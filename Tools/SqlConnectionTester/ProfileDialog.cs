using Terminal.Gui;

namespace SqlConnectionTester;

/// <summary>Add / edit dialog: every connection and authentication option in one form.</summary>
public static class ProfileDialog
{
    public static bool Show(ConnectionProfile p, string title)
    {
        var dialog = Create(p, title, out var wasAccepted);
        Application.Run(dialog);
        return wasAccepted();
    }

    /// <summary>Builds the dialog without running it (used by Show, and by --ui-selftest).</summary>
    public static Dialog Create(ConnectionProfile p, string title, out Func<bool> wasAccepted)
    {
        var accepted = false;
        wasAccepted = () => accepted;

        var ok = new Button("Ok", true);
        var cancel = new Button("Cancel");
        var preview = new Button("Preview");
        var dialog = new Dialog(title, 92, 30, preview, ok, cancel);

        Label Lbl(string text, int x, int y) => new(text) { X = x, Y = y };
        TextField Fld(string value, int x, int y, int width, bool secret = false) =>
            new(value) { X = x, Y = y, Width = width, Secret = secret };

        // ---- left column: where and what
        var name = Fld(p.Name, 18, 1, 48);
        var server = Fld(p.Server, 18, 3, 48);
        var database = Fld(p.Database, 18, 5, 48);
        var user = Fld(p.UserId, 18, 7, 48);
        var password = Fld(p.Password, 18, 9, 48, secret: true);
        var savePassword = new CheckBox("Save password (encrypted for this Windows user)") { X = 18, Y = 11, Checked = p.SavePassword };

        dialog.Add(Lbl("Name:", 1, 1), name,
                   Lbl("Server:", 1, 3), server,
                   Lbl("Database:", 1, 5), database,
                   Lbl("User / client id:", 1, 7), user,
                   Lbl("Password / secret:", 1, 9), password,
                   savePassword);

        // ---- authentication
        var authFrame = new FrameView("Authentication") { X = 1, Y = 13, Width = 44, Height = 12 };
        var authLabels = AuthMethodInfo.All.Select(a => (NStack.ustring)a.Label).ToArray();
        var auth = new RadioGroup(authLabels)
        {
            X = 0,
            Y = 0,
            SelectedItem = Array.FindIndex(AuthMethodInfo.All, a => a.Method == p.Authentication)
        };
        authFrame.Add(auth);
        dialog.Add(authFrame);

        var hint = new Label("") { X = 46, Y = 13, Width = 44, Height = 2 };
        dialog.Add(hint);

        // ---- right column: connection options
        var optionsFrame = new FrameView("Options") { X = 46, Y = 15, Width = 44, Height = 10 };
        var encrypt = new RadioGroup(new NStack.ustring[] { "Encrypt: Mandatory", "Encrypt: Optional", "Encrypt: Strict" })
        {
            X = 0,
            Y = 0,
            SelectedItem = p.Encrypt switch { "Optional" => 1, "Strict" => 2, _ => 0 }
        };
        var trust = new CheckBox("Trust server certificate") { X = 0, Y = 3, Checked = p.TrustServerCertificate };
        var readOnly = new CheckBox("Read-only intent (AG)") { X = 0, Y = 4, Checked = p.ReadOnlyIntent };
        var multiSubnet = new CheckBox("MultiSubnetFailover") { X = 0, Y = 5, Checked = p.MultiSubnetFailover };
        var raw = new CheckBox("Use raw connection string") { X = 0, Y = 6, Checked = p.UseRawConnectionString };
        optionsFrame.Add(encrypt, trust, readOnly, multiSubnet, raw);
        dialog.Add(optionsFrame);

        var timeout = Fld(p.ConnectTimeoutSeconds.ToString(), 18, 25, 6);
        var cmdTimeout = Fld(p.CommandTimeoutSeconds.ToString(), 46, 25, 6);
        dialog.Add(Lbl("Connect timeout:", 1, 25), timeout, Lbl("Query timeout:", 31, 25), cmdTimeout);

        var query = Fld(p.Query, 18, 26, 70);
        dialog.Add(Lbl("Query:", 1, 26), query);

        var rawField = Fld(p.RawConnectionString, 18, 27, 70);
        dialog.Add(Lbl("Raw string:", 1, 27), rawField);

        void Sync()
        {
            var method = AuthMethodInfo.All[auth.SelectedItem].Method;
            hint.Text = AuthMethodInfo.All[auth.SelectedItem].Hint;
            var usesRaw = raw.Checked;
            user.Enabled = !usesRaw && AuthMethodInfo.NeedsUser(method);
            password.Enabled = !usesRaw && AuthMethodInfo.NeedsPassword(method);
            savePassword.Enabled = password.Enabled;
            server.Enabled = database.Enabled = !usesRaw;
            encrypt.Enabled = trust.Enabled = readOnly.Enabled = multiSubnet.Enabled = !usesRaw;
            rawField.Enabled = usesRaw;
        }
        auth.SelectedItemChanged += _ => Sync();
        raw.Toggled += _ => Sync();
        Sync();

        void Apply()
        {
            p.Name = name.Text.ToString() ?? p.Name;
            p.Server = server.Text.ToString() ?? "";
            p.Database = database.Text.ToString() ?? "";
            p.UserId = user.Text.ToString() ?? "";
            p.Password = password.Text.ToString() ?? "";
            p.SavePassword = savePassword.Checked;
            p.Authentication = AuthMethodInfo.All[auth.SelectedItem].Method;
            p.Encrypt = encrypt.SelectedItem switch { 1 => "Optional", 2 => "Strict", _ => "Mandatory" };
            p.TrustServerCertificate = trust.Checked;
            p.ReadOnlyIntent = readOnly.Checked;
            p.MultiSubnetFailover = multiSubnet.Checked;
            p.UseRawConnectionString = raw.Checked;
            p.RawConnectionString = rawField.Text.ToString() ?? "";
            p.Query = string.IsNullOrWhiteSpace(query.Text.ToString()) ? ConnectionProfile.DefaultQuery : query.Text.ToString()!;
            if (int.TryParse(timeout.Text.ToString(), out var t) && t > 0) p.ConnectTimeoutSeconds = t;
            if (int.TryParse(cmdTimeout.Text.ToString(), out var c) && c > 0) p.CommandTimeoutSeconds = c;
        }

        preview.Clicked += () =>
        {
            Apply();
            try { MessageBox.Query("Connection string", ConnectionProfile.Mask(p.Build()), "Ok"); }
            catch (Exception ex) { MessageBox.ErrorQuery("Connection string", ConnectionTester.Describe(ex), "Ok"); }
        };

        ok.Clicked += () =>
        {
            Apply();
            if (string.IsNullOrWhiteSpace(p.Name)) { MessageBox.ErrorQuery("Add", "Give the connection a name.", "Ok"); return; }
            if (!p.UseRawConnectionString && string.IsNullOrWhiteSpace(p.Server)) { MessageBox.ErrorQuery("Add", "Give a server.", "Ok"); return; }
            if (p.UseRawConnectionString && string.IsNullOrWhiteSpace(p.RawConnectionString)) { MessageBox.ErrorQuery("Add", "Give a raw connection string.", "Ok"); return; }
            try { p.Build(); }
            catch (Exception ex) { MessageBox.ErrorQuery("Connection string", ConnectionTester.Describe(ex), "Ok"); return; }
            accepted = true;
            Application.RequestStop();
        };
        cancel.Clicked += () => Application.RequestStop();

        return dialog;
    }
}
