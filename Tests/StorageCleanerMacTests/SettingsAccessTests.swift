import AppKit
import XCTest
@testable import StorageCleanerMac

@MainActor
final class SettingsAccessTests: XCTestCase {
    func testEveryPermissionDestinationUsesItsOwnSystemSettingsURL() throws {
        let expected: [(CleanupService.SystemSettingsDestination, String)] = [
            (.fullDiskAccess, "Privacy_AllFiles"), (.filesAndFolders, "Privacy_FilesAndFolders"),
            (.appManagement, "Privacy_AppBundles"), (.loginItems, "com.apple.LoginItems-Settings.extension")]
        for (destination, pane) in expected {
            let urls = CleanupService.systemSettingsURLs(for: destination)
            XCTAssertFalse(urls.isEmpty)
            XCTAssertEqual(urls.first?.scheme, "x-apple.systempreferences")
            XCTAssertTrue(urls.first?.absoluteString.contains(pane) == true, pane)
        }
        let source = try read("Sources/StorageCleanerMac/Views/Settings/SettingsAccess.swift")
        let section = try r2SourceDeclaration("var permissionSetupSection:", in: source)
        for call in ["open: openFullDiskAccessSettings", "open: openFilesAndFoldersSettings", "open: openAppManagementSettings", "open: openNotificationSettings"] {
            XCTAssertTrue(section.contains(call), call)
        }
        XCTAssertTrue(source.contains("x-apple.systempreferences:com.apple.Notifications-Settings.extension"))
        XCTAssertTrue(source.contains("fanControl.openApprovalSettings()"))
        XCTAssertFalse(source.contains("AXIsProcessTrusted"))
        XCTAssertFalse(source.contains("SecItemCopyMatching"))
    }

    func testReturningToVisiblePermissionsRefreshesButDoesNotRequestAccess() throws {
        XCTAssertTrue(SettingsActivationRefresh.shouldRefresh(isVisible: true, category: .accessAndSetup))
        XCTAssertFalse(SettingsActivationRefresh.shouldRefresh(isVisible: false, category: .accessAndSetup))
        for category in [SettingsCategory.about, .scanAndSafety, .miniWindow, .updates] {
            XCTAssertFalse(SettingsActivationRefresh.shouldRefresh(isVisible: true, category: category))
        }
        let observer = try read("Sources/StorageCleanerMac/Views/Settings/SettingsActivationRefresh.swift")
        XCTAssertTrue(observer.contains("NSApplication.didBecomeActiveNotification"))
        XCTAssertTrue(observer.contains("guard Self.shouldRefresh(isVisible: isVisible, category: category)"))
        XCTAssertTrue(observer.contains("refresh()"))
        let access = try read("Sources/StorageCleanerMac/Views/Settings/SettingsAccess.swift")
        let refresh = try r2SourceDeclaration("func refreshAccessStatus()", in: access)
        for token in ["ScanReadinessService.fullDiskAccessState()", "ApplicationUpdateNotificationService.isAuthorized()", "await fanControl.refreshConnection()"] {
            XCTAssertTrue(refresh.contains(token), token)
        }
        XCTAssertFalse(refresh.contains("requestAuthorization"))
        XCTAssertFalse(refresh.contains("registerHelper()"))
        XCTAssertFalse(refresh.contains("SecItem"))
        let root = try read("Sources/StorageCleanerMac/Views/SettingsView.swift")
        XCTAssertTrue(root.contains("SettingsActivationRefresh(isVisible: isSettingsVisible, category: selectedCategory)"))
        XCTAssertTrue(root.contains("refresh(category: selectedCategory)"))
    }

