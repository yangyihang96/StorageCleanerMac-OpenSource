import Foundation

enum HomebrewApplicationMatchConfidence: String, Sendable {
    case exactArtifactPath
    case uniqueNameFallback
}

struct HomebrewApplicationMatch: Sendable {
    let package: HomebrewInventoryPackage
    let confidence: HomebrewApplicationMatchConfidence
}

struct HomebrewInventoryPackage: Hashable, Sendable {
    let metadata: HomebrewPackageMetadata
    let displayNames: [String]
    let exactApplicationPaths: Set<String>
}

struct HomebrewInventory: Sendable {
    let executableURL: URL
    let prefixURL: URL
    let packages: [HomebrewInventoryPackage]

    var formulae: [HomebrewInventoryPackage] {
        packages.filter { $0.metadata.kind == .formula }
    }

    var casks: [HomebrewInventoryPackage] {
        packages.filter { $0.metadata.kind == .cask }
    }

    func match(application: InstalledApplication) -> HomebrewApplicationMatch? {
        let normalizedPath = ApplicationPathNormalizer.comparisonKey(for: application.bundleURL)
        let resolvedPath = ApplicationPathNormalizer.comparisonKey(
            for: application.bundleURL.resolvingSymlinksInPath()
        )
        if let exact = casks.first(where: {
            $0.exactApplicationPaths.contains(normalizedPath)
                || $0.exactApplicationPaths.contains(resolvedPath)
        }) {
            return HomebrewApplicationMatch(package: exact, confidence: .exactArtifactPath)
        }

        let normalizedNames = Set([
            Self.normalizedName(application.displayName),
            Self.normalizedName(application.bundleURL.deletingPathExtension().lastPathComponent),
        ].filter { !$0.isEmpty })
        let candidates = casks.filter { package in
            let names = package.displayNames
                + [package.metadata.token]
                + package.metadata.appBundlePaths.map {
                    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                }
            return names.contains { normalizedNames.contains(Self.normalizedName($0)) }
        }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        return HomebrewApplicationMatch(package: candidate, confidence: .uniqueNameFallback)
    }

    private static func normalizedName(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter(CharacterSet.alphanumerics.contains)
            .map(String.init)
            .joined()
    }
}

enum HomebrewCommandEnvironment {
    static let allowedKeys: Set<String> = [
        "HOME",
        "HOMEBREW_NO_ANALYTICS",
        "HOMEBREW_NO_AUTO_UPDATE",
        "HOMEBREW_NO_ENV_HINTS",
        "HOMEBREW_NO_INSTALL_CLEANUP",
        "LANG",
        "LC_ALL",
        "LOGNAME",
        "PATH",
        "TMPDIR",
        "USER",
        "NONINTERACTIVE",
    ]

    static func allowlist(
        executableURL: URL,
        environment: [String: String]
    ) -> [String: String] {
        let prefix = executableURL.deletingLastPathComponent().deletingLastPathComponent()
        let pathEntries = [
            executableURL.deletingLastPathComponent().path,
            prefix.appendingPathComponent("sbin", isDirectory: true).path,
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "/usr/local/bin",
        ]
        var allowlist: [String: String] = [
            "HOME": environment["HOME"]?.trimmed.nonEmpty
                ?? FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": environment["TMPDIR"]?.trimmed.nonEmpty
                ?? FileManager.default.temporaryDirectory.path,
            "PATH": Array(NSOrderedSet(array: pathEntries))
                .compactMap { $0 as? String }
                .joined(separator: ":"),
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "NONINTERACTIVE": "1",
        ]
        for key in ["USER", "LOGNAME", "LANG", "LC_ALL"] {
            if let value = environment[key]?.trimmed.nonEmpty {
                allowlist[key] = value
            }
        }
        return allowlist
    }
}

protocol HomebrewCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Data
}

struct ShellHomebrewCommandRunner: HomebrewCommandRunning {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async throws -> Data {
        let cancellation = HomebrewCommandCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                let output = try Shell.captureCancellable(
                    executableURL.path,
                    arguments,
                    environment: environment,
                    timeout: timeout,
                    outputByteLimit: 8 * 1_024 * 1_024,
                    cancellationCheck: { cancellation.isCancelled }
                )
                return Data(output.utf8)
            }.value
        } onCancel: {
            cancellation.cancel()
        }
    }
}

final class HomebrewCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock { cancelled = true }
    }
}

