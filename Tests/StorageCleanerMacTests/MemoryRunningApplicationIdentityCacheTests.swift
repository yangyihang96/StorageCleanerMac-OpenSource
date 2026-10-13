// The reuse counters exist in Debug builds only.
#if DEBUG
import AppKit
import Darwin
import XCTest
@testable import StorageCleanerMac

/// Phase 2 audit: the memory process list read every running application's
/// bundle identifier, paths and launch date on the main thread at each
/// refresh. They are read once per process now (process identifier and
/// start time); what the probe gets must be what reading them directly gives.
@MainActor
final class MemoryRunningApplicationIdentityCacheTests: XCTestCase {
    func testCachedIdentitiesEqualDirectReadsOnEveryRefresh() throws {
        for _ in 0..<3 {
            let applications = NSWorkspace.shared.runningApplications
            XCTAssertFalse(applications.isEmpty)
            let cached = RunningApplicationIdentityCache.identities(of: applications)
            XCTAssertEqual(cached.map(\.0), applications.map(\.processIdentifier))
            for ((pid, identity), app) in zip(cached, applications) {
                XCTAssertEqual(pid, app.processIdentifier)
                XCTAssertEqual(identity.name, app.localizedName)
                XCTAssertEqual(identity.bundleIdentifier, app.bundleIdentifier)
                XCTAssertEqual(identity.bundlePath, app.bundleURL?.path)
                XCTAssertEqual(identity.executablePath, app.executableURL?.path)
                XCTAssertEqual(identity.launchDate, app.launchDate)
                XCTAssertEqual(identity.isActive, app.isActive)
                let expectedPolicy: MemoryRunningApplicationActivationPolicy = switch app.activationPolicy {
                case .regular: .regular
                case .accessory: .accessory
                default: .prohibited
                }
                XCTAssertEqual(identity.activationPolicy, expectedPolicy)
            }
        }
    }

