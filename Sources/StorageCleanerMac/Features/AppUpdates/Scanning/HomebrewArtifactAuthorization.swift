import Foundation

/// Mirrors Homebrew's Pkg.requires_sudo?, Installer.args[:sudo], and moved /
/// relocated artifact parent writability. This is inventory-only; no brew runs.
enum HomebrewArtifactAuthorization {
    static func reasons(artifacts: [[String: Any]],
        configuration: HomebrewCaskConfiguration = .resolve(),
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        writable: (String) -> Bool = { FileManager.default.isWritableFile(atPath: $0) }) -> [String] {
        var reasons = Set<String>()
        func sudoDeclared(_ value: Any) -> Bool {
            if let map = value as? [String: Any] {
                return map["sudo"] as? Bool == true || map.values.contains(where: sudoDeclared)
            }
            return (value as? [Any])?.contains(where: sudoDeclared) == true
        }
        func target(_ value: Any, directory: String) -> String? {
            if let list = value as? [Any], let name = list.first as? String {
                let explicit = (list.dropFirst().first as? [String: Any])?["target"] as? String
                let name = explicit ?? URL(fileURLWithPath: name).lastPathComponent
                return name.hasPrefix("/") ? name : directory + "/" + name
            }
            if let name = value as? String { return directory + "/" + URL(fileURLWithPath: name).lastPathComponent }
            return nil
        }
        let directories = configuration.directories
        if !configuration.understood { reasons.insert("无法确认 Homebrew 有效目标配置，保守请求管理员授权") }
        for artifact in artifacts {
            if artifact["pkg"] != nil { reasons.insert("pkg 安装器") }
            if let installer = artifact["installer"], sudoDeclared(installer) { reasons.insert("声明 sudo 的厂商安装器") }
            if let uninstall = artifact["uninstall"], sudoDeclared(uninstall) { reasons.insert("声明 sudo 的卸载步骤") }
            for (key, directory) in directories {
                guard let value = artifact[key] else { continue }
                guard let path = target(value, directory: directory) else { reasons.insert("无法确认 \(key) 的目标，保守请求管理员授权"); continue }
                var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
                while !exists(parent.path), parent.path != "/" { parent.deleteLastPathComponent() }
                if !writable(parent.path) || (exists(path) && !writable(path)) {
                    reasons.insert("受保护的 \(key) 目标：\(path)")
                }
            }
            let known = Set(directories.keys).union(["pkg", "installer", "uninstall", "zap", "preflight", "postflight", "uninstall_preflight", "uninstall_postflight", "stage_only", "caveats"])
            if artifact.keys.contains(where: { !known.contains($0) }) { reasons.insert("未知 artifact 目标，保守请求管理员授权") }
        }
        return reasons.sorted()
    }
}

enum AppUpdateProtectedReplacementPolicy {
    static func accepts(_ app: InstalledApplication) -> Bool {
        app.bundleURL.standardizedFileURL == app.bundleURL
            && app.bundleURL.deletingLastPathComponent().path == "/Applications"
            && app.bundleURL.pathExtension == "app" && app.identity.isCompleteForAutomaticUpdates
            && !app.bundleIdentifier.lowercased().hasPrefix("com.apple.")
            && !app.bundleIdentifier.lowercased().hasPrefix("com.local.storagecleanermac")
    }
}
