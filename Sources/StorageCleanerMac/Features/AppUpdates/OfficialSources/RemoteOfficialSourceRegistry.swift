import Foundation

struct OfficialSourceRegistryRemoteConfiguration: Sendable {
    let remoteURL: URL
    let keyID: String
    let publicKey: Data
    let allowedHosts: Set<String>

    static var production: Self? {
        guard let remoteURL = URL(string:
            "https://raw.githubusercontent.com/yangyihang96/StorageCleanerMacUpdates/main/official-sources-v1.json"
        ), let publicKey = Data(base64Encoded: "9zE8Bh4PM/yp47qqC5RmAVnvkrqlX7TtT7POVCz2wEo=") else {
            return nil
        }
        return Self(
            remoteURL: remoteURL,
            keyID: "storage-cleaner-source-registry-v1",
            publicKey: publicKey,
            allowedHosts: ["raw.githubusercontent.com"]
        )
    }
}

private final class OfficialRegistryRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>
    private let validator = AllowedHostValidator()

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              (try? validator.validate(url, allowedHosts: allowedHosts)) != nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

actor RemoteOfficialSourceRegistryRefresher {
    private let configuration: OfficialSourceRegistryRemoteConfiguration?
    private let minimumRefreshInterval: TimeInterval
    private var lastAttempt: Date?

    init(
        configuration: OfficialSourceRegistryRemoteConfiguration? = .production,
        minimumRefreshInterval: TimeInterval = 6 * 60 * 60
    ) {
        self.configuration = configuration
        self.minimumRefreshInterval = minimumRefreshInterval
    }

    func refresh(
        registry: OfficialSourceRegistry,
        now: Date = Date()
    ) async -> String? {
        guard let configuration else { return nil }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < minimumRefreshInterval {
            return nil
        }
        lastAttempt = now

        let loader = SignedRegistryLoader(
            trustedPublicKeys: [configuration.keyID: configuration.publicKey]
        )
        let lastKnownGood = loadLastKnownGood(loader: loader, now: now)
        do {
            try AllowedHostValidator().validate(
                configuration.remoteURL,
                allowedHosts: configuration.allowedHosts
            )
            let delegate = OfficialRegistryRedirectDelegate(allowedHosts: configuration.allowedHosts)
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = 8
            sessionConfiguration.timeoutIntervalForResource = 12
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(
                configuration: sessionConfiguration,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(from: configuration.remoteURL)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  let finalURL = httpResponse.url,
                  (try? AllowedHostValidator().validate(
                    finalURL,
                    allowedHosts: configuration.allowedHosts
                  )) != nil else {
                throw URLError(.badServerResponse)
            }
            let outcome = try loader.load(
                envelopeData: data,
                lastKnownGood: lastKnownGood,
                now: now
            )
            try await registry.installVerifiedSnapshot(outcome.snapshot, now: now)
            if outcome.disposition == .acceptedRemote {
                try saveLastKnownGood(data)
            }
            return outcome.remoteRejection?.localizedDescription
        } catch {
            if let lastKnownGood {
                try? await registry.installVerifiedSnapshot(lastKnownGood, now: now)
            }
            return error.localizedDescription
        }
    }

    private func loadLastKnownGood(
        loader: SignedRegistryLoader,
        now: Date
    ) -> OfficialSourceRegistrySnapshot? {
        guard let data = try? Data(contentsOf: Self.lastKnownGoodURL),
              let outcome = try? loader.load(envelopeData: data, now: now) else {
            return nil
        }
        return outcome.snapshot
    }

    private func saveLastKnownGood(_ data: Data) throws {
        let directory = Self.lastKnownGoodURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: Self.lastKnownGoodURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: Self.lastKnownGoodURL.path
        )
    }

    private static var lastKnownGoodURL: URL {
        AppDataDirectories.applicationSupportRoot
            .appendingPathComponent("OfficialSources", isDirectory: true)
            .appendingPathComponent("last-known-good-v1.json", isDirectory: false)
    }
}
