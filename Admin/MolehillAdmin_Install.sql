/*
===============================================================================
 Molehill Watch - SQL Server Support Package
 Molehill Admin: contract, ticket, time and billing database     Version 1.2.0
 Molehill Data Services  -  jay@jayparry.co.uk  -  molehilldataservices.com
-------------------------------------------------------------------------------
 Runs on YOUR OWN SQL Server (Express is fine), not on client servers.
 Requires SQL Server 2017 or later.

 Implements the commercial terms of the Molehill Watch agreement:
   * pricing: GBP 450 1st/2nd server, GBP 375 3rd+, GBP 225 AG/standby secondaries,
     FCI billed per instance, non-production only by agreed fee
   * 3 included business-hours support hours per billing cycle (no roll-over)
   * GBP 75/h business hours, GBP 115/h out of hours, 1 hour minimum per ticket
   * ticket SLA: Critical same business day, Standard within 1 full business day
     (Mon-Fri 09:00-17:30 UK time, excluding bank holidays)
   * >1 hour work flagged for an estimate before continuing
   * billing cycles from the client start date, fees in advance, extra support
     in arrears, 14 day payment terms, no VAT (configurable)
   * 3 month initial term, then 1 full calendar month's notice ending at the close
     of the billing cycle; price changes max once a year with 1 month's notice
   * onboarding checklist, weekly report tracking, unsupported-version risk records

 EASIEST: run Install-MolehillAdmin.ps1.   MANUAL: run in SSMS (F5).
 Safe to re-run: objects are upgraded in place and data is kept.
 Everyday use: see Docs\Admin-Guide.md.
===============================================================================
*/
SET NOCOUNT ON;
GO
IF CONVERT(int, PARSENAME(CONVERT(varchar(32), SERVERPROPERTY('ProductVersion')), 4)) < 14
    RAISERROR('Molehill Admin requires SQL Server 2017 or later (Express edition is fine). Installation stopped.', 20, 1) WITH LOG;
GO
USE master;
GO
IF DB_ID(N'MolehillAdmin') IS NULL
BEGIN
    CREATE DATABASE MolehillAdmin;
    PRINT 'Created database MolehillAdmin.';
END
GO
ALTER DATABASE MolehillAdmin SET AUTO_CLOSE OFF;
GO
USE MolehillAdmin;
GO

/*=============================================================================
  1. TABLES
=============================================================================*/
IF OBJECT_ID(N'dbo.InstallHistory') IS NULL
CREATE TABLE dbo.InstallHistory (
    InstallId   int IDENTITY(1,1) CONSTRAINT PK_InstallHistory PRIMARY KEY,
    Version     varchar(20)  NOT NULL,
    InstalledAt datetime2(0) NOT NULL CONSTRAINT DF_InstallHistory_At DEFAULT SYSDATETIME());

IF OBJECT_ID(N'dbo.Setting') IS NULL
CREATE TABLE dbo.Setting (
    Name        varchar(100)   NOT NULL CONSTRAINT PK_Setting PRIMARY KEY,
    Value       nvarchar(4000) NULL,
    Description nvarchar(1000) NULL);

IF OBJECT_ID(N'dbo.BankHoliday') IS NULL
CREATE TABLE dbo.BankHoliday (
    HolidayDate date          NOT NULL CONSTRAINT PK_BankHoliday PRIMARY KEY,
    Name        nvarchar(100) NOT NULL);

IF OBJECT_ID(N'dbo.ProductLifecycle') IS NULL
CREATE TABLE dbo.ProductLifecycle (
    ProductName   nvarchar(100) NOT NULL CONSTRAINT PK_ProductLifecycle PRIMARY KEY,
    VersionKey    varchar(20)   NOT NULL,  -- what you type in Instance.SqlVersion, e.g. '2016'
    MainstreamEnd date          NULL,
    ExtendedEnd   date          NULL);

IF OBJECT_ID(N'dbo.PriceList') IS NULL
CREATE TABLE dbo.PriceList (
    PriceListId           int IDENTITY(1,1) CONSTRAINT PK_PriceList PRIMARY KEY,
    Name                  nvarchar(100) NOT NULL CONSTRAINT UQ_PriceList_Name UNIQUE,
    EffectiveFrom         date          NOT NULL,
    IsStandard            bit           NOT NULL CONSTRAINT DF_PriceList_IsStandard DEFAULT 1,
    ServerFee             decimal(9,2)  NOT NULL,   -- 1st and 2nd production instance
    ServerFeeTiered       decimal(9,2)  NOT NULL,   -- from TierFromServerNumber onwards
    TierFromServerNumber  int           NOT NULL,
    SecondaryReplicaFee   decimal(9,2)  NOT NULL,
    IncludedHoursPerCycle decimal(5,2)  NOT NULL,
    BusinessHoursRate     decimal(9,2)  NOT NULL,
    OutOfHoursRate        decimal(9,2)  NOT NULL,
    MinimumChargeHours    decimal(5,2)  NOT NULL,
    InitialTermMonths     int           NOT NULL);

IF OBJECT_ID(N'dbo.Client') IS NULL
CREATE TABLE dbo.Client (
    ClientId     int IDENTITY(1,1) CONSTRAINT PK_Client PRIMARY KEY,
    ClientName   nvarchar(200) NOT NULL CONSTRAINT UQ_Client_Name UNIQUE,
    Address      nvarchar(500) NULL,
    BillingEmail nvarchar(320) NULL,
    Notes        nvarchar(max) NULL,
    CreatedAt    datetime2(0)  NOT NULL CONSTRAINT DF_Client_CreatedAt DEFAULT SYSDATETIME());

IF OBJECT_ID(N'dbo.Contact') IS NULL
CREATE TABLE dbo.Contact (
    ContactId        int IDENTITY(1,1) CONSTRAINT PK_Contact PRIMARY KEY,
    ClientId         int           NOT NULL CONSTRAINT FK_Contact_Client REFERENCES dbo.Client (ClientId),
    FullName         nvarchar(200) NOT NULL,
    Email            nvarchar(320) NULL,
    Phone            nvarchar(50)  NULL,
    IsNamedContact   bit           NOT NULL CONSTRAINT DF_Contact_Named DEFAULT 0,   -- named point of contact for tickets
    IsBillingContact bit           NOT NULL CONSTRAINT DF_Contact_Billing DEFAULT 0,
    IsActive         bit           NOT NULL CONSTRAINT DF_Contact_Active DEFAULT 1);

IF OBJECT_ID(N'dbo.Agreement') IS NULL
CREATE TABLE dbo.Agreement (
    AgreementId          int IDENTITY(1,1) CONSTRAINT PK_Agreement PRIMARY KEY,
    AgreementRef         varchar(30)   NOT NULL CONSTRAINT UQ_Agreement_Ref UNIQUE,
    ClientId             int           NOT NULL CONSTRAINT FK_Agreement_Client REFERENCES dbo.Client (ClientId),
    SignedDate           date          NULL,
    StartDate            date          NOT NULL,     -- billing cycles run from this date
    InitialTermMonths    int           NOT NULL,
    PriceListId          int           NOT NULL CONSTRAINT FK_Agreement_PriceList REFERENCES dbo.PriceList (PriceListId),
    TicketChannel        nvarchar(300) NOT NULL,
    InitialReviewDoneDate date         NULL,
    InitialReviewNotes   nvarchar(max) NULL,
    NoticeGivenDate      date          NULL,
    NoticeGivenBy        varchar(20)   NULL CONSTRAINT CK_Agreement_NoticeBy CHECK (NoticeGivenBy IN ('Client', 'Molehill')),
    EndDate              date          NULL,
    ConfidentialityAgreement bit       NOT NULL CONSTRAINT DF_Agreement_NDA DEFAULT 0,
    DataProcessingAgreement  bit       NOT NULL CONSTRAINT DF_Agreement_DPA DEFAULT 0,
    OutOfHoursCoverNotes nvarchar(500) NULL,         -- separate written emergency cover, if any
    SupportPausedFrom    date          NULL,         -- late payment
    Notes                nvarchar(max) NULL,
    CreatedAt            datetime2(0)  NOT NULL CONSTRAINT DF_Agreement_CreatedAt DEFAULT SYSDATETIME());

IF OBJECT_ID(N'dbo.Instance') IS NULL
CREATE TABLE dbo.Instance (
    InstanceId               int IDENTITY(1,1) CONSTRAINT PK_Instance PRIMARY KEY,
    AgreementId              int           NOT NULL CONSTRAINT FK_Instance_Agreement REFERENCES dbo.Agreement (AgreementId),
    InstanceName             nvarchar(128) NOT NULL,
    Environment              varchar(20)   NOT NULL CONSTRAINT DF_Instance_Env DEFAULT 'Production'
                             CONSTRAINT CK_Instance_Env CHECK (Environment IN ('Production', 'NonProduction')),
    Role                     varchar(30)   NOT NULL CONSTRAINT DF_Instance_Role DEFAULT 'Standalone'
                             CONSTRAINT CK_Instance_Role CHECK (Role IN ('Standalone', 'AGPrimary', 'AGSecondary', 'LogShippingSecondary', 'MirrorSecondary', 'FCI', 'GeoReplica')),
    PricedAsFullInstance     bit           NOT NULL CONSTRAINT DF_Instance_Full DEFAULT 0,  -- busy readable secondary quoted as full
    AgreedMonthlyFee         decimal(9,2)  NULL,      -- bespoke price; required for non-production
    AvailabilityGroup        nvarchar(128) NULL,
    PrimaryInstanceId        int           NULL CONSTRAINT FK_Instance_Primary REFERENCES dbo.Instance (InstanceId),
    FciNodes                 nvarchar(400) NULL,
    SqlVersion               varchar(20)   NULL,      -- e.g. '2019'
    Edition                  nvarchar(100) NULL,
    OsVersion                nvarchar(100) NULL,
    UnsupportedRiskAcceptedBy   nvarchar(200) NULL,
    UnsupportedRiskAcceptedDate date       NULL,
    HasExtendedSecurityUpdates  bit        NOT NULL CONSTRAINT DF_Instance_ESU DEFAULT 0,
    CoveredFrom              date          NOT NULL,
    CoveredTo                date          NULL,
    MonitoringInstalledDate  date          NULL,
    Notes                    nvarchar(max) NULL,
    CONSTRAINT CK_Instance_NonProdFee CHECK (Environment = 'Production' OR AgreedMonthlyFee IS NOT NULL));

-- Azure SQL (agreement update): platform, database count for Azure SQL Database units, geo-replica role
IF COL_LENGTH(N'dbo.Instance', N'Platform') IS NULL
    ALTER TABLE dbo.Instance ADD Platform varchar(40) NOT NULL CONSTRAINT DF_Instance_Platform DEFAULT 'SqlServer'
        CONSTRAINT CK_Instance_Platform CHECK (Platform IN ('SqlServer', 'AzureSqlManagedInstance', 'AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool'));
IF COL_LENGTH(N'dbo.Instance', N'DatabaseCount') IS NULL
    ALTER TABLE dbo.Instance ADD DatabaseCount int NULL;     -- Azure SQL Database logical server / elastic pool only
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Instance_Role' AND definition NOT LIKE N'%GeoReplica%')
BEGIN
    ALTER TABLE dbo.Instance DROP CONSTRAINT CK_Instance_Role;
    ALTER TABLE dbo.Instance ADD CONSTRAINT CK_Instance_Role
        CHECK (Role IN ('Standalone', 'AGPrimary', 'AGSecondary', 'LogShippingSecondary', 'MirrorSecondary', 'FCI', 'GeoReplica'));
