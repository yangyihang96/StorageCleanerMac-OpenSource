import CryptoKit
import Darwin
import FileOperationShared
import Foundation

/// A non-mapped, owned byte snapshot. Signature, manifest and extraction all
/// consume this value, never a path which another process can replace.
struct AuthenticatedUpdateArchive: Sendable {
    let bytes: Data
    let fileExtension: String
    let sha256: String
    init(bytes: Data, fileExtension: String) throws {
        guard !bytes.isEmpty, bytes.count <= 1_073_741_824 else { throw SparkleAutomaticUpdateError.invalidSignature }
        self.bytes = bytes; self.fileExtension = fileExtension
        sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func snapshot(_ url: URL, expectedSHA256: String? = nil) throws -> Self {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw SparkleAutomaticUpdateError.invalidSignature }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var attributes = stat()
        guard fstat(fd, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFREG,
              attributes.st_size > 0, attributes.st_size <= 1_073_741_824 else { throw SparkleAutomaticUpdateError.invalidSignature }
        var bytes = Data()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            guard chunk.count <= 1_073_741_824 - bytes.count else { throw SparkleAutomaticUpdateError.invalidSignature }
            bytes.append(chunk)
        }
        let result = try Self(bytes: bytes, fileExtension: url.pathExtension.lowercased())
        if let expectedSHA256, result.sha256 != expectedSHA256 { throw SparkleAutomaticUpdateError.invalidSignature }
        return result
    }
    /// Disk images need a seekable descriptor. Unlink before hdiutil starts and
    /// dup it to stdin: /dev/fd/0 refers to these exact authenticated bytes.
    func imageDescriptor(in root: URL) throws -> FileHandle {
        var template = Array(root.appendingPathComponent("image-XXXXXX").path.utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw OfficialApplicationUpdateInstallerError.mountFailed }
        let path = String(cString: template)
        unlink(path)
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: bytes)
        try handle.seek(toOffset: 0)
        return handle
    }
}

struct AuthenticatedApplicationCandidate: Sendable {
    let url: URL
    let sha256: String
    static func copy(from source: URL, into root: URL, expectedSHA256: String, verify: (URL) throws -> Void) throws -> Self {
        // Never derive a replacement expected value from the mutable path.
        let expected = expectedSHA256
        try AuthenticatedApplicationDigest.authenticateCopy(source, expectedSHA256: expected)
        try verify(source)
        let destination = root.appendingPathComponent("Candidate-" + UUID().uuidString + ".app")
        try FileManager.default.copyItem(at: source, to: destination)
        try verify(destination)
        let actual = try AuthenticatedApplicationDigest.compute(destination)
        guard actual == expected else { throw NSError(domain: "AuthenticatedApplicationCandidate", code: 1, userInfo: [NSLocalizedDescriptionKey:
            L10n.text("私有候选副本摘要改变", "Private candidate copy digest changed") + "\nSHA-256: \(expected) → \(actual)"] ) }
        return Self(url: destination, sha256: expected)
    }
}
