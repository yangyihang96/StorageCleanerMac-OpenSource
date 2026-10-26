import AppKit
import Combine
import Foundation

struct RecentItemsApplication {
    let name: String
    let icon: NSImage?
    let isRunning: Bool

    @MainActor
    static func resolve(_ bundleID: String) -> Self {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let displayName = url.map { FileManager.default.displayName(atPath: $0.path) }
        let name = displayName.map { $0.hasSuffix(".app") ? String($0.dropLast(4)) : $0 } ?? bundleID
        return Self(name: name, icon: url.map { NSWorkspace.shared.icon(forFile: $0.path) },
                    isRunning: NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID })
    }
}

@MainActor
final class RecentItemsStore: ObservableObject {
    @Published private(set) var snapshot: RecentItemsSnapshot?
    @Published private(set) var selectedIDs: Set<String> = []
    @Published private(set) var confirmation: [RecentItemsList]?
    @Published private(set) var result: RecentItemsCleanupResult?
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var error: String?
    @Published private(set) var applications: [String: RecentItemsApplication] = [:]
    private let environment: RecentItemsCleanupEnvironment
    private let resolveApplication: @MainActor (String) -> RecentItemsApplication

    init(environment: RecentItemsCleanupEnvironment = .init(scanner: .init()),
         snapshot: RecentItemsSnapshot? = nil,
         resolveApplication: @escaping @MainActor (String) -> RecentItemsApplication = RecentItemsApplication.resolve) {
        self.environment = environment; self.snapshot = snapshot; self.resolveApplication = resolveApplication
        updateApplications()
    }

    var selectedLists: [RecentItemsList] { (snapshot?.lists ?? []).filter { selectedIDs.contains($0.id) } }

    func scan() async {
        guard !isScanning, !isCleaning else { return }
        isScanning = true
        let scanner = environment.scanner
        snapshot = await Task.detached(priority: .utility) { scanner.scan() }.value
        selectedIDs = []; confirmation = nil; result = nil; error = nil
        updateApplications()
        isScanning = false
    }

    /// Report §4 item 12 (Start Over): Protection goes back to its landing
    /// page with nothing read; the results page reads the lists again when
    /// it next appears. Not while a scan or a cleanup runs.
    func startOver() {
        guard !isScanning, !isCleaning else { return }
        snapshot = nil; selectedIDs = []; confirmation = nil; result = nil; error = nil
        updateApplications()
    }

    func setSelected(_ selected: Bool, listID: String) {
        guard !isCleaning, confirmation == nil, snapshot?.lists.contains(where: { $0.id == listID }) == true else { return }
        if selected { selectedIDs.insert(listID) } else { selectedIDs.remove(listID) }
    }

    func beginReview(confirm: Bool) {
        guard !isCleaning else { return }
        result = nil; error = nil; confirmation = nil
        if confirm { prepareConfirmation() }
    }

    func prepareConfirmation() {
        guard !isCleaning else { return }
        updateApplications()
        confirmation = selectedLists
    }

    func editSelection() { if !isCleaning { confirmation = nil; error = nil } }

    func name(for list: RecentItemsList) -> String {
        if let bundleID = list.bundleIdentifier { return applications[bundleID]?.name ?? bundleID }
        return RecentItemsPresentation.title(for: list.category)
    }

    var confirmationFacts: OperationConfirmationFacts {
        let lists = confirmation ?? []
        return OperationConfirmationFacts(
            surface: .safeCleanup, actions: [.moveToTrash],
            items: lists.map { .init(id: $0.id, title: name(for: $0), path: $0.url.path, bytes: nil,
                                    detail: RecentItemsPresentation.count($0.entryCount)) },
            localBytes: nil,
            appsToQuit: Array(Set(lists.compactMap { list in
                guard let bundleID = list.bundleIdentifier, let app = applications[bundleID], app.isRunning else { return nil }
                return app.name
            })).sorted(),
            recovery: [.trashAndOperationHistory], permission: .notRequired)
    }

    func clean(confirmed: Bool, coordinator: HeavyWorkCoordinator) async {
        guard confirmed, let confirmation, !confirmation.isEmpty, !isCleaning else { return }
        isCleaning = true; error = nil
        defer { isCleaning = false }
        do {
            result = try await RecentItemsCleanupService.clean(selected: confirmation, confirmed: confirmed,
                                                              environment: environment, coordinator: coordinator)
            if let result {
                snapshot = result.snapshot; selectedIDs = []; self.confirmation = nil
                updateApplications()
            }
        } catch {
            self.error = L10n.text("未能开始这次清理，列表未移走；请等待其他操作结束后再试。",
                                   "Cleanup could not start; lists were not moved. Wait for other operations to finish and try again.")
        }
    }

    private func updateApplications() {
        applications = Dictionary(uniqueKeysWithValues: Set((snapshot?.lists ?? []).compactMap(\.bundleIdentifier))
            .map { ($0, resolveApplication($0)) })
    }
}
