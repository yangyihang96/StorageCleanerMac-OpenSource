import XCTest
@testable import StorageCleanerMac

final class ControlAccessibilityContractTests: XCTestCase {
    func testKeyboardSelectionMovesAndClampsWithinVisibleItems() {
        let visibleItemIDs = ["first", "second", "third"]

        XCTAssertEqual(
            ItemListKeyboardSelectionResolver.resolvedSelectionID(
                currentSelectionID: "first",
                visibleItemIDs: visibleItemIDs,
                direction: .next
            ),
            "second"
        )
        XCTAssertEqual(
            ItemListKeyboardSelectionResolver.resolvedSelectionID(
                currentSelectionID: "second",
                visibleItemIDs: visibleItemIDs,
                direction: .previous
            ),
            "first"
        )
        XCTAssertEqual(
            ItemListKeyboardSelectionResolver.resolvedSelectionID(
                currentSelectionID: "first",
                visibleItemIDs: visibleItemIDs,
                direction: .previous
            ),
            "first"
        )
        XCTAssertEqual(
            ItemListKeyboardSelectionResolver.resolvedSelectionID(
                currentSelectionID: "third",
                visibleItemIDs: visibleItemIDs,
                direction: .next
            ),
            "third"
        )
    }

    func testKeyboardSelectionHandlesMissingAndEmptySelections() {
        XCTAssertEqual(
            ItemListKeyboardSelectionResolver.resolvedSelectionID(
                currentSelectionID: "missing",
                visibleItemIDs: ["first", "second"],
                direction: .next
            ),
            "first"
        )
        XCTAssertEqual(
            ItemListKeyboardSelectionResolver.resolvedSelectionID(
                currentSelectionID: nil,
                visibleItemIDs: ["first", "second"],
                direction: .previous
            ),
            "second"
        )
        XCTAssertNil(
            ItemListKeyboardSelectionResolver.resolvedSelectionID(
                currentSelectionID: "first",
                visibleItemIDs: [],
                direction: .next
            )
        )
    }

    func testSharedSearchFieldKeepsFocusAndEscapeAccessibilityContracts() throws {
        let source = try projectSource(
            "Sources/StorageCleanerMac/Views/SmartCareComponents.swift"
        )

        XCTAssertTrue(source.contains("@FocusState private var isFocused: Bool"))
        XCTAssertTrue(source.contains(".focused(focusBinding)"))
        XCTAssertTrue(source.contains("var focus: FocusState<Bool>.Binding?"))
        XCTAssertTrue(source.contains(".onExitCommand"))
        XCTAssertTrue(source.contains("Color(nsColor: .keyboardFocusIndicatorColor)"))
        XCTAssertTrue(source.contains(
            "title: L10n.text(\"清除搜索\", \"Clear Search\")"
        ))
        XCTAssertTrue(source.contains("AppIconButton("))
    }

