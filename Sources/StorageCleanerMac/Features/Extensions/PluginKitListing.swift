import Foundation

/// One record of `pluginkit -mAvvv`: a header line (election mark,
/// identifier and version) followed by tab-indented `Key = value` lines.
struct PluginKitRecord: Equatable, Sendable {
    let identifier: String
    let version: String?
    let election: ExtensionElection
    let path: String
    let extensionPoint: String?
    let parentPath: String?
    let parentName: String?
    let displayName: String?

    /// Apple's own extensions are counted, not listed.
    var isApple: Bool {
        identifier.hasPrefix("com.apple.")
            || path.hasPrefix("/System/")
            || (parentPath?.hasPrefix("/System/") ?? false)
    }
}

/// D-FP1: app and Safari extensions are read from pluginkit, as Mac Sai
/// does. Read-only: `-m` matches, `-A` includes every version, `-vvv`
/// prints every field. Nothing is elected or ignored from this app.
enum PluginKitListing {
    static let executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
    static let arguments = ["-mAvvv"]
    static let timeout: TimeInterval = 10
    static let outputByteLimit = 4 * 1_024 * 1_024

    /// The records, or nil when pluginkit could not be run or failed.
    static func read(
        runner: any StartupItemsDomain.StartupProcessRunning = StartupItemsDomain
            .CancellableStartupProcessRunner(outputByteLimit: outputByteLimit)
    ) async -> [PluginKitRecord]? {
        guard let result = try? await runner.run(executableURL: executableURL, arguments: arguments,
                                                 timeout: timeout),
              result.terminationStatus == 0 else { return nil }
        return parse(result.standardOutput)
    }

    static func parse(_ output: String) -> [PluginKitRecord] {
        var records: [PluginKitRecord] = []
        var header: (identifier: String, version: String?, election: ExtensionElection)?
        var fields: [String: String] = [:]

        func flush() {
            defer { header = nil; fields = [:] }
            guard let header, let path = fields["Path"], path.hasPrefix("/") else { return }
            records.append(PluginKitRecord(
                identifier: header.identifier, version: header.version, election: header.election,
                path: path, extensionPoint: fields["SDK"], parentPath: fields["Parent Bundle"],
                parentName: fields["Parent Name"], displayName: fields["Display Name"]
            ))
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
                continue
            }
            if line.hasPrefix("\t") {
                guard header != nil else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard let separator = trimmed.range(of: " = ") else { continue }
                let key = String(trimmed[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
                if fields[key] == nil, !value.isEmpty, value != "(null)" { fields[key] = value }
                continue
            }
            flush()
            header = parseHeader(line)
        }
        flush()
        return records
    }

    /// `+    com.example.Widget(1.2)`; the version can itself be `(null)`.
    static func parseHeader(_ line: String) -> (identifier: String, version: String?, election: ExtensionElection)? {
        guard let first = line.first else { return nil }
        let election: ExtensionElection = switch first {
        case "+": .enabled
        case "-": .disabled
        case "=": .superseded
        default: .automatic
        }
        let rest = (["+", "-", "=", "!", "?"].contains(first) ? String(line.dropFirst()) : line)
            .trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty else { return nil }
        guard let open = rest.firstIndex(of: "("), let close = rest.lastIndex(of: ")"), open < close else {
            return (rest, nil, election)
        }
        let identifier = String(rest[..<open]).trimmingCharacters(in: .whitespaces)
        guard !identifier.isEmpty else { return nil }
        let version = String(rest[rest.index(after: open)..<close])
        return (identifier, version.isEmpty || version == "(null)" ? nil : version, election)
    }
}
