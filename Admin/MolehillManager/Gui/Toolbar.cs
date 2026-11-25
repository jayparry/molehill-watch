using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   The named buttons for whatever is selected. This is the point of the whole exercise.
///
///   The terminal UI hides an action that does not apply: it is not greyed, it is absent, and there
///   is no way to learn what is possible or why something is missing. So it renders
///   <c>set.Actions</c> - all of them - and not <c>set.Available</c>, which is the one-word
///   difference between the two front ends. A disabled button keeps its label and carries the
///   reason as its tooltip, so "why can't I invoice this?" is answered by hovering over the button
///   that would have done it.
/// </summary>
internal sealed class Toolbar : UserControl
{
    private readonly WrapPanel _buttons = new() { Orientation = Orientation.Horizontal };

    public Toolbar()
    {
        Content = new Border
        {
            Background = AppResources.Resource<Brush>("Surface"),
            BorderBrush = AppResources.Resource<Brush>("Line"),
            BorderThickness = new Thickness(0, 0, 0, 1),
            Padding = new Thickness(8, 6, 8, 6),
            Child = _buttons
        };
    }

    /// <summary>What is on the toolbar now, in order. The self-test reads the buttons back off this.</summary>
    public IReadOnlyList<Button> Buttons => _buttons.Children.OfType<Button>().ToList();

    /// <summary>
    ///   Puts up one button per action. An action that is enabled must have something to run, so a
    ///   missing handler is refused here rather than on the click: it is a mistake in the screen,
    ///   not something a person can do anything about, and the self-test walks every action set to
    ///   catch it.
    /// </summary>
    public void Show(MhActionSet set, IReadOnlyDictionary<string, Action> handlers) =>
        Show(set, null, handlers);

    /// <summary>
    ///   The selected row's actions, then - after a divider - the ones for the whole agreement or
    ///   engagement. Two scopes, both on show. The terminal reaches the second group through a
    ///   menu item on the first menu, so "record the initial review" is two unlabelled key presses
    ///   away from anywhere; here it is a button you can see from across the room.
    /// </summary>
    public void Show(MhActionSet set, MhActionSet? wide, IReadOnlyDictionary<string, Action> handlers)
    {
        _buttons.Children.Clear();
        Add(set, handlers);
        if (wide == null || wide.Actions.Count == 0) return;
        _buttons.Children.Add(new Border
        {
            Width = 1,
            Margin = new Thickness(6, 2, 12, 2),
            Background = AppResources.Resource<Brush>("LineStrong")
        });
        Add(wide, handlers);
    }

    private void Add(MhActionSet set, IReadOnlyDictionary<string, Action> handlers)
    {
        var missing = set.Actions.Where(a => a.Enabled && !handlers.ContainsKey(a.Id)).Select(a => a.Id).ToList();
        if (missing.Count > 0)
            throw new InvalidOperationException(
                $"'{set.Title}' offers {string.Join(", ", missing)} with nothing to run.");

        foreach (var action in set.Actions)
        {
            var button = new Button
            {
                Content = action.Label,
                Tag = action.Id,
                IsEnabled = action.Enabled,
                Margin = new Thickness(0, 0, 6, 0),
                Padding = new Thickness(10, 4, 10, 4),
                MinWidth = 0
            };
            if (!action.Enabled)
            {
                button.ToolTip = action.DisabledReason;
                // without this a disabled button says nothing at all when you hover it, which would
                // leave the reasons written, tested, and invisible - exactly the problem being fixed
                ToolTipService.SetShowOnDisabled(button, true);
            }
            if (action.Enabled && handlers.TryGetValue(action.Id, out var run))
                button.Click += (_, _) => Report.Try(set.Title, run);
            _buttons.Children.Add(button);
        }
    }
}
