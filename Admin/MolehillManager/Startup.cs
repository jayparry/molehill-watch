using Terminal.Gui;

namespace MolehillManager;

/// <summary>Start-up: asks for whatever the config file is missing, saves it, and connects.</summary>
public static class Startup
{
    /// <summary>Fills in whatever the config lacks, then connects. Returns a working connection string, or null if the user gave up.</summary>
    public static string? Connect(AppConfig config, string path, bool existed, bool forceSetup, bool loadFailed)
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
                if (SetupDialog.Show(config, path, why) != SetupResult.Saved) return null;
                forceSetup = false;
                reason = null;
            }

            if (config.NeedsSecretPrompt)
            {
                var who = config.Connection.User == "" ? config.Describe() : $"{config.Connection.User} on {config.Connection.Server}";
                var prompt = config.SecretUnreadable
                    ? "The saved password was encrypted by another Windows user or on another machine, so it can't be used here. Type it again."
                    : $"Sign in as {who}.";
                var secret = SetupDialog.AskSecret(config, path, prompt);
                if (secret == null) return null;
                if (secret == "") { forceSetup = true; continue; }     // "Settings..." pressed
            }

            var connectionString = config.BuildConnectionString();
            var error = ConfigStore.Check(connectionString);
            if (error == null) return connectionString;
            var first = error.Split('\n')[0];
            reason = "Could not connect: " + (first.Length > 170 ? first[..170] + "..." : first) + " (Test shows the full error.)";
        }
    }
}
