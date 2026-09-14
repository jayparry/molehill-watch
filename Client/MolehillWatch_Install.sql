/*
===============================================================================
 Molehill Watch - SQL Server Support Package
 Client monitoring install script                               Version 1.0.0
 Molehill Data Services  -  jay@jayparry.co.uk  -  molehilldataservices.com
-------------------------------------------------------------------------------
 Installs, on ONE SQL Server instance:
   * the MolehillWatch database (settings, collected history, weekly reports)
   * collection procedures (backups, error log, Agent jobs, top queries,
     disk/database growth, Availability Groups, blocking)
   * the weekly status report builder (HTML, optional Database Mail)
   * four SQL Agent jobs (category "Molehill Watch")

 EASIEST:  run Install-MolehillWatch.ps1 (does all of this for you).
 MANUAL:   open in SSMS, connect as sysadmin, press F5, then run the
           "CONFIGURE" block at the very bottom of this file.

 Safe to re-run: objects are upgraded in place and collected data is kept.
 Requires SQL Server 2012 or later. Nothing leaves the server unless report
 e-mail is configured (and query text is excluded from e-mail by default).

 Availability Groups: install on EVERY replica. Do NOT add the MolehillWatch
 database to an Availability Group - each replica keeps its own history.
===============================================================================
*/
SET NOCOUNT ON;
GO
IF CONVERT(int, PARSENAME(CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')), 4)) < 11
    RAISERROR('Molehill Watch requires SQL Server 2012 or later. Installation stopped.', 20, 1) WITH LOG;
IF ISNULL(IS_SRVROLEMEMBER('sysadmin'), 0) = 0
    RAISERROR('Molehill Watch must be installed by a member of the sysadmin role. Installation stopped.', 20, 1) WITH LOG;
GO

/*=============================================================================
  1. DATABASE
=============================================================================*/
USE master;
GO
IF DB_ID(N'MolehillWatch') IS NULL
BEGIN
    CREATE DATABASE MolehillWatch;
    PRINT 'Created database MolehillWatch.';
END
GO
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = N'MolehillWatch') <> N'SIMPLE'
    ALTER DATABASE MolehillWatch SET RECOVERY SIMPLE;
IF (SELECT is_auto_close_on FROM sys.databases WHERE name = N'MolehillWatch') = 1
    ALTER DATABASE MolehillWatch SET AUTO_CLOSE OFF;
DECLARE @owner nvarchar(300) = N'ALTER AUTHORIZATION ON DATABASE::MolehillWatch TO ' + QUOTENAME(SUSER_SNAME(0x01)) + N';';
EXEC (@owner);
GO
USE MolehillWatch;
GO

/*=============================================================================
  2. TABLES
=============================================================================*/
IF OBJECT_ID(N'dbo.InstallHistory') IS NULL
CREATE TABLE dbo.InstallHistory (
    InstallId    int IDENTITY(1,1) NOT NULL CONSTRAINT PK_InstallHistory PRIMARY KEY,
    Version      varchar(20)   NOT NULL,
    InstalledAt  datetime2(0)  NOT NULL CONSTRAINT DF_InstallHistory_At DEFAULT SYSDATETIME(),
    InstalledBy  nvarchar(128) NOT NULL CONSTRAINT DF_InstallHistory_By DEFAULT SUSER_SNAME());

IF OBJECT_ID(N'dbo.Setting') IS NULL
CREATE TABLE dbo.Setting (
    Name        varchar(100)   NOT NULL CONSTRAINT PK_Setting PRIMARY KEY,
    Value       nvarchar(4000) NULL,
    Description nvarchar(1000) NULL);

IF OBJECT_ID(N'dbo.CollectorState') IS NULL
CREATE TABLE dbo.CollectorState (
    StateName   varchar(100) NOT NULL CONSTRAINT PK_CollectorState PRIMARY KEY,
    DateValue   datetime     NULL,
    IntValue    bigint       NULL);

IF OBJECT_ID(N'dbo.CollectionLog') IS NULL
CREATE TABLE dbo.CollectionLog (
    LogId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_CollectionLog PRIMARY KEY,
    CollectionType varchar(20)    NOT NULL,
    StepName       varchar(100)   NOT NULL,
    StartTime      datetime       NOT NULL,
    EndTime        datetime       NULL,
    Succeeded      bit            NULL,
    ErrorMessage   nvarchar(4000) NULL);

IF OBJECT_ID(N'dbo.ProductLifecycle') IS NULL
CREATE TABLE dbo.ProductLifecycle (
    ProductName   nvarchar(100) NOT NULL CONSTRAINT PK_ProductLifecycle PRIMARY KEY,
    Product       varchar(30)   NOT NULL,   -- 'SQL Server' | 'Windows Server'
    MajorVersion  int           NULL,       -- SQL Server major build number
    MainstreamEnd date          NULL,
    ExtendedEnd   date          NULL,
    Notes         nvarchar(400) NULL);

IF OBJECT_ID(N'dbo.ErrorLogPattern') IS NULL
CREATE TABLE dbo.ErrorLogPattern (
    PatternId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ErrorLogPattern PRIMARY KEY,
    Pattern        nvarchar(400)  NOT NULL,
    IsExclusion    bit            NOT NULL,
    Priority       int            NOT NULL CONSTRAINT DF_ErrorLogPattern_Priority DEFAULT 500,
    Category       varchar(50)    NULL,
    Severity       varchar(10)    NULL,     -- Critical | Warning | Info
    Recommendation nvarchar(1000) NULL,
    IsEnabled      bit            NOT NULL CONSTRAINT DF_ErrorLogPattern_Enabled DEFAULT 1);

IF OBJECT_ID(N'dbo.ErrorLogEntry') IS NULL
BEGIN
    CREATE TABLE dbo.ErrorLogEntry (
        EntryId     bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_ErrorLogEntry PRIMARY KEY,
        LogDate     datetime       NOT NULL,
        ProcessInfo nvarchar(100)  NULL,
        LogText     nvarchar(4000) NOT NULL,
        TextHash    varbinary(20)  NOT NULL,
        PatternId   int            NULL,
        Category    varchar(50)    NULL,
        Severity    varchar(10)    NULL,
        CapturedAt  datetime       NOT NULL CONSTRAINT DF_ErrorLogEntry_CapturedAt DEFAULT GETDATE());
    CREATE UNIQUE INDEX UX_ErrorLogEntry_Dedupe ON dbo.ErrorLogEntry (LogDate, TextHash) WITH (IGNORE_DUP_KEY = ON);
END

IF OBJECT_ID(N'dbo.JobFailure') IS NULL
BEGIN
    CREATE TABLE dbo.JobFailure (
        JobHistoryId    int            NOT NULL CONSTRAINT PK_JobFailure PRIMARY KEY,  -- msdb instance_id
        JobName         sysname        NOT NULL,
        StepId          int            NOT NULL,
        StepName        sysname        NULL,
        RunDateTime     datetime       NOT NULL,
        DurationSeconds int            NULL,
        RunStatus       int            NOT NULL,  -- 0 failed, 3 cancelled
        Message         nvarchar(4000) NULL);
    CREATE INDEX IX_JobFailure_RunDateTime ON dbo.JobFailure (RunDateTime);
END

IF OBJECT_ID(N'dbo.QuerySnapshot') IS NULL
BEGIN
    CREATE TABLE dbo.QuerySnapshot (
        SnapshotTime       datetime   NOT NULL,
        QueryHash          binary(8)  NOT NULL,
        ExecutionCount     bigint     NOT NULL,
        CpuMs              bigint     NOT NULL,
        DurationMs         bigint     NOT NULL,
        LogicalReads       bigint     NOT NULL,
        LogicalWrites      bigint     NOT NULL,
        OldestPlanCreation datetime   NULL,
        LastExecution      datetime   NULL,
        CONSTRAINT PK_QuerySnapshot PRIMARY KEY (SnapshotTime, QueryHash));
END

IF OBJECT_ID(N'dbo.QueryText') IS NULL
CREATE TABLE dbo.QueryText (
    QueryHash    binary(8)     NOT NULL CONSTRAINT PK_QueryText PRIMARY KEY,
    DatabaseName sysname       NULL,
    ObjectName   sysname       NULL,
    QueryText    nvarchar(max) NULL,
    FirstSeen    datetime      NOT NULL CONSTRAINT DF_QueryText_FirstSeen DEFAULT GETDATE());

IF OBJECT_ID(N'dbo.DiskSnapshot') IS NULL
CREATE TABLE dbo.DiskSnapshot (
    SnapshotTime      datetime      NOT NULL,
    VolumeMountPoint  nvarchar(260) NOT NULL,
    LogicalVolumeName nvarchar(512) NULL,
    TotalMB           bigint        NOT NULL,
    FreeMB            bigint        NOT NULL,
    CONSTRAINT PK_DiskSnapshot PRIMARY KEY (SnapshotTime, VolumeMountPoint));

IF OBJECT_ID(N'dbo.DatabaseFileSnapshot') IS NULL
CREATE TABLE dbo.DatabaseFileSnapshot (
    SnapshotTime    datetime       NOT NULL,
    DatabaseName    sysname        NOT NULL,
    FileId          int            NOT NULL,
    FileType        nvarchar(60)   NOT NULL,
    LogicalName     sysname        NOT NULL,
    PhysicalName    nvarchar(260)  NOT NULL,
    SizeMB          decimal(18,2)  NOT NULL,
    UsedMB          decimal(18,2)  NULL,
    GrowthPages     int            NOT NULL,
    IsPercentGrowth bit            NOT NULL,
    MaxSizePages    int            NOT NULL,
    CONSTRAINT PK_DatabaseFileSnapshot PRIMARY KEY (SnapshotTime, DatabaseName, FileId));

IF OBJECT_ID(N'dbo.AgDatabaseSample') IS NULL
CREATE TABLE dbo.AgDatabaseSample (
    SampleTime          datetime      NOT NULL,
    AgName              sysname       NOT NULL,
    ReplicaServer       nvarchar(128) NOT NULL,
    DatabaseName        sysname       NOT NULL,
    IsLocal             bit           NULL,
    ReplicaRole         nvarchar(60)  NULL,
    AvailabilityMode    nvarchar(60)  NULL,
    FailoverMode        nvarchar(60)  NULL,
    SyncState           nvarchar(60)  NULL,
    SyncHealth          nvarchar(60)  NULL,
    IsSuspended         bit           NULL,
    SuspendReason       nvarchar(60)  NULL,
    LogSendQueueKB      bigint        NULL,
    RedoQueueKB         bigint        NULL,
    SecondaryLagSeconds bigint        NULL,
    IsFailoverReady     bit           NULL,
    CONSTRAINT PK_AgDatabaseSample PRIMARY KEY (SampleTime, AgName, ReplicaServer, DatabaseName));

IF OBJECT_ID(N'dbo.AgReplicaSample') IS NULL
CREATE TABLE dbo.AgReplicaSample (
    SampleTime       datetime      NOT NULL,
    AgName           sysname       NOT NULL,
    ReplicaServer    nvarchar(128) NOT NULL,
    ReplicaRole      nvarchar(60)  NULL,
    AvailabilityMode nvarchar(60)  NULL,
    FailoverMode     nvarchar(60)  NULL,
    ConnectedState   nvarchar(60)  NULL,
    SyncHealth       nvarchar(60)  NULL,
    CONSTRAINT PK_AgReplicaSample PRIMARY KEY (SampleTime, AgName, ReplicaServer));

IF OBJECT_ID(N'dbo.BlockingSample') IS NULL
BEGIN
    CREATE TABLE dbo.BlockingSample (
        SampleId          bigint IDENTITY(1,1) NOT NULL CONSTRAINT PK_BlockingSample PRIMARY KEY,
        SampleTime        datetime       NOT NULL,
        SessionId         int            NOT NULL,
        BlockingSessionId int            NULL,
        IsHeadBlocker     bit            NOT NULL,
        WaitSeconds       int            NULL,
        WaitType          nvarchar(60)   NULL,
        DatabaseName      sysname        NULL,
        LoginName         nvarchar(128)  NULL,
        HostName          nvarchar(128)  NULL,
        ProgramName       nvarchar(128)  NULL,
        OpenTransactions  int            NULL,
        SqlText           nvarchar(4000) NULL);
    CREATE INDEX IX_BlockingSample_SampleTime ON dbo.BlockingSample (SampleTime);
END

IF OBJECT_ID(N'dbo.WeeklyReport') IS NULL
CREATE TABLE dbo.WeeklyReport (
    ReportId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_WeeklyReport PRIMARY KEY,
    GeneratedAt   datetime       NOT NULL,
    PeriodStart   datetime       NOT NULL,
    PeriodEnd     datetime       NOT NULL,
    ClientName    nvarchar(200)  NULL,
    InstanceName  nvarchar(200)  NULL,
    OverallStatus varchar(10)    NULL,   -- Red | Amber | Green
    CriticalCount int            NULL,
    WarningCount  int            NULL,
    InfoCount     int            NULL,
    Html          nvarchar(max)  NULL,
    EmailedAt     datetime       NULL,
    EmailError    nvarchar(2000) NULL);

IF OBJECT_ID(N'dbo.ReportFinding') IS NULL
CREATE TABLE dbo.ReportFinding (
    FindingId      int IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReportFinding PRIMARY KEY,
    ReportId       int            NOT NULL CONSTRAINT FK_ReportFinding_Report REFERENCES dbo.WeeklyReport (ReportId) ON DELETE CASCADE,
    Section        varchar(30)    NOT NULL,
    Severity       varchar(10)    NOT NULL,
    Item           nvarchar(400)  NOT NULL,
    Detail         nvarchar(max)  NULL,
    Recommendation nvarchar(1000) NULL);

-- Latest builds published by Microsoft, loaded by Update-PatchReference.ps1
IF OBJECT_ID(N'dbo.PatchReference') IS NULL
BEGIN
    CREATE TABLE dbo.PatchReference (
        ReferenceId int IDENTITY(1,1) NOT NULL CONSTRAINT PK_PatchReference PRIMARY KEY,
        Product     varchar(20)   NOT NULL,     -- 'SQL Server' | 'Windows Server'
        ProductName nvarchar(100) NOT NULL,     -- e.g. 'SQL Server 2022', 'Windows Server 2022'
        Major       int           NOT NULL,
        Minor       int           NOT NULL,
        BuildNumber int           NOT NULL,     -- Windows: OS build (20348); SQL: third part of the version
        Revision    int           NOT NULL,     -- Windows: UBR; SQL: fourth part of the version
        ServicePack nvarchar(30)  NULL,
        UpdateName  nvarchar(60)  NULL,         -- 'CU26', 'CU26 + GDR', 'GDR', 'Security Update'
        CuNumber    int           NULL,
        KB          varchar(20)   NULL,
        ReleaseDate date          NULL,
        Source      nvarchar(200) NULL,
        LoadedAt    datetime      NOT NULL CONSTRAINT DF_PatchReference_LoadedAt DEFAULT GETDATE());
    CREATE INDEX IX_PatchReference_Lookup ON dbo.PatchReference (Product, Major, BuildNumber, Revision);
END

-- What is installed on this server (collected daily)
IF OBJECT_ID(N'dbo.PatchLevel') IS NULL
CREATE TABLE dbo.PatchLevel (
    CollectedAt        datetime      NOT NULL CONSTRAINT PK_PatchLevel PRIMARY KEY,
    OsProductName      nvarchar(200) NULL,
    OsInstallationType nvarchar(50)  NULL,
    OsDisplayVersion   nvarchar(50)  NULL,
    OsCurrentBuild     int           NULL,
    OsUbr              int           NULL,
    SqlVersion         varchar(30)   NULL,
    SqlUpdateLevel     nvarchar(50)  NULL,
    SqlUpdateReference nvarchar(50)  NULL);
GO

/*=============================================================================
  3. REFERENCE DATA
=============================================================================*/
-- Settings (existing values are never overwritten on re-install)
INSERT dbo.Setting (Name, Value, Description)
SELECT v.Name, v.Value, v.Description
FROM (VALUES
    ('ClientName',                    N'',      N'Client organisation name shown on reports.'),
    ('InstanceDisplayName',           N'',      N'Friendly name for this instance on reports (blank = @@SERVERNAME).'),
    ('UnsupportedRiskAccepted',       N'',      N'If this instance runs an unsupported version: who accepted the risk and when, e.g. "J Smith, 01 Oct 2026".'),
    ('RetentionDays',                 N'90',    N'Days to keep error log, job failure, collection log and report history.'),
    ('SampleRetentionDays',           N'35',    N'Days to keep high-frequency samples (AG, blocking, query snapshots).'),
    ('TrendRetentionDays',            N'400',   N'Days to keep daily disk and database size snapshots (growth trends).'),
    ('BackupFullMaxAgeHours',         N'170',   N'Critical if the last FULL backup is older than this.'),
    ('BackupFullOrDiffMaxAgeHours',   N'26',    N'Warning if the last FULL or DIFF backup is older than this.'),
    ('BackupLogMaxAgeMinutes',        N'90',    N'Critical if a FULL/BULK_LOGGED database has no log backup within this.'),
    ('CheckDbMaxAgeDays',             N'8',     N'Warning if DBCC CHECKDB has not completed cleanly within this many days.'),
    ('DiskWarnFreePct',               N'15',    N'Warning below this % free.'),
    ('DiskCritFreePct',               N'10',    N'Critical below this % free.'),
    ('LogUsedWarnPct',                N'75',    N'Warning when a transaction log (>= 512 MB) is this % full and waiting on something.'),
    ('AgSendQueueWarnKB',             N'102400',N'Warning when the AG log send queue exceeded this (KB) during the period.'),
    ('AgRedoQueueWarnKB',             N'102400',N'Warning when the AG redo queue exceeded this (KB) during the period.'),
    ('AgLagWarnSeconds',              N'60',    N'Warning when secondary lag exceeded this during the period (SQL 2016+).'),
    ('BlockingThresholdSeconds',      N'60',    N'Capture blocking chains where a request has waited at least this long.'),
    ('BlockingWarnSeconds',           N'300',   N'Warning when any blocked request waited this long during the period.'),
    ('ReportEmailProfile',            N'',      N'Database Mail profile used to send the weekly report (blank = no e-mail).'),
    ('ReportEmailRecipients',         N'',      N'Semicolon separated recipients for the weekly report.'),
    ('ReportEmailIncludeQueryText',   N'0',     N'1 = include query text in the e-mailed report. Default 0 - query text can contain personal data.'),
    ('SqlPatchGraceDays',             N'30',    N'Days after a SQL Server CU/GDR is released before not having it becomes a Warning.'),
    ('SqlCuBehindCritical',           N'3',     N'Critical when this many cumulative updates behind the latest CU.'),
    ('SqlSecurityUpdateSeverity',     N'Info',  N'Severity when on the latest CU but a newer "CU + GDR" security update exists: Info or Warning.'),
    ('WindowsPatchGraceDays',         N'14',    N'Days after Patch Tuesday before a missing Windows security update becomes a Warning (Critical once a second month is missed).'),
    ('PatchReferenceMaxAgeDays',      N'40',    N'Warning when the patch reference data has not been refreshed for this many days.')
) v (Name, Value, Description)
WHERE NOT EXISTS (SELECT 1 FROM dbo.Setting s WHERE s.Name = v.Name);

-- Microsoft lifecycle dates. Verify at https://learn.microsoft.com/lifecycle and edit as needed.
MERGE dbo.ProductLifecycle AS t
USING (VALUES
    (N'SQL Server 2012',        'SQL Server',     11, '2017-07-11', '2022-07-12', NULL),
    (N'SQL Server 2014',        'SQL Server',     12, '2019-07-09', '2024-07-09', NULL),
    (N'SQL Server 2016',        'SQL Server',     13, '2021-07-13', '2026-07-14', NULL),
    (N'SQL Server 2017',        'SQL Server',     14, '2022-10-11', '2027-10-12', NULL),
    (N'SQL Server 2019',        'SQL Server',     15, '2025-02-28', '2030-01-08', NULL),
    (N'SQL Server 2022',        'SQL Server',     16, '2028-01-11', '2033-01-11', NULL),
    (N'SQL Server 2025',        'SQL Server',     17, NULL,         NULL,         N'Add dates once confirmed on the Microsoft lifecycle site.'),
    (N'Windows Server 2008 R2', 'Windows Server', NULL, '2015-01-13', '2020-01-14', NULL),
    (N'Windows Server 2012',    'Windows Server', NULL, '2018-10-09', '2023-10-10', NULL),
    (N'Windows Server 2012 R2', 'Windows Server', NULL, '2018-10-09', '2023-10-10', NULL),
    (N'Windows Server 2016',    'Windows Server', NULL, '2022-01-11', '2027-01-12', NULL),
    (N'Windows Server 2019',    'Windows Server', NULL, '2024-01-09', '2029-01-09', NULL),
    (N'Windows Server 2022',    'Windows Server', NULL, '2026-10-13', '2031-10-14', NULL),
    (N'Windows Server 2025',    'Windows Server', NULL, '2029-10-09', '2034-10-10', NULL)
) AS s (ProductName, Product, MajorVersion, MainstreamEnd, ExtendedEnd, Notes)
ON t.ProductName = s.ProductName
WHEN NOT MATCHED THEN INSERT (ProductName, Product, MajorVersion, MainstreamEnd, ExtendedEnd, Notes)
                      VALUES (s.ProductName, s.Product, s.MajorVersion, s.MainstreamEnd, s.ExtendedEnd, s.Notes);

-- Error log classification. First matching include pattern (lowest Priority) wins.
-- Add your own rows; defaults are only inserted if missing.
INSERT dbo.ErrorLogPattern (Pattern, IsExclusion, Priority, Category, Severity, Recommendation)
SELECT v.Pattern, v.IsExclusion, v.Priority, v.Category, v.Severity, v.Recommendation
FROM (VALUES
    (N'%found 0 errors and repaired 0 errors%', 1, 0, NULL, NULL, NULL),
    (N'%without errors%',                       1, 0, NULL, NULL, NULL),
    (N'%Logging SQL Server messages in file%',  1, 0, NULL, NULL, NULL),
    (N'%\ERRORLOG%',                            1, 0, NULL, NULL, NULL),
    (N'%error log has been reinitialized%',     1, 0, NULL, NULL, NULL),
    (N'%informational message only%',           1, 0, NULL, NULL, NULL),
    (N'%Using ''dbghelp.dll''%',                1, 0, NULL, NULL, NULL),
    (N'%Error: 823,%',            0, 10, 'Corruption', 'Critical', N'Possible database corruption. Run DBCC CHECKDB, check storage health and confirm backups are restorable. Raise a Critical ticket.'),
    (N'%Error: 824,%',            0, 10, 'Corruption', 'Critical', N'Possible database corruption. Run DBCC CHECKDB, check storage health and confirm backups are restorable. Raise a Critical ticket.'),
    (N'%Error: 825,%',            0, 10, 'Corruption', 'Critical', N'Read-retry I/O errors are an early warning of storage failure. Check storage health and run DBCC CHECKDB.'),
    (N'%corrupt%',                0, 10, 'Corruption', 'Critical', N'Possible database corruption. Run DBCC CHECKDB, check storage health and confirm backups are restorable. Raise a Critical ticket.'),
    (N'%consistency error%',      0, 10, 'Corruption', 'Critical', N'DBCC reported consistency errors. Do not run repair without advice - raise a Critical ticket.'),
    (N'%stack dump%',             0, 20, 'Stack dump / crash', 'Critical', N'SQL Server produced a memory dump. Check the build against the latest CU for known fixes and raise a ticket.'),
    (N'%non-yielding%',           0, 20, 'Stack dump / crash', 'Critical', N'Non-yielding scheduler detected. Check the build against the latest CU and raise a ticket.'),
    (N'%access violation%',       0, 20, 'Stack dump / crash', 'Critical', N'Access violation detected. Check the build against the latest CU and raise a ticket.'),
    (N'%lease%expired%',          0, 25, 'Availability', 'Critical', N'Availability Group lease expired - the AG may have gone offline or failed over. Investigate cluster and replica health.'),
    (N'%SSPI%fail%',              0, 30, 'Authentication', 'Warning', N'Kerberos/NTLM authentication failures. Check SPNs, domain connectivity and service account health.'),
    (N'%unable to reuse a session%', 0, 30, 'Connection reuse', 'Info', N'Usually harmless connection pooling noise unless very frequent.'),
    (N'%log for database%is full%', 0, 35, 'Space', 'Critical', N'A transaction log filled. Check log backups, disk space and long-running transactions.'),
    (N'%Could not allocate%',     0, 35, 'Space', 'Critical', N'A database could not grow. Check disk space, autogrowth and file max size settings.'),
    (N'%BACKUP failed%',          0, 40, 'Backup failure', 'Critical', N'Backups failed. Confirm the backup destination is reachable and has space, then re-run the backup.'),
    (N'%Error: 3041,%',           0, 40, 'Backup failure', 'Critical', N'Backups failed. Confirm the backup destination is reachable and has space, then re-run the backup.'),
    (N'%BackupIoRequest%',        0, 40, 'Backup failure', 'Critical', N'Backup I/O error. Check the backup destination and network path.'),
    (N'%BackupDiskFile%',         0, 40, 'Backup failure', 'Critical', N'Backup I/O error. Check the backup destination and network path.'),
    (N'%RESTORE failed%',         0, 40, 'Restore failure', 'Warning', N'A restore failed. Confirm whether this was expected (e.g. a test restore).'),
    (N'%Severity: 2[0-5],%',      0, 50, 'Severe error (20+)', 'Critical', N'High-severity error. Review the message and raise a ticket if unexpected.'),
    (N'%I/O requests taking longer than%', 0, 60, 'Storage latency', 'Warning', N'Storage took more than 15 seconds to respond. Review storage performance with your infrastructure team.'),
    (N'%paged out%',              0, 70, 'Memory pressure', 'Warning', N'SQL Server memory was paged out. Review max server memory, Lock Pages in Memory and OS memory use.'),
    (N'%insufficient system memory%', 0, 70, 'Memory pressure', 'Warning', N'Memory pressure. Review max server memory and other memory consumers on the server.'),
    (N'%Error: 701,%',            0, 70, 'Memory pressure', 'Warning', N'Out-of-memory error. Review max server memory and memory-heavy queries.'),
    (N'%Error: 35[0-9][0-9][0-9],%', 0, 80, 'Availability', 'Warning', N'Availability Group error. Check replica connectivity and synchronisation.'),
    (N'%Error: 19[0-9][0-9][0-9],%', 0, 80, 'Availability', 'Warning', N'Availability Group / cluster error. Check replica connectivity and synchronisation.'),
    (N'%deadlock%',               0, 90, 'Deadlocks', 'Warning', N'Deadlocks occurred. The deadlock graphs are in the system_health Extended Events session.'),
    (N'%Login failed%',           0, 100, 'Login failures', 'Info', N'Login failures may be a misconfigured application or unauthorised attempts. Review the source if counts are high.'),
    (N'%Severity: 1[6-9],%',      0, 110, 'General errors', 'Warning', N'Review the error and raise a ticket if it recurs or is unexpected.'),
    (N'%failed%',                 0, 120, 'Other failures', 'Info', N'Usually informational unless recurring.'),
    (N'%could not%',              0, 120, 'Other failures', 'Info', N'Usually informational unless recurring.'),
    (N'%unable to%',              0, 120, 'Other failures', 'Info', N'Usually informational unless recurring.'),
    (N'%timed out%',              0, 120, 'Other failures', 'Info', N'Usually informational unless recurring.')
) v (Pattern, IsExclusion, Priority, Category, Severity, Recommendation)
WHERE NOT EXISTS (SELECT 1 FROM dbo.ErrorLogPattern p WHERE p.Pattern = v.Pattern AND p.IsExclusion = v.IsExclusion);
GO

/*=============================================================================
  4. HELPER FUNCTIONS
=============================================================================*/
IF OBJECT_ID(N'dbo.fn_Setting') IS NULL EXEC (N'CREATE FUNCTION dbo.fn_Setting (@Name varchar(100)) RETURNS nvarchar(4000) AS BEGIN RETURN NULL; END');
GO
ALTER FUNCTION dbo.fn_Setting (@Name varchar(100))
RETURNS nvarchar(4000)
AS
BEGIN
    RETURN (SELECT Value FROM dbo.Setting WHERE Name = @Name);
END
GO
IF OBJECT_ID(N'dbo.fn_SettingInt') IS NULL EXEC (N'CREATE FUNCTION dbo.fn_SettingInt (@Name varchar(100), @Default bigint) RETURNS bigint AS BEGIN RETURN NULL; END');
GO
ALTER FUNCTION dbo.fn_SettingInt (@Name varchar(100), @Default bigint)
RETURNS bigint
AS
BEGIN
    RETURN ISNULL((SELECT TRY_CONVERT(bigint, Value) FROM dbo.Setting WHERE Name = @Name), @Default);
END
GO
IF OBJECT_ID(N'dbo.fn_Html') IS NULL EXEC (N'CREATE FUNCTION dbo.fn_Html (@s nvarchar(max)) RETURNS nvarchar(max) AS BEGIN RETURN NULL; END');
GO
ALTER FUNCTION dbo.fn_Html (@s nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@s, N''), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;');
END
GO
IF OBJECT_ID(N'dbo.fn_Date') IS NULL EXEC (N'CREATE FUNCTION dbo.fn_Date (@d datetime) RETURNS nvarchar(30) AS BEGIN RETURN NULL; END');
GO
ALTER FUNCTION dbo.fn_Date (@d datetime)
RETURNS nvarchar(30)
AS
BEGIN
    RETURN CASE WHEN @d IS NULL OR @d < '19010101' THEN N'never'
                ELSE CONVERT(nvarchar(11), @d, 106) + N' ' + CONVERT(nvarchar(5), @d, 108) END;
END
GO
IF OBJECT_ID(N'dbo.fn_Age') IS NULL EXEC (N'CREATE FUNCTION dbo.fn_Age (@From datetime, @To datetime) RETURNS nvarchar(30) AS BEGIN RETURN NULL; END');
GO
ALTER FUNCTION dbo.fn_Age (@From datetime, @To datetime)
RETURNS nvarchar(30)
AS
BEGIN
    IF @From IS NULL OR @From < '19010101' RETURN N'never';
    DECLARE @m bigint = DATEDIFF(minute, @From, @To);
    RETURN CASE WHEN @m < 120  THEN CONVERT(nvarchar(20), @m) + N' min ago'
                WHEN @m < 2880 THEN CONVERT(nvarchar(20), @m / 60) + N' h ago'
                ELSE CONVERT(nvarchar(20), @m / 1440) + N' days ago' END;
END
GO
-- Which tool took a backup, from msdb backup history
IF OBJECT_ID(N'dbo.fn_BackupTool') IS NULL EXEC (N'CREATE FUNCTION dbo.fn_BackupTool (@UserName nvarchar(128), @IsSnapshot bit, @DeviceType tinyint, @SoftwareName nvarchar(128)) RETURNS nvarchar(30) AS BEGIN RETURN NULL; END');
GO
ALTER FUNCTION dbo.fn_BackupTool (@UserName nvarchar(128), @IsSnapshot bit, @DeviceType tinyint, @SoftwareName nvarchar(128))
RETURNS nvarchar(30)
AS
BEGIN
    RETURN CASE WHEN @IsSnapshot = 1                                  THEN N'VM/VSS snapshot'
                WHEN @UserName LIKE N'%AzureWLBackupPluginSvc%'        THEN N'Azure Backup'
                WHEN @DeviceType = 9                                  THEN N'Backup to URL'
                WHEN @DeviceType = 7                                  THEN N'Third-party (VDI)'
                WHEN @SoftwareName NOT LIKE N'Microsoft SQL Server%'  THEN N'Third-party'
                WHEN @DeviceType = 5                                  THEN N'Native (tape)'
                ELSE N'Native' END;
END
GO

/*=============================================================================
  5. CONFIGURATION PROCEDURE
=============================================================================*/
IF OBJECT_ID(N'dbo.usp_Configure', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_Configure AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_Configure
    @ClientName                  nvarchar(200)  = NULL,
    @InstanceDisplayName         nvarchar(200)  = NULL,
    @ReportEmailProfile          sysname        = NULL,
    @ReportEmailRecipients       nvarchar(1000) = NULL,
    @ReportEmailIncludeQueryText bit            = NULL,
    @UnsupportedRiskAccepted     nvarchar(400)  = NULL,
    @SettingName                 varchar(100)   = NULL,   -- set any other setting by name
    @SettingValue                nvarchar(4000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ClientName IS NOT NULL                  UPDATE dbo.Setting SET Value = @ClientName WHERE Name = 'ClientName';
    IF @InstanceDisplayName IS NOT NULL         UPDATE dbo.Setting SET Value = @InstanceDisplayName WHERE Name = 'InstanceDisplayName';
    IF @ReportEmailProfile IS NOT NULL          UPDATE dbo.Setting SET Value = @ReportEmailProfile WHERE Name = 'ReportEmailProfile';
    IF @ReportEmailRecipients IS NOT NULL       UPDATE dbo.Setting SET Value = @ReportEmailRecipients WHERE Name = 'ReportEmailRecipients';
    IF @ReportEmailIncludeQueryText IS NOT NULL UPDATE dbo.Setting SET Value = CONVERT(nvarchar(1), @ReportEmailIncludeQueryText) WHERE Name = 'ReportEmailIncludeQueryText';
    IF @UnsupportedRiskAccepted IS NOT NULL     UPDATE dbo.Setting SET Value = @UnsupportedRiskAccepted WHERE Name = 'UnsupportedRiskAccepted';
    IF @SettingName IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.Setting WHERE Name = @SettingName)
        BEGIN
            RAISERROR(N'Unknown setting "%s". SELECT * FROM MolehillWatch.dbo.Setting to see valid names.', 16, 1, @SettingName);
            RETURN;
        END
        UPDATE dbo.Setting SET Value = @SettingValue WHERE Name = @SettingName;
    END
    SELECT Name, Value, Description FROM dbo.Setting ORDER BY Name;
END
GO

/*=============================================================================
  6. COLLECTORS
=============================================================================*/
IF OBJECT_ID(N'dbo.usp_CollectErrorLog', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectErrorLog AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectErrorLog
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @since datetime = ISNULL((SELECT DateValue FROM dbo.CollectorState WHERE StateName = 'ErrorLogHighWater'), DATEADD(day, -8, GETDATE()));
    DECLARE @start nvarchar(30) = CONVERT(nvarchar(30), DATEADD(minute, -1, @since), 120);
    DECLARE @end   nvarchar(30) = CONVERT(nvarchar(30), DATEADD(minute, 5, GETDATE()), 120);
    DECLARE @lognum int = 1;

    CREATE TABLE #log (RowId int IDENTITY(1,1) PRIMARY KEY, LogDate datetime, ProcessInfo nvarchar(100), LogText nvarchar(max));

    WHILE @lognum >= 0   -- previous log first, then current, so rows stay in time order
    BEGIN
        BEGIN TRY
            INSERT #log (LogDate, ProcessInfo, LogText)
            EXEC master.dbo.xp_readerrorlog @lognum, 1, N'', N'', @start, @end, N'asc';
        END TRY
        BEGIN CATCH
            -- archive log may not exist yet
        END CATCH;
        SET @lognum = @lognum - 1;
    END

    -- "Error: n, Severity: s, State: x." header lines are merged into the message line that follows
    ;WITH x AS (
        SELECT RowId, LogDate, ProcessInfo, LogText,
               PrevText = LAG(LogText)     OVER (ORDER BY RowId),
               PrevDate = LAG(LogDate)     OVER (ORDER BY RowId),
               PrevProc = LAG(ProcessInfo) OVER (ORDER BY RowId),
               NextDate = LEAD(LogDate)     OVER (ORDER BY RowId),
               NextProc = LEAD(ProcessInfo) OVER (ORDER BY RowId)
        FROM #log)
    SELECT LogDate, ProcessInfo,
           FullText = LEFT(CASE WHEN PrevText LIKE N'Error: %, Severity: %' AND PrevDate = LogDate AND PrevProc = ProcessInfo
                                THEN PrevText + N' ' + LogText ELSE LogText END, 4000)
    INTO #merged
    FROM x
    WHERE NOT (LogText LIKE N'Error: %, Severity: %' AND NextDate = LogDate AND NextProc = ProcessInfo);

    INSERT dbo.ErrorLogEntry (LogDate, ProcessInfo, LogText, TextHash, PatternId, Category, Severity)
    SELECT m.LogDate, m.ProcessInfo, m.FullText, HASHBYTES('SHA1', m.FullText), p.PatternId, p.Category, p.Severity
    FROM #merged m
    CROSS APPLY (SELECT TOP (1) PatternId, Category, Severity
                 FROM dbo.ErrorLogPattern ip
                 WHERE ip.IsExclusion = 0 AND ip.IsEnabled = 1 AND m.FullText LIKE ip.Pattern
                 ORDER BY ip.Priority, ip.PatternId) p
    WHERE m.LogDate >= DATEADD(minute, -1, @since)
      AND NOT EXISTS (SELECT 1 FROM dbo.ErrorLogPattern ep
                      WHERE ep.IsExclusion = 1 AND ep.IsEnabled = 1 AND m.FullText LIKE ep.Pattern);

    DECLARE @hw datetime = (SELECT MAX(LogDate) FROM #log);
    IF @hw IS NOT NULL
    BEGIN
        UPDATE dbo.CollectorState SET DateValue = @hw WHERE StateName = 'ErrorLogHighWater';
        IF @@ROWCOUNT = 0 INSERT dbo.CollectorState (StateName, DateValue) VALUES ('ErrorLogHighWater', @hw);
    END
END
GO

IF OBJECT_ID(N'dbo.usp_CollectJobFailures', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectJobFailures AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectJobFailures
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @last bigint = ISNULL((SELECT IntValue FROM dbo.CollectorState WHERE StateName = 'JobHistoryHighWater'), 0);
    DECLARE @max  bigint = (SELECT MAX(instance_id) FROM msdb.dbo.sysjobhistory);
    IF @max IS NULL RETURN;
    IF @max < @last SET @last = 0;   -- msdb history was reset

    INSERT dbo.JobFailure (JobHistoryId, JobName, StepId, StepName, RunDateTime, DurationSeconds, RunStatus, Message)
    SELECT h.instance_id, j.name, h.step_id, h.step_name,
           msdb.dbo.agent_datetime(h.run_date, h.run_time),
           (h.run_duration / 10000) * 3600 + (h.run_duration / 100 % 100) * 60 + h.run_duration % 100,
           h.run_status, LEFT(h.message, 4000)
    FROM msdb.dbo.sysjobhistory h
    JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
    WHERE h.instance_id > @last
      AND h.run_status IN (0, 3)
      AND h.run_date > 0
      AND NOT EXISTS (SELECT 1 FROM dbo.JobFailure f WHERE f.JobHistoryId = h.instance_id);

    UPDATE dbo.CollectorState SET IntValue = @max WHERE StateName = 'JobHistoryHighWater';
    IF @@ROWCOUNT = 0 INSERT dbo.CollectorState (StateName, IntValue) VALUES ('JobHistoryHighWater', @max);
END
GO

IF OBJECT_ID(N'dbo.usp_CollectQueryStats', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectQueryStats AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectQueryStats
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime = GETDATE();

    SELECT query_hash, sql_handle, plan_handle, statement_start_offset, statement_end_offset,
           execution_count, total_worker_time, total_elapsed_time, total_logical_reads,
           total_logical_writes, creation_time, last_execution_time
    INTO #qs
    FROM sys.dm_exec_query_stats
    WHERE query_hash <> 0x0000000000000000;

    ;WITH agg AS (
        SELECT query_hash,
               ExecutionCount = SUM(execution_count),
               CpuMs          = SUM(total_worker_time) / 1000,
               DurationMs     = SUM(total_elapsed_time) / 1000,
               LogicalReads   = SUM(total_logical_reads),
               LogicalWrites  = SUM(total_logical_writes),
               OldestPlan     = MIN(creation_time),
               LastExec       = MAX(last_execution_time)
        FROM #qs GROUP BY query_hash),
    ranked AS (
        SELECT *, rc = ROW_NUMBER() OVER (ORDER BY CpuMs DESC),
                  rr = ROW_NUMBER() OVER (ORDER BY LogicalReads DESC),
                  rd = ROW_NUMBER() OVER (ORDER BY DurationMs DESC)
        FROM agg)
    SELECT query_hash, ExecutionCount, CpuMs, DurationMs, LogicalReads, LogicalWrites, OldestPlan, LastExec
    INTO #top
    FROM ranked
    WHERE rc <= 50 OR rr <= 50 OR rd <= 50;

    INSERT dbo.QuerySnapshot (SnapshotTime, QueryHash, ExecutionCount, CpuMs, DurationMs, LogicalReads, LogicalWrites, OldestPlanCreation, LastExecution)
    SELECT @now, query_hash, ExecutionCount, CpuMs, DurationMs, LogicalReads, LogicalWrites, OldestPlan, LastExec
    FROM #top;

    INSERT dbo.QueryText (QueryHash, DatabaseName, ObjectName, QueryText)
    SELECT t.query_hash, DB_NAME(pa.dbid), OBJECT_NAME(st.objectid, st.dbid),
           SUBSTRING(st.text, (s.statement_start_offset / 2) + 1,
                     ((CASE s.statement_end_offset WHEN -1 THEN DATALENGTH(st.text) ELSE s.statement_end_offset END
                       - s.statement_start_offset) / 2) + 1)
    FROM #top t
    CROSS APPLY (SELECT TOP (1) q.sql_handle, q.plan_handle, q.statement_start_offset, q.statement_end_offset
                 FROM #qs q WHERE q.query_hash = t.query_hash ORDER BY q.total_worker_time DESC) s
    OUTER APPLY sys.dm_exec_sql_text(s.sql_handle) st
    OUTER APPLY (SELECT dbid = CONVERT(int, pa.value) FROM sys.dm_exec_plan_attributes(s.plan_handle) pa WHERE pa.attribute = N'dbid') pa
    WHERE NOT EXISTS (SELECT 1 FROM dbo.QueryText x WHERE x.QueryHash = t.query_hash);
END
GO

IF OBJECT_ID(N'dbo.usp_CollectAvailabilityGroups', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectAvailabilityGroups AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectAvailabilityGroups
AS
BEGIN
    SET NOCOUNT ON;
    IF ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0) = 0 RETURN;

    DECLARE @now datetime = GETDATE();
    DECLARE @lag nvarchar(100) =
        CASE WHEN EXISTS (SELECT 1 FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.dm_hadr_database_replica_states') AND name = N'secondary_lag_seconds')
             THEN N'drs.secondary_lag_seconds' ELSE N'CAST(NULL AS bigint)' END;

    INSERT dbo.AgReplicaSample (SampleTime, AgName, ReplicaServer, ReplicaRole, AvailabilityMode, FailoverMode, ConnectedState, SyncHealth)
    SELECT @now, ag.name, ar.replica_server_name, ars.role_desc, ar.availability_mode_desc, ar.failover_mode_desc,
           ars.connected_state_desc, ars.synchronization_health_desc
    FROM sys.availability_groups ag
    JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id;

    DECLARE @sql nvarchar(max) = N'
    INSERT dbo.AgDatabaseSample (SampleTime, AgName, ReplicaServer, DatabaseName, IsLocal, ReplicaRole, AvailabilityMode, FailoverMode,
                                 SyncState, SyncHealth, IsSuspended, SuspendReason, LogSendQueueKB, RedoQueueKB, SecondaryLagSeconds, IsFailoverReady)
    SELECT @now, ag.name, ar.replica_server_name, ISNULL(adc.database_name, DB_NAME(drs.database_id)), drs.is_local, ars.role_desc,
           ar.availability_mode_desc, ar.failover_mode_desc, drs.synchronization_state_desc, drs.synchronization_health_desc,
           drs.is_suspended, drs.suspend_reason_desc, drs.log_send_queue_size, drs.redo_queue_size, ' + @lag + N', dcs.is_failover_ready
    FROM sys.dm_hadr_database_replica_states drs
    JOIN sys.availability_replicas ar ON ar.replica_id = drs.replica_id
    JOIN sys.availability_groups ag ON ag.group_id = drs.group_id
    LEFT JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = drs.replica_id
    LEFT JOIN sys.availability_databases_cluster adc ON adc.group_database_id = drs.group_database_id AND adc.group_id = drs.group_id
    LEFT JOIN sys.dm_hadr_database_replica_cluster_states dcs ON dcs.replica_id = drs.replica_id AND dcs.group_database_id = drs.group_database_id
    WHERE ISNULL(adc.database_name, DB_NAME(drs.database_id)) IS NOT NULL;';
    EXEC sp_executesql @sql, N'@now datetime', @now = @now;
END
GO

IF OBJECT_ID(N'dbo.usp_CollectBlocking', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectBlocking AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectBlocking
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime = GETDATE();
    DECLARE @thresholdMs bigint = dbo.fn_SettingInt('BlockingThresholdSeconds', 60) * 1000;

    SELECT r.session_id, r.blocking_session_id, r.wait_time, r.wait_type, r.database_id, r.sql_handle
    INTO #blocked
    FROM sys.dm_exec_requests r
    WHERE r.blocking_session_id <> 0 AND r.blocking_session_id <> r.session_id AND r.wait_time >= @thresholdMs;

    IF NOT EXISTS (SELECT 1 FROM #blocked) RETURN;

    INSERT dbo.BlockingSample (SampleTime, SessionId, BlockingSessionId, IsHeadBlocker, WaitSeconds, WaitType, DatabaseName,
                               LoginName, HostName, ProgramName, OpenTransactions, SqlText)
    SELECT @now, b.session_id, b.blocking_session_id, 0, b.wait_time / 1000, b.wait_type, DB_NAME(b.database_id),
           s.login_name, s.host_name, s.program_name, s.open_transaction_count, LEFT(t.text, 4000)
    FROM #blocked b
    JOIN sys.dm_exec_sessions s ON s.session_id = b.session_id
    OUTER APPLY sys.dm_exec_sql_text(b.sql_handle) t;

    -- head blockers: blocking others but not blocked themselves
    INSERT dbo.BlockingSample (SampleTime, SessionId, BlockingSessionId, IsHeadBlocker, WaitSeconds, WaitType, DatabaseName,
                               LoginName, HostName, ProgramName, OpenTransactions, SqlText)
    SELECT @now, s.session_id, NULL, 1, NULL, r.wait_type, DB_NAME(ISNULL(r.database_id, s.database_id)),
           s.login_name, s.host_name, s.program_name, s.open_transaction_count, LEFT(t.text, 4000)
    FROM sys.dm_exec_sessions s
    LEFT JOIN sys.dm_exec_requests r ON r.session_id = s.session_id
    OUTER APPLY (SELECT TOP (1) c.most_recent_sql_handle FROM sys.dm_exec_connections c WHERE c.session_id = s.session_id) c
    OUTER APPLY sys.dm_exec_sql_text(ISNULL(r.sql_handle, c.most_recent_sql_handle)) t
    WHERE s.session_id IN (SELECT blocking_session_id FROM #blocked)
      AND s.session_id NOT IN (SELECT session_id FROM #blocked);
END
GO

IF OBJECT_ID(N'dbo.usp_CollectDisk', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectDisk AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectDisk
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime = GETDATE();
    INSERT dbo.DiskSnapshot (SnapshotTime, VolumeMountPoint, LogicalVolumeName, TotalMB, FreeMB)
    SELECT @now, vs.volume_mount_point, MAX(vs.logical_volume_name),
           MAX(vs.total_bytes) / 1048576, MAX(vs.available_bytes) / 1048576
    FROM sys.master_files mf
    JOIN sys.databases d ON d.database_id = mf.database_id AND d.state = 0
    CROSS APPLY sys.dm_os_volume_stats(mf.database_id, mf.file_id) vs
    GROUP BY vs.volume_mount_point;
END
GO

IF OBJECT_ID(N'dbo.usp_CollectDatabaseFiles', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectDatabaseFiles AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectDatabaseFiles
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @now datetime = GETDATE(), @db sysname, @sql nvarchar(max);

    CREATE TABLE #used (DatabaseName sysname, FileId int, UsedMB decimal(18,2));

    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases
        WHERE state = 0 AND source_database_id IS NULL AND HAS_DBACCESS(name) = 1;
    OPEN dbs;
    FETCH NEXT FROM dbs INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            SET @sql = N'USE ' + QUOTENAME(@db) + N'; SELECT DB_NAME(), file_id, CAST(FILEPROPERTY(name, ''SpaceUsed'') / 128.0 AS decimal(18,2)) FROM sys.database_files;';
            INSERT #used (DatabaseName, FileId, UsedMB) EXEC (@sql);
        END TRY
        BEGIN CATCH
            -- e.g. non-readable AG secondary: sizes still come from sys.master_files
        END CATCH;
        FETCH NEXT FROM dbs INTO @db;
    END
    CLOSE dbs; DEALLOCATE dbs;

    INSERT dbo.DatabaseFileSnapshot (SnapshotTime, DatabaseName, FileId, FileType, LogicalName, PhysicalName, SizeMB, UsedMB, GrowthPages, IsPercentGrowth, MaxSizePages)
    SELECT @now, d.name, mf.file_id, mf.type_desc, mf.name, mf.physical_name, CAST(mf.size / 128.0 AS decimal(18,2)), u.UsedMB,
           mf.growth, mf.is_percent_growth, mf.max_size
    FROM sys.master_files mf
    JOIN sys.databases d ON d.database_id = mf.database_id
    LEFT JOIN #used u ON u.DatabaseName = d.name AND u.FileId = mf.file_id
    WHERE d.source_database_id IS NULL AND mf.type IN (0, 1);
END
GO

IF OBJECT_ID(N'dbo.usp_PurgeHistory', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_PurgeHistory AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_PurgeHistory
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @keep   datetime = DATEADD(day, -dbo.fn_SettingInt('RetentionDays', 90), GETDATE());
    DECLARE @sample datetime = DATEADD(day, -dbo.fn_SettingInt('SampleRetentionDays', 35), GETDATE());
    DECLARE @trend  datetime = DATEADD(day, -dbo.fn_SettingInt('TrendRetentionDays', 400), GETDATE());
    DECLARE @n int = 1;

    WHILE @n > 0 BEGIN DELETE TOP (10000) FROM dbo.AgDatabaseSample WHERE SampleTime < @sample; SET @n = @@ROWCOUNT; END
    SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (10000) FROM dbo.AgReplicaSample WHERE SampleTime < @sample; SET @n = @@ROWCOUNT; END
    SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (10000) FROM dbo.BlockingSample WHERE SampleTime < @sample; SET @n = @@ROWCOUNT; END
    SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (10000) FROM dbo.QuerySnapshot WHERE SnapshotTime < @sample; SET @n = @@ROWCOUNT; END
    SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (10000) FROM dbo.ErrorLogEntry WHERE LogDate < @keep; SET @n = @@ROWCOUNT; END
    SET @n = 1; WHILE @n > 0 BEGIN DELETE TOP (10000) FROM dbo.CollectionLog WHERE StartTime < @keep; SET @n = @@ROWCOUNT; END
    DELETE FROM dbo.JobFailure WHERE RunDateTime < @keep;
    DELETE FROM dbo.DiskSnapshot WHERE SnapshotTime < @trend;
    DELETE FROM dbo.DatabaseFileSnapshot WHERE SnapshotTime < @trend;
    DELETE FROM dbo.QueryText WHERE NOT EXISTS (SELECT 1 FROM dbo.QuerySnapshot s WHERE s.QueryHash = QueryText.QueryHash) AND FirstSeen < @sample;
    DELETE FROM dbo.WeeklyReport WHERE GeneratedAt < DATEADD(day, -400, GETDATE());
    DELETE FROM dbo.PatchLevel WHERE CollectedAt < @trend;
END
GO

/*=============================================================================
  6b. PATCHING
=============================================================================*/
IF OBJECT_ID(N'dbo.usp_CollectPatchLevel', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_CollectPatchLevel AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_CollectPatchLevel
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @key nvarchar(200) = N'SOFTWARE\Microsoft\Windows NT\CurrentVersion';
    DECLARE @build nvarchar(50), @ubr int, @type nvarchar(50), @name nvarchar(200), @display nvarchar(50);

    IF NOT EXISTS (SELECT 1 FROM sys.all_objects WHERE name = N'dm_os_host_info')
       OR EXISTS (SELECT 1 FROM sys.dm_os_host_info WHERE host_platform = N'Windows')
    BEGIN
        BEGIN TRY
            EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @key, @value_name = N'CurrentBuild',     @value = @build OUTPUT;
            EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @key, @value_name = N'UBR',              @value = @ubr OUTPUT;
            EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @key, @value_name = N'InstallationType', @value = @type OUTPUT;
            EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @key, @value_name = N'ProductName',      @value = @name OUTPUT;
            EXEC master.dbo.xp_regread @rootkey = N'HKEY_LOCAL_MACHINE', @key = @key, @value_name = N'DisplayVersion',   @value = @display OUTPUT;
        END TRY
        BEGIN CATCH
        END CATCH;
    END

    INSERT dbo.PatchLevel (CollectedAt, OsProductName, OsInstallationType, OsDisplayVersion, OsCurrentBuild, OsUbr, SqlVersion, SqlUpdateLevel, SqlUpdateReference)
    VALUES (GETDATE(), @name, @type, @display, TRY_CONVERT(int, @build), @ubr,
            CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')),
            CONVERT(nvarchar(50), SERVERPROPERTY('ProductUpdateLevel')),
            CONVERT(nvarchar(50), SERVERPROPERTY('ProductUpdateReference')));
END
GO

IF OBJECT_ID(N'dbo.usp_PatchReference_Clear', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_PatchReference_Clear AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_PatchReference_Clear
    @Product varchar(20)
AS
BEGIN
    SET NOCOUNT ON;
    DELETE FROM dbo.PatchReference WHERE Product = @Product;
END
GO

IF OBJECT_ID(N'dbo.usp_PatchReference_Add', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_PatchReference_Add AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_PatchReference_Add
    @Product     varchar(20),
    @ProductName nvarchar(100),
    @Major       int,
    @Minor       int,
    @BuildNumber int,
    @Revision    int,
    @ServicePack nvarchar(30) = NULL,
    @UpdateName  nvarchar(60) = NULL,
    @CuNumber    int          = NULL,
    @KB          varchar(20)  = NULL,
    @ReleaseDate date         = NULL,
    @Source      nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT dbo.PatchReference (Product, ProductName, Major, Minor, BuildNumber, Revision, ServicePack, UpdateName, CuNumber, KB, ReleaseDate, Source)
    VALUES (@Product, @ProductName, @Major, @Minor, @BuildNumber, @Revision, @ServicePack, @UpdateName, @CuNumber, @KB, @ReleaseDate, @Source);
END
GO

/* Compares this server with the reference data. One row per component; Severity is OK | Info | Warning | Critical.
   Windows: the monthly cumulative security update for the OS, judged by build number (CurrentBuild.UBR).
   SQL Server: position on the servicing branch (CU or GDR) the instance is on. */
IF OBJECT_ID(N'dbo.usp_PatchStatus', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_PatchStatus AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_PatchStatus
    @SqlVersion varchar(30) = NULL   -- testing only: evaluate this build instead of the running one
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Today date = CAST(GETDATE() AS date);
    DECLARE @R TABLE (SortOrder int, Component varchar(20), Installed nvarchar(100), InstalledUpdate nvarchar(100), Latest nvarchar(100),
                      LatestUpdate nvarchar(100), LatestReleased date, Status nvarchar(100), Severity varchar(10),
                      Detail nvarchar(1000), Recommendation nvarchar(1000), ReferenceLoaded datetime);

    /*---------------------------------------------------------- SQL Server */
    DECLARE @Ver varchar(30) = ISNULL(@SqlVersion, CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')));
    DECLARE @Maj int = CONVERT(int, PARSENAME(@Ver, 4)), @Bld int = CONVERT(int, PARSENAME(@Ver, 2)), @Rev int = CONVERT(int, PARSENAME(@Ver, 1));
    DECLARE @SqlLoaded datetime = (SELECT MAX(LoadedAt) FROM dbo.PatchReference WHERE Product = 'SQL Server' AND Major = @Maj);
    DECLARE @Grace int = CONVERT(int, dbo.fn_SettingInt('SqlPatchGraceDays', 30)),
            @CuCrit int = CONVERT(int, dbo.fn_SettingInt('SqlCuBehindCritical', 3)),
            @SecSev varchar(10) = CASE WHEN dbo.fn_Setting('SqlSecurityUpdateSeverity') = N'Warning' THEN 'Warning' ELSE 'Info' END;

    IF @SqlLoaded IS NULL
        INSERT @R VALUES (1, 'SQL Server', @Ver, CONVERT(nvarchar(50), SERVERPROPERTY('ProductUpdateLevel')), NULL, NULL, NULL, N'Not checked', 'Info',
                          N'No build reference data is loaded for this SQL Server version.', N'Run Update-PatchReference.ps1 to load the latest build list from Microsoft.', NULL);
    ELSE
    BEGIN
        -- where the installed build sits: exact match, or the nearest published build below it
        DECLARE @InstUpdate nvarchar(60), @InstCu int, @InstSp nvarchar(30), @InstDate date, @Exact bit;
        SELECT TOP (1) @InstUpdate = UpdateName, @InstCu = CuNumber, @InstSp = ISNULL(ServicePack, N'None'), @InstDate = ReleaseDate,
                       @Exact = CASE WHEN BuildNumber = @Bld AND Revision = @Rev THEN 1 ELSE 0 END
        FROM dbo.PatchReference
        WHERE Product = 'SQL Server' AND Major = @Maj AND (BuildNumber < @Bld OR (BuildNumber = @Bld AND Revision <= @Rev))
        ORDER BY BuildNumber DESC, Revision DESC;
        SET @InstSp = ISNULL(@InstSp, N'None');

        DECLARE @Track varchar(3) =
            CASE WHEN @InstUpdate LIKE N'%CU%' THEN 'CU'
                 WHEN EXISTS (SELECT 1 FROM dbo.PatchReference WHERE Product = 'SQL Server' AND Major = @Maj AND ISNULL(ServicePack, N'None') = @InstSp
                              AND CuNumber IS NOT NULL AND (BuildNumber > @Bld OR (BuildNumber = @Bld AND Revision > @Rev))) AND ISNULL(@InstUpdate, N'') NOT LIKE N'%GDR%' THEN 'CU'
                 ELSE 'GDR' END;

        DECLARE @LName nvarchar(60), @LBld int, @LRev int, @LKB varchar(20), @LDate date, @LCu int, @LAll int;
        DECLARE @AName nvarchar(60), @ABld int, @ARev int, @AKB varchar(20), @ADate date;
        DECLARE @InstalledText nvarchar(100) = CASE WHEN @Exact = 1 THEN @InstUpdate WHEN @InstUpdate IS NOT NULL THEN @InstUpdate + N' (or later, unlisted build)' ELSE N'Unlisted build' END;

        IF @Track = 'CU'
        BEGIN
            -- latest plain CU, and latest release on the CU branch (may be "CU + GDR")
            SELECT TOP (1) @LName = UpdateName, @LBld = BuildNumber, @LRev = Revision, @LKB = KB, @LDate = ReleaseDate, @LCu = CuNumber
            FROM dbo.PatchReference
            WHERE Product = 'SQL Server' AND Major = @Maj AND ISNULL(ServicePack, N'None') = @InstSp AND CuNumber IS NOT NULL AND UpdateName NOT LIKE N'%GDR%'
            ORDER BY BuildNumber DESC, Revision DESC;
            SELECT TOP (1) @AName = UpdateName, @ABld = BuildNumber, @ARev = Revision, @AKB = KB, @ADate = ReleaseDate
            FROM dbo.PatchReference
            WHERE Product = 'SQL Server' AND Major = @Maj AND ISNULL(ServicePack, N'None') = @InstSp AND CuNumber IS NOT NULL
            ORDER BY BuildNumber DESC, Revision DESC;

            IF @Bld > @ABld OR (@Bld = @ABld AND @Rev >= @ARev)
                INSERT @R VALUES (1, 'SQL Server', @Ver, @InstalledText, CONVERT(nvarchar(20), @Maj) + N'.0.' + CONVERT(nvarchar(10), @ABld) + N'.' + CONVERT(nvarchar(10), @ARev), @AName, @ADate,
                                  N'Up to date', 'OK', N'On the latest cumulative update and security release.', NULL, @SqlLoaded);
            ELSE IF @Bld > @LBld OR (@Bld = @LBld AND @Rev >= @LRev)
                INSERT @R VALUES (1, 'SQL Server', @Ver, @InstalledText, CONVERT(nvarchar(20), @Maj) + N'.0.' + CONVERT(nvarchar(10), @ABld) + N'.' + CONVERT(nvarchar(10), @ARev), @AName, @ADate,
                                  N'Latest CU - security update available', @SecSev,
                                  N'On the latest cumulative update (' + @LName + N'). ' + @AName + N' (KB' + ISNULL(@AKB, N'?') + N', released ' + CONVERT(nvarchar(11), @ADate, 106) + N') adds security fixes on top of it.',
                                  N'Apply KB' + ISNULL(@AKB, N'?') + N' at the next maintenance window.', @SqlLoaded);
            ELSE
            BEGIN
                SET @LAll = @LCu - ISNULL(@InstCu, 0);
                INSERT @R VALUES (1, 'SQL Server', @Ver, @InstalledText, CONVERT(nvarchar(20), @Maj) + N'.0.' + CONVERT(nvarchar(10), @ABld) + N'.' + CONVERT(nvarchar(10), @ARev), @AName, @ADate,
                                  CASE WHEN @InstCu IS NULL THEN N'No cumulative update installed' ELSE CONVERT(nvarchar(10), @LAll) + N' CU' + CASE WHEN @LAll = 1 THEN N'' ELSE N's' END + N' behind' END,
                                  CASE WHEN @LAll >= @CuCrit THEN 'Critical' WHEN DATEDIFF(day, @LDate, @Today) > @Grace THEN 'Warning' ELSE 'Info' END,
                                  N'Installed: ' + ISNULL(@InstUpdate, N'RTM') + ISNULL(N' (released ' + CONVERT(nvarchar(11), @InstDate, 106) + N')', N'')
                                  + N'. Latest cumulative update: ' + @LName + N' (KB' + ISNULL(@LKB, N'?') + N', released ' + CONVERT(nvarchar(11), @LDate, 106) + N')'
                                  + CASE WHEN @AName <> @LName THEN N'; latest security release on that branch: ' + @AName + N' (KB' + ISNULL(@AKB, N'?') + N').' ELSE N'.' END,
                                  N'Plan to apply ' + CASE WHEN @AName <> @LName THEN @AName + N' (KB' + ISNULL(@AKB, N'?') + N')' ELSE @LName + N' (KB' + ISNULL(@LKB, N'?') + N')' END
                                  + N' after testing. Molehill Data Services can apply it as planned out-of-hours work.', @SqlLoaded);
            END
        END
        ELSE
        BEGIN
            -- GDR (security-only) branch; SQL Server 2016 SP3 also has a parallel "Azure Connect feature pack" branch
            DECLARE @Family int = CASE WHEN @InstUpdate LIKE N'%Azure Connect%' THEN 1 ELSE 0 END;
            SELECT TOP (1) @AName = UpdateName, @ABld = BuildNumber, @ARev = Revision, @AKB = KB, @ADate = ReleaseDate
            FROM dbo.PatchReference
            WHERE Product = 'SQL Server' AND Major = @Maj AND ISNULL(ServicePack, N'None') = @InstSp AND CuNumber IS NULL
              AND (UpdateName LIKE N'%GDR%' OR UpdateName LIKE N'%Security%')
              AND CASE WHEN UpdateName LIKE N'%Azure Connect%' THEN 1 ELSE 0 END = @Family
            ORDER BY BuildNumber DESC, Revision DESC;

            IF @ABld IS NULL OR @Bld > @ABld OR (@Bld = @ABld AND @Rev >= @ARev)
                INSERT @R VALUES (1, 'SQL Server', @Ver, @InstalledText, CASE WHEN @ABld IS NOT NULL THEN CONVERT(nvarchar(20), @Maj) + N'.0.' + CONVERT(nvarchar(10), @ABld) + N'.' + CONVERT(nvarchar(10), @ARev) END,
                                  @AName, @ADate, N'Up to date (GDR branch)', 'OK', N'On the latest security (GDR) release for this branch.', NULL, @SqlLoaded);
            ELSE
            BEGIN
                SET @LAll = (SELECT COUNT(*) FROM dbo.PatchReference
                             WHERE Product = 'SQL Server' AND Major = @Maj AND ISNULL(ServicePack, N'None') = @InstSp AND CuNumber IS NULL
                               AND (UpdateName LIKE N'%GDR%' OR UpdateName LIKE N'%Security%')
                               AND CASE WHEN UpdateName LIKE N'%Azure Connect%' THEN 1 ELSE 0 END = @Family
                               AND (BuildNumber > @Bld OR (BuildNumber = @Bld AND Revision > @Rev)));
                INSERT @R VALUES (1, 'SQL Server', @Ver, @InstalledText, CONVERT(nvarchar(20), @Maj) + N'.0.' + CONVERT(nvarchar(10), @ABld) + N'.' + CONVERT(nvarchar(10), @ARev), @AName, @ADate,
                                  CONVERT(nvarchar(10), @LAll) + N' security update' + CASE WHEN @LAll = 1 THEN N'' ELSE N's' END + N' behind (GDR branch)',
                                  CASE WHEN @LAll >= 2 THEN 'Critical' WHEN DATEDIFF(day, @ADate, @Today) > @Grace THEN 'Warning' ELSE 'Info' END,
                                  N'This instance is on the GDR (security fixes only) branch. Latest GDR: KB' + ISNULL(@AKB, N'?') + N' (released ' + CONVERT(nvarchar(11), @ADate, 106) + N').',
                                  N'Apply KB' + ISNULL(@AKB, N'?') + N'. Consider moving to the cumulative update branch, which Microsoft recommends for ongoing servicing.', @SqlLoaded);
            END
        END
    END

    /*---------------------------------------------------------- Windows */
    DECLARE @OsName nvarchar(200), @OsType nvarchar(50), @OsBuild int, @OsUbr int, @OsAt datetime;
    SELECT TOP (1) @OsName = OsProductName, @OsType = OsInstallationType, @OsBuild = OsCurrentBuild, @OsUbr = OsUbr, @OsAt = CollectedAt
    FROM dbo.PatchLevel ORDER BY CollectedAt DESC;
    DECLARE @OsText nvarchar(100) = CASE WHEN @OsBuild IS NOT NULL THEN CONVERT(nvarchar(10), @OsBuild) + ISNULL(N'.' + CONVERT(nvarchar(10), @OsUbr), N'') END;
    DECLARE @WinLoaded datetime = (SELECT MAX(LoadedAt) FROM dbo.PatchReference WHERE Product = 'Windows Server');
    DECLARE @WGrace int = CONVERT(int, dbo.fn_SettingInt('WindowsPatchGraceDays', 14));

    IF EXISTS (SELECT 1 FROM sys.all_objects WHERE name = N'dm_os_host_info')
       AND NOT EXISTS (SELECT 1 FROM sys.dm_os_host_info WHERE host_platform = N'Windows')
        INSERT @R VALUES (2, 'Windows', NULL, NULL, NULL, NULL, NULL, N'Not checked (not Windows)', 'Info', N'SQL Server is not running on Windows, so Windows patching is not checked.', NULL, NULL);
    ELSE IF @OsBuild IS NULL
        INSERT @R VALUES (2, 'Windows', NULL, NULL, NULL, NULL, NULL, N'Not collected yet', 'Info', N'The operating system build has not been collected yet (daily collection).', NULL, NULL);
    ELSE IF ISNULL(@OsType, N'') NOT LIKE N'Server%'
        INSERT @R VALUES (2, 'Windows', @OsText, @OsName, NULL, NULL, NULL, N'Not checked (not Windows Server)', 'Info',
                          N'Security update checks cover Windows Server only (this host reports ' + ISNULL(@OsName, N'?') + N', ' + ISNULL(@OsType, N'?') + N').', NULL, NULL);
    ELSE IF @OsBuild < 10000 OR @OsUbr IS NULL
        INSERT @R VALUES (2, 'Windows', @OsText, @OsName, NULL, NULL, NULL, N'Not checked (Windows Server 2012 / 2012 R2)', 'Info',
                          N'Windows Server 2012 and 2012 R2 do not record their monthly update level in a way that can be compared automatically.',
                          N'Confirm in Windows Update that the latest monthly rollup is installed.', NULL);
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.PatchReference WHERE Product = 'Windows Server' AND BuildNumber = @OsBuild)
        INSERT @R VALUES (2, 'Windows', @OsText, @OsName, NULL, NULL, NULL, N'Not checked', 'Info',
                          N'No security update reference data is loaded for Windows build ' + CONVERT(nvarchar(10), @OsBuild) + N'.',
                          N'Run Update-PatchReference.ps1 to load the latest security updates from Microsoft.', @WinLoaded);
    ELSE
    BEGIN
        DECLARE @WName nvarchar(100), @WRev int, @WKB varchar(20), @WDate date, @WSource nvarchar(200), @Missing int, @Loaded int, @OldestMissing date;
        SELECT TOP (1) @WName = ProductName, @WRev = Revision, @WKB = KB, @WDate = ReleaseDate, @WSource = Source
        FROM dbo.PatchReference WHERE Product = 'Windows Server' AND BuildNumber = @OsBuild ORDER BY ReleaseDate DESC, Revision DESC;
        SELECT @Missing = SUM(CASE WHEN Revision > @OsUbr THEN 1 ELSE 0 END), @Loaded = COUNT(*),
               @OldestMissing = MIN(CASE WHEN Revision > @OsUbr THEN ReleaseDate END)
        FROM dbo.PatchReference WHERE Product = 'Windows Server' AND BuildNumber = @OsBuild;

        INSERT @R VALUES (2, 'Windows', @OsText, ISNULL(@OsName, @WName),
                          CONVERT(nvarchar(10), @OsBuild) + N'.' + CONVERT(nvarchar(10), @WRev), N'KB' + ISNULL(@WKB, N'?') + N' (' + ISNULL(@WSource, N'') + N' security update)', @WDate,
                          CASE WHEN @Missing = 0 THEN N'Up to date'
                               ELSE CONVERT(nvarchar(10), @Missing) + N' monthly security update' + CASE WHEN @Missing = 1 THEN N'' ELSE N's' END + N' missing' END,
                          CASE WHEN @Missing = 0 THEN 'OK'
                               WHEN @Missing >= 2 THEN 'Critical'
                               WHEN DATEDIFF(day, @WDate, @Today) > @WGrace THEN 'Warning'
                               ELSE 'Info' END,
                          CASE WHEN @Missing = 0 THEN N'The latest Windows security update (KB' + ISNULL(@WKB, N'?') + N') is installed.'
                               ELSE N'Installed OS build ' + @OsText + N'. The latest security update is KB' + ISNULL(@WKB, N'?') + N' (build ' + CONVERT(nvarchar(10), @OsBuild) + N'.' + CONVERT(nvarchar(10), @WRev)
                                  + N', released ' + CONVERT(nvarchar(11), @WDate, 106) + N'). Missing ' + CONVERT(nvarchar(10), @Missing) + N' of the last ' + CONVERT(nvarchar(10), @Loaded)
                                  + N' monthly security updates, the oldest from ' + CONVERT(nvarchar(11), @OldestMissing, 106) + N'.' END,
                          CASE WHEN @Missing = 0 THEN NULL
                               ELSE N'Install the latest cumulative security update (KB' + ISNULL(@WKB, N'?') + N') via Windows Update / WSUS and restart. Cumulative updates include all earlier security fixes.' END,
                          @WinLoaded);
    END

    /*---------------------------------------------------------- Reference freshness */
    DECLARE @RefLoaded datetime = (SELECT MAX(LoadedAt) FROM dbo.PatchReference), @MaxAge int = CONVERT(int, dbo.fn_SettingInt('PatchReferenceMaxAgeDays', 40));
    IF @RefLoaded IS NOT NULL AND DATEDIFF(day, @RefLoaded, GETDATE()) > @MaxAge
        INSERT @R VALUES (3, 'Reference data', NULL, NULL, NULL, NULL, NULL, N'Out of date', 'Warning',
                          N'Patch reference data was last refreshed ' + CONVERT(nvarchar(11), @RefLoaded, 106) + N', so newer updates may not be taken into account.',
                          N'Run Update-PatchReference.ps1 (or Export-WeeklyReports.ps1 -UpdatePatchReference).', @RefLoaded);

    SELECT SortOrder, Component, Installed, InstalledUpdate, Latest, LatestUpdate, LatestReleased, Status, Severity, Detail, Recommendation, ReferenceLoaded
    FROM @R ORDER BY SortOrder;
END
GO

/*=============================================================================
  7. WEEKLY REPORT
=============================================================================*/
IF OBJECT_ID(N'dbo.usp_ShowReport', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_ShowReport @ReportId int = NULL AS RETURN 0;');
GO
IF OBJECT_ID(N'dbo.usp_BuildWeeklyReport', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_BuildWeeklyReport AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_BuildWeeklyReport
    @DaysBack      int = 7,
    @SendEmail     bit = 0,
    @ReturnResults bit = 1
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now      datetime = GETDATE();
    DECLARE @Start    datetime = DATEADD(day, -@DaysBack, @Now);
    DECLARE @Today    date     = CAST(@Now AS date);
    DECLARE @Client   nvarchar(200) = ISNULL(NULLIF(dbo.fn_Setting('ClientName'), N''), N'(client name not set)');
    DECLARE @Instance nvarchar(200) = ISNULL(NULLIF(dbo.fn_Setting('InstanceDisplayName'), N''), ISNULL(@@SERVERNAME, CONVERT(nvarchar(128), SERVERPROPERTY('ServerName'))));
    DECLARE @RiskAccepted nvarchar(400) = ISNULL(dbo.fn_Setting('UnsupportedRiskAccepted'), N'');
    DECLARE @List nvarchar(max), @Cnt int;

    CREATE TABLE #F (
        Seq            int IDENTITY(1,1),
        Section        varchar(30)    NOT NULL,
        Severity       varchar(10)    NOT NULL,
        Item           nvarchar(400)  NOT NULL,
        Detail         nvarchar(max)  NULL,
        Recommendation nvarchar(1000) NULL);

    /*--------------------------------------------------------------- SERVER */
    DECLARE @ProductVersion nvarchar(50) = CONVERT(nvarchar(50), SERVERPROPERTY('ProductVersion'));
    DECLARE @Major int = CONVERT(int, PARSENAME(@ProductVersion, 4));
    DECLARE @EngineEdition int = CONVERT(int, SERVERPROPERTY('EngineEdition'));
    DECLARE @Edition nvarchar(200) = CONVERT(nvarchar(200), SERVERPROPERTY('Edition'));
    DECLARE @Level nvarchar(100) = CONVERT(nvarchar(50), SERVERPROPERTY('ProductLevel')) + ISNULL(N' ' + CONVERT(nvarchar(50), SERVERPROPERTY('ProductUpdateLevel')), N'');
    DECLARE @SqlProduct nvarchar(100), @SqlMainEnd date, @SqlExtEnd date;
    SELECT TOP (1) @SqlProduct = ProductName, @SqlMainEnd = MainstreamEnd, @SqlExtEnd = ExtendedEnd
    FROM dbo.ProductLifecycle WHERE Product = 'SQL Server' AND MajorVersion = @Major;
    SET @SqlProduct = ISNULL(@SqlProduct, N'SQL Server (version ' + CONVERT(nvarchar(10), @Major) + N')');

    DECLARE @Ver nvarchar(4000) = @@VERSION, @OsName nvarchar(200);
    IF CHARINDEX(N' on ', @Ver) > 0
    BEGIN
        SET @OsName = SUBSTRING(@Ver, CHARINDEX(N' on ', @Ver) + 4, 200);
        SET @OsName = RTRIM(LEFT(@OsName, CHARINDEX(N' <', @OsName + N' <') - 1));
    END
    DECLARE @OsProduct nvarchar(100), @OsMainEnd date, @OsExtEnd date;
    SELECT TOP (1) @OsProduct = ProductName, @OsMainEnd = MainstreamEnd, @OsExtEnd = ExtendedEnd
    FROM dbo.ProductLifecycle
    WHERE Product = 'Windows Server'
      AND (@OsName LIKE N'%' + ProductName + N' %' OR @OsName LIKE N'%' + ProductName)
    ORDER BY LEN(ProductName) DESC;

    DECLARE @StartTime datetime, @Cpus int, @MemGB decimal(10,1);
    SELECT @StartTime = sqlserver_start_time, @Cpus = cpu_count, @MemGB = CAST(physical_memory_kb / 1048576.0 AS decimal(10,1)) FROM sys.dm_os_sys_info;
    DECLARE @MaxMem bigint = (SELECT CONVERT(bigint, value_in_use) FROM sys.configurations WHERE name = N'max server memory (MB)');
    DECLARE @IsClustered int = ISNULL(CONVERT(int, SERVERPROPERTY('IsClustered')), 0);
    DECLARE @IsHadr int = ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0);

    DECLARE @HaDesc nvarchar(1000) = N'';
    IF @IsHadr = 1
        SET @HaDesc = ISNULL(STUFF((SELECT N', ' + ag.name + N' (' + ISNULL(ars.role_desc, N'?') + N')'
                                    FROM sys.availability_groups ag
                                    JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
                                    JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id AND ars.is_local = 1
                                    FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''), N'');
    SET @HaDesc = CASE WHEN @HaDesc <> N'' THEN N'Availability Groups: ' + @HaDesc ELSE N'' END
                + CASE WHEN @IsClustered = 1 THEN CASE WHEN @HaDesc <> N'' THEN N'; ' ELSE N'' END
                       + N'Failover Cluster Instance, active node ' + CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS')) ELSE N'' END;
    IF EXISTS (SELECT 1 FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL)
        SET @HaDesc = @HaDesc + CASE WHEN @HaDesc <> N'' THEN N'; ' ELSE N'' END + N'Database mirroring';
    IF EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_monitor_primary) OR EXISTS (SELECT 1 FROM msdb.dbo.log_shipping_monitor_secondary)
        SET @HaDesc = @HaDesc + CASE WHEN @HaDesc <> N'' THEN N'; ' ELSE N'' END + N'Log shipping';
    IF @HaDesc = N'' SET @HaDesc = N'Standalone instance';

    IF @SqlExtEnd IS NOT NULL AND @SqlExtEnd < @Today
        INSERT #F VALUES ('Server', 'Critical', N'Unsupported SQL Server version',
            @SqlProduct + N' left Microsoft extended support on ' + CONVERT(nvarchar(11), @SqlExtEnd, 106) + N'. No security updates or product fixes are available from Microsoft.'
            + CASE WHEN @RiskAccepted <> N'' THEN N' Risk acceptance recorded: ' + @RiskAccepted + N'.' ELSE N' No client risk acceptance is recorded on this instance.' END,
            N'Plan an upgrade or migration to a supported version. Molehill Data Services can scope and quote this as project work.');
    ELSE IF @SqlExtEnd IS NOT NULL AND @SqlExtEnd < DATEADD(month, 12, @Today)
        INSERT #F VALUES ('Server', 'Warning', N'SQL Server version approaching end of support',
            @SqlProduct + N' leaves Microsoft extended support on ' + CONVERT(nvarchar(11), @SqlExtEnd, 106) + N'.',
            N'Start planning an upgrade now to avoid running an unsupported version.');
    ELSE IF @SqlMainEnd IS NOT NULL AND @SqlMainEnd < @Today
        INSERT #F VALUES ('Server', 'Info', N'SQL Server version in extended support',
            @SqlProduct + N' is in extended support (security fixes only) until ' + CONVERT(nvarchar(11), @SqlExtEnd, 106) + N'.', NULL);

    IF @OsExtEnd IS NOT NULL AND @OsExtEnd < @Today
        INSERT #F VALUES ('Server', 'Critical', N'Unsupported operating system',
            @OsProduct + N' left Microsoft extended support on ' + CONVERT(nvarchar(11), @OsExtEnd, 106) + N'.'
            + CASE WHEN @RiskAccepted <> N'' THEN N' Risk acceptance recorded: ' + @RiskAccepted + N'.' ELSE N'' END,
            N'Plan a migration to a supported Windows Server version.');
    ELSE IF @OsExtEnd IS NOT NULL AND @OsExtEnd < DATEADD(month, 12, @Today)
        INSERT #F VALUES ('Server', 'Warning', N'Operating system approaching end of support',
            @OsProduct + N' leaves Microsoft extended support on ' + CONVERT(nvarchar(11), @OsExtEnd, 106) + N'.',
            N'Start planning an operating system upgrade or migration.');

    IF @StartTime > @Start
        INSERT #F VALUES ('Server', 'Info', N'SQL Server restarted during the period',
            N'Service started ' + dbo.fn_Date(@StartTime) + N'. Query performance data only covers activity since the restart.', NULL);

    /*-------------------------------------------------------------- BACKUPS */
    CREATE TABLE #bk (DatabaseName sysname, RecoveryModel nvarchar(60), StateDesc nvarchar(60), IsAgDatabase bit, IsPreferred bit,
                      LastFull datetime, LastDiff datetime, LastLog datetime, LastFullDevice nvarchar(260), Evaluate bit,
                      FullTool nvarchar(30) NULL, LogTools nvarchar(200) NULL);
    INSERT #bk (DatabaseName, RecoveryModel, StateDesc, IsAgDatabase, IsPreferred, LastFull, LastDiff, LastLog, Evaluate)
    SELECT d.name, d.recovery_model_desc, d.state_desc,
           CASE WHEN d.replica_id IS NULL THEN 0 ELSE 1 END,
           CONVERT(bit, ISNULL(sys.fn_hadr_backup_is_preferred_replica(d.name), 1)),
           b.LastFull, b.LastDiff, b.LastLog, 0
    FROM sys.databases d
    LEFT JOIN (SELECT database_name,
                      LastFull = MAX(CASE WHEN type = 'D' THEN backup_finish_date END),
                      LastDiff = MAX(CASE WHEN type = 'I' THEN backup_finish_date END),
                      LastLog  = MAX(CASE WHEN type = 'L' THEN backup_finish_date END)
               FROM msdb.dbo.backupset
               WHERE backup_finish_date >= DATEADD(day, -400, @Now)
               GROUP BY database_name) b ON b.database_name COLLATE DATABASE_DEFAULT = d.name COLLATE DATABASE_DEFAULT
    WHERE d.database_id <> 2 AND d.source_database_id IS NULL;

    UPDATE bk SET LastFullDevice = x.physical_device_name, FullTool = x.Tool
    FROM #bk bk
    CROSS APPLY (SELECT TOP (1) mf.physical_device_name, Tool = dbo.fn_BackupTool(b.user_name, b.is_snapshot, mf.device_type, ms.software_name)
                 FROM msdb.dbo.backupset b
                 JOIN msdb.dbo.backupmediafamily mf ON mf.media_set_id = b.media_set_id
                 LEFT JOIN msdb.dbo.backupmediaset ms ON ms.media_set_id = b.media_set_id
                 WHERE b.database_name COLLATE DATABASE_DEFAULT = bk.DatabaseName COLLATE DATABASE_DEFAULT AND b.type = 'D'
                 ORDER BY b.backup_finish_date DESC) x;

    -- every tool that took log backups during the period
    SELECT DISTINCT DatabaseName = b.database_name COLLATE DATABASE_DEFAULT,
           Tool = dbo.fn_BackupTool(b.user_name, b.is_snapshot, mf.device_type, ms.software_name)
    INTO #logtools
    FROM msdb.dbo.backupset b
    OUTER APPLY (SELECT TOP (1) x.device_type FROM msdb.dbo.backupmediafamily x WHERE x.media_set_id = b.media_set_id) mf
    LEFT JOIN msdb.dbo.backupmediaset ms ON ms.media_set_id = b.media_set_id
    WHERE b.type = 'L' AND b.backup_finish_date >= @Start;

    UPDATE bk SET LogTools = STUFF((SELECT N' + ' + lt.Tool FROM #logtools lt WHERE lt.DatabaseName = bk.DatabaseName COLLATE DATABASE_DEFAULT
                                    ORDER BY lt.Tool FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 3, N'')
    FROM #bk bk;

    UPDATE #bk SET Evaluate = 1 WHERE StateDesc = N'ONLINE' AND NOT (IsAgDatabase = 1 AND IsPreferred = 0);

    DECLARE @FullMaxH bigint = dbo.fn_SettingInt('BackupFullMaxAgeHours', 170),
            @DiffMaxH bigint = dbo.fn_SettingInt('BackupFullOrDiffMaxAgeHours', 26),
            @LogMaxM  bigint = dbo.fn_SettingInt('BackupLogMaxAgeMinutes', 90);

    SET @List = STUFF((SELECT N', ' + DatabaseName FROM #bk WHERE Evaluate = 1 AND LastFull IS NULL ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Backups', 'Critical', N'Databases with no full backup', N'No full backup found in msdb history: ' + @List + N'.',
                          N'Take a full backup as soon as possible and add these databases to the backup schedule.');

    SET @List = STUFF((SELECT N', ' + DatabaseName + N' (' + dbo.fn_Age(LastFull, @Now) + N')' FROM #bk
                       WHERE Evaluate = 1 AND LastFull < DATEADD(hour, -@FullMaxH, @Now) ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Backups', 'Critical', N'Full backups overdue', N'Last full backup older than ' + CONVERT(nvarchar(10), @FullMaxH) + N' hours: ' + @List + N'.',
                          N'Check the backup job/tool is running and succeeding for these databases.');

    SET @List = STUFF((SELECT N', ' + DatabaseName + N' (' + dbo.fn_Age(CASE WHEN LastDiff > LastFull THEN LastDiff ELSE LastFull END, @Now) + N')' FROM #bk
                       WHERE Evaluate = 1 AND LastFull >= DATEADD(hour, -@FullMaxH, @Now)
                         AND (CASE WHEN LastDiff > LastFull THEN LastDiff ELSE LastFull END) < DATEADD(hour, -@DiffMaxH, @Now)
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Backups', 'Warning', N'No full or differential backup in the last ' + CONVERT(nvarchar(10), @DiffMaxH) + N' hours', @List + N'.',
                          N'Confirm a daily full or differential backup is scheduled and succeeding.');

    SET @List = STUFF((SELECT N', ' + DatabaseName + N' (' + dbo.fn_Age(LastLog, @Now) + N')' FROM #bk
                       WHERE Evaluate = 1 AND RecoveryModel IN (N'FULL', N'BULK_LOGGED') AND DatabaseName <> N'model'
                         AND (LastLog IS NULL OR LastLog < DATEADD(minute, -@LogMaxM, @Now))
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Backups', 'Critical', N'Transaction log backups missing or overdue',
                          N'FULL/BULK_LOGGED recovery databases without a log backup in ' + CONVERT(nvarchar(10), @LogMaxM) + N' minutes: ' + @List + N'.',
                          N'Schedule regular log backups (point-in-time recovery is at risk and logs will keep growing), or switch to SIMPLE recovery if point-in-time recovery is not required.');

    SET @List = STUFF((SELECT N', ' + bk.DatabaseName FROM #bk bk
                       WHERE bk.Evaluate = 1 AND bk.LastFullDevice LIKE N'[A-Za-z]:\%'
                         AND EXISTS (SELECT 1 FROM sys.master_files mf WHERE mf.database_id = DB_ID(bk.DatabaseName)
                                     AND LEFT(mf.physical_name, 2) = LEFT(bk.LastFullDevice, 2))
                       ORDER BY bk.DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Backups', 'Warning', N'Backups stored on the same drive as database files',
                          N'Latest full backup written to a drive that also holds the database files: ' + @List + N'.',
                          N'A single disk failure could lose both the database and its backups. Copy backups to separate storage or off-server.');

    SET @List = STUFF((SELECT N', ' + DatabaseName + N' (' + LogTools + N')' FROM #bk
                       WHERE Evaluate = 1 AND LogTools LIKE N'% + %'
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Backups', 'Critical', N'Log backups taken by more than one tool',
                          N'Transaction log backups during the period came from different backup tools: ' + @List + N'.',
                          N'The log chain is split between the tools, so neither holds a complete chain and point-in-time restores can fail. Use one tool for log backups (e.g. remove maintenance plan or Agent log backups for databases protected by Azure Backup). Ignore this if you deliberately switched tools during the week.');

    SET @List = STUFF((SELECT N', ' + bk.DatabaseName FROM #bk bk
                       WHERE bk.Evaluate = 1 AND bk.FullTool = N'VM/VSS snapshot'
                         AND NOT EXISTS (SELECT 1 FROM msdb.dbo.backupset b
                                         WHERE b.database_name COLLATE DATABASE_DEFAULT = bk.DatabaseName COLLATE DATABASE_DEFAULT
                                           AND b.type IN ('D', 'I') AND b.is_snapshot = 0 AND b.backup_finish_date >= DATEADD(hour, -@FullMaxH, @Now))
                       ORDER BY bk.DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Backups', 'Warning', N'Full backups are VM/VSS snapshots only',
                          N'The only recent full backups are volume snapshots (e.g. Azure VM backup, Veeam or other VSS-based tools): ' + @List + N'.',
                          N'Snapshots restore the whole VM or volume to the moment of the snapshot. They do not give single-database or point-in-time restores and are not part of a log backup chain. If those are needed, add SQL-aware backups (Azure Backup for SQL Server, native or third-party).');

    SELECT @Cnt = COUNT(*) FROM #bk WHERE StateDesc = N'ONLINE' AND IsAgDatabase = 1 AND IsPreferred = 0;
    IF @Cnt > 0
        INSERT #F VALUES ('Backups', 'Info', N'Availability Group databases backed up on another replica',
                          CONVERT(nvarchar(10), @Cnt) + N' AG database(s) are not preferred for backups on this replica; check the preferred replica''s report.', NULL);

    SELECT @Cnt = COUNT(*) FROM dbo.ErrorLogEntry WHERE LogDate >= @Start AND Category = 'Backup failure';
    IF @Cnt > 0
        INSERT #F VALUES ('Backups', 'Critical', N'Backup failures in the error log',
                          CONVERT(nvarchar(10), @Cnt) + N' backup failure message(s) during the period. See the error log section.',
                          N'Confirm the backup destination is reachable and has space, then re-run the failed backups.');

    /*------------------------------------------------------------ ERROR LOG */
    SELECT e.Category,
           Severity  = CASE MIN(CASE e.Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END) WHEN 1 THEN 'Critical' WHEN 2 THEN 'Warning' ELSE 'Info' END,
           Entries   = COUNT(*),
           FirstSeen = MIN(e.LogDate),
           LastSeen  = MAX(e.LogDate)
    INTO #el
    FROM dbo.ErrorLogEntry e
    WHERE e.LogDate >= @Start
    GROUP BY e.Category;

    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Error log', el.Severity, el.Category + N' (' + CONVERT(nvarchar(10), el.Entries) + N')',
           N'Last seen ' + dbo.fn_Date(el.LastSeen) + N': ' + LEFT(l.LogText, 400),
           p.Recommendation
    FROM #el el
    CROSS APPLY (SELECT TOP (1) LogText, PatternId FROM dbo.ErrorLogEntry x WHERE x.Category = el.Category AND x.LogDate >= @Start ORDER BY x.LogDate DESC) l
    LEFT JOIN dbo.ErrorLogPattern p ON p.PatternId = l.PatternId
    WHERE el.Severity IN ('Critical', 'Warning') OR el.Entries >= 50
    ORDER BY CASE el.Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END, el.Entries DESC;

    /*----------------------------------------------------------- AGENT JOBS */
    SELECT JobName, Failures = COUNT(*), LastFailure = MAX(RunDateTime)
    INTO #jf
    FROM dbo.JobFailure
    WHERE StepId = 0 AND RunDateTime >= @Start
    GROUP BY JobName;

    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Agent jobs',
           CASE WHEN jf.JobName LIKE N'%backup%' THEN 'Critical' ELSE 'Warning' END,
           N'Job failed: ' + jf.JobName,
           CONVERT(nvarchar(10), jf.Failures) + N' failure(s), last ' + dbo.fn_Date(jf.LastFailure)
             + ISNULL(N'. Step "' + s.StepName + N'": ' + LEFT(s.Message, 400), N''),
           N'Review the job history and the failing step. Raise a ticket if you would like us to investigate.'
    FROM #jf jf
    OUTER APPLY (SELECT TOP (1) StepName, Message FROM dbo.JobFailure f
                 WHERE f.JobName = jf.JobName AND f.StepId > 0 AND f.RunDateTime >= @Start
                 ORDER BY f.RunDateTime DESC) s
    ORDER BY jf.LastFailure DESC;

    DECLARE @AgentStatus nvarchar(60), @AgentStartup nvarchar(60);
    SELECT TOP (1) @AgentStatus = status_desc, @AgentStartup = startup_type_desc
    FROM sys.dm_server_services WHERE servicename LIKE N'SQL Server Agent%';
    IF @EngineEdition <> 4 AND @AgentStatus IS NOT NULL AND @AgentStatus <> N'Running'
        INSERT #F VALUES ('Agent jobs', 'Critical', N'SQL Server Agent is not running',
                          N'Agent service status: ' + @AgentStatus + N'. Scheduled jobs (including backups) will not run.',
                          N'Start the SQL Server Agent service and set it to start automatically.');
    ELSE IF @EngineEdition <> 4 AND @AgentStartup IS NOT NULL AND @AgentStartup <> N'Automatic'
        INSERT #F VALUES ('Agent jobs', 'Warning', N'SQL Server Agent is not set to start automatically',
                          N'Startup type: ' + @AgentStartup + N'. After a server restart, scheduled jobs will not run.',
                          N'Set the SQL Server Agent service startup type to Automatic.');

    /*-------------------------------------------------------------- QUERIES */
    DECLARE @QFirst datetime, @QLast datetime;
    SELECT @QFirst = MIN(SnapshotTime), @QLast = MAX(SnapshotTime) FROM dbo.QuerySnapshot WHERE SnapshotTime >= @Start;

    CREATE TABLE #q (RankNo int, QueryHash binary(8), DatabaseName sysname NULL, ObjectName sysname NULL, QueryText nvarchar(max) NULL,
                     Executions bigint, CpuMs bigint, DurationMs bigint, Reads bigint);
    IF @QLast IS NOT NULL
        INSERT #q (RankNo, QueryHash, DatabaseName, ObjectName, QueryText, Executions, CpuMs, DurationMs, Reads)
        SELECT TOP (10) ROW_NUMBER() OVER (ORDER BY x.CpuMs DESC), x.QueryHash, t.DatabaseName, t.ObjectName, t.QueryText,
               x.Executions, x.CpuMs, x.DurationMs, x.Reads
        FROM (
            SELECT l.QueryHash,
                   Executions = CASE WHEN r.IsDelta = 1 THEN l.ExecutionCount - f.ExecutionCount ELSE l.ExecutionCount END,
                   CpuMs      = CASE WHEN r.IsDelta = 1 THEN l.CpuMs - f.CpuMs ELSE l.CpuMs END,
                   DurationMs = CASE WHEN r.IsDelta = 1 THEN l.DurationMs - f.DurationMs ELSE l.DurationMs END,
                   Reads      = CASE WHEN r.IsDelta = 1 THEN l.LogicalReads - f.LogicalReads ELSE l.LogicalReads END
            FROM dbo.QuerySnapshot l
            LEFT JOIN dbo.QuerySnapshot f ON f.SnapshotTime = @QFirst AND f.QueryHash = l.QueryHash AND @QFirst < @QLast
            CROSS APPLY (SELECT IsDelta = CASE WHEN f.QueryHash IS NOT NULL AND l.ExecutionCount >= f.ExecutionCount AND l.CpuMs >= f.CpuMs
                                                    AND l.DurationMs >= f.DurationMs AND l.LogicalReads >= f.LogicalReads THEN 1 ELSE 0 END) r
            WHERE l.SnapshotTime = @QLast) x
        LEFT JOIN dbo.QueryText t ON t.QueryHash = x.QueryHash
        WHERE x.Executions > 0 AND ISNULL(t.DatabaseName, N'') <> N'MolehillWatch'
        ORDER BY x.CpuMs DESC;

    IF NOT EXISTS (SELECT 1 FROM #q)
        INSERT #F VALUES ('Queries', 'Info', N'No query performance data yet',
                          N'Query statistics are collected hourly; data will appear once collection has run.', NULL);

    /*------------------------------------------------------------- CAPACITY */
    DECLARE @DiskWarn bigint = dbo.fn_SettingInt('DiskWarnFreePct', 15), @DiskCrit bigint = dbo.fn_SettingInt('DiskCritFreePct', 10);
    DECLARE @DiskLatest datetime = (SELECT MAX(SnapshotTime) FROM dbo.DiskSnapshot);

    SELECT d.VolumeMountPoint, d.LogicalVolumeName, d.TotalMB, d.FreeMB,
           FreePct   = CAST(100.0 * d.FreeMB / NULLIF(d.TotalMB, 0) AS decimal(5,1)),
           Change30d = d.FreeMB - o.FreeMB,
           DaysToFull = CASE WHEN o.FreeMB > d.FreeMB AND DATEDIFF(hour, o.SnapshotTime, d.SnapshotTime) >= 72
                             THEN CAST(d.FreeMB / ((o.FreeMB - d.FreeMB) / (DATEDIFF(hour, o.SnapshotTime, d.SnapshotTime) / 24.0)) AS int) END
    INTO #disk
    FROM dbo.DiskSnapshot d
    OUTER APPLY (SELECT TOP (1) FreeMB, SnapshotTime FROM dbo.DiskSnapshot o
                 WHERE o.VolumeMountPoint = d.VolumeMountPoint AND o.SnapshotTime >= DATEADD(day, -30, @DiskLatest)
                 ORDER BY o.SnapshotTime) o
    WHERE d.SnapshotTime = @DiskLatest;

    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Capacity', CASE WHEN FreePct < @DiskCrit THEN 'Critical' ELSE 'Warning' END,
           N'Low disk space: ' + VolumeMountPoint,
           CONVERT(nvarchar(20), FreePct) + N'% free (' + FORMAT(FreeMB / 1024.0, 'N1') + N' GB of ' + FORMAT(TotalMB / 1024.0, 'N1') + N' GB).',
           N'Free up space or extend the volume before it fills. A full volume can stop databases or backups.'
    FROM #disk WHERE FreePct < @DiskWarn;

    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Capacity', CASE WHEN DaysToFull < 14 THEN 'Critical' ELSE 'Warning' END,
           N'Disk projected to fill: ' + VolumeMountPoint,
           N'At the current rate of growth this volume will be full in about ' + CONVERT(nvarchar(10), DaysToFull) + N' days.',
           N'Plan extra capacity or reduce growth (archiving, backup retention, index maintenance).'
    FROM #disk WHERE DaysToFull < 30 AND FreePct >= @DiskWarn;

    DECLARE @FileLatest datetime = (SELECT MAX(SnapshotTime) FROM dbo.DatabaseFileSnapshot);
    ;WITH s AS (
        SELECT SnapshotTime, DatabaseName,
               DataMB     = SUM(CASE WHEN FileType = N'ROWS' THEN SizeMB END),
               DataUsedMB = SUM(CASE WHEN FileType = N'ROWS' THEN ISNULL(UsedMB, SizeMB) END),
               LogMB      = SUM(CASE WHEN FileType = N'LOG' THEN SizeMB END)
        FROM dbo.DatabaseFileSnapshot
        GROUP BY SnapshotTime, DatabaseName)
    SELECT l.DatabaseName, l.DataMB, l.DataUsedMB, l.LogMB,
           Growth7dMB  = l.DataUsedMB - w.DataUsedMB,
           Growth30dMB = l.DataUsedMB - m.DataUsedMB,
           LogUsedPct  = CAST(NULL AS int), LogReuseWait = CAST(NULL AS nvarchar(60))
    INTO #db
    FROM s l
    OUTER APPLY (SELECT TOP (1) DataUsedMB FROM s x WHERE x.DatabaseName = l.DatabaseName AND x.SnapshotTime >= DATEADD(hour, -180, @FileLatest) AND x.SnapshotTime < l.SnapshotTime ORDER BY x.SnapshotTime) w
    OUTER APPLY (SELECT TOP (1) DataUsedMB FROM s x WHERE x.DatabaseName = l.DatabaseName AND x.SnapshotTime >= DATEADD(hour, -732, @FileLatest) AND x.SnapshotTime < l.SnapshotTime ORDER BY x.SnapshotTime) m
    WHERE l.SnapshotTime = @FileLatest;

    UPDATE db SET LogUsedPct = pc.cntr_value, LogReuseWait = d.log_reuse_wait_desc
    FROM #db db
    JOIN sys.databases d ON d.name = db.DatabaseName
    LEFT JOIN sys.dm_os_performance_counters pc
           ON pc.counter_name LIKE N'Percent Log Used%' AND pc.object_name LIKE N'%:Databases%'
          AND RTRIM(pc.instance_name) = db.DatabaseName;

    DECLARE @LogWarn bigint = dbo.fn_SettingInt('LogUsedWarnPct', 75);
    SET @List = STUFF((SELECT N', ' + DatabaseName + N' (' + CONVERT(nvarchar(10), LogUsedPct) + N'% of ' + FORMAT(LogMB / 1024.0, 'N1') + N' GB, waiting on ' + LogReuseWait + N')'
                       FROM #db WHERE LogUsedPct >= @LogWarn AND LogMB >= 512 AND LogReuseWait NOT IN (N'NOTHING', N'CHECKPOINT')
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Capacity', 'Warning', N'Transaction logs filling up', @List + N'.',
                          N'LOG_BACKUP: check log backups are running. ACTIVE_TRANSACTION: look for long-running open transactions. AVAILABILITY_REPLICA: check AG synchronisation.');

    SET @List = STUFF((SELECT N', ' + DatabaseName + N'/' + LogicalName + N' (' + FORMAT(SizeMB / 1024.0, 'N1') + N' GB of ' + FORMAT(MaxSizePages / 128.0 / 1024.0, 'N1') + N' GB max)'
                       FROM dbo.DatabaseFileSnapshot
                       WHERE SnapshotTime = @FileLatest AND MaxSizePages NOT IN (-1, 0, 268435456) AND SizeMB >= 0.9 * (MaxSizePages / 128.0)
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Capacity', 'Critical', N'Database files close to their maximum size', @List + N'.',
                          N'Raise the file max size or add a file before the database stops accepting writes.');

    SET @List = STUFF((SELECT N', ' + DatabaseName + N'/' + LogicalName
                       FROM dbo.DatabaseFileSnapshot
                       WHERE SnapshotTime = @FileLatest AND DatabaseName NOT IN (N'master', N'model', N'msdb')
                         AND ((IsPercentGrowth = 1 AND SizeMB >= 1024) OR (IsPercentGrowth = 0 AND GrowthPages BETWEEN 1 AND 1280 AND SizeMB >= 1024))
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Capacity', 'Info', N'Autogrowth settings could be improved',
                          N'Files over 1 GB growing by a percentage or by 10 MB or less: ' + LEFT(@List, 1500) + CASE WHEN LEN(@List) > 1500 THEN N'...' ELSE N'' END + N'.',
                          N'Use fixed growth increments sized to the file (e.g. 256 MB - 1 GB) to avoid many small or very large growth events.');

    SET @List = STUFF((SELECT N', ' + DatabaseName + N'/' + LogicalName
                       FROM dbo.DatabaseFileSnapshot
                       WHERE SnapshotTime = @FileLatest AND GrowthPages = 0 AND DatabaseName <> N'tempdb'
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Capacity', 'Warning', N'Autogrowth disabled', N'Files that cannot grow automatically: ' + @List + N'.',
                          N'Confirm this is intentional and that free space inside these files is monitored.');

    /*--------------------------------------------------------- AVAILABILITY */
    DECLARE @AgLatest datetime = (SELECT MAX(SampleTime) FROM dbo.AgDatabaseSample);
    DECLARE @AgRepLatest datetime = (SELECT MAX(SampleTime) FROM dbo.AgReplicaSample);
    DECLARE @SendWarn bigint = dbo.fn_SettingInt('AgSendQueueWarnKB', 102400),
            @RedoWarn bigint = dbo.fn_SettingInt('AgRedoQueueWarnKB', 102400),
            @LagWarn  bigint = dbo.fn_SettingInt('AgLagWarnSeconds', 60);

    SELECT AgName, ReplicaServer, DatabaseName, ReplicaRole, AvailabilityMode, FailoverMode,
           CurrentSyncState  = MAX(CASE WHEN SampleTime = @AgLatest THEN SyncState END),
           CurrentSyncHealth = MAX(CASE WHEN SampleTime = @AgLatest THEN SyncHealth END),
           IsSuspended       = CONVERT(bit, MAX(CASE WHEN SampleTime = @AgLatest THEN CONVERT(int, IsSuspended) END)),
           IsFailoverReady   = CONVERT(bit, MAX(CASE WHEN SampleTime = @AgLatest THEN CONVERT(int, IsFailoverReady) END)),
           MaxSendQueueKB    = MAX(LogSendQueueKB),
           MaxRedoQueueKB    = MAX(RedoQueueKB),
           MaxLagSeconds     = MAX(SecondaryLagSeconds),
           UnhealthySamples  = SUM(CASE WHEN SyncHealth <> N'HEALTHY' THEN 1 ELSE 0 END),
           Samples           = COUNT(*),
           IsCurrent         = MAX(CASE WHEN SampleTime = @AgLatest THEN 1 ELSE 0 END)
    INTO #ag
    FROM dbo.AgDatabaseSample
    WHERE SampleTime >= @Start
    GROUP BY AgName, ReplicaServer, DatabaseName, ReplicaRole, AvailabilityMode, FailoverMode;

    IF @IsHadr = 1 AND EXISTS (SELECT 1 FROM sys.availability_groups)
    BEGIN
        IF @AgLatest IS NULL OR @AgLatest < DATEADD(hour, -1, @Now)
            INSERT #F VALUES ('Availability', 'Warning', N'Availability Group sampling is not running',
                              N'The last AG sample was ' + dbo.fn_Date(@AgLatest) + N'.', N'Check the "Molehill Watch - Collect Frequent" job.');

        INSERT #F (Section, Severity, Item, Detail, Recommendation)
        SELECT 'Availability', 'Critical', N'AG replica disconnected: ' + ReplicaServer + N' (' + AgName + N')',
               N'Replica connection state is ' + ConnectedState + N'.', N'Check the replica is online and the endpoint/network between replicas is healthy.'
        FROM dbo.AgReplicaSample WHERE SampleTime = @AgRepLatest AND ConnectedState = N'DISCONNECTED';

        SET @List = STUFF((SELECT N', ' + DatabaseName + N' on ' + ReplicaServer FROM #ag WHERE IsCurrent = 1 AND IsSuspended = 1 FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
        IF @List IS NOT NULL
            INSERT #F VALUES ('Availability', 'Critical', N'AG data movement suspended', @List + N'.',
                              N'Investigate why data movement was suspended, then resume it. The primary log cannot truncate while suspended.');

        SET @List = STUFF((SELECT N', ' + DatabaseName + N' on ' + ReplicaServer + N' (' + CurrentSyncState + N')' FROM #ag
                           WHERE IsCurrent = 1 AND ISNULL(IsSuspended, 0) = 0
                             AND ((AvailabilityMode = N'SYNCHRONOUS_COMMIT' AND CurrentSyncState <> N'SYNCHRONIZED')
                               OR (AvailabilityMode <> N'SYNCHRONOUS_COMMIT' AND CurrentSyncState NOT IN (N'SYNCHRONIZING', N'SYNCHRONIZED')))
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
        IF @List IS NOT NULL
            INSERT #F VALUES ('Availability', 'Critical', N'AG databases not synchronising', @List + N'.',
                              N'A failover now could lose data or fail. Check replica connectivity, disk space and the error log on each replica.');

        SET @List = STUFF((SELECT N', ' + DatabaseName + N' on ' + ReplicaServer FROM #ag
                           WHERE IsCurrent = 1 AND AvailabilityMode = N'SYNCHRONOUS_COMMIT' AND FailoverMode = N'AUTOMATIC' AND IsFailoverReady = 0
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
        IF @List IS NOT NULL
            INSERT #F VALUES ('Availability', 'Critical', N'Automatic failover not ready', @List + N'.',
                              N'These databases would not fail over automatically. Resolve synchronisation before relying on automatic failover.');

        SET @List = STUFF((SELECT N', ' + DatabaseName + N' on ' + ReplicaServer + N' (' + CONVERT(nvarchar(10), UnhealthySamples) + N' of ' + CONVERT(nvarchar(10), Samples) + N' samples)' FROM #ag
                           WHERE UnhealthySamples > 0 AND ISNULL(CurrentSyncHealth, N'') = N'HEALTHY'
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
        IF @List IS NOT NULL
            INSERT #F VALUES ('Availability', 'Warning', N'Intermittent AG health issues during the period', @List + N'. Currently healthy.',
                              N'Review the error log around those times for network or replica issues.');

        SET @List = STUFF((SELECT N', ' + DatabaseName + N' to ' + ReplicaServer + N' (send ' + FORMAT(MaxSendQueueKB / 1024.0, 'N0') + N' MB, redo ' + FORMAT(MaxRedoQueueKB / 1024.0, 'N0') + N' MB'
                                  + ISNULL(N', lag ' + CONVERT(nvarchar(20), MaxLagSeconds) + N's', N'') + N')' FROM #ag
                           WHERE MaxSendQueueKB > @SendWarn OR MaxRedoQueueKB > @RedoWarn OR MaxLagSeconds > @LagWarn
                           FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
        IF @List IS NOT NULL
            INSERT #F VALUES ('Availability', 'Warning', N'AG latency peaks during the period', N'Peak queues: ' + @List + N'.',
                              N'Large queues increase potential data loss (async) or commit latency (sync). Check network throughput and secondary I/O at peak times.');

        INSERT #F VALUES ('Availability', 'Info', N'Replica job and login parity',
                          N'SQL Agent job and login parity between replicas is compared by Molehill Data Services across all replicas each week.', NULL);
    END

    -- Database mirroring
    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Availability', 'Critical', N'Database mirroring problem: ' + DB_NAME(database_id),
           N'Role ' + mirroring_role_desc + N', state ' + mirroring_state_desc + N', partner ' + ISNULL(mirroring_partner_instance, N'?') + N'.',
           N'Check the mirror partner is online and the mirroring endpoint is reachable.'
    FROM sys.database_mirroring
    WHERE mirroring_guid IS NOT NULL AND mirroring_state_desc NOT IN (N'SYNCHRONIZED', N'SYNCHRONIZING');

    -- Log shipping
    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Availability', 'Critical', N'Log shipping backup overdue: ' + primary_database,
           N'Last log shipping backup ' + dbo.fn_Date(last_backup_date) + N' (threshold ' + CONVERT(nvarchar(10), backup_threshold) + N' min).',
           N'Check the log shipping backup job on the primary.'
    FROM msdb.dbo.log_shipping_monitor_primary
    WHERE last_backup_date IS NULL OR DATEDIFF(minute, last_backup_date, @Now) > backup_threshold;

    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Availability', 'Critical', N'Log shipping restore overdue: ' + secondary_database,
           N'Last restore ' + dbo.fn_Date(last_restored_date) + N', last copy ' + dbo.fn_Date(last_copied_date) + N' (threshold ' + CONVERT(nvarchar(10), restore_threshold) + N' min).',
           N'Check the copy and restore jobs on the secondary and the share between servers.'
    FROM msdb.dbo.log_shipping_monitor_secondary
    WHERE last_restored_date IS NULL OR DATEDIFF(minute, last_restored_date, @Now) > restore_threshold;

    -- Failover Cluster Instance nodes
    CREATE TABLE #nodes (NodeName nvarchar(256), NodeStatus nvarchar(60) NULL, IsCurrentOwner bit NULL);
    IF @IsClustered = 1
    BEGIN
        IF EXISTS (SELECT 1 FROM sys.all_columns WHERE object_id = OBJECT_ID(N'sys.dm_os_cluster_nodes') AND name = N'status_description')
            EXEC (N'INSERT #nodes SELECT NodeName, status_description, is_current_owner FROM sys.dm_os_cluster_nodes;');
        ELSE
            EXEC (N'INSERT #nodes (NodeName) SELECT NodeName FROM sys.dm_os_cluster_nodes;');

        INSERT #F (Section, Severity, Item, Detail, Recommendation)
        SELECT 'Availability', 'Warning', N'Cluster node not up: ' + NodeName, N'Node status: ' + NodeStatus + N'.',
               N'The instance cannot fail over to this node until it is back up.'
        FROM #nodes WHERE NodeStatus IS NOT NULL AND NodeStatus <> N'up';
    END

    /*------------------------------------------------------------- BLOCKING */
    DECLARE @BlockWarn bigint = dbo.fn_SettingInt('BlockingWarnSeconds', 300);
    DECLARE @BlockSamples int, @BlockMaxWait int;
    SELECT @BlockSamples = COUNT(DISTINCT SampleTime), @BlockMaxWait = MAX(WaitSeconds)
    FROM dbo.BlockingSample WHERE SampleTime >= @Start AND IsHeadBlocker = 0;

    SELECT TOP (5) LoginName, HostName, ProgramName, DatabaseName, Occurrences = COUNT(DISTINCT SampleTime), SampleSql = MAX(SqlText)
    INTO #blk
    FROM dbo.BlockingSample
    WHERE SampleTime >= @Start AND IsHeadBlocker = 1
    GROUP BY LoginName, HostName, ProgramName, DatabaseName
    ORDER BY COUNT(DISTINCT SampleTime) DESC;

    IF @BlockSamples > 0
        INSERT #F VALUES ('Blocking', CASE WHEN @BlockMaxWait >= @BlockWarn THEN 'Warning' ELSE 'Info' END,
                          N'Blocking detected',
                          N'Blocking over ' + CONVERT(nvarchar(10), dbo.fn_SettingInt('BlockingThresholdSeconds', 60)) + N' seconds was seen in '
                          + CONVERT(nvarchar(10), @BlockSamples) + N' five-minute sample(s). Longest wait ' + CONVERT(nvarchar(10), @BlockMaxWait) + N' seconds.',
                          N'Review the head blockers below. Long-held transactions or missing indexes are the usual causes.');

    /*------------------------------------------------------------- PATCHING */
    CREATE TABLE #patch (SortOrder int, Component varchar(20), Installed nvarchar(100), InstalledUpdate nvarchar(100), Latest nvarchar(100),
                         LatestUpdate nvarchar(100), LatestReleased date, Status nvarchar(100), Severity varchar(10),
                         Detail nvarchar(1000), Recommendation nvarchar(1000), ReferenceLoaded datetime);
    BEGIN TRY
        EXEC dbo.usp_CollectPatchLevel;
        INSERT #patch EXEC dbo.usp_PatchStatus;
    END TRY
    BEGIN CATCH
        INSERT #F VALUES ('Patching', 'Info', N'Patch status could not be checked', LEFT(ERROR_MESSAGE(), 400), NULL);
    END CATCH;

    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Patching', Severity, Component + N': ' + Status, Detail, Recommendation
    FROM #patch WHERE Severity IN ('Critical', 'Warning', 'Info')
    ORDER BY SortOrder;

    /*---------------------------------------------------------------- RISKS */
    INSERT #F (Section, Severity, Item, Detail, Recommendation)
    SELECT 'Risks', CASE WHEN state_desc = N'OFFLINE' THEN 'Info' ELSE 'Critical' END,
           N'Database not online: ' + name, N'State: ' + state_desc + N'.',
           CASE WHEN state_desc = N'OFFLINE' THEN N'Confirm this database is intentionally offline.' ELSE N'Investigate immediately - raise a Critical ticket.' END
    FROM sys.databases
    WHERE state_desc IN (N'SUSPECT', N'RECOVERY_PENDING', N'EMERGENCY', N'OFFLINE');

    SELECT @Cnt = COUNT(*) FROM msdb.dbo.suspect_pages WHERE last_update_date >= DATEADD(day, -90, @Now);
    IF @Cnt > 0
        INSERT #F VALUES ('Risks', 'Critical', N'Suspect pages recorded',
                          CONVERT(nvarchar(10), @Cnt) + N' suspect page record(s) in msdb.dbo.suspect_pages in the last 90 days.',
                          N'Indicates I/O or corruption problems. Run DBCC CHECKDB and review storage health.');

    CREATE TABLE #dbcc (ParentObject nvarchar(255), [Object] nvarchar(255), Field nvarchar(255), Value nvarchar(255));
    CREATE TABLE #checkdb (DatabaseName sysname, LastGood datetime NULL);
    DECLARE @db sysname, @sql nvarchar(max);
    DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
        SELECT name FROM sys.databases WHERE state = 0 AND database_id <> 2 AND source_database_id IS NULL AND HAS_DBACCESS(name) = 1;
    OPEN dbs;
    FETCH NEXT FROM dbs INTO @db;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            TRUNCATE TABLE #dbcc;
            SET @sql = N'DBCC DBINFO(' + QUOTENAME(@db, '''') + N') WITH TABLERESULTS, NO_INFOMSGS;';
            INSERT #dbcc EXEC (@sql);
            INSERT #checkdb SELECT @db, MAX(TRY_CONVERT(datetime, Value)) FROM #dbcc WHERE Field = N'dbi_dbccLastKnownGood';
        END TRY
        BEGIN CATCH
        END CATCH;
        FETCH NEXT FROM dbs INTO @db;
    END
    CLOSE dbs; DEALLOCATE dbs;

    DECLARE @CheckDbDays bigint = dbo.fn_SettingInt('CheckDbMaxAgeDays', 8);
    SET @List = STUFF((SELECT N', ' + DatabaseName + N' (' + dbo.fn_Age(LastGood, @Now) + N')' FROM #checkdb
                       WHERE LastGood IS NULL OR LastGood < DATEADD(day, -@CheckDbDays, @Now)
                       ORDER BY DatabaseName FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Risks', 'Warning', N'Integrity checks overdue',
                          N'No clean DBCC CHECKDB in the last ' + CONVERT(nvarchar(10), @CheckDbDays) + N' days: ' + LEFT(@List, 1500) + CASE WHEN LEN(@List) > 1500 THEN N'...' ELSE N'' END + N'.',
                          N'Schedule a weekly DBCC CHECKDB so corruption is found while good backups still exist.');

    SET @List = STUFF((SELECT N', ' + name FROM sys.databases WHERE is_auto_shrink_on = 1 ORDER BY name FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Risks', 'Warning', N'Auto-shrink enabled', @List + N'.', N'Disable AUTO_SHRINK - it causes fragmentation and repeated growth/shrink cycles.');

    SET @List = STUFF((SELECT N', ' + name FROM sys.databases WHERE is_auto_close_on = 1 ORDER BY name FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Risks', 'Warning', N'Auto-close enabled', @List + N'.', N'Disable AUTO_CLOSE - it adds overhead to every first connection and flushes caches.');

    SET @List = STUFF((SELECT N', ' + name + N' (' + page_verify_option_desc + N')' FROM sys.databases WHERE page_verify_option_desc <> N'CHECKSUM' AND database_id <> 2 ORDER BY name FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Risks', 'Warning', N'Page verification not set to CHECKSUM', @List + N'.', N'Set PAGE_VERIFY CHECKSUM so storage corruption is detected.');

    IF @MaxMem >= 2147483647
        INSERT #F VALUES ('Risks', 'Warning', N'Max server memory not configured',
                          N'max server memory is at the default (unlimited) on a server with ' + CONVERT(nvarchar(20), @MemGB) + N' GB RAM.',
                          N'Set max server memory to leave headroom for the operating system and other services.');

    IF EXISTS (SELECT 1 FROM sys.configurations WHERE name = N'priority boost' AND CONVERT(int, value_in_use) = 1)
        INSERT #F VALUES ('Risks', 'Warning', N'Priority boost enabled', N'"priority boost" is on.', N'Microsoft recommends leaving priority boost off; it can destabilise the server.');

    /*----------------------------------------------------------- MONITORING */
    SET @List = STUFF((SELECT TOP (5) N'; ' + CollectionType + N'/' + StepName + N' at ' + dbo.fn_Date(StartTime) + N': ' + LEFT(ISNULL(ErrorMessage, N''), 200)
                       FROM dbo.CollectionLog WHERE StartTime >= @Start AND Succeeded = 0
                       ORDER BY StartTime DESC FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N'');
    IF @List IS NOT NULL
        INSERT #F VALUES ('Monitoring', 'Warning', N'Molehill Watch collection errors', @List,
                          N'Some report data may be incomplete. Molehill Data Services will review.');

    DECLARE @LastHourly datetime = (SELECT MAX(StartTime) FROM dbo.CollectionLog WHERE CollectionType IN ('Hourly', 'All') AND Succeeded = 1);
    IF @LastHourly IS NULL OR @LastHourly < DATEADD(hour, -3, @Now)
        INSERT #F VALUES ('Monitoring', 'Warning', N'Molehill Watch collection jobs not running',
                          N'Last successful hourly collection: ' + dbo.fn_Date(@LastHourly) + N'.',
                          N'Check the "Molehill Watch" SQL Agent jobs (or scheduled tasks on Express) are enabled and SQL Server Agent is running.');

    DECLARE @FirstData datetime = (SELECT MIN(SnapshotTime) FROM dbo.DiskSnapshot);
    IF @FirstData IS NULL OR @FirstData > DATEADD(day, 1, @Start)
        INSERT #F VALUES ('Monitoring', 'Info', N'Monitoring recently installed',
                          N'Data collection began ' + dbo.fn_Date(@FirstData) + N'. Trends and weekly totals will be more complete in future reports.', NULL);

    /*--------------------------------------------------------------- SAVE */
    DECLARE @Crit int = (SELECT COUNT(*) FROM #F WHERE Severity = 'Critical'),
            @Warn int = (SELECT COUNT(*) FROM #F WHERE Severity = 'Warning'),
            @Info int = (SELECT COUNT(*) FROM #F WHERE Severity = 'Info');
    DECLARE @Overall varchar(10) = CASE WHEN @Crit > 0 THEN 'Red' WHEN @Warn > 0 THEN 'Amber' ELSE 'Green' END;
    DECLARE @OverallText nvarchar(100) = CASE @Overall WHEN 'Red' THEN N'Action required' WHEN 'Amber' THEN N'Attention recommended' ELSE N'No issues found' END;

    INSERT dbo.WeeklyReport (GeneratedAt, PeriodStart, PeriodEnd, ClientName, InstanceName, OverallStatus, CriticalCount, WarningCount, InfoCount)
    VALUES (@Now, @Start, @Now, @Client, @Instance, @Overall, @Crit, @Warn, @Info);
    DECLARE @ReportId int = SCOPE_IDENTITY();

    INSERT dbo.ReportFinding (ReportId, Section, Severity, Item, Detail, Recommendation)
    SELECT @ReportId, Section, Severity, Item, Detail, Recommendation
    FROM #F
    ORDER BY CASE Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END, Seq;

    /*--------------------------------------------------------------- HTML */
    DECLARE @H nvarchar(max), @QFull nvarchar(max), @QNoText nvarchar(max), @T nvarchar(max);
    DECLARE @Empty nvarchar(200) = N'<tr><td colspan="9" class="note">Nothing to report.</td></tr>';

    SET @H = N'<html><head><meta charset="utf-8" /><title>Molehill Watch - ' + dbo.fn_Html(@Client) + N' - ' + dbo.fn_Html(@Instance) + N'</title>
<style>
body{margin:0;background:#F4F2F1;font-family:"Segoe UI",Arial,sans-serif;color:#231F20;font-size:14px;line-height:1.5}
.wrap{max-width:1040px;margin:0 auto;padding:24px}
.hero{background:#231F20;color:#FFFFFF;padding:28px 32px}
.brand{font-size:28px;font-weight:700;letter-spacing:-0.01em}
.tag{color:#44C8F5;font-size:14px}
.hero h1{font-size:20px;margin:20px 0 4px;font-weight:600}
.meta{color:#BFBBBA;font-size:13px}
.rag{display:inline-block;margin-top:16px;padding:8px 16px;font-weight:700;font-size:15px}
.rag-red{background:#D64545;color:#FFFFFF}.rag-amber{background:#F2A93B;color:#231F20}.rag-green{background:#3FA66B;color:#FFFFFF}
h2{font-size:18px;border-bottom:3px solid #44C8F5;padding-bottom:6px;margin:34px 0 12px}
h3{font-size:15px;margin:20px 0 8px}
table{width:100%;border-collapse:collapse;background:#FFFFFF;font-size:13px;margin-bottom:10px}
th{background:#231F20;color:#FFFFFF;text-align:left;padding:8px 10px;font-weight:600}
td{padding:7px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top}
td.critical{background:#D64545;color:#FFFFFF;font-weight:600;white-space:nowrap}
td.warning{background:#F9D58C;font-weight:600;white-space:nowrap}
td.info{background:#DDF3FC;white-space:nowrap}
td.ok{background:#D5EEDD;white-space:nowrap}
td.num{text-align:right;white-space:nowrap}
td.code{font-family:Consolas,monospace;font-size:12px;color:#55504F;word-break:break-word}
td.key{font-weight:600;width:28%;background:#FAF9F9}
.note{color:#7A7473;font-size:12px}
.foot{margin-top:40px;padding-top:12px;border-top:1px solid #E2DEDD;color:#7A7473;font-size:12px}
</style></head><body><div class="wrap">
<div class="hero"><div class="brand">Molehill Watch</div><div class="tag">Catching molehills before they''re mountains</div>
<h1>Weekly SQL Server Status Report</h1>
<div class="meta">' + dbo.fn_Html(@Client) + N' &#183; ' + dbo.fn_Html(@Instance) + N' &#183; ' + dbo.fn_Date(@Start) + N' to ' + dbo.fn_Date(@Now) + N'</div>
<div class="rag rag-' + LOWER(@Overall) + N'">' + @Overall + N': ' + @OverallText + N' &#8212; ' + CONVERT(nvarchar(10), @Crit) + N' critical, ' + CONVERT(nvarchar(10), @Warn) + N' warning(s)</div></div>';

    -- At a glance
    SET @T = CAST((SELECT td = s.Section, '',
                          [td/@class] = CASE WHEN c.Crit > 0 THEN 'critical' WHEN c.Warn > 0 THEN 'warning' ELSE 'ok' END,
                          td = CASE WHEN c.Crit > 0 THEN 'Red' WHEN c.Warn > 0 THEN 'Amber' ELSE 'Green' END, '',
                          [td/@class] = 'num', td = c.Crit, '',
                          [td/@class] = 'num', td = c.Warn, '',
                          [td/@class] = 'num', td = c.Info
                   FROM (VALUES (1, 'Server'), (2, 'Patching'), (3, 'Backups'), (4, 'Error log'), (5, 'Agent jobs'), (6, 'Queries'),
                                (7, 'Capacity'), (8, 'Availability'), (9, 'Blocking'), (10, 'Risks'), (11, 'Monitoring')) s (SortOrder, Section)
                   CROSS APPLY (SELECT Crit = ISNULL(SUM(CASE WHEN f.Severity = 'Critical' THEN 1 ELSE 0 END), 0),
                                       Warn = ISNULL(SUM(CASE WHEN f.Severity = 'Warning' THEN 1 ELSE 0 END), 0),
                                       Info = ISNULL(SUM(CASE WHEN f.Severity = 'Info' THEN 1 ELSE 0 END), 0)
                                FROM #F f WHERE f.Section = s.Section) c
                   ORDER BY s.SortOrder
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @H = @H + N'<h2>At a glance</h2><table><tr><th>Area</th><th>Status</th><th>Critical</th><th>Warnings</th><th>Info</th></tr>' + ISNULL(@T, @Empty) + N'</table>';

    -- Findings
    SET @T = CAST((SELECT [td/@class] = LOWER(Severity), td = Severity, '',
                          td = Section, '', td = Item, '', td = ISNULL(Detail, ''), '', td = ISNULL(Recommendation, '')
                   FROM #F
                   ORDER BY CASE Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END, Seq
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @H = @H + N'<h2>Findings and recommendations</h2><table><tr><th>Severity</th><th>Area</th><th>Finding</th><th>Detail</th><th>Recommendation</th></tr>'
            + ISNULL(@T, N'<tr><td colspan="5" class="ok">No issues found this week.</td></tr>') + N'</table>'
            + N'<p class="note">Where remediation is recommended, any work beyond the included monthly support time will be scoped and agreed with you before it is carried out.</p>';

    -- Server
    SET @T = CAST((SELECT [td/@class] = 'key', td = k, '', td = v
                   FROM (VALUES (1, N'Instance', ISNULL(@@SERVERNAME, N'') + N' (host ' + CONVERT(nvarchar(128), SERVERPROPERTY('ComputerNamePhysicalNetBIOS')) + N')'),
                                (2, N'SQL Server', @SqlProduct + N' ' + @Edition + N' - ' + @ProductVersion + N' ' + @Level),
                                (3, N'SQL Server support', CASE WHEN @SqlExtEnd IS NULL THEN N'See Microsoft lifecycle'
                                                                WHEN @SqlExtEnd < @Today THEN N'UNSUPPORTED since ' + CONVERT(nvarchar(11), @SqlExtEnd, 106)
                                                                WHEN @SqlMainEnd < @Today THEN N'Extended support until ' + CONVERT(nvarchar(11), @SqlExtEnd, 106)
                                                                ELSE N'Mainstream support until ' + CONVERT(nvarchar(11), @SqlMainEnd, 106) END),
                                (4, N'Operating system', ISNULL(@OsName, N'Unknown')
                                                        + ISNULL(CASE WHEN @OsExtEnd < @Today THEN N' - UNSUPPORTED since ' + CONVERT(nvarchar(11), @OsExtEnd, 106)
                                                                      ELSE N' - supported until ' + CONVERT(nvarchar(11), @OsExtEnd, 106) END, N'')),
                                (5, N'Running since', dbo.fn_Date(@StartTime)),
                                (6, N'CPU / memory', CONVERT(nvarchar(10), @Cpus) + N' logical CPUs, ' + CONVERT(nvarchar(20), @MemGB) + N' GB RAM, max server memory '
                                                     + CASE WHEN @MaxMem >= 2147483647 THEN N'unlimited' ELSE FORMAT(@MaxMem, 'N0') + N' MB' END),
                                (7, N'High availability', @HaDesc),
                                (8, N'Databases', CONVERT(nvarchar(10), (SELECT COUNT(*) FROM sys.databases WHERE database_id > 4)) + N' user databases')
                        ) x (o, k, v)
                   ORDER BY o
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @H = @H + N'<h2>Server</h2><table>' + @T + N'</table>';

    -- Patching
    SET @T = CAST((SELECT td = Component, '',
                          td = ISNULL(Installed, N'-') + ISNULL(N' - ' + NULLIF(InstalledUpdate, N''), N''), '',
                          td = ISNULL(Latest + ISNULL(N' - ' + LatestUpdate, N''), N'-'), '',
                          td = ISNULL(CONVERT(nvarchar(11), LatestReleased, 106), N'-'), '',
                          [td/@class] = CASE Severity WHEN 'Critical' THEN 'critical' WHEN 'Warning' THEN 'warning' WHEN 'OK' THEN 'ok' ELSE 'info' END,
                          td = Status
                   FROM #patch ORDER BY SortOrder
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    DECLARE @PatchRef datetime = (SELECT MAX(LoadedAt) FROM dbo.PatchReference);
    SET @H = @H + N'<h2>Patching</h2><table><tr><th>Component</th><th>Installed</th><th>Latest available</th><th>Released</th><th>Status</th></tr>' + ISNULL(@T, @Empty) + N'</table>'
            + N'<p class="note">Windows: the monthly cumulative security update for the operating system (feature and optional preview updates are ignored; other software such as .NET or drivers is not covered). '
            + N'SQL Server: the latest cumulative update on the servicing branch in use. Build data from Microsoft, last refreshed ' + ISNULL(dbo.fn_Date(@PatchRef), N'never') + N'.</p>';

    -- Backups
    SET @T = CAST((SELECT td = DatabaseName, '', td = RecoveryModel, '',
                          td = dbo.fn_Date(LastFull), '', td = dbo.fn_Date(LastDiff), '',
                          td = CASE WHEN RecoveryModel = N'SIMPLE' THEN N'n/a (SIMPLE)' ELSE dbo.fn_Date(LastLog) END, '',
                          td = ISNULL(N'Full: ' + FullTool, N'') + ISNULL(CASE WHEN FullTool IS NOT NULL THEN N'; ' ELSE N'' END + N'Log: ' + LogTools, N''), '',
                          td = CASE WHEN StateDesc <> N'ONLINE' THEN StateDesc WHEN IsAgDatabase = 1 AND IsPreferred = 0 THEN N'Backed up on another AG replica' ELSE N'' END
                   FROM #bk ORDER BY CASE WHEN DatabaseName IN (N'master', N'model', N'msdb') THEN 0 ELSE 1 END, DatabaseName
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @H = @H + N'<h2>1. Backups</h2><table><tr><th>Database</th><th>Recovery</th><th>Last full</th><th>Last diff</th><th>Last log</th><th>Backup tool</th><th>Note</th></tr>' + ISNULL(@T, @Empty) + N'</table>';

    -- Error log
    SET @T = CAST((SELECT [td/@class] = LOWER(Severity), td = Severity, '', td = Category, '',
                          [td/@class] = 'num', td = Entries, '', td = dbo.fn_Date(FirstSeen), '', td = dbo.fn_Date(LastSeen)
                   FROM #el ORDER BY CASE Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END, Entries DESC
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @H = @H + N'<h2>2. SQL Server error log</h2><table><tr><th>Severity</th><th>Category</th><th>Entries</th><th>First seen</th><th>Last seen</th></tr>' + ISNULL(@T, @Empty) + N'</table>';
    SET @T = CAST((SELECT TOP (15) td = dbo.fn_Date(LogDate), '', [td/@class] = LOWER(Severity), td = Severity, '', [td/@class] = 'code', td = LEFT(LogText, 600)
                   FROM dbo.ErrorLogEntry WHERE LogDate >= @Start AND Severity IN ('Critical', 'Warning')
                   ORDER BY LogDate DESC
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    IF @T IS NOT NULL
        SET @H = @H + N'<h3>Most recent notable entries</h3><table><tr><th>When</th><th>Severity</th><th>Message</th></tr>' + @T + N'</table>';

    -- Jobs
    SET @T = CAST((SELECT td = jf.JobName, '', [td/@class] = 'num', td = jf.Failures, '', td = dbo.fn_Date(jf.LastFailure), '',
                          [td/@class] = 'code', td = ISNULL(s.StepName + N': ' + LEFT(s.Message, 500), N'')
                   FROM #jf jf
                   OUTER APPLY (SELECT TOP (1) StepName, Message FROM dbo.JobFailure f WHERE f.JobName = jf.JobName AND f.StepId > 0 AND f.RunDateTime >= @Start ORDER BY f.RunDateTime DESC) s
                   ORDER BY jf.LastFailure DESC
                   FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @H = @H + N'<h2>3. SQL Agent jobs</h2><p>SQL Server Agent: ' + CASE WHEN @EngineEdition = 4 THEN N'not available (Express edition)' ELSE ISNULL(dbo.fn_Html(@AgentStatus), N'unknown') END + N'.</p>'
            + N'<table><tr><th>Failed job</th><th>Failures</th><th>Last failure</th><th>Failing step</th></tr>' + ISNULL(@T, N'<tr><td colspan="4" class="ok">No job failures this period.</td></tr>') + N'</table>';

    -- Queries (two variants: with and without query text)
    SET @QFull = CAST((SELECT [td/@class] = 'num', td = RankNo, '', td = ISNULL(DatabaseName, N''), '',
                              [td/@class] = 'code', td = ISNULL(ObjectName + N': ', N'') + LEFT(ISNULL(QueryText, N'(text not available)'), 400), '',
                              [td/@class] = 'num', td = FORMAT(Executions, 'N0'), '',
                              [td/@class] = 'num', td = FORMAT(CpuMs / 1000.0, 'N1'), '',
                              [td/@class] = 'num', td = FORMAT(CpuMs * 1.0 / NULLIF(Executions, 0), 'N1'), '',
                              [td/@class] = 'num', td = FORMAT(DurationMs * 1.0 / NULLIF(Executions, 0), 'N1'), '',
                              [td/@class] = 'num', td = FORMAT(Reads / NULLIF(Executions, 0), 'N0')
                       FROM #q ORDER BY RankNo FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @QNoText = CAST((SELECT [td/@class] = 'num', td = RankNo, '', td = ISNULL(DatabaseName, N''), '',
                                [td/@class] = 'code', td = ISNULL(ObjectName + N' - ', N'') + N'query hash ' + CONVERT(nvarchar(20), QueryHash, 1), '',
                                [td/@class] = 'num', td = FORMAT(Executions, 'N0'), '',
                                [td/@class] = 'num', td = FORMAT(CpuMs / 1000.0, 'N1'), '',
                                [td/@class] = 'num', td = FORMAT(CpuMs * 1.0 / NULLIF(Executions, 0), 'N1'), '',
                                [td/@class] = 'num', td = FORMAT(DurationMs * 1.0 / NULLIF(Executions, 0), 'N1'), '',
                                [td/@class] = 'num', td = FORMAT(Reads / NULLIF(Executions, 0), 'N0')
                         FROM #q ORDER BY RankNo FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    DECLARE @QHead nvarchar(max) = N'<h2>4. Top 10 queries by CPU</h2><table><tr><th>#</th><th>Database</th><th>Query</th><th>Executions</th><th>Total CPU (s)</th><th>Avg CPU (ms)</th><th>Avg duration (ms)</th><th>Avg reads</th></tr>';
    DECLARE @QFoot nvarchar(max) = N'</table><p class="note">Based on plan cache snapshots taken hourly. Figures are approximate and exclude queries whose plans were not cached.</p>';

    -- Capacity (tail of report, shared by both variants)
    SET @T = CAST((SELECT td = VolumeMountPoint + ISNULL(N' ' + NULLIF(LogicalVolumeName, N''), N''), '',
                          [td/@class] = 'num', td = FORMAT(TotalMB / 1024.0, 'N1'), '',
                          [td/@class] = 'num', td = FORMAT(FreeMB / 1024.0, 'N1'), '',
                          [td/@class] = CASE WHEN FreePct < @DiskCrit THEN 'critical' WHEN FreePct < @DiskWarn THEN 'warning' ELSE 'num' END, td = CONVERT(nvarchar(10), FreePct) + N'%', '',
                          [td/@class] = 'num', td = ISNULL(FORMAT(Change30d / 1024.0, 'N1'), N'-'), '',
                          [td/@class] = 'num', td = ISNULL(CONVERT(nvarchar(10), DaysToFull), N'-')
                   FROM #disk ORDER BY VolumeMountPoint FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    DECLARE @Tail nvarchar(max) = N'<h2>5. Capacity</h2><h3>Disk space</h3><table><tr><th>Volume</th><th>Size (GB)</th><th>Free (GB)</th><th>Free %</th><th>Free change 30d (GB)</th><th>Days to full</th></tr>'
            + ISNULL(@T, @Empty) + N'</table>';

    SET @T = CAST((SELECT TOP (25) td = DatabaseName, '',
                          [td/@class] = 'num', td = FORMAT(DataMB / 1024.0, 'N2'), '',
                          [td/@class] = 'num', td = FORMAT(DataUsedMB / 1024.0, 'N2'), '',
                          [td/@class] = 'num', td = FORMAT(LogMB / 1024.0, 'N2'), '',
                          [td/@class] = 'num', td = ISNULL(CONVERT(nvarchar(10), LogUsedPct) + N'%', N'-'), '',
                          [td/@class] = 'num', td = ISNULL(FORMAT(Growth7dMB, 'N0'), N'-'), '',
                          [td/@class] = 'num', td = ISNULL(FORMAT(Growth30dMB, 'N0'), N'-')
                   FROM #db ORDER BY DataMB DESC FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @Tail = @Tail + N'<h3>Databases (largest 25)</h3><table><tr><th>Database</th><th>Data (GB)</th><th>Data used (GB)</th><th>Log (GB)</th><th>Log used</th><th>Growth 7d (MB)</th><th>Growth 30d (MB)</th></tr>'
            + ISNULL(@T, @Empty) + N'</table>';

    -- Availability
    SET @Tail = @Tail + N'<h2>6. High availability</h2><p>' + dbo.fn_Html(@HaDesc) + N'</p>';
    SET @T = CAST((SELECT td = AgName, '', td = ReplicaServer, '', td = DatabaseName, '', td = ISNULL(ReplicaRole, N''), '',
                          td = REPLACE(AvailabilityMode, N'_COMMIT', N''), '',
                          [td/@class] = CASE WHEN CurrentSyncHealth = N'HEALTHY' THEN 'ok' WHEN CurrentSyncHealth = N'PARTIALLY_HEALTHY' THEN 'warning' ELSE 'critical' END,
                          td = ISNULL(CurrentSyncState, N'-'), '',
                          [td/@class] = 'num', td = FORMAT(MaxSendQueueKB / 1024.0, 'N1'), '',
                          [td/@class] = 'num', td = FORMAT(MaxRedoQueueKB / 1024.0, 'N1'), '',
                          [td/@class] = 'num', td = ISNULL(CONVERT(nvarchar(20), MaxLagSeconds), N'-')
                   FROM #ag ORDER BY AgName, DatabaseName, ReplicaServer FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    IF @T IS NOT NULL
        SET @Tail = @Tail + N'<h3>Availability Group databases (peaks over the period)</h3><table><tr><th>AG</th><th>Replica</th><th>Database</th><th>Role</th><th>Mode</th><th>Sync state</th><th>Max send queue (MB)</th><th>Max redo queue (MB)</th><th>Max lag (s)</th></tr>' + @T + N'</table>';
    SET @T = CAST((SELECT td = NodeName, '', td = ISNULL(NodeStatus, N'-'), '', td = CASE WHEN IsCurrentOwner = 1 THEN N'Active' ELSE N'' END
                   FROM #nodes ORDER BY NodeName FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    IF @T IS NOT NULL
        SET @Tail = @Tail + N'<h3>Cluster nodes</h3><table><tr><th>Node</th><th>Status</th><th>Owner</th></tr>' + @T + N'</table>';

    -- Blocking
    SET @T = CAST((SELECT td = ISNULL(LoginName, N''), '', td = ISNULL(HostName, N''), '', td = ISNULL(ProgramName, N''), '', td = ISNULL(DatabaseName, N''), '',
                          [td/@class] = 'num', td = Occurrences, '', [td/@class] = 'code', td = LEFT(ISNULL(SampleSql, N''), 300)
                   FROM #blk ORDER BY Occurrences DESC FOR XML PATH('tr'), TYPE) AS nvarchar(max));
    SET @Tail = @Tail + N'<h2>7. Blocking</h2><p>' + CASE WHEN ISNULL(@BlockSamples, 0) = 0 THEN N'No blocking over the capture threshold was seen this period.'
                                                          ELSE N'Blocking seen in ' + CONVERT(nvarchar(10), @BlockSamples) + N' sample(s); longest wait ' + CONVERT(nvarchar(10), @BlockMaxWait) + N' seconds.' END + N'</p>';
    IF @T IS NOT NULL
        SET @Tail = @Tail + N'<h3>Top head blockers</h3><table><tr><th>Login</th><th>Host</th><th>Program</th><th>Database</th><th>Samples</th><th>Last statement</th></tr>' + @T + N'</table>';

    SET @Tail = @Tail + N'<div class="foot">This is a high-level operational review provided under the Molehill Watch SQL Server Support Package. It is not a full SQL Server health check or performance tuning exercise.<br />'
            + N'Generated ' + dbo.fn_Date(@Now) + N' by Molehill Watch on ' + dbo.fn_Html(@Instance) + N'. Report #' + CONVERT(nvarchar(10), @ReportId) + N'.<br />'
            + N'Molehill Data Services &#183; jay@jayparry.co.uk &#183; molehilldataservices.com</div></div></body></html>';

    DECLARE @HtmlFull nvarchar(max) = @H + @QHead + ISNULL(@QFull, @Empty) + @QFoot + @Tail;
    UPDATE dbo.WeeklyReport SET Html = @HtmlFull WHERE ReportId = @ReportId;

    /*-------------------------------------------------------------- E-MAIL */
    DECLARE @Profile sysname = NULLIF(dbo.fn_Setting('ReportEmailProfile'), N''),
            @Recipients nvarchar(1000) = NULLIF(dbo.fn_Setting('ReportEmailRecipients'), N'');
    IF @SendEmail = 1 AND @Profile IS NOT NULL AND @Recipients IS NOT NULL
    BEGIN
        DECLARE @Body nvarchar(max) = CASE WHEN dbo.fn_SettingInt('ReportEmailIncludeQueryText', 0) = 1 THEN @HtmlFull
                                           ELSE @H + @QHead + ISNULL(@QNoText, @Empty) + @QFoot + @Tail END;
        DECLARE @Subject nvarchar(255) = LEFT(N'[Molehill Watch] ' + UPPER(@Overall) + N' - ' + @Client + N' - ' + @Instance + N' - week to ' + CONVERT(nvarchar(11), @Now, 106), 255);
        BEGIN TRY
            EXEC msdb.dbo.sp_send_dbmail @profile_name = @Profile, @recipients = @Recipients, @subject = @Subject, @body = @Body, @body_format = 'HTML';
            UPDATE dbo.WeeklyReport SET EmailedAt = GETDATE() WHERE ReportId = @ReportId;
        END TRY
        BEGIN CATCH
            UPDATE dbo.WeeklyReport SET EmailError = LEFT(ERROR_MESSAGE(), 2000) WHERE ReportId = @ReportId;
        END CATCH;
    END

    IF @ReturnResults = 1
        EXEC dbo.usp_ShowReport @ReportId = @ReportId;
END
GO

IF OBJECT_ID(N'dbo.usp_ShowReport', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_ShowReport AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_ShowReport
    @ReportId int = NULL      -- NULL = latest
AS
BEGIN
    SET NOCOUNT ON;
    IF @ReportId IS NULL SET @ReportId = (SELECT MAX(ReportId) FROM dbo.WeeklyReport);

    SELECT ReportId, GeneratedAt, PeriodStart, PeriodEnd, ClientName, InstanceName, OverallStatus,
           CriticalCount, WarningCount, InfoCount, EmailedAt, EmailError
    FROM dbo.WeeklyReport WHERE ReportId = @ReportId;

    SELECT Severity, Section, Item, Detail, Recommendation
    FROM dbo.ReportFinding WHERE ReportId = @ReportId
    ORDER BY CASE Severity WHEN 'Critical' THEN 1 WHEN 'Warning' THEN 2 ELSE 3 END, FindingId;
END
GO

/*=============================================================================
  8. INVENTORY (used by Export-WeeklyReports.ps1 for AG replica parity checks)
=============================================================================*/
IF OBJECT_ID(N'dbo.usp_Inventory', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_Inventory AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_Inventory
AS
BEGIN
    SET NOCOUNT ON;
    -- 1: Availability Groups this instance belongs to
    IF ISNULL(CONVERT(int, SERVERPROPERTY('IsHadrEnabled')), 0) = 1
        EXEC (N'SELECT ServerName = @@SERVERNAME, AgName = ag.name, LocalRole = ars.role_desc,
                       Replicas = STUFF((SELECT N'','' + r2.replica_server_name FROM sys.availability_replicas r2
                                         WHERE r2.group_id = ag.group_id ORDER BY r2.replica_server_name
                                         FOR XML PATH(''''), TYPE).value(''.'', ''nvarchar(max)''), 1, 1, N'''')
                FROM sys.availability_groups ag
                JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id
                JOIN sys.dm_hadr_availability_replica_states ars ON ars.replica_id = ar.replica_id AND ars.is_local = 1;');
    ELSE
        SELECT ServerName = @@SERVERNAME, AgName = CAST(NULL AS sysname), LocalRole = CAST(NULL AS nvarchar(60)), Replicas = CAST(NULL AS nvarchar(max)) WHERE 1 = 0;

    -- 2: SQL Agent jobs with a fingerprint of their steps and schedules
    SELECT JobName = j.name, IsEnabled = j.enabled, Category = c.name,
           StepCount = (SELECT COUNT(*) FROM msdb.dbo.sysjobsteps s WHERE s.job_id = j.job_id),
           StepFingerprint = (SELECT CHECKSUM_AGG(CHECKSUM(s.step_id, s.step_name, s.subsystem, s.command, s.database_name)) FROM msdb.dbo.sysjobsteps s WHERE s.job_id = j.job_id),
           EnabledSchedules = (SELECT COUNT(*) FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id WHERE js.job_id = j.job_id AND sc.enabled = 1)
    FROM msdb.dbo.sysjobs j
    LEFT JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
    ORDER BY j.name;

    -- 3: Logins (SIDs matter for SQL logins after failover)
    SELECT LoginName = name, LoginType = type_desc, IsDisabled = is_disabled,
           Sid = CONVERT(varchar(200), sid, 1), DefaultDatabase = default_database_name,
           IsSysadmin = IS_SRVROLEMEMBER('sysadmin', name)
    FROM sys.server_principals
    WHERE type IN ('S', 'U', 'G') AND name NOT LIKE N'##%'
    ORDER BY name;
END
GO

/*=============================================================================
  9. ORCHESTRATION, ACCESS AND JOBS
=============================================================================*/
IF OBJECT_ID(N'dbo.usp_Collect', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_Collect AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_Collect
    @Type varchar(20)   -- Frequent | Hourly | Daily | Weekly | All
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @steps TABLE (StepOrder int IDENTITY(1,1), StepName varchar(100), Command nvarchar(400));

    IF @Type IN ('Frequent', 'All')
        INSERT @steps (StepName, Command) VALUES ('AvailabilityGroups', N'EXEC dbo.usp_CollectAvailabilityGroups;'), ('Blocking', N'EXEC dbo.usp_CollectBlocking;');
    IF @Type IN ('Hourly', 'All', 'Weekly')
        INSERT @steps (StepName, Command) VALUES ('ErrorLog', N'EXEC dbo.usp_CollectErrorLog;'), ('JobFailures', N'EXEC dbo.usp_CollectJobFailures;');
    IF @Type IN ('Hourly', 'All')
        INSERT @steps (StepName, Command) VALUES ('QueryStats', N'EXEC dbo.usp_CollectQueryStats;');
    IF @Type IN ('Daily', 'All')
        INSERT @steps (StepName, Command) VALUES ('Disk', N'EXEC dbo.usp_CollectDisk;'), ('DatabaseFiles', N'EXEC dbo.usp_CollectDatabaseFiles;'), ('Purge', N'EXEC dbo.usp_PurgeHistory;');
    IF @Type IN ('Daily', 'All', 'Weekly')
        INSERT @steps (StepName, Command) VALUES ('PatchLevel', N'EXEC dbo.usp_CollectPatchLevel;');
    IF @Type = 'Weekly'
        INSERT @steps (StepName, Command) VALUES ('WeeklyReport', N'EXEC dbo.usp_BuildWeeklyReport @SendEmail = 1, @ReturnResults = 0;');

    IF NOT EXISTS (SELECT 1 FROM @steps)
    BEGIN
        RAISERROR(N'@Type must be Frequent, Hourly, Daily, Weekly or All.', 16, 1);
        RETURN;
    END

    DECLARE @i int = 1, @max int = (SELECT MAX(StepOrder) FROM @steps), @name varchar(100), @cmd nvarchar(400), @logId bigint, @failed int = 0, @msg nvarchar(4000);
    WHILE @i <= @max
    BEGIN
        SELECT @name = StepName, @cmd = Command FROM @steps WHERE StepOrder = @i;
        INSERT dbo.CollectionLog (CollectionType, StepName, StartTime) VALUES (@Type, @name, GETDATE());
        SET @logId = SCOPE_IDENTITY();
        BEGIN TRY
            EXEC sp_executesql @cmd;
            UPDATE dbo.CollectionLog SET EndTime = GETDATE(), Succeeded = 1 WHERE LogId = @logId;
        END TRY
        BEGIN CATCH
            SET @msg = LEFT(ERROR_MESSAGE(), 4000);
            IF XACT_STATE() <> 0 ROLLBACK;
            UPDATE dbo.CollectionLog SET EndTime = GETDATE(), Succeeded = 0, ErrorMessage = @msg WHERE LogId = @logId;
            SET @failed = @failed + 1;
            PRINT N'Step ' + @name + N' failed: ' + @msg;
        END CATCH;
        SET @i = @i + 1;
    END

    IF @failed > 0
        RAISERROR(N'Molehill Watch: %d collection step(s) failed. See MolehillWatch.dbo.CollectionLog.', 16, 1, @failed);
END
GO

IF OBJECT_ID(N'dbo.usp_GrantMolehillAccess', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_GrantMolehillAccess AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_GrantMolehillAccess
    @LoginName sysname,                -- N'CONTOSO\svc-molehill' (Windows) or N'molehill_support' (SQL login)
    @Password  nvarchar(128) = NULL,   -- SQL logins only: creates the login if it does not exist
    @Sid       varbinary(85) = NULL    -- SQL logins only: create with this SID (keep AG replicas identical)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @q nvarchar(300) = QUOTENAME(@LoginName), @sql nvarchar(max), @user sysname;
    DECLARE @lit nvarchar(300) = N'N''' + REPLACE(@LoginName, N'''', N'''''') + N'''';
    DECLARE @IsWindows bit = CASE WHEN CHARINDEX(N'\', @LoginName) > 0 THEN 1 ELSE 0 END;

    IF SUSER_ID(@LoginName) IS NULL
    BEGIN
        IF @IsWindows = 1
        BEGIN
            SET @sql = N'CREATE LOGIN ' + @q + N' FROM WINDOWS WITH DEFAULT_DATABASE = [master];';
            EXEC (@sql);
            PRINT N'Created Windows login ' + @LoginName;
        END
        ELSE IF @Password IS NOT NULL
        BEGIN
            SET @sql = N'CREATE LOGIN ' + @q + N' WITH PASSWORD = N''' + REPLACE(@Password, N'''', N'''''') + N''''
                     + CASE WHEN @Sid IS NOT NULL THEN N', SID = ' + CONVERT(nvarchar(200), @Sid, 1) ELSE N'' END
                     + N', DEFAULT_DATABASE = [master], CHECK_POLICY = ON, CHECK_EXPIRATION = OFF;';
            EXEC (@sql);
            PRINT N'Created SQL login ' + @LoginName + N' (password policy on, expiry off' + CASE WHEN @Sid IS NOT NULL THEN N', SID matched to first instance' ELSE N'' END + N').';
        END
        ELSE
        BEGIN
            RAISERROR(N'SQL login "%s" does not exist. Create it first, or pass a password so the installer can create it.', 16, 1, @LoginName);
            RETURN;
        END
    END
    ELSE IF @IsWindows = 0
    BEGIN
        IF @Password IS NOT NULL
            PRINT N'SQL login ' + @LoginName + N' already exists - password left unchanged.';
        IF @Sid IS NOT NULL AND SUSER_SID(@LoginName) <> @Sid
            PRINT N'WARNING: SQL login ' + @LoginName + N' already exists with a different SID (' + CONVERT(nvarchar(200), SUSER_SID(@LoginName), 1)
                + N') from the first instance (' + CONVERT(nvarchar(200), @Sid, 1) + N'). On Availability Group replicas, recreate it with SID = '
                + CONVERT(nvarchar(200), @Sid, 1) + N' so access survives a failover.';
    END

    IF @IsWindows = 0 AND CONVERT(int, SERVERPROPERTY('IsIntegratedSecurityOnly')) = 1
        PRINT N'WARNING: this instance only allows Windows authentication, so SQL login ' + @LoginName
            + N' cannot sign in yet. Enable "SQL Server and Windows Authentication mode" (Server properties > Security) and restart the SQL Server service.';

    -- Server level: read-only visibility of health, configuration and performance data
    SET @sql = N'USE master; GRANT VIEW SERVER STATE TO ' + @q + N'; GRANT VIEW ANY DEFINITION TO ' + @q + N';';
    IF CONVERT(int, PARSENAME(CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')), 4)) >= 12
        SET @sql = @sql + N' GRANT CONNECT ANY DATABASE TO ' + @q + N';';
    EXEC (@sql);

    -- MolehillWatch: read everything, run the report viewers
    IF DATABASE_PRINCIPAL_ID(N'MolehillWatchReader') IS NULL
        CREATE ROLE MolehillWatchReader;
    GRANT SELECT ON SCHEMA::dbo TO MolehillWatchReader;
    GRANT EXECUTE ON dbo.usp_ShowReport TO MolehillWatchReader;
    GRANT EXECUTE ON dbo.usp_Inventory TO MolehillWatchReader;
    GRANT EXECUTE ON dbo.usp_PatchStatus TO MolehillWatchReader;
    -- lets the weekly export refresh Microsoft's published build list (writes only to dbo.PatchReference)
    GRANT EXECUTE ON dbo.usp_PatchReference_Clear TO MolehillWatchReader;
    GRANT EXECUTE ON dbo.usp_PatchReference_Add TO MolehillWatchReader;

    SET @user = (SELECT name FROM sys.database_principals WHERE sid = SUSER_SID(@LoginName));
    IF @user IS NULL
    BEGIN
        SET @sql = N'CREATE USER ' + @q + N' FOR LOGIN ' + @q + N';';
        EXEC (@sql);
        SET @user = @LoginName;
    END
    IF IS_ROLEMEMBER(N'MolehillWatchReader', @user) = 0
    BEGIN
        SET @sql = N'ALTER ROLE MolehillWatchReader ADD MEMBER ' + QUOTENAME(@user) + N';';
        EXEC (@sql);
    END

    -- msdb: read job definitions, history and backup history
    SET @sql = N'USE msdb;
        DECLARE @u sysname = (SELECT name FROM sys.database_principals WHERE sid = SUSER_SID(' + @lit + N'));
        IF @u IS NULL BEGIN CREATE USER ' + @q + N' FOR LOGIN ' + @q + N'; SET @u = ' + @lit + N'; END
        DECLARE @s nvarchar(400) = N''ALTER ROLE SQLAgentReaderRole ADD MEMBER '' + QUOTENAME(@u) + N''; ALTER ROLE db_datareader ADD MEMBER '' + QUOTENAME(@u) + N'';'';
        EXEC (@s);';
    EXEC (@sql);

    PRINT N'Granted Molehill Watch read access to ' + @LoginName + N'.';
END
GO

IF OBJECT_ID(N'dbo.usp_InstallJobs', N'P') IS NULL EXEC (N'CREATE PROCEDURE dbo.usp_InstallJobs AS RETURN 0;');
GO
ALTER PROCEDURE dbo.usp_InstallJobs
    @Remove bit = 0,     -- 1 = remove the Molehill Watch jobs only
    @Force  bit = 0      -- 1 = create jobs even on Express (testing only)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @job sysname;

    DECLARE jobs CURSOR LOCAL FAST_FORWARD FOR
        SELECT j.name FROM msdb.dbo.sysjobs j JOIN msdb.dbo.syscategories c ON c.category_id = j.category_id
        WHERE c.name = N'Molehill Watch';
    OPEN jobs;
    FETCH NEXT FROM jobs INTO @job;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        EXEC msdb.dbo.sp_delete_job @job_name = @job, @delete_unused_schedule = 1;
        FETCH NEXT FROM jobs INTO @job;
    END
    CLOSE jobs; DEALLOCATE jobs;

    IF @Remove = 1 BEGIN PRINT N'Molehill Watch jobs removed.'; RETURN; END

    IF CONVERT(int, SERVERPROPERTY('EngineEdition')) = 4 AND @Force = 0
    BEGIN
        PRINT N'Express edition detected: SQL Server Agent is not available, so no jobs were created.';
        PRINT N'Run Install-MolehillWatch.ps1 with -UseTaskScheduler to schedule collection with Windows Task Scheduler.';
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM msdb.dbo.syscategories WHERE name = N'Molehill Watch' AND category_class = 1)
        EXEC msdb.dbo.sp_add_category @class = N'JOB', @type = N'LOCAL', @name = N'Molehill Watch';

    DECLARE @owner sysname = SUSER_SNAME(0x01);
    DECLARE @defs TABLE (JobName sysname, CollectType varchar(20), Descr nvarchar(512),
                         FreqType int, FreqInterval int, SubdayType int, SubdayInterval int, StartTime int);
    INSERT @defs VALUES
        (N'Molehill Watch - Collect Frequent', 'Frequent', N'Availability Group health and blocking samples (every 5 minutes).', 4, 1, 4, 5, 0),
        (N'Molehill Watch - Collect Hourly',   'Hourly',   N'Error log, failed job history and query statistics (hourly).',   4, 1, 8, 1, 200),
        (N'Molehill Watch - Collect Daily',    'Daily',    N'Disk space and database size snapshots, history purge (daily).', 4, 1, 1, 0, 53000),
        (N'Molehill Watch - Weekly Report',    'Weekly',   N'Builds (and optionally e-mails) the weekly status report (Mondays).', 8, 2, 1, 0, 63000);

    DECLARE @name sysname, @type varchar(20), @descr nvarchar(512), @ft int, @fi int, @st int, @si int, @start int, @cmd nvarchar(400);
    DECLARE d CURSOR LOCAL FAST_FORWARD FOR SELECT JobName, CollectType, Descr, FreqType, FreqInterval, SubdayType, SubdayInterval, StartTime FROM @defs;
    OPEN d;
    FETCH NEXT FROM d INTO @name, @type, @descr, @ft, @fi, @st, @si, @start;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @cmd = N'EXEC dbo.usp_Collect @Type = ''' + @type + N''';';
        EXEC msdb.dbo.sp_add_job @job_name = @name, @enabled = 1, @description = @descr, @category_name = N'Molehill Watch', @owner_login_name = @owner;
        EXEC msdb.dbo.sp_add_jobstep @job_name = @name, @step_name = N'Collect', @subsystem = N'TSQL', @database_name = N'MolehillWatch', @command = @cmd, @retry_attempts = 0;
        EXEC msdb.dbo.sp_add_jobschedule @job_name = @name, @name = @name, @enabled = 1, @freq_type = @ft, @freq_interval = @fi,
             @freq_subday_type = @st, @freq_subday_interval = @si, @freq_recurrence_factor = 1, @active_start_time = @start;
        EXEC msdb.dbo.sp_add_jobserver @job_name = @name, @server_name = N'(local)';
        PRINT N'Created job: ' + @name;
        FETCH NEXT FROM d INTO @name, @type, @descr, @ft, @fi, @st, @si, @start;
    END
    CLOSE d; DEALLOCATE d;
END
GO

/*=============================================================================
  10. FINISH
=============================================================================*/
EXEC dbo.usp_InstallJobs;
INSERT dbo.InstallHistory (Version) VALUES ('1.0.0');
PRINT N'Molehill Watch 1.0.0 installed on ' + ISNULL(@@SERVERNAME, N'this instance') + N'.';
GO

/*=============================================================================
  CONFIGURE  (manual installs only - the PowerShell installer does this for you)
  Highlight and run the lines below after editing the values.
=============================================================================

EXEC MolehillWatch.dbo.usp_Configure
     @ClientName            = N'Client Ltd',
     @InstanceDisplayName   = N'',                   -- blank = server name
     @ReportEmailProfile    = N'',                   -- Database Mail profile, blank = no e-mail
     @ReportEmailRecipients = N'';                   -- e.g. N'it@client.co.uk'

EXEC MolehillWatch.dbo.usp_GrantMolehillAccess @LoginName = N'DOMAIN\svc-molehill';
-- or, without a domain, a SQL login (created if missing; on AG replicas pass the first replica's SID):
-- EXEC MolehillWatch.dbo.usp_GrantMolehillAccess @LoginName = N'molehill_support', @Password = N'<strong password>', @Sid = NULL;

EXEC MolehillWatch.dbo.usp_Collect @Type = 'All';          -- first collection
EXEC MolehillWatch.dbo.usp_BuildWeeklyReport;              -- baseline report

=============================================================================*/
