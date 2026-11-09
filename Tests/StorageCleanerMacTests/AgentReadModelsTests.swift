import AgentGatewayCore
import AgentShared
import FanControlShared
import XCTest
@testable import StorageCleanerMac

/// D266 on the App's real types: each mapper gives only the fields it names,
/// every ID is a token, and nothing a fixture plants as private comes out.
final class AgentReadModelsTests: XCTestCase {
    static let home = "/Users/agent-fixture"
    private let tokens = AgentItemTokens()

    /// What the router does with a result, plus a search for what must not appear.
    private func checked(_ value: AgentJSONValue, tool: String, absent: [String] = [],
                         file: StaticString = #filePath, line: UInt = #line) throws -> AgentJSONValue {
        let cleaned = try AgentResultGuard(home: Self.home).cleaned(value)
        let schema = try XCTUnwrap(AgentToolCatalog.tool(named: tool)).outputSchema
        XCTAssertNil(AgentSchemaValidator.violation(of: cleaned, against: schema), file: file, line: line)
        let text = String(decoding: try JSONEncoder().encode(cleaned), as: UTF8.self)
        XCTAssertFalse(text.contains(Self.home), "home folder left in \(text)", file: file, line: line)
        for fragment in absent { XCTAssertFalse(text.contains(fragment), "\(fragment) left in \(text)", file: file, line: line) }
        return cleaned
    }

    private func listResult(_ items: [AgentJSONValue], module: String = "junk") -> AgentJSONValue {
        ["module": .string(module), "status": "ready", "items": .array(items)]
    }

    // MARK: Junk

    private static let sessionID = ScanSessionID()

    static func candidate(rule: String = "system.user-caches", path: String = "\(home)/.cache/com.fixture.app",
                          bytes: Int64 = 4_096, risk: CleanupRisk = .safe, closing: [String] = []) -> ScanCandidate {
        let source = URL(fileURLWithPath: path)
        return ScanCandidate(
            id: ScanCandidateID(), sessionID: sessionID, ruleID: rule, ruleSelectionPolicyVersion: 1,
            categoryID: "system", categoryTitle: "系统缓存", subcategoryTitle: "应用缓存",
            sourceURL: source, allowedRootURL: source.deletingLastPathComponent(),
            snapshot: FileSnapshot(
                identity: FileIdentity(deviceID: 7, inode: 42, entryKind: .directory, creationTimeNanoseconds: 1),
                standardizedPath: source.path, volumeIdentifier: "private-volume-identifier",
                logicalSizeBytes: bytes * 2, allocatedSizeBytes: bytes, modificationTimeNanoseconds: 1,
                isWritableVolume: true, isCloudItem: false, isCloudPlaceholder: false, hasSymbolicLinkComponent: false),
            risk: risk,
            recommendation: CleanupRecommendation(level: .recommended, reasonCode: "fixture", evidenceCodes: ["private-evidence-code"]),
            defaultSelection: .selected, executionEligibility: .eligible, measurementCompleteness: .complete,
            isManuallySelectable: true, action: .moveToTrash, requiredClosedBundleIDs: closing, reason: "可以再生")
    }

    func testAJunkRowGivesATokenAWrittenHomeAndNoInternals() throws {
        let row = Self.candidate(closing: ["com.fixture.app"])
        let result = try checked(listResult([AgentReadModels.junkItem(row, tokens: tokens)]), tool: "list_results",
                                 absent: ["private-volume-identifier", "private-evidence-code", "allowedRoot", "inode"])
        let item = try XCTUnwrap(result["items"]?[0])
        let id = try XCTUnwrap(item["id"]?.stringValue)
        XCTAssertEqual(tokens.internalID(for: id, module: "junk"), row.id.rawValue.uuidString)
        XCTAssertEqual(item["name"]?.stringValue, "com.fixture.app")
        XCTAssertEqual(item["path"]?.stringValue, "~/.cache/com.fixture.app")
        XCTAssertEqual(item["category"]?.stringValue, "系统缓存")
        XCTAssertEqual(item["subcategory"]?.stringValue, "应用缓存")
        XCTAssertEqual(item["size_bytes"]?.integerValue, 4_096)
        XCTAssertEqual(item["risk"]?.stringValue, "safe")
        XCTAssertEqual(item["preselected"]?.boolValue, true)
        XCTAssertEqual(item["required_closed_bundle_ids"]?[0]?.stringValue, "com.fixture.app")
    }

