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

        // CleanMyMac `local_notification_applications_updates_complete_*`,
        // with this app's counts kept in the body.
        let content = UNMutableNotificationContent()
        content.title = L10n.text("更新任务已完成！", "Updater tasks completed!")
        content.body = L10n.text(
            "\(ByteFormat.count(completed)) 个成功，\(ByteFormat.count(failed)) 个失败，\(ByteFormat.count(cancelled)) 个取消。点击以查看您的应用程序更新结果。",
            "\(ByteFormat.count(completed)) succeeded, \(ByteFormat.count(failed)) failed, \(ByteFormat.count(cancelled)) cancelled. Click to see your application update results."
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
