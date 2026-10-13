import AppKit
import SwiftUI

/// Production data enters through the existing Store. No browser provider or
/// deletion operation is invoked by a disclosure, filter or selection control.
struct BrowserPrivacyLightfieldResults<Notices: View, Utilities: View>: View {
    @ObservedObject var store: BrowserPrivacyStore
    @Binding var searchQuery: String
    @Environment(\.colorScheme) private var scheme
    @Environment(\.featureLightfieldCompactResults) private var compactResults
    @ViewBuilder let notices: Notices
    @ViewBuilder let utilities: Utilities
    let showsRecords: Bool
    let pageRow: (BrowserPrivacyDisplayItem) -> AnyView
    let selectAll: () -> Void
    let requestSelection: (Set<UUID>, Set<UUID>, String) -> Void

    private var browsers: [BrowserPrivacyBrowser] { store.resultPresentation?.browsers ?? [] }
    private var disabled: Bool { store.isProcessing || store.state == .scanning || store.isRunningBrowserPreflight }
    private var palette: FeatureLightfieldPalette { FeatureLightfieldPalette.resolve(scheme) }

    var body: some View {
        GeometryReader { proxy in
            if compactResults {
                VStack(spacing: 8) {
                    filters(width: proxy.size.width)
                    FeatureOptionsScrollView(probePrefix: "lightfield.privacy", balancesContent: false,
                        usesLightfield: true, fadesResults: true, preservesLazyLayout: true) { document }
                }.background(alignment: .top) { summary }
            } else if proxy.size.height < 240 {
                FeatureOptionsScrollView(probePrefix: "lightfield.privacy", balancesContent: false,
                    usesLightfield: true, fadesResults: true, preservesLazyLayout: true) {
                    VStack(spacing: 20) { summary; filters(width: proxy.size.width); document }
                }
            } else {
                VStack(spacing: 20) {
                    summary
                    filters(width: proxy.size.width)
                    FeatureOptionsScrollView(probePrefix: "lightfield.privacy", balancesContent: false,
                        usesLightfield: true, fadesResults: true, preservesLazyLayout: true) { document }
                }
            }
        }
        .foregroundStyle(palette.fg)
    }

    private var summary: some View {
        LightfieldSummary(module: .privacy,
            label: L10n.text("按浏览器整理的浏览记录", "Browsing history by browser"),
            value: store.isFiltering ? "…" : String(store.resultPresentation.map {
                $0.hasTextQuery ? $0.visibleCount : $0.records.count
            } ?? 0), unit: L10n.text("条记录", "records"),
            note: store.isFiltering ? L10n.text("正在筛选", "Filtering") : summaryNote,
            probeID: "lightfield.privacy.summary")
    }

    private var summaryNote: String {
        let snapshot = store.resultPresentation
        let sites = snapshot?.siteCount ?? 0, hidden = snapshot?.concealedCount ?? 0
        return "· " + L10n.text("\(sites) 个站点", "\(sites) sites")
            + (hidden > 0 ? " · " + BrowserPrivacyDisclosurePolicy.sensitiveSummary(hidden) : "")
    }

    private func filters(width: CGFloat) -> some View {
        VStack(spacing: 0) {
            if width < 600 {
                browserSegments
                search
            } else {
                HStack(spacing: 20) { browserSegments; Spacer(minLength: 0); search.frame(width: min(240, width * 0.3)) }
            }
            HStack(spacing: 16) {
                LightfieldTextSegments(titles: [L10n.text("今天", "Today"), L10n.text("7 天", "7 days"), L10n.text("全部", "All")],
                    selection: dateSelection, module: .privacy)
                Spacer(minLength: 0)
                Text(L10n.text("已选 ", "Selected ") + store.disclosurePolicy.summary(store.selectedRecords))
                    .font(.system(size: 13)).lineLimit(1).monospacedDigit()
                Button(L10n.text("全选", "Select All"), action: selectAll)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(store.isFiltering)
                Button(L10n.text("反选", "Invert")) {
                    guard !store.isFiltering else { return }
                    let ids = BrowserPrivacyLightfieldPresentation.deletableIDs(store.filteredRecords)
                    let additions = BrowserPrivacyLightfieldPresentation.invertedIDs(records: store.filteredRecords,
                        selected: store.selectedRecordIDs)
                    requestSelection(additions, ids.subtracting(additions), L10n.text("当前筛选（反选）", "Current filter (invert)"))
                }.buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(store.isFiltering)
            }.font(.system(size: 13)).foregroundStyle(palette.fg2)
        }
        .disabled(disabled).lightfieldComponentProbe("lightfield.privacy.filters")
    }

