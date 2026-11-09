import AgentShared
import Darwin
import FileOperationShared
import Foundation
import XCTest

/// D263: where the socket lives, and who may stand at either end of it.
final class AgentLocationAndPeerTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)
    private let releaseData = "/Users/fixture/Library/Application Support/StorageCleanerMac"
    private let betaData = "/Users/fixture/Library/Application Support/StorageCleanerMac-Beta"

    // MARK: Data directory and socket path

    func testDataDirectoryFollowsTheAppsOwnRules() {
        func directory(_ id: String, _ environment: [String: String] = [:], beta: Bool = false) -> String? {
            AgentDataLocation.dataDirectory(bundleIdentifier: id, environment: environment, home: home, compiledAsBeta: beta)?.path
        }
        XCTAssertEqual(directory("com.local.StorageCleanerMac"), releaseData)
        XCTAssertEqual(directory("com.local.StorageCleanerMac.beta"), betaData)
        let root = "/Users/fixture/Library/Caches/StorageCleanerIntegration-0D6A2B4E-8C1F-4F55-9E1A-2B3C4D5E6F70"
        XCTAssertEqual(directory("com.local.StorageCleanerMac.integration", ["STORAGE_CLEANER_INTEGRATION_ROOT": root], beta: true), root)
        for rejected in ["/Users/fixture/Library/Caches/Other-1", "/tmp/StorageCleanerIntegration-1",
                         "/Users/fixture/Library/Caches/x/../StorageCleanerIntegration-1"] {
            XCTAssertEqual(directory("com.local.StorageCleanerMac.integration", ["STORAGE_CLEANER_INTEGRATION_ROOT": rejected], beta: true),
                           betaData, "Same fallback as AppDataDirectories.integrationRoot: \(rejected)")
        }
        XCTAssertEqual(directory("com.local.StorageCleanerMac", ["STORAGE_CLEANER_INTEGRATION_ROOT": root]),
                       releaseData, "Only the QA bundle accepts the override")
        XCTAssertNil(directory("com.example.Other"))
    }

    func testSocketPathsFitSunPathForEveryBuild() throws {
        let release = AgentSocketLocation.socketPath(dataDirectory: URL(fileURLWithPath: releaseData))
        let beta = AgentSocketLocation.socketPath(dataDirectory: URL(fileURLWithPath: betaData))
        let qa = AgentSocketLocation.socketPath(dataDirectory: home.appendingPathComponent(
            "Library/Caches/StorageCleanerIntegration-0D6A2B4E-8C1F-4F55-9E1A-2B3C4D5E6F70"))
        XCTAssertEqual(beta, betaData + "/Agent/s")
        XCTAssertEqual([release, beta, qa].map(\.utf8.count), [68, 73, 100])
        for path in [release, beta, qa] { XCTAssertNoThrow(try AgentSocketLocation.validateLength(path)) }
        XCTAssertNoThrow(try AgentSocketLocation.validateLength("/" + String(repeating: "a", count: 102)))
        XCTAssertThrowsError(try AgentSocketLocation.validateLength("/" + String(repeating: "a", count: 103))) {
            XCTAssertEqual($0 as? AgentSocketLocationError, .pathTooLong(104))
        }
    }

    func testDirectoryCheckRejectsLinksFilesLoosePermissionsAndOtherOwners() throws {
        let root = try AgentTestDirectory.make(self)
        let data = root.appendingPathComponent("d")
        let agent = data.appendingPathComponent("Agent")
        XCTAssertThrowsError(try AgentSocketLocation.checkDirectory(dataDirectory: data, uid: getuid())) {
            XCTAssertEqual($0 as? AgentSocketLocationError, .missing)
        }
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        XCTAssertEqual(chmod(agent.path, 0o755), 0)
        XCTAssertThrowsError(try AgentSocketLocation.checkDirectory(dataDirectory: data, uid: getuid())) {
            XCTAssertEqual($0 as? AgentSocketLocationError, .wrongPermissions(0o755))
        }
        XCTAssertEqual(chmod(agent.path, 0o700), 0)
        XCTAssertNoThrow(try AgentSocketLocation.checkDirectory(dataDirectory: data, uid: getuid()))
        XCTAssertThrowsError(try AgentSocketLocation.checkDirectory(dataDirectory: data, uid: getuid() + 1)) {
            XCTAssertEqual($0 as? AgentSocketLocationError, .wrongOwner)
        }

        let linked = root.appendingPathComponent("l")
        try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("Agent"), withDestinationURL: agent)
        XCTAssertThrowsError(try AgentSocketLocation.checkDirectory(dataDirectory: linked, uid: getuid())) {
            XCTAssertEqual($0 as? AgentSocketLocationError, .isSymbolicLink)
        }

        let plain = root.appendingPathComponent("f")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: plain.appendingPathComponent("Agent").path, contents: Data()))
        XCTAssertThrowsError(try AgentSocketLocation.checkDirectory(dataDirectory: plain, uid: getuid())) {
            XCTAssertEqual($0 as? AgentSocketLocationError, .notADirectory)
        }
    }

    // MARK: The App checks the bridge

    func testAppAcceptsOnlyTheBundledBridgeOfTheSameUserAndSigner() {
        let app = UpdateAskpassCodeIdentity(identifier: "com.local.StorageCleanerMac.beta", team: "TEAM", cdhash: Data([1]))
        let bundled = UpdateAskpassCodeIdentity(identifier: "com.local.StorageCleanerMac.beta.agent-bridge", team: "TEAM", cdhash: Data([2]))
        let policy = AgentBridgePeerPolicy(bridgeExecutable: "/Applications/测试版.app/Contents/Helpers/storage-cleaner-agent",
                                           application: app, bundledBridge: bundled)
        let peer = UpdateAskpassKernelPeer(pid: 301, uid: getuid(), auditToken: Data(repeating: 0, count: 32))
        for boundary in ["valid", "uid", "path", "identifier", "signer", "hash", "reused"] {
            let reads = AgentLookupCounter()
            let allowed = policy.permits(
                boundary == "uid" ? .init(pid: 301, uid: getuid() + 1, auditToken: peer.auditToken) : peer,
                uid: getuid(),
                process: { pid in
                    guard pid == 301 else { return nil }
                    return UpdateProcessSnapshot(pid: pid, startTime: boundary == "reused" && reads.next() > 0 ? 99 : 10,
                                                 parentPID: 200, groupPID: 200, uid: boundary == "uid" ? getuid() + 1 : getuid(),
                                                 executable: boundary == "path" ? "/tmp/storage-cleaner-agent" : policy.bridgeExecutable)
                },
                signature: { _ in
                    .init(identifier: boundary == "identifier" ? "com.example.agent-bridge" : bundled.identifier,
                          team: boundary == "signer" ? "OTHER" : "TEAM", cdhash: boundary == "hash" ? Data([9]) : bundled.cdhash)
                })
            XCTAssertEqual(allowed, boundary == "valid", boundary)
        }
    }

    func testAppRequiresTheBridgeIdentifierToBeItsOwnPlusSuffix() {
        let app = UpdateAskpassCodeIdentity(identifier: "com.local.StorageCleanerMac.beta", team: "TEAM", cdhash: Data([1]))
        let foreign = UpdateAskpassCodeIdentity(identifier: "com.local.StorageCleanerMac.agent-bridge", team: "TEAM", cdhash: Data([2]))
        let policy = AgentBridgePeerPolicy(bridgeExecutable: "/b", application: app, bundledBridge: foreign)
        let peer = UpdateAskpassKernelPeer(pid: 7, uid: getuid(), auditToken: Data())
        XCTAssertFalse(policy.permits(peer, uid: getuid(),
                                      process: { UpdateProcessSnapshot(pid: $0, startTime: 1, parentPID: 1, groupPID: 1, uid: getuid(), executable: "/b") },
                                      signature: { _ in foreign }),
                       "The release bridge must not be accepted by the Beta, and the other way round")
    }

    func testAdHocBridgeMustBeTheExactBundledBytes() {
        let app = UpdateAskpassCodeIdentity(identifier: "com.local.StorageCleanerMac.integration", team: nil, cdhash: Data([1]), adHoc: true)
        let bundled = UpdateAskpassCodeIdentity(identifier: "com.local.StorageCleanerMac.integration.agent-bridge", team: nil,
                                                cdhash: Data([2]), adHoc: true)
        let policy = AgentBridgePeerPolicy(bridgeExecutable: "/b", application: app, bundledBridge: bundled)
        let peer = UpdateAskpassKernelPeer(pid: 7, uid: getuid(), auditToken: Data())
        let process: (pid_t) -> UpdateProcessSnapshot? = {
            UpdateProcessSnapshot(pid: $0, startTime: 1, parentPID: 1, groupPID: 1, uid: getuid(), executable: "/b")
        }
        XCTAssertTrue(policy.permits(peer, uid: getuid(), process: process, signature: { _ in bundled }))
        XCTAssertFalse(policy.permits(peer, uid: getuid(), process: process, signature: { _ in
            .init(identifier: bundled.identifier, team: nil, cdhash: Data([3]), adHoc: true)
        }))
        let signedApp = AgentBridgePeerPolicy(bridgeExecutable: "/b", application: .init(identifier: app.identifier, team: nil, cdhash: Data([1])),
                                              bundledBridge: bundled)
        XCTAssertFalse(signedApp.permits(peer, uid: getuid(), process: process, signature: { _ in bundled }),
                       "No team and not ad hoc: nothing authenticates the bundled bytes")
    }

    // MARK: The bridge checks the App

    func testBridgeAcceptsOnlyItsOwnAppProcess() {
        let bridge = UpdateAskpassCodeIdentity(identifier: "com.local.StorageCleanerMac.beta.agent-bridge", team: "TEAM", cdhash: Data([2]))
        let policy = AgentApplicationPeerPolicy(applicationExecutable: "/Applications/测试版.app/Contents/MacOS/StorageCleanerMacBeta",
                                                applicationIdentifier: "com.local.StorageCleanerMac.beta", bridge: bridge,
                                                bundledApplication: nil)
        let peer = UpdateAskpassKernelPeer(pid: 401, uid: getuid(), auditToken: Data(repeating: 0, count: 32))
        for boundary in ["valid", "uid", "path", "identifier", "signer", "reused"] {
            let reads = AgentLookupCounter()
            let allowed = policy.permits(
                boundary == "uid" ? .init(pid: 401, uid: getuid() + 1, auditToken: peer.auditToken) : peer,
                uid: getuid(),
                process: { pid in
                    guard pid == 401 else { return nil }
                    return UpdateProcessSnapshot(pid: pid, startTime: boundary == "reused" && reads.next() > 0 ? 99 : 10,
                                                 parentPID: 1, groupPID: 401, uid: boundary == "uid" ? getuid() + 1 : getuid(),
                                                 executable: boundary == "path" ? "/tmp/StorageCleanerMacBeta" : policy.applicationExecutable)
                },
                signature: { _ in
                    .init(identifier: boundary == "identifier" ? "com.local.StorageCleanerMac" : policy.applicationIdentifier,
                          team: boundary == "signer" ? "OTHER" : "TEAM", cdhash: Data([1]))
                })
            XCTAssertEqual(allowed, boundary == "valid", boundary)
        }
    }

    func testAdHocBridgeComparesTheAppWithTheBundleOnDisk() {
        let bridge = UpdateAskpassCodeIdentity(identifier: "x.agent-bridge", team: nil, cdhash: Data([2]), adHoc: true)
        let onDisk = UpdateAskpassCodeIdentity(identifier: "x", team: nil, cdhash: Data([5]), adHoc: true)
        let process: (pid_t) -> UpdateProcessSnapshot? = {
            UpdateProcessSnapshot(pid: $0, startTime: 1, parentPID: 1, groupPID: 1, uid: getuid(), executable: "/A.app/Contents/MacOS/A")
        }
        let peer = UpdateAskpassKernelPeer(pid: 9, uid: getuid(), auditToken: Data())
        let checked = AgentApplicationPeerPolicy(applicationExecutable: "/A.app/Contents/MacOS/A", applicationIdentifier: "x",
                                                 bridge: bridge, bundledApplication: onDisk)
        XCTAssertTrue(checked.permits(peer, uid: getuid(), process: process, signature: { _ in onDisk }))
        XCTAssertFalse(checked.permits(peer, uid: getuid(), process: process, signature: { _ in
            .init(identifier: "x", team: nil, cdhash: Data([6]), adHoc: true)
        }))
        let unchecked = AgentApplicationPeerPolicy(applicationExecutable: "/A.app/Contents/MacOS/A", applicationIdentifier: "x",
                                                   bridge: bridge, bundledApplication: nil)
        XCTAssertFalse(unchecked.permits(peer, uid: getuid(), process: process, signature: { _ in onDisk }),
                       "An ad-hoc bridge without the App's on-disk identity has nothing to compare with")
    }
}

/// Counts lookups so a test can change the answer after the first one.
final class AgentLookupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { defer { count += 1 }; return count } }
}

/// Short directories under /private/tmp: a socket path must fit in sun_path,
/// and the per-user temporary directory is already 50 bytes long.
enum AgentTestDirectory {
    static func make(_ testCase: XCTestCase) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("sc-agt-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        testCase.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
