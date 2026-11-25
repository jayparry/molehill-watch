using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Threading;

// MolehillManager.Grid is the terminal grid helper and, being in the parent namespace, wins over
// System.Windows.Controls.Grid in here.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   One page in the content pane. <see cref="Actions"/> is asked again every time the page says
///   something has <see cref="Changed"/>, because what can be done depends on what is selected -
///   which is the whole point of a visible toolbar.
/// </summary>
internal interface IShellPage
{
    UIElement Content { get; }
    MhActionSet Actions { get; }
    IReadOnlyDictionary<string, Action> Handlers { get; }

    /// <summary>
    ///   What can be done to the thing the page is about, rather than to the row selected on it -
    ///   an agreement or an engagement as a whole. The terminal puts these behind a second menu
    ///   reached from the first, which is as deep as the hiding gets in this app and the hardest
    ///   part of it to find. Here they are a second group on the same toolbar: still visible,
    ///   still one press, and plainly a different scope.
    /// </summary>
    MhActionSet? WideActions => null;

    /// <summary>The selection moved: offer the actions again.</summary>
    event Action? Changed;
}

/// <summary>A page with nothing on it to do yet - the parts not built.</summary>
internal sealed class PlainPage : IShellPage
{
    public PlainPage(string title, UIElement content)
    {
        Content = content;
        Actions = new MhActionSet(title, Array.Empty<MhAction>());
    }

    public UIElement Content { get; }
    public MhActionSet Actions { get; }
    public IReadOnlyDictionary<string, Action> Handlers { get; } = new Dictionary<string, Action>();

    // nothing on a plain page ever changes, so the event has nowhere to be raised from
    public event Action? Changed { add { } remove { } }
}

/// <summary>
///   The whole screen bar the window: the tree down the left, and on the right a breadcrumb, the
///   toolbar of what can be done here, and the page itself.
///
///   It is a UserControl and not a Window on purpose - a Window that is never shown has no
///   PresentationSource and arranges to nothing, so it cannot be tested, while this measures and
///   arranges on an STA thread with no window at all. Pages arrive through a factory rather than
///   being built in here, so the self-test drives the whole shell with no database.
///
///   No modal stack. An agreement or an engagement is a page in this pane, not a dialog over a
///   dialog over the main screen, which is how the terminal ends up three deep with no way of
///   telling where you are.
/// </summary>
internal sealed class Shell : UserControl
{
    private readonly Func<NavNode, IShellPage> _open;
    private readonly TreeView _tree = new();
    private readonly TextBlock _crumbs;
    private readonly Toolbar _toolbar = new();
    private readonly ContentControl _pane = new();
    private IShellPage? _page;
    private bool _quiet;        // stops a highlight we set ourselves from re-opening the page

