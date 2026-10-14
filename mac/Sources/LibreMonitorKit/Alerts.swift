import Foundation

// Port of src/LibreMonitor.Core/Alerts.cs

public enum AlertKind: Sendable, Equatable {
    case low
    case high
}

/// User-chosen alert thresholds, always in mg/dL (the app converts for display). Both alerts are off by default.
public struct AlertSettings: Codable, Equatable, Sendable {
    public static let minLow = 40.0
    public static let maxLow = 150.0
    public static let minHigh = 100.0
    public static let maxHigh = 400.0
    public static let maxRepeatMinutes = 240

    public var lowEnabled: Bool
    public var lowMgPerDl: Double
    public var highEnabled: Bool
    public var highMgPerDl: Double
    /// Reminder interval while still out of range; 0 means alert once per episode.
    public var repeatMinutes: Int
    public var sound: Bool

    public init(
        lowEnabled: Bool = false,
        lowMgPerDl: Double = 70,
        highEnabled: Bool = false,
        highMgPerDl: Double = 180,
        repeatMinutes: Int = 30,
        sound: Bool = true)
    {
        self.lowEnabled = lowEnabled
        self.lowMgPerDl = lowMgPerDl
        self.highEnabled = highEnabled
        self.highMgPerDl = highMgPerDl
        self.repeatMinutes = repeatMinutes
        self.sound = sound
    }

    /// - Parameter unit: the unit the user is editing in; only used to word the message.
    /// - Returns: a message describing the first problem, or nil when the settings are usable.
    public func validate(unit: GlucoseUnit = .mgPerDl, locale: Locale = .current) -> String? {
        func f(_ mgPerDl: Double) -> String { GlucoseUnits.format(mgPerDl, unit: unit, locale: locale) }

        if lowMgPerDl < Self.minLow || lowMgPerDl > Self.maxLow {
            return "The low threshold must be between \(f(Self.minLow)) and \(f(Self.maxLow)) \(unit.label)."
        }

        if highMgPerDl < Self.minHigh || highMgPerDl > Self.maxHigh {
            return "The high threshold must be between \(f(Self.minHigh)) and \(f(Self.maxHigh)) \(unit.label)."
        }

        if lowMgPerDl >= highMgPerDl {
            return "The low threshold must be below the high threshold."
        }

        if repeatMinutes < 0 || repeatMinutes > Self.maxRepeatMinutes {
            return "The repeat interval must be between 0 and \(Self.maxRepeatMinutes) minutes."
        }

        return nil
    }
}

/// An alert that should be delivered now.
public struct AlertRaised: Equatable, Sendable {
    public let kind: AlertKind
    public let reading: GlucoseReading
    public let isReminder: Bool

    public init(kind: AlertKind, reading: GlucoseReading, isReminder: Bool) {
        self.kind = kind
        self.reading = reading
        self.isReminder = isReminder
    }
}

/// Decides when to alert. Pure logic with no UI or clock of its own, so every rule can be tested.
/// One instance follows one stream of readings.
public final class AlertEvaluator {
    /// Readings older than this are not acted on (the same limit the display uses for "old reading").
    public static let maxReadingAge: TimeInterval = 10 * 60

    /// After an alert, a reading must move this far back inside the range before the next crossing counts as a
    /// new episode, so a value hovering on the line does not alert repeatedly.
    public static let rearmMarginMgPerDl = 5.0

    private var episode: AlertKind?
    private var lastRaisedAt: Date?
    private var snoozeEnd = Date.distantPast

    public init() {}

    public func snoozedUntil(now: Date) -> Date? {
        snoozeEnd > now ? snoozeEnd : nil
    }

    public func snooze(until: Date) { snoozeEnd = until }

    public func resume() { snoozeEnd = Date.distantPast }

    /// Forget the current episode, for example after the thresholds change.
    public func reset() {
        episode = nil
        lastRaisedAt = nil
    }

    /// Which alert zone a reading is in right now, ignoring snooze and history; nil when in range, disabled or old.
    public static func classify(_ settings: AlertSettings, _ current: GlucoseReading?, now: Date) -> AlertKind? {
        guard let current, now.timeIntervalSince(current.timestamp) <= maxReadingAge else { return nil }

        if settings.lowEnabled && current.mgPerDl < settings.lowMgPerDl { return .low }
        if settings.highEnabled && current.mgPerDl > settings.highMgPerDl { return .high }
        return nil
    }

    /// - Returns: the alert to deliver, or nil when nothing is due.
    public func evaluate(_ settings: AlertSettings, _ current: GlucoseReading?, now: Date) -> AlertRaised? {
        // An old or missing reading says nothing about the present, so it neither alerts nor ends an episode.
        guard let current, now.timeIntervalSince(current.timestamp) <= Self.maxReadingAge else { return nil }

        guard let kind = Self.classify(settings, current, now: now) else {
            endEpisodeIfClear(settings, mgPerDl: current.mgPerDl)
            return nil
        }

        if episode != kind {
            episode = kind
            lastRaisedAt = nil
        }

        if now < snoozeEnd { return nil }

        let neverRaised = lastRaisedAt == nil
        var reminderDue = false
        if settings.repeatMinutes > 0, let last = lastRaisedAt {
            reminderDue = now.timeIntervalSince(last) >= TimeInterval(settings.repeatMinutes * 60)
        }

        if !neverRaised && !reminderDue { return nil }

        lastRaisedAt = now
        return AlertRaised(kind: kind, reading: current, isReminder: !neverRaised)
    }

    private func endEpisodeIfClear(_ settings: AlertSettings, mgPerDl: Double) {
        var clear = false
        switch episode {
        case .low: clear = mgPerDl >= settings.lowMgPerDl + Self.rearmMarginMgPerDl
        case .high: clear = mgPerDl <= settings.highMgPerDl - Self.rearmMarginMgPerDl
        case nil: clear = false
        }

        // Also clear when that alert has been switched off, otherwise a stale episode would linger.
        let disabled = (episode == .low && !settings.lowEnabled) || (episode == .high && !settings.highEnabled)

        if clear || disabled { reset() }
    }
}
