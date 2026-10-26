import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D105 (review C-R1, C-R2): the helper keeps each return to system control it
/// makes on its own with the result that return actually had, and the app
/// records each one once, when it next hears from the helper. Fake restore
/// results, temp folders and a fake helper only; nothing here writes to fans,
/// power settings or the user's data.
final class HardwareAutomaticRestoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = TestFileSystem.uniqueRoot("HardwareAutomaticRestore")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The return runs first and the result it actually had is what is kept;
    /// a return with no control to give back is not kept.
    func testTheHelperKeepsTheResultItsReturnActuallyHad() {
        for (hadControl, result) in [(true, true), (true, false), (false, true), (false, false)] {
            var events: [String] = []
            let returned = FanControlAutomaticRestore.perform(.fanLeaseExpired, hadControl: hadControl, restore: {
                events.append("restore")
                return result
            }, keep: { reason, restored in
                events.append("keep \(reason.rawValue) \(restored)")
            })
            XCTAssertEqual(returned, result)
            XCTAssertEqual(events, hadControl ? ["restore", "keep fanLeaseExpired \(result)"] : ["restore"],
                           "control \(hadControl), result \(result)")
        }
    }

    /// One entry per return with its result; a failed return retried for the
    /// same reason stays one entry until one completes; the newest 16 are kept
    /// and fit the size limit.
    func testTheListKeepsEachResultAndStaysBounded() throws {
        var log = FanControlAutomaticRestoreLog()
        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lease = log.record(.fanLeaseExpired, restored: true, at: date)
        let thermal = log.record(.thermalProtectionActivated, restored: false, at: date + 1)
        XCTAssertEqual(log.record(.thermalProtectionActivated, restored: false, at: date + 3), thermal,
                       "A retry of the same failed return")
        let leaseFailed = log.record(.fanLeaseExpired, restored: false, at: date + 5)
        let completed = log.record(.fanLeaseExpired, restored: true, at: date + 7)
        XCTAssertEqual(log.restores, [lease, thermal, leaseFailed, completed])
        XCTAssertEqual(log.restores.map(\.restored), [true, false, false, true])
        XCTAssertEqual(Set(log.restores.map(\.id)).count, 4)

        for index in 0..<40 {
            log.record(.appDisconnected, restored: index.isMultiple(of: 2), at: date + Double(10 + index))
        }
        XCTAssertEqual(FanControlAutomaticRestoreLog.retainedLimit, 16)
        XCTAssertEqual(log.restores.count, 16)
        XCTAssertEqual(log.restores.first?.occurredAt, date + 34)
        XCTAssertEqual(log.restores.last?.occurredAt, date + 49)
        let data = try log.encoded()
        XCTAssertLessThanOrEqual(data.count, FanControlAutomaticRestoreLog.maximumEncodedBytes)
        XCTAssertEqual(FanControlAutomaticRestoreLog.decoded(data), log)
    }

    /// Only a list the helper could have written is read back; a reason from a
    /// newer helper reads as "other".
    func testOnlyAListTheHelperCouldHaveWrittenIsRead() throws {
        XCTAssertNil(FanControlAutomaticRestoreLog.decoded(Data("not json".utf8)))
        XCTAssertNil(FanControlAutomaticRestoreLog.decoded(
            Data(count: FanControlAutomaticRestoreLog.maximumEncodedBytes + 1)))
        let entry = #"{"id":"\#(UUID().uuidString)","occurredAt":1,"reason":"fanLeaseExpired","restored":true}"#
        let seventeen = #"{"restores":[\#(Array(repeating: entry, count: 17).joined(separator: ","))]}"#
        XCTAssertNil(FanControlAutomaticRestoreLog.decoded(Data(seventeen.utf8)))
        let sixteen = #"{"restores":[\#(Array(repeating: entry, count: 16).joined(separator: ","))]}"#
        XCTAssertEqual(FanControlAutomaticRestoreLog.decoded(Data(sixteen.utf8))?.restores.count, 16)
        let newer = #"{"restores":[{"id":"\#(UUID().uuidString)","occurredAt":1,"reason":"fanReplaced","restored":false}]}"#
        XCTAssertEqual(FanControlAutomaticRestoreLog.decoded(Data(newer.utf8))?.restores.map(\.reason), [.other])
    }

    /// The helper's copy survives the helper starting again; a link or an
    /// oversized file in its place is not read, and a result that cannot be
    /// written is still reported from memory.
    func testTheHelpersCopySurvivesARestartAndRefusesAnythingElse() throws {
        let url = root.appendingPathComponent("helper.restores")
        let helper = FanControlAutomaticRestoreJournal(url: url)
        helper.record(.fanLeaseExpired, restored: true)
        helper.record(.startupRecovery, restored: false)
        XCTAssertEqual(helper.restores.map(\.restored), [true, false])
        XCTAssertEqual(FanControlAutomaticRestoreJournal(url: url).restores, helper.restores,
                       "A helper started again reports the same returns")

        let kept = try FanControlAutomaticRestoreLog(restores: helper.restores).encoded()
        let target = root.appendingPathComponent("elsewhere")
        try kept.write(to: target)
        let link = root.appendingPathComponent("linked.restores")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = FanControlAutomaticRestoreJournal(url: link)
        XCTAssertEqual(linked.restores, [], "A link in place of the file is not read")
        linked.record(.appDisconnected, restored: true)
        XCTAssertEqual(try Data(contentsOf: target), kept, "Nor written through")

        let oversized = root.appendingPathComponent("oversized.restores")
        try Data(count: FanControlAutomaticRestoreLog.maximumEncodedBytes + 1).write(to: oversized)
        XCTAssertEqual(FanControlAutomaticRestoreJournal(url: oversized).restores, [])

        let unwritable = FanControlAutomaticRestoreJournal(
            url: root.appendingPathComponent("missing/folder/helper.restores"))
        unwritable.record(.helperStopping, restored: false)
        XCTAssertEqual(unwritable.restores.map(\.reason), [.helperStopping])
        XCTAssertEqual(unwritable.restores.map(\.restored), [false])
    }

    /// A reason alone is unconfirmed. With the helper's report, the request
    /// keeps its own result and each reported return becomes its own record,
    /// with the helper's ID, time, reason and result.
    func testAReasonAloneIsUnconfirmedAndAReportedReturnKeepsItsResult() throws {
        for code in [FanControlHelperErrorCode.fanLeaseExpired, .curveLeaseExpired, .thermalProtectionActivated] {
            let unconfirmed = try XCTUnwrap(HardwareOperationRecord.make(
                for: .renewFanControlLease, reply: Self.reply(.renewFanControlLease, errorCode: code), at: Date()))
            XCTAssertEqual(unconfirmed.operation, .systemFanControl)
            XCTAssertEqual(unconfirmed.outcome, .automaticRestoreUnconfirmed)
            XCTAssertEqual(unconfirmed.errorCode, code.rawValue)
            XCTAssertNil(HardwareOperationRecord.make(
                for: .renewFanControlLease, reply: Self.reply(.renewFanControlLease, errorCode: code, restores: []),
                at: Date()), "The report says what was returned; a renewal itself is not recorded")
            XCTAssertEqual(FanControlAutomaticRestore.Reason(rawValue: code.rawValue)?.rawValue, code.rawValue)
        }
        let fan = FanControlHelperRequest(operation: .apply, targetRPMByFan: [0: 2_400], automaticFanIDs: [],
                                          allowsRPMDecrease: false, watchdogSeconds: 10, powerModeSource: nil,
                                          powerModeSetting: nil, powerModeValue: nil)
        let write = try XCTUnwrap(HardwareOperationRecord.make(
            for: fan, reply: Self.reply(.apply, errorCode: .thermalProtectionActivated, restores: []), at: Date()))
        XCTAssertEqual(write.operation, .fanSpeed)
        XCTAssertEqual(write.outcome, .failed)
        XCTAssertEqual(write.errorCode, "thermalProtectionActivated")

        let date = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let returned = FanControlAutomaticRestore(occurredAt: date, reason: .curveFailed, restored: true)
        let record = HardwareOperationRecord(automaticRestore: returned)
        XCTAssertEqual(record.id, returned.id)
        XCTAssertEqual(record.recordedAt, date)
        XCTAssertEqual(record.operation, .systemFanControl)
        XCTAssertEqual(record.outcome, .automaticRestore)
        XCTAssertEqual(record.automaticRestoreReason, .curveFailed)
        XCTAssertNil(record.errorCode)
        let failed = HardwareOperationRecord(automaticRestore: FanControlAutomaticRestore(
            occurredAt: date, reason: .startupRecovery, restored: false))
        XCTAssertEqual(failed.outcome, .automaticRestoreFailed)

        // Still nothing that names the computer.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(failed)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["id", "recordedAt", "operation", "outcome", "automaticRestoreReason"])
    }

    /// The report is never part of a power sample, which stays read-only.
    func testAPowerSampleNeverCarriesTheReport() {
        let sample = PowermetricsSample(cpuMilliwatts: 5_000, gpuMilliwatts: 2_000, aneMilliwatts: 0,
                                        clusters: [], gpuMegahertz: nil, durationSeconds: 1)
        let restore = FanControlAutomaticRestore(occurredAt: Date(timeIntervalSinceReferenceDate: 1),
                                                 reason: .fanLeaseExpired, restored: true)
        for restores in [[restore], []] {
            XCTAssertThrowsError(try FanControlHelperReply(
                operation: .samplePowerMetrics, success: true, message: "ok", appliedTargetRPMByFan: [:],
                powerSampleResult: .sample(sample), automaticRestores: restores).validated(for: .samplePowerMetrics))
        }
        XCTAssertNoThrow(try FanControlHelperReply(
            operation: .samplePowerMetrics, success: true, message: "ok", appliedTargetRPMByFan: [:],
            powerSampleResult: .sample(sample)).validated(for: .samplePowerMetrics))
        XCTAssertNoThrow(try FanControlHelperReply(
            operation: .ping, success: true, message: "ok", appliedTargetRPMByFan: [:],
            automaticRestores: [restore]).validated(for: .ping))
    }

    /// The same return reported again is one record.
    func testTheRecordKeepsAReportedReturnOnce() async throws {
        let history = HardwareOperationHistory(storageURL: root.appendingPathComponent("hardware-operations.json"))
        let restore = FanControlAutomaticRestore(occurredAt: Date(timeIntervalSinceReferenceDate: 9),
                                                 reason: .appDisconnected, restored: true)
        try await history.record(HardwareOperationRecord(automaticRestore: restore))
        try await history.record(HardwareOperationRecord(automaticRestore: restore))
        try await history.record(HardwareOperationRecord(automaticRestore: FanControlAutomaticRestore(
            occurredAt: Date(timeIntervalSinceReferenceDate: 9), reason: .appDisconnected, restored: true)))
        let records = try await history.load()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter { $0.id == restore.id }.count, 1)
    }

    /// Each result reads as what happened; only a completed return says the
    /// fans went back to the system.
    func testEachResultReadsAsWhatHappened() {
        let cases: [(HardwareOperationRecord.Outcome, FanControlAutomaticRestore.Reason?, String?, String)] = [
            (.automaticRestore, .appDisconnected, nil,
             L10n.text("App 断开连接，已自动交回系统", "App disconnected; returned to the system")),
            (.automaticRestore, .curveLeaseExpired, nil, L10n.text("租约到期，已自动交回系统", "Lease expired; returned to the system")),
            (.automaticRestoreFailed, .startupRecovery, nil,
             L10n.text("辅助程序重新启动，但未能交回系统控制", "Helper restarted; could not return control to the system")),
            (.automaticRestoreFailed, .thermalProtectionActivated, nil,
             L10n.text("过热保护，但未能交回系统控制", "Thermal protection; could not return control to the system")),
            (.automaticRestoreFailed, .fanVerificationFailed, nil,
             L10n.text("风扇状态无法核对，但未能交回系统控制", "Fan state could not be verified; could not return control to the system")),
            (.automaticRestoreUnconfirmed, nil, "curveLeaseExpired",
             L10n.text("租约到期，是否已交回系统未确认", "Lease expired; return to the system unconfirmed")),
            (.automaticRestoreUnconfirmed, nil, "thermalProtectionActivated",
             L10n.text("过热保护，是否已交回系统未确认", "Thermal protection; return to the system unconfirmed")),
        ]
        for (outcome, reason, code, text) in cases {
            let record = HardwareOperationRecord(recordedAt: Date(), operation: .systemFanControl, outcome: outcome,
                                                 errorCode: code, automaticRestoreReason: reason)
            XCTAssertEqual(HardwareOperationPresentation.outcome(record), text)
            XCTAssertNil(HardwareOperationPresentation.detail(record))
            if outcome != .automaticRestore {
                XCTAssertFalse(text.contains("已自动交回系统") || text.contains("returned to the system"), text)
            }
        }
        XCTAssertEqual(HardwareOperationPresentation.title(HardwareOperationRecord(
            recordedAt: Date(), operation: .systemFanControl, outcome: .automaticRestoreFailed)),
            L10n.text("风扇交回系统控制", "Return fans to system control"))
    }

    /// End to end with a fake helper: the returns it reports when the app
    /// connects are recorded once each with the result the helper reported;
    /// connecting again, or another run of the app, adds nothing; a later
    /// return is added once.
    @MainActor
    func testTheAppRecordsTheHelpersOwnReturnsOnceWhenItConnects() async throws {
        let history = HardwareOperationHistory(storageURL: root.appendingPathComponent("hardware-operations.json"))
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lease = FanControlAutomaticRestore(occurredAt: base, reason: .fanLeaseExpired, restored: true)
        let thermal = FanControlAutomaticRestore(occurredAt: base + 60, reason: .thermalProtectionActivated, restored: false)
        let journal = R2TestValue([lease, thermal])
        let pings = R2TestValue(0)
        func coordinator() -> FanControlCoordinator {
            FanControlCoordinator(
                defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled, isHelperReachable: true,
                now: { base + 600 },
                requestSender: TestOperationFactory(for: self).fanRequestSender(
                    handling: [.ping, .readPowerConfiguration]) { request in
                    if request.operation == .ping { pings.value += 1 }
                    return FanControlHelperReply(operation: request.operation, success: true, message: "fake",
                                                 appliedTargetRPMByFan: [:],
                                                 automaticRestores: request.operation == .ping ? journal.value : nil)
                },
                reconnectSleeper: { _ in throw CancellationError() },
                legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
                legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { throw CancellationError() },
                serviceStatusProvider: { .enabled }, serviceRegistrar: { throw CancellationError() },
                serviceUnregistrar: { throw CancellationError() }, approvalSettingsOpener: {},
                operationHistory: history)
        }

        let first = coordinator()
        await first.connectHelper()
        var records = try await Self.records(in: history, count: 2)
        XCTAssertEqual(records.map(\.id), [thermal.id, lease.id], "Newest first, by the helper's own times")
        XCTAssertEqual(records.map(\.outcome), [.automaticRestoreFailed, .automaticRestore])
        XCTAssertEqual(records.map(\.automaticRestoreReason), [.thermalProtectionActivated, .fanLeaseExpired])
        XCTAssertEqual(records.map(\.recordedAt), [base + 60, base])

        await first.connectHelper()
        let again = coordinator()
        await again.connectHelper()
        XCTAssertEqual(pings.value, 3, "Each connection reached the helper and was told the same returns")
        records = try await Self.settledRecords(in: history, count: 2)
        XCTAssertEqual(records.map(\.id), [thermal.id, lease.id])

        let disconnected = FanControlAutomaticRestore(occurredAt: base + 120, reason: .appDisconnected, restored: true)
        journal.value.append(disconnected)
        await again.connectHelper()
        records = try await Self.settledRecords(in: history, count: 3)
        XCTAssertEqual(records.map(\.id), [disconnected.id, thermal.id, lease.id])
        XCTAssertEqual(records.map(\.outcome), [.automaticRestore, .automaticRestoreFailed, .automaticRestore])
    }

    /// Review D105-R1: a return counts as recorded only once its save
    /// succeeded. While the record cannot be saved, connecting still
    /// completes and the returns the helper reports are not marked; once it
    /// can, the same coordinator records the return the next time the helper
    /// reports it, once. A new return is recorded too, and reporting both
    /// again adds nothing.
    @MainActor
    func testAReturnWhoseSaveFailedIsRecordedWhenTheHelperReportsItAgain() async throws {
        // A file where the record's folder belongs, in this test's own
        // temporary folder: reading and saving the record fail until it goes.
        let folder = root.appendingPathComponent("History")
        try Data("not a folder".utf8).write(to: folder)
        let history = HardwareOperationHistory(storageURL: folder.appendingPathComponent("hardware-operations.json"))
        let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let lease = FanControlAutomaticRestore(occurredAt: base, reason: .fanLeaseExpired, restored: true)
        let journal = R2TestValue([lease])
        let pings = R2TestValue(0)
        let coordinator = FanControlCoordinator(
            defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled, isHelperReachable: true,
            now: { base + 600 },
            requestSender: TestOperationFactory(for: self).fanRequestSender(
                handling: [.ping, .readPowerConfiguration]) { request in
                if request.operation == .ping { pings.value += 1 }
                return FanControlHelperReply(operation: request.operation, success: true, message: "fake",
                                             appliedTargetRPMByFan: [:],
                                             automaticRestores: request.operation == .ping ? journal.value : nil)
            },
            reconnectSleeper: { _ in throw CancellationError() },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { throw CancellationError() },
            serviceStatusProvider: { .enabled }, serviceRegistrar: { throw CancellationError() },
            serviceUnregistrar: { throw CancellationError() }, approvalSettingsOpener: {},
            operationHistory: history)

        await coordinator.connectHelper()
        await coordinator.connectHelper()
        // The record serves calls in turn: once these reads have failed, the
        // saves sent before them have failed too, and the coordinator has
        // heard so before the test goes on.
        for _ in 0..<3 {
            await Task.yield()
            do {
                _ = try await history.load()
                XCTFail("The record cannot be read while a file holds its folder's place")
            } catch {}
        }
        XCTAssertEqual(pings.value, 2)
        try FileManager.default.removeItem(at: folder)

        await coordinator.connectHelper()
        var records = try await Self.records(in: history, count: 1)
        XCTAssertEqual(records.map(\.id), [lease.id], "Reported again, the return is recorded")
        XCTAssertEqual(records.map(\.outcome), [.automaticRestore])
        XCTAssertEqual(records.map(\.recordedAt), [base])

        let thermal = FanControlAutomaticRestore(occurredAt: base + 60, reason: .thermalProtectionActivated,
                                                 restored: false)
        journal.value.append(thermal)
        await coordinator.connectHelper()
        _ = try await Self.records(in: history, count: 2)
        await coordinator.connectHelper()
        await coordinator.connectHelper()
        XCTAssertEqual(pings.value, 6)
        records = try await Self.settledRecords(in: history, count: 2)
        XCTAssertEqual(records.map(\.id), [thermal.id, lease.id])
        XCTAssertEqual(records.map(\.outcome), [.automaticRestoreFailed, .automaticRestore])
    }

    /// A failed startup recovery the helper reports is recorded once, from
    /// the report, and not a second time by the app's own fault latch.
    @MainActor
    func testAStartupFailureTheHelperReportsIsRecordedOnce() async throws {
        let history = HardwareOperationHistory(storageURL: root.appendingPathComponent("hardware-operations.json"))
        let startup = FanControlAutomaticRestore(occurredAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                                                 reason: .startupRecovery, restored: false)
        let reads = R2TestValue(0)
        let coordinator = FanControlCoordinator(
            defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: TestOperationFactory(for: self).fanRequestSender(handling: [.readMacMiniMode]) { request in
                reads.value += 1
                return FanControlHelperReply(operation: request.operation, success: false, message: "raw",
                                             appliedTargetRPMByFan: [:], errorCode: .fanCrashRecoveryFailed,
                                             automaticRestores: [startup])
            },
            reconnectSleeper: { _ in throw CancellationError() },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }, operationHistory: history)
        await coordinator.refreshMacMiniMode()
        await coordinator.refreshMacMiniMode()
        await coordinator.refreshMacMiniMode()
        XCTAssertEqual(reads.value, 3)
        let records = try await Self.settledRecords(in: history, count: 1)
        XCTAssertEqual(records.first?.id, startup.id)
        XCTAssertEqual(records.first?.outcome, .automaticRestoreFailed)
        XCTAssertEqual(records.first?.automaticRestoreReason, .startupRecovery)
        XCTAssertFalse(records.contains { $0.errorCode == FanControlHelperErrorCode.fanCrashRecoveryFailed.rawValue })
    }

    /// The helper keeps the list in root's /var/run, never a user's folder;
    /// every return it makes on its own goes through the kept return, which
    /// hands the fans back before anything is kept and waits on nothing from
    /// the app; startup keeps its recovery's own result; and the list rides on
    /// a ping and on every reply that did not succeed, never on a power sample.
    func testTheHelperKeepsEveryReturnItMakesOnItsOwn() throws {
        let text = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/FanControlHelper/main.swift"), encoding: .utf8)
        let shared = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/FanControlShared/FanControlAutomaticRestore.swift"), encoding: .utf8)
        XCTAssertTrue(SwiftSourceScanning.compactKeepingLiterals(text).contains(
            #"FanControlAutomaticRestoreJournal(url:URL(fileURLWithPath:"/var/run/\(StorageCleanerBuildIdentity.helperLabel).restores"))"#))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "FanControlAutomaticRestoreJournal(", in: text), 1)
        for forbidden in ["homeDirectory", "NSHomeDirectory", "FileManager.default.urls(", "applicationSupportDirectory",
                          "\"~", "/Users/"] {
            XCTAssertFalse(shared.contains(forbidden), forbidden)
        }

        let lexed = SwiftSourceScanning.code(text)
        let code = SwiftSourceScanning.compact(lexed)
        for site in ["restoreAutomatically(.appDisconnected)", "restoreAutomatically(.helperStopping)",
                     "restoreAutomatically(.fanLeaseExpired)", "restoreAutomatically(.fanVerificationFailed)",
                     "restoreAutomatically(Self.automaticRestoreReason(for:error))"] {
            XCTAssertEqual(SwiftSourceScanning.occurrences(of: site, in: code), 1, site)
        }
        XCTAssertTrue(code.contains("letrestoreCompleted=restoreAllFans(using:controller)"
            + "automaticRestores.record(.fanVerificationFailed,restored:restoreCompleted)"))
        let restore = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "private func restoreAutomatically(", in: lexed))
        XCTAssertTrue(restore.contains("FanControlAutomaticRestore.perform(reason,hadControl:!forcedFanIDs.isEmpty"
            + "||FileManager.default.fileExists(atPath:Self.controlRecoveryMarkerURL.path),restore:{restoreAllFans()},"
            + "keep:{automaticRestores.record($0,restored:$1)})"), restore)
        for waiting in ["connections", "reply", "await", "wait(", "Semaphore", "sync"] {
            XCTAssertFalse(restore.contains(waiting), waiting)
        }

        let run = SwiftSourceScanning.compact(try SwiftSourceScanning.body(of: "func run() {", in: lexed))
        let ordered = ["letrecoversPreviousControl=FileManager.default.fileExists(atPath:Self.controlRecoveryMarkerURL.path)",
                       "letstartupState=startupSafety.start(recoverFans:{smcQueue.sync{recoverPreviousControlIfNeeded()}}",
                       "ifrecoversPreviousControl{automaticRestores.record(.startupRecovery,restored:startupState==.ready)}"]
        let offsets = try ordered.map { try XCTUnwrap(run.range(of: $0), $0).lowerBound }
        XCTAssertEqual(offsets, offsets.sorted())

        XCTAssertTrue(code.contains("reply(Self.encoded(reportingAutomaticRestores(handle(request))))"))
        let reporting = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "private func reportingAutomaticRestores(", in: lexed))
        XCTAssertEqual(reporting, "guardreply.operation!=.samplePowerMetrics,reply.operation==.ping||!reply.successelse{"
            + "returnreply}returnreply.reporting(automaticRestores.restores)")
    }

    private static func reply(_ operation: FanControlHelperRequest.Operation, errorCode: FanControlHelperErrorCode,
                              restores: [FanControlAutomaticRestore]? = nil) -> FanControlHelperReply {
        FanControlHelperReply(operation: operation, success: false, message: "", appliedTargetRPMByFan: [:],
                              errorCode: errorCode, automaticRestores: restores)
    }

    private static func records(in history: HardwareOperationHistory, count: Int) async throws -> [HardwareOperationRecord] {
        var records: [HardwareOperationRecord] = []
        for _ in 0..<500 {
            records = try await history.load()
            if records.count >= count { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(records.count, count)
        return records
    }

    /// `count` records, and still `count` after any record still on its way
    /// has had time to arrive.
    private static func settledRecords(in history: HardwareOperationHistory,
                                       count: Int) async throws -> [HardwareOperationRecord] {
        _ = try await records(in: history, count: count)
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(10)) }
        let records = try await history.load()
        XCTAssertEqual(records.count, count)
        return records
    }
}