    func testAMailAttachmentRowGivesItsCategoryAndSizeOnly() throws {
        let path = "\(Self.home)/Library/Containers/com.apple.mail/Data/Library/Mail Downloads/2026 工资单.pdf"
        let row = Self.candidate(rule: "mail.downloaded-attachments", path: path, bytes: 8_192)
        let result = try checked(listResult([AgentReadModels.junkItem(row, tokens: tokens)]), tool: "list_results",
                                 absent: ["工资单", "Mail Downloads", "可以再生"])
        let item = try XCTUnwrap(result["items"]?[0])
        XCTAssertEqual(item["private"]?.boolValue, true)
        XCTAssertNil(item["name"])
        XCTAssertNil(item["path"])
        XCTAssertEqual(item["size_bytes"]?.integerValue, 8_192)
        XCTAssertNotNil(item["id"]?.stringValue)
    }

    // MARK: Startup items

    private func startupItem() throws -> StartupItemsDomain.Item {
        let plist = URL(fileURLWithPath: "\(Self.home)/Library/LaunchAgents/com.fixture.agent.plist")
        let configuration = LaunchdPlistParser().parse(dictionary: [
            "Label": "com.fixture.agent",
            "ProgramArguments": ["\(Self.home)/bin/fixture-agent", "--token=private-launch-argument"],
            "EnvironmentVariables": ["PRIVATE_VARIABLE": "private-environment-value"]
        ], plistURL: plist)
        var state = StartupItemsDomain.State.unknown
        state.enablement = .enabled
        state.load = .loaded
        state.process = .running(pid: 4_321)
        var attribution = StartupItemsDomain.Attribution(evidence: [])
        attribution.applicationName = "Fixture"
        attribution.developerName = "Fixture Ltd"
        attribution.designatedRequirement = "private-designated-requirement"
        let component = StartupItemsDomain.Candidate(
            id: "launchd:\(plist.path)", source: .launchdPlist, kind: .userLaunchAgent, scope: .currentUser,
            name: "Fixture Agent", label: "com.fixture.agent", plistURL: plist,
            executableURL: URL(fileURLWithPath: "\(Self.home)/bin/fixture-agent"), applicationURL: nil,
            configuration: configuration, state: state, attribution: attribution, actionCapability: .readOnly,
            diagnosticEvidence: ["world-writable", "private-diagnostic-evidence"])
        return StartupItemsDomain.Item(
            id: component.id, kind: .userLaunchAgent, scope: .currentUser, name: "Fixture Agent", components: [component],
            state: state, attribution: attribution, actionCapability: .readOnly, warnings: ["private-warning"])
    }

