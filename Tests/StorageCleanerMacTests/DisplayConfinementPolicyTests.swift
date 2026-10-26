import CoreGraphics
import XCTest
@testable import StorageCleanerMac

/// D106: the pure placement rules, on fixture displays only.
final class DisplayConfinementPolicyTests: XCTestCase {
    static let main = DisplayConfinementScreen(
        displayID: 1, name: "Fixture Built-in",
        frame: CGRect(x: 0, y: 0, width: 1352, height: 878),
        visibleFrame: CGRect(x: 0, y: 0, width: 1352, height: 845), isMain: true
    )
    static let target = DisplayConfinementScreen(
        displayID: 2, name: "Fixture 虚拟屏 · Target",
        frame: CGRect(x: 1352, y: -202, width: 1920, height: 1080),
        visibleFrame: CGRect(x: 1352, y: -202, width: 1920, height: 1055), isMain: false
    )
    static let other = DisplayConfinementScreen(
        displayID: 3, name: "Fixture Other",
        frame: CGRect(x: -1440, y: 0, width: 1440, height: 900),
        visibleFrame: CGRect(x: -1440, y: 0, width: 1440, height: 875), isMain: false
    )

    func testTargetMustMatchExactlyOnceAndNeverBeTheMenuBarDisplay() {
        let screens = [Self.main, Self.target, Self.other]
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: Self.target.name, in: screens), .success(Self.target))
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: "", in: screens), .failure(.emptyName))
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: "fixture 虚拟屏 · target", in: screens),
                       .failure(.missing(name: "fixture 虚拟屏 · target")))
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: "Fixture 虚拟屏", in: screens),
                       .failure(.missing(name: "Fixture 虚拟屏")))
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: Self.target.name, in: [Self.main, Self.other]),
                       .failure(.missing(name: Self.target.name)))
        let twin = DisplayConfinementScreen(displayID: 4, name: Self.target.name, frame: Self.other.frame,
                                            visibleFrame: Self.other.visibleFrame, isMain: false)
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: Self.target.name, in: screens + [twin]),
                       .failure(.ambiguous(name: Self.target.name, count: 2)))
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: Self.main.name, in: screens),
                       .failure(.mainDisplay(name: Self.main.name)))
        XCTAssertEqual(DisplayConfinementPolicy.resolveTarget(named: Self.target.name, in: []),
                       .failure(.missing(name: Self.target.name)))
    }

    func testContainmentUsesTheWholeDisplayWithHalfAPointTolerance() {
        let target = Self.target
        XCTAssertTrue(DisplayConfinementPolicy.contains(CGRect(x: 1400, y: 0, width: 800, height: 600), in: target))
        XCTAssertTrue(DisplayConfinementPolicy.contains(target.frame, in: target))
        XCTAssertTrue(DisplayConfinementPolicy.contains(target.frame.insetBy(dx: -0.4, dy: -0.4), in: target))
        XCTAssertFalse(DisplayConfinementPolicy.contains(target.frame.insetBy(dx: -0.6, dy: 0), in: target))
        // One point onto the menu-bar display is off the target.
        XCTAssertFalse(DisplayConfinementPolicy.contains(CGRect(x: 1351, y: 0, width: 400, height: 300), in: target))
        XCTAssertFalse(DisplayConfinementPolicy.contains(CGRect(x: 100, y: 100, width: 400, height: 300), in: target))
        // A window with no area counts by its origin.
        XCTAssertTrue(DisplayConfinementPolicy.contains(CGRect(x: 1500, y: 10, width: 0, height: 0), in: target))
        XCTAssertFalse(DisplayConfinementPolicy.contains(CGRect(x: 10, y: 10, width: 0, height: 0), in: target))
        XCTAssertFalse(DisplayConfinementPolicy.contains(CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10), in: target))
        XCTAssertFalse(DisplayConfinementPolicy.contains(CGRect(x: 1400, y: 0, width: CGFloat.infinity, height: 10), in: target))
    }

    func testPlacementKeepsMovesShrinksOrRefuses() {
        let target = Self.target
        let inside = CGRect(x: 1500, y: 100, width: 800, height: 600)
        XCTAssertEqual(DisplayConfinementPolicy.place(inside, minimumSize: .zero, in: target), .unchanged(inside))

        // A frame on the menu-bar display is centred in the target's visible area.
        let onMain = CGRect(x: 100, y: 100, width: 800, height: 600)
        let centred = CGRect(x: (target.visibleFrame.midX - 400).rounded(.down),
                             y: (target.visibleFrame.midY - 300).rounded(.down), width: 800, height: 600)
        XCTAssertEqual(DisplayConfinementPolicy.place(onMain, minimumSize: .zero, in: target), .moved(centred))

        // A frame across the two displays moves the shortest way.
        let across = CGRect(x: 1300, y: 100, width: 400, height: 300)
        XCTAssertEqual(DisplayConfinementPolicy.place(across, minimumSize: .zero, in: target),
                       .moved(CGRect(x: 1352, y: 100, width: 400, height: 300)))

        // Larger than the visible area: shrinks when the minimum size allows.
        let huge = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        XCTAssertEqual(DisplayConfinementPolicy.place(huge, minimumSize: CGSize(width: 600, height: 400), in: target),
                       .moved(target.visibleFrame))
        XCTAssertEqual(DisplayConfinementPolicy.place(huge, minimumSize: CGSize(width: 2000, height: 400), in: target),
                       .refused("the window's minimum size does not fit the target display"))
        XCTAssertEqual(DisplayConfinementPolicy.place(huge, minimumSize: CGSize(width: 600, height: 1056), in: target),
                       .refused("the window's minimum size does not fit the target display"))
        XCTAssertEqual(DisplayConfinementPolicy.place(CGRect(x: CGFloat.nan, y: 0, width: 1, height: 1),
                                                      minimumSize: .zero, in: target),
                       .refused("the window frame is not finite"))
        // A window without area off the target is moved by its origin.
        guard case .moved(let placed) = DisplayConfinementPolicy.place(.zero, minimumSize: .zero, in: target) else {
            return XCTFail("an off-target empty frame must move")
        }
        XCTAssertTrue(DisplayConfinementPolicy.contains(placed, in: target))
    }

    func testEveryPlacedFrameLiesOnTheTarget() {
        var generator = FixtureRandom(seed: 0x0106)
        for _ in 0..<2_000 {
            let frame = CGRect(x: generator.next(in: -4000...6000), y: generator.next(in: -3000...3000),
                               width: generator.next(in: 0...4000), height: generator.next(in: 0...3000))
            let minimum = CGSize(width: generator.next(in: 0...2500), height: generator.next(in: 0...1500))
            switch DisplayConfinementPolicy.place(frame, minimumSize: minimum, in: Self.target) {
            case .unchanged(let placed), .moved(let placed):
                XCTAssertTrue(DisplayConfinementPolicy.contains(placed, in: Self.target), "\(frame) -> \(placed)")
                XCTAssertFalse(placed.intersects(Self.main.frame.insetBy(dx: 0.5, dy: 0.5)), "\(placed)")
            case .refused:
                XCTAssertTrue(minimum.width > Self.target.visibleFrame.width
                              || minimum.height > Self.target.visibleFrame.height, "\(frame) \(minimum)")
            }
        }
    }
}

/// Deterministic numbers for the placement sweep (SplitMix64).
private struct FixtureRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next(in range: ClosedRange<Double>) -> CGFloat {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        value ^= value >> 31
        let unit = Double(value >> 11) / Double(1 << 53)
        return CGFloat(range.lowerBound + unit * (range.upperBound - range.lowerBound))
    }
}
