namespace MolehillManager;

public enum SetupResult { Cancelled, Saved }

/// <summary>
///   What the settings screen holds, as the plain text a person typed. The screen's only job is to
///   fill one of these in and hand it to <see cref="Setup.Examine"/>; every rule about what makes a
///   setting acceptable lives there, where a test can reach it without a screen of any kind.
/// </summary>
public sealed class SettingsDraft
{
    public string Server { get; set; } = "";
    public string Database { get; set; } = "";
    public string Authentication { get; set; } = "Windows";
    public string User { get; set; } = "";
    public string Secret { get; set; } = "";
    public bool SavePassword { get; set; } = true;
    public string Encrypt { get; set; } = "Mandatory";
    public bool TrustServerCertificate { get; set; } = true;
    public string Timeout { get; set; } = "15";
    public string OutputFolder { get; set; } = "";
    public string AutoRefresh { get; set; } = "0";

    /// <summary>The draft a screen starts from: whatever the config file already says.</summary>
    public static SettingsDraft From(AppConfig config)
    {
        var c = config.Connection;
        return new SettingsDraft
        {
            Server = c.Server,
            Database = c.Database,
            Authentication = c.Authentication,
            User = c.User,
            Secret = config.Secret ?? "",
            SavePassword = c.SavePassword,
            Encrypt = c.Encrypt,
            TrustServerCertificate = c.TrustServerCertificate,
            Timeout = c.ConnectTimeoutSeconds.ToString(),
            OutputFolder = config.OutputFolder,
            AutoRefresh = config.AutoRefreshMinutes.ToString()
        };
    }

    /// <summary>
    ///   The settings this draft would make, or null and a sentence saying what is wrong with it.
    ///   Built on a copy of <paramref name="current"/>, so a draft that is never committed - or is
    ///   only being tested - leaves the live config untouched.
    /// </summary>
    public AppConfig? Validate(AppConfig current, out string? problem)
    {
        problem = null;
        var copy = new AppConfig
        {
            Connection = current.Connection.Clone(),
            OutputFolder = OutputFolder.Trim(),
            AutoRefreshMinutes = current.AutoRefreshMinutes,
            Secret = Secret
        };
        var c = copy.Connection;
        c.Server = Server.Trim();
        c.Database = Database.Trim();
        c.Authentication = Authentication;
        c.User = AppConfig.AllowsUser(c.Authentication) ? User.Trim() : "";
        c.SavePassword = SavePassword;
        c.Encrypt = Encrypt;
        c.TrustServerCertificate = TrustServerCertificate;

        if (!int.TryParse(Timeout, out var t) || t < 1 || t > 600) { problem = "Timeout must be 1 - 600 seconds."; return null; }
        c.ConnectTimeoutSeconds = t;
        if (!int.TryParse(AutoRefresh, out var r) || r < 0 || r > 1440) { problem = "Auto refresh must be 0 - 1440 minutes."; return null; }
        copy.AutoRefreshMinutes = r;
        if (!AppConfig.NeedsSecret(c.Authentication)) copy.Secret = null;

        var missing = copy.Missing();
        if (AppConfig.NeedsSecret(c.Authentication) && string.IsNullOrEmpty(copy.Secret))
            missing.Add(c.Authentication == "EntraServicePrincipal" ? "client secret" : "password");
        if (missing.Count > 0) { problem = "Still needed: " + string.Join(", ", missing) + "."; return null; }
        return copy;
    }
}

/// <summary>What a draft turned out to be worth: this is what a settings screen decides from.</summary>
public enum SaveVerdict
{
    /// <summary>The draft is not usable. <see cref="SaveCheck.Problem"/> says why.</summary>
    Invalid,
    /// <summary>Nothing answered. Saving is allowed, but only after asking.</summary>
    Unreachable,
    /// <summary>The server answered and MolehillAdmin can be created, installed or upgraded.</summary>
    CanInstall,
    /// <summary>The database is there and current.</summary>
    Ready
}

/// <param name="Candidate">The settings the draft makes - null only when <c>Invalid</c>.</param>
/// <param name="Problem">Why the draft is unusable - set only when <c>Invalid</c>.</param>
/// <param name="Database">What the server said - null only when <c>Invalid</c>.</param>
public sealed record SaveCheck(SaveVerdict Verdict, AppConfig? Candidate, string? Problem, DbCheck? Database);

/// <summary>
///   How a typed password went. <paramref name="Problem"/> means the server refused it and nothing
///   was saved; <paramref name="WriteProblem"/> means it worked but could not be remembered, which
///   is worth saying and not worth stopping for - the app connects, and asks again next time.
/// </summary>
public sealed record SecretResult(string? Problem, string? WriteProblem)
{
    public bool Worked => Problem == null;
}

