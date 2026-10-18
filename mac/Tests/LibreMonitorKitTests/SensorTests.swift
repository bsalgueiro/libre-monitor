import Foundation
import LibreMonitorKit
import XCTest

// Port of windows/tests/LibreMonitor.Core.Tests/SensorTests.cs

final class SensorTests: XCTestCase {
    private let activated = utc(2026, 10, 9, 13, 4)
    private var sensor: SensorInfo { SensorInfo(activatedAt: activated) }

    private func after(_ days: Double = 0, hours: Double = 0, minutes: Double = 0) -> Date {
        activated.addingTimeInterval(days * 86400 + hours * 3600 + minutes * 60)
    }

    func testEndsAtIsFourteenDaysAfterActivation() {
        XCTAssertEqual(SensorSchedule.endsAt(sensor), utc(2026, 10, 23, 13, 4))
    }

    func testRemainingCountsDownAndGoesNegativeAfterTheEnd() {
        XCTAssertEqual(SensorSchedule.remaining(sensor, now: after(8)), 6 * 86400)
        XCTAssertTrue(SensorSchedule.remaining(sensor, now: after(15)) < 0)
    }

    // ---- duration ----

    func testEndsAtUsesTheChosenDuration() {
        XCTAssertEqual(SensorSchedule.endsAt(sensor, durationDays: 15), after(15))
        XCTAssertEqual(SensorSchedule.endsAt(sensor, durationDays: 14), after(14))
    }

    func testAnUnknownDurationFallsBackToFourteenDays() {
        for days in [0, 13, 16, -5] {
            XCTAssertEqual(SensorSchedule.normalizeDurationDays(days), SensorSchedule.defaultDurationDays)
            XCTAssertEqual(SensorSchedule.endsAt(sensor, durationDays: days), after(14))
        }
    }

    func testTheChoicesIncludeTheDefaultAndOnlyHoldSensibleValues() {
        XCTAssertTrue(SensorSchedule.durationChoices.contains(SensorSchedule.defaultDurationDays))
        for days in SensorSchedule.durationChoices {
            XCTAssertTrue(days >= 10 && days <= 20)
        }
    }

    private let standard = SensorAlertSettings() // on, 1 day before, once a day

    private func check(
        _ e: SensorExpiryEvaluator, _ now: Date, _ settings: SensorAlertSettings? = nil, snoozedUntil: Date? = nil,
        durationDays: Int = 14, sensor other: SensorInfo? = nil) -> SensorEndingRaised?
    {
        e.evaluate(other ?? sensor, now: now, settings: settings ?? standard, snoozedUntil: snoozedUntil, durationDays: durationDays)
    }

    func testALongerDurationMovesTheNoticeLater() {
        let e = SensorExpiryEvaluator()

        XCTAssertNil(check(e, after(13), durationDays: 15))
        XCTAssertNotNil(check(e, after(14), durationDays: 15))
    }

    func testChangingTheDurationAllowsANewNotice() {
        let e = SensorExpiryEvaluator()
        XCTAssertNotNil(check(e, after(13), durationDays: 14))
        XCTAssertNil(check(e, after(13, hours: 1), durationDays: 14))

        // Switched to 15 days: that notice came a day early, so another is due when 15 days are nearly up.
        XCTAssertNil(check(e, after(13, hours: 2), durationDays: 15))
        XCTAssertNotNil(check(e, after(14), durationDays: 15))
    }

    // ---- alert settings ----

    func testDefaultsAreOnOneDayBeforeOnceADayAndValid() {
        XCTAssertTrue(standard.enabled)
        XCTAssertEqual(standard.daysBefore, 1)
        XCTAssertEqual(standard.repeatMinutes, 1440)
        XCTAssertNil(standard.validate())
    }

    func testDaysBeforeMustBeBetweenOneAndSeven() {
        for days in [0, 8, -1] { XCTAssertNotNil(SensorAlertSettings(daysBefore: days).validate()) }
        for days in [1, 7] { XCTAssertNil(SensorAlertSettings(daysBefore: days).validate()) }
    }

    func testRepeatMustBeOneOfTheChoices() {
        for minutes in [0, 30, 720] { XCTAssertNotNil(SensorAlertSettings(repeatMinutes: minutes).validate()) }
    }

    func testTheRepeatChoicesAreOnceADaySixHoursAndEveryHour() {
        XCTAssertEqual(SensorAlertSettings.repeatChoices, [1440, 360, 60])
    }

    // ---- notification ----

