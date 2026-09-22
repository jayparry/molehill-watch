using System.Data;
using System.Text;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>The main screen: Dashboard, Clients, Tickets and Billing tabs.</summary>
public sealed class MainWindow
{
    private AdminDb _db;
    private readonly Func<AdminDb?>? _reconnect;
    private readonly string? _configPath;
    private readonly Func<int>? _autoRefreshMinutes;
    private int _minutesSinceRefresh;

    private TabView _tabs = null!;
    private TabView.Tab _dashTab = null!, _clientsTab = null!, _ticketsTab = null!, _billingTab = null!;
    private TableView _alerts = null!, _agreements = null!, _tickets = null!, _invoices = null!;
    private TextView _money = null!, _clientDetail = null!, _ticketDetail = null!, _invoiceDetail = null!;
    private CheckBox _showEnded = null!, _openOnly = null!;
    private RadioGroup _invoiceFilter = null!;
    private Label _status = null!;

    public MainWindow(AdminDb db, string? configPath = null, Func<AdminDb?>? reconnect = null, Func<int>? autoRefreshMinutes = null)
    {
        _db = db;
        _configPath = configPath;
        _reconnect = reconnect;
        _autoRefreshMinutes = autoRefreshMinutes;
    }

    /// <summary>
    /// A new full-screen top level with the main window on it, for Application.Run. Application.Top can't be used:
    /// Terminal.Gui disposes it when a dialog (settings, password, install) runs before the main loop starts.
    /// </summary>
    public Toplevel CreateTop()
    {
        var top = Toplevel.Create();
        Build(top);
        return top;
    }

