import Foundation

// D101 G2: iOS simulator items Xcode no longer uses. Two kinds are listed,
// read-only through `xcrun simctl … -j` (argument arrays, never a shell):
// devices simctl reports unavailable, and runtime images no device uses,
// counting the devices in Xcode's preview and test device sets as well.
// Each is deleted only through simctl's own command, one identifier at a
// time, after two confirmations; CoreSimulator's folders are never touched
// directly, because CoreSimulator manages them. Nothing is offered when the
// selected developer tools have no simctl.

struct SimulatorDevice: Equatable, Sendable {
    let udid: String
    let name: String
    let runtimeIdentifier: String
    let isAvailable: Bool
    let availabilityError: String?
    /// The data and log folders simctl reports, when it reports them.
    let bytes: Int64?
}

struct SimulatorRuntime: Equatable, Sendable {
    /// The image identifier `simctl runtime delete` takes.
    let identifier: String
    /// What devices name, such as `com.apple.CoreSimulator.SimRuntime.iOS-27-0`.
    let runtimeIdentifier: String
    let version: String
    let build: String
    let state: String
    let isDeletable: Bool
    let bytes: Int64?
}

struct SimulatorInventory: Equatable, Sendable {
    var devices: [SimulatorDevice]
    /// nil when simctl could not list runtimes; then none is offered.
    var runtimes: [SimulatorRuntime]?
    /// Runtimes the devices in Xcode's other device sets use. nil when a set
    /// could not be read: then no runtime counts as unused.
    var otherDeviceSetRuntimes: Set<String>?
}

