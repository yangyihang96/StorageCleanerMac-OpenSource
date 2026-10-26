import Foundation
import XCTest
@testable import StorageCleanerMac

final class SpaceMapTreemapViewStateTests: XCTestCase {
    typealias State = SpaceMapTreemapViewState
    typealias Tile = SpaceMapTreemapLayout.Tile
    private let size = CGSize(width: 600, height: 400)
    private let point = CGPoint(x: 100, y: 100)

    private func entry(_ name: String, directory: Bool = true, bytes: Int64 = 100) -> StorageTreemapEntry {
        .init(id: name, title: name, path: "/analysis/" + name, sizeBytes: bytes, kind: directory ? "folder" : "file",
              isDirectory: directory, childCount: directory ? 2 : nil)
    }

    private var directory: Tile {
        Tile(kind: .entry(entry("folder")), frame: CGRect(x: 10, y: 10, width: 250, height: 200), depth: 0,
             header: CGRect(x: 10, y: 10, width: 250, height: 20))
    }

    @discardableResult
    private func zoom(_ state: inout State, factor: CGFloat, phase: State.Phase = .none,
                      momentum: Bool = false, time: TimeInterval = 1) -> State.Action {
        state.zoom(factor: factor, at: point, tiles: [directory], size: size, phase: phase,
                   momentum: momentum, time: time, canNavigate: true)
    }

    func testZoomKeepsThePointUnderThePointerFixed() {
        let before = State.Viewport(scale: 1.5, origin: CGPoint(x: 30, y: 20))
        let after = before.zoomed(at: point, factor: 1.2, ceiling: 5)
        XCTAssertEqual(before.unproject(point).x, after.unproject(point).x, accuracy: 0.000_001)
        XCTAssertEqual(before.unproject(point).y, after.unproject(point).y, accuracy: 0.000_001)
    }

    func testScaleIsClampedToOneAndTheCeiling() {
        XCTAssertEqual(State.Viewport().zoomed(at: point, factor: 1_000, ceiling: 2.5).scale, 2.5)
        XCTAssertEqual(State.Viewport(scale: 4).zoomed(at: point, factor: 0.001, ceiling: 5).scale, 1)
    }

    func testCeilingUsesDeepestDirectoryBodyAndCapsAtFive() {
        let deeper = Tile(kind: .entry(entry("folder/inner")), frame: CGRect(x: 20, y: 40, width: 100, height: 80), depth: 1,
                          header: CGRect(x: 20, y: 40, width: 100, height: 15))
        let state = State()
        XCTAssertEqual(state.zoomCeiling(at: point, tiles: [directory], size: size), min(600 / 250, 400 / 180), accuracy: 0.0001)
        XCTAssertEqual(state.zoomCeiling(at: point, tiles: [directory, deeper], size: size), 5)
    }

    func testFilesAndRemaindersHaveNoZoomTarget() {
        let file = Tile(kind: .entry(entry("a.mov", directory: false)), frame: directory.frame, depth: 0, header: nil)
        let remainder = StorageTreemapEntry(id: "rest", title: "rest", path: "", sizeBytes: 10, kind: "aggregate",
                                            isDirectory: false, role: .unmeasuredRemainder)
        for tile in [file, Tile(kind: .entry(remainder), frame: directory.frame, depth: 0, header: nil)] {
            var state = State()
            XCTAssertEqual(state.zoomCeiling(at: point, tiles: [tile], size: size), 1)
            XCTAssertEqual(state.zoom(factor: 2, at: point, tiles: [tile], size: size, phase: .none,
                                      momentum: false, time: 1, canNavigate: true), .none)
            XCTAssertEqual(state.viewport.scale, 1)
        }
    }

    func testZoomAtCeilingEntersOnTheNextEventWithScreenBody() {
        var state = State()
        XCTAssertEqual(zoom(&state, factor: 10), .none)
        let from = state.viewport.project(State.body(directory))
        XCTAssertEqual(zoom(&state, factor: 1.15, time: 2), .enter(entry("folder"), from: from))
    }

