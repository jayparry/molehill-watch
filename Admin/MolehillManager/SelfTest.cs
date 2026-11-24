using System.Data;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>Headless checks: every screen and form against a real MolehillAdmin, with a fake console.</summary>
public static partial class SelfTest
{
    private static int _pass, _fail;

    static SelfTest()
    {
        // the output encoding is ConsoleHost's job now. Setting it here threw when the app became
        // windowed and there was no console yet - and in a static constructor that arrives as a
        // TypeInitializationException, at whatever moment something first touched SelfTest.

        // errors come back as FAIL lines, not as a dialog nothing can dismiss. Named in full
        // because SelfTest.Ui(AdminDb) is the read-only suite, and would win the lookup here.
        MolehillManager.Ui.Headless = true;
    }

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
            Check(name, false, AdminDb.Explain(ex).Replace("\n", " | "));
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

            Check("--tui asks for the terminal, whatever the default is",
                Startup.ChooseFrontEnd(tuiAsked: true) == FrontEnd.Terminal);
            Check("saying nothing gets the default",
                Startup.ChooseFrontEnd(tuiAsked: false) == Startup.Default);
            // when the default moves to the window, this is the check that fails, and the reminder
            // that --help, README.md and Admin/MolehillManager/README.md all still say otherwise
            Check("the default is still the terminal, as everything written down says",
                Startup.Default == FrontEnd.Terminal, Startup.Default.ToString());

            // which row a screen comes back to after a refresh. The terminal UI remembers the row
            // number, so anything inserted above moves you to a different row without saying so;
            // the window remembers the row.
            static DataTable Rows(string column, params string[] values)
            {
                var t = new DataTable();
                t.Columns.Add(column, typeof(string));
                foreach (var v in values) t.Rows.Add(v);
                return t;
            }
            var refs = Rows("Ref", "MW-0001", "MW-0002", "MW-0003");
            Check("a Ref column identifies a row", RowKey.KeyColumn(refs) == "Ref", RowKey.KeyColumn(refs) ?? "(none)");
            Check("and a row is remembered by it", RowKey.Of(refs, 1) == "MW-0002", RowKey.Of(refs, 1) ?? "(none)");
            Check("a row inserted above does not move the selection",
                RowKey.Reselect(Rows("Ref", "MW-0000", "MW-0001", "MW-0002", "MW-0003"), "MW-0002", 1) == 2,
                RowKey.Reselect(Rows("Ref", "MW-0000", "MW-0001", "MW-0002", "MW-0003"), "MW-0002", 1).ToString());
            Check("the row that was selected having gone, the number is used",
                RowKey.Reselect(Rows("Ref", "MW-0001", "MW-0003"), "MW-0002", 1) == 1);
            Check("an empty table selects nothing", RowKey.Reselect(Rows("Ref"), "MW-0002", 1) == -1);
            Check("a column that repeats does not identify a row", RowKey.KeyColumn(Rows("Ref", "A", "A", "B")) == null);
            Check("nor does one with a blank in it", RowKey.KeyColumn(Rows("Ref", "A", "", "B")) == null);
            Check("a table with nothing identifying falls back to the row number",
                RowKey.Reselect(Rows("Client", "x", "y", "z"), "x", 2) == 2);
            Check("and a row number past the end is brought back in range",
                RowKey.Reselect(Rows("Ref", "A", "B"), null, 9) == 1);
            var both = Rows("Ticket", "MW-00001", "MW-00002");
            both.Columns.Add("Ref", typeof(string));
            both.Rows[0]["Ref"] = "A-1"; both.Rows[1]["Ref"] = "A-2";
            Check("Ref is preferred to Ticket when a table has both", RowKey.KeyColumn(both) == "Ref", RowKey.KeyColumn(both) ?? "(none)");

