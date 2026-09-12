import Darwin
import XCTest
@testable import StorageCleanerMac

final class EnergyImpactServiceTests: XCTestCase {
    func testPowerConversionUsesEnergyDeltaAndSampleWindow() {
        XCTAssertEqual(
            EnergyImpactService.watts(fromNanojoules: 1_500_000_000, over: 1.5),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(EnergyImpactService.watts(fromNanojoules: 42, over: 0), 0)
    }

    func testDiskByteRateUsesMonotonicResourceCounters() {
        XCTAssertEqual(
            EnergyImpactService.byteRate(previous: 1_000, current: 7_000, over: 1.5),
            4_000
        )
        XCTAssertEqual(EnergyImpactService.byteRate(previous: 7_000, current: 1_000, over: 1), 0)
        XCTAssertEqual(EnergyImpactService.byteRate(previous: 1_000, current: 7_000, over: 0), 0)
    }

    @MainActor
    func testSnapshotPublishesPipelineAndPreviewBeforeMeasuredResult() async {
        var processPreview: EnergyImpactSnapshot?
        var phases: [EnergyImpactScanPhase] = []

        let measuredSnapshot = await EnergyImpactService.snapshot(
            sampleInterval: .milliseconds(1),
            onProgress: { phases.append($0) }
        ) { snapshot in
            processPreview = snapshot
        }

        XCTAssertEqual(phases, EnergyImpactScanPhase.allCases)
        XCTAssertEqual(phases.map(\.fractionCompleted), phases.map(\.fractionCompleted).sorted())
        XCTAssertNotNil(processPreview)
        XCTAssertEqual(processPreview?.sampleSeconds, 0)
        XCTAssertLessThanOrEqual(
            processPreview?.generatedAt ?? .distantFuture,
            measuredSnapshot.generatedAt
        )
    }

    func testCalibrationUsesMeasuredEnergyPerCPUSecondAndSafeBounds() {
        XCTAssertEqual(
            EnergyImpactService.calibratedWattsPerCore(
                measuredEnergyNanojoules: 2_000_000_000,
                cpuTimeSeconds: 2,
                fallback: 0.55
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            EnergyImpactService.calibratedWattsPerCore(
                measuredEnergyNanojoules: 0,
                cpuTimeSeconds: 0,
                fallback: 0.55
            ),
            0.55
        )
        XCTAssertEqual(
            EnergyImpactService.calibratedWattsPerCore(
                measuredEnergyNanojoules: 100_000_000_000,
                cpuTimeSeconds: 1,
                fallback: 0.55
            ),
            12
        )
    }

    func testMachTimeConversionUsesProvidedTimebase() {
        XCTAssertEqual(
            EnergyImpactService.secondsFromMachTime(
                24_000_000,
                numerator: 125,
                denominator: 3
            ),
            1,
            accuracy: 0.000_001
        )
    }

    func testParsesPSRowsWithElapsedAndCPUTime() {
        let output = """
            123     1  2048 03-19:47:07 435:23.17  13.3 /Applications/Example App.app/Contents/MacOS/Example App
            456   123  1024 00:02:03   0:01.50   0.4 /usr/libexec/exampled
        """

        let rows = EnergyImpactService.processRows(fromPSOutput: output)

        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].pid, 123)
        XCTAssertEqual(rows[0].parentPID, 1)
        XCTAssertEqual(rows[0].residentBytes, 2_097_152)
        XCTAssertEqual(rows[0].elapsedSeconds, 330_427)
        XCTAssertEqual(rows[0].cpuTimeSeconds, 26_123.17)
        XCTAssertEqual(rows[0].cpuPercent, 13.3)
        XCTAssertEqual(rows[0].path, "/Applications/Example App.app/Contents/MacOS/Example App")
    }

    func testPSRowsDeduplicateRepeatedPIDs() {
        let output = """
            123     1  2048 03-19:47:07 435:23.17  13.3 /Applications/Example App.app/Contents/MacOS/Example App
            123     1  2048 03-19:47:07 435:23.17  13.3 /Applications/Example App.app/Contents/MacOS/Example App
            456   123  1024 00:02:03   0:01.50   0.4 /usr/libexec/exampled
        """

        let rows = EnergyImpactService.processRows(fromPSOutput: output)

        XCTAssertEqual(rows.map(\.pid), [123, 456])
    }

    func testDurationParserSupportsMacProcessFormats() {
        XCTAssertEqual(EnergyImpactService.durationSeconds(from: "03-19:47:07"), 330_427)
        XCTAssertEqual(EnergyImpactService.durationSeconds(from: "435:23.17"), 26_123.17)
        XCTAssertEqual(EnergyImpactService.durationSeconds(from: "02:03:04"), 7_384)
        XCTAssertEqual(EnergyImpactService.durationSeconds(from: "00:00.74"), 0.74)
    }

