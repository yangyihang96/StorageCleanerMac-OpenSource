import Foundation
import Security
import CryptoKit

/// A versioned, local ownership decision. Names discover candidates; they do
/// not issue this evidence. Shared and unreadable containers fail closed.
struct UninstallOwnershipEvidence: Codable, Hashable, Sendable {
    enum Basis: String, Codable, Sendable { case containerRequirement, vendorRule }
    let basis: Basis
    let bundleID: String
    let teamID: String
    let applicationIdentity: FileIdentity
    let path: String
    let identity: FileIdentity
    let source: String
    let sourceHash: String
    let checkedAt: Date
    var applicationVersion: String? = nil
    var applicationBuild: String? = nil
}

enum UninstallOwnershipVerifier {
    static let metadataName = ".com.apple.containermanagerd.metadata.plist"
    static let vscodeSource = "https://code.visualstudio.com/docs/setup/uninstall#clean-uninstall"

    static func prepare(_ app: InstalledAppItem, inventory: [InstalledAppItem], complete: Bool,
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> InstalledAppItem {
        let signature = try? CodeSignatureVerifier().verifyCode(at: URL(fileURLWithPath: app.path))
        let team = signature?.teamIdentifier ?? ""
        let vendorRules = UninstallVendorRules.rules(bundleID: app.bundleIdentifier, version: app.version, teamID: team)
        let home = homeDirectory
        // D87: documented paths are discovered for any signer so they stay
        // visible; only `vendorRules` (signer-bound) can issue evidence below.
        let extras = UninstallVendorRules.discoveryCandidates(bundleID: app.bundleIdentifier, version: app.version)
            .map { home.appendingPathComponent($0).path }
        let unmeasured = UninstallVendorRules.unmeasuredDiscoveryPaths(bundleID: app.bundleIdentifier)
            .map { home.appendingPathComponent($0).path }
        var result = app
        result.relatedItems = discover(app, additionalPaths: extras, unmeasuredPaths: Set(unmeasured), homeDirectory: homeDirectory)
        result.relatedPaths = result.relatedItems.map(\.path)
        let block: UninstallOwnershipBlockReason?
        if !complete { block = .inventoryIncomplete }
        else if inventory.filter({ $0.bundleIdentifier == app.bundleIdentifier }).count != 1 { block = .otherInstallations }
        else if app.scanIdentity == nil || signature?.codeSigningIdentifier != app.bundleIdentifier || team.isEmpty || !hasAppleAnchor(app.path) { block = .signatureUnverified }
        else { block = nil }
        result.relatedItems = result.relatedItems.map { item in
            var evidence: UninstallOwnershipEvidence?
            if block == nil, let appIdentity = app.scanIdentity, let identity = item.scanIdentity {
                let container = home.appendingPathComponent("Library/Containers/" + app.bundleIdentifier).path
                if item.path == container, let data = metadata(at: item.path),
                   containerMatches(data, appPath: app.path, bundleID: app.bundleIdentifier) {
                    evidence = .init(basis: .containerRequirement, bundleID: app.bundleIdentifier, teamID: team,
                        applicationIdentity: appIdentity, path: item.path, identity: identity,
                        source: item.path + "/" + metadataName, sourceHash: digest(data), checkedAt: Date(), applicationVersion: app.version, applicationBuild: app.build)
                } else if let rule = vendorRules.first(where: { home.appendingPathComponent($0.relativePath).path == item.path }) {
                    evidence = .init(basis: .vendorRule, bundleID: app.bundleIdentifier, teamID: team,
                        applicationIdentity: appIdentity, path: item.path, identity: identity,
                        source: rule.source, sourceHash: rule.revision, checkedAt: Date(), applicationVersion: app.version, applicationBuild: app.build)
                }
            }
            return .init(path: item.path, sizeBytes: item.sizeBytes, scanIdentity: item.scanIdentity,
                ownershipEvidence: evidence, sizeIsKnown: item.sizeIsKnown,
                ownershipBlockReason: item.scanIdentity == nil ? item.ownershipBlockReason : (block ?? .notVerified))
        }
        return result
    }

    /// Refresh at selection time, not from the potentially hours-old inventory.
    /// Permission failures remain visible; they are never silently called absent.
    /// `unmeasuredPaths` are only checked with `lstat` (existence, identity)
    /// and never walked; their size stays unknown (D87 shared groups).
    static func discover(_ app: InstalledAppItem, additionalPaths: [String] = [], unmeasuredPaths: Set<String> = [],
                         homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledAppRelatedItem] {
        let paths = Set(app.relatedItems.map(\.path) + additionalPaths + UninstallCandidatePathPolicy.candidateURLs(
            bundleIdentifier: app.bundleIdentifier, homeDirectory: homeDirectory).map(\.path))
        let deadline = Date().addingTimeInterval(3)
        return paths.sorted().compactMap { path in
            guard !Task.isCancelled else { return nil }
            guard path == PathSafety.lexicalPath(path) else { return nil }
            do {
                // lstat distinguishes absence from denied access before the fail-closed
                // component check (which also returns true for missing components).
                let snapshot = try FoundationReadOnlyFileSystem().aggregateSnapshot(at: URL(fileURLWithPath: path))
                guard !PathSafety.containsSymbolicLinkComponent(in: path), AppUninstallService.isSafeRelatedPath(path, homeDirectory: homeDirectory) else {
                    return .init(path: path, sizeBytes: 0, sizeIsKnown: false, ownershipBlockReason: .unsafePath)
                }
                if unmeasuredPaths.contains(path) {
                    return .init(path: path, sizeBytes: 0, scanIdentity: snapshot.identity, sizeIsKnown: false)
                }
                let measured = measure(URL(fileURLWithPath: path), deadline: deadline)
                return .init(path: path, sizeBytes: measured.bytes, scanIdentity: snapshot.identity, sizeIsKnown: measured.complete)
            } catch CleanupFileSystemError.vanished { return nil }
            catch { return .init(path: path, sizeBytes: 0, sizeIsKnown: false, ownershipBlockReason: .unreadable) }
        }
    }

    private static func measure(_ url: URL, deadline: Date) -> (bytes: Int64, complete: Bool) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let root = try? url.resourceValues(forKeys: keys) else { return (0, false) }
        if root.isRegularFile == true { return (Int64(root.fileSize ?? 0), root.fileSize != nil) }
        guard root.isDirectory == true else { return (0, false) }
        var complete = true
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, _ in complete = false; return true }) else { return (0, false) }
        var bytes: Int64 = 0; var count = 0
        for case let child as URL in walker {
            guard !Task.isCancelled, Date() < deadline, count < 25_000 else { return (bytes, false) }
            count += 1
            guard let values = try? child.resourceValues(forKeys: keys) else { complete = false; continue }
            if values.isRegularFile == true, let size = values.fileSize { bytes += Int64(size) }
        }
        return (bytes, complete)
    }

    static func canResumeResiduals(bundleID: String, inventory: [InstalledAppItem], complete: Bool) -> Bool {
        complete && !inventory.contains { $0.bundleIdentifier == bundleID }
    }

    static func hasAppleAnchor(_ path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return CodeSignatureVerifier.isAppleAnchored(code)
    }

    static func metadata(at container: String) -> Data? {
        let url = URL(fileURLWithPath: container).appendingPathComponent(metadataName)
        guard !PathSafety.containsSymbolicLinkComponent(in: url.path),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, size <= 1_048_576 else { return nil }
        return try? Data(contentsOf: url, options: .uncached)
    }

    static func containerMatches(_ data: Data, appPath: String, bundleID: String) -> Bool {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["MCMMetadataIdentifier"] as? String == bundleID,
              let info = plist["MCMMetadataInfo"] as? [String: Any],
              let identities = info["Identity"] as? [Data], !identities.isEmpty, identities.count <= 16 else { return false }
        // An unknown or multiple-owner encoding is not proof of exclusivity.
        if let owners = info["Owners"], (owners as? String) != bundleID { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        // Reject broader requirements that happen to accept this app (for
        // example `identifier "this.app" or true`). Compare the complete
        // platform-generated requirement, not a substring or a successful match.
        var designated: SecRequirement?
        var signingInformation: CFDictionary?
        guard SecCodeCopyDesignatedRequirement(code, [], &designated) == errSecSuccess,
              let designated,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSRequirementInformation), &signingInformation) == errSecSuccess,
              let information = signingInformation as? [String: Any],
              let implicitValue = information[kSecCodeInfoImplicitDesignatedRequirement as String],
              CFGetTypeID(implicitValue as CFTypeRef) == SecRequirementGetTypeID() else { return false }
        let implicit = implicitValue as! SecRequirement // type ID checked above
        var designatedData: CFData?
        var implicitData: CFData?
        guard SecRequirementCopyData(designated, [], &designatedData) == errSecSuccess,
              SecRequirementCopyData(implicit, [], &implicitData) == errSecSuccess,
              let designatedData, let implicitData,
              (designatedData as Data) == (implicitData as Data),
              identities.allSatisfy({ $0 == (implicitData as Data) }) else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), implicit) == errSecSuccess

    }

    static func isCurrent(_ item: InstalledAppRelatedItem, app: InstalledAppItem,
                          homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        guard let proof = item.ownershipEvidence, proof.path == item.path,
              proof.bundleID == app.bundleIdentifier, proof.applicationIdentity == app.scanIdentity,
              proof.identity == item.scanIdentity,
              proof.applicationVersion == app.version, proof.applicationBuild == app.build else { return false }
        switch proof.basis {
        case .containerRequirement:
            let expected = homeDirectory.appendingPathComponent("Library/Containers/" + app.bundleIdentifier).path
            guard UninstallCandidatePathPolicy.isSafeComponent(app.bundleIdentifier), item.path == expected,
                  proof.source == expected + "/" + metadataName,
                  let data = metadata(at: item.path) else { return false }
            return digest(data) == proof.sourceHash
        case .vendorRule:
            return UninstallVendorRules.rules(bundleID: app.bundleIdentifier, version: app.version, teamID: proof.teamID).contains {
                proof.source == $0.source && proof.sourceHash == $0.revision
                    && item.path == homeDirectory.appendingPathComponent($0.relativePath).path
            }
        }
    }

    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}


enum UninstallOwnershipBlockReason: String, Hashable, Sendable {
    case inventoryIncomplete, otherInstallations, signatureUnverified, notVerified, unreadable, unsafePath
    var title: String {
        switch self {
        case .unreadable: L10n.text("无读取权限，已保留", "Cannot read; kept")
        case .unsafePath: L10n.text("路径已变化或含符号链接，已保留", "Changed path or symbolic link; kept")
        case .inventoryIncomplete: L10n.text("应用清单不完整，已保留", "The application inventory is incomplete; other users of this data cannot be excluded.")
        case .otherInstallations: L10n.text("存在其他安装副本，已保留", "Another installation or an ambiguous app identity requires retaining this data.")
        case .signatureUnverified: L10n.text("应用签名未核实，已保留", "The application signature and scanned identity could not be verified; related data is retained.")
        case .notVerified: L10n.text("归属未确认，已保留", "Exclusive ownership could not be verified; this item is retained.")
        }
    }
}
