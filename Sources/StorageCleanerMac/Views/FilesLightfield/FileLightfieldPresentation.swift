import Foundation
import SwiftUI

/// The approved seven categories aggregate existing measured profiles only.
enum LightfieldFileCategory: String, CaseIterable, Identifiable, Sendable {
    case application, system, developer, media, archive, document, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .application: L10n.text("应用", "Apps")
        case .system: L10n.text("系统", "System")
        case .developer: L10n.text("代码", "Code")
        case .media: L10n.text("媒体", "Media")
        case .archive: L10n.text("归档", "Archives")
        case .document: L10n.text("文档", "Documents")
        case .other: L10n.text("其他", "Other")
        }
    }
    var icon: LightfieldOptionIcon {
        switch self {
        case .application: .migrationApplication
        case .media: .fileanalysisMedia
        case .archive: .fileanalysisArchives
        case .document: .fileanalysisDocuments
        case .system, .developer, .other: .fileanalysisOther
        }
    }
    static func category(_ value: StorageMapContentCategory) -> Self {
        switch value {
        case .application: .application
        case .system: .system
        case .developer: .developer
        case .image, .video, .audio: .media
        case .archive: .archive
        case .document: .document
        case .data, .other: .other
        }
    }
}

enum FileLightfieldPresentation {
    static func sum(_ values: [Int64]) -> Int64 {
        values.reduce(0) { total, value in
            let result = total.addingReportingOverflow(max(0, value))
            return result.overflow ? .max : result.partialValue
        }
    }
    static func amount(_ bytes: Int64) -> (String, String) {
        let formatted = ByteFormat.storageString(bytes)
        let parsed = FeatureLightfieldAmount.parse(formatted)
        guard let value = parsed.value else { return (formatted, "") }
        return (String(format: "%.*f", parsed.precision, value), parsed.unit)
    }
    static func scopeIcon(_ kind: StorageMapScanTarget.Kind) -> LightfieldOptionIcon {
        switch kind {
        case .homeDirectory: .fileanalysisDocuments
        case .internalVolume: .migrationDestinationDrive
        case .externalVolume: .duplicatesExternalVolume
        }
    }
    static func types(_ result: StorageMapAnalysisResult) -> [LightfieldChartItem] {
        guard let profile = result.index.directories[result.index.rootPath]?.contentProfile else { return [] }
        return LightfieldFileCategory.allCases.compactMap { category in
            let bytes = sum(StorageMapContentCategory.allCases.filter {
                LightfieldFileCategory.category($0) == category
            }.map { profile.bytes(for: $0) })
            guard bytes > 0 else { return nil }
            return LightfieldChartItem(id: category.id, label: category.title, value: Double(bytes),
                formattedValue: ByteFormat.storageString(bytes), module: .largeFiles,
                icon: category.icon, color: FeatureLightfieldPalette.fileType(category),
                detail: category.title + " · " + ByteFormat.storageString(bytes))
        }
    }
    /// Complete index count, rather than inspectedItemCount (which includes directories).
    static func fileCount(_ index: StorageMapAnalysisIndex) -> Int {
        index.childrenByDirectory.values.reduce(0) { $0 + $1.filter { !$0.isDirectory }.count }
    }
    static func largest(_ index: StorageMapAnalysisIndex) -> [StorageTreemapEntry] {
        index.childrenByDirectory.flatMap { parent, children in
            children.compactMap { indexed -> StorageTreemapEntry? in
                let path = (parent as NSString).appendingPathComponent(indexed.name)
                guard !indexed.isDirectory, let bytes = indexed.sizeBytes, bytes > 0,
                      !index.duplicateFilePaths.contains(path) else { return nil }
                return StorageTreemapEntry(id: path, title: indexed.name, path: path, sizeBytes: bytes,
                    kind: indexed.kind, isDirectory: false, canDescend: false,
                    isEstimated: indexed.isEstimated, isCloudOnly: indexed.isCloudOnly)
            }
        }.sorted {
            $0.sizeBytes == $1.sizeBytes ? $0.path < $1.path : $0.sizeBytes > $1.sizeBytes
        }.prefix(8).map { $0 }
    }
    static func chart(_ entry: StorageTreemapEntry) -> LightfieldChartItem {
        let type = LightfieldFileCategory.category(entry.contentCategory)
        let bytes = ByteFormat.storageString(entry.sizeBytes)
        return .init(id: entry.id, label: entry.title, value: Double(entry.sizeBytes), formattedValue: bytes,
            module: .largeFiles, icon: entry.isDirectory ? .migrationSourceFolder : type.icon,
            color: FeatureLightfieldPalette.fileType(type), detail: entry.path + " · " + type.title + " · " + bytes
                + (entry.isEstimated ? L10n.text(" · 估算", " · Estimated") : "")
                + (entry.canDescend ? L10n.text(" · 点击进入", " · Open folder") : L10n.text(" · 点击选择", " · Select item")))
    }
}

enum LightfieldMigrationGrouping: Int, CaseIterable, Sendable {
    case type, modified, location
    var title: String {
        switch self {
        case .type: L10n.text("按类型", "By Type")
        case .modified: L10n.text("按修改时间", "By Modified Date")
        case .location: L10n.text("按位置", "By Location")
        }
    }
}

struct LightfieldMigrationEntry: Identifiable, Sendable {
    let item: ExternalMigrationItem
    /// nil stays unknown: no synchronous file probing in view bodies.
    var modifiedAt: Date? = nil
    var id: String { item.id }
    var category: StorageMapContentCategory {
        item.kind == .application ? .application : .classify(name: item.title, kind: "file", isDirectory: false)
    }
    var icon: LightfieldOptionIcon {
        switch category {
        case .video: .duplicatesVideos
        case .image: .duplicatesPhotos
        case .audio: .duplicatesAudio
        default: LightfieldFileCategory.category(category).icon
        }
    }
}

