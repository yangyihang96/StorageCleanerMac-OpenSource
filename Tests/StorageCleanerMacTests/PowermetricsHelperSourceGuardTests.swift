import FanControlShared
import Foundation
import XCTest
@testable import StorageCleanerMac

/// Text guard over every file under Sources/FanControlHelper and
/// Sources/FanControlShared (recursive, any extension). The privileged helper may
/// create exactly two kinds of child process: the original whitelisted pmset
/// (Foundation Process) and the one constant powermetrics command (posix_spawn).
/// A text guard cannot prove the absence of every dynamic alias, so independent
/// code review is still required; it does lock every known spelling.
final class PowermetricsHelperSourceGuardTests: XCTestCase {
    func testEveryHelperProcessIsAnAllowedFixedCommand() throws {
        let sources = try helperSources()
        XCTAssertTrue(try permits(sources))
        XCTAssertGreaterThanOrEqual(sources.count, 5, "the scan must cover the whole helper and shared sources")
        let main = try XCTUnwrap(sources["FanControlHelper/main.swift"])
        let runner = try XCTUnwrap(sources["FanControlHelper/PowermetricsProcessRunner.swift"])
        XCTAssertTrue(main.contains("HelperPMSetWhitelist.permits(arguments)"))
        XCTAssertTrue(runner.contains("O_NONBLOCK"))
        XCTAssertTrue(runner.contains("guard !isStopping"))
        let termination = try MiniWindowLogicFixtures.section(main, from: "private func startTerminationHandlers", to: "private func readPowerConfiguration")
        XCTAssertTrue(termination.contains("self.powerSamplingRunner.stopForTermination()"))
        XCTAssertFalse(runner.contains("readDataToEndOfFile"))
        XCTAssertFalse(runner.contains("waitUntilExit"))
        let telemetry = try MiniWindowLogicFixtures.source("Sources/StorageCleanerMac/Services/SoCPowerTelemetry.swift")
        XCTAssertTrue(telemetry.contains("if #available(macOS 26, *) { return .unsupported }"))
    }

    /// The child runs in its own process group and is reaped only by the runner;
    /// SIGKILL goes to the group only while the child is known to be unreaped.
    func testChildIsSpawnedInOwnGroupAndKilledOnlyBeforeItsOwnReap() throws {
        let runner = try MiniWindowLogicFixtures.source("Sources/FanControlHelper/PowermetricsProcessRunner.swift")
        for needle in ["POSIX_SPAWN_SETPGROUP", "posix_spawnattr_setpgroup(&attributes, 0) == 0", "POSIX_SPAWN_CLOEXEC_DEFAULT",
                       "POSIX_SPAWN_SETSIGDEF", "waitpid(pid, &status, WNOHANG)"] {
            XCTAssertTrue(runner.contains(needle), needle)
        }
        // Every kill targets the negative pgid and sits under childLock behind an
        // `activeChild` check; reaping clears `activeChild` under the same lock.
        let kills = runner.components(separatedBy: "Darwin.kill(").dropFirst()
        XCTAssertEqual(kills.count, 2)
        XCTAssertTrue(kills.allSatisfy { $0.hasPrefix("-pid, SIGKILL)") })
        let stop = try MiniWindowLogicFixtures.section(runner, from: "func stopForTermination()", to: "/// Non-blocking reap")
        XCTAssertTrue(stop.contains("childLock.withLock") && stop.contains("if let pid = activeChild { _ = Darwin.kill(-pid, SIGKILL) }"))
        let killer = try MiniWindowLogicFixtures.section(runner, from: "private func killGroupIfUnreaped", to: "func sample()")
        XCTAssertTrue(killer.contains("childLock.withLock") && killer.contains("if activeChild == pid { _ = Darwin.kill(-pid, SIGKILL) }"))
        let reaper = try MiniWindowLogicFixtures.section(runner, from: "private func reapIfExited", to: "/// Kills the whole group")
        XCTAssertTrue(reaper.contains("childLock.withLock") && reaper.contains("guard activeChild == pid") && reaper.contains("activeChild = nil"))
        XCTAssertEqual(runner.components(separatedBy: "waitpid(").count - 1, 1, "only the guarded reaper waits")
        XCTAssertFalse(runner.contains("waitpid(-1"))
        XCTAssertFalse(runner.contains("processIdentifier"), "no Foundation Process pid is killed")
        let spawn = try MiniWindowLogicFixtures.section(runner, from: "let spawnStatus: Int32 = childLock.withLock {", to: "if spawnStatus == ECANCELED")
        XCTAssertTrue(spawn.contains("guard !isStopping else { return ECANCELED }"))
        XCTAssertTrue(spawn.contains("if status == 0 { activeChild = spawnedPID }"))
        XCTAssertTrue(runner.contains("if let previous = childLock.withLock({ activeChild }) {\n            guard reapIfExited(previous) != nil else { return .failure(.busy) }"))
        XCTAssertTrue(runner.contains("if stdoutEOF && stderrEOF && waitStatus == nil { waitStatus = reapIfExited(pid) }"),
                      "keep the group leader unreaped while descendants can hold pipe writers")
    }

