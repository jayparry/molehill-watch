// The two detail screens' shared half: the summary block each shows, and the small decisions that
// used to live inside the terminal windows' button handlers. Nothing here draws anything, so the
// window and the terminal say the same words rather than growing a second version of each that
// drifts.
using System.Data;
using System.Text;

namespace MolehillManager;

/// <summary>What logging a weekly report should do next, given the instances on the agreement.</summary>
public enum WeeklyStep
{
    /// <summary>There is nothing to report on yet.</summary>
    NoInstances,

    /// <summary>Exactly one instance, so asking which would be a question with one answer.</summary>
    TheOnlyOne,

    /// <summary>Several: ask.</summary>
    Choose
}

/// <summary>The agreement and engagement screens, decided apart from how they are drawn.</summary>
public static class Detail
{
    /// <summary>What both front ends say when there is nothing to report on yet.</summary>
    public const string NoInstancesYet = "Add an instance first.";

    /// <summary>
    ///   Which instance a weekly report is for. The three-way branch matters: with no instances the
    ///   form cannot be filled in at all, and with exactly one a picker is a question whose answer
    ///   is already known - the terminal skips it, and so does the window.
    /// </summary>
    public static (WeeklyStep Step, string? Instance) WeeklyStepFor(IReadOnlyList<string> names) =>
        names.Count switch
        {
            0 => (WeeklyStep.NoInstances, null),
            1 => (WeeklyStep.TheOnlyOne, names[0]),
            _ => (WeeklyStep.Choose, null)
        };

    /// <summary>
    ///   What to say about contacts that are no longer current. They are hidden by default, because
    ///   a list of people who have left is not what anyone opens the tab for - but hiding them with
    ///   no word at all is how "why is that contact missing?" happens, so the count is always said.
    ///   Nothing is said when there are none, rather than "0 removed".
    ///
    ///   <paramref name="howToAddBack"/> is the only part the two front ends differ on, because
    ///   Enter on a row and a button are not the same instruction. Everything else - the count, the
    ///   plural, and saying nothing at all when there is nothing to say - is decided once.
    /// </summary>
    public static string RemovedContactsNote(int removed, bool showing, string howToAddBack) =>
        removed == 0 ? ""
        : showing ? $"{removed} removed - {howToAddBack}"
        : $"{removed} removed contact{(removed == 1 ? "" : "s")} hidden - tick to see or add back";

    /// <summary>How many of these contacts are no longer current.</summary>
    public static int RemovedCount(DataTable contacts) =>
        contacts.Columns.Contains("Status")
            ? contacts.Rows.Cast<DataRow>().Count(r => r["Status"] as string == "Removed")
            : 0;

    /// <summary>
    ///   Only the current ones, as the tab shows them unless asked otherwise. A copy, so that
    ///   filtering what is on the screen cannot change the table the caller still holds.
    /// </summary>
    public static DataTable CurrentContacts(DataTable contacts)
    {
        if (!contacts.Columns.Contains("Status")) return contacts;
        var only = contacts.Clone();
        foreach (var row in contacts.Select("Status = 'Current'")) only.ImportRow(row);
        return only;
    }

    // ------------------------------------------------------------------ the summaries