struct HomebrewInventoryScanner: Sendable {
    private let runner: any HomebrewCommandRunning
    private let fileManagerFactory: @Sendable () -> FileManager
    private let environmentProvider: @Sendable () -> [String: String]

    init(
        runner: any HomebrewCommandRunning = ShellHomebrewCommandRunner(),
        fileManagerFactory: @escaping @Sendable () -> FileManager = { FileManager() },
        environmentProvider: @escaping @Sendable () -> [String: String] = {
            ProcessInfo.processInfo.environment
        }
    ) {
        self.runner = runner
        self.fileManagerFactory = fileManagerFactory
        self.environmentProvider = environmentProvider
    }

    /// Scans the normal inventory without Homebrew's `--greedy` opt-in. The
    /// latter includes casks whose own updater is responsible for releases and
    /// must only be requested by an explicit caller.
    func scan(includeGreedyCasks: Bool = false) async throws -> HomebrewInventory? {
        let processEnvironment = environmentProvider()
        guard let executableURL = locateHomebrewExecutable(environment: processEnvironment) else {
            return nil
        }
        let commandEnvironment = HomebrewCommandEnvironment.allowlist(
            executableURL: executableURL,
            environment: processEnvironment
        )
        // Homebrew commands share locks and may start short-lived helper
        // processes. Running two CLI instances concurrently can leave either
        // command waiting long enough for the strict process-tree timeout to
        // fire, even though each command completes quickly on its own. Keep
        // inventory discovery serial and deterministic.
        let prefixData = try await runner.run(
            executableURL: executableURL,
            arguments: ["--prefix"],
            environment: commandEnvironment,
            timeout: 10
        )
        let infoData = try await runner.run(
            executableURL: executableURL,
            arguments: ["info", "--json=v2", "--installed"],
            environment: commandEnvironment,
            timeout: 45
        )
        let prefixString = String(decoding: prefixData, as: UTF8.self).trimmed
        guard !prefixString.isEmpty else {
            throw ApplicationScanningError.invalidHomebrewOutput("brew --prefix")
        }

        // The normal query is the only source allowed to authorize automatic
        // updates. If the user opts into self-updating cask discovery, retain a
        // second greedy result solely so those items can be shown for manual
        // review without losing which query produced the match.
        let outdatedData = try await optionalOutdatedData(
            executableURL: executableURL,
            arguments: ["outdated", "--json=v2"],
            environment: commandEnvironment
        )
        let greedyOutdatedData = includeGreedyCasks
            ? try await optionalOutdatedData(
                executableURL: executableURL,
                arguments: ["outdated", "--json=v2", "--greedy"],
                environment: commandEnvironment
            )
            : nil

        let packages = try HomebrewInventoryParser.parse(
            installedData: infoData,
            outdatedData: outdatedData,
            greedyOutdatedData: greedyOutdatedData,
            prefixURL: URL(fileURLWithPath: prefixString, isDirectory: true)
        )
        return HomebrewInventory(
            executableURL: executableURL,
            prefixURL: URL(fileURLWithPath: prefixString, isDirectory: true),
            packages: packages
        )
    }