    public Shell(Func<NavNode, IShellPage> open)
    {
        _open = open;

        _crumbs = new TextBlock
        {
            FontFamily = AppResources.Resource<FontFamily>("TitleFont"),
            FontSize = 17,
            Foreground = AppResources.Resource<Brush>("Ink"),
            Margin = new Thickness(16, 12, 16, 10),
            TextTrimming = TextTrimming.CharacterEllipsis
        };

        _tree.BorderThickness = new Thickness(0);
        _tree.Background = AppResources.Resource<Brush>("Surface");
        _tree.Padding = new Thickness(6, 10, 6, 10);
        _tree.ItemTemplate = NodeTemplate();
        // Open, every level of it. A TreeView does not even build a collapsed node's children, so
        // a client under a shut "Clients" is not merely hard to find, it is not on the screen at
        // all - which is the complaint this window exists to answer. It scrolls; it does not hide.
        var expanded = new Style(typeof(TreeViewItem));
        expanded.Setters.Add(new Setter(TreeViewItem.IsExpandedProperty, true));
        _tree.ItemContainerStyle = expanded;
        _tree.SelectedItemChanged += (_, e) =>
        {
            if (_quiet || e.NewValue is not NavNode node) return;
            Report.Try(node.Label, () => Show(node));
        };

        var right = new WpfGrid { Background = AppResources.Resource<Brush>("Paper") };
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        right.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        WpfGrid.SetRow(_crumbs, 0);
        WpfGrid.SetRow(_toolbar, 1);
        WpfGrid.SetRow(_pane, 2);
        right.Children.Add(_crumbs);
        right.Children.Add(_toolbar);
        right.Children.Add(_pane);

        var split = new WpfGrid();
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(248), MinWidth = 150 });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var line = new Border { Width = 1, Background = AppResources.Resource<Brush>("Line") };
        WpfGrid.SetColumn(_tree, 0);
        WpfGrid.SetColumn(line, 1);
        WpfGrid.SetColumn(right, 2);
        split.Children.Add(_tree);
        split.Children.Add(line);
        split.Children.Add(right);

        Content = split;
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
    }

    private static HierarchicalDataTemplate NodeTemplate()
    {
        var text = new FrameworkElementFactory(typeof(TextBlock));
        text.SetBinding(TextBlock.TextProperty, new Binding(nameof(NavNode.Label)));
        text.SetValue(FrameworkElement.MarginProperty, new Thickness(2, 3, 2, 3));
        return new HierarchicalDataTemplate
        {
            ItemsSource = new Binding(nameof(NavNode.Children)),
            VisualTree = text
        };
    }

    /// <summary>The tree as it stands. For the self-test.</summary>
    public IReadOnlyList<NavNode> Tree { get; private set; } = Array.Empty<NavNode>();

    /// <summary>Where we are, or null before anything has been opened.</summary>
    public NavNode? Here { get; private set; }

    /// <summary>The breadcrumb as shown.</summary>
    public string Breadcrumb => _crumbs.Text;

    public Toolbar Actions => _toolbar;

    /// <summary>What is in the content pane.</summary>
    public object? Page => _pane.Content;

    /// <summary>Which node the tree is pointing at. For the self-test.</summary>
    public object? Highlighted => _tree.SelectedItem;

    /// <summary>
    ///   Puts a new tree up - after a refresh, or when the data first arrives - and stays where it
    ///   was. The same thinking as <see cref="RowKey"/>: the app refreshes on a timer, and a client
    ///   added or removed meanwhile must not move you somewhere else. Where you were having gone
    ///   altogether, it falls back to Today rather than to whatever now sits in that position.
    /// </summary>
    public void Load(IReadOnlyList<NavNode> tree)
    {
        Tree = tree;
        _quiet = true;
        try { _tree.ItemsSource = tree; }
        finally { _quiet = false; }

        var wanted = Here == null ? null : Nav.Find(tree, Here.Kind, Here.Key);
        Show(wanted ?? Nav.Find(tree, NavKind.Today) ?? tree.FirstOrDefault());
    }

    /// <summary>Opens a place by what it is, rather than by hunting for its node.</summary>
    public void Go(NavKind kind, string? key = null) => Show(Nav.Find(Tree, kind, key));

    private void Show(NavNode? node)
    {
        if (node == null) return;
        if (_page != null) _page.Changed -= Offer;
        Here = node;
        _crumbs.Text = Nav.Breadcrumb(Tree, node.Kind, node.Key);
        _page = _open(node);
        _pane.Content = _page.Content;
        _page.Changed += Offer;
        Offer();
        PointAt(node);
    }

    /// <summary>
    ///   Moves the tree's highlight to a node the app opened itself - from a double-click in the
    ///   list, or from an alert on Today. Without this the content pane and the breadcrumb move
    ///   while the tree goes on pointing at where you were, which is the confusion this window is
    ///   for.
    ///
    ///   WPF has no "select this item" on a TreeView, only IsSelected on the container, and a
    ///   container exists only once its level has been generated - which is both why every level is
    ///   expanded from the start and why this walks the generators rather than the nodes. At start-up
    ///   there is no container yet, because nothing has been laid out, so it is asked again once the
    ///   window has arranged itself.
    /// </summary>
    private void PointAt(NavNode node)
    {
        if (Highlight(_tree, node)) return;
        // nothing has been laid out yet, so there is no container to point at: ask again once there is
        Dispatcher.BeginInvoke(new Action(() => Highlight(_tree, node)), DispatcherPriority.Loaded);
    }

    private bool Highlight(ItemsControl parent, NavNode node)
    {
        foreach (var item in parent.Items)
        {
            if (parent.ItemContainerGenerator.ContainerFromItem(item) is not TreeViewItem container) continue;
            if (ReferenceEquals(item, node))
            {
                if (container.IsSelected) return true;
                _quiet = true;
                try { container.IsSelected = true; }
                finally { _quiet = false; }
                return true;
            }
            if (Highlight(container, node)) return true;
        }
        return false;
    }

    /// <summary>
    ///   Offers what can be done here. Asked again whenever the page says the selection moved,
    ///   because an action that applies to the selected row is the main thing the terminal hides.
    /// </summary>
    private void Offer()
    {
        if (_page != null) _toolbar.Show(_page.Actions, _page.WideActions, _page.Handlers);
    }
}
