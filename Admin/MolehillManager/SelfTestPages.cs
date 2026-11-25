using System.Data;
using System.Windows;
using System.Windows.Controls;
using MolehillManager.Gui;

namespace MolehillManager;

/// <summary>
///   The agreement and engagement pages: the two screens Phase 2 exists for, and the ones the
///   terminal hides the most behind.
///
///   Everything here runs with no database and no window. The pages are handed their tables
///   already fetched, and every action goes out through one delegate, so what is checked is the
///   screen's behaviour rather than a stack of mocked queries: which tabs exist, what each tab
///   offers for the row selected on it, which of those are greyed and why, and that pressing any
///   of them reaches something that will run.
/// </summary>
public static partial class SelfTest
{
    // ---------------------------------------------------------------- made-up data

    private static DataTable Table(params (string Name, Type Type)[] columns)
    {
        var t = new DataTable();
        foreach (var (name, type) in columns) t.Columns.Add(name, type);
        return t;
    }

    private static DataTable SomeInstances()
    {
        var t = Table(("Instance", typeof(string)), ("Role", typeof(string)), ("Env", typeof(string)),
            ("Version", typeof(string)), ("Fee", typeof(decimal)), ("Cover", typeof(string)));
        t.Rows.Add("SQL01", "Standalone", "Production", "2019", 350m, "Covered");
        t.Rows.Add("SQL02\\INST", "AGPrimary", "Production", "2022", 225m, "Covered");
        return t;
    }

    private static DataTable SomeOnboarding()
    {
        var t = Table(("Code", typeof(string)), ("Description", typeof(string)), ("Required", typeof(string)),
            ("Done", typeof(DateTime)), ("Notes", typeof(string)));
        t.Rows.Add("SIGNED", "Agreement signed and start date confirmed", "Yes", new DateTime(2026, 1, 9), null);
        t.Rows.Add("MONITORING", "Molehill Watch installed on every covered instance", "Yes", DBNull.Value, null);
        return t;
    }

    /// <summary>Contacts as the query returns them: every one, with Status saying which are current.</summary>
    private static DataTable SomeContacts()
    {
        var t = Table(("Id", typeof(int)), ("Name", typeof(string)), ("Email", typeof(string)),
            ("Tickets", typeof(string)), ("Invoices", typeof(string)), ("Status", typeof(string)));
        t.Rows.Add(11, "Dana Vale", "dana@acme.example", "Yes", "", "Current");
        t.Rows.Add(12, "Ray Finch", "ray@acme.example", "", "Yes", "Current");
        t.Rows.Add(13, "Sam Orde", "sam@acme.example", "", "", "Removed");
        return t;
    }

    private static DataTable SomeTickets()
    {
        var t = Table(("Ticket", typeof(string)), ("Severity", typeof(string)), ("Status", typeof(string)),
            ("Title", typeof(string)), ("Instance", typeof(string)));
        t.Rows.Add("TKT-0042", "Critical", "Open", "Backups failing on SQL01", "SQL01");
        t.Rows.Add("TKT-0043", "Standard", "Resolved", "Slow overnight job", "SQL02\\INST");
        return t;
    }

    private static DataTable SomeWeekly()
    {
        var t = Table(("WeekEnding", typeof(DateTime)), ("Instance", typeof(string)), ("Status", typeof(string)),
            ("Critical", typeof(int)), ("Warnings", typeof(int)));
        t.Rows.Add(new DateTime(2026, 11, 20), "SQL01", "Amber", 0, 3);
        return t;
    }

    /// <summary>
    ///   Pre-paid packages, built so the three rules have something real to decide: one open,
    ///   invoiced and partly used, one open and untouched, and one cancelled.
    /// </summary>
    private static DataTable SomePrepaid()
    {
        var t = Table(("Ref", typeof(string)), ("Hours", typeof(decimal)), ("Used", typeof(decimal)),
            ("State", typeof(string)), ("Invoice", typeof(string)));
        t.Rows.Add("PP-0014", 10m, 4m, "Open", "MDS-INV-2026-0009");
        t.Rows.Add("PP-0015", 5m, 0m, "Open", DBNull.Value);
        t.Rows.Add("PP-0016", 5m, 0m, "Cancelled", DBNull.Value);
        return t;
    }