struct LightfieldMigrationGroup: Identifiable {
    let id: String
    let title: String
    let icon: LightfieldOptionIcon
    let entries: [LightfieldMigrationEntry]
    var bytes: Int64 { FileLightfieldPresentation.sum(entries.map { $0.item.sizeBytes }) }
}

/// Eligibility is independent of row rendering. Cache the set and selected
/// entries once so selection checks in the lazy list are constant-time.
struct LightfieldMigrationSelection {
    let eligibleIDs: Set<String>
    let entries: [LightfieldMigrationEntry]
    let bytes: Int64

    static func make(entries: [LightfieldMigrationEntry], completedIDs: Set<String>, selectedIDs: Set<String>) -> Self {
        let eligible = Set(entries.lazy.filter { !completedIDs.contains($0.id) }.map(\.id))
        let selected = entries.filter { selectedIDs.contains($0.id) && eligible.contains($0.id) }
        return Self(eligibleIDs: eligible, entries: selected,
            bytes: FileLightfieldPresentation.sum(selected.map { $0.item.sizeBytes }))
    }
}

enum LightfieldMigrationPresentation {
    static let largeFileThreshold: Int64 = 1_000_000_000
    static func fileEntries(_ items: [StorageItem]) -> [LightfieldMigrationEntry] {
        items.compactMap { source in
            guard let item = ExternalMigrationItem.largeFile(source) else { return nil }
            return LightfieldMigrationEntry(item: item, modifiedAt: source.modifiedAt)
        }
    }
    static func oldLargeIDs(_ entries: [LightfieldMigrationEntry], now: Date, calendar: Calendar = .current) -> Set<String> {
        guard let cutoff = calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now)) else { return [] }
        return Set(entries.filter {
            guard let date = $0.modifiedAt else { return false }
            return date <= now && calendar.startOfDay(for: date) <= cutoff && $0.item.sizeBytes >= largeFileThreshold
        }.map(\.id))
    }
    static func groups(_ entries: [LightfieldMigrationEntry], by grouping: LightfieldMigrationGrouping,
                       root: String?, now: Date, calendar: Calendar = .current) -> [LightfieldMigrationGroup] {
        var buckets: [String: [LightfieldMigrationEntry]] = [:]
        var labels: [String: String] = [:]
        var icons: [String: LightfieldOptionIcon] = [:]
        for entry in entries {
            let key: String, title: String, icon: LightfieldOptionIcon
            switch grouping {
            case .type:
                switch entry.category {
                case .video: key = "0-video"; title = L10n.text("视频", "Videos"); icon = .duplicatesVideos
                case .image: key = "1-image"; title = L10n.text("图片", "Images"); icon = .duplicatesPhotos
                case .archive: key = "2-archive"; title = L10n.text("压缩包与安装包", "Archives & Installers"); icon = .fileanalysisArchives
                case .application:
                    key = entry.item.kind == .application ? "6-app" : "2-archive"
                    title = entry.item.kind == .application ? L10n.text("应用", "Apps") : L10n.text("压缩包与安装包", "Archives & Installers")
                    icon = .migrationApplication
                case .audio: key = "3-audio"; title = L10n.text("音频", "Audio"); icon = .duplicatesAudio
                case .document: key = "4-document"; title = L10n.text("文档", "Documents"); icon = .fileanalysisDocuments
                default: key = "5-other"; title = L10n.text("其他", "Other"); icon = .fileanalysisOther
                }
            case .modified:
                let day = entry.modifiedAt.map { calendar.startOfDay(for: $0) }
                let year = calendar.date(byAdding: .year, value: -1, to: calendar.startOfDay(for: now))
                let half = calendar.date(byAdding: .month, value: -6, to: calendar.startOfDay(for: now))
                if let date = entry.modifiedAt, date <= now, let day, let year, let half {
                    if day <= year { key = "0-old"; title = L10n.text("一年以上未修改", "Over One Year") }
                    else if day <= half { key = "1-half"; title = L10n.text("半年到一年", "Six Months to One Year") }
                    else { key = "2-recent"; title = L10n.text("近半年", "Within Six Months") }
                } else if entry.modifiedAt != nil {
                    key = "3-future"; title = L10n.text("修改时间在未来", "Future Modified Date")
                } else { key = "3-unknown"; title = L10n.text("修改时间未知", "Modified Date Unknown") }
                icon = .migrationVerification
            case .location:
                let path = entry.item.sourceURL.deletingLastPathComponent().path
                if let root, path == root || path.hasPrefix(root + "/") {
                    let relative = path == root ? "" : String(path.dropFirst(root.count + 1))
                    let first = relative.split(separator: "/").first.map(String.init)
                    key = first.map { (root as NSString).appendingPathComponent($0) } ?? root
                } else { key = path }
                title = key; icon = .migrationSourceFolder
            }
            buckets[key, default: []].append(entry); labels[key] = title; icons[key] = icon
        }
        return buckets.keys.sorted().map { key in
            .init(id: key, title: labels[key] ?? key, icon: icons[key] ?? .migrationSourceFolder,
                entries: (buckets[key] ?? []).sorted {
                    $0.item.sizeBytes == $1.item.sizeBytes ? $0.id < $1.id : $0.item.sizeBytes > $1.item.sizeBytes
                })
        }
    }
}
