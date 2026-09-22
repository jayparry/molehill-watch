/*
===============================================================================
 Molehill Watch - SQL Server Support Package
 Molehill Admin: clients, engagements, tickets, time and billing  Version 2.2.0
 Molehill Data Services  -  jay@jayparry.co.uk  -  molehilldataservices.com
-------------------------------------------------------------------------------
 Runs on YOUR OWN SQL Server (Express is fine), not on client servers.
 Requires SQL Server 2017 or later.

 Everything the business invoices hangs off an ENGAGEMENT:
   * Monitoring  - a Molehill Watch support agreement, billed on its own cycle
                   (fees in advance, support in arrears) as set out below
   * Consultancy - project or advisory work for a client, billed at an agreed
                   day rate (or hourly, or a fixed price) every two weeks from
                   the day the work started
 A client can have any number of both. Each engagement is invoiced separately;
 free-text invoices cover anything that fits neither.

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
    Notes        nvarchar(max) NULL,
    CreatedAt    datetime2(0)  NOT NULL CONSTRAINT DF_Client_CreatedAt DEFAULT SYSDATETIME());

IF OBJECT_ID(N'dbo.Contact') IS NULL
CREATE TABLE dbo.Contact (
    ContactId        int IDENTITY(1,1) CONSTRAINT PK_Contact PRIMARY KEY,
    ClientId         int           NOT NULL CONSTRAINT FK_Contact_Client REFERENCES dbo.Client (ClientId),
    FullName         nvarchar(200) NOT NULL,
    Email            nvarchar(320) NULL,
    Phone            nvarchar(50)  NULL,
    IsNamedContact   bit           NOT NULL CONSTRAINT DF_Contact_Named DEFAULT 0,   -- raises tickets (named point of contact)
    IsBillingContact bit           NOT NULL CONSTRAINT DF_Contact_Billing DEFAULT 0, -- receives invoices (the only billing setting)
    IsActive         bit           NOT NULL CONSTRAINT DF_Contact_Active DEFAULT 1);

-- 2.0.0: an engagement is anything the business bills a client for. A Molehill Watch
-- support agreement is one kind (details in dbo.Agreement); consultancy work is another.
IF OBJECT_ID(N'dbo.Engagement') IS NULL
CREATE TABLE dbo.Engagement (
    EngagementId   int IDENTITY(1,1) CONSTRAINT PK_Engagement PRIMARY KEY,
    EngagementRef  varchar(30)   NOT NULL CONSTRAINT UQ_Engagement_Ref UNIQUE,
    ClientId       int           NOT NULL CONSTRAINT FK_Engagement_Client REFERENCES dbo.Client (ClientId),
    EngagementType varchar(20)   NOT NULL CONSTRAINT CK_Engagement_Type CHECK (EngagementType IN ('Monitoring', 'Consultancy')),
    Name           nvarchar(200) NOT NULL,
    BillingMode    varchar(20)   NOT NULL CONSTRAINT CK_Engagement_Mode
                   CHECK (BillingMode IN ('AgreementCycle', 'DayRate', 'Hourly', 'FixedPrice')),
    DayRate        decimal(9,2)  NULL,          -- DayRate mode: agreed rate for a full day
    HourlyRate     decimal(9,2)  NULL,          -- Hourly mode
    OutOfHoursRate decimal(9,2)  NULL,          -- optional: hourly rate for out-of-hours consultancy
    FixedPrice     decimal(10,2) NULL,          -- FixedPrice mode: invoiced when the work is marked complete
    DayRounding    varchar(10)   NULL CONSTRAINT CK_Engagement_Rounding CHECK (DayRounding IN ('HalfDay', 'WholeDay', 'Exact')),
    PurchaseOrder  nvarchar(100) NULL,          -- client PO number, printed on the invoice
    Status         varchar(15)   NOT NULL CONSTRAINT DF_Engagement_Status DEFAULT 'Active'
                   CONSTRAINT CK_Engagement_Status CHECK (Status IN ('Active', 'OnHold', 'Completed', 'Cancelled')),
    StartDate      date          NULL,
    EndDate        date          NULL,
    CompletedOn    date          NULL,
    Notes          nvarchar(max) NULL,
    CreatedAt      datetime2(0)  NOT NULL CONSTRAINT DF_Engagement_CreatedAt DEFAULT SYSDATETIME(),
    CONSTRAINT CK_Engagement_Rates CHECK (
        (BillingMode = 'DayRate'    AND DayRate    IS NOT NULL) OR
        (BillingMode = 'Hourly'     AND HourlyRate IS NOT NULL) OR
        (BillingMode = 'FixedPrice' AND FixedPrice IS NOT NULL) OR
         BillingMode = 'AgreementCycle'));

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

-- 1.3.0: who receives invoices is set only on contacts. A client-level billing e-mail from an earlier version
-- becomes a contact that receives invoices but doesn't raise tickets (or marks the contact that already has it).
IF COL_LENGTH(N'dbo.Client', N'BillingEmail') IS NOT NULL
BEGIN
    EXEC (N'
    UPDATE ct SET IsBillingContact = 1
    FROM dbo.Contact ct JOIN dbo.Client c ON c.ClientId = ct.ClientId
    WHERE ct.IsActive = 1 AND ct.Email = LTRIM(RTRIM(c.BillingEmail));

    DECLARE @m TABLE (ClientId int, Email nvarchar(320), Since date);
    INSERT @m
    SELECT c.ClientId, LTRIM(RTRIM(c.BillingEmail)), CAST(c.CreatedAt AS date) FROM dbo.Client c
    WHERE NULLIF(LTRIM(RTRIM(c.BillingEmail)), N'''') IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM dbo.Contact ct WHERE ct.ClientId = c.ClientId AND ct.IsActive = 1 AND ct.Email = LTRIM(RTRIM(c.BillingEmail)));

    DECLARE @new TABLE (ContactId int, ClientId int);
    INSERT dbo.Contact (ClientId, FullName, Email, IsNamedContact, IsBillingContact)
    OUTPUT inserted.ContactId, inserted.ClientId INTO @new
    SELECT m.ClientId,
           CASE WHEN EXISTS (SELECT 1 FROM dbo.Contact x WHERE x.ClientId = m.ClientId AND x.FullName = N''Accounts'') THEN N''Accounts (billing)'' ELSE N''Accounts'' END,
           m.Email, 0, 1
    FROM @m m;
    INSERT dbo.ContactPeriod (ContactId, StartDate) SELECT n.ContactId, m.Since FROM @new n JOIN @m m ON m.ClientId = n.ClientId;
    IF @@ROWCOUNT > 0 PRINT N''Billing e-mails moved to contacts that receive invoices (called Accounts).'';

    ALTER TABLE dbo.Client DROP COLUMN BillingEmail;');
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
    ClientId    int           NOT NULL CONSTRAINT FK_Invoice_Client REFERENCES dbo.Client (ClientId),
    EngagementId int          NULL CONSTRAINT FK_Invoice_Engagement REFERENCES dbo.Engagement (EngagementId),  -- NULL = a free-text invoice for the client
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
    LineType       varchar(20)   NOT NULL CONSTRAINT CK_InvoiceLine_Type CHECK (LineType IN ('MonthlyFee', 'BusinessHours', 'OutOfHours', 'Project', 'Adjustment', 'Info', 'PrepaidPurchase', 'PrepaidDrawn', 'Consultancy', 'FixedFee', 'Other')),
    BillingCycleId int           NULL,
    WorkDate       date          NULL,          -- consultancy lines: the day the work was done
    RateType       varchar(20)   NULL,          -- consultancy lines: BusinessHours | OutOfHours
    InstanceId     int           NULL,
    TicketId       int           NULL,
    Description    nvarchar(500) NOT NULL,
    Quantity       decimal(9,2)  NOT NULL,
    UnitPrice      decimal(9,2)  NOT NULL,
    Amount         decimal(10,2) NOT NULL);

IF OBJECT_ID(N'dbo.TimeEntry') IS NULL
CREATE TABLE dbo.TimeEntry (
    TimeEntryId  int IDENTITY(1,1) CONSTRAINT PK_TimeEntry PRIMARY KEY,
    EngagementId int          NOT NULL CONSTRAINT FK_TimeEntry_Engagement REFERENCES dbo.Engagement (EngagementId),
    TicketId    int           NULL CONSTRAINT FK_TimeEntry_Ticket REFERENCES dbo.Ticket (TicketId),
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

-- 1.4.0: pre-paid support hours, bought as an add-on at a negotiated rate.
-- They cover business-hours support only; out-of-hours work is always billed at the out-of-hours rate.
IF OBJECT_ID(N'dbo.PrepaidPackage') IS NULL
CREATE TABLE dbo.PrepaidPackage (
    PackageId       int IDENTITY(1,1) CONSTRAINT PK_PrepaidPackage PRIMARY KEY,
    PackageRef      AS ('PH-' + RIGHT('0000' + CONVERT(varchar(10), PackageId), 4)) PERSISTED,
    AgreementId     int           NOT NULL CONSTRAINT FK_PrepaidPackage_Agreement REFERENCES dbo.Agreement (AgreementId),
    PurchasedOn     date          NOT NULL,
    Hours           decimal(7,2)  NOT NULL CONSTRAINT CK_PrepaidPackage_Hours CHECK (Hours > 0),
    HourlyRate      decimal(9,2)  NOT NULL CONSTRAINT CK_PrepaidPackage_Rate CHECK (HourlyRate >= 0),
    Price           AS (CAST(Hours * HourlyRate AS decimal(10,2))) PERSISTED,
    StartsOn        date          NOT NULL,      -- first day the hours can be used
    ExpiresOn       date          NULL,          -- last day they can be used; NULL = no expiry
    InvoiceId       int           NULL CONSTRAINT FK_PrepaidPackage_Invoice REFERENCES dbo.Invoice (InvoiceId),
    Status          varchar(10)   NOT NULL CONSTRAINT DF_PrepaidPackage_Status DEFAULT 'Active'
                    CONSTRAINT CK_PrepaidPackage_Status CHECK (Status IN ('Active', 'Cancelled')),
    Notes           nvarchar(1000) NULL,
    CreatedAt       datetime2(0)  NOT NULL CONSTRAINT DF_PrepaidPackage_CreatedAt DEFAULT SYSDATETIME(),
    CONSTRAINT CK_PrepaidPackage_Dates CHECK (ExpiresOn IS NULL OR ExpiresOn >= StartsOn));

-- 1.4.1: packages never cover out-of-hours work (1.4.0 had an optional ratio)
IF COL_LENGTH(N'dbo.PrepaidPackage', N'OutOfHoursRatio') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'dbo.CK_PrepaidPackage_Ooh') IS NOT NULL ALTER TABLE dbo.PrepaidPackage DROP CONSTRAINT CK_PrepaidPackage_Ooh;
    ALTER TABLE dbo.PrepaidPackage DROP COLUMN OutOfHoursRatio;
END

-- hours taken from a package by an arrears invoice (voiding that invoice gives them back)
IF OBJECT_ID(N'dbo.PrepaidUsage') IS NULL
CREATE TABLE dbo.PrepaidUsage (
    UsageId        int IDENTITY(1,1) CONSTRAINT PK_PrepaidUsage PRIMARY KEY,
    PackageId      int          NOT NULL CONSTRAINT FK_PrepaidUsage_Package REFERENCES dbo.PrepaidPackage (PackageId),
    InvoiceId      int          NOT NULL CONSTRAINT FK_PrepaidUsage_Invoice REFERENCES dbo.Invoice (InvoiceId),
    BillingCycleId int          NULL,
    TicketId       int          NULL CONSTRAINT FK_PrepaidUsage_Ticket REFERENCES dbo.Ticket (TicketId),
    RateType       varchar(20)  NOT NULL,        -- always BusinessHours
    WorkedHours    decimal(9,2) NOT NULL,        -- chargeable support time covered
    HoursUsed      decimal(9,2) NOT NULL,        -- pre-paid hours taken (the same)
    CreatedAt      datetime2(0) NOT NULL CONSTRAINT DF_PrepaidUsage_CreatedAt DEFAULT SYSDATETIME());

-- 1.5.0: each ticket has a rate. Time logged on it is charged at that rate unless the time entry says otherwise.
-- BusinessHours | OutOfHours | ByTimeOfWork (each time entry rated by when the work was done)
IF COL_LENGTH(N'dbo.Ticket', N'RateType') IS NULL
BEGIN
    ALTER TABLE dbo.Ticket ADD RateType varchar(20) NOT NULL CONSTRAINT DF_Ticket_RateType DEFAULT 'BusinessHours'
        CONSTRAINT CK_Ticket_RateType CHECK (RateType IN ('BusinessHours', 'OutOfHours', 'ByTimeOfWork'));
    -- tickets from before keep the old behaviour: rated by the time of work (planned out-of-hours work: out of hours)
    EXEC (N'UPDATE dbo.Ticket SET RateType = CASE WHEN WorkType = ''PlannedOutOfHours'' THEN ''OutOfHours'' ELSE ''ByTimeOfWork'' END;');
END

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_InvoiceLine_Type' AND definition NOT LIKE N'%Consultancy%')
BEGIN
    ALTER TABLE dbo.InvoiceLine DROP CONSTRAINT CK_InvoiceLine_Type;
    ALTER TABLE dbo.InvoiceLine ADD CONSTRAINT CK_InvoiceLine_Type
        CHECK (LineType IN ('MonthlyFee', 'BusinessHours', 'OutOfHours', 'Project', 'Adjustment', 'Info', 'PrepaidPurchase', 'PrepaidDrawn', 'Consultancy', 'FixedFee', 'Other'));
END

/*---------------------------------------------------------------------------
  2.0.0: engagements. Databases from 1.x hang everything off the agreement;
  from here an agreement is one kind of engagement and invoices, time and
  billing hang off the engagement instead. Existing data is moved across.
---------------------------------------------------------------------------*/
IF COL_LENGTH(N'dbo.Agreement', N'EngagementId') IS NULL
    ALTER TABLE dbo.Agreement ADD EngagementId int NULL CONSTRAINT FK_Agreement_Engagement REFERENCES dbo.Engagement (EngagementId);

IF COL_LENGTH(N'dbo.InvoiceLine', N'WorkDate') IS NULL
    ALTER TABLE dbo.InvoiceLine ADD WorkDate date NULL;

IF COL_LENGTH(N'dbo.InvoiceLine', N'RateType') IS NULL
    ALTER TABLE dbo.InvoiceLine ADD RateType varchar(20) NULL;

IF COL_LENGTH(N'dbo.InvoiceLine', N'EngagementId') IS NULL
    ALTER TABLE dbo.InvoiceLine ADD EngagementId int NULL CONSTRAINT FK_InvoiceLine_Engagement REFERENCES dbo.Engagement (EngagementId);

IF COL_LENGTH(N'dbo.Invoice', N'ClientId') IS NULL
    ALTER TABLE dbo.Invoice ADD ClientId int NULL CONSTRAINT FK_Invoice_Client REFERENCES dbo.Client (ClientId),
                                EngagementId int NULL CONSTRAINT FK_Invoice_Engagement REFERENCES dbo.Engagement (EngagementId);

IF COL_LENGTH(N'dbo.TimeEntry', N'EngagementId') IS NULL
    ALTER TABLE dbo.TimeEntry ADD EngagementId int NULL CONSTRAINT FK_TimeEntry_Engagement REFERENCES dbo.Engagement (EngagementId);
GO

-- every agreement becomes a monitoring engagement, keeping its own reference
INSERT dbo.Engagement (EngagementRef, ClientId, EngagementType, Name, BillingMode, Status, StartDate, EndDate)
SELECT a.AgreementRef, a.ClientId, 'Monitoring', N'Molehill Watch SQL Server support', 'AgreementCycle',
       CASE WHEN a.EndDate IS NOT NULL AND a.EndDate < CAST(SYSDATETIME() AS date) THEN 'Completed' ELSE 'Active' END,
       a.StartDate, a.EndDate
