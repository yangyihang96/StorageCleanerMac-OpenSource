#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Batch 2b review: rows whose labels were measured too wide for their space
/// render complete, at their own font size, in Chinese and English. Frames
/// come from the production views' layout probes; natural widths from AppKit.
@MainActor
final class MiniWindowRowLayoutTests: XCTestCase {
    /// Content width inside a card on a page of the given width.
    private func cardContentWidth(page: CGFloat) -> CGFloat {
        page - 2 * MiniWindowStyleTokens.contentInset - 2 * MiniWindowStyleTokens.cardHorizontalInset
    }

    func testProcessHeadersShowCompleteTitlesAndColumnLabels() async throws {
        let detail = cardContentWidth(page: MiniWindowStyleTokens.detailWidth)
        let power = cardContentWidth(page: MiniWindowStyleTokens.powerDetailWidth)
        for language in [AppLanguage.english, .zhHans] {
            let scope = RowLayoutLanguageScope(language)
            defer { scope.restore() }
            let cases: [(name: String, width: CGFloat, title: String, status: String?,
                         columns: [GeekProcessListColumn], loading: Bool)] = [
                ("power", power, L10n.text("使用显著能耗", "Using Significant Energy").uppercased(), nil,
                 [GeekProcessListColumn(id: "power", title: L10n.text("功率", "Power"))], true),
                ("network", detail, L10n.text("进程", "PROCESSES"), nil,
                 [GeekProcessListColumn(id: "upload", title: L10n.text("上传", "Upload"), tint: .pink),
                  GeekProcessListColumn(id: "download", title: L10n.text("下载", "Download"), tint: .blue)], false),
                ("disk", detail, L10n.text("进程", "PROCESSES"), nil,
                 [GeekProcessListColumn(id: "read", title: L10n.text("读取", "Read"), tint: .pink),
                  GeekProcessListColumn(id: "write", title: L10n.text("写入", "Write"), tint: .blue)], false),
                ("cpu", detail, L10n.text("进程", "PROCESSES"), L10n.text("未测量", "Not Measured"),
                 [GeekProcessListColumn(id: "cpu", title: L10n.text("占用", "CPU"))], false),
            ]
            for item in cases {
                let header = GeekProcessListHeader(title: item.title, status: item.status, columns: item.columns) {
                    if item.loading {
                        ProgressView().controlSize(.mini).frame(width: 10, height: 10)
                    }
                }
                let host = RowLayoutHost(content: header.frame(width: item.width), size: CGSize(width: item.width, height: 40))
                defer { host.close() }
                let ids = ["process-header.row", "process-header.title"] + item.columns.map { "process-header.column.\($0.id)" }
                let frames = try await host.frames(required: Set(ids))
                let row = try XCTUnwrap(frames["process-header.row"])
                let title = try XCTUnwrap(frames["process-header.title"])
                let context = "\(language.rawValue) \(item.name)"
                XCTAssertGreaterThanOrEqual(title.width, natural(item.title, weight: .semibold) - 0.5,
                                            "\(context): the title must not truncate")
                for (index, column) in item.columns.enumerated() {
                    let label = try XCTUnwrap(frames["process-header.column.\(column.id)"])
                    XCTAssertGreaterThanOrEqual(label.width, natural(column.title) - 0.5,
                                                "\(context): \(column.title) must not truncate")
                    // Right-aligned on the rows' value columns (60 pt slots, 6 pt apart).
                    let fromEnd = CGFloat(item.columns.count - 1 - index)
                        * (GeekSecondaryTransferLayout.processValueColumnWidth + MiniWindowStyleTokens.inlineSpacing)
                    XCTAssertEqual(label.maxX, row.maxX - fromEnd, accuracy: 0.5, "\(context): \(column.title) alignment")
                }
            }
        }
    }

    func testVolumeRowShowsTheCapacitySummaryAtFullSize() async throws {
        let width = MiniWindowStyleTokens.detailWidth - 2 * MiniWindowStyleTokens.contentInset
        // The longest realistic summary: three-digit gigabytes beside a full ring.
        let capacity = StorageCapacitySnapshot(totalBytes: 200_000_000_000_000, availableBytes: 999_990_000_000)
        for language in [AppLanguage.english, .zhHans] {
            let scope = RowLayoutLanguageScope(language)
            defer { scope.restore() }
            for checkedAt in [nil, Date().addingTimeInterval(-7_200)] as [Date?] {
                let volume = GeekDiskVolumePresentation(
                    id: "fixture", name: "Macintosh HD", capacity: capacity,
                    healthText: L10n.text("健康度 100%", "Health 100%"), smartStatus: .verified,
                    temperature: nil, isNetwork: false, healthCheckedAt: checkedAt
                )
                let summary = GeekDiskCapacityWording.volumeSummary(
                    usedPercent: try XCTUnwrap(volume.usagePercent),
                    available: ByteFormat.storageString(capacity.userAvailableBytes)
                )
                XCTAssertTrue(summary.contains("999.99"), summary)
                let host = RowLayoutHost(content: GeekDiskVolumeSummary(volume: volume).frame(width: width),
                                         size: CGSize(width: width, height: 60))
                defer { host.close() }
                let frames = try await host.frames(required: ["disk-volume.summary"])
                let frame = try XCTUnwrap(frames["disk-volume.summary"])
                XCTAssertGreaterThanOrEqual(frame.width, natural(summary, monospacedDigits: true) - 0.5,
                                            "\(language.rawValue): \(summary) must render complete at 11 pt")
                XCTAssertEqual(host.fittingHeight, GeekDiskVolumeLayout.cardHeight, accuracy: 0.5,
                               "The row keeps the height its tertiary offsets are computed with")
            }
        }
    }

    private func natural(_ text: String, weight: NSFont.Weight = .regular, monospacedDigits: Bool = false) -> CGFloat {
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: weight)
            : NSFont.systemFont(ofSize: 11, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}

@MainActor
private final class RowLayoutLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}

@MainActor
private final class RowLayoutRecorder { var frames: [String: CGRect] = [:] }

@MainActor
private final class RowLayoutHost {
    let window: NSWindow
    private let host: NSHostingView<AnyView>
    private let recorder = RowLayoutRecorder()

    init<Content: View>(content: Content, size: CGSize) {
        _ = NSApplication.shared
        let root = content
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: size.width, alignment: .topLeading)
            .environment(\.colorScheme, .dark)
            .environment(\.miniWindowVisualMode, .black)
            .onPreferenceChange(LayoutFramePreferenceKey.self) { [weak recorder] frames in
                Task { @MainActor [weak recorder] in recorder?.frames = frames }
            }
        host = NSHostingView(rootView: AnyView(root))
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
    }

    var fittingHeight: CGFloat { host.fittingSize.height }

    func frames(required: Set<String>) async throws -> [String: CGRect] {
        var previous: [String: CGRect]?
        var stablePasses = 0
        for _ in 0..<100 {
            host.needsLayout = true
            host.layoutSubtreeIfNeeded()
            await Task.yield()
            if required.isSubset(of: Set(recorder.frames.keys)) {
                let current = recorder.frames.filter { required.contains($0.key) }
                stablePasses = previous == current ? stablePasses + 1 : 0
                previous = current
                if stablePasses >= 2 { return current }
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NSError(domain: "MiniWindowRowLayoutTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Row layout frames did not stabilize"])
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}
#endif