    private var browserSegments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LightfieldTextSegments(titles: [L10n.text("全部", "All")] + browsers.map {
                BrowserPrivacyDisplayText.sanitized($0.displayName, maximumLength: 80) ?? ""
            }, selection: browserSelection, module: .privacy)
        }.frame(height: 32).accessibilityLabel(L10n.text("浏览器筛选", "Browser filter"))
    }
    private var browserSelection: Binding<Int> {
        Binding(get: { browsers.firstIndex { $0.id == store.filters.browserID }.map { $0 + 1 } ?? 0 }, set: { index in
            store.filters.browserID = index > 0 && index <= browsers.count ? browsers[index - 1].id : nil
            if let profileID = store.filters.profileID, !store.records.contains(where: {
                $0.profileID == profileID && (store.filters.browserID == nil || $0.browser.id == store.filters.browserID)
            }) { store.filters.profileID = nil }
        })
    }
    private var dateSelection: Binding<Int> {
        Binding(get: {
            BrowserPrivacyDatePreset.matching(store.filters, now: Date()).flatMap {
                BrowserPrivacyLightfieldPresentation.datePresets.firstIndex(of: $0)
            } ?? -1
        }, set: { index in
            guard BrowserPrivacyLightfieldPresentation.datePresets.indices.contains(index) else { return }
            var filters = store.filters
            BrowserPrivacyLightfieldPresentation.datePresets[index].apply(to: &filters, now: Date())
            store.filters = filters
        })
    }
    private var search: some View {
        TextField(L10n.text("搜索域名或页面", "Search domain or page"), text: $searchQuery)
            .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(palette.fg2)
            .frame(height: 32).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .accessibilityLabel(L10n.text("搜索域名或页面", "Search domain or page"))
    }

    private var document: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            FeatureLightfieldHairline()
            notices
            if showsRecords {
                ForEach(store.resultPresentation?.browserGroups ?? []) { group in
                    BrowserPrivacyLightfieldBrowser(store: store, group: group,
                        pageRow: pageRow, requestSelection: requestSelection)
                }
            }
            utilities.padding(.vertical, 12)
        }.lightfieldComponentProbe("lightfield.privacy.document")
    }

}

/// All profiles retain their original selection identities; the sensitive
/// bucket is presented once per browser, across those profiles (D70②).
struct BrowserPrivacyLightfieldBrowser: View {
    @ObservedObject var store: BrowserPrivacyStore
    let group: BrowserPrivacyBrowserGroup
    let pageRow: (BrowserPrivacyDisplayItem) -> AnyView
    let requestSelection: (Set<UUID>, Set<UUID>, String) -> Void
    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(group.profiles) { profile in
                BrowserPrivacyLightfieldProfile(store: store, group: profile, pageRow: pageRow,
                    requestSelection: requestSelection, showsSensitive: false,
                    browserSensitiveGroup: profile.id == group.profiles.first?.id ? group.sensitiveGroup : nil)
            }
        }
    }
}

