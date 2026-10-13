import CryptoKit
import Foundation

struct SparkleRelease: Hashable, Sendable {
    let version: ApplicationVersion
    let downloadURL: URL
    let edSignature: String?
    let minimumSystemVersion: String?
    let maximumSystemVersion: String?
    let byteCount: Int64?
    let isDelta: Bool
}

enum SparkleAutomaticUpdateError: LocalizedError, Sendable {
    case unsafeFeed, invalidAppcast, invalidSignature, configurationChanged, unsupportedArchive, noNewVersion
    var errorDescription: String? {
        switch self {
        case .unsafeFeed: L10n.text("Sparkle 更新源必须使用安全 HTTPS 地址", "Sparkle requires a secure HTTPS feed")
        case .invalidAppcast: L10n.text("Sparkle 发布清单无效", "Invalid Sparkle appcast")
        case .invalidSignature: L10n.text("Sparkle 附件的 EdDSA 签名无效，旧应用保持原位", "Invalid Sparkle EdDSA signature; the old app is preserved")
        case .configurationChanged: L10n.text("Sparkle 配置或应用身份已改变，请重新检查", "Sparkle configuration or app identity changed; check again")
        case .unsupportedArchive: L10n.text("此 Sparkle 附件格式无法安全自动解包，请打开应用内更新", "This Sparkle archive cannot be safely extracted; open the in-app updater")
        case .noNewVersion: L10n.text("附件版本不高于已安装版本，旧应用保持原位", "The archive version is not newer; the old app is preserved")
        }
    }
}

protocol SparkleAutomaticUpdating: Sendable {
    func check(_ application: InstalledApplication) async throws -> SparkleRelease?
    func install(_ application: InstalledApplication, release: SparkleRelease,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult
}

struct SparkleAutomaticUpdateAdapter: SparkleAutomaticUpdating {
    var fetch: @Sendable (URL, URL) async throws -> Void = { url, destination in
        guard Self.safeHTTPS(url) else { throw SparkleAutomaticUpdateError.unsafeFeed }
        _ = try await OfficialUpdateDownloader(maximumBytes: 1_073_741_824,
            allowedHosts: [url.host!]).download(URLRequest(url: url), stagingURL: destination)
    }
    var installArchive: @Sendable (AuthenticatedUpdateArchive, InstalledApplication, SparkleRelease, @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult = { archive, app, release, progress in
        try await OfficialApplicationUpdateInstaller().installVerifiedSparkleArchive(archive, application: app, release: release, progress: progress)
    }
    var afterAuthentication: @Sendable (URL) async throws -> Void = { _ in }
    var systemVersion: @Sendable () -> String = {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    static func safeHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.isEmpty == false && url.user == nil && url.password == nil
    }

    func check(_ application: InstalledApplication) async throws -> SparkleRelease? {
        guard let configuration = application.sparkleConfiguration,
              let feed = configuration.feedURL, Self.safeHTTPS(feed) else { throw SparkleAutomaticUpdateError.unsafeFeed }
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("appcast.xml")
        try await fetch(feed, file)
        let bytes = try Data(contentsOf: file)
        guard bytes.count <= 4 * 1_024 * 1_024 else { throw SparkleAutomaticUpdateError.invalidAppcast }
        return try SparkleAppcastParser.select(bytes, installed: application.installedVersion, systemVersion: systemVersion())
    }

    func install(_ application: InstalledApplication, release: SparkleRelease,
        progress: @escaping @Sendable (ApplicationUpdateProgressEvent) -> Void) async throws -> ApplicationUpdateInstallResult {
        guard let configuration = application.sparkleConfiguration,
              Self.isNewer(release.version, than: application.installedVersion), Self.safeHTTPS(release.downloadURL), !release.isDelta,
              ["zip", "dmg"].contains(release.downloadURL.pathExtension.lowercased()) else {
            throw SparkleAutomaticUpdateError.noNewVersion
        }
        let root = try workspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("Update." + release.downloadURL.pathExtension.lowercased())
        progress(.init(applicationID: application.id, state: .downloading, fraction: nil, detail: L10n.text("正在下载 Sparkle 签名附件", "Downloading signed Sparkle archive")))
        try await fetch(release.downloadURL, archive)
        try Task.checkCancellation()
        let authenticated = try AuthenticatedUpdateArchive.snapshot(archive)
        let bytes = authenticated.bytes
        if let size = release.byteCount, size > 0, size != Int64(bytes.count) { throw SparkleAutomaticUpdateError.invalidSignature }
        if let key = configuration.publicEDKey?.trimmed.nonEmpty {
            guard let keyData = Data(base64Encoded: key), keyData.count == 32,
                  let signature = release.edSignature.flatMap({ Data(base64Encoded: $0) }),
                  signature.count == 64,
                  let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
                  publicKey.isValidSignature(signature, for: bytes) else { throw SparkleAutomaticUpdateError.invalidSignature }
        } else {
            // Legacy Sparkle: require Apple-anchored old and new code signatures
            // with the identical Team ID; the shared installer enforces both.
            guard application.identity.isCompleteForAutomaticUpdates,
                  application.sourceEvidence.contains("valid-code-signature") else { throw SparkleAutomaticUpdateError.invalidSignature }
        }
        try Task.checkCancellation()
        try await afterAuthentication(archive)
        return try await installArchive(authenticated, application, release, progress)
    }

    static func isNewer(_ candidate: ApplicationVersion, than installed: ApplicationVersion) -> Bool {
        installed < candidate
    }
    private func workspace() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true).appendingPathComponent("StorageCleaner-Sparkle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }
}

final class SparkleAppcastParser: NSObject, XMLParserDelegate {
    private var releases = [SparkleRelease]()
    private var enclosure: [String: String]?
    private var fields = [String: String]()
    private var element = ""
    private var insideItem = false