FROM dbo.Agreement a
WHERE a.EngagementId IS NULL AND NOT EXISTS (SELECT 1 FROM dbo.Engagement e WHERE e.EngagementRef = a.AgreementRef);

UPDATE a SET a.EngagementId = e.EngagementId
FROM dbo.Agreement a JOIN dbo.Engagement e ON e.EngagementRef = a.AgreementRef
WHERE a.EngagementId IS NULL;
GO

-- invoices and time move from the agreement to its engagement
IF COL_LENGTH(N'dbo.Invoice', N'AgreementId') IS NOT NULL
    EXEC(N'UPDATE i SET i.ClientId = a.ClientId, i.EngagementId = a.EngagementId
           FROM dbo.Invoice i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId WHERE i.ClientId IS NULL;');

UPDATE e SET e.EngagementId = a.EngagementId
FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId
WHERE e.EngagementId IS NULL;
GO

IF COL_LENGTH(N'dbo.Invoice', N'AgreementId') IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Invoice WHERE ClientId IS NULL)
BEGIN
    DECLARE @fk sysname = (SELECT name FROM sys.foreign_keys WHERE parent_object_id = OBJECT_ID(N'dbo.Invoice') AND name LIKE N'FK_Invoice_Agreement%');
    IF @fk IS NOT NULL EXEC(N'ALTER TABLE dbo.Invoice DROP CONSTRAINT ' + @fk);
    ALTER TABLE dbo.Invoice DROP COLUMN AgreementId;
    PRINT N'Invoices moved from agreements to engagements.';
END
GO

-- once everything is across, the new links are required
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.Agreement') AND name = N'EngagementId' AND is_nullable = 1)
   AND NOT EXISTS (SELECT 1 FROM dbo.Agreement WHERE EngagementId IS NULL)
BEGIN
    ALTER TABLE dbo.Agreement ALTER COLUMN EngagementId int NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'UQ_Agreement_Engagement' AND object_id = OBJECT_ID(N'dbo.Agreement'))
        CREATE UNIQUE INDEX UQ_Agreement_Engagement ON dbo.Agreement (EngagementId);
END

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.Invoice') AND name = N'ClientId' AND is_nullable = 1)
   AND NOT EXISTS (SELECT 1 FROM dbo.Invoice WHERE ClientId IS NULL)
    ALTER TABLE dbo.Invoice ALTER COLUMN ClientId int NOT NULL;

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.TimeEntry') AND name = N'EngagementId' AND is_nullable = 1)
   AND NOT EXISTS (SELECT 1 FROM dbo.TimeEntry WHERE EngagementId IS NULL)
    ALTER TABLE dbo.TimeEntry ALTER COLUMN EngagementId int NOT NULL;

-- consultancy time has no ticket
IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.TimeEntry') AND name = N'TicketId' AND is_nullable = 0)
    ALTER TABLE dbo.TimeEntry ALTER COLUMN TicketId int NULL;
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
    ('DayHours',            N'7.5',                            N'Hours in a consultancy day. Used to turn logged time into days and back.'),
    ('ConsultancyBillingDays', N'14',                          N'How often consultancy work is invoiced, counted from the engagement''s start date. 14 = every two weeks.'),
    ('DayRateRounding',     N'HalfDay',                        N'How a day-rate engagement rounds each day worked: HalfDay, WholeDay or Exact.'),
    ('ConsultancyRefPrefix',N'CON',                            N'Consultancy engagement references look like CON-0001.'),
    ('CombineInvoicesPerClient', N'0',                         N'0 = one invoice per engagement (recommended). 1 = one invoice per client per run.'),
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

-- Work is only ever billed if it falls inside one of the agreement's billing cycles: from the start date,
-- and not after the agreement ends. Anything outside that is never invoiced.
CREATE OR ALTER FUNCTION dbo.fn_IsBillablePeriod (@AgreementId int, @WorkStart datetime2(0))
RETURNS bit
AS
BEGIN
    DECLARE @Start date, @End date;
    SELECT @Start = StartDate, @End = EndDate FROM dbo.Agreement WHERE AgreementId = @AgreementId;
    IF @Start IS NULL RETURN 0;
    RETURN CASE WHEN CAST(@WorkStart AS date) >= @Start AND (@End IS NULL OR CAST(@WorkStart AS date) <= @End) THEN 1 ELSE 0 END;
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

-- hours in a consultancy day, and how each day worked is rounded
CREATE OR ALTER FUNCTION dbo.fn_DayHours ()
RETURNS decimal(5,2)
AS
BEGIN
    RETURN ISNULL(NULLIF(TRY_CONVERT(decimal(5,2), dbo.fn_Setting('DayHours')), 0), 7.5);
END
GO

CREATE OR ALTER FUNCTION dbo.fn_DaysWorked (@Minutes int, @Rounding varchar(10))
RETURNS decimal(9,2)
AS
BEGIN
    DECLARE @Exact decimal(18,6) = @Minutes / 60.0 / dbo.fn_DayHours();
    SET @Rounding = ISNULL(@Rounding, NULLIF(dbo.fn_Setting('DayRateRounding'), N''));
    RETURN CASE @Rounding
             WHEN 'Exact'    THEN CAST(@Exact AS decimal(9,2))
             WHEN 'WholeDay' THEN CAST(CEILING(@Exact) AS decimal(9,2))
             ELSE CAST(CEILING(@Exact * 2) / 2.0 AS decimal(9,2))   -- HalfDay
           END;
END
GO

-- consultancy billing periods: fixed-length runs of days from the engagement's start
-- date (a fortnight by default). Work dated before the start belongs to the first one.
CREATE OR ALTER FUNCTION dbo.fn_ConsultancyBillingDays ()
RETURNS int
AS
BEGIN
    RETURN ISNULL(NULLIF(TRY_CONVERT(int, dbo.fn_Setting('ConsultancyBillingDays')), 0), 14);
END
GO

CREATE OR ALTER FUNCTION dbo.fn_ConsultancyPeriod (@StartDate date, @WorkDate date)
RETURNS int
AS
BEGIN
    RETURN CASE WHEN @WorkDate <= @StartDate THEN 0
                ELSE DATEDIFF(day, @StartDate, @WorkDate) / dbo.fn_ConsultancyBillingDays() END;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_ConsultancyPeriodStart (@StartDate date, @Period int)
RETURNS date
AS
BEGIN
    RETURN DATEADD(day, @Period * dbo.fn_ConsultancyBillingDays(), @StartDate);
END
GO

-- consultancy work, a line per day worked (out-of-hours work on its own line when
-- the engagement has an out-of-hours rate). Quantity is days, or hours when billed hourly.
CREATE OR ALTER FUNCTION dbo.fn_ConsultancyWork (@EngagementId int, @UnbilledOnly bit)
RETURNS TABLE
AS
RETURN
    SELECT EngagementId = e.EngagementId,
           WorkDate     = CAST(te.WorkStart AS date),
           te.RateType,
           Minutes      = SUM(te.Minutes),
           Hours        = CAST(SUM(te.Minutes) / 60.0 AS decimal(9,2)),
           Days         = dbo.fn_DaysWorked(SUM(te.Minutes), e.DayRounding),
           Unit         = CASE WHEN e.BillingMode = 'Hourly' OR (te.RateType = 'OutOfHours' AND e.OutOfHoursRate IS NOT NULL) THEN 'hour' ELSE 'day' END,
           Quantity     = CASE WHEN e.BillingMode = 'Hourly' OR (te.RateType = 'OutOfHours' AND e.OutOfHoursRate IS NOT NULL)
                               THEN CAST(SUM(te.Minutes) / 60.0 AS decimal(9,2))
                               ELSE dbo.fn_DaysWorked(SUM(te.Minutes), e.DayRounding) END,
           UnitPrice    = CASE WHEN te.RateType = 'OutOfHours' AND e.OutOfHoursRate IS NOT NULL THEN e.OutOfHoursRate
                               WHEN e.BillingMode = 'Hourly' THEN e.HourlyRate
                               ELSE ISNULL(e.DayRate, 0) END,
           WorkDone     = STRING_AGG(CONVERT(nvarchar(max), te.Description), N'; ') WITHIN GROUP (ORDER BY te.WorkStart)
    FROM dbo.Engagement e
    JOIN dbo.TimeEntry te ON te.EngagementId = e.EngagementId
    WHERE e.EngagementId = @EngagementId AND te.IsBillable = 1 AND (@UnbilledOnly = 0 OR te.InvoiceId IS NULL)
    GROUP BY e.EngagementId, CAST(te.WorkStart AS date), te.RateType, e.DayRounding, e.BillingMode, e.OutOfHoursRate, e.HourlyRate, e.DayRate;
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
  3b. VIEWS
=============================================================================*/
GO
-- every invoice with who it is for and what it is for (agreement columns are
-- NULL for consultancy and free-text invoices)
CREATE OR ALTER VIEW dbo.vw_Invoice
AS
SELECT i.InvoiceId, i.InvoiceNo, i.InvoiceDate, i.DueDate, i.SubTotal, i.VatRatePct, i.VatAmount, i.Total,
       i.Status, i.SentAt, i.PaidAt, i.Notes, i.CreatedAt,
       i.ClientId, c.ClientName,
       i.EngagementId, e.EngagementRef, e.EngagementType, EngagementName = e.Name, e.PurchaseOrder,
       a.AgreementId, a.AgreementRef, a.SupportPausedFrom
FROM dbo.Invoice i
JOIN dbo.Client c ON c.ClientId = i.ClientId
LEFT JOIN dbo.Engagement e ON e.EngagementId = i.EngagementId
LEFT JOIN dbo.Agreement a ON a.EngagementId = i.EngagementId;
GO

/*=============================================================================
  4. CLIENTS, AGREEMENTS AND INSTANCES
=============================================================================*/
-- Who receives invoices is set on contacts (usp_Contact_Add @IsBillingContact = 1), not on the client.
CREATE OR ALTER PROCEDURE dbo.usp_Client_Add
    @ClientName   nvarchar(200),
    @Address      nvarchar(500) = NULL,
    @Notes        nvarchar(max) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM dbo.Client WHERE ClientName = @ClientName)
    BEGIN
        UPDATE dbo.Client SET Address = ISNULL(@Address, Address), Notes = ISNULL(@Notes, Notes)
        WHERE ClientName = @ClientName;
        PRINT N'Updated client ' + @ClientName;
    END
    ELSE
    BEGIN
        INSERT dbo.Client (ClientName, Address, Notes) VALUES (@ClientName, @Address, @Notes);
        PRINT N'Added client ' + @ClientName + N'. Add contacts next: who raises tickets, and who receives invoices.';
    END
END
GO

CREATE OR ALTER FUNCTION dbo.fn_ClientId (@Client nvarchar(200))   -- client name, agreement ref or engagement ref
RETURNS int
AS
BEGIN
    RETURN COALESCE((SELECT ClientId FROM dbo.Client WHERE ClientName = @Client),
                    (SELECT ClientId FROM dbo.Agreement WHERE AgreementRef = @Client),
                    (SELECT ClientId FROM dbo.Engagement WHERE EngagementRef = @Client));
END
GO

-- engagement ref, agreement ref, or a client name when that client has exactly one engagement
CREATE OR ALTER FUNCTION dbo.fn_EngagementId (@Engagement nvarchar(200))
RETURNS int
AS
BEGIN
    RETURN COALESCE(
        (SELECT EngagementId FROM dbo.Engagement WHERE EngagementRef = @Engagement),
        (SELECT EngagementId FROM dbo.Agreement WHERE AgreementRef = @Engagement),
        (SELECT MIN(e.EngagementId) FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId
         WHERE c.ClientName = @Engagement AND e.Status IN ('Active', 'OnHold')
         HAVING COUNT(*) = 1));
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
    @IsNamedContact   bit = NULL,               -- raises tickets. NULL = no (new contact) / unchanged (someone being re-added)
    @IsBillingContact bit = NULL,               -- receives invoices (e.g. a shared accounts@ address with tickets off)
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
        PRINT N'WARNING: ' + @Name + N' was the only contact receiving invoices. Add another (a shared accounts address can be a contact that only receives invoices).';
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
           RaisesTickets = CASE WHEN ct.IsNamedContact = 1 THEN 'Yes' ELSE '' END,
           ReceivesInvoices = CASE WHEN ct.IsBillingContact = 1 THEN 'Yes' ELSE '' END,
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
    -- the agreement is a monitoring engagement; both share one reference
    DECLARE @TempRef varchar(30) = ISNULL(@AgreementRef, 'TMP-' + LEFT(CONVERT(varchar(36), NEWID()), 20));
    INSERT dbo.Engagement (EngagementRef, ClientId, EngagementType, Name, BillingMode, Status, StartDate)
    VALUES (@TempRef, @ClientId, 'Monitoring', N'Molehill Watch SQL Server support', 'AgreementCycle', 'Active', @StartDate);
    DECLARE @EngagementId int = SCOPE_IDENTITY();

    INSERT dbo.Agreement (AgreementRef, ClientId, EngagementId, SignedDate, StartDate, InitialTermMonths, PriceListId, TicketChannel)
    SELECT @TempRef, @ClientId, @EngagementId, @SignedDate, @StartDate, InitialTermMonths, @PriceListId, @TicketChannel
    FROM dbo.PriceList WHERE PriceListId = @PriceListId;
    DECLARE @AgreementId int = SCOPE_IDENTITY();
    IF @AgreementRef IS NULL
    BEGIN
        DECLARE @NewRef varchar(30) = 'MWA-' + RIGHT('0000' + CONVERT(varchar(10), @AgreementId), 4);
        UPDATE dbo.Agreement SET AgreementRef = @NewRef WHERE AgreementId = @AgreementId;
        UPDATE dbo.Engagement SET EngagementRef = @NewRef WHERE EngagementId = @EngagementId;
    END

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
  4b. ENGAGEMENTS (CONSULTANCY AND OTHER BILLABLE WORK)
