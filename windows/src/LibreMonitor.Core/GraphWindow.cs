namespace LibreMonitor.Core;

/// <summary>
/// Which readings to draw as a line for a graph window that starts at a given time. Pure logic, so the edge cases are tested
/// and both platforms draw the same line.
/// </summary>
public static class GraphWindow
{
    /// <summary>
    /// The readings from <paramref name="start"/> onwards, with the line starting exactly at <paramref name="start"/>.
    /// A reading just before the window is not drawn where it is (pinning it to the left edge made the line start with a small
    /// vertical hook). Instead the line enters the window at the value it had at the edge, interpolated between that
    /// reading and the first one inside. If the two are further apart than <paramref name="maxGap"/> there is a real gap in the data, so the
    /// line simply starts at the first reading inside, as it would after any other gap.
    /// </summary>
    /// <param name="sorted">The readings, oldest first.</param>
    public static List<GlucoseReading> ClipToWindow(IReadOnlyList<GlucoseReading> sorted, DateTimeOffset start, TimeSpan maxGap)
    {
        var first = -1;
        for (var i = 0; i < sorted.Count; i++)
        {
            if (sorted[i].TimestampUtc >= start)
            {
                first = i;
                break;
            }
        }

        if (first < 0) return [];

        var clipped = new List<GlucoseReading>(sorted.Count - first + 1);
        if (first > 0)
        {
            var before = sorted[first - 1];
            var inside = sorted[first];
            var span = inside.TimestampUtc - before.TimestampUtc;
            if (inside.TimestampUtc > start && span <= maxGap)
            {
                var t = (start - before.TimestampUtc).TotalSeconds / span.TotalSeconds;
                var value = before.MgPerDl + (inside.MgPerDl - before.MgPerDl) * t;
                clipped.Add(new GlucoseReading(start, value, value, Trend.Unknown, value > 180, value < 70));
            }
        }

        for (var i = first; i < sorted.Count; i++) clipped.Add(sorted[i]);
        return clipped;
    }
}
