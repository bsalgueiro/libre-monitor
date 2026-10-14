import Foundation
import LibreMonitorKit
import XCTest

/// A UTC date, so test timestamps do not depend on the machine's time zone.
func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar.date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
}

/// Thread-safe counter for tests whose fake server and test body run on different threads.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// Thread-safe holder for a value captured from a callback.
final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ initial: T) { stored = initial }

    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); defer { lock.unlock() }; stored = newValue }
    }
}

/// A fixed list of canned responses, handed out in order (the Swift counterpart of the C# StubHandler).
final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(status: Int, body: String)]

    init(_ items: [(Int, String)]) {
        self.items = items.map { (status: $0.0, body: $0.1) }
    }

    func next() -> (status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        return items.isEmpty ? (status: 500, body: "{}") : items.removeFirst()
    }
}

/// Answers every request from a closure instead of the network, and records the requests it saw.
/// Tests in one class run one after another, so a single shared handler is enough.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) -> (status: Int, body: String)

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var recorded: [URLRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler
        recorded = []
    }

    static var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler
        Self.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }

        let result = handler(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: result.status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(result.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Asserts that `block` throws exactly `expected`.
func expectError(
    _ expected: LibreLinkUpError,
    file: StaticString = #filePath, line: UInt = #line,
    _ block: () async throws -> Void) async
{
    do {
        try await block()
        XCTFail("Expected \(expected) but nothing was thrown", file: file, line: line)
    } catch let error as LibreLinkUpError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Unexpected error: \(error)", file: file, line: line)
    }
}

/// Asserts that `block` throws any `.other(...)` error and returns its message.
@discardableResult
func expectOtherError(
    file: StaticString = #filePath, line: UInt = #line,
    _ block: () async throws -> Void) async -> String?
{
    do {
        try await block()
        XCTFail("Expected an error but nothing was thrown", file: file, line: line)
    } catch LibreLinkUpError.other(let message) {
        return message
    } catch {
        XCTFail("Expected an .other error but got: \(error)", file: file, line: line)
    }
    return nil
}
