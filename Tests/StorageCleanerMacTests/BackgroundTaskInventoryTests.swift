import FileOperationShared
import Foundation
import XCTest
@testable import StorageCleanerMac

/// D177: login items come from the Background Task Management list, read by
/// the privileged helper so no password dialog appears (10-23 the performance
/// page said 0 login items while System Settings listed 5).
final class BackgroundTaskInventoryTests: XCTestCase {
    private static let openAtLoginRecord = """
    UUID: 00000000-0000-0000-0000-000000000177
    Identifier: 2.com.example.chat
    Name: Example Chat
    Bundle Identifier: com.example.chat
    Type: app (0x2)
    Disposition: [enabled, allowed, visible, notified] (0xb)
    """

    func testFilterKeepsSystemWideAndCallerRecordsOnly() throws {
        let output = """
        ========================
         Records for UID -2 : FFFFEEEE-DDDD-CCCC-BBBB-AAAAFFFFFFFE
        ========================
         Identifier: 16.com.example.daemon
         Name: Example Daemon
        ========================
         Records for UID 501 : 11111111-2222-3333-4444-555555555555
        ========================
         Identifier: 2.com.example.mine
         Name: Mine
        ========================
         Records for UID 502 : 66666666-7777-8888-9999-000000000000
        ========================
         Identifier: 2.com.example.someone-else
         Name: Someone Else
        ========================
         Records for UID unknown
        ========================
         Identifier: 2.com.example.unreadable
        """

        let kept = try XCTUnwrap(BackgroundTaskInventoryFilter.records(in: output, uid: 501))

        XCTAssertTrue(kept.contains("16.com.example.daemon"))
        XCTAssertTrue(kept.contains("2.com.example.mine"))
        XCTAssertFalse(kept.contains("someone-else"))
        XCTAssertFalse(kept.contains("unreadable"))
        XCTAssertEqual(BTMOutputParser().parse(kept).map(\.identifier), ["16.com.example.daemon", "2.com.example.mine"])
    }

    func testFilterRejectsTextWithoutAccountHeadings() {
        XCTAssertNil(BackgroundTaskInventoryFilter.records(in: Self.openAtLoginRecord, uid: 501))
        XCTAssertNil(BackgroundTaskInventoryFilter.records(in: "", uid: 501))
    }

