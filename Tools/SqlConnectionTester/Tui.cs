using Terminal.Gui;

namespace SqlConnectionTester;

/// <summary>The full-screen terminal interface.</summary>
public class Tui
{
    private readonly List<ConnectionProfile> _profiles;
    private readonly Dictionary<string, TestResult> _results = new();
    private string _path;
    private bool _dirty;

    private ListView _list = null!;
    private TextView _detail = null!;
    private Label _status = null!;

    public Tui(string path, List<ConnectionProfile> profiles)
    {
        _path = path;
        _profiles = profiles;
    }

    public void Run()
    {
        Application.Init();
        BuildViews(Application.Top);
        Application.Run();
        Application.Shutdown();
    }

    /// <summary>Creates every view. Split out so --ui-selftest can build the interface without a console.</summary>
    public void BuildViews(Toplevel top)
    {

        var menu = new MenuBar(new[]
        {
            new MenuBarItem("_File", new[]
            {
                new MenuItem("_Open...", "", OpenFile),
                new MenuItem("_Save", "", Save, null, null, Key.CtrlMask | Key.S),
                new MenuItem("Save _As...", "", SaveAs),
                null!,
                new MenuItem("_Quit", "", Quit, null, null, Key.CtrlMask | Key.Q)
            }),
            new MenuBarItem("_Connection", new[]
            {
                new MenuItem("_Add...", "", () => EditProfile(null)),
                new MenuItem("_Edit...", "", () => EditProfile(Selected())),
                new MenuItem("D_uplicate", "", Duplicate),
                new MenuItem("_Delete", "", Delete),
                null!,
                new MenuItem("_Test selected", "", TestSelected),
                new MenuItem("Test a_ll", "", TestAll)
            }),
            new MenuBarItem("_Results", new[]
            {
                new MenuItem("_View full result...", "", ShowResult),
                new MenuItem("_Export CSV...", "", ExportCsv),
                new MenuItem("_Copy connection string", "", CopyConnectionString)
            }),
            new MenuBarItem("_Help", new[] { new MenuItem("_About", "", About) })
        });

        var win = new Window("SQL Connection Tester")
        {
            X = 0,
            Y = 1,
            Width = Dim.Fill(),
            Height = Dim.Fill(1)
        };

        _list = new ListView(new List<string>())
        {
            X = 0,
            Y = 0,
            Width = Dim.Percent(42),
            Height = Dim.Fill(1),
            AllowsMarking = false
        };
        _list.SelectedItemChanged += _ => ShowDetail();
        _list.OpenSelectedItem += _ => EditProfile(Selected());

        var detailFrame = new FrameView("Details")
        {
            X = Pos.Right(_list),
            Y = 0,
            Width = Dim.Fill(),
            Height = Dim.Fill(1)
        };
        _detail = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(), ReadOnly = true, WordWrap = true };
        detailFrame.Add(_detail);

        _status = new Label("") { X = 0, Y = Pos.Bottom(_list), Width = Dim.Fill() };
        win.Add(_list, detailFrame, _status);

        var statusBar = new StatusBar(new[]
        {
            new StatusItem(Key.F2, "~F2~ Add", () => EditProfile(null)),
            new StatusItem(Key.F3, "~F3~ Edit", () => EditProfile(Selected())),
            new StatusItem(Key.F4, "~F4~ Delete", Delete),
            new StatusItem(Key.F5, "~F5~ Test", TestSelected),
            new StatusItem(Key.F6, "~F6~ Test all", TestAll),
            new StatusItem(Key.F7, "~F7~ Result", ShowResult),
            new StatusItem(Key.F8, "~F8~ Export", ExportCsv),
            new StatusItem(Key.CtrlMask | Key.S, "~^S~ Save", Save),
            new StatusItem(Key.CtrlMask | Key.Q, "~^Q~ Quit", Quit)
        });

