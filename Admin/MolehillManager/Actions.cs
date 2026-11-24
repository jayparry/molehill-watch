// What the user can do, decided apart from how it is offered. Nothing here draws anything, nothing
// here touches a database: every rule below is a function of the selected row, so the whole matrix
// can be asserted without a screen. The screens turn a set into a menu (terminal) or a row of
// buttons (GUI) and look each chosen action up by its Id, never by the words on its label.
using System.Data;

namespace MolehillManager;

/// <summary>
///   One named thing the user can do. An action that does not apply is still in the set, disabled
///   and carrying the reason, so a screen can say why rather than leave the user guessing.
/// </summary>
public sealed record MhAction(string Id, string Label)
{
    public bool Enabled { get; init; } = true;

    /// <summary>Why it cannot be done, in a sentence fit to show. Null when it can.</summary>
    public string? DisabledReason { get; init; }

    public static MhAction Off(string id, string label, string reason) =>
        new(id, label) { Enabled = false, DisabledReason = reason };

    /// <summary>Enabled when the condition holds, disabled with the reason when it does not.</summary>
    public static MhAction If(bool condition, string id, string label, string reason) =>
        condition ? new MhAction(id, label) : Off(id, label, reason);
}

/// <summary>The actions for one selection, with the title the screen shows above them.</summary>
public sealed record MhActionSet(string Title, IReadOnlyList<MhAction> Actions)
{
    /// <summary>The ones that can actually be done. The terminal UI offers only these.</summary>
    public IReadOnlyList<MhAction> Available => Actions.Where(a => a.Enabled).ToList();

    public MhAction? ById(string id) => Actions.FirstOrDefault(a => a.Id == id);

    public MhActionSet Add(params MhAction[] more) => new(Title, Actions.Concat(more).ToList());

    /// <summary>
    ///   The same set with everything outside <paramref name="ids"/> greyed and carrying
    ///   <paramref name="reason"/>. What a part-built window offers: the action is still on show,
    ///   so nothing quietly disappears while the port is half done, and the reason says where to go
    ///   for it meanwhile. An action already disabled keeps the reason it had, that being the more
    ///   specific of the two.
    /// </summary>
    public MhActionSet Only(IEnumerable<string> ids, string reason)
    {
        var handled = new HashSet<string>(ids);
        return new MhActionSet(Title, Actions
            .Select(a => !a.Enabled || handled.Contains(a.Id) ? a : MhAction.Off(a.Id, a.Label, reason))
            .ToList());
    }
}

/// <summary>
///   Every availability rule in the app, as functions of the data. These used to be scattered
///   through the three windows, deciding from the words in a formatted grid cell; the queries now
///   carry the raw values (the <c>_</c>-prefixed columns) and the rules read those.
/// </summary>
public static class ActionRules
{
    private static MhActionSet Set(string title, params MhAction[] actions) => new(title, actions);

    private static bool Blank(object? v) => v is null or DBNull;

    // ---------------------------------------------------------------- shared groups

    /// <summary>A ticket's actions, the same on the Tickets tab and inside an agreement.</summary>
    public static MhActionSet Ticket(string? ticketRef) => ticketRef == null
        ? Set("Tickets", new MhAction("ticket-new", "Open a ticket"))
        : Set($"Ticket {ticketRef}",
            new MhAction("ticket-details", "Details and time logged"),
            new MhAction("ticket-respond", "Record first response"),
            new MhAction("ticket-log-time", "Log time"),
            new MhAction("ticket-rate", "Change rate (business hours / out of hours)"),
            new MhAction("ticket-edit-time", "Correct or remove logged time"),
            new MhAction("ticket-estimate", "Estimate / client approval"),
            new MhAction("ticket-close", "Resolve or close"),
            new MhAction("ticket-new", "Open a ticket"));

    /// <summary>
    ///   An invoice's actions. Only a draft can have its lines changed - the database refuses the
    ///   rest - so those three are offered and disabled rather than quietly missing.
    /// </summary>
    public static MhActionSet Invoice(string? invoiceNo, bool isDraft)
    {
        if (invoiceNo == null) return Set("Billing");
        const string notDraft = "Only a draft invoice can be changed. Void it to start again.";
        return Set($"Invoice {invoiceNo}",
            new MhAction("invoice-html", "Save as HTML (and open)"),
            new MhAction("invoice-sent", "Mark sent"),
            new MhAction("invoice-paid", "Mark paid"),
            MhAction.If(isDraft, "invoice-line-add", "Add a line", notDraft),
            MhAction.If(isDraft, "invoice-line-remove", "Remove a line", notDraft),
            MhAction.If(isDraft, "invoice-adjust", "Add an adjustment or credit", notDraft),
            new MhAction("invoice-void", "Void"),
            new MhAction("invoice-renumber", "Put draft numbers back in date order"));
    }

