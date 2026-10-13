using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using LibreMonitor.Core;
using DrawingColor = System.Drawing.Color;
using MediaColor = System.Windows.Media.Color;

namespace LibreMonitor.App;

/// <summary>
/// Notification-area icon. Its image is the current glucose value on a tile coloured by range, so the reading
/// can be seen even when the widget is hidden. Left-click toggles the widget; the menu offers show/hide and exit.
/// </summary>
public sealed class TrayController : IDisposable
{
    private const int IconSize = 32;
    // White digits on a deep-coloured tile, like the flat white-on-colour glyphs elsewhere in the tray.
    // The light theme's range colours are the darker ones, which keep white readable.
    private static readonly DrawingColor Ink = DrawingColor.White;
    private static readonly Theme TileColours = Theme.Light;

    private readonly NotifyIcon _icon;
    private readonly ToolStripMenuItem _toggleItem;
    private readonly Func<bool> _isWidgetVisible;
    private Icon? _current;

    public TrayController(Func<bool> isWidgetVisible, Action toggleWidget, Action exit)
    {
        _isWidgetVisible = isWidgetVisible;

        _toggleItem = new ToolStripMenuItem("Hide widget", null, (_, _) => toggleWidget());
        var menu = new ContextMenuStrip();
        menu.Items.Add(_toggleItem);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => exit());
        menu.Opening += (_, _) => _toggleItem.Text = _isWidgetVisible() ? "Hide widget" : "Show widget";

        _icon = new NotifyIcon { ContextMenuStrip = menu, Text = "Libre Monitor" };
        _icon.MouseClick += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) toggleWidget();
        };

        SetIcon(Render("--", TileColours.Muted));
    }

    public bool Visible
    {
        get => _icon.Visible;
        set => _icon.Visible = value;
    }

    /// <param name="problem">Connection problem to show instead of the reading, if any.</param>
    public void Update(GlucoseReading? current, GlucoseUnit unit, bool stale, string? problem, string age)
    {
        if (current is null)
        {
            SetIcon(Render("?", TileColours.Muted));
            SetTooltip(problem is null ? "Libre Monitor: no reading" : $"Libre Monitor: {problem}");
            return;
        }

        var value = GlucoseUnits.Format(current.MgPerDl, unit, CultureInfo.CurrentCulture);
        var colour = stale || problem is not null ? TileColours.Muted : ColourFor(current.MgPerDl);
        SetIcon(Render(value, colour));

        var tooltip = $"{value} {unit.Label()} {current.Trend.ToArrow()} · {age}";
        SetTooltip(problem is null ? tooltip : $"{tooltip} · {problem}");
    }

    public void Dispose()
    {
        // Disposing removes the icon from the tray; otherwise a ghost icon lingers until the mouse passes over it.
        _icon.Visible = false;
        _icon.Dispose();
        _icon.ContextMenuStrip?.Dispose();
        _current?.Dispose();
    }

    private static MediaColor ColourFor(double mgPerDl) => mgPerDl switch
    {
        < Palette.LowMgPerDl => TileColours.Low,
        > Palette.HighMgPerDl => TileColours.High,
        _ => TileColours.InRange,
    };

    private void SetTooltip(string text) => _icon.Text = text.Length > 120 ? text[..120] : text;

    private void SetIcon(Icon icon)
    {
        _icon.Icon = icon;
        _current?.Dispose();
        _current = icon;
    }

    private static Icon Render(string text, MediaColor tile)
    {
        using var bitmap = new Bitmap(IconSize, IconSize);
        using (var g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;

            // Edge to edge, so the tile uses the whole icon area and reads as large as the tray allows.
            using var path = RoundedRectangle(new RectangleF(0, 0, IconSize, IconSize), 6);
            using var background = new SolidBrush(DrawingColor.FromArgb(tile.R, tile.G, tile.B));
            g.FillPath(background, path);

            // Typographic format drops the default side padding, and NoWrap keeps a too-wide value on one line
            // (wrapping used to push the second digit out of the tile, leaving only the first visible).
            using var format = (StringFormat)StringFormat.GenericTypographic.Clone();
            format.Alignment = StringAlignment.Center;
            format.LineAlignment = StringAlignment.Center;
            format.FormatFlags |= StringFormatFlags.NoWrap;

            using var foreground = new SolidBrush(Ink);
            using var font = FitFont(g, text, format);
            g.DrawString(text, font, foreground, new RectangleF(0, 0, IconSize, IconSize), format);
        }

        // GetHicon hands over a native handle that must be freed; the clone is an independent managed copy.
        var handle = bitmap.GetHicon();
        try
        {
            return (Icon)Icon.FromHandle(handle).Clone();
        }
        finally
        {
            DestroyIcon(handle);
        }
    }

    /// <summary>The largest bold font, up to 26px, with which the text still fits inside the tile.</summary>
    private static Font FitFont(Graphics g, string text, StringFormat format)
    {
        const float Largest = 26, Smallest = 8;
        const float MaxWidth = IconSize - 2;

        var pixels = Largest;
        var font = new Font("Segoe UI", pixels, FontStyle.Bold, GraphicsUnit.Pixel);
        while (pixels > Smallest && g.MeasureString(text, font, PointF.Empty, format).Width > MaxWidth)
        {
            font.Dispose();
            pixels--;
            font = new Font("Segoe UI", pixels, FontStyle.Bold, GraphicsUnit.Pixel);
        }

        return font;
    }

    private static GraphicsPath RoundedRectangle(RectangleF r, float radius)
    {
        var d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr handle);
}