    func testAStartupItemGivesNoProgramArgumentsOrEvidence() throws {
        let row = try startupItem()
        let result = try checked(listResult([AgentReadModels.startupItem(row, tokens: tokens)], module: "startup_items"), tool: "list_results",
                                 absent: ["private-launch-argument", "fixture-agent", "PRIVATE_VARIABLE", "private-environment-value",
                                          "private-designated-requirement", "private-diagnostic-evidence", "private-warning",
                                          "LaunchAgents", "4321"])
        let item = try XCTUnwrap(result["items"]?[0])
        let id = try XCTUnwrap(item["id"]?.stringValue)
        XCTAssertEqual(tokens.internalID(for: id, module: "startup_items"), row.id)
        XCTAssertEqual(item["name"]?.stringValue, "Fixture Agent")
        XCTAssertEqual(item["kind"]?.stringValue, "userLaunchAgent")
        XCTAssertEqual(item["scope"]?.stringValue, "currentUser")
        XCTAssertEqual(item["enablement"]?.stringValue, "enabled")
        XCTAssertEqual(item["load"]?.stringValue, "loaded")
        XCTAssertEqual(item["process"]?.stringValue, "running")
        XCTAssertEqual(item["application_name"]?.stringValue, "Fixture")
        XCTAssertEqual(item["developer_name"]?.stringValue, "Fixture Ltd")
        XCTAssertEqual(item["needs_attention"]?.boolValue, true)
        XCTAssertEqual(item["component_count"]?.integerValue, 1)
    }

    // MARK: Applications

    func testAnInstalledAppGivesCountsNotRelatedPaths() throws {
        let path = "\(Self.home)/Applications/Fixture.app"
        let row = InstalledAppItem(
            id: path, name: "Fixture", bundleIdentifier: "com.fixture.app", path: path, version: "1.2", build: "34",
            category: "工具", appDescription: "private-description", developerName: "Fixture Ltd", sizeBytes: 1_024,
            source: "App Store", modifiedAt: Date(timeIntervalSince1970: 1_790_000_000),
            relatedPaths: ["\(Self.home)/Library/Application Support/private-related-path"], relatedItems: [], status: .installed)
        let result = try checked(listResult([AgentReadModels.installedApp(row, tokens: tokens)], module: "installed_apps"), tool: "list_results",
                                 absent: ["private-description", "private-related-path", "Fixture.app"])
        let item = try XCTUnwrap(result["items"]?[0])
        let id = try XCTUnwrap(item["id"]?.stringValue)
        XCTAssertEqual(tokens.internalID(for: id, module: "installed_apps"), path)
        XCTAssertEqual(item["bundle_id"]?.stringValue, "com.fixture.app")
        XCTAssertEqual(item["version"]?.stringValue, "1.2")
        XCTAssertEqual(item["size_bytes"]?.integerValue, 1_024)
        XCTAssertEqual(item["related_path_count"]?.integerValue, 1)
        XCTAssertEqual(item["status"]?.stringValue, "installed")
        XCTAssertEqual(item["modified_at"]?.stringValue, "2026-09-21T14:13:20Z")
    }

    func testAnAppWithoutAProperIdentifierDoesNotCostThePage() throws {
        let row = InstalledAppItem(id: "/Applications/Odd.app", name: "Odd", bundleIdentifier: "/Applications/Odd.app", path: "/Applications/Odd.app",
                                   version: "1", build: "1", category: "", appDescription: "", sizeBytes: 1, source: "", modifiedAt: nil,
                                   relatedPaths: [], relatedItems: [], status: .installed)
        let result = try checked(listResult([AgentReadModels.installedApp(row, tokens: tokens)], module: "installed_apps"), tool: "list_results")
        XCTAssertEqual(result["items"]?[0]?["bundle_id"], .null)
        XCTAssertEqual(result["items"]?[0]?["name"]?.stringValue, "Odd")
    }

