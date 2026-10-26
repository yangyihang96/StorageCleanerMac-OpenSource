import Darwin
import Foundation
import Security

/// D-FP1: who signed a bundle. A developer is named only when the signature
/// chains to an Apple-issued certificate, so a self-made certificate cannot
/// claim one. Resources are not re-hashed (`kSecCSDoNotValidateResources`):
/// the list only names the developer and nothing is trusted or run from it.
enum ExtensionSigningReader {
    static func signing(at url: URL) -> ExtensionSigning {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            return .notChecked
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                            &information) == errSecSuccess,
              let values = information as? [String: Any] else {
            return .notChecked
        }
        // No identifier: not signed. No certificates: ad hoc, which names nobody.
        let certificates = values[kSecCodeInfoCertificates as String] as? [SecCertificate] ?? []
        guard values[kSecCodeInfoIdentifier as String] != nil, !certificates.isEmpty else { return .unsigned }
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateResources)
        if satisfies(staticCode, requirement: "anchor apple", flags: flags) { return .apple }
        guard satisfies(staticCode, requirement: "anchor apple generic", flags: flags),
              let team = values[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty else {
            return .invalid
        }
        return .developer(teamID: team, name: certificates.first.flatMap(developerName))
    }

    private static func satisfies(_ code: SecStaticCode, requirement text: String, flags: SecCSFlags) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// "Developer ID Application: Example Ltd (ABCDE12345)" → "Example Ltd".
    static func developerName(_ certificate: SecCertificate) -> String? {
        guard let summary = SecCertificateCopySubjectSummary(certificate) as String? else { return nil }
        return developerName(fromSubject: summary)
    }

    static func developerName(fromSubject subject: String) -> String? {
        var name = subject
        for prefix in ["Developer ID Application: ", "Apple Development: ", "Apple Distribution: ",
                       "Mac Developer: ", "3rd Party Mac Developer Application: ", "Developer ID Installer: "]
        where name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
            break
        }
        if name.hasSuffix(")"), let open = name.lastIndex(of: "(") {
            name = String(name[..<open])
        }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }
}

/// D-FP1: reads the extension folders of the user's and the shared Library
/// and the app extensions pluginkit knows. Nothing here changes a file.
struct ExtensionInventoryScanner: Sendable {
    struct Roots: Sendable, Equatable {
        var userLibrary: URL
        var localLibrary: URL

        static var live: Roots {
            Roots(userLibrary: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library", isDirectory: true),
                  localLibrary: URL(fileURLWithPath: "/Library", isDirectory: true))
        }

        func library(for domain: ExtensionDomain) -> URL {
            domain == .user ? userLibrary : localLibrary
        }
    }

    var roots: Roots = .live
    var homePath: String = PathSafety.lexicalHomePath
    var operatingSystemMajorVersion: Int = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    var signing: @Sendable (URL) -> ExtensionSigning = { ExtensionSigningReader.signing(at: $0) }
    var pluginKit: @Sendable () async -> [PluginKitRecord]? = { await PluginKitListing.read() }
    var metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    /// A bundle with more entries than this is reported as "at least".
    var sizeEntryLimit = 50_000

    func scan() async -> ExtensionInventory {
        var items: [ExtensionItem] = []
        var hidden = 0
        for kind in ExtensionKind.folderKinds {
            for domain in [ExtensionDomain.user, .local] where !(kind == .kernelExtension && domain == .user) {
                for (folder, extensions) in kind.libraryFolders {
                    if Task.isCancelled { break }
                    let directory = roots.library(for: domain).appendingPathComponent(folder, isDirectory: true)
                    for item in bundles(in: directory, extensions: extensions, kind: kind, domain: domain) {
                        // Apple's own drivers in /Library/Extensions are counted, not listed.
                        if kind == .kernelExtension, item.bundleIdentifier?.hasPrefix("com.apple.") == true {
                            hidden += 1
                        } else {
                            items.append(item)
                        }
                    }
                }
            }
        }
        let records = Task.isCancelled ? nil : await pluginKit()
        if let records {
            var seen = Set<String>()
            for record in records where seen.insert(record.path).inserted {
                if record.isApple { hidden += 1 } else { items.append(Self.item(for: record)) }
            }
        }
        items.sort(by: Self.listOrder)
        return ExtensionInventory(items: items, hiddenAppleExtensionCount: hidden,
                                  pluginKitAvailable: records != nil, scannedAt: Date())
    }

    /// Larger first within a kind; obsolete bundles first of all, since
    /// removing them changes nothing a user can notice.
    static func listOrder(_ a: ExtensionItem, _ b: ExtensionItem) -> Bool {
        if a.kind != b.kind {
            return ExtensionKind.allCases.firstIndex(of: a.kind)! < ExtensionKind.allCases.firstIndex(of: b.kind)!
        }
        if (a.obsolescence != nil) != (b.obsolescence != nil) { return a.obsolescence != nil }
        if a.bytes != b.bytes { return a.bytes > b.bytes }
        return a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    // MARK: Bundle folders

    func bundles(in directory: URL, extensions: Set<String>, kind: ExtensionKind,
                 domain: ExtensionDomain) -> [ExtensionItem] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        return children
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { bundleItem(at: $0, kind: kind, domain: domain) }
    }

