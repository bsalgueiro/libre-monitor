import Foundation

// Port of src/LibreMonitor.Core/GlucoseMonitor.cs

public struct MonitorUpdate: Sendable {
    public let patient: Patient
    public let snapshot: GlucoseSnapshot
    public let fetchedAt: Date

    public init(patient: Patient, snapshot: GlucoseSnapshot, fetchedAt: Date) {
        self.patient = patient
        self.snapshot = snapshot
        self.fetchedAt = fetchedAt
    }
}

/// Polls LibreLinkUp on a fixed interval and reports each result through callbacks.
/// The callbacks run on a background thread. Read-only: it only logs in and fetches.
public final class GlucoseMonitor: @unchecked Sendable {
    /// The phone uploads about once a minute, so polling faster than this gains nothing.
    public static let defaultInterval: TimeInterval = 60

    public typealias Credentials = @Sendable () -> (email: String, password: String)

    private let client: LibreLinkUpClient
    private let credentials: Credentials
    private let interval: TimeInterval

    private var task: Task<Void, Never>?
    private var patient: Patient?

    /// A poll succeeded.
    public var onUpdate: (@Sendable (MonitorUpdate) -> Void)?

    /// A poll failed. `fatal` failures stop the monitor; the rest are retried on the next tick.
    public var onFailure: (@Sendable (Error, _ fatal: Bool) -> Void)?

    public init(
        client: LibreLinkUpClient,
        credentials: @escaping Credentials,
        interval: TimeInterval = GlucoseMonitor.defaultInterval)
    {
        self.client = client
        self.credentials = credentials
        self.interval = interval
    }

    public func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    public func stop() async {
        let running = task
        task = nil
        running?.cancel()
        await running?.value
    }

    /// Polls again right away, for example after the Mac wakes from sleep.
    public func refreshNow() {
        guard task != nil else { return }
        task?.cancel()
        task = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        while !Task.isCancelled {
            guard await pollOnce() else { return }

            do {
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            } catch {
                return // cancelled
            }
        }
    }

    /// - Returns: false when a fatal error (or cancellation) means polling should stop.
    private func pollOnce() async -> Bool {
        do {
            let loggedIn = await client.isLoggedIn
            if !loggedIn {
                let login = credentials()
                try await client.login(email: login.email, password: login.password)
            }

            // The followed person is looked up once and cached; only the graph is fetched on later ticks.
            if patient == nil {
                guard let first = try await client.getPatients().first else {
                    throw LibreLinkUpError.other("This account is not following anyone yet.")
                }
                patient = first
            }

            guard let who = patient else { return true }
            let snapshot = try await client.getGraph(patientId: who.patientId)
            onUpdate?(MonitorUpdate(patient: who, snapshot: snapshot, fetchedAt: Date()))
            return true
        } catch is CancellationError {
            return false
        } catch let error as LibreLinkUpError {
            switch error {
            case .invalidCredentials, .accountActionRequired:
                onFailure?(error, true)
                return false
            default:
                // Session expiry already cleared the token, so the next tick logs in again.
                onFailure?(error, false)
                return true
            }
        } catch {
            if Task.isCancelled { return false }
            onFailure?(error, false)
            return true
        }
    }
}
