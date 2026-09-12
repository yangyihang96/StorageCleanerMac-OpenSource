import Foundation

struct StorageMapScanTarget: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case internalVolume
        case homeDirectory
        case externalVolume
    }

    let id: String
    let path: String
    let title: String
    let kind: Kind

    init(path: String, title: String, kind: Kind) {
        let normalizedPath = PathSafety.lexicalPath(path)
        self.id = normalizedPath
        self.path = normalizedPath
        self.title = title
        self.kind = kind
    }

    var systemImage: String {
        switch kind {
        case .internalVolume:
            "internaldrive.fill"
        case .homeDirectory:
            "house.fill"
        case .externalVolume:
            "externaldrive.fill"
        }
    }
}

struct StorageMapScanProgress: Equatable, Sendable {
    let currentPath: String
    let inspectedItemCount: Int
    let measuredBytes: Int64
}

enum StorageMapContentCategory: String, CaseIterable, Hashable, Sendable {
    case application
    case image
    case video
    case audio
    case document
    case archive
    case developer
    case data
    case system
    case other

    var title: String {
        switch self {
        case .application:
            L10n.text("应用与安装包", "Apps & Installers")
        case .image:
            L10n.text("图片", "Images")
        case .video:
            L10n.text("视频", "Video")
        case .audio:
            L10n.text("音频", "Audio")
        case .document:
            L10n.text("文档", "Documents")
        case .archive:
            L10n.text("压缩与磁盘映像", "Archives & Disk Images")
        case .developer:
            L10n.text("代码与开发文件", "Code & Developer Files")
        case .data:
            L10n.text("数据", "Data")
        case .system:
            L10n.text("系统与配置", "System & Configuration")
        case .other:
            L10n.text("其他", "Other")
        }
    }

    var systemImage: String {
        switch self {
        case .application: "app.fill"
        case .image: "photo.fill"
        case .video: "film.fill"
        case .audio: "music.note"
        case .document: "doc.text.fill"
        case .archive: "archivebox.fill"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .data: "cylinder.split.1x2.fill"
        case .system: "gearshape.2.fill"
        case .other: "doc.fill"
        }
    }

    static func classify(name: String, kind: String, isDirectory: Bool) -> Self {
        let normalizedKind = kind.lowercased()
        let extensionName = genericKinds.contains(normalizedKind)
            ? (name as NSString).pathExtension.lowercased()
            : normalizedKind
        let normalizedDeveloperFileName = extensionName.isEmpty || extensionName == "txt"
            ? name.lowercased()
            : nil

        if normalizedKind == "package" {
            let packageExtension = (name as NSString).pathExtension.lowercased()
            if imagePackageExtensions.contains(packageExtension) { return .image }
            if videoPackageExtensions.contains(packageExtension) { return .video }
            if audioPackageExtensions.contains(packageExtension) { return .audio }
            if documentPackageExtensions.contains(packageExtension) { return .document }
            if developerPackageExtensions.contains(packageExtension) { return .developer }
            if applicationExtensions.contains(packageExtension) { return .application }
            return .other
        }
        if applicationExtensions.contains(extensionName) {
            return .application
        }
        if isDirectory { return .other }
        if developerExtensions.contains(extensionName)
            || normalizedDeveloperFileName.map(developerFileNames.contains) == true {
            return .developer
        }
        if imageExtensions.contains(extensionName) { return .image }
        if videoExtensions.contains(extensionName) { return .video }
        if audioExtensions.contains(extensionName) { return .audio }
        if documentExtensions.contains(extensionName) { return .document }
        if archiveExtensions.contains(extensionName) { return .archive }
        if dataExtensions.contains(extensionName) { return .data }
        if systemExtensions.contains(extensionName)
            || name.hasPrefix(".")
            || normalizedKind == "alias" {
            return .system
        }
        return .other
    }

