import Combine
import Foundation

@MainActor
final class PhotoLibraryStore: ObservableObject {
    @Published private(set) var authorization: PhotoLibraryAuthorization = .notDetermined
    @Published private(set) var result: LibraryPhotoScanResult?
    @Published private(set) var busy = false
    @Published private(set) var processed = 0
    @Published private(set) var message: String?
    @Published var selectedIDs = Set<String>()
    @Published private(set) var keepers: [String: String] = [:]
    private let provider: any PhotoLibraryProviding
    private let scanner: PhotoLibraryScanner
    private let cache: PhotoThumbnailHashCache
    private var task: Task<Void, Never>?
    @Published private(set) var scanning = false
    init(provider: any PhotoLibraryProviding, cache: PhotoThumbnailHashCache) {
        self.provider = provider; self.cache = cache
        scanner = .init(provider: provider, cache: cache)
    }
    static func live() -> PhotoLibraryStore {
        .init(provider: PhotoKitLibraryProvider(), cache: .init(fileURL: AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("PhotoLibrary", isDirectory: true).appendingPathComponent("thumbnail-hashes-v1.json")))
    }
    func refreshAuthorization() async {
        authorization = await provider.authorization()
        if !authorization.canRead {
            if scanning { task?.cancel() }
            result = nil; selectedIDs.removeAll(); keepers.removeAll()
            do { try await cache.clear() }
            catch { message = L10n.text("授权已撤销，但无法移除缩略图哈希缓存，请检查应用数据目录权限。", "Access was revoked, but the thumbnail hash cache could not be removed. Check app data directory permissions.") }
        }
    }
    func authorize() {
        guard !busy else { return }
        busy = true
        task = Task {
            authorization = await provider.requestAuthorization()
            busy = false; task = nil
        }
    }
    func scan() {
        guard !busy else { return }
        busy = true; scanning = true; processed = 0; message = nil
        result = nil; selectedIDs.removeAll(); keepers.removeAll()
        let scanner = scanner
        task = Task {
            await refreshAuthorization()
            do {
                let output = try await scanner.scan { [self] count in await self.setProgress(count) }
                try Task.checkCancellation()
                result = output
                keepers = Dictionary(uniqueKeysWithValues: output.groups.map { ($0.id, $0.keeperID) })
            } catch is CancellationError { message = L10n.text("已取消扫描。", "Scan cancelled.") }
            catch { message = L10n.text("无法扫描照片图库。请检查授权后重试。", "Unable to scan the photo library. Check access and try again.") }
            busy = false; scanning = false; task = nil
        }
    }
    private func setProgress(_ count: Int) { processed = count }
    func cancel() { if scanning { task?.cancel() } }
    func keep(_ photo: LibraryPhoto, in group: LibraryPhotoGroup) {
        guard !busy else { return }; keepers[group.id] = photo.id; selectedIDs.remove(photo.id)
    }
    func toggle(_ photo: LibraryPhoto, in group: LibraryPhotoGroup) {
        guard !busy, keepers[group.id] != photo.id else { return }
        if !selectedIDs.insert(photo.id).inserted { selectedIDs.remove(photo.id) }
    }
    func addSelectedToAlbum() {
        guard !busy, authorization.canAddToAlbum, let result else { return }
        let validIDs = Set(result.groups.flatMap { group in group.photos.filter { $0.id != keepers[group.id] }.map(\.id) })
        let ids = selectedIDs.intersection(validIDs).sorted()
        guard !ids.isEmpty else { return }
        busy = true; message = nil
        task = Task {
            await refreshAuthorization()
            do {
                guard authorization.canAddToAlbum else { throw PhotoLibraryError.permission }
                let count = try await provider.addToReviewAlbum(identifiers: ids)
                message = L10n.text("已将 \(ByteFormat.count(count)) 张照片加入『存储清理助手-待删除』。请在『照片』App 中查看并删除，删除后进入『最近删除』30 天可恢复。", "Added \(ByteFormat.count(count)) photos to ‘存储清理助手-待删除’. Review and delete them in Photos. Deleted photos can be recovered from Recently Deleted for 30 days.")
                selectedIDs.removeAll()
            } catch { message = L10n.text("加入相册失败或未能核实。请在『照片』App 中检查；没有删除照片。", "Album addition failed or could not be verified. Check Photos; no photos were deleted.") }
            busy = false; task = nil
        }
    }
    func preview(_ photo: LibraryPhoto) async -> Data? {
        guard await provider.authorization().canRead else {
            await refreshAuthorization()
            return nil
        }
        return try? await provider.thumbnail(for: photo, includePreview: true)?.preview
    }
}
