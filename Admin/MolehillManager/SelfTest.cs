using System.Data;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>Headless checks: every screen and form against a real MolehillAdmin, with a fake console.</summary>
public static class SelfTest
{
    private static int _pass, _fail;

    static SelfTest() => Console.OutputEncoding = System.Text.Encoding.UTF8;

    private static void Check(string name, bool ok, string detail = "")
    {
        if (ok) _pass++; else _fail++;
        Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {name}{(detail == "" ? "" : "  -  " + detail)}");
    }

    private static T? Step<T>(string name, Func<T> action, Func<T, string?>? verify = null)
    {
        try
        {
            var result = action();
            var problem = verify?.Invoke(result);
            Check(name, problem == null, problem ?? "");
            return result;
        }
        catch (Exception ex)
        {
            Check(name, false, (ex is FormatException ? ex.Message : AdminDb.Describe(ex)).Replace("\n", " | "));
            return default;
        }
    }

    private static void ExpectError(string name, Action action, string mustContain)
    {
        try
        {
            action();
            Check(name, false, "no error raised");
        }
        catch (Exception ex)
        {
            var msg = ex is FormatException ? ex.Message : AdminDb.Describe(ex);
            Check(name, msg.Contains(mustContain, StringComparison.OrdinalIgnoreCase), msg.Replace("\n", " | "));
        }
    }

    private static int Finish()
    {
        Console.WriteLine();
        Console.WriteLine($"{_pass} passed, {_fail} failed.");
        return _fail == 0 ? 0 : 2;
    }

    /// <summary>Builds the main window, every agreement window and every form. Read-only.</summary>
    public static int Ui(AdminDb db)
    {
        Application.Init(new FakeDriver(), null);
        try
        {
            RunUi(db);
        }
        finally
        {
            Application.Shutdown();
        }
        return Finish();
    }

    private static void RunUi(AdminDb db)
    {
        Step("main window builds and loads every tab", () => { new MainWindow(db).Build(Application.Top); return 0; });
        Step("dashboard returns its 4 result sets", () => db.Proc("dbo.usp_Dashboard"), r => r.Tables.Count == 4 ? null : $"{r.Tables.Count} sets");

        var agreements = Queries.Agreements(db, includeEnded: true);
        Check("agreements query", true, $"{agreements.Rows.Count} agreement(s)");
        foreach (DataRow a in agreements.Rows)
        {
            var reference = (string)a["Ref"];
            Step($"agreement window {reference}", () => new AgreementWindow(db, reference).Build());
            Step($"summary {reference}", () => AgreementWindow.Summary(db, reference, includeInstances: true), s => s.Contains("not found") ? s : null);
        }

        // every form builds as a dialog, using real data where the form needs a selection
        var anyRef = agreements.Rows.Count > 0 ? (string)agreements.Rows[0]["Ref"] : "MWA-0000";
        var anyClient = agreements.Rows.Count > 0 ? (string)agreements.Rows[0]["Client"] : "Client";
        var anyInstance = agreements.Rows.Count > 0 ? Queries.InstanceNames(db, anyRef).FirstOrDefault() ?? "SQL01" : "SQL01";
        var tickets = Queries.Tickets(db, openOnly: false);
        var anyTicket = tickets.Rows.Count > 0 ? (string)tickets.Rows[0]["Ticket"] : "MW-00001";
        var invoices = Queries.Invoices(db, "All");
        var anyInvoice = invoices.Rows.Count > 0 ? (string)invoices.Rows[0]["Invoice"] : "INV-0001";

        foreach (var spec in AllForms(db, anyRef, anyClient, anyInstance, anyTicket, anyInvoice))
            Step($"form '{spec.Title}' builds", () => { using var d = FormDialog.Create(spec, out _); return 0; });

        if (tickets.Rows.Count > 0) Step($"ticket detail {anyTicket}", () => TicketActions.Describe(db, anyTicket));
        if (invoices.Rows.Count > 0) Step($"invoice lines {anyInvoice}", () => Queries.InvoiceLines(db, anyInvoice));

        // MM_SCREENS=<file>: render the screens into the fake console and write them out as text, for checking layout
        var dump = Environment.GetEnvironmentVariable("MM_SCREENS");
        if (!string.IsNullOrEmpty(dump)) DumpScreens(db, dump, anyRef, AllForms(db, anyRef, anyClient, anyInstance, anyTicket, anyInvoice));
    }

