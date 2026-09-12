import SwiftUI

struct MacBenchmarkLeaderboardSection: View {
    private enum TableLayout {
        static let spacing: CGFloat = 10
        static let rankWidth: CGFloat = 48
        static let scoreWidth: CGFloat = 132
        static var detailColumns: [GridItem] {
            [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .topLeading)]
        }
    }

    @ObservedObject var store: MacBenchmarkLeaderboardStore
    let profile: BenchmarkProfile
    let results: [MacBenchmarkResult]

    @State private var showsRemovalConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            uploadStatus
            leaderboardContent
            Divider()
        }
        .padding(.horizontal, AppDesignTokens.Spacing.compact)
        .padding(.vertical, AppDesignTokens.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: profile) {
            await store.load(profile: profile)
        }
        .alert(
            L10n.text("移除公开成绩？", "Remove Public Result?"),
            isPresented: $showsRemovalConfirmation
        ) {
            Button(L10n.text("取消", "Cancel"), role: .cancel) {}
            Button(L10n.text("移除我的成绩", "Remove My Result"), role: .destructive) {
                Task { await store.removeMyEntry(profile: profile) }
            }
        } message: {
            Text(L10n.text(
                "只会移除社区榜单中的公开记录；本机性能测试历史不会被删除。",
                "Only the public community entry will be removed. Local benchmark history will remain."
            ))
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    leaderboardTitle
                    identityLabel
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    leaderboardTitle
                    identityLabel
                }
            }

            Label(
                L10n.text(
                    "用户 ID：\(store.automaticDisplayName)",
                    "User ID: \(store.automaticDisplayName)"
                ),
                systemImage: "person.crop.circle"
            )
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                if case .loading = store.loadState {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.text("正在刷新排行榜", "Refreshing leaderboard"))
                }
                Spacer(minLength: 0)

                AppButton(
                    title: L10n.text("刷新", "Refresh"),
                    systemImage: "arrow.clockwise",
                    kind: .secondary,
                    controlSize: .small,
                    isDisabled: isLoading || isLeaderboardMutationRunning
                ) {
                    Task { await store.load(profile: profile, force: true) }
                }

                if ownsVisibleEntry {
                    AppButton(
                        title: L10n.text("移除我的成绩", "Remove My Result"),
                        systemImage: "trash",
                        kind: .destructive,
                        controlSize: .small,
                        isDisabled: isLeaderboardMutationRunning
                    ) {
                        showsRemovalConfirmation = true
                    }
                }

                if case .failed = store.uploadState,
                   store.canUpload(results) {
                    AppButton(
                        title: L10n.text("重试上传", "Retry Upload"),
                        systemImage: "square.and.arrow.up",
                        kind: .primary,
                        controlSize: .small,
                        isDisabled: isLeaderboardMutationRunning
                    ) {
                        Task { await store.submitBestAutomatically(results) }
                    }
                }
            }
        }
    }

    private var leaderboardTitle: some View {
        Label(
            L10n.text("社区性能排行榜 · v6", "Community Benchmark Leaderboard · v6"),
            systemImage: "trophy.fill"
        )
        .font(AppDesignTokens.Typography.sectionTitle)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var identityLabel: some View {
        Label(
            L10n.text("社区上传 · 身份未验证", "Community · Unverified Identity"),
            systemImage: "person.2.badge.gearshape"
        )
        .font(AppDesignTokens.Typography.secondary)
        .foregroundStyle(AppDesignTokens.Palette.warning)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var uploadStatus: some View {
        switch store.uploadState {
        case .submitting:
            Label(
                L10n.text(
                    "有效成绩正在自动上传；本机历史已独立保存。",
                    "The valid result is uploading automatically; local history is stored separately."
                ),
                systemImage: "arrow.up.circle"
            )
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case let .succeeded(entryID):
            Label(
                L10n.text(
                    "成绩已公开显示，并已刷新排行榜。记录号：\(entryID.prefix(8))",
                    "The result is public and the leaderboard was refreshed. Entry: \(entryID.prefix(8))"
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(AppDesignTokens.Palette.success)
            .fixedSize(horizontal: false, vertical: true)
        case .removed:
            Label(
                L10n.text(
                    "公开成绩已移除；本机性能测试历史保持不变。",
                    "The public result was removed; local benchmark history is unchanged."
                ),
                systemImage: "checkmark.circle.fill"
            )
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(AppDesignTokens.Palette.success)
            .fixedSize(horizontal: false, vertical: true)
        case let .failed(failure):
            Label(failure.message, systemImage: "exclamationmark.triangle.fill")
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        case .idle, .removing:
            EmptyView()
        }
    }

    @ViewBuilder
    private var leaderboardContent: some View {
        if !store.entries.isEmpty, store.loadedProfile == profile {
            leaderboardTable
        } else {
            switch store.loadState {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.text("正在读取社区榜单…", "Loading community results…"))
                        .font(AppDesignTokens.Typography.secondary)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            case .loaded:
                ContentUnavailableView(
                    L10n.text("这个榜单还没有成绩", "No Results Yet"),
                    systemImage: "trophy",
                    description: Text(L10n.text(
                        "还没有 Standard v6 成绩。完成一次符合电源、温控和稳定性门禁的有效性能测试后，成绩会自动加入。",
                        "There are no Standard v6 results yet. Complete a valid run that passes the power, thermal, and stability gates to add it automatically."
                    ))
                )
                .frame(maxWidth: .infinity, minHeight: 120)
            case let .failed(failure):
                ContentUnavailableView(
                    L10n.text("排行榜未加载", "Leaderboard Not Loaded"),
                    systemImage: "wifi.exclamationmark",
                    description: Text(failure.message)
                )
                .frame(maxWidth: .infinity, minHeight: 120)
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
                    Divider().padding(
                        .leading,
                        TableLayout.rankWidth + TableLayout.spacing
                    )
                }
            }
            if store.totalEntryCount > store.entries.count {
                Divider()
                Text(L10n.text(
                    "显示前 \(store.entries.count) 名 · 共 \(store.totalEntryCount) 条成绩",
                    "Top \(store.entries.count) shown · \(store.totalEntryCount) total results"
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 9)
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
            Text(L10n.text("用户 ID", "User ID"))
                .frame(maxWidth: .infinity, alignment: .leading)
            tableHeader(
                MacBenchmarkPresentation.standardLeaderboardScoreTitle,
                width: TableLayout.scoreWidth,
                alignment: .trailing
            )
        }
        .font(AppDesignTokens.Typography.metadata)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppDesignTokens.Palette.secondaryBackground.opacity(0.55))
    }

    private func leaderboardRow(_ entry: MacBenchmarkLeaderboardEntry) -> some View {
        let isMine = entry.id == store.lastSubmittedEntryID
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: TableLayout.spacing) {
                Text("#\(entry.rank)")
                    .font(AppDesignTokens.Typography.dataValue)
                    .foregroundStyle(entry.rank <= 3 ? AppDesignTokens.Palette.warning : .secondary)
                    .monospacedDigit()
                    .frame(width: TableLayout.rankWidth, alignment: .leading)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.displayName)
                        .font(AppDesignTokens.Typography.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if isMine {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(AppDesignTokens.Palette.primary)
                            .help(L10n.text("本机最近上传的成绩", "Most recently uploaded from this Mac"))
                    }
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
                    title: L10n.text("处理器", "Processor"),
                    value: entry.processorModel
                )
                leaderboardDetail(
                    title: L10n.text("内存容量", "Memory Capacity"),
                    value: MacBenchmarkPresentation.capacityText(
                        entry.physicalMemoryBytes,
                        countStyle: .memory
                    )
                )
                leaderboardDetail(
                    title: L10n.text("硬盘容量", "Disk Capacity"),
                    value: MacBenchmarkPresentation.capacityText(
                        entry.systemDiskCapacityBytes,
                        countStyle: .file
                    )
                )
                leaderboardDetail(
                    title: L10n.text("完成时间", "Completed"),
                    value: entry.completedAt.formatted(date: .numeric, time: .shortened)
                )
            }
            .padding(.leading, TableLayout.rankWidth + TableLayout.spacing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isMine ? AppDesignTokens.Palette.selection.opacity(0.14) : .clear)
        .accessibilityElement(children: .combine)
    }

    private func leaderboardDetail(
        title: String,
        value: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(value)
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func tableHeader(
        _ text: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(text).frame(width: width, alignment: alignment)
    }

    private func scoreText(_ score: Double) -> String {
        String(Int(score.rounded()))
    }

    private var isLoading: Bool {
        if case .loading = store.loadState { return true }
        return false
    }

    private var isLeaderboardMutationRunning: Bool {
        switch store.uploadState {
        case .submitting, .removing: true
        case .idle, .succeeded, .removed, .failed: false
        }
    }

    private var ownsVisibleEntry: Bool {
        guard let id = store.lastSubmittedEntryID else { return false }
        return store.entries.contains { $0.id == id }
    }
}
