using MolehillManager;
using Terminal.Gui;

// Molehill Manager - Molehill Data Services
// Terminal front end for the MolehillAdmin database: clients, agreements, instances, tickets and billing.

string? connectionString = null;
string? server = null, database = null;
var selfTest = false;
var selfTestWrite = false;
var allowWrites = false;

for (var i = 0; i < args.Length; i++)
{
    switch (args[i].ToLowerInvariant())
    {
        case "-c" or "--connection-string":
            if (++i < args.Length) connectionString = args[i];
            break;
        case "-s" or "--server":
            if (++i < args.Length) server = args[i];
            break;
        case "-d" or "--database":
            if (++i < args.Length) database = args[i];
            break;
        case "--selftest":
            selfTest = true;
            break;
        case "--selftest-write":
            selfTestWrite = true;
            break;
        case "--allow-writes":
            allowWrites = true;
            break;
        case "-h" or "--help" or "/?":
            Help();
            return 0;
        default:
            Console.Error.WriteLine($"Unknown option '{args[i]}'. Use --help.");
            return 64;
    }
}

var settingsPath = ConnectionSettings.DefaultPath;
var settings = ConnectionSettings.Load(settingsPath) ?? new ConnectionSettings();
if (server != null || database != null)
{
    if (server != null) settings.Server = server;
    if (database != null) settings.Database = database;
    settings.Authentication = "Windows";
    connectionString = settings.Build(null);
}

if (selfTest || selfTestWrite)
{
    if (connectionString == null) { Console.Error.WriteLine("The self-tests need -c \"connection string\" (or -s server -d database)."); return 64; }
    var problem = ConnectionSettings.Check(connectionString);
    if (problem != null) { Console.Error.WriteLine(problem); return 1; }
    if (selfTestWrite && !allowWrites)
    {
        Console.Error.WriteLine("--selftest-write adds a test client, agreement, tickets and invoices. Only use it on a test copy of MolehillAdmin,");
        Console.Error.WriteLine("and add --allow-writes to confirm.");
        return 64;
    }
    return selfTestWrite ? SelfTest.Write(new AdminDb(connectionString)) : SelfTest.Ui(new AdminDb(connectionString));
}

try
{
    Application.Init();
}
catch (Exception ex)
{
    Console.Error.WriteLine("This needs a real terminal window (Windows Terminal, conhost or an SSH session).");
    Console.Error.WriteLine(ex.Message);
    return 1;
}

try
{
    // a connection string from the command line is tried first; otherwise (or if it fails) ask
    if (connectionString != null)
    {
        var problem = ConnectionSettings.Check(connectionString);
        if (problem != null)
        {
            MessageBox.ErrorQuery("Connect", problem, "Ok");
            connectionString = null;
        }
    }
    connectionString ??= ConnectionSettings.Prompt(settings, settingsPath);
    if (connectionString == null) return 0;

    var main = new MainWindow(new AdminDb(connectionString), () =>
    {
        var cs = ConnectionSettings.Prompt(settings, settingsPath);
        return cs == null ? null : new AdminDb(cs);
    });
    main.Build(Application.Top);
    Application.Run();
}
finally
{
    Application.Shutdown();
}
return 0;

static void Help() => Console.WriteLine("""
Molehill Manager - Molehill Data Services

Terminal front end for the MolehillAdmin database: clients, agreements, instances
(SQL Server, Azure SQL Managed Instance, Azure SQL Database), onboarding, tickets,
time, billing and invoices.

  MolehillManager                           connect (remembers the server; never the password)
  MolehillManager -s SQL01 -d MolehillAdmin Windows authentication to that server
  MolehillManager -c "Server=...;..."       any connection string

  MolehillManager -c "..." --selftest       build every screen and form against the database
                                            (read-only) and report
  MolehillManager -c "..." --selftest-write --allow-writes
                                            scripted run of every form against a TEST copy:
                                            adds a client, instances, tickets and invoices

Keys: F2 new, F3/Enter open or actions, F5 refresh, F6 run billing, Ctrl+Q quit.
""");
