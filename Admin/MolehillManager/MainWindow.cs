using System.Data;
using System.Text;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>The main screen: Dashboard, Clients, Tickets and Billing tabs.</summary>
public sealed class MainWindow
{
    private AdminDb _db;
    private readonly Func<AdminDb?>? _reconnect;

    private TabView _tabs = null!;
    private TabView.Tab _dashTab = null!, _clientsTab = null!, _ticketsTab = null!, _billingTab = null!;
    private TableView _alerts = null!, _agreements = null!, _tickets = null!, _invoices = null!;
    private TextView _money = null!, _clientDetail = null!, _ticketDetail = null!, _invoiceDetail = null!;
    private CheckBox _showEnded = null!, _openOnly = null!;
    private RadioGroup _invoiceFilter = null!;
    private Label _status = null!;

    public MainWindow(AdminDb db, Func<AdminDb?>? reconnect = null)
    {
        _db = db;
        _reconnect = reconnect;
    }

    public void Build(Toplevel top)
    {
        var menu = new MenuBar(new[]
        {
            new MenuBarItem("_File", new[]
            {
                new MenuItem("_Connect...", "", Reconnect),
                new MenuItem("Save dashboard _HTML...", "", () => Ui.Try("Dashboard", () => Ui.Saved("Dashboard", AdminForms.SaveDashboardHtml(_db, AdminForms.DefaultOutputFolder)))),
                null!,
                new MenuItem("_Quit", "", () => Application.RequestStop(), null, null, Key.CtrlMask | Key.Q)
            }),
            new MenuBarItem("_Clients", new[]
            {
                new MenuItem("_New client...", "", NewClient),
                new MenuItem("New _agreement for an existing client...", "", () => Ui.Form(AdminForms.NewAgreement(_db), RefreshAll)),
                new MenuItem("_Open selected agreement", "", OpenAgreement),
                null!,
                new MenuItem("Schedule a _price change...", "", () => Ui.Form(AdminForms.PriceChange(_db), RefreshAll))
            }),
            new MenuBarItem("_Tickets", new[]
            {
                new MenuItem("_New ticket...", "", () => Ui.Form(AdminForms.OpenTicket(_db), RefreshAll)),
                new MenuItem("_Actions on selected ticket...", "", TicketAction)
            }),
            new MenuBarItem("_Billing", new[]
            {
                new MenuItem("_Run billing...", "", () => Ui.Form(AdminForms.RunBilling(_db), RefreshAll)),
                new MenuItem("_Actions on selected invoice...", "", InvoiceAction)
            }),
            new MenuBarItem("_Help", new[]
            {
                new MenuItem("_Keys", "", Keys),
                new MenuItem("_About", "", () => MessageBox.Query("About",
                    "Molehill Manager\n\nClients, agreements, tickets and billing for the\nMolehill Watch SQL Server Support Package.\n\nAll the rules live in the MolehillAdmin database;\nthis app is a front end to its procedures.", "Ok"))
            })
        });

        var win = new Window("") { X = 0, Y = 1, Width = Dim.Fill(), Height = Dim.Fill(1), Border = new Border { BorderStyle = BorderStyle.None } };
        _tabs = new TabView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(1) };
        _dashTab = new TabView.Tab("Dashboard", BuildDashboard());
        _clientsTab = new TabView.Tab("Clients", BuildClients());
        _ticketsTab = new TabView.Tab("Tickets", BuildTickets());
        _billingTab = new TabView.Tab("Billing", BuildBilling());
        _tabs.AddTab(_dashTab, true);
        _tabs.AddTab(_clientsTab, false);
        _tabs.AddTab(_ticketsTab, false);
        _tabs.AddTab(_billingTab, false);
        _status = new Label("") { X = 0, Y = Pos.AnchorEnd(1), Width = Dim.Fill() };
        win.Add(_tabs, _status);

        var statusBar = new StatusBar(new[]
        {
            new StatusItem(Key.F2, "~F2~ New", New),
            new StatusItem(Key.F3, "~F3~ Open/actions", Open),
            new StatusItem(Key.F5, "~F5~ Refresh", RefreshAll),
            new StatusItem(Key.F6, "~F6~ Run billing", () => Ui.Form(AdminForms.RunBilling(_db), RefreshAll)),
            new StatusItem(Key.F1, "~F1~ Keys", Keys),
            new StatusItem(Key.CtrlMask | Key.Q, "~^Q~ Quit", () => Application.RequestStop())
        });

