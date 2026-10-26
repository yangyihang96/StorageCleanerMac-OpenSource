import Combine
import Foundation

/// All inputs cross the detached-task boundary as immutable index values.
/// The source owns only eight recent layouts; viewport changes never enter
/// their keys and therefore never repeat the tree traversal.
@MainActor
final class SpaceMapTreemapSource: ObservableObject {
    struct Key: Hashable, Sendable {
        let path: String
        let width: Int
        let height: Int
        let levels: Int
        let version: UInt64
        let keyword: String

        init(path: String, size: CGSize, levels: Int, version: UInt64, keyword: String = "") {
            self.path = path
            width = Int(max(1, size.width.rounded()))
            height = Int(max(1, size.height.rounded()))
            self.levels = min(6, max(1, levels))
            self.version = version
            self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var size: CGSize { CGSize(width: width, height: height) }
    }

    struct Input: Sendable {
        let snapshot: StorageMapDirectorySnapshot
        let index: StorageMapAnalysisIndex
        var filter: SpaceMapTreemapFilter.Result? = nil

        var roots: [StorageTreemapEntry] {
            StorageTreemapPresentation.mapLayoutEntries(from: snapshot.entries, measuredBytes: snapshot.measuredBytes,
                                                       referenceBytes: snapshot.referenceBytes, limit: .max)
        }

        func children(at path: String) -> [StorageTreemapEntry] {
            (try? DiskScanner(excludedPaths: []).storageMapSnapshot(at: path, using: index))?.entries ?? []
        }
    }

    typealias Layout = @Sendable (Input, Key) -> [SpaceMapTreemapLayout.Tile]
    struct FilterKey: Hashable, Sendable {
        let version: UInt64
        let path: String
        let keyword: String

