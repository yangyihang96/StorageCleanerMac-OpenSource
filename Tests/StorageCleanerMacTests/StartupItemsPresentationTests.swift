import XCTest
@testable import StorageCleanerMac

final class StartupItemsPresentationTests: XCTestCase {
    func testPrimaryCategoryLabelsAllScannedItemsTruthfully() {
        XCTAssertEqual(StartupItemsCategory.all.title, L10n.text("全部", "All"))
    }

    func testDefaultCategoriesUseUserFacingConcepts() {
        XCTAssertEqual(StartupItemsCategory.loginItems.title, L10n.text("登录时打开", "Open at Login"))
        XCTAssertEqual(StartupItemsCategory.background.title, L10n.text("后台运行", "Background"))
        XCTAssertEqual(StartupItemsCategory.updatesAndSync.title, L10n.text("更新与同步", "Updates & Sync"))
        XCTAssertEqual(StartupItemsCategory.attention.title, L10n.text("需要关注", "Needs Attention"))
    }

    func testDefaultListHidesAppleSystemItemsButKeepsUnknownItems() {
        let user = item(id: "user", kind: .userLaunchAgent, scope: .currentUser, name: "Sync Agent")
        var system = item(id: "system", kind: .systemLaunchDaemon, scope: .system, name: "Apple Daemon")
        system.components[0].state.process = .running(pid: 1)
        system.state.process = .running(pid: 1)
        let unknown = item(id: "unknown", kind: .unknown, scope: .unknown, name: "Unknown Background Item")

        let presentation = StartupItemsPresentation.make(
            items: [system, unknown, user],
            query: "",
            filter: .all
        )

        XCTAssertEqual(Set(presentation.visibleItems.map(\.id)), ["user", "unknown"])
        XCTAssertEqual(presentation.summary.total, 2)
        XCTAssertEqual(presentation.summary.manageable, 0)
        XCTAssertEqual(presentation.summary.unidentified, 2)
        XCTAssertEqual(presentation.summary.background, 1)
    }

    func testDefaultListDoesNotHideItemsBasedOnAppleLookingLabelOrKindAlone() {
        var spoofed = item(
            id: "spoofed",
            kind: .systemLaunchAgent,
            scope: .system,
            name: "com.apple.lookalike"
        )
        spoofed.components[0].plistURL = URL(fileURLWithPath: "/Library/LaunchAgents/com.apple.lookalike.plist")
        spoofed.components[0].diagnosticEvidence = ["apple-system-location"]

        let presentation = StartupItemsPresentation.make(
            items: [spoofed],
            query: "",
            filter: .all
        )

        XCTAssertEqual(presentation.visibleItems.map(\.id), ["spoofed"])
        XCTAssertFalse(spoofed.isAppleSystem)
    }

    func testDefaultListHidesProtectedAppleBackgroundTask() {
        var candidate = component(
            id: "apple-btm",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Apple Background Task"
        )
        candidate.source = .backgroundTaskDiagnostic
        candidate.plistURL = nil
        candidate.executableURL = URL(
            fileURLWithPath: "/System/Library/PrivateFrameworks/Example.framework/Versions/A/Helper"
        )
        var appleBTM = item(
            id: "apple-btm",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Apple Background Task"
        )
        appleBTM.components = [candidate]

        let all = StartupItemsPresentation.make(items: [appleBTM], query: "", filter: .all)
        let system = StartupItemsPresentation.make(items: [appleBTM], query: "", filter: .appleSystem)

        XCTAssertTrue(all.visibleItems.isEmpty)
        XCTAssertEqual(system.visibleItems.map(\.id), ["apple-btm"])
        XCTAssertTrue(appleBTM.isAppleSystem)
    }

    func testProtectedSystemApplicationIsAppleRegardlessOfScannerSource() {
        var maps = component(
            id: "maps-login",
            kind: .openAtLogin,
            scope: .currentUser,
            name: "Maps"
        )
        maps.source = .openAtLogin
        maps.applicationURL = URL(fileURLWithPath: "/System/Applications/Maps.app")
        maps.executableURL = URL(fileURLWithPath: "/System/Applications/Maps.app/Contents/MacOS/Maps")
        let item = StartupItemsDomain.Item(
            id: maps.id,
            kind: maps.kind,
            scope: maps.scope,
            name: maps.name,
            components: [maps],
            state: maps.state,
            attribution: maps.attribution,
            actionCapability: maps.actionCapability,
            warnings: []
        )

        XCTAssertTrue(item.isAppleSystem)
        XCTAssertTrue(
            StartupItemsPresentation.make(items: [item], query: "", filter: .all).visibleItems.isEmpty
        )
        XCTAssertEqual(
            StartupItemsPresentation.make(items: [item], query: "", filter: .appleSystem)
                .visibleItems.map(\.id),
            ["maps-login"]
        )
    }

