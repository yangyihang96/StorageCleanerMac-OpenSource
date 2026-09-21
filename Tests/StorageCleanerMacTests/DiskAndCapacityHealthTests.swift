import Foundation
import XCTest
@testable import StorageCleanerMac

final class DiskAndCapacityHealthTests: XCTestCase {
    func testNetworkCapacityKeepsUnavailableSeparateFromFullDisk() {
        XCTAssertNil(MountedStorageVolumeService.networkCapacity(total: nil, available: nil))
        XCTAssertNil(MountedStorageVolumeService.networkCapacity(total: 0, available: 0))
        XCTAssertNil(MountedStorageVolumeService.networkCapacity(total: 100, available: -1))
        XCTAssertNil(MountedStorageVolumeService.networkCapacity(total: 100, available: 101))
        let full = MountedStorageVolumeService.networkCapacity(total: 100, available: 0)
        XCTAssertEqual(full?.totalBytes, 100)
        XCTAssertEqual(full?.availableBytes, 0)
        XCTAssertEqual(MountedStorageVolumeService.networkCapacity(total: 100, available: 25)?.availableBytes, 25)
    }

    func testMountedVolumeClassificationSeparatesNetworkAndPhysicalExternalDisks() {
        XCTAssertEqual(
            MountedStorageVolumeService.classification(
                isLocal: false,
                isInternal: nil,
                isDiskImage: false
            ),
            .network
        )
        XCTAssertEqual(
            MountedStorageVolumeService.classification(
                isLocal: true,
                isInternal: false,
                isDiskImage: false
            ),
            .external
        )
        XCTAssertNil(MountedStorageVolumeService.classification(
            isLocal: true,
            isInternal: true,
            isDiskImage: false
        ))
        XCTAssertNil(MountedStorageVolumeService.classification(
            isLocal: true,
            isInternal: false,
            isDiskImage: true
        ))
    }

