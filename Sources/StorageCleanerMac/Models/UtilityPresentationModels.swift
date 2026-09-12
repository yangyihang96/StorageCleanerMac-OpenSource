struct EnergyImpactListPresentation: Equatable {
    let apps: [EnergyImpactApp]
    let maxEstimatedEnergyWh: Double
    let maxCurrentPowerWatts: Double
    let maxAveragePowerWatts: Double
    let lastID: String?
}

enum EnergyImpactListPresenter {
    static func presentation(
        apps: [EnergyImpactApp],
        query: String,
        sortMode: EnergyImpactSortMode
    ) -> EnergyImpactListPresentation {
        let term = query.trimmed
        let filtered = apps.filter { app in
            app.isApplication
                && (term.isEmpty
                    || app.name.localizedCaseInsensitiveContains(term)
                    || app.sourceTitle.localizedCaseInsensitiveContains(term)
                    || app.path.localizedCaseInsensitiveContains(term))
        }
        let sorted = sortMode.sorted(filtered)
        let maxima = sorted.reduce(
            into: (
                estimatedEnergyWh: 0.0,
                currentPowerWatts: 0.0,
                averagePowerWatts: 0.0
            )
        ) { maxima, app in
            maxima.estimatedEnergyWh = max(maxima.estimatedEnergyWh, app.estimatedEnergyWh)
            maxima.currentPowerWatts = max(maxima.currentPowerWatts, app.currentPowerWatts)
            maxima.averagePowerWatts = max(maxima.averagePowerWatts, app.averagePowerWatts)
        }
        return EnergyImpactListPresentation(
            apps: sorted,
            maxEstimatedEnergyWh: max(maxima.estimatedEnergyWh, 0.001),
            maxCurrentPowerWatts: max(maxima.currentPowerWatts, 0.001),
            maxAveragePowerWatts: max(maxima.averagePowerWatts, 0.001),
            lastID: sorted.last?.id
        )
    }
}

struct AppUninstallListPresentation {
    typealias SourcePresenter = (
        [InstalledAppItem],
        String,
        AppUninstallListFilter,
        AppUninstallSortMode
    ) -> [InstalledAppItem]

    let apps: [InstalledAppItem]
    let count: Int
    let lastID: String?
    let totalFootprintBytes: Int64
    private let filterCounts: [AppUninstallListFilter: Int]

    private init(
        apps: [InstalledAppItem],
        count: Int,
        lastID: String?,
        totalFootprintBytes: Int64,
        filterCounts: [AppUninstallListFilter: Int]
    ) {
        self.apps = apps
        self.count = count
        self.lastID = lastID
        self.totalFootprintBytes = totalFootprintBytes
        self.filterCounts = filterCounts
    }

    func count(for filter: AppUninstallListFilter) -> Int {
        filterCounts[filter] ?? 0
    }

    static func make(
        apps: [InstalledAppItem],
        query: String,
        filter: AppUninstallListFilter,
        sortMode: AppUninstallSortMode,
        sourcePresenter: SourcePresenter = { apps, query, filter, sortMode in
            AppUninstallListPresenter.visibleApps(
                from: apps,
                query: query,
                filter: filter,
                sortMode: sortMode
            )
        }
    ) -> Self {
        let visibleApps = sourcePresenter(apps, query, filter, sortMode)
        var filterCounts = [AppUninstallListFilter: Int]()
        for app in apps {
            for candidateFilter in AppUninstallListFilter.allCases where candidateFilter.includes(app) {
                filterCounts[candidateFilter, default: 0] += 1
            }
        }

        return Self(
            apps: visibleApps,
            count: visibleApps.count,
            lastID: visibleApps.last?.id,
            totalFootprintBytes: visibleApps.reduce(0) { $0 + $1.totalFootprintBytes },
            filterCounts: filterCounts
        )
    }
}