/// One production browser/profile branch; its state is presentation-only.
/// It is independently hostable for native AX tests (the AppKit harness does
/// not publish ScrollView descendants; see existing N20).
struct BrowserPrivacyLightfieldProfile: View {
    @ObservedObject var store: BrowserPrivacyStore
    let group: BrowserPrivacyProfileGroup
    let pageRow: (BrowserPrivacyDisplayItem) -> AnyView
    let requestSelection: (Set<UUID>, Set<UUID>, String) -> Void
    var showsSensitive = true
    var browserSensitiveGroup: BrowserPrivacyProfileGroup? = nil
    var bucketOnly = false
    @Environment(\.colorScheme) private var scheme
    @State private var closedProfiles: Set<BrowserPrivacyProfileIdentity> = []
    @State private var openSensitive: Set<BrowserPrivacyProfileIdentity> = []
    private var disabled: Bool { store.isFiltering || store.isProcessing || store.state == .scanning || store.isRunningBrowserPreflight }
    private var palette: FeatureLightfieldPalette { FeatureLightfieldPalette.resolve(scheme) }
    var body: some View {
        Group {
            if bucketOnly { sensitive(group) }
            else { profile(group) }
        }
            .onChange(of: store.scanSnapshot?.id) { _, _ in openSensitive.removeAll(); store.expandedSiteIDs.removeAll() }
    }

    private func profile(_ group: BrowserPrivacyProfileGroup) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Button {
                    if !closedProfiles.contains(group.id), showsSensitive || browserSensitiveGroup != nil {
                        store.concealSensitiveSites(browserID: group.browser.id)
                    }
                    toggle(&closedProfiles, group.id)
                } label: {
                    HStack(spacing: 16) {
                        LightfieldAppIcon(path: group.browser.applicationURL?.path, size: .medium)
                        Text(group.title).font(.system(size: 15, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Text(BrowserPrivacyLightfieldPresentation.counts(sites: group.sites.count, records: group.records.count))
                            .font(.system(size: 13)).foregroundStyle(palette.fg2).lineLimit(1)
                        Spacer(minLength: 0)
                        FeatureLightfieldDisclosureChevron(expanded: !closedProfiles.contains(group.id))
                    }.contentShape(Rectangle())
                }.buttonStyle(FeatureLightfieldRowButtonStyle())
                    .accessibilityLabel(group.title)
                    .accessibilityValue(closedProfiles.contains(group.id) ? L10n.text("已折叠", "Collapsed") : L10n.text("已展开", "Expanded"))
                selection(group.records, label: L10n.text("选择 \(group.title) 的可删记录", "Select deletable records in \(group.title)"))
            }.frame(height: FeatureLightfield.rowHeight).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            if !closedProfiles.contains(group.id) {
                if let sensitiveGroup = browserSensitiveGroup, !sensitiveGroup.sites.isEmpty {
                    BrowserPrivacyLightfieldProfile(store: store, group: sensitiveGroup, pageRow: pageRow,
                        requestSelection: requestSelection, bucketOnly: true)
                }
                if showsSensitive && !group.sensitiveSites.isEmpty { sensitive(group) }
                ForEach(group.regularSites) { site in domain(site) }
            }
        }.lightfieldComponentProbe("lightfield.privacy.profile." + group.id.profileID)
    }

    private func sensitive(_ group: BrowserPrivacyProfileGroup) -> some View {
        let sites = group.sensitiveSites
        let records = sites.flatMap(\.records)
        return LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                selection(records, label: L10n.text("选择 \(group.title) 的敏感网站可删记录", "Select deletable sensitive records in \(group.title)"))
                LightfieldStatusGlyph(status: .locked)
                Button {
                    let wasOpen = openSensitive.contains(group.id)
                    if wasOpen { store.concealSensitiveSites(browserID: group.browser.id) }
                    toggle(&openSensitive, group.id)
                } label: {
                    HStack(spacing: 12) {
                        Text(L10n.text("敏感网站", "Sensitive websites")).font(.system(size: 15))
                        Text("· " + BrowserPrivacyLightfieldPresentation.counts(sites: sites.count, records: records.count))
                            .font(.system(size: 13)).foregroundStyle(palette.fg2).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(L10n.text("需审阅", "Review required")).font(.system(size: 13))
                            .foregroundStyle(FeatureLightfieldStatus.warning.color(palette))
                        FeatureLightfieldDisclosureChevron(expanded: openSensitive.contains(group.id))
                    }.contentShape(Rectangle())
                }.buttonStyle(FeatureLightfieldRowButtonStyle())
                    .accessibilityLabel(L10n.text("敏感网站", "Sensitive websites") + " · " + group.title)
                    .accessibilityValue(openSensitive.contains(group.id) ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
                    .accessibilityHint(L10n.text("需审阅，展开显示打码域名", "Review required; expand to show concealed domains"))
            }.frame(height: FeatureLightfield.rowHeight).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            if openSensitive.contains(group.id) {
                ForEach(sites) { site in domain(site) }.padding(.leading, FeatureLightfield.childRowIndent)
            }
        }
    }

    private func domain(_ site: BrowserPrivacySiteGroup) -> some View {
#if DEBUG
        let _ = BrowserPrivacyRenderProbe.domainBuilt()
#endif
        let expanded = store.expandedSiteIDs.contains(site.id) && (!site.isSensitive || store.revealedSensitiveSites.contains(site.id))
        let title = site.isSensitive && !expanded ? site.concealedTitle : site.title
        return LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                selection(site.records, label: L10n.text("选择 \(title) 下的可删记录", "Select deletable records under \(title)"))
                Text(site.isSensitive ? "•" : String(title.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.fg2)
                    .frame(width: 16, height: 16).accessibilityHidden(true)
                Button {
                    if site.isSensitive { store.setSensitiveSiteRevealed(!expanded, siteID: site.id) }
                    if expanded { store.expandedSiteIDs.remove(site.id) }
                    else { store.expandedSiteIDs.insert(site.id) }
                } label: {
                    HStack(spacing: 12) {
                        Text(title).font(.system(size: 15, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(BrowserPrivacyLightfieldPresentation.recordCount(site.records.count)
                            + " · " + (site.latestVisit.map { L10n.text("最近 \(BrowserPrivacyDateFormatter.string($0))", "Latest \(BrowserPrivacyDateFormatter.string($0))") }
                                ?? L10n.text("时间不可用", "Time unavailable")))
                            .font(.system(size: 13)).foregroundStyle(palette.fg2).lineLimit(1).truncationMode(.tail)
                        FeatureLightfieldDisclosureChevron(expanded: expanded)
                    }.contentShape(Rectangle())
                }.buttonStyle(FeatureLightfieldRowButtonStyle())
                    .accessibilityLabel(title)
                    .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
            }.frame(height: FeatureLightfield.rowHeight).overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            if expanded {
                ForEach(site.pages) { page in pageRow(page) }.padding(.leading, FeatureLightfield.childRowIndent)
            }
        }
    }

    private func selection(_ records: [BrowserPrivacyRecord], label: String) -> some View {
        let ids = BrowserPrivacyLightfieldPresentation.deletableIDs(records)
            .intersection(store.resultPresentation?.recordIDs ?? [])
        let state = BrowserPrivacyLightfieldPresentation.selectionState(ids: ids, selected: store.selectedRecordIDs)
        return Button {
            guard !disabled else { return }
            if state == .checked { store.setSelection(false, recordIDs: ids) }
            else { requestSelection(ids, [], label) }
        } label: {
            FeatureLightfieldCheck(selected: state != .unchecked, module: .privacy, mixed: state == .mixed)
        }.buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(disabled || ids.isEmpty)
            .accessibilityLabel(label).accessibilityValue(state.accessibilityValue)
    }

    private func toggle<ID: Hashable>(_ values: inout Set<ID>, _ id: ID) {
        if values.contains(id) { values.remove(id) } else { values.insert(id) }
    }
}

