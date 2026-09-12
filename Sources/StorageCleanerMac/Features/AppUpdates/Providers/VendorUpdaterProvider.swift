import Foundation

/// Recognizes applications that ship their own trusted update machinery
/// (Google Keystone, Squirrel.Mac). StorageCleanerMac never drives these
/// updaters; the provider exists so such apps surface an honest, actionable
/// "update inside the app" path instead of falling through to the
/// source-unconfirmed bucket.
struct VendorUpdaterProvider: ApplicationUpdateProvider {
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
        !Self.detectUpdaterKinds(at: application.bundleURL).isEmpty
    }

    func inspect(_ application: InstalledApplication) async throws -> ApplicationUpdateSourceInfo {
        let kinds = Self.detectUpdaterKinds(at: application.bundleURL)
        guard !kinds.isEmpty else {
            throw ApplicationScanningError.providerUnsupported(identifier.rawValue)
        }
        return ApplicationUpdateSourceInfo(
            providerIdentifier: identifier,
            evidence: kinds.map(\.rawValue).sorted(),
            requiresUserInteraction: true,
            canAutomaticallyUpdate: false
        )
    }

    func checkForUpdate(_ application: InstalledApplication) async throws -> ApplicationUpdateCheckResult {
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