    private static AgreementData SomeAgreement(bool paused = false) => new(
        "MW-A-0003", "Acme Ltd",
        "Acme Ltd  (MW-A-0003)   Status: Current   Price list: Standard 2026\nTickets via: support@acme.example",
        paused, SomeInstances(), SomeOnboarding(), SomeContacts(), SomeTickets(), SomeWeekly(), SomePrepaid());

    private static DataTable SomeDaysWorked()
    {
        var t = Table(("Date", typeof(DateTime)), ("Rate", typeof(string)), ("Hours", typeof(decimal)),
            ("Days", typeof(decimal)), ("Charge", typeof(decimal)), ("Invoiced", typeof(string)));
        t.Rows.Add(new DateTime(2026, 11, 17), "Business hours", 8m, 1m, 400m, "");
        t.Rows.Add(new DateTime(2026, 11, 18), "Business hours", 4m, 0.5m, 200m, "MDS-INV-2026-0011");
        return t;
    }

    /// <summary>
    ///   Logged work. The rows here are chosen to catch the rule that used to be wrong: whether
    ///   time is already invoiced is the raw _InvoiceId, not the words in the Invoiced cell. So one
    ///   row reads like an invoice number and is not invoiced, and one is invoiced while reading
    ///   nothing of the sort.
    /// </summary>
    private static DataTable SomeEntries()
    {
        var t = Table(("Id", typeof(int)), ("Date", typeof(DateTime)), ("Minutes", typeof(int)),
            ("Rate", typeof(string)), ("Invoiced", typeof(string)), ("Description", typeof(string)),
            ("_InvoiceId", typeof(int)));
        t.Rows.Add(501, new DateTime(2026, 11, 17), 480, "Business hours", "at the next billing run", "Index review", DBNull.Value);
        t.Rows.Add(502, new DateTime(2026, 11, 18), 240, "Business hours", "ACME-2026-11", "Statistics", DBNull.Value);
        t.Rows.Add(503, new DateTime(2026, 11, 10), 120, "Business hours", "paid up front", "Kick-off", 77);
        return t;
    }

    /// <summary>
    ///   Invoices. One draft, one sent and past its due date - which the query prints as OVERDUE,
    ///   so a rule reading the Status cell rather than the raw flag would get it wrong.
    /// </summary>
    private static DataTable SomeInvoices()
    {
        var t = Table(("Invoice", typeof(string)), ("Dated", typeof(DateTime)), ("Total", typeof(decimal)),
            ("Status", typeof(string)), ("_IsDraft", typeof(bool)));
        t.Rows.Add("MDS-INV-2026-0012", new DateTime(2026, 11, 20), 600m, "Draft", true);
        t.Rows.Add("MDS-INV-2026-0011", new DateTime(2026, 10, 1), 1200m, "OVERDUE", false);
        return t;
    }

    private static DataTable CurrentContactsOnly()
    {
        var t = SomeContacts();
        foreach (var row in t.Select("Status = 'Removed'")) row.Delete();
        t.AcceptChanges();
        return t;
    }

    private static EngagementData SomeEngagement(bool finished = false) => new(
        "C-0012", "Acme Ltd",
        "Acme Ltd  (C-0012)   Upgrade to SQL Server 2022\n£400.00 a day   Status: Active",
        finished, SomeDaysWorked(), SomeEntries(), SomeInvoices(), CurrentContactsOnly());

    // ---------------------------------------------------------------- the shared helpers

    /// <summary>
    ///   Presses every action the page offers, on every tab, and says which ones reached nothing.
    ///
    ///   This is what replaced checking a dictionary of handlers for completeness. The page builds
    ///   a handler for each action it offers, so that check became true by construction; what can
    ///   still be wrong is the window having no case for an id, and the only way to find that is to
    ///   press the thing. A page whose actions are all wired runs every one of these.
    /// </summary>
    private static List<string> PressEverything(DetailPage page, HashSet<string> known)
    {
        var nothing = new List<string>();
        foreach (var header in page.Headers)
        {
            page.ShowTab(header);
            var grid = page.GridOn(header);
            // once with nothing selected and once on a row, because which actions exist changes
            foreach (var index in new[] { -1, 0 })
            {
                grid.SelectedIndex = index;
                var offered = page.Actions.Actions.Concat(page.WideActions?.Actions ?? Array.Empty<MhAction>())
                    .Where(a => a.Enabled).Select(a => a.Id).ToList();
                var handlers = page.Handlers;
                foreach (var id in offered)
                {
                    if (!handlers.ContainsKey(id)) { nothing.Add($"{header}/{id}: no handler"); continue; }
                    if (!known.Contains(id)) nothing.Add($"{header}/{id}: the window has no case for it");
                }
            }
        }
        return nothing;
    }

