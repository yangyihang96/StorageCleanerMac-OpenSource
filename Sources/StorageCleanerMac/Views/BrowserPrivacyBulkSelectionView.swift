import Foundation
import SwiftUI

enum BrowserPrivacyBulkSelectionScope: Hashable, Sendable {
    case today
    case last7Days
    case last30Days
    case olderThan30Days
    case website(String)
    case sensitive

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
        case .sensitive:
            L10n.text("敏感网站", "Sensitive websites")
        }
    }

    func matchingRecordIDs(
        in records: [BrowserPrivacyRecord],
        now: Date = Date(),
        calendar: Calendar = .current,
        disclosure: BrowserPrivacyDisclosurePolicy? = nil
    ) -> Set<UUID> {
        let disclosure = disclosure ?? .protecting(records)
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
                return !disclosure.isConcealed(record) && Self.normalizedDomain(record.domain) == Self.normalizedDomain(domain)
            case .sensitive:
                return record.locator != nil && disclosure.isConcealed(record)
            }
        }.map(\.id))
    }

    static func websiteOptions(
        from records: [BrowserPrivacyRecord],
        disclosure: BrowserPrivacyDisclosurePolicy? = nil
    ) -> [BrowserPrivacyWebsiteSelectionOption] {
        let disclosure = disclosure ?? .protecting(records)
        let counts = records.reduce(into: [String: Int]()) { result, record in
            guard record.selectionEligibility.canSelect,
                  !disclosure.isConcealed(record),
                  let domain = normalizedDomain(record.domain) else { return }
            result[domain, default: 0] += 1
        }
        var options = counts.map { BrowserPrivacyWebsiteSelectionOption(domain: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.domain.localizedCaseInsensitiveCompare(rhs.domain) == .orderedAscending
            }
        let concealed = records.count { $0.selectionEligibility.canSelect && disclosure.isConcealed($0) }
        if concealed > 0 {
            options.insert(.init(domain: L10n.text("敏感网站", "Sensitive websites"), count: concealed, isSensitive: true,
                hasDeletableRecord: records.contains { $0.locator != nil && $0.selectionEligibility.canSelect && disclosure.isConcealed($0) }), at: 0)
        }
        return options
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
    var isSensitive = false
    var hasDeletableRecord = true

    var id: String { isSensitive ? "sensitive-sites" : domain }
    var title: String { isSensitive ? BrowserPrivacyDisclosurePolicy.sensitiveSummary(count) : domain }
}

struct BrowserPrivacyBulkSelectionPresentation: Sendable {
    let websiteOptions: [BrowserPrivacyWebsiteSelectionOption]
    let dateCounts: [BrowserPrivacyBulkSelectionScope: Int]
    let dateSummaries: [BrowserPrivacyBulkSelectionScope: String]
    static let dateScopes: [BrowserPrivacyBulkSelectionScope] = [.today, .last7Days, .last30Days, .olderThan30Days]
    init(records: [BrowserPrivacyRecord], disclosure: BrowserPrivacyDisclosurePolicy) {
        websiteOptions = BrowserPrivacyBulkSelectionScope.websiteOptions(from: records, disclosure: disclosure)
        let now = Date()
        var counts: [BrowserPrivacyBulkSelectionScope: Int] = [:], summaries: [BrowserPrivacyBulkSelectionScope: String] = [:]
        for scope in Self.dateScopes {
            let ids = scope.matchingRecordIDs(in: records, now: now, disclosure: disclosure)
            let subset = records.filter { ids.contains($0.id) }
            counts[scope] = ids.count; summaries[scope] = disclosure.summary(subset)
        }
        dateCounts = counts; dateSummaries = summaries
    }
    func websiteOptions(matching query: String) -> [BrowserPrivacyWebsiteSelectionOption] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return websiteOptions.filter { $0.isSensitive || query.isEmpty || $0.domain.localizedCaseInsensitiveContains(query) }
    }
}