    func testShellDiskRunnerPhysicallyCancelsCurrentTask() async {
        let task = Task.detached { () -> DiskHealthCommandFailure? in
            do {
                _ = try ShellDiskHealthCommandRunner().capture(DiskHealthCommand(
                    executable: "/bin/sleep",
                    arguments: ["0.8"],
                    timeout: 2
                ))
                return nil
            } catch let failure as DiskHealthCommandFailure {
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

    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testDiskParserReadsTruthfulDiskAndNestedNVMeFields() throws {
        let snapshot = DiskHealthService.parseDiskInfo(
            completeDiskPlist,
            systemProfilerData: verifiedNVMeJSON,
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.status, .healthy)
        XCTAssertEqual(snapshot.smartStatus, .verified)
        XCTAssertEqual(snapshot.isTRIMEnabled, true)
        XCTAssertEqual(snapshot.fileSystem, "APFS")
        XCTAssertEqual(snapshot.isSolidState, true)
        XCTAssertEqual(snapshot.isInternal, true)
        XCTAssertEqual(snapshot.isFileVaultEnabled, true)
        XCTAssertEqual(snapshot.totalBytes, 1_000_000)
        XCTAssertEqual(snapshot.availableBytes, 400_000)
        XCTAssertEqual(snapshot.checkedAt, checkedAt)
    }

    func testDiskParserSeparatesVerifiedFailingUnsupportedAndMissingSMART() {
        let cases: [(Data?, DiskSMARTStatus, HealthStatus, HealthAvailability)] = [
            (nvmeJSON(smart: "Verified", trim: "Yes"), .verified, .healthy, .available),
            (nvmeJSON(smart: "Failing", trim: "Yes"), .failing, .actionRequired, .available),
            (nvmeJSON(smart: "Not Supported", trim: "Yes"), .unsupported, .attention, .available),
            (nvmeJSON(smart: nil, trim: "Yes"), .unavailable, .attention, .partial),
            (nil, .unavailable, .attention, .partial)
        ]

        for (profilerData, expectedSMART, expectedStatus, expectedAvailability) in cases {
            let snapshot = DiskHealthService.parseDiskInfo(
                completeDiskPlist,
                systemProfilerData: profilerData,
                checkedAt: checkedAt
            )
            XCTAssertEqual(snapshot.smartStatus, expectedSMART)
            XCTAssertEqual(snapshot.status, expectedStatus)
            XCTAssertEqual(snapshot.availability, expectedAvailability)
        }
    }

    func testDiskParserHandlesSymbolicProfilerValuesAndTRIMStates() {
        let enabled = DiskHealthService.parseDiskInfo(
            completeDiskPlist,
            systemProfilerData: nvmeJSON(smart: "spsmart_status_verified", trim: "sptrim_yes"),
            checkedAt: checkedAt
        )
        let disabled = DiskHealthService.parseDiskInfo(
            completeDiskPlist,
            systemProfilerData: nvmeJSON(smart: "spsmart_status_verified", trim: "sptrim_no"),
            checkedAt: checkedAt
        )
        let missing = DiskHealthService.parseDiskInfo(
            completeDiskPlist,
            systemProfilerData: nvmeJSON(smart: "spsmart_status_verified", trim: nil),
            checkedAt: checkedAt
        )

        XCTAssertEqual(enabled.smartStatus, .verified)
        XCTAssertEqual(enabled.isTRIMEnabled, true)
        XCTAssertEqual(disabled.isTRIMEnabled, false)
        XCTAssertEqual(disabled.status, .attention)
        XCTAssertNil(missing.isTRIMEnabled)
        XCTAssertEqual(missing.availability, .partial)
        XCTAssertEqual(missing.status, .attention)
    }

    func testDiskParserDoesNotAttributeAnotherDriveWhenTargetHasNoMatch() {
        let snapshot = DiskHealthService.parseDiskInfo(
            targetedDiskPlist,
            systemProfilerData: Data(
                """
                {
                  "SPNVMeDataType": [
                    {
                      "bsd_name": "diskOTHER1",
                      "spnvme_smart_status": "Failing",
                      "spnvme_trim_support": "No"
                    },
                    {
                      "bsd_name": "diskOTHER2",
                      "spnvme_smart_status": "Verified",
                      "spnvme_trim_support": "Yes"
                    }
                  ]
                }
                """.utf8
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.smartStatus, .unavailable)
        XCTAssertNil(snapshot.isTRIMEnabled)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
    }

    func testDiskParserSelectsExactTargetFromMultipleNVMeCandidates() {
        let snapshot = DiskHealthService.parseDiskInfo(
            targetedDiskPlist,
            systemProfilerData: Data(
                """
                {
                  "SPNVMeDataType": [
                    {
                      "bsd_name": "diskOTHER",
                      "spnvme_smart_status": "Failing",
                      "spnvme_trim_support": "No"
                    },
                    {
                      "bsd_name": "diskSTART",
                      "spnvme_smart_status": "Verified",
                      "spnvme_trim_support": "Yes"
                    }
                  ]
                }
                """.utf8
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.smartStatus, .verified)
        XCTAssertEqual(snapshot.isTRIMEnabled, true)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.status, .healthy)
    }

    func testDiskParserRejectsSingleCandidateWithExplicitDifferentDiskIdentifier() {
        let snapshot = DiskHealthService.parseDiskInfo(
            targetedDiskPlist,
            systemProfilerData: Data(
                """
                {
                  "SPNVMeDataType": [
                    {
                      "bsd_name": "diskOTHER",
                      "spnvme_smart_status": "Failing",
                      "spnvme_trim_support": "No"
                    }
                  ]
                }
                """.utf8
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.smartStatus, .unavailable)
        XCTAssertNil(snapshot.isTRIMEnabled)
        XCTAssertEqual(snapshot.availability, .partial)
        XCTAssertEqual(snapshot.status, .attention)
    }

    func testDiskParserAllowsSingleCandidateWithoutComparableDiskIdentifier() {
        let snapshot = DiskHealthService.parseDiskInfo(
            targetedDiskPlist,
            systemProfilerData: Data(
                """
                {
                  "SPNVMeDataType": [
                    {
                      "_name": "Synthetic Test SSD",
                      "spnvme_smart_status": "Verified",
                      "spnvme_trim_support": "Yes"
                    }
                  ]
                }
                """.utf8
            ),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.smartStatus, .verified)
        XCTAssertEqual(snapshot.isTRIMEnabled, true)
        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.status, .healthy)
    }

    func testDiskParserUsesSafeCapacityFallbackAndReusesPressureClassification() {
        let attention = DiskHealthService.parseDiskInfo(
            diskPlistWithoutCapacity,
            systemProfilerData: verifiedNVMeJSON,
            capacitySnapshot: StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 150),
            checkedAt: checkedAt
        )
        let critical = DiskHealthService.parseDiskInfo(
            diskPlistWithoutCapacity,
            systemProfilerData: verifiedNVMeJSON,
            capacitySnapshot: StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 50),
            checkedAt: checkedAt
        )

        XCTAssertEqual(attention.totalBytes, 1_000)
        XCTAssertEqual(attention.availableBytes, 150)
        XCTAssertEqual(attention.status, .attention)
        XCTAssertEqual(critical.status, .actionRequired)
    }

    func testDiskParserPrefersMountedVolumeCapacityOverZeroRootVolumeFreeSpace() {
        let diskInfo = diskPlist(
            extraEntries: """
            <key>ParentWholeDisk</key><string>disk0</string>
            <key>FilesystemType</key><string>apfs</string>
            <key>TotalSize</key><integer>1000</integer>
            <key>FreeSpace</key><integer>0</integer>
            <key>AvailableSpace</key><integer>0</integer>
            <key>APFSContainerFree</key><integer>300</integer>
            <key>Internal</key><true/>
            <key>SolidState</key><true/>
            <key>FileVault</key><true/>
            """
        )

        let snapshot = DiskHealthService.parseDiskInfo(
            diskInfo,
            systemProfilerData: verifiedNVMeJSON,
            capacitySnapshot: StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 450),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.totalBytes, 1_000)
        XCTAssertEqual(snapshot.availableBytes, 450)
        XCTAssertEqual(snapshot.status, .healthy)
    }

    func testDiskParserUsesAPFSContainerFreeWhenMountedVolumeCapacityIsUnavailable() {
        let diskInfo = diskPlist(
            extraEntries: """
            <key>FilesystemType</key><string>apfs</string>
            <key>TotalSize</key><integer>1000</integer>
            <key>FreeSpace</key><integer>0</integer>
            <key>AvailableSpace</key><integer>0</integer>
            <key>APFSContainerFree</key><integer>300</integer>
            """
        )

        let snapshot = DiskHealthService.parseDiskInfo(
            diskInfo,
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.totalBytes, 1_000)
        XCTAssertEqual(snapshot.availableBytes, 300)
    }

    func testDiskParserKeepsAuthoritativeZeroMountedVolumeCapacity() {
        let snapshot = DiskHealthService.parseDiskInfo(
            completeDiskPlist,
            systemProfilerData: verifiedNVMeJSON,
            capacitySnapshot: StorageCapacitySnapshot(totalBytes: 1_000_000, availableBytes: 0),
            checkedAt: checkedAt
        )

        XCTAssertEqual(snapshot.availableBytes, 0)
        XCTAssertEqual(snapshot.status, .actionRequired)
    }

    func testMalformedAndEmptyDiskDataNeverBecomeHealthy() {
        let malformed = DiskHealthService.parseDiskInfo(
            Data("not a plist".utf8),
            systemProfilerData: Data("not json".utf8),
            checkedAt: checkedAt
        )
        let empty = DiskHealthService.parseDiskInfo(
            emptyDiskPlist,
            systemProfilerData: emptyNVMeJSON,
            checkedAt: checkedAt
        )

        XCTAssertEqual(malformed.availability, .unavailable)
        XCTAssertEqual(malformed.status, .unavailable)
        XCTAssertEqual(malformed.smartStatus, .unavailable)
        XCTAssertEqual(empty.availability, .unavailable)
        XCTAssertEqual(empty.status, .unavailable)
    }

    func testDiskServiceRunsOnlyFixedReadOnlyCommandsWithWatchdogs() {
        let runner = RecordingDiskHealthRunner(responses: [
            DiskHealthService.diskInfoCommand: .success(completeDiskPlist),
            DiskHealthService.nvmeProfilerCommand: .success(verifiedNVMeJSON)
        ])
        let service = DiskHealthService(
            runner: runner,
            capacityProvider: { nil },
            now: { self.checkedAt }
        )

        let snapshot = service.snapshot()

        XCTAssertEqual(snapshot.status, .healthy)
        XCTAssertEqual(runner.commands, [
            DiskHealthCommand(
                executable: "/usr/sbin/diskutil",
                arguments: ["info", "-plist", "/"],
                timeout: 3
            ),
            DiskHealthCommand(
                executable: "/usr/sbin/system_profiler",
                arguments: ["-json", "-detailLevel", "mini", "-timeout", "5", "SPNVMeDataType"],
                timeout: 8
            )
        ])
        let allArguments = runner.commands.flatMap(\.arguments)
        XCTAssertFalse(allArguments.contains("verifyVolume"))
        XCTAssertFalse(allArguments.contains("repairVolume"))
        XCTAssertFalse(allArguments.contains("fsck_apfs"))
        XCTAssertTrue(runner.commands.allSatisfy { $0.executable.hasPrefix("/usr/sbin/") })
    }

    func testExternalVolumeHealthUsesOneReadOnlyDiskutilArgumentWithoutShellParsing() {
        let volumeURL = URL(
            fileURLWithPath: "/Volumes/Backup; touch SHOULD_NOT_EXIST",
            isDirectory: true
        )
        let command = DiskHealthService.diskInfoCommand(for: volumeURL)
        let runner = RecordingDiskHealthRunner(responses: [
            command: .success(completeDiskPlist),
        ])
        let service = DiskHealthService(
            runner: runner,
            capacityProvider: { nil },
            now: { self.checkedAt }
        )

        _ = service.snapshot(
            for: volumeURL,
            capacitySnapshot: StorageCapacitySnapshot(
                totalBytes: 2_000_000,
                availableBytes: 1_000_000
            )
        )

        XCTAssertEqual(runner.commands, [command])
        XCTAssertEqual(command.executable, "/usr/sbin/diskutil")
        XCTAssertEqual(command.arguments, [
            "info",
            "-plist",
            "/Volumes/Backup; touch SHOULD_NOT_EXIST",
        ])
        XCTAssertFalse(runner.commands.contains(DiskHealthService.nvmeProfilerCommand))
    }

    func testMountedVolumeProbeReadsRealRemainingLifeAndTemperatureAndMarksDiskImages() {
        let physicalURL = URL(fileURLWithPath: "/Volumes/ROG", isDirectory: true)
        let physicalCommand = DiskHealthService.diskInfoCommand(for: physicalURL)
        let physicalRunner = RecordingDiskHealthRunner(responses: [
            physicalCommand: .success(Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
                "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0"><dict>
                  <key>FilesystemType</key><string>apfs</string>
                  <key>Internal</key><false/>
                  <key>SolidState</key><true/>
                  <key>SMARTStatus</key><string>Verified</string>
                  <key>SMARTDeviceSpecificKeysMayVaryNotGuaranteed</key><dict>
                    <key>PERCENTAGE_USED</key><integer>7</integer>
                    <key>TEMPERATURE</key><integer>318</integer>
                  </dict>
                </dict></plist>
                """.utf8
            )),
        ])
        let physicalProbe = DiskHealthService(
            runner: physicalRunner,
            capacityProvider: { nil },
            now: { self.checkedAt }
        ).mountedVolumeProbe(
            for: physicalURL,
            capacitySnapshot: StorageCapacitySnapshot(
                totalBytes: 1_000,
                availableBytes: 500
            )
        )

        XCTAssertFalse(physicalProbe.isDiskImage)
        XCTAssertEqual(physicalProbe.remainingLifePercent, 93)
        XCTAssertEqual(try XCTUnwrap(physicalProbe.temperatureCelsius), 44.85, accuracy: 0.01)
        XCTAssertEqual(physicalProbe.health.smartStatus, .verified)
        XCTAssertEqual(physicalProbe.health.remainingLifePercent, 93)
        XCTAssertEqual(
            try XCTUnwrap(physicalProbe.health.temperatureCelsius),
            44.85,
            accuracy: 0.01
        )

        let imageURL = URL(fileURLWithPath: "/Volumes/Installer", isDirectory: true)
        let imageCommand = DiskHealthService.diskInfoCommand(for: imageURL)
        let imageRunner = RecordingDiskHealthRunner(responses: [
            imageCommand: .success(Data(
                """
                <?xml version="1.0" encoding="UTF-8"?>
                <plist version="1.0"><dict>
                  <key>BusProtocol</key><string>Disk Image</string>
                  <key>FilesystemType</key><string>hfs</string>
                  <key>Internal</key><false/>
                </dict></plist>
                """.utf8
            )),
        ])
        let imageProbe = DiskHealthService(
            runner: imageRunner,
            capacityProvider: { nil },
            now: { self.checkedAt }
        ).mountedVolumeProbe(
            for: imageURL,
            capacitySnapshot: StorageCapacitySnapshot(
                totalBytes: 1_000,
                availableBytes: 500
            )
        )

        XCTAssertTrue(imageProbe.isDiskImage)
        XCTAssertNil(imageProbe.remainingLifePercent)
        XCTAssertNil(imageProbe.temperatureCelsius)
    }

    func testDiskServiceMapsCommandFailuresToSafeAvailabilityWithoutRawErrors() throws {
        let cases: [(DiskHealthCommandFailure, HealthAvailability)] = [
            (.permissionDenied, .permissionDenied),
            (.timedOut, .timedOut),
            (.cancelled, .cancelled),
            (.unavailable, .unavailable)
        ]

        for (failure, expectedAvailability) in cases {
            let runner = RecordingDiskHealthRunner(defaultResponse: .failure(failure))
            let service = DiskHealthService(
                runner: runner,
                capacityProvider: { nil },
                now: { self.checkedAt }
            )

            let snapshot = service.snapshot()
            let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

            XCTAssertEqual(snapshot.availability, expectedAvailability)
            XCTAssertEqual(snapshot.status, .unavailable)
            XCTAssertEqual(snapshot.smartStatus, .unavailable)
            XCTAssertFalse(encoded.contains("TEST-RAW-STDERR"))
            XCTAssertFalse(snapshot.summaryText?.contains("TEST-RAW-STDERR") == true)
        }
    }

    func testDiskServiceMapsUnknownRunnerErrorWithoutPropagatingDescription() throws {
        let runner = RecordingDiskHealthRunner(
            defaultResponse: .failure(RawDiskRunnerError(message: "TEST-RAW-STDERR Private Volume diskTEST"))
        )
        let snapshot = DiskHealthService(
            runner: runner,
            capacityProvider: { nil },
            now: { self.checkedAt }
        ).snapshot()
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertEqual(snapshot.status, .unavailable)
        XCTAssertFalse(encoded.contains("TEST-RAW-STDERR"))
        XCTAssertFalse(encoded.contains("Private Volume"))
        XCTAssertFalse(encoded.contains("diskTEST"))
    }

    func testDiskSnapshotNeverRetainsSerialModelBSDNameOrVolumeName() throws {
        let snapshot = DiskHealthService.parseDiskInfo(
            privacyDiskPlist,
            systemProfilerData: privacyNVMeJSON,
            checkedAt: checkedAt
        )
        let encoded = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)

        for privateValue in [
            "TEST-SERIAL-DO-NOT-KEEP",
            "Synthetic Test SSD",
            "diskTEST",
            "Private Test Volume"
        ] {
            XCTAssertFalse(encoded.contains(privateValue))
        }
        XCTAssertEqual(snapshot.fileSystem, "APFS")
        XCTAssertEqual(snapshot.smartStatus, .verified)
    }

    func testCapacityHistoryRecordsOnePointPerLocalDayAndKeepsNinety() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        for day in 0..<100 {
            try service.record(capacityPoint(day: day, availableBytes: 800 - Int64(day)))
            try service.record(capacityPoint(day: day, availableBytes: 700 - Int64(day)))
        }

        let points = try service.load()
        XCTAssertEqual(points.count, 90)
        XCTAssertEqual(Set(points.map(\.dayKey)).count, 90)
        XCTAssertEqual(points.first?.dayKey, "2023-11-24")
        XCTAssertEqual(points.last?.availableBytes, 601)
        XCTAssertEqual(points, points.sorted { $0.recordedAt < $1.recordedAt })
    }

    func testCapacityHistoryUsesInjectedLocalCalendarForDailyDedupe() throws {
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = try XCTUnwrap(TimeZone(identifier: "Australia/Sydney"))
        let service = CapacityHistoryService(storage: .memory, calendar: sydney)
        let first = CapacityHistoryPoint(
            recordedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T14:10:00Z")),
            totalBytes: 1_000,
            availableBytes: 500,
            availableForImportantUsageBytes: 450
        )
        let second = CapacityHistoryPoint(
            recordedAt: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T14:30:00Z")),
            totalBytes: 1_000,
            availableBytes: 480,
            availableForImportantUsageBytes: 430
        )

        try service.record(first)
        try service.record(second)

        let points = try service.load()
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.dayKey, "2026-07-16")
        XCTAssertEqual(points.first?.availableBytes, 480)
    }

    func testCapacityHistoryKeepsNewerSameDayPointWhenOlderPointArrivesLate() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        let dayStart = utcCalendar.startOfDay(for: capacityDate(day: 4))
        let newer = CapacityHistoryPoint(
            recordedAt: dayStart.addingTimeInterval(20 * 60 * 60),
            totalBytes: 1_000,
            availableBytes: 500,
            availableForImportantUsageBytes: 490
        )
        let olderWithDifferentCapacity = CapacityHistoryPoint(
            recordedAt: dayStart.addingTimeInterval(60 * 60),
            totalBytes: 2_000,
            availableBytes: 1_500,
            availableForImportantUsageBytes: 1_490
        )

        try service.record(newer)
        try service.record(olderWithDifferentCapacity)

        let points = try service.load()
        XCTAssertEqual(points.count, 1)
        XCTAssertEqual(points.first?.recordedAt, newer.recordedAt)
        XCTAssertEqual(points.first?.totalBytes, 1_000)
        XCTAssertEqual(points.first?.availableBytes, 500)
        XCTAssertEqual(points.first?.segmentID, 0)
    }

    func testCapacityHistoryRejectsCrossDayLatePointAndContinuesLatestSegment() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        try service.record(capacityPoint(day: 2, totalBytes: 1_000, availableBytes: 500))
        try service.record(capacityPoint(day: 1, totalBytes: 2_000, availableBytes: 1_500))
        try service.record(capacityPoint(day: 9, totalBytes: 1_000, availableBytes: 450))

        let points = try service.load()
        XCTAssertEqual(points.map(\.recordedAt), [capacityDate(day: 2), capacityDate(day: 9)])
        XCTAssertEqual(points.map(\.segmentID), [0, 0])
        XCTAssertEqual(points.map(\.totalBytes), [1_000, 1_000])

        let trend = try service.trendSnapshot()
        XCTAssertEqual(trend.sevenDayDeltaBytes, -50)
        XCTAssertNil(trend.thirtyDayDeltaBytes)
    }

    func testSameDayReplacementRebasesSegmentAgainstPreviousDayWhenCapacityRecovers() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        let dayOneStart = utcCalendar.startOfDay(for: capacityDate(day: 1))
        let morning = CapacityHistoryPoint(
            recordedAt: dayOneStart.addingTimeInterval(8 * 60 * 60),
            totalBytes: 2_000,
            availableBytes: 1_500,
            availableForImportantUsageBytes: 1_490
        )
        let evening = CapacityHistoryPoint(
            recordedAt: dayOneStart.addingTimeInterval(20 * 60 * 60),
            totalBytes: 1_000,
            availableBytes: 600,
            availableForImportantUsageBytes: 590
        )

        try service.record(capacityPoint(day: 0, totalBytes: 1_000, availableBytes: 700))
        try service.record(morning)
        XCTAssertEqual(try service.load().map(\.segmentID), [0, 1])

        try service.record(evening)

        let points = try service.load()
        XCTAssertEqual(points.map(\.totalBytes), [1_000, 1_000])
        XCTAssertEqual(points.map(\.segmentID), [0, 0])
        XCTAssertEqual(points.last?.recordedAt, evening.recordedAt)
    }

    func testSameDayReplacementKeepsOneNewSegmentWhenFinalCapacityStillDiffersFromPreviousDay() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        let dayOneStart = utcCalendar.startOfDay(for: capacityDate(day: 1))
        let morning = CapacityHistoryPoint(
            recordedAt: dayOneStart.addingTimeInterval(8 * 60 * 60),
            totalBytes: 2_000,
            availableBytes: 1_500,
            availableForImportantUsageBytes: 1_490
        )
        let evening = CapacityHistoryPoint(
            recordedAt: dayOneStart.addingTimeInterval(20 * 60 * 60),
            totalBytes: 1_600,
            availableBytes: 1_100,
            availableForImportantUsageBytes: 1_090
        )

        try service.record(capacityPoint(day: 0, totalBytes: 1_000, availableBytes: 700))
        try service.record(morning)
        try service.record(evening)

        let points = try service.load()
        XCTAssertEqual(points.map(\.totalBytes), [1_000, 1_600])
        XCTAssertEqual(points.map(\.segmentID), [0, 1])
        XCTAssertEqual(points.last?.recordedAt, evening.recordedAt)
    }

    func testCapacityHistoryStartsNewSegmentOnlyAboveFivePercent() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        try service.record(capacityPoint(day: 0, totalBytes: 1_000, availableBytes: 700))
        try service.record(capacityPoint(day: 1, totalBytes: 1_050, availableBytes: 710))
        try service.record(capacityPoint(day: 2, totalBytes: 1_103, availableBytes: 720))

        let points = try service.load()
        XCTAssertEqual(points.map(\.segmentID), [0, 0, 1])
    }

    func testCapacityTrendBuildsSevenAndThirtyDayDeltasFromCurrentSegment() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        for day in 0...30 {
            try service.record(capacityPoint(day: day, availableBytes: 900 - Int64(day * 10)))
        }

        let trend = try service.trendSnapshot()

        XCTAssertEqual(trend.availability, .available)
        XCTAssertEqual(trend.status, .healthy)
        XCTAssertEqual(trend.totalBytes, 1_000)
        XCTAssertEqual(trend.availableBytes, 600)
        XCTAssertEqual(trend.availableForImportantUsageBytes, 590)
        XCTAssertEqual(trend.sevenDayDeltaBytes, -70)
        XCTAssertEqual(trend.thirtyDayDeltaBytes, -300)
    }

    func testCapacityTrendDoesNotCrossSegmentsAndDoesNotPredictWithInsufficientSamples() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        for day in 0...30 {
            try service.record(capacityPoint(day: day, availableBytes: 900 - Int64(day)))
        }
        try service.record(capacityPoint(day: 31, totalBytes: 2_000, availableBytes: 1_500))

        let trend = try service.trendSnapshot()

        XCTAssertEqual(trend.totalBytes, 2_000)
        XCTAssertNil(trend.sevenDayDeltaBytes)
        XCTAssertNil(trend.thirtyDayDeltaBytes)
    }

    func testCapacityTrendPreviewIsSideEffectFreeAndPreservesImportantUsageCapacity() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        try service.record(capacityPoint(day: 0, availableBytes: 900))
        let previewPoint = CapacityHistoryPoint(
            recordedAt: capacityDate(day: 7),
            totalBytes: 1_000,
            availableBytes: 800,
            availableForImportantUsageBytes: 850
        )

        let preview = try service.trendSnapshot(including: previewPoint)

        XCTAssertEqual(preview.recordedAt, previewPoint.recordedAt)
        XCTAssertEqual(preview.availableBytes, 800)
        XCTAssertEqual(preview.availableForImportantUsageBytes, 850)
        XCTAssertEqual(preview.sevenDayDeltaBytes, -100)
        XCTAssertEqual(try service.load().count, 1)
        XCTAssertEqual(try service.load().last?.recordedAt, capacityDate(day: 0))
    }

    func testCapacityTrendReusesStorageCapacityPressure() throws {
        let attentionService = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        try attentionService.record(capacityPoint(day: 0, totalBytes: 1_000, availableBytes: 150))
        let criticalService = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        try criticalService.record(capacityPoint(day: 0, totalBytes: 1_000, availableBytes: 50))

        XCTAssertEqual(try attentionService.trendSnapshot().status, .attention)
        XCTAssertEqual(try criticalService.trendSnapshot().status, .actionRequired)
    }

    func testCapacityHistoryRejectsInvalidAndNegativePoints() throws {
        let service = CapacityHistoryService(storage: .memory, calendar: utcCalendar)
        try service.record(capacityPoint(day: 0, totalBytes: -1, availableBytes: 0))
        try service.record(capacityPoint(day: 1, totalBytes: 1_000, availableBytes: -1))
        try service.record(capacityPoint(day: 2, totalBytes: 1_000, availableBytes: 1_001))
        try service.record(CapacityHistoryPoint(
            recordedAt: capacityDate(day: 3),
            totalBytes: 1_000,
            availableBytes: 500,
            availableForImportantUsageBytes: -1
        ))

        XCTAssertEqual(try service.load(), [])
        XCTAssertEqual(try service.trendSnapshot().availability, .unavailable)
    }

    func testMalformedFileLoadsSafelyAndCanRecoverWithAtomicWrite() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fileURL = sandbox.appendingPathComponent("capacity-history.json")
        try Data("{ malformed".utf8).write(to: fileURL)
        let service = CapacityHistoryService(storage: .file(fileURL), calendar: utcCalendar)

        XCTAssertEqual(try service.load(), [])
        try service.record(capacityPoint(day: 0, availableBytes: 500))
        XCTAssertEqual(try service.load().count, 1)
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: sandbox.path), [fileURL.lastPathComponent])
    }

    func testMalformedDecodedPointsAreFiltered() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fileURL = sandbox.appendingPathComponent("capacity-history.json")
        let malformedPoints: [[String: Any]] = [[
            "recordedAt": 1_000,
            "totalBytes": -1,
            "availableBytes": 9,
            "dayKey": "private/path",
            "segmentID": -5
        ]]
        try JSONSerialization.data(withJSONObject: malformedPoints).write(to: fileURL)

        let service = CapacityHistoryService(storage: .file(fileURL), calendar: utcCalendar)

        XCTAssertEqual(try service.load(), [])
    }

    func testExtremeDecodedSegmentIDIsNormalizedBeforeStartingNewSegment() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fileURL = sandbox.appendingPathComponent("capacity-history.json")
        let extreme = CapacityHistoryPoint(
            recordedAt: capacityDate(day: 0),
            totalBytes: 1_000,
            availableBytes: 500,
            availableForImportantUsageBytes: 490,
            dayKey: "untrusted-day-key",
            segmentID: .max
        )
        try JSONEncoder().encode([extreme]).write(to: fileURL)
        let service = CapacityHistoryService(storage: .file(fileURL), calendar: utcCalendar)

        let loaded = try service.load()
        XCTAssertEqual(loaded.first?.segmentID, 0)
        guard loaded.first?.segmentID != .max else { return }

        try service.record(capacityPoint(day: 1, totalBytes: 2_000, availableBytes: 1_500))
        let updated = try service.load()
        XCTAssertEqual(updated.map(\.segmentID), [0, 1])
        XCTAssertEqual(updated.map(\.totalBytes), [1_000, 2_000])
    }

    func testCorruptedReusedSegmentIDsBecomeMonotonicTransitionsAndContinueLatestSegment() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fileURL = sandbox.appendingPathComponent("capacity-history.json")
        let corrupted = [
            CapacityHistoryPoint(
                recordedAt: capacityDate(day: 0),
                totalBytes: 1_000,
                availableBytes: 900,
                availableForImportantUsageBytes: 890,
                dayKey: "ignored-0",
                segmentID: 0
            ),
            CapacityHistoryPoint(
                recordedAt: capacityDate(day: 7),
                totalBytes: 1_000,
                availableBytes: 800,
                availableForImportantUsageBytes: 790,
                dayKey: "ignored-1",
                segmentID: 1
            ),
            CapacityHistoryPoint(
                recordedAt: capacityDate(day: 14),
                totalBytes: 1_000,
                availableBytes: 700,
                availableForImportantUsageBytes: 690,
                dayKey: "ignored-2",
                segmentID: 0
            )
        ]
        try JSONEncoder().encode(corrupted).write(to: fileURL)
        let service = CapacityHistoryService(storage: .file(fileURL), calendar: utcCalendar)

        XCTAssertEqual(try service.load().map(\.segmentID), [0, 1, 2])

        try service.record(capacityPoint(day: 21, availableBytes: 600))
        let updated = try service.load()
        XCTAssertEqual(updated.map(\.segmentID), [0, 1, 2, 2])
        XCTAssertEqual(updated.last?.recordedAt, capacityDate(day: 21))

        let trend = try service.trendSnapshot()
        XCTAssertEqual(trend.sevenDayDeltaBytes, -100)
        XCTAssertNil(trend.thirtyDayDeltaBytes)
    }

    func testFileStorageRoundTripsOnlyBoundedPrivacySafeFields() throws {
        let sandbox = makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let fileURL = sandbox.appendingPathComponent("capacity-history.json")
        let writer = CapacityHistoryService(storage: .file(fileURL), calendar: utcCalendar)
        try writer.record(capacityPoint(day: 0, availableBytes: 500))
        let reader = CapacityHistoryService(storage: .file(fileURL), calendar: utcCalendar)

        XCTAssertEqual(try reader.load(), try writer.load())
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [[String: Any]])
        let keys = try XCTUnwrap(raw.first).keys
        XCTAssertEqual(Set(keys), Set([
            "recordedAt",
            "totalBytes",
            "availableBytes",
            "availableForImportantUsageBytes",
            "dayKey",
            "segmentID"
        ]))
        let encoded = String(decoding: try Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertFalse(encoded.contains(sandbox.path))
        XCTAssertFalse(encoded.contains("path"))
        XCTAssertFalse(encoded.contains("volume"))
        XCTAssertFalse(encoded.contains("fileName"))
    }

    func testDefaultCapacityHistoryLocationUsesApplicationSupport() {
        let url = CapacityHistoryService.defaultStorageURL

        XCTAssertTrue(url.path.contains("/Library/Application Support/"))
        XCTAssertEqual(url.lastPathComponent, "capacity-history.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "StorageCleanerMac")
    }

    private var completeDiskPlist: Data {
        diskPlist(
            extraEntries: """
                <key>FilesystemType</key><string>apfs</string>
                <key>TotalSize</key><integer>1000000</integer>
                <key>FreeSpace</key><integer>400000</integer>
                <key>Internal</key><true/>
                <key>SolidState</key><true/>
                <key>FileVault</key><true/>
            """
        )
    }

    private var diskPlistWithoutCapacity: Data {
        diskPlist(
            extraEntries: """
                <key>FilesystemName</key><string>APFS</string>
                <key>Internal</key><true/>
                <key>SolidState</key><true/>
                <key>FileVault</key><true/>
            """
        )
    }

    private var targetedDiskPlist: Data {
        diskPlist(
            extraEntries: """
                <key>FilesystemType</key><string>apfs</string>
                <key>TotalSize</key><integer>1000000</integer>
                <key>FreeSpace</key><integer>400000</integer>
                <key>Internal</key><true/>
                <key>SolidState</key><true/>
                <key>FileVault</key><true/>
                <key>ParentWholeDisk</key><string>diskSTART</string>
            """
        )
    }

    private var emptyDiskPlist: Data {
        diskPlist(extraEntries: "")
    }

    private var privacyDiskPlist: Data {
        diskPlist(
            extraEntries: """
                <key>FilesystemType</key><string>apfs</string>
                <key>TotalSize</key><integer>1000000</integer>
                <key>FreeSpace</key><integer>400000</integer>
                <key>Internal</key><true/>
                <key>SolidState</key><true/>
                <key>FileVault</key><true/>
                <key>VolumeName</key><string>Private Test Volume</string>
                <key>DeviceNode</key><string>/dev/diskTEST</string>
                <key>MediaName</key><string>Synthetic Test SSD</string>
                <key>SerialNumber</key><string>TEST-SERIAL-DO-NOT-KEEP</string>
            """
        )
    }

    private var verifiedNVMeJSON: Data {
        Data(
            """
            {
              "SPNVMeDataType": [
                {
                  "_name": "Synthetic Controller",
                  "_items": [
                    {
                      "_name": "Synthetic Test SSD",
                      "spnvme_smart_status": "spsmart_status_verified",
                      "spnvme_trim_support": "sptrim_yes"
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
    }

    private var privacyNVMeJSON: Data {
        Data(
            """
            {
              "SPNVMeDataType": [
                {
                  "_name": "Synthetic Test SSD",
                  "serial_number": "TEST-SERIAL-DO-NOT-KEEP",
                  "bsd_name": "diskTEST",
                  "spnvme_smart_status": "Verified",
                  "spnvme_trim_support": "Yes"
                }
              ]
            }
            """.utf8
        )
    }

    private var emptyNVMeJSON: Data {
        Data("{\"SPNVMeDataType\": []}".utf8)
    }

    private func diskPlist(extraEntries: String) -> Data {
        Data(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
            \(extraEntries)
            </dict>
            </plist>
            """.utf8
        )
    }

    private func nvmeJSON(smart: String?, trim: String?) -> Data {
        var item = [String: Any]()
        if let smart { item["spnvme_smart_status"] = smart }
        if let trim { item["spnvme_trim_support"] = trim }
        return try! JSONSerialization.data(withJSONObject: ["SPNVMeDataType": [item]])
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func capacityDate(day: Int) -> Date {
        utcCalendar.date(
            byAdding: .day,
            value: day,
            to: Date(timeIntervalSince1970: 1_700_000_000)
        )!
    }

    private func capacityPoint(
        day: Int,
        totalBytes: Int64 = 1_000,
        availableBytes: Int64
    ) -> CapacityHistoryPoint {
        CapacityHistoryPoint(
            recordedAt: capacityDate(day: day),
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            availableForImportantUsageBytes: availableBytes - 10
        )
    }

    private func makeSandbox() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskAndCapacityHealthTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private final class RecordingDiskHealthRunner: DiskHealthCommandRunning {
    private let responses: [DiskHealthCommand: Result<Data, Error>]
    private let defaultResponse: Result<Data, Error>?
    private(set) var commands = [DiskHealthCommand]()

    init(
        responses: [DiskHealthCommand: Result<Data, Error>] = [:],
        defaultResponse: Result<Data, Error>? = nil
    ) {
        self.responses = responses
        self.defaultResponse = defaultResponse
    }

    convenience init(defaultResponse: Result<Data, Error>) {
        self.init(responses: [:], defaultResponse: defaultResponse)
    }

    func capture(_ command: DiskHealthCommand) throws -> Data {
        commands.append(command)
        guard let response = responses[command] ?? defaultResponse else {
            throw DiskHealthCommandFailure.unavailable
        }
        return try response.get()
    }
}

private struct RawDiskRunnerError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}
