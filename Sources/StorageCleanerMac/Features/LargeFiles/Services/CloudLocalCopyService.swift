import Darwin
import Foundation
import os

/// D90: the capability boundary deliberately has no delete, move or content-read operation.
protocol CloudLocalCopyProvider: Sendable {
    func state(at path: String) async throws -> CloudLocalCopyState
    func evict(_ expected: CloudLocalCopyState) async throws
}

enum CloudCopyProvider: Equatable, Sendable {
    case iCloud, external(String), local, unknown
    var title: String {
        switch self {
        case .iCloud: return "iCloud Drive"
        case .external(let name): return name
        case .unknown: return L10n.text("提供商未知", "Unknown Provider")
        case .local: return L10n.text("本地文件", "Local File")
        }
    }
}

enum CloudCopyBlock: Equatable, Sendable {
    case unsupported, notCloud, unknown, unreadable, notUploaded, conflict, syncing, placeholder, unsafe
    var title: String {
        switch self {
        case .unsupported: return L10n.text("提供商不支持：请在访达中右键选『移除下载』", "Provider unsupported: in Finder, Control-click the file and choose Remove Download")
        case .notCloud: return L10n.text("不是云端文件", "Not a cloud file")
        case .unknown: return L10n.text("同步状态不明，不能释放", "Sync state unknown; cannot release")
        case .unreadable: return L10n.text("未能读取状态", "Could not read state")
        case .notUploaded: return L10n.text("未上传完成或有未同步修改", "Upload incomplete or unsynced edits")
        case .conflict: return L10n.text("有未解决的冲突", "Unresolved conflicts")
        case .syncing: return L10n.text("正在同步或同步出错", "Sync in progress or sync error")
        case .placeholder: return L10n.text("已是云端占位或没有本地分配块", "Already a placeholder or no local allocated blocks")
        case .unsafe: return L10n.text("仅支持无链接的普通文件，路径或文件身份已改变", "Only regular unlinked files supported; path or identity changed")
        }
    }
}

/// Every default is "no evidence": a state is selectable only after a reader proved each field.
struct CloudLocalCopyState: Equatable, Sendable, Identifiable {
    enum Download: Sendable { case current, downloaded, placeholder, unknown }
    let path: String
    var provider: CloudCopyProvider = .unknown
    var supported = false
    var safe: Bool? = nil
    var identity = ""
    var revision = ""
    var allocatedBytes: Int64 = 0
    var download: Download = .unknown
    var uploaded: Bool? = nil
    var conflicts: Bool? = nil
    var uploading: Bool? = nil
    var downloading: Bool? = nil
    var excludedFromSync: Bool? = nil
    var syncError: Bool? = nil
    var unreadable = false
    var id: String { path }
    var block: CloudCopyBlock? {
        if unreadable { return .unreadable }
        if safe == false { return .unsafe }
        guard safe == true else { return .unknown }
        guard provider != .unknown else { return .unknown }
        guard provider != .local else { return .notCloud }
        guard supported else { return .unsupported }
        if conflicts == true { return .conflict }
        if uploading == true || downloading == true || syncError == true { return .syncing }
        if uploaded == false || excludedFromSync == true { return .notUploaded }
        guard uploaded == true, conflicts == false, uploading == false, downloading == false,
              excludedFromSync == false, syncError == false else { return .unknown }
        guard download != .unknown else { return .unknown }
        guard download != .placeholder, allocatedBytes > 0 else { return .placeholder }
        return nil
    }
    static func unreadable(_ path: String) -> Self {
        var state = Self(path: path); state.unreadable = true; return state
    }
}

enum CloudCopyResultStatus: Equatable, Sendable {
    case released, blocked(CloudCopyBlock), failed, readbackFailed, unchanged, cancelled, limit, busy
    var title: String {
        switch self {
        case .released: return L10n.text("已确认释放", "Release confirmed")
        case .blocked(let reason): return reason.title
        case .failed: return L10n.text("释放调用失败", "Release call failed")
        case .readbackFailed: return L10n.text("无法回读，释放量未确认", "Readback failed; release unconfirmed")
        case .unchanged: return L10n.text("未确认：多次回读仍未见占位和大小下降，请稍后重新分析", "Unconfirmed: repeated readback did not show a placeholder with a smaller size; analyze again later")
        case .cancelled: return L10n.text("已取消，未执行", "Cancelled; not executed")
        case .busy: return L10n.text("其他操作正在进行，未执行释放", "Another operation is active; release not executed")
        case .limit: return L10n.text("超过批量上限，未执行", "Batch limit exceeded; not executed")
        }
    }
}
struct CloudCopyResult: Equatable, Sendable, Identifiable {
    let path: String
    let status: CloudCopyResultStatus
    var releasedBytes: Int64 = 0
    var detail: String? = nil
    var id: String { path }
}
struct CloudCopyOutcome: Sendable {
    var items: [CloudCopyResult] = []
    var releasedBytes: Int64 { items.reduce(0) { $0 + $1.releasedBytes } }
}