=============================================================================*/
CREATE OR ALTER PROCEDURE dbo.usp_Engagement_Add
    @Client         nvarchar(200),               -- client name
    @Name           nvarchar(200),               -- what the work is, e.g. 'Data warehouse migration'
    @BillingMode    varchar(20)   = 'DayRate',   -- DayRate | Hourly | FixedPrice
    @DayRate        decimal(9,2)  = NULL,        -- agreed day rate
    @HourlyRate     decimal(9,2)  = NULL,        -- Hourly mode
    @OutOfHoursRate decimal(9,2)  = NULL,        -- optional hourly rate for out-of-hours work
    @FixedPrice     decimal(10,2) = NULL,        -- FixedPrice mode
    @StartDate      date          = NULL,
    @EndDate        date          = NULL,
    @PurchaseOrder  nvarchar(100) = NULL,        -- the client's PO number, printed on invoices
    @DayRounding    varchar(10)   = NULL,        -- HalfDay (default) | WholeDay | Exact
    @Notes          nvarchar(max) = NULL,
    @EngagementRef  varchar(30)   = NULL         -- default CON-0001 style
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = dbo.fn_ClientId(@Client);
    IF @ClientId IS NULL BEGIN RAISERROR(N'Client "%s" not found. Run usp_Client_Add first.', 16, 1, @Client); RETURN; END
    IF @BillingMode NOT IN ('DayRate', 'Hourly', 'FixedPrice')
    BEGIN
        RAISERROR(N'@BillingMode must be DayRate, Hourly or FixedPrice. A Molehill Watch support agreement is set up with usp_Agreement_Create instead.', 16, 1);
        RETURN;
    END
    IF @BillingMode = 'DayRate'    AND ISNULL(@DayRate, 0)    <= 0 BEGIN RAISERROR(N'A day-rate engagement needs @DayRate.', 16, 1); RETURN; END
    IF @BillingMode = 'Hourly'     AND ISNULL(@HourlyRate, 0) <= 0 BEGIN RAISERROR(N'An hourly engagement needs @HourlyRate.', 16, 1); RETURN; END
    IF @BillingMode = 'FixedPrice' AND ISNULL(@FixedPrice, 0) <= 0 BEGIN RAISERROR(N'A fixed-price engagement needs @FixedPrice.', 16, 1); RETURN; END
    IF @DayRounding IS NOT NULL AND @DayRounding NOT IN ('HalfDay', 'WholeDay', 'Exact')
    BEGIN RAISERROR(N'@DayRounding must be HalfDay, WholeDay or Exact.', 16, 1); RETURN; END

    DECLARE @Prefix varchar(10) = ISNULL(NULLIF(dbo.fn_Setting('ConsultancyRefPrefix'), N''), 'CON');
    IF @EngagementRef IS NULL
    BEGIN
        DECLARE @Seq int = ISNULL((SELECT MAX(TRY_CONVERT(int, RIGHT(EngagementRef, 4))) FROM dbo.Engagement WHERE EngagementRef LIKE @Prefix + '-%'), 0) + 1;
        SET @EngagementRef = @Prefix + '-' + RIGHT('0000' + CONVERT(varchar(10), @Seq), 4);
    END
    IF EXISTS (SELECT 1 FROM dbo.Engagement WHERE EngagementRef = @EngagementRef)
    BEGIN RAISERROR(N'Engagement %s already exists.', 16, 1, @EngagementRef); RETURN; END

    INSERT dbo.Engagement (EngagementRef, ClientId, EngagementType, Name, BillingMode, DayRate, HourlyRate, OutOfHoursRate,
                           FixedPrice, DayRounding, PurchaseOrder, Status, StartDate, EndDate, Notes)
    VALUES (@EngagementRef, @ClientId, 'Consultancy', @Name, @BillingMode, @DayRate, @HourlyRate, @OutOfHoursRate,
            @FixedPrice, @DayRounding, @PurchaseOrder, 'Active', ISNULL(@StartDate, CAST(dbo.fn_UkNow() AS date)), @EndDate, @Notes);

    PRINT N'Engagement ' + @EngagementRef + N' created. Log work with usp_Work_Log, then usp_Billing_Run invoices it '
        + CASE WHEN @BillingMode = 'FixedPrice' THEN N'when you mark it complete (usp_Engagement_Complete).' ELSE N'at the end of each month.' END;

    SELECT e.EngagementRef, c.ClientName, e.Name, e.BillingMode,
           Rate = CASE e.BillingMode WHEN 'DayRate' THEN NCHAR(163) + FORMAT(e.DayRate, 'N2') + N'/day'
                                     WHEN 'Hourly'  THEN NCHAR(163) + FORMAT(e.HourlyRate, 'N2') + N'/hour'
                                     ELSE NCHAR(163) + FORMAT(e.FixedPrice, 'N2') + N' fixed' END,
           e.OutOfHoursRate, e.Status, e.StartDate, e.EndDate, e.PurchaseOrder
    FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId WHERE e.EngagementRef = @EngagementRef;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Engagement_Update       -- NULL = leave as it is
    @Engagement     nvarchar(200),
    @Name           nvarchar(200) = NULL,
    @DayRate        decimal(9,2)  = NULL,
    @HourlyRate     decimal(9,2)  = NULL,
    @OutOfHoursRate decimal(9,2)  = NULL,
    @FixedPrice     decimal(10,2) = NULL,
    @StartDate      date          = NULL,
    @EndDate        date          = NULL,
    @PurchaseOrder  nvarchar(100) = NULL,
    @DayRounding    varchar(10)   = NULL,
    @Notes          nvarchar(max) = NULL,
    @Status         varchar(15)   = NULL         -- Active | OnHold
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Id int = dbo.fn_EngagementId(@Engagement);
    IF @Id IS NULL BEGIN RAISERROR(N'Engagement "%s" not found.', 16, 1, @Engagement); RETURN; END
    IF (SELECT EngagementType FROM dbo.Engagement WHERE EngagementId = @Id) = 'Monitoring'
    BEGIN RAISERROR(N'That is a Molehill Watch agreement - change it with the agreement procedures (usp_PriceChange_Schedule, usp_Notice_Give).', 16, 1); RETURN; END
    IF @Status IS NOT NULL AND @Status NOT IN ('Active', 'OnHold')
    BEGIN RAISERROR(N'@Status must be Active or OnHold (use usp_Engagement_Complete or usp_Engagement_Cancel to finish it).', 16, 1); RETURN; END
    IF @DayRounding IS NOT NULL AND @DayRounding NOT IN ('HalfDay', 'WholeDay', 'Exact')
    BEGIN RAISERROR(N'@DayRounding must be HalfDay, WholeDay or Exact.', 16, 1); RETURN; END

    UPDATE dbo.Engagement
    SET Name = ISNULL(NULLIF(LTRIM(RTRIM(@Name)), N''), Name),
        DayRate = ISNULL(@DayRate, DayRate), HourlyRate = ISNULL(@HourlyRate, HourlyRate),
        OutOfHoursRate = ISNULL(@OutOfHoursRate, OutOfHoursRate), FixedPrice = ISNULL(@FixedPrice, FixedPrice),
        StartDate = ISNULL(@StartDate, StartDate), EndDate = ISNULL(@EndDate, EndDate),
        PurchaseOrder = ISNULL(@PurchaseOrder, PurchaseOrder), DayRounding = ISNULL(@DayRounding, DayRounding),
        Notes = ISNULL(@Notes, Notes), Status = ISNULL(@Status, Status)
    WHERE EngagementId = @Id;

    IF (@DayRate IS NOT NULL OR @HourlyRate IS NOT NULL OR @OutOfHoursRate IS NOT NULL)
       AND EXISTS (SELECT 1 FROM dbo.TimeEntry WHERE EngagementId = @Id AND InvoiceId IS NULL AND IsBillable = 1)
        PRINT N'Note: the new rate applies to all time that has not been invoiced yet, including work already logged.';

    EXEC dbo.usp_Engagement_Show @Engagement = @Engagement;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Engagement_Complete
    @Engagement  nvarchar(200),
    @CompletedOn date = NULL        -- default: the engagement's end date, or today if it has none
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Id int = dbo.fn_EngagementId(@Engagement);
    IF @Id IS NULL BEGIN RAISERROR(N'Engagement "%s" not found.', 16, 1, @Engagement); RETURN; END
    DECLARE @Type varchar(20), @End date;
    SELECT @Type = EngagementType, @End = EndDate FROM dbo.Engagement WHERE EngagementId = @Id;
    IF @Type = 'Monitoring'
    BEGIN RAISERROR(N'A Molehill Watch agreement ends by giving notice (usp_Notice_Give).', 16, 1); RETURN; END
    DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
    SET @CompletedOn = COALESCE(@CompletedOn, @End, @Today);
    IF @CompletedOn > @Today
        PRINT N'Note: finished on ' + CONVERT(nvarchar(11), @CompletedOn, 106) + N' (the end date on the engagement), which is in the future - its invoice will be dated then too.';
    UPDATE dbo.Engagement SET Status = 'Completed', CompletedOn = @CompletedOn, EndDate = ISNULL(EndDate, @CompletedOn) WHERE EngagementId = @Id;
    PRINT N'Engagement marked complete. The next billing run invoices whatever is outstanding.';
    EXEC dbo.usp_Engagement_Show @Engagement = @Engagement;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Engagement_Cancel
    @Engagement nvarchar(200),
    @Reason     nvarchar(500) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Id int = dbo.fn_EngagementId(@Engagement);
    IF @Id IS NULL BEGIN RAISERROR(N'Engagement "%s" not found.', 16, 1, @Engagement); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.Invoice WHERE EngagementId = @Id AND Status <> 'Void')
    BEGIN RAISERROR(N'This engagement has been invoiced, so it cannot be cancelled. Mark it complete instead (usp_Engagement_Complete).', 16, 1); RETURN; END
    UPDATE dbo.Engagement SET Status = 'Cancelled', Notes = ISNULL(Notes + NCHAR(10), N'') + N'Cancelled: ' + ISNULL(@Reason, N'no reason given') WHERE EngagementId = @Id;
    PRINT N'Engagement cancelled. Any time logged against it will not be invoiced.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Engagement_Show
    @Engagement nvarchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Id int = dbo.fn_EngagementId(@Engagement);
    IF @Id IS NULL BEGIN RAISERROR(N'Engagement "%s" not found.', 16, 1, @Engagement); RETURN; END

    SELECT e.EngagementRef, c.ClientName, e.EngagementType, e.Name, e.BillingMode,
           Rate = CASE e.BillingMode WHEN 'DayRate' THEN NCHAR(163) + FORMAT(e.DayRate, 'N2') + N'/day'
                                     WHEN 'Hourly'  THEN NCHAR(163) + FORMAT(e.HourlyRate, 'N2') + N'/hour'
                                     WHEN 'FixedPrice' THEN NCHAR(163) + FORMAT(e.FixedPrice, 'N2') + N' fixed'
                                     ELSE N'per the agreement' END,
           OutOfHours = CASE WHEN e.OutOfHoursRate IS NULL THEN N'at the day rate' ELSE NCHAR(163) + FORMAT(e.OutOfHoursRate, 'N2') + N'/hour' END,
           e.Status, e.StartDate, e.EndDate, e.CompletedOn, e.PurchaseOrder,
           DayRounding = ISNULL(e.DayRounding, dbo.fn_Setting('DayRateRounding')),
           BillingPeriod = CASE WHEN e.BillingMode = 'FixedPrice' THEN N'on completion'
                                ELSE N'every ' + CONVERT(nvarchar(10), dbo.fn_ConsultancyBillingDays()) + N' days from '
                                     + CONVERT(nvarchar(11), e.StartDate, 106) END,
           NextInvoiceOn = CASE WHEN e.BillingMode <> 'FixedPrice' AND e.Status IN ('Active', 'OnHold')
                                THEN DATEADD(day, -1, dbo.fn_ConsultancyPeriodStart(e.StartDate,
                                     dbo.fn_ConsultancyPeriod(e.StartDate, CAST(dbo.fn_UkNow() AS date)) + 1)) END,
           e.Notes
    FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId WHERE e.EngagementId = @Id;

    SELECT Worked = FORMAT(ISNULL(SUM(w.Days), 0), 'N2') + N' days',
           Unbilled = FORMAT(ISNULL(SUM(CASE WHEN u.WorkDate IS NOT NULL THEN u.Days END), 0), 'N2') + N' days',
           UnbilledValue = NCHAR(163) + FORMAT(ISNULL(SUM(CASE WHEN u.WorkDate IS NOT NULL THEN u.Quantity * u.UnitPrice END), 0), 'N2'),
           Invoiced = NCHAR(163) + FORMAT(ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE EngagementId = @Id AND Status <> 'Void'), 0), 'N2'),
           LastWorked = MAX(w.WorkDate)
    FROM dbo.fn_ConsultancyWork(@Id, 0) w
    LEFT JOIN dbo.fn_ConsultancyWork(@Id, 1) u ON u.WorkDate = w.WorkDate AND u.RateType = w.RateType;

    SELECT w.WorkDate, w.RateType, w.Days, w.Hours, Charge = NCHAR(163) + FORMAT(w.Quantity * w.UnitPrice, 'N2'),
           Billed = CASE WHEN EXISTS (SELECT 1 FROM dbo.TimeEntry te WHERE te.EngagementId = @Id AND CAST(te.WorkStart AS date) = w.WorkDate AND te.RateType = w.RateType AND te.InvoiceId IS NULL AND te.IsBillable = 1)
                         THEN N'not yet' ELSE N'invoiced' END,
           w.WorkDone
    FROM dbo.fn_ConsultancyWork(@Id, 0) w ORDER BY w.WorkDate DESC, w.RateType;

    SELECT i.InvoiceNo, i.InvoiceDate, i.DueDate, i.Total, i.Status
    FROM dbo.Invoice i WHERE i.EngagementId = @Id ORDER BY i.InvoiceNo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Engagement_List
    @Client        nvarchar(200) = NULL,     -- NULL = every client
    @IncludeClosed bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = CASE WHEN @Client IS NOT NULL THEN dbo.fn_ClientId(@Client) END;
    IF @Client IS NOT NULL AND @ClientId IS NULL BEGIN RAISERROR(N'Client "%s" not found.', 16, 1, @Client); RETURN; END

    SELECT e.EngagementRef, c.ClientName, e.EngagementType, e.Name, e.Status,
           Rate = CASE e.BillingMode WHEN 'DayRate' THEN NCHAR(163) + FORMAT(e.DayRate, 'N0') + N'/day'
                                     WHEN 'Hourly'  THEN NCHAR(163) + FORMAT(e.HourlyRate, 'N0') + N'/hour'
                                     WHEN 'FixedPrice' THEN NCHAR(163) + FORMAT(e.FixedPrice, 'N0') + N' fixed'
                                     ELSE N'agreement' END,
           UnbilledDays  = ISNULL(u.Days, 0),
           UnbilledValue = ISNULL(u.Value, 0),
           LastWorked    = u.LastWorked,
           Invoiced      = ISNULL((SELECT SUM(Total) FROM dbo.Invoice i WHERE i.EngagementId = e.EngagementId AND i.Status <> 'Void'), 0),
           e.PurchaseOrder
    FROM dbo.Engagement e
    JOIN dbo.Client c ON c.ClientId = e.ClientId
    OUTER APPLY (SELECT Days = SUM(w.Days), Value = SUM(w.Quantity * w.UnitPrice), LastWorked = MAX(w.WorkDate)
                 FROM dbo.fn_ConsultancyWork(e.EngagementId, 1) w) u
    WHERE (@ClientId IS NULL OR e.ClientId = @ClientId)
      AND (@IncludeClosed = 1 OR e.Status IN ('Active', 'OnHold'))
    ORDER BY c.ClientName, CASE e.EngagementType WHEN 'Monitoring' THEN 0 ELSE 1 END, e.EngagementRef;
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
        UPDATE e SET e.EndDate = @EndDate FROM dbo.Engagement e JOIN dbo.Agreement a ON a.EngagementId = e.EngagementId WHERE a.AgreementId = @AgreementId;

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
    @WorkType     varchar(20)   = 'Support', -- Support | PlannedOutOfHours | Project
    @RateType     varchar(20)   = NULL       -- BusinessHours | OutOfHours | ByTimeOfWork; default: out of hours for planned
                                             -- out-of-hours work, otherwise business hours
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

    SET @RateType = ISNULL(@RateType, CASE WHEN @WorkType = 'PlannedOutOfHours' THEN 'OutOfHours' ELSE 'BusinessHours' END);
    IF @RateType NOT IN ('BusinessHours', 'OutOfHours', 'ByTimeOfWork')
    BEGIN RAISERROR(N'@RateType must be BusinessHours, OutOfHours or ByTimeOfWork.', 16, 1); RETURN; END

    INSERT dbo.Ticket (AgreementId, InstanceId, ContactId, Severity, WorkType, Title, Description, Channel, RaisedAt, ResponseDueAt, Status, RateType)
    VALUES (@AgreementId, @InstanceId, @ContactId, @Severity, @WorkType, @Title, @Description, @Channel, @RaisedAt,
            dbo.fn_ResponseDue(@RaisedAt, @Severity), 'Open', @RateType);
    IF @RateType = 'OutOfHours' PRINT N'Time on this ticket is charged at the out-of-hours rate.';
    ELSE IF @RateType = 'ByTimeOfWork' PRINT N'Time on this ticket is charged by when the work is done (out of hours outside Mon-Fri 09:00-17:30).';
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
    DECLARE @TicketId int, @AgreementId int, @WorkType varchar(20), @EstApproved datetime2(0), @EstHours decimal(6,2), @TicketRate varchar(20);
    SELECT @TicketId = TicketId, @AgreementId = AgreementId, @WorkType = WorkType, @EstApproved = EstimateApprovedAt, @EstHours = EstimateHours, @TicketRate = RateType
    FROM dbo.Ticket WHERE TicketRef = @TicketRef;
    IF @TicketId IS NULL BEGIN RAISERROR(N'Ticket %s not found.', 16, 1, @TicketRef); RETURN; END

    SET @WorkStart = ISNULL(@WorkStart, DATEADD(minute, -@Minutes, dbo.fn_UkNow()));
    -- the entry's own rate if given, else the ticket's; "by time of work" decides from when the work was done
    SET @RateType = ISNULL(@RateType, CASE WHEN @TicketRate <> 'ByTimeOfWork' THEN @TicketRate
                                           WHEN @WorkType = 'PlannedOutOfHours' OR dbo.fn_IsBusinessHours(@WorkStart) = 0 THEN 'OutOfHours'
                                           ELSE 'BusinessHours' END);
    IF @RateType NOT IN ('BusinessHours', 'OutOfHours') BEGIN RAISERROR(N'@RateType must be BusinessHours or OutOfHours.', 16, 1); RETURN; END

    DECLARE @TicketEngagementId int = (SELECT EngagementId FROM dbo.Agreement WHERE AgreementId = @AgreementId);
    INSERT dbo.TimeEntry (EngagementId, TicketId, WorkStart, Minutes, RateType, Description, IsBillable)
    VALUES (@TicketEngagementId, @TicketId, @WorkStart, @Minutes, @RateType, @Description, @IsBillable);

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
        PRINT N'Logged as OUT OF HOURS (GBP ' + ISNULL(@OohRate, N'?') + N'/h). Pass @RateType = ''BusinessHours'' if that is wrong, or change the ticket''s rate (usp_Ticket_SetRate).';
    END

    IF dbo.fn_IsBillablePeriod(@AgreementId, @WorkStart) = 0
    BEGIN
        DECLARE @AgStart date, @AgEnd date;
        SELECT @AgStart = StartDate, @AgEnd = EndDate FROM dbo.Agreement WHERE AgreementId = @AgreementId;
        PRINT N'WARNING: this time is dated ' + CONVERT(nvarchar(11), @WorkStart, 106) + N', outside the agreement''s billing period ('
            + CONVERT(nvarchar(11), @AgStart, 106) + ISNULL(N' to ' + CONVERT(nvarchar(11), @AgEnd, 106), N' onwards')
            + N'). It will NEVER be invoiced and will not use included or pre-paid hours. Correct the date with usp_Time_Update.';
    END
    ELSE IF CAST(@WorkStart AS date) > CAST(dbo.fn_UkNow() AS date)
        PRINT N'Note: this time is dated in the future, so it is billed in a later cycle.';

    EXEC dbo.usp_Agreement_Usage @Client = NULL, @AgreementId = @AgreementId, @AsOfDate = @WorkStart;
