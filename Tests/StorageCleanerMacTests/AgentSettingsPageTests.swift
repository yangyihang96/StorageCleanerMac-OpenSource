import AgentGatewayCore
import AgentShared
import AppKit
import Combine
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D265, D273: what the "AI 助手" page says and does, without a window.
/// `SettingsPagesRenderReviewTests` renders it; `SettingsInventoryTests` holds its
/// controls to the page and to the one set of rows.
@MainActor
final class AgentSettingsPageTests: XCTestCase {
    private let client = AgentClientIdentity(kind: .signed, identifier: "com.fixture.client", team: "TEAM123", cdhash: nil,
                                             executablePath: "/Applications/Fixture.app/Contents/MacOS/Fixture", displayName: "Fixture")

    private func makeInterface(launchBlocked: Bool = false) throws -> (AgentInterface, URL) {
        // `sun_path` holds 103 bytes; `TestFileSystem`'s roots are too long for it.
        let data = FileManager.default.temporaryDirectory.appendingPathComponent("sca-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: data) }
        let interface = AgentInterface(defaults: TestPreferenceDomain.make(for: self), dataDirectory: data,
                                       applicationURL: URL(fileURLWithPath: "/nonexistent/Fixture.app"), launchBlocked: launchBlocked,
                                       announceWaitingClient: { _ in })
        interface.start(source: AgentInterfaceLifecycleTests.EmptySource())
        return (interface, data)
    }

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    // MARK: The tab

    /// `SettingsLightfieldGeometryTests` lays the tabs out in a window, which needs
    /// a test display; this holds the sum without one. The ninth tab at the old
    /// `minWidth: 64` needed 616 pt, and at any one width "Reminders" or
    /// "Assistant" broke inside the word in English.
    func testEveryTabFitsTheSmallestWindow() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            XCTAssertLessThanOrEqual(SettingsTabBar.minimumWidth, 560, "\(language)")
        }
    }

    /// Rendered at 560 pt, "Access & Privacy" read "Access" and "& Priv…" while a
    /// tab only made room for its longest word.
    func testATabFitsItsWholeTitleOnTwoLines() {
        let scope = CalibrationLanguageScope(.english)
        defer { scope.restore() }
        let font = NSFont.systemFont(ofSize: SettingsTabBar.titleSize, weight: .semibold)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        func room(_ category: SettingsCategory) -> CGFloat { category.minimumTabWidth - 2 * SettingsTabBar.tabPadding }
        XCTAssertGreaterThanOrEqual(room(.accessAndSetup), width("Access &"))
        XCTAssertGreaterThanOrEqual(room(.accessAndSetup), width("Privacy"))
        XCTAssertGreaterThanOrEqual(room(.scanAndSafety), width("Reminders"))
        XCTAssertGreaterThanOrEqual(room(.aiAssistant), width("Assistant"))
        XCTAssertLessThan(room(.aiAssistant), width("AI Assistant"), "two lines are allowed, and a narrow window needs them")
        XCTAssertGreaterThanOrEqual(room(.about), width("About"))
    }

    func testTheTabHasItsNameAndAPicture() {
        XCTAssertEqual(SettingsCategory.aiAssistant.rawValue, "aiAssistant")
        XCTAssertEqual(SettingsCategory.aiAssistant.tabArt, .tileAIClutter)
        XCTAssertEqual(SettingsCategory.aiAssistant.minimumContentHeight, 0)
        // What the notification tells the user to look for (`notifyUser`).
        var scope = CalibrationLanguageScope(.zhHans)
        XCTAssertEqual(SettingsCategory.aiAssistant.title, "AI 助手")
        scope.restore()
        scope = CalibrationLanguageScope(.english)
        XCTAssertEqual(SettingsCategory.aiAssistant.title, "AI Assistant")
        scope.restore()
    }

    func testComingBackToTheAppRefreshesThePage() {
        XCTAssertTrue(SettingsActivationRefresh.shouldRefresh(isVisible: true, category: .aiAssistant))
        XCTAssertFalse(SettingsActivationRefresh.shouldRefresh(isVisible: false, category: .aiAssistant))
    }

    // MARK: What the page reads

    func testEnteringThePageShowsTheLastUse() throws {
        let (interface, _) = try makeInterface()
        interface.decide(client, .readOnly)
        XCTAssertNil(interface.clients.first?.lastUsedAt)
        let used = Date(timeIntervalSince1970: 1_790_000_000)
        try XCTUnwrap(interface.registry).markUsed(client, at: used)
        XCTAssertNil(interface.clients.first?.lastUsedAt, "a call publishes nothing by itself")
        interface.refreshForSettings()
        XCTAssertEqual(interface.clients.first?.lastUsedAt, used)
    }

    func testTheLogIsNewestFirstAndShowsAtMostAHundred() async throws {
        let (interface, data) = try makeInterface()
        _ = try AgentSocketDirectory.prepare(dataDirectory: data)
        let gateway = try XCTUnwrap(interface.gateway)
        let log = await gateway.accessLog
        let start = Date()
        for index in 0..<120 {
            log.append(.init(time: start.addingTimeInterval(TimeInterval(index)), client: "Fixture", clientKey: client.bindingKey,
                             tool: "tool-\(index)", level: .read, outcome: .allowed))
        }
        interface.refreshForSettings()
        await interface.waitForAccessRead()
        XCTAssertEqual(interface.accessEntryCount, 120)
        XCTAssertEqual(interface.recentAccess.count, 100)
        XCTAssertEqual(interface.recentAccess.first?.tool, "tool-119")
        XCTAssertEqual(interface.recentAccess.last?.tool, "tool-20")
    }

    func testReadingThePageWithTheSwitchOffLeavesNothingOnDisk() async throws {
        let (interface, data) = try makeInterface()
        interface.refreshForSettings()
        await interface.waitForAccessRead()
        XCTAssertEqual(interface.recentAccess, [])
        XCTAssertEqual(interface.accessEntryCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.appendingPathComponent("Agent").path))
    }

    func testReadingThePageWithoutAGatewayShowsNothing() async throws {
        let (interface, _) = try makeInterface(launchBlocked: true)
        interface.refreshForSettings()
        await interface.waitForAccessRead()
        XCTAssertEqual(interface.clients, [])
        XCTAssertEqual(interface.recentAccess, [])
    }

    // MARK: The switch

    /// No status change follows when there is no gateway, and the change itself
    /// is applied later: the switch still has to move when it is clicked.
    func testTheSwitchShowsItsChangeAtOnce() throws {
        let (interface, _) = try makeInterface(launchBlocked: true)
        var changes = 0
        let observation = interface.objectWillChange.sink { changes += 1 }
        interface.setEnabled(true)
        observation.cancel()
        XCTAssertEqual(changes, 1)
        XCTAssertTrue(interface.isEnabled)
    }

    func testTheCaptionFollowsTheSwitchWhileItsChangeIsApplied() async throws {
        let (interface, _) = try makeInterface()
        XCTAssertEqual(interface.statusCaption, AgentGatewayStatus.off.settingsText)
        interface.setEnabled(true)
        XCTAssertEqual(interface.statusCaption, L10n.text("正在打开…", "Turning on…"))
        await interface.waitForStatusUpdate()
        XCTAssertEqual(interface.statusCaption, AgentGatewayStatus.failed(.bridgeUnverifiable).settingsText)
        XCTAssertTrue(interface.status.isFailure)
        interface.setEnabled(false)
        XCTAssertEqual(interface.statusCaption, L10n.text("正在关闭…", "Turning off…"))
        await interface.waitForStatusUpdate()
        XCTAssertEqual(interface.statusCaption, AgentGatewayStatus.off.settingsText)
        XCTAssertFalse(interface.status.isFailure)
    }

    /// D106: an acceptance session opens nothing, so it is not "turning on".
    func testWithoutAGatewayTheCaptionIsTheStatus() throws {
        let (interface, _) = try makeInterface(launchBlocked: true)
        interface.setEnabled(true)
        XCTAssertEqual(interface.statusCaption, AgentGatewayStatus.off.settingsText)
    }

    // MARK: What the page says

    /// D263: the name comes from the program's path, so the signature is what
    /// says who this is, and anything without a developer signature stands out.
    func testEverySignatureSaysWhoThisIs() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            XCTAssertTrue(client.settingsSignature.contains("com.fixture.client"))
            XCTAssertTrue(client.settingsSignature.contains("TEAM123"))
            XCTAssertTrue(client.hasDeveloperSignature)
            let adHoc = AgentClientIdentity(kind: .adHoc, identifier: "a.out", team: nil, cdhash: "ab", executablePath: "~/bin/tool", displayName: "tool")
            XCTAssertTrue(adHoc.settingsSignature.contains("~/bin/tool"))
            XCTAssertFalse(adHoc.hasDeveloperSignature)
            let unsigned = AgentClientIdentity(kind: .unsigned, identifier: nil, team: nil, cdhash: nil, executablePath: "~/bin/other", displayName: "other")
            XCTAssertTrue(unsigned.settingsSignature.contains("~/bin/other"))
            XCTAssertFalse(unsigned.hasDeveloperSignature)
            XCTAssertNotEqual(adHoc.settingsSignature.replacingOccurrences(of: "~/bin/tool", with: ""),
                              unsigned.settingsSignature.replacingOccurrences(of: "~/bin/other", with: ""))
        }
    }

    func testEveryPermissionOutcomeAndReasonHasItsOwnWords() {
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            let decisions = [AgentClientDecision.readOnly, .propose, .denied].map(\.settingsTitle)
            XCTAssertEqual(Set(decisions).count, 3)
            XCTAssertFalse(decisions.contains(""))
            // D273: what the page offers (was `[.readOnly, .propose]`, two titles).
            let grants = AgentSettingsPage.grants.map(\.settingsGrantTitle)
            XCTAssertEqual(Set(grants).count, AgentSettingsPage.grants.count)
            XCTAssertFalse(grants.contains(""))
            let levels = [AgentOperationLevel.read, .scan, .propose].map(\.settingsTitle)
            XCTAssertEqual(Set(levels).count, 3)
            XCTAssertFalse(levels.contains(""))
            let reasons = AgentRefusalReason.allCases.map(\.settingsText)
            XCTAssertEqual(Set(reasons).count, AgentRefusalReason.allCases.count)
            XCTAssertFalse(reasons.contains(""))
        }
    }

    func testALogRowSaysHowTheCallEnded() {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        func entry(_ outcome: AgentAccessLogEntry.Outcome, _ reason: AgentRefusalReason? = nil) -> AgentAccessLogEntry {
            .init(time: Date(), client: "Fixture", clientKey: "k", tool: "get_overview", level: .read, outcome: outcome, reason: reason)
        }
        XCTAssertEqual(entry(.allowed).settingsOutcome, "允许")
        XCTAssertEqual(entry(.failed).settingsOutcome, "出错")
        XCTAssertEqual(entry(.refused).settingsOutcome, "拒绝")
        XCTAssertEqual(entry(.refused, .rateLimited).settingsOutcome, "拒绝：" + AgentRefusalReason.rateLimited.settingsText)
        XCTAssertFalse(entry(.allowed).isProblem)
        XCTAssertTrue(entry(.refused).isProblem)
        XCTAssertTrue(entry(.failed).isProblem)
    }

    /// A plain `formatted(date:time:)` follows the process's locale. In a test, in a
    /// render and after switching language without a restart, that left the Chinese
    /// page reading "上次使用 Nov 2, 2026 at 10:23 AM" with the system on en_US.
    func testTimesFollowTheAppLanguage() throws {
        let (interface, _) = try makeInterface()
        interface.decide(client, .readOnly)
        let time = Date(timeIntervalSince1970: 1_790_000_000)
        try XCTUnwrap(interface.registry).markUsed(client, at: time)
        interface.refreshForSettings()
        let record = try XCTUnwrap(interface.clients.first)
        let entry = AgentAccessLogEntry(time: time, client: "Fixture", clientKey: "k", tool: "get_overview", level: .read, outcome: .allowed)
        var scope = CalibrationLanguageScope(.zhHans)
        // D273: the last use is its own line now (was inside `settingsCaption`).
        var lastUse = try XCTUnwrap(record.settingsLastUse)
        XCTAssertTrue(lastUse.hasPrefix("上次使用 2026年"), lastUse)
        XCTAssertTrue(entry.settingsDetail.hasSuffix(" · 读取 · " + entry.time.formatted(Date.FormatStyle(date: .abbreviated, time: .standard).locale(Locale(identifier: "zh_Hans")))), entry.settingsDetail)
        XCTAssertTrue(entry.settingsDetail.contains("2026年"), entry.settingsDetail)
        scope.restore()
        scope = CalibrationLanguageScope(.english)
        lastUse = try XCTUnwrap(record.settingsLastUse)
        XCTAssertTrue(lastUse.hasPrefix("Last used Sep"), lastUse)
        XCTAssertFalse(lastUse.contains("年"), lastUse)
        XCTAssertFalse(entry.settingsDetail.contains("年"), entry.settingsDetail)
        scope.restore()
    }

    /// The first access is the likeliest thing to see here: not "1 entries".
    func testTheLogCountReadsInBothLanguages() {
        var scope = CalibrationLanguageScope(.english)
        XCTAssertEqual(AgentSettingsPage.accessCountText(1), "1 entry")
        XCTAssertEqual(AgentSettingsPage.accessCountText(2), "2 entries")
        scope.restore()
        scope = CalibrationLanguageScope(.zhHans)
        XCTAssertEqual(AgentSettingsPage.accessCountText(1), "1 条")
        XCTAssertEqual(AgentSettingsPage.accessCountText(2), "2 条")
        scope.restore()
    }

    /// D273: one grant and a refusal (was `[.readOnly, .propose]`, D261); none skips
    /// the user's confirmation.
    func testNoGrantSkipsConfirmation() throws {
        XCTAssertEqual(AgentSettingsPage.grants, [.readOnly])
        let page = try source("Sources/StorageCleanerMac/Views/Settings/SettingsAIAssistant.swift")
        for forbidden in ["免确认", "skip confirmation", "without asking"] {
            XCTAssertFalse(page.contains(forbidden), forbidden)
        }
    }

    /// D273: a waiting client is allowed to read or denied, nothing else (was also
    /// "允许提出操作"), and neither that section nor the first-time page brings up
    /// proposals. A client that already holds `.propose` still shows it: see
    /// `testEveryPermissionOutcomeAndReasonHasItsOwnWords`.
    func testAWaitingClientIsOnlyAllowedToReadOrDenied() throws {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        XCTAssertEqual(AgentSettingsPage.grants.map(\.settingsGrantTitle), ["允许只读"])
        let page = try source("Sources/StorageCleanerMac/Views/Settings/SettingsAIAssistant.swift")
        let pending = try r2SourceDeclaration("private var pendingSection: some View", in: page)
        XCTAssertEqual(pending.components(separatedBy: "SettingsLinkButton(").count - 1, 2, "the grants and the refusal")
        XCTAssertTrue(pending.contains("ForEach(Self.grants"))
        XCTAssertTrue(pending.contains("interface.decide(client.identity, .denied)"))
        for marker in ["private var pendingSection: some View", "private var introCanSection: some View",
                       "private var introCannotSection: some View", "private var connectionSection: some View"] {
            let section = try r2SourceDeclaration(marker, in: page).lowercased()
            for word in ["提出", "propos"] { XCTAssertFalse(section.contains(word), "\(marker): \(word)") }
        }
    }

    /// D273: for a client with no developer signature only the signature line is a
    /// warning; when it was last used stays plain (was one caption in one color).
    /// Pure red comes from nothing else in the row, so a red pixel is the warning.
    func testTheWarningColorStaysOnTheSignatureLine() throws {
        let row = SettingsRow(title: "Title", caption: "Warning line", captionColor: Color(red: 1, green: 0, blue: 0), detail: "Plain line") { EmptyView() }
            .frame(width: 320)
            .environment(\.colorScheme, .light)
            .background(Color.white)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        var inkRows: [Int] = [], redRows: [Int] = []
        for y in 0..<bitmap.pixelsHigh {
            var ink = false, red = false
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent < 2.4 { ink = true }
                if color.redComponent > 0.7, color.greenComponent < 0.3, color.blueComponent < 0.3 { red = true }
            }
            if ink { inkRows.append(y) }
            if red { redRows.append(y) }
        }
        let lastRed = try XCTUnwrap(redRows.last, "the caption keeps its color")
        let lastInk = try XCTUnwrap(inkRows.last)
        XCTAssertGreaterThan(lastInk - lastRed, 8, "a line without the warning color follows it")
    }

    /// The page hands the row the signature and the last use apart, and a denied
    /// client has no last use to show.
    func testASignatureAndItsLastUseAreSeparateLines() throws {
        let scope = CalibrationLanguageScope(.zhHans)
        defer { scope.restore() }
        let (interface, _) = try makeInterface()
        let unsigned = AgentClientIdentity(kind: .unsigned, identifier: nil, team: nil, cdhash: nil, executablePath: "~/bin/other", displayName: "other")
        let denied = AgentClientIdentity(kind: .adHoc, identifier: "a.out", team: nil, cdhash: "ab", executablePath: "~/bin/tool", displayName: "tool")
        interface.decide(unsigned, .readOnly)
        interface.decide(denied, .denied)
        func record(_ identity: AgentClientIdentity) throws -> AgentClientRecord {
            try XCTUnwrap(interface.clients.first { $0.identity.bindingKey == identity.bindingKey })
        }
        XCTAssertEqual(try record(unsigned).settingsLastUse, "还没有用过")
        XCTAssertNil(try record(denied).settingsLastUse)
        XCTAssertFalse(unsigned.settingsSignature.contains("还没有用过"))
        let page = try source("Sources/StorageCleanerMac/Views/Settings/SettingsAIAssistant.swift")
        let clients = try r2SourceDeclaration("private var clientsSection: some View", in: page)
        XCTAssertTrue(clients.contains("caption: record.identity.settingsSignature"))
        XCTAssertTrue(clients.contains("detail: record.settingsLastUse"))
    }

    /// D272: plain captions use plain words. The interface's internal names stay
    /// out, except in the rows that give a client its configuration.
    func testPlainTextAvoidsInternalWords() throws {
        let failures: [AgentGatewayFailure] = [.location(.pathTooLong(120)), .location(.missing), .bridgeUnverifiable, .socket(EADDRINUSE), .socket(EIO)]
        let statuses = [AgentGatewayStatus.off, .listening] + failures.map(AgentGatewayStatus.failed)
        for language in [AppLanguage.zhHans, .english] {
            let scope = CalibrationLanguageScope(language)
            defer { scope.restore() }
            for status in statuses {
                for word in ["套接字", "网关", "桥接", "stdio", "MCP", "socket", "gateway", "bridge"] {
                    XCTAssertFalse(status.settingsText.lowercased().contains(word.lowercased()), "\(status): \(word)")
                }
            }
        }
        let page = try source("Sources/StorageCleanerMac/Views/Settings/SettingsAIAssistant.swift")
        for word in ["套接字", "网关", "桥接", "stdio"] {
            XCTAssertFalse(page.contains(word), word)
        }
    }

    /// D272: a render or a test hands the page its interface, and the page reaches
    /// for nothing else: no real gateway, no real preferences.
    func testThePageReadsOnlyTheInterfaceItIsGiven() throws {
        let page = try source("Sources/StorageCleanerMac/Views/Settings/SettingsAIAssistant.swift")
        for forbidden in ["AgentInterface.shared", "UserDefaults.standard", "AgentGateway(", ".registry", "FileManager"] {
            XCTAssertFalse(page.contains(forbidden), forbidden)
        }
        let root = try source("Sources/StorageCleanerMac/Views/SettingsView.swift")
        XCTAssertTrue(root.contains("agentInterface: @autoclosure @escaping @MainActor () -> AgentInterface = AgentInterface.shared"))
    }
}
