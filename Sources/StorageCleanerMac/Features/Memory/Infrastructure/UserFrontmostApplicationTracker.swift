import AppKit

/// BOARD N19: the application the user is working in. Memory quit
/// suggestions never include it. While this app itself is in front (its main
/// window, menu or mini window is being used) that is the application that
/// was in front just before it; otherwise it is the frontmost application.
@MainActor
final class UserFrontmostApplicationTracker {
    static let shared = UserFrontmostApplicationTracker()

    private let ownProcessIdentifier: pid_t
    private(set) var lastOtherFrontmostProcessIdentifier: pid_t?
    private var observer: NSObjectProtocol?

    init(ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier) {
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    /// Follows application activations from launch, so the application in
    /// front before this one is known when its window is used.
    func start(workspace: NSWorkspace = .shared) {
        guard observer == nil else { return }
        recordActivation(of: workspace.frontmostApplication?.processIdentifier)
        observer = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let processIdentifier = application?.processIdentifier
            MainActor.assumeIsolated {
                self?.recordActivation(of: processIdentifier)
            }
        }
    }

    func recordActivation(of processIdentifier: pid_t?) {
        guard let processIdentifier, processIdentifier > 0,
              processIdentifier != ownProcessIdentifier else { return }
        lastOtherFrontmostProcessIdentifier = processIdentifier
    }

    /// The user's application given the current frontmost one.
    func userFrontmostProcessIdentifier(frontmost: pid_t?) -> pid_t? {
        Self.resolve(
            frontmost: frontmost,
            lastOther: lastOtherFrontmostProcessIdentifier,
            own: ownProcessIdentifier
        )
    }

    nonisolated static func resolve(frontmost: pid_t?, lastOther: pid_t?, own: pid_t) -> pid_t? {
        if let frontmost, frontmost > 0, frontmost != own { return frontmost }
        return lastOther
    }
}
