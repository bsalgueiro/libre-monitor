import CryptoKit
import Foundation

// Port of windows/src/LibreMonitor.Core/LibreLinkUpClient.cs

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
            let json = try decode(data, status: status)

            if let object = json as? [String: Any], let code = (object["status"] as? NSNumber)?.intValue, code == 2 {
                throw LibreLinkUpError.invalidCredentials
            }

            // Anything else that is not a normal success is the service behaving differently, not a wrong password.
            let root = try Self.requireObject(json)
            try Self.throwIfUnexpectedStatus(root)

            guard let payload = root["data"] as? [String: Any] else {
                throw LibreLinkUpError.serviceChanged(detail: "the login response has no data")
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
                throw LibreLinkUpError.serviceChanged(detail: "the login response has no session details")
            }

            token = newToken
            accountIdHash = Self.sha256Hex(userId)
            return
        }

        throw LibreLinkUpError.other("Too many login redirects.")
    }

    // MARK: - Reads

    public func getPatients() async throws -> [Patient] {
        let root = try Self.requireObject(try await get("/llu/connections"))
        try Self.throwIfUnexpectedStatus(root)

        // An empty list is a normal answer (nobody is shared yet); a missing list is not.
        guard let items = root["data"] as? [[String: Any]] else {
            throw LibreLinkUpError.serviceChanged(detail: "the connections response has no list")
        }

        return try items.map { item in
            guard let id = item["patientId"] as? String else {
                throw LibreLinkUpError.serviceChanged(detail: "a connection has no patient id")
            }
            return Patient(
                patientId: id,
                firstName: item["firstName"] as? String ?? "",
                lastName: item["lastName"] as? String ?? "")
        }
    }

    public func getGraph(patientId: String) async throws -> GlucoseSnapshot {
        let root = try Self.requireObject(try await get("/llu/connections/\(Self.escape(patientId))/graph"))
        try Self.throwIfUnexpectedStatus(root)

        guard let data = root["data"] as? [String: Any] else {
            throw LibreLinkUpError.serviceChanged(detail: "the graph response has no data")
        }

        // No current measurement is a normal answer (sensor warming up or out of range); a changed format is not.
        var current: GlucoseReading?
        var history: [GlucoseReading] = []

        if let connection = data["connection"] as? [String: Any],
           let latest = connection["glucoseMeasurement"] as? [String: Any]
        {
            current = try Self.parseReading(latest)
        }

        if let graph = data["graphData"] as? [[String: Any]] {
            history = try graph.map { try Self.parseReading($0) }
        }

        return GlucoseSnapshot(current: current, history: history, sensor: Self.parseSensor(data))
    }

    /// The activation time of the sensor in use, or nil when the service does not say. The answer is optional extra
    /// information, so anything unexpected here means "unknown", never a service change. Only the activation time is
    /// read: the serial number and device ids are never touched.
    private static func parseSensor(_ data: [String: Any]) -> SensorInfo? {
        var newest: Date?

        func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }

        func consider(_ value: Any?) {
            guard let sensor = value as? [String: Any] else { return }

            // "s" says whether the sensor is the active one; only an explicit false rules it out.
            if let active = sensor["s"] as? NSNumber, isBoolean(active), !active.boolValue { return }

            // From 2001 to 2096: anything else is not a date.
            guard let activated = sensor["a"] as? NSNumber, !isBoolean(activated) else { return }
            let seconds = activated.int64Value
            guard seconds >= 1_000_000_000, seconds <= 4_000_000_000 else { return }

            let at = Date(timeIntervalSince1970: TimeInterval(seconds))
            if newest == nil || at > newest! { newest = at }
        }

        if let list = data["activeSensors"] as? [Any] {
            for entry in list { consider((entry as? [String: Any])?["sensor"]) }
        }

        // The same information also appears on the connection, for answers that carry no list.
        if newest == nil, let connection = data["connection"] as? [String: Any] {
            consider(connection["sensor"])
        }

        return newest.map { SensorInfo(activatedAt: $0) }
    }

    private static func requireObject(_ json: Any) throws -> [String: Any] {
        guard let object = json as? [String: Any] else {
            throw LibreLinkUpError.serviceChanged(detail: "the response is not a JSON object")
        }
        return object
    }

    /// The API reports its own status in the body. 0 is success and 2 (bad credentials) is handled by the caller; any
    /// other value, such as the one used to say that the client version is too old, means the service has changed.
    private static func throwIfUnexpectedStatus(_ root: [String: Any]) throws {
        guard let code = (root["status"] as? NSNumber)?.intValue, code != 0 else { return }

        var minimumVersion: String?
        if let data = root["data"] as? [String: Any], let minimum = data["minimumVersion"], !(minimum is NSNull) {
            minimumVersion = "\(minimum)"
        }

        throw LibreLinkUpError.serviceChanged(detail: minimumVersion.map {
            "status \(code), the service now asks for app version \($0) or newer"
        } ?? "status \(code)")
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
            // Forbidden (a blocked client), not found or gone (a removed endpoint) are not hiccups: the service has
            // changed. Server errors and rate limits are, so those stay ordinary, retryable failures.
            if status == 403 || status == 404 || status == 410 {
                throw LibreLinkUpError.serviceChanged(detail: "HTTP \(status)")
            }
            throw LibreLinkUpError.other("LibreLinkUp returned HTTP \(status).")
        }

        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            // A web page where JSON was expected is typically a block or challenge page.
            throw LibreLinkUpError.serviceChanged(detail: "the response is not valid JSON")
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
            throw LibreLinkUpError.serviceChanged(detail: "unrecognised timestamp format '\(text)'")
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
