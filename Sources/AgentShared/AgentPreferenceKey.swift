import Foundation

/// Preference keys in the App's own defaults domain. The bridge only reads
/// them, to tell "switched off" from "not running" (D267).
public enum AgentPreferenceKey {
    /// D265: "允许 AI 助手连接". Absent means off.
    public static let interfaceEnabled = "agentInterface.enabled"
    /// D267, from batch 2: may the bridge open the App when it is not running.
    public static let allowLaunch = "agentInterface.allowLaunch"
    /// D263: the user's decisions per client. Written by the App only.
    public static let clients = "agentInterface.clients.v1"

    /// The switch as the App stores it: nil only when the domain cannot be read.
    public static func interfaceEnabled(in defaults: UserDefaults?) -> Bool? {
        guard let defaults else { return nil }
        return defaults.object(forKey: interfaceEnabled) as? Bool ?? false
    }
}
