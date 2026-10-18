import AppKit
import LibreMonitorKit
import SwiftUI

/// Edits every alert, one tab per kind (glucose, insulin, sensor), and the switch that pauses them all. There is no Save:
/// each change is applied as it is made (text fields when you leave them or press Return), and a value that is not valid
/// is explained and left unapplied until it is fixed. Glucose thresholds are edited in the unit the widget displays and
/// converted to mg/dL for storage.
/// Port of windows/src/LibreMonitor.App/AlertsWindow.xaml(.cs).
struct AlertsView: View {
    /// The app's own state. "Pause all alerts" is read from and written to it directly, so this checkbox and the widget
    /// menu are the same setting: either one changes the other at once.
    @ObservedObject var model: AppModel
    let unit: GlucoseUnit
    /// Sends a sample notification (and plays the sound if asked); reports whether one could be shown.
    let sendTest: (Bool, @escaping (Bool) -> Void) -> Void
    /// Each of these is called every time a valid change is made.
    let applyAlerts: (AlertSettings) -> Void
    let applyInsulin: (InsulinSettings) -> Void
    let applySensor: (SensorAlertSettings) -> Void
    let close: () -> Void

    private var paused: Bool { model.settings.alertsPaused }

    // What has been applied so far. The text-as-first-shown trick keeps a threshold left untouched at its exact stored
    // value, so opening the window in mmol/L never nudges 70 mg/dL to 70.3 through rounding.
    @State private var appliedAlerts: AlertSettings
    @State private var appliedInsulin: InsulinSettings
    @State private var lowShown: String
    @State private var highShown: String

    @State private var lowEnabled: Bool
    @State private var highEnabled: Bool
    @State private var lowText: String
    @State private var highText: String
    @State private var repeatMinutes: Int
    @State private var sound: Bool
    @State private var insulinEnabled: Bool
    @State private var dosesPerDay: Int
    @State private var firstDose: Date
    @State private var secondDose: Date
    @State private var insulinRepeatMinutes: Int
    @State private var sensorEnabled: Bool
    @State private var sensorDays: Int
    @State private var sensorRepeat: Int
    @State private var info: String?
    @State private var errors: [String: String] = [:]

    private enum Field: Hashable { case low, high }
    @FocusState private var focus: Field?
    @State private var lastFocus: Field?

    private struct RepeatChoice: Identifiable {
        let minutes: Int
        let label: String
        var id: Int { minutes }
    }

    private static let repeatChoices = [
        RepeatChoice(minutes: 0, label: "Never (alert once)"),
        RepeatChoice(minutes: 15, label: "Every 15 minutes"),
        RepeatChoice(minutes: 30, label: "Every 30 minutes"),
        RepeatChoice(minutes: 60, label: "Every hour"),
    ]

    /// A time of day as a date today, for the time pickers.
    private static func date(minutes: Int) -> Date {
        let start = Calendar.current.startOfDay(for: Date())
        return Calendar.current.date(byAdding: .minute, value: minutes, to: start) ?? start
    }

