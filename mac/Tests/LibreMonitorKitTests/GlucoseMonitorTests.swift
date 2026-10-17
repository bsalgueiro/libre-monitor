import Foundation
import LibreMonitorKit
import XCTest

// Port of windows/tests/LibreMonitor.Core.Tests/GlucoseMonitorTests.cs

final class GlucoseMonitorTests: XCTestCase {
    private static let loginOk = #"{"status":0,"data":{"user":{"id":"u"},"authTicket":{"token":"t"}}}"#
    private static let patients = #"{"status":0,"data":[{"patientId":"p1","firstName":"Ana","lastName":"Silva"}]}"#
    private static let graph = #"{"status":0,"data":{"connection":{"glucoseMeasurement":{"FactoryTimestamp":"10/13/2026 8:45:12 PM","ValueInMgPerDl":112,"Value":112,"TrendArrow":3}},"graphData":[]}}"#

    private func makeMonitor() -> GlucoseMonitor {
        let client = LibreLinkUpClient(session: StubURLProtocol.makeSession())
        return GlucoseMonitor(client: client, credentials: { (email: "a@b.c", password: "pw") }, interval: 0.02)
    }

    func testStartLogsInAndRaisesUpdates() async throws {
        let logins = Counter()
        StubURLProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/login") { logins.increment(); return (200, Self.loginOk) }
            if path.hasSuffix("/connections") { return (200, Self.patients) }
            return (200, Self.graph)
        }

        let monitor = makeMonitor()
        let first = Box<MonitorUpdate?>(nil)
        let received = expectation(description: "update")
        received.assertForOverFulfill = false
        monitor.onUpdate = { update in
            if first.value == nil { first.value = update }
            received.fulfill()
        }

        monitor.start()
        await fulfillment(of: [received], timeout: 5)
        await monitor.stop()

