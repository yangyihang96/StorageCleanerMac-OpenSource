import Foundation

struct MyActivityMacInfo: Equatable, Sendable {
    var modelName: String?
    var startupDiskName: String?
    var capacity: StorageCapacitySnapshot?

    var capacityText: String {
        guard let capacity else { return L10n.text("容量未读取", "Capacity Unavailable") }
        return L10n.text("已用 \(ByteFormat.storageString(capacity.userUsedBytes)) / 共 \(ByteFormat.storageString(capacity.totalBytes))",
                         "\(ByteFormat.storageString(capacity.userUsedBytes)) used / \(ByteFormat.storageString(capacity.totalBytes)) total")
    }

    /// One read when this page opens. D195 uses the same important-usage
    /// reading as Space Lens; health assessment keeps its strict free space.
    static func read() -> Self {
        Self(modelName: SystemAppleSiliconHardwareDataSource().string("hw.model"),
             startupDiskName: (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]))?.volumeName,
             capacity: StorageCapacityService.snapshot())
    }
}
