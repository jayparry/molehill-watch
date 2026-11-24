// The pure half of Output: turning a value or a table into text. Shared by the terminal UI,
// the text tables on every detail pane and - the reason it is a file of its own - the GUI grid,
// which must not reach into a Terminal.Gui file to format a cell. Nothing here draws anything.
using System.Data;
using System.Globalization;
using System.Text;

namespace MolehillManager;

public static partial class Output
{
    /// <summary>
    ///   The columns worth showing. A leading underscore marks one a query carries for the code to
    ///   branch on - a raw status, an id - rather than for anyone to read, so no screen prints it.
    /// </summary>
    public static IReadOnlyList<DataColumn> Shown(DataTable table) =>
        table.Columns.Cast<DataColumn>().Where(c => !c.ColumnName.StartsWith('_')).ToList();

    /// <summary>
    ///   Whether a table reads better as "Name : value" lines than as columns - one row with more
    ///   columns than fit comfortably across. Shared so the window lays a result out the same way
    ///   the terminal prints it, rather than deciding it again in WPF.
    /// </summary>
    public static bool ReadsBetterVertical(DataTable table) =>
        table.Rows.Count == 1 && Shown(table).Count > 4;

    public static string TextTable(DataTable table, bool vertical = false)
    {
        var sb = new StringBuilder();
        if (table.Rows.Count == 0) { sb.AppendLine("(no rows)"); return sb.ToString(); }
        var shown = Shown(table);

        if (vertical || ReadsBetterVertical(table))
        {
            var w = shown.Max(c => c.ColumnName.Length);
            foreach (DataRow row in table.Rows)
            {
                foreach (var c in shown) sb.AppendLine($"{c.ColumnName.PadRight(w)} : {Format(c.ColumnName, row[c])}");
                sb.AppendLine();
            }
            return sb.ToString();
        }

        var widths = shown
            .Select(c => Math.Min(40, Math.Max(c.ColumnName.Length, table.Rows.Cast<DataRow>().Select(r => Format(c.ColumnName, r[c]).Length).DefaultIfEmpty(0).Max())))
            .ToArray();
        string Cell(string s, int w) => (s.Length > w ? s[..(w - 1)] + "…" : s).PadRight(w);
        sb.AppendLine(string.Join("  ", shown.Select((c, i) => Cell(c.ColumnName, widths[i]))).TrimEnd());
        sb.AppendLine(string.Join("  ", widths.Select(w => new string('-', w))));
        foreach (DataRow row in table.Rows)
            sb.AppendLine(string.Join("  ", shown.Select((c, i) => Cell(Format(c.ColumnName, row[c]), widths[i]))).TrimEnd());
        return sb.ToString();
    }

    private static readonly HashSet<string> MoneyColumns = new(StringComparer.OrdinalIgnoreCase)
        { "Fee", "MonthlyFee", "Total", "SubTotal", "VatAmount", "Amount", "Price", "UnitPrice", "TotalMonthlyFee" };

    /// <summary>Formats a cell; money columns always show pence.</summary>
    public static string Format(string column, object? value) =>
        value is decimal m && MoneyColumns.Contains(column) ? m.ToString("N2", CultureInfo.InvariantCulture) : Format(value);

    public static string Format(object? value) => value switch
    {
        null or DBNull => "",
        DateTime d when d.TimeOfDay == TimeSpan.Zero => d.ToString("dd MMM yyyy", CultureInfo.InvariantCulture),
        DateTime d => d.ToString("dd MMM yyyy HH:mm", CultureInfo.InvariantCulture),
        decimal m => m.ToString("0.##", CultureInfo.InvariantCulture),
        bool b => b ? "Yes" : "No",
        _ => value.ToString()?.Replace("\r", " ").Replace("\n", " ") ?? ""
    };
}
