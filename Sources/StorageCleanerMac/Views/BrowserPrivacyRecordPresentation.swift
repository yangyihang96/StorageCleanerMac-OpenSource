import Foundation
import SwiftUI

/// How one history address is shown (decision D20: every row must say which
/// site and which page it is).
///
/// The row shows the site and path. Query parameters and fragments can carry
/// tokens, so they are folded ("?…", "#…", or left out for web pages) until
/// the user expands the row or copies the address; a tooltip never shows
/// them. Text is stripped of control characters and bounded before it
/// reaches a view; nothing here is persisted, exported or logged.
struct BrowserPrivacyAddressPresentation: Equatable, Sendable {
    /// Site and path for web pages; the original address for other schemes.
    let collapsed: String
    /// The complete address. Nil when the browser recorded none.
    let full: String?
    /// False when neither an address nor a site is known.
    let isAvailable: Bool

    /// True when `full` shows something the collapsed form leaves out.
    var hasFoldedDetail: Bool {
        guard let full else { return false }
        return full != collapsed
    }

    init(url: String?, domain: String?) {
        let address = BrowserPrivacyDisplayText.sanitized(url, maximumLength: Self.fullLengthLimit)
        if let address {
            full = address
            collapsed = Self.collapsed(address)
            isAvailable = true
        } else if let site = BrowserPrivacyDisplayText.sanitized(domain, maximumLength: 253) {
            full = nil
            collapsed = site.lowercased()
            isAvailable = true
        } else {
            full = nil
            collapsed = L10n.text("网址不可用", "Address unavailable")
            isAvailable = false
        }
    }

    private static let fullLengthLimit = 2_048
    private static let foldedQuery = "?…"
    private static let foldedFragment = "#…"

    private static func collapsed(_ address: String) -> String {
        if let components = URLComponents(string: address),
           let scheme = components.scheme?.lowercased(),
           scheme == "http" || scheme == "https",
           let host = components.host, !host.isEmpty {
            var text = host.lowercased()
            if let port = components.port {
                text += ":\(port)"
            }
            // The decoded path reads as the page name; fall back to the
            // stored spelling when it does not decode.
            let path = components.path.isEmpty ? components.percentEncodedPath : components.path
            if path != "/" {
                text += BrowserPrivacyDisplayText.sanitized(path, maximumLength: fullLengthLimit) ?? ""
            }
            let hasQuery = !(components.percentEncodedQuery ?? "").isEmpty
            return hasQuery ? text + foldedQuery : text
        }
        // chrome://, file://, about: and addresses that do not parse keep
        // their own spelling; only what follows a "?" or a "#" is folded,
        // since a fragment can carry a token too (an OAuth access_token, for
        // example).
        guard let cut = address.firstIndex(where: { $0 == "?" || $0 == "#" }),
              address.index(after: cut) < address.endIndex else {
            return address
        }
        return String(address[..<cut]) + (address[cut] == "?" ? foldedQuery : foldedFragment)
    }
}

/// What a result row says about one page.
struct BrowserPrivacyRecordPresentation: Equatable, Sendable {
    let browserName: String
    let profileName: String
    /// The recorded page title, or the address when there is none.
    let title: String
    let hasRecordedTitle: Bool
    let address: BrowserPrivacyAddressPresentation
    /// Nil for categories that say nothing about the page.
    let category: String?
    let visitCount: Int
    let latestVisit: String?
    let accessibilityLabel: String

    init(item: BrowserPrivacyDisplayItem, disclosure: BrowserPrivacyDisclosurePolicy = .init()) {
        self.init(
            browserName: item.browser.displayName,
            profileName: item.profileDisplayName,
            title: item.title,
            url: item.address,
            domain: item.domain,
            category: item.category,
            visitCount: item.visitCount,
            latestVisitedAt: item.latestVisitedAt,
            concealed: item.records.contains(where: disclosure.isConcealed)
        )
    }

    init(record: BrowserPrivacyRecord, disclosure: BrowserPrivacyDisclosurePolicy = .init()) {
        self.init(
            browserName: record.browser.displayName,
            profileName: record.resolvedProfileDisplayName,
            title: record.title,
            url: record.url,
            domain: record.domain,
            category: record.category,
            visitCount: 1,
            latestVisitedAt: record.visitedAt,
            concealed: disclosure.isConcealed(record)
        )
    }

    private init(
        browserName: String,
        profileName: String,
        title: String?,
        url: String?,
        domain: String?,
        category: BrowserPrivacyCategory,
        visitCount: Int,
        latestVisitedAt: Date?,
        concealed: Bool
    ) {
        self.browserName = browserName
        self.profileName = profileName
        if concealed {
            address = BrowserPrivacyAddressPresentation(url: nil, domain: nil)
            self.title = BrowserPrivacyDisclosurePolicy.sensitiveSummary(visitCount)
            hasRecordedTitle = false; self.category = nil; self.visitCount = visitCount
            latestVisit = nil; accessibilityLabel = self.title
            return
        }
        address = BrowserPrivacyAddressPresentation(url: url, domain: domain)
        let recordedTitle = BrowserPrivacyDisplayText.sanitized(title, maximumLength: 160)
        hasRecordedTitle = recordedTitle != nil
        self.title = recordedTitle ?? address.collapsed
        self.category = category.isInformative ? category.title : nil
        self.visitCount = visitCount
        latestVisit = latestVisitedAt.map(BrowserPrivacyDateFormatter.string)
        accessibilityLabel = [
            browserName,
            profileName,
            self.title,
            hasRecordedTitle ? address.collapsed : nil,
            BrowserPrivacyCountText.visits(visitCount),
            latestVisit.map { L10n.text("最近 \($0)", "latest \($0)") },
        ]
        .compactMap { $0 }
        .joined(separator: L10n.text("，", ", "))
    }

