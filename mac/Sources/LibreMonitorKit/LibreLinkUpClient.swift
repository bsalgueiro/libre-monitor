import CryptoKit
import Foundation

// Port of src/LibreMonitor.Core/LibreLinkUpClient.cs

/// Read-only client for the unofficial LibreLinkUp follower API.
/// It only logs in and reads; nothing here writes data to the account.
public actor LibreLinkUpClient {
    private static let maxRedirects = 2

    private let session: URLSession
    private let options: LibreLinkUpOptions

    private var baseUrl: String
    private var token: String?
    private var accountIdHash: String?

    public init(session: URLSession = .shared, options: LibreLinkUpOptions = LibreLinkUpOptions()) {
        self.session = session
        self.options = options

        var base = options.baseUrl
        while base.hasSuffix("/") { base.removeLast() }
        self.baseUrl = base
    }

    public var currentBaseUrl: String { baseUrl }

    public var isLoggedIn: Bool { token != nil }

    // MARK: - Login

    public func login(email: String, password: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        for _ in 0...Self.maxRedirects {
            var request = try makeRequest(method: "POST", path: "/llu/auth/login", authenticated: false)
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let (data, status) = try await perform(request)
            let root = try decode(data, status: status) as? [String: Any]

            if let code = root?["status"] as? Int, code == 2 {
                throw LibreLinkUpError.invalidCredentials
            }

            guard let payload = root?["data"] as? [String: Any] else {
                throw LibreLinkUpError.invalidCredentials
            }

            if let redirect = payload["redirect"] as? Bool, redirect {
                // The region comes from the server, so it is validated before it becomes part of a host name.
                guard let region = payload["region"] as? String, Self.isSafeRegion(region) else {
                    throw LibreLinkUpError.other("Login redirected to an unrecognised region.")
                }

                baseUrl = "https://api-\(region.lowercased()).libreview.io"
                continue
            }

            if let step = payload["step"] as? [String: Any], let type = step["type"] as? String {
                throw LibreLinkUpError.accountActionRequired(step: type)
            }

            guard let ticket = payload["authTicket"] as? [String: Any],
                  let newToken = ticket["token"] as? String,
                  let user = payload["user"] as? [String: Any],
                  let userId = user["id"] as? String
            else {
                throw LibreLinkUpError.invalidCredentials
            }

            token = newToken
            accountIdHash = Self.sha256Hex(userId)
            return
        }

        throw LibreLinkUpError.other("Too many login redirects.")
    }

    // MARK: - Reads

    public func getPatients() async throws -> [Patient] {
        let json = try await get("/llu/connections")
        guard let root = json as? [String: Any], let items = root["data"] as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            guard let id = item["patientId"] as? String else { return nil }
            return Patient(
                patientId: id,
                firstName: item["firstName"] as? String ?? "",
                lastName: item["lastName"] as? String ?? "")
        }
    }

    public func getGraph(patientId: String) async throws -> GlucoseSnapshot {
        let json = try await get("/llu/connections/\(Self.escape(patientId))/graph")

        var current: GlucoseReading?
        var history: [GlucoseReading] = []

        if let root = json as? [String: Any], let data = root["data"] as? [String: Any] {
            if let connection = data["connection"] as? [String: Any],
               let latest = connection["glucoseMeasurement"] as? [String: Any]
            {
                current = try Self.parseReading(latest)
            }

            if let graph = data["graphData"] as? [[String: Any]] {
                history = try graph.map { try Self.parseReading($0) }
            }
        }

        return GlucoseSnapshot(current: current, history: history)
    }

    // MARK: - Requests

    private func get(_ path: String) async throws -> Any {
        guard token != nil else { throw LibreLinkUpError.sessionExpired }

        let request = try makeRequest(method: "GET", path: path, authenticated: true)
        let (data, status) = try await perform(request)

        if status == 401 || status == 403 {
            token = nil
            throw LibreLinkUpError.sessionExpired
        }

        return try decode(data, status: status)
    }

    private func makeRequest(method: String, path: String, authenticated: Bool) throws -> URLRequest {
        guard let url = URL(string: baseUrl + path) else {
            throw LibreLinkUpError.other("Invalid request address.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(options.product, forHTTPHeaderField: "product")
        request.setValue(options.appVersion, forHTTPHeaderField: "version")
        request.setValue(options.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        if authenticated, let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(accountIdHash, forHTTPHeaderField: "account-id")
        }

        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw LibreLinkUpError.other("LibreLinkUp returned an unexpected response.")
        }

        return (data, http.statusCode)
    }

    /// Bad requests (400) still carry a JSON body that says why; any other failure status is an error.
    private func decode(_ data: Data, status: Int) throws -> Any {
        if !(200..<300).contains(status) && status != 400 {
            throw LibreLinkUpError.other("LibreLinkUp returned HTTP \(status).")
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw LibreLinkUpError.other("LibreLinkUp returned a response that is not valid JSON.")
        }
    }

    // MARK: - Parsing helpers

    private static func parseReading(_ e: [String: Any]) throws -> GlucoseReading {
        let timestamp = try parseTimestamp(e["FactoryTimestamp"] as? String ?? "")
        let trend = (e["TrendArrow"] as? NSNumber).flatMap { Trend(rawValue: $0.intValue) } ?? .unknown

        return GlucoseReading(
            timestamp: timestamp,
            mgPerDl: (e["ValueInMgPerDl"] as? NSNumber)?.doubleValue ?? 0,
            value: (e["Value"] as? NSNumber)?.doubleValue ?? 0,
            trend: trend,
            isHigh: e["isHigh"] as? Bool ?? false,
            isLow: e["isLow"] as? Bool ?? false)
    }

    /// FactoryTimestamp is UTC in the API's US-style format, e.g. "10/13/2026 8:45:12 PM".
    private static func parseTimestamp(_ text: String) throws -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "M/d/yyyy h:mm:ss a"

        guard let date = formatter.date(from: text) else {
            throw LibreLinkUpError.other("Unrecognised timestamp format '\(text)'.")
        }

        return date
    }

    private static func isSafeRegion(_ region: String) -> Bool {
        region.range(of: "^[A-Za-z0-9]{2,6}$", options: .regularExpression) != nil
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
