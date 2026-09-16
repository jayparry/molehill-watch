using SqlConnectionTester;

// SQL Connection Tester - Molehill Data Services
// Interactive terminal app (default) plus a headless mode for scripts and scheduled checks.

var path = ProfileStore.DefaultPath;
var headless = false;
var csv = "";
var extraConnectionStrings = new List<string>();
var uiSelfTest = false;

for (var i = 0; i < args.Length; i++)
{
    var a = args[i].ToLowerInvariant();
    switch (a)
    {
        case "-f" or "--file":
            if (++i < args.Length) path = args[i];
            break;
        case "-t" or "--test":
            headless = true;
            break;
        case "-c" or "--csv":
            headless = true;
            if (++i < args.Length) csv = args[i];
            break;
        case "-s" or "--connection-string":
            headless = true;
            if (++i < args.Length) extraConnectionStrings.Add(args[i]);
            break;
        case "--ui-selftest":            // builds the whole interface with a fake console, for automated checks
            uiSelfTest = true;
            break;
        case "-h" or "--help" or "/?":
            Help();
            return 0;
        default:
            Console.Error.WriteLine($"Unknown option '{args[i]}'. Use --help.");
            return 64;
    }
}

List<ConnectionProfile> profiles;
try
{
    profiles = ProfileStore.Load(path);
}
catch (Exception ex)
{
    Console.Error.WriteLine($"Could not read {path}:{Environment.NewLine}{ConnectionTester.Describe(ex)}");
    return 1;
}

foreach (var cs in extraConnectionStrings)
    profiles.Add(new ConnectionProfile { Name = cs.Length > 40 ? cs[..40] + "..." : cs, UseRawConnectionString = true, RawConnectionString = cs });

if (uiSelfTest)
{
    Terminal.Gui.Application.Init(new Terminal.Gui.FakeDriver(), null);
    try
    {
        var tui = new Tui(path, profiles);
        tui.BuildViews(Terminal.Gui.Application.Top);
        var sample = profiles.FirstOrDefault() ?? new ConnectionProfile { Name = "sample", Server = "SQL01" };
        foreach (var method in Enum.GetValues<AuthMethod>())
        {
            sample.Authentication = method;
            _ = sample.Build();                       // every auth method produces a valid connection string
            using var dialog = ProfileDialog.Create(sample, "Self test", out _);
        }
        Console.WriteLine($"UI self-test OK: interface built, {Enum.GetValues<AuthMethod>().Length} authentication methods build a connection string.");
    }
    finally
    {
        Terminal.Gui.Application.Shutdown();
    }
    return 0;
}

if (!headless)
{
    try
    {
        new Tui(path, profiles).Run();
    }
    catch (InvalidOperationException ex) when (ex.Message.Contains("console", StringComparison.OrdinalIgnoreCase))
    {
        Console.Error.WriteLine("This needs a real terminal window (Windows Terminal, conhost or an SSH session).");
        Console.Error.WriteLine("For scripts and pipelines use the headless mode instead: SqlConnectionTester --test");
        return 1;
    }
    return 0;
}

// ---- headless: test everything and print the four columns
if (profiles.Count == 0)
{
    Console.Error.WriteLine("No connections to test. Add some in the app, or pass --connection-string \"...\".");
    return 64;
}

var results = new List<TestResult>();
foreach (var p in profiles)
{
    var r = ConnectionTester.Test(p);
    results.Add(r);
    Console.WriteLine($"ConnectionString : {r.ConnectionString}");
    Console.WriteLine($"TestText         : {r.TestText}");
    Console.WriteLine($"Status           : {r.Status}");
    if (!string.IsNullOrEmpty(r.ErrorMessage)) Console.WriteLine($"ErrorMessage     : {r.ErrorMessage}");
    Console.WriteLine();
}

if (!string.IsNullOrEmpty(csv))
{
    ConnectionTester.ExportCsv(results, csv);
    Console.WriteLine($"Results saved to {csv}");
}

var failed = results.Count(r => !r.Succeeded);
Console.WriteLine($"{results.Count - failed} of {results.Count} connection(s) succeeded.");
return failed == 0 ? 0 : 2;

static void Help() => Console.WriteLine("""
SQL Connection Tester - Molehill Data Services

Tests SQL Server connection strings by reading a single row from dbo.TestConnection.
Read-only: nothing is created or changed on the server.

  SqlConnectionTester                     open the terminal app (add, edit and test connections)
  SqlConnectionTester --test              test every saved connection and print the results
  SqlConnectionTester --csv results.csv   test everything and also write a CSV
  SqlConnectionTester -s "Server=..."     test one connection string (repeatable)
  SqlConnectionTester --file conns.json   use a different connections file

Exit codes: 0 all succeeded, 2 one or more failed, 1 error, 64 bad usage.

In the app: F2 add, F3 edit, F4 delete, F5 test, F6 test all, F7 full result, F8 export CSV,
Ctrl+S save, Ctrl+Q quit. Authentication methods include Windows, SQL login, and Entra ID
(password, integrated, interactive/MFA, device code, service principal, managed identity, default).
""");
