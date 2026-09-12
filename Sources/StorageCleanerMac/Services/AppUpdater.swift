import AppKit
import Combine
import FanControlShared
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: !StorageCleanerBuildIdentity.isBeta,
            // Sparkle filters compatibility, channels, phased rollouts and
            // skipped releases before selecting the highest remaining full
            // update. A custom selector here would weaken those guarantees.
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        guard !StorageCleanerBuildIdentity.isBeta else {
            let alert = NSAlert()
            alert.messageText = L10n.text("本地测试版", "Local Beta")
            alert.informativeText = L10n.text(
                "测试版由本地构建流程更新，不会连接或安装正式版更新。",
                "This beta is updated by the local build workflow and will not connect to or install production updates."
            )
            alert.runModal()
            return
        }
        controller.checkForUpdates(nil)
    }
}