    /// <summary>The agreement in a few lines; with the instances and contacts for the Clients tab preview.</summary>
    public static string AgreementSummary(AdminDb db, string agreementRef, bool includeInstances)
    {
        var a = Queries.Agreement(db, agreementRef);
        if (a == null) return $"{agreementRef} not found.";
        string F(string c) => Output.Format(a[c]);
        var sb = new StringBuilder();
        sb.AppendLine($"{F("ClientName")}  ({F("AgreementRef")})   Status: {F("Status")}   Price list: {F("PriceList")}");
        sb.AppendLine($"Started {F("StartDate")}, signed {(a["SignedDate"] is DBNull ? "NOT RECORDED" : F("SignedDate"))}; " +
                      $"initial term {F("InitialTermMonths")} months to {F("InitialTermEnds")}" +
                      (a["EndDate"] is DBNull ? "" : $"; ENDS {F("EndDate")} (notice {F("NoticeGivenDate")} by {F("NoticeGivenBy")})"));
        sb.AppendLine($"Initial review: {(a["InitialReviewDoneDate"] is DBNull ? "not yet delivered" : F("InitialReviewDoneDate"))}" +
                      (a["SupportPausedFrom"] is DBNull ? "" : $"   SUPPORT PAUSED from {F("SupportPausedFrom")} (late payment)"));
        sb.AppendLine($"Tickets via: {F("TicketChannel")}");
        sb.AppendLine($"Invoices to: {(a["InvoicesTo"] is DBNull ? "NO ONE - add a contact that receives invoices (Contacts tab)" : F("InvoicesTo"))}" +
                      (a["Address"] is DBNull ? "" : $"   {F("Address")}"));

        var usage = Queries.AgreementUsage(db, agreementRef);
        if (usage.First is { Rows.Count: > 0 } u)
        {
            var r = u.Rows[0];
            sb.AppendLine($"This cycle ({Output.Format(r["CycleStart"])} - {Output.Format(r["CycleEnd"])}): " +
                          $"{Output.Format(r["BusinessHoursLogged"])} of {Output.Format(r["IncludedHours"])} included hours used, " +
                          $"{Output.Format(r["IncludedHoursRemaining"])} left; {Output.Format(r["OutOfHoursLogged"])} h out of hours"
                          + (r.Table.Columns.Contains("PrepaidHoursLeft") && r["PrepaidHoursLeft"] is decimal left ? $"; pre-paid hours left: {Output.Format(left)}" : "")
                          + (r.Table.Columns.Contains("UnbilledHours") && r["UnbilledHours"] is decimal unbilled && unbilled > 0
                             ? $"; {Output.Format(unbilled)} h logged but not yet billed" : ""));
        }
        else sb.AppendLine(usage.Messages.FirstOrDefault() ?? "");

        if (includeInstances)
        {
            var inst = Queries.Instances(db, agreementRef);
            // the database works the monthly fee out for the Clients tab and the dashboard; one figure, one place
            sb.AppendLine().AppendLine($"Instances (monthly fee £{Queries.AgreementMonthlyFee(db, agreementRef):N2}):");
            sb.Append(inst.Rows.Count == 0 ? "(none yet - open the agreement and press F2)\n" : Output.TextTable(inst));
            var contacts = Queries.Contacts(db, agreementRef).DefaultView.ToTable(false, "Name", "Email", "Phone", "Tickets", "Invoices", "From");
            sb.AppendLine().AppendLine("Contacts:");
            sb.Append(contacts.Rows.Count == 0 ? "(none)\n" : Output.TextTable(contacts));
        }
        return sb.ToString();
    }

    /// <summary>
    ///   One ticket in full: who raised it, when a response was due, what was agreed and every
    ///   minute logged against it. Shared, so the terminal's Details dialog and the window's show
    ///   the same thing.
    /// </summary>
    public static string TicketSummary(AdminDb db, string ticketRef)
    {
        var t = Queries.Ticket(db, ticketRef);
        if (t == null) return $"{ticketRef} not found.";
        var sb = new StringBuilder();
        sb.AppendLine($"{t["TicketRef"]}  {t["Title"]}");
        sb.AppendLine($"{t["ClientName"]} ({t["AgreementRef"]})   {t["Severity"]} {t["WorkType"]}   Status: {t["Status"]}   "
                      + $"Charged: {AdminForms.RateLabel(t["RateType"] as string).ToLowerInvariant()}");
        if (t["InstanceName"] is string inst) sb.AppendLine($"Instance: {inst}");
        if (t["Contact"] is string contact) sb.AppendLine($"Raised by: {contact} via {t["Channel"]}");
        sb.AppendLine($"Raised {Output.Format(t["RaisedAt"])}   response due {Output.Format(t["ResponseDueAt"])}   " +
                      (t["FirstResponseAt"] is DBNull ? "NOT RESPONDED" : $"responded {Output.Format(t["FirstResponseAt"])}"));
        if (t["EstimateHours"] is not DBNull)
            sb.AppendLine($"Estimate: {Output.Format(t["EstimateHours"])} h, " +
                          (t["EstimateApprovedAt"] is DBNull ? "awaiting approval" : $"approved {Output.Format(t["EstimateApprovedAt"])}"));
        if (t["Description"] is string d) sb.AppendLine().AppendLine(d);
        if (t["Resolution"] is string r) sb.AppendLine().AppendLine($"Resolution ({Output.Format(t["ResolvedAt"])}):").AppendLine(r);
        var time = Queries.TimeEntries(db, ticketRef);
        sb.AppendLine().AppendLine("Time logged:");
        sb.Append(time.Rows.Count == 0 ? "(none)\n" : Output.TextTable(time));
        return sb.ToString();
    }

