import Foundation
import XCTest
@testable import StorageCleanerMac

final class StartupItemParsingTests: XCTestCase {
    private let parser = LaunchdPlistParser()

    func testParsesProgramAndAllCommonScalarFields() throws {
        let configuration = parser.parse(dictionary: [
            "Label": "com.example.agent",
            "Program": "/Applications/Example.app/Contents/MacOS/helper",
            "ProgramArguments": ["/ignored/when/program/is/present", "--background"],
            "RunAtLoad": true,
            "Disabled": false,
            "ProcessType": "Background",
            "LimitLoadToSessionType": "Aqua",
            "AssociatedBundleIdentifiers": ["com.example.app"],
            "WorkingDirectory": "/tmp/example",
            "UserName": "example-user",
            "GroupName": "staff",
            "StandardOutPath": "/tmp/example.out",
            "StandardErrorPath": "/tmp/example.err"
        ])

        XCTAssertEqual(configuration.label, "com.example.agent")
        XCTAssertEqual(configuration.resolvedExecutableURL?.path, "/Applications/Example.app/Contents/MacOS/helper")
        XCTAssertEqual(configuration.programArguments, ["/ignored/when/program/is/present", "--background"])
        XCTAssertEqual(configuration.runAtLoad, true)
        XCTAssertEqual(configuration.disabled, false)
        XCTAssertEqual(configuration.processType, "Background")
        XCTAssertEqual(configuration.limitLoadToSessionTypes, ["Aqua"])
        XCTAssertEqual(configuration.associatedBundleIdentifiers, ["com.example.app"])
        XCTAssertEqual(configuration.workingDirectory, "/tmp/example")
        XCTAssertEqual(configuration.userName, "example-user")
        XCTAssertEqual(configuration.groupName, "staff")
        XCTAssertEqual(configuration.standardOutPath, "/tmp/example.out")
        XCTAssertEqual(configuration.standardErrorPath, "/tmp/example.err")
        XCTAssertTrue(configuration.triggers.contains(.login))
        XCTAssertTrue(configuration.triggers.contains(.runAtLoad))
    }

    func testFallsBackToFirstProgramArgumentWithoutShellSplitting() {
        let configuration = parser.parse(dictionary: [
            "Label": "com.example.arguments",
            "ProgramArguments": ["/Applications/Example App.app/Contents/MacOS/Example App", "--name=a b"]
        ])

        XCTAssertEqual(configuration.resolvedExecutableURL?.path, "/Applications/Example App.app/Contents/MacOS/Example App")
        XCTAssertEqual(configuration.programArguments.count, 2)
        XCTAssertEqual(configuration.programArguments[1], "--name=a b")
    }

    func testResolvesBundleProgramOnlyRelativeToKnownApplicationBundle() {
        let application = URL(fileURLWithPath: "/Applications/Example.app")
        let configuration = parser.parse(
            dictionary: [
                "Label": "com.example.embedded",
                "BundleProgram": "Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"
            ],
            applicationBundleURL: application
        )

        XCTAssertEqual(
            configuration.resolvedExecutableURL?.path,
            "/Applications/Example.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper"
        )
        XCTAssertFalse(configuration.issues.contains(.unresolvedBundleProgram("Contents/Library/LoginItems/Helper.app/Contents/MacOS/Helper")))
    }

    func testRejectsEscapingBundleProgram() {
        let configuration = parser.parse(
            dictionary: ["Label": "com.example.escape", "BundleProgram": "../outside"],
            applicationBundleURL: URL(fileURLWithPath: "/Applications/Example.app")
        )

        XCTAssertNil(configuration.resolvedExecutableURL)
        XCTAssertTrue(configuration.issues.contains(.unresolvedBundleProgram("../outside")))
    }

