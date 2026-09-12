import AppKit
import Combine
import Foundation

@MainActor
final class AppInstallationConflictController: ObservableObject {
    static let dismissalDefaultsKey = "appInstallationConflict.dismissedFingerprint.v1"

    @Published private(set) var conflict: AppInstallationConflict?

    private let defaults: UserDefaults
    private let dismissalDefaultsKey: String
    private let detector: @Sendable () -> AppInstallationConflict?
    private let revealInFinder: ([URL]) -> Void
    private var didCheckThisProcess = false

    init(
        defaults: UserDefaults = .standard,
        dismissalDefaultsKey: String = AppInstallationConflictController.dismissalDefaultsKey,
        detector: @escaping @Sendable () -> AppInstallationConflict? = {
            AppInstallationConflictService.detect()
        },
        revealInFinder: @escaping ([URL]) -> Void = { urls in
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    ) {
        self.defaults = defaults
        self.dismissalDefaultsKey = dismissalDefaultsKey
        self.detector = detector
        self.revealInFinder = revealInFinder
    }

    func checkIfNeeded() async {
        guard !didCheckThisProcess else { return }
        didCheckThisProcess = true

        let detector = self.detector
        let detectedConflict = await Task.detached(priority: .utility) {
            detector()
        }.value

        guard let detectedConflict else {
            conflict = nil
            return
        }

        guard defaults.string(forKey: dismissalDefaultsKey) != detectedConflict.fingerprint else {
            conflict = nil
            return
        }
        conflict = detectedConflict
    }

    func revealCopies() {
        guard let conflict else { return }
        revealInFinder(conflict.copies.map(\.url))
    }

    func dismiss() {
        guard let conflict else { return }
        defaults.set(conflict.fingerprint, forKey: dismissalDefaultsKey)
        self.conflict = nil
    }
}
