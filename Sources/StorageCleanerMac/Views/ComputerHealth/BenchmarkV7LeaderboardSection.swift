import AppKit
import SwiftUI

struct BenchmarkV7LeaderboardSection: View {
    private enum TableLayout {
        static let spacing: CGFloat = 10
        static let rankWidth: CGFloat = 52
        static let scoreWidth: CGFloat = 112
        static var detailColumns: [GridItem] {
            [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .topLeading)]
        }
    }

    @ObservedObject var store: BenchmarkV7LeaderboardStore
    let results: [BenchmarkV7Result]

    @State private var showsPublishConfirmation = false
    @State private var showsRemovalConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            header
            eligibilityStatus
            mutationStatus
            leaderboardContent
        }
        .padding(AppDesignTokens.Layout.sectionPadding)
        .glassPanel(
            cornerRadius: AppDesignTokens.Layout.cardRadius,
            tint: AppDesignTokens.Palette.primary.opacity(0.035)
        )
        .task {
            await store.loadFirst(force: false)
        }
        .confirmationDialog(
            publishActionTitle,
            isPresented: $showsPublishConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("确认发布", "Confirm Publish")) {
                Task { await store.submitBest(results) }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(publishConfirmationMessage)
        }
        .confirmationDialog(
            L10n.text("移除公开成绩？", "Remove Public Result?"),
            isPresented: $showsRemovalConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.text("移除我的成绩", "Remove My Result"), role: .destructive) {
                Task { await store.removeMyEntry() }
            }
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.text(
                "只会移除全球排行榜中的公开记录；本机性能测试结果和历史记录不会被删除。",
                "Only the public global leaderboard entry will be removed. Local benchmark results and history will remain."
            ))
        }
        .onChange(of: store.loadState, initial: false) { _, state in
            announce(loadAnnouncement(for: state))
        }
        .onChange(of: store.mutationState, initial: false) { _, state in
            announce(mutationAnnouncement(for: state))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: AppDesignTokens.Spacing.medium) {
                    titleAndScope
                    Spacer(minLength: AppDesignTokens.Spacing.medium)
                    actions
                }
                VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
                    titleAndScope
                    actions
                }
            }

            HStack(spacing: AppDesignTokens.Spacing.small) {
                if let generatedAt = store.generatedAt {
                    Text(L10n.text(
                        "更新于 \(generatedAt.formatted(date: .numeric, time: .shortened))",
                        "Updated \(generatedAt.formatted(date: .numeric, time: .shortened))"
                    ))
                } else {
                    Text(L10n.text("尚未更新", "Not updated yet"))
                }
                Text("·")
                Text(L10n.text(
                    "共 \(store.total) 台参与设备",
                    "\(store.total) participating Macs"
                ))
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("正在刷新全球排行榜", "Refreshing global ranking"))
                }
            }
            .font(AppDesignTokens.Typography.metadata)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var titleAndScope: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Image(systemName: "globe.asia.australia.fill")
                    .foregroundStyle(AppDesignTokens.Palette.primary)
                    .accessibilityHidden(true)
                Text(L10n.text("全球 Mac 排行榜", "Global Mac Leaderboard"))
                    .font(AppDesignTokens.Typography.cardTitle)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Text(L10n.text(
                "主动参与且通过资格校验的 Mac 成绩。",
                "Scores from Macs that opted in and passed eligibility checks."
            ))
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: AppDesignTokens.Spacing.small) {
            AppButton(
                title: L10n.text("刷新", "Refresh"),
                systemImage: "arrow.clockwise",
                kind: .secondary,
                controlSize: .small,
                isDisabled: isLoading
            ) {
                Task { await store.loadFirst(force: true) }
            }

            if canPublish {
                AppButton(
                    title: publishActionTitle,
                    systemImage: "square.and.arrow.up",
                    kind: .primary,
                    controlSize: .small,
                    isDisabled: isMutationRunning
                ) {
                    showsPublishConfirmation = true
                }
            }

            if store.lastSubmittedEntryID != nil {
                AppButton(
                    title: L10n.text("移除我的成绩", "Remove My Result"),
                    systemImage: "trash",
                    kind: .destructive,
                    controlSize: .small,
                    isDisabled: isMutationRunning
                ) {
                    showsRemovalConfirmation = true
                }
            }
        }
    }

    private var eligibilityStatus: some View {
        let status = eligibilityPresentation
        return statusLabel(status.text, systemImage: status.symbol, color: status.color)
    }

    @ViewBuilder
    private var mutationStatus: some View {
        switch store.mutationState {
        case .idle:
            EmptyView()
        case .submitting:
            statusLabel(
                L10n.text("正在发布匿名成绩…", "Publishing anonymous result…"),
                systemImage: "arrow.up.circle",
                color: .secondary
            )
        case .submitted:
            statusLabel(
                L10n.text(
                    "已发布，名次稍后更新。",
                    "Published; rank updates shortly."
                ),
                systemImage: "checkmark.circle.fill",
                color: AppDesignTokens.Palette.success
            )
        case .removing:
            statusLabel(
                L10n.text("正在移除公开成绩…", "Removing public result…"),
                systemImage: "trash",
                color: .secondary
            )
        case .removed:
            statusLabel(
                L10n.text(
                    "公开成绩已移除；本机历史记录保持不变。",
                    "The public result was removed. Local history remains unchanged."
                ),
                systemImage: "checkmark.circle.fill",
                color: AppDesignTokens.Palette.success
            )
        case let .failed(failure):
            statusLabel(
                failure.message,
                systemImage: "exclamationmark.triangle.fill",
                color: AppDesignTokens.Palette.warning
            )
        }
    }

    @ViewBuilder
    private var leaderboardContent: some View {
        if store.entries.isEmpty {
            emptyLeaderboardContent
        } else {
            if let failure = loadFailure {
                staleResultsBanner(failure)
            }
            leaderboardTable
            if store.hasMore {
                AppButton(
                    title: L10n.text("加载更多", "Load More"),
                    systemImage: "arrow.down.circle",
                    kind: .secondary,
                    isLoading: isLoadingMore,
                    isDisabled: isLoading
                ) {
                    Task { await store.loadMore() }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private var emptyLeaderboardContent: some View {
        switch store.loadState {
        case .idle, .loading, .loadingMore:
            HStack(spacing: AppDesignTokens.Spacing.small) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
                Text(L10n.text("正在读取全球排行榜…", "Loading global ranking…"))
            }
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.text("正在读取全球排行榜", "Loading global ranking"))
        case .loaded:
            ContentUnavailableView(
                L10n.text("暂无公开成绩", "No Public Results Yet"),
                systemImage: "trophy",
                description: Text(L10n.text(
                    "完成当前 V7 官方测试并通过资格校验后，可在确认公开字段后参与排名。",
                    "Complete the current official V7 benchmark and pass its eligibility checks, then confirm the public fields to participate."
                ))
            )
            .frame(maxWidth: .infinity, minHeight: 140)
        case let .failed(failure):
            VStack(spacing: AppDesignTokens.Spacing.small) {
                ContentUnavailableView(
                    L10n.text("排行榜未加载", "Leaderboard Not Loaded"),
                    systemImage: "wifi.exclamationmark",
                    description: Text(failure.message)
                )
                AppButton(
                    title: L10n.text("重试", "Retry"),
                    systemImage: "arrow.clockwise",
                    kind: .secondary
                ) {
                    Task { await store.loadFirst(force: true) }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private func staleResultsBanner(_ failure: BenchmarkV7LeaderboardFailure) -> some View {
        let generatedText = store.generatedAt.map {
            $0.formatted(date: .numeric, time: .shortened)
        } ?? L10n.text("上次更新", "the last update")
        return VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.small) {
            statusLabel(
                L10n.text(
                    "无法刷新，正在显示 \(generatedText) 的数据。\(failure.message)",
                    "Unable to refresh. Showing data from \(generatedText). \(failure.message)"
                ),
                systemImage: "wifi.exclamationmark",
                color: AppDesignTokens.Palette.warning
            )
            AppButton(
                title: L10n.text("重试刷新", "Retry Refresh"),
                systemImage: "arrow.clockwise",
                kind: .secondary,
                controlSize: .small
            ) {
                Task { await store.loadFirst(force: true) }
            }
        }
    }

    private var leaderboardTable: some View {
        VStack(spacing: 0) {
            leaderboardHeader
            Divider()
            ForEach(store.entries) { entry in
                leaderboardRow(entry)
                if entry.id != store.entries.last?.id {
                    Divider().padding(.leading, TableLayout.rankWidth + TableLayout.spacing)
                }
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private var leaderboardHeader: some View {
        HStack(spacing: TableLayout.spacing) {
            tableHeader(
                L10n.text("名次", "Rank"),
                width: TableLayout.rankWidth,
                alignment: .leading
            )
            Text(L10n.text("电脑机型", "Computer model"))
                .frame(maxWidth: .infinity, alignment: .leading)
            tableHeader(
                L10n.text("总分", "Total score"),
                width: TableLayout.scoreWidth,
                alignment: .trailing
            )
        }
        .font(AppDesignTokens.Typography.metadata)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppDesignTokens.Palette.secondaryBackground.opacity(0.55))
        .accessibilityAddTraits(.isHeader)
    }

    private func leaderboardRow(_ entry: BenchmarkV7LeaderboardEntry) -> some View {
        let isMine = entry.id == store.lastSubmittedEntryID
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: TableLayout.spacing) {
                Text("#\(entry.rank)")
                    .font(AppDesignTokens.Typography.dataValue)
                    .foregroundStyle(entry.rank <= 3 ? AppDesignTokens.Palette.warning : .secondary)
                    .monospacedDigit()
                    .frame(width: TableLayout.rankWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(entry.computerModel)
                            .font(AppDesignTokens.Typography.secondary.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        if isMine {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(AppDesignTokens.Palette.primary)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(entry.displayName)
                        .font(AppDesignTokens.Typography.metadata)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Text(scoreText(entry.score))
                    .font(AppDesignTokens.Typography.dataValue)
                    .monospacedDigit()
                    .frame(width: TableLayout.scoreWidth, alignment: .trailing)
            }

            LazyVGrid(
                columns: TableLayout.detailColumns,
                alignment: .leading,
                spacing: 8
            ) {
                leaderboardDetail(
                    title: L10n.text("芯片", "Chip"),
                    value: entry.processorModel
                )
                leaderboardDetail(
                    title: L10n.text("内存", "Memory"),
                    value: "\(entry.memoryGB) GB"
                )
                leaderboardDetail(
                    title: L10n.text("测试日期", "Test date"),
                    value: entry.completedOn
                )
            }
            .padding(.leading, TableLayout.rankWidth + TableLayout.spacing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isMine ? AppDesignTokens.Palette.selection.opacity(0.14) : .clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(rowAccessibilityLabel(entry, isMine: isMine))
    }

    private func leaderboardDetail(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tableHeader(_ text: String, width: CGFloat, alignment: Alignment) -> some View {
        Text(text).frame(width: width, alignment: alignment)
    }

    private func statusLabel(
        _ text: String,
        systemImage: String,
        color: Color
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppDesignTokens.Spacing.small) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(text)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    private func rowAccessibilityLabel(
        _ entry: BenchmarkV7LeaderboardEntry,
        isMine: Bool
    ) -> String {
        var parts = [
            L10n.text("名次 \(entry.rank)", "Rank \(entry.rank)"),
            L10n.text("电脑机型 \(entry.computerModel)", "Computer model \(entry.computerModel)"),
            L10n.text("芯片 \(entry.processorModel)", "Chip \(entry.processorModel)"),
            L10n.text("内存 \(entry.memoryGB) GB", "Memory \(entry.memoryGB) GB"),
            L10n.text("总分 \(scoreText(entry.score))", "Total score \(scoreText(entry.score))"),
            L10n.text("测试日期 \(entry.completedOn)", "Test date \(entry.completedOn)"),
            L10n.text("匿名名称 \(entry.displayName)", "Anonymous name \(entry.displayName)"),
        ]
        if isMine {
            parts.append(L10n.text("我的公开成绩", "My public result"))
        }
        return parts.joined(separator: L10n.text("，", ", "))
    }

    private var eligibilityPresentation: (text: String, symbol: String, color: Color) {
        if let draft = publishDraft {
            if store.isConfigured {
                return (
                    L10n.text(
                        "最佳成绩 \(scoreText(draft.score)) 符合排行资格，确认后发布。",
                        "Best score \(scoreText(draft.score)) is eligible; published after confirmation."
                    ),
                    "checkmark.shield",
                    AppDesignTokens.Palette.success
                )
            }
            return (
                BenchmarkV7LeaderboardFailure.notConfigured.message,
                "exclamationmark.triangle",
                AppDesignTokens.Palette.warning
            )
        }
        if results.isEmpty {
            return (
                L10n.text(
                    "完成一次当前 V7 官方性能测试后，可检查是否符合排行资格。",
                    "Complete the current official V7 benchmark to check ranking eligibility."
                ),
                "info.circle",
                .secondary
            )
        }
        return ineligibilityPresentation
    }

    private var ineligibilityPresentation: (text: String, symbol: String, color: Color) {
        guard let result = results.max(by: {
            ($0.coreScore?.overallScore ?? 0) < ($1.coreScore?.overallScore ?? 0)
        }) else {
            return (
                L10n.text(
                    "当前保存的成绩未通过 V7 官方排行资格。",
                    "Saved results are not eligible for the official V7 ranking."
                ),
                "exclamationmark.triangle",
                AppDesignTokens.Palette.warning
            )
        }

        if !result.isComplete {
            return (
                L10n.text(
                    "最近一次测试未完整完成，因此暂不符合排行资格；请重新运行完整测试。",
                    "The latest test did not complete fully, so it is not eligible yet; run the full test again."
                ),
                "exclamationmark.triangle",
                AppDesignTokens.Palette.warning
            )
        }

        let preflight = result.preflight
        if preflight.powerSource != .acPower {
            return (
                L10n.text(
                    "测试时未接通电源；请接通电源后重新运行完整测试。",
                    "The test did not run on AC power. Connect power and run the full test again."
                ),
                "bolt.slash",
                AppDesignTokens.Palette.warning
            )
        }
        if preflight.lowPowerModeEnabled {
            return (
                L10n.text(
                    "测试时开启了低电量模式；请关闭低电量模式后重新运行完整测试。",
                    "Low Power Mode was enabled during the test. Turn it off and run the full test again."
                ),
                "leaf",
                AppDesignTokens.Palette.warning
            )
        }
        if preflight.thermalState != .nominal {
            return (
                L10n.text(
                    "测试时系统温度未处于正常范围；请在温度恢复正常后重新运行完整测试。",
                    "The Mac was not at a nominal thermal state during the test. Wait for normal temperatures and run the full test again."
                ),
                "thermometer.high",
                AppDesignTokens.Palette.warning
            )
        }

        if result.versions != BenchmarkV7LeaderboardConstants.currentVersions {
            return (
                L10n.text(
                    "成绩使用旧版测试协议，与当前 V7 官方排行不兼容；请重新运行完整测试。",
                    "This result uses an older benchmark protocol and is incompatible with the current official V7 ranking; run the full test again."
                ),
                "arrow.triangle.2.circlepath",
                AppDesignTokens.Palette.warning
            )
        }

        return (
            L10n.text(
                "当前保存的成绩未通过 V7 官方排行资格；请重新运行完整测试。",
                "Saved results are not eligible for the official V7 ranking; run the full test again."
            ),
            "exclamationmark.triangle",
            AppDesignTokens.Palette.warning
        )
    }

    private var publishDraft: BenchmarkV7LeaderboardDraft? {
        store.bestDraft(in: results)
    }

    private var canPublish: Bool {
        store.canSubmit(results)
    }

    private var publishActionTitle: String {
        store.lastSubmittedEntryID == nil
            ? L10n.text("发布我的最佳成绩", "Publish My Best Score")
            : L10n.text("更新我的最佳成绩", "Update My Best Score")
    }

    private var publishConfirmationMessage: String {
        guard let draft = publishDraft else {
            return BenchmarkV7LeaderboardFailure.incompatibleResult.message
        }
        return L10n.text(
            "将公开匿名名称“\(store.anonymousDisplayName)”、电脑机型“\(draft.computerModel)”、芯片“\(draft.processorModel)”、内存 \(draft.memoryGB) GB、总分 \(scoreText(draft.score))、测试日期 \(draft.completedAt.formatted(date: .numeric, time: .omitted)) 和协议 \(draft.versions.planVersion)。应用不会提交电脑名称、序列号、硬件 UUID、IP 地址或本机路径；Cloudflare 会为传输和滥用限流处理连接 IP，但不会把它放入公开榜单。服务还会接收测试指标、测试条件与随机安装标识，用于校验、更新和删除，但不会在榜单公开这些内容。",
            "The public entry will include the anonymous name “\(store.anonymousDisplayName)”, computer model “\(draft.computerModel)”, chip “\(draft.processorModel)”, \(draft.memoryGB) GB memory, total score \(scoreText(draft.score)), test date \(draft.completedAt.formatted(date: .numeric, time: .omitted)), and protocol \(draft.versions.planVersion). The app does not send computer name, serial number, hardware UUID, IP address, or local paths as submission fields. Cloudflare processes the connection IP for transport and abuse rate limiting, but it is not included in the public leaderboard. The service also receives benchmark metrics, test conditions, and a random installation identifier for validation, updates, and removal, but does not show them publicly."
        )
    }

    private var isLoading: Bool {
        switch store.loadState {
        case .loading, .loadingMore: true
        case .idle, .loaded, .failed: false
        }
    }

    private var isLoadingMore: Bool {
        if case .loadingMore = store.loadState { return true }
        return false
    }

    private var isMutationRunning: Bool {
        switch store.mutationState {
        case .submitting, .removing: true
        case .idle, .submitted, .removed, .failed: false
        }
    }

    private var loadFailure: BenchmarkV7LeaderboardFailure? {
        if case let .failed(failure) = store.loadState { return failure }
        return nil
    }

    private func loadAnnouncement(
        for state: BenchmarkV7LeaderboardLoadState
    ) -> String? {
        switch state {
        case .loading:
            L10n.text("正在刷新全球排行榜", "Refreshing global ranking")
        case .loadingMore:
            L10n.text("正在加载更多排名", "Loading more rankings")
        case .loaded:
            L10n.text(
                "全球排行榜已更新，共 \(store.total) 台参与设备",
                "Global ranking updated with \(store.total) participating Macs"
            )
        case let .failed(failure):
            failure.message
        case .idle:
            nil
        }
    }

    private func mutationAnnouncement(
        for state: BenchmarkV7LeaderboardMutationState
    ) -> String? {
        switch state {
        case .submitting:
            L10n.text("正在发布匿名成绩", "Publishing anonymous result")
        case .submitted:
            L10n.text("成绩已发布", "Result published")
        case .removing:
            L10n.text("正在移除公开成绩", "Removing public result")
        case .removed:
            L10n.text("公开成绩已移除", "Public result removed")
        case let .failed(failure):
            failure.message
        case .idle:
            nil
        }
    }

    private func announce(_ message: String?) {
        guard let message, !message.isEmpty else { return }
        AccessibilityNotification.Announcement(message).post()
    }

    private func scoreText(_ score: Double) -> String {
        String(Int(score.rounded()))
    }
}
