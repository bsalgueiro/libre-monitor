import Foundation

// Port of src/LibreMonitor.Core/Simulation.cs and DevOptions.cs
//
// Developer mode lives entirely inside `#if DEBUG`: a Release build does not contain this code at all, so a
// simulated reading can never appear in a build that users receive.

#if DEBUG

/// A fake state for testing how the display looks. Developer use only.
public struct SimulationScenario: Equatable, Sendable {
    public let name: String
    public let mgPerDl: Double?
    public let trend: Trend
    public let stale: Bool

    public init(_ name: String, _ mgPerDl: Double?, trend: Trend = .stable, stale: Bool = false) {
        self.name = name
        self.mgPerDl = mgPerDl
        self.trend = trend
        self.stale = stale
    }
}

/// Builds synthetic readings so every colour state can be seen without waiting for real glucose to change.
public enum Simulation {
    // The edges (69/70, 180/181) sit either side of the colour thresholds.
    public static let scenarios: [SimulationScenario] = [
        SimulationScenario("Low 55 (red)", 55, trend: .downSlow),
        SimulationScenario("Low 69, just under range (red)", 69, trend: .downSlow),
        SimulationScenario("In range 100 (green)", 100),
        SimulationScenario("In range 180, top of range (green)", 180),
        SimulationScenario("High 181, just over range (amber)", 181, trend: .upSlow),
        SimulationScenario("High 250 (amber)", 250, trend: .upSlow),
        SimulationScenario("Very high 350 (amber)", 350, trend: .upFast),
        SimulationScenario("Old reading (grey)", 110, trend: .stable, stale: true),
        SimulationScenario("No reading", nil),
    ]

    private static let historySteps = 48 // 12 hours at the API's 15 minute spacing
    private static let staleMinutes = 25.0 // comfortably past the 10 minute "old reading" limit

    /// A believable 12 hour history that eases from a gentle wave into the scenario's value.
    public static func build(_ scenario: SimulationScenario, now: Date) -> GlucoseSnapshot {
        guard let target = scenario.mgPerDl else { return GlucoseSnapshot(current: nil, history: []) }

        let latest = scenario.stale ? now.addingTimeInterval(-staleMinutes * 60) : now
        var history: [GlucoseReading] = []

        for i in 0..<historySteps {
            let progress = Double(i) / Double(historySteps - 1)
            var ease = min(max((progress - 0.6) / 0.4, 0), 1)
            ease = ease * ease * (3 - 2 * ease) // smoothstep

            let baseline = 115 + 25 * sin(Double(i) / 5.0)
            let value = (baseline + (target - baseline) * ease).rounded(.toNearestOrEven) // same as C# Math.Round
            let at = latest.addingTimeInterval(-15 * 60 * Double(historySteps - i))
            history.append(reading(at, value, .unknown))
        }

        return GlucoseSnapshot(current: reading(latest, target, scenario.trend), history: history)
    }

    private static func reading(_ at: Date, _ mgPerDl: Double, _ trend: Trend) -> GlucoseReading {
        GlucoseReading(
            timestamp: at, mgPerDl: mgPerDl, value: mgPerDl, trend: trend,
            isHigh: mgPerDl > 180, isLow: mgPerDl < 70)
    }
}

/// Developer switches from the command line. They only take effect when the caller says developer features are
/// allowed; a published build does not contain this code at all.
public struct DevOptions: Equatable, Sendable {
    public let enabled: Bool
    public let scenario: Int?

    public static let none = DevOptions(enabled: false, scenario: nil)

    public init(enabled: Bool, scenario: Int?) {
        self.enabled = enabled
        self.scenario = scenario
    }

    /// `--dev` turns developer mode on. `--simulate N` also turns it on and starts with scenario N showing.
    /// - Parameter allowed: false in builds where developer features must never appear: the result is then always `.none`.
    public static func parse(_ args: [String], allowed: Bool) -> DevOptions {
        if !allowed { return .none }

        let dev = args.contains { $0.lowercased() == "--dev" }

        var scenario: Int?
        if let flag = args.firstIndex(where: { $0.lowercased() == "--simulate" }), flag + 1 < args.count,
           let n = Int(args[flag + 1]), n >= 0, n < Simulation.scenarios.count
        {
            scenario = n
        }

        return DevOptions(enabled: dev || scenario != nil, scenario: scenario)
    }
}

#endif
