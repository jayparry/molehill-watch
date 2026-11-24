using System.Windows;

namespace MolehillManager.Gui;

/// <summary>
///   Where the window puts a problem, and the window's half of the app's error policy.
///
///   The policy itself is <see cref="AdminDb.Explain"/>, shared with the terminal: a
///   FormatException is the app's own sentence about what someone typed and is shown as it stands,
///   anything else goes through Describe. What differs here is only where it appears.
/// </summary>
internal static class Report
{
    /// <summary>
    ///   Set by the self-test, so a problem arrives as a FAIL line rather than a modal box that
    ///   nothing can dismiss. The terminal half has the same escape hatch, for the same reason:
    ///   without it an error during a refresh hung the suite for forty minutes instead of failing
    ///   it, which in CI looks like a timeout with no clue in it.
    /// </summary>
    public static Action<string, string>? Sink;

    public static void Problem(string title, string message)
    {
        if (Sink != null) { Sink(title, message); return; }
        MessageBox.Show(message, title, MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    /// <summary>Runs something, and reports what went wrong rather than letting it out.</summary>
    public static void Try(string title, Action action)
    {
        try { action(); }
        catch (Exception ex) { Problem(title, AdminDb.Explain(ex)); }
    }
}
