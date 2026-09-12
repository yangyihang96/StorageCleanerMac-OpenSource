import Foundation

enum OfficialPackageType: String, Codable, CaseIterable, Sendable {
    case application = "app"
    case diskImage = "dmg"
    case zipArchive = "zip"
    case installerPackage = "pkg"
}

enum PackageValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedExtension(String)
    case extensionNotExpected(String)
    case notARegularFile
    case emptyFile
    case fileTooLarge
    case tooManyArchiveEntries
    case archiveExpansionTooLarge
    case suspiciousCompressionRatio
    case invalidArchivePath(String)
    case escapingSymbolicLink(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedExtension(value):
            return OfficialUpdateLocalization.format("不支持官网更新包格式 .%@。", "Unsupported official update package format: .%@.", value)
        case let .extensionNotExpected(value):
            return OfficialUpdateLocalization.format("官方来源未声明 .%@ 格式。", "The official source did not declare the .%@ package format.", value)
        case .notARegularFile:
            return L10n.text("更新包不是普通文件。", "The update package is not a regular file.")
        case .emptyFile:
            return L10n.text("更新包为空。", "The update package is empty.")
        case .fileTooLarge:
            return L10n.text("更新包超过安全大小限制。", "The update package exceeds the safety size limit.")
        case .tooManyArchiveEntries:
            return L10n.text("压缩包条目数超过安全限制。", "The archive has too many entries.")
        case .archiveExpansionTooLarge:
            return L10n.text("压缩包解压后大小超过安全限制。", "The expanded archive exceeds the safety size limit.")
        case .suspiciousCompressionRatio:
            return L10n.text("压缩包的压缩比异常。", "The archive has a suspicious compression ratio.")
        case let .invalidArchivePath(path):
            return OfficialUpdateLocalization.format("压缩包包含不安全路径：%@", "The archive contains an unsafe path: %@", path)
        case let .escapingSymbolicLink(path):
            return OfficialUpdateLocalization.format("压缩包符号链接超出解压目录：%@", "An archive symlink escapes the extraction root: %@", path)
        }
    }
}

struct PackageTypeValidator: Sendable {
    static let supportedExtensions = Set(OfficialPackageType.allCases.map(\.rawValue))

    let maximumDownloadBytes: Int64

    init(maximumDownloadBytes: Int64 = 20 * 1_024 * 1_024 * 1_024) {
        self.maximumDownloadBytes = maximumDownloadBytes
    }

    func validateRemoteURL(_ url: URL, expectedExtensions: Set<String>) throws -> OfficialPackageType {
        let pathExtension = url.pathExtension.lowercased()
        guard let kind = OfficialPackageType(rawValue: pathExtension) else {
            throw PackageValidationError.unsupportedExtension(pathExtension)
        }
        let normalizedExpected = Set(expectedExtensions.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        guard normalizedExpected.contains(pathExtension) else {
            throw PackageValidationError.extensionNotExpected(pathExtension)
        }
        return kind
    }

    func validateDownloadedFile(
        at url: URL,
        expectedExtensions: Set<String>,
        reportedContentLength: Int64? = nil
    ) throws -> OfficialPackageType {
        let kind = try validateRemoteURL(url, expectedExtensions: expectedExtensions)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw PackageValidationError.notARegularFile }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else { throw PackageValidationError.emptyFile }
        guard size <= maximumDownloadBytes else { throw PackageValidationError.fileTooLarge }
        if let reportedContentLength, reportedContentLength > 0,
           abs(size - reportedContentLength) > max(4_096, reportedContentLength / 100) {
            throw PackageValidationError.fileTooLarge
        }
        return kind
    }
}

enum ArchiveEntryKind: String, Codable, Sendable {
    case file
    case directory
    case symbolicLink
}

struct ArchiveEntryDescriptor: Codable, Hashable, Sendable {
    let path: String
    let kind: ArchiveEntryKind
    let compressedSize: Int64
    let uncompressedSize: Int64
    let symbolicLinkTarget: String?

