import CoreFoundation
import Darwin
import Foundation

/// 只还原路径；不修改隔离属性，不启动应用，也不创建或卸载转移挂载。
///
/// r2-fa-followups P2-2：只有确实在应用转移（App Translocation）挂载下运行、
/// 又还原不出原路径的应用，才算“无法确认”。包已被删除或移走但仍在运行的
/// 应用不是转移运行，按它自己的路径匹配（路径不存在也照样比对）。
enum FileAnalysisRunningApplicationResolver {
    typealias TranslocationCheck = @convention(c) (
        CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> UInt8
    typealias OriginalPath = @convention(c) (
        CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    /// The bundle's original location: its own path, unless macOS runs it
    /// translocated; then the path Security restores. Nil only for an app
    /// running from a translocation mount whose original path cannot be
    /// restored.
    static func originalURL(for url: URL) -> URL? {
        let url = url.standardizedFileURL
        let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL)
        defer { if let handle { dlclose(handle) } }
        let check = handle.flatMap { dlsym($0, "SecTranslocateIsTranslocatedURL") }
            .map { unsafeBitCast($0, to: TranslocationCheck.self) }
        let original = handle.flatMap { dlsym($0, "SecTranslocateCreateOriginalPathForURL") }
            .map { unsafeBitCast($0, to: OriginalPath.self) }
        var translocated = false
        // When Security cannot say (the bundle is gone, or the lookup is
        // missing), only the translocation mount itself counts.
        let asked = check.map { $0(url as CFURL, &translocated, nil) != 0 } ?? false
        guard asked ? translocated : isInTranslocationMount(url.path) else { return url }
        guard let original, let retained = original(url as CFURL, nil) else { return nil }
        let restored = (retained.takeRetainedValue() as URL).standardizedFileURL
        guard restored.isFileURL, !restored.path.isEmpty, restored.path != url.path else { return nil }
        return restored
    }

    /// macOS runs a translocated app from a read-only mount at
    /// `…/AppTranslocation/<id>/d/<App>.app` in the user's temporary folder.
    static func isInTranslocationMount(_ path: String) -> Bool {
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(of: "AppTranslocation") else { return false }
        return components.count - index >= 3
    }

    /// The name people know the app by: its bundle's file name.
    static func applicationName(forBundlePath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let bare = (name as NSString).pathExtension.caseInsensitiveCompare("app") == .orderedSame
            ? (name as NSString).deletingPathExtension : name
        return bare.isEmpty ? name : bare
    }
}

struct FileAnalysisRunningApplicationState: Equatable, Sendable {
    /// Every running app's bundle path, and the original path of each
    /// translocated one.
    let paths: [String]
    /// P2-2: translocated apps whose original path could not be restored.
    var unknownApplicationNames: [String] = []

    var isKnown: Bool { unknownApplicationNames.isEmpty }
}
