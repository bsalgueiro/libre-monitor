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

/// The user's choices for the "sensor is about to end" alert. On by default, one day before the end, once a day, which
/// is the single notice the app gave before this could be set.
public struct SensorAlertSettings: Codable, Equatable, Sendable {
    public static let maxDaysBefore = 7

    /// Once a day, every 6 hours, every hour (in minutes).
    public static let repeatChoices = [1440, 360, 60]

    public var enabled: Bool
    /// How many days before the end the alerts start, 1 to `maxDaysBefore`.
    public var daysBefore: Int
    /// How often to repeat once they have started: one of `repeatChoices`.
    public var repeatMinutes: Int

    public init(enabled: Bool = true, daysBefore: Int = 1, repeatMinutes: Int = 1440) {
        self.enabled = enabled
        self.daysBefore = daysBefore
        self.repeatMinutes = repeatMinutes
    }

    /// - Returns: a message describing the first problem, or nil when the settings are usable.
    public func validate() -> String? {
        if daysBefore < 1 || daysBefore > Self.maxDaysBefore {
            return "The sensor alert must start between 1 and \(Self.maxDaysBefore) days before the end."
        }
        if !Self.repeatChoices.contains(repeatMinutes) { return "Choose how often to repeat the sensor alert." }
        return nil
    }
}

/// A notification that the sensor is about to end.
public struct SensorEndingRaised: Equatable, Sendable {
    public let endsAt: Date
    public let isReminder: Bool

    public init(endsAt: Date, isReminder: Bool = false) {
        self.endsAt = endsAt
        self.isReminder = isReminder
    }
}

/// Decides when to say the sensor is about to end: from `daysBefore` days before the end, then again at the chosen
/// interval, until the end. Pure logic with no UI or clock of its own. Nothing is stored, so after a restart the first
/// notice may come once more for the same sensor. Changing the duration counts as a new question: notices given for 14
/// days do not stop the ones at the end of 15.
public final class SensorExpiryEvaluator {
    private var episodeActivation: Date?
    private var episodeDuration: Int?
    private var lastRaisedAt: Date?

    public init() {}

    /// Forget what has been raised, for example after the settings change.
    public func reset() {
        episodeActivation = nil
        episodeDuration = nil
        lastRaisedAt = nil
    }

    /// - Parameter snoozedUntil: the shared alert snooze, if one is active; a held notice is raised once it ends.
    public func evaluate(
        _ sensor: SensorInfo?, now: Date, settings: SensorAlertSettings, snoozedUntil: Date? = nil,
        durationDays: Int = SensorSchedule.defaultDurationDays) -> SensorEndingRaised?
    {
        guard let sensor, settings.enabled else {
            reset()
            return nil
        }

        let days = SensorSchedule.normalizeDurationDays(durationDays)
        let remaining = SensorSchedule.remaining(sensor, now: now, durationDays: days)
        if remaining <= 0 || remaining > TimeInterval(settings.daysBefore) * 86400 { return nil }

        if episodeActivation != sensor.activatedAt || episodeDuration != days {
            episodeActivation = sensor.activatedAt
            episodeDuration = days
            lastRaisedAt = nil
        }

        if let until = snoozedUntil, now < until { return nil }

        let neverRaised = lastRaisedAt == nil
        var reminderDue = false
        if let last = lastRaisedAt {
            reminderDue = now.timeIntervalSince(last) >= TimeInterval(settings.repeatMinutes * 60)
        }
        if !neverRaised && !reminderDue { return nil }

        lastRaisedAt = now
        return SensorEndingRaised(endsAt: SensorSchedule.endsAt(sensor, durationDays: days), isReminder: !neverRaised)
    }
}
