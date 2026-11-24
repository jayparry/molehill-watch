using System.Data;
using System.Diagnostics;
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

    /// <summary>All the text a control would show, in tree order.</summary>
    private static List<string> Texts(DependencyObject root) =>
        Descendants<TextBlock>(root).Select(t => t.Text).Where(t => !string.IsNullOrWhiteSpace(t)).ToList();

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
        return Finish();
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
