using System.Data;
using System.Text;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>One agreement: its instances, onboarding, contacts, tickets and weekly reports, and everything you can do to it.</summary>
public sealed class AgreementWindow
{
    private readonly AdminDb _db;
    private readonly string _ref;
    private string _clientName = "";

    private Dialog _dialog = null!;
    private TextView _summary = null!;
    private TabView _tabs = null!;
    private TabView.Tab _instTab = null!, _onbTab = null!, _contactTab = null!, _ticketTab = null!, _weeklyTab = null!, _prepaidTab = null!;
    private TableView _prepaid = null!;
    private TableView _instances = null!, _onboarding = null!, _contacts = null!, _tickets = null!, _weekly = null!;
    private CheckBox _showRemoved = null!;
    private Label _removedNote = null!;

    /// <summary>The contacts grid and its toggle (for the self-test).</summary>
    internal TableView ContactsTable => _contacts;
    internal string RemovedNote => _removedNote.Text.ToString() ?? "";

    public AgreementWindow(AdminDb db, string agreementRef)
    {
        _db = db;
        _ref = agreementRef;
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
        var add = new Button("Add (F2)");
        var close = new Button("Close", true);
        _dialog = new Dialog($"Agreement {_ref}", actions, add, close) { Width = Dim.Fill(1), Height = Dim.Fill(1) };

        _summary = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = 7, ReadOnly = true };
        _tabs = new TabView { X = 0, Y = 7, Width = Dim.Fill(), Height = Dim.Fill(3) };

        TableView Table(Action onEnter)
        {
            var t = Grid.Make();
            t.CellActivated += _ => onEnter();
            return t;
        }
        _instances = Table(RowActions);
        _onboarding = Table(RowActions);
        _contacts = Table(RowActions);
        _tickets = Table(RowActions);
        _weekly = Table(LogWeekly);

        _instTab = new TabView.Tab("Instances", _instances);
        _onbTab = new TabView.Tab("Onboarding", _onboarding);
        // removed contacts are hidden unless asked for
        var contactView = new View { Width = Dim.Fill(), Height = Dim.Fill() };
        _showRemoved = new CheckBox("Show removed contacts") { X = 1, Y = 0 };
        _showRemoved.Toggled += _ => RefreshContacts();
        _removedNote = new Label("") { X = Pos.Right(_showRemoved) + 3, Y = 0, Width = Dim.Fill(), ColorScheme = Colors.Menu };
        _contacts.Y = 1;
        _contacts.Height = Dim.Fill();
        contactView.Add(_showRemoved, _removedNote, _contacts);
        _contactTab = new TabView.Tab("Contacts", contactView);
        _ticketTab = new TabView.Tab("Tickets", _tickets);
        _weeklyTab = new TabView.Tab("Weekly reports", _weekly);
        _prepaid = Table(RowActions);
        var prepaidView = new View { Width = Dim.Fill(), Height = Dim.Fill() };
        prepaidView.Add(new Label("A package is charged on the client's next monthly invoice unless you said otherwise. Hours come off it when billing runs (F6), not when time is logged.")
            { X = 1, Y = 0, ColorScheme = Colors.Menu });
        _prepaid.Y = 1;
        _prepaid.Height = Dim.Fill();
        prepaidView.Add(_prepaid);
        _prepaidTab = new TabView.Tab("Pre-paid hours", prepaidView);
        _tabs.AddTab(_instTab, true);
        _tabs.AddTab(_onbTab, false);
        _tabs.AddTab(_contactTab, false);
        _tabs.AddTab(_ticketTab, false);
        _tabs.AddTab(_weeklyTab, false);
        _tabs.AddTab(_prepaidTab, false);

        var hint = new Label("Enter or F4: actions for the selected row (F4 also has the agreement actions).  F2 adds to this tab.  F5 refreshes.")
            { X = 0, Y = Pos.AnchorEnd(2), Width = Dim.Fill(), ColorScheme = Colors.Menu };
        _dialog.Add(_summary, _tabs, hint);

        actions.Clicked += ShowActions;
        add.Clicked += Add;
        close.Clicked += () => Application.RequestStop();
        _dialog.KeyPress += e =>
        {
            switch (e.KeyEvent.Key)
            {
                case Key.F2: Add(); e.Handled = true; break;
                case Key.F4: ShowActions(); e.Handled = true; break;
                case Key.F5: Refresh(); e.Handled = true; break;
            }
        };

