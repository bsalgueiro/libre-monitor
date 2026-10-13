using System.Windows.Media;

namespace LibreMonitor.App;

public enum ThemeChoice
{
    System,
    Light,
    Dark,
}

/// <summary>A complete set of colours for one look. Range colours are darker in the light theme to keep contrast on white.</summary>
public sealed record Theme(
    Color CardBackground,
    Color CardBorder,
    Color Text,
    Color Muted,
    /// <summary>Colour of lines, guides and fills drawn over the card (white on dark, near-black on light).</summary>
    Color Ink,
    byte FillAlpha,
    /// <summary>Outline around the "now" dot, matching the card so the dot looks cut out.</summary>
    Color Ring,
    Color Pill,
    Color InRange,
    Color High,
    Color Low)
{
    public static readonly Theme Dark = new(
        CardBackground: Color.FromArgb(0xEB, 0x17, 0x1C, 0x23),
        CardBorder: Color.FromArgb(0x26, 0xFF, 0xFF, 0xFF),
        Text: Color.FromRgb(0xF2, 0xF5, 0xF9),
        Muted: Color.FromRgb(0x8B, 0x95, 0xA3),
        Ink: Color.FromRgb(0xFF, 0xFF, 0xFF),
        FillAlpha: 46,
        Ring: Color.FromArgb(230, 20, 25, 33),
        Pill: Color.FromArgb(242, 16, 20, 25),
        InRange: Color.FromRgb(0x5C, 0xD6, 0x8A),
        High: Color.FromRgb(0xFF, 0xB8, 0x4D),
        Low: Color.FromRgb(0xFF, 0x6B, 0x6B));

    public static readonly Theme Light = new(
        CardBackground: Color.FromArgb(0xB8, 0xFA, 0xFB, 0xFD),
        CardBorder: Color.FromArgb(0x2E, 0x00, 0x00, 0x00),
        Text: Color.FromRgb(0x14, 0x1A, 0x22),
        Muted: Color.FromRgb(0x5F, 0x6B, 0x7A),
        Ink: Color.FromRgb(0x1B, 0x23, 0x30),
        FillAlpha: 30,
        Ring: Color.FromArgb(235, 250, 251, 253),
        Pill: Color.FromArgb(245, 255, 255, 255),
        InRange: Color.FromRgb(0x1F, 0x9D, 0x5B),
        High: Color.FromRgb(0xC7, 0x77, 0x00),
        Low: Color.FromRgb(0xD6, 0x3A, 0x3A));
}

/// <summary>Range thresholds and the colours of the active theme. Thresholds only colour the display; they are not alarms.</summary>
public static class Palette
{
    public const double LowMgPerDl = 70;
    public const double HighMgPerDl = 180;

    /// <summary>Plain reference line drawn across the graph.</summary>
    public const double ReferenceMgPerDl = 100;

    public static Theme Current { get; private set; } = Theme.Dark;

    public static void Use(Theme theme) => Current = theme;

    public static Color InRange => Current.InRange;
    public static Color High => Current.High;
    public static Color Low => Current.Low;
    public static Color Muted => Current.Muted;
    public static Color Text => Current.Text;

    /// <summary>The theme's ink colour at the given opacity, for guides, fills and faint labels.</summary>
    public static Color Ink(byte alpha) => Color.FromArgb(alpha, Current.Ink.R, Current.Ink.G, Current.Ink.B);

    public static Color WithAlpha(Color color, byte alpha) => Color.FromArgb(alpha, color.R, color.G, color.B);

    public static Color ForMgPerDl(double mgPerDl) => mgPerDl switch
    {
        < LowMgPerDl => Low,
        > HighMgPerDl => High,
        _ => InRange,
    };

    public static SolidColorBrush Brush(Color color)
    {
        var brush = new SolidColorBrush(color);
        brush.Freeze();
        return brush;
    }
}