    private static let genericKinds: Set<String> = [
        "", "file", "folder", "document", "aggregate", "unavailable", "excluded",
    ]
    private static let applicationExtensions: Set<String> = [
        "app", "appex", "bundle", "component", "mdimporter", "pkg", "plugin", "prefpane",
    ]
    private static let imagePackageExtensions: Set<String> = [
        "aplibrary", "photolibrary", "photoslibrary",
    ]
    private static let videoPackageExtensions: Set<String> = [
        "fcpevent", "fcpproject", "fcpbundle", "imovielibrary", "motiontemplate",
    ]
    private static let audioPackageExtensions: Set<String> = [
        "band", "logicx", "musiclibrary",
    ]
    private static let documentPackageExtensions: Set<String> = [
        "epub", "key", "numbers", "pages", "rtfd",
    ]
    private static let developerPackageExtensions: Set<String> = [
        "playground", "playgroundbook", "swiftpm", "xcodeproj", "xcworkspace",
    ]
    private static let imageExtensions: Set<String> = [
        "arw", "avif", "bmp", "cr2", "dng", "gif", "heic", "heif", "ico", "jpeg", "jpg",
        "nef", "orf", "png", "psd", "raw", "svg", "tif", "tiff", "webp",
    ]
    private static let videoExtensions: Set<String> = [
        "3gp", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts",
        "vob", "webm", "wmv",
    ]
    private static let audioExtensions: Set<String> = [
        "aac", "aiff", "alac", "caf", "flac", "m4a", "m4b", "mid", "midi", "mp3", "ogg",
        "opus", "wav", "wma",
    ]
    private static let documentExtensions: Set<String> = [
        "doc", "docx", "epub", "key", "md", "numbers", "odf", "odp", "ods", "odt", "pages",
        "pdf", "ppt", "pptx", "rtf", "rtfd", "tex", "txt", "xls", "xlsx",
    ]
    private static let archiveExtensions: Set<String> = [
        "7z", "bz2", "cab", "dmg", "gz", "iso", "rar", "tar", "tbz", "tgz", "xz", "zip",
        "zst",
    ]
    private static let developerExtensions: Set<String> = [
        "c", "cc", "cpp", "cs", "css", "dart", "go", "gradle", "h", "hpp", "html", "java",
        "js", "jsx", "kt", "kts", "m", "mm", "php", "playground", "py", "rb", "rs", "scss",
        "sh", "sql", "storyboard", "swift", "tsx", "ts", "vue", "xcconfig", "xcodeproj",
        "xcworkspace", "xib", "zsh",
    ]
    private static let developerFileNames: Set<String> = [
        "cmakelists.txt", "dockerfile", "gemfile", "makefile", "package.swift", "podfile",
    ]
    private static let dataExtensions: Set<String> = [
        "arrow", "csv", "db", "json", "jsonl", "ndjson", "parquet", "realm", "sqlite", "sqlite3",
        "tsv", "xml", "yaml", "yml",
    ]
    private static let systemExtensions: Set<String> = [
        "cache", "conf", "dylib", "framework", "ini", "kext", "lock", "log", "plist", "so", "tmp",
    ]
}

/// Fixed-width counters avoid allocating a dictionary for every indexed folder.
/// The profile is merged bottom-up with the existing directory index, so folder
/// colors describe their contents without a second file-system walk.
struct StorageMapContentProfile: Equatable, Sendable {
    private var applicationBytes: Int64 = 0
    private var imageBytes: Int64 = 0
    private var videoBytes: Int64 = 0
    private var audioBytes: Int64 = 0
    private var documentBytes: Int64 = 0
    private var archiveBytes: Int64 = 0
    private var developerBytes: Int64 = 0
    private var dataBytes: Int64 = 0
    private var systemBytes: Int64 = 0
    private var otherBytes: Int64 = 0

    init(category: StorageMapContentCategory? = nil, bytes: Int64 = 0) {
        if let category {
            add(bytes: bytes, to: category)
        }
    }

    mutating func add(bytes rawBytes: Int64, to category: StorageMapContentCategory) {
        let bytes = max(0, rawBytes)
        guard bytes > 0 else { return }
        switch category {
        case .application: applicationBytes += bytes
        case .image: imageBytes += bytes
        case .video: videoBytes += bytes
        case .audio: audioBytes += bytes
        case .document: documentBytes += bytes
        case .archive: archiveBytes += bytes
        case .developer: developerBytes += bytes
        case .data: dataBytes += bytes
        case .system: systemBytes += bytes
        case .other: otherBytes += bytes
        }
    }

    mutating func merge(_ other: StorageMapContentProfile) {
        applicationBytes += other.applicationBytes
        imageBytes += other.imageBytes
        videoBytes += other.videoBytes
        audioBytes += other.audioBytes
        documentBytes += other.documentBytes
        archiveBytes += other.archiveBytes
        developerBytes += other.developerBytes
        dataBytes += other.dataBytes
        systemBytes += other.systemBytes
        otherBytes += other.otherBytes
    }

