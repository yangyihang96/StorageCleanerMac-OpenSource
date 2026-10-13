import Darwin
import Foundation

/// 第 4／5 轮裁定：`.app` 的包类型不决定它是否是应用；在包内找到普通
/// 可执行文件才算应用。名字沿用 CFBundle 的规则：取 CFBundleExecutable，
/// 没写或 plist 解析失败则用去掉 `.app` 的包名。子路径逐级核对，不跟随
/// 链接、不下载；无权限、仅云端、过大或链接等不确定情况仍按应用挡住。
/// 扫描分类和移到废纸篓规则共用，只在主线程以外调用。
enum FileAnalysisApplicationBundleProbe {
    static let maximumInfoPlistBytes = 1 << 20

    private enum Layout {
        case contents, resources, supportFiles, flat

        var infoDirectory: String {
            switch self {
            case .contents: "Contents"
            case .resources: "Resources"
            case .supportFiles: "Support Files"
            case .flat: "."
            }
        }

        var executableDirectories: [[String]] {
            let base: [String]
            switch self {
            case .contents: base = ["Contents"]
            case .supportFiles: base = ["Support Files", "Executables"]
            case .flat: base = []
            case .resources: return [[]] // 旧式 Resources 布局只在包根查找。
            }
            // 与 CFBundle 在 macOS 的候选顺序一致；每一处都受包根边界约束。
            let platforms = ["MacOS", "Mac OS X", "MacOSClassic", "Mac OS 8"]
            return platforms.map { base + [$0] } + [base] + (base.isEmpty ? [] : [[]])
        }
    }

    static func isApplication(atPath path: String) -> Bool {
        isApplication(atPath: path, beforeOpeningInfoPlist: {})
    }

    /// 测试可在元数据检查和打开之间替换 plist，复现换成 FIFO 的竞态。
    static func isApplication(atPath path: String, beforeOpeningInfoPlist: () -> Void) -> Bool {
        var status = stat()
        guard Darwin.lstat(path, &status) == 0 else { return errno != ENOENT }
        switch status.st_mode & S_IFMT {
        case S_IFDIR: break
        case S_IFLNK: return true
        default: return false
        }
        if status.st_flags & UInt32(SF_DATALESS) != 0 { return true }
        let bundle = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard bundle >= 0 else { return true }
        defer { close(bundle) }
        guard let bundleLayout = layout(inBundle: bundle) else { return true }
        let directory = openat(bundle, bundleLayout.infoDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard directory >= 0 else { return true }
        defer { close(directory) }
        guard fstat(directory, &status) == 0, status.st_flags & UInt32(SF_DATALESS) == 0 else { return true }

        var info: [String: Any]?
        if fstatat(directory, "Info.plist", &status, AT_SYMLINK_NOFOLLOW) == 0 {
            if status.st_flags & UInt32(SF_DATALESS) != 0 { return true }
            switch status.st_mode & S_IFMT {
            case S_IFLNK: return true
            case S_IFREG:
                if status.st_size > maximumInfoPlistBytes { return true }
                beforeOpeningInfoPlist()
                let descriptor = openat(directory, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard descriptor >= 0 else { return true }
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                // 打开后的类型、占位和大小再核对；检查后换成 FIFO 不阻塞，也不读取。
                var opened = stat()
                guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
                      opened.st_dev == status.st_dev, opened.st_ino == status.st_ino,
                      opened.st_flags & UInt32(SF_DATALESS) == 0,
                      opened.st_size <= maximumInfoPlistBytes else { return true }
                guard let data = try? handle.read(upToCount: maximumInfoPlistBytes + 1),
                      data.count <= maximumInfoPlistBytes else { return true }
                info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
            default: break // 目录、FIFO 等不打开，继续用包名后备查找。
            }
        } else if errno != ENOENT {
            return true
        }
        let named = info?["CFBundleExecutable"] as? String
        let executable = named.flatMap { $0.isEmpty ? nil : $0 }
            ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return bundleLayout.executableDirectories.contains {
            hasExecutable(executable, relativeTo: $0, inBundle: bundle)
        }
    }

    /// `.app` 的布局优先级；不用会跟随链接的 Bundle／URL 查询。
    /// nil 代表无法安全确认，调用方保守按应用处理。
    private static func layout(inBundle bundle: Int32) -> Layout? {
        for layout in [Layout.contents, .resources, .supportFiles] {
            var status = stat()
            guard fstatat(bundle, layout.infoDirectory, &status, AT_SYMLINK_NOFOLLOW) == 0 else {
                if errno == ENOENT { continue }
                return nil
            }
            if status.st_flags & UInt32(SF_DATALESS) != 0 { return nil }
            switch status.st_mode & S_IFMT {
            case S_IFDIR: return layout
            case S_IFLNK: return nil
            default: continue
            }
        }
        return .flat
    }

    private static func hasExecutable(_ executable: String, relativeTo base: [String], inBundle bundle: Int32) -> Bool {
        guard !executable.isEmpty, !executable.hasPrefix("/"), !executable.contains("\0") else { return false }
        // 先做词法解析，再从已打开的包根逐级核对；不对文件系统使用 ..，
        // 也不因目录在检查中被移走而走出包根。
        var path = base
        for component in executable.split(separator: "/").map(String.init) {
            if component == ".." {
                guard !path.isEmpty else { return false }
                path.removeLast()
            } else if component != "." {
                path.append(component)
            }
        }
        guard !path.isEmpty else { return false }
        var directory = dup(bundle)
        guard directory >= 0 else { return true }
        defer { close(directory) }
        for (index, component) in path.enumerated() {
            var status = stat()
            guard fstatat(directory, component, &status, AT_SYMLINK_NOFOLLOW) == 0 else { return errno != ENOENT }
            switch status.st_mode & S_IFMT {
            case S_IFLNK: return true
            case S_IFREG: return index == path.count - 1
            case S_IFDIR:
                if index == path.count - 1 { return false }
                if status.st_flags & UInt32(SF_DATALESS) != 0 { return true }
                let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                guard next >= 0 else { return true }
                close(directory)
                directory = next
            default: return false
            }
        }
        return false
    }
}
