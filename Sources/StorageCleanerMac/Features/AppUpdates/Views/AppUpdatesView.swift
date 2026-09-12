import AppKit
import SwiftUI

struct AppUpdaterView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: ScanStore

    @State private var searchText = ""
    @State private var catalogFilter: AppUpdateCatalogFilter = .all
    @State private var catalogSort: AppUpdateCatalogSort = .recommended
    @State private var selectedApplicationID: String?
    @State private var isShowingSessionLog = false

    var body: some View {
        VStack(spacing: 0) {
#if DEBUG
            if store.isDebugAppUpdatePresentationFixtureActive {
                Label(
                    L10n.text(
                        "界面演示 · 不会扫描或安装",
                        "UI Demo · No Scanning or Installation"
                    ),
                    systemImage: "eye.fill"
                )
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background(AppDesignTokens.Palette.warning.opacity(0.11))
                .accessibilityLabel(
                    L10n.text(
                        "界面演示，不会扫描或安装应用",
                        "UI demo; applications will not be scanned or installed"
                    )
                )
            }
#endif

            VStack(spacing: 0) {
                if shouldShowOrchestratorStatusBanner {
                    AppUpdateOrchestratorStatusBanner(
                        state: store.appUpdateOrchestratorState,
                        queue: store.appUpdateQueueSnapshot,
                        progress: store.appUpdateProgress,
                        canCancel: canCancelOrchestrator,
                        onCancel: cancelOrchestrator
                    )
                    .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
                    .padding(.top, AppDesignTokens.Spacing.compact)
                }

                if isShowingSessionLog {
                    AppUpdateSessionLogPage(
                        state: store.appUpdatePresentationState,
                        onRetry: store.retryAppUpdates,
                        onBack: { isShowingSessionLog = false }
                    )
                } else {
                    presentationContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.18),
            value: store.appUpdatePresentationState.phase
        )
    }

    @ViewBuilder
    private var presentationContent: some View {
        switch store.appUpdatePresentationState {
        case let .idle(lastSummary):
            AppUpdateIdlePage(
                lastSummary: lastSummary,
                canScan: store.canRefreshAppUpdates,
                onScan: store.refreshAppUpdates,
                onManage: store.showAppUpdateManager
            )
        case let .scanning(progress):
            AppUpdateScanningPage(
                progress: progress,
                canCancel: store.isLoadingAppUpdates,
                onCancel: store.cancelAppUpdateScan
            )
        case let .scanSummary(summary):
            AppUpdateScanSummaryPage(
                summary: summary,
                warnings: store.appUpdateScanWarnings,
                canUpdate: store.canRequestOneClickAppUpdates,
                onUpdateAll: {
                    store.requestSelectedAppUpdates(
                        applicationIDs: Set(summary.batchEligibleApps.map(\.id))
                    )
                },
                onManage: store.showAppUpdateManager,
                onRescan: store.refreshAppUpdates
            )
        case let .managing(snapshot):
            AppUpdateManagerPage(
                snapshot: snapshot,
                searchText: $searchText,
                filter: $catalogFilter,
                sort: $catalogSort,
                selectedApplicationID: $selectedApplicationID,
                batchState: store.appUpdateOrchestratorState,
                canRunActions: store.canRequestOneClickAppUpdates,
                onShowSummary: store.showAppUpdateScanSummary,
                onRescan: store.refreshAppUpdates,
                onUpdateAutomatic: { ids in
                    store.requestSelectedAppUpdates(applicationIDs: ids)
                },
                onAutomaticUpdate: { app in store.requestAppUpdate(app) },
                onAppStoreUpdate: { app in store.requestAppStoreUpdate(app) },
                onOpenUpdateEntry: { app in store.openUpdateEntry(app) }
            )
        case let .preparingUpdate(plan):
            AppUpdatePreparingPage(
                plan: plan,
                onCancel: store.cancelOneClickAppUpdates
            )
        case let .updating(snapshot):
            AppUpdateProgressPage(
                snapshot: snapshot,
                isFinalizing: false,
                onCancel: store.cancelOneClickAppUpdates,
                onShowLog: { isShowingSessionLog = true }
            )
        case let .finalizing(snapshot):
            AppUpdateProgressPage(
                snapshot: snapshot,
                isFinalizing: true,
                onCancel: {},
                onShowLog: { isShowingSessionLog = true }
            )
        case let .completed(report):
            reportPage(report: report, fallbackOutcome: .allSucceeded)
        case let .cancelled(report):
            reportPage(report: report, fallbackOutcome: .cancelled)
        case let .failed(report):
            reportPage(report: report, fallbackOutcome: .allFailed)
        }
    }

    private func reportPage(
        report: AppUpdateReport?,
        fallbackOutcome: AppUpdateReportOutcome
    ) -> some View {
        AppUpdateReportPage(
            report: report,
            fallbackOutcome: fallbackOutcome,
            onRetry: store.retryAppUpdates,
            onShowLog: { isShowingSessionLog = true },
            onManage: store.showAppUpdateManager,
            onDone: store.showAppUpdateScanSummary
        )
    }

    private var canCancelOrchestrator: Bool {
        switch store.appUpdateOrchestratorState {
        case .scanning:
            store.isLoadingAppUpdates
        case .preparing, .downloading, .waitingForApplications, .installing, .verifying:
            store.isRunningOneClickUpdate
        case .idle, .completed, .partialFailure, .failed, .cancelled:
            false
        }
    }

    private var shouldShowOrchestratorStatusBanner: Bool {
        switch store.appUpdateOrchestratorState {
        case .preparing, .downloading, .waitingForApplications, .installing, .verifying:
            true
        case .idle, .scanning, .completed, .partialFailure, .failed, .cancelled:
            false
        }
    }

    private var cancelOrchestrator: () -> Void {
        switch store.appUpdateOrchestratorState {
        case .scanning:
            store.cancelAppUpdateScan
        case .preparing, .downloading, .waitingForApplications, .installing, .verifying:
            store.cancelOneClickAppUpdates
        case .idle, .completed, .partialFailure, .failed, .cancelled:
            {}
        }
    }
}

private struct AppUpdateOrchestratorStatusBanner: View {
    @Environment(\.moduleTheme) private var theme

    let state: UpdateOrchestratorState
    let queue: ApplicationUpdateQueueSnapshot?
    let progress: AppUpdateProgress?
    let canCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: state.systemImage)
                .foregroundStyle(theme.accent)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(theme.primaryText)
                Text(detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if canCancel {
                AppButton(
                    title: L10n.text("停止", "Stop"),
                    systemImage: "stop.circle",
                    kind: .secondary,
                    tint: theme.accent,
                    action: onCancel
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.text("更新批次状态", "Update batch status"))
        .accessibilityValue("\(state.title)：\(detail)")
    }

    private var detail: String {
        switch state {
        case .scanning:
            progress?.detail ?? L10n.text(
                "正在读取应用与更新来源",
                "Reading applications and update sources"
            )
        case .preparing:
            L10n.text(
                "正在冻结计划并执行安全复核",
                "Freezing the plan and running safety checks"
            )
        case .downloading, .waitingForApplications, .installing, .verifying:
            queue?.tasks.first(where: { !$0.state.isTerminal })?.detail
                ?? L10n.text("正在处理更新队列", "Processing the update queue")
        case .completed, .partialFailure, .failed, .cancelled:
            terminalCounts
        case .idle:
            ""
        }
    }

    private var terminalCounts: String {
        guard let queue else {
            return L10n.text("没有可显示的批次项目", "No batch items to display")
        }
        let completed = queue.tasks.count { $0.state == .completed }
        let failed = queue.tasks.count { $0.state == .failed }
        let cancelled = queue.tasks.count { $0.state == .cancelled }
        return L10n.text(
            "\(completed) 个成功，\(failed) 个失败，\(cancelled) 个取消",
            "\(completed) succeeded, \(failed) failed, \(cancelled) cancelled"
        )
    }
}

private struct AppUpdateIdlePage: View {
    let lastSummary: LastAppScanSummary?
    let canScan: Bool
    let onScan: () -> Void
    let onManage: () -> Void

    var body: some View {
        HeroScanPage(
            title: ReviewFilter.updater.title,
            subtitle: ReviewFilter.updater.pageSubtitle,
            headerSystemImage: ReviewFilter.updater.systemImage,
            configurationTitle: L10n.text("上次检查", "Last Check"),
            actionTitle: L10n.text("检查更新", "Check for Updates"),
            actionDetail: "",
            actionSystemImage: "arrow.triangle.2.circlepath",
            status: status,
            isActionDisabled: !canScan,
            trustText: nil,
            showsAccessory: lastSummary != nil,
            action: onScan
        ) {
            if let lastSummary {
                AppUpdateLastScanAccessory(summary: lastSummary, onManage: onManage)
            }
        }
    }

    private var status: ScanStatusPresentation {
        guard let lastSummary else { return .idle(L10n.text("尚未检查更新", "Updates not checked")) }
        return .completed(
            L10n.text(
                "上次扫描：\(lastSummary.completedAt.formatted(date: .abbreviated, time: .shortened))",
                "Last scanned: \(lastSummary.completedAt.formatted(date: .abbreviated, time: .shortened))"
            )
        )
    }
}

