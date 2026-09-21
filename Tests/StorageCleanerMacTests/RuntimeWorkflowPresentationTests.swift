import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class RuntimeWorkflowPresentationTests: XCTestCase {
    func testUnknownAndNonfiniteProgressNeverBecomeAReportedPercentage() {
        for value in [nil, Double.nan, .infinity, -.infinity] {
            XCTAssertNil(RuntimeWorkflowState.measuredFraction(value))
        }
    }

    func testMeasuredProgressKeepsZeroAndCompletionAndClampsOvershoot() {
        XCTAssertEqual(RuntimeWorkflowState.measuredFraction(0), 0)
        XCTAssertEqual(RuntimeWorkflowState.measuredFraction(1), 1)
        XCTAssertEqual(RuntimeWorkflowState.measuredFraction(0.42), 0.42)
        XCTAssertEqual(RuntimeWorkflowState.measuredFraction(-0.2), 0)
        XCTAssertEqual(RuntimeWorkflowState.measuredFraction(1.2), 1)
    }

    func testPausedAndTerminalStatesDoNotShowAnActiveSpinner() {
        XCTAssertTrue(RuntimeWorkflowState.running.isActive)
        XCTAssertTrue(RuntimeWorkflowState.stopping.isActive)
        for state in [RuntimeWorkflowState.paused, .cancelled, .completed, .attention, .failed] {
            XCTAssertFalse(state.isActive)
        }
    }

    /// Exact production components with controlled data, kept separate from
    /// live captures. No Store is mutated and no cleanup or hardware work runs.
    func testRuntimeStatesRenderInLightDarkAndCompactLayouts() async throws {
        let states: [RuntimeWorkflowState] = [.running, .paused, .stopping, .cancelled, .completed, .attention, .failed]
        for scheme in [ColorScheme.dark, .light] {
            for width: CGFloat in [976, 441] {
                for (index, state) in states.enumerated() {
                    let theme = ReviewFilter.duplicates.moduleTheme
                    let root = ZStack {
                        ModuleBackground(theme: theme)
                        VStack(spacing: 12) {
                            RuntimeActivityCard(
                                title: "正在确认文件内容", subtitle: "副本在完整比对后才会列入结果",
                                state: state, fraction: state == .running ? nil : 0.42,
                                metrics: [.init(title: "已扫描文件", value: "12,345"), .init(title: "已完整比对", value: "256"), .init(title: "已读取内容", value: "8.2 GiB")],
                                currentItem: "/Users/example/" + String(repeating: "很长的目录名称/", count: 20) + "example.dat"
                            ) { EmptyView() }
                            RuntimeActivityFooter {
                                Button("继续") {}.appButtonChrome(.secondary)
                                Button("取消扫描") {}.appButtonChrome(.secondary)
                            }
                        }.padding(16)
                    }
                    .environment(\.moduleTheme, theme)
                    .preferredColorScheme(scheme)
                    let host = NSHostingView(rootView: root)
                    host.sizingOptions = []
                    host.frame = CGRect(x: 0, y: 0, width: width, height: 520)
                    for _ in 0..<4 {
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                    if let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_RUNTIME_SNAPSHOT_DIR"] {
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try data.write(to: directory.appendingPathComponent("shared-\(scheme)-\(Int(width))-state\(index).png"))
                    }
                }
            }
        }
    }
}
