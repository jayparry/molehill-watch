using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

// MolehillManager.Grid is the terminal grid helper and wins over WPF's in here, being nearer.
using WpfGrid = System.Windows.Controls.Grid;

namespace MolehillManager.Gui;

/// <summary>
///   The settings screen, in the window. Shown on first run, when the config file is missing
///   something, when the connection fails, and from Settings in the tree.
///
///   This is the layout and nothing else. What makes a setting acceptable, what Test means and what
///   saving does are all in <see cref="Setup"/>, which the terminal screen and the self-test reach
///   the same way - so there is one set of rules about timeouts, missing fields, the output folder
///   and when a password is stored, not three.
///
///   The buttons are part of the control rather than the window around it, so the whole screen can
///   be driven headlessly: a test can type into it, press Test, press Save, and read what happened.
///   Asking a question goes out through <c>ask</c> for the same reason - in the window that is a
///   dialog, in the self-test it is a recorded answer.
/// </summary>
internal sealed class SettingsView : UserControl
{
    private readonly AppConfig _config;
    private readonly string _path;
    private readonly Func<string, string, string[], int> _ask;

    private readonly TextBox _server = new();
    private readonly TextBox _database = new();
    private readonly ComboBox _auth = new();
    private readonly TextBox _user = new();
    private readonly PasswordBox _secret = new();
    private readonly CheckBox _savePassword = new() { Content = "Remember it (encrypted for this Windows user)" };
    private readonly ComboBox _encrypt = new();
    private readonly CheckBox _trust = new() { Content = "Trust the server certificate" };
    private readonly TextBox _timeout = new() { Width = 60 };
    private readonly TextBox _output = new();
    private readonly TextBox _refresh = new() { Width = 60 };
    private readonly TextBlock _hint = new() { TextWrapping = TextWrapping.Wrap };
    private readonly Button _test = new() { Content = "Test" };
    private readonly Button _save = new() { Content = "Save", IsDefault = true };
    private readonly Button _cancel = new() { Content = "Cancel", IsCancel = true };

    public SettingsView(AppConfig config, string path, string why, Func<string, string, string[], int> ask)
    {
        _config = config;
        _path = path;
        _ask = ask;

        var c = config.Connection;
        _server.Text = c.Server;
        _database.Text = c.Database;
        _auth.ItemsSource = AppConfig.AuthLabels;
        _auth.SelectedIndex = Math.Max(0, Array.IndexOf(AppConfig.AuthMethods, c.Authentication));
        _user.Text = c.User;
        _secret.Password = config.Secret ?? "";
        _savePassword.IsChecked = c.SavePassword;
        _encrypt.ItemsSource = Setup.EncryptOptions;
        _encrypt.SelectedIndex = Math.Max(0, Array.IndexOf(Setup.EncryptOptions, c.Encrypt));
        _trust.IsChecked = c.TrustServerCertificate;
        _timeout.Text = c.ConnectTimeoutSeconds.ToString();
        _output.Text = config.OutputFolder;
        _refresh.Text = config.AutoRefreshMinutes.ToString();

        _auth.SelectionChanged += (_, _) => Sync();
        _test.Click += (_, _) => Report.Try("Settings", () => Test());
        _save.Click += (_, _) => Report.Try("Settings", () => Save());
        _cancel.Click += (_, _) => Finish(SetupResult.Cancelled);

        Content = Build(why);
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
        Sync();
    }

    // ---------------------------------------------------------------- what is on the screen

    public string Server { get => _server.Text; set => _server.Text = value; }
    public string Database { get => _database.Text; set => _database.Text = value; }
    public string User { get => _user.Text; set => _user.Text = value; }
    public string Secret { get => _secret.Password; set => _secret.Password = value; }
    public string OutputFolder { get => _output.Text; set => _output.Text = value; }
    public string Timeout { get => _timeout.Text; set => _timeout.Text = value; }
    public string AutoRefresh { get => _refresh.Text; set => _refresh.Text = value; }
    public bool SavePassword { get => _savePassword.IsChecked == true; set => _savePassword.IsChecked = value; }
    public bool TrustCertificate { get => _trust.IsChecked == true; set => _trust.IsChecked = value; }

