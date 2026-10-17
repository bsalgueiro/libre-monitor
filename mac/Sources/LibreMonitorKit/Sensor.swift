import Foundation

// Port of windows/src/LibreMonitor.Core/Sensor.cs

/// When the sensor in use is due to end. The service reports when the sensor was activated but not when it ends, so the
/// end is the activation plus the sensor's life span. The service does not say how long that is either, so the user
/// chooses it (14 days by default; the Libre 2 Plus and Libre 3 Plus last 15). It is still an estimate, and wording
/// around it says "about".
public enum SensorSchedule {
    /// The life span assumed until the user chooses one.
    public static let defaultLifeDays = 14

    /// The life spans the user can choose from. More can be added here when another kind of sensor needs it.
    public static let lifeChoices = [14, 15]

    /// The notification about the sensor ending comes when this little time is left.
    public static let noticeBefore: TimeInterval = 24 * 3600

    /// The given life span if it is one of the choices, otherwise the default (for example a saved value that no longer exists).
    public static func normalizeLifeDays(_ days: Int) -> Int {
        lifeChoices.contains(days) ? days : defaultLifeDays
    }

    public static func endsAt(_ sensor: SensorInfo, lifeDays: Int = defaultLifeDays) -> Date {
        sensor.activatedAt.addingTimeInterval(TimeInterval(normalizeLifeDays(lifeDays)) * 86400)
    }

    /// Time left; zero or negative once the sensor is due to have ended.
    public static func remaining(_ sensor: SensorInfo, now: Date, lifeDays: Int = defaultLifeDays) -> TimeInterval {
        endsAt(sensor, lifeDays: lifeDays).timeIntervalSince(now)
    }
}

/// A notification that the sensor is about to end.
public struct SensorEndingRaised: Equatable, Sendable {
    public let endsAt: Date

    public init(endsAt: Date) {
        self.endsAt = endsAt
    }
}

/// Decides when to say the sensor is about to end: once per sensor and chosen life span, when `noticeBefore` or less
/// remains. Pure logic with no UI or clock of its own. Nothing is stored, so after a restart the notice may come once
/// more for the same sensor. Changing the life span counts as a new question: a notice already given for 14 days does
/// not stop one at the end of 15.
public final class SensorExpiryEvaluator {
    private var notifiedActivation: Date?
    private var notifiedLifeDays: Int?

    public init() {}

    /// - Parameter snoozedUntil: the shared alert snooze, if one is active; the notice is raised once the snooze ends.
    public func evaluate(
        _ sensor: SensorInfo?, now: Date, snoozedUntil: Date? = nil,
        lifeDays: Int = SensorSchedule.defaultLifeDays) -> SensorEndingRaised?
    {
        guard let sensor else { return nil }

        let days = SensorSchedule.normalizeLifeDays(lifeDays)
        let remaining = SensorSchedule.remaining(sensor, now: now, lifeDays: days)
        if remaining <= 0 || remaining > SensorSchedule.noticeBefore { return nil }
        if notifiedActivation == sensor.activatedAt && notifiedLifeDays == days { return nil }
        if let until = snoozedUntil, now < until { return nil }

        notifiedActivation = sensor.activatedAt
        notifiedLifeDays = days
        return SensorEndingRaised(endsAt: SensorSchedule.endsAt(sensor, lifeDays: days))
    }
}
