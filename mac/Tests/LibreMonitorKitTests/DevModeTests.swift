import Foundation
import LibreMonitorKit
import XCTest

// Port of tests/LibreMonitor.Core.Tests/SimulationTests.cs and DevOptionsTests.cs.
// Developer mode only exists in Debug builds, so these tests do too.

#if DEBUG

final class SimulationTests: XCTestCase {
    private let now = utc(2026, 10, 14, 12, 0, 0)

    func testScenariosCoverEveryColourStateAndBothThresholdEdges() {
        let values = Simulation.scenarios.filter { !$0.stale }.compactMap { $0.mgPerDl }

        XCTAssertTrue(values.contains { $0 < 70 })
        XCTAssertTrue(values.contains { $0 >= 70 && $0 <= 180 })
        XCTAssertTrue(values.contains { $0 > 180 })
        XCTAssertTrue(values.contains(69))
        XCTAssertTrue(values.contains(180))
        XCTAssertTrue(values.contains(181))
        XCTAssertTrue(Simulation.scenarios.contains { $0.stale })
        XCTAssertTrue(Simulation.scenarios.contains { $0.mgPerDl == nil })
    }

    func testBuildCurrentMatchesTheScenarioAndIsNow() throws {
        let scenario = SimulationScenario("t", 250, trend: .upSlow)

        let snapshot = Simulation.build(scenario, now: now)

        let current = try XCTUnwrap(snapshot.current)
        XCTAssertEqual(current.mgPerDl, 250)
        XCTAssertEqual(current.trend, .upSlow)
        XCTAssertEqual(current.timestamp, now)
        XCTAssertTrue(current.isHigh)
        XCTAssertFalse(current.isLow)
    }

    func testBuildHistoryIsOrderedEndsNearTheTargetAndStaysBeforeCurrent() throws {
        let snapshot = Simulation.build(SimulationScenario("t", 55, trend: .downSlow), now: now)

        XCTAssertEqual(snapshot.history.count, 48)
        XCTAssertEqual(snapshot.history.map(\.timestamp), snapshot.history.map(\.timestamp).sorted())
        XCTAssertLessThan(try XCTUnwrap(snapshot.history.last).timestamp, try XCTUnwrap(snapshot.current).timestamp)
        XCTAssertEqual(try XCTUnwrap(snapshot.history.last).mgPerDl, 55, accuracy: 0.5)
    }

    func testBuildStaleScenarioIsOlderThanTheOldReadingLimit() throws {
        let snapshot = Simulation.build(SimulationScenario("t", 110, stale: true), now: now)

        XCTAssertGreaterThan(now.timeIntervalSince(try XCTUnwrap(snapshot.current).timestamp), 10 * 60)
    }

    func testBuildNoReadingHasNothing() {
        let snapshot = Simulation.build(SimulationScenario("t", nil), now: now)

        XCTAssertNil(snapshot.current)
        XCTAssertTrue(snapshot.history.isEmpty)
    }
}

final class DevOptionsTests: XCTestCase {
    func testNoFlagsDevModeIsOff() {
        XCTAssertEqual(DevOptions.parse(["app"], allowed: true), .none)
    }

    func testDevFlagTurnsItOnWhenAllowed() {
        let options = DevOptions.parse(["app", "--dev"], allowed: true)

        XCTAssertTrue(options.enabled)
        XCTAssertNil(options.scenario)
    }

    func testSimulateFlagImpliesDevModeAndPicksTheScenario() {
        let options = DevOptions.parse(["app", "--simulate", "2"], allowed: true)

        XCTAssertTrue(options.enabled)
        XCTAssertEqual(options.scenario, 2)
    }

    func testInvalidScenarioIsIgnoredAndDoesNotEnableDevModeOnItsOwn() {
        for value in ["abc", "-1", "99"] {
            let options = DevOptions.parse(["app", "--simulate", value], allowed: true)

            XCTAssertFalse(options.enabled, value)
            XCTAssertNil(options.scenario, value)
        }
    }

    func testSimulateWithoutAValueIsIgnored() {
        XCTAssertEqual(DevOptions.parse(["app", "--simulate"], allowed: true), .none)
    }

    func testFlagsAreCaseInsensitive() {
        XCTAssertTrue(DevOptions.parse(["app", "--DEV"], allowed: true).enabled)
    }

    // The guarantee that matters: a build that does not allow dev mode can never have it enabled by any flag.
    func testWhenNotAllowedNothingEnablesIt() {
        for flag in ["--dev", "--simulate"] {
            let options = DevOptions.parse(["app", "--dev", flag, "0", "--simulate", "0"], allowed: false)

            XCTAssertEqual(options, .none)
            XCTAssertFalse(options.enabled)
            XCTAssertNil(options.scenario)
        }
    }
}

#endif
