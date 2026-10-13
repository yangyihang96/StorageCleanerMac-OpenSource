import Combine
import Foundation

@MainActor
final class BrowserPrivacyDataStore: ObservableObject {
    struct Availability: Identifiable {
        let browser: String
        let type: BrowserPrivacyDataType
        let reason: String
        var id: String { browser + type.rawValue }
    }
    @Published private(set) var availability: [Availability] = []
    @Published private(set) var groups: [BrowserPrivacyDataGroup] = []
    @Published var selection: Set<String> = []
    @Published private(set) var keepingSites: Set<String>
    @Published private(set) var isWorking = false
    @Published private(set) var messages: [String] = []
    private let defaults: UserDefaults
    private let service: BrowserPrivacyDataService
    private static let preferenceKey = "browser-privacy.kept-sites.v1"

    init(service: BrowserPrivacyDataService = .init(), defaults: UserDefaults = .standard) {
        self.service = service; self.defaults = defaults
        keepingSites = Set((defaults.stringArray(forKey: Self.preferenceKey) ?? []).map(BrowserPrivacyDataGroup.normalizedSite))
    }
    func keep(_ site: String) {
        let normalized = BrowserPrivacyDataGroup.normalizedSite(site)
        guard !normalized.isEmpty else { return }
        keepingSites.insert(normalized)
        selection.subtract(groups.filter { $0.isProtected(by: keepingSites) }.map(\.id))
        defaults.set(keepingSites.sorted(), forKey: Self.preferenceKey)
    }
    func unkeep(_ site: String) {
        keepingSites.remove(BrowserPrivacyDataGroup.normalizedSite(site))
        defaults.set(keepingSites.sorted(), forKey: Self.preferenceKey)
    }
    func canSelect(_ group: BrowserPrivacyDataGroup) -> Bool {
        group.writable && !group.isProtected(by: keepingSites)
    }
    var selected: [BrowserPrivacyDataGroup] {
        groups.filter { selection.contains($0.id) && canSelect($0) }
    }
    func scan() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        groups = []; selection = []; messages = []
        let service = self.service
        let result = await Task.detached(priority: .utility) {
            let profiles = await service.discover()
            var groups: [BrowserPrivacyDataGroup] = []
            var messages: [String] = []
            for profile in profiles {
                for contract in BrowserPrivacyDataContract.allCases where contract.engine == profile.browser.engine {
                    let url = profile.historyDatabaseURL.deletingLastPathComponent().appendingPathComponent(contract.relativePath)
                    // An absent database is distinct from a failed read.
                    guard FileManager.default.fileExists(atPath: url.path) else { continue }
                    do { groups += try await service.scan(profile: profile, contract: contract) }
                    catch {
                        messages.append(profile.browser.displayName + " · " + contract.type.title + ": " +
                            BrowserPrivacyDataFailure.describe(error))
                    }
                }
            }
            if profiles.isEmpty { messages.append(L10n.text("未发现可读取的浏览器配置文件。", "No readable browser profiles were found.")) }
            let browsers = Dictionary(grouping: profiles, by: { $0.browser.id }).values.compactMap { $0.first?.browser }
            let availability = browsers.flatMap { browser in
                BrowserPrivacyDataType.allCases.compactMap { type -> Availability? in
                    let matched = groups.filter { $0.profile.browser.id == browser.id && $0.contract.type == type }
                    if matched.contains(where: \.writable) { return nil }
                    let adapter = BrowserPrivacyDataContract.allCases.first { $0.engine == browser.engine && $0.type == type }
                    let reason: String
                    if let first = matched.first { reason = first.unavailableReason }
                    else if let adapter, !adapter.permitsDeletion { reason = adapter.unavailableReason }
                    else if adapter != nil { reason = L10n.text("未发现此类型的可读数据库；格式、权限与身份需要通过核验才能开放删除。", "No readable database was found for this type. Format, access and identity must pass verification before deletion is available.") }
                    else if type == .sessions { reason = type.limitation }
                    else { reason = L10n.text("此浏览器与类型尚无安全的删除／恢复适配器。", "This browser and type do not yet have a verified deletion and restore adapter.") }
                    return Availability(browser: browser.displayName, type: type, reason: reason)
                }
            }
            return (groups, messages, availability)
        }.value
        applyScanResults(result.0)
        messages = result.1
        availability = result.2
    }
    func applyScanResults(_ results: [BrowserPrivacyDataGroup]) {
        groups = results
        selection = [] // Reading never selects destructive actions.

    }
    func deleteSelected() async {
        guard !isWorking, !selected.isEmpty else { return }
        let selected = self.selected
        let sites = keepingSites
        isWorking = true
        defer { isWorking = false }
        messages = []
        let service = self.service
        let result = await Task.detached(priority: .utility) {
            do {
                let count = try await service.deleteRun(selected, keeping: sites)
                return [L10n.text("已回读确认删除 \(count) 条，可在操作记录中恢复。", "Confirmed deletion of \(count) records; restore from operation records.")]
            } catch { return [BrowserPrivacyDataFailure.describe(error)] }
        }.value
        messages = result
        selection = []
        groups = [] // Never leave stale write locators available after a mutation.
    }
}
