import UserNotifications

@MainActor private var authorizationRequested = false

// Silent notification, like Electron's Notification({ silent: true }).
@MainActor
func notify(_ title: String, _ body: String) {
    let center = UNUserNotificationCenter.current()
    if !authorizationRequested {
        authorizationRequested = true
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { _ in }
}
