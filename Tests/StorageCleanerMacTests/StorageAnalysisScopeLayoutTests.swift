#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class StorageAnalysisScopeLayoutTests: XCTestCase {
    func testRealScopeButtonsReflowWithoutResettingSelection() async throws {
        let fixture = StorageScopeLayoutFixture()
        let host = StorageScopeLayoutHost(fixture: fixture, width: 345)
        defer { host.close() }

        let required: Set<String> = ["fileAnalysis.scopes", "fileAnalysis.scope.0", "fileAnalysis.scope.1"]
        let sizes: [(CGFloat, Int)] = [(345, 1), (335, 1), (336, 1), (260, 1), (420, 1)]
        for (index, size) in sizes.enumerated() {
            let revision = index == 0 ? nil : host.recorder.revision
            host.resize(width: size.0)
            let frames = try await host.frames(required: required, afterRevision: revision)
            let first = try XCTUnwrap(frames["fileAnalysis.scope.0"])
            let second = try XCTUnwrap(frames["fileAnalysis.scope.1"])
            let scopes = try XCTUnwrap(frames["fileAnalysis.scopes"])
            let pixel = 1 / host.window.backingScaleFactor
            XCTAssertEqual(scopes.width, size.0, accuracy: pixel)
            XCTAssertTrue(scopes.insetBy(dx: -pixel, dy: -pixel).contains(first))
            XCTAssertTrue(scopes.insetBy(dx: -pixel, dy: -pixel).contains(second))
            // D70 replaces the two-column cards with 56 pt option rows.
            XCTAssertEqual(first.height, 56, accuracy: pixel)
            XCTAssertEqual(second.height, 56, accuracy: pixel)
            XCTAssertEqual(first.minX, second.minX, accuracy: pixel)
            XCTAssertEqual(second.minY - first.maxY, 0, accuracy: pixel)
            XCTAssertEqual(fixture.selectedID, fixture.targets[1].id)
        }
    }

    func testLongTargetTitlesAndPathsRemainInsideMeasuredCards() async throws {
        let fixture = StorageScopeLayoutFixture()
        fixture.targets[0] = StorageMapScanTarget(
            path: "/Volumes/ScopeFixture-Long-External-Volume/Folder-With-A-Long-Name",
            title: "External storage with a long bilingual name 外接存储",
            kind: .externalVolume
        )
        let host = StorageScopeLayoutHost(fixture: fixture, width: 345)
        defer { host.close() }
        let required = Set((0..<2).flatMap {
            ["fileAnalysis.scope.\($0)", "fileAnalysis.scope.\($0).title", "fileAnalysis.scope.\($0).metadata"]
        })
        for (index, width) in [CGFloat(345), 260, 420].enumerated() {
            let revision = index == 0 ? nil : host.recorder.revision
            host.resize(width: width)
            let frames = try await host.frames(required: required, afterRevision: revision)
            let pixel = 1 / host.window.backingScaleFactor
            for target in 0..<2 {
                let card = try XCTUnwrap(frames["fileAnalysis.scope.\(target)"])
                let title = try XCTUnwrap(frames["fileAnalysis.scope.\(target).title"])
                let path = try XCTUnwrap(frames["fileAnalysis.scope.\(target).metadata"])
                XCTAssertGreaterThanOrEqual(card.height, 44)
                XCTAssertTrue(card.insetBy(dx: -pixel, dy: -pixel).contains(title))
                XCTAssertTrue(card.insetBy(dx: -pixel, dy: -pixel).contains(path))
                XCTAssertGreaterThanOrEqual(path.minX, title.maxX, "D70 metadata occupies the trailing column")
            }
            XCTAssertEqual(fixture.targets[0].path,
                "/Volumes/ScopeFixture-Long-External-Volume/Folder-With-A-Long-Name")
            XCTAssertEqual(fixture.selectedID, fixture.targets[1].id)
        }
    }
}

@MainActor
private final class StorageScopeLayoutFixture: ObservableObject {
    @Published var targets = [
        StorageMapScanTarget(path: "/", title: "Macintosh HD", kind: .internalVolume),
        StorageMapScanTarget(path: "/Users/ScopeFixture", title: "个人目录", kind: .homeDirectory)
    ]
    @Published var selectedID = "/Users/ScopeFixture"
}

private struct StorageScopeLayoutFixtureView: View {
    @ObservedObject var fixture: StorageScopeLayoutFixture

    var body: some View {
        StorageAnalysisScopePicker(targets: fixture.targets, selectedID: $fixture.selectedID, isDisabled: false)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
private final class StorageScopeFrameRecorder {
    var frames: [String: CGRect] = [:]
    var revision = 0

    func record(_ frames: [String: CGRect]) {
        self.frames = frames
        revision += 1
    }
}

@MainActor
private final class StorageScopeLayoutHost {
    let recorder = StorageScopeFrameRecorder()
    let window: NSWindow
    private let controller: NSHostingController<AnyView>

    init(fixture: StorageScopeLayoutFixture, width: CGFloat) {
        _ = NSApplication.shared
        let root = StorageScopeLayoutFixtureView(fixture: fixture)
            .onPreferenceChange(LayoutFramePreferenceKey.self) { [weak recorder] frames in
                Task { @MainActor [weak recorder] in recorder?.record(frames) }
            }
        controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.contentViewController = controller
        window.setContentSize(CGSize(width: width, height: 420))
    }

    func resize(width: CGFloat) {
        window.setContentSize(CGSize(width: width, height: 420))
        controller.view.needsLayout = true
        controller.view.layoutSubtreeIfNeeded()
    }

    func frames(required: Set<String>, afterRevision: Int?) async throws -> [String: CGRect] {
        var stable: [String: CGRect]?
        var stablePasses = 0
        for _ in 0..<120 {
            controller.view.needsLayout = true
            controller.view.layoutSubtreeIfNeeded()
            await Task.yield()
            let frames = recorder.frames
            if required.isSubset(of: Set(frames.keys)),
               afterRevision.map({ recorder.revision > $0 }) ?? true {
                stablePasses = frames == stable ? stablePasses + 1 : 1
                stable = frames
                if stablePasses >= 3 { return frames }
            } else {
                stable = nil
                stablePasses = 0
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "StorageScopeLayoutFixture", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Scope layout frames did not settle"])
    }

    func close() {
        window.orderOut(nil)
        window.contentViewController = nil
        window.close()
    }
}
#endif