    public string Encrypt
    {
        get => _encrypt.SelectedItem as string ?? Setup.EncryptOptions[0];
        set => _encrypt.SelectedIndex = Math.Max(0, Array.IndexOf(Setup.EncryptOptions, value));
    }

    /// <summary>The sign-in method, as the value the config file stores rather than its label.</summary>
    public string Authentication
    {
        get => AppConfig.AuthMethods[Math.Max(0, _auth.SelectedIndex)];
        set => _auth.SelectedIndex = Math.Max(0, Array.IndexOf(AppConfig.AuthMethods, value));
    }

    /// <summary>Which fields this sign-in method uses, and what it says about itself. For the self-test.</summary>
    public bool UserEnabled => _user.IsEnabled;
    public bool SecretEnabled => _secret.IsEnabled;
    public string Hint => _hint.Text;

    public SetupResult Result { get; private set; } = SetupResult.Cancelled;

    /// <summary>Raised when the screen is finished with, saved or cancelled.</summary>
    public event Action<SetupResult>? Finished;

    // ---------------------------------------------------------------- the three buttons

    /// <summary>
    ///   Tries the settings as typed and says what came back. Nothing is written - Examine works on
    ///   a copy - so Test on a half-finished screen cannot damage a working config file.
    /// </summary>
    public SaveCheck Test()
    {
        var examined = Setup.Examine(Draft(), _config);
        var message = examined.Verdict switch
        {
            SaveVerdict.Invalid => examined.Problem!,
            SaveVerdict.Ready => $"Connected to {examined.Candidate!.Describe()}.",
            SaveVerdict.CanInstall => $"The server is reachable.\n\n{examined.Database!.Message}\n\nPress Save and Molehill Manager will offer to do it.",
            _ => examined.Database!.Message
        };
        var title = examined.Verdict is SaveVerdict.Invalid ? "Settings"
            : examined.Verdict is SaveVerdict.Unreachable ? "Could not connect" : "Settings";
        _ask(title, message, new[] { "Ok" });
        return examined;
    }

    /// <summary>
    ///   Saves, asking first where the server did not answer. Returns what the screen ended as, so a
    ///   caller - or a test - does not have to wait for the event to know.
    /// </summary>
    public SetupResult Save()
    {
        var examined = Setup.Examine(Draft(), _config);
        if (examined.Verdict == SaveVerdict.Invalid)
        {
            _ask("Settings", examined.Problem!, new[] { "Ok" });
            return SetupResult.Cancelled;
        }
        // a server that never answers is not necessarily wrong - it may be off, or firewalled, or
        // the settings may be being filled in away from the network they will be used on
        if (examined.Verdict == SaveVerdict.Unreachable
            && _ask("Could not connect", examined.Database!.Message + "\n\nSave these settings anyway?",
                    new[] { "Keep editing", "Save anyway" }) != 1)
            return SetupResult.Cancelled;

        var error = Setup.Commit(_config, _path, examined.Candidate!);
        if (error != null)
        {
            _ask("Settings", error, new[] { "Ok" });
            return SetupResult.Cancelled;
        }
        Finish(SetupResult.Saved);
        return SetupResult.Saved;
    }

    public void Cancel() => Finish(SetupResult.Cancelled);

    private void Finish(SetupResult result)
    {
        Result = result;
        Finished?.Invoke(result);
    }

    /// <summary>What is on the screen, as typed. <see cref="Setup.Examine"/> decides what it is worth.</summary>
    public SettingsDraft Draft() => new()
    {
        Server = Server,
        Database = Database,
        Authentication = Authentication,
        User = User,
        Secret = Secret,
        SavePassword = SavePassword,
        Encrypt = Encrypt,
        TrustServerCertificate = TrustCertificate,
        Timeout = Timeout,
        OutputFolder = OutputFolder,
        AutoRefresh = AutoRefresh
    };

