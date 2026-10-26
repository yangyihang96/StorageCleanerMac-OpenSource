import CryptoKit
import Foundation
import XCTest
@testable import StorageCleanerMac

final class D186YARAEngineTests: XCTestCase {
    private func check(_ strings: String = "", _ condition: String, bytes: [UInt8], expected: Bool = true,
                       file: StaticString = #filePath, line: UInt = #line) throws {
        let rules = YARARuleset(source: "rule Synthetic { \(strings.isEmpty ? "" : "strings: " + strings) condition: \(condition) }")
        XCTAssertEqual(rules.unsupportedCount, 0, "\(rules.rules.compactMap(\.unsupportedReason))", file: file, line: line)
        let root = TestFileSystem.uniqueRoot("d186-engine")
        TestFileSystem.registerCleanup(of: root, for: self)
        try TestFileSystem.createDirectory(at: root)
        let url = root.appendingPathComponent("synthetic.bytes")
        try Data(bytes).write(to: url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let contents = try handle.readToEnd() ?? Data()
        let result = rules.evaluate(data: contents, fileSize: Int64(contents.count))
        XCTAssertEqual(result.ruleNames == ["Synthetic"], expected, file: file, line: line)
        XCTAssertEqual(result.inconclusiveRuleCount, 0, file: file, line: line)
    }
    func testTextAsciiEscapesAndOverlappingMatches() throws {
        try check(#"$a = "aba" ascii $b = "\x00\t\n\r\\\"# + "\"\"", "#a == 2 and @a[1] == 0 and @a[2] == 2 and $b at 5",
                  bytes: Array("ababa".utf8) + [0, 9, 10, 13, 92, 34])
    }
    func testNocaseOnlyFoldsAscii() throws {
        try check(#"$a = "aBc" nocase"#, "$a", bytes: Array("ABC".utf8))
        try check(#"$a = "\xc0" nocase"#, "$a", bytes: [0xe0], expected: false)
    }
    func testWideIsUTF16LittleEndianAndAsciiRequiresItsModifier() throws {
        try check(#"$a = "Hi" wide"#, "#a == 1 and @a == 3", bytes: [72, 105, 32, 72, 0, 105, 0])
        try check(#"$a = "Hi" wide ascii nocase"#, "#a == 2", bytes: [72, 73, 32, 104, 0, 105, 0])
    }
    func testFullwordUsesAsciiWordBoundaries() throws {
        try check(#"$a = "cat" fullword nocase"#, "#a == 3 and @a[1] == 5", bytes: Array("xcat CAT cat_ cat9 cat!".utf8))
    }
    func testWideFullwordChecksPairsOnBothSides() throws {
        try check(#"$a = "cat" wide fullword"#, "#a == 1 and @a == 12",
                  bytes: [120, 0, 99, 0, 97, 0, 116, 0, 32, 0, 32, 0, 99, 0, 97, 0, 116, 0, 33, 0])
    }
    func testHexWholeAndHalfByteWildcards() throws {
        try check("$a = { 41 ?? A? ?B 42 }", "$a", bytes: [0x41, 0, 0xaf, 0x2b, 0x42])
        try check("$a = { 41 A? ?B }", "$a", bytes: [0x41, 0x9f, 0x2b], expected: false)
    }
    func testHexJumpsAlternativesAndNestedAlternatives() throws {
        try check("$a = { 41 [1-3] ( 42 | ( 43 44 | 45 ) ) [2] 46 }", "$a at 1",
                  bytes: [0, 0x41, 9, 9, 0x43, 0x44, 9, 9, 0x46])
        try check("$a = { 41 [1-2] 42 }", "$a", bytes: [0x41, 0, 0, 0, 0x42], expected: false)
    }
    func testRegexCountsOverlapsAndPreservesLatin1ByteOffsets() throws {
        try check(#"$a = /ab[0-9]{2}/ $b = /aba/"#, "$a at 2 and #b == 2 and @b[2] == 9",
                  bytes: [0xff, 0x80] + Array("ab12 ababa".utf8))
    }
    func testRegexByteClassesCaseAndDotSemantics() throws {
        try check(#"$a = /a.c/i $b = /\w\d\s/"#, "$a at 0 and $b at 4", bytes: [65, 13, 67, 0, 120, 49, 32])
        try check(#"$a = /a.c/"#, "$a", bytes: [97, 10, 99], expected: false)
        try check(#"$a = /a.c/s"#, "$a", bytes: [97, 10, 99])
    }
    func testFilesizeWithBothCasesOfIntegerSuffixesAndArithmetic() throws {
        try check("", "filesize == 1kb and 1KB < 2mB and 2MB == 2097152 and (4 + 2 * 3) == 10", bytes: Array(repeating: 0, count: 1024))
    }
    func testAtInCountAndOneBasedOffsets() throws {
        try check(#"$a = "ok""#, "$a at 1 and $a in (4..4) and #a == 2 and @a[2] == 4 and not (@a[0] == 0)",
                  bytes: Array(" ok ok".utf8), expected: false) // undefined is not negated into a hit.
        try check(#"$a = "ok""#, "$a at 1 and $a in (4..4) and #a == 2 and @a[2] == 4", bytes: Array(" ok ok".utf8))
    }
    func testUintReadsEndianAndOutOfRangeIsUndefined() throws {
        try check("", "uint32be(0) == 0x01020304 and uint32(0) == 0x04030201 and uint16be(1) == 0x0203 and uint8(3) == 4", bytes: [1, 2, 3, 4])
        try check("", "not (uint32(2) == 0)", bytes: [0, 0, 0, 0], expected: false)
    }
    func testSha256OverTheFileAndAPartialRange() throws {
        let bytes = Array("Synthetic D186 fixture".utf8)
        let whole = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        let partial = SHA256.hash(data: Data(bytes[2..<6])).map { String(format: "%02x", $0) }.joined()
        try check("", "hash.sha256(0, filesize) == \"\(whole)\" and hash.sha256(2, 4) == \"\(partial)\"", bytes: bytes)
    }
    func testAllAnyAndNumericOfWildcardSets() throws {
        let strings = #"$a1 = "one" $a2 = "two" $b = "three""#
        try check(strings, "all of ($a*) and any of them and 2 of them and not 3 of them", bytes: Array("one two".utf8))
        try check(strings, "all of them", bytes: Array("one two".utf8), expected: false)
    }
    func testPrivateRulesTagsDescriptionsCommentsAndReferences() {
        let rules = YARARuleset(source: #"""
        import "hash"
        /* synthetic only; braces } and rule text in a comment */
        private rule Header : synthetic { meta: description = "fixture" strings: $a = "hello" condition: $a at 0 }
        rule Visible { condition: Header and filesize == 5 } // trailing comment
        """#)
        XCTAssertEqual(rules.supportedCount, 2)
        XCTAssertEqual(rules.rules.first?.description, "fixture")
        XCTAssertEqual(rules.evaluate(data: Data("hello".utf8), fileSize: 5).ruleNames, ["Visible"])
    }
    func testRuleFilesHaveIndependentPrivateReferencesAndGlobalConditions() {
        let rules = YARARuleset(sources: [
            "private rule Header { strings: $a = \"alpha\" condition: $a at 0 } rule First { condition: Header }",
            "private rule Header { strings: $a = \"beta\" condition: $a at 0 } global rule Gate { condition: false } rule Second { condition: Header }"
        ])
        XCTAssertEqual(rules.supportedCount, 5)
        XCTAssertEqual(rules.evaluate(data: Data("alpha".utf8), fileSize: 5).ruleNames, ["First"])
    }
    func testForAnyAndAllOfWithCurrentStringAndCount() throws {
        try check(#"$a1 = "ab" $a2 = "cd""#, "for any of ($a*) : ($ at 0) and for all of them : (# == 1)", bytes: Array("ab cd".utf8))
    }
    func testForAnyAllAndNumericInRangesWithOffsetExpressions() throws {
        try check(#"$a = "a""#, "for all i in (1..#a-1) : (@a[i+1] - @a[i] == 2) and for any j in (0..3) : (uint8(j) == 98) and for 2 i in (1..3) : (i > 1)", bytes: Array("ababa".utf8))
    }
    func testUnsupportedRulesNeverHitEvenWhenAnotherBranchIsTrue() {
        let rules = YARARuleset(source: #"""
        rule Encoded { strings: $a = "fixture" base64 condition: true or $a }
        rule UnknownFunction { condition: true or math.entropy(0, filesize) > 1 }
        rule Dependency { condition: Encoded }
        rule Ordinary { condition: true }
        """#)
        XCTAssertEqual(rules.unsupportedCount, 3)
        XCTAssertEqual(rules.evaluate(data: Data(), fileSize: 0).ruleNames, ["Ordinary"])
    }
    func testInvalidTypedConditionsAndEmptySetsCannotHideBehindTrue() {
        let rules = YARARuleset(source: """
        rule BadRead { condition: true or uint32(true) == 0 }
        rule BadArithmetic { condition: true or 1 + false == 2 }
        rule BadRange { strings: $a = "x" condition: true or $a at true }
        rule EmptySet { condition: all of them }
        rule EmptyTags : { condition: true }
        rule Good { condition: true == true }
        """)
        XCTAssertEqual(rules.unsupportedCount, 5)
        XCTAssertEqual(rules.evaluate(data: Data(), fileSize: 0).ruleNames, ["Good"])
    }
    func testLocalScriptRuleSupportAndParseTime() throws {
        let url = MalwareScanRoots.live.ruleFiles[1]
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("D186: system script rules are inaccessible") }
        let start = Date()
        let rules = YARARuleset(source: source)
        XCTAssertGreaterThan(rules.rules.count, 0)
        XCTAssertGreaterThanOrEqual(Double(rules.supportedCount) / Double(rules.rules.count), 0.95)
        XCTAssertLessThan(Date().timeIntervalSince(start), 15)
        print("D186 XPScripts supported=\(rules.supportedCount)/\(rules.rules.count), parseSeconds=\(Date().timeIntervalSince(start))")
    }
    func testMalformedRulesAndCyclesDoNotCrashOrPoisonFollowingRules() {
        let rules = YARARuleset(source: #"""
        rule Broken { strings: $a = { 41 [9-2] 42 } condition: $a }
        rule Syntax { condition: ( }
        private rule First { condition: Second }
        private rule Second { condition: First }
        rule Good { condition: filesize == 0 }
        """#)
        XCTAssertEqual(rules.unsupportedCount, 4)
        XCTAssertEqual(rules.evaluate(data: Data(), fileSize: 0).ruleNames, ["Good"])
    }
    func testUnavailableContentUsesOnlyDecidableMetadataAndNeverNegatesUnknownToTrue() {
        let rules = YARARuleset(source: #"""
        rule Size { condition: filesize > 64MB }
        rule NeedBytes { strings: $a = "fixture" condition: not $a }
        rule Guarded { strings: $a = "fixture" condition: filesize < 64MB and $a }
        """#)
        let result = rules.evaluate(data: nil, fileSize: 64 * 1024 * 1024 + 1)
        XCTAssertEqual(result.ruleNames, ["Size"])
        XCTAssertEqual(result.inconclusiveRuleCount, 1)
    }
    func testEvaluationBudgetAndCancellationCannotProduceAHIt() {
        let rules = YARARuleset(source: "rule Budget { condition: not (for any i in (0..1000000) : (i == -1)) }")
        XCTAssertTrue(rules.evaluate(data: Data(), fileSize: 0).ruleNames.isEmpty)
        XCTAssertEqual(rules.evaluate(data: Data(), fileSize: 0).inconclusiveRuleCount, 1)
        XCTAssertTrue(YARARuleset(source: "rule Cancel { condition: true }").evaluate(data: Data(), fileSize: 0, cancelled: { true }).ruleNames.isEmpty)
    }
    func testLocalXProtectRuleSupportAndParseTime() throws {
        let url = MalwareScanRoots.live.ruleFiles[0]
        guard let source = try? String(contentsOf: url, encoding: .utf8) else { throw XCTSkip("D186: system XProtect rules are inaccessible") }
        let start = Date()
        let rules = YARARuleset(source: source)
        let seconds = Date().timeIntervalSince(start)
        XCTAssertGreaterThan(rules.rules.count, 0)
        XCTAssertGreaterThanOrEqual(Double(rules.supportedCount) / Double(rules.rules.count), 0.95)
        XCTAssertLessThan(seconds, 15)
        print("D186 XProtect supported=\(rules.supportedCount)/\(rules.rules.count), parseSeconds=\(seconds)")
        if let scripts = try? String(contentsOf: MalwareScanRoots.live.ruleFiles[1], encoding: .utf8) {
            let combinedStart = Date()
            let combined = YARARuleset(sources: [source, scripts])
            let scriptRules = YARARuleset(source: scripts)
            XCTAssertEqual(combined.supportedCount, rules.supportedCount + scriptRules.supportedCount)
            XCTAssertEqual(combined.rules.count, rules.rules.count + scriptRules.rules.count)
            XCTAssertLessThan(Date().timeIntervalSince(combinedStart), 15)
            print("D186 combined supported=\(combined.supportedCount)/\(combined.rules.count), parseSeconds=\(Date().timeIntervalSince(combinedStart))")
        }
    }
}
