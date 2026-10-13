import Foundation

/// Approval grants only exact protected application replacements. No root
/// command, mas, brew, password, or caller environment can enter the daemon.
public struct AuthorizedUpdateTarget: Codable, Sendable, Equatable {
    public let path: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let version: String
    public let build: String
    public init(path: String, bundleIdentifier: String, teamIdentifier: String, version: String, build: String) {
        self.path = path; self.bundleIdentifier = bundleIdentifier; self.teamIdentifier = teamIdentifier
        self.version = version; self.build = build
    }
}

public struct AuthorizedApplicationReplacementBatch: Codable, Sendable, Equatable {
    public let sessionID: UUID
    public let targets: [AuthorizedUpdateTarget]
    public let createdAt: Date
    public init(sessionID: UUID, targets: [AuthorizedUpdateTarget]) {
        self.sessionID = sessionID; self.targets = targets; createdAt = Date()
    }
    public static var right: String { FileOperationIdentity.helper + ".application-replacements" }
    public var isValid: Bool {
        targets.count <= 256 && !targets.isEmpty && Set(targets.map(\.path)).count == targets.count
            && targets.allSatisfy { target in
                let url = URL(fileURLWithPath: target.path)
                return url.standardizedFileURL.path == target.path && url.pathExtension == "app"
                    && url.deletingLastPathComponent().path == "/Applications"
                    && !target.bundleIdentifier.isEmpty && !target.teamIdentifier.isEmpty
                    && !target.bundleIdentifier.contains("\"") && !target.teamIdentifier.contains("\"")
                    && !target.bundleIdentifier.lowercased().hasPrefix("com.apple.")
                    && !target.bundleIdentifier.lowercased().hasPrefix("com.local.storagecleanermac")
            }
    }
}

public struct AuthenticatedApplicationReplacement: Codable, Sendable {
    public let candidatePath: String
    public let destinationPath: String
    public let sessionID: UUID
    public let candidateSHA256: String
    public init(candidatePath: String, destinationPath: String, sessionID: UUID, candidateSHA256: String) {
        self.candidatePath = candidatePath; self.destinationPath = destinationPath; self.sessionID = sessionID; self.candidateSHA256 = candidateSHA256
    }
}

public struct ApplicationReplacementCapabilities: Codable, Sendable {
    public let version: Int
    public let build: String
    public let busy: Bool
    public static let currentVersion = 2 // Frozen leaf digest format and retained rollback journal.
    public init(version: Int = Self.currentVersion, build: String, busy: Bool = false) { self.version = version; self.build = build; self.busy = busy }
}

public struct AuthorizedUpdateReply: Codable, Sendable {
    public let error: String?
    public let errorCode: Int?
    public let finished: Bool
    public init(error: String? = nil, errorCode: Int? = nil, finished: Bool = true) { self.error = error; self.errorCode = errorCode; self.finished = finished }
}