    private func optionalOutdatedData(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]
    ) async throws -> Data? {
        do {
            return try await runner.run(
                executableURL: executableURL,
                arguments: arguments,
                environment: environment,
                timeout: 60
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Re-reads one installed Formula after an update without enumerating the
    /// user's entire Homebrew inventory. Arguments are passed directly to
    /// `Process`; no shell parsing or command interpolation is involved.
    func installedFormulaVersion(
        token: String,
        environment: [String: String]? = nil
    ) async throws -> ApplicationVersion? {
        guard HomebrewPackageTokenPolicy.isValid(token) else {
            throw ApplicationScanningError.invalidHomebrewOutput("invalid formula token")
        }
        let processEnvironment = environment ?? environmentProvider()
        guard let executableURL = locateHomebrewExecutable(environment: processEnvironment) else {
            return nil
        }
        let commandEnvironment = HomebrewCommandEnvironment.allowlist(
            executableURL: executableURL,
            environment: processEnvironment
        )
        let data = try await runner.run(
            executableURL: executableURL,
            arguments: ["info", "--json=v2", "--formula", token],
            environment: commandEnvironment,
            timeout: 20
        )
        return try HomebrewInventoryParser.installedFormulaVersion(
            from: data,
            expectedToken: token
        )
    }

    func locateHomebrewExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        var candidates = [URL]()
        let declaredPrefix = environment["HOMEBREW_PREFIX"]?.trimmed.nonEmpty.map {
            URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL
        }
        if let declaredPrefix {
            let prefixExecutable = declaredPrefix.appendingPathComponent("bin/brew", isDirectory: false)
            if let explicit = environment["HOMEBREW_BREW_FILE"]?.trimmed.nonEmpty {
                let explicitURL = URL(fileURLWithPath: explicit).standardizedFileURL
                if explicitURL == prefixExecutable.standardizedFileURL {
                    candidates.append(explicitURL)
                }
            } else {
                candidates.append(prefixExecutable)
            }
        }
        candidates.append(contentsOf: [
            URL(fileURLWithPath: "/opt/homebrew/bin/brew"),
            URL(fileURLWithPath: "/usr/local/bin/brew"),
            URL(fileURLWithPath: "/home/linuxbrew/.linuxbrew/bin/brew"),
        ])

        let fileManager = fileManagerFactory()
        var seen = Set<String>()
        return candidates.first { candidate in
            let path = candidate.standardizedFileURL.path
            guard seen.insert(path).inserted else { return false }
            return HomebrewExecutableTrustPolicy.isTrusted(
                candidate,
                declaredPrefix: declaredPrefix,
                fileManager: fileManager
            )
        }
    }
}

enum HomebrewPackageTokenPolicy {
    static func isValid(_ rawToken: String) -> Bool {
        let token = rawToken.trimmed
        guard !token.isEmpty,
              token == rawToken,
              token.count <= 200,
              !token.hasPrefix("-"),
              !token.contains(".."),
              !token.contains("//") else {
            return false
        }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@+_./-"
        )
        return token.unicodeScalars.allSatisfy(allowed.contains)
            && token.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty }
    }
}

enum HomebrewExecutableTrustPolicy {
    private static let standardPaths: Set<String> = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
        "/home/linuxbrew/.linuxbrew/bin/brew",
    ]

    static func isTrusted(
        _ executableURL: URL,
        declaredPrefix: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        let executable = executableURL.standardizedFileURL
        guard executable.path.hasPrefix("/"),
              executable.lastPathComponent == "brew",
              executable.deletingLastPathComponent().lastPathComponent == "bin",
              fileManager.isExecutableFile(atPath: executable.path) else {
            return false
        }

        let isStandard = standardPaths.contains(executable.path)
        let isDeclaredCustom: Bool
        if let declaredPrefix {
            let prefix = declaredPrefix.standardizedFileURL
            let expected = prefix.appendingPathComponent("bin/brew", isDirectory: false).standardizedFileURL
            isDeclaredCustom = executable == expected
                && isSafeDeclaredPrefix(prefix)
                && prefix.pathComponents.count >= 3
        } else {
            isDeclaredCustom = false
        }
        guard isStandard || isDeclaredCustom else { return false }

        let pathsToCheck = [
            executable,
            executable.deletingLastPathComponent(),
            declaredPrefix?.standardizedFileURL,
        ].compactMap { $0 }
        return pathsToCheck.allSatisfy { url in
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let owner = attributes[.ownerAccountID] as? NSNumber,
                  let permissions = attributes[.posixPermissions] as? NSNumber else {
                return false
            }
            let ownerID = owner.uint32Value
            let mode = permissions.uint16Value
            return (ownerID == 0 || ownerID == getuid()) && (mode & 0o002) == 0
        }
    }

    static func isSafeDeclaredPrefix(_ prefixURL: URL) -> Bool {
        let path = prefixURL.standardizedFileURL.path
        let rejectedRoots = ["/", "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"]
        return !rejectedRoots.contains { rejectedRoot in
            path == rejectedRoot || path.hasPrefix(rejectedRoot + "/")
        }
    }
}

enum HomebrewInventoryParser {
    static func installedFormulaVersion(
        from data: Data,
        expectedToken: String
    ) throws -> ApplicationVersion? {
        guard let root = try jsonRoot(data, label: "formula info JSON root") else {
            throw ApplicationScanningError.invalidHomebrewOutput("formula info JSON root")
        }
        guard root["formulae"] is [[String: Any]],
              root["casks"] == nil || root["casks"] is [[String: Any]] else {
            throw ApplicationScanningError.invalidHomebrewOutput(
                "formula info JSON package lists"
            )
        }
        let requestedShortName = expectedToken.split(separator: "/").last.map(String.init)
            ?? expectedToken
        let matchingFormula = dictionaries(root["formulae"]).first { dictionary in
            let name = string(dictionary["name"])
            let fullName = string(dictionary["full_name"])
            if expectedToken.contains("/") {
                return fullName == expectedToken
            }
            return name == expectedToken || fullName == expectedToken
                || fullName?.split(separator: "/").last.map(String.init) == requestedShortName
        }
        guard let matchingFormula else { return nil }
        let installedVersions = dictionaries(matchingFormula["installed"])
            .compactMap { string($0["version"]) }
        guard let version = installedVersions.last else { return nil }
        return ApplicationVersion(marketing: version)
    }

