import Foundation
import XCTest
@testable import StorageCleanerMac

final class MemorySelectionSummaryTests: XCTestCase {
    func testFixtureSelectionMenuUsesDraftPermissionWhileQuitKeepsDemoGuard() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let store = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Stores/ScanStore.swift"
        ), encoding: .utf8)
        let view = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekMemoryView.swift"
        ), encoding: .utf8)
        func section(_ source: String, from start: String, to end: String) throws -> String {
            let startRange = try XCTUnwrap(source.range(of: start))
            let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex))
            return String(source[startRange.upperBound..<endRange.lowerBound])
        }

        let draftPermission = try section(store, from: "var canEditMemorySelection: Bool {",
                                          to: "var canRequestMemoryQuitActions: Bool {")
        XCTAssertTrue(draftPermission.contains("!isLoadingMemory && !isOptimizingMemory"))
        XCTAssertFalse(draftPermission.contains("MiniWindowDemoData"))
        let quitPermission = try section(store, from: "var canRequestMemoryQuitActions: Bool {",
                                         to: "func canRequestMemoryQuit(")
        XCTAssertTrue(quitPermission.contains("#if DEBUG || STORAGE_CLEANER_BETA"))
        XCTAssertTrue(quitPermission.contains("guard !MiniWindowDemoData.isEnabled else { return false }"))
        XCTAssertTrue(quitPermission.contains("return canEditMemorySelection"))

        let menu = try section(view, from: "private struct GeekMemoryProcessSelectionMenu: View {",
                               to: "private struct GeekMemoryCleanupButton: View {")
        XCTAssertTrue(menu.contains("Menu {"))
        XCTAssertTrue(menu.contains("ForEach(selectableApps)"))
        XCTAssertTrue(menu.contains(".disabled(selectableApps.isEmpty || !store.canEditMemorySelection)"))
        XCTAssertTrue(menu.contains("store.setMemoryAppUsageSelection(app, isSelected: isSelected)"))
        XCTAssertFalse(menu.contains("canRequestMemoryQuitActions"))
        let cleanup = try section(view, from: "private struct GeekMemoryCleanupButton: View {",
                                  to: "private struct GeekMemoryQuitResultCard: View {")
        XCTAssertTrue(cleanup.contains(".disabled(!canPrepareSelection || !store.canRequestMemoryQuitActions)"))
        XCTAssertTrue(cleanup.contains(".disabled(!store.canRequestMemoryQuitActions)"))
        XCTAssertTrue(cleanup.contains("store.confirmQuitSelectedMemoryProcesses()"))

        let quitRequest = try section(store, from: "func requestQuitSelectedMemoryProcesses(",
                                      to: "func cancelQuitSelectedMemoryProcesses(")
        XCTAssertTrue(quitRequest.contains("guard canRequestMemoryQuitActions else { return }"))
        let batchConfirm = try section(store, from: "func confirmQuitSelectedMemoryProcesses()",
                                       to: "func cancelMemoryOptimization()")
        XCTAssertTrue(batchConfirm.contains("canRequestMemoryQuitActions else { return }"))
        XCTAssertTrue(batchConfirm.contains("let plan = pendingMemoryOptimizationPlan"))
        let singleConfirm = try section(store, from: "func confirmQuitProcess()",
                                        to: "func confirmQuitSelectedMemoryProcesses()")
        XCTAssertTrue(singleConfirm.contains("canRequestMemoryQuit(process) else { return }"))
    }

    #if DEBUG || STORAGE_CLEANER_BETA
    @MainActor
    func testFixtureSnapshotSelectionOnlyChangesDraftAndRespectsBusyState() throws {
        let store = ScanStore()
        let captured = MiniWindowDemoData.memorySnapshot
        store.memorySnapshot = captured
        let app = try XCTUnwrap(captured.appsByResidentUsage.first { !$0.selectableProcessIDs.isEmpty })

        XCTAssertTrue(store.canEditMemorySelection)
        store.setMemoryAppUsageSelection(app, isSelected: true)
        XCTAssertEqual(store.selectedMemoryProcessIDs, Set(app.selectableProcessIDs))
        store.toggleMemoryAppUsageSelection(app)
        XCTAssertTrue(store.selectedMemoryProcessIDs.isEmpty)
        store.selectAllMemoryProcessesForQuit()
        XCTAssertEqual(store.selectedMemoryProcessIDs, Set(captured.selectableQuitProcesses.map(\.id)))
        store.clearMemoryProcessSelection()
        XCTAssertTrue(store.selectedMemoryProcessIDs.isEmpty)
        if !captured.recommendedQuitProcessIDs.isEmpty {
            XCTAssertTrue(store.selectRecommendedMemoryApps())
            XCTAssertEqual(store.selectedMemoryProcessIDs, captured.recommendedQuitProcessIDs)
        }
        store.clearMemoryProcessSelection()

        for loading in [true, false] {
            store.isLoadingMemory = loading
            store.isOptimizingMemory = !loading
            XCTAssertFalse(store.canEditMemorySelection)
            store.setMemoryAppUsageSelection(app, isSelected: true)
            store.selectAllMemoryProcessesForQuit()
            XCTAssertFalse(store.selectRecommendedMemoryApps())
            XCTAssertTrue(store.selectedMemoryProcessIDs.isEmpty)
        }
        store.isOptimizingMemory = false
        XCTAssertNil(store.pendingMemoryProcess)
        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertTrue(store.pendingMemoryProcessesToQuit.isEmpty)
        XCTAssertFalse(store.isMemoryBatchQuitConfirmationPresentedInMenuBar)
        XCTAssertFalse(store.isOptimizingMemory)
    }
    #endif

    func testMemoryAppListUsesNativeScrollingWithoutFixedPageSize() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        ), encoding: .utf8)
        let panel = try XCTUnwrap(source.components(separatedBy: "struct MemoryProcessSelectionPanel: View {").last)
        XCTAssertTrue(panel.contains("ScrollView {"))
        XCTAssertTrue(panel.contains("LazyVStack(spacing: 0)"))
        XCTAssertTrue(panel.contains("ForEach(apps)"))
        XCTAssertTrue(panel.contains("ForEach(sampledProcesses)"))
        XCTAssertFalse(panel.contains("pageRange"))
    }

    func testSampledProcessListExplainsItsScopeAndRowsHaveNoQuitActions() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        ), encoding: .utf8)
        let panel = try XCTUnwrap(source.components(separatedBy: "struct MemoryProcessSelectionPanel: View {").last?
            .components(separatedBy: "private struct MemoryReadOnlyProcessRow").first)
        XCTAssertTrue(panel.contains("selection: $store.memoryShowsAllProcesses"))
        XCTAssertTrue(panel.contains("snapshot.processesByResidentUsage"))
        XCTAssertTrue(panel.contains("物理内存足迹大于 0"))
        XCTAssertTrue(panel.contains("最多 256 项；不代表全部系统 PID"))
        XCTAssertTrue(panel.contains("进程快照"))
        XCTAssertTrue(panel.contains("Text(snapshot.generatedAt, format: .dateTime.year().month().day().hour().minute().second())"))
        XCTAssertFalse(panel.contains("实时采样"))
        XCTAssertFalse(panel.contains("Timer"))
        XCTAssertTrue(panel.contains("MiniWindowDemoData.isEnabled { Text(\"FIXTURE ·\") }"))
        XCTAssertTrue(panel.contains("$0.canQuit && $0.bundlePath?.hasSuffix(\".app\") == true"))
        XCTAssertTrue(panel.contains(".disabled(!store.canRequestMemoryQuitActions)"))
        let row = try XCTUnwrap(source.components(separatedBy: "private struct MemoryReadOnlyProcessRow: View {").last?
            .components(separatedBy: "private struct MemoryAppSelectionTableHeader").first)
        XCTAssertTrue(row.contains("String(process.id)"))
        XCTAssertTrue(row.contains("process.availability == .available"))
        XCTAssertTrue(row.contains("ByteFormat.string(process.residentBytes)"))
        XCTAssertTrue(row.contains("process.capturedAt.formatted"))
        XCTAssertFalse(row.contains("Button("))
        XCTAssertFalse(row.contains("Toggle("))
        XCTAssertFalse(row.contains("ScanStore"))
    }

    @MainActor
    func testSampledListKeepsProtectedAndHelperPIDsWithoutExpandingQuitTargets() throws {
        let leader = process(id: 6_901, name: "Example", executable: "Example",
                             residentBytes: 400 * 1024 * 1024, canQuit: true)
        let helper = process(id: 6_902, name: "Example Helper", executable: "Helper",
                             residentBytes: 600 * 1024 * 1024, canQuit: false)
        let system = MemoryProcess(id: 6_903, name: "System", path: "/usr/libexec/example",
                                   iconPath: "/usr/libexec/example", bundlePath: nil,
                                   residentBytes: 800 * 1024 * 1024, percent: 1, canQuit: false)
        let captured = snapshot(processes: [leader, system, helper])
        let store = ScanStore()
        store.memorySnapshot = captured
        let panel = MemoryProcessSelectionPanel(snapshot: captured, store: store)

        XCTAssertTrue(store.memoryShowsAllProcesses)
        XCTAssertEqual(panel.sampledProcesses.map(\.id), [system.id, helper.id, leader.id])
        XCTAssertEqual(captured.appsByResidentUsage.count, 2)
        XCTAssertFalse(try XCTUnwrap(panel.sampledProcesses.first(where: { $0.id == system.id })).canQuit)
        let app = try XCTUnwrap(captured.appsByResidentUsage.first(where: { $0.canQuit }))
        store.memoryShowsAllProcesses = false
        store.setMemoryAppUsageSelection(app, isSelected: true)
        store.memoryShowsAllProcesses = true
        XCTAssertEqual(store.selectedMemoryProcessesForQuit.map(\.id), [leader.id])
        XCTAssertEqual(store.selectedMemoryAppCount, 1)
        XCTAssertNil(store.pendingMemoryQuitSummary)
    }

    @MainActor
    func testSampledListUsesTheSuppliedSnapshotWithoutMixingStoreProcesses() {
        let fixtureProcess = process(id: 6_911, name: "Fixture", executable: "Fixture",
                                     residentBytes: 40 * 1024 * 1024, canQuit: false)
        let otherProcess = process(id: 6_912, name: "Other", executable: "Other",
                                   residentBytes: 80 * 1024 * 1024, canQuit: true)
        let fixtureSnapshot = snapshot(processes: [fixtureProcess])
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [otherProcess])
        let panel = MemoryProcessSelectionPanel(snapshot: fixtureSnapshot, store: store)

        XCTAssertEqual(panel.sampledProcesses.map(\.id), [fixtureProcess.id])
        XCTAssertEqual(panel.snapshot.generatedAt, fixtureSnapshot.generatedAt)
        XCTAssertFalse(panel.sampledProcesses.contains(where: { $0.id == otherProcess.id }))
    }

    @MainActor
    func testSelectedEstimateIncludesHelpersButSafeTargetsUseOnlyRegularApplications() throws {
        let leader = process(
            id: 7_001,
            name: "Example",
            executable: "Example",
            residentBytes: 400 * 1024 * 1024,
            canQuit: true
        )
        let helper = process(
            id: 7_002,
            name: "Example Helper",
            executable: "Example Helper (Renderer)",
            residentBytes: 600 * 1024 * 1024,
            canQuit: false
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [helper, leader])

        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first)
        store.setMemoryAppUsageSelection(app, isSelected: true)

        XCTAssertEqual(store.selectedMemoryAppCount, 1)
        XCTAssertEqual(store.selectedMemoryAppEstimatedBytes, 1_000 * 1024 * 1024)
        XCTAssertEqual(store.selectedMemoryAppUsages.map(\.id), [app.id])
        XCTAssertEqual(store.selectedMemoryProcessesForQuit.map(\.id), [leader.id])
        XCTAssertFalse(store.selectedMemoryProcessesForQuit.contains(where: { $0.id == helper.id }))
    }

    @MainActor
    func testMultipleRegularInstancesRemainTargetsWhileApplicationSummaryIsDeduplicated() throws {
        let largerLeader = process(
            id: 7_011,
            name: "Example",
            executable: "Example",
            residentBytes: 500 * 1024 * 1024,
            canQuit: true
        )
        let secondRegularInstance = process(
            id: 7_012,
            name: "Example",
            executable: "Example",
            residentBytes: 300 * 1024 * 1024,
            canQuit: true
        )
        let helper = process(
            id: 7_013,
            name: "Example Helper",
            executable: "Example Helper (GPU)",
            residentBytes: 200 * 1024 * 1024,
            canQuit: false
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [secondRegularInstance, helper, largerLeader])

        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first)
        store.setMemoryAppUsageSelection(app, isSelected: true)

        XCTAssertEqual(store.selectedMemoryProcessIDs, [largerLeader.id, secondRegularInstance.id])
        XCTAssertEqual(
            Set(store.selectedMemoryProcessesForQuit.map(\.id)),
            [largerLeader.id, secondRegularInstance.id]
        )
        XCTAssertEqual(store.selectedMemoryAppCount, 1)
        XCTAssertEqual(store.selectedMemoryAppEstimatedBytes, 1_000 * 1024 * 1024)

        store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)

        XCTAssertEqual(store.pendingMemoryQuitSummary?.appCount, 1)
        XCTAssertEqual(Set(store.pendingMemoryProcessesToQuit.map(\.id)), [largerLeader.id, secondRegularInstance.id])
        XCTAssertFalse(store.pendingMemoryProcessesToQuit.contains(where: { $0.id == helper.id }))
    }

    @MainActor
    func testRecommendedSelectionUsesApplicationCountAndAggregateUsage() {
        let firstLeader = process(
            id: 7_021,
            name: "First",
            executable: "First",
            bundleName: "First",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let firstHelper = process(
            id: 7_022,
            name: "First Helper",
            executable: "First Helper (Renderer)",
            bundleName: "First",
            residentBytes: 600 * 1024 * 1024,
            canQuit: false
        )
        let secondLeader = process(
            id: 7_023,
            name: "Second",
            executable: "Second",
            bundleName: "Second",
            residentBytes: 800 * 1024 * 1024,
            canQuit: true
        )
        let secondHelper = process(
            id: 7_024,
            name: "Second Helper",
            executable: "Second Helper (GPU)",
            bundleName: "Second",
            residentBytes: 500 * 1024 * 1024,
            canQuit: false
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(
            processes: [firstHelper, secondLeader, firstLeader, secondHelper],
            freeBytes: 300 * 1024 * 1024,
            compressedBytes: 4 * 1024 * 1024 * 1024,
            swapUsedBytes: 512 * 1024 * 1024,
            pressureFreePercentage: 5
        )

        XCTAssertTrue(store.selectRecommendedMemoryApps())
        XCTAssertEqual(store.selectedMemoryAppCount, 2)
        XCTAssertEqual(store.selectedMemoryAppEstimatedBytes, 2_600 * 1024 * 1024)
        XCTAssertEqual(Set(store.selectedMemoryProcessesForQuit.map(\.id)), [firstLeader.id, secondLeader.id])
    }

    @MainActor
    func testRecommendedActionSelectsFirstAndExecutesOnlyOnSecondClick() {
        let suggested = process(
            id: 7_027,
            name: "Suggested",
            executable: "Suggested",
            bundleName: "Suggested",
            residentBytes: 900 * 1024 * 1024,
            canQuit: true
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(
            processes: [suggested],
            freeBytes: 300 * 1024 * 1024,
            compressedBytes: 4 * 1024 * 1024 * 1024,
            swapUsedBytes: 512 * 1024 * 1024,
            pressureFreePercentage: 5
        )

        store.performRecommendedMemoryAction()

        XCTAssertTrue(store.isRecommendedMemorySelectionPrepared)
        XCTAssertEqual(store.selectedMemoryProcessesForQuit.map(\.id), [suggested.id])
        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertFalse(store.isOptimizingMemory)

        store.performRecommendedMemoryAction()

        XCTAssertTrue(store.isOptimizingMemory)
        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertTrue(store.pendingMemoryProcessesToQuit.isEmpty)
        store.cancelMemoryOptimization()
    }

    @MainActor
    func testPreparingQuitKeepsManualSelectionInsteadOfReplacingItWithSuggestions() throws {
        let manual = process(
            id: 7_025,
            name: "Manual",
            executable: "Manual",
            bundleName: "Manual",
            residentBytes: 200 * 1024 * 1024,
            canQuit: true
        )
        let suggested = process(
            id: 7_026,
            name: "Suggested",
            executable: "Suggested",
            bundleName: "Suggested",
            residentBytes: 900 * 1024 * 1024,
            canQuit: true
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(
            processes: [suggested, manual],
            freeBytes: 300 * 1024 * 1024,
            compressedBytes: 4 * 1024 * 1024 * 1024,
            swapUsedBytes: 512 * 1024 * 1024,
            pressureFreePercentage: 5
        )

        let manualApp = try XCTUnwrap(
            store.memorySnapshot?.appsByResidentUsage.first { $0.name == "Manual" }
        )
        store.setMemoryAppUsageSelection(manualApp, isSelected: true)

        XCTAssertTrue(store.ensureMemorySelectionForQuit())
        XCTAssertEqual(store.selectedMemoryAppUsages.map(\.name), ["Manual"])
        XCTAssertEqual(store.selectedMemoryProcessesForQuit.map(\.id), [manual.id])
    }

    @MainActor
    func testRequestFreezesSummaryUntilCancellation() throws {
        let leader = process(
            id: 7_031,
            name: "Example",
            executable: "Example",
            residentBytes: 400 * 1024 * 1024,
            canQuit: true
        )
        let helper = process(
            id: 7_032,
            name: "Example Helper",
            executable: "Example Helper (Renderer)",
            residentBytes: 600 * 1024 * 1024,
            canQuit: false
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [leader, helper])
        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first)
        store.setMemoryAppUsageSelection(app, isSelected: true)

        store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)

        XCTAssertEqual(
            store.pendingMemoryQuitSummary,
            MemoryQuitSelectionSummary(appCount: 1, estimatedBytes: 1_000 * 1024 * 1024)
        )
        XCTAssertEqual(store.pendingMemoryProcessesToQuit.map(\.id), [leader.id])
        XCTAssertTrue(store.isMemoryBatchQuitConfirmationPresentedInMenuBar)

        store.memorySnapshot = snapshot(processes: [
            process(
                id: leader.id,
                name: "Example",
                executable: "Example",
                residentBytes: 20 * 1024 * 1024,
                canQuit: true
            )
        ])

        XCTAssertEqual(store.pendingMemoryQuitSummary?.estimatedBytes, 1_000 * 1024 * 1024)

        store.cancelQuitSelectedMemoryProcesses()

        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertTrue(store.pendingMemoryProcessesToQuit.isEmpty)
        XCTAssertFalse(store.isMemoryBatchQuitConfirmationPresentedInMenuBar)
    }

    @MainActor
    func testRefreshClearsFrozenSummaryTargetsSelectionAndMenuFlag() throws {
        let leader = process(
            id: 7_041,
            name: "Example",
            executable: "Example",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [leader])
        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first)
        store.setMemoryAppUsageSelection(app, isSelected: true)
        store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)

        store.refreshMemory(priority: .background)

        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertTrue(store.pendingMemoryProcessesToQuit.isEmpty)
        XCTAssertTrue(store.selectedMemoryProcessIDs.isEmpty)
        XCTAssertFalse(store.isMemoryBatchQuitConfirmationPresentedInMenuBar)
    }

    @MainActor
    func testRequestFreezesOnlyRegularApplicationInstancesIntoAPlan() throws {
        let leader = process(
            id: 7_051,
            name: "Example",
            executable: "Example",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let secondRegularInstance = process(
            id: 7_052,
            name: "Example",
            executable: "Example",
            residentBytes: 300 * 1024 * 1024,
            canQuit: true
        )
        let helper = process(
            id: 7_053,
            name: "Example Helper",
            executable: "Example Helper (Renderer)",
            residentBytes: 500 * 1024 * 1024,
            canQuit: false
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [helper, secondRegularInstance, leader])
        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first)
        store.setMemoryAppUsageSelection(app, isSelected: true)
        store.requestQuitSelectedMemoryProcesses(presentConfirmationInMenuBar: true)

        let plan = try XCTUnwrap(store.pendingMemoryOptimizationPlan)
        XCTAssertEqual(
            Set(plan.targets.map { $0.identity.processIdentifier }),
            [leader.id, secondRegularInstance.id]
        )
        XCTAssertFalse(plan.targets.contains { $0.identity.processIdentifier == helper.id })
        XCTAssertEqual(plan.confirmation, .pending)
        XCTAssertEqual(plan.action, .gracefulQuit)
        XCTAssertFalse(plan.riskNotice.isEmpty)
    }

    @MainActor
    func testCancellingBatchInvalidatesThePendingPlan() throws {
        let firstInstance = process(
            id: 7_055,
            name: "Example",
            executable: "Example",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let secondInstance = process(
            id: 7_056,
            name: "Example",
            executable: "Example",
            residentBytes: 300 * 1024 * 1024,
            canQuit: true
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [firstInstance, secondInstance])
        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first)
        store.setMemoryAppUsageSelection(app, isSelected: true)
        store.requestQuitSelectedMemoryProcesses()

        XCTAssertNotNil(store.pendingMemoryOptimizationPlan)
        store.cancelQuitSelectedMemoryProcesses()

        XCTAssertNil(store.pendingMemoryQuitSummary)
        XCTAssertNil(store.pendingMemoryOptimizationPlan)
        XCTAssertTrue(store.pendingMemoryProcessesToQuit.isEmpty)
        XCTAssertFalse(store.isMemoryBatchQuitConfirmationPresentedInMenuBar)
    }

    @MainActor
    func testPlanKeepsEachProcessIdentityForPIDReuseProtection() throws {
        let successfulInstance = process(
            id: 7_057,
            name: "Example",
            executable: "Example",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let failedInstance = process(
            id: 7_058,
            name: "Example",
            executable: "Example",
            residentBytes: 300 * 1024 * 1024,
            canQuit: true
        )
        let store = ScanStore()
        store.memorySnapshot = snapshot(processes: [successfulInstance, failedInstance])
        let app = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.first)
        store.setMemoryAppUsageSelection(app, isSelected: true)
        store.requestQuitSelectedMemoryProcesses()

        let plan = try XCTUnwrap(store.pendingMemoryOptimizationPlan)
        XCTAssertEqual(plan.targets.map(\.identity), [
            successfulInstance.identity,
            failedInstance.identity,
        ])
        XCTAssertEqual(plan.preflight.count, 2)
    }

    func testMatchingRegularIdentityIsAccepted() throws {
        let target = process(
            id: 7_061,
            name: "Example",
            executable: "Example",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let identity = MemoryRunningApplicationIdentity(
            processIdentifier: target.id,
            bundlePath: target.bundlePath,
            executablePath: target.path,
            activationPolicy: .regular
        )

        XCTAssertNoThrow(
            try MemoryOptimizerService.validateQuitTarget(
                target,
                against: identity,
                currentProcessIdentifier: 1
            )
        )
    }

    func testPIDReuseWithDifferentBundleOrExecutableIsRejected() {
        let target = process(
            id: 7_071,
            name: "Example",
            executable: "Example",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let reusedIdentity = MemoryRunningApplicationIdentity(
            processIdentifier: target.id,
            bundlePath: "/Applications/Other.app",
            executablePath: "/Applications/Other.app/Contents/MacOS/Other",
            activationPolicy: .regular
        )

        XCTAssertThrowsError(
            try MemoryOptimizerService.validateQuitTarget(
                target,
                against: reusedIdentity,
                currentProcessIdentifier: 1
            )
        ) { error in
            guard case MemoryOptimizerError.processIdentityChanged = error else {
                return XCTFail("Expected processIdentityChanged, got \(error)")
            }
        }

        let replacedExecutable = MemoryRunningApplicationIdentity(
            processIdentifier: target.id,
            bundlePath: target.bundlePath,
            executablePath: "/Applications/Example.app/Contents/MacOS/Unexpected",
            activationPolicy: .regular
        )
        XCTAssertThrowsError(
            try MemoryOptimizerService.validateQuitTarget(
                target,
                against: replacedExecutable,
                currentProcessIdentifier: 1
            )
        )
    }

    func testSymlinkEquivalentBundleAndExecutablePathsAreAccepted() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("StorageCleanerMemoryIdentity-\(UUID().uuidString)", isDirectory: true)
        let realBundleURL = root
            .appendingPathComponent("Real", isDirectory: true)
            .appendingPathComponent("Example.app", isDirectory: true)
        let realExecutableURL = realBundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("Example")
        let linkedBundleURL = root.appendingPathComponent("Example.app", isDirectory: true)
        let linkedExecutableURL = linkedBundleURL.appendingPathComponent("Contents/MacOS/Example")

        try fileManager.createDirectory(
            at: realExecutableURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(fileManager.createFile(atPath: realExecutableURL.path, contents: Data()))
        try fileManager.createSymbolicLink(at: linkedBundleURL, withDestinationURL: realBundleURL)
        defer { try? fileManager.removeItem(at: root) }

        let target = MemoryProcess(
            id: 7_075,
            name: "Example",
            path: linkedExecutableURL.path,
            iconPath: linkedBundleURL.path,
            bundlePath: linkedBundleURL.path,
            residentBytes: 700 * 1024 * 1024,
            percent: 1,
            canQuit: true
        )
        let identity = MemoryRunningApplicationIdentity(
            processIdentifier: target.id,
            bundlePath: realBundleURL.path,
            executablePath: realExecutableURL.path,
            activationPolicy: .regular
        )

        XCTAssertNoThrow(
            try MemoryOptimizerService.validateQuitTarget(
                target,
                against: identity,
                currentProcessIdentifier: 1
            )
        )
    }

    func testNonRegularOrSelfApplicationIsRejected() {
        let target = process(
            id: 7_081,
            name: "Example",
            executable: "Example",
            residentBytes: 700 * 1024 * 1024,
            canQuit: true
        )
        let accessoryIdentity = MemoryRunningApplicationIdentity(
            processIdentifier: target.id,
            bundlePath: target.bundlePath,
            executablePath: target.path,
            activationPolicy: .accessory
        )

        XCTAssertThrowsError(
            try MemoryOptimizerService.validateQuitTarget(
                target,
                against: accessoryIdentity,
                currentProcessIdentifier: 1
            )
        )
        XCTAssertThrowsError(
            try MemoryOptimizerService.validateQuitTarget(
                target,
                against: MemoryRunningApplicationIdentity(
                    processIdentifier: target.id,
                    bundlePath: target.bundlePath,
                    executablePath: target.path,
                    activationPolicy: .regular
                ),
                currentProcessIdentifier: target.id
            )
        )
    }

    private func process(
        id: Int32,
        name: String,
        executable: String,
        bundleName: String = "Example",
        residentBytes: Int64,
        canQuit: Bool
    ) -> MemoryProcess {
        let bundlePath = "/Applications/\(bundleName).app"
        return MemoryProcess(
            id: id,
            name: name,
            path: "\(bundlePath)/Contents/MacOS/\(executable)",
            iconPath: bundlePath,
            bundlePath: bundlePath,
            residentBytes: residentBytes,
            percent: 1,
            canQuit: canQuit
        )
    }

    private func snapshot(
        processes: [MemoryProcess],
        freeBytes: Int64 = 4 * 1024 * 1024 * 1024,
        compressedBytes: Int64 = 0,
        swapUsedBytes: Int64 = 0,
        pressureFreePercentage: Int? = 80
    ) -> MemorySnapshot {
        MemorySnapshot(
            generatedAt: Date(),
            physicalBytes: 16 * 1024 * 1024 * 1024,
            freeBytes: freeBytes,
            inactiveBytes: 0,
            speculativeBytes: 0,
            fileBackedBytes: 512 * 1024 * 1024,
            purgeableBytes: 0,
            wiredBytes: 2 * 1024 * 1024 * 1024,
            compressedBytes: compressedBytes,
            swapUsedBytes: swapUsedBytes,
            pressureFreePercentage: pressureFreePercentage,
            pressureSummary: "test",
            topProcesses: processes
        )
    }
}
