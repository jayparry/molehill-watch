using System.Data;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   Everything one agreement's page shows, fetched by the window and handed over whole - so the
///   page never touches a database and can be built in a test from six tables made up on the spot.
///   <c>Contacts</c> is every contact, removed ones included: the page does the hiding, and says
///   how many it hid.
/// </summary>
internal sealed record AgreementData(
    string Ref,
    string ClientName,
    string Summary,
    bool Paused,
    DataTable Instances,
    DataTable Onboarding,
    DataTable Contacts,
    DataTable Tickets,
    DataTable Weekly,
    DataTable Prepaid);

/// <summary>
///   One Molehill Watch agreement, as a page in the content pane rather than a dialog over the
///   main window.
///
///   This is the screen the whole exercise was for. In the terminal it is a dialog with six tabs
///   where every action sits behind Enter or F4, the F4 list changes with both the tab and the
///   selected row, and its last item opens a second list holding the agreement-wide actions -
///   which is as deep as the hiding gets anywhere in the app. Here the tabs are tabs, the row's
///   actions are buttons, and the agreement's own actions are a second group of buttons beside
///   them.
/// </summary>
internal static class AgreementPage
{
    public const string Instances = "Instances";
    public const string Onboarding = "Onboarding";
    public const string Contacts = "Contacts";
    public const string Tickets = "Tickets";
    public const string Weekly = "Weekly reports";
    public const string Prepaid = "Pre-paid hours";

    /// <summary>What the Contacts tab says about the removed ones while it is showing them.</summary>
    public const string AddBackHere = "pick one and press \"Add back as a contact\"";

    private const string PrepaidNote =
        "A package is charged on the client's next monthly invoice unless you said otherwise. "
        + "Hours come off it when billing runs, not when time is logged.";

    /// <summary>
    ///   What double-clicking a row does, per tab. Named rather than "whatever is first in the
    ///   list", so that reordering the actions one day cannot quietly change what a double-click
    ///   does. It is only ever a shortcut: every one of these is a button on the toolbar as well.
    /// </summary>
    private static readonly Dictionary<string, string> OnDoubleClick = new()
    {
        [Instances] = "instance-update",
        [Onboarding] = "onboarding-done",
        [Contacts] = "contact-edit",
        [Tickets] = "ticket-details",
        [Prepaid] = "prepaid-usage"
    };

    /// <summary>
    ///   Builds the page. <paramref name="canDo"/> is what the window has wired up: anything else
    ///   is greyed and carries <paramref name="notYet"/> rather than being dropped, so a half-built
    ///   window is honest about what it cannot do and says where to go instead.
    /// </summary>
    public static DetailPage Build(AgreementData data, IReadOnlyCollection<string>? canDo, string notYet,
        RunDetailAction run)
    {
        var tabs = new List<DetailTab>();
        MhGrid Grid(string header) => tabs.First(t => t.Header == header).Grid;
        // null means the window does the lot, which is not the same as listing every id here
        // and letting the two drift apart
        MhActionSet Narrow(MhActionSet set) => canDo == null ? set : set.Only(canDo, notYet);

        // Contacts: the removed ones are hidden behind a tick box, and their count is always said.
        var showRemoved = new CheckBox
        {
            Content = "Show removed contacts",
            Foreground = AppResources.Resource<Brush>("InkSecondary")
        };
        var removedNote = new TextBlock
        {
            Foreground = AppResources.Resource<Brush>("Muted"),
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0)
        };
        var contactsHeader = new StackPanel { Orientation = Orientation.Vertical };
        contactsHeader.Children.Add(showRemoved);
        contactsHeader.Children.Add(removedNote);

        tabs.Add(new DetailTab(Instances, () => Narrow(ActionRules.Instances(Grid(Instances).Selected("Instance")))));
        tabs.Add(new DetailTab(Onboarding, () => Narrow(ActionRules.Onboarding(Grid(Onboarding).Selected("Code")))));
        tabs.Add(new DetailTab(Contacts, () => Narrow(ContactActions(Grid(Contacts))), above: contactsHeader));
        tabs.Add(new DetailTab(Tickets, () => Narrow(ActionRules.Ticket(Grid(Tickets).Selected("Ticket")))));
        tabs.Add(new DetailTab(Weekly, () => Narrow(ActionRules.Weekly())));
        tabs.Add(new DetailTab(Prepaid, () => Narrow(PrepaidActions(Grid(Prepaid))), note: PrepaidNote));

        Grid(Instances).Bind(data.Instances);
        Grid(Onboarding).Bind(data.Onboarding);
        Grid(Tickets).Bind(data.Tickets);
        Grid(Weekly).Bind(data.Weekly);
        Grid(Prepaid).Bind(data.Prepaid);

        void ShowContacts()
        {
            var showing = showRemoved.IsChecked == true;
            Grid(Contacts).Bind(showing ? data.Contacts : Detail.CurrentContacts(data.Contacts));
            removedNote.Text = Detail.RemovedContactsNote(Detail.RemovedCount(data.Contacts), showing, AddBackHere);
        }
        showRemoved.Click += (_, _) => Report.Try(Contacts, ShowContacts);
        ShowContacts();

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
            Narrow(ActionRules.AgreementWide(data.Ref, data.Paused)), run);
    }

    /// <summary>
    ///   A contact's actions. Whether they are a current contact comes from the raw Status rather
    ///   than from the word in the cell, and the grid may or may not be showing the removed ones.
    /// </summary>
    private static MhActionSet ContactActions(MhGrid grid)
    {
        var row = grid.SelectedRow();
        if (row == null || row["Id"] is not int id) return ActionRules.Contact(null, null, false);
        return ActionRules.Contact(id, grid.Selected("Name") ?? "Contact", row["Status"] as string == "Current");
    }

    /// <summary>
    ///   A pre-paid package. The rules read the raw cells, because an unused package's Used reads
    ///   as the string "0" once formatted and an uninvoiced one's Invoice as an empty cell.
    /// </summary>
    private static MhActionSet PrepaidActions(MhGrid grid)
    {
        var row = grid.SelectedRow();
        return ActionRules.Prepaid(grid.Selected("Ref"), row?["State"] as string, row?["Invoice"], row?["Used"]);
    }
}
