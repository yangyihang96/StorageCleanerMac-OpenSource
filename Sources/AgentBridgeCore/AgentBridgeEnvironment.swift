import AgentShared
import FileOperationShared
import Foundation

/// Everything the bridge knows comes from the App bundle it ships in:
/// `<App>.app/Contents/Helpers/storage-cleaner-agent` (D260). A bridge found
/// anywhere else does nothing rather than guess an App.
public struct AgentBridgeEnvironment: Equatable, Sendable {
    public enum Failure: Error, Equatable, Sendable {
        case notInApplicationBundle
        case unreadableInfo
        case unknownApplication(String)
    }

    public let applicationURL: URL
    public let applicationExecutable: String
    public let bundleIdentifier: String
    public let displayName: String
    public let version: String
    public let dataDirectory: URL

    public var socketPath: String { AgentSocketLocation.socketPath(dataDirectory: dataDirectory) }

    public static func locate(executable: URL, home: URL,
                              compiledAsBeta: Bool = AgentDataLocation.compiledAsBeta) throws(Failure) -> Self {
        // A link on PATH still leads back to the real file inside the bundle.
        let helpers = URL(fileURLWithPath: AgentPaths.real(executable)).deletingLastPathComponent()
        let contents = helpers.deletingLastPathComponent()
        let application = contents.deletingLastPathComponent()
        guard helpers.lastPathComponent == "Helpers", contents.lastPathComponent == "Contents", application.pathExtension == "app" else {
            throw .notInApplicationBundle
        }
        guard let info = NSDictionary(contentsOf: contents.appendingPathComponent("Info.plist")) as? [String: Any],
              let identifier = info["CFBundleIdentifier"] as? String,
              let executableName = info["CFBundleExecutable"] as? String, !executableName.isEmpty, !executableName.contains("/") else {
            throw .unreadableInfo
        }
        // QA copies carry their isolated data root in LSEnvironment.
        let environment = info["LSEnvironment"] as? [String: String] ?? [:]
        guard let data = AgentDataLocation.dataDirectory(bundleIdentifier: identifier, environment: environment, home: home,
                                                         compiledAsBeta: compiledAsBeta) else {
            throw .unknownApplication(identifier)
        }
        let name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String
            ?? application.deletingPathExtension().lastPathComponent
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        let version = (info["CFBundleVersion"] as? String).map { "\(short) (\($0))" } ?? short
        return .init(applicationURL: application, applicationExecutable: contents.appendingPathComponent("MacOS/\(executableName)").path,
                     bundleIdentifier: identifier, displayName: name, version: version, dataDirectory: data)
    }

    public var serverIdentity: AgentServerIdentity {
        .init(name: AgentDataLocation.serverName(bundleIdentifier: bundleIdentifier), title: displayName, version: version)
    }

    /// The App's switch, read from its own defaults (D267). Never written here.
    public func interfaceEnabled() -> Bool? {
        AgentPreferenceKey.interfaceEnabled(in: UserDefaults(suiteName: bundleIdentifier))
    }

    /// Nil when the bridge cannot vouch for itself (unsigned, or signed under
    /// another identifier): then no App is ever trusted.
    public func applicationPolicy(bridgeExecutable: URL) -> AgentApplicationPeerPolicy? {
        guard let bridge = UpdateAskpassCodeIdentity.file(URL(fileURLWithPath: AgentPaths.real(bridgeExecutable))),
              bridge.identifier == bundleIdentifier + AgentBridgePeerPolicy.identifierSuffix else { return nil }
        // Only ad-hoc builds need the App's on-disk identity: validating the
        // whole bundle is not free.
        let bundled = bridge.adHoc ? UpdateAskpassCodeIdentity.file(applicationURL) : nil
        return AgentApplicationPeerPolicy(applicationExecutable: applicationExecutable, applicationIdentifier: bundleIdentifier,
                                          bridge: bridge, bundledApplication: bundled)
    }
}
