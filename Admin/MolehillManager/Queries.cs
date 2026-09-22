using System.Data;

namespace MolehillManager;

/// <summary>The read queries behind each screen. Changes always go through the stored procedures.</summary>
public static class Queries
{
    // agreement status, as the dashboard reports it
    private const string AgreementStatus = """
        CASE WHEN a.EndDate < @Today THEN 'Ended' WHEN a.StartDate > @Today THEN 'Not started'
             WHEN a.NoticeGivenDate IS NOT NULL THEN 'Notice given' WHEN a.SupportPausedFrom IS NOT NULL THEN 'Paused'
             WHEN @Today <= dbo.fn_InitialTermEnd(a.AgreementId) THEN 'Initial term' ELSE 'Rolling monthly' END
        """;

    public static DataTable Agreements(AdminDb db, bool includeEnded) => db.Query($"""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        SELECT a.AgreementRef AS Ref, c.ClientName AS Client, {AgreementStatus} AS Status,
               a.StartDate AS Started,
               (SELECT COUNT(*) FROM dbo.Instance i WHERE i.AgreementId = a.AgreementId AND i.CoveredTo IS NULL) AS Instances,
               (SELECT SUM(MonthlyFee) FROM dbo.fn_AgreementFees(a.AgreementId, CASE WHEN a.StartDate > @Today THEN a.StartDate ELSE @Today END)) AS MonthlyFee,
               (SELECT COUNT(*) FROM dbo.Ticket t WHERE t.AgreementId = a.AgreementId AND t.Status NOT IN ('Resolved', 'Closed')) AS OpenTickets,
               (SELECT COUNT(*) FROM dbo.OnboardingItem o WHERE o.AgreementId = a.AgreementId AND o.IsRequired = 1 AND o.CompletedDate IS NULL) AS OnboardingLeft,
               (SELECT SUM(p.Remaining) FROM dbo.fn_PrepaidPackages(a.AgreementId, @Today) p WHERE p.State IN ('Active', 'Not started')) AS PrepaidLeft
        FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
        WHERE @IncludeEnded = 1 OR a.EndDate IS NULL OR a.EndDate >= @Today
        ORDER BY c.ClientName, a.StartDate;
        """, ("@IncludeEnded", includeEnded));

    /// <summary>"MWA-0001 - Client" for pickers.</summary>
    public static List<string> AgreementChoices(AdminDb db) =>
        db.Query("""
            SELECT a.AgreementRef + ' - ' + c.ClientName FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
            WHERE a.EndDate IS NULL OR a.EndDate >= DATEADD(day, -90, CAST(dbo.fn_UkNow() AS date))
            ORDER BY c.ClientName, a.StartDate;
            """).Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();

    public static string RefFromChoice(string choice) => choice.Split(" - ", 2)[0].Trim();

    public static List<string> ClientNames(AdminDb db) =>
        db.Query("SELECT ClientName FROM dbo.Client ORDER BY ClientName;").Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();

    public static List<string> PriceLists(AdminDb db) =>
        db.Query("SELECT Name FROM dbo.PriceList ORDER BY EffectiveFrom DESC, Name;").Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();

    public static List<string> InstanceNames(AdminDb db, string agreementRef) =>
        db.Query("""
            SELECT i.InstanceName FROM dbo.Instance i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId
            WHERE a.AgreementRef = @Ref AND i.CoveredTo IS NULL ORDER BY i.InstanceName;
            """, ("@Ref", agreementRef)).Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();

