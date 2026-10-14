import AppKit
import LibreMonitorKit
import SwiftUI

/// Edits the alert thresholds in the unit the widget displays. Values are converted to mg/dL for storage.
/// Port of src/LibreMonitor.App/AlertsWindow.xaml(.cs).
struct AlertsView: View {
    let unit: GlucoseUnit
    let original: AlertSettings
    /// Sends a sample notification (and plays the sound if asked); reports whether one could be shown.
    let sendTest: (Bool, @escaping (Bool) -> Void) -> Void
    let save: (AlertSettings) -> Void
    let cancel: () -> Void

    @State private var lowEnabled: Bool
    @State private var highEnabled: Bool
    @State private var lowText: String
    @State private var highText: String
    @State private var repeatMinutes: Int
    @State private var sound: Bool
    @State private var info: String?
    @State private var error: String?

    // The text as first shown is remembered: a threshold left untouched keeps its exact stored value, so opening and
    // saving in mmol/L never nudges 70 mg/dL to 70.3 through rounding.
    private let lowShown: String
    private let highShown: String

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

    init(
        unit: GlucoseUnit, original: AlertSettings,
        sendTest: @escaping (Bool, @escaping (Bool) -> Void) -> Void,
        save: @escaping (AlertSettings) -> Void, cancel: @escaping () -> Void)
    {
        self.unit = unit
        self.original = original
        self.sendTest = sendTest
        self.save = save
        self.cancel = cancel

        let low = GlucoseUnits.format(original.lowMgPerDl, unit: unit)
        let high = GlucoseUnits.format(original.highMgPerDl, unit: unit)
        lowShown = low
        highShown = high

        _lowEnabled = State(initialValue: original.lowEnabled)
        _highEnabled = State(initialValue: original.highEnabled)
        _lowText = State(initialValue: low)
        _highText = State(initialValue: high)
        _sound = State(initialValue: original.sound)
        // The stored interval may not be one of the choices; pick the nearest.
        let nearest = Self.repeatChoices.min { abs($0.minutes - original.repeatMinutes) < abs($1.minutes - original.repeatMinutes) }
        _repeatMinutes = State(initialValue: nearest?.minutes ?? 30)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Glucose alerts").font(.headline)

            Text("Get a notification when a reading goes below or above your own limits. Both are off until you turn them on.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            limitRow("Alert when glucose goes below", isOn: $lowEnabled, text: $lowText)
            limitRow("Alert when glucose goes above", isOn: $highEnabled, text: $highText)

            Picker("While still out of range, remind me", selection: $repeatMinutes) {
                ForEach(Self.repeatChoices) { Text($0.label).tag($0.minutes) }
            }

            Toggle("Play a sound", isOn: $sound)

            Text("Alerts only work while this app is running, your Mac is awake, and your phone is uploading. Readings can "
                + "arrive minutes late, and macOS may hide notifications (for example in a Focus mode). Do not rely on this "
                + "for safety: keep your sensor's own alarms on.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let info {
                Text(info).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error {
                Text(error).font(.callout).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Send test alert") { runTest() }
                Spacer()
                Button("Cancel") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Save") { commit() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private func limitRow(_ title: String, isOn: Binding<Bool>, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn).fontWeight(.semibold)
            HStack {
                TextField("", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                Text(unit.label).foregroundColor(.secondary)
            }
            .padding(.leading, 20)
        }
    }

    // MARK: - Actions

    private func runTest() {
        error = nil
        sendTest(sound) { shown in
            info = shown
                ? "Test sent. If you saw nothing, check System Settings > Notifications and any Focus mode."
                : "No notification could be shown. Check System Settings > Notifications > Libre Monitor. "
                    + "Alerts still use the sound and the card's coloured border."
        }
    }

    /// The value in mg/dL, or nil (with the error set) when the text is not a number. Untouched text keeps its exact value.
    private func read(_ text: String, shown: String, original: Double, name: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == shown { return original }

        // Accept either decimal separator, whatever the macOS language, since people type both.
        guard let value = Double(trimmed.replacingOccurrences(of: ",", with: ".")) else {
            error = "Enter a number for the \(name) threshold."
            return nil
        }

        return unit == .mmolPerL ? ((value * GlucoseUnits.mgPerDlPerMmolPerL) * 10).rounded() / 10 : value
    }

    private func commit() {
        guard let low = read(lowText, shown: lowShown, original: original.lowMgPerDl, name: "low"),
              let high = read(highText, shown: highShown, original: original.highMgPerDl, name: "high")
        else { return }

        let settings = AlertSettings(
            lowEnabled: lowEnabled, lowMgPerDl: low, highEnabled: highEnabled, highMgPerDl: high,
            repeatMinutes: repeatMinutes, sound: sound)

        if let problem = settings.validate(unit: unit) {
            error = problem
            return
        }

        save(settings)
    }
}

@MainActor
final class AlertsWindowController {
    private var window: NSWindow?

    func show(
        unit: GlucoseUnit, settings: AlertSettings,
        sendTest: @escaping (Bool, @escaping (Bool) -> Void) -> Void,
        onSave: @escaping (AlertSettings) -> Void)
    {
        window?.close()

        let view = AlertsView(
            unit: unit, original: settings, sendTest: sendTest,
            save: { [weak self] new in
                onSave(new)
                self?.window?.close()
            },
            cancel: { [weak self] in self?.window?.close() })

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
