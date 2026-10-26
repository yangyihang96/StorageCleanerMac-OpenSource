import Foundation
import XCTest
@testable import StorageCleanerMac

/// D100 G4-1: docs/2.0.1/cleanup-rule-table.md lists every cleanup rule from
/// the three sources the loader combines, in load order. The file is generated
/// here; a rule change without the regenerated file fails.
final class CleanupRuleTableTests: XCTestCase {
    private static let recordVariable = "STORAGE_CLEANER_RECORD_RULE_TABLE"
    private static let documentURL = SwiftSourceScanning.projectRoot
        .appendingPathComponent("docs/2.0.1/cleanup-rule-table.md")

    func testRuleTableDocumentMatchesTheLoadedRules() throws {
        let rendered = try Self.render(CleanupRuleSetLoader.loadBundled())
        if ProcessInfo.processInfo.environment[Self.recordVariable] == "1" {
            try FileManager.default.createDirectory(
                at: Self.documentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try rendered.write(to: Self.documentURL, atomically: true, encoding: .utf8)
        }
        let stored = try String(contentsOf: Self.documentURL, encoding: .utf8)
        XCTAssertEqual(stored, rendered, """
            docs/2.0.1/cleanup-rule-table.md is out of date. Regenerate it with \
            \(Self.recordVariable)=1 swift test --filter CleanupRuleTableTests
            """)
    }

    func testRuleTableHasOneRowForEachRuleOfTheThreeSources() throws {
        let ruleSet = try CleanupRuleSetLoader.loadBundled()
        let json = try JSONDecoder().decode(CleanupRuleSet.self, from: Data(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Resources/CleanupRules.v2.json")))
        let expected = DeveloperToolArtifactCatalog.cleanupRules.count + CleanupCoverageCatalog.cleanupRules.count
            + json.rules.count
        XCTAssertGreaterThan(json.rules.count, 0)
        XCTAssertEqual(ruleSet.rules.count, expected)
        let rows = Self.render(ruleSet).split(separator: "\n")
            .filter { $0.range(of: #"^\| \d+ \|"#, options: .regularExpression) != nil }
        XCTAssertEqual(rows.count, expected)
        XCTAssertEqual(rows.map { $0.split(separator: "|")[1].trimmingCharacters(in: .whitespaces) },
                       ruleSet.rules.map { "`\($0.id)`" })
    }

    static func render(_ ruleSet: CleanupRuleSet) -> String {
        let counts = Dictionary(grouping: ruleSet.rules, by: { $0.maintenance?.source.rawValue ?? "none" })
            .mapValues(\.count)
        var lines = [
            "# 2.0.1 清理规则表",
            "",
            "本文件由 `Tests/StorageCleanerMacTests/CleanupRuleTableTests.swift` 从 `CleanupRuleSetLoader.loadBundled()` 生成，"
                + "请勿手改。规则改动后用 `\(recordVariable)=1 swift test --filter CleanupRuleTableTests` 重新生成；"
                + "文件与规则不一致时测试失败（DECISIONS D100 G4-1）。",
            "",
            "规则集 schemaVersion \(ruleSet.schemaVersion)，rulesVersion \(ruleSet.rulesVersion)，共 \(ruleSet.rules.count) 条："
                + "`developer-catalog` \(counts["developer-catalog", default: 0]) 条（`DeveloperToolArtifactCatalog`），"
                + "`coverage-catalog` \(counts["coverage-catalog", default: 0]) 条（`CleanupCoverageCatalog`），"
                + "`json` \(counts["json", default: 0]) 条（`Resources/CleanupRules.v2.json`）。"
                + "顺序即加载顺序：多条规则命中同一项目时，排在前面的规则认领。",
            "",
            "列说明：根路径中 `~` 是用户主目录；范围与匹配见 `CleanupRule.candidateScope` 和 `include.nameMatcher`；"
                + "风险、动作、默认勾选为规则里的原始取值；需先退出的 App 是 bundle ID；修订是 `maintenance.revision`。",
            "",
            "| # | ID | 来源 | 根路径 | 范围与匹配 | 风险 | 动作 | 默认勾选 | 需先退出的 App | 证据 | 修订 |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        for (index, rule) in ruleSet.rules.enumerated() {
            let root = rule.root.kind == .homeRelative ? "~/" + rule.root.path : rule.root.path
            let matcher = rule.include.nameMatcher.mode == .any
                ? "any"
                : rule.include.nameMatcher.mode.rawValue + ": " + rule.include.nameMatcher.values.joined(separator: ", ")
            let evidence = rule.maintenance?.evidenceURLs.map { "<\($0)>" }.joined(separator: "<br>") ?? ""
            let cells = [
                "\(index + 1)",
                "`\(rule.id)`",
                rule.maintenance?.source.rawValue ?? "—",
                "`\(root)`",
                rule.effectiveCandidateScope.rawValue + " · " + matcher,
                rule.risk.rawValue,
                rule.action.rawValue,
                rule.defaultSelection.rawValue,
                rule.requiredClosedBundleIDs.isEmpty ? "—" : rule.requiredClosedBundleIDs.joined(separator: ", "),
                evidence.isEmpty ? "—" : evidence,
                rule.maintenance.map { "\($0.revision)" } ?? "—",
            ]
            lines.append("| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
