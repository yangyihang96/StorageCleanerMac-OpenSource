import Foundation
import XCTest
@testable import StorageCleanerMac

final class BackupAndStabilityHealthTests: XCTestCase {
    func testShellTimeMachineRunnerPhysicallyCancelsCurrentTask() async {
        let task = Task.detached { () -> TimeMachineCommandFailure? in
            do {
                _ = try ShellTimeMachineCommandRunner().capture(TimeMachineCommand(
                    executable: "/bin/sleep",
                    arguments: ["0.8"],
                    timeout: 2
                ))
                return nil
            } catch let failure as TimeMachineCommandFailure {
                return failure
            } catch {
                return .unavailable
            }
        }
        try? await Task.sleep(for: .milliseconds(100))
        let clock = ContinuousClock()
        let startedAt = clock.now

        task.cancel()
        let failure = await task.value

        XCTAssertEqual(failure, .cancelled)
        XCTAssertLessThan(startedAt.duration(to: clock.now), .milliseconds(700))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTimeMachineRunsOnlyFixedReadOnlyCommandsWithWatchdogs() throws {
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(configuredDestinationPlist),
            TimeMachineStatusService.statusCommand: .success(Data("Running = 1;".utf8)),
            TimeMachineStatusService.localSnapshotsCommand: .success(
                Data("Snapshots for volume /:\n2027-01-15-011500\n".utf8)
            ),
            TimeMachineStatusService.latestBackupCommand: .success(Data("2027-01-14-221500\n".utf8))
        ])
        let service = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        )

        let snapshot = service.snapshot()

        XCTAssertEqual(runner.commands, [
            TimeMachineCommand(
                executable: "/usr/bin/tmutil",
                arguments: ["destinationinfo", "-X"],
                timeout: 3
            ),
            TimeMachineCommand(
                executable: "/usr/bin/tmutil",
                arguments: ["status"],
                timeout: 2
            ),
            TimeMachineCommand(
                executable: "/usr/bin/tmutil",
                arguments: ["listlocalsnapshotdates", "/"],
                timeout: 3
            ),
            TimeMachineCommand(
                executable: "/usr/bin/tmutil",
                arguments: ["latestbackup", "-t"],
                timeout: 5
            )
        ])
        XCTAssertEqual(snapshot.destinationState, .configured)
        XCTAssertEqual(snapshot.isRunning, true)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.status, .healthy)
        XCTAssertNotNil(snapshot.latestLocalSnapshot)
        XCTAssertNotNil(snapshot.latestCompleteBackup)
        XCTAssertEqual(snapshot.completeBackupAvailability, .available)
    }

    func testTimeMachineUnconfiguredDestinationDoesNotRunFollowUpCommands() {
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(emptyDestinationPlist)
        ])
        let snapshot = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(runner.commands, [TimeMachineStatusService.destinationInfoCommand])
        XCTAssertEqual(snapshot.destinationState, .unconfigured)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.status, .attention)
        XCTAssertNil(snapshot.isRunning)
        XCTAssertNil(snapshot.latestLocalSnapshot)
        XCTAssertNil(snapshot.latestCompleteBackup)
        XCTAssertEqual(snapshot.completeBackupAvailability, .unavailable)
    }

    func testTimeMachineNoDestinationTextOrFailureIsTruthfullyUnconfigured() {
        let responses: [Result<Data, Error>] = [
            .success(Data("No destinations configured.".utf8)),
            .failure(TimeMachineCommandFailure.unconfigured)
        ]

        for response in responses {
            let runner = RecordingTimeMachineRunner(responses: [
                TimeMachineStatusService.destinationInfoCommand: response
            ])
            let snapshot = TimeMachineStatusService(
                runner: runner,
                calendar: utcCalendar,
                now: { self.now }
            ).snapshot()

            XCTAssertEqual(runner.commands, [TimeMachineStatusService.destinationInfoCommand])
            XCTAssertEqual(snapshot.destinationState, .unconfigured)
            XCTAssertEqual(snapshot.availability, .available)
            XCTAssertEqual(snapshot.status, .attention)
        }
    }

    func testTimeMachineLocalSnapshotNeverBecomesCompleteBackup() {
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(configuredDestinationPlist),
            TimeMachineStatusService.statusCommand: .success(Data("Running = 0;".utf8)),
            TimeMachineStatusService.localSnapshotsCommand: .success(Data("2027-01-15-011500".utf8)),
            TimeMachineStatusService.latestBackupCommand: .failure(TimeMachineCommandFailure.unreachable)
        ])

        let snapshot = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        XCTAssertNotNil(snapshot.latestLocalSnapshot)
        XCTAssertNil(snapshot.latestCompleteBackup)
        XCTAssertEqual(snapshot.completeBackupAvailability, .unavailable)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
    }

    func testTimeMachineDestinationFailuresMapToSafeTypedStates() {
        let cases: [(TimeMachineCommandFailure, TimeMachineDestinationState, HealthAvailability)] = [
            (.permissionDenied, .permissionDenied, .permissionDenied),
            (.timedOut, .timedOut, .timedOut),
            (.cancelled, .unavailable, .cancelled),
            (.unreachable, .unreachable, .unavailable),
            (.unavailable, .unavailable, .unavailable)
        ]

        for (failure, expectedState, expectedAvailability) in cases {
            let runner = RecordingTimeMachineRunner(responses: [
                TimeMachineStatusService.destinationInfoCommand: .failure(failure)
            ])

            let snapshot = TimeMachineStatusService(
                runner: runner,
                calendar: utcCalendar,
                now: { self.now }
            ).snapshot()

            XCTAssertEqual(snapshot.destinationState, expectedState)
            XCTAssertEqual(snapshot.availability, expectedAvailability)
            XCTAssertEqual(snapshot.status, .unavailable)
            XCTAssertEqual(runner.commands, [TimeMachineStatusService.destinationInfoCommand])
        }
    }

    func testTimeMachineConfiguredDestinationKeepsLatestBackupFailureSeparate() {
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(configuredDestinationPlist),
            TimeMachineStatusService.statusCommand: .success(Data("Running = 0;".utf8)),
            TimeMachineStatusService.localSnapshotsCommand: .success(Data("2027-01-15-011500".utf8)),
            TimeMachineStatusService.latestBackupCommand: .failure(TimeMachineCommandFailure.permissionDenied)
        ])

        let snapshot = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(snapshot.destinationState, .configured)
        XCTAssertEqual(snapshot.isRunning, false)
        XCTAssertEqual(snapshot.completeBackupAvailability, .permissionDenied)
        XCTAssertNil(snapshot.latestCompleteBackup)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
    }

    func testTimeMachineDestinationRemovalDuringFollowUpNeverMarksCompleteBackupAvailable() {
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(configuredDestinationPlist),
            TimeMachineStatusService.statusCommand: .success(Data("Running = 0;".utf8)),
            TimeMachineStatusService.localSnapshotsCommand: .success(Data("2027-01-15-011500".utf8)),
            TimeMachineStatusService.latestBackupCommand: .failure(TimeMachineCommandFailure.unconfigured)
        ])

        let snapshot = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(snapshot.destinationState, .configured)
        XCTAssertNil(snapshot.latestCompleteBackup)
        XCTAssertEqual(snapshot.completeBackupAvailability, .unavailable)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
    }

    func testTimeMachineMalformedDatesNeverFabricateBackupDates() {
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(configuredDestinationPlist),
            TimeMachineStatusService.statusCommand: .success(Data("Running = maybe;".utf8)),
            TimeMachineStatusService.localSnapshotsCommand: .success(Data("2027-99-99-999999\nprivate-name".utf8)),
            TimeMachineStatusService.latestBackupCommand: .success(Data("not-a-date".utf8))
        ])

        let snapshot = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        XCTAssertNil(snapshot.isRunning)
        XCTAssertNil(snapshot.latestLocalSnapshot)
        XCTAssertNil(snapshot.latestCompleteBackup)
        XCTAssertEqual(snapshot.completeBackupAvailability, .unavailable)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
    }

    func testTimeMachineRunningParserRejectsSubstringAndConflictingKeys() {
        for statusText in [
            "NotRunning = 1;",
            "Running = 1;\nRunning = 0;"
        ] {
            let runner = RecordingTimeMachineRunner(responses: [
                TimeMachineStatusService.destinationInfoCommand: .success(configuredDestinationPlist),
                TimeMachineStatusService.statusCommand: .success(Data(statusText.utf8)),
                TimeMachineStatusService.localSnapshotsCommand: .success(Data("2027-01-15-011500".utf8)),
                TimeMachineStatusService.latestBackupCommand: .success(Data("2027-01-14-221500".utf8))
            ])

            let snapshot = TimeMachineStatusService(
                runner: runner,
                calendar: utcCalendar,
                now: { self.now }
            ).snapshot()

            XCTAssertNil(snapshot.isRunning)
            XCTAssertEqual(snapshot.availability, .partial)
            XCTAssertEqual(snapshot.status, .attention)
        }
    }

    func testTimeMachineLatestBackupRequiresExactlyOneTimestamp() {
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(configuredDestinationPlist),
            TimeMachineStatusService.statusCommand: .success(Data("Running = 0;".utf8)),
            TimeMachineStatusService.localSnapshotsCommand: .success(Data("2027-01-15-011500".utf8)),
            TimeMachineStatusService.latestBackupCommand: .success(
                Data("Warning at /private/2027-01-14-221500: backup unavailable".utf8)
            )
        ])

        let snapshot = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        XCTAssertNil(snapshot.latestCompleteBackup)
        XCTAssertEqual(snapshot.completeBackupAvailability, .unavailable)
        XCTAssertEqual(snapshot.availability, .partial)
    }

    func testTimeMachineMalformedDestinationPlistNeverBecomesConfigured() {
        let malformed = try! PropertyListSerialization.data(
            fromPropertyList: [
                "Error": "private destination details",
                "Kind": "Network",
                "MountPoint": "/Volumes/Private"
            ],
            format: .xml,
            options: 0
        )
        let runner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(malformed)
        ])

        let snapshot = TimeMachineStatusService(
            runner: runner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(runner.commands, [TimeMachineStatusService.destinationInfoCommand])
        XCTAssertEqual(snapshot.destinationState, .unavailable)
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertEqual(snapshot.status, .unavailable)
    }

    func testTimeMachineUnknownRawErrorAndDestinationMetadataAreNotRetained() throws {
        let secret = "smb://secret-user@private-host/backup"
        let configuredRunner = RecordingTimeMachineRunner(responses: [
            TimeMachineStatusService.destinationInfoCommand: .success(destinationPlist(secret: secret)),
            TimeMachineStatusService.statusCommand: .success(Data("Running = 0;".utf8)),
            TimeMachineStatusService.localSnapshotsCommand: .success(Data("2027-01-15-011500".utf8)),
            TimeMachineStatusService.latestBackupCommand: .success(Data("2027-01-14-221500".utf8))
        ])
        let configured = TimeMachineStatusService(
            runner: configuredRunner,
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()
        let unknown = TimeMachineStatusService(
            runner: RecordingTimeMachineRunner(responses: [
                TimeMachineStatusService.destinationInfoCommand: .failure(
                    RawBackupError(message: "private-host secret-user destination-id")
                )
            ]),
            calendar: utcCalendar,
            now: { self.now }
        ).snapshot()

        let encoded = String(decoding: try JSONEncoder().encode([configured, unknown]), as: UTF8.self)
        XCTAssertFalse(encoded.contains(secret))
        XCTAssertFalse(encoded.contains("secret-user"))
        XCTAssertFalse(encoded.contains("destination-id"))
        XCTAssertEqual(unknown.destinationState, .unavailable)
        XCTAssertEqual(unknown.availability, .unavailable)
    }

    func testShellTimeMachineFailureClassifierDoesNotExposeRawOutput() {
        let permission = ShellTimeMachineCommandRunner.safeFailure(
            for: ShellError.failed(
                "/usr/bin/tmutil latestbackup -t",
                1,
                "Operation not permitted /Users/private"
            )
        )
        let unreachable = ShellTimeMachineCommandRunner.safeFailure(
            for: ShellError.failed(
                "/usr/bin/tmutil latestbackup -t",
                1,
                "The backup destination could not be mounted at smb://private-host"
            )
        )
        let unknown = ShellTimeMachineCommandRunner.safeFailure(
            for: RawBackupError(message: "private-host token")
        )
        let unconfigured = ShellTimeMachineCommandRunner.safeFailure(
            for: ShellError.failed(
                "/usr/bin/tmutil destinationinfo -X",
                1,
                "No destinations configured."
            )
        )

        XCTAssertEqual(permission, .permissionDenied)
        XCTAssertEqual(unreachable, .unreachable)
        XCTAssertEqual(unknown, .unavailable)
        XCTAssertEqual(unconfigured, .unconfigured)
        XCTAssertFalse(String(describing: unknown).contains("private-host"))
    }

    func testStabilityClassifiesRecentReportsAndFiltersOldOrIrrelevantFiles() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try writeReport("Example.crash", "Process: Example\nPath: /Users/private/Example", in: sandbox, ageDays: 1)
        try writeReport("Window.hang", "Application Specific Information: hung", in: sandbox, ageDays: 2)
        try writeReport("Busy.spin", "Process: Busy", in: sandbox, ageDays: 3)
        try writeReport(
            "panic-full-2027.ips",
            #"{"report_type":"kernel panic","stack":"/Users/private/secret"}"#,
            in: sandbox,
            ageDays: 1
        )
        try writeReport(
            "UnexpectedRestart-2027.diag",
            #"{"report_type":"unexpected restart"}"#,
            in: sandbox,
            ageDays: 1
        )
        try writeReport("Old.crash", "Process: Old", in: sandbox, ageDays: 31)
        try writeReport("Notes.txt", "panic words alone are not a report", in: sandbox, ageDays: 1)

        let summary = StabilityReportService(
            roots: [sandbox],
            now: { self.now }
        ).snapshot(windowDays: 30)

        XCTAssertEqual(summary.crashCount, 1)
        XCTAssertEqual(summary.hangCount, 1)
        XCTAssertEqual(summary.spinCount, 1)
        XCTAssertEqual(summary.panicCount, 1)
        XCTAssertEqual(summary.unexpectedRestartCount, 1)
        XCTAssertEqual(summary.filesExamined, 5)
        XCTAssertEqual(summary.availability, .available)
        XCTAssertEqual(summary.status, .actionRequired)
        XCTAssertEqual(summary.windowStart, utcCalendar.date(byAdding: .day, value: -30, to: now))
        XCTAssertEqual(summary.generatedAt, now)
        XCTAssertEqual(
            summary.events.map { $0.type.rawValue }.sorted(),
            StabilityEventType.allFixtureRawValues
        )
        XCTAssertEqual(
            summary.events.filter { $0.occurredAt == now.addingTimeInterval(-86_400) }.count,
            3
        )
        XCTAssertTrue(summary.events.contains {
            $0.type == .hang && $0.occurredAt == now.addingTimeInterval(-2 * 86_400)
        })
        XCTAssertTrue(summary.events.contains {
            $0.type == .spin && $0.occurredAt == now.addingTimeInterval(-3 * 86_400)
        })
    }

    func testStabilityUnknownIPSMetadataDoesNotCreateFalseCrash() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let report = root.appendingPathComponent("ResourceReport.ips")
        let access = SelectiveStabilityFileAccess(
            root: root,
            files: [report],
            modificationDate: now,
            responses: [
                report: .success(Data(#"{"app_name":"Example","bug_type":"999"}"#.utf8))
            ]
        )

        let summary = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(summary.filesExamined, 1)
        XCTAssertEqual(summary.crashCount, 0)
        XCTAssertEqual(summary.availability, .partial)
        XCTAssertEqual(summary.status, .attention)
    }

    func testShutdownStallIsAHangAndGenericShutdownIsNotAnUnexpectedRestart() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try writeReport(
            "shutdown_stall_2026.shutdownStall",
            "shutdown took too long",
            in: sandbox,
            ageDays: 1
        )
        try writeReport(
            "Shutdown.ips",
            #"{"report_type":"shutdown"}"#,
            in: sandbox,
            ageDays: 1
        )

        let summary = StabilityReportService(
            roots: [sandbox],
            now: { self.now }
        ).snapshot(windowDays: 30)

        XCTAssertEqual(summary.hangCount, 1)
        XCTAssertEqual(summary.unexpectedRestartCount, 0)
        XCTAssertEqual(summary.status, .attention)
        XCTAssertFalse(summary.events.contains { $0.type == .unexpectedRestart })
    }

    func testStabilityModernIPSUsesOnlyAppleCrashBugTypeAllowlist() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let stringCrash = root.appendingPathComponent("StringCrash.ips")
        let numericCrash = root.appendingPathComponent("NumericCrash.ips")
        let stackshot = root.appendingPathComponent("Stackshot.ips")
        let unknown = root.appendingPathComponent("Unknown.ips")
        let access = SelectiveStabilityFileAccess(
            root: root,
            files: [stringCrash, numericCrash, stackshot, unknown],
            modificationDate: now,
            responses: [
                stringCrash: .success(Data(#"{"app_name":"Example","bug_type":"309"}"#.utf8)),
                numericCrash: .success(Data(#"{"name":"Example2","bug_type":309}"#.utf8)),
                stackshot: .success(Data(#"{"name":"Example3","bug_type":"288"}"#.utf8)),
                unknown: .success(Data(#"{"name":"Example4","bug_type":"777"}"#.utf8))
            ]
        )

        let summary = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(summary.filesExamined, 4)
        XCTAssertEqual(summary.crashCount, 2)
        XCTAssertEqual(summary.availability, .partial)
        XCTAssertEqual(summary.status, .attention)
    }

    func testStabilityMissingDefaultStyleRootsAreReliableEmptySources() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let missingOne = sandbox.appendingPathComponent("MissingOne", isDirectory: true)
        let missingTwo = sandbox.appendingPathComponent("MissingTwo", isDirectory: true)
        let empty = sandbox.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

        let mixed = StabilityReportService(
            roots: [missingOne, empty],
            now: { self.now }
        ).snapshot()
        let bothMissing = StabilityReportService(
            roots: [missingOne, missingTwo],
            now: { self.now }
        ).snapshot()

        for summary in [mixed, bothMissing] {
            XCTAssertEqual(summary.availability, .available)
            XCTAssertEqual(summary.status, .healthy)
            XCTAssertEqual(summary.filesExamined, 0)
            XCTAssertEqual(summary.crashCount, 0)
        }
    }

    func testStabilityBlockingFileAccessCannotExceedHardWallBudget() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let access = BlockingStabilityFileAccess(delay: 2.6)
        let service = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now }
        )
        let startedAt = Date()

        let summary = service.snapshot()
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 2.4)
        XCTAssertEqual(summary.availability, .timedOut)
        XCTAssertEqual(summary.status, .unavailable)
        XCTAssertNil(summary.crashCount)
        XCTAssertEqual(summary.filesExamined, 0)

        let repeatedStartedAt = Date()
        let repeated = service.snapshot()
        let repeatedElapsed = Date().timeIntervalSince(repeatedStartedAt)
        XCTAssertLessThan(repeatedElapsed, 0.2)
        XCTAssertEqual(repeated.availability, .timedOut)
        XCTAssertEqual(access.metadataCallCount, 1)

        Thread.sleep(forTimeInterval: 0.7)
    }

    func testStabilityDeferredWorkClearsInFlightGateAfterTimeout() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let scheduler = DeferredStabilityWorkScheduler()
        let service = StabilityReportService(
            roots: [root],
            now: { self.now },
            wallTimeLimit: 0.02,
            enqueueWork: scheduler.enqueue
        )

        let first = service.snapshot()
        XCTAssertEqual(first.availability, .timedOut)
        XCTAssertEqual(scheduler.totalEnqueued, 1)

        scheduler.runNext()

        let afterDeferredWorkRuns = service.snapshot()
        XCTAssertEqual(afterDeferredWorkRuns.availability, .timedOut)
        XCTAssertEqual(scheduler.totalEnqueued, 2)

        scheduler.runNext()
    }

    func testStabilityWindowCanBeLimitedToSevenDays() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try writeReport("Recent.crash", "Process: Recent", in: sandbox, ageDays: 2)
        try writeReport("EightDays.crash", "Process: Older", in: sandbox, ageDays: 8)

        let service = StabilityReportService(roots: [sandbox], now: { self.now })
        let sevenDays = service.snapshot(windowDays: 7)
        let thirtyDays = service.snapshot(windowDays: 30)

        XCTAssertEqual(sevenDays.crashCount, 1)
        XCTAssertEqual(sevenDays.filesExamined, 1)
        XCTAssertEqual(thirtyDays.crashCount, 2)
        XCTAssertEqual(thirtyDays.filesExamined, 2)
    }

    func testStabilityOrdinaryEventsNeedAttentionAndEmptyDirectoryIsHealthy() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let empty = StabilityReportService(roots: [sandbox], now: { self.now }).snapshot()
        try writeReport("Example.crash", "Process: Example", in: sandbox, ageDays: 1)
        let withCrash = StabilityReportService(roots: [sandbox], now: { self.now }).snapshot()

        XCTAssertEqual(empty.availability, .available)
        XCTAssertEqual(empty.status, .healthy)
        XCTAssertEqual(empty.crashCount, 0)
        XCTAssertEqual(withCrash.availability, .available)
        XCTAssertEqual(withCrash.status, .attention)
    }

    func testStabilityNeverFollowsFileOrDirectorySymlinks() throws {
        let sandbox = makeSandbox()
        let external = makeSandbox()
        defer {
            try? FileManager.default.removeItem(at: sandbox)
            try? FileManager.default.removeItem(at: external)
        }
        try writeReport("Real.crash", "Process: Real", in: sandbox, ageDays: 1)
        try writeReport("External.crash", "Process: External", in: external, ageDays: 1)
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("Linked.crash"),
            withDestinationURL: external.appendingPathComponent("External.crash")
        )
        try FileManager.default.createSymbolicLink(
            at: sandbox.appendingPathComponent("LinkedDirectory"),
            withDestinationURL: external
        )

        let summary = StabilityReportService(roots: [sandbox], now: { self.now }).snapshot()

        XCTAssertEqual(summary.crashCount, 1)
        XCTAssertEqual(summary.filesExamined, 1)
    }

    func testStabilityCapsSixHundredReportsAtFiveHundred() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        for index in 0..<600 {
            try writeReport("Report-\(index).crash", "Process: Example", in: sandbox, ageDays: 1)
        }

        let summary = StabilityReportService(roots: [sandbox], now: { self.now }).snapshot()

        XCTAssertEqual(summary.filesExamined, 500)
        XCTAssertEqual(summary.crashCount, 500)
        XCTAssertEqual(summary.availability, .partial)
        XCTAssertEqual(summary.status, .attention)
    }

    func testStabilityEnforcesPerFileAndTotalByteCaps() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let files = (0..<140).map {
            root.appendingPathComponent("Report-\($0).ips")
        }
        let access = RecordingStabilityFileAccess(
            roots: [root],
            files: files,
            modificationDate: now,
            data: Data(repeating: 65, count: 100_000)
        )

        let summary = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now }
        ).snapshot()

        XCTAssertTrue(access.requestedReadLimits.allSatisfy { $0 <= 8 * 1_024 })
        XCTAssertLessThanOrEqual(access.totalBytesReturned, 8 * 1_024 * 1_024)
        XCTAssertEqual(summary.filesExamined, 140)
        XCTAssertEqual(summary.availability, .partial)
        XCTAssertEqual(summary.status, .attention)
    }

    func testStabilityReadsOnlyIPSHeaderForReportsThatNeedContent() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let files = [
            root.appendingPathComponent("Example.crash"),
            root.appendingPathComponent("Example.hang"),
            root.appendingPathComponent("Example.spin"),
            root.appendingPathComponent("Example.panic"),
            root.appendingPathComponent("Example.ips")
        ]
        let access = RecordingStabilityFileAccess(
            roots: [root],
            files: files,
            modificationDate: now,
            data: Data(#"{"app_name":"Example","bug_type":"309"}"#.utf8)
        )

        let summary = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(access.requestedReadLimits, [8 * 1_024])
        XCTAssertEqual(summary.filesExamined, 5)
        XCTAssertEqual(summary.crashCount, 2)
        XCTAssertEqual(summary.hangCount, 1)
        XCTAssertEqual(summary.spinCount, 1)
        XCTAssertEqual(summary.panicCount, 1)
    }

    func testStabilityTwoSecondBudgetReportsTimedOutWithoutYieldLoop() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let access = RecordingStabilityFileAccess(
            roots: [root],
            files: [root.appendingPathComponent("Report.crash")],
            modificationDate: now,
            data: Data("Process: Example".utf8)
        )
        var ticks = [0.0, 0.5, 2.0]
        let service = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now },
            monotonicNow: { ticks.isEmpty ? 2.0 : ticks.removeFirst() }
        )

        let summary = service.snapshot()

        XCTAssertEqual(summary.availability, .timedOut)
        XCTAssertEqual(summary.status, .unavailable)
        XCTAssertLessThanOrEqual(summary.filesExamined, 1)
        XCTAssertNil(summary.crashCount)
        XCTAssertNil(summary.hangCount)
    }

    func testStabilityTimeoutAfterExaminingAFilePreservesPartialCounts() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let access = RecordingStabilityFileAccess(
            roots: [root],
            files: [
                root.appendingPathComponent("First.crash"),
                root.appendingPathComponent("Second.crash")
            ],
            modificationDate: now,
            data: Data("Process: Example".utf8)
        )
        var ticks = [0.0, 0, 0, 0, 0, 0, 2]
        let summary = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now },
            monotonicNow: { ticks.isEmpty ? 2.0 : ticks.removeFirst() }
        ).snapshot()

        XCTAssertEqual(summary.availability, .partial)
        XCTAssertEqual(summary.status, .attention)
        XCTAssertEqual(summary.filesExamined, 1)
        XCTAssertEqual(summary.crashCount, 1)
    }

    func testStabilityPermissionAndUnknownRootFailuresAreTruthfulAndPrivate() throws {
        let root = URL(fileURLWithPath: "/synthetic/private", isDirectory: true)
        let permission = StabilityReportService(
            roots: [root],
            fileAccess: FailingStabilityFileAccess(error: POSIXError(.EACCES)),
            now: { self.now }
        ).snapshot()
        let unknown = StabilityReportService(
            roots: [root],
            fileAccess: FailingStabilityFileAccess(
                error: RawBackupError(message: "/Users/private secret stack")
            ),
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(permission.availability, .permissionDenied)
        XCTAssertEqual(permission.status, .unavailable)
        XCTAssertNil(permission.crashCount)
        XCTAssertEqual(unknown.availability, .unavailable)
        XCTAssertEqual(unknown.status, .unavailable)
        let encoded = String(decoding: try JSONEncoder().encode([permission, unknown]), as: UTF8.self)
        XCTAssertFalse(encoded.contains("/Users/private"))
        XCTAssertFalse(encoded.contains("secret stack"))
    }

    func testStabilityPartialReadAndMalformedIPSCanNeverReportHealthy() {
        let root = URL(fileURLWithPath: "/synthetic", isDirectory: true)
        let good = root.appendingPathComponent("Good.crash")
        let denied = root.appendingPathComponent("Denied.ips")
        let malformed = root.appendingPathComponent("Malformed.ips")
        let access = SelectiveStabilityFileAccess(
            root: root,
            files: [good, denied, malformed],
            modificationDate: now,
            responses: [
                good: .success(Data("Process: Good".utf8)),
                denied: .failure(POSIXError(.EACCES)),
                malformed: .success(Data("not structured report metadata".utf8))
            ]
        )

        let summary = StabilityReportService(
            roots: [root],
            fileAccess: access,
            now: { self.now }
        ).snapshot()

        XCTAssertEqual(summary.availability, .partial)
        XCTAssertEqual(summary.status, .attention)
        XCTAssertEqual(summary.crashCount, 1)
        XCTAssertEqual(summary.filesExamined, 2)
    }

    func testStabilitySnapshotEncodingNeverIncludesStackPathsArgumentsOrBinaryImages() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let secrets = [
            "/Users/private/Documents/Secret.app",
            "--account-token=private-token",
            "Binary Images:",
            "0x1234 private_stack_function"
        ]
        try writeReport(
            "Private.crash",
            (["Process: Private"] + secrets).joined(separator: "\n"),
            in: sandbox,
            ageDays: 1
        )

        let summary = StabilityReportService(roots: [sandbox], now: { self.now }).snapshot()
        let encoded = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)

        for secret in secrets {
            XCTAssertFalse(encoded.contains(secret))
        }
        XCTAssertFalse(encoded.contains("Private.crash"))
        XCTAssertEqual(summary.filesExamined, 1)
        XCTAssertEqual(summary.crashCount, 1)
        XCTAssertEqual(summary.events, [
            StabilityEvent(type: .crash, occurredAt: now.addingTimeInterval(-86_400))
        ])
    }

    func testStabilityCounterIncrementSaturatesInsteadOfOverflowing() {
        XCTAssertEqual(StabilityReportService.saturatedIncrement(Int.max), Int.max)
        XCTAssertEqual(StabilityReportService.saturatedIncrement(Int.max - 1), Int.max)
    }

    private var configuredDestinationPlist: Data {
        destinationPlist(secret: "smb://private-user@backup-host/Private Disk")
    }

    private var emptyDestinationPlist: Data {
        try! PropertyListSerialization.data(
            fromPropertyList: [],
            format: .xml,
            options: 0
        )
    }

    private func destinationPlist(secret: String) -> Data {
        try! PropertyListSerialization.data(
            fromPropertyList: [[
                "DestinationID": "PRIVATE-ID",
                "DestinationURL": secret,
                "Name": "Private Backup"
            ]],
            format: .xml,
            options: 0
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeSandbox() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupAndStabilityHealthTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeReport(
        _ name: String,
        _ contents: String,
        in directory: URL,
        ageDays: Int
    ) throws {
        let url = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        let date = utcCalendar.date(byAdding: .day, value: -ageDays, to: now)!
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

private extension StabilityEventType {
    static var allFixtureRawValues: [String] {
        [crash, hang, spin, panic, unexpectedRestart].map(\.rawValue).sorted()
    }
}

private final class RecordingTimeMachineRunner: TimeMachineCommandRunning {
    private let responses: [TimeMachineCommand: Result<Data, Error>]
    private(set) var commands = [TimeMachineCommand]()

    init(responses: [TimeMachineCommand: Result<Data, Error>]) {
        self.responses = responses
    }

    func capture(_ command: TimeMachineCommand) throws -> Data {
        commands.append(command)
        guard let response = responses[command] else {
            throw TimeMachineCommandFailure.unavailable
        }
        return try response.get()
    }
}

private struct RawBackupError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class RecordingStabilityFileAccess: StabilityFileAccessing {
    private let roots: Set<URL>
    private let files: [URL]
    private let modificationDate: Date
    private let data: Data
    private(set) var requestedReadLimits = [Int]()
    private(set) var totalBytesReturned = 0

    init(roots: [URL], files: [URL], modificationDate: Date, data: Data) {
        self.roots = Set(roots)
        self.files = files
        self.modificationDate = modificationDate
        self.data = data
    }

    func metadata(for url: URL) throws -> StabilityFileMetadata {
        if roots.contains(url) {
            return StabilityFileMetadata(
                isDirectory: true,
                isRegularFile: false,
                isSymbolicLink: false,
                modificationDate: nil
            )
        }
        return StabilityFileMetadata(
            isDirectory: false,
            isRegularFile: true,
            isSymbolicLink: false,
            modificationDate: modificationDate
        )
    }

    func contents(of directory: URL) throws -> [URL] {
        roots.contains(directory) ? files : []
    }

    func readPrefix(of file: URL, maxBytes: Int) throws -> Data {
        requestedReadLimits.append(maxBytes)
        let prefix = Data(data.prefix(maxBytes))
        totalBytesReturned += prefix.count
        return prefix
    }
}

private struct FailingStabilityFileAccess: StabilityFileAccessing {
    let error: Error

    func metadata(for url: URL) throws -> StabilityFileMetadata { throw error }
    func contents(of directory: URL) throws -> [URL] { throw error }
    func readPrefix(of file: URL, maxBytes: Int) throws -> Data { throw error }
}

private final class BlockingStabilityFileAccess: StabilityFileAccessing {
    let delay: TimeInterval
    private let lock = NSLock()
    private var metadataCalls = 0

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var metadataCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return metadataCalls
    }

    func metadata(for url: URL) throws -> StabilityFileMetadata {
        lock.lock()
        metadataCalls += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: delay)
        return StabilityFileMetadata(
            isDirectory: true,
            isRegularFile: false,
            isSymbolicLink: false,
            modificationDate: nil
        )
    }

    func contents(of directory: URL) throws -> [URL] { [] }
    func readPrefix(of file: URL, maxBytes: Int) throws -> Data { Data() }
}

private final class DeferredStabilityWorkScheduler {
    private let lock = NSLock()
    private var workItems = [DispatchWorkItem]()
    private var enqueuedCount = 0

    var totalEnqueued: Int {
        lock.lock()
        defer { lock.unlock() }
        return enqueuedCount
    }

    func enqueue(_ workItem: DispatchWorkItem) {
        lock.lock()
        workItems.append(workItem)
        enqueuedCount += 1
        lock.unlock()
    }

    func runNext() {
        lock.lock()
        let workItem = workItems.isEmpty ? nil : workItems.removeFirst()
        lock.unlock()
        workItem?.perform()
    }
}

private final class SelectiveStabilityFileAccess: StabilityFileAccessing {
    private let root: URL
    private let files: [URL]
    private let modificationDate: Date
    private let responses: [URL: Result<Data, Error>]

    init(
        root: URL,
        files: [URL],
        modificationDate: Date,
        responses: [URL: Result<Data, Error>]
    ) {
        self.root = root
        self.files = files
        self.modificationDate = modificationDate
        self.responses = responses
    }

    func metadata(for url: URL) throws -> StabilityFileMetadata {
        if url == root {
            return StabilityFileMetadata(
                isDirectory: true,
                isRegularFile: false,
                isSymbolicLink: false,
                modificationDate: nil
            )
        }
        return StabilityFileMetadata(
            isDirectory: false,
            isRegularFile: true,
            isSymbolicLink: false,
            modificationDate: modificationDate
        )
    }

    func contents(of directory: URL) throws -> [URL] {
        directory == root ? files : []
    }

    func readPrefix(of file: URL, maxBytes: Int) throws -> Data {
        guard let response = responses[file] else { throw CocoaError(.fileNoSuchFile) }
        return Data(try response.get().prefix(maxBytes))
    }
}
