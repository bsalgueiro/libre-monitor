using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using LibreMonitor.Core;

namespace LibreMonitor.App;

/// <summary>
/// Minimal glucose graph: smooth line coloured by range, shaded in-range band, and a dot on a dashed "now" line.
/// Drawn directly with a DrawingContext so it stays crisp at any size and DPI.
/// </summary>
public sealed class GlucoseGraph : FrameworkElement
{
    private const double PadRight = 5; // room for the "now" dot; the card padding supplies the rest, matching the left side
    private const double PadTop = 6;
    private const double PadBottom = 14;
    // History arrives every ~15 minutes and the newest reading can trail it by a while, so only a real outage breaks the line.
    private static readonly TimeSpan GapBreak = TimeSpan.FromMinutes(40);
    private static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(10);

    public static readonly DependencyProperty ReadingsProperty = DependencyProperty.Register(
        nameof(Readings), typeof(IReadOnlyList<GlucoseReading>), typeof(GlucoseGraph),
        new FrameworkPropertyMetadata(null, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty HoursProperty = DependencyProperty.Register(
        nameof(Hours), typeof(double), typeof(GlucoseGraph),
        new FrameworkPropertyMetadata(6.0, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty UnitProperty = DependencyProperty.Register(
        nameof(Unit), typeof(GlucoseUnit), typeof(GlucoseGraph),
        new FrameworkPropertyMetadata(GlucoseUnit.MgPerDl, FrameworkPropertyMetadataOptions.AffectsRender));

    /// <summary>Only changes how values are labelled; the plot itself always works in mg/dL.</summary>
    public GlucoseUnit Unit
    {
        get => (GlucoseUnit)GetValue(UnitProperty);
        set => SetValue(UnitProperty, value);
    }

    public IReadOnlyList<GlucoseReading>? Readings
    {
        get => (IReadOnlyList<GlucoseReading>?)GetValue(ReadingsProperty);
        set => SetValue(ReadingsProperty, value);
    }

    public double Hours
    {
        get => (double)GetValue(HoursProperty);
        set => SetValue(HoursProperty, value);
    }

    private double? _mouseX;

    /// <summary>Redraw without new data, so the "now" edge keeps moving.</summary>
    public void Refresh() => InvalidateVisual();

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        _mouseX = e.GetPosition(this).X;
        InvalidateVisual();
    }

    protected override void OnMouseLeave(MouseEventArgs e)
    {
        base.OnMouseLeave(e);
        _mouseX = null;
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;

        // A transparent fill makes the whole area hit-testable, so hover works between the drawn shapes.
        dc.DrawRectangle(Brushes.Transparent, null, new Rect(0, 0, w, h));
        if (w < 40 || h < 30) return;

        var plotW = w - PadRight;
        var plotH = h - PadTop - PadBottom;
        var end = DateTimeOffset.UtcNow;
        var start = end.AddHours(-Hours);

        var points = (Readings ?? [])
            .Where(r => r.TimestampUtc >= start.AddMinutes(-GapBreak.TotalMinutes))
            .OrderBy(r => r.TimestampUtc)
            .ToList();

        // Keep the target band visible even when the data is flat, and stretch to fit highs and lows.
        double lo = 54, hi = 200;
        if (points.Count > 0)
        {
            lo = Math.Min(lo, points.Min(p => p.MgPerDl) - 10);
            hi = Math.Max(hi, points.Max(p => p.MgPerDl) + 10);
        }
        lo = Math.Max(lo, 20);
        hi = Math.Min(hi, 500);

        double X(DateTimeOffset t) => Math.Clamp((t - start).TotalSeconds / (Hours * 3600), 0, 1) * plotW;
        double Y(double v) => PadTop + (1 - (Math.Clamp(v, lo, hi) - lo) / (hi - lo)) * plotH;
        var pixelsPerDip = VisualTreeHelper.GetDpi(this).PixelsPerDip;

        DrawBand(dc, plotW, Y, Unit, pixelsPerDip);
        DrawTimeLabels(dc, start, plotW, h, X, pixelsPerDip);

        if (points.Count == 0) return;

        var lineBrush = RangeGradient(Y(hi), Y(lo), Y);
        var linePen = new Pen(lineBrush, 2.2) { LineJoin = PenLineJoin.Round, StartLineCap = PenLineCap.Round, EndLineCap = PenLineCap.Round };
        linePen.Freeze();
        var areaBrush = new LinearGradientBrush(Palette.Ink(Palette.Current.FillAlpha), Palette.Ink(0), 90);
        areaBrush.Freeze();
        var baseline = PadTop + plotH;

        foreach (var run in SplitAtGaps(points))
        {
            var xy = run.Select(r => new Point(X(r.TimestampUtc), Y(r.MgPerDl))).ToList();
            if (xy.Count == 1)
            {
                dc.DrawEllipse(lineBrush, null, xy[0], 1.6, 1.6);
                continue;
            }

            dc.DrawGeometry(areaBrush, null, BuildSpline(xy, closeToBaseline: baseline));
            dc.DrawGeometry(null, linePen, BuildSpline(xy, closeToBaseline: null));
        }

        DrawNow(dc, points[^1], end, X, Y, plotH);

        if (_mouseX is { } mouseX)
        {
            DrawHover(dc, points, mouseX, w, plotH, X, Y, Unit, pixelsPerDip);
        }
    }

    /// <summary>Highlights the reading nearest to the cursor and labels it with its value and time.</summary>
    private static void DrawHover(
        DrawingContext dc, List<GlucoseReading> points, double mouseX, double width, double plotH,
        Func<DateTimeOffset, double> x, Func<double, double> y, GlucoseUnit unit, double pixelsPerDip)
    {
        var nearest = points.MinBy(p => Math.Abs(x(p.TimestampUtc) - mouseX));
        if (nearest is null) return;

        var px = x(nearest.TimestampUtc);
        var py = y(nearest.MgPerDl);
        var colour = Palette.ForMgPerDl(nearest.MgPerDl);

        var guide = new Pen(Palette.Brush(Palette.Ink(90)), 1);
        guide.Freeze();
        dc.DrawLine(guide, new Point(px, PadTop), new Point(px, PadTop + plotH));

        var ring = new Pen(Palette.Brush(Palette.Current.Ring), 2);
        ring.Freeze();
        dc.DrawEllipse(Palette.Brush(colour), ring, new Point(px, py), 5.4, 5.4);

        var label = new FormattedText(
            $"{GlucoseUnits.Format(nearest.MgPerDl, unit, CultureInfo.CurrentCulture)}  ·  {nearest.TimestampUtc.ToLocalTime():HH:mm}",
            CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface(new FontFamily("Segoe UI Variable Display, Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal),
            11.5, Palette.Brush(Palette.Text), pixelsPerDip);

        double boxW = label.Width + 16, boxH = label.Height + 8;
        var boxX = Math.Clamp(px - boxW / 2, 0, Math.Max(0, width - boxW));
        var boxY = py - boxH - 10;
        if (boxY < 0) boxY = py + 12; // not enough room above a high reading

        var border = new Pen(Palette.Brush(Palette.WithAlpha(colour, 170)), 1);
        border.Freeze();
        dc.DrawRoundedRectangle(Palette.Brush(Palette.Current.Pill), border, new Rect(boxX, boxY, boxW, boxH), 6, 6);
        dc.DrawText(label, new Point(boxX + 8, boxY + 4));
    }

    private static void DrawBand(DrawingContext dc, double plotW, Func<double, double> y, GlucoseUnit unit, double pixelsPerDip)
    {
        var top = y(Palette.HighMgPerDl);
        var bottom = y(Palette.LowMgPerDl);
        var band = Palette.Brush(Palette.WithAlpha(Palette.InRange, 30));
        dc.DrawRoundedRectangle(band, null, new Rect(0, top, plotW, bottom - top), 3, 3);

        string Label(double mgPerDl) => GlucoseUnits.Format(mgPerDl, unit, CultureInfo.CurrentCulture);
        var label = Palette.Brush(Palette.WithAlpha(Palette.Muted, 130));
        DrawText(dc, Label(Palette.HighMgPerDl), new Point(3, top - 11), label, 8.5, pixelsPerDip);
        DrawText(dc, Label(Palette.LowMgPerDl), new Point(3, bottom + 1), label, 8.5, pixelsPerDip);

        // Straight reference line, drawn under the curve so the data stays on top.
        var referenceY = y(Palette.ReferenceMgPerDl);
        var referencePen = new Pen(Palette.Brush(Palette.Ink(95)), 1);
        referencePen.Freeze();
        dc.DrawLine(referencePen, new Point(0, referenceY), new Point(plotW, referenceY));
        DrawText(dc, Label(Palette.ReferenceMgPerDl), new Point(3, referenceY - 11), label, 8.5, pixelsPerDip);
    }

    private void DrawTimeLabels(DrawingContext dc, DateTimeOffset start, double plotW, double h, Func<DateTimeOffset, double> x, double pixelsPerDip)
    {
        var step = Hours <= 3 ? 1 : Hours <= 6 ? 2 : 3;
        var local = start.ToLocalTime();
        var tick = new DateTimeOffset(local.Year, local.Month, local.Day, local.Hour, 0, 0, local.Offset).AddHours(1);
        while (tick.Hour % step != 0) tick = tick.AddHours(1);

        var brush = Palette.Brush(Palette.WithAlpha(Palette.Muted, 140));
        for (; x(tick) < plotW - 16; tick = tick.AddHours(step))
        {
            var px = x(tick);
            if (px < 10) continue;
            DrawText(dc, tick.ToString("HH", CultureInfo.InvariantCulture) + "h", new Point(px - 7, h - PadBottom + 2), brush, 8.5, pixelsPerDip);
        }
    }

    private void DrawNow(DrawingContext dc, GlucoseReading latest, DateTimeOffset now, Func<DateTimeOffset, double> x, Func<double, double> y, double plotH)
    {
        var stale = now - latest.TimestampUtc > StaleAfter;
        var colour = stale ? Palette.Muted : Palette.ForMgPerDl(latest.MgPerDl);
        var px = x(latest.TimestampUtc);
        var py = y(latest.MgPerDl);

        var dash = new Pen(Palette.Brush(Palette.Ink(70)), 1) { DashStyle = new DashStyle([3, 3], 0) };
        dash.Freeze();
        dc.DrawLine(dash, new Point(px, PadTop), new Point(px, PadTop + plotH));

        var ring = new Pen(Palette.Brush(Palette.Current.Ring), 2);
        ring.Freeze();
        dc.DrawEllipse(Palette.Brush(colour), ring, new Point(px, py), 4.6, 4.6);
    }

    /// <summary>Vertical gradient that keeps the line amber above range, green inside it and red below, with soft transitions.</summary>
    private static LinearGradientBrush RangeGradient(double top, double bottom, Func<double, double> y)
    {
        var span = bottom - top;
        double Offset(double v) => span <= 0 ? 0 : Math.Clamp((y(v) - top) / span, 0, 1);
        double high = Offset(Palette.HighMgPerDl), low = Offset(Palette.LowMgPerDl);
        const double blend = 0.03;

        var highEdge = Math.Min(1, high + blend);
        var lowStart = Math.Max(highEdge, low - blend);

        var brush = new LinearGradientBrush
        {
            MappingMode = BrushMappingMode.Absolute,
            StartPoint = new Point(0, top),
            EndPoint = new Point(0, bottom),
        };
        brush.GradientStops.Add(new GradientStop(Palette.High, 0));
        brush.GradientStops.Add(new GradientStop(Palette.High, Math.Max(0, high - blend)));
        brush.GradientStops.Add(new GradientStop(Palette.InRange, highEdge));
        brush.GradientStops.Add(new GradientStop(Palette.InRange, lowStart));
        brush.GradientStops.Add(new GradientStop(Palette.Low, Math.Min(1, low + blend)));
        brush.GradientStops.Add(new GradientStop(Palette.Low, 1));
        brush.Freeze();
        return brush;
    }

    /// <summary>Catmull-Rom spline through the points, converted to cubic Béziers. Optionally closed down to a baseline for the area fill.</summary>
    private static StreamGeometry BuildSpline(IReadOnlyList<Point> p, double? closeToBaseline)
    {
        var geometry = new StreamGeometry();
        using (var ctx = geometry.Open())
        {
            if (closeToBaseline is { } baseline)
            {
                ctx.BeginFigure(new Point(p[0].X, baseline), isFilled: true, isClosed: true);
                ctx.LineTo(p[0], false, false);
            }
            else
            {
                ctx.BeginFigure(p[0], isFilled: false, isClosed: false);
            }

            for (var i = 0; i < p.Count - 1; i++)
            {
                var p0 = p[Math.Max(i - 1, 0)];
                var p1 = p[i];
                var p2 = p[i + 1];
                var p3 = p[Math.Min(i + 2, p.Count - 1)];
                ctx.BezierTo(
                    new Point(p1.X + (p2.X - p0.X) / 6, p1.Y + (p2.Y - p0.Y) / 6),
                    new Point(p2.X - (p3.X - p1.X) / 6, p2.Y - (p3.Y - p1.Y) / 6),
                    p2, closeToBaseline is null, closeToBaseline is null);
            }

            if (closeToBaseline is { } b) ctx.LineTo(new Point(p[^1].X, b), false, false);
        }

        geometry.Freeze();
        return geometry;
    }

    private static IEnumerable<List<GlucoseReading>> SplitAtGaps(List<GlucoseReading> points)
    {
        var run = new List<GlucoseReading> { points[0] };
        for (var i = 1; i < points.Count; i++)
        {
            if (points[i].TimestampUtc - points[i - 1].TimestampUtc > GapBreak)
            {
                yield return run;
                run = [];
            }

            run.Add(points[i]);
        }

        yield return run;
    }

    private static void DrawText(DrawingContext dc, string text, Point at, Brush brush, double size, double pixelsPerDip)
    {
        var formatted = new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
            new Typeface("Segoe UI"), size, brush, pixelsPerDip);
        dc.DrawText(formatted, at);
    }
}
