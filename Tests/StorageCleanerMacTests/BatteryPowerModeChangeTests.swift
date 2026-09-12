import Foundation
import XCTest
@testable import StorageCleanerMac

final class BatteryPowerModeChangeTests: XCTestCase {
    func testWriteCommandWhitelistMapsBatteryAndACWithoutAllSourcesFlag() throws {
        let expectations: [(BatteryPowerSource, BatteryPowerMode, BatteryPowerModeSettingKey, [String])] = [
            (.batteryPower, .automatic, .powerMode, ["-b", "powermode", "0"]),
            (.batteryPower, .lowPower, .powerMode, ["-b", "powermode", "1"]),
            (.batteryPower, .highPower, .powerMode, ["-b", "powermode", "2"]),
            (.acPower, .automatic, .powerMode, ["-c", "powermode", "0"]),
            (.acPower, .lowPower, .powerMode, ["-c", "powermode", "1"]),
            (.acPower, .highPower, .powerMode, ["-c", "powermode", "2"]),
            (.batteryPower, .automatic, .lowPowerMode, ["-b", "lowpowermode", "0"]),
            (.batteryPower, .lowPower, .lowPowerMode, ["-b", "lowpowermode", "1"]),
            (.acPower, .automatic, .lowPowerMode, ["-c", "lowpowermode", "0"]),
            (.acPower, .lowPower, .lowPowerMode, ["-c", "lowpowermode", "1"]),
        ]

        for (source, mode, setting, expectedArguments) in expectations {
            let command = try XCTUnwrap(BatteryPowerModeWriteCommand.make(
                source: source,
                mode: mode,
                setting: setting
            ))
            XCTAssertEqual(command.arguments, expectedArguments)
            XCTAssertTrue(command.isWhitelisted)
            XCTAssertFalse(command.arguments.contains("-a"))
        }

        XCTAssertNil(BatteryPowerModeWriteCommand.make(
            source: .unknown,
            mode: .automatic
        ))
        XCTAssertNil(BatteryPowerModeWriteCommand.make(
            source: .acPower,
            mode: .highPower,
            setting: .lowPowerMode
        ))
    }

    func testPowerModeHelperRequestCarriesOnlyWhitelistedPMSetFields() throws {
        let command = try XCTUnwrap(BatteryPowerModeWriteCommand.make(
            source: .acPower,
            mode: .highPower,
            setting: .powerMode
        ))
        let request = try XCTUnwrap(
            FanControlHelperRequest.applyPowerMode(command)
        )

        XCTAssertEqual(request.operation, .applyPowerMode)
        XCTAssertEqual(request.powerModeSource, "-c")
        XCTAssertEqual(request.powerModeSetting, "powermode")
        XCTAssertEqual(request.powerModeValue, 2)
        XCTAssertEqual(request.targetRPMByFan, [:])
        XCTAssertEqual(request.automaticFanIDs, [])
        XCTAssertEqual(request.watchdogSeconds, 0)
    }

