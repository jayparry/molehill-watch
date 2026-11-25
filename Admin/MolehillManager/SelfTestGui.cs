using System.Data;
using System.Diagnostics;
using System.Globalization;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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
    /// <summary>
    ///   Where to write a picture of each view, or null. Set by <c>--selftest-gui --shot FOLDER</c>.
    ///
    ///   The suite cannot assert on pixels - that was never the plan - but the views are already
    ///   built and arranged at a known size, so putting them on disk costs a dozen lines and is the
    ///   only way to look at the window without a machine to run it on. It is also how a layout that
    ///   is technically correct and visually wrong gets noticed, which no amount of reading
    ///   TextBlocks out of a visual tree will do.
    /// </summary>
    public static string? ShotFolder;

    private static void Shot(FrameworkElement element, string name)
    {
        if (ShotFolder == null) return;
        try
        {
            Directory.CreateDirectory(ShotFolder);
            var width = (int)Math.Ceiling(element.ActualWidth);
            var height = (int)Math.Ceiling(element.ActualHeight);
            if (width <= 0 || height <= 0) { Console.WriteLine($"SKIP  picture of {name} (it arranged to nothing)"); return; }
            var bitmap = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
            bitmap.Render(element);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            var path = Path.Combine(ShotFolder, name + ".png");
            using var file = File.Create(path);
            encoder.Save(file);
            Console.WriteLine($"      picture: {path} ({width} x {height})");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"SKIP  picture of {name}: {AdminDb.Explain(ex)}");
        }
    }

    /// <summary>
    ///   Text that is capped in width but still set to stretch. WPF centres an element whose
    ///   alignment is Stretch and whose width is constrained, so a paragraph written with a MaxWidth
    ///   and nothing else drifts into the middle of the pane - which reads as a mistake rather than
    ///   a decision, and is invisible to every assertion about what the text says.
    ///
    ///   Found twice by looking at pictures, in two different views, before it was worth a check.
    /// </summary>
    /// <summary>
    ///   Presses the button with these words on it. Calling the method behind a button is not the
    ///   same test as pressing it: a mutation pass found three handlers wired to the wrong thing,
    ///   all of which the direct calls sailed straight past.
    /// </summary>
    private static bool Press(FrameworkElement root, string label)
    {
        var button = Descendants<Button>(root).FirstOrDefault(b => (b.Content as string) == label);
        if (button == null) return false;
        button.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
        return true;
    }

    private static void NothingAdrift(FrameworkElement root, string what)
    {
        var adrift = Descendants<TextBlock>(root)
            .Where(b => !double.IsInfinity(b.MaxWidth) && b.HorizontalAlignment == HorizontalAlignment.Stretch)
            .Select(b => $"\"{TextOf(b).Split('\n')[0]}\" (MaxWidth {b.MaxWidth:0})")
            .ToList();
        Check($"{what}: no text is capped in width and left to centre itself",
            adrift.Count == 0, string.Join(" | ", adrift.Take(3)));
    }

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
        Section("the shell", () => CheckShell(watcher));
        Section("the settings screen", () => CheckSettings(watcher));
        Section("the password prompt", () => CheckSecret(watcher));
        Section("the Today page", () => CheckToday(watcher));
        Section("the client list", () => CheckClients(watcher));
        Section("what each node opens", CheckWhatOpens);
        Section("the detail rules", CheckDetailRules);
        Section("the agreement page", () => CheckAgreementPage(watcher));
        Section("the engagement page", () => CheckEngagementPage(watcher));
        Section("the tickets page", () => CheckTicketsPage(watcher));
        Section("the billing page", () => CheckBillingPage(watcher));
        Section("how big the window opens", CheckWindowSize);
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
        Shot(host, "4-toolbar");

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
        NothingAdrift(host, "the result view");

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

    /// <summary>A tree like the one a database gives, for the shell and the client list.</summary>
    private static DataTable SomeWork()
    {
        var t = new DataTable();
        foreach (var c in new[] { "Ref", "Client", "Type", "What", "Status", "Rate", "Unbilled", "_EngagementType" })
            t.Columns.Add(c, typeof(string));
        t.Columns.Add("OpenTickets", typeof(int));
        t.Columns.Add("OnboardingLeft", typeof(int));
        t.Rows.Add("MW-A-0003", "Acme Ltd", "Molehill Watch", "4 instance(s) monitored", "Current",
            "£350/month", null, "Monitoring", 2, 0);
        t.Rows.Add("C-0012", "Acme Ltd", "Consultancy", "Upgrade to SQL Server 2022", "Active",
            "£900/day", "£1,800 (2.00 d)", "Consultancy", 0, 0);
        t.Rows.Add("MW-A-0007", "Zeta Ltd", "Molehill Watch", "2 instance(s) monitored", "Current",
            "£180/month", null, "Monitoring", 0, 3);
        // Type is a display string from a CASE; _EngagementType is the value itself. They agree
        // today, so a row where they do not is the only way to check which one is being read.
        t.Rows.Add("C-0033", "Zeta Ltd", "Molehill Watch", "Health check", "Active",
            "£700/day", null, "Consultancy", 0, 0);
        // A consultancy project called "Molehill Watch" - rolling the product out, say - which is
        // the other way the same confusion bites: here it is the tree's own label that reads as a
        // support agreement while the work is nothing of the sort. Deciding from the label rather
        // than the raw type would send this one to the wrong page.
        t.Rows.Add("C-0041", "Zeta Ltd", "Consultancy", "Molehill Watch", "Active",
            "£400/day", null, "Consultancy", 0, 0);
        return t;
    }

    /// <summary>
    ///   The shell, driven with no database at all: pages arrive through a factory, so what can be
    ///   checked here is everything that is not a page - the tree, the breadcrumb, which page was
    ///   asked for, and that the toolbar is offered again when a page says its selection moved.
    /// </summary>
    private static void CheckShell(BindingWatcher watcher)
    {
        var asked = new List<NavKind>();
        var pages = new Dictionary<NavKind, PlainPage>();
        IShellPage Open(NavNode node)
        {
            asked.Add(node.Kind);
            var page = new PlainPage(node.Label, new TextBlock { Text = $"page: {node.Label}" });
            pages[node.Kind] = page;
            return page;
        }

        watcher.Clear();
        var shell = new Shell(Open);
        var tree = Nav.Build(SomeWork());
        Step("the shell lays out with no window", () => { shell.Load(tree); Layout(shell, 1200, 800); return 0; });
        Check("no binding warnings from the shell", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));

        Check("it opens on Today rather than on nothing",
            shell.Here?.Kind == NavKind.Today && asked.Contains(NavKind.Today), shell.Here?.Label ?? "(nowhere)");
        Check("and the breadcrumb says so", shell.Breadcrumb == "Today", shell.Breadcrumb);
        Check("every place in the tree is on the screen",
            new[] { "Today", "Clients", "Tickets", "Billing", "Settings" }.All(t => Texts(shell).Contains(t)),
            string.Join(" | ", Texts(shell).Take(8)));
        Check("the clients are in the tree too, under Clients",
            Texts(shell).Contains("Acme Ltd") && Texts(shell).Contains("Zeta Ltd"),
            string.Join(" | ", Texts(shell)));
        Shot(shell, "1-shell");
        NothingAdrift(shell, "the shell");

        shell.Go(NavKind.Engagement, "C-0012");
        Check("the tree points at what was opened, rather than at where you were",
            (shell.Highlighted as NavNode)?.Key == "C-0012",
            (shell.Highlighted as NavNode)?.Label ?? "(nothing)");
        Check("opening an engagement puts the way to it in the breadcrumb",
            shell.Breadcrumb == "Clients › Acme Ltd › Upgrade to SQL Server 2022", shell.Breadcrumb);
        Check("and its page is in the content pane",
            shell.Page is TextBlock { Text: "page: Upgrade to SQL Server 2022" },
            (shell.Page as TextBlock)?.Text ?? shell.Page?.GetType().Name ?? "(nothing)");

        // a refresh must not move you, which is the same rule the grid follows for its rows
        var sameAgain = Nav.Build(SomeWork());
        shell.Load(sameAgain);
        Check("a refresh leaves you where you were",
            shell.Here?.Key == "C-0012", shell.Here?.Label ?? "(nowhere)");

        var gone = SomeWork();
        gone.Rows.RemoveAt(1);                       // the engagement that was open is no longer there
        shell.Load(Nav.Build(gone));
        Check("and when what you were looking at has gone, it falls back to Today",
            shell.Here?.Kind == NavKind.Today, shell.Here?.Label ?? "(nowhere)");

        // the point of the exercise: the toolbar follows the page's selection
        var offers = 0;
        var moving = new MovingPage();
        var following = new Shell(_ => moving);
        following.Load(Nav.Build(null));
        moving.Offer(ActionRules.Ticket("MW-00001"), id => offers++);
        Check("a page saying its selection moved gets its actions offered again",
            following.Actions.Buttons.Count == ActionRules.Ticket("MW-00001").Actions.Count,
            $"{following.Actions.Buttons.Count} buttons");
        moving.Offer(ActionRules.Ticket(null), id => offers++);
        Check("and offered the new ones, not the ones from before",
            following.Actions.Buttons.Count == ActionRules.Ticket(null).Actions.Count,
            $"{following.Actions.Buttons.Count} buttons");
    }

    /// <summary>A page that changes its mind, to prove the shell asks again when it does.</summary>
    private sealed class MovingPage : IShellPage
    {
        private MhActionSet _set = new("Nothing", Array.Empty<MhAction>());
        private Action<string> _run = _ => { };

        public UIElement Content { get; } = new TextBlock { Text = "moving" };
        public MhActionSet Actions => _set;
        public IReadOnlyDictionary<string, Action> Handlers =>
            _set.Actions.ToDictionary(a => a.Id, a => (Action)(() => _run(a.Id)));
        public event Action? Changed;

        public void Offer(MhActionSet set, Action<string> run)
        {
            _set = set;
            _run = run;
            Changed?.Invoke();
        }
    }

    private static void CheckToday(BindingWatcher watcher)
    {
        var alerts = new DataTable();
        foreach (var c in new[] { "Priority", "Area", "Client", "Item", "Detail", "DueBy" }) alerts.Columns.Add(c, typeof(string));
        alerts.Rows.Add("High", "Onboarding", "Acme Ltd", "Monitoring not set up", "No agent on SQL01", "31 Dec 2026");
        alerts.Rows.Add("Low", "Billing", "Zeta Ltd", "Draft invoice waiting", "MDS-INV-2026-0009", "");
        var tickets = new DataTable();
        tickets.Columns.Add("Ticket", typeof(string));
        tickets.Rows.Add("MW-00001");
        var money = new DataTable();
        money.Columns.Add("MonthlyRecurringRevenue", typeof(decimal));
        money.Rows.Add(4250m);
        var dashboard = new DashboardView(alerts, tickets, new DataTable(), new DataTable(), money.Rows[0]);

        var shown = new List<string>();
        var went = new List<string>();
        var saved = 0;

        watcher.Clear();
        TodayPage? page = null;
        Step("the Today page lays out with no window", () =>
        {
            page = new TodayPage(dashboard, client => client == "Acme Ltd" ? "MW-A-0003" : null,
                (title, _) => shown.Add(title), (kind, key) => went.Add($"{kind}:{key}"), () => saved++);
            Layout(page, 1200, 800);
            return 0;
        });
        if (page == null) return;
        Check("no binding warnings from the Today page", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));

        Check("the alerts are on it", page.Alerts.Table == alerts);
        Check("and so is what the alert says",
            Texts(page).Contains("No agent on SQL01"), string.Join(" | ", Texts(page).Take(6)));
        Check("the money is shown as figures with their words",
            page.Tiles.Any(t => t.Label == "Monthly recurring revenue" && t.Value == "£4,250.00"),
            string.Join(", ", page.Tiles.Select(t => $"{t.Label}={t.Value}")));
        Check("and the open-ticket count with them",
            Texts(page).Contains("Open tickets") && Texts(page).Contains("1"),
            string.Join(" | ", Texts(page)));

        // the priority column is coloured by the rule, not by a style written out in the view
        var priority = page.Alerts.Columns.FirstOrDefault(c => (c.Header as string) == "Priority");
        Check("the priority column is given a look of its own", priority?.CellStyle != null);
        // what the style actually sets, rather than only what the converter would answer: a style
        // missing its Foreground setter leaves a high alert as dark ink on that red, unreadable,
        // and the converter goes on giving the right answer to nobody.
        var parts = priority?.CellStyle?.Setters.OfType<Setter>()
            .Select(s => $"{s.Property.Name}:{(s.Value as Binding)?.ConverterParameter}").ToList() ?? new List<string>();
        foreach (var wanted in new[] { "Background:Background", "Foreground:Ink", "FontWeight:Bold" })
            Check($"and that look sets its {wanted.Split(':')[0].ToLowerInvariant()} from the rule",
                parts.Contains(wanted), string.Join(" | ", parts));
        Check("a high priority comes out as the dashboard's red",
            ReferenceEquals(AlertLook.Instance.Convert("High", typeof(Brush), "Background", CultureInfo.InvariantCulture),
                AppResources.Resource<Brush>("StatusRed")));
        Check("and its text white, so it can be read at all",
            ReferenceEquals(AlertLook.Instance.Convert("High", typeof(Brush), "Ink", CultureInfo.InvariantCulture),
                AppResources.Resource<Brush>("StatusRedInk")));
        Check("a priority nobody has heard of leaves the cell alone",
            AlertLook.Instance.Convert("Critical", typeof(Brush), "Background", CultureInfo.InvariantCulture) is SolidColorBrush { Color.A: 0 });

        // binding a list puts you on its first row - RowKey.Reselect clamps into range - which is
        // what a to-do list wants: the first alert's actions are offered without a click.
        Check("the first alert is picked, so there is something to do straight away",
            page.Alerts.SelectedIndex == 0 && page.Actions.ById("alert-show")?.Enabled == true,
            page.Actions.ById("alert-show")?.DisabledReason ?? "(enabled)");
        Check("saving the dashboard does not need a selection at all",
            page.Actions.ById("dashboard-html")?.Enabled == true);

        var noAlerts = new DashboardView(alerts.Clone(), tickets, new DataTable(), new DataTable(), money.Rows[0]);
        var quiet = new TodayPage(noAlerts, _ => null, (_, _) => { }, (_, _) => { }, () => { });
        Layout(quiet, 1000);
        Check("with nothing to do, the alert actions say to pick something rather than vanishing",
            quiet.Actions.ById("alert-show")?.DisabledReason == "Pick an alert first.",
            quiet.Actions.ById("alert-show")?.DisabledReason ?? "(enabled)");

        Check("the alert that is picked is about a client with an agreement, so opening it is offered",
            page.Actions.ById("alert-agreement")?.Enabled == true
            && page.Actions.ById("alert-agreement")?.Label.Contains("MW-A-0003") == true,
            page.Actions.ById("alert-agreement")?.Label ?? "(none)");
        page.Handlers["alert-show"]();
        Check("showing the whole alert puts it up", shown.SequenceEqual(new[] { "Alert" }), string.Join(", ", shown));
        page.Handlers["alert-agreement"]();
        Check("and opening the client goes to the client, not to a reference the tree does not use",
            went.SequenceEqual(new[] { "Client:Acme Ltd" }), string.Join(", ", went));
        page.Handlers["dashboard-html"]();
        Check("saving the dashboard runs the save", saved == 1, saved.ToString());
        Layout(page, 1200, 800);
        NothingAdrift(page, "the Today page");
        Shot(page, "2-today");

        page.Alerts.SelectedIndex = 1;
        Check("an alert about a client with no agreement says that, rather than offering nothing",
            page.Actions.ById("alert-agreement")?.Enabled == false
            && page.Actions.ById("alert-agreement")?.DisabledReason?.Contains("Zeta Ltd") == true,
            page.Actions.ById("alert-agreement")?.DisabledReason ?? "(enabled)");
    }

    private static void CheckClients(BindingWatcher watcher)
    {
        var work = SomeWork();
        var reloads = new List<bool>();
        var went = new List<string>();
        var ran = new List<string>();
        var handlers = new Dictionary<string, Action>
        {
            ["client-new"] = () => ran.Add("client-new"),
            ["agreement-new"] = () => ran.Add("agreement-new"),
            ["engagement-new"] = () => ran.Add("engagement-new")
        };

        watcher.Clear();
        ClientsPage? page = null;
        Step("the client list lays out with no window", () =>
        {
            page = new ClientsPage(work, false, ended => reloads.Add(ended),
                (kind, key) => went.Add($"{kind}:{key}"), handlers);
            Layout(page, 1200, 800);
            return 0;
        });
        if (page == null) return;
        Check("no binding warnings from the client list", watcher.Lines.Count == 0, string.Join(" | ", watcher.Lines.Take(2)));

        Check("every piece of work is on it", page.Work.Table == work && work.Rows.Count == 5,
            $"{work.Rows.Count} rows");
        var empty = new ClientsPage(work.Clone(), false, _ => { }, (_, _) => { }, handlers);
        Layout(empty, 1000);
        Check("an empty list says so, and says where to start",
            empty.Summary.Contains("No work to show") && empty.Summary.Contains("New client"), empty.Summary);
        Check("and offers exactly the three ways to start something new",
            empty.Actions.Actions.Count == 3 && empty.Actions.Available.Count == 3,
            string.Join(", ", empty.Actions.Actions.Select(a => a.Id)));
        Check("a list with work in it starts on its first row",
            page.Work.SelectedIndex == 0 && page.Summary.Contains("open ticket(s)"), page.Summary);

        page.Work.Select("Ref", "MW-A-0003");
        Check("picking a support agreement offers the support actions",
            page.Actions.ById("agreement-open") != null && page.Actions.ById("ticket-new") != null,
            string.Join(", ", page.Actions.Actions.Select(a => a.Id)));
        Check("the ones the window cannot do yet are still on show, greyed, saying where to go",
            page.Actions.ById("agreement-open")?.Enabled == false
            && page.Actions.ById("agreement-open")?.DisabledReason == ClientsPage.NotYet,
            page.Actions.ById("agreement-open")?.DisabledReason ?? "(enabled)");
        Check("and the ones it can do are offered",
            page.Actions.ById("client-new")?.Enabled == true && page.Actions.ById("ticket-new")?.Enabled == false);
        Check("the line underneath says what is unusual about the row",
            page.Summary.Contains("2 open ticket(s)") && !page.Summary.Contains("0 onboarding"), page.Summary);
        Layout(page, 1200, 800);
        NothingAdrift(page, "the client list");
        Shot(page, "3-clients");

        page.Work.Select("Ref", "C-0012");
        Check("picking consultancy offers the consultancy actions instead",
            page.Actions.ById("engagement-open") != null && page.Actions.ById("work-log") != null
            && page.Actions.ById("agreement-open") == null,
            string.Join(", ", page.Actions.Actions.Select(a => a.Id)));
        Check("and its unbilled work is in the line underneath",
            page.Summary.Contains("not yet invoiced"), page.Summary);

        page.Work.Select("Ref", "C-0033");
        Check("consultancy whose Type cell reads \"Molehill Watch\" is still treated as consultancy",
            page.Actions.ById("engagement-open") != null && page.Actions.ById("agreement-open") == null,
            string.Join(", ", page.Actions.Actions.Select(a => a.Id)));

        page.Handlers["engagement-new"]();
        Check("an action that is wired runs", ran.SequenceEqual(new[] { "engagement-new" }), string.Join(", ", ran));

        var tick = Descendants<CheckBox>(page).FirstOrDefault();
        Check("there is a tick box for the finished work", tick != null);
        if (tick != null)
        {
            tick.IsChecked = true;
            tick.RaiseEvent(new RoutedEventArgs(System.Windows.Controls.Primitives.ButtonBase.ClickEvent));
            Check("ticking it asks for the list again, with the finished work in it",
                reloads.SequenceEqual(new[] { true }), string.Join(", ", reloads));
        }

        page.Work.Select("Ref", "C-0012");
        went.Clear();
        page.Open();
        Check("opening a row goes to that engagement, by the reference the tree is keyed on",
            went.SequenceEqual(new[] { "Engagement:C-0012" }), string.Join(", ", went));

        var tree = Nav.Build(work);
        var shell = new Shell(_ => page!);
        shell.Load(tree);
        Check("the toolbar takes everything the page offers, greyed reasons and all",
            shell.Actions.Buttons.Count == page.Actions.Actions.Count,
            $"{shell.Actions.Buttons.Count} buttons for {page.Actions.Actions.Count} actions");
    }

    /// <summary>A config in a scratch folder: nothing here touches the real one.</summary>
    private static (AppConfig Config, string Path, string Folder) ScratchConfig()
    {
        var folder = Path.Combine(Path.GetTempPath(), "MolehillManager-guitest-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        var config = new AppConfig
        {
            OutputFolder = Path.Combine(folder, "out"),
            Connection = { Server = "SQL01", Database = "MolehillAdmin", Authentication = "Windows" }
        };
        return (config, Path.Combine(folder, ConfigStore.FileName), folder);
    }

    /// <summary>
    ///   The settings screen. Everything checked here happens without a server: which fields a
    ///   sign-in method uses, what it says about itself, that what was typed comes back as a draft,
    ///   and that a draft which cannot be valid is refused before anything is written. The paths
    ///   that need a server - Test against a real one, "Save anyway", the install offer - are the
    ///   setup suite's job, and it drives the same Setup rules through ScriptedPrompts.
    /// </summary>
    private static void CheckSettings(BindingWatcher watcher)
    {
        var (config, path, folder) = ScratchConfig();
        try
        {
            var asked = new List<string>();
            var answer = 0;
            int Ask(string title, string message, string[] buttons)
            {
                asked.Add($"{title}: {message.Replace("\n", " ")}");
                return answer;
            }

            watcher.Clear();
            SettingsView? view = null;
            Step("the settings screen lays out with no window", () =>
            {
                view = new SettingsView(config, path, "The server is not set yet.", Ask);
                Layout(view, 900, 700);
                return 0;
            });
            if (view == null) return;
            Check("no binding warnings from the settings screen", watcher.Lines.Count == 0,
                string.Join(" | ", watcher.Lines.Take(2)));

            Check("it says why it opened", Texts(view).Contains("The server is not set yet."),
                string.Join(" | ", Texts(view).Take(4)));
            Check("and where the answers are written", Texts(view).Any(t => t.StartsWith("Saved to ") && t.Contains(ConfigStore.FileName)),
                string.Join(" | ", Texts(view).Where(t => t.StartsWith("Saved to"))));

            // the rule that makes the screen worth having: seven methods, each using different fields
            foreach (var method in AppConfig.AuthMethods)
            {
                view.Authentication = method;
                Layout(view, 900, 700);
                Check($"settings: {method} takes a user name only if it uses one",
                    view.UserEnabled == AppConfig.AllowsUser(method),
                    $"user {(view.UserEnabled ? "on" : "off")}, expected {(AppConfig.AllowsUser(method) ? "on" : "off")}");
                Check($"settings: {method} takes a secret only if it needs one",
                    view.SecretEnabled == AppConfig.NeedsSecret(method),
                    $"secret {(view.SecretEnabled ? "on" : "off")}");
                Check($"settings: {method} explains itself", view.Hint == MolehillManager.Setup.AuthHint(method), view.Hint);
            }

            // what was typed is what gets examined - including the method's stored value, not its label
            view.Authentication = "SqlLogin";
            view.Server = " SQL02 ";
            view.Database = "MolehillAdmin";
            view.User = "mm";
            view.Secret = "S3cret";
            view.Timeout = "30";
            view.AutoRefresh = "5";
            view.Encrypt = "Strict";
            view.TrustCertificate = false;
            view.SavePassword = true;
            view.OutputFolder = Path.Combine(folder, "invoices");
            var draft = view.Draft();
            Check("the draft carries what was typed",
                draft.Server == " SQL02 " && draft.User == "mm" && draft.Secret == "S3cret"
                && draft.Timeout == "30" && draft.AutoRefresh == "5",
                $"{draft.Server}/{draft.User}/{draft.Timeout}/{draft.AutoRefresh}");
            Check("and the sign-in method as the file stores it, not as the screen shows it",
                draft.Authentication == "SqlLogin", draft.Authentication);
            Check("and the encryption and certificate settings",
                draft.Encrypt == "Strict" && !draft.TrustServerCertificate, draft.Encrypt);

            // a draft that cannot be valid is refused without the server being asked at all
            view.Timeout = "9999";
            asked.Clear();
            var verdict = view.Save();
            Check("a timeout nobody could mean is refused", verdict == SetupResult.Cancelled);
            Check("and the reason is shown, naming the field",
                asked.Count == 1 && asked[0].Contains("Timeout", StringComparison.OrdinalIgnoreCase),
                string.Join(" | ", asked));
            Check("and nothing is written", !File.Exists(path), path);

            asked.Clear();
            var tested = view.Test();
            Check("Test refuses it the same way, and still writes nothing",
                tested.Verdict == SaveVerdict.Invalid && !File.Exists(path) && asked.Count == 1,
                string.Join(" | ", asked));

            view.Timeout = "30";
            view.Server = "";
            asked.Clear();
            Check("a missing server is refused too", view.Save() == SetupResult.Cancelled && asked.Count == 1,
                string.Join(" | ", asked));

            // A server that never answers, without needing one: a closed port on localhost is
            // refused at once, with no DNS lookup and nothing network-dependent to hang on. This is
            // the path where a wrong answer quietly throws away what has just been typed, so it
            // belongs in the suite that runs anywhere rather than only the one that needs a server.
            view.Server = "localhost,14331";
            view.Database = "MolehillAdmin";
            view.Authentication = "Windows";
            view.Timeout = "1";
            view.OutputFolder = Path.Combine(folder, "invoices");

            asked.Clear();
            answer = 0;                                        // "Keep editing"
            Check("a server that does not answer is not quietly saved over",
                view.Save() == SetupResult.Cancelled);
            Check("and it asks whether to save anyway",
                asked.Count == 1 && asked[0].StartsWith("Could not connect")
                && asked[0].Contains("Save these settings anyway?"), string.Join(" | ", asked));
            Check("keeping editing writes nothing", !File.Exists(path), path);

            asked.Clear();
            var unreachable = view.Test();
            Check("Test reports that the server did not answer",
                unreachable.Verdict == SaveVerdict.Unreachable, unreachable.Verdict.ToString());
            Check("and trying settings never writes them", !File.Exists(path), path);

            asked.Clear();
            answer = 1;                                        // "Save anyway"
            Check("saving anyway saves", view.Save() == SetupResult.Saved);
            Check("and what was typed is in the file",
                File.Exists(path) && File.ReadAllText(path).Contains("localhost,14331"),
                File.Exists(path) ? "written" : "no file");
            File.Delete(path);

            // Cancel, pressed rather than called: the button has to be wired to the right thing
            var ended = new List<SetupResult>();
            view.Finished += r => ended.Add(r);
            Check("there is a Cancel button to press", Press(view, "Cancel"));
            Check("pressing it reports cancelled, not saved",
                view.Result == SetupResult.Cancelled && ended.SequenceEqual(new[] { SetupResult.Cancelled }),
                view.Result.ToString());
            Check("and still nothing is written", !File.Exists(path));

            foreach (var width in new[] { 700, 900, 1200 })
                Step($"the settings screen lays out at {width}", () => { Layout(view, width, 700); return 0; });

            view.Authentication = "SqlLogin";
            view.Server = "SQL02";
            view.User = "mm";
            Layout(view, 880, 700);
            NothingAdrift(view, "the settings screen");
            Shot(view, "5-settings");
        }
        finally
        {
            try { Directory.Delete(folder, true); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>
    ///   The password prompt, and the three different things its answer can mean. Start-up reads
    ///   null as "give up", "" as "open the settings screen" and anything else as the password, so
    ///   returning the wrong one turns a correctable mistake into the app closing.
    /// </summary>
    private static void CheckSecret(BindingWatcher watcher)
    {
        var (config, path, folder) = ScratchConfig();
        try
        {
            var asked = new List<string>();
            int Ask(string title, string message, string[] buttons) { asked.Add($"{title}: {message}"); return 0; }

            watcher.Clear();
            SecretView? view = null;
            Step("the password prompt lays out with no window", () =>
            {
                view = new SecretView(config, path, "Sign in as mm.", Ask);
                Layout(view, 560, 300);
                return 0;
            });
            if (view == null) return;
            Check("no binding warnings from the password prompt", watcher.Lines.Count == 0,
                string.Join(" | ", watcher.Lines.Take(2)));
            Check("it says who it is signing in as", Texts(view).Contains("Sign in as mm."),
                string.Join(" | ", Texts(view)));

            // an empty box is a typo, not an answer: it asks again rather than closing
            Check("connecting with nothing typed does not connect", !view.Connect());
            Check("and says what to type", asked.Count == 1 && asked[0].Contains("password"), string.Join(" | ", asked));
            Check("and the prompt is still waiting", view.Value == null);

            view.Cancel();
            Check("cancelling means give up, which start-up reads as null", view.Value == null);

            var second = new SecretView(config, path, "Sign in as mm.", Ask);
            Layout(second, 560, 300);
            string? got = "unset";
            second.Finished += v => got = v;
            Check("there is a Settings button to press", Press(second, "Settings..."));
            Check("Settings means the whole screen, which start-up reads as an empty string",
                second.Value == "" && got == "", second.Value ?? "(null)");

            var third = new SecretView(config, path, "Sign in as mm.", Ask);
            Layout(third, 560, 300);
            string? gaveUp = "unset";
            third.Finished += v => gaveUp = v;
            Check("there is a Cancel button to press", Press(third, "Cancel"));
            Check("and pressing it is giving up, which start-up reads as null",
                third.Value == null && gaveUp == null, third.Value ?? "(null)");

            // a password the server will not take: the same closed port, so no server is needed
            var refused = new AppConfig
            {
                OutputFolder = config.OutputFolder,
                Connection = { Server = "localhost,14331", Database = "MolehillAdmin", Authentication = "SqlLogin", User = "mm", ConnectTimeoutSeconds = 1 }
            };
            var refusedView = new SecretView(refused, path, "Sign in as mm.", Ask);
            Layout(refusedView, 560, 300);
            refusedView.Secret = "S3cret-Pa55word!";
            asked.Clear();
            Check("a password the server will not take does not get through", !refusedView.Connect());
            Check("the screen stays open, because the usual reason is a typo", refusedView.Value == null);
            Check("and it says what went wrong",
                asked.Count >= 1 && asked[0].StartsWith("Could not connect"), string.Join(" | ", asked));
            Check("and nothing is written for a password that did not work", !File.Exists(path), path);

            // a client secret is not a password, and the box says which it wants
            var sp = new AppConfig { OutputFolder = config.OutputFolder, Connection = { Server = "SQL01", Database = "d", Authentication = "EntraServicePrincipal" } };
            var spView = new SecretView(sp, path, "Sign in.", Ask);
            Layout(spView, 560, 300);
            Check("a service principal is asked for a client secret, not a password",
                spView.What == "Client secret" && Texts(spView).Contains("Client secret"),
                string.Join(" | ", Texts(spView)));

            Layout(view, 560, 300);
            NothingAdrift(view, "the password prompt");
            Shot(view, "6-secret");
        }
        finally
        {
            try { Directory.Delete(folder, true); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
        }
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

        // and it still has its columns. A grid that has been rendered generates them the moment
        // ItemsSource changes, so clearing them afterwards threw away the ones just made and left
        // an empty header with nothing under it - on every refresh, in every grid in the window.
        // Everything here passed throughout: the table was bound, the rows were there, the
        // selection was right, and the screen was blank. A picture found it.
        Check("and it still has its columns after a rebind",
            grid.Columns.Select(c => c.Header?.ToString() ?? "").SequenceEqual(headers),
            $"{grid.Columns.Count} columns: {string.Join(", ", grid.Columns.Select(c => c.Header))}");

        // the invoice lines do this: the same grid, bound to a different shape each time the
        // selection moves
        var other = new DataTable();
        other.Columns.Add("Id", typeof(int));
        other.Columns.Add("Amount", typeof(decimal));
        other.Rows.Add(1, 400m);
        Step("rebinding to a table of another shape", () => { grid.Bind(other); Layout(host, 1100); return 0; });
        Check("gives the columns of the new table, not the old ones",
            grid.Columns.Select(c => c.Header?.ToString() ?? "").SequenceEqual(new[] { "Id", "Amount" }),
            string.Join(", ", grid.Columns.Select(c => c.Header)));
        Check("and its cells are on the screen",
            Texts(host).Contains("400.00"), string.Join(" | ", Texts(host)));
    }
}
