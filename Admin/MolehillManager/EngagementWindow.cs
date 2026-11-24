using System.Data;
using System.Text;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>One piece of consultancy work: the days worked, its invoices and the client's contacts.</summary>
public sealed class EngagementWindow
{
    private readonly AdminDb _db;
    private readonly string _ref;
    private string _clientName = "";

    private Dialog _dialog = null!;
    private TextView _summary = null!;
    private TabView _tabs = null!;
    private TabView.Tab _workTab = null!, _entriesTab = null!, _invoiceTab = null!, _contactTab = null!;
    private TableView _work = null!, _entries = null!, _invoices = null!, _contacts = null!;

    public EngagementWindow(AdminDb db, string engagementRef)
    {
        _db = db;
        _ref = engagementRef;
    }

    public void Run()
    {
        Build();
        Application.Run(_dialog);
    }

    /// <summary>Builds the window without running it (also used by the self-test).</summary>
    public Dialog Build()
    {
        var actions = new Button("Actions (F4)");
        var add = new Button("Log work (F2)");
        var close = new Button("Close", true);
        _dialog = new Dialog($"Engagement {_ref}", actions, add, close) { Width = Dim.Fill(1), Height = Dim.Fill(1) };

        _summary = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = 6, ReadOnly = true };
        _tabs = new TabView { X = 0, Y = 6, Width = Dim.Fill(), Height = Dim.Fill(3) };

        TableView Table()
        {
            var t = Grid.Make();
            t.CellActivated += _ => RowActions();
            return t;
        }
        _work = Table();
        _entries = Table();
        _invoices = Table();
        _contacts = Table();

        var workView = new View { Width = Dim.Fill(), Height = Dim.Fill() };
        workView.Add(new Label("A day's work is billed as one line. Everything logged on the same day counts together, and each billing period is invoiced once it has ended.")
            { X = 1, Y = 0, ColorScheme = Colors.Menu });
        _work.Y = 1;
        _work.Height = Dim.Fill();
        workView.Add(_work);

        _workTab = new TabView.Tab("Days worked", workView);
        _entriesTab = new TabView.Tab("Everything logged", _entries);
        _invoiceTab = new TabView.Tab("Invoices", _invoices);
        _contactTab = new TabView.Tab("Contacts", _contacts);
        _tabs.AddTab(_workTab, true);
        _tabs.AddTab(_entriesTab, false);
        _tabs.AddTab(_invoiceTab, false);
        _tabs.AddTab(_contactTab, false);

        var hint = new Label("Enter or F4: actions for the selected row (F4 also has the engagement actions).  F2 logs work.  F5 refreshes.")
            { X = 0, Y = Pos.AnchorEnd(2), Width = Dim.Fill(), ColorScheme = Colors.Menu };
        _dialog.Add(_summary, _tabs, hint);

        actions.Clicked += ShowActions;
        add.Clicked += LogWork;
        close.Clicked += () => Application.RequestStop();
        _dialog.KeyPress += e =>
        {
            switch (e.KeyEvent.Key)
            {
                case Key.F2: LogWork(); e.Handled = true; break;
                case Key.F4: ShowActions(); e.Handled = true; break;
                case Key.F5: Refresh(); e.Handled = true; break;
            }
        };

