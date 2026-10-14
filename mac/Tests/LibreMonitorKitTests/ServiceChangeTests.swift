import Foundation
import LibreMonitorKit
import XCTest

// Port of tests/LibreMonitor.Core.Tests/ServiceChangeTests.cs
//
// What happens when LibreLinkUp changes, blocks the client, or just has a bad moment. The rule: a response that does
// not look right is "the service changed" (so the user can be told to look for an update), never a wrong password;
// ordinary hiccups stay quiet and retryable.

final class ServiceChangeTests: XCTestCase {
    private static let loginOk = #"{"status":0,"data":{"user":{"id":"u"},"authTicket":{"token":"t"}}}"#
    private static let patients = #"{"status":0,"data":[{"patientId":"p1","firstName":"Ana","lastName":"Silva"}]}"#
    private static let graph = #"{"status":0,"data":{"connection":{"glucoseMeasurement":{"FactoryTimestamp":"10/13/2026 8:45:12 PM","ValueInMgPerDl":112,"Value":112,"TrendArrow":3}},"graphData":[]}}"#

    // MARK: helpers

    private func makeClient(_ route: @escaping StubURLProtocol.Handler) -> LibreLinkUpClient {
        StubURLProtocol.install(route)
        return LibreLinkUpClient(session: StubURLProtocol.makeSession())
    }

    /// A client that has logged in successfully; `afterLogin` answers every later request.
    private func loggedIn(_ afterLogin: @escaping StubURLProtocol.Handler) async throws -> LibreLinkUpClient {
        let client = makeClient { request in
            request.url!.path.hasSuffix("/auth/login") ? (status: 200, body: Self.loginOk) : afterLogin(request)
        }
        try await client.login(email: "a@b.c", password: "pw")
        return client
    }

    private func thrown(_ block: () async throws -> Void) async -> Error? {
        do { try await block(); return nil } catch { return error }
    }

    private func serviceChangedDetail(_ error: Error?, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let changed = error as? LibreLinkUpError, case .serviceChanged(let detail) = changed else {
            XCTFail("Expected .serviceChanged but got \(String(describing: error))", file: file, line: line)
            return nil
        }
        return detail
    }

    // MARK: login

    func testLoginBlockedOrRemovedIsServiceChanged() async {
        for code in [403, 404, 410] {
            let client = makeClient { _ in (code, "<html>blocked</html>") }

            let error = await thrown { try await client.login(email: "a@b.c", password: "pw") }

            XCTAssertEqual(serviceChangedDetail(error), "HTTP \(code)")
        }
    }

    func testLoginServerErrorOrRateLimitIsAnOrdinaryRetryableFailure() async {
        for code in [500, 502, 429] {
            let client = makeClient { _ in (code, "{}") }

            let error = await thrown { try await client.login(email: "a@b.c", password: "pw") }

            guard let failure = error as? LibreLinkUpError, case .other = failure else {
                return XCTFail("HTTP \(code) should be an ordinary failure, got \(String(describing: error))")
            }
        }
    }

