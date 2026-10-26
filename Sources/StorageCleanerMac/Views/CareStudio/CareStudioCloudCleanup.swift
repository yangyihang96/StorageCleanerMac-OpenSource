import AppKit
import SwiftUI

/// Local File Provider folders only: no accounts are connected or stored.
/// Every release uses D90's separate, freshly checked review sheet.
struct CareStudioCloudCleanupPage: View {
    @ObservedObject var store: ScanStore
    @ObservedObject private var model: CloudCleanupModel
    @State private var review: CloudReview?

    private struct CloudReview: Identifiable {
        let id = UUID()
        let entries: [StorageTreemapEntry]
    }

    init(store: ScanStore, model: CloudCleanupModel = .shared) {
        self.store = store
        self.model = model
    }

    var body: some View {
        Group {
            switch model.phase {
            case .scanning:
                CareStudioRunningPage(
                    module: .cloudCleanup,
                    detail: model.progress.currentPath.isEmpty ? nil : model.progress.currentPath,
                    headlineValue: L10n.text("已检查 \(ByteFormat.count(model.progress.inspectedCount)) 项", "\(ByteFormat.count(model.progress.inspectedCount)) items checked"),
                    footnote: L10n.text("只读 · 不下载、不删除任何文件", "Read-only · Nothing is downloaded or deleted"),
                    onStop: model.cancel)
            case .finished:
                if let snapshot = model.snapshot {
                    results(snapshot)
                } else {
                    landing
                }
            case .idle, .cancelled:
                landing
            }
        }
        .sheet(item: $review) { review in
            CloudLocalCopySheet(entries: review.entries,
                                coordinator: store.largeFilesWorkspace.cloudLocalCopyCoordinator,
                                onClose: { self.review = nil })
                .environment(\.locale, L10n.locale)
        }
        .onAppear { model.refreshProviders() }
    }

    private var landing: some View {
        CareStudioLandingPage(
            module: .cloudCleanup,
            bullets: CloudCleanupPresentation.landingBullets(iCloudDriveAvailable: model.iCloudDriveAvailable,
                                                            providers: model.providers),
            status: CloudCleanupPresentation.landingStatus(iCloudDriveAvailable: model.iCloudDriveAvailable),
            footnote: L10n.text("只读扫描 · 移除本机副本前逐项确认", "Read-only scan · Every local copy is confirmed before removal"),
            actionTitle: L10n.text("扫描", "Scan"),
            actionEnabled: model.iCloudDriveAvailable || !model.providers.isEmpty,
            actionHint: model.providers.isEmpty
                ? L10n.text("读取 iCloud 云盘里已下载到这台 Mac 的文件", "Reads which iCloud Drive files are downloaded to this Mac")
                : L10n.text("读取这台 Mac 已设置的云盘文件夹", "Reads the cloud folders set up on this Mac"),
            action: model.start)
    }