    func bytes(for category: StorageMapContentCategory) -> Int64 {
        switch category {
        case .application: applicationBytes
        case .image: imageBytes
        case .video: videoBytes
        case .audio: audioBytes
        case .document: documentBytes
        case .archive: archiveBytes
        case .developer: developerBytes
        case .data: dataBytes
        case .system: systemBytes
        case .other: otherBytes
        }
    }

    var dominantCategory: StorageMapContentCategory {
        var winner = StorageMapContentCategory.other
        var winnerBytes: Int64 = 0
        for category in StorageMapContentCategory.allCases {
            let candidateBytes = bytes(for: category)
            if candidateBytes > winnerBytes {
                winner = category
                winnerBytes = candidateBytes
            }
        }
        return winner
    }
}

struct StorageMapDirectoryAggregate: Equatable, Sendable {
    var sizeBytes: Int64 = 0
    var immediateChildCount: Int = 0
    var descendantItemCount: Int = 0
    var isComplete = true
    var contentProfile = StorageMapContentProfile()

    var dominantContentCategory: StorageMapContentCategory {
        contentProfile.dominantCategory
    }
}

struct StorageMapIndexedEntry: Equatable, Sendable {
    let name: String
    let kind: String
    /// The byte count used by the storage-map presentation. Ordinary files use
    /// allocated bytes, while application-bundle contents use logical bytes to
    /// match Finder-style app sizing without inflating sparse or cloud files.
    let sizeBytes: Int64?
    let isDirectory: Bool
    let canDescend: Bool
    let isEstimated: Bool
}

struct StorageMapAnalysisIndex: Equatable, Sendable {
    let rootPath: String
    let rootVolumeIdentifier: String?
    let directories: [String: StorageMapDirectoryAggregate]
    let childrenByDirectory: [String: [StorageMapIndexedEntry]]
    let blockedDirectoryPaths: Set<String>
    let duplicateFilePaths: Set<String>
}

struct StorageMapAnalysisResult: Equatable, Sendable {
    let target: StorageMapScanTarget
    let volumeTotalBytes: Int64
    let volumeAvailableBytes: Int64
    let inspectedItemCount: Int
    let omittedItemCount: Int
    let scanSeconds: TimeInterval
    let index: StorageMapAnalysisIndex
    let rootSnapshot: StorageMapDirectorySnapshot

    var usedVolumeBytes: Int64 {
        max(0, volumeTotalBytes - volumeAvailableBytes)
    }
}

enum StorageTreemapEntryRole: Equatable, Sendable {
    case content
    case measuredRemainder
    case unmeasuredRemainder
}

struct StorageTreemapEntry: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let path: String
    let sizeBytes: Int64
    let kind: String
    let isDirectory: Bool
    let canDescend: Bool
    let childCount: Int?
    let isEstimated: Bool
    let contentCategory: StorageMapContentCategory
    let role: StorageTreemapEntryRole

    init(
        id: String,
        title: String,
        path: String,
        sizeBytes: Int64,
        kind: String,
        isDirectory: Bool,
        canDescend: Bool? = nil,
        childCount: Int? = nil,
        isEstimated: Bool = false,
        contentCategory: StorageMapContentCategory? = nil,
        role: StorageTreemapEntryRole = .content
    ) {
        self.id = id
        self.title = title
        self.path = path
        self.sizeBytes = sizeBytes
        self.kind = kind
        self.isDirectory = isDirectory
        self.canDescend = canDescend ?? isDirectory
        self.childCount = childCount
        self.isEstimated = isEstimated
        self.contentCategory = contentCategory ?? StorageMapContentCategory.classify(
            name: title,
            kind: kind,
            isDirectory: isDirectory
        )
        self.role = role
    }
}

struct StorageMapDirectorySnapshot: Equatable, Sendable {
    let path: String
    let title: String
    let entries: [StorageTreemapEntry]
    let measuredBytes: Int64
    let referenceBytes: Int64
    let referenceIsEstimated: Bool
    let inspectedItemCount: Int
    let omittedEntryCount: Int
    let isComplete: Bool

    init(
        path: String,
        title: String,
        entries: [StorageTreemapEntry],
        measuredBytes: Int64,
        referenceBytes: Int64? = nil,
        referenceIsEstimated: Bool? = nil,
        inspectedItemCount: Int,
        omittedEntryCount: Int,
        isComplete: Bool
    ) {
        let normalizedMeasuredBytes = max(0, measuredBytes)
        self.path = path
        self.title = title
        self.entries = entries
        self.measuredBytes = normalizedMeasuredBytes
        self.referenceBytes = max(normalizedMeasuredBytes, referenceBytes ?? normalizedMeasuredBytes)
        self.referenceIsEstimated = referenceIsEstimated ?? !isComplete
        self.inspectedItemCount = inspectedItemCount
        self.omittedEntryCount = omittedEntryCount
        self.isComplete = isComplete
    }

