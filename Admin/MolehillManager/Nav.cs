// The left-hand tree, decided apart from how it is drawn. Nothing here touches a database or a
// screen: Build is handed the engagements table and returns the whole tree, so what the window
// offers - and where you are in it - can be asserted with no window at all.
using System.Data;

namespace MolehillManager;

/// <summary>Which part of the app a node leads to. The window switches on this, never on a label.</summary>
public enum NavKind { Today, Clients, Client, Engagement, Tickets, Billing, Settings }

/// <summary>
///   One line in the tree. <paramref name="Key"/> is the client name or the engagement reference -
///   what the page needs to load itself - and is null for the fixed nodes, which need nothing.
/// </summary>
public sealed record NavNode(NavKind Kind, string Label, string? Key = null)
{
    public IReadOnlyList<NavNode> Children { get; init; } = Array.Empty<NavNode>();

    /// <summary>
    ///   <c>Monitoring</c> or <c>Consultancy</c>, straight from the column the query carries for the
    ///   purpose, and null on every other kind of node. This is the most load-bearing branch in the
    ///   app - it picks which page opens - and it used to be decided by comparing a cell against the
    ///   word "Consultancy" that a CASE in the query had just produced.
    /// </summary>
    public string? EngagementType { get; init; }
}

public static class Nav
{
    /// <summary>The breadcrumb separator. One place, so the window does not spell it twice.</summary>
    public const string Separator = " › ";

    /// <summary>
    ///   The whole tree. The five fixed nodes are always there, in this order, so the window opens
    ///   and is navigable before any data arrives - and when there is no data at all, which is what
    ///   a brand new database looks like.
    /// </summary>
    public static IReadOnlyList<NavNode> Build(DataTable? engagements) => new[]
    {
        new NavNode(NavKind.Today, "Today"),
        new NavNode(NavKind.Clients, "Clients") { Children = Clients(engagements) },
        new NavNode(NavKind.Tickets, "Tickets"),
        new NavNode(NavKind.Billing, "Billing"),
        new NavNode(NavKind.Settings, "Settings")
    };

    private static IReadOnlyList<NavNode> Clients(DataTable? engagements)
    {
        if (engagements == null || !engagements.Columns.Contains("Client") || !engagements.Columns.Contains("Ref"))
            return Array.Empty<NavNode>();

        // one line per client however many engagements they have, and in the order a person would
        // look for a name rather than the order the query happened to return
        return engagements.Rows.Cast<DataRow>()
            .GroupBy(r => Text(r, "Client") ?? "")
            .OrderBy(g => g.Key, StringComparer.CurrentCultureIgnoreCase)
            .Select(g => new NavNode(NavKind.Client, g.Key, g.Key)
            {
                Children = g.Select(r => new NavNode(NavKind.Engagement, EngagementLabel(r), Text(r, "Ref"))
                {
                    EngagementType = Text(r, "_EngagementType")
                }).ToList()
            })
            .ToList();
    }

    /// <summary>
    ///   What an engagement is called in the tree. A support agreement is "Molehill Watch" - its
    ///   What column says "3 instance(s) monitored", which is worth knowing on the page and not in
    ///   a list of names - and a consultancy engagement is its project name, which is exactly what
    ///   you would be looking for.
    /// </summary>
    private static string EngagementLabel(DataRow row)
    {
        if (Text(row, "_EngagementType") == "Monitoring") return Text(row, "Type") ?? "Molehill Watch";
        var name = Text(row, "What");
        return string.IsNullOrWhiteSpace(name) ? Text(row, "Ref") ?? "" : name;
    }

    private static string? Text(DataRow row, string column) =>
        row.Table.Columns.Contains(column) && row[column] is string s ? s : null;

    /// <summary>The node for a kind and key, or null when the tree has no such thing any more.</summary>
    public static NavNode? Find(IReadOnlyList<NavNode> roots, NavKind kind, string? key = null) =>
        Path(roots, kind, key)?.LastOrDefault();

    /// <summary>
    ///   The nodes from the top down to the one asked for, which is what the breadcrumb is made of.
    ///   Empty when it is not in the tree - a client who was removed while the window was open.
    /// </summary>
    public static IReadOnlyList<NavNode> Trail(IReadOnlyList<NavNode> roots, NavKind kind, string? key = null) =>
        (IReadOnlyList<NavNode>?)Path(roots, kind, key) ?? Array.Empty<NavNode>();

    /// <summary>The breadcrumb itself, so the window joins nothing up for itself.</summary>
    public static string Breadcrumb(IReadOnlyList<NavNode> roots, NavKind kind, string? key = null) =>
        string.Join(Separator, Trail(roots, kind, key).Select(n => n.Label));

    private static List<NavNode>? Path(IEnumerable<NavNode> nodes, NavKind kind, string? key)
    {
        foreach (var node in nodes)
        {
            if (node.Kind == kind && node.Key == key) return new List<NavNode> { node };
            var below = Path(node.Children, kind, key);
            if (below == null) continue;
            below.Insert(0, node);
            return below;
        }
        return null;
    }
}
