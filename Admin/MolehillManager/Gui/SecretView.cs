using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   Asks for just the password, when everything else in the config file is already right - the
///   usual case when a password was never saved, or was saved by a different Windows user.
///
///   The answer carries three meanings, and <see cref="Startup.Connect"/> depends on all three:
///   a value is the password, <c>null</c> means the person gave up and the app stops, and an empty
///   string means they pressed Settings and want the whole screen instead. Returning the wrong one
///   of those turns "let me fix the server name" into "goodbye", so the self-test checks each.
/// </summary>
internal sealed class SecretView : UserControl
{
    private readonly AppConfig _config;
    private readonly string _path;
    private readonly Func<string, string, string[], int> _ask;
    private readonly PasswordBox _secret = new();
    private readonly CheckBox _remember = new() { Content = "Remember it (encrypted for this Windows user)" };
    private readonly Button _connect = new() { Content = "Connect", IsDefault = true };
    private readonly Button _settings = new() { Content = "Settings..." };
    private readonly Button _cancel = new() { Content = "Cancel", IsCancel = true };

    public SecretView(AppConfig config, string path, string why, Func<string, string, string[], int> ask)
    {
        _config = config;
        _path = path;
        _ask = ask;

        // a service principal has a client secret, not a password, and calling it the wrong thing in
        // the one box someone has to type into is a small way to make them doubt everything else
        What = config.Connection.Authentication == "EntraServicePrincipal" ? "Client secret" : "Password";
        _remember.IsChecked = config.Connection.SavePassword;

        _connect.Click += (_, _) => Report.Try("Sign in", () => Connect());
        _settings.Click += (_, _) => Finish("");
        _cancel.Click += (_, _) => Finish(null);

        Content = Build(why);
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
    }

    /// <summary>"Password", or "Client secret" for a service principal.</summary>
    public string What { get; }

    public string Secret { get => _secret.Password; set => _secret.Password = value; }
    public bool Remember { get => _remember.IsChecked == true; set => _remember.IsChecked = value; }

    /// <summary>The password, "" for Settings..., or null for cancelled. Null until it is finished.</summary>
    public string? Value { get; private set; }

    public event Action<string?>? Finished;

    /// <summary>
    ///   Tries what was typed. The screen stays open on a refusal, because the usual reason is a
    ///   typo and closing would mean starting the whole sign-in again.
    /// </summary>
    public bool Connect()
    {
        var value = Secret;
        if (value == "")
        {
            _ask("Sign in", $"Type the {What.ToLowerInvariant()}.", new[] { "Ok" });
            return false;
        }
        var tried = Setup.TrySecret(_config, _path, value, Remember);
        if (!tried.Worked)
        {
            _ask("Could not connect", tried.Problem!, new[] { "Ok" });
            return false;
        }
        // it works, but could not be stored: worth saying, not worth stopping for - the app
        // connects now and asks again next time
        if (tried.WriteProblem != null) _ask("Settings", tried.WriteProblem, new[] { "Ok" });
        Finish(value);
        return true;
    }

    public void OpenSettings() => Finish("");

    public void Cancel() => Finish(null);

    private void Finish(string? value)
    {
        Value = value;
        Finished?.Invoke(value);
    }

    private UIElement Build(string why)
    {
        var rows = new StackPanel { Margin = new Thickness(18, 16, 18, 16) };
        rows.Children.Add(new TextBlock
        {
            Text = why,
            TextWrapping = TextWrapping.Wrap,
            MaxWidth = 520,
            HorizontalAlignment = HorizontalAlignment.Left,
            Margin = new Thickness(0, 0, 0, 14)
        });
        rows.Children.Add(new TextBlock { Text = What, Margin = new Thickness(0, 0, 0, 3) });
        _secret.Margin = new Thickness(0, 0, 0, 10);
        rows.Children.Add(_secret);
        _remember.Margin = new Thickness(0, 0, 0, 4);
        rows.Children.Add(_remember);

        foreach (var b in new[] { _connect, _settings, _cancel })
        {
            b.MinWidth = 96;
            b.Padding = new Thickness(10, 4, 10, 4);
            b.Margin = new Thickness(8, 0, 0, 0);
        }
        rows.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Right,
            Margin = new Thickness(0, 18, 0, 0),
            Children = { _connect, _settings, _cancel }
        });

        return new Border { Background = AppResources.Resource<Brush>("Paper"), Child = rows };
    }
}
