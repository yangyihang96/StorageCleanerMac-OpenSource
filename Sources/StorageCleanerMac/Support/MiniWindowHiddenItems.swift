import AppKit
import Foundation

/// D136: iStat Menus 7.30's hidden menu items. A hide button appends the
/// item's key to `Disks.Menu.Filtering` (`Network.Menu.Filtering` for an
/// interface), the menu rebuilds without it and the submenu closes; the
/// settings app's Statistics menu resets the list (`Reset Disk Filtering`
/// sets it to nil). The list is stored as a JSON array string so the panel
/// and the settings window both observe it with `@AppStorage`.
enum MiniWindowHiddenItems {
    static let disksKey = "menuBar.disks.hidden.v1"

    /// iStat runs a space section's click 0.1 s later (`dispatch_after`).
    static let actionDelay: TimeInterval = 0.1

    static func keys(from raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return keys
    }

    /// The stored list with `key` appended; an item hides once.
    static func raw(appending key: String, to raw: String) -> String {
        var keys = keys(from: raw)
        guard !keys.contains(key) else { return raw }
        keys.append(key)
        guard let data = try? JSONEncoder().encode(keys),
              let encoded = String(data: data, encoding: .utf8) else { return raw }
        return encoded
    }

    /// The items whose key is not in the stored list, in their order.
    static func visible<Item>(_ items: [Item], raw: String, key: (Item) -> String) -> [Item] {
        let hidden = Set(keys(from: raw))
        guard !hidden.isEmpty else { return items }
        return items.filter { !hidden.contains(key($0)) }
    }
}

/// D136: the disk space section's Finder button opens the volume
/// (`-[NSWorkspace openURL:]` with `fileURLWithPath: disk.path`).
@MainActor
enum MiniWindowVolumeActions {
    static func showInFinder(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}