    /// <summary>Every id the window has a case for. Read off the window's own source, so it cannot drift.</summary>
    private static HashSet<string> WiredIds(string method)
    {
        var source = RepoFile("Gui/MhWindow.cs");
        if (source == null) return new HashSet<string>();
        var from = source.IndexOf("private void RunOn" + method, StringComparison.Ordinal);
        if (from < 0) from = source.IndexOf("private bool RunOn" + method, StringComparison.Ordinal);
        if (from < 0) return new HashSet<string>();
        var to = source.IndexOf("\n    private", from + 10, StringComparison.Ordinal);
        var body = to < 0 ? source[from..] : source[from..to];
        return System.Text.RegularExpressions.Regex.Matches(body, "case \"([a-z-]+)\"")
            .Select(m => m.Groups[1].Value).ToHashSet();
    }

    /// <summary>A file from the repository beside the exe, or null when it is not there (a published build).</summary>
    private static string? RepoFile(string relative)
    {
        var here = AppContext.BaseDirectory;
        for (var i = 0; i < 8 && here != null; i++)
        {
            var path = Path.Combine(here, relative.Replace('/', Path.DirectorySeparatorChar));
            if (File.Exists(path)) return File.ReadAllText(path);
            here = Directory.GetParent(here)?.FullName;
        }
        return null;
    }

    // ---------------------------------------------------------------- the pure half

    /// <summary>
    ///   Which page each node opens. Worth its own section: it is the branch that picks the whole
    ///   screen, and a mutation pass found it had no coverage at all while it lived in the window.
    /// </summary>
    private static void CheckWhatOpens()
    {
        var tree = Nav.Build(SomeWork());
        Opens For(NavKind kind, string? key = null) =>
            Nav.Opening(Nav.Find(tree, kind, key) ?? new NavNode(kind, "", key));

        Check("Today opens Today", For(NavKind.Today) == Opens.Today);
        Check("Clients opens the client list", For(NavKind.Clients) == Opens.Clients);
        Check("and so does one client", For(NavKind.Client, "Acme Ltd") == Opens.Clients);
        Check("Settings opens the settings", For(NavKind.Settings) == Opens.Settings);

        Check("a support agreement opens the agreement page",
            For(NavKind.Engagement, "MW-A-0003") == Opens.Agreement,
            For(NavKind.Engagement, "MW-A-0003").ToString());
        Check("consultancy opens the engagement page",
            For(NavKind.Engagement, "C-0012") == Opens.Engagement,
            For(NavKind.Engagement, "C-0012").ToString());
        // the row whose Type cell says "Molehill Watch" while the raw type says Consultancy
        Check("and work whose Type cell reads \"Molehill Watch\" still opens the engagement page",
            For(NavKind.Engagement, "C-0033") == Opens.Engagement,
            For(NavKind.Engagement, "C-0033").ToString());

        // the other way round: a project named after the product, where the tree's own label reads
        // "Molehill Watch" while the work is consultancy
        Check("and a consultancy project called \"Molehill Watch\" opens the engagement page",
            For(NavKind.Engagement, "C-0041") == Opens.Engagement,
            For(NavKind.Engagement, "C-0041").ToString());
        Check("which is not something the tree's label could have told it",
            (Nav.Find(Nav.Build(SomeWork()), NavKind.Engagement, "C-0041")?.Label) == "Molehill Watch",
            Nav.Find(Nav.Build(SomeWork()), NavKind.Engagement, "C-0041")?.Label ?? "(missing)");

        // these two move to their own pages in Phase 3, and this is what will say so
        Check("Tickets and Billing are not built yet",
            For(NavKind.Tickets) == Opens.NotBuilt && For(NavKind.Billing) == Opens.NotBuilt,
            $"{For(NavKind.Tickets)} / {For(NavKind.Billing)}");
    }