    func testExitStatusDecoding() {
        XCTAssertEqual(PowermetricsWaitStatus.exitCode(0), 0)
        XCTAssertEqual(PowermetricsWaitStatus.exitCode(1 << 8), 1)
        XCTAssertEqual(PowermetricsWaitStatus.exitCode(Int32(SIGKILL)), 128 + SIGKILL)
        XCTAssertNotEqual(PowermetricsWaitStatus.exitCode(-1), 0)
    }

    func testGuardRejectsEveryProcessCreationSpellingAndParameterChange() throws {
        let sources = try helperSources()
        XCTAssertTrue(try permits(sources))
        let runnerPath = "FanControlHelper/PowermetricsProcessRunner.swift", mainPath = "FanControlHelper/main.swift"
        // Injected anywhere in the helper/shared sources, including a new file in a subdirectory.
        let injected = [
            "let injected = Process()", "let p: Process = .init()", "let p: Foundation.Process = .init()",
            "let p = Process.init()", "try Process.run(url, arguments: [])", "try Process . run(url, arguments: [])",
            "let t = NSTask()", "let t = NSUserUnixTask(url: url)", "NSAppleScript(source: s)",
            "posix_spawn(&pid, \"/bin/sh\", nil, nil, nil, nil)", "posix_spawnp(&pid, \"sh\", nil, nil, argv, nil)",
            "let launch = posix_spawn",
            "__posix_spawn(&pid, path, nil, nil, argv, nil)", "execv(\"/bin/sh\", argv)", "execve(path, argv, envp)",
            "execl(\"/bin/sh\", \"sh\", nil)", "execvp(\"sh\", argv)", "fexecve(fd, argv, envp)", "let child = fork()",
            "let child = vfork()", "system(\"/bin/sh\")", "popen(\"/bin/sh\", \"r\")", "dlsym(handle, \"posix_spawn\")",
            "dlopen(path, RTLD_NOW)", "NSClassFromString(name)", "setenv(\"DYLD_INSERT_LIBRARIES\", p, 1)",
            "putenv(entry)", "syscall(SYS_execve)", "NSWorkspace.shared.openApplication(at: url, configuration: c)",
        ]
        for snippet in injected {
            for path in [mainPath, runnerPath, "FanControlShared/PowermetricsSample.swift", "FanControlHelper/Sub/Injected.swift"] {
                var changed = sources
                changed[path] = (sources[path] ?? "") + "\nfunc injectedBypass() { \(snippet) }\n"
                XCTAssertFalse(try permits(changed), "\(path): \(snippet)")
            }
        }
        // Changes to the one allowed powermetrics launch.
        for (needle, replacement) in [
            ("static let executablePath = \"/usr/bin/powermetrics\"", "static let executablePath = \"/bin/sh\""),
            ("\"-i\", \"1000\"", "\"-i\", \"500\""),
            ("\"-n\", \"1\"", "\"-n\", \"0\""),
            ("\"PATH=/usr/bin:/bin:/usr/sbin:/sbin\"]", "\"PATH=/usr/bin:/bin:/usr/sbin:/sbin\", \"DYLD_INSERT_LIBRARIES=/tmp/x\"]"),
            ("static let arguments = [", "static var arguments = ["),
            (".map { strdup($0) } + [nil]\n        let environmentVector", ".map { strdup($0) } + [strdup(\"--show-process-energy\"), nil]\n        let environmentVector"),
            ("let environmentVector: [UnsafeMutablePointer<CChar>?] = Self.environment.map { strdup($0) } + [nil]",
             "let environmentVector: [UnsafeMutablePointer<CChar>?] = ProcessInfo.processInfo.environment.map { strdup($0.key + \"=\" + $0.value) } + [nil]"),
            ("posix_spawn(&spawnedPID, Self.executablePath,", "posix_spawn(&spawnedPID, \"/bin/sh\","),
            ("argumentVector, environmentVector)", "argumentVector, nil)"),
            ("posix_spawn_file_actions_addchdir_np(&actions, \"/\") == 0 else {",
             "posix_spawn_file_actions_addchdir_np(&actions, \"/\") == 0,\n              posix_spawn_file_actions_addopen(&actions, 3, \"/etc/sudoers\", O_RDONLY, 0) == 0 else {"),
        ] {
            var changed = sources
            changed[runnerPath] = sources[runnerPath]?.replacingOccurrences(of: needle, with: replacement)
            XCTAssertNotEqual(changed[runnerPath], sources[runnerPath], needle)
            XCTAssertFalse(try permits(changed), needle)
        }
        // pmset: whitelist bypass, same-line suffixes and environment changes.
        for (needle, replacement) in [
            ("HelperPMSetWhitelist.permits(arguments)", "true"),
            ("process.arguments = arguments\n", "process.arguments = arguments + [\"-a\", \"sleep\", \"0\"]\n"),
            ("URL(fileURLWithPath: \"/usr/bin/pmset\")\n", "URL(fileURLWithPath: \"/usr/bin/pmset\").deletingLastPathComponent().appendingPathComponent(\"sh\")\n"),
            ("            \"LANG\": \"C\",\n", "            \"LANG\": \"C\",\n            \"DYLD_INSERT_LIBRARIES\": \"/tmp/x\",\n"),
            ("process.environment = [", "process.environment = ProcessInfo.processInfo.environment; process.environment = ["),
            ("        process.standardOutput = outputPipe", "        process.environment?[\"DYLD_INSERT_LIBRARIES\"] = \"/tmp/x\"\n        process.standardOutput = outputPipe"),
            ("        ]\n        process.standardOutput = outputPipe", "        ].merging(ProcessInfo.processInfo.environment) { _, inherited in inherited }\n        process.standardOutput = outputPipe"),
        ] {
            var changed = sources
            changed[mainPath] = sources[mainPath]?.replacingOccurrences(of: needle, with: replacement)
            XCTAssertNotEqual(changed[mainPath], sources[mainPath], needle)
            XCTAssertFalse(try permits(changed), needle)
        }
    }

