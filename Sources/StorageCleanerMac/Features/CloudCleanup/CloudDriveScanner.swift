import Darwin
import Foundation

/// Read-only cloud-folder inventory. Enumeration reads metadata only; reviewing and
/// releasing local copies remains the separate D90 flow, with fresh eligibility checks.
struct CloudDriveSnapshot: Equatable, Sendable {
    struct File: Identifiable, Equatable, Sendable {
        var id: String { path }
        let path: String
        let name: String
        let allocatedBytes: Int64
        let logicalBytes: Int64
        let modifiedAt: Date?
    }

    var rootExists = false
    var localFileCount = 0
    var localBytes: Int64 = 0
    var cloudOnlyCount = 0
    var cloudOnlyBytes: Int64 = 0
    /// The largest downloaded files, largest first.
    var largestLocalFiles: [File] = []
    /// Files that were walked; the walk stops at `CloudDriveScanner.itemLimit`.
    var inspectedCount = 0
    var isTruncated = false
    var unreadableCount = 0

    /// Downloaded files of at least `CloudDriveScanner.largeFileBytes`.
    var largeLocalFiles: [File] {
        largestLocalFiles.filter { $0.allocatedBytes >= CloudDriveScanner.largeFileBytes }
    }

    var largeLocalBytes: Int64 {
        largeLocalFiles.reduce(Int64(0)) { CleanupByteCount.adding($1.allocatedBytes, to: $0) }
    }
}

enum CloudDriveScanner {
    enum ProviderKind: Equatable, Sendable {
        case googleDrive, oneDrive, dropbox, box, other
    }

    struct Provider: Identifiable, Equatable, Sendable {
        var id: String { path }
        let kind: ProviderKind
        let name: String
        let account: String
        let path: String
        var displayTitle: String { account.isEmpty ? name : name + " · " + account }

        /// File Provider folder names are display hints; they never prove eviction support.
        init(folderName: String, path: String) {
            let parts = folderName.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            let stem = String(parts[0])
            switch stem {
            case "GoogleDrive": kind = .googleDrive; name = "Google Drive"
            case "OneDrive": kind = .oneDrive; name = "OneDrive"
            case "Dropbox": kind = .dropbox; name = "Dropbox"
            case "Box": kind = .box; name = "Box"
            default: kind = .other; name = stem
            }
            account = parts.count > 1 ? String(parts[1]) : ""
            self.path = path
        }
    }

    struct ProviderSnapshot: Identifiable, Equatable, Sendable {
        var id: String { provider.id }
        let provider: Provider
        let snapshot: CloudDriveSnapshot
    }

    /// Injectable, metadata-only reader shared by iCloud and third-party walks.
    struct Metadata: Sendable {
        var isRegularFile: Bool? = nil
        var isSymbolicLink: Bool? = nil
        var totalFileAllocatedSize: Int? = nil
        var fileAllocatedSize: Int? = nil
        var fileSize: Int? = nil
        var isDataless = false
        var contentModificationDate: Date? = nil

        static func read(_ url: URL) throws -> Self {
            var info = stat()
            let result = url.withUnsafeFileSystemRepresentation { path in
                path.map { lstat($0, &info) } ?? -1
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            // The enumerator prefetched these local attributes. Cloud resource
            // keys would ask bird/FileProvider once per item (D192).
            let values = try url.resourceValues(forKeys: Set(resourceKeys))
            return Self(isRegularFile: values.isRegularFile, isSymbolicLink: values.isSymbolicLink,
                        totalFileAllocatedSize: values.totalFileAllocatedSize,
                        fileAllocatedSize: values.fileAllocatedSize ?? Int(info.st_blocks) * 512, fileSize: values.fileSize ?? Int(info.st_size),
                        isDataless: info.st_flags & UInt32(SF_DATALESS) != 0,
                        contentModificationDate: values.contentModificationDate)
        }
    }
    typealias MetadataReader = @Sendable (URL) throws -> Metadata
    static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey
    ]

    struct Progress: Equatable, Sendable {
        var inspectedCount = 0
        var currentPath = ""
    }

    static let itemLimit = 400_000
    static let largeFileBytes: Int64 = 100_000_000
    /// As many as D90's review reads (`CloudLocalCopyService.reviewLimit`).
    static let keptFileCount = CloudLocalCopyService.reviewLimit

