using Terminal.Gui;

namespace MolehillManager;

/// <summary>
/// The settings screen. Shown on first run, whenever the config file is missing something, when the
/// connection fails, and from File &gt; Settings. Everything it asks for is written to the config file.
/// This is the layout and nothing else: what makes a setting acceptable, and what saving does, is in
/// <see cref="Setup"/>, where the WPF screen and the self-test reach the same rules.
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

        var encrypt = new RadioGroup(Setup.EncryptOptions.Select(o => (NStack.ustring)o).ToArray())
        {
            X = 58, Y = 4, SelectedItem = Math.Max(0, Array.IndexOf(Setup.EncryptOptions, c.Encrypt))
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
            hint.Text = Setup.AuthHint(m);
        }
        auth.SelectedItemChanged += _ => Sync();
        Sync();

        // what is on the screen, as typed. Setup.Examine decides what it is worth, on a copy, so
        // Cancel - and Test - leave the config untouched.
        SettingsDraft Draft() => new()
        {
            Server = server.Text.ToString() ?? "",
            Database = database.Text.ToString() ?? "",
            Authentication = Method(),
            User = user.Text.ToString() ?? "",
            Secret = password.Text.ToString() ?? "",
            SavePassword = savePassword.Checked,
            Encrypt = Setup.EncryptOptions[encrypt.SelectedItem],
            TrustServerCertificate = trust.Checked,
            Timeout = timeout.Text.ToString() ?? "",
            OutputFolder = output.Text.ToString() ?? "",
            AutoRefresh = refresh.Text.ToString() ?? ""
        };

        test.Clicked += () =>
        {
            var examined = Setup.Examine(Draft(), config);
            switch (examined.Verdict)
            {
                case SaveVerdict.Invalid:
                    MessageBox.ErrorQuery("Settings", examined.Problem!, "Ok");
                    break;
                case SaveVerdict.Ready:
                    MessageBox.Query("Settings", $"Connected to {examined.Candidate!.Describe()}.", "Ok");
                    break;
                case SaveVerdict.CanInstall:
                    MessageBox.Query("Settings", $"The server is reachable.\n\n{examined.Database!.Message}\n\nPress Save and Molehill Manager will offer to do it.", "Ok");
                    break;
                default:
                    MessageBox.ErrorQuery("Could not connect", examined.Database!.Message, "Ok");
                    break;
            }
        };

        save.Clicked += () =>
        {
            var examined = Setup.Examine(Draft(), config);
            if (examined.Verdict == SaveVerdict.Invalid) { MessageBox.ErrorQuery("Settings", examined.Problem!, "Ok"); return; }
            if (examined.Verdict == SaveVerdict.Unreachable
                && MessageBox.ErrorQuery("Could not connect", examined.Database!.Message + "\n\nSave these settings anyway?", "Keep editing", "Save anyway") != 1) return;
            var error = Setup.Commit(config, path, examined.Candidate!);
            if (error != null) { MessageBox.ErrorQuery("Settings", error, "Ok"); return; }
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
            var tried = Setup.TrySecret(config, path, value, remember.Checked);
            if (!tried.Worked) { MessageBox.ErrorQuery("Could not connect", tried.Problem!, "Ok"); return; }
            if (tried.WriteProblem != null) MessageBox.ErrorQuery("Settings", tried.WriteProblem, "Ok");
            secret = value;
            Application.RequestStop();
        };
        settings.Clicked += () => { secret = ""; Application.RequestStop(); };   // "" = open the full settings instead
        cancel.Clicked += () => Application.RequestStop();
        Application.Run(dialog);
        return secret;
    }
}

/// <summary>
///   Start-up's questions, asked in the terminal. This is the whole of what the Terminal.Gui front
///   end contributes to starting up; <see cref="Startup.Connect"/> holds the decisions.
/// </summary>
public sealed class TerminalPrompts : IStartupPrompts
{
    public SetupResult AskSettings(AppConfig config, string path, string why) => SetupDialog.Show(config, path, why);

    public string? AskSecret(AppConfig config, string path, string prompt) => SetupDialog.AskSecret(config, path, prompt);

    public int Choose(string title, string message, params string[] buttons) =>
        MessageBox.Query(title, message, buttons.Select(b => (NStack.ustring)b).ToArray());

    public void ShowText(string title, string text) => Output.Text(title, text);

    public void RunForm(FormSpec spec) => Ui.Try(spec.Title, () => Ui.Form(spec, null));

    /// <summary>Runs the install with a progress window. Returns null on success, or the full error.</summary>
    public string? RunInstall(AppConfig config, out List<string> messages)
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
}