    private static func minutes(of date: Date) -> Int {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    private static func sensorRepeatLabel(_ minutes: Int) -> String {
        switch minutes {
        case 1440: return "Once a day"
        case 360: return "Every 6 hours"
        case 60: return "Every hour"
        default: return "Every \(minutes) minutes"
        }
    }

    init(
        model: AppModel, unit: GlucoseUnit, original: AlertSettings, insulin: InsulinSettings, sensor: SensorAlertSettings,
        sendTest: @escaping (Bool, @escaping (Bool) -> Void) -> Void,
        applyAlerts: @escaping (AlertSettings) -> Void, applyInsulin: @escaping (InsulinSettings) -> Void,
        applySensor: @escaping (SensorAlertSettings) -> Void, close: @escaping () -> Void)
    {
        self.model = model
        self.unit = unit
        self.sendTest = sendTest
        self.applyAlerts = applyAlerts
        self.applyInsulin = applyInsulin
        self.applySensor = applySensor
        self.close = close

        let low = GlucoseUnits.format(original.lowMgPerDl, unit: unit)
        let high = GlucoseUnits.format(original.highMgPerDl, unit: unit)
        _appliedAlerts = State(initialValue: original)
        _appliedInsulin = State(initialValue: insulin)
        _lowShown = State(initialValue: low)
        _highShown = State(initialValue: high)

        _lowEnabled = State(initialValue: original.lowEnabled)
        _highEnabled = State(initialValue: original.highEnabled)
        _lowText = State(initialValue: low)
        _highText = State(initialValue: high)
        _sound = State(initialValue: original.sound)
        // The stored interval may not be one of the choices; pick the nearest.
        let nearest = Self.repeatChoices.min { abs($0.minutes - original.repeatMinutes) < abs($1.minutes - original.repeatMinutes) }
        _repeatMinutes = State(initialValue: nearest?.minutes ?? 30)

        _insulinEnabled = State(initialValue: insulin.enabled)
        _dosesPerDay = State(initialValue: insulin.dosesPerDay == 2 ? 2 : 1)
        _firstDose = State(initialValue: Self.date(minutes: insulin.firstDoseMinutes))
        _secondDose = State(initialValue: Self.date(minutes: insulin.secondDoseMinutes))
        let nearestInsulin = Self.repeatChoices.min {
            abs($0.minutes - insulin.repeatMinutes) < abs($1.minutes - insulin.repeatMinutes)
        }
        _insulinRepeatMinutes = State(initialValue: nearestInsulin?.minutes ?? 30)

        _sensorEnabled = State(initialValue: sensor.enabled)
        _sensorDays = State(initialValue: min(max(sensor.daysBefore, 1), SensorAlertSettings.maxDaysBefore))
        let nearestRepeat = SensorAlertSettings.repeatChoices.min {
            abs($0 - sensor.repeatMinutes) < abs($1 - sensor.repeatMinutes)
        }
        _sensorRepeat = State(initialValue: nearestRepeat ?? 1440)
    }

    // The inputs of each group, so one change handler per group is enough.
    private struct GlucoseInputs: Equatable {
        var lowEnabled: Bool
        var highEnabled: Bool
        var repeatMinutes: Int
    }

    private struct InsulinInputs: Equatable {
        var enabled: Bool
        var doses: Int
        var first: Date
        var second: Date
        var repeatMinutes: Int
    }

    private struct SensorInputs: Equatable {
        var enabled: Bool
        var days: Int
        var repeatMinutes: Int
    }

    private var glucoseInputs: GlucoseInputs { GlucoseInputs(lowEnabled: lowEnabled, highEnabled: highEnabled, repeatMinutes: repeatMinutes) }

    private var insulinInputs: InsulinInputs {
        InsulinInputs(enabled: insulinEnabled, doses: dosesPerDay, first: firstDose, second: secondDose, repeatMinutes: insulinRepeatMinutes)
    }

    private var sensorInputs: SensorInputs { SensorInputs(enabled: sensorEnabled, days: sensorDays, repeatMinutes: sensorRepeat) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Pause all alerts", isOn: $model.settings.alertsPaused).fontWeight(.semibold)
                Text("Nothing will notify you until you untick this. It is the same as \"Snooze alerts > Until I turn them "
                    + "back on\" in the widget menu. Changes here are applied as you make them.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading, 20)
            }

            TabView {
                tabContent { glucoseTab }.tabItem { Text("Glucose") }
                tabContent { insulinSection }.tabItem { Text("Insulin") }
                tabContent { sensorTab }.tabItem { Text("Sensor") }
            }
            .frame(height: 410)

            Toggle("Play a sound", isOn: $sound)
                .disabled(paused)
                .opacity(paused ? 0.45 : 1)

            if let info {
                Text(info).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let message = errors.sorted(by: { $0.key < $1.key }).first?.value {
                Text(message).font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Send test alert") { runTest() }.disabled(paused)
                Spacer()
                Button("Close") { close() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 470)
        .onChange(of: glucoseInputs) { _ in applyGlucose() }
        .onChange(of: insulinInputs) { _ in applyInsulinChanges() }
        .onChange(of: sensorInputs) { _ in applySensorChanges() }
        .onChange(of: sound) { _ in applySound() }
        .onChange(of: focus) { newField in
            // A text field was left: apply what was typed into it.
            if let previous = lastFocus, previous != newField { applyGlucose() }
            lastFocus = newField
        }
    }

    /// One tab's content: scrolls if it is taller than the tab, and is greyed out and disabled while everything is paused.
    private func tabContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 14)
                .padding(.horizontal, 6)
        }
        .disabled(paused)
        .opacity(paused ? 0.45 : 1)
    }

