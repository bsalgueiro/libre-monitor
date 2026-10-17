import Foundation

// Port of windows/src/LibreMonitor.Core/Sensor.cs

/// When the sensor in use is due to end. The service reports when the sensor was activated but not when it ends, so the
/// end is the activation plus the usual lifetime. That is an estimate: wording around it says "about", and a sensor
/// type with a longer life would simply end a day later than shown, which is the safe way round.
public enum SensorSchedule {
    /// Libre 2 and 3 sensors last 14 days (a Libre 3 Plus lasts 15).
    public static let lifetime: TimeInterval = 14 * 24 * 3600

    /// The notification about the sensor ending comes when this little time is left.
    public static let noticeBefore: TimeInterval = 24 * 3600

    public static func endsAt(_ sensor: SensorInfo) -> Date { sensor.activatedAt.addingTimeInterval(lifetime) }

    /// Time left; zero or negative once the sensor is due to have ended.
    public static func remaining(_ sensor: SensorInfo, now: Date) -> TimeInterval {
        endsAt(sensor).timeIntervalSince(now)
    }
}

/// A notification that the sensor is about to end.
public struct SensorEndingRaised: Equatable, Sendable {
    public let endsAt: Date

    public init(endsAt: Date) {
        self.endsAt = endsAt
    }
}

/// Decides when to say the sensor is about to end: once per sensor, when `noticeBefore` or less remains. Pure logic
/// with no UI or clock of its own. Nothing is stored, so after a restart the notice may come once more for the same sensor.
public final class SensorExpiryEvaluator {
    private var notifiedFor: Date?

    public init() {}

    /// - Parameter snoozedUntil: the shared alert snooze, if one is active; the notice is raised once the snooze ends.
    public func evaluate(_ sensor: SensorInfo?, now: Date, snoozedUntil: Date? = nil) -> SensorEndingRaised? {
        guard let sensor else { return nil }

        let remaining = SensorSchedule.remaining(sensor, now: now)
        if remaining <= 0 || remaining > SensorSchedule.noticeBefore { return nil }
        if notifiedFor == sensor.activatedAt { return nil }
        if let until = snoozedUntil, now < until { return nil }

        notifiedFor = sensor.activatedAt
        return SensorEndingRaised(endsAt: SensorSchedule.endsAt(sensor))
    }
}
