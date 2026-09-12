import Darwin
import Foundation

struct AppBuildInfo: Equatable, Sendable {
    let version: String
    let build: String
    let commit: String
    let dirty: Bool
    let buildDate: String
    let configuration: String

    var isBeta: Bool { configuration == "Beta" }
    var commitDisplay: String { dirty ? "\(commit)-dirty" : commit }

    static func load(bundle: Bundle = .main) -> AppBuildInfo? {
        guard let url = bundle.url(forResource: "BuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return decode(plist)
    }

    static func decode(_ plist: [String: Any]) -> AppBuildInfo? {
        guard let version = (plist["version"] as? String)?.nonEmpty,
              let build = (plist["build"] as? String)?.nonEmpty,
              let commit = (plist["commit"] as? String)?.nonEmpty,
              let dirty = plist["dirty"] as? Bool,
              let buildDate = (plist["buildDate"] as? String)?.nonEmpty,
              let configuration = (plist["configuration"] as? String)?.nonEmpty else {
            return nil
        }
        return AppBuildInfo(
            version: version,
            build: build,
            commit: commit,
            dirty: dirty,
            buildDate: buildDate,
            configuration: configuration
        )
    }

    func betaDiagnosticsMarkdown(
        helperStatus: String,
        advancedControlStatus: String
    ) -> String {
        [
            "测试版",
            "存储清理助手 \(version)",
            "Build \(build)",
            "Commit \(commitDisplay)",
            "构建日期 \(buildDate)",
            "构建配置 \(configuration)",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Mac 型号 \(Self.machineModel ?? "未知")",
            "Helper 状态 \(helperStatus)",
            "高级控制状态 \(advancedControlStatus)"
        ].joined(separator: "\n")
    }

    private static var machineModel: String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0,
              size > 1,
              size <= 1_024 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        let result = buffer.withUnsafeMutableBufferPointer {
            sysctlbyname("hw.model", $0.baseAddress, &size, nil, 0)
        }
        guard result == 0 else {
            return nil
        }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

enum AppRuntimeLocationKind: Equatable, Sendable {
    case applications
    case developmentDist
    case buildProduct
    case other

    var title: String {
        switch self {
        case .applications:
            L10n.text("已安装", "Installed")
        case .developmentDist:
            L10n.text("开发版本", "Development Build")
        case .buildProduct:
            L10n.text("构建版本", "Build Product")
        case .other:
            L10n.text("非标准位置", "Non-standard Location")
        }
    }

    var detail: String {
        switch self {
        case .applications:
            L10n.text("正在从 /Applications 运行", "Running from /Applications")
        case .developmentDist:
            L10n.text("正在从项目 dist 目录运行", "Running from the project dist folder")
        case .buildProduct:
            L10n.text("正在从 SwiftPM 或 Xcode 构建目录运行", "Running from a SwiftPM or Xcode build folder")
        case .other:
            L10n.text("正在从非标准位置运行", "Running from a non-standard location")
        }
    }

    var systemImage: String {
        switch self {
        case .applications:
            "checkmark.seal.fill"
        case .developmentDist:
            "hammer.fill"
        case .buildProduct:
            "curlybraces.square.fill"
        case .other:
            "location.fill"
        }
    }
}

struct AppRuntimeInfo: Equatable, Sendable {
    let kind: AppRuntimeLocationKind
    let path: String
    let bundleIdentifier: String
    let version: String?
    let build: String?
    let buildInfo: AppBuildInfo?

    var versionDisplay: String {
        switch (version?.nonEmpty, build?.nonEmpty) {
        case let (version?, build?):
            "\(version) (\(build))"
        case let (version?, nil):
            version
        case let (nil, build?):
            build
        case (nil, nil):
            L10n.text("本地构建", "Local build")
        }
    }

    var distributionStatus: String {
        switch kind {
        case .applications:
            L10n.text(
                "本机安装版可运行；公开分发仍需 Developer ID 签名和 Apple 公证。",
                "Installed locally; public distribution still requires Developer ID signing and Apple notarization."
            )
        case .developmentDist, .buildProduct:
            L10n.text(
                "开发构建仅用于本机验证，不适合作为公开分发包。",
                "Development builds are for local verification and are not suitable for public distribution."
            )
        case .other:
            L10n.text(
                "当前从非标准位置运行；公开分发前请使用发布包并完成公证。",
                "Running from a non-standard location; use a release package and notarize before public distribution."
            )
        }
    }

    var authorizationStabilityStatus: String {
        switch kind {
        case .applications:
            L10n.text(
                "从 /Applications 运行且 Bundle ID 保持不变时，macOS 通常会复用已授予的文件访问权限。",
                "When running from /Applications with the same Bundle ID, macOS usually reuses previously granted file access."
            )
        case .developmentDist, .buildProduct:
            L10n.text(
                "开发包或构建产物可能因为路径、签名或构建身份变化，被 macOS 当作新的 App，需要重新确认权限。",
                "Development builds can be treated as a new app when path, signing, or build identity changes, so macOS may ask for access again."
            )
        case .other:
            L10n.text(
                "当前运行位置不标准；如需减少重复权限确认，请安装到 /Applications 并保持 Bundle ID 与签名身份稳定。",
                "This location is non-standard; to reduce repeated access prompts, install into /Applications and keep the Bundle ID and signing identity stable."
            )
        }
    }

    var authorizationStabilityAction: String {
        let installPath = buildInfo?.isBeta == true
            ? "/Applications/测试版.app"
            : "/Applications/存储清理助手.app"
        return switch kind {
        case .applications:
            L10n.text(
                "固定从 \(installPath) 打开；不要从 DMG、下载目录或临时构建目录反复启动不同副本。",
                "Keep opening \(installPath); avoid repeatedly launching different copies from the DMG, Downloads, or temporary build folders."
            )
        case .developmentDist, .buildProduct:
            L10n.text(
                "这是开发或构建副本；需要稳定复用授权时，请安装并打开 \(installPath)。",
                "This is a development or build copy; for stable access reuse, install and open \(installPath)."
            )
        case .other:
            L10n.text(
                "当前不是标准安装位置；需要减少重复授权时，请改用 \(installPath)。",
                "This is not the standard install location; to reduce repeated prompts, use \(installPath)."
            )
        }
    }

    var authorizationWindowLifecycleNote: String {
        switch kind {
        case .applications:
            L10n.text(
                "关闭窗口只会隐藏主界面，不会撤销 macOS 文件访问授权；再次打开同一个 /Applications 副本时不需要重新授权。",
                "Closing the window only hides the main interface and does not revoke macOS file access; reopening the same /Applications copy should not require access again."
            )
        case .developmentDist, .buildProduct:
            L10n.text(
                "关闭窗口本身不会撤销授权；如果开发副本路径、签名或构建身份变化，macOS 仍可能把它当作新 App 再次确认。",
                "Closing the window itself does not revoke access; if a development copy changes path, signing, or build identity, macOS may still treat it as a new app and ask again."
            )
        case .other:
            L10n.text(
                "关闭窗口本身不会撤销授权；当前副本位置不标准，稳定复用授权前请先改用 /Applications 安装版。",
                "Closing the window itself does not revoke access; this copy is in a non-standard location, so use the /Applications install for stable access reuse."
            )
        }
    }

    var diagnosticsMarkdown: String {
        [
            "# \(L10n.text("存储清理助手诊断信息", "Storage Cleaner Diagnostics"))",
            "",
            "- \(L10n.text("当前版本", "Current Version")): \(versionDisplay)",
            "- Build: \(build?.nonEmpty ?? "-")",
            "- Bundle ID: \(bundleIdentifier)",
            "- \(L10n.text("运行位置", "Runtime")): \(kind.title)",
            "- \(L10n.text("运行路径", "Runtime Path")): \(path)",
            "- \(L10n.text("分发状态", "Distribution Status")): \(distributionStatus)",
            "- \(L10n.text("授权稳定性", "Access Stability")): \(authorizationStabilityStatus)",
            "- \(L10n.text("减少重复授权", "Reduce Repeated Prompts")): \(authorizationStabilityAction)",
            "- \(L10n.text("关闭窗口与授权", "Window Closing and Access")): \(authorizationWindowLifecycleNote)"
        ].joined(separator: "\n")
    }
}

enum AppRuntimeLocationService {
    static func current(bundle: Bundle = .main) -> AppRuntimeInfo {
        info(
            bundlePath: bundle.bundleURL.path,
            bundleIdentifier: bundle.bundleIdentifier,
            infoDictionary: bundle.infoDictionary,
            buildInfo: AppBuildInfo.load(bundle: bundle)
        )
    }

    static func info(
        bundlePath: String,
        bundleIdentifier: String?,
        infoDictionary: [String: Any]?,
        buildInfo: AppBuildInfo? = nil
    ) -> AppRuntimeInfo {
        AppRuntimeInfo(
            kind: kind(for: bundlePath),
            path: normalizedPath(bundlePath),
            bundleIdentifier: bundleIdentifier?.nonEmpty ?? "-",
            version: infoDictionary?["CFBundleShortVersionString"] as? String,
            build: infoDictionary?["CFBundleVersion"] as? String,
            buildInfo: buildInfo
        )
    }

    static func kind(for bundlePath: String) -> AppRuntimeLocationKind {
        let path = normalizedPath(bundlePath)
        if path.hasPrefix("/Applications/") {
            return .applications
        }
        if path.contains("/dist/") {
            return .developmentDist
        }
        if path.contains("/.build/") || path.contains("/DerivedData/") {
            return .buildProduct
        }
        return .other
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .path
    }
}
