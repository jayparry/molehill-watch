using Microsoft.Data.SqlClient;

namespace SqlConnectionTester;

/// <summary>Every authentication method the tester can build a connection string for.</summary>
public enum AuthMethod
{
    WindowsIntegrated,
    SqlLogin,
    EntraPassword,
    EntraIntegrated,
    EntraInteractive,
    EntraDeviceCode,
    EntraServicePrincipal,
    EntraManagedIdentity,
    EntraDefault
}

public static class AuthMethodInfo
{
    /// <summary>Menu label, and what the method needs from the user.</summary>
    public static readonly (AuthMethod Method, string Label, string Hint, bool NeedsUser, bool NeedsPassword)[] All =
    {
        (AuthMethod.WindowsIntegrated,    "Windows authentication",        "Signed-in Windows account (Integrated Security)",            false, false),
        (AuthMethod.SqlLogin,             "SQL Server authentication",     "SQL login and password",                                    true,  true),
        (AuthMethod.EntraPassword,        "Entra ID - password",           "Entra user name and password (no MFA)",                     true,  true),
        (AuthMethod.EntraIntegrated,      "Entra ID - integrated",         "Domain-joined single sign-on",                              false, false),
        (AuthMethod.EntraInteractive,     "Entra ID - interactive (MFA)",  "Opens a browser prompt; user name optional",                 true,  false),
        (AuthMethod.EntraDeviceCode,      "Entra ID - device code",        "Shows a code to enter on another device",                    false, false),
        (AuthMethod.EntraServicePrincipal,"Entra ID - service principal",  "Application (client) id and secret",                         true,  true),
        (AuthMethod.EntraManagedIdentity, "Entra ID - managed identity",   "Azure VM identity; user name = client id for user-assigned", true,  false),
        (AuthMethod.EntraDefault,         "Entra ID - default",            "Tries environment, managed identity, Azure CLI, browser",    true,  false)
    };

    public static string Label(AuthMethod m) => All.First(a => a.Method == m).Label;
    public static bool NeedsUser(AuthMethod m) => All.First(a => a.Method == m).NeedsUser;
    public static bool NeedsPassword(AuthMethod m) => All.First(a => a.Method == m).NeedsPassword;
}

/// <summary>A saved connection. Either built from the fields below, or a raw connection string.</summary>
public class ConnectionProfile
{
    public string Name { get; set; } = "New connection";
    public bool UseRawConnectionString { get; set; }
    public string RawConnectionString { get; set; } = "";

    public string Server { get; set; } = "";
    public string Database { get; set; } = "";
    public AuthMethod Authentication { get; set; } = AuthMethod.WindowsIntegrated;
    public string UserId { get; set; } = "";

    /// <summary>Only written to disk when SavePassword is on, and then encrypted for the current Windows user.</summary>
    public string? ProtectedPassword { get; set; }
    public bool SavePassword { get; set; }

    [System.Text.Json.Serialization.JsonIgnore]
    public string Password { get; set; } = "";

    public string Encrypt { get; set; } = "Mandatory";          // Mandatory | Optional | Strict
    public bool TrustServerCertificate { get; set; }
    public string HostNameInCertificate { get; set; } = "";
    public string ApplicationName { get; set; } = "SQL Connection Tester";
    public bool ReadOnlyIntent { get; set; }
    public bool MultiSubnetFailover { get; set; }
    public string FailoverPartner { get; set; } = "";
    public int ConnectTimeoutSeconds { get; set; } = 15;
    public int CommandTimeoutSeconds { get; set; } = 30;

    /// <summary>Defaults to the agreed test query; can be overridden per connection.</summary>
    public string Query { get; set; } = DefaultQuery;

    public const string DefaultQuery = "SELECT TestText FROM dbo.TestConnection";

    public ConnectionProfile Clone()
    {
        var c = (ConnectionProfile)MemberwiseClone();
        c.Name = Name + " (copy)";
        return c;
    }

    /// <summary>The connection string as it will be used.</summary>
    public string Build()
    {
        if (UseRawConnectionString) return RawConnectionString;

        var b = new SqlConnectionStringBuilder
        {
            DataSource = Server,
            ApplicationName = string.IsNullOrWhiteSpace(ApplicationName) ? "SQL Connection Tester" : ApplicationName,
            ConnectTimeout = ConnectTimeoutSeconds,
            Pooling = false                     // always a fresh connection, so a test never reuses a pooled one
        };

        if (!string.IsNullOrWhiteSpace(Database)) b.InitialCatalog = Database;

        switch (Authentication)
        {
            case AuthMethod.WindowsIntegrated:
                b.IntegratedSecurity = true;
                break;
            case AuthMethod.SqlLogin:
                b.UserID = UserId;
                b.Password = Password;
                break;
            case AuthMethod.EntraPassword:
#pragma warning disable CS0618 // deprecated by Microsoft, but still in use and asked for here
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryPassword;
#pragma warning restore CS0618
                b.UserID = UserId;
                b.Password = Password;
                break;
            case AuthMethod.EntraIntegrated:
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryIntegrated;
                break;
            case AuthMethod.EntraInteractive:
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryInteractive;
                if (!string.IsNullOrWhiteSpace(UserId)) b.UserID = UserId;
                break;
            case AuthMethod.EntraDeviceCode:
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryDeviceCodeFlow;
                break;
            case AuthMethod.EntraServicePrincipal:
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryServicePrincipal;
                b.UserID = UserId;
                b.Password = Password;
                break;
            case AuthMethod.EntraManagedIdentity:
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryManagedIdentity;
                if (!string.IsNullOrWhiteSpace(UserId)) b.UserID = UserId;   // user-assigned identity client id
                break;
            case AuthMethod.EntraDefault:
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryDefault;
                if (!string.IsNullOrWhiteSpace(UserId)) b.UserID = UserId;
                break;
        }

        b.Encrypt = Encrypt switch
        {
            "Optional" => SqlConnectionEncryptOption.Optional,
            "Strict" => SqlConnectionEncryptOption.Strict,
            _ => SqlConnectionEncryptOption.Mandatory
        };
        if (TrustServerCertificate) b.TrustServerCertificate = true;
        if (!string.IsNullOrWhiteSpace(HostNameInCertificate)) b.HostNameInCertificate = HostNameInCertificate;
        if (ReadOnlyIntent) b.ApplicationIntent = ApplicationIntent.ReadOnly;
        if (MultiSubnetFailover) b.MultiSubnetFailover = true;
        if (!string.IsNullOrWhiteSpace(FailoverPartner)) b.FailoverPartner = FailoverPartner;

        return b.ConnectionString;
    }

    /// <summary>The connection string with any password replaced by ***, for display and reports.</summary>
    public static string Mask(string connectionString) =>
        System.Text.RegularExpressions.Regex.Replace(connectionString, @"(?i)\b(password|pwd)\s*=\s*[^;]*", "$1=***");

    public string Describe()
    {
        if (UseRawConnectionString) return "Raw connection string";
        var bits = new List<string> { AuthMethodInfo.Label(Authentication) };
        if (!string.IsNullOrWhiteSpace(Database)) bits.Add($"database {Database}");
        bits.Add($"encrypt {Encrypt}{(TrustServerCertificate ? " (trust cert)" : "")}");
        if (ReadOnlyIntent) bits.Add("read-only intent");
        if (MultiSubnetFailover) bits.Add("multi-subnet failover");
        return string.Join(", ", bits);
    }
}