    static func select(_ data: Data, installed: ApplicationVersion, systemVersion: String) throws -> SparkleRelease? {
        // No DTD/entity expansion or external resources in vendor-controlled XML.
        guard data.count <= 4 * 1_024 * 1_024,
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!DOCTYPE"),
              !String(decoding: data, as: UTF8.self).uppercased().contains("<!ENTITY") else { throw SparkleAutomaticUpdateError.invalidAppcast }
        let parser = XMLParser(data: data)
        let delegate = SparkleAppcastParser()
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw SparkleAutomaticUpdateError.invalidAppcast }
        return delegate.releases.filter { release in
            !release.isDelta && SparkleAutomaticUpdateAdapter.safeHTTPS(release.downloadURL)
                && SparkleAutomaticUpdateAdapter.isNewer(release.version, than: installed)
                && (release.minimumSystemVersion.map { ApplicationVersion.compare(systemVersion, $0) != .orderedAscending } ?? true)
                && (release.maximumSystemVersion.map { ApplicationVersion.compare(systemVersion, $0) != .orderedDescending } ?? true)
        }.max { left, right in SparkleAutomaticUpdateAdapter.isNewer(right.version, than: left.version) }
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "item" { insideItem = true; fields = [:]; enclosure = nil }
        if insideItem && name == "enclosure" && attributes["sparkle:deltaFrom"] == nil && attributes["sparkle:os"] != "windows" { enclosure = attributes }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideItem { fields[element, default: ""] += string }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "item" else { return }
        defer { insideItem = false; element = "" }
        guard let enclosure, let url = enclosure["url"].flatMap(URL.init(string:)),
              let version = (enclosure["sparkle:version"] ?? fields["sparkle:version"])?.trimmed.nonEmpty else { return }
        let marketing = (enclosure["sparkle:shortVersionString"] ?? fields["sparkle:shortVersionString"])?.trimmed.nonEmpty ?? ""
        releases.append(.init(version: .init(marketing: marketing, build: version), downloadURL: url,
            edSignature: enclosure["sparkle:edSignature"], minimumSystemVersion: fields["sparkle:minimumSystemVersion"]?.trimmed,
            maximumSystemVersion: fields["sparkle:maximumSystemVersion"]?.trimmed,
            byteCount: enclosure["length"].flatMap(Int64.init), isDelta: false))
    }
}