    private static string Screen()
    {
        var driver = (FakeDriver)Application.Driver;
        var contents = driver.Contents;
        var sb = new System.Text.StringBuilder();
        for (var r = 0; r < contents.GetLength(0); r++)
        {
            var line = new System.Text.StringBuilder();
            for (var c = 0; c < contents.GetLength(1); c++) line.Append(char.ConvertFromUtf32(Math.Max(32, contents[r, c, 0])));
            sb.AppendLine(line.ToString().TrimEnd());
        }
        return sb.ToString();
    }

    private static void Render(View view)
    {
        view.LayoutSubviews();
        view.Redraw(view.Bounds);
    }

    private static void DumpScreens(AdminDb db, string path, string reference, IEnumerable<FormSpec> forms)
    {
        FakeConsole.SetBufferSize(132, 40);
        FakeConsole.SetWindowSize(132, 40);
        ((FakeDriver)Application.Driver).SetBufferSize(132, 40);
        var sb = new System.Text.StringBuilder();
        var top = new Toplevel();
        top.Frame = new Rect(0, 0, 132, 40);
        Application.Driver.Clip = new Rect(0, 0, 132, 40);
        var main = new MainWindow(db);
        main.Build(top);
        var tabs = FindAll<TabView>(top).First();
        foreach (var tab in tabs.Tabs.ToList())
        {
            tabs.SelectedTab = tab;
            Render(top);
            sb.AppendLine($"===== main: {tab.Text}").AppendLine(Screen());
        }
        var agreement = new AgreementWindow(db, reference).Build();
        agreement.X = 0; agreement.Y = 0; agreement.Width = 131; agreement.Height = 39;
        var inner = FindAll<TabView>(agreement).First();
        foreach (var tab in inner.Tabs.ToList())
        {
            inner.SelectedTab = tab;
            agreement.Frame = new Rect(0, 0, 131, 39);
            Render(agreement);
            sb.AppendLine($"===== agreement: {tab.Text}").AppendLine(Screen());
        }
        foreach (var spec in forms)
        {
            var d = FormDialog.Create(spec, out _);
            d.Frame = new Rect(0, 0, 98, Math.Min(38, spec.Fields.Sum(f => f.Kind == FieldKind.Memo ? 4 : 1) + 10));
            Application.Driver.Clip = new Rect(0, 0, 132, 40);
            Render(d);
            sb.AppendLine($"===== form: {spec.Title}").AppendLine(Screen());
        }
        File.WriteAllText(path, sb.ToString());
        Console.WriteLine($"Screens written to {path}");
    }

    private static IEnumerable<T> FindAll<T>(View root) where T : View
    {
        foreach (var v in root.Subviews)
        {
            if (v is T t) yield return t;
            foreach (var x in FindAll<T>(v)) yield return x;
        }
    }

    private static IEnumerable<FormSpec> AllForms(AdminDb db, string reference, string client, string instance, string ticket, string invoice) => new[]
    {
        AdminForms.NewClient(db), AdminForms.NewAgreement(db), AdminForms.AddContact(db, client),
        AdminForms.AddInstance(db, reference), AdminForms.UpdateInstance(db, reference, instance), AdminForms.RemoveInstance(db, reference, instance),
        AdminForms.RiskAcceptance(db, reference, instance), AdminForms.WeeklyReport(db, reference, instance),
        AdminForms.CompleteOnboarding(db, reference, "REMOTE_ACCESS", "Remote access"), AdminForms.RecordReview(db, reference),
        AdminForms.GiveNotice(db, reference), AdminForms.PauseSupport(db, reference, true), AdminForms.PauseSupport(db, reference, false),
        AdminForms.PriceChange(db), AdminForms.AddQuote(db, reference), AdminForms.OpenTicket(db, reference),
        AdminForms.RespondTicket(db, ticket), AdminForms.EstimateTicket(db, ticket), AdminForms.LogTime(db, ticket), AdminForms.CloseTicket(db, ticket),
        AdminForms.RunBilling(db), AdminForms.AdjustInvoice(db, invoice), AdminForms.SetInvoiceStatus(db, invoice, "Paid")
    };