        Refresh();
        return _dialog;
    }

    public void Refresh()
    {
        Ui.Try("Agreement", () =>
        {
            var a = Queries.Agreement(_db, _ref) ?? throw new InvalidOperationException($"Agreement {_ref} not found.");
            _clientName = (string)a["ClientName"];
            _summary.Text = Summary(_db, _ref, includeInstances: false);
            Grid.Bind(_instances, Queries.Instances(_db, _ref));
            Grid.Bind(_onboarding, Queries.Onboarding(_db, _ref));
            RefreshContacts();
            Grid.Bind(_tickets, Queries.Tickets(_db, openOnly: false, _ref));
            Grid.Bind(_weekly, Queries.WeeklyReports(_db, _ref));
            Grid.Bind(_prepaid, Queries.Prepaid(_db, _ref));
        });
    }

    /// <summary>Shows or hides removed contacts (the tick box does the same).</summary>
    public void SetShowRemoved(bool show)
    {
        _showRemoved.Checked = show;
        RefreshContacts();
    }

    private void RefreshContacts()
    {
        Ui.Try("Contacts", () =>
        {
            var all = Queries.Contacts(_db, _ref, includeRemoved: true);
            var removed = all.Rows.Cast<DataRow>().Count(r => (string)r["Status"] == "Removed");
            if (_showRemoved.Checked)
            {
                Grid.Bind(_contacts, all);
                _removedNote.Text = removed == 0 ? "" : $"{removed} removed - Enter on one to add them back";
            }
            else
            {
                var view = all.DefaultView;
                view.RowFilter = "Status = 'Current'";
                Grid.Bind(_contacts, view.ToTable());
                _removedNote.Text = removed == 0 ? "" : $"{removed} removed contact{(removed == 1 ? "" : "s")} hidden - tick to see or add back";
            }
        });
    }

    /// <summary>The agreement in a few lines; with the instances and contacts for the Clients tab preview.</summary>
    public static string Summary(AdminDb db, string agreementRef, bool includeInstances)
    {
        var a = Queries.Agreement(db, agreementRef);
        if (a == null) return $"{agreementRef} not found.";
        string F(string c) => Output.Format(a[c]);
        var sb = new StringBuilder();
        sb.AppendLine($"{F("ClientName")}  ({F("AgreementRef")})   Status: {F("Status")}   Price list: {F("PriceList")}");
        sb.AppendLine($"Started {F("StartDate")}, signed {(a["SignedDate"] is DBNull ? "NOT RECORDED" : F("SignedDate"))}; " +
                      $"initial term {F("InitialTermMonths")} months to {F("InitialTermEnds")}" +
                      (a["EndDate"] is DBNull ? "" : $"; ENDS {F("EndDate")} (notice {F("NoticeGivenDate")} by {F("NoticeGivenBy")})"));
        sb.AppendLine($"Initial review: {(a["InitialReviewDoneDate"] is DBNull ? "not yet delivered" : F("InitialReviewDoneDate"))}" +
                      (a["SupportPausedFrom"] is DBNull ? "" : $"   SUPPORT PAUSED from {F("SupportPausedFrom")} (late payment)"));
        sb.AppendLine($"Tickets via: {F("TicketChannel")}");
        sb.AppendLine($"Invoices to: {(a["InvoicesTo"] is DBNull ? "NO ONE - add a contact that receives invoices (Contacts tab)" : F("InvoicesTo"))}" +
                      (a["Address"] is DBNull ? "" : $"   {F("Address")}"));

        var usage = Queries.AgreementUsage(db, agreementRef);
        if (usage.First is { Rows.Count: > 0 } u)
        {
            var r = u.Rows[0];
            sb.AppendLine($"This cycle ({Output.Format(r["CycleStart"])} - {Output.Format(r["CycleEnd"])}): " +
                          $"{Output.Format(r["BusinessHoursLogged"])} of {Output.Format(r["IncludedHours"])} included hours used, " +
                          $"{Output.Format(r["IncludedHoursRemaining"])} left; {Output.Format(r["OutOfHoursLogged"])} h out of hours"
                          + (r.Table.Columns.Contains("PrepaidHoursLeft") && r["PrepaidHoursLeft"] is decimal left ? $"; pre-paid hours left: {Output.Format(left)}" : "")
                          + (r.Table.Columns.Contains("UnbilledHours") && r["UnbilledHours"] is decimal unbilled && unbilled > 0
                             ? $"; {Output.Format(unbilled)} h logged but not yet billed" : ""));
        }
        else sb.AppendLine(usage.Messages.FirstOrDefault() ?? "");

        if (includeInstances)
        {
            var inst = Queries.Instances(db, agreementRef);
            // the database works the monthly fee out for the Clients tab and the dashboard; one figure, one place
            sb.AppendLine().AppendLine($"Instances (monthly fee £{Queries.AgreementMonthlyFee(db, agreementRef):N2}):");
            sb.Append(inst.Rows.Count == 0 ? "(none yet - open the agreement and press F2)\n" : Output.TextTable(inst));
            var contacts = Queries.Contacts(db, agreementRef).DefaultView.ToTable(false, "Name", "Email", "Phone", "Tickets", "Invoices", "From");
            sb.AppendLine().AppendLine("Contacts:");
            sb.Append(contacts.Rows.Count == 0 ? "(none)\n" : Output.TextTable(contacts));
        }
        return sb.ToString();
    }

    // ------------------------------------------------------------------ actions

    private string? SelectedInstance() => Grid.Selected(_instances, "Instance");

    private void Add()
    {
        var tab = _tabs.SelectedTab;
        if (tab == _contactTab) Ui.Form(AdminForms.AddContact(_db, _clientName), Refresh);
        else if (tab == _ticketTab) Ui.Form(AdminForms.OpenTicket(_db, _ref), Refresh);
        else if (tab == _weeklyTab) LogWeekly();
        else if (tab == _prepaidTab) Ui.Form(AdminForms.SellPrepaid(_db, _ref), Refresh);
        else if (tab == _onbTab) CompleteOnboarding();
        else Ui.Form(AdminForms.AddInstance(_db, _ref), Refresh);
    }

    // Every tab's actions come from one list: Enter on a row shows them, F4 shows them plus the agreement-wide ones.

    private (MhActionSet Set, Dictionary<string, Action> Handlers) Context()
    {
        var tab = _tabs.SelectedTab;
        if (tab == _contactTab) return ContactList();
        if (tab == _ticketTab) return TicketList();
        if (tab == _weeklyTab) return (ActionRules.Weekly(), new() { ["weekly-log"] = LogWeekly });
        if (tab == _prepaidTab) return PrepaidList();
        if (tab == _onbTab) return OnboardingList();
        return InstanceList();
    }

    private void RowActions()
    {
        var (set, handlers) = Context();
        Picker.Actions(set, handlers);
    }

    /// <summary>F4: what can be done here, then the agreement-wide actions.</summary>
    private void ShowActions()
    {
        var (set, handlers) = Context();
        handlers["agreement-more"] = AgreementActions;
        Picker.Actions(set.Add(new MhAction("agreement-more", "Agreement actions (review, notice, pause, usage, quote, billing) ...")), handlers);
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

    private (MhActionSet, Dictionary<string, Action>) InstanceList()
    {
        var name = SelectedInstance();
        var handlers = new Dictionary<string, Action>
        {
            ["instance-add"] = () => Ui.Form(AdminForms.AddInstance(_db, _ref), Refresh)
        };
        if (name != null)
        {
            handlers["instance-update"] = () => Ui.Form(AdminForms.UpdateInstance(_db, _ref, name), Refresh);
            handlers["instance-weekly"] = () => Ui.Form(AdminForms.WeeklyReport(_db, _ref, name), Refresh);
            handlers["instance-ticket"] = () =>
            {
                var spec = AdminForms.OpenTicket(_db, _ref);
                Ui.Form(new FormSpec
                {
                    Title = spec.Title, Intro = spec.Intro, Submit = spec.Submit,
                    Fields = spec.Fields.Select(f => f.Name == "InstanceName" ? Field.Text("InstanceName", f.Label, def: name) : f).ToList()
                }, Refresh);
            };
            handlers["instance-risk"] = () => Ui.Form(AdminForms.RiskAcceptance(_db, _ref, name), Refresh);
            handlers["instance-remove"] = () => Ui.Form(AdminForms.RemoveInstance(_db, _ref, name), Refresh);
        }
        return (ActionRules.Instances(name), handlers);
    }

    private (MhActionSet, Dictionary<string, Action>) OnboardingList()
    {
        var code = Grid.Selected(_onboarding, "Code");
        return (ActionRules.Onboarding(code), new Dictionary<string, Action>
        {
            ["onboarding-done"] = CompleteOnboarding,
            ["onboarding-show"] = ShowOnboarding
        });
    }

    private (MhActionSet, Dictionary<string, Action>) ContactList()
    {
        var handlers = new Dictionary<string, Action>
        {
            ["contact-add"] = () => Ui.Form(AdminForms.AddContact(_db, _clientName), Refresh)
        };
        var idText = Grid.Selected(_contacts, "Id");
        if (idText == null || !int.TryParse(idText, out var id)) return (ActionRules.Contact(null, null, false), handlers);
        var name = Grid.Selected(_contacts, "Name") ?? "Contact";
        handlers["contact-edit"] = () => Ui.Form(AdminForms.EditContact(_db, id), Refresh);
        handlers["contact-remove"] = () => Ui.Form(AdminForms.RemoveContact(_db, id), Refresh);
        handlers["contact-readd"] = () => Ui.Form(AdminForms.ReaddContact(_db, id), Refresh);
        handlers["contact-history"] = () => Ui.Try("History", () =>
            Output.Text($"{name} - contact history", Output.TextTable(Queries.ContactPeriods(_db, id))));
        // current or removed comes from the raw Status, not from the word in the cell
        return (ActionRules.Contact(id, name, Grid.SelectedRow(_contacts)?["Status"] as string == "Current"), handlers);
    }

    private (MhActionSet, Dictionary<string, Action>) TicketList()
    {
        var reference = Grid.Selected(_tickets, "Ticket");
        var handlers = reference == null
            ? new Dictionary<string, Action>()
            : TicketActions.Handlers(_db, reference, Refresh);
        handlers["ticket-new"] = () => Ui.Form(AdminForms.OpenTicket(_db, _ref), Refresh);
        return (ActionRules.Ticket(reference), handlers);
    }

    private (MhActionSet, Dictionary<string, Action>) PrepaidList()
    {
        var reference = Grid.Selected(_prepaid, "Ref");
        var handlers = new Dictionary<string, Action>
        {
            ["prepaid-sell"] = () => Ui.Form(AdminForms.SellPrepaid(_db, _ref), Refresh)
        };
        if (reference != null)
        {
            handlers["prepaid-usage"] = () => Ui.Try("Pre-paid hours", () =>
            {
                var used = Queries.PrepaidUsage(_db, reference);
                Output.Text($"{reference} - hours used", used.Rows.Count == 0 ? "None of these hours have been used yet." : Output.TextTable(used));
            });
            handlers["prepaid-update"] = () => Ui.Form(AdminForms.UpdatePrepaid(_db, reference), Refresh);
            handlers["prepaid-invoice"] = () => Ui.Form(AdminForms.InvoicePrepaid(_db, reference), Refresh);
            handlers["prepaid-cancel"] = () => Ui.Form(AdminForms.CancelPrepaid(_db, reference), Refresh);
        }
        var row = Grid.SelectedRow(_prepaid);
        return (ActionRules.Prepaid(reference, row?["State"] as string, row?["Invoice"], row?["Used"]), handlers);
    }

    private void CompleteOnboarding()
    {
        var code = Grid.Selected(_onboarding, "Code");
        if (code == null) return;
        var description = Grid.Selected(_onboarding, "Description") ?? "";
        Ui.Form(AdminForms.CompleteOnboarding(_db, _ref, code, description), Refresh);
    }

    private void LogWeekly()
    {
        var names = Queries.InstanceNames(_db, _ref);
        if (names.Count == 0) { MessageBox.Query("Weekly report", "Add an instance first.", "Ok"); return; }
        var name = names.Count == 1 ? names[0] : Picker.Choose("Which instance?", names, SelectedInstance());
        if (name != null) Ui.Form(AdminForms.WeeklyReport(_db, _ref, name), Refresh);
    }

    private void ShowOnboarding() =>
        Ui.Try("Onboarding", () => Output.Show("Onboarding", Queries.OnboardingShow(_db, _ref)));

    private void AgreementActions()
    {
        var paused = Queries.Agreement(_db, _ref)?["SupportPausedFrom"] is not DBNull;
        Picker.Actions(ActionRules.AgreementWide(_ref, paused), new Dictionary<string, Action>
        {
            ["agreement-review"] = () => Ui.Form(AdminForms.RecordReview(_db, _ref), Refresh),
            ["agreement-usage"] = () => Ui.Try("Usage", () => Output.Show("Usage", Queries.AgreementUsage(_db, _ref))),
            ["onboarding-show"] = ShowOnboarding,
            ["ticket-new"] = () => Ui.Form(AdminForms.OpenTicket(_db, _ref), Refresh),
            ["agreement-quote"] = () => Ui.Form(AdminForms.AddQuote(_db, _ref), Refresh),
            ["prepaid-sell"] = () => Ui.Form(AdminForms.SellPrepaid(_db, _ref), Refresh),
            ["agreement-notice"] = () => Ui.Form(AdminForms.GiveNotice(_db, _ref), Refresh),
            ["agreement-pause"] = () => Ui.Form(AdminForms.PauseSupport(_db, _ref, !paused), Refresh),
            ["billing-run"] = () => Ui.RunBilling(_db, _ref, Refresh)
        });
    }

    /// <summary>Selects one pre-paid package and returns what it offers (for the self-test).</summary>
    internal MhActionSet PrepaidActions(string packageRef)
    {
        _tabs.SelectedTab = _prepaidTab;
        var rows = _prepaid.Table.Rows.Cast<DataRow>().ToList();
        var i = rows.FindIndex(r => (string)r["Ref"] == packageRef);
        if (i < 0) throw new InvalidOperationException($"{packageRef} is not listed on the Pre-paid hours tab.");
        _prepaid.SelectedRow = i;
        return Context().Set;
    }

    /// <summary>The agreement-wide actions, with nothing drawn (for the self-test).</summary>
    internal MhActionSet AgreementWideSet() =>
        ActionRules.AgreementWide(_ref, Queries.Agreement(_db, _ref)?["SupportPausedFrom"] is not DBNull);
}