    private func results(_ snapshot: CloudDriveSnapshot) -> some View {
        // Item 12: Start Over in the title bar, now asking first; Scan Again
        // gone (CleanMyMac scans again from the landing page).
        CareStudioPageFrame(module: .cloudCleanup,
                            titleBar: .startOver(CareStudioStartOver(activity: store.heavyWorkActivityStore,
                                                                     action: model.startOver)),
                            footnote: CloudCleanupPresentation.resultFootnote(hasOtherProviders: !model.providerSnapshots.isEmpty)) {
            VStack(spacing: 0) {
                if !([snapshot] + model.providerSnapshots.map(\.snapshot)).contains(where: \.rootExists) {
                    CareStudioResultsStateMark(art: .stateEmpty)
                } else if ([snapshot] + model.providerSnapshots.map(\.snapshot)).allSatisfy({ $0.localFileCount == 0 }) {
                    CareStudioResultsStateMark(art: .stateAllClear)
                }
                Text(CloudCleanupPresentation.headline(snapshot, providers: model.providerSnapshots))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(CareStudioInk.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 32)
                    .padding(.top, 18)
                    .accessibilityAddTraits(.isHeader)
#if DEBUG
                    .layoutProbe("careStudio.cloudCleanup.headline")
#endif
                if !snapshot.largestLocalFiles.isEmpty {
                    CareStudioPillButton(title: L10n.text("查看全部本机文件", "Review All Local Files")) {
                        review = CloudReview(entries: CloudDriveScanner.reviewEntries(snapshot.largestLocalFiles))
                    }
                    .padding(.top, 12)
                }
                if snapshot.isTruncated || snapshot.unreadableCount > 0 {
                    CareStudioNotice(systemImage: "exclamationmark.triangle",
                                     text: snapshot.isTruncated
                                        ? L10n.text("文件太多，只读了前 \(ByteFormat.count(CloudDriveScanner.itemLimit)) 项。", "Too many files; the first \(ByteFormat.count(CloudDriveScanner.itemLimit)) were read.")
                                        : L10n.text("\(ByteFormat.count(snapshot.unreadableCount)) 项无法读取，已跳过。", "\(ByteFormat.count(snapshot.unreadableCount)) items could not be read and were skipped."))
                        .padding(.horizontal, 32)
                        .padding(.top, 10)
                }
                CareStudioTileGrid(tiles: tiles(snapshot))
                    .padding(.horizontal, CareStudioMetrics.pageInset)
                    .padding(.top, 18)
                    .padding(.bottom, 12)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
            // The row that went to the title bar was 26 pt plus 12 above it;
            // the page below keeps its place.
            .padding(.top, 38)
        } action: {
            EmptyView()
        }
    }

    private func tiles(_ snapshot: CloudDriveSnapshot) -> [CareStudioTileModel] {
        var tiles: [CareStudioTileModel] = []
        tiles.append(CareStudioTileModel(
            id: "local", module: .cloudCleanup,
            title: L10n.text("本机已下载的文件", "Locally Synced Files"),
            value: ByteFormat.storageString(snapshot.localBytes),
            valueCaption: L10n.text("\(ByteFormat.count(snapshot.localFileCount)) 个文件在这台 Mac 上", "\(ByteFormat.count(snapshot.localFileCount)) files on this Mac"),
            detail: L10n.text("这些 iCloud 云盘文件已下载到这台 Mac。移除本机副本后文件仍在 iCloud，打开时会重新下载。",
                              "These iCloud Drive files are downloaded to this Mac. Without the local copy they stay in iCloud and download again when opened."),
            systemImage: "icloud.and.arrow.down",
            reviewTitle: L10n.text("查看", "Review"),
            onReview: { review = CloudReview(entries: CloudDriveScanner.reviewEntries(snapshot.largestLocalFiles)) }, art: .tileDownloaded))
        // D192: no tile for nothing (10-23 test beta showed "0 bytes · 0 files
        // over 100 MB"); CleanMyMac shows only tiles that found something.
        if !snapshot.largeLocalFiles.isEmpty {
            tiles.append(CareStudioTileModel(
                id: "large", module: .cloudCleanup,
                title: L10n.text("大型本机文件", "Large Local Files"),
                value: ByteFormat.storageString(snapshot.largeLocalBytes),
                valueCaption: L10n.text("\(ByteFormat.count(snapshot.largeLocalFiles.count)) 个文件超过 \(ByteFormat.storageString(CloudDriveScanner.largeFileBytes))",
                                        "\(ByteFormat.count(snapshot.largeLocalFiles.count)) files over \(ByteFormat.storageString(CloudDriveScanner.largeFileBytes))"),
                systemImage: "doc.badge.arrow.up",
                reviewTitle: L10n.text("查看", "Review"),
                onReview: { review = CloudReview(entries: CloudDriveScanner.reviewEntries(snapshot.largeLocalFiles)) }, art: .tileLargeCloud))
        }
        tiles.append(CareStudioTileModel(
            id: "cloudOnly", module: .cloudCleanup,
            title: L10n.text("只在云端的文件", "Cloud-Only Files"),
            value: ByteFormat.count(snapshot.cloudOnlyCount),
            valueCaption: L10n.text("共 \(ByteFormat.storageString(snapshot.cloudOnlyBytes))，不占本机空间", "\(ByteFormat.storageString(snapshot.cloudOnlyBytes)) in all, no space on this Mac"),
            systemImage: "icloud",
            reviewTitle: L10n.text("在访达中打开", "Open in Finder"),
            onReview: { NSWorkspace.shared.open(CloudDriveScanner.iCloudDriveRoot().appendingPathComponent("com~apple~CloudDocs")) }, art: .tileCloudOnly))
        for (index, result) in model.providerSnapshots.enumerated() {
            tiles.append(CloudCleanupPresentation.providerTile(
                result, id: "provider.\(index)", appIcon: result.provider.systemIcon,
                onReview: { review = CloudReview(entries: CloudDriveScanner.reviewEntries(result.snapshot.largestLocalFiles)) },
                onOpen: { NSWorkspace.shared.open(URL(fileURLWithPath: result.provider.path)) }))
        }
        return tiles
    }
}

extension CloudDriveScanner.Provider {
    @MainActor var systemIcon: NSImage? {
        iconPath.map { NSWorkspace.shared.icon(forFile: $0) }
    }

