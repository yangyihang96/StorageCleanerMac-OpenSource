import Foundation

/// D226: the one list of installer types. Applications → Installers lists
/// them wherever they are; My Clutter's Downloads and Large & Old Files leave
/// them out, so an installer is listed in one place only.
enum InstallerFileTypes {
    static let extensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "sparseimage", "xip"]

    static func isInstaller(path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }
}
