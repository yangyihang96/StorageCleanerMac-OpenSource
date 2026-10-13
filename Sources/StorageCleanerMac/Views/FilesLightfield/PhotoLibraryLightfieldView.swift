import AppKit
import SwiftUI

struct PhotoLibraryLightfieldView: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#endif
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: PhotoLibraryStore
    /// Returns to the file-system similar-photos page; the store is kept.
    let onUseFileSystemImages: () -> Void
    @State private var confirmingAlbum = false
    private var allowsLibraryAccess: Bool {
#if DEBUG
        !isFixture
#else
        true
#endif
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Text(L10n.text("系统照片图库", "System Photo Library")).font(.system(size: 24, weight: .semibold))
                Spacer(minLength: 0)
                Button(L10n.text("改用文件系统图片", "Use File System Images"), action: onUseFileSystemImages)
                    .buttonStyle(FeatureLightfieldRowButtonStyle()).fixedSize()
            }
            Text(model.authorization.message).font(.system(size: 13))
            HStack(spacing: 16) {
                if model.authorization == .notDetermined {
                    Button(L10n.text("授权照片访问", "Authorize Photo Access"), action: model.authorize)
                }
                Button(L10n.text("去系统设置开启", "Open System Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") { NSWorkspace.shared.open(url) }
                }
                Button(L10n.text("刷新授权状态", "Refresh Access Status")) { Task { await model.refreshAuthorization() } }.disabled(model.busy)
                Button(L10n.text("扫描图库", "Scan Library"), action: model.scan).disabled(!model.authorization.canRead || model.busy)
                if model.scanning {
                    Text(L10n.text("已处理 \(model.processed) 张", "Processed \(model.processed) photos"))
                    Button(L10n.text("取消扫描", "Cancel Scan"), action: model.cancel)
                }
            }.buttonStyle(FeatureLightfieldRowButtonStyle())
            if let result = model.result {
                Text(L10n.text("已处理 \(result.processed) 张 · \(result.groups.count) 组 · 本地缩略图不可用 \(result.missingThumbnails) 张", "Processed \(result.processed) photos · \(result.groups.count) groups · \(result.missingThumbnails) local thumbnails unavailable"))
                    .font(.system(size: 13))
                if result.truncated {
                    Text(L10n.text("只处理前 \(result.processed) 张；图库中还有更多照片。", "Only the first \(result.processed) photos were processed; the library contains more photos."))
                }
                if result.comparisonLimited {
                    Text(L10n.text("已达到相似比对预算，结果不完整。", "Similarity comparison budget reached; results are incomplete."))
                }
                Text(L10n.text("元数据重复候选不代表原图内容完全相同。每组建议保留一张，默认不选；请逐张审阅。", "Matching metadata does not confirm identical original content. One photo is suggested for keeping per group; none are selected by default. Review each photo."))
                    .font(.system(size: 13))
            }
            FeatureOptionsScrollView(probePrefix: "lightfield.photos.library", balancesContent: false, usesLightfield: true, fadesResults: true) {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(model.result?.groups ?? []) { group in
                        Text(group.title).font(.system(size: 15, weight: .semibold))
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], alignment: .leading, spacing: 16) {
                            ForEach(group.photos) { photo in
                                PhotoLibraryTile(photo: photo, kept: model.keepers[group.id] == photo.id,
                                                 selected: model.selectedIDs.contains(photo.id), busy: model.busy,
                                                 preview: { await model.preview(photo) },
                                                 toggle: { model.toggle(photo, in: group) }, keep: { model.keep(photo, in: group) })
                            }
                        }
                        FeatureLightfieldHairline()
                    }
                }
            }
            if let message = model.message { Text(message).font(.system(size: 13)).textSelection(.enabled) }
            HStack(spacing: 16) {
                Button(L10n.text("加入待删除相册（\(model.selectedIDs.count) 张）", "Add to Review Album (\(model.selectedIDs.count) photos)")) { confirmingAlbum = true }
                    .disabled(model.busy || model.selectedIDs.isEmpty || !model.authorization.canAddToAlbum)
                Button(L10n.text("打开照片 App", "Open Photos")) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Photos") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
            }.buttonStyle(FeatureLightfieldRowButtonStyle())
        }.foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg).padding(24).disabled(!allowsLibraryAccess)
            .task {
#if DEBUG
                guard !isFixture else { return }
#endif
                await model.refreshAuthorization()
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, allowsLibraryAccess else { return }
                Task { await model.refreshAuthorization() }
            }
            .onDisappear { model.cancel() }
            .alert(L10n.text("加入待删除相册？", "Add to Review Album?"), isPresented: $confirmingAlbum) {
                Button(L10n.text("取消", "Cancel"), role: .cancel) {}
                Button(L10n.text("加入相册", "Add to Album"), action: model.addSelectedToAlbum)
            } message: {
                Text(L10n.text("将选中的 \(model.selectedIDs.count) 张照片加入『存储清理助手-待删除』，不删除照片。需要完整读写授权以创建或复用相册并加入照片；已有唯一同名相册时可能复用您的相册。请在『照片』App 中查看并删除；删除后进入『最近删除』30 天可恢复。", "Add \(model.selectedIDs.count) selected photos to ‘存储清理助手-待删除’ without deleting them. Full read/write access is required to create or reuse the album and add photos. An existing uniquely named album may be yours and will be reused. Review and delete in Photos; recover from Recently Deleted for 30 days."))
            }
    }
}

private struct PhotoLibraryTile: View {
#if DEBUG
    @Environment(\.featurePresentationIsFixture) private var isFixture
#endif
    @Environment(\.colorScheme) private var scheme
    let photo: LibraryPhoto
    let kept: Bool
    let selected: Bool
    let busy: Bool
    let preview: () async -> Data?
    let toggle: () -> Void
    let keep: () -> Void
    @State private var image: NSImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image { Image(nsImage: image).resizable().scaledToFit().frame(height: 102).accessibilityHidden(true) }
            else { Text(L10n.text("本地缩略图不可用", "Local thumbnail unavailable")).frame(height: 102) }
            Text("\(photo.width) × \(photo.height)").font(.system(size: 13))
            Text(photo.creationDate.map { $0.formatted(date: .numeric, time: .shortened) } ?? L10n.text("拍摄时间未知", "Capture date unknown"))
                .font(.system(size: 13))
            if photo.favorite { Text(L10n.text("已收藏", "Favorite")) }
            if photo.edited { Text(L10n.text("已编辑", "Edited")) }
            Button(action: toggle) {
                HStack { FeatureLightfieldCheck(selected: selected, module: .duplicates); Text(L10n.text("加入待删除相册", "Add to Review Album")) }
            }.disabled(kept || busy).accessibilityValue(selected ? L10n.text("已选", "Selected") : L10n.text("未选", "Not selected"))
            Button(kept ? L10n.text("建议保留", "Suggested Keep") : L10n.text("改为保留此张", "Keep This Photo"), action: keep).disabled(busy)
        }.buttonStyle(FeatureLightfieldRowButtonStyle()).font(.system(size: 13))
            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
            .task(id: photo.cacheKey) {
#if DEBUG
                guard !isFixture else { return }
#endif
                let data = await preview()
                guard !Task.isCancelled else { return }
                image = data.flatMap(NSImage.init(data:))
            }
    }
}
