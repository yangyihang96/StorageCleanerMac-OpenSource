import Foundation
import XCTest
@testable import StorageCleanerMac

/// D101 G2: simulator items are listed from simctl's JSON and deleted only
/// through simctl, one identifier per command. Every test uses fixtures and
/// a fake runner; nothing here runs the real simctl.
final class SimulatorCleanupTests: XCTestCase {
    // Shapes from `xcrun simctl list -j devices` and `xcrun simctl runtime list -j`
    // (Xcode 27 beta); paths and identifiers are made up.
    private static let iOS27 = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
    private static let iOS18 = "com.apple.CoreSimulator.SimRuntime.iOS-18-0"
    private static let iOS17 = "com.apple.CoreSimulator.SimRuntime.iOS-17-5"
    private static let watchOS11 = "com.apple.CoreSimulator.SimRuntime.watchOS-11-0"
    private static let tvOS18 = "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"
    private static let visionOS2 = "com.apple.CoreSimulator.SimRuntime.xrOS-2-0"

    private static let availablePhone = "2CFABC53-E865-45D4-9877-0DA864EE0F4F"
    private static let unavailablePhone = "6A9E2B1C-0D3F-4E5A-8B7C-9D0E1F2A3B4C"
    private static let unavailableWatch = "0B1C2D3E-4F50-4617-8293-A4B5C6D7E8F9"
    private static let noFlagPad = "11111111-2222-4333-8444-555555555555"

    private static let runtime27 = "B1941F9A-0C12-46D8-9048-0523F43FBC3F"
    private static let runtime18 = "C2A52E0B-1D23-47E9-A159-1634054CCD40"
    private static let runtimeWatch = "D3B63F1C-2E34-48FA-B26A-2745165DDE51"
    private static let runtime17 = "E4C7402D-3F45-490B-837B-3856276EEF62"
    private static let runtimeTV = "F5D8513E-4056-4A1C-948C-4967387FF073"
    private static let runtimeDeleting = "06E9624F-5167-4B2D-A59D-5A78498001A4"
    private static let runtimeMismatched = "17FA7350-6278-4C3E-B6AE-6B8959A112B5"
    private static let runtimeVision = "280B8461-7389-4D4F-87BF-7C9A6AB223C6"

    private static func device(_ udid: String, _ name: String, available: Bool?, error: String? = nil,
                               data: Int64? = nil, log: Int64? = nil) -> [String: Any] {
        var device: [String: Any] = [
            "udid": udid, "name": name, "state": "Shutdown",
            "dataPath": "/Users/fixture/Library/Developer/CoreSimulator/Devices/\(udid)/data",
            "logPath": "/Users/fixture/Library/Logs/CoreSimulator/\(udid)",
            "deviceTypeIdentifier": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
        ]
        if let available { device["isAvailable"] = available }
        if let error { device["availabilityError"] = error }
        if let data { device["dataPathSize"] = data }
        if let log { device["logPathSize"] = log }
        return device
    }

    private static func runtime(_ key: String, _ runtimeIdentifier: String, version: String, build: String,
                                deletable: Bool = true, state: String = "Ready", size: Int64 = 7_000_000_000,
                                identifier: String? = nil) -> [String: Any] {
        [
            "identifier": identifier ?? key, "runtimeIdentifier": runtimeIdentifier, "version": version,
            "build": build, "deletable": deletable, "state": state, "sizeBytes": size,
            "kind": "Patchable Cryptex Disk Image", "platformIdentifier": "com.apple.platform.iphonesimulator",
            "path": "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/fixture.asset/AssetData",
        ]
    }

    private static var fixtureDevices: [String: [[String: Any]]] {
        [
            iOS27: [device(availablePhone, "iPhone 18 Pro", available: true, data: 18_337_792)],
            iOS17: [device(unavailablePhone, "iPhone 15 Pro", available: false,
                           error: "runtime profile not found using \"System\" match policy",
                           data: 1_048_576_000, log: 4_096)],
            // Unavailable, yet it still names a runtime that exists.
            watchOS11: [device(unavailableWatch, "Apple Watch Series 10", available: false,
                               error: "device type profile not found")],
            // No availability flag: never offered, still keeps its runtime.
            tvOS18: [device(noFlagPad, "Apple TV", available: nil)],
        ]
    }