    func testOnlyExplicitAppleFilterCanExposeProtectedSystemItems() {
        func protectedItem(
            id: String,
            kind: StartupItemsDomain.ItemKind,
            enablement: StartupItemsDomain.EnablementState = .enabled,
            managed: Bool = false
        ) -> StartupItemsDomain.Item {
            var candidate = component(
                id: id,
                kind: kind,
                scope: .system,
                name: id,
                enablement: enablement
            )
            candidate.applicationURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            if managed { candidate.state.management = .managedByOrganization }
            if kind == .orphanedItem { candidate.diagnosticEvidence.append("target-missing") }
            return StartupItemsDomain.Item(
                id: id,
                kind: kind,
                scope: candidate.scope,
                name: candidate.name,
                components: [candidate],
                state: candidate.state,
                attribution: nil,
                actionCapability: .readOnly,
                warnings: []
            )
        }

        let protectedItems = [
            protectedItem(id: "open", kind: .openAtLogin),
            protectedItem(id: "user", kind: .userLaunchAgent),
            protectedItem(id: "global", kind: .systemLaunchAgent),
            protectedItem(id: "daemon", kind: .systemLaunchDaemon, enablement: .disabled),
            protectedItem(id: "managed", kind: .managedItem, managed: true),
            protectedItem(id: "orphan", kind: .orphanedItem),
        ]
        let ordinaryFilters = StartupItemsListFilter.allCases.filter { $0 != .appleSystem }

        for filter in ordinaryFilters {
            XCTAssertTrue(
                StartupItemsPresentation.make(items: protectedItems, query: "", filter: filter)
                    .visibleItems.isEmpty,
                "Protected Apple items leaked through \(filter.rawValue)"
            )
        }
        XCTAssertEqual(
            Set(StartupItemsPresentation.make(items: protectedItems, query: "", filter: .appleSystem)
                .visibleItems.map(\.id)),
            Set(protectedItems.map(\.id))
        )
    }

    func testApplicationIconUsesOnlyReliableParentApplication() {
        var lowConfidence = component(
            id: "low",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Helper"
        )
        lowConfidence.attribution = attribution(confidence: .low)
        lowConfidence.applicationURL = URL(fileURLWithPath: "/Applications/Product.app")
        var lowItem = item(id: "low", kind: .userLaunchAgent, scope: .currentUser, name: "Helper")
        lowItem.components = [lowConfidence]
        lowItem.attribution = lowConfidence.attribution

        var verified = component(
            id: "verified",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Helper"
        )
        verified.applicationURL = URL(fileURLWithPath: "/Applications/Product.app")
        verified.attribution = attribution(confidence: .high)
        let verifiedItem = StartupItemsDomain.Item(
            id: "verified",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Helper",
            components: [verified],
            state: verified.state,
            attribution: verified.attribution,
            actionCapability: verified.actionCapability,
            warnings: []
        )

        XCTAssertNil(lowItem.applicationIconPath)
        XCTAssertEqual(verifiedItem.applicationIconPath, "/Applications/Product.app")
    }

    func testMissingIconsUseNativeSystemFallbacks() {
        let apple = item(
            id: "apple-icon",
            kind: .systemLaunchDaemon,
            scope: .system,
            name: "Apple Daemon"
        )
        let thirdParty = item(
            id: "third-party-icon",
            kind: .launchDaemon,
            scope: .allUsers,
            name: "Vendor Daemon"
        )

        XCTAssertEqual(apple.fallbackSystemImage, "apple.logo")
        XCTAssertEqual(thirdParty.fallbackSystemImage, thirdParty.kind.systemImage)
    }

    func testLowConfidenceAttributionCannotDriveTopLevelIdentityOrParentAction() throws {
        var candidate = component(
            id: "low-identity",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Raw Helper"
        )
        candidate.attribution = attribution(confidence: .low)
        candidate.applicationURL = URL(fileURLWithPath: "/Applications/Product.app")
        candidate.actionCapability.canOpenParentApp = true

        let lowItem = try XCTUnwrap(StartupItemMerger().merge([candidate]).first)
        let lowCapability = StartupItemsDomain.StartupCapabilityResolver(
            platform: .nonSandboxDirect,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        ).capability(for: candidate)

        XCTAssertEqual(lowItem.name, "Raw Helper")
        XCTAssertEqual(lowItem.displayName, "Raw Helper")
        XCTAssertEqual(lowItem.developerDisplayName, L10n.text("开发者未知", "Unknown Developer"))
        XCTAssertFalse(lowItem.actionCapability.canOpenParentApp)
        XCTAssertFalse(lowCapability.canOpenParentApp)

        candidate.attribution = attribution(confidence: .high)
        let highItem = try XCTUnwrap(StartupItemMerger().merge([candidate]).first)
        let highCapability = StartupItemsDomain.StartupCapabilityResolver(
            platform: .nonSandboxDirect,
            homeDirectory: URL(fileURLWithPath: "/Users/test")
        ).capability(for: candidate)
        XCTAssertEqual(highItem.displayName, "Product")
        XCTAssertEqual(highItem.developerDisplayName, "Example")
        XCTAssertTrue(highItem.actionCapability.canOpenParentApp)
        XCTAssertTrue(highCapability.canOpenParentApp)
    }

