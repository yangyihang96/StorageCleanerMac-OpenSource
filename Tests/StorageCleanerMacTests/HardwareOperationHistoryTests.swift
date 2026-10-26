import FanControlShared
import Foundation
import ServiceManagement
import XCTest
@testable import StorageCleanerMac

/// D102 L4: hardware writes and automatic restores go to a bounded local
/// record that holds no machine identifiers. Temp folders and a fake helper
/// only; nothing here writes to fans, power settings or the user's data.
final class HardwareOperationHistoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = TestFileSystem.uniqueRoot("HardwareOperationHistory")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// A reply makes a success or a failure, no reply an unconfirmed record,
    /// each from the request's own values; a reply that only gives the reason
    /// the helper returns the fans to the system makes an automatic restore
    /// whose result is unconfirmed (D105, review C-R1: until then this test
    /// expected `.automaticRestore`, a success the reply does not show). Reads
    /// and lease renewals make none.
    func testWritesAndAutomaticRestoresMakeRecordsAndReadsDoNot() throws {
        let fan = FanControlHelperRequest(operation: .apply, targetRPMByFan: [0: 2_400, 1: 2_600], automaticFanIDs: [2],
                                          allowsRPMDecrease: false, watchdogSeconds: 10, powerModeSource: nil,
                                          powerModeSetting: nil, powerModeValue: nil)
        let success = try XCTUnwrap(HardwareOperationRecord.make(
            for: fan, reply: Self.reply(.apply, success: true), at: Date(timeIntervalSinceReferenceDate: 1)))
        XCTAssertEqual(success.operation, .fanSpeed)
        XCTAssertEqual(success.outcome, .succeeded)
        XCTAssertEqual(success.targetRPMByFan, [0: 2_400, 1: 2_600])
        XCTAssertEqual(success.automaticFanIDs, [2])
        XCTAssertNil(success.errorCode)
        XCTAssertEqual(success.recordedAt, Date(timeIntervalSinceReferenceDate: 1))

        let failure = try XCTUnwrap(HardwareOperationRecord.make(
            for: fan, reply: Self.reply(.apply, success: false, errorCode: .smcWriteFailed), at: Date()))
        XCTAssertEqual(failure.outcome, .failed)
        XCTAssertEqual(failure.errorCode, "smcWriteFailed")
        XCTAssertEqual(HardwareOperationRecord.make(for: fan, reply: nil, at: Date())?.outcome, .unconfirmed)

        let command = try XCTUnwrap(BatteryPowerModeWriteCommand.make(source: .batteryPower, mode: .lowPower))
        let power = try XCTUnwrap(HardwareOperationRecord.make(
            for: try XCTUnwrap(FanControlHelperRequest.applyPowerMode(command)),
            reply: Self.reply(.applyPowerMode, success: true), at: Date()))
        XCTAssertEqual(power.operation, .powerMode)
        XCTAssertEqual([power.powerSource, power.powerSetting], ["-b", "powermode"])
        XCTAssertEqual(power.powerValue, 1)
        XCTAssertNil(power.targetRPMByFan)

        for code in [FanControlHelperErrorCode.fanLeaseExpired, .curveLeaseExpired, .thermalProtectionActivated] {
            let restored = try XCTUnwrap(HardwareOperationRecord.make(
                for: .renewFanControlLease, reply: Self.reply(.renewFanControlLease, success: false, errorCode: code),
                at: Date()), code.rawValue)
            XCTAssertEqual(restored.operation, .systemFanControl)
            XCTAssertEqual(restored.outcome, .automaticRestoreUnconfirmed)
            XCTAssertEqual(restored.errorCode, code.rawValue)
        }

        XCTAssertNil(HardwareOperationRecord.make(
            for: .renewFanControlLease, reply: Self.reply(.renewFanControlLease, success: true), at: Date()))
        XCTAssertNil(HardwareOperationRecord.make(for: .renewFanControlLease, reply: nil, at: Date()))
        XCTAssertNil(HardwareOperationRecord.make(for: .ping, reply: Self.reply(.ping, success: true), at: Date()))
        XCTAssertNil(HardwareOperationRecord.make(
            for: .ping, reply: Self.reply(.ping, success: false, errorCode: .fanCrashRecoveryFailed), at: Date()),
            "The coordinator records a failed startup recovery once, when it latches")
        XCTAssertNil(HardwareOperationRecord.make(
            for: .readPowerConfiguration, reply: Self.reply(.readPowerConfiguration, success: false), at: Date()))
        XCTAssertNil(HardwareOperationRecord.make(for: .readMacMiniMode, reply: nil, at: Date()))
        XCTAssertNil(HardwareOperationRecord.make(for: .samplePowerMetrics, reply: nil, at: Date()))
    }

    /// End to end through the coordinator with a fake helper: the Mac mini
    /// mode write that succeeds, the one the helper refuses and the one that
    /// gets no reply each leave a record, newest first; the pings before them
    /// leave none.
    @MainActor
    func testTheCoordinatorRecordsItsWrites() async throws {
        let history = HardwareOperationHistory(storageURL: root.appendingPathComponent("hardware-operations.json"))
        let clock = R2TestValue(Date(timeIntervalSinceReferenceDate: 800_000_000))
        let answer = R2TestValue(0)
        let on = MacMiniModeStatus(state: MacMiniPersistedState(mode: .whenOnAC, ownsSleepDisabled: true),
            readings: MacMiniSystemReadings(powerSource: .ac, sleepDisabled: true, clamshellClosed: false,
                                            clamshellCausesSleep: true), failure: nil)
        let coordinator = FanControlCoordinator(
            defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled, isHelperReachable: true,
            now: { clock.value },
            requestSender: TestOperationFactory(for: self).fanRequestSender(handling: [.ping, .setMacMiniMode]) { request in
                guard request.operation == .setMacMiniMode else {
                    return FanControlHelperReply(operation: request.operation, success: true, message: "fake",
                                                 appliedTargetRPMByFan: [:])
                }
                switch answer.value {
                case 0:
                    return FanControlHelperReply(operation: request.operation, success: true, message: "fake",
                                                 appliedTargetRPMByFan: [:], macMiniModeStatus: on)
                case 1:
                    return FanControlHelperReply(operation: request.operation, success: false, message: "raw conflict",
                                                 appliedTargetRPMByFan: [:], errorCode: .macMiniModeConflict)
                default:
                    throw CocoaError(.xpcConnectionInterrupted)
                }
            },
            reconnectSleeper: { _ in throw CancellationError() },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            legacyArtifactsSafeForRemovalProvider: { false }, legacyUninstaller: { throw CancellationError() },
            serviceStatusProvider: { .enabled }, serviceRegistrar: { throw CancellationError() },
            serviceUnregistrar: { throw CancellationError() }, approvalSettingsOpener: {},
            operationHistory: history)
        for attempt in 0..<3 {
            answer.value = attempt
            clock.value = Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(attempt) * 60)
            await coordinator.setMacMiniMode(.whenOnAC)
        }

        let records = try await Self.records(in: history, count: 3)
        XCTAssertEqual(records.map(\.operation), [.macMiniMode, .macMiniMode, .macMiniMode])
        XCTAssertEqual(records.map(\.outcome), [.unconfirmed, .failed, .succeeded], "Newest first")
        XCTAssertEqual(records.map(\.macMiniMode), [.whenOnAC, .whenOnAC, .whenOnAC])
        XCTAssertEqual(records.map(\.errorCode), [nil, "macMiniModeConflict", nil])
        XCTAssertEqual(records.map(\.recordedAt), [120, 60, 0].map { Date(timeIntervalSinceReferenceDate: 800_000_000 + $0) })
    }

    /// The helper's failed startup recovery is recorded once, when the app
    /// first learns of it, not on every later reply that repeats it.
    @MainActor
    func testAFailedStartupRecoveryIsRecordedOnce() async throws {
        let history = HardwareOperationHistory(storageURL: root.appendingPathComponent("hardware-operations.json"))
        var reads = 0
        let coordinator = FanControlCoordinator(
            defaults: TestPreferenceDomain.make(for: self), helperStatusOverride: .enabled, isHelperReachable: true,
            requestSender: TestOperationFactory(for: self).fanRequestSender(handling: [.readMacMiniMode]) { request in
                reads += 1
                return FanControlHelperReply(operation: request.operation, success: false, message: "raw",
                                             appliedTargetRPMByFan: [:], errorCode: .fanCrashRecoveryFailed)
            },
            reconnectSleeper: { _ in throw CancellationError() },
            legacyArtifactsPresentProvider: { false }, legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }, operationHistory: history)
        await coordinator.refreshMacMiniMode()
        let first = try await Self.records(in: history, count: 1)
        await coordinator.refreshMacMiniMode()
        await coordinator.refreshMacMiniMode()
        // Each refresh reached the helper and got the same reply; give any
        // record those later replies made time to arrive.
        XCTAssertEqual(reads, 3)
        var after = first
        for _ in 0..<50 where after.count == first.count {
            try await Task.sleep(for: .milliseconds(10))
            after = try await history.load()
        }

        XCTAssertEqual(after, first)
        XCTAssertEqual(first.first?.operation, .systemFanControl)
        XCTAssertEqual(first.first?.outcome, .failed)
        XCTAssertEqual(first.first?.errorCode, "fanCrashRecoveryFailed")
    }

    /// Only these fields are written. Text from the helper (which could name
    /// the machine) never reaches the record.
    func testRecordsHoldNoMachineIdentifiers() throws {
        let identifying = "Mac mini (C02XK0ABCDEF) IOPlatformUUID 12345678-90AB-CDEF-1234-567890ABCDEF"
        let command = try XCTUnwrap(BatteryPowerModeWriteCommand.make(source: .acPower, mode: .highPower))
        let record = try XCTUnwrap(HardwareOperationRecord.make(
            for: try XCTUnwrap(FanControlHelperRequest.applyPowerMode(command)),
            reply: Self.reply(.applyPowerMode, success: false, message: identifying, errorCode: .pmsetFailed),
            at: Date(timeIntervalSinceReferenceDate: 4)))
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue(Set(object.keys).isSubset(of: [
            "id", "recordedAt", "operation", "outcome", "targetRPMByFan", "automaticFanIDs",
            "powerSetting", "powerValue", "powerSource", "macMiniMode", "errorCode",
        ]), "\(object.keys.sorted())")
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for fragment in ["C02XK0ABCDEF", "IOPlatformUUID", "12345678-90AB", "Mac mini", "raw"] {
            XCTAssertFalse(text.contains(fragment), fragment)
        }
        XCTAssertEqual([record.powerSource, record.powerSetting], ["-c", "powermode"])
        XCTAssertEqual(record.powerValue, 2)
        XCTAssertEqual(record.errorCode, "pmsetFailed")
    }

    /// At most 200 records and 128 KiB; the oldest go first, and a record
    /// that arrives late still sorts by its time.
    func testTheRecordIsBoundedByCountAndBytes() async throws {
        XCTAssertEqual(HardwareOperationHistory.maximumRecordCount, 200)
        XCTAssertEqual(HardwareOperationHistory.maximumStorageBytes, 131_072)
        let url = root.appendingPathComponent("hardware-operations.json")
        let history = HardwareOperationHistory(storageURL: url)
        for index in 0..<230 {
            try await history.record(HardwareOperationRecord(
                recordedAt: Date(timeIntervalSinceReferenceDate: Double(index)), operation: .fanSpeed,
                outcome: .succeeded, targetRPMByFan: [0: 1_000 + index]))
        }
        var loaded = try await history.load()
        XCTAssertEqual(loaded.count, 200)
        XCTAssertEqual(loaded.first?.targetRPMByFan, [0: 1_229])
        XCTAssertEqual(loaded.last?.targetRPMByFan, [0: 1_030])
        XCTAssertLessThanOrEqual(try fileSize(url), HardwareOperationHistory.maximumStorageBytes)

        try await history.record(HardwareOperationRecord(
            recordedAt: Date(timeIntervalSinceReferenceDate: 100.5), operation: .fanCurveOff, outcome: .succeeded))
        loaded = try await history.load()
        XCTAssertEqual(loaded.count, 200)
        XCTAssertEqual(loaded.firstIndex { $0.operation == .fanCurveOff }, 129, "Between 101 and 100")
        XCTAssertEqual(loaded.last?.targetRPMByFan, [0: 1_031])

        // Records large enough that 200 would not fit: the byte limit decides.
        let wide = Dictionary(uniqueKeysWithValues: (0..<64).map { ($0, 6_000 + $0) })
        for index in 0..<200 {
            try await history.record(HardwareOperationRecord(
                recordedAt: Date(timeIntervalSinceReferenceDate: Double(1_000 + index)), operation: .fanSpeed,
                outcome: .succeeded, targetRPMByFan: wide, automaticFanIDs: Array(0..<64)))
        }
        let trimmed = try await history.load()
        XCTAssertLessThan(trimmed.count, 200)
        XCTAssertEqual(trimmed.map(\.recordedAt),
                       (0..<trimmed.count).map { Date(timeIntervalSinceReferenceDate: Double(1_199 - $0)) },
                       "The newest kept, the oldest went first")
        XCTAssertTrue(trimmed.allSatisfy { $0.targetRPMByFan == wide })
        XCTAssertLessThanOrEqual(try fileSize(url), HardwareOperationHistory.maximumStorageBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [url.lastPathComponent],
                       "Trimmed on every write, so no file grew past the limit and had to be set aside")
    }

    /// A damaged file is kept beside the new one, never overwritten; a link
    /// in place of the file is refused for reading and writing.
    func testAnUnreadableFileIsKeptAsideAndALinkIsRefused() async throws {
        let url = root.appendingPathComponent("hardware-operations.json")
        try Data("not json".utf8).write(to: url)
        let history = HardwareOperationHistory(storageURL: url)
        do {
            _ = try await history.load()
            XCTFail("A damaged file is not read as an empty record")
        } catch {}
        try await history.record(HardwareOperationRecord(recordedAt: Date(timeIntervalSinceReferenceDate: 5),
                                                         operation: .macMiniMode, outcome: .succeeded,
                                                         macMiniMode: .whenOnAC))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let aside = try XCTUnwrap(names.first { $0.hasPrefix("hardware-operations.json.corrupt-") })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(aside)), Data("not json".utf8))
        let loaded = try await history.load()
        XCTAssertEqual(loaded.map(\.macMiniMode), [.whenOnAC])

        let target = root.appendingPathComponent("elsewhere.json")
        try Data("{}".utf8).write(to: target)
        let link = root.appendingPathComponent("linked.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let linked = HardwareOperationHistory(storageURL: link)
        do {
            _ = try await linked.load()
            XCTFail("A link in place of the file must be refused")
        } catch {}
        do {
            try await linked.record(HardwareOperationRecord(recordedAt: Date(), operation: .fanCurveOff, outcome: .succeeded))
            XCTFail("A link in place of the file must not be written through")
        } catch {}
        XCTAssertEqual(try Data(contentsOf: target), Data("{}".utf8))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
    }

    /// Each kind of record reads as what happened; fans are numbered from 1.
    func testThePageNamesEachRecord() throws {
        let fan = HardwareOperationRecord(recordedAt: Date(), operation: .fanSpeed, outcome: .succeeded,
                                          targetRPMByFan: [1: 2_600, 0: 2_400], automaticFanIDs: [2])
        XCTAssertEqual(HardwareOperationPresentation.title(fan), L10n.text("设置风扇转速", "Fan speed set"))
        XCTAssertEqual(HardwareOperationPresentation.detail(fan), [
            L10n.text("风扇 1：2400 RPM", "Fan 1: 2400 RPM"), L10n.text("风扇 2：2600 RPM", "Fan 2: 2600 RPM"),
            L10n.text("风扇 3：交回系统", "Fan 3: system control"),
        ].joined(separator: L10n.text("；", "; ")))
        XCTAssertEqual(HardwareOperationPresentation.outcome(fan), L10n.text("成功", "Succeeded"))

        let power = HardwareOperationRecord(recordedAt: Date(), operation: .powerMode, outcome: .failed,
                                            powerSetting: "lowpowermode", powerValue: 1, powerSource: "-c",
                                            errorCode: "pmsetFailed")
        XCTAssertEqual(HardwareOperationPresentation.detail(power),
                       L10n.text("电源适配器", "Power adapter") + " · pmset lowpowermode 1")
        XCTAssertEqual(HardwareOperationPresentation.outcome(power), L10n.text("失败（pmsetFailed）", "Failed (pmsetFailed)"))

        let outcomes: [(HardwareOperationRecord.Outcome, String?, String)] = [
            (.unconfirmed, nil, L10n.text("未确认：已发出，但没有收到可用的回复", "Unconfirmed: sent, but no usable reply came back")),
            (.automaticRestore, "fanLeaseExpired", L10n.text("租约到期，已自动交回系统", "Lease expired; returned to the system")),
            (.automaticRestore, "thermalProtectionActivated",
             L10n.text("过热保护，已自动交回系统", "Thermal protection; returned to the system")),
            (.failed, "fanCrashRecoveryFailed",
             L10n.text("失败：辅助程序启动时未能交回系统控制", "Failed: the helper could not return control at startup")),
        ]
        for (outcome, code, text) in outcomes {
            let record = HardwareOperationRecord(recordedAt: Date(), operation: .systemFanControl, outcome: outcome,
                                                 errorCode: code)
            XCTAssertEqual(HardwareOperationPresentation.outcome(record), text)
            XCTAssertNil(HardwareOperationPresentation.detail(record))
        }
        XCTAssertEqual(HardwareOperationPresentation.detail(HardwareOperationRecord(
            recordedAt: Date(), operation: .macMiniMode, outcome: .succeeded, macMiniMode: .off)), L10n.text("关闭", "Off"))
    }

    /// Only the app's shared coordinator records by default, so a coordinator
    /// made in a test never writes to the user's folders; the operation
    /// history page reads the same shared record.
    func testOnlyTheSharedCoordinatorRecordsByDefault() throws {
        func compact(_ path: String) throws -> String {
            SwiftSourceScanning.compact(SwiftSourceScanning.code(try String(
                contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(path), encoding: .utf8)))
        }
        let coordinator = try compact("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift")
        XCTAssertTrue(coordinator.contains(
            "staticletshared=AcceptanceLaunch.isActive?makeAcceptanceInstance():FanControlCoordinator(operationHistory:.shared)"
        ))
        // D106: an acceptance session's coordinator never reaches the helper,
        // so it has no hardware operation to record and records nothing.
        let code = SwiftSourceScanning.code(try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"), encoding: .utf8))
        let factory = try XCTUnwrap(code.range(of: "static func makeAcceptanceInstance("))
        let signature = try XCTUnwrap(code.range(of: ") -> FanControlCoordinator {", range: factory.upperBound..<code.endIndex))
        let body = try XCTUnwrap(SwiftSourceScanning.bodyRange(from: signature.lowerBound, in: code))
        XCTAssertTrue(code[body].contains("coordinator.isDataOnlyFixture = true"))
        XCTAssertFalse(code[body].contains("operationHistory"), "an acceptance coordinator records nothing")
        XCTAssertTrue(coordinator.contains("operationHistory:HardwareOperationHistory?=nil)"))
        XCTAssertTrue(coordinator.contains("self.operationHistory=operationHistory"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "HardwareOperationHistory.shared", in: coordinator), 0)
        XCTAssertTrue(try compact("Sources/StorageCleanerMac/Views/ReversibleOperationsView.swift")
            .contains("varhardwareHistory:HardwareOperationHistory=.shared"))
    }

    /// A request stopped in the app (no requirement for the helper, an
    /// untrusted bundled helper, a request that would not encode) never
    /// reached the helper and is not recorded; one that left gets its reply's
    /// result or "unconfirmed". The XPC branch cannot run here (the test host
    /// is ad hoc signed), so this reads the source; the fake-helper branch is
    /// run in testTheCoordinatorRecordsItsWrites.
    func testOnlyARequestThatLeftTheAppCanBeUnconfirmed() throws {
        let source = SwiftSourceScanning.code(try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/StorageCleanerMac/Services/FanControlCoordinator.swift"), encoding: .utf8))
        let send = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "private func send(_ request: FanControlHelperRequest,", in: source))
        XCTAssertTrue(send.contains("varsent=false,replied=falsedo{letreply=tryawaitperformSend(request,"
            + "generation:&generation,sent:&sent)replied=truerecordHardwareOperation(request,reply:reply)"), send)
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "recordHardwareOperation(", in: send), 2, send)
        XCTAssertTrue(send.contains("}catch{ifsent,!replied{recordHardwareOperation(request,reply:nil)}"), send)

        let perform = SwiftSourceScanning.compact(try SwiftSourceScanning.body(
            of: "private func performSend(_ request: FanControlHelperRequest,", in: source))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "sent=", in: perform), 2, perform)
        XCTAssertTrue(perform.contains("ifletrequestSender{sent=trueresponse=tryawaitwithCheckedThrowingContinuation"), perform)
        // Set as the message is handed to the connection, after every step that can fail in the app.
        let handover = try XCTUnwrap(perform.range(of: "sent=truehelper.execute(requestData)"), perform)
        for step in ["throwFanControlConnectionError.untrustedBundledHelper", "tryrequest.encodedForTransport()",
                     "tryhelperConnection()", "throwing:FanControlConnectionError.invalidRemoteObject"] {
            let range = try XCTUnwrap(perform.range(of: step), step)
            XCTAssertLessThan(range.upperBound, handover.lowerBound, step)
        }
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

    private func fileSize(_ url: URL) throws -> Int {
        try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
    }

    private static func reply(_ operation: FanControlHelperRequest.Operation, success: Bool, message: String = "",
                              errorCode: FanControlHelperErrorCode? = nil) -> FanControlHelperReply {
        FanControlHelperReply(operation: operation, success: success, message: message,
                              appliedTargetRPMByFan: [:], errorCode: errorCode)
    }
}
