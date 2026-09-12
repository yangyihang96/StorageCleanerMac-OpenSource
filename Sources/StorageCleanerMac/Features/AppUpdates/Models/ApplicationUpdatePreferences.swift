import Foundation

enum ApplicationUpdateCheckFrequency: String, Codable, CaseIterable, Identifiable, Sendable {
    case daily
    case weekly
    case manual

    var id: String { rawValue }

    var title: String {
        switch self {
        case .daily: L10n.text("每天", "Daily")
        case .weekly: L10n.text("每周", "Weekly")
        case .manual: L10n.text("手动", "Manual")
        }
    }
}

struct ApplicationUpdatePreferencesSnapshot: Equatable, Sendable {
    var automaticallyChecks: Bool
    var checkFrequency: ApplicationUpdateCheckFrequency
    var automaticallyDownloadsVerifiedUpdates: Bool
    var automaticallyInstallsSilentUpdates: Bool
    var alwaysCreatesPlan: Bool
    var updatesAfterApplicationQuits: Bool
    var includesHomebrewFormulae: Bool
    var checksSelfUpdatingHomebrewCasks: Bool
    var scansExternalVolumes: Bool
    var notifiesOnCompletion: Bool

    /// The product does not ship a download-only staging queue. Keep the
    /// legacy persisted fields coherent and expose one truthful opt-in for the
    /// complete silent update flow instead of two independently selectable
    /// controls that imply unsupported background pre-downloads.
    var automaticallyExecutesSilentUpdates: Bool {
        automaticallyDownloadsVerifiedUpdates
            && automaticallyInstallsSilentUpdates
            && !alwaysCreatesPlan
    }

    mutating func setAutomaticSilentUpdateExecution(_ isEnabled: Bool) {
        automaticallyDownloadsVerifiedUpdates = isEnabled
        automaticallyInstallsSilentUpdates = isEnabled
        alwaysCreatesPlan = !isEnabled
    }
}

enum ApplicationUpdatePreferences {
    private enum Key {
        static let automaticallyChecks = "appUpdates.automaticallyChecks.v1"
        static let checkFrequency = "appUpdates.checkFrequency.v1"
        static let automaticallyDownloads = "appUpdates.automaticallyDownloads.v1"
        static let automaticallyInstalls = "appUpdates.automaticallyInstalls.v1"
        static let alwaysCreatesPlan = "appUpdates.alwaysCreatesPlan.v1"
        static let updateAfterQuit = "appUpdates.updateAfterQuit.v1"
        static let includesFormulae = "appUpdates.includesHomebrewFormulae.v1"
        static let checksSelfUpdatingCasks = "appUpdates.checksSelfUpdatingCasks.v1"
        static let scansExternalVolumes = "appUpdates.scansExternalVolumes.v1"
        static let notifiesOnCompletion = "appUpdates.notifiesOnCompletion.v1"
    }

    static func snapshot(defaults: UserDefaults = .standard) -> ApplicationUpdatePreferencesSnapshot {
        return ApplicationUpdatePreferencesSnapshot(
            automaticallyChecks: bool(
                forKey: Key.automaticallyChecks,
                defaultValue: true,
                defaults: defaults
            ),
            checkFrequency: ApplicationUpdateCheckFrequency(
                rawValue: defaults.string(forKey: Key.checkFrequency) ?? ""
            ) ?? .weekly,
            automaticallyDownloadsVerifiedUpdates: defaults.bool(forKey: Key.automaticallyDownloads),
            automaticallyInstallsSilentUpdates: defaults.bool(forKey: Key.automaticallyInstalls),
            alwaysCreatesPlan: bool(
                forKey: Key.alwaysCreatesPlan,
                defaultValue: true,
                defaults: defaults
            ),
            updatesAfterApplicationQuits: bool(
                forKey: Key.updateAfterQuit,
                defaultValue: true,
                defaults: defaults
            ),
            includesHomebrewFormulae: bool(
                forKey: Key.includesFormulae,
                defaultValue: true,
                defaults: defaults
            ),
            checksSelfUpdatingHomebrewCasks: defaults.bool(forKey: Key.checksSelfUpdatingCasks),
            scansExternalVolumes: defaults.bool(forKey: Key.scansExternalVolumes),
            notifiesOnCompletion: bool(
                forKey: Key.notifiesOnCompletion,
                defaultValue: true,
                defaults: defaults
            )
        )
    }

    private static func bool(
        forKey key: String,
        defaultValue: Bool,
        defaults: UserDefaults
    ) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    static func set(
        _ snapshot: ApplicationUpdatePreferencesSnapshot,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(snapshot.automaticallyChecks, forKey: Key.automaticallyChecks)
        defaults.set(snapshot.checkFrequency.rawValue, forKey: Key.checkFrequency)
        defaults.set(snapshot.automaticallyDownloadsVerifiedUpdates, forKey: Key.automaticallyDownloads)
        defaults.set(snapshot.automaticallyInstallsSilentUpdates, forKey: Key.automaticallyInstalls)
        defaults.set(snapshot.alwaysCreatesPlan, forKey: Key.alwaysCreatesPlan)
        defaults.set(snapshot.updatesAfterApplicationQuits, forKey: Key.updateAfterQuit)
        defaults.set(snapshot.includesHomebrewFormulae, forKey: Key.includesFormulae)
        defaults.set(snapshot.checksSelfUpdatingHomebrewCasks, forKey: Key.checksSelfUpdatingCasks)
        defaults.set(snapshot.scansExternalVolumes, forKey: Key.scansExternalVolumes)
        defaults.set(snapshot.notifiesOnCompletion, forKey: Key.notifiesOnCompletion)
    }
}

enum ApplicationUpdateCheckSchedule {
    private static let lastCheckKey = "appUpdates.lastAutomaticCheck.v1"

    static func shouldCheck(
        preferences: ApplicationUpdatePreferencesSnapshot = ApplicationUpdatePreferences.snapshot(),
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard preferences.automaticallyChecks,
              preferences.checkFrequency != .manual else { return false }
        guard let lastCheck = defaults.object(forKey: lastCheckKey) as? Date else { return true }
        let interval: TimeInterval = switch preferences.checkFrequency {
        case .daily: 24 * 60 * 60
        case .weekly: 7 * 24 * 60 * 60
        case .manual: .infinity
        }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    static func markChecked(
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        defaults.set(date, forKey: lastCheckKey)
    }
}