END
GO

-- Correct a time entry that has not been invoiced. NULL = leave as it is.
CREATE OR ALTER PROCEDURE dbo.usp_Time_Update
    @TimeEntryId int,
    @WorkStart   datetime2(0)  = NULL,
    @Minutes     int           = NULL,
    @Description nvarchar(1000) = NULL,
    @RateType    varchar(20)   = NULL,       -- BusinessHours | OutOfHours
    @IsBillable  bit           = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TicketId int, @InvoiceId int, @AgreementId int, @Ref varchar(30), @Found bit = 0;
    SELECT @TicketId = e.TicketId, @InvoiceId = e.InvoiceId, @AgreementId = t.AgreementId,
           @Ref = ISNULL(t.TicketRef, g.EngagementRef), @Found = 1
    FROM dbo.TimeEntry e
    LEFT JOIN dbo.Ticket t ON t.TicketId = e.TicketId
    LEFT JOIN dbo.Engagement g ON g.EngagementId = e.EngagementId
    WHERE e.TimeEntryId = @TimeEntryId;
    IF @Found = 0 BEGIN RAISERROR(N'Time entry %d not found.', 16, 1, @TimeEntryId); RETURN; END
    IF @InvoiceId IS NOT NULL
    BEGIN
        DECLARE @No varchar(30) = (SELECT InvoiceNo FROM dbo.Invoice WHERE InvoiceId = @InvoiceId);
        RAISERROR(N'This time is already on invoice %s. Void that invoice first (usp_Invoice_SetStatus @Status = ''Void''), then change it.', 16, 1, @No);
        RETURN;
    END
    IF @Minutes IS NOT NULL AND @Minutes <= 0 BEGIN RAISERROR(N'@Minutes must be more than 0 (use usp_Time_Delete to remove the entry).', 16, 1); RETURN; END
    IF @RateType IS NOT NULL AND @RateType NOT IN ('BusinessHours', 'OutOfHours') BEGIN RAISERROR(N'@RateType must be BusinessHours or OutOfHours.', 16, 1); RETURN; END

    UPDATE dbo.TimeEntry
    SET WorkStart = ISNULL(@WorkStart, WorkStart), Minutes = ISNULL(@Minutes, Minutes),
        Description = ISNULL(NULLIF(LTRIM(RTRIM(@Description)), N''), Description),
        RateType = ISNULL(@RateType, RateType), IsBillable = ISNULL(@IsBillable, IsBillable)
    WHERE TimeEntryId = @TimeEntryId;

    DECLARE @NewStart datetime2(0) = (SELECT WorkStart FROM dbo.TimeEntry WHERE TimeEntryId = @TimeEntryId);
    PRINT N'Updated the time on ' + @Ref + N'.';
    IF @AgreementId IS NOT NULL AND dbo.fn_IsBillablePeriod(@AgreementId, @NewStart) = 0
        PRINT N'WARNING: it is still dated outside the agreement''s billing period, so it will never be invoiced.';
    SELECT e.TimeEntryId, Ref = ISNULL(t.TicketRef, g.EngagementRef), e.WorkStart, e.Minutes, e.RateType, e.IsBillable, e.Description
    FROM dbo.TimeEntry e LEFT JOIN dbo.Ticket t ON t.TicketId = e.TicketId LEFT JOIN dbo.Engagement g ON g.EngagementId = e.EngagementId
    WHERE e.TimeEntryId = @TimeEntryId;
END
GO

-- Remove a time entry that has not been invoiced (logged against the wrong ticket, duplicate, and so on).
CREATE OR ALTER PROCEDURE dbo.usp_Time_Delete
    @TimeEntryId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @InvoiceId int, @Ref varchar(30), @Minutes int;
    SELECT @InvoiceId = e.InvoiceId, @Ref = ISNULL(t.TicketRef, g.EngagementRef), @Minutes = e.Minutes
    FROM dbo.TimeEntry e LEFT JOIN dbo.Ticket t ON t.TicketId = e.TicketId LEFT JOIN dbo.Engagement g ON g.EngagementId = e.EngagementId
    WHERE e.TimeEntryId = @TimeEntryId;
    IF @Ref IS NULL BEGIN RAISERROR(N'Time entry %d not found.', 16, 1, @TimeEntryId); RETURN; END
    IF @InvoiceId IS NOT NULL
    BEGIN
        DECLARE @No varchar(30) = (SELECT InvoiceNo FROM dbo.Invoice WHERE InvoiceId = @InvoiceId);
        RAISERROR(N'This time is already on invoice %s. Void that invoice first, then remove it.', 16, 1, @No);
        RETURN;
    END
    DELETE dbo.TimeEntry WHERE TimeEntryId = @TimeEntryId;
    PRINT N'Removed ' + CONVERT(nvarchar(10), @Minutes) + N' minutes from ' + @Ref + N'.';
END
GO

-- Change a ticket's rate; by default its time not yet invoiced is re-rated too.
CREATE OR ALTER PROCEDURE dbo.usp_Ticket_SetRate
    @TicketRef       varchar(20),
    @RateType        varchar(20),               -- BusinessHours | OutOfHours | ByTimeOfWork
    @ApplyToUnbilled bit = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @TicketId int, @WorkType varchar(20);
    SELECT @TicketId = TicketId, @WorkType = WorkType FROM dbo.Ticket WHERE TicketRef = @TicketRef;
    IF @TicketId IS NULL BEGIN RAISERROR(N'Ticket %s not found.', 16, 1, @TicketRef); RETURN; END
    IF @RateType NOT IN ('BusinessHours', 'OutOfHours', 'ByTimeOfWork')
    BEGIN RAISERROR(N'@RateType must be BusinessHours, OutOfHours or ByTimeOfWork.', 16, 1); RETURN; END

    UPDATE dbo.Ticket SET RateType = @RateType WHERE TicketId = @TicketId;
    DECLARE @Changed int = 0, @Invoiced int;
    IF @ApplyToUnbilled = 1
    BEGIN
        UPDATE dbo.TimeEntry
        SET RateType = CASE WHEN @RateType <> 'ByTimeOfWork' THEN @RateType
                            WHEN @WorkType = 'PlannedOutOfHours' OR dbo.fn_IsBusinessHours(WorkStart) = 0 THEN 'OutOfHours' ELSE 'BusinessHours' END
        WHERE TicketId = @TicketId AND InvoiceId IS NULL;
        SET @Changed = @@ROWCOUNT;
    END
    SET @Invoiced = (SELECT COUNT(*) FROM dbo.TimeEntry WHERE TicketId = @TicketId AND InvoiceId IS NOT NULL);
    PRINT @TicketRef + N' is now charged ' + CASE @RateType WHEN 'BusinessHours' THEN N'at the business-hours rate'
                                                             WHEN 'OutOfHours' THEN N'at the out-of-hours rate'
                                                             ELSE N'by when the work is done' END + N'.'
        + CASE WHEN @ApplyToUnbilled = 1 THEN N' ' + CONVERT(nvarchar(10), @Changed) + N' time entr' + CASE WHEN @Changed = 1 THEN N'y' ELSE N'ies' END + N' not yet invoiced re-rated.' ELSE N'' END
        + CASE WHEN @Invoiced > 0 THEN N' ' + CONVERT(nvarchar(10), @Invoiced) + N' already invoiced unchanged (void the invoice to re-bill them).' ELSE N'' END;
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

/*-----------------------------------------------------------------------------
  Consultancy work: logged against the engagement, not a ticket. Give @Days
  (1, 0.5, ...), @Hours or @Minutes - whichever suits.
-----------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_Work_Log
    @Engagement  nvarchar(200),
    @Description nvarchar(1000),
    @Days        decimal(6,2) = NULL,
    @Hours       decimal(6,2) = NULL,
    @Minutes     int          = NULL,
    @WorkDate    date         = NULL,           -- default today
    @RateType    varchar(20)  = 'BusinessHours',-- OutOfHours only matters if the engagement has an out-of-hours rate
    @IsBillable  bit          = 1
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Id int = dbo.fn_EngagementId(@Engagement);
    IF @Id IS NULL BEGIN RAISERROR(N'Engagement "%s" not found. Create it with usp_Engagement_Add.', 16, 1, @Engagement); RETURN; END

    DECLARE @Type varchar(20), @Status varchar(15), @Start date, @End date, @Ref varchar(30), @Mode varchar(20);
    SELECT @Type = EngagementType, @Status = Status, @Start = StartDate, @End = EndDate, @Ref = EngagementRef, @Mode = BillingMode
    FROM dbo.Engagement WHERE EngagementId = @Id;
    IF @Type = 'Monitoring'
    BEGIN RAISERROR(N'That is a Molehill Watch agreement: support time belongs to a ticket (usp_Ticket_Open, then usp_Time_Log).', 16, 1); RETURN; END
    IF @Status = 'Cancelled' BEGIN RAISERROR(N'Engagement %s is cancelled.', 16, 1, @Ref); RETURN; END
    IF @RateType NOT IN ('BusinessHours', 'OutOfHours') BEGIN RAISERROR(N'@RateType must be BusinessHours or OutOfHours.', 16, 1); RETURN; END

    DECLARE @Mins int = COALESCE(@Minutes, CONVERT(int, ROUND(@Hours * 60, 0)), CONVERT(int, ROUND(@Days * dbo.fn_DayHours() * 60, 0)));
    IF ISNULL(@Mins, 0) <= 0 BEGIN RAISERROR(N'Give @Days, @Hours or @Minutes.', 16, 1); RETURN; END
    SET @WorkDate = ISNULL(@WorkDate, CAST(dbo.fn_UkNow() AS date));

    INSERT dbo.TimeEntry (EngagementId, TicketId, WorkStart, Minutes, RateType, Description, IsBillable)
    VALUES (@Id, NULL, DATEADD(hour, 9, CAST(@WorkDate AS datetime2(0))), @Mins, @RateType, @Description, @IsBillable);

    IF @Status = 'Completed' PRINT N'Note: this engagement is marked complete. The next billing run will invoice this time too.';
    IF @Status <> 'Completed' AND @Mode IN ('DayRate', 'Hourly')
    BEGIN
        DECLARE @PerEnd date = DATEADD(day, -1, dbo.fn_ConsultancyPeriodStart(@Start, dbo.fn_ConsultancyPeriod(@Start, @WorkDate) + 1));
        PRINT N'Invoiced after ' + CONVERT(nvarchar(11), @PerEnd, 106) + N' (every '
            + CONVERT(nvarchar(10), dbo.fn_ConsultancyBillingDays()) + N' days from ' + CONVERT(nvarchar(11), @Start, 106) + N').';
    END
    IF @WorkDate < @Start PRINT N'Note: that date is before the engagement started (' + CONVERT(nvarchar(11), @Start, 106) + N').';
    IF @End IS NOT NULL AND @WorkDate > @End PRINT N'Note: that date is after the engagement''s end date (' + CONVERT(nvarchar(11), @End, 106) + N').';
    IF @IsBillable = 0 PRINT N'Logged as non-billable, so it will not appear on an invoice.';

    DECLARE @Rounded nvarchar(20) = (SELECT FORMAT(SUM(w.Days), 'N2') FROM dbo.fn_ConsultancyWork(@Id, 0) w WHERE w.WorkDate = @WorkDate);
    IF @IsBillable = 1 AND @Mode <> 'FixedPrice'
        PRINT N'Logged. ' + CONVERT(nvarchar(11), @WorkDate, 106) + N' now bills as ' + ISNULL(@Rounded, N'0') + N' day(s).';

    SELECT w.WorkDate, w.RateType, w.Hours, BillsAs = FORMAT(w.Quantity, 'N2') + N' ' + w.Unit + N'(s)',
           Charge = NCHAR(163) + FORMAT(w.Quantity * w.UnitPrice, 'N2'), w.WorkDone
    FROM dbo.fn_ConsultancyWork(@Id, 0) w WHERE w.WorkDate = @WorkDate;

    SELECT UnbilledDays = ISNULL(SUM(w.Days), 0), UnbilledValue = ISNULL(SUM(w.Quantity * w.UnitPrice), 0)
    FROM dbo.fn_ConsultancyWork(@Id, 1) w;
END
GO

/*=============================================================================
  7. BILLING
=============================================================================*/
-- Packages on an agreement with what is left, as of a date. State: Active | Used up | Expired | Not started | Cancelled
CREATE OR ALTER FUNCTION dbo.fn_PrepaidPackages (@AgreementId int, @AsOf date)
RETURNS TABLE
AS
RETURN
    SELECT p.PackageId, p.PackageRef, p.AgreementId, p.PurchasedOn, p.Hours, p.HourlyRate, p.Price, p.StartsOn, p.ExpiresOn,
           p.InvoiceId, p.Status, p.Notes,
           Used      = CAST(ISNULL(u.Used, 0) AS decimal(9,2)),
           Remaining = CAST(p.Hours - ISNULL(u.Used, 0) AS decimal(9,2)),
           LastUsed  = u.LastUsed,
           State     = CASE WHEN p.Status = 'Cancelled' THEN 'Cancelled'
                            WHEN p.Hours - ISNULL(u.Used, 0) <= 0 THEN 'Used up'
                            WHEN p.ExpiresOn < @AsOf THEN 'Expired'
                            WHEN p.StartsOn > @AsOf THEN 'Not started'
                            ELSE 'Active' END
    FROM dbo.PrepaidPackage p
    OUTER APPLY (SELECT Used = SUM(x.HoursUsed), LastUsed = MAX(x.CreatedAt) FROM dbo.PrepaidUsage x WHERE x.PackageId = p.PackageId) u
    WHERE p.AgreementId = @AgreementId;
