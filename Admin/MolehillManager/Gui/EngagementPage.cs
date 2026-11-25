using System.Data;

namespace MolehillManager.Gui;

/// <summary>
///   Everything one consultancy engagement's page shows, fetched by the window and handed over
///   whole, for the same reason as <see cref="AgreementData"/>.
/// </summary>
internal sealed record EngagementData(
    string Ref,
    string ClientName,
    string Summary,
    bool Finished,
    DataTable Work,
    DataTable Entries,
    DataTable Invoices,
    DataTable Contacts);

/// <summary>
///   One piece of consultancy work: the days worked, everything logged, its invoices and the
///   client's contacts.
///
///   The same fix as <see cref="AgreementPage"/>, and one rule worth keeping in sight while
///   reading it: whether a time entry is already invoiced is decided from the row's raw InvoiceId.
///   It used to be a test on the words in the Invoiced cell beginning with a hard-coded "MDS",
///   while the invoice prefix is a setting the user can change.
/// </summary>
internal static class EngagementPage
{
    public const string Work = "Days worked";
    public const string Entries = "Everything logged";
    public const string Invoices = "Invoices";
    public const string Contacts = "Contacts";

    private const string WorkNote =
        "A day's work is billed as one line. Everything logged on the same day counts together, "
        + "and each billing period is invoiced once it has ended.";

    private static readonly Dictionary<string, string> OnDoubleClick = new()
    {
        [Entries] = "entry-correct",
        [Invoices] = "invoice-html",
        [Contacts] = "contact-edit"
    };

    public static DetailPage Build(EngagementData data, IReadOnlyCollection<string>? canDo, string notYet,
        RunDetailAction run)
    {
        var tabs = new List<DetailTab>();
        MhGrid Grid(string header) => tabs.First(t => t.Header == header).Grid;
        // null means the window does the lot, which is not the same as listing every id here
        // and letting the two drift apart
        MhActionSet Narrow(MhActionSet set) => canDo == null ? set : set.Only(canDo, notYet);

        tabs.Add(new DetailTab(Work, () => Narrow(ActionRules.DaysWorked(Grid(Work).Selected("Date"))), note: WorkNote));
        tabs.Add(new DetailTab(Entries, () => Narrow(EntryActions(Grid(Entries)))));
        tabs.Add(new DetailTab(Invoices, () => Narrow(InvoiceActionsFor(Grid(Invoices)))));
        // this grid never lists removed contacts, so the one selected is always a current one
        tabs.Add(new DetailTab(Contacts, () => Narrow(ContactActions(Grid(Contacts)))));

        Grid(Work).Bind(data.Work);
        Grid(Entries).Bind(data.Entries);
        Grid(Invoices).Bind(data.Invoices);
        Grid(Contacts).Bind(data.Contacts);

        foreach (var tab in tabs)
        {
            if (!OnDoubleClick.TryGetValue(tab.Header, out var id)) continue;
            var captured = tab;
            captured.Opened = () =>
            {
                if (captured.Actions().ById(id)?.Enabled == true) run(id, captured);
            };
        }

        return new DetailPage(data.Summary, tabs,
            Narrow(ActionRules.EngagementWide(data.Ref, data.Finished)), run);
    }

    /// <summary>One logged time entry, and whether its time has already been invoiced.</summary>
    private static MhActionSet EntryActions(MhGrid grid)
    {
        var row = grid.SelectedRow();
        if (row == null || row["Id"] is not int id) return ActionRules.LoggedWork(null, false, null);
        return ActionRules.LoggedWork(id, row.Table.Columns.Contains("_InvoiceId") && row["_InvoiceId"] is int,
            grid.Selected("Invoiced"));
    }

    /// <summary>
    ///   An invoice. Whether it is a draft comes from the raw flag the query carries, not from the
    ///   Status cell - which reads "OVERDUE" rather than "Sent" once a sent invoice is past its due
    ///   date, and is a formatted column besides.
    /// </summary>
    private static MhActionSet InvoiceActionsFor(MhGrid grid)
    {
        var row = grid.SelectedRow();
        var draft = row != null && row.Table.Columns.Contains("_IsDraft") && row["_IsDraft"] is true;
        return ActionRules.EngagementInvoices(grid.Selected("Invoice"), draft);
    }

    private static MhActionSet ContactActions(MhGrid grid)
    {
        var row = grid.SelectedRow();
        if (row == null || row["Id"] is not int id) return ActionRules.Contact(null, null, false);
        return ActionRules.Contact(id, grid.Selected("Name") ?? "Contact", current: true, history: false);
    }
}