    /// <summary>
    ///   Which fields the chosen sign-in method actually uses, and the sentence explaining it.
    ///   Windows and the default Entra sign-in take no user name at all; only three of the seven
    ///   take a password or a client secret.
    /// </summary>
    private void Sync()
    {
        var method = Authentication;
        _user.IsEnabled = AppConfig.AllowsUser(method);
        _secret.IsEnabled = _savePassword.IsEnabled = AppConfig.NeedsSecret(method);
        _hint.Text = Setup.AuthHint(method);
    }

    // ---------------------------------------------------------------- layout

    private UIElement Build(string why)
    {
        var rows = new StackPanel { Margin = new Thickness(18, 14, 18, 14) };

        if (!string.IsNullOrWhiteSpace(why))
            rows.Children.Add(new Border
            {
                Background = AppResources.Resource<Brush>("Tint"),
                BorderBrush = AppResources.Resource<Brush>("Accent"),
                BorderThickness = new Thickness(3, 0, 0, 0),
                Padding = new Thickness(11, 7, 11, 7),
                Margin = new Thickness(0, 0, 0, 14),
                Child = new TextBlock { Text = why, TextWrapping = TextWrapping.Wrap, MaxWidth = 620,
                                        HorizontalAlignment = HorizontalAlignment.Left }
            });

        var split = new WpfGrid();
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(26) });
        split.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var left = new StackPanel();
        left.Children.Add(Labelled("Server", _server));
        left.Children.Add(Labelled("Database", _database));
        left.Children.Add(Labelled("Sign in with", _auth));
        _hint.Foreground = AppResources.Resource<Brush>("Note");
        _hint.FontSize = 11.5;
        _hint.Margin = new Thickness(0, 0, 0, 10);
        _hint.MaxWidth = 380;
        _hint.HorizontalAlignment = HorizontalAlignment.Left;
        left.Children.Add(_hint);
        left.Children.Add(Labelled("User / client id", _user));
        left.Children.Add(Labelled("Password / secret", _secret));
        _savePassword.Margin = new Thickness(0, 0, 0, 10);
        left.Children.Add(_savePassword);

        var right = new StackPanel { Width = 240 };
        right.Children.Add(Labelled("Encryption", _encrypt));
        _trust.Margin = new Thickness(0, 0, 0, 10);
        right.Children.Add(_trust);
        right.Children.Add(Labelled("Timeout (seconds)", _timeout));

        WpfGrid.SetColumn(left, 0);
        WpfGrid.SetColumn(right, 2);
        split.Children.Add(left);
        split.Children.Add(right);
        rows.Children.Add(split);

        rows.Children.Add(Labelled("Output folder", _output));
        rows.Children.Add(Labelled("Auto refresh (minutes, 0 = only on F5)", _refresh));

        rows.Children.Add(new TextBlock
        {
            Text = $"Saved to {_path}",
            Foreground = AppResources.Resource<Brush>("Muted"),
            FontSize = 11.5,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 6, 0, 0)
        });

        foreach (var b in new[] { _test, _save, _cancel })
        {
            b.MinWidth = 92;
            b.Padding = new Thickness(10, 4, 10, 4);
            b.Margin = new Thickness(8, 0, 0, 0);
        }
        rows.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 16, 0, 0),
            Children = { _test, _save, _cancel }
        });

        return new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Background = AppResources.Resource<Brush>("Paper"),
            Content = rows
        };
    }

    private static UIElement Labelled(string label, FrameworkElement field)
    {
        field.Margin = new Thickness(0, 0, 0, 10);
        field.HorizontalAlignment = field.Width > 0 ? HorizontalAlignment.Left : HorizontalAlignment.Stretch;
        var stack = new StackPanel();
        stack.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 0, 3) });
        stack.Children.Add(field);
        return stack;
    }
}
