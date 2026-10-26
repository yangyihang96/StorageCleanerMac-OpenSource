import Darwin
import Foundation

extension FoundationReadOnlyFileSystem {
    /// Mail has many message files. readdir's type avoids full metadata reads
    /// for those files, enters .mbox packages, and never follows a link.
    func directoryEntries(of directory: URL, checking: () throws -> Void) throws -> [URL] {
        try checking()
        let descriptor = try directory.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw CleanupFileSystemError.unreadable }
            return Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw Self.cleanupError(for: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
        }
        guard let stream = fdopendir(descriptor) else {
            let code = errno
            close(descriptor)
            throw Self.cleanupError(for: NSError(domain: NSPOSIXErrorDomain, code: Int(code)))
        }
        defer { closedir(stream) }
        var result = [URL]()
        while true {
            try checking()
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 {
                    throw Self.cleanupError(for: NSError(domain: NSPOSIXErrorDomain, code: Int(errno)))
                }
                return result
            }
            let type = entry.pointee.d_type
            guard type == UInt8(DT_DIR) || type == UInt8(DT_LNK) || type == UInt8(DT_UNKNOWN) else { continue }
            let nameLength = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameLength) {
                    String(cString: $0)
                }
            }
            guard name != ".", name != ".." else { continue }
            let url = directory.appendingPathComponent(name)
            if type == UInt8(DT_UNKNOWN) {
                // Some file systems omit d_type. lstat only; no content reads.
                let kind = try aggregateSnapshot(at: url).identity.entryKind
                guard kind == .directory || kind == .symbolicLink else { continue }
            }
            result.append(url)
        }
    }
}