    func testParsesKeepAliveBooleanAndDictionary() {
        let boolean = parser.parse(dictionary: ["Label": "boolean", "KeepAlive": true])
        XCTAssertEqual(boolean.keepAlive, true)
        XCTAssertEqual(boolean.keepAliveDictionary, [:])
        XCTAssertTrue(boolean.triggers.contains(.keepAlive))

        let dictionary = parser.parse(dictionary: [
            "Label": "dictionary",
            "KeepAlive": ["SuccessfulExit": false, "NetworkState": true]
        ])
        XCTAssertEqual(dictionary.keepAlive, true)
        XCTAssertEqual(dictionary.keepAliveDictionary["SuccessfulExit"], "0")
        XCTAssertEqual(dictionary.keepAliveDictionary["NetworkState"], "1")
    }

    func testParsesIntervalAndSingleCalendarTrigger() {
        let configuration = parser.parse(dictionary: [
            "Label": "com.example.timer",
            "StartInterval": 1_800,
            "StartCalendarInterval": ["Hour": 9, "Minute": 0]
        ])

        XCTAssertEqual(configuration.startInterval, 1_800)
        XCTAssertEqual(configuration.startCalendarIntervals, [
            .init(minute: 0, hour: 9, day: nil, weekday: nil, month: nil)
        ])
        XCTAssertTrue(configuration.triggers.contains(.interval(seconds: 1_800)))
        XCTAssertTrue(configuration.triggers.contains(.calendar(configuration.startCalendarIntervals)))
    }

    func testParsesCalendarArrayWatchQueueMachAndSocketTriggers() {
        let configuration = parser.parse(dictionary: [
            "Label": "com.example.triggered",
            "StartCalendarInterval": [
                ["Weekday": 1, "Hour": 8],
                ["Weekday": 6, "Hour": 10, "Minute": 30]
            ],
            "WatchPaths": ["/tmp/watch"],
            "QueueDirectories": ["/tmp/queue"],
            "MachServices": ["com.example.service": true],
            "Sockets": ["Listener": ["SockServiceName": "1234"]]
        ])

        XCTAssertEqual(configuration.startCalendarIntervals.count, 2)
        XCTAssertEqual(configuration.watchPaths, ["/tmp/watch"])
        XCTAssertEqual(configuration.queueDirectories, ["/tmp/queue"])
        XCTAssertEqual(configuration.machServices, ["com.example.service"])
        XCTAssertEqual(configuration.sockets, ["Listener"])
        XCTAssertTrue(configuration.triggers.contains(.watchPaths(["/tmp/watch"])))
        XCTAssertTrue(configuration.triggers.contains(.queueDirectories(["/tmp/queue"])))
        XCTAssertTrue(configuration.triggers.contains(.machServices(["com.example.service"])))
        XCTAssertTrue(configuration.triggers.contains(.sockets(["Listener"])))
    }

    func testDaemonPathProducesSystemBootTriggerWithoutClaimingImmediateRun() {
        let configuration = parser.parse(
            dictionary: ["Label": "com.example.daemon", "Program": "/usr/local/libexec/example"],
            plistURL: URL(fileURLWithPath: "/Library/LaunchDaemons/com.example.daemon.plist")
        )

        XCTAssertTrue(configuration.triggers.contains(.systemBoot))
        XCTAssertFalse(configuration.triggers.contains(.runAtLoad))
    }

    func testTriggerlessServiceIsClassifiedAsOnDemand() {
        let configuration = parser.parse(dictionary: [
            "Label": "com.example.ondemand",
            "Program": "/usr/local/libexec/example"
        ])
        XCTAssertEqual(configuration.triggers, [.onDemand])
    }

    func testMissingLabelAndProgramAreRetainedAsIssues() {
        let configuration = parser.parse(dictionary: ["Disabled": true])

        XCTAssertNil(configuration.label)
        XCTAssertTrue(configuration.issues.contains(.missingLabel))
        XCTAssertTrue(configuration.issues.contains(.missingExecutable))
        XCTAssertEqual(configuration.disabled, true)
    }