    func testAnAppUpdateGivesVersionsAndNoFileOrFeed() throws {
        var row = AppUpdateItem(
            id: "/Applications/Fixture.app", name: "Fixture", bundleIdentifier: "com.fixture.app", path: "/Applications/Fixture.app",
            version: "1.0", build: "1", source: "Sparkle", method: .sparkle, feedURL: "https://private-feed.example/appcast.xml",
            caskToken: nil, currentVersion: "1.0", latestVersion: "2.0", modifiedAt: nil)
        row.signingTeamIdentifier = "PRIVATETEAM"
        row.codeSigningIdentifier = "private.signing.identifier"
        row.executableURL = URL(fileURLWithPath: "/Applications/Fixture.app/Contents/MacOS/private-executable")
        let result = try checked(listResult([AgentReadModels.appUpdate(row, tokens: tokens)], module: "app_updates"), tool: "list_results",
                                 absent: ["private-feed", "PRIVATETEAM", "private.signing", "private-executable", "/Applications"])
        let item = try XCTUnwrap(result["items"]?[0])
        let id = try XCTUnwrap(item["id"]?.stringValue)
        XCTAssertEqual(tokens.internalID(for: id, module: "app_updates"), "/Applications/Fixture.app")
        XCTAssertEqual(item["name"]?.stringValue, "Fixture")
        XCTAssertEqual(item["installed_version"]?.stringValue, "1.0")
        XCTAssertEqual(item["available_version"]?.stringValue, "2.0")
        XCTAssertEqual(item["provider"]?.stringValue, "sparkle")
    }

    // MARK: Operation records