/// <summary>
///   The settings screen's decisions, with no screen: what a draft is worth, and what writing it
///   does. Terminal.Gui, WPF and the self-test all go through here, so there is one set of rules
///   about timeouts, missing fields, the output folder and when a password is stored.
/// </summary>
public static class Setup
{
    /// <summary>Validates a draft and asks the server about it. Nothing is written.</summary>
    public static SaveCheck Examine(SettingsDraft draft, AppConfig current)
    {
        var candidate = draft.Validate(current, out var problem);
        if (candidate == null) return new SaveCheck(SaveVerdict.Invalid, null, problem, null);
        var check = AdminInstaller.Inspect(candidate);
        var verdict = check.State == DbState.Ready ? SaveVerdict.Ready
                    : check.CanInstall ? SaveVerdict.CanInstall
                    : SaveVerdict.Unreachable;
        return new SaveCheck(verdict, candidate, null, check);
    }

    /// <summary>
    ///   Makes the output folder, copies the candidate into the live config and writes the file.
    ///   Returns null when that all worked, or a sentence naming what did not.
    /// </summary>
    public static string? Commit(AppConfig config, string path, AppConfig candidate)
    {
        try { Directory.CreateDirectory(candidate.OutputFolder); }
        catch (Exception ex) { return $"Could not create {candidate.OutputFolder}:\n{ex.Message}"; }

        config.Connection = candidate.Connection;
        config.OutputFolder = candidate.OutputFolder;
        config.AutoRefreshMinutes = candidate.AutoRefreshMinutes;
        config.Secret = candidate.Secret;
        config.SecretUnreadable = false;
        try { ConfigStore.Save(path, config); }
        catch (Exception ex) { return $"Could not write {path}:\n{ex.Message}"; }
        return null;
    }

    /// <summary>
    ///   Tries a password that has just been typed, and remembers it if it works. The password is
    ///   put back to nothing when the server refuses it, so a failed attempt leaves no trace.
    /// </summary>
    public static SecretResult TrySecret(AppConfig config, string path, string value, bool remember)
    {
        config.Secret = value;
        var check = AdminInstaller.Inspect(config);
        if (check.State == DbState.Error) { config.Secret = null; return new SecretResult(check.Message, null); }
        config.Connection.SavePassword = remember;
        try { ConfigStore.Save(path, config); }
        catch (Exception ex) { return new SecretResult(null, $"Could not write {path}:\n{ex.Message}"); }
        return new SecretResult(null, null);
    }

    /// <summary>The sentence under the sign-in choices. Data, not decoration: each method needs different things.</summary>
    public static string AuthHint(string method) => method switch
    {
        "Windows" => "Signs in as the Windows account running Molehill Manager.",
        "SqlLogin" => "SQL Server authentication: login name and password.",
        "EntraInteractive" => "Opens a browser sign-in (MFA supported). User name is optional (pre-fills the prompt).",
        "EntraPassword" => "Entra user name and password. Deprecated by Microsoft; does not work with MFA.",
        "EntraServicePrincipal" => "App registration: its application (client) id and a client secret.",
        "EntraManagedIdentity" => "Azure VMs only. Client id for a user-assigned identity; blank for system-assigned.",
        _ => "Tries environment variables, managed identity, Azure CLI (az login), then a browser."
    };

    /// <summary>The three encryption settings, in the order a screen offers them.</summary>
    public static readonly string[] EncryptOptions = { "Mandatory", "Optional", "Strict" };
}

/// <summary>
///   Everything start-up has to ask a person, with nothing about how. <see cref="Startup.Connect"/>
///   decides what to ask and what to do with the answer; an implementation of this decides whether
///   that is a Terminal.Gui dialog, a WPF window, or a script in the self-test.
/// </summary>
public interface IStartupPrompts
{
    /// <summary>The full settings screen. <paramref name="why"/> says what brought it up.</summary>
    SetupResult AskSettings(AppConfig config, string path, string why);

    /// <summary>
    ///   Just the password, when the config file has everything else. Null means the person gave up;
    ///   an empty string means they asked for the full settings screen instead.
    /// </summary>
    string? AskSecret(AppConfig config, string path, string prompt);

    /// <summary>A question with named buttons. Returns which one, counting from zero.</summary>
    int Choose(string title, string message, params string[] buttons);

    /// <summary>Shows something long - an install log, or an error in full.</summary>
    void ShowText(string title, string text);

    /// <summary>
    ///   Creates, installs or upgrades the database, showing progress as it goes. Returns null when
    ///   it worked, with what it did in <paramref name="messages"/>, or the error in full.
    /// </summary>
    string? RunInstall(AppConfig config, out List<string> messages);

    /// <summary>Puts one form up (the business details, after a fresh install) and reports its own failures.</summary>
    void RunForm(FormSpec spec);
}
