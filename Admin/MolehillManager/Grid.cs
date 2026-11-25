using System.Data;
using System.Text;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>TableView helpers: consistent look, readable dates and money, selected-row lookups.</summary>
public static class Grid
{
    public static TableView Make() => new()
    {
        X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(),
        FullRowSelect = true,
        MultiSelect = false,
        MaxCellWidth = 60,
        NullSymbol = "",
        Style = new TableView.TableStyle { ShowHorizontalHeaderOverline = false, ShowHorizontalHeaderUnderline = true, ExpandLastColumn = true, AlwaysShowHeaders = true }
    };

    public static void Bind(TableView view, DataTable table)
    {
        var keep = view.SelectedRow;
        view.Table = table;
        foreach (DataColumn c in table.Columns)
        {
            var style = view.Style.GetOrCreateColumnStyle(c);
            var name = c.ColumnName;
            // carried for the code to branch on, not for reading: see Output.Shown
            if (name.StartsWith('_')) { style.Visible = false; continue; }
            style.RepresentationGetter = v => Output.Format(name, v);
            if (c.DataType == typeof(decimal) || c.DataType == typeof(int)) style.Alignment = TextAlignment.Right;
            if (c.ColumnName is "Description" or "Title" or "Basis" or "Notes" or "Detail") style.MaxWidth = 50;
        }
        view.SelectedRow = table.Rows.Count == 0 ? 0 : Math.Min(Math.Max(keep, 0), table.Rows.Count - 1);
        view.Update();
    }

    public static string? Selected(TableView view, string column)
    {
        var t = view.Table;
        if (t == null || t.Rows.Count == 0 || view.SelectedRow < 0 || view.SelectedRow >= t.Rows.Count || !t.Columns.Contains(column)) return null;
        var v = t.Rows[view.SelectedRow][column];
        return v is DBNull ? null : Output.Format(v);
    }

    public static DataRow? SelectedRow(TableView view)
    {
        var t = view.Table;
        return t == null || view.SelectedRow < 0 || view.SelectedRow >= t.Rows.Count ? null : t.Rows[view.SelectedRow];
    }
}

/// <summary>Runs a form or action, reports errors in full, and refreshes afterwards.</summary>
public static class Ui
{
    public static void Form(FormSpec spec, Action? refresh)
    {
        if (FormDialog.Show(spec) != null) refresh?.Invoke();
    }

    /// <summary>
    ///   Set by the self-test. A MessageBox under the fake driver waits for a keystroke that never
    ///   arrives, so an error raised while a window was building its panes would hang the run
    ///   instead of failing it - which it did, for forty minutes, before anyone noticed.
    /// </summary>
    internal static bool Headless;

    public static void Try(string title, Action action)
    {
        if (Headless) { action(); return; }   // let it out, so the harness reports it
        try { action(); }
        catch (Exception ex) { MessageBox.ErrorQuery(title, AdminDb.Explain(ex), "Ok"); }
    }

    /// <summary>
    ///   Runs the billing for one client, agreement or engagement and shows what it did. The
    ///   procedure says nothing at all when there was nothing to bill, so say so; this was written
    ///   out three times, once in each window.
    /// </summary>
    public static void RunBilling(AdminDb db, string reference, Action refresh) => Try("Billing", () =>
    {
        var r = db.Proc("dbo.usp_Billing_Run", ("@Client", reference));
        if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing new to invoice.");
        Output.Show("Billing", r);
        refresh();
    });

    /// <summary>Writes a file and offers to open it in the default browser.</summary>
    public static void Saved(string title, string path)
    {
        if (MessageBox.Query(title, $"Saved to\n{path}", "Open", "Ok") != 0) return;
        Try(title, () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }));
    }
}

/// <summary>The actions on an invoice, shared by the Billing tab and the engagement window.</summary>
public static class InvoiceActions
{
    /// <summary>What applies to this invoice: only a draft can have its lines changed.</summary>
    public static MhActionSet Set(AdminDb db, string invoiceNo) =>
        ActionRules.Invoice(invoiceNo, Queries.IsDraftInvoice(db, invoiceNo));