    static func parse(
        installedData: Data,
        outdatedData: Data?,
        greedyOutdatedData: Data? = nil,
        prefixURL: URL
    ) throws -> [HomebrewInventoryPackage] {
        guard let installedRoot = try jsonRoot(installedData, label: "installed JSON root") else {
            throw ApplicationScanningError.invalidHomebrewOutput("installed JSON root")
        }
        try validatePackageLists(installedRoot, label: "installed JSON")
        let outdatedRoot = try jsonRoot(outdatedData, label: "outdated JSON root")
        let greedyOutdatedRoot = try jsonRoot(greedyOutdatedData, label: "greedy outdated JSON root")
        try validatePackageLists(outdatedRoot, label: "outdated JSON")
        try validatePackageLists(greedyOutdatedRoot, label: "greedy outdated JSON")
        let hasPlainFormulaList = outdatedRoot?["formulae"] is [[String: Any]]
        let hasPlainCaskList = outdatedRoot?["casks"] is [[String: Any]]
        let hasGreedyCaskList = greedyOutdatedRoot?["casks"] is [[String: Any]]
        let outdatedFormulae = tokenSet(outdatedRoot?["formulae"], keys: ["name", "full_name"])
        // `brew outdated --json=v2` currently emits the cask identifier as
        // `name` (while `brew info --json=v2` uses `token`). Accept both so a
        // Homebrew output-format distinction cannot silently hide every
        // outdated cask from the update plan.
        let outdatedCasks = tokenSet(outdatedRoot?["casks"], keys: ["token", "name"])
        let greedyOutdatedCasks = tokenSet(
            greedyOutdatedRoot?["casks"],
            keys: ["token", "name"]
        )

        var packages = [HomebrewInventoryPackage]()
        for dictionary in dictionaries(installedRoot["formulae"]) {
            guard let token = string(dictionary["name"]) ?? string(dictionary["full_name"]) else {
                continue
            }
            let installedVersions = dictionaries(dictionary["installed"])
                .compactMap { string($0["version"]) }
            let versions = dictionary["versions"] as? [String: Any]
            let currentVersion = string(versions?["stable"])
                ?? string(versions?["head"])
            let isOutdated = hasPlainFormulaList && outdatedFormulae.contains(token)
            let metadata = HomebrewPackageMetadata(
                token: token,
                kind: .formula,
                homepageURL: string(dictionary["homepage"]).flatMap(URL.init(string:)),
                installedVersions: installedVersions,
                currentVersion: currentVersion,
                isOutdated: isOutdated,
                outdatedProvenance: hasPlainFormulaList ? .plain : .unknown,
                isPinned: bool(dictionary["pinned"]),
                isDisabled: bool(dictionary["disabled"]),
                isDeprecated: bool(dictionary["deprecated"]),
                autoUpdates: false,
                requiresManualInstaller: false,
                appBundlePaths: []
            )
            packages.append(
                HomebrewInventoryPackage(
                    metadata: metadata,
                    displayNames: [string(dictionary["full_name"]), token].compactMap { $0 },
                    exactApplicationPaths: []
                )
            )
        }

        for dictionary in dictionaries(installedRoot["casks"]) {
            guard let token = string(dictionary["token"]) else { continue }
            let artifacts = dictionaries(dictionary["artifacts"])
            let applicationPaths = appBundlePaths(from: artifacts)
            // Preserve Homebrew's raw version. A comma can represent either an
            // artifact digest or a general CSV version tuple; only the strict
            // automatic-comparison layer may project a narrowly proven digest.
            let installedVersions = stringArray(dictionary["installed"])
            let currentVersion = string(dictionary["version"])
            let isPlainOutdated = hasPlainCaskList && outdatedCasks.contains(token)
            let isGreedyOutdated = hasGreedyCaskList && greedyOutdatedCasks.contains(token)
            let isOutdated = isPlainOutdated || isGreedyOutdated
            let outdatedProvenance: HomebrewOutdatedProvenance
            if isPlainOutdated {
                outdatedProvenance = .plain
            } else if isGreedyOutdated {
                outdatedProvenance = .greedy
            } else {
                outdatedProvenance = hasPlainCaskList ? .plain : .unknown
            }
            let metadata = HomebrewPackageMetadata(
                token: token,
                kind: .cask,
                homepageURL: string(dictionary["homepage"]).flatMap(URL.init(string:)),
                installedVersions: installedVersions,
                currentVersion: currentVersion,
                isOutdated: isOutdated,
                outdatedProvenance: outdatedProvenance,
                isPinned: bool(dictionary["pinned"]),
                isDisabled: bool(dictionary["disabled"]),
                isDeprecated: bool(dictionary["deprecated"]),
                autoUpdates: bool(dictionary["auto_updates"]),
                requiresManualInstaller: artifacts.contains {
                    $0.keys.contains("pkg") || $0.keys.contains("installer")
                },
                appBundlePaths: applicationPaths
            )
            let exactPaths = Set(applicationPaths.flatMap { path -> [String] in
                let originalURL = URL(fileURLWithPath: path, isDirectory: true)
                return [
                    ApplicationPathNormalizer.comparisonKey(for: originalURL),
                    ApplicationPathNormalizer.comparisonKey(for: originalURL.resolvingSymlinksInPath()),
                ]
            })
            packages.append(
                HomebrewInventoryPackage(
                    metadata: metadata,
                    displayNames: stringArray(dictionary["name"]) + [token],
                    exactApplicationPaths: exactPaths
                )
            )
        }

        return packages.sorted {
            if $0.metadata.kind != $1.metadata.kind {
                return $0.metadata.kind.rawValue < $1.metadata.kind.rawValue
            }
            return $0.metadata.token.localizedStandardCompare($1.metadata.token) == .orderedAscending
        }
    }

