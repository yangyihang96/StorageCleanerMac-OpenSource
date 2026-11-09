import Foundation
import XCTest

/// D272: the settings window was reorganized by moving rows between pages. Every
/// preference and action must stay reachable on the page that names it, and each
/// page must use the one set of rows.
final class SettingsInventoryTests: XCTestCase {
    private static let views = "Sources/StorageCleanerMac/Views/"
    private static let reminders = "Sources/StorageCleanerMac/Features/AppLifecycle/Reminders/UI/AppLifecycleReminderSettingsSection.swift"

    private static let inventory: [(page: String, items: [String])] = [
        (views + "Settings/SettingsGeneral.swift", [
            "selection: selectedLanguage", "selection: selectedAppearance", "selection: selectedCanvasTheme",
            "isOn: launchAtLoginBinding", "KeepMenuBarPanelAfterQuitToggle()", "SMAppService.openSystemSettingsLoginItems()",
        ]),
        (views + "Settings/SettingsCombinedStatusIcon.swift", [
            "selection: statusModeBinding", "selection: selectedStatusPreset", "$statusCustomDayHex", "$statusCustomNightHex",
            "$iconSize", "selection: ringStrokeBinding", "selection: volumeStyleBinding", "$showsBatteryPercentage",
            "$showsBatteryPercentageInConnectionSlot", "$showsChargingIndicator", "$showsChargingEffect",
            "$showsChargingBoltHeartbeat", "$showsPercentageWhenConnected", "$batterySymbolScale", "$usesBatteryStatusColors",
            "$batteryCriticalThreshold", "$batteryFullThreshold", "$wifiSymbolScale", "$showsWiFiIconForEthernet",
            "$showsWiFiIconForHotspot", "$showsWiFiIconForTemporaryConnection", "$showsWiFiIconForInternetSharing",
            "$bluetoothSymbolScale", "$replacesNetworkIconWithBluetoothAudio", "selection: iconChoiceBinding",
            "$usesBluetoothAudioVolumeColor", "$prioritizesNetworkErrorsOverBluetoothAudio",
        ]),
        (views + "MiniWindowConfigurationSettingsView.swift", [
            "draft.value.setModule(", "draft.value.moveModule(", "draft.reset()", "draft.cancel()", "apply()",
            "hiddenDiskKeysRaw = \"\"", "$notebookExample",
        ]),
        (views + "Settings/SettingsMiniWindow.swift", [
            "menuThemeBinding($menuThemeDarkID", "menuThemeBinding($menuThemeLightID", "isOn: $menuThemeVibrancy",
            "PanelMetricColorPicker(role: role)",
        ]),
        (views + "Settings/SettingsScan.swift", ["selection: selectedMaintenanceCadence"]),
        (reminders, [
            "binding(\\.offersCorrectUninstall)", "binding(\\.notifiesTrashSize)", "binding(\\.trashSizeThresholdBytes)",
            "binding(\\.notifiesLowDiskSpace)", "binding(\\.lowDiskSpaceThresholdBytes)", "confirmsReset = true",
        ]),
        (views + "SettingsView.swift", ["showsOperations = true", "AppLifecycleReminderSettingsSection()"]),
        (views + "Settings/SettingsAccess.swift", [
            "open: openFullDiskAccessSettings", "open: openFilesAndFoldersSettings", "open: openAppManagementSettings",
            "open: openNotificationSettings", "requestNotificationAccess()", "refreshAccessStatus()", "helperAccessActions",
            "fileOperationHelperRow", "$allowsPublicAddress", "$allowsCountryLookup",
        ]),
        (views + "Settings/SettingsAIAssistant.swift", [
            "isOn: switchBinding", "introSeen = true", "introSeen = false", "interface.decide(client.identity, grant)",
            "interface.decide(client.identity, .denied)", "interface.revoke(bindingKey:", "snippets.claudeDesktop",
            "snippets.claudeCode", "snippets.codex", "expanded: $showsAccessLog",
        ]),
        (views + "Settings/SettingsSystem.swift", [
            "fanControl.registerHelper()", "fanControl.migrateLegacyHelper()", "fanControl.openApprovalSettings()",
            "selection: fanControlModeBinding", "fanControl.reconnectHelper()", "fanControl.unregisterHelper()",
            "selection: $fanControl.selectedFanSet", "FanCurveEditor(", "fanControlSlider(",
        ]),
        (views + "Settings/SettingsUpdates.swift", [
            "updatePreferenceBinding(\\.automaticallyChecks)", "selection: updateFrequencyBinding", "isOn: automaticSilentUpdateBinding",
            "updatePreferenceBinding(\\.updatesAfterApplicationQuits)", "updatePreferenceBinding(\\.notifiesOnCompletion)",
            "updatePreferenceBinding(\\.scansExternalVolumes)", "setUpdateSource(method, isEnabled: $0)", "resetUpdateSources()",
        ]),
        (views + "Settings/SettingsAbout.swift", [
            "copyRuntimeDiagnostics()", "showsSupportExport = true", "buildInfo.commitDisplay", "runtimeInfo.bundleIdentifier",
            "runtimeInfo.kind.detail", "diagnosticValue", "runtimeInfo.distributionStatus", "runtimeInfo.authorizationStabilityStatus",
        ]),
    ]

