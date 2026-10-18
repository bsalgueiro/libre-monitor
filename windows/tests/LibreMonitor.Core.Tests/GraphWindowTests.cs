using LibreMonitor.Core;

namespace LibreMonitor.Core.Tests;

public class GraphWindowTests
{
    private static readonly DateTimeOffset Start = new(2026, 10, 18, 6, 0, 0, TimeSpan.Zero);
    private static readonly TimeSpan Gap = TimeSpan.FromMinutes(40);

    private static GlucoseReading R(int minutesFromStart, double mgPerDl) =>
        new(Start.AddMinutes(minutesFromStart), mgPerDl, mgPerDl, Trend.Stable, mgPerDl > 180, mgPerDl < 70);

    [Fact]
    public void NothingOlderThanTheWindow_IsReturnedAsItIs()
    {
        var readings = new[] { R(5, 100), R(20, 110), R(35, 120) };

        var clipped = GraphWindow.ClipToWindow(readings, Start, Gap);

        Assert.Equal(readings, clipped);
    }

    [Fact]
    public void AReadingJustBeforeTheWindow_IsReplacedByTheValueAtTheEdge()
    {
        // 100 at 15 minutes before, 130 at 15 minutes after: halfway between them at the edge.
        var clipped = GraphWindow.ClipToWindow([R(-15, 100), R(15, 130), R(30, 140)], Start, Gap);

        Assert.Equal(3, clipped.Count);
        Assert.Equal(Start, clipped[0].TimestampUtc);
        Assert.Equal(115, clipped[0].MgPerDl, 6);
        Assert.Equal(130, clipped[1].MgPerDl);
    }

    [Fact]
    public void TheEdgeValue_IsInterpolatedByTime_NotAveraged()
    {
        // The edge is a third of the way from the older reading to the newer one.
        var clipped = GraphWindow.ClipToWindow([R(-10, 100), R(20, 190)], Start, Gap);

        Assert.Equal(130, clipped[0].MgPerDl, 6);
    }

    [Fact]
    public void AReadingExactlyAtTheEdge_NeedsNoInterpolation()
    {
        var clipped = GraphWindow.ClipToWindow([R(-15, 100), R(0, 120), R(15, 130)], Start, Gap);

        Assert.Equal(2, clipped.Count);
        Assert.Equal(120, clipped[0].MgPerDl);
        Assert.Equal(Start, clipped[0].TimestampUtc);
    }

    [Fact]
    public void OnlyTheNearestOlderReading_Matters()
    {
        var clipped = GraphWindow.ClipToWindow([R(-45, 60), R(-30, 80), R(10, 120)], Start, Gap);

        // Between the reading 30 minutes before (80) and the one 10 minutes after (120): a quarter of the way in time is 30/40.
        Assert.Equal(110, clipped[0].MgPerDl, 6);
        Assert.Equal(2, clipped.Count);
    }

    [Fact]
    public void ARealGapAtTheEdge_StartsTheLineAtTheFirstReadingInside()
    {
        // 60 minutes between the last reading before the window and the first inside: more than the gap, so no edge point.
        var clipped = GraphWindow.ClipToWindow([R(-50, 100), R(10, 130), R(25, 135)], Start, Gap);

        Assert.Equal(2, clipped.Count);
        Assert.Equal(130, clipped[0].MgPerDl);
    }

    [Fact]
    public void EverythingOlderThanTheWindow_GivesNoLine()
    {
        Assert.Empty(GraphWindow.ClipToWindow([R(-60, 100), R(-30, 110)], Start, Gap));
    }

    [Fact]
    public void NoReadings_GivesNoLine() => Assert.Empty(GraphWindow.ClipToWindow([], Start, Gap));

    [Fact]
    public void TheEdgeReading_IsFlaggedLikeAnyReading()
    {
        var clipped = GraphWindow.ClipToWindow([R(-10, 60), R(10, 66)], Start, Gap);

        Assert.True(clipped[0].IsLow);
        Assert.False(clipped[0].IsHigh);
    }

    [Fact]
    public void TheInputIsNotChanged()
    {
        var readings = new[] { R(-10, 100), R(10, 120) };

        GraphWindow.ClipToWindow(readings, Start, Gap);

        Assert.Equal(2, readings.Length);
        Assert.Equal(-10, (readings[0].TimestampUtc - Start).TotalMinutes);
    }
}
