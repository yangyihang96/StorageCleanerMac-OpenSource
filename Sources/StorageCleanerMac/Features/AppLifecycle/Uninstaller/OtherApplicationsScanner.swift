import Foundation

/// D218: this inventory belongs only to the manager's Other Locations category.
/// It never feeds the installed-app inventory, Smart Scan or the overview.
struct OtherApplicationGroup: Identifiable, Sendable {
    let id: String
    let copies: [InstalledAppItem]
    var name: String { copies.first?.name ?? "" }
    var sizeBytes: Int64 { copies.reduce(0) { $0 + $1.sizeBytes } }
}

struct OtherApplicationsReport: Sendable {
    var groups: [OtherApplicationGroup] = []
    var unavailableReason: String?
    var ignoredCount = 0

    static func grouping(_ applications: [InstalledAppItem], ignoreList: IgnoreListSnapshot) -> Self {
        let visible = applications.filter {
            !ignoreList.ignoresApplication(bundleIdentifier: $0.bundleIdentifier, path: $0.path, category: .uninstaller)
        }
        let groups = Dictionary(grouping: visible) { app in
            app.bundleIdentifier.trimmed.isEmpty ? "path:\(app.path)" : "bundle:\(app.bundleIdentifier.lowercased())"
        }.map { key, copies in
            OtherApplicationGroup(id: key, copies: copies.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending })
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return Self(groups: groups, ignoredCount: applications.count - visible.count)
    }
}

struct OtherApplicationsScanner: Sendable {
    var homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    var query: @Sendable () async throws -> SpotlightApplicationScanResult = {
        try await SpotlightApplicationScanner(contentTypeAttribute: NSMetadataItemContentTypeTreeKey)
            .scan(timeout: .seconds(12))
    }
    var containsSymbolicLink: @Sendable (String) -> Bool = { PathSafety.containsSymbolicLinkComponent(in: $0) }
    var readApplication: @Sendable (URL) -> InstalledAppItem? = Self.readBundle

    func scan(ignoreList: IgnoreListSnapshot = .empty) async throws -> OtherApplicationsReport {
        let result: SpotlightApplicationScanResult
        do { result = try await query() }
        catch is CancellationError { throw CancellationError() }
        catch {
            return OtherApplicationsReport(unavailableReason: L10n.text(
                "无法查询 Spotlight：\(error.localizedDescription)", "Spotlight could not be queried: \(error.localizedDescription)"))
        }
        try Task.checkCancellation()
        switch result.completion {
        case .unavailable:
            return OtherApplicationsReport(unavailableReason: L10n.text("Spotlight 暂时不可用。", "Spotlight is currently unavailable."))
        case .timedOut:
            return OtherApplicationsReport(unavailableReason: L10n.text("Spotlight 查询未能及时完成。", "The Spotlight query did not finish in time."))
        case .completed: break
        }
        var seen = Set<String>()
        var applications: [InstalledAppItem] = []
        for url in result.applicationURLs {
            try Task.checkCancellation()
            guard url.isFileURL else { continue }
            let path = PathSafety.lexicalPath(url.path)
            guard Self.permits(path: path, homePath: homeDirectory.path),
                  seen.insert(path).inserted, !containsSymbolicLink(path),
                  let item = readApplication(URL(fileURLWithPath: path)),
                  item.path == path,
                  !Self.isProxyOrWebApplication(item.bundleIdentifier) else { continue }
            applications.append(item)
        }
        return .grouping(applications, ignoreList: ignoreList)
    }

    /// Pure lexical filtering runs before any bundle or directory is read.
    static func permits(path: String, homePath: String) -> Bool {
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).pathExtension.lowercased() == "app" else { return false }
        let path = ProtectedLocations.folded(PathSafety.lexicalPath(path))
        let home = ProtectedLocations.folded(PathSafety.lexicalPath(homePath))
        let excludedRoots = ["/Applications", home + "/Applications", home + "/Library", "/Library", "/System", "/Volumes",
                             "/usr", "/bin", "/sbin", "/private", "/opt", "/cores", "/net", "/tmp", "/var", "/dev", "/etc", "/Developer"]
        guard !excludedRoots.contains(where: { root in
            let root = ProtectedLocations.folded(root)
            return path == root || path.hasPrefix(root + "/")
        }), !ProtectedLocations.protects(path: path, homePath: home) else { return false }
        let parents = path.split(separator: "/").dropLast().map(String.init)
        let packageExtensions: Set<String> = ["app", "pvm", "vmwarevm", "vbox", "utm", "parallels", "backupdb", "backup", "sparsebundle", "backupbundle"]
        return !parents.contains { part in
            packageExtensions.contains((part as NSString).pathExtension)
                || [".trash", ".trashes", ".cxoffice", "com.apple.timemachine.localsnapshots",
                    "chrome apps.localized", "chromium apps.localized", "edge apps.localized", "brave browser apps.localized"].contains(part)
        }
    }

    static func isProxyOrWebApplication(_ identifier: String) -> Bool {
        let id = identifier.lowercased()
        return ["com.parallels.winapp", "com.parallels.applicationgroupbridge", "com.vmware.proxyapp",
                "com.codeweavers.crossoverhelper", "com.codeweavers.crossover.winapp",
                "com.google.chrome.app.", "com.google.chrome.canary.app.", "org.chromium.chromium.app.",
                "com.microsoft.edgemac.app.", "com.brave.browser.app.", "com.vivaldi.vivaldi.app.",
                "com.operasoftware.opera.app.", "com.apple.safari.webapp", "com.apple.safaritechnologypreview.webapp"]
            .contains(where: id.hasPrefix)
    }

    private static func readBundle(_ url: URL) -> InstalledAppItem? {
        guard let identity = AppUninstallService.uninstallFileIdentity(at: url.path), identity.entryKind == .directory else { return nil }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard !PathSafety.containsSymbolicLinkComponent(in: infoURL.path),
              let data = try? Data(contentsOf: infoURL),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        return InstalledAppItem(id: url.path,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? url.deletingPathExtension().lastPathComponent,
            bundleIdentifier: info["CFBundleIdentifier"] as? String ?? "", path: url.path,
            version: info["CFBundleShortVersionString"] as? String ?? "", build: info["CFBundleVersion"] as? String ?? "",
            category: "", appDescription: "", sizeBytes: TrashSizeMeasurer.allocatedSize(of: url),
            source: L10n.text("其他位置", "Other Locations"), modifiedAt: values?.contentModificationDate,
            scanIdentity: identity, relatedPaths: [], relatedItems: [], status: .installed)
    }
}
