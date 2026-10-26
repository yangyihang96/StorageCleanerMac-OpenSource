import AppKit
import Combine
import Foundation

/// One installed application in the manager.
struct ApplicationEntry: Identifiable, Sendable {
    let item: InstalledAppItem
    let profile: ApplicationProfile?
    var classification: ApplicationClassification
    /// Nil while still loading in the background (CleanMyMac
    /// `ApplicationsBackgroundResourcesLoadingHandler`).
    var resources: [ApplicationResource]?
    let isThisApplication: Bool

    var id: String { item.id }
    var isProtectedSystemApplication: Bool { profile?.isProtectedSystemApplication ?? false }
    var bundleResourceID: String { PathSafety.lexicalPath(item.path) }
    var removableResources: [ApplicationResource] { (resources ?? []).filter(\.isRemovable) }
    var totalBytes: Int64 {
        guard let resources else { return item.sizeBytes }
        return resources.reduce(0) { $0 + $1.sizeBytes }
    }
}

enum ApplicationSortMode: String, CaseIterable, Identifiable, Sendable {
    case name, size, lastOpened, lastUpdated
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: L10n.text("名称", "Name")
        case .size: L10n.text("大小", "Size")
        case .lastOpened: L10n.text("上次打开时间", "Last Opened")
        case .lastUpdated: L10n.text("上次更新时间", "Last Updated")
        }
    }
}

/// CleanMyMac's Applications data manager, rebuilt over this app's
/// inventory: categories, CleanMyMac's selection rule (an app's checkbox
/// selects every item it found; leaving the binary out is a reset), the
/// running-app step, the removal and the completion screen.
@MainActor
final class ApplicationsManagerModel: ObservableObject {
    enum Phase: Equatable {
        case browsing
        /// CleanMyMac's dialog when it is asked to uninstall itself.
        case confirmingSelfRemoval
        case terminating
        case removing(current: String, index: Int, total: Int)
        case finished
    }

    struct RunningApplication: Identifiable, Equatable {
        enum State: Equatable { case running, quitting, quit, cannotQuit, ignored }
        let id: String
        let title: String
        let path: String
        let bundleIdentifier: String
        var state: State
    }

    @Published private(set) var ignoredApplicationCount = 0
    @Published private(set) var ignoredLeftoverCount = 0
    @Published private(set) var ignoredDownloadCount = 0
    @Published private(set) var ignoredPluginCount = 0
    var ignoredTotal: Int { ignoredApplicationCount + ignoredLeftoverCount + ignoredDownloadCount + ignoredPluginCount }
    var ignoredSummary: String { IgnoreListSnapshot.summary(ignoredTotal) }
    private var scanIgnoreList = IgnoreListSnapshot.empty
    /// D207: which listing a held app or leftover belongs to; a reload or a
    /// new leftover scan makes a fresh one, which Put Back leaves alone.
    private var entriesRevision = 0
    private var leftoversRevision = 0
    private var completeInventory: [InstalledAppItem] = []
    @Published private(set) var entries: [ApplicationEntry] = []
    @Published private(set) var otherApplications = OtherApplicationsReport()
    @Published private(set) var isScanningOtherApplications = false
    @Published var otherApplicationSelection: Set<String> = []
    private var completeOtherApplications = OtherApplicationsReport()
    private let otherApplicationsScanner: OtherApplicationsScanner
    private var otherApplicationsTask: Task<Void, Never>?
    @Published private(set) var leftovers: [LeftoverGroup] = []
    @Published private(set) var installers: [InstallerFile] = []
    @Published private(set) var audioPlugins: [InstallerFile] = []
    @Published var pluginSelection: Set<String> = []
    /// CleanMyMac shows its result tiles after every scan, before the
    /// manager; set when the store's inventory scan ends.
    @Published var showsOverview = false
    @Published private(set) var isLoadingResources = false
    @Published private(set) var isScanningLeftovers = false
    @Published var category: ApplicationCategory = .all
    @Published var sortMode: ApplicationSortMode = .name
    @Published var searchText = ""
    @Published var expanded: Set<String> = []
    /// Entry id → selected resource ids (the bundle's id is its path).
    @Published var selection: [String: Set<String>] = [:]
    @Published var leftoverSelection: Set<String> = []
    @Published var installerSelection: Set<String> = []
    @Published private(set) var phase: Phase = .browsing
    @Published var runningApplications: [RunningApplication] = []
    @Published private(set) var outcomes: [ApplicationRemovalOutcome] = []
    /// Why the removal did not start (another task held the exclusive lease,
    /// or another copy of the app did): nothing moved and the selection
    /// stays (10-24: it read "Some files were not removed · Files are in the
    /// Trash" with an unreadable error in the log).
    @Published private(set) var startFailure: String?
    /// Apps that were in the Trash when the reminder handed them over.
    @Published private(set) var trashedApplications: [TrashedApplication] = []

    private weak var store: ScanStore?
    private var scanEnd: AnyCancellable?
    /// The rescan after “Manage More Items” returns to the list, not the tiles.
    private var keepsListAfterScan = false
    private var loadTask: Task<Void, Never>?
    private var leftoverTask: Task<Void, Never>?
    private var removalTask: Task<Void, Never>?
    private var pendingRequests: [ApplicationRemovalRequest] = []
    private var loadedInventoryIDs: [String] = []
    /// Set when bundles moved: the inventory is rescanned on “Manage More
    /// Items”, so the completion screen stays until then.
    private var needsInventoryRefresh = false
    var removal = ApplicationRemovalService()

    /// One manager per store (the app has one): switching pages keeps its
    /// selection and the background loading going, and every test store
    /// gets its own.
    private static let models = NSMapTable<ScanStore, ApplicationsManagerModel>.weakToStrongObjects()

    static func of(_ store: ScanStore) -> ApplicationsManagerModel {
        if let model = models.object(forKey: store) { return model }
        let model = ApplicationsManagerModel()
        model.attach(store)
        models.setObject(model, forKey: store)
        return model
    }

