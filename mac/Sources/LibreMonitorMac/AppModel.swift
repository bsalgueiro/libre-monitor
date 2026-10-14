import Combine
import Foundation
import LibreMonitorKit

/// Everything the widget shows. Owned by the app delegate, observed by the SwiftUI views.
@MainActor
final class AppModel: ObservableObject {
    enum Problem {
        case reconnecting
        case signInNeeded
        /// LibreLinkUp keeps answering in a way this version does not understand; a newer version may be needed.
        case serviceChanged
    }

    /// A reading older than this is shown as "old" (the same limit the alerts use).
    static let staleAfter: TimeInterval = 10 * 60

    @Published private(set) var realUpdate: MonitorUpdate?
    @Published private(set) var problem: Problem?
    private var serviceChanged = false

    /// Which alert zone the current reading is in (drives the coloured card border); nil when in range or alerts are off.
    @Published var alertZone: AlertKind?
    /// While set (and in the future), alert notifications are paused. Shown in the menu.
    @Published var snoozedUntil: Date?
    /// Refreshed on a timer so the age text and the graph's "now" edge keep moving between polls.
    @Published private(set) var now = Date()
    @Published var settings: WidgetSettings {
        didSet { SettingsStore.save(settings) }
    }

    #if DEBUG
    /// Developer mode: a fake reading standing in for the real one. Never exists in a Release build.
    @Published private(set) var simulation: SimulationScenario?
    @Published private(set) var simulatedUpdate: MonitorUpdate?
    /// True only when started with --dev (or --simulate N): shows the "simulate reading" menu.
    @Published var devEnabled = false

    /// -1 means real data; otherwise the index into `Simulation.scenarios`. Bound to the developer menu.
    var simulationIndex: Int {
        get { simulation.flatMap { Simulation.scenarios.firstIndex(of: $0) } ?? -1 }
        set { simulate(newValue < 0 ? nil : Simulation.scenarios[newValue]) }
    }
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
        serviceChanged = false // a good answer ends the episode
    }

    func fail(fatal: Bool) {
        // Once the service is known to have changed, keep saying so rather than going back to "reconnecting".
        problem = serviceChanged ? .serviceChanged : (fatal ? .signInNeeded : .reconnecting)
    }

    /// The monitor found the service changed several times in a row. Retrying will not fix that.
    func markServiceChanged() {
        serviceChanged = true
        problem = .serviceChanged
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
