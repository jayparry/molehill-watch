using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   The window's answers to the start-up questions - the third implementation of
///   <see cref="IStartupPrompts"/>, after the terminal's and the scripted one in the self-test.
///
///   Every one of them is a thin wrapper now: the settings screen is <see cref="SettingsView"/>,
///   the password prompt is <see cref="SecretView"/>, a form is <see cref="MhForm"/>, and all three
///   decide nothing - <see cref="Setup"/> and <see cref="Startup.Connect"/> do. What is left here is
///   putting a control in a window, running it, and handing back what it said.
/// </summary>
internal sealed class WindowPrompts : IStartupPrompts
{
    /// <summary>The window the questions belong to, once there is one. Null during start-up.</summary>
    public Window? Owner { get; set; }

    public SetupResult AskSettings(AppConfig config, string path, string why)
    {
        var view = new SettingsView(config, path, why, Choose);
        var window = Frame("Molehill Manager settings", view, 820, 640);
        view.Finished += _ => window.Close();
        window.ShowDialog();
        return view.Result;
    }

    public string? AskSecret(AppConfig config, string path, string prompt)
    {
        var view = new SecretView(config, path, prompt, Choose);
        var window = Frame("Sign in", view, 560, 300);
        window.SizeToContent = SizeToContent.Height;
        var answered = false;
        view.Finished += _ => { answered = true; window.Close(); };
        window.ShowDialog();
        // closing the window with the X is the same as giving up, not the same as pressing Settings
        return answered ? view.Value : null;
    }

    public int Choose(string title, string message, params string[] buttons) =>
        Dialogs.Ask(Owner, title, message, buttons);

    public void ShowText(string title, string text) => Dialogs.Read(Owner, title, Words(text));

    public void RunForm(FormSpec spec) => Dialogs.Form(Owner, spec);

    /// <summary>
    ///   Installs, showing what the script is doing as it goes. The work runs off the UI thread and
    ///   reports back through the dispatcher, the way the terminal marshals through its main loop;
    ///   without that the window would be frozen for the ten seconds the install takes and look like
    ///   it had crashed at exactly the moment someone is least sure of the app.
    /// </summary>
    public string? RunInstall(AppConfig config, out List<string> messages)
    {
        var collected = new List<string>();
        string? error = null;

        var step = new TextBlock
        {
            Text = "Starting...",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(18, 18, 18, 6),
            MaxWidth = 500,
            HorizontalAlignment = HorizontalAlignment.Left
        };
        var rows = new StackPanel();
        rows.Children.Add(step);
        rows.Children.Add(new TextBlock
        {
            Text = "This takes a few seconds.",
            Foreground = AppResources.Resource<Brush>("Muted"),
            Margin = new Thickness(18, 0, 18, 18)
        });
        var window = Frame($"Installing MolehillAdmin into [{config.Connection.Database}]",
            new Border { Background = AppResources.Resource<Brush>("Paper"), Child = rows }, 560, 180);
        window.SizeToContent = SizeToContent.Height;

        window.Loaded += (_, _) => Task.Run(() =>
        {
            try
            {
                collected = AdminInstaller.Install(config,
                    s => window.Dispatcher.Invoke(() => step.Text = s));
            }
            catch (Exception ex)
            {
                error = ex is InvalidOperationException ? ex.Message : AdminDb.Describe(ex);
            }
            finally
            {
                window.Dispatcher.Invoke(window.Close);
            }
        });
        window.ShowDialog();

        messages = collected;
        return error;
    }

    private Window Frame(string title, UIElement content, double width, double height)
    {
        var window = new Window
        {
            Title = title,
            Width = width,
            Height = height,
            WindowStartupLocation = Owner == null ? WindowStartupLocation.CenterScreen : WindowStartupLocation.CenterOwner,
            Background = AppResources.Resource<Brush>("Paper"),
            Content = content
        };
        if (Owner != null) window.Owner = Owner;
        return window;
    }

    private static UIElement Words(string text) => new ScrollViewer
    {
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Content = new TextBlock
        {
            Text = text,
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(18),
            MaxWidth = 640,
            HorizontalAlignment = HorizontalAlignment.Left,
            Foreground = AppResources.Resource<Brush>("Ink")
        }
    };
}