    func testHelperPowerConfigurationMatchesOnlyTheExactSourceSettingAndMode() throws {
        let configuration = FanControlPowerConfiguration(
            battery: .lowPower,
            adapter: .highPower,
            supportedBatteryModes: [.automatic, .lowPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .lowPowerMode,
            adapterSetting: .powerMode
        )

        XCTAssertTrue(configuration.matches(try XCTUnwrap(
            BatteryPowerModeWriteCommand.make(
                source: .acPower,
                mode: .highPower,
                setting: .powerMode
            )
        )))
        XCTAssertFalse(configuration.matches(try XCTUnwrap(
            BatteryPowerModeWriteCommand.make(
                source: .batteryPower,
                mode: .lowPower,
                setting: .powerMode
            )
        )))
    }

    @MainActor
    func testCoordinatorRejectsOptimisticPowerReplyWithoutMatchingReadback() async throws {
        let command = try XCTUnwrap(BatteryPowerModeWriteCommand.make(
            source: .batteryPower,
            mode: .lowPower,
            setting: .powerMode
        ))
        let coordinator = FanControlCoordinator(
            helperStatusOverride: .enabled,
            isHelperReachable: true,
            requestSender: { request in
                FanControlHelperReply(
                    operation: request.operation,
                    success: true,
                    message: "optimistic",
                    appliedTargetRPMByFan: [:]
                )
            },
            legacyArtifactsPresentProvider: { false },
            legacyArtifactsCurrentProvider: { false },
            serviceStatusProvider: { .enabled }
        )

        do {
            _ = try await coordinator.applyPowerMode(command)
            XCTFail("A write without readback must not report success")
        } catch let failure as BatteryPowerModeCommandFailure {
            XCTAssertEqual(failure, .verificationFailed)
        }
    }

    func testCapabilityParserSupportsLegacyLowPowerAndPrefersValidConsolidatedMode() {
        let parsed = BatteryHealthService.powerModes(from: """
        Battery Power:
         lowpowermode         1
        AC Power:
         powermode            0
         lowpowermode         1
        """)

        XCTAssertEqual(parsed.battery, .lowPower)
        XCTAssertEqual(parsed.supportedBatteryModes, [.automatic, .lowPower])
        XCTAssertEqual(parsed.batterySetting, .lowPowerMode)
        XCTAssertEqual(parsed.adapter, .automatic)
        XCTAssertEqual(parsed.supportedAdapterModes, [.automatic, .lowPower, .highPower])
        XCTAssertEqual(parsed.adapterSetting, .powerMode)
    }

    func testCapabilityParserConservativelyOffersBatteryLowPowerWhenMacOSOmitsBatterySection() {
        let parsed = BatteryHealthService.powerModes(
            from: """
            AC Power:
             lowpowermode         0
            """,
            inferMissingBatteryLowPowerMode: true
        )

        XCTAssertNil(parsed.battery)
        XCTAssertEqual(
            parsed.supportedBatteryModes,
            [.automatic, .lowPower]
        )
        XCTAssertEqual(parsed.batterySetting, .lowPowerMode)
        XCTAssertEqual(parsed.adapter, .automatic)
        XCTAssertEqual(parsed.adapterSetting, .lowPowerMode)
    }

    func testCapabilityParserDoesNotInventMissingBatteryWithoutInternalBatteryEvidence() {
        let parsed = BatteryHealthService.powerModes(from: """
        AC Power:
         lowpowermode         0
        """)

        XCTAssertNil(parsed.battery)
        XCTAssertEqual(parsed.supportedBatteryModes, [])
        XCTAssertNil(parsed.batterySetting)
    }

    func testCapabilityParserRejectsUnknownRawValuesInsteadOfOfferingControls() {
        let parsed = BatteryHealthService.powerModes(from: """
        Battery Power:
         powermode            9
         lowpowermode         -1
        AC Power:
         powermode            -1
        """)

        XCTAssertNil(parsed.battery)
        XCTAssertNil(parsed.adapter)
        XCTAssertEqual(parsed.supportedBatteryModes, [])
        XCTAssertEqual(parsed.supportedAdapterModes, [])
        XCTAssertNil(parsed.batterySetting)
        XCTAssertNil(parsed.adapterSetting)
    }

    func testUnknownPowerSourceSectionCannotPollutePreviousACSection() {
        let parsed = BatteryHealthService.powerModes(from: """
        AC Power:
         lowpowermode         0
        UPS Power:
         powermode            2
        """)

        XCTAssertEqual(parsed.adapter, .automatic)
        XCTAssertEqual(parsed.supportedAdapterModes, [.automatic, .lowPower])
        XCTAssertEqual(parsed.adapterSetting, .lowPowerMode)
        XCTAssertNil(parsed.battery)
    }

    func testInvalidConsolidatedKeyPoisonsSourceInsteadOfFallingBackToLegacy() {
        let parsed = BatteryHealthService.powerModes(from: """
        Battery Power:
         powermode            future
         lowpowermode         1
        AC Power:
         powermode            9
         lowpowermode         0
        """)

        XCTAssertNil(parsed.battery)
        XCTAssertNil(parsed.adapter)
        XCTAssertEqual(parsed.supportedBatteryModes, [])
        XCTAssertEqual(parsed.supportedAdapterModes, [])
        XCTAssertNil(parsed.batterySetting)
        XCTAssertNil(parsed.adapterSetting)
    }

    func testConflictingDuplicateConsolidatedValuesPoisonOnlyThatSource() {
        let parsed = BatteryHealthService.powerModes(from: """
        Battery Power:
         powermode            0
         powermode            2
        AC Power:
         powermode            1
         powermode            1
        """)

        XCTAssertNil(parsed.battery)
        XCTAssertEqual(parsed.supportedBatteryModes, [])
        XCTAssertNil(parsed.batterySetting)
        XCTAssertEqual(parsed.adapter, .lowPower)
        XCTAssertEqual(parsed.supportedAdapterModes, [.automatic, .lowPower, .highPower])
        XCTAssertEqual(parsed.adapterSetting, .powerMode)
    }

    func testSuccessfulChangeRequiresExactRequestedSourceAndMode() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 0),
            consolidatedOutput(battery: 1, adapter: 0),
        ])
        let writer = ScriptedPowerModeWriter()
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(source: .batteryPower, mode: .lowPower)

        guard case let .changed(observed) = result else {
            return XCTFail("Expected verified change, got \(result)")
        }
        XCTAssertEqual(observed.battery, .lowPower)
        XCTAssertEqual(observed.adapter, .automatic)
        let commands = await writer.commands
        XCTAssertEqual(commands.map(\.arguments), [["-b", "powermode", "1"]])
    }

    func testDelayedPowerdPublicationIsRetriedBeforeSuccess() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 0),
            consolidatedOutput(battery: 0, adapter: 0),
            consolidatedOutput(battery: 1, adapter: 0),
        ])
        let writer = ScriptedPowerModeWriter()
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(source: .batteryPower, mode: .lowPower)

        guard case .changed = result else {
            return XCTFail("Expected delayed verification success, got \(result)")
        }
        let captureCount = await reader.captureCount
        XCTAssertEqual(captureCount, 3)
    }

    func testAuthorizationCancellationReturnsCancelledWithoutFalseSuccess() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 0),
        ])
        let writer = ScriptedPowerModeWriter(failure: .cancelled)
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(source: .batteryPower, mode: .lowPower)

        XCTAssertEqual(result, .cancelled)
        let captureCount = await reader.captureCount
        XCTAssertEqual(captureCount, 1)
    }

    func testExecutionFailureReturnsFailureWithoutFalseSuccess() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 0),
        ])
        let writer = ScriptedPowerModeWriter(failure: .unavailable)
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(source: .acPower, mode: .lowPower)

        XCTAssertEqual(result, .failed)
        let captureCount = await reader.captureCount
        XCTAssertEqual(captureCount, 1)
    }

    func testHelperVerificationFailureKeepsTheBaselineAsObservedState() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 0),
        ])
        let writer = ScriptedPowerModeWriter(failure: .verificationFailed)
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(
            source: .batteryPower,
            mode: .lowPower
        )

        guard case let .verificationFailed(observed) = result else {
            return XCTFail("Expected verification failure, got \(result)")
        }
        XCTAssertEqual(observed.battery, .automatic)
        XCTAssertEqual(observed.adapter, .automatic)
    }

    func testChangingWrongSourceFailsExactTargetVerification() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 0),
            consolidatedOutput(battery: 0, adapter: 1),
        ])
        let writer = ScriptedPowerModeWriter()
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(source: .batteryPower, mode: .lowPower)

        guard case let .verificationFailed(observed) = result else {
            return XCTFail("Expected exact-target verification failure, got \(result)")
        }
        XCTAssertEqual(observed.battery, .automatic)
        XCTAssertEqual(observed.adapter, .lowPower)
    }

    func testUnsupportedHighPowerNeverInvokesWriter() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            legacyOutput(battery: 0, adapter: 0),
        ])
        let writer = ScriptedPowerModeWriter()
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(source: .acPower, mode: .highPower)

        XCTAssertEqual(result, .unsupported)
        let commands = await writer.commands
        XCTAssertEqual(commands, [])
    }

    func testSelectingCurrentModeIsVerifiedWithoutAdministratorWrite() async {
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 1),
        ])
        let writer = ScriptedPowerModeWriter()
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(source: .acPower, mode: .lowPower)

        guard case let .changed(observed) = result else {
            return XCTFail("Expected current mode to verify without a write, got \(result)")
        }
        XCTAssertEqual(observed.adapter, .lowPower)
        let commands = await writer.commands
        XCTAssertEqual(commands, [])
    }

    func testHelperVerifiedReadbackSkipsRedundantPMSetProcess() async {
        let verified = BatteryPowerModes(
            battery: .lowPower,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .powerMode,
            adapterSetting: .powerMode
        )
        let reader = SequenceBatteryHealthRunner(outputs: [
            consolidatedOutput(battery: 0, adapter: 0),
        ])
        let writer = ScriptedPowerModeWriter(verifiedModes: verified)
        let service = makeService(reader: reader, writer: writer)

        let result = await service.changePowerMode(
            source: .batteryPower,
            mode: .lowPower
        )

        XCTAssertEqual(result, .changed(verified))
        let captureCount = await reader.captureCount
        XCTAssertEqual(captureCount, 1)
    }

    @MainActor
    func testComputerHealthStorePublishesVerifiedModeAndCancellationState() async {
        let changedModes = BatteryPowerModes(
            battery: .lowPower,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .powerMode,
            adapterSetting: .powerMode
        )
        let controller = ScriptedPowerModeController(results: [
            .changed(changedModes),
            .cancelled,
        ])
        let store = ComputerHealthStore(
            probe: FailingComputerHealthProbe(),
            batteryPowerModeController: controller
        )

        await store.changeBatteryPowerMode(source: .batteryPower, mode: .lowPower)
        XCTAssertEqual(store.batteryPowerModes, changedModes)
        XCTAssertEqual(
            store.batteryPowerModeAdjustmentState,
            .changed(source: .batteryPower, mode: .lowPower)
        )

        await store.changeBatteryPowerMode(source: .acPower, mode: .lowPower)
        XCTAssertEqual(
            store.batteryPowerModeAdjustmentState,
            .cancelled(source: .acPower, mode: .lowPower)
        )
        XCTAssertEqual(store.batteryPowerModes, changedModes)
    }

    @MainActor
    func testStaleRefreshCannotOverwriteNewlyVerifiedMode() async {
        let oldModes = BatteryPowerModes(
            battery: .automatic,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .powerMode,
            adapterSetting: .powerMode
        )
        let changedModes = BatteryPowerModes(
            battery: .lowPower,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .powerMode,
            adapterSetting: .powerMode
        )
        let controller = ControlledPowerModeController(changeResult: .changed(changedModes))
        let store = ComputerHealthStore(
            probe: FailingComputerHealthProbe(),
            batteryPowerModeController: controller
        )

        let staleRefresh = Task { @MainActor in
            await store.refreshBatteryPowerModes()
        }
        await controller.waitForReadRequest()
        await store.changeBatteryPowerMode(source: .batteryPower, mode: .lowPower)
        await controller.resumeRead(with: oldModes)
        await staleRefresh.value

        XCTAssertEqual(store.batteryPowerModes, changedModes)
        XCTAssertEqual(
            store.batteryPowerModeAdjustmentState,
            .changed(source: .batteryPower, mode: .lowPower)
        )
    }

    @MainActor
    func testRapidPowerModeSelectionIsSerialAndLatestWins() async {
        let firstModes = BatteryPowerModes(
            battery: .lowPower,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .powerMode,
            adapterSetting: .powerMode
        )
        let latestModes = BatteryPowerModes(
            battery: .highPower,
            adapter: .automatic,
            supportedBatteryModes: [.automatic, .lowPower, .highPower],
            supportedAdapterModes: [.automatic, .lowPower, .highPower],
            batterySetting: .powerMode,
            adapterSetting: .powerMode
        )
        let controller = QueuedPowerModeController()
        let store = ComputerHealthStore(
            probe: FailingComputerHealthProbe(),
            batteryPowerModeController: controller
        )

        let first = Task { @MainActor in
            await store.changeBatteryPowerMode(
                source: .batteryPower,
                mode: .lowPower
            )
        }
        await controller.waitForRequestCount(1)
        let latest = Task { @MainActor in
            await store.changeBatteryPowerMode(
                source: .batteryPower,
                mode: .highPower
            )
        }
        await Task.yield()
        let requestCountWhileFirstIsRunning = await controller.requestCount
        XCTAssertEqual(requestCountWhileFirstIsRunning, 1)

        await controller.resumeNext(with: .changed(firstModes))
        await controller.waitForRequestCount(2)
        await controller.resumeNext(with: .changed(latestModes))
        await first.value
        await latest.value

        let maximumActiveRequestCount = await controller.maximumActiveRequestCount
        XCTAssertEqual(maximumActiveRequestCount, 1)
        XCTAssertEqual(store.batteryPowerModes, latestModes)
        XCTAssertEqual(
            store.batteryPowerModeAdjustmentState,
            .changed(source: .batteryPower, mode: .highPower)
        )
    }

    private func makeService(
        reader: SequenceBatteryHealthRunner,
        writer: ScriptedPowerModeWriter
    ) -> BatteryHealthService {
        BatteryHealthService(
            runner: reader,
            powerModeWriter: writer,
            powerSampleProvider: { nil },
            verificationDelay: {}
        )
    }

    private func consolidatedOutput(battery: Int, adapter: Int) -> String {
        """
        Battery Power:
         powermode            \(battery)
        AC Power:
         powermode            \(adapter)
        """
    }

    private func legacyOutput(battery: Int, adapter: Int) -> String {
        """
        Battery Power:
         lowpowermode         \(battery)
        AC Power:
         lowpowermode         \(adapter)
        """
    }
}