    /// <summary>How many instances a per-instance price covers; blank on the engagement means the one.</summary>
    private static int UnitCount(DataRow e) => e["UnitCount"] is int c ? c : 1;

    /// <summary>The engagement in a few lines; with the work and invoices for the Clients tab preview.</summary>
    public static string EngagementSummary(AdminDb db, string engagementRef, bool includeWork)
    {
        var e = Queries.Engagement(db, engagementRef);
        if (e == null) return $"{engagementRef} not found.";
        string F(string c) => Output.Format(e[c]);
        var mode = (string)e["BillingMode"];
        var rate = mode switch
        {
            "DayRate" => $"£{e["DayRate"]:N2} a day",
            "Hourly" => $"£{e["HourlyRate"]:N2} an hour",
            "FixedPrice" => $"£{e["FixedPrice"]:N2} fixed price",
            "PerInstance" => $"£{e["UnitTotal"]:N2} for {UnitCount(e)} instance(s)"
                             + $" (£{e["FirstUnitPrice"]:N2} first"
                             + (e["ExtraUnitPrice"] is decimal x && x > 0 ? $", then £{x:N2} each" : ", the rest included")
                             + (e["PriceCap"] is decimal cap ? $", capped at £{cap:N2}" : "") + ")",
            _ => "per the agreement"
        };
        var sb = new StringBuilder();
        sb.AppendLine($"{F("ClientName")}  ({F("EngagementRef")})   {F("Name")}");
        sb.AppendLine($"{rate}" + (e["OutOfHoursRate"] is decimal ooh ? $", out of hours £{ooh:N2}/h" : "")
                      + $"   Status: {F("Status")}   Started {F("StartDate")}"
                      + (e["EndDate"] is DBNull ? "" : $", to {F("EndDate")}")
                      + (e["CompletedOn"] is DBNull ? "" : $", finished {F("CompletedOn")}"));
        sb.AppendLine($"Worked {e["TotalDays"]:N2} days in total; {e["UnbilledDays"]:N2} days (£{e["UnbilledValue"]:N2}) not invoiced yet"
                      + (e["LastWorked"] is DBNull ? "" : $"; last worked {F("LastWorked")}"));
        sb.AppendLine($"Invoiced so far: £{e["Invoiced"]:N2}"
                      + (e["PurchaseOrder"] is DBNull ? "" : $"   PO: {F("PurchaseOrder")}")
                      + (mode is "FixedPrice" or "PerInstance" ? "   Invoiced when you mark it finished"
                         : e["PeriodEndsOn"] is DateTime ends
                           ? $"   Billed every {e["BillingEveryDays"]} days from the start: this period ends {ends:dd MMM yyyy}" : ""));
        sb.AppendLine($"Invoices to: {(e["InvoicesTo"] is DBNull ? "NO ONE - add a contact that receives invoices" : F("InvoicesTo"))}");
        if (e["Notes"] is not DBNull) sb.AppendLine($"Notes: {F("Notes")}");

        if (includeWork)
        {
            var work = Queries.ConsultancyWork(db, engagementRef);
            sb.AppendLine().AppendLine("Days worked:");
            sb.Append(work.Rows.Count == 0 ? "(nothing logged yet - open it and press F2)\n" : Output.TextTable(work));
            var invoices = Queries.EngagementInvoices(db, engagementRef);
            sb.AppendLine().AppendLine("Invoices:");
            sb.Append(invoices.Rows.Count == 0 ? "(none yet)\n" : Output.TextTable(invoices));
        }
        return sb.ToString();
    }
}
