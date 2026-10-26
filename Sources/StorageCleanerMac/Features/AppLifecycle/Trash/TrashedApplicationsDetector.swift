import AppKit
import Foundation

/// An application bundle found somewhere inside the user's Trash.
struct TrashedApplication: Equatable, Hashable, Sendable, Identifiable {
    /// Where the bundle sits inside the Trash (possibly deep in a folder).
    let url: URL
    let bundleIdentifier: String?
    let displayName: String
    let version: String

    var id: String { discriminator }

    /// The ignore key. CleanMyMac stores the bundle's directory file URL with
    /// its trailing slash, for example `file:///Users/me/.Trash/App.app/`.
    var discriminator: String { Self.discriminator(for: url) }

    static func discriminator(for url: URL) -> String {
        URL(fileURLWithPath: url.path, isDirectory: true).absoluteString
    }
}

/// CleanMyMac 5 `CMTrashedAppsService` / `CMBundleValidator`, decompiled on
/// 2026-10-19 (`CleanMyMac卸载更新逆向-2026-10-19/逆向规格与差距清单.md` §5.2).
/// Read-only: it lists and inspects, it never moves or deletes.
enum TrashedApplicationsDetector {
    /// Packages CleanMyMac never descends into while looking for apps.
    static let opaquePackageExtensions: Set<String> = ["vmwarevm", "photolibrary", "aplibrary"]

    /// Bounds the walk of a very large Trash; CleanMyMac has no bound, a
    /// reminder is not worth stalling the app for.
    struct Budget: Sendable {
        var maximumVisitedEntries = 400_000
        var deadline: TimeInterval = 45
    }

    struct Scan: Equatable, Sendable {
        var applicationURLs: [URL]
        var isComplete: Bool
    }

    /// `+[CMTrashedAppsService applicationsToUninstallFromTrashURL:]`:
    /// walk the Trash; a directory whose extension is an opaque package is not
    /// entered; a valid application is recorded (when it opens as a bundle)
    /// and not entered; anything else that is a folder is walked further.
    static func applicationURLs(
        inTrash trashURL: URL,
        fileManager: FileManager = .default,
        budget: Budget = Budget()
    ) -> Scan {
        guard let enumerator = fileManager.enumerator(
            at: trashURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return Scan(applicationURLs: [], isComplete: false)
        }
        let deadline = Date().addingTimeInterval(budget.deadline)
        var visited = 0
        var found: [URL] = []
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            visited += 1
            if visited > budget.maximumVisitedEntries || (visited % 512 == 0 && Date() > deadline) {
                return Scan(applicationURLs: found, isComplete: false)
            }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            guard isDirectory else {
                enumerator.skipDescendants()
                continue
            }
            if opaquePackageExtensions.contains(url.pathExtension) {
                enumerator.skipDescendants()
            } else if isValidApplication(at: url, fileManager: fileManager) {
                if Bundle(url: url) != nil {
                    found.append(url)
                }
                enumerator.skipDescendants()
            }
        }
        return Scan(applicationURLs: found, isComplete: true)
    }

    /// `+[CMBundleValidator _validateOfBundleWithPath:extension:fileManager:]`
    /// with extension `app`: the path extension contains "app" (case
    /// insensitive, as `rangeOfString:options:1`) and both `Contents/MacOS`
    /// and `Contents/Info.plist` exist.
    static func isValidApplication(at url: URL, fileManager: FileManager = .default) -> Bool {
        guard url.pathExtension.range(of: "app", options: .caseInsensitive) != nil else { return false }
        return fileManager.fileExists(atPath: url.appendingPathComponent("Contents/MacOS").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("Contents/Info.plist").path)
    }

    /// `-[CMTrashedAppsService appExistsOutsideTrashWithURL:]`: LaunchServices
    /// is asked for the bundle identifier. A copy it knows outside the Trash
    /// counts only when it is writable. When it knows none, or only the one in
    /// the Trash, `/Applications/<same bundle name>` counts when it exists and
    /// is writable.
    static func applicationExistsOutsideTrash(
        _ applicationURL: URL,
        trashURL: URL,
        launchServicesPath: (String) -> String? = { identifier in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier)?.path
        },
        fileManager: FileManager = .default,
        applicationsDirectory: String = "/Applications"
    ) -> Bool {
        let identifier = Bundle(url: applicationURL)?.bundleIdentifier
        let knownPath = identifier.flatMap(launchServicesPath)
        if let knownPath, knownPath.range(of: trashURL.path) == nil {
            return fileManager.isWritableFile(atPath: knownPath)
        }
        let fallback = (applicationsDirectory as NSString).appendingPathComponent(applicationURL.lastPathComponent)
        return fileManager.fileExists(atPath: fallback) && fileManager.isWritableFile(atPath: fallback)
    }

    /// `-[CMTrashedAppsService update]`: the applications found, minus those
    /// that still exist outside the Trash.
    static func trashedApplications(
        inTrash trashURL: URL,
        fileManager: FileManager = .default,
        budget: Budget = Budget(),
        existsOutsideTrash: ((URL) -> Bool)? = nil
    ) -> (applications: [TrashedApplication], isComplete: Bool) {
        let scan = applicationURLs(inTrash: trashURL, fileManager: fileManager, budget: budget)
        let outside = existsOutsideTrash ?? { url in
            applicationExistsOutsideTrash(url, trashURL: trashURL, fileManager: fileManager)
        }
        let applications = scan.applicationURLs
            .filter { !outside($0) }
            .map { describe($0) }
        return (applications, scan.isComplete)
    }

    static func describe(_ url: URL) -> TrashedApplication {
        let info = Bundle(url: url)?.infoDictionary ?? [:]
        let name = (info["CFBundleDisplayName"] as? String)?.nonEmptyTrimmed
            ?? (info["CFBundleName"] as? String)?.nonEmptyTrimmed
            ?? url.deletingPathExtension().lastPathComponent
        return TrashedApplication(
            url: url,
            bundleIdentifier: (info["CFBundleIdentifier"] as? String)?.nonEmptyTrimmed,
            displayName: name,
            version: (info["CFBundleShortVersionString"] as? String) ?? ""
        )
    }
}

private extension String {
    var nonEmptyTrimmed: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
