import Foundation
import LibreMonitorKit
import XCTest

// Port of tests/LibreMonitor.Core.Tests/AlertTests.cs (37 cases)

final class AlertTests: XCTestCase {
    private let t0 = utc(2026, 10, 14, 12, 0, 0)
    private let both = AlertSettings(lowEnabled: true, highEnabled: true, repeatMinutes: 30)

    private func reading(_ mgPerDl: Double, at: Date) -> GlucoseReading {
        GlucoseReading(
            timestamp: at, mgPerDl: mgPerDl, value: mgPerDl, trend: .stable,
            isHigh: mgPerDl > 180, isLow: mgPerDl < 70)
    }

    private func minute(_ m: Int) -> Date { t0.addingTimeInterval(TimeInterval(m * 60)) }

    /// Evaluate a fresh reading taken at the given minute.
    private func step(_ e: AlertEvaluator, _ s: AlertSettings, _ mgPerDl: Double, _ m: Int) -> AlertRaised? {
        e.evaluate(s, reading(mgPerDl, at: minute(m)), now: minute(m))
    }

    // MARK: raising

    func testInRangeRaisesNothing() {
        XCTAssertNil(step(AlertEvaluator(), both, 100, 0))
    }

    func testLowRaisesOnceOnEntry() throws {
        let e = AlertEvaluator()

        let raised = try XCTUnwrap(step(e, both, 65, 0))

        XCTAssertEqual(raised.kind, .low)
        XCTAssertFalse(raised.isReminder)
        XCTAssertEqual(raised.reading.mgPerDl, 65)
        XCTAssertNil(step(e, both, 64, 1))
        XCTAssertNil(step(e, both, 63, 2))
    }

    func testHighRaisesOnceOnEntry() throws {
        let e = AlertEvaluator()

        XCTAssertEqual(try XCTUnwrap(step(e, both, 200, 0)).kind, .high)
        XCTAssertNil(step(e, both, 210, 1))
    }

    func testThresholdsAreStrictSoTheValueOnTheLineIsInRange() {
        let e = AlertEvaluator()

        XCTAssertNil(step(e, both, 70, 0))
        XCTAssertNil(step(e, both, 180, 1))
        XCTAssertNotNil(step(e, both, 69, 2))
    }

    func testDisabledKindsNeverRaise() {
        let onlyHigh = AlertSettings(lowEnabled: false, highEnabled: true)

        XCTAssertNil(step(AlertEvaluator(), onlyHigh, 40, 0))
        XCTAssertNotNil(step(AlertEvaluator(), onlyHigh, 250, 0))
    }

    func testCustomThresholdsAreUsed() throws {
        let strict = AlertSettings(lowEnabled: true, lowMgPerDl: 90, highEnabled: true, highMgPerDl: 140)

        XCTAssertEqual(try XCTUnwrap(step(AlertEvaluator(), strict, 85, 0)).kind, .low)
        XCTAssertEqual(try XCTUnwrap(step(AlertEvaluator(), strict, 150, 0)).kind, .high)
        XCTAssertNil(step(AlertEvaluator(), strict, 100, 0))
    }

    // MARK: reminders

    func testStillOutOfRangeRemindsAfterTheIntervalThenKeepsReminding() throws {
        let e = AlertEvaluator()
        _ = step(e, both, 60, 0)

        XCTAssertNil(step(e, both, 60, 29))
        let reminder = try XCTUnwrap(step(e, both, 60, 30))
        XCTAssertTrue(reminder.isReminder)
        XCTAssertNil(step(e, both, 60, 59))
        XCTAssertNotNil(step(e, both, 60, 60))
    }

    func testRepeatZeroAlertsOncePerEpisode() {
        var once = both
        once.repeatMinutes = 0
        let e = AlertEvaluator()
        XCTAssertNotNil(step(e, once, 60, 0))

        XCTAssertNil(step(e, once, 60, 30))
        XCTAssertNil(step(e, once, 60, 600))
    }

    // MARK: episodes and flapping

    func testBackInRangeThenOutAgainIsANewEpisode() throws {
        let e = AlertEvaluator()
        XCTAssertNotNil(step(e, both, 65, 0))

        XCTAssertNil(step(e, both, 100, 5)) // recovered, well clear of the line
        let again = try XCTUnwrap(step(e, both, 65, 10))

        XCTAssertFalse(again.isReminder)
    }

    func testHoveringOnTheLineDoesNotAlertEveryCrossing() {
        let e = AlertEvaluator()
        XCTAssertNotNil(step(e, both, 69, 0))

        XCTAssertNil(step(e, both, 71, 1)) // back over the line but inside the 5 mg/dL margin
        XCTAssertNil(step(e, both, 69, 2)) // same episode, so no new alert
        XCTAssertNil(step(e, both, 71, 3))
        XCTAssertNil(step(e, both, 69, 4))
    }

    func testClearingTheMarginReArms() {
        let e = AlertEvaluator()
        _ = step(e, both, 69, 0)

        _ = step(e, both, 75, 1) // exactly threshold + margin counts as clear
        XCTAssertNotNil(step(e, both, 69, 2))
    }

    func testHighReArmsBelowTheThresholdByTheMargin() {
        let e = AlertEvaluator()
        _ = step(e, both, 190, 0)

        XCTAssertNil(step(e, both, 178, 1)) // in range but within the margin
        XCTAssertNil(step(e, both, 190, 2))
        _ = step(e, both, 175, 3)
        XCTAssertNotNil(step(e, both, 190, 4))
    }

    func testSwitchingFromHighToLowRaisesTheNewKind() throws {
        let e = AlertEvaluator()
        _ = step(e, both, 200, 0)

        let raised = try XCTUnwrap(step(e, both, 60, 5))

        XCTAssertEqual(raised.kind, .low)
        XCTAssertFalse(raised.isReminder)
    }

