// What the Today page shows, decided apart from how it is drawn. The money block and the alert
// colouring are both rules rather than layout, so they live here where a test can read them.
using System.Globalization;

namespace MolehillManager;

/// <summary>One figure on the Today page, with the words that go above it.</summary>
public sealed record Tile(string Label, string Value);

public static class Today
{
    private static readonly (string Label, string Column)[] Figures =
    {
        ("Monthly recurring revenue", "MonthlyRecurringRevenue"),
        ("Draft invoices", "DraftInvoicesTotal"),
        ("Sent, unpaid", "UnpaidSentTotal"),
        ("Overdue", "OverdueTotal"),
        ("Paid this year", "PaidThisYear"),
        ("Consultancy logged, not yet invoiced", "UnbilledConsultancy")
    };

    /// <summary>
    ///   The money figures, and the open-ticket count after them. A figure the database does not
    ///   report is left out rather than shown empty: the terminal prints the whole block from a
    ///   format string, so a missing figure arrives as a lone pound sign with nothing after it.
    /// </summary>
    public static IReadOnlyList<Tile> Tiles(DashboardView dashboard)
    {
        var tiles = Figures
            .Select(f => (f.Label, Amount: dashboard.Amount(f.Column)))
            .Where(f => f.Amount.HasValue)
            .Select(f => new Tile(f.Label, "£" + f.Amount!.Value.ToString("N2", CultureInfo.InvariantCulture)))
            .ToList();
        tiles.Add(new Tile("Open tickets", dashboard.OpenTicketCount.ToString(CultureInfo.InvariantCulture)));
        return tiles;
    }

    /// <summary>
    ///   How an alert's priority is coloured, as <see cref="Gui.Palette"/> keys rather than brushes,
    ///   so the rule stays testable and the window only has to look the keys up.
    ///
    ///   These are deliberately the same colours as the dashboard HTML the clients already receive -
    ///   <c>td.high</c>, <c>td.normal</c> and <c>td.low</c> in <c>MolehillAdmin_Install.sql</c> - and
    ///   the self-test holds them to that file, so the window and the e-mail agree by rule and not
    ///   by coincidence. Anything else, including a priority a later version of the database invents,
    ///   is left uncoloured rather than guessed at.
    /// </summary>
    public static (string Background, string Ink, bool Bold)? AlertColour(string? priority) => priority switch
    {
        "High" => ("StatusRed", "StatusRedInk", true),
        "Normal" => ("StatusAmber", "Ink", true),
        "Low" => ("StatusInfo", "Ink", false),
        _ => null
    };
}