private actor SequenceBatteryHealthRunner: BatteryHealthCommandRunning {
    private var outputs: [String]
    private(set) var captureCount = 0

    init(outputs: [String]) {
        self.outputs = outputs
    }

    func capture(_ command: BatteryHealthCommand) async throws -> Data {
        guard command == BatteryHealthService.powerModesCommand,
              !outputs.isEmpty else {
            throw BatteryHealthCommandFailure.unavailable
        }
        captureCount += 1
        return Data(outputs.removeFirst().utf8)
    }
}

private actor ScriptedPowerModeWriter: BatteryPowerModeCommandRunning {
    private let failure: BatteryPowerModeCommandFailure?
    private let verifiedModes: BatteryPowerModes?
    private(set) var commands = [BatteryPowerModeWriteCommand]()

    init(
        failure: BatteryPowerModeCommandFailure? = nil,
        verifiedModes: BatteryPowerModes? = nil
    ) {
        self.failure = failure
        self.verifiedModes = verifiedModes
    }

    func apply(_ command: BatteryPowerModeWriteCommand) async throws -> BatteryPowerModes? {
        commands.append(command)
        if let failure { throw failure }
        return verifiedModes
    }
}

private actor QueuedPowerModeController: BatteryPowerModeControlling {
    private var continuations = [CheckedContinuation<BatteryPowerModeChangeResult, Never>]()
    private(set) var requestCount = 0
    private var activeRequestCount = 0
    private(set) var maximumActiveRequestCount = 0

    func readPowerModes() async -> BatteryPowerModes? { nil }

    func changePowerMode(
        source: BatteryPowerSource,
        mode: BatteryPowerMode
    ) async -> BatteryPowerModeChangeResult {
        _ = source
        _ = mode
        requestCount += 1
        activeRequestCount += 1
        maximumActiveRequestCount = max(maximumActiveRequestCount, activeRequestCount)
        let result = await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        activeRequestCount -= 1
        return result
    }

    func waitForRequestCount(_ expected: Int) async {
        while requestCount < expected {
            await Task.yield()
        }
    }

    func resumeNext(with result: BatteryPowerModeChangeResult) {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume(returning: result)
    }
}

