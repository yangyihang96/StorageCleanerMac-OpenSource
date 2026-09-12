import Foundation
import IOKit.ps
import XCTest
@testable import StorageCleanerMac

final class BatteryHealthServiceTests: XCTestCase {
    func testCancellableShellCanRunWithAnExactEnvironmentAllowlist() throws {
        let output = try Shell.captureCancellable(
            "/usr/bin/env",
            [],
            environment: [
                "PATH": "/usr/bin:/bin",
                "STORAGE_CLEANER_ENV_TEST": "isolated",
            ],
            timeout: 2,
            outputByteLimit: 4_096,
            cancellationCheck: { false }
        )

        XCTAssertEqual(
            Set(output.split(separator: "\n").map(String.init)),
            [
                "PATH=/usr/bin:/bin",
                "STORAGE_CLEANER_ENV_TEST=isolated",
            ]
        )
    }

    private let sampledAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testHealthyOptimizedEightyPercentChargeIsNotFlagged() throws {
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: batteryJSON(
                chargePercent: 80,
                maximumCapacity: "100%",
                cycleCount: 35,
                condition: "spbattery_health_normal",
                optimizedCharging: true
            ),
            powerSample: internalPowerSample(chargePercent: 80, isCharging: false, source: .acPower),
            powerModeOutput: pmsetOutput(batteryMode: 1, adapterMode: 0),
            sampledAt: sampledAt
        ))

        XCTAssertEqual(snapshot.maximumCapacityPercent, 100)
        XCTAssertEqual(snapshot.cycleCount, 35)
        XCTAssertEqual(snapshot.status, .healthy)
        XCTAssertEqual(snapshot.condition, .normal)
        XCTAssertEqual(snapshot.guidance.kind, .optimizedChargingNormal)
        XCTAssertEqual(snapshot.batteryPowerMode, .lowPower)
        XCTAssertEqual(snapshot.adapterPowerMode, .automatic)
    }

    func testInternalPowerSourceAndRemainingTimeAreReusedWithoutGuessing() throws {
        let powerSnapshot = BatteryPowerSnapshot(
            chargePercent: 41,
            isCharging: false,
            powerSource: .batteryPower,
            timeToEmptyMinutes: 137,
            timeToFullChargeMinutes: nil
        )
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: batteryJSON(
                chargePercent: 41,
                maximumCapacity: "96%",
                cycleCount: 88,
                condition: "Normal",
                optimizedCharging: false
            ),
            powerSample: BatteryPowerSample(
                snapshot: powerSnapshot,
                provenance: .internalBattery
            ),
            powerModeOutput: pmsetOutput(batteryMode: 0, adapterMode: 0),
            sampledAt: sampledAt
        ))

        XCTAssertEqual(snapshot.powerSource, .batteryPower)
        XCTAssertEqual(snapshot.remainingTimeMinutes, 137)
        XCTAssertEqual(snapshot.currentChargePercent, 41)
        XCTAssertEqual(snapshot.isCharging, false)
    }

    func testMissingBatteryHidesModuleInsteadOfInventingZero() {
        XCTAssertNil(BatteryHealthService.parse(
            systemProfilerData: Data("{\"SPPowerDataType\":[]}".utf8),
            powerSample: nil,
            powerModeOutput: nil,
            sampledAt: sampledAt
        ))
    }

    func testEvidenceDistinguishesExplicitNoBatteryFromProbeFailure() async throws {
        let sampledAt = self.sampledAt
        let noBatteryRunner = RecordingBatteryHealthRunner(responses: [
            BatteryHealthService.profilerCommand: .success(Data("{\"SPPowerDataType\":[]}".utf8)),
            BatteryHealthService.powerModesCommand: .success(Data())
        ])
        let noBatteryService = BatteryHealthService(
            runner: noBatteryRunner,
            powerSampleProvider: { nil },
            now: { sampledAt }
        )
        let noBatteryEvidence = try await noBatteryService.evidence()

        XCTAssertEqual(noBatteryEvidence, .notPresent(checkedAt: sampledAt))

        let failedService = BatteryHealthService(
            runner: RecordingBatteryHealthRunner(
                defaultResponse: .failure(BatteryHealthCommandFailure.permissionDenied)
            ),
            powerSampleProvider: { nil },
            now: { sampledAt }
        )
        let failedEvidence = try await failedService.evidence()

        XCTAssertEqual(
            failedEvidence,
            .failed(reason: .permissionDenied, checkedAt: sampledAt)
        )
    }

    func testEvidenceNeverTreatsMalformedOrUnknownProfilerDataAsNoBattery() async throws {
        let sampledAt = self.sampledAt
        for profilerData in [
            Data("{\"SPPowerDataType\":[".utf8),
            Data("{\"SPPowerDataType\":[{\"_name\":\"Power\"}]}".utf8),
            Data("{\"UnexpectedPowerEnvelope\":[]}".utf8),
        ] {
            let service = BatteryHealthService(
                runner: RecordingBatteryHealthRunner(responses: [
                    BatteryHealthService.profilerCommand: .success(profilerData),
                    BatteryHealthService.powerModesCommand: .success(Data()),
                ]),
                powerSampleProvider: { nil },
                now: { sampledAt }
            )

            let evidence = try await service.evidence()

            XCTAssertEqual(
                evidence,
                .failed(reason: .readFailed, checkedAt: sampledAt)
            )
        }
    }

    func testReadableNoBatteryProfilerDoesNotTurnUPSIntoInternalBattery() {
        XCTAssertNil(BatteryHealthService.parse(
            systemProfilerData: Data("{\"SPPowerDataType\":[]}".utf8),
            powerSample: BatteryPowerSample(
                snapshot: powerSnapshot(
                    chargePercent: 75,
                    isCharging: false,
                    source: .batteryPower
                ),
                provenance: .externalOrUnknown
            ),
            powerModeOutput: nil,
            sampledAt: sampledAt
        ))
    }

    func testReadableProfilerWithMissingSchemaFallsBackToProvenInternalBattery() throws {
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: Data("{\"SPPowerDataType\":[{\"_name\":\"Power\"}]}".utf8),
            powerSample: BatteryPowerSample(
                snapshot: powerSnapshot(
                    chargePercent: 73,
                    isCharging: false,
                    source: .batteryPower
                ),
                provenance: .internalBattery
            ),
            powerModeOutput: nil,
            sampledAt: sampledAt
        ))

        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
        XCTAssertEqual(snapshot.currentChargePercent, 73)
        XCTAssertNil(snapshot.maximumCapacityPercent)
        XCTAssertNil(snapshot.condition)
    }

    func testReadableProfilerWithMissingSchemaRejectsUnusableInternalSample() {
        let unusable = BatteryPowerSnapshot(
            chargePercent: nil,
            isCharging: nil,
            powerSource: .unknown,
            timeToEmptyMinutes: nil,
            timeToFullChargeMinutes: nil
        )

        XCTAssertNil(BatteryHealthService.parse(
            systemProfilerData: Data("{\"SPPowerDataType\":[{\"_name\":\"Power\"}]}".utf8),
            powerSample: BatteryPowerSample(
                snapshot: unusable,
                provenance: .internalBattery
            ),
            powerModeOutput: nil,
            sampledAt: sampledAt
        ))
    }

    func testInternalBatterySelectionUsesHardwareTypeAndRejectsUPSOnlyInput() throws {
        let ups: [String: Any] = [
            kIOPSTypeKey: "UPS",
            kIOPSCurrentCapacityKey: 90,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue
        ]
        let internalBattery: [String: Any] = [
            kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSCurrentCapacityKey: 61,
            kIOPSMaxCapacityKey: 100,
            kIOPSPowerSourceStateKey: kIOPSACPowerValue
        ]

        let selected = try XCTUnwrap(BatteryPowerService.selectSample(
            fromPowerSourceDescriptions: [ups, internalBattery],
            allowExternalFallback: false
        ))
        let rejectedUPS = BatteryPowerService.selectSample(
            fromPowerSourceDescriptions: [ups],
            allowExternalFallback: false
        )

        XCTAssertEqual(selected.provenance, .internalBattery)
        XCTAssertEqual(selected.snapshot.chargePercent, 61)
        XCTAssertNil(rejectedUPS)
    }

    func testSystemConditionIsAuthoritativeAndServiceRecommendedRequiresAction() throws {
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: batteryJSON(
                chargePercent: 88,
                maximumCapacity: "92%",
                cycleCount: 740,
                condition: "Service Recommended",
                optimizedCharging: false
            ),
            powerSample: internalPowerSample(chargePercent: 88, isCharging: false, source: .batteryPower),
            powerModeOutput: nil,
            sampledAt: sampledAt
        ))

        XCTAssertEqual(snapshot.condition, .serviceRecommended)
        XCTAssertEqual(snapshot.status, .actionRequired)
        XCTAssertEqual(snapshot.guidance.kind, .serviceRecommended)
    }

    func testMissingHealthFieldsRemainPartialAndNeverBecomeHealthy() throws {
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: batteryJSON(
                chargePercent: 54,
                maximumCapacity: nil,
                cycleCount: nil,
                condition: nil,
                optimizedCharging: nil
            ),
            powerSample: internalPowerSample(chargePercent: 54, isCharging: false, source: .batteryPower),
            powerModeOutput: nil,
            sampledAt: sampledAt
        ))

        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
        XCTAssertNil(snapshot.maximumCapacityPercent)
        XCTAssertNil(snapshot.cycleCount)
        XCTAssertNil(snapshot.condition)
    }

    func testLowBatteryGuidanceDoesNotClaimItChangedThePowerMode() throws {
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: batteryJSON(
                chargePercent: 14,
                maximumCapacity: "98%",
                cycleCount: 50,
                condition: "Normal",
                optimizedCharging: false
            ),
            powerSample: internalPowerSample(chargePercent: 14, isCharging: false, source: .batteryPower),
            powerModeOutput: pmsetOutput(batteryMode: 0, adapterMode: 0),
            sampledAt: sampledAt
        ))

        XCTAssertEqual(snapshot.guidance.kind, .considerLowPower)
        XCTAssertEqual(snapshot.batteryPowerMode, .automatic)
    }

    func testEightyPercentWithoutExplicitOptimizedStateIsNotCalledOptimizedCharging() throws {
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: batteryJSON(
                chargePercent: 80,
                maximumCapacity: "100%",
                cycleCount: 35,
                condition: "Normal",
                optimizedCharging: nil
            ),
            powerSample: internalPowerSample(chargePercent: 80, isCharging: false, source: .acPower),
            powerModeOutput: pmsetOutput(batteryMode: 0, adapterMode: 0),
            sampledAt: sampledAt
        ))

        XCTAssertEqual(snapshot.guidance.kind, .none)
    }

    func testInvalidCapacityAndPrivateBatteryFieldsAreDiscarded() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: batteryJSON(
                chargePercent: 80,
                maximumCapacity: "100%",
                cycleCount: 35,
                condition: "Normal",
                optimizedCharging: false
            )) as? [String: Any]
        )
        var records = try XCTUnwrap(object["SPPowerDataType"] as? [[String: Any]])
        records[0]["sppower_battery_health_info"] = [
            "sppower_battery_health_maximum_capacity": "250%",
            "sppower_battery_cycle_count": 35,
            "sppower_battery_health": "Normal"
        ]
        records[0]["sppower_battery_model_info"] = [
            "sppower_battery_serial_number": "TEST-PRIVATE-SERIAL",
            "sppower_battery_device_name": "TEST-PRIVATE-MODEL"
        ]
        object["SPPowerDataType"] = records
        let snapshot = try XCTUnwrap(BatteryHealthService.parse(
            systemProfilerData: try JSONSerialization.data(withJSONObject: object),
            powerSample: internalPowerSample(chargePercent: 80, isCharging: false, source: .acPower),
            powerModeOutput: nil,
            sampledAt: sampledAt
        ))
        let description = String(describing: snapshot)

        XCTAssertNil(snapshot.maximumCapacityPercent)
        XCTAssertFalse(description.contains("TEST-PRIVATE-SERIAL"))
        XCTAssertFalse(description.contains("TEST-PRIVATE-MODEL"))
    }

    func testPowerModeParserAcceptsOnlyKnownReadOnlyCustomValues() {
        let parsed = BatteryHealthService.powerModes(from: pmsetOutput(batteryMode: 1, adapterMode: 2))
        let unknown = BatteryHealthService.powerModes(from: pmsetOutput(batteryMode: 9, adapterMode: -1))

        XCTAssertEqual(parsed.battery, .lowPower)
        XCTAssertEqual(parsed.adapter, .highPower)
        XCTAssertNil(unknown.battery)
        XCTAssertNil(unknown.adapter)
    }

    func testServiceRunsOnlyFixedReadCommandsWithShortWatchdogs() async throws {
        let runner = RecordingBatteryHealthRunner(responses: [
            BatteryHealthService.profilerCommand: .success(batteryJSON(
                chargePercent: 65,
                maximumCapacity: "97%",
                cycleCount: 100,
                condition: "Normal",
                optimizedCharging: false
            )),
            BatteryHealthService.powerModesCommand: .success(Data(pmsetOutput(
                batteryMode: 0,
                adapterMode: 0
            ).utf8))
        ])
        let powerSample = internalPowerSample(
            chargePercent: 65,
            isCharging: false,
            source: .batteryPower
        )
        let sampledAt = sampledAt
        let service = BatteryHealthService(
            runner: runner,
            powerSampleProvider: { powerSample },
            now: { sampledAt }
        )

        let snapshot = try await service.snapshot()

        XCTAssertEqual(snapshot?.maximumCapacityPercent, 97)
        XCTAssertEqual(runner.commands, [
            BatteryHealthCommand(
                executable: "/usr/sbin/system_profiler",
                arguments: ["-json", "-detailLevel", "mini", "-timeout", "5", "SPPowerDataType"],
                timeout: 8
            ),
            BatteryHealthCommand(
                executable: "/usr/bin/pmset",
                arguments: ["-g", "custom"],
                timeout: 3
            )
        ])
        XCTAssertFalse(runner.commands.flatMap(\.arguments).contains("-b"))
        XCTAssertFalse(runner.commands.flatMap(\.arguments).contains("-c"))
        XCTAssertFalse(runner.commands.flatMap(\.arguments).contains("-a"))
    }

    func testRunnerFailuresNeverSurfaceRawCommandOutput() async throws {
        let runner = RecordingBatteryHealthRunner(defaultResponse: .failure(
            RawBatteryError(message: "TEST-RAW-BATTERY-SERIAL private-value")
        ))
        let powerSample = internalPowerSample(
            chargePercent: 44,
            isCharging: false,
            source: .batteryPower
        )
        let sampledAt = sampledAt
        let snapshot = try await BatteryHealthService(
            runner: runner,
            powerSampleProvider: { powerSample },
            now: { sampledAt }
        ).snapshot()

        let encoded = String(describing: snapshot)
        XCTAssertFalse(encoded.contains("TEST-RAW-BATTERY-SERIAL"))
        XCTAssertFalse(encoded.contains("private-value"))
        XCTAssertEqual(snapshot?.availability, .partial)
    }

    @MainActor
    func testSnapshotChecksCancellationBeforeStartingSecondFixedCommand() async throws {
        let runner = ManualBatteryHealthRunner()
        let powerSample = internalPowerSample(
            chargePercent: 65,
            isCharging: false,
            source: .batteryPower
        )
        let profilerData = batteryJSON(
            chargePercent: 65,
            maximumCapacity: "97%",
            cycleCount: 100,
            condition: "Normal",
            optimizedCharging: false
        )
        let sampledAt = sampledAt
        let service = BatteryHealthService(
            runner: runner,
            powerSampleProvider: { powerSample },
            now: { sampledAt }
        )

        let task = Task { try await service.snapshot() }
        await runner.waitForCommandCount(1)
        task.cancel()
        await runner.resumeNext(with: .success(profilerData))

        do {
            _ = try await task.value
            XCTFail("Cancelled sampling must not return a snapshot")
        } catch is CancellationError {
            // Expected: the second fixed command was never started.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [BatteryHealthService.profilerCommand])
    }

    @MainActor
    func testShellRunnerExecutesOffMainAndForwardsTaskCancellation() async throws {
        let probe = BatteryRunnerExecutionProbe()
        let runner = ShellBatteryHealthCommandRunner { command, cancellation in
            try probe.execute(command, cancellation: cancellation)
        }

        let task = Task { try await runner.capture(BatteryHealthService.profilerCommand) }
        let didStart = await probe.waitUntilStarted()
        XCTAssertTrue(didStart)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancelled command must not return output")
        } catch BatteryHealthCommandFailure.cancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(probe.didRunOffMainThread)
        XCTAssertTrue(probe.didObserveCancellation)
    }

    func testCancellableShellStopsSlowProcessTreeBeforeWatchdog() async {
        let cancellation = BatteryHealthCancellationFlag()
        let task = Task.detached {
            try Shell.captureCancellable(
                "/bin/sh",
                ["-c", "sleep 30"],
                timeout: 10,
                outputByteLimit: 1_024,
                cancellationCheck: { cancellation.isCancelled }
            )
        }
        try? await Task.sleep(for: .milliseconds(100))
        cancellation.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must terminate the running process tree")
        } catch ShellError.cancelled {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCancellableShellWaitsUntilBackgroundChildCannotMutate() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-shell-tree-\(UUID().uuidString)")
        let startedMarker = directory.appendingPathComponent("started")
        let mutationMarker = directory.appendingPathComponent("mutated")
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let cancellation = BatteryHealthCancellationFlag()
        let script = """
        (
          (
            trap '' TERM
            /usr/bin/touch '\(startedMarker.path)'
            /bin/sleep 0.4
            /usr/bin/touch '\(mutationMarker.path)'
          ) &
        ) &
        while [ ! -e '\(startedMarker.path)' ]; do /bin/sleep 0.01; done
        while :; do /bin/sleep 1; done
        """
        let task = Task.detached {
            try Shell.captureCancellable(
                "/bin/sh",
                ["-c", script],
                timeout: 5,
                outputByteLimit: 1_024,
                cancellationCheck: { cancellation.isCancelled }
            )
        }

        for _ in 0..<1_000 where !FileManager.default.fileExists(atPath: startedMarker.path) {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: startedMarker.path))
        cancellation.cancel()

        do {
            _ = try await task.value
            XCTFail("Cancellation must stop every captured child")
        } catch ShellError.cancelled {
            // Expected after verified process-tree exit.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mutationMarker.path))
    }

    func testShellLaunchesUserCodeInIndependentProcessGroup() throws {
        XCTAssertNotEqual(
            Shell.containedProcessSpawnFlags & Int16(POSIX_SPAWN_SETPGROUP),
            0
        )
        XCTAssertNotEqual(
            Shell.containedProcessSpawnFlags & Int16(POSIX_SPAWN_START_SUSPENDED),
            0
        )
        let output = try Shell.capture(
            "/bin/sh",
            [
                "-c",
                "root=$$; group=$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' '); /usr/bin/printf '%s %s' \"$root\" \"$group\""
            ],
            timeout: 2
        )
        let fields = output.split(separator: " ")

        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first, fields.last)
    }

    func testCancellableShellRejectsOutputPastItsReadLimit() {
        XCTAssertThrowsError(try Shell.captureCancellable(
            "/usr/bin/printf",
            [String(repeating: "x", count: 2_048)],
            timeout: 2,
            outputByteLimit: 128,
            cancellationCheck: { false }
        )) { error in
            guard case ShellError.outputTooLarge = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testAlreadyCancelledShellDoesNotLaunchProcess() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-shell-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }

        XCTAssertThrowsError(try Shell.captureCancellable(
            "/usr/bin/touch",
            [marker.path],
            timeout: 2,
            outputByteLimit: 128,
            cancellationCheck: { true }
        )) { error in
            guard case ShellError.cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testShellRechecksCancellationImmediatelyBeforeLaunch() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-shell-race-\(UUID().uuidString)")
        let cancellation = CancellationCheckSequence(cancelOnCheck: 2)
        defer { try? FileManager.default.removeItem(at: marker) }

        XCTAssertThrowsError(try Shell.captureCancellable(
            "/usr/bin/touch",
            [marker.path],
            timeout: 2,
            outputByteLimit: 128,
            cancellationCheck: { cancellation.check() }
        )) { error in
            guard case ShellError.cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertGreaterThanOrEqual(cancellation.checkCount, 2)
    }

    func testTerminationWithUnknownLaunchIdentityNeverSignals() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        let signalProbe = ShellTerminationSignalProbe()
        defer {
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        let didTerminate = Shell.terminate(
            process,
            launchedIdentity: nil,
            finished: DispatchSemaphore(value: 0),
            signals: Shell.TerminationSignalOperations(
                processTree: { _, _, _ in signalProbe.recordSignal() },
                processes: { _, _ in signalProbe.recordSignal() }
            )
        )

        XCTAssertFalse(didTerminate)
        XCTAssertEqual(signalProbe.signalCount, 0)
        XCTAssertTrue(process.isRunning)
    }

    func testTerminateWaitsForEveryCapturedDescendantIdentity() {
        let process = Process()
        let root = Shell.ProcessIdentity(
            processID: 100,
            startSeconds: 10,
            startMicroseconds: 20
        )
        let descendant = Shell.ProcessIdentity(
            processID: 101,
            startSeconds: 11,
            startMicroseconds: 21
        )
        let probe = ShellProcessTreeExitProbe(
            presences: [.sameProcessRunning, .sameProcessRunning, .exited],
            monotonicTimes: [0, 10_000_000, 20_000_000, 30_000_000]
        )

        let didTerminate = Shell.terminate(
            process,
            launchedIdentity: root,
            finished: DispatchSemaphore(value: 0),
            signals: Shell.TerminationSignalOperations(
                processTree: { _, _, _ in },
                processes: { _, _ in }
            ),
            descendantIdentities: [descendant],
            processTreeExitTimeout: 1,
            exitOperations: probe.operations
        )

        XCTAssertTrue(didTerminate)
        XCTAssertEqual(probe.presenceCheckCount, 3)
        XCTAssertEqual(probe.pauseCount, 2)
    }

    func testTerminateBoundsUnknownDescendantVerification() {
        let process = Process()
        let root = Shell.ProcessIdentity(
            processID: 200,
            startSeconds: 20,
            startMicroseconds: 30
        )
        let descendant = Shell.ProcessIdentity(
            processID: 201,
            startSeconds: 21,
            startMicroseconds: 31
        )
        let probe = ShellProcessTreeExitProbe(
            presences: [.unknown, .unknown, .unknown],
            monotonicTimes: [0, 600_000_000, 1_200_000_000]
        )

        let didTerminate = Shell.terminate(
            process,
            launchedIdentity: root,
            finished: DispatchSemaphore(value: 0),
            signals: Shell.TerminationSignalOperations(
                processTree: { _, _, _ in },
                processes: { _, _ in }
            ),
            descendantIdentities: [descendant],
            processTreeExitTimeout: 1,
            exitOperations: probe.operations
        )

        XCTAssertFalse(didTerminate)
        XCTAssertLessThanOrEqual(probe.pauseCount, 2)
    }

    func testTerminateDiscoversGrowingDescendantsAndSignalsOnlyVerifiedIdentities() {
        let process = Process()
        let root = Shell.ProcessIdentity(
            processID: 300,
            startSeconds: 30,
            startMicroseconds: 40
        )
        let child = Shell.ProcessIdentity(
            processID: 301,
            startSeconds: 31,
            startMicroseconds: 41
        )
        let grandchild = Shell.ProcessIdentity(
            processID: 302,
            startSeconds: 32,
            startMicroseconds: 42
        )
        let reusedPID = Shell.ProcessIdentity(
            processID: 303,
            startSeconds: 33,
            startMicroseconds: 43
        )
        let probe = ShellGrowingProcessTreeProbe(
            child: child,
            discoveredDescendants: [grandchild, reusedPID],
            emptyChildScansBeforeDiscovery: 1,
            presenceSequences: [
                child: [.sameProcessRunning, .exited],
                grandchild: [.unknown, .sameProcessRunning, .exited],
                reusedPID: [.pidReused]
            ]
        )

        let didTerminate = Shell.terminate(
            process,
            launchedIdentity: root,
            finished: DispatchSemaphore(value: 0),
            signals: Shell.TerminationSignalOperations(
                processTree: { _, _, _ in },
                processes: { identities, _ in probe.recordSignals(identities) }
            ),
            descendantIdentities: [child],
            trackDescendants: { probe.recordTracked($0) },
            processTreeExitTimeout: 1,
            exitOperations: probe.operations
        )

        XCTAssertTrue(didTerminate)
        XCTAssertTrue(probe.trackedIdentities.contains(grandchild))
        XCTAssertTrue(probe.trackedIdentities.contains(reusedPID))
        XCTAssertTrue(probe.signalledIdentities.contains(grandchild))
        XCTAssertFalse(probe.signalledIdentities.contains(reusedPID))
    }

    func testProcessGroupBarrierFindsLateReparentedMemberBeforeQuietRelease() {
        let root = Shell.ProcessIdentity(
            processID: 400,
            startSeconds: 40,
            startMicroseconds: 50
        )
        let lateMember = Shell.ProcessIdentity(
            processID: 401,
            startSeconds: 41,
            startMicroseconds: 51
        )
        let probe = ShellProcessGroupExitProbe(
            memberSnapshots: [[], [lateMember], [], []],
            presences: [
                root: [.exited, .exited, .exited, .exited],
                lateMember: [.sameProcessRunning, .exited, .exited]
            ]
        )

        let didExit = Shell.waitForProcessGroupExit(
            processGroupID: root.processID,
            rootIdentity: root,
            initiallyTracked: [root],
            timeout: 1,
            quietInterval: 0.01,
            operations: probe.operations,
            onDiscovered: { probe.recordTracked($0) },
            onVerifiedRunning: { probe.recordSignals($0) }
        )

        XCTAssertTrue(didExit)
        XCTAssertGreaterThanOrEqual(probe.memberScanCount, 4)
        XCTAssertTrue(probe.trackedIdentities.contains(lateMember))
        XCTAssertTrue(probe.signalledIdentities.contains(lateMember))
    }

    func testProcessGroupBarrierRejectsKnownMemberWithUnreadableIdentity() {
        let root = Shell.ProcessIdentity(
            processID: 500,
            startSeconds: 50,
            startMicroseconds: 60
        )
        let membershipOperations = Shell.ProcessGroupMembershipOperations(
            processIDs: { _ in [501] },
            processGroupID: { _ in root.processID },
            witness: { _ in nil }
        )
        let discoveryIncomplete = BatteryHealthCancellationFlag()

        let didExit = Shell.waitForProcessGroupExit(
            processGroupID: root.processID,
            rootIdentity: root,
            initiallyTracked: [root],
            timeout: 1,
            operations: Shell.ProcessGroupExitOperations(
                members: { processGroupID in
                    Shell.processGroupIdentities(
                        processGroupID: processGroupID,
                        operations: membershipOperations
                    )
                },
                presence: { _ in .exited },
                monotonicNow: { UInt64.max },
                pause: { _ in }
            ),
            onDiscoveryIncomplete: {
                discoveryIncomplete.cancel()
            }
        )

        XCTAssertFalse(didExit)
        XCTAssertTrue(discoveryIncomplete.isCancelled)
    }

    func testProcessGroupSnapshotUsesAtomicWitnessBeforeMemberLeavesGroup() {
        let root = Shell.ProcessIdentity(
            processID: 550,
            startSeconds: 55,
            startMicroseconds: 65
        )
        let witnessedMember = Shell.ProcessIdentity(
            processID: 551,
            startSeconds: 56,
            startMicroseconds: 66
        )
        let operations = Shell.ProcessGroupMembershipOperations(
            processIDs: { requestedGroupID in
                requestedGroupID == root.processID ? [witnessedMember.processID] : nil
            },
            processGroupID: { _ in -1 },
            witness: { _ in
                Shell.ProcessGroupWitness(
                    identity: witnessedMember,
                    processGroupID: root.processID
                )
            }
        )

        let snapshot = Shell.processGroupIdentities(
            processGroupID: root.processID,
            operations: operations
        )

        XCTAssertEqual(snapshot, [witnessedMember])
    }

    func testLiveProcessGroupQueryReturnsCurrentProcessFromRequestedGroup() throws {
        let groupID = getpgrp()
        let processIDs = try XCTUnwrap(
            Shell.processGroupProcessIDs(processGroupID: groupID)
        )

        XCTAssertTrue(processIDs.contains(getpid()))
        XCTAssertNil(Shell.processGroupProcessIDs(processGroupID: 1))
    }

    func testProcessGroupSnapshotNeverAdoptsReusedPIDFromAnotherGroup() {
        let root = Shell.ProcessIdentity(
            processID: 575,
            startSeconds: 57,
            startMicroseconds: 67
        )
        let replacement = Shell.ProcessIdentity(
            processID: 576,
            startSeconds: 99,
            startMicroseconds: 1
        )
        let operations = Shell.ProcessGroupMembershipOperations(
            processIDs: { _ in [replacement.processID] },
            processGroupID: { _ in root.processID },
            witness: { _ in
                Shell.ProcessGroupWitness(
                    identity: replacement,
                    processGroupID: 999
                )
            }
        )

        let snapshot = Shell.processGroupIdentities(
            processGroupID: root.processID,
            operations: operations
        )

        XCTAssertEqual(snapshot, [])
    }

    func testProcessGroupBarrierKeepsPreviouslyCapturedMemberAfterItLeavesGroup() {
        let root = Shell.ProcessIdentity(
            processID: 600,
            startSeconds: 60,
            startMicroseconds: 70
        )
        let escapedMember = Shell.ProcessIdentity(
            processID: 601,
            startSeconds: 61,
            startMicroseconds: 71
        )
        let lifecycle = Shell.POSIXProcessGroupCleanupLifecycle(
            testingRootIdentity: root,
            processGroupID: root.processID,
            memberSnapshot: { _ in [] },
            presence: { _ in .exited }
        )
        lifecycle.updateTrackedMembers([escapedMember])
        let probe = ShellProcessGroupExitProbe(
            memberSnapshots: [[], [], []],
            presences: [
                root: [.exited, .exited, .exited],
                escapedMember: [.sameProcessRunning, .exited, .exited]
            ]
        )

        let didExit = Shell.waitForProcessGroupExit(
            processGroupID: root.processID,
            rootIdentity: root,
            initiallyTracked: lifecycle.trackedMemberSnapshot(),
            timeout: 1,
            quietInterval: 0.01,
            operations: probe.operations,
            additionalTracked: { lifecycle.trackedMemberSnapshot() },
            onVerifiedRunning: { probe.recordSignals($0) }
        )

        XCTAssertTrue(didExit)
        XCTAssertTrue(probe.signalledIdentities.contains(escapedMember))
    }

    func testProcessGroupCleanupLifecycleNeverReleasesAfterIncompleteDiscovery() {
        let root = Shell.ProcessIdentity(
            processID: 700,
            startSeconds: 70,
            startMicroseconds: 80
        )
        let lifecycle = Shell.POSIXProcessGroupCleanupLifecycle(
            testingRootIdentity: root,
            processGroupID: root.processID,
            memberSnapshot: { _ in [] },
            presence: { _ in .exited }
        )
        lifecycle.markDiscoveryIncomplete()

        XCTAssertEqual(lifecycle.cleanupPresence(), .unknown)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(lifecycle.cleanupPresence(), .unknown)
        XCTAssertFalse(lifecycle.hasCompleteDiscovery)
    }

    func testCleanupReaperImmediatelyReleasesExitedAndReusedProcesses() {
        for presence in [ShellProcessPresence.exited, .pidReused] {
            let scheduler = ManualShellCleanupScheduler()
            let lifecycle = FakeShellCleanupLifecycle(presence: presence)
            let reaper = ShellProcessCleanupReaper(
                retryDelay: 1,
                maximumRetryCount: 2,
                schedule: { delay, operation in
                    scheduler.schedule(after: delay, operation: operation.run)
                }
            )

            reaper.retain(lifecycle)

            XCTAssertFalse(lifecycle.isRetainingProcess)
            XCTAssertEqual(lifecycle.signalCount, 0)
            XCTAssertEqual(lifecycle.releaseCount, 1)
            XCTAssertEqual(scheduler.scheduledCount, 0)
            XCTAssertFalse(reaper.hasPendingCleanup)
        }
    }

    func testCleanupReaperQuarantinesUnknownPresenceAfterForegroundRetryBudget() {
        let scheduler = ManualShellCleanupScheduler()
        let lifecycle = FakeShellCleanupLifecycle(presence: .unknown)
        let reaper = ShellProcessCleanupReaper(
            retryDelay: 1,
            maximumRetryCount: 2,
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation: operation.run)
            }
        )

        reaper.retain(lifecycle)
        XCTAssertTrue(lifecycle.isRetainingProcess)
        XCTAssertTrue(reaper.hasPendingCleanup)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        scheduler.runNext()
        XCTAssertEqual(lifecycle.signalCount, 0)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        scheduler.runNext()
        XCTAssertEqual(lifecycle.signalCount, 0)
        XCTAssertEqual(lifecycle.releaseCount, 0)
        XCTAssertTrue(lifecycle.isRetainingProcess)
        XCTAssertTrue(reaper.hasPendingCleanup)
        XCTAssertTrue(reaper.hasExhaustedCleanup)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        lifecycle.setPresence(.exited)
        scheduler.runNext()
        XCTAssertEqual(lifecycle.releaseCount, 1)
        XCTAssertFalse(lifecycle.isRetainingProcess)
        XCTAssertFalse(reaper.hasPendingCleanup)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func testCleanupReaperKeepsSameProcessQuarantinedUntilVerifiedExit() {
        let scheduler = ManualShellCleanupScheduler()
        let lifecycle = FakeShellCleanupLifecycle(presence: .sameProcessRunning)
        let reaper = ShellProcessCleanupReaper(
            retryDelay: 1,
            maximumRetryCount: 2,
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation: operation.run)
            }
        )

        reaper.retain(lifecycle)
        XCTAssertTrue(lifecycle.isRetainingProcess)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        scheduler.runNext()
        XCTAssertEqual(lifecycle.signalCount, 1)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        scheduler.runNext()
        XCTAssertEqual(lifecycle.signalCount, 2)
        XCTAssertEqual(lifecycle.releaseCount, 0)
        XCTAssertTrue(lifecycle.isRetainingProcess)
        XCTAssertTrue(reaper.hasPendingCleanup)
        XCTAssertTrue(reaper.hasExhaustedCleanup)
        XCTAssertEqual(scheduler.scheduledCount, 1)

        lifecycle.setPresence(.pidReused)
        scheduler.runNext()
        XCTAssertEqual(lifecycle.signalCount, 2)
        XCTAssertEqual(lifecycle.releaseCount, 1)
        XCTAssertFalse(lifecycle.isRetainingProcess)
        XCTAssertFalse(reaper.hasPendingCleanup)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func testCleanupReaperTerminationCallbackCancelsQueuedRetryAndReleases() {
        let scheduler = ManualShellCleanupScheduler()
        let lifecycle = FakeShellCleanupLifecycle(presence: .sameProcessRunning)
        let reaper = ShellProcessCleanupReaper(
            retryDelay: 1,
            maximumRetryCount: 3,
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation: operation.run)
            }
        )

        reaper.retain(lifecycle)
        reaper.processDidTerminate(lifecycle.cleanupID)
        scheduler.runNext()

        XCTAssertEqual(lifecycle.signalCount, 0)
        XCTAssertEqual(lifecycle.releaseCount, 1)
        XCTAssertFalse(lifecycle.isRetainingProcess)
        XCTAssertFalse(reaper.hasPendingCleanup)
        XCTAssertEqual(scheduler.scheduledCount, 0)
    }

    func testBatteryShellCleanupGateBlocksLaunchUntilCleanupCallback() throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-shell-gate-\(UUID().uuidString)")
        let scheduler = ManualShellCleanupScheduler()
        let lifecycle = FakeShellCleanupLifecycle(presence: .sameProcessRunning)
        let reaper = ShellProcessCleanupReaper(
            retryDelay: 1,
            maximumRetryCount: 2,
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation: operation.run)
            }
        )
        defer { try? FileManager.default.removeItem(at: marker) }

        reaper.retain(lifecycle)
        let waitStartedAt = Date()
        XCTAssertThrowsError(try Shell.captureCancellable(
            "/usr/bin/touch",
            [marker.path],
            timeout: 2,
            outputByteLimit: 128,
            cancellationCheck: { false },
            cleanupReaper: reaper,
            cleanupWaitTimeout: 0.02
        )) { error in
            guard case ShellError.cleanupPending = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(waitStartedAt), 0.5)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))

        reaper.processDidTerminate(lifecycle.cleanupID)
        _ = try Shell.captureCancellable(
            "/usr/bin/touch",
            [marker.path],
            timeout: 2,
            outputByteLimit: 128,
            cancellationCheck: { false },
            cleanupReaper: reaper,
            cleanupWaitTimeout: 0
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testBatteryShellCleanupGateWaitIsCancellableWithoutLaunching() {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageCleanerMac-shell-gate-cancel-\(UUID().uuidString)")
        let scheduler = ManualShellCleanupScheduler()
        let lifecycle = FakeShellCleanupLifecycle(presence: .unknown)
        let cancellation = CancellationCheckSequence(cancelOnCheck: 2)
        let reaper = ShellProcessCleanupReaper(
            retryDelay: 1,
            maximumRetryCount: 2,
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation: operation.run)
            }
        )
        defer { try? FileManager.default.removeItem(at: marker) }

        reaper.retain(lifecycle)
        XCTAssertThrowsError(try Shell.captureCancellable(
            "/usr/bin/touch",
            [marker.path],
            timeout: 2,
            outputByteLimit: 128,
            cancellationCheck: { cancellation.check() },
            cleanupReaper: reaper,
            cleanupWaitTimeout: 1
        )) { error in
            guard case ShellError.cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertGreaterThanOrEqual(cancellation.checkCount, 2)
    }

    @MainActor
    func testBatteryHealthServiceSkipsPhysicalSamplingWhileCleanupLeasePending() async throws {
        let scheduler = ManualShellCleanupScheduler()
        let lifecycle = FakeShellCleanupLifecycle(presence: .unknown)
        let reaper = ShellProcessCleanupReaper(
            retryDelay: 1,
            maximumRetryCount: 2,
            schedule: { delay, operation in
                scheduler.schedule(after: delay, operation: operation.run)
            }
        )
        let runner = ShellBatteryHealthCommandRunner(
            cleanupReaper: reaper,
            cleanupWaitTimeout: 0
        )
        let sampledAt = sampledAt
        let service = BatteryHealthService(
            runner: runner,
            powerSampleProvider: { nil },
            now: { sampledAt }
        )

        reaper.retain(lifecycle)
        let snapshot = try await service.snapshot()

        XCTAssertNil(snapshot)
        XCTAssertTrue(reaper.hasPendingCleanup)
        XCTAssertTrue(lifecycle.isRetainingProcess)
        XCTAssertEqual(lifecycle.signalCount, 0)
        XCTAssertEqual(scheduler.scheduledCount, 1)
    }

    @MainActor
    func testLatestSnapshotWaitsForCancelledSamplingBeforeStarting() async throws {
        let runner = ManualBatteryHealthRunner()
        let powerSample = internalPowerSample(
            chargePercent: 65,
            isCharging: false,
            source: .batteryPower
        )
        let profilerData = batteryJSON(
            chargePercent: 65,
            maximumCapacity: "97%",
            cycleCount: 100,
            condition: "Normal",
            optimizedCharging: false
        )
        let sampledAt = sampledAt
        let service = BatteryHealthService(
            runner: runner,
            powerSampleProvider: { powerSample },
            now: { sampledAt }
        )

        let first = Task { try await service.snapshot() }
        await runner.waitForCommandCount(1)
        let latest = Task { try await service.snapshot() }
        for _ in 0..<20 { await Task.yield() }
        let commandCountBeforeRelease = await runner.recordedCommands().count
        XCTAssertEqual(commandCountBeforeRelease, 1)

        await runner.resumeNext(with: .success(profilerData))
        do {
            _ = try await first.value
            XCTFail("Superseded sampling must be cancelled")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        await runner.waitForCommandCount(2)
        await runner.resumeNext(with: .success(profilerData))
        await runner.waitForCommandCount(3)
        await runner.resumeNext(with: .success(Data(pmsetOutput(
            batteryMode: 0,
            adapterMode: 0
        ).utf8)))

        let snapshot = try await latest.value
        XCTAssertEqual(snapshot?.maximumCapacityPercent, 97)
        let maximumActive = await runner.maximumActiveCaptureCount()
        XCTAssertEqual(maximumActive, 1)
    }

    @MainActor
    func testCompletedSampleCannotPublishAfterNewGenerationBegins() async throws {
        let profilerData = batteryJSON(
            chargePercent: 65,
            maximumCapacity: "97%",
            cycleCount: 100,
            condition: "Normal",
            optimizedCharging: false
        )
        let runner = RecordingBatteryHealthRunner(responses: [
            BatteryHealthService.profilerCommand: .success(profilerData),
            BatteryHealthService.powerModesCommand: .success(Data(pmsetOutput(
                batteryMode: 0,
                adapterMode: 0
            ).utf8))
        ])
        let barrier = FirstBatteryPublicationBarrier()
        let sampledAt = sampledAt
        let service = BatteryHealthService(
            runner: runner,
            powerSampleProvider: {
                BatteryPowerSample(
                    snapshot: BatteryPowerSnapshot(
                        chargePercent: 65,
                        isCharging: false,
                        powerSource: .batteryPower,
                        timeToEmptyMinutes: 120,
                        timeToFullChargeMinutes: nil
                    ),
                    provenance: .internalBattery
                )
            },
            now: { sampledAt },
            beforeSnapshotPublication: { await barrier.pauseFirstPublication() }
        )

        let superseded = Task { try await service.snapshot() }
        await barrier.waitForPublicationCount(1)
        let newest = Task { try await service.snapshot() }
        await barrier.waitForPublicationCount(2)

        let newestSnapshot = try await newest.value
        XCTAssertEqual(newestSnapshot?.maximumCapacityPercent, 97)
        await barrier.releaseFirstPublication()

        do {
            _ = try await superseded.value
            XCTFail("A completed sample from an older generation must not publish")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testCancelledSnapshotCannotPublishCompletedSample() async throws {
        let profilerData = batteryJSON(
            chargePercent: 65,
            maximumCapacity: "97%",
            cycleCount: 100,
            condition: "Normal",
            optimizedCharging: false
        )
        let runner = RecordingBatteryHealthRunner(responses: [
            BatteryHealthService.profilerCommand: .success(profilerData),
            BatteryHealthService.powerModesCommand: .success(Data(pmsetOutput(
                batteryMode: 0,
                adapterMode: 0
            ).utf8))
        ])
        let barrier = FirstBatteryPublicationBarrier()
        let sampledAt = sampledAt
        let service = BatteryHealthService(
            runner: runner,
            powerSampleProvider: { nil },
            now: { sampledAt },
            beforeSnapshotPublication: { await barrier.pauseFirstPublication() }
        )

        let request = Task { try await service.snapshot() }
        await barrier.waitForPublicationCount(1)
        request.cancel()
        await barrier.releaseFirstPublication()

        do {
            _ = try await request.value
            XCTFail("A cancelled request must not publish an already completed sample")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testSettingsVerifierReportsSuccessOnlyWhenPowerModeChanges() async {
        let baseline = healthSnapshot(chargePercent: 50, batteryMode: .automatic)
        let chargeOnlyChange = healthSnapshot(chargePercent: 51, batteryMode: .automatic)
        let modeChange = healthSnapshot(chargePercent: 52, batteryMode: .lowPower)
        let reader = SnapshotSequenceReader([baseline, chargeOnlyChange, modeChange, baseline])
        let opener = RecordingBatterySettingsOpener(result: true)
        let verifier = BatterySettingsVerifier(
            reader: { reader.next() },
            opener: opener
        )

        let didOpen = await verifier.beginAdjustment()
        let chargeOnlyWasVerified = await verifier.verifyAfterSettingsChange()
        let modeChangeWasVerified = await verifier.verifyAfterSettingsChange()
        let verificationAfterSuccess = await verifier.verifyAfterSettingsChange()
        XCTAssertEqual(didOpen, .opened)
        XCTAssertEqual(chargeOnlyWasVerified, .unchanged)
        XCTAssertEqual(modeChangeWasVerified, .changed)
        XCTAssertEqual(verificationAfterSuccess, .unverifiable)
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(opener.lastURL?.absoluteString, BatterySettingsVerifier.settingsURL.absoluteString)
    }

    @MainActor
    func testSettingsVerifierIgnoresHealthChangesAndExpires() async {
        let baseline = healthSnapshot(chargePercent: 50, batteryMode: .automatic)
        let healthChange = BatteryHealthSnapshot(
            availability: .available,
            status: .actionRequired,
            currentChargePercent: 49,
            isCharging: false,
            maximumCapacityPercent: 79,
            cycleCount: 900,
            condition: .serviceRecommended,
            batteryPowerMode: .automatic,
            adapterPowerMode: .automatic,
            guidance: BatteryGuidance(kind: .serviceRecommended),
            sampledAt: sampledAt.addingTimeInterval(10)
        )
        var clock = sampledAt
        let reader = SnapshotSequenceReader([baseline, healthChange])
        let opener = RecordingBatterySettingsOpener(result: true)
        let verifier = BatterySettingsVerifier(
            reader: { reader.next() },
            opener: opener,
            now: { clock },
            verificationWindow: 30
        )

        let didOpen = await verifier.beginAdjustment()
        let healthChangeWasVerified = await verifier.verifyAfterSettingsChange()
        clock = sampledAt.addingTimeInterval(31)
        let expiredVerification = await verifier.verifyAfterSettingsChange()

        XCTAssertEqual(didOpen, .opened)
        XCTAssertEqual(healthChangeWasVerified, .unchanged)
        XCTAssertEqual(expiredVerification, .expired)
    }

    @MainActor
    func testSettingsVerifierIgnoresPowerModeBecomingReadable() async {
        let baseline = healthSnapshot(
            chargePercent: 50,
            batteryMode: nil,
            adapterMode: .automatic
        )
        let newlyReadable = healthSnapshot(
            chargePercent: 50,
            batteryMode: .automatic,
            adapterMode: .automatic
        )
        let confirmedAdapterChange = healthSnapshot(
            chargePercent: 50,
            batteryMode: .automatic,
            adapterMode: .lowPower
        )
        let reader = SnapshotSequenceReader([baseline, newlyReadable, confirmedAdapterChange])
        let verifier = BatterySettingsVerifier(
            reader: { reader.next() },
            opener: RecordingBatterySettingsOpener(result: true)
        )

        let didOpen = await verifier.beginAdjustment()
        let availabilityOnlyChange = await verifier.verifyAfterSettingsChange()
        let confirmedChange = await verifier.verifyAfterSettingsChange()

        XCTAssertEqual(didOpen, .opened)
        XCTAssertEqual(availabilityOnlyChange, .unchanged)
        XCTAssertEqual(confirmedChange, .changed)
    }

    @MainActor
    func testSettingsVerifierIgnoresPowerModeBecomingUnreadable() async {
        let baseline = healthSnapshot(
            chargePercent: 50,
            batteryMode: .automatic,
            adapterMode: .automatic
        )
        let temporarilyUnreadable = healthSnapshot(
            chargePercent: 50,
            batteryMode: nil,
            adapterMode: .lowPower
        )
        let newBaseline = healthSnapshot(
            chargePercent: 50,
            batteryMode: .automatic,
            adapterMode: .automatic
        )
        let confirmedBatteryChange = healthSnapshot(
            chargePercent: 50,
            batteryMode: .lowPower,
            adapterMode: .automatic
        )
        let reader = SnapshotSequenceReader([
            baseline,
            temporarilyUnreadable,
            newBaseline,
            confirmedBatteryChange
        ])
        let verifier = BatterySettingsVerifier(
            reader: { reader.next() },
            opener: RecordingBatterySettingsOpener(result: true)
        )

        let didOpen = await verifier.beginAdjustment()
        let availabilityOnlyChange = await verifier.verifyAfterSettingsChange()
        let reopened = await verifier.beginAdjustment()
        let confirmedChange = await verifier.verifyAfterSettingsChange()

        XCTAssertEqual(didOpen, .opened)
        XCTAssertEqual(availabilityOnlyChange, .unverifiable)
        XCTAssertEqual(reopened, .opened)
        XCTAssertEqual(confirmedChange, .changed)
    }

    @MainActor
    func testSettingsVerifierDoesNotOpenWithoutAnyReadablePowerModeBaseline() async {
        let unreadable = healthSnapshot(
            chargePercent: 50,
            batteryMode: nil,
            adapterMode: nil
        )
        let opener = RecordingBatterySettingsOpener(result: true)
        let verifier = BatterySettingsVerifier(
            reader: { unreadable },
            opener: opener
        )

        let begin = await verifier.beginAdjustment()
        let verification = await verifier.verifyAfterSettingsChange()

        XCTAssertEqual(begin, .baselineUnavailable)
        XCTAssertEqual(verification, .unverifiable)
        XCTAssertEqual(opener.openCount, 0)
    }

    @MainActor
    func testSettingsVerifierOpensUnverifiedGuidanceWithoutCreatingABaseline() async {
        let unreadable = healthSnapshot(
            chargePercent: 50,
            batteryMode: nil,
            adapterMode: nil
        )
        let opener = RecordingBatterySettingsOpener(result: true)
        let verifier = BatterySettingsVerifier(
            reader: { unreadable },
            opener: opener
        )

        let begin = await verifier.beginAdjustment()
        let guidanceOpened = verifier.openSettingsWithoutVerification()
        let verification = await verifier.verifyAfterSettingsChange()

        XCTAssertEqual(begin, .baselineUnavailable)
        XCTAssertTrue(guidanceOpened)
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertEqual(opener.lastURL, BatterySettingsVerifier.settingsURL)
        XCTAssertEqual(verification, .unverifiable)
    }

    @MainActor
    func testSettingsVerifierExpiresAfterFiveMinuteWindowAndCanReestablishBaseline() async {
        let baseline = healthSnapshot(chargePercent: 50, batteryMode: .automatic)
        let changed = healthSnapshot(chargePercent: 50, batteryMode: .lowPower)
        let reader = SnapshotSequenceReader([baseline, baseline, changed])
        var clock = sampledAt
        let verifier = BatterySettingsVerifier(
            reader: { reader.next() },
            opener: RecordingBatterySettingsOpener(result: true),
            now: { clock },
            verificationWindow: 300
        )

        let firstBegin = await verifier.beginAdjustment()
        XCTAssertEqual(firstBegin, .opened)
        clock = sampledAt.addingTimeInterval(301)
        let expired = await verifier.verifyAfterSettingsChange()
        XCTAssertEqual(expired, .expired)
        let secondBegin = await verifier.beginAdjustment()
        XCTAssertEqual(secondBegin, .opened)
        let changedResult = await verifier.verifyAfterSettingsChange()
        XCTAssertEqual(changedResult, .changed)
    }

    @MainActor
    func testSettingsVerifierDoesNotStartVerificationWhenSettingsFailToOpen() async {
        let reader = SnapshotSequenceReader([healthSnapshot(chargePercent: 50, batteryMode: .automatic)])
        let opener = RecordingBatterySettingsOpener(result: false)
        let verifier = BatterySettingsVerifier(reader: { reader.next() }, opener: opener)

        let didOpen = await verifier.beginAdjustment()
        let didVerify = await verifier.verifyAfterSettingsChange()
        XCTAssertEqual(didOpen, .failedToOpen)
        XCTAssertEqual(didVerify, .unverifiable)
    }

    @MainActor
    func testSettingsVerifierNewestBeginWinsWhenReadersResumeOutOfOrder() async {
        let oldBaseline = healthSnapshot(chargePercent: 50, batteryMode: .highPower)
        let newBaseline = healthSnapshot(chargePercent: 50, batteryMode: .automatic)
        let newMode = healthSnapshot(chargePercent: 50, batteryMode: .lowPower)
        let reader = ControlledSnapshotReader()
        let opener = RecordingBatterySettingsOpener(result: true)
        let verifier = BatterySettingsVerifier(
            reader: { await reader.next() },
            opener: opener
        )

        let oldBegin = Task { await verifier.beginAdjustment() }
        await reader.waitForRequestCount(1)
        let newestBegin = Task { await verifier.beginAdjustment() }
        await reader.waitForRequestCount(2)

        reader.resumeRequest(at: 1, with: newBaseline)
        let newestDidOpen = await newestBegin.value
        reader.resumeRequest(at: 0, with: oldBaseline)
        let oldDidOpen = await oldBegin.value

        XCTAssertEqual(newestDidOpen, .opened)
        XCTAssertEqual(oldDidOpen, .superseded)
        XCTAssertEqual(opener.openCount, 1)

        let verify = Task { await verifier.verifyAfterSettingsChange() }
        await reader.waitForRequestCount(3)
        reader.resumeRequest(at: 2, with: newMode)
        let didVerify = await verify.value
        XCTAssertEqual(didVerify, .changed)
    }

    @MainActor
    func testSettingsVerifierStaleVerifyCannotClearNewBeginSession() async {
        let firstBaseline = healthSnapshot(chargePercent: 50, batteryMode: .automatic)
        let oldModeChange = healthSnapshot(chargePercent: 50, batteryMode: .highPower)
        let newBaseline = healthSnapshot(chargePercent: 50, batteryMode: .lowPower)
        let newModeChange = healthSnapshot(chargePercent: 50, batteryMode: .automatic)
        let reader = ControlledSnapshotReader()
        let verifier = BatterySettingsVerifier(
            reader: { await reader.next() },
            opener: RecordingBatterySettingsOpener(result: true)
        )

        let firstBegin = Task { await verifier.beginAdjustment() }
        await reader.waitForRequestCount(1)
        reader.resumeRequest(at: 0, with: firstBaseline)
        let firstDidOpen = await firstBegin.value
        XCTAssertEqual(firstDidOpen, .opened)

        let staleVerify = Task { await verifier.verifyAfterSettingsChange() }
        await reader.waitForRequestCount(2)
        let newBegin = Task { await verifier.beginAdjustment() }
        await reader.waitForRequestCount(3)
        reader.resumeRequest(at: 2, with: newBaseline)
        let newDidOpen = await newBegin.value
        XCTAssertEqual(newDidOpen, .opened)

        reader.resumeRequest(at: 1, with: oldModeChange)
        let staleResult = await staleVerify.value
        XCTAssertEqual(staleResult, .unverifiable)

        let newVerify = Task { await verifier.verifyAfterSettingsChange() }
        await reader.waitForRequestCount(4)
        reader.resumeRequest(at: 3, with: newModeChange)
        let newResult = await newVerify.value
        XCTAssertEqual(newResult, .changed)
    }

    private func powerSnapshot(
        chargePercent: Int,
        isCharging: Bool,
        source: BatteryPowerSource
    ) -> BatteryPowerSnapshot {
        BatteryPowerSnapshot(
            chargePercent: chargePercent,
            isCharging: isCharging,
            powerSource: source,
            timeToEmptyMinutes: source == .batteryPower ? 120 : nil,
            timeToFullChargeMinutes: nil
        )
    }

    private func internalPowerSample(
        chargePercent: Int,
        isCharging: Bool,
        source: BatteryPowerSource
    ) -> BatteryPowerSample {
        BatteryPowerSample(
            snapshot: powerSnapshot(
                chargePercent: chargePercent,
                isCharging: isCharging,
                source: source
            ),
            provenance: .internalBattery
        )
    }

    private func healthSnapshot(
        chargePercent: Int,
        batteryMode: BatteryPowerMode?,
        adapterMode: BatteryPowerMode? = .automatic
    ) -> BatteryHealthSnapshot {
        BatteryHealthSnapshot(
            availability: .available,
            status: .healthy,
            currentChargePercent: chargePercent,
            isCharging: false,
            maximumCapacityPercent: 98,
            cycleCount: 50,
            condition: .normal,
            batteryPowerMode: batteryMode,
            adapterPowerMode: adapterMode,
            guidance: BatteryGuidance(kind: .none),
            sampledAt: sampledAt
        )
    }

    private func batteryJSON(
        chargePercent: Int,
        maximumCapacity: String?,
        cycleCount: Int?,
        condition: String?,
        optimizedCharging: Bool?
    ) -> Data {
        var health = [String: Any]()
        if let maximumCapacity {
            health["sppower_battery_health_maximum_capacity"] = maximumCapacity
        }
        if let cycleCount {
            health["sppower_battery_cycle_count"] = cycleCount
        }
        if let condition {
            health["sppower_battery_health"] = condition
        }
        var charge: [String: Any] = [
            "sppower_battery_state_of_charge": "\(chargePercent)%",
            "sppower_battery_is_charging": false
        ]
        if let optimizedCharging {
            charge["sppower_battery_optimized_charging"] = optimizedCharging
        }
        return try! JSONSerialization.data(withJSONObject: [
            "SPPowerDataType": [[
                "sppower_battery_charge_info": charge,
                "sppower_battery_health_info": health
            ]]
        ])
    }

    private func pmsetOutput(batteryMode: Int, adapterMode: Int) -> String {
        """
        Battery Power:
         powermode              \(batteryMode)
         sleep                  1
        AC Power:
         powermode              \(adapterMode)
         sleep                  0
        """
    }
}

private final class RecordingBatteryHealthRunner: BatteryHealthCommandRunning, @unchecked Sendable {
    private let responses: [BatteryHealthCommand: Result<Data, Error>]
    private let defaultResponse: Result<Data, Error>?
    private let lock = NSLock()
    private var commandStorage = [BatteryHealthCommand]()

    var commands: [BatteryHealthCommand] {
        lock.withLock { commandStorage }
    }

    init(
        responses: [BatteryHealthCommand: Result<Data, Error>] = [:],
        defaultResponse: Result<Data, Error>? = nil
    ) {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    convenience init(defaultResponse: Result<Data, Error>) {
        self.init(responses: [:], defaultResponse: defaultResponse)
    }

    func capture(_ command: BatteryHealthCommand) async throws -> Data {
        lock.withLock { commandStorage.append(command) }
        guard let response = responses[command] ?? defaultResponse else {
            throw BatteryHealthCommandFailure.unavailable
        }
        return try response.get()
    }
}

private actor ManualBatteryHealthRunner: BatteryHealthCommandRunning {
    private struct PendingCapture {
        let continuation: CheckedContinuation<Data, Error>
    }

    private var commands = [BatteryHealthCommand]()
    private var pendingCaptures = [PendingCapture]()
    private var activeCaptureCount = 0
    private var maximumActive = 0

    func capture(_ command: BatteryHealthCommand) async throws -> Data {
        commands.append(command)
        activeCaptureCount += 1
        maximumActive = max(maximumActive, activeCaptureCount)
        defer { activeCaptureCount -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            pendingCaptures.append(PendingCapture(continuation: continuation))
        }
    }

    func waitForCommandCount(_ expectedCount: Int) async {
        while commands.count < expectedCount {
            await Task.yield()
        }
    }

    func resumeNext(with result: Result<Data, Error>) {
        guard !pendingCaptures.isEmpty else { return }
        let pending = pendingCaptures.removeFirst()
        pending.continuation.resume(with: result)
    }

    func recordedCommands() -> [BatteryHealthCommand] {
        commands
    }

    func maximumActiveCaptureCount() -> Int {
        maximumActive
    }
}

private actor FirstBatteryPublicationBarrier {
    private var publicationCount = 0
    private var firstPublicationContinuation: CheckedContinuation<Void, Never>?

    func pauseFirstPublication() async {
        publicationCount += 1
        guard publicationCount == 1 else { return }
        await withCheckedContinuation { continuation in
            firstPublicationContinuation = continuation
        }
    }

    func waitForPublicationCount(_ expectedCount: Int) async {
        while publicationCount < expectedCount {
            await Task.yield()
        }
    }

    func releaseFirstPublication() {
        firstPublicationContinuation?.resume()
        firstPublicationContinuation = nil
    }
}

private final class BatteryRunnerExecutionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var ranOffMainThread = false
    private var observedCancellation = false

    var didRunOffMainThread: Bool {
        lock.withLock { ranOffMainThread }
    }

    var didObserveCancellation: Bool {
        lock.withLock { observedCancellation }
    }

    func execute(
        _ command: BatteryHealthCommand,
        cancellation: BatteryHealthCancellationFlag
    ) throws -> Data {
        lock.withLock {
            started = true
            ranOffMainThread = !Thread.isMainThread
        }
        while !cancellation.isCancelled {
            Thread.sleep(forTimeInterval: 0.001)
        }
        lock.withLock { observedCancellation = true }
        throw BatteryHealthCommandFailure.cancelled
    }

    func waitUntilStarted() async -> Bool {
        for _ in 0..<1_000 {
            if lock.withLock({ started }) { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }
}

private final class CancellationCheckSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let cancellationCheck: Int
    private var count = 0

    init(cancelOnCheck: Int) {
        cancellationCheck = cancelOnCheck
    }

    var checkCount: Int {
        lock.withLock { count }
    }

    func check() -> Bool {
        lock.withLock {
            count += 1
            return count >= cancellationCheck
        }
    }
}

private final class ManualShellCleanupScheduler: @unchecked Sendable {
    private let lock = NSLock()
    private var operations = [@Sendable () -> Void]()

    var scheduledCount: Int {
        lock.withLock { operations.count }
    }

    func schedule(
        after delay: TimeInterval,
        operation: @escaping @Sendable () -> Void
    ) {
        lock.withLock { operations.append(operation) }
    }

    func runNext() {
        let operation = lock.withLock {
            operations.isEmpty ? nil : operations.removeFirst()
        }
        operation?()
    }
}

private final class FakeShellCleanupLifecycle: ShellProcessCleanupLifecycle, @unchecked Sendable {
    let cleanupID = UUID()
    private let lock = NSLock()
    private var retainingProcess = false
    private var processPresence: ShellProcessPresence
    private var signals = 0
    private var releases = 0

    init(presence: ShellProcessPresence) {
        processPresence = presence
    }

    var isRetainingProcess: Bool {
        lock.withLock { retainingProcess }
    }

    var signalCount: Int {
        lock.withLock { signals }
    }

    var releaseCount: Int {
        lock.withLock { releases }
    }

    func setPresence(_ presence: ShellProcessPresence) {
        lock.withLock { processPresence = presence }
    }

    func activateRetention() -> Bool {
        lock.withLock {
            retainingProcess = true
            return true
        }
    }

    func cleanupPresence() -> ShellProcessPresence {
        lock.withLock { processPresence }
    }

    func retryVerifiedTermination() {
        lock.withLock {
            if processPresence == .sameProcessRunning {
                signals += 1
            }
        }
    }

    func releaseRetention() {
        lock.withLock {
            releases += 1
            retainingProcess = false
        }
    }
}

private final class ShellTerminationSignalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var signals = 0

    var signalCount: Int {
        lock.withLock { signals }
    }

    func recordSignal() {
        lock.withLock { signals += 1 }
    }
}

private final class ShellProcessTreeExitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var presences: [ShellProcessPresence]
    private var monotonicTimes: [UInt64]
    private var presenceChecks = 0
    private var pauses = 0

    init(
        presences: [ShellProcessPresence],
        monotonicTimes: [UInt64]
    ) {
        self.presences = presences
        self.monotonicTimes = monotonicTimes
    }

    var presenceCheckCount: Int {
        lock.withLock { presenceChecks }
    }

    var pauseCount: Int {
        lock.withLock { pauses }
    }

    var operations: Shell.ProcessTreeExitOperations {
        Shell.ProcessTreeExitOperations(
            descendants: { _ in [] },
            presence: { [weak self] _ in
                guard let self else { return .unknown }
                return lock.withLock {
                    presenceChecks += 1
                    guard !presences.isEmpty else { return .unknown }
                    return presences.removeFirst()
                }
            },
            monotonicNow: { [weak self] in
                guard let self else { return 0 }
                return lock.withLock {
                    guard !monotonicTimes.isEmpty else { return 0 }
                    return monotonicTimes.removeFirst()
                }
            },
            pause: { [weak self] _ in
                self?.lock.withLock { self?.pauses += 1 }
            }
        )
    }
}

private final class ShellGrowingProcessTreeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let child: Shell.ProcessIdentity
    private let discoveredDescendants: [Shell.ProcessIdentity]
    private var emptyChildScansBeforeDiscovery: Int
    private var presenceSequences: [Shell.ProcessIdentity: [ShellProcessPresence]]
    private var tracked = Set<Shell.ProcessIdentity>()
    private var signalled = Set<Shell.ProcessIdentity>()
    private var monotonicTime: UInt64 = 0

    init(
        child: Shell.ProcessIdentity,
        discoveredDescendants: [Shell.ProcessIdentity],
        emptyChildScansBeforeDiscovery: Int = 0,
        presenceSequences: [Shell.ProcessIdentity: [ShellProcessPresence]]
    ) {
        self.child = child
        self.discoveredDescendants = discoveredDescendants
        self.emptyChildScansBeforeDiscovery = max(0, emptyChildScansBeforeDiscovery)
        self.presenceSequences = presenceSequences
    }

    var trackedIdentities: Set<Shell.ProcessIdentity> {
        lock.withLock { tracked }
    }

    var signalledIdentities: Set<Shell.ProcessIdentity> {
        lock.withLock { signalled }
    }

    func recordTracked(_ identities: [Shell.ProcessIdentity]) {
        lock.withLock { tracked.formUnion(identities) }
    }

    func recordSignals(_ identities: [Shell.ProcessIdentity]) {
        lock.withLock { signalled.formUnion(identities) }
    }

    var operations: Shell.ProcessTreeExitOperations {
        Shell.ProcessTreeExitOperations(
            descendants: { [weak self] identity in
                guard let self else { return [] }
                return lock.withLock {
                    guard identity == child else { return [] }
                    if emptyChildScansBeforeDiscovery > 0 {
                        emptyChildScansBeforeDiscovery -= 1
                        return []
                    }
                    return discoveredDescendants
                }
            },
            presence: { [weak self] identity in
                guard let self else { return .unknown }
                return lock.withLock {
                    guard var sequence = presenceSequences[identity],
                          !sequence.isEmpty else {
                        return .exited
                    }
                    let presence = sequence.removeFirst()
                    presenceSequences[identity] = sequence
                    return presence
                }
            },
            monotonicNow: { [weak self] in
                guard let self else { return 0 }
                return lock.withLock {
                    defer { monotonicTime += 10_000_000 }
                    return monotonicTime
                }
            },
            pause: { _ in }
        )
    }
}

private final class ShellProcessGroupExitProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var memberSnapshots: [[Shell.ProcessIdentity]]
    private var presences: [Shell.ProcessIdentity: [ShellProcessPresence]]
    private var scans = 0
    private var monotonicTime: UInt64 = 0
    private var tracked = Set<Shell.ProcessIdentity>()
    private var signalled = Set<Shell.ProcessIdentity>()

    init(
        memberSnapshots: [[Shell.ProcessIdentity]],
        presences: [Shell.ProcessIdentity: [ShellProcessPresence]]
    ) {
        self.memberSnapshots = memberSnapshots
        self.presences = presences
    }

    var memberScanCount: Int {
        lock.withLock { scans }
    }

    var trackedIdentities: Set<Shell.ProcessIdentity> {
        lock.withLock { tracked }
    }

    var signalledIdentities: Set<Shell.ProcessIdentity> {
        lock.withLock { signalled }
    }

    func recordTracked(_ identities: [Shell.ProcessIdentity]) {
        lock.withLock { tracked.formUnion(identities) }
    }

    func recordSignals(_ identities: [Shell.ProcessIdentity]) {
        lock.withLock { signalled.formUnion(identities) }
    }

    var operations: Shell.ProcessGroupExitOperations {
        Shell.ProcessGroupExitOperations(
            members: { [weak self] _ in
                guard let self else { return nil }
                return lock.withLock {
                    scans += 1
                    guard !memberSnapshots.isEmpty else { return [] }
                    return memberSnapshots.removeFirst()
                }
            },
            presence: { [weak self] identity in
                guard let self else { return .unknown }
                return lock.withLock {
                    guard var sequence = presences[identity],
                          !sequence.isEmpty else {
                        return .exited
                    }
                    let result = sequence.removeFirst()
                    presences[identity] = sequence
                    return result
                }
            },
            monotonicNow: { [weak self] in
                guard let self else { return 0 }
                return lock.withLock {
                    defer { monotonicTime += 10_000_000 }
                    return monotonicTime
                }
            },
            pause: { _ in }
        )
    }
}

private struct RawBatteryError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
private final class SnapshotSequenceReader {
    private var snapshots: [BatteryHealthSnapshot?]

    init(_ snapshots: [BatteryHealthSnapshot?]) {
        self.snapshots = snapshots
    }

    func next() -> BatteryHealthSnapshot? {
        snapshots.isEmpty ? nil : snapshots.removeFirst()
    }
}

@MainActor
private final class ControlledSnapshotReader {
    private var requests = [CheckedContinuation<BatteryHealthSnapshot?, Never>?]()

    func next() async -> BatteryHealthSnapshot? {
        await withCheckedContinuation { continuation in
            requests.append(continuation)
        }
    }

    func waitForRequestCount(_ expectedCount: Int) async {
        while requests.count < expectedCount {
            await Task.yield()
        }
    }

    func resumeRequest(at index: Int, with snapshot: BatteryHealthSnapshot?) {
        guard requests.indices.contains(index), let continuation = requests[index] else {
            return
        }
        requests[index] = nil
        continuation.resume(returning: snapshot)
    }
}

@MainActor
private final class RecordingBatterySettingsOpener: BatterySettingsOpening {
    private let result: Bool
    private(set) var openCount = 0
    private(set) var lastURL: URL?

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        openCount += 1
        lastURL = url
        return result
    }
}