END
IF COL_LENGTH(N'dbo.PriceList', N'AzureSqlDbUnitFee') IS NULL
    ALTER TABLE dbo.PriceList ADD
        AzureSqlDbUnitFee           decimal(9,2) NOT NULL CONSTRAINT DF_PriceList_AzureUnit DEFAULT 300,   -- per logical server / elastic pool
        AzureSqlDbIncludedDatabases int          NOT NULL CONSTRAINT DF_PriceList_AzureIncl DEFAULT 5,     -- databases covered by the unit fee
        AzureSqlDbExtraDatabaseFee  decimal(9,2) NOT NULL CONSTRAINT DF_PriceList_AzureExtra DEFAULT 40;   -- each database beyond that
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_Instance_AzureDbCount')
    ALTER TABLE dbo.Instance ADD CONSTRAINT CK_Instance_AzureDbCount
        CHECK (Platform NOT IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool') OR Role = 'GeoReplica' OR DatabaseCount >= 1);
GO

-- Contact history: one row per period someone was a contact (removed and re-added = two rows).
-- Contact.IsActive is kept in step: 1 while the contact has an open period (EndDate NULL).
IF OBJECT_ID(N'dbo.ContactPeriod') IS NULL
BEGIN
    CREATE TABLE dbo.ContactPeriod (
        ContactPeriodId int IDENTITY(1,1) CONSTRAINT PK_ContactPeriod PRIMARY KEY,
        ContactId       int           NOT NULL CONSTRAINT FK_ContactPeriod_Contact REFERENCES dbo.Contact (ContactId),
        StartDate       date          NOT NULL,
        EndDate         date          NULL,      -- last day as a contact; NULL = current
        EndReason       nvarchar(400) NULL,
        CONSTRAINT CK_ContactPeriod_Dates CHECK (EndDate IS NULL OR EndDate >= StartDate));
    CREATE UNIQUE INDEX UX_ContactPeriod_Open ON dbo.ContactPeriod (ContactId) WHERE EndDate IS NULL;

    -- contacts from before the history was kept: a contact since the client was set up
    INSERT dbo.ContactPeriod (ContactId, StartDate, EndDate, EndReason)
    SELECT ct.ContactId, CAST(c.CreatedAt AS date),
           CASE WHEN ct.IsActive = 0 THEN CAST(SYSDATETIME() AS date) END,
           CASE WHEN ct.IsActive = 0 THEN N'Already inactive when contact history started' END
    FROM dbo.Contact ct JOIN dbo.Client c ON c.ClientId = ct.ClientId;
END
GO

IF OBJECT_ID(N'dbo.OnboardingItem') IS NULL
CREATE TABLE dbo.OnboardingItem (
    AgreementId   int           NOT NULL CONSTRAINT FK_OnboardingItem_Agreement REFERENCES dbo.Agreement (AgreementId),
    ItemCode      varchar(30)   NOT NULL,
    SortOrder     int           NOT NULL,
    Description   nvarchar(400) NOT NULL,
    IsRequired    bit           NOT NULL,
    CompletedDate date          NULL,
    Notes         nvarchar(1000) NULL,
    CONSTRAINT PK_OnboardingItem PRIMARY KEY (AgreementId, ItemCode));

IF OBJECT_ID(N'dbo.PriceChange') IS NULL
CREATE TABLE dbo.PriceChange (
    PriceChangeId  int IDENTITY(1,1) CONSTRAINT PK_PriceChange PRIMARY KEY,
    AgreementId    int  NOT NULL CONSTRAINT FK_PriceChange_Agreement REFERENCES dbo.Agreement (AgreementId),
    NewPriceListId int  NOT NULL CONSTRAINT FK_PriceChange_PriceList REFERENCES dbo.PriceList (PriceListId),
    NotifiedDate   date NOT NULL,
    EffectiveDate  date NOT NULL);

IF OBJECT_ID(N'dbo.Ticket') IS NULL
CREATE TABLE dbo.Ticket (
    TicketId           int IDENTITY(1,1) CONSTRAINT PK_Ticket PRIMARY KEY,
    TicketRef          AS ('MW-' + RIGHT('00000' + CONVERT(varchar(10), TicketId), 5)) PERSISTED,
    AgreementId        int           NOT NULL CONSTRAINT FK_Ticket_Agreement REFERENCES dbo.Agreement (AgreementId),
    InstanceId         int           NULL CONSTRAINT FK_Ticket_Instance REFERENCES dbo.Instance (InstanceId),
    ContactId          int           NULL CONSTRAINT FK_Ticket_Contact REFERENCES dbo.Contact (ContactId),
    Severity           varchar(10)   NOT NULL CONSTRAINT CK_Ticket_Severity CHECK (Severity IN ('Critical', 'Standard')),
    WorkType           varchar(20)   NOT NULL CONSTRAINT DF_Ticket_WorkType DEFAULT 'Support'
                       CONSTRAINT CK_Ticket_WorkType CHECK (WorkType IN ('Support', 'PlannedOutOfHours', 'Project')),
    Title              nvarchar(200) NOT NULL,
    Description        nvarchar(max) NULL,
    Channel            nvarchar(50)  NULL,
    RaisedAt           datetime2(0)  NOT NULL,
    ResponseDueAt      datetime2(0)  NOT NULL,
    FirstResponseAt    datetime2(0)  NULL,
    Status             varchar(30)   NOT NULL CONSTRAINT DF_Ticket_Status DEFAULT 'Open'
                       CONSTRAINT CK_Ticket_Status CHECK (Status IN ('Open', 'InProgress', 'AwaitingClient', 'AwaitingEstimateApproval', 'Resolved', 'Closed')),
    EstimateHours      decimal(6,2)  NULL,
    EstimateSentAt     datetime2(0)  NULL,
    EstimateApprovedAt datetime2(0)  NULL,
    ResolvedAt         datetime2(0)  NULL,
    Resolution         nvarchar(max) NULL,
    CreatedAt          datetime2(0)  NOT NULL CONSTRAINT DF_Ticket_CreatedAt DEFAULT SYSDATETIME());

IF OBJECT_ID(N'dbo.Invoice') IS NULL
CREATE TABLE dbo.Invoice (
    InvoiceId   int IDENTITY(1,1) CONSTRAINT PK_Invoice PRIMARY KEY,
    InvoiceNo   varchar(30)   NOT NULL CONSTRAINT UQ_Invoice_No UNIQUE,
    AgreementId int           NOT NULL CONSTRAINT FK_Invoice_Agreement REFERENCES dbo.Agreement (AgreementId),
    InvoiceDate date          NOT NULL,
    DueDate     date          NOT NULL,
    SubTotal    decimal(10,2) NOT NULL CONSTRAINT DF_Invoice_SubTotal DEFAULT 0,
    VatRatePct  decimal(5,2)  NOT NULL CONSTRAINT DF_Invoice_VatRate DEFAULT 0,
    VatAmount   decimal(10,2) NOT NULL CONSTRAINT DF_Invoice_Vat DEFAULT 0,
    Total       decimal(10,2) NOT NULL CONSTRAINT DF_Invoice_Total DEFAULT 0,
    Status      varchar(10)   NOT NULL CONSTRAINT DF_Invoice_Status DEFAULT 'Draft'
                CONSTRAINT CK_Invoice_Status CHECK (Status IN ('Draft', 'Sent', 'Paid', 'Void')),
    SentAt      date          NULL,
    PaidAt      date          NULL,
    Notes       nvarchar(1000) NULL,
    CreatedAt   datetime2(0)  NOT NULL CONSTRAINT DF_Invoice_CreatedAt DEFAULT SYSDATETIME());

IF OBJECT_ID(N'dbo.BillingCycle') IS NULL
CREATE TABLE dbo.BillingCycle (
    BillingCycleId     int IDENTITY(1,1) CONSTRAINT PK_BillingCycle PRIMARY KEY,
    AgreementId        int          NOT NULL CONSTRAINT FK_BillingCycle_Agreement REFERENCES dbo.Agreement (AgreementId),
    CycleNumber        int          NOT NULL,
    StartDate          date         NOT NULL,
    EndDate            date         NOT NULL,
    PriceListId        int          NOT NULL CONSTRAINT FK_BillingCycle_PriceList REFERENCES dbo.PriceList (PriceListId),
    IncludedHours      decimal(5,2) NOT NULL,
    IncludedHoursUsed  decimal(6,2) NOT NULL CONSTRAINT DF_BillingCycle_Used DEFAULT 0,
    FeeInvoiceId       int          NULL CONSTRAINT FK_BillingCycle_FeeInvoice REFERENCES dbo.Invoice (InvoiceId),
    ArrearsProcessedAt datetime2(0) NULL,
    CONSTRAINT UQ_BillingCycle UNIQUE (AgreementId, CycleNumber));

IF OBJECT_ID(N'dbo.InvoiceLine') IS NULL
CREATE TABLE dbo.InvoiceLine (
    InvoiceLineId  int IDENTITY(1,1) CONSTRAINT PK_InvoiceLine PRIMARY KEY,
    InvoiceId      int           NOT NULL CONSTRAINT FK_InvoiceLine_Invoice REFERENCES dbo.Invoice (InvoiceId),
    LineType       varchar(20)   NOT NULL CONSTRAINT CK_InvoiceLine_Type CHECK (LineType IN ('MonthlyFee', 'BusinessHours', 'OutOfHours', 'Project', 'Adjustment', 'Info')),
    BillingCycleId int           NULL,
    InstanceId     int           NULL,
    TicketId       int           NULL,
    Description    nvarchar(500) NOT NULL,
    Quantity       decimal(9,2)  NOT NULL,
    UnitPrice      decimal(9,2)  NOT NULL,
    Amount         decimal(10,2) NOT NULL);

IF OBJECT_ID(N'dbo.TimeEntry') IS NULL
CREATE TABLE dbo.TimeEntry (
    TimeEntryId int IDENTITY(1,1) CONSTRAINT PK_TimeEntry PRIMARY KEY,
    TicketId    int           NOT NULL CONSTRAINT FK_TimeEntry_Ticket REFERENCES dbo.Ticket (TicketId),
    WorkStart   datetime2(0)  NOT NULL,
    Minutes     int           NOT NULL CONSTRAINT CK_TimeEntry_Minutes CHECK (Minutes > 0),
    RateType    varchar(20)   NOT NULL CONSTRAINT CK_TimeEntry_Rate CHECK (RateType IN ('BusinessHours', 'OutOfHours')),
    Description nvarchar(1000) NOT NULL,
    IsBillable  bit           NOT NULL CONSTRAINT DF_TimeEntry_Billable DEFAULT 1,
    InvoiceId   int           NULL CONSTRAINT FK_TimeEntry_Invoice REFERENCES dbo.Invoice (InvoiceId),
    CreatedAt   datetime2(0)  NOT NULL CONSTRAINT DF_TimeEntry_CreatedAt DEFAULT SYSDATETIME());

IF OBJECT_ID(N'dbo.WeeklyReportLog') IS NULL
CREATE TABLE dbo.WeeklyReportLog (
    WeeklyReportLogId int IDENTITY(1,1) CONSTRAINT PK_WeeklyReportLog PRIMARY KEY,
    InstanceId        int           NOT NULL CONSTRAINT FK_WeeklyReportLog_Instance REFERENCES dbo.Instance (InstanceId),
    WeekEnding        date          NOT NULL,
    SentAt            datetime2(0)  NOT NULL,
    OverallStatus     varchar(10)   NULL CONSTRAINT CK_WeeklyReportLog_Status CHECK (OverallStatus IN ('Red', 'Amber', 'Green')),
    CriticalCount     int           NULL,
    WarningCount      int           NULL,
    FollowUpTicketId  int           NULL CONSTRAINT FK_WeeklyReportLog_Ticket REFERENCES dbo.Ticket (TicketId),
    Notes             nvarchar(max) NULL,
    CONSTRAINT UQ_WeeklyReportLog UNIQUE (InstanceId, WeekEnding));

IF OBJECT_ID(N'dbo.Quote') IS NULL
CREATE TABLE dbo.Quote (
    QuoteId        int IDENTITY(1,1) CONSTRAINT PK_Quote PRIMARY KEY,
    QuoteRef       AS ('MQ-' + RIGHT('0000' + CONVERT(varchar(10), QuoteId), 4)) PERSISTED,
    ClientId       int           NOT NULL CONSTRAINT FK_Quote_Client REFERENCES dbo.Client (ClientId),
    TicketId       int           NULL CONSTRAINT FK_Quote_Ticket REFERENCES dbo.Ticket (TicketId),
    Title          nvarchar(200) NOT NULL,
    Scope          nvarchar(max) NULL,
    EstimatedHours decimal(7,2)  NULL,
    Price          decimal(10,2) NULL,
    Status         varchar(10)   NOT NULL CONSTRAINT DF_Quote_Status DEFAULT 'Draft'
                   CONSTRAINT CK_Quote_Status CHECK (Status IN ('Draft', 'Sent', 'Accepted', 'Declined', 'Invoiced')),
    SentDate       date          NULL,
    DecisionDate   date          NULL,
    CreatedAt      datetime2(0)  NOT NULL CONSTRAINT DF_Quote_CreatedAt DEFAULT SYSDATETIME());
GO

/*=============================================================================
  2. REFERENCE DATA
=============================================================================*/
INSERT dbo.Setting (Name, Value, Description)
SELECT v.Name, v.Value, v.Description
FROM (VALUES
    ('BusinessName',        N'Molehill Data Services',         N'Shown on invoices and the dashboard.'),
    ('BusinessEmail',       N'jay@jayparry.co.uk',             N'Shown on invoices.'),
    ('BusinessWebsite',     N'molehilldataservices.com',       N'Shown on invoices.'),
    ('BusinessAddress',     N'',                               N'Your postal address for invoices.'),
    ('PaymentDetails',      N'',                               N'Bank / payment details printed on invoices (e.g. account name, sort code, account number).'),
    ('InvoicePrefix',       N'MDS',                            N'Invoice numbers look like MDS-2026-0001.'),
    ('PaymentTermsDays',    N'14',                             N'Days from invoice date to due date.'),
    ('VatRegistered',       N'0',                              N'1 once VAT registered (notify clients in advance).'),
    ('VatRatePct',          N'20',                             N'VAT rate applied when VatRegistered = 1.'),
    ('BusinessHoursStart',  N'09:00',                          N'UK local time.'),
    ('BusinessHoursEnd',    N'17:30',                          N'UK local time.'),
    ('MinimumChargeMode',   N'Fair',                           N'Fair = included hours are used at actual time, and a ticket is charged so its total is at least the minimum. Strict = the 1 hour minimum per ticket also applies before included hours are deducted.'),
    ('EstimateThresholdMinutes', N'60',                        N'Flag tickets for an estimate once logged time passes this.'),
    ('ReportGraceDays',     N'2',                              N'Days after the week ends (Sunday) before a missing weekly report is flagged.'),
    ('ReviewReminderDays',  N'21',                             N'Days before the end of the initial term to flag the review.'),
    ('AlertEmailProfile',   N'',                               N'Database Mail profile for the daily dashboard e-mail (not available on Express).'),
    ('AlertEmailRecipients',N'',                               N'Recipients for the daily dashboard e-mail.')
) v (Name, Value, Description)
WHERE NOT EXISTS (SELECT 1 FROM dbo.Setting s WHERE s.Name = v.Name);

IF NOT EXISTS (SELECT 1 FROM dbo.PriceList)
    INSERT dbo.PriceList (Name, EffectiveFrom, IsStandard, ServerFee, ServerFeeTiered, TierFromServerNumber, SecondaryReplicaFee,
                          IncludedHoursPerCycle, BusinessHoursRate, OutOfHoursRate, MinimumChargeHours, InitialTermMonths)
    VALUES (N'Standard 2026', '2026-01-01', 1, 450, 375, 3, 225, 3, 75, 115, 1, 3);

-- England & Wales bank holidays (source: gov.uk/bank-holidays). Add future years as they are published.
MERGE dbo.BankHoliday AS t
USING (VALUES
    ('2025-01-01', N'New Year''s Day'), ('2025-04-18', N'Good Friday'), ('2025-04-21', N'Easter Monday'), ('2025-05-05', N'Early May bank holiday'),
    ('2025-05-26', N'Spring bank holiday'), ('2025-08-25', N'Summer bank holiday'), ('2025-12-25', N'Christmas Day'), ('2025-12-26', N'Boxing Day'),
    ('2026-01-01', N'New Year''s Day'), ('2026-04-03', N'Good Friday'), ('2026-04-06', N'Easter Monday'), ('2026-05-04', N'Early May bank holiday'),
    ('2026-05-25', N'Spring bank holiday'), ('2026-08-31', N'Summer bank holiday'), ('2026-12-25', N'Christmas Day'), ('2026-12-28', N'Boxing Day (substitute day)'),
    ('2027-01-01', N'New Year''s Day'), ('2027-03-26', N'Good Friday'), ('2027-03-29', N'Easter Monday'), ('2027-05-03', N'Early May bank holiday'),
    ('2027-05-31', N'Spring bank holiday'), ('2027-08-30', N'Summer bank holiday'), ('2027-12-27', N'Christmas Day (substitute day)'), ('2027-12-28', N'Boxing Day (substitute day)'),
    ('2028-01-03', N'New Year''s Day (substitute day)'), ('2028-04-14', N'Good Friday'), ('2028-04-17', N'Easter Monday'), ('2028-05-01', N'Early May bank holiday'),
    ('2028-05-29', N'Spring bank holiday'), ('2028-08-28', N'Summer bank holiday'), ('2028-12-25', N'Christmas Day'), ('2028-12-26', N'Boxing Day'),
    ('2029-01-01', N'New Year''s Day'), ('2029-03-30', N'Good Friday'), ('2029-04-02', N'Easter Monday'), ('2029-05-07', N'Early May bank holiday'),
    ('2029-05-28', N'Spring bank holiday'), ('2029-08-27', N'Summer bank holiday'), ('2029-12-25', N'Christmas Day'), ('2029-12-26', N'Boxing Day'),
    ('2030-01-01', N'New Year''s Day'), ('2030-04-19', N'Good Friday'), ('2030-04-22', N'Easter Monday'), ('2030-05-06', N'Early May bank holiday'),
    ('2030-05-27', N'Spring bank holiday'), ('2030-08-26', N'Summer bank holiday'), ('2030-12-25', N'Christmas Day'), ('2030-12-26', N'Boxing Day')
) AS s (HolidayDate, Name)
ON t.HolidayDate = s.HolidayDate
WHEN NOT MATCHED THEN INSERT (HolidayDate, Name) VALUES (s.HolidayDate, s.Name);

-- Microsoft lifecycle (verify at learn.microsoft.com/lifecycle)
MERGE dbo.ProductLifecycle AS t
USING (VALUES
    (N'SQL Server 2008 R2', '2008R2', '2014-07-08', '2019-07-09'), (N'SQL Server 2008', '2008', '2014-07-08', '2019-07-09'),
    (N'SQL Server 2012', '2012', '2017-07-11', '2022-07-12'), (N'SQL Server 2014', '2014', '2019-07-09', '2024-07-09'),
    (N'SQL Server 2016', '2016', '2021-07-13', '2026-07-14'), (N'SQL Server 2017', '2017', '2022-10-11', '2027-10-12'),
    (N'SQL Server 2019', '2019', '2025-02-28', '2030-01-08'), (N'SQL Server 2022', '2022', '2028-01-11', '2033-01-11'),
    (N'SQL Server 2025', '2025', NULL, NULL)
) AS s (ProductName, VersionKey, MainstreamEnd, ExtendedEnd)
ON t.ProductName = s.ProductName
WHEN NOT MATCHED THEN INSERT (ProductName, VersionKey, MainstreamEnd, ExtendedEnd) VALUES (s.ProductName, s.VersionKey, s.MainstreamEnd, s.ExtendedEnd);
GO

/*=============================================================================
  3. FUNCTIONS
=============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_Setting (@Name varchar(100))
RETURNS nvarchar(4000)
AS
BEGIN
    RETURN (SELECT Value FROM dbo.Setting WHERE Name = @Name);
END
GO

-- Current UK local time (handles GMT/BST), whatever the server's time zone
CREATE OR ALTER FUNCTION dbo.fn_UkNow ()
RETURNS datetime2(0)
AS
BEGIN
    RETURN CONVERT(datetime2(0), SYSUTCDATETIME() AT TIME ZONE 'UTC' AT TIME ZONE 'GMT Standard Time');
END
GO

CREATE OR ALTER FUNCTION dbo.fn_IsBusinessDay (@d date)
RETURNS bit
AS
BEGIN
    -- 1900-01-01 was a Monday, so % 7 gives 0 = Monday ... 5 = Saturday, 6 = Sunday (independent of DATEFIRST)
    IF DATEDIFF(day, '19000101', @d) % 7 >= 5 RETURN 0;
    IF EXISTS (SELECT 1 FROM dbo.BankHoliday WHERE HolidayDate = @d) RETURN 0;
    RETURN 1;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_NextBusinessDay (@d date)
RETURNS date
AS
BEGIN
    DECLARE @n date = DATEADD(day, 1, @d);
    WHILE dbo.fn_IsBusinessDay(@n) = 0 SET @n = DATEADD(day, 1, @n);
    RETURN @n;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_IsBusinessHours (@At datetime2(0))
RETURNS bit
AS
BEGIN
    DECLARE @t time(0) = CAST(@At AS time(0));
    IF dbo.fn_IsBusinessDay(CAST(@At AS date)) = 1
       AND @t >= CONVERT(time(0), dbo.fn_Setting('BusinessHoursStart'))
       AND @t <  CONVERT(time(0), dbo.fn_Setting('BusinessHoursEnd'))
        RETURN 1;
    RETURN 0;
END
GO

/* Target response time from the agreement:
   Critical = end of the same business day; Standard = end of the next full business day.
   A ticket raised outside business hours is treated as received at the start of the next business day. */
CREATE OR ALTER FUNCTION dbo.fn_ResponseDue (@RaisedAt datetime2(0), @Severity varchar(10))
RETURNS datetime2(0)
AS
BEGIN
    DECLARE @end time(0) = CONVERT(time(0), dbo.fn_Setting('BusinessHoursEnd'));
    DECLARE @d date = CAST(@RaisedAt AS date);
    IF dbo.fn_IsBusinessDay(@d) = 0 OR CAST(@RaisedAt AS time(0)) >= @end
        SET @d = dbo.fn_NextBusinessDay(@d);
    IF @Severity = 'Standard'
        SET @d = dbo.fn_NextBusinessDay(@d);
    RETURN DATEADD(second, DATEDIFF(second, CAST('00:00' AS time(0)), @end), CAST(@d AS datetime2(0)));
END
GO

CREATE OR ALTER FUNCTION dbo.fn_CycleStart (@AgreementStart date, @CycleNumber int)
RETURNS date
AS
BEGIN
    RETURN DATEADD(month, @CycleNumber - 1, @AgreementStart);
END
GO

CREATE OR ALTER FUNCTION dbo.fn_CycleNumberForDate (@AgreementStart date, @d date)
RETURNS int
AS
BEGIN
    IF @d < @AgreementStart RETURN 0;
    DECLARE @n int = DATEDIFF(month, @AgreementStart, @d) + 1;
    IF dbo.fn_CycleStart(@AgreementStart, @n) > @d SET @n = @n - 1;
    RETURN @n;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_AgreementId (@Client nvarchar(200))   -- agreement ref or client name
RETURNS int
AS
BEGIN
    RETURN COALESCE(
        (SELECT AgreementId FROM dbo.Agreement WHERE AgreementRef = @Client),
        (SELECT TOP (1) a.AgreementId FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
         WHERE c.ClientName = @Client ORDER BY a.StartDate DESC));
END
GO

CREATE OR ALTER FUNCTION dbo.fn_PriceListIdOn (@AgreementId int, @d date)
RETURNS int
AS
BEGIN
    RETURN COALESCE(
        (SELECT TOP (1) NewPriceListId FROM dbo.PriceChange WHERE AgreementId = @AgreementId AND EffectiveDate <= @d ORDER BY EffectiveDate DESC, PriceChangeId DESC),
        (SELECT PriceListId FROM dbo.Agreement WHERE AgreementId = @AgreementId));
END
GO

CREATE OR ALTER FUNCTION dbo.fn_InitialTermEnd (@AgreementId int)
RETURNS date
AS
BEGIN
    RETURN (SELECT DATEADD(day, -1, DATEADD(month, InitialTermMonths, StartDate)) FROM dbo.Agreement WHERE AgreementId = @AgreementId);
END
GO

/* Earliest end date for notice given on @NoticeDate: one full calendar month's notice, ending at the
   close of the billing cycle current at the end of that month, and never before the initial term ends. */
CREATE OR ALTER FUNCTION dbo.fn_EndDateForNotice (@AgreementId int, @NoticeDate date)
RETURNS date
AS
BEGIN
    DECLARE @start date = (SELECT StartDate FROM dbo.Agreement WHERE AgreementId = @AgreementId);
    DECLARE @noticeExpires date = EOMONTH(@NoticeDate, 1);
    DECLARE @cycle int = dbo.fn_CycleNumberForDate(@start, @noticeExpires);
    DECLARE @end date = DATEADD(day, -1, dbo.fn_CycleStart(@start, @cycle + 1));
    DECLARE @termEnd date = dbo.fn_InitialTermEnd(@AgreementId);
    RETURN CASE WHEN @end < @termEnd THEN @termEnd ELSE @end END;
END
GO

/* Monthly fee for everything covered on @AsOf:
   - SQL Server instances and Azure SQL Managed Instances rank together for the multi-server tiers:
     1st & 2nd at ServerFee, then ServerFeeTiered. An FCI is one instance whatever its node count.
   - AG / log shipping / mirroring secondaries (and Managed Instance failover-group secondaries) at SecondaryReplicaFee,
     unless priced as a full instance.
   - Azure SQL Database, per logical server or elastic pool: AzureSqlDbUnitFee for up to AzureSqlDbIncludedDatabases
     databases, plus AzureSqlDbExtraDatabaseFee for each one beyond. Failover-group secondaries / geo-replicas included.
     These are flat rates and do not count towards the tiers.
   - An AgreedMonthlyFee overrides everything and does not count towards the tiers. */
CREATE OR ALTER FUNCTION dbo.fn_AgreementFees (@AgreementId int, @AsOf date)
RETURNS TABLE
AS
RETURN
    WITH inst AS (
        SELECT i.InstanceId, i.InstanceName, i.Role, i.Environment, i.AgreedMonthlyFee, i.CoveredFrom, i.Platform, i.DatabaseCount,
               p.ServerFee, p.ServerFeeTiered, p.TierFromServerNumber, p.SecondaryReplicaFee,
               p.AzureSqlDbUnitFee, p.AzureSqlDbIncludedDatabases, p.AzureSqlDbExtraDatabaseFee,
               IsAzureDb   = CASE WHEN i.Platform IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool') THEN 1 ELSE 0 END,
               IsSecondary = CASE WHEN i.Role IN ('AGSecondary', 'LogShippingSecondary', 'MirrorSecondary', 'GeoReplica') AND i.PricedAsFullInstance = 0 THEN 1 ELSE 0 END
        FROM dbo.Instance i
        JOIN dbo.PriceList p ON p.PriceListId = dbo.fn_PriceListIdOn(@AgreementId, @AsOf)
        WHERE i.AgreementId = @AgreementId AND i.CoveredFrom <= @AsOf AND (i.CoveredTo IS NULL OR i.CoveredTo >= @AsOf)),
    ranked AS (
        SELECT *, TierRank = ROW_NUMBER() OVER (PARTITION BY CASE WHEN AgreedMonthlyFee IS NULL AND IsSecondary = 0 AND IsAzureDb = 0 THEN 1 ELSE 0 END
                                                ORDER BY CoveredFrom, InstanceId),
                  ExtraDatabases = CASE WHEN DatabaseCount > AzureSqlDbIncludedDatabases THEN DatabaseCount - AzureSqlDbIncludedDatabases ELSE 0 END
        FROM inst)
    SELECT InstanceId, InstanceName, Role, Environment, Platform, DatabaseCount,
           PricingBasis = CASE WHEN AgreedMonthlyFee IS NOT NULL THEN 'Agreed fee'
                               WHEN IsAzureDb = 1 AND IsSecondary = 1 THEN 'Azure SQL Database geo-replica, included'
                               WHEN IsAzureDb = 1 THEN 'Azure SQL Database ' + CASE WHEN Platform = 'AzureSqlDatabaseElasticPool' THEN 'elastic pool' ELSE 'logical server' END
                                                       + ', ' + CONVERT(varchar(10), ISNULL(DatabaseCount, 0)) + ' database' + CASE WHEN DatabaseCount = 1 THEN '' ELSE 's' END
                                                       + CASE WHEN ExtraDatabases > 0 THEN ' (' + CONVERT(varchar(10), ExtraDatabases) + ' beyond the ' + CONVERT(varchar(10), AzureSqlDbIncludedDatabases) + ' included)' ELSE '' END
                               WHEN IsSecondary = 1 THEN 'Secondary replica' + CASE WHEN Platform = 'AzureSqlManagedInstance' THEN ', Azure SQL Managed Instance' ELSE '' END
                               WHEN TierRank < TierFromServerNumber THEN 'Server ' + CONVERT(varchar(5), TierRank) + CASE WHEN Platform = 'AzureSqlManagedInstance' THEN ', Azure SQL Managed Instance' ELSE '' END
                               ELSE 'Server ' + CONVERT(varchar(5), TierRank) + ', multi-server rate' + CASE WHEN Platform = 'AzureSqlManagedInstance' THEN ', Azure SQL Managed Instance' ELSE '' END END,
           MonthlyFee = CAST(CASE WHEN AgreedMonthlyFee IS NOT NULL THEN AgreedMonthlyFee
                                  WHEN IsAzureDb = 1 AND IsSecondary = 1 THEN 0
                                  WHEN IsAzureDb = 1 THEN AzureSqlDbUnitFee + ExtraDatabases * AzureSqlDbExtraDatabaseFee
                                  WHEN IsSecondary = 1 THEN SecondaryReplicaFee
                                  WHEN TierRank < TierFromServerNumber THEN ServerFee
                                  ELSE ServerFeeTiered END AS decimal(9,2))
    FROM ranked;
GO

/*=============================================================================
  4. CLIENTS, AGREEMENTS AND INSTANCES
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_Client_Add
    @ClientName   nvarchar(200),
    @Address      nvarchar(500) = NULL,
    @BillingEmail nvarchar(320) = NULL,
    @Notes        nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.Client WHERE ClientName = @ClientName)
    BEGIN
        UPDATE dbo.Client SET Address = ISNULL(@Address, Address), BillingEmail = ISNULL(@BillingEmail, BillingEmail), Notes = ISNULL(@Notes, Notes)
        WHERE ClientName = @ClientName;
        PRINT N'Updated client ' + @ClientName;
    END
    ELSE
    BEGIN
        INSERT dbo.Client (ClientName, Address, BillingEmail, Notes) VALUES (@ClientName, @Address, @BillingEmail, @Notes);
        PRINT N'Added client ' + @ClientName;
    END
END
GO

CREATE OR ALTER FUNCTION dbo.fn_ClientId (@Client nvarchar(200))   -- client name or agreement ref
RETURNS int
AS
BEGIN
    RETURN COALESCE((SELECT ClientId FROM dbo.Client WHERE ClientName = @Client),
                    (SELECT ClientId FROM dbo.Agreement WHERE AgreementRef = @Client));
END
GO

CREATE OR ALTER FUNCTION dbo.fn_LooksLikeEmail (@Email nvarchar(320))
RETURNS bit
AS
BEGIN
    RETURN CASE WHEN @Email LIKE N'%_@_%._%' AND @Email NOT LIKE N'% %' AND @Email NOT LIKE N'%@%@%'
                     AND @Email NOT LIKE N'%..%' AND @Email NOT LIKE N'%.' AND @Email NOT LIKE N'%@.%' THEN 1 ELSE 0 END;
END
GO

-- Finds a contact by id, or by client (name or agreement ref) + full name.
CREATE OR ALTER PROCEDURE dbo.usp_Contact_Resolve
    @ContactId int = NULL OUTPUT,
    @Client    nvarchar(200) = NULL,
    @FullName  nvarchar(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF @ContactId IS NOT NULL
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM dbo.Contact WHERE ContactId = @ContactId)
        BEGIN RAISERROR(N'Contact %d not found.', 16, 1, @ContactId); RETURN 1; END
        RETURN 0;
    END
    DECLARE @ClientId int = dbo.fn_ClientId(@Client);
    IF @ClientId IS NULL BEGIN RAISERROR(N'Client or agreement "%s" not found.', 16, 1, @Client); RETURN 1; END
    IF (SELECT COUNT(*) FROM dbo.Contact WHERE ClientId = @ClientId AND FullName = @FullName) > 1
    BEGIN RAISERROR(N'More than one contact called "%s" - use @ContactId (see usp_Contact_Show).', 16, 1, @FullName); RETURN 1; END
    SET @ContactId = (SELECT ContactId FROM dbo.Contact WHERE ClientId = @ClientId AND FullName = @FullName);
    IF @ContactId IS NULL BEGIN RAISERROR(N'"%s" is not a contact for %s.', 16, 1, @FullName, @Client); RETURN 1; END
    RETURN 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Contact_Add
    @ClientName       nvarchar(200),            -- client name or agreement ref
    @FullName         nvarchar(200),
    @Email            nvarchar(320) = NULL,
    @Phone            nvarchar(50)  = NULL,
    @IsNamedContact   bit = NULL,               -- NULL = no (new contact) / unchanged (someone being re-added)
    @IsBillingContact bit = NULL,
    @StartDate        date = NULL               -- first day as a contact; default today
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @ClientId int = dbo.fn_ClientId(@ClientName);
    IF @ClientId IS NULL BEGIN RAISERROR(N'Client "%s" not found.', 16, 1, @ClientName); RETURN; END
    SET @FullName = LTRIM(RTRIM(@FullName));
    IF ISNULL(@FullName, N'') = N'' BEGIN RAISERROR(N'Give the contact''s name.', 16, 1); RETURN; END
    SET @Email = NULLIF(LTRIM(RTRIM(@Email)), N'');
    IF @Email IS NOT NULL AND dbo.fn_LooksLikeEmail(@Email) = 0 BEGIN RAISERROR(N'"%s" does not look like an e-mail address.', 16, 1, @Email); RETURN; END
    SET @StartDate = ISNULL(@StartDate, CAST(dbo.fn_UkNow() AS date));

    DECLARE @Existing int, @ExistingActive bit;
    SELECT TOP (1) @Existing = ContactId, @ExistingActive = IsActive FROM dbo.Contact
    WHERE ClientId = @ClientId AND FullName = @FullName ORDER BY IsActive DESC, ContactId DESC;
    IF @ExistingActive = 1
    BEGIN RAISERROR(N'%s is already a contact for this client. Use usp_Contact_Update to change their details.', 16, 1, @FullName); RETURN; END
    IF @Existing IS NOT NULL
    BEGIN
        -- removed earlier: bring the same person back with a new period, keeping their history
        EXEC dbo.usp_Contact_Reinstate @ContactId = @Existing, @StartDate = @StartDate, @Email = @Email, @Phone = @Phone,
             @IsNamedContact = @IsNamedContact, @IsBillingContact = @IsBillingContact;
        RETURN;
    END

    BEGIN TRAN;
    INSERT dbo.Contact (ClientId, FullName, Email, Phone, IsNamedContact, IsBillingContact)
    VALUES (@ClientId, @FullName, @Email, NULLIF(LTRIM(RTRIM(@Phone)), N''), ISNULL(@IsNamedContact, 0), ISNULL(@IsBillingContact, 0));
    DECLARE @ContactId int = SCOPE_IDENTITY();
    INSERT dbo.ContactPeriod (ContactId, StartDate) VALUES (@ContactId, @StartDate);
    COMMIT;
    IF @IsNamedContact = 1
        UPDATE dbo.OnboardingItem SET CompletedDate = ISNULL(CompletedDate, CAST(dbo.fn_UkNow() AS date))
        WHERE ItemCode = 'NAMED_CONTACT' AND AgreementId IN (SELECT AgreementId FROM dbo.Agreement WHERE ClientId = @ClientId);
    PRINT N'Added contact ' + @FullName + N' from ' + CONVERT(nvarchar(11), @StartDate, 106) + N'.';
END
GO

-- Change a contact's details. NULL = leave as is; '' clears the e-mail or phone.
CREATE OR ALTER PROCEDURE dbo.usp_Contact_Update
    @ContactId        int           = NULL,
    @Client           nvarchar(200) = NULL,     -- with @FullName, instead of @ContactId
    @FullName         nvarchar(200) = NULL,
    @NewFullName      nvarchar(200) = NULL,
    @Email            nvarchar(320) = NULL,
    @Phone            nvarchar(50)  = NULL,
    @IsNamedContact   bit           = NULL,
    @IsBillingContact bit           = NULL
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @rc int;
    EXEC @rc = dbo.usp_Contact_Resolve @ContactId = @ContactId OUTPUT, @Client = @Client, @FullName = @FullName;
    IF @rc <> 0 OR @ContactId IS NULL RETURN;

    DECLARE @ClientId int, @OldName nvarchar(200), @IsActive bit;
    SELECT @ClientId = ClientId, @OldName = FullName, @IsActive = IsActive FROM dbo.Contact WHERE ContactId = @ContactId;
    SET @NewFullName = NULLIF(LTRIM(RTRIM(@NewFullName)), N'');
    IF @NewFullName IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.Contact WHERE ClientId = @ClientId AND FullName = @NewFullName AND ContactId <> @ContactId)
    BEGIN RAISERROR(N'This client already has a contact called %s.', 16, 1, @NewFullName); RETURN; END
    IF NULLIF(LTRIM(RTRIM(@Email)), N'') IS NOT NULL AND dbo.fn_LooksLikeEmail(LTRIM(RTRIM(@Email))) = 0
    BEGIN DECLARE @e nvarchar(320) = LTRIM(RTRIM(@Email)); RAISERROR(N'"%s" does not look like an e-mail address.', 16, 1, @e); RETURN; END

    UPDATE dbo.Contact
    SET FullName         = ISNULL(@NewFullName, FullName),
        Email            = CASE WHEN @Email IS NULL THEN Email ELSE NULLIF(LTRIM(RTRIM(@Email)), N'') END,
        Phone            = CASE WHEN @Phone IS NULL THEN Phone ELSE NULLIF(LTRIM(RTRIM(@Phone)), N'') END,
        IsNamedContact   = ISNULL(@IsNamedContact, IsNamedContact),
        IsBillingContact = ISNULL(@IsBillingContact, IsBillingContact)
    WHERE ContactId = @ContactId;

    IF @IsNamedContact = 1 AND @IsActive = 1
        UPDATE dbo.OnboardingItem SET CompletedDate = ISNULL(CompletedDate, CAST(dbo.fn_UkNow() AS date))
        WHERE ItemCode = 'NAMED_CONTACT' AND AgreementId IN (SELECT AgreementId FROM dbo.Agreement WHERE ClientId = @ClientId);
    PRINT N'Updated ' + ISNULL(@NewFullName, @OldName) + CASE WHEN @IsActive = 0 THEN N' (no longer a current contact; their details were still corrected).' ELSE N'.' END;
    SELECT ContactId, FullName, Email, Phone, IsNamedContact, IsBillingContact, IsActive FROM dbo.Contact WHERE ContactId = @ContactId;
END
GO

-- Soft delete: ends the contact's current period. Their record, history and tickets are kept.
CREATE OR ALTER PROCEDURE dbo.usp_Contact_Remove
    @ContactId int           = NULL,
    @Client    nvarchar(200) = NULL,            -- with @FullName, instead of @ContactId
    @FullName  nvarchar(200) = NULL,
    @EndDate   date          = NULL,            -- their last day as a contact; default today
    @Reason    nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @rc int;
    EXEC @rc = dbo.usp_Contact_Resolve @ContactId = @ContactId OUTPUT, @Client = @Client, @FullName = @FullName;
    IF @rc <> 0 OR @ContactId IS NULL RETURN;

    DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
    SET @EndDate = ISNULL(@EndDate, @Today);
    DECLARE @Name nvarchar(200), @ClientId int, @Named bit, @Billing bit;
    SELECT @Name = FullName, @ClientId = ClientId, @Named = IsNamedContact, @Billing = IsBillingContact FROM dbo.Contact WHERE ContactId = @ContactId;
    DECLARE @PeriodId int, @From date;
    SELECT @PeriodId = ContactPeriodId, @From = StartDate FROM dbo.ContactPeriod WHERE ContactId = @ContactId AND EndDate IS NULL;
    IF @PeriodId IS NULL
    BEGIN
        DECLARE @Last nvarchar(11) = (SELECT CONVERT(nvarchar(11), MAX(EndDate), 106) FROM dbo.ContactPeriod WHERE ContactId = @ContactId);
        RAISERROR(N'%s is not a current contact (removed %s).', 16, 1, @Name, @Last); RETURN;
    END
    IF @EndDate > @Today BEGIN RAISERROR(N'The end date is in the future. Record the removal on or after their last day.', 16, 1); RETURN; END
    IF @EndDate < @From
    BEGIN DECLARE @f nvarchar(11) = CONVERT(nvarchar(11), @From, 106); RAISERROR(N'%s only became a contact on %s; the end date cannot be before that.', 16, 1, @Name, @f); RETURN; END

    BEGIN TRAN;
    UPDATE dbo.ContactPeriod SET EndDate = @EndDate, EndReason = NULLIF(LTRIM(RTRIM(@Reason)), N'') WHERE ContactPeriodId = @PeriodId;
    UPDATE dbo.Contact SET IsActive = 0 WHERE ContactId = @ContactId;
    COMMIT;

    PRINT N'Removed ' + @Name + N' as a contact (last day ' + CONVERT(nvarchar(11), @EndDate, 106) + N'). Their history and tickets are kept; add them again with usp_Contact_Add or usp_Contact_Reinstate.';
    IF @Named = 1 AND NOT EXISTS (SELECT 1 FROM dbo.Contact WHERE ClientId = @ClientId AND IsActive = 1 AND IsNamedContact = 1)
        PRINT N'WARNING: ' + @Name + N' was the client''s only named point of contact. The agreement needs one: add another, or mark an existing contact as named.';
    IF @Billing = 1 AND NOT EXISTS (SELECT 1 FROM dbo.Contact WHERE ClientId = @ClientId AND IsActive = 1 AND IsBillingContact = 1)
        PRINT N'Note: ' + @Name + N' was the billing contact. Invoices now go to the client''s billing e-mail only.';
END
GO

-- Brings a removed contact back, with a new period. Details can be changed at the same time (NULL = unchanged).
CREATE OR ALTER PROCEDURE dbo.usp_Contact_Reinstate
    @ContactId        int           = NULL,
    @Client           nvarchar(200) = NULL,     -- with @FullName, instead of @ContactId
    @FullName         nvarchar(200) = NULL,
    @StartDate        date          = NULL,     -- first day back; default today
    @Email            nvarchar(320) = NULL,
    @Phone            nvarchar(50)  = NULL,
    @IsNamedContact   bit           = NULL,
    @IsBillingContact bit           = NULL
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @rc int;
    EXEC @rc = dbo.usp_Contact_Resolve @ContactId = @ContactId OUTPUT, @Client = @Client, @FullName = @FullName;
    IF @rc <> 0 OR @ContactId IS NULL RETURN;

    SET @StartDate = ISNULL(@StartDate, CAST(dbo.fn_UkNow() AS date));
    DECLARE @Name nvarchar(200) = (SELECT FullName FROM dbo.Contact WHERE ContactId = @ContactId);
    IF EXISTS (SELECT 1 FROM dbo.ContactPeriod WHERE ContactId = @ContactId AND EndDate IS NULL)
    BEGIN RAISERROR(N'%s is already a current contact.', 16, 1, @Name); RETURN; END
    DECLARE @LastEnd date = (SELECT MAX(EndDate) FROM dbo.ContactPeriod WHERE ContactId = @ContactId);
    IF @StartDate <= @LastEnd
    BEGIN DECLARE @l nvarchar(11) = CONVERT(nvarchar(11), @LastEnd, 106); RAISERROR(N'%s was a contact until %s; the new start date must be after that.', 16, 1, @Name, @l); RETURN; END

    BEGIN TRAN;
    INSERT dbo.ContactPeriod (ContactId, StartDate) VALUES (@ContactId, @StartDate);
    UPDATE dbo.Contact SET IsActive = 1 WHERE ContactId = @ContactId;
    COMMIT;
    IF @Email IS NOT NULL OR @Phone IS NOT NULL OR @IsNamedContact IS NOT NULL OR @IsBillingContact IS NOT NULL
        EXEC dbo.usp_Contact_Update @ContactId = @ContactId, @Email = @Email, @Phone = @Phone,
             @IsNamedContact = @IsNamedContact, @IsBillingContact = @IsBillingContact;
    IF (SELECT IsNamedContact FROM dbo.Contact WHERE ContactId = @ContactId) = 1
        UPDATE dbo.OnboardingItem SET CompletedDate = ISNULL(CompletedDate, CAST(dbo.fn_UkNow() AS date))
        WHERE ItemCode = 'NAMED_CONTACT' AND AgreementId IN (SELECT AgreementId FROM dbo.Agreement WHERE ClientId = (SELECT ClientId FROM dbo.Contact WHERE ContactId = @ContactId));
    PRINT @Name + N' is a contact again from ' + CONVERT(nvarchar(11), @StartDate, 106) + N' (previously until ' + CONVERT(nvarchar(11), @LastEnd, 106) + N').';
END
GO

-- A client's contacts with their periods. @IncludeRemoved = 0 shows current contacts only.
CREATE OR ALTER PROCEDURE dbo.usp_Contact_Show
    @Client         nvarchar(200),
    @IncludeRemoved bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = dbo.fn_ClientId(@Client);
    IF @ClientId IS NULL BEGIN RAISERROR(N'Client or agreement "%s" not found.', 16, 1, @Client); RETURN; END
    SELECT ct.ContactId, ct.FullName, ct.Email, ct.Phone,
           Named = CASE WHEN ct.IsNamedContact = 1 THEN 'Yes' ELSE '' END,
           Billing = CASE WHEN ct.IsBillingContact = 1 THEN 'Yes' ELSE '' END,
           Status = CASE WHEN ct.IsActive = 1 THEN 'Current' ELSE 'Removed' END,
           Periods = STRING_AGG(CONVERT(nvarchar(11), p.StartDate, 106) + N' - ' + ISNULL(CONVERT(nvarchar(11), p.EndDate, 106), N'now'), N'; ')
                     WITHIN GROUP (ORDER BY p.StartDate)
    FROM dbo.Contact ct LEFT JOIN dbo.ContactPeriod p ON p.ContactId = ct.ContactId
    WHERE ct.ClientId = @ClientId AND (@IncludeRemoved = 1 OR ct.IsActive = 1)
    GROUP BY ct.ContactId, ct.FullName, ct.Email, ct.Phone, ct.IsNamedContact, ct.IsBillingContact, ct.IsActive
    ORDER BY ct.IsActive DESC, ct.IsNamedContact DESC, ct.FullName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Agreement_Create
    @ClientName    nvarchar(200),
    @StartDate     date,
    @SignedDate    date          = NULL,
    @TicketChannel nvarchar(300) = N'E-mail to jay@jayparry.co.uk',
    @AgreementRef  varchar(30)   = NULL,     -- default MWA-0001 style
    @PriceListName nvarchar(100) = NULL      -- default: latest standard price list effective at the start date
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = (SELECT ClientId FROM dbo.Client WHERE ClientName = @ClientName);
    IF @ClientId IS NULL BEGIN RAISERROR(N'Client "%s" not found. Run usp_Client_Add first.', 16, 1, @ClientName); RETURN; END

    DECLARE @PriceListId int = CASE WHEN @PriceListName IS NOT NULL THEN (SELECT PriceListId FROM dbo.PriceList WHERE Name = @PriceListName)
                                    ELSE (SELECT TOP (1) PriceListId FROM dbo.PriceList WHERE IsStandard = 1 AND EffectiveFrom <= @StartDate ORDER BY EffectiveFrom DESC) END;
    IF @PriceListId IS NULL SET @PriceListId = (SELECT TOP (1) PriceListId FROM dbo.PriceList WHERE IsStandard = 1 ORDER BY EffectiveFrom);
    IF @PriceListId IS NULL BEGIN RAISERROR(N'No price list found.', 16, 1); RETURN; END

    BEGIN TRAN;
    INSERT dbo.Agreement (AgreementRef, ClientId, SignedDate, StartDate, InitialTermMonths, PriceListId, TicketChannel)
    SELECT ISNULL(@AgreementRef, 'TMP-' + LEFT(CONVERT(varchar(36), NEWID()), 20)), @ClientId, @SignedDate, @StartDate, InitialTermMonths, @PriceListId, @TicketChannel
    FROM dbo.PriceList WHERE PriceListId = @PriceListId;
    DECLARE @AgreementId int = SCOPE_IDENTITY();
    IF @AgreementRef IS NULL
        UPDATE dbo.Agreement SET AgreementRef = 'MWA-' + RIGHT('0000' + CONVERT(varchar(10), @AgreementId), 4) WHERE AgreementId = @AgreementId;

    INSERT dbo.OnboardingItem (AgreementId, ItemCode, SortOrder, Description, IsRequired, CompletedDate)
    VALUES (@AgreementId, 'SIGNED',          1, N'Agreement signed and start date confirmed', 1, @SignedDate),
           (@AgreementId, 'NAMED_CONTACT',   2, N'Named point of contact for support ticket queries', 1,
                CASE WHEN EXISTS (SELECT 1 FROM dbo.Contact WHERE ClientId = @ClientId AND IsNamedContact = 1 AND IsActive = 1) THEN CAST(dbo.fn_UkNow() AS date) END),
           (@AgreementId, 'TICKET_CHANNEL',  3, N'Agreed channel for raising support tickets', 1, NULL),
           (@AgreementId, 'REMOTE_ACCESS',   4, N'Remote access to each covered SQL Server (VPN, Azure Bastion or agreed equivalent)', 1, NULL),
           (@AgreementId, 'SSMS_ACCESS',     5, N'SSMS or equivalent tooling with access to each instance (jump box preferred)', 1, NULL),
           (@AgreementId, 'PERMISSIONS',     6, N'Account with permissions to review server health, jobs and performance data', 1, NULL),
           (@AgreementId, 'MONITORING',      7, N'Molehill Watch installed on every covered instance (and every AG replica)', 1, NULL),
           (@AgreementId, 'VERSION_REVIEW',  8, N'SQL Server / OS versions recorded; unsupported-version risk acceptance obtained where needed', 1, NULL),
           (@AgreementId, 'FIRST_REPORT',    9, N'First weekly status report delivered', 1, NULL),
           (@AgreementId, 'CONFIDENTIALITY',10, N'Confidentiality agreement / Data Processing Agreement (only if requested)', 0, NULL);
    COMMIT;

    SELECT a.AgreementRef, c.ClientName, a.StartDate, InitialTermEnds = dbo.fn_InitialTermEnd(a.AgreementId), PriceList = p.Name, a.TicketChannel
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId JOIN dbo.PriceList p ON p.PriceListId = a.PriceListId
    WHERE a.AgreementId = @AgreementId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Instance_Add
    @Client               nvarchar(200),            -- agreement ref or client name
    @InstanceName         nvarchar(128),
    @Role                 varchar(30)   = 'Standalone', -- Standalone | AGPrimary | AGSecondary | LogShippingSecondary | MirrorSecondary | FCI | GeoReplica
    @Platform             varchar(40)   = 'SqlServer',  -- SqlServer | AzureSqlManagedInstance | AzureSqlDatabaseServer | AzureSqlDatabaseElasticPool
    @DatabaseCount        int           = NULL,         -- Azure SQL Database logical server / elastic pool: databases in it
    @Environment          varchar(20)   = 'Production',
    @SqlVersion           varchar(20)   = NULL,     -- e.g. '2019'
    @Edition              nvarchar(100) = NULL,
    @OsVersion            nvarchar(100) = NULL,
    @AvailabilityGroup    nvarchar(128) = NULL,
    @PrimaryInstanceName  nvarchar(128) = NULL,
    @FciNodes             nvarchar(400) = NULL,
    @PricedAsFullInstance bit           = 0,
    @AgreedMonthlyFee     decimal(9,2)  = NULL,
    @CoveredFrom          date          = NULL      -- default: agreement start until its first invoice (onboarding), then today
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    IF @AgreementId IS NULL BEGIN RAISERROR(N'Agreement or client "%s" not found.', 16, 1, @Client); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.Instance WHERE AgreementId = @AgreementId AND InstanceName = @InstanceName AND CoveredTo IS NULL)
    BEGIN RAISERROR(N'Instance "%s" is already covered on this agreement.', 16, 1, @InstanceName); RETURN; END

    IF @Platform NOT IN ('SqlServer', 'AzureSqlManagedInstance', 'AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool')
    BEGIN RAISERROR(N'@Platform must be SqlServer, AzureSqlManagedInstance, AzureSqlDatabaseServer or AzureSqlDatabaseElasticPool.', 16, 1); RETURN; END
    IF @Role = 'GeoReplica' AND @Platform = 'SqlServer'
    BEGIN RAISERROR(N'GeoReplica is for Azure SQL failover-group secondaries and geo-replicas. Use AGSecondary, LogShippingSecondary or MirrorSecondary for SQL Server.', 16, 1); RETURN; END
    IF @Platform IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool') AND @Role <> 'GeoReplica' AND ISNULL(@DatabaseCount, 0) < 1
    BEGIN RAISERROR(N'Azure SQL Database is billed per logical server or elastic pool: give @DatabaseCount (the number of databases in it).', 16, 1); RETURN; END
    IF @Platform IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool') AND @Role NOT IN ('Standalone', 'GeoReplica')
    BEGIN RAISERROR(N'For Azure SQL Database use @Role = Standalone (the server or pool) or GeoReplica (a failover-group secondary).', 16, 1); RETURN; END
    IF @Environment = 'NonProduction' AND @AgreedMonthlyFee IS NULL
    BEGIN RAISERROR(N'Non-production instances are included at an agreed fee: give @AgreedMonthlyFee.', 16, 1); RETURN; END

    DECLARE @Start date = (SELECT StartDate FROM dbo.Agreement WHERE AgreementId = @AgreementId);
    DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
    -- servers named while onboarding (before the first fee invoice) are covered from the start date;
    -- later additions from today, so they are charged from the next cycle start (no pro-rata)
    SET @CoveredFrom = ISNULL(@CoveredFrom,
        CASE WHEN @Start > @Today THEN @Start
             WHEN NOT EXISTS (SELECT 1 FROM dbo.BillingCycle WHERE AgreementId = @AgreementId AND FeeInvoiceId IS NOT NULL) THEN @Start
             ELSE @Today END);

    DECLARE @PrimaryId int = (SELECT TOP (1) InstanceId FROM dbo.Instance WHERE AgreementId = @AgreementId AND InstanceName = @PrimaryInstanceName AND CoveredTo IS NULL);
    IF @PrimaryInstanceName IS NOT NULL AND @PrimaryId IS NULL
        PRINT N'Note: primary instance "' + @PrimaryInstanceName + N'" not found on this agreement; add it first to link the secondary.';

    INSERT dbo.Instance (AgreementId, InstanceName, Environment, Role, Platform, DatabaseCount, PricedAsFullInstance, AgreedMonthlyFee, AvailabilityGroup, PrimaryInstanceId,
                         FciNodes, SqlVersion, Edition, OsVersion, CoveredFrom)
    VALUES (@AgreementId, @InstanceName, @Environment, @Role, @Platform, @DatabaseCount, @PricedAsFullInstance, @AgreedMonthlyFee, @AvailabilityGroup, @PrimaryId,
            @FciNodes, @SqlVersion, @Edition, @OsVersion, @CoveredFrom);
    IF @Platform = 'AzureSqlManagedInstance'
        PRINT N'Azure SQL Managed Instance: priced as a standard production instance and counts towards the multi-server tiers.';
    IF @Platform IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool') AND @Role = 'GeoReplica'
        PRINT N'Azure SQL Database geo-replica / failover-group secondary: included at no charge.';
    ELSE IF @Platform IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool')
        PRINT N'Azure SQL Database: flat rate per logical server or elastic pool; does not count towards the multi-server tiers. Update @DatabaseCount with usp_Instance_Update when databases are added or removed.';

    DECLARE @Ext date = (SELECT ExtendedEnd FROM dbo.ProductLifecycle WHERE VersionKey = @SqlVersion);
    IF @Ext < @Today
        PRINT N'WARNING: SQL Server ' + @SqlVersion + N' is out of Microsoft support (since ' + CONVERT(nvarchar(11), @Ext, 106)
            + N'). Record the client''s risk acceptance with usp_Instance_RecordRiskAcceptance and recommend an upgrade.';
    IF @Role IN ('AGSecondary', 'LogShippingSecondary', 'MirrorSecondary') AND @PricedAsFullInstance = 0
        PRINT N'Priced as a secondary replica. If it carries a significant reporting/application workload, re-add with @PricedAsFullInstance = 1.';
    IF @Environment = 'NonProduction'
        PRINT N'Non-production instance included at the agreed fee.';

    PRINT N'Fee schedule from ' + CONVERT(nvarchar(11), @CoveredFrom, 106) + N' (applies from the next billing cycle start - no pro-rata):';
    SELECT InstanceName, Platform, Role, Environment, PricingBasis, MonthlyFee FROM dbo.fn_AgreementFees(@AgreementId, @CoveredFrom) ORDER BY MonthlyFee DESC, InstanceName;
    SELECT TotalMonthlyFee = SUM(MonthlyFee) FROM dbo.fn_AgreementFees(@AgreementId, @CoveredFrom);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Instance_Remove
    @Client       nvarchar(200),
    @InstanceName nvarchar(128),
    @CoveredTo    date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    UPDATE dbo.Instance SET CoveredTo = ISNULL(@CoveredTo, CAST(dbo.fn_UkNow() AS date))
    WHERE AgreementId = @AgreementId AND InstanceName = @InstanceName AND CoveredTo IS NULL;
    IF @@ROWCOUNT = 0 RAISERROR(N'Covered instance "%s" not found.', 16, 1, @InstanceName);
    ELSE PRINT N'Coverage ended for ' + @InstanceName + N'. Remember: the monthly fee for a cycle is set by what is covered at the cycle start.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Instance_Update
    @Client                  nvarchar(200),
    @InstanceName            nvarchar(128),
    @SqlVersion              varchar(20)   = NULL,
    @Edition                 nvarchar(100) = NULL,
    @OsVersion               nvarchar(100) = NULL,
    @MonitoringInstalledDate date          = NULL,
    @Notes                   nvarchar(max) = NULL,
    @DatabaseCount           int           = NULL     -- Azure SQL Database: databases now in the server / pool
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    UPDATE dbo.Instance
    SET SqlVersion = ISNULL(@SqlVersion, SqlVersion), Edition = ISNULL(@Edition, Edition), OsVersion = ISNULL(@OsVersion, OsVersion),
        MonitoringInstalledDate = ISNULL(@MonitoringInstalledDate, MonitoringInstalledDate), Notes = ISNULL(@Notes, Notes),
        DatabaseCount = ISNULL(@DatabaseCount, DatabaseCount)
    WHERE AgreementId = @AgreementId AND InstanceName = @InstanceName AND CoveredTo IS NULL;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR(N'Covered instance "%s" not found.', 16, 1, @InstanceName); RETURN; END

    -- tick the onboarding item once every covered instance has monitoring installed
    UPDATE o SET CompletedDate = CAST(dbo.fn_UkNow() AS date)
    FROM dbo.OnboardingItem o
    WHERE o.AgreementId = @AgreementId AND o.ItemCode = 'MONITORING' AND o.CompletedDate IS NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.Instance i WHERE i.AgreementId = @AgreementId AND i.CoveredTo IS NULL AND i.MonitoringInstalledDate IS NULL);
    PRINT N'Updated ' + @InstanceName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Instance_RecordRiskAcceptance
    @Client       nvarchar(200),
    @InstanceName nvarchar(128),
    @AcceptedBy   nvarchar(200),
    @AcceptedDate date = NULL,
    @HasExtendedSecurityUpdates bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    UPDATE dbo.Instance
    SET UnsupportedRiskAcceptedBy = @AcceptedBy, UnsupportedRiskAcceptedDate = ISNULL(@AcceptedDate, CAST(dbo.fn_UkNow() AS date)),
        HasExtendedSecurityUpdates = @HasExtendedSecurityUpdates
    WHERE AgreementId = @AgreementId AND InstanceName = @InstanceName AND CoveredTo IS NULL;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR(N'Covered instance "%s" not found.', 16, 1, @InstanceName); RETURN; END
    PRINT N'Risk acceptance recorded. Also run this on the client server, in its Molehill Watch database, so it shows in weekly reports:';
    PRINT N'  EXEC mw.usp_Configure @UnsupportedRiskAccepted = N''' + REPLACE(@AcceptedBy, N'''', N'''''') + N', '
          + CONVERT(nvarchar(11), ISNULL(@AcceptedDate, CAST(dbo.fn_UkNow() AS date)), 106) + N''';';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Onboarding_Complete
    @Client        nvarchar(200),
    @ItemCode      varchar(30),        -- see usp_Onboarding_Show
    @CompletedDate date = NULL,
    @Notes         nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    UPDATE dbo.OnboardingItem SET CompletedDate = ISNULL(@CompletedDate, CAST(dbo.fn_UkNow() AS date)), Notes = ISNULL(@Notes, Notes)
    WHERE AgreementId = @AgreementId AND ItemCode = @ItemCode;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR(N'Onboarding item "%s" not found for that agreement.', 16, 1, @ItemCode); RETURN; END
    IF @ItemCode = 'CONFIDENTIALITY' UPDATE dbo.Agreement SET ConfidentialityAgreement = 1, DataProcessingAgreement = 1 WHERE AgreementId = @AgreementId;
    EXEC dbo.usp_Onboarding_Show @Client = @Client;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Onboarding_Show
    @Client nvarchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    SELECT ItemCode, Description, Required = CASE WHEN IsRequired = 1 THEN 'Yes' ELSE 'Optional' END,
           Status = CASE WHEN CompletedDate IS NOT NULL THEN 'Done' ELSE 'Outstanding' END, CompletedDate, Notes
    FROM dbo.OnboardingItem WHERE AgreementId = @AgreementId ORDER BY SortOrder;

    SELECT InstanceName, Role, SqlVersion, MonitoringInstalled = MonitoringInstalledDate,
           SupportStatus = CASE WHEN l.ExtendedEnd < CAST(dbo.fn_UkNow() AS date) THEN 'UNSUPPORTED' WHEN l.ExtendedEnd IS NULL THEN '?' ELSE 'Supported' END,
           RiskAccepted = CASE WHEN i.UnsupportedRiskAcceptedDate IS NOT NULL THEN i.UnsupportedRiskAcceptedBy + ' ' + CONVERT(varchar(11), i.UnsupportedRiskAcceptedDate, 106) END
    FROM dbo.Instance i LEFT JOIN dbo.ProductLifecycle l ON l.VersionKey = i.SqlVersion
    WHERE i.AgreementId = @AgreementId AND i.CoveredTo IS NULL
    ORDER BY i.InstanceName;
END
GO

/*=============================================================================
  5. TERM, NOTICE AND PRICE CHANGES
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_Agreement_RecordReview
    @Client     nvarchar(200),
    @ReviewDate date = NULL,
    @Notes      nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Agreement SET InitialReviewDoneDate = ISNULL(@ReviewDate, CAST(dbo.fn_UkNow() AS date)), InitialReviewNotes = @Notes
    WHERE AgreementId = dbo.fn_AgreementId(@Client);
    PRINT N'Initial term review recorded.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Notice_Give
    @Client     nvarchar(200),
    @NoticeDate date = NULL,
    @GivenBy    varchar(20) = 'Client',   -- Client | Molehill
    @WhatIf     bit = 0                   -- 1 = just show the end date
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    IF @AgreementId IS NULL BEGIN RAISERROR(N'Agreement or client "%s" not found.', 16, 1, @Client); RETURN; END
    SET @NoticeDate = ISNULL(@NoticeDate, CAST(dbo.fn_UkNow() AS date));
    DECLARE @EndDate date = dbo.fn_EndDateForNotice(@AgreementId, @NoticeDate);

    IF @WhatIf = 0
        UPDATE dbo.Agreement SET NoticeGivenDate = @NoticeDate, NoticeGivenBy = @GivenBy, EndDate = @EndDate WHERE AgreementId = @AgreementId;

    SELECT a.AgreementRef, c.ClientName, NoticeGiven = @NoticeDate, GivenBy = @GivenBy,
           InitialTermEnds = dbo.fn_InitialTermEnd(a.AgreementId), AgreementEnds = @EndDate,
           Explanation = N'One full calendar month''s notice runs to ' + CONVERT(nvarchar(11), EOMONTH(@NoticeDate, 1), 106)
                       + N'; the agreement ends at the close of the billing cycle current at that point'
                       + CASE WHEN @EndDate = dbo.fn_InitialTermEnd(a.AgreementId) THEN N' (held to the end of the initial term).' ELSE N'.' END,
           Recorded = CASE WHEN @WhatIf = 1 THEN 'No (WhatIf)' ELSE 'Yes' END
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE a.AgreementId = @AgreementId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_PriceChange_Schedule
    @NewPriceListName nvarchar(100),
    @NotifiedDate     date,
    @EffectiveDate    date,
    @Client           nvarchar(200) = NULL   -- NULL = every active agreement
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @PriceListId int = (SELECT PriceListId FROM dbo.PriceList WHERE Name = @NewPriceListName);
    IF @PriceListId IS NULL BEGIN RAISERROR(N'Price list "%s" not found. Insert it into dbo.PriceList first.', 16, 1, @NewPriceListName); RETURN; END

    DECLARE @MinEffective date = DATEADD(day, 1, EOMONTH(@NotifiedDate, 1));
    IF @EffectiveDate < @MinEffective
    BEGIN
        DECLARE @m nvarchar(30) = CONVERT(nvarchar(11), @MinEffective, 106);
        RAISERROR(N'At least one full calendar month''s notice is required: the earliest effective date for notice on that date is %s.', 16, 1, @m);
        RETURN;
    END

    SELECT a.AgreementId, a.AgreementRef, c.ClientName,
           LastChange = COALESCE((SELECT MAX(EffectiveDate) FROM dbo.PriceChange pc WHERE pc.AgreementId = a.AgreementId), a.StartDate)
    INTO #targets
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE (a.EndDate IS NULL OR a.EndDate >= @EffectiveDate)
      AND (@Client IS NULL OR a.AgreementId = dbo.fn_AgreementId(@Client));

    IF EXISTS (SELECT 1 FROM #targets WHERE DATEADD(year, 1, LastChange) > @EffectiveDate)
    BEGIN
        SELECT AgreementRef, ClientName, LastPriceChangeOrStart = LastChange, EarliestNextChange = DATEADD(year, 1, LastChange)
        FROM #targets WHERE DATEADD(year, 1, LastChange) > @EffectiveDate;
        RAISERROR(N'Prices can be reviewed no more than once per year. The agreements listed are not eligible on that date; nothing was changed.', 16, 1);
        RETURN;
    END

    INSERT dbo.PriceChange (AgreementId, NewPriceListId, NotifiedDate, EffectiveDate)
    SELECT AgreementId, @PriceListId, @NotifiedDate, @EffectiveDate FROM #targets;
    SELECT AgreementRef, ClientName, NewPriceList = @NewPriceListName, NotifiedDate = @NotifiedDate, EffectiveDate = @EffectiveDate,
           Note = N'Applies to billing cycles starting on or after the effective date.' FROM #targets;
END
GO

/*=============================================================================
  6. TICKETS AND TIME
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_Ticket_Open
    @Client       nvarchar(200),            -- agreement ref or client name
    @Title        nvarchar(200),
    @Severity     varchar(10)   = 'Standard',
    @InstanceName nvarchar(128) = NULL,
    @ContactName  nvarchar(200) = NULL,
    @Description  nvarchar(max) = NULL,
    @RaisedAt     datetime2(0)  = NULL,     -- UK time; default now
    @Channel      nvarchar(50)  = N'E-mail',
    @WorkType     varchar(20)   = 'Support' -- Support | PlannedOutOfHours | Project
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    IF @AgreementId IS NULL BEGIN RAISERROR(N'Agreement or client "%s" not found.', 16, 1, @Client); RETURN; END
    SET @RaisedAt = ISNULL(@RaisedAt, dbo.fn_UkNow());

    DECLARE @InstanceId int = NULL;
    IF @InstanceName IS NOT NULL
    BEGIN
        SET @InstanceId = (SELECT TOP (1) InstanceId FROM dbo.Instance WHERE AgreementId = @AgreementId AND InstanceName = @InstanceName
                           AND CoveredFrom <= CAST(@RaisedAt AS date) AND (CoveredTo IS NULL OR CoveredTo >= CAST(@RaisedAt AS date)));
        IF @InstanceId IS NULL
            PRINT N'WARNING: ' + @InstanceName + N' is not a covered instance on this agreement. Support for non-covered servers is quoted separately.';
    END
    DECLARE @ClientId int = (SELECT ClientId FROM dbo.Agreement WHERE AgreementId = @AgreementId);
    DECLARE @ContactId int = (SELECT TOP (1) ContactId FROM dbo.Contact
                              WHERE ClientId = @ClientId AND (FullName = @ContactName OR (@ContactName IS NULL AND IsNamedContact = 1 AND IsActive = 1))
                              ORDER BY IsActive DESC, IsNamedContact DESC);
    IF @ContactName IS NOT NULL AND @ContactId IS NULL
        PRINT N'Note: ' + @ContactName + N' is not a contact for this client, so the ticket is logged without one.';
    ELSE IF (SELECT IsActive FROM dbo.Contact WHERE ContactId = @ContactId) = 0
    BEGIN
        DECLARE @RemovedOn nvarchar(11) = (SELECT CONVERT(nvarchar(11), MAX(EndDate), 106) FROM dbo.ContactPeriod WHERE ContactId = @ContactId);
        PRINT N'WARNING: ' + @ContactName + N' is no longer a contact for this client (removed ' + ISNULL(@RemovedOn, N'?')
            + N'). Check the request is authorised by a current named contact.';
    END

    DECLARE @a_End date, @a_Paused date, @a_Start date;
    SELECT @a_End = EndDate, @a_Paused = SupportPausedFrom, @a_Start = StartDate FROM dbo.Agreement WHERE AgreementId = @AgreementId;
    IF @a_End < CAST(@RaisedAt AS date) PRINT N'WARNING: this agreement ended on ' + CONVERT(nvarchar(11), @a_End, 106) + N'.';
    IF @a_Start > CAST(@RaisedAt AS date) PRINT N'WARNING: this agreement does not start until ' + CONVERT(nvarchar(11), @a_Start, 106) + N'.';
    IF @a_Paused IS NOT NULL PRINT N'WARNING: support is paused for late payment (since ' + CONVERT(nvarchar(11), @a_Paused, 106) + N').';

    INSERT dbo.Ticket (AgreementId, InstanceId, ContactId, Severity, WorkType, Title, Description, Channel, RaisedAt, ResponseDueAt, Status)
    VALUES (@AgreementId, @InstanceId, @ContactId, @Severity, @WorkType, @Title, @Description, @Channel, @RaisedAt,
            dbo.fn_ResponseDue(@RaisedAt, @Severity), 'Open');
    DECLARE @TicketId int = SCOPE_IDENTITY();

    IF dbo.fn_IsBusinessHours(@RaisedAt) = 0 AND @Severity = 'Critical'
        PRINT N'Raised outside business hours: treated as top priority at the start of the next business day (no guaranteed out-of-hours response).';
    IF @WorkType = 'Project'
        PRINT N'Project work: scope and quote with usp_Quote_Add before starting.';

    SELECT t.TicketRef, c.ClientName, t.Severity, t.Title, Instance = @InstanceName, t.RaisedAt, t.ResponseDueAt,
           DueIn = CASE WHEN DATEDIFF(minute, dbo.fn_UkNow(), t.ResponseDueAt) < 0 THEN 'OVERDUE'
                        ELSE CONVERT(varchar(10), DATEDIFF(minute, dbo.fn_UkNow(), t.ResponseDueAt) / 60) + 'h ' + CONVERT(varchar(10), DATEDIFF(minute, dbo.fn_UkNow(), t.ResponseDueAt) % 60) + 'm' END
    FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE t.TicketId = @TicketId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Ticket_Respond
    @TicketRef   varchar(20),
    @RespondedAt datetime2(0) = NULL,
    @Status      varchar(30)  = 'InProgress'
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Ticket
    SET FirstResponseAt = ISNULL(FirstResponseAt, ISNULL(@RespondedAt, dbo.fn_UkNow())), Status = @Status
    WHERE TicketRef = @TicketRef;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR(N'Ticket %s not found.', 16, 1, @TicketRef); RETURN; END
    SELECT TicketRef, Severity, RaisedAt, ResponseDueAt, FirstResponseAt,
           Sla = CASE WHEN FirstResponseAt <= ResponseDueAt THEN 'Met' ELSE 'Missed' END, Status
    FROM dbo.Ticket WHERE TicketRef = @TicketRef;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Ticket_Estimate
    @TicketRef     varchar(20),
    @EstimateHours decimal(6,2) = NULL,  -- sets the estimate and marks it sent
    @Approved      bit = 0               -- 1 = client approved the estimate
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Ticket
    SET EstimateHours = ISNULL(@EstimateHours, EstimateHours),
        EstimateSentAt = CASE WHEN @EstimateHours IS NOT NULL THEN dbo.fn_UkNow() ELSE EstimateSentAt END,
        EstimateApprovedAt = CASE WHEN @Approved = 1 THEN dbo.fn_UkNow() ELSE EstimateApprovedAt END,
        Status = CASE WHEN @Approved = 1 THEN 'InProgress' WHEN @EstimateHours IS NOT NULL THEN 'AwaitingEstimateApproval' ELSE Status END
    WHERE TicketRef = @TicketRef;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR(N'Ticket %s not found.', 16, 1, @TicketRef); RETURN; END
    SELECT TicketRef, Title, EstimateHours, EstimateSentAt, EstimateApprovedAt, Status FROM dbo.Ticket WHERE TicketRef = @TicketRef;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Time_Log
    @TicketRef   varchar(20),
    @Minutes     int,
    @Description nvarchar(1000),
    @WorkStart   datetime2(0) = NULL,   -- UK time; default = now minus @Minutes
    @RateType    varchar(20)  = NULL,   -- BusinessHours | OutOfHours; default decided from @WorkStart
    @IsBillable  bit          = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TicketId int, @AgreementId int, @WorkType varchar(20), @EstApproved datetime2(0), @EstHours decimal(6,2);
    SELECT @TicketId = TicketId, @AgreementId = AgreementId, @WorkType = WorkType, @EstApproved = EstimateApprovedAt, @EstHours = EstimateHours
    FROM dbo.Ticket WHERE TicketRef = @TicketRef;
    IF @TicketId IS NULL BEGIN RAISERROR(N'Ticket %s not found.', 16, 1, @TicketRef); RETURN; END

    SET @WorkStart = ISNULL(@WorkStart, DATEADD(minute, -@Minutes, dbo.fn_UkNow()));
    SET @RateType = ISNULL(@RateType, CASE WHEN @WorkType = 'PlannedOutOfHours' OR dbo.fn_IsBusinessHours(@WorkStart) = 0 THEN 'OutOfHours' ELSE 'BusinessHours' END);

    INSERT dbo.TimeEntry (TicketId, WorkStart, Minutes, RateType, Description, IsBillable)
    VALUES (@TicketId, @WorkStart, @Minutes, @RateType, @Description, @IsBillable);

    UPDATE dbo.Ticket SET Status = 'InProgress', FirstResponseAt = ISNULL(FirstResponseAt, @WorkStart)
    WHERE TicketId = @TicketId AND Status = 'Open';

    DECLARE @Total int = (SELECT SUM(Minutes) FROM dbo.TimeEntry WHERE TicketId = @TicketId AND IsBillable = 1);
    DECLARE @Threshold int = ISNULL(TRY_CONVERT(int, dbo.fn_Setting('EstimateThresholdMinutes')), 60);
    IF @Total > @Threshold AND @EstApproved IS NULL
        PRINT N'ESTIMATE NEEDED: ' + @TicketRef + N' now has ' + CONVERT(nvarchar(10), @Total) + N' minutes logged. The agreement says work over 1 hour must be flagged to the client with an estimate before continuing (usp_Ticket_Estimate).';
    ELSE IF @EstHours IS NOT NULL AND @Total > @EstHours * 60
        PRINT N'NOTE: logged time (' + CONVERT(nvarchar(10), @Total) + N' min) has passed the approved estimate of ' + CONVERT(nvarchar(10), @EstHours) + N' hours.';
    IF @RateType = 'OutOfHours' AND @WorkType <> 'PlannedOutOfHours'
    BEGIN
        DECLARE @OohRate nvarchar(20) = (SELECT CONVERT(nvarchar(20), OutOfHoursRate) FROM dbo.PriceList WHERE PriceListId = dbo.fn_PriceListIdOn(@AgreementId, CAST(@WorkStart AS date)));
        PRINT N'Logged as OUT OF HOURS (GBP ' + ISNULL(@OohRate, N'?') + N'/h). Pass @RateType = ''BusinessHours'' if that is wrong.';
    END

    EXEC dbo.usp_Agreement_Usage @Client = NULL, @AgreementId = @AgreementId, @AsOfDate = @WorkStart;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Ticket_Close
    @TicketRef  varchar(20),
    @Resolution nvarchar(max),
    @Status     varchar(30) = 'Resolved'   -- Resolved | Closed
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Ticket SET Status = @Status, Resolution = @Resolution, ResolvedAt = ISNULL(ResolvedAt, dbo.fn_UkNow()),
           FirstResponseAt = ISNULL(FirstResponseAt, dbo.fn_UkNow())
    WHERE TicketRef = @TicketRef;
    IF @@ROWCOUNT = 0 BEGIN RAISERROR(N'Ticket %s not found.', 16, 1, @TicketRef); RETURN; END
    SELECT t.TicketRef, t.Title, t.Status, t.RaisedAt, t.ResolvedAt,
           MinutesLogged = (SELECT SUM(Minutes) FROM dbo.TimeEntry e WHERE e.TicketId = t.TicketId)
    FROM dbo.Ticket t WHERE t.TicketRef = @TicketRef;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Quote_Add
    @Client         nvarchar(200),
    @Title          nvarchar(200),
    @Scope          nvarchar(max) = NULL,
    @EstimatedHours decimal(7,2)  = NULL,
    @Price          decimal(10,2) = NULL,
    @TicketRef      varchar(20)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = (SELECT ClientId FROM dbo.Agreement WHERE AgreementId = dbo.fn_AgreementId(@Client));
    SET @ClientId = ISNULL(@ClientId, (SELECT ClientId FROM dbo.Client WHERE ClientName = @Client));
    IF @ClientId IS NULL BEGIN RAISERROR(N'Client "%s" not found.', 16, 1, @Client); RETURN; END
    INSERT dbo.Quote (ClientId, TicketId, Title, Scope, EstimatedHours, Price)
    VALUES (@ClientId, (SELECT TicketId FROM dbo.Ticket WHERE TicketRef = @TicketRef), @Title, @Scope, @EstimatedHours, @Price);
    SELECT * FROM dbo.Quote WHERE QuoteId = SCOPE_IDENTITY();
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_WeeklyReport_Log
    @Client        nvarchar(200),
    @InstanceName  nvarchar(128),
    @OverallStatus varchar(10)  = NULL,   -- Red | Amber | Green
    @CriticalCount int          = NULL,
    @WarningCount  int          = NULL,
    @WeekEnding    date         = NULL,   -- default: the most recent Sunday
    @Notes         nvarchar(max) = NULL,
    @FollowUpTicketRef varchar(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    DECLARE @InstanceId int = (SELECT TOP (1) InstanceId FROM dbo.Instance WHERE AgreementId = @AgreementId AND InstanceName = @InstanceName ORDER BY CASE WHEN CoveredTo IS NULL THEN 0 ELSE 1 END);
    IF @InstanceId IS NULL BEGIN RAISERROR(N'Instance "%s" not found on that agreement.', 16, 1, @InstanceName); RETURN; END
    DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
    -- 1900-01-07 was a Sunday
    SET @WeekEnding = ISNULL(@WeekEnding, DATEADD(day, -(DATEDIFF(day, '19000107', @Today) % 7), @Today));

    MERGE dbo.WeeklyReportLog AS t
    USING (SELECT @InstanceId AS InstanceId, @WeekEnding AS WeekEnding) AS s
    ON t.InstanceId = s.InstanceId AND t.WeekEnding = s.WeekEnding
    WHEN MATCHED THEN UPDATE SET SentAt = dbo.fn_UkNow(), OverallStatus = ISNULL(@OverallStatus, t.OverallStatus), CriticalCount = ISNULL(@CriticalCount, t.CriticalCount),
                                 WarningCount = ISNULL(@WarningCount, t.WarningCount), Notes = ISNULL(@Notes, t.Notes),
                                 FollowUpTicketId = ISNULL((SELECT TicketId FROM dbo.Ticket WHERE TicketRef = @FollowUpTicketRef), t.FollowUpTicketId)
    WHEN NOT MATCHED THEN INSERT (InstanceId, WeekEnding, SentAt, OverallStatus, CriticalCount, WarningCount, Notes, FollowUpTicketId)
                          VALUES (@InstanceId, @WeekEnding, dbo.fn_UkNow(), @OverallStatus, @CriticalCount, @WarningCount, @Notes,
                                  (SELECT TicketId FROM dbo.Ticket WHERE TicketRef = @FollowUpTicketRef));

    UPDATE dbo.OnboardingItem SET CompletedDate = @Today WHERE AgreementId = @AgreementId AND ItemCode = 'FIRST_REPORT' AND CompletedDate IS NULL;
    PRINT N'Weekly report logged for ' + @InstanceName + N', week ending ' + CONVERT(nvarchar(11), @WeekEnding, 106) + N'.';
END
GO

/*=============================================================================
  7. BILLING
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_Agreement_Usage
    @Client      nvarchar(200) = NULL,
    @AgreementId int           = NULL,
    @AsOfDate    date          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @AgreementId = ISNULL(@AgreementId, dbo.fn_AgreementId(@Client));
    SET @AsOfDate = ISNULL(@AsOfDate, CAST(dbo.fn_UkNow() AS date));
    DECLARE @Start date = (SELECT StartDate FROM dbo.Agreement WHERE AgreementId = @AgreementId);
    DECLARE @n int = dbo.fn_CycleNumberForDate(@Start, @AsOfDate);
    IF @n = 0 BEGIN PRINT N'The agreement has not started yet.'; RETURN; END
    DECLARE @CycleStart date = dbo.fn_CycleStart(@Start, @n), @CycleEnd date = DATEADD(day, -1, dbo.fn_CycleStart(@Start, @n + 1));
    DECLARE @Included decimal(5,2) = (SELECT IncludedHoursPerCycle FROM dbo.PriceList WHERE PriceListId = dbo.fn_PriceListIdOn(@AgreementId, @CycleStart));

    SELECT CycleNumber = @n, CycleStart = @CycleStart, CycleEnd = @CycleEnd,
           IncludedHours = @Included,
           BusinessHoursLogged = CAST(ISNULL(SUM(CASE WHEN e.RateType = 'BusinessHours' THEN e.Minutes END), 0) / 60.0 AS decimal(6,2)),
           IncludedHoursRemaining = CAST(CASE WHEN @Included - ISNULL(SUM(CASE WHEN e.RateType = 'BusinessHours' THEN e.Minutes END), 0) / 60.0 < 0 THEN 0
                                              ELSE @Included - ISNULL(SUM(CASE WHEN e.RateType = 'BusinessHours' THEN e.Minutes END), 0) / 60.0 END AS decimal(6,2)),
           OutOfHoursLogged = CAST(ISNULL(SUM(CASE WHEN e.RateType = 'OutOfHours' THEN e.Minutes END), 0) / 60.0 AS decimal(6,2)),
           Note = N'Approximate - minimum charges are applied at invoicing. Unused included hours do not roll over.'
    FROM dbo.Ticket t
    LEFT JOIN dbo.TimeEntry e ON e.TicketId = t.TicketId AND e.IsBillable = 1 AND CAST(e.WorkStart AS date) BETWEEN @CycleStart AND @CycleEnd
    WHERE t.AgreementId = @AgreementId AND t.WorkType <> 'Project';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_New
    @AgreementId int,
    @InvoiceDate date,
    @InvoiceId   int OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Prefix varchar(10) = ISNULL(NULLIF(dbo.fn_Setting('InvoicePrefix'), N''), 'INV');
    DECLARE @Year char(4) = CONVERT(char(4), YEAR(@InvoiceDate));
    DECLARE @Seq int = ISNULL((SELECT MAX(TRY_CONVERT(int, RIGHT(InvoiceNo, 4))) FROM dbo.Invoice WHERE InvoiceNo LIKE @Prefix + '-' + @Year + '-%'), 0) + 1;
    INSERT dbo.Invoice (InvoiceNo, AgreementId, InvoiceDate, DueDate)
    VALUES (@Prefix + '-' + @Year + '-' + RIGHT('0000' + CONVERT(varchar(10), @Seq), 4), @AgreementId, @InvoiceDate,
            DATEADD(day, ISNULL(TRY_CONVERT(int, dbo.fn_Setting('PaymentTermsDays')), 14), @InvoiceDate));
    SET @InvoiceId = SCOPE_IDENTITY();
END
GO

-- Additional support for one billing cycle, billed in arrears
CREATE OR ALTER PROCEDURE dbo.usp_Invoice_AddArrears
    @InvoiceId      int,
    @BillingCycleId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int, @Start date, @End date, @Included decimal(6,2), @Used decimal(6,2), @BhRate decimal(9,2), @OohRate decimal(9,2), @Min decimal(5,2);
    SELECT @AgreementId = bc.AgreementId, @Start = bc.StartDate, @End = bc.EndDate, @Included = bc.IncludedHours, @Used = bc.IncludedHoursUsed,
           @BhRate = p.BusinessHoursRate, @OohRate = p.OutOfHoursRate, @Min = p.MinimumChargeHours
    FROM dbo.BillingCycle bc JOIN dbo.PriceList p ON p.PriceListId = bc.PriceListId
    WHERE bc.BillingCycleId = @BillingCycleId;
    DECLARE @Strict bit = CASE WHEN dbo.fn_Setting('MinimumChargeMode') = N'Strict' THEN 1 ELSE 0 END;
    DECLARE @Period nvarchar(40) = CONVERT(nvarchar(11), @Start, 106) + N' - ' + CONVERT(nvarchar(11), @End, 106);

    SELECT e.TimeEntryId, e.TicketId, e.Minutes, e.RateType, e.WorkStart
    INTO #entries
    FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId
    WHERE t.AgreementId = @AgreementId AND t.WorkType <> 'Project' AND e.IsBillable = 1 AND e.InvoiceId IS NULL
      AND CAST(e.WorkStart AS date) BETWEEN @Start AND @End;

    SELECT t.TicketId, t.TicketRef, t.Title, Instance = i.InstanceName,
           BhHours  = CAST(ISNULL(SUM(CASE WHEN x.RateType = 'BusinessHours' THEN x.Minutes END), 0) / 60.0 AS decimal(9,4)),
           OohHours = CAST(ISNULL(SUM(CASE WHEN x.RateType = 'OutOfHours' THEN x.Minutes END), 0) / 60.0 AS decimal(9,4)),
           FirstWork = MIN(x.WorkStart)
    INTO #tickets
    FROM #entries x JOIN dbo.Ticket t ON t.TicketId = x.TicketId LEFT JOIN dbo.Instance i ON i.InstanceId = t.InstanceId
    GROUP BY t.TicketId, t.TicketRef, t.Title, i.InstanceName;

    DECLARE @Remaining decimal(9,4) = CASE WHEN @Included - @Used > 0 THEN @Included - @Used ELSE 0 END;
    DECLARE @UsedNow decimal(9,4) = 0;
    DECLARE @TicketId int, @Ref varchar(20), @Title nvarchar(200), @Inst nvarchar(128), @Bh decimal(9,4), @Ooh decimal(9,4);
    DECLARE @TicketHours decimal(9,4), @Covered decimal(9,4), @Charged decimal(9,4), @Label nvarchar(400);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TicketId, TicketRef, Title, Instance, BhHours, OohHours FROM #tickets ORDER BY FirstWork, TicketId;
    OPEN c;
    FETCH NEXT FROM c INTO @TicketId, @Ref, @Title, @Inst, @Bh, @Ooh;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @Label = @Ref + N' ' + LEFT(@Title, 120) + ISNULL(N' (' + @Inst + N')', N'');
        IF @Bh > 0
        BEGIN
            IF @Strict = 1
            BEGIN
                SET @TicketHours = CASE WHEN @Bh < @Min THEN @Min ELSE @Bh END;
                SET @Covered = CASE WHEN @TicketHours < @Remaining THEN @TicketHours ELSE @Remaining END;
                SET @Charged = @TicketHours - @Covered;
            END
            ELSE
            BEGIN
                SET @Covered = CASE WHEN @Bh < @Remaining THEN @Bh ELSE @Remaining END;
                SET @Charged = CASE WHEN @Bh - @Covered <= 0 THEN 0
                                    WHEN @Bh - @Covered > @Min - @Covered THEN @Bh - @Covered
                                    ELSE @Min - @Covered END;
            END
            SET @Remaining = @Remaining - @Covered;
            SET @UsedNow = @UsedNow + @Covered;
            IF ROUND(@Charged, 2) > 0
                INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, TicketId, Description, Quantity, UnitPrice, Amount)
                VALUES (@InvoiceId, 'BusinessHours', @BillingCycleId, @TicketId,
                        N'Additional business-hours support: ' + @Label + N' - ' + FORMAT(@Bh, 'N2') + N' h worked'
                        + CASE WHEN @Covered > 0 THEN N', ' + FORMAT(@Covered, 'N2') + N' h from included hours' ELSE N'' END
                        + CASE WHEN ROUND(@Charged, 2) > ROUND(@Bh - @Covered, 2) THEN N', 1 h minimum charge applied' ELSE N'' END,
                        ROUND(@Charged, 2), @BhRate, ROUND(ROUND(@Charged, 2) * @BhRate, 2));
        END
        IF @Ooh > 0
        BEGIN
            SET @Charged = CASE WHEN @Ooh < @Min THEN @Min ELSE @Ooh END;
            INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, TicketId, Description, Quantity, UnitPrice, Amount)
            VALUES (@InvoiceId, 'OutOfHours', @BillingCycleId, @TicketId,
                    N'Out-of-hours support: ' + @Label + N' - ' + FORMAT(@Ooh, 'N2') + N' h worked'
                    + CASE WHEN @Ooh < @Min THEN N', 1 h minimum charge applied' ELSE N'' END,
                    ROUND(@Charged, 2), @OohRate, ROUND(ROUND(@Charged, 2) * @OohRate, 2));
        END
        FETCH NEXT FROM c INTO @TicketId, @Ref, @Title, @Inst, @Bh, @Ooh;
    END
    CLOSE c; DEALLOCATE c;

    IF EXISTS (SELECT 1 FROM #tickets)
        INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, Description, Quantity, UnitPrice, Amount)
        VALUES (@InvoiceId, 'Info', @BillingCycleId,
                N'Included support hours used for ' + @Period + N': ' + FORMAT(@Used + @UsedNow, 'N2') + N' of ' + FORMAT(@Included, 'N2') + N' (unused hours do not roll over)',
                0, 0, 0);

    UPDATE dbo.TimeEntry SET InvoiceId = @InvoiceId WHERE TimeEntryId IN (SELECT TimeEntryId FROM #entries);
    UPDATE dbo.BillingCycle SET IncludedHoursUsed = IncludedHoursUsed + ROUND(@UsedNow, 2), ArrearsProcessedAt = SYSDATETIME() WHERE BillingCycleId = @BillingCycleId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_Recalculate
    @InvoiceId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @VatRate decimal(5,2) = CASE WHEN dbo.fn_Setting('VatRegistered') = N'1' THEN ISNULL(TRY_CONVERT(decimal(5,2), dbo.fn_Setting('VatRatePct')), 20) ELSE 0 END;
    UPDATE i SET SubTotal = x.SubTotal, VatRatePct = @VatRate, VatAmount = ROUND(x.SubTotal * @VatRate / 100, 2),
                 Total = x.SubTotal + ROUND(x.SubTotal * @VatRate / 100, 2)
    FROM dbo.Invoice i
    CROSS APPLY (SELECT SubTotal = ISNULL(SUM(Amount), 0) FROM dbo.InvoiceLine l WHERE l.InvoiceId = i.InvoiceId) x
    WHERE i.InvoiceId = @InvoiceId AND i.Status = 'Draft';
END
GO

/* Creates billing cycles and DRAFT invoices due up to @AsOfDate. Run daily (the scheduled task does this).
   Each cycle's invoice = monthly fees for that cycle (in advance) + additional support from earlier cycles (in arrears).
   After an agreement ends, its final additional support is invoiced on its own. */
CREATE OR ALTER PROCEDURE dbo.usp_Billing_Run
    @AsOfDate date = NULL,
    @Client   nvarchar(200) = NULL   -- NULL = all agreements
AS
BEGIN
    SET NOCOUNT ON;
    SET @AsOfDate = ISNULL(@AsOfDate, CAST(dbo.fn_UkNow() AS date));
    DECLARE @Only int = CASE WHEN @Client IS NOT NULL THEN dbo.fn_AgreementId(@Client) END;
    IF @Client IS NOT NULL AND @Only IS NULL BEGIN RAISERROR(N'Agreement or client "%s" not found.', 16, 1, @Client); RETURN; END
    DECLARE @Created TABLE (InvoiceId int);
    DECLARE @AgreementId int, @Start date, @End date, @n int, @cs date, @ce date, @pl int;

    -- 1. billing cycles
    DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT AgreementId, StartDate, EndDate FROM dbo.Agreement WHERE StartDate <= @AsOfDate AND (@Only IS NULL OR AgreementId = @Only);
    OPEN a;
    FETCH NEXT FROM a INTO @AgreementId, @Start, @End;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @n = 1;
        WHILE dbo.fn_CycleStart(@Start, @n) <= @AsOfDate AND (@End IS NULL OR dbo.fn_CycleStart(@Start, @n) <= @End)
        BEGIN
            SET @cs = dbo.fn_CycleStart(@Start, @n);
            SET @ce = DATEADD(day, -1, dbo.fn_CycleStart(@Start, @n + 1));
            IF @End < @ce SET @ce = @End;
            IF NOT EXISTS (SELECT 1 FROM dbo.BillingCycle WHERE AgreementId = @AgreementId AND CycleNumber = @n)
            BEGIN
                SET @pl = dbo.fn_PriceListIdOn(@AgreementId, @cs);
                INSERT dbo.BillingCycle (AgreementId, CycleNumber, StartDate, EndDate, PriceListId, IncludedHours)
                SELECT @AgreementId, @n, @cs, @ce, @pl, IncludedHoursPerCycle FROM dbo.PriceList WHERE PriceListId = @pl;
            END
            ELSE
                UPDATE dbo.BillingCycle SET EndDate = @ce WHERE AgreementId = @AgreementId AND CycleNumber = @n AND EndDate <> @ce;  -- notice shortened it
            SET @n = @n + 1;
        END
        FETCH NEXT FROM a INTO @AgreementId, @Start, @End;
    END
    CLOSE a; DEALLOCATE a;

    -- 2. one invoice per cycle start: fees in advance + outstanding arrears from earlier cycles
    DECLARE @CycleId int, @InvoiceId int, @PrevId int, @CycleNo int;
    DECLARE cyc CURSOR LOCAL FAST_FORWARD FOR
        SELECT BillingCycleId, AgreementId, CycleNumber, StartDate, EndDate FROM dbo.BillingCycle
        WHERE FeeInvoiceId IS NULL AND StartDate <= @AsOfDate AND (@Only IS NULL OR AgreementId = @Only) ORDER BY AgreementId, CycleNumber;
    OPEN cyc;
    FETCH NEXT FROM cyc INTO @CycleId, @AgreementId, @CycleNo, @cs, @ce;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
        EXEC dbo.usp_Invoice_New @AgreementId = @AgreementId, @InvoiceDate = @cs, @InvoiceId = @InvoiceId OUTPUT;

        INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, InstanceId, Description, Quantity, UnitPrice, Amount)
        SELECT @InvoiceId, 'MonthlyFee', @CycleId, f.InstanceId,
               N'Molehill Watch SQL Server support, ' + CONVERT(nvarchar(11), @cs, 106) + N' - ' + CONVERT(nvarchar(11), @ce, 106) + N': '
               + f.InstanceName + N' (' + f.PricingBasis + CASE WHEN f.Environment = 'NonProduction' THEN ', non-production' ELSE '' END + N')',
               1, f.MonthlyFee, f.MonthlyFee
        FROM dbo.fn_AgreementFees(@AgreementId, @cs) f
        ORDER BY f.MonthlyFee DESC, f.InstanceName;

        DECLARE prev CURSOR LOCAL FAST_FORWARD FOR
            SELECT BillingCycleId FROM dbo.BillingCycle bc
            WHERE bc.AgreementId = @AgreementId AND bc.CycleNumber < @CycleNo
              AND (bc.ArrearsProcessedAt IS NULL
                   OR EXISTS (SELECT 1 FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId
                              WHERE t.AgreementId = bc.AgreementId AND t.WorkType <> 'Project' AND e.IsBillable = 1 AND e.InvoiceId IS NULL
                                AND CAST(e.WorkStart AS date) BETWEEN bc.StartDate AND bc.EndDate))
            ORDER BY bc.CycleNumber;
        OPEN prev;
        FETCH NEXT FROM prev INTO @PrevId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            EXEC dbo.usp_Invoice_AddArrears @InvoiceId = @InvoiceId, @BillingCycleId = @PrevId;
            FETCH NEXT FROM prev INTO @PrevId;
        END
        CLOSE prev; DEALLOCATE prev;

        IF NOT EXISTS (SELECT 1 FROM dbo.InvoiceLine WHERE InvoiceId = @InvoiceId)
        BEGIN
            -- nothing covered at the cycle start and nothing owed: no invoice (the cycle is looked at again next run)
            DELETE dbo.Invoice WHERE InvoiceId = @InvoiceId;
            COMMIT;
            DECLARE @NoFeeMsg nvarchar(400) = N'No invoice for ' + (SELECT AgreementRef FROM dbo.Agreement WHERE AgreementId = @AgreementId)
                + N' cycle ' + CONVERT(nvarchar(10), @CycleNo) + N' (' + CONVERT(nvarchar(11), @cs, 106)
                + N'): no instances were covered at the cycle start. Check the instances'' Covered from dates.';
            IF @cs >= DATEADD(day, -35, @AsOfDate) PRINT @NoFeeMsg;   -- only nag about recent cycles
            FETCH NEXT FROM cyc INTO @CycleId, @AgreementId, @CycleNo, @cs, @ce;
            CONTINUE;
        END
        UPDATE dbo.BillingCycle SET FeeInvoiceId = @InvoiceId WHERE BillingCycleId = @CycleId;
        EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
        COMMIT;
        INSERT @Created VALUES (@InvoiceId);
        FETCH NEXT FROM cyc INTO @CycleId, @AgreementId, @CycleNo, @cs, @ce;
    END
    CLOSE cyc; DEALLOCATE cyc;

    -- 3. finished cycles still holding unbilled support (final cycle of an ended agreement, or late time entries)
    DECLARE fin CURSOR LOCAL FAST_FORWARD FOR
        SELECT bc.BillingCycleId, bc.AgreementId, bc.EndDate FROM dbo.BillingCycle bc
        WHERE bc.EndDate < @AsOfDate AND (@Only IS NULL OR bc.AgreementId = @Only)
          AND (bc.ArrearsProcessedAt IS NULL
               OR EXISTS (SELECT 1 FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId
                          WHERE t.AgreementId = bc.AgreementId AND t.WorkType <> 'Project' AND e.IsBillable = 1 AND e.InvoiceId IS NULL
                            AND CAST(e.WorkStart AS date) BETWEEN bc.StartDate AND bc.EndDate))
        ORDER BY bc.AgreementId, bc.CycleNumber;
    OPEN fin;
    FETCH NEXT FROM fin INTO @CycleId, @AgreementId, @ce;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF EXISTS (SELECT 1 FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId JOIN dbo.BillingCycle bc ON bc.BillingCycleId = @CycleId
                   WHERE t.AgreementId = @AgreementId AND t.WorkType <> 'Project' AND e.IsBillable = 1 AND e.InvoiceId IS NULL
                     AND CAST(e.WorkStart AS date) BETWEEN bc.StartDate AND bc.EndDate)
        BEGIN
            BEGIN TRAN;
            SET @cs = DATEADD(day, 1, @ce);
            EXEC dbo.usp_Invoice_New @AgreementId = @AgreementId, @InvoiceDate = @cs, @InvoiceId = @InvoiceId OUTPUT;
            EXEC dbo.usp_Invoice_AddArrears @InvoiceId = @InvoiceId, @BillingCycleId = @CycleId;
            EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
            COMMIT;
            INSERT @Created VALUES (@InvoiceId);
        END
        ELSE
            UPDATE dbo.BillingCycle SET ArrearsProcessedAt = SYSDATETIME() WHERE BillingCycleId = @CycleId;
        FETCH NEXT FROM fin INTO @CycleId, @AgreementId, @ce;
    END
    CLOSE fin; DEALLOCATE fin;

    SELECT i.InvoiceNo, c.ClientName, a.AgreementRef, i.InvoiceDate, i.DueDate, i.SubTotal, i.VatAmount, i.Total, i.Status
    FROM @Created x JOIN dbo.Invoice i ON i.InvoiceId = x.InvoiceId
    JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    ORDER BY i.InvoiceNo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_Adjust
    @InvoiceNo   varchar(30),
    @Description nvarchar(500),
    @Amount      decimal(10,2)     -- negative for a credit
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @InvoiceId int = (SELECT InvoiceId FROM dbo.Invoice WHERE InvoiceNo = @InvoiceNo AND Status = 'Draft');
    IF @InvoiceId IS NULL BEGIN RAISERROR(N'Draft invoice %s not found (only drafts can be changed).', 16, 1, @InvoiceNo); RETURN; END
    INSERT dbo.InvoiceLine (InvoiceId, LineType, Description, Quantity, UnitPrice, Amount) VALUES (@InvoiceId, 'Adjustment', @Description, 1, @Amount, @Amount);
    EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
    SELECT InvoiceNo, SubTotal, VatAmount, Total FROM dbo.Invoice WHERE InvoiceId = @InvoiceId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_SetStatus
    @InvoiceNo  varchar(30),
    @Status     varchar(10),          -- Sent | Paid | Void
    @StatusDate date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET @StatusDate = ISNULL(@StatusDate, CAST(dbo.fn_UkNow() AS date));
    DECLARE @InvoiceId int = (SELECT InvoiceId FROM dbo.Invoice WHERE InvoiceNo = @InvoiceNo);
    IF @InvoiceId IS NULL BEGIN RAISERROR(N'Invoice %s not found.', 16, 1, @InvoiceNo); RETURN; END

    IF @Status = 'Sent'
        UPDATE dbo.Invoice SET Status = 'Sent', SentAt = @StatusDate, InvoiceDate = @StatusDate,
               DueDate = DATEADD(day, ISNULL(TRY_CONVERT(int, dbo.fn_Setting('PaymentTermsDays')), 14), @StatusDate)
        WHERE InvoiceId = @InvoiceId AND Status = 'Draft';
    ELSE IF @Status = 'Paid'
    BEGIN
        UPDATE dbo.Invoice SET Status = 'Paid', PaidAt = @StatusDate WHERE InvoiceId = @InvoiceId AND Status IN ('Draft', 'Sent');
        -- lift a late-payment pause once nothing is overdue
        UPDATE a SET SupportPausedFrom = NULL
        FROM dbo.Agreement a
        WHERE a.AgreementId = (SELECT AgreementId FROM dbo.Invoice WHERE InvoiceId = @InvoiceId) AND a.SupportPausedFrom IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dbo.Invoice i WHERE i.AgreementId = a.AgreementId AND i.Status = 'Sent' AND i.DueDate < @StatusDate);
    END
    ELSE IF @Status = 'Void'
    BEGIN
        -- release time and cycles so a corrected invoice is produced on the next billing run
        UPDATE dbo.TimeEntry SET InvoiceId = NULL WHERE InvoiceId = @InvoiceId;
        UPDATE bc SET IncludedHoursUsed = 0, ArrearsProcessedAt = NULL
        FROM dbo.BillingCycle bc WHERE bc.BillingCycleId IN (SELECT BillingCycleId FROM dbo.InvoiceLine WHERE InvoiceId = @InvoiceId AND LineType IN ('BusinessHours', 'OutOfHours', 'Info'));
        UPDATE dbo.BillingCycle SET FeeInvoiceId = NULL WHERE FeeInvoiceId = @InvoiceId;
        UPDATE dbo.Invoice SET Status = 'Void', Notes = ISNULL(Notes + N' ', N'') + N'Voided ' + CONVERT(nvarchar(11), @StatusDate, 106) WHERE InvoiceId = @InvoiceId;
        PRINT N'Invoice voided. Run usp_Billing_Run to produce a replacement.';
    END
    ELSE BEGIN RAISERROR(N'@Status must be Sent, Paid or Void.', 16, 1); RETURN; END

    SELECT InvoiceNo, InvoiceDate, DueDate, Total, Status, SentAt, PaidAt FROM dbo.Invoice WHERE InvoiceId = @InvoiceId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Agreement_PauseSupport
    @Client    nvarchar(200),
    @Pause     bit = 1,
    @PauseDate date = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE dbo.Agreement SET SupportPausedFrom = CASE WHEN @Pause = 1 THEN ISNULL(@PauseDate, CAST(dbo.fn_UkNow() AS date)) END
    WHERE AgreementId = dbo.fn_AgreementId(@Client);
    PRINT CASE WHEN @Pause = 1 THEN N'Support paused for late payment.' ELSE N'Support resumed.' END;