    func testMalformedAndNonDictionaryPlistsFailPrecisely() throws {
        XCTAssertThrowsError(try parser.parse(data: Data("not a plist".utf8))) {
            XCTAssertEqual($0 as? LaunchdPlistParserError, .malformedPropertyList)
        }

        let array = try PropertyListSerialization.data(fromPropertyList: ["not", "a", "dictionary"], format: .binary, options: 0)
        XCTAssertThrowsError(try parser.parse(data: array)) {
            XCTAssertEqual($0 as? LaunchdPlistParserError, .invalidRootObject)
        }
    }

    func testInvalidIndividualValuesDoNotDiscardOtherwiseUsableRecord() {
        let configuration = parser.parse(dictionary: [
            "Label": "com.example.tolerant",
            "Program": "/usr/bin/true",
            "RunAtLoad": "yes",
            "ProgramArguments": "/usr/bin/true",
            "StartInterval": 1.5
        ])

        XCTAssertEqual(configuration.label, "com.example.tolerant")
        XCTAssertEqual(configuration.resolvedExecutableURL?.path, "/usr/bin/true")
        XCTAssertTrue(configuration.issues.contains(.invalidValue(key: "RunAtLoad")))
        XCTAssertTrue(configuration.issues.contains(.invalidValue(key: "ProgramArguments")))
        XCTAssertTrue(configuration.issues.contains(.invalidValue(key: "StartInterval")))
    }

    func testRawValuesPreserveUnknownPropertyListFields() {
        let configuration = parser.parse(dictionary: [
            "Label": "com.example.raw",
            "CustomVendorKey": ["Nested": [1, 2, 3]]
        ])

        XCTAssertEqual(
            configuration.rawValues["CustomVendorKey"],
            .dictionary(["Nested": .array([.integer(1), .integer(2), .integer(3)])])
        )
    }

    func testLaunchTriggerDescriptionsAreSemantic() {
        XCTAssertEqual(StartupItemsDomain.LaunchTrigger.interval(seconds: 1_800).userFacingDescription, L10n.text("每 30 分钟运行", "Runs every 30 minutes"))
        XCTAssertEqual(StartupItemsDomain.LaunchTrigger.machServices(["service"]).userFacingDescription, L10n.text("收到请求时按需启动", "Starts on demand when requested"))
        XCTAssertEqual(
            StartupItemsDomain.LaunchTrigger.calendar([
                .init(minute: 30, hour: 9, day: nil, weekday: 1, month: nil),
            ]).userFacingDescription,
            L10n.text("每周一 09:30 运行", "Runs every Monday at 09:30")
        )
    }
}

final class BTMOutputParserTests: XCTestCase {
    func testParsesMultipleDiagnosticRecordsAndPreservesUnknownFields() {
        let output = """
        Records for UID 501

        UUID: 11111111-1111-1111-1111-111111111111
        Name: Example Helper
        Developer Name: Example, Inc.
        Team Identifier: TEAM123456
        Bundle Identifier: com.example.helper
        Parent Identifier: com.example.app
        URL: file:///Applications/Example.app/Contents/Library/LoginItems/Helper.app
        Type: login item
        Disposition: [enabled, allowed, visible]
        Future Field: retained

        UUID: 22222222-2222-2222-2222-222222222222
        Identifier: com.example.denied
        Executable Path: /Library/PrivilegedHelperTools/com.example.denied
        Disposition: disabled, disallowed
        """

        let records = BTMOutputParser().parse(output)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].bundleIdentifier, "com.example.helper")
        XCTAssertEqual(records[0].teamIdentifier, "TEAM123456")
        XCTAssertEqual(records[0].executableURL?.path, "/Applications/Example.app/Contents/Library/LoginItems/Helper.app")
        XCTAssertEqual(records[0].authorizationState, .approved)
        XCTAssertEqual(records[0].enablementState, .enabled)
        XCTAssertEqual(records[0].rawFields["futurefield"], "retained")
        XCTAssertEqual(records[1].identifier, "com.example.denied")
        XCTAssertEqual(records[1].authorizationState, .denied)
        XCTAssertEqual(records[1].enablementState, .disabled)
    }

    func testFormatDriftAndMalformedLinesDoNotEraseValidFields() {
        let output = """
        random heading without delimiter
        Service Identifier = com.example.changed
        Display Name = Changed Format
        Flags = notified requires-approval
        broken:line:with:extra:colons
        """

        let records = BTMOutputParser().parse(output)

        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records[0].identifier, "com.example.changed")
        XCTAssertEqual(records[0].name, "Changed Format")
        XCTAssertEqual(records[0].authorizationState, .requiresApproval)
    }

    func testHeadingOnlyOutputProducesNoFakeRecord() {
        XCTAssertTrue(BTMOutputParser().parse("Records for UID 501\nNo records found").isEmpty)
    }
}

