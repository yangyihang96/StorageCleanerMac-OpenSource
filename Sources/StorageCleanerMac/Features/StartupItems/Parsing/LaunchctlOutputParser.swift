import Foundation

struct LaunchctlRuntimeEvidence: Equatable, Sendable {
    var domain: String?
    var label: String?
    var servicePath: String?
    var program: String?
    var stateDescription: String?
    var pid: Int32?
    var lastExitCode: Int32?
    var runs: Int?
    var activeCount: Int?
    var registrationState: StartupItemsDomain.RegistrationState
    var loadState: StartupItemsDomain.LoadState
    var processState: StartupItemsDomain.ProcessState
    var rawFields: [String: String]
}
struct LaunchctlListRecord: Equatable, Sendable {
    let label: String
    let pid: Int32?
    let lastExitCode: Int32?

    /// A missing PID means loaded but idle, not disabled.
    var processState: StartupItemsDomain.ProcessState {
        if let pid { return .running(pid: pid) }
        if let lastExitCode, lastExitCode != 0 { return .failed(exitCode: lastExitCode) }
        return .stopped
    }
}

struct LaunchctlOutputParser: Sendable {
    func parsePrint(_ output: String) -> LaunchctlRuntimeEvidence {
        let firstLine = output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { $0.contains(" = {") })
        let serviceIdentifier = firstLine?.components(separatedBy: " = {").first
        let identity = serviceIdentifier.map(parseServiceIdentifier)
        let fields = parseFields(output)
        let pid = int32(fields["pid"])
        let exitCode = int32(fields["lastexitcode"] ?? fields["laststatus"])
        let state = fields["state"]?.lowercased()
        let activeCount = integer(fields["activecount"])
        let runs = integer(fields["runs"])

        let processState: StartupItemsDomain.ProcessState
        if let pid {
            processState = .running(pid: pid)
        } else if state == "waiting" || state == "spawn scheduled" {
            processState = .waiting
        } else if let exitCode, exitCode != 0, state == "exited" || state == "failed" {
            processState = .failed(exitCode: exitCode)
        } else if fields.isEmpty {
            processState = .unknown
        } else {
            processState = .stopped
        }

        let loadState: StartupItemsDomain.LoadState
        if fields.isEmpty {
            loadState = .unknown
        } else if state == "running" || pid != nil || (activeCount ?? 0) > 0 {
            loadState = .loaded
        } else if state == "waiting" || state == "not running" || state == "exited" {
            loadState = .onDemand
        } else {
            loadState = .loaded
        }

        return LaunchctlRuntimeEvidence(
            domain: identity?.domain,
            label: identity?.label,
            servicePath: fields["path"],
            program: fields["program"],
            stateDescription: fields["state"],
            pid: pid,
            lastExitCode: exitCode,
            runs: runs,
            activeCount: activeCount,
            registrationState: fields.isEmpty ? .unknown : .registered,
            loadState: loadState,
            processState: processState,
            rawFields: fields
        )
    }

    func parseDisabledOverrides(_ output: String) -> [String: Bool] {
        var result = [String: Bool]()
        for line in output.components(separatedBy: .newlines) {
            guard let separator = line.range(of: "=>") else { continue }
            let rawLabel = line[..<separator.lowerBound]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            let rawValue = line[separator.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: ";, \t"))
                .lowercased()
            guard !rawLabel.isEmpty, rawValue == "true" || rawValue == "false" else { continue }
            result[rawLabel] = rawValue == "true"
        }
        return result
    }

    func parseLegacyList(_ output: String) -> [LaunchctlListRecord] {
        output.components(separatedBy: .newlines).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3, fields[0] != "PID" else { return nil }
            let rawPID = String(fields[0])
            let pid = rawPID == "-" ? nil : Int32(rawPID)
            let exitCode = Int32(fields[1])
            let label = fields.dropFirst(2).map(String.init).joined(separator: " ")
            guard !label.isEmpty else { return nil }
            return LaunchctlListRecord(label: label, pid: pid, lastExitCode: exitCode)
        }
    }

    private func parseFields(_ output: String) -> [String: String] {
        var result = [String: String]()
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = normalizedKey(String(trimmed[..<separator]))
            var value = String(trimmed[trimmed.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if value.hasSuffix(";") { value.removeLast() }
            guard !key.isEmpty, value != "{" else { continue }
            result[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return result
    }

    private func parseServiceIdentifier(_ value: String) -> (domain: String?, label: String?) {
        guard let separator = value.lastIndex(of: "/") else { return (nil, value) }
        return (String(value[..<separator]), String(value[value.index(after: separator)...]))
    }

    private func normalizedKey(_ key: String) -> String {
        key.lowercased().filter(\.isLetter)
    }

    private func integer(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func int32(_ value: String?) -> Int32? {
        guard let value else { return nil }
        return Int32(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
