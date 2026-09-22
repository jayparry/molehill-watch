using System.Data;
using System.Globalization;
using System.Text;
using Terminal.Gui;

namespace MolehillManager;

public enum FieldKind { Text, Memo, Date, DateTime, Int, Decimal, Bool, Choice }

/// <summary>One input on a form. Values are held as text and parsed on submit, so bad input gets a clear message.</summary>
public sealed class Field
{
    public string Name { get; init; } = "";
    public string Label { get; init; } = "";
    public FieldKind Kind { get; init; } = FieldKind.Text;
    public bool Required { get; init; }
    public string Default { get; init; } = "";
    public string[] Choices { get; init; } = Array.Empty<string>();
    public string Help { get; init; } = "";

    public static Field Text(string name, string label, bool required = false, string def = "", string help = "") =>
        new() { Name = name, Label = label, Required = required, Default = def, Help = help };
    public static Field Memo(string name, string label, bool required = false, string def = "") =>
        new() { Name = name, Label = label, Kind = FieldKind.Memo, Required = required, Default = def };
    public static Field Date(string name, string label, bool required = false, string def = "", string help = "yyyy-mm-dd") =>
        new() { Name = name, Label = label, Kind = FieldKind.Date, Required = required, Default = def, Help = help };
    public static Field DateTime(string name, string label, bool required = false, string def = "", string help = "yyyy-mm-dd hh:mm, UK time") =>
        new() { Name = name, Label = label, Kind = FieldKind.DateTime, Required = required, Default = def, Help = help };
    public static Field Int(string name, string label, bool required = false, string def = "", string help = "") =>
        new() { Name = name, Label = label, Kind = FieldKind.Int, Required = required, Default = def, Help = help };
    public static Field Decimal(string name, string label, bool required = false, string def = "", string help = "") =>
        new() { Name = name, Label = label, Kind = FieldKind.Decimal, Required = required, Default = def, Help = help };
    public static Field Bool(string name, string label, bool def = false, string help = "") =>
        new() { Name = name, Label = label, Kind = FieldKind.Bool, Default = def ? "1" : "0", Help = help };
    public static Field Choice(string name, string label, string[] choices, string def = "", string help = "") =>
        new() { Name = name, Label = label, Kind = FieldKind.Choice, Choices = choices, Default = def == "" ? choices[0] : def, Help = help, Required = true };
}

/// <summary>What the user typed, with typed accessors. Empty text means "not given" (NULL, the procedure's default).</summary>
public sealed class FormValues
{
    private readonly Dictionary<string, string> _raw = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Field> _fields;

    public FormValues(IEnumerable<Field> fields)
    {
        _fields = fields.ToDictionary(f => f.Name, StringComparer.OrdinalIgnoreCase);
        foreach (var f in _fields.Values) _raw[f.Name] = f.Default;
    }

    public string this[string name]
    {
        get => _raw.TryGetValue(name, out var v) ? v : "";
        set
        {
            if (!_fields.ContainsKey(name)) throw new ArgumentException($"The form has no field called '{name}'.");
            _raw[name] = value ?? "";
        }
    }

    private string Label(string name) => _fields.TryGetValue(name, out var f) ? f.Label : name;

    public string? Str(string name) => string.IsNullOrWhiteSpace(this[name]) ? null : this[name].Trim();

    public bool Bool(string name) => this[name] is "1" or "true" or "True" or "yes" or "Yes";