    private static void CheckDetailRules()
    {
        var (none, _) = Detail.WeeklyStepFor(Array.Empty<string>());
        Check("with no instances there is nothing to report on", none == WeeklyStep.NoInstances, none.ToString());
        var (one, only) = Detail.WeeklyStepFor(new[] { "SQL01" });
        Check("with exactly one, the question is not asked", one == WeeklyStep.TheOnlyOne && only == "SQL01",
            $"{one} / {only}");
        var (many, nothing) = Detail.WeeklyStepFor(new[] { "SQL01", "SQL02" });
        Check("with several, it is", many == WeeklyStep.Choose && nothing == null, $"{many} / {nothing}");

        Check("no removed contacts, nothing said",
            Detail.RemovedContactsNote(0, false, "pick one") == "", Detail.RemovedContactsNote(0, false, "pick one"));
        Check("one removed reads as one, not \"1 contacts\"",
            Detail.RemovedContactsNote(1, false, "pick one") == "1 removed contact hidden - tick to see or add back",
            Detail.RemovedContactsNote(1, false, "pick one"));
        Check("two removed reads as two",
            Detail.RemovedContactsNote(2, false, "pick one").StartsWith("2 removed contacts hidden"),
            Detail.RemovedContactsNote(2, false, "pick one"));
        Check("while they are showing, it says how to put one back",
            Detail.RemovedContactsNote(2, true, "press Add back") == "2 removed - press Add back",
            Detail.RemovedContactsNote(2, true, "press Add back"));

        var all = SomeContacts();
        Check("the removed ones are counted off the raw Status", Detail.RemovedCount(all) == 1,
            Detail.RemovedCount(all).ToString());
        var current = Detail.CurrentContacts(all);
        Check("and filtering them out leaves the current ones", current.Rows.Count == 2, $"{current.Rows.Count} rows");
        Check("without changing the table it was given", all.Rows.Count == 3, $"{all.Rows.Count} rows");
    }

    // ---------------------------------------------------------------- the agreement page