    func bundleItem(at url: URL, kind: ExtensionKind, domain: ExtensionDomain) -> ExtensionItem? {
        let path = PathSafety.lexicalPath(url.path)
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let isLink = (status.st_mode & S_IFMT) == S_IFLNK
        let snapshot = try? metadata.snapshot(at: URL(fileURLWithPath: path))
        // A link is read through for its name; its target is not measured.
        let readURL = isLink ? URL(fileURLWithPath: path).resolvingSymlinksInPath() : URL(fileURLWithPath: path)
        let info = Self.infoDictionary(of: readURL)
        let size = isLink ? (bytes: Int64(0), complete: true) : allocatedSize(of: readURL)
        let management: ExtensionManagement
        if domain == .local {
            management = kind == .kernelExtension ? .systemSettingsApproval : .administratorLocation
        } else if ProtectedLocations.protects(path: path, homePath: homePath) {
            management = .protectedLocation
        } else if isLink || snapshot?.hasSymbolicLinkComponent == true {
            management = .symbolicLink
        } else if snapshot == nil {
            management = .unreadable
        } else {
            management = .movableToTrash
        }
        return ExtensionItem(
            kind: kind,
            path: path,
            name: Self.displayName(info: info, kind: kind, fileName: url.deletingPathExtension().lastPathComponent),
            bundleIdentifier: info["CFBundleIdentifier"] as? String,
            version: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String),
            domain: domain,
            bytes: size.bytes,
            sizeIsLowerBound: !size.complete,
            signing: signing(readURL),
            parentName: nil,
            parentPath: nil,
            election: nil,
            extensionPoint: nil,
            obsolescence: obsolescence(for: kind),
            isSymbolicLink: isLink,
            identity: snapshot?.identity,
            modified: snapshot?.modificationTimeNanoseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) },
            management: management
        )
    }

    func obsolescence(for kind: ExtensionKind) -> ExtensionObsolescence? {
        switch kind {
        case .quickLookGenerator: operatingSystemMajorVersion >= 15 ? .quickLookGeneratorsRetired : nil
        case .internetPlugin: .npapiRetired
        default: nil
        }
    }

    static func infoDictionary(of bundle: URL) -> [String: Any] {
        for candidate in ["Contents/Info.plist", "Info.plist"] {
            if let info = NSDictionary(contentsOf: bundle.appendingPathComponent(candidate)) as? [String: Any] {
                return info
            }
        }
        return [:]
    }

    static func displayName(info: [String: Any], kind: ExtensionKind, fileName: String) -> String {
        let keys = kind == .preferencePane
            ? ["NSPrefPaneIconLabel", "CFBundleDisplayName", "CFBundleName"]
            : ["CFBundleDisplayName", "CFBundleName"]
        for key in keys {
            if let value = info[key] as? String {
                let flat = value.components(separatedBy: .newlines).joined(separator: " ")
                    .trimmingCharacters(in: .whitespaces)
                if !flat.isEmpty { return flat }
            }
        }
        return fileName
    }

    /// Allocated bytes of a bundle, without following links inside it.
    func allocatedSize(of url: URL) -> (bytes: Int64, complete: Bool) {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isSymbolicLinkKey]
        var total: Int64 = 0
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true {
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [], errorHandler: { _, _ in true }) else {
            return (total, false)
        }
        var count = 0
        while let child = enumerator.nextObject() as? URL {
            count += 1
            if count > sizeEntryLimit { return (total, false) }
            guard let values = try? child.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return (total, true)
    }

    // MARK: pluginkit

    static func item(for record: PluginKitRecord) -> ExtensionItem {
        let isSafari = record.extensionPoint.map(ExtensionPointNames.safariPoints.contains) ?? false
        let fileName = URL(fileURLWithPath: record.path).deletingPathExtension().lastPathComponent
        let parentName = record.parentName
            ?? record.parentPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        return ExtensionItem(
            kind: isSafari ? .safariExtension : .appExtension,
            path: record.path,
            name: record.displayName ?? fileName,
            bundleIdentifier: record.identifier,
            version: record.version,
            domain: .application,
            bytes: 0,
            sizeIsLowerBound: false,
            signing: .notChecked,
            parentName: parentName,
            parentPath: record.parentPath,
            election: record.election,
            extensionPoint: record.extensionPoint,
            obsolescence: nil,
            isSymbolicLink: false,
            identity: nil,
            modified: nil,
            management: isSafari ? .safariSettings : .withParentApplication(parentName ?? fileName)
        )
    }
}
