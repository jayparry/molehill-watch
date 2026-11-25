namespace MolehillManager;

/// <summary>
///   How big the window should open, decided apart from the window.
///
///   It is a small rule with one awkward case in it, which is why it is here rather than in the
///   window where it could not be checked: a size remembered from a monitor that is no longer
///   plugged in. Opening 2560 wide on a 1366-wide laptop puts half the app, and sometimes all of
///   the toolbar, off the side of the screen - where there is nothing to drag it back by.
/// </summary>
public static class WindowPlace
{
    public const int DefaultWidth = 1200;
    public const int DefaultHeight = 780;

    /// <summary>Below this the tree and the content pane cannot both be on the screen.</summary>
    public const int MinWidth = 780;
    public const int MinHeight = 520;

    /// <summary>
    ///   What to open at, given what was saved and how much room there is. A saved size is used as
    ///   it stands when it fits; when it does not it is brought back inside the screen rather than
    ///   thrown away, because a window that is too wide is usually one that was on a bigger monitor
    ///   and will be again. Anything below the minimum is treated as nothing saved at all.
    /// </summary>
    public static (int Width, int Height, bool Maximised) Opening(WindowConfig? saved, double screenWidth, double screenHeight)
    {
        var width = saved is { Width: >= MinWidth } ? saved.Width : DefaultWidth;
        var height = saved is { Height: >= MinHeight } ? saved.Height : DefaultHeight;

        // a screen smaller than the minimum is not a real screen - a service with no desktop, or a
        // measurement taken before anything was shown - so it is ignored rather than obeyed
        if (screenWidth >= MinWidth) width = (int)Math.Min(width, screenWidth);
        if (screenHeight >= MinHeight) height = (int)Math.Min(height, screenHeight);

        return (width, height, saved?.Maximised ?? false);
    }

    /// <summary>
    ///   Whether what the window was left at is worth writing to the config file. A run that did
    ///   not move or resize anything should not rewrite it - the file holds the encrypted password,
    ///   and rewriting it on every close is a risk taken for nothing.
    /// </summary>
    public static bool WorthSaving(WindowConfig? saved, int width, int height, bool maximised)
    {
        if (width < MinWidth || height < MinHeight) return false;
        return saved == null || saved.Width != width || saved.Height != height || saved.Maximised != maximised;
    }
}