    public int? Int(string name)
    {
        var s = Str(name);
        if (s == null) return null;
        return int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out var v) ? v
            : throw new FormatException($"{Label(name)}: '{s}' is not a whole number.");
    }

    public decimal? Dec(string name)
    {
        var s = Str(name)?.TrimStart('£');
        if (s == null) return null;
        return decimal.TryParse(s, NumberStyles.Number, CultureInfo.InvariantCulture, out var v) ? v
            : throw new FormatException($"{Label(name)}: '{s}' is not a number.");
    }

    private static readonly string[] DateFormats = { "yyyy-MM-dd", "yyyy-M-d", "dd/MM/yyyy", "d/M/yyyy", "dd MMM yyyy", "d MMM yyyy" };
    private static readonly string[] DateTimeFormats =
        { "yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-ddTHH:mm", "dd/MM/yyyy HH:mm", "d/M/yyyy H:mm", "yyyy-MM-dd" };

    public DateTime? Date(string name)
    {
        var s = Str(name);
        if (s == null) return null;
        if (s.Equals("today", StringComparison.OrdinalIgnoreCase)) return System.DateTime.Today;
        return System.DateTime.TryParseExact(s, DateFormats, CultureInfo.GetCultureInfo("en-GB"), DateTimeStyles.None, out var v) ? v
            : throw new FormatException($"{Label(name)}: '{s}' is not a date (use yyyy-mm-dd).");
    }

    public DateTime? DateTime(string name)
    {
        var s = Str(name);
        if (s == null) return null;
        if (s.Equals("now", StringComparison.OrdinalIgnoreCase)) return null;   // the procedures default to UK now
        return System.DateTime.TryParseExact(s, DateTimeFormats, CultureInfo.GetCultureInfo("en-GB"), DateTimeStyles.None, out var v) ? v
            : throw new FormatException($"{Label(name)}: '{s}' is not a date and time (use yyyy-mm-dd hh:mm).");
    }

    /// <summary>Required fields and basic type checks, before anything goes to the database.</summary>
    public void Validate()
    {
        foreach (var f in _fields.Values)
        {
            if (f.Required && f.Kind != FieldKind.Bool && string.IsNullOrWhiteSpace(this[f.Name]))
                throw new FormatException($"{f.Label} is required.");
            switch (f.Kind)
            {
                case FieldKind.Int: Int(f.Name); break;
                case FieldKind.Decimal: Dec(f.Name); break;
                case FieldKind.Date: Date(f.Name); break;
                case FieldKind.DateTime: DateTime(f.Name); break;
                case FieldKind.Choice when f.Choices.Length > 0 && !f.Choices.Contains(this[f.Name]):
                    throw new FormatException($"{f.Label}: choose one of {string.Join(", ", f.Choices)}.");
            }
        }
    }
}

/// <summary>A form: its fields, and what happens when it is submitted. The self-test drives these without a screen.</summary>
public sealed class FormSpec
{
    public string Title { get; init; } = "";
    public string Intro { get; init; } = "";
    public List<Field> Fields { get; init; } = new();
    public Func<FormValues, ProcResult> Submit { get; init; } = _ => new ProcResult();

    public FormValues NewValues() => new(Fields);

    /// <summary>Validates and submits: used by the dialog and by the self-test.</summary>
    public ProcResult Execute(FormValues values)
    {
        values.Validate();
        return Submit(values);
    }
}

/// <summary>Turns a FormSpec into a dialog.</summary>
public static class FormDialog
{
    private const int LabelWidth = 24;
    private const int DialogWidth = 98;

    /// <summary>Shows the form until it is submitted successfully or cancelled. Returns the result, or null if cancelled.</summary>
    public static ProcResult? Show(FormSpec spec)
    {
        var dialog = Create(spec, out var result);
        Application.Run(dialog);
        var r = result();
        if (r != null && (r.Messages.Count > 0 || r.Tables.Count > 0)) Output.Show(spec.Title, r);
        return r;
    }

