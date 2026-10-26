import Darwin
import Foundation

/// The selection is only a preview. D46 still checks identity and readiness
/// again in its review; this reads metadata without opening the selected data.
enum FileAnalysisSelectionReclaim {
    struct Metadata: Equatable, Sendable {
        let isRegularFile: Bool
        let linkCount: UInt64
        let deviceID: UInt64
    }

    struct Key: Equatable, Sendable {
        let selections: [FileAnalysisTrashSelection]
        let version: UInt64
    }

    typealias MetadataReader = @Sendable (String) -> Metadata?
    typealias SharingReader = @Sendable (String) -> FileStorageSharing.Reading

    static func metadata(at path: String) -> Metadata? {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0 else { return nil }
        return Metadata(isRegularFile: status.st_mode & S_IFMT == S_IFREG,
                        linkCount: UInt64(status.st_nlink), deviceID: UInt64(bitPattern: Int64(status.st_dev)))
    }

    static func estimate(for selection: FileAnalysisTrashSelection,
                         metadata: MetadataReader, sharing: SharingReader) -> CleanupReclaimableEstimate? {
        // Match review's G1 rule: folders and files with other hard links
        // retain their listed size; neither needs a sharing attribute read.
        guard !selection.isDirectory, let status = metadata(selection.path),
              status.isRegularFile, status.linkCount <= 1 else { return nil }
        return CleanupReclaimableEstimate.file(sharing(selection.path), allocatedBytes: max(0, selection.bytes),
                                               deviceID: status.deviceID)
    }

    static func calculate(_ selections: [FileAnalysisTrashSelection],
                          metadata: MetadataReader, sharing: SharingReader,
                          isCancelled: () -> Bool = { false }) -> CleanupSelectionReclaimable? {
        var items: [(size: Int64, estimate: CleanupReclaimableEstimate?)] = []
        for selection in selections {
            guard !isCancelled() else { return nil }
            items.append((max(0, selection.bytes), estimate(for: selection, metadata: metadata, sharing: sharing)))
        }
        guard !isCancelled() else { return nil }
        return CleanupSelectionReclaimable(items: items)
    }

    static func calculateAsync(_ selections: [FileAnalysisTrashSelection],
                               metadata: @escaping MetadataReader = Self.metadata(at:),
                               sharing: @escaping SharingReader = { FileStorageSharing.read(at: URL(fileURLWithPath: $0)) }) async -> CleanupSelectionReclaimable? {
        guard !Task.isCancelled else { return nil }
        let task = Task.detached(priority: .utility) {
            calculate(selections, metadata: metadata, sharing: sharing, isCancelled: { Task.isCancelled })
        }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return Task.isCancelled || task.isCancelled ? nil : result
    }

    static func title(selectedBytes: Int64, reclaim: CleanupSelectionReclaimable?, estimating: Bool) -> String {
        let selected = ByteFormat.storageString(selectedBytes)
        let freed = estimating ? "…" : reclaim.map { ByteFormat.storageString($0.freedBytes) } ?? "…"
        return L10n.text("已选 \(selected) · 清空废纸篓后约释放 \(freed)",
                         "Selected \(selected) · About \(freed) freed after emptying the Trash")
    }

    static func help(reclaim: CleanupSelectionReclaimable?) -> String {
        let basis = L10n.text(
            "移到废纸篓不会马上释放空间，清空废纸篓后才会释放。文件夹和有其他硬链接的文件按完整大小计；与其他文件共享的克隆块不计入。",
            "Moving items to the Trash does not free space immediately; space is freed after emptying the Trash. Folders and files with other hard links count at their full size; clone blocks shared with other files are excluded.")
        guard let reclaim, reclaim.possibleCloneBytes > 0 else { return basis }
        let possible = ByteFormat.storageString(reclaim.possibleCloneBytes)
        return basis + L10n.text("所选的完整克隆可能另外释放 \(possible)。",
                                 " The selected full clones may free an additional \(possible).")
    }
}
