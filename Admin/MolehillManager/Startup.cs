using Terminal.Gui;

namespace MolehillManager;

/// <summary>Start-up: asks for whatever the config file is missing, saves it, and connects.</summary>
public static class Startup
{
    /// <summary>Fills in whatever the config lacks, then connects. Returns a working connection string, or null if the user gave up.</summary>
    private static string Shorten(string text)
    {
        var first = text.Split('\n')[0];
        return first.Length > 170 ? first[..170] + "..." : first;
    }

    private static void ShowText(string title, string text) => Output.Text(title, text);

    /// <summary>Runs the install with a progress window. Returns null on success, or the full error.</summary>
    private static string? RunInstall(AppConfig config, out List<string> messages)
    {
        var collected = new List<string>();
        string? error = null;
        var label = new Label("Starting...") { X = 1, Y = 1, Width = Dim.Fill(1) };
        var dialog = new Dialog($"Installing MolehillAdmin into [{config.Connection.Database}]", 72, 7);
        dialog.Add(label, new Label("This takes a few seconds.") { X = 1, Y = 3, ColorScheme = Colors.Menu });
        var worker = Task.Run(() =>
        {
            try { collected = AdminInstaller.Install(config, s => Application.MainLoop?.Invoke(() => label.Text = s)); }
            catch (Exception ex) { error = ex is InvalidOperationException ? ex.Message : AdminDb.Describe(ex); }
            finally { Application.MainLoop?.Invoke(() => Application.RequestStop(dialog)); }
        });
        Application.Run(dialog);
        worker.Wait();
        messages = collected;
        return error;
    }

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
                var choice = MessageBox.Query(title, check.Message, button, "Settings...", "Quit");
                if (choice == 1) { forceSetup = true; continue; }
                if (choice != 0) return null;
                var fresh = check.State != DbState.NeedsUpgrade;
                var error = RunInstall(config, out var messages);
                if (error != null) { reason = "The install failed: " + Shorten(error) + " (Test shows the connection details.)"; ShowText("Install failed", error); continue; }
                ShowText(fresh ? "MolehillAdmin installed" : "MolehillAdmin upgraded",
                    string.Join("\n", messages.Where(m => !string.IsNullOrWhiteSpace(m)).Take(40))
                    + "\n\nNot set up by the app: the scheduled daily billing run and HTML export. Use F6 (Run billing) in the app,"
                    + "\nor run Admin\\Install-MolehillAdmin.ps1 on this machine to schedule it.");
                if (fresh)
                    Ui.Try("Business details", () => Ui.Form(AdminForms.BusinessDetails(new AdminDb(config.BuildConnectionString())), null));
                continue;   // inspect again: should now be Ready
            }

            reason = check.State == DbState.Error ? "Could not connect: " + Shorten(check.Message) + " (Test shows the full error.)" : check.Message;
        }
    }
}