private struct AppUpdateLastScanAccessory: View {
    @Environment(\.moduleTheme) private var theme

    let summary: LastAppScanSummary
    let onManage: () -> Void

    var body: some View {
        ContentPanel(cornerRadius: 12) {
            HStack(spacing: 18) {
                AppUpdateCompactMetric(
                    value: summary.automaticCount,
                    title: L10n.text("可直接更新", "Automatic")
                )
                AppUpdateCompactMetric(
                    value: summary.requiresQuitCount,
                    title: L10n.text("需先退出", "Quit First")
                )
                AppUpdateCompactMetric(
                    value: summary.requiresAuthorizationCount,
                    title: L10n.text("需要授权", "Authorization")
                )
                AppUpdateCompactMetric(
                    value: summary.manualCount,
                    title: L10n.text("需手动处理", "Manual")
                )
                AppUpdateCompactMetric(
                    value: summary.currentCount,
                    title: L10n.text("已是最新", "Current")
                )

                Divider().frame(height: 34)

                AppButton(
                    title: L10n.text("管理更新", "Manage Updates"),
                    systemImage: "list.bullet.rectangle",
                    kind: .secondary,
                    tint: theme.accent,
                    action: onManage
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: 510)
    }
}

private struct AppUpdateCompactMetric: View {
    @Environment(\.moduleTheme) private var theme

    let value: Int
    let title: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value, format: .number)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(theme.primaryText)
                .monospacedDigit()
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }
}

private struct AppUpdateScanningPage: View {
    @Environment(\.moduleTheme) private var theme

    let progress: AppScanProgressSnapshot
    let canCancel: Bool
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.15))
                    .frame(width: 108, height: 108)
                Image(systemName: "square.grid.2x2.fill")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 7) {
                Text(L10n.text("正在扫描应用", "Scanning Applications"))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(theme.primaryText)
                Text(progress.stage.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.primaryText.opacity(0.92))
                Text(progressDetail)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 480)
            }

            ContentPanel(cornerRadius: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    AppUpdateProgressIndicator(
                        fraction: progress.progressFraction,
                        completedUnitCount: progress.completedUnitCount,
                        totalUnitCount: progress.totalUnitCount
                    )

                    AppUpdateStageRail(activeStage: progress.stage)
                }
                .padding(18)
            }
            .frame(maxWidth: 560)

            AppButton(
                title: L10n.text("停止扫描", "Stop Scanning"),
                systemImage: "stop.circle",
                kind: .secondary,
                tint: theme.accent,
                isDisabled: !canCancel,
                help: L10n.text(
                    "在当前扫描器的安全边界停止；已读取的结果不会被当作完整扫描",
                    "Stop at the current scanner safety boundary; partial results are not treated as a completed scan"
                ),
                action: onCancel
            )
        }
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }

    private var progressDetail: String {
        if let name = progress.currentApplicationName?.trimmed.nonEmpty {
            return L10n.text("正在处理：\(name)", "Processing: \(name)")
        }
        return progress.stage.detail
    }
}

private struct AppUpdateProgressIndicator: View {
    @Environment(\.moduleTheme) private var theme

    let fraction: Double?
    let completedUnitCount: Int
    let totalUnitCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                    .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100))%")
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(theme.accent)
                    .accessibilityValue(L10n.text("总量正在确定", "Determining total"))
            }

            HStack {
                Text(L10n.text("扫描进度", "Scan Progress"))
                Spacer()
                Text(progressText)
                    .monospacedDigit()
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var progressText: String {
        guard let totalUnitCount, totalUnitCount > 0 else {
            return L10n.text("已处理 \(completedUnitCount)", "\(completedUnitCount) processed")
        }
        return "\(completedUnitCount) / \(totalUnitCount)"
    }
}

private struct AppUpdateStageRail: View {
    @Environment(\.moduleTheme) private var theme

    let activeStage: AppScanStage

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppScanStage.allPresentationStages, id: \.self) { stage in
                HStack(spacing: 6) {
                    Image(systemName: symbol(for: stage))
                        .foregroundStyle(color(for: stage))
                        .accessibilityHidden(true)
                    Text(stage.shortTitle)
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(color(for: stage))
                }
                .font(.system(size: 11, weight: stage == activeStage ? .semibold : .medium))
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stage.title)
                .accessibilityValue(accessibilityState(for: stage))
            }
        }
    }

    private func symbol(for stage: AppScanStage) -> String {
        if stage.presentationIndex < activeStage.presentationIndex { return "checkmark.circle.fill" }
        if stage == activeStage { return "circle.inset.filled" }
        return "circle"
    }

    private func color(for stage: AppScanStage) -> Color {
        stage.presentationIndex <= activeStage.presentationIndex
            ? theme.accent
            : .secondary.opacity(0.55)
    }

    private func accessibilityState(for stage: AppScanStage) -> String {
        if stage.presentationIndex < activeStage.presentationIndex {
            return L10n.text("已完成", "Completed")
        }
        if stage == activeStage { return L10n.text("正在进行", "In Progress") }
        return L10n.text("等待中", "Waiting")
    }
}

struct AppUpdateApplicationCopyGroup: Identifiable {
    let id: String
    let applications: [InstalledApplication]

    var primary: InstalledApplication? { applications.first }

    var isDuplicateGroup: Bool {
        applications.count > 1 || applications.contains(where: \.isDuplicate)
    }

    func matches(_ filter: AppUpdateListFilter, query: String = "") -> Bool {
        if filter == .automatic, isDuplicateGroup { return false }
        return primary(matching: filter, query: query) != nil
    }

    func primary(
        matching filter: AppUpdateListFilter,
        query: String = ""
    ) -> InstalledApplication? {
        AppUpdateListPresenter.visibleApps(
            from: applications,
            query: query,
            filter: filter
        ).first
    }

    func containsThirdParty(
        where predicate: (InstalledApplication) -> Bool
    ) -> Bool {
        applications.contains { AppUpdateListFilter.all.includes($0) && predicate($0) }
    }

    var hasSigningConflict: Bool {
        applications.contains {
            $0.sourceEvidence.contains("duplicate-signing-identity-conflict")
        }
    }

    static func make(from applications: [InstalledApplication]) -> [Self] {
        var order = [String]()
        var grouped = [String: [InstalledApplication]]()
        for application in applications {
            let identifier = application.bundleIdentifier.trimmed.lowercased()
            let key = identifier.isEmpty ? "path:\(application.id)" : "bundle:\(identifier)"
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(application)
        }
        return order.compactMap { key in
            guard let copies = grouped[key], !copies.isEmpty else { return nil }
            let sorted = copies.sorted { left, right in
                let leftRank = preferredCopyRank(left)
                let rightRank = preferredCopyRank(right)
                if leftRank != rightRank { return leftRank < rightRank }
                return left.path.localizedStandardCompare(right.path) == .orderedAscending
            }
            return Self(id: key, applications: sorted)
        }
    }

    static func count(
        in applications: [InstalledApplication],
        matching filter: AppUpdateListFilter
    ) -> Int {
        make(from: applications).filter { $0.matches(filter) }.count
    }

    private static func preferredCopyRank(_ application: InstalledApplication) -> Int {
        if application.path.hasPrefix("/Applications/") { return 0 }
        if application.path.contains("/Applications/") { return 1 }
        return 2
    }
}

struct AppUpdateApplicationCopyGroupPresentation {
    let groups: [AppUpdateApplicationCopyGroup]
    let automaticApps: [InstalledApplication]

    static func make(
        applications: [InstalledApplication],
        query: String
    ) -> Self {
        let allGroups = AppUpdateApplicationCopyGroup.make(from: applications)
        let visibleGroups = allGroups.filter { $0.matches(.updateAvailable, query: query) }
        let singleCopyApps = allGroups
            .filter { !$0.isDuplicateGroup }
            .compactMap(\.applications.first)
        let automaticApps = singleCopyApps.filter { application in
            application.canJoinAutomaticUpdatePlan
        }

        return Self(
            groups: visibleGroups,
            automaticApps: automaticApps
        )
    }
}

private extension View {
    func appUpdateListInsets() -> some View {
        listRowInsets(
            EdgeInsets(
                top: AppDesignTokens.Spacing.small,
                leading: AppDesignTokens.Layout.pagePadding,
                bottom: AppDesignTokens.Spacing.small,
                trailing: AppDesignTokens.Layout.pagePadding
            )
        )
    }
}

private struct AppUpdateScanSummaryPage: View {
    @Environment(\.moduleTheme) private var theme

    let summary: AppScanSummary
    let warnings: [String]
    let canUpdate: Bool
    let onUpdateAll: () -> Void
    let onManage: () -> Void
    let onRescan: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ModulePageHeader(
                title: L10n.text("扫描完成", "Scan Complete"),
                subtitle: L10n.text("可更新项目已整理", "Available updates are ready"),
                systemImage: "checkmark.circle.fill"
            ) {
                GlassToolbarButton(
                    title: L10n.text("重新扫描", "Scan Again"),
                    systemImage: "arrow.clockwise",
                    isDisabled: !canUpdate,
                    action: onRescan
                )
            }
            .padding(.bottom, AppDesignTokens.Spacing.medium)