    func testNoNoticeWhileMoreThanTheLeadTimeRemains() {
        XCTAssertNil(check(SensorExpiryEvaluator(), after(8)))
        XCTAssertNil(check(SensorExpiryEvaluator(), after(13, minutes: -1)))
        XCTAssertNil(check(SensorExpiryEvaluator(), after(10, minutes: -1), SensorAlertSettings(daysBefore: 3)))
    }

    func testNoticeComesWhenTheLeadTimeIsReached() {
        let raised = check(SensorExpiryEvaluator(), after(13))
        XCTAssertEqual(raised?.endsAt, SensorSchedule.endsAt(sensor))
        XCTAssertEqual(raised?.isReminder, false)

        XCTAssertNotNil(check(SensorExpiryEvaluator(), after(11), SensorAlertSettings(daysBefore: 3)))
        XCTAssertNotNil(check(SensorExpiryEvaluator(), after(7), SensorAlertSettings(daysBefore: 7)))
    }

    func testOnceADayRepeatsEveryDayUntilTheEnd() {
        let e = SensorExpiryEvaluator()
        let threeDays = SensorAlertSettings(daysBefore: 3, repeatMinutes: 1440)

        XCTAssertEqual(check(e, after(11), threeDays)?.isReminder, false)
        XCTAssertNil(check(e, after(11, hours: 23), threeDays))
        XCTAssertEqual(check(e, after(12), threeDays)?.isReminder, true)
        XCTAssertEqual(check(e, after(13), threeDays)?.isReminder, true)
        XCTAssertNil(check(e, after(14), threeDays)) // the sensor has ended
    }

    func testEverySixHoursAndEveryHourRepeat() {
        let sixHours = SensorExpiryEvaluator()
        let six = SensorAlertSettings(daysBefore: 1, repeatMinutes: 360)
        XCTAssertNotNil(check(sixHours, after(13), six))
        XCTAssertNil(check(sixHours, after(13, hours: 5), six))
        XCTAssertNotNil(check(sixHours, after(13, hours: 6), six))
        XCTAssertNotNil(check(sixHours, after(13, hours: 12), six))

        let hourly = SensorExpiryEvaluator()
        let hour = SensorAlertSettings(daysBefore: 1, repeatMinutes: 60)
        XCTAssertNotNil(check(hourly, after(13), hour))
        XCTAssertNil(check(hourly, after(13, minutes: 30), hour))
        XCTAssertNotNil(check(hourly, after(13, hours: 1), hour))
        XCTAssertNotNil(check(hourly, after(13, hours: 2), hour))
    }

    func testNoNoticeOnceTheSensorHasEnded() {
        XCTAssertNil(check(SensorExpiryEvaluator(), after(14)))
        XCTAssertNil(check(SensorExpiryEvaluator(), after(16)))
    }

    func testNoNoticeWithoutASensor() {
        XCTAssertNil(SensorExpiryEvaluator().evaluate(nil, now: after(13), settings: standard))
    }

    func testNoNoticeWhenTurnedOffAndTurningItOnStartsFresh() {
        let e = SensorExpiryEvaluator()

        XCTAssertNil(check(e, after(13), SensorAlertSettings(enabled: false)))
        XCTAssertEqual(check(e, after(13, hours: 1))?.isReminder, false)
    }

    func testANewSensorGetsItsOwnNotices() {
        let e = SensorExpiryEvaluator()
        XCTAssertNotNil(check(e, after(13)))

        let next = SensorInfo(activatedAt: after(14))

        XCTAssertNil(check(e, after(20), sensor: next))
        XCTAssertEqual(check(e, after(27), sensor: next)?.isReminder, false)
    }

    func testSnoozeHoldsTheNoticeThenRaisesItWhenItEnds() {
        let e = SensorExpiryEvaluator()
        let until = after(13, hours: 2)

        XCTAssertNil(check(e, after(13), snoozedUntil: until))
        XCTAssertNil(check(e, after(13, hours: 1), snoozedUntil: until))

        let raised = check(e, until, snoozedUntil: until)
        XCTAssertNotNil(raised)
        XCTAssertEqual(raised?.isReminder, false)
    }

    func testAPauseWithoutAnEndHoldsTheNoticeIndefinitely() {
        let e = SensorExpiryEvaluator()

        XCTAssertNil(check(e, after(13), snoozedUntil: .distantFuture))
        XCTAssertNil(check(e, after(13, hours: 20), snoozedUntil: .distantFuture))
        XCTAssertNotNil(check(e, after(13, hours: 21)))
    }

    func testResetStartsAFreshEpisode() {
        let e = SensorExpiryEvaluator()
        XCTAssertNotNil(check(e, after(13)))

        e.reset()

        XCTAssertEqual(check(e, after(13, minutes: 1))?.isReminder, false)
    }
}