    init(
        path: String,
        kind: ArchiveEntryKind,
        compressedSize: Int64 = 0,
        uncompressedSize: Int64 = 0,
        symbolicLinkTarget: String? = nil
    ) {
        self.path = path
        self.kind = kind
        self.compressedSize = compressedSize
        self.uncompressedSize = uncompressedSize
        self.symbolicLinkTarget = symbolicLinkTarget
    }
}

struct ArchiveExtractionValidator: Sendable {
    let maximumEntryCount: Int
    let maximumExpandedBytes: Int64
    let maximumCompressionRatio: Double
    let maximumPathLength: Int

    init(
        maximumEntryCount: Int = 50_000,
        maximumExpandedBytes: Int64 = 40 * 1_024 * 1_024 * 1_024,
        maximumCompressionRatio: Double = 1_000,
        maximumPathLength: Int = 1_024
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumExpandedBytes = maximumExpandedBytes
        self.maximumCompressionRatio = maximumCompressionRatio
        self.maximumPathLength = maximumPathLength
    }

    /// This validates metadata before extraction. It deliberately does not run an
    /// unzip tool; the caller must enumerate entries using a bounded archive reader.
    func validate(entries: [ArchiveEntryDescriptor]) throws {
        guard entries.count <= maximumEntryCount else { throw PackageValidationError.tooManyArchiveEntries }

        var totalCompressed: Int64 = 0
        var totalExpanded: Int64 = 0
        for entry in entries {
            try validateRelativePath(entry.path)
            guard entry.compressedSize >= 0, entry.uncompressedSize >= 0 else {
                throw PackageValidationError.invalidArchivePath(entry.path)
            }
            totalCompressed = try addingWithoutOverflow(totalCompressed, entry.compressedSize)
            totalExpanded = try addingWithoutOverflow(totalExpanded, entry.uncompressedSize)
            guard totalExpanded <= maximumExpandedBytes else {
                throw PackageValidationError.archiveExpansionTooLarge
            }

            if entry.kind == .symbolicLink {
                guard let target = entry.symbolicLinkTarget, !target.isEmpty else {
                    throw PackageValidationError.escapingSymbolicLink(entry.path)
                }
                try validateSymbolicLink(path: entry.path, target: target)
            }
        }

        if totalExpanded > 0 {
            guard totalCompressed > 0 else { throw PackageValidationError.suspiciousCompressionRatio }
            let ratio = Double(totalExpanded) / Double(totalCompressed)
            guard ratio <= maximumCompressionRatio else { throw PackageValidationError.suspiciousCompressionRatio }
        }
    }

    func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              path.utf8.count <= maximumPathLength,
              !path.contains("\0"),
              !path.contains("\\"),
              !path.hasPrefix("/"),
              !path.hasPrefix("~"),
              !Self.hasWindowsDrivePrefix(path) else {
            throw PackageValidationError.invalidArchivePath(path)
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ component in
            !component.isEmpty && component != "." && component != ".."
        }) else {
            throw PackageValidationError.invalidArchivePath(path)
        }
    }

    private func validateSymbolicLink(path: String, target: String) throws {
        guard !target.hasPrefix("/"), !target.hasPrefix("~"), !target.contains("\\"),
              !Self.hasWindowsDrivePrefix(target) else {
            throw PackageValidationError.escapingSymbolicLink(path)
        }

        var stack = Array(path.split(separator: "/").dropLast()).map(String.init)
        for component in target.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                guard !stack.isEmpty else { throw PackageValidationError.escapingSymbolicLink(path) }
                stack.removeLast()
            default:
                stack.append(component)
            }
        }
    }

    private func addingWithoutOverflow(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        guard !overflow else { throw PackageValidationError.archiveExpansionTooLarge }
        return result
    }

    private static func hasWindowsDrivePrefix(_ path: String) -> Bool {
        let scalars = Array(path.unicodeScalars.prefix(2))
        guard scalars.count == 2 else { return false }
        return CharacterSet.letters.contains(scalars[0]) && scalars[1] == ":"
    }
}