    private var glucoseTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Get a notification when a reading goes below or above your own limits. Both are off until you turn them on.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            limitRow("Alert when glucose goes below", isOn: $lowEnabled, text: $lowText, field: .low)
            limitRow("Alert when glucose goes above", isOn: $highEnabled, text: $highText, field: .high)

            Picker("While still out of range, remind me", selection: $repeatMinutes) {
                ForEach(Self.repeatChoices) { Text($0.label).tag($0.minutes) }
            }

            Text("Alerts only work while this app is running, your Mac is awake, and your phone is uploading. Readings can "
                + "arrive minutes late, and macOS may hide notifications (for example in a Focus mode). Do not rely on this "
                + "for safety: keep your sensor's own alarms on.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sensorTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Get a notification as your sensor gets close to its end. It is on by default.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Alert me before my sensor ends", isOn: $sensorEnabled).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Picker("Start alerting", selection: $sensorDays) {
                    ForEach(1...SensorAlertSettings.maxDaysBefore, id: \.self) {
                        Text($0 == 1 ? "1 day before" : "\($0) days before").tag($0)
                    }
                }
                Picker("Then repeat", selection: $sensorRepeat) {
                    ForEach(SensorAlertSettings.repeatChoices, id: \.self) { Text(Self.sensorRepeatLabel($0)).tag($0) }
                }
            }
            .padding(.leading, 20)
            .disabled(!sensorEnabled)
            .opacity(sensorEnabled ? 1 : 0.5)

            Text("The end date is an estimate: the sensor's start plus its duration. Set the duration (14 or 15 days) in the "
                + "widget menu, under Sensor duration.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var insulinSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("A reminder at your usual time, and a syringe icon on the widget to tap once the dose is administered, so you "
                + "can check later whether you already did. Off until you turn it on.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Remind me to administer my insulin", isOn: $insulinEnabled).fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $dosesPerDay) {
                    Text("Once a day").tag(1)
                    Text("Twice a day").tag(2)
                }
                .labelsHidden()
                .frame(width: 190)

                DatePicker(dosesPerDay == 2 ? "First time" : "Time", selection: $firstDose, displayedComponents: .hourAndMinute)
                    .frame(width: 230)
                if dosesPerDay == 2 {
                    DatePicker("Second time", selection: $secondDose, displayedComponents: .hourAndMinute)
                        .frame(width: 230)
                }

                Picker("If not marked as administered, remind me", selection: $insulinRepeatMinutes) {
                    ForEach(Self.repeatChoices) { Text($0.label.replacingOccurrences(of: "alert once", with: "remind once")).tag($0.minutes) }
                }
            }
            .padding(.leading, 20)
            .disabled(!insulinEnabled)
            .opacity(insulinEnabled ? 1 : 0.5)

            Text("This is a memory aid only. It cannot know about a dose you did not tap, it does not record amounts, and it "
                + "gives no dosing advice. Reminders stop 6 hours after the dose time. Follow your care team's instructions.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func limitRow(_ title: String, isOn: Binding<Bool>, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn).fontWeight(.semibold)
            HStack {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($focus, equals: field)
                    .onSubmit { applyGlucose() }
                Text(unit.label).foregroundColor(.secondary)
            }
            .padding(.leading, 20)
        }
    }

    // MARK: - Applying changes

    private func setError(_ group: String, _ message: String?) {
        errors[group] = message
        info = nil
    }

    private func runTest() {
        info = nil
        sendTest(sound) { shown in
            info = shown
                ? "Test sent. If you saw nothing, check System Settings > Notifications and any Focus mode."
                : "No notification could be shown. Check System Settings > Notifications > Libre Monitor Desktop. "
                    + "Alerts still use the sound and the card's coloured border."
        }
    }

    /// The value in mg/dL, or nil (with the problem set) when the text is not a number. Untouched text keeps its exact value.
    private func read(_ text: String, shown: String, original: Double, name: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == shown { return original }

        // Accept either decimal separator, whatever the macOS language, since people type both.
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
            setError("glucose", "Enter a number for the \(name) threshold.")
            return nil
        }

        return unit == .mmolPerL ? ((value * GlucoseUnits.mgPerDlPerMmolPerL) * 10).rounded() / 10 : value
    }

    private func applyGlucose() {
        guard let low = read(lowText, shown: lowShown, original: appliedAlerts.lowMgPerDl, name: "low"),
              let high = read(highText, shown: highShown, original: appliedAlerts.highMgPerDl, name: "high")
        else { return } // read has said what is wrong

        let settings = AlertSettings(
            lowEnabled: lowEnabled, lowMgPerDl: low, highEnabled: highEnabled, highMgPerDl: high,
            repeatMinutes: repeatMinutes, sound: sound)

        if let problem = settings.validate(unit: unit) {
            setError("glucose", problem)
            return
        }

        setError("glucose", nil)
        appliedAlerts = settings
        lowShown = lowText.trimmingCharacters(in: .whitespaces)
        highShown = highText.trimmingCharacters(in: .whitespaces)
        applyAlerts(settings)
    }

    /// The sound is applied on its own, so a threshold that is half edited and not valid yet cannot hold it back.
    private func applySound() {
        appliedAlerts.sound = sound
        applyAlerts(appliedAlerts)
    }

    private func applyInsulinChanges() {
        // The "administered" mark belongs to the app, not this window, and is merged in by whoever applies this.
        var insulin = appliedInsulin
        insulin.enabled = insulinEnabled
        insulin.dosesPerDay = dosesPerDay
        insulin.firstDoseMinutes = Self.minutes(of: firstDose)
        if dosesPerDay == 2 { insulin.secondDoseMinutes = Self.minutes(of: secondDose) }
        insulin.repeatMinutes = insulinRepeatMinutes

        if insulin.enabled, let problem = insulin.validate() {
            setError("insulin", problem)
            return
        }

        setError("insulin", nil)
        appliedInsulin = insulin
        applyInsulin(insulin)
    }

    private func applySensorChanges() {
        let sensor = SensorAlertSettings(enabled: sensorEnabled, daysBefore: sensorDays, repeatMinutes: sensorRepeat)
        if let problem = sensor.validate() {
            setError("sensor", problem)
            return
        }

        setError("sensor", nil)
        applySensor(sensor)
    }
}

@MainActor
final class AlertsWindowController {
    private var window: NSWindow?

    func show(
        model: AppModel, unit: GlucoseUnit, settings: AlertSettings, insulin: InsulinSettings, sensor: SensorAlertSettings,
        sendTest: @escaping (Bool, @escaping (Bool) -> Void) -> Void,
        applyAlerts: @escaping (AlertSettings) -> Void, applyInsulin: @escaping (InsulinSettings) -> Void,
        applySensor: @escaping (SensorAlertSettings) -> Void)
    {
        window?.close()

        let view = AlertsView(
            model: model, unit: unit, original: settings, insulin: insulin, sensor: sensor, sendTest: sendTest,
            applyAlerts: applyAlerts, applyInsulin: applyInsulin, applySensor: applySensor,
            close: { [weak self] in self?.window?.close() })

        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Alerts"
        window.styleMask = [.titled, .closable]
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
