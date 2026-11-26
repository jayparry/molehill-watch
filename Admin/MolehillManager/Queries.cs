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

    /// <summary>"MWA-0001 - Client" for pickers.</summary>
    public static List<string> AgreementChoices(AdminDb db) =>
        db.Query("""
            SELECT a.AgreementRef + ' - ' + c.ClientName FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
            WHERE a.EndDate IS NULL OR a.EndDate >= DATEADD(day, -90, CAST(dbo.fn_UkNow() AS date))
            ORDER BY c.ClientName, a.StartDate;
            """).Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();

    public static string RefFromChoice(string choice) => choice.Split(" - ", 2)[0].Trim();

    /// <summary>
    ///   True while an invoice can still be changed. This gates adding, removing and adjusting
    ///   lines, so it belongs with the other reads rather than inside the screen that asks.
    /// </summary>
    public static bool IsDraftInvoice(AdminDb db, string invoiceNo) =>
        db.Scalar("SELECT 1 FROM dbo.Invoice WHERE InvoiceNo = @No AND Status = 'Draft';", ("@No", invoiceNo)) != null;

    /// <summary>
    ///   The agreement to open for a client named on a dashboard alert: the one still running,
    ///   otherwise the one that ran most recently. Null when the client has none.
    /// </summary>
    public static string? AgreementRefForClient(AdminDb db, string clientName) =>
        db.Scalar("""
            SELECT TOP (1) a.AgreementRef FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
            WHERE c.ClientName = @Client ORDER BY CASE WHEN a.EndDate IS NULL THEN 0 ELSE 1 END, a.StartDate DESC;
            """, ("@Client", clientName)) as string;

    /// <summary>
    ///   What the agreement's covered instances come to a month, as the database works it out for
    ///   the Clients tab and for the dashboard. The summary used to add the Fee column up itself,
    ///   which was a second implementation of a figure that goes on invoices.
    /// </summary>
    public static decimal AgreementMonthlyFee(AdminDb db, string agreementRef) =>
        db.Scalar("""
            DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
            SELECT ISNULL((SELECT SUM(f.MonthlyFee) FROM dbo.fn_AgreementFees(a.AgreementId,
                               CASE WHEN a.StartDate > @Today THEN a.StartDate ELSE @Today END) f), 0)
            FROM dbo.Agreement a WHERE a.AgreementRef = @Ref;
            """, ("@Ref", agreementRef)) as decimal? ?? 0m;

    /// <summary>Included hours used this cycle. The screens ask through here, not by name.</summary>
    public static ProcResult AgreementUsage(AdminDb db, string agreementRef) =>
        db.Proc("dbo.usp_Agreement_Usage", ("@Client", agreementRef));

    /// <summary>The onboarding checklist and version status.</summary>
    public static ProcResult OnboardingShow(AdminDb db, string agreementRef) =>
        db.Proc("dbo.usp_Onboarding_Show", ("@Client", agreementRef));

    /// <summary>
    ///   The dashboard's five result sets, each by name. The screen used to take the alerts from
    ///   the first, the open-ticket count from the second's row count and the money from whichever
    ///   set happened to carry a MonthlyRecurringRevenue column - three assumptions about the order
    ///   a procedure returns things in, none of them written down.
    /// </summary>
    public static DashboardView Dashboard(AdminDb db)
    {
        var r = db.Proc("dbo.usp_Dashboard");
        if (r.Tables.Count < 5)
            throw new InvalidOperationException(
                $"dbo.usp_Dashboard returned {r.Tables.Count} result sets, not the five expected "
                + "(alerts, open tickets, agreements, engagements, money). The database may need upgrading.");
        var money = r.Tables[4];
        return new DashboardView(r.Tables[0], r.Tables[1], r.Tables[2], r.Tables[3],
            money.Rows.Count > 0 ? money.Rows[0] : null);
    }

    public static List<string> ClientNames(AdminDb db) =>
        db.Query("SELECT ClientName FROM dbo.Client ORDER BY ClientName;").Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();

    /// <summary>Quotes and where each one got to. Nothing read dbo.Quote at all before 2.8.0.</summary>
    public static DataTable Quotes(AdminDb db, string? clientName = null, bool openOnly = false) =>
        db.Proc("dbo.usp_Quote_List", ("@Client", clientName), ("@OpenOnly", openOnly)).First ?? new DataTable();

    public static List<string> PriceLists(AdminDb db) =>
        db.Query("SELECT Name FROM dbo.PriceList ORDER BY EffectiveFrom DESC, Name;").Rows.Cast<DataRow>().Select(r => (string)r[0]).ToList();

    public static List<string> InstanceNames(AdminDb db, string agreementRef) =>
        db.Query("""
            SELECT i.InstanceName FROM dbo.AgreementInstance ai
            JOIN dbo.Instance i ON i.InstanceId = ai.InstanceId
            JOIN dbo.Agreement a ON a.AgreementId = ai.AgreementId
            WHERE a.AgreementRef = @Ref AND ai.CoveredTo IS NULL ORDER BY i.InstanceName;
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
               p.StartsOn AS [From], p.ExpiresOn AS [Use by], p.State,
               CASE WHEN i.InvoiceNo IS NOT NULL THEN 'invoiced'
                    WHEN p.BillingMethod = 'NextCycle' THEN 'on the next monthly invoice'
                    WHEN p.BillingMethod = 'OwnInvoice' THEN 'to be invoiced on its own'
                    ELSE 'not invoiced' END AS Charging,
               i.InvoiceNo AS Invoice, i.Status AS [Invoice status], p.Notes
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
               CASE WHEN ai.CoveredTo IS NOT NULL AND ai.CoveredTo < @AsOf THEN 'Removed ' + CONVERT(varchar(11), ai.CoveredTo, 106)
                    WHEN ai.CoveredTo IS NOT NULL THEN 'Ends ' + CONVERT(varchar(11), ai.CoveredTo, 106)
                    WHEN ai.CoveredFrom > @AsOf THEN 'From ' + CONVERT(varchar(11), ai.CoveredFrom, 106) ELSE 'Covered' END AS Cover,
               i.MonitoringInstalledDate AS Monitoring,
               CASE WHEN i.Platform IN ('AzureSqlDatabaseServer', 'AzureSqlDatabaseElasticPool', 'AzureSqlManagedInstance') THEN 'Microsoft-managed'
                    WHEN l.ExtendedEnd < @Today AND i.UnsupportedRiskAcceptedDate IS NOT NULL THEN 'Unsupported, risk accepted'
                    WHEN l.ExtendedEnd < @Today THEN 'UNSUPPORTED'
                    WHEN l.ExtendedEnd IS NULL THEN '?' ELSE 'Supported' END AS Lifecycle,
               f.PricingBasis AS Basis
        -- One row per SERVER, not per coverage. A server repriced part-way through has more than
        -- one coverage row, and listing both would show it twice and double its fee in any total -
        -- which is exactly what the write suite caught. The coverage in force at @AsOf wins; where
        -- none is, the most recent one is shown so a removed server still appears.
        FROM dbo.Instance i
        JOIN (SELECT InstanceId, AgreementId, CoveredFrom, CoveredTo,
                     Pick = ROW_NUMBER() OVER (PARTITION BY InstanceId
                            ORDER BY CASE WHEN CoveredFrom <= @AsOf AND (CoveredTo IS NULL OR CoveredTo >= @AsOf) THEN 0 ELSE 1 END,
                                     CoveredFrom DESC)
              FROM dbo.AgreementInstance WHERE AgreementId = @AgreementId) ai
          ON ai.InstanceId = i.InstanceId AND ai.Pick = 1
        LEFT JOIN dbo.fn_AgreementFees(@AgreementId, @AsOf) f ON f.InstanceId = i.InstanceId
        LEFT JOIN dbo.ProductLifecycle l ON l.VersionKey = i.SqlVersion
        ORDER BY CASE WHEN ai.CoveredTo < @AsOf THEN 1 ELSE 0 END, i.InstanceName;
        """, ("@Ref", agreementRef));

    public static DataRow? Instance(AdminDb db, string agreementRef, string instanceName)
    {
        var t = db.Query("""
            SELECT TOP (1) i.* FROM dbo.Instance i
            JOIN dbo.Agreement a ON a.ClientId = i.ClientId
            WHERE a.AgreementRef = @Ref AND i.InstanceName = @Name
            ORDER BY CASE WHEN i.CoveredTo IS NULL THEN 0 ELSE 1 END, i.InstanceId;
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
        JOIN dbo.AgreementInstance ai ON ai.InstanceId = i.InstanceId
        JOIN dbo.Agreement a ON a.AgreementId = ai.AgreementId
        LEFT JOIN dbo.Ticket t ON t.TicketId = w.FollowUpTicketId
        WHERE a.AgreementRef = @Ref ORDER BY w.WeekEnding DESC, i.InstanceName;
        """, ("@Ref", agreementRef));

    public static DataTable Tickets(AdminDb db, bool openOnly, string? agreementRef = null) => db.Query("""
        SELECT TOP (500) t.TicketRef AS Ticket, c.ClientName AS Client, t.Severity, t.Status, t.WorkType AS Type,
               dbo.fn_RateBandName(t.RateType) AS Rate, t.Title,
               i.InstanceName AS Instance, t.RaisedAt AS Raised, t.ResponseDueAt AS ResponseDue, t.FirstResponseAt AS Responded,
               CAST(ISNULL((SELECT SUM(Minutes) FROM dbo.TimeEntry e WHERE e.TicketId = t.TicketId), 0) / 60.0 AS decimal(6,2)) AS Hours,
               t.EstimateHours AS Estimate, CASE WHEN t.EstimateApprovedAt IS NOT NULL THEN 'Yes' END AS Approved
        FROM dbo.Ticket t JOIN dbo.Client c ON c.ClientId = t.ClientId
        LEFT JOIN dbo.Agreement a ON a.EngagementId = t.EngagementId
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
            FROM dbo.Ticket t JOIN dbo.Client c ON c.ClientId = t.ClientId
            LEFT JOIN dbo.Agreement a ON a.EngagementId = t.EngagementId
            LEFT JOIN dbo.Instance i ON i.InstanceId = t.InstanceId LEFT JOIN dbo.Contact ct ON ct.ContactId = t.ContactId
            WHERE t.TicketRef = @Ref;
            """, ("@Ref", ticketRef));
        return t.Rows.Count == 0 ? null : t.Rows[0];
    }

    public static DataTable TimeEntries(AdminDb db, string ticketRef) => db.Query("""
        SELECT e.TimeEntryId AS Id, e.WorkStart AS Started, e.Minutes, e.RateType AS Rate, CASE WHEN e.IsBillable = 1 THEN 'Yes' ELSE 'No' END AS Billable,
               CASE WHEN inv.InvoiceNo IS NOT NULL THEN inv.InvoiceNo
                    WHEN dbo.fn_IsBillableWhen(t.EngagementId, e.WorkStart) = 0 THEN 'NEVER - outside the billing period'
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
               i.SentAt AS Sent, i.PaidAt AS Paid,
               CAST(CASE WHEN i.Status = 'Draft' THEN 1 ELSE 0 END AS bit) AS _IsDraft
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
                    THEN CONVERT(nvarchar(10), (SELECT COUNT(*) FROM dbo.AgreementInstance ai WHERE ai.AgreementId = a.AgreementId AND ai.CoveredTo IS NULL))
                         + ' instance(s) monitored'
                    ELSE e.Name END AS [What],
               CASE WHEN e.EngagementType = 'Monitoring' THEN {AgreementStatus} ELSE e.Status END AS Status,
               CASE e.BillingMode
                    WHEN 'AgreementCycle' THEN NCHAR(163) + FORMAT(ISNULL((SELECT SUM(MonthlyFee) FROM dbo.fn_AgreementFees(a.AgreementId,
                             CASE WHEN a.StartDate > @Today THEN a.StartDate ELSE @Today END)), 0), 'N0') + '/month'
                    WHEN 'DayRate'    THEN NCHAR(163) + FORMAT(e.DayRate, 'N0') + '/day'
                    WHEN 'Hourly'     THEN NCHAR(163) + FORMAT(e.HourlyRate, 'N0') + '/hour'
                    WHEN 'PerInstance' THEN NCHAR(163) + FORMAT(e.UnitTotal, 'N0') + '/'
                         + CONVERT(nvarchar(10), ISNULL(e.UnitCount, 1)) + ' inst'
                    ELSE NCHAR(163) + FORMAT(e.FixedPrice, 'N0') + ' fixed' END AS Rate,
               CASE WHEN e.EngagementType = 'Monitoring'
                    THEN NULLIF(FORMAT(ISNULL((SELECT SUM(te.Minutes) / 60.0 FROM dbo.TimeEntry te
                                               WHERE te.EngagementId = e.EngagementId AND te.IsBillable = 1 AND te.InvoiceId IS NULL), 0), 'N2') + ' h', '0.00 h')
                    ELSE NULLIF(NCHAR(163) + FORMAT(ISNULL(u.Value, 0), 'N0') + ' (' + FORMAT(ISNULL(u.Days, 0), 'N2') + ' d)', NCHAR(163) + '0 (0.00 d)')
                    END AS Unbilled,
               (SELECT COUNT(*) FROM dbo.Ticket t WHERE t.EngagementId = e.EngagementId AND t.Status NOT IN ('Resolved', 'Closed')) AS OpenTickets,
               (SELECT COUNT(*) FROM dbo.OnboardingItem o WHERE o.AgreementId = a.AgreementId AND o.IsRequired = 1 AND o.CompletedDate IS NULL) AS OnboardingLeft,
               e.EngagementType AS _EngagementType
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
                   e.FixedPrice, e.UnitCount, e.FirstUnitPrice, e.ExtraUnitPrice, e.PriceCap, e.UnitTotal,
                   e.DayRounding, e.PurchaseOrder, e.Status, e.StartDate, e.EndDate, e.CompletedOn, e.Notes,
                   (SELECT STRING_AGG(ct.FullName + ISNULL(N' <' + ct.Email + N'>', N' (no e-mail)'), N'; ') FROM dbo.Contact ct
                    WHERE ct.ClientId = c.ClientId AND ct.IsActive = 1 AND ct.IsBillingContact = 1) AS InvoicesTo,
                   ISNULL(u.Days, 0) AS UnbilledDays, ISNULL(u.Value, 0) AS UnbilledValue, u.LastWorked,
                   CASE WHEN e.BillingMode IN ('FixedPrice', 'PerInstance') THEN NULL
                        ELSE DATEADD(day, -1, dbo.fn_ConsultancyPeriodStart(e.StartDate,
                             dbo.fn_ConsultancyPeriod(e.StartDate, CAST(dbo.fn_UkNow() AS date), dbo.fn_EngagementBillingDays(e.EngagementId)) + 1,
                             dbo.fn_EngagementBillingDays(e.EngagementId))) END AS PeriodEndsOn,
                   dbo.fn_EngagementBillingDays(e.EngagementId) AS BillingEveryDays,
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
        SELECT w.WorkDate AS [Date], dbo.fn_RateBandName(w.RateType) AS Rate,
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
               dbo.fn_RateBandName(e.RateType) AS Rate,
               CASE WHEN e.IsBillable = 1 THEN 'Yes' ELSE 'No' END AS Billable,
               ISNULL(i.InvoiceNo, CASE WHEN e.IsBillable = 1 THEN 'at the next billing run' ELSE 'not billable' END) AS Invoiced,
               e.Description, e.InvoiceId AS _InvoiceId
        FROM dbo.TimeEntry e JOIN dbo.Engagement g ON g.EngagementId = e.EngagementId
        LEFT JOIN dbo.Invoice i ON i.InvoiceId = e.InvoiceId
        WHERE g.EngagementRef = @Ref ORDER BY e.WorkStart DESC, e.TimeEntryId DESC;
        """, ("@Ref", engagementRef));

    public static DataTable EngagementInvoices(AdminDb db, string engagementRef) => db.Query("""
        DECLARE @Today date = CAST(dbo.fn_UkNow() AS date);
        SELECT i.InvoiceNo AS Invoice, i.InvoiceDate AS Dated, i.DueDate AS Due, i.Total,
               CASE WHEN i.Status = 'Sent' AND i.DueDate < @Today THEN 'OVERDUE' ELSE i.Status END AS Status,
               i.SentAt AS Sent, i.PaidAt AS Paid,
               -- the rule is "only a draft can be changed", and the Status column above is not it:
               -- an overdue invoice reads OVERDUE rather than Sent, and it is formatted besides
               CAST(CASE WHEN i.Status = 'Draft' THEN 1 ELSE 0 END AS bit) AS _IsDraft
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

/// <summary>
///   What <c>dbo.usp_Dashboard</c> returns, named rather than numbered. Money is the one row of the
///   last set, or null when the database has nothing to report yet.
/// </summary>
public sealed record DashboardView(
    DataTable Alerts, DataTable OpenTickets, DataTable Agreements, DataTable Engagements, DataRow? Money)
{
    public int OpenTicketCount => OpenTickets.Rows.Count;

    /// <summary>A money figure by name, or null when the database does not report it.</summary>
    public decimal? Amount(string column) =>
        Money is not null && Money.Table.Columns.Contains(column) && Money[column] is decimal d ? d : null;
}
