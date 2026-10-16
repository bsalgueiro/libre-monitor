import Foundation
import LibreMonitorKit
import XCTest

// Port of windows/tests/LibreMonitor.Core.Tests/InsulinTests.cs

final class InsulinTests: XCTestCase {
    private static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let cal = InsulinTests.utc

    // 2026-10-14 is a Wednesday; UTC is used so the clock times in the tests are the local times.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var parts = DateComponents()
        parts.year = 2026; parts.month = 10; parts.day = day; parts.hour = hour; parts.minute = minute
        return cal.date(from: parts)!
    }

    private let once = InsulinSettings(enabled: true, dosesPerDay: 1, firstDoseMinutes: 8 * 60, repeatMinutes: 30)
    private let twice = InsulinSettings(
        enabled: true, dosesPerDay: 2, firstDoseMinutes: 8 * 60, secondDoseMinutes: 20 * 60, repeatMinutes: 30)

    private func state(_ s: InsulinSettings, _ now: Date) -> DoseState {
        InsulinSchedule.status(s, now: now, calendar: cal).state
    }

    // ---- status ------------------------------------------------------------------------------

    func testBeforeThePeriodOpensTheEarlierDoseIsStillTheCurrentOne() {
        let status = InsulinSchedule.status(once, now: at(14, 5), calendar: cal)

        XCTAssertEqual(status.state, .due)
        XCTAssertEqual(status.slot, at(13, 8))
    }

    func testWhenThePeriodOpensTheStatusIsUpcoming() {
        XCTAssertEqual(state(once, at(14, 6)), .upcoming)
        XCTAssertEqual(state(once, at(14, 7, 59)), .upcoming)
    }

    func testAtTheDoseTimeTheStatusIsDue() {
        XCTAssertEqual(state(once, at(14, 8)), .due)
        XCTAssertEqual(state(once, at(14, 15)), .due)
    }

    func testMarkedDoseIsTakenUntilTheNextPeriodOpens() {
        let taken = once.markingTaken(at: at(14, 8, 12))

        let status = InsulinSchedule.status(taken, now: at(14, 8, 13), calendar: cal)
        XCTAssertEqual(status.state, .taken)
        XCTAssertEqual(status.takenAt, at(14, 8, 12))
        XCTAssertEqual(state(taken, at(14, 23, 59)), .taken)
        XCTAssertEqual(state(taken, at(15, 5, 59)), .taken)
        XCTAssertEqual(state(taken, at(15, 6)), .upcoming)
        XCTAssertEqual(state(taken, at(15, 8)), .due)
    }

    func testATapBeforeTheDoseTimeCountsForThatDose() {
        let taken = once.markingTaken(at: at(14, 6, 30))

        XCTAssertEqual(state(taken, at(14, 6, 31)), .taken)
        XCTAssertEqual(state(taken, at(14, 8, 30)), .taken)
        XCTAssertEqual(state(taken, at(15, 6)), .upcoming)
    }

    func testATapForYesterdaysDoseDoesNotCountForToday() {
        XCTAssertEqual(state(once.markingTaken(at: at(13, 8, 5)), at(14, 8)), .due)
    }

    func testUndoRemovesTheMark() {
        let taken = once.markingTaken(at: at(14, 8, 5))

        XCTAssertEqual(state(taken.undone(), at(14, 9)), .due)
        XCTAssertNil(taken.undone().lastTakenAt)
    }

    func testATimestampInTheFutureIsNotTaken() {
        XCTAssertEqual(state(once.markingTaken(at: at(20, 8)), at(14, 9)), .due)
    }

    func testTwiceHasTwoPeriodsADay() {
        let morning = twice.markingTaken(at: at(14, 8, 10))

        XCTAssertEqual(state(morning, at(14, 9)), .taken)
        XCTAssertEqual(state(morning, at(14, 17, 59)), .taken)
        XCTAssertEqual(state(morning, at(14, 18)), .upcoming)
        XCTAssertEqual(state(morning, at(14, 20)), .due)
        XCTAssertEqual(state(morning.markingTaken(at: at(14, 20, 5)), at(14, 21)), .taken)
        XCTAssertEqual(state(morning.markingTaken(at: at(14, 20, 5)), at(15, 6)), .upcoming)
    }

    func testTwiceMorningTapDoesNotCoverTheEvening() {
        XCTAssertEqual(state(twice.markingTaken(at: at(14, 8, 10)), at(14, 20, 1)), .due)
    }

    func testADoseNearMidnightWrapsCorrectly() {
        let late = InsulinSettings(enabled: true, dosesPerDay: 1, firstDoseMinutes: 23 * 60 + 30)
        let taken = late.markingTaken(at: at(14, 23, 40))

        XCTAssertEqual(state(taken, at(15, 1)), .taken)
        XCTAssertEqual(state(taken, at(15, 21, 30)), .upcoming)
        XCTAssertEqual(state(taken, at(15, 23, 30)), .due)
    }

    func testADoseJustAfterMidnightCountsAnEveningTapAsEarly() {
        let early = InsulinSettings(enabled: true, dosesPerDay: 1, firstDoseMinutes: 30)

        XCTAssertEqual(state(early.markingTaken(at: at(14, 23, 0)), at(15, 0, 40)), .taken)
    }

    func testTheCalendarZoneDecidesWhatLocalTimeMeans() {
        var plus3 = Calendar(identifier: .gregorian)
        plus3.timeZone = TimeZone(secondsFromGMT: 3 * 3600)!

        let status = InsulinSchedule.status(once, now: at(14, 5, 30), calendar: plus3)
        XCTAssertEqual(status.state, .due)
        XCTAssertEqual(status.slot, at(14, 5))
    }

    // ---- validation --------------------------------------------------------------------------

    func testDefaultsAreValidAndOff() {
        let defaults = InsulinSettings()

        XCTAssertFalse(defaults.enabled)
        XCTAssertNil(defaults.validate())
        XCTAssertNil(defaults.lastTakenAt)
    }

    func testDosesPerDayMustBeOneOrTwo() {
        XCTAssertNotNil(InsulinSettings(dosesPerDay: 0).validate())
        XCTAssertNotNil(InsulinSettings(dosesPerDay: 3).validate())
    }

    func testTimesMustBeInsideTheDay() {
        XCTAssertNotNil(InsulinSettings(firstDoseMinutes: -1).validate())
        XCTAssertNotNil(InsulinSettings(firstDoseMinutes: 1440).validate())
    }

    func testTwoDosesMustBeFarEnoughApart() {
        XCTAssertNotNil(InsulinSettings(dosesPerDay: 2, firstDoseMinutes: 8 * 60, secondDoseMinutes: 10 * 60).validate())
        XCTAssertNotNil(InsulinSettings(dosesPerDay: 2, firstDoseMinutes: 60, secondDoseMinutes: 23 * 60).validate())
        XCTAssertNil(InsulinSettings(dosesPerDay: 2, firstDoseMinutes: 8 * 60, secondDoseMinutes: 12 * 60).validate())
    }

    func testTheSecondTimeIsIgnoredForASingleDose() {
        XCTAssertNil(InsulinSettings(dosesPerDay: 1, firstDoseMinutes: 8 * 60, secondDoseMinutes: 8 * 60).validate())
    }

    func testRepeatIntervalMustBeInRange() {
        XCTAssertNotNil(InsulinSettings(repeatMinutes: -1).validate())
        XCTAssertNotNil(InsulinSettings(repeatMinutes: AlertSettings.maxRepeatMinutes + 1).validate())
    }

    // ---- reminders ---------------------------------------------------------------------------

    private func step(_ e: InsulinReminderEvaluator, _ s: InsulinSettings, _ now: Date, snoozedUntil: Date? = nil)
        -> InsulinReminderRaised?
    {
        e.evaluate(s, now: now, calendar: cal, snoozedUntil: snoozedUntil)
    }

    func testNothingIsRaisedBeforeTheDoseTime() {
        XCTAssertNil(step(InsulinReminderEvaluator(), once, at(14, 7, 59)))
    }

    func testDisabledNeverRaises() {
        var off = once
        off.enabled = false
        XCTAssertNil(step(InsulinReminderEvaluator(), off, at(14, 8)))
    }

    func testRaisesAtTheDoseTimeThenRepeats() {
        let e = InsulinReminderEvaluator()

        let first = step(e, once, at(14, 8))
        XCTAssertEqual(first?.isReminder, false)
        XCTAssertEqual(first?.slot, at(14, 8))
        XCTAssertNil(step(e, once, at(14, 8, 29)))

        XCTAssertEqual(step(e, once, at(14, 8, 30))?.isReminder, true)
        XCTAssertNil(step(e, once, at(14, 8, 45)))
        XCTAssertNotNil(step(e, once, at(14, 9)))
    }

    func testMarkingTheDoseStopsRemindersAndAllowsTheNextDose() {
        let e = InsulinReminderEvaluator()
        XCTAssertNotNil(step(e, once, at(14, 8)))

        let taken = once.markingTaken(at: at(14, 8, 10))
        XCTAssertNil(step(e, taken, at(14, 8, 30)))
        XCTAssertNil(step(e, taken, at(15, 7)))
        XCTAssertNotNil(step(e, taken, at(15, 8)))
    }

    func testRepeatZeroRemindsOnlyOnce() {
        let e = InsulinReminderEvaluator()
        var single = once
        single.repeatMinutes = 0

        XCTAssertNotNil(step(e, single, at(14, 8)))
        XCTAssertNil(step(e, single, at(14, 9)))
        XCTAssertNil(step(e, single, at(14, 12)))
    }

    func testRemindersStopAfterTheReminderWindowButTheDoseStaysDue() {
        let e = InsulinReminderEvaluator()
        XCTAssertNotNil(step(e, once, at(14, 8)))
        XCTAssertNotNil(step(e, once, at(14, 13, 30)))

        XCTAssertNil(step(e, once, at(14, 14, 1)))
        XCTAssertNil(step(e, once, at(14, 23)))
        XCTAssertNil(step(e, once, at(15, 3)))
        XCTAssertEqual(state(once, at(15, 3)), .due)
    }

    func testALateStartInsideTheWindowRaisesImmediatelyOutsideItDoesNot() {
        XCTAssertNotNil(step(InsulinReminderEvaluator(), once, at(14, 10)))
        XCTAssertNil(step(InsulinReminderEvaluator(), once, at(14, 20)))
    }

    func testSnoozeHoldsTheReminderThenRaisesWhenItEnds() {
        let e = InsulinReminderEvaluator()
        let until = at(14, 9)

        XCTAssertNil(step(e, once, at(14, 8), snoozedUntil: until))
        XCTAssertNil(step(e, once, at(14, 8, 59), snoozedUntil: until))

        let raised = step(e, once, at(14, 9), snoozedUntil: until)
        XCTAssertNotNil(raised)
        XCTAssertEqual(raised?.isReminder, false)
    }

    func testTwiceEachDoseIsItsOwnEpisode() {
        let e = InsulinReminderEvaluator()
        XCTAssertNotNil(step(e, twice, at(14, 8)))
        let morningTaken = twice.markingTaken(at: at(14, 8, 5))
        XCTAssertNil(step(e, morningTaken, at(14, 12)))

        let evening = step(e, morningTaken, at(14, 20))
        XCTAssertEqual(evening?.isReminder, false)
        XCTAssertEqual(evening?.slot, at(14, 20))
    }

    func testResetStartsAFreshEpisode() {
        let e = InsulinReminderEvaluator()
        XCTAssertNotNil(step(e, once, at(14, 8)))

        e.reset()

        XCTAssertEqual(step(e, once, at(14, 8, 1))?.isReminder, false)
    }
}