    func testSamplingCannotBypassAuthenticationOrReachControlQueues() throws {
        let main = try MiniWindowLogicFixtures.source("Sources/FanControlHelper/main.swift")
        let sampling = try MiniWindowLogicFixtures.section(main, from: "private func executePowerSample", to: "private func handle(")
        XCTAssertTrue(main.contains("try CodeSigningCheck.clientMatchesHelper(auditToken: token, helperIdentity: startupIdentity.signing)"))
        XCTAssertTrue(sampling.contains("NSXPCConnection.current()"))
        XCTAssertTrue(sampling.contains("CodeSigningCheck.powerSamplingClientIdentityMatches(auditToken: token)"))
        XCTAssertTrue(sampling.contains("CodeSigningCheck.powerSamplingClientSealIsValid(auditToken: token)"))
        XCTAssertTrue(sampling.contains("PowermetricsSamplingRequest.decode(data)"))
        XCTAssertFalse(sampling.contains("runPMSet("))
        XCTAssertFalse(sampling.contains("smcQueue"))
        XCTAssertFalse(sampling.contains("commandQueue.sync"))
        let cheap = try MiniWindowLogicFixtures.section(main, from: "static func powerSamplingClientIdentityMatches", to: "static func powerSamplingClientSealIsValid")
        XCTAssertTrue(cheap.contains("SecCodeCheckValidity(code, [], nil)"))
        XCTAssertTrue(cheap.contains("PowermetricsClientPolicy.permits("))
        XCTAssertFalse(cheap.contains("SecStaticCodeCheckValidity"), "the per-request check stays cheap")
        let seal = try MiniWindowLogicFixtures.section(main, from: "static func powerSamplingClientSealIsValid", to: "static func macMiniExpectedIdentity")
        XCTAssertTrue(seal.contains("SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckNestedCode), nil)"))
        XCTAssertFalse(seal.contains("kSecCSDoNotValidateResources"))
        let guest = try MiniWindowLogicFixtures.section(main, from: "private static func powerSamplingGuestCode", to: "/// Cheap")
        XCTAssertTrue(guest.contains("kSecGuestAttributeAudit"))
        let policy = try MiniWindowLogicFixtures.source("Sources/FanControlShared/PowermetricsSample.swift")
        XCTAssertTrue(policy.contains("T9GZL52H8R"))
        XCTAssertTrue(policy.contains("resolvingSymlinksInPath()"))
    }