enum AppUpdateListFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case updateAvailable
    case automatic
    case websiteDownload
    case websiteManual
    case applicationInternal
    case appStore
    case homebrew
    case sparkle
    case upToDate
    case sourceUnconfirmed
    case failed
    case ignored
    case systemManaged

    var id: String { rawValue }

    func includes(_ app: AppUpdateItem) -> Bool {
        let isSystemManaged = SystemApplicationPolicy.isSystemManaged(app)
            || app.primaryUpdateProvider == .systemManaged
        return switch self {
        case .all:
            !isSystemManaged
        case .updateAvailable:
            !isSystemManaged
                && app.updateStatus != .ignored
                && app.effectiveVersionCheckState == .updateAvailable
                && app.availableVersion.map { app.installedVersion < $0 } == true
        case .automatic:
            !isSystemManaged
                && app.effectiveUpdateCapability == .automatic
                && app.canAutomaticallyUpdate
                && app.availableVersion.map { app.installedVersion < $0 } == true
        case .websiteDownload:
            !isSystemManaged && app.hasConfirmedOfficialWebsiteSource
        case .websiteManual:
            !isSystemManaged && app.primaryUpdateProvider == .manual
        case .applicationInternal:
            !isSystemManaged
                && (app.primaryUpdateProvider == .sparkle
                    || app.primaryUpdateProvider == .vendorUpdater)
        case .appStore:
            !isSystemManaged && app.primaryUpdateProvider == .macAppStore
        case .homebrew:
            !isSystemManaged && app.primaryUpdateProvider == .homebrew
        case .sparkle:
            // Sparkle is the implementation behind the single "in-app
            // update" provider category, not a second public category.
            false
        case .upToDate:
            !isSystemManaged && app.effectiveVersionCheckState == .upToDate
        case .sourceUnconfirmed:
            !isSystemManaged
                && (app.effectiveSourceResolutionState == .unresolved
                    || app.effectiveSourceResolutionState == .needsConfirmation)
        case .failed:
            !isSystemManaged
                && (app.effectiveSourceResolutionState == .failed
                    || app.effectiveVersionCheckState == .failed
                    || app.updateStatus == .failed)
        case .ignored:
            !isSystemManaged && app.updateStatus == .ignored
        case .systemManaged:
            isSystemManaged
        }
    }
}

enum AppUpdateListPresenter {
    static func visibleApps(
        from apps: [AppUpdateItem],
        query: String,
        filter: AppUpdateListFilter
    ) -> [AppUpdateItem] {
        let methodApps = apps.filter(filter.includes)
        let normalizedQuery = query.trimmed
        guard !normalizedQuery.isEmpty else { return methodApps }

        return methodApps.filter { app in
            app.name.localizedCaseInsensitiveContains(normalizedQuery)
                || app.bundleIdentifier.localizedCaseInsensitiveContains(normalizedQuery)
                || app.versionDisplay.localizedCaseInsensitiveContains(normalizedQuery)
                || app.currentVersionDisplay.localizedCaseInsensitiveContains(normalizedQuery)
                || app.latestVersionDisplay.localizedCaseInsensitiveContains(normalizedQuery)
                || app.source.localizedCaseInsensitiveContains(normalizedQuery)
                || (app.caskToken?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || (app.officialDomain?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || (app.signingTeamIdentifier?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                || app.path.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }
}

struct AppUpdateListPresentation {
    typealias SourcePresenter = (
        [AppUpdateItem],
        String,
        AppUpdateListFilter
    ) -> [AppUpdateItem]

    let apps: [AppUpdateItem]
    let count: Int
    let lastID: String?
    private let filterCounts: [AppUpdateListFilter: Int]

    private init(
        apps: [AppUpdateItem],
        count: Int,
        lastID: String?,
        filterCounts: [AppUpdateListFilter: Int]
    ) {
        self.apps = apps
        self.count = count
        self.lastID = lastID
        self.filterCounts = filterCounts
    }

    func count(for filter: AppUpdateListFilter) -> Int {
        filterCounts[filter] ?? 0
    }

    static func make(
        apps: [AppUpdateItem],
        query: String,
        filter: AppUpdateListFilter,
        sourcePresenter: SourcePresenter = { apps, query, filter in
            AppUpdateListPresenter.visibleApps(
                from: apps,
                query: query,
                filter: filter
            )
        }
    ) -> Self {
        let visibleApps = sourcePresenter(apps, query, filter)
        var filterCounts = [AppUpdateListFilter: Int]()
        for app in apps {
            for candidateFilter in AppUpdateListFilter.allCases where candidateFilter.includes(app) {
                filterCounts[candidateFilter, default: 0] += 1
            }
        }

        return Self(
            apps: visibleApps,
            count: visibleApps.count,
            lastID: visibleApps.last?.id,
            filterCounts: filterCounts
        )
    }
}
