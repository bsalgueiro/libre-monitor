import AppKit
import SwiftUI

// Colours and thresholds, matching src/LibreMonitor.App/Palette.cs.
// Range colours are darker in the light theme so they keep their contrast on a light background.
// The thresholds only colour the display; they are not alarms.

enum Thresholds {
    static let lowMgPerDl = 70.0
    static let highMgPerDl = 180.0
    static let referenceMgPerDl = 100.0
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity)
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

struct WidgetTheme {
    let text: Color
    let muted: Color
    /// Colour of lines, guides and fills drawn over the card (white on dark, near-black on light).
    let ink: Color
    let fillOpacity: Double
    /// Outline around the "now" dot, matching the card so the dot looks cut out.
    let ring: Color
    let pill: Color
    let inRange: Color
    let high: Color
    let low: Color

    static let dark = WidgetTheme(
        text: Color(hex: 0xF2F5F9), muted: Color(hex: 0x8B95A3), ink: .white, fillOpacity: 0.18,
        ring: Color(hex: 0x141921, opacity: 0.9), pill: Color(hex: 0x101419, opacity: 0.95),
        inRange: Color(hex: 0x5CD68A), high: Color(hex: 0xFFB84D), low: Color(hex: 0xFF6B6B))

    static let light = WidgetTheme(
        text: Color(hex: 0x141A22), muted: Color(hex: 0x5F6B7A), ink: Color(hex: 0x1B2330), fillOpacity: 0.12,
        ring: Color(hex: 0xFAFBFD, opacity: 0.92), pill: Color(hex: 0xFFFFFF, opacity: 0.96),
        inRange: Color(hex: 0x1F9D5B), high: Color(hex: 0xC77700), low: Color(hex: 0xD63A3A))

    static func forScheme(_ scheme: ColorScheme) -> WidgetTheme { scheme == .dark ? dark : light }

    func color(forMgPerDl mgPerDl: Double) -> Color {
        if mgPerDl < Thresholds.lowMgPerDl { return low }
        if mgPerDl > Thresholds.highMgPerDl { return high }
        return inRange
    }
}

/// Colours of the menu bar tile: white digits on a deep tile, like the Windows tray icon.
enum TileColors {
    static let inRange = NSColor(hex: 0x1F9D5B)
    static let high = NSColor(hex: 0xC77700)
    static let low = NSColor(hex: 0xD63A3A)
    static let muted = NSColor(hex: 0x5F6B7A)

    static func color(forMgPerDl mgPerDl: Double) -> NSColor {
        if mgPerDl < Thresholds.lowMgPerDl { return low }
        if mgPerDl > Thresholds.highMgPerDl { return high }
        return inRange
    }
}