    /// Order on the XPC delivery thread: decode, current(), cheap per-connection
    /// interval, readiness, admission, then hop to the verification queue. Signing
    /// work happens only after the hop, and execution only after authorization.
    func testCallerVerificationPrecedesTheOnlySamplingEntryAndReplyIsStructured() throws {
        let sources = try helperSources()
        let main = try XCTUnwrap(sources["FanControlHelper/main.swift"])
        let runner = try XCTUnwrap(sources["FanControlHelper/PowermetricsProcessRunner.swift"])
        XCTAssertEqual(main.components(separatedBy: "powerSampling.request(").count - 1, 1)
        XCTAssertEqual(main.components(separatedBy: "executePowerSample(").count - 1, 2, "one definition, one route")
        let sampling = try MiniWindowLogicFixtures.section(main, from: "private func executePowerSample", to: "private func handle(")
        let ordered = ["PowermetricsSamplingRequest.decode(data)",
                       "NSXPCConnection.current()",
                       "powerSamplingClients.admitAttempt(connection: connectionID,",
                       "startupSafety.isReady",
                       "pendingPowerSamples < PowermetricsSamplingCoordinator.maximumWaiters",
                       "powerSamplingVerificationQueue.async {",
                       "let authorized = powerSamplingClients.authorize(",
                       "cheapCheck: { try CodeSigningCheck.powerSamplingClientIdentityMatches(auditToken: token) }",
                       "sealCheck: { try CodeSigningCheck.powerSamplingClientSealIsValid(auditToken: token) }",
                       "powerSampling.request(authorized: authorized)"]
        let offsets = try ordered.map { needle in
            try XCTUnwrap(sampling.range(of: needle), needle).lowerBound
        }
        XCTAssertEqual(offsets, offsets.sorted(), "verification must precede admission and execution")
        let synchronous = try MiniWindowLogicFixtures.section(main, from: "private func executePowerSample", to: "powerSamplingVerificationQueue.async {")
        for expensive in ["CodeSigningCheck.powerSampling", "SecStaticCode", "SecCode", ".authorize("] {
            XCTAssertFalse(synchronous.contains(expensive), "no signing work on the XPC delivery thread: \(expensive)")
        }
        let invalidation = try MiniWindowLogicFixtures.section(main, from: "newConnection.invalidationHandler = {", to: "let admitted = smcQueue.sync")
        XCTAssertTrue(invalidation.contains("powerSamplingClients.forget(connection: ObjectIdentifier(newConnection))"))
        let listener = try MiniWindowLogicFixtures.section(main, from: "func listener(", to: "func execute(")
        XCTAssertTrue(listener.contains("powerSamplingClients.register(connection: ObjectIdentifier(newConnection))"))
        XCTAssertTrue(sampling.contains("admission: admission, process: client"), "capture the connection lifetime before asynchronous checks")
        for forbidden in ["\\(", "stderr", "standardError", "macMiniRuntime", "childLock", "MacMiniPolicy",
                          "fanCurve", "restoreAllFans", "runPMSet(", "smcQueue", "commandQueue.sync"] {
            XCTAssertFalse(sampling.contains(forbidden), forbidden)
        }
        XCTAssertFalse(main.contains("childLock"), "the child lock is private to the sampling runner")
        XCTAssertFalse(main.contains(".sample()"), "the runner is reachable only through the coordinator")
        XCTAssertEqual(runner.components(separatedBy: "runner.sample()").count - 1, 1)
        let maker = try MiniWindowLogicFixtures.section(runner, from: "func makeCoordinator()", to: "func stopForTermination()")
        XCTAssertTrue(maker.contains("PowermetricsSamplingCoordinator {"))
        XCTAssertTrue(maker.contains("runner.sample()"))
        XCTAssertFalse(runner.contains("output.append("), "the privileged adapter keeps no output buffer")
        let policy = try XCTUnwrap(sources["FanControlShared/PowermetricsSampling.swift"])
        XCTAssertEqual(policy.components(separatedBy: "output.append(").count - 1, 1)
        XCTAssertTrue(policy.contains("output.append(chunk.stdout)"), "stderr is counted, never kept or returned")
    }