        top.Add(menu, win, statusBar);
        RefreshList();
    }

    private ConnectionProfile? Selected() =>
        _list.SelectedItem >= 0 && _list.SelectedItem < _profiles.Count ? _profiles[_list.SelectedItem] : null;

    private void RefreshList(int? select = null)
    {
        var items = _profiles.Select(p =>
        {
            var state = _results.TryGetValue(p.Name, out var r) ? (r.Succeeded ? "[ OK ]" : "[FAIL]") : "[    ]";
            return $"{state} {p.Name}  -  {(p.UseRawConnectionString ? "raw" : p.Server)}";
        }).ToList();

        _list.SetSource(items);
        if (select.HasValue && select.Value >= 0 && select.Value < items.Count) _list.SelectedItem = select.Value;
        ShowDetail();
        UpdateStatus();
    }

    private void UpdateStatus()
    {
        var ok = _results.Values.Count(r => r.Succeeded);
        var fail = _results.Values.Count(r => !r.Succeeded);
        _status.Text = $" {_profiles.Count} connection(s)   tested: {ok} succeeded, {fail} failed   file: {_path}{(_dirty ? " *" : "")}";
    }

    private void ShowDetail()
    {
        var p = Selected();
        if (p == null) { _detail.Text = "No connection selected.\n\nPress F2 to add one."; return; }

        var text = $"{p.Name}\n\n{p.Describe()}\n\nConnection string:\n{ConnectionProfile.Mask(p.Build())}\n\nQuery:\n{p.Query}\n";
        if (_results.TryGetValue(p.Name, out var r))
        {
            text += $"\nLast test: {r.TestedAt:dd MMM yyyy HH:mm:ss} ({r.ElapsedMs} ms)\nStatus: {r.Status}\n";
            if (r.TestText != null) text += $"TestText: {r.TestText}\n";
            if (!string.IsNullOrEmpty(r.ErrorMessage)) text += $"\n{r.ErrorMessage}\n";
        }
        else text += "\nNot tested yet (F5).";
        _detail.Text = text;
    }

    // ---------------------------------------------------------------- actions

    private void EditProfile(ConnectionProfile? existing)
    {
        var isNew = existing == null;
        var p = existing ?? new ConnectionProfile();
        if (ProfileDialog.Show(p, isNew ? "Add connection" : "Edit connection"))
        {
            if (isNew) _profiles.Add(p);
            _dirty = true;
            RefreshList(isNew ? _profiles.Count - 1 : _list.SelectedItem);
        }
    }

    private void Duplicate()
    {
        var p = Selected();
        if (p == null) return;
        _profiles.Add(p.Clone());
        _dirty = true;
        RefreshList(_profiles.Count - 1);
    }

    private void Delete()
    {
        var p = Selected();
        if (p == null) return;
        if (MessageBox.Query("Delete", $"Delete '{p.Name}'?", "Yes", "No") != 0) return;
        _profiles.Remove(p);
        _results.Remove(p.Name);
        _dirty = true;
        RefreshList(0);
    }

    private void TestSelected()
    {
        var p = Selected();
        if (p == null) return;
        var index = _list.SelectedItem;
        _status.Text = $" Testing {p.Name}...";
        Application.Refresh();
        _results[p.Name] = ConnectionTester.Test(p);
        RefreshList(index);
        ShowResult();
    }

    private void TestAll()
    {
        foreach (var p in _profiles)
        {
            _status.Text = $" Testing {p.Name}...";
            Application.Refresh();
            _results[p.Name] = ConnectionTester.Test(p);
        }
        RefreshList(_list.SelectedItem);
        var ok = _results.Values.Count(r => r.Succeeded);
        MessageBox.Query("Test all", $"{ok} of {_profiles.Count} connection(s) succeeded.", "Ok");
    }

    private void ShowResult()
    {
        var p = Selected();
        if (p == null || !_results.TryGetValue(p.Name, out var r))
        {
            MessageBox.Query("Result", "This connection has not been tested yet (F5).", "Ok");
            return;
        }

        var text = $"Connection : {r.Name}\r\n" +
                   $"Status     : {r.Status}\r\n" +
                   $"TestText   : {r.TestText}\r\n" +
                   $"Tested     : {r.TestedAt:dd MMM yyyy HH:mm:ss} ({r.ElapsedMs} ms)\r\n\r\n" +
                   $"Connection string:\r\n{r.ConnectionString}\r\n\r\n" +
                   (string.IsNullOrEmpty(r.ErrorMessage) ? "" : $"Error:\r\n{r.ErrorMessage.Replace("\n", "\r\n")}");

        var close = new Button("Close", true);
        var dialog = new Dialog(r.Succeeded ? "Success" : "Failure", 88, 26, close);
        var view = new TextView { X = 0, Y = 0, Width = Dim.Fill(), Height = Dim.Fill(1), ReadOnly = true, WordWrap = true, Text = text };
        close.Clicked += () => Application.RequestStop();
        dialog.Add(view);
        Application.Run(dialog);
    }

    private void CopyConnectionString()
    {
        var p = Selected();
        if (p == null) return;
        try
        {
            Clipboard.TrySetClipboardData(p.Build());
            MessageBox.Query("Copy", "The connection string (including any password) was copied to the clipboard.", "Ok");
        }
        catch (Exception ex)
        {
            MessageBox.ErrorQuery("Copy", ConnectionTester.Describe(ex), "Ok");
        }
    }

    private void ExportCsv()
    {
        if (_results.Count == 0) { MessageBox.Query("Export", "Nothing tested yet (F6 tests everything).", "Ok"); return; }
        var save = new SaveDialog("Export results", "Choose a CSV file") { DirectoryPath = Directory.GetCurrentDirectory(), FilePath = "connection-test-results.csv" };
        Application.Run(save);
        if (save.Canceled || save.FilePath == null) return;
        try
        {
            ConnectionTester.ExportCsv(_profiles.Where(p => _results.ContainsKey(p.Name)).Select(p => _results[p.Name]), save.FilePath.ToString()!);
            MessageBox.Query("Export", $"Saved {_results.Count} result(s).", "Ok");
        }
        catch (Exception ex)
        {
            MessageBox.ErrorQuery("Export", ConnectionTester.Describe(ex), "Ok");
        }
    }

    private void OpenFile()
    {
        var open = new OpenDialog("Open connections", "Choose a connections file") { DirectoryPath = Path.GetDirectoryName(_path) ?? "." };
        Application.Run(open);
        if (open.Canceled || open.FilePaths.Count == 0) return;
        try
        {
            var loaded = ProfileStore.Load(open.FilePaths[0]);
            _profiles.Clear();
            _profiles.AddRange(loaded);
            _results.Clear();
            _path = open.FilePaths[0];
            _dirty = false;
            RefreshList(0);
        }
        catch (Exception ex)
        {
            MessageBox.ErrorQuery("Open", ConnectionTester.Describe(ex), "Ok");
        }
    }

    private void Save()
    {
        try
        {
            ProfileStore.Save(_path, _profiles);
            _dirty = false;
            UpdateStatus();
        }
        catch (Exception ex)
        {
            MessageBox.ErrorQuery("Save", ConnectionTester.Describe(ex), "Ok");
        }
    }

    private void SaveAs()
    {
        var save = new SaveDialog("Save connections", "Choose a file") { DirectoryPath = Path.GetDirectoryName(_path) ?? ".", FilePath = Path.GetFileName(_path) };
        Application.Run(save);
        if (save.Canceled || save.FilePath == null) return;
        _path = save.FilePath.ToString()!;
        Save();
    }

    private void About() =>
        MessageBox.Query("About", "SQL Connection Tester\n\nTests SQL Server connection strings by reading a single row\nfrom dbo.TestConnection. Read-only: nothing is created or changed.\n\nMolehill Data Services", "Ok");

    private void Quit()
    {
        if (_dirty && MessageBox.Query("Quit", "Save changes before quitting?", "Save", "Discard") == 0) Save();
        Application.RequestStop();
    }
}