        top.Add(menu, win, statusBar);
        RefreshAll();
    }

    // ------------------------------------------------------------------ tabs

    private View BuildDashboard()
    {
        var view = new View { Width = Dim.Fill(), Height = Dim.Fill() };
        var todo = new FrameView("To do (daily alerts)") { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Percent(70) };
        _alerts = Grid.Make();
        _alerts.CellActivated += _ => ShowAlert();
        todo.Add(_alerts);
        var money = new FrameView("Money") { X = 0, Y = Pos.Bottom(todo), Width = Dim.Fill(), Height = Dim.Fill() };
        _money = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(), ReadOnly = true };
        money.Add(_money);
        view.Add(todo, money);
        return view;
    }

    private View BuildClients()
    {
        var view = new View { Width = Dim.Fill(), Height = Dim.Fill() };
        _showEnded = new CheckBox("Show ended agreements") { X = 1, Y = 0 };
        _showEnded.Toggled += _ => RefreshClients();
        var hint = new Label("Enter: open the agreement (instances, onboarding, contacts, notice...)   F2: new client") { X = 30, Y = 0, ColorScheme = Colors.Menu };
        var listFrame = new FrameView("Agreements") { X = 0, Y = 1, Width = Dim.Fill(), Height = Dim.Percent(50) };
        _agreements = Grid.Make();
        _agreements.CellActivated += _ => OpenAgreement();
        _agreements.SelectedCellChanged += _ => ShowClientDetail();
        listFrame.Add(_agreements);
        var detailFrame = new FrameView("Details") { X = 0, Y = Pos.Bottom(listFrame), Width = Dim.Fill(), Height = Dim.Fill() };
        _clientDetail = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(), ReadOnly = true };
        detailFrame.Add(_clientDetail);
        view.Add(_showEnded, hint, listFrame, detailFrame);
        return view;
    }

    private View BuildTickets()
    {
        var view = new View { Width = Dim.Fill(), Height = Dim.Fill() };
        _openOnly = new CheckBox("Open tickets only", true) { X = 1, Y = 0 };
        _openOnly.Toggled += _ => RefreshTickets();
        var hint = new Label("Enter: respond, log time, estimate, close   F2: new ticket") { X = 30, Y = 0, ColorScheme = Colors.Menu };
        var listFrame = new FrameView("Tickets") { X = 0, Y = 1, Width = Dim.Fill(), Height = Dim.Percent(55) };
        _tickets = Grid.Make();
        _tickets.CellActivated += _ => TicketAction();
        _tickets.SelectedCellChanged += _ => ShowTicketDetail();
        listFrame.Add(_tickets);
        var detailFrame = new FrameView("Ticket") { X = 0, Y = Pos.Bottom(listFrame), Width = Dim.Fill(), Height = Dim.Fill() };
        _ticketDetail = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(), ReadOnly = true };
        detailFrame.Add(_ticketDetail);
        view.Add(_openOnly, hint, listFrame, detailFrame);
        return view;
    }

    private View BuildBilling()
    {
        var view = new View { Width = Dim.Fill(), Height = Dim.Fill() };
        _invoiceFilter = new RadioGroup(new NStack.ustring[] { "Outstanding (draft and sent)", "All" }) { X = 1, Y = 0, DisplayMode = DisplayModeLayout.Horizontal };
        _invoiceFilter.SelectedItemChanged += _ => RefreshBilling();
        var hint = new Label("Enter: view/save, mark sent/paid/void, adjust   F6: run billing") { X = 50, Y = 0, ColorScheme = Colors.Menu };
        var listFrame = new FrameView("Invoices") { X = 0, Y = 1, Width = Dim.Fill(), Height = Dim.Percent(55) };
        _invoices = Grid.Make();
        _invoices.CellActivated += _ => InvoiceAction();
        _invoices.SelectedCellChanged += _ => ShowInvoiceDetail();
        listFrame.Add(_invoices);
        var detailFrame = new FrameView("Invoice lines") { X = 0, Y = Pos.Bottom(listFrame), Width = Dim.Fill(), Height = Dim.Fill() };
        _invoiceDetail = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(), ReadOnly = true };
        detailFrame.Add(_invoiceDetail);
        view.Add(_invoiceFilter, hint, listFrame, detailFrame);
        return view;
    }

    // ------------------------------------------------------------------ refresh

    public void RefreshAll()
    {
        Ui.Try("Refresh", () =>
        {
            RefreshDashboard();
            RefreshClients();
            RefreshTickets();
            RefreshBilling();
            var b = new Microsoft.Data.SqlClient.SqlConnectionStringBuilder(_db.ConnectionString);
            _status.Text = $" {b.DataSource} / {b.InitialCatalog}   refreshed {DateTime.Now:HH:mm:ss}";
        });
    }

    private void RefreshDashboard()
    {
        var r = _db.Proc("dbo.usp_Dashboard");
        if (r.Tables.Count > 0) Grid.Bind(_alerts, r.Tables[0]);
        var sb = new StringBuilder();
        if (r.Tables.Count > 3 && r.Tables[3].Rows.Count > 0)
        {
            var m = r.Tables[3].Rows[0];
            sb.AppendLine($" Monthly recurring revenue £{m["MonthlyRecurringRevenue"]:N2}     Draft invoices £{m["DraftInvoicesTotal"]:N2}");
            sb.AppendLine($" Sent, unpaid £{m["UnpaidSentTotal"]:N2}     Overdue £{m["OverdueTotal"]:N2}     Paid this year £{m["PaidThisYear"]:N2}");
        }
        if (r.Tables.Count > 1) sb.AppendLine($" Open tickets: {r.Tables[1].Rows.Count}");
        _money.Text = sb.ToString();
    }

    private void RefreshClients()
    {
        Grid.Bind(_agreements, Queries.Agreements(_db, _showEnded.Checked));
        ShowClientDetail();
    }

    private void RefreshTickets()
    {
        Grid.Bind(_tickets, Queries.Tickets(_db, _openOnly.Checked));
        ShowTicketDetail();
    }

    private void RefreshBilling()
    {
        Grid.Bind(_invoices, Queries.Invoices(_db, _invoiceFilter.SelectedItem == 0 ? "Outstanding" : "All"));
        ShowInvoiceDetail();
    }

    private void ShowClientDetail()
    {
        var reference = Grid.Selected(_agreements, "Ref");
        if (reference == null) { _clientDetail.Text = "No agreements yet. F2 (or Clients > New client) adds one."; return; }
        Ui.Try("Client", () => _clientDetail.Text = AgreementWindow.Summary(_db, reference, includeInstances: true));
    }

    private void ShowTicketDetail()
    {
        var reference = Grid.Selected(_tickets, "Ticket");
        _ticketDetail.Text = reference == null ? "No tickets." : TicketActions.Describe(_db, reference);
    }

    private void ShowInvoiceDetail()
    {
        var no = Grid.Selected(_invoices, "Invoice");
        _invoiceDetail.Text = no == null ? "No invoices. F6 runs billing." : Output.TextTable(Queries.InvoiceLines(_db, no));
    }

    private void ShowAlert()
    {
        var row = Grid.SelectedRow(_alerts);
        if (row == null) return;
        Output.Text("Alert", string.Join("\n", row.Table.Columns.Cast<DataColumn>().Select(c => $"{c.ColumnName,-9}: {Output.Format(row[c])}")));
    }

    // ------------------------------------------------------------------ actions

    private void New()
    {
        if (_tabs.SelectedTab == _ticketsTab) Ui.Form(AdminForms.OpenTicket(_db), RefreshAll);
        else if (_tabs.SelectedTab == _billingTab) Ui.Form(AdminForms.RunBilling(_db), RefreshAll);
        else NewClient();
    }

    private void Open()
    {
        if (_tabs.SelectedTab == _ticketsTab) TicketAction();
        else if (_tabs.SelectedTab == _billingTab) InvoiceAction();
        else if (_tabs.SelectedTab == _dashTab) ShowAlert();
        else OpenAgreement();
    }

    private void NewClient()
    {
        var spec = AdminForms.NewClient(_db);
        var result = FormDialog.Show(spec);
        if (result == null) return;
        RefreshAll();
        var created = result.Tables.SelectMany(t => t.Rows.Cast<DataRow>())
            .Select(r => r.Table.Columns.Contains("AgreementRef") ? r["AgreementRef"] as string : null).LastOrDefault(r => r != null);
        if (created != null && MessageBox.Query("New client", $"Agreement {created} created. Open it now to add the instances?", "Open", "Later") == 0)
            new AgreementWindow(_db, created).Run();
        RefreshAll();
    }

    private void OpenAgreement()
    {
        var reference = Grid.Selected(_agreements, "Ref");
        if (reference == null) return;
        new AgreementWindow(_db, reference).Run();
        RefreshAll();
    }

    private void TicketAction()
    {
        var reference = Grid.Selected(_tickets, "Ticket");
        if (reference == null) { Ui.Form(AdminForms.OpenTicket(_db), RefreshAll); return; }
        TicketActions.Show(_db, reference, RefreshAll);
    }

    private void InvoiceAction()
    {
        var no = Grid.Selected(_invoices, "Invoice");
        if (no == null) return;
        Picker.Actions($"Invoice {no}",
            ("Save as HTML (and open)", () => Ui.Try("Invoice", () => Ui.Saved("Invoice", AdminForms.SaveInvoiceHtml(_db, no, AdminForms.DefaultOutputFolder)))),
            ("Mark sent", () => Ui.Form(AdminForms.SetInvoiceStatus(_db, no, "Sent"), RefreshAll)),
            ("Mark paid", () => Ui.Form(AdminForms.SetInvoiceStatus(_db, no, "Paid"), RefreshAll)),
            ("Add an adjustment or credit (draft only)", () => Ui.Form(AdminForms.AdjustInvoice(_db, no), RefreshAll)),
            ("Void", () =>
            {
                if (MessageBox.Query("Void", $"Void {no}? Any time it billed becomes billable again.", "Void", "Cancel") == 0)
                    Ui.Form(AdminForms.SetInvoiceStatus(_db, no, "Void"), RefreshAll);
            }));
    }

    private void Reconnect()
    {
        var db = _reconnect?.Invoke();
        if (db == null) return;
        _db = db;
        RefreshAll();
    }

    private static void Keys() => MessageBox.Query("Keys", """
        F2   New: client, ticket or billing run (by tab)
        F3   Open / actions for the selected row (Enter too)
        F5   Refresh everything
        F6   Run billing
        Ctrl+Q  Quit

        Tab / Shift+Tab move between controls, arrows move
        between the tabs when the tab strip has focus.
        In a form: * marks a required field; blank means
        'use the default'. Enter on a choice opens the list.
        """, "Ok");
}