    func testLoginClientVersionTooOldSaysWhichVersionIsNeeded() async {
        let client = makeClient { _ in (200, #"{"status":920,"data":{"minimumVersion":"4.99.0"}}"#) }

        let error = await thrown { try await client.login(email: "a@b.c", password: "pw") }

        let detail = serviceChangedDetail(error) ?? ""
        XCTAssertTrue(detail.contains("920"))
        XCTAssertTrue(detail.contains("4.99.0"))
    }

    func testLoginAnyOtherNonZeroStatusIsServiceChangedNotAWrongPassword() async {
        let client = makeClient { _ in (200, #"{"status":7}"#) }

        let error = await thrown { try await client.login(email: "a@b.c", password: "pw") }

        XCTAssertNotNil(serviceChangedDetail(error))
    }

    func testLoginWrongPasswordIsStillAWrongPassword() async {
        let client = makeClient { _ in (200, #"{"status":2}"#) }

        await expectError(.invalidCredentials) { try await client.login(email: "a@b.c", password: "bad") }
    }

    func testLoginResponseInTheWrongShapeIsServiceChangedNotAWrongPassword() async {
        let bodies = [
            #"{"status":0}"#,                                          // no data at all
            #"{"status":0,"data":{}}"#,                                // data without a session
            #"{"status":0,"data":{"user":{"id":"u"}}}"#,               // no auth ticket
            #"{"status":0,"data":{"authTicket":{"token":"t"}}}"#,      // no user
            "<html>Just a moment...</html>",                           // a challenge page instead of JSON
            "[]",                                                      // JSON, but not an object
        ]
        for body in bodies {
            let client = makeClient { _ in (200, body) }

            let error = await thrown { try await client.login(email: "a@b.c", password: "pw") }

            XCTAssertNotNil(serviceChangedDetail(error), body)
        }
    }

    // MARK: reads

    func testConnectionsMissingListIsServiceChanged() async throws {
        let client = try await loggedIn { _ in (200, #"{"status":0}"#) }

        let error = await thrown { _ = try await client.getPatients() }

        XCTAssertNotNil(serviceChangedDetail(error))
    }

    func testConnectionsEmptyListIsNormal() async throws {
        let client = try await loggedIn { _ in (200, #"{"status":0,"data":[]}"#) }

        let patients = try await client.getPatients()

        XCTAssertTrue(patients.isEmpty)
    }

    func testConnectionsItemWithoutPatientIdIsServiceChanged() async throws {
        let client = try await loggedIn { _ in (200, #"{"status":0,"data":[{"firstName":"Ana"}]}"#) }

        let error = await thrown { _ = try await client.getPatients() }

        XCTAssertNotNil(serviceChangedDetail(error))
    }

    func testGraphNonZeroStatusIsServiceChanged() async throws {
        let client = try await loggedIn { _ in (200, #"{"status":920,"data":{"minimumVersion":"5.0.0"}}"#) }

        let error = await thrown { _ = try await client.getGraph(patientId: "p1") }

        XCTAssertNotNil(serviceChangedDetail(error))
    }

    func testGraphNoDataObjectIsServiceChanged() async throws {
        let client = try await loggedIn { _ in (200, #"{"status":0}"#) }

        let error = await thrown { _ = try await client.getGraph(patientId: "p1") }

        XCTAssertNotNil(serviceChangedDetail(error))
    }

    func testGraphUnrecognisedTimestampIsServiceChanged() async throws {
        let body = #"{"status":0,"data":{"connection":{"glucoseMeasurement":{"FactoryTimestamp":"2026-10-13T20:45:12Z","ValueInMgPerDl":112}},"graphData":[]}}"#
        let client = try await loggedIn { _ in (200, body) }

        let error = await thrown { _ = try await client.getGraph(patientId: "p1") }

        XCTAssertNotNil(serviceChangedDetail(error))
    }

    func testGraphNoCurrentReadingIsStillNormal() async throws {
        let client = try await loggedIn { _ in (200, #"{"status":0,"data":{"connection":{},"graphData":[]}}"#) }

        let snapshot = try await client.getGraph(patientId: "p1")

        XCTAssertNil(snapshot.current)
    }

    func testReadForbiddenStillMeansAnExpiredSessionNotAChangedService() async throws {
        let client = try await loggedIn { _ in (403, "{}") }

        await expectError(.sessionExpired) { _ = try await client.getPatients() }
    }

    func testMessageNamesTheProblemAndNeverTheCredentials() {
        let message = LibreLinkUpError.serviceChanged(detail: "status 920").errorDescription ?? ""

        XCTAssertTrue(message.contains("status 920"))
        XCTAssertTrue(message.contains("changed or blocked"))
    }

    // MARK: the monitor escalates only when it keeps happening

    private func makeMonitor(_ route: @escaping StubURLProtocol.Handler) -> GlucoseMonitor {
        StubURLProtocol.install(route)
        return GlucoseMonitor(
            client: LibreLinkUpClient(session: StubURLProtocol.makeSession()),
            credentials: { (email: "a@b.c", password: "pw") },
            interval: 0.015)
    }

    func testMonitorRaisesServiceChangedOnlyAfterTheThresholdOfFailuresInARowAndOnlyOnce() async throws {
        let monitor = makeMonitor { _ in (403, "<html>blocked</html>") }
        let failures = Counter()
        let raisedAt = Box<[Int]>([])
        let enough = expectation(description: "enough failures")
        enough.assertForOverFulfill = false

        monitor.onFailure = { _, fatal in
            XCTAssertFalse(fatal)
            if failures.increment() >= GlucoseMonitor.serviceChangedThreshold + 4 { enough.fulfill() }
        }
        monitor.onServiceChanged = { _ in raisedAt.value.append(failures.value) }

        monitor.start()
        await fulfillment(of: [enough], timeout: 5)
        await monitor.stop()

        XCTAssertEqual(raisedAt.value.count, 1, "reported once, not on every failure")
        XCTAssertEqual(raisedAt.value.first, GlucoseMonitor.serviceChangedThreshold, "and not before the threshold")
    }

    func testMonitorAFewOddResponsesAmongGoodOnesRaiseNothing() async {
        let graphCalls = Counter()
        // Every third graph response is odd; the others are fine, so there is never an unbroken run.
        let monitor = makeMonitor { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/login") { return (200, Self.loginOk) }
            if path.hasSuffix("/connections") { return (200, Self.patients) }
            return graphCalls.increment() % 3 == 0 ? (404, "{}") : (200, Self.graph)
        }
        let raised = Box(false)
        let enough = expectation(description: "enough polls")
        enough.assertForOverFulfill = false

        monitor.onServiceChanged = { _ in raised.value = true }
        monitor.onUpdate = { _ in if graphCalls.value >= 12 { enough.fulfill() } }

        monitor.start()
        await fulfillment(of: [enough], timeout: 5)
        await monitor.stop()

        XCTAssertFalse(raised.value)
    }

    func testMonitorAfterRecoveryAReturningProblemIsReportedAgain() async {
        let broken = Box(true)
        let monitor = makeMonitor { request in
            let path = request.url!.path
            if path.hasSuffix("/auth/login") { return (200, Self.loginOk) }
            if path.hasSuffix("/connections") { return (200, Self.patients) }
            return broken.value ? (404, "{}") : (200, Self.graph)
        }
        let episodes = Counter()
        let first = expectation(description: "first episode")
        let second = expectation(description: "second episode")
        let recovered = expectation(description: "recovered")
        recovered.assertForOverFulfill = false

        monitor.onServiceChanged = { _ in
            if episodes.increment() == 1 { first.fulfill() } else { second.fulfill() }
        }
        monitor.onUpdate = { _ in recovered.fulfill() }

        monitor.start()
        await fulfillment(of: [first], timeout: 5)
        broken.value = false
        await fulfillment(of: [recovered], timeout: 5)
        broken.value = true
        await fulfillment(of: [second], timeout: 5)
        await monitor.stop()

        XCTAssertEqual(episodes.value, 2)
    }

    func testMonitorServerErrorsAreNeverReportedAsAChangedService() async {
        let monitor = makeMonitor { _ in (500, "{}") }
        let raised = Box(false)
        let failures = Counter()
        let enough = expectation(description: "enough failures")
        enough.assertForOverFulfill = false

        monitor.onServiceChanged = { _ in raised.value = true }
        monitor.onFailure = { _, _ in if failures.increment() >= 8 { enough.fulfill() } }

        monitor.start()
        await fulfillment(of: [enough], timeout: 5)
        await monitor.stop()

        XCTAssertFalse(raised.value)
    }
}
