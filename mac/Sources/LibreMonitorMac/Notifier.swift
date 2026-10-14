import AppKit
import UserNotifications

/// System notifications (the counterpart of the tray balloon on Windows).
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    /// Notifications need a real app bundle. Running the bare executable (for example with `swift run`) has none, and
    /// asking for the notification center there crashes, so every entry point checks this first.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Call once at launch so notifications are shown (and clicks handled) while the app is running.
    func start() {
        guard Self.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Posts a notification, asking macOS for permission the first time. `completion` says whether it was posted:
    /// false when notifications are unavailable, were refused in System Settings, or failed.
    /// `openURL` (https only) is opened if the user clicks the notification.
    func post(title: String, body: String, sound: Bool, openURL: URL? = nil, completion: ((Bool) -> Void)? = nil) {
        guard Self.isAvailable else {
            completion?(false)
            return
        }

        let center = UNUserNotificationCenter.current()

        func add() {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound { content.sound = .default }
            if let openURL, openURL.scheme == "https" { content.userInfo = ["url": openURL.absoluteString] }

            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in completion?(error == nil) }
        }

        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { add() } else { completion?(false) }
                }
            case .denied:
                completion?(false)
            default:
                add()
            }
        }
    }

    // An accessory app is often the active app, and macOS hides notifications from the active app unless asked to show them.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void)
    {
        // Only addresses this app attached itself, and only https ones, are ever opened.
        if let text = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: text), url.scheme == "https"
        {
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
