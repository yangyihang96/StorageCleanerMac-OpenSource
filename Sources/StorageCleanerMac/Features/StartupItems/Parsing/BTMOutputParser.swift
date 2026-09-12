import Foundation

struct BTMRecord: Hashable, Sendable {
    var identifier: String?
    var uuid: UUID?
    var name: String?
    var developerName: String?
    var teamIdentifier: String?
    var bundleIdentifier: String?
    var parentIdentifier: String?
    var executableURL: URL?
    var itemType: String?
    var disposition: Set<String>
    var rawFields: [String: String]
    var rawBlock: String

    var registrationState: StartupItemsDomain.RegistrationState { .registered }

    var authorizationState: StartupItemsDomain.AuthorizationState {
        if disposition.contains(where: { $0 == "denied" || $0 == "disallowed" || $0 == "notallowed" }) {
            return .denied
        }
        if disposition.contains(where: { $0 == "allowed" || $0 == "approved" }) {
            return .approved
        }
        if disposition.contains("notified")
            || disposition.contains("requiresapproval")
            || (disposition.contains("requires") && disposition.contains("approval")) {
            return .requiresApproval
        }
        return .unknown
    }

    var enablementState: StartupItemsDomain.EnablementState {
        if disposition.contains(where: { $0 == "disabled" || $0 == "disallowed" }) { return .disabled }
        if disposition.contains("enabled") { return .enabled }
        return .unknown
    }
}

/// Tolerant parser for the diagnostic output of `sfltool dumpbtm`.
/// The command is not treated as a stable API, so unknown fields are retained
/// and malformed records do not invalidate records parsed earlier.
struct BTMOutputParser: Sendable {
    func parse(_ output: String) -> [BTMRecord] {
        blocks(in: output).compactMap(parseBlock)
    }

    private func blocks(in output: String) -> [String] {
        var result = [String]()
        var current = [String]()
        var hasIdentityField = false
        var seenKeys = Set<String>()

        func flush() {
            guard !current.isEmpty, hasIdentityField else {
                current.removeAll(keepingCapacity: true)
                hasIdentityField = false
                seenKeys.removeAll(keepingCapacity: true)
                return
            }
            result.append(current.joined(separator: "\n"))
            current.removeAll(keepingCapacity: true)
            hasIdentityField = false
            seenKeys.removeAll(keepingCapacity: true)
        }

        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.allSatisfy({ $0 == "=" || $0 == "-" }) {
                flush()
                continue
            }
            let key = normalizedKey(keyValue(from: trimmed)?.key ?? "")
            let identifierKeys: Set<String> = ["identifier", "serviceidentifier", "recordidentifier"]
            if (key == "uuid" && seenKeys.contains("uuid"))
                || (identifierKeys.contains(key) && !identifierKeys.isDisjoint(with: seenKeys)) {
                flush()
            }
            current.append(trimmed)
            if !key.isEmpty { seenKeys.insert(key) }
            if ["uuid", "identifier", "serviceidentifier", "recordidentifier", "bundleidentifier", "url", "executablepath"].contains(key) {
                hasIdentityField = true
            }
        }
        flush()
        return result
    }

    private func parseBlock(_ block: String) -> BTMRecord? {
        var fields = [String: String]()
        for line in block.components(separatedBy: .newlines) {
            guard let pair = keyValue(from: line) else { continue }
            fields[normalizedKey(pair.key)] = pair.value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !fields.isEmpty else { return nil }

        let identifier = value(in: fields, keys: ["identifier", "serviceidentifier", "recordidentifier"])
        let rawUUID = value(in: fields, keys: ["uuid"])
        let rawPath = value(in: fields, keys: ["executablepath", "path", "url"])
        let dispositionText = value(in: fields, keys: ["disposition", "status", "flags"]) ?? ""
        let disposition = Set(
            dispositionText
                .lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        )

        return BTMRecord(
            identifier: identifier,
            uuid: rawUUID.flatMap(UUID.init(uuidString:)),
            name: value(in: fields, keys: ["name", "displayname"]),
            developerName: value(in: fields, keys: ["developername", "developer"]),
            teamIdentifier: value(in: fields, keys: ["teamidentifier", "teamid"]),
            bundleIdentifier: value(in: fields, keys: ["bundleidentifier", "bundleid"]),
            parentIdentifier: value(in: fields, keys: ["parentidentifier", "parentbundleidentifier"]),
            executableURL: fileURL(from: rawPath),
            itemType: value(in: fields, keys: ["type", "itemtype"]),
            disposition: disposition,
            rawFields: fields,
            rawBlock: block
        )
    }

    private func keyValue(from line: String) -> (key: String, value: String)? {
        guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { return nil }
        let key = String(line[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let value = String(line[line.index(after: separator)...])
        return key.isEmpty ? nil : (key, value)
    }

    private func normalizedKey(_ key: String) -> String {
        key.lowercased().filter(\.isLetter)
    }

    private func value(in fields: [String: String], keys: [String]) -> String? {
        keys.lazy.compactMap { fields[$0] }.first(where: { !$0.isEmpty })
    }

    private func fileURL(from rawValue: String?) -> URL? {
        guard var value = rawValue?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")),
              !value.isEmpty else { return nil }
        if value.hasPrefix("file://"), let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        if value.hasPrefix("~") {
            value = NSString(string: value).expandingTildeInPath
        }
        guard value.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: value).standardizedFileURL
    }
}
