import Darwin
import Foundation

struct UniversalBinaryCandidate: Identifiable, Equatable, Sendable {
    struct File: Equatable, Sendable {
        let relativePath: String
        let plan: UniversalMachO.Plan
    }
    var id: String { url.path }
    let url: URL
    let name: String
    let version: String
    let bundleIDs: [String]
    let tree: [String: UniversalBinarySafety.Stamp]
    let files: [File]
    var savedBytes: Int64 { files.reduce(0) { $0 + $1.plan.savedBytes } }
}

struct UniversalBinaryInventory: Sendable {
    var apps: [UniversalBinaryCandidate] = []
    var skipped: [UniversalBinarySkip: Int] = [:]
    var unreadableLocations = 0
    var rootOwnedAppCount = 0
    var savedBytes: Int64 { CleanupByteCount.sum(apps.map(\.savedBytes)) }
}

struct UniversalBinaryResult: Identifiable, Sendable {
    enum Status: Equatable, Sendable { case success, skipped, failed }
    let id: String
    let name: String
    let status: Status
    let detail: String
    var savedBytes: Int64 = 0
    var report: CleanReport? = nil
}

struct UniversalBinaryEnvironment: Sendable {
    var roots: [URL] = [URL(fileURLWithPath: "/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/Applications/Utilities")]
    var nativeCPU = UniversalMachO.hostCPU
    var ownURL = Bundle.main.bundleURL.standardizedFileURL
    var ownBundleID = Bundle.main.bundleIdentifier
    var signature: @Sendable (URL) throws -> Void = { try UniversalBinarySafety.signature($0) }
    var isApple: @Sendable (URL) throws -> Bool = { try UniversalBinarySafety.isApple($0) }
    var gatekeeper: @Sendable (URL) throws -> Bool = { try UniversalGatekeeper.assess($0) }
    var running: @Sendable (URL, [String]) async -> Bool = { await UniversalBinarySafety.isRunning($0, identifiers: $1) }
    var isAPFS: @Sendable (URL) -> Bool = { UniversalBinarySafety.isAPFS($0) }
    var clone: @Sendable (URL, URL) throws -> Void = { source, target in
        guard clonefile(source.path, target.path, UInt32(CLONE_NOFOLLOW)) == 0 else { throw UniversalBinarySkip.cloneFailed }
    }
    var trash: @Sendable (URL) throws -> URL = { source in
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let destination = destination as URL? else { throw CleanupMoveError.invalidResult }
        return destination
    }
    var metadata: any ReadOnlyFileSystem = FoundationReadOnlyFileSystem()
    var persist: @Sendable (CleanReport, [String: FileIdentity]) throws -> Void = {
        try CleanupReportJournal.live.checkpoint($0, expectedIdentities: $1)
    }
}

/// D184: a separate, explicit transaction per app. Ordinary cleanup never receives these paths.
enum UniversalBinaryService {
    static let ruleID = "applications.universal-thinning.d184"
    static let searchRoots = ["MacOS", "Frameworks", "PlugIns", "Library", "XPCServices", "Helpers", "Resources"]

