import XCTest
@testable import StorageCleanerMac

/// Read the actual Core failure assignments without running a Core workload.
/// Any new code or nonliteral assignment must get an explicit UI contract.
enum V11CoreStopContract {
    enum ContractError: Error { case changedFailureDefinition, untranslatedCode(String) }
    static func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Services/Benchmark/MSeries/MSeriesCoreRunner.swift"), encoding: .utf8)
    }
    static func codes(in source: String) throws -> [String] {
        let assignments = try NSRegularExpression(pattern: #"\bfailure\s*=(?!=)\s*([^;\n}]+)"#)
        let literals = try NSRegularExpression(pattern: #"^"([^"]+)"$"#)
        let returns = try NSRegularExpression(pattern: #"\bglobalFailure:\s*([^,\n]+)"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let returned = returns.matches(in: source, range: range)
        guard returned.count == 1,
              let returnRange = Range(returned[0].range(at: 1), in: source),
              source[returnRange].trimmingCharacters(in: .whitespaces) == "failure" else {
            throw ContractError.changedFailureDefinition
        }
        // The only declaration must stay uninitialized, so every code reaches the assignment check below.
        let declarations = try NSRegularExpression(pattern: #"\b(?:var|let)\s+failure\b([^\n]*)"#)
        let declared = declarations.matches(in: source, range: range)
        guard declared.count == 1,
              let declarationRange = Range(declared[0].range(at: 1), in: source),
              source[declarationRange].trimmingCharacters(in: .whitespaces) == ": String?" else {
            throw ContractError.changedFailureDefinition
        }
        let matches = assignments.matches(in: source, range: range)
        guard !matches.isEmpty else { throw ContractError.changedFailureDefinition }
        return try matches.map { assignment in
            guard let valueRange = Range(assignment.range(at: 1), in: source) else {
                throw ContractError.changedFailureDefinition
            }
            let value = source[valueRange].trimmingCharacters(in: .whitespaces)
            guard let literal = literals.firstMatch(in: value, range: NSRange(value.startIndex..<value.endIndex, in: value)),
                  let codeRange = Range(literal.range(at: 1), in: value) else {
                throw ContractError.changedFailureDefinition
            }
            return String(value[codeRange])
        }
    }
    static func text(_ code: String) throws -> (zh: String, en: String) {
        switch code {
        case "thermal-protection":
            return ("温度过高 · 测试已停止以保护设备", "High temperature · Test stopped to protect the device")
        case "core-timeout", "core-item-timeout":
            return ("测试超时 · 保留已完成测量", "Test timed out · Completed measurements retained")
        default: throw ContractError.untranslatedCode(code)
        }
    }
}

// The contract is shared with MSeriesV11RunnerTests, which also builds in Release.
#if DEBUG
@MainActor
final class MSeriesV11CoreFailurePresentationTests: XCTestCase {
    func testActualCoreFailureAssignmentsHaveSpecificChineseAndEnglishPresentation() throws {
        let codes = try V11CoreStopContract.codes(in: V11CoreStopContract.source())
        XCTAssertEqual(Set(codes), ["core-timeout", "thermal-protection", "core-item-timeout"])
        XCTAssertEqual(codes.count, 3)
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for code in codes {
                let expected = try V11CoreStopContract.text(code)
                let text = MSeriesV11PagePresentation.ResultDisposition.reasonText(code)
                XCTAssertEqual(text, language == .zhHans ? expected.zh : expected.en)
                XCTAssertFalse(text.contains(code))
            }
        }
    }
    func testNewCoreCodeAndChangedAssignmentCannotEscapeTheDefinitionGuard() throws {
        let source = try V11CoreStopContract.source()
        let extended = source + "\nfailure = \"future-core-stop-code\";\n"
        let codes = try V11CoreStopContract.codes(in: extended)
        XCTAssertTrue(codes.contains("future-core-stop-code"))
        XCTAssertThrowsError(try codes.forEach { _ = try V11CoreStopContract.text($0) })
        let dynamic = source.replacingOccurrences(of: "failure = \"core-timeout\"", with: "failure = computeStopCode()")
        XCTAssertNotEqual(dynamic, source)
        XCTAssertThrowsError(try V11CoreStopContract.codes(in: dynamic))
        let changedReturn = source.replacingOccurrences(of: "globalFailure: failure", with: "globalFailure: anotherCode")
        XCTAssertNotEqual(changedReturn, source)
        XCTAssertThrowsError(try V11CoreStopContract.codes(in: changedReturn))
        let initialized = source.replacingOccurrences(of: "var failure: String?\n", with: "var failure: String? = \"future-core-stop-code\"\n")
        XCTAssertNotEqual(initialized, source)
        XCTAssertThrowsError(try V11CoreStopContract.codes(in: initialized))
        let shadowed = source.replacingOccurrences(of: "var failure: String?\n", with: "var failure: String?\n        let failure: String? = \"future-core-stop-code\"\n")
        XCTAssertNotEqual(shadowed, source)
        XCTAssertThrowsError(try V11CoreStopContract.codes(in: shadowed))
    }
}
#endif