/// Thrown by the native gate when the fresh state no longer matches the reviewed one.
enum CloudCopyGateError: Error, Sendable { case recheckFailed }

/// Result details are shown in the UI; system error prose is never passed through untranslated.
enum CloudCopyErrorText {
    static func describe(_ error: any Error) -> String {
        if error is CloudCopyGateError {
            return L10n.text("执行前复查未通过：文件状态或身份已改变", "Pre-release check failed: file state or identity changed")
        }
        if let busy = error as? HeavyWorkCoordinator.Error, case .busy(let owner) = busy {
            return HeavyWorkActivityStore.conflictMessage(activeOwner: owner)
        }
        if error is CancellationError { return L10n.text("已取消", "Cancelled") }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain {
            switch ns.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
                return L10n.text("文件已不存在", "The file no longer exists")
            case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                return L10n.text("没有访问权限", "Permission denied")
            case NSUbiquitousFileUnavailableError, NSUbiquitousFileNotUploadedDueToQuotaError,
                 NSUbiquitousFileUbiquityServerNotAvailable:
                return L10n.text("iCloud 暂不可用或文件尚未上传", "iCloud is unavailable or the file is not uploaded")
            default: break
            }
        }
        return L10n.text("系统未完成请求（错误代码 \(ns.code)）", "The system did not complete the request (error code \(ns.code))")
    }
}

struct CloudLocalCopyService: Sendable {
    static let batchLimit = 50
    static let reviewLimit = 200
    static let readTimeout: Duration = .seconds(5)
    let provider: any CloudLocalCopyProvider
    var coordinator: HeavyWorkCoordinator? = nil
    /// Bounded, read-only readback: system state can lag the accepted eviction request.
    var readbackAttempts = 3
    var readbackInterval: Duration = .milliseconds(500)

    /// Files the index already knows are cloud placeholders are skipped before the review cap.
    static func reviewCandidates(_ entries: [StorageTreemapEntry]) -> [String] {
        Array(entries.filter { $0.role == .content && !$0.isDirectory && !$0.isCloudOnly }
            .map(\.path).prefix(reviewLimit))
    }

    /// Sequential metadata reads, each with its own upper bound. A read that does not answer
    /// in time is reported as unreadable and is never selectable.
    static func readStates(_ paths: [String], provider: any CloudLocalCopyProvider,
                           timeout: Duration = readTimeout) async -> [CloudLocalCopyState] {
        var states: [CloudLocalCopyState] = []
        for path in paths {
            if Task.isCancelled { break }
            states.append(await readState(path, provider: provider, timeout: timeout))
        }
        return states
    }

    static func readState(_ path: String, provider: any CloudLocalCopyProvider,
                          timeout: Duration) async -> CloudLocalCopyState {
        let once = CloudCopyResumeOnce()
        return await withCheckedContinuation { continuation in
            once.install(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                once.resume(.unreadable(path))
            }
            Task {
                let value = (try? await provider.state(at: path)) ?? .unreadable(path)
                once.resume(value)
                timer.cancel()
            }
        }
    }

    /// Sequential, bounded, off the main actor. An in-flight eviction finishes its readback;
    /// cancellation prevents subsequent calls, it cannot undo an accepted system request.
    func release(_ selection: [CloudLocalCopyState]) async -> CloudCopyOutcome {
        guard let coordinator else { return await releaseItems(selection) }
        do {
            let lease = try await coordinator.acquire(owner: .cloudLocalCopy)
            let outcome = await releaseItems(selection)
            await coordinator.release(lease)
            return outcome
        } catch {
            return CloudCopyOutcome(items: selection.map { .init(path: $0.path, status: .busy, detail: CloudCopyErrorText.describe(error)) })
        }
    }