    /// <summary>
    ///   A contact's actions. Removing and adding back are the same slot: exactly one of the two
    ///   applies, and which it is comes from the raw Status, not from the word in the cell.
    /// </summary>
    public static MhActionSet Contact(int? contactId, string? name, bool current, bool history = true)
    {
        var add = new MhAction("contact-add", "Add a contact");
        if (contactId == null) return Set("Contacts", add);
        var actions = new List<MhAction>
        {
            new("contact-edit", "Edit details (name, e-mail, phone, raises tickets / receives invoices)"),
            MhAction.If(current, "contact-remove", "Remove as a contact (kept in history)", $"{name} is not a current contact."),
            MhAction.If(!current, "contact-readd", "Add back as a contact", $"{name} is already a contact.")
        };
        if (history) actions.Add(new MhAction("contact-history", "History (dates as a contact)"));
        actions.Add(add);
        return new MhActionSet($"Contact {name}", actions);
    }

    // ---------------------------------------------------------------- the main window

    /// <summary>F2 on the Clients tab, and the whole tab's actions when nothing is selected.</summary>
    public static MhActionSet NewOnClients() => Set("Clients",
        new MhAction("client-new", "New client (with their Molehill Watch agreement)"),
        new MhAction("engagement-new", "New consultancy engagement"),
        new MhAction("agreement-new", "New Molehill Watch agreement for an existing client"));

    /// <summary>
    ///   The Clients tab. Support agreements and consultancy work have different actions, and which
    ///   it is comes from the raw EngagementType the query carries - the most load-bearing branch in
    ///   the app, since it also picks the detail pane and the window that opens.
    /// </summary>
    public static MhActionSet Clients(string? agreementRef, string? clientName, bool isConsultancy)
    {
        if (agreementRef == null) return NewOnClients();
        var title = $"{clientName} ({agreementRef})";
        var billing = new MhAction("billing-run", $"Run billing for {agreementRef}");
        return isConsultancy
            ? Set(title,
                new MhAction("engagement-open", "Open it (days worked, invoices, contacts)"),
                new MhAction("work-log", "Log work"),
                new MhAction("engagement-edit", "Change it (rate, name, PO, dates)"),
                new MhAction("engagement-complete", "Finished - invoice what is left"),
                new MhAction("invoice-new", "New invoice typed by hand"),
                billing,
                new MhAction("engagement-new", "New consultancy engagement"))
            : Set(title,
                new MhAction("agreement-open", "Open the agreement (instances, contacts, onboarding, pre-paid hours...)"),
                new MhAction("ticket-new", "Open a ticket"),
                new MhAction("prepaid-sell", "Sell pre-paid hours"),
                new MhAction("engagement-new", "New consultancy engagement for this client"),
                billing,
                new MhAction("client-new", "New client"));
    }

    public static MhActionSet TicketsTab(string? ticketRef) => Ticket(ticketRef);

    public static MhActionSet BillingTab(string? invoiceNo, bool isDraft)
    {
        var run = new MhAction("billing-run", "Run billing");
        var typed = new MhAction("invoice-new", "New invoice typed by hand");
        return invoiceNo == null ? Set("Billing", run, typed) : Invoice(invoiceNo, isDraft).Add(run, typed);
    }

    /// <summary>
    ///   The dashboard. <paramref name="agreementRef"/> is what the client-to-agreement lookup found,
    ///   or null: the rule does not go to the database itself.
    /// </summary>
    public static MhActionSet Dashboard(bool alertSelected, string? clientName, string? agreementRef)
    {
        const string nothing = "Pick an alert first.";
        var open = agreementRef != null
            ? new MhAction("alert-agreement", $"Open {clientName}'s agreement ({agreementRef})")
            : MhAction.Off("alert-agreement", "Open the client's agreement",
                !alertSelected ? nothing
                : string.IsNullOrEmpty(clientName) ? "This alert is not about one client."
                : $"{clientName} has no agreement to open.");
        return Set("Dashboard",
            MhAction.If(alertSelected, "alert-show", "Show the whole alert", nothing),
            open,
            new MhAction("dashboard-html", "Save the dashboard as HTML"));
    }

    // ---------------------------------------------------------------- the agreement window

    public static MhActionSet Instances(string? instanceName)
    {
        var add = new MhAction("instance-add", "Add an instance / Azure SQL server or pool");
        return instanceName == null
            ? Set("Instances", add)
            : Set($"Instance {instanceName}",
                new MhAction("instance-update", "Update versions, database count, monitoring date, notes"),
                new MhAction("instance-weekly", "Log a weekly report sent"),
                new MhAction("instance-ticket", "Open a ticket for this instance"),
                new MhAction("instance-risk", "Record unsupported-version risk acceptance"),
                new MhAction("instance-remove", "Remove from cover"),
                add);
    }

    public static MhActionSet Onboarding(string? code) => code == null
        ? Set("Onboarding", new MhAction("onboarding-show", "Checklist and version status"))
        : Set($"Onboarding {code}",
            new MhAction("onboarding-done", $"Mark '{code}' done"),
            new MhAction("onboarding-show", "Checklist and version status"));

