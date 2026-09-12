import Foundation

enum LargeFileKind: String, CaseIterable, Identifiable, Sendable {
    case folder
    case video
    case installer
    case archive
    case document
    case image
    case audio
    case mailAttachment
    case developer
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: L10n.text("文件夹", "Folder")
        case .video: L10n.text("视频", "Video")
        case .installer: L10n.text("安装包", "Installer")
        case .archive: L10n.text("压缩包", "Archive")
        case .document: L10n.text("文稿", "Document")
        case .image: L10n.text("图片", "Image")
        case .audio: L10n.text("音频", "Audio")
        case .mailAttachment: L10n.text("邮件附件", "Mail Attachment")
        case .developer: L10n.text("开发文件", "Developer")
        case .other: L10n.text("其他", "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .folder: "folder.fill"
        case .video: "film.fill"
        case .installer: "shippingbox.fill"
        case .archive: "archivebox.fill"
        case .document: "doc.text.fill"
        case .image: "photo.fill"
        case .audio: "waveform"
        case .mailAttachment: "paperclip"
        case .developer: "hammer.fill"
        case .other: "doc.fill"
        }
    }

    var shortDescription: String {
        switch self {
        case .folder:
            L10n.text("按项目内容审查，优先归档或释放云端本地副本。", "Review by project contents; archive or free local cloud copies first.")
        case .video:
            L10n.text("通常适合转移到外置盘或云端归档。", "Usually good candidates for external or cloud archive.")
        case .installer:
            L10n.text("安装完成后多半可删除，保留近期需要回滚的版本。", "Often removable after install; keep recent rollback installers.")
        case .archive:
            L10n.text("确认已解压或备份后再处理。", "Review after confirming the contents are extracted or backed up.")
        case .document:
            L10n.text("先确认是否是工作资料或合同文档。", "Check whether these are work records or documents first.")
        case .image:
            L10n.text("适合按项目、照片库或云端备份整理。", "Good for project, photo library, or cloud-backup review.")
        case .audio:
            L10n.text("通常来自录音、音乐或导出素材。", "Often recordings, music, or exported media assets.")
        case .mailAttachment:
            L10n.text("可能仍可从邮件重新下载，删除前确认原邮件存在。", "May be downloadable from Mail again; confirm the original message first.")
        case .developer:
            L10n.text("可能影响项目构建，处理前确认项目仍可恢复。", "May affect builds; confirm the project can be restored first.")
        case .other:
            L10n.text("类型不明确，建议先定位查看。", "Unknown type; locate and inspect before cleanup.")
        }
    }

    static func classify(_ item: StorageItem) -> LargeFileKind {
        let pathExtension = URL(fileURLWithPath: item.path).pathExtension.lowercased()
        let text = [
            item.title,
            item.path,
            item.kind,
            item.groupTitle,
            item.sourceID
        ]
        .joined(separator: " ")
        .lowercased()

        if item.sourceID == "mail_attachments" {
            return .mailAttachment
        }

        if developerExtensions.contains(pathExtension)
            || text.contains("xcode")
            || text.contains("deriveddata")
            || text.contains("node_modules") {
            return .developer
        }

        if item.isDirectory {
            return .folder
        }

        if videoExtensions.contains(pathExtension) { return .video }
        if installerExtensions.contains(pathExtension) { return .installer }
        if archiveExtensions.contains(pathExtension) { return .archive }
        if documentExtensions.contains(pathExtension) { return .document }
        if imageExtensions.contains(pathExtension) { return .image }
        if audioExtensions.contains(pathExtension) { return .audio }

        if text.contains("installer") || text.contains("安装") {
            return .installer
        }
        if text.contains("archive") || text.contains("压缩") {
            return .archive
        }
        if text.contains("movie") || text.contains("video") || text.contains("影片") || text.contains("视频") {
            return .video
        }

        return .other
    }

    private static let videoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "mkv", "avi", "wmv", "flv", "webm", "mts", "m2ts"
    ]

    private static let installerExtensions: Set<String> = [
        "dmg", "pkg", "mpkg", "ipsw", "appinstaller"
    ]

    private static let archiveExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz", "iso"
    ]

    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "txt", "rtf", "csv"
    ]

    private static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "raw", "arw", "cr2", "nef", "dng", "psd"
    ]

    private static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aiff", "flac", "ogg", "caf"
    ]

    private static let developerExtensions: Set<String> = [
        "xcarchive", "xcodeproj", "xcworkspace", "framework", "simruntime", "a", "o"
    ]
}

