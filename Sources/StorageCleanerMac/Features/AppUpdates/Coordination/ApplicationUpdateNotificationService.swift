import Foundation
import UserNotifications

enum ApplicationUpdateNotificationService {
    static func isAuthorized() async -> Bool {
        guard isApplicationHost else { return false }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return status == .authorized || status == .provisional
    }

    static func requestAuthorization() async -> Bool {
        guard isApplicationHost else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound]
            )
        } catch {
            return false
        }
    }

    static func notifyQueueFinished(
        completed: Int,
        failed: Int,
        cancelled: Int
    ) async {
        guard ApplicationUpdatePreferences.snapshot().notifiesOnCompletion,
              isApplicationHost else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional else {
            return
        }

        let content = UNMutableNotificationContent()
        content.title = L10n.text("应用更新已完成", "Application Updates Finished")
        content.body = L10n.text(
            "\(completed) 个成功，\(failed) 个失败，\(cancelled) 个取消",
            "\(completed) succeeded, \(failed) failed, \(cancelled) cancelled"
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "application-updates-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    private static var isApplicationHost: Bool {
        Bundle.main.bundleIdentifier?.isEmpty == false
            && Bundle.main.bundleURL.pathExtension.lowercased() == "app"
    }
}