        Refresh();
        return _dialog;
    }

    public void Refresh()
    {
        Ui.Try("Engagement", () =>
        {
            var e = Queries.Engagement(_db, _ref) ?? throw new InvalidOperationException($"Engagement {_ref} not found.");
            _clientName = (string)e["ClientName"];
            _summary.Text = Summary(_db, _ref, includeWork: false);
            Grid.Bind(_work, Queries.ConsultancyWork(_db, _ref));
            Grid.Bind(_entries, Queries.WorkEntries(_db, _ref));
            Grid.Bind(_invoices, Queries.EngagementInvoices(_db, _ref));
            var contacts = Queries.Contacts(_db, ClientContactsRef(), includeRemoved: false);
            Grid.Bind(_contacts, contacts);
        });
    }

    /// <summary>Contacts are the client's, so look them up through any agreement they have; the client name works too.</summary>
    private string ClientContactsRef() => _ref;

    /// <summary>How many instances a per-instance price covers; blank on the engagement means the one.</summary>
    private static int UnitCount(DataRow e) => e["UnitCount"] is int c ? c : 1;

    /// <summary>The engagement in a few lines; with the work and invoices for the Clients tab preview.</summary>
    public static string Summary(AdminDb db, string engagementRef, bool includeWork)
    {
        var e = Queries.Engagement(db, engagementRef);
        if (e == null) return $"{engagementRef} not found.";
        string F(string c) => Output.Format(e[c]);
        var mode = (string)e["BillingMode"];
        var rate = mode switch
        {
            "DayRate" => $"£{e["DayRate"]:N2} a day",
            "Hourly" => $"£{e["HourlyRate"]:N2} an hour",
            "FixedPrice" => $"£{e["FixedPrice"]:N2} fixed price",
            "PerInstance" => $"£{e["UnitTotal"]:N2} for {UnitCount(e)} instance(s)"
                             + $" (£{e["FirstUnitPrice"]:N2} first"
                             + (e["ExtraUnitPrice"] is decimal x && x > 0 ? $", then £{x:N2} each" : ", the rest included")
                             + (e["PriceCap"] is decimal cap ? $", capped at £{cap:N2}" : "") + ")",
            _ => "per the agreement"
        };
        var sb = new StringBuilder();
        sb.AppendLine($"{F("ClientName")}  ({F("EngagementRef")})   {F("Name")}");
        sb.AppendLine($"{rate}" + (e["OutOfHoursRate"] is decimal ooh ? $", out of hours £{ooh:N2}/h" : "")
                      + $"   Status: {F("Status")}   Started {F("StartDate")}"
                      + (e["EndDate"] is DBNull ? "" : $", to {F("EndDate")}")
                      + (e["CompletedOn"] is DBNull ? "" : $", finished {F("CompletedOn")}"));
        sb.AppendLine($"Worked {e["TotalDays"]:N2} days in total; {e["UnbilledDays"]:N2} days (£{e["UnbilledValue"]:N2}) not invoiced yet"
                      + (e["LastWorked"] is DBNull ? "" : $"; last worked {F("LastWorked")}"));
        sb.AppendLine($"Invoiced so far: £{e["Invoiced"]:N2}"
                      + (e["PurchaseOrder"] is DBNull ? "" : $"   PO: {F("PurchaseOrder")}")
                      + (mode is "FixedPrice" or "PerInstance" ? "   Invoiced when you mark it finished"
                         : e["PeriodEndsOn"] is DateTime ends
                           ? $"   Billed every {e["BillingEveryDays"]} days from the start: this period ends {ends:dd MMM yyyy}" : ""));
        sb.AppendLine($"Invoices to: {(e["InvoicesTo"] is DBNull ? "NO ONE - add a contact that receives invoices" : F("InvoicesTo"))}");
        if (e["Notes"] is not DBNull) sb.AppendLine($"Notes: {F("Notes")}");

        if (includeWork)
        {
            var work = Queries.ConsultancyWork(db, engagementRef);
            sb.AppendLine().AppendLine("Days worked:");
            sb.Append(work.Rows.Count == 0 ? "(nothing logged yet - open it and press F2)\n" : Output.TextTable(work));
            var invoices = Queries.EngagementInvoices(db, engagementRef);
            sb.AppendLine().AppendLine("Invoices:");
            sb.Append(invoices.Rows.Count == 0 ? "(none yet)\n" : Output.TextTable(invoices));
        }
        return sb.ToString();
    }

    // ------------------------------------------------------------------ actions

    private void LogWork() => Ui.Form(AdminForms.LogWork(_db, _ref), Refresh);

    private (MhActionSet Set, Dictionary<string, Action> Handlers) Context()
    {
        var tab = _tabs.SelectedTab;
        var handlers = new Dictionary<string, Action> { ["work-log"] = LogWork };

        if (tab == _invoiceTab)
        {
            var no = Grid.Selected(_invoices, "Invoice");
            if (no != null) foreach (var (id, run) in InvoiceActions.Handlers(_db, no, Refresh)) handlers[id] = run;
            handlers["invoice-new"] = () => Ui.Form(AdminForms.NewInvoice(_db, _ref), Refresh);
            return (ActionRules.EngagementInvoices(no, no != null && Queries.IsDraftInvoice(_db, no)), handlers);
        }
        if (tab == _contactTab)
        {
            handlers["contact-add"] = () => Ui.Form(AdminForms.AddContact(_db, _clientName), Refresh);
            var idText = Grid.Selected(_contacts, "Id");
            if (idText == null || !int.TryParse(idText, out var id)) return (ActionRules.Contact(null, null, false), handlers);
            var name = Grid.Selected(_contacts, "Name") ?? "Contact";
            handlers["contact-edit"] = () => Ui.Form(AdminForms.EditContact(_db, id), Refresh);
            handlers["contact-remove"] = () => Ui.Form(AdminForms.RemoveContact(_db, id), Refresh);
            handlers["contact-readd"] = () => Ui.Form(AdminForms.ReaddContact(_db, id), Refresh);
            // this grid never lists removed contacts, so the one here is always a current one
            return (ActionRules.Contact(id, name, current: true, history: false), handlers);
        }
        if (tab == _entriesTab)
        {
            var idText = Grid.Selected(_entries, "Id");
            if (idText == null || !int.TryParse(idText, out var id)) return (ActionRules.LoggedWork(null, false, null), handlers);
            var invoiceNo = Grid.Selected(_entries, "Invoiced");
            // on an invoice or not, from the row's raw InvoiceId. This used to be read out of the
            // words in the Invoiced cell, starting with a hard-coded "MDS" - and the invoice prefix
            // is a setting the user can change.
            var invoiced = Grid.SelectedRow(_entries)?["_InvoiceId"] is int;
            handlers["entry-invoiced"] = () =>
                MessageBox.Query("Logged work", $"This time is on invoice {invoiceNo}. Void that invoice, then change the time.", "Ok");
            handlers["entry-correct"] = () => Ui.Form(AdminForms.EditTimeEntry(_db, id), Refresh);
            handlers["entry-remove"] = () => Ui.Form(AdminForms.DeleteTimeEntry(_db, id), Refresh);
            return (ActionRules.LoggedWork(id, invoiced, invoiceNo), handlers);
        }

        handlers["work-day-correct"] = () =>
        {
            _tabs.SelectedTab = _entriesTab;
            MessageBox.Query("Days worked", "Everything logged is on the next tab - pick the entry there to correct or remove it.", "Ok");
        };
        return (ActionRules.DaysWorked(Grid.Selected(_work, "Date")), handlers);
    }

    private void RowActions()
    {
        var (set, handlers) = Context();
        Picker.Actions(set, handlers);
    }

    private void ShowActions()
    {
        var (set, handlers) = Context();
        handlers["engagement-more"] = EngagementActions;
        Picker.Actions(set.Add(new MhAction("engagement-more", "Engagement actions (change, finish, invoice, billing) ...")), handlers);
    }

    /// <summary>The actions for a tab, with nothing drawn (for the self-test).</summary>
    internal (MhActionSet Set, Dictionary<string, Action> Handlers) ActionsOn(TabView.Tab? tab = null)
    {
        if (tab != null) _tabs.SelectedTab = tab;
        return Context();
    }

    /// <summary>The F4 menu's labels for the tab showing (for the self-test).</summary>
    internal List<string> ActionLabels(TabView.Tab? tab = null)
    {
        var set = ActionsOn(tab).Set;
        return set.Available.Select(a => a.Label).Prepend(set.Title).ToList();
    }

    internal IEnumerable<TabView.Tab> Tabs => _tabs.Tabs;

    private void EngagementActions() =>
        Picker.Actions(EngagementWideSet(), new Dictionary<string, Action>
        {
            ["work-log"] = LogWork,
            ["engagement-edit"] = () => Ui.Form(AdminForms.EditEngagement(_db, _ref), Refresh),
            ["engagement-complete"] = () => Ui.Form(AdminForms.CompleteEngagement(_db, _ref), Refresh),
            ["engagement-cancel"] = () => Ui.Form(AdminForms.CancelEngagement(_db, _ref), Refresh),
            ["invoice-new"] = () => Ui.Form(AdminForms.NewInvoice(_db, _ref), Refresh),
            ["billing-run"] = () => Ui.RunBilling(_db, _ref, Refresh)
        });

    /// <summary>
    ///   Selects one logged-work row and returns what it offers (for the self-test): whether the
    ///   time is already invoiced, read off the real row rather than the first one listed.
    /// </summary>
    internal MhActionSet EntryActions(bool invoiced)
    {
        _tabs.SelectedTab = _entriesTab;
        var rows = _entries.Table.Rows.Cast<DataRow>().ToList();
        var i = rows.FindIndex(r => (r["_InvoiceId"] is int) == invoiced);
        if (i < 0) throw new InvalidOperationException($"no logged work that is {(invoiced ? "" : "not ")}invoiced.");
        _entries.SelectedRow = i;
        return Context().Set;
    }

    /// <summary>The engagement-wide actions, with nothing drawn (for the self-test).</summary>
    internal MhActionSet EngagementWideSet() =>
        ActionRules.EngagementWide(_ref, Queries.Engagement(_db, _ref)?["Status"] as string is "Completed" or "Cancelled");
}
