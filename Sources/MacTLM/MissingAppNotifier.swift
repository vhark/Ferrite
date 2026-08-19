import Foundation
import UserNotifications

/// One unobtrusive notification listing template apps that failed to launch
/// (PRD §3.2). Falls back to NSLog when not running from a bundle (swift run)
/// or when notification permission is denied.
enum MissingAppNotifier {
    static func notify(missing: [String]) {
        guard Bundle.main.bundleIdentifier != nil else {
            NSLog("MacTLM: (no bundle) missing apps: %@", missing.joined(separator: ", "))
            return
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "MacTLM"
            content.body = "Didn't launch: \(missing.joined(separator: ", "))"
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }
}