struct BrowserPrivacyBulkSelectionView: View {
    let isDisabled: Bool
    let onSelect: (BrowserPrivacyBulkSelectionScope) -> Void

    @State private var websiteQuery = ""

    private static let dateScopes = BrowserPrivacyBulkSelectionPresentation.dateScopes
    let presentation: BrowserPrivacyBulkSelectionPresentation

    init(
        records: [BrowserPrivacyRecord],
        isDisabled: Bool,
        disclosure: BrowserPrivacyDisclosurePolicy? = nil,
        onSelect: @escaping (BrowserPrivacyBulkSelectionScope) -> Void
    ) {
        self.isDisabled = isDisabled
        self.onSelect = onSelect
        presentation = .init(records: records, disclosure: disclosure ?? .protecting(records))
    }

    init(presentation: BrowserPrivacyBulkSelectionPresentation, isDisabled: Bool,
         onSelect: @escaping (BrowserPrivacyBulkSelectionScope) -> Void) {
        self.presentation = presentation; self.isDisabled = isDisabled; self.onSelect = onSelect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.micro) {
                Text(L10n.text("批量选择", "Bulk Select"))
                    .font(AppTypography.sectionTitle)
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

            ForEach(filteredWebsiteOptions.filter(\.isSensitive)) { option in
                websiteSelectionButton(option)
            }

            if filteredWebsiteOptions.isEmpty {
                Text(L10n.text("没有匹配的网站", "No matching websites"))
                    .font(AppTypography.caption)
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredWebsiteOptions.filter { !$0.isSensitive }) { option in
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
        presentation.websiteOptions(matching: websiteQuery)
    }

    private func dateSelectionButton(_ scope: BrowserPrivacyBulkSelectionScope) -> some View {
        let count = presentation.dateCounts[scope, default: 0]
        let summary = presentation.dateSummaries[scope] ?? BrowserPrivacyLightfieldPresentation.recordCount(0)
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
                Text(summary)
                    .font(AppTypography.caption.monospacedDigit())
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText)
            }
            .padding(.vertical, AppDesignTokens.Spacing.small)
            .contentShape(Rectangle())
        }
        .appButtonChrome(.toolbar)
        .disabled(isDisabled || count == 0)
        .accessibilityLabel(L10n.text(
            "选择\(scope.title)的 \(summary)",
            "Select \(summary) from \(scope.title)"
        ))
    }

    private func websiteSelectionButton(
        _ option: BrowserPrivacyWebsiteSelectionOption
    ) -> some View {
        Button {
            onSelect(option.isSensitive ? .sensitive : .website(option.domain))
        } label: {
            HStack(spacing: AppDesignTokens.Spacing.small) {
                Text(option.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: AppDesignTokens.Spacing.small)
                if !option.isSensitive { Text(BrowserPrivacyCountText.visits(option.count))
                    .font(AppTypography.caption.monospacedDigit())
                    .foregroundStyle(AppDesignTokens.Palette.secondaryText) }
            }
            .padding(.vertical, AppDesignTokens.Spacing.small)
            .contentShape(Rectangle())
        }
        .appButtonChrome(.toolbar)
        .disabled(isDisabled || (option.isSensitive && !option.hasDeletableRecord))
        .accessibilityLabel(option.isSensitive ? option.title : L10n.text(
            "选择网站 \(option.domain) 的 \(ByteFormat.count(option.count)) 次访问",
            "Select \(BrowserPrivacyCountText.visits(option.count)) for \(option.domain)"
        ))
    }

    private func dateSymbol(for scope: BrowserPrivacyBulkSelectionScope) -> String {
        switch scope {
        case .today: "calendar"
        case .last7Days: "calendar.badge.clock"
        case .last30Days: "calendar.circle"
        case .olderThan30Days: "calendar.badge.minus"
        case .website: "globe"
        case .sensitive: "lock"
        }
    }
}
