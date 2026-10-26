import Darwin
import Foundation

/// D184: reads only the bounded fat header. No executable is run or mapped.
enum UniversalMachO {
    static let arm64: UInt32 = 0x0100000c
    static let x86_64: UInt32 = 0x01000007
    static let maximumHeaderSize = 8 + 64 * 32

    struct Slice: Equatable, Sendable {
        let cpu: UInt32
        let subtype: UInt32
        let offset: UInt64
        let size: UInt64
    }

    struct Plan: Equatable, Sendable {
        let native: Slice
        let savedBytes: Int64
        let fileSize: UInt64
        let header: Data
    }

    enum Failure: Error { case malformed, changed, io, unsafeFile, metadata }

    static var hostCPU: UInt32 {
        // Also detects Apple silicon when the app itself is translated.
        var value: Int32 = 0
        var size = MemoryLayout.size(ofValue: value)
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1 ? arm64 : x86_64
    }

    static func parse(header: Data, fileSize: UInt64, nativeCPU: UInt32) throws -> Plan? {
        guard header.count >= 4 else { return nil }
        func number(_ offset: Int, _ length: Int) throws -> UInt64 {
            guard offset >= 0, offset <= header.count, length <= header.count - offset else { throw Failure.malformed }
            return header[offset..<(offset + length)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        let magic = try number(0, 4)
        // Swapped fat headers are deliberately refused; both supported formats are big endian.
        if magic == 0xbebafeca || magic == 0xbfbafeca { throw Failure.malformed }
        guard magic == 0xcafebabe || magic == 0xcafebabf else { return nil }
        let count = try number(4, 4)
        guard count > 0, count <= 64 else { throw Failure.malformed }
        let stride = magic == 0xcafebabf ? 32 : 20
        let tableEnd = 8 + Int(count) * stride
        guard tableEnd <= header.count, UInt64(tableEnd) <= fileSize, fileSize <= UInt64(Int64.max) else {
            throw Failure.malformed
        }
        var slices: [Slice] = []
        var architectures = Set<String>()
        for index in 0..<Int(count) {
            let base = 8 + index * stride
            let cpu = UInt32(try number(base, 4)), subtype = UInt32(try number(base + 4, 4))
            let wide = stride == 32
            let offset = try number(base + 8, wide ? 8 : 4)
            let size = try number(base + (wide ? 16 : 12), wide ? 8 : 4)
            let alignment = try number(base + (wide ? 24 : 16), 4)
            guard size > 0, offset >= UInt64(tableEnd), offset <= fileSize, size <= fileSize - offset,
                  alignment < 63, offset % (UInt64(1) << alignment) == 0,
                  architectures.insert("\(cpu):\(subtype)").inserted else { throw Failure.malformed }
            if wide, try number(base + 28, 4) != 0 { throw Failure.malformed }
            slices.append(Slice(cpu: cpu, subtype: subtype, offset: offset, size: size))
        }
        let ordered = slices.sorted { $0.offset < $1.offset }
        for index in 1..<ordered.count where ordered[index].offset < ordered[index - 1].offset + ordered[index - 1].size {
            throw Failure.malformed
        }
        let native = slices.filter { $0.cpu == nativeCPU }
        // Multiple native subtypes need a loader decision; never guess which one to retain.
        guard slices.count > 1, native.count == 1, let kept = native.first else { return nil }
        let saved = slices.filter { $0.cpu != nativeCPU }.reduce(UInt64(0)) { $0 + $1.size }
        guard saved > 0 else { return nil }
        return Plan(native: kept, savedBytes: Int64(saved), fileSize: fileSize, header: Data(header.prefix(tableEnd)))
    }

    static func inspect(_ url: URL, nativeCPU: UInt32) throws -> Plan? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.io }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0,
              info.st_flags & UInt32(SF_DATALESS) == 0 else { throw Failure.unsafeFile }
        return try parse(header: read(fd, offset: 0, count: min(Int(info.st_size), maximumHeaderSize)),
                         fileSize: UInt64(info.st_size), nativeCPU: nativeCPU)
    }

    static func read(_ fd: Int32, offset: UInt64, count: Int) throws -> Data {
        var bytes = Data(count: count)
        let got = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard got == count else { throw Failure.io }
        return bytes
    }

    /// Only callable with a tracked clone root. A failed write stays inside that clone.
    static func extract(_ plan: Plan, at file: URL, clone: URL) throws {
        guard UniversalBinarySafety.isInside(file, clone),
              !PathSafety.containsSymbolicLinkComponent(in: file.path),
              UniversalBinarySafety.isStagingName(clone.lastPathComponent) else { throw Failure.unsafeFile }
        let source = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw Failure.io }
        defer { close(source) }
        var info = stat()
        guard fstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_uid == getuid(), UInt64(info.st_size) == plan.fileSize,
              try read(source, offset: 0, count: plan.header.count) == plan.header else { throw Failure.changed }
        let attributes = try APFSCloneReplacement.extendedAttributes(file.path)
        let acl = APFSCloneReplacement.aclText(file.path)
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".storagecleaner-slice-\(UUID().uuidString)")
        let output = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.io }
        defer { close(output) }
        var copied: UInt64 = 0
        while copied < plan.native.size {
            try Task.checkCancellation()
            let chunk = try read(source, offset: plan.native.offset + copied,
                                 count: Int(min(plan.native.size - copied, 1_048_576)))
            let written = chunk.withUnsafeBytes { Darwin.write(output, $0.baseAddress, chunk.count) }
            guard written == chunk.count else { throw Failure.io }
            copied += UInt64(chunk.count)
        }
        // COPYFILE_METADATA preserves mode, ACL, quarantine, Finder info and other xattrs.
        // Embedded code signatures remain in the retained slice. Never re-sign anything.
        guard fcopyfile(source, output, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0,
              fsync(output) == 0 else { throw Failure.metadata }
        var result = stat()
        guard fstat(output, &result) == 0, result.st_mode == info.st_mode,
              result.st_uid == info.st_uid, result.st_gid == info.st_gid,
              result.st_size == off_t(plan.native.size),
              try APFSCloneReplacement.extendedAttributes(temporary.path) == attributes,
              APFSCloneReplacement.aclText(temporary.path) == acl else { throw Failure.metadata }
        guard rename(temporary.path, file.path) == 0 else { throw Failure.io }
    }
}