    func testPermissionStateKeepsUnknownAndOnDemandSeparateFromGranted() throws {
        let source = try read("Sources/StorageCleanerMac/Views/Settings/SettingsAccess.swift")
        let status = try r2SourceDeclaration("var fullDiskAccessStatus:", in: source)
        for value in ["case .verified:", "case .notVerified:", "case .unknown:", "未验证", "无法判断"] { XCTAssertTrue(status.contains(value), value) }
        XCTAssertTrue(source.contains("由 macOS 按位置管理"))
        XCTAssertTrue(source.contains("由 macOS 按需确认"))
        XCTAssertTrue(source.contains("待授权"))
        XCTAssertTrue(source.contains("fanControl.hasTrustedHelper && fanControl.helperState == .enabled"))
        XCTAssertTrue(source.contains("已安装 · 尚未连接"))
    }

    func testActivationDuringAnInFlightReadQueuesOneFreshReadInsteadOfLosingIt() throws {
        var gate = SettingsAccessRefreshGate()
        XCTAssertFalse(gate.isChecking)
        XCTAssertFalse(gate.finish())
        XCTAssertTrue(gate.request())
        XCTAssertTrue(gate.isChecking)
        for _ in 0..<10 { XCTAssertFalse(gate.request(), "Concurrent activation must not start overlapping reads") }
        XCTAssertTrue(gate.finish(), "An activation during the old read must cause a fresh follow-up")
        XCTAssertTrue(gate.isChecking)
        XCTAssertFalse(gate.finish(), "Ten activations coalesce to one follow-up")
        XCTAssertFalse(gate.isChecking)
        XCTAssertTrue(gate.request(), "A later return starts a new read")
        XCTAssertFalse(gate.finish())
        let access = try read("Sources/StorageCleanerMac/Views/Settings/SettingsAccess.swift")
        let refresh = try r2SourceDeclaration("func refreshAccessStatus()", in: access)
        XCTAssertTrue(refresh.contains("guard accessRefreshGate.request() else { return }"))
        XCTAssertTrue(refresh.contains("} while accessRefreshGate.finish()"))
        XCTAssertFalse(refresh.contains("requestAuthorization"))
    }

#if DEBUG
    func testExplicitPermissionScreenshotStatesAreInertAndDebugOnly() throws {
        XCTAssertNil(SettingsAccessDemo.resolve(arguments: []))
        XCTAssertNil(SettingsAccessDemo.resolve(arguments: ["--debug-settings-access=invalid"]))
        for profile in SettingsAccessDemo.allCases {
            XCTAssertEqual(SettingsAccessDemo.resolve(arguments: ["--debug-settings-access=" + profile.rawValue]), profile)
        }
        XCTAssertEqual(SettingsAccessDemo.pending.diskState, .notVerified)
        XCTAssertEqual(SettingsAccessDemo.unknown.diskState, .unknown)
        XCTAssertTrue(SettingsAccessDemo.granted.notificationsAuthorized)
        XCTAssertFalse(SettingsAccessDemo.pending.notificationsAuthorized)
        let fixture = try read("Sources/StorageCleanerMac/Debug/SettingsAccessDemo.swift")
        XCTAssertTrue(fixture.hasPrefix("#if DEBUG"))
        XCTAssertTrue(fixture.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("#endif"))
        for token in ["NSWorkspace", "SecItem", "registerHelper", "requestAuthorization", "selectMode"] {
            XCTAssertFalse(fixture.contains(token), token)
        }
        let access = try read("Sources/StorageCleanerMac/Views/Settings/SettingsAccess.swift")
        let refresh = try r2SourceDeclaration("func refreshAccessStatus()", in: access)
        let demoEnd = try XCTUnwrap(refresh.range(of: "#endif"))
        XCTAssertTrue(refresh[..<demoEnd.lowerBound].contains("return"))
        XCTAssertFalse(refresh[..<demoEnd.lowerBound].contains("fanControl.refreshStatus()"))
        let request = try r2SourceDeclaration("func requestNotificationAccess()", in: access)
        XCTAssertTrue(request.contains("guard SettingsAccessDemo.current == nil else { return }"))
        XCTAssertTrue(access.contains("inert screenshot action"))
    }
#endif

    private func read(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
