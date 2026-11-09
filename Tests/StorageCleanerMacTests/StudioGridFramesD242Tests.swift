import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// D242 (review P2-2): the 2.0.1 log had AppKit's “Invalid view geometry:
/// width/height is negative”. The window host could not reproduce it (every
/// module page at five sizes from 300 × 200 up, `CareStudioNavigationTests`),
/// so the studio grids' own arithmetic is held to sizes that are never
/// negative, however small the space they are given.
@MainActor
final class StudioGridFramesD242Tests: XCTestCase {
    private let narrow = [CGSize(width: 1, height: 1), CGSize(width: 10, height: 6), CGSize(width: 27, height: 13),
                          CGSize(width: 60, height: 40), CGSize(width: 900, height: 600)]

    private func assertNonNegative(_ frames: [CGRect], _ label: String) {
        for frame in frames {
            XCTAssertGreaterThanOrEqual(frame.width, 0, "\(label): \(frame)")
            XCTAssertGreaterThanOrEqual(frame.height, 0, "\(label): \(frame)")
        }
    }

    func testTileGridFramesAreNeverNegative() {
        for size in narrow {
            for count in 1...6 {
                assertNonNegative(CareStudioTileGrid.frames(count: count, in: size), "tiles \(count) in \(size)")
            }
        }
    }

    func testSmartCareGridsAreNeverNegative() {
        for size in narrow {
            for count in 1...5 {
                assertNonNegative(SmartCareResultsGrid.frames(count: count, in: size), "results \(count) in \(size)")
                for current in [nil] + (0..<count).map(Optional.some) {
                    assertNonNegative(SmartCareScanningCollage.frames(count: count, current: current, in: size),
                                      "scanning \(count), current \(String(describing: current)) in \(size)")
                }
            }
        }
    }

    func testRegularSizesKeepTheirLayout() {
        // The clamps change nothing where the space suffices (old frames).
        let tiles = CareStudioTileGrid.frames(count: 4, in: CGSize(width: 900, height: 600))
        XCTAssertEqual(tiles.count, 4)
        XCTAssertEqual(tiles[0].width, (900 - 2 * CareStudioMetrics.tileSpacing) / 3, accuracy: 0.001)
        let results = SmartCareResultsGrid.frames(count: 5, in: CGSize(width: 900, height: 600))
        XCTAssertEqual(results[0].width, (900 - 2 * CareStudioMetrics.tileSpacing) / 3, accuracy: 0.001)
    }
}
