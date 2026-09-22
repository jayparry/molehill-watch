using System.Reflection;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;

namespace MolehillManager;

public enum DbState { Ready, DatabaseMissing, NotInstalled, NeedsUpgrade, Clash, NoAccess, Error }

/// <summary>What the configured database looks like from here.</summary>
public sealed record DbCheck(DbState State, string Message)
{
    /// <summary>States the app can fix by creating, installing or upgrading.</summary>
    public bool CanInstall => State is DbState.DatabaseMissing or DbState.NotInstalled or DbState.NeedsUpgrade;
}

/// <summary>
/// Creates and installs (or upgrades) the MolehillAdmin database from the install script built into the app,
/// under whatever database name the config file gives. The script is safe to re-run: data is kept.
/// </summary>
public static class AdminInstaller
{
    // tables MolehillAdmin creates in dbo: a database already holding any of these (without being MolehillAdmin) is left alone
    private static readonly string[] OwnTables =
    {
        "InstallHistory", "Setting", "BankHoliday", "ProductLifecycle", "PriceList", "Client", "Contact", "Agreement", "Instance",
        "OnboardingItem", "PriceChange", "Ticket", "Invoice", "BillingCycle", "InvoiceLine", "TimeEntry", "WeeklyReportLog", "Quote"
    };

    public static string Script
    {
        get
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("MolehillAdmin_Install.sql")
                               ?? throw new InvalidOperationException("The MolehillAdmin install script is missing from this build.");
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
    }

    /// <summary>The version the built-in script installs (its INSERT into dbo.InstallHistory).</summary>
    public static Version ScriptVersion
    {
        get
        {
            var m = Regex.Match(Script, @"INSERT dbo\.InstallHistory \(Version\) VALUES \('([0-9.]+)'\)");
            return m.Success ? Version.Parse(m.Groups[1].Value) : new Version(0, 0);
        }
    }

    private static string MasterConnectionString(AppConfig config) =>
        new SqlConnectionStringBuilder(config.BuildConnectionString()) { InitialCatalog = "master" }.ConnectionString;

    public static DbCheck Inspect(AppConfig config)
    {
        var name = config.Connection.Database;
        var server = config.Connection.Server;
        try
        {
            using var conn = new SqlConnection(config.BuildConnectionString());
            conn.Open();
            using var cmd = conn.CreateCommand();
            cmd.CommandText = $"""
                SELECT IsInstalled = CASE WHEN OBJECT_ID(N'dbo.usp_Dashboard') IS NOT NULL AND OBJECT_ID(N'dbo.Agreement') IS NOT NULL THEN 1 ELSE 0 END,
                       IsCurrent = CASE WHEN COL_LENGTH(N'dbo.Instance', N'Platform') IS NOT NULL THEN 1 ELSE 0 END,
                       Clashes   = STUFF((SELECT N', dbo.' + name FROM sys.tables WHERE schema_id = SCHEMA_ID(N'dbo')
                                          AND name IN ({string.Join(", ", OwnTables.Select(t => $"N'{t}'"))}) ORDER BY name
                                          FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 2, N''),
                       Others    = (SELECT COUNT(*) FROM sys.objects WHERE is_ms_shipped = 0 AND type IN ('U', 'V', 'P', 'FN', 'IF', 'TF')),
                       Partial   = CASE WHEN OBJECT_ID(N'dbo.InstallHistory') IS NOT NULL THEN 1 ELSE 0 END;
                """;
            using var r = cmd.ExecuteReader();
            r.Read();
            var installed = r.GetInt32(0) == 1;
            var current = r.GetInt32(1) == 1;
            var clashes = r.IsDBNull(2) ? "" : r.GetString(2);
            var others = r.GetInt32(3);
            var partial = r.GetInt32(4) == 1;   // InstallHistory is the script's first table: an install that stopped part way
            r.Close();
            // read separately: a reference to a missing table fails at compile time, even behind a CASE
            var installedVersion = new Version(0, 0);
            if (partial)
            {
                using var vcmd = conn.CreateCommand();
                vcmd.CommandText = "SELECT TOP (1) Version FROM dbo.InstallHistory ORDER BY InstallId DESC;";
                if (vcmd.ExecuteScalar() is string text && Version.TryParse(text, out var v)) installedVersion = v;
            }
            var behind = installedVersion < ScriptVersion;
            if (installed && current && !behind) return new DbCheck(DbState.Ready, $"Connected to {name} on {server}.");
            if (installed)
                return new DbCheck(DbState.NeedsUpgrade,
                    $"MolehillAdmin in [{name}] on {server} is an older version ({(installedVersion.Major == 0 ? "unknown" : installedVersion.ToString())}; "
                    + $"this app brings {ScriptVersion}). Upgrading keeps all your data (the install is safe to re-run), but take a backup first if you are unsure.");
            if (partial)
                return new DbCheck(DbState.NotInstalled, $"MolehillAdmin in [{name}] on {server} is only partly installed (an earlier install stopped). Finish the install? Nothing already there is lost.");
            if (clashes != "")
                return new DbCheck(DbState.Clash,
                    $"[{name}] on {server} is not MolehillAdmin, but already has tables with the names MolehillAdmin uses ({clashes}). It will not be touched: choose another database name in Settings.");
            return new DbCheck(DbState.NotInstalled, others == 0
                ? $"[{name}] on {server} exists but is empty. Install MolehillAdmin into it?"
                : $"[{name}] on {server} exists and has {others} other object(s), none of them MolehillAdmin's. MolehillAdmin can be installed alongside them (in the dbo schema). Install it?");
        }
        catch (SqlException ex) when (ex.Number is 4060 or 40615 or 916)
        {
            // cannot open the database: find out whether it exists at all
            try
            {
                using var master = new SqlConnection(MasterConnectionString(config));
                master.Open();
                using var cmd = master.CreateCommand();
                cmd.CommandText = "SELECT CASE WHEN DB_ID(@n) IS NULL THEN 0 ELSE 1 END, CONVERT(int, HAS_PERMS_BY_NAME(NULL, NULL, 'CREATE ANY DATABASE'))";
                cmd.Parameters.AddWithValue("@n", name);
                using var r = cmd.ExecuteReader();
                r.Read();
                if (r.GetInt32(0) == 1)
                    return new DbCheck(DbState.NoAccess, $"[{name}] exists on {server}, but this sign-in has no access to it. Ask for a user in that database, or sign in differently.\n\n{AdminDb.Describe(ex)}");
                var canCreate = !r.IsDBNull(1) && r.GetInt32(1) == 1;
                return new DbCheck(DbState.DatabaseMissing,
                    $"There is no database called [{name}] on {server}. Create it and install MolehillAdmin?"
                    + (canCreate ? "" : "\n\nNote: this sign-in may not have permission to create databases (CREATE ANY DATABASE / dbcreator)."));
            }
            catch (Exception inner)
            {
                return new DbCheck(DbState.Error, AdminDb.Describe(ex) + "\n\n(Checking master as well: " + AdminDb.Describe(inner) + ")");
            }
        }
        catch (Exception ex)
        {
            return new DbCheck(DbState.Error, AdminDb.Describe(ex));
        }
    }