private actor ScriptedPowerModeController: BatteryPowerModeControlling {
    private var results: [BatteryPowerModeChangeResult]

    init(results: [BatteryPowerModeChangeResult]) {
        self.results = results
    }

    func readPowerModes() async -> BatteryPowerModes? { nil }

    func changePowerMode(
        source: BatteryPowerSource,
        mode: BatteryPowerMode
    ) async -> BatteryPowerModeChangeResult {
        results.isEmpty ? .failed : results.removeFirst()
    }
}

private struct FailingComputerHealthProbe: ComputerHealthProbing {
    func probe() async throws -> ComputerHealthSnapshot {
        throw ComputerHealthRefreshError.readFailed
    }
}

private actor ControlledPowerModeController: BatteryPowerModeControlling {
    private let changeResult: BatteryPowerModeChangeResult
    private var readWasRequested = false
    private var readContinuation: CheckedContinuation<BatteryPowerModes?, Never>?

    init(changeResult: BatteryPowerModeChangeResult) {
        self.changeResult = changeResult
    }

    func readPowerModes() async -> BatteryPowerModes? {
        readWasRequested = true
        return await withCheckedContinuation { continuation in
            readContinuation = continuation
        }
    }

    func waitForReadRequest() async {
        while !readWasRequested {
            await Task.yield()
        }
    }

    func resumeRead(with modes: BatteryPowerModes?) {
        readContinuation?.resume(returning: modes)
        readContinuation = nil
    }

    func changePowerMode(
        source: BatteryPowerSource,
        mode: BatteryPowerMode
    ) async -> BatteryPowerModeChangeResult {
        changeResult
    }
}
