import Foundation
import LibreMonitorKit
import XCTest

// Port of windows/tests/LibreMonitor.Core.Tests/GraphWindowTests.cs

final class GraphWindowTests: XCTestCase {
    private let start = utc(2026, 10, 18, 6, 0)
    private let gap: TimeInterval = 40 * 60

    private func r(_ minutesFromStart: Double, _ mgPerDl: Double) -> GlucoseReading {
        GlucoseReading(
            timestamp: start.addingTimeInterval(minutesFromStart * 60), mgPerDl: mgPerDl, value: mgPerDl, trend: .stable,
            isHigh: mgPerDl > 180, isLow: mgPerDl < 70)
    }

    func testNothingOlderThanTheWindowIsReturnedAsItIs() {
        let readings = [r(5, 100), r(20, 110), r(35, 120)]

        XCTAssertEqual(GraphWindow.clipToWindow(readings, start: start, maxGap: gap), readings)
    }

    func testAReadingJustBeforeTheWindowIsReplacedByTheValueAtTheEdge() {
        // 100 at 15 minutes before, 130 at 15 minutes after: halfway between them at the edge.
        let clipped = GraphWindow.clipToWindow([r(-15, 100), r(15, 130), r(30, 140)], start: start, maxGap: gap)

        XCTAssertEqual(clipped.count, 3)
        XCTAssertEqual(clipped[0].timestamp, start)
        XCTAssertEqual(clipped[0].mgPerDl, 115, accuracy: 0.000001)
        XCTAssertEqual(clipped[1].mgPerDl, 130)
    }

    func testTheEdgeValueIsInterpolatedByTimeNotAveraged() {
        // The edge is a third of the way from the older reading to the newer one.
        let clipped = GraphWindow.clipToWindow([r(-10, 100), r(20, 190)], start: start, maxGap: gap)

        XCTAssertEqual(clipped[0].mgPerDl, 130, accuracy: 0.000001)
    }

    func testAReadingExactlyAtTheEdgeNeedsNoInterpolation() {
        let clipped = GraphWindow.clipToWindow([r(-15, 100), r(0, 120), r(15, 130)], start: start, maxGap: gap)

        XCTAssertEqual(clipped.count, 2)
        XCTAssertEqual(clipped[0].mgPerDl, 120)
        XCTAssertEqual(clipped[0].timestamp, start)
    }

    func testOnlyTheNearestOlderReadingMatters() {
        let clipped = GraphWindow.clipToWindow([r(-45, 60), r(-30, 80), r(10, 120)], start: start, maxGap: gap)

        // Between the reading 30 minutes before (80) and the one 10 minutes after (120): 30 of 40 minutes in.
        XCTAssertEqual(clipped[0].mgPerDl, 110, accuracy: 0.000001)
        XCTAssertEqual(clipped.count, 2)
    }

    func testARealGapAtTheEdgeStartsTheLineAtTheFirstReadingInside() {
        let clipped = GraphWindow.clipToWindow([r(-50, 100), r(10, 130), r(25, 135)], start: start, maxGap: gap)

        XCTAssertEqual(clipped.count, 2)
        XCTAssertEqual(clipped[0].mgPerDl, 130)
    }

    func testEverythingOlderThanTheWindowGivesNoLine() {
        XCTAssertTrue(GraphWindow.clipToWindow([r(-60, 100), r(-30, 110)], start: start, maxGap: gap).isEmpty)
    }

    func testNoReadingsGivesNoLine() {
        XCTAssertTrue(GraphWindow.clipToWindow([], start: start, maxGap: gap).isEmpty)
    }

    func testTheEdgeReadingIsFlaggedLikeAnyReading() {
        let clipped = GraphWindow.clipToWindow([r(-10, 60), r(10, 66)], start: start, maxGap: gap)

        XCTAssertTrue(clipped[0].isLow)
        XCTAssertFalse(clipped[0].isHigh)
    }
}
