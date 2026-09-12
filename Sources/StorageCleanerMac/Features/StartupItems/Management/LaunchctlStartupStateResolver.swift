import Foundation

extension StartupItemsDomain {
    protocol StartupManagedStateResolving: Sendable {
        func resolve(label: String, userID: uid_t) async throws -> State
    }

    struct LaunchctlStartupStateResolver: StartupManagedStateResolving {
        private let runner: any StartupProcessRunning
        private let launchctlURL: URL
        private let timeout: TimeInterval

        init(
            runner: any StartupProcessRunning = CancellableStartupProcessRunner(),
            launchctlURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
            timeout: TimeInterval = 5
        ) {
            self.runner = runner
            self.launchctlURL = launchctlURL
            self.timeout = timeout
        }

        func resolve(label: String, userID: uid_t) async throws -> State {
            try Task.checkCancellation()
            let domain = "gui/\(userID)"
            let serviceTarget = "\(domain)/\(label)"
            async let serviceResult = runner.run(
                executableURL: launchctlURL,
                arguments: ["print", serviceTarget],
                timeout: timeout
            )
            async let disabledResult = runner.run(
                executableURL: launchctlURL,
                arguments: ["print-disabled", domain],
                timeout: timeout
            )
            let (service, disabled) = try await (serviceResult, disabledResult)
            try Task.checkCancellation()

            guard disabled.terminationStatus == 0 else {
                throw StartupManagementError.stateUnavailable(disabled.combinedOutput)
            }
            let isDisabled = Self.disabledValue(for: label, output: disabled.combinedOutput)
            let enablement: EnablementState = isDisabled.map { $0 ? .disabled : .enabled } ?? .unknown
            guard service.terminationStatus == 0 else {
                guard Self.isServiceNotFound(service.combinedOutput) else {
                    throw StartupManagementError.stateUnavailable(service.combinedOutput)
                }
                return State(
                    registration: .discoveredFromFile,
                    authorization: .notApplicable,
                    enablement: enablement,
                    load: .notLoaded,
                    process: .stopped,
                    management: .directlyManageable
                )
            }

            let output = service.combinedOutput
            let pid = Self.integerValue(for: "pid", output: output).flatMap(Int32.init(exactly:))
            let lastExit = Self.integerValue(for: "last exit code", output: output).flatMap(Int32.init(exactly:))
            let process: ProcessState
            if let pid {
                process = .running(pid: pid)
            } else if output.range(of: "state = waiting", options: .caseInsensitive) != nil {
                process = .waiting
            } else if let lastExit, lastExit != 0 {
                process = .failed(exitCode: lastExit)
            } else {
                process = .stopped
            }
            let onDemand = output.range(of: "state = waiting", options: .caseInsensitive) != nil
                || output.range(of: "ondemand", options: [.caseInsensitive, .diacriticInsensitive]) != nil

            return State(
                registration: .registered,
                authorization: .notApplicable,
                enablement: enablement,
                load: onDemand ? .onDemand : .loaded,
                process: process,
                management: .directlyManageable
            )
        }

        static func disabledValue(for label: String, output: String) -> Bool? {
            for line in output.split(whereSeparator: \.isNewline) {
                let text = String(line)
                guard text.contains("\"\(label)\"") else { continue }
                if text.range(of: "=> true", options: .caseInsensitive) != nil
                    || text.range(of: "=> disabled", options: .caseInsensitive) != nil {
                    return true
                }
                if text.range(of: "=> false", options: .caseInsensitive) != nil
                    || text.range(of: "=> enabled", options: .caseInsensitive) != nil {
                    return false
                }
            }
            return nil
        }

        private static func isServiceNotFound(_ output: String) -> Bool {
            let normalized = output.lowercased()
            return normalized.contains("could not find service")
                || normalized.contains("service not found")
                || normalized.contains("no such process")
        }

        private static func integerValue(for key: String, output: String) -> Int? {
            for line in output.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                guard fields.count == 2,
                      fields[0].caseInsensitiveCompare(key) == .orderedSame else { continue }
                return Int(fields[1])
            }
            return nil
        }
    }
}
