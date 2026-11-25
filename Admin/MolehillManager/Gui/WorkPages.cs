using System.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   The Tickets and Billing pages. Both are a list with a description underneath, so both are a
///   <see cref="ListPage"/>; what differs is the filter above the list, what goes below it, and
///   which rules decide the actions.
///
///   Neither touches a database. The tables arrive fetched, and what goes underneath comes back
///   from a callback the window supplies - the same arrangement the Today page and the client list
///   already use, and the reason all of this can be driven with no server.
/// </summary>
internal static class WorkPages
{
    public const string OpenOnly = "Open tickets only";
    public const string Outstanding = "Outstanding only (draft and sent)";

    /// <summary>
    ///   The tickets. <paramref name="describe"/> gives the whole ticket as text - who raised it,
    ///   when a response was due, and every minute logged against it.
    /// </summary>
    public static ListPage Tickets(DataTable tickets, bool openOnly, Action<bool> reload,
        Func<string, string> describe, RunGridAction run)
    {
        var tick = new CheckBox
        {
            Content = OpenOnly,
            IsChecked = openOnly,
            Margin = new Thickness(0, 0, 0, 8),
            Foreground = AppResources.Resource<Brush>("InkSecondary")
        };
        ListPage? page = null;
        tick.Click += (_, _) => Report.Try("Tickets", () => reload(tick.IsChecked == true));

        page = new ListPage(tickets, tick, "Ticket",
            list => list.Selected("Ticket") is { } reference ? describe(reference) : NoTickets,
            () => ActionRules.TicketsTab(page?.List.Selected("Ticket")),
            run);
        page.Opened = () => Report.Try("Tickets", () =>
        {
            if (page!.List.Selected("Ticket") != null) run("ticket-details", page.List);
        });
        return page;
    }

    /// <summary>What the lower half says when there is no ticket to describe.</summary>
    public const string NoTickets = "No tickets. Open one with the button above.";

    /// <summary>What it says when there is no invoice.</summary>
    public const string NoInvoices = "No invoices. \"Run billing\" above makes them.";

    /// <summary>
    ///   The invoices, with the lines of the one selected underneath as a grid rather than as a
    ///   block of text - they are a table, and the terminal only lays them out as words because it
    ///   has nowhere else to put them.
    /// </summary>
    public static ListPage Billing(DataTable invoices, bool outstandingOnly, Action<bool> reload,
        Func<string, DataTable> lines, RunGridAction run)
    {
        var tick = new CheckBox
        {
            Content = Outstanding,
            IsChecked = outstandingOnly,
            Margin = new Thickness(0, 0, 0, 8),
            Foreground = AppResources.Resource<Brush>("InkSecondary")
        };
        ListPage? page = null;
        tick.Click += (_, _) => Report.Try("Billing", () => reload(tick.IsChecked == true));

        page = new ListPage(invoices, tick, "Invoice lines",
            list => list.Selected("Invoice") is { } no ? lines(no) : (object)NoInvoices,
            () => Actions(page?.List),
            run);
        page.Opened = () => Report.Try("Billing", () =>
        {
            if (page!.List.Selected("Invoice") != null) run("invoice-html", page.List);
        });
        return page;
    }

    /// <summary>
    ///   Whether the selected invoice is a draft - and so whether its lines can be changed - comes
    ///   from the raw flag the query carries, not from the Status cell. The two agree today; the
    ///   point is that one is the value and the other is a label that has already been rewritten
    ///   once, because a sent invoice past its due date is printed as OVERDUE.
    /// </summary>
    private static MhActionSet Actions(MhGrid? list)
    {
        var row = list?.SelectedRow();
        var draft = row != null && row.Table.Columns.Contains("_IsDraft") && row["_IsDraft"] is true;
        return ActionRules.BillingTab(list?.Selected("Invoice"), draft);
    }
}
