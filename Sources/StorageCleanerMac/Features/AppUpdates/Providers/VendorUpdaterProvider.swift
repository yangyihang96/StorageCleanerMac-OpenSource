import Foundation

/// Drives a verified official CLI when available; local updater markers alone
/// keep an explicit in-app fallback with its reason.
struct VendorUpdaterProvider: ApplicationUpdateProvider {
    var commandAdapter = VendorCommandUpdateAdapter()
    var readApplication: @Sendable (URL) async -> InstalledApplication? = { url in
        await ApplicationMetadataReader().read(applicationURL: url, runningState: .init(bundleIdentifiers: [], normalizedBundlePaths: []))
    }
    let identifier = ApplicationUpdateProviderIdentifier.vendorUpdater

    enum VendorUpdaterKind: String, CaseIterable, Sendable {
        case keystone = "vendor-keystone"
        case squirrel = "vendor-squirrel"

        var displayName: String {
            switch self {
            case .keystone:
                L10n.text("Google 更新器", "Google Updater")
            case .squirrel:
                L10n.text("内置自动更新器", "Built-in Auto Updater")
            }
        }
    }

    func canHandle(_ application: InstalledApplication) async -> Bool {
        if await commandAdapter.resolve(application) != nil { return true }
        return !Self.detectUpdaterKinds(at: application.bundleURL).isEmpty
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        let kinds = Self.detectUpdaterKinds(at: application.bundleURL)
        let command = await commandAdapter.resolve(application)
        guard !kinds.isEmpty || command != nil else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        return ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: kinds.map(\.rawValue).sorted() + (command == nil ? [] : ["vendor-official-cli"]),
            requiresUserInteraction: command == nil,
            canAutomaticallyUpdate: command != nil
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
        if let command = await commandAdapter.resolve(application) {
            let version = try await commandAdapter.check(application, command: command)
            return .init(status: .automaticallyUpdatable, availableVersion: version, releaseDate: nil, releaseNotes: nil, downloadSize: nil,
                warning: version == nil ? L10n.text("将由厂商官方更新器检查并更新，完成后核验磁盘版本", "The official vendor updater will check and update, then verify the on-disk version") : nil)
        }
        let kinds = Self.detectUpdaterKinds(at: application.bundleURL)
        let updaterName = kinds.first?.displayName
            ?? L10n.text("厂商更新器", "Vendor Updater")
        return ApplicationUpdateCheckResult(
            status: .latestVersionUnknown,
            availableVersion: nil,
            releaseDate: nil,
            releaseNotes: nil,
            downloadSize: nil,
            warning: L10n.text(
                "此应用由\(updaterName)维护，最新版本无法从外部只读确认；打开应用即可检查并安装更新。",
                "This app is maintained by its \(updaterName); the latest version cannot be confirmed read-only from outside. Open the app to check and install updates."
            )
        )
    }

    func prepareUpdate(_ application: InstalledApplication) async throws -> PreparedApplicationUpdate {
        guard !application.isRunning, let command = await commandAdapter.resolve(application) else {
            throw ApplicationScanningError.providerUnsupported("vendor-official-cli-unavailable")
        }
        return .init(applicationID: application.id, providerIdentifier: .vendorUpdater, originalIdentity: application.identity,
            originalVersion: application.installedVersion, targetVersion: application.availableVersion,
            providerPayload: ["bundle-path": application.path, "command-path": command.executableURL.path,
                "product-id": command.productID, "team": application.signingTeamIdentifier ?? ""])
    }

    func install(_ update: PreparedApplicationUpdate, progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult {
        guard let path = update.providerPayload["bundle-path"],
              let app = await readApplication(URL(fileURLWithPath: path)),
              app.identity == update.originalIdentity, app.installedVersion == update.originalVersion, !app.isRunning,
              let command = await commandAdapter.resolve(app), command.executableURL.path == update.providerPayload["command-path"],
              command.productID == update.providerPayload["product-id"] else { throw ProviderBackedUpdateExecutorError.applicationIdentityChanged }
        progress(.init(applicationID: update.applicationID, state: .installing, fraction: nil, detail: L10n.text("厂商官方更新器正在更新", "The official vendor updater is updating")))
        _ = try await commandAdapter.run(command.executableURL, command.installArguments)
        return .init(applicationID: update.applicationID, state: .needsReconciliation, observedVersion: nil, detail: L10n.text("正在核验厂商更新后的版本", "Verifying the version after vendor update"))
    }

    /// Purely local, read-only detection. Only unambiguous in-bundle markers
    /// count; nothing here contacts the network or trusts app-provided URLs.
    static func detectUpdaterKinds(
        at bundleURL: URL,
        fileManager: FileManager = .default
    ) -> [VendorUpdaterKind] {
        var kinds = [VendorUpdaterKind]()
        let frameworksURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Frameworks", isDirectory: true)

        let infoPlistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        if let data = try? Data(contentsOf: infoPlistURL),
           let plist = try? PropertyListSerialization.propertyList(
               from: data,
               options: [],
               format: nil
           ) as? [String: Any],
           plist["KSUpdateURL"] != nil || plist["KSProductID"] != nil {
            kinds.append(.keystone)
        } else if directoryExists(
            frameworksURL.appendingPathComponent(
                "KeystoneRegistration.framework",
                isDirectory: true
            ),
            fileManager: fileManager
        ) {
            kinds.append(.keystone)
        }

        if directoryExists(
            frameworksURL.appendingPathComponent("Squirrel.framework", isDirectory: true),
            fileManager: fileManager
        ) {
            kinds.append(.squirrel)
        }
        return kinds
    }

    private static func directoryExists(
        _ url: URL,
        fileManager: FileManager
    ) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