    static func report(rulesVersion: String = "cleanup-rules-fixture", ruleID: String = "system.user-caches",
                       path: String = "\(home)/.cache/com.fixture.app") -> CleanReport {
        let planID = CleanPlanID(rawValue: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let receipt = CleanupMoveReceipt(
            originalPath: path, resultingItemURL: URL(fileURLWithPath: "\(home)/.Trash/private-trash-name"), disposition: .trash,
            movedIdentity: FileIdentity(deviceID: 7, inode: 42, entryKind: .directory, creationTimeNanoseconds: 1),
            verification: .identityVerified, movedAt: date)
        let items = [
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: ruleID, sourcePath: path, estimatedBytes: 4_096, outcome: .moved(receipt)),
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: ruleID, sourcePath: path + "-2", estimatedBytes: 1, outcome: .skipped(.itemMissing)),
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: ruleID, sourcePath: path + "-3", estimatedBytes: 1,
                            outcome: .failed(CleanFailure(code: .moveOutcomeUnknown, detailCode: "private-detail-code")))
        ]
        return CleanReport(
            id: UUID(), planID: planID, sessionID: ScanSessionID(), rulesVersion: rulesVersion, disposition: .trash, scanWasPartial: false,
            startedAt: date, completedAt: date.addingTimeInterval(5), outcome: .partiallyCompleted, items: items,
            summary: CleanReportSummary(requestedItemCount: 3, movedItemCount: 1, skippedItemCount: 1, failedItemCount: 1, notProcessedItemCount: 0,
                                        unverifiedMoveCount: 0, plannedBytes: 4_098, movedToRecoverableLocationBytes: 4_096,
                                        reclaimableAfterEmptyingTrashBytes: nil, permanentlyFreedBytes: 0, availableSpaceDeltaBytes: nil),
            persistenceFailure: "private-persistence-failure")
    }

    func testARecordSummaryComesFromTheIndexWithoutPaths() throws {
        let index = CleanupReportIndex(report: Self.report(), orderingDate: Date(timeIntervalSince1970: 1_790_000_005))
        let value = AgentReadModels.operationRecordSummary(index)
        let result = try checked(["items": [value], "next_cursor": nil], tool: "list_operation_records",
                                 absent: ["Caches", "private-persistence-failure"])
        let item = try XCTUnwrap(result["items"]?[0])
        XCTAssertEqual(item["id"]?.stringValue, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(item["outcome"]?.stringValue, "partiallyCompleted")
        XCTAssertEqual(item["moved_count"]?.integerValue, 1)
        XCTAssertEqual(item["failed_count"]?.integerValue, 1)
        XCTAssertEqual(item["recoverable_count"]?.integerValue, 1)
        XCTAssertEqual(item["needs_verification"]?.boolValue, true)
    }

    func testARecordSummaryOfAPrivateOperationHasNoSubject() throws {
        let path = "\(Self.home)/Library/Containers/com.tencent.xinWeChat/private-chat-file.pdf"
        let index = CleanupReportIndex(report: Self.report(rulesVersion: ChatFilesTrashService.ruleID, ruleID: ChatFilesTrashService.ruleID, path: path),
                                       orderingDate: Date())
        XCTAssertNotNil(index.subject, "the index itself does name the chat file")
        let result = try checked(["items": [AgentReadModels.operationRecordSummary(index)], "next_cursor": nil], tool: "list_operation_records",
                                 absent: ["private-chat-file"])
        XCTAssertEqual(result["items"]?[0]?["private"]?.boolValue, true)
    }

    func testARecordGivesWrittenHomesAndResultsButNoInternals() throws {
        let result = try checked(["record": AgentReadModels.operationRecord(Self.report())], tool: "get_operation_record",
                                 absent: ["private-trash-name", "private-persistence-failure", "private-detail-code", "inode"])
        let record = try XCTUnwrap(result["record"])
        XCTAssertEqual(record["id"]?.stringValue, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(record["needs_verification"]?.boolValue, true)
        XCTAssertEqual(record["items"]?[0]?["path"]?.stringValue, "~/.cache/com.fixture.app")
        XCTAssertEqual(record["items"]?[0]?["result"]?.stringValue, "moved")
        XCTAssertEqual(record["items"]?[0]?["can_restore"]?.boolValue, true)
        XCTAssertEqual(record["items"]?[1]?["result"]?.stringValue, "skipped")
        XCTAssertEqual(record["items"]?[1]?["detail"]?.stringValue, "itemMissing")
        XCTAssertEqual(record["items"]?[2]?["result"]?.stringValue, "failed")
        XCTAssertEqual(record["items"]?[2]?["detail"]?.stringValue, "moveOutcomeUnknown")
    }

    func testARecordOfPrivateItemsGivesNoPaths() throws {
        let path = "\(Self.home)/Library/Containers/com.apple.mail/Data/private-attachment.pdf"
        let report = Self.report(ruleID: "mail.downloaded-attachments", path: path)
        let result = try checked(["record": AgentReadModels.operationRecord(report)], tool: "get_operation_record", absent: ["private-attachment"])
        let item = try XCTUnwrap(result["record"]?["items"]?[0])
        XCTAssertEqual(item["private"]?.boolValue, true)
        XCTAssertNil(item["path"])
    }

    func testARecordCapsItsItemsAndSaysHowManyThereAre() throws {
        var report = Self.report()
        let many = (0..<500).map { index in
            CleanReportItem(id: UUID(), planItemID: UUID(), ruleID: "system.user-caches", sourcePath: "/fixture/\(index)", estimatedBytes: 1, outcome: .notProcessed)
        }
        report = CleanReport(id: report.id, planID: report.planID, sessionID: report.sessionID, rulesVersion: report.rulesVersion,
                             disposition: report.disposition, scanWasPartial: false, startedAt: report.startedAt,
                             completedAt: report.completedAt, outcome: report.outcome, items: many, summary: report.summary)
        let result = try checked(["record": AgentReadModels.operationRecord(report)], tool: "get_operation_record")
        XCTAssertEqual(result["record"]?["items"]?.arrayValue?.count, 200)
        XCTAssertEqual(result["record"]?["item_count"]?.integerValue, 500)
    }

    // MARK: Hardware and history

    func testAHardwareRecordGivesWhatWasAskedAndTheResult() throws {
        let record = HardwareOperationRecord(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, recordedAt: Date(timeIntervalSince1970: 1_790_000_000),
            operation: .fanSpeed, outcome: .succeeded, targetRPMByFan: [0: 3_000], automaticFanIDs: [1],
            powerSetting: "lowpowermode", powerValue: 1, powerSource: "battery", macMiniMode: .whenOnAC, errorCode: "fixture_error",
            automaticRestoreReason: .fanLeaseExpired)
        let result = try checked(["items": [AgentReadModels.hardwareOperation(record)], "next_cursor": nil], tool: "list_hardware_operations")
        let item = try XCTUnwrap(result["items"]?[0])
        XCTAssertEqual(item["operation"]?.stringValue, "fanSpeed")
        XCTAssertEqual(item["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(item["time"]?.stringValue, "2026-09-21T14:13:20Z")
        XCTAssertEqual(item["target_rpm_by_fan"]?["0"]?.integerValue, 3_000)
        XCTAssertEqual(item["power_setting"]?.stringValue, "lowpowermode")
        XCTAssertEqual(item["power_value"]?.integerValue, 1)
        XCTAssertEqual(item["mac_mini_mode"]?.stringValue, "whenOnAC")
        XCTAssertEqual(item["automatic_restore_reason"]?.stringValue, "fanLeaseExpired")
    }

    func testHistoryEntriesGiveNumbersOnly() throws {
        let entry = ScanHistoryEntry(date: Date(timeIntervalSince1970: 1_790_000_000), scanSeconds: 12, score: 80, diskUsedBytes: 100, diskFreeBytes: 200,
                                     greenBytes: 1, yellowBytes: 2, redBytes: 3, itemCount: 6, greenCount: 1, yellowCount: 2, redCount: 3, deniedCount: 1)
        let scan = try checked(["kind": "scans", "items": [AgentReadModels.scanHistory(entry)], "next_cursor": nil], tool: "get_history")
        XCTAssertEqual(scan["items"]?[0]?["score"]?.integerValue, 80)
        XCTAssertEqual(scan["items"]?[0]?["green_bytes"]?.integerValue, 1)
        XCTAssertEqual(scan["items"]?[0]?["denied_count"]?.integerValue, 1)

        let point = CapacityHistoryPoint(recordedAt: Date(timeIntervalSince1970: 1_790_000_000), totalBytes: 100, availableBytes: 40,
                                         availableForImportantUsageBytes: 60, dayKey: "private-day-key", segmentID: 987_654)
        let capacity = try checked(["kind": "capacity", "items": [AgentReadModels.capacityHistory(point)], "next_cursor": nil], tool: "get_history",
                                   absent: ["private-day-key", "987654"])
        XCTAssertEqual(capacity["items"]?[0]?["available_bytes"]?.integerValue, 40)
        XCTAssertEqual(capacity["items"]?[0]?["available_for_important_usage_bytes"]?.integerValue, 60)
    }

    // MARK: Live status

    func testLiveStatusWithoutAReadingSaysSo() throws {
        let result = try checked(AgentReadModels.liveStatus(AgentLiveState()), tool: "get_live_status")
        XCTAssertEqual(result["data_time"], .null)
        XCTAssertEqual(result["cpu"], .null)
        XCTAssertEqual(result["fans"]?.arrayValue?.count, 0)
    }

    func testLiveStatusGivesNumbersAndNoProcesses() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let process = MemoryProcess(id: 77, name: "private-process-name", path: "\(Self.home)/private-process-path", iconPath: "",
                                    bundlePath: nil, residentBytes: 1, percent: 1, canQuit: true)
        let memory = MemorySnapshot(generatedAt: date, physicalBytes: 1_000, freeBytes: 100, inactiveBytes: 0, speculativeBytes: 0, fileBackedBytes: 100,
                                    purgeableBytes: 0, wiredBytes: 300, compressedBytes: 50, swapUsedBytes: 20, pressureFreePercentage: 61,
                                    pressureSummary: "private-pressure-summary", topProcesses: [process])
        let snapshot = SystemMonitorSnapshot(
            generatedAt: date,
            metrics: [SystemMonitorMetric(kind: .gpuUsage, value: "12%", detail: "", isAvailable: true),
                      SystemMonitorMetric(kind: .chipTemperature, value: "55°C", detail: "", isAvailable: true)],
            networkThroughput: NetworkMonitorThroughput(downBytesPerSecond: 11, upBytesPerSecond: 22),
            cpuUsageBreakdown: CPUUsageBreakdown(totalPercent: 33.33, userPercent: 22.22, systemPercent: 11.11),
            loadAverage: SystemLoadAverage(oneMinute: 1, fiveMinutes: 2, fifteenMinutes: 3),
            thermalState: .fair,
            fanReadings: [SystemFanReading(index: 0, actualRPM: 2_000, minimumRPM: 1_000, maximumRPM: 6_000, targetRPM: nil)],
            temperatureReadings: [SystemTemperatureReading(zone: .gpu, celsius: 51.26)],
            gpuMemoryUsedBytes: 64)
        var state = AgentLiveState()
        state.snapshot = snapshot
        state.memory = memory
        state.capacity = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 400)
        state.battery = AgentBatteryReading(chargePercent: 80, isCharging: true, powerSource: .acPower, minutesRemaining: nil, sampledAt: date)
        let result = try checked(AgentReadModels.liveStatus(state), tool: "get_live_status",
                                 absent: ["private-process", "private-pressure-summary", "77"])
        XCTAssertEqual(result["data_time"]?.stringValue, "2026-09-21T14:13:20Z")
        XCTAssertEqual(result["cpu"]?["total_percent"], .number(33.3))
        XCTAssertEqual(result["cpu"]?["load_average_1m"], .number(1))
        XCTAssertEqual(result["gpu"]?["usage_percent"], .number(12))
        XCTAssertEqual(result["gpu"]?["memory_used_bytes"]?.integerValue, 64)
        XCTAssertEqual(result["memory"]?["physical_bytes"]?.integerValue, 1_000)
        XCTAssertEqual(result["memory"]?["used_bytes"]?.integerValue, 800)
        XCTAssertEqual(result["memory"]?["pressure_free_percent"]?.integerValue, 61)
        XCTAssertEqual(result["disk"]?["available_bytes"]?.integerValue, 400)
        XCTAssertEqual(result["network"]?["download_bytes_per_second"]?.integerValue, 11)
        XCTAssertEqual(result["battery"]?["charge_percent"]?.integerValue, 80)
        XCTAssertEqual(result["battery"]?["power_source"]?.stringValue, "acPower")
        XCTAssertEqual(result["thermal"]?["state"]?.stringValue, "fair")
        XCTAssertEqual(result["thermal"]?["chip_celsius"], .number(55))
        XCTAssertEqual(result["thermal"]?["zones"]?[0]?["celsius"], .number(51.3))
        XCTAssertEqual(result["fans"]?[0]?["actual_rpm"]?.integerValue, 2_000)
    }

    func testAnUnmeasurableNumberIsNullNotAFailure() throws {
        // JSON has no NaN: a sensor's bad value must not cost the whole answer.
        var state = AgentLiveState()
        state.snapshot = SystemMonitorSnapshot(generatedAt: Date(), metrics: [], networkThroughput: nil,
                                               cpuUsageBreakdown: CPUUsageBreakdown(totalPercent: .nan, userPercent: .infinity, systemPercent: 1))
        let result = try checked(AgentReadModels.liveStatus(state), tool: "get_live_status")
        XCTAssertEqual(result["cpu"]?["total_percent"], .null)
        XCTAssertEqual(result["cpu"]?["user_percent"], .null)
        XCTAssertNoThrow(try JSONEncoder().encode(result))
    }

    // MARK: Health

    func testHealthGivesScoresAndIssuesButNoPrivateText() throws {
        let date = ComputerHealthSecurityFixture.date
        let snapshot = ComputerHealthSecurityFixture.snapshot(smart: .failing, backupStatus: .attention)
        let evaluation = ComputerHealthEvaluation(
            score: 72.4, status: .attention, coverage: 0.8, confidence: HealthConfidence(value: 90, level: .high, modelVersion: "private-model"),
            components: [HealthComponentEvaluation(factor: .capacity, availability: .available, score: 71.6, evidenceSummary: "private-evidence-summary",
                                                   evaluatedAt: date, modelVersion: "private-model")],
            evaluatedAt: date, modelVersion: "private-model")
        var state = AgentHealthState()
        state.evaluation = evaluation
        state.snapshot = snapshot
        let result = try checked(AgentReadModels.health(state), tool: "get_health",
                                 absent: ["private-volume-and-path", "private-backup-name", "private-evidence-summary", "private-model"])
        XCTAssertEqual(result["score"]?.integerValue, 72)
        XCTAssertEqual(result["status"]?.stringValue, "attention")
        XCTAssertEqual(result["factors"]?[0]?["factor"]?.stringValue, "capacity")
        XCTAssertEqual(result["factors"]?[0]?["score"]?.integerValue, 72)
        let issues = try XCTUnwrap(result["issues"]?.arrayValue)
        XCTAssertEqual(issues.compactMap { $0["factor"]?.stringValue }, ["disk", "backup"])
        XCTAssertEqual(issues.compactMap { $0["severity"]?.stringValue }, ["actionRequired", "attention"])
        XCTAssertEqual(result["disk"]?["smart_status"]?.stringValue, "failing")
        XCTAssertEqual(result["data_time"]?.stringValue, date.ISO8601Format())
    }

    func testHealthBeforeTheFirstCheckIsEmptyNotAnError() throws {
        let result = try checked(AgentReadModels.health(AgentHealthState()), tool: "get_health")
        XCTAssertEqual(result["issues"]?.arrayValue?.count, 0)
        XCTAssertEqual(result["score"], .null)
    }

    // MARK: Overview

    func testOverviewGivesTheAppWithoutItsPath() throws {
        var state = AgentOverviewState()
        state.isMenuBarOnly = true
        state.capacity = StorageCapacitySnapshot(totalBytes: 1_000, availableBytes: 400)
        let identity = AgentAppIdentity(name: "测试版", version: "2.0.2", build: "20261101", channel: "beta")
        let context = AgentCallContext(client: AgentClientIdentity(kind: .signed, identifier: "com.fixture", team: "T", cdhash: nil,
                                                                   executablePath: "~/private-client-path", displayName: "Fixture Client"),
                                       decision: .readOnly)
        let modules: [AgentJSONValue] = [["module": "junk", "status": "not_scanned"]]
        let result = try checked(AgentReadModels.overview(state, identity: identity, context: context, modules: modules, now: Date(timeIntervalSince1970: 1_790_000_000)),
                                 tool: "get_overview", absent: ["private-client-path", "/Applications"])
        XCTAssertEqual(result["app"]?["name"]?.stringValue, "测试版")
        XCTAssertEqual(result["app"]?["channel"]?.stringValue, "beta")
        XCTAssertEqual(result["app"]?["mode"]?.stringValue, "menu_bar_only")
        XCTAssertEqual(result["client"]?["name"]?.stringValue, "Fixture Client")
        XCTAssertEqual(result["client"]?["permission"]?.stringValue, "read_only")
        XCTAssertEqual(result["disk"]?["available_bytes"]?.integerValue, 400)
        XCTAssertEqual(result["modules"]?[0]?["status"]?.stringValue, "not_scanned")
    }

    func testTheMappersNeverEncodeAWholeModel() throws {
        // D266: whitelists only. Encoding a model would bring along every field
        // added to it later.
        let source = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Features/Agent/AgentReadModels.swift")
        for forbidden in ["JSONEncoder", "Mirror(", "CodingKey", "programArguments", "topProcesses", "recentChanges",
                          "restoreAuthorizations", "uninstallOwnership", "thinningSwaps", "recoveryAttempts", "diagnosticEvidence"] {
            XCTAssertFalse(source.contains(forbidden), "\(forbidden) in AgentReadModels.swift")
        }
    }
}
