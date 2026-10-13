import Foundation

struct HomebrewCaskConfiguration: Sendable {
    let directories: [String: String]
    let understood: Bool
    // Cask::Config::DEFAULT_DIRS and derived prefix directories. Saved explicit
    // wins over saved/current env, which wins over saved/default configuration.
    static func resolve(saved: [String: Any]? = nil, environment: [String: String] = [:],
        home: URL = FileManager.default.homeDirectoryForCurrentUser, prefix: URL = URL(fileURLWithPath: "/opt/homebrew")) -> Self {
        let defaults = ["appdir": "/Applications", "appimagedir": "~/Applications", "keyboard_layoutdir": "/Library/Keyboard Layouts",
            "colorpickerdir": "~/Library/ColorPickers", "prefpanedir": "~/Library/PreferencePanes", "qlplugindir": "~/Library/QuickLook",
            "mdimporterdir": "~/Library/Spotlight", "dictionarydir": "~/Library/Dictionaries", "fontdir": "~/Library/Fonts",
            "servicedir": "~/Library/Services", "input_methoddir": "~/Library/Input Methods", "internet_plugindir": "~/Library/Internet Plug-Ins",
            "audio_unit_plugindir": "~/Library/Audio/Plug-Ins/Components", "vst_plugindir": "~/Library/Audio/Plug-Ins/VST",
            "vst3_plugindir": "~/Library/Audio/Plug-Ins/VST3", "screen_saverdir": "~/Library/Screen Savers"]
        var values = defaults; var understood = true
        func merge(_ map: [String: Any]?) {
            if map?.keys.contains(where: { defaults[$0] == nil && $0 != "languages" && !$0.contains("-") }) == true { understood = false }
            for (key, value) in map ?? [:] where defaults[key] != nil {
                if let path = value as? String { values[key] = path } else { understood = false }
            }
        }
        merge(saved?["default"] as? [String: Any])
        if let env = saved?["env"] as? [String: Any] { merge(env) }
        else if let options = environment["HOMEBREW_CASK_OPTS"] {
            if let words = shellWords(options) {
                for word in words where word.hasPrefix("--") && word.contains("=") {
                    let pair = word.dropFirst(2).split(separator: "=", maxSplits: 1).map(String.init)
                    let key = pair[0].replacingOccurrences(of: "-", with: "_")
                    if defaults[key] != nil { values[key] = pair[1] }
                    else if key != "language" { understood = false }
                }
            } else { understood = false }
        }
        merge(saved?["explicit"] as? [String: Any])
        let keys = ["app": "appdir", "appimage": "appimagedir", "keyboard_layout": "keyboard_layoutdir", "colorpicker": "colorpickerdir",
            "prefpane": "prefpanedir", "qlplugin": "qlplugindir", "mdimporter": "mdimporterdir", "dictionary": "dictionarydir", "font": "fontdir",
            "service": "servicedir", "input_method": "input_methoddir", "internet_plugin": "internet_plugindir",
            "audio_unit_plugin": "audio_unit_plugindir", "vst_plugin": "vst_plugindir", "vst3_plugin": "vst3_plugindir", "screen_saver": "screen_saverdir"]
        var dirs = [String: String]()
        for (artifact, key) in keys {
            guard let path = values[key] else { understood = false; continue }
            if path.hasPrefix("~/") { dirs[artifact] = home.appendingPathComponent(String(path.dropFirst(2))).standardizedFileURL.path }
            else if path.hasPrefix("/") { dirs[artifact] = URL(fileURLWithPath: path).standardizedFileURL.path }
            else { understood = false }
        }
        dirs["suite"] = dirs["app"]
        for (artifact, relative) in ["binary": "bin", "manpage": "share/man", "bash_completion": "etc/bash_completion.d",
            "zsh_completion": "share/zsh/site-functions", "fish_completion": "share/fish/vendor_completions.d", "pwsh_completion": "share/pwsh/completions"] {
            dirs[artifact] = prefix.appendingPathComponent(relative).path
        }
        return .init(directories: dirs, understood: understood)
    }
    static func installed(token: String, prefix: URL, environment: [String: String]) -> Self {
        guard HomebrewPackageTokenPolicy.isValid(token) else { return .init(directories: [:], understood: false) }
        let file = prefix.appendingPathComponent("Caskroom").appendingPathComponent(token.split(separator: "/").last.map(String.init) ?? token)
            .appendingPathComponent(".metadata/config.json")
        if FileManager.default.fileExists(atPath: file.path) {
            guard let bytes = try? Data(contentsOf: file), bytes.count <= 262_144,
                let saved = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return .init(directories: [:], understood: false) }
            return resolve(saved: saved, environment: environment, prefix: prefix)
        }
        return resolve(environment: environment, prefix: prefix)
    }
    private static func shellWords(_ text: String) -> [String]? {
        var words = [String](); var word = ""; var quote: Character?; var escaped = false
        for c in text {
            if escaped { word.append(c); escaped = false }
            else if c == "\\", quote != "'" { escaped = true }
            else if let current = quote { if c == current { quote = nil } else { word.append(c) } }
            else if c == "\"" || c == "'" { quote = c }
            else if c.isWhitespace { if !word.isEmpty { words.append(word); word = "" } }
            else { word.append(c) }
        }
        guard !escaped, quote == nil else { return nil }
        if !word.isEmpty { words.append(word) }; return words
    }
}