    func testZoomOutAtOneReturns() {
        var state = State()
        XCTAssertEqual(zoom(&state, factor: 0.8), .back)
    }

    func testMomentumScalesWithoutEntering() {
        var state = State()
        zoom(&state, factor: 10)
        XCTAssertEqual(zoom(&state, factor: 1.15, phase: .changed, momentum: true), .none)
        XCTAssertEqual(zoom(&state, factor: 0.9, phase: .changed, momentum: true), .none)
        XCTAssertLessThan(state.viewport.scale, state.zoomCeiling(at: point, tiles: [directory], size: size))
    }

    func testSecondNavigationWithinTheSameGestureIsRejected() {
        var state = State()
        zoom(&state, factor: 10, phase: .began)
        XCTAssertNotEqual(zoom(&state, factor: 1.15, phase: .changed), .none)
        XCTAssertEqual(zoom(&state, factor: 1.15, phase: .changed, time: 2), .none)
        XCTAssertNotEqual(zoom(&state, factor: 1.15, phase: .began, time: 3), .none)
    }

    func testOrdinaryWheelWaitsThreeHundredMillisecondsBetweenNavigations() {
        var gate = State.GestureGate()
        XCTAssertTrue(gate.allowsNavigation(phase: .none, momentum: false, time: 1, requested: true))
        XCTAssertFalse(gate.allowsNavigation(phase: .none, momentum: false, time: 1.299, requested: true))
        XCTAssertTrue(gate.allowsNavigation(phase: .none, momentum: false, time: 1.301, requested: true))
    }

    func testDeviceDirectionIsIndependentOfNaturalScrollingAndDeltasAreBounded() {
        let ordinary = State.scrollLines(deltaY: 2, precise: false, inverted: false)
        let natural = State.scrollLines(deltaY: -48, precise: true, inverted: true)
        XCTAssertEqual(ordinary, natural)
        XCTAssertGreaterThan(pow(1.15, natural), 1)
        XCTAssertEqual(State.scrollLines(deltaY: 999, precise: false, inverted: false), 3)
        XCTAssertEqual(State.scrollLines(deltaY: -999, precise: true, inverted: false), -3)
    }

    func testPanRemainsWithinTheContentBounds() {
        var state = State(viewport: .init(scale: 2))
        state.pan(by: CGSize(width: -2_000, height: -2_000), size: size)
        XCTAssertEqual(state.viewport.origin, CGPoint(x: 300, y: 200))
        state.pan(by: CGSize(width: 2_000, height: 2_000), size: size)
        XCTAssertEqual(state.viewport.origin, .zero)
    }

    func testEscapeResetsZoomBeforeReturningAndBusyNeverNavigates() {
        var state = State(viewport: .init(scale: 2))
        XCTAssertEqual(state.escape(canNavigate: true), .reset(from: .init(scale: 2)))
        XCTAssertEqual(state.viewport.scale, 1)
        XCTAssertEqual(state.escape(canNavigate: true), .back)
        XCTAssertEqual(state.escape(canNavigate: false), .none)
        XCTAssertEqual(state.zoom(factor: 0.8, at: point, tiles: [directory], size: size, phase: .began,
                                  momentum: false, time: 1, canNavigate: false), .none)
    }

    func testTransitionUsesCubicEaseOutAndExactEndpoints() {
        let from = CGRect(x: 50, y: 60, width: 200, height: 100)
        let to = CGRect(x: 0, y: 0, width: 600, height: 400)
        let transition = State.Transition(source: from, destination: to, started: 10)
        XCTAssertEqual(transition.sample(to, at: 10), from)
        XCTAssertEqual(transition.sample(to, at: 10 + transition.duration), to)
        let middle = transition.sample(to, at: 10 + transition.duration / 2)
        XCTAssertEqual(middle.minX, 50 * 0.125, accuracy: 0.0001)
        XCTAssertEqual(middle.width, 200 + 400 * 0.875, accuracy: 0.0001)
    }

