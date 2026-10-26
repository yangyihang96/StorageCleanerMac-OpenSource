import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D154 batch 3Q: the extension and maintenance panels give every row of
/// their left column its own object, as CleanMyMac's managers do.
@MainActor
final class ToolboxCategoryArtTests: XCTestCase {
    func testEveryExtensionKindHasItsOwnObject() {
        assertOwnObjects(ExtensionKind.allCases.map { ($0.rawValue, $0.art) })
    }

    func testEveryMaintenanceTaskHasItsOwnObject() {
        assertOwnObjects(SystemMaintenanceTaskID.allCases.map { ($0.rawValue, $0.art) })
    }

    /// For review (`STORAGE_CLEANER_TOOLBOX_EVIDENCE`): the two left columns
    /// in the modules the app opens them in, each object turned to the
    /// panel's colour — window captures leave `hueRotation` out.
    func testRendersTheLeftColumnsForReview() async throws {
        guard let path = ProcessInfo.processInfo.environment["STORAGE_CLEANER_TOOLBOX_EVIDENCE"] else {
            throw XCTSkip("Review renders are written only when STORAGE_CLEANER_TOOLBOX_EVIDENCE is set.")
        }
        let scope = MiniWindowLogicLanguageScope(.zhHans)
        defer { scope.restore() }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let library = GeneratedArtLibrary(directory: root.appendingPathComponent("Resources/Art", isDirectory: true))
        for art in GeneratedArt.allCases where art.isTile {
            _ = await library.image(named: art.resourceName(.header))
        }
        let columns: [(name: String, module: CareStudioModule, rows: [(title: String, symbol: String, art: GeneratedArt)])] = [
            ("extensions", .applications, ExtensionKind.allCases.map { ($0.title, $0.systemImage, $0.art) }),
            ("maintenance", .startup, SystemMaintenanceTaskID.allCases.map { ($0.title, $0.systemImage, $0.art) }),
        ]
        for column in columns {
            let content = VStack(spacing: 2) {
                ForEach(column.rows.indices, id: \.self) { index in
                    let row = column.rows[index]
                    ToolboxCategoryRow(module: column.module, title: row.title, detail: "", systemImage: row.symbol,
                                       art: row.art, isCurrent: false, onSelect: {})
                }
            }
            .padding(10)
            .frame(width: 280)
            .background(CareStudioManagerInk.panel)
            .environment(\.generatedArtLibrary, library)
            .environment(\.generatedArtWindowVisible, true)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, column.name)
            try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: path).appendingPathComponent("left-column-\(column.name).png"))
        }
    }

    /// Each row's object is a small one (192 only) that takes its panel's
    /// colour, and no two rows of a panel share one.
    private func assertOwnObjects(_ rows: [(String, GeneratedArt)],
                                  file: StaticString = #filePath, line: UInt = #line) {
        var seen: [GeneratedArt: String] = [:]
        for (row, art) in rows {
            XCTAssertTrue(art.isTile, "\(row): \(art) is not a small object", file: file, line: line)
            XCTAssertFalse(art.keepsOwnColour, "\(row): \(art) would not take the panel's colour", file: file, line: line)
            if let other = seen[art] {
                XCTFail("\(row) and \(other) share \(art)", file: file, line: line)
            }
            seen[art] = row
        }
    }
}
