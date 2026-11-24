namespace MolehillManager;

/// <summary>Which front end to put up.</summary>
public enum FrontEnd
{
    /// <summary>Terminal.Gui, in the console it was started from.</summary>
    Terminal,
    /// <summary>The window.</summary>
    Window
}

/// <summary>
///   Start-up: asks for whatever the config file is missing, saves it, and connects. Every question
///   goes through <see cref="IStartupPrompts"/>, so the retry loop - missing settings, an unreadable
///   password, a database that is not there yet, one that needs upgrading, an install that failed -
///   is written once and does not know whether it is talking to a terminal, a window or a script.
/// </summary>
public static class Startup
{
    /// <summary>
    ///   What you get by saying nothing. It is the terminal until the window can do everything the
    ///   terminal can; moving it is the one line that makes the window the double-click default, and
    ///   the self-test says so when it changes, so the help text and both READMEs are not left behind.
    /// </summary>
    public const FrontEnd Default = FrontEnd.Terminal;

    /// <summary>
    ///   Which front end to start. --tui always means the terminal and wins over --gui, because it
    ///   is the one that can do everything; --gui asks for the window whatever the default is, which
    ///   is how the window is reachable while the default is still the terminal; silence means the
    ///   default.
    /// </summary>
    public static FrontEnd ChooseFrontEnd(bool tuiAsked, bool guiAsked = false) =>
        tuiAsked ? FrontEnd.Terminal : guiAsked ? FrontEnd.Window : Default;

    private static string Shorten(string text)
    {
        var first = text.Split('\n')[0];
        return first.Length > 170 ? first[..170] + "..." : first;
    }

    /// <summary>Fills in whatever the config lacks, then connects. Returns a working connection string, or null if the user gave up.</summary>
    public static string? Connect(IStartupPrompts prompts, AppConfig config, string path, bool existed, bool forceSetup, bool loadFailed)
    {
        string? reason = null;
        while (true)
        {
            var missing = config.Missing();
            if (forceSetup || missing.Count > 0 || reason != null)
            {
                var why = reason
                          ?? (loadFailed || !existed ? "First run: where is MolehillAdmin, and how should Molehill Manager sign in? These settings are saved to the config file below."
                              : missing.Count > 0 ? $"The config file doesn't have: {string.Join(", ", missing)}. Fill it in and Save."
                              : "Change the settings and Save. Molehill Manager reconnects straight away.");
                if (prompts.AskSettings(config, path, why) != SetupResult.Saved) return null;
                forceSetup = false;
                reason = null;
            }

            if (config.NeedsSecretPrompt)
            {
                var who = config.Connection.User == "" ? config.Describe() : $"{config.Connection.User} on {config.Connection.Server}";
                var prompt = config.SecretUnreadable
                    ? "The saved password was encrypted by another Windows user or on another machine, so it can't be used here. Type it again."
                    : $"Sign in as {who}.";
                var secret = prompts.AskSecret(config, path, prompt);
                if (secret == null) return null;
                if (secret == "") { forceSetup = true; continue; }     // "Settings..." pressed
            }

            var check = AdminInstaller.Inspect(config);
            if (check.State == DbState.Ready) return config.BuildConnectionString();

            if (check.CanInstall)
            {
                var (title, button) = check.State switch
                {
                    DbState.DatabaseMissing => ("Create MolehillAdmin", "Create and install"),
                    DbState.NeedsUpgrade => ("Upgrade MolehillAdmin", "Upgrade"),
                    _ => ("Install MolehillAdmin", "Install")
                };
                var choice = prompts.Choose(title, check.Message, button, "Settings...", "Quit");
                if (choice == 1) { forceSetup = true; continue; }
                if (choice != 0) return null;
                var fresh = check.State != DbState.NeedsUpgrade;
                var error = prompts.RunInstall(config, out var messages);
                if (error != null)
                {
                    reason = "The install failed: " + Shorten(error) + " (Test shows the connection details.)";
                    prompts.ShowText("Install failed", error);
                    continue;
                }
                prompts.ShowText(fresh ? "MolehillAdmin installed" : "MolehillAdmin upgraded",
                    string.Join("\n", messages.Where(m => !string.IsNullOrWhiteSpace(m)).Take(40))
                    + "\n\nNot set up by the app: the scheduled daily billing run and HTML export. Use F6 (Run billing) in the app,"
                    + "\nor run Admin\\Install-MolehillAdmin.ps1 on this machine to schedule it.");
                if (fresh)
                    prompts.RunForm(AdminForms.BusinessDetails(new AdminDb(config.BuildConnectionString())));
                continue;   // inspect again: should now be Ready
            }

            reason = check.State == DbState.Error ? "Could not connect: " + Shorten(check.Message) + " (Test shows the full error.)" : check.Message;
        }
    }
}
