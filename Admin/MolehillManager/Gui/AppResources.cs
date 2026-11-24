using System.Windows;

namespace MolehillManager.Gui;

/// <summary>
///   The WPF <see cref="Application"/>, made in code rather than from an App.xaml.
///
///   There is deliberately no App.xaml: an ApplicationDefinition generates its own Main, which
///   would collide with ours (CS0017), and ours has to exist to carry [STAThread]. Making the
///   Application here is also what lets the views be tested, because resource lookups need one -
///   and because constructing a second Application in a process throws, this has to be the only
///   place it happens.
/// </summary>
internal static class AppResources
{
    /// <summary>
    ///   The Application, made once. Safe to call from anywhere, including the self-test, which
    ///   builds views over and over in a single process.
    /// </summary>
    public static Application Ensure()
    {
        if (Application.Current != null) return Application.Current;
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Resources.MergedDictionaries.Add(Palette.Build());
        return app;
    }

    /// <summary>
    ///   A resource by key, or a clear complaint. WPF's own answer to a missing resource is null,
    ///   which then arrives much later as a blank control or a NullReferenceException with nothing
    ///   in it to say which key was wrong.
    /// </summary>
    public static T Resource<T>(string key)
    {
        var found = Ensure().TryFindResource(key);
        if (found is T typed) return typed;
        throw new InvalidOperationException(found == null
            ? $"There is no resource called '{key}'."
            : $"The resource '{key}' is a {found.GetType().Name}, not a {typeof(T).Name}.");
    }
}
