using System.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// MolehillManager.Grid is the terminal grid helper and wins over WPF's in here, being nearer.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   Runs one action, told which tab it came from so it can read the row that is selected. The
///   page never holds a database or a dialog; this is the one way out of it.
///
///   An id the window does not know is a mistake in the screen rather than something a person can
///   do anything about, so the window throws on one. That is a better guard than a dictionary of
///   handlers checked for completeness, because the self-test presses every enabled button on every
///   tab and so actually walks it.
/// </summary>
internal delegate void RunDetailAction(string id, DetailTab tab);

/// <summary>
///   One tab on a detail page: a grid, what to say above it, and what can be done to the row
///   selected in it. The actions are a function rather than a value because they depend on the
///   selection, which is the whole reason the toolbar is asked again every time it moves.
/// </summary>
internal sealed class DetailTab
{
    public DetailTab(string header, Func<MhActionSet> actions, string? note = null, UIElement? above = null)
    {
        Header = header;
        Actions = actions;
        Note = note;
        Above = above;
    }

    public string Header { get; }
    public Func<MhActionSet> Actions { get; }

    /// <summary>A grey line of explanation above the grid, as the terminal tabs have. Null for none.</summary>
    public string? Note { get; }

    /// <summary>A control above the grid - the "show removed contacts" tick box. Null for none.</summary>
    public UIElement? Above { get; }

    public MhGrid Grid { get; } = new();

    /// <summary>Raised when something was double-clicked, so the page can open or edit it.</summary>
    public Action? Opened { get; set; }
}

/// <summary>
///   An agreement or an engagement: a summary at the top, then its tables on tabs, with the
///   toolbar above showing what can be done to whatever is selected.
///
///   This is where the hidden-action problem is actually fixed. The terminal reaches these screens
///   as a dialog over the main window, puts every action behind Enter or F4, changes which exist
///   with both the tab and the row, and hides a second menu behind the last item of the first. A
///   page in the content pane with a visible toolbar removes all four at once.
///
///   It holds no database and no dialogs: the tables and the summary arrive built, and every
///   action goes out through the handler dictionary. That is what lets the whole screen be driven
///   with no server and no window.
/// </summary>
internal sealed class DetailPage : UserControl, IShellPage
{
    private readonly TabControl _tabs = new();
    private readonly TextBlock _summary;
    private readonly IReadOnlyList<DetailTab> _list;
    private readonly RunDetailAction _run;
    private readonly MhActionSet? _wide;