    /// The probe refreshes on different run-loop turns, and
    /// `NSWorkspace.runningApplications` returns new objects on each turn
    /// (review of phase 2: 0 of 167 objects the same across turns). The
    /// stored identities must still be used again for every application
    /// whose process is the same as at the previous refresh.
    func testIdentitiesAreReusedOnTheNextRunLoopTurn() {
        let first = NSWorkspace.shared.runningApplications
        _ = RunningApplicationIdentityCache.identities(of: first)
        let started = Dictionary(first.map { ($0.processIdentifier, Self.startTime(of: $0.processIdentifier)) },
                                 uniquingKeysWith: { earlier, _ in earlier })
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))

        let second = NSWorkspace.shared.runningApplications
        let identities = RunningApplicationIdentityCache.identities(of: second)
        let unchanged = second.filter { app in
            guard let now = Self.startTime(of: app.processIdentifier) else { return false }
            return started[app.processIdentifier] == now
        }
        XCTAssertGreaterThan(unchanged.count, 0)
        XCTAssertEqual(RunningApplicationIdentityCache.reusedCount, unchanged.count,
                       "every application whose process did not change is not read again")
        XCTAssertEqual(RunningApplicationIdentityCache.readCount, second.count - unchanged.count)
        for ((pid, identity), app) in zip(identities, second) {
            XCTAssertEqual(pid, app.processIdentifier)
            XCTAssertEqual(identity.bundleIdentifier, app.bundleIdentifier)
            XCTAssertEqual(identity.bundlePath, app.bundleURL?.path)
            XCTAssertEqual(identity.executablePath, app.executableURL?.path)
            XCTAssertEqual(identity.launchDate, app.launchDate)
            XCTAssertEqual(identity.name, app.localizedName)
            XCTAssertEqual(identity.isActive, app.isActive)
        }
    }

    /// Each refresh brings new objects for the same processes (as
    /// `NSWorkspace.runningApplications` does on each turn): the fixed
    /// properties are read once per process.
    func testAProcessSeenAgainIsNotReadAgainFromANewObject() {
        let counter = ReadCounter()
        let started: [pid_t: UInt64] = [901: 1_000, 902: 2_000]
        func refresh() -> [(pid_t, SystemMemoryProbe.RunningAppIdentity)] {
            RunningApplicationIdentityCache.identities(
                of: [FakeApplication(pid: 901, bundle: "com.example.a", counter: counter),
                     FakeApplication(pid: 902, bundle: "com.example.b", counter: counter)],
                startTime: { started[$0] })
        }
        _ = refresh()
        XCTAssertEqual(counter.identityReads, 2)
        let second = refresh()
        XCTAssertEqual(counter.identityReads, 2, "new objects for the same processes are not read again")
        XCTAssertEqual(RunningApplicationIdentityCache.reusedCount, 2)
        XCTAssertEqual(RunningApplicationIdentityCache.readCount, 0)
        XCTAssertEqual(second.map(\.1.bundleIdentifier), ["com.example.a", "com.example.b"])
        XCTAssertEqual(second.map(\.1.name), ["App 901", "App 902"], "the name is read every time")
    }

    /// A process identifier reused by a new process (another start time) is
    /// read again.
    func testAReusedProcessIdentifierIsReadAgain() {
        let counter = ReadCounter()
        var started: [pid_t: UInt64] = [903: 1_000]
        _ = RunningApplicationIdentityCache.identities(
            of: [FakeApplication(pid: 903, bundle: "com.example.old", counter: counter)], startTime: { started[$0] })
        started[903] = 5_000
        let again = RunningApplicationIdentityCache.identities(
            of: [FakeApplication(pid: 903, bundle: "com.example.new", counter: counter)], startTime: { started[$0] })
        XCTAssertEqual(again.first?.1.bundleIdentifier, "com.example.new")
        XCTAssertEqual(RunningApplicationIdentityCache.readCount, 1)
        XCTAssertEqual(RunningApplicationIdentityCache.reusedCount, 0)
        XCTAssertEqual(counter.identityReads, 2)
    }

    /// Without a start time a process cannot be told apart from a later one
    /// with the same identifier: it is read every time and not stored.
    func testAProcessWithoutAStartTimeIsReadEveryTime() {
        let counter = ReadCounter()
        for bundle in ["com.example.first", "com.example.second"] {
            let identities = RunningApplicationIdentityCache.identities(
                of: [FakeApplication(pid: 904, bundle: bundle, counter: counter)], startTime: { _ in nil })
            XCTAssertEqual(identities.first?.1.bundleIdentifier, bundle)
            XCTAssertEqual(RunningApplicationIdentityCache.readCount, 1)
            XCTAssertEqual(RunningApplicationIdentityCache.reusedCount, 0)
        }
        XCTAssertEqual(counter.identityReads, 2)
    }

    private static func startTime(of pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec
    }

    /// Applications that are no longer listed are not kept.
    func testIdentitiesOfAShorterListOnlyCoverThatList() {
        let applications = NSWorkspace.shared.runningApplications
        _ = RunningApplicationIdentityCache.identities(of: applications)
        let first = Array(applications.prefix(1))
        XCTAssertEqual(RunningApplicationIdentityCache.identities(of: first).map(\.0), first.map(\.processIdentifier))
        XCTAssertEqual(RunningApplicationIdentityCache.identities(of: applications).count, applications.count)
    }
}

private final class ReadCounter {
    var identityReads = 0
}

/// A running application read the way the probe reads one; counts reads of
/// the fixed properties through its bundle identifier.
private final class FakeApplication: RunningApplicationIdentitySource {
    let processIdentifier: pid_t
    let localizedName: String?
    let activationPolicy: NSApplication.ActivationPolicy = .regular
    let isActive = false
    private let bundle: String
    private let counter: ReadCounter

    init(pid: pid_t, bundle: String, counter: ReadCounter) {
        processIdentifier = pid
        localizedName = "App \(pid)"
        self.bundle = bundle
        self.counter = counter
    }

    var bundleIdentifier: String? {
        counter.identityReads += 1
        return bundle
    }
    var bundleURL: URL? { URL(fileURLWithPath: "/Applications/\(bundle).app") }
    var executableURL: URL? { URL(fileURLWithPath: "/Applications/\(bundle).app/Contents/MacOS/\(bundle)") }
    var launchDate: Date? { Date(timeIntervalSince1970: 1_000) }
}
#endif