    // MARK: - Guard implementation

    private func helperSources() throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var result: [String: String] = [:]
        for folder in ["FanControlHelper", "FanControlShared"] {
            let base = root.appendingPathComponent("Sources/" + folder)
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]))
            for case let url as URL in enumerator where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let relative = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
                result[folder + "/" + relative] = try String(contentsOf: url, encoding: .utf8)
            }
        }
        return result
    }

    private static let allowedSpawnIdentifiers: Set<String> = [
        "posix_spawn", "posix_spawn_file_actions_t", "posix_spawnattr_t",
        "posix_spawn_file_actions_init", "posix_spawn_file_actions_destroy", "posix_spawn_file_actions_addopen",
        "posix_spawn_file_actions_adddup2", "posix_spawn_file_actions_addchdir_np",
        "posix_spawnattr_init", "posix_spawnattr_destroy", "posix_spawnattr_setflags", "posix_spawnattr_setpgroup",
        "posix_spawnattr_setsigdefault", "posix_spawnattr_setsigmask",
    ]

    private func permits(_ sources: [String: String]) throws -> Bool {
        func regex(_ pattern: String) throws -> NSRegularExpression { try NSRegularExpression(pattern: pattern) }
        func matches(_ expression: NSRegularExpression, _ source: String) -> [String] {
            expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap {
                Range($0.range, in: source).map { String(source[$0]) }
            }
        }
        func exactLines(_ source: String, _ line: String) -> Int {
            source.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { $0.trimmingCharacters(in: .whitespaces) == line }.count
        }
        let forbidden = try [
            #"\bf?exec[lvp]\w*\s*\("#, #"\bv?fork\s*\("#, #"\bvfork\b"#, #"\bNSTask\b"#, #"\bNSUserUnixTask\b"#,
            #"\bNSUserScriptTask\b"#, #"\bNSAppleScript\b"#, #"\bOSAScript\b"#, #"\bsystem\s*\("#, #"\bpopen\s*\("#,
            #"\bProcess\s*\.\s*run\s*\("#, #"\bProcess\s*\.\s*init\b"#, #":\s*(?:Foundation\.)?Process\s*=\s*\.init"#, #"\bdlsym\s*\("#, #"\bdlopen\s*\("#,
            #"\bNSClassFromString\b"#, #"\bsetenv\s*\("#, #"\bputenv\s*\("#, #"\bsyscall\s*\("#, #"\bNSWorkspace\b"#,
            #"\bposix_spawnp\b"#,
        ].map(regex)
        let spawnIdentifier = try regex(#"\w*posix_spawn\w*"#)
        let spawnCall = try regex(#"\bposix_spawn\s*\("#)
        let spawnReference = try regex(#"\bposix_spawn\b"#)
        let processCall = try regex(#"\bProcess\s*\("#)
        let processEnvironment = try regex(#"\bprocess\s*\.\s*environment\b"#)
        let mainPath = "FanControlHelper/main.swift", runnerPath = "FanControlHelper/PowermetricsProcessRunner.swift"
        var processSites: [String: Int] = [:], spawnSites: [String: Int] = [:]
        for (path, source) in sources {
            if forbidden.contains(where: { !matches($0, source).isEmpty }) { return false }
            let identifiers = matches(spawnIdentifier, source)
            if !identifiers.isEmpty && (path != runnerPath || !Set(identifiers).isSubset(of: Self.allowedSpawnIdentifiers)) { return false }
            let processes = matches(processCall, source).count, spawns = matches(spawnCall, source).count
            if processes > 0 { processSites[path] = processes }
            if spawns > 0 { spawnSites[path] = spawns }
            if source.components(separatedBy: "process.executableURL").count - 1 > 1
                || source.components(separatedBy: "process.arguments").count - 1 > 1
                || matches(processEnvironment, source).count != (path == mainPath ? 1 : 0)
                || source.components(separatedBy: ".environment = ").count - 1 > (path == mainPath ? 1 : 0) { return false }
        }
        guard processSites == [mainPath: 1], spawnSites == [runnerPath: 1],
              let main = sources[mainPath], let runner = sources[runnerPath] else { return false }
        let runnerCode = runner.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
        }.joined(separator: "\n")
        guard matches(spawnReference, runnerCode).count == 1 else { return false }

        // pmset: the original whitelist, checked before the one Process(), fixed path/arguments/environment.
        let pmset = try MiniWindowLogicFixtures.section(main, from: "private func runPMSet", to: "private func ")
        guard let guardIndex = pmset.range(of: "guard HelperPMSetWhitelist.permits(arguments) else {"),
              let launch = pmset.range(of: "let process = Process()\n"), guardIndex.lowerBound < launch.lowerBound,
              exactLines(main, "let process = Process()") == 1,
              exactLines(main, "process.executableURL = URL(fileURLWithPath: \"/usr/bin/pmset\")") == 1,
              exactLines(main, "process.arguments = arguments") == 1,
              main.components(separatedBy: "process.environment = [\n            \"LANG\": \"C\",\n            \"PATH\": \"/usr/bin:/bin:/usr/sbin:/sbin\",\n        ]\n").count == 2
        else { return false }

        // powermetrics: constant path, arguments and environment; one spawn call
        // whose vectors are built only from those constants; stdin is /dev/null.
        return exactLines(runner, "static let executablePath = \"/usr/bin/powermetrics\"") == 1
            && exactLines(runner, "static let arguments = [\"--samplers\", \"cpu_power,gpu_power,ane_power\", \"-n\", \"1\", \"-i\", \"1000\", \"-f\", \"plist\"]") == 1
            && exactLines(runner, "static let environment = [\"LANG=C\", \"LC_ALL=C\", \"PATH=/usr/bin:/bin:/usr/sbin:/sbin\"]") == 1
            && exactLines(runner, "let argumentVector: [UnsafeMutablePointer<CChar>?] = ([Self.executablePath] + Self.arguments).map { strdup($0) } + [nil]") == 1
            && exactLines(runner, "let environmentVector: [UnsafeMutablePointer<CChar>?] = Self.environment.map { strdup($0) } + [nil]") == 1
            && exactLines(runner, "let status = posix_spawn(&spawnedPID, Self.executablePath, &actions, &attributes,") == 1
            && exactLines(runner, "argumentVector, environmentVector)") == 1
            && runner.components(separatedBy: "argumentVector").count - 1 == 4
            && runner.components(separatedBy: "environmentVector").count - 1 == 4
            && runner.components(separatedBy: "posix_spawn_file_actions_addopen(").count - 1 == 1
            && runner.contains("posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, \"/dev/null\", O_RDONLY, 0) == 0,")
            && runner.components(separatedBy: "posix_spawn_file_actions_adddup2(").count - 1 == 2
            && runner.contains("posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO) == 0,")
            && runner.contains("posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO) == 0,")
    }
}
