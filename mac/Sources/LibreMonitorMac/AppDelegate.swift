import AppKit
import LibreMonitorKit
import SwiftUI

/// Hands the follower login to the polling thread. The monitor asks for it whenever it has to sign in again.
final class CredentialBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = (email: "", password: "")

    func set(_ credentials: (email: String, password: String)) {
        lock.lock(); defer { lock.unlock() }
        stored = credentials
    }

    func get() -> (email: String, password: String) {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let client = LibreLinkUpClient()
    private let credentials = CredentialBox()

    private var monitor: GlucoseMonitor?
    private var panel: WidgetPanel!
    private var statusItem: StatusItemController!
    private var loginController: LoginWindowController?
    private var tickTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = makePanel()
        statusItem = StatusItemController(
            isWidgetVisible: { [weak self] in self?.panel.isVisible ?? false },
            toggleWidget: { [weak self] in self?.toggleWidget() },
            quit: { NSApp.terminate(nil) })
        statusItem.isVisible = model.settings.showStatusIcon

        observeWake()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        #if DEBUG
        // Developer mode (Debug builds only): --simulate N starts with scenario N showing.
        let dev = DevOptions.parse(CommandLine.arguments, allowed: true)
        if let scenario = dev.scenario {
            model.simulate(Simulation.scenarios[scenario])
        }
        #endif

        panel.orderFrontRegardless()
        refreshStatusItem()

        if let saved = KeychainStore.load() {
            credentials.set(saved)
            startMonitoring()
        } else if !model.isSimulated {
            showLogin()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tickTimer?.invalidate()
    }

    // MARK: - Widget window

    private func makePanel() -> WidgetPanel {
        let panel = WidgetPanel()
        let actions = WidgetActions(
            signOut: { [weak self] in self?.signOutAndQuit() },
            quit: { NSApp.terminate(nil) })
        panel.contentView = WidgetPanel.makeContent(rootView: WidgetView(model: model, actions: actions))

        let name = "LibreMonitorWidget"
        if !panel.setFrameUsingName(name) {
            // First launch: bottom-right corner of the main screen's usable area.
            if let area = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: area.maxX - panel.frame.width - 16, y: area.minY + 16))
            }
        }
        panel.setFrameAutosaveName(name) // remembers position and size from now on
        return panel
    }

    private func toggleWidget() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard monitor == nil else { return }

        let box = credentials
        let monitor = GlucoseMonitor(client: client, credentials: { box.get() })
        monitor.onUpdate = { [weak self] update in
            Task { @MainActor in
                self?.model.apply(update)
                self?.refreshStatusItem()
            }
        }
        monitor.onFailure = { [weak self] _, fatal in
            Task { @MainActor in
                self?.model.fail(fatal: fatal)
                self?.refreshStatusItem()
            }
        }
        monitor.start()
        self.monitor = monitor
    }

    private func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The Mac was asleep, so the data is stale: poll again right away.
            Task { @MainActor in self?.monitor?.refreshNow() }
        }
    }

    private func tick() {
        model.tick()
        refreshStatusItem()
    }

    private func refreshStatusItem() {
        let unit = model.settings.unit
        guard let current = model.current else {
            statusItem.update(text: "?", tile: TileColors.muted, tooltip: "Libre Monitor: no reading")
            return
        }

        let value = GlucoseUnits.format(current.mgPerDl, unit: unit)
        let greyed = model.isStale || model.problem != nil
        let tile = greyed ? TileColors.muted : TileColors.color(forMgPerDl: current.mgPerDl)
        let age = formatAge(model.age ?? 0)
        let prefix = model.isSimulated ? "SIMULATED · " : ""
        statusItem.update(
            text: value, tile: tile,
            tooltip: "\(prefix)\(value) \(unit.label) \(current.trend.arrow) · \(age)")
    }

    // MARK: - Sign in and out

    private func showLogin() {
        let controller = LoginWindowController(
            signIn: { [weak self] email, password in
                await self?.signIn(email: email, password: password) ?? "Sign-in failed."
            },
            onCancel: { NSApp.terminate(nil) })
        loginController = controller
        controller.show()
    }

    /// - Returns: a message to show in the dialog, or nil when signing in worked.
    private func signIn(email: String, password: String) async -> String? {
        do {
            try await client.login(email: email, password: password)
            try KeychainStore.save(email: email, password: password)
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        credentials.set((email: email, password: password))
        loginController?.close()
        loginController = nil
        startMonitoring()
        return nil
    }

    private func signOutAndQuit() {
        Task { @MainActor in
            await monitor?.stop()
            KeychainStore.clear()
            NSApp.terminate(nil)
        }
    }
}
