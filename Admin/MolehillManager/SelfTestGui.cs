using System.Data;
using System.Diagnostics;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using MolehillManager.Gui;

namespace MolehillManager;

/// <summary>
///   The views, built and laid out with no window and no screen.
///
///   The terminal front end gets an unusually good deal: FakeDriver ships inside Terminal.Gui, so
///   the read-only suite builds real screens and reads the rendered characters back out of the
///   driver's buffer. WPF has no equivalent, and rasterising to a bitmap and then needing OCR is
///   not a sensible thing to build. So what this does instead is construct every view, run layout,
///   and walk the visual tree asserting on text and control state - which catches binding errors,
///   missing resources, layout exceptions and wrong enabled/disabled states. It will not catch
///   something drawn off-screen or hidden behind something else, and that gap is the argument for
///   having put so much of the behaviour in plain classes.
///
///   A separate file from the rest of SelfTest because that one has `using Terminal.Gui`, where
///   Application means something else entirely.
/// </summary>
public static partial class SelfTest
{
    /// <summary>
    ///   Collects WPF's binding warnings, which are otherwise written to a trace nobody reads while
    ///   the control renders blank. This is the characteristic WPF failure: a mistyped binding path
    ///   is silent at build time, silent at run time, and simply shows nothing.
    /// </summary>
    private sealed class BindingWatcher : TraceListener
    {
        private readonly List<string> _lines = new();
        public IReadOnlyList<string> Lines => _lines;

        public override void Write(string? message) { if (message != null) _lines.Add(message); }
        public override void WriteLine(string? message) { if (message != null) _lines.Add(message); }
        public void Clear() => _lines.Clear();

        public static BindingWatcher Install()
        {
            var watcher = new BindingWatcher();
            PresentationTraceSources.Refresh();
            var source = PresentationTraceSources.DataBindingSource;
            source.Listeners.Add(watcher);
            source.Switch.Level = SourceLevels.Warning | SourceLevels.Error;
            return watcher;
        }
    }

    /// <summary>Lays a control out at a given width, as though it were on screen, without showing it.</summary>
    private static void Layout(FrameworkElement element, double width, double height = 900)
    {
        element.Measure(new Size(width, height));
        element.Arrange(new Rect(0, 0, width, height));
        element.UpdateLayout();
    }

