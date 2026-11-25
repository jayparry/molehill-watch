using System.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// MolehillManager.Grid is the terminal grid helper and wins over WPF's in here, being nearer.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   A form in its own small window, and the two places the app has to wait for an answer. These
///   need ShowDialog and so cannot be tested at all, which is exactly why there are no decisions in
///   here: the laying out is <see cref="MhForm"/>, the parsing and the messages are
///   <see cref="FormValues"/> and <see cref="AdminDb.Explain"/>, and all of those are checked.
/// </summary>
internal static class Dialogs
{
    private static Window Frame(Window? owner, string title, UIElement content, double width, double height)
    {
        var window = new Window
        {
            Title = title,
            Width = width,
            Height = height,
            WindowStartupLocation = owner == null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            Background = AppResources.Resource<Brush>("Paper"),
            Content = content
        };
        // start-up asks its questions before there is a window to own them
        if (owner != null) window.Owner = owner;
        return window;
    }

    /// <summary>Puts a form up and returns what the procedures said, or null if it was cancelled.</summary>
    public static ProcResult? Form(Window? owner, FormSpec spec)
    {
        var form = new MhForm(spec);
        ProcResult? done = null;

        var save = new Button { Content = "Save", IsDefault = true, MinWidth = 90, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(10, 4, 10, 4) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4) };
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(16, 0, 16, 14),
            Children = { save, cancel }
        };

        var rows = new WpfGrid();
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        WpfGrid.SetRow(form, 0);
        WpfGrid.SetRow(buttons, 1);
        rows.Children.Add(form);
        rows.Children.Add(buttons);

        var window = Frame(owner, spec.Title, rows, 720, 620);
        // the form stays open on a bad value, with the reason on it, as the terminal's does
        save.Click += (_, _) => { done = form.Submit(); if (done != null) window.DialogResult = true; };
        window.ShowDialog();
        return done;
    }

    /// <summary>Shows something to read - an alert, or what a procedure said.</summary>
    public static void Read(Window? owner, string title, UIElement content)
    {
        var close = new Button { Content = "Close", IsDefault = true, IsCancel = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4) };
        var rows = new WpfGrid();
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        WpfGrid.SetRow(content, 0);
        rows.Children.Add(content);
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(16, 0, 16, 14),
            Children = { close }
        };
        WpfGrid.SetRow(bar, 1);
        rows.Children.Add(bar);
        var window = Frame(owner, title, rows, 760, 620);
        close.Click += (_, _) => window.Close();
        window.ShowDialog();
    }

    /// <summary>
    ///   Picks one of a list. Two flows need it - which line to take off a draft invoice, and which
    ///   time entry to correct - and both are a list the user has to see before they can answer, so
    ///   neither fits in a row of buttons. Returns null if nothing was chosen.
    /// </summary>
    public static int? Pick(Window? owner, string title, IReadOnlyList<string> labels)
    {
        int? chosen = null;
        var list = new ListBox
        {
            Margin = new Thickness(16, 16, 16, 10),
            FontFamily = AppResources.Resource<FontFamily>("BodyFont")
        };
        foreach (var label in labels) list.Items.Add(label);
        list.SelectedIndex = 0;

        var ok = new Button { Content = "Ok", IsDefault = true, MinWidth = 90, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(10, 4, 10, 4) };
        var cancel = new Button { Content = "Cancel", IsCancel = true, MinWidth = 90, Padding = new Thickness(10, 4, 10, 4) };
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(16, 0, 16, 14),
            Children = { ok, cancel }
        };
        var rows = new WpfGrid();
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        WpfGrid.SetRow(list, 0);
        WpfGrid.SetRow(bar, 1);
        rows.Children.Add(list);
        rows.Children.Add(bar);

        var window = Frame(owner, title, rows, 640, 460);
        void Take() { if (list.SelectedIndex >= 0) { chosen = list.SelectedIndex; window.Close(); } }
        ok.Click += (_, _) => Take();
        list.MouseDoubleClick += (_, _) => Take();
        window.ShowDialog();
        return chosen;
    }

    /// <summary>Asks a yes/no sort of question. Returns the index of the button chosen.</summary>
    public static int Ask(Window? owner, string title, string message, params string[] buttons)
    {
        var chosen = buttons.Length - 1;
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(16, 10, 16, 14)
        };
        var rows = new WpfGrid();
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var text = new TextBlock
        {
            Text = message,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(18, 18, 18, 0),
            Foreground = AppResources.Resource<Brush>("Ink")
        };
        WpfGrid.SetRow(text, 0);
        WpfGrid.SetRow(bar, 1);
        rows.Children.Add(text);
        rows.Children.Add(bar);
        var window = Frame(owner, title, rows, 480, 210);
        window.SizeToContent = SizeToContent.Height;
        for (var i = 0; i < buttons.Length; i++)
        {
            var index = i;
            var button = new Button
            {
                Content = buttons[i],
                MinWidth = 90,
                Margin = new Thickness(8, 0, 0, 0),
                Padding = new Thickness(10, 4, 10, 4),
                IsDefault = i == 0
            };
            button.Click += (_, _) => { chosen = index; window.Close(); };
            bar.Children.Add(button);
        }
        window.ShowDialog();
        return chosen;
    }
}