    /// The line below the address: category, visit count and latest time.
    var summary: String {
        [
            category,
            BrowserPrivacyCountText.visits(visitCount),
            latestVisit.map { L10n.text("最近 \($0)", "latest \($0)") }
                ?? L10n.text("时间不可用", "time unavailable"),
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    /// Why a row matched the search when the matching text is not on the row:
    /// the search term inside the folded query, another folded part of the
    /// address, or a category the row does not print.
    static func searchHint(
        for item: BrowserPrivacyDisplayItem,
        query: String,
        keywordFilter: String = "",
        disclosure: BrowserPrivacyDisclosurePolicy = .init()
    ) -> String? {
        if item.records.contains(where: disclosure.isConcealed) {
            return BrowserPrivacyDisclosurePolicy.sensitiveSummary(item.visitCount)
        }
        let keywords = item.searchKeywords
        func keywordHint(_ keyword: String) -> String {
            let shown = BrowserPrivacyDisplayText.sanitized(keyword, maximumLength: 80) ?? keyword
            return L10n.text("命中搜索词：\(shown)", "Matched search term: \(shown)")
        }

        let keywordQuery = BrowserPrivacySearchText.normalized(keywordFilter)
        if !keywordQuery.isEmpty,
           let keyword = keywords.first(where: {
               BrowserPrivacySearchText.normalized($0).contains(keywordQuery)
           }) {
            return keywordHint(keyword)
        }

        let normalizedQuery = BrowserPrivacySearchText.normalized(query)
        guard !normalizedQuery.isEmpty else { return nil }
        func contains(_ value: String?) -> Bool {
            guard let value else { return false }
            return BrowserPrivacySearchText.normalized(value).contains(normalizedQuery)
        }

        let presentation = BrowserPrivacyRecordPresentation(item: item)
        let visible: [String?] = [
            presentation.browserName,
            presentation.profileName,
            presentation.title,
            presentation.address.collapsed,
            item.category.isInformative ? item.category.localizedNames.chinese : nil,
            item.category.isInformative ? item.category.localizedNames.english : nil,
        ]
        if visible.contains(where: contains) { return nil }
        if let keyword = keywords.first(where: { contains($0) }) {
            return keywordHint(keyword)
        }
        if item.records.contains(where: { contains($0.url) || contains($0.url?.removingPercentEncoding) }) {
            return L10n.text(
                "网址的参数里包含搜索内容，展开可查看完整网址",
                "The search text is inside the address parameters; expand to see the full address"
            )
        }
        if contains(item.category.localizedNames.chinese) || contains(item.category.localizedNames.english) {
            return L10n.text("类别：\(item.category.title)", "Category: \(item.category.title)")
        }
        return nil
    }
}

/// One line of an expanded row.
struct BrowserPrivacyVisitPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let time: String
    /// What distinguishes this visit from the row: its "#fragment" and, when
    /// the browser recorded a different title for it, that title.
    let detail: String?

    static let displayLimit = 50

    /// The newest visits of a page, at most `displayLimit`.
    static func visits(of item: BrowserPrivacyDisplayItem) -> [Self] {
        let rowTitle = BrowserPrivacyDisplayText.sanitized(item.title, maximumLength: 160)
        return item.records.prefix(displayLimit).map { record in
            var details: [String] = []
            if let url = record.url,
               let fragment = URLComponents(string: url)?.fragment,
               let shown = BrowserPrivacyDisplayText.sanitized(fragment, maximumLength: 80) {
                details.append("#\(shown)")
            }
            if let title = BrowserPrivacyDisplayText.sanitized(record.title, maximumLength: 160),
               title != rowTitle {
                details.append(title)
            }
            return Self(
                id: record.id,
                time: record.visitedAt.map(BrowserPrivacyDateFormatter.string)
                    ?? L10n.text("时间不可用", "Time unavailable"),
                detail: details.isEmpty ? nil : details.joined(separator: " · ")
            )
        }
    }
}

/// The pages named in a confirmation or a manual-handling list.
enum BrowserPrivacyPageListText {
    /// "Title — site/path" for the first pages, then how many more there are.
    static func lines(
        for items: [BrowserPrivacyDisplayItem],
        limit: Int = 6,
        disclosure: BrowserPrivacyDisclosurePolicy? = nil
    ) -> [String] {
        let policy = disclosure ?? .protecting(items.flatMap(\.records))
        let visible = items.filter { !$0.records.contains(where: policy.isConcealed) }
        let hidden = items.filter { $0.records.contains(where: policy.isConcealed) }.reduce(0) { $0 + $1.visitCount }
        var lines = visible.prefix(limit).map { item -> String in
            let presentation = BrowserPrivacyRecordPresentation(item: item, disclosure: policy)
            let name = presentation.hasRecordedTitle
                ? "\(presentation.title) — \(presentation.address.collapsed)"
                : presentation.address.collapsed
            return "• \(name)"
        }
        if hidden > 0 { lines.append("• " + BrowserPrivacyDisclosurePolicy.sensitiveSummary(hidden)) }
        if visible.count > limit {
            let remaining = visible.count - limit
            lines.append(L10n.text("等 \(ByteFormat.count(remaining)) 个页面", "and \(ByteFormat.count(remaining)) more pages"))
        }
        return lines
    }

