import XCTest
@testable import StorageCleanerMac

final class L10nTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)
        super.tearDown()
    }

    func testChineseLanguageModeUsesChineseText() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)

        XCTAssertEqual(L10n.text("中文", "English"), "中文")
        XCTAssertEqual(L10n.items(3), "3 项")
    }

    func testEnglishLanguageModeUsesEnglishText() {
        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)

        XCTAssertEqual(L10n.text("中文", "English"), "English")
        XCTAssertEqual(L10n.items(1), "1 item")
        XCTAssertEqual(L10n.items(3), "3 items")
    }

    func testSystemLanguageModeFollowsPreferredLanguages() {
        XCTAssertTrue(L10n.usesChinese(for: .system, preferredLanguages: ["zh-Hans-AU", "en-AU"]))
        XCTAssertFalse(L10n.usesChinese(for: .system, preferredLanguages: ["en-AU", "zh-Hans"]))
    }

    func testAppKitLanguageOverrideFollowsExplicitAppLanguage() {
        XCTAssertEqual(L10n.appKitAppleLanguages(for: .zhHans), ["zh-Hans"])
        XCTAssertEqual(L10n.appKitAppleLanguages(for: .english), ["en"])
        XCTAssertNil(L10n.appKitAppleLanguages(for: .system))
    }

    func testAppearanceTitlesFollowLanguageMode() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(AppAppearance.dark.title, "深色")

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(AppAppearance.dark.title, "Dark")
    }

    func testBulkTrashMessageKeepsTrashAndFreeSpaceBoundaryClear() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        let chinese = L10n.bulkTrashMessage(count: 2, bytes: "100 MB")
        XCTAssertTrue(chinese.contains("移到废纸篓"))
        XCTAssertTrue(chinese.contains("清空废纸篓后才会真正释放空间"))
        XCTAssertFalse(chinese.contains("预计释放"))

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        let english = L10n.bulkTrashMessage(count: 2, bytes: "100 MB")
        XCTAssertTrue(english.contains("Move 2 items marked safe to clean to Trash"))
        XCTAssertTrue(english.contains("Free space changes after Trash is emptied"))
        XCTAssertFalse(english.contains("Estimated space"))
    }

    func testMainMenuTitleLocalizationFollowsAppLanguage() {
        XCTAssertEqual(MainMenuLocalizer.localizedTitle("File", usesChinese: true), "文件")
        XCTAssertEqual(MainMenuLocalizer.localizedTitle("Edit", usesChinese: true), "编辑")
        XCTAssertEqual(MainMenuLocalizer.localizedTitle("Window", usesChinese: true), "窗口")
        XCTAssertEqual(MainMenuLocalizer.localizedTitle("About Storage Cleaner", usesChinese: true), "关于存储清理助手")

        XCTAssertEqual(MainMenuLocalizer.localizedTitle("文件", usesChinese: false), "File")
        XCTAssertEqual(MainMenuLocalizer.localizedTitle("编辑", usesChinese: false), "Edit")
        XCTAssertEqual(MainMenuLocalizer.localizedTitle("关于存储清理助手", usesChinese: false), "About Storage Cleaner")
    }

    func testReviewFilterTerminologyFollowsLanguageMode() {
        let chineseTitles = [
            "智能扫描", "系统健康", "性能测试", "安全清理", "浏览器隐私", "开发工具与产物", "大型文件", "文件搬家", "重复文件", "系统工具",
            "登录项与后台任务", "内存管理", "能耗", "卸载", "应用更新"
        ]
        let englishTitles = [
            "Smart Scan", "System Health", "Performance Test", "Safe Cleanup", "Browser Privacy", "Dev Tools & Artifacts", "Large Files", "File Migration", "Duplicates", "System Tools",
            "Login Items & Background Tasks", "Memory Management", "Energy", "Uninstall", "App Updates"
        ]

        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(ReviewFilter.allCases.map(\.title), chineseTitles)
        XCTAssertEqual(ReviewFilter.green.sidebarTitle, "安全清理")
        XCTAssertEqual(ReviewFilter.privacy.sidebarTitle, "浏览器隐私")
        XCTAssertEqual(ReviewFilter.largeFiles.sidebarTitle, "文件分析")
        XCTAssertEqual(ReviewFilter.migration.sidebarTitle, "文件搬家")

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(ReviewFilter.allCases.map(\.title), englishTitles)
        XCTAssertEqual(ReviewFilter.green.sidebarTitle, "Safe Cleanup")
        XCTAssertEqual(ReviewFilter.privacy.sidebarTitle, "Browser Privacy")
        XCTAssertEqual(ReviewFilter.largeFiles.sidebarTitle, "File Analysis")
        XCTAssertEqual(ReviewFilter.migration.sidebarTitle, "File Migration")
    }

    func testMenuBarPanelExposesGeekVocabularyOnly() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(PanelDensity.menuBarChoices.map(\.title), ["极客"])

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(PanelDensity.menuBarChoices.map(\.title), ["Geek"])
    }

    func testComputerHealthDashboardCoreLabelsAreLocalized() {
        UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(HealthDashboardText.dataInsufficient, "数据不足")
        XCTAssertEqual(HealthDashboardText.environmentTitle, "环境状态（不计入总分）")
        XCTAssertEqual(HealthDashboardText.scoreEvidenceTitle, "评分构成与原始证据")
        XCTAssertEqual(BatterySettingsActionLabel.openSettings.localizedTitle, "打开电池设置")
        XCTAssertEqual(BatterySettingsActionLabel.verifySettings.localizedTitle, "验证电池设置")
        XCTAssertEqual(BatterySettingsActionLabel.openingSettings.localizedTitle, "正在打开设置")
        XCTAssertEqual(BatterySettingsActionLabel.verifying.localizedTitle, "正在验证设置")
        XCTAssertEqual(BatterySettingsActionLabel.verifyAgain.localizedTitle, "重新验证设置")
        XCTAssertEqual(BatterySettingsActionLabel.reopenSettings.localizedTitle, "重新打开电池设置")
        XCTAssertEqual(BatterySettingsActionLabel.openManually.localizedTitle, "打开电池设置（手动核对）")
        XCTAssertEqual(BatterySettingsActionLabel.recheckSettings.localizedTitle, "重新检查电池设置")
        XCTAssertEqual(BatteryTimeEstimateKind.untilFull.localizedLabel, "预计充满")
        XCTAssertEqual(BatteryTimeEstimateKind.remaining.localizedLabel, "预计剩余")

        UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(HealthDashboardText.dataInsufficient, "Data Insufficient")
        XCTAssertEqual(HealthDashboardText.environmentTitle, "Environment (Not Scored)")
        XCTAssertEqual(HealthDashboardText.scoreEvidenceTitle, "Score Breakdown & Raw Evidence")
        XCTAssertEqual(BatterySettingsActionLabel.openSettings.localizedTitle, "Open Battery Settings")
        XCTAssertEqual(BatterySettingsActionLabel.verifySettings.localizedTitle, "Verify Battery Settings")
        XCTAssertEqual(BatterySettingsActionLabel.openingSettings.localizedTitle, "Opening Settings")
        XCTAssertEqual(BatterySettingsActionLabel.verifying.localizedTitle, "Verifying Settings")
        XCTAssertEqual(BatterySettingsActionLabel.verifyAgain.localizedTitle, "Verify Settings Again")
        XCTAssertEqual(BatterySettingsActionLabel.reopenSettings.localizedTitle, "Reopen Battery Settings")
        XCTAssertEqual(BatterySettingsActionLabel.openManually.localizedTitle, "Open Battery Settings (Verify Manually)")
        XCTAssertEqual(BatterySettingsActionLabel.recheckSettings.localizedTitle, "Recheck Battery Settings")
        XCTAssertEqual(BatteryTimeEstimateKind.untilFull.localizedLabel, "Estimated Until Full")
        XCTAssertEqual(BatteryTimeEstimateKind.remaining.localizedLabel, "Estimated Remaining")
    }
}
