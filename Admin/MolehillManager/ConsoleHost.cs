using System.Runtime.InteropServices;

namespace MolehillManager;

/// <summary>
///   The app is windowed now, so that double-clicking it does not leave an empty black window
///   behind the screen. A windowed process is not attached to a console, which matters in one place
///   only: Terminal.Gui draws by writing to a console and reading its size back, so --tui has to
///   have one. Everything else - the self-tests, --install, --help - prints perfectly well with the
///   handles it was given.
/// </summary>
internal static class ConsoleHost
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();

    /// <summary>ATTACH_PARENT_PROCESS: the terminal that launched us, whichever that is.</summary>
    private const int ParentProcess = -1;

    /// <summary>
    ///   Whether this run needs a console of its own. Only the terminal front end does.
    ///
    ///   Deliberately asks about one switch rather than keeping a list of the ones that print: a
    ///   list would be a second copy of the parser, and the day it fell behind, a new switch would
    ///   print into nowhere and look as though it had done nothing.
    /// </summary>
    public static bool NeedsConsole(string[] args) =>
        args.Any(a => string.Equals(a, "--tui", StringComparison.OrdinalIgnoreCase));

    /// <summary>
    ///   Makes sure the terminal front end has a console, and leaves everything else alone.
    ///   Must be the first thing <c>Main</c> does: .NET works out where Console.Out goes once, the
    ///   first time anything touches it.
    /// </summary>
    public static void Prepare(string[] args)
    {
        // Nothing is borrowed for the other switches, and this is not an oversight. cmd.exe and
        // PowerShell hand a windowed child their own standard handles, so printing already works;
        // and when the output was redirected, that handle IS the file. AttachConsole replaces the
        // standard handles with the console's own, so calling it unconditionally - which is what
        // this did first - threw the redirection away and wrote into the terminal instead. That is
        // measurable: the handle went from 480 to 768 and the redirected file stayed empty.
        if (NeedsConsole(args) && GetConsoleWindow() == IntPtr.Zero && !AttachConsole(ParentProcess))
            AllocConsole();   // double-clicked, or launched from something with no console at all

        // the screens, the reports and every money column use box-drawing characters and a pound
        // sign. This used to be set in SelfTest's static constructor, where a throw arrives as a
        // TypeInitializationException at whatever moment something first touches SelfTest.
        try { Console.OutputEncoding = System.Text.Encoding.UTF8; }
        catch (Exception ex) when (ex is IOException or ArgumentException)
        {
            // no console and no redirection: there is nowhere for the text to go anyway
        }
    }
}