    /// The provider's own app, for its icon only, by the names the scanner
    /// gives the File Provider folders; other providers keep the tile's object.
    @MainActor var iconPath: String? {
        let identifiers: [String] = switch kind {
        case .oneDrive: ["com.microsoft.OneDrive", "com.microsoft.OneDrive-mac"]
        case .googleDrive: ["com.google.drivefs"]
        case .dropbox: ["com.getdropbox.dropbox"]
        case .box: ["com.box.desktop"]
        case .other: []
        }
        return identifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path }.first
    }
}

/// Shared presentation values also let tests verify both languages without opening a window.
enum CloudCleanupPresentation {
    /// D204: names only, as CleanMyMac's landings; what each line says
    /// beyond its name is for VoiceOver.
    static func landingBullets(iCloudDriveAvailable: Bool, providers: [CloudDriveScanner.Provider]) -> [CareStudioBullet] {
        var bullets = [
            CareStudioBullet(id: "icloud", title: L10n.text("iCloud 云盘", "iCloud Drive"), systemImage: "icloud",
                             hint: iCloudDriveAvailable
                                ? L10n.text("已在这台 Mac 上启用", "On for this Mac")
                                : L10n.text("这台 Mac 没有启用 iCloud 云盘", "iCloud Drive is off on this Mac")),
            CareStudioBullet(id: "local", title: L10n.text("本机副本", "Local Copies"), systemImage: "arrow.down.circle",
                             hint: providers.isEmpty
                                ? L10n.text("移除后文件仍在 iCloud，需要时再下载", "Files stay in iCloud and download again when opened")
                                : L10n.text("移除后文件仍在云盘，需要时再下载", "Files stay in the cloud and download again when opened"))
        ]
        if providers.isEmpty {
            bullets.append(CareStudioBullet(id: "others", title: L10n.text("其他云盘", "Other Clouds"),
                                            systemImage: "externaldrive.connected.to.line.below",
                                            hint: L10n.text("没有发现其他云盘文件夹", "No other cloud folders found")))
        } else {
            for (index, provider) in providers.enumerated() {
                bullets.append(CareStudioBullet(id: "provider.\(index)", title: provider.displayTitle,
                                                systemImage: "externaldrive.connected.to.line.below",
                                                hint: L10n.text("已在这台 Mac 上设置", "Set up on this Mac")))
            }
        }
        return bullets
    }

    /// D204: iCloud Drive being off was the iCloud line's second line; it
    /// stays on the page, under the list.
    static func landingStatus(iCloudDriveAvailable: Bool) -> String? {
        iCloudDriveAvailable ? nil : L10n.text("这台 Mac 没有启用 iCloud 云盘", "iCloud Drive is off on this Mac")
    }

    static func resultFootnote(hasOtherProviders: Bool) -> String {
        hasOtherProviders
            ? L10n.text("只移除本机副本 · 文件仍在云盘", "Only local copies are removed · Files stay in the cloud")
            : L10n.text("只移除本机副本 · 文件仍在 iCloud", "Only local copies are removed · Files stay in iCloud")
    }

