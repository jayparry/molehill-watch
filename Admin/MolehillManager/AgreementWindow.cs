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
    private TabView.Tab _instTab = null!, _onbTab = null!, _contactTab = null!, _ticketTab = null!, _weeklyTab = null!;
    private TableView _instances = null!, _onboarding = null!, _contacts = null!, _tickets = null!, _weekly = null!;

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
        _instances = Table(InstanceActions);
        _onboarding = Table(CompleteOnboarding);
        _contacts = Table(ContactActions);
        _tickets = Table(TicketAction);
        _weekly = Table(LogWeekly);

        _instTab = new TabView.Tab("Instances", _instances);
        _onbTab = new TabView.Tab("Onboarding", _onboarding);
        _contactTab = new TabView.Tab("Contacts", _contacts);
        _ticketTab = new TabView.Tab("Tickets", _tickets);
        _weeklyTab = new TabView.Tab("Weekly reports", _weekly);
        _tabs.AddTab(_instTab, true);
        _tabs.AddTab(_onbTab, false);
        _tabs.AddTab(_contactTab, false);
        _tabs.AddTab(_ticketTab, false);
        _tabs.AddTab(_weeklyTab, false);

        var hint = new Label("Enter on a row: actions for it (contacts: edit, remove, add back).  F2 adds.  F4: all agreement actions.")
            { X = 0, Y = Pos.AnchorEnd(2), Width = Dim.Fill(), ColorScheme = Colors.Menu };
        _dialog.Add(_summary, _tabs, hint);

        actions.Clicked += AllActions;
        add.Clicked += Add;
        close.Clicked += () => Application.RequestStop();
        _dialog.KeyPress += e =>
        {
            switch (e.KeyEvent.Key)
            {
                case Key.F2: Add(); e.Handled = true; break;
                case Key.F4: AllActions(); e.Handled = true; break;
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
            Grid.Bind(_contacts, Queries.Contacts(_db, _ref, includeRemoved: true));
            Grid.Bind(_tickets, Queries.Tickets(_db, openOnly: false, _ref));
            Grid.Bind(_weekly, Queries.WeeklyReports(_db, _ref));
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
        sb.AppendLine($"Billing: {(a["BillingEmail"] is DBNull ? "(no billing e-mail)" : F("BillingEmail"))}" +
                      (a["Address"] is DBNull ? "" : $"   {F("Address")}"));

        var usage = db.Proc("dbo.usp_Agreement_Usage", ("@Client", agreementRef));
        if (usage.First is { Rows.Count: > 0 } u)
        {
            var r = u.Rows[0];
            sb.AppendLine($"This cycle ({Output.Format(r["CycleStart"])} - {Output.Format(r["CycleEnd"])}): " +
                          $"{Output.Format(r["BusinessHoursLogged"])} of {Output.Format(r["IncludedHours"])} included hours used, " +
                          $"{Output.Format(r["IncludedHoursRemaining"])} left; {Output.Format(r["OutOfHoursLogged"])} h out of hours");
        }
        else sb.AppendLine(usage.Messages.FirstOrDefault() ?? "");

        if (includeInstances)
        {
            var inst = Queries.Instances(db, agreementRef);
            var fee = inst.Rows.Cast<DataRow>().Where(r => r["Fee"] is decimal).Sum(r => (decimal)r["Fee"]);
            sb.AppendLine().AppendLine($"Instances (monthly fee £{fee:N2}):");
            sb.Append(inst.Rows.Count == 0 ? "(none yet - open the agreement and press F2)\n" : Output.TextTable(inst));
            var contacts = Queries.Contacts(db, agreementRef).DefaultView.ToTable(false, "Name", "Email", "Phone", "Named", "Billing", "From");
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
        else if (tab == _onbTab) CompleteOnboarding();
        else Ui.Form(AdminForms.AddInstance(_db, _ref), Refresh);
    }

    private void InstanceActions()
    {
        var name = SelectedInstance();
        if (name == null) { Ui.Form(AdminForms.AddInstance(_db, _ref), Refresh); return; }
        Picker.Actions(name,
            ("Update versions, database count, monitoring date, notes", () => Ui.Form(AdminForms.UpdateInstance(_db, _ref, name), Refresh)),
            ("Log a weekly report sent", () => Ui.Form(AdminForms.WeeklyReport(_db, _ref, name), Refresh)),
            ("Open a ticket for this instance", () =>
            {
                var spec = AdminForms.OpenTicket(_db, _ref);
                var withInstance = new FormSpec
                {
                    Title = spec.Title, Intro = spec.Intro, Submit = spec.Submit,
                    Fields = spec.Fields.Select(f => f.Name == "InstanceName" ? Field.Text("InstanceName", f.Label, def: name) : f).ToList()
                };
                Ui.Form(withInstance, Refresh);
            }),
            ("Record unsupported-version risk acceptance", () => Ui.Form(AdminForms.RiskAcceptance(_db, _ref, name), Refresh)),
            ("Remove from cover", () => Ui.Form(AdminForms.RemoveInstance(_db, _ref, name), Refresh)),
            ("Add another instance", () => Ui.Form(AdminForms.AddInstance(_db, _ref), Refresh)));
    }

    private void ContactActions()
    {
        var idText = Grid.Selected(_contacts, "Id");
        if (idText == null || !int.TryParse(idText, out var id)) { Ui.Form(AdminForms.AddContact(_db, _clientName), Refresh); return; }
        var name = Grid.Selected(_contacts, "Name") ?? "Contact";
        var current = Grid.Selected(_contacts, "Status") == "Current";
        var actions = new List<(string, Action)>
        {
            ("Edit details (name, e-mail, phone, named / billing)", () => Ui.Form(AdminForms.EditContact(_db, id), Refresh)),
            current ? ("Remove as a contact (kept in history)", () => Ui.Form(AdminForms.RemoveContact(_db, id), Refresh))
                    : ("Add back as a contact", () => Ui.Form(AdminForms.ReaddContact(_db, id), Refresh)),
            ("History (dates as a contact)", () => Ui.Try("History", () =>
                Output.Text($"{name} - contact history", Output.TextTable(Queries.ContactPeriods(_db, id))))),
            ("Add another contact", () => Ui.Form(AdminForms.AddContact(_db, _clientName), Refresh))
        };
        Picker.Actions(name, actions.ToArray());
    }

    private void CompleteOnboarding()
    {
        var code = Grid.Selected(_onboarding, "Code");
        if (code == null) return;
        var description = Grid.Selected(_onboarding, "Description") ?? "";
        Ui.Form(AdminForms.CompleteOnboarding(_db, _ref, code, description), Refresh);
    }

    private void TicketAction()
    {
        var reference = Grid.Selected(_tickets, "Ticket");
        if (reference == null) { Ui.Form(AdminForms.OpenTicket(_db, _ref), Refresh); return; }
        TicketActions.Show(_db, reference, Refresh);
    }

    private void LogWeekly()
    {
        var names = Queries.InstanceNames(_db, _ref);
        if (names.Count == 0) { MessageBox.Query("Weekly report", "Add an instance first.", "Ok"); return; }
        var name = names.Count == 1 ? names[0] : Picker.Choose("Which instance?", names, SelectedInstance());
        if (name != null) Ui.Form(AdminForms.WeeklyReport(_db, _ref, name), Refresh);
    }

    private void AllActions()
    {
        var paused = Queries.Agreement(_db, _ref)?["SupportPausedFrom"] is not DBNull;
        Picker.Actions($"Agreement {_ref}",
            ("Add an instance / Azure SQL server or pool", () => Ui.Form(AdminForms.AddInstance(_db, _ref), Refresh)),
            ("Actions for the selected instance", InstanceActions),
            ("Add a contact", () => Ui.Form(AdminForms.AddContact(_db, _clientName), Refresh)),
            ("Edit, remove or add back the selected contact", () => { _tabs.SelectedTab = _contactTab; ContactActions(); }),
            ("Mark the selected onboarding item done", () => { _tabs.SelectedTab = _onbTab; CompleteOnboarding(); }),
            ("Open a ticket", () => Ui.Form(AdminForms.OpenTicket(_db, _ref), Refresh)),
            ("Log a weekly report sent", LogWeekly),
            ("Record the initial review delivered", () => Ui.Form(AdminForms.RecordReview(_db, _ref), Refresh)),
            ("Included hours used this cycle", () => Ui.Try("Usage", () => Output.Show("Usage", _db.Proc("dbo.usp_Agreement_Usage", ("@Client", _ref))))),
            ("Onboarding checklist and version status", () => Ui.Try("Onboarding", () => Output.Show("Onboarding", _db.Proc("dbo.usp_Onboarding_Show", ("@Client", _ref))))),
            ("Project quote", () => Ui.Form(AdminForms.AddQuote(_db, _ref), Refresh)),
            ("Notice: preview or record the end date", () => Ui.Form(AdminForms.GiveNotice(_db, _ref), Refresh)),
            (paused ? "Resume support" : "Pause support (late payment)", () => Ui.Form(AdminForms.PauseSupport(_db, _ref, !paused), Refresh)),
            ("Run billing for this agreement", () => Ui.Try("Billing", () =>
            {
                var r = _db.Proc("dbo.usp_Billing_Run", ("@Client", _ref));
                if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing new to invoice.");
                Output.Show("Billing", r);
                Refresh();
            })));
    }
}
