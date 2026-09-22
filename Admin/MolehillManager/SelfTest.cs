using System.Data;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>Headless checks: every screen and form against a real MolehillAdmin, with a fake console.</summary>
public static class SelfTest
{
    private static int _pass, _fail;

    static SelfTest() => Console.OutputEncoding = System.Text.Encoding.UTF8;

    private static void Check(string name, bool ok, string detail = "")
    {
        if (ok) _pass++; else _fail++;
        Console.WriteLine($"{(ok ? "PASS" : "FAIL")}  {name}{(detail == "" ? "" : "  -  " + detail)}");
    }

    private static T? Step<T>(string name, Func<T> action, Func<T, string?>? verify = null)
    {
        try
        {
            var result = action();
            var problem = verify?.Invoke(result);
            Check(name, problem == null, problem ?? "");
            return result;
        }
        catch (Exception ex)
        {
            Check(name, false, (ex is FormatException ? ex.Message : AdminDb.Describe(ex)).Replace("\n", " | "));
            if (Environment.GetEnvironmentVariable("MM_TRACE") == "1") Console.WriteLine(ex);
            return default;
        }
    }

    private static void ExpectError(string name, Action action, string mustContain)
    {
        try
        {
            action();
            Check(name, false, "no error raised");
        }
        catch (Exception ex)
        {
            var msg = ex is FormatException ? ex.Message : AdminDb.Describe(ex);
            Check(name, msg.Contains(mustContain, StringComparison.OrdinalIgnoreCase), msg.Replace("\n", " | "));
        }
    }

    private static int Finish()
    {
        Console.WriteLine();
        Console.WriteLine($"{_pass} passed, {_fail} failed.");
        return _fail == 0 ? 0 : 2;
    }

