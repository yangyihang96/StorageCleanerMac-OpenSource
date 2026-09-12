import Combine
import XCTest
@testable import StorageCleanerMac

final class MenuBarMonitorSessionTests: XCTestCase {
    @MainActor
    func testSessionTransferTotalsAccumulateWithoutExtraMonitorPublications() {
        let state = MenuBarMonitorState()
        var publicationCount = 0
        let cancellable = state.objectWillChange.sink {
            publicationCount += 1
        }

        state.update(snapshot(at: 100, download: 100, upload: 50))
        XCTAssertEqual(state.sessionDownloadedBytes, 0)
        XCTAssertEqual(state.sessionUploadedBytes, 0)

        state.update(snapshot(at: 102, download: 100, upload: 50))
        XCTAssertEqual(state.sessionDownloadedBytes, 200)
        XCTAssertEqual(state.sessionUploadedBytes, 100)

        // Long gaps are capped so waking from sleep cannot fabricate traffic.
        state.update(snapshot(at: 202, download: 100, upload: 50))
        XCTAssertEqual(state.sessionDownloadedBytes, 700)
        XCTAssertEqual(state.sessionUploadedBytes, 350)
        XCTAssertEqual(publicationCount, 3)
        withExtendedLifetime(cancellable) {}
    }

    @MainActor
    func testOutOfOrderSampleDoesNotChangeSessionTotalsAndRemainsInHistory() {
        let state = MenuBarMonitorState()
        state.update(snapshot(at: 10, download: 80, upload: 20))
        state.update(snapshot(at: 12, download: 80, upload: 20))
        state.update(snapshot(at: 11, download: 9_999, upload: 9_999))

        XCTAssertEqual(state.sessionDownloadedBytes, 160)
        XCTAssertEqual(state.sessionUploadedBytes, 40)
        XCTAssertEqual(state.history.map(\.date), [
            Date(timeIntervalSince1970: 10),
            Date(timeIntervalSince1970: 11),
            Date(timeIntervalSince1970: 12)
        ])
    }

    @MainActor
    func testSessionTransferTotalsIgnoreNegativeRatesAndSaturateSafely() {
        let state = MenuBarMonitorState()
        state.update(snapshot(at: 1, download: 1, upload: 1))
        state.update(snapshot(at: 2, download: -1, upload: -1))
        XCTAssertEqual(state.sessionDownloadedBytes, 0)
        XCTAssertEqual(state.sessionUploadedBytes, 0)

        state.update(snapshot(at: 3, download: .max, upload: .max))
        XCTAssertEqual(state.sessionDownloadedBytes, .max)
        XCTAssertEqual(state.sessionUploadedBytes, .max)
    }

    @MainActor
    func testPanelOpenRefreshesOnlyWhenTheSharedSnapshotIsStale() {
        let state = MenuBarMonitorState()
        let generatedAt = Date(timeIntervalSince1970: 100)

        XCTAssertTrue(state.needsRefresh(at: generatedAt, interval: 1))

        state.update(snapshot(at: 100, download: 0, upload: 0))

        XCTAssertFalse(state.needsRefresh(
            at: generatedAt.addingTimeInterval(0.999),
            interval: 1
        ))
        XCTAssertTrue(state.needsRefresh(
            at: generatedAt.addingTimeInterval(1),
            interval: 1
        ))
    }

    private func snapshot(
        at timestamp: TimeInterval,
        download: Int64,
        upload: Int64
    ) -> SystemMonitorSnapshot {
        SystemMonitorSnapshot(
            generatedAt: Date(timeIntervalSince1970: timestamp),
            metrics: [],
            networkThroughput: NetworkMonitorThroughput(
                downBytesPerSecond: download,
                upBytesPerSecond: upload
            )
        )
    }
}
