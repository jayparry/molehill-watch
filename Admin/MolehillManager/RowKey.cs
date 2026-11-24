using System.Data;

namespace MolehillManager;

/// <summary>
///   Which column identifies a row, and where the selection should land after a refresh.
///
///   The terminal UI keeps the selection by index: it remembers "row 4" and puts you back on row 4.
///   The screens refresh on a timer, so when something is inserted above you - a new ticket, an
///   invoice with an earlier date after a renumber - you quietly end up looking at a different row
///   than the one you were reading, and the next action you take applies to that one. Keeping it by
///   key instead costs one lookup and cannot do that.
///
///   No UI of any kind here, so the rules can be tested without a screen.
/// </summary>
public static class RowKey
{
    /// <summary>
    ///   The columns that identify a row, in the order they are preferred. These are the display
    ///   names the queries alias to - the same ones the terminal UI already reads a selection out
    ///   of - not the underlying column names.
    /// </summary>
    private static readonly string[] Candidates = { "Ref", "Ticket", "Invoice", "Id", "Code", "Instance" };

    /// <summary>
    ///   The column to remember a row by, or null when nothing in the table identifies one. A
    ///   candidate only counts when every row has a value for it and no two rows share one:
    ///   a column that repeats would put the selection on the first match, which is the bug this
    ///   exists to avoid, only harder to see.
    /// </summary>
    public static string? KeyColumn(DataTable table)
    {
        foreach (var name in Candidates)
        {
            if (!table.Columns.Contains(name)) continue;
            var values = table.Rows.Cast<DataRow>().Select(r => Output.Format(name, r[name])).ToList();
            if (values.Any(string.IsNullOrEmpty)) continue;
            if (values.Distinct(StringComparer.Ordinal).Count() != values.Count) continue;
            return name;
        }
        return null;
    }

    /// <summary>What <paramref name="table"/> row <paramref name="index"/> should be remembered as, if anything.</summary>
    public static string? Of(DataTable table, int index)
    {
        if (index < 0 || index >= table.Rows.Count) return null;
        var key = KeyColumn(table);
        return key == null ? null : Output.Format(key, table.Rows[index][key]);
    }

    /// <summary>
    ///   Where the selection goes in a table that has just been reloaded: back on the same row when
    ///   it is still there, otherwise as near as possible to where it was. -1 when there is nothing
    ///   to select.
    /// </summary>
    public static int Reselect(DataTable table, string? was, int wasIndex)
    {
        if (table.Rows.Count == 0) return -1;
        var key = KeyColumn(table);
        if (key != null && was != null)
        {
            var found = table.Rows.Cast<DataRow>()
                .Select((r, i) => (Index: i, Value: Output.Format(key, r[key])))
                .FirstOrDefault(x => string.Equals(x.Value, was, StringComparison.Ordinal), (Index: -1, Value: ""));
            if (found.Index >= 0) return found.Index;
        }
        return Math.Min(Math.Max(wasIndex, 0), table.Rows.Count - 1);
    }
}
