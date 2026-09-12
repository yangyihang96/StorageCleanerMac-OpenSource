import Darwin
import Foundation

struct StartupApplicationSigningIdentity: Equatable, Sendable {
    let teamIdentifier: String?
    let codeSigningIdentifier: String?
    let designatedRequirement: String?
}

protocol StartupApplicationSigningIdentityReading: Sendable {
    func identity(
        at bundleURL: URL,
        executableURL: URL?
    ) async -> StartupApplicationSigningIdentity?
}

actor StartupApplicationSigningIdentityReader: StartupApplicationSigningIdentityReading {
    static let shared = StartupApplicationSigningIdentityReader()

    private struct FileStamp: Hashable {
        let device: UInt64
        let inode: UInt64
        let size: Int64
        let modificationSeconds: Int64
        let modificationNanoseconds: Int64
    }

    private struct CacheKey: Hashable {
        let bundlePath: String
        let bundleStamp: FileStamp
        let executablePath: String?
        let executableStamp: FileStamp?
    }

    private struct CacheValue {
        let identity: StartupApplicationSigningIdentity?
    }

    private static let codesignURL = URL(fileURLWithPath: "/usr/bin/codesign")
    private static let defaultOutputByteLimit = 64 * 1_024
    private let runner: any StartupItemsDomain.StartupProcessRunning
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let maximumCacheEntries: Int
    private var cache = [CacheKey: CacheValue]()
    private var cacheOrder = [CacheKey]()

    init(
        runner: any StartupItemsDomain.StartupProcessRunning = StartupItemsDomain
            .CancellableStartupProcessRunner(outputByteLimit: defaultOutputByteLimit),
        timeout: TimeInterval = 1,
        maximumOutputBytes: Int = defaultOutputByteLimit,
        maximumCacheEntries: Int = 256
    ) {
        self.runner = runner
        self.timeout = max(0.1, timeout)
        self.maximumOutputBytes = max(1, maximumOutputBytes)
        self.maximumCacheEntries = max(1, maximumCacheEntries)
    }

    func identity(
        at bundleURL: URL,
        executableURL: URL?
    ) async -> StartupApplicationSigningIdentity? {
        guard !Task.isCancelled,
              let key = Self.cacheKey(bundleURL: bundleURL, executableURL: executableURL) else {
            return nil
        }
        if let cached = cache[key] { return cached.identity }

        let identity: StartupApplicationSigningIdentity?
        do {
            let verification = try await runner.run(
                executableURL: Self.codesignURL,
                arguments: [
                    "--verify", "--strict", "--verbose=1", key.bundlePath,
                ],
                timeout: timeout
            )
            guard verification.terminationStatus == 0,
                  verification.combinedOutput.utf8.count <= maximumOutputBytes else {
                store(nil, for: key)
                return nil
            }
            let display = try await runner.run(
                executableURL: Self.codesignURL,
                arguments: [
                    "--display", "--verbose=1", "--requirements", "-", key.bundlePath,
                ],
                timeout: timeout
            )
            let output = display.combinedOutput
            guard display.terminationStatus == 0,
                  output.utf8.count <= maximumOutputBytes else {
                store(nil, for: key)
                return nil
            }
            identity = Self.parse(output)
        } catch {
            identity = nil
        }
        store(identity, for: key)
        return identity
    }

    private func store(_ identity: StartupApplicationSigningIdentity?, for key: CacheKey) {
        cache.keys
            .filter { $0.bundlePath == key.bundlePath && $0 != key }
            .forEach { staleKey in
                cache.removeValue(forKey: staleKey)
                cacheOrder.removeAll { $0 == staleKey }
            }
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = CacheValue(identity: identity)
        while cacheOrder.count > maximumCacheEntries {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private static func cacheKey(bundleURL: URL, executableURL: URL?) -> CacheKey? {
        let bundle = bundleURL.standardizedFileURL
        guard let bundleStamp = fileStamp(at: bundle, expectedType: S_IFDIR) else { return nil }
        let executable = executableURL?.standardizedFileURL
        let executableStamp: FileStamp?
        if let executable {
            guard let stamp = fileStamp(at: executable, expectedType: S_IFREG) else { return nil }
            executableStamp = stamp
        } else {
            executableStamp = nil
        }
        return CacheKey(
            bundlePath: bundle.path,
            bundleStamp: bundleStamp,
            executablePath: executable?.path,
            executableStamp: executableStamp
        )
    }

    private static func fileStamp(at URL: URL, expectedType: mode_t) -> FileStamp? {
        var metadata = stat()
        guard URL.path.withCString({ Darwin.lstat($0, &metadata) }) == 0,
              (metadata.st_mode & S_IFMT) == expectedType else {
            return nil
        }
        return FileStamp(
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino),
            size: Int64(metadata.st_size),
            modificationSeconds: Int64(metadata.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(metadata.st_mtimespec.tv_nsec)
        )
    }

    private static func parse(_ output: String) -> StartupApplicationSigningIdentity? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let teamIdentifier = value(after: "TeamIdentifier=", in: lines, maximumLength: 128)
            .flatMap { value in
                value.caseInsensitiveCompare("not set") == .orderedSame
                    ? nil
                    : value.allSatisfy { $0.isLetter || $0.isNumber } ? value : nil
            }
        let codeSigningIdentifier = value(
            after: "Identifier=",
            in: lines,
            maximumLength: 512
        )
        let designatedRequirement = value(
            after: "designated =>",
            in: lines,
            maximumLength: 16 * 1_024
        )
        guard teamIdentifier != nil
                || codeSigningIdentifier != nil
                || designatedRequirement != nil else {
            return nil
        }
        return StartupApplicationSigningIdentity(
            teamIdentifier: teamIdentifier,
            codeSigningIdentifier: codeSigningIdentifier,
            designatedRequirement: designatedRequirement
        )
    }

    private static func value(
        after prefix: String,
        in lines: [String],
        maximumLength: Int
    ) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmed
        guard let nonempty = value.nonEmpty,
              nonempty.count <= maximumLength,
              !nonempty.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return nonempty
    }
}