    public static MhActionSet Weekly() => Set("Weekly reports", new MhAction("weekly-log", "Log a weekly report sent"));

    /// <summary>
    ///   A pre-paid package. The three rules here used to be read out of formatted cells, where an
    ///   unused package reads as the string "0" and an uninvoiced one as an empty cell.
    /// </summary>
    public static MhActionSet Prepaid(string? reference, string? state, object? invoice, object? used)
    {
        var sell = new MhAction("prepaid-sell", "Sell pre-paid hours");
        if (reference == null) return Set("Pre-paid hours", sell);

        var cancelled = state == "Cancelled";
        const string gone = "This package has been cancelled.";
        var unused = Blank(used) || used is decimal hours && hours == 0m;
        return Set($"Pre-paid hours {reference}",
            new MhAction("prepaid-usage", "Where the hours went"),
            MhAction.If(!cancelled, "prepaid-update", "Change expiry, how it is charged, notes", gone),
            cancelled ? MhAction.Off("prepaid-invoice", "Invoice it now, on its own", gone)
                      : MhAction.If(Blank(invoice), "prepaid-invoice", "Invoice it now, on its own",
                            $"Already on invoice {invoice}."),
            cancelled ? MhAction.Off("prepaid-cancel", "Cancel (unused only)", gone)
                      : MhAction.If(unused, "prepaid-cancel", "Cancel (unused only)",
                            $"{used} of these hours have already been used."),
            sell);
    }

    /// <summary>The agreement-wide actions, behind their own entry on the F4 list.</summary>
    public static MhActionSet AgreementWide(string agreementRef, bool paused) => Set($"Agreement {agreementRef}",
        new MhAction("agreement-review", "Record the initial review delivered"),
        new MhAction("agreement-usage", "Included hours used this cycle"),
        new MhAction("onboarding-show", "Onboarding checklist and version status"),
        new MhAction("ticket-new", "Open a ticket"),
        new MhAction("agreement-quote", "Project quote"),
        new MhAction("prepaid-sell", "Sell pre-paid hours"),
        new MhAction("agreement-notice", "Notice: preview or record the end date"),
        new MhAction("agreement-pause", paused ? "Resume support" : "Pause support (late payment)"),
        new MhAction("billing-run", "Run billing for this agreement"));

    // ---------------------------------------------------------------- the engagement window

    public static MhActionSet EngagementInvoices(string? invoiceNo, bool isDraft)
    {
        var newInvoice = new MhAction("invoice-new", "New invoice typed by hand");
        var log = new MhAction("work-log", "Log work");
        return invoiceNo == null
            ? Set("Invoices", newInvoice, log)
            : Invoice(invoiceNo, isDraft).Add(newInvoice);
    }

    /// <summary>
    ///   One logged time entry. Whether it is already invoiced comes from the row's raw InvoiceId;
    ///   it used to be read out of the words in the Invoiced cell, starting with a hard-coded "MDS"
    ///   while the invoice prefix is a user-editable setting.
    /// </summary>
    public static MhActionSet LoggedWork(int? entryId, bool invoiced, string? invoiceNo)
    {
        var log = new MhAction("work-log", "Log work");
        if (entryId == null) return Set("Everything logged", log);
        var why = $"This time is on invoice {invoiceNo}. Void that invoice, then change the time.";
        var actions = new List<MhAction>();
        if (invoiced) actions.Add(new MhAction("entry-invoiced", "Already invoiced - void the invoice first to change it"));
        actions.Add(MhAction.If(!invoiced, "entry-correct", "Correct it (date, time, description)", why));
        actions.Add(MhAction.If(!invoiced, "entry-remove", "Remove it", why));
        actions.Add(log);
        return new MhActionSet($"Logged work #{entryId}", actions);
    }

    public static MhActionSet DaysWorked(string? date)
    {
        var log = new MhAction("work-log", "Log work");
        return date == null
            ? Set("Days worked", log)
            : Set(date, log, new MhAction("work-day-correct", "Correct or remove what was logged that day"));
    }

    /// <summary>The engagement-wide actions. Finished work cannot be finished or cancelled again.</summary>
    public static MhActionSet EngagementWide(string engagementRef, bool finished)
    {
        var why = "This engagement is already finished.";
        return Set($"Engagement {engagementRef}",
            new MhAction("work-log", "Log work"),
            new MhAction("engagement-edit", "Change it (rate, name, PO, dates, on hold)"),
            MhAction.If(!finished, "engagement-complete", "Finished - invoice what is left", why),
            MhAction.If(!finished, "engagement-cancel", "Cancel (nothing invoiced)", why),
            new MhAction("invoice-new", "New invoice typed by hand"),
            new MhAction("billing-run", "Run billing for this engagement"));
    }
}
