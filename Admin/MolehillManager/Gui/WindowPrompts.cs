using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   The window's answers to the start-up questions - the third implementation of
///   <see cref="IStartupPrompts"/>, after the terminal's and the scripted one in the self-test.
///
///   Three of the six are real already, because the pieces they need are built: a question is
///   <see cref="Dialogs.Ask"/>, something to read is <see cref="Dialogs.Read"/>, and a form is
///   <see cref="MhForm"/> - which is how the business-details form appears after a fresh install.
///
///   The two that ask for settings are not, and they say so rather than failing quietly. They need
///   the settings screen, which is Phase 4; all of its rules are already in <see cref="Setup"/>,
///   where <see cref="SetupDialog"/> and a future WPF screen both read them, so what is left there
///   is laying out seven authentication methods and their hints. Until then the terminal front end
///   does the first run, which is also why the default is still the terminal: a window that cannot
///   ask for a server would be a worse first run than the one we have.
/// </summary>
internal sealed class WindowPrompts : IStartupPrompts
{
    private const string Setup =
        "The window cannot change the settings yet.\n\n"
        + "Run MolehillManager --tui once to set up the server and the database; after that the "
        + "window will start straight into the app.";

    public SetupResult AskSettings(AppConfig config, string path, string why)
    {
        Dialogs.Read(null, "Settings", Words($"{why}\n\n{Setup}\n\nThe settings file is {path}."));
        return SetupResult.Cancelled;
    }

    public string? AskSecret(AppConfig config, string path, string prompt)
    {
        Dialogs.Read(null, "Password", Words($"{prompt}\n\n{Setup}"));
        return null;
    }

    public int Choose(string title, string message, params string[] buttons) =>
        Dialogs.Ask(null, title, message, buttons);

    public void ShowText(string title, string text) => Dialogs.Read(null, title, Words(text));

    public void RunForm(FormSpec spec) => Dialogs.Form(null, spec);

    /// <summary>
    ///   Installs, then shows what the script said. The terminal puts a progress box up and feeds it
    ///   from the callback; here the messages are shown at the end, because an install that is doing
    ///   something is better signalled by a window that is plainly busy than by a list of SQL batch
    ///   names nobody reads.
    /// </summary>
    public string? RunInstall(AppConfig config, out List<string> messages)
    {
        var said = new List<string>();
        string? problem = null;
        try { AdminInstaller.Install(config, line => said.Add(line)); }
        catch (Exception ex) { problem = AdminDb.Explain(ex); }
        messages = said;
        return problem;
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
            Foreground = AppResources.Resource<Brush>("Ink")
        }
    };
}