    func testDefaultScanReadsHelperWithoutOptInOrCommand() async throws {
        let runner = InventoryRecordingRunner()
        let scanner = BackgroundTaskManagementScanner.helperBacked(
            helper: FakeBackgroundTaskInventory(.success(Self.openAtLoginRecord)),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        let candidates = try await scanner.scan(context: StartupScanContext(applicationDirectories: []))

        XCTAssertEqual(candidates.map(\.kind), [.openAtLogin])
        XCTAssertEqual(scanner.coverageIdentifier, BackgroundTaskManagementScanner.helperCoverageIdentifier)
        let commandCalls = await runner.recordedArguments()
        XCTAssertTrue(commandCalls.isEmpty, "the default scan never runs sfltool itself")
    }

    func testMissingHelperFailsQuietlyUnlessFullScanAsks() async throws {
        let runner = InventoryRecordingRunner(output: Self.openAtLoginRecord)
        let scanner = BackgroundTaskManagementScanner.helperBacked(
            helper: FakeBackgroundTaskInventory(.failure(.helperUnavailable)),
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: runner
        )

        do {
            _ = try await scanner.scan(context: StartupScanContext(applicationDirectories: []))
            XCTFail("a missing helper is reported, not hidden")
        } catch {
            XCTAssertEqual(error as? BackgroundTaskManagementScanError, .helperUnavailable)
        }
        let quietCalls = await runner.recordedArguments()
        XCTAssertTrue(quietCalls.isEmpty, "no password dialog without the Full Scan")

        let candidates = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [], includeBackgroundTaskDiagnostic: true))
        let fullScanCalls = await runner.recordedArguments()
        XCTAssertEqual(fullScanCalls, [["dumpbtm"]])
        XCTAssertEqual(candidates.map(\.kind), [.openAtLogin])
    }

    func testCommandDumpCountsOnlyThisAccountWhenHeadingsArePresent() async throws {
        let output = """
        Records for UID 501 : 11111111-2222-3333-4444-555555555555
        \(Self.openAtLoginRecord)
        Records for UID 502 : 66666666-7777-8888-9999-000000000000
        UUID: 00000000-0000-0000-0000-000000000502
        Identifier: 2.com.example.other
        Name: Other Account App
        Type: app (0x2)
        Disposition: [enabled, allowed]
        """
        let scanner = BackgroundTaskManagementScanner(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            runner: InventoryRecordingRunner(output: output)
        )

        let candidates = try await scanner.scan(context: StartupScanContext(
            applicationDirectories: [], currentUserID: 501, includeBackgroundTaskDiagnostic: true))

        XCTAssertEqual(candidates.map(\.name), ["Example Chat"])
    }

    func testHelperReadMakesManagedCoverageAvailableWithoutOptIn() async throws {
        let coordinator = StartupScanCoordinator(
            primaryScanners: [
                BackgroundTaskManagementScanner.helperBacked(
                    helper: FakeBackgroundTaskInventory(.success(Self.openAtLoginRecord)),
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    runner: InventoryRecordingRunner()
                ),
            ],
            secondaryScannerFactory: { _ in [] }
        )

        let result = try await coordinator.scan(context: StartupScanContext(applicationDirectories: []))

        XCTAssertTrue(result.coverage.managedItemCoverageAvailable)
        XCTAssertEqual(result.coverage.managedItemCount, 0)
        let source = try XCTUnwrap(result.coverage.sources.first { $0.source == .backgroundTaskDiagnostic })
        XCTAssertEqual(source.identifier, BackgroundTaskManagementScanner.helperCoverageIdentifier)
        XCTAssertNil(source.errorDescription)
    }

    @MainActor
    func testPerformancePageCountsLoginItemsFromHelper() async throws {
        let runner = InventoryRecordingRunner()
        let coordinator = StartupScanCoordinator(
            primaryScanners: [
                BackgroundTaskManagementScanner.helperBacked(
                    helper: FakeBackgroundTaskInventory(.success(Self.openAtLoginRecord)),
                    executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                    runner: runner
                ),
            ],
            secondaryScannerFactory: { _ in [] }
        )
        let store = try ScanStore.makeForTests(for: self, startupScanCoordinator: coordinator)

        store.refreshStartupItems()
        var waited = 0
        while store.isLoadingStartupItems, waited < 200 {
            try await Task.sleep(for: .milliseconds(10))
            waited += 1
        }

        XCTAssertFalse(store.isLoadingStartupItems)
        // The same projection as the "你有 N 个登录项" tile.
        let logins = StartupItemsPresentation.make(items: store.startupDomainItems, query: "", category: .all,
                                                   status: .all, source: .all, includeAppleSystem: false,
                                                   sort: .recommended, includeTechnicalDetails: false)
            .count(for: .loginItems)
        XCTAssertEqual(logins, 1)
        let commandCalls = await runner.recordedArguments()
        XCTAssertTrue(commandCalls.isEmpty)
    }

    func testDefaultCoordinatorUsesTheHelperBackedScanner() throws {
        let code = SwiftSourceScanning.compact(SwiftSourceScanning.code(try String(
            contentsOf: SwiftSourceScanning.projectRoot.appendingPathComponent(
                "Sources/StorageCleanerMac/Features/StartupItems/Scanning/StartupScanCoordinator.swift"),
            encoding: .utf8)))
        XCTAssertTrue(code.contains("BackgroundTaskManagementScanner.helperBacked(),"))
        XCTAssertFalse(code.contains("BackgroundTaskManagementScanner(),"))
    }

    /// The helper runs one fixed, read-only command; the client only asks.
    func testHelperRunsOnlyDumpBTMAndClientNeverInstallsTheHelper() throws {
        let sources = try SwiftSourceScanning.sources()
        let helperFiles = sources.filter { $0.key.hasPrefix("Sources/FileOperationHelper/") }
        XCTAssertFalse(helperFiles.isEmpty)
        for (path, raw) in helperFiles {
            XCTAssertFalse(SwiftSourceScanning.compactKeepingLiterals(raw).contains("resetbtm"), path)
        }
        let command = SwiftSourceScanning.compactKeepingLiterals(
            try XCTUnwrap(helperFiles["Sources/FileOperationHelper/BackgroundTaskInventory.swift"]))
        XCTAssertTrue(command.contains(#"staticletexecutable="/usr/bin/sfltool""#))
        XCTAssertTrue(command.contains(#"staticletarguments=["dumpbtm"]"#))
        XCTAssertTrue(command.contains("process.executableURL=URL(fileURLWithPath:executable)"))
        XCTAssertTrue(command.contains("process.arguments=arguments"))
        XCTAssertTrue(command.contains("process.standardInput=FileHandle.nullDevice"))
        XCTAssertTrue(command.contains("staticlettimeout:TimeInterval=15"))
        XCTAssertTrue(command.contains("staticletoutputLimit=16*1_024*1_024"))
        XCTAssertTrue(command.contains("BackgroundTaskInventoryFilter.records(in:"))
        XCTAssertEqual(SwiftSourceScanning.occurrences(of: "Process()", in: command), 1)

        let client = SwiftSourceScanning.compact(SwiftSourceScanning.code(
            try XCTUnwrap(sources["Sources/StorageCleanerMac/Services/HelperBackgroundTaskInventory.swift"])))
        for forbidden in ["prepareHelper", "SMAppService", "register", "AuthorizationCreate", "Shell."] {
            XCTAssertFalse(client.contains(forbidden), forbidden)
        }
        XCTAssertTrue(client.contains("proxy.applicationReplacementCapabilities?(reply:reply)"))
        XCTAssertTrue(client.contains("proxy.backgroundTaskInventory?(reply:reply)"))
    }
}

private struct FakeBackgroundTaskInventory: BackgroundTaskInventoryReading {
    let result: Result<String, BackgroundTaskManagementScanError>
    init(_ result: Result<String, BackgroundTaskManagementScanError>) { self.result = result }
    func dump(context: StartupScanContext) async throws -> String { try result.get() }
}

private actor InventoryRecordingRunner: StartupCommandRunning {
    private let output: String
    private var arguments = [[String]]()
    init(output: String = "") { self.output = output }
    func run(executable: String, arguments: [String], timeout: TimeInterval) async throws -> StartupCommandResult {
        self.arguments.append(arguments)
        return StartupCommandResult(terminationStatus: 0, standardOutput: output, standardError: "")
    }
    func recordedArguments() -> [[String]] { arguments }
}
