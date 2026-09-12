import Foundation

struct SystemManagedProvider: ApplicationUpdateProvider {
    let identifier = ApplicationUpdateProviderIdentifier.systemManaged

    func canHandle(_ application: InstalledApplication) async -> Bool {
        SystemApplicationPolicy.isSystemManaged(application)
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: ["system-managed-path"],
            requiresUserInteraction: false,
            canAutomaticallyUpdate: false
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        ApplicationUpdateCheckResult(
            status: .systemManaged,
            availableVersion: nil,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil,
            warning: nil
        )
    }
}