/// <summary>
///   The window. Deliberately thin: it owns the database, the refresh and the dialogs, and hands
///   every decision to <see cref="Shell"/> and the pages, which are tested without it. A Window
///   that is never shown arranges to nothing, so anything worth asserting must not live here.
/// </summary>
internal sealed class MhWindow : Window
{
    private readonly AppConfig _config;
    private readonly string _configPath;
    private readonly Shell _shell;
    private AdminDb _db;          // replaced when the settings screen points somewhere else
    private bool _showEnded;

    public MhWindow(AdminDb db, AppConfig config, string configPath)
    {
        _db = db;
        _config = config;
        _configPath = configPath;
        _shell = new Shell(Open);

        Title = "Molehill Manager";
        Width = 1200;
        Height = 780;
        MinWidth = 780;
        MinHeight = 520;
        Background = AppResources.Resource<Brush>("Paper");
        Content = _shell;

        // F5 refreshes, as in the terminal - as an accelerator, never as the only way to do it
        KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.F5) Report.Try("Refresh", Reload); };

        Reload();
    }

    private void Reload() => _shell.Load(Nav.Build(Queries.Engagements(_db, _showEnded)));

    /// <summary>
    ///   Which page to build. The choosing is <see cref="Nav.Opening"/>, where it can be asserted
    ///   without a database or a window; all this does is build what it was told to.
    /// </summary>
    private IShellPage Open(NavNode node) => Nav.Opening(node) switch
    {
        Opens.Today => Today(),
        Opens.Clients => Clients(node),
        Opens.Settings => Settings(),
        Opens.Agreement => AgreementFor(node.Key!),
        Opens.Engagement => EngagementFor(node.Key!),
        _ => new PlainPage(node.Label, NotBuilt(node))
    };

    /// <summary>
    ///   Re-reads everything after something changed it. Load stays where it was and rebuilds the
    ///   page it is on, so this is all that is needed - asking the shell to go there afterwards
    ///   would build the page, and run its half-dozen queries, a second time.
    /// </summary>
    private void Again() => Reload();

    private IShellPage AgreementFor(string reference)
    {
        var a = Queries.Agreement(_db, reference);
        var data = new AgreementData(
            reference,
            a?["ClientName"] as string ?? "",
            Detail.AgreementSummary(_db, reference, includeInstances: false),
            a != null && a["SupportPausedFrom"] is not DBNull,
            Queries.Instances(_db, reference),
            Queries.Onboarding(_db, reference),
            Queries.Contacts(_db, reference, includeRemoved: true),
            Queries.Tickets(_db, openOnly: false, reference),
            Queries.WeeklyReports(_db, reference),
            Queries.Prepaid(_db, reference));
        return AgreementPage.Build(data, null, ClientsPage.NotYet,
            (id, tab) => Report.Try(tab.Header, () => RunOnAgreement(reference, data.ClientName, id, tab)));
    }

    private IShellPage EngagementFor(string reference)
    {
        var e = Queries.Engagement(_db, reference);
        var data = new EngagementData(
            reference,
            e?["ClientName"] as string ?? "",
            Detail.EngagementSummary(_db, reference, includeWork: false),
            e?["Status"] as string is "Completed" or "Cancelled",
            Queries.ConsultancyWork(_db, reference),
            Queries.WorkEntries(_db, reference),
            Queries.EngagementInvoices(_db, reference),
            Queries.Contacts(_db, reference, includeRemoved: false));
        return EngagementPage.Build(data, null, ClientsPage.NotYet,
            (id, tab) => Report.Try(tab.Header, () => RunOnEngagement(reference, data.ClientName, id, tab)));
    }

    private static int? SelectedId(DetailTab tab) => tab.Grid.SelectedRow()?["Id"] as int?;

    /// <summary>
    ///   Everything an agreement page can do. One place, and it throws on an id it does not know -
    ///   the guard that replaced checking a dictionary of handlers for completeness, and a better
    ///   one, because the self-test presses every enabled button on every tab and so walks it.
    /// </summary>
    private void RunOnAgreement(string reference, string clientName, string id, DetailTab tab)
    {
        var grid = tab.Grid;
        switch (id)
        {
            // ---- instances
            case "instance-add": Form(AdminForms.AddInstance(_db, reference)); break;
            case "instance-update": Form(AdminForms.UpdateInstance(_db, reference, grid.Selected("Instance")!)); break;
            case "instance-weekly": Form(AdminForms.WeeklyReport(_db, reference, grid.Selected("Instance")!)); break;
            case "instance-ticket": Form(AdminForms.OpenTicketFor(_db, reference, grid.Selected("Instance")!)); break;
            case "instance-risk": Form(AdminForms.RiskAcceptance(_db, reference, grid.Selected("Instance")!)); break;
            case "instance-remove": Form(AdminForms.RemoveInstance(_db, reference, grid.Selected("Instance")!)); break;

            // ---- onboarding
            case "onboarding-done":
                Form(AdminForms.CompleteOnboarding(_db, reference, grid.Selected("Code")!, grid.Selected("Description") ?? ""));
                break;
            case "onboarding-show": Show("Onboarding", Queries.OnboardingShow(_db, reference)); break;

            // ---- contacts
            case "contact-add": Form(AdminForms.AddContact(_db, clientName)); break;
            case "contact-edit": Form(AdminForms.EditContact(_db, SelectedId(tab)!.Value)); break;
            case "contact-remove": Form(AdminForms.RemoveContact(_db, SelectedId(tab)!.Value)); break;
            case "contact-readd": Form(AdminForms.ReaddContact(_db, SelectedId(tab)!.Value)); break;
            case "contact-history":
                Dialogs.Read(this, grid.Selected("Name") + " - contact history",
                    Bound(Queries.ContactPeriods(_db, SelectedId(tab)!.Value)));
                break;

            // ---- weekly reports
            case "weekly-log": LogWeekly(reference); break;

            // ---- pre-paid hours
            case "prepaid-sell": Form(AdminForms.SellPrepaid(_db, reference)); break;
            case "prepaid-usage":
            {
                var package = grid.Selected("Ref")!;
                var used = Queries.PrepaidUsage(_db, package);
                if (used.Rows.Count == 0) Dialogs.Ask(this, package, "None of these hours have been used yet.", "Ok");
                else Dialogs.Read(this, package + " - hours used", Bound(used));
                break;
            }
            case "prepaid-update": Form(AdminForms.UpdatePrepaid(_db, grid.Selected("Ref")!)); break;
            case "prepaid-invoice": Form(AdminForms.InvoicePrepaid(_db, grid.Selected("Ref")!)); break;
            case "prepaid-cancel": Form(AdminForms.CancelPrepaid(_db, grid.Selected("Ref")!)); break;

            // ---- the agreement itself
            case "agreement-review": Form(AdminForms.RecordReview(_db, reference)); break;
            case "agreement-usage": Show("Usage", Queries.AgreementUsage(_db, reference)); break;
            case "agreement-quote": Form(AdminForms.AddQuote(_db, reference)); break;
            case "agreement-notice": Form(AdminForms.GiveNotice(_db, reference)); break;
            case "agreement-pause":
                Form(AdminForms.PauseSupport(_db, reference, Queries.Agreement(_db, reference)?["SupportPausedFrom"] is DBNull));
                break;
            case "billing-run": RunBilling(reference); break;

            default:
                if (!RunOnTicket(reference, id, tab)) Unknown(id);
                break;
        }
    }

    /// <summary>The ticket actions, which the agreement page offers and the Tickets tab will share.</summary>
    private bool RunOnTicket(string agreementRef, string id, DetailTab tab)
    {
        var ticket = tab.Grid.Selected("Ticket");
        switch (id)
        {
            case "ticket-new": Form(AdminForms.OpenTicket(_db, agreementRef)); return true;
            case "ticket-details": Dialogs.Read(this, ticket!, Reading(Detail.TicketSummary(_db, ticket!))); return true;
            case "ticket-respond": Form(AdminForms.RespondTicket(_db, ticket!)); return true;
            case "ticket-log-time": Form(AdminForms.LogTime(_db, ticket!)); return true;
            case "ticket-rate": Form(AdminForms.SetTicketRate(_db, ticket!)); return true;
            case "ticket-estimate": Form(AdminForms.EstimateTicket(_db, ticket!)); return true;
            case "ticket-close": Form(AdminForms.CloseTicket(_db, ticket!)); return true;
            case "ticket-edit-time": EditTicketTime(ticket!); return true;
            default: return false;
        }
    }

    /// <summary>Everything an engagement page can do.</summary>
    private void RunOnEngagement(string reference, string clientName, string id, DetailTab tab)
    {
        var grid = tab.Grid;
        switch (id)
        {
            case "work-log": Form(AdminForms.LogWork(_db, reference)); break;
            case "work-day-correct":
                Dialogs.Ask(this, "Days worked",
                    "Everything logged is on the next tab - pick the entry there to correct or remove it.", "Ok");
                break;

            case "entry-invoiced":
                Dialogs.Ask(this, "Logged work",
                    "This time is on invoice " + grid.Selected("Invoiced") + ". Void that invoice, then change the time.", "Ok");
                break;
            case "entry-correct": Form(AdminForms.EditTimeEntry(_db, SelectedId(tab)!.Value)); break;
            case "entry-remove": Form(AdminForms.DeleteTimeEntry(_db, SelectedId(tab)!.Value)); break;

            case "contact-add": Form(AdminForms.AddContact(_db, clientName)); break;
            case "contact-edit": Form(AdminForms.EditContact(_db, SelectedId(tab)!.Value)); break;
            case "contact-remove": Form(AdminForms.RemoveContact(_db, SelectedId(tab)!.Value)); break;
            case "contact-readd": Form(AdminForms.ReaddContact(_db, SelectedId(tab)!.Value)); break;

            case "invoice-new": Form(AdminForms.NewInvoice(_db, reference)); break;
            case "engagement-edit": Form(AdminForms.EditEngagement(_db, reference)); break;
            case "engagement-complete": Form(AdminForms.CompleteEngagement(_db, reference)); break;
            case "engagement-cancel": Form(AdminForms.CancelEngagement(_db, reference)); break;
            case "billing-run": RunBilling(reference); break;

            default:
                if (!RunOnInvoice(id, tab)) Unknown(id);
                break;
        }
    }

    /// <summary>The invoice actions, shared with the Billing tab when it arrives.</summary>
    private bool RunOnInvoice(string id, DetailTab tab)
    {
        var invoice = tab.Grid.Selected("Invoice");
        switch (id)
        {
            case "invoice-html": Saved("Invoice", AdminForms.SaveInvoiceHtml(_db, invoice!, AdminForms.OutputFolder)); return true;
            case "invoice-sent": Form(AdminForms.SetInvoiceStatus(_db, invoice!, "Sent")); return true;
            case "invoice-paid": Form(AdminForms.SetInvoiceStatus(_db, invoice!, "Paid")); return true;
            case "invoice-line-add": Form(AdminForms.AddInvoiceLine(_db, invoice!)); return true;
            case "invoice-adjust": Form(AdminForms.AdjustInvoice(_db, invoice!)); return true;
            case "invoice-line-remove": RemoveInvoiceLine(invoice!); return true;
            case "invoice-void":
                // the one destructive confirmation in the app, and it says what it costs rather
                // than asking "are you sure?"
                if (Dialogs.Ask(this, "Void", "Void " + invoice + "? Any time it billed becomes billable again.", "Void", "Cancel") == 0)
                    Form(AdminForms.SetInvoiceStatus(_db, invoice!, "Void"));
                return true;
            case "invoice-renumber":
            {
                var r = _db.Proc("dbo.usp_Invoice_Renumber");
                if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing to do - they are already in date order.");
                Show("Invoice numbers", r);
                return true;
            }
            default: return false;
        }
    }

    private static void Unknown(string id) =>
        throw new InvalidOperationException($"The window has nothing wired to '{id}'.");

    /// <summary>
    ///   Which instance a weekly report is for. With none there is nothing to report on, and with
    ///   exactly one the question has only one answer - so it is not asked. Both front ends take
    ///   that decision from <see cref="Detail.WeeklyStepFor"/> rather than each keeping their own.
    /// </summary>
    private void LogWeekly(string reference)
    {
        var names = Queries.InstanceNames(_db, reference);
        var (step, only) = Detail.WeeklyStepFor(names);
        if (step == WeeklyStep.NoInstances) { Dialogs.Ask(this, "Weekly report", Detail.NoInstancesYet, "Ok"); return; }
        var name = step == WeeklyStep.TheOnlyOne ? only : Picked(names, "Which instance?");
        if (name != null) Form(AdminForms.WeeklyReport(_db, reference, name));
    }

    private string? Picked(IReadOnlyList<string> labels, string title)
    {
        var i = Dialogs.Pick(this, title, labels);
        return i == null ? null : labels[i.Value];
    }

    /// <summary>Pick a line off a draft invoice and take it away. Billing-run lines are refused by the database.</summary>
    private void RemoveInvoiceLine(string invoiceNo)
    {
        var lines = Queries.InvoiceLines(_db, invoiceNo);
        if (lines.Rows.Count == 0) { Dialogs.Ask(this, "Invoice", "This invoice has no lines yet.", "Ok"); return; }
        var labels = lines.Rows.Cast<DataRow>()
            .Select(r => Output.Format(r["Description"]) + "  -  " + Output.Format(r["Amount"])).ToList();
        var picked = Dialogs.Pick(this, invoiceNo + " - which line?", labels);
        if (picked == null) return;
        Form(AdminForms.RemoveInvoiceLine(_db, invoiceNo, (int)lines.Rows[picked.Value]["Id"], labels[picked.Value]));
    }

    /// <summary>Pick one of a ticket's time entries, then correct or remove it.</summary>
    private void EditTicketTime(string ticketRef)
    {
        var entries = Queries.TimeEntries(_db, ticketRef);
        if (entries.Rows.Count == 0) { Dialogs.Ask(this, "Time", "No time has been logged on this ticket yet.", "Ok"); return; }
        var labels = entries.Rows.Cast<DataRow>()
            .Select(r => Output.Format(r["Started"]) + "  " + r["Minutes"] + " min  "
                         + AdminForms.RateLabel(r["Rate"] as string) + "  -  " + Output.Format(r["Invoiced"]))
            .ToList();
        var picked = Dialogs.Pick(this, ticketRef + " - which time entry?", labels);
        if (picked == null) return;
        var entryId = (int)entries.Rows[picked.Value]["Id"];
        var what = Dialogs.Ask(this, labels[picked.Value], "Correct it, or take it away?", "Correct it", "Remove it", "Cancel");
        if (what == 0) Form(AdminForms.EditTimeEntry(_db, entryId));
        else if (what == 1) Form(AdminForms.DeleteTimeEntry(_db, entryId));
    }

    private void Show(string title, ProcResult result)
    {
        Dialogs.Read(this, title, new ResultView(result));
        Again();
    }

    /// <summary>
    ///   Runs the billing for one agreement or engagement and says what it did. The procedure says
    ///   nothing at all when there was nothing to bill, so say so.
    /// </summary>
    private void RunBilling(string reference)
    {
        var r = _db.Proc("dbo.usp_Billing_Run", ("@Client", reference));
        if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing new to invoice.");
        Show("Billing", r);
    }

    private void Saved(string title, string path)
    {
        if (Dialogs.Ask(this, title, "Saved to" + Environment.NewLine + path, "Open", "Ok") != 0) return;
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
    }

    private static UIElement Bound(DataTable table)
    {
        var grid = new MhGrid { Margin = new Thickness(12) };
        grid.Bind(table);
        return grid;
    }

    private static UIElement Reading(string text) => new ScrollViewer
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Content = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(16),
            Foreground = AppResources.Resource<Brush>("Ink")
        }
    };

    /// <summary>
    ///   The settings, as a page rather than a dialog - it is a place in the tree, so it behaves
    ///   like one. Saving re-reads the connection, because the whole point of changing it mid-session
    ///   is to be looking at a different database afterwards.
    /// </summary>
    private IShellPage Settings()
    {
        var view = new SettingsView(_config, _configPath, "",
            (title, message, buttons) => Dialogs.Ask(this, title, message, buttons));
        view.Finished += result =>
        {
            if (result != SetupResult.Saved) return;
            Report.Try("Settings", () =>
            {
                _db = new AdminDb(_config.BuildConnectionString());
                Reload();
            });
        };
        return new PlainPage("Settings", view);
    }

    private IShellPage Today() => new TodayPage(
        Queries.Dashboard(_db),
        client => Queries.AgreementRefForClient(_db, client),
        (title, content) => Dialogs.Read(this, title, content),
        (kind, key) => _shell.Go(kind, key),
        SaveDashboard);

    private IShellPage Clients(NavNode node)
    {
        var work = Queries.Engagements(_db, _showEnded);
        var page = new ClientsPage(work, _showEnded, ShowEnded, (kind, key) => _shell.Go(kind, key),
            new Dictionary<string, Action>
            {
                ["client-new"] = NewClient,
                ["agreement-new"] = () => Form(AdminForms.NewAgreement(_db)),
                ["engagement-new"] = () => Form(AdminForms.NewEngagement(_db, node.Kind == NavKind.Client ? node.Key : null))
            });
        if (node.Kind == NavKind.Client && node.Key != null) page.Work.Select("Client", node.Key);
        return page;
    }

    private void ShowEnded(bool ended)
    {
        _showEnded = ended;
        Reload();
    }

    private void Form(FormSpec spec)
    {
        var result = Dialogs.Form(this, spec);
        if (result == null) return;
        Again();
        if (result.Messages.Count > 0 || result.Tables.Count > 0)
            Dialogs.Read(this, spec.Title, new ResultView(result));
    }

    private void NewClient()
    {
        var result = Dialogs.Form(this, AdminForms.NewClient(_db));
        if (result == null) return;
        Reload();
        // The terminal offers to open the new agreement at once here, because an agreement with no
        // instances on it is the commonest half-finished state in the database. That offer needs the
        // agreement page, which is Phase 2; until then this says what the procedures said, which is
        // where the new reference appears, rather than opening a door onto a placeholder.
        Dialogs.Read(this, "New client", new ResultView(result));
    }

    private void SaveDashboard() =>
        Report.Try("Dashboard", () =>
        {
            var path = AdminForms.SaveDashboardHtml(_db, AdminForms.OutputFolder);
            if (Dialogs.Ask(this, "Dashboard", $"Saved to\n{path}", "Open", "Ok") != 0) return;
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
        });

    private static UIElement NotBuilt(NavNode node) => new TextBlock
    {
        Text = $"{node.Label} is not in the window yet.\n\n"
               + "It is in the terminal front end: close this and run MolehillManager --tui.",
        TextWrapping = TextWrapping.Wrap,
        Margin = new Thickness(18),
        MaxWidth = 520,
        HorizontalAlignment = HorizontalAlignment.Left,
        Foreground = AppResources.Resource<Brush>("Muted")
    };
}