    // MARK: old data

    func testOldReadingIsIgnored() {
        let e = AlertEvaluator()

        XCTAssertNil(e.evaluate(both, reading(55, at: t0), now: minute(11)))
    }

    func testOldReadingDoesNotEndAnEpisode() {
        let e = AlertEvaluator()
        _ = step(e, both, 60, 0)

        _ = e.evaluate(both, reading(110, at: minute(1)), now: minute(20)) // far too old to trust
        XCTAssertNil(step(e, both, 60, 21)) // still the same episode: no fresh alert
    }

    func testNoReadingRaisesNothing() {
        XCTAssertNil(AlertEvaluator().evaluate(both, nil, now: t0))
    }

    // MARK: snooze

    func testSnoozeSuppressesAlertsThenRaisesIfStillOut() throws {
        let e = AlertEvaluator()
        e.snooze(until: minute(30))

        XCTAssertNil(step(e, both, 60, 0))
        XCTAssertNil(step(e, both, 60, 29))
        let raised = try XCTUnwrap(step(e, both, 60, 31))

        XCTAssertFalse(raised.isReminder) // the episode was never announced, so it is not a reminder
    }

    func testSnoozeThatEndsAfterRecoveryRaisesNothing() {
        let e = AlertEvaluator()
        e.snooze(until: minute(30))
        _ = step(e, both, 60, 0)
        _ = step(e, both, 100, 10)

        XCTAssertNil(step(e, both, 100, 31))
    }

    func testResumeCancelsASnooze() {
        let e = AlertEvaluator()
        e.snooze(until: t0.addingTimeInterval(2 * 3600))
        e.resume()

        XCTAssertNotNil(step(e, both, 60, 0))
        XCTAssertNil(e.snoozedUntil(now: t0))
    }

    func testSnoozedUntilReportsOnlyWhileActive() {
        let e = AlertEvaluator()
        e.snooze(until: minute(30))

        XCTAssertEqual(e.snoozedUntil(now: minute(10)), minute(30))
        XCTAssertNil(e.snoozedUntil(now: minute(31)))
    }

    // MARK: settings changes

    func testResetStartsAFreshEpisode() {
        let e = AlertEvaluator()
        _ = step(e, both, 60, 0)
        e.reset()

        XCTAssertNotNil(step(e, both, 60, 1))
    }

    func testTurningTheAlertOffEndsItsEpisode() {
        let e = AlertEvaluator()
        _ = step(e, both, 60, 0)

        var off = both
        off.lowEnabled = false
        XCTAssertNil(step(e, off, 60, 1))
        XCTAssertNotNil(step(e, both, 60, 2)) // turned back on: counts as new
    }

    // MARK: classification (drives the widget highlight)

    func testClassifyIgnoresHistoryAndSnooze() {
        let cases: [(Double, AlertKind?)] = [(65, .low), (100, nil), (200, .high)]
        for (mgPerDl, expected) in cases {
            let e = AlertEvaluator()
            e.snooze(until: t0.addingTimeInterval(3600))

            XCTAssertEqual(AlertEvaluator.classify(both, reading(mgPerDl, at: t0), now: t0), expected, "\(mgPerDl)")
        }
    }

    func testClassifyOldReadingIsNil() {
        XCTAssertNil(AlertEvaluator.classify(both, reading(50, at: t0), now: minute(11)))
    }

    // MARK: validation

    func testDefaultsAreOffAndValid() {
        let defaults = AlertSettings()

        XCTAssertFalse(defaults.lowEnabled)
        XCTAssertFalse(defaults.highEnabled)
        XCTAssertEqual(defaults.lowMgPerDl, 70)
        XCTAssertEqual(defaults.highMgPerDl, 180)
        XCTAssertNil(defaults.validate())
    }

    func testValidateRejectsUnusableSettings() {
        let cases: [(low: Double, high: Double, repeatMinutes: Int, why: String)] = [
            (30, 180, 30, "low too small"),
            (160, 180, 30, "low too large"),
            (70, 90, 30, "high too small"),
            (70, 450, 30, "high too large"),
            (150, 120, 30, "low above high"),
            (70, 180, -1, "negative repeat"),
            (70, 180, 241, "repeat too long"),
        ]
        for c in cases {
            let settings = AlertSettings(lowMgPerDl: c.low, highMgPerDl: c.high, repeatMinutes: c.repeatMinutes)
            XCTAssertNotNil(settings.validate(), c.why)
        }
    }

    func testValidateAcceptsTheLimits() {
        let cases: [(Double, Double, Int)] = [(40, 400, 0), (150, 151, 240), (70, 180, 30)]
        for (low, high, repeatMinutes) in cases {
            let settings = AlertSettings(lowMgPerDl: low, highMgPerDl: high, repeatMinutes: repeatMinutes)
            XCTAssertNil(settings.validate(), "\(low) \(high) \(repeatMinutes)")
        }
    }

    func testValidationMessagesUseTheEditingUnit() throws {
        let tooLow = AlertSettings(lowMgPerDl: 30)

        let mg = try XCTUnwrap(tooLow.validate(unit: .mgPerDl, locale: Locale(identifier: "en_US_POSIX")))
        let mmol = try XCTUnwrap(tooLow.validate(unit: .mmolPerL, locale: Locale(identifier: "en_US_POSIX")))

        XCTAssertTrue(mg.contains("mg/dL"))
        XCTAssertTrue(mmol.contains("mmol/L"))
        XCTAssertTrue(mmol.contains("2.2")) // 40 mg/dL
    }
}
