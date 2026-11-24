using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;

// MolehillManager.Grid is the terminal grid helper and wins over WPF's in here, being nearer.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   An alert's priority, as the look of its cell. <c>parameter</c> picks which part - the
///   background, the ink or the weight - because three converters for one rule is three places to
///   change it. The rule itself is <see cref="Today.AlertColour"/>, held to the dashboard HTML the
///   clients receive by the self-test.
/// </summary>
internal sealed class AlertLook : IValueConverter
{
    public static readonly AlertLook Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture)
    {
        var look = Today.AlertColour(value as string);
        return (parameter as string) switch
        {
            "Ink" => AppResources.Resource<Brush>(look?.Ink ?? "Ink"),
            "Bold" => look?.Bold == true ? FontWeights.SemiBold : FontWeights.Normal,
            _ => look == null ? (object)Brushes.Transparent : AppResources.Resource<Brush>(look.Value.Background)
        };
    }

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}

/// <summary>
///   Today: what needs doing, and what the money looks like. The alerts are the daily to-do list
///   the database works out; the figures underneath are <see cref="Today.Tiles"/>.
///
///   The dashboard arrives in the constructor and through <see cref="Refresh"/>, never fetched in
///   here and never in Loaded - which does not fire for an element with no window, so a page that
///   loaded there could not be tested at all.
/// </summary>
internal sealed class TodayPage : UserControl, IShellPage
{
    private readonly Func<string, string?> _agreementFor;
    private readonly Action<string, UIElement> _show;
    private readonly Action<NavKind, string?> _go;
    private readonly Action _saveHtml;
    private readonly MhGrid _alerts = new();
    private readonly WrapPanel _tiles = new();

    public TodayPage(DashboardView dashboard, Func<string, string?> agreementFor,
        Action<string, UIElement> show, Action<NavKind, string?> go, Action saveHtml)
    {
        _agreementFor = agreementFor;
        _show = show;
        _go = go;
        _saveHtml = saveHtml;

        _alerts.SelectionChanged += (_, _) => Changed?.Invoke();
        // asked as each column is generated, which is the only moment it can be applied: see MhGrid
        _alerts.CellStyleFor = column => column == "Priority" ? PriorityCell() : null;
        _alerts.MouseDoubleClick += (_, _) => Report.Try("Alert", ShowAlert);

        var heading = new TextBlock
        {
            Text = "To do",
            FontFamily = AppResources.Resource<FontFamily>("TitleFont"),
            FontSize = 14,
            Foreground = AppResources.Resource<Brush>("Muted"),
            Margin = new Thickness(0, 0, 0, 6)
        };
        _tiles.Margin = new Thickness(0, 14, 0, 0);

        var rows = new WpfGrid();
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        rows.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        WpfGrid.SetRow(heading, 0);
        WpfGrid.SetRow(_alerts, 1);
        WpfGrid.SetRow(_tiles, 2);
        rows.Children.Add(heading);
        rows.Children.Add(_alerts);
        rows.Children.Add(_tiles);
        rows.Margin = new Thickness(16, 6, 16, 16);

        Content = rows;
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
        Refresh(dashboard);
    }

    public void Refresh(DashboardView dashboard)
    {
        _alerts.Bind(dashboard.Alerts);
        Tiles = Today.Tiles(dashboard);
        _tiles.Children.Clear();
        foreach (var tile in Tiles) _tiles.Children.Add(Box(tile));
        Changed?.Invoke();
    }

    private static Style PriorityCell()
    {
        var style = new Style(typeof(DataGridCell));
        void Part(DependencyProperty property, string which) =>
            style.Setters.Add(new Setter(property,
                new Binding("Priority") { Converter = AlertLook.Instance, ConverterParameter = which }));
        Part(Control.BackgroundProperty, "Background");
        Part(Control.ForegroundProperty, "Ink");
        Part(Control.FontWeightProperty, "Bold");
        return style;
    }

    private static UIElement Box(Tile tile) => new Border
    {
        Background = AppResources.Resource<Brush>("Surface"),
        BorderBrush = AppResources.Resource<Brush>("Line"),
        BorderThickness = new Thickness(1),
        CornerRadius = new CornerRadius(3),
        Padding = new Thickness(12, 8, 12, 9),
        Margin = new Thickness(0, 0, 10, 10),
        Child = new StackPanel
        {
            Children =
            {
                new TextBlock
                {
                    Text = tile.Label,
                    FontSize = 11.5,
                    Foreground = AppResources.Resource<Brush>("Muted"),
                    MaxWidth = 210,
                    TextWrapping = TextWrapping.Wrap
                },
                new TextBlock
                {
                    Text = tile.Value,
                    FontFamily = AppResources.Resource<FontFamily>("TitleFont"),
                    FontSize = 18,
                    Margin = new Thickness(0, 2, 0, 0)
                }
            }
        }
    };

    /// <summary>The alerts grid, and the tiles' words. For the self-test.</summary>
    public MhGrid Alerts => _alerts;

    public IReadOnlyList<Tile> Tiles { get; private set; } = Array.Empty<Tile>();

    UIElement IShellPage.Content => this;

    public MhActionSet Actions
    {
        get
        {
            var client = _alerts.Selected("Client");
            var selected = _alerts.SelectedRow() != null;
            var reference = string.IsNullOrEmpty(client) ? null : _agreementFor(client);
            return ActionRules.Dashboard(selected, client, reference);
        }
    }

    public IReadOnlyDictionary<string, Action> Handlers => new Dictionary<string, Action>
    {
        ["alert-show"] = ShowAlert,
        ["alert-agreement"] = OpenTheClient,
        ["dashboard-html"] = _saveHtml
    };

    public event Action? Changed;

    private void ShowAlert()
    {
        var row = _alerts.SelectedRow();
        if (row != null) _show("Alert", ResultView.Of(row));
    }

    /// <summary>
    ///   Takes you to the client the alert is about. The action's label names their agreement,
    ///   because that is what the rule says and the terminal opens the agreement window; the
    ///   agreement's own page is Phase 2, and the client's node lists it. Note that the reference
    ///   the lookup returns is an AgreementRef while the tree is keyed by EngagementRef - the two
    ///   are not the same, so navigating by it would quietly do nothing at all.
    /// </summary>
    private void OpenTheClient()
    {
        var client = _alerts.Selected("Client");
        if (!string.IsNullOrEmpty(client)) _go(NavKind.Client, client);
    }
}