        init(version: UInt64, path: String, keyword: String) {
            self.version = version
            self.path = DiskScanner.storageMapLogicalPath(path)
            self.keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    typealias Filter = @Sendable (StorageMapAnalysisIndex, FilterKey) -> SpaceMapTreemapFilter.Result?
    typealias Worth = @Sendable (StorageMapAnalysisIndex, SpaceMapPurposeMap, String) -> [SpaceLensWorthALook.Row]?
    struct Filtered: Sendable {
        let key: FilterKey
        let result: SpaceMapTreemapFilter.Result
    }

    @Published private(set) var purposeMap: SpaceMapPurposeMap?
    @Published private(set) var worthRows: [SpaceLensWorthALook.Row] = []
    @Published private(set) var worthVersion: UInt64?
    @Published private(set) var isFinding = false
    @Published private(set) var filtered: Filtered?
    private var layouts: [Key: [SpaceMapTreemapLayout.Tile]] = [:]
    private var recentKeys: [Key] = []
    private var purposeVersion: UInt64?
    private var currentVersion: UInt64?
    private let compute: Layout
    private let computeFilter: Filter
    private let computeWorth: Worth
    private var filters: [FilterKey: SpaceMapTreemapFilter.Result] = [:]
    private var recentFilters: [FilterKey] = []
    private var filterRequest = UUID()
    private var worthRequest = UUID()

    init(compute: @escaping Layout = SpaceMapTreemapSource.computeLayout,
         computeFilter: @escaping Filter = SpaceMapTreemapSource.computeFilter,
         computeWorth: @escaping Worth = SpaceMapTreemapSource.computeWorth) {
        self.compute = compute
        self.computeFilter = computeFilter
        self.computeWorth = computeWorth
    }

    nonisolated static func computeFilter(_ index: StorageMapAnalysisIndex, _ key: FilterKey) -> SpaceMapTreemapFilter.Result? {
        SpaceMapTreemapFilter.filter(index: index, basePath: key.path, keyword: key.keyword, isCancelled: { Task.isCancelled })
    }

    nonisolated static func computeWorth(_ index: StorageMapAnalysisIndex, _ purposes: SpaceMapPurposeMap,
                                         _ homePath: String) -> [SpaceLensWorthALook.Row]? {
        guard let findings = SpaceMapInsights.worthALook(index: index, purposes: purposes,
            limit: 6, minimumBytes: 64 * 1_024 * 1_024, isCancelled: { Task.isCancelled }) else { return nil }
        return SpaceLensWorthALook.rows(findings, index: index, homePath: homePath, isCancelled: { Task.isCancelled })
    }

    nonisolated static func computeLayout(_ input: Input, _ key: Key) -> [SpaceMapTreemapLayout.Tile] {
        let scanner = DiskScanner(excludedPaths: [])
        return SpaceMapTreemapLayout.layout(rootPath: input.snapshot.path, rootEntries: input.roots,
            in: CGRect(origin: .zero, size: key.size), options: .init(maxDepth: key.levels), children: { path in
                guard !Task.isCancelled else { return [] }
                return (try? scanner.storageMapSnapshot(at: path, using: input.index))?.entries ?? []
            }, filter: input.filter)
    }

    func layout(_ input: Input, key: Key) async -> [SpaceMapTreemapLayout.Tile]? {
        guard !Task.isCancelled else { return nil }
        if let cached = layouts[key] {
            touch(key)
            return cached
        }
        let compute = compute
        let task = Task.detached(priority: .userInitiated) { compute(input, key) }
        let tiles = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !task.isCancelled else { return nil }
        layouts[key] = tiles
        touch(key)
        while recentKeys.count > 8 { layouts[recentKeys.removeFirst()] = nil }
        return tiles
    }

    func classify(index: StorageMapAnalysisIndex, version: UInt64, homePath: String) async {
        guard !Task.isCancelled else { return }
        currentVersion = version
        if purposeVersion == version { return }
        purposeMap = nil
        purposeVersion = nil
        let task = Task.detached(priority: .utility) {
            SpaceMapPurposeClassifier.classify(index: index, homePath: homePath, isCancelled: { Task.isCancelled })
        }
        let map = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !task.isCancelled, currentVersion == version, let map else { return }
        purposeVersion = version
        purposeMap = map
    }

    var cachedLayoutCount: Int { layouts.count }

    func classification(for version: UInt64) -> SpaceMapPurposeMap? {
        purposeVersion == version ? purposeMap : nil
    }

    func findWorthALook(index: StorageMapAnalysisIndex, version: UInt64, homePath: String) async {
        guard !Task.isCancelled, worthVersion != version else { return }
        let request = UUID()
        worthRequest = request
        isFinding = true
        defer { if worthRequest == request { isFinding = false } }
        await classify(index: index, version: version, homePath: homePath)
        guard !Task.isCancelled, let purposes = classification(for: version) else { return }
        let computeWorth = computeWorth
        let task = Task.detached(priority: .utility) { computeWorth(index, purposes, homePath) }
        let rows = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !task.isCancelled, worthRequest == request, let rows else { return }
        worthRows = rows
        worthVersion = version
    }

    func filter(index: StorageMapAnalysisIndex, key: FilterKey, debounce: Duration = .milliseconds(150)) async {
        guard !Task.isCancelled else { return }
        let request = UUID()
        filterRequest = request
        guard !key.keyword.isEmpty else { filtered = nil; return }
        if let cached = filters[key] {
            filtered = Filtered(key: key, result: cached)
            return
        }
        do { try await Task.sleep(for: debounce) } catch { return }
        guard !Task.isCancelled, request == filterRequest else { return }
        let computeFilter = computeFilter
        let task = Task.detached(priority: .userInitiated) { computeFilter(index, key) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !task.isCancelled, request == filterRequest, let result else { return }
        filters[key] = result
        recentFilters.removeAll { $0 == key }
        recentFilters.append(key)
        while recentFilters.count > 8 { filters[recentFilters.removeFirst()] = nil }
        filtered = Filtered(key: key, result: result)
    }

    /// Keep the last accepted result while the next keystroke is debouncing.
    /// A new directory never reuses its parent's matches.
    func activeFilter(version: UInt64, path: String, keyword: String) -> SpaceMapTreemapFilter.Result? {
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let filtered, filtered.key.version == version, filtered.key.path == path else { return nil }
        return filtered.result
    }

    private func touch(_ key: Key) {
        recentKeys.removeAll { $0 == key }
        recentKeys.append(key)
    }
}