    public void Build(Toplevel top)
    {
        var menu = new MenuBar(new[]
        {
            new MenuBarItem("_File", new[]
            {
                new MenuItem("_Settings...", "", Reconnect),
                new MenuItem("_Business and invoice details...", "", () => Ui.Try("Business details", () => Ui.Form(AdminForms.BusinessDetails(_db), RefreshAll))),
                new MenuItem("Save dashboard _HTML...", "", () => Ui.Try("Dashboard", () => Ui.Saved("Dashboard", AdminForms.SaveDashboardHtml(_db, AdminForms.OutputFolder)))),
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
                new MenuItem("_Actions on selected ticket...", "", () => { _tabs.SelectedTab = _ticketsTab; ShowActions(); })
            }),
            new MenuBarItem("_Billing", new[]
            {
                new MenuItem("_Run billing...", "", () => Ui.Form(AdminForms.RunBilling(_db), RefreshAll)),
                new MenuItem("_Actions on selected invoice...", "", () => { _tabs.SelectedTab = _billingTab; ShowActions(); })
            }),
            new MenuBarItem("_Help", new[]
            {
                new MenuItem("_Keys", "", Keys),
                new MenuItem("_About", "", () => MessageBox.Query("About",
                    "Molehill Manager\n\nClients, agreements, tickets and billing for the\nMolehill Watch SQL Server Support Package.\n\nAll the rules live in the MolehillAdmin database;\nthis app is a front end to its procedures.\n\n"
                    + $"Settings: {_configPath ?? "(none)"}\nOutput:   {AdminForms.OutputFolder}", "Ok"))
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
            new StatusItem(Key.F4, "~F4~ Actions", ShowActions),
            new StatusItem(Key.F5, "~F5~ Refresh", RefreshAll),
            new StatusItem(Key.F6, "~F6~ Run billing", () => Ui.Form(AdminForms.RunBilling(_db), RefreshAll)),
            new StatusItem(Key.F1, "~F1~ Keys", Keys),
            new StatusItem(Key.CtrlMask | Key.Q, "~^Q~ Quit", () => Application.RequestStop())
        });

        top.Add(menu, win, statusBar);
        RefreshAll();

        // auto refresh: checked every minute, so a changed setting takes effect without a restart
        if (_autoRefreshMinutes != null && Application.MainLoop != null)
            Application.MainLoop.AddTimeout(TimeSpan.FromMinutes(1), _ =>
            {
                var every = _autoRefreshMinutes();
                if (every > 0 && ++_minutesSinceRefresh >= every) RefreshAll();
                return true;
            });
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
        _tickets.CellActivated += _ => ShowActions();
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
        _invoices.CellActivated += _ => ShowActions();
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
            _minutesSinceRefresh = 0;
            _status.Text = $" {b.DataSource} / {b.InitialCatalog}   refreshed {DateTime.Now:HH:mm:ss}"
                         + (_autoRefreshMinutes?.Invoke() is > 0 and var m ? $" (auto every {m} min)" : "");
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

    /// <summary>F4: the actions for the tab showing and its selected row.</summary>
    private (string Title, List<(string Label, Action Run)> Items) ContextActions()
    {
        if (_tabs.SelectedTab == _ticketsTab)
        {
            var newTicket = ("New ticket", (Action)(() => Ui.Form(AdminForms.OpenTicket(_db), RefreshAll)));
            var reference = Grid.Selected(_tickets, "Ticket");
            if (reference == null) return ("Tickets", new() { newTicket });
            var list = TicketActions.List(_db, reference, RefreshAll);
            list.Add(newTicket);
            return ($"Ticket {reference}", list);
        }
        if (_tabs.SelectedTab == _billingTab)
        {
            var run = ("Run billing", (Action)(() => Ui.Form(AdminForms.RunBilling(_db), RefreshAll)));
            var no = Grid.Selected(_invoices, "Invoice");
            if (no == null) return ("Billing", new() { run });
            return ($"Invoice {no}", new()
            {
                ("Save as HTML (and open)", () => Ui.Try("Invoice", () => Ui.Saved("Invoice", AdminForms.SaveInvoiceHtml(_db, no, AdminForms.OutputFolder)))),
                ("Mark sent", () => Ui.Form(AdminForms.SetInvoiceStatus(_db, no, "Sent"), RefreshAll)),
                ("Mark paid", () => Ui.Form(AdminForms.SetInvoiceStatus(_db, no, "Paid"), RefreshAll)),
                ("Add an adjustment or credit (draft only)", () => Ui.Form(AdminForms.AdjustInvoice(_db, no), RefreshAll)),
                ("Void", () =>
                {
                    if (MessageBox.Query("Void", $"Void {no}? Any time it billed becomes billable again.", "Void", "Cancel") == 0)
                        Ui.Form(AdminForms.SetInvoiceStatus(_db, no, "Void"), RefreshAll);
                }),
                run
            });
        }
        if (_tabs.SelectedTab == _dashTab)
        {
            var list = new List<(string, Action)>();
            var row = Grid.SelectedRow(_alerts);
            if (row != null)
            {
                list.Add(("Show the whole alert", ShowAlert));
                var client = row.Table.Columns.Contains("Client") ? row["Client"] as string : null;
                var reference = string.IsNullOrEmpty(client) ? null
                    : _db.Scalar("""
                        SELECT TOP (1) a.AgreementRef FROM dbo.Agreement a JOIN dbo.Client c ON c.ClientId = a.ClientId
                        WHERE c.ClientName = @c ORDER BY CASE WHEN a.EndDate IS NULL THEN 0 ELSE 1 END, a.StartDate DESC;
                        """, ("@c", client)) as string;
                if (reference != null) list.Add(($"Open {client}'s agreement ({reference})", () => { new AgreementWindow(_db, reference).Run(); RefreshAll(); }));
            }
            list.Add(("Save the dashboard as HTML", () => Ui.Try("Dashboard", () => Ui.Saved("Dashboard", AdminForms.SaveDashboardHtml(_db, AdminForms.OutputFolder)))));
            return ("Dashboard", list);
        }
        // Clients
        var newClient = ("New client", (Action)NewClient);
        var agreement = Grid.Selected(_agreements, "Ref");
        if (agreement == null) return ("Clients", new() { newClient });
        var name = Grid.Selected(_agreements, "Client");
        return ($"{name} ({agreement})", new()
        {
            ("Open the agreement (instances, contacts, onboarding, pre-paid hours...)", OpenAgreement),
            ("Open a ticket", () => Ui.Form(AdminForms.OpenTicket(_db, agreement), RefreshAll)),
            ("Sell pre-paid hours", () => Ui.Form(AdminForms.SellPrepaid(_db, agreement), RefreshAll)),
            ("Run billing for this agreement", () => Ui.Try("Billing", () =>
            {
                var r = _db.Proc("dbo.usp_Billing_Run", ("@Client", agreement));
                if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing new to invoice.");
                Output.Show("Billing", r);
                RefreshAll();
            })),
            newClient
        });
    }

    private void ShowActions()
    {
        var (title, items) = ContextActions();
        Picker.Actions(title, items.ToArray());
    }

    /// <summary>The F4 menu's labels for a tab (for the self-test).</summary>
    internal List<string> ActionLabels(int tabIndex)
    {
        _tabs.SelectedTab = _tabs.Tabs.ElementAt(tabIndex);
        var (title, items) = ContextActions();
        return items.Select(i => i.Label).Prepend(title).ToList();
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

    private void Reconnect()
    {
        var db = _reconnect?.Invoke();
        if (db == null) return;
        _db = db;
        RefreshAll();
    }

    private static void Keys() => MessageBox.Query("Keys", """
        F2   New: client, ticket or billing run (by tab)
        F4   Actions for the selected row on this tab
             (Enter too; on Clients, Enter opens the agreement)
        F5   Refresh everything

        In an agreement: F2 adds to the tab showing, F4 lists
        the actions for the selected row plus the agreement
        actions (review, notice, pause, usage, billing).
        F6   Run billing
        Ctrl+Q  Quit

        Tab / Shift+Tab move between controls, arrows move
        between the tabs when the tab strip has focus.
        In a form: * marks a required field; blank means
        'use the default'. Enter on a choice opens the list.
        """, "Ok");
}
