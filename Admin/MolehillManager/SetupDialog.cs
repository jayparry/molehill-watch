using Terminal.Gui;

namespace MolehillManager;

public enum SetupResult { Cancelled, Saved }

/// <summary>
/// The settings screen. Shown on first run, whenever the config file is missing something, when the
/// connection fails, and from File > Settings. Everything it asks for is written to the config file.
/// </summary>
public static class SetupDialog
{
    public static SetupResult Show(AppConfig config, string path, string reason)
    {
        var dialog = Create(config, path, reason, out var result);
        Application.Run(dialog);
        return result();
    }

    /// <summary>Builds the dialog without running it (also used by the self-test).</summary>
    public static Dialog Create(AppConfig config, string path, string reason, out Func<SetupResult> result)
    {
        var outcome = SetupResult.Cancelled;
        result = () => outcome;
        var c = config.Connection;

        var test = new Button("Test");
        var save = new Button("Save", true);
        var cancel = new Button("Cancel");
        var dialog = new Dialog("Molehill Manager settings", 92, 30, test, save, cancel);

        Label L(string text, int y) => new(text) { X = 1, Y = y };
        var why = new Label(reason) { X = 1, Y = 0, Width = Dim.Fill(1), Height = 2, ColorScheme = Colors.Error };
        var server = new TextField(c.Server) { X = 20, Y = 3, Width = 34 };
        var database = new TextField(c.Database) { X = 20, Y = 5, Width = 34 };
        var auth = new RadioGroup(AppConfig.AuthLabels.Select(l => (NStack.ustring)l).ToArray())
        {
            X = 20, Y = 7, SelectedItem = Math.Max(0, Array.IndexOf(AppConfig.AuthMethods, c.Authentication))
        };
        var user = new TextField(c.User) { X = 20, Y = 15, Width = 34 };
        var password = new TextField(config.Secret ?? "") { X = 20, Y = 16, Width = 34, Secret = true };
        var savePassword = new CheckBox("Remember it (encrypted for this Windows user)", c.SavePassword) { X = 20, Y = 17 };

        var encrypt = new RadioGroup(new NStack.ustring[] { "Mandatory", "Optional", "Strict" })
        {
            X = 58, Y = 4, SelectedItem = Math.Max(0, Array.IndexOf(new[] { "Mandatory", "Optional", "Strict" }, c.Encrypt))
        };
        var trust = new CheckBox("Trust server certificate", c.TrustServerCertificate) { X = 58, Y = 8 };
        var timeout = new TextField(c.ConnectTimeoutSeconds.ToString()) { X = 76, Y = 10, Width = 5 };

        var output = new TextField(config.OutputFolder) { X = 20, Y = 19, Width = 66 };
        var refresh = new TextField(config.AutoRefreshMinutes.ToString()) { X = 20, Y = 21, Width = 5 };
        var hint = new Label("") { X = 1, Y = 23, Width = Dim.Fill(1), Height = 2, ColorScheme = Colors.Menu };

        dialog.Add(why,
                   L("Server:", 3), server, L("Database:", 5), database,
                   L("Sign in with:", 7), auth,
                   L("User / client id:", 15), user, L("Password / secret:", 16), password, savePassword,
                   new Label("Encryption:") { X = 58, Y = 3 }, encrypt, trust,
                   new Label("Timeout (seconds):") { X = 58, Y = 10 }, timeout,
                   L("Output folder:", 19), output,
                   L("Auto refresh:", 21), refresh, new Label("minutes (0 = only on F5)") { X = 26, Y = 21 },
                   hint,
                   new Label($"Saved to {path}") { X = 1, Y = 25, Width = Dim.Fill(1), ColorScheme = Colors.Menu });

        string Method() => AppConfig.AuthMethods[auth.SelectedItem];
        void Sync()
        {
            var m = Method();
            user.Enabled = AppConfig.AllowsUser(m);
            password.Enabled = savePassword.Enabled = AppConfig.NeedsSecret(m);
            hint.Text = m switch
            {
                "Windows" => "Signs in as the Windows account running Molehill Manager.",
                "SqlLogin" => "SQL Server authentication: login name and password.",
                "EntraInteractive" => "Opens a browser sign-in (MFA supported). User name is optional (pre-fills the prompt).",
                "EntraPassword" => "Entra user name and password. Deprecated by Microsoft; does not work with MFA.",
                "EntraServicePrincipal" => "App registration: its application (client) id and a client secret.",
                "EntraManagedIdentity" => "Azure VMs only. Client id for a user-assigned identity; blank for system-assigned.",
                _ => "Tries environment variables, managed identity, Azure CLI (az login), then a browser."
            };
        }
        auth.SelectedItemChanged += _ => Sync();
        Sync();

        // read the screen into a copy, so Cancel leaves the config untouched
        AppConfig? Read(out string? problem)
        {
            problem = null;
            var copy = new AppConfig
            {
                Connection = c.Clone(),
                OutputFolder = output.Text.ToString()?.Trim() ?? "",
                AutoRefreshMinutes = config.AutoRefreshMinutes,
                Secret = password.Text.ToString()
            };
            var cc = copy.Connection;
            cc.Server = server.Text.ToString()?.Trim() ?? "";
            cc.Database = database.Text.ToString()?.Trim() ?? "";
            cc.Authentication = Method();
            cc.User = AppConfig.AllowsUser(cc.Authentication) ? user.Text.ToString()?.Trim() ?? "" : "";
            cc.SavePassword = savePassword.Checked;
            cc.Encrypt = encrypt.SelectedItem switch { 1 => "Optional", 2 => "Strict", _ => "Mandatory" };
            cc.TrustServerCertificate = trust.Checked;
            if (!int.TryParse(timeout.Text.ToString(), out var t) || t < 1 || t > 600) { problem = "Timeout must be 1 - 600 seconds."; return null; }
            cc.ConnectTimeoutSeconds = t;
            if (!int.TryParse(refresh.Text.ToString(), out var r) || r < 0 || r > 1440) { problem = "Auto refresh must be 0 - 1440 minutes."; return null; }
            copy.AutoRefreshMinutes = r;
            if (!AppConfig.NeedsSecret(cc.Authentication)) copy.Secret = null;

            var missing = copy.Missing();
            if (AppConfig.NeedsSecret(cc.Authentication) && string.IsNullOrEmpty(copy.Secret))
                missing.Add(cc.Authentication == "EntraServicePrincipal" ? "client secret" : "password");
            if (missing.Count > 0) { problem = "Still needed: " + string.Join(", ", missing) + "."; return null; }
            return copy;
        }

        test.Clicked += () =>
        {
            var copy = Read(out var problem);
            if (copy == null) { MessageBox.ErrorQuery("Settings", problem!, "Ok"); return; }
            var error = ConfigStore.Check(copy.BuildConnectionString());
            if (error == null) MessageBox.Query("Settings", $"Connected to {copy.Describe()}.", "Ok");
            else MessageBox.ErrorQuery("Could not connect", error, "Ok");
        };

        save.Clicked += () =>
        {
            var copy = Read(out var problem);
            if (copy == null) { MessageBox.ErrorQuery("Settings", problem!, "Ok"); return; }
            var error = ConfigStore.Check(copy.BuildConnectionString());
            if (error != null && MessageBox.ErrorQuery("Could not connect", error + "\n\nSave these settings anyway?", "Keep editing", "Save anyway") != 1) return;
            try
            {
                Directory.CreateDirectory(copy.OutputFolder);
            }
            catch (Exception ex)
            {
                MessageBox.ErrorQuery("Output folder", $"Could not create {copy.OutputFolder}:\n{ex.Message}", "Ok");
                return;
            }
            config.Connection = copy.Connection;
            config.OutputFolder = copy.OutputFolder;
            config.AutoRefreshMinutes = copy.AutoRefreshMinutes;
            config.Secret = copy.Secret;
            config.SecretUnreadable = false;
            try { ConfigStore.Save(path, config); }
            catch (Exception ex) { MessageBox.ErrorQuery("Settings", $"Could not write {path}:\n{ex.Message}", "Ok"); return; }
            outcome = SetupResult.Saved;
            Application.RequestStop();
        };
        cancel.Clicked += () => Application.RequestStop();
        return dialog;
    }

