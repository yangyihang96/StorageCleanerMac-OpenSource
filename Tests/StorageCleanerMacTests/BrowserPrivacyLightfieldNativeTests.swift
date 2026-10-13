#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class BrowserPrivacyLightfieldNativeTests: XCTestCase {
    private let windows: [CGSize] = [.init(width: 820, height: 560), .init(width: 1000, height: 700),
        .init(width: 1280, height: 763), .init(width: 1680, height: 1050), .init(width: 2400, height: 1350),
        .init(width: 677, height: 390), .init(width: 1280, height: 390)]

    func testProductionPrivacyThreeStatesKeepSkeletonAndPinnedActionAcrossSevenSizes() async throws {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore()
        for dark in [false, true] {
            for phase in FeatureLightfieldPhase.allCases {
                let root: AnyView
                switch phase {
                case .landing: root = AnyView(BrowserPrivacyWorkspaceView(browserPrivacyStore: BrowserPrivacyPreviewFixture.makeStore()))
                case .running: root = AnyView(BrowserPrivacyRunningPage(onCancel: {}))
                case .result: root = AnyView(BrowserPrivacyWorkspaceView(browserPrivacyStore: store))
                }
                let host = CalibrationAppKitLayoutHost(root: root
                    .environment(\.featurePresentationIsFixture, true)
                    .environment(\.featureDisablesLayoutAnimations, true), size: .init(width: 1070, height: 735), dark: dark)
                defer { host.close() }
                for window in windows {
                    let size = CGSize(width: window.width - 210, height: window.height - 28)
                    host.resize(to: size)
                    let ids: Set<String> = ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status", "fixture.viewport"]
                    let frames = try await host.frames(required: ids, size: size)
                    if phase == .result {
                        try assertCompactResultSkeleton(frames, window: window)
                        continue
                    }
                    let geometry = FeatureLightfieldGeometry(size: size, phase: phase)
                    for (name, expected) in [("title", geometry.title), ("content", geometry.content),
                        ("primary", geometry.primary), ("status", geometry.status)] {
                        let actual = try XCTUnwrap(frames["lightfield." + name])
                        XCTAssertEqual(actual.minX, expected.minX, accuracy: 0.5, name)
                        XCTAssertEqual(actual.minY, expected.minY, accuracy: 0.5, name)
                        XCTAssertEqual(actual.width, expected.width, accuracy: 0.5, name)
                        XCTAssertEqual(actual.height, expected.height, accuracy: 0.5, name)
                        XCTAssertTrue(CGRect(origin: .zero, size: size).insetBy(dx: -0.5, dy: -0.5).contains(actual), name)
                    }
                    XCTAssertEqual(frames["lightfield.primary"]!.minY - frames["lightfield.content"]!.maxY, 24, accuracy: 0.5)
                }
            }
        }
    }

    func testPrivacyLandingFitsRealPageContainerAcrossOriginalSizeSweep() async throws {
        // Same 7 × 9 detail-column sweep as the all-module regression. This
        // independently hosts the real privacy page without an operation-home
        // fixture, so its D67 geometry can also run in the managed sandbox.
        for language in [AppLanguage.zhHans, .english] {
            let languageScope = CalibrationLanguageScope(language)
            defer { languageScope.restore() }
            let store = BrowserPrivacyPreviewFixture.makeStore()
            let root = AdaptivePageViewport(resetID: ReviewFilter.privacy) {
                BrowserPrivacyWorkspaceView(browserPrivacyStore: store)
                    .environment(\.moduleTheme, ReviewFilter.privacy.moduleTheme)
                    .environment(\.featurePresentationIsFixture, true)
                    .environment(\.featureDisablesLayoutAnimations, true)
            }
            let host = CalibrationAppKitLayoutHost(root: root, size: .init(width: 1083, height: 712), dark: true)
            defer { host.close() }
            for width: CGFloat in [655, 703, 760, 803, 903, 1000, 1083] {
                for height: CGFloat in [468, 520, 560, 600, 640, 660, 680, 712, 760] {
                    let size = CGSize(width: width, height: height)
                    let context = "privacy \(language) \(Int(width))x\(Int(height))"
                    host.resize(to: size)
                    let ids: Set<String> = ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status",
                        "lightfield.options.scrollViewport", "lightfield.optionsEnd", "fixture.viewport"]
                    let frames = try await host.frames(required: ids, size: size)
                    let bounds = try XCTUnwrap(frames["fixture.viewport"])
                    for id in ["lightfield.title", "lightfield.content", "lightfield.primary", "lightfield.status"] {
                        XCTAssertTrue(bounds.insetBy(dx: -0.5, dy: -0.5).contains(try XCTUnwrap(frames[id])), context + " " + id)
                    }
                    let action = try XCTUnwrap(frames["lightfield.primary"])
                    XCTAssertEqual(action.height, 52, accuracy: 0.5, context)
                    XCTAssertEqual(action.minY - (try XCTUnwrap(frames["lightfield.content"])).maxY, 24, accuracy: 0.5, context)
                    XCTAssertGreaterThanOrEqual(try XCTUnwrap(frames["lightfield.title"]).minY, 48 - 0.5, context)
                    let viewport = try XCTUnwrap(frames["lightfield.options.scrollViewport"])
                    let end = try XCTUnwrap(frames["lightfield.optionsEnd"])
                    if end.maxY > viewport.maxY + 0.5 {
                        try host.scrollOptionsToBottom(matching: viewport)
                        let after = try await host.frames(required: ids, size: size)
                        XCTAssertLessThanOrEqual(try XCTUnwrap(after["lightfield.optionsEnd"]).maxY, viewport.maxY + 0.5, context)
                    }
                }
            }
        }
    }

    func testPageAXSelectionDisclosureAndVisitRemainIndependent() async throws {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore()
        let item = store.filteredDisplayItems.first { $0.visitCount == 3 }!
        let model = PageCallbacks()
        let size = CGSize(width: 520, height: 260)
        let host = CalibrationAppKitLayoutHost(root: PageFixture(item: item, model: model), size: size, dark: true)
        defer { host.close() }
        let title = BrowserPrivacyRecordPresentation(item: item).title
        let select = L10n.text("选择页面：\(title)", "Select page: \(title)")
        try await host.waitForAccessibility(labels: [title, select],
            expectedValues: [title: L10n.text("已折叠", "Collapsed"), select: L10n.text("未选择", "Not selected")],
            pressLabels: [title, select])
        XCTAssertTrue(try host.press(label: title))
        XCTAssertTrue(model.selected.isEmpty, "Disclosure cannot select")
        try await host.waitForAccessibility(labels: [title], expectedValues: [title: L10n.text("已展开", "Expanded")])
        XCTAssertTrue(try host.press(label: select))
        XCTAssertEqual(model.selected, Set(item.records.map(\.id)))
        let shown = BrowserPrivacyVisitPresentation.visits(of: item)[0]
        let visit = L10n.text("\(shown.time) 的访问", "Visit at \(shown.time)")
        try await host.waitForAccessibility(labels: [visit], pressLabels: [visit])
        XCTAssertTrue(try host.press(label: visit))
        XCTAssertEqual(model.selected.count, item.records.count - 1)
        XCTAssertTrue(model.expanded)
    }

    func testSensitiveAXRequiresTwoExplicitDisclosuresAndGroupRequestsExactIDs() async throws {
        let store = await BrowserPrivacyPreviewFixture.makeResultStore(outcome: BrowserPrivacyLightfieldTestFixture.outcome)
        store.filters.browserID = "chrome"
        await store.waitForFilteredResults()
        let groups = BrowserPrivacyLightfieldPresentation.groups(store.filteredDisplayItems)
        let group = groups.first { $0.id.profileID == "chrome:Default" }!
        let site = group.sensitiveSites.first { $0.title == "private.example" }!
        let callbacks = GroupCallbacks()
        let size = CGSize(width: 878, height: 900)
        let host = CalibrationAppKitLayoutHost(root: BrowserPrivacyLightfieldProfile(store: store, group: group,
            pageRow: { AnyView(BrowserPrivacyLightfieldPageRow(item: $0, selectedIDs: store.selectedRecordIDs,
                expanded: false, disabled: false, select: {}, disclose: {}, visit: { _ in }, disclosure: store.disclosurePolicy)) },
            requestSelection: { adding, _, _ in callbacks.requestedIDs = adding })
            .environment(\.featureDisablesLayoutAnimations, true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: true)
        defer { host.close() }
        let bucket = L10n.text("敏感网站", "Sensitive websites") + " · " + group.title
        let selection = L10n.text("选择 \(group.title) 的可删记录", "Select deletable records in \(group.title)")
        try await host.waitForAccessibility(labels: [bucket, selection],
            expectedValues: [bucket: L10n.text("已折叠", "Collapsed")], pressLabels: [bucket, selection])
        let profileProbe = "lightfield.privacy.profile." + group.id.profileID
        let initial = try await host.frames(required: ["fixture.viewport", profileProbe], size: size)
        XCTAssertNil(initial["lightfield.privacy.page"], "No sensitive page row is mounted initially")
        for sensitiveSite in group.sensitiveSites {
            XCTAssertNil(host.element(label: sensitiveSite.concealedTitle), "Even concealed domain rows require explicit bucket disclosure")
            XCTAssertNil(host.element(label: sensitiveSite.title))
            for page in sensitiveSite.pages {
                XCTAssertNil(host.element(label: BrowserPrivacyRecordPresentation(item: page).title))
            }
        }
        let manualIDs = Set(group.records.filter { $0.locator == nil }.map(\.id))
        XCTAssertEqual(manualIDs.count, 2)
        let expectedGroupIDs = Set(group.records.filter { $0.locator != nil }.map(\.id))
        store.filters.query = "pending-filter-generation"
        XCTAssertTrue(store.isFiltering)
        if host.element(label: selection, requiresPress: true) != nil { _ = try host.press(label: selection) }
        XCTAssertTrue(callbacks.requestedIDs.isEmpty, "A stale native group action cannot select before the new filter publishes")
        XCTAssertTrue(store.selectedRecordIDs.isEmpty)
        store.filters.query = ""
        await store.waitForFilteredResults()
        try await host.waitForAccessibility(labels: [selection], expectedEnabled: [selection: true], pressLabels: [selection])
        XCTAssertTrue(try host.press(label: selection))
        XCTAssertEqual(callbacks.requestedIDs, expectedGroupIDs)
        XCTAssertTrue(manualIDs.isDisjoint(with: callbacks.requestedIDs))
        XCTAssertTrue(store.selectedRecordIDs.isEmpty, "A group addition awaits the existing review confirmation")
        // Simulate only the already-reviewed selection callback, without
        // invoking deletion. Browser-only records remain unselected.
        store.setSelection(true, recordIDs: callbacks.requestedIDs)
        XCTAssertEqual(store.selectedRecordIDs, expectedGroupIDs)
        XCTAssertTrue(manualIDs.isDisjoint(with: store.selectedRecordIDs))
        try await host.waitForAccessibility(labels: [selection], expectedValues: [selection: L10n.text("已全选", "All selected")])
        XCTAssertTrue(try host.press(label: selection))
        XCTAssertTrue(store.selectedRecordIDs.isEmpty)
        let sensitiveSelection = L10n.text("选择 \(group.title) 的敏感网站可删记录", "Select deletable sensitive records in \(group.title)")
        try await host.waitForAccessibility(labels: [sensitiveSelection], pressLabels: [sensitiveSelection])
        XCTAssertTrue(try host.press(label: sensitiveSelection))
        XCTAssertEqual(callbacks.requestedIDs, Set(group.sensitiveSites.flatMap(\.records).filter { $0.locator != nil }.map(\.id)))
        store.setSelection(true, recordIDs: callbacks.requestedIDs)
        XCTAssertTrue(manualIDs.isDisjoint(with: store.selectedRecordIDs))
        store.setSelection(false, recordIDs: store.selectedRecordIDs)
        XCTAssertTrue(try host.press(label: bucket))
        try await host.waitForAccessibility(labels: [bucket] + group.sensitiveSites.map(\.concealedTitle),
            expectedValues: [bucket: L10n.text("已展开", "Expanded")], pressLabels: [site.concealedTitle])
        let masked = try await host.frames(required: ["fixture.viewport", profileProbe], size: size)
        XCTAssertNil(masked["lightfield.privacy.page"], "Bucket disclosure shows concealed sites, not pages")
        XCTAssertNil(host.element(label: site.title))
        XCTAssertNil(host.element(label: site.pages[0].title!))
        XCTAssertTrue(try host.press(label: site.concealedTitle))
        try await host.waitForAccessibility(labels: [site.title, site.pages[0].title!])
        _ = try await host.frames(required: ["lightfield.privacy.page", profileProbe], size: size)
        XCTAssertTrue(store.selectedRecordIDs.isEmpty, "Revealing sensitive content cannot select anything")
        XCTAssertTrue(try host.press(label: bucket))
        try await host.waitForAccessibility(labels: [bucket], expectedValues: [bucket: L10n.text("已折叠", "Collapsed")])
        let folded = try await host.frames(required: ["fixture.viewport", profileProbe], size: size)
        XCTAssertNil(folded["lightfield.privacy.page"])
        XCTAssertNil(host.element(label: site.concealedTitle))
        XCTAssertNil(host.element(label: site.title))
        XCTAssertNil(host.element(label: site.pages[0].title!))
    }

    func testLongUntitledAddressStaysInItsPageColumnAtSevenSizes() async throws {
        let row = BrowserPrivacyPreviewFixture.outcome.records[0]
        let record = BrowserPrivacyRecord(id: UUID(), browser: row.browser, profileID: row.profileID,
            profileDisplayName: String(repeating: "非常长的配置文件名称", count: 40), source: .history,
            url: "https://long.example/" + String(repeating: "very-long-page-component/", count: 80) + "specific-final-page?query=fixture-only",
            domain: "long.example", title: nil, searchKeyword: nil, visitedAt: Date(), visitCount: 1,
            category: .productivity, selectionConfidence: .medium, sizeBytes: nil)
        let item = BrowserPrivacyDisplayItem.aggregate([record])[0]
        for window in windows {
            let canvas = CGSize(width: window.width - 210, height: window.height - 28)
            let width = FeatureLightfieldGeometry(size: canvas, phase: .result).content.width - FeatureLightfield.childRowIndent
            let size = CGSize(width: width, height: 120)
            let host = CalibrationAppKitLayoutHost(root: BrowserPrivacyLightfieldPageRow(item: item,
                selectedIDs: [], expanded: false, disabled: false, select: {}, disclose: {}, visit: { _ in })
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: false)
            defer { host.close() }
            let frames = try await host.frames(required: ["fixture.viewport", "lightfield.privacy.page", "lightfield.privacy.page.title"], size: size)
            let page = try XCTUnwrap(frames["lightfield.privacy.page"])
            let title = try XCTUnwrap(frames["lightfield.privacy.page.title"])
            XCTAssertTrue(page.insetBy(dx: -0.5, dy: -0.5).contains(title))
            XCTAssertLessThanOrEqual(page.maxX, width + 0.5)
            XCTAssertEqual(page.height, 32, accuracy: 0.5)
            XCTAssertTrue(BrowserPrivacyRecordPresentation(item: item).title.contains("very-long-page-component"))
        }
    }

    func testHealthSecurityAndChangeLogRetainStatusGlyphGrid() async throws {
        let snapshot = FeatureLightfieldResultFixture.healthSnapshot
        let size = CGSize(width: 878, height: 520)
        let host = CalibrationAppKitLayoutHost(root: VStack(spacing: 0) {
            HealthSecurityChecksView(snapshot: snapshot.security)
            HealthRecentChangesView(events: snapshot.recentChanges)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading), size: size, dark: false)
        defer { host.close() }
        let ids = SystemProtectionCheck.healthChecks.flatMap {
            ["lightfield.health.security.leading." + $0.rawValue, "lightfield.health.security.disclosure." + $0.rawValue]
        }
        let frames = try await host.frames(required: Set(ids), size: size)
        for id in ids { XCTAssertEqual(try XCTUnwrap(frames[id]).size, .init(width: 20, height: 20)) }
        let leading = SystemProtectionCheck.healthChecks.map { frames["lightfield.health.security.leading." + $0.rawValue]! }
        for pair in zip(leading, leading.dropFirst()) { XCTAssertEqual(pair.1.minY - pair.0.minY, 52, accuracy: 0.5) }
        let label = SystemProtectionCheck.fileVault.title + " · " + SystemProtectionState.enabled.displayText
        try await host.waitForAccessibility(labels: [label], pressLabels: [label])
        XCTAssertTrue(try host.press(label: label))
        try await host.waitForAccessibility(labels: [label], expectedValues: [label: L10n.text("已展开", "Expanded")])
    }
}

@MainActor private final class PageCallbacks: ObservableObject {
    @Published var selected: Set<UUID> = []
    @Published var expanded = false
}
@MainActor private final class GroupCallbacks {
    var requestedIDs: Set<UUID> = []
}
private struct PageFixture: View {
    let item: BrowserPrivacyDisplayItem
    @ObservedObject var model: PageCallbacks
    var body: some View {
        BrowserPrivacyLightfieldPageRow(item: item, selectedIDs: model.selected,
            expanded: model.expanded, disabled: false,
            select: {
                let ids = Set(item.records.map(\.id))
                model.selected = model.selected == ids ? [] : ids
            }, disclose: { model.expanded.toggle() }, visit: { row in
                if model.selected.contains(row.id) { model.selected.remove(row.id) } else { model.selected.insert(row.id) }
            }).environment(\.featureDisablesLayoutAnimations, true)
    }
}
#endif