    /// <summary>The config file: missing values, plain-text migration, DPAPI encryption, dialogs. No database needed.</summary>
    public static int Config()
    {
        var folder = Path.Combine(Path.GetTempPath(), "MolehillManager-configtest-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, ConfigStore.FileName);
        const string pw = "S3cret-Pa55word!";
        try
        {
            Step("explicit --config path is used", () => ConfigStore.Resolve(path), r => r == path ? null : r);

            var fresh = ConfigStore.Load(path, out var existed);
            Check("no file: first run, server missing", !existed && fresh.Missing().Contains("server"), string.Join(", ", fresh.Missing()));
            Check("no file: output folder defaulted", fresh.OutputFolder == AppConfig.DefaultOutputFolder, fresh.OutputFolder);

            // hand-edited file: comments, trailing comma, plain-text password
            File.WriteAllText(path, """
                {
                  // edited by hand
                  "Connection": { "Server": "SQL01", "Database": "MolehillAdmin", "Authentication": "SqlLogin", "User": "mm", "Password": "S3cret-Pa55word!", },
                  "OutputFolder": "D:/Invoices",
                }
                """);
            var c1 = ConfigStore.Load(path, out _);
            Check("comments and trailing commas accepted", c1.Connection.Server == "SQL01");
            Check("plain-text password picked up", c1.Secret == pw && c1.PlainTextSecretFound);
            Check("complete config has nothing missing", c1.Missing().Count == 0 && !c1.NeedsSecretPrompt, string.Join(", ", c1.Missing()));
            ConfigStore.Save(path, c1);
            var text = File.ReadAllText(path);
            Check("saved file has no plain-text password", !text.Contains(pw) && !text.Contains("\"Password\""));
            Check("saved file has the encrypted password", text.Contains("\"PasswordEncrypted\":"));
            var c2 = ConfigStore.Load(path, out _);
            Check("encrypted password reads back", c2.Secret == pw && !c2.PlainTextSecretFound && !c2.SecretUnreadable);
            Check("connection string carries it", c2.BuildConnectionString().Contains(pw));

            // Windows names typed with single backslashes
            File.WriteAllText(path, """{ "Connection": { "Server": "SQL01\INST", "Authentication": "Windows" }, "OutputFolder": "D:\reports\new" }""");
            var cb = ConfigStore.Load(path, out _);
            Check("single backslashes taken literally", cb.Connection.Server == @"SQL01\INST" && cb.OutputFolder == @"D:\reports\new", cb.Connection.Server + " " + cb.OutputFolder);
            ConfigStore.Save(path, cb);
            var cb2 = ConfigStore.Load(path, out _);
            Check("and survive a save and reload", cb2.Connection.Server == @"SQL01\INST" && cb2.OutputFolder == @"D:\reports\new", cb2.Connection.Server + " " + cb2.OutputFolder);
            File.WriteAllText(path, text);

            // someone else's (or a corrupted) encrypted password
            File.WriteAllText(path, text.Replace(c2.Connection.PasswordEncrypted!, Convert.ToBase64String(new byte[64])));
            var c3 = ConfigStore.Load(path, out _);
            Check("unreadable encrypted password: asked for again", c3.SecretUnreadable && c3.NeedsSecretPrompt);

            // not remembered
            c2.Connection.SavePassword = false;
            ConfigStore.Save(path, c2);
            var c4 = ConfigStore.Load(path, out _);
            Check("'remember' off: nothing stored, asked each time", !File.ReadAllText(path).Contains("\"PasswordEncrypted\":") && c4.NeedsSecretPrompt);

            // Windows sign-in never stores a secret
            c2.Connection.Authentication = "Windows"; c2.Connection.SavePassword = true; c2.Secret = "ignored";
            ConfigStore.Save(path, c2);
            Check("Windows sign-in stores no secret", !File.ReadAllText(path).Contains("\"PasswordEncrypted\":"));

            // what gets asked for
            var c5 = new AppConfig { OutputFolder = "x", Connection = { Server = "SQL01", Authentication = "SqlLogin" } };
            Check("SQL login without user: user name asked for", c5.Missing().Contains("user name"));
            c5.Connection.Authentication = "EntraServicePrincipal";
            Check("service principal without id: client id asked for", c5.Missing().Contains("client id"));
            c5.Connection.Authentication = "Bogus";
            Check("unknown sign-in method: asked for", c5.Missing().Contains("sign-in method"));
            c5.Connection.Authentication = "EntraServicePrincipal"; c5.Connection.User = "app-id";
            Check("secret needed but not saved: password prompt", c5.Missing().Count == 0 && c5.NeedsSecretPrompt);

            foreach (var method in AppConfig.AuthMethods)
                Step($"connection string builds: {method}", () =>
                {
                    var c = new AppConfig { Secret = "x", Connection = { Server = "SQL01", Authentication = method, User = "u" } };
                    return c.BuildConnectionString();
                });

            Application.Init(new FakeDriver(), null);
            try
            {
                foreach (var method in AppConfig.AuthMethods)
                    Step($"settings dialog builds: {method}", () =>
                    {
                        var c = new AppConfig { OutputFolder = "x", Connection = { Server = "SQL01", Authentication = method } };
                        using var d = SetupDialog.Create(c, path, "Self test", out _);
                        return 0;
                    });
            }
            finally { Application.Shutdown(); }
        }
        finally
        {
            try { Directory.Delete(folder, true); } catch { }
        }
        return Finish();
    }

    /// <summary>
    /// The real start-up path on a fake console: a config file without a server, so the settings screen opens,
    /// explains what is missing, is filled in and saved, and the app connects with what was written.
    /// </summary>
    public static int Setup(string server)
    {
        var folder = Path.Combine(Path.GetTempPath(), "MolehillManager-setuptest-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, ConfigStore.FileName);
        File.WriteAllText(path, "{ \"Connection\": { \"Database\": \"MolehillAdmin\", \"Authentication\": \"Windows\" } }");
        var shownReason = "";
        var others = new List<string>();
        Application.Init(new FakeDriver(), null);
        try
        {
            var config = ConfigStore.Load(path, out var existed);
            Check("config without a server is incomplete", config.Missing().SequenceEqual(new[] { "server", "output folder" }), string.Join(", ", config.Missing()));

            View? handled = null;
            Application.Iteration += () =>
            {
                var current = Application.Current;
                if (current == null || current == handled) return;
                handled = current;
                if (current is Dialog d && d.Title.ToString() == "Molehill Manager settings")
                {
                    var labels = All<Label>(d).ToList();
                    shownReason = labels.First().Text.ToString() ?? "";
                    var fields = All<TextField>(d).ToList();          // server, database, user, password, timeout, output, refresh
                    fields[0].Text = server;
                    fields[5].Text = Path.Combine(folder, "out");
                    All<Button>(d).First(b => b.Text.ToString()!.Contains("Save")).OnClicked();
                }
                else
                {
                    others.Add(All<Label>(current).Select(l => l.Text.ToString()).FirstOrDefault(t => !string.IsNullOrWhiteSpace(t)) ?? "(dialog)");
                    Application.RequestStop(current);
                }
            };

            var cs = Step("start-up asks, saves and connects", () => Startup.Connect(config, path, existed, forceSetup: false, loadFailed: false),
                r => r != null ? null : "gave up: " + string.Join(" | ", others));
            Check("settings screen said what was missing", shownReason.Contains("server"), shownReason);
            Check("no other prompts on the way", others.Count == 0, string.Join(" | ", others));
            var saved = ConfigStore.Load(path, out _);
            Check("server written to the config file", saved.Connection.Server == server, saved.Connection.Server);
            Check("output folder written and created", saved.OutputFolder == Path.Combine(folder, "out") && Directory.Exists(saved.OutputFolder), saved.OutputFolder);
            Check("saved config is complete", saved.Missing().Count == 0 && !saved.NeedsSecretPrompt, string.Join(", ", saved.Missing()));
            Check("the file connects", ConfigStore.Check(saved.BuildConnectionString()) == null);
            // exactly what Program does next, after the start-up dialogs have run: build the main screen and run it
            Step("main window builds after the start-up dialogs (as the app does)", () =>
            {
                var top = new MainWindow(new AdminDb(cs!), path, () => null, () => 0).CreateTop();
                Check("main screen has the menu, tabs and status bar", top.Subviews.Count >= 3, top.Subviews.Count.ToString());
                Application.Run(top);                          // the test's handler closes it again
                return 0;
            });
            Console.WriteLine();
            Console.WriteLine(File.ReadAllText(path));
        }
        finally
        {
            Application.Shutdown();
            try { Directory.Delete(folder, true); } catch { }
        }
        return Finish();
    }

    /// <summary>
    /// Create / install / upgrade on a real server, through the start-up screens on a fake console. Uses (and then
    /// drops) databases called MolehillAdmin_selftest_*; nothing else on the server is touched.
    /// </summary>
    public static int Install(string server)
    {
        var stamp = Guid.NewGuid().ToString("N")[..6];
        string Db(string what) => $"MolehillAdmin_selftest_{stamp}_{what}";
        var created = new List<string>();
        var folder = Path.Combine(Path.GetTempPath(), "MolehillManager-installtest-" + stamp);
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, ConfigStore.FileName);
        var seen = new List<string>();

        AppConfig Config(string db) => new() { OutputFolder = folder, Connection = { Server = server, Database = db, Authentication = "Windows" } };
        var master = new AdminDb(new AppConfig { Connection = { Server = server, Database = "master" } }.BuildConnectionString());

        Application.Init(new FakeDriver(), null);
        View? handled = null;
        Application.Iteration += () =>
        {
            var current = Application.Current;
            if (current == null || current == handled || current is not Dialog d) return;
            var title = d.Title.ToString() ?? "";
            if (title.StartsWith("Installing")) return;                       // progress window: closes itself
            handled = current;
            seen.Add(title);
            var buttons = All<Button>(d).ToList();
            Button Press(params string[] names) => buttons.First(b => names.Any(n => b.Text.ToString()!.Contains(n)));
            if (title is "Create MolehillAdmin" or "Install MolehillAdmin" or "Upgrade MolehillAdmin")
                Press("Create and install", "Install", "Upgrade").OnClicked();
            else if (title == "Business and invoice details" && All<TextField>(d).Any())
            {
                All<TextField>(d).First().Text = "Selftest Services Ltd";
                Press("Save").OnClicked();
            }
            else if (title == "Molehill Manager settings") Press("Cancel").OnClicked();   // unexpected: fail the step
            else Press("Close", "Ok").OnClicked();
        };

        try
        {
            // 1. no database at all
            var a = Config(Db("new"));
            created.Add(a.Connection.Database);
            Check("missing database detected", AdminInstaller.Inspect(a).State == DbState.DatabaseMissing, AdminInstaller.Inspect(a).Message);
            ConfigStore.Save(path, a);
            var cs = Step("start-up creates and installs it", () => Startup.Connect(a, path, existed: true, forceSetup: false, loadFailed: false),
                r => r != null ? null : "gave up; saw: " + string.Join(" | ", seen));
            Check("asked first, then showed the result and business details",
                seen.Take(3).SequenceEqual(new[] { "Create MolehillAdmin", "MolehillAdmin installed", "Business and invoice details" }), string.Join(" | ", seen));
            Check("database is ready", AdminInstaller.Inspect(a).State == DbState.Ready);
            var adb = new AdminDb(a.BuildConnectionString());
            Check("business details saved", (adb.Scalar("SELECT Value FROM dbo.Setting WHERE Name = 'BusinessName'") as string) == "Selftest Services Ltd");
            Check("install recorded", Convert.ToInt32(adb.Scalar("SELECT COUNT(*) FROM dbo.InstallHistory")) >= 1);
            Check("standard price list seeded", Convert.ToInt32(adb.Scalar("SELECT COUNT(*) FROM dbo.PriceList")) >= 1);
            Step("the app's screens work on it (after the install dialogs, as the app does)", () => { new MainWindow(adb, path, () => null, () => 0).CreateTop(); return 0; });

            // 2. an older MolehillAdmin (before the Azure SQL columns): upgrade keeps the data
            adb.Proc("dbo.usp_Client_Add", ("@ClientName", "Kept Ltd"));
            adb.Execute("""
                ALTER TABLE dbo.Instance DROP CONSTRAINT CK_Instance_AzureDbCount;
                ALTER TABLE dbo.Instance DROP CONSTRAINT CK_Instance_Platform;
                ALTER TABLE dbo.Instance DROP CONSTRAINT DF_Instance_Platform;
                ALTER TABLE dbo.Instance DROP COLUMN Platform;
                """);
            Check("older version detected", AdminInstaller.Inspect(a).State == DbState.NeedsUpgrade, AdminInstaller.Inspect(a).Message);
            seen.Clear();
            Step("start-up upgrades it", () => Startup.Connect(a, path, existed: true, forceSetup: false, loadFailed: false),
                r => r != null ? null : "gave up; saw: " + string.Join(" | ", seen));
            Check("upgrade asked for, no business details form", seen.FirstOrDefault() == "Upgrade MolehillAdmin" && !seen.Contains("Business and invoice details"), string.Join(" | ", seen));
            Check("upgraded and ready", AdminInstaller.Inspect(a).State == DbState.Ready);
            Check("data kept", Convert.ToInt32(adb.Scalar("SELECT COUNT(*) FROM dbo.Client WHERE ClientName = N'Kept Ltd'")) == 1);

            // 2b. schema current but an older recorded version (e.g. a later change that isn't a new column): upgrade offered
            adb.Execute("INSERT dbo.InstallHistory (Version) VALUES ('1.0.0');");
            var older = AdminInstaller.Inspect(a);
            Check("older recorded version offered the upgrade", older.State == DbState.NeedsUpgrade && older.Message.Contains("1.0.0"), older.Message);
            Step("upgrading it", () => AdminInstaller.Install(a));
            Check("version recorded, ready again", AdminInstaller.Inspect(a).State == DbState.Ready && AdminInstaller.ScriptVersion >= new Version(1, 2));

            // 3. an install that stopped part way is finished, not refused as a clash
            adb.Execute("DROP PROCEDURE dbo.usp_Dashboard;");
            var partial = AdminInstaller.Inspect(a);
            Check("partial install offered to finish", partial.State == DbState.NotInstalled && partial.Message.Contains("partly"), partial.Message);
            Step("finishing it", () => AdminInstaller.Install(a));
            Check("finished and ready", AdminInstaller.Inspect(a).State == DbState.Ready);

            // 4. an existing empty database, with a name that needs quoting
            var b = Config(Db("empty [x]"));
            created.Add(b.Connection.Database);
            master.Execute("CREATE DATABASE [" + b.Connection.Database.Replace("]", "]]") + "];");
            Check("empty database detected", AdminInstaller.Inspect(b).State == DbState.NotInstalled && AdminInstaller.Inspect(b).Message.Contains("empty"), AdminInstaller.Inspect(b).Message);
            seen.Clear();
            Step("start-up installs into it", () => Startup.Connect(b, path, existed: true, forceSetup: false, loadFailed: false),
                r => r != null ? null : "gave up; saw: " + string.Join(" | ", seen));
            Check("installed and ready", AdminInstaller.Inspect(b).State == DbState.Ready);

            // 5. someone else's database with the same table names: left alone
            var c = Config(Db("other"));
            created.Add(c.Connection.Database);
            master.Execute($"CREATE DATABASE [{c.Connection.Database}];");
            new AdminDb(c.BuildConnectionString()).Execute("CREATE TABLE dbo.Client (Id int); CREATE TABLE dbo.Invoice (Id int);");
            var clash = AdminInstaller.Inspect(c);
            Check("clashing tables refused", clash.State == DbState.Clash && !clash.CanInstall && clash.Message.Contains("dbo.Client"), clash.Message);

            // 6. a server that isn't there
            var bad = Config(Db("x"));
            bad.Connection.Server = "no-such-server-molehill-test"; bad.Connection.ConnectTimeoutSeconds = 3;
            Check("unreachable server is an error, not an install offer", AdminInstaller.Inspect(bad).State == DbState.Error);
        }
        finally
        {
            Application.Shutdown();
            SqlConnectionPools.Clear();
            foreach (var db in created)
            {
                try { master.Execute($"IF DB_ID(@n) IS NOT NULL BEGIN DECLARE @q nvarchar(300) = QUOTENAME(@n); EXEC (N'ALTER DATABASE ' + @q + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE ' + @q); END", ("@n", db)); }
                catch (Exception ex) { Console.WriteLine($"(could not drop {db}: {ex.Message})"); }
            }
            try { Directory.Delete(folder, true); } catch { }
        }
        return Finish();
    }

    private static class SqlConnectionPools
    {
        public static void Clear() => Microsoft.Data.SqlClient.SqlConnection.ClearAllPools();
    }

    private static IEnumerable<T> All<T>(View root) where T : View
    {
        foreach (var v in root.Subviews)
        {
            if (v is T t) yield return t;
            foreach (var x in All<T>(v)) yield return x;
        }
    }

    /// <summary>Builds the main window, every agreement window and every form. Read-only.</summary>
    public static int Ui(AdminDb db)
    {
        Application.Init(new FakeDriver(), null);
        try
        {
            RunUi(db);
        }
        finally
        {
            Application.Shutdown();
        }
        return Finish();
    }

    private static void RunUi(AdminDb db)
    {
        Step("main window builds and loads every tab", () => { new MainWindow(db).CreateTop(); return 0; });
        Step("dashboard returns its 4 result sets", () => db.Proc("dbo.usp_Dashboard"), r => r.Tables.Count == 4 ? null : $"{r.Tables.Count} sets");

        var agreements = Queries.Agreements(db, includeEnded: true);
        Check("agreements query", true, $"{agreements.Rows.Count} agreement(s)");
        foreach (DataRow a in agreements.Rows)
        {
            var reference = (string)a["Ref"];
            Step($"agreement window {reference}", () => new AgreementWindow(db, reference).Build());
            Step($"summary {reference}", () => AgreementWindow.Summary(db, reference, includeInstances: true), s => s.Contains("not found") ? s : null);
        }

        // every form builds as a dialog, using real data where the form needs a selection
        var anyRef = agreements.Rows.Count > 0 ? (string)agreements.Rows[0]["Ref"] : "MWA-0000";
        var anyClient = agreements.Rows.Count > 0 ? (string)agreements.Rows[0]["Client"] : "Client";
        var anyInstance = agreements.Rows.Count > 0 ? Queries.InstanceNames(db, anyRef).FirstOrDefault() ?? "SQL01" : "SQL01";
        var tickets = Queries.Tickets(db, openOnly: false);
        var anyTicket = tickets.Rows.Count > 0 ? (string)tickets.Rows[0]["Ticket"] : "MW-00001";
        var invoices = Queries.Invoices(db, "All");
        var anyInvoice = invoices.Rows.Count > 0 ? (string)invoices.Rows[0]["Invoice"] : "INV-0001";

        foreach (var spec in AllForms(db, anyRef, anyClient, anyInstance, anyTicket, anyInvoice))
            Step($"form '{spec.Title}' builds", () => { using var d = FormDialog.Create(spec, out _); return 0; });

        if (tickets.Rows.Count > 0) Step($"ticket detail {anyTicket}", () => TicketActions.Describe(db, anyTicket));
        if (invoices.Rows.Count > 0) Step($"invoice lines {anyInvoice}", () => Queries.InvoiceLines(db, anyInvoice));

        // MM_SCREENS=<file>: render the screens into the fake console and write them out as text, for checking layout
        var dump = Environment.GetEnvironmentVariable("MM_SCREENS");
        if (!string.IsNullOrEmpty(dump)) DumpScreens(db, dump, anyRef, AllForms(db, anyRef, anyClient, anyInstance, anyTicket, anyInvoice));
    }

    private static string Screen()
    {
        var driver = (FakeDriver)Application.Driver;
        var contents = driver.Contents;
        var sb = new System.Text.StringBuilder();
        for (var r = 0; r < contents.GetLength(0); r++)
        {
            var line = new System.Text.StringBuilder();
            for (var c = 0; c < contents.GetLength(1); c++) line.Append(char.ConvertFromUtf32(Math.Max(32, contents[r, c, 0])));
            sb.AppendLine(line.ToString().TrimEnd());
        }
        return sb.ToString();
    }

    private static void Render(View view)
    {
        view.LayoutSubviews();
        view.Redraw(view.Bounds);
    }

    private static void DumpScreens(AdminDb db, string path, string reference, IEnumerable<FormSpec> forms)
    {
        FakeConsole.SetBufferSize(132, 40);
        FakeConsole.SetWindowSize(132, 40);
        ((FakeDriver)Application.Driver).SetBufferSize(132, 40);
        var sb = new System.Text.StringBuilder();
        var top = new Toplevel();
        top.Frame = new Rect(0, 0, 132, 40);
        Application.Driver.Clip = new Rect(0, 0, 132, 40);
        var main = new MainWindow(db);
        main.Build(top);
        var tabs = FindAll<TabView>(top).First();
        foreach (var tab in tabs.Tabs.ToList())
        {
            tabs.SelectedTab = tab;
            Render(top);
            sb.AppendLine($"===== main: {tab.Text}").AppendLine(Screen());
        }
        var agreement = new AgreementWindow(db, reference).Build();
        agreement.X = 0; agreement.Y = 0; agreement.Width = 131; agreement.Height = 39;
        var inner = FindAll<TabView>(agreement).First();
        foreach (var tab in inner.Tabs.ToList())
        {
            inner.SelectedTab = tab;
            agreement.Frame = new Rect(0, 0, 131, 39);
            Render(agreement);
            sb.AppendLine($"===== agreement: {tab.Text}").AppendLine(Screen());
        }
        foreach (var spec in forms)
        {
            var d = FormDialog.Create(spec, out _);
            d.Frame = new Rect(0, 0, 98, Math.Min(38, spec.Fields.Sum(f => f.Kind == FieldKind.Memo ? 4 : 1) + 10));
            Application.Driver.Clip = new Rect(0, 0, 132, 40);
            Render(d);
            sb.AppendLine($"===== form: {spec.Title}").AppendLine(Screen());
        }
        File.WriteAllText(path, sb.ToString());
        Console.WriteLine($"Screens written to {path}");
    }

    private static IEnumerable<T> FindAll<T>(View root) where T : View
    {
        foreach (var v in root.Subviews)
        {
            if (v is T t) yield return t;
            foreach (var x in FindAll<T>(v)) yield return x;
        }
    }

    private static IEnumerable<FormSpec> AllForms(AdminDb db, string reference, string client, string instance, string ticket, string invoice)
    {
        var contact = db.Scalar("SELECT TOP (1) ContactId FROM dbo.Contact ORDER BY ContactId;") is int id ? id : 0;
        var contactForms = contact == 0 ? Array.Empty<FormSpec>()
            : new[] { AdminForms.EditContact(db, contact), AdminForms.RemoveContact(db, contact), AdminForms.ReaddContact(db, contact) };
        return contactForms.Concat(new[]
    {
        AdminForms.NewClient(db), AdminForms.NewAgreement(db), AdminForms.AddContact(db, client),
        AdminForms.AddInstance(db, reference), AdminForms.UpdateInstance(db, reference, instance), AdminForms.RemoveInstance(db, reference, instance),
        AdminForms.RiskAcceptance(db, reference, instance), AdminForms.WeeklyReport(db, reference, instance),
        AdminForms.CompleteOnboarding(db, reference, "REMOTE_ACCESS", "Remote access"), AdminForms.RecordReview(db, reference),
        AdminForms.GiveNotice(db, reference), AdminForms.PauseSupport(db, reference, true), AdminForms.PauseSupport(db, reference, false),
        AdminForms.PriceChange(db), AdminForms.AddQuote(db, reference), AdminForms.OpenTicket(db, reference),
        AdminForms.RespondTicket(db, ticket), AdminForms.EstimateTicket(db, ticket), AdminForms.LogTime(db, ticket), AdminForms.CloseTicket(db, ticket),
        AdminForms.RunBilling(db), AdminForms.AdjustInvoice(db, invoice), AdminForms.SetInvoiceStatus(db, invoice, "Paid"),
        AdminForms.BusinessDetails(db)
    });
    }

    /// <summary>Fills in and submits every form, exactly as the dialogs do, against a test database.</summary>
    public static int Write(AdminDb db)
    {
        var stamp = DateTime.Now.ToString("MMddHHmmss");
        var name = $"Selftest Ltd {stamp}";
        var reference = $"ST-{stamp}";
        var start = DateTime.Today.AddDays(-40);   // so billing has a started cycle, and an ended one for arrears
        string D(DateTime d) => d.ToString("yyyy-MM-dd");

        FormValues Fill(FormSpec spec, params (string Field, string Value)[] values)
        {
            var v = spec.NewValues();
            foreach (var (f, value) in values) v[f] = value;
            return v;
        }
        ProcResult Submit(FormSpec spec, params (string, string)[] values) => spec.Execute(Fill(spec, values));

        Console.WriteLine($"Writing test data as '{name}' ({reference}).");
        Console.WriteLine();

        Step("new client + contact + agreement", () => Submit(AdminForms.NewClient(db),
                ("ClientName", name), ("ContactName", "Pat Tester"),
                ("ContactEmail", "pat@selftest.example"), ("ContactReceivesInvoices", "0"), ("StartDate", D(start)),
                ("SignedDate", D(start.AddDays(-7))), ("AgreementRef", reference)),
            r => r.Tables.Any(t => t.Columns.Contains("AgreementRef") && t.Rows.Count == 1 && (string)t.Rows[0]["AgreementRef"] == reference) ? null : "agreement not returned");

        ExpectError("duplicate client is refused before touching the database",
            () => Submit(AdminForms.NewClient(db), ("ClientName", name), ("StartDate", D(start))), "already exists");
        ExpectError("required field is enforced", () => Submit(AdminForms.AddInstance(db, reference)), "Name is required");
        ExpectError("bad number is caught", () => Submit(AdminForms.AddInstance(db, reference), ("InstanceName", "X"), ("DatabaseCount", "lots")), "not a whole number");

        Step("first contact raises tickets, doesn't receive invoices", () => Queries.Contacts(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Name"] == "Pat Tester" && (string)r["Tickets"] == "Yes" && (string)r["Invoices"] == "") ? null : "flags wrong");
        Step("summary says nobody receives invoices yet", () => AgreementWindow.Summary(db, reference, false), s => s.Contains("Invoices to: NO ONE") ? null : "not flagged");
        Step("shared accounts address: receives invoices only", () => Submit(AdminForms.AddContact(db, name), ("FullName", "Accounts"),
            ("Email", "accounts@selftest.example"), ("IsBillingContact", "1"), ("StartDate", D(start))));
        Step("it doesn't raise tickets, and the summary shows where invoices go", () => AgreementWindow.Summary(db, reference, false),
            s => s.Contains("Invoices to: Accounts <accounts@selftest.example>") ? null : s.Split('\n').FirstOrDefault(l => l.StartsWith("Invoices")) ?? "no line");
        Step("add contact from a start date", () => Submit(AdminForms.AddContact(db, name), ("FullName", "Sam Second"), ("Email", "sam@selftest.exmaple"),
            ("Phone", "01234 567890"), ("StartDate", D(start))));
        int SamId() => (int)Queries.Contacts(db, reference, includeRemoved: true).Rows.Cast<DataRow>().First(r => (string)r["Name"] == "Sam Second")["Id"];
        Step("edit contact: fix the e-mail typo, clear the phone", () => Submit(AdminForms.EditContact(db, SamId()),
            ("Email", "sam@selftest.example"), ("Phone", "")));
        Step("edited details saved, the rest unchanged", () => Queries.Contact(db, SamId())!,
            r => (string)r["Email"] == "sam@selftest.example" && r["Phone"] is DBNull && (string)r["FullName"] == "Sam Second" ? null : $"{r["Email"]} / {r["Phone"]}");
        ExpectError("edit contact: bad e-mail refused", () => Submit(AdminForms.EditContact(db, SamId()), ("Email", "sam at selftest")), "does not look like an e-mail");
        ExpectError("add contact: someone already current refused", () => Submit(AdminForms.AddContact(db, name), ("FullName", "Sam Second")), "already a contact");
        Step("remove contact (soft)", () => Submit(AdminForms.RemoveContact(db, SamId()), ("EndDate", D(DateTime.Today.AddDays(-10))), ("Reason", "Left the company")));
        Step("removed contact kept, shown as removed", () => Queries.Contacts(db, reference, includeRemoved: true),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Name"] == "Sam Second" && (string)r["Status"] == "Removed" && r["To"] is DateTime) ? null : "not removed");
        Step("removed contact left out of the current list", () => Queries.Contacts(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Name"] == "Sam Second") ? "still listed" : null);
        ExpectError("remove contact: twice refused", () => Submit(AdminForms.RemoveContact(db, SamId())), "not a current contact");
        ExpectError("add back: start before they left refused", () => Submit(AdminForms.ReaddContact(db, SamId()), ("StartDate", D(DateTime.Today.AddDays(-12)))), "must be after");
        Step("add contact back", () => Submit(AdminForms.ReaddContact(db, SamId()), ("StartDate", D(DateTime.Today)), ("Phone", "07000 000000")));
        Step("history has both periods, with the reason", () => Queries.ContactPeriods(db, SamId()),
            t => t.Rows.Count == 2 && (string)t.Rows[0]["Reason"] == "Left the company" && t.Rows[1]["To"] is DBNull ? null : $"{t.Rows.Count} periods");
        Step("back as a current contact with the new phone", () => Queries.Contact(db, SamId())!,
            r => r["IsActive"] is true && (string)r["Phone"] == "07000 000000" ? null : "not current");

        var add = () => AdminForms.AddInstance(db, reference);
        Step("add SQL Server standalone", () => Submit(add(), ("InstanceName", "ST-SQL01"), ("SqlVersion", "2019"), ("Edition", "Standard")));
        Step("add AG primary", () => Submit(add(), ("InstanceName", "ST-SQL02"), ("Role", "AGPrimary"), ("AvailabilityGroup", "AG1"), ("SqlVersion", "2022")));
        Step("add AG secondary", () => Submit(add(), ("InstanceName", "ST-SQL03"), ("Role", "AGSecondary"), ("PrimaryInstanceName", "ST-SQL02"), ("AvailabilityGroup", "AG1"), ("SqlVersion", "2022")));
        Step("add Azure SQL Managed Instance", () => Submit(add(), ("InstanceName", "st-mi01"), ("Platform", "AzureSqlManagedInstance"), ("Edition", "General Purpose")));
        Step("add Azure SQL Database server, 8 databases", () => Submit(add(), ("InstanceName", "st-sqldb"), ("Platform", "AzureSqlDatabaseServer"), ("DatabaseCount", "8")));
        Step("add Azure SQL Database geo-replica", () => Submit(add(), ("InstanceName", "st-sqldb-dr"), ("Platform", "AzureSqlDatabaseServer"), ("Role", "GeoReplica"), ("PrimaryInstanceName", "st-sqldb")));
        Step("add non-production at an agreed fee", () => Submit(add(), ("InstanceName", "ST-DEV01"), ("Environment", "NonProduction"), ("AgreedMonthlyFee", "95.50"), ("SqlVersion", "2022")));
        ExpectError("Azure SQL Database without a database count is refused", () => Submit(add(), ("InstanceName", "st-pool"), ("Platform", "AzureSqlDatabaseElasticPool")), "database");
        ExpectError("non-production without a fee is refused", () => Submit(add(), ("InstanceName", "ST-DEV02"), ("Environment", "NonProduction")), "@AgreedMonthlyFee");

        Step("update Azure database count to 9", () => Submit(AdminForms.UpdateInstance(db, reference, "st-sqldb"), ("DatabaseCount", "9")));
        Step("update keeps untouched fields", () => Queries.Instance(db, reference, "ST-SQL01")!,
            r => (string)r["Edition"] == "Standard" ? null : $"edition is {r["Edition"]}");
        Step("update monitoring date", () => Submit(AdminForms.UpdateInstance(db, reference, "ST-SQL01"), ("MonitoringInstalledDate", D(start))));

        // pricing, straight from the price list the agreement is on
        var fees = Queries.Instances(db, reference);
        var price = db.Query("SELECT p.* FROM dbo.Agreement a JOIN dbo.PriceList p ON p.PriceListId = a.PriceListId WHERE a.AgreementRef = @r", ("@r", reference)).Rows[0];
        decimal Fee(string inst) => fees.Rows.Cast<DataRow>().Where(r => (string)r["Instance"] == inst).Select(r => r["Fee"] is decimal d ? d : -1m).FirstOrDefault(-1m);
        var unit = (decimal)price["AzureSqlDbUnitFee"];
        var extra = (decimal)price["AzureSqlDbExtraDatabaseFee"];
        var included = (int)price["AzureSqlDbIncludedDatabases"];
        Check("Azure SQL Database fee = unit + extra databases", Fee("st-sqldb") == unit + (9 - included) * extra, $"£{Fee("st-sqldb")}");
        Check("geo-replica is included", Fee("st-sqldb-dr") == 0, $"£{Fee("st-sqldb-dr")}");
        Check("Managed Instance priced as the 3rd server (multi-server rate)", Fee("st-mi01") == (decimal)price["ServerFeeTiered"], $"£{Fee("st-mi01")}");
        Check("AG secondary at the secondary rate", Fee("ST-SQL03") == (decimal)price["SecondaryReplicaFee"], $"£{Fee("ST-SQL03")}");
        Check("agreed fee used for non-production", Fee("ST-DEV01") == 95.50m, $"£{Fee("ST-DEV01")}");

        Step("onboarding item done", () => Submit(AdminForms.CompleteOnboarding(db, reference, "REMOTE_ACCESS", ""), ("Notes", "VPN")));
        Step("onboarding recorded", () => Queries.Onboarding(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Code"] == "REMOTE_ACCESS" && r["Done"] is DateTime) ? null : "not marked done");
        Step("named contact auto-completed", () => Queries.Onboarding(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Code"] == "NAMED_CONTACT" && r["Done"] is DateTime) ? null : "not marked done");
        Step("initial review", () => Submit(AdminForms.RecordReview(db, reference), ("Notes", "Delivered")));
        Step("risk acceptance", () => Submit(AdminForms.RiskAcceptance(db, reference, "ST-SQL01"), ("AcceptedBy", "Pat Tester")));
        Step("weekly report", () => Submit(AdminForms.WeeklyReport(db, reference, "ST-SQL01"), ("OverallStatus", "Amber"), ("WarningCount", "2")));
        Step("weekly report recorded", () => Queries.WeeklyReports(db, reference), t => t.Rows.Count == 1 ? null : $"{t.Rows.Count} rows");

        // a ticket through its whole life
        var raised = start.AddDays(3).Date.AddHours(10);
        while (raised.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday) raised = raised.AddDays(1);
        var opened = Step("open ticket", () => Submit(AdminForms.OpenTicket(db, reference),
            ("Title", "Slow queries"), ("Severity", "Critical"), ("InstanceName", "ST-SQL01"), ("RaisedAt", raised.ToString("yyyy-MM-dd HH:mm")),
            ("Description", "Reports timing out")), r => r.First is { Rows.Count: 1 } ? null : "no ticket returned");
        var ticket = opened?.First?.Rows[0]["TicketRef"] as string ?? "MW-?";
        Step("respond", () => Submit(AdminForms.RespondTicket(db, ticket), ("RespondedAt", raised.AddMinutes(30).ToString("yyyy-MM-dd HH:mm"))));
        Step("estimate sent", () => Submit(AdminForms.EstimateTicket(db, ticket), ("EstimateHours", "3")));
        Step("estimate approved", () => Submit(AdminForms.EstimateTicket(db, ticket), ("Approved", "1")));
        Step("log 90 minutes, rate worked out", () => Submit(AdminForms.LogTime(db, ticket), ("Minutes", "90"), ("Description", "Index review"),
            ("WorkStart", raised.AddHours(1).ToString("yyyy-MM-dd HH:mm"))));
        Step("log 30 minutes out of hours, forced rate", () => Submit(AdminForms.LogTime(db, ticket), ("Minutes", "30"), ("Description", "Evening check"),
            ("WorkStart", raised.Date.AddHours(20).ToString("yyyy-MM-dd HH:mm")), ("RateType", "OutOfHours")));
        Step("time recorded", () => Queries.TimeEntries(db, ticket), t => t.Rows.Count == 2 && (string)t.Rows[0]["Rate"] == "BusinessHours" ? null : "wrong entries");
        Step("close", () => Submit(AdminForms.CloseTicket(db, ticket), ("Resolution", "Added two indexes")));
        Step("ticket detail", () => TicketActions.Describe(db, ticket), s => s.Contains("Added two indexes") && s.Contains("Index review") ? null : "detail incomplete");
        Step("project quote", () => Submit(AdminForms.AddQuote(db, reference), ("Title", "Upgrade to 2022"), ("EstimatedHours", "12"), ("TicketRef", ticket)));

        // billing
        var billed = Step("run billing for the agreement", () => Submit(AdminForms.RunBilling(db),
                ("Client", Queries.AgreementChoices(db).First(c => Queries.RefFromChoice(c) == reference))),
            r => r.First is { Rows.Count: > 0 } ? null : "no invoices created");
        var invoice = billed?.First?.Rows[0]["InvoiceNo"] as string ?? "?";
        Step("first invoice charges the first month (instances named during onboarding)", () => Queries.InvoiceLines(db, invoice),
            t => t.Rows.Cast<DataRow>().Count(r => (string)r["Type"] == "MonthlyFee") == 7 ? null : $"{t.Rows.Cast<DataRow>().Count(r => (string)r["Type"] == "MonthlyFee")} fee lines");
        Step("instance added after the first invoice is covered from today", () => { Submit(add(), ("InstanceName", "ST-SQL04")); return Queries.Instance(db, reference, "ST-SQL04")!; },
            r => (DateTime)r["CoveredFrom"] == DateTime.Today ? null : $"covered from {r["CoveredFrom"]}");
        Step("billing again creates nothing", () => Submit(AdminForms.RunBilling(db),
                ("Client", Queries.AgreementChoices(db).First(c => Queries.RefFromChoice(c) == reference))),
            r => r.First is { Rows.Count: 0 } ? null : $"{r.First?.Rows.Count} more invoice(s)");
        Step("adjustment", () => Submit(AdminForms.AdjustInvoice(db, invoice), ("Description", "Goodwill credit"), ("Amount", "-10")));
        Step("invoice lines include the credit", () => Queries.InvoiceLines(db, invoice),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Type"] == "Adjustment" && (decimal)r["Amount"] == -10m) ? null : "no adjustment line");
        var folder = Path.Combine(Path.GetTempPath(), "MolehillManager-selftest");
        Step("invoice HTML saved", () => AdminForms.SaveInvoiceHtml(db, invoice, folder), p => File.ReadAllText(p).Contains(invoice) ? null : "HTML lacks invoice number");
        Step("invoice is billed to the contact that receives invoices, not the ticket contact", () => File.ReadAllText(Path.Combine(folder, invoice + ".html")),
            h => h.Contains("accounts@selftest.example") && !h.Contains("pat@selftest.example") ? null : "wrong recipients");
        Step("dashboard HTML saved", () => AdminForms.SaveDashboardHtml(db, folder), p => File.ReadAllText(p).Contains("<html", StringComparison.OrdinalIgnoreCase) ? null : "not HTML");
        Step("mark sent", () => Submit(AdminForms.SetInvoiceStatus(db, invoice, "Sent")));
        Step("mark paid", () => Submit(AdminForms.SetInvoiceStatus(db, invoice, "Paid")));
        Step("invoice is paid", () => Queries.Invoices(db, "All"), t => t.Rows.Cast<DataRow>().Any(r => (string)r["Invoice"] == invoice && (string)r["Status"] == "Paid") ? null : "not paid");
        ExpectError("adjusting a paid invoice is refused", () => Submit(AdminForms.AdjustInvoice(db, invoice), ("Description", "x"), ("Amount", "1")), "draft");

        // agreement lifecycle
        Step("pause support", () => Submit(AdminForms.PauseSupport(db, reference, true)));
        Step("summary shows paused", () => AgreementWindow.Summary(db, reference, false), s => s.Contains("SUPPORT PAUSED") ? null : "not shown");
        Step("resume support", () => Submit(AdminForms.PauseSupport(db, reference, false)));
        Step("notice preview records nothing", () => Submit(AdminForms.GiveNotice(db, reference)),
            r => r.First?.Rows[0]["Recorded"] as string == "No (WhatIf)" && Queries.Agreement(db, reference)!["EndDate"] is DBNull ? null : "notice was recorded");
        Step("remove instance", () => Submit(AdminForms.RemoveInstance(db, reference, "ST-DEV01"), ("CoveredTo", D(DateTime.Today))));
        Step("removed instance keeps its history", () => Queries.Instances(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Instance"] == "ST-DEV01" && ((string)r["Cover"]).StartsWith("Ends")) ? null : "cover not ended");
        Step("new agreement for the existing client", () => Submit(AdminForms.NewAgreement(db), ("ClientName", name), ("StartDate", D(DateTime.Today.AddMonths(2))), ("AgreementRef", reference + "b")));

        // the screens over the new data
        Application.Init(new FakeDriver(), null);
        try
        {
            Step("main window over the test data", () => { new MainWindow(db).CreateTop(); return 0; });
            Step("agreement window over the test data", () => new AgreementWindow(db, reference).Build());
        }
        finally
        {
            Application.Shutdown();
        }

        Console.WriteLine();
        Console.WriteLine(AgreementWindow.Summary(db, reference, includeInstances: true));
        return Finish();
    }
}
