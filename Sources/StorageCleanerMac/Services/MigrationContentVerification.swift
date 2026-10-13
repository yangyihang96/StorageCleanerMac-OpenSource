import Foundation

/// An in-memory proof, bound to both paths and full identity/size/nanosecond
/// mtime/ctime snapshots. Never persisted as authority across application runs.
struct MigrationContentVerification: Equatable, Sendable {
    let sourceURL: URL
    let destinationURL: URL
    let digest: Data
    let sourceSnapshot: GuardedFileContentReader.Snapshot
    let destinationSnapshot: GuardedFileContentReader.Snapshot

    private init(source: URL, destination: URL, digest: Data,
                 sourceSnapshot: GuardedFileContentReader.Snapshot, destinationSnapshot: GuardedFileContentReader.Snapshot) {
        sourceURL = source; destinationURL = destination; self.digest = digest
        self.sourceSnapshot = sourceSnapshot; self.destinationSnapshot = destinationSnapshot
    }

    static func verify(_ source: URL, _ destination: URL, reader: GuardedFileContentReader,
                       reusing previous: Self? = nil) throws -> Self {
        try reader.checkAvailability(source)
        try reader.checkAvailability(destination)
        let first = try reader.open(source).snapshot
        let second = try reader.open(destination).snapshot
        if let previous, previous.sourceURL == source, previous.destinationURL == destination,
           previous.sourceSnapshot == first, previous.destinationSnapshot == second { return previous }
        let sourceDigest = try reader.digestWithSnapshot(source)
        let destinationDigest = try reader.digestWithSnapshot(destination)
        guard sourceDigest.digest == destinationDigest.digest else { throw ExternalDriveMigrationError.copyVerificationFailed }
        guard try reader.open(source).snapshot == sourceDigest.snapshot,
              try reader.open(destination).snapshot == destinationDigest.snapshot else { throw FileContentReadError.changed }
        return Self(source: source, destination: destination, digest: sourceDigest.digest,
            sourceSnapshot: sourceDigest.snapshot, destinationSnapshot: destinationDigest.snapshot)
    }

    /// Called only by the publisher after its own metadata restoration/rename.
    /// Compare the complete pre-restoration snapshot, including ctime, before
    /// allowing the publisher's own metadata writes/rename to rebind the proof.
    /// A changed snapshot requires hashing; size and restored mtime are not proof.
    /// A failed refresh simply drops the optimization; publication has committed.
    func afterPublication(at destination: URL, reader: GuardedFileContentReader,
                          beforeMetadataRestoration: GuardedFileContentReader.Snapshot? = nil) -> Self? {
        guard let first = try? reader.open(sourceURL).snapshot,
              let second = try? reader.open(destination).snapshot else { return nil }
        guard (beforeMetadataRestoration ?? second) == destinationSnapshot,
              first == sourceSnapshot,
              second.device == destinationSnapshot.device, second.inode == destinationSnapshot.inode,
              second.size == destinationSnapshot.size,
              second.modifiedSeconds == destinationSnapshot.modifiedSeconds,
              second.modifiedNanoseconds == destinationSnapshot.modifiedNanoseconds else {
            return try? Self.verify(sourceURL, destination, reader: reader)
        }
        return Self(source: sourceURL, destination: destination, digest: digest,
            sourceSnapshot: first, destinationSnapshot: second)
    }
}