    func testAppBundlePathExtractsContainingApplicationBundle() {
        XCTAssertEqual(
            EnergyImpactService.appBundlePath(in: "/Applications/Example App.app/Contents/MacOS/Example"),
            "/Applications/Example App.app"
        )
        XCTAssertEqual(
            EnergyImpactService.appBundlePath(in: "/Applications/Example App.app/Contents/Frameworks/Example Helper.app/Contents/MacOS/Example Helper"),
            "/Applications/Example App.app"
        )
        XCTAssertEqual(
            EnergyImpactService.appBundlePath(in: "/System/Applications/Utilities/Activity Monitor.app"),
            "/System/Applications/Utilities/Activity Monitor.app"
        )
        XCTAssertNil(EnergyImpactService.appBundlePath(in: "/usr/libexec/exampled"))
    }

    func testBundleIdentifierCandidateOnlyAcceptsBundleLikeProcessNames() {
        XCTAssertEqual(
            EnergyImpactService.bundleIdentifierCandidate(from: "com.teamviewer.Desktop"),
            "com.teamviewer.Desktop"
        )
        XCTAssertEqual(
            EnergyImpactService.bundleIdentifierCandidates(from: "/Library/Application Support/iStat Menus/com.bjango.istatmenus.daemon"),
            ["com.bjango.istatmenus.daemon", "com.bjango.istatmenus"]
        )
        XCTAssertEqual(
            EnergyImpactService.bundleIdentifierCandidates(from: "/System/Library/com.apple.example"),
            ["com.apple.example"]
        )
        XCTAssertNil(EnergyImpactService.bundleIdentifierCandidate(from: "WindowServer"))
    }

    func testSoftwareGroupKeyMergesSameBundleIdentifier() {
        let mainKey = EnergyImpactService.softwareGroupKey(
            appPath: "/Applications/Example.app",
            bundleIdentifier: "com.example.App"
        )
        let helperKey = EnergyImpactService.softwareGroupKey(
            appPath: "/Applications/Example.app/Contents/Library/LoginItems/Example Helper.app",
            bundleIdentifier: "com.example.App"
        )
        let processKey = EnergyImpactService.softwareGroupKey(
            appPath: "/usr/libexec/exampled",
            bundleIdentifier: nil
        )

        XCTAssertEqual(mainKey, helperKey)
        XCTAssertEqual(processKey, "app:/usr/libexec/exampled")
    }

    func testWattHourConversionUsesNanojoules() {
        XCTAssertEqual(EnergyImpactService.wattHours(fromNanojoules: 3_600_000_000_000), 1.0)
        XCTAssertEqual(EnergyImpactService.wattHours(fromNanojoules: 360_000_000_000), 0.1)
    }

    func testEnergyCounterSummationUsesNanojoules() {
        let samples = [
            EnergyResourceUsage(
                pid: 1,
                energyNanojoules: 3_600_000_000_000,
                cpuTimeMach: 0,
                processStartMach: 1,
                diskReadBytes: 0,
                diskWrittenBytes: 0
            ),
            EnergyResourceUsage(
                pid: 2,
                energyNanojoules: 1_800_000_000_000,
                cpuTimeMach: 0,
                processStartMach: 2,
                diskReadBytes: 0,
                diskWrittenBytes: 0
            )
        ]

        let wattHours = EnergyImpactService.wattHours(
            fromNanojoules: EnergyImpactService.sumEnergyNanojoules(samples)
        )

        XCTAssertEqual(wattHours, 1.5)
    }

    func testResourceUsageReadsKernelEnergyCounterForCurrentProcess() {
        let usage = EnergyImpactService.resourceUsage(pid: getpid())

        XCTAssertNotNil(usage)
        XCTAssertEqual(usage?.pid, getpid())
        XCTAssertGreaterThan(usage?.processStartMach ?? 0, 0)
    }

    func testEnergyFormattingUsesElectricalUnits() {
        XCTAssertEqual(EnergyImpactApp.energyText(0.0004), "0.4 mWh")
        XCTAssertEqual(EnergyImpactApp.energyText(0.42), "420 mWh")
        XCTAssertEqual(EnergyImpactApp.energyText(1.234), "1.23 Wh")
    }

    func testPowerFormattingUsesWatts() {
        XCTAssertEqual(EnergyImpactApp.powerText(0.42), "420 mW")
        XCTAssertEqual(EnergyImpactApp.powerText(1.234), "1.23 W")
        XCTAssertEqual(EnergyImpactApp.powerText(12.34), "12.3 W")
    }

    func testMeasurementQualityDistinguishesMeasuredMixedAndEstimatedApps() {
        XCTAssertEqual(makeEnergyApp(processCount: 3, measuredProcessCount: 3).measurementQuality, .measured)
        XCTAssertEqual(makeEnergyApp(processCount: 3, measuredProcessCount: 2).measurementQuality, .mixed)
        XCTAssertEqual(makeEnergyApp(processCount: 3, measuredProcessCount: 0).measurementQuality, .estimated)
    }