    init(otherApplicationsScanner: OtherApplicationsScanner = OtherApplicationsScanner()) {
        self.otherApplicationsScanner = otherApplicationsScanner
    }

    func attach(_ store: ScanStore) {
        self.store = store
        scanEnd = store.$isLoadingInstalledApps
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] loading in
                guard let self, !loading else { return }
                if keepsListAfterScan { keepsListAfterScan = false } else { showsOverview = true }
            }
    }

    // MARK: Loading

    /// Rebuilds the entries from the store's inventory and loads each app's
    /// resources in the background. `readsDisk == false` (inert presentation
    /// fixtures) lists the inventory only: no bundle, Library or Spotlight
    /// reads.
    func load(inventory: [InstalledAppItem], readsDisk: Bool = true, ignoreList: IgnoreListSnapshot? = nil) {
        let snapshot = ignoreList ?? store?.currentIgnoreListSnapshot() ?? .empty
        let changedIgnores = snapshot != scanIgnoreList
        scanIgnoreList = snapshot
        applyOtherApplications(completeOtherApplications)
        completeInventory = inventory
        let inventory = inventory.filter { !snapshot.ignoresApplication(bundleIdentifier: $0.bundleIdentifier, path: $0.path, category: .uninstaller) }
        ignoredApplicationCount = completeInventory.count - inventory.count
        let ids = inventory.map(\.id)
        guard changedIgnores || ids != loadedInventoryIDs || entries.isEmpty else { return }
        loadedInventoryIDs = ids
        entriesRevision += 1
        loadTask?.cancel()
        let ownPath = PathSafety.lexicalPath(Bundle.main.bundleURL.path)
        let previous = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        entries = inventory.map { item in
            if let kept = previous[item.id], kept.item.scanIdentity == item.scanIdentity { return kept }
            return ApplicationEntry(
                item: item, profile: nil,
                classification: ApplicationClassification(
                    store: ApplicationClassification.store(for: item.path, bundleIdentifier: item.bundleIdentifier),
                    vendor: ApplicationVendor.of(bundleIdentifier: item.bundleIdentifier, teamIdentifier: nil),
                    isUnused: ApplicationClassification.isUnused(lastUsed: item.lastUsedAt, installed: item.modifiedAt),
                    isThirtyTwoBitOnly: false, suspiciousReason: nil),
                resources: nil,
                isThisApplication: PathSafety.lexicalPath(item.path) == ownPath
            )
        }
        selection = selection.filter { key, _ in ids.contains(key) }
        let pending = entries.filter { $0.resources == nil }.map(\.item)
        guard readsDisk else { return }
        refreshOtherApplications()
        // Ignoring every app must not hide residual resources or installers.
        scanLeftoversAndInstallers()
        guard !pending.isEmpty else { isLoadingResources = false; return }
        isLoadingResources = true
        let identifiers = Set(completeInventory.map(\.bundleIdentifier))
        let paths = Set(completeInventory.map { PathSafety.lexicalPath($0.path) })
        loadTask = Task { [weak self] in
            await withTaskGroup(of: ApplicationEntryLoad?.self) { group in
                var iterator = pending.makeIterator()
                func addNext() {
                    guard let item = iterator.next() else { return }
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return nil }
                        return ApplicationEntryLoad.load(item, installedIdentifiers: identifiers, installedPaths: paths)
                    }
                }
                for _ in 0..<3 { addNext() }
                for await loaded in group {
                    addNext()
                    guard let loaded, let self else { continue }
                    self.apply(loaded)
                }
            }
            self?.isLoadingResources = false
        }
    }

    private func apply(_ loaded: ApplicationEntryLoad) {
        guard let index = entries.firstIndex(where: { $0.id == loaded.id }) else { return }
        let old = entries[index]
        entries[index] = ApplicationEntry(item: old.item, profile: loaded.profile, classification: loaded.classification,
                                          resources: loaded.resources, isThisApplication: old.isThisApplication)
        // An app selected before its items finished loading gets them all.
        if let selected = selection[old.id], selected.contains(old.bundleResourceID) {
            selection[old.id] = Set(entries[index].removableResources.map(\.id))
        }
    }

    func scanLeftoversAndInstallers() {
        leftoverTask?.cancel()
        isScanningLeftovers = true
        let identifiers = Set(completeInventory.map(\.bundleIdentifier))
        let names = completeInventory.map(\.name)
        let ignoreList = scanIgnoreList
        leftoverTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (LeftoverScanner(installedBundleIdentifiers: identifiers, ignoreList: ignoreList).scanReport(),
                 UnusedInstallerScanner(installedApplicationNames: names, ignoreList: ignoreList).scanReport(),
                 AudioPluginScanner(ignoreList: ignoreList).scanReport())
            }.value
            guard let self, !Task.isCancelled else { return }
            leftovers = result.0.groups
            leftoversRevision += 1
            ignoredLeftoverCount = result.0.ignoredCount
            installers = result.1.files
            ignoredDownloadCount = result.1.ignoredCount
            audioPlugins = result.2.files
            ignoredPluginCount = result.2.ignoredCount
            // CleanMyMac preselects every leftover; installers are preselected
            // when the app they install is already here.
            leftoverSelection = Set(result.0.groups.flatMap(\.resources).map(\.id))
            installerSelection = Set(result.1.files.filter(\.preselected).map(\.id))
            isScanningLeftovers = false
        }
    }

    // MARK: Listing

    /// Runs only from the real manager's disk-reading path or an explicit
    /// rescan. Inert fixtures never launch a Spotlight query.
    func refreshOtherApplications() {
        otherApplicationsTask?.cancel()
        isScanningOtherApplications = true
        let scanner = otherApplicationsScanner
        otherApplicationsTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { try await scanner.scan() }
            do {
                let report = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: { worker.cancel() }
                guard let self, !Task.isCancelled else { return }
                completeOtherApplications = report
                applyOtherApplications(report)
                isScanningOtherApplications = false
            } catch {
                guard let self, !Task.isCancelled else { return }
                isScanningOtherApplications = false
            }
        }
    }

    func waitForOtherApplications() async { await otherApplicationsTask?.value }

    private func applyOtherApplications(_ report: OtherApplicationsReport) {
        var visible = OtherApplicationsReport.grouping(report.groups.flatMap(\.copies), ignoreList: scanIgnoreList)
        visible.unavailableReason = report.unavailableReason
        otherApplications = visible
        otherApplicationSelection.formIntersection(visible.groups.flatMap(\.copies).map(\.path))
    }

    var visibleOtherApplications: [OtherApplicationGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return otherApplications.groups.filter { group in
            query.isEmpty || group.name.localizedCaseInsensitiveContains(query)
                || group.copies.contains { $0.path.localizedCaseInsensitiveContains(query)
                    || $0.bundleIdentifier.localizedCaseInsensitiveContains(query) }
        }.sorted { lhs, rhs in
            switch sortMode {
            case .size: return lhs.sizeBytes > rhs.sizeBytes
            case .lastUpdated:
                return (lhs.copies.compactMap(\.modifiedAt).max() ?? .distantPast)
                    > (rhs.copies.compactMap(\.modifiedAt).max() ?? .distantPast)
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    func toggleOtherApplications(_ group: OtherApplicationGroup) {
        let paths = Set(group.copies.map(\.path))
        if paths.isSubset(of: otherApplicationSelection) { otherApplicationSelection.subtract(paths) }
        else { otherApplicationSelection.formUnion(paths) }
    }

    func toggleOtherApplication(_ path: String) {
        guard otherApplications.groups.contains(where: { $0.copies.contains { $0.path == path } }) else { return }
        if !otherApplicationSelection.insert(path).inserted { otherApplicationSelection.remove(path) }
    }

    func count(in category: ApplicationCategory) -> Int {
        switch category {
        case .otherLocations: return otherApplications.groups.count
        case .selected:
            return entries.filter { matches($0, category) }.count
                + otherApplications.groups.filter { $0.copies.contains { otherApplicationSelection.contains($0.path) } }.count
        case .leftovers: return leftovers.count
        case .installers: return installers.count
        case .audioPlugins: return audioPlugins.count
        default: return entries.filter { matches($0, category) }.count
        }
    }

    func matches(_ entry: ApplicationEntry, _ category: ApplicationCategory) -> Bool {
        switch category {
        case .all: return true
        case .unused: return entry.classification.isUnused && !entry.isProtectedSystemApplication
        case .suspicious: return entry.classification.suspiciousReason != nil
        case .selected: return !(selection[entry.id] ?? []).isEmpty
        case .store(let store): return entry.classification.store == store
        case .vendor(let vendor): return entry.classification.vendor == vendor
        case .thirtyTwoBit: return entry.classification.isThirtyTwoBitOnly
        case .audioPlugins, .leftovers, .installers, .otherLocations: return false
        }
    }

    var visibleEntries: [ApplicationEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = entries.filter { entry in
            matches(entry, category) && (query.isEmpty || entry.item.name.lowercased().contains(query)
                || entry.item.bundleIdentifier.lowercased().contains(query))
        }
        return filtered.sorted { lhs, rhs in
            switch sortMode {
            case .name:
                return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
            case .size:
                return lhs.totalBytes > rhs.totalBytes
            case .lastOpened:
                return (lhs.item.lastUsedAt ?? .distantPast) > (rhs.item.lastUsedAt ?? .distantPast)
            case .lastUpdated:
                return (lhs.item.modifiedAt ?? .distantPast) > (rhs.item.modifiedAt ?? .distantPast)
            }
        }
    }

    // MARK: Selection (CleanMyMac rules)

    enum SelectionState { case none, partial, all }

    func selectionState(of entry: ApplicationEntry) -> SelectionState {
        let selected = selection[entry.id] ?? []
        guard !selected.isEmpty else { return .none }
        let removable = Set(entry.removableResources.map(\.id))
        if entry.resources == nil { return selected.contains(entry.bundleResourceID) ? .all : .partial }
        return removable.isSubset(of: selected) ? .all : .partial
    }

    /// The app checkbox: everything found, or nothing. A protected system app
    /// selects its related files only (a reset).
    func toggle(_ entry: ApplicationEntry) {
        if selectionState(of: entry) == .all {
            selection[entry.id] = nil
            return
        }
        if entry.resources == nil {
            selection[entry.id] = entry.isProtectedSystemApplication ? [] : [entry.bundleResourceID]
        } else {
            selection[entry.id] = Set(entry.removableResources.map(\.id))
        }
    }

    func toggle(_ resource: ApplicationResource, in entry: ApplicationEntry) {
        guard resource.isRemovable else { return }
        var selected = selection[entry.id] ?? []
        if selected.contains(resource.id) { selected.remove(resource.id) } else { selected.insert(resource.id) }
        selection[entry.id] = selected.isEmpty ? nil : selected
    }

    func toggle(group: ApplicationResourceGroup, in entry: ApplicationEntry) {
        let ids = Set(entry.removableResources.filter { $0.group == group }.map(\.id))
        guard !ids.isEmpty else { return }
        var selected = selection[entry.id] ?? []
        if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
        selection[entry.id] = selected.isEmpty ? nil : selected
    }

    func isSelected(_ resource: ApplicationResource, in entry: ApplicationEntry) -> Bool {
        (selection[entry.id] ?? []).contains(resource.id)
    }

    /// `uninstaller_footer_title`: whole applications and single items.
    var selectionSummary: (applications: Int, items: Int, bytes: Int64) {
        if category == .otherLocations {
            let copies = selectedOtherApplicationCopies
            return (copies.count, 0, copies.reduce(0) { $0 + $1.sizeBytes })
        }
        var applications = 0
        var items = 0
        var bytes: Int64 = 0
        for entry in entries {
            let selected = selection[entry.id] ?? []
            guard !selected.isEmpty else { continue }
            let resources = (entry.resources ?? []).filter { selected.contains($0.id) }
            bytes += resources.reduce(0) { $0 + $1.sizeBytes }
            if entry.resources == nil, selected.contains(entry.bundleResourceID) { bytes += entry.item.sizeBytes }
            if selected.contains(entry.bundleResourceID) { applications += 1 } else { items += resources.count }
        }
        for app in otherApplications.groups.flatMap(\.copies) where otherApplicationSelection.contains(app.path) {
            applications += 1
            bytes += app.sizeBytes
        }
        for group in leftovers {
            for resource in group.resources where leftoverSelection.contains(resource.id) {
                items += 1
                bytes += resource.sizeBytes
            }
        }
        for file in installers where installerSelection.contains(file.id) {
            items += 1
            bytes += file.resource.sizeBytes
        }
        for plugin in audioPlugins where pluginSelection.contains(plugin.id) {
            items += 1
            bytes += plugin.resource.sizeBytes
        }
        return (applications, items, bytes)
    }

    var footerTitle: String {
        let summary = selectionSummary
        switch (summary.applications, summary.items) {
        case (0, 0): return L10n.text("未选择应用程序", "No Applications Selected")
        case (let apps, 0): return L10n.text("已选择 \(ByteFormat.count(apps)) 个应用程序", "\(ByteFormat.count(apps)) Application\(apps == 1 ? "" : "s") Selected")
        case (0, let items): return L10n.text("已选择 \(ByteFormat.count(items)) 个项目", "\(ByteFormat.count(items)) Item\(items == 1 ? "" : "s") Selected")
        case (let apps, let items):
            return L10n.text("已选择 \(ByteFormat.count(apps)) 个应用程序和 \(ByteFormat.count(items)) 个项目",
                             "\(ByteFormat.count(apps)) Application\(apps == 1 ? "" : "s") and \(ByteFormat.count(items)) Item\(items == 1 ? "" : "s") Selected")
        }
    }

    /// CleanMyMac's Uninstall / Remove, in the page's approved wording (the
    /// page title is already “卸载”, so the button names what it acts on).
    var primaryActionTitle: String {
        switch category {
        case .leftovers, .installers, .audioPlugins, .otherLocations: return L10n.text("移除所选", "Remove Selected")
        default:
            let summary = selectionSummary
            return summary.applications == 0 && summary.items > 0
                ? L10n.text("移除所选", "Remove Selected") : L10n.text("卸载所选", "Uninstall Selected")
        }
    }

    var hasSelection: Bool {
        let summary = selectionSummary
        return summary.applications + summary.items > 0
    }

    // MARK: Result tiles (CleanMyMac `ApplicationsTilesMapper`)

    enum Tile: Hashable { case unused, leftovers, installers, thirtyTwoBit }

    var unusedEntries: [ApplicationEntry] { entries.filter { matches($0, .unused) } }
    var thirtyTwoBitEntries: [ApplicationEntry] { entries.filter { matches($0, .thirtyTwoBit) } }
    var leftoverBytes: Int64 { leftovers.reduce(0) { $0 + $1.totalBytes } }
    var installerBytes: Int64 { installers.reduce(0) { $0 + $1.resource.sizeBytes } }

    /// A tile's primary button (“Uninstall” / “Remove”): just that tile's
    /// items, through the same running-app step and receipts.
    func runTile(_ tile: Tile) {
        guard phase == .browsing else { return }
        selection = [:]
        leftoverSelection = []
        installerSelection = []
        pluginSelection = []
        switch tile {
        case .unused:
            for entry in unusedEntries { selection[entry.id] = entry.resources.map { Set($0.filter(\.isRemovable).map(\.id)) } ?? [entry.bundleResourceID] }
            category = .unused
        case .thirtyTwoBit:
            for entry in thirtyTwoBitEntries { selection[entry.id] = entry.resources.map { Set($0.filter(\.isRemovable).map(\.id)) } ?? [entry.bundleResourceID] }
            category = .thirtyTwoBit
        case .leftovers:
            leftoverSelection = Set(leftovers.flatMap(\.resources).filter(\.isRemovable).map(\.id))
            category = .leftovers
        case .installers:
            installerSelection = Set(installers.filter(\.preselected).map(\.id))
            category = .installers
        }
        showsOverview = false
        requestRemoval()
    }

    /// Report §4 item 12 (CleanMyMac's Start Over): nothing stays ticked or
    /// filtered when Applications goes back to its landing page. Not while a
    /// removal runs.
    // MARK: D207 ignore list (CleanMyMac's Add to Ignore List)

    var canIgnore: Bool { phase == .browsing }

    /// D207: these apps go on the ignore list under Uninstaller and leave the
    /// uninstall and unused lists as a load leaves out what the list covers,
    /// among the ignored apps. Their leftovers stay: an app on the list does
    /// not hide them. Put Back returns them, selected as they were.
    func ignoreApplications(_ ids: [String], feedback: IgnoreListFeedback) {
        let requested = Set(ids)
        let chosen = entries.filter { requested.contains($0.id) }
        guard canIgnore, !chosen.isEmpty, let snapshot = feedback.add(chosen.map {
            IgnoreListFeedback.Item(target: .application(bundleIdentifier: $0.item.bundleIdentifier, path: $0.item.path),
                                    category: .uninstaller, name: $0.item.name)
        }) else { return }
        let held = entries.enumerated().filter {
            snapshot.ignoresApplication(bundleIdentifier: $0.element.item.bundleIdentifier, path: $0.element.item.path, category: .uninstaller)
        }.map { (index: $0.offset, entry: $0.element) }
        guard !held.isEmpty else { return }
        let heldIDs = Set(held.map(\.entry.id))
        let wasSelected = selection.filter { heldIDs.contains($0.key) }
        entries.removeAll { heldIDs.contains($0.id) }
        selection = selection.filter { !heldIDs.contains($0.key) }
        // The next load finds the list as this result has it: no reload.
        loadedInventoryIDs = entries.map(\.id)
        scanIgnoreList = snapshot
        ignoredApplicationCount += held.count
        let revision = entriesRevision
        feedback.onPutBack { [weak self] snapshot in
            self?.putBackApplications(held, selected: wasSelected, revision: revision, snapshot: snapshot)
        }
    }

    /// Put Back: apps the list no longer covers return to their places in the same listing.
    private func putBackApplications(_ held: [(index: Int, entry: ApplicationEntry)], selected: [String: Set<String>],
                                     revision: Int, snapshot: IgnoreListSnapshot) {
        guard canIgnore, revision == entriesRevision else { return }
        let present = Set(entries.map(\.id))
        let returning = held.filter {
            !present.contains($0.entry.id)
                && !snapshot.ignoresApplication(bundleIdentifier: $0.entry.item.bundleIdentifier, path: $0.entry.item.path,
                                                category: .uninstaller)
        }
        guard !returning.isEmpty else { return }
        for item in returning.sorted(by: { $0.index < $1.index }) {
            entries.insert(item.entry, at: min(item.index, entries.count))
        }
        for item in returning { if let resources = selected[item.entry.id] { selection[item.entry.id] = resources } }
        loadedInventoryIDs = entries.map(\.id)
        scanIgnoreList = snapshot
        ignoredApplicationCount = max(0, ignoredApplicationCount - returning.count)
    }

    /// D207: these leftovers go on the ignore list under Uninstaller by path,
    /// as the leftover scan reads them, and leave the list among the ignored
    /// leftovers; a group left empty goes. Put Back returns them, selected as
    /// they were.
    func ignoreLeftovers(_ resourceIDs: Set<String>, feedback: IgnoreListFeedback) {
        let chosen = leftovers.flatMap { group in group.resources.filter { resourceIDs.contains($0.id) }.map { (group, $0) } }
        guard canIgnore, !chosen.isEmpty, let snapshot = feedback.add(chosen.map { group, resource in
            IgnoreListFeedback.Item(target: IgnoreListTarget(path: resource.path), category: .uninstaller,
                                    name: group.displayName + " · " + URL(fileURLWithPath: resource.path).lastPathComponent)
        }) else { return }
        var held: [HeldLeftover] = []
        var remaining: [LeftoverGroup] = []
        for (groupIndex, group) in leftovers.enumerated() {
            var kept = group
            kept.resources = []
            for (index, resource) in group.resources.enumerated() {
                if snapshot.ignores(path: resource.path, category: .uninstaller, includingDescendants: true) {
                    held.append(HeldLeftover(group: group, groupIndex: groupIndex, resource: resource, index: index))
                } else {
                    kept.resources.append(resource)
                }
            }
            if !kept.resources.isEmpty { remaining.append(kept) }
        }
        guard !held.isEmpty else { return }
        let heldIDs = Set(held.map(\.resource.id))
        let wasSelected = leftoverSelection.intersection(heldIDs)
        leftovers = remaining
        leftoverSelection.subtract(heldIDs)
        ignoredLeftoverCount += held.count
        scanIgnoreList = snapshot
        let revision = leftoversRevision
        feedback.onPutBack { [weak self] snapshot in
            self?.putBackLeftovers(held, selected: wasSelected, revision: revision, snapshot: snapshot)
        }
    }

    struct HeldLeftover {
        let group: LeftoverGroup
        let groupIndex: Int
        let resource: ApplicationResource
        let index: Int
    }

    /// Put Back: leftovers the list no longer covers return to their groups in
    /// the same listing, a group that had gone back to its place.
    private func putBackLeftovers(_ held: [HeldLeftover], selected: Set<String>, revision: Int, snapshot: IgnoreListSnapshot) {
        guard canIgnore, revision == leftoversRevision else { return }
        let present = Set(leftovers.flatMap(\.resources).map(\.id))
        let returning = held.filter {
            !present.contains($0.resource.id) && !snapshot.ignores(path: $0.resource.path, category: .uninstaller, includingDescendants: true)
        }
        guard !returning.isEmpty else { return }
        for item in returning.sorted(by: { ($0.groupIndex, $0.index) < ($1.groupIndex, $1.index) }) {
            if let groupIndex = leftovers.firstIndex(where: { $0.id == item.group.id }) {
                leftovers[groupIndex].resources.insert(item.resource, at: min(item.index, leftovers[groupIndex].resources.count))
            } else {
                var group = item.group
                group.resources = [item.resource]
                leftovers.insert(group, at: min(item.groupIndex, leftovers.count))
            }
        }
        leftoverSelection.formUnion(selected.intersection(returning.map(\.resource.id)))
        ignoredLeftoverCount = max(0, ignoredLeftoverCount - returning.count)
        scanIgnoreList = snapshot
    }

    /// D225 (D207, D215): copies of apps outside the standard folders go on
    /// the ignore list under Uninstaller by path — every copy of an app from
    /// its row, one copy from its own row — and leave the list as the scan
    /// leaves out what the list covers, among the ignored; an app left with
    /// no copy goes. Put Back returns them, selected as they were. Only the
    /// listing changes: the D212 merging and D218's bundle-only removal are
    /// untouched.
    func ignoreOtherApplications(_ paths: [String], feedback: IgnoreListFeedback) {
        let requested = Set(paths)
        let chosen = otherApplications.groups.flatMap(\.copies).filter { requested.contains($0.path) }
        guard canIgnore, !chosen.isEmpty, let snapshot = feedback.add(chosen.map {
            IgnoreListFeedback.Item(target: IgnoreListTarget(path: $0.path), category: .uninstaller, name: $0.name)
        }) else { return }
        let wasSelected = otherApplicationSelection.intersection(chosen.map(\.path))
        scanIgnoreList = snapshot
        applyOtherApplications(completeOtherApplications)
        feedback.onPutBack { [weak self] snapshot in
            guard let self, canIgnore else { return }
            scanIgnoreList = snapshot
            applyOtherApplications(completeOtherApplications)
            let listed = Set(otherApplications.groups.flatMap(\.copies).map(\.path))
            otherApplicationSelection.formUnion(wasSelected.intersection(listed))
        }
    }

    func startOver() {
        guard phase == .browsing else { return }
        selection = [:]
        leftoverSelection = []
        installerSelection = []
        pluginSelection = []
        category = .all
        searchText = ""
        showsOverview = false
    }

    /// A tile's “Review” button.
    func review(_ category: ApplicationCategory) {
        self.category = category
        showsOverview = false
    }

    // MARK: Trashed applications (from the reminder)

    /// CleanMyMac `UninstallAppFlowCoordinator` for apps already in the Trash:
    /// each is shown with what it left, everything selected.
    func beginTrashedApplications(_ apps: [TrashedApplication]) {
        trashedApplications = apps
        showsOverview = false
        category = .all
        let identifiers = Set(entries.map(\.item.bundleIdentifier))
        let paths = Set(entries.map { PathSafety.lexicalPath($0.item.path) })
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { () -> [LeftoverGroup] in
                apps.compactMap { app in
                    guard let profile = ApplicationProfileReader.profile(at: app.url) else { return nil }
                    let finder = ApplicationResourceFinder(installedBundleIdentifiers: identifiers.subtracting([profile.bundleIdentifier]),
                                                           installedApplicationPaths: paths)
                    let resources = finder.resources(for: profile, includeBundle: false)
                    return LeftoverGroup(bundleIdentifier: profile.bundleIdentifier, displayName: app.displayName, resources: resources)
                }
            }.value
            let groups = Self.mergingByIdentifier(found)
            guard let self else { return }
            leftovers = groups + leftovers.filter { group in !groups.contains { $0.bundleIdentifier == group.bundleIdentifier } }
            leftoversRevision += 1
            leftoverSelection.formUnion(groups.flatMap(\.resources).filter(\.isRemovable).map(\.id))
            category = .leftovers
        }
    }

    /// D212: copies of one app in the Trash find the same leftovers (10-25:
    /// three builds of one app made three identical groups, and two of their
    /// requests found the files already moved). One group per identifier,
    /// each path once.
    static func mergingByIdentifier(_ groups: [LeftoverGroup]) -> [LeftoverGroup] {
        var merged: [LeftoverGroup] = []
        for group in groups {
            if let index = merged.firstIndex(where: { $0.bundleIdentifier == group.bundleIdentifier }) {
                let known = Set(merged[index].resources.map(\.id))
                merged[index].resources += group.resources.filter { !known.contains($0.id) }
            } else {
                merged.append(group)
            }
        }
        return merged
    }

    // MARK: Removal

    func requestRemoval() {
        guard phase == .browsing, hasSelection else { return }
        pendingRequests = buildRequests()
        guard !pendingRequests.isEmpty else { return }
        if pendingRequests.contains(where: isSelfRemoval) {
            phase = .confirmingSelfRemoval
            return
        }
        proceedToTermination()
    }

    func confirmSelfRemoval(_ confirmed: Bool) {
        guard phase == .confirmingSelfRemoval else { return }
        if confirmed {
            proceedToTermination()
        } else {
            pendingRequests.removeAll(where: isSelfRemoval)
            phase = .browsing
            if !pendingRequests.isEmpty { proceedToTermination() }
        }
    }

    private func isSelfRemoval(_ request: ApplicationRemovalRequest) -> Bool {
        guard let app = request.application else { return false }
        return PathSafety.lexicalPath(app.path) == PathSafety.lexicalPath(Bundle.main.bundleURL.path)
            || entries.first { $0.item.path == app.path }?.isThisApplication == true
    }

    /// Replaces the entries without loading (previews and tests).
    func replaceEntries(_ newEntries: [ApplicationEntry]) {
        loadTask?.cancel()
        entries = newEntries
        loadedInventoryIDs = newEntries.map(\.id)
        entriesRevision += 1
    }

    /// Replaces the leftovers without scanning (previews and tests); all selected, as a scan leaves them.
    func replaceLeftovers(_ groups: [LeftoverGroup]) {
        leftoverTask?.cancel()
        leftovers = groups
        leftoverSelection = Set(groups.flatMap(\.resources).map(\.id))
        leftoversRevision += 1
    }

    func buildRequests() -> [ApplicationRemovalRequest] {
        // D218: another category may have preselected leftovers. The Other
        // Locations action must never bring those resources along.
        if category == .otherLocations {
            return selectedOtherApplicationCopies.map { app in
                ApplicationRemovalRequest(title: app.name, bundleIdentifier: app.bundleIdentifier,
                    purpose: .bundleOnly, application: app, resources: [])
            }
        }
        var requests: [ApplicationRemovalRequest] = []
        // D212: a path goes in one request only, so no later request finds it
        // already moved and reports it as not moved.
        var claimed = Set<String>()
        func unclaimed(_ resources: [ApplicationResource]) -> [ApplicationResource] {
            resources.filter { claimed.insert($0.id).inserted }
        }
        for entry in entries {
            let selected = selection[entry.id] ?? []
            guard !selected.isEmpty else { continue }
            let includesBundle = selected.contains(entry.bundleResourceID)
            let resources = unclaimed((entry.resources ?? []).filter { selected.contains($0.id) && $0.evidence != .bundle && $0.isRemovable })
            guard includesBundle || !resources.isEmpty else { continue }
            requests.append(ApplicationRemovalRequest(
                title: entry.item.name, bundleIdentifier: entry.item.bundleIdentifier,
                purpose: includesBundle ? .uninstall : .reset,
                application: entry.item, resources: resources))
        }
        for app in otherApplications.groups.flatMap(\.copies) where otherApplicationSelection.contains(app.path) {
            guard claimed.insert(app.path).inserted else { continue }
            requests.append(ApplicationRemovalRequest(title: app.name, bundleIdentifier: app.bundleIdentifier,
                purpose: .bundleOnly, application: app, resources: []))
        }
        for group in leftovers {
            let resources = unclaimed(group.resources.filter { leftoverSelection.contains($0.id) && $0.isRemovable })
            guard !resources.isEmpty else { continue }
            let trashed = trashedApplications.contains { $0.bundleIdentifier == group.bundleIdentifier }
            requests.append(ApplicationRemovalRequest(title: group.displayName, bundleIdentifier: group.bundleIdentifier,
                purpose: trashed ? .trashedApplication : .leftovers, application: nil, resources: resources))
        }
        let installerResources = unclaimed(installers.filter { installerSelection.contains($0.id) }.map(\.resource))
        if !installerResources.isEmpty {
            requests.append(ApplicationRemovalRequest(title: L10n.text("安装器", "Installers"), bundleIdentifier: "",
                purpose: .installers, application: nil, resources: installerResources))
        }
        let pluginResources = unclaimed(audioPlugins.filter { pluginSelection.contains($0.id) && $0.resource.isRemovable }.map(\.resource))
        if !pluginResources.isEmpty {
            requests.append(ApplicationRemovalRequest(title: L10n.text("音频插件", "Audio Plugins"), bundleIdentifier: "",
                purpose: .installers, application: nil, resources: pluginResources))
        }
        return requests
    }

    private var selectedOtherApplicationCopies: [InstalledAppItem] {
        otherApplications.groups.flatMap(\.copies).filter { otherApplicationSelection.contains($0.path) }
    }

    /// CleanMyMac `ApplicationsTerminator`: running apps are listed before
    /// anything moves.
    private func proceedToTermination() {
        runningApplications = pendingRequests.compactMap { request in
            guard let app = request.application,
                  ApplicationTerminator.isRunning(path: app.path, bundleIdentifier: app.bundleIdentifier) else { return nil }
            return RunningApplication(id: app.id, title: app.name, path: app.path, bundleIdentifier: app.bundleIdentifier, state: .running)
        }
        if runningApplications.isEmpty {
            startRemoval()
        } else {
            phase = .terminating
        }
    }

    func quit(_ id: String, force: Bool) {
        guard let index = runningApplications.firstIndex(where: { $0.id == id }) else { return }
        let target = runningApplications[index]
        runningApplications[index].state = .quitting
        Task { [weak self] in
            let outcome = await ApplicationTerminator.quit(path: target.path, bundleIdentifier: target.bundleIdentifier, force: force)
            guard let self, let current = runningApplications.firstIndex(where: { $0.id == id }) else { return }
            runningApplications[current].state = outcome == .quit ? .quit : (outcome == .cannotQuit ? .cannotQuit : .running)
            continueIfTerminationResolved()
        }
    }

    func ignoreRunning(_ id: String) {
        guard let index = runningApplications.firstIndex(where: { $0.id == id }) else { return }
        runningApplications[index].state = .ignored
        continueIfTerminationResolved()
    }

    func quitAll() {
        for app in runningApplications where app.state == .running || app.state == .cannotQuit {
            quit(app.id, force: false)
        }
    }

    /// “Ignore and Continue”: apps still running are skipped (their items
    /// stay, reported as “Skipped (the app is running)”, as D93 words it).
    func ignoreAllAndContinue() {
        for index in runningApplications.indices where runningApplications[index].state != .quit {
            runningApplications[index].state = .ignored
        }
        continueIfTerminationResolved()
    }

    func cancelTermination() {
        guard phase == .terminating else { return }
        runningApplications = []
        pendingRequests = []
        phase = .browsing
    }

    private func continueIfTerminationResolved() {
        guard phase == .terminating,
              runningApplications.allSatisfy({ $0.state == .quit || $0.state == .ignored }) else { return }
        startRemoval()
    }

    private func startRemoval() {
        guard let store else { return }
        let requests = pendingRequests
        pendingRequests = []
        outcomes = []
        startFailure = nil
        phase = .removing(current: requests.first?.title ?? "", index: 0, total: requests.count)
        let coordinator = store.heavyWorkCoordinator
        let service = removal
        let trashed = trashedApplications
        let ownPath = PathSafety.lexicalPath(Bundle.main.bundleURL.path)
        let selfRequestID = requests.first { $0.application.map { PathSafety.lexicalPath($0.path) } == ownPath }?.id
        let identifiers = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0.bundleIdentifier) })
        removalTask = Task { [weak self] in
            var collected: [ApplicationRemovalOutcome] = []
            do {
                collected = try await coordinator.withLease(owner: .cleanup) { lease in
                    var results: [ApplicationRemovalOutcome] = []
                    for (index, request) in requests.enumerated() {
                        if Task.isCancelled { break }
                        await MainActor.run {
                            self?.phase = .removing(current: request.title, index: index, total: requests.count)
                        }
                        let outcome = await service.run(request, coordinator: coordinator, lease: lease)
                        if let report = outcome.report {
                            _ = await CleanReportStore.recordDetached(report)
                        }
                        results.append(outcome)
                    }
                    return results
                }
            } catch {
                // Only taking the lease throws, before the first item: nothing
                // ran, so there is nothing to log and the selection stays.
                guard let self else { return }
                startFailure = error.localizedDescription
                phase = .finished
                return
            }
            guard let self else { return }
            outcomes = collected
            phase = .finished
            let handled = trashed.filter { app in
                collected.contains { outcome in
                    outcome.purpose == .trashedApplication && outcome.failedCount == 0
                        && identifiers[outcome.id] == app.bundleIdentifier
                }
            }
            if !handled.isEmpty { AppLifecycleReminderCenter.shared.markHandled(handled) }
            if collected.contains(where: { $0.purpose == .trashedApplication }) { trashedApplications = [] }
            selection = [:]
            leftoverSelection = []
            installerSelection = []
            pluginSelection = []
            otherApplicationSelection = []
            if collected.contains(where: { $0.applicationRemoved }) {
                needsInventoryRefresh = true
                let removedPaths = Set(requests.filter { request in
                    collected.contains { $0.id == request.id && $0.applicationRemoved }
                }.compactMap { $0.application?.path })
                entries.removeAll { entry in
                    removedPaths.contains(entry.item.path)
                }
                completeOtherApplications.groups = completeOtherApplications.groups.compactMap { group in
                    let copies = group.copies.filter { !removedPaths.contains($0.path) }
                    return copies.isEmpty ? nil : OtherApplicationGroup(id: group.id, copies: copies)
                }
                applyOtherApplications(completeOtherApplications)
            }
            scanLeftoversAndInstallers()
            // CleanMyMac: "It will be quit and completely removed".
            if let selfRequestID, collected.contains(where: { $0.id == selfRequestID && $0.applicationRemoved }) {
                NSApp.terminate(nil)
            }
        }
    }

    /// “Manage More Items”.
    func returnToBrowsing() {
        guard phase == .finished else { return }
        outcomes = []
        startFailure = nil
        phase = .browsing
        if needsInventoryRefresh, let store, store.canRefreshInstalledApps {
            needsInventoryRefresh = false
            keepsListAfterScan = true
            store.refreshInstalledApps()
        }
    }

    // MARK: Completion texts (CleanMyMac's done page; our own wording, D154)

    var completionSucceeded: Bool { startFailure == nil && outcomes.allSatisfy(\.succeeded) }

    var completionTitle: String {
        let purposes = Set(outcomes.map(\.purpose))
        if startFailure != nil { return L10n.text("没能开始", "Could Not Start") }
        if !completionSucceeded { return L10n.text("有些文件没能移走", "Some files were not removed") }
        if purposes.isSubset(of: [.leftovers, .installers, .trashedApplication]) {
            return L10n.text("残留已清理", "Leftovers removed")
        }
        return L10n.text("卸载完成", "Uninstall complete")
    }

    var completionDescription: String {
        let removedApps = outcomes.filter(\.applicationRemoved).count
        let leftoverGroups = outcomes.filter { [.leftovers, .trashedApplication].contains($0.purpose) && $0.removedCount > 0 }.count
        let bytes = ByteFormat.storageString(outcomes.reduce(0) { $0 + $1.removedBytes })
        if let startFailure {
            return startFailure + L10n.text("没有移动任何文件，选中的项目都还在。", " Nothing was moved, and your selection is kept.")
        }
        if !completionSucceeded {
            return L10n.text("可能有应用还在用这些文件。退出相关应用后再试一次；没移走的都还在原处，日志里有原因。",
                             "An app may still be using them. Quit the related apps and try again; anything not moved is still in place, and the log says why.")
        }
        if removedApps > 0 {
            return L10n.text("\(ByteFormat.count(removedApps)) 个应用已卸载 · 移入废纸篓 \(bytes)",
                             "\(ByteFormat.count(removedApps)) app\(removedApps == 1 ? "" : "s") uninstalled · \(bytes) moved to the Trash")
        }
        if leftoverGroups > 0 {
            return L10n.text("\(ByteFormat.count(leftoverGroups)) 个应用的残留已移除 · 移入废纸篓 \(bytes)",
                             "Leftovers of \(ByteFormat.count(leftoverGroups)) app\(leftoverGroups == 1 ? "" : "s") removed · \(bytes) moved to the Trash")
        }
        return L10n.text("已移入废纸篓 \(bytes)，可从“操作记录”恢复", "\(bytes) moved to the Trash; restorable from Operation History")
    }

    /// The done page's corner note: the Trash only when something went there.
    var completionFootnote: String {
        outcomes.contains { $0.removedCount > 0 }
            ? L10n.text("文件在废纸篓里 · 可在“操作记录”恢复", "Files are in the Trash · Restorable from Operation History")
            : L10n.text("没有移动任何文件", "Nothing was moved")
    }
}