    /// <summary>Fills in and submits every form, exactly as the dialogs do, against a test database.</summary>
    public static int Write(AdminDb db)
    {
        var stamp = DateTime.Now.ToString("MMddHHmmss");
        var name = $"Selftest Ltd {stamp}";
        var reference = $"ST-{stamp}";
        var start = DateTime.Today.AddDays(-40);   // so billing has a started cycle, and an ended one for arrears
        string D(DateTime d) => d.ToString("yyyy-MM-dd");

        FormValues Fill(FormSpec spec, params (string Field, string Value)[] values)
        {
            var v = spec.NewValues();
            foreach (var (f, value) in values) v[f] = value;
            return v;
        }
        ProcResult Submit(FormSpec spec, params (string, string)[] values) => spec.Execute(Fill(spec, values));

        Console.WriteLine($"Writing test data as '{name}' ({reference}).");
        Console.WriteLine();

        Step("new client + contact + agreement", () => Submit(AdminForms.NewClient(db),
                ("ClientName", name), ("BillingEmail", "accounts@selftest.example"), ("ContactName", "Pat Tester"),
                ("ContactEmail", "pat@selftest.example"), ("ContactIsBilling", "1"), ("StartDate", D(start)),
                ("SignedDate", D(start.AddDays(-7))), ("AgreementRef", reference)),
            r => r.Tables.Any(t => t.Columns.Contains("AgreementRef") && t.Rows.Count == 1 && (string)t.Rows[0]["AgreementRef"] == reference) ? null : "agreement not returned");

        ExpectError("duplicate client is refused before touching the database",
            () => Submit(AdminForms.NewClient(db), ("ClientName", name), ("StartDate", D(start))), "already exists");
        ExpectError("required field is enforced", () => Submit(AdminForms.AddInstance(db, reference)), "Name is required");
        ExpectError("bad number is caught", () => Submit(AdminForms.AddInstance(db, reference), ("InstanceName", "X"), ("DatabaseCount", "lots")), "not a whole number");

        Step("add contact", () => Submit(AdminForms.AddContact(db, name), ("FullName", "Sam Second"), ("Email", "sam@selftest.example")));

        var add = () => AdminForms.AddInstance(db, reference);
        Step("add SQL Server standalone", () => Submit(add(), ("InstanceName", "ST-SQL01"), ("SqlVersion", "2019"), ("Edition", "Standard")));
        Step("add AG primary", () => Submit(add(), ("InstanceName", "ST-SQL02"), ("Role", "AGPrimary"), ("AvailabilityGroup", "AG1"), ("SqlVersion", "2022")));
        Step("add AG secondary", () => Submit(add(), ("InstanceName", "ST-SQL03"), ("Role", "AGSecondary"), ("PrimaryInstanceName", "ST-SQL02"), ("AvailabilityGroup", "AG1"), ("SqlVersion", "2022")));
        Step("add Azure SQL Managed Instance", () => Submit(add(), ("InstanceName", "st-mi01"), ("Platform", "AzureSqlManagedInstance"), ("Edition", "General Purpose")));
        Step("add Azure SQL Database server, 8 databases", () => Submit(add(), ("InstanceName", "st-sqldb"), ("Platform", "AzureSqlDatabaseServer"), ("DatabaseCount", "8")));
        Step("add Azure SQL Database geo-replica", () => Submit(add(), ("InstanceName", "st-sqldb-dr"), ("Platform", "AzureSqlDatabaseServer"), ("Role", "GeoReplica"), ("PrimaryInstanceName", "st-sqldb")));
        Step("add non-production at an agreed fee", () => Submit(add(), ("InstanceName", "ST-DEV01"), ("Environment", "NonProduction"), ("AgreedMonthlyFee", "95.50"), ("SqlVersion", "2022")));
        ExpectError("Azure SQL Database without a database count is refused", () => Submit(add(), ("InstanceName", "st-pool"), ("Platform", "AzureSqlDatabaseElasticPool")), "database");
        ExpectError("non-production without a fee is refused", () => Submit(add(), ("InstanceName", "ST-DEV02"), ("Environment", "NonProduction")), "@AgreedMonthlyFee");

        Step("update Azure database count to 9", () => Submit(AdminForms.UpdateInstance(db, reference, "st-sqldb"), ("DatabaseCount", "9")));
        Step("update keeps untouched fields", () => Queries.Instance(db, reference, "ST-SQL01")!,
            r => (string)r["Edition"] == "Standard" ? null : $"edition is {r["Edition"]}");
        Step("update monitoring date", () => Submit(AdminForms.UpdateInstance(db, reference, "ST-SQL01"), ("MonitoringInstalledDate", D(start))));

        // pricing, straight from the price list the agreement is on
        var fees = Queries.Instances(db, reference);
        var price = db.Query("SELECT p.* FROM dbo.Agreement a JOIN dbo.PriceList p ON p.PriceListId = a.PriceListId WHERE a.AgreementRef = @r", ("@r", reference)).Rows[0];
        decimal Fee(string inst) => fees.Rows.Cast<DataRow>().Where(r => (string)r["Instance"] == inst).Select(r => r["Fee"] is decimal d ? d : -1m).FirstOrDefault(-1m);
        var unit = (decimal)price["AzureSqlDbUnitFee"];
        var extra = (decimal)price["AzureSqlDbExtraDatabaseFee"];
        var included = (int)price["AzureSqlDbIncludedDatabases"];
        Check("Azure SQL Database fee = unit + extra databases", Fee("st-sqldb") == unit + (9 - included) * extra, $"£{Fee("st-sqldb")}");
        Check("geo-replica is included", Fee("st-sqldb-dr") == 0, $"£{Fee("st-sqldb-dr")}");
        Check("Managed Instance priced as the 3rd server (multi-server rate)", Fee("st-mi01") == (decimal)price["ServerFeeTiered"], $"£{Fee("st-mi01")}");
        Check("AG secondary at the secondary rate", Fee("ST-SQL03") == (decimal)price["SecondaryReplicaFee"], $"£{Fee("ST-SQL03")}");
        Check("agreed fee used for non-production", Fee("ST-DEV01") == 95.50m, $"£{Fee("ST-DEV01")}");

        Step("onboarding item done", () => Submit(AdminForms.CompleteOnboarding(db, reference, "REMOTE_ACCESS", ""), ("Notes", "VPN")));
        Step("onboarding recorded", () => Queries.Onboarding(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Code"] == "REMOTE_ACCESS" && r["Done"] is DateTime) ? null : "not marked done");
        Step("named contact auto-completed", () => Queries.Onboarding(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Code"] == "NAMED_CONTACT" && r["Done"] is DateTime) ? null : "not marked done");
        Step("initial review", () => Submit(AdminForms.RecordReview(db, reference), ("Notes", "Delivered")));
        Step("risk acceptance", () => Submit(AdminForms.RiskAcceptance(db, reference, "ST-SQL01"), ("AcceptedBy", "Pat Tester")));
        Step("weekly report", () => Submit(AdminForms.WeeklyReport(db, reference, "ST-SQL01"), ("OverallStatus", "Amber"), ("WarningCount", "2")));
        Step("weekly report recorded", () => Queries.WeeklyReports(db, reference), t => t.Rows.Count == 1 ? null : $"{t.Rows.Count} rows");

        // a ticket through its whole life
        var raised = start.AddDays(3).Date.AddHours(10);
        while (raised.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday) raised = raised.AddDays(1);
        var opened = Step("open ticket", () => Submit(AdminForms.OpenTicket(db, reference),
            ("Title", "Slow queries"), ("Severity", "Critical"), ("InstanceName", "ST-SQL01"), ("RaisedAt", raised.ToString("yyyy-MM-dd HH:mm")),
            ("Description", "Reports timing out")), r => r.First is { Rows.Count: 1 } ? null : "no ticket returned");
        var ticket = opened?.First?.Rows[0]["TicketRef"] as string ?? "MW-?";
        Step("respond", () => Submit(AdminForms.RespondTicket(db, ticket), ("RespondedAt", raised.AddMinutes(30).ToString("yyyy-MM-dd HH:mm"))));
        Step("estimate sent", () => Submit(AdminForms.EstimateTicket(db, ticket), ("EstimateHours", "3")));
        Step("estimate approved", () => Submit(AdminForms.EstimateTicket(db, ticket), ("Approved", "1")));
        Step("log 90 minutes, rate worked out", () => Submit(AdminForms.LogTime(db, ticket), ("Minutes", "90"), ("Description", "Index review"),
            ("WorkStart", raised.AddHours(1).ToString("yyyy-MM-dd HH:mm"))));
        Step("log 30 minutes out of hours, forced rate", () => Submit(AdminForms.LogTime(db, ticket), ("Minutes", "30"), ("Description", "Evening check"),
            ("WorkStart", raised.Date.AddHours(20).ToString("yyyy-MM-dd HH:mm")), ("RateType", "OutOfHours")));
        Step("time recorded", () => Queries.TimeEntries(db, ticket), t => t.Rows.Count == 2 && (string)t.Rows[0]["Rate"] == "BusinessHours" ? null : "wrong entries");
        Step("close", () => Submit(AdminForms.CloseTicket(db, ticket), ("Resolution", "Added two indexes")));
        Step("ticket detail", () => TicketActions.Describe(db, ticket), s => s.Contains("Added two indexes") && s.Contains("Index review") ? null : "detail incomplete");
        Step("project quote", () => Submit(AdminForms.AddQuote(db, reference), ("Title", "Upgrade to 2022"), ("EstimatedHours", "12"), ("TicketRef", ticket)));

        // billing
        var billed = Step("run billing for the agreement", () => Submit(AdminForms.RunBilling(db),
                ("Client", Queries.AgreementChoices(db).First(c => Queries.RefFromChoice(c) == reference))),
            r => r.First is { Rows.Count: > 0 } ? null : "no invoices created");
        var invoice = billed?.First?.Rows[0]["InvoiceNo"] as string ?? "?";
        Step("first invoice charges the first month (instances named during onboarding)", () => Queries.InvoiceLines(db, invoice),
            t => t.Rows.Cast<DataRow>().Count(r => (string)r["Type"] == "MonthlyFee") == 7 ? null : $"{t.Rows.Cast<DataRow>().Count(r => (string)r["Type"] == "MonthlyFee")} fee lines");
        Step("instance added after the first invoice is covered from today", () => { Submit(add(), ("InstanceName", "ST-SQL04")); return Queries.Instance(db, reference, "ST-SQL04")!; },
            r => (DateTime)r["CoveredFrom"] == DateTime.Today ? null : $"covered from {r["CoveredFrom"]}");
        Step("billing again creates nothing", () => Submit(AdminForms.RunBilling(db),
                ("Client", Queries.AgreementChoices(db).First(c => Queries.RefFromChoice(c) == reference))),
            r => r.First is { Rows.Count: 0 } ? null : $"{r.First?.Rows.Count} more invoice(s)");
        Step("adjustment", () => Submit(AdminForms.AdjustInvoice(db, invoice), ("Description", "Goodwill credit"), ("Amount", "-10")));
        Step("invoice lines include the credit", () => Queries.InvoiceLines(db, invoice),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Type"] == "Adjustment" && (decimal)r["Amount"] == -10m) ? null : "no adjustment line");
        var folder = Path.Combine(Path.GetTempPath(), "MolehillManager-selftest");
        Step("invoice HTML saved", () => AdminForms.SaveInvoiceHtml(db, invoice, folder), p => File.ReadAllText(p).Contains(invoice) ? null : "HTML lacks invoice number");
        Step("dashboard HTML saved", () => AdminForms.SaveDashboardHtml(db, folder), p => File.ReadAllText(p).Contains("<html", StringComparison.OrdinalIgnoreCase) ? null : "not HTML");
        Step("mark sent", () => Submit(AdminForms.SetInvoiceStatus(db, invoice, "Sent")));
        Step("mark paid", () => Submit(AdminForms.SetInvoiceStatus(db, invoice, "Paid")));
        Step("invoice is paid", () => Queries.Invoices(db, "All"), t => t.Rows.Cast<DataRow>().Any(r => (string)r["Invoice"] == invoice && (string)r["Status"] == "Paid") ? null : "not paid");
        ExpectError("adjusting a paid invoice is refused", () => Submit(AdminForms.AdjustInvoice(db, invoice), ("Description", "x"), ("Amount", "1")), "draft");

        // agreement lifecycle
        Step("pause support", () => Submit(AdminForms.PauseSupport(db, reference, true)));
        Step("summary shows paused", () => AgreementWindow.Summary(db, reference, false), s => s.Contains("SUPPORT PAUSED") ? null : "not shown");
        Step("resume support", () => Submit(AdminForms.PauseSupport(db, reference, false)));
        Step("notice preview records nothing", () => Submit(AdminForms.GiveNotice(db, reference)),
            r => r.First?.Rows[0]["Recorded"] as string == "No (WhatIf)" && Queries.Agreement(db, reference)!["EndDate"] is DBNull ? null : "notice was recorded");
        Step("remove instance", () => Submit(AdminForms.RemoveInstance(db, reference, "ST-DEV01"), ("CoveredTo", D(DateTime.Today))));
        Step("removed instance keeps its history", () => Queries.Instances(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Instance"] == "ST-DEV01" && ((string)r["Cover"]).StartsWith("Ends")) ? null : "cover not ended");
        Step("new agreement for the existing client", () => Submit(AdminForms.NewAgreement(db), ("ClientName", name), ("StartDate", D(DateTime.Today.AddMonths(2))), ("AgreementRef", reference + "b")));

        // the screens over the new data
        Application.Init(new FakeDriver(), null);
        try
        {
            Step("main window over the test data", () => { new MainWindow(db).Build(Application.Top); return 0; });
            Step("agreement window over the test data", () => new AgreementWindow(db, reference).Build());
        }
        finally
        {
            Application.Shutdown();
        }

        Console.WriteLine();
        Console.WriteLine(AgreementWindow.Summary(db, reference, includeInstances: true));
        return Finish();
    }
}