    func testInspectorLabelsLowConfidenceAttributionWithoutExposingIdentityFields() {
        var candidate = component(
            id: "low-inspector-identity",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Raw Helper"
        )
        candidate.attribution = attribution(confidence: .low)
        candidate.applicationURL = URL(fileURLWithPath: "/Applications/Product.app")

        let low = StartupInspectorIdentityPresentation.make(candidate: candidate)

        XCTAssertEqual(low.applicationLabel, L10n.text("可能所属（低可信）", "Possible Application (Low Confidence)"))
        XCTAssertEqual(low.applicationName, "Product")
        XCTAssertNil(low.applicationURL)
        XCTAssertNil(low.bundleIdentifier)
        XCTAssertNil(low.teamIdentifier)

        candidate.attribution = attribution(confidence: .high)
        let high = StartupInspectorIdentityPresentation.make(candidate: candidate)
        XCTAssertEqual(high.applicationLabel, L10n.text("所属应用", "Application"))
        XCTAssertEqual(high.applicationURL?.path, "/Applications/Product.app")
        XCTAssertEqual(high.bundleIdentifier, "com.example.product")
        XCTAssertEqual(high.teamIdentifier, "TEAM123")
    }

    func testMixedComponentEnablementDisplaysPartiallyDisabled() {
        var enabled = component(
            id: "enabled-component",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Enabled",
            enablement: .enabled
        )
        var disabled = component(
            id: "disabled-component",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Disabled",
            enablement: .disabled
        )
        enabled.attribution = attribution(confidence: .high)
        disabled.attribution = attribution(confidence: .high)
        let item = StartupItemsDomain.Item(
            id: "mixed",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Product",
            components: [enabled, disabled],
            state: disabled.state,
            attribution: enabled.attribution,
            actionCapability: .readOnly,
            warnings: []
        )

        XCTAssertTrue(item.isPartiallyDisabled)
        XCTAssertEqual(item.displayStatus, L10n.text("部分停用", "Partially Disabled"))
    }

    func testRawLaunchdLabelRemainsVisibleWithoutInventingOwner() throws {
        var candidate = component(
            id: "ai.openclaw.gateway",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "ai.openclaw.gateway"
        )
        candidate.label = "ai.openclaw.gateway"

        let item = try XCTUnwrap(StartupItemMerger().merge([candidate]).first)

        XCTAssertEqual(item.displayName, "ai.openclaw.gateway")
        XCTAssertEqual(
            item.developerDisplayName,
            L10n.text("开发者未知", "Unknown Developer")
        )
    }

    func testAppleAdvancedFilterUsesAppleDeveloperAndManagedStatus() {
        let apple = item(
            id: "apple-row",
            kind: .systemLaunchAgent,
            scope: .system,
            name: "com.apple.fixture"
        )

        XCTAssertTrue(apple.isAppleSystem)
        XCTAssertEqual(apple.developerDisplayName, "Apple")
        XCTAssertEqual(apple.displayStatus, L10n.text("由 macOS 管理", "Managed by macOS"))
        XCTAssertEqual(
            StartupItemsPresentation.make(items: [apple], query: "", filter: .appleSystem)
                .visibleItems.map(\.id),
            ["apple-row"]
        )
    }

    func testSummaryAndFiltersUseNormalizedComponentKindsAndStates() {
        let login = item(id: "login", kind: .openAtLogin, scope: .currentUser, name: "Login App")
        let disabled = item(
            id: "disabled",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Disabled Agent",
            enablement: .disabled
        )
        let daemon = item(id: "daemon", kind: .launchDaemon, scope: .allUsers, name: "Vendor Daemon")
        let orphan = item(id: "orphan", kind: .orphanedItem, scope: .currentUser, name: "Old Helper")
        var running = item(id: "running", kind: .appBackgroundTask, scope: .currentUser, name: "Running Helper")
        running.components[0].state.process = .running(pid: 42)
        running.state.process = .running(pid: 42)
        let items = [login, disabled, daemon, orphan, running]

        let all = StartupItemsPresentation.make(items: items, query: "", filter: .all)

        XCTAssertEqual(all.summary.openAtLogin, 1)
        XCTAssertEqual(all.summary.background, 3)
        XCTAssertEqual(all.summary.manageable, 0)
        XCTAssertEqual(all.summary.unidentified, 5)
        XCTAssertEqual(all.summary.orphaned, 1)
        XCTAssertEqual(
            StartupItemsPresentation.make(items: items, query: "", filter: .disabled).visibleItems.map(\.id),
            ["disabled"]
        )
        XCTAssertEqual(
            StartupItemsPresentation.make(items: items, query: "", filter: .daemons).visibleItems.map(\.id),
            ["daemon"]
        )
        XCTAssertEqual(
            StartupItemsPresentation.make(items: items, query: "", filter: .background).visibleItems.map(\.id),
            ["disabled", "running", "daemon"]
        )
    }

