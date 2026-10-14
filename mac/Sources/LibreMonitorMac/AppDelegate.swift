import AppKit
import Combine
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
    private let aboutController = AboutWindowController()
    private var tickTimer: Timer?
    private var settingsObserver: AnyCancellable?
    private var lastScrollChange = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = makePanel()
        statusItem = StatusItemController(
            isWidgetVisible: { [weak self] in self?.panel.isVisible ?? false },
            toggleWidget: { [weak self] in self?.toggleWidget() },
            quit: { NSApp.terminate(nil) })
        applySettings(model.settings)
        settingsObserver = model.$settings.sink { [weak self] settings in
            // @Published fires before the value is stored, so use the value it hands over and refresh afterwards.
            self?.applySettings(settings)
            Task { @MainActor in self?.refreshStatusItem() }
        }

        observeWake()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }

        #if DEBUG
        // Developer mode (Debug builds only): --simulate N starts with scenario N showing.
        let dev = DevOptions.parse(CommandLine.arguments, allowed: true)
        model.devEnabled = dev.enabled
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
            close: { [weak self] in self?.closeWidget() },
            moveToCorner: { [weak self] corner in self?.moveToCorner(corner) },
            hideToMenuBar: { [weak self] in self?.hideToMenuBar() },
            showAbout: { [weak self] in self?.showAbout() },
            signOut: { [weak self] in self?.signOutAndQuit() },
            quit: { NSApp.terminate(nil) })
        panel.contentView = WidgetPanel.makeContent(rootView: WidgetView(model: model, actions: actions))
        panel.onScroll = { [weak self] delta in self?.scrolled(delta) }

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
        if panel.isVisible { hideToMenuBar() } else { panel.orderFrontRegardless() }
    }

    /// The close button: with the menu bar icon shown it hides there; without one, hiding would strand the app, so it quits.
    private func closeWidget() {
        if model.settings.showStatusIcon { hideToMenuBar() } else { NSApp.terminate(nil) }
    }

    /// The widget is only ever hidden while the menu bar item is there to bring it back.
    private func hideToMenuBar() {
        guard model.settings.showStatusIcon else { return }
        panel.orderOut(nil)
    }

    private func moveToCorner(_ corner: Corner) {
        guard let area = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }

        let inset: CGFloat = 16
        let size = panel.frame.size
        let x = corner.isLeft ? area.minX + inset : area.maxX - size.width - inset
        let y = corner.isTop ? area.maxY - size.height - inset : area.minY + inset
        panel.setFrameOrigin(NSPoint(x: x, y: y)) // the frame autosave remembers the new place
    }

    /// Scrolling over the widget steps the graph range between 3, 6 and 12 hours, like the Windows wheel.
    private func scrolled(_ delta: CGFloat) {
        // A trackpad flick sends a long stream of events; one step per gesture is enough.
        guard abs(delta) > 0.5, Date().timeIntervalSince(lastScrollChange) > 0.3 else { return }

        let choices = [3, 6, 12]
        let index = choices.firstIndex(of: model.settings.hours) ?? 1
        let next = min(max(index + (delta > 0 ? -1 : 1), 0), choices.count - 1)
        guard next != index else { return }

        model.settings.hours = choices[next]
        lastScrollChange = Date()
    }

    private func applySettings(_ settings: WidgetSettings) {
        panel.level = settings.alwaysOnTop ? .floating : .normal
        statusItem.isVisible = settings.showStatusIcon

        switch settings.theme {
        case .system: panel.appearance = nil
        case .light: panel.appearance = NSAppearance(named: .aqua)
        case .dark: panel.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func showAbout() {
        aboutController.show()
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