    static func headline(_ snapshot: CloudDriveSnapshot, providers: [CloudDriveScanner.ProviderSnapshot]) -> String {
        guard !providers.isEmpty else { return iCloudHeadline(snapshot) }
        let snapshots = [snapshot] + providers.map(\.snapshot)
        guard snapshots.contains(where: \.rootExists) else {
            return L10n.text("没有可读取的云盘文件夹。", "No cloud folders could be read.")
        }
        guard snapshots.contains(where: { $0.localFileCount > 0 }) else {
            return L10n.text("云盘文件都只在云端，这台 Mac 上没有副本。", "Your cloud files are all in the cloud; none take space on this Mac.")
        }
        let bytes = snapshots.reduce(Int64(0)) { CleanupByteCount.adding($1.localBytes, to: $0) }
        return L10n.text("云盘文件在这台 Mac 上占用 \(ByteFormat.storageString(bytes))。",
                         "Cloud files take \(ByteFormat.storageString(bytes)) on this Mac.")
    }

    static func iCloudHeadline(_ snapshot: CloudDriveSnapshot) -> String {
        guard snapshot.rootExists else {
            return L10n.text("这台 Mac 没有启用 iCloud 云盘。", "iCloud Drive is off on this Mac.")
        }
        guard snapshot.localFileCount > 0 else {
            return L10n.text("iCloud 云盘的文件都只在云端，这台 Mac 上没有副本。", "Your iCloud Drive files are all in the cloud; none take space on this Mac.")
        }
        return L10n.text("iCloud 云盘在这台 Mac 上占用 \(ByteFormat.storageString(snapshot.localBytes))。",
                         "iCloud Drive takes \(ByteFormat.storageString(snapshot.localBytes)) on this Mac.")
    }


    static func providerTile(_ result: CloudDriveScanner.ProviderSnapshot, id: String, appIcon: NSImage? = nil,
                             onReview: @escaping () -> Void, onOpen: @escaping () -> Void) -> CareStudioTileModel {
        let snapshot = result.snapshot
        let local = L10n.text("本机：\(ByteFormat.count(snapshot.localFileCount)) 个文件",
                              "On this Mac: \(ByteFormat.count(snapshot.localFileCount)) files")
        let cloud = L10n.text("只在云端：\(ByteFormat.storageString(snapshot.cloudOnlyBytes))（\(ByteFormat.count(snapshot.cloudOnlyCount)) 个文件）",
                              "Cloud only: \(ByteFormat.storageString(snapshot.cloudOnlyBytes)) (\(ByteFormat.count(snapshot.cloudOnlyCount)) files)")
        var notes: [String] = []
        if !snapshot.rootExists {
            notes.append(L10n.text("云盘文件夹无法读取", "Cloud folder could not be read"))
        }
        if snapshot.isTruncated {
            notes.append(L10n.text("只读了前 \(ByteFormat.count(CloudDriveScanner.itemLimit)) 项",
                                    "Only the first \(ByteFormat.count(CloudDriveScanner.itemLimit)) items were read"))
        }
        if snapshot.unreadableCount > 0 {
            notes.append(L10n.text("\(ByteFormat.count(snapshot.unreadableCount)) 项无法读取", "\(ByteFormat.count(snapshot.unreadableCount)) unreadable items"))
        }
        return CareStudioTileModel(
            id: id, module: .cloudCleanup, title: result.provider.displayTitle,
            value: snapshot.rootExists ? ByteFormat.storageString(snapshot.localBytes) : L10n.text("无法读取", "Unavailable"),
            valueCaption: local + "\n" + cloud,
            detail: L10n.text("查看最大的 \(ByteFormat.count(snapshot.largestLocalFiles.count)) 个本机文件。",
                              "Review the \(ByteFormat.count(snapshot.largestLocalFiles.count)) largest local files."),
            note: notes.isEmpty ? nil : notes.joined(separator: " · "),
            systemImage: "externaldrive.connected.to.line.below", appIcon: appIcon,
            reviewTitle: L10n.text("查看", "Review"), onReview: onReview,
            cleanTitle: L10n.text("在访达中打开", "Open in Finder"), onClean: onOpen)
    }
}
