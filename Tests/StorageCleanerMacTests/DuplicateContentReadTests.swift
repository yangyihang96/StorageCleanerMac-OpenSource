import XCTest
@testable import StorageCleanerMac

final class DuplicateContentReadTests: XCTestCase {
    func testScanControlCancelsBlockedFingerprintAndHashThenResumesFromCheckpoint() async throws {
        for blocksHash in [false, true] {
            let fixture = try ContentReadFixture()
            defer { fixture.remove() }
            try fixture.contents.write(to: fixture.root.appendingPathComponent("second.bin"))
            let gate = ContentReadGate()
            defer { gate.release() }
            let control = DuplicateFileScanControl()
            let hashing = FileContentReadPool.Control()
            let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1), timeout: 10,
                willRead: { _ in if !blocksHash || hashing.isCancelled { gate.block() } })
            let configuration = DuplicateFileScanner.Configuration(roots: [fixture.root.path], excludedPaths: [],
                maxScanSeconds: 10, candidateRules: [])
            let resumeStore = DuplicateFileResumeIndexStore(fileURL: fixture.root.appendingPathComponent(".resume-index.json"))
            let persist: DuplicateFileScanner.ResumeIndexHandler = { data in
                do {
                    if let data { try resumeStore.save(data) }
                    else { try resumeStore.clear() }
                } catch { XCTFail("Could not persist the isolated resume index: \(error)") }
            }
            let worker = Task.detached {
                DuplicateFileScanner.scanReport(configuration: configuration, resumeIndexData: nil,
                    control: control, resumeIndex: persist,
                    progress: { if $0.phase == .hashing { hashing.cancel() } }, contentReader: reader)
            }
            await fulfillment(of: [gate.entered], timeout: 1)
            let start = ProcessInfo.processInfo.systemUptime
            control.cancel()
            let cancelled = await worker.value
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            XCTAssertEqual(cancelled.outcome, .cancelled)
            XCTAssertFalse(cancelled.coverage.reachedTimeLimit)
            XCTAssertTrue(cancelled.exactGroups.isEmpty)
            XCTAssertEqual(cancelled.progress.scannedFiles, 2)
            XCTAssertFalse(gate.didReturn, "Scan control must cancel the wait without waiting for the blocked read")

            let savedIndex = try XCTUnwrap(resumeStore.load())
            let probe = ContentReadProbe()
            let resumedReader = GuardedFileContentReader(willRead: { _ in probe.recordRead() })
            let resumed = await Task.detached {
                DuplicateFileScanner.scanReport(configuration: configuration, resumeIndexData: savedIndex,
                    resumeIndex: persist, contentReader: resumedReader)
            }.value
            XCTAssertEqual(resumed.outcome, .complete)
            XCTAssertEqual(resumed.progress.scannedDirectories, 1)
            XCTAssertEqual(resumed.progress.scannedFiles, 2)
            XCTAssertEqual(resumed.progress.hashedFiles, 2)
            XCTAssertEqual(resumed.exactGroups.count, 1)
            XCTAssertEqual(try XCTUnwrap(resumed.exactGroups.first).files.count, 2)
            XCTAssertGreaterThan(probe.reads, 0, "Resumed confirmation must use the injected reader too")
            XCTAssertNil(resumeStore.load(), "Successful confirmation clears the persisted checkpoint")
        }
    }

    func testQuickFingerprintAndHashTimeoutRemainPartial() async throws {
        for blocksHash in [false, true] {
            let fixture = try ContentReadFixture()
            defer { fixture.remove() }
            try fixture.contents.write(to: fixture.root.appendingPathComponent("second.bin"))
            let gate = ContentReadGate()
            defer { gate.release() }
            let hashing = FileContentReadPool.Control()
            let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1), timeout: 0.1,
                willRead: { _ in if !blocksHash || hashing.isCancelled { gate.block() } })
            let configuration = DuplicateFileScanner.Configuration(roots: [fixture.root.path], excludedPaths: [],
                maxScanSeconds: 10, candidateRules: [])
            let worker = Task.detached {
                DuplicateFileScanner.scanReport(configuration: configuration, resumeIndexData: nil,
                    progress: { if $0.phase == .hashing { hashing.cancel() } }, contentReader: reader)
            }
            await fulfillment(of: [gate.entered], timeout: 1)
            let start = ProcessInfo.processInfo.systemUptime
            let report = await worker.value
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            XCTAssertTrue(report.coverage.reachedTimeLimit)
            XCTAssertEqual(report.coverage.contentReadUnresponsive, true)
            XCTAssertTrue(report.exactGroups.isEmpty)
            XCTAssertFalse(gate.didReturn)
        }
    }

    func testImageSignatureTimeoutIsPartialAndCancellationUsesScanControl() async throws {
        for cancels in [false, true] {
            let fixture = try ContentReadFixture()
            defer { fixture.remove() }
            // Different lengths avoid exact matching; the read stand-in stops
            // ImageIO before these deliberately fake image bytes are decoded.
            try Data([1]).write(to: fixture.root.appendingPathComponent("a.png"))
            try Data([2, 3]).write(to: fixture.root.appendingPathComponent("b.png"))
            let gate = ContentReadGate()
            defer { gate.release() }
            let control = DuplicateFileScanControl()
            let reader = GuardedFileContentReader(pool: FileContentReadPool(maximumReaders: 1),
                timeout: cancels ? 10 : 0.1, willRead: { _ in gate.block() })
            let configuration = DuplicateFileScanner.Configuration(roots: [fixture.root.path], excludedPaths: [],
                maxScanSeconds: 10, candidateRules: [.similarImage])
            let worker = Task.detached {
                DuplicateFileScanner.scanReport(configuration: configuration, resumeIndexData: nil,
                    control: control, contentReader: reader)
            }
            await fulfillment(of: [gate.entered], timeout: 1)
            if cancels { control.cancel() }
            let start = ProcessInfo.processInfo.systemUptime
            let report = await worker.value
            XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
            XCTAssertTrue(report.candidates.isEmpty)
            if cancels { XCTAssertEqual(report.outcome, .cancelled) }
            else {
                XCTAssertTrue(report.coverage.reachedTimeLimit)
                XCTAssertEqual(report.coverage.contentReadUnresponsive, true)
            }
            XCTAssertFalse(gate.didReturn)
        }
    }
}