GO

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
           PrepaidHoursLeft = (SELECT CAST(SUM(Remaining) AS decimal(9,2)) FROM dbo.fn_PrepaidPackages(@AgreementId, @AsOfDate) WHERE State IN ('Active', 'Not started')),
           -- billable time not yet on an invoice: included and pre-paid hours are only used when billing runs
           UnbilledHours = (SELECT CAST(ISNULL(SUM(x.Minutes), 0) / 60.0 AS decimal(9,2)) FROM dbo.TimeEntry x JOIN dbo.Ticket y ON y.TicketId = x.TicketId
                            WHERE y.AgreementId = @AgreementId AND y.WorkType <> 'Project' AND x.IsBillable = 1 AND x.InvoiceId IS NULL
                              AND dbo.fn_IsBillablePeriod(y.AgreementId, x.WorkStart) = 1),
           Note = N'Approximate - minimum charges are applied at invoicing. Unused included hours do not roll over.'
    FROM dbo.Ticket t
    LEFT JOIN dbo.TimeEntry e ON e.TicketId = t.TicketId AND e.IsBillable = 1 AND CAST(e.WorkStart AS date) BETWEEN @CycleStart AND @CycleEnd
    WHERE t.AgreementId = @AgreementId AND t.WorkType <> 'Project';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_New
    @InvoiceDate  date,
    @InvoiceId    int OUTPUT,
    @EngagementId int = NULL,          -- NULL = a free-text invoice for the client
    @ClientId     int = NULL           -- taken from the engagement when not given
AS
BEGIN
    SET NOCOUNT ON;
    SET @ClientId = ISNULL(@ClientId, (SELECT ClientId FROM dbo.Engagement WHERE EngagementId = @EngagementId));
    IF @ClientId IS NULL BEGIN RAISERROR(N'An invoice needs a client or an engagement.', 16, 1); RETURN; END
    DECLARE @Prefix varchar(10) = ISNULL(NULLIF(dbo.fn_Setting('InvoicePrefix'), N''), 'INV');
    DECLARE @Year char(4) = CONVERT(char(4), YEAR(@InvoiceDate));
    DECLARE @Seq int = ISNULL((SELECT MAX(TRY_CONVERT(int, RIGHT(InvoiceNo, 4))) FROM dbo.Invoice WHERE InvoiceNo LIKE @Prefix + '-' + @Year + '-%'), 0) + 1;
    INSERT dbo.Invoice (InvoiceNo, ClientId, EngagementId, InvoiceDate, DueDate)
    VALUES (@Prefix + '-' + @Year + '-' + RIGHT('0000' + CONVERT(varchar(10), @Seq), 4), @ClientId, @EngagementId, @InvoiceDate,
            DATEADD(day, ISNULL(TRY_CONVERT(int, dbo.fn_Setting('PaymentTermsDays')), 14), @InvoiceDate));
    SET @InvoiceId = SCOPE_IDENTITY();
END
GO

