using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Data.SqlClient;

namespace MolehillManager;

/// <summary>Where MolehillAdmin lives and how to sign in to it.</summary>
public sealed class ConnectionConfig
{
    public string Server { get; set; } = "";
    public string Database { get; set; } = "MolehillAdmin";

    /// <summary>Windows | SqlLogin | EntraInteractive | EntraPassword | EntraServicePrincipal | EntraManagedIdentity | EntraDefault</summary>
    public string Authentication { get; set; } = "Windows";

    /// <summary>SQL login, Entra user name, or the app (client) id for a service principal / user-assigned managed identity.</summary>
    public string User { get; set; } = "";

    /// <summary>Plain text is accepted when you edit the file by hand; it is encrypted and removed on the next start.</summary>
    public string? Password { get; set; }

    /// <summary>The password or client secret, encrypted with Windows DPAPI for the current user on this machine.</summary>
    public string? PasswordEncrypted { get; set; }

    /// <summary>false = ask for the password every time the app starts.</summary>
    public bool SavePassword { get; set; } = true;

    /// <summary>Mandatory | Optional | Strict</summary>
    public string Encrypt { get; set; } = "Mandatory";
    public bool TrustServerCertificate { get; set; } = true;
    public int ConnectTimeoutSeconds { get; set; } = 15;

    public ConnectionConfig Clone() => (ConnectionConfig)MemberwiseClone();
}

/// <summary>Everything the app keeps between runs.</summary>
public sealed class AppConfig
{
    [JsonPropertyName("_about")]
    public string About { get; set; } =
        "Molehill Manager settings. Edit here or with File > Settings in the app. Secrets are stored encrypted for this Windows user " +
        "(PasswordEncrypted); a plain Password typed in here is encrypted and removed the next time the app starts.";

    public ConnectionConfig Connection { get; set; } = new();

    /// <summary>Where invoice and dashboard HTML files are saved.</summary>
    public string OutputFolder { get; set; } = "";

    /// <summary>Refresh the screens every N minutes (0 = only when you press F5).</summary>
    public int AutoRefreshMinutes { get; set; } = 0;

    /// <summary>Not saved: the password for this run (decrypted, typed in, or read from a plain-text field).</summary>
    [JsonIgnore] public string? Secret { get; set; }

    /// <summary>Not saved: the stored secret could not be decrypted (another Windows user or machine).</summary>
    [JsonIgnore] public bool SecretUnreadable { get; set; }

    /// <summary>Not saved: the file had a plain-text password, so it should be rewritten (encrypted) straight away.</summary>
    [JsonIgnore] public bool PlainTextSecretFound { get; set; }

    public static readonly string[] AuthMethods =
        { "Windows", "SqlLogin", "EntraInteractive", "EntraPassword", "EntraServicePrincipal", "EntraManagedIdentity", "EntraDefault" };

    public static readonly string[] AuthLabels =
    {
        "Windows authentication", "SQL Server login", "Entra ID - interactive (MFA)", "Entra ID - password",
        "Entra ID - service principal", "Entra ID - managed identity", "Entra ID - default (az login, env...)"
    };

    public static bool NeedsUser(string auth) => auth is "SqlLogin" or "EntraPassword" or "EntraServicePrincipal";
    public static bool AllowsUser(string auth) => auth != "Windows" && auth != "EntraDefault";
    public static bool NeedsSecret(string auth) => auth is "SqlLogin" or "EntraPassword" or "EntraServicePrincipal";

