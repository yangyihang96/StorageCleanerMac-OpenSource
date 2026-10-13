import AppKit
import XCTest
@testable import StorageCleanerMac

final class SimilarImagePreviewCacheTests: XCTestCase {
    @MainActor
    func testPreviewDecodesImageButRejectsTextAndSymbolicLinks() throws {
        let folder = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("similar-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let imageURL = folder.appendingPathComponent("photo.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for y in 0..<16 {
            for x in 0..<16 {
                bitmap.setColor(NSColor(calibratedRed: 0.2, green: 0.55, blue: 0.45, alpha: 1), atX: x, y: y)
            }
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: imageURL)
        XCTAssertNotNil(SimilarImagePreviewCache.decode(at: imageURL.path))

        let textURL = folder.appendingPathComponent("notes.txt")
        try Data("not an image".utf8).write(to: textURL)
        XCTAssertNil(SimilarImagePreviewCache.decode(at: textURL.path))

        let linkURL = folder.appendingPathComponent("photo-link.png")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: imageURL)
        XCTAssertNil(SimilarImagePreviewCache.decode(at: linkURL.path))

        let linkedFolder = folder.appendingPathComponent("linked-folder", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: folder)
        XCTAssertNil(SimilarImagePreviewCache.decode(
            at: linkedFolder.appendingPathComponent("photo.png").path
        ))
    }
}