    private static void CheckAgreementPage(BindingWatcher watcher)
    {
        var data = SomeAgreement();
        var ran = new List<string>();
        watcher.Clear();

        DetailPage? page = null;
        Step("the agreement page lays out with no window", () =>
        {
            page = AgreementPage.Build(data, null, ClientsPage.NotYet, (id, tab) => ran.Add($"{tab.Header}/{id}"));
            Layout(page, 1200, 820);
            return 0;
        });
        if (page == null) return;
        Check("no binding warnings from the agreement page", watcher.Lines.Count == 0,
            string.Join(" | ", watcher.Lines.Take(2)));

        Check("its six tabs are there, in the order the terminal has them",
            page.Headers.SequenceEqual(new[]
            {
                AgreementPage.Instances, AgreementPage.Onboarding, AgreementPage.Contacts,
                AgreementPage.Tickets, AgreementPage.Weekly, AgreementPage.Prepaid
            }), string.Join(", ", page.Headers));
        Check("the summary is on it", page.Summary.Contains("MW-A-0003"), page.Summary);
        Check("every tab has its table", page.GridOn(AgreementPage.Instances).Table == data.Instances
            && page.GridOn(AgreementPage.Tickets).Table == data.Tickets
            && page.GridOn(AgreementPage.Prepaid).Table == data.Prepaid);

        // ---- instances
        page.ShowTab(AgreementPage.Instances);
        page.GridOn(AgreementPage.Instances).SelectedIndex = -1;
        Check("with no instance picked, the only thing offered is adding one",
            page.Actions.Available.Select(a => a.Id).SequenceEqual(new[] { "instance-add" }),
            string.Join(", ", page.Actions.Available.Select(a => a.Id)));
        page.GridOn(AgreementPage.Instances).Select("Instance", "SQL01");
        Check("picking one offers what can be done to it",
            page.Actions.ById("instance-update") != null && page.Actions.ById("instance-ticket") != null,
            string.Join(", ", page.Actions.Actions.Select(a => a.Id)));

        // ---- contacts: removed ones hidden, and said so
        page.ShowTab(AgreementPage.Contacts);
        var contacts = page.GridOn(AgreementPage.Contacts);
        Check("the contacts tab hides the removed ones to begin with",
            contacts.Table?.Rows.Count == 2, $"{contacts.Table?.Rows.Count} rows");
        // "hidden", not "removed": the tick box beside it reads "Show removed contacts"
        var note = Texts(page).FirstOrDefault(s => s.Contains("hidden"));
        Check("and says how many it hid, in words that match the count",
            note == "1 removed contact hidden - tick to see or add back", note ?? "(nothing said)");
        var tick = Descendants<CheckBox>(page).FirstOrDefault(c => (c.Content as string) == "Show removed contacts");
        Check("there is a tick box for them", tick != null);
        if (tick != null)
        {
            tick.IsChecked = true;
            tick.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Check("ticking it shows them", contacts.Table?.Rows.Count == 3, $"{contacts.Table?.Rows.Count} rows");
            Check("and the note changes to say how to put one back",
                Texts(page).Any(s => s.Contains(AgreementPage.AddBackHere)),
                string.Join(" | ", Texts(page).Where(s => s.Contains("removed"))));
            contacts.Select("Name", "Sam Orde");
            Check("a removed contact is offered adding back, not removing - from the raw Status",
                page.Actions.ById("contact-readd")?.Enabled == true
                && page.Actions.ById("contact-remove")?.Enabled == false,
                page.Actions.ById("contact-remove")?.DisabledReason ?? "(enabled)");
            contacts.Select("Name", "Dana Vale");
            Check("and a current one the other way round",
                page.Actions.ById("contact-remove")?.Enabled == true
                && page.Actions.ById("contact-readd")?.Enabled == false);
            tick.IsChecked = false;
            tick.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        }

        // ---- pre-paid hours: the three rules that used to read formatted cells
        page.ShowTab(AgreementPage.Prepaid);
        var prepaid = page.GridOn(AgreementPage.Prepaid);
        prepaid.Select("Ref", "PP-0014");
        Check("an invoiced package cannot be invoiced again, and says which invoice it is on",
            page.Actions.ById("prepaid-invoice")?.Enabled == false
            && page.Actions.ById("prepaid-invoice")?.DisabledReason?.Contains("MDS-INV-2026-0009") == true,
            page.Actions.ById("prepaid-invoice")?.DisabledReason ?? "(enabled)");
        Check("and one with hours used cannot be cancelled",
            page.Actions.ById("prepaid-cancel")?.Enabled == false
            && page.Actions.ById("prepaid-cancel")?.DisabledReason?.Contains("4") == true,
            page.Actions.ById("prepaid-cancel")?.DisabledReason ?? "(enabled)");
        prepaid.Select("Ref", "PP-0015");
        Check("an untouched, uninvoiced package can be both",
            page.Actions.ById("prepaid-invoice")?.Enabled == true
            && page.Actions.ById("prepaid-cancel")?.Enabled == true);
        prepaid.Select("Ref", "PP-0016");
        Check("a cancelled one can be neither, and says so",
            page.Actions.ById("prepaid-update")?.DisabledReason == "This package has been cancelled.",
            page.Actions.ById("prepaid-update")?.DisabledReason ?? "(enabled)");

        // ---- the agreement's own actions, as a second group rather than a second menu
        page.ShowTab(AgreementPage.Weekly);
        Check("the agreement's own actions are offered beside the tab's",
            page.WideActions?.ById("agreement-review") != null && page.WideActions?.ById("agreement-notice") != null,
            string.Join(", ", page.WideActions?.Actions.Select(a => a.Id) ?? Array.Empty<string>()));
        Check("an agreement that is not paused is offered pausing",
            page.WideActions?.ById("agreement-pause")?.Label == "Pause support (late payment)",
            page.WideActions?.ById("agreement-pause")?.Label ?? "(missing)");
        var pausedPage = AgreementPage.Build(SomeAgreement(paused: true), null, ClientsPage.NotYet, (_, _) => { });
        Layout(pausedPage, 1200, 820);
        Check("and a paused one is offered resuming, which is the same button with the other label",
            pausedPage.WideActions?.ById("agreement-pause")?.Label == "Resume support",
            pausedPage.WideActions?.ById("agreement-pause")?.Label ?? "(missing)");

        // ---- the same action must not appear twice
        page.ShowTab(AgreementPage.Tickets);
        page.GridOn(AgreementPage.Tickets).SelectedIndex = -1;
        Check("the Tickets tab offers opening a ticket",
            page.Actions.ById("ticket-new") != null);
        Check("and the agreement group does not offer it a second time",
            page.WideActions?.ById("ticket-new") == null,
            string.Join(", ", page.WideActions?.Actions.Select(a => a.Id) ?? Array.Empty<string>()));
        page.ShowTab(AgreementPage.Weekly);
        Check("while on a tab that does not, the agreement group still does",
            page.WideActions?.ById("ticket-new") != null);

        // ---- the toolbar takes both groups
        var shell = new Shell(_ => page!);
        shell.Load(Nav.Build(SomeWork()));
        shell.Go(NavKind.Engagement, "MW-A-0003");
        var expected = page.Actions.Actions.Count + (page.WideActions?.Actions.Count ?? 0);
        Check("the toolbar shows every action of both groups, greyed ones and all",
            shell.Actions.Buttons.Count == expected,
            $"{shell.Actions.Buttons.Count} buttons for {expected} actions");

        // ---- double-click runs the named action for that tab, not whatever happens to be first
        ran.Clear();
        page.ShowTab(AgreementPage.Instances);
        page.GridOn(AgreementPage.Instances).Select("Instance", "SQL01");
        page.GridOn(AgreementPage.Instances).RaiseEvent(new MouseButtonEventArgsStub());
        Check("double-clicking an instance edits it", ran.SequenceEqual(new[] { "Instances/instance-update" }),
            string.Join(", ", ran));

        Layout(page, 1200, 820);
        NothingAdrift(page, "the agreement page");
        Shot(page, "7-agreement");

        // ---- everything offered reaches something the window will run
        var wired = WiredIds("Agreement");
        wired.UnionWith(WiredIds("Ticket"));
        if (wired.Count == 0) Console.WriteLine("SKIP  the window's wiring (no source beside the exe)");
        else
        {
            var lost = PressEverything(page, wired);
            Check("every action the agreement page offers has a case in the window",
                lost.Count == 0, string.Join(" | ", lost.Take(4)));
        }

        // ---- a half-built window greys what it cannot do, rather than dropping it
        var limited = AgreementPage.Build(data, new[] { "instance-add" }, ClientsPage.NotYet, (_, _) => { });
        Layout(limited, 1200, 820);
        limited.ShowTab(AgreementPage.Instances);
        limited.GridOn(AgreementPage.Instances).Select("Instance", "SQL01");
        Check("what the window cannot do is still on show, greyed, saying where to go",
            limited.Actions.ById("instance-update")?.Enabled == false
            && limited.Actions.ById("instance-update")?.DisabledReason == ClientsPage.NotYet,
            limited.Actions.ById("instance-update")?.DisabledReason ?? "(enabled)");
        Check("and what it can do is still offered", limited.Actions.ById("instance-add")?.Enabled == true);
    }

