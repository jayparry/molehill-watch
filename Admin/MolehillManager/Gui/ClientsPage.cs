using System.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// MolehillManager.Grid is the terminal grid helper and wins over WPF's in here, being nearer.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   The work: every support agreement and consultancy engagement, with a tick box for the ones
///   that have finished. The terminal shows the same list and hides the actions behind Enter and
///   F2; here they are on show, and the ones the window cannot do yet say so rather than
///   disappearing - see <see cref="MhActionSet.Only"/>.
///
///   The table arrives from outside, as on <see cref="TodayPage"/>, and asking for the finished
///   work goes back out through <see cref="Reload"/> rather than this page reaching for a database.
/// </summary>
internal sealed class ClientsPage : UserControl, IShellPage
{
    /// <summary>
    ///   What a greyed button says while the window is half built. It names the way to do the thing
    ///   meanwhile, which is the whole difference between an action that is disabled and one that
    ///   has been hidden.
    /// </summary>
    public const string NotYet = "Not in the window yet - run with --tui for this one.";

    private readonly MhGrid _work = new();
    private readonly CheckBox _ended;
    private readonly TextBlock _summary;
    private readonly Action<bool> _reload;
    private readonly Action<NavKind, string?> _go;
    private readonly IReadOnlyDictionary<string, Action> _handlers;

    public ClientsPage(DataTable work, bool showEnded, Action<bool> reload,
        Action<NavKind, string?> go, IReadOnlyDictionary<string, Action> handlers)
    {
        _reload = reload;
        _go = go;
        _handlers = handlers;

        _ended = new CheckBox
        {
            Content = "Show finished work",
            IsChecked = showEnded,
            Margin = new Thickness(0, 0, 0, 8),
            Foreground = AppResources.Resource<Brush>("InkSecondary")
        };
        _ended.Click += (_, _) => Report.Try("Work", () => _reload(_ended.IsChecked == true));

        _work.SelectionChanged += (_, _) => { Describe(); Changed?.Invoke(); };
        _work.MouseDoubleClick += (_, _) => Report.Try("Work", Open);

        _summary = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = AppResources.Resource<Brush>("Muted"),
            Margin = new Thickness(0, 10, 0, 0),
            MaxWidth = 900,
            // a MaxWidth narrower than the room available centres the block, which puts this line
            // adrift in the middle of the window rather than under the first column
            HorizontalAlignment = HorizontalAlignment.Left
        };

        var rows = new WpfGrid { Margin = new Thickness(16, 6, 16, 16) };
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        WpfGrid.SetRow(_ended, 0);
        WpfGrid.SetRow(_work, 1);
        WpfGrid.SetRow(_summary, 2);
        rows.Children.Add(_ended);
        rows.Children.Add(_work);
        rows.Children.Add(_summary);

        Content = rows;
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
        Refresh(work);
    }

    public void Refresh(DataTable work)
    {
        _work.Bind(work);
        Describe();
        Changed?.Invoke();
    }

    /// <summary>The grid and the line under it. For the self-test.</summary>
    public MhGrid Work => _work;

    public string Summary => _summary.Text;

    UIElement IShellPage.Content => this;

    /// <summary>
    ///   Which actions apply, from the raw engagement type rather than from the words in the Type
    ///   cell - the branch that picks the detail pane, the page that opens and this whole list.
    /// </summary>
    public MhActionSet Actions
    {
        get
        {
            var row = _work.SelectedRow();
            var reference = _work.Selected("Ref");
            var client = _work.Selected("Client");
            var consultancy = row != null && row.Table.Columns.Contains("_EngagementType")
                && row["_EngagementType"] as string == "Consultancy";
            return ActionRules.Clients(reference, client, consultancy).Only(_handlers.Keys, NotYet);
        }
    }

    public IReadOnlyDictionary<string, Action> Handlers => _handlers;

    public event Action? Changed;

    /// <summary>
    ///   Opening a row goes to its node in the tree, which is the same place the tree reaches. One
    ///   route, so double-clicking here and clicking there cannot drift apart - and public, so that
    ///   the route itself is checked rather than only the double-click that happens to call it.
    /// </summary>
    public void Open()
    {
        var reference = _work.Selected("Ref");
        if (!string.IsNullOrEmpty(reference)) _go(NavKind.Engagement, reference);
    }

    /// <summary>
    ///   The line under the grid, which the terminal fills with a text table of the selected row.
    ///   Here it is one sentence, because the row itself is already on the screen and in full.
    /// </summary>
    private void Describe()
    {
        var row = _work.SelectedRow();
        if (row == null)
        {
            var count = _work.Table?.Rows.Count ?? 0;
            _summary.Text = count == 0
                ? "No work to show. Start with \"New client\" below."
                : $"{count} engagement(s). Pick one to see what can be done with it.";
            return;
        }
        var parts = new List<string>();
        // a count of nothing is not worth a word: "0 open ticket(s)" is noise on every row that
        // has none, and the whole point of this line is what is unusual about the one selected
        void Add(string column, string shape, bool hideNothing = false)
        {
            var value = _work.Selected(column);
            if (string.IsNullOrEmpty(value)) return;
            if (hideNothing && (value == "0" || value == "0.00")) return;
            parts.Add(string.Format(shape, value));
        }
        Add("Status", "{0}");
        Add("Rate", "{0}");
        Add("Unbilled", "{0} not yet invoiced");
        Add("OpenTickets", "{0} open ticket(s)", hideNothing: true);
        Add("OnboardingLeft", "{0} onboarding item(s) still to do", hideNothing: true);
        _summary.Text = string.Join("   ·   ", parts);
    }
}