    func testTransitionDurationIsMonotonicAndReducedMotionIsImmediate() {
        let rect = CGRect(origin: .zero, size: size)
        var previous: TimeInterval = 0
        for ratio in [1.0, 2, 4, 8, 16, 32] {
            let t = State.Transition(source: rect, destination: CGRect(x: 0, y: 0, width: 600 / ratio, height: 400 / ratio), started: 0)
            XCTAssertGreaterThanOrEqual(t.duration, 0.13)
            XCTAssertLessThanOrEqual(t.duration, 0.31)
            XCTAssertGreaterThanOrEqual(t.duration, previous)
            previous = t.duration
        }
        let t = State.Transition(source: .zero, destination: rect, started: 0, reduceMotion: true)
        XCTAssertEqual(t.duration, 0)
        XCTAssertEqual(t.sample(rect, at: 0), rect)
    }

    func testDirectionSelectsNearestSiblingAndIgnoresAnotherParent() {
        let a = Tile(kind: .entry(entry("a")), frame: CGRect(x: 0, y: 0, width: 50, height: 50), depth: 1, header: nil)
        let near = Tile(kind: .entry(entry("b")), frame: CGRect(x: 55, y: 0, width: 50, height: 50), depth: 1, header: nil)
        let far = Tile(kind: .entry(entry("c")), frame: CGRect(x: 50, y: 70, width: 50, height: 50), depth: 1, header: nil)
        let unrelated = Tile(kind: .entry(entry("other/child")), frame: CGRect(x: 51, y: 0, width: 50, height: 50), depth: 1, header: nil)
        var state = State(selectedID: "a")
        state.move(.right, tiles: [a, far, unrelated, near])
        XCTAssertEqual(state.selectedID, "b")
        state.move(.right, tiles: [a, near])
        XCTAssertEqual(state.selectedID, "b")
    }

    func testDirectionWithoutSelectionChoosesLargestTopLevelTile() {
        let small = Tile(kind: .entry(entry("small")), frame: CGRect(x: 0, y: 0, width: 5, height: 5), depth: 0, header: nil)
        var state = State()
        state.move(.down, tiles: [small, directory])
        XCTAssertEqual(state.selectedID, "folder")
    }

    func testRootRemainderSharesTheCurrentDirectoryWithContentTiles() {
        let first = Tile(kind: .entry(entry("first")), frame: CGRect(x: 0, y: 0, width: 50, height: 50), depth: 0, header: nil)
        let rest = StorageTreemapEntry(id: "rest", title: "rest", path: "", sizeBytes: 10, kind: "aggregate",
                                      isDirectory: false, role: .unmeasuredRemainder)
        let remainder = Tile(kind: .entry(rest), frame: CGRect(x: 55, y: 0, width: 50, height: 50), depth: 0, header: nil)
        var state = State(selectedID: "first")
        state.move(.right, tiles: [first, remainder])
        XCTAssertEqual(state.selectedID, "rest")
    }

    func testHoverMapsDeepEntriesToTopLevelAndOmitsAggregates() {
        let deep = Tile(kind: .entry(entry("folder/child.mov", directory: false)), frame: .zero, depth: 1, header: nil)
        XCTAssertEqual(State.highlightedID(for: deep, roots: [entry("folder")]), "folder")
        XCTAssertNil(State.highlightedID(for: .init(kind: .others(parentPath: "/analysis/folder", count: 5, bytes: 8),
                                                   frame: .zero, depth: 1, header: nil), roots: [entry("folder")]))
        let remainder = StorageTreemapEntry(id: "rest", title: "rest", path: "", sizeBytes: 1, kind: "aggregate",
                                            isDirectory: false, role: .measuredRemainder)
        XCTAssertNil(State.highlightedID(for: .init(kind: .entry(remainder), frame: .zero, depth: 0, header: nil), roots: [remainder]))
    }
}
