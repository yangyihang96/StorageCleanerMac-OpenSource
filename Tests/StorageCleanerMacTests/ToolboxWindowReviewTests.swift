#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D-FP1–D-FP3: the new review panels hold scroll views, fields and menus,
/// which ImageRenderer cannot draw. This display-bound class (in-process,
/// `script/display-bound-tests.txt`) hosts them in a window on the test
/// display: it checks that rows, the footer total and the main button stay
/// inside the window at the supported sizes, and writes PNGs for review only
/// when `STORAGE_CLEANER_TOOLBOX_EVIDENCE` is set. No scanner runs and no
/// file is touched: every store holds fixture data.
@MainActor
final class ToolboxWindowReviewTests: XCTestCase {
    private static let sizes = [CGSize(width: 1_070, height: 735), CGSize(width: 1_024, height: 734),
                                CGSize(width: 780, height: 540)]

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private final class ProbeRecorder {
        var frames: [String: CGRect] = [:]
    }

    static func maintenanceStatuses() -> [SystemMaintenanceTaskID: SystemMaintenanceStatus] {
        var statuses: [SystemMaintenanceTaskID: SystemMaintenanceStatus] = [:]
        for id in SystemMaintenanceTaskID.allCases {
            statuses[id] = SystemMaintenanceStatus(mode: .informational, lines: [id.summary])
        }
        statuses[.speedUpMail] = SystemMaintenanceStatus(mode: .runnable, lines: ["邮件索引现在 1.2 GB。"], isRecommended: true)
        statuses[.rebuildLaunchServices] = SystemMaintenanceStatus(mode: .runnable)
        statuses[.flushDNS] = SystemMaintenanceStatus(mode: .administratorRequired, lines: ["需要管理员权限。"])
        statuses[.freeUpMemory] = SystemMaintenanceStatus(mode: .elsewhere(.freeUpMemoryPage))
        statuses[.maintenanceScripts] = SystemMaintenanceStatus(mode: .notNeeded, lines: ["这版 macOS 已没有周期维护脚本。"])
        return statuses
    }

    static func chatInventory() -> ChatFilesInventory {
        var rows: [ChatFilesRow] = []
        let months = ["2026-10", "2026-08", "2025-12", "2025-06", "2024-11", "2024-03"]
        for app in [ChatApp.wechat, .qq] {
            for kind in ChatMediaKind.allCases {
                for (index, month) in months.enumerated() {
                    rows.append(ChatFilesRow(
                        id: "\(app.rawValue)|acct|\(kind.rawValue)|\(month)", app: app,
                        account: app == .wechat ? "wxid_fixture_account_1234" : "nt_qq_fixture", kind: kind, month: month,
                        folders: [.init(path: "/Users/fixture/\(month)", identity: nil)],
                        bytes: Int64(index + 1) * 180_000_000, fileCount: (index + 1) * 37, newestModification: nil,
                        isOlderThanCutoff: index >= 2, sizeIsLowerBound: false))
                }
            }
        }
        return ChatFilesInventory(rows: rows, appsFound: [.wechat, .qq], scannedAt: Date(), cutoffDays: 90)
    }

    private func pages() -> [(name: String, view: AnyView)] {
        let extensions = ExtensionManagerStore(coordinator: HeavyWorkCoordinator(), openURL: { _ in })
        extensions.installPreview(inventory: ToolboxRenderReviewTests.extensionInventory(),
                                  selection: Set(ToolboxRenderReviewTests.extensionInventory()
                                    .items(of: .quickLookGenerator).map(\.id)))
        let maintenance = SystemMaintenanceStore(coordinator: HeavyWorkCoordinator(), openURL: { _ in }, copyText: { _ in })
        maintenance.installPreview(statuses: Self.maintenanceStatuses(), selection: [.speedUpMail])
        let chat = ChatFilesStore(coordinator: HeavyWorkCoordinator(), loadVolumes: { [] }, openURL: { _ in })
        chat.installPreview(inventory: Self.chatInventory(), selection: ["wechat|acct|files|2024-03"])
        // D154 batch 3Q: each panel in the module the app opens it in
        // (ContentView), so the left columns' objects take its colour (was
        // `.startup` for all three).
        return [
            ("extensions", AnyView(ExtensionManagerPage(store: extensions, module: .applications, onBack: {}))),
            ("maintenance", AnyView(SystemMaintenancePage(store: maintenance, module: .startup, onBack: {}))),
            ("chat-files", AnyView(ChatFilesPage(store: chat, module: .clutter, onBack: {}))),
        ]
    }

    func testToolboxPanelsKeepRowsAndTheMainButtonInsideTheWindow() async throws {
        let library = GeneratedArtLibrary(directory: projectRoot.appendingPathComponent("Resources/Art", isDirectory: true))
        let evidence = ProcessInfo.processInfo.environment["STORAGE_CLEANER_TOOLBOX_EVIDENCE"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
        for (language, light) in [(AppLanguage.zhHans, false), (.zhHans, true), (.english, false)] {
            let scope = MiniWindowLogicLanguageScope(language)
            defer { scope.restore() }
            for (name, page) in pages() {
                for size in Self.sizes {
                    let recorder = ProbeRecorder()
                    let root = page
                        .frame(width: size.width, height: size.height)
                        .environment(\.generatedArtLibrary, library)
                        .environment(\.generatedArtWindowVisible, true)
                        .environment(\.featureDisablesLayoutAnimations, true)
                        .layoutProbe("toolbox.review.viewport")
                        .onPreferenceChange(LayoutFramePreferenceKey.self) { frames in
                            Task { @MainActor in recorder.frames = frames }
                        }
                    let controller = NSHostingController(rootView: AnyView(root))
                    controller.sizingOptions = []
                    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.animationBehavior = .none
                    window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                    window.contentViewController = controller
                    window.setContentSize(size)
                    window.orderFront(nil)
                    defer {
                        window.orderOut(nil)
                        window.close()
                    }
                    for _ in 0..<24 {
                        controller.view.layoutSubtreeIfNeeded()
                        window.displayIfNeeded()
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    let label = "\(name) \(Int(size.width))×\(Int(size.height)) \(language) \(light ? "light" : "dark")"
                    let viewport = try XCTUnwrap(recorder.frames["toolbox.review.viewport"], label)
                    for key in ["toolbox.manager", "toolbox.footer.action", "toolbox.footer.total"] {
                        let frame = try XCTUnwrap(recorder.frames[key], "\(label): \(key)")
                        XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(frame), "\(label): \(key) \(frame) outside \(viewport)")
                    }
                    XCTAssertNotNil(recorder.frames["toolbox.category"], "\(label): the category column has rows")
                    if let evidence, size == Self.sizes[0] || size == Self.sizes[2] {
                        let hosted = controller.view
                        let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds), label)
                        hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
                        let suffix = (language == .english ? "en" : "zh") + (light ? "-light" : "-dark")
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: evidence.appendingPathComponent("w-\(name)-\(Int(size.width))-\(suffix).png"))
                    }
                }
            }
        }
    }
}
#endif
