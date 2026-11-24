using System.Windows;
using System.Windows.Media;

namespace MolehillManager.Gui;

/// <summary>
///   The house colours and fonts, in one place, taken from what clients already receive rather than
///   invented for this app: <c>Site/assets/molehill.css</c> for the ink, accent and surfaces, and
///   <c>Client/Export-WeeklyReports.ps1</c> for the status cells, the note grey and the link blue.
///   The self-test reads both of those files when it can find them and says so if they drift apart.
///
///   Light theme only, deliberately. A dark theme is a second set of decisions about every status
///   colour, and the invoices and reports these screens sit next to are all light.
/// </summary>
internal static class Palette
{
    // from Site/assets/molehill.css
    public const string Ink = "#231F20";              // --ink
    public const string InkSecondary = "#2D2829";
    public const string Accent = "#44C8F5";           // --cyan
    public const string Paper = "#FFFFFF";            // --paper
    public const string Surface = "#F4F2F1";          // --shell
    public const string Line = "#E4E0DF";             // --line
    public const string LineStrong = "#D9D5D4";
    public const string Tint = "#F2FBFE";             // --tint
    public const string Muted = "#6F6A69";            // --muted
    public const string Disabled = "#8C8686";

    // from Client/Export-WeeklyReports.ps1
    public const string Note = "#7A7473";             // .note
    public const string Link = "#1B9BCB";             // a
    public const string StatusRed = "#D64545";        // td.Red / td.critical, white text on it
    public const string StatusRedInk = "#FFFFFF";
    public const string StatusAmber = "#F9D58C";      // td.Amber / td.warning
    public const string StatusGreen = "#D5EEDD";      // td.Green / td.ok
    public const string StatusInfo = "#DDF3FC";       // td.info

    /// <summary>
    ///   Every colour, by the key a view asks for. One definition: <see cref="Build"/> makes the
    ///   brushes from this and the self-test checks this, so neither can list a colour the other
    ///   does not have.
    /// </summary>
    public static readonly (string Key, string Hex)[] Colours =
    {
        ("Ink", Ink), ("InkSecondary", InkSecondary), ("Accent", Accent), ("Paper", Paper),
        ("Surface", Surface), ("Line", Line), ("LineStrong", LineStrong), ("Tint", Tint),
        ("Muted", Muted), ("Disabled", Disabled), ("Note", Note), ("Link", Link),
        ("StatusRed", StatusRed), ("StatusRedInk", StatusRedInk), ("StatusAmber", StatusAmber),
        ("StatusGreen", StatusGreen), ("StatusInfo", StatusInfo)
    };

    /// <summary>
    ///   Krungthep for headings, as on the invoices and the site, with the same fallbacks; the body
    ///   text is the system UI font, because data needs to be legible rather than branded. WPF takes
    ///   a comma-separated list and walks it, which is what the CSS --title and --body do.
    /// </summary>
    public const string TitleFontFamily = "Krungthep, Bahnschrift, DIN Alternate, Trebuchet MS, Segoe UI";
    public const string BodyFontFamily = "Segoe UI, Arial";

    public static readonly (string Key, string Families)[] Fonts =
    {
        ("TitleFont", TitleFontFamily), ("BodyFont", BodyFontFamily)
    };

    /// <summary>
    ///   The resources every view looks things up in: a frozen SolidColorBrush under each colour's
    ///   key, the Color itself under the key plus "Colour", and the two font families.
    /// </summary>
    public static ResourceDictionary Build()
    {
        var resources = new ResourceDictionary();
        foreach (var (key, hex) in Colours)
        {
            var colour = (Color)ColorConverter.ConvertFromString(hex);
            var brush = new SolidColorBrush(colour);
            brush.Freeze();
            resources[key] = brush;
            resources[key + "Colour"] = colour;
        }
        foreach (var (key, families) in Fonts) resources[key] = new FontFamily(families);
        return resources;
    }
}