final class LaunchctlOutputParserTests: XCTestCase {
    private let parser = LaunchctlOutputParser()

    func testParsesRunningPrintOutput() {
        let evidence = parser.parsePrint("""
        gui/501/com.example.agent = {
            active count = 1
            path = /Users/example/Library/LaunchAgents/com.example.agent.plist
            state = running
            program = /Applications/Example.app/Contents/MacOS/helper
            pid = 4321
            runs = 7
            last exit code = 0
        }
        """)

        XCTAssertEqual(evidence.domain, "gui/501")
        XCTAssertEqual(evidence.label, "com.example.agent")
        XCTAssertEqual(evidence.pid, 4321)
        XCTAssertEqual(evidence.runs, 7)
        XCTAssertEqual(evidence.registrationState, .registered)
        XCTAssertEqual(evidence.loadState, .loaded)
        XCTAssertEqual(evidence.processState, .running(pid: 4321))
    }

    func testLoadedWithoutPIDIsOnDemandNotDisabled() {
        let evidence = parser.parsePrint("""
        gui/501/com.example.ondemand = {
            active count = 0
            state = waiting
            runs = 2
            last exit code = 0
        }
        """)

        XCTAssertNil(evidence.pid)
        XCTAssertEqual(evidence.loadState, .onDemand)
        XCTAssertEqual(evidence.processState, .waiting)
    }

    func testFailedExitIsRetainedSeparatelyFromEnablement() {
        let evidence = parser.parsePrint("""
        system/com.example.failed = {
            state = failed
            last exit code = 78
        }
        """)

        XCTAssertEqual(evidence.processState, .failed(exitCode: 78))
        XCTAssertEqual(evidence.loadState, .loaded)
    }

    func testUnparseablePrintOutputProducesUnknownEvidence() {
        let evidence = parser.parsePrint("launchctl: service not found")
        XCTAssertEqual(evidence.registrationState, .unknown)
        XCTAssertEqual(evidence.loadState, .unknown)
        XCTAssertEqual(evidence.processState, .unknown)
    }

    func testParsesDisabledOverridesWithoutGuessingUnknownValues() {
        let overrides = parser.parseDisabledOverrides("""
        disabled services = {
            "com.example.disabled" => true
            "com.example.enabled" => false
            "com.example.unknown" => maybe
        }
        """)

        XCTAssertEqual(overrides, ["com.example.disabled": true, "com.example.enabled": false])
    }

    func testLegacyListMissingPIDMeansIdleLoadedService() throws {
        let records = parser.parseLegacyList("""
        PID\tStatus\tLabel
        -\t0\tcom.example.idle
        987\t0\tcom.example.running
        -\t78\tcom.example.failed
        """)

        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records[0].processState, .stopped)
        XCTAssertEqual(records[1].processState, .running(pid: 987))
        XCTAssertEqual(records[2].processState, .failed(exitCode: 78))
    }
}
