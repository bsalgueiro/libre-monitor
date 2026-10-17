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

    // ---- notification ----

    func testNoNoticeWhileMoreThanADayRemains() {
        XCTAssertNil(SensorExpiryEvaluator().evaluate(sensor, now: after(8)))
        XCTAssertNil(SensorExpiryEvaluator().evaluate(sensor, now: after(13, minutes: -1)))
    }

    func testNoticeComesOnceWhenADayOrLessRemains() {
        let e = SensorExpiryEvaluator()

        let raised = e.evaluate(sensor, now: after(13))

        XCTAssertEqual(raised?.endsAt, SensorSchedule.endsAt(sensor))
        XCTAssertNil(e.evaluate(sensor, now: after(13, hours: 2)))
        XCTAssertNil(e.evaluate(sensor, now: after(13, hours: 20)))
    }

    func testNoNoticeOnceTheSensorHasEnded() {
        XCTAssertNil(SensorExpiryEvaluator().evaluate(sensor, now: after(14)))
        XCTAssertNil(SensorExpiryEvaluator().evaluate(sensor, now: after(16)))
    }

    func testNoNoticeWithoutASensor() {
        XCTAssertNil(SensorExpiryEvaluator().evaluate(nil, now: after(13)))
    }

    func testANewSensorGetsItsOwnNotice() {
        let e = SensorExpiryEvaluator()
        XCTAssertNotNil(e.evaluate(sensor, now: after(13)))

        let next = SensorInfo(activatedAt: after(14))

        XCTAssertNil(e.evaluate(next, now: after(20)))
        XCTAssertNotNil(e.evaluate(next, now: after(27)))
    }

    func testSnoozeHoldsTheNoticeThenRaisesItWhenItEnds() {
        let e = SensorExpiryEvaluator()
        let until = after(13, hours: 2)

        XCTAssertNil(e.evaluate(sensor, now: after(13), snoozedUntil: until))
        XCTAssertNil(e.evaluate(sensor, now: after(13, hours: 1), snoozedUntil: until))
        XCTAssertNotNil(e.evaluate(sensor, now: until, snoozedUntil: until))
    }
}
