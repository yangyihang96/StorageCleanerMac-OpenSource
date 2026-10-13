import Foundation
import XCTest
@testable import StorageCleanerMac

/// D38: the memory status sample reads the system-wide free percentage from
/// `kern.memorystatus_level` instead of starting `/usr/bin/memory_pressure -Q`
/// (the value that tool prints) on every refresh.
@MainActor
final class MemoryHeadroomSysctlTests: XCTestCase {
    func testTheStatusSampleDoesNotStartMemoryPressure() throws {
        let probe = try source("Sources/StorageCleanerMac/Features/Memory/Infrastructure/SystemMemoryProbe.swift")
        XCTAssertFalse(probe.contains("\"/usr/bin/memory_pressure\""),
                       "The status sample must not start memory_pressure for each refresh")
        XCTAssertTrue(probe.contains("sysctlbyname(\"kern.memorystatus_level\""),
                      "Headroom comes from the kernel value memory_pressure prints")
    }

    /// The tool prints the kernel value: read the kernel just before and just
    /// after running the tool, and the tool's number lies between the two
    /// reads. The value can move while the tool runs and move back, so a
    /// reading that falls outside its own bracket is measured again (at most
    /// three brackets); the number must still equal a value the kernel reported
    /// around it, with no tolerance.
    func testTheKernelValueIsTheNumberMemoryPressurePrints() throws {
        let kernel = try XCTUnwrap(SystemMemoryProbe.readSystemMemoryFreePercentage())
        XCTAssertTrue((0...100).contains(kernel))
        var brackets: [(before: Int32, tool: Int, after: Int32)] = []
        for _ in 0..<3 {
            let before = try XCTUnwrap(SystemMemoryProbe.readSystemMemoryFreePercentage())
            let output = try Shell.capture("/usr/bin/memory_pressure", ["-Q"], timeout: 5)
            let after = try XCTUnwrap(SystemMemoryProbe.readSystemMemoryFreePercentage())
            let tool = try XCTUnwrap(MemoryOptimizerService.pressureSummary(from: output).freePercentage)
            brackets.append((before, tool, after))
            if (Int(min(before, after))...Int(max(before, after))).contains(tool) { return }
        }
        XCTFail("memory_pressure printed a value outside every kernel bracket: \(brackets)")
    }

    func testTheHeadroomKeepsTheToolsWording() async throws {
        let chinese = HeadroomLanguageScope(.zhHans)
        defer { chinese.restore() }
        XCTAssertEqual(MemoryOptimizerService.pressureSummary(freePercentage: 68).summary, "压力余量 68%")
        XCTAssertEqual(MemoryOptimizerService.pressureSummary(freePercentage: 68).summary,
                       MemoryOptimizerService.pressureSummary(from: "System-wide memory free percentage: 68%").summary)
        XCTAssertEqual(MemoryOptimizerService.pressureSummary(freePercentage: 130).freePercentage, 100)
        XCTAssertEqual(MemoryOptimizerService.pressureSummary(freePercentage: -3).freePercentage, 0)

        let snapshot = await SystemMemoryProbe.shared.snapshot(includeProcesses: false)
        let headroom = try XCTUnwrap(snapshot.pressureFreePercentage, "The status sample keeps its headroom")
        XCTAssertTrue((0...100).contains(headroom))
        XCTAssertEqual(snapshot.pressureSummary, "压力余量 \(headroom)%")
    }

    // MARK: Helpers

    private func source(_ relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// Switches L10n for one assertion block through the volatile argument
/// domain (as MiniWindowConsistencyRuleTests does).
@MainActor
private final class HeadroomLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}
