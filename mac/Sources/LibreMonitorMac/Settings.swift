import Foundation
import LibreMonitorKit

// Port of src/LibreMonitor.App/WidgetSettings.cs. Nothing here is sensitive, and no glucose data is stored:
// only preferences (and the alert limits).

enum ThemeChoice: String, Codable, CaseIterable {
    case system
    case light
    case dark
}

struct WidgetSettings: Codable, Equatable {
    var unit: GlucoseUnit = .mgPerDl
    var hours: Int = 6
    var theme: ThemeChoice = .system
    var showStatusIcon = true
    var showGraph = true
    var alwaysOnTop = true
    var alerts = AlertSettings()
}

enum SettingsStore {
    private static let key = "settings.v1"

    static func load() -> WidgetSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let settings = try? JSONDecoder().decode(WidgetSettings.self, from: data)
        else { return WidgetSettings() }
        return settings
    }

    static func save(_ settings: WidgetSettings) {
        // Preferences are a convenience; failing to save them must never disturb the monitor.
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
