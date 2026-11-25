using System.Data;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;

namespace MolehillManager.Gui;

/// <summary>
///   Runs a cell's value through <see cref="Output.Format"/>, so the window shows exactly what the
///   terminal shows and what the text tables show. The column name is the converter's parameter,
///   because the money columns always print pence and only the name says which those are.
/// </summary>
internal sealed class CellText : IValueConverter
{
    public static readonly CellText Instance = new();

    public object Convert(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        Output.Format(parameter as string ?? "", value);

    public object ConvertBack(object? value, Type targetType, object? parameter, CultureInfo culture) =>
        throw new NotSupportedException("The grid is read-only; every change goes through a form.");
}

/// <summary>
///   The one grid in the window. A DataGrid over a DataTable, with the display rules the terminal
///   UI has: underscore columns hidden, numbers right, the long free-text columns capped, money to
///   two decimals - all of them by going through <see cref="Output.Format"/> rather than growing a
///   second implementation of the same rules in XAML.
///
///   Read-only, because every change in this app goes through a FormSpec and a stored procedure.
/// </summary>
internal sealed class MhGrid : DataGrid
{
    /// <summary>
    ///   Capped in the terminal UI at 50 characters, because one long description otherwise pushes
    ///   every other column off the screen. Here the cell wraps instead, so the cap is a column
    ///   width rather than a truncation - the text is all still there.
    /// </summary>
    private static readonly HashSet<string> Wide = new(StringComparer.OrdinalIgnoreCase)
        { "Description", "Title", "Basis", "Notes", "Detail" };

    public MhGrid()
    {
        AutoGenerateColumns = true;
        IsReadOnly = true;
        SelectionMode = DataGridSelectionMode.Single;
        SelectionUnit = DataGridSelectionUnit.FullRow;
        HeadersVisibility = DataGridHeadersVisibility.Column;
        GridLinesVisibility = DataGridGridLinesVisibility.Horizontal;
        CanUserAddRows = false;
        CanUserDeleteRows = false;
        CanUserReorderColumns = true;
        CanUserSortColumns = true;
        EnableRowVirtualization = true;
        Background = AppResources.Resource<System.Windows.Media.Brush>("Paper");
        Foreground = AppResources.Resource<System.Windows.Media.Brush>("Ink");
        HorizontalGridLinesBrush = AppResources.Resource<System.Windows.Media.Brush>("Line");
        // a DataGrid draws its own border in the system theme's blue, which is the one colour in
        // the window belonging to no palette at all - and it frames every grid on every page
        BorderBrush = AppResources.Resource<System.Windows.Media.Brush>("Line");
        BorderThickness = new Thickness(1);
        FontFamily = AppResources.Resource<System.Windows.Media.FontFamily>("BodyFont");
        AutoGeneratingColumn += (s, e) => OnAutoGeneratingColumn(this, e);
    }

    /// <summary>
    ///   A look for one column's cells, by column name - how the Today page colours an alert's
    ///   priority. It has to be asked for here rather than set on the column afterwards: the columns
    ///   are generated when the grid is first measured, not when the table is bound, so anything set
    ///   straight after Bind is set on an empty collection and quietly does nothing at all.
    /// </summary>
    public Func<string, Style?>? CellStyleFor { get; set; }

    private static void OnAutoGeneratingColumn(MhGrid grid, DataGridAutoGeneratingColumnEventArgs e)
    {
        // carried for the code to branch on, not for reading: the same rule as Output.Shown
        if (e.PropertyName.StartsWith('_')) { e.Cancel = true; return; }

        var text = new DataGridTextColumn
        {
            Header = Output.Heading(e.PropertyName),
            Binding = new Binding($"[{e.PropertyName}]")
            {
                Converter = CellText.Instance,
                ConverterParameter = e.PropertyName
            },
            SortMemberPath = e.PropertyName
        };

        if (e.PropertyType == typeof(decimal) || e.PropertyType == typeof(int) || e.PropertyType == typeof(long))
            text.CellStyle = RightAligned();
        if (Wide.Contains(e.PropertyName))
            text.MaxWidth = 380;
        if (grid.CellStyleFor?.Invoke(e.PropertyName) is { } look)
            text.CellStyle = look;

        e.Column = text;
    }

    private static Style RightAligned()
    {
        var style = new Style(typeof(DataGridCell));
        style.Setters.Add(new Setter(HorizontalAlignmentProperty, HorizontalAlignment.Right));
        return style;
    }

    /// <summary>The table on show, or null before anything has been bound.</summary>
    public DataTable? Table { get; private set; }

    /// <summary>
    ///   Puts a table up, keeping the selection on the same row rather than the same row number.
    ///   See <see cref="RowKey"/> for why that is not the same thing.
    /// </summary>
    public void Bind(DataTable table)
    {
        var was = Table == null ? null : RowKey.Of(Table, SelectedIndex);
        var wasIndex = SelectedIndex;
        Table = table;
        ItemsSource = table.DefaultView;
        Columns.Clear();                     // AutoGenerateColumns rebuilds them for the new table
        AutoGenerateColumns = true;
        SelectedIndex = RowKey.Reselect(table, was, wasIndex);
    }

    /// <summary>The selected row, or null when nothing is selected.</summary>
    public DataRow? SelectedRow() =>
        SelectedItem is DataRowView view ? view.Row : null;

    /// <summary>
    ///   Selects the first row whose <paramref name="column"/> reads as <paramref name="value"/>,
    ///   and says whether there was one. How the tree puts you on a client it has just opened.
    /// </summary>
    public bool Select(string column, string value)
    {
        if (Table == null || !Table.Columns.Contains(column)) return false;
        for (var i = 0; i < Table.Rows.Count; i++)
        {
            if (Output.Format(column, Table.Rows[i][column]) != value) continue;
            SelectedIndex = i;
            return true;
        }
        return false;
    }

    /// <summary>One cell of the selected row, formatted as the screen shows it. Null when there is none.</summary>
    public string? Selected(string column)
    {
        var row = SelectedRow();
        if (row == null || !row.Table.Columns.Contains(column)) return null;
        var value = row[column];
        return value is DBNull ? null : Output.Format(column, value);
    }
}
