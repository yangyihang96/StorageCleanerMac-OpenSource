import Foundation
import zlib

enum SecureZipArchiveError: Error, Equatable, LocalizedError, Sendable {
    case invalidArchive
    case unsupportedZip64
    case encryptedEntry(String)
    case unsupportedEntryFlags(UInt16, String)
    case unsupportedCompressionMethod(UInt16, String)
    case unsupportedEntryType(String)
    case duplicatePath(String)
    case pathTypeConflict(String)
    case localHeaderMismatch(String)
    case extractionFailed
    case extractedEntryMissing(String)
    case extractedEntryChanged(String)
    case checksumMismatch(String)
    case destinationAlreadyExists

    var errorDescription: String? {
        switch self {
        case .invalidArchive:
            L10n.text("ZIP 更新包结构无效。", "The ZIP update archive is invalid.")
        case .unsupportedZip64:
            L10n.text("当前不自动安装 ZIP64 更新包。", "ZIP64 update archives are not installed automatically.")
        case let .encryptedEntry(path):
            OfficialUpdateLocalization.format("ZIP 条目已加密：%@。", "The ZIP entry is encrypted: %@.", path)
        case let .unsupportedEntryFlags(flags, path):
            OfficialUpdateLocalization.format(
                "ZIP 条目使用了不支持的 flags 0x%04x：%@。",
                "The ZIP entry uses unsupported flags 0x%04x: %@.",
                flags,
                path
            )
        case let .unsupportedCompressionMethod(method, path):
            OfficialUpdateLocalization.format(
                "ZIP 条目使用了不支持的压缩方式 %u：%@。",
                "The ZIP entry uses unsupported compression method %u: %@.",
                method,
                path
            )
        case let .unsupportedEntryType(path):
            OfficialUpdateLocalization.format("ZIP 包含不支持的条目类型：%@。", "The ZIP contains an unsupported entry type: %@.", path)
        case let .duplicatePath(path):
            OfficialUpdateLocalization.format("ZIP 包含重复路径：%@。", "The ZIP contains a duplicate path: %@.", path)
        case let .pathTypeConflict(path):
            OfficialUpdateLocalization.format("ZIP 路径类型冲突：%@。", "The ZIP contains a path type conflict: %@.", path)
        case let .localHeaderMismatch(path):
            OfficialUpdateLocalization.format("ZIP 条目的本地头信息不一致：%@。", "The ZIP entry local header does not match: %@.", path)
        case .extractionFailed:
            L10n.text("无法安全解压 ZIP 更新包。", "The ZIP update archive could not be extracted safely.")
        case let .extractedEntryMissing(path):
            OfficialUpdateLocalization.format("解压后缺少 ZIP 条目：%@。", "An extracted ZIP entry is missing: %@.", path)
        case let .extractedEntryChanged(path):
            OfficialUpdateLocalization.format("解压后的 ZIP 条目类型或大小已改变：%@。", "An extracted ZIP entry changed type or size: %@.", path)
        case let .checksumMismatch(path):
            OfficialUpdateLocalization.format("ZIP 条目校验失败：%@。", "A ZIP entry failed checksum verification: %@.", path)
        case .destinationAlreadyExists:
            L10n.text("ZIP 解压目标必须是全新目录。", "The ZIP extraction destination must be a new directory.")
        }
    }
}

struct SecureZipArchiveEntry: Equatable, Sendable {
    let rawName: Data
    let relativePath: String
    let kind: ArchiveEntryKind
    let compressionMethod: UInt16
    let flags: UInt16
    let crc32: UInt32
    let compressedSize: Int64
    let uncompressedSize: Int64
    let localHeaderOffset: Int64
    let dataOffset: Int64
    let permissions: Int
    let symbolicLinkTarget: String?

    var descriptor: ArchiveEntryDescriptor {
        ArchiveEntryDescriptor(
            path: relativePath,
            kind: kind,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            symbolicLinkTarget: symbolicLinkTarget
        )
    }
}

/// A narrow ZIP reader used only for verified official application updates.
///
/// It reads the central directory itself before invoking the fixed system
/// extractor. Paths, sizes, compression ratios, entry types and symlink targets
/// are therefore rejected before extraction. The fresh extraction tree is then
/// re-read entry-by-entry (including CRC-32) before any application is selected.
struct SecureZipArchiveExtractor: Sendable {
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localFileHeaderSignature: UInt32 = 0x0403_4B50
    private static let maximumCommentLength = 65_535
    private static let maximumCentralDirectoryBytes = 128 * 1_024 * 1_024
    private static let maximumSymbolicLinkBytes = 4_096