            FeatureWorkspaceSurface {
                ScrollView {
                    VStack(spacing: 22) {
                        VStack(spacing: 5) {
                            Text(summary.scannedCount, format: .number)
                                .font(.system(size: 50, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.primaryText)
                                .monospacedDigit()
                            Text(L10n.text("已检查的应用", "Applications Checked"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(L10n.text("已检查的应用", "Applications Checked"))
                        .accessibilityValue("\(summary.scannedCount)")

                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                            spacing: 10
                        ) {
                            AppUpdateSummaryMetric(
                                title: L10n.text("可直接更新", "Automatic"),
                                value: summary.automaticCount,
                                systemImage: "arrow.down.circle.fill",
                                color: theme.accent
                            )
                            AppUpdateSummaryMetric(
                                title: L10n.text("退出后更新", "Quit First"),
                                value: summary.requiresQuitCount,
                                systemImage: "power.circle.fill",
                                color: .indigo
                            )
                            AppUpdateSummaryMetric(
                                title: L10n.text("需要授权", "Authorization"),
                                value: summary.requiresAuthorizationCount,
                                systemImage: "lock.shield.fill",
                                color: AppDesignTokens.Palette.warning
                            )
                            AppUpdateSummaryMetric(
                                title: L10n.text("需手动处理", "Manual"),
                                value: summary.manualCount,
                                systemImage: "hand.raised.fill",
                                color: .orange
                            )
                            AppUpdateSummaryMetric(
                                title: L10n.text("已是最新", "Current"),
                                value: summary.currentCount,
                                systemImage: "checkmark.shield.fill",
                                color: AppDesignTokens.Palette.success
                            )
                            AppUpdateSummaryMetric(
                                title: L10n.text("状态未知", "Unknown"),
                                value: summary.unknownCount,
                                systemImage: "questionmark.circle.fill",
                                color: .secondary
                            )
                        }

                        if summary.systemManagedCount > 0 {
                            Label(
                                L10n.text(
                                    "另有 \(summary.systemManagedCount) 个应用由 macOS 或 App Store 管理；已计入检查总数，不会加入应用内批量更新。",
                                    "Another \(summary.systemManagedCount) apps are managed by macOS or the App Store. They are included in the checked total and excluded from in-app batch updates."
                                ),
                                systemImage: "apple.logo"
                            )
                            .font(AppDesignTokens.Typography.metadata)
                            .foregroundStyle(theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        switch summary.completionState {
                        case .updatesAvailable:
                            EmptyView()
                        case .allCurrent:
                            AppUpdateActionNotice(
                                title: L10n.text("所有应用都是最新版本", "All Apps Are Up to Date"),
                                detail: L10n.text(
                                    "本次扫描没有发现可用更新，也没有需要手动确认或版本状态未知的应用。",
                                    "This scan found no available updates and no applications requiring manual review or with an unknown version state."
                                ),
                                systemImage: "checkmark.seal.fill"
                            )
                        case .noConfirmedUpdates:
                            AppUpdateActionNotice(
                                title: L10n.text("未发现可确认更新", "No Confirmed Updates Found"),
                                detail: L10n.text(
                                    "仍有应用需要手动检查、来源待确认或最新版本未知。",
                                    "Some applications still require manual checks, source confirmation, or have an unknown latest version."
                                ),
                                systemImage: "questionmark.circle"
                            )
                        }

                        if !warnings.isEmpty {
                            AppUpdateWarningsView(warnings: warnings)
                        }

                        HStack(spacing: 10) {
                            AppButton(
                                title: L10n.text("管理更新", "Manage Updates"),
                                systemImage: "list.bullet.rectangle",
                                kind: .secondary,
                                tint: theme.accent,
                                action: onManage
                            )
                            if !summary.batchEligibleApps.isEmpty {
                                AppButton(
                                    title: L10n.text(
                                        "一键更新全部 · \(summary.batchEligibleApps.count) 个",
                                        "Update All · \(summary.batchEligibleApps.count)"
                                    ),
                                    systemImage: "arrow.down.circle.fill",
                                    kind: .primary,
                                    tint: theme.accent,
                                    isDisabled: !canUpdate,
                                    help: L10n.text(
                                        "只包含可立即更新，以及可正常退出后更新的项目；需要授权的项目不会加入",
                                        "Includes only items that can update now or after a normal quit; authorization-required items are excluded"
                                    ),
                                    action: onUpdateAll
                                )
                            }
                        }
                    }
                    .padding(26)
                    .frame(maxWidth: .infinity)
                    .frame(maxWidth: .infinity, minHeight: 440)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.top, AppDesignTokens.Spacing.compact)
        .padding(.bottom, AppDesignTokens.Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AppUpdateSummaryMetric: View {
    let title: String
    let value: Int
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(value, format: .number)
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }
}

private struct AppUpdateWarningsView: View {
    let warnings: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(L10n.text("扫描提醒", "Scan Notices"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppDesignTokens.Palette.warning)
            ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                Text(warning)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppDesignTokens.Palette.warning.opacity(0.09),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

private enum AppUpdateCatalogSort: String, CaseIterable, Identifiable {
    case recommended
    case name
    case releaseDate
    case downloadSize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recommended: L10n.text("推荐顺序", "Recommended")
        case .name: L10n.text("名称", "Name")
        case .releaseDate: L10n.text("发布日期", "Release Date")
        case .downloadSize: L10n.text("下载大小", "Download Size")
        }
    }
}

private struct AppUpdateManagerPage: View {
    @Environment(\.moduleTheme) private var theme
    @Environment(\.windowLayoutMetrics) private var layout
    @State private var selectedAutomaticApplicationIDs = Set<String>()

    let snapshot: AppUpdateCatalogSnapshot
    @Binding var searchText: String
    @Binding var filter: AppUpdateCatalogFilter
    @Binding var sort: AppUpdateCatalogSort
    @Binding var selectedApplicationID: String?
    let batchState: UpdateOrchestratorState
    let canRunActions: Bool
    let onShowSummary: () -> Void
    let onRescan: () -> Void
    let onUpdateAutomatic: (Set<String>) -> Void
    let onAutomaticUpdate: (InstalledApplication) -> Void
    let onAppStoreUpdate: (InstalledApplication) -> Void
    let onOpenUpdateEntry: (InstalledApplication) -> Void

    var body: some View {
        ManagementListPage(
            title: L10n.text("应用更新", "Application Updates"),
            subtitle: subtitle,
            systemImage: "square.and.arrow.down"
        ) {
            GlassToolbarButton(
                title: L10n.text("扫描摘要", "Scan Summary"),
                systemImage: "chart.bar.xaxis",
                action: onShowSummary
            )
            GlassToolbarButton(
                title: L10n.text("检查更新", "Check for Updates"),
                systemImage: "arrow.clockwise",
                isDisabled: !canRunActions,
                action: onRescan
            )
            GlassToolbarButton(
                title: L10n.text(
                    "更新所选 · \(selectedAutomaticApplicationIDs.count) 个",
                    "Update Selected · \(selectedAutomaticApplicationIDs.count)"
                ),
                systemImage: "arrow.down.circle",
                isDisabled: !canRunActions || selectedAutomaticApplicationIDs.isEmpty
            ) {
                onUpdateAutomatic(selectedAutomaticApplicationIDs)
            }
        } controls: {
            catalogControls
        } content: {
            catalogWorkspace
        }
        .onAppear {
            normalizeSelection(visibleEntries.map(\.id))
        }
        .onChange(of: snapshot.sessionID) { _, _ in
            selectedAutomaticApplicationIDs.formIntersection(automaticApplicationIDs)
        }
        .onChange(of: automaticApplicationIDs) { _, eligibleIDs in
            selectedAutomaticApplicationIDs.formIntersection(eligibleIDs)
        }
        .onChange(of: visibleEntries.map(\.id)) { _, ids in
            normalizeSelection(ids)
        }
    }

    @ViewBuilder
    private var catalogWorkspace: some View {
        VStack(spacing: 0) {
            catalogColumns
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text(
                    "显示 \(visibleEntries.count) / \(snapshot.entries.count) 个应用；已选 \(selectedAutomaticApplicationIDs.count) 个，其中筛选外 \(selectedAutomaticApplicationIDs.subtracting(visibleAutomaticApplicationIDs).count) 个",
                    "Showing \(visibleEntries.count) of \(snapshot.entries.count) apps; \(selectedAutomaticApplicationIDs.count) selected, including \(selectedAutomaticApplicationIDs.subtracting(visibleAutomaticApplicationIDs).count) outside this filter"
                ))
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.secondary)
                HStack {
                    Button(L10n.text("选择当前可更新项", "Select Visible Updates")) {
                        selectedAutomaticApplicationIDs.formUnion(visibleAutomaticApplicationIDs)
                    }
                    .disabled(visibleAutomaticApplicationIDs.isEmpty)
                    Button(L10n.text("选择全部可更新项", "Select All Updates")) {
                        selectedAutomaticApplicationIDs = automaticApplicationIDs
                    }
                    .disabled(automaticApplicationIDs.isEmpty)
                    Button(L10n.text("清空选择", "Clear Selection")) {
                        selectedAutomaticApplicationIDs.removeAll()
                    }
                    .disabled(selectedAutomaticApplicationIDs.isEmpty)
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
        }
    }

    @ViewBuilder
    private var catalogColumns: some View {
        if layout.density == .compact {
            VStack(spacing: 0) {
                catalogList
                    .frame(minHeight: 180, maxHeight: .infinity)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        } else {
            HStack(spacing: 0) {
                catalogList
                    .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
                Divider()
                detail
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }

    private var catalogControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) {
                catalogSearchField
                catalogPickerRow
            }

            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                catalogSearchField
                catalogPickerRow
            }
        }
    }

    private var catalogSearchField: some View {
        TaskSearchField(
            placeholder: L10n.text("搜索应用、版本或来源", "Search apps, versions, or sources"),
            text: $searchText,
            tint: theme.accent
        )
        .frame(maxWidth: .infinity)
    }

    private var catalogPickerRow: some View {
        HStack(spacing: 9) {
            Picker(L10n.text("更新能力", "Capability"), selection: $filter) {
                ForEach(AppUpdateCatalogFilter.allCases, id: \.self) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 138)
            .help(L10n.text("按更新能力筛选", "Filter by update capability"))
            .accessibilityLabel(L10n.text("更新能力筛选", "Update Capability Filter"))

            Picker(L10n.text("排序", "Sort"), selection: $sort) {
                ForEach(AppUpdateCatalogSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 122)
            .help(L10n.text("应用排序", "Application sort order"))
            .accessibilityLabel(L10n.text("应用排序", "Application Sort Order"))
        }
    }

    private var automaticApplicationIDs: Set<String> {
        Set(snapshot.entries.filter(\.canJoinAutomaticUpdateBatch).map(\.id))
    }

    private var visibleAutomaticApplicationIDs: Set<String> {
        Set(visibleEntries.filter(\.canJoinAutomaticUpdateBatch).map(\.id))
    }

    private var subtitle: String {
        let base = L10n.text("\(snapshot.entries.count) 个应用", "\(snapshot.entries.count) applications")
        guard batchState != .idle, !batchState.title.isEmpty else { return base }
        return "\(base) · \(batchState.title)"
    }

    private var visibleEntries: [AppUpdateCatalogEntry] {
        let query = searchText.trimmed
        let entries = snapshot.entries(matching: filter)
            .filter { entry in
                guard !query.isEmpty else { return true }
                let app = entry.application
                return app.name.localizedCaseInsensitiveContains(query)
                    || app.bundleIdentifier.localizedCaseInsensitiveContains(query)
                    || app.currentVersionDisplay.localizedCaseInsensitiveContains(query)
                    || app.latestVersionDisplay.localizedCaseInsensitiveContains(query)
                    || app.source.localizedCaseInsensitiveContains(query)
                    || (app.officialDomain?.localizedCaseInsensitiveContains(query) ?? false)
            }
        return entries.sorted(by: sortPredicate)
    }

    private var selectedEntry: AppUpdateCatalogEntry? {
        visibleEntries.first { $0.id == selectedApplicationID }
    }

    @ViewBuilder
    private var catalogList: some View {
        if visibleEntries.isEmpty {
            ContentUnavailableView(
                searchText.trimmed.isEmpty
                    ? L10n.text("没有此类应用", "No Applications in This Category")
                    : L10n.text("没有搜索结果", "No Search Results"),
                systemImage: "magnifyingglass",
                description: Text(
                    L10n.text("调整筛选或搜索条件。", "Adjust the filter or search query.")
                )
            )
        } else {
            List(selection: $selectedApplicationID) {
                ForEach(visibleEntries) { entry in
                    AppUpdateCatalogRow(
                        entry: entry,
                        canRunActions: canRunActions,
                        onOpenManualUpdate: { onOpenUpdateEntry(entry.application) },
                        isSelectedForAutomaticUpdate: Binding(
                            get: { selectedAutomaticApplicationIDs.contains(entry.id) },
                            set: { isSelected in
                                guard entry.canJoinAutomaticUpdateBatch else { return }
                                if isSelected {
                                    selectedAutomaticApplicationIDs.insert(entry.id)
                                } else {
                                    selectedAutomaticApplicationIDs.remove(entry.id)
                                }
                            }
                        )
                    )
                        .tag(entry.id)
                        .appUpdateListInsets()
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .accessibilityLabel(L10n.text("应用更新列表", "Application Update List"))
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selectedEntry {
            AppUpdateCatalogDetail(
                entry: selectedEntry,
                canRunActions: canRunActions,
                onAutomaticUpdate: onAutomaticUpdate,
                onAppStoreUpdate: onAppStoreUpdate,
                onOpenUpdateEntry: onOpenUpdateEntry
            )
        } else {
            ContentUnavailableView(
                L10n.text("选择一个应用", "Select an Application"),
                systemImage: "app.dashed",
                description: Text(
                    L10n.text("查看版本、来源和可用操作。", "Review versions, source, and available actions.")
                )
            )
        }
    }

    private func normalizeSelection(_ ids: [String]) {
        guard !ids.isEmpty else {
            selectedApplicationID = nil
            return
        }
        if let selectedApplicationID, ids.contains(selectedApplicationID) { return }
        selectedApplicationID = ids.first
    }

    private func sortPredicate(
        _ left: AppUpdateCatalogEntry,
        _ right: AppUpdateCatalogEntry
    ) -> Bool {
        switch sort {
        case .recommended:
            let leftRank = left.category.presentationRank
            let rightRank = right.category.presentationRank
            if leftRank != rightRank { return leftRank < rightRank }
        case .releaseDate:
            let leftDate = left.application.releaseDate ?? .distantPast
            let rightDate = right.application.releaseDate ?? .distantPast
            if leftDate != rightDate { return leftDate > rightDate }
        case .downloadSize:
            let leftSize = left.application.downloadSize ?? -1
            let rightSize = right.application.downloadSize ?? -1
            if leftSize != rightSize { return leftSize > rightSize }
        case .name:
            break
        }
        return left.application.name.localizedStandardCompare(right.application.name) == .orderedAscending
    }
}

private struct AppUpdateCatalogRow: View {
    let entry: AppUpdateCatalogEntry
    let canRunActions: Bool
    let onOpenManualUpdate: () -> Void
    @Binding var isSelectedForAutomaticUpdate: Bool

    var body: some View {
        HStack(spacing: 10) {
            if entry.canJoinAutomaticUpdateBatch {
                Toggle(
                    L10n.text(
                        "选择 \(entry.application.name) 加入安全更新批次",
                        "Select \(entry.application.name) for the safe update batch"
                    ),
                    isOn: $isSelectedForAutomaticUpdate
                )
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(L10n.text("加入安全更新批次", "Include in the safe update batch"))
            } else {
                Color.clear
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }

            AppUpdateApplicationIcon(
                application: entry.application,
                size: 32,
                tint: entry.category.color
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.application.name)
                    .font(AppDesignTokens.Typography.compactLabel.weight(.medium))
                    .lineLimit(1)
                    .help(entry.application.name)
                Text(versionText)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.application.source.trimmed.nonEmpty ?? L10n.text("来源待确认", "Source Unconfirmed"))
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(entry.application.path)
                Label(entry.category.title, systemImage: entry.category.systemImage)
                    .font(AppDesignTokens.Typography.metadata)
                    .foregroundStyle(entry.category.color)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            if entry.category == .manual {
                AppButton(
                    title: L10n.text("更新入口", "Update Entry"),
                    systemImage: "arrow.up.right",
                    kind: .smallUtility,
                    controlSize: .small,
                    isDisabled: !canRunActions,
                    help: L10n.text("打开此项目的手动更新入口", "Open this item's manual update entry"),
                    action: onOpenManualUpdate
                )
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.application.name)
        .accessibilityValue("\(versionText), \(entry.application.source), \(entry.category.title)")
    }

    private var versionText: String {
        guard let availableVersion = entry.application.availableVersion else {
            return entry.application.currentVersionDisplay
        }
        return "\(entry.application.currentVersionDisplay) → \(availableVersion.display)"
    }
}

private struct AppUpdateApplicationIcon: View {
    let application: InstalledApplication
    let size: CGFloat
    let tint: Color

    var body: some View {
        if let applicationURL = ApplicationIconSourceResolver.applicationBundleURL(for: application) {
            CachedAppIconView(path: applicationURL.path, size: size) {
                fallback
            }
        } else {
            fallback
        }
    }

    private var fallback: some View {
        Image(systemName: fallbackSystemImage)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(
                tint.opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .stroke(tint.opacity(0.20), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    private var fallbackSystemImage: String {
        if application.packageKind == .commandLineTool { return "terminal" }
        switch application.primaryUpdateProvider {
        case .macAppStore: return "apple.logo"
        case .homebrew: return "shippingbox.fill"
        case .systemManaged: return "gearshape.2.fill"
        case .sparkle, .vendorUpdater: return "arrow.triangle.2.circlepath"
        case .officialWebsite: return "safari"
        case .manual: return "app.fill"
        }
    }
}

private struct AppUpdateCatalogDetail: View {
    @Environment(\.moduleTheme) private var theme

    let entry: AppUpdateCatalogEntry
    let canRunActions: Bool
    let onAutomaticUpdate: (InstalledApplication) -> Void
    let onAppStoreUpdate: (InstalledApplication) -> Void
    let onOpenUpdateEntry: (InstalledApplication) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    AppUpdateApplicationIcon(
                        application: app,
                        size: 58,
                        tint: entry.category.color
                    )

                    VStack(alignment: .leading, spacing: 5) {
                        Text(app.name)
                            .font(.system(size: 23, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)
                        Label(entry.category.title, systemImage: entry.category.systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(entry.category.color)
                        Text(app.bundleIdentifier.trimmed.nonEmpty ?? L10n.text("无 Bundle ID", "No Bundle ID"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                AppUpdateVersionComparison(app: app)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    AppUpdateFact(
                        title: L10n.text("更新来源", "Update Source"),
                        value: sourceText,
                        systemImage: "link"
                    )
                    AppUpdateFact(
                        title: L10n.text("发布日期", "Release Date"),
                        value: releaseDateText,
                        systemImage: "calendar"
                    )
                    AppUpdateFact(
                        title: L10n.text("下载大小", "Download Size"),
                        value: downloadSizeText,
                        systemImage: "arrow.down.circle"
                    )
                    AppUpdateFact(
                        title: L10n.text("安装位置", "Installed Location"),
                        value: app.path,
                        systemImage: "folder"
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text("发布说明", "Release Notes"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(app.releaseNotes?.trimmed.nonEmpty ?? L10n.text("暂无发布说明", "No release notes available"))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                if let updateError = app.updateError?.trimmed.nonEmpty {
                    Label(updateError, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppDesignTokens.Palette.warning)
                        .textSelection(.enabled)
                }

                advancedHomebrewDetails
                actionArea
            }
            .padding(20)
            .frame(maxWidth: 650, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var app: InstalledApplication { entry.application }

    private var sourceText: String {
        app.officialDomain?.trimmed.nonEmpty
            ?? app.source.trimmed.nonEmpty
            ?? L10n.text("暂无", "Unavailable")
    }

    private var releaseDateText: String {
        app.releaseDate?.formatted(date: .abbreviated, time: .omitted)
            ?? L10n.text("暂无", "Unavailable")
    }

    private var downloadSizeText: String {
        guard let downloadSize = app.downloadSize, downloadSize >= 0 else {
            return L10n.text("暂无", "Unavailable")
        }
        return ByteCountFormatter.string(fromByteCount: downloadSize, countStyle: .file)
    }

    @ViewBuilder
    private var actionArea: some View {
        switch entry.category {
        case .automatic:
            AppButton(
                title: L10n.text("更新此应用", "Update This Application"),
                systemImage: "arrow.down.circle.fill",
                kind: .primary,
                tint: theme.accent,
                isDisabled: !canRunActions || !entry.canJoinAutomaticUpdatePlan
            ) {
                onAutomaticUpdate(app)
            }
        case .requiresQuit:
            AppButton(
                title: L10n.text("退出并更新", "Quit and Update"),
                systemImage: "power.circle.fill",
                kind: .primary,
                tint: theme.accent,
                isDisabled: !canRunActions || !entry.canJoinAutomaticUpdateBatch,
                help: L10n.text(
                    "先请求应用正常退出；不会强制终止进程，退出失败时更新会停止",
                    "Requests a normal quit first; the app is never force-terminated and the update stops if quitting fails"
                )
            ) {
                onAutomaticUpdate(app)
            }
        case .requiresAuthorization:
            AppUpdateActionNotice(
                title: L10n.text("需要管理员授权", "Administrator Authorization Required"),
                detail: app.updateHandlingDetail,
                systemImage: "lock.shield.fill"
            )
        case .appStore:
            AppButton(
                title: L10n.text("在 App Store 中更新", "Update in App Store"),
                systemImage: "apple.logo",
                kind: .primary,
                tint: theme.accent,
                isDisabled: !canRunActions || !entry.isUpdateAvailable,
                help: L10n.text(
                    "打开公开 App Store 页面；仍需由你确认，应用不会自动操作 App Store",
                    "Open the public App Store page; you still confirm the update and the app never automates the App Store"
                )
            ) {
                onAppStoreUpdate(app)
            }
        case .inApplication:
            AppButton(
                title: L10n.text("打开应用内更新", "Open In-App Updater"),
                systemImage: "arrow.up.forward.app",
                kind: .primary,
                tint: theme.accent,
                isDisabled: !canRunActions
            ) {
                onOpenUpdateEntry(app)
            }
        case .website where app.hasConfirmedOfficialWebsiteSource:
            AppButton(
                title: L10n.text("打开已验证官网", "Open Verified Website"),
                systemImage: "safari",
                kind: .primary,
                tint: theme.accent,
                isDisabled: !canRunActions
            ) {
                onOpenUpdateEntry(app)
            }
        case .website:
            AppUpdateActionNotice(
                title: L10n.text("官网来源待确认", "Website Source Unconfirmed"),
                detail: L10n.text(
                    "没有可验证的官方地址，因此未提供下载按钮。",
                    "No verifiable official address is available, so no download button is shown."
                ),
                systemImage: "questionmark.shield"
            )
        case .manual:
            AppButton(
                title: manualUpdateButtonTitle,
                systemImage: manualUpdateButtonSystemImage,
                kind: .secondary,
                tint: theme.accent,
                isDisabled: !canRunActions
            ) {
                onOpenUpdateEntry(app)
            }
        case .unknown:
            AppUpdateActionNotice(
                title: L10n.text("当前不支持更新", "Update Currently Unsupported"),
                detail: app.updateHandlingDetail,
                systemImage: "questionmark.circle"
            )
        case .systemManaged:
            AppUpdateActionNotice(
                title: L10n.text("由 macOS 管理", "Managed by macOS"),
                detail: app.updateHandlingDetail,
                systemImage: "apple.logo"
            )
        }
    }

    private var manualUpdateButtonTitle: String {
        if AppUpdateService.validatedManualUpdateURL(for: app) != nil {
            return L10n.text("打开官方更新页", "Open Official Update Page")
        }
        if app.primaryUpdateProvider == .homebrew {
            return L10n.text("复制更新命令", "Copy Update Command")
        }
        return L10n.text("打开更新入口", "Open Update Entry")
    }

    private var manualUpdateButtonSystemImage: String {
        if AppUpdateService.validatedManualUpdateURL(for: app) != nil { return "safari" }
        return app.primaryUpdateProvider == .homebrew ? "doc.on.doc" : "arrow.up.forward.app"
    }

    @ViewBuilder
    private var advancedHomebrewDetails: some View {
        if let command = app.homebrewCommand {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text(
                        "应用内自动更新使用受控可执行文件与参数数组，不会执行此显示文本。",
                        "In-app automatic updates use a controlled executable and argument array; this displayed text is never evaluated."
                    ))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                    Text(command)
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            Color.primary.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )

                    AppButton(
                        title: L10n.text("复制命令（备用）", "Copy Command (Fallback)"),
                        systemImage: "doc.on.doc",
                        kind: .secondary,
                        tint: theme.accent,
                        isDisabled: !canRunActions,
                        help: L10n.text(
                            "仅供高级用户手动排障；普通更新请使用一键更新",
                            "For advanced manual troubleshooting only; use Update All for normal updates"
                        )
                    ) {
                        onOpenUpdateEntry(app)
                    }
                }
                .padding(.top, 10)
            } label: {
                Label(
                    L10n.text("高级详情与备用命令", "Advanced Details and Fallback Command"),
                    systemImage: "terminal"
                )
                .font(.system(size: 13, weight: .semibold))
            }
            .padding(13)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
    }
}

private struct AppUpdateVersionComparison: View {
    let app: InstalledApplication

    var body: some View {
        HStack(spacing: 12) {
            version(title: L10n.text("当前版本", "Current"), value: app.currentVersionDisplay)
            Image(systemName: "arrow.right")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            version(title: L10n.text("可用版本", "Available"), value: app.availableVersion?.display ?? L10n.text("暂无", "Unavailable"))
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func version(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppUpdateFact: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct AppUpdateActionNotice: View {
    let title: String
    let detail: String
    let systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AppUpdatePreparingPage: View {
    @Environment(\.moduleTheme) private var theme

    let plan: FrozenUpdatePlan
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.15))
                    .frame(width: 104, height: 104)
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(theme.accent)
                    .accessibilityHidden(true)
            }

            VStack(spacing: 7) {
                Text(L10n.text("正在准备更新", "Preparing Updates"))
                    .font(.system(size: 30, weight: .bold))
                Text(L10n.text(
                    "正在冻结更新计划并重新核验来源、版本与应用身份",
                    "Freezing the update plan and rechecking source, version, and application identity"
                ))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            }

            ContentPanel(cornerRadius: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel(L10n.text("正在准备更新", "Preparing Updates"))
                    ForEach(plan.automaticApplications) { app in
                        HStack(spacing: 10) {
                            CachedAppIconView(
                                path: ApplicationIconSourceResolver.sourceURL(for: app).path,
                                size: 27
                            ) {
                                AppSymbolIcon(systemImage: "app", role: .inline)
                            }
                            Text(app.name)
                                .font(.system(size: 12.5, weight: .semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(app.availableVersion?.display ?? L10n.text("版本待核验", "Version pending"))
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(17)
            }
            .frame(maxWidth: 520)

            AppButton(
                title: L10n.text("取消", "Cancel"),
                systemImage: "xmark.circle",
                kind: .secondary,
                tint: theme.accent,
                action: onCancel
            )
        }
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.vertical, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

private struct AppUpdateProgressPage: View {
    @Environment(\.moduleTheme) private var theme

    let snapshot: AppUpdateSessionSnapshot
    let isFinalizing: Bool
    let onCancel: () -> Void
    let onShowLog: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ModulePageHeader(
                title: pageTitle,
                subtitle: pageSubtitle,
                systemImage: snapshot.isCancellationRequested
                    ? "stop.circle"
                    : (isFinalizing ? "checkmark.shield" : "arrow.down.circle.fill")
            ) {
                GlassToolbarButton(
                    title: L10n.text("本次日志", "Session Log"),
                    systemImage: "doc.text.magnifyingglass",
                    action: onShowLog
                )
            }
            .padding(.bottom, AppDesignTokens.Spacing.medium)

            FeatureWorkspaceSurface {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(progressTitle)
                                .font(.system(size: 14, weight: .semibold))
                            Spacer()
                            Text(progressCountText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }

                        if let fraction = snapshot.processedFraction {
                            ProgressView(value: fraction)
                                .progressViewStyle(.linear)
                                .tint(theme.accent)
                                .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100))%")
                        } else {
                            ProgressView()
                                .progressViewStyle(.linear)
                                .tint(theme.accent)
                                .accessibilityValue(L10n.text("正在等待真实进度", "Waiting for real progress"))
                        }
                    }
                    .padding(17)

                    Divider()

                    List(snapshot.items) { item in
                        AppUpdateSessionItemRow(item: item)
                            .appUpdateListInsets()
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .accessibilityLabel(L10n.text("更新项目状态", "Update Item Status"))

                    if !isFinalizing {
                        Divider()
                        HStack {
                            Spacer()
                            AppButton(
                                title: snapshot.isCancellationRequested
                                    ? L10n.text("正在停止", "Stopping")
                                    : L10n.text("停止更新", "Stop Updates"),
                                systemImage: "stop.circle",
                                kind: .secondary,
                                tint: theme.accent,
                                isDisabled: snapshot.isCancellationRequested,
                                action: onCancel
                            )
                        }
                        .padding(14)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.top, AppDesignTokens.Spacing.compact)
        .padding(.bottom, AppDesignTokens.Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var progressTitle: String {
        if snapshot.isCancellationRequested {
            return L10n.text("正在停止和清理", "Stopping and Cleaning Up")
        }
        if isFinalizing { return L10n.text("最终核验", "Final Verification") }
        return snapshot.queue.isPaused
            ? L10n.text("更新已暂停", "Updates Paused")
            : L10n.text("总体进度", "Overall Progress")
    }

    private var pageTitle: String {
        if snapshot.isCancellationRequested {
            return L10n.text("正在停止更新", "Stopping Updates")
        }
        return isFinalizing
            ? L10n.text("正在完成更新", "Finalizing Updates")
            : L10n.text("正在更新应用", "Updating Applications")
    }

    private var pageSubtitle: String {
        if snapshot.isCancellationRequested {
            return L10n.text("正在完成当前步骤", "Finishing the Current Step")
        }
        return isFinalizing
            ? L10n.text("正在核验安装结果", "Verifying Installed Versions")
            : L10n.text("\(snapshot.items.count) 个应用", "\(snapshot.items.count) applications")
    }

    private var progressCountText: String {
        let processed = snapshot.items.count { $0.task.state.isTerminal }
        return "\(processed) / \(snapshot.items.count)"
    }
}

private struct AppUpdateSessionItemRow: View {
    @Environment(\.moduleTheme) private var theme

    let item: AppUpdateSessionItem

    var body: some View {
        HStack(spacing: 12) {
            if let app = item.application {
                CachedAppIconView(
                    path: ApplicationIconSourceResolver.sourceURL(for: app).path,
                    size: 34
                ) {
                    AppSymbolIcon(systemImage: "app", role: .inline)
                }
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Label(item.task.state.title, systemImage: item.task.state.systemImage)
                        .foregroundStyle(item.task.state.color)
                    if let detail = item.task.detail?.trimmed.nonEmpty,
                       detail != item.task.errorDescription?.trimmed.nonEmpty {
                        Text("·")
                        Text(detail)
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

                if let fraction = item.task.progressFraction,
                   fraction.isFinite,
                   !item.task.state.isTerminal {
                    ProgressView(value: min(max(fraction, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(theme.accent)
                        .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100))%")
                }

                if let error = item.task.errorDescription?.trimmed.nonEmpty {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppDesignTokens.Palette.destructive)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 10)

            Text(item.task.targetVersion?.display ?? "—")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.displayName)
        .accessibilityValue(item.task.state.title)
    }
}

private struct AppUpdateReportPage: View {
    @Environment(\.moduleTheme) private var theme

    let report: AppUpdateReport?
    let fallbackOutcome: AppUpdateReportOutcome
    let onRetry: (Set<String>) -> Void
    let onShowLog: () -> Void
    let onManage: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ModulePageHeader(
                title: outcome.title,
                subtitle: outcome.detail,
                systemImage: outcome.systemImage
            ) {
                if report != nil {
                    GlassToolbarButton(
                        title: L10n.text("本次日志", "Session Log"),
                        systemImage: "doc.text.magnifyingglass",
                        action: onShowLog
                    )
                }
            }
            .padding(.bottom, AppDesignTokens.Spacing.medium)

            FeatureWorkspaceSurface {
                VStack(spacing: 0) {
                    if let report {
                        HStack(spacing: AppDesignTokens.Spacing.small) {
                            AppUpdateReportCount(
                                title: L10n.text("成功", "Succeeded"),
                                value: report.succeededCount,
                                color: AppDesignTokens.Palette.success
                            )
                            AppUpdateReportCount(
                                title: L10n.text("失败", "Failed"),
                                value: report.failedCount,
                                color: AppDesignTokens.Palette.destructive
                            )
                            AppUpdateReportCount(
                                title: L10n.text("取消", "Cancelled"),
                                value: report.cancelledCount,
                                color: .secondary
                            )
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, AppDesignTokens.Layout.sectionPadding)
                        .padding(.vertical, AppDesignTokens.Layout.compactPadding)

                        if let sessionError = report.sessionError?.trimmed.nonEmpty {
                            Divider()
                            Text(sessionError)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(AppDesignTokens.Palette.destructive)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, AppDesignTokens.Layout.sectionPadding)
                                .padding(.vertical, AppDesignTokens.Spacing.regular)
                                .background(AppDesignTokens.Palette.destructive.opacity(0.07))
                        }

                        Divider()

                        if report.items.isEmpty {
                            AppUpdateActionNotice(
                                title: outcome.title,
                                detail: outcome.detail,
                                systemImage: outcome.systemImage
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(report.items) { item in
                                        AppUpdateReportItemRow(item: item) {
                                            onRetry([item.applicationID])
                                        }
                                        if item.id != report.items.last?.id { Divider() }
                                    }
                                }
                            }
                        }
                    } else {
                        AppUpdateActionNotice(
                            title: outcome.title,
                            detail: outcome.detail,
                            systemImage: outcome.systemImage
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    Divider()

                    HStack(spacing: AppDesignTokens.Spacing.regular) {
                        AppButton(
                            title: L10n.text("管理更新", "Manage Updates"),
                            systemImage: "list.bullet.rectangle",
                            kind: .secondary,
                            tint: theme.accent,
                            action: onManage
                        )
                        Spacer(minLength: AppDesignTokens.Spacing.medium)
                        if !retryableApplicationIDs.isEmpty {
                            AppButton(
                                title: L10n.text(
                                    "重试失败项（\(retryableApplicationIDs.count)）",
                                    "Retry Failed (\(retryableApplicationIDs.count))"
                                ),
                                systemImage: "arrow.clockwise",
                                kind: .secondary,
                                tint: theme.accent
                            ) {
                                onRetry(retryableApplicationIDs)
                            }
                        }
                        AppButton(
                            title: L10n.text("完成", "Done"),
                            systemImage: "checkmark",
                            kind: .primary,
                            tint: theme.accent,
                            action: onDone
                        )
                    }
                    .padding(.horizontal, AppDesignTokens.Layout.sectionPadding)
                    .padding(.vertical, AppDesignTokens.Layout.compactPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.top, AppDesignTokens.Spacing.compact)
        .padding(.bottom, AppDesignTokens.Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var outcome: AppUpdateReportOutcome { report?.outcome ?? fallbackOutcome }

    private var retryableApplicationIDs: Set<String> {
        Set(report?.retryableApplicationIDs ?? [])
    }
}

private struct AppUpdateReportCount: View {
    let title: String
    let value: Int
    let color: Color

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.tight) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value, format: .number)
                .font(.system(size: 12.5, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.05), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(value)")
    }
}

private struct AppUpdateReportItemRow: View {
    let item: AppUpdateReportItem
    let onRetry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            if let applicationPath = item.applicationPath?.trimmed.nonEmpty {
                CachedAppIconView(path: applicationPath, size: 34) {
                    AppSymbolIcon(systemImage: "app", role: .inline)
                }
            } else {
                AppSymbolIcon(systemImage: "app.dashed", role: .inline)
                    .frame(width: 34, height: 34)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(versionText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                if let detail = item.detail?.trimmed.nonEmpty,
                   detail != item.errorDescription?.trimmed.nonEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                if let error = item.errorDescription?.trimmed.nonEmpty {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(AppDesignTokens.Palette.destructive)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 10)

            VStack(alignment: .trailing, spacing: 6) {
                Text(item.state.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(item.state.color)
                if item.canRetry {
                    AppButton(
                        title: L10n.text("重试", "Retry"),
                        systemImage: "arrow.clockwise",
                        kind: .smallUtility,
                        controlSize: .small,
                        action: onRetry
                    )
                }
            }
        }
        .padding(.horizontal, AppDesignTokens.Layout.sectionPadding)
        .padding(.vertical, AppDesignTokens.Layout.compactPadding)
        .accessibilityElement(children: .contain)
    }

    private var versionText: String {
        let versions = if let targetVersion = item.targetVersion {
            "\(item.originalVersion.display) → \(targetVersion.display)"
        } else {
            item.originalVersion.display
        }
        return "\(versions) · \(item.sourceDisplayName)"
    }
}

private struct AppUpdateSessionLogPage: View {
    @Environment(\.moduleTheme) private var theme

    let state: AppUpdatePresentationState
    let onRetry: (Set<String>) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ModulePageHeader(
                title: L10n.text("本次更新日志", "Current Update Log"),
                subtitle: L10n.text(
                    "只显示当前更新会话；此页面不创建历史记录",
                    "Shows only the current update session; this page does not create a history store"
                ),
                systemImage: "doc.text.magnifyingglass"
            ) {
                GlassToolbarButton(
                    title: L10n.text("返回", "Back"),
                    systemImage: "chevron.left",
                    action: onBack
                )
            }
            .padding(.bottom, AppDesignTokens.Spacing.medium)

            FeatureWorkspaceSurface {
                VStack(spacing: 0) {
                    if let sessionID = state.sessionID {
                        HStack {
                            Text(L10n.text("会话", "Session"))
                            Text(sessionID.uuidString)
                                .textSelection(.enabled)
                            Spacer()
                            Text(state.phase.title)
                        }
                        .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.secondaryText)
                        .padding(14)
                        Divider()
                    }

                    if !entries.isEmpty {
                        HStack(spacing: 10) {
                            AppUpdateLogMetric(
                                title: L10n.text("成功", "Succeeded"),
                                value: "\(entries.count { $0.state == .completed })"
                            )
                            AppUpdateLogMetric(
                                title: L10n.text("失败", "Failed"),
                                value: "\(entries.count { $0.state == .failed })"
                            )
                            AppUpdateLogMetric(
                                title: L10n.text("需操作", "Action Needed"),
                                value: "\(manualActionCount)"
                            )
                            AppUpdateLogMetric(
                                title: L10n.text("下载大小", "Download Size"),
                                value: totalDownloadSizeText
                            )
                            AppUpdateLogMetric(
                                title: L10n.text("总耗时", "Duration"),
                                value: durationText
                            )
                        }
                        .padding(12)
                        Divider()
                    }

                    if entries.isEmpty {
                        ContentUnavailableView(
                            L10n.text("暂无日志项目", "No Log Items"),
                            systemImage: "doc.text",
                            description: Text(
                                L10n.text("当前会话尚未产生逐项状态。", "The current session has not produced item states yet.")
                            )
                        )
                    } else {
                        List(entries) { entry in
                            AppUpdateLogRow(entry: entry)
                                .appUpdateListInsets()
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel(L10n.text("本次更新日志项目", "Current Update Log Items"))
                    }

                    Divider()
                    HStack {
                        AppButton(
                            title: L10n.text("完成", "Done"),
                            systemImage: "checkmark",
                            kind: .secondary,
                            tint: theme.accent,
                            action: onBack
                        )
                        Spacer()
                        if !retryableApplicationIDs.isEmpty {
                            AppButton(
                                title: L10n.text(
                                    "重试失败项目 · \(retryableApplicationIDs.count)",
                                    "Retry Failed · \(retryableApplicationIDs.count)"
                                ),
                                systemImage: "arrow.clockwise",
                                kind: .primary,
                                tint: theme.accent
                            ) {
                                onRetry(retryableApplicationIDs)
                                onBack()
                            }
                        }
                    }
                    .padding(12)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, AppDesignTokens.Layout.pagePadding)
        .padding(.top, AppDesignTokens.Spacing.compact)
        .padding(.bottom, AppDesignTokens.Layout.pagePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var entries: [AppUpdateLogEntry] {
        switch state {
        case let .preparingUpdate(plan):
            return plan.automaticApplications.map { app in
                AppUpdateLogEntry(
                    id: "preparing-\(app.id)",
                    timestamp: plan.createdAt,
                    applicationName: app.name,
                    originalVersion: app.installedVersion,
                    targetVersion: app.availableVersion,
                    sourceDisplayName: app.source,
                    applicationPath: app.path,
                    downloadSize: app.downloadSize,
                    createdAt: plan.createdAt,
                    attemptCount: 0,
                    state: .queued,
                    detail: L10n.text("已加入冻结计划", "Added to frozen plan"),
                    errorDescription: nil
                )
            }
        case let .updating(snapshot), let .finalizing(snapshot):
            return snapshot.items.map { item in
                AppUpdateLogEntry(
                    id: item.task.id.uuidString,
                    timestamp: item.task.updatedAt,
                    applicationName: item.displayName,
                    originalVersion: item.task.originalVersion,
                    targetVersion: item.task.targetVersion,
                    sourceDisplayName: item.application?.source.trimmed.nonEmpty
                        ?? item.task.providerIdentifier.rawValue,
                    applicationPath: item.application?.path,
                    downloadSize: item.application?.downloadSize,
                    createdAt: item.task.createdAt,
                    attemptCount: item.task.attemptCount,
                    state: item.task.state,
                    detail: item.task.detail,
                    errorDescription: item.task.errorDescription
                )
            }
        case let .completed(report), let .failed(report):
            return report.logEntries
        case let .cancelled(report):
            return report?.logEntries ?? []
        case .idle, .scanning, .scanSummary, .managing:
            return []
        }
    }

    private var manualActionCount: Int {
        entries.count {
            [.waitingForQuit, .waitingForAuthorization, .needsReconciliation, .skipped]
                .contains($0.state)
        }
    }

    private var retryableApplicationIDs: Set<String> {
        switch state {
        case let .completed(report), let .failed(report):
            Set(report.retryableApplicationIDs)
        case let .cancelled(report):
            Set(report?.retryableApplicationIDs ?? [])
        case .idle, .scanning, .scanSummary, .managing,
             .preparingUpdate, .updating, .finalizing:
            []
        }
    }

    private var totalDownloadSizeText: String {
        let knownSizes = entries.compactMap(\.downloadSize)
        guard !knownSizes.isEmpty else { return L10n.text("暂无", "Unavailable") }
        let formatted = ByteCountFormatter.string(
            fromByteCount: knownSizes.reduce(0, +),
            countStyle: .file
        )
        guard knownSizes.count == entries.count else {
            return L10n.text("已知至少 \(formatted)", "At least \(formatted) known")
        }
        return formatted
    }

    private var durationText: String {
        guard let startedAt = entries.map(\.createdAt).min(),
              let updatedAt = entries.map(\.timestamp).max() else {
            return L10n.text("暂无", "Unavailable")
        }
        let totalSeconds = max(0, Int(updatedAt.timeIntervalSince(startedAt).rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return minutes > 0 ? "\(minutes)m \(seconds)s" : "\(seconds)s"
    }
}

private struct AppUpdateLogMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

private struct AppUpdateLogEntry: Identifiable {
    let id: String
    let timestamp: Date
    let applicationName: String
    let originalVersion: ApplicationVersion
    let targetVersion: ApplicationVersion?
    let sourceDisplayName: String
    let applicationPath: String?
    let downloadSize: Int64?
    let createdAt: Date
    let attemptCount: Int
    let state: ApplicationUpdateTaskState
    let detail: String?
    let errorDescription: String?
}

private struct AppUpdateLogRow: View {
    let entry: AppUpdateLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let applicationPath = entry.applicationPath {
                CachedAppIconView(path: applicationPath, size: 28) {
                    AppSymbolIcon(systemImage: "app", role: .inline)
                }
            } else {
                AppSymbolIcon(systemImage: "app.dashed", role: .inline)
                    .frame(width: 28, height: 28)
            }

            Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)

            Image(systemName: entry.state.systemImage)
                .foregroundStyle(entry.state.color)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.applicationName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(entry.state.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(entry.state.color)
                }
                Text(versionAndSourceText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .textSelection(.enabled)
                if entry.attemptCount > 0 {
                    Text(L10n.text(
                        "第 \(entry.attemptCount) 次尝试",
                        "Attempt \(entry.attemptCount)"
                    ))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                if let detail = entry.detail?.trimmed.nonEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let error = entry.errorDescription?.trimmed.nonEmpty {
                    HStack(alignment: .top) {
                        Text(error)
                            .font(.system(size: 11.5))
                            .foregroundStyle(AppDesignTokens.Palette.destructive)
                            .textSelection(.enabled)
                        Spacer()
                        AppButton(
                            title: L10n.text("复制错误", "Copy Error"),
                            systemImage: "doc.on.doc",
                            kind: .smallUtility,
                            controlSize: .small
                        ) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(error, forType: .string)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
    }

    private var versionAndSourceText: String {
        let versions = entry.targetVersion.map {
            "\(entry.originalVersion.display) → \($0.display)"
        } ?? entry.originalVersion.display
        let source = entry.sourceDisplayName.trimmed.nonEmpty
            ?? L10n.text("来源未知", "Unknown Source")
        return "\(versions) · \(source)"
    }
}

private extension AppScanStage {
    static let allPresentationStages: [Self] = [
        .discoveringApplications,
        .readingMetadata,
        .resolvingSources,
        .checkingVersions,
        .finishing,
    ]

    var presentationIndex: Int {
        Self.allPresentationStages.firstIndex(of: self) ?? 0
    }

    var title: String {
        switch self {
        case .discoveringApplications: L10n.text("查找已安装应用", "Discovering Installed Applications")
        case .readingMetadata: L10n.text("读取应用信息", "Reading Application Metadata")
        case .resolvingSources: L10n.text("识别更新来源", "Resolving Update Sources")
        case .checkingVersions: L10n.text("检查可用版本", "Checking Available Versions")
        case .finishing: L10n.text("整理扫描结果", "Finalizing Scan Results")
        }
    }

    var shortTitle: String {
        switch self {
        case .discoveringApplications: L10n.text("发现", "Discover")
        case .readingMetadata: L10n.text("信息", "Metadata")
        case .resolvingSources: L10n.text("来源", "Sources")
        case .checkingVersions: L10n.text("版本", "Versions")
        case .finishing: L10n.text("完成", "Finish")
        }
    }

    var detail: String {
        switch self {
        case .discoveringApplications:
            L10n.text("正在查找应用", "Finding applications")
        case .readingMetadata:
            L10n.text("正在读取应用信息", "Reading application details")
        case .resolvingSources:
            L10n.text("正在识别更新来源", "Identifying update sources")
        case .checkingVersions:
            L10n.text("正在检查最新版本", "Checking latest versions")
        case .finishing:
            L10n.text("正在整理结果", "Preparing results")
        }
    }

}

private extension AppUpdateCatalogFilter {
    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .automatic: L10n.text("自动更新", "Automatic")
        case .requiresQuit: L10n.text("退出后更新", "Quit First")
        case .requiresAuthorization: L10n.text("需要授权", "Authorization")
        case .manual: L10n.text("手动处理", "Manual")
        case .appStore: L10n.text("App Store", "App Store")
        case .inApplication: L10n.text("应用内更新", "In-App")
        case .website: L10n.text("官方网站", "Website")
        case .unknown: L10n.text("未知", "Unknown")
        }
    }
}

private extension AppUpdateCatalogCategory {
    var title: String {
        switch self {
        case .automatic: L10n.text("可直接自动更新", "Automatic Update")
        case .requiresQuit: L10n.text("退出后自动更新", "Automatic After Quit")
        case .requiresAuthorization: L10n.text("需要管理员授权", "Authorization Required")
        case .manual: L10n.text("需手动处理", "Manual Action")
        case .appStore: L10n.text("App Store", "App Store")
        case .inApplication: L10n.text("应用内更新", "In-App Updater")
        case .website: L10n.text("官方网站", "Official Website")
        case .unknown: L10n.text("能力未知", "Capability Unknown")
        case .systemManaged: L10n.text("由 macOS 管理", "Managed by macOS")
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "arrow.down.circle.fill"
        case .requiresQuit: "power.circle.fill"
        case .requiresAuthorization: "lock.shield.fill"
        case .manual: "hand.raised.fill"
        case .appStore: "apple.logo"
        case .inApplication: "arrow.up.forward.app"
        case .website: "safari"
        case .unknown: "questionmark.circle"
        case .systemManaged: "gearshape.2"
        }
    }

    var color: Color {
        switch self {
        case .automatic: .accentColor
        case .requiresQuit: .indigo
        case .requiresAuthorization: AppDesignTokens.Palette.warning
        case .manual: .orange
        case .appStore: .blue
        case .inApplication: .indigo
        case .website: .cyan
        case .unknown, .systemManaged: .secondary
        }
    }

    var presentationRank: Int {
        switch self {
        case .automatic: 0
        case .requiresQuit: 1
        case .requiresAuthorization: 2
        case .appStore: 3
        case .inApplication: 4
        case .website: 5
        case .manual: 6
        case .unknown: 7
        case .systemManaged: 8
        }
    }
}

private extension ApplicationUpdateTaskState {
    var title: String {
        switch self {
        case .queued: L10n.text("等待中", "Waiting")
        case .checking: L10n.text("正在检查", "Checking")
        case .downloading: L10n.text("正在下载", "Downloading")
        case .waitingForQuit: L10n.text("等待退出应用", "Waiting for App to Quit")
        case .waitingForAuthorization: L10n.text("等待授权", "Waiting for Authorization")
        case .installing: L10n.text("正在安装", "Installing")
        case .verifying: L10n.text("正在验证", "Verifying")
        case .completed: L10n.text("已完成", "Completed")
        case .skipped: L10n.text("已跳过", "Skipped")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .failed: L10n.text("失败", "Failed")
        case .needsReconciliation: L10n.text("需要重新核验", "Needs Reconciliation")
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .checking: "magnifyingglass"
        case .downloading: "arrow.down.circle"
        case .waitingForQuit: "power"
        case .waitingForAuthorization: "lock.shield"
        case .installing: "shippingbox"
        case .verifying, .needsReconciliation: "checkmark.shield"
        case .completed: "checkmark.circle.fill"
        case .skipped: "forward.circle"
        case .cancelled: "xmark.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .completed: AppDesignTokens.Palette.success
        case .failed: AppDesignTokens.Palette.destructive
        case .waitingForQuit, .waitingForAuthorization, .needsReconciliation:
            AppDesignTokens.Palette.warning
        case .cancelled, .skipped: .secondary
        case .queued, .checking, .downloading, .installing, .verifying: .accentColor
        }
    }
}

private extension AppUpdateReportOutcome {
    var title: String {
        switch self {
        case .allSucceeded: L10n.text("全部更新成功", "All Updates Succeeded")
        case .partialSuccess: L10n.text("部分更新成功", "Some Updates Succeeded")
        case .allFailed: L10n.text("更新未能完成", "Updates Could Not Complete")
        case .cancelled: L10n.text("更新已取消", "Updates Cancelled")
        case .noEligibleUpdates: L10n.text("没有可自动更新的项目", "No Eligible Automatic Updates")
        case .requiresAction: L10n.text("仍需完成部分操作", "Additional Action Required")
        }
    }

    var detail: String {
        switch self {
        case .allSucceeded:
            L10n.text("已核验安装版本。", "Installed versions verified.")
        case .partialSuccess:
            L10n.text("可重试失败项目。", "Retry failed items.")
        case .allFailed:
            L10n.text("请重试失败项目或查看日志。", "Retry failed items or view the log.")
        case .cancelled:
            L10n.text("可返回后重新开始。", "Return to start again.")
        case .noEligibleUpdates:
            L10n.text("请在对应更新入口完成。", "Complete updates in their listed entry points.")
        case .requiresAction:
            L10n.text("按项目提示完成后继续。", "Follow each item prompt to continue.")
        }
    }

    var systemImage: String {
        switch self {
        case .allSucceeded: "checkmark.circle.fill"
        case .partialSuccess: "checkmark.circle.badge.xmark"
        case .allFailed: "exclamationmark.triangle.fill"
        case .cancelled: "xmark.circle"
        case .noEligibleUpdates: "hand.raised.circle"
        case .requiresAction: "person.crop.circle.badge.exclamationmark"
        }
    }

    var color: Color {
        switch self {
        case .allSucceeded: AppDesignTokens.Palette.success
        case .partialSuccess, .requiresAction, .noEligibleUpdates: AppDesignTokens.Palette.warning
        case .allFailed: AppDesignTokens.Palette.destructive
        case .cancelled: .secondary
        }
    }
}

private extension AppUpdateReport {
    var logEntries: [AppUpdateLogEntry] {
        items.map { item in
            AppUpdateLogEntry(
                id: item.id.uuidString,
                timestamp: item.updatedAt,
                applicationName: item.displayName,
                originalVersion: item.originalVersion,
                targetVersion: item.targetVersion,
                sourceDisplayName: item.sourceDisplayName,
                applicationPath: item.applicationPath,
                downloadSize: item.downloadSize,
                createdAt: item.createdAt,
                attemptCount: item.attemptCount,
                state: item.state,
                detail: item.detail,
                errorDescription: item.errorDescription
            )
        }
    }
}

private extension AppUpdatePresentationPhase {
    var title: String {
        switch self {
        case .idle: L10n.text("空闲", "Idle")
        case .scanning: L10n.text("扫描中", "Scanning")
        case .scanSummary: L10n.text("扫描摘要", "Scan Summary")
        case .managing: L10n.text("管理更新", "Managing Updates")
        case .preparingUpdate: L10n.text("准备更新", "Preparing Updates")
        case .updating: L10n.text("更新中", "Updating")
        case .finalizing: L10n.text("最终核验", "Finalizing")
        case .completed: L10n.text("已完成", "Completed")
        case .cancelled: L10n.text("已取消", "Cancelled")
        case .failed: L10n.text("失败", "Failed")
        }
    }
}
