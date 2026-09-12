import Foundation

struct ManualUpdateProvider: ApplicationUpdateProvider {
    let identifier = ApplicationUpdateProviderIdentifier.manual

    func canHandle(_ application: InstalledApplication) async -> Bool { true }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: ["no-verified-provider"],
            requiresUserInteraction: true,
            canAutomaticallyUpdate: false
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        ApplicationUpdateCheckResult(
            status: .sourceUnconfirmed,
            availableVersion: nil,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil,
            warning: L10n.text("尚无经过验证的更新来源。", "No verified update source is available.")
        )
    }
}