/// Off-main loading of one application's profile, classification and items.
struct ApplicationEntryLoad: Sendable {
    let id: String
    let profile: ApplicationProfile?
    let classification: ApplicationClassification
    let resources: [ApplicationResource]

    static func load(_ item: InstalledAppItem, installedIdentifiers: Set<String>, installedPaths: Set<String>) -> ApplicationEntryLoad {
        let url = URL(fileURLWithPath: item.path, isDirectory: true)
        let profile = ApplicationProfileReader.profile(at: url)
        let classification = ApplicationClassification(
            store: ApplicationClassification.store(for: item.path, bundleIdentifier: item.bundleIdentifier),
            vendor: ApplicationVendor.of(bundleIdentifier: item.bundleIdentifier, teamIdentifier: profile?.teamIdentifier),
            isUnused: ApplicationClassification.isUnused(lastUsed: item.lastUsedAt, installed: item.modifiedAt),
            isThirtyTwoBitOnly: ApplicationClassification.isThirtyTwoBitOnly(url),
            suspiciousReason: ApplicationClassification.suspiciousReason(for: url)
        )
        var resources: [ApplicationResource] = []
        if let profile {
            let finder = ApplicationResourceFinder(
                installedBundleIdentifiers: installedIdentifiers.subtracting([profile.bundleIdentifier]),
                installedApplicationPaths: installedPaths.subtracting([PathSafety.lexicalPath(item.path)])
            )
            resources = finder.resources(for: profile)
        }
        return ApplicationEntryLoad(id: item.id, profile: profile, classification: classification, resources: resources)
    }
}
