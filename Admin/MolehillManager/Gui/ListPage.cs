using System.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// MolehillManager.Grid is the terminal grid helper and wins over WPF's in here, being nearer.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   Runs one action for the row selected in a grid. The flat pages' equivalent of
///   <see cref="RunDetailAction"/>: same contract, same reason, one less level.
/// </summary>
internal delegate void RunGridAction(string id, MhGrid grid);

/// <summary>
///   A list with something underneath it that describes whatever is selected - the shape both
///   Tickets and Billing have, and the shape the terminal gives them too.
///
///   The lower half is the part worth being careful about. In the terminal it is a read-only
///   TextView holding either the ticket in full or the invoice's lines laid out as a text table.
///   One of those is prose and one is a table, so this takes either: a description as text, or a
///   grid of its own.
/// </summary>
internal sealed class ListPage : UserControl, IShellPage
{
    private readonly MhGrid _list = new();
    private readonly MhGrid _below = new();
    private readonly TextBlock _text;
    private readonly ContentControl _detail = new();
    private readonly Func<MhActionSet> _actions;
    private readonly RunGridAction _run;
    private readonly Func<MhGrid, object?> _describe;

    /// <summary>
    ///   <paramref name="describe"/> is handed the list and gives back what to put underneath it:
    ///   a string to read, a DataTable to lay out as a grid, or null for neither.
    /// </summary>
    public ListPage(DataTable rows, UIElement? filter, string detailHeader,
        Func<MhGrid, object?> describe, Func<MhActionSet> actions, RunGridAction run)
    {
        _actions = actions;
        _run = run;
        _describe = describe;

        _text = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = AppResources.Resource<Brush>("InkSecondary"),
            Margin = new Thickness(2, 4, 2, 2)
        };

        _list.SelectionChanged += (_, _) => { Describe(); Changed?.Invoke(); };
        _list.MouseDoubleClick += (_, _) => Opened?.Invoke();

        var heading = new TextBlock
        {
            Text = detailHeader,
            FontFamily = AppResources.Resource<FontFamily>("TitleFont"),
            FontSize = 12,
            Foreground = AppResources.Resource<Brush>("Muted"),
            Margin = new Thickness(0, 10, 0, 4)
        };

        var rowsPanel = new WpfGrid { Margin = new Thickness(16, 6, 16, 16) };
        rowsPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // filter
        rowsPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(55, GridUnitType.Star) });
        rowsPanel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // heading
        rowsPanel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(45, GridUnitType.Star) });
        if (filter != null)
        {
            WpfGrid.SetRow(filter, 0);
            rowsPanel.Children.Add(filter);
        }
        WpfGrid.SetRow(_list, 1);
        WpfGrid.SetRow(heading, 2);
        WpfGrid.SetRow(_detail, 3);
        rowsPanel.Children.Add(_list);
        rowsPanel.Children.Add(heading);
        rowsPanel.Children.Add(_detail);

        Content = rowsPanel;
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
        // no Changed here: nothing has subscribed yet, and the shell offers a page's actions itself
        // the moment it puts it up. A refresh is a new page in this window, not a reload of this one
        _list.Bind(rows);
        Describe();
    }

    private void Describe()
    {
        switch (_describe(_list))
        {
            case DataTable table:
                _below.Bind(table);
                _detail.Content = _below;
                break;
            case string words:
                _text.Text = words;
                _detail.Content = _text;
                break;
            default:
                _text.Text = "";
                _detail.Content = _text;
                break;
        }
    }

    /// <summary>The list, the thing underneath it, and what it says. For the self-test.</summary>
    public MhGrid List => _list;

    public MhGrid Below => _below;

    public string Text => _text.Text;

    /// <summary>What is actually under the list now - the grid, or the block of words.</summary>
    public object? Detail => _detail.Content;

    /// <summary>Double-clicked. The window hangs the row's first action off this.</summary>
    public Action? Opened { get; set; }

    UIElement IShellPage.Content => this;

    public MhActionSet Actions => _actions();

    public IReadOnlyDictionary<string, Action> Handlers
    {
        get
        {
            var handlers = new Dictionary<string, Action>();
            foreach (var action in Actions.Actions.Where(a => a.Enabled))
            {
                var id = action.Id;
                handlers[id] = () => _run(id, _list);
            }
            return handlers;
        }
    }

    public event Action? Changed;
}
