import UserNotifications
import AppKit

/// Posts a local notification when a clip finishes saving, with a "Show in
/// Finder" action — useful since the status text in the menu is easy to miss
/// if you're not actively looking at it.
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        let showAction = UNNotificationAction(identifier: "SHOW_IN_FINDER", title: "Show in Finder", options: [])
        let category = UNNotificationCategory(identifier: "CLIP_SAVED", actions: [showAction], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notifyClipSaved(url: URL) {
        let content = UNMutableNotificationContent()
        content.title = "Replay saved"
        content.body = url.lastPathComponent
        content.sound = .default
        content.categoryIdentifier = "CLIP_SAVED"
        content.userInfo = ["path": url.path]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