    /// <summary>Creates the database if needed, then runs the install script in it. Returns the messages it printed.</summary>
    public static List<string> Install(AppConfig config, Action<string>? progress = null)
    {
        var name = config.Connection.Database;
        var messages = new List<string>();
        progress ??= _ => { };

        progress("Checking the server...");
        using (var master = new SqlConnection(MasterConnectionString(config)))
        {
            master.Open();
            using var cmd = master.CreateCommand();
            cmd.CommandText = "SELECT CONVERT(varchar(30), SERVERPROPERTY('ProductVersion')), CONVERT(int, SERVERPROPERTY('EngineEdition')), CASE WHEN DB_ID(@n) IS NULL THEN 0 ELSE 1 END";
            cmd.Parameters.AddWithValue("@n", name);
            string version; int engine; bool exists;
            using (var r = cmd.ExecuteReader())
            {
                r.Read();
                version = r.GetString(0); engine = r.GetInt32(1); exists = r.GetInt32(2) == 1;
            }
            // Azure SQL Database (5) and Managed Instance (8) are always current, whatever version number they report
            if (engine is not (5 or 8) && int.Parse(version.Split('.')[0]) < 14)
                throw new InvalidOperationException($"MolehillAdmin needs SQL Server 2017 or later (Express is fine); {config.Connection.Server} is version {version}.");
            if (!exists)
            {
                progress($"Creating database [{name}]...");
                using var create = master.CreateCommand();
                create.CommandText = "CREATE DATABASE " + QuoteName(name) + ";";
                create.CommandTimeout = 300;
                create.ExecuteNonQuery();
                messages.Add($"Created database [{name}].");
            }
        }

        // the script's own preamble creates and switches to a database called MolehillAdmin: run only what follows it
        var batches = Regex.Split(Script, @"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase)
                           .Where(b => b.Trim().Length > 0).ToList();
        var start = batches.FindIndex(b => b.Trim().Equals("USE MolehillAdmin;", StringComparison.OrdinalIgnoreCase));
        if (start < 0) throw new InvalidOperationException("The install script's layout is not recognised (no 'USE MolehillAdmin;').");
        batches = batches.Skip(start + 1).ToList();

        // a fresh connection pool: the database may have only just been created
        SqlConnection.ClearAllPools();
        using var conn = new SqlConnection(config.BuildConnectionString());
        conn.InfoMessage += (_, e) =>
        {
            foreach (SqlError err in e.Errors)
                if (!err.Message.Contains("depends on the missing object") && !err.Message.StartsWith("Changed database context"))
                    messages.Add(err.Message);
        };
        conn.Open();
        try
        {
            using var autoClose = conn.CreateCommand();
            autoClose.CommandText = "ALTER DATABASE CURRENT SET AUTO_CLOSE OFF;";
            autoClose.ExecuteNonQuery();
        }
        catch (SqlException) { /* not supported everywhere (e.g. Azure SQL Database); harmless */ }

        for (var i = 0; i < batches.Count; i++)
        {
            progress($"Installing... step {i + 1} of {batches.Count}");
            using var cmd = conn.CreateCommand();
            cmd.CommandText = batches[i];
            cmd.CommandTimeout = 0;
            try { cmd.ExecuteNonQuery(); }
            catch (SqlException ex)
            {
                throw new InvalidOperationException($"The install stopped at step {i + 1} of {batches.Count}:\n{AdminDb.Describe(ex)}");
            }
        }
        progress("Done.");
        return messages;
    }

    private static string QuoteName(string name) => "[" + name.Replace("]", "]]") + "]";
}