    private func releaseItems(_ selection: [CloudLocalCopyState]) async -> CloudCopyOutcome {
        guard selection.count <= Self.batchLimit else {
            return CloudCopyOutcome(items: selection.map { .init(path: $0.path, status: .limit) })
        }
        var outcome = CloudCopyOutcome()
        var visited = Set<String>()
        for selected in selection {
            guard visited.insert(selected.path).inserted else { continue }
            if Task.isCancelled {
                outcome.items.append(.init(path: selected.path, status: .cancelled)); continue
            }
            if let block = selected.block {
                outcome.items.append(.init(path: selected.path, status: .blocked(block))); continue
            }
            let before: CloudLocalCopyState
            do { before = try await provider.state(at: selected.path) }
            catch {
                outcome.items.append(.init(path: selected.path, status: .blocked(.unreadable), detail: CloudCopyErrorText.describe(error))); continue
            }
            if let block = before.block {
                outcome.items.append(.init(path: selected.path, status: .blocked(block))); continue
            }
            guard before.path == selected.path, before.identity == selected.identity,
                  before.provider == selected.provider,
                  before.revision == selected.revision else {
                outcome.items.append(.init(path: selected.path, status: .blocked(.unsafe))); continue
            }
            if Task.isCancelled {
                outcome.items.append(.init(path: selected.path, status: .cancelled)); continue
            }
            do { try await provider.evict(before) }
            catch {
                outcome.items.append(.init(path: selected.path, status: .failed, detail: CloudCopyErrorText.describe(error))); continue
            }
            outcome.items.append(await readBack(before))
        }
        return outcome
    }

    /// Success needs the same safe file, now a placeholder, with a measured allocation drop.
    private func readBack(_ before: CloudLocalCopyState) async -> CloudCopyResult {
        var lastError: (any Error)?
        for attempt in 0..<max(1, readbackAttempts) {
            if attempt > 0 {
                // Detached so cancelling later items cannot shorten an accepted request's readback.
                let interval = readbackInterval
                await Task.detached { try? await Task.sleep(for: interval) }.value
            }
            do {
                let after = try await provider.state(at: before.path)
                lastError = nil
                let difference = max(0, before.allocatedBytes - after.allocatedBytes)
                if after.path == before.path, after.safe == true, after.provider == before.provider,
                   after.identity == before.identity, after.download == .placeholder, difference > 0 {
                    return .init(path: before.path, status: .released, releasedBytes: difference)
                }
            } catch { lastError = error }
        }
        if let lastError {
            return .init(path: before.path, status: .readbackFailed, detail: CloudCopyErrorText.describe(lastError))
        }
        return .init(path: before.path, status: .unchanged)
    }
}

/// First answer wins (metadata or timeout); later answers are ignored.
private final class CloudCopyResumeOnce: Sendable {
    private let pending = OSAllocatedUnfairLock<CheckedContinuation<CloudLocalCopyState, Never>?>(initialState: nil)
    func install(_ continuation: CheckedContinuation<CloudLocalCopyState, Never>) {
        pending.withLock { $0 = continuation }
    }
    func resume(_ value: CloudLocalCopyState) {
        let continuation = pending.withLock { slot -> CheckedContinuation<CloudLocalCopyState, Never>? in
            let current = slot; slot = nil; return current
        }
        continuation?.resume(returning: value)
    }
}

/// Sync metadata for one URL. Reading it never opens, coordinates or downloads the file.
struct CloudSyncMetadata: Sendable {
    var isUbiquitous: Bool?
    var download: CloudLocalCopyState.Download = .unknown
    var uploaded: Bool?
    var conflicts: Bool?
    var uploading: Bool?
    var downloading: Bool?
    var excludedFromSync: Bool?
    var syncError: Bool?

    static func read(_ url: URL) throws -> CloudSyncMetadata {
        let values = try url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            .ubiquitousItemHasUnresolvedConflictsKey, .ubiquitousItemIsUploadedKey,
            .ubiquitousItemIsUploadingKey, .ubiquitousItemIsDownloadingKey,
            .ubiquitousItemIsExcludedFromSyncKey, .ubiquitousItemUploadingErrorKey,
            .ubiquitousItemDownloadingErrorKey
        ])
        var metadata = CloudSyncMetadata(isUbiquitous: values.isUbiquitousItem)
        switch values.ubiquitousItemDownloadingStatus {
        case .current: metadata.download = .current
        case .downloaded: metadata.download = .downloaded
        case .notDownloaded: metadata.download = .placeholder
        default: metadata.download = .unknown
        }
        metadata.uploaded = values.ubiquitousItemIsUploaded
        metadata.conflicts = values.ubiquitousItemHasUnresolvedConflicts
        metadata.uploading = values.ubiquitousItemIsUploading
        metadata.downloading = values.ubiquitousItemIsDownloading
        metadata.excludedFromSync = values.ubiquitousItemIsExcludedFromSync
        metadata.syncError = values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil
        return metadata
    }
}