    func testSignificantEnergyUsesTheSameThresholdForEveryApplication() {
        XCTAssertFalse(
            makeEnergyApp(
                processCount: 1,
                measuredProcessCount: 1,
                currentPowerWatts: 0.49,
                cpuPercent: 4.9
            ).isSignificantCurrentEnergy
        )
        XCTAssertTrue(
            makeEnergyApp(
                processCount: 1,
                measuredProcessCount: 1,
                currentPowerWatts: 0.5,
                cpuPercent: 0
            ).isSignificantCurrentEnergy
        )
        XCTAssertTrue(
            makeEnergyApp(
                processCount: 1,
                measuredProcessCount: 1,
                currentPowerWatts: 0,
                cpuPercent: 5
            ).isSignificantCurrentEnergy
        )
    }

    func testSnapshotTotalIncludesMeasuredAndCalibratedSupplement() {
        let app = makeEnergyApp(processCount: 2, measuredProcessCount: 1)
        let snapshot = EnergyImpactSnapshot(
            generatedAt: Date(),
            scanSeconds: 1.3,
            sampleSeconds: 1.2,
            uptimeSeconds: 3_600,
            apps: [app],
            processCount: 2,
            measuredProcessCount: 1,
            unmeasuredProcessCount: 1,
            measuredTotalEnergyWh: 1.25,
            estimatedSupplementEnergyWh: 0.25,
            calibrationWattsPerCore: 0.75,
            usesLocalCalibration: true
        )

        XCTAssertEqual(snapshot.estimatedTotalEnergyWh, 1.5)
        XCTAssertEqual(snapshot.energyCoveragePercent, 50)
        XCTAssertEqual(snapshot.measurementQuality, .mixed)
    }

    func testEnergyPageKeepsMeasuredSamplingAndUsefulAppActions() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let serviceSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Services/EnergyImpactService.swift"),
            encoding: .utf8
        )
        let viewSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let geekPowerSource = try String(
            contentsOf: projectRoot.appendingPathComponent("Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekPowerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(serviceSource.contains("info.ri_energy_nj"))
        XCTAssertFalse(serviceSource.contains("/usr/bin/top"))
        XCTAssertFalse(serviceSource.contains("powerSamples(fromTopOutput:"))
        XCTAssertFalse(viewSource.contains("Task.sleep(for: .seconds(6))"))
        XCTAssertTrue(viewSource.contains("实时采样窗口"))
        XCTAssertTrue(viewSource.contains("平均功率"))
        XCTAssertTrue(viewSource.contains("arrow.up.forward.app"))
        XCTAssertTrue(viewSource.contains("activateFileViewerSelecting"))
        XCTAssertTrue(geekPowerSource.contains("GeekPowerEnergyCardState.resolve("))
        XCTAssertTrue(geekPowerSource.contains("geekHasEnergyImpactSnapshot"))
        XCTAssertTrue(geekPowerSource.contains("正在扫描应用…"))
        XCTAssertTrue(geekPowerSource.contains("当前没有显著能耗应用"))
        XCTAssertTrue(geekPowerSource.contains("ProgressView()"))
    }

    func testLiveEnergySnapshotWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_LIVE_ENERGY_TEST"] == "1" else {
            throw XCTSkip("Live energy sampling test is opt-in.")
        }

        let snapshot = await EnergyImpactService.snapshot()

        XCTAssertFalse(snapshot.apps.isEmpty)
        XCTAssertTrue(snapshot.apps.allSatisfy(\.isApplication))
        XCTAssertLessThanOrEqual(snapshot.measuredProcessCount, snapshot.processCount)
        XCTAssertEqual(snapshot.processCount, snapshot.measuredProcessCount + snapshot.unmeasuredProcessCount)
        XCTAssertGreaterThan(snapshot.sampleSeconds, 1)
        XCTAssertLessThan(snapshot.scanSeconds, 5)
        XCTAssertTrue(snapshot.estimatedTotalEnergyWh.isFinite)
        XCTAssertTrue(snapshot.totalCurrentPowerWatts.isFinite)
    }

    private func makeEnergyApp(
        processCount: Int,
        measuredProcessCount: Int,
        currentPowerWatts: Double = 0.4,
        cpuPercent: Double = 4
    ) -> EnergyImpactApp {
        EnergyImpactApp(
            id: "example-\(processCount)-\(measuredProcessCount)",
            name: "Example",
            path: "/Applications/Example.app",
            iconPath: "/Applications/Example.app",
            bundlePath: "/Applications/Example.app",
            bundleIdentifier: "com.example.App",
            measuredEnergyWh: 1,
            estimatedSupplementEnergyWh: 0.2,
            estimatedEnergyWh: 1.2,
            currentPowerWatts: currentPowerWatts,
            averagePowerWatts: 0.3,
            cpuPercent: cpuPercent,
            diskReadBytesPerSecond: 0,
            diskWriteBytesPerSecond: 0,
            residentBytes: 1_024,
            cumulativeCPUSeconds: 120,
            longestRunningSeconds: 3_600,
            processCount: processCount,
            measuredProcessCount: measuredProcessCount,
            processIDs: Array(1...processCount).map(Int32.init),
            isApplication: true
        )
    }
}
