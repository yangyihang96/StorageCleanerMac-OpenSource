import AppKit
import Foundation

/// A2 (D22): asks the apps that own selected cleanup rows to quit normally, so
/// their caches and logs can be cleaned. Only regular apps the user can see
/// are offered; a menu-bar or background app, Finder and this app run on but
/// must be quit by hand. An app is never force-quit: it may ask to save or
/// refuse, and then its rows are skipped as before.
///
/// Round 3 (P2-6): the normal quit request and the wait reuse the existing
/// `BrowserPrivacyRunningApplicationChecking.requestNormalTermination`
/// (`NSRunningApplication.terminate()` for every running instance, then a
/// check every 100 ms until a clock deadline), so there is one implementation
/// of "quit normally and wait" and the wait cannot grow with slow polls.
@MainActor
struct CleanupOwnerQuitService {
    /// One running instance of an owner app.
    struct RunningOwner: Equatable, Sendable {
        let bundleIdentifier: String
        let displayName: String
    }

    /// The running owners of some rows: those that can be asked to quit, and
    /// those that must be quit by hand.
    struct Options: Equatable, Sendable {
        var quittable: [RunningOwner] = []
        var manual: [RunningOwner] = []

        var isEmpty: Bool { quittable.isEmpty && manual.isEmpty }
    }

    struct RunningApplication {
        let bundleIdentifier: String?
        let localizedName: String?
        let isRegularApplication: Bool
    }

    /// How long the store waits for the apps to quit (clock deadline).
    nonisolated static let waitSeconds: TimeInterval = 5
    private static let neverOffered: Set<String> = ["com.apple.finder"]

    private let runningApplications: @MainActor () -> [RunningApplication]
    private let terminator: any BrowserPrivacyRunningApplicationChecking
    private let ownBundleIdentifier: String?

    init(
        workspace: NSWorkspace = .shared,
        terminator: any BrowserPrivacyRunningApplicationChecking = BrowserPrivacyWorkspaceRunningApplicationChecker()
    ) {
        runningApplications = {
            workspace.runningApplications.map { application in
                RunningApplication(
                    bundleIdentifier: application.bundleIdentifier,
                    localizedName: application.localizedName,
                    isRegularApplication: application.activationPolicy == .regular
                )
            }
        }
        self.terminator = terminator
        ownBundleIdentifier = Bundle.main.bundleIdentifier
    }

    init(
        runningApplications: @escaping @MainActor () -> [RunningApplication],
        terminator: any BrowserPrivacyRunningApplicationChecking,
        ownBundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) {
        self.runningApplications = runningApplications
        self.terminator = terminator
        self.ownBundleIdentifier = ownBundleIdentifier
    }

    /// The running instances of these apps, split into those that may be
    /// asked to quit and those that must be quit by hand. An identifier with
    /// any instance that cannot be asked is wholly manual, so the apps asked
    /// to quit are exactly the instances listed as quittable.
    func options(among bundleIdentifiers: Set<String>) -> Options {
        var instances = [String: [RunningApplication]]()
        for application in runningApplications() {
            guard let identifier = application.bundleIdentifier,
                  bundleIdentifiers.contains(identifier) else { continue }
            instances[identifier, default: []].append(application)
        }
        var options = Options()
        for (identifier, running) in instances {
            let owners = running.map { application in
                RunningOwner(
                    bundleIdentifier: identifier,
                    displayName: application.localizedName.flatMap { $0.isEmpty ? nil : $0 } ?? identifier
                )
            }
            let canAsk = identifier != ownBundleIdentifier
                && !Self.neverOffered.contains(identifier)
                && running.allSatisfy(\.isRegularApplication)
            if canAsk {
                options.quittable += owners
            } else {
                options.manual += owners
            }
        }
        let byName: (RunningOwner, RunningOwner) -> Bool = {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        options.quittable.sort(by: byName)
        options.manual.sort(by: byName)
        return options
    }

    /// Asks every running instance of the listed apps to quit normally and
    /// waits until they quit or the deadline passes. Returns the identifiers
    /// still running; nothing is ever force-quit.
    func quitNormally(_ owners: [RunningOwner]) async -> Set<String> {
        let identifiers = Set(owners.map(\.bundleIdentifier))
        guard !identifiers.isEmpty else { return [] }
        return await terminator.requestNormalTermination(
            bundleIdentifiers: identifiers,
            timeoutSeconds: Self.waitSeconds
        )
    }
}

/// A2: the owner apps listed for confirmation before they are asked to quit.
struct CleanupOwnerQuitRequest: Identifiable, Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A running row on the results page: quit, then clean the selection.
        case results(cleanupScope: Set<ScanCandidateID>?)
        /// The confirmation sheet: quit, then check the same plan again.
        case confirmation
    }

    let id = UUID()
    let source: Source
    /// Every running instance that will be asked to quit.
    let owners: [CleanupOwnerQuitService.RunningOwner]
    /// Round 3 (P2-3): the scan, and on the sheet the plan, the request was
    /// made for. If either changed while the apps quit, nothing continues.
    var sessionID: ScanSessionID? = nil
    var planID: CleanPlanID? = nil

    var isFromConfirmation: Bool { source == .confirmation }
}
