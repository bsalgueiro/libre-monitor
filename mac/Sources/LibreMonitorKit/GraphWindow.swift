import Foundation

// Port of windows/src/LibreMonitor.Core/GraphWindow.cs

/// Which readings to draw as a line for a graph window that starts at a given time. Pure logic, so the edge cases are tested
/// and both platforms draw the same line.
public enum GraphWindow {
    /// The readings from `start` onwards, with the line starting exactly at `start`.
    /// A reading just before the window is not drawn where it is (pinning it to the left edge made the line start with a small
    /// vertical hook). Instead the line enters the window at the value it had at the edge, interpolated between that
    /// reading and the first one inside. If the two are further apart than `maxGap` there is a real gap in the data, so the
    /// line simply starts at the first reading inside, as it would after any other gap.
    /// - Parameter sorted: the readings, oldest first.
    public static func clipToWindow(_ sorted: [GlucoseReading], start: Date, maxGap: TimeInterval) -> [GlucoseReading] {
        guard let first = sorted.firstIndex(where: { $0.timestamp >= start }) else { return [] }

        var clipped: [GlucoseReading] = []
        clipped.reserveCapacity(sorted.count - first + 1)

        if first > 0 {
            let before = sorted[first - 1]
            let inside = sorted[first]
            let span = inside.timestamp.timeIntervalSince(before.timestamp)
            if inside.timestamp > start && span <= maxGap {
                let t = start.timeIntervalSince(before.timestamp) / span
                let value = before.mgPerDl + (inside.mgPerDl - before.mgPerDl) * t
                clipped.append(GlucoseReading(
                    timestamp: start, mgPerDl: value, value: value, trend: .unknown, isHigh: value > 180, isLow: value < 70))
            }
        }

        clipped.append(contentsOf: sorted[first...])
        return clipped
    }
}