    public static string DefaultOutputFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "Molehill", "Invoices");

    /// <summary>What the file is missing: anything listed has to be asked for before the app can connect.</summary>
    public List<string> Missing()
    {
        var missing = new List<string>();
        var c = Connection;
        if (string.IsNullOrWhiteSpace(c.Server)) missing.Add("server");
        if (string.IsNullOrWhiteSpace(c.Database)) missing.Add("database");
        if (!AuthMethods.Contains(c.Authentication)) missing.Add("sign-in method");
        else if (NeedsUser(c.Authentication) && string.IsNullOrWhiteSpace(c.User))
            missing.Add(c.Authentication == "EntraServicePrincipal" ? "client id" : "user name");
        if (!new[] { "Mandatory", "Optional", "Strict" }.Contains(c.Encrypt)) missing.Add("encryption setting");
        if (string.IsNullOrWhiteSpace(OutputFolder)) missing.Add("output folder");
        return missing;
    }

    /// <summary>True when only the password is needed (not saved, or saved by someone else).</summary>
    [JsonIgnore] public bool NeedsSecretPrompt => NeedsSecret(Connection.Authentication) && string.IsNullOrEmpty(Secret);

    public string BuildConnectionString()
    {
        var c = Connection;
        var b = new SqlConnectionStringBuilder
        {
            DataSource = c.Server.Trim(),
            InitialCatalog = c.Database.Trim(),
            TrustServerCertificate = c.TrustServerCertificate,
            Encrypt = SqlConnectionEncryptOption.Parse(c.Encrypt),
            ApplicationName = "Molehill Manager",
            ConnectTimeout = c.ConnectTimeoutSeconds > 0 ? c.ConnectTimeoutSeconds : 15
        };
        var user = c.User.Trim();
        switch (c.Authentication)
        {
            case "SqlLogin":
                b.UserID = user; b.Password = Secret ?? "";
                break;
            case "EntraInteractive":
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryInteractive;
                if (user != "") b.UserID = user;
                break;
            case "EntraPassword":
#pragma warning disable CS0618   // deprecated by Microsoft but still works, and some tenants still use it
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryPassword;
#pragma warning restore CS0618
                b.UserID = user; b.Password = Secret ?? "";
                break;
            case "EntraServicePrincipal":
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryServicePrincipal;
                b.UserID = user; b.Password = Secret ?? "";
                break;
            case "EntraManagedIdentity":
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryManagedIdentity;
                if (user != "") b.UserID = user;
                break;
            case "EntraDefault":
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault;
                break;
            default:
                b.IntegratedSecurity = true;
                break;
        }
        return b.ConnectionString;
    }

    public string Describe()
    {
        var c = Connection;
        var label = AuthMethods.Contains(c.Authentication) ? AuthLabels[Array.IndexOf(AuthMethods, c.Authentication)] : c.Authentication;
        return $"{c.Server} / {c.Database} ({label}{(c.User != "" && AllowsUser(c.Authentication) ? ", " + c.User : "")})";
    }
}