    public DetailPage(string summary, IReadOnlyList<DetailTab> tabs, MhActionSet? wide, RunDetailAction run)
    {
        _list = tabs;
        _run = run;
        _wide = wide;

        _summary = new TextBlock
        {
            Text = summary,
            TextWrapping = TextWrapping.Wrap,
            Foreground = AppResources.Resource<Brush>("InkSecondary"),
            LineHeight = 18,
            Margin = new Thickness(0, 0, 0, 10)
        };

        var box = new Border
        {
            Background = AppResources.Resource<Brush>("Surface"),
            BorderBrush = AppResources.Resource<Brush>("Line"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(16, 12, 16, 4),
            Child = _summary
        };

        foreach (var tab in tabs)
        {
            tab.Grid.SelectionChanged += (_, _) => Changed?.Invoke();
            tab.Grid.MouseDoubleClick += (_, _) =>
            {
                if (tab.Opened != null) Report.Try(tab.Header, tab.Opened);
            };
            _tabs.Items.Add(new TabItem { Header = tab.Header, Content = Body(tab) });
        }
        // a tab is a different selection, so the toolbar has to be asked again
        _tabs.SelectionChanged += (_, e) => { if (ReferenceEquals(e.OriginalSource, _tabs)) Changed?.Invoke(); };
        if (_tabs.Items.Count > 0) _tabs.SelectedIndex = 0;

        var rows = new WpfGrid();
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        WpfGrid.SetRow(box, 0);
        WpfGrid.SetRow(_tabs, 1);
        _tabs.Margin = new Thickness(16, 10, 16, 16);
        _tabs.Background = AppResources.Resource<Brush>("Paper");
        _tabs.BorderThickness = new Thickness(0);
        rows.Children.Add(box);
        rows.Children.Add(_tabs);

        Content = rows;
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
    }

    private static UIElement Body(DetailTab tab)
    {
        if (tab.Note == null && tab.Above == null) return tab.Grid;

        var rows = new WpfGrid { Margin = new Thickness(0, 8, 0, 0) };
        var top = new StackPanel { Orientation = Orientation.Vertical, Margin = new Thickness(2, 0, 2, 8) };
        if (tab.Above != null) top.Children.Add(tab.Above);
        if (tab.Note != null)
            top.Children.Add(new TextBlock
            {
                Text = tab.Note,
                TextWrapping = TextWrapping.Wrap,
                Foreground = AppResources.Resource<Brush>("Muted"),
                Margin = new Thickness(0, tab.Above == null ? 0 : 6, 0, 0)
            });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        WpfGrid.SetRow(top, 0);
        WpfGrid.SetRow(tab.Grid, 1);
        rows.Children.Add(top);
        rows.Children.Add(tab.Grid);
        return rows;
    }

    /// <summary>The summary block as shown. For the self-test.</summary>
    public string Summary => _summary.Text;

    /// <summary>The tab headers, in order.</summary>
    public IReadOnlyList<string> Headers => _list.Select(t => t.Header).ToList();

    /// <summary>The tab showing.</summary>
    public DetailTab Current => _list[Math.Max(0, _tabs.SelectedIndex)];

    /// <summary>Moves to a tab by its header, and says whether there was one.</summary>
    public bool ShowTab(string header)
    {
        var i = _list.ToList().FindIndex(t => t.Header == header);
        if (i < 0) return false;
        _tabs.SelectedIndex = i;
        // Not tidiness. A TabControl builds only the selected tab's content, so until layout runs
        // again the tab just moved to is not in the visual tree at all - the same trap as a
        // TreeView not building a collapsed node's children, with the same symptom: everything
        // reads as empty and nothing says why.
        UpdateLayout();
        return true;
    }

    /// <summary>One tab's grid, by header. Throws rather than returning null: a wrong name is a bug here.</summary>
    public MhGrid GridOn(string header) =>
        _list.FirstOrDefault(t => t.Header == header)?.Grid
        ?? throw new InvalidOperationException($"There is no '{header}' tab.");

    UIElement IShellPage.Content => this;

    /// <summary>What can be done to the selected row of the tab showing.</summary>
    public MhActionSet Actions => Current.Actions();

    /// <summary>
    ///   The agreement's or engagement's own actions, less anything the tab showing already
    ///   offers. Four ids sit in both - opening a ticket, selling pre-paid hours, the onboarding
    ///   checklist, running the billing - and two buttons with the same words on them, side by
    ///   side, reads as a bug however well each one works.
    /// </summary>
    public MhActionSet? WideActions
    {
        get
        {
            if (_wide == null) return null;
            var already = new HashSet<string>(Actions.Actions.Select(a => a.Id));
            var rest = _wide.Actions.Where(a => !already.Contains(a.Id)).ToList();
            return rest.Count == 0 ? null : new MhActionSet(_wide.Title, rest);
        }
    }

    /// <summary>
    ///   Something to run for every action currently offered, in both groups. Built from the sets
    ///   rather than written out beside them, so an action can never be offered with nothing behind
    ///   it - and what is offered is already narrowed to what the window can do, by the page that
    ///   built the tabs.
    /// </summary>
    public IReadOnlyDictionary<string, Action> Handlers
    {
        get
        {
            var tab = Current;
            var all = Actions.Actions.Concat(WideActions?.Actions ?? Array.Empty<MhAction>());
            var handlers = new Dictionary<string, Action>();
            foreach (var action in all.Where(a => a.Enabled))
            {
                var id = action.Id;
                handlers[id] = () => _run(id, tab);
            }
            return handlers;
        }
    }

    public event Action? Changed;
}