    /// <summary>Asks for just the password when everything else is in the config file. Null = cancelled.</summary>
    public static string? AskSecret(AppConfig config, string path, string reason)
    {
        string? secret = null;
        var c = config.Connection;
        var ok = new Button("Connect", true);
        var settings = new Button("Settings...");
        var cancel = new Button("Cancel");
        var dialog = new Dialog("Sign in", 72, 12, ok, settings, cancel);
        var what = c.Authentication == "EntraServicePrincipal" ? "Client secret" : "Password";
        var field = new TextField("") { X = 18, Y = 3, Width = 48, Secret = true };
        var remember = new CheckBox("Remember it (encrypted for this Windows user)", c.SavePassword) { X = 18, Y = 5 };
        dialog.Add(new Label(reason) { X = 1, Y = 0, Width = Dim.Fill(1), Height = 2 },
                   new Label($"{what}:") { X = 1, Y = 3 }, field, remember);
        field.SetFocus();

        ok.Clicked += () =>
        {
            var value = field.Text.ToString() ?? "";
            if (value == "") { MessageBox.ErrorQuery("Sign in", $"Type the {what.ToLowerInvariant()}.", "Ok"); return; }
            config.Secret = value;
            var error = ConfigStore.Check(config.BuildConnectionString());
            if (error != null) { config.Secret = null; MessageBox.ErrorQuery("Could not connect", error, "Ok"); return; }
            c.SavePassword = remember.Checked;
            try { ConfigStore.Save(path, config); } catch (Exception ex) { MessageBox.ErrorQuery("Settings", $"Could not write {path}:\n{ex.Message}", "Ok"); }
            secret = value;
            Application.RequestStop();
        };
        settings.Clicked += () => { secret = ""; Application.RequestStop(); };   // "" = open the full settings instead
        cancel.Clicked += () => Application.RequestStop();
        Application.Run(dialog);
        return secret;
    }
}
