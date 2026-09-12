import Foundation
import SwiftUI

/// Shows enough local history context to identify a record without exposing
/// the full URL, path, query parameters, or parsed search keyword.
struct BrowserPrivacySafeRecordPresentation: Equatable {
    let title: String
    let location: String
    let domain: String
    let keyword: String
    let accessibilityLabel: String

    init(record: BrowserPrivacyRecord) {
        let displayDomain = Self.displayDomain(
            record.domain ?? record.url.flatMap { URLComponents(string: $0)?.host }
        )
        title = Self.sanitizedSummary(record.title)
            ?? L10n.text("未记录页面标题", "Page title unavailable")
        domain = displayDomain
        location = displayDomain == Self.unknownDomain
            ? L10n.text("网址信息不可用", "Address unavailable")
            : L10n.text(
                "\(displayDomain) · 仅显示域名，路径和查询参数未展示",
                "\(displayDomain) · domain only; path and query are not shown"
            )
        keyword = record.searchKeyword == nil
            ? L10n.text("没有可用的搜索关键词", "No search keyword available")
            : L10n.text("搜索关键词未展示", "Search keyword not shown")
        accessibilityLabel = L10n.text(
            "\(record.browser.displayName) 浏览记录，\(title)，域名 \(displayDomain)",
            "\(record.browser.displayName) history record, \(title), domain \(displayDomain)"
        )
    }

    static func displayDomain(_ domain: String?) -> String {
        sanitizedSummary(domain, maximumLength: 160)?.lowercased() ?? unknownDomain
    }

    static func maskedDomain(_ domain: String?) -> String {
        guard let domain else { return "•••" }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: true)
        guard labels.count >= 2 else { return "•••" }
        let visibleSuffix = labels.suffix(1).joined(separator: ".")
        let leading = labels.dropLast().map { label -> String in
            guard let first = label.first else { return "•" }
            return String(first) + String(repeating: "•", count: min(max(label.count - 1, 1), 8))
        }.joined(separator: ".")
        return "\(leading).\(visibleSuffix)"
    }

    private static var unknownDomain: String {
        L10n.text("未知网站", "Unknown site")
    }

    private static func sanitizedSummary(
        _ value: String?,
        maximumLength: Int = 120
    ) -> String? {
        guard let value else { return nil }
        let withoutControls = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let collapsed = withoutControls.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength - 1)) + "…"
    }
}

struct BrowserPrivacyRecordIdentityView: View {
    @Environment(\.moduleTheme) private var theme

    let item: BrowserPrivacyDisplayItem
    private let presentation: BrowserPrivacySafeRecordPresentation?

    init(item: BrowserPrivacyDisplayItem) {
        self.item = item
        presentation = item.records.first.map(BrowserPrivacySafeRecordPresentation.init)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            browserIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppDesignTokens.Spacing.micro) {
                    Text(item.browser.displayName)
                        .font(AppTypography.caption.weight(.semibold))
                        .foregroundStyle(AppDesignTokens.Palette.accent)
                    Text(item.profileDisplayName)
                        .font(AppTypography.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(presentation?.title ?? L10n.text("未记录页面标题", "Page title unavailable"))
                    .font(AppTypography.metadata.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(AppTypography.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var detail: String {
        let domain = presentation?.domain ?? BrowserPrivacySafeRecordPresentation.displayDomain(item.domain)
        let date = item.latestVisitedAt.map(BrowserPrivacyDateFormatter.string)
            ?? L10n.text("时间不可用", "Time unavailable")
        return L10n.text(
            "\(domain) · \(item.visitCount) 次访问 · \(date)",
            "\(domain) · \(item.visitCount) visits · \(date)"
        )
    }

    private var accessibilityLabel: String {
        let title = presentation?.title ?? L10n.text("未记录页面标题", "Page title unavailable")
        let domain = presentation?.domain ?? BrowserPrivacySafeRecordPresentation.displayDomain(item.domain)
        return L10n.text(
            "\(item.browser.displayName)，\(title)，\(domain)，\(item.visitCount) 次访问",
            "\(item.browser.displayName), \(title), \(domain), \(item.visitCount) visits"
        )
    }

    @ViewBuilder
    private var browserIcon: some View {
        if let path = item.browser.applicationURL?.path {
            CachedAppIconView(path: path, size: 32) {
                fallbackIcon
            }
        } else {
            fallbackIcon
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "safari")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(AppDesignTokens.Palette.accent)
            .frame(width: 32, height: 32)
            .background(AppDesignTokens.Palette.accent.opacity(0.12), in: RoundedRectangle(
                cornerRadius: AppDesignTokens.Radius.glassControl,
                style: .continuous
            ))
            .accessibilityHidden(true)
    }
}

enum BrowserPrivacyDateFormatter {
    static func string(_ date: Date) -> String {
        date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened)
                .locale(L10n.locale)
        )
    }
}
