import XCTest
@testable import StorageCleanerMac

@MainActor
final class FileOperationReadRetryTests: XCTestCase {
    func testReadExchangesUseANewConnectionAfterOneTransportFailure() async throws {
        for operation in ["applicationReplacementCapabilities", "systemCacheInventory", "backgroundTaskInventory"] {
            var connectionIDs: [Int] = []
            var waits = 0
            let result = try await FileOperationReadRetry.perform(wait: { waits += 1 }) {
                let freshConnection = connectionIDs.count + 1
                connectionIDs.append(freshConnection)
                if freshConnection == 1 { throw FileOperationReadRetry.TransportFailure.noReply }
                return operation + " result"
            }
            XCTAssertEqual(result, operation + " result")
            XCTAssertEqual(connectionIDs, [1, 2])
            XCTAssertEqual(waits, 1)
        }
    }

    func testProtectedUpdateProbeAlsoRetriesConnectionLost() async throws {
        var calls = 0
        let result = try await FileOperationReadRetry.perform(wait: {}) {
            calls += 1
            if calls == 1 { throw AuthorizedMoveError.connectionLost }
            return 42
        }
        XCTAssertEqual(result, 42)
        XCTAssertEqual(calls, 2)
    }

    func testSecondTransportFailureIsReturnedWithoutFurtherRetry() async {
        var calls = 0
        var waits = 0
        do {
            let _: Int = try await FileOperationReadRetry.perform(wait: { waits += 1 }) {
                calls += 1
                throw FileOperationReadRetry.TransportFailure.noReply
            }
            XCTFail("both reads failed")
        } catch { XCTAssertTrue(error is FileOperationReadRetry.TransportFailure) }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(waits, 1)
    }

    func testMutatingExchangesNeverReplayAnUnknownOutcome() async {
        for operation in ["prepare", "commit", "prepareSystemCacheClear", "commitSystemCacheClear",
                          "prepareApplicationReplacements", "replaceAuthenticatedApplication", "finishApplicationReplacements"] {
            var calls = 0
            var waits = 0
            do {
                let _: Int = try await FileOperationReadRetry.perform(readOnly: false, wait: { waits += 1 }) {
                    calls += 1
                    throw FileOperationReadRetry.TransportFailure.noReply
                }
                XCTFail(operation)
            } catch { XCTAssertTrue(error is FileOperationReadRetry.TransportFailure) }
            XCTAssertEqual(calls, 1, operation)
            XCTAssertEqual(waits, 0, operation)
        }
    }

    func testAReplyErrorAndCancellationDoNotRetry() async {
        for error in [SystemCacheServiceError.unavailable as any Error, CancellationError()] {
            var calls = 0
            var waits = 0
            do {
                let _: Int = try await FileOperationReadRetry.perform(wait: { waits += 1 }) {
                    calls += 1
                    throw error
                }
                XCTFail("a reply error is final")
            } catch { }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(waits, 0)
        }
    }

    func testCancellationDuringRetryDelaySendsNoSecondRequest() async {
        var calls = 0
        do {
            let _: Int = try await FileOperationReadRetry.perform(wait: { throw CancellationError() }) {
                calls += 1
                throw FileOperationReadRetry.TransportFailure.noReply
            }
            XCTFail("cancelled")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls, 1)
    }

    func testOnlyReadEntryPointsWrapTheExchangeAndKeepExistingTimeouts() throws {
        func source(_ name: String) throws -> String {
            try String(contentsOf: SwiftSourceScanning.projectRoot
                .appendingPathComponent("Sources/StorageCleanerMac/Services/" + name + ".swift"), encoding: .utf8)
        }
        let cache = try source("SystemCacheService")
        let cacheClass = try r2SourceDeclaration("final class SystemCacheService:", in: cache)
        let inventory = try r2SourceDeclaration("func inventory() async -> SystemCacheInventoryReply?", in: cacheClass)
        XCTAssertTrue(inventory.contains("FileOperationReadRetry.perform"))
        XCTAssertTrue(inventory.contains("let connection = try self.connect()"))
        XCTAssertTrue(inventory.contains("timeout: 35"))
        let clear = try r2SourceDeclaration("func clear(", in: cacheClass)
        XCTAssertFalse(clear.contains("FileOperationReadRetry.perform"))
        let probe = try r2SourceDeclaration("private func verifiedConnection()", in: cacheClass)
        XCTAssertTrue(probe.contains("FileOperationReadRetry.perform"))
        XCTAssertTrue(probe.contains("self.checkBuild(connection)"))
        XCTAssertFalse(probe.contains("prepareSystemCacheClear"))
        XCTAssertLessThan(try XCTUnwrap(clear.range(of: "verifiedConnection()")).lowerBound,
                          try XCTUnwrap(clear.range(of: "prepareSystemCacheClear?")).lowerBound)
        let background = try source("HelperBackgroundTaskInventory")
        XCTAssertTrue(try r2SourceDeclaration("func dump(", in: background).contains("FileOperationReadRetry.perform"))
        XCTAssertTrue(background.contains("timeout: 2"))
        let update = try source("AppUpdateProtectedApplicationAuthorization")
        let capabilities = try r2SourceDeclaration("private func capabilities()", in: update)
        XCTAssertTrue(capabilities.contains("FileOperationReadRetry.perform"))
        XCTAssertTrue(capabilities.contains("self.openConnection()"))
        XCTAssertTrue(capabilities.contains("timeout: 2"))
        for method in ["func prepare(", "func replace(", "func finish()"] {
            XCTAssertFalse(try r2SourceDeclaration(method, in: update).contains("FileOperationReadRetry"))
        }
        XCTAssertFalse(try source("AuthorizedApplicationMover").contains("FileOperationReadRetry"))
    }
}
