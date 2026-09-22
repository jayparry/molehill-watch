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
        workView.Add(new Label("A day's work is billed as one line. Everything logged on the same day counts together.")
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
                      + (e["PurchaseOrder"] is DBNull ? "" : $"   PO: {F("PurchaseOrder")}"));
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

    private (string Title, List<(string Label, Action Run)> Items) ContextActions()
    {
        var tab = _tabs.SelectedTab;
        var log = ("Log work", (Action)LogWork);

        if (tab == _invoiceTab)
        {
            var newInvoice = ("New invoice typed by hand", (Action)(() => Ui.Form(AdminForms.NewInvoice(_db, _ref), Refresh)));
            var no = Grid.Selected(_invoices, "Invoice");
            if (no == null) return ("Invoices", new() { newInvoice, log });
            return ($"Invoice {no}", InvoiceActions.List(_db, no, Refresh).Append(newInvoice).ToList());
        }
        if (tab == _contactTab)
        {
            var add = ("Add a contact", (Action)(() => Ui.Form(AdminForms.AddContact(_db, _clientName), Refresh)));
            var idText = Grid.Selected(_contacts, "Id");
            if (idText == null || !int.TryParse(idText, out var id)) return ("Contacts", new() { add });
            var name = Grid.Selected(_contacts, "Name") ?? "Contact";
            return ($"Contact {name}", new()
            {
                ("Edit details (name, e-mail, phone, raises tickets / receives invoices)", () => Ui.Form(AdminForms.EditContact(_db, id), Refresh)),
                ("Remove as a contact (kept in history)", () => Ui.Form(AdminForms.RemoveContact(_db, id), Refresh)),
                add
            });
        }
        if (tab == _entriesTab)
        {
            var idText = Grid.Selected(_entries, "Id");
            if (idText == null || !int.TryParse(idText, out var id)) return ("Everything logged", new() { log });
            var invoiced = Grid.Selected(_entries, "Invoiced");
            var list = new List<(string, Action)>();
            if (invoiced != null && invoiced.StartsWith("MDS") || invoiced is { } s && s.Contains('-') && !s.Contains("billing run") && !s.Contains("billable"))
                list.Add(("Already invoiced - void the invoice first to change it", () =>
                    MessageBox.Query("Logged work", $"This time is on invoice {invoiced}. Void that invoice, then change the time.", "Ok")));
            else
            {
                list.Add(("Correct it (date, time, description)", () => Ui.Form(AdminForms.EditTimeEntry(_db, id), Refresh)));
                list.Add(("Remove it", () => Ui.Form(AdminForms.DeleteTimeEntry(_db, id), Refresh)));
            }
            list.Add(log);
            return ($"Logged work #{id}", list);
        }

        // Days worked
        var date = Grid.Selected(_work, "Date");
        if (date == null) return ("Days worked", new() { log });
        return ($"{date}", new()
        {
            log,
            ("Correct or remove what was logged that day", () =>
            {
                _tabs.SelectedTab = _entriesTab;
                MessageBox.Query("Days worked", "Everything logged is on the next tab - pick the entry there to correct or remove it.", "Ok");
            })
        });
    }

    private void RowActions()
    {
        var (title, items) = ContextActions();
        Picker.Actions(title, items.ToArray());
    }

    private void ShowActions()
    {
        var (title, items) = ContextActions();
        items.Add(("Engagement actions (change, finish, invoice, billing) ...", EngagementActions));
        Picker.Actions(title, items.ToArray());
    }

    /// <summary>The F4 menu's labels for the tab showing (for the self-test).</summary>
    internal List<string> ActionLabels(TabView.Tab? tab = null)
    {
        if (tab != null) _tabs.SelectedTab = tab;
        var (title, items) = ContextActions();
        return items.Select(i => i.Label).Prepend(title).ToList();
    }

    internal IEnumerable<TabView.Tab> Tabs => _tabs.Tabs;

    private void EngagementActions()
    {
        var e = Queries.Engagement(_db, _ref);
        var finished = e?["Status"] as string is "Completed" or "Cancelled";
        var list = new List<(string, Action)>
        {
            ("Log work", LogWork),
            ("Change it (rate, name, PO, dates, on hold)", () => Ui.Form(AdminForms.EditEngagement(_db, _ref), Refresh))
        };
        if (!finished)
        {
            list.Add(("Finished - invoice what is left", () => Ui.Form(AdminForms.CompleteEngagement(_db, _ref), Refresh)));
            list.Add(("Cancel (nothing invoiced)", () => Ui.Form(AdminForms.CancelEngagement(_db, _ref), Refresh)));
        }
        list.Add(("New invoice typed by hand", () => Ui.Form(AdminForms.NewInvoice(_db, _ref), Refresh)));
        list.Add(("Run billing for this engagement", () => Ui.Try("Billing", () =>
        {
            var r = _db.Proc("dbo.usp_Billing_Run", ("@Client", _ref));
            if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing new to invoice.");
            Output.Show("Billing", r);
            Refresh();
        })));
        Picker.Actions($"Engagement {_ref}", list.ToArray());
    }
}
