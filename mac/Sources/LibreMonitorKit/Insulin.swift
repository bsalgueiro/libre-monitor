import Foundation

// Port of windows/src/LibreMonitor.Core/Insulin.cs

/// Where one daily insulin dose stands. Only a memory aid: the app cannot know about doses that were not tapped.
public enum DoseState: Sendable, Equatable {
    /// The next dose is not due yet and nothing has been marked for it.
    case upcoming
    /// The dose time has passed and the dose has not been marked as taken.
    case due
    /// The user marked this dose as taken.
    case taken
}

/// Settings for the daily insulin reminder, plus the time the user last marked a dose as taken.
/// That one timestamp is all that is kept: no amounts and no history. The reminder is off by default.
public struct InsulinSettings: Codable, Equatable, Sendable {
    /// With two doses a day, the two times must be at least this far apart (both ways round the clock).
    public static let minGapMinutes = 4 * 60

    public var enabled: Bool
    /// 1 or 2.
    public var dosesPerDay: Int
    /// Minutes after local midnight.
    public var firstDoseMinutes: Int
    /// Minutes after local midnight; only used when `dosesPerDay` is 2.
    public var secondDoseMinutes: Int
    /// Reminder interval while the dose is still not marked; 0 means remind once.
    public var repeatMinutes: Int
    /// When the user last tapped "taken"; nil if never or undone.
    public var lastTakenAt: Date?

    public init(
        enabled: Bool = false,
        dosesPerDay: Int = 1,
        firstDoseMinutes: Int = 8 * 60,
        secondDoseMinutes: Int = 20 * 60,
        repeatMinutes: Int = 30,
        lastTakenAt: Date? = nil)
    {
        self.enabled = enabled
        self.dosesPerDay = dosesPerDay
        self.firstDoseMinutes = firstDoseMinutes
        self.secondDoseMinutes = secondDoseMinutes
        self.repeatMinutes = repeatMinutes
        self.lastTakenAt = lastTakenAt
    }

    /// The dose times, earliest first.
    public var doseMinutes: [Int] {
        dosesPerDay == 2 ? [firstDoseMinutes, secondDoseMinutes].sorted() : [firstDoseMinutes]
    }

    /// - Returns: a message describing the first problem, or nil when the settings are usable.
    public func validate() -> String? {
        if dosesPerDay != 1 && dosesPerDay != 2 { return "Choose one or two doses a day." }

        if firstDoseMinutes < 0 || firstDoseMinutes >= 1440 || secondDoseMinutes < 0 || secondDoseMinutes >= 1440 {
            return "Enter a valid time for each dose."
        }

        if dosesPerDay == 2 {
            let gap = abs(firstDoseMinutes - secondDoseMinutes)
            if gap < Self.minGapMinutes || 1440 - gap < Self.minGapMinutes {
                return "The two dose times must be at least \(Self.minGapMinutes / 60) hours apart."
            }
        }

        if repeatMinutes < 0 || repeatMinutes > AlertSettings.maxRepeatMinutes {
            return "The repeat interval must be between 0 and \(AlertSettings.maxRepeatMinutes) minutes."
        }

        return nil
    }

    /// The same settings with the current dose marked as taken now.
    public func markingTaken(at now: Date) -> InsulinSettings {
        var copy = self
        copy.lastTakenAt = now
        return copy
    }

    /// The same settings with the "taken" mark removed (for a tap by mistake).
    public func undone() -> InsulinSettings {
        var copy = self
        copy.lastTakenAt = nil
        return copy
    }
}

/// Where the current dose stands.
public struct DoseStatus: Equatable, Sendable {
    public let state: DoseState
    /// The scheduled time of the dose this status is about.
    public let slot: Date
    /// When it was marked taken; only set when `state` is `.taken`.
    public let takenAt: Date?

    public init(state: DoseState, slot: Date, takenAt: Date?) {
        self.state = state
        self.slot = slot
        self.takenAt = takenAt
    }
}

