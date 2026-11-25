using System.Text.Json;
using MolehillManager;
using Terminal.Gui;

// Molehill Manager - Molehill Data Services
// Front end for the MolehillAdmin database: clients, agreements, instances, tickets and billing.
// Settings live in MolehillManager.config.json (next to the .exe, or in %APPDATA%\MolehillManager);
// anything missing is asked for on start-up and written back to the file.

internal static class Program
{
    // WPF needs an STA main thread, and an attribute cannot be put on the implicit entry point of
    // top-level statements - which is what this file used to be. Nothing else about it has changed.
    [STAThread]
    private static int Main(string[] args)
    {
        ConsoleHost.Prepare();             // before anything prints: see ConsoleHost

        string? configArg = null, connectionOverride = null;
        bool forceSetup = false, installOnly = false, selfTest = false, selfTestWrite = false,
             selfTestConfig = false, allowWrites = false, tui = false, gui = false, selfTestGui = false;
        string? shotFolder = null;

        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--config":
                    if (++i < args.Length) configArg = args[i];
                    break;
                case "--setup":
                    forceSetup = true;
                    break;
                case "--tui":                                   // the terminal front end, whatever the default is
                    tui = true;
                    break;
                case "--gui":                                   // the window, whatever the default is
                    gui = true;
                    break;
                case "--shot":                                  // with --selftest-gui: save a picture of each view
                    shotFolder = i + 1 < args.Length ? args[++i] : null;
                    break;
                case "--install":                               // create / install / upgrade the configured database, no screen
                    installOnly = true;
                    break;
                case "-c" or "--connection-string":            // self-tests only: bypass the config file
                    if (++i < args.Length) connectionOverride = args[i];
                    break;
                case "--selftest": selfTest = true; break;
                case "--selftest-write": selfTestWrite = true; break;
                case "--selftest-config": selfTestConfig = true; break;
                case "--selftest-gui":                          // build and lay out every view, no database
                    selfTestGui = true;                         // dispatched below, so that --shot is read first
                    break;
                case "--selftest-install":                      // create / install / upgrade test databases on this server, then drop them
                    if (++i < args.Length) return SelfTest.Install(args[i]);
                    break;
                case "--selftest-setup":                        // drives the first-run settings screen against this server
                    if (++i < args.Length) return SelfTest.Setup(args[i]);
                    break;
                case "--allow-writes": allowWrites = true; break;
                case "-h" or "--help" or "/?":
                    Help();
                    return 0;
                default:
                    Console.Error.WriteLine($"Unknown option '{args[i]}'. Use --help.");
                    return 64;
            }
        }

        SelfTest.ShotFolder = shotFolder;

        if (selfTestGui) return SelfTest.Gui();
        if (selfTestConfig) return SelfTest.Config();

        var path = ConfigStore.Resolve(configArg);
        AppConfig config;
        bool existed;
        string? loadProblem = null;
        try
        {
            config = ConfigStore.Load(path, out existed);
        }
        catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
        {
            config = new AppConfig { OutputFolder = AppConfig.DefaultOutputFolder };
            existed = false;
            loadProblem = $"{path} could not be read ({ex.Message.Split('\n')[0]}).";
        }

        // a password typed into the file by hand is encrypted straight away
        if (loadProblem == null && config.PlainTextSecretFound)
        {
            try { ConfigStore.Save(path, config); }
            catch (Exception ex) { Console.Error.WriteLine($"Warning: could not rewrite {path} to encrypt the password: {ex.Message}"); }
        }

        // ---------------------------------------------------------------- headless install / upgrade
        if (installOnly) return Install(config, path, loadProblem);

        // ---------------------------------------------------------------- self-tests (no screen)
        if (selfTest || selfTestWrite)
            return RunSelfTest(config, path, loadProblem, connectionOverride, selfTestWrite, allowWrites);

        // ---------------------------------------------------------------- the app
        return Startup.ChooseFrontEnd(tui, gui) switch
        {
            FrontEnd.Terminal => RunTerminal(config, path, existed, forceSetup, loadProblem),
            _ => RunWindow(config, path, existed, forceSetup, loadProblem)
        };
    }

    private static int Install(AppConfig config, string path, string? loadProblem)
    {
        if (loadProblem != null) { Console.Error.WriteLine(loadProblem); return 1; }
        if (config.Missing().Count > 0 || config.NeedsSecretPrompt)
        {
            Console.Error.WriteLine($"The config file {path} is incomplete ({string.Join(", ", config.Missing().DefaultIfEmpty("password"))}); run the app once to fill it in.");
            return 64;
        }
        var check = AdminInstaller.Inspect(config);
        if (check.State is DbState.Clash or DbState.NoAccess or DbState.Error) { Console.Error.WriteLine(check.Message); return 1; }
        Console.WriteLine(check.State switch
        {
            DbState.DatabaseMissing => $"[{config.Connection.Database}] does not exist on {config.Connection.Server}: creating it and installing MolehillAdmin.",
            DbState.NeedsUpgrade => "Upgrading MolehillAdmin (data is kept).",
            DbState.NotInstalled => $"Installing MolehillAdmin into [{config.Connection.Database}].",
            _ => "MolehillAdmin is already current; re-running the install script (safe, data is kept)."
        });
        try
        {
            foreach (var m in AdminInstaller.Install(config, Console.WriteLine)) Console.WriteLine("  " + m);
            Console.WriteLine(AdminInstaller.Inspect(config).State == DbState.Ready ? $"MolehillAdmin is ready in [{config.Connection.Database}] on {config.Connection.Server}." : "Installed, but the check afterwards did not pass.");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex is InvalidOperationException ? ex.Message : AdminDb.Describe(ex));
            return 1;
        }
    }

    private static int RunSelfTest(AppConfig config, string path, string? loadProblem, string? connectionOverride, bool write, bool allowWrites)
    {
        string connectionString;
        if (connectionOverride != null) connectionString = connectionOverride;
        else if (loadProblem != null) { Console.Error.WriteLine(loadProblem); return 1; }
        else if (config.Missing().Count > 0 || config.NeedsSecretPrompt)
        {
            Console.Error.WriteLine($"The config file {path} is incomplete; run the app once to fill it in, or pass -c \"connection string\".");
            return 64;
        }
        else connectionString = config.BuildConnectionString();

        var problem = ConfigStore.Check(connectionString);
        if (problem != null) { Console.Error.WriteLine(problem); return 1; }
        if (write && !allowWrites)
        {
            Console.Error.WriteLine("--selftest-write adds a test client, agreement, tickets and invoices. Only use it on a test copy of MolehillAdmin,");
            Console.Error.WriteLine("and add --allow-writes to confirm.");
            return 64;
        }
        return write ? SelfTest.Write(new AdminDb(connectionString)) : SelfTest.Ui(new AdminDb(connectionString));
    }

    private static int RunTerminal(AppConfig config, string path, bool existed, bool forceSetup, string? loadProblem)
    {
        // a windowed program has no console of its own, and Terminal.Gui cannot draw without one.
        // Double-clicking the exe comes through here while the terminal is still the default.
        ConsoleHost.EnsureConsoleForTerminalUi();

        try
        {
            Application.Init();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("Molehill Manager needs a real terminal window (Windows Terminal, conhost or an SSH session).");
            Console.Error.WriteLine(ex.Message);
            return 1;
        }

        try
        {
            if (loadProblem != null)
            {
                var backup = path + ".bak";
                if (MessageBox.ErrorQuery("Settings", $"{loadProblem}\n\nStart again with new settings? The old file is kept as\n{backup}", "New settings", "Quit") != 0) return 1;
                try { File.Copy(path, backup, overwrite: true); } catch { /* unreadable or locked: nothing to keep */ }
            }

            var prompts = new TerminalPrompts();
            var connectionString = Startup.Connect(prompts, config, path, existed, forceSetup, loadProblem != null);
            if (connectionString == null) return 0;
            AdminForms.OutputFolder = config.OutputFolder;

            var main = new MainWindow(new AdminDb(connectionString), path, () =>
            {
                // File > Settings: edit, save, reconnect
                var cs = Startup.Connect(prompts, config, path, existed: true, forceSetup: true, loadFailed: false);
                if (cs == null) return null;
                AdminForms.OutputFolder = config.OutputFolder;
                return new AdminDb(cs);
            }, () => config.AutoRefreshMinutes);
            Application.Run(main.CreateTop());
        }
        finally
        {
            Application.Shutdown();
        }
        return 0;
    }

    /// <summary>The window. Nothing to run yet: the shell is the next step, and until then nothing asks for it.</summary>
    /// <summary>
    ///   The window. Everything worth asserting is in Shell and the pages, which the GUI suite
    ///   builds without one; this gets a connection, puts the window up and runs the message loop.
    /// </summary>
    private static int RunWindow(AppConfig config, string path, bool existed, bool forceSetup, string? loadProblem) =>
        MolehillManager.Gui.WindowApp.Run(config, path, existed, forceSetup, loadProblem != null);

    private static void Help() => Console.WriteLine($"""
Molehill Manager - Molehill Data Services

Front end for the MolehillAdmin database: clients, agreements, instances
(SQL Server, Azure SQL Managed Instance, Azure SQL Database), onboarding, tickets,
time, billing and invoices.

Just run it. Settings are kept in {ConfigStore.FileName}:
  next to MolehillManager.exe (if that folder is writable), otherwise
  {ConfigStore.AppDataPath}
Anything missing is asked for on start-up and saved. Passwords and client secrets are
only saved if you tick "Remember it", and then encrypted for your Windows account.

  MolehillManager                       start (first run asks for the settings)
  MolehillManager                       start the window
  MolehillManager --tui                 start the terminal front end instead: the one that works
                                        over a remote session with no desktop
  MolehillManager --gui                 start the window, whatever the default is
  MolehillManager --setup               open the settings screen first
  MolehillManager --config D:\x.json    use a different config file (one per environment)
  MolehillManager --install             create / install / upgrade the configured database without
                                        the screen (the app also offers this itself when needed)

This .exe is a windowed program, so that double-clicking it leaves no empty console window behind
the screen. Most shells do not wait for one of those, and do not report its exit code. Anything
scripted - a self-test, --install, a scheduled task - should run MolehillManager.cmd beside it,
which takes the same switches and behaves as a console program always did.

  MolehillManager.cmd --selftest        build every screen and form against the configured
                                        database (read-only) and report
  MolehillManager.cmd --selftest-write --allow-writes
                                        scripted run of every form against a TEST copy
  MolehillManager.cmd --selftest-config check the config file handling (no database needed)
  MolehillManager.cmd --selftest-install S
                                        create / install / upgrade scratch databases on server S, then drop them
  MolehillManager.cmd --selftest-setup S
                                        drive the first-run settings screen against server S
  (-c "connection string" points a self-test somewhere other than the config file)

Keys: F2 new, F3/Enter open or actions, F5 refresh, F6 run billing, Ctrl+Q quit.
""");
}