    public static DataRow? Agreement(AdminDb db, string agreementRef)
    {
        var t = db.Query($"""
            DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
            SELECT a.AgreementRef, c.ClientName, c.Address, c.Notes AS ClientNotes,
                   (SELECT STRING_AGG(ct.FullName + ISNULL(N' <' + ct.Email + N'>', N' (no e-mail)'), N'; ') FROM dbo.Contact ct
                    WHERE ct.ClientId = c.ClientId AND ct.IsActive = 1 AND ct.IsBillingContact = 1) AS InvoicesTo,
                   {AgreementStatus} AS Status, a.SignedDate, a.StartDate, a.InitialTermMonths,
                   dbo.fn_InitialTermEnd(a.AgreementId) AS InitialTermEnds, p.Name AS PriceList, a.TicketChannel,
                   a.InitialReviewDoneDate, a.InitialReviewNotes, a.NoticeGivenDate, a.NoticeGivenBy, a.EndDate,
                   a.SupportPausedFrom, a.OutOfHoursCoverNotes, a.Notes
            FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
            JOIN dbo.PriceList p ON p.PriceListId = dbo.fn_PriceListIdOn(a.AgreementId, CASE WHEN a.StartDate > @Today THEN a.StartDate ELSE @Today END)
            WHERE a.AgreementRef = @Ref;
            """, ("@Ref", agreementRef));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    /// <summary>The client's contacts; removed ones too when asked, with the dates of their latest period.</summary>
    public static DataTable Contacts(AdminDb db, string agreementRef, bool includeRemoved = false) => db.Query("""
        SELECT ct.ContactId AS Id, ct.FullName AS Name, ct.Email, ct.Phone,
               CASE WHEN ct.IsNamedContact = 1 THEN 'Yes' ELSE '' END AS Tickets,
               CASE WHEN ct.IsBillingContact = 1 THEN 'Yes' ELSE '' END AS Invoices,
               CASE WHEN ct.IsActive = 1 THEN 'Current' ELSE 'Removed' END AS Status,
               p.StartDate AS [From], p.EndDate AS [To],
               (SELECT COUNT(*) FROM dbo.ContactPeriod x WHERE x.ContactId = ct.ContactId) AS Periods
        FROM dbo.Contact ct
        OUTER APPLY (SELECT TOP (1) StartDate, EndDate FROM dbo.ContactPeriod WHERE ContactId = ct.ContactId ORDER BY StartDate DESC) p
        WHERE ct.ClientId = dbo.fn_ClientId(@Ref) AND (@IncludeRemoved = 1 OR ct.IsActive = 1)
        ORDER BY ct.IsActive DESC, ct.IsNamedContact DESC, ct.FullName;
        """, ("@Ref", agreementRef), ("@IncludeRemoved", includeRemoved));

    /// <summary>The agreement's pre-paid hours packages, newest first.</summary>
    public static DataTable Prepaid(AdminDb db, string agreementRef) => db.Query("""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        SELECT p.PackageRef AS Ref, p.PurchasedOn AS Bought, p.Hours, p.HourlyRate AS Rate, p.Price, p.Used, p.Remaining AS [Left],
               p.StartsOn AS [From], p.ExpiresOn AS [Use by],
               p.State, i.InvoiceNo AS Invoice, i.Status AS [Invoice status], p.Notes
        FROM dbo.fn_PrepaidPackages((SELECT AgreementId FROM dbo.Agreement WHERE AgreementRef = @Ref), @Today) p
        LEFT JOIN dbo.Invoice i ON i.InvoiceId = p.InvoiceId
        ORDER BY p.PurchasedOn DESC, p.PackageId DESC;
        """, ("@Ref", agreementRef));

    public static DataTable PrepaidUsage(AdminDb db, string packageRef) => db.Query("""
        SELECT u.CreatedAt AS Recorded, t.TicketRef AS Ticket, t.Title, u.HoursUsed AS Hours,
               i.InvoiceNo AS Invoice
        FROM dbo.PrepaidUsage u JOIN dbo.PrepaidPackage p ON p.PackageId = u.PackageId
        JOIN dbo.Invoice i ON i.InvoiceId = u.InvoiceId LEFT JOIN dbo.Ticket t ON t.TicketId = u.TicketId
        WHERE p.PackageRef = @Ref ORDER BY u.UsageId;
        """, ("@Ref", packageRef));

    public static DataRow? PrepaidPackage(AdminDb db, string packageRef)
    {
        var t = db.Query("SELECT * FROM dbo.PrepaidPackage WHERE PackageRef = @Ref;", ("@Ref", packageRef));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    public static DataRow? Contact(AdminDb db, int contactId)
    {
        var t = db.Query("SELECT * FROM dbo.Contact WHERE ContactId = @Id;", ("@Id", contactId));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    public static DataTable ContactPeriods(AdminDb db, int contactId) => db.Query("""
        SELECT StartDate AS [From], EndDate AS [To], DATEDIFF(day, StartDate, ISNULL(EndDate, CAST(dbo.fn_UkNow() AS date))) + 1 AS Days,
               EndReason AS Reason
        FROM dbo.ContactPeriod WHERE ContactId = @Id ORDER BY StartDate;
        """, ("@Id", contactId));

    /// <summary>Every instance on the agreement, with what it costs today (or from the start date, before it starts).</summary>
    public static DataTable Instances(AdminDb db, string agreementRef) => db.Query("""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        DECLARE @AgreementId int = (SELECT AgreementId FROM dbo.Agreement WHERE AgreementRef = @Ref);
        DECLARE @AsOf date = (SELECT CASE WHEN StartDate > @Today THEN StartDate ELSE @Today END FROM dbo.Agreement WHERE AgreementId = @AgreementId);
        SELECT i.InstanceName AS Instance,
               CASE i.Platform WHEN 'SqlServer' THEN 'SQL Server' WHEN 'AzureSqlManagedInstance' THEN 'Azure SQL MI'
                               WHEN 'AzureSqlDatabaseServer' THEN 'Azure SQL DB server' WHEN 'AzureSqlDatabaseElasticPool' THEN 'Azure SQL DB pool' END AS Platform,
               i.Role, i.DatabaseCount AS DBs, i.Environment AS Env, i.SqlVersion AS Version,
               f.MonthlyFee AS Fee,
               CASE WHEN i.CoveredTo IS NOT NULL AND i.CoveredTo < @AsOf THEN 'Removed ' + CONVERT(varchar(11), i.CoveredTo, 106)
                    WHEN i.CoveredTo IS NOT NULL THEN 'Ends ' + CONVERT(varchar(11), i.CoveredTo, 106)
                    WHEN i.CoveredFrom > @AsOf THEN 'From ' + CONVERT(varchar(11), i.CoveredFrom, 106) ELSE 'Covered' END AS Cover,
               i.MonitoringInstalledDate AS Monitoring,
               CASE WHEN i.Platform IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool', 'AzureSqlManagedInstance') THEN 'Microsoft-managed'
                    WHEN l.ExtendedEnd < @Today AND i.UnsupportedRiskAcceptedDate IS NOT NULL THEN 'Unsupported, risk accepted'
                    WHEN l.ExtendedEnd < @Today THEN 'UNSUPPORTED'
                    WHEN l.ExtendedEnd IS NULL THEN '?' ELSE 'Supported' END AS Lifecycle,
               f.PricingBasis AS Basis
        FROM dbo.Instance i
        LEFT JOIN dbo.fn_AgreementFees(@AgreementId, @AsOf) f ON f.InstanceId = i.InstanceId
        LEFT JOIN dbo.ProductLifecycle l ON l.VersionKey = i.SqlVersion
        WHERE i.AgreementId = @AgreementId
        ORDER BY CASE WHEN i.CoveredTo < @AsOf THEN 1 ELSE 0 END, i.InstanceName;
        """, ("@Ref", agreementRef));

    public static DataRow? Instance(AdminDb db, string agreementRef, string instanceName)
    {
        var t = db.Query("""
            SELECT i.* FROM dbo.Instance i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId
            WHERE a.AgreementRef = @Ref AND i.InstanceName = @Name;
            """, ("@Ref", agreementRef), ("@Name", instanceName));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    public static DataTable Onboarding(AdminDb db, string agreementRef) => db.Query("""
        SELECT o.ItemCode AS Code, o.Description, CASE WHEN o.IsRequired = 1 THEN 'Yes' ELSE '' END AS Required,
               o.CompletedDate AS Done, o.Notes
        FROM dbo.OnboardingItem o JOIN dbo.Agreement a ON a.AgreementId = o.AgreementId
        WHERE a.AgreementRef = @Ref ORDER BY o.SortOrder;
        """, ("@Ref", agreementRef));

    public static DataTable WeeklyReports(AdminDb db, string agreementRef) => db.Query("""
        SELECT TOP (200) w.WeekEnding, i.InstanceName AS Instance, w.OverallStatus AS Status, w.CriticalCount AS Critical,
               w.WarningCount AS Warnings, t.TicketRef AS FollowUp, w.Notes
        FROM dbo.WeeklyReportLog w JOIN dbo.Instance i ON i.InstanceId = w.InstanceId
        JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId
        LEFT JOIN dbo.Ticket t ON t.TicketId = w.FollowUpTicketId
        WHERE a.AgreementRef = @Ref ORDER BY w.WeekEnding DESC, i.InstanceName;
        """, ("@Ref", agreementRef));

    public static DataTable Tickets(AdminDb db, bool openOnly, string? agreementRef = null) => db.Query("""
        SELECT TOP (500) t.TicketRef AS Ticket, c.ClientName AS Client, t.Severity, t.Status, t.WorkType AS Type,
               CASE t.RateType WHEN 'BusinessHours' THEN 'Business' WHEN 'OutOfHours' THEN 'Out of hours' ELSE 'By time' END AS Rate, t.Title,
               i.InstanceName AS Instance, t.RaisedAt AS Raised, t.ResponseDueAt AS ResponseDue, t.FirstResponseAt AS Responded,
               CAST(ISNULL((SELECT SUM(Minutes) FROM dbo.TimeEntry e WHERE e.TicketId = t.TicketId), 0) / 60.0 AS decimal(6,2)) AS Hours,
               t.EstimateHours AS Estimate, CASE WHEN t.EstimateApprovedAt IS NOT NULL THEN 'Yes' END AS Approved
        FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
        LEFT JOIN dbo.Instance i ON i.InstanceId = t.InstanceId
        WHERE (@OpenOnly = 0 OR t.Status NOT IN ('Resolved', 'Closed')) AND (@Ref IS NULL OR a.AgreementRef = @Ref)
        ORDER BY CASE WHEN t.Status IN ('Resolved', 'Closed') THEN 1 ELSE 0 END,
                 CASE t.Severity WHEN 'Critical' THEN 0 ELSE 1 END, t.RaisedAt DESC;
        """, ("@OpenOnly", openOnly), ("@Ref", agreementRef));

    public static DataRow? Ticket(AdminDb db, string ticketRef)
    {
        var t = db.Query("""
            SELECT t.TicketRef, a.AgreementRef, c.ClientName, t.Title, t.Severity, t.WorkType, t.RateType, t.Status, i.InstanceName,
                   ct.FullName AS Contact, t.Channel, t.RaisedAt, t.ResponseDueAt, t.FirstResponseAt,
                   t.EstimateHours, t.EstimateSentAt, t.EstimateApprovedAt, t.ResolvedAt, t.Description, t.Resolution
            FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
            LEFT JOIN dbo.Instance i ON i.InstanceId = t.InstanceId LEFT JOIN dbo.Contact ct ON ct.ContactId = t.ContactId
            WHERE t.TicketRef = @Ref;
            """, ("@Ref", ticketRef));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    public static DataTable TimeEntries(AdminDb db, string ticketRef) => db.Query("""
        SELECT e.TimeEntryId AS Id, e.WorkStart AS Started, e.Minutes, e.RateType AS Rate, CASE WHEN e.IsBillable = 1 THEN 'Yes' ELSE 'No' END AS Billable,
               CASE WHEN inv.InvoiceNo IS NOT NULL THEN inv.InvoiceNo
                    WHEN dbo.fn_IsBillablePeriod(t.AgreementId, e.WorkStart) = 0 THEN 'NEVER - outside the billing period'
                    WHEN e.IsBillable = 0 THEN 'not billable'
                    ELSE 'at the next billing run' END AS Invoiced,
               e.Description
        FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId LEFT JOIN dbo.Invoice inv ON inv.InvoiceId = e.InvoiceId
        WHERE t.TicketRef = @Ref ORDER BY e.WorkStart;
        """, ("@Ref", ticketRef));

    public static DataRow? TimeEntry(AdminDb db, int timeEntryId)
    {
        var t = db.Query("""
            SELECT e.*, t.TicketRef, inv.InvoiceNo FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId
            LEFT JOIN dbo.Invoice inv ON inv.InvoiceId = e.InvoiceId WHERE e.TimeEntryId = @Id;
            """, ("@Id", timeEntryId));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    public static DataTable Invoices(AdminDb db, string filter) => db.Query("""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        SELECT TOP (500) i.InvoiceNo AS Invoice, i.ClientName AS Client, ISNULL(i.EngagementRef, 'free-text') AS [For],
               i.InvoiceDate AS Dated, i.DueDate AS Due,
               i.Total, CASE WHEN i.Status = 'Sent' AND i.DueDate < @Today THEN 'OVERDUE' ELSE i.Status END AS Status,
               i.SentAt AS Sent, i.PaidAt AS Paid
        FROM dbo.vw_Invoice i
        WHERE @Filter = 'All' OR (@Filter = 'Outstanding' AND i.Status IN ('Draft', 'Sent'))
        ORDER BY i.InvoiceDate DESC, i.InvoiceNo DESC;
        """, ("@Filter", filter));

    public static DataTable InvoiceLines(AdminDb db, string invoiceNo) => db.Query("""
        SELECT l.InvoiceLineId AS Id, l.LineType AS Type, l.Description, l.Quantity AS Qty, l.UnitPrice AS Price, l.Amount
        FROM dbo.InvoiceLine l JOIN dbo.Invoice i ON i.InvoiceId = l.InvoiceId
        WHERE i.InvoiceNo = @No ORDER BY l.InvoiceLineId;
        """, ("@No", invoiceNo));

    // ------------------------------------------------------------------ engagements

    /// <summary>Everything the business is billing for: support agreements and consultancy side by side.</summary>
    public static DataTable Engagements(AdminDb db, bool includeEnded) => db.Query($"""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        SELECT e.EngagementRef AS Ref, c.ClientName AS Client,
               CASE e.EngagementType WHEN 'Monitoring' THEN 'Molehill Watch' ELSE 'Consultancy' END AS Type,
               CASE WHEN e.EngagementType = 'Monitoring'
                    THEN CONVERT(nvarchar(10), (SELECT COUNT(*) FROM dbo.Instance i WHERE i.AgreementId = a.AgreementId AND i.CoveredTo IS NULL))
                         + ' instance(s) monitored'
                    ELSE e.Name END AS [What],
               CASE WHEN e.EngagementType = 'Monitoring' THEN {AgreementStatus} ELSE e.Status END AS Status,
               CASE e.BillingMode
                    WHEN 'AgreementCycle' THEN NCHAR(163) + FORMAT(ISNULL((SELECT SUM(MonthlyFee) FROM dbo.fn_AgreementFees(a.AgreementId,
                             CASE WHEN a.StartDate > @Today THEN a.StartDate ELSE @Today END)), 0), 'N0') + '/month'
                    WHEN 'DayRate'    THEN NCHAR(163) + FORMAT(e.DayRate, 'N0') + '/day'
                    WHEN 'Hourly'     THEN NCHAR(163) + FORMAT(e.HourlyRate, 'N0') + '/hour'
                    ELSE NCHAR(163) + FORMAT(e.FixedPrice, 'N0') + ' fixed' END AS Rate,
               CASE WHEN e.EngagementType = 'Monitoring'
                    THEN NULLIF(FORMAT(ISNULL((SELECT SUM(te.Minutes) / 60.0 FROM dbo.TimeEntry te
                                               WHERE te.EngagementId = e.EngagementId AND te.IsBillable = 1 AND te.InvoiceId IS NULL), 0), 'N2') + ' h', '0.00 h')
                    ELSE NULLIF(NCHAR(163) + FORMAT(ISNULL(u.Value, 0), 'N0') + ' (' + FORMAT(ISNULL(u.Days, 0), 'N2') + ' d)', NCHAR(163) + '0 (0.00 d)')
                    END AS Unbilled,
               (SELECT COUNT(*) FROM dbo.Ticket t WHERE t.AgreementId = a.AgreementId AND t.Status NOT IN ('Resolved', 'Closed')) AS OpenTickets,
               (SELECT COUNT(*) FROM dbo.OnboardingItem o WHERE o.AgreementId = a.AgreementId AND o.IsRequired = 1 AND o.CompletedDate IS NULL) AS OnboardingLeft
        FROM dbo.Engagement e
        JOIN dbo.Client c ON c.ClientId = e.ClientId
        LEFT JOIN dbo.Agreement a ON a.EngagementId = e.EngagementId
        OUTER APPLY (SELECT Days = SUM(w.Days), Value = SUM(w.Quantity * w.UnitPrice) FROM dbo.fn_ConsultancyWork(e.EngagementId, 1) w) u
        WHERE @IncludeEnded = 1
           OR (e.EngagementType = 'Monitoring' AND (a.EndDate IS NULL OR a.EndDate >= @Today))
           OR (e.EngagementType = 'Consultancy' AND (e.Status IN ('Active', 'OnHold') OR e.CompletedOn >= DATEADD(day, -60, @Today)))
        ORDER BY c.ClientName, CASE e.EngagementType WHEN 'Monitoring' THEN 0 ELSE 1 END, e.EngagementRef;
        """, ("@IncludeEnded", includeEnded));

    public static DataRow? Engagement(AdminDb db, string engagementRef)
    {
        var t = db.Query("""
            SELECT e.EngagementRef, c.ClientName, e.EngagementType, e.Name, e.BillingMode, e.DayRate, e.HourlyRate, e.OutOfHoursRate,
                   e.FixedPrice, e.DayRounding, e.PurchaseOrder, e.Status, e.StartDate, e.EndDate, e.CompletedOn, e.Notes,
                   (SELECT STRING_AGG(ct.FullName + ISNULL(N' <' + ct.Email + N'>', N' (no e-mail)'), N'; ') FROM dbo.Contact ct
                    WHERE ct.ClientId = c.ClientId AND ct.IsActive = 1 AND ct.IsBillingContact = 1) AS InvoicesTo,
                   ISNULL(u.Days, 0) AS UnbilledDays, ISNULL(u.Value, 0) AS UnbilledValue, u.LastWorked,
                   CASE WHEN e.BillingMode = 'FixedPrice' THEN NULL
                        ELSE DATEADD(day, -1, dbo.fn_ConsultancyPeriodStart(e.StartDate,
                             dbo.fn_ConsultancyPeriod(e.StartDate, CAST(dbo.fn_UkNow() AS date)) + 1)) END AS PeriodEndsOn,
                   dbo.fn_ConsultancyBillingDays() AS BillingEveryDays,
                   ISNULL(w.Days, 0) AS TotalDays,
                   ISNULL((SELECT SUM(i.Total) FROM dbo.Invoice i WHERE i.EngagementId = e.EngagementId AND i.Status <> 'Void'), 0) AS Invoiced
            FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId
            OUTER APPLY (SELECT Days = SUM(x.Days), Value = SUM(x.Quantity * x.UnitPrice), LastWorked = MAX(x.WorkDate)
                         FROM dbo.fn_ConsultancyWork(e.EngagementId, 1) x) u
            OUTER APPLY (SELECT Days = SUM(x.Days) FROM dbo.fn_ConsultancyWork(e.EngagementId, 0) x) w
            WHERE e.EngagementRef = @Ref;
            """, ("@Ref", engagementRef));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    /// <summary>The days worked on a consultancy engagement, newest first.</summary>
    public static DataTable ConsultancyWork(AdminDb db, string engagementRef) => db.Query("""
        DECLARE @Id int = dbo.fn_EngagementId(@Ref);
        SELECT w.WorkDate AS [Date], CASE w.RateType WHEN 'OutOfHours' THEN 'Out of hours' ELSE 'Business hours' END AS Rate,
               w.Hours, w.Days, FORMAT(w.Quantity, 'N2') + ' ' + w.Unit + '(s)' AS Billed,
               -- what it was invoiced at, or what it would be charged at today
               ISNULL((SELECT SUM(l.Amount) FROM dbo.InvoiceLine l JOIN dbo.Invoice iv ON iv.InvoiceId = l.InvoiceId
                       WHERE l.EngagementId = @Id AND l.WorkDate = w.WorkDate AND l.RateType = w.RateType AND iv.Status <> 'Void'),
                      CAST(w.Quantity * w.UnitPrice AS decimal(10,2))) AS Charge,
               CASE WHEN EXISTS (SELECT 1 FROM dbo.TimeEntry te WHERE te.EngagementId = @Id AND CAST(te.WorkStart AS date) = w.WorkDate
                                   AND te.RateType = w.RateType AND te.IsBillable = 1 AND te.InvoiceId IS NULL)
                    THEN 'at the next billing run'
                    ELSE ISNULL((SELECT TOP (1) i.InvoiceNo FROM dbo.TimeEntry te JOIN dbo.Invoice i ON i.InvoiceId = te.InvoiceId
                                 WHERE te.EngagementId = @Id AND CAST(te.WorkStart AS date) = w.WorkDate AND te.RateType = w.RateType), '') END AS Invoiced,
               w.WorkDone AS [Work done]
        FROM dbo.fn_ConsultancyWork(@Id, 0) w ORDER BY w.WorkDate DESC, w.RateType;
        """, ("@Ref", engagementRef));

    /// <summary>Non-billable time is kept out of the charges, so it gets its own list.</summary>
    public static DataTable WorkEntries(AdminDb db, string engagementRef) => db.Query("""
        SELECT e.TimeEntryId AS Id, CAST(e.WorkStart AS date) AS [Date], e.Minutes,
               CAST(e.Minutes / 60.0 / dbo.fn_DayHours() AS decimal(6,2)) AS Days,
               CASE e.RateType WHEN 'OutOfHours' THEN 'Out of hours' ELSE 'Business hours' END AS Rate,
               CASE WHEN e.IsBillable = 1 THEN 'Yes' ELSE 'No' END AS Billable,
               ISNULL(i.InvoiceNo, CASE WHEN e.IsBillable = 1 THEN 'at the next billing run' ELSE 'not billable' END) AS Invoiced,
               e.Description
        FROM dbo.TimeEntry e JOIN dbo.Engagement g ON g.EngagementId = e.EngagementId
        LEFT JOIN dbo.Invoice i ON i.InvoiceId = e.InvoiceId
        WHERE g.EngagementRef = @Ref ORDER BY e.WorkStart DESC, e.TimeEntryId DESC;
        """, ("@Ref", engagementRef));

    public static DataTable EngagementInvoices(AdminDb db, string engagementRef) => db.Query("""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        SELECT i.InvoiceNo AS Invoice, i.InvoiceDate AS Dated, i.DueDate AS Due, i.Total,
               CASE WHEN i.Status = 'Sent' AND i.DueDate < @Today THEN 'OVERDUE' ELSE i.Status END AS Status,
               i.SentAt AS Sent, i.PaidAt AS Paid
        FROM dbo.vw_Invoice i WHERE i.EngagementRef = @Ref ORDER BY i.InvoiceDate DESC, i.InvoiceNo DESC;
        """, ("@Ref", engagementRef));

    /// <summary>"CON-0001 - Client" for pickers; consultancy only unless asked for everything.</summary>
    public static List<string> EngagementChoices(AdminDb db, bool consultancyOnly = true) =>
        db.Query("""
            SELECT e.EngagementRef + ' - ' + c.ClientName + CASE WHEN e.EngagementType = 'Consultancy' THEN ' (' + e.Name + ')' ELSE '' END
            FROM dbo.Engagement e JOIN dbo.Client c ON c.ClientId = e.ClientId
            WHERE (@ConsultancyOnly = 0 OR e.EngagementType = 'Consultancy')
              AND (e.Status IN ('Active', 'OnHold') OR e.CompletedOn >= DATEADD(day, -90, CAST(dbo.fn_UkNow() AS date)))
            ORDER BY c.ClientName, CASE e.EngagementType WHEN 'Monitoring' THEN 0 ELSE 1 END, e.EngagementRef;
            """, ("@ConsultancyOnly", consultancyOnly)).Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();
}
