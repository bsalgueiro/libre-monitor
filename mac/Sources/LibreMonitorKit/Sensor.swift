import Foundation

// Port of windows/src/LibreMonitor.Core/Sensor.cs

/// When the sensor in use is due to end. The service reports when the sensor was activated but not when it ends, so the
/// end is the activation plus the sensor's duration. The service does not say how long that is either, so the user
/// chooses it (14 days by default; the Libre 2 Plus and Libre 3 Plus last 15). It is still an estimate, and wording
/// around it says "about".
public enum SensorSchedule {
    /// The duration assumed until the user chooses one.
    public static let defaultDurationDays = 14

    /// The durations the user can choose from. More can be added here when another kind of sensor needs it.
    public static let durationChoices = [14, 15]

    /// The notification about the sensor ending comes when this little time is left.
    public static let noticeBefore: TimeInterval = 24 * 3600

    /// The given duration if it is one of the choices, otherwise the default (for example a saved value that no longer exists).
    public static func normalizeDurationDays(_ days: Int) -> Int {
        durationChoices.contains(days) ? days : defaultDurationDays
    }

    public static func endsAt(_ sensor: SensorInfo, durationDays: Int = defaultDurationDays) -> Date {
        sensor.activatedAt.addingTimeInterval(TimeInterval(normalizeDurationDays(durationDays)) * 86400)
    }

    /// Time left; zero or negative once the sensor is due to have ended.
    public static func remaining(_ sensor: SensorInfo, now: Date, durationDays: Int = defaultDurationDays) -> TimeInterval {
        endsAt(sensor, durationDays: durationDays).timeIntervalSince(now)
    }
}

/// A notification that the sensor is about to end.
public struct SensorEndingRaised: Equatable, Sendable {
    public let endsAt: Date

    public init(endsAt: Date) {
        self.endsAt = endsAt
    }
}

/// Decides when to say the sensor is about to end: once per sensor and chosen duration, when `noticeBefore` or less
/// remains. Pure logic with no UI or clock of its own. Nothing is stored, so after a restart the notice may come once
/// more for the same sensor. Changing the duration counts as a new question: a notice already given for 14 days does
/// not stop one at the end of 15.
public final class SensorExpiryEvaluator {
    private var notifiedActivation: Date?
    private var notifiedDurationDays: Int?

    public init() {}

    /// - Parameter snoozedUntil: the shared alert snooze, if one is active; the notice is raised once the snooze ends.
    public func evaluate(
        _ sensor: SensorInfo?, now: Date, snoozedUntil: Date? = nil,
        durationDays: Int = SensorSchedule.defaultDurationDays) -> SensorEndingRaised?
    {
        guard let sensor else { return nil }

        let days = SensorSchedule.normalizeDurationDays(durationDays)
        let remaining = SensorSchedule.remaining(sensor, now: now, durationDays: days)
        if remaining <= 0 || remaining > SensorSchedule.noticeBefore { return nil }
        if notifiedActivation == sensor.activatedAt && notifiedDurationDays == days { return nil }
        if let until = snoozedUntil, now < until { return nil }

        notifiedActivation = sensor.activatedAt
        notifiedDurationDays = days
        return SensorEndingRaised(endsAt: SensorSchedule.endsAt(sensor, durationDays: days))
    }
}