    private static var fixtureRuntimes: [String: [String: Any]] {
        [
            runtime27: runtime(runtime27, iOS27, version: "27.0", build: "24A434", size: 8_067_000_161),
            runtime18: runtime(runtime18, iOS18, version: "18.0", build: "22A3351", size: 7_500_000_000),
            runtimeWatch: runtime(runtimeWatch, watchOS11, version: "11.0", build: "22R349"),
            runtimeTV: runtime(runtimeTV, tvOS18, version: "18.0", build: "22J356"),
            runtime17: runtime(runtime17, "com.apple.CoreSimulator.SimRuntime.iOS-17-0", version: "17.0",
                               build: "21A328", deletable: false),
            runtimeDeleting: runtime(runtimeDeleting, "com.apple.CoreSimulator.SimRuntime.iOS-16-4",
                                     version: "16.4", build: "20E247", state: "Deleting"),
            runtimeMismatched: runtime(runtimeMismatched, "com.apple.CoreSimulator.SimRuntime.iOS-16-0",
                                       version: "16.0", build: "20A360", identifier: runtime18),
            runtimeVision: runtime(runtimeVision, visionOS2, version: "2.0", build: "22N320"),
        ]
    }

    private static func json(_ object: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Parsing

    func testParsesTheSimctlListings() throws {
        let devices = try SimulatorInventoryParser.devices(from: Self.json(["devices": Self.fixtureDevices]))
        XCTAssertEqual(devices.count, 4)
        let phone = try XCTUnwrap(devices.first { $0.udid == Self.unavailablePhone })
        XCTAssertEqual(phone.name, "iPhone 15 Pro")
        XCTAssertEqual(phone.runtimeIdentifier, Self.iOS17)
        XCTAssertFalse(phone.isAvailable)
        XCTAssertEqual(phone.availabilityError, "runtime profile not found using \"System\" match policy")
        XCTAssertEqual(phone.bytes, 1_048_576_000 + 4_096, "Data and log folders")
        XCTAssertNil(try XCTUnwrap(devices.first { $0.udid == Self.unavailableWatch }).bytes, "Size not reported")
        XCTAssertTrue(try XCTUnwrap(devices.first { $0.udid == Self.noFlagPad }).isAvailable,
                      "No flag reads as available")

        let runtimes = try SimulatorInventoryParser.runtimes(from: Self.json(Self.fixtureRuntimes))
        XCTAssertEqual(runtimes.count, 8)
        let ios27 = try XCTUnwrap(runtimes.first { $0.identifier == Self.runtime27 })
        XCTAssertEqual(ios27.runtimeIdentifier, Self.iOS27)
        XCTAssertEqual(ios27.build, "24A434")
        XCTAssertEqual(ios27.bytes, 8_067_000_161)
        XCTAssertTrue(ios27.isDeletable)
        // A key that does not match its identifier is kept, never deletable.
        let mismatched = try XCTUnwrap(runtimes.first { $0.identifier == Self.runtimeMismatched })
        XCTAssertFalse(mismatched.isDeletable)

        XCTAssertThrowsError(try SimulatorInventoryParser.devices(from: Data("not json".utf8)))
        XCTAssertThrowsError(try SimulatorInventoryParser.runtimes(from: Data("[]".utf8)))
        XCTAssertEqual(SimulatorCleanupItem.runtimeName(Self.iOS27, version: "27.0"), "iOS 27.0")
        XCTAssertEqual(SimulatorCleanupItem.runtimeName(Self.visionOS2, version: "2.0"), "xrOS 2.0")
        XCTAssertEqual(SimulatorCleanupItem.runtimeName("custom", version: "1.0"), "1.0")
    }

    // MARK: What is listed

    func testListsOnlyUnavailableDevicesAndRuntimesNoDeviceUses() throws {
        let items = SimulatorCleanupPolicy.items(in: try Self.inventory(otherSets: [Self.visionOS2]))
        XCTAssertEqual(items.map(\.kind), [.unavailableDevice, .unavailableDevice, .unusedRuntime])
        XCTAssertEqual(items.map(\.identifier), [Self.unavailableWatch, Self.unavailablePhone, Self.runtime18])
        let runtime = try XCTUnwrap(items.last)
        XCTAssertEqual(runtime.name, "iOS 18.0")
        XCTAssertEqual(runtime.build, "22A3351")
        XCTAssertEqual(runtime.bytes, 7_500_000_000)
        // One identifier per command; never `all` or `unavailable`.
        XCTAssertEqual(items[1].deletionArguments, ["delete", Self.unavailablePhone])
        XCTAssertEqual(runtime.deletionArguments, ["runtime", "delete", Self.runtime18])
        XCTAssertTrue(items.allSatisfy { UUID(uuidString: $0.deletionArguments.last!) != nil })
    }

    /// A runtime any device names is never listed: an available device, an
    /// unavailable one, a device without the flag, or a device in Xcode's
    /// preview or test sets. When those sets cannot be read, or simctl
    /// cannot list runtimes, no runtime is listed at all.
    func testARuntimeInUseIsNeverListed() throws {
        let inventory = try Self.inventory(otherSets: [Self.visionOS2])
        // Device items carry their device's runtime; only runtime items count.
        let listed = Set(SimulatorCleanupPolicy.items(in: inventory).filter { $0.kind == .unusedRuntime }
            .map(\.runtimeIdentifier))
        for used in [Self.iOS27, Self.watchOS11, Self.tvOS18, Self.visionOS2] {
            XCTAssertFalse(listed.contains(used), used)
        }
        // Each deletable runtime, used by one more device, drops out.
        for runtime in try XCTUnwrap(inventory.runtimes) where runtime.isDeletable {
            var used = inventory
            used.devices.append(SimulatorDevice(udid: UUID().uuidString, name: "Fixture", runtimeIdentifier:
                runtime.runtimeIdentifier, isAvailable: false, availabilityError: nil, bytes: nil))
            XCTAssertFalse(SimulatorCleanupPolicy.items(in: used).contains { $0.identifier == runtime.identifier },
                           runtime.runtimeIdentifier)
            var previews = inventory
            previews.otherDeviceSetRuntimes = [runtime.runtimeIdentifier]
            XCTAssertFalse(SimulatorCleanupPolicy.items(in: previews).contains { $0.identifier == runtime.identifier },
                           runtime.runtimeIdentifier)
        }
        var unreadableSets = inventory
        unreadableSets.otherDeviceSetRuntimes = nil
        XCTAssertEqual(SimulatorCleanupPolicy.items(in: unreadableSets).map(\.kind), [.unavailableDevice, .unavailableDevice])
        var noRuntimeList = inventory
        noRuntimeList.runtimes = nil
        XCTAssertEqual(SimulatorCleanupPolicy.items(in: noRuntimeList).map(\.kind), [.unavailableDevice, .unavailableDevice])
        // Not deletable, being deleted, or listed under another key: never offered.
        for identifier in [Self.runtime17, Self.runtimeDeleting, Self.runtimeMismatched] {
            XCTAssertFalse(SimulatorCleanupPolicy.items(in: inventory).contains { $0.identifier == identifier }, identifier)
        }
    }

    /// simctl reads `all`, `unavailable` and `booted` as many devices.
    func testOnlyASingleItemIdentifierCanReachSimctl() {
        for word in ["all", "unavailable", "booted", "", "-h", "2CFABC53"] {
            XCTAssertFalse(SimulatorCleanupPolicy.isSingleItemIdentifier(word), word)
            let inventory = SimulatorInventory(
                devices: [SimulatorDevice(udid: word, name: word, runtimeIdentifier: Self.iOS17, isAvailable: false,
                                          availabilityError: nil, bytes: nil)],
                runtimes: [SimulatorRuntime(identifier: word, runtimeIdentifier: Self.iOS18, version: "18.0",
                                            build: "22A3351", state: "Ready", isDeletable: true, bytes: nil)],
                otherDeviceSetRuntimes: [])
            XCTAssertTrue(SimulatorCleanupPolicy.items(in: inventory).isEmpty, word)
        }
    }

    // MARK: Other device sets and the tools

    func testOtherDeviceSetsAreReadFromTheirDeviceFiles() throws {
        let root = try makeRoot()
        let reader = FoundationSimulatorDeviceSetReader()
        XCTAssertEqual(reader.runtimeIdentifiers(inSetAt: root.appendingPathComponent("Missing")), [])
        let set = root.appendingPathComponent("Previews", isDirectory: true)
        try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        XCTAssertEqual(reader.runtimeIdentifiers(inSetAt: set), [])
        try writeDevice(in: set, udid: UUID().uuidString, runtime: Self.visionOS2)
        try writeDevice(in: set, udid: UUID().uuidString, runtime: Self.iOS18)
        try Data("not a device".utf8).write(to: set.appendingPathComponent("device_set.plist"))
        XCTAssertEqual(reader.runtimeIdentifiers(inSetAt: set), [Self.visionOS2, Self.iOS18])
        // A device folder that cannot be read: no runtime may count as unused.
        try FileManager.default.createDirectory(at: set.appendingPathComponent(UUID().uuidString),
                                                withIntermediateDirectories: true)
        XCTAssertNil(reader.runtimeIdentifiers(inSetAt: set))
        let file = root.appendingPathComponent("NotASet")
        try Data().write(to: file)
        XCTAssertNil(reader.runtimeIdentifiers(inSetAt: file))
        // B-R1: a path under a file cannot exist (ENOTDIR), so there is no set.
        XCTAssertEqual(reader.runtimeIdentifiers(inSetAt: file.appendingPathComponent("Previews")), [])
    }

    func testTheToolsAreFoundFromFilesAndCommandLineToolsAloneDoNotCount() throws {
        let root = try makeRoot()
        let xcode = root.appendingPathComponent("Xcode-Fixture.app/Contents/Developer", isDirectory: true)
        let simctl = xcode.appendingPathComponent("usr/bin/simctl")
        try FileManager.default.createDirectory(at: simctl.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: simctl)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: simctl.path)
        let commandLineTools = root.appendingPathComponent("CommandLineTools", isDirectory: true)
        try FileManager.default.createDirectory(at: commandLineTools.appendingPathComponent("usr/bin"),
                                                withIntermediateDirectories: true)
        let link = root.appendingPathComponent("xcode_select_link")
        let missingLink = root.appendingPathComponent("missing_link").path

        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: xcode.path)
        XCTAssertEqual(SimulatorToolLocator.developerDirectory(environment: [:], selectionLink: link.path)?.path,
                       xcode.path)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: commandLineTools.path)
        XCTAssertNil(SimulatorToolLocator.developerDirectory(environment: [:], selectionLink: link.path))
        // DEVELOPER_DIR wins, and may name the app itself.
        XCTAssertEqual(SimulatorToolLocator.developerDirectory(
            environment: ["DEVELOPER_DIR": xcode.deletingLastPathComponent().deletingLastPathComponent().path],
            selectionLink: missingLink)?.standardizedFileURL.path, xcode.standardizedFileURL.path)
        XCTAssertNil(SimulatorToolLocator.developerDirectory(
            environment: ["DEVELOPER_DIR": commandLineTools.path], selectionLink: link.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: simctl.path)
        XCTAssertNil(SimulatorToolLocator.developerDirectory(environment: ["DEVELOPER_DIR": xcode.path],
                                                             selectionLink: missingLink), "Not executable")
    }

    // MARK: Deleting

    func testDeletesOnlyTheFrozenItemsStillListedOneCommandEach() async throws {
        let fake = FakeSimctl(devices: Self.fixtureDevices, runtimes: Self.fixtureRuntimes)
        let service = Self.service(fake)
        let items = try await service.items()
        XCTAssertEqual(items.map(\.identifier), [Self.unavailableWatch, Self.unavailablePhone, Self.runtime18])
        // Frozen: one device, the runtime, and a device no longer listed.
        let gone = SimulatorCleanupItem(kind: .unavailableDevice, identifier: UUID().uuidString, name: "Gone",
                                        runtimeIdentifier: Self.iOS17, build: nil, bytes: 1, availabilityError: nil)
        await fake.resetCalls()
        let result = await service.delete([items[1], items[2], gone])

        let calls = await fake.calls
        XCTAssertEqual(calls.filter { $0.contains("delete") }, [
            ["delete", Self.unavailablePhone], ["runtime", "delete", Self.runtime18],
        ])
        XCTAssertFalse(calls.contains { $0.contains("all") || $0.contains("unavailable") })
        // Listed again before deleting, and read back afterwards.
        XCTAssertEqual(calls.first, ["list", "-j", "devices"])
        XCTAssertEqual(calls.last, ["runtime", "list", "-j"])
        XCTAssertEqual(result.entries.first { $0.item == items[1] }?.outcome, .deleted)
        XCTAssertEqual(result.entries.first { $0.item == items[2] }?.outcome, .deleted)
        XCTAssertEqual(result.entries.first { $0.item == gone }?.outcome, .skipped(.changed))
        XCTAssertEqual(result.deletedCount, 2)
        XCTAssertEqual(result.deletedBytes, 1_048_576_000 + 4_096 + 7_500_000_000)
        XCTAssertEqual(result.skippedCount, 1)
        // The device the user did not freeze is still there.
        let remaining = try await service.items()
        XCTAssertEqual(remaining.map(\.identifier), [Self.unavailableWatch])
    }

    func testNothingIsDeletedWhileXcodeOrSimulatorRuns() async throws {
        for owner in SimulatorCleanupService.ownerBundleIdentifiers {
            let fake = FakeSimctl(devices: Self.fixtureDevices, runtimes: Self.fixtureRuntimes)
            let items = try await Self.service(fake).items()
            await fake.setRunning([owner])
            let result = await Self.service(fake).delete(items)
            XCTAssertEqual(result.entries.map(\.outcome), Array(repeating: .skipped(.ownerRunning), count: 3), owner)
            let deletions = await fake.calls.filter { $0.contains("delete") }
            XCTAssertTrue(deletions.isEmpty, owner)
        }
        // Started after the first deletion: the rest are kept.
        let fake = FakeSimctl(devices: Self.fixtureDevices, runtimes: Self.fixtureRuntimes)
        let items = try await Self.service(fake).items()
        await fake.launchXcodeAfterFirstDeletion()
        let result = await Self.service(fake).delete(items)
        XCTAssertEqual(result.deletedCount, 1)
        XCTAssertEqual(result.count(.skipped(.ownerRunning)), 2)
        let deletions = await fake.calls.filter { $0.contains("delete") }
        XCTAssertEqual(deletions.count, 1)
    }

    func testChangesAfterConfirmationKeepTheItem() async throws {
        let fake = FakeSimctl(devices: Self.fixtureDevices, runtimes: Self.fixtureRuntimes)
        let service = Self.service(fake)
        let items = try await service.items()
        // A device now uses the runtime, and the phone became available again.
        await fake.addDevice(runtime: Self.iOS18, udid: UUID().uuidString, available: true)
        await fake.setAvailable(Self.unavailablePhone, true)
        let result = await service.delete(items)
        XCTAssertEqual(result.entries.first { $0.item.identifier == Self.runtime18 }?.outcome, .skipped(.changed))
        XCTAssertEqual(result.entries.first { $0.item.identifier == Self.unavailablePhone }?.outcome, .skipped(.changed))
        XCTAssertEqual(result.entries.first { $0.item.identifier == Self.unavailableWatch }?.outcome, .deleted)
        let deletions = await fake.calls.filter { $0.contains("delete") }
        XCTAssertEqual(deletions, [["delete", Self.unavailableWatch]])

        // A list that cannot be read again keeps everything.
        let unreadable = FakeSimctl(devices: Self.fixtureDevices, runtimes: Self.fixtureRuntimes)
        let frozen = try await Self.service(unreadable).items()
        await unreadable.failListings()
        let kept = await Self.service(unreadable).delete(frozen)
        XCTAssertEqual(kept.entries.map(\.outcome), Array(repeating: .skipped(.notRechecked), count: 3))
        let unreadableDeletions = await unreadable.calls.filter { $0.contains("delete") }
        XCTAssertTrue(unreadableDeletions.isEmpty)
    }

    func testFailuresAndDeletionsStillListedAreReportedAsSuch() async throws {
        let fake = FakeSimctl(devices: Self.fixtureDevices, runtimes: Self.fixtureRuntimes)
        let service = Self.service(fake)
        let items = try await service.items()
        await fake.failDeletion(of: Self.unavailableWatch)
        await fake.keepRuntimesListedAfterDeletion()
        let result = await service.delete(items)
        XCTAssertEqual(result.entries.first { $0.item.identifier == Self.unavailableWatch }?.outcome, .failed)
        XCTAssertEqual(result.entries.first { $0.item.identifier == Self.unavailablePhone }?.outcome, .deleted)
        XCTAssertEqual(result.entries.first { $0.item.identifier == Self.runtime18 }?.outcome, .requested)
        XCTAssertEqual(result.deletedBytes, 1_048_576_000 + 4_096, "Only what is gone counts")
        withLanguage(.zhHans) {
            // D178: decimal, "1.05 GB" (was `ByteFormat.string`, binary: "1000.0 MiB").
            XCTAssertEqual(result.message, "已删除 1 项模拟器项目 · 约 \(ByteFormat.storageString(1_048_580_096))；"
                + "1 项已交给 simctl 删除，读回时仍在列表中，请稍后重新检查；1 项未能删除")
        }
        withLanguage(.english) {
            XCTAssertTrue(result.message.hasPrefix("Deleted 1 item"), result.message)
            XCTAssertFalse(result.message.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) },
                           result.message)
        }
    }

    // MARK: Confirmation

    func testTheConfirmationListsPermanentDeletionAndTheAppsToQuit() throws {
        let items = SimulatorCleanupPolicy.items(in: try Self.inventory(otherSets: [Self.visionOS2]))
        let facts = OperationConfirmationFacts.simulatorCleanup(items)
        XCTAssertEqual(facts.actions, [.permanentDeletion])
        XCTAssertEqual(facts.recovery, [.notRecoverable])
        XCTAssertEqual(facts.itemCount, 3)
        XCTAssertEqual(facts.permanentDeletionBytes, 1_048_576_000 + 4_096 + 7_500_000_000)
        XCTAssertTrue(facts.bytesAreLowerBound, "The watch's size was not reported")
        XCTAssertEqual(facts.trashBytes, 0)
        XCTAssertTrue(facts.appsToQuit.contains("Xcode"))
        XCTAssertEqual(facts.permission, .notRequired)
    }

    /// Two confirmations, as the menu's Empty Trash (D101 L5): the frozen
    /// list runs only when both are given, and nothing is preselected.
    @MainActor
    func testTheControllerDeletesOnlyAfterBothConfirmations() async throws {
        let fake = FakeSimctl(devices: Self.fixtureDevices, runtimes: Self.fixtureRuntimes)
        let controller = SimulatorCleanupController(coordinator: HeavyWorkCoordinator(), service: Self.service(fake))
        controller.load()
        try await waitUntil { controller.phase == .loaded }
        XCTAssertEqual(controller.items.count, 3)
        XCTAssertTrue(controller.selectedIDs.isEmpty, "Nothing is selected by default")
        controller.requestDeletion()
        XCTAssertNil(controller.pending, "Nothing selected, nothing to confirm")

        let phone = try XCTUnwrap(controller.items.first { $0.identifier == Self.unavailablePhone })
        controller.setSelected(phone, true)
        controller.requestDeletion()
        XCTAssertEqual(controller.pending, [phone])
        // A selection changed while the confirmation is open does not reach it.
        controller.setSelected(controller.items[0], true)
        XCTAssertEqual(controller.pending, [phone])
        controller.confirmDeletion(acknowledgesPermanentDeletion: true, acknowledgesSimulatorDataReviewed: false)
        controller.confirmDeletion(acknowledgesPermanentDeletion: false, acknowledgesSimulatorDataReviewed: true)
        XCTAssertEqual(controller.phase, .loaded)
        var deletions = await fake.calls.filter { $0.contains("delete") }
        XCTAssertTrue(deletions.isEmpty)

        controller.confirmDeletion(acknowledgesPermanentDeletion: true, acknowledgesSimulatorDataReviewed: true)
        try await waitUntil { controller.phase == .finished }
        deletions = await fake.calls.filter { $0.contains("delete") }
        XCTAssertEqual(deletions, [["delete", Self.unavailablePhone]])
        XCTAssertNotNil(controller.resultMessage)
        XCTAssertNil(controller.pending)
    }

    // MARK: Helpers

    private static func inventory(otherSets: Set<String>) throws -> SimulatorInventory {
        SimulatorInventory(
            devices: try SimulatorInventoryParser.devices(from: json(["devices": fixtureDevices])),
            runtimes: try SimulatorInventoryParser.runtimes(from: json(fixtureRuntimes)),
            otherDeviceSetRuntimes: otherSets)
    }

    private static func service(_ fake: FakeSimctl) -> SimulatorCleanupService {
        SimulatorCleanupService(runner: FakeSimctlRunner(fake: fake), deviceSets: FixedDeviceSets(),
                                runningApplications: FakeRunningApplications(fake: fake),
                                homeURL: URL(fileURLWithPath: "/Users/fixture", isDirectory: true))
    }

    private func makeRoot() throws -> URL {
        let root = TestFileSystem.uniqueRoot("SimulatorCleanup")
        TestFileSystem.registerCleanup(of: root, for: self)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeDevice(in set: URL, udid: String, runtime: String) throws {
        let folder = set.appendingPathComponent(udid, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let plist: [String: Any] = ["UDID": udid, "runtime": runtime, "name": "Preview", "state": 1]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: folder.appendingPathComponent("device.plist"))
    }

    @MainActor
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "Timed out")
    }

    private func withLanguage(_ language: AppLanguage, _ body: () throws -> Void) rethrows {
        let defaults = TestPreferenceDomain.make(for: self)
        defaults.set(language.rawValue, forKey: L10n.languageDefaultsKey)
        let preferences = TestVolatilePreferences()
        preferences.set(defaults.string(forKey: L10n.languageDefaultsKey) ?? language.rawValue,
            forKey: L10n.languageDefaultsKey)
        defer { preferences.restore() }
        XCTAssertEqual(L10n.usesChinese, language == .zhHans)
        try body()
    }
}

