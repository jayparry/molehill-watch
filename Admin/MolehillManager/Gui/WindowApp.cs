using System.Windows;

namespace MolehillManager.Gui;

/// <summary>
///   Starting the window: get a connection the same way the terminal does, put the window up, run
///   the message loop.
///
///   It lives here rather than in <c>Program</c> on purpose. <c>Program</c> has
///   <c>using Terminal.Gui</c>, and both frameworks have an <c>Application</c> and a
///   <c>MessageBox</c>, so every WPF type named in there has to be written out in full or it is
///   ambiguous. The entry point stays a switchboard and this is the only place that needs both.
/// </summary>
internal static class WindowApp
{
    public static int Run(AppConfig config, string path, bool existed, bool forceSetup, bool loadFailed)
    {
        var app = AppResources.Ensure();
        var prompts = new WindowPrompts();
        var connection = Startup.Connect(prompts, config, path, existed, forceSetup, loadFailed);
        if (connection == null) return 1;   // the person gave up, and was told why

        var window = new MhWindow(new AdminDb(connection), config, path);
        // from here on the questions have a window to belong to, so they open over it
        prompts.Owner = window;
        // AppResources keeps the Application alive on purpose, so that the view tests can build one
        // and not have it shut down under them; a real run ends when the window is closed.
        app.ShutdownMode = ShutdownMode.OnMainWindowClose;
        app.Run(window);
        return 0;
    }
}