END
GO

/*=============================================================================
  8. INVOICE DOCUMENT
=============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_Html (@s nvarchar(max))
RETURNS nvarchar(max)
AS
BEGIN
    RETURN REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@s, N''), N'&', N'&amp;'), N'<', N'&lt;'), N'>', N'&gt;'), N'"', N'&quot;');
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_Html
    @InvoiceNo varchar(30),
    @Html      nvarchar(max) = NULL OUTPUT,
    @Select    bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @InvoiceId int, @AgreementId int;
    SELECT @InvoiceId = InvoiceId, @AgreementId = AgreementId FROM dbo.Invoice WHERE InvoiceNo = @InvoiceNo;
    IF @InvoiceId IS NULL BEGIN RAISERROR(N'Invoice %s not found.', 16, 1, @InvoiceNo); RETURN; END

    DECLARE @Vat bit = CASE WHEN (SELECT VatRatePct FROM dbo.Invoice WHERE InvoiceId = @InvoiceId) > 0 THEN 1 ELSE 0 END;
    DECLARE @Rows nvarchar(max) = (
        SELECT STRING_AGG(CONVERT(nvarchar(max),
                   N'<tr' + CASE WHEN LineType = 'Info' THEN N' class="info"' ELSE N'' END + N'><td>' + dbo.fn_Html(Description) + N'</td>'
                 + N'<td class="num">' + CASE WHEN LineType = 'Info' THEN N'' WHEN LineType IN ('BusinessHours', 'OutOfHours') THEN FORMAT(Quantity, 'N2') + N' h' ELSE FORMAT(Quantity, 'N0') END + N'</td>'
                 + N'<td class="num">' + CASE WHEN LineType = 'Info' THEN N'' ELSE N'&#163;' + FORMAT(UnitPrice, 'N2') END + N'</td>'
                 + N'<td class="num">' + CASE WHEN LineType = 'Info' THEN N'' ELSE N'&#163;' + FORMAT(Amount, 'N2') END + N'</td></tr>'), N'')
               WITHIN GROUP (ORDER BY CASE LineType WHEN 'MonthlyFee' THEN 1 WHEN 'BusinessHours' THEN 2 WHEN 'OutOfHours' THEN 3 WHEN 'Info' THEN 4 ELSE 5 END, InvoiceLineId)
        FROM dbo.InvoiceLine WHERE InvoiceId = @InvoiceId);

    SELECT @Html = N'<html><head><meta charset="utf-8" /><title>Invoice ' + i.InvoiceNo + N'</title><style>
body{margin:0;background:#F4F2F1;font-family:"Segoe UI",Arial,sans-serif;color:#231F20;font-size:14px;line-height:1.5}
.page{max-width:820px;margin:24px auto;background:#fff;padding:0 0 30px}
.hero{background:#231F20;color:#fff;padding:28px 36px;display:flex;justify-content:space-between;align-items:flex-end}
.brand{font-size:24px;font-weight:700}.tag{color:#44C8F5;font-size:13px}.title{font-size:30px;font-weight:700;color:#44C8F5}
.body{padding:26px 36px}.cols{display:flex;justify-content:space-between;gap:24px;margin-bottom:24px}
.label{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:#7A7473}
table{width:100%;border-collapse:collapse;font-size:13px}th{background:#231F20;color:#fff;text-align:left;padding:8px 10px}
td{padding:8px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top}td.num,th.num{text-align:right;white-space:nowrap}
tr.info td{color:#55504F;font-style:italic;background:#F2FBFE}
.totals{margin-left:auto;width:320px;margin-top:14px}.totals td{border:none;padding:4px 10px}.grand td{font-size:17px;font-weight:700;border-top:3px solid #44C8F5}
.note{color:#55504F;font-size:12px;margin-top:22px;border-left:4px solid #44C8F5;padding:6px 12px;background:#F2FBFE}
.foot{padding:0 36px;color:#7A7473;font-size:12px}
@media print{body{background:#fff}.page{margin:0}}
</style></head><body><div class="page">
<div class="hero"><div><div class="brand">' + dbo.fn_Html(dbo.fn_Setting('BusinessName')) + N'</div><div class="tag">SQL Server &amp; Azure Consultancy</div></div><div class="title">' + CASE WHEN i.Status = 'Void' THEN N'VOID' ELSE N'INVOICE' END + N'</div></div>
<div class="body"><div class="cols">
<div><div class="label">Bill to</div><strong>' + dbo.fn_Html(c.ClientName) + N'</strong><br />' + REPLACE(dbo.fn_Html(c.Address), CHAR(10), N'<br />')
    + ISNULL(N'<br />' + dbo.fn_Html((SELECT TOP (1) FullName FROM dbo.Contact WHERE ClientId = c.ClientId AND IsBillingContact = 1 AND IsActive = 1)), N'')
    + ISNULL(N'<br />' + dbo.fn_Html(c.BillingEmail), N'') + N'</div>
<div style="text-align:right"><div class="label">Invoice number</div><strong>' + i.InvoiceNo + N'</strong>
<div class="label" style="margin-top:8px">Invoice date</div>' + CONVERT(nvarchar(11), i.InvoiceDate, 106) + N'
<div class="label" style="margin-top:8px">Payment due</div>' + CONVERT(nvarchar(11), i.DueDate, 106) + N'
<div class="label" style="margin-top:8px">Agreement</div>' + a.AgreementRef + N'</div></div>
<table><tr><th>Description</th><th class="num">Qty</th><th class="num">Rate</th><th class="num">Amount</th></tr>' + ISNULL(@Rows, N'') + N'</table>
<table class="totals">
<tr><td>Subtotal</td><td class="num">&#163;' + FORMAT(i.SubTotal, 'N2') + N'</td></tr>'
    + CASE WHEN @Vat = 1 THEN N'<tr><td>VAT at ' + FORMAT(i.VatRatePct, 'N0') + N'%</td><td class="num">&#163;' + FORMAT(i.VatAmount, 'N2') + N'</td></tr>' ELSE N'' END + N'
<tr class="grand"><td>Total due</td><td class="num">&#163;' + FORMAT(i.Total, 'N2') + N'</td></tr></table>
<div class="note">' + CASE WHEN @Vat = 0 THEN dbo.fn_Html(dbo.fn_Setting('BusinessName')) + N' is not currently VAT registered, so no VAT is charged.<br />' ELSE N'' END
    + N'Monthly fees are invoiced in advance; additional support is invoiced in arrears. Payment is due within '
    + ISNULL(dbo.fn_Setting('PaymentTermsDays'), N'14') + N' days of the invoice date. Late payment may result in support being paused until payment is received.'
    + CASE WHEN NULLIF(dbo.fn_Setting('PaymentDetails'), N'') IS NOT NULL THEN N'<br /><br /><strong>Payment details:</strong> ' + REPLACE(dbo.fn_Html(dbo.fn_Setting('PaymentDetails')), CHAR(10), N'<br />') ELSE N'' END
    + N'</div></div>
<div class="foot">' + dbo.fn_Html(dbo.fn_Setting('BusinessName')) + ISNULL(N' &#183; ' + dbo.fn_Html(NULLIF(dbo.fn_Setting('BusinessAddress'), N'')), N'')
    + N' &#183; ' + dbo.fn_Html(dbo.fn_Setting('BusinessEmail')) + N' &#183; ' + dbo.fn_Html(dbo.fn_Setting('BusinessWebsite')) + N'</div>
</div></body></html>'
    FROM dbo.Invoice i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE i.InvoiceId = @InvoiceId;

    IF @Select = 1 SELECT InvoiceNo = @InvoiceNo, Html = @Html;
END
GO

/*=============================================================================
  9. DASHBOARD
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_Dashboard
    @AsOf       datetime2(0) = NULL,
    @AlertsOnly bit = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET @AsOf = ISNULL(@AsOf, dbo.fn_UkNow());
    DECLARE @Today date = CAST(@AsOf AS date);
    DECLARE @Grace int = ISNULL(TRY_CONVERT(int, dbo.fn_Setting('ReportGraceDays')), 2);
    DECLARE @ReviewDays int = ISNULL(TRY_CONVERT(int, dbo.fn_Setting('ReviewReminderDays')), 21);
    DECLARE @Threshold int = ISNULL(TRY_CONVERT(int, dbo.fn_Setting('EstimateThresholdMinutes')), 60);
    DECLARE @LastSunday date = DATEADD(day, -(DATEDIFF(day, '19000107', @Today) % 7), @Today);
    IF @LastSunday = @Today SET @LastSunday = DATEADD(day, -7, @Today);

    CREATE TABLE #A (Priority tinyint, Area varchar(20), Client nvarchar(200), Item nvarchar(300), Detail nvarchar(1000), DueBy datetime2(0) NULL);

    -- Tickets awaiting first response
    INSERT #A
    SELECT CASE WHEN t.ResponseDueAt < @AsOf THEN 1 WHEN t.Severity = 'Critical' THEN 1 ELSE 2 END, 'Ticket', c.ClientName,
           t.TicketRef + N' ' + t.Severity + N': ' + t.Title,
           CASE WHEN t.ResponseDueAt < @AsOf THEN N'Response OVERDUE (was due ' ELSE N'Response due ' END + FORMAT(t.ResponseDueAt, 'ddd dd MMM HH:mm') + CASE WHEN t.ResponseDueAt < @AsOf THEN N')' ELSE N'' END,
           t.ResponseDueAt
    FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE t.FirstResponseAt IS NULL AND t.Status NOT IN ('Resolved', 'Closed');

    -- Estimates needed
    INSERT #A
    SELECT 2, 'Ticket', c.ClientName, t.TicketRef + N' needs an estimate', FORMAT(x.Mins / 60.0, 'N2') + N' h logged without an approved estimate (agreement: flag work over 1 hour before continuing).', NULL
    FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    CROSS APPLY (SELECT Mins = SUM(Minutes) FROM dbo.TimeEntry e WHERE e.TicketId = t.TicketId AND e.IsBillable = 1) x
    WHERE x.Mins > @Threshold AND t.EstimateApprovedAt IS NULL AND t.Status NOT IN ('Resolved', 'Closed') AND t.WorkType = 'Support';

    -- Weekly reports
    IF DATEDIFF(day, @LastSunday, @Today) > @Grace
    INSERT #A
    SELECT 2, 'Report', c.ClientName, N'Weekly report outstanding: ' + i.InstanceName, N'No report logged for the week ending ' + CONVERT(nvarchar(11), @LastSunday, 106) + N'.', NULL
    FROM dbo.Instance i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE i.CoveredTo IS NULL AND i.CoveredFrom <= DATEADD(day, -6, @LastSunday) AND i.MonitoringInstalledDate <= @LastSunday
      AND a.StartDate <= DATEADD(day, -6, @LastSunday) AND (a.EndDate IS NULL OR a.EndDate >= @LastSunday)
      AND NOT EXISTS (SELECT 1 FROM dbo.WeeklyReportLog w WHERE w.InstanceId = i.InstanceId AND w.WeekEnding > DATEADD(day, -7, @LastSunday));

    -- Invoices
    INSERT #A
    SELECT 2, 'Billing', c.ClientName, N'Draft invoice ready to send: ' + i.InvoiceNo, NCHAR(163) + FORMAT(i.Total, 'N2') + N', dated ' + CONVERT(nvarchar(11), i.InvoiceDate, 106) + N'. Review, send, then usp_Invoice_SetStatus @Status = ''Sent''.', NULL
    FROM dbo.Invoice i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE i.Status = 'Draft';

    INSERT #A
    SELECT 1, 'Billing', c.ClientName, N'Payment overdue: ' + i.InvoiceNo,
           NCHAR(163) + FORMAT(i.Total, 'N2') + N' was due ' + CONVERT(nvarchar(11), i.DueDate, 106) + N' (' + CONVERT(nvarchar(10), DATEDIFF(day, i.DueDate, @Today)) + N' days). Support may be paused until paid'
           + CASE WHEN a.SupportPausedFrom IS NOT NULL THEN N' - currently PAUSED.' ELSE N'.' END, NULL
    FROM dbo.Invoice i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE i.Status = 'Sent' AND i.DueDate < @Today;

    -- Contacts: onboarding done, but every named contact has since been removed
    INSERT #A
    SELECT 2, 'Contacts', c.ClientName, N'No current named contact (' + a.AgreementRef + N')',
           N'Every named point of contact has been removed. The agreement needs one for ticket queries: add or re-add one.', NULL
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE (a.EndDate IS NULL OR a.EndDate >= @Today)
      AND EXISTS (SELECT 1 FROM dbo.OnboardingItem o WHERE o.AgreementId = a.AgreementId AND o.ItemCode = 'NAMED_CONTACT' AND o.CompletedDate IS NOT NULL)
      AND NOT EXISTS (SELECT 1 FROM dbo.Contact ct WHERE ct.ClientId = a.ClientId AND ct.IsActive = 1 AND ct.IsNamedContact = 1);

    -- Onboarding
    INSERT #A
    SELECT 2, 'Onboarding', c.ClientName, N'Onboarding incomplete (' + a.AgreementRef + N')',
           STRING_AGG(CONVERT(nvarchar(max), o.Description), N'; ') WITHIN GROUP (ORDER BY o.SortOrder), NULL
    FROM dbo.OnboardingItem o JOIN dbo.Agreement a ON a.AgreementId = o.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE o.IsRequired = 1 AND o.CompletedDate IS NULL AND (a.EndDate IS NULL OR a.EndDate >= @Today)
    GROUP BY c.ClientName, a.AgreementRef;

    -- Initial term review and endings
    INSERT #A
    SELECT 2, 'Agreement', c.ClientName, N'Initial term review due (' + a.AgreementRef + N')',
           N'Initial 3-month term ends ' + CONVERT(nvarchar(11), dbo.fn_InitialTermEnd(a.AgreementId), 106) + N'. Review whether the level of support is right, then usp_Agreement_RecordReview.',
           CAST(dbo.fn_InitialTermEnd(a.AgreementId) AS datetime2(0))
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE a.InitialReviewDoneDate IS NULL AND a.EndDate IS NULL AND DATEADD(day, -@ReviewDays, dbo.fn_InitialTermEnd(a.AgreementId)) <= @Today;

    INSERT #A
    SELECT 2, 'Agreement', c.ClientName, N'Agreement ending ' + CONVERT(nvarchar(11), a.EndDate, 106) + N' (' + a.AgreementRef + N')',
           N'Notice given by ' + a.NoticeGivenBy + N' on ' + CONVERT(nvarchar(11), a.NoticeGivenDate, 106) + N'. Arrange access removal and uninstall of Molehill Watch if requested.',
           CAST(a.EndDate AS datetime2(0))
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE a.EndDate BETWEEN @Today AND DATEADD(day, 45, @Today);

    INSERT #A
    SELECT 3, 'Agreement', c.ClientName, N'Price change takes effect ' + CONVERT(nvarchar(11), pc.EffectiveDate, 106), N'New price list: ' + p.Name + N' (notified ' + CONVERT(nvarchar(11), pc.NotifiedDate, 106) + N').', CAST(pc.EffectiveDate AS datetime2(0))
    FROM dbo.PriceChange pc JOIN dbo.PriceList p ON p.PriceListId = pc.NewPriceListId JOIN dbo.Agreement a ON a.AgreementId = pc.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE pc.EffectiveDate BETWEEN @Today AND DATEADD(day, 45, @Today);

    -- Versions
    INSERT #A
    SELECT CASE WHEN i.UnsupportedRiskAcceptedDate IS NULL THEN 1 ELSE 3 END, 'Version', c.ClientName,
           i.InstanceName + N' runs unsupported SQL Server ' + i.SqlVersion,
           CASE WHEN i.UnsupportedRiskAcceptedDate IS NULL THEN N'No risk acceptance recorded - obtain it (usp_Instance_RecordRiskAcceptance) and recommend an upgrade.'
                ELSE N'Risk accepted by ' + i.UnsupportedRiskAcceptedBy + N'. Upgrade project opportunity.' END, NULL
    FROM dbo.Instance i JOIN dbo.ProductLifecycle l ON l.VersionKey = i.SqlVersion
    JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE i.CoveredTo IS NULL AND l.ExtendedEnd < @Today AND (a.EndDate IS NULL OR a.EndDate >= @Today);

    INSERT #A
    SELECT 3, 'Version', c.ClientName, i.InstanceName + N': SQL Server ' + i.SqlVersion + N' support ends ' + CONVERT(nvarchar(11), l.ExtendedEnd, 106),
           N'Recommend an upgrade (quote as project work).', CAST(l.ExtendedEnd AS datetime2(0))
    FROM dbo.Instance i JOIN dbo.ProductLifecycle l ON l.VersionKey = i.SqlVersion
    JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE i.CoveredTo IS NULL AND l.ExtendedEnd BETWEEN @Today AND DATEADD(month, 12, @Today) AND (a.EndDate IS NULL OR a.EndDate >= @Today);

    -- Included hours
    INSERT #A
    SELECT 3, 'Usage', c.ClientName, N'Included hours ' + FORMAT(u.Used, 'N2') + N' of ' + FORMAT(p.IncludedHoursPerCycle, 'N2') + N' used',
           N'Billing cycle ' + CONVERT(nvarchar(11), u.CycleStart, 106) + N' - ' + CONVERT(nvarchar(11), u.CycleEnd, 106) + N'. Further business-hours work is chargeable.', NULL
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    CROSS APPLY (SELECT CycleStart = dbo.fn_CycleStart(a.StartDate, dbo.fn_CycleNumberForDate(a.StartDate, @Today)),
                        CycleEnd = DATEADD(day, -1, dbo.fn_CycleStart(a.StartDate, dbo.fn_CycleNumberForDate(a.StartDate, @Today) + 1))) cy
    CROSS APPLY (SELECT Used = ISNULL(SUM(e.Minutes), 0) / 60.0, cy.CycleStart, cy.CycleEnd
                 FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId
                 WHERE t.AgreementId = a.AgreementId AND e.IsBillable = 1 AND e.RateType = 'BusinessHours' AND t.WorkType <> 'Project'
                   AND CAST(e.WorkStart AS date) BETWEEN cy.CycleStart AND cy.CycleEnd) u
    JOIN dbo.PriceList p ON p.PriceListId = dbo.fn_PriceListIdOn(a.AgreementId, cy.CycleStart)
    WHERE a.StartDate <= @Today AND (a.EndDate IS NULL OR a.EndDate >= @Today) AND u.Used >= 0.8 * p.IncludedHoursPerCycle;

    -- Housekeeping
    IF (SELECT MAX(HolidayDate) FROM dbo.BankHoliday) < DATEADD(month, 6, @Today)
        INSERT #A VALUES (2, 'Admin', N'', N'Add next year''s bank holidays', N'dbo.BankHoliday runs out soon; SLA due times depend on it (gov.uk/bank-holidays).', NULL);

    SELECT Priority = CASE Priority WHEN 1 THEN 'High' WHEN 2 THEN 'Normal' ELSE 'Low' END, Area, Client, Item, Detail, DueBy
    FROM #A ORDER BY #A.Priority, DueBy, Area, Client;

    IF @AlertsOnly = 1 RETURN;

    -- Open tickets
    SELECT t.TicketRef, c.ClientName, t.Severity, t.Status, t.Title, Instance = i.InstanceName, t.RaisedAt, t.ResponseDueAt, t.FirstResponseAt,
           HoursLogged = CAST(ISNULL((SELECT SUM(Minutes) FROM dbo.TimeEntry e WHERE e.TicketId = t.TicketId), 0) / 60.0 AS decimal(6,2)),
           t.EstimateHours, EstimateApproved = CASE WHEN t.EstimateApprovedAt IS NOT NULL THEN 'Yes' END
    FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    LEFT JOIN dbo.Instance i ON i.InstanceId = t.InstanceId
    WHERE t.Status NOT IN ('Resolved', 'Closed')
    ORDER BY CASE t.Severity WHEN 'Critical' THEN 0 ELSE 1 END, t.ResponseDueAt;

    -- Agreements
    SELECT a.AgreementRef, c.ClientName, a.StartDate, InitialTermEnds = dbo.fn_InitialTermEnd(a.AgreementId),
           Status = CASE WHEN a.EndDate < @Today THEN 'Ended' WHEN a.StartDate > @Today THEN 'Not started'
                         WHEN a.NoticeGivenDate IS NOT NULL THEN 'Notice given' WHEN a.SupportPausedFrom IS NOT NULL THEN 'Paused'
                         WHEN @Today <= dbo.fn_InitialTermEnd(a.AgreementId) THEN 'Initial term' ELSE 'Rolling monthly' END,
           a.EndDate,
           CoveredInstances = (SELECT COUNT(*) FROM dbo.fn_AgreementFees(a.AgreementId, CASE WHEN a.StartDate > @Today THEN a.StartDate ELSE @Today END)),
           MonthlyFee = (SELECT SUM(MonthlyFee) FROM dbo.fn_AgreementFees(a.AgreementId, CASE WHEN a.StartDate > @Today THEN a.StartDate ELSE @Today END)),
           NextCycleStarts = dbo.fn_CycleStart(a.StartDate, dbo.fn_CycleNumberForDate(a.StartDate, @Today) + 1)
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE a.EndDate IS NULL OR a.EndDate >= DATEADD(day, -60, @Today)
    ORDER BY c.ClientName;

    -- Money
    SELECT MonthlyRecurringRevenue = ISNULL((SELECT SUM(f.MonthlyFee) FROM dbo.Agreement a CROSS APPLY dbo.fn_AgreementFees(a.AgreementId, @Today) f
                                             WHERE a.StartDate <= @Today AND (a.EndDate IS NULL OR a.EndDate >= @Today)), 0),
           DraftInvoicesTotal = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Draft'), 0),
           UnpaidSentTotal    = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Sent'), 0),
           OverdueTotal       = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Sent' AND DueDate < @Today), 0),
           PaidThisYear       = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Paid' AND YEAR(PaidAt) = YEAR(@Today)), 0);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_DashboardHtml
    @Html nvarchar(max) = NULL OUTPUT,
    @Select bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    CREATE TABLE #alerts (Priority varchar(10), Area varchar(20), Client nvarchar(200), Item nvarchar(300), Detail nvarchar(1000), DueBy datetime2(0));
    INSERT #alerts EXEC dbo.usp_Dashboard @AlertsOnly = 1;

    DECLARE @Now datetime2(0) = dbo.fn_UkNow();
    DECLARE @Rows nvarchar(max) = (
        SELECT STRING_AGG(CONVERT(nvarchar(max),
                   N'<tr><td class="' + LOWER(Priority) + N'">' + Priority + N'</td><td>' + Area + N'</td><td>' + dbo.fn_Html(Client) + N'</td><td><strong>'
                 + dbo.fn_Html(Item) + N'</strong><br />' + dbo.fn_Html(Detail) + N'</td></tr>'), N'')
               WITHIN GROUP (ORDER BY CASE Priority WHEN 'High' THEN 1 WHEN 'Normal' THEN 2 ELSE 3 END, DueBy)
        FROM #alerts);

    DECLARE @Tickets nvarchar(max) = (
        SELECT STRING_AGG(CONVERT(nvarchar(max),
                   N'<tr><td>' + t.TicketRef + N'</td><td>' + dbo.fn_Html(c.ClientName) + N'</td><td class="' + CASE WHEN t.Severity = 'Critical' THEN N'high' ELSE N'' END + N'">' + t.Severity
                 + N'</td><td>' + dbo.fn_Html(t.Title) + N'</td><td>' + t.Status + N'</td><td>' + FORMAT(t.ResponseDueAt, 'ddd dd MMM HH:mm')
                 + CASE WHEN t.FirstResponseAt IS NULL AND t.ResponseDueAt < @Now THEN N' <strong>OVERDUE</strong>' WHEN t.FirstResponseAt IS NOT NULL THEN N' (responded)' ELSE N'' END + N'</td></tr>'), N'')
               WITHIN GROUP (ORDER BY t.ResponseDueAt)
        FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
        WHERE t.Status NOT IN ('Resolved', 'Closed'));

    SET @Html = N'<html><head><meta charset="utf-8" /><title>Molehill Watch - Daily dashboard</title><style>
body{margin:0;background:#F4F2F1;font-family:"Segoe UI",Arial,sans-serif;color:#231F20;font-size:14px;line-height:1.5}
.wrap{max-width:1000px;margin:0 auto;padding:24px}.hero{background:#231F20;color:#fff;padding:24px 30px}
.brand{font-size:26px;font-weight:700}.tag{color:#44C8F5}.meta{color:#BFBBBA;font-size:13px;margin-top:10px}
h2{font-size:18px;border-bottom:3px solid #44C8F5;padding-bottom:6px;margin:30px 0 12px}
table{width:100%;border-collapse:collapse;background:#fff;font-size:13px}th{background:#231F20;color:#fff;text-align:left;padding:8px 10px}
td{padding:7px 10px;border-bottom:1px solid #E2DEDD;vertical-align:top}td.high{background:#D64545;color:#fff;font-weight:600}
td.normal{background:#F9D58C;font-weight:600}td.low{background:#DDF3FC}.ok{background:#D5EEDD}
</style></head><body><div class="wrap"><div class="hero"><div class="brand">Molehill Watch</div><div class="tag">Daily dashboard</div>
<div class="meta">' + dbo.fn_Html(dbo.fn_Setting('BusinessName')) + N' &#183; ' + FORMAT(@Now, 'dddd dd MMMM yyyy HH:mm') + N' (UK)</div></div>
<h2>To do</h2><table><tr><th>Priority</th><th>Area</th><th>Client</th><th>Item</th></tr>' + ISNULL(@Rows, N'<tr><td class="ok" colspan="4">Nothing needs attention today.</td></tr>') + N'</table>
<h2>Open tickets</h2><table><tr><th>Ticket</th><th>Client</th><th>Severity</th><th>Title</th><th>Status</th><th>Response due</th></tr>'
        + ISNULL(@Tickets, N'<tr><td colspan="6">No open tickets.</td></tr>') + N'</table></div></body></html>';

    IF @Select = 1 SELECT Html = @Html;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Daily
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_Billing_Run;

    DECLARE @Profile sysname = NULLIF(dbo.fn_Setting('AlertEmailProfile'), N''), @To nvarchar(1000) = NULLIF(dbo.fn_Setting('AlertEmailRecipients'), N'');
    IF @Profile IS NOT NULL AND @To IS NOT NULL AND CONVERT(int, SERVERPROPERTY('EngineEdition')) <> 4
    BEGIN
        DECLARE @Html nvarchar(max);
        EXEC dbo.usp_DashboardHtml @Html = @Html OUTPUT, @Select = 0;
        DECLARE @Subject nvarchar(200) = N'Molehill Watch dashboard - ' + FORMAT(dbo.fn_UkNow(), 'ddd dd MMM yyyy');
        EXEC msdb.dbo.sp_send_dbmail @profile_name = @Profile, @recipients = @To, @subject = @Subject, @body = @Html, @body_format = 'HTML';
    END
END
GO

INSERT dbo.InstallHistory (Version) VALUES ('1.2.0');   -- bump with every schema change: Molehill Manager offers the upgrade
PRINT N'Molehill Admin 1.2.0 installed.';
GO