extension BrowserPrivacySelectionState {
    var accessibilityValue: String {
        switch self {
        case .unchecked: L10n.text("未选择", "Not selected")
        case .mixed: L10n.text("部分选择", "Mixed")
        case .checked: L10n.text("已全选", "All selected")
        }
    }
}

struct BrowserPrivacyLightfieldPageRow: View {
    @Environment(\.colorScheme) private var scheme
    let item: BrowserPrivacyDisplayItem
    let selectedIDs: Set<UUID>
    let expanded: Bool
    let disabled: Bool
    let select: () -> Void
    let disclose: () -> Void
    let visit: (BrowserPrivacyRecord) -> Void
    var disclosure: BrowserPrivacyDisclosurePolicy? = nil
    @State private var copiedAddress = false
    private var policy: BrowserPrivacyDisclosurePolicy { disclosure ?? .protecting(item.records) }
    private var presentation: BrowserPrivacyRecordPresentation { .init(item: item, disclosure: policy) }
    private var pageTitle: String {
        if item.records.contains(where: policy.isConcealed) { return presentation.title }
        return presentation.hasRecordedTitle ? presentation.title : (presentation.address.full ?? presentation.address.collapsed)
    }
    private var selectionState: BrowserPrivacySelectionState {
        BrowserPrivacyLightfieldPresentation.selectionState(ids: Set(item.records.map(\.id)), selected: selectedIDs)
    }
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
#if DEBUG
        let _ = BrowserPrivacyRenderProbe.pageBuilt()
#endif
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Button(action: select) {
                    FeatureLightfieldCheck(selected: selectionState != .unchecked, module: .privacy, mixed: selectionState == .mixed)
                }.buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(disabled)
                    .accessibilityLabel(L10n.text("选择页面：\(pageTitle)", "Select page: \(pageTitle)"))
                    .accessibilityValue(selectionState.accessibilityValue)
                Button(action: disclose) {
                    HStack(spacing: 16) {
                        Text(pageTitle).font(.system(size: 13)).lineLimit(1)
                            .truncationMode(presentation.hasRecordedTitle ? .tail : .middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lightfieldComponentProbe("lightfield.privacy.page.title")
                        if item.directDeletionBlocker != nil {
                            LightfieldStatusGlyph(status: .readOnly)
                        }
                        Text(BrowserPrivacyLightfieldPresentation.recordCount(item.visitCount))
                            .font(.system(size: 13)).monospacedDigit()
                        FeatureLightfieldDisclosureChevron(expanded: expanded)
                    }.contentShape(Rectangle())
                }.buttonStyle(FeatureLightfieldRowButtonStyle()).accessibilityLabel(pageTitle)
                    .accessibilityValue(expanded ? L10n.text("已展开", "Expanded") : L10n.text("已折叠", "Collapsed"))
                    .accessibilityHint(item.locallyDeletable ? presentation.summary : L10n.text("需在浏览器内处理", "Handle in browser"))
            }.frame(height: 32).foregroundStyle(palette.fg2)
            if expanded && !item.records.contains(where: policy.isConcealed) {
                Text(presentation.address.full ?? presentation.address.collapsed)
                    .font(.system(size: 13, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                    .foregroundStyle(palette.fg2)
                Button(copiedAddress ? L10n.text("已复制网址", "Address Copied") : L10n.text("复制网址", "Copy Address")) {
                    guard let address = presentation.address.full else { return }
                    copiedAddress = BrowserPrivacyClipboard.write(address, to: .general)
                }.buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13))
                    .disabled(presentation.address.full == nil)
                ForEach(Array(zip(item.records, BrowserPrivacyVisitPresentation.visits(of: item))), id: \.1.id) { record, shown in
                    Button { visit(record) } label: {
                        HStack(spacing: 16) {
                            FeatureLightfieldCheck(selected: selectedIDs.contains(record.id), module: .privacy)
                            Text(shown.time).font(.system(size: 13)).monospacedDigit()
                            if let detail = shown.detail { Text(detail).font(.system(size: 13)).lineLimit(1).truncationMode(.middle) }
                        }.frame(height: 32).foregroundStyle(palette.fg2)
                    }.buttonStyle(FeatureLightfieldRowButtonStyle()).disabled(disabled)
                        .accessibilityLabel(L10n.text("\(shown.time) 的访问", "Visit at \(shown.time)"))
                        .accessibilityValue(selectedIDs.contains(record.id) ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not selected"))
                }
                if item.records.count > BrowserPrivacyVisitPresentation.displayLimit {
                    Text(L10n.text("另有更早的访问；选择页面会包含全部访问。", "Earlier visits remain; selecting the page includes all visits."))
                        .font(.system(size: 13)).foregroundStyle(palette.fg2)
                }
            }
        }.lightfieldComponentProbe("lightfield.privacy.page")
    }
}

private extension BrowserPrivacyDisplayItem {
    var locallyDeletable: Bool { records.allSatisfy { $0.locator != nil } }
}