    public static Dictionary<string, Action> Handlers(AdminDb db, string invoiceNo, Action refresh) => new()
    {
        ["invoice-html"] = () => Ui.Try("Invoice", () => Ui.Saved("Invoice", AdminForms.SaveInvoiceHtml(db, invoiceNo, AdminForms.OutputFolder))),
        ["invoice-sent"] = () => Ui.Form(AdminForms.SetInvoiceStatus(db, invoiceNo, "Sent"), refresh),
        ["invoice-paid"] = () => Ui.Form(AdminForms.SetInvoiceStatus(db, invoiceNo, "Paid"), refresh),
        ["invoice-line-add"] = () => Ui.Form(AdminForms.AddInvoiceLine(db, invoiceNo), refresh),
        ["invoice-line-remove"] = () => Ui.Try("Invoice", () => RemoveLine(db, invoiceNo, refresh)),
        ["invoice-adjust"] = () => Ui.Form(AdminForms.AdjustInvoice(db, invoiceNo), refresh),
        ["invoice-void"] = () =>
        {
            if (MessageBox.Query("Void", $"Void {invoiceNo}? Any time it billed becomes billable again.", "Void", "Cancel") == 0)
                Ui.Form(AdminForms.SetInvoiceStatus(db, invoiceNo, "Void"), refresh);
        },
        ["invoice-renumber"] = () => Ui.Try("Invoice numbers", () =>
        {
            var r = db.Proc("dbo.usp_Invoice_Renumber");
            if (r.First is { Rows.Count: 0 }) r.Messages.Add("Nothing to do - they are already in date order.");
            Output.Show("Invoice numbers", r);
            refresh();
        })
    };

    /// <summary>Pick a line off a draft invoice and take it away (billing-run lines are refused by the database).</summary>
    private static void RemoveLine(AdminDb db, string invoiceNo, Action refresh)
    {
        var lines = Queries.InvoiceLines(db, invoiceNo);
        if (lines.Rows.Count == 0) { MessageBox.Query("Invoice", "This invoice has no lines yet.", "Ok"); return; }
        var labels = lines.Rows.Cast<DataRow>()
            .Select(r => $"{Output.Format(r["Description"])}  -  {Output.Format(r["Amount"])}").ToList();
        var picked = Picker.ChooseIndex($"{invoiceNo} - which line?", labels);
        if (picked == null) return;
        var row = lines.Rows[picked.Value];
        Ui.Form(AdminForms.RemoveInvoiceLine(db, invoiceNo, (int)row["Id"], labels[picked.Value]), refresh);
    }
}

/// <summary>The actions on a ticket, shared by the Tickets tab and the agreement window.</summary>
public static class TicketActions
{
    public static Dictionary<string, Action> Handlers(AdminDb db, string ticketRef, Action refresh) => new()
    {
        ["ticket-details"] = () => Ui.Try("Ticket", () => Details(db, ticketRef)),
        ["ticket-respond"] = () => Ui.Form(AdminForms.RespondTicket(db, ticketRef), refresh),
        ["ticket-log-time"] = () => Ui.Try("Log time", () => Ui.Form(AdminForms.LogTime(db, ticketRef), refresh)),
        ["ticket-rate"] = () => Ui.Try("Rate", () => Ui.Form(AdminForms.SetTicketRate(db, ticketRef), refresh)),
        ["ticket-edit-time"] = () => Ui.Try("Time", () => EditTime(db, ticketRef, refresh)),
        ["ticket-estimate"] = () => Ui.Form(AdminForms.EstimateTicket(db, ticketRef), refresh),
        ["ticket-close"] = () => Ui.Form(AdminForms.CloseTicket(db, ticketRef), refresh),
        ["ticket-new"] = () => Ui.Form(AdminForms.OpenTicket(db), refresh)
    };

    public static void Show(AdminDb db, string ticketRef, Action refresh) =>
        Picker.Actions(ActionRules.Ticket(ticketRef), Handlers(db, ticketRef, refresh));

    /// <summary>Pick one of the ticket's time entries, then correct or remove it.</summary>
    private static void EditTime(AdminDb db, string ticketRef, Action refresh)
    {
        var entries = Queries.TimeEntries(db, ticketRef);
        if (entries.Rows.Count == 0) { MessageBox.Query("Time", "No time has been logged on this ticket yet.", "Ok"); return; }
        var labels = entries.Rows.Cast<DataRow>()
            .Select(r => $"{Output.Format(r["Started"])}  {r["Minutes"]} min  {AdminForms.RateLabel(r["Rate"] as string)}  -  {Output.Format(r["Invoiced"])}")
            .ToList();
        var picked = Picker.ChooseIndex($"{ticketRef} - which time entry?", labels);
        if (picked == null) return;
        var id = (int)entries.Rows[picked.Value]["Id"];
        Picker.Actions(labels[picked.Value],
            ("Correct it (date, minutes, rate, description)", () => Ui.Form(AdminForms.EditTimeEntry(db, id), refresh)),
            ("Remove it", () => Ui.Form(AdminForms.DeleteTimeEntry(db, id), refresh)));
    }

    public static void Details(AdminDb db, string ticketRef) => Output.Text(ticketRef, Detail.TicketSummary(db, ticketRef));
}