/*-----------------------------------------------------------------------------
  Pre-paid hours: an add-on package of support hours bought in advance at a
  negotiated rate. Chargeable support (after the month's included hours, with the
  minimum charge applied) is taken from it before anything is billed at the
  standard rates. Soonest-expiring package first.
-----------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_Prepaid_Add
    @Client          nvarchar(200),              -- agreement ref or client name
    @Hours           decimal(7,2),
    @HourlyRate      decimal(9,2),               -- negotiated
    @PurchasedOn     date          = NULL,       -- default today; also the invoice date
    @StartsOn        date          = NULL,       -- default the purchase date
    @ExpiresOn       date          = NULL,       -- last day the hours can be used (or use @ValidMonths); NULL = no expiry
    @ValidMonths     int           = NULL,
    @Notes           nvarchar(1000) = NULL,
    @Invoice         bit           = 1           -- 1 = draft invoice for the package now
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    IF @AgreementId IS NULL BEGIN RAISERROR(N'Agreement or client "%s" not found.', 16, 1, @Client); RETURN; END
    IF ISNULL(@Hours, 0) <= 0 BEGIN RAISERROR(N'Give the number of hours (more than 0).', 16, 1); RETURN; END
    IF @HourlyRate IS NULL OR @HourlyRate < 0 BEGIN RAISERROR(N'Give the agreed hourly rate.', 16, 1); RETURN; END
    IF @ExpiresOn IS NOT NULL AND @ValidMonths IS NOT NULL BEGIN RAISERROR(N'Give @ExpiresOn or @ValidMonths, not both.', 16, 1); RETURN; END
    SET @PurchasedOn = ISNULL(@PurchasedOn, CAST(dbo.fn_UkNow() AS date));
    SET @StartsOn = ISNULL(@StartsOn, @PurchasedOn);
    IF @ValidMonths IS NOT NULL SET @ExpiresOn = DATEADD(day, -1, DATEADD(month, @ValidMonths, @StartsOn));
    IF @ExpiresOn < @StartsOn BEGIN RAISERROR(N'The expiry date is before the hours can be used.', 16, 1); RETURN; END
    DECLARE @End date = (SELECT EndDate FROM dbo.Agreement WHERE AgreementId = @AgreementId);
    IF @End < @StartsOn BEGIN RAISERROR(N'The agreement ends before these hours could be used.', 16, 1); RETURN; END

    DECLARE @PackageId int, @InvoiceId int;
    BEGIN TRAN;
    INSERT dbo.PrepaidPackage (AgreementId, PurchasedOn, Hours, HourlyRate, StartsOn, ExpiresOn, Notes)
    VALUES (@AgreementId, @PurchasedOn, @Hours, @HourlyRate, @StartsOn, @ExpiresOn, NULLIF(LTRIM(RTRIM(@Notes)), N''));
    SET @PackageId = SCOPE_IDENTITY();
    IF @Invoice = 1
    BEGIN
        DECLARE @PkgEngagementId int = (SELECT EngagementId FROM dbo.Agreement WHERE AgreementId = @AgreementId);
        EXEC dbo.usp_Invoice_New @EngagementId = @PkgEngagementId, @InvoiceDate = @PurchasedOn, @InvoiceId = @InvoiceId OUTPUT;
        INSERT dbo.InvoiceLine (InvoiceId, LineType, Description, Quantity, UnitPrice, Amount)
        SELECT @InvoiceId, 'PrepaidPurchase',
               N'Pre-paid support hours (' + PackageRef + N'): ' + FORMAT(Hours, 'N2') + N' h, usable '
               + CASE WHEN ExpiresOn IS NULL THEN N'from ' + CONVERT(nvarchar(11), StartsOn, 106) + N' (no expiry)'
                      ELSE CONVERT(nvarchar(11), StartsOn, 106) + N' - ' + CONVERT(nvarchar(11), ExpiresOn, 106) END
               + N', for business-hours support',
               Hours, HourlyRate, Price
        FROM dbo.PrepaidPackage WHERE PackageId = @PackageId;
        EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
        UPDATE dbo.PrepaidPackage SET InvoiceId = @InvoiceId WHERE PackageId = @PackageId;
    END
    COMMIT;

    DECLARE @Std decimal(9,2) = (SELECT BusinessHoursRate FROM dbo.PriceList WHERE PriceListId = dbo.fn_PriceListIdOn(@AgreementId, @StartsOn));
    DECLARE @Ref varchar(10) = (SELECT PackageRef FROM dbo.PrepaidPackage WHERE PackageId = @PackageId);
    PRINT N'Pre-paid hours ' + @Ref + N': ' + FORMAT(@Hours, 'N2') + N' h at GBP ' + FORMAT(@HourlyRate, 'N2') + N'/h = GBP ' + FORMAT(@Hours * @HourlyRate, 'N2')
        + CASE WHEN @Std > @HourlyRate THEN N' (GBP ' + FORMAT(@Std - @HourlyRate, 'N2') + N'/h below the standard business-hours rate).'
               WHEN @Std IS NOT NULL THEN N'. Note: not below the standard business-hours rate of GBP ' + FORMAT(@Std, 'N2') + N'/h.' ELSE N'.' END;
    IF @InvoiceId IS NOT NULL EXEC dbo.usp_Invoice_Renumber @Year = NULL, @Quiet = 1;   -- keep the numbering in date order
    DECLARE @InvNo varchar(30) = (SELECT InvoiceNo FROM dbo.Invoice WHERE InvoiceId = @InvoiceId);
    IF @Invoice = 1 PRINT N'Draft invoice ' + @InvNo + N' created for the package.';
    ELSE PRINT N'No invoice created (@Invoice = 0): bill it yourself, e.g. with usp_Invoice_Adjust.';

    SELECT p.PackageRef, p.Hours, p.HourlyRate, p.Price, p.StartsOn, p.ExpiresOn, InvoiceNo = i.InvoiceNo
    FROM dbo.PrepaidPackage p LEFT JOIN dbo.Invoice i ON i.InvoiceId = p.InvoiceId WHERE p.PackageId = @PackageId;
END
GO

-- Change the expiry or notes after purchase. NULL = unchanged.
CREATE OR ALTER PROCEDURE dbo.usp_Prepaid_Update
    @PackageRef        varchar(10),
    @ExpiresOn         date         = NULL,
    @NoExpiry          bit          = 0,       -- 1 = remove the expiry date
    @Notes             nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @PackageId int, @StartsOn date, @Status varchar(10);
    SELECT @PackageId = PackageId, @StartsOn = StartsOn, @Status = Status FROM dbo.PrepaidPackage WHERE PackageRef = @PackageRef;
    IF @PackageId IS NULL BEGIN RAISERROR(N'Pre-paid package %s not found.', 16, 1, @PackageRef); RETURN; END
    IF @Status = 'Cancelled' BEGIN RAISERROR(N'%s is cancelled.', 16, 1, @PackageRef); RETURN; END
    IF @ExpiresOn < @StartsOn BEGIN RAISERROR(N'The expiry date is before the hours can be used.', 16, 1); RETURN; END
    UPDATE dbo.PrepaidPackage
    SET ExpiresOn = CASE WHEN @NoExpiry = 1 THEN NULL ELSE ISNULL(@ExpiresOn, ExpiresOn) END,
        Notes = ISNULL(NULLIF(LTRIM(RTRIM(@Notes)), N''), Notes)
    WHERE PackageId = @PackageId;
    PRINT N'Updated ' + @PackageRef + N'. Changes apply to support billed from now on; hours already taken are unchanged.';
    SELECT PackageRef, Hours, Used, Remaining, StartsOn, ExpiresOn, State
    FROM dbo.fn_PrepaidPackages((SELECT AgreementId FROM dbo.PrepaidPackage WHERE PackageId = @PackageId), CAST(dbo.fn_UkNow() AS date))
    WHERE PackageId = @PackageId;
END
GO

-- Cancel a package that hasn't been used. Its invoice is voided if not yet paid.
CREATE OR ALTER PROCEDURE dbo.usp_Prepaid_Cancel
    @PackageRef varchar(10),
    @Reason     nvarchar(400) = NULL
AS
BEGIN
    SET NOCOUNT, XACT_ABORT ON;
    DECLARE @PackageId int, @Status varchar(10), @InvoiceId int;
    SELECT @PackageId = PackageId, @Status = Status, @InvoiceId = InvoiceId FROM dbo.PrepaidPackage WHERE PackageRef = @PackageRef;
    IF @PackageId IS NULL BEGIN RAISERROR(N'Pre-paid package %s not found.', 16, 1, @PackageRef); RETURN; END
    IF @Status = 'Cancelled' BEGIN RAISERROR(N'%s is already cancelled.', 16, 1, @PackageRef); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.PrepaidUsage WHERE PackageId = @PackageId)
    BEGIN RAISERROR(N'Hours from %s have already been used, so it cannot be cancelled. Change its expiry instead, or credit the client with usp_Invoice_Adjust.', 16, 1, @PackageRef); RETURN; END

    DECLARE @InvStatus varchar(10) = (SELECT Status FROM dbo.Invoice WHERE InvoiceId = @InvoiceId);
    UPDATE dbo.PrepaidPackage SET Status = 'Cancelled', Notes = ISNULL(Notes + N' ', N'') + N'Cancelled' + ISNULL(N': ' + @Reason, N'') WHERE PackageId = @PackageId;
    IF @InvStatus IN ('Draft', 'Sent')
    BEGIN
        DECLARE @No varchar(30) = (SELECT InvoiceNo FROM dbo.Invoice WHERE InvoiceId = @InvoiceId);
        EXEC dbo.usp_Invoice_SetStatus @InvoiceNo = @No, @Status = 'Void';
    END
    PRINT N'Cancelled ' + @PackageRef + N'.' + CASE WHEN @InvStatus = 'Paid' THEN N' Its invoice was already paid: refund or credit the client.' ELSE N'' END;
END
GO

-- A client's packages, and where their hours went.
CREATE OR ALTER PROCEDURE dbo.usp_Prepaid_Show
    @Client nvarchar(200)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @AgreementId int = dbo.fn_AgreementId(@Client);
    IF @AgreementId IS NULL BEGIN RAISERROR(N'Agreement or client "%s" not found.', 16, 1, @Client); RETURN; END
    DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
    SELECT p.PackageRef, p.PurchasedOn, p.Hours, p.HourlyRate, p.Price, p.Used, p.Remaining, p.StartsOn, p.ExpiresOn,
           p.State, Invoice = i.InvoiceNo, InvoiceStatus = i.Status, p.Notes
    FROM dbo.fn_PrepaidPackages(@AgreementId, @Today) p LEFT JOIN dbo.Invoice i ON i.InvoiceId = p.InvoiceId
    ORDER BY p.PurchasedOn, p.PackageId;

    SELECT p.PackageRef, Ticket = t.TicketRef, Invoice = i.InvoiceNo, u.RateType, u.WorkedHours, u.HoursUsed, Recorded = u.CreatedAt
    FROM dbo.PrepaidUsage u JOIN dbo.PrepaidPackage p ON p.PackageId = u.PackageId
    JOIN dbo.Invoice i ON i.InvoiceId = u.InvoiceId LEFT JOIN dbo.Ticket t ON t.TicketId = u.TicketId
    WHERE p.AgreementId = @AgreementId ORDER BY u.UsageId;
END
GO

-- Takes chargeable business-hours support from the agreement's packages, hour for hour (used by the arrears invoice).
-- Out-of-hours work never comes from a package.
CREATE OR ALTER PROCEDURE dbo.usp_Prepaid_Draw
    @AgreementId    int,
    @OnDate         date,
    @Hours          decimal(9,4),               -- chargeable business-hours support to cover
    @InvoiceId      int,
    @BillingCycleId int = NULL,
    @TicketId       int = NULL,
    @Covered        decimal(9,4) OUTPUT,        -- hours covered
    @Refs           nvarchar(400) OUTPUT        -- e.g. 'PH-0001 2.00 h'
AS
BEGIN
    SET NOCOUNT ON;
    SELECT @Covered = 0, @Refs = NULL;
    DECLARE @PackageId int, @Ref varchar(10), @Left decimal(9,4), @Take decimal(9,4);
    DECLARE p CURSOR LOCAL FAST_FORWARD FOR
        SELECT PackageId, PackageRef, Remaining
        FROM dbo.fn_PrepaidPackages(@AgreementId, @OnDate)
        WHERE State = 'Active'
        ORDER BY CASE WHEN ExpiresOn IS NULL THEN 1 ELSE 0 END, ExpiresOn, StartsOn, PackageId;
    OPEN p;
    FETCH NEXT FROM p INTO @PackageId, @Ref, @Left;
    WHILE @@FETCH_STATUS = 0 AND ROUND(@Hours - @Covered, 2) > 0
    BEGIN
        SET @Take = ROUND(CASE WHEN @Hours - @Covered < @Left THEN @Hours - @Covered ELSE @Left END, 2);
        IF @Take > 0
        BEGIN
            INSERT dbo.PrepaidUsage (PackageId, InvoiceId, BillingCycleId, TicketId, RateType, WorkedHours, HoursUsed)
            VALUES (@PackageId, @InvoiceId, @BillingCycleId, @TicketId, 'BusinessHours', @Take, @Take);
            SET @Covered = @Covered + @Take;
            SET @Refs = ISNULL(@Refs + N', ', N'') + @Ref + N' ' + FORMAT(@Take, 'N2') + N' h';
        END
        FETCH NEXT FROM p INTO @PackageId, @Ref, @Left;
    END
    CLOSE p; DEALLOCATE p;
    IF @Covered > @Hours SET @Covered = @Hours;
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
    DECLARE @FirstWork datetime2(0), @FromPack decimal(9,4), @PackRefs nvarchar(400), @Billed decimal(9,4);

    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT TicketId, TicketRef, Title, Instance, BhHours, OohHours, FirstWork FROM #tickets ORDER BY FirstWork, TicketId;
    OPEN c;
    FETCH NEXT FROM c INTO @TicketId, @Ref, @Title, @Inst, @Bh, @Ooh, @FirstWork;
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
            -- chargeable time comes out of pre-paid hours first
            SELECT @FromPack = 0, @PackRefs = NULL;
            IF ROUND(@Charged, 2) > 0
                EXEC dbo.usp_Prepaid_Draw @AgreementId = @AgreementId, @OnDate = @FirstWork, @Hours = @Charged,
                     @InvoiceId = @InvoiceId, @BillingCycleId = @BillingCycleId, @TicketId = @TicketId, @Covered = @FromPack OUTPUT, @Refs = @PackRefs OUTPUT;
            SET @Billed = @Charged - @FromPack;
            IF ROUND(@FromPack, 2) > 0
                INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, TicketId, Description, Quantity, UnitPrice, Amount)
                VALUES (@InvoiceId, 'PrepaidDrawn', @BillingCycleId, @TicketId,
                        N'Business-hours support from pre-paid hours: ' + @Label + N' (' + @PackRefs + N')'
                        + CASE WHEN ROUND(@Billed, 2) <= 0 AND ROUND(@Charged, 2) > ROUND(@Bh - @Covered, 2) THEN N', 1 h minimum charge applied' ELSE N'' END,
                        ROUND(@FromPack, 2), 0, 0);
            IF ROUND(@Billed, 2) > 0
                INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, TicketId, Description, Quantity, UnitPrice, Amount)
                VALUES (@InvoiceId, 'BusinessHours', @BillingCycleId, @TicketId,
                        N'Additional business-hours support: ' + @Label + N' - ' + FORMAT(@Bh, 'N2') + N' h worked'
                        + CASE WHEN @Covered > 0 THEN N', ' + FORMAT(@Covered, 'N2') + N' h from included hours' ELSE N'' END
                        + CASE WHEN @FromPack > 0 THEN N', ' + FORMAT(@FromPack, 'N2') + N' h from pre-paid hours' ELSE N'' END
                        + CASE WHEN ROUND(@Charged, 2) > ROUND(@Bh - @Covered, 2) THEN N', 1 h minimum charge applied' ELSE N'' END,
                        ROUND(@Billed, 2), @BhRate, ROUND(ROUND(@Billed, 2) * @BhRate, 2));
        END
        IF @Ooh > 0
        BEGIN
            -- out-of-hours work is always billed at the out-of-hours rate (never from pre-paid hours)
            SET @Charged = CASE WHEN @Ooh < @Min THEN @Min ELSE @Ooh END;
            INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, TicketId, Description, Quantity, UnitPrice, Amount)
            VALUES (@InvoiceId, 'OutOfHours', @BillingCycleId, @TicketId,
                    N'Out-of-hours support: ' + @Label + N' - ' + FORMAT(@Ooh, 'N2') + N' h worked'
                    + CASE WHEN @Ooh < @Min THEN N', 1 h minimum charge applied' ELSE N'' END,
                    ROUND(@Charged, 2), @OohRate, ROUND(ROUND(@Charged, 2) * @OohRate, 2));
        END
        FETCH NEXT FROM c INTO @TicketId, @Ref, @Title, @Inst, @Bh, @Ooh, @FirstWork;
    END
    CLOSE c; DEALLOCATE c;

    IF EXISTS (SELECT 1 FROM #tickets)
        INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, Description, Quantity, UnitPrice, Amount)
        VALUES (@InvoiceId, 'Info', @BillingCycleId,
                N'Included support hours used for ' + @Period + N': ' + FORMAT(@Used + @UsedNow, 'N2') + N' of ' + FORMAT(@Included, 'N2') + N' (unused hours do not roll over)',
                0, 0, 0);

    -- pre-paid hours left, when this invoice took some
    IF EXISTS (SELECT 1 FROM dbo.PrepaidUsage WHERE InvoiceId = @InvoiceId AND BillingCycleId = @BillingCycleId)
        INSERT dbo.InvoiceLine (InvoiceId, LineType, BillingCycleId, Description, Quantity, UnitPrice, Amount)
        SELECT @InvoiceId, 'Info', @BillingCycleId,
               N'Pre-paid hours left: ' + STRING_AGG(PackageRef + N' ' + FORMAT(Remaining, 'N2') + N' h'
                                                    + ISNULL(N' (use by ' + CONVERT(nvarchar(11), ExpiresOn, 106) + N')', N''), N'; ')
                                          WITHIN GROUP (ORDER BY PackageId),
               0, 0, 0
        FROM dbo.fn_PrepaidPackages(@AgreementId, @End)
        WHERE PackageId IN (SELECT PackageId FROM dbo.PrepaidUsage WHERE InvoiceId = @InvoiceId);

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
    @Client   nvarchar(200) = NULL   -- client name (everything they have), or one agreement / engagement ref. NULL = everybody
AS
BEGIN
    SET NOCOUNT ON;
    SET @AsOfDate = ISNULL(@AsOfDate, CAST(dbo.fn_UkNow() AS date));
    DECLARE @OnlyClient int = NULL, @OnlyEng int = NULL;
    IF @Client IS NOT NULL
    BEGIN
        SET @OnlyClient = dbo.fn_ClientId(@Client);
        IF NOT EXISTS (SELECT 1 FROM dbo.Client WHERE ClientName = @Client) SET @OnlyEng = dbo.fn_EngagementId(@Client);
        IF @OnlyClient IS NULL AND @OnlyEng IS NULL
        BEGIN RAISERROR(N'Client, agreement or engagement "%s" not found.', 16, 1, @Client); RETURN; END
    END
    DECLARE @Ags TABLE (AgreementId int PRIMARY KEY);
    INSERT @Ags SELECT a.AgreementId FROM dbo.Agreement a
    WHERE (@OnlyEng IS NULL OR a.EngagementId = @OnlyEng) AND (@OnlyClient IS NULL OR a.ClientId = @OnlyClient);
    DECLARE @Engs TABLE (EngagementId int PRIMARY KEY);
    INSERT @Engs SELECT e.EngagementId FROM dbo.Engagement e
    WHERE e.EngagementType = 'Consultancy' AND e.Status <> 'Cancelled'
      AND (@OnlyEng IS NULL OR e.EngagementId = @OnlyEng) AND (@OnlyClient IS NULL OR e.ClientId = @OnlyClient);
    DECLARE @Created TABLE (InvoiceId int);
    DECLARE @AgreementId int, @Start date, @End date, @n int, @cs date, @ce date, @pl int, @EngId int;

    -- 1. billing cycles
    DECLARE a CURSOR LOCAL FAST_FORWARD FOR SELECT AgreementId, StartDate, EndDate FROM dbo.Agreement
        WHERE StartDate <= @AsOfDate AND AgreementId IN (SELECT AgreementId FROM @Ags);
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
        WHERE FeeInvoiceId IS NULL AND StartDate <= @AsOfDate AND AgreementId IN (SELECT AgreementId FROM @Ags) ORDER BY AgreementId, CycleNumber;
    OPEN cyc;
    FETCH NEXT FROM cyc INTO @CycleId, @AgreementId, @CycleNo, @cs, @ce;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRAN;
        SET @EngId = (SELECT EngagementId FROM dbo.Agreement WHERE AgreementId = @AgreementId);
        EXEC dbo.usp_Invoice_New @EngagementId = @EngId, @InvoiceDate = @cs, @InvoiceId = @InvoiceId OUTPUT;

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
        WHERE bc.EndDate < @AsOfDate AND bc.AgreementId IN (SELECT AgreementId FROM @Ags)
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
            SET @EngId = (SELECT EngagementId FROM dbo.Agreement WHERE AgreementId = @AgreementId);
        EXEC dbo.usp_Invoice_New @EngagementId = @EngId, @InvoiceDate = @cs, @InvoiceId = @InvoiceId OUTPUT;
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

    /*-------------------------------------------------------------------------
      4. consultancy engagements: time invoiced in arrears at the end of each
         billing period - a fortnight from the engagement's start date unless
         ConsultancyBillingDays says otherwise - or as soon as the work is
         marked complete; fixed prices are invoiced on completion.
    -------------------------------------------------------------------------*/
    DECLARE @Eid int, @Mode varchar(20), @Fixed decimal(10,2), @EStatus varchar(15), @EComp date,
            @ERef varchar(30), @EName nvarchar(200), @EStart date, @Period int,
            @PEnd date, @PStart date, @IDate date, @FpDays nvarchar(20);
    DECLARE con CURSOR LOCAL FAST_FORWARD FOR
        SELECT e.EngagementId, e.BillingMode, e.FixedPrice, e.Status, e.CompletedOn, e.EngagementRef, e.Name,
               ISNULL(e.StartDate, (SELECT MIN(CAST(te.WorkStart AS date)) FROM dbo.TimeEntry te WHERE te.EngagementId = e.EngagementId))
        FROM dbo.Engagement e WHERE e.EngagementId IN (SELECT EngagementId FROM @Engs) ORDER BY e.EngagementRef;
    OPEN con;
    FETCH NEXT FROM con INTO @Eid, @Mode, @Fixed, @EStatus, @EComp, @ERef, @EName, @EStart;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF @Mode IN ('DayRate', 'Hourly') AND @EStart IS NOT NULL
        BEGIN
            DECLARE per CURSOR LOCAL FAST_FORWARD FOR
                SELECT DISTINCT dbo.fn_ConsultancyPeriod(@EStart, CAST(te.WorkStart AS date)) FROM dbo.TimeEntry te
                WHERE te.EngagementId = @Eid AND te.IsBillable = 1 AND te.InvoiceId IS NULL ORDER BY 1;
            OPEN per;
            FETCH NEXT FROM per INTO @Period;
            WHILE @@FETCH_STATUS = 0
            BEGIN
                SET @PStart = dbo.fn_ConsultancyPeriodStart(@EStart, @Period);
                SET @PEnd = DATEADD(day, -1, dbo.fn_ConsultancyPeriodStart(@EStart, @Period + 1));
                IF @PEnd <= @AsOfDate OR @EStatus = 'Completed'
                BEGIN
                    SET @IDate = CASE WHEN @PEnd <= @AsOfDate THEN @PEnd ELSE ISNULL(@EComp, @AsOfDate) END;
                    BEGIN TRAN;
                    EXEC dbo.usp_Invoice_New @EngagementId = @Eid, @InvoiceDate = @IDate, @InvoiceId = @InvoiceId OUTPUT;

                    INSERT dbo.InvoiceLine (InvoiceId, LineType, EngagementId, WorkDate, RateType, Description, Quantity, UnitPrice, Amount)
                    SELECT @InvoiceId, 'Consultancy', @Eid, w.WorkDate, w.RateType,
                           CONVERT(nvarchar(11), w.WorkDate, 106) + N' - ' + w.WorkDone
                           + CASE WHEN w.RateType = 'OutOfHours' THEN N' (out of hours)' ELSE N'' END,
                           w.Quantity, w.UnitPrice, CAST(w.Quantity * w.UnitPrice AS decimal(10,2))
                    FROM dbo.fn_ConsultancyWork(@Eid, 1) w
                    WHERE dbo.fn_ConsultancyPeriod(@EStart, w.WorkDate) = @Period
                    ORDER BY w.WorkDate, w.RateType;

                    INSERT dbo.InvoiceLine (InvoiceId, LineType, EngagementId, Description, Quantity, UnitPrice, Amount)
                    VALUES (@InvoiceId, 'Info', @Eid, N'Work done ' + CONVERT(nvarchar(11), @PStart, 106) + N' - '
                            + CONVERT(nvarchar(11), @PEnd, 106) + N' (' + @EName + N')', 0, 0, 0);

                    UPDATE dbo.TimeEntry SET InvoiceId = @InvoiceId
                    WHERE EngagementId = @Eid AND IsBillable = 1 AND InvoiceId IS NULL
                      AND dbo.fn_ConsultancyPeriod(@EStart, CAST(WorkStart AS date)) = @Period;

                    EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
                    COMMIT;
                    INSERT @Created VALUES (@InvoiceId);
                END
                FETCH NEXT FROM per INTO @Period;
            END
            CLOSE per; DEALLOCATE per;
        END
        ELSE IF @Mode = 'FixedPrice' AND @EStatus = 'Completed'
             AND NOT EXISTS (SELECT 1 FROM dbo.Invoice i JOIN dbo.InvoiceLine l ON l.InvoiceId = i.InvoiceId
                             WHERE i.EngagementId = @Eid AND l.LineType = 'FixedFee' AND i.Status <> 'Void')
        BEGIN
            SET @IDate = ISNULL(@EComp, @AsOfDate);
            BEGIN TRAN;
            EXEC dbo.usp_Invoice_New @EngagementId = @Eid, @InvoiceDate = @IDate, @InvoiceId = @InvoiceId OUTPUT;
            INSERT dbo.InvoiceLine (InvoiceId, LineType, EngagementId, Description, Quantity, UnitPrice, Amount)
            VALUES (@InvoiceId, 'FixedFee', @Eid, @EName + N' - agreed fixed price, completed ' + CONVERT(nvarchar(11), @IDate, 106), 1, @Fixed, @Fixed);

            SET @FpDays = (SELECT FORMAT(ISNULL(SUM(w.Days), 0), 'N2') FROM dbo.fn_ConsultancyWork(@Eid, 1) w);
            IF @FpDays <> N'0.00'
                INSERT dbo.InvoiceLine (InvoiceId, LineType, EngagementId, Description, Quantity, UnitPrice, Amount)
                VALUES (@InvoiceId, 'Info', @Eid, N'Work done: ' + @FpDays + N' days, covered by the fixed price', 0, 0, 0);

            UPDATE dbo.TimeEntry SET InvoiceId = @InvoiceId WHERE EngagementId = @Eid AND IsBillable = 1 AND InvoiceId IS NULL;
            EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
            COMMIT;
            INSERT @Created VALUES (@InvoiceId);
        END
        FETCH NEXT FROM con INTO @Eid, @Mode, @Fixed, @EStatus, @EComp, @ERef, @EName, @EStart;
    END
    CLOSE con; DEALLOCATE con;

    -- numbers follow the invoice date, whatever order the run raised them in
    IF EXISTS (SELECT 1 FROM @Created) EXEC dbo.usp_Invoice_Renumber @Quiet = 1;

    SELECT i.InvoiceNo, i.ClientName, Engagement = ISNULL(i.EngagementRef, N'(free-text)'), i.InvoiceDate, i.DueDate,
           i.SubTotal, i.VatAmount, i.Total, i.Status
    FROM @Created x JOIN dbo.vw_Invoice i ON i.InvoiceId = x.InvoiceId
    ORDER BY i.InvoiceDate, i.InvoiceNo;