    private static func appBundlePaths(from artifacts: [[String: Any]]) -> [String] {
        var paths = Set<String>()
        for artifact in artifacts {
            guard let rawValue = artifact["app"] else { continue }
            for entry in artifactEntries(rawValue) {
                let sourceName = entry.source
                let targetName = entry.target ?? URL(fileURLWithPath: sourceName).lastPathComponent
                let path: String
                if targetName.hasPrefix("/") {
                    path = targetName
                } else {
                    path = URL(fileURLWithPath: "/Applications", isDirectory: true)
                        .appendingPathComponent(targetName, isDirectory: true)
                        .path
                }
                if URL(fileURLWithPath: path).pathExtension.caseInsensitiveCompare("app") == .orderedSame {
                    paths.insert(path)
                }
            }
        }
        return paths.sorted()
    }

    private static func artifactEntries(_ value: Any) -> [(source: String, target: String?)] {
        if let string = string(value) {
            return [(string, nil)]
        }
        guard let array = value as? [Any], let source = array.first.flatMap(string) else {
            return []
        }
        let target: String?
        if array.count > 1, let options = array[1] as? [String: Any] {
            target = string(options["target"])
        } else {
            target = nil
        }
        return [(source, target)]
    }

    private static func tokenSet(_ value: Any?, keys: [String]) -> Set<String> {
        Set(dictionaries(value).compactMap { dictionary in
            keys.lazy.compactMap { string(dictionary[$0]) }.first
        })
    }

    private static func dictionaries(_ value: Any?) -> [[String: Any]] {
        value as? [[String: Any]] ?? []
    }

    private static func jsonRoot(
        _ data: Data?,
        label: String
    ) throws -> [String: Any]? {
        guard let data else { return nil }
        guard !data.isEmpty else {
            throw ApplicationScanningError.invalidHomebrewOutput("\(label) empty")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ApplicationScanningError.invalidHomebrewOutput(label)
        }
        return root
    }

    private static func validatePackageLists(
        _ root: [String: Any]?,
        label: String
    ) throws {
        guard let root else { return }
        guard root["formulae"] is [[String: Any]],
              root["casks"] is [[String: Any]] else {
            throw ApplicationScanningError.invalidHomebrewOutput("\(label) package lists")
        }
    }

    private static func stringArray(_ value: Any?) -> [String] {
        if let string = string(value) { return [string] }
        if let array = value as? [Any] { return array.compactMap(string) }
        return []
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            value.trimmed.nonEmpty
        case let value as NSNumber:
            value.stringValue.trimmed.nonEmpty
        default:
            nil
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        switch value {
        case let value as Bool:
            value
        case let value as NSNumber:
            value.boolValue
        case let value as String:
            ["true", "yes", "1"].contains(value.lowercased())
        default:
            false
        }
    }
}