    static func inventory(environment: UniversalBinaryEnvironment = .init()) async -> UniversalBinaryInventory {
        var result = UniversalBinaryInventory()
        var seen = Set<String>()
        for root in environment.roots {
            if Task.isCancelled { break }
            var rootInfo = stat()
            if lstat(root.path, &rootInfo) != 0, errno == ENOENT { continue }
            guard !PathSafety.containsSymbolicLinkComponent(in: root.path) else { result.unreadableLocations += 1; continue }
            let children: [URL]
            do { children = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) }
            catch { result.unreadableLocations += 1; continue }
            for app in children.sorted(by: { $0.path < $1.path }) where app.pathExtension.lowercased() == "app" {
                guard seen.insert(app.path).inserted else { continue }
                if Task.isCancelled { break }
                if (try? UniversalBinarySafety.stamp(app).owner) == 0 { result.rootOwnedAppCount += 1 }
                do { result.apps.append(try await inspect(app, environment: environment)) }
                catch let skip as UniversalBinarySkip { result.skipped[skip, default: 0] += 1 }
                catch is CancellationError { break }
                catch { result.skipped[.unsafeBundle, default: 0] += 1 }
            }
        }
        result.apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return result
    }

    static func inspect(_ app: URL, environment: UniversalBinaryEnvironment) async throws -> UniversalBinaryCandidate {
        try Task.checkCancellation()
        guard app.isFileURL, app.standardizedFileURL == app, app.pathExtension.lowercased() == "app",
              environment.roots.contains(app.deletingLastPathComponent()) else { throw UniversalBinarySkip.unsafeBundle }
        let root = try UniversalBinarySafety.stamp(app)
        guard root.identity.entryKind == .directory, !PathSafety.containsSymbolicLinkComponent(in: app.path) else {
            throw UniversalBinarySkip.unsafeBundle
        }
        guard root.owner == getuid(), root.owner != 0 else { throw UniversalBinarySkip.notOwned }
        guard access(app.path, R_OK | W_OK | X_OK) == 0,
              access(app.deletingLastPathComponent().path, W_OK | X_OK) == 0 else { throw UniversalBinarySkip.notWritable }
        let info = try information(app.appendingPathComponent("Contents/Info.plist"))
        guard let bundleID = info["CFBundleIdentifier"] as? String, !bundleID.isEmpty else { throw UniversalBinarySkip.unsafeBundle }
        let ourChannels: Set<String> = ["com.local.StorageCleanerMac", "com.local.StorageCleanerMac.beta", "com.local.StorageCleanerMac.integration"]
        if app == environment.ownURL || bundleID == environment.ownBundleID || ourChannels.contains(bundleID) {
            throw UniversalBinarySkip.ownApp
        }
        if FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            throw UniversalBinarySkip.appStore
        }
        if await environment.running(app, [bundleID]) { throw UniversalBinarySkip.running }
        let tree = try UniversalBinarySafety.tree(app)
        guard tree[""] == root else { throw UniversalBinarySkip.changed }
        // Reject external links before asking Security.framework to read bundle resources.
        try environment.signature(app)
        if try environment.isApple(app) { throw UniversalBinarySkip.apple }
        var files: [UniversalBinaryCandidate.File] = []
        var identifiers: Set<String> = [bundleID]
        for (relative, entry) in tree.sorted(by: { $0.key < $1.key }) where entry.identity.entryKind == .regularFile {
            try Task.checkCancellation()
            if relative.hasSuffix("/Info.plist"), relative != "Contents/Info.plist",
               let nested = try information(app.appendingPathComponent(relative))["CFBundleIdentifier"] as? String {
                identifiers.insert(nested)
            }
            guard searchRoots.contains(where: { relative.hasPrefix("Contents/\($0)/") }) else { continue }
            if let plan = try UniversalMachO.inspect(app.appendingPathComponent(relative), nativeCPU: environment.nativeCPU) {
                let (sum, overflow) = files.reduce(Int64(0), { $0 + $1.plan.savedBytes }).addingReportingOverflow(plan.savedBytes)
                guard !overflow, sum > 0 else { throw UniversalBinarySkip.unsafeBundle }
                files.append(.init(relativePath: relative, plan: plan))
            }
        }
        guard !files.isEmpty else { throw UniversalBinarySkip.noNativeSlice }
        guard try UniversalBinarySafety.tree(app) == tree else { throw UniversalBinarySkip.changed }
        let ids = identifiers.sorted()
        if await environment.running(app, ids) { throw UniversalBinarySkip.running }
        return UniversalBinaryCandidate(url: app,
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? app.deletingPathExtension().lastPathComponent,
            version: info["CFBundleShortVersionString"] as? String ?? info["CFBundleVersion"] as? String ?? "—",
            bundleIDs: ids, tree: tree, files: files)
    }

    private static func information(_ url: URL) throws -> [String: Any] {
        guard !PathSafety.containsSymbolicLinkComponent(in: url.path) else { throw UniversalBinarySkip.unsafeBundle }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw UniversalBinarySkip.unsafeBundle }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size > 0,
              value.st_size <= 1_048_576 else { throw UniversalBinarySkip.unsafeBundle }
        let data = try UniversalMachO.read(fd, offset: 0, count: Int(value.st_size))
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw UniversalBinarySkip.unsafeBundle
        }
        return info
    }

    static func execute(_ apps: [UniversalBinaryCandidate], environment: UniversalBinaryEnvironment = .init(),
                        beforeMutation: @escaping @Sendable () async throws -> Void = {}) async -> [UniversalBinaryResult] {
        var results: [UniversalBinaryResult] = []
        var seen = Set<String>()
        for app in apps where seen.insert(app.id).inserted {
            results.append(await thin(app, environment: environment, beforeMutation: beforeMutation))
        }
        return results
    }

    private static func thin(_ app: UniversalBinaryCandidate, environment env: UniversalBinaryEnvironment,
                             beforeMutation: @escaping @Sendable () async throws -> Void) async -> UniversalBinaryResult {
        func result(_ status: UniversalBinaryResult.Status, _ detail: String, bytes: Int64 = 0,
                    report: CleanReport? = nil) -> UniversalBinaryResult {
            .init(id: app.id, name: app.name, status: status, detail: detail, savedBytes: bytes, report: report)
        }
        // This visible backup name is also the Put Back destination in Operation History.
        let suffix = L10n.text("（瘦身前）", " (before thinning)")
        let staging = app.url.deletingLastPathComponent().appendingPathComponent(
            "\(app.url.deletingPathExtension().lastPathComponent)\(suffix).storagecleaner-thin-\(UUID().uuidString).app")
        var cloneIdentity: FileIdentity?
        var swapped = false
        var trashTarget: URL?
        var report: CleanReport?
        var preparationFailure: Error?
        var originalDescriptor: Int32 = -1
        defer { if originalDescriptor >= 0 { close(originalDescriptor) } }
        var phase = L10n.text("复核", "Preflight")
        do {
            try await beforeMutation()
            let fresh = try await inspect(app.url, environment: env)
            guard fresh == app else { throw UniversalBinarySkip.changed }
            guard env.isAPFS(app.url), env.isAPFS(app.url.deletingLastPathComponent()) else { throw UniversalBinarySkip.notAPFS }
            guard let scannedIdentity = app.tree[""]?.identity else { throw UniversalBinarySkip.changed }
            originalDescriptor = open(app.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard originalDescriptor >= 0 else { throw UniversalBinarySkip.changed }
            _ = try UniversalBinarySafety.trackedPath(originalDescriptor, identity: scannedIdentity)
            let requiredAssessment = try env.gatekeeper(app.url)
            phase = L10n.text("创建克隆", "Create clone")
            try Task.checkCancellation()
            try env.clone(app.url, staging)
            let created = try UniversalBinarySafety.stamp(staging)
            guard created.identity.entryKind == .directory, created.owner == getuid(),
                  created.identity.deviceID == app.tree[""]?.identity.deviceID,
                  created.identity != app.tree[""]?.identity else { throw UniversalBinarySkip.cloneFailed }
            cloneIdentity = created.identity
            let clonedTree = try UniversalBinarySafety.tree(staging)
            guard let cloneRoot = clonedTree[""], cloneRoot.identity != app.tree[""]?.identity,
                  cloneRoot.identity.deviceID == app.tree[""]?.identity.deviceID else { throw UniversalBinarySkip.cloneFailed }
            guard Set(clonedTree.keys) == Set(app.tree.keys), clonedTree.allSatisfy({ path, value in
                guard let original = app.tree[path] else { return false }
                return value.mode == original.mode && value.owner == original.owner
                    && (value.identity.entryKind != .regularFile || value.size == original.size)
            }) else { throw UniversalBinarySkip.changed }
            phase = L10n.text("写入本机代码", "Write native code")
            for file in app.files {
                try UniversalMachO.extract(file.plan, at: staging.appendingPathComponent(file.relativePath), clone: staging)
            }
            phase = L10n.text("校验副本", "Validate copy")
            try env.signature(staging)
            if requiredAssessment, try !env.gatekeeper(staging) { throw UniversalBinarySkip.gatekeeper }
            let validatedClone = try UniversalBinarySafety.tree(staging)
            phase = L10n.text("交换并记录原应用", "Swap and record original app")
            let originalIdentity = try UniversalBinarySafety.stamp(app.url).identity
            guard originalIdentity == app.tree[""]?.identity else { throw UniversalBinarySkip.changed }
            // RecordedTrashOperation checkpoints intent BEFORE validate is allowed to swap.
            let item = RecordedTrashOperation.Item(path: staging.path, bytes: app.savedBytes,
                identity: originalIdentity, allowedRestoreRoot: app.url.deletingLastPathComponent())
            let moveReport = await RecordedTrashOperation.runAsync(items: [item], ruleID: ruleID,
                validate: { _ in
                    try await beforeMutation()
                    guard try UniversalBinarySafety.stamp(app.url).identity == cloneRoot.identity,
                          try UniversalBinarySafety.stamp(staging).identity == originalIdentity else { throw UniversalBinarySkip.changed }
                }, move: { source in
                    let target = try env.trash(source)
                    trashTarget = target
                    return target
                }, metadata: env.metadata, persist: env.persist,
                prepare: { _ in
                    do {
                        try await beforeMutation()
                        try Task.checkCancellation()
                        guard try UniversalBinarySafety.tree(app.url) == app.tree,
                              try UniversalBinarySafety.tree(staging) == validatedClone else { throw UniversalBinarySkip.changed }
                        try env.signature(app.url)
                        guard try UniversalBinarySafety.tree(app.url) == app.tree else { throw UniversalBinarySkip.changed }
                        if await env.running(app.url, app.bundleIDs) { throw UniversalBinarySkip.running }
                        try swap(staging, app.url, left: cloneRoot.identity, right: originalIdentity)
                        swapped = true
                    } catch {
                        preparationFailure = error
                        throw error
                    }
                })
            report = moveReport
            if let preparationFailure { throw preparationFailure }
            guard moveReport.persistenceFailure == nil, let receipt = moveReport.restorableReceipts.first,
                  receipt.movedIdentity == originalIdentity,
                  try UniversalBinarySafety.stamp(app.url).identity == cloneRoot.identity else {
                throw CleanupMoveError.invalidResult
            }
            return result(.success, L10n.text("原应用已移入废纸篓，可从操作记录放回；清空废纸篓后才释放空间。",
                "Original app moved to Trash; put it back from Operation History. Space is freed after emptying Trash."),
                bytes: app.savedBytes, report: moveReport)
        } catch {
            let skip = error as? UniversalBinarySkip
            var detail = skip?.title ?? (error is CancellationError ? UniversalBinarySkip.cancelled.title : error.localizedDescription)
            if swapped, let cloneIdentity, let original = app.tree[""]?.identity {
                do {
                    // A completed Trash move with a failed receipt is compensated before swapping back.
                    var returnedFromTrash = false
                    if (try? UniversalBinarySafety.stamp(staging).identity) != original {
                        let source: URL
                        if let tracked = try? UniversalBinarySafety.trackedPath(originalDescriptor, identity: original) {
                            source = tracked
                        } else if let trashTarget, (try? UniversalBinarySafety.stamp(trashTarget).identity) == original {
                            source = trashTarget
                        } else { throw UniversalBinarySkip.changed }
                        try ExclusiveRecoveryMove.perform(source: source, destination: staging, expectedIdentity: original)
                        returnedFromTrash = true
                    }
                    try swap(staging, app.url, left: original, right: cloneIdentity)
                    swapped = false
                    if var compensated = report, returnedFromTrash {
                        compensated.recoveryAttempts = [CleanupRecoveryReport(completedAt: Date(), items: [
                            CleanupRecoveryItem(id: UUID(), originalPath: staging.path, outcome: .restored)])]
                        try? env.persist(compensated, [staging.path: original])
                        report = compensated
                    }
                } catch {
                    // Never delete either version if rollback cannot prove their identities.
                    detail += L10n.text("；无法自动还原，两份应用均已保留。请查看操作记录和应用所在文件夹。",
                        "; automatic rollback could not be confirmed. Both copies were kept; check Operation History and the app folder.")
                }
            }
            if !swapped, let cloneIdentity {
                do { try UniversalBinarySafety.discardClone(staging, identity: cloneIdentity) }
                catch { detail += L10n.text("；临时副本保留在：", "; temporary copy kept at: ") + staging.path }
            }
            if cloneIdentity == nil, FileManager.default.fileExists(atPath: staging.path) {
                detail += L10n.text("；未确认归属的临时项目已保留：", "; unverified temporary item kept at: ") + staging.path
            }
            let status: UniversalBinaryResult.Status = skip != nil && (cloneIdentity == nil || skip == .running
                || skip == .changed || skip == .cancelled) ? .skipped : .failed
            return result(status, phase + L10n.text("：", ": ") + detail, report: report)
        }
    }

    private static func swap(_ leftURL: URL, _ rightURL: URL, left: FileIdentity, right: FileIdentity) throws {
        guard leftURL.deletingLastPathComponent() == rightURL.deletingLastPathComponent(),
              UniversalBinarySafety.isStagingName(leftURL.lastPathComponent),
              !PathSafety.containsSymbolicLinkComponent(in: leftURL.path),
              !PathSafety.containsSymbolicLinkComponent(in: rightURL.path),
              try UniversalBinarySafety.stamp(leftURL).identity == left,
              try UniversalBinarySafety.stamp(rightURL).identity == right else { throw UniversalBinarySkip.changed }
        guard renamex_np(leftURL.path, rightURL.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(.EIO) }
    }

}
