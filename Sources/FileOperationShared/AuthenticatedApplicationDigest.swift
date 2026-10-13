import CryptoKit
import Foundation

/// Binds the authenticated candidate tree, including relative names, types,
/// modes, link targets and every regular byte. Both client and root staging
/// use this exact representation. External links and special files fail closed.
public enum AuthenticatedApplicationDigest {
    public struct Record: Sendable {
        public let path: String
        public let type: FileAttributeType
        public let mode: UInt16
        public let contentDigest: Data
        public let size: UInt64
        public let link: String?
        public init(path: String, type: FileAttributeType, mode: UInt16, contentDigest: Data = Data(), size: UInt64 = 0, link: String? = nil) {
            self.path = path; self.type = type; self.mode = mode; self.contentDigest = contentDigest; self.size = size; self.link = link
        }
    }
    /// Records constructed by the ZIP decoder from authenticated bytes, without
    /// reopening the mutable extracted tree, use the same canonical digest.
    public static func compute(records: [Record]) -> String {
        var hash = SHA256()
        for record in records.sorted(by: { $0.path < $1.path }) {
            hash.update(data: Data("\(record.path.utf8.count):\(record.path):\(record.type.rawValue):\(record.mode)\n".utf8))
            if let link = record.link { hash.update(data: Data("\(link.utf8.count):\(link)\n".utf8)) }
            if record.type == .typeRegular { hash.update(data: record.contentDigest); hash.update(data: Data("\n\(record.size)\n".utf8)) }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func authenticateCopy(_ copy: URL, expectedSHA256: String) throws {
        guard try compute(copy) == expectedSHA256 else { throw CocoaError(.fileReadCorruptFile) }
    }
    public static func compute(_ bundle: URL) throws -> String {
        let root = bundle.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(atPath: bundle.path),
              try FileManager.default.attributesOfItem(atPath: bundle.path)[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadCorruptFile) }
        let paths = enumerator.compactMap { $0 as? String }.sorted()
        var records = [Record]()
        for relative in paths {
            let url = bundle.appendingPathComponent(relative)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let type = attributes[.type] as? FileAttributeType
            let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
            switch type {
            case .typeDirectory: records.append(.init(path: relative, type: .typeDirectory, mode: mode))
            case .typeSymbolicLink:
                guard url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw CocoaError(.fileReadCorruptFile) }
                let link = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                records.append(.init(path: relative, type: .typeSymbolicLink, mode: mode, link: link))
            case .typeRegular:
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var size: UInt64 = 0
                var content = SHA256()
                while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty { content.update(data: bytes); size += UInt64(bytes.count) }
                records.append(.init(path: relative, type: .typeRegular, mode: mode, contentDigest: Data(content.finalize()), size: size))
            default: throw CocoaError(.fileReadCorruptFile)
            }
        }
        return compute(records: records)
    }
}
