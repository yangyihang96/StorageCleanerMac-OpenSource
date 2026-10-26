import AppKit
import Foundation

/// An application as `NSWorkspace` lists it (D192: login items' run state).
struct StartupRunningApplication: Sendable, Equatable {
    let bundleURL: URL?
    let pid: Int32
}

/// Supplements filesystem discovery with runtime evidence. It intentionally
/// does not use `launchctl list` as a discovery source: disabled and unloaded
/// plist-backed services must remain visible.
struct LaunchdRuntimeScanner: StartupItemScanning {
    private let runner: any StartupCommandRunning
    private let parser: LaunchctlOutputParser
    private let executableURL: URL
    private let runningApplications: @Sendable () async -> [StartupRunningApplication]

    init(
        runner: any StartupCommandRunning = StructuredStartupCommandRunner(),
        parser: LaunchctlOutputParser = LaunchctlOutputParser(),
        executableURL: URL = URL(fileURLWithPath: "/bin/launchctl"),
        runningApplications: @escaping @Sendable () async -> [StartupRunningApplication] = LaunchdRuntimeScanner.currentApplications
    ) {
        self.runner = runner
        self.parser = parser
        self.executableURL = executableURL.standardizedFileURL
        self.runningApplications = runningApplications
    }

    let source = StartupItemsDomain.ScanSource.launchdRuntime
    let coverageIdentifier = "launchd.runtime.current-user-and-third-party-system"

    func scan(context: StartupScanContext) async throws -> [StartupItemsDomain.Candidate] {
        let labelled = context.seedCandidates.filter { $0.label?.isEmpty == false }
        // D192: an Open at Login app or a login-item helper app is not a
        // launchd job under its BTM identifier ("2.com.example.app"), so
        // asking launchctl by that label always answered "not running"
        // (10-23 test beta: all nine login items, Claude included, while
        // they ran). Such items run as applications; the application list
        // answers for them.
        var applicationResults: [StartupItemsDomain.Candidate] = []
        let applications = labelled.filter { Self.applicationBundlePath(of: $0) != nil }
        if !applications.isEmpty {
            let running = await runningApplications()
            applicationResults = applications.map { Self.applicationRuntimeCandidate(from: $0, running: running) }
        }
        let known = labelled.filter { Self.applicationBundlePath(of: $0) == nil }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path), !known.isEmpty else {
            return applicationResults
        }

        let GUI = "gui/\(context.currentUserID)"
        async let legacyListResult = runner.run(
            executable: executableURL.path,
            arguments: ["list"],
            timeout: context.commandTimeout
        )
        async let GUIDisabledResult = runner.run(
            executable: executableURL.path,
            arguments: ["print-disabled", GUI],
            timeout: context.commandTimeout
        )
        async let systemDisabledResult = runner.run(
            executable: executableURL.path,
            arguments: ["print-disabled", "system"],
            timeout: context.commandTimeout
        )

        let listResult = try? await legacyListResult
        let GUIResult = try? await GUIDisabledResult
        let systemResult = try? await systemDisabledResult
        try Task.checkCancellation()

        let records = parser.parseLegacyList(
            listResult?.terminationStatus == 0 ? listResult?.standardOutput ?? "" : ""
        )
        let recordsByLabel = Dictionary(records.map { ($0.label, $0) }, uniquingKeysWith: { first, _ in first })
        let GUIOverrides = parser.parseDisabledOverrides(
            GUIResult?.terminationStatus == 0 ? GUIResult?.standardOutput ?? "" : ""
        )
        let GUIOverrideQuerySucceeded = GUIResult?.terminationStatus == 0
        let systemOverrides = parser.parseDisabledOverrides(
            systemResult?.terminationStatus == 0 ? systemResult?.standardOutput ?? "" : ""
        )
        let systemOverrideQuerySucceeded = systemResult?.terminationStatus == 0

