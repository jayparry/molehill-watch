using System.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// MolehillManager.Grid is the terminal's grid helper, and being in the parent namespace it wins
// over System.Windows.Controls.Grid in here. Naming WPF's explicitly, rather than finding out from
// an error message about Pos and Dim.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   What a procedure said, in the window: its PRINT messages first, then each result set - the
///   same order and the same decisions as <c>Output.Show</c> prints in the terminal, including
///   which tables read better as "Name : value" lines, which is
///   <see cref="Output.ReadsBetterVertical"/> rather than a second opinion written in WPF.
///
///   The messages matter as much as the tables. Every procedure in MolehillAdmin says what it did
///   with PRINT - "Invoice MDS-INV-2026-0009 created, 3 lines" - and a screen that shows only the
///   rows throws that away.
/// </summary>
internal sealed class ResultView : UserControl
{
    private readonly StackPanel _parts = new();

    public ResultView()
    {
        Content = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Background = AppResources.Resource<Brush>("Paper"),
            Padding = new Thickness(16),
            Content = _parts
        };
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
    }

    public ResultView(ProcResult result) : this() => Show(result);

    /// <summary>The PRINT messages shown, in order. For the self-test.</summary>
    public List<string> Messages { get; } = new();

    /// <summary>The grids built, one per result set shown as a table. For the self-test.</summary>
    public List<MhGrid> Grids { get; } = new();

    public void Show(ProcResult result)
    {
        _parts.Children.Clear();
        Messages.Clear();
        Grids.Clear();

        foreach (var message in result.Messages)
        {
            Messages.Add(message);
            _parts.Children.Add(new TextBlock
            {
                Text = message,
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 4),
                MaxWidth = 760,
                HorizontalAlignment = HorizontalAlignment.Left
            });
        }

        foreach (var table in result.Tables) Add(table);

        if (_parts.Children.Count == 0)
            _parts.Children.Add(new TextBlock
            {
                Text = "Done. The database had nothing further to say.",
                Foreground = AppResources.Resource<Brush>("Muted")
            });
    }

    /// <summary>One table, as a grid or as lines, by the shared rule.</summary>
    public void Add(DataTable table)
    {
        var top = _parts.Children.Count > 0 ? 12 : 0;
        if (table.Rows.Count == 0)
        {
            _parts.Children.Add(new TextBlock
            {
                Text = "(no rows)",
                Foreground = AppResources.Resource<Brush>("Muted"),
                Margin = new Thickness(0, top, 0, 0)
            });
            return;
        }

        if (Output.ReadsBetterVertical(table))
        {
            _parts.Children.Add(Lines(table.Rows[0], top));
            return;
        }

        var grid = new MhGrid { Margin = new Thickness(0, top, 0, 0), MaxHeight = 420 };
        grid.Bind(table);
        Grids.Add(grid);
        _parts.Children.Add(grid);
    }

    /// <summary>
    ///   One row as "Name : value" pairs - what the terminal's alert and ticket detail panes print.
    ///   Not a two-column grid, which would be selectable and sortable and so invite clicking on
    ///   something that does nothing.
    /// </summary>
    private static UIElement Lines(DataRow row, int top = 0)
    {
        var layout = new WpfGrid { Margin = new Thickness(0, top, 0, 0) };
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        var line = 0;
        foreach (var column in Output.Shown(row.Table))
        {
            layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var name = new TextBlock
            {
                Text = column.ColumnName,
                Foreground = AppResources.Resource<Brush>("Muted"),
                Margin = new Thickness(0, 0, 14, 4)
            };
            WpfGrid.SetRow(name, line);
            WpfGrid.SetColumn(name, 0);
            var value = new TextBlock
            {
                Text = Output.Format(column.ColumnName, row[column]),
                TextWrapping = TextWrapping.Wrap,
                Margin = new Thickness(0, 0, 0, 4),
                MaxWidth = 640,
                HorizontalAlignment = HorizontalAlignment.Left
            };
            WpfGrid.SetRow(value, line);
            WpfGrid.SetColumn(value, 1);
            layout.Children.Add(name);
            layout.Children.Add(value);
            line++;
        }
        return layout;
    }

    /// <summary>One row on its own, which is how an alert is opened.</summary>
    public static ResultView Of(DataRow row)
    {
        var view = new ResultView();
        view._parts.Children.Add(Lines(row));
        return view;
    }
}