END
GO

/*-----------------------------------------------------------------------------
  Invoice numbers run in invoice-date order. A billing run can raise invoices
  in any order (support cycles, then each engagement's periods), so once it has
  finished, the drafts are renumbered into date order.

  Anything sent, paid or voided keeps its number for good - those have gone to
  the client, and a voided number is never handed out again. Drafts take the
  numbers left over, in date order, so a client's invoices arrive in sequence.
-----------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_Invoice_Renumber
    @Year  int = NULL,     -- NULL = every year that has a draft invoice
    @Quiet bit = 0         -- 1 = say nothing (the billing run uses this)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Prefix varchar(10) = ISNULL(NULLIF(dbo.fn_Setting('InvoicePrefix'), N''), 'INV');
    DECLARE @Changed TABLE (InvoiceId int PRIMARY KEY, OldNo varchar(30), NewNo varchar(30), InvoiceDate date);

    DECLARE @y int;
    DECLARE yr CURSOR LOCAL FAST_FORWARD FOR
        SELECT DISTINCT YEAR(InvoiceDate) FROM dbo.Invoice
        WHERE Status = 'Draft' AND (@Year IS NULL OR YEAR(InvoiceDate) = @Year);
    OPEN yr;
    FETCH NEXT FROM yr INTO @y;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        DECLARE @Year4 char(4) = CONVERT(char(4), @y);
        DECLARE @Taken TABLE (Seq int PRIMARY KEY);
        DELETE @Taken;
        INSERT @Taken
        SELECT DISTINCT TRY_CONVERT(int, RIGHT(InvoiceNo, 4)) FROM dbo.Invoice
        WHERE Status <> 'Draft' AND InvoiceNo LIKE @Prefix + '-' + @Year4 + '-%' AND TRY_CONVERT(int, RIGHT(InvoiceNo, 4)) IS NOT NULL;

        DECLARE @Drafts int = (SELECT COUNT(*) FROM dbo.Invoice WHERE Status = 'Draft' AND YEAR(InvoiceDate) = @y);
        DECLARE @Need int = @Drafts + (SELECT COUNT(*) FROM @Taken);

        IF OBJECT_ID(N'tempdb..#Map') IS NOT NULL DROP TABLE #Map;
        ;WITH n AS (SELECT TOP (@Need) Seq = ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) FROM sys.all_columns),
              free AS (SELECT Seq, rn = ROW_NUMBER() OVER (ORDER BY Seq) FROM n WHERE Seq NOT IN (SELECT Seq FROM @Taken)),
              d AS (SELECT InvoiceId, InvoiceNo, InvoiceDate, rn = ROW_NUMBER() OVER (ORDER BY InvoiceDate, InvoiceId)
                    FROM dbo.Invoice WHERE Status = 'Draft' AND YEAR(InvoiceDate) = @y)
        SELECT d.InvoiceId, OldNo = d.InvoiceNo, d.InvoiceDate,
               NewNo = @Prefix + '-' + @Year4 + '-' + RIGHT('0000' + CONVERT(varchar(10), f.Seq), 4)
        INTO #Map
        FROM d JOIN free f ON f.rn = d.rn;

        DELETE #Map WHERE OldNo = NewNo;
        IF EXISTS (SELECT 1 FROM #Map)
        BEGIN
            -- park them out of the way first, so swapping two numbers cannot clash
            UPDATE i SET InvoiceNo = 'RENUM-' + CONVERT(varchar(20), i.InvoiceId)
            FROM dbo.Invoice i JOIN #Map m ON m.InvoiceId = i.InvoiceId;
            UPDATE i SET InvoiceNo = m.NewNo
            FROM dbo.Invoice i JOIN #Map m ON m.InvoiceId = i.InvoiceId;
            INSERT @Changed SELECT InvoiceId, OldNo, NewNo, InvoiceDate FROM #Map;
        END
        DROP TABLE #Map;
        FETCH NEXT FROM yr INTO @y;
    END
    CLOSE yr; DEALLOCATE yr;

    IF @Quiet = 1 RETURN;
    IF NOT EXISTS (SELECT 1 FROM @Changed) PRINT N'Invoice numbers are already in date order.';
    SELECT Renumbered = OldNo, NowCalled = NewNo, InvoiceDate FROM @Changed ORDER BY InvoiceDate, NewNo;
END
GO

/*-----------------------------------------------------------------------------
  Invoices you type yourself: anything that is not a monitoring cycle or
  consultancy time - licences bought for a client, a one-off piece of work,
  expenses being re-charged.
-----------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_Invoice_Create
    @Client      nvarchar(200),
    @InvoiceDate date           = NULL,
    @Engagement  nvarchar(200)  = NULL,    -- optional: put it against a piece of work
    @Notes       nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @ClientId int = dbo.fn_ClientId(@Client);
    IF @ClientId IS NULL BEGIN RAISERROR(N'Client "%s" not found.', 16, 1, @Client); RETURN; END
    DECLARE @Eid int = CASE WHEN @Engagement IS NOT NULL THEN dbo.fn_EngagementId(@Engagement) END;
    IF @Engagement IS NOT NULL AND @Eid IS NULL BEGIN RAISERROR(N'Engagement "%s" not found.', 16, 1, @Engagement); RETURN; END
    IF @Eid IS NOT NULL AND (SELECT ClientId FROM dbo.Engagement WHERE EngagementId = @Eid) <> @ClientId
    BEGIN RAISERROR(N'That engagement belongs to a different client.', 16, 1); RETURN; END

    SET @InvoiceDate = ISNULL(@InvoiceDate, CAST(dbo.fn_UkNow() AS date));
    DECLARE @InvoiceId int;
    EXEC dbo.usp_Invoice_New @EngagementId = @Eid, @ClientId = @ClientId, @InvoiceDate = @InvoiceDate, @InvoiceId = @InvoiceId OUTPUT;
    IF @Notes IS NOT NULL UPDATE dbo.Invoice SET Notes = @Notes WHERE InvoiceId = @InvoiceId;

    EXEC dbo.usp_Invoice_Renumber @Year = NULL, @Quiet = 1;   -- keep the numbering in date order
    DECLARE @No varchar(30) = (SELECT InvoiceNo FROM dbo.Invoice WHERE InvoiceId = @InvoiceId);
    PRINT N'Draft invoice ' + @No + N' created. Add lines with usp_Invoice_AddLine, then send it with usp_Invoice_SetStatus.';
    SELECT InvoiceNo, InvoiceDate, DueDate, Total, Status FROM dbo.Invoice WHERE InvoiceId = @InvoiceId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_AddLine
    @InvoiceNo   varchar(30),
    @Description nvarchar(500),
    @Amount      decimal(10,2) = NULL,    -- a single amount, or give @Quantity and @UnitPrice
    @Quantity    decimal(9,2)  = NULL,
    @UnitPrice   decimal(9,2)  = NULL,
    @LineType    varchar(20)   = 'Other'  -- Other | Consultancy | Project | Adjustment | Info
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @InvoiceId int = (SELECT InvoiceId FROM dbo.Invoice WHERE InvoiceNo = @InvoiceNo AND Status = 'Draft');
    IF @InvoiceId IS NULL BEGIN RAISERROR(N'Draft invoice %s not found (only drafts can be changed - and draft numbers shift to stay in invoice-date order, so check the current one).', 16, 1, @InvoiceNo); RETURN; END
    IF @LineType NOT IN ('Other', 'Consultancy', 'Project', 'Adjustment', 'Info', 'FixedFee')
    BEGIN RAISERROR(N'@LineType must be Other, Consultancy, Project, FixedFee, Adjustment or Info.', 16, 1); RETURN; END
    IF @Amount IS NULL AND (@Quantity IS NULL OR @UnitPrice IS NULL)
    BEGIN RAISERROR(N'Give @Amount, or both @Quantity and @UnitPrice.', 16, 1); RETURN; END

    SET @Quantity  = ISNULL(@Quantity, 1);
    SET @UnitPrice = ISNULL(@UnitPrice, @Amount / NULLIF(@Quantity, 0));
    DECLARE @LineAmount decimal(10,2) = CASE WHEN @LineType = 'Info' THEN 0 ELSE CAST(@Quantity * @UnitPrice AS decimal(10,2)) END;

    INSERT dbo.InvoiceLine (InvoiceId, LineType, EngagementId, Description, Quantity, UnitPrice, Amount)
    SELECT @InvoiceId, @LineType, i.EngagementId, @Description, @Quantity, @UnitPrice, @LineAmount
    FROM dbo.Invoice i WHERE i.InvoiceId = @InvoiceId;

    EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
    SELECT l.InvoiceLineId, l.LineType, l.Description, l.Quantity, l.UnitPrice, l.Amount
    FROM dbo.InvoiceLine l WHERE l.InvoiceId = @InvoiceId ORDER BY l.InvoiceLineId;
    SELECT InvoiceNo, SubTotal, VatAmount, Total FROM dbo.Invoice WHERE InvoiceId = @InvoiceId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_RemoveLine
    @InvoiceLineId int
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @InvoiceId int = (SELECT l.InvoiceId FROM dbo.InvoiceLine l JOIN dbo.Invoice i ON i.InvoiceId = l.InvoiceId
                              WHERE l.InvoiceLineId = @InvoiceLineId AND i.Status = 'Draft');
    IF @InvoiceId IS NULL BEGIN RAISERROR(N'Line %d not found on a draft invoice.', 16, 1, @InvoiceLineId); RETURN; END
    IF EXISTS (SELECT 1 FROM dbo.InvoiceLine WHERE InvoiceLineId = @InvoiceLineId
               AND LineType IN ('MonthlyFee', 'BusinessHours', 'OutOfHours', 'PrepaidDrawn', 'PrepaidPurchase', 'Consultancy', 'FixedFee'))
    BEGIN RAISERROR(N'That line was produced by the billing run. Void the invoice instead, correct the time or fees, and run billing again.', 16, 1); RETURN; END
    DELETE dbo.InvoiceLine WHERE InvoiceLineId = @InvoiceLineId;
    EXEC dbo.usp_Invoice_Recalculate @InvoiceId = @InvoiceId;
    SELECT InvoiceNo, SubTotal, VatAmount, Total FROM dbo.Invoice WHERE InvoiceId = @InvoiceId;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_Invoice_Show
    @InvoiceNo varchar(30)
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.Invoice WHERE InvoiceNo = @InvoiceNo)
    BEGIN RAISERROR(N'Invoice %s not found.', 16, 1, @InvoiceNo); RETURN; END
    SELECT i.InvoiceNo, i.ClientName, Engagement = ISNULL(i.EngagementRef, N'(free-text)'), i.EngagementName,
           i.PurchaseOrder, i.InvoiceDate, i.DueDate, i.SubTotal, i.VatAmount, i.Total, i.Status, i.SentAt, i.PaidAt, i.Notes
    FROM dbo.vw_Invoice i WHERE i.InvoiceNo = @InvoiceNo;
    SELECT l.InvoiceLineId, l.LineType, l.WorkDate, l.Description, l.Quantity, l.UnitPrice, l.Amount
    FROM dbo.InvoiceLine l JOIN dbo.Invoice i ON i.InvoiceId = l.InvoiceId
    WHERE i.InvoiceNo = @InvoiceNo ORDER BY l.InvoiceLineId;
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
    IF @InvoiceId IS NULL BEGIN RAISERROR(N'Draft invoice %s not found (only drafts can be changed - and draft numbers shift to stay in invoice-date order, so check the current one).', 16, 1, @InvoiceNo); RETURN; END
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
        WHERE a.ClientId = (SELECT ClientId FROM dbo.Invoice WHERE InvoiceId = @InvoiceId) AND a.SupportPausedFrom IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM dbo.Invoice i WHERE i.ClientId = a.ClientId AND i.Status = 'Sent' AND i.DueDate < @StatusDate);
    END
    ELSE IF @Status = 'Void'
    BEGIN
        -- a pre-paid package's own invoice: the package goes with it, unless its hours are already in use
        IF EXISTS (SELECT 1 FROM dbo.PrepaidPackage p JOIN dbo.PrepaidUsage u ON u.PackageId = p.PackageId WHERE p.InvoiceId = @InvoiceId)
        BEGIN
            DECLARE @UsedRef varchar(10) = (SELECT TOP (1) PackageRef FROM dbo.PrepaidPackage WHERE InvoiceId = @InvoiceId);
            RAISERROR(N'Hours from pre-paid package %s have been used, so its invoice cannot be voided. Credit the client with usp_Invoice_Adjust instead.', 16, 1, @UsedRef);
            RETURN;
        END
        UPDATE dbo.PrepaidPackage SET Status = 'Cancelled' WHERE InvoiceId = @InvoiceId AND Status = 'Active';
        IF @@ROWCOUNT > 0 PRINT N'The pre-paid hours package on this invoice is cancelled.';
        -- pre-paid hours this invoice took are given back
        DELETE dbo.PrepaidUsage WHERE InvoiceId = @InvoiceId;
        -- release time and cycles so a corrected invoice is produced on the next billing run
        UPDATE dbo.TimeEntry SET InvoiceId = NULL WHERE InvoiceId = @InvoiceId;
        UPDATE bc SET IncludedHoursUsed = 0, ArrearsProcessedAt = NULL
        FROM dbo.BillingCycle bc WHERE bc.BillingCycleId IN (SELECT BillingCycleId FROM dbo.InvoiceLine WHERE InvoiceId = @InvoiceId AND LineType IN ('BusinessHours', 'OutOfHours', 'Info', 'PrepaidDrawn'));
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
    DECLARE @InvoiceId int, @EngagementId int, @EngType varchar(20);
    SELECT @InvoiceId = i.InvoiceId, @EngagementId = i.EngagementId, @EngType = e.EngagementType
    FROM dbo.Invoice i LEFT JOIN dbo.Engagement e ON e.EngagementId = i.EngagementId WHERE i.InvoiceNo = @InvoiceNo;
    IF @InvoiceId IS NULL BEGIN RAISERROR(N'Invoice %s not found.', 16, 1, @InvoiceNo); RETURN; END

    -- what the invoice is for: the agreement reference, or the engagement and its PO number
    DECLARE @RefHtml nvarchar(1000) = ISNULL((
        SELECT N'<div class="label" style="margin-top:8px">' + CASE WHEN e.EngagementType = 'Monitoring' THEN N'Agreement' ELSE N'Engagement' END + N'</div>'
             + dbo.fn_Html(e.EngagementRef)
             + CASE WHEN e.EngagementType = 'Consultancy' THEN N'<br /><span style="color:#7A7473">' + dbo.fn_Html(e.Name) + N'</span>' ELSE N'' END
             + ISNULL(N'<div class="label" style="margin-top:8px">Your reference</div>' + dbo.fn_Html(NULLIF(e.PurchaseOrder, N'')), N'')
        FROM dbo.Engagement e WHERE e.EngagementId = @EngagementId), N'');

    DECLARE @Vat bit = CASE WHEN (SELECT VatRatePct FROM dbo.Invoice WHERE InvoiceId = @InvoiceId) > 0 THEN 1 ELSE 0 END;
    DECLARE @Rows nvarchar(max) = (
        SELECT STRING_AGG(CONVERT(nvarchar(max),
                   N'<tr' + CASE WHEN LineType IN ('Info', 'PrepaidDrawn') THEN N' class="info"' ELSE N'' END + N'><td>' + dbo.fn_Html(Description) + N'</td>'
                 + N'<td class="num">' + CASE WHEN LineType = 'Info' THEN N''
                        WHEN LineType IN ('BusinessHours', 'OutOfHours', 'PrepaidPurchase', 'PrepaidDrawn') THEN FORMAT(Quantity, 'N2') + N' h'
                        WHEN LineType = 'Consultancy' THEN FORMAT(Quantity, 'N2') + CASE WHEN UnitPrice = 0 THEN N'' ELSE N' d' END
                        ELSE FORMAT(Quantity, 'N2') END + N'</td>'
                 + N'<td class="num">' + CASE WHEN LineType = 'Info' THEN N'' WHEN LineType = 'PrepaidDrawn' THEN N'pre-paid' ELSE N'&#163;' + FORMAT(UnitPrice, 'N2') END + N'</td>'
                 + N'<td class="num">' + CASE WHEN LineType = 'Info' THEN N'' ELSE N'&#163;' + FORMAT(Amount, 'N2') END + N'</td></tr>'), N'')
               WITHIN GROUP (ORDER BY CASE LineType WHEN 'MonthlyFee' THEN 1 WHEN 'PrepaidPurchase' THEN 2 WHEN 'BusinessHours' THEN 3 WHEN 'OutOfHours' THEN 4 WHEN 'PrepaidDrawn' THEN 5 WHEN 'Info' THEN 7 ELSE 6 END, InvoiceLineId)
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
    + ISNULL(N'<br />' + (SELECT STRING_AGG(dbo.fn_Html(FullName) + ISNULL(N' &#183; ' + dbo.fn_Html(Email), N''), N'<br />') WITHIN GROUP (ORDER BY FullName)
                         FROM dbo.Contact WHERE ClientId = c.ClientId AND IsBillingContact = 1 AND IsActive = 1), N'') + N'</div>
<div style="text-align:right"><div class="label">Invoice number</div><strong>' + i.InvoiceNo + N'</strong>
<div class="label" style="margin-top:8px">Invoice date</div>' + CONVERT(nvarchar(11), i.InvoiceDate, 106) + N'
<div class="label" style="margin-top:8px">Payment due</div>' + CONVERT(nvarchar(11), i.DueDate, 106) + N'
' + @RefHtml + N'</div></div>
<table><tr><th>Description</th><th class="num">Qty</th><th class="num">Rate</th><th class="num">Amount</th></tr>' + ISNULL(@Rows, N'') + N'</table>
<table class="totals">
<tr><td>Subtotal</td><td class="num">&#163;' + FORMAT(i.SubTotal, 'N2') + N'</td></tr>'
    + CASE WHEN @Vat = 1 THEN N'<tr><td>VAT at ' + FORMAT(i.VatRatePct, 'N0') + N'%</td><td class="num">&#163;' + FORMAT(i.VatAmount, 'N2') + N'</td></tr>' ELSE N'' END + N'
<tr class="grand"><td>Total due</td><td class="num">&#163;' + FORMAT(i.Total, 'N2') + N'</td></tr></table>
<div class="note">' + CASE WHEN @Vat = 0 THEN dbo.fn_Html(dbo.fn_Setting('BusinessName')) + N' is not currently VAT registered, so no VAT is charged.<br />' ELSE N'' END
    + CASE WHEN @EngType = 'Monitoring' THEN N'Monthly fees are invoiced in advance; additional support is invoiced in arrears. ' ELSE N'' END
    + N'Payment is due within ' + ISNULL(dbo.fn_Setting('PaymentTermsDays'), N'14') + N' days of the invoice date.'
    + CASE WHEN @EngType = 'Monitoring' THEN N' Late payment may result in support being paused until payment is received.' ELSE N'' END
    + CASE WHEN NULLIF(dbo.fn_Setting('PaymentDetails'), N'') IS NOT NULL THEN N'<br /><br /><strong>Payment details:</strong> ' + REPLACE(dbo.fn_Html(dbo.fn_Setting('PaymentDetails')), CHAR(10), N'<br />') ELSE N'' END
    + N'</div></div>
<div class="foot">' + dbo.fn_Html(dbo.fn_Setting('BusinessName')) + ISNULL(N' &#183; ' + dbo.fn_Html(NULLIF(dbo.fn_Setting('BusinessAddress'), N'')), N'')
    + N' &#183; ' + dbo.fn_Html(dbo.fn_Setting('BusinessEmail')) + N' &#183; ' + dbo.fn_Html(dbo.fn_Setting('BusinessWebsite')) + N'</div>
</div></body></html>'
    FROM dbo.Invoice i JOIN dbo.Client c ON c.ClientId = i.ClientId
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

    -- Time that can never be invoiced: dated outside the agreement's billing period
    INSERT #A
    SELECT 2, 'Billing', c.ClientName, N'Time logged outside the billing period: ' + t.TicketRef,
           FORMAT(SUM(e.Minutes) / 60.0, 'N2') + N' h dated ' + CONVERT(nvarchar(11), MIN(e.WorkStart), 106)
           + N', outside ' + a.AgreementRef + N' (' + CONVERT(nvarchar(11), a.StartDate, 106) + ISNULL(N' to ' + CONVERT(nvarchar(11), a.EndDate, 106), N' onwards')
           + N'). It will never be invoiced and does not use included or pre-paid hours: correct the date (usp_Time_Update) or remove it.', NULL
    FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId
    JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE e.IsBillable = 1 AND e.InvoiceId IS NULL AND t.WorkType <> 'Project' AND dbo.fn_IsBillablePeriod(t.AgreementId, e.WorkStart) = 0
    GROUP BY c.ClientName, t.TicketRef, a.AgreementRef, a.StartDate, a.EndDate;

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
    SELECT 2, 'Billing', c.ClientName, N'Draft invoice ready to send: ' + i.InvoiceNo, NCHAR(163) + FORMAT(i.Total, 'N2') + N', dated ' + CONVERT(nvarchar(11), i.InvoiceDate, 106)
           + N'. Send to: ' + ISNULL((SELECT STRING_AGG(ISNULL(ct.Email, ct.FullName + N' (no e-mail)'), N'; ') FROM dbo.Contact ct
                                      WHERE ct.ClientId = c.ClientId AND ct.IsActive = 1 AND ct.IsBillingContact = 1), N'NO ONE - add a contact that receives invoices')
           + N'. Then usp_Invoice_SetStatus @Status = ''Sent''.', NULL
    FROM dbo.vw_Invoice i JOIN dbo.Client c ON c.ClientId = i.ClientId
    WHERE i.Status = 'Draft';

    INSERT #A
    SELECT 1, 'Billing', c.ClientName, N'Payment overdue: ' + i.InvoiceNo,
           NCHAR(163) + FORMAT(i.Total, 'N2') + N' was due ' + CONVERT(nvarchar(11), i.DueDate, 106) + N' (' + CONVERT(nvarchar(10), DATEDIFF(day, i.DueDate, @Today)) + N' days). Support may be paused until paid'
           + CASE WHEN i.SupportPausedFrom IS NOT NULL THEN N' - currently PAUSED.' ELSE N'.' END, NULL
    FROM dbo.vw_Invoice i JOIN dbo.Client c ON c.ClientId = i.ClientId
    WHERE i.Status = 'Sent' AND i.DueDate < @Today;

    -- Consultancy: work waiting to be invoiced, and jobs that look finished
    INSERT #A
    SELECT 3, 'Consultancy', c.ClientName, N'Unbilled work: ' + e.EngagementRef + N' ' + e.Name,
           FORMAT(u.Days, 'N2') + N' days (' + NCHAR(163) + FORMAT(u.Value, 'N2') + N') logged up to ' + CONVERT(nvarchar(11), u.LastWorked, 106)
           + N'. The billing run invoices it after ' + CONVERT(nvarchar(11), DATEADD(day, -1,
               dbo.fn_ConsultancyPeriodStart(e.StartDate, dbo.fn_ConsultancyPeriod(e.StartDate, @Today) + 1)), 106) + N'.', NULL
    FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId
    CROSS APPLY (SELECT Days = SUM(w.Days), Value = SUM(w.Quantity * w.UnitPrice), LastWorked = MAX(w.WorkDate)
                 FROM dbo.fn_ConsultancyWork(e.EngagementId, 1) w) u
    WHERE e.EngagementType = 'Consultancy' AND e.Status IN ('Active', 'OnHold') AND e.BillingMode <> 'FixedPrice' AND u.Days > 0;

    INSERT #A
    SELECT 2, 'Consultancy', c.ClientName, N'Engagement past its end date: ' + e.EngagementRef + N' ' + e.Name,
           N'It ended ' + CONVERT(nvarchar(11), e.EndDate, 106) + N' but is still open. Mark it complete (usp_Engagement_Complete) so the final invoice goes out.', NULL
    FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId
    WHERE e.EngagementType = 'Consultancy' AND e.Status IN ('Active', 'OnHold') AND e.EndDate < @Today;

    INSERT #A
    SELECT 2, 'Consultancy', c.ClientName, N'Fixed price to invoice: ' + e.EngagementRef + N' ' + e.Name,
           NCHAR(163) + FORMAT(e.FixedPrice, 'N2') + N' agreed, completed ' + CONVERT(nvarchar(11), e.CompletedOn, 106) + N'. The next billing run raises it.', NULL
    FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId
    WHERE e.EngagementType = 'Consultancy' AND e.BillingMode = 'FixedPrice' AND e.Status = 'Completed'
      AND NOT EXISTS (SELECT 1 FROM dbo.Invoice i JOIN dbo.InvoiceLine l ON l.InvoiceId = i.InvoiceId
                      WHERE i.EngagementId = e.EngagementId AND l.LineType = 'FixedFee' AND i.Status <> 'Void');

    -- Contacts: onboarding done, but every named contact has since been removed
    INSERT #A
    SELECT 2, 'Contacts', c.ClientName, N'No current named contact (' + a.AgreementRef + N')',
           N'Every named point of contact has been removed. The agreement needs one for ticket queries: add or re-add one.', NULL
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE (a.EndDate IS NULL OR a.EndDate >= @Today)
      AND EXISTS (SELECT 1 FROM dbo.OnboardingItem o WHERE o.AgreementId = a.AgreementId AND o.ItemCode = 'NAMED_CONTACT' AND o.CompletedDate IS NOT NULL)
      AND NOT EXISTS (SELECT 1 FROM dbo.Contact ct WHERE ct.ClientId = a.ClientId AND ct.IsActive = 1 AND ct.IsNamedContact = 1);

    -- Pre-paid hours: running low, just used up, or about to expire
    INSERT #A
    SELECT 2, 'Billing', c.ClientName, N'Pre-paid hours running low: ' + p.PackageRef,
           FORMAT(p.Remaining, 'N2') + N' of ' + FORMAT(p.Hours, 'N2') + N' h left' + ISNULL(N', use by ' + CONVERT(nvarchar(11), p.ExpiresOn, 106), N'') + N'. A good time to offer a top-up.', NULL
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    CROSS APPLY dbo.fn_PrepaidPackages(a.AgreementId, @Today) p
    WHERE p.State = 'Active' AND p.Remaining <= p.Hours * 0.2 AND (a.EndDate IS NULL OR a.EndDate >= @Today);

    INSERT #A
    SELECT 2, 'Billing', c.ClientName, N'Pre-paid hours used up: ' + p.PackageRef,
           N'All ' + FORMAT(p.Hours, 'N2') + N' h used (last on ' + CONVERT(nvarchar(11), p.LastUsed, 106) + N'). Further support is billed at the standard rates unless they top up.', NULL
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    CROSS APPLY dbo.fn_PrepaidPackages(a.AgreementId, @Today) p
    WHERE p.State = 'Used up' AND p.LastUsed >= DATEADD(day, -30, @Today) AND (a.EndDate IS NULL OR a.EndDate >= @Today)
      AND NOT EXISTS (SELECT 1 FROM dbo.fn_PrepaidPackages(a.AgreementId, @Today) o WHERE o.State IN ('Active', 'Not started'));

    INSERT #A
    SELECT 2, 'Billing', c.ClientName, N'Pre-paid hours expiring: ' + p.PackageRef,
           FORMAT(p.Remaining, 'N2') + N' h unused will expire on ' + CONVERT(nvarchar(11), p.ExpiresOn, 106) + N'. Let the client know (or agree an extension with usp_Prepaid_Update).', p.ExpiresOn
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    CROSS APPLY dbo.fn_PrepaidPackages(a.AgreementId, @Today) p
    WHERE p.State = 'Active' AND p.ExpiresOn <= DATEADD(day, 30, @Today) AND p.Remaining > p.Hours * 0.2;

    -- Contacts: nobody receives invoices
    INSERT #A
    SELECT 2, 'Contacts', c.ClientName, N'No one receives invoices (' + a.AgreementRef + N')',
           N'No current contact has "receives invoices" set. Add one - a shared accounts address can be a contact that only receives invoices.', NULL
    FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
    WHERE (a.EndDate IS NULL OR a.EndDate >= @Today)
      AND NOT EXISTS (SELECT 1 FROM dbo.Contact ct WHERE ct.ClientId = a.ClientId AND ct.IsActive = 1 AND ct.IsBillingContact = 1);

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

    -- Consultancy engagements
    SELECT e.EngagementRef, c.ClientName, e.Name, e.Status,
           Rate = CASE e.BillingMode WHEN 'DayRate' THEN NCHAR(163) + FORMAT(e.DayRate, 'N0') + N'/day'
                                     WHEN 'Hourly'  THEN NCHAR(163) + FORMAT(e.HourlyRate, 'N0') + N'/hour'
                                     ELSE NCHAR(163) + FORMAT(e.FixedPrice, 'N0') + N' fixed' END,
           UnbilledDays = ISNULL(u.Days, 0), UnbilledValue = ISNULL(u.Value, 0), LastWorked = u.LastWorked,
           Invoiced = ISNULL((SELECT SUM(i.Total) FROM dbo.Invoice i WHERE i.EngagementId = e.EngagementId AND i.Status <> 'Void'), 0)
    FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId
    OUTER APPLY (SELECT Days = SUM(w.Days), Value = SUM(w.Quantity * w.UnitPrice), LastWorked = MAX(w.WorkDate)
                 FROM dbo.fn_ConsultancyWork(e.EngagementId, 1) w) u
    WHERE e.EngagementType = 'Consultancy'
      AND (e.Status IN ('Active', 'OnHold') OR e.CompletedOn >= DATEADD(day, -60, @Today))
    ORDER BY c.ClientName, e.EngagementRef;

    -- Money
    SELECT MonthlyRecurringRevenue = ISNULL((SELECT SUM(f.MonthlyFee) FROM dbo.Agreement a CROSS APPLY dbo.fn_AgreementFees(a.AgreementId, @Today) f
                                             WHERE a.StartDate <= @Today AND (a.EndDate IS NULL OR a.EndDate >= @Today)), 0),
           DraftInvoicesTotal = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Draft'), 0),
           UnpaidSentTotal    = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Sent'), 0),
           OverdueTotal       = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Sent' AND DueDate < @Today), 0),
           PaidThisYear       = ISNULL((SELECT SUM(Total) FROM dbo.Invoice WHERE Status = 'Paid' AND YEAR(PaidAt) = YEAR(@Today)), 0),
           UnbilledConsultancy = ISNULL((SELECT SUM(w.Quantity * w.UnitPrice) FROM dbo.Engagement e
                                         CROSS APPLY dbo.fn_ConsultancyWork(e.EngagementId, 1) w
                                         WHERE e.EngagementType = 'Consultancy' AND e.Status <> 'Cancelled'), 0);
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

INSERT dbo.InstallHistory (Version) VALUES ('2.2.0');   -- bump with every schema change: Molehill Manager offers the upgrade
PRINT N'Molehill Admin 2.2.0 installed.';
GO
