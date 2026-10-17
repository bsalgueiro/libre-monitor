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

    func testRefreshNowPollsAgainWithoutWaitingForTheInterval() async {
        StubURLProtocol.install { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/login") { return (200, Self.loginOk) }
            if path.hasSuffix("/connections") { return (200, Self.patients) }
            return (200, Self.graph)
        }

        // An hour between polls: the second update can only come from refreshNow.
        let client = LibreLinkUpClient(session: StubURLProtocol.makeSession())
        let monitor = GlucoseMonitor(client: client, credentials: { (email: "a@b.c", password: "pw") }, interval: 3600)
        let count = Counter()
        let first = expectation(description: "first update")
        let second = expectation(description: "second update")
        monitor.onUpdate = { _ in
            count.increment()
            if count.value == 1 { first.fulfill() } else if count.value == 2 { second.fulfill() }
        }

        monitor.start()
        await fulfillment(of: [first], timeout: 5)
        try? await Task.sleep(nanoseconds: 100_000_000) // let the loop reach its sleep
        monitor.refreshNow()
        await fulfillment(of: [second], timeout: 5)
        await monitor.stop()

        XCTAssertEqual(count.value, 2)
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