    public static Dialog Create(FormSpec spec, out Func<ProcResult?> result)
    {
        ProcResult? submitted = null;
        result = () => submitted;
        var values = spec.NewValues();

        var introLines = string.IsNullOrEmpty(spec.Intro) ? 0 : Wrap(spec.Intro, 90).Count;
        var rows = spec.Fields.Sum(f => f.Kind == FieldKind.Memo ? 4 : 1) + introLines + (introLines > 0 ? 1 : 0);
        var screenRows = Application.Driver?.Rows ?? 40;
        var height = Math.Min(rows + 6, Math.Max(12, screenRows - 2));

        var ok = new Button("Save", true);
        var cancel = new Button("Cancel");
        var dialog = new Dialog(spec.Title, DialogWidth, height, ok, cancel);

        // a scroll view keeps long forms usable on small terminals
        var scroll = new ScrollView
        {
            X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(1),
            ContentSize = new Size(DialogWidth - 4, rows + 1),
            ShowVerticalScrollIndicator = rows + 1 > height - 4,
            AutoHideScrollBars = true
        };
        dialog.Add(scroll);

        var y = 0;
        if (introLines > 0)
        {
            scroll.Add(new Label(string.Join("\n", Wrap(spec.Intro, 90))) { X = 1, Y = 0, Width = 92, Height = introLines });
            y = introLines + 1;
        }

        var readers = new List<Action>();
        foreach (var f in spec.Fields)
        {
            var label = new Label((f.Required ? "*" : " ") + f.Label + ":") { X = 0, Y = y, Width = LabelWidth };
            scroll.Add(label);
            var x = LabelWidth + 1;
            var helpText = f.Help;
            View input;
            switch (f.Kind)
            {
                case FieldKind.Memo:
                    var memo = new TextView { X = x, Y = y, Width = 66, Height = 3, Text = f.Default, WordWrap = true };
                    readers.Add(() => values[f.Name] = memo.Text.ToString() ?? "");
                    input = memo;
                    break;
                case FieldKind.Bool:
                    var check = new CheckBox("") { X = x, Y = y, Checked = f.Default == "1" };
                    readers.Add(() => values[f.Name] = check.Checked ? "1" : "0");
                    input = check;
                    break;
                case FieldKind.Choice:
                    var current = f.Default;
                    var pick = new Button(current) { X = x, Y = y };
                    pick.Clicked += () =>
                    {
                        var chosen = Picker.Choose(f.Label, f.Choices, current);
                        if (chosen == null) return;
                        current = chosen;
                        pick.Text = chosen;
                    };
                    readers.Add(() => values[f.Name] = current);
                    input = pick;
                    helpText = string.IsNullOrEmpty(helpText) ? "Enter to choose" : helpText;
                    break;
                default:
                    var width = f.Kind switch { FieldKind.Date => 12, FieldKind.DateTime => 17, FieldKind.Int or FieldKind.Decimal => 10, _ => string.IsNullOrEmpty(f.Help) ? 66 : 30 };
                    var text = new TextField(f.Default) { X = x, Y = y, Width = width };
                    readers.Add(() => values[f.Name] = text.Text.ToString() ?? "");
                    input = text;
                    break;
            }
            scroll.Add(input);

            if (!string.IsNullOrEmpty(helpText))
            {
                var helpX = f.Kind switch
                {
                    FieldKind.Date => x + 13, FieldKind.DateTime => x + 18, FieldKind.Int or FieldKind.Decimal => x + 11,
                    FieldKind.Bool => x + 5, FieldKind.Choice => x + f.Choices.Max(c => c.Length) + 6, FieldKind.Memo => -1, _ => x + 31
                };
                if (helpX > 0 && helpX < DialogWidth - 6)
                    scroll.Add(new Label(Trim(helpText, DialogWidth - 5 - helpX)) { X = helpX, Y = y, ColorScheme = Colors.Menu });
            }
            y += f.Kind == FieldKind.Memo ? 4 : 1;
        }

        ok.Clicked += () =>
        {
            foreach (var read in readers) read();
            try
            {
                submitted = spec.Execute(values);
                Application.RequestStop();
            }
            catch (Exception ex)
            {
                MessageBox.ErrorQuery(spec.Title, ex is FormatException ? ex.Message : AdminDb.Describe(ex), "Ok");
            }
        };
        cancel.Clicked += () => Application.RequestStop();
        return dialog;
    }

    private static string Trim(string s, int max) => s.Length <= max ? s : s[..Math.Max(0, max - 1)] + "…";

    public static List<string> Wrap(string text, int width)
    {
        var lines = new List<string>();
        foreach (var para in text.Split('\n'))
        {
            var line = new StringBuilder();
            foreach (var word in para.Split(' '))
            {
                if (line.Length > 0 && line.Length + word.Length + 1 > width) { lines.Add(line.ToString()); line.Clear(); }
                if (line.Length > 0) line.Append(' ');
                line.Append(word);
            }
            lines.Add(line.ToString());
        }
        return lines;
    }
}

/// <summary>Pick one value from a list.</summary>
public static class Picker
{
    public static string? Choose(string title, IList<string> choices, string? current = null)
    {
        string? chosen = null;
        var list = new ListView(choices.ToList()) { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill() };
        var index = current == null ? -1 : choices.IndexOf(current);
        if (index >= 0) list.SelectedItem = index;
        var cancel = new Button("Cancel");
        var width = Math.Min(Math.Max(choices.Max(c => c.Length), title.Length) + 8, 100);
        var dialog = new Dialog(title, width, Math.Min(choices.Count + 5, 30), cancel);
        list.OpenSelectedItem += e => { chosen = choices[e.Item]; Application.RequestStop(); };
        cancel.Clicked += () => Application.RequestStop();
        dialog.Add(list);
        list.SetFocus();
        Application.Run(dialog);
        return chosen;
    }

