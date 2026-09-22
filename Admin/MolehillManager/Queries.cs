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
               (SELECT COUNT(*) FROM dbo.OnboardingItem o WHERE o.AgreementId = a.AgreementId AND o.IsRequired = 1 AND o.CompletedDate IS NULL) AS OnboardingLeft
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
        FROM dbo.Contact ct JOIN dbo.Agreement a ON a.ClientId = ct.ClientId
        OUTER APPLY (SELECT TOP (1) StartDate, EndDate FROM dbo.ContactPeriod WHERE ContactId = ct.ContactId ORDER BY StartDate DESC) p
        WHERE a.AgreementRef = @Ref AND (@IncludeRemoved = 1 OR ct.IsActive = 1)
        ORDER BY ct.IsActive DESC, ct.IsNamedContact DESC, ct.FullName;
        """, ("@Ref", agreementRef), ("@IncludeRemoved", includeRemoved));

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
        SELECT TOP (500) t.TicketRef AS Ticket, c.ClientName AS Client, t.Severity, t.Status, t.WorkType AS Type, t.Title,
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
            SELECT t.TicketRef, a.AgreementRef, c.ClientName, t.Title, t.Severity, t.WorkType, t.Status, i.InstanceName,
                   ct.FullName AS Contact, t.Channel, t.RaisedAt, t.ResponseDueAt, t.FirstResponseAt,
                   t.EstimateHours, t.EstimateSentAt, t.EstimateApprovedAt, t.ResolvedAt, t.Description, t.Resolution
            FROM dbo.Ticket t JOIN dbo.Agreement a ON a.AgreementId = t.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
            LEFT JOIN dbo.Instance i ON i.InstanceId = t.InstanceId LEFT JOIN dbo.Contact ct ON ct.ContactId = t.ContactId
            WHERE t.TicketRef = @Ref;
            """, ("@Ref", ticketRef));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    public static DataTable TimeEntries(AdminDb db, string ticketRef) => db.Query("""
        SELECT e.WorkStart AS Started, e.Minutes, e.RateType AS Rate, CASE WHEN e.IsBillable = 1 THEN 'Yes' ELSE 'No' END AS Billable,
               inv.InvoiceNo AS Invoiced, e.Description
        FROM dbo.TimeEntry e JOIN dbo.Ticket t ON t.TicketId = e.TicketId LEFT JOIN dbo.Invoice inv ON inv.InvoiceId = e.InvoiceId
        WHERE t.TicketRef = @Ref ORDER BY e.WorkStart;
        """, ("@Ref", ticketRef));

    public static DataTable Invoices(AdminDb db, string filter) => db.Query("""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        SELECT TOP (500) i.InvoiceNo AS Invoice, c.ClientName AS Client, a.AgreementRef AS Agreement, i.InvoiceDate AS Dated, i.DueDate AS Due,
               i.Total, CASE WHEN i.Status = 'Sent' AND i.DueDate < @Today THEN 'OVERDUE' ELSE i.Status END AS Status,
               i.SentAt AS Sent, i.PaidAt AS Paid
        FROM dbo.Invoice i JOIN dbo.Agreement a ON a.AgreementId = i.AgreementId JOIN dbo.Client c ON c.ClientId = a.ClientId
        WHERE @Filter = 'All' OR (@Filter = 'Outstanding' AND i.Status IN ('Draft', 'Sent'))
        ORDER BY i.InvoiceDate DESC, i.InvoiceNo DESC;
        """, ("@Filter", filter));

    public static DataTable InvoiceLines(AdminDb db, string invoiceNo) => db.Query("""
        SELECT l.LineType AS Type, l.Description, l.Quantity AS Qty, l.UnitPrice AS Price, l.Amount
        FROM dbo.InvoiceLine l JOIN dbo.Invoice i ON i.InvoiceId = l.InvoiceId
        WHERE i.InvoiceNo = @No ORDER BY l.InvoiceLineId;
        """, ("@No", invoiceNo));
}