        let GUIKnown = known.filter {
            $0.kind != .launchDaemon && $0.kind != .systemLaunchDaemon && $0.kind != .systemLaunchAgent
        }
        var result = try await GUIRuntimeCandidates(
            GUIKnown,
            domain: GUI,
            recordsByLabel: recordsByLabel,
            disabledOverrides: GUIOverrides,
            disabledQuerySucceeded: GUIOverrideQuerySucceeded,
            context: context
        )
        result.reserveCapacity(known.count)
        for candidate in known {
            try Task.checkCancellation()
            guard let label = candidate.label else { continue }
            let isDaemon = candidate.kind == .launchDaemon || candidate.kind == .systemLaunchDaemon
            if isDaemon, candidate.kind != .systemLaunchDaemon {
                result.append(
                    try await systemRuntimeCandidate(
                        for: candidate,
                        label: label,
                        disabledOverride: systemOverrides[label],
                        disabledQuerySucceeded: systemOverrideQuerySucceeded,
                        context: context
                    )
                )
            }
            // Apple system daemons remain read-only and do not incur hundreds
            // of individual diagnostic subprocesses.
        }
        return applicationResults + result
    }

    static func currentApplications() async -> [StartupRunningApplication] {
        await MainActor.run {
            NSWorkspace.shared.runningApplications.map {
                StartupRunningApplication(bundleURL: $0.bundleURL, pid: $0.processIdentifier)
            }
        }
    }

    /// The .app an Open at Login item opens (its own URL, or the app it was
    /// attributed to), or a login item's own helper .app. nil for anything
    /// else, which keeps the launchctl lookup.
    static func applicationBundlePath(of candidate: StartupItemsDomain.Candidate) -> String? {
        let urls: [URL?]
        switch candidate.kind {
        case .openAtLogin: urls = [candidate.executableURL, candidate.applicationURL]
        case .loginItem: urls = [candidate.executableURL]
        default: return nil
        }
        return urls.compactMap { $0 }
            .first { $0.pathExtension.caseInsensitiveCompare("app") == .orderedSame }
            .map { $0.standardizedFileURL.path }
    }

    private static func applicationRuntimeCandidate(
        from candidate: StartupItemsDomain.Candidate,
        running: [StartupRunningApplication]
    ) -> StartupItemsDomain.Candidate {
        let path = applicationBundlePath(of: candidate)
        let match = running.first { $0.bundleURL?.standardizedFileURL.path == path }
        var updated = candidate
        updated.state.process = match.map { .running(pid: $0.pid) } ?? .stopped
        return StartupItemsDomain.Candidate(
            id: "runtime:\(candidate.scope.rawValue):\(candidate.label ?? candidate.id)",
            source: .launchdRuntime,
            kind: candidate.kind,
            scope: candidate.scope,
            name: candidate.name,
            label: candidate.label,
            plistURL: candidate.plistURL,
            executableURL: candidate.executableURL,
            applicationURL: candidate.applicationURL,
            configuration: candidate.configuration,
            state: updated.state,
            attribution: candidate.attribution,
            actionCapability: candidate.actionCapability,
            diagnosticEvidence: [match == nil ? "running-applications:absent" : "running-applications:present"]
        )
    }

    private func GUIRuntimeCandidates(
        _ candidates: [StartupItemsDomain.Candidate],
        domain: String,
        recordsByLabel: [String: LaunchctlListRecord],
        disabledOverrides: [String: Bool],
        disabledQuerySucceeded: Bool,
        context: StartupScanContext
    ) async throws -> [StartupItemsDomain.Candidate] {
        try await withThrowingTaskGroup(of: StartupItemsDomain.Candidate.self, returning: [StartupItemsDomain.Candidate].self) { group in
            var iterator = candidates.makeIterator()
            let limit = min(8, candidates.count)
            for _ in 0..<limit {
                guard let candidate = iterator.next() else { break }
                group.addTask { try await GUIRuntimeCandidate(candidate, domain: domain, recordsByLabel: recordsByLabel, disabledOverrides: disabledOverrides, disabledQuerySucceeded: disabledQuerySucceeded, context: context) }
            }
            var result = [StartupItemsDomain.Candidate]()
            while let candidate = try await group.next() {
                try Task.checkCancellation()
                result.append(candidate)
                if let next = iterator.next() {
                    group.addTask { try await GUIRuntimeCandidate(next, domain: domain, recordsByLabel: recordsByLabel, disabledOverrides: disabledOverrides, disabledQuerySucceeded: disabledQuerySucceeded, context: context) }
                }
            }
            return result
        }
    }

    private func GUIRuntimeCandidate(
        _ candidate: StartupItemsDomain.Candidate,
        domain: String,
        recordsByLabel: [String: LaunchctlListRecord],
        disabledOverrides: [String: Bool],
        disabledQuerySucceeded: Bool,
        context: StartupScanContext
    ) async throws -> StartupItemsDomain.Candidate {
        guard let label = candidate.label else { return candidate }
        do {
            let command = try await runner.run(
                executable: executableURL.path,
                arguments: ["print", "\(domain)/\(label)"],
                timeout: context.commandTimeout
            )
            if command.terminationStatus == 0 {
                let runtime = parser.parsePrint(command.standardOutput)
                return runtimeCandidate(
                    from: candidate,
                    loadState: runtime.loadState,
                    processState: runtime.processState,
                    disabledOverride: disabledOverrides[label],
                    disabledQuerySucceeded: disabledQuerySucceeded,
                    evidence: ["launchctl-print:\(domain)", "runs:\(runtime.runs ?? 0)"]
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return runtimeCandidate(
                from: candidate,
                loadState: .unknown,
                processState: .unknown,
                disabledOverride: disabledOverrides[label],
                disabledQuerySucceeded: disabledQuerySucceeded,
                evidence: ["launchctl-print-error:\(error.localizedDescription)"]
            )
        }
        let record = recordsByLabel[label]
        return runtimeCandidate(
            from: candidate,
            loadState: record == nil ? .notLoaded : .loaded,
            processState: record?.processState ?? .stopped,
            disabledOverride: disabledOverrides[label],
            disabledQuerySucceeded: disabledQuerySucceeded,
            evidence: record == nil ? ["launchctl-print:not-loaded"] : ["launchctl-list:fallback-loaded"]
        )
    }

    private func systemRuntimeCandidate(
        for candidate: StartupItemsDomain.Candidate,
        label: String,
        disabledOverride: Bool?,
        disabledQuerySucceeded: Bool,
        context: StartupScanContext
    ) async throws -> StartupItemsDomain.Candidate {
        do {
            let command = try await runner.run(
                executable: executableURL.path,
                arguments: ["print", "system/\(label)"],
                timeout: context.commandTimeout
            )
            if command.terminationStatus == 0 {
                let runtime = parser.parsePrint(command.standardOutput)
                return runtimeCandidate(
                    from: candidate,
                    loadState: runtime.loadState,
                    processState: runtime.processState,
                    disabledOverride: disabledOverride,
                    disabledQuerySucceeded: disabledQuerySucceeded,
                    evidence: ["launchctl-print:system", "runs:\(runtime.runs ?? 0)"]
                )
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return runtimeCandidate(
                from: candidate,
                loadState: .unknown,
                processState: .unknown,
                disabledOverride: disabledOverride,
                disabledQuerySucceeded: disabledQuerySucceeded,
                evidence: ["launchctl-print-error:\(error.localizedDescription)"]
            )
        }
        return runtimeCandidate(
            from: candidate,
            loadState: .notLoaded,
            processState: .stopped,
            disabledOverride: disabledOverride,
            disabledQuerySucceeded: disabledQuerySucceeded,
            evidence: ["launchctl-print:not-loaded"]
        )
    }

    private func runtimeCandidate(
        from candidate: StartupItemsDomain.Candidate,
        loadState: StartupItemsDomain.LoadState,
        processState: StartupItemsDomain.ProcessState,
        disabledOverride: Bool?,
        disabledQuerySucceeded: Bool,
        evidence: [String]
    ) -> StartupItemsDomain.Candidate {
        var updatedState = candidate.state
        updatedState.registration = loadState == .notLoaded ? candidate.state.registration : .registered
        updatedState.load = loadState
        updatedState.process = processState
        if let disabledOverride {
            updatedState.enablement = disabledOverride ? .disabled : .enabled
        } else if disabledQuerySucceeded {
            // `print-disabled` reports overrides. When there is no override,
            // retain an explicit Disabled=true from the plist; otherwise the
            // launchd default is enabled.
            updatedState.enablement = candidate.configuration?.disabled == true ? .disabled : .enabled
        }

        return StartupItemsDomain.Candidate(
            id: "runtime:\(candidate.scope.rawValue):\(candidate.label ?? candidate.id)",
            source: .launchdRuntime,
            kind: candidate.kind,
            scope: candidate.scope,
            name: candidate.name,
            label: candidate.label,
            plistURL: candidate.plistURL,
            executableURL: candidate.executableURL,
            applicationURL: candidate.applicationURL,
            configuration: candidate.configuration,
            state: updatedState,
            attribution: candidate.attribution,
            actionCapability: candidate.actionCapability,
            diagnosticEvidence: evidence
        )
    }
}