    /// The first sites, then how many more there are.
    static func siteSummary(_ domains: [String], limit: Int = 8) -> String {
        guard !domains.isEmpty else {
            return L10n.text("所选记录没有网站域名（例如浏览器内部页面或本地文件）。",
                             "The selected records have no website domain (for example browser-internal pages or local files).")
        }
        let shown = domains.prefix(limit).joined(separator: L10n.text("、", ", "))
        guard domains.count > limit else { return shown }
        let remaining = domains.count - limit
        return L10n.text("\(shown) 等 \(ByteFormat.count(domains.count)) 个网站", "\(shown) and \(ByteFormat.count(remaining)) more sites")
    }
}

/// Counts are always labelled, so pages and visits cannot be mistaken for
/// each other.
enum BrowserPrivacyCountText {
    static func pages(_ count: Int) -> String {
        if L10n.usesChinese { return "\(ByteFormat.count(count)) 个页面" }
        return count == 1 ? "1 page" : "\(ByteFormat.count(count)) pages"
    }

    static func visits(_ count: Int) -> String {
        if L10n.usesChinese { return "\(ByteFormat.count(count)) 次访问" }
        return count == 1 ? "1 visit" : "\(ByteFormat.count(count)) visits"
    }

    static func pagesAndVisits(pages pageCount: Int, visits visitCount: Int) -> String {
        "\(pages(pageCount)) · \(visits(visitCount))"
    }

    /// Header of the result list.
    static func listHeader(
        pages pageCount: Int,
        visits visitCount: Int,
        selectedVisits: Int
    ) -> String {
        let total = pagesAndVisits(pages: pageCount, visits: visitCount)
        return L10n.text(
            "\(total) · 已选 \(ByteFormat.count(selectedVisits)) 次访问",
            "\(total) · \(visits(selectedVisits)) selected"
        )
    }
}

enum BrowserPrivacyDisplayText {
    /// Removes control and invisible formatting characters, collapses
    /// whitespace and bounds the length. Nil for nothing to show.
    static func sanitized(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let withoutControls = String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
        }))
        let collapsed = withoutControls.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength - 1)) + "…"
    }
}

/// The identity block of a row: browser and profile, title, address and the
/// visit summary.
struct BrowserPrivacyRecordIdentityView: View {
    @Environment(\.moduleTheme) private var theme

    let item: BrowserPrivacyDisplayItem
    let searchHint: String?
    private let presentation: BrowserPrivacyRecordPresentation

    init(item: BrowserPrivacyDisplayItem, searchHint: String? = nil) {
        self.item = item
        self.searchHint = searchHint
        presentation = BrowserPrivacyRecordPresentation(item: item)
    }

    var body: some View {
        HStack(alignment: .top, spacing: AppDesignTokens.Spacing.small) {
            browserIcon

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: AppDesignTokens.Spacing.micro) {
                    Text(presentation.browserName)
                        .font(AppTypography.caption.weight(.semibold))
                        .foregroundStyle(AppDesignTokens.Palette.accent)
                    Text(presentation.profileName)
                        .font(AppTypography.caption)
                        .foregroundStyle(theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(presentation.title)
                    .font(AppTypography.metadata.weight(.semibold))
                    .foregroundStyle(theme.primaryText)
                    .lineLimit(2)
                    .truncationMode(presentation.hasRecordedTitle ? .tail : .middle)
                    // D20: query parameters stay folded until the row is
                    // expanded, so no tooltip carries the complete address.
                    .help(presentation.hasRecordedTitle
                        ? presentation.title
                        : presentation.address.collapsed)

                if presentation.hasRecordedTitle {
                    // A long address keeps its site and its last path
                    // component; the tooltip shows it untruncated, still
                    // without the query.
                    Text(presentation.address.collapsed)
                        .font(AppTypography.caption)
                        .foregroundStyle(theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(presentation.address.collapsed)
                }

                Text(presentation.summary)
                    .font(AppTypography.caption.monospacedDigit())
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if let searchHint {
                    Text(searchHint)
                        .font(AppTypography.caption)
                        .foregroundStyle(AppDesignTokens.Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The row is a button label, which centres wrapped text by default.
            .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }

    @ViewBuilder
    private var browserIcon: some View {
        if let path = item.browser.iconPath {
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
