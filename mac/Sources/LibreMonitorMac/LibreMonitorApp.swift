import AppKit

/// Entry point. The app has no Dock icon (LSUIElement): it lives as the floating widget and a menu bar item.
@main
enum LibreMonitorApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
