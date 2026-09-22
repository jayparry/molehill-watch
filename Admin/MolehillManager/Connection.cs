using System.Text.Json;
using Microsoft.Data.SqlClient;
using Terminal.Gui;

namespace MolehillManager;

/// <summary>Where MolehillAdmin lives. Saved without the password, which is asked for each time.</summary>
public sealed class ConnectionSettings
{
    public string Server { get; set; } = @".\SQLEXPRESS";
    public string Database { get; set; } = "MolehillAdmin";
    public string Authentication { get; set; } = "Windows";      // Windows | SqlLogin | EntraInteractive
    public string User { get; set; } = "";
    public bool TrustServerCertificate { get; set; } = true;

    public static readonly string[] AuthMethods = { "Windows", "SqlLogin", "EntraInteractive" };

    public static string DefaultPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MolehillManager", "settings.json");

    public static ConnectionSettings? Load(string path)
    {
        try { return File.Exists(path) ? JsonSerializer.Deserialize<ConnectionSettings>(File.ReadAllText(path)) : null; }
        catch { return null; }
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public string Build(string? password)
    {
        var b = new SqlConnectionStringBuilder
        {
            DataSource = Server,
            InitialCatalog = Database,
            TrustServerCertificate = TrustServerCertificate,
            ApplicationName = "Molehill Manager",
            ConnectTimeout = 15
        };
        switch (Authentication)
        {
            case "SqlLogin":
                b.UserID = User;
                b.Password = password ?? "";
                break;
            case "EntraInteractive":
                b.Authentication = SqlAuthenticationMethod.ActiveDirectoryInteractive;
                if (!string.IsNullOrWhiteSpace(User)) b.UserID = User;
                break;
            default:
                b.IntegratedSecurity = true;
                break;
        }
        return b.ConnectionString;
    }

    /// <summary>Connects and checks this really is a MolehillAdmin database. Returns null when it is fine.</summary>
    public static string? Check(string connectionString)
    {
        try
        {
            var db = new AdminDb(connectionString);
            var ok = db.Scalar("SELECT CASE WHEN OBJECT_ID(N'dbo.usp_Dashboard') IS NOT NULL AND OBJECT_ID(N'dbo.Agreement') IS NOT NULL THEN 1 ELSE 0 END");
            if (Convert.ToInt32(ok) != 1)
                return "Connected, but this database has no MolehillAdmin objects. Install it with Admin\\Install-MolehillAdmin.ps1, or pick the right database.";
            var platform = db.Scalar("SELECT COL_LENGTH(N'dbo.Instance', N'Platform')");
            if (platform == null)
                return "This MolehillAdmin is from before the Azure SQL update. Re-run Admin\\Install-MolehillAdmin.ps1 to upgrade it (your data is kept).";
            return null;
        }
        catch (Exception ex)
        {
            return AdminDb.Describe(ex);
        }
    }

    /// <summary>The connect dialog. Returns a working connection string, or null if cancelled.</summary>
    public static string? Prompt(ConnectionSettings settings, string savePath)
    {
        string? result = null;
        var connect = new Button("Connect", true);
        var cancel = new Button("Cancel");
        var dialog = new Dialog("Connect to MolehillAdmin", 72, 16, connect, cancel);

        var server = new TextField(settings.Server) { X = 16, Y = 1, Width = 50 };
        var database = new TextField(settings.Database) { X = 16, Y = 3, Width = 50 };
        var auth = new RadioGroup(new NStack.ustring[] { "Windows", "SQL login", "Entra ID (interactive)" })
        {
            X = 16, Y = 5, DisplayMode = DisplayModeLayout.Horizontal,
            SelectedItem = Math.Max(0, Array.IndexOf(AuthMethods, settings.Authentication))
        };
        var user = new TextField(settings.User) { X = 16, Y = 7, Width = 50 };
        var password = new TextField("") { X = 16, Y = 8, Width = 50, Secret = true };
        var trust = new CheckBox("Trust server certificate", settings.TrustServerCertificate) { X = 16, Y = 10 };
        dialog.Add(new Label("Server:") { X = 1, Y = 1 }, server,
                   new Label("Database:") { X = 1, Y = 3 }, database,
                   new Label("Sign in with:") { X = 1, Y = 5 }, auth,
                   new Label("User:") { X = 1, Y = 7 }, user,
                   new Label("Password:") { X = 1, Y = 8 }, password, trust,
                   new Label("The password is never saved.") { X = 16, Y = 11, ColorScheme = Colors.Menu });

        void Sync()
        {
            user.Enabled = auth.SelectedItem != 0;
            password.Enabled = auth.SelectedItem == 1;
        }
        auth.SelectedItemChanged += _ => Sync();
        Sync();

        connect.Clicked += () =>
        {
            settings.Server = server.Text.ToString()?.Trim() ?? "";
            settings.Database = database.Text.ToString()?.Trim() ?? "";
            settings.Authentication = AuthMethods[auth.SelectedItem];
            settings.User = user.Text.ToString()?.Trim() ?? "";
            settings.TrustServerCertificate = trust.Checked;
            var cs = settings.Build(password.Text.ToString());
            var problem = Check(cs);
            if (problem != null) { MessageBox.ErrorQuery("Connect", problem, "Ok"); return; }
            try { settings.Save(savePath); } catch { /* not being able to remember the server is not fatal */ }
            result = cs;
            Application.RequestStop();
        };
        cancel.Clicked += () => Application.RequestStop();
        Application.Run(dialog);
        return result;
    }
}