    private let validator: ArchiveExtractionValidator

    init(validator: ArchiveExtractionValidator = ArchiveExtractionValidator()) {
        self.validator = validator
    }

    func validateArchive(at archiveURL: URL) throws {
        _ = try manifest(at: archiveURL)
    }

    func extract(archiveURL: URL, to destinationURL: URL) async throws {
        let entries = try manifest(at: archiveURL)
        guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw SecureZipArchiveError.destinationAlreadyExists
        }
        try FileManager.default.createDirectory(
            at: destinationURL,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let cancellation = SecureZipExtractionCancellation()
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                try Shell.run(
                    "/usr/bin/ditto",
                    ["-x", "-k", archiveURL.path, destinationURL.path],
                    timeout: 30 * 60,
                    outputByteLimit: 1_048_576,
                    cancellationCheck: { cancellation.isCancelled }
                )
            }.value
        } onCancel: {
            cancellation.cancel()
        }
        guard result.terminationStatus == 0 else {
            throw SecureZipArchiveError.extractionFailed
        }
        try validateExtractedTree(entries, root: destinationURL)
    }

    func manifest(at archiveURL: URL) throws -> [SecureZipArchiveEntry] {
        let values = try archiveURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let rawFileSize = values.fileSize, rawFileSize > 0 else {
            throw SecureZipArchiveError.invalidArchive
        }
        let fileSize = Int64(rawFileSize)
        let handle = try FileHandle(forReadingFrom: archiveURL)
        defer { try? handle.close() }

        let tailSize = min(
            fileSize,
            Int64(Self.maximumCommentLength + 22)
        )
        let tail = try readExactly(
            handle,
            offset: fileSize - tailSize,
            count: Int(tailSize)
        )
        let eocdIndex = try endOfCentralDirectoryIndex(in: tail)
        let absoluteEOCDOffset = fileSize - tailSize + Int64(eocdIndex)

        let diskNumber = tail.uint16LE(at: eocdIndex + 4)
        let centralDirectoryDisk = tail.uint16LE(at: eocdIndex + 6)
        let diskEntryCount = tail.uint16LE(at: eocdIndex + 8)
        let entryCount = tail.uint16LE(at: eocdIndex + 10)
        let centralDirectorySize32 = tail.uint32LE(at: eocdIndex + 12)
        let centralDirectoryOffset32 = tail.uint32LE(at: eocdIndex + 16)
        guard diskNumber == 0,
              centralDirectoryDisk == 0,
              diskEntryCount == entryCount else {
            throw SecureZipArchiveError.invalidArchive
        }
        guard entryCount != UInt16.max,
              centralDirectorySize32 != UInt32.max,
              centralDirectoryOffset32 != UInt32.max else {
            throw SecureZipArchiveError.unsupportedZip64
        }

        let centralDirectorySize = Int64(centralDirectorySize32)
        let centralDirectoryOffset = Int64(centralDirectoryOffset32)
        guard centralDirectorySize >= 0,
              centralDirectorySize <= Int64(Self.maximumCentralDirectoryBytes),
              centralDirectoryOffset >= 0,
              centralDirectoryOffset <= absoluteEOCDOffset,
              centralDirectorySize <= absoluteEOCDOffset - centralDirectoryOffset else {
            throw SecureZipArchiveError.invalidArchive
        }
        let centralDirectory = try readExactly(
            handle,
            offset: centralDirectoryOffset,
            count: Int(centralDirectorySize)
        )

        var entries: [SecureZipArchiveEntry] = []
        entries.reserveCapacity(Int(entryCount))
        var cursor = 0
        for _ in 0..<Int(entryCount) {
            guard cursor <= centralDirectory.count - 46,
                  centralDirectory.uint32LE(at: cursor) == Self.centralDirectorySignature else {
                throw SecureZipArchiveError.invalidArchive
            }
            let versionMadeBy = centralDirectory.uint16LE(at: cursor + 4)
            let flags = centralDirectory.uint16LE(at: cursor + 8)
            let compressionMethod = centralDirectory.uint16LE(at: cursor + 10)
            let checksum = centralDirectory.uint32LE(at: cursor + 16)
            let compressedSize32 = centralDirectory.uint32LE(at: cursor + 20)
            let uncompressedSize32 = centralDirectory.uint32LE(at: cursor + 24)
            let nameLength = Int(centralDirectory.uint16LE(at: cursor + 28))
            let extraLength = Int(centralDirectory.uint16LE(at: cursor + 30))
            let commentLength = Int(centralDirectory.uint16LE(at: cursor + 32))
            let diskStart = centralDirectory.uint16LE(at: cursor + 34)
            let externalAttributes = centralDirectory.uint32LE(at: cursor + 38)
            let localHeaderOffset32 = centralDirectory.uint32LE(at: cursor + 42)
            guard diskStart == 0 else { throw SecureZipArchiveError.invalidArchive }
            guard compressedSize32 != UInt32.max,
                  uncompressedSize32 != UInt32.max,
                  localHeaderOffset32 != UInt32.max else {
                throw SecureZipArchiveError.unsupportedZip64
            }

            let recordLength = 46 + nameLength + extraLength + commentLength
            guard nameLength > 0,
                  recordLength >= 46,
                  cursor <= centralDirectory.count - recordLength else {
                throw SecureZipArchiveError.invalidArchive
            }
            let rawName = centralDirectory.subdata(
                in: (cursor + 46)..<(cursor + 46 + nameLength)
            )
            guard let decodedName = String(data: rawName, encoding: .utf8) else {
                throw SecureZipArchiveError.invalidArchive
            }
            let relativePath = decodedName.hasSuffix("/")
                ? String(decodedName.dropLast())
                : decodedName
            try validator.validateRelativePath(relativePath)
            guard flags & 0x0041 == 0 else {
                throw SecureZipArchiveError.encryptedEntry(relativePath)
            }
            let supportedFlags: UInt16 = 0x080E
            guard flags & ~supportedFlags == 0 else {
                throw SecureZipArchiveError.unsupportedEntryFlags(flags, relativePath)
            }
            guard compressionMethod == 0 || compressionMethod == 8 else {
                throw SecureZipArchiveError.unsupportedCompressionMethod(
                    compressionMethod,
                    relativePath
                )
            }

            let kindAndMode = try entryKindAndPermissions(
                path: decodedName,
                versionMadeBy: versionMadeBy,
                externalAttributes: externalAttributes
            )
            let localHeaderOffset = Int64(localHeaderOffset32)
            let local = try localEntryMetadata(
                handle: handle,
                rawName: rawName,
                path: relativePath,
                expectedFlags: flags,
                expectedCompressionMethod: compressionMethod,
                localHeaderOffset: localHeaderOffset,
                compressedSize: Int64(compressedSize32),
                centralDirectoryOffset: centralDirectoryOffset
            )
            var symbolicLinkTarget: String?
            if kindAndMode.kind == .symbolicLink {
                guard compressedSize32 <= Self.maximumSymbolicLinkBytes,
                      uncompressedSize32 > 0,
                      uncompressedSize32 <= Self.maximumSymbolicLinkBytes else {
                    throw SecureZipArchiveError.unsupportedEntryType(relativePath)
                }
                let compressed = try readExactly(
                    handle,
                    offset: local.dataOffset,
                    count: Int(compressedSize32)
                )
                let targetData = try decodedEntryData(
                    compressed,
                    method: compressionMethod,
                    expectedSize: Int(uncompressedSize32)
                )
                guard let target = String(data: targetData, encoding: .utf8),
                      !target.isEmpty,
                      !target.contains("\0") else {
                    throw SecureZipArchiveError.unsupportedEntryType(relativePath)
                }
                guard self.checksum(of: targetData) == checksum else {
                    throw SecureZipArchiveError.checksumMismatch(relativePath)
                }
                symbolicLinkTarget = target
            }

            entries.append(SecureZipArchiveEntry(
                rawName: rawName,
                relativePath: relativePath,
                kind: kindAndMode.kind,
                compressionMethod: compressionMethod,
                flags: flags,
                crc32: checksum,
                compressedSize: Int64(compressedSize32),
                uncompressedSize: Int64(uncompressedSize32),
                localHeaderOffset: localHeaderOffset,
                dataOffset: local.dataOffset,
                permissions: kindAndMode.permissions,
                symbolicLinkTarget: symbolicLinkTarget
            ))
            cursor += recordLength
        }
        guard cursor == centralDirectory.count else {
            throw SecureZipArchiveError.invalidArchive
        }

        try validator.validate(entries: entries.map(\.descriptor))
        try validatePathGraph(entries)
        return entries
    }

    private func endOfCentralDirectoryIndex(in tail: Data) throws -> Int {
        guard tail.count >= 22 else { throw SecureZipArchiveError.invalidArchive }
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            guard tail.uint32LE(at: index) == Self.endOfCentralDirectorySignature else {
                continue
            }
            let commentLength = Int(tail.uint16LE(at: index + 20))
            guard index + 22 + commentLength == tail.count else { continue }
            return index
        }
        throw SecureZipArchiveError.invalidArchive
    }

    private func entryKindAndPermissions(
        path: String,
        versionMadeBy: UInt16,
        externalAttributes: UInt32
    ) throws -> (kind: ArchiveEntryKind, permissions: Int) {
        let hostSystem = UInt8(truncatingIfNeeded: versionMadeBy >> 8)
        let unixMode = Int(externalAttributes >> 16)
        let fileType = unixMode & 0o170000
        let kind: ArchiveEntryKind
        if path.hasSuffix("/") || fileType == 0o040000 {
            kind = .directory
        } else if (hostSystem == 3 || hostSystem == 19), fileType == 0o120000 {
            kind = .symbolicLink
        } else if fileType == 0 || fileType == 0o100000 {
            kind = .file
        } else {
            throw SecureZipArchiveError.unsupportedEntryType(path)
        }
        let declaredPermissions = unixMode & 0o777
        let fallback = kind == .directory ? 0o755 : 0o644
        return (kind, declaredPermissions == 0 ? fallback : declaredPermissions)
    }

    private func localEntryMetadata(
        handle: FileHandle,
        rawName: Data,
        path: String,
        expectedFlags: UInt16,
        expectedCompressionMethod: UInt16,
        localHeaderOffset: Int64,
        compressedSize: Int64,
        centralDirectoryOffset: Int64
    ) throws -> (dataOffset: Int64, range: Range<Int64>) {
        let header = try readExactly(handle, offset: localHeaderOffset, count: 30)
        guard header.uint32LE(at: 0) == Self.localFileHeaderSignature,
              header.uint16LE(at: 6) == expectedFlags,
              header.uint16LE(at: 8) == expectedCompressionMethod else {
            throw SecureZipArchiveError.localHeaderMismatch(path)
        }
        let nameLength = Int(header.uint16LE(at: 26))
        let extraLength = Int(header.uint16LE(at: 28))
        let localName = try readExactly(
            handle,
            offset: localHeaderOffset + 30,
            count: nameLength
        )
        guard localName == rawName else {
            throw SecureZipArchiveError.localHeaderMismatch(path)
        }
        let dataOffset = localHeaderOffset + 30 + Int64(nameLength + extraLength)
        guard localHeaderOffset >= 0,
              dataOffset >= localHeaderOffset,
              compressedSize >= 0,
              dataOffset <= centralDirectoryOffset,
              compressedSize <= centralDirectoryOffset - dataOffset else {
            throw SecureZipArchiveError.invalidArchive
        }
        return (dataOffset, dataOffset..<(dataOffset + compressedSize))
    }

    private func validatePathGraph(_ entries: [SecureZipArchiveEntry]) throws {
        var kindsByPath: [String: ArchiveEntryKind] = [:]
        for entry in entries {
            let key = normalizedPathKey(entry.relativePath)
            guard kindsByPath[key] == nil else {
                throw SecureZipArchiveError.duplicatePath(entry.relativePath)
            }
            kindsByPath[key] = entry.kind
        }

        for entry in entries {
            let components = entry.relativePath.split(separator: "/").map(String.init)
            guard components.count > 1 else { continue }
            for length in 1..<components.count {
                let parent = normalizedPathKey(components.prefix(length).joined(separator: "/"))
                if let kind = kindsByPath[parent], kind != .directory {
                    throw SecureZipArchiveError.pathTypeConflict(entry.relativePath)
                }
            }
        }
    }

    private func validateExtractedTree(
        _ entries: [SecureZipArchiveEntry],
        root: URL
    ) throws {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for entry in entries {
            try Task.checkCancellation()
            // ditto may consume AppleDouble metadata instead of materializing
            // the __MACOSX sidecar entry. The signed application is still
            // verified after extraction, so those metadata-only files are not
            // treated as candidate content here.
            if entry.relativePath == "__MACOSX"
                || entry.relativePath.hasPrefix("__MACOSX/") {
                continue
            }
            let item = root.appendingPathComponent(entry.relativePath)
            let values: URLResourceValues
            do {
                values = try item.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                ])
            } catch {
                throw SecureZipArchiveError.extractedEntryMissing(entry.relativePath)
            }
            switch entry.kind {
            case .directory:
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw SecureZipArchiveError.extractedEntryChanged(entry.relativePath)
                }
            case .file:
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true,
                      Int64(values.fileSize ?? -1) == entry.uncompressedSize else {
                    throw SecureZipArchiveError.extractedEntryChanged(entry.relativePath)
                }
                guard try checksum(of: item) == entry.crc32 else {
                    throw SecureZipArchiveError.checksumMismatch(entry.relativePath)
                }
            case .symbolicLink:
                guard values.isSymbolicLink == true,
                      let expectedTarget = entry.symbolicLinkTarget,
                      try FileManager.default.destinationOfSymbolicLink(atPath: item.path)
                        == expectedTarget else {
                    throw SecureZipArchiveError.extractedEntryChanged(entry.relativePath)
                }
                let resolved = item.resolvingSymlinksInPath().standardizedFileURL.path
                guard resolved == rootPath || resolved.hasPrefix(rootPrefix) else {
                    throw PackageValidationError.escapingSymbolicLink(entry.relativePath)
                }
            }
        }
    }

    private func checksum(of url: URL) throws -> UInt32 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var value: uLong = crc32(0, nil, 0)
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            value = data.withUnsafeBytes { buffer in
                guard let base = buffer.bindMemory(to: Bytef.self).baseAddress else { return value }
                return crc32(value, base, uInt(buffer.count))
            }
        }
        return UInt32(truncatingIfNeeded: value)
    }

    private func checksum(of data: Data) -> UInt32 {
        let value = data.withUnsafeBytes { buffer -> uLong in
            guard let base = buffer.bindMemory(to: Bytef.self).baseAddress else {
                return crc32(0, nil, 0)
            }
            return crc32(crc32(0, nil, 0), base, uInt(buffer.count))
        }
        return UInt32(truncatingIfNeeded: value)
    }

    private func decodedEntryData(
        _ compressed: Data,
        method: UInt16,
        expectedSize: Int
    ) throws -> Data {
        switch method {
        case 0:
            guard compressed.count == expectedSize else {
                throw SecureZipArchiveError.invalidArchive
            }
            return compressed
        case 8:
            var stream = z_stream()
            let initialized = inflateInit2_(
                &stream,
                -MAX_WBITS,
                ZLIB_VERSION,
                Int32(MemoryLayout<z_stream>.size)
            )
            guard initialized == Z_OK else { throw SecureZipArchiveError.invalidArchive }
            defer { inflateEnd(&stream) }

            var input = [UInt8](compressed)
            var decoded = Data()
            decoded.reserveCapacity(expectedSize)
            var status: Int32 = Z_OK
            try input.withUnsafeMutableBytes { inputBuffer in
                stream.next_in = inputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(inputBuffer.count)
                var output = [UInt8](repeating: 0, count: max(1, expectedSize))
                repeat {
                    let produced = output.withUnsafeMutableBytes { outputBuffer -> Int in
                        stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(outputBuffer.count)
                        status = inflate(&stream, Z_NO_FLUSH)
                        return outputBuffer.count - Int(stream.avail_out)
                    }
                    if produced > 0 {
                        decoded.append(contentsOf: output.prefix(produced))
                    }
                    guard decoded.count <= expectedSize else {
                        throw SecureZipArchiveError.invalidArchive
                    }
                    guard status == Z_OK || status == Z_STREAM_END else {
                        throw SecureZipArchiveError.invalidArchive
                    }
                    if status == Z_OK, produced == 0, stream.avail_in == 0 {
                        throw SecureZipArchiveError.invalidArchive
                    }
                } while status != Z_STREAM_END
            }
            guard stream.avail_in == 0, decoded.count == expectedSize else {
                throw SecureZipArchiveError.invalidArchive
            }
            return decoded
        default:
            throw SecureZipArchiveError.unsupportedCompressionMethod(method, "-")
        }
    }

    private func readExactly(
        _ handle: FileHandle,
        offset: Int64,
        count: Int
    ) throws -> Data {
        guard offset >= 0, count >= 0 else { throw SecureZipArchiveError.invalidArchive }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else {
            throw SecureZipArchiveError.invalidArchive
        }
        return data
    }

    private func normalizedPathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }
}

private extension Data {
    func uint16LE(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func uint32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

private final class SecureZipExtractionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}
