import AgentBridgeCore
import AgentShared
import Foundation
import XCTest

/// The bridge learns everything from the App bundle it ships in: which App,
/// whose data directory, and so where the socket is (D260, D263).
final class AgentBridgeEnvironmentTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/fixture", isDirectory: true)

    private func makeBundle(_ root: URL, name: String = "测试版", info: [String: Any]?) throws -> URL {
        let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("Helpers"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        if let info {
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
        }
        let bridge = contents.appendingPathComponent("Helpers/storage-cleaner-agent")
        XCTAssertTrue(FileManager.default.createFile(atPath: bridge.path, contents: Data()))
        return bridge
    }

    private let betaInfo: [String: Any] = [
        "CFBundleIdentifier": "com.local.StorageCleanerMac.beta", "CFBundleExecutable": "StorageCleanerMacBeta",
        "CFBundleDisplayName": "测试版", "CFBundleShortVersionString": "2.0.2", "CFBundleVersion": "20261029120000"
    ]

    func testBundledBridgeFindsItsAppDataAndSocket() throws {
        let root = try AgentTestDirectory.make(self)
        let bridge = try makeBundle(root, info: betaInfo)
        let environment = try AgentBridgeEnvironment.locate(executable: bridge, home: home)
        XCTAssertEqual(environment.bundleIdentifier, "com.local.StorageCleanerMac.beta")
        XCTAssertEqual(environment.applicationExecutable,
                       root.path + "/测试版.app/Contents/MacOS/StorageCleanerMacBeta")
        XCTAssertEqual(environment.socketPath, "/Users/fixture/Library/Application Support/StorageCleanerMac-Beta/Agent/s")
        XCTAssertEqual(environment.serverIdentity, AgentServerIdentity(name: "storage-cleaner-beta", title: "测试版",
                                                                       version: "2.0.2 (20261029120000)"))

        let link = root.appendingPathComponent("agent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bridge)
        XCTAssertEqual(try AgentBridgeEnvironment.locate(executable: link, home: home), environment,
                       "A link on PATH still leads back to the bundle")
        // /tmp is itself a link; the App process is reported under /private/tmp.
        let viaTmp = URL(fileURLWithPath: bridge.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        XCTAssertEqual(try AgentBridgeEnvironment.locate(executable: viaTmp, home: home).applicationExecutable,
                       environment.applicationExecutable)
        XCTAssertTrue(environment.applicationExecutable.hasPrefix("/private/tmp/"), "As proc_pidpath reports it")
    }

    func testQACopyUsesItsIsolatedRoot() throws {
        let root = try AgentTestDirectory.make(self)
        let isolated = "/Users/fixture/Library/Caches/StorageCleanerIntegration-0D6A2B4E-8C1F-4F55-9E1A-2B3C4D5E6F70"
        var info = betaInfo
        info["CFBundleIdentifier"] = "com.local.StorageCleanerMac.integration"
        info["LSEnvironment"] = ["STORAGE_CLEANER_INTEGRATION_ROOT": isolated]
        let environment = try AgentBridgeEnvironment.locate(executable: try makeBundle(root, info: info), home: home)
        XCTAssertEqual(environment.dataDirectory.path, isolated)
        XCTAssertEqual(environment.serverIdentity.name, "storage-cleaner-qa")
    }

    func testOutsideABundleOrWithAForeignBundleNothingIsGuessed() throws {
        let root = try AgentTestDirectory.make(self)
        let loose = root.appendingPathComponent("storage-cleaner-agent")
        XCTAssertTrue(FileManager.default.createFile(atPath: loose.path, contents: Data()))
        XCTAssertThrowsError(try AgentBridgeEnvironment.locate(executable: loose, home: home)) {
            XCTAssertEqual($0 as? AgentBridgeEnvironment.Failure, .notInApplicationBundle)
        }
        XCTAssertThrowsError(try AgentBridgeEnvironment.locate(executable: try makeBundle(root, name: "Bare", info: nil), home: home)) {
            XCTAssertEqual($0 as? AgentBridgeEnvironment.Failure, .unreadableInfo)
        }
        var foreign = betaInfo
        foreign["CFBundleIdentifier"] = "com.example.Cleaner"
        XCTAssertThrowsError(try AgentBridgeEnvironment.locate(executable: try makeBundle(root, name: "Other", info: foreign), home: home)) {
            XCTAssertEqual($0 as? AgentBridgeEnvironment.Failure, .unknownApplication("com.example.Cleaner"))
        }
    }
}