    var unmeasuredBytes: Int64 {
        max(0, referenceBytes - measuredBytes)
    }

    func referenced(totalBytes: Int64, isEstimated: Bool) -> StorageMapDirectorySnapshot {
        let normalizedReference = max(0, totalBytes)
        let measuredValueWins = measuredBytes > normalizedReference
        return StorageMapDirectorySnapshot(
            path: path,
            title: title,
            entries: entries,
            measuredBytes: measuredBytes,
            referenceBytes: max(measuredBytes, normalizedReference),
            referenceIsEstimated: measuredValueWins ? !isComplete : isEstimated,
            inspectedItemCount: inspectedItemCount,
            omittedEntryCount: omittedEntryCount,
            isComplete: isComplete
        )
    }
}

enum StorageMapBrowsePhase: Equatable, Sendable {
    case idle
    case loading(path: String, title: String, referenceBytes: Int64, referenceIsEstimated: Bool)
    case failed(
        path: String,
        title: String,
        referenceBytes: Int64,
        referenceIsEstimated: Bool,
        message: String
    )

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}

enum StorageMapEntryFilter: String, CaseIterable, Hashable, Identifiable, Sendable {
    case all
    case directories
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: L10n.text("全部", "All")
        case .directories: L10n.text("文件夹", "Folders")
        case .files: L10n.text("文件", "Files")
        }
    }
}

enum StorageMapEntrySort: String, CaseIterable, Hashable, Identifiable, Sendable {
    case sizeDescending
    case sizeAscending
    case nameAscending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sizeDescending: L10n.text("大小：从大到小", "Size: Largest First")
        case .sizeAscending: L10n.text("大小：从小到大", "Size: Smallest First")
        case .nameAscending: L10n.text("名称", "Name")
        }
    }
}

enum StorageTreemapPresentation {
    static func navigationLevel(
        for entry: StorageTreemapEntry,
        in navigation: [StorageMapDirectorySnapshot],
        fallback: Int
    ) -> Int {
        navigation.firstIndex { snapshot in
            snapshot.entries.contains { $0.id == entry.id && $0.path == entry.path }
        } ?? fallback
    }