/// Only metadata is read. No enumeration, file coordination, opening or download requests.
/// NSFileProviderManager is limited to a provider's own extension/app (SDK header contract).
/// This app has no such domains, so every provider other than positively identified iCloud
/// fails closed as unsupported.
actor NativeCloudLocalCopyProvider: CloudLocalCopyProvider {
    typealias MetadataReader = @Sendable (URL) throws -> CloudSyncMetadata
    typealias Evictor = @Sendable (URL) throws -> Void
    private let home: String
    private let metadata: MetadataReader
    private let evictor: Evictor

    init(home: String = FileManager.default.homeDirectoryForCurrentUser.path,
         metadata: @escaping MetadataReader = CloudSyncMetadata.read,
         evictor: @escaping Evictor = { try FileManager.default.evictUbiquitousItem(at: $0) }) {
        self.home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        self.metadata = metadata
        self.evictor = evictor
    }

    func state(at path: String) async throws -> CloudLocalCopyState {
        var state = CloudLocalCopyState(path: path)
        guard path.hasPrefix("/"), URL(fileURLWithPath: path).standardizedFileURL.path == path,
              safeAncestors(path) else { state.safe = false; return state }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            state.safe = false; return state
        }
        state.safe = true
        state.identity = "\(info.st_dev):\(info.st_ino)"
        state.revision = "\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_size)"
        state.allocatedBytes = max(0, Int64(info.st_blocks) * 512)
        // CloudStorage path names are display hints, never proof of provider capability.
        if let name = Self.externalProviderName(path) {
            state.provider = .external(name); state.supported = false; return state
        }
        let values = try metadata(URL(fileURLWithPath: path))
        var homeInfo = stat()
        let homeDevice: dev_t? = lstat(home, &homeInfo) == 0 ? homeInfo.st_dev : nil
        let iCloudLocation = Self.isICloudLocation(path, home: home, fileDevice: info.st_dev, homeDevice: homeDevice)
        // Foundation reports no ubiquity value for plain local files; inside an iCloud location
        // a missing value stays unknown. Either way the file is not selectable.
        guard let ubiquitous = values.isUbiquitous else { state.provider = iCloudLocation ? .unknown : .local; return state }
        guard ubiquitous else { state.provider = .local; return state }
        guard iCloudLocation else {
            state.provider = .external(L10n.text("其他云提供商", "Other cloud provider")); state.supported = false
            return state
        }
        state.provider = .iCloud; state.supported = true
        state.download = values.download
        state.uploaded = values.uploaded
        state.conflicts = values.conflicts
        state.uploading = values.uploading
        state.downloading = values.downloading
        state.excludedFromSync = values.excludedFromSync
        state.syncError = values.syncError
        return state
    }

    func evict(_ expected: CloudLocalCopyState) async throws {
        // Defense in depth for direct callers; the service also checks the review identity.
        let fresh = try await state(at: expected.path)
        guard fresh.provider == .iCloud, fresh.block == nil, fresh.identity == expected.identity,
              fresh.revision == expected.revision else { throw CloudCopyGateError.recheckFailed }
        try evictor(URL(fileURLWithPath: expected.path))
    }

    private func safeAncestors(_ path: String) -> Bool {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != "/" {
            var info = stat()
            guard lstat(parent, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return false }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
        return true
    }

    /// Positive iCloud evidence only: iCloud Drive's Mobile Documents container, or the
    /// Desktop/Documents folders that iCloud maps on the home volume. Ubiquitous items
    /// anywhere else belong to a provider this app cannot verify.
    static func isICloudLocation(_ path: String, home: String, fileDevice: dev_t, homeDevice: dev_t?) -> Bool {
        if path.hasPrefix(home + "/Library/Mobile Documents/") { return true }
        guard path.hasPrefix(home + "/Desktop/") || path.hasPrefix(home + "/Documents/") else { return false }
        return homeDevice == fileDevice
    }

    static func externalProviderName(_ path: String) -> String? {
        let components = path.split(separator: "/")
        guard let i = components.firstIndex(of: "CloudStorage"), i > 0,
              components[i - 1] == "Library", components.count > i + 1 else { return nil }
        let name = String(components[i + 1])
        if name.hasPrefix("OneDrive") { return "OneDrive" }
        if name.hasPrefix("GoogleDrive") { return "Google Drive" }
        if name.hasPrefix("Dropbox") { return "Dropbox" }
        return name
    }
}