enum LargeFileFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case folder
    case video
    case installer
    case archive
    case document
    case image
    case audio
    case mailAttachment
    case developer
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .folder: LargeFileKind.folder.title
        case .video: LargeFileKind.video.title
        case .installer: LargeFileKind.installer.title
        case .archive: LargeFileKind.archive.title
        case .document: LargeFileKind.document.title
        case .image: LargeFileKind.image.title
        case .audio: LargeFileKind.audio.title
        case .mailAttachment: LargeFileKind.mailAttachment.title
        case .developer: LargeFileKind.developer.title
        case .other: LargeFileKind.other.title
        }
    }

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .folder: LargeFileKind.folder.systemImage
        case .video: LargeFileKind.video.systemImage
        case .installer: LargeFileKind.installer.systemImage
        case .archive: LargeFileKind.archive.systemImage
        case .document: LargeFileKind.document.systemImage
        case .image: LargeFileKind.image.systemImage
        case .audio: LargeFileKind.audio.systemImage
        case .mailAttachment: LargeFileKind.mailAttachment.systemImage
        case .developer: LargeFileKind.developer.systemImage
        case .other: LargeFileKind.other.systemImage
        }
    }

    func includes(_ item: StorageItem) -> Bool {
        switch self {
        case .all:
            true
        case .folder:
            LargeFileKind.classify(item) == .folder
        case .video:
            LargeFileKind.classify(item) == .video
        case .installer:
            LargeFileKind.classify(item) == .installer
        case .archive:
            LargeFileKind.classify(item) == .archive
        case .document:
            LargeFileKind.classify(item) == .document
        case .image:
            LargeFileKind.classify(item) == .image
        case .audio:
            LargeFileKind.classify(item) == .audio
        case .mailAttachment:
            LargeFileKind.classify(item) == .mailAttachment
        case .developer:
            LargeFileKind.classify(item) == .developer
        case .other:
            LargeFileKind.classify(item) == .other
        }
    }
}

enum LargeFileSortMode: String, CaseIterable, Identifiable, Sendable {
    case size
    case name
    case kind
    case source
    case risk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: L10n.text("按大小", "Size")
        case .name: L10n.text("按名称", "Name")
        case .kind: L10n.text("按类型", "Kind")
        case .source: L10n.text("按来源", "Source")
        case .risk: L10n.text("按风险", "Risk")
        }
    }

    var systemImage: String {
        switch self {
        case .size: "arrow.down.circle"
        case .name: "textformat.abc"
        case .kind: "tag"
        case .source: "folder"
        case .risk: "shield.lefthalf.filled"
        }
    }
}

struct LargeFileKindSummary: Identifiable, Sendable {
    let kind: LargeFileKind
    let count: Int
    let bytes: Int64

    var id: LargeFileKind { kind }
}

enum LargeFilePresenter {
    static func availableFilters(for items: [StorageItem]) -> [LargeFileFilter] {
        LargeFileFilter.allCases.filter { filter in
            filter == .all || items.contains { filter.includes($0) }
        }
    }

    static func visibleItems(
        from items: [StorageItem],
        query: String,
        filter: LargeFileFilter,
        sortMode: LargeFileSortMode
    ) -> [StorageItem] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredItems = items.filter { filter.includes($0) }
        let searchedItems: [StorageItem]

        if trimmedQuery.isEmpty {
            searchedItems = filteredItems
        } else {
            searchedItems = filteredItems.filter { item in
                let kind = LargeFileKind.classify(item)
                return item.title.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.path.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.kind.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.groupTitle.localizedCaseInsensitiveContains(trimmedQuery)
                    || item.sourceID.localizedCaseInsensitiveContains(trimmedQuery)
                    || kind.title.localizedCaseInsensitiveContains(trimmedQuery)
            }
        }

        return sort(searchedItems, by: sortMode)
    }

    static func summaries(for items: [StorageItem]) -> [LargeFileKindSummary] {
        Dictionary(grouping: items, by: LargeFileKind.classify)
            .map { kind, items in
                LargeFileKindSummary(
                    kind: kind,
                    count: items.count,
                    bytes: items.reduce(0) { $0 + $1.sizeBytes }
                )
            }
            .sorted { lhs, rhs in
                if lhs.bytes == rhs.bytes {
                    return lhs.kind.title.localizedStandardCompare(rhs.kind.title) == .orderedAscending
                }
                return lhs.bytes > rhs.bytes
            }
    }

    static func sourceTitle(for item: StorageItem) -> String {
        switch item.sourceID {
        case "large_files":
            L10n.text("用户文件", "User Files")
        case "downloads":
            L10n.text("下载目录", "Downloads")
        case "mail_attachments":
            L10n.text("邮件附件", "Mail Attachments")
        default:
            item.groupTitle.isEmpty ? item.sourceID : item.groupTitle
        }
    }

    private static func sort(_ items: [StorageItem], by sortMode: LargeFileSortMode) -> [StorageItem] {
        items.sorted { lhs, rhs in
            switch sortMode {
            case .size:
                if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                return lhs.sizeBytes > rhs.sizeBytes
            case .name:
                return compareTitle(lhs, rhs)
            case .kind:
                let lhsKind = LargeFileKind.classify(lhs).title
                let rhsKind = LargeFileKind.classify(rhs).title
                let order = lhsKind.localizedStandardCompare(rhsKind)
                if order == .orderedSame {
                    if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return order == .orderedAscending
            case .source:
                let order = sourceTitle(for: lhs).localizedStandardCompare(sourceTitle(for: rhs))
                if order == .orderedSame {
                    if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return order == .orderedAscending
            case .risk:
                if lhs.tier.sortRank == rhs.tier.sortRank {
                    if lhs.sizeBytes == rhs.sizeBytes { return compareTitle(lhs, rhs) }
                    return lhs.sizeBytes > rhs.sizeBytes
                }
                return lhs.tier.sortRank < rhs.tier.sortRank
            }
        }
    }

    private static func compareTitle(_ lhs: StorageItem, _ rhs: StorageItem) -> Bool {
        lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}
