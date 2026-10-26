import Darwin
import Foundation

enum RecentItemsCategory: String, CaseIterable, Sendable {
    case documents, applications, servers, applicationDocuments
}

struct RecentItemsList: Identifiable, Sendable {
    var id: String { url.path }
    let url: URL
    let category: RecentItemsCategory
    let bundleIdentifier: String?
    let entryCount: Int?
    let file: FileSnapshot
}

struct RecentItemsSnapshot: Sendable {
    var lists: [RecentItemsList] = []
    var unreadableLocations = 0
    var knownEntryCount: Int { lists.compactMap(\.entryCount).reduce(0, +) }
    var unknownListCount: Int { lists.filter { $0.entryCount == nil }.count }
}

/// D188: names and class metadata only. No private classes are unarchived,
/// and the contents of bookmarks, URLs and document titles are never inspected.
struct RecentItemsScanner: Sendable {
    static let applicationDirectory = "com.apple.LSSharedFileList.ApplicationRecentDocuments"
    let rootURL: URL
    private let metadata = FoundationReadOnlyFileSystem()

    init(rootURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/com.apple.sharedfilelist", isDirectory: true)) {
        self.rootURL = URL(fileURLWithPath: PathSafety.lexicalPath(rootURL.path), isDirectory: true)
    }

    /// Only immediate, regular files in these two locations qualify. This
    /// lexical check is repeated alongside the no-link metadata check at move time.
    func classification(of url: URL) -> (RecentItemsCategory, String?)? {
        guard url.isFileURL, url.path == PathSafety.lexicalPath(url.path),
              ["sfl2", "sfl3", "sfl4"].contains(url.pathExtension) else { return nil }
        let stem = url.deletingPathExtension().lastPathComponent
        let parent = url.deletingLastPathComponent().path
        if parent == rootURL.path {
            switch stem {
            case "com.apple.LSSharedFileList.RecentDocuments": return (.documents, nil)
            case "com.apple.LSSharedFileList.RecentApplications": return (.applications, nil)
            case "com.apple.LSSharedFileList.RecentServers", "com.apple.LSSharedFileList.RecentHosts": return (.servers, nil)
            default: return nil
            }
        }
        guard parent == rootURL.appendingPathComponent(Self.applicationDirectory).path,
              !stem.hasPrefix("com.apple.LSSharedFileList.") else { return nil }
        // The per-app filename must be a bundle identifier, not a folder,
        // a sidebar list, an arbitrary basename, or a nested path.
        let parts = stem.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        guard parts.count > 1, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        return (.applicationDocuments, stem)
    }

    func scan() -> RecentItemsSnapshot {
        var result = RecentItemsSnapshot()
        for directory in [rootURL, rootURL.appendingPathComponent(Self.applicationDirectory, isDirectory: true)] {
            do {
                let parent = try metadata.snapshot(at: directory)
                guard parent.identity.entryKind == .directory, !parent.hasSymbolicLinkComponent else {
                    result.unreadableLocations += 1; continue
                }
                for url in try metadata.children(of: directory) {
                    guard classification(of: url) != nil else { continue }
                    if let list = try? readList(at: url) { result.lists.append(list) }
                }
            } catch CleanupFileSystemError.vanished {
                continue
            } catch { result.unreadableLocations += 1 }
        }
        result.lists.sort { $0.url.path < $1.url.path }
        return result
    }

    func readList(at url: URL) throws -> RecentItemsList {
        guard let (category, bundleID) = classification(of: url) else { throw POSIXError(.EINVAL) }
        let file = try metadata.snapshot(at: url)
        guard file.identity.entryKind == .regularFile, !file.hasSymbolicLinkComponent else { throw POSIXError(.ELOOP) }
        // Bound the plist allocation. Oversized or unreadable files remain
        // listed with an unknown count; they are never described as empty.
        let count: Int?
        if file.logicalSizeBytes <= 32 * 1_024 * 1_024,
           let data = try? readWithoutLinks(url),
           let after = try? metadata.snapshot(at: url),
           after.identity == file.identity, after.modificationTimeNanoseconds == file.modificationTimeNanoseconds,
           after.logicalSizeBytes == file.logicalSizeBytes {
            count = Self.entryCount(in: data)
        } else { count = nil }
        return RecentItemsList(url: url, category: category, bundleIdentifier: bundleID, entryCount: count, file: file)
    }

    /// Positive absence evidence must not follow a newly substituted parent
    /// link, including a dangling link. Used only for the selected paths.
    func isAbsentWithoutLinks(_ url: URL) -> Bool {
        guard classification(of: url) != nil else { return false }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in url.pathComponents.dropFirst() {
            current.appendPathComponent(component)
            var status = stat()
            guard lstat(current.path, &status) == 0 else { return errno == ENOENT }
            guard status.st_mode & S_IFMT != S_IFLNK else { return false }
        }
        return false
    }

