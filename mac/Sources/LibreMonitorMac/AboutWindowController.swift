import AppKit
import SwiftUI

/// The About text. A plain window rather than NSAlert: an alert always shows the application icon, which is
/// the generic placeholder until the app has an icon of its own.
struct AboutView: View {
    let close: () -> Void

    /// "Libre Monitor 0.1.0" in a built app (the version make-app.sh stamps into it); just the name otherwise.
    private var title: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "Libre Monitor \($0)" } ?? "Libre Monitor"
    }

    var body: some View {
        VStack(spacing: 14) {
            Text(title)
                .font(.title3.weight(.semibold))

            Text("Shows glucose data that the LibreLink app has already uploaded, read through LibreLinkUp. "
                + "It never talks to the sensor and never changes any data.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Nothing about your glucose readings is saved on this Mac. The only things stored are your login, in "
                + "your Keychain, and your display preferences, such as units, theme, window position and alert limits.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("It is not a medical device and is not affiliated with Abbott. Do not use it for treatment decisions.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("OK") { close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(24)
        .frame(width: 360)
    }
}

@MainActor
final class AboutWindowController {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView(close: { [weak self] in self?.window?.close() }))
            let window = NSWindow(contentViewController: hosting)
            window.title = "About Libre Monitor"
            window.styleMask = [.titled, .closable]
            window.level = .floating
            window.isReleasedWhenClosed = false
            self.window = window
        }

        window?.center()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
