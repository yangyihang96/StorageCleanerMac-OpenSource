import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import StorageCleanerMac

private actor ArtDecodeGate {
    private(set) var calls = 0
    private var pending: [CheckedContinuation<GeneratedArtImage?, Never>] = []
    func decode() async -> GeneratedArtImage? {
        calls += 1
        return await withCheckedContinuation { pending.append($0) }
    }
    func release(_ image: GeneratedArtImage? = nil) {
        let waiting = pending
        pending = []
        for item in waiting { item.resume(returning: image) }
    }
}

final class GeneratedArtLifecycleTests: XCTestCase {
    private var imageURL: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Art/module-memory-192.heic")
    }

    @MainActor
    func testHiddenPreloadHasZeroResolverAndDecoderCallsAndVisibleReadsOnce() async throws {
        let calls = StartupWorkCounter(), url = imageURL
        let library = GeneratedArtLibrary(resolver: GeneratedArtResolver { _ in calls.read("resolve"); return url },
            decoder: { url in
                calls.read("decode")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
                return GeneratedArtImage(image: image)
            })
        await library.preload(["current", "other"], whileVisible: false)
        XCTAssertEqual(calls.count("resolve"), 0)
        XCTAssertEqual(calls.count("decode"), 0, "A constructed hidden main view does no speculative work")
        let first = await library.image(named: "current")
        XCTAssertNotNil(first, "Visible current-page demand does not wait for speculative art")
        await library.preload(["current"], whileVisible: true)
        XCTAssertEqual(calls.count("decode"), 1)
        let reopened = await library.image(named: "current")
        XCTAssertTrue(first === reopened)
        XCTAssertEqual(calls.count("resolve"), 1, "Hide/reopen/rapid page return reuses the decoded picture")
    }

    @MainActor
    func testCancellationStopsSpeculativeQueueAndNeverCachesCancellationAsMissing() async throws {
        let gate = ArtDecodeGate(), url = imageURL, cancellations = StartupWorkCounter()
        let library = GeneratedArtLibrary(resolver: GeneratedArtResolver { _ in url }, decoder: { _ in
            let value = await gate.decode()
            if Task.isCancelled { cancellations.read("decode") }
            return value
        })
        let preload = Task { await library.preload(["first", "second", "third"], whileVisible: true) }
        try await StartupTestWait.until { await gate.calls == 1 }
        preload.cancel()
        await gate.release()
        await preload.value
        XCTAssertEqual(cancellations.count("decode"), 1, "The detached decoder receives cancellation when its last owner hides")
        XCTAssertFalse(library.isKnownMissing(named: "first"))
        let calls = await gate.calls
        XCTAssertEqual(calls, 1, "Hiding stops the remaining physical decodes")
        let retry = Task { await library.image(named: "first") }
        try await StartupTestWait.until { await gate.calls == 2 }
        await gate.release()
        _ = await retry.value
        XCTAssertTrue(library.isKnownMissing(named: "first"), "Only a completed missing decode is remembered")
    }

    @MainActor
    func testCancelledWaiterDoesNotCancelAnotherVisibleWaiterOrDuplicateDecode() async throws {
        let gate = ArtDecodeGate(), url = imageURL, resolves = StartupWorkCounter()
        let library = GeneratedArtLibrary(resolver: GeneratedArtResolver { _ in resolves.read("lookup"); return url },
            decoder: { _ in await gate.decode() })
        let first = Task { await library.image(named: "shared") }
        try await StartupTestWait.until { await gate.calls == 1 }
        let second = Task { await library.image(named: "shared") }
        // Prove both requests joined the same physical flight before cancellation.
        try await StartupTestWait.until { library.activeWaiterCount(named: "shared") == 2 }
        first.cancel()
        await gate.release()
        let cancelled = await first.value
        _ = await second.value
        XCTAssertNil(cancelled)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(resolves.count("lookup"), 1)
        XCTAssertTrue(library.isKnownMissing(named: "shared"), "A surviving request completed normally")
    }

    func testProductionViewTasksUseActualWindowVisibility() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let content = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/ContentView.swift"), encoding: .utf8)
        XCTAssertTrue(content.contains("@State private var generatedArtWindowVisible = false"))
        XCTAssertTrue(content.contains("GeneratedArtWindowVisibility(visible: $generatedArtWindowVisible)"))
        XCTAssertTrue(content.contains("guard generatedArtWindowVisible else { return }"))
        for name in ["GeneratedArtView.swift", "FeatureLightfield.swift", "FeatureLightfieldComponents.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent("Sources/StorageCleanerMac/Views/DesignSystem/" + name), encoding: .utf8)
            XCTAssertTrue(source.contains("guard artWindowVisible else { return }"), name)
            XCTAssertTrue(source.contains("visible: artWindowVisible"), name)
        }
    }
}
