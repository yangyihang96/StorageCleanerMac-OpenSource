import Foundation

/// Source contracts follow the presentation extracted from the live container.
/// This does not include preview fixtures or unrelated views in their evidence.
func r2ProductionSource(at url: URL) throws -> String {
    let value = try SettingsSourceContract.source(at: url)
    guard url.lastPathComponent == "MenuBarGeekPanel.swift" else { return value }
    let presentation = url.deletingLastPathComponent().appendingPathComponent("GeekOverviewPresentation.swift")
    return value + "\n" + (try String(contentsOf: presentation, encoding: .utf8))
}

/// Scope these known source contracts to a balanced declaration, rather than
/// the next declaration in the file. Reordering declarations keeps the contract.
func r2SourceDeclaration(_ marker: String, in source: String) throws -> String {
    guard let declaration = source.range(of: marker),
          let opening = source[declaration.upperBound...].firstIndex(of: "{") else {
        throw NSError(domain: "R2SourceContract", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Missing declaration: \(marker)"])
    }
    var depth = 0
    for index in source[opening...].indices {
        if source[index] == "{" { depth += 1 }
        if source[index] == "}" {
            depth -= 1
            if depth == 0 { return String(source[declaration.lowerBound...index]) }
        }
    }
    throw NSError(domain: "R2SourceContract", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Unclosed declaration: \(marker)"])
}

@MainActor final class R2TestValue<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