    /// <summary>Every element of a kind in a control, however deeply nested.</summary>
    private static IEnumerable<T> Descendants<T>(DependencyObject root) where T : DependencyObject
    {
        var count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, i);
            if (child is T hit) yield return hit;
            foreach (var deeper in Descendants<T>(child)) yield return deeper;
        }
    }

    /// <summary>
    ///   What one TextBlock shows. A TextBlock built through its Inlines reads back Text == "" -
    ///   setting Text makes a Run, but adding Runs never updates Text - so a view written that way
    ///   would lay out, look right, and be invisible to every test here. The views are written not
    ///   to do it; this reads the inlines anyway, so that the harness is not the thing that is
    ///   blind if one ever does.
    /// </summary>
    private static string TextOf(TextBlock block) =>
        block.Text.Length > 0
            ? block.Text
            : string.Concat(block.Inlines.OfType<System.Windows.Documents.Run>().Select(r => r.Text));

    /// <summary>All the text a control would show, in tree order.</summary>
    private static List<string> Texts(DependencyObject root) =>
        Descendants<TextBlock>(root).Select(TextOf).Where(t => !string.IsNullOrWhiteSpace(t)).ToList();

    /// <summary>
    ///   One part of the suite, with a throw turned into a FAIL rather than an unhandled exception.
    ///
    ///   Worth having for the same reason Ui.Headless is. A control's constructor asking for a
    ///   resource that is not there threw out of the whole run, so the mutation that stopped the
    ///   palette being merged looked like a crashed process with a stack trace rather than a suite
    ///   reporting what was wrong - which in CI reads as "the harness is broken", and gets the
    ///   wrong thing investigated.
    /// </summary>
    private static void Section(string name, Action body)
    {
        try { body(); }
        catch (Exception ex)
        {
            Check($"{name}: ran to the end", false, AdminDb.Explain(ex).Replace("\n", " | "));
            if (Environment.GetEnvironmentVariable("MM_TRACE") == "1") Console.WriteLine(ex);
        }
    }

    public static int Gui()
    {
        Step("a WPF Application can be made with no window", () => { AppResources.Ensure(); return 0; });
        Check("and making it again gives the same one", ReferenceEquals(AppResources.Ensure(), Application.Current));

        var watcher = BindingWatcher.Install();

        // the spike: can a control be built and laid out with no window, no screen and no message loop?
        var panel = new StackPanel();
        var label = new TextBlock { Text = "Molehill" };
        panel.Children.Add(label);
        var host = new UserControl { Content = panel };
        Step("a UserControl lays out with no window", () => { Layout(host, 900); return 0; },
            _ => host.ActualWidth > 0 ? null : $"arranged to {host.ActualWidth} x {host.ActualHeight}");
        Check("and its text can be read back out of the visual tree",
            Texts(host).SequenceEqual(new[] { "Molehill" }), string.Join(" | ", Texts(host)));
        Check("no binding warnings so far", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines));

        // and the part everything else depends on: does a wrong binding path get noticed?
        watcher.Clear();
        var bad = new TextBlock();
        bad.SetBinding(TextBlock.TextProperty, new Binding("ThereIsNoSuchProperty") { Source = new { Real = 1 } });
        var badHost = new UserControl { Content = bad };
        Layout(badHost, 900);
        Check("a mistyped binding path is caught rather than rendering blank",
            watcher.Lines.Any(l => l.Contains("ThereIsNoSuchProperty")),
            watcher.Lines.Count == 0 ? "nothing was reported" : string.Join(" | ", watcher.Lines.Take(2)));

        Section("the palette", CheckPalette);
        Section("the grid", () => CheckGrid(watcher));
        Section("the toolbar", () => CheckToolbar(watcher));
        Section("the forms", () => CheckForms(watcher));
        Section("what a procedure said", () => CheckResultView(watcher));
        Section("the alert colours", CheckAlertColours);
        return Finish();
    }

    private static void CheckToolbar(BindingWatcher watcher)
    {
        // a real rule, not one invented for the test: a pre-paid package that has been invoiced and
        // partly used, so two of its five actions do not apply and both have something to say.
        var set = ActionRules.Prepaid("PP-14", "Open", invoice: "MDS-INV-2026-0009", used: 4m);
        var ran = new List<string>();
        var handlers = set.Actions.Where(a => a.Enabled)
            .ToDictionary(a => a.Id, a => (Action)(() => ran.Add(a.Id)));

        watcher.Clear();
        var toolbar = new Toolbar();
        var host = new UserControl { Content = toolbar };
        Step("the toolbar takes an action set and lays out", () => { toolbar.Show(set, handlers); Layout(host, 1100, 120); return 0; });
        Check("no binding warnings from the toolbar", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));

        var buttons = toolbar.Buttons;
        Check("every action is on show, not only the ones that apply",
            buttons.Count == set.Actions.Count && buttons.Count > set.Available.Count,
            $"{buttons.Count} buttons for {set.Actions.Count} actions, {set.Available.Count} of them available");
        Check("the labels are the action labels",
            buttons.Select(b => b.Content as string).SequenceEqual(set.Actions.Select(a => a.Label)),
            string.Join(" | ", buttons.Select(b => b.Content)));
        Check("each button is tagged with its action id, so nothing is dispatched by label",
            buttons.Select(b => b.Tag as string).SequenceEqual(set.Actions.Select(a => a.Id)),
            string.Join(" | ", buttons.Select(b => b.Tag)));

        foreach (var action in set.Actions)
        {
            var button = buttons.First(b => (b.Tag as string) == action.Id);
            Check($"toolbar: {action.Id} is {(action.Enabled ? "offered" : "greyed")}",
                button.IsEnabled == action.Enabled);
            if (action.Enabled) continue;
            Check($"toolbar: {action.Id} says why not",
                (button.ToolTip as string) == action.DisabledReason, button.ToolTip as string ?? "(nothing)");
            Check($"toolbar: {action.Id} shows that reason even though it is greyed",
                ToolTipService.GetShowOnDisabled(button));
        }

        var invoice = buttons.First(b => (b.Tag as string) == "prepaid-invoice");
        Check("and the reason names the invoice it is already on",
            (invoice.ToolTip as string)?.Contains("MDS-INV-2026-0009") == true, invoice.ToolTip as string ?? "");
        var cancel = buttons.First(b => (b.Tag as string) == "prepaid-cancel");
        Check("and the one about used hours says how many",
            (cancel.ToolTip as string)?.Contains("4") == true, cancel.ToolTip as string ?? "");

        var usage = buttons.First(b => (b.Tag as string) == "prepaid-usage");
        usage.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        Check("pressing a button runs its action", ran.SequenceEqual(new[] { "prepaid-usage" }), string.Join(", ", ran));

        ExpectError("an action offered with nothing to run is refused when the toolbar is built",
            () => new Toolbar().Show(set, new Dictionary<string, Action>()), "nothing to run");

        // the window's half of the error policy: a failure reports rather than escaping
        var reported = new List<string>();
        Report.Sink = (title, message) => reported.Add($"{title}: {message}");
        try
        {
            var angry = new Toolbar();
            angry.Show(ActionRules.Ticket("MW-00001"),
                ActionRules.Ticket("MW-00001").Actions.ToDictionary(a => a.Id,
                    a => (Action)(() => throw new FormatException("Minutes: 'half an hour' is not a whole number."))));
            angry.Buttons[0].RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Check("an action that fails is reported, not thrown out of the window",
                reported.Count == 1 && reported[0].Contains("half an hour"), string.Join(" | ", reported));
            Check("and a message about what was typed is shown as it was written",
                reported[0].EndsWith("Minutes: 'half an hour' is not a whole number."), reported[0]);
        }
        finally { Report.Sink = null; }
    }

    /// <summary>
    ///   Every real form in the app, laid out in the window as well as in the terminal. Called from
    ///   the read-only suite, which is the one with a database to build the specs from; the synthetic
    ///   form in <see cref="CheckForms"/> covers the renderer's rules, and this covers the 41 forms
    ///   that actually exist, with their real defaults, choices and help.
    /// </summary>
    public static void RealFormsLayOut(IEnumerable<FormSpec> specs)
    {
        var watcher = BindingWatcher.Install();
        foreach (var spec in specs)
        {
            watcher.Clear();
            var form = Step($"form '{spec.Title}' lays out in the window", () =>
            {
                var built = new MhForm(spec);
                Layout(built, 900);
                return built;
            });
            if (form == null) continue;
            Check($"form '{spec.Title}': no binding warnings",
                watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));
            var shown = Texts(form);
            var unlabelled = spec.Fields.Where(f => !shown.Contains(f.Label)).Select(f => f.Label).ToList();
            Check($"form '{spec.Title}': every field is labelled",
                unlabelled.Count == 0, string.Join(", ", unlabelled));
        }
    }

    private static void CheckForms(BindingWatcher watcher)
    {
        // every kind of field there is, so the renderer is covered without needing a database
        var spec = new FormSpec
        {
            Title = "Everything",
            Intro = "One of each, to lay out.",
            Fields = new List<Field>
            {
                Field.Text("name", "Client name", required: true, help: "as it should appear on the invoice"),
                Field.Memo("notes", "Notes"),
                Field.Date("from", "Covered from", required: true),
                Field.DateTime("at", "Raised at"),
                Field.Int("minutes", "Minutes", required: true),
                Field.Decimal("rate", "Rate"),
                Field.Bool("urgent", "Urgent", def: true),
                Field.Choice("severity", "Severity", new[] { "Low", "Normal", "High" }, def: "Normal")
            },
            Submit = v => { var r = new ProcResult(); r.Messages.Add($"{v["name"]} / {v.Int("minutes")} / {v["severity"]}"); return r; }
        };

        watcher.Clear();
        var form = new MhForm(spec);
        Step("a form with one of every field lays out", () => { Layout(form, 900); return 0; });
        Check("no binding warnings from the form", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));

        var texts = Texts(form);
        Check("the intro is shown", texts.Contains("One of each, to lay out."), string.Join(" | ", texts.Take(3)));
        foreach (var field in spec.Fields)
            Check($"form: {field.Name} is labelled", texts.Any(t => t.StartsWith(field.Label)), field.Label);
        // the star is its own TextBlock next to the label, so "labelled, then starred" in tree order
        static bool Starred(DependencyObject root, string label)
        {
            var blocks = Descendants<TextBlock>(root).Select(TextOf).ToList();
            var at = blocks.IndexOf(label);
            return at >= 0 && at + 1 < blocks.Count && blocks[at + 1].Trim() == "*";
        }
        Check("a required field is marked with a star", Starred(form, "Client name"),
            string.Join(" | ", texts.Where(t => t.Contains('*'))));
        Check("and one that is not required is not", !Starred(form, "Notes"));
        Check("the star says what it means, for anyone who has not met the convention",
            Descendants<TextBlock>(form).Any(t => TextOf(t).Trim() == "*" && (t.ToolTip as string) == "Required"));
        Check("the help sits with its field rather than being dropped for want of room",
            texts.Contains("as it should appear on the invoice"));
        Check("a date says what shape it wants", texts.Contains("yyyy-mm-dd"));

        Check("a choice is a drop-down, already on its default",
            Descendants<ComboBox>(form).SingleOrDefault() is { SelectedItem: "Normal" });
        Check("a yes/no is a tick box, already set",
            Descendants<CheckBox>(form).SingleOrDefault() is { IsChecked: true });
        Check("the memo takes more than one line",
            Descendants<TextBox>(form).Any(t => t.AcceptsReturn && t.TextWrapping == TextWrapping.Wrap));

        // filling it in and submitting, with nothing on screen but the control
        var boxes = Descendants<TextBox>(form).ToList();
        boxes[0].Text = "Contoso Ltd";          // name
        boxes[2].Text = "2026-03-01";           // from
        boxes[3].Text = "2026-03-01 09:30";     // at
        boxes[4].Text = "90";                   // minutes
        var values = form.Values();
        Check("what was typed is read back off the controls",
            values["name"] == "Contoso Ltd" && values["minutes"] == "90" && values["severity"] == "Normal"
            && values["urgent"] == "1", $"{values["name"]} / {values["minutes"]} / {values["severity"]} / {values["urgent"]}");
        var result = form.Submit();
        Check("submitting runs the form's own Submit",
            result?.Messages.FirstOrDefault() == "Contoso Ltd / 90 / Normal", result?.Messages.FirstOrDefault() ?? "(nothing)");
        Check("and nothing is complained about", form.Problem == null, form.Problem ?? "");

        // and the failure path: the form stays up with the reason on it
        boxes[4].Text = "half an hour";
        Check("a number that is not one is refused", form.Submit() == null);
        Check("the reason is put on the form, which stays open",
            form.Problem?.Contains("not a whole number") == true, form.Problem ?? "(nothing shown)");
        Check("and it names the field by its label", form.Problem?.StartsWith("Minutes") == true, form.Problem ?? "");

        boxes[4].Text = "90";
        boxes[0].Text = "   ";
        Check("a required field left blank is refused", form.Submit() == null);
        Check("and says which one", form.Problem?.Contains("Client name") == true, form.Problem ?? "");
    }

    /// <summary>
    ///   The result view: the PRINT messages a procedure wrote, then its result sets. The messages
    ///   are half of what the app does - every procedure in MolehillAdmin reports what it did with
    ///   PRINT - so a screen that shows only rows is a screen that has thrown that away.
    /// </summary>
    private static void CheckResultView(BindingWatcher watcher)
    {
        var wide = new DataTable();
        wide.Columns.Add("Ref", typeof(string));
        wide.Columns.Add("Client", typeof(string));
        wide.Columns.Add("Fee", typeof(decimal));
        wide.Rows.Add("MW-A-0003", "Acme Ltd", 350m);
        wide.Rows.Add("MW-A-0007", "Zeta Ltd", 180m);

        var result = new ProcResult();
        result.Messages.Add("Invoice MDS-INV-2026-0009 created, 3 lines.");
        result.Messages.Add("Nothing else to bill.");
        result.Tables.Add(wide);

        watcher.Clear();
        var view = new ResultView();
        var host = new UserControl { Content = view };
        Step("a result lays out with no window", () => { view.Show(result); Layout(host, 1000); return 0; });
        Check("no binding warnings from the result view", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));
        Check("what the procedure said is shown, in the order it said it",
            view.Messages.SequenceEqual(result.Messages), string.Join(" | ", view.Messages));
        Check("and it is on the screen, not only in a list",
            Texts(host).Contains("Invoice MDS-INV-2026-0009 created, 3 lines."), string.Join(" | ", Texts(host).Take(3)));
        Check("the result set is a grid", view.Grids.Count == 1 && view.Grids[0].Table == wide);

        // the same rule the terminal prints by, not a second opinion written in WPF
        var one = new DataTable();
        foreach (var c in new[] { "Priority", "Area", "Client", "Item", "Detail", "DueBy" }) one.Columns.Add(c, typeof(string));
        one.Rows.Add("High", "Onboarding", "Acme Ltd", "Monitoring not set up", "No agent on SQL01", "31 Dec 2026");
        var single = new ProcResult();
        single.Tables.Add(one);
        var narrow = new ResultView();
        var narrowHost = new UserControl { Content = narrow };
        Step("one row of many columns lays out", () => { narrow.Show(single); Layout(narrowHost, 1000); return 0; });
        Check("one row with more columns than fit across is shown as lines, not as a grid",
            narrow.Grids.Count == 0 && Output.ReadsBetterVertical(one));
        Check("and every column of it is on the screen, named",
            new[] { "Priority", "Detail", "No agent on SQL01" }.All(t => Texts(narrowHost).Contains(t)),
            string.Join(" | ", Texts(narrowHost)));

        var empty = new ProcResult();
        empty.Tables.Add(new DataTable("nothing"));
        var emptyView = new ResultView();
        var emptyHost = new UserControl { Content = emptyView };
        Step("an empty result set lays out", () => { emptyView.Show(empty); Layout(emptyHost, 800); return 0; });
        Check("a result set with no rows says so rather than showing an empty box",
            Texts(emptyHost).Contains("(no rows)"), string.Join(" | ", Texts(emptyHost)));

        var silent = new ResultView();
        var silentHost = new UserControl { Content = silent };
        Step("a procedure that said nothing at all lays out", () => { silent.Show(new ProcResult()); Layout(silentHost, 800); return 0; });
        Check("and a procedure that said nothing is reported as done, not as a blank screen",
            Texts(silentHost).Any(t => t.StartsWith("Done.")), string.Join(" | ", Texts(silentHost)));

        var alert = ResultView.Of(one.Rows[0]);
        var alertHost = new UserControl { Content = alert };
        Step("a single row opens on its own", () => { Layout(alertHost, 800); return 0; });
        Check("an alert opened on its own shows its own columns",
            Texts(alertHost).Contains("No agent on SQL01"), string.Join(" | ", Texts(alertHost)));
    }

    /// <summary>
    ///   The alert colours, held to the dashboard HTML the clients actually receive. The mapping
    ///   itself is checked without a screen in --selftest-config; what is checked here is that the
    ///   keys resolve to real brushes, and that they are still the same colours - and the same
    ///   boldness - as td.high / td.normal / td.low in the install script.
    /// </summary>
    private static void CheckAlertColours()
    {
        foreach (var priority in new[] { "High", "Normal", "Low" })
        {
            var colour = Today.AlertColour(priority);
            Check($"an alert priority has a colour: {priority}", colour != null);
            if (colour == null) continue;
            Step($"and it resolves to brushes: {priority}", () =>
                (AppResources.Resource<SolidColorBrush>(colour.Value.Background),
                 AppResources.Resource<SolidColorBrush>(colour.Value.Ink)));
        }

        var root = RepositoryRoot();
        if (root == null)
        {
            Console.WriteLine("SKIP  alert colours match the dashboard e-mail (not running from the repository)");
            return;
        }
        var sql = File.ReadAllText(Path.Combine(root, "Admin", "MolehillAdmin_Install.sql"));
        foreach (var (priority, cssClass) in new[] { ("High", "high"), ("Normal", "normal"), ("Low", "low") })
        {
            var rule = Regex.Match(sql, @"td\." + cssClass + @"\{([^}]*)\}");
            Check($"the dashboard HTML still has a td.{cssClass} rule", rule.Success);
            var colour = Today.AlertColour(priority);
            if (!rule.Success || colour == null) continue;
            var hex = Palette.Colours.First(c => c.Key == colour.Value.Background).Hex;
            Check($"a {cssClass} alert is still the {hex} the dashboard e-mail uses",
                rule.Groups[1].Value.Contains(hex, StringComparison.OrdinalIgnoreCase), rule.Groups[1].Value);
            Check($"and a {cssClass} alert is {(colour.Value.Bold ? "bold in both" : "bold in neither")}",
                rule.Groups[1].Value.Contains("font-weight:600") == colour.Value.Bold, rule.Groups[1].Value);
        }
        Check("the white on a high alert is the white the dashboard puts on it",
            Regex.Match(sql, @"td\.high\{([^}]*)\}").Groups[1].Value.Contains("color:#fff")
            && Palette.StatusRedInk.Equals("#FFFFFF", StringComparison.OrdinalIgnoreCase));
    }

    private static void CheckPalette()
    {
        foreach (var (key, hex) in Palette.Colours)
        {
            var brush = Step($"palette: {key}", () => AppResources.Resource<SolidColorBrush>(key));
            Check($"palette: {key} is {hex}",
                brush != null && brush.Color.ToString(System.Globalization.CultureInfo.InvariantCulture)
                    .Equals("#FF" + hex.TrimStart('#'), StringComparison.OrdinalIgnoreCase),
                brush?.Color.ToString() ?? "(missing)");
            Check($"palette: {key} is also there as a Color",
                AppResources.Ensure().TryFindResource(key + "Colour") is Color);
        }
        foreach (var (key, families) in Palette.Fonts)
        {
            var font = Step($"palette: {key}", () => AppResources.Resource<FontFamily>(key));
            Check($"palette: {key} keeps its fallbacks", font?.Source == families, font?.Source ?? "(missing)");
        }
        Check("asking for a resource that is not there says which one",
            Step("", () => { try { AppResources.Resource<SolidColorBrush>("Chartreuse"); return ""; } catch (Exception ex) { return ex.Message; } })
                ?.Contains("Chartreuse") == true);

        // the colours are not this app's to invent: they are what clients already receive. When the
        // repository is to hand, check they still agree with it - the drift would otherwise be
        // invisible, because nothing here would ever look wrong on its own.
        var root = RepositoryRoot();
        if (root == null)
        {
            Console.WriteLine("SKIP  palette matches the site and report styles (not running from the repository)");
            return;
        }
        var css = File.ReadAllText(Path.Combine(root, "Site", "assets", "molehill.css"));
        var report = File.ReadAllText(Path.Combine(root, "Client", "Export-WeeklyReports.ps1"));
        void Shared(string what, string hex, string source, string text) =>
            Check($"palette: {what} {hex} is still what {source} uses",
                text.Contains(hex, StringComparison.OrdinalIgnoreCase));

        Shared("the ink", Palette.Ink, "the site", css);
        Shared("the accent", Palette.Accent, "the site", css);
        Shared("the surface", Palette.Surface, "the site", css);
        Shared("the line", Palette.Line, "the site", css);
        Shared("the tint", Palette.Tint, "the site", css);
        Shared("the muted grey", Palette.Muted, "the site", css);
        Shared("red", Palette.StatusRed, "the weekly report", report);
        Shared("amber", Palette.StatusAmber, "the weekly report", report);
        Shared("green", Palette.StatusGreen, "the weekly report", report);
        Shared("info", Palette.StatusInfo, "the weekly report", report);
        Shared("the note grey", Palette.Note, "the weekly report", report);
        Shared("the link blue", Palette.Link, "the weekly report", report);
        Check("palette: Krungthep still leads the heading font, as on the invoices and the site",
            css.Contains("Krungthep") && Palette.TitleFontFamily.StartsWith("Krungthep"));
    }

    /// <summary>The repository, when the app is running from a build inside it. Null from a published exe.</summary>
    private static string? RepositoryRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir != null)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "Site", "assets"))) return dir.FullName;
            dir = dir.Parent;
        }
        return null;
    }

    private static void CheckGrid(BindingWatcher watcher)
    {
        static DataTable Table()
        {
            var t = new DataTable();
            t.Columns.Add("Ref", typeof(string));
            t.Columns.Add("Client", typeof(string));
            t.Columns.Add("Fee", typeof(decimal));
            t.Columns.Add("Started", typeof(DateTime));
            t.Columns.Add("Description", typeof(string));
            t.Columns.Add("_EngagementType", typeof(string));
            return t;
        }
        var table = Table();
        table.Rows.Add("MW-0001", "Contoso Ltd", 120m, new DateTime(2026, 3, 1), "A long description", "Watch");
        table.Rows.Add("MW-0002", "Fabrikam", 7.5m, new DateTime(2026, 3, 2, 9, 30, 0), "Another", "Consultancy");

        watcher.Clear();
        var grid = new MhGrid();
        var host = new UserControl { Content = grid };
        Step("the grid takes a table and lays out", () => { grid.Bind(table); Layout(host, 1100); return 0; });
        Check("no binding warnings from the grid", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));

        var headers = grid.Columns.Select(c => c.Header?.ToString() ?? "").ToList();
        Check("the underscore column is not shown",
            !headers.Contains("_EngagementType") && headers.Count == 5, string.Join(", ", headers));

        var cells = Texts(host);
        Check("money shows pence even when the figure is round",
            cells.Contains("120.00") && cells.Contains("7.50"), string.Join(" | ", cells));
        Check("a date with no time shows as a date",
            cells.Contains("01 Mar 2026"), string.Join(" | ", cells));
        Check("a date with a time shows the time too",
            cells.Contains("02 Mar 2026 09:30"), string.Join(" | ", cells));

        var fee = grid.Columns.First(c => (c.Header as string) == "Fee");
        Check("numbers are to the right", fee.CellStyle != null
            && fee.CellStyle.Setters.OfType<Setter>().Any(s => Equals(s.Value, HorizontalAlignment.Right)));
        var description = grid.Columns.First(c => (c.Header as string) == "Description");
        Check("the long free-text columns are capped", description.MaxWidth < double.PositiveInfinity,
            description.MaxWidth.ToString(System.Globalization.CultureInfo.InvariantCulture));

        grid.SelectedIndex = 1;
        Check("the selected row can be read back", grid.Selected("Ref") == "MW-0002", grid.Selected("Ref") ?? "(none)");
        Check("including a column carried only for the code",
            grid.SelectedRow()?["_EngagementType"] as string == "Consultancy");

        // the improvement the plan asked for: a row arriving above you must not move you
        var again = Table();
        again.Rows.Add("MW-0000", "Earlier Ltd", 50m, new DateTime(2026, 2, 1), "Inserted above", "Watch");
        foreach (DataRow r in table.Rows) again.Rows.Add(r.ItemArray);
        Step("rebinding with a row inserted above", () => { grid.Bind(again); Layout(host, 1100); return 0; });
        Check("the selection stays on the same row, not the same row number",
            grid.Selected("Ref") == "MW-0002" && grid.SelectedIndex == 2,
            $"{grid.Selected("Ref")} at {grid.SelectedIndex}");
    }
}