    static func iCloudDriveRoot(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Mobile Documents", isDirectory: true)
    }

    /// Reads immediate directory names only, never the contents of a provider folder.
    static func otherProviders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Provider] {
        let root = home.appendingPathComponent("Library/CloudStorage", isDirectory: true)
        guard safeDirectory(root), let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return names.filter { !$0.hasPrefix(".") }.sorted().compactMap { name in
            let url = root.appendingPathComponent(name, isDirectory: true)
            guard safeDirectory(url) else { return nil }
            return Provider(folderName: name, path: url.path)
        }
    }

    /// Each root (iCloud or one provider/account) gets its own itemLimit budget.
    /// The stop-marker item is counted, as in the original iCloud walk; it is not classified.
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     limit: Int = itemLimit, metadata: MetadataReader = Metadata.read,
                     isCancelled: @Sendable () -> Bool,
                     progress: @Sendable (Progress) -> Void) -> CloudDriveSnapshot {
        scan(root: iCloudDriveRoot(home: home), limit: limit, metadata: metadata,
             isCancelled: isCancelled, progress: progress)
    }

    static func scan(provider: Provider, limit: Int = itemLimit, metadata: MetadataReader = Metadata.read,
                     isCancelled: @Sendable () -> Bool,
                     progress: @Sendable (Progress) -> Void) -> CloudDriveSnapshot {
        scan(root: URL(fileURLWithPath: provider.path), limit: limit, metadata: metadata,
             isCancelled: isCancelled, progress: progress)
    }

    private static func scan(root: URL, limit: Int, metadata: MetadataReader,
                             isCancelled: @Sendable () -> Bool,
                             progress: @Sendable (Progress) -> Void) -> CloudDriveSnapshot {
        var snapshot = CloudDriveSnapshot()
        guard !isCancelled(), safeDirectory(root) else { return snapshot }
        snapshot.rootExists = true
        // The handler may also report a directory that could not be enumerated.
        var walkErrors = 0
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: resourceKeys,
                                                          options: [.skipsHiddenFiles],
                                                          errorHandler: { _, _ in walkErrors += 1; return true }) else {
            snapshot.unreadableCount = 1
            return snapshot
        }
        var kept: [CloudDriveSnapshot.File] = []
        var smallestKept: Int64 = 0
        for case let url as URL in walker {
            if isCancelled() { break }
            snapshot.inspectedCount += 1
            if snapshot.inspectedCount > max(0, limit) { snapshot.isTruncated = true; break }
            if snapshot.inspectedCount % 400 == 0 {
                progress(Progress(inspectedCount: snapshot.inspectedCount, currentPath: url.path))
            }
            guard let values = try? metadata(url) else {
                walker.skipDescendants()
                snapshot.unreadableCount += 1
                continue
            }
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let logical = Int64(values.fileSize ?? 0)
            let allocated = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if values.isDataless {
                snapshot.cloudOnlyCount += 1
                snapshot.cloudOnlyBytes = CleanupByteCount.adding(logical, to: snapshot.cloudOnlyBytes)
                continue
            }
            guard allocated > 0 else { continue }
            snapshot.localFileCount += 1
            snapshot.localBytes = CleanupByteCount.adding(allocated, to: snapshot.localBytes)
            if kept.count < keptFileCount || allocated > smallestKept {
                kept.append(.init(path: url.path, name: url.lastPathComponent, allocatedBytes: allocated,
                                  logicalBytes: logical, modifiedAt: values.contentModificationDate))
                if kept.count > keptFileCount * 2 {
                    kept.sort { $0.allocatedBytes > $1.allocatedBytes }
                    kept.removeLast(kept.count - keptFileCount)
                }
                if kept.count >= keptFileCount {
                    smallestKept = kept.map(\.allocatedBytes).min() ?? 0
                }
            }
        }
        snapshot.unreadableCount += walkErrors
        kept.sort { $0.allocatedBytes > $1.allocatedBytes }
        snapshot.largestLocalFiles = Array(kept.prefix(keptFileCount))
        progress(Progress(inspectedCount: snapshot.inspectedCount, currentPath: root.path))
        return snapshot
    }

    /// Reject symlinked roots/ancestors before enumeration; the walker also skips links.
    private static func safeDirectory(_ url: URL) -> Bool {
        var current = url
        while current.path != "/" {
            var info = stat()
            guard lstat(current.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            current.deleteLastPathComponent()
        }
        return true
    }

    /// The files as D90's review takes them.
    static func reviewEntries(_ files: [CloudDriveSnapshot.File]) -> [StorageTreemapEntry] {
        files.map { file in
            StorageTreemapEntry(id: file.path, title: file.name, path: file.path, sizeBytes: file.allocatedBytes,
                                kind: URL(fileURLWithPath: file.path).pathExtension, isDirectory: false)
        }
    }
}

