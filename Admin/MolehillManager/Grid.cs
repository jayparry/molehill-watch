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

    public static void Try(string title, Action action)
    {
        try { action(); }
        catch (Exception ex) { MessageBox.ErrorQuery(title, ex is FormatException ? ex.Message : AdminDb.Describe(ex), "Ok"); }
    }

    /// <summary>Writes a file and offers to open it in the default browser.</summary>
    public static void Saved(string title, string path)
    {
        if (MessageBox.Query(title, $"Saved to\n{path}", "Open", "Ok") != 0) return;
        Try(title, () => System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }));
    }
}

/// <summary>The actions on a ticket, shared by the Tickets tab and the agreement window.</summary>
public static class TicketActions
{
    public static List<(string Label, Action Run)> List(AdminDb db, string ticketRef, Action refresh) => new()
    {
        ("Details and time logged", () => Ui.Try("Ticket", () => Details(db, ticketRef))),
        ("Record first response", () => Ui.Form(AdminForms.RespondTicket(db, ticketRef), refresh)),
        ("Log time", () => Ui.Try("Log time", () => Ui.Form(AdminForms.LogTime(db, ticketRef), refresh))),
        ("Change rate (business hours / out of hours)", () => Ui.Try("Rate", () => Ui.Form(AdminForms.SetTicketRate(db, ticketRef), refresh))),
        ("Estimate / client approval", () => Ui.Form(AdminForms.EstimateTicket(db, ticketRef), refresh)),
        ("Resolve or close", () => Ui.Form(AdminForms.CloseTicket(db, ticketRef), refresh))
    };

    public static void Show(AdminDb db, string ticketRef, Action refresh) => Picker.Actions($"Ticket {ticketRef}", List(db, ticketRef, refresh).ToArray());

    public static string Describe(AdminDb db, string ticketRef)
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

    public static void Details(AdminDb db, string ticketRef) => Output.Text(ticketRef, Describe(db, ticketRef));
}