    func testMetadataRowsAndTransientStatusExposeSingleSpokenLabels() throws {
        let metadata = try projectSource(
            "Sources/StorageCleanerMac/Support/MetadataPill.swift"
        )
        let content = try projectSource(
            "Sources/StorageCleanerMac/Views/ContentView.swift"
        )
        let itemList = try projectSource(
            "Sources/StorageCleanerMac/Views/ItemListView.swift"
        )

        // D64 keeps explicit state symbols hidden from the spoken label.
        XCTAssertTrue(metadata.contains("if let renderedSystemImage {"))
        XCTAssertTrue(metadata.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(metadata.contains(".accessibilityValue(status.accessibilityDescription)"))
        XCTAssertTrue(metadata.contains("Text(text)"))
        XCTAssertTrue(metadata.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(metadata.contains(".accessibilityLabel(text)"))
        XCTAssertTrue(content.contains(".onChange(of: message, initial: true)"))
        XCTAssertTrue(content.contains("AccessibilityNotification.Announcement(newMessage).post()"))
        XCTAssertTrue(content.contains(".accessibilityLabel(message)"))
        XCTAssertTrue(itemList.contains(".accessibilityValue(metric.value)"))
        XCTAssertTrue(itemList.contains("details = [item.kind, size, item.path]"))
    }

    func testSelectionAndIconOnlyControlsExposeAccessibleNamesAndStates() throws {
        let itemListSource = try projectSource(
            "Sources/StorageCleanerMac/Views/ItemListView.swift"
        )
        let contentSource = try projectSource(
            "Sources/StorageCleanerMac/Views/ContentView.swift"
        )
        let modulePresentation = try projectSource(
            "Sources/StorageCleanerMac/Views/ModulePresentation.swift"
        )
        let overviewSource = try projectSource(
            "Sources/StorageCleanerMac/Views/OverviewView.swift"
        )

        XCTAssertTrue(itemListSource.contains(".onMoveCommand(perform: moveSelection)"))
        XCTAssertTrue(itemListSource.contains(".focused($focusedItemID, equals: item.id)"))
        XCTAssertTrue(itemListSource.contains(".isSelected"))
        XCTAssertTrue(itemListSource.contains(".contentShape(Rectangle())"))
        XCTAssertFalse(contentSource.contains("GlassSegmentedControl("))
        XCTAssertFalse(contentSource.contains("Picker(\"\", selection: $selection)"))
        XCTAssertTrue(modulePresentation.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(modulePresentation.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(modulePresentation.contains("Text(title(option)).tag(option)"))
        XCTAssertTrue(modulePresentation.contains("selection: $selection"))
        XCTAssertTrue(overviewSource.contains(
            ".accessibilityLabel(L10n.text(\"更多操作\", \"More Actions\"))"
        ))
    }

    func testPanelIconControlsShareMinimumHitRegionsAndSpokenLabels() throws {
        let controls = try projectSource(
            "Sources/StorageCleanerMac/Support/AppControls.swift"
        )
        let iconStyle = try projectSource(
            "Sources/StorageCleanerMac/Support/AppIconStyle.swift"
        )
        let panelChrome = try projectSource(
            "Sources/StorageCleanerMac/Views/MenuBarPanelChrome.swift"
        )

        XCTAssertTrue(iconStyle.contains("static let iconHitRegion: CGFloat = 32"))
        for role in [AppIconRole.toolbar, .inline, .sidebar] {
            XCTAssertEqual(role.glyphSize, 16,
                "Adding another role to the same switch branch must not change existing glyph sizes")
        }
        XCTAssertEqual(AppControlSizes.iconHitRegion, 32)
        XCTAssertEqual(AppIconRole.toolbar.frameSize, AppControlSizes.iconHitRegion)
        XCTAssertEqual(AppIconRole.panelNavigation.frameSize, AppControlSizes.iconHitRegion)
        let symbolIcon = try XCTUnwrap(
            iconStyle.components(separatedBy: "struct AppSymbolIcon: View").last?
                .components(separatedBy: "struct AppSymbolGlyph: View").first
        )
        XCTAssertTrue(symbolIcon.contains("AppSymbolGlyph("))
        XCTAssertTrue(symbolIcon.contains("size: role.glyphSize"))
        XCTAssertTrue(symbolIcon.contains(".frame(width: role.frameSize, height: role.frameSize)"))
        XCTAssertTrue(symbolIcon.contains(".contentShape(Rectangle())"))
        XCTAssertTrue(symbolIcon.contains(".accessibilityHidden(isDecorative)"))
        XCTAssertTrue(iconStyle.contains("case .panelNavigation, .panelHeader, .panelMode: 18"))
        XCTAssertTrue(iconStyle.contains("case .toolbar, .panelNavigation:"))
        XCTAssertTrue(iconStyle.contains("AppControlSizes.iconHitRegion"))
        XCTAssertTrue(iconStyle.contains(".contentShape(Rectangle())"))
        XCTAssertGreaterThanOrEqual(
            controls.components(separatedBy: "AppControlSizes.iconHitRegion").count - 1,
            4
        )
        XCTAssertGreaterThanOrEqual(
            controls.components(separatedBy: ".contentShape(Rectangle())").count - 1,
            2
        )
        XCTAssertTrue(controls.contains(".help(title)"))
        XCTAssertTrue(controls.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(panelChrome.contains(
            "AppSymbolIcon(systemImage: AppSymbols.Action.more, role: .toolbar)"
        ))
        XCTAssertTrue(panelChrome.contains(
            ".help(L10n.text(\"更多小窗操作\", \"More Panel Actions\"))"
        ))
        XCTAssertTrue(panelChrome.contains(
            ".accessibilityLabel(L10n.text(\"更多小窗操作\", \"More Panel Actions\"))"
        ))
    }

    func testCompactPanelMotionAndTabGroupUseSharedContracts() throws {
        // D64 retires the simple tab strip; the live module controls still
        // have one spoken navigation label and respect reduced motion.
        let components = try D64MenuBarSource.source("MenuBarAdvanced/GeekPanelComponents.swift")
        let control = try r2SourceDeclaration("struct GeekOverviewModuleButton<", in: components)
        XCTAssertTrue(control.contains(".accessibilityLabel(accessibilityLabel ?? destination.title)"))
        XCTAssertTrue(control.contains(".environment(\\.geekCombinedCardIsSelected, isSelected)"))
        XCTAssertTrue(control.contains(".accessibilityHint(L10n.text(\"打开二级监控详情\", \"Open secondary monitoring details\"))"))
        let panel = try D64MenuBarSource.source("MenuBarAdvancedStatusView.swift")
        XCTAssertTrue(panel.contains("@Environment(\\.accessibilityReduceMotion) var reduceMotion"))
        XCTAssertTrue(panel.contains("reduceMotion: reduceMotion"))
        XCTAssertFalse(panel.contains(".snappy(duration: 0.30)"))
    }

    func testAppArtworkDefaultsToDecorativeButAllowsCallersToOptIn() throws {
        let cachedIconSource = try projectSource(
            "Sources/StorageCleanerMac/Views/CachedAppIconView.swift"
        )
        let artworkSource = try projectSource(
            "Sources/StorageCleanerMac/Support/AppArtwork.swift"
        )

        XCTAssertTrue(cachedIconSource.contains("isDecorative: Bool = true"))
        XCTAssertTrue(cachedIconSource.contains(".accessibilityHidden(isDecorative)"))
        XCTAssertTrue(artworkSource.contains("var isDecorative = true"))
        XCTAssertTrue(artworkSource.contains(".accessibilityHidden(isDecorative)"))
    }

    func testStartupConsoleExposesFocusedKeyboardAndVoiceOverContracts() throws {
        let dashboard = try projectSource(
            "Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsDashboardView.swift"
        )
        let app = try projectSource(
            "Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift"
        )
        let content = try projectSource(
            "Sources/StorageCleanerMac/Views/ContentView.swift"
        )

        XCTAssertTrue(dashboard.contains("@FocusState private var isSearchFocused: Bool"))
        XCTAssertTrue(dashboard.contains(".focused($isSearchFocused)"))
        XCTAssertTrue(dashboard.contains(".onKeyPress(.return)"))
        XCTAssertTrue(dashboard.contains(".onKeyPress(.space)"))
        XCTAssertTrue(dashboard.contains(".accessibilityLabel(L10n.text(\"搜索启动项\", \"Search startup items\"))"))
        XCTAssertTrue(dashboard.contains(".accessibilityLabel(L10n.text(\"允许以后启动 · \\(item.displayName)\", \"Allow future launches · \\(item.displayName)\"))"))
        XCTAssertTrue(dashboard.contains(".accessibilityValue(item.displayStatus)"))
        XCTAssertTrue(app.contains("@FocusedValue(\\.startupItemsKeyboardActions)"))
        XCTAssertTrue(app.contains("startupItemsKeyboardActions?.focusSearch()"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"r\", modifiers: [.command])"))
        XCTAssertTrue(app.contains(".keyboardShortcut(\"f\", modifiers: [.command])"))
        XCTAssertTrue(content.contains("\\.startupItemsKeyboardActions"))
        XCTAssertTrue(content.contains("storageCleanerFocusStartupItemsSearch"))
    }

    func testBenchmarkLeaderboardExposesCompleteRowsAndAnnouncesStateChanges() throws {
        let source = try projectSource(
            "Sources/StorageCleanerMac/Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift"
        )

        XCTAssertTrue(source.contains(".accessibilityAddTraits(.isHeader)"))
        XCTAssertTrue(source.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(source.contains(".accessibilityLabel(rowAccessibilityLabel("))
        XCTAssertTrue(source.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(source.contains("AccessibilityNotification.Announcement"))
        XCTAssertTrue(source.contains("L10n.text(\"名次\", \"Rank\")"))
        XCTAssertTrue(source.contains("L10n.text(\"电脑机型\", \"Computer model\")"))
        XCTAssertTrue(source.contains("L10n.text(\"芯片\", \"Chip\")"))
        XCTAssertTrue(source.contains("L10n.text(\"内存\", \"Memory\")"))
        XCTAssertTrue(source.contains("L10n.text(\"总分\", \"Total score\")"))
        XCTAssertTrue(source.contains("L10n.text(\"测试日期\", \"Test date\")"))
    }

    private func projectSource(_ relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
