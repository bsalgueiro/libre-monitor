import Foundation

// Port of src/LibreMonitor.Core/Models.cs

/// Trend arrow as reported by LibreView (1 = falling fast ... 5 = rising fast).
public enum Trend: Int, Sendable, Equatable {
    case unknown = 0
    case downFast = 1
    case downSlow = 2
    case stable = 3
    case upSlow = 4
    case upFast = 5

    public var arrow: String {
        switch self {
        case .downFast: return "↓"
        case .downSlow: return "↘"
        case .stable: return "→"
        case .upSlow: return "↗"
        case .upFast: return "↑"
        case .unknown: return "?"
        }
    }
}

public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case mgPerDl
    case mmolPerL

    public var label: String { self == .mmolPerL ? "mmol/L" : "mg/dL" }
}

public enum GlucoseUnits {
    /// mg/dL per mmol/L for glucose (molar mass 180.16 g/mol; the conventional factor is 18.0182).
    public static let mgPerDlPerMmolPerL = 18.0182

    /// Formats a value stored in mg/dL: whole numbers for mg/dL, one decimal for mmol/L.
    /// Rounds half away from zero, like the Windows app, so both apps show the same digits.
    public static func format(_ mgPerDl: Double, unit: GlucoseUnit, locale: Locale = .current) -> String {
        switch unit {
        case .mmolPerL: return formatted(mgPerDl / mgPerDlPerMmolPerL, decimals: 1, locale: locale)
        case .mgPerDl: return formatted(mgPerDl, decimals: 0, locale: locale)
        }
    }

    private static func formatted(_ value: Double, decimals: Int, locale: Locale) -> String {
        let scale = pow(10.0, Double(decimals))
        let rounded = (value * scale).rounded(.toNearestOrAwayFromZero) / scale

        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = decimals
        formatter.maximumFractionDigits = decimals
        return formatter.string(from: NSNumber(value: rounded)) ?? String(rounded)
    }
}

/// One glucose measurement. `mgPerDl` is always mg/dL; `value` is in the account's display unit.
public struct GlucoseReading: Equatable, Sendable {
    public let timestamp: Date
    public let mgPerDl: Double
    public let value: Double
    public let trend: Trend
    public let isHigh: Bool
    public let isLow: Bool

    public init(timestamp: Date, mgPerDl: Double, value: Double, trend: Trend, isHigh: Bool, isLow: Bool) {
        self.timestamp = timestamp
        self.mgPerDl = mgPerDl
        self.value = value
        self.trend = trend
        self.isHigh = isHigh
        self.isLow = isLow
    }
}

/// A person whose data the logged-in follower account can see.
public struct Patient: Equatable, Sendable {
    public let patientId: String
    public let firstName: String
    public let lastName: String

    public init(patientId: String, firstName: String, lastName: String) {
        self.patientId = patientId
        self.firstName = firstName
        self.lastName = lastName
    }
}

/// Latest reading plus the recent history returned by the graph endpoint.
public struct GlucoseSnapshot: Equatable, Sendable {
    public let current: GlucoseReading?
    public let history: [GlucoseReading]

    public init(current: GlucoseReading?, history: [GlucoseReading]) {
        self.current = current
        self.history = history
    }
}

public struct LibreLinkUpOptions: Sendable {
    /// Global entry point. Login may redirect to a regional host.
    public var baseUrl = "https://api.libreview.io"

    /// The follower API rejects clients below a minimum version, so this needs to track the official app.
    public var appVersion = "4.16.0"

    public var product = "llu.android"

    /// Required: the service's edge layer answers 403 to requests that carry no User-Agent.
    /// It identifies this tool honestly rather than imitating a browser or the official app.
    public var userAgent = "LibreMonitor/0.1 (personal read-only monitor)"

    public init() {}
}