/// The Cloud Cleanup page's state, kept while the window is open so going
/// to another module and back keeps the results (as CleanMyMac does).
@MainActor
final class CloudCleanupModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case finished
        case cancelled
    }

    static let shared = CloudCleanupModel()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var progress = CloudDriveScanner.Progress()
    @Published private(set) var snapshot: CloudDriveSnapshot?
    @Published private(set) var providers: [CloudDriveScanner.Provider] = []
    @Published private(set) var providerSnapshots: [CloudDriveScanner.ProviderSnapshot] = []
    @Published private(set) var iCloudDriveAvailable = false
    private var task: Task<Void, Never>?
    private var cancelFlag = CloudScanCancelFlag()
    private var runID = UUID()
    private let home: URL
    private let metadata: CloudDriveScanner.MetadataReader
    private let itemLimit: Int

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
         metadata: @escaping CloudDriveScanner.MetadataReader = CloudDriveScanner.Metadata.read,
         itemLimit: Int = CloudDriveScanner.itemLimit) {
        self.home = home
        self.metadata = metadata
        self.itemLimit = itemLimit
        refreshProviders()
    }

    func refreshProviders() {
        providers = CloudDriveScanner.otherProviders(home: home)
        var isDirectory: ObjCBool = false
        iCloudDriveAvailable = FileManager.default.fileExists(atPath: CloudDriveScanner.iCloudDriveRoot(home: home).path,
                                                              isDirectory: &isDirectory) && isDirectory.boolValue
    }

    func start() {
        guard phase != .scanning else { return }
        refreshProviders()
        cancelFlag = CloudScanCancelFlag()
        let flag = cancelFlag
        let id = UUID()
        runID = id
        phase = .scanning
        progress = .init()
        let home = home, metadata = metadata, limit = itemLimit, providers = providers
        task = Task {
            let result = await Task.detached(priority: .utility) {
                let model = self
                let iCloud = CloudDriveScanner.scan(home: home, limit: limit, metadata: metadata,
                                                    isCancelled: { flag.isCancelled }) { update in
                    Task { @MainActor in model.receive(update, runID: id) }
                }
                var results: [CloudDriveScanner.ProviderSnapshot] = []
                var checked = iCloud.inspectedCount
                for provider in providers {
                    if flag.isCancelled { break }
                    let previous = checked
                    let snapshot = CloudDriveScanner.scan(provider: provider, limit: limit, metadata: metadata,
                                                           isCancelled: { flag.isCancelled }) { update in
                        let progress = CloudDriveScanner.Progress(inspectedCount: previous + update.inspectedCount,
                                                                  currentPath: update.currentPath)
                        Task { @MainActor in model.receive(progress, runID: id) }
                    }
                    checked += snapshot.inspectedCount
                    results.append(.init(provider: provider, snapshot: snapshot))
                }
                return (iCloud, results)
            }.value
            guard runID == id else { return }
            if flag.isCancelled {
                phase = snapshot == nil ? .idle : .finished
                return
            }
            snapshot = result.0
            providerSnapshots = result.1
            phase = .finished
        }
    }

    func cancel() {
        guard phase == .scanning else { return }
        cancelFlag.cancel()
    }

    private func receive(_ update: CloudDriveScanner.Progress, runID: UUID) {
        guard phase == .scanning, self.runID == runID else { return }
        progress = update
    }

    func startOver() {
        cancel()
        runID = UUID()
        snapshot = nil
        providerSnapshots = []
        phase = .idle
    }
}

/// A flag the background walk polls.
final class CloudScanCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
    func reset() { lock.withLock { cancelled = false } }
}