        let update = try XCTUnwrap(first.value)
        XCTAssertEqual(update.patient.firstName, "Ana")
        XCTAssertEqual(update.snapshot.current?.mgPerDl, 112)
        XCTAssertEqual(logins.value, 1)
    }

    // MARK: - refreshNow and its guard rails

    /// A clock the test moves by hand, so the refresh limits can be checked without waiting.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)

        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    }

    private func installOkStub() {
        StubURLProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/login") { return (200, Self.loginOk) }
            if path.hasSuffix("/connections") { return (200, Self.patients) }
            return (200, Self.graph)
        }
    }

    /// A monitor that polls once an hour, so every further poll in a test comes from refreshNow.
    private func makeRefreshMonitor(clock: FakeClock, updates: Counter) -> GlucoseMonitor {
        let client = LibreLinkUpClient(session: StubURLProtocol.makeSession())
        let monitor = GlucoseMonitor(
            client: client, credentials: { (email: "a@b.c", password: "pw") }, interval: 3600, clock: { clock.now })
        monitor.onUpdate = { _ in updates.increment() }
        return monitor
    }

    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    func testRefreshNowAfterTheMinimumGapPollsAgainWithoutWaitingForTheInterval() async {
        installOkStub()
        let clock = FakeClock()
        let updates = Counter()
        let monitor = makeRefreshMonitor(clock: clock, updates: updates)

        monitor.start()
        await waitUntil { updates.value == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000) // let the loop reach its sleep
        clock.advance(GlucoseMonitor.minPollGap)

        XCTAssertTrue(monitor.refreshNow())
        await waitUntil { updates.value == 2 }
        await monitor.stop()

        XCTAssertEqual(updates.value, 2)
    }

    func testRefreshNowRightAfterAPollIsRefused() async {
        installOkStub()
        let clock = FakeClock()
        let updates = Counter()
        let monitor = makeRefreshMonitor(clock: clock, updates: updates)

        monitor.start()
        await waitUntil { updates.value == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(GlucoseMonitor.minPollGap - 1)

        XCTAssertFalse(monitor.refreshNow())
        try? await Task.sleep(nanoseconds: 300_000_000)
        await monitor.stop()

        XCTAssertEqual(updates.value, 1) // nothing was fetched
    }

    func testRepeatedRefreshNowOnlyTheFirstClickCounts() async {
        installOkStub()
        let clock = FakeClock()
        let updates = Counter()
        let monitor = makeRefreshMonitor(clock: clock, updates: updates)

        monitor.start()
        await waitUntil { updates.value == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(GlucoseMonitor.minPollGap)

        var accepted = 0
        for _ in 0..<20 where monitor.refreshNow() { accepted += 1 }

        await waitUntil { updates.value == 2 }
        try? await Task.sleep(nanoseconds: 300_000_000)
        await monitor.stop()

        XCTAssertEqual(accepted, 1)
        XCTAssertEqual(updates.value, 2) // 20 clicks, one request
    }

    func testRefreshNowIsLimitedToAFewTimesInTenMinutesThenAllowedAgain() async {
        installOkStub()
        let clock = FakeClock()
        let updates = Counter()
        let monitor = makeRefreshMonitor(clock: clock, updates: updates)

        monitor.start()
        await waitUntil { updates.value == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        // Spaced just wider than the gap, the clicks are only stopped by the cap.
        for i in 0..<GlucoseMonitor.maxManualRefreshes {
            clock.advance(GlucoseMonitor.minPollGap)
            XCTAssertTrue(monitor.refreshNow(), "refresh \(i + 1) should be allowed")
            await waitUntil { updates.value == i + 2 }
            try? await Task.sleep(nanoseconds: 50_000_000) // let the loop reach its sleep again
        }

        clock.advance(GlucoseMonitor.minPollGap)
        XCTAssertFalse(monitor.refreshNow()) // over the cap
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(updates.value, 1 + GlucoseMonitor.maxManualRefreshes)

        clock.advance(GlucoseMonitor.manualRefreshWindow) // the window has passed
        XCTAssertTrue(monitor.refreshNow())
        await waitUntil { updates.value == 2 + GlucoseMonitor.maxManualRefreshes }
        await monitor.stop()
    }

    func testRefreshNowWhileAPollIsRunningIsRefused() async {
        let gate = DispatchSemaphore(value: 0)
        let graphRequested = expectation(description: "graph requested")
        graphRequested.assertForOverFulfill = false
        StubURLProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/login") { return (200, Self.loginOk) }
            if path.hasSuffix("/connections") { return (200, Self.patients) }
            graphRequested.fulfill()
            gate.wait() // hold the first poll open until the test lets it finish
            return (200, Self.graph)
        }

        let clock = FakeClock()
        let updates = Counter()
        let monitor = makeRefreshMonitor(clock: clock, updates: updates)

        monitor.start()
        await fulfillment(of: [graphRequested], timeout: 5) // the first poll is in flight

        // Long past the minimum gap, so only the running poll can be the reason for the refusal.
        clock.advance(GlucoseMonitor.minPollGap * 2)
        XCTAssertFalse(monitor.refreshNow())

        gate.signal()
        await waitUntil { updates.value == 1 }
        await monitor.stop()

        XCTAssertEqual(updates.value, 1)
    }

    func testRefreshNowBeforeStartDoesNothing() {
        installOkStub()
        let monitor = makeRefreshMonitor(clock: FakeClock(), updates: Counter())

        XCTAssertFalse(monitor.refreshNow())
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testExpiredSessionLogsInAgainAndKeepsPolling() async {
        let logins = Counter()
        let graphCalls = Counter()
        StubURLProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/login") { logins.increment(); return (200, Self.loginOk) }
            if path.hasSuffix("/connections") { return (200, Self.patients) }
            return graphCalls.increment() == 1 ? (401, "{}") : (200, Self.graph)
        }

        let monitor = makeMonitor()
        let sawNonFatal = Box(false)
        let recovered = expectation(description: "recovered")
        recovered.assertForOverFulfill = false
        monitor.onFailure = { _, fatal in if !fatal { sawNonFatal.value = true } }
        monitor.onUpdate = { _ in recovered.fulfill() }

        monitor.start()
        await fulfillment(of: [recovered], timeout: 5)
        await monitor.stop()

        XCTAssertTrue(sawNonFatal.value)
        XCTAssertEqual(logins.value, 2)
    }

    func testWrongPasswordIsFatalAndStopsPolling() async throws {
        let logins = Counter()
        StubURLProtocol.install { request in
            if request.url!.path.hasSuffix("/auth/login") { logins.increment() }
            return (200, #"{"status":2}"#)
        }

        let monitor = makeMonitor()
        let fatal = Box<Bool?>(nil)
        let failed = expectation(description: "failed")
        failed.assertForOverFulfill = false
        monitor.onFailure = { _, isFatal in
            if fatal.value == nil { fatal.value = isFatal }
            failed.fulfill()
        }

        monitor.start()
        await fulfillment(of: [failed], timeout: 5)
        try await Task.sleep(nanoseconds: 150_000_000) // long enough for several polls, if it had not stopped
        await monitor.stop()

        XCTAssertEqual(fatal.value, true)
        XCTAssertEqual(logins.value, 1)
    }
}
