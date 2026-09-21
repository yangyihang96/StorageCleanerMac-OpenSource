import AppKit
import Combine
import Sparkle

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(
            // Each signed bundle declares its own feed and verification key.
            // Beta uses appcast-beta.xml; production keeps appcast.xml.
            startingUpdater: true,
            // Sparkle filters compatibility, channels, phased rollouts and
            // skipped releases before selecting the highest remaining full
            // update. A custom selector here would weaken those guarantees.
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