    // ---------------------------------------------------------------- the engagement page

    private static void CheckEngagementPage(BindingWatcher watcher)
    {
        var data = SomeEngagement();
        var ran = new List<string>();
        watcher.Clear();

        DetailPage? page = null;
        Step("the engagement page lays out with no window", () =>
        {
            page = EngagementPage.Build(data, null, ClientsPage.NotYet, (id, tab) => ran.Add($"{tab.Header}/{id}"));
            Layout(page, 1200, 820);
            return 0;
        });
        if (page == null) return;
        Check("no binding warnings from the engagement page", watcher.Lines.Count == 0,
            string.Join(" | ", watcher.Lines.Take(2)));
        Check("its four tabs are there",
            page.Headers.SequenceEqual(new[]
            {
                EngagementPage.Work, EngagementPage.Entries, EngagementPage.Invoices, EngagementPage.Contacts
            }), string.Join(", ", page.Headers));

        // ---- logged work: invoiced or not, from the raw id
        page.ShowTab(EngagementPage.Entries);
        var entries = page.GridOn(EngagementPage.Entries);
        entries.SelectedIndex = 1;      // reads "ACME-2026-11", has no invoice behind it
        Check("time whose Invoiced cell reads like an invoice number, but has none, can still be corrected",
            page.Actions.ById("entry-correct")?.Enabled == true,
            page.Actions.ById("entry-correct")?.DisabledReason ?? "(enabled)");
        entries.SelectedIndex = 2;      // reads "paid up front", is on invoice 77
        Check("and time that is on an invoice cannot, whatever its cell says",
            page.Actions.ById("entry-correct")?.Enabled == false
            && page.Actions.ById("entry-remove")?.Enabled == false,
            page.Actions.ById("entry-correct")?.DisabledReason ?? "(enabled)");
        Check("with the reason naming the invoice to void first",
            page.Actions.ById("entry-invoiced")?.Enabled == true,
            string.Join(", ", page.Actions.Actions.Select(a => a.Id)));
        entries.SelectedIndex = -1;
        Check("with nothing picked, only logging work is offered",
            page.Actions.Available.Select(a => a.Id).SequenceEqual(new[] { "work-log" }),
            string.Join(", ", page.Actions.Available.Select(a => a.Id)));

        // ---- invoices: draft or not, from the raw flag rather than the Status cell
        page.ShowTab(EngagementPage.Invoices);
        var invoices = page.GridOn(EngagementPage.Invoices);
        invoices.Select("Invoice", "MDS-INV-2026-0012");
        Check("a draft invoice can have its lines changed",
            page.Actions.ById("invoice-line-add")?.Enabled == true
            && page.Actions.ById("invoice-adjust")?.Enabled == true);
        invoices.Select("Invoice", "MDS-INV-2026-0011");
        Check("an overdue one cannot, and says to void it to start again",
            page.Actions.ById("invoice-line-add")?.Enabled == false
            && page.Actions.ById("invoice-line-add")?.DisabledReason?.Contains("Void it") == true,
            page.Actions.ById("invoice-line-add")?.DisabledReason ?? "(enabled)");
        Check("but it can still be voided, marked sent or saved",
            page.Actions.ById("invoice-void")?.Enabled == true
            && page.Actions.ById("invoice-html")?.Enabled == true);

        // ---- contacts here have no history, because this grid never lists removed ones
        page.ShowTab(EngagementPage.Contacts);
        page.GridOn(EngagementPage.Contacts).Select("Name", "Dana Vale");
        Check("a contact on the engagement page is offered editing and removing",
            page.Actions.ById("contact-edit")?.Enabled == true
            && page.Actions.ById("contact-remove")?.Enabled == true);
        Check("but not history, which needs the removed ones this grid does not list",
            page.Actions.ById("contact-history") == null,
            string.Join(", ", page.Actions.Actions.Select(a => a.Id)));

        // ---- the engagement's own actions
        Check("the engagement's own actions are offered beside the tab's",
            page.WideActions?.ById("engagement-edit") != null && page.WideActions?.ById("billing-run") != null,
            string.Join(", ", page.WideActions?.Actions.Select(a => a.Id) ?? Array.Empty<string>()));
        var done = EngagementPage.Build(SomeEngagement(finished: true), null, ClientsPage.NotYet, (_, _) => { });
        Layout(done, 1200, 820);
        Check("finished work cannot be finished or cancelled again, and says why",
            done.WideActions?.ById("engagement-complete")?.Enabled == false
            && done.WideActions?.ById("engagement-complete")?.DisabledReason == "This engagement is already finished.",
            done.WideActions?.ById("engagement-complete")?.DisabledReason ?? "(enabled)");
        Check("though work can still be logged against it",
            done.WideActions?.ById("work-log")?.Enabled == true || done.Actions.ById("work-log")?.Enabled == true);

        Layout(page, 1200, 820);
        NothingAdrift(page, "the engagement page");
        Shot(page, "8-engagement");

        var wired = WiredIds("Engagement");
        wired.UnionWith(WiredIds("Invoice"));
        if (wired.Count == 0) Console.WriteLine("SKIP  the window's wiring (no source beside the exe)");
        else
        {
            var lost = PressEverything(page, wired);
            Check("every action the engagement page offers has a case in the window",
                lost.Count == 0, string.Join(" | ", lost.Take(4)));
        }
    }

    /// <summary>A double-click the grid will accept, without a mouse.</summary>
    private sealed class MouseButtonEventArgsStub : System.Windows.Input.MouseButtonEventArgs
    {
        public MouseButtonEventArgsStub()
            : base(System.Windows.Input.Mouse.PrimaryDevice, 0, System.Windows.Input.MouseButton.Left)
        {
            RoutedEvent = Control.MouseDoubleClickEvent;
        }
    }
}