/// <summary>Finds, reads and writes the config file, encrypting secrets with DPAPI.</summary>
public static class ConfigStore
{
    public const string FileName = "MolehillManager.config.json";

    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        AllowTrailingCommas = true,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping   // readable paths and base64 in the file
    };

    public static string AppDataPath =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MolehillManager", FileName);

    public static string ExeFolderPath => Path.Combine(AppContext.BaseDirectory, FileName);

    /// <summary>
    /// --config wins. Otherwise a config next to the .exe (portable), then one in %APPDATA%\MolehillManager.
    /// A new file goes next to the .exe when that folder is writable, else in %APPDATA%.
    /// </summary>
    public static string Resolve(string? explicitPath)
    {
        if (!string.IsNullOrWhiteSpace(explicitPath)) return Path.GetFullPath(explicitPath);
        if (File.Exists(ExeFolderPath)) return ExeFolderPath;
        if (File.Exists(AppDataPath)) return AppDataPath;
        return IsWritable(AppContext.BaseDirectory) ? ExeFolderPath : AppDataPath;
    }

    private static bool IsWritable(string folder)
    {
        try
        {
            var probe = Path.Combine(folder, $".mm-write-test-{Guid.NewGuid():N}");
            File.WriteAllText(probe, "");
            File.Delete(probe);
            return true;
        }
        catch { return false; }
    }

    /// <summary>Reads the file (a missing file gives defaults). A plain-text password is moved into Secret.</summary>
    public static AppConfig Load(string path, out bool existed)
    {
        existed = File.Exists(path);
        var config = existed
            ? JsonSerializer.Deserialize<AppConfig>(LiteralBackslashes(File.ReadAllText(path)), Options) ?? new AppConfig()
            : new AppConfig();
        config.Connection ??= new ConnectionConfig();
        if (string.IsNullOrWhiteSpace(config.OutputFolder)) config.OutputFolder = existed ? "" : AppConfig.DefaultOutputFolder;

        var c = config.Connection;
        if (!string.IsNullOrEmpty(c.Password))
        {
            config.Secret = c.Password;            // typed into the file by hand: used now, encrypted on save
            config.PlainTextSecretFound = true;
            c.Password = null;
        }
        else if (!string.IsNullOrEmpty(c.PasswordEncrypted))
        {
            try { config.Secret = OperatingSystem.IsWindows() ? Unprotect(c.PasswordEncrypted) : throw new PlatformNotSupportedException(); }
            catch { config.SecretUnreadable = true; }   // encrypted by another Windows user or on another machine
        }
        return config;
    }

    /// <summary>
    /// People editing the file type Windows names as they are (SQL01\INST, D:\Reports). In JSON that is either
    /// invalid or, worse, silently wrong (\r becomes a carriage return), so a backslash that isn't already
    /// escaping a backslash or a quote is taken literally. Properly escaped files read the same either way.
    /// </summary>
    internal static string LiteralBackslashes(string json)
    {
        var sb = new StringBuilder(json.Length + 16);
        for (var i = 0; i < json.Length; i++)
        {
            if (json[i] == '\\' && i + 1 < json.Length && (json[i + 1] == '\\' || json[i + 1] == '"'))
            {
                sb.Append(json, i, 2);
                i++;
            }
            else if (json[i] == '\\') sb.Append(@"\\");
            else sb.Append(json[i]);
        }
        return sb.ToString();
    }

    /// <summary>Writes the file. The secret is only stored when SavePassword is on, and only ever encrypted.</summary>
    public static void Save(string path, AppConfig config)
    {
        var c = config.Connection;
        c.Password = null;
        c.PasswordEncrypted = c.SavePassword && AppConfig.NeedsSecret(c.Authentication) && !string.IsNullOrEmpty(config.Secret) && OperatingSystem.IsWindows()
            ? Protect(config.Secret)
            : null;
        var folder = Path.GetDirectoryName(path);
        if (!string.IsNullOrEmpty(folder)) Directory.CreateDirectory(folder);
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(config, Options));
        File.Move(temp, path, overwrite: true);
    }

    public static bool CanProtect => OperatingSystem.IsWindows();

    // extra entropy ties the blob to this app as well as to the Windows user
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Molehill Manager / MolehillAdmin connection secret");

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static string Protect(string value) =>
        Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), Entropy, DataProtectionScope.CurrentUser));

    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private static string Unprotect(string value) =>
        Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(value), Entropy, DataProtectionScope.CurrentUser));

    /// <summary>Connects and checks this is a current MolehillAdmin database. Returns null when it is fine.</summary>
    public static string? Check(string connectionString)
    {
        try
        {
            var db = new AdminDb(connectionString);
            var ok = db.Scalar("SELECT CASE WHEN OBJECT_ID(N'dbo.usp_Dashboard') IS NOT NULL AND OBJECT_ID(N'dbo.Agreement') IS NOT NULL THEN 1 ELSE 0 END");
            if (Convert.ToInt32(ok) != 1)
                return "Connected, but this database has no MolehillAdmin objects. Install it with Admin\\Install-MolehillAdmin.ps1, or pick the right database.";
            if (db.Scalar("SELECT COL_LENGTH(N'dbo.Instance', N'Platform')") == null)
                return "This MolehillAdmin is from before the Azure SQL update. Re-run Admin\\Install-MolehillAdmin.ps1 to upgrade it (your data is kept).";
            return null;
        }
        catch (Exception ex)
        {
            return AdminDb.Describe(ex);
        }
    }
}
