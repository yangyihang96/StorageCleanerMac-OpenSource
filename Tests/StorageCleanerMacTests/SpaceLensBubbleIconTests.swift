import XCTest
@testable import StorageCleanerMac

/// D154 batch 3N: Space Lens bubbles show the item's own icon, as CleanMyMac
/// does — the app's, a folder's or the kind of file's, as in the list.
@MainActor
final class SpaceLensBubbleIconTests: XCTestCase {
    func testEveryItemBubbleCarriesItsIconSourceAndKeepsItsValues() {
        let app = StorageTreemapEntry(id: "/Applications/Notes.app", title: "Notes", path: "/Applications/Notes.app",
                                      sizeBytes: 300, kind: "app", isDirectory: true, isCloudOnly: false)
        let folder = StorageTreemapEntry(id: "/Users/me/Movies", title: "Movies", path: "/Users/me/Movies",
                                         sizeBytes: 200, kind: "folder", isDirectory: true, isCloudOnly: false)
        let file = StorageTreemapEntry(id: "/Users/me/a.mov", title: "a.mov", path: "/Users/me/a.mov",
                                       sizeBytes: 100, kind: "file", isDirectory: false, isCloudOnly: false)

        for entry in [app, folder, file] {
            let bubble = CareStudioSpaceLensPage.bubble(entry)
            let plain = FileLightfieldPresentation.chart(entry)
            XCTAssertEqual(bubble.picture, LightfieldChartPicture(path: entry.path, isDirectory: entry.isDirectory))
            XCTAssertEqual(bubble.id, plain.id)
            XCTAssertEqual(bubble.label, plain.label)
            XCTAssertEqual(bubble.value, plain.value)
            XCTAssertEqual(bubble.formattedValue, plain.formattedValue)
        }
        XCTAssertNil(FileLightfieldPresentation.chart(file).picture, "other charts keep their option glyphs")
    }

    /// The icon is at least 12 pt and at most 56 pt, and in a labelled bubble
    /// the name and size keep their two lines under it.
    func testTheIconFitsItsBubbleAndLeavesTheLabelsTheirLines() {
        XCTAssertEqual(LightfieldBubbleLayout.pictureSide(diameter: 28, labelled: false), 17)
        XCTAssertEqual(LightfieldBubbleLayout.pictureSide(diameter: 10, labelled: false), 12)
        XCTAssertEqual(LightfieldBubbleLayout.pictureSide(diameter: 180, labelled: false), 56)
        // D193③: the threshold went from 100 to 80 pt; the icon of a labelled
        // bubble at the threshold is now the 12 pt floor (26 pt at 100 pt,
        // the old threshold's value, as before).
        XCTAssertEqual(LightfieldBubbleLayout.pictureSide(diameter: LightfieldBubbleLayout.labelThreshold, labelled: true), 12)
        XCTAssertEqual(LightfieldBubbleLayout.pictureSide(diameter: 100, labelled: true), 26)
        XCTAssertEqual(LightfieldBubbleLayout.pictureSide(diameter: LightfieldBubbleLayout.maximumDiameter, labelled: true), 56)
        for diameter in stride(from: LightfieldBubbleLayout.labelThreshold, through: LightfieldBubbleLayout.maximumDiameter, by: 4) {
            let side = LightfieldBubbleLayout.pictureSide(diameter: diameter, labelled: true)
            XCTAssertLessThanOrEqual(side + 44, diameter * 0.7 + 0.5, "\(diameter): the icon crowds out the labels")
        }
    }
}
