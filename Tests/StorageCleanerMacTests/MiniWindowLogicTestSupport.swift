import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// Shared fixtures of the batch 4b mini-window logic tests.

/// Switches the interface language for one test through the volatile argument
/// domain, like the other mini-window rule tests; nothing is persisted.
@MainActor
final class MiniWindowLogicLanguageScope {
    private let original: [String: Any]

    init(_ language: AppLanguage) {
        let defaults = UserDefaults.standard
        original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = original
        temporary[L10n.languageDefaultsKey] = language.rawValue
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        XCTAssertEqual(L10n.appLanguage, language)
    }

    func restore() {
        UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)
    }
}

enum MiniWindowLogicFixtures {
    static func source(_ relativePath: String, file: StaticString = #filePath) throws -> String {
        let root = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try SettingsSourceContract.source(at: root.appendingPathComponent(relativePath))
    }

    static func section(_ source: String, from start: String, to end: String,
                        file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing \(start)", file: file, line: line)
        let endRange = try XCTUnwrap(source.range(of: end, range: startRange.upperBound..<source.endIndex),
                                     "missing \(end)", file: file, line: line)
        return String(source[startRange.upperBound..<endRange.lowerBound])
    }

    static func memoryProcess(
        id: Int32,
        name: String,
        residentBytes: Int64,
        canQuit: Bool = true
    ) -> MemoryProcess {
        let bundlePath = "/Applications/\(name).app"
        return MemoryProcess(
            id: id,
            name: name,
            path: "\(bundlePath)/Contents/MacOS/\(name)",
            iconPath: bundlePath,
            bundlePath: bundlePath,
            residentBytes: residentBytes,
            percent: 1,
            canQuit: canQuit
        )
    }

    /// A 16 GB Mac. The defaults describe heavy pressure, so apps above the
    /// quit threshold become suggested quit candidates.
    static func memorySnapshot(
        processes: [MemoryProcess],
        freeBytes: Int64 = 300 * 1024 * 1024,
        compressedBytes: Int64 = 4 * 1024 * 1024 * 1024,
        swapUsedBytes: Int64 = 512 * 1024 * 1024,
        pressureFreePercentage: Int? = 5
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