            // In a Section for the same reason the GUI suite's parts are: a throw in here used
            // to take the whole run down without printing a summary, so a mutation pass could
            // not tell a failing check from a broken harness.
            Section("the shared rules, the tree and the Today page", () =>
            {
                // The app's error policy, which both front ends share through AdminDb.Explain. Worth
                // being exact about what the special case is for, because a mutation pass showed it
                // changes nothing today: Describe of a FormatException with nothing inside it returns
                // precisely the message, and every FormatException the app throws is bare. So the rule
                // only bites when one carries an inner exception - which is what the third check below
                // is, and without it, replacing Explain with Describe breaks no test at all.
                var bare = new FormatException("Minutes: 'half an hour' is not a whole number.");
                Check("what someone typed is shown as the app wrote it",
                    AdminDb.Explain(bare) == bare.Message, AdminDb.Explain(bare));
                Check("and for a bare one that is the same as the full description",
                    AdminDb.Describe(bare) == bare.Message, AdminDb.Describe(bare));
                var wrapped = new FormatException("Covered from: 'soon' is not a date (use yyyy-mm-dd).",
                    new InvalidOperationException("Sequence contains no elements"));
                Check("a sentence about what was typed is not padded out with the detail underneath it",
                    AdminDb.Explain(wrapped) == wrapped.Message, AdminDb.Explain(wrapped));
                Check("while the full description keeps that detail, for the places that want it",
                    AdminDb.Describe(wrapped).Contains("Sequence contains no elements"), AdminDb.Describe(wrapped));
                var failed = new InvalidOperationException("The database is not there.", new IOException("the disk went away"));
                Check("anything not about typing is described in full, inner exceptions and all",
                    AdminDb.Explain(failed) == AdminDb.Describe(failed) && AdminDb.Explain(failed).Contains("the disk went away"),
                    AdminDb.Explain(failed));

                // ---- the left-hand tree, with no window. What the app offers, and where you are in it.
                static DataTable Work(params (string Client, string Ref, string Type, string What, string Raw)[] rows)
                {
                    var t = new DataTable();
                    foreach (var c in new[] { "Ref", "Client", "Type", "What", "_EngagementType" }) t.Columns.Add(c, typeof(string));
                    foreach (var r in rows) t.Rows.Add(r.Ref, r.Client, r.Type, r.What, r.Raw);
                    return t;
                }
                var tree = Nav.Build(Work(
                    ("Zeta Ltd", "MW-A-0007", "Molehill Watch", "2 instance(s) monitored", "Monitoring"),
                    ("Acme Ltd", "MW-A-0003", "Molehill Watch", "4 instance(s) monitored", "Monitoring"),
                    ("Acme Ltd", "C-0012", "Consultancy", "Upgrade to SQL Server 2022", "Consultancy")));
                Check("the tree offers the same five places every time",
                    tree.Select(n => n.Kind).SequenceEqual(new[]
                        { NavKind.Today, NavKind.Clients, NavKind.Tickets, NavKind.Billing, NavKind.Settings }),
                    string.Join(", ", tree.Select(n => n.Label)));
                var clients = tree[1].Children;
                Check("a client is one line however much work they have", clients.Count == 2,
                    string.Join(", ", clients.Select(c => $"{c.Label} ({c.Children.Count})")));
                Check("and they are in the order someone would look a name up in",
                    clients.Select(c => c.Label).SequenceEqual(new[] { "Acme Ltd", "Zeta Ltd" }),
                    string.Join(", ", clients.Select(c => c.Label)));
                var acme = clients.First(c => c.Label == "Acme Ltd").Children;
                Check("a support agreement is called what it is, not how many instances it has",
                    acme.Any(n => n.Label == "Molehill Watch"), string.Join(", ", acme.Select(n => n.Label)));
                Check("and a consultancy engagement is called by its project name",
                    acme.Any(n => n.Label == "Upgrade to SQL Server 2022"), string.Join(", ", acme.Select(n => n.Label)));
                Check("each one carries the raw type, so the page is picked from data and not from a label",
                    acme.FirstOrDefault(n => n.Key == "C-0012")?.EngagementType == "Consultancy",
                    acme.FirstOrDefault(n => n.Key == "C-0012")?.EngagementType ?? "(none)");
                Check("the breadcrumb says where you are",
                    Nav.Breadcrumb(tree, NavKind.Engagement, "C-0012") == "Clients › Acme Ltd › Upgrade to SQL Server 2022",
                    Nav.Breadcrumb(tree, NavKind.Engagement, "C-0012"));
                Check("for one of the fixed places it is just that place",
                    Nav.Breadcrumb(tree, NavKind.Today) == "Today", Nav.Breadcrumb(tree, NavKind.Today));
                Check("and something no longer in the tree has no breadcrumb rather than a made-up one",
                    Nav.Breadcrumb(tree, NavKind.Engagement, "C-9999") == "",
                    Nav.Breadcrumb(tree, NavKind.Engagement, "C-9999"));
                Check("an engagement is found by its reference", Nav.Find(tree, NavKind.Engagement, "MW-A-0003") != null);
                Check("the tree is there and navigable before any data is",
                    Nav.Build(null).Count == 5 && Nav.Build(null)[1].Children.Count == 0);
                Check("and a table without the columns it needs is treated as no data, not as a crash",
                    Nav.Build(new DataTable()).Count == 5);
                var wrongTable = new DataTable();
                wrongTable.Columns.Add("Something", typeof(string));
                wrongTable.Rows.Add("else");
                Check("a table with rows but not the columns gives no clients, rather than one with no name",
                    Nav.Build(wrongTable)[1].Children.Count == 0,
                    string.Join(", ", Nav.Build(wrongTable)[1].Children.Select(c => $"'{c.Label}'")));

                // ---- the Today page's figures
                static DashboardView Dash(int openTickets, params (string Column, decimal Value)[] money)
                {
                    var tickets = new DataTable();
                    tickets.Columns.Add("Ticket", typeof(string));
                    for (var i = 1; i <= openTickets; i++) tickets.Rows.Add($"MW-{i:00000}");
                    var m = new DataTable();
                    foreach (var (column, _) in money) m.Columns.Add(column, typeof(decimal));
                    if (money.Length > 0) m.Rows.Add(money.Select(x => (object)x.Value).ToArray());
                    return new DashboardView(new DataTable(), tickets, new DataTable(), new DataTable(),
                        m.Rows.Count > 0 ? m.Rows[0] : null);
                }
                var tiles = Today.Tiles(Dash(3,
                    ("MonthlyRecurringRevenue", 4250m), ("DraftInvoicesTotal", 0m), ("UnpaidSentTotal", 1200.5m),
                    ("OverdueTotal", 0m), ("PaidThisYear", 18400m), ("UnbilledConsultancy", 640m)));
                Check("every figure the database reports is shown", tiles.Count == 7,
                    string.Join(", ", tiles.Select(t => t.Label)));
                Check("money shows the pence", tiles[0].Value == "£4,250.00", tiles[0].Value);
                Check("and halves are not lost", tiles[2].Value == "£1,200.50", tiles[2].Value);
                Check("the open tickets are counted, after the money",
                    tiles[^1].Label == "Open tickets" && tiles[^1].Value == "3", tiles[^1].Value);
                var some = Today.Tiles(Dash(0, ("MonthlyRecurringRevenue", 1m)));
                Check("a figure the database does not report is left out, not shown as a bare pound sign",
                    some.Count == 2 && some.All(t => t.Value != "£"), string.Join(", ", some.Select(t => $"{t.Label}={t.Value}")));
                var quiet = Today.Tiles(Dash(2));
                Check("with no money reported at all, the ticket count is still shown",
                    quiet.Count == 1 && quiet[0].Value == "2", string.Join(", ", quiet.Select(t => t.Label)));

                // the colours an alert gets, as palette keys. That these are the same colours the
                // dashboard e-mail uses is checked against the install script itself, in --selftest-gui.
                Check("a high alert is coloured as the dashboard the clients receive colours it",
                    Today.AlertColour("High") == ("StatusRed", "StatusRedInk", true));
                Check("and normal and low the same way",
                    Today.AlertColour("Normal") == ("StatusAmber", "Ink", true)
                    && Today.AlertColour("Low") == ("StatusInfo", "Ink", false));
                Check("a priority nobody has heard of is left uncoloured rather than guessed at",
                    Today.AlertColour("Critical") == null && Today.AlertColour(null) == null);
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
        var outFolder = Path.Combine(folder, "out");
        try
        {
            var config = ConfigStore.Load(path, out var existed);
            Check("config without a server is incomplete", config.Missing().SequenceEqual(new[] { "server", "output folder" }), string.Join(", ", config.Missing()));

            // no Application, no driver: start-up asks through IStartupPrompts and nothing else
            var prompts = new ScriptedPrompts
            {
                // the server and folder are what is missing; the refresh is typed over to prove that
                // a setting the file already had a value for is written back as changed
                Fill = draft => { draft.Server = server; draft.OutputFolder = outFolder; draft.AutoRefresh = "7"; return draft; }
            };

            var cs = Step("start-up asks, saves and connects (with no console of any kind)",
                () => Startup.Connect(prompts, config, path, existed, forceSetup: false, loadFailed: false),
                r => r != null ? null : "gave up: " + (prompts.Refused ?? prompts.Trail));
            Check("settings screen said what was missing", prompts.Why?.Contains("server") == true, prompts.Why ?? "(never asked)");
            Check("settings screen was handed what the file already said",
                prompts.Offered?.Database == "MolehillAdmin" && prompts.Offered?.Server == "" && prompts.Offered?.Authentication == "Windows",
                $"{prompts.Offered?.Server}/{prompts.Offered?.Database}/{prompts.Offered?.Authentication}");
            Check("asked once, and nothing else", prompts.Seen.SequenceEqual(new[] { "settings" }), prompts.Trail);
            var saved = ConfigStore.Load(path, out _);
            Check("server written to the config file", saved.Connection.Server == server, saved.Connection.Server);
            Check("output folder written and created", saved.OutputFolder == outFolder && Directory.Exists(saved.OutputFolder), saved.OutputFolder);
            Check("auto refresh written as typed", saved.AutoRefreshMinutes == 7, saved.AutoRefreshMinutes.ToString());
            Check("saved config is complete", saved.Missing().Count == 0 && !saved.NeedsSecretPrompt, string.Join(", ", saved.Missing()));
            Check("the file connects", ConfigStore.Check(saved.BuildConnectionString()) == null);

            // the rules the screen no longer owns, now that a test can reach them
            SettingsDraft Good() => new()
            {
                Server = server, Database = "MolehillAdmin", Authentication = "Windows",
                Encrypt = "Mandatory", Timeout = "15", OutputFolder = outFolder, AutoRefresh = "0"
            };
            // named in full: SelfTest.Setup(string) is this suite, and would win the lookup here
            SaveCheck Examine(SettingsDraft draft) => MolehillManager.Setup.Examine(draft, saved);
            var good = Examine(Good());
            Check("a good draft is accepted and reaches the server", good.Verdict == SaveVerdict.Ready, good.Database?.Message ?? good.Problem ?? "");

            SaveCheck Bad(Action<SettingsDraft> spoil) { var d = Good(); spoil(d); return Examine(d); }
            void Rejected(string what, Action<SettingsDraft> spoil, string reasonHas)
            {
                var r = Bad(spoil);
                Check($"rejected: {what}", r.Verdict == SaveVerdict.Invalid && r.Problem!.Contains(reasonHas), $"{r.Verdict} {r.Problem}");
            }
            Rejected("no server", d => d.Server = "   ", "server");
            Rejected("no database", d => d.Database = "", "database");
            Rejected("no output folder", d => d.OutputFolder = " ", "output folder");
            Rejected("a sign-in method that does not exist", d => d.Authentication = "Telepathy", "sign-in method");
            Rejected("an encryption setting that does not exist", d => d.Encrypt = "Sometimes", "encryption");
            Rejected("a timeout that is not a number", d => d.Timeout = "soon", "1 - 600");
            Rejected("a timeout of nothing", d => d.Timeout = "0", "1 - 600");
            Rejected("a timeout of a lifetime", d => d.Timeout = "601", "1 - 600");
            Rejected("auto refresh that is not a number", d => d.AutoRefresh = "often", "0 - 1440");
            Rejected("auto refresh beyond a day", d => d.AutoRefresh = "1441", "0 - 1440");
            Rejected("auto refresh going backwards", d => d.AutoRefresh = "-1", "0 - 1440");
            Rejected("a SQL login with no user name", d => { d.Authentication = "SqlLogin"; d.Secret = "x"; }, "user name");
            Rejected("a SQL login with no password", d => { d.Authentication = "SqlLogin"; d.User = "sa"; }, "password");
            Rejected("a service principal with no client id", d => { d.Authentication = "EntraServicePrincipal"; d.Secret = "x"; }, "client id");
            Rejected("a service principal with no secret", d => { d.Authentication = "EntraServicePrincipal"; d.User = "app"; }, "client secret");

            var trimmed = Bad(d => { d.Server = $"  {server}  "; d.Database = " MolehillAdmin "; d.OutputFolder = $" {outFolder} "; });
            Check("spaces either side of a server, database or folder are ignored",
                trimmed.Candidate?.Connection.Server == server && trimmed.Candidate?.Connection.Database == "MolehillAdmin"
                && trimmed.Candidate?.OutputFolder == outFolder,
                $"'{trimmed.Candidate?.Connection.Server}' '{trimmed.Candidate?.Connection.Database}' '{trimmed.Candidate?.OutputFolder}'");

            var unreachable = Bad(d => { d.Server = "no-such-server-molehill-test"; d.Timeout = "3"; });
            Check("a server that is not there can be saved, but only on purpose",
                unreachable.Verdict == SaveVerdict.Unreachable, unreachable.Verdict.ToString());

            var windows = Bad(d => { d.Authentication = "Windows"; d.User = "ignored"; d.Secret = "ignored"; });
            Check("Windows sign-in keeps no user name and no password",
                windows.Candidate!.Connection.User == "" && windows.Candidate.Secret == null,
                $"'{windows.Candidate.Connection.User}' / {windows.Candidate.Secret ?? "(none)"}");

            var untouched = saved.Connection.Server;
            Bad(d => { d.Server = "somewhere-else"; d.Database = ""; });     // invalid, so nothing is dialled
            Check("examining a draft changes nothing", saved.Connection.Server == untouched, saved.Connection.Server);

            // the hints are prose, so there is nothing to assert about their wording - but a hint
            // that promises a password where none is asked for, or stays silent where one is, is wrong
            foreach (var method in AppConfig.AuthMethods)
            {
                var hint = MolehillManager.Setup.AuthHint(method);
                var promises = hint.Contains("password", StringComparison.OrdinalIgnoreCase) || hint.Contains("secret", StringComparison.OrdinalIgnoreCase);
                Check($"sign-in hint: {method}", hint.Length > 20 && promises == AppConfig.NeedsSecret(method), hint);
            }
            Check("every sign-in method has its own hint",
                AppConfig.AuthMethods.Select(MolehillManager.Setup.AuthHint).Distinct().Count() == AppConfig.AuthMethods.Length);

            // the three ways out of start-up that no test has ever taken, now that a script can take them.
            // A database name nothing could have created, so "Create MolehillAdmin" is what comes up.
            AppConfig Fresh(string db) => new()
            {
                OutputFolder = outFolder,
                Connection = { Server = server, Database = db, Authentication = "Windows", ConnectTimeoutSeconds = 15 }
            };
            var absent = Fresh("MolehillAdmin_selftest_never_created");
            var missing = AdminInstaller.Inspect(absent);
            Check("that database really is not there", missing.State == DbState.DatabaseMissing, missing.Message);
            var installable = Bad(d => d.Database = absent.Connection.Database);
            Check("settings for a database that could be created are not treated as a failure to connect",
                installable.Verdict == SaveVerdict.CanInstall, $"{installable.Verdict} {installable.Database?.Message}");

            var quit = new ScriptedPrompts { Answer = (_, _) => 2 };          // "Quit"
            Check("Quit at the install offer creates nothing",
                Startup.Connect(quit, absent, path, existed: true, forceSetup: false, loadFailed: false) == null
                && quit.Seen.SequenceEqual(new[] { "Create MolehillAdmin" })
                && AdminInstaller.Inspect(absent).State == DbState.DatabaseMissing, quit.Trail);

            var settings = new ScriptedPrompts { Answer = (_, _) => 1 };      // "Settings..." - and then closed
            Check("Settings at the install offer opens the settings screen, not the installer",
                Startup.Connect(settings, absent, path, existed: true, forceSetup: false, loadFailed: false) == null
                && settings.Seen.SequenceEqual(new[] { "Create MolehillAdmin", "settings" })
                && AdminInstaller.Inspect(absent).State == DbState.DatabaseMissing, settings.Trail);

            // a config that needs a password it has not got: the two ways that can end
            var needsPassword = Fresh("MolehillAdmin");
            needsPassword.Connection.Authentication = "SqlLogin";
            needsPassword.Connection.User = "selftest-no-such-login";
            Check("a SQL login with nothing saved asks for the password", needsPassword.NeedsSecretPrompt);

            var gaveUp = new ScriptedPrompts { Secret = _ => null };
            Check("giving up at the password prompt stops there",
                Startup.Connect(gaveUp, needsPassword, path, existed: true, forceSetup: false, loadFailed: false) == null
                && gaveUp.Seen.SequenceEqual(new[] { "password" }), gaveUp.Trail);

            var wantsSettings = new ScriptedPrompts { Secret = _ => "" };     // the "Settings..." button
            Check("Settings at the password prompt opens the full settings screen",
                Startup.Connect(wantsSettings, needsPassword, path, existed: true, forceSetup: false, loadFailed: false) == null
                && wantsSettings.Seen.SequenceEqual(new[] { "password", "settings" }), wantsSettings.Trail);
            Check("and asks for settings, rather than complaining about a password nobody gave",
                wantsSettings.Why?.Contains("Change the settings") == true, wantsSettings.Why ?? "(never asked)");

            var refused = new ScriptedPrompts { Secret = _ => "not the password" };
            Check("a password the server refuses is not saved and not kept",
                Startup.Connect(refused, needsPassword, path, existed: true, forceSetup: false, loadFailed: false) == null
                && needsPassword.Secret == null && refused.Refused != null, refused.Refused ?? refused.Trail);

            // "Save anyway" on a server that never answers: the file is written, and start-up comes
            // straight back for more rather than pretending it connected. Typed once, then closed.
            var typed = 0;
            var anyway = new ScriptedPrompts { SaveUnreachable = true };
            anyway.Fill = d =>
            {
                if (typed++ > 0) return null;
                d.Server = "no-such-server-molehill-test";
                d.Timeout = "3";
                d.OutputFolder = outFolder;
                return d;
            };
            var anywayPath = Path.Combine(folder, "anyway.json");
            var anywayConfig = new AppConfig { OutputFolder = "" };            // incomplete, so the screen opens
            var anywayResult = Startup.Connect(anyway, anywayConfig, anywayPath, existed: false, forceSetup: false, loadFailed: false);
            Check("settings for a server that is not there are written, and asked about again",
                anywayResult == null && anyway.Seen.SequenceEqual(new[] { "settings", "settings" })
                && File.Exists(anywayPath)
                && ConfigStore.Load(anywayPath, out _).Connection.Server == "no-such-server-molehill-test",
                anyway.Trail + " / " + (File.Exists(anywayPath) ? "written" : "not written"));
            Check("and the second time it says it could not connect", anyway.Why?.Contains("Could not connect") == true, anyway.Why ?? "(never asked twice)");

            // a password saved by another Windows user: once new settings are saved, the app must stop
            // asking. Nothing cleared the flag before this was shared, and nothing would have noticed.
            var strangePath = Path.Combine(folder, "strange.json");
            var strange = new AppConfig
            {
                OutputFolder = outFolder,
                Connection = { Server = server, Database = "MolehillAdmin", Authentication = "SqlLogin", User = "someone" }
            };
            ConfigStore.Save(strangePath, strange);
            File.WriteAllText(strangePath, File.ReadAllText(strangePath)
                .Replace("\"User\": \"someone\"", "\"User\": \"someone\",\n    \"PasswordEncrypted\": \"" + Convert.ToBase64String(new byte[64]) + "\""));
            var unreadable = ConfigStore.Load(strangePath, out _);
            Check("a password encrypted by someone else is noticed", unreadable.SecretUnreadable && unreadable.NeedsSecretPrompt);
            var over = new ScriptedPrompts
            {
                Fill = d => { d.Authentication = "Windows"; d.Server = server; d.OutputFolder = outFolder; return d; }
            };
            Check("saving new settings over it stops the app asking for that password",
                Startup.Connect(over, unreadable, strangePath, existed: true, forceSetup: true, loadFailed: false) != null
                && !unreadable.SecretUnreadable && !unreadable.NeedsSecretPrompt
                && !ConfigStore.Load(strangePath, out _).NeedsSecretPrompt,
                over.Refused ?? over.Trail);

            // exactly what Program does next, after the start-up questions: build the main screen and draw it
            Application.Init(new FakeDriver(), null);
            try
            {
                Step("main window builds and draws after start-up (as the app does)", () =>
                {
                    var top = new MainWindow(new AdminDb(cs!), path, () => null, () => 0).CreateTop();
                    Check("main screen has the menu, tabs and status bar", top.Subviews.Count >= 3, top.Subviews.Count.ToString());
                    top.Frame = new Rect(0, 0, 120, 40);
                    Application.Driver.Clip = new Rect(0, 0, 120, 40);
                    Render(top);                                   // draws it, with no main loop to get back out of
                    return 0;
                });
            }
            finally { Application.Shutdown(); }

            Console.WriteLine();
            Console.WriteLine(File.ReadAllText(path));
        }
        finally
        {
            try { Directory.Delete(folder, true); } catch { }
        }
        return Finish();
    }

    /// <summary>
    /// Create / install / upgrade on a real server, driven through start-up by a script. Uses (and then
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

        AppConfig Config(string db) => new() { OutputFolder = folder, Connection = { Server = server, Database = db, Authentication = "Windows" } };
        var master = new AdminDb(new AppConfig { Connection = { Server = server, Database = "master" } }.BuildConnectionString());

        // a person who says yes to installing and fills the business name in. No console, no driver:
        // Fill is left null, so the settings screen opening at all would end the run and fail the step.
        var prompts = new ScriptedPrompts
        {
            FillForm = spec =>
            {
                var v = spec.NewValues();
                v["BusinessName"] = "Selftest Services Ltd";
                return v;
            }
        };
        var seen = prompts.Seen;

        try
        {
            // 1. no database at all
            var a = Config(Db("new"));
            created.Add(a.Connection.Database);
            Check("missing database detected", AdminInstaller.Inspect(a).State == DbState.DatabaseMissing, AdminInstaller.Inspect(a).Message);
            ConfigStore.Save(path, a);
            var cs = Step("start-up creates and installs it", () => Startup.Connect(prompts, a, path, existed: true, forceSetup: false, loadFailed: false),
                r => r != null ? null : "gave up; saw: " + string.Join(" | ", seen));
            Check("asked first, then showed the result and business details",
                seen.Take(3).SequenceEqual(new[] { "Create MolehillAdmin", "MolehillAdmin installed", "Business and invoice details" }), string.Join(" | ", seen));
            Check("database is ready", AdminInstaller.Inspect(a).State == DbState.Ready);
            var adb = new AdminDb(a.BuildConnectionString());
            Check("business details saved", (adb.Scalar("SELECT Value FROM dbo.Setting WHERE Name = 'BusinessName'") as string) == "Selftest Services Ltd");
            Check("install recorded", Convert.ToInt32(adb.Scalar("SELECT COUNT(*) FROM dbo.InstallHistory")) >= 1);
            Check("standard price list seeded", Convert.ToInt32(adb.Scalar("SELECT COUNT(*) FROM dbo.PriceList")) >= 1);
            // the only part of this suite that needs a console at all, now that start-up does not
            Application.Init(new FakeDriver(), null);
            try { Step("the app's screens work on it (after the install, as the app does)", () => { new MainWindow(adb, path, () => null, () => 0).CreateTop(); return 0; }); }
            finally { Application.Shutdown(); }

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
            Step("start-up upgrades it", () => Startup.Connect(prompts, a, path, existed: true, forceSetup: false, loadFailed: false),
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
            Step("start-up installs into it", () => Startup.Connect(prompts, b, path, existed: true, forceSetup: false, loadFailed: false),
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

    /// <summary>
    ///   Every availability rule, as a plain function of the selection: no screen and no database.
    ///   Each check below is one rule that used to live inside a window, where nothing could reach
    ///   it. Both halves matter - that what applies is offered, and that what does not is refused
    ///   with a reason fit to show the user.
    /// </summary>
    private static void RunRules()
    {
        static string Ids(MhActionSet s) => string.Join(" ", s.Actions.Select(a => a.Enabled ? a.Id : $"({a.Id})"));
        static bool On(MhActionSet s, string id) => s.ById(id)?.Enabled == true;
        static bool Off(MhActionSet s, string id, string reasonHas) =>
            s.ById(id) is { Enabled: false, DisabledReason: { } why } && why.Contains(reasonHas, StringComparison.OrdinalIgnoreCase);

        // every set names its actions once, or looking one up by Id would find the wrong one
        var every = new List<MhActionSet>
        {
            ActionRules.NewOnClients(),
            ActionRules.Clients(null, null, false),
            ActionRules.Clients("ST-1", "Acme", false), ActionRules.Clients("CST-1", "Acme", true),
            ActionRules.TicketsTab(null), ActionRules.TicketsTab("MW-1"),
            ActionRules.BillingTab(null, false), ActionRules.BillingTab("INV-1", true), ActionRules.BillingTab("INV-1", false),
            ActionRules.Dashboard(false, null, null), ActionRules.Dashboard(true, "Acme", "ST-1"), ActionRules.Dashboard(true, "Acme", null),
            ActionRules.Instances(null), ActionRules.Instances("SQL01"),
            ActionRules.Onboarding(null), ActionRules.Onboarding("CONTACTS"),
            ActionRules.Contact(null, null, false), ActionRules.Contact(3, "Pat", true), ActionRules.Contact(3, "Pat", false),
            ActionRules.Weekly(),
            ActionRules.Prepaid(null, null, null, null), ActionRules.Prepaid("PP-1", "Open", null, null),
            ActionRules.Prepaid("PP-1", "Cancelled", null, null), ActionRules.Prepaid("PP-1", "Open", "INV-1", 4m),
            ActionRules.AgreementWide("ST-1", false), ActionRules.AgreementWide("ST-1", true),
            ActionRules.EngagementInvoices(null, false), ActionRules.EngagementInvoices("INV-1", true),
            ActionRules.LoggedWork(null, false, null), ActionRules.LoggedWork(7, false, null), ActionRules.LoggedWork(7, true, "INV-1"),
            ActionRules.DaysWorked(null), ActionRules.DaysWorked("01 Nov 2026"),
            ActionRules.EngagementWide("CST-1", false), ActionRules.EngagementWide("CST-1", true)
        };
        var duplicated = every.Where(s => s.Actions.Select(a => a.Id).Distinct().Count() != s.Actions.Count).ToList();
        Check($"all {every.Count} action sets name each action once", duplicated.Count == 0,
            string.Join(" / ", duplicated.Select(Ids)));
        var mute = every.SelectMany(s => s.Actions).Where(a => !a.Enabled && string.IsNullOrWhiteSpace(a.DisabledReason)).ToList();
        Check("every action that cannot be done says why", mute.Count == 0, string.Join(", ", mute.Select(a => a.Id)));

        // a support agreement and consultancy work offer different things
        var support = ActionRules.Clients("ST-1", "Acme", isConsultancy: false);
        var consultancy = ActionRules.Clients("CST-1", "Acme", isConsultancy: true);
        Check("a support agreement offers tickets and pre-paid hours, not finishing the work",
            On(support, "agreement-open") && On(support, "ticket-new") && On(support, "prepaid-sell")
            && support.ById("engagement-complete") == null, Ids(support));
        Check("consultancy work offers logging work and finishing it, not tickets or pre-paid hours",
            On(consultancy, "engagement-open") && On(consultancy, "work-log") && On(consultancy, "engagement-complete")
            && consultancy.ById("ticket-new") == null && consultancy.ById("prepaid-sell") == null, Ids(consultancy));

        // only a draft invoice can have its lines changed
        var draft = ActionRules.BillingTab("INV-1", isDraft: true);
        var sent = ActionRules.BillingTab("INV-1", isDraft: false);
        Check("a draft invoice can have lines added, taken off and adjusted",
            On(draft, "invoice-line-add") && On(draft, "invoice-line-remove") && On(draft, "invoice-adjust"), Ids(draft));
        Check("an invoice that is not a draft cannot, and says so",
            Off(sent, "invoice-line-add", "draft") && Off(sent, "invoice-line-remove", "draft") && Off(sent, "invoice-adjust", "draft")
            && On(sent, "invoice-void") && On(sent, "invoice-paid"), Ids(sent));

        // pre-paid hours: invoiced, used, cancelled
        var fresh = ActionRules.Prepaid("PP-1", "Open", invoice: null, used: null);
        var invoicedPackage = ActionRules.Prepaid("PP-1", "Open", invoice: "INV-9", used: 0m);
        var partUsed = ActionRules.Prepaid("PP-1", "Open", invoice: null, used: 4m);
        var cancelled = ActionRules.Prepaid("PP-1", "Cancelled", invoice: "INV-9", used: 0m);
        // the values come out of a DataRow, where nothing is spelt null: an empty cell is DBNull,
        // and a rule that only tests for null would read every unused package as a used one
        var fromRow = ActionRules.Prepaid("PP-1", "Open", invoice: DBNull.Value, used: DBNull.Value);
        Check("an unused, uninvoiced package can be invoiced on its own or cancelled",
            On(fresh, "prepaid-invoice") && On(fresh, "prepaid-cancel") && On(fresh, "prepaid-update"), Ids(fresh));
        Check("and the same when the empty cells arrive as DBNull, which is how a row gives them",
            On(fromRow, "prepaid-invoice") && On(fromRow, "prepaid-cancel"), Ids(fromRow));
        Check("a package already on an invoice cannot be invoiced again, and names the invoice",
            Off(invoicedPackage, "prepaid-invoice", "INV-9") && On(invoicedPackage, "prepaid-cancel"), Ids(invoicedPackage));
        Check("a part-used package cannot be cancelled, and says how much went",
            Off(partUsed, "prepaid-cancel", "4") && On(partUsed, "prepaid-invoice"), Ids(partUsed));
        Check("a cancelled package can only be looked at",
            On(cancelled, "prepaid-usage") && Off(cancelled, "prepaid-update", "cancelled")
            && Off(cancelled, "prepaid-invoice", "cancelled") && Off(cancelled, "prepaid-cancel", "cancelled"), Ids(cancelled));

        // logged time that is already on an invoice
        var open = ActionRules.LoggedWork(7, invoiced: false, null);
        var billed = ActionRules.LoggedWork(7, invoiced: true, "INV-9");
        Check("time not yet invoiced can be corrected or removed",
            On(open, "entry-correct") && On(open, "entry-remove") && open.ById("entry-invoiced") == null, Ids(open));
        Check("time already on an invoice cannot, and says which invoice to void",
            Off(billed, "entry-correct", "INV-9") && Off(billed, "entry-remove", "INV-9")
            && On(billed, "entry-invoiced"), Ids(billed));

        // a contact is either current or removed, never both
        var currentContact = ActionRules.Contact(3, "Pat", current: true);
        var pastContact = ActionRules.Contact(3, "Pat", current: false);
        Check("a current contact can be removed but not added back",
            On(currentContact, "contact-remove") && Off(currentContact, "contact-readd", "already"), Ids(currentContact));
        Check("a removed contact can be added back but not removed again",
            On(pastContact, "contact-readd") && Off(pastContact, "contact-remove", "not a current"), Ids(pastContact));

        // finished work cannot be finished or cancelled twice
        var running = ActionRules.EngagementWide("CST-1", finished: false);
        var done = ActionRules.EngagementWide("CST-1", finished: true);
        Check("work in progress can be finished or cancelled",
            On(running, "engagement-complete") && On(running, "engagement-cancel"), Ids(running));
        Check("finished work cannot be finished or cancelled again",
            Off(done, "engagement-complete", "already finished") && Off(done, "engagement-cancel", "already finished")
            && On(done, "invoice-new") && On(done, "billing-run"), Ids(done));

        // the dashboard's alert actions
        var noAlert = ActionRules.Dashboard(false, null, null);
        var withAgreement = ActionRules.Dashboard(true, "Acme", "ST-1");
        var noAgreement = ActionRules.Dashboard(true, "Acme", null);
        var noClient = ActionRules.Dashboard(true, null, null);
        Check("with no alert picked, only saving the dashboard is offered",
            Off(noAlert, "alert-show", "pick an alert") && Off(noAlert, "alert-agreement", "pick an alert")
            && On(noAlert, "dashboard-html"), Ids(noAlert));
        Check("an alert about a client with an agreement offers to open it, named",
            On(withAgreement, "alert-agreement") && withAgreement.ById("alert-agreement")!.Label.Contains("Acme's agreement (ST-1)"), Ids(withAgreement));
        Check("an alert whose client has no agreement says that, rather than offering nothing",
            Off(noAgreement, "alert-agreement", "Acme has no agreement") && On(noAgreement, "alert-show"), Ids(noAgreement));
        Check("an alert about no one in particular says that too",
            Off(noClient, "alert-agreement", "not about one client"), Ids(noClient));

        // the pause toggle is one action with two names
        Check("pause and resume are the same action, named for what it will do",
            ActionRules.AgreementWide("ST-1", paused: false).ById("agreement-pause")!.Label.StartsWith("Pause support")
            && ActionRules.AgreementWide("ST-1", paused: true).ById("agreement-pause")!.Label == "Resume support");

        // nothing selected: what is left is the things that need no selection
        Check("with nothing selected a tab still offers what needs no selection",
            ActionRules.Instances(null).Available.Select(a => a.Id).SequenceEqual(new[] { "instance-add" })
            && ActionRules.TicketsTab(null).Available.Select(a => a.Id).SequenceEqual(new[] { "ticket-new" })
            && ActionRules.Prepaid(null, null, null, null).Available.Select(a => a.Id).SequenceEqual(new[] { "prepaid-sell" })
            && ActionRules.LoggedWork(null, false, null).Available.Select(a => a.Id).SequenceEqual(new[] { "work-log" }));
    }

    private static void RunUi(AdminDb db)
    {
        RunRules();
        Step("main window builds and loads every tab", () => { new MainWindow(db).CreateTop(); return 0; });
        // the dashboard's five result sets, each holding what its name says. The screen used to
        // take them by position, so a sixth set or a reordering would have gone unremarked.
        var dash = Step("dashboard returns its five result sets, named", () => Queries.Dashboard(db), d =>
            !d.Alerts.Columns.Contains("Priority") ? "alerts are not the alerts"
            : !d.OpenTickets.Columns.Contains("TicketRef") ? "open tickets are not the tickets"
            : !d.Agreements.Columns.Contains("AgreementRef") ? "agreements are not the agreements"
            : !d.Engagements.Columns.Contains("EngagementRef") ? "engagements are not the engagements"
            : d.Money != null && d.Amount("MonthlyRecurringRevenue") == null ? "money has no recurring revenue in it"
            : null);
        if (dash != null)
            Check("the dashboard's open-ticket count agrees with the Tickets tab",
                dash.OpenTicketCount == Queries.Tickets(db, openOnly: true).Rows.Count,
                $"dashboard {dash.OpenTicketCount}, tab {Queries.Tickets(db, openOnly: true).Rows.Count}");

        var engagements = Queries.Engagements(db, includeEnded: true);
        Check("engagements query", true, $"{engagements.Rows.Count} engagement(s)");
        foreach (DataRow a in engagements.Rows)
        {
            var reference = (string)a["Ref"];
            if ((string)a["Type"] == "Consultancy")
            {
                Step($"engagement window {reference}", () => new EngagementWindow(db, reference).Build());
                Step($"summary {reference}", () => EngagementWindow.Summary(db, reference, includeWork: true), s => s.Contains("not found") ? s : null);
            }
            else
            {
                Step($"agreement window {reference}", () => new AgreementWindow(db, reference).Build());
                Step($"summary {reference}", () => AgreementWindow.Summary(db, reference, includeInstances: true), s => s.Contains("not found") ? s : null);
            }
        }

        // every form builds as a dialog, using real data where the form needs a selection
        var agreements = engagements.Rows.Cast<DataRow>().Where(r => (string)r["Type"] != "Consultancy").ToList();
        var consultancy = engagements.Rows.Cast<DataRow>().FirstOrDefault(r => (string)r["Type"] == "Consultancy");
        var consultancyForms = Array.Empty<FormSpec>();
        var anyRef = agreements.Count > 0 ? (string)agreements[0]["Ref"] : "MWA-0000";
        var anyClient = agreements.Count > 0 ? (string)agreements[0]["Client"] : "Client";
        var anyInstance = agreements.Count > 0 ? Queries.InstanceNames(db, anyRef).FirstOrDefault() ?? "SQL01" : "SQL01";
        var tickets = Queries.Tickets(db, openOnly: false);
        var anyTicket = tickets.Rows.Count > 0 ? (string)tickets.Rows[0]["Ticket"] : "MW-00001";
        var invoices = Queries.Invoices(db, "All");
        var anyInvoice = invoices.Rows.Count > 0 ? (string)invoices.Rows[0]["Invoice"] : "INV-0001";

        // Everything offered has code behind its Id. Matching a chosen action by its label used to
        // mean a renamed or repeated label ran the wrong thing, silently; a missing handler now
        // fails here rather than when someone picks it.
        var missing = new List<string>();
        void Covered(string where, MhActionSet set, IReadOnlyDictionary<string, Action> handlers)
        {
            foreach (var a in set.Available.Where(a => !handlers.ContainsKey(a.Id))) missing.Add($"{where}: {a.Id}");
        }
        var main = new MainWindow(db);
        main.CreateTop();
        for (var i = 0; i < 4; i++)
        {
            var (set, handlers) = main.ActionsOn(i);
            Covered($"main tab {i + 1}", set, handlers);
        }
        if (agreements.Count > 0)
        {
            var aw = new AgreementWindow(db, anyRef);
            aw.Build();
            foreach (var tab in aw.Tabs.ToList())
            {
                var (set, handlers) = aw.ActionsOn(tab);
                Covered($"agreement {tab.Text}", set, handlers);
            }
        }
        if (consultancy != null)
        {
            var ew = new EngagementWindow(db, (string)consultancy["Ref"]);
            ew.Build();
            foreach (var tab in ew.Tabs.ToList())
            {
                var (set, handlers) = ew.ActionsOn(tab);
                Covered($"engagement {tab.Text}", set, handlers);
            }
        }
        Check("every action the screens offer has code behind its Id", missing.Count == 0, string.Join(", ", missing));

        var everyForm = AllForms(db, anyRef, anyClient, anyInstance, anyTicket, anyInvoice).ToList();
        foreach (var spec in everyForm)
            Step($"form '{spec.Title}' builds", () => { using var d = FormDialog.Create(spec, out _); return 0; });

        // and the same specs in the window. This is the suite with a database to build them from,
        // and it also settles whether the two frameworks' Applications can share a process: this
        // one has already called Terminal.Gui's Application.Init with the fake driver.
        RealFormsLayOut(everyForm);

        if (consultancy != null)
        {
            var conRef = (string)consultancy["Ref"];
            consultancyForms = new[] { AdminForms.LogWork(db, conRef), AdminForms.CompleteEngagement(db, conRef), AdminForms.EditEngagement(db, conRef) };
            foreach (var spec in new[] { AdminForms.LogWork(db, conRef), AdminForms.EditEngagement(db, conRef),
                                         AdminForms.CompleteEngagement(db, conRef), AdminForms.CancelEngagement(db, conRef), AdminForms.NewInvoice(db, conRef) })
                Step($"form '{spec.Title}' builds", () => { using var d = FormDialog.Create(spec, out _); return 0; });
        }

        if (tickets.Rows.Count > 0) Step($"ticket detail {anyTicket}", () => TicketActions.Describe(db, anyTicket));
        if (invoices.Rows.Count > 0) Step($"invoice lines {anyInvoice}", () => Queries.InvoiceLines(db, anyInvoice));

        // MM_SCREENS=<file>: render the screens into the fake console and write them out as text, for checking layout
        var dump = Environment.GetEnvironmentVariable("MM_SCREENS");
        if (!string.IsNullOrEmpty(dump))
            DumpScreens(db, dump, anyRef, AllForms(db, anyRef, anyClient, anyInstance, anyTicket, anyInvoice).Concat(consultancyForms));
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
        if (Queries.Engagements(db, includeEnded: true).Rows.Cast<DataRow>().FirstOrDefault(r => (string)r["Type"] == "Consultancy") is { } con)
        {
            var window = new EngagementWindow(db, (string)con["Ref"]).Build();
            window.X = 0; window.Y = 0; window.Width = 131; window.Height = 39;
            var conTabs = FindAll<TabView>(window).First();
            foreach (var tab in conTabs.Tabs.ToList())
            {
                conTabs.SelectedTab = tab;
                window.Frame = new Rect(0, 0, 131, 39);
                Render(window);
                sb.AppendLine($"===== engagement: {tab.Text}").AppendLine(Screen());
            }
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
        AdminForms.RespondTicket(db, ticket), AdminForms.EstimateTicket(db, ticket), AdminForms.LogTime(db, ticket), AdminForms.SetTicketRate(db, ticket),
        AdminForms.EditTimeEntry(db, db.Scalar("SELECT TOP (1) TimeEntryId FROM dbo.TimeEntry ORDER BY TimeEntryId;") is int te ? te : 0),
        AdminForms.DeleteTimeEntry(db, db.Scalar("SELECT TOP (1) TimeEntryId FROM dbo.TimeEntry ORDER BY TimeEntryId;") is int te2 ? te2 : 0),
        AdminForms.CloseTicket(db, ticket),
        AdminForms.RunBilling(db), AdminForms.AdjustInvoice(db, invoice), AdminForms.SetInvoiceStatus(db, invoice, "Paid"),
        AdminForms.BusinessDetails(db), AdminForms.SellPrepaid(db, reference),
        AdminForms.NewEngagement(db, client), AdminForms.NewInvoice(db), AdminForms.AddInvoiceLine(db, invoice),
        AdminForms.RemoveInvoiceLine(db, invoice, 0, "a line")
    }).Concat(db.Scalar("SELECT TOP (1) PackageRef FROM dbo.PrepaidPackage;") is string pk
        ? new[] { AdminForms.UpdatePrepaid(db, pk), AdminForms.CancelPrepaid(db, pk) } : Array.Empty<FormSpec>());
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
        // what the main window reads back to offer "open it now and add the instances"
        Step("the agreement it created can be picked out of what it said", () => Submit(AdminForms.NewClient(db),
                ("ClientName", name + " II"), ("StartDate", D(start)), ("AgreementRef", reference + "-II")),
            r => AdminForms.CreatedAgreementRef(r) != reference + "-II" ? AdminForms.CreatedAgreementRef(r) ?? "(nothing)"
                 // one set names it, so which one is picked cannot matter. Say so here: if a
                 // procedure ever reports the reference twice, this is where someone decides.
                 : r.Tables.Count(t => t.Columns.Contains("AgreementRef")) is var named && named != 1
                   ? $"{named} result sets name an agreement, so which one is read now matters" : null);

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
            ("WorkStart", raised.Date.AddHours(20).ToString("yyyy-MM-dd HH:mm")), ("RateType", "Out of hours")));
        Step("time recorded", () => Queries.TimeEntries(db, ticket), t => t.Rows.Count == 2 && (string)t.Rows[0]["Rate"] == "BusinessHours" ? null : "wrong entries");

        // the ticket's rate decides, not the clock: a normal ticket worked at 21:00 is still business hours
        var late = Step("open a normal ticket in the evening", () => Submit(AdminForms.OpenTicket(db, reference), ("Title", "Evening question"),
            ("RaisedAt", raised.Date.AddHours(21).ToString("yyyy-MM-dd HH:mm"))), r => r.First is { Rows.Count: 1 } ? null : "no ticket");
        var lateRef = late?.First?.Rows[0]["TicketRef"] as string ?? "MW-?";
        Step("its rate defaults to business hours", () => Queries.Ticket(db, lateRef)!, r => (string)r["RateType"] == "BusinessHours" ? null : (string)r["RateType"]);
        Step("time logged late in the day stays business hours", () => Submit(AdminForms.LogTime(db, lateRef), ("Minutes", "20"), ("Description", "Answered"),
            ("WorkStart", raised.Date.AddHours(21).ToString("yyyy-MM-dd HH:mm")), ("IsBillable", "0")));   // not billable: keeps the billing figures below unchanged
        Step("recorded at the business-hours rate", () => Queries.TimeEntries(db, lateRef), t => (string)t.Rows[0]["Rate"] == "BusinessHours" ? null : (string)t.Rows[0]["Rate"]);
        Step("change the ticket to out of hours, re-rating its time", () => Submit(AdminForms.SetTicketRate(db, lateRef), ("RateType", "Out of hours")));
        Step("its time is now out of hours", () => Queries.TimeEntries(db, lateRef), t => (string)t.Rows[0]["Rate"] == "OutOfHours" ? null : (string)t.Rows[0]["Rate"]);
        Step("back to business hours", () => Submit(AdminForms.SetTicketRate(db, lateRef), ("RateType", "Business hours")));
        var planned = Step("planned out-of-hours ticket", () => Submit(AdminForms.OpenTicket(db, reference), ("Title", "Tier change"), ("WorkType", "PlannedOutOfHours"),
            ("RaisedAt", raised.ToString("yyyy-MM-dd HH:mm"))), r => r.First is { Rows.Count: 1 } ? null : "no ticket");
        Step("defaults to out of hours", () => Queries.Ticket(db, planned?.First?.Rows[0]["TicketRef"] as string ?? "?")!,
            r => (string)r["RateType"] == "OutOfHours" ? null : (string)r["RateType"]);
        Step("close the planned ticket unworked", () => Submit(AdminForms.CloseTicket(db, planned?.First?.Rows[0]["TicketRef"] as string ?? "?"), ("Resolution", "Cancelled"), ("Status", "Closed")));

        // time dated outside the agreement's billing period: never billed, and fixable
        var strayDate = start.AddDays(-30).Date.AddHours(10);
        var stray = Step("ticket with work dated before the agreement", () => Submit(AdminForms.OpenTicket(db, reference), ("Title", "Wrong date"),
            ("RaisedAt", strayDate.ToString("yyyy-MM-dd HH:mm"))), r => r.First is { Rows.Count: 1 } ? null : "no ticket");
        var strayRef = stray?.First?.Rows[0]["TicketRef"] as string ?? "MW-?";
        Step("log 2 hours on the wrong date", () => Submit(AdminForms.LogTime(db, strayRef), ("Minutes", "120"), ("Description", "Dated wrongly"),
            ("WorkStart", strayDate.ToString("yyyy-MM-dd HH:mm"))),
            r => r.Messages.Any(m => m.Contains("NEVER be invoiced")) ? null : "no warning: " + string.Join(" | ", r.Messages));
        Step("the entry says it will never be invoiced", () => Queries.TimeEntries(db, strayRef),
            t => ((string)t.Rows[0]["Invoiced"]).StartsWith("NEVER") ? null : (string)t.Rows[0]["Invoiced"]);
        Step("the dashboard flags it", () => db.Proc("dbo.usp_Dashboard", ("@AlertsOnly", true)),
            r => r.First!.Rows.Cast<DataRow>().Any(a2 => ((string)a2["Item"]).StartsWith("Time logged outside the billing period: " + strayRef)) ? null : "not flagged");
        var strayId = (int)Queries.TimeEntries(db, strayRef).Rows[0]["Id"];
        Step("correct the date", () => Submit(AdminForms.EditTimeEntry(db, strayId), ("WorkStart", raised.AddDays(1).ToString("yyyy-MM-dd HH:mm"))));
        Step("now waiting for the next billing run", () => Queries.TimeEntries(db, strayRef),
            t => (string)t.Rows[0]["Invoiced"] == "at the next billing run" ? null : (string)t.Rows[0]["Invoiced"]);
        Step("summary shows time not yet billed", () => AgreementWindow.Summary(db, reference, false),
            s2 => s2.Contains("logged but not yet billed") ? null : "not shown");
        Step("remove the entry again", () => Submit(AdminForms.DeleteTimeEntry(db, strayId)));
        Step("it is gone", () => Queries.TimeEntries(db, strayRef), t => t.Rows.Count == 0 ? null : $"{t.Rows.Count} left");
        Step("close that ticket", () => Submit(AdminForms.CloseTicket(db, strayRef), ("Resolution", "Logged in error"), ("Status", "Closed")));
        Step("close", () => Submit(AdminForms.CloseTicket(db, ticket), ("Resolution", "Added two indexes")));
        Step("ticket detail", () => TicketActions.Describe(db, ticket), s => s.Contains("Added two indexes") && s.Contains("Index review") ? null : "detail incomplete");
        Step("project quote", () => Submit(AdminForms.AddQuote(db, reference), ("Title", "Upgrade to 2022"), ("EstimatedHours", "12"), ("TicketRef", ticket)));

        // pre-paid hours, bought at the start; more business-hours work so some of it goes beyond the included hours
        var more = raised.Date.AddDays(1).AddHours(10);
        while (more.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday) more = more.AddDays(1);
        var tuning = Step("more business-hours work in the first cycle", () => Submit(AdminForms.OpenTicket(db, reference), ("Title", "Index tuning"),
            ("RaisedAt", more.ToString("yyyy-MM-dd HH:mm"))), r => r.First is { Rows.Count: 1 } ? null : "no ticket");
        var extraRef = tuning?.First?.Rows[0]["TicketRef"] as string ?? "MW-?";
        Step("log 150 minutes (with the earlier 90, one hour past the included three)", () => Submit(AdminForms.LogTime(db, extraRef), ("Minutes", "150"),
            ("Description", "Tuning"), ("WorkStart", more.ToString("yyyy-MM-dd HH:mm"))));
        Step("sell pre-paid hours (charged on the next monthly invoice)", () => Submit(AdminForms.SellPrepaid(db, reference),
                ("Hours", "5"), ("HourlyRate", "60"), ("ValidMonths", "12"), ("PurchasedOn", D(start))),
            r => r.First is { Rows.Count: 1 } t && (decimal)t.Rows[0]["Price"] == 300m && t.Rows[0]["InvoiceNo"] is DBNull ? null : "package or invoice wrong");
        var package = (string)Queries.Prepaid(db, reference).Rows[0]["Ref"];
        Step("it says where it will be charged", () => Queries.Prepaid(db, reference),
            t => (string)t.Rows[0]["Charging"] == "on the next monthly invoice" ? null : (string)t.Rows[0]["Charging"]);
        ExpectError("sell pre-paid hours: expiry and months together refused", () => Submit(AdminForms.SellPrepaid(db, reference), ("Hours", "5"), ("HourlyRate", "60"),
            ("ValidMonths", "12"), ("ExpiresOn", D(DateTime.Today.AddMonths(6)))), "not both");
        Step("sell a second package the client has already paid for", () => Submit(AdminForms.SellPrepaid(db, reference),
            ("Hours", "2"), ("HourlyRate", "55"), ("BillWith", "Not at all - already paid for")));
        var spare = Queries.Prepaid(db, reference).Rows.Cast<DataRow>().Select(r => (string)r["Ref"]).First(r => r != package);
        Step("cancel the unused package", () => Submit(AdminForms.CancelPrepaid(db, spare), ("Reason", "Self-test")));
        Step("cancelled", () => Queries.Prepaid(db, reference), t => t.Rows.Cast<DataRow>().Any(r => (string)r["Ref"] == spare && (string)r["State"] == "Cancelled") ? null : "not cancelled");

        // billing
        var billed = Step("run billing for the agreement", () => Submit(AdminForms.RunBilling(db),
                ("Client", Queries.EngagementChoices(db, consultancyOnly: false).First(c => Queries.RefFromChoice(c) == reference))),
            r => r.First is { Rows.Count: > 0 } ? null : "no invoices created");
        var invoice = billed?.First?.Rows[0]["InvoiceNo"] as string ?? "?";
        Step("first invoice charges the first month (instances named during onboarding)", () => Queries.InvoiceLines(db, invoice),
            t => t.Rows.Cast<DataRow>().Count(r => (string)r["Type"] == "MonthlyFee") == 7 ? null : $"{t.Rows.Cast<DataRow>().Count(r => (string)r["Type"] == "MonthlyFee")} fee lines");
        Step("instance added after the first invoice is covered from today", () => { Submit(add(), ("InstanceName", "ST-SQL04")); return Queries.Instance(db, reference, "ST-SQL04")!; },
            r => (DateTime)r["CoveredFrom"] == DateTime.Today ? null : $"covered from {r["CoveredFrom"]}");
        Step("the hour past the included hours came out of the pre-paid hours", () => Queries.Prepaid(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Ref"] == package && (decimal)r["Left"] == 4m) ? null
                 : "left: " + string.Join(", ", t.Rows.Cast<DataRow>().Select(r => $"{r["Ref"]} {r["Left"]}")));
        Step("usage shows the ticket it went on", () => Queries.PrepaidUsage(db, package),
            t => t.Rows.Count == 1 && (string)t.Rows[0]["Ticket"] == extraRef && (decimal)t.Rows[0]["Hours"] == 1m ? null : $"{t.Rows.Count} rows");
        Step("the out-of-hours time was billed at the out-of-hours rate, not taken from the package", () => db.Query("""
                SELECT l.Quantity, l.UnitPrice FROM dbo.InvoiceLine l JOIN dbo.vw_Invoice i ON i.InvoiceId = l.InvoiceId
                WHERE i.AgreementRef = @r AND l.LineType = 'OutOfHours';
                """, ("@r", reference)),
            t => t.Rows.Count == 1 && (decimal)t.Rows[0]["Quantity"] == 1m && (decimal)t.Rows[0]["UnitPrice"] == 115m ? null : $"{t.Rows.Count} OOH lines");
        Step("extend the expiry", () => Submit(AdminForms.UpdatePrepaid(db, package), ("ExpiresOn", D(DateTime.Today.AddYears(2)))));
        Step("the package was charged on the monthly invoice, not one of its own", () => Queries.InvoiceLines(db, invoice),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Type"] == "PrepaidPurchase" && (decimal)r["Amount"] == 300m) ? null : "no package line on the cycle invoice");
        Step("and the package now points at that invoice", () => Queries.Prepaid(db, reference),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Ref"] == package && (string)r["Invoice"] == invoice) ? null : "not linked");
        ExpectError("changing how an invoiced package is charged is refused",
            () => Submit(AdminForms.UpdatePrepaid(db, package), ("BillWith", "Not at all - already paid for")), "already on invoice");
        ExpectError("cancel a package in use refused", () => Submit(AdminForms.CancelPrepaid(db, package)), "already been used");
        Step("summary shows pre-paid hours left", () => AgreementWindow.Summary(db, reference, false), s => s.Contains("pre-paid hours left: 4") ? null : "not shown");
        Step("billing again creates nothing", () => Submit(AdminForms.RunBilling(db),
                ("Client", Queries.EngagementChoices(db, consultancyOnly: false).First(c => Queries.RefFromChoice(c) == reference))),
            r => r.First is { Rows.Count: 0 } ? null : $"{r.First?.Rows.Count} more invoice(s)");
        Step("adjustment", () => Submit(AdminForms.AdjustInvoice(db, invoice), ("Description", "Goodwill credit"), ("Amount", "-10")));
        Step("invoice lines include the credit", () => Queries.InvoiceLines(db, invoice),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Type"] == "Adjustment" && (decimal)r["Amount"] == -10m) ? null : "no adjustment line");
        var folder = Path.Combine(Path.GetTempPath(), "MolehillManager-selftest");
        Step("invoice HTML saved", () => AdminForms.SaveInvoiceHtml(db, invoice, folder), p => File.ReadAllText(p).Contains(invoice) ? null : "HTML lacks invoice number");
        Step("invoice is addressed to the contact that receives invoices, not the ticket contact", () => File.ReadAllText(Path.Combine(folder, invoice + ".html")),
            h => h.Contains("For the attention of Accounts") && !h.Contains("Pat Tester") ? null : "wrong recipients");
        Step("invoice carries the logo and the brand", () => File.ReadAllText(Path.Combine(folder, invoice + ".html")),
            h => h.Contains("src=\"data:image/png;base64,") && h.Contains("#44C8F5") && h.Contains("Krungthep") ? null : "brand missing");
        Step("dashboard HTML saved", () => AdminForms.SaveDashboardHtml(db, folder), p => File.ReadAllText(p).Contains("<html", StringComparison.OrdinalIgnoreCase) ? null : "not HTML");
        Step("mark sent", () => Submit(AdminForms.SetInvoiceStatus(db, invoice, "Sent")));
        Step("mark paid", () => Submit(AdminForms.SetInvoiceStatus(db, invoice, "Paid")));
        Step("invoice is paid", () => Queries.Invoices(db, "All"), t => t.Rows.Cast<DataRow>().Any(r => (string)r["Invoice"] == invoice && (string)r["Status"] == "Paid") ? null : "not paid");
        ExpectError("adjusting a paid invoice is refused", () => Submit(AdminForms.AdjustInvoice(db, invoice), ("Description", "x"), ("Amount", "1")), "draft");

        // consultancy: a day-rate engagement for the same client, invoiced monthly in arrears
        var lastMonth = new DateTime(DateTime.Today.Year, DateTime.Today.Month, 1).AddMonths(-1);
        var conRef = $"CST-{stamp}";
        Step("new consultancy engagement", () => Submit(AdminForms.NewEngagement(db, name), ("ClientName", name), ("Name", "Warehouse migration"),
                ("BillingMode", "Day rate"), ("DayRate", "600"), ("StartDate", D(lastMonth)), ("PurchaseOrder", "PO-1234"), ("EngagementRef", conRef)),
            r => r.First is { Rows.Count: 1 } t && (string)t.Rows[0]["EngagementRef"] == conRef ? null : "engagement not returned");
        Step("log a full day", () => Submit(AdminForms.LogWork(db, conRef), ("WorkDate", D(lastMonth.AddDays(1))), ("Days", "1"), ("Description", "Discovery")));
        Step("log three hours the next day", () => Submit(AdminForms.LogWork(db, conRef), ("WorkDate", D(lastMonth.AddDays(2))), ("Hours", "3"), ("Description", "Schema review")));
        Step("log two hours and three more the day after", () =>
        {
            Submit(AdminForms.LogWork(db, conRef), ("WorkDate", D(lastMonth.AddDays(3))), ("Hours", "2"), ("Description", "ETL rewrite"));
            return Submit(AdminForms.LogWork(db, conRef), ("WorkDate", D(lastMonth.AddDays(3))), ("Hours", "3"), ("Description", "ETL testing"));
        });
        Step("three hours bills as half a day; two plus three on one day bills as a whole one", () => Queries.ConsultancyWork(db, conRef),
            t => t.Rows.Count == 3 && t.Rows.Cast<DataRow>().Sum(r => (decimal)r["Days"]) == 2.5m ? null
                 : string.Join(", ", t.Rows.Cast<DataRow>().Select(r => $"{Output.Format(r["Date"])} {r["Days"]}")));
        Step("non-billable work is logged but not charged", () => Submit(AdminForms.LogWork(db, conRef),
            ("WorkDate", D(lastMonth.AddDays(4))), ("Hours", "1"), ("Description", "Internal write-up"), ("IsBillable", "0")));
        Step("summary counts 2.5 days waiting to be invoiced", () => EngagementWindow.Summary(db, conRef, includeWork: false),
            s2 => s2.Contains("2.50 days (£1,500.00) not invoiced") ? null : s2.Split('\n').FirstOrDefault(l => l.Contains("not invoiced")) ?? "no line");
        var conChoice = Queries.EngagementChoices(db).First(c => Queries.RefFromChoice(c) == conRef);
        var conBilled = Step("run billing for the engagement", () => Submit(AdminForms.RunBilling(db), ("Client", conChoice)),
            r => r.First is { Rows.Count: 1 } t && (decimal)t.Rows[0]["Total"] == 1500m ? null
                 : $"{r.First?.Rows.Count} invoice(s), total {r.First?.Rows.Cast<DataRow>().FirstOrDefault()?["Total"]}");
        var conInvoice = conBilled?.First?.Rows[0]["InvoiceNo"] as string ?? "?";
        Step("one line per day worked, plus the period it covers", () => Queries.InvoiceLines(db, conInvoice),
            t => t.Rows.Cast<DataRow>().Count(r => (string)r["Type"] == "Consultancy") == 3
                 && t.Rows.Cast<DataRow>().Any(r => (string)r["Type"] == "Info" && ((string)r["Description"]).StartsWith("Work done "))
                 ? null : string.Join(", ", t.Rows.Cast<DataRow>().Select(r => (string)r["Type"])));
        Step("it is dated the last day of the billing period", () => Queries.EngagementInvoices(db, conRef),
            t => (DateTime)t.Rows[0]["Dated"] == lastMonth.AddDays(13) ? null : $"dated {t.Rows[0]["Dated"]}, expected {lastMonth.AddDays(13):d}");
        Step("the invoice names the engagement and the client's PO", () => AdminForms.SaveInvoiceHtml(db, conInvoice, Path.Combine(Path.GetTempPath(), "MolehillManager-selftest")),
            p => File.ReadAllText(p) is var h && h.Contains(conRef) && h.Contains("PO-1234") && h.Contains("Warehouse migration") ? null : "engagement not on the invoice");
        Step("billing again invoices nothing twice", () => Submit(AdminForms.RunBilling(db), ("Client", conChoice)),
            r => r.First is { Rows.Count: 0 } ? null : $"{r.First?.Rows.Count} more invoice(s)");
        Step("nothing left unbilled", () => Queries.Engagement(db, conRef)!, r => (decimal)r["UnbilledDays"] == 0m ? null : $"{r["UnbilledDays"]} days");
        ExpectError("an invoiced engagement cannot be cancelled", () => Submit(AdminForms.CancelEngagement(db, conRef), ("Reason", "Self-test")), "cannot be cancelled");
        Step("rate change applies to work not yet invoiced", () => Submit(AdminForms.EditEngagement(db, conRef), ("DayRate", "650")));
        Step("this month's work uses the new rate", () => { Submit(AdminForms.LogWork(db, conRef), ("WorkDate", D(DateTime.Today)), ("Days", "1"), ("Description", "Cutover")); return Queries.Engagement(db, conRef)!; },
            r => (decimal)r["UnbilledValue"] == 650m ? null : $"£{r["UnbilledValue"]}");
        var periodEnd = (DateTime)db.Scalar("""
            SELECT DATEADD(day, -1, dbo.fn_ConsultancyPeriodStart(e.StartDate,
                   dbo.fn_ConsultancyPeriod(e.StartDate, CAST(dbo.fn_UkNow() AS date), dbo.fn_EngagementBillingDays(e.EngagementId)) + 1,
                   dbo.fn_EngagementBillingDays(e.EngagementId)))
            FROM dbo.Engagement e WHERE e.EngagementRef = @r;
            """, ("@r", conRef))!;
        Step($"the period running now (to {periodEnd:dd MMM}) is only invoiced once it ends", () => Submit(AdminForms.RunBilling(db), ("Client", conChoice)),
            r => (r.First?.Rows.Count > 0) == (periodEnd <= DateTime.Today) ? null
                 : $"{r.First?.Rows.Count} invoice(s) with the period ending {periodEnd:d}");

        // finishing: the form starts on the engagement's end date, and so does the procedure
        var conEnd = DateTime.Today.AddDays(-3);
        Step("give the engagement an end date", () => Submit(AdminForms.EditEngagement(db, conRef), ("EndDate", D(conEnd))));
        Step("the finish form starts on that date", () => AdminForms.CompleteEngagement(db, conRef),
            f => f.Fields.First(x => x.Name == "CompletedOn").Default == D(conEnd) ? null
                 : $"starts on '{f.Fields.First(x => x.Name == "CompletedOn").Default}'");
        Step("finishing with no date given uses it", () => Submit(AdminForms.CompleteEngagement(db, conRef)));
        Step("finished on the end date", () => Queries.Engagement(db, conRef)!,
            r => r["CompletedOn"] is DateTime c && c.Date == conEnd ? null : $"finished {r["CompletedOn"]}");
        Step("anything left goes out dated then, and nothing is left unbilled", () => Submit(AdminForms.RunBilling(db), ("Client", conChoice)),
            r => r.First!.Rows.Cast<DataRow>().Any(x => (DateTime)x["InvoiceDate"] != conEnd) ? "invoice not dated on the finish date"
                 : (decimal)Queries.Engagement(db, conRef)!["UnbilledDays"] == 0m ? null : "days left unbilled");

        /* per-instance work: a health check sold by the server. The price is worked out from the
           count, so the sums are what can go wrong - and the cap only shows itself at a count high
           enough to pass it. */
        var piRef = $"PIN-{stamp}";
        Step("new per-instance engagement", () => Submit(AdminForms.NewEngagement(db, name), ("ClientName", name),
                ("Name", "SQL Server health check"), ("BillingMode", "Per instance"),
                ("FirstUnitPrice", "1450"), ("ExtraUnitPrice", "350"), ("UnitCount", "3"), ("PriceCap", "3500"),
                ("StartDate", D(DateTime.Today)), ("EngagementRef", piRef)),
            r => r.First is { Rows.Count: 1 } t2 && (string)t2.Rows[0]["EngagementRef"] == piRef ? null : "engagement not returned");
        Step("three instances price at 1450 + 2 x 350", () => Queries.Engagement(db, piRef)!,
            r => (decimal)r["UnitTotal"] == 2150m ? null : $"£{r["UnitTotal"]}");
        Step("the summary shows how the price is built", () => EngagementWindow.Summary(db, piRef, includeWork: false),
            s2 => s2.Contains("£2,150.00 for 3 instance(s)") && s2.Contains("£1,450.00 first, then £350.00 each")
                  && s2.Contains("capped at £3,500.00") && s2.Contains("Invoiced when you mark it finished")
                  ? null : s2.Split('\n').Skip(1).FirstOrDefault() ?? "no line");
        var piChoice = Queries.EngagementChoices(db).First(c => Queries.RefFromChoice(c) == piRef);
        Step("nothing is invoiced until it is finished", () => Submit(AdminForms.RunBilling(db), ("Client", piChoice)),
            r => r.First is { Rows.Count: 0 } ? null : $"{r.First?.Rows.Count} invoice(s) raised early");
        /* The days a health check took are still worth recording, they are just not what the client
           is charged for. Logging some is what makes the fortnightly billing visible by its absence:
           without it there is nothing for a period to invoice and the mode is never really tested. */
        Step("the days it took are logged, but they are not what is billed", () =>
            { Submit(AdminForms.LogWork(db, piRef), ("WorkDate", D(DateTime.Today)), ("Days", "2"), ("Description", "Collection and write-up")); return Queries.Engagement(db, piRef)!; },
            r => (decimal)r["TotalDays"] == 2m && r["PeriodEndsOn"] is DBNull ? null
                 : $"{r["TotalDays"]} days, period ends {r["PeriodEndsOn"]}");
        Step("two weeks of work does not raise a fortnightly invoice", () => Submit(AdminForms.RunBilling(db), ("Client", piChoice)),
            r => r.First is { Rows.Count: 0 } ? null : $"{r.First?.Rows.Count} invoice(s) raised by the period");
        Step("and the dashboard does not chase it as unbilled work", () => db.Proc("dbo.usp_Dashboard", ("@AlertsOnly", true)),
            r => r.First!.Rows.Cast<DataRow>().Any(a2 => ((string)a2["Item"]).StartsWith("Unbilled work: " + piRef))
                 ? "listed as unbilled work, but it is invoiced on completion" : null);
        Step("a bigger estate is capped, not charged per instance for ever", () =>
            { Submit(AdminForms.EditEngagement(db, piRef), ("UnitCount", "10")); return Queries.Engagement(db, piRef)!; },
            r => (decimal)r["UnitTotal"] == 3500m ? null : $"£{r["UnitTotal"]} for 10, expected the £3,500 cap");
        ExpectError("an estate of none is refused", () => Submit(AdminForms.EditEngagement(db, piRef), ("UnitCount", "0")), "1 or more");
        Step("finish it", () => Submit(AdminForms.CompleteEngagement(db, piRef), ("CompletedOn", D(DateTime.Today))));
        var piBilled = Step("the completion invoice is the capped total", () => Submit(AdminForms.RunBilling(db), ("Client", piChoice)),
            r => r.First is { Rows.Count: 1 } t2 && (decimal)t2.Rows[0]["Total"] == 3500m ? null
                 : $"{r.First?.Rows.Count} invoice(s), total {r.First?.Rows.Cast<DataRow>().FirstOrDefault()?["Total"]}");
        var piInvoice = piBilled?.First?.Rows[0]["InvoiceNo"] as string ?? "?";
        Step("it shows the first instance, the other nine, and what the cap took off", () => Queries.InvoiceLines(db, piInvoice),
            t2 =>
            {
                var l = t2.Rows.Cast<DataRow>().ToList();
                var first = l.FirstOrDefault(r => ((string)r["Description"]).Contains("first SQL Server instance"));
                var extra = l.FirstOrDefault(r => ((string)r["Description"]).Contains("further instance"));
                var cap = l.FirstOrDefault(r => (string)r["Type"] == "Adjustment");
                return first != null && (decimal)first["Amount"] == 1450m
                       && extra != null && (decimal)extra["Qty"] == 9m && (decimal)extra["Amount"] == 3150m
                       && cap != null && (decimal)cap["Amount"] == -1100m
                       ? null : string.Join(" | ", l.Select(r => $"{r["Type"]} {r["Qty"]}x{r["Price"]}={r["Amount"]}"));
            });
        Step("billing again raises nothing twice", () => Submit(AdminForms.RunBilling(db), ("Client", piChoice)),
            r => r.First is { Rows.Count: 0 } ? null : $"{r.First?.Rows.Count} more invoice(s)");
        ExpectError("a per-instance engagement with no first-instance price is refused", () =>
            Submit(AdminForms.NewEngagement(db, name), ("ClientName", name), ("Name", "No price"),
                   ("BillingMode", "Per instance"), ("EngagementRef", $"PIX-{stamp}")), "FirstUnitPrice");

        // an invoice typed by hand
        var typed = Step("new invoice typed by hand", () => Submit(AdminForms.NewInvoice(db), ("ClientName", name)),
            r => r.First is { Rows.Count: 1 } ? null : "no invoice");
        var typedNo = typed?.First?.Rows[0]["InvoiceNo"] as string ?? "?";
        Step("add a quantity x price line", () => Submit(AdminForms.AddInvoiceLine(db, typedNo), ("Description", "SQL Server licence"), ("Quantity", "3"), ("UnitPrice", "120")));
        Step("add a flat amount", () => Submit(AdminForms.AddInvoiceLine(db, typedNo), ("Description", "Courier"), ("Amount", "40")));
        Step("it totals 400", () => Queries.Invoices(db, "All"),
            t => t.Rows.Cast<DataRow>().Any(r => (string)r["Invoice"] == typedNo && (decimal)r["Total"] == 400m) ? null : "wrong total");
        Step("remove the courier line", () =>
        {
            var line = Queries.InvoiceLines(db, typedNo).Rows.Cast<DataRow>().First(r => (string)r["Description"] == "Courier");
            return Submit(AdminForms.RemoveInvoiceLine(db, typedNo, (int)line["Id"], "Courier"));
        }, r => r.First is { Rows.Count: 1 } t && (decimal)t.Rows[0]["Total"] == 360m ? null : "still there");
        ExpectError("a line the billing run made cannot be picked off", () =>
        {
            var day = Queries.InvoiceLines(db, conInvoice).Rows.Cast<DataRow>().First(r => (string)r["Type"] == "Consultancy");
            Submit(AdminForms.RemoveInvoiceLine(db, conInvoice, (int)day["Id"], "a day of work"));
        }, "billing run");

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

            // F4 lists what fits the tab and row showing
            var aw = new AgreementWindow(db, reference);
            aw.Build();
            foreach (var tab in aw.Tabs.ToList())
            {
                var labels = aw.ActionLabels(tab);
                var tabName = tab.Text.ToString();
                var expected = tabName switch
                {
                    "Instances" => "Update versions",
                    "Onboarding" => "Mark '",
                    "Contacts" => "Edit details",
                    "Tickets" => "Change rate",
                    "Weekly reports" => "Log a weekly report",
                    _ => "Where the hours went"
                };
                Check($"agreement F4 on {tabName}: {labels[0]}", labels.Skip(1).Any(l => l.StartsWith(expected))
                      && !labels.Any(l => l.StartsWith("Pause support") || l.StartsWith("Notice")), string.Join(" | ", labels.Skip(1)));
            }
            var mw = new MainWindow(db);
            mw.CreateTop();
            var mainExpect = new[] { "Save the dashboard", "Open the agreement", "Change rate", "Mark paid" };
            for (var i = 0; i < 4; i++)
            {
                var labels = mw.ActionLabels(i);
                Check($"main F4 on tab {i + 1}: {labels[0]}", labels.Skip(1).Any(l => l.StartsWith(mainExpect[i])), string.Join(" | ", labels.Skip(1)));
            }
            Submit(AdminForms.RemoveContact(db, SamId()), ("Reason", "Toggle test"));
            var win = new AgreementWindow(db, reference);
            win.Build();
            bool Listed(string who) => win.ContactsTable.Table.Rows.Cast<DataRow>().Any(r => (string)r["Name"] == who);
            Check("contacts tab hides removed contacts by default", !Listed("Sam Second") && Listed("Pat Tester"), win.RemovedNote);
            Check("and says how many are hidden", win.RemovedNote.StartsWith("1 removed contact hidden"), win.RemovedNote);
            win.SetShowRemoved(true);
            Check("ticking 'Show removed contacts' lists them", Listed("Sam Second") && Listed("Pat Tester"), win.RemovedNote);
            win.SetShowRemoved(false);
            Check("unticking hides them again", !Listed("Sam Second"));

            // ---- the availability rules over real rows, not made-up ones. RunRules checks the
            // rules themselves; these check that each screen hands them the right data, which is
            // where the old code went wrong by reading the words out of a formatted cell.
            static bool On(MhActionSet s, string id) => s.ById(id)?.Enabled == true;
            static bool Off(MhActionSet s, string id, string reasonHas) =>
                s.ById(id) is { Enabled: false, DisabledReason: { } why } && why.Contains(reasonHas, StringComparison.OrdinalIgnoreCase);
            static string Ids(MhActionSet s) => string.Join(" ", s.Actions.Select(a => a.Enabled ? a.Id : $"({a.Id})"));

            // the monthly fee, three ways: the figure the summary prints, the instances it lists,
            // and what the dashboard reports for the same agreement. The summary used to add the
            // Fee column up in the screen, which was a second implementation of invoiced money.
            var fee = Queries.AgreementMonthlyFee(db, reference);
            var listed = Queries.Instances(db, reference).Rows.Cast<DataRow>().Where(r => r["Fee"] is decimal).Sum(r => (decimal)r["Fee"]);
            var reported = Queries.Dashboard(db).Agreements.Rows.Cast<DataRow>()
                .Where(r => (string)r["AgreementRef"] == reference).Select(r => r["MonthlyFee"] as decimal?).FirstOrDefault();
            Check("the monthly fee is the instances' fees added up", fee > 0m && fee == listed, $"fee £{fee}, instances £{listed}");
            Check("and it is the figure the dashboard reports", fee == reported, $"fee £{fee}, dashboard £{reported}");

            Check("a draft invoice is known to be one", Queries.IsDraftInvoice(db, typedNo));
            Check("an invoice that has been sent and paid is not", !Queries.IsDraftInvoice(db, invoice));
            var found = Queries.AgreementRefForClient(db, name);
            Check("the dashboard can find the client's agreement from the alert", found != null && found.StartsWith(reference), found ?? "(none)");

            var picked = new MainWindow(db);
            picked.CreateTop();
            var onSupport = picked.ClientActions(reference);
            var onConsultancy = picked.ClientActions(conRef);
            Check("the Clients tab offers agreement actions for the support agreement",
                On(onSupport, "agreement-open") && On(onSupport, "ticket-new") && On(onSupport, "prepaid-sell")
                && onSupport.ById("engagement-complete") == null, Ids(onSupport));
            Check("and consultancy actions for the engagement on the same tab",
                On(onConsultancy, "engagement-open") && On(onConsultancy, "work-log")
                && onConsultancy.ById("ticket-new") == null, Ids(onConsultancy));

            var packages = new AgreementWindow(db, reference);
            packages.Build();
            var invoiced = packages.PrepaidActions(package);
            var dead = packages.PrepaidActions(spare);
            Check("the package already on an invoice is not offered for invoicing again",
                Off(invoiced, "prepaid-invoice", invoice), Ids(invoiced));
            Check("and the hour taken out of it stops it being cancelled",
                Off(invoiced, "prepaid-cancel", "already been used"), Ids(invoiced));
            Check("the cancelled package offers nothing but where its hours went",
                dead.Available.Select(a => a.Id).SequenceEqual(new[] { "prepaid-usage", "prepaid-sell" }), Ids(dead));

            var logged = new EngagementWindow(db, conRef);
            logged.Build();
            var onInvoice = logged.EntryActions(invoiced: true);
            var notYet = logged.EntryActions(invoiced: false);
            Check("logged time that is already invoiced cannot be corrected or removed",
                Off(onInvoice, "entry-correct", "void that invoice") && Off(onInvoice, "entry-remove", "void that invoice")
                && On(onInvoice, "entry-invoiced"), Ids(onInvoice));
            Check("logged time not on an invoice still can be",
                On(notYet, "entry-correct") && On(notYet, "entry-remove"), Ids(notYet));
            var finished = logged.EngagementWideSet();
            Check("a finished engagement is not offered for finishing or cancelling again",
                Off(finished, "engagement-complete", "already finished") && Off(finished, "engagement-cancel", "already finished")
                && On(finished, "billing-run"), Ids(finished));
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

/// <summary>
///   Start-up's questions, answered by a script. The third implementation of
///   <see cref="IStartupPrompts"/>, and the one that shows the other two are only presentation: it
///   needs no console, no driver and no window, so the whole first-run path - missing settings, a
///   password, create, install, upgrade - can be walked and then asked what it was asked, in order.
/// </summary>
internal sealed class ScriptedPrompts : IStartupPrompts
{
    /// <summary>Everything asked or shown, in the order it happened. This is what the tests assert on.</summary>
    public readonly List<string> Seen = new();

    /// <summary>The settings screen as it was handed over, before the script typed into it.</summary>
    public SettingsDraft? Offered { get; private set; }

    /// <summary>The sentence the settings screen was given, saying what brought it up.</summary>
    public string? Why { get; private set; }

    /// <summary>Why a save or a sign-in did not go through, when one did not.</summary>
    public string? Refused { get; private set; }

    /// <summary>Types into the settings screen. Returns null - or is left null - to close it instead.</summary>
    public Func<SettingsDraft, SettingsDraft?>? Fill;

    /// <summary>Answers the password prompt: a password, "" for "Settings...", or null to give up (the default).</summary>
    public Func<string, string?>? Secret;

    /// <summary>Picks a button, by title and message. Left null, the first one.</summary>
    public Func<string, string, int>? Answer;

    /// <summary>Fills a form in. Left null, the form is closed without submitting.</summary>
    public Func<FormSpec, FormValues>? FillForm;

    /// <summary>Whether to save settings the server would not answer for, as "Save anyway" does. Off by default.</summary>
    public bool SaveUnreachable;

    public string Trail => Seen.Count == 0 ? "(nothing asked)" : string.Join(" | ", Seen);

    public SetupResult AskSettings(AppConfig config, string path, string why)
    {
        Seen.Add("settings");
        Why = why;
        Offered = SettingsDraft.From(config);           // a record of what was offered: a second draft,
        if (Fill == null) return SetupResult.Cancelled;  // so a Fill that edits in place cannot rewrite it
        var filled = Fill(SettingsDraft.From(config));
        if (filled == null) return SetupResult.Cancelled;
        var examined = Setup.Examine(filled, config);
        if (examined.Verdict == SaveVerdict.Invalid) { Refused = examined.Problem; return SetupResult.Cancelled; }
        if (examined.Verdict == SaveVerdict.Unreachable && !SaveUnreachable)
        {
            Refused = examined.Database!.Message;      // the screen's "Keep editing"
            return SetupResult.Cancelled;
        }
        Refused = Setup.Commit(config, path, examined.Candidate!);
        return Refused == null ? SetupResult.Saved : SetupResult.Cancelled;
    }

    public string? AskSecret(AppConfig config, string path, string prompt)
    {
        Seen.Add("password");
        var value = Secret?.Invoke(prompt);
        if (string.IsNullOrEmpty(value)) return value;            // null gave up, "" asked for the settings
        var tried = Setup.TrySecret(config, path, value, remember: true);
        Refused = tried.Problem ?? tried.WriteProblem;
        return tried.Worked ? value : null;
    }

    public int Choose(string title, string message, params string[] buttons)
    {
        Seen.Add(title);
        return Answer?.Invoke(title, message) ?? 0;
    }

    public void ShowText(string title, string text) => Seen.Add(title);

    public string? RunInstall(AppConfig config, out List<string> messages)
    {
        messages = new List<string>();
        try { messages = AdminInstaller.Install(config); return null; }
        catch (Exception ex) { return ex is InvalidOperationException ? ex.Message : AdminDb.Describe(ex); }
    }

    public void RunForm(FormSpec spec)
    {
        Seen.Add(spec.Title);
        if (FillForm != null) spec.Execute(FillForm(spec));
    }
}