    /// Open every component without following links, including ancestors.
    private func readWithoutLinks(_ url: URL) throws -> Data {
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        for component in url.deletingLastPathComponent().pathComponents.dropFirst() {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw POSIXError(.ELOOP) }
            close(descriptor); descriptor = next
        }
        let file = openat(descriptor, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw POSIXError(.EIO) }
        let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size <= 32 * 1_024 * 1_024 else { throw POSIXError(.EINVAL) }
        // The extra byte catches a file that grew during the read.
        let data = try handle.read(upToCount: 32 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 32 * 1_024 * 1_024 else { throw POSIXError(.EFBIG) }
        return data
    }

    static func entryCount(in data: Data) -> Int? {
        guard let archive = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              archive["$archiver"] as? String == "NSKeyedArchiver",
              archive["$version"] as? Int == 100000,
              let objects = archive["$objects"] as? [Any], !objects.isEmpty,
              let top = archive["$top"] as? [String: Any], !top.isEmpty,
              top.values.allSatisfy({ referenceIndex($0).map(objects.indices.contains) == true }) else { return nil }
        if let root = top["root"].flatMap({ object(at: $0, in: objects) }) as? [String: Any],
           isInstance(root, of: ["NSDictionary", "NSMutableDictionary"], in: objects) {
            return plainItemCount(in: root, objects: objects)
        }
        var count = 0
        var hasInstances = false
        for case let object as [String: Any] in objects {
            guard let reference = object["$class"] else { continue }
            hasInstances = true
            guard let index = referenceIndex(reference), objects.indices.contains(index),
                  let type = objects[index] as? [String: Any],
                  let name = type["$classname"] as? String else { return nil }
            let classes = (type["$classes"] as? [String] ?? []) + [name]
            if classes.contains(where: { $0.contains("SFLListItem") }) {
                count += 1
            } else if !name.hasPrefix("NS") && name != "SFLList" {
                return nil // A new, unrecognized schema must not look empty.
            }
        }
        return hasInstances ? count : nil
    }

    /// D192②: lists whose root is a dictionary hold their entries in its
    /// "items" array; on macOS 27 every entry is a plain dictionary with no
    /// SFL class, so the class count above read each such list as empty
    /// (10-23 test beta: "0 recent items" against 10 + 10 + 10 + 2 entries).
    /// Only the array's length is read. An entry of another kind leaves the
    /// count unknown.
    private static func plainItemCount(in root: [String: Any], objects: [Any]) -> Int? {
        guard let keys = root["NS.keys"] as? [Any], let values = root["NS.objects"] as? [Any],
              keys.count == values.count,
              let position = keys.firstIndex(where: { object(at: $0, in: objects) as? String == "items" }),
              let items = object(at: values[position], in: objects) as? [String: Any],
              isInstance(items, of: ["NSArray", "NSMutableArray"], in: objects),
              let entries = items["NS.objects"] as? [Any] else { return nil }
        for entry in entries {
            guard let item = object(at: entry, in: objects) as? [String: Any],
                  let reference = item["$class"], let index = referenceIndex(reference), objects.indices.contains(index),
                  let type = objects[index] as? [String: Any], let name = type["$classname"] as? String else { return nil }
            let classes = (type["$classes"] as? [String] ?? []) + [name]
            guard name == "NSDictionary" || name == "NSMutableDictionary"
                    || classes.contains(where: { $0.contains("SFLListItem") }) else { return nil }
        }
        return entries.count
    }

    private static func object(at reference: Any, in objects: [Any]) -> Any? {
        guard let index = referenceIndex(reference), objects.indices.contains(index) else { return nil }
        return objects[index]
    }

    private static func isInstance(_ object: [String: Any], of names: Set<String>, in objects: [Any]) -> Bool {
        guard let reference = object["$class"], let index = referenceIndex(reference), objects.indices.contains(index),
              let type = objects[index] as? [String: Any], let name = type["$classname"] as? String else { return false }
        return names.contains(name)
    }

    private static func referenceIndex(_ value: Any) -> Int? {
        if let reference = value as? [String: Any] { return reference["CF$UID"] as? Int }
        // Public plist serialization exposes binary UID references as CF$UID
        // dictionaries in XML. Reading that XML as a plist creates another
        // opaque UID, so inspect the integer in this generated reference-only
        // XML instead. No item payload or private UID accessor is involved.
        guard let xml = try? PropertyListSerialization.data(fromPropertyList: ["ref": value], format: .xml, options: 0) else { return nil }
        let text = String(decoding: xml, as: UTF8.self)
        guard let marker = text.range(of: "<key>CF$UID</key>"),
              let start = text.range(of: "<integer>", range: marker.upperBound..<text.endIndex)?.upperBound,
              let end = text.range(of: "</integer>", range: start..<text.endIndex)?.lowerBound else { return nil }
        return Int(text[start..<end])
    }
}
