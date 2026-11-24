using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   One control that lays out any form in the app, from its <see cref="FormSpec"/>. There are 41
///   of them and this is all of them, because every write already goes through a FormSpec whose
///   Execute needs no screen.
///
///   Deliberately no DatePicker, no NumericUpDown and no masked box: <see cref="FormValues"/> holds
///   everything as the text that was typed and parses it on submit, and those parse messages -
///   "Covered from: 'soon' is not a date (use yyyy-mm-dd)" - are the app's tested behaviour. A
///   typed control would quietly replace them with WPF's own, or with nothing at all.
///
///   Two things the terminal does that this does better: the help text sits under its field instead
///   of being squeezed into whatever space is left on the right (where, on a narrow terminal, it is
///   dropped altogether), and a choice is a drop-down rather than a button that opens a list.
/// </summary>
internal sealed class MhForm : UserControl
{
    private readonly FormSpec _spec;
    private readonly List<Action<FormValues>> _readers = new();
    private readonly TextBlock _problem;

    public MhForm(FormSpec spec)
    {
        _spec = spec;

        var rows = new StackPanel { Margin = new Thickness(16) };

        if (!string.IsNullOrEmpty(spec.Intro))
            rows.Children.Add(new TextBlock
            {
                Text = spec.Intro,
                TextWrapping = TextWrapping.Wrap,
                Foreground = AppResources.Resource<Brush>("Muted"),
                Margin = new Thickness(0, 0, 0, 14),
                MaxWidth = 720
            });

        foreach (var field in spec.Fields) rows.Children.Add(Row(field));

        _problem = new TextBlock
        {
            TextWrapping = TextWrapping.Wrap,
            Foreground = AppResources.Resource<Brush>("StatusRed"),
            Margin = new Thickness(0, 10, 0, 0),
            Visibility = Visibility.Collapsed,
            MaxWidth = 720
        };
        rows.Children.Add(_problem);

        Content = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Background = AppResources.Resource<Brush>("Paper"),
            Content = rows
        };
        FontFamily = AppResources.Resource<FontFamily>("BodyFont");
        Foreground = AppResources.Resource<Brush>("Ink");
    }

    private UIElement Row(Field field)
    {
        var stack = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };

        // The label and its star are two TextBlocks rather than one with two Runs, because a
        // TextBlock built through Inlines reads back Text == "" - setting Text makes a Run, but
        // adding Runs never updates Text - and the self-test reads views by their TextBlocks' Text.
        // A view written the other way is laid out, looks right, and is invisible to every test.
        var label = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 3) };
        label.Children.Add(new TextBlock { Text = field.Label, Foreground = AppResources.Resource<Brush>("Ink") });
        if (field.Required)
            label.Children.Add(new TextBlock
            {
                Text = " *",
                Foreground = AppResources.Resource<Brush>("StatusRed"),
                FontWeight = FontWeights.Bold,
                ToolTip = "Required"
            });
        stack.Children.Add(label);
        stack.Children.Add(Input(field));

        if (!string.IsNullOrEmpty(field.Help))
            stack.Children.Add(new TextBlock
            {
                Text = field.Help,
                TextWrapping = TextWrapping.Wrap,
                FontSize = 11.5,
                Foreground = AppResources.Resource<Brush>("Note"),
                Margin = new Thickness(0, 3, 0, 0),
                MaxWidth = 560
            });

        return stack;
    }

    private UIElement Input(Field field)
    {
        switch (field.Kind)
        {
            case FieldKind.Memo:
                var memo = new TextBox
                {
                    Text = field.Default,
                    AcceptsReturn = true,
                    TextWrapping = TextWrapping.Wrap,
                    VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                    MinHeight = 66,
                    MaxWidth = 560,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Width = 560
                };
                _readers.Add(v => v[field.Name] = memo.Text);
                return memo;

            case FieldKind.Bool:
                var check = new CheckBox { IsChecked = field.Default == "1", HorizontalAlignment = HorizontalAlignment.Left };
                _readers.Add(v => v[field.Name] = check.IsChecked == true ? "1" : "0");
                return check;

            case FieldKind.Choice:
                var choice = new ComboBox
                {
                    ItemsSource = field.Choices,
                    SelectedItem = field.Choices.Contains(field.Default) ? field.Default : field.Choices.FirstOrDefault(),
                    Width = 260,
                    HorizontalAlignment = HorizontalAlignment.Left
                };
                _readers.Add(v => v[field.Name] = choice.SelectedItem as string ?? "");
                return choice;

            default:
                var width = field.Kind switch
                {
                    FieldKind.Date => 130,
                    FieldKind.DateTime => 180,
                    FieldKind.Int or FieldKind.Decimal => 110,
                    _ => 420
                };
                var text = new TextBox { Text = field.Default, Width = width, HorizontalAlignment = HorizontalAlignment.Left };
                _readers.Add(v => v[field.Name] = text.Text);
                return text;
        }
    }

    /// <summary>What is on the screen now, ready for <see cref="FormSpec.Execute"/>.</summary>
    public FormValues Values()
    {
        var values = _spec.NewValues();
        foreach (var read in _readers) read(values);
        return values;
    }

    /// <summary>
    ///   Submits the form. Returns what the procedures said, or null when something was wrong -
    ///   in which case the reason is on the form and the form stays open, as the terminal's does.
    /// </summary>
    public ProcResult? Submit()
    {
        _problem.Visibility = Visibility.Collapsed;
        try
        {
            return _spec.Execute(Values());
        }
        catch (Exception ex)
        {
            _problem.Text = AdminDb.Explain(ex);
            _problem.Visibility = Visibility.Visible;
            return null;
        }
    }

    /// <summary>What went wrong last time it was submitted, if it is being shown. For the self-test.</summary>
    public string? Problem => _problem.Visibility == Visibility.Visible ? _problem.Text : null;
}
