using System.Runtime.InteropServices;

namespace MolehillManager;

/// <summary>
///   The app is windowed now, so that double-clicking it leaves no empty black window behind the
///   screen. A windowed process is not attached to a console, which matters in exactly one place:
///   Terminal.Gui draws by writing to a console and reading its size back. Everything else - the
///   self-tests, --install, --help - prints perfectly well with the handles it was given.
/// </summary>
internal static class ConsoleHost
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AllocConsole();

    /// <summary>ATTACH_PARENT_PROCESS: the terminal that launched us, whichever that is.</summary>
    private const int ParentProcess = -1;

    /// <summary>The process already has a console, so there is nothing to attach to it.</summary>
    private const int AlreadyHaveOne = 5;   // ERROR_ACCESS_DENIED

    /// <summary>
    ///   The first thing Main does, because .NET works out where Console.Out goes once - the first
    ///   time anything touches it.
    ///
    ///   Nothing is attached here, and that is not an oversight. cmd.exe and PowerShell hand a
    ///   windowed child their own standard handles, so printing already works; and when the output
    ///   was redirected, that handle IS the file. AttachConsole replaces the standard handles with
    ///   the console's own, so calling it here - which is what this did first - threw the
    ///   redirection away and wrote into the terminal instead, leaving the file empty. Measurable:
    ///   the handle went from 480 to 768 and IsOutputRedirected was already true beforehand.
    /// </summary>
    public static void Prepare() => UseUtf8();

    /// <summary>
    ///   Makes sure there is a real console, for the terminal front end and nothing else. Borrows
    ///   the launching terminal, or makes one when there is none to borrow - double-clicked from
    ///   Explorer - because otherwise the app would start, find it cannot draw, and quit without
    ///   ever showing anything.
    ///
    ///   Asked here, where the front end has already been chosen, rather than from a list of
    ///   switches at the top of Main. A list would be a second copy of the parser, and it would get
    ///   this wrong both ways: double-clicking would do nothing, and a self-test that was
    ///   double-clicked would open a console that scrolls past and vanishes.
    /// </summary>
    public static void EnsureConsoleForTerminalUi()
    {
        if (!AttachConsole(ParentProcess) && Marshal.GetLastWin32Error() != AlreadyHaveOne)
            AllocConsole();
        UseUtf8();            // the console may not have existed when Prepare ran
    }

    /// <summary>
    ///   The screens, the reports and every money column use box-drawing characters and a pound
    ///   sign. This used to be set in SelfTest's static constructor, where a throw arrives as a
    ///   TypeInitializationException at whatever moment something first touches SelfTest.
    /// </summary>
    private static void UseUtf8()
    {
        try { Console.OutputEncoding = System.Text.Encoding.UTF8; }
        catch (Exception ex) when (ex is IOException or ArgumentException)
        {
            // no console and no redirection: there is nowhere for the text to go anyway
        }
    }
}
