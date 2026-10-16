import CryptoKit
import Foundation
import LibreMonitorKit
import XCTest

// Port of windows/tests/LibreMonitor.Core.Tests/LibreLinkUpClientTests.cs

final class LibreLinkUpClientTests: XCTestCase {
    private let loginOk = #"{"status":0,"data":{"user":{"id":"user-123"},"authTicket":{"token":"tok-abc"}}}"#

    private func makeClient(_ responses: [(Int, String)]) -> LibreLinkUpClient {
        let queue = ResponseQueue(responses)
        StubURLProtocol.install { _ in queue.next() }
        return LibreLinkUpClient(session: StubURLProtocol.makeSession())
    }

    func testLoginStoresSessionAndSendsRequiredHeaders() async throws {
        let client = makeClient([(200, loginOk), (200, #"{"status":0,"data":[]}"#)])

        try await client.login(email: "a@b.c", password: "pw")
        _ = try await client.getPatients()

        let loggedIn = await client.isLoggedIn
        XCTAssertTrue(loggedIn)

        let requests = StubURLProtocol.requests
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.libreview.io/llu/auth/login")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "product"), "llu.android")
        // Requests without a User-Agent get HTTP 403 from the service's edge layer.
        XCTAssertFalse((requests[0].value(forHTTPHeaderField: "User-Agent") ?? "").isEmpty)
        XCTAssertFalse((requests[1].value(forHTTPHeaderField: "User-Agent") ?? "").isEmpty)
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))

        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer tok-abc")
        let expectedHash = SHA256.hash(data: Data("user-123".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "account-id"), expectedHash)
    }

    func testLoginFollowsRegionRedirect() async throws {
        let client = makeClient([
            (200, #"{"status":0,"data":{"redirect":true,"region":"eu"}}"#),
            (200, loginOk),
        ])

        try await client.login(email: "a@b.c", password: "pw")

        let baseUrl = await client.currentBaseUrl
        XCTAssertEqual(baseUrl, "https://api-eu.libreview.io")
        XCTAssertEqual(StubURLProtocol.requests[1].url?.absoluteString, "https://api-eu.libreview.io/llu/auth/login")
    }

    func testLoginRejectsUnsafeRegionWithoutSendingCredentialsElsewhere() async {
        for region in ["evil.example/x", "eu.attacker.com", ""] {
            let client = makeClient([(200, #"{"status":0,"data":{"redirect":true,"region":"\#(region)"}}"#)])

            await expectOtherError { try await client.login(email: "a@b.c", password: "pw") }

            XCTAssertEqual(StubURLProtocol.requests.count, 1, "region '\(region)'")
            let baseUrl = await client.currentBaseUrl
            XCTAssertEqual(baseUrl, "https://api.libreview.io", "region '\(region)'")
        }
    }

    func testLoginWrongPasswordThrows() async {
        let client = makeClient([(200, #"{"status":2}"#)])

        await expectError(.invalidCredentials) { try await client.login(email: "a@b.c", password: "bad") }

        let loggedIn = await client.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    func testLoginPendingStepThrowsActionRequired() async {
        for step in ["tou", "pp", "verifyEmail"] {
            let client = makeClient([(200, #"{"status":0,"data":{"step":{"type":"\#(step)"}}}"#)])

            await expectError(.accountActionRequired(step: step)) {
                try await client.login(email: "a@b.c", password: "pw")
            }
        }
    }

    func testLoginErrorMessageNeverContainsPassword() async {
        let client = makeClient([(500, "{}")])

        do {
            try await client.login(email: "a@b.c", password: "s3cret-pw")
            XCTFail("Expected an error")
        } catch {
            XCTAssertFalse(String(describing: error).contains("s3cret-pw"))
            XCTAssertFalse(error.localizedDescription.contains("s3cret-pw"))
        }
    }

    func testReadWithoutLoginThrowsSessionExpired() async {
        let client = makeClient([])

        await expectError(.sessionExpired) { _ = try await client.getPatients() }
    }

    func testReadUnauthorizedClearsSession() async throws {
        let client = makeClient([(200, loginOk), (401, "{}")])
        try await client.login(email: "a@b.c", password: "pw")

        await expectError(.sessionExpired) { _ = try await client.getPatients() }

        let loggedIn = await client.isLoggedIn
        XCTAssertFalse(loggedIn)
    }

    func testGetPatientsParsesConnections() async throws {
        let client = makeClient([
            (200, loginOk),
            (200, #"{"status":0,"data":[{"patientId":"p1","firstName":"Ana","lastName":"Silva"}]}"#),
        ])
        try await client.login(email: "a@b.c", password: "pw")

        let patients = try await client.getPatients()

        XCTAssertEqual(patients, [Patient(patientId: "p1", firstName: "Ana", lastName: "Silva")])
    }

    func testGetGraphParsesCurrentAndHistory() async throws {
        let graph = """
        {"status":0,"data":{
          "connection":{"glucoseMeasurement":{"FactoryTimestamp":"10/13/2026 8:45:12 PM","ValueInMgPerDl":112,"Value":112,"TrendArrow":4,"isHigh":false,"isLow":false}},
          "graphData":[
            {"FactoryTimestamp":"10/13/2026 8:30:00 PM","ValueInMgPerDl":98,"Value":98,"isHigh":false,"isLow":false},
            {"FactoryTimestamp":"10/13/2026 8:35:00 PM","ValueInMgPerDl":69,"Value":69,"isHigh":false,"isLow":true}
          ]}}
        """
        let client = makeClient([(200, loginOk), (200, graph)])
        try await client.login(email: "a@b.c", password: "pw")

        let snapshot = try await client.getGraph(patientId: "p 1")

        XCTAssertEqual(StubURLProtocol.requests[1].url?.absoluteString,
                       "https://api.libreview.io/llu/connections/p%201/graph")
        let current = try XCTUnwrap(snapshot.current)
        XCTAssertEqual(current.timestamp, utc(2026, 10, 13, 20, 45, 12))
        XCTAssertEqual(current.mgPerDl, 112)
        XCTAssertEqual(current.trend, .upSlow)
        XCTAssertEqual(snapshot.history.count, 2)
        XCTAssertTrue(snapshot.history[1].isLow)
        XCTAssertEqual(snapshot.history[0].trend, .unknown)
    }

    func testGetGraphWithNoMeasurementReturnsNilCurrent() async throws {
        let client = makeClient([(200, loginOk), (200, #"{"status":0,"data":{"connection":{},"graphData":[]}}"#)])
        try await client.login(email: "a@b.c", password: "pw")

        let snapshot = try await client.getGraph(patientId: "p1")

        XCTAssertNil(snapshot.current)
        XCTAssertTrue(snapshot.history.isEmpty)
    }
}