    func testDirectlyManageableItemsFilterAndSortAheadOfUnknownReadOnlyItems() {
        var direct = item(
            id: "direct",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Known App"
        )
        direct.components[0].state.management = .directlyManageable
        direct.components[0].actionCapability.canDisableDirectly = true
        direct.attribution = attribution(confidence: .high)
        direct.components[0].attribution = direct.attribution
        var disabledWithoutEnablePermission = item(
            id: "disabled-read-only",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Disabled Read Only",
            enablement: .disabled
        )
        disabledWithoutEnablePermission.components[0].state.management = .directlyManageable
        disabledWithoutEnablePermission.components[0].actionCapability.canDisableDirectly = true
        var settings = item(
            id: "settings",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Settings Managed"
        )
        settings.components[0].state.management = .manageableInSystemSettings
        settings.components[0].actionCapability.canOpenSystemSettings = true
        settings.attribution = attribution(confidence: .high)
        settings.components[0].attribution = settings.attribution
        var administrator = item(
            id: "administrator",
            kind: .launchDaemon,
            scope: .allUsers,
            name: "Administrator Managed"
        )
        administrator.components[0].state.management = .requiresAdministrator
        administrator.components[0].actionCapability.requiresAdministrator = true
        let unknown = item(
            id: "unknown",
            kind: .launchDaemon,
            scope: .allUsers,
            name: "Unknown Background Item"
        )

        let all = StartupItemsPresentation.make(
            items: [unknown, direct],
            query: "",
            filter: .all
        )

        XCTAssertEqual(all.visibleItems.map(\.id), ["direct", "unknown"])
        XCTAssertEqual(all.summary.manageable, 1)
        XCTAssertEqual(
            StartupItemsPresentation.make(
                items: [unknown, disabledWithoutEnablePermission, direct],
                query: "",
                filter: .directlyManageable
            ).visibleItems.map(\.id),
            ["direct"]
        )
        XCTAssertEqual(
            Set(StartupItemsPresentation.make(
                items: [unknown, disabledWithoutEnablePermission, settings, administrator, direct],
                query: "",
                filter: .actionable
            ).visibleItems.map(\.id)),
            ["direct", "settings", "administrator"]
        )
    }

