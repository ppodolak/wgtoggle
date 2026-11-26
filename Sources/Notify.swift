import AppKit
import UserNotifications

/// macOS notifications for tunnel up/down and errors. Clicking an error opens the Log Explorer.
final class Notify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notify()
    static let enabledKey = "notificationsEnabled"

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func setup() {
        let c = UNUserNotificationCenter.current()
        c.delegate = shared
        c.requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err { Log.warn("notifications unavailable: \(err.localizedDescription)") }
            else { Log.info("notifications \(granted ? "allowed" : "denied by user")") }
        }
    }

    static func connected(_ name: String) {
        post(title: "\(name) connected", body: "Tunnel is up.", id: "state-\(name)")
    }

    static func disconnected(_ name: String) {
        post(title: "\(name) disconnected", body: "Tunnel is down.", id: "state-\(name)")
    }

    static func error(_ title: String, _ message: String) {
        // Keep the banner short; full text is in the log.
        let short = message.split(separator: "\n").map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? message
        post(title: title, body: String(short.prefix(180)) + "\nClick to open logs.",
             id: "error-\(UUID().uuidString)", openLogs: true, sound: .defaultCritical)
    }

    static func post(title: String, body: String, id: String = UUID().uuidString, openLogs: Bool = false,
                             sound: UNNotificationSound = .default) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = sound
        content.threadIdentifier = openLogs ? "errors" : "state"
        if openLogs { content.userInfo = ["open": "logs"] }
        // Same id per tunnel → a fresh up/down replaces the previous banner instead of stacking.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { err in
            if let err { Log.warn("notification failed: \(err.localizedDescription)") }
        }
    }

    // Show banners even when the app is frontmost (e.g. Log Explorer focused).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        if response.notification.request.content.userInfo["open"] as? String == "logs" {
            DispatchQueue.main.async { MainActor.assumeIsolated { LogExplorer.show() } }
        }
        done()
    }
}
