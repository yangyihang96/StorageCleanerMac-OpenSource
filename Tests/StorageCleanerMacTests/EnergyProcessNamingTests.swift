import Foundation
import XCTest
@testable import StorageCleanerMac

/// BOARD N16-4 (live 2026-10-07): the power page's "使用显著能耗" listed two
/// rows named "测试版" with the same icon. Findings:
/// - the process list comes from `ps -o comm=`, whose paths are vis-encoded
///   when the app runs without a UTF-8 locale (apps opened from the Finder
///   or the Dock): "/Applications/测试版.app" reads as
///   "/Applications/M-fM-5M^KM-hM-/M^UM-gM^IM^H.app", whose "/" splits the
///   bundle name, so the name became garbage and the bundle was not found;
/// - a launchd helper started from the bundle (BundleProgram) is listed with
///   its relative argv[0] "Contents/Resources/…", so it is not attributed to
///   its app;
/// - different applications with the same display name (the installed Beta
///   and an isolated copy, both "测试版") are listed under the same name.
/// Paths now come from the kernel (`proc_pidpath`); same-named different
/// applications get what tells them apart.
final class EnergyProcessNamingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EnergyProcessNamingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A real process started from "测试版.app": `ps` without a UTF-8 locale
    /// garbles its path; the kernel's path names the app.
    func testAPathPrintedWithoutAUTF8LocaleIsReadFromTheKernel() throws {
        let bundle = try makeBundle(folder: "Installed", fileName: "测试版", displayName: "测试版",
                                    identifier: "com.example.naming.beta", executableFrom: "/bin/sleep")
        let process = Process()
        process.executableURL = bundle.appendingPathComponent("Contents/MacOS/Fixture")
        process.arguments = ["30"]
        do { try process.run() } catch { throw XCTSkip("the fixture executable cannot run here: \(error)") }
        defer { process.terminate(); process.waitUntilExit() }
        let pid = process.processIdentifier

        let printed = try psCommand(pid: pid, environment: [:])
        XCTAssertFalse(printed.contains("测试版"), "ps vis-encodes the path without a UTF-8 locale: \(printed)")
        let row = EnergyProcessRow(pid: pid, parentPID: 1, residentBytes: 1_024, elapsedSeconds: 1,
                                   cpuTimeSeconds: 0, cpuPercent: 0, path: printed)

        let resolved = try XCTUnwrap(EnergyImpactService.resolvingExecutablePaths([row]).first)
        XCTAssertEqual(URL(fileURLWithPath: resolved.path).resolvingSymlinksInPath().path,
                       bundle.appendingPathComponent("Contents/MacOS/Fixture").resolvingSymlinksInPath().path)
        let snapshot = try XCTUnwrap(EnergyImpactService.menuBarSnapshot(
            previous: frame([resolved], counter: 1, uptime: 10),
            current: frame([resolved], counter: 2, uptime: 11)))
        XCTAssertEqual(snapshot.apps.map(\.name), ["测试版"])
    }

    func testAHelperListedWithARelativePathJoinsItsApplication() throws {
        let bundle = try makeBundle(folder: "Installed", fileName: "测试版", displayName: "测试版",
                                    identifier: "com.example.naming.beta")
        let main = EnergyProcessRow(pid: 9_101, parentPID: 1, residentBytes: 1_024, elapsedSeconds: 100,
                                    cpuTimeSeconds: 5, cpuPercent: 5,
                                    path: bundle.appendingPathComponent("Contents/MacOS/Fixture").path)
        let helper = EnergyProcessRow(pid: 9_102, parentPID: 1, residentBytes: 1_024, elapsedSeconds: 100,
                                      cpuTimeSeconds: 1, cpuPercent: 1, path: "Contents/Resources/FixtureHelper")
        let kernelPaths: [Int32: String] = [
            9_101: main.path,
            9_102: bundle.appendingPathComponent("Contents/Resources/FixtureHelper").path,
        ]
        let rows = EnergyImpactService.resolvingExecutablePaths([main, helper]) { kernelPaths[$0] }
        let snapshot = try XCTUnwrap(EnergyImpactService.menuBarSnapshot(
            previous: frame(rows, counter: 1, uptime: 10), current: frame(rows, counter: 2, uptime: 11)))
        XCTAssertEqual(snapshot.apps.count, 1, "the helper is part of its app, not a second row")
        XCTAssertEqual(snapshot.apps.first?.name, "测试版")
        XCTAssertEqual(snapshot.apps.first?.processIDs, [9_101, 9_102])

        // A process whose path the kernel no longer reports keeps the printed one.
        let gone = EnergyImpactService.resolvingExecutablePaths([helper]) { _ in nil }
        XCTAssertEqual(gone.first?.path, "Contents/Resources/FixtureHelper")
    }

    func testDifferentApplicationsWithTheSameNameAreToldApart() throws {
        let installed = try makeBundle(folder: "Applications", fileName: "测试版", displayName: "测试版",
                                       identifier: "com.example.naming.beta")
        let copy = try makeBundle(folder: "app-r2-mini-dark", fileName: "StorageCleanerIntegration",
                                  displayName: "测试版", identifier: "com.example.naming.integration")
        let rows = [
            EnergyProcessRow(pid: 9_201, parentPID: 1, residentBytes: 1_024, elapsedSeconds: 100,
                             cpuTimeSeconds: 5, cpuPercent: 5,
                             path: installed.appendingPathComponent("Contents/MacOS/Fixture").path),
            EnergyProcessRow(pid: 9_202, parentPID: 1, residentBytes: 1_024, elapsedSeconds: 100,
                             cpuTimeSeconds: 5, cpuPercent: 5,
                             path: copy.appendingPathComponent("Contents/MacOS/Fixture").path),
        ]
        let snapshot = try XCTUnwrap(EnergyImpactService.menuBarSnapshot(
            previous: frame(rows, counter: 1, uptime: 10), current: frame(rows, counter: 2, uptime: 11)))
        XCTAssertEqual(Set(snapshot.apps.map(\.name)),
                       ["测试版 · Applications", "测试版 · StorageCleanerIntegration"])

        XCTAssertEqual(EnergyImpactService.qualifiedName("测试版", bundlePath: "/Applications/测试版.app"),
                       "测试版 · Applications", "the folder when the bundle has the same name")
        XCTAssertEqual(EnergyImpactService.qualifiedName("测试版", bundlePath: "/x/StorageCleanerIntegration.app"),
                       "测试版 · StorageCleanerIntegration", "the bundle's own name when it differs")
        XCTAssertEqual(EnergyImpactService.qualifiedName("Tool", bundlePath: nil), "Tool")
    }

    func testTheKernelPathOfThisProcess() throws {
        let path = try XCTUnwrap(EnergyImpactService.executablePath(processIdentifier: getpid()))
        XCTAssertTrue(path.hasPrefix("/"), path)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), path)
        XCTAssertNil(EnergyImpactService.executablePath(processIdentifier: -1))
    }

    /// Review P2-12: one reader (one buffer) serves a whole sampling pass; a
    /// short path read after a long one carries nothing of it.
    func testOneReaderServesEveryProcessOfAPass() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        do { try sleeper.run() } catch { throw XCTSkip("/bin/sleep cannot run here: \(error)") }
        defer {
            sleeper.terminate()
            sleeper.waitUntilExit()
        }
        var reader = EnergyImpactService.ExecutablePathReader()
        let own = try XCTUnwrap(reader.path(of: getpid()))
        XCTAssertGreaterThan(own.utf8.count, "/bin/sleep".utf8.count, own)
        XCTAssertEqual(reader.path(of: sleeper.processIdentifier), "/bin/sleep")
        XCTAssertEqual(reader.path(of: getpid()), own)
        XCTAssertNil(reader.path(of: -1))
        XCTAssertEqual(EnergyImpactService.executablePath(processIdentifier: getpid()), own)
    }

    // MARK: - Support

    private func makeBundle(folder: String, fileName: String, displayName: String, identifier: String,
                            executableFrom source: String? = nil) throws -> URL {
        let bundle = root.appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent("\(fileName).app", isDirectory: true)
        let macOS = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": displayName,
            "CFBundleDisplayName": displayName,
            "CFBundleExecutable": "Fixture",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let executable = macOS.appendingPathComponent("Fixture")
        if let source {
            try FileManager.default.copyItem(atPath: source, toPath: executable.path)
        } else {
            FileManager.default.createFile(atPath: executable.path, contents: Data())
        }
        return bundle
    }

    private func psCommand(pid: Int32, environment: [String: String]) throws -> String {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-o", "comm=", "-p", String(pid)]
        ps.environment = environment
        let pipe = Pipe()
        ps.standardOutput = pipe
        try ps.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func frame(_ rows: [EnergyProcessRow], counter: UInt64,
                       uptime: TimeInterval) -> EnergyImpactService.MenuBarCounterFrame {
        let counters = Dictionary(uniqueKeysWithValues: rows.map { row in
            (row.pid, EnergyResourceUsage(pid: row.pid, energyNanojoules: counter * 1_000_000_000,
                                          cpuTimeMach: counter * 1_000_000, processStartMach: 7,
                                          diskReadBytes: counter, diskWrittenBytes: counter))
        })
        return .init(sampledAt: Date(), uptime: uptime, rows: rows, counters: counters)
    }
}