    /// <summary>A list of named actions; runs the chosen one.</summary>
    public static void Actions(string title, params (string Label, Action Run)[] actions)
    {
        var chosen = Choose(title, actions.Select(a => a.Label).ToList());
        if (chosen == null) return;
        actions.First(a => a.Label == chosen).Run();
    }
}

/// <summary>Shows what a procedure said: PRINT messages first, then any result sets as text tables.</summary>
public static class Output
{
    public static void Show(string title, ProcResult result)
    {
        var sb = new StringBuilder();
        foreach (var m in result.Messages) sb.AppendLine(m);
        foreach (var t in result.Tables)
        {
            if (sb.Length > 0) sb.AppendLine();
            sb.Append(TextTable(t));
        }
        Text(title, sb.ToString());
    }

    public static void Text(string title, string text)
    {
        var close = new Button("Close", true);
        var width = Math.Min((Application.Driver?.Cols ?? 120) - 4, 130);
        var height = Math.Min((Application.Driver?.Rows ?? 40) - 4, 36);
        var dialog = new Dialog(title, width, height, close);
        var view = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(1), ReadOnly = true, Text = text.Replace("\r\n", "\n") };
        close.Clicked += () => Application.RequestStop();
        dialog.Add(view);
        Application.Run(dialog);
    }

    public static string TextTable(DataTable table, bool vertical = false)
    {
        var sb = new StringBuilder();
        if (table.Rows.Count == 0) { sb.AppendLine("(no rows)"); return sb.ToString(); }

        // one row with many columns reads better as "Name : value" lines
        if (vertical || (table.Rows.Count == 1 && table.Columns.Count > 4))
        {
            var w = table.Columns.Cast<DataColumn>().Max(c => c.ColumnName.Length);
            foreach (DataRow row in table.Rows)
            {
                foreach (DataColumn c in table.Columns) sb.AppendLine($"{c.ColumnName.PadRight(w)} : {Format(c.ColumnName, row[c])}");
                sb.AppendLine();
            }
            return sb.ToString();
        }

        var widths = table.Columns.Cast<DataColumn>()
            .Select(c => Math.Min(40, Math.Max(c.ColumnName.Length, table.Rows.Cast<DataRow>().Select(r => Format(c.ColumnName, r[c]).Length).DefaultIfEmpty(0).Max())))
            .ToArray();
        string Cell(string s, int w) => (s.Length > w ? s[..(w - 1)] + "…" : s).PadRight(w);
        sb.AppendLine(string.Join("  ", table.Columns.Cast<DataColumn>().Select((c, i) => Cell(c.ColumnName, widths[i]))).TrimEnd());
        sb.AppendLine(string.Join("  ", widths.Select(w => new string('-', w))));
        foreach (DataRow row in table.Rows)
            sb.AppendLine(string.Join("  ", table.Columns.Cast<DataColumn>().Select((c, i) => Cell(Format(c.ColumnName, row[c]), widths[i]))).TrimEnd());
        return sb.ToString();
    }

    private static readonly HashSet<string> MoneyColumns = new(StringComparer.OrdinalIgnoreCase)
        { "Fee", "MonthlyFee", "Total", "SubTotal", "VatAmount", "Amount", "Price", "UnitPrice", "TotalMonthlyFee" };

    /// <summary>Formats a cell; money columns always show pence.</summary>
    public static string Format(string column, object? value) =>
        value is decimal m && MoneyColumns.Contains(column) ? m.ToString("N2", CultureInfo.InvariantCulture) : Format(value);

    public static string Format(object? value) => value switch
    {
        null or DBNull => "",
        DateTime d when d.TimeOfDay == TimeSpan.Zero => d.ToString("dd MMM yyyy", CultureInfo.InvariantCulture),
        DateTime d => d.ToString("dd MMM yyyy HH:mm", CultureInfo.InvariantCulture),
        decimal m => m.ToString("0.##", CultureInfo.InvariantCulture),
        bool b => b ? "Yes" : "No",
        _ => value.ToString()?.Replace("\r", " ").Replace("\n", " ") ?? ""
    };
}
