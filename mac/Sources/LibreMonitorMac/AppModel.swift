import Combine
import Foundation
import LibreMonitorKit

/// Everything the widget shows. Owned by the app delegate, observed by the SwiftUI views.
@MainActor
final class AppModel: ObservableObject {
    enum Problem {
        case reconnecting
        case signInNeeded
    }

    /// A reading older than this is shown as "old" (the same limit the alerts use).
    static let staleAfter: TimeInterval = 10 * 60

    @Published private(set) var realUpdate: MonitorUpdate?
    @Published private(set) var problem: Problem?
    /// Refreshed on a timer so the age text and the graph's "now" edge keep moving between polls.
    @Published private(set) var now = Date()
    @Published var settings: WidgetSettings {
        didSet { SettingsStore.save(settings) }
    }

    #if DEBUG
    /// Developer mode: a fake reading standing in for the real one. Never exists in a Release build.
    @Published private(set) var simulation: SimulationScenario?
    @Published private(set) var simulatedUpdate: MonitorUpdate?
    #endif

    init(settings: WidgetSettings = SettingsStore.load()) {
        self.settings = settings
    }

    // MARK: - What to show

    var isSimulated: Bool {
        #if DEBUG
        return simulation != nil
        #else
        return false
        #endif
    }

    var displayUpdate: MonitorUpdate? {
        #if DEBUG
        if simulation != nil { return simulatedUpdate }
        #endif
        return realUpdate
    }

    var current: GlucoseReading? { displayUpdate?.snapshot.current }

    /// History plus the current reading when it is newer than the last history sample.
    var readings: [GlucoseReading] {
        guard let snapshot = displayUpdate?.snapshot else { return [] }

        var list = snapshot.history
        if let current = snapshot.current, list.last.map({ current.timestamp > $0.timestamp }) ?? true {
            list.append(current)
        }
        return list
    }

    var age: TimeInterval? { current.map { now.timeIntervalSince($0.timestamp) } }

    var isStale: Bool { (age ?? 0) > Self.staleAfter }

    var patientName: String? {
        displayUpdate.map { "\($0.patient.firstName) \($0.patient.lastName)" }
    }

    // MARK: - Updates

    func apply(_ update: MonitorUpdate) {
        realUpdate = update
        problem = nil
    }

    func fail(fatal: Bool) {
        problem = fatal ? .signInNeeded : .reconnecting
    }

    func tick() {
        now = Date()
        #if DEBUG
        // Rebuilt each tick so a simulated reading does not age into the grey "old reading" state.
        if let simulation { simulatedUpdate = Self.makeSimulatedUpdate(simulation, at: now) }
        #endif
    }

    #if DEBUG
    func simulate(_ scenario: SimulationScenario?) {
        simulation = scenario
        simulatedUpdate = scenario.map { Self.makeSimulatedUpdate($0, at: Date()) }
    }

    private static func makeSimulatedUpdate(_ scenario: SimulationScenario, at date: Date) -> MonitorUpdate {
        MonitorUpdate(
            patient: Patient(patientId: "simulated", firstName: "Simulated", lastName: "data"),
            snapshot: Simulation.build(scenario, now: date),
            fetchedAt: date)
    }
    #endif
}