struct SimulatorCleanupItem: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case unavailableDevice
        case unusedRuntime
    }

    /// What must still be true when the item is deleted.
    struct Target: Hashable, Sendable {
        let kind: Kind
        let identifier: String
        let runtimeIdentifier: String
        let build: String?
    }

    let kind: Kind
    /// The device UDID or runtime image identifier simctl deletes; always a UUID.
    let identifier: String
    let name: String
    let runtimeIdentifier: String
    /// The runtime build; nil for devices.
    let build: String?
    /// As simctl reported it when listed.
    let bytes: Int64?
    /// Why simctl says a device is unavailable.
    let availabilityError: String?

    var id: String { "\(kind.rawValue):\(identifier)" }

    var target: Target {
        Target(kind: kind, identifier: identifier, runtimeIdentifier: runtimeIdentifier, build: build)
    }

    /// Everything after `xcrun simctl`: one item, never `all` or `unavailable`.
    var deletionArguments: [String] {
        switch kind {
        case .unavailableDevice: ["delete", identifier]
        case .unusedRuntime: ["runtime", "delete", identifier]
        }
    }

    var title: String {
        switch kind {
        case .unavailableDevice:
            name
        case .unusedRuntime:
            L10n.text("\(name) 运行时", "\(name) Runtime")
        }
    }

    var detail: String {
        switch kind {
        case .unavailableDevice:
            let reason = availabilityError.map { L10n.text("：\($0)", ": \($0)") } ?? ""
            return L10n.text(
                "不可用的模拟器设备\(reason)。删除会一并删除设备里的 App 和数据。",
                "Unavailable simulator device\(reason). Deleting it also deletes its apps and data."
            )
        case .unusedRuntime:
            let build = build.map { L10n.text("（\($0)）", " (\($0))") } ?? ""
            return L10n.text(
                "没有任何模拟器设备在用的运行时\(build)。需要时可在 Xcode 设置的“Components”中重新下载。",
                "Runtime\(build) no simulator device uses. Download it again in Xcode Settings > Components when needed."
            )
        }
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` reads `iOS 27.0`.
    static func runtimeName(_ runtimeIdentifier: String, version: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimRuntime."
        guard runtimeIdentifier.hasPrefix(prefix) else { return version }
        let parts = runtimeIdentifier.dropFirst(prefix.count).split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return version }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}

enum SimulatorCleanupPolicy {
    /// Unavailable devices, and deletable runtime images no device uses. A
    /// device of any availability, in any device set, keeps its runtime.
    /// Two images with the same runtime identifier both count as used when a
    /// device names it, since simctl does not say which image it runs.
    static func items(in inventory: SimulatorInventory) -> [SimulatorCleanupItem] {
        let devices = inventory.devices
            .filter { !$0.isAvailable && isSingleItemIdentifier($0.udid) }
            .sorted { ($0.name, $0.udid) < ($1.name, $1.udid) }
            .map { device in
                SimulatorCleanupItem(
                    kind: .unavailableDevice, identifier: device.udid, name: device.name,
                    runtimeIdentifier: device.runtimeIdentifier, build: nil, bytes: device.bytes,
                    availabilityError: device.availabilityError
                )
            }
        guard let runtimes = inventory.runtimes, let otherDeviceSetRuntimes = inventory.otherDeviceSetRuntimes else {
            return devices
        }
        let used = Set(inventory.devices.map(\.runtimeIdentifier)).union(otherDeviceSetRuntimes)
        let unused = runtimes
            .filter { runtime in
                runtime.isDeletable
                    && isSingleItemIdentifier(runtime.identifier)
                    && !runtime.runtimeIdentifier.isEmpty
                    && !used.contains(runtime.runtimeIdentifier)
                    && runtime.state.range(of: "delet", options: .caseInsensitive) == nil
            }
            .sorted { ($0.runtimeIdentifier, $0.build) < ($1.runtimeIdentifier, $1.build) }
            .map { runtime in
                SimulatorCleanupItem(
                    kind: .unusedRuntime, identifier: runtime.identifier,
                    name: SimulatorCleanupItem.runtimeName(runtime.runtimeIdentifier, version: runtime.version),
                    runtimeIdentifier: runtime.runtimeIdentifier, build: runtime.build, bytes: runtime.bytes,
                    availabilityError: nil
                )
            }
        return devices + unused
    }

    /// simctl also accepts `all`, `unavailable` and `booted`; only a UUID
    /// names exactly one item.
    static func isSingleItemIdentifier(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }
}

enum SimulatorInventoryParser {
    private struct DeviceList: Decodable {
        let devices: [String: [Device]]
    }

    private struct Device: Decodable {
        let udid: String
        let name: String
        let isAvailable: Bool?
        let availabilityError: String?
        let dataPathSize: Int64?
        let logPathSize: Int64?
    }

    private struct Runtime: Decodable {
        let identifier: String?
        let runtimeIdentifier: String?
        let version: String?
        let build: String?
        let state: String?
        let deletable: Bool?
        let sizeBytes: Int64?
    }

    /// `simctl list -j devices`. A device without `isAvailable` counts as
    /// available: it is never offered, and it still keeps its runtime.
    static func devices(from data: Data) throws -> [SimulatorDevice] {
        let list = try JSONDecoder().decode(DeviceList.self, from: data)
        return list.devices.flatMap { runtimeIdentifier, devices in
            devices.map { device in
                SimulatorDevice(
                    udid: device.udid, name: device.name, runtimeIdentifier: runtimeIdentifier,
                    isAvailable: device.isAvailable ?? true, availabilityError: device.availabilityError,
                    bytes: total(device.dataPathSize, device.logPathSize)
                )
            }
        }
        .sorted { $0.udid < $1.udid }
    }

    /// `simctl runtime list -j`, keyed by image identifier. An entry whose
    /// key and identifier differ, or that leaves out what deleting needs, is
    /// kept as not deletable so its runtime is still known.
    static func runtimes(from data: Data) throws -> [SimulatorRuntime] {
        let list = try JSONDecoder().decode([String: Runtime].self, from: data)
        return list.map { key, runtime in
            let complete = runtime.identifier == key && runtime.runtimeIdentifier?.isEmpty == false
                && runtime.build != nil
            return SimulatorRuntime(
                identifier: key, runtimeIdentifier: runtime.runtimeIdentifier ?? "",
                version: runtime.version ?? "", build: runtime.build ?? "", state: runtime.state ?? "",
                isDeletable: complete && runtime.deletable == true, bytes: runtime.sizeBytes
            )
        }
        .sorted { $0.identifier < $1.identifier }
    }

    private static func total(_ values: Int64?...) -> Int64? {
        let known = values.compactMap { $0 }.filter { $0 >= 0 }
        return known.isEmpty ? nil : known.reduce(0) { CleanupByteCount.adding($1, to: $0) }
    }
}

/// Reads which runtimes the devices in one of Xcode's other device sets use,
/// from each device's own `device.plist`. Read-only; no process.
protocol SimulatorDeviceSetReading: Sendable {
    /// Empty only when the set is confirmed not to exist; nil when it, or a
    /// device in it, could not be read.
    func runtimeIdentifiers(inSetAt url: URL) -> Set<String>?
}

struct FoundationSimulatorDeviceSetReader: SimulatorDeviceSetReading {
    func runtimeIdentifiers(inSetAt url: URL) -> Set<String>? {
        // B-R1: fileExists is also false behind a folder that cannot be
        // searched, so only ENOENT or ENOTDIR counts as no set.
        var status = stat()
        guard stat(url.path, &status) == 0 else {
            let code = errno
            return code == ENOENT || code == ENOTDIR ? [] : nil
        }
        guard status.st_mode & S_IFMT == S_IFDIR,
              let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return nil }
        var runtimes = Set<String>()
        for name in names where UUID(uuidString: name) != nil {
            let plist = url.appendingPathComponent(name, isDirectory: true).appendingPathComponent("device.plist")
            guard let data = try? Data(contentsOf: plist),
                  let device = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let runtime = device["runtime"] as? String, !runtime.isEmpty else {
                return nil
            }
            runtimes.insert(runtime)
        }
        return runtimes
    }
}

/// Finds the developer directory xcrun would use, from files only: running
/// xcrun without developer tools asks the user to install them.
enum SimulatorToolLocator {
    static let selectionLink = "/var/db/xcode_select_link"
    static let defaultDeveloperDirectory = "/Applications/Xcode.app/Contents/Developer"

    /// The directory, when it holds simctl; Command Line Tools alone do not.
    static func developerDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        selectionLink: String = SimulatorToolLocator.selectionLink,
        fileManager: FileManager = .default
    ) -> URL? {
        var path: String
        if let value = environment["DEVELOPER_DIR"], !value.isEmpty {
            path = value
        } else if let link = try? fileManager.destinationOfSymbolicLink(atPath: selectionLink), !link.isEmpty {
            path = link
        } else {
            path = defaultDeveloperDirectory
        }
        if path.hasSuffix(".app") || path.hasSuffix(".app/") {
            path = URL(fileURLWithPath: path).appendingPathComponent("Contents/Developer").path
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let simctl = directory.appendingPathComponent("usr/bin/simctl")
        return fileManager.isExecutableFile(atPath: simctl.path) ? directory : nil
    }
}

protocol SimulatorCommandRunning: Sendable {
    /// Runs `xcrun simctl` with these arguments: an argument array, no shell.
    func simctl(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult
}

struct XcrunSimulatorCommandRunner: SimulatorCommandRunning {
    static let xcrun = "/usr/bin/xcrun"
    /// Listings are a few MiB at most.
    static let outputByteLimit = 16 * 1_024 * 1_024

    func simctl(_ arguments: [String], timeout: TimeInterval) async throws -> ShellCommandResult {
        try await Task.detached(priority: .userInitiated) {
            try Shell.run(Self.xcrun, ["simctl"] + arguments, timeout: timeout, outputByteLimit: Self.outputByteLimit)
        }.value
    }
}

enum SimulatorCleanupError: LocalizedError, Equatable {
    case listingFailed

    var errorDescription: String? {
        L10n.text("无法读取模拟器列表", "Could not read the simulator list")
    }
}

struct SimulatorCleanupResult: Equatable, Sendable {
    enum SkipReason: Equatable, Sendable {
        /// Xcode or Simulator was running.
        case ownerRunning
        /// No longer listed the same way: a device became available again,
        /// a device now uses the runtime, or the item is gone.
        case changed
        /// The list could not be read again before deleting.
        case notRechecked
    }

    enum Outcome: Equatable, Sendable {
        /// Gone when read back.
        case deleted
        /// simctl accepted the command, but the item was still listed.
        case requested
        case skipped(SkipReason)
        case failed
    }

    struct Entry: Equatable, Sendable {
        let item: SimulatorCleanupItem
        let outcome: Outcome
    }

    var entries: [Entry] = []

    func count(_ outcome: Outcome) -> Int { entries.filter { $0.outcome == outcome }.count }

    var deletedCount: Int { count(.deleted) }
    var requestedCount: Int { count(.requested) }
    var failedCount: Int { count(.failed) }
    var skippedCount: Int {
        entries.filter { if case .skipped = $0.outcome { true } else { false } }.count
    }

    /// As simctl reported the deleted items when they were listed.
    var deletedBytes: Int64 {
        entries.filter { $0.outcome == .deleted }
            .reduce(0) { CleanupByteCount.adding($1.item.bytes ?? 0, to: $0) }
    }

    var message: String {
        var parts = [L10n.text(
            "已删除 \(ByteFormat.count(deletedCount)) 项模拟器项目 · 约 \(ByteFormat.storageString(deletedBytes))",
            "Deleted \(L10n.items(deletedCount)) of simulator data · about \(ByteFormat.storageString(deletedBytes))"
        )]
        if requestedCount > 0 {
            parts.append(L10n.text(
                "\(ByteFormat.count(requestedCount)) 项已交给 simctl 删除，读回时仍在列表中，请稍后重新检查",
                "\(L10n.items(requestedCount)) handed to simctl were still listed when read back; check again later"
            ))
        }
        let running = count(.skipped(.ownerRunning))
        if running > 0 {
            parts.append(L10n.text(
                "Xcode 或模拟器正在运行，\(ByteFormat.count(running)) 项已跳过",
                "Xcode or Simulator was running, so \(L10n.items(running)) were skipped"
            ))
        }
        let changed = count(.skipped(.changed)) + count(.skipped(.notRechecked))
        if changed > 0 {
            parts.append(L10n.text(
                "\(ByteFormat.count(changed)) 项在确认后有变化或无法复查，已保留",
                "\(L10n.items(changed)) changed after confirmation or could not be rechecked and were kept"
            ))
        }
        if failedCount > 0 {
            parts.append(L10n.text("\(ByteFormat.count(failedCount)) 项未能删除", "\(L10n.items(failedCount)) could not be deleted"))
        }
        return parts.joined(separator: L10n.text("；", "; "))
    }
}

struct SimulatorCleanupService: Sendable {
    /// Deleting is skipped while either runs.
    static let ownerBundleIdentifiers = ["com.apple.dt.Xcode", "com.apple.iphonesimulator"]
    /// Xcode's other device sets (SwiftUI previews, test clones), relative to home.
    static let otherDeviceSets = [
        "Library/Developer/Xcode/UserData/Previews/Simulator Devices",
        "Library/Developer/XCTestDevices",
    ]
    static let listingTimeout: TimeInterval = 60
    /// Deleting a runtime image can take minutes.
    static let deletionTimeout: TimeInterval = 600

    let runner: any SimulatorCommandRunning
    var deviceSets: any SimulatorDeviceSetReading = FoundationSimulatorDeviceSetReader()
    var runningApplications: any CleanupRunningApplicationChecking = FoundationCleanupRunningApplicationChecker()
    var homeURL: URL = FileManager.default.homeDirectoryForCurrentUser

    /// Read-only: two simctl listings and the other sets' device files.
    func inventory() async throws -> SimulatorInventory {
        let listing = try await runner.simctl(["list", "-j", "devices"], timeout: Self.listingTimeout)
        guard listing.terminationStatus == 0,
              let devices = try? SimulatorInventoryParser.devices(from: Data(listing.standardOutput.utf8)) else {
            throw SimulatorCleanupError.listingFailed
        }
        var runtimes: [SimulatorRuntime]?
        if let output = try? await runner.simctl(["runtime", "list", "-j"], timeout: Self.listingTimeout),
           output.terminationStatus == 0 {
            runtimes = try? SimulatorInventoryParser.runtimes(from: Data(output.standardOutput.utf8))
        }
        var otherDeviceSetRuntimes: Set<String>? = []
        for relative in Self.otherDeviceSets {
            let set = homeURL.appendingPathComponent(relative, isDirectory: true)
            guard let used = deviceSets.runtimeIdentifiers(inSetAt: set) else {
                otherDeviceSetRuntimes = nil
                break
            }
            otherDeviceSetRuntimes?.formUnion(used)
        }
        return SimulatorInventory(devices: devices, runtimes: runtimes, otherDeviceSetRuntimes: otherDeviceSetRuntimes)
    }

    func items() async throws -> [SimulatorCleanupItem] {
        SimulatorCleanupPolicy.items(in: try await inventory())
    }

    func runningOwners() async -> [String] {
        var running: [String] = []
        for bundleIdentifier in Self.ownerBundleIdentifiers
        where await runningApplications.isRunning(bundleIdentifier: bundleIdentifier) {
            running.append(bundleIdentifier)
        }
        return running
    }

    /// Deletes only the items frozen for the confirmation that are still
    /// listed the same way now, one simctl command each, and reads the
    /// list back to say what is gone.
    func delete(_ frozen: [SimulatorCleanupItem]) async -> SimulatorCleanupResult {
        var result = SimulatorCleanupResult()
        guard await runningOwners().isEmpty else {
            result.entries = frozen.map { .init(item: $0, outcome: .skipped(.ownerRunning)) }
            return result
        }
        guard let current = try? await items() else {
            result.entries = frozen.map { .init(item: $0, outcome: .skipped(.notRechecked)) }
            return result
        }
        let eligible = Set(current.map(\.target))
        var handedOver: [SimulatorCleanupItem] = []
        for item in frozen {
            guard eligible.contains(item.target),
                  SimulatorCleanupPolicy.isSingleItemIdentifier(item.identifier) else {
                result.entries.append(.init(item: item, outcome: .skipped(.changed)))
                continue
            }
            guard await runningOwners().isEmpty else {
                result.entries.append(.init(item: item, outcome: .skipped(.ownerRunning)))
                continue
            }
            do {
                let output = try await runner.simctl(item.deletionArguments, timeout: Self.deletionTimeout)
                if output.terminationStatus == 0 {
                    handedOver.append(item)
                } else {
                    result.entries.append(.init(item: item, outcome: .failed))
                }
            } catch {
                result.entries.append(.init(item: item, outcome: .failed))
            }
        }
        guard !handedOver.isEmpty else { return result }
        let after = try? await inventory()
        for item in handedOver {
            let stillListed: Bool
            if let after {
                switch item.kind {
                case .unavailableDevice:
                    stillListed = after.devices.contains { $0.udid == item.identifier }
                case .unusedRuntime:
                    stillListed = after.runtimes?.contains { $0.identifier == item.identifier } ?? true
                }
            } else {
                stillListed = true
            }
            result.entries.append(.init(item: item, outcome: stillListed ? .requested : .deleted))
        }
        return result
    }
}

extension OperationConfirmationFacts {
    /// D101 G2: count and size come from the list frozen when the
    /// confirmation opened, as simctl reported them.
    static func simulatorCleanup(_ items: [SimulatorCleanupItem]) -> OperationConfirmationFacts {
        let bytes = items.reduce(Int64(0)) { CleanupByteCount.adding($1.bytes ?? 0, to: $0) }
        return OperationConfirmationFacts(
            surface: .developerTools, actions: [.permanentDeletion],
            items: items.map { item in
                OperationConfirmationItem(id: item.id, title: item.title, path: nil, bytes: item.bytes,
                                          detail: item.detail)
            },
            localBytes: bytes, bytesAreLowerBound: items.contains { $0.bytes == nil },
            permanentDeletionBytes: bytes,
            appsToQuit: ["Xcode", L10n.text("模拟器", "Simulator")],
            recovery: [.notRecoverable], permission: .notRequired
        )
    }
}