    func testEveryPreferenceAndActionStaysOnItsPage() throws {
        for (page, items) in Self.inventory {
            let source = try text(page)
            for item in items {
                XCTAssertTrue(source.contains(item), "\(page): \(item)")
            }
        }
    }

    func testEveryPageIsReachableFromTheWindow() throws {
        let root = try text(Self.views + "SettingsView.swift")
        for declaration in ["ignoreListSettings", "miniWindowSettings", "permissionSetupSection", "networkPrivacySection",
                            "interfaceSection", "launchBehaviorSection", "maintenanceReminderSection", "fanControlSection",
                            "updateAutomationSection", "updateSourceSection", "aboutSection",
                            "AgentSettingsPage(interface: agentInterface)", "agentInterface.refreshForSettings()"] {
            XCTAssertTrue(root.contains(declaration), declaration)
        }
        let menuBar = try text(Self.views + "Settings/SettingsMiniWindow.swift")
        for part in ["CombinedStatusIconSettingsSection()", "MiniWindowConfigurationSettingsView(draft:", "panelAppearanceSection"] {
            XCTAssertTrue(menuBar.contains(part), part)
        }
    }

    /// The module list opens on its own part of the menu bar page, whichever part was last open.
    func testPanelSettingsLinksOpenTheModuleList() throws {
        for file in ["MenuBarPanelChrome.swift", "MiniWindowConfigurationSettingsView.swift"] {
            let source = try text(Self.views + file)
            XCTAssertTrue(source.contains("UserDefaults.standard.set(\"miniWindow\", forKey: \"settings.selected-category.v1\")\n"), file)
            XCTAssertTrue(source.contains("UserDefaults.standard.set(SettingsMenuBarPage.panelContent.rawValue, forKey: SettingsMenuBarPage.defaultsKey)"), file)
        }
    }

    func testPagesUseTheOneSetOfRows() throws {
        let pages = ["General", "MiniWindow", "Scan", "Access", "AIAssistant", "System", "Updates", "About", "CombinedStatusIcon", "PermissionRow"]
            .map { Self.views + "Settings/Settings\($0).swift" } + [Self.views + "SettingsView.swift", Self.reminders]
        for page in pages {
            let source = try text(page)
            for retired in ["LabeledContent(", "DisclosureGroup", "toggleStyle(.checkbox)", "LightfieldExpandableRow("] {
                XCTAssertFalse(source.contains(retired), "\(page): \(retired)")
            }
            XCTAssertNil(source.range(of: #"(^|\s)Section \{"#, options: .regularExpression), "\(page): a plain Section")
        }
        // One switch, in one place.
        let rows = try text(Self.views + "Settings/SettingsLightfield.swift")
        XCTAssertEqual(rows.components(separatedBy: "Toggle(title, isOn:").count - 1, 1)
    }

    private func text(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }
}