/// Works out which dose a moment belongs to. Pure logic with no UI or clock of its own, so every rule can be tested.
///
/// A dose "period" starts `earlyWindow` before the scheduled time and ends `earlyWindow` before the next scheduled
/// time. A tap counts for the period it falls in, so tapping a little early still counts for that dose, and the status
/// goes back to `.upcoming` when the next period opens.
public enum InsulinSchedule {
    public static let earlyWindow: TimeInterval = 2 * 3600

    /// - Returns: the scheduled time of the dose whose period contains `moment`.
    public static func slot(for settings: InsulinSettings, at moment: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: moment)
        let limit = moment.addingTimeInterval(earlyWindow)
        var best: Date?

        for offset in -1...1 {
            guard let date = calendar.date(byAdding: .day, value: offset, to: day) else { continue }
            for minutes in settings.doseMinutes {
                let slot = slotAt(date, minutes: minutes, calendar: calendar)
                if slot <= limit && (best == nil || slot > best!) { best = slot }
            }
        }

        // The previous day always has a slot at or before the limit, so the fallback is never used.
        return best ?? day
    }

    public static func status(_ settings: InsulinSettings, now: Date, calendar: Calendar) -> DoseStatus {
        let slot = slot(for: settings, at: now, calendar: calendar)

        if let taken = settings.lastTakenAt, self.slot(for: settings, at: taken, calendar: calendar) == slot {
            return DoseStatus(state: .taken, slot: slot, takenAt: taken)
        }

        return DoseStatus(state: now >= slot ? .due : .upcoming, slot: slot, takenAt: nil)
    }

    /// The wall-clock time on that day. A time the clocks skip (spring forward) lands after the gap.
    private static func slotAt(_ day: Date, minutes: Int, calendar: Calendar) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = minutes / 60
        parts.minute = minutes % 60
        parts.second = 0
        return calendar.date(from: parts) ?? day.addingTimeInterval(TimeInterval(minutes * 60))
    }
}

/// A dose reminder that should be delivered now.
public struct InsulinReminderRaised: Equatable, Sendable {
    public let slot: Date
    public let isReminder: Bool

    public init(slot: Date, isReminder: Bool) {
        self.slot = slot
        self.isReminder = isReminder
    }
}

/// Decides when to remind about a dose that is due and not marked as taken. One instance follows one schedule.
/// Reminders repeat at the chosen interval until the dose is marked or `reminderWindow` has passed.
/// The dose still shows as due after that, but the app stops notifying (no night-time reminders for a missed dose).
public final class InsulinReminderEvaluator {
    /// How long after the scheduled time reminders keep coming.
    public static let reminderWindow: TimeInterval = 6 * 3600

    private var episodeSlot: Date?
    private var lastRaisedAt: Date?

    public init() {}

    /// Forget the current episode, for example after the schedule changes.
    public func reset() {
        episodeSlot = nil
        lastRaisedAt = nil
    }

    /// - Parameter snoozedUntil: the shared alert snooze, if one is active; a snoozed reminder is raised once the snooze ends.
    /// - Returns: the reminder to deliver, or nil when nothing is due.
    public func evaluate(
        _ settings: InsulinSettings, now: Date, calendar: Calendar, snoozedUntil: Date? = nil) -> InsulinReminderRaised?
    {
        guard settings.enabled else {
            reset()
            return nil
        }

        let status = InsulinSchedule.status(settings, now: now, calendar: calendar)
        guard status.state == .due else {
            reset()
            return nil
        }

        if episodeSlot != status.slot {
            episodeSlot = status.slot
            lastRaisedAt = nil
        }

        if now.timeIntervalSince(status.slot) > Self.reminderWindow { return nil }
        if let until = snoozedUntil, now < until { return nil }

        let neverRaised = lastRaisedAt == nil
        var reminderDue = false
        if settings.repeatMinutes > 0, let last = lastRaisedAt {
            reminderDue = now.timeIntervalSince(last) >= TimeInterval(settings.repeatMinutes * 60)
        }

        if !neverRaised && !reminderDue { return nil }

        lastRaisedAt = now
        return InsulinReminderRaised(slot: status.slot, isReminder: !neverRaised)
    }
}
