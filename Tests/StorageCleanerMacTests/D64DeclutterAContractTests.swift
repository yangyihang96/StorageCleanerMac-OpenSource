import XCTest
import SwiftUI
@testable import StorageCleanerMac

/// D64 D1 + D3: model tables and wiring contracts distinguish decorative glyphs
/// from navigation, selection, progress, warning and privacy information.
/// No production stores, preferences, hardware or file operations are created.
final class D64DeclutterAContractTests: XCTestCase {
    func testTextActionsHideInlineIconsButKeepSelectionAndCompactFallback() throws {
        let controls = try source("Support/AppControls.swift")
        let label = try segment(controls, from: "private struct AdaptiveAppButtonLabel:", to: "struct AppButton:")
        XCTAssertTrue(label.contains("if showsInlineIcon {\n                actionIcon(systemImage: systemImage)"))
        XCTAssertTrue(label.contains("AppButtonIconPolicy.showsInlineIcon(kind: kind, systemImage: systemImage)"))
        let expected: [(AppButtonKind, Bool, Bool)] = [
            (.primary, false, false), (.secondary, false, true), (.tertiary, false, true),
            (.destructive, false, true), (.toolbar, false, true), (.icon, false, true),
            (.glass, false, true), (.glassProminent, false, false), (.menu, false, true),
            (.disclosure, true, true), (.smallUtility, false, true), (.metric, true, true),
            (.selectionRow, true, true),
        ]
        XCTAssertEqual(AppButtonKind.allCases, expected.map { $0.0 })
        for (kind, ordinary, external) in expected {
            XCTAssertFalse(AppButtonIconPolicy.showsInlineIcon(kind: kind, systemImage: nil), "\(kind)")
            for symbol in ["trash", "gearshape", "lock.fill", "arrow.clockwise"] {
                XCTAssertEqual(AppButtonIconPolicy.showsInlineIcon(kind: kind, systemImage: symbol), ordinary, "\(kind) / \(symbol)")
            }
            for symbol in ["arrow.up.right", "arrow.up.right.square"] {
                XCTAssertEqual(AppButtonIconPolicy.showsInlineIcon(kind: kind, systemImage: symbol), external, "\(kind) / \(symbol)")
            }
        }
        XCTAssertFalse(label.contains(".frame(width: 22, height: 22)"))
        XCTAssertFalse(label.contains("in: Circle()"))
        XCTAssertTrue(label.contains("Label(title, systemImage: systemImage)\n                        .labelStyle(.iconOnly)"))
        XCTAssertTrue(label.contains("wrappedTitleLabel"))
        XCTAssertTrue(controls.contains(".disabled(isDisabled || isLoading)"))
        XCTAssertTrue(controls.contains(".accessibilityLabel(title)"))
        let selection = try segment(controls, from: "struct AppSelectionButton:", to: "struct AppFilterButton:")
        XCTAssertTrue(selection.contains("kind: .selectionRow"))
        XCTAssertTrue(selection.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        let disclosure = try segment(controls, from: "struct AppDisclosureButton:", to: "#if DEBUG")
        XCTAssertTrue(disclosure.contains("isExpanded ? \"chevron.down\" : \"chevron.right\""))
    }

    @MainActor
    func testMetadataAndMetricsAreTextOnlyWithoutLosingValuesOrSpokenLabels() throws {
        let metadata = try source("Support/MetadataPill.swift")
        let ordinary = MetadataPill(text: "Count", systemImage: "exclamationmark.triangle.fill", tint: AppDesignTokens.Palette.warning)
        XCTAssertEqual(ordinary.status, .none)
        XCTAssertNil(ordinary.renderedSystemImage, "A legacy icon or warning color cannot opt in to status semantics")
        XCTAssertTrue(metadata.contains("Text(text)"))
        XCTAssertTrue(metadata.contains(".foregroundStyle(tint)"))
        XCTAssertTrue(metadata.contains(".glassCapsule(tint: tint)"))
        XCTAssertTrue(metadata.contains(".accessibilityElement(children: .ignore)"))
        XCTAssertTrue(metadata.contains(".accessibilityLabel(text)"))
        XCTAssertTrue(metadata.contains("if let renderedSystemImage {"))
        XCTAssertTrue(metadata.contains("Image(systemName: renderedSystemImage)"))
        XCTAssertTrue(metadata.contains(".accessibilityHidden(true)"))
        XCTAssertTrue(metadata.contains(".accessibilityValue(status.accessibilityDescription)"))
        let components = try source("Views/SmartCareComponents.swift")
        let metric = try segment(components, from: "struct SmartCareMetric:", to: "enum AppEmptyStateDensity")
        XCTAssertFalse(metric.contains("Image(systemName:"))
        XCTAssertTrue(metric.contains("Text(value)"))
        XCTAssertTrue(metric.contains("Text(title)"))
        XCTAssertTrue(metric.contains(".monospacedDigit()"))
        XCTAssertTrue(metric.contains(".accessibilityValue(value)"))
        XCTAssertTrue(metric.contains(".accessibilityLabel(title)"))
    }

    @MainActor
    func testEmptyStateHasNoStaticGlyphSlotWhileRealProgressAndResultsRemain() throws {
        let components = try source("Views/SmartCareComponents.swift")
        let empty = try segment(components, from: "struct AppEmptyState<Action:", to: "extension AppEmptyState")
        XCTAssertTrue(empty.contains("if isLoading {\n                AppStateIconRing(systemImage: systemImage, isActive: isLoading)"))
        XCTAssertTrue(empty.contains("Text(title)"))
        XCTAssertTrue(empty.contains("Text(detail)"))
        XCTAssertFalse(empty.contains(".lineLimit(1)"))
        let ring = try segment(components, from: "struct AppStateIconRing:", to: "struct AppEmptyState<Action:")
        XCTAssertTrue(ring.contains("} else if showsStaticStatus {"))
        XCTAssertTrue(ring.contains("return isActive || showsStaticStatus ? 32 : 0"))
        XCTAssertTrue(ring.contains("if progress != nil {"))
        XCTAssertTrue(ring.contains(".trim(from: 0, to: renderedProgress)"))
        XCTAssertTrue(ring.contains("CGFloat(min(1, max(0, progress ?? 0)))"))
        XCTAssertTrue(ring.contains("} else if isActive {\n                ProgressView()"))
        XCTAssertEqual(AppStateIconRole.allCases, [.decorative, .result])
        for symbol in ["checkmark", "checkmark.circle", "xmark.octagon.fill", "exclamationmark.circle", "minus.circle", "hourglass", "trash"] {
            let result = AppStateIconRing(systemImage: symbol)
            XCTAssertEqual(result.role, .result)
            XCTAssertTrue(result.showsStaticStatus, symbol)
            XCTAssertEqual(result.renderedSize, 32, symbol)
            let decoration = AppStateIconRing(systemImage: symbol, role: .decorative)
            XCTAssertFalse(decoration.showsStaticStatus, symbol)
            XCTAssertEqual(decoration.renderedSize, 0, symbol)
            XCTAssertEqual(AppStateIconRing(systemImage: symbol, isActive: true, role: .decorative).renderedSize, 32, symbol)
            XCTAssertEqual(AppStateIconRing(systemImage: symbol, size: 168, progress: 0.5, role: .decorative).renderedSize, 168, symbol)
        }
    }

    func testSettingsKeepSevenNavigationCategoriesWithoutDecoratedHeadingsOrTutorial() throws {
        let settings = try source("Views/SettingsView.swift")
        let category = try segment(settings, from: "enum SettingsCategory:", to: "struct SettingsView:")
        // D207＋旧值：七类，没有 "ignoreList"。D207 照 CleanMyMac 加了第八页“忽略列表”；
        // 不加装饰标题、不加教程的要求不变，新页签同样用插画（D207 补）。
        XCTAssertEqual(SettingsCategory.allCases.map(\.rawValue), ["general", "miniWindow", "scanAndSafety", "ignoreList", "accessAndSetup", "systemControl", "updates", "about"])
        for name in ["general", "miniWindow", "scanAndSafety", "ignoreList", "accessAndSetup", "systemControl", "updates", "about"] {
            XCTAssertTrue(category.contains("    case " + name), name)
        }
        XCTAssertFalse(category.contains("var subtitle:"))
        // D69/B6 replaces native grouped Settings with B2 artwork and flat rows.
        // Semantic palette checks and the inert status sample are not decoration.
        let lightfield = try source("Views/Settings/SettingsLightfield.swift")
        let header = try r2SourceDeclaration("struct SettingsLightfieldPane", in: lightfield)
        XCTAssertTrue(header.contains("Text(category.title)"))
        XCTAssertTrue(header.contains("FeatureLightfieldArtwork("))
        XCTAssertTrue(header.contains(".frame(width: 48, height: 48)"))
        XCTAssertFalse(header.contains("AppSymbolIcon("))
        XCTAssertFalse(header.contains("category.subtitle"))
        // D154 batch 3I: the top tabs show each page's picture (was
        // `private var settingsSidebar:` in SettingsView.swift, at 20 × 20).
        let sidebar = try r2SourceDeclaration("struct SettingsTabBar", in: lightfield)
        XCTAssertTrue(sidebar.contains("FeatureLightfieldArtwork("))
        XCTAssertTrue(sidebar.contains(".frame(width: 28, height: 28)"))
        XCTAssertFalse(settings.contains("Image(systemName: \"gearshape.fill\")"))
        XCTAssertNil(settings.range(of: #"\bLabel\s*(?:\(|\{)"#, options: .regularExpression))
        XCTAssertFalse(sidebar.contains("Image(systemName:"))
        XCTAssertFalse(header.contains("Image(systemName:"))
        XCTAssertTrue(lightfield.contains("Image(systemName: \"checkmark\")"))
        XCTAssertFalse(settings.contains("permissionTutorialSection"))
        XCTAssertFalse(settings.contains("SettingsTutorialStep"))
        for copy in ["设置教程", "Setup Guide", "推荐设置顺序", "Recommended Setup Order",
                     "授权复用建议", "Access Reuse Guidance", "窗口关闭说明", "Window Closing",
                     "调整语言、外观、菜单栏小窗与启动行为。",
                     "Adjust language, appearance, the menu-bar panel, and launch behavior."] {
            XCTAssertFalse(settings.contains(copy), copy)
        }
        XCTAssertTrue(settings.contains(".accessibilityHint(method.detail)"))
        XCTAssertFalse(settings.contains("Text(method.detail)"))
        XCTAssertTrue(settings.contains("runtimeInfo.authorizationStabilityStatus"))
        XCTAssertTrue(settings.contains("runtimeInfo.diagnosticsMarkdown"))
    }

    func testPermissionsKeepRequirementsPathsActionsAndSafetyWithoutArtwork() throws {
        // D154 batch 3J: the guide's pages each show one main picture, which
        // D64 keeps; the decorations below stay out of it.
        let onboarding = try source("Views/FirstLaunchOnboardingView.swift")
        let settings = try source("Views/SettingsView.swift")
        for decoration in ["Image(systemName:", "AppSymbolIcon(", "artworkIsActive", "repeatForever", "Label(L10n.text", "circle.fill"] {
            XCTAssertFalse(onboarding.contains(decoration), decoration)
        }
        for copy in ["只申请功能真正需要的权限", "Only permissions needed by real features are requested"] {
            XCTAssertFalse(onboarding.contains(copy), copy)
        }
        for value in ["Text(title)", "Text(requirement)", "Text(status)", "Text(detail)", "Text(guide)",
                      ".foregroundStyle(statusTint)", ".keyboardShortcut(.defaultAction)", "finish()",
                      "store.requestRequiredFolderAccess()", "store.refreshScanReadiness(showCompletionMessage: true)"] {
            XCTAssertTrue(onboarding.contains(value), value)
        }
        for path in ["System Settings → Privacy & Security → Full Disk Access", "System Settings → General → Login Items & Extensions",
                     "System Settings → Notifications → Storage Cleaner"] {
            XCTAssertTrue(onboarding.contains(path), path)
        }
        for copy in ["不保存管理员密码", "administrator passwords are never stored", "不上传扫描结果", "scan results are not uploaded"] {
            XCTAssertTrue(onboarding.contains(copy), copy)
        }
        for copy in ["未授权仍可扫描手动选择的文件夹", "Without access, you can still scan folders you choose manually",
                     "不上传扫描内容", "scan content is not uploaded",
                     "api.ipify.org / api6.ipify.org", "api.country.is", "公网 IP 可关闭，地区查询须另行同意",
                     "public-IP lookup can be turned off, and region lookup requires separate consent", "失联或过热时恢复 macOS 控制"] {
            XCTAssertTrue(settings.contains(copy), copy)
        }
        XCTAssertTrue(settings.contains("Text(PermissionSafetyDisclosure.settingsHelper.text)"))
        XCTAssertTrue(onboarding.contains("detail: PermissionSafetyDisclosure.onboardingHelper.text"))
    }

    @MainActor
    func testSettingsFeedbackOnlyDecoratesWarningsAndExclusionRemovalStaysAccessible() throws {
        let settings = try source("Views/SettingsView.swift")
        let expected: [(SettingsNoticeSeverity, Bool)] = [(.information, false), (.success, false), (.warning, true), (.failure, true), (.locked, true)]
        XCTAssertEqual(SettingsNoticeSeverity.allCases, expected.map { $0.0 })
        for (severity, showsSymbol) in expected {
            for symbol in ["exclamationmark.triangle.fill", "xmark.octagon.fill", "lock.shield.fill", "checkmark.circle.fill", "gearshape"] {
                for tint in [AppDesignTokens.Palette.warning, AppDesignTokens.Palette.success, AppDesignTokens.Palette.destructive] {
                    let notice = SettingsNotice(text: "Feedback", systemImage: symbol, tint: tint, severity: severity)
                    XCTAssertEqual(notice.showsWarningSymbol, showsSymbol, "\(severity) / \(symbol)")
                }
            }
        }
        let view = try segment(settings, from: "struct SettingsNoticeView:", to: "struct ExclusionPathRow:")
        XCTAssertTrue(view.contains("if notice.showsWarningSymbol {\n                AppSymbolIcon("))
        XCTAssertTrue(view.contains("Text(notice.text)"))
        XCTAssertTrue(view.contains(".accessibilityElement(children: .combine)"))
        let row = try segment(settings, from: "struct ExclusionPathRow:", to: "struct SettingsWindowConfigurator:")
        XCTAssertFalse(row.contains("AppSymbolIcon("))
        XCTAssertTrue(row.contains("LightfieldPathText(path: path)"))
        XCTAssertTrue(row.contains("Button(L10n.text(\"移除\", \"Remove\"), action: remove)"))
        XCTAssertTrue(row.contains(".buttonStyle(FeatureLightfieldRowButtonStyle())"))
        XCTAssertTrue(row.contains("action: remove"))
    }

    func testUpdateSourceNoticeKeepsRemotePermissionAndSelfUpdateBoundaries() throws {
        let settings = try source("Views/SettingsView.swift")
        let updates = try r2SourceDeclaration("var updateSourceSection:", in: settings)
        let boundary = try segment(updates, from: "\n            Text(L10n.text(\n", to: "\n            SettingsNoticeView(")
        XCTAssertTrue(boundary.contains("关闭来源仅停止该来源的远程检查，不改变权限，也不影响存储清理助手自身的 Sparkle 更新。"))
        XCTAssertTrue(boundary.contains("Disabling a source only stops its remote checks; permissions and Storage Cleaner's own Sparkle updates are unchanged."))
        XCTAssertTrue(boundary.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(updates.contains(".lineLimit(1)"))
        XCTAssertTrue(updates.contains("value: \"\\(updateSourceConfiguration.enabledCount)/\\(AppUpdateMethod.allCases.count)\""))
        XCTAssertTrue(updates.contains("get: { updateSourceConfiguration.includes(method) }"))
        XCTAssertTrue(updates.contains("set: { setUpdateSource(method, isEnabled: $0) }"))
        XCTAssertTrue(updates.contains("resetUpdateSources()"))
        for copy in ["App Store、官网与需授权的项目始终要求确认", "签名变化会阻止自动安装",
                     "authorization flows always require confirmation", "signing changes block automatic installation"] {
            XCTAssertTrue(updates.contains(copy), copy)
        }
        let setSource = try SettingsSourceContract.declarations([
            "func setUpdateSource(", "func resetUpdateSources()",
        ], in: settings)
        XCTAssertTrue(setSource.contains("AppUpdateSourcePreferences.setConfiguration(updateSourceConfiguration)"))
        XCTAssertTrue(setSource.contains("AppUpdateSourcePreferences.reset()"))
        XCTAssertFalse(setSource.contains("requestAuthorization"))
        XCTAssertFalse(setSource.contains("permissionNotice"))
    }

    func testLaunchAtLoginKeepsApprovalAndSessionRestoreBehaviorWithoutGuidance() throws {
        let settings = try source("Views/SettingsView.swift")
        let launch = try SettingsSourceContract.declarations([
            "var launchBehaviorSection:", "var launchAtLoginBinding:", "var launchAtLoginStatusTitle:",
            "func refreshLaunchAtLoginStatus()", "func setLaunchAtLogin(",
        ], in: settings)
        for value in ["isOn: launchAtLoginBinding", "SMAppService.openSystemSettingsLoginItems()",
                      "try service.register()", "try service.unregister()", "launchAtLoginStatus = service.status",
                      "case (false, .enabled), (false, .requiresApproval):",
                      "launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval",
                      ".disabled(isChangingLaunchAtLogin || launchAtLoginStatus == nil)",
                      "SettingsNotice.launchAtLoginResult(", "requiresApproval: launchAtLoginStatus == .requiresApproval",
                      "SettingsNotice.launchAtLoginFailure(error.localizedDescription)"] {
            XCTAssertTrue(launch.contains(value), value)
        }
        XCTAssertFalse(launch.contains("应用不会加入 macOS 的登录会话恢复列表"))
        XCTAssertFalse(launch.contains("The app opts out of macOS login-session restoration"))
        let app = try source("App/StorageCleanerMacApp.swift")
        let didLaunch = try segment(app, from: "func applicationDidFinishLaunching(", to: "#if DEBUG || STORAGE_CLEANER_BETA")
        XCTAssertTrue(didLaunch.contains("NSApp.disableRelaunchOnLogin()"))
    }

    func testAccessRepairKeepsOnlyTitlesAndTheMediaPrivacyBoundary() throws {
        let repair = try source("Services/AccessRepairGuideService.swift")
        for title in ["打开权限设置", "Open Access Settings", "允许关键位置", "Allow Key Locations", "重新扫描验证", "Rescan To Verify"] {
            XCTAssertTrue(repair.contains(title), title)
        }
        XCTAssertEqual(repair.components(separatedBy: "detail: \"\"").count - 1, 2)
        XCTAssertTrue(repair.contains("媒体资料库默认不读取。"))
        XCTAssertTrue(repair.contains("Media libraries are not read by default."))
        for copy in ["优先打开", "Start with Files & Folders", "评分和排行才会更新", "so the score and rankings update"] {
            XCTAssertFalse(repair.contains(copy), copy)
        }
        XCTAssertTrue(repair.contains("currentReadiness?.level == .needsPermission"))
    }

    func testOperationAndSupportNoticesKeepSafetyAndActualRecordScope() throws {
        let operations = try source("Views/ReversibleOperationsView.swift")
        for copy in ["清空废纸篓后才释放空间", "恢复前核验身份，同名冲突不覆盖",
                     "Space is released after emptying Trash", "never overwrites name conflicts"] {
            XCTAssertTrue(operations.contains(copy), copy)
        }
        XCTAssertTrue(operations.contains("systemImage: \"exclamationmark.triangle\""))
        XCTAssertTrue(operations.contains("恢复已核实的文件"))
        let support = try source("Views/RedactedSupportExportView.swift")
        XCTAssertTrue(support.contains("仅保存到本地，不上传；不含身份、路径、IP、密钥、进程清单与文件内容。"))
        XCTAssertTrue(support.contains("Saved locally, never uploaded; excludes identity, paths, IPs, secrets, process lists and file contents."))
        XCTAssertFalse(support.contains("先检查内容，再保存到本地。不会上传。"))
        XCTAssertFalse(support.contains("Review the contents before saving locally. Nothing is uploaded."))
        XCTAssertTrue(support.contains("已加载操作记录（最多 100 条）"))
        XCTAssertTrue(support.contains("Loaded Operations (up to 100)"))
        XCTAssertTrue(support.contains("String(snapshot.loadedOperationCount)"))
        XCTAssertTrue(support.contains(".fileExporter("))
    }

    func testMiniConfigurationRetainsInteractiveHandlesAndPreviewProvenance() throws {
        let mini = try source("Views/MiniWindowConfigurationSettingsView.swift")
        XCTAssertTrue(mini.contains("Image(systemName: \"line.3.horizontal\")"))
        XCTAssertTrue(mini.contains(".draggable(DashboardModuleDrag("))
        XCTAssertTrue(mini.contains("FeatureLightfieldCheck(selected: item.isVisible"))
        XCTAssertTrue(mini.contains("draft.value.setModule(item.module, isVisible: !item.isVisible)"))
        XCTAssertTrue(mini.contains(".accessibilityValue(item.isVisible ?"))
        XCTAssertTrue(mini.contains(".accessibilityLabel(L10n.text(\"上移\", \"Move up\")"))
        XCTAssertTrue(mini.contains(".accessibilityLabel(L10n.text(\"下移\", \"Move down\")"))
        XCTAssertTrue(mini.contains("SettingsMiniWindowPreview(configuration: draft.value"))
        let preview = try source("Views/Settings/SettingsMiniWindowPreview.swift")
        XCTAssertTrue(preview.contains("模拟小窗预览 · 非实时数据"))
        XCTAssertTrue(preview.contains("Simulated panel preview · Not live data"))
        XCTAssertTrue(mini.contains("try owner.applyLive(draft.value)"))
    }

    func testUnusedSmartCareHeroIsRemovedWithoutRemovingTheGaugeOrPageHeader() throws {
        let components = try source("Views/SmartCareComponents.swift")
        XCTAssertFalse(components.contains("struct SmartCareHeroVisual:"))
        XCTAssertFalse(components.contains("enum SmartCareHeroMode:"))
        XCTAssertTrue(components.contains("struct SmartCareGauge:"))
        XCTAssertTrue(components.contains("struct AppPageHeader<Actions:"))
    }

    @MainActor
    func testMetadataPillStatusMakesRestrictionsDistinctWithoutInferringLegacyNames() {
        let expected: [(MetadataPillStatus, String?)] = [
            (.none, nil), (.locked, "lock.fill"), (.warning, "exclamationmark.triangle.fill"),
            (.failure, "xmark.octagon.fill"), (.readOnly, "lock"), (.systemSettingsOnly, "gearshape"),
        ]
        XCTAssertEqual(MetadataPillStatus.allCases, expected.map { $0.0 })
        for (status, symbol) in expected {
            for legacy in ["number", "lock.fill", "xmark.octagon.fill", "gearshape"] {
                let pill = MetadataPill(text: "Running", systemImage: legacy, tint: AppDesignTokens.Palette.warning, status: status)
                XCTAssertEqual(pill.renderedSystemImage, symbol, "\(status) / \(legacy)")
                XCTAssertEqual(pill.status.accessibilityDescription.isEmpty, status == .none)
            }
        }
        XCTAssertEqual(Set(expected.compactMap { $0.1 }).count, 5, "The five restrictions/results must be visually distinguishable")
    }

    func testPermissionDisclosuresKeepPasswordAndControlScopeInBothLanguages() throws {
        XCTAssertEqual(PermissionSafetyDisclosure.allCases, [.settingsHelper, .onboardingHelper, .unneededAccess])
        for disclosure in [PermissionSafetyDisclosure.settingsHelper, .onboardingHelper] {
            for word in ["风扇", "电源模式", "系统级启动项", "白名单", "不保存管理员密码"] {
                XCTAssertTrue(disclosure.chinese.contains(word), "\(disclosure) / \(word)")
            }
            for word in ["fans", "power modes", "system startup items", "allow-listed", "administrator passwords are never stored"] {
                XCTAssertTrue(disclosure.english.contains(word), "\(disclosure) / \(word)")
            }
        }
        XCTAssertTrue(PermissionSafetyDisclosure.onboardingHelper.chinese.contains("管理员授权一次"))
        XCTAssertTrue(PermissionSafetyDisclosure.onboardingHelper.english.contains("one administrator approval"))
        let settings = try source("Views/SettingsView.swift")
        let permissions = try segment(settings, from: "var permissionSetupSection:", to: "var helperAccessActions:")
        XCTAssertTrue(permissions.contains("Text(PermissionSafetyDisclosure.settingsHelper.text)"))
        let onboarding = try source("Views/FirstLaunchOnboardingView.swift")
        let helper = try segment(onboarding, from: "private var helperCard:", to: "private var notificationCard:")
        XCTAssertTrue(helper.contains("detail: PermissionSafetyDisclosure.onboardingHelper.text"))
    }

    func testNetworkPrivacyRetainsUnneededAccessBoundary() throws {
        let disclosure = PermissionSafetyDisclosure.unneededAccess
        for word in ["无需", "辅助功能", "屏幕录制", "相机", "麦克风", "定位", "自动化"] {
            XCTAssertTrue(disclosure.chinese.contains(word), word)
        }
        for word in ["No Accessibility", "Screen Recording", "Camera", "Microphone", "Location", "Automation", "permissions are required"] {
            XCTAssertTrue(disclosure.english.contains(word), word)
        }
        let settings = try source("Views/SettingsView.swift")
        let network = try r2SourceDeclaration("var networkPrivacySection:", in: settings)
        XCTAssertTrue(network.contains("Text(PermissionSafetyDisclosure.unneededAccess.text)"))
        XCTAssertTrue(network.contains(".fixedSize(horizontal: false, vertical: true)"))
        XCTAssertFalse(network.contains(".lineLimit(1)"))
        XCTAssertTrue(network.contains("api.country.is"))
        XCTAssertTrue(network.contains("public-IP lookup can be turned off, and region lookup requires separate consent"))
    }

    @MainActor
    func testLoginFailureUsesExplicitSeverityAndDefaultSymbol() throws {
        let failure = SettingsNotice.launchAtLoginFailure("D64-error-token")
        XCTAssertEqual(failure.severity, .failure)
        XCTAssertTrue(failure.showsWarningSymbol)
        XCTAssertEqual(failure.systemImage, "exclamationmark.triangle.fill", "Preserve the approved default login-failure symbol")
        XCTAssertTrue(failure.text.contains("D64-error-token"))
        for shouldLaunch in [false, true] {
            let approval = SettingsNotice.launchAtLoginResult(requiresApproval: true, shouldLaunch: shouldLaunch)
            XCTAssertEqual(approval.severity, .warning)
            XCTAssertTrue(approval.showsWarningSymbol)
            let completed = SettingsNotice.launchAtLoginResult(requiresApproval: false, shouldLaunch: shouldLaunch)
            XCTAssertEqual(completed.severity, .success)
            XCTAssertFalse(completed.showsWarningSymbol)
            XCTAssertFalse(completed.text.isEmpty)
        }
        let settings = try source("Views/SettingsView.swift")
        let mutation = try r2SourceDeclaration("func setLaunchAtLogin(", in: settings)
        XCTAssertTrue(mutation.contains("SettingsNotice.launchAtLoginFailure(error.localizedDescription)"))
        XCTAssertTrue(mutation.contains("SettingsNotice.launchAtLoginResult("))
    }

    @MainActor
    func testSettingsOpenFeedbackModelsAndFailureBranchesKeepSeverity() throws {
        for symbol in ["bell.fill", "externaldrive.fill", "folder.fill", "shippingbox.fill"] {
            for didOpen in [false, true] {
                let notice = SettingsNotice.openSettingsResult(didOpen: didOpen, openedText: "opened", failureText: "failed", openedSymbol: symbol)
                XCTAssertEqual(notice.severity, didOpen ? .information : .failure)
                XCTAssertEqual(notice.showsWarningSymbol, !didOpen)
                XCTAssertEqual(notice.text, didOpen ? "opened" : "failed")
                XCTAssertEqual(notice.systemImage, didOpen ? symbol : "exclamationmark.triangle.fill")
            }
        }
        let settings = try source("Views/SettingsView.swift")
        for start in [
            "func openNotificationSettings()",
            "func openFullDiskAccessSettings()",
            "func openFilesAndFoldersSettings()",
            "func openAppManagementSettings()",
        ] {
            let branch = try r2SourceDeclaration(start, in: settings)
            XCTAssertTrue(branch.contains("SettingsNotice.openSettingsResult("), start)
            XCTAssertTrue(branch.contains("didOpen: didOpen"), start)
            XCTAssertTrue(branch.contains("failureText: L10n.text("), start)
        }
    }

    @MainActor
    func testSettingsColumnsAlignHeaderWithLightfieldContent() throws {
        for category in SettingsCategory.allCases {
            let geometry = SettingsLightfieldGeometry(size: CGSize(width: 970, height: 732), category: category)
            XCTAssertEqual(geometry.title.minX, geometry.content.minX, "\(category)")
            XCTAssertEqual(geometry.title.width, geometry.content.width, "\(category)")
            XCTAssertGreaterThan(geometry.content.minY, geometry.title.maxY)
            XCTAssertEqual(geometry.content.minX, category == .general || category == .miniWindow ? 52 : 96)
        }
        let settings = try source("Views/SettingsView.swift")
        let pane = try r2SourceDeclaration("private func settingsPane(", in: settings)
        // D154 batch 3I: the window draws the backdrop behind the tabs and the
        // pane (was `SettingsLightfieldPane(category: category)`).
        XCTAssertTrue(pane.contains("SettingsLightfieldPane(category: category, drawsBackdrop: false)"))
        XCTAssertTrue(pane.contains("settingsForm(for: category)"))
        let lightfield = try source("Views/Settings/SettingsLightfield.swift")
        let shell = try r2SourceDeclaration("struct SettingsLightfieldPane", in: lightfield)
        XCTAssertTrue(shell.contains("SettingsLightfieldGeometry(size: viewport.size, category: category)"))
        XCTAssertTrue(shell.contains(".offset(x: geometry.title.minX, y: geometry.title.minY)"))
        XCTAssertTrue(shell.contains(".offset(x: geometry.content.minX, y: geometry.content.minY)"))
        XCTAssertFalse(shell.contains(".frame(maxWidth: AppDesignTokens.Layout.settingsPageMaxWidth"))
    }

    func testUnusedCanvasThemeDetailIsRemovedWithoutChangingThemeSelection() throws {
        let tokens = try source("Support/AppDesignTokens.swift")
        let canvas = try segment(tokens, from: "enum AppCanvasTheme:", to: "private final class AppCanvasThemeCache:")
        XCTAssertFalse(canvas.contains("var detail:"))
        for copy in ["夜间使用纯黑底色", "Night uses a pure black canvas", "夜间使用深靛蓝底色", "Night uses a deep indigo canvas"] {
            XCTAssertFalse(tokens.contains(copy), copy)
        }
        XCTAssertEqual(AppCanvasTheme.allCases, [.pureBlack, .deepSpace])
        XCTAssertEqual(AppCanvasTheme.defaultTheme, .deepSpace)
        XCTAssertEqual(AppCanvasTheme.resolve(rawValue: "pureBlack"), .pureBlack)
        XCTAssertEqual(AppCanvasTheme.resolve(rawValue: "unknown"), .deepSpace)
        XCTAssertEqual(AppCanvasTheme.resolve(rawValue: nil), .deepSpace)
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try r2ProductionSource(at: root.appendingPathComponent("Sources/StorageCleanerMac/" + relative))
    }

    private func segment(_ source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start))
        let tail = source[startRange.upperBound...]
        let endRange = try XCTUnwrap(tail.range(of: end))
        return String(tail[..<endRange.lowerBound])
    }
}
