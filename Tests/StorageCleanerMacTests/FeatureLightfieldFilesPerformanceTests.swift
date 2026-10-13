#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

@MainActor
final class FeatureLightfieldFilesPerformanceTests: XCTestCase {
    func testTwoThousandGroupsPrecomputeKeepersAndDatesOnceWithoutRowSearches() throws {
        let groups = largeGroups()
        let preferred = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.items[1].id) })
        let selected = Set(groups.map { $0.items[0].id })
        let started = ContinuousClock.now
        let presentation = DuplicateLightfieldPresentation.make(groups: groups, selectedIDs: selected,
            preferredKeepers: preferred)
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertTrue(presentation.canKeepNewest)
        XCTAssertEqual(presentation.keeperIDsByGroup.count, 2_000)
        XCTAssertEqual(presentation.newestItemsByGroup.count, 2_000)
        XCTAssertEqual(presentation.modifiedAtByItemID.count, 6_000)
        for group in groups {
            XCTAssertEqual(presentation.keeperIDsByGroup[group.id], group.items[1].id)
            XCTAssertEqual(presentation.newestItemsByGroup[group.id]?.id, group.items[2].id)
        }

        // Follow UtilityPresentationPerformanceTests: guard the actual render
        // path so a linear model cannot hide searches repeated in lazy rows.
        let source = try sourceText("DuplicateFilesLightfieldView.swift")
        let body = try XCTUnwrap(source.range(of: "struct DuplicateLightfieldBody: View {"))
        let row = try XCTUnwrap(source.range(of: "struct LightfieldDuplicateRow: View {"))
        let render = String(source[body.lowerBound..<row.lowerBound])
        XCTAssertEqual(render.components(separatedBy: "DuplicateLightfieldPresentation.make(").count - 1, 1)
        XCTAssertEqual(render.components(separatedBy: "presentation.keeperIDsByGroup[group.id] == item.id").count - 1, 2)
        XCTAssertTrue(render.contains("modifiedAt: presentation.modifiedAtByItemID[item.id]"))
        XCTAssertTrue(render.contains("presentation.newestItemsByGroup[group.id]"))
        XCTAssertFalse(render.contains("keeper(group)"))
        XCTAssertFalse(render.contains("private func keeper("))
        XCTAssertFalse(render.contains("group.items.first(where:"))
        print("B7PERF duplicatePresentation groups=2000 copies=6000 elapsed=\(elapsed)")
    }

    func testTwoThousandGroupsBuildOnlyLazyFirstScreenWithinOneSecondAndKeepGeometry() async throws {
        let groups = largeGroups()
        let model = MetadataSelectionFixture()
        _ = NSApplication.shared
        let size = CGSize(width: 1070, height: 735)
        let started = ContinuousClock.now
        let host = CalibrationAppKitLayoutHost(root: DuplicateMetadataNativeFixture(groups: groups, model: model), size: size, dark: true)
        defer { host.close() }
        let firstID = groups[0].items[0].id
        let frames = try await host.frames(required: ["fixture.viewport", "lightfield.primary",
            "lightfield.duplicates.row." + firstID, "lightfield.duplicates.group." + groups[0].id], size: size)
        let elapsed = started.duration(to: .now)
        let rows = frames.filter { $0.key.hasPrefix("lightfield.duplicates.row.") }
        XCTAssertLessThan(elapsed, .seconds(1), "Native construction and first stable screen, excluding data fixture creation")
        XCTAssertGreaterThan(rows.count, 0)
        XCTAssertLessThan(rows.count, 120, "At most 2% of the 6,000 rows may be realized for the first screen")
        XCTAssertNil(frames["lightfield.duplicates.row." + groups[1_999].items[2].id])
        XCTAssertEqual(try XCTUnwrap(frames["lightfield.primary"]).height, 52, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(frames["lightfield.duplicates.group." + groups[0].id]).height, 52, accuracy: 0.5)
        for frame in rows.values { XCTAssertEqual(frame.height, 52, accuracy: 0.5) }
        XCTAssertTrue(try sourceText("DuplicateFilesLightfieldView.swift").contains("LazyVStack(alignment: .leading, spacing: 0)"))
        print("B7PERF nativeFirstScreen groups=2000 copies=6000 realizedRows=\(rows.count) elapsed=\(elapsed)")
    }

    func testMigrationSelectionCachesEligibilityOnceForSixThousandRows() throws {
        let entries = (0..<6_000).map { index in
            LightfieldMigrationEntry(item: ExternalMigrationItem(id: "file:\(index)", title: "\(index).bin",
                sourceURL: URL(fileURLWithPath: "/Fixture/\(index).bin"), sizeBytes: 1_000, kind: .file,
                bundleIdentifier: ""), modifiedAt: nil)
        }
        let completed = Set(entries.prefix(10).map(\.id))
        let started = ContinuousClock.now
        let selection = LightfieldMigrationSelection.make(entries: entries, completedIDs: completed,
            selectedIDs: Set(entries.map(\.id)).union(["outside"]))
        let elapsed = started.duration(to: .now)
        XCTAssertLessThan(elapsed, .milliseconds(200))
        XCTAssertEqual(selection.eligibleIDs, Set(entries.dropFirst(10).map(\.id)))
        XCTAssertEqual(selection.entries.map(\.id), entries.dropFirst(10).map(\.id))
        XCTAssertEqual(selection.bytes, 5_990_000)
        let source = try sourceText("FileMigrationLightfieldView.swift")
        XCTAssertEqual(source.components(separatedBy: "LightfieldMigrationSelection.make(").count - 1, 1)
        XCTAssertFalse(source.contains("private var eligibleIDs:"))
        XCTAssertTrue(source.contains("row(entry, eligibleIDs: selection.eligibleIDs)"))
        print("B7PERF migrationSelection rows=6000 elapsed=\(elapsed)")
    }

    private func largeGroups() -> [DuplicateDisplayGroup] {
        (0..<2_000).map { index in
            let id = "g\(index)"
            let items = (0..<3).map { copy in
                metadataItem(id: "\(id)-\(copy)", path: "/Fixture/\(id)/\(copy).bin",
                    date: Date(timeIntervalSince1970: 1_791_288_000 + Double(copy)))
            }
            return DuplicateDisplayGroup(id: id, title: id, sizeBytes: items[0].sizeBytes, items: items,
                isContentConfirmed: true, candidateRule: nil, relationship: .independent, physicalReclaimableBytes: nil)
        }
    }

    private func sourceText(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/FilesLightfield/" + file), encoding: .utf8)
    }
}
#endif
