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

    private IShellPage Open(NavNode node) => node.Kind switch
    {
        NavKind.Today => Today(),
        NavKind.Clients or NavKind.Client => Clients(node),
        NavKind.Settings => Settings(),
        _ => new PlainPage(node.Label, NotBuilt(node))
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
        Reload();
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