    func testPrimaryConsoleKeepsEveryNonAppleResultVisible() {
        var direct = item(
            id: "direct-primary",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Direct"
        )
        direct.components[0].state.management = .directlyManageable
        direct.components[0].actionCapability.canDisableDirectly = true
        direct.attribution = attribution(confidence: .high)
        direct.components[0].attribution = direct.attribution

        var settings = item(
            id: "settings-primary",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Settings"
        )
        settings.components[0].state.management = .manageableInSystemSettings
        settings.components[0].actionCapability.canOpenSystemSettings = true
        settings.attribution = attribution(confidence: .high)
        settings.components[0].attribution = settings.attribution

        var informationOnly = item(
            id: "technical-only",
            kind: .unknown,
            scope: .unknown,
            name: "Unknown Background Item"
        )
        informationOnly.components[0].state.management = .unsupported
        let items = [informationOnly, settings, direct]

        let primary = StartupItemsPresentation.make(
            items: items,
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        XCTAssertEqual(Set(primary.visibleItems.map(\.id)), Set(items.map(\.id)))

        let attention = StartupItemsPresentation.make(
            items: items,
            query: "",
            category: .attention,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        XCTAssertEqual(attention.visibleItems.map(\.id), ["technical-only"])
        XCTAssertEqual(attention.visibleItems.first?.displayName, "Unknown Background Item")
        XCTAssertFalse(informationOnly.isActionable)
        XCTAssertFalse(attention.allowsStartupMutationActions)

        let technical = StartupItemsPresentation.make(
            items: items,
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: true
        )
        XCTAssertEqual(Set(technical.visibleItems.map(\.id)), Set(items.map(\.id)))
    }

    func testPrimaryConsoleKeepsUnattributedSystemSettingsRowsVisible() {
        var unknownSettings = item(
            id: "unknown-settings",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "com.example.unknown.helper"
        )
        unknownSettings.components[0].state.management = .manageableInSystemSettings
        unknownSettings.components[0].actionCapability.canOpenSystemSettings = true

        let primary = StartupItemsPresentation.make(
            items: [unknownSettings],
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        let technical = StartupItemsPresentation.make(
            items: [unknownSettings],
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: true
        )

        XCTAssertEqual(primary.visibleItems.map(\.id), ["unknown-settings"])
        XCTAssertEqual(technical.visibleItems.map(\.id), ["unknown-settings"])
        let attention = StartupItemsPresentation.make(
            items: [unknownSettings],
            query: "",
            category: .attention,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        XCTAssertEqual(attention.visibleItems.map(\.id), ["unknown-settings"])
        XCTAssertFalse(attention.allowsStartupMutationActions)
        XCTAssertEqual(
            unknownSettings.managementExplanation,
            L10n.text(
                "由 macOS 系统设置管理，本应用只会打开对应设置页。",
                "Managed by macOS System Settings; this app only opens the relevant settings page."
            )
        )
    }

    func testPrimaryProjectionKeepsLowConfidenceRowsVisibleWithoutInventingTrust() {
        var lowConfidenceDirect = item(
            id: "low-direct",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Low Confidence Direct"
        )
        lowConfidenceDirect.components[0].state.management = .directlyManageable
        lowConfidenceDirect.components[0].actionCapability.canDisableDirectly = true
        lowConfidenceDirect.attribution = attribution(confidence: .low)
        lowConfidenceDirect.components[0].attribution = lowConfidenceDirect.attribution

        var lowConfidenceSettings = item(
            id: "low-settings",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Low Confidence Settings"
        )
        lowConfidenceSettings.components[0].state.management = .manageableInSystemSettings
        lowConfidenceSettings.components[0].actionCapability.canOpenSystemSettings = true
        lowConfidenceSettings.attribution = attribution(confidence: .low)
        lowConfidenceSettings.components[0].attribution = lowConfidenceSettings.attribution

        var protected = item(
            id: "protected",
            kind: .privilegedHelper,
            scope: .allUsers,
            name: "Protected System Item"
        )
        protected.components[0].state.management = .systemProtected
        protected.attribution = attribution(confidence: .high)
        protected.components[0].attribution = protected.attribution

        var lowConfidenceReadOnly = item(
            id: "low-read-only",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Low Confidence Read-only"
        )
        lowConfidenceReadOnly.attribution = attribution(confidence: .low)
        lowConfidenceReadOnly.components[0].attribution = lowConfidenceReadOnly.attribution

        let items = [
            lowConfidenceDirect,
            lowConfidenceSettings,
            lowConfidenceReadOnly,
            protected,
        ]
        let primary = StartupItemsPresentation.make(
            items: items,
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        let technical = StartupItemsPresentation.make(
            items: items,
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: true
        )

        XCTAssertEqual(Set(primary.visibleItems.map(\.id)), Set(items.map(\.id)))
        XCTAssertEqual(Set(technical.visibleItems.map(\.id)), Set(items.map(\.id)))
        XCTAssertEqual(lowConfidenceDirect.manageability, .directlyManageable)
        XCTAssertEqual(lowConfidenceSettings.manageability, .manageableThroughSystemSettings)
        XCTAssertEqual(lowConfidenceReadOnly.manageability, .protectedSystemItem)
        XCTAssertEqual(protected.manageability, .protectedSystemItem)

        let attention = StartupItemsPresentation.make(
            items: items,
            query: "",
            category: .attention,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        XCTAssertEqual(
            Set(attention.visibleItems.map(\.id)),
            ["low-direct", "low-settings"]
        )
        XCTAssertFalse(attention.allowsStartupMutationActions)
    }

    func testPrimaryConsoleRequiresExactManageabilityAndKnownEnablement() {
        var direct = item(
            id: "direct-exact",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Direct Exact"
        )
        direct.attribution = attribution(confidence: .high)
        direct.components[0].attribution = direct.attribution
        direct.components[0].state.management = .directlyManageable
        direct.components[0].actionCapability.canDisableDirectly = true

        var settings = item(
            id: "settings-exact",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Settings Exact"
        )
        settings.attribution = attribution(confidence: .high)
        settings.components[0].attribution = settings.attribution
        settings.components[0].state.management = .manageableInSystemSettings
        settings.components[0].actionCapability.canOpenSystemSettings = true

        var misleadingSettings = settings
        misleadingSettings = StartupItemsDomain.Item(
            id: "settings-misleading",
            kind: misleadingSettings.kind,
            scope: misleadingSettings.scope,
            name: misleadingSettings.name,
            components: misleadingSettings.components,
            state: misleadingSettings.state,
            attribution: misleadingSettings.attribution,
            actionCapability: misleadingSettings.actionCapability,
            warnings: misleadingSettings.warnings
        )
        misleadingSettings.components[0].state.management = .unsupported

        var unknownState = direct
        unknownState = StartupItemsDomain.Item(
            id: "direct-unknown-state",
            kind: unknownState.kind,
            scope: unknownState.scope,
            name: unknownState.name,
            components: unknownState.components,
            state: unknownState.state,
            attribution: unknownState.attribution,
            actionCapability: unknownState.actionCapability,
            warnings: unknownState.warnings
        )
        unknownState.components[0].state.enablement = .unknown

        XCTAssertEqual(direct.manageability, .directlyManageable)
        XCTAssertEqual(settings.manageability, .manageableThroughSystemSettings)
        XCTAssertEqual(misleadingSettings.manageability, .informationOnly)
        XCTAssertEqual(unknownState.manageability, .informationOnly)

        let primary = StartupItemsPresentation.make(
            items: [direct, settings, misleadingSettings, unknownState],
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        XCTAssertEqual(
            Set(primary.visibleItems.map(\.id)),
            Set(["direct-exact", "settings-exact", "settings-misleading", "direct-unknown-state"])
        )
    }

    func testPrimarySearchOnlyMatchesApplicationDeveloperOrPurpose() {
        var product = item(
            id: "search-primary",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Product"
        )
        product.attribution = attribution(confidence: .high)
        product.components[0].attribution = product.attribution
        product.components[0].label = "com.example.product.hidden-helper"
        product.components[0].state.management = .manageableInSystemSettings
        product.components[0].actionCapability.canOpenSystemSettings = true

        func search(_ query: String) -> [String] {
            StartupItemsPresentation.make(
                items: [product],
                query: query,
                category: .all,
                status: .all,
                source: .all,
                includeAppleSystem: false,
                sort: .recommended,
                includeTechnicalDetails: true
            ).visibleItems.map(\.id)
        }

        XCTAssertEqual(search("Product"), ["search-primary"])
        XCTAssertEqual(search("Example"), ["search-primary"])
        XCTAssertTrue(search("TEAM123").isEmpty)
        XCTAssertTrue(search("hidden-helper").isEmpty)
    }

    func testDefaultCategoryCountsStayStableWhenAttentionIsSelected() {
        var direct = item(
            id: "count-direct",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Direct"
        )
        direct.components[0].state.management = .directlyManageable
        direct.components[0].actionCapability.canDisableDirectly = true
        direct.attribution = attribution(confidence: .high)
        direct.components[0].attribution = direct.attribution
        var technicalOnly = item(
            id: "count-technical",
            kind: .unknown,
            scope: .unknown,
            name: "Technical Only"
        )
        technicalOnly.components[0].state.management = .unsupported
        var attributedReview = item(
            id: "count-attributed-review",
            kind: .unknown,
            scope: .unknown,
            name: "Attributed Review"
        )
        attributedReview.components[0].state.management = .unsupported
        attributedReview.attribution = attribution(confidence: .low)
        attributedReview.components[0].attribution = attributedReview.attribution

        let all = StartupItemsPresentation.make(
            items: [direct, technicalOnly, attributedReview],
            query: "",
            category: .all,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )
        let attention = StartupItemsPresentation.make(
            items: [direct, technicalOnly, attributedReview],
            query: "",
            category: .attention,
            status: .all,
            source: .all,
            includeAppleSystem: false,
            sort: .recommended,
            includeTechnicalDetails: false
        )

        XCTAssertEqual(all.count(for: .all), 3)
        XCTAssertEqual(attention.count(for: .all), 3)
        XCTAssertEqual(all.count(for: .attention), 2)
        XCTAssertEqual(attention.count(for: .attention), 2)
        XCTAssertEqual(
            Set(attention.visibleItems.map(\.id)),
            ["count-technical", "count-attributed-review"]
        )
        XCTAssertEqual(technicalOnly.displayName, "Technical Only")
        XCTAssertFalse(technicalOnly.isActionable)
        XCTAssertFalse(attention.allowsStartupMutationActions)
    }

    func testAppleTechnicalItemUsesStableLabelInsteadOfUnknownTitle() {
        var candidate = component(
            id: "apple-technical-label",
            kind: .systemLaunchAgent,
            scope: .system,
            name: "Raw Apple Helper",
            label: "com.apple.stable.helper"
        )
        candidate.attribution = nil
        let apple = StartupItemsDomain.Item(
            id: candidate.id,
            kind: candidate.kind,
            scope: candidate.scope,
            name: candidate.name,
            components: [candidate],
            state: candidate.state,
            attribution: nil,
            actionCapability: candidate.actionCapability,
            warnings: []
        )

        XCTAssertTrue(apple.isAppleSystem)
        XCTAssertEqual(apple.displayName, "com.apple.stable.helper")
        XCTAssertNotEqual(
            apple.displayName,
            L10n.text("未知后台项目", "Unknown Background Item")
        )

        var sourceOnlyCandidate = component(
            id: "apple-technical-source",
            kind: .appBackgroundTask,
            scope: .system,
            name: L10n.text("未知后台项目", "Unknown Background Item")
        )
        sourceOnlyCandidate.source = .backgroundTaskDiagnostic
        sourceOnlyCandidate.plistURL = nil
        sourceOnlyCandidate.diagnosticEvidence = ["apple-system-signature"]
        let sourceOnlyApple = StartupItemsDomain.Item(
            id: sourceOnlyCandidate.id,
            kind: sourceOnlyCandidate.kind,
            scope: sourceOnlyCandidate.scope,
            name: sourceOnlyCandidate.name,
            components: [sourceOnlyCandidate],
            state: sourceOnlyCandidate.state,
            attribution: nil,
            actionCapability: sourceOnlyCandidate.actionCapability,
            warnings: []
        )

        XCTAssertTrue(sourceOnlyApple.isAppleSystem)
        XCTAssertEqual(
            sourceOnlyApple.displayName,
            L10n.text(
                "Apple 系统项目 · 后台任务诊断",
                "Apple System Item · Background Task Diagnostic"
            )
        )
    }

    func testGroupedApplicationShowsLoginAndBackgroundStatesSeparately() {
        let login = component(
            id: "group-login",
            kind: .openAtLogin,
            scope: .currentUser,
            name: "Product",
            enablement: .enabled
        )
        let background = component(
            id: "group-background",
            kind: .appBackgroundTask,
            scope: .currentUser,
            name: "Product Helper",
            enablement: .disabled
        )
        let grouped = StartupItemsDomain.Item(
            id: "grouped",
            kind: .openAtLogin,
            scope: .currentUser,
            name: "Product",
            components: [login, background],
            state: login.state,
            attribution: attribution(confidence: .high),
            actionCapability: .readOnly,
            warnings: []
        )

        XCTAssertEqual(grouped.loginItemStatusText, L10n.text("登录时打开：开启", "Open at Login: On"))
        XCTAssertEqual(grouped.backgroundItemStatusText, L10n.text("后台运行：关闭", "Background: Off"))
    }

    func testOnDemandStatusUsesPlainEnabledNotRunningCopy() {
        var onDemand = item(
            id: "on-demand",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "On Demand"
        )
        onDemand.state.load = .onDemand
        onDemand.state.process = .stopped

        XCTAssertEqual(
            onDemand.displayStatus,
            L10n.text("已启用 · 当前未运行", "Enabled · Not Running")
        )
        XCTAssertEqual(
            onDemand.statusDetailText,
            L10n.text(
                "由 macOS 在应用或系统事件需要时启动",
                "macOS starts it only when an app or system event needs it"
            )
        )
    }

    func testRunningSummaryDoesNotClaimZeroWhenRuntimeStateIsUnknown() {
        var unknown = item(
            id: "unknown-runtime",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Unknown Runtime"
        )
        unknown.components[0].state.process = .unknown
        unknown.state.process = .unknown
        XCTAssertEqual(
            unknown.runningSummaryText,
            L10n.text("运行状态待确认", "Runtime state pending")
        )

        unknown.components[0].state.process = .stopped
        unknown.state.process = .stopped
        XCTAssertEqual(unknown.runningSummaryText, L10n.text("0 个正在运行", "0 running"))
    }

    func testSearchMatchesApplicationIdentityLabelAndPath() {
        let candidate = component(
            id: "agent",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Updater",
            label: "com.example.product.updater"
        )
        let attribution = StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.product",
            applicationURL: URL(fileURLWithPath: "/Applications/Product.app"),
            applicationName: "Product",
            developerName: "Example Corp",
            teamIdentifier: "TEAM123",
            designatedRequirement: nil,
            evidence: [
                StartupItemsDomain.AttributionEvidence(
                    kind: .associatedBundleIdentifier,
                    value: "com.example.product",
                    confidence: .verified
                ),
            ]
        )
        let item = StartupItemsDomain.Item(
            id: "product",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Product",
            components: [candidate],
            state: candidate.state,
            attribution: attribution,
            actionCapability: candidate.actionCapability,
            warnings: []
        )

        XCTAssertEqual(
            StartupItemsPresentation.make(items: [item], query: "TEAM123", filter: .all).visibleItems.map(\.id),
            ["product"]
        )
        XCTAssertEqual(
            StartupItemsPresentation.make(items: [item], query: "product.updater", filter: .all).visibleItems.map(\.id),
            ["product"]
        )
    }

    func testConsoleCategoriesAreMutuallyExclusiveAndCountsAreExplainable() {
        let login = item(id: "login", kind: .openAtLogin, scope: .currentUser, name: "Login App")
        let agent = item(id: "agent", kind: .userLaunchAgent, scope: .currentUser, name: "User Agent")
        let daemon = item(id: "daemon", kind: .launchDaemon, scope: .allUsers, name: "Daemon")
        var combined = item(id: "combined", kind: .userLaunchAgent, scope: .currentUser, name: "Combined")
        combined.components.append(component(
            id: "combined-daemon",
            kind: .launchDaemon,
            scope: .allUsers,
            name: "Combined Daemon"
        ))

        let all = consolePresentation(items: [login, agent, daemon, combined])

        XCTAssertEqual(all.count(for: .all), 4)
        XCTAssertEqual(all.count(for: .loginItems), 1)
        XCTAssertEqual(all.count(for: .background), 3)
        XCTAssertEqual(all.count(for: .updatesAndSync), 0)
        XCTAssertEqual(all.count(for: .attention), 0)
        XCTAssertEqual(
            all.count(for: .loginItems)
                + all.count(for: .background)
                + all.count(for: .updatesAndSync)
                + all.count(for: .attention),
            all.count(for: .all)
        )
        XCTAssertEqual(
            Set(consolePresentation(items: [login, agent, daemon, combined], category: .background)
                .visibleItems.map(\.id)),
            ["agent", "daemon", "combined"]
        )
    }

    func testLoginCategoryKeepsItemsThatAlsoNeedAttention() {
        var login = item(
            id: "login-needs-attention",
            kind: .openAtLogin,
            scope: .currentUser,
            name: "Login App"
        )
        login.components[0].diagnosticEvidence = ["group-writable"]

        let all = consolePresentation(items: [login])

        XCTAssertEqual(all.count(for: .loginItems), 1)
        XCTAssertEqual(all.count(for: .attention), 1)
        XCTAssertEqual(
            consolePresentation(items: [login], category: .loginItems).visibleItems.map(\.id),
            ["login-needs-attention"]
        )
    }

    func testBackgroundCategoryKeepsItemsThatAlsoNeedAttention() {
        var background = item(
            id: "background-needs-attention",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Background Agent"
        )
        background.components[0].diagnosticEvidence = ["group-writable"]

        let all = consolePresentation(items: [background])

        XCTAssertEqual(all.count(for: .background), 1)
        XCTAssertEqual(all.count(for: .attention), 1)
        XCTAssertEqual(
            consolePresentation(items: [background], category: .background).visibleItems.map(\.id),
            ["background-needs-attention"]
        )
    }

    func testConsoleFiltersKeepConfigurationRuntimeAndCapabilitySeparate() {
        var disabledRunning = item(
            id: "disabled-running",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Disabled Running",
            enablement: .disabled
        )
        disabledRunning.components[0].state.process = .running(pid: 42)
        disabledRunning.state.process = .running(pid: 42)

        var invalid = item(
            id: "invalid",
            kind: .userLaunchAgent,
            scope: .currentUser,
            name: "Missing Target"
        )
        invalid.components[0].diagnosticEvidence = ["target-missing"]

        var administrator = item(
            id: "administrator",
            kind: .launchDaemon,
            scope: .allUsers,
            name: "Administrator Item"
        )
        administrator.components[0].state.management = .requiresAdministrator
        administrator.components[0].actionCapability.requiresAdministrator = true

        let items = [disabledRunning, invalid, administrator]

        XCTAssertEqual(
            disabledRunning.displayStatus,
            L10n.text("已禁用 · 本次会话仍在运行", "Disabled · Still Running This Session")
        )
        XCTAssertEqual(
            consolePresentation(items: items, status: .disabled).visibleItems.map(\.id),
            ["disabled-running"]
        )
        XCTAssertEqual(
            consolePresentation(items: items, status: .running).visibleItems.map(\.id),
            ["disabled-running"]
        )
        XCTAssertEqual(
            consolePresentation(items: items, status: .invalidConfiguration).visibleItems.map(\.id),
            ["invalid"]
        )
        XCTAssertEqual(
            consolePresentation(items: items, status: .requiresAdministrator).visibleItems.map(\.id),
            ["administrator"]
        )
    }

    func testConsoleCanExplicitlyShowAppleSystemItems() {
        let apple = item(
            id: "apple-console",
            kind: .systemLaunchAgent,
            scope: .system,
            name: "com.apple.fixture"
        )

        XCTAssertTrue(consolePresentation(items: [apple]).visibleItems.isEmpty)
        XCTAssertEqual(
            consolePresentation(items: [apple], includeAppleSystem: true).visibleItems.map(\.id),
            ["apple-console"]
        )
    }

    private func consolePresentation(
        items: [StartupItemsDomain.Item],
        category: StartupItemsCategory = .all,
        status: StartupItemsStatusFilter = .all,
        source: StartupItemsSourceFilter = .all,
        includeAppleSystem: Bool = false,
        sort: StartupItemsSortOrder = .recommended
    ) -> StartupItemsPresentation {
        StartupItemsPresentation.make(
            items: items,
            query: "",
            category: category,
            status: status,
            source: source,
            includeAppleSystem: includeAppleSystem,
            sort: sort
        )
    }

    private func item(
        id: String,
        kind: StartupItemsDomain.ItemKind,
        scope: StartupItemsDomain.Scope,
        name: String,
        enablement: StartupItemsDomain.EnablementState = .enabled
    ) -> StartupItemsDomain.Item {
        let candidate = component(
            id: id,
            kind: kind,
            scope: scope,
            name: name,
            enablement: enablement
        )
        return StartupItemsDomain.Item(
            id: id,
            kind: kind,
            scope: scope,
            name: name,
            components: [candidate],
            state: candidate.state,
            attribution: nil,
            actionCapability: candidate.actionCapability,
            warnings: []
        )
    }

    private func component(
        id: String,
        kind: StartupItemsDomain.ItemKind,
        scope: StartupItemsDomain.Scope,
        name: String,
        label: String? = nil,
        enablement: StartupItemsDomain.EnablementState = .enabled
    ) -> StartupItemsDomain.Candidate {
        var candidate = StartupItemsDomain.Candidate(
            id: id,
            source: .launchdPlist,
            kind: kind,
            scope: scope,
            name: name,
            label: label,
            plistURL: URL(fileURLWithPath: "/Users/test/Library/LaunchAgents/\(id).plist"),
            executableURL: URL(fileURLWithPath: "/Applications/\(name).app/Contents/MacOS/\(name)"),
            applicationURL: nil,
            configuration: nil,
            state: StartupItemsDomain.State(
                registration: .discoveredFromFile,
                authorization: .unknown,
                enablement: enablement,
                load: .notLoaded,
                process: .stopped,
                management: .readOnly
            ),
            attribution: nil,
            actionCapability: .readOnly,
            diagnosticEvidence: (kind == .systemLaunchAgent || kind == .systemLaunchDaemon)
                ? ["apple-system-location"] : []
        )
        if kind == .systemLaunchAgent || kind == .systemLaunchDaemon {
            let directory = kind == .systemLaunchAgent ? "LaunchAgents" : "LaunchDaemons"
            candidate.plistURL = URL(fileURLWithPath: "/System/Library/\(directory)/\(id).plist")
        }
        return candidate
    }

    private func attribution(
        confidence: StartupItemsDomain.AttributionConfidence
    ) -> StartupItemsDomain.Attribution {
        StartupItemsDomain.Attribution(
            applicationBundleIdentifier: "com.example.product",
            applicationURL: URL(fileURLWithPath: "/Applications/Product.app"),
            applicationName: "Product",
            developerName: "Example",
            teamIdentifier: "TEAM123",
            designatedRequirement: nil,
            evidence: [
                .init(kind: .labelHint, value: "product", confidence: confidence),
            ]
        )
    }
}
