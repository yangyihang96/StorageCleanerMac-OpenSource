import Foundation
import SwiftUI

enum BrowserPrivacyBulkSelectionScope: Hashable, Sendable {
    case today
    case last7Days
    case last30Days
    case olderThan30Days
    case website(String)

    var title: String {
        switch self {
        case .today:
            L10n.text("今天", "Today")
        case .last7Days:
            L10n.text("最近 7 天", "Last 7 Days")
        case .last30Days:
            L10n.text("最近 30 天", "Last 30 Days")
        case .olderThan30Days:
            L10n.text("30 天以前", "Older Than 30 Days")
        case let .website(domain):
            domain
        }
    }

    func matchingRecordIDs(
        in records: [BrowserPrivacyRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Set<UUID> {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? now.addingTimeInterval(86_400)
        let startOfLast7Days = calendar.date(byAdding: .day, value: -6, to: startOfToday)
            ?? startOfToday
        let startOfLast30Days = calendar.date(byAdding: .day, value: -29, to: startOfToday)
            ?? startOfToday

        return Set(records.lazy.filter { record in
            guard record.selectionEligibility.canSelect else { return false }
            switch self {
            case .today:
                guard let visitedAt = record.visitedAt else { return false }
                return visitedAt >= startOfToday && visitedAt < startOfTomorrow
            case .last7Days:
                guard let visitedAt = record.visitedAt else { return false }
                return visitedAt >= startOfLast7Days && visitedAt < startOfTomorrow
            case .last30Days:
                guard let visitedAt = record.visitedAt else { return false }
                return visitedAt >= startOfLast30Days && visitedAt < startOfTomorrow
            case .olderThan30Days:
                guard let visitedAt = record.visitedAt else { return false }
                return visitedAt < startOfLast30Days
            case let .website(domain):
                return Self.normalizedDomain(record.domain) == Self.normalizedDomain(domain)
            }
        }.map(\.id))
    }

    static func websiteOptions(
        from records: [BrowserPrivacyRecord]
    ) -> [BrowserPrivacyWebsiteSelectionOption] {
        let counts = records.reduce(into: [String: Int]()) { result, record in
            guard record.selectionEligibility.canSelect,
                  let domain = normalizedDomain(record.domain) else { return }
            result[domain, default: 0] += 1
        }
        return counts.map { BrowserPrivacyWebsiteSelectionOption(domain: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
            }
    }

    private static func normalizedDomain(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}

struct BrowserPrivacyWebsiteSelectionOption: Identifiable, Equatable, Sendable {
    let domain: String
    let count: Int

    var id: String { domain }
}

struct BrowserPrivacyBulkSelectionView: View {
    let isDisabled: Bool
    let onSelect: (BrowserPrivacyBulkSelectionScope) -> Void

    @State private var websiteQuery = ""

    private static let dateScopes: [BrowserPrivacyBulkSelectionScope] = [
        .today,
        .last7Days,
        .last30Days,
        .olderThan30Days,
    ]
    private let websiteOptions: [BrowserPrivacyWebsiteSelectionOption]
    private let dateCounts: [BrowserPrivacyBulkSelectionScope: Int]

    init(
        records: [BrowserPrivacyRecord],
        isDisabled: Bool,
        onSelect: @escaping (BrowserPrivacyBulkSelectionScope) -> Void
    ) {
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        websiteOptions = BrowserPrivacyBulkSelectionScope.websiteOptions(from: records)
        let now = Date()
        dateCounts = Dictionary(uniqueKeysWithValues: Self.dateScopes.map { scope in
            (scope, scope.matchingRecordIDs(in: records, now: now).count)
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                Text(L10n.text("批量选择", "Bulk Select"))
                    .font(AppTypography.sectionTitle)
                Text(L10n.text(
                    "按日期或网站加入选择；不会立即删除。",
                    "Add records by date or website; nothing is deleted immediately."
                ))
                .font(AppTypography.caption)
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            }

            Divider()

            Text(L10n.text("按日期", "By Date"))
                .font(AppTypography.metadata)

            VStack(spacing: 0) {
                ForEach(Array(Self.dateScopes.enumerated()), id: \.element) { index, scope in
                    dateSelectionButton(scope)
                    if index < Self.dateScopes.count - 1 {
                        Divider()
                    }
                }
            }

            Divider()

            Text(L10n.text("按网站", "By Website"))
                .font(AppTypography.metadata)

            TextField(
                L10n.text("搜索网站域名", "Search website domains"),
                text: $websiteQuery
            )
            .textFieldStyle(.roundedBorder)

            if filteredWebsiteOptions.isEmpty {
                Text(L10n.text("没有匹配的网站", "No matching websites"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredWebsiteOptions) { option in
                            websiteSelectionButton(option)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 210)
            }
        }
        .padding(AppDesignTokens.Spacing.medium)
        .frame(width: 360)
        .accessibilityElement(children: .contain)
    }

    private var filteredWebsiteOptions: [BrowserPrivacyWebsiteSelectionOption] {
        let query = websiteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return websiteOptions }
        return websiteOptions.filter { $0.domain.localizedCaseInsensitiveContains(query) }
    }

    private func dateSelectionButton(_ scope: BrowserPrivacyBulkSelectionScope) -> some View {
        let count = dateCounts[scope, default: 0]
        return Button {
            onSelect(scope)
        } label: {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Image(systemName: dateSymbol(for: scope))
                    .frame(width: 18)
                    .foregroundStyle(AppDesignTokens.Palette.accent)
                    .accessibilityHidden(true)
                Text(scope.title)
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Text(L10n.text("\(count) 项", "\(count) items"))
                    .font(AppTypography.caption.monospacedDigit())
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            }
            .padding(.vertical, AppDesignTokens.Spacing.small)
            .contentShape(Rectangle())
        }
        .appButtonChrome(.toolbar)
        .disabled(isDisabled || count == 0)
        .accessibilityLabel(L10n.text(
            "选择\(scope.title)的 \(count) 项浏览记录",
            "Select \(count) browsing records from \(scope.title)"
        ))
    }

    private func websiteSelectionButton(
        _ option: BrowserPrivacyWebsiteSelectionOption
    ) -> some View {
        Button {
            onSelect(.website(option.domain))
        } label: {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Image(systemName: "globe")
                    .frame(width: 18)
                    .foregroundStyle(AppDesignTokens.Palette.accent)
                    .accessibilityHidden(true)
                Text(option.domain)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AppDesignTokens.Spacing.small)
                Text(L10n.text("\(option.count) 项", "\(option.count) items"))
                    .font(AppTypography.caption.monospacedDigit())
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            }
            .padding(.vertical, AppDesignTokens.Spacing.small)
            .contentShape(Rectangle())
        }
        .appButtonChrome(.toolbar)
        .disabled(isDisabled)
        .accessibilityLabel(L10n.text(
            "选择网站 \(option.domain) 的 \(option.count) 项浏览记录",
            "Select \(option.count) browsing records for \(option.domain)"
        ))
    }

    private func dateSymbol(for scope: BrowserPrivacyBulkSelectionScope) -> String {
        switch scope {
        case .today: "calendar"
        case .last7Days: "calendar.badge.clock"
        case .last30Days: "calendar.circle"
        case .olderThan30Days: "calendar.badge.minus"
        case .website: "globe"
        }
    }
}
