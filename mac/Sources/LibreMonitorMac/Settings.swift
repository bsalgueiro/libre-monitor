import Foundation
import LibreMonitorKit

// Port of windows/src/LibreMonitor.App/WidgetSettings.cs. Nothing here is sensitive, and no glucose data is stored:
// only preferences (the alert limits, and the long-acting insulin reminder: its times and when a dose was last
// marked as taken, which is the only thing recorded about it).

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
    var insulin = InsulinSettings()

    init() {}

    // Written out so that settings saved by an older version, which lack newer keys, still load instead of being reset.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        unit = try c.decodeIfPresent(GlucoseUnit.self, forKey: .unit) ?? unit
        hours = try c.decodeIfPresent(Int.self, forKey: .hours) ?? hours
        theme = try c.decodeIfPresent(ThemeChoice.self, forKey: .theme) ?? theme
        showStatusIcon = try c.decodeIfPresent(Bool.self, forKey: .showStatusIcon) ?? showStatusIcon
        showGraph = try c.decodeIfPresent(Bool.self, forKey: .showGraph) ?? showGraph
        alwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? alwaysOnTop
        alerts = try c.decodeIfPresent(AlertSettings.self, forKey: .alerts) ?? alerts
        insulin = try c.decodeIfPresent(InsulinSettings.self, forKey: .insulin) ?? insulin
    }
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