    /// Filters only the supplied directory's list. The captured snapshot and
    /// the map's byte totals remain the source of truth for geometry and shares.
    static func filteredEntries(
        from entries: [StorageTreemapEntry],
        query: String = "",
        filter: StorageMapEntryFilter = .all,
        sort: StorageMapEntrySort = .sizeDescending
    ) -> [StorageTreemapEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            let matchesType = switch filter {
            case .all: true
            case .directories: entry.isDirectory
            case .files: !entry.isDirectory
            }
            return matchesType && (query.isEmpty
                || entry.title.localizedStandardContains(query)
                || entry.path.localizedStandardContains(query))
        }.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes {
                switch sort {
                case .sizeDescending: return lhs.sizeBytes > rhs.sizeBytes
                case .sizeAscending: return lhs.sizeBytes < rhs.sizeBytes
                case .nameAscending: break
                }
            }
            let nameOrder = lhs.title.localizedStandardCompare(rhs.title)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            let pathOrder = lhs.path.localizedStandardCompare(rhs.path)
            if pathOrder != .orderedSame { return pathOrder == .orderedAscending }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            if lhs.title != rhs.title { return lhs.title < rhs.title }
            return lhs.id < rhs.id
        }
    }

    static func entries(from items: [StorageItem], limit: Int = 24) -> [StorageTreemapEntry] {
        guard limit > 0 else { return [] }
        return items
            .filter { $0.sizeBytes > 0 }
            .sorted(by: entryOrdering)
            .prefix(limit)
            .map {
                StorageTreemapEntry(
                    id: $0.id,
                    title: $0.title,
                    path: $0.openPath.nonEmpty ?? $0.path,
                    sizeBytes: $0.sizeBytes,
                    kind: $0.kind,
                    isDirectory: $0.isDirectory
                )
            }
    }

    static func visibleEntries(
        from snapshot: StorageMapDirectorySnapshot,
        limit: Int = .max
    ) -> [StorageTreemapEntry] {
        guard limit > 0 else { return [] }
        return Array(snapshot.entries.prefix(limit))
    }

    static func mapEntries(
        from entries: [StorageTreemapEntry],
        limit: Int = 18
    ) -> [StorageTreemapEntry] {
        guard limit > 0 else { return [] }
        return Array(entries.filter { $0.sizeBytes > 0 }.prefix(limit))
    }

    static func mapLayoutEntries(
        from entries: [StorageTreemapEntry],
        measuredBytes: Int64,
        referenceBytes: Int64,
        limit: Int = 18
    ) -> [StorageTreemapEntry] {
        var result = mapEntries(from: entries, limit: limit)
        let visibleBytes = result.reduce(Int64(0)) { $0 + max(0, $1.sizeBytes) }
        let normalizedMeasuredBytes = max(visibleBytes, measuredBytes)
        let normalizedReferenceBytes = max(normalizedMeasuredBytes, referenceBytes)
        let measuredRemainderBytes = max(0, normalizedMeasuredBytes - visibleBytes)
        let unmeasuredRemainderBytes = max(0, normalizedReferenceBytes - normalizedMeasuredBytes)

        if measuredRemainderBytes > 0 {
            result.append(StorageTreemapEntry(
                id: "storage-map-measured-remainder",
                title: L10n.text("其他已测项目", "Other Measured Items"),
                path: "",
                sizeBytes: measuredRemainderBytes,
                kind: "aggregate",
                isDirectory: false,
                role: .measuredRemainder
            ))
        }

        if unmeasuredRemainderBytes > 0 {
            result.append(StorageTreemapEntry(
                id: "storage-map-unmeasured-remainder",
                title: L10n.text("尚未完成测量", "Measurement Incomplete"),
                path: "",
                sizeBytes: unmeasuredRemainderBytes,
                kind: "aggregate",
                isDirectory: false,
                role: .unmeasuredRemainder
            ))
        }

        return result
    }

    static func displaySize(for entry: StorageTreemapEntry) -> String {
        let size = ByteFormat.storageString(entry.sizeBytes)
        return entry.isEstimated
            ? L10n.text("至少 \(size)", "At least \(size)")
            : size
    }

    private static func entryOrdering(_ lhs: StorageItem, _ rhs: StorageItem) -> Bool {
        if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// Angular areas preserve the captured byte totals at every directory level.
enum StorageSunburstLayout {
    struct Segment: Identifiable {
        let entry: StorageTreemapEntry
        let depth: Int
        let start: Double
        let end: Double
        let share: Double
        var id: String { "\(depth):\(start):\(entry.id)" }
        var innerRadiusFraction: Double { 0.28 + Double(depth) * 0.24 }
        var outerRadiusFraction: Double { 0.52 + Double(depth) * 0.24 }

        func contains(_ point: CGPoint, center: CGPoint, radius: Double) -> Bool {
            guard radius.isFinite, radius > 0, point.x.isFinite, point.y.isFinite else { return false }
            let x = point.x - center.x
            let y = point.y - center.y
            let distance = hypot(x, y) / radius
            guard distance >= innerRadiusFraction, distance < outerRadiusFraction else { return false }
            let turn = 2 * Double.pi
            let angle = (atan2(y, x) - start).truncatingRemainder(dividingBy: turn)
            return (angle < 0 ? angle + turn : angle) < end - start
        }
    }

    static func segment(
        at point: CGPoint,
        center: CGPoint,
        radius: Double,
        in segments: [Segment]
    ) -> Segment? {
        segments.first { $0.contains(point, center: center, radius: radius) }
    }

    static func segments(
        entries: [StorageTreemapEntry],
        children: (StorageTreemapEntry) -> [StorageTreemapEntry]
    ) -> [Segment] {
        var result: [Segment] = []
        func append(_ entries: [StorageTreemapEntry], depth: Int, start: Double, span: Double, share: Double) {
            let positive = entries.filter { $0.sizeBytes > 0 }
            let total = positive.reduce(0.0) { $0 + Double($1.sizeBytes) }
            guard total > 0, total.isFinite else { return }
            var cursor = start
            for entry in positive {
                let fraction = Double(entry.sizeBytes) / total
                let end = cursor + span * fraction
                result.append(Segment(entry: entry, depth: depth, start: cursor, end: end, share: share * fraction))
                // ponytail: three visible levels; navigate into a folder for deeper levels.
                if depth < 2, entry.canDescend {
                    append(children(entry), depth: depth + 1, start: cursor, span: end - cursor, share: share * fraction)
                }
                cursor = end
            }
        }
        append(entries, depth: 0, start: -.pi / 2, span: 2 * .pi, share: 1)
        return result
    }
}