/// A simctl stand-in: listings come from the fixture model, deletions change
/// it, and every argument list is recorded.
private actor FakeSimctl {
    private var devices: [String: [[String: Any]]]
    private var runtimes: [String: [String: Any]]
    private(set) var calls: [[String]] = []
    private var running: Set<String> = []
    private var failingDeletions: Set<String> = []
    private var listingsFail = false
    private var runtimesStayListed = false
    private var xcodeStartsAfterFirstDeletion = false

    init(devices: [String: [[String: Any]]], runtimes: [String: [String: Any]]) {
        self.devices = devices
        self.runtimes = runtimes
    }

    func resetCalls() { calls = [] }
    func setRunning(_ bundleIdentifiers: Set<String>) { running = bundleIdentifiers }
    func isRunning(_ bundleIdentifier: String) -> Bool { running.contains(bundleIdentifier) }
    func failDeletion(of identifier: String) { failingDeletions.insert(identifier) }
    func failListings() { listingsFail = true }
    func keepRuntimesListedAfterDeletion() { runtimesStayListed = true }
    func launchXcodeAfterFirstDeletion() { xcodeStartsAfterFirstDeletion = true }

    func addDevice(runtime: String, udid: String, available: Bool) {
        devices[runtime, default: []].append(["udid": udid, "name": "Added", "isAvailable": available])
    }

    func setAvailable(_ udid: String, _ available: Bool) {
        for (runtime, list) in devices {
            devices[runtime] = list.map { device in
                guard device["udid"] as? String == udid else { return device }
                var changed = device
                changed["isAvailable"] = available
                return changed
            }
        }
    }

    func run(_ arguments: [String]) throws -> ShellCommandResult {
        calls.append(arguments)
        switch arguments {
        case ["list", "-j", "devices"]:
            if listingsFail { throw ShellError.failed("xcrun simctl list", 1, "fixture") }
            return Self.output(try JSONSerialization.data(withJSONObject: ["devices": devices]))
        case ["runtime", "list", "-j"]:
            if listingsFail { return ShellCommandResult(terminationStatus: 1, standardOutput: "", standardError: "fixture") }
            return Self.output(try JSONSerialization.data(withJSONObject: runtimes))
        default:
            break
        }
        if arguments.count == 2, arguments[0] == "delete" {
            return delete(device: arguments[1])
        }
        if arguments.count == 3, arguments[0] == "runtime", arguments[1] == "delete" {
            return delete(runtime: arguments[2])
        }
        return ShellCommandResult(terminationStatus: 64, standardOutput: "", standardError: "unexpected")
    }

    private func delete(device udid: String) -> ShellCommandResult {
        guard !failingDeletions.contains(udid) else {
            return ShellCommandResult(terminationStatus: 1, standardOutput: "", standardError: "fixture failure")
        }
        for (runtime, list) in devices {
            devices[runtime] = list.filter { $0["udid"] as? String != udid }
        }
        afterDeletion()
        return ShellCommandResult(terminationStatus: 0, standardOutput: "", standardError: "")
    }

    private func delete(runtime identifier: String) -> ShellCommandResult {
        guard !failingDeletions.contains(identifier) else {
            return ShellCommandResult(terminationStatus: 1, standardOutput: "", standardError: "fixture failure")
        }
        if !runtimesStayListed { runtimes[identifier] = nil }
        afterDeletion()
        return ShellCommandResult(terminationStatus: 0, standardOutput: "", standardError: "")
    }

    private func afterDeletion() {
        if xcodeStartsAfterFirstDeletion { running.insert("com.apple.dt.Xcode") }
    }

    private static func output(_ data: Data) -> ShellCommandResult {
        ShellCommandResult(terminationStatus: 0, standardOutput: String(decoding: data, as: UTF8.self), standardError: "")
    }
}

private struct FakeSimctlRunner: SimulatorCommandRunning {
    let fake: FakeSimctl

    func simctl(_ arguments: [String], timeout _: TimeInterval) async throws -> ShellCommandResult {
        try await fake.run(arguments)
    }
}

private struct FakeRunningApplications: CleanupRunningApplicationChecking {
    let fake: FakeSimctl

    func isRunning(bundleIdentifier: String) async -> Bool {
        await fake.isRunning(bundleIdentifier)
    }
}

/// The preview set uses visionOS 2; the test set is empty.
private struct FixedDeviceSets: SimulatorDeviceSetReading {
    func runtimeIdentifiers(inSetAt url: URL) -> Set<String>? {
        url.path.hasSuffix("Previews/Simulator Devices") ? ["com.apple.CoreSimulator.SimRuntime.xrOS-2-0"] : []
    }
}
