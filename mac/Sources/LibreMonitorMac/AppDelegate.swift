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
    private let alertsController = AlertsWindowController()
    private let alertEvaluator = AlertEvaluator()
    private let insulinEvaluator = InsulinReminderEvaluator()
    private let sensorEvaluator = SensorExpiryEvaluator()
    private var lastAlertSettings = AlertSettings()
    private var lastInsulinSettings = InsulinSettings()
    private var lastSensorAlert = SensorAlertSettings()
    private var lastPaused = false
    private var tickTimer: Timer?
    private var settingsObserver: AnyCancellable?
    private var lastScrollChange = Date.distantPast
    private var graphShown = true

    // Each mode (graph shown or hidden) remembers its own size, so turning the graph back on restores the layout.
    private static let graphSizeKey = "widgetSize.graph"
    private static let compactSizeKey = "widgetSize.compact"
    private static let graphMinSize = NSSize(width: 224, height: 148)
    private static let compactMinSize = NSSize(width: 190, height: 100) // below this the unit and status text are too small
    private static let graphDefaultSize = NSSize(width: 280, height: 172)
    private static let compactDefaultSize = NSSize(width: 260, height: 132)

    func applicationDidFinishLaunching(_ notification: Notification) {
        Notifier.shared.start()
        lastAlertSettings = model.settings.alerts
        lastInsulinSettings = model.settings.insulin
        lastSensorAlert = model.settings.sensorAlert
        lastPaused = model.settings.alertsPaused
        if lastPaused { alertEvaluator.snooze(until: .distantFuture) } // alerts stay paused across restarts until turned back on
        panel = makePanel()
        statusItem = StatusItemController(
            isWidgetVisible: { [weak self] in self?.panel.isVisible ?? false },
            toggleWidget: { [weak self] in self?.toggleWidget() },
            quit: { NSApp.terminate(nil) })
        graphShown = model.settings.showGraph
        panel.minSize = graphShown ? Self.graphMinSize : Self.compactMinSize
        if !graphShown, !UserDefaults.standard.bool(forKey: "widgetSize.compact.initialised") {
            // First run with the graph hidden: the remembered frame is the graph-sized one, so start from a compact size.
            applyGraphMode(show: false, force: true)
        }

        applySettings(model.settings)
        settingsObserver = model.$settings.sink { [weak self] settings in
            // @Published fires before the value is stored, so use the value it hands over and refresh afterwards.
            self?.applySettings(settings)
            if settings.alerts != self?.lastAlertSettings {
                // New limits start a fresh episode.
                self?.lastAlertSettings = settings.alerts
                self?.alertEvaluator.reset()
            }
            if settings.insulin != self?.lastInsulinSettings {
                self?.lastInsulinSettings = settings.insulin
                self?.insulinEvaluator.reset()
            }
            if settings.sensorAlert != self?.lastSensorAlert {
                self?.lastSensorAlert = settings.sensorAlert
                self?.sensorEvaluator.reset()
            }
            if settings.alertsPaused != self?.lastPaused {
                // A pause is a snooze with no end, so every alert that follows the shared snooze stops, and raises
                // again as soon as the pause is lifted.
                self?.lastPaused = settings.alertsPaused
                if settings.alertsPaused {
                    self?.alertEvaluator.snooze(until: .distantFuture)
                } else {
                    self?.alertEvaluator.resume()
                    self?.model.snoozedUntil = nil
                }
            }
            Task { @MainActor in
                self?.refreshStatusItem()
                self?.evaluateAlerts()
                self?.evaluateInsulin()
                self?.evaluateSensor() // the chosen sensor duration may have changed
            }
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
            showAlerts: { [weak self] in self?.showAlerts() },
            toggleInsulin: { [weak self] in self?.toggleInsulin() },
            pauseAlerts: { [weak self] in self?.model.settings.alertsPaused = true },
            refreshNow: { [weak self] in self?.refreshNow() },
            snoozeAlerts: { [weak self] minutes in self?.snoozeAlerts(minutes: minutes) },
            resumeAlerts: { [weak self] in self?.resumeAlerts() },
            checkForUpdates: { NSWorkspace.shared.open(AppInfo.releasesUrl) },
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
        // The range only affects the graph. A trackpad flick sends a long stream of events; one step per gesture is enough.
        guard graphShown, abs(delta) > 0.5, Date().timeIntervalSince(lastScrollChange) > 0.3 else { return }

        let choices = [3, 6, 12]
        let index = choices.firstIndex(of: model.settings.hours) ?? 1
        let next = min(max(index + (delta > 0 ? -1 : 1), 0), choices.count - 1)
        guard next != index else { return }

        model.settings.hours = choices[next]
        lastScrollChange = Date()
    }

    /// Switches between the graph layout and the compact (value only) layout, keeping the widget's top-left corner.
    private func applyGraphMode(show: Bool, force: Bool = false) {
        guard force || show != graphShown else { return }

        let defaults = UserDefaults.standard
        // Remember the size of the mode being left (unless this is the very first compact start, where it is not meaningful).
        if !force {
            defaults.set(NSStringFromSize(panel.frame.size), forKey: graphShown ? Self.graphSizeKey : Self.compactSizeKey)
        }

        graphShown = show
        panel.minSize = show ? Self.graphMinSize : Self.compactMinSize

        let key = show ? Self.graphSizeKey : Self.compactSizeKey
        let fallback = show ? Self.graphDefaultSize : Self.compactDefaultSize
        var target = defaults.string(forKey: key).map(NSSizeFromString) ?? fallback
        target.width = max(target.width, panel.minSize.width)
        target.height = max(target.height, panel.minSize.height)

        let old = panel.frame
        let frame = NSRect(x: old.minX, y: old.maxY - target.height, width: target.width, height: target.height)
        panel.setFrame(frame, display: true, animate: !force)
        defaults.set(true, forKey: "widgetSize.compact.initialised")
    }

    private func applySettings(_ settings: WidgetSettings) {
        applyGraphMode(show: settings.showGraph)
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
                self?.evaluateAlerts()
                self?.evaluateSensor()
            }
        }
        monitor.onFailure = { [weak self] _, fatal in
            Task { @MainActor in
                self?.model.fail(fatal: fatal)
                self?.refreshStatusItem()
            }
        }
        monitor.onServiceChanged = { [weak self] _ in
            // LibreLinkUp has changed or blocked this client. The widget says so, a notification appears once (clicking
            // it opens the releases page), and the right-click menu has "Check for updates…".
            Task { @MainActor in
                #if DEBUG
                if self?.model.isSimulated == true { return }
                #endif
                self?.model.markServiceChanged()
                self?.refreshStatusItem()
                Notifier.shared.post(
                    title: "Can't read LibreLinkUp",
                    body: "Abbott may have changed or blocked the service. Click here to look for a newer version of Libre Monitor Desktop.",
                    sound: false, openURL: AppInfo.releasesUrl)
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

    /// Double-clicking the value fetches a new reading now, instead of waiting for the next minute.
    private func refreshNow() {
        // A fake reading has nothing to refresh. The monitor itself refuses refreshes that come too soon or too often
        // (see GlucoseMonitor.refreshNow), so repeated clicks cannot hammer the unofficial service; they are ignored.
        guard let monitor, !model.isSimulated, monitor.refreshNow() else { return }

        model.refreshingUntil = Date().addingTimeInterval(15)
    }

    private func tick() {
        model.tick()
        refreshStatusItem()
        evaluateAlerts()
        evaluateInsulin() // follows the clock, not the readings, so it runs whatever the glucose state is
        evaluateSensor()
    }

    // MARK: - Sensor

    /// The snooze that holds back insulin and sensor alerts: no end while everything is paused, otherwise the timed snooze.
    private func effectiveSnooze(_ now: Date) -> Date? {
        model.settings.alertsPaused ? .distantFuture : model.snoozedUntil.flatMap { $0 > now ? $0 : nil }
    }

    private func evaluateSensor() {
        let now = Date()
        guard let raised = sensorEvaluator.evaluate(
            model.sensor, now: now, settings: model.settings.sensorAlert, snoozedUntil: effectiveSnooze(now),
            durationDays: model.settings.sensorDurationDays)
        else { return }

        Notifier.shared.post(
            title: "Sensor reminder",
            body: "The sensor is due to end about \(formatDateTime(raised.endsAt)).",
            sound: false)
    }

    // MARK: - Alerts

    private func evaluateAlerts() {
        let now = Date()
        let settings = model.settings.alerts
        let current = model.current

        if let raised = alertEvaluator.evaluate(settings, current, now: now) {
            deliver(raised, now: now)
        }

        model.alertZone = AlertEvaluator.classify(settings, current, now: now)
        if let until = model.snoozedUntil, until <= now { model.snoozedUntil = nil }
    }

    private func deliver(_ alert: AlertRaised, now: Date) {
        let unit = model.settings.unit
        let low = alert.kind == .low
        // One message, however many times it repeats: the title says what it is, the body carries the reading.
        var title = "\(low ? "Low" : "High") glucose alert"
        if model.isSimulated { title = "SIMULATED · " + title }

        let value = GlucoseUnits.format(alert.reading.mgPerDl, unit: unit)
        let body = "\(value) \(unit.label) \(alert.reading.trend.arrow) · \(formatAge(now.timeIntervalSince(alert.reading.timestamp)))"
        let sound = model.settings.alerts.sound

        Notifier.shared.post(title: title, body: body, sound: sound) { posted in
            // Without a notification (refused, or not running as an app) the sound and the card's border still work.
            if !posted && sound { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    // MARK: - Insulin

    private func evaluateInsulin() {
        let now = Date()
        guard let raised = insulinEvaluator.evaluate(
            model.settings.insulin, now: now, calendar: .current, snoozedUntil: effectiveSnooze(now))
        else { return }

        let sound = model.settings.alerts.sound
        let body = "Due at \(clockText(raised.slot)). Not marked as administered yet."
        Notifier.shared.post(title: "Insulin reminder", body: body, sound: sound) { posted in
            if !posted && sound { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    private func clockText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }

    /// Marks the current dose as administered, or removes the mark. Both ask first: a wrong "administered" would hide a missed dose.
    private func toggleInsulin() {
        guard let status = model.insulinStatus else { return }

        let alert = NSAlert()
        alert.alertStyle = .informational
        if status.state == .administered {
            alert.messageText = "Remove the “administered” mark?"
            alert.informativeText = "Insulin administered on \(formatDateTime(status.administeredAt ?? status.slot)).\n"
                + "Only do this if you did not administer it."
            alert.addButton(withTitle: "Remove mark")
        } else {
            alert.messageText = "Mark the \(formatDateTime(status.slot)) insulin dose as administered?"
            alert.addButton(withTitle: "Mark as administered")
        }
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        model.settings.insulin = status.state == .administered
            ? model.settings.insulin.undone()
            : model.settings.insulin.markingAdministered(at: Date())
    }

    private func showAlerts() {
        alertsController.show(
            model: model, unit: model.settings.unit, settings: model.settings.alerts, insulin: model.settings.insulin,
            sensor: model.settings.sensorAlert,
            sendTest: { sound, done in
                Notifier.shared.post(title: "Test alert", body: "This is how an alert will look.", sound: sound) { posted in
                    DispatchQueue.main.async {
                        if !posted && sound { NSSound.beep() }
                        done(posted)
                    }
                }
            },
            onSave: { [weak self] alerts, insulin, sensor in
                guard let self else { return }
                // Re-read the settings now: the pause switch may have been changed (here or in the menu) while the window
                // was open, and Save must not put an old value back.
                var settings = model.settings // one assignment, so the settings are saved once
                settings.alerts = alerts
                settings.insulin = insulin
                settings.sensorAlert = sensor
                model.settings = settings
            })
    }

    private func snoozeAlerts(minutes: Int) {
        guard !model.settings.alertsPaused else { return } // already stopped until turned back on
        let until = Date().addingTimeInterval(TimeInterval(minutes * 60))
        alertEvaluator.snooze(until: until)
        model.snoozedUntil = until
    }

    private func resumeAlerts() {
        model.settings.alertsPaused = false
        alertEvaluator.resume()
        model.snoozedUntil = nil
        evaluateAlerts()
        evaluateInsulin()
        evaluateSensor()
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
        let note = model.problem == .serviceChanged ? " · service changed, check for updates" : ""
        statusItem.update(
            text: value, tile: tile,
            tooltip: "\(prefix)\(value) \(unit.label) \(current.trend.arrow) · \(age)\(note)")
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
