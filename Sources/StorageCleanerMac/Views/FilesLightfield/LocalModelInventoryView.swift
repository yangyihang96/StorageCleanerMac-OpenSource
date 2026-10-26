import AppKit
import SwiftUI

/// D84：容量口径说明。只读文字，不改任何测量。
struct StorageCapacityNotesSheet: View {
    @Environment(\.colorScheme) private var scheme
    let onClose: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("容量口径", "Size Basis")).font(.system(size: 24, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(StorageCapacityPresentation.notes.enumerated()), id: \.offset) { _, note in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(note.title).font(.system(size: 15, weight: .semibold))
                            Text(note.body).font(.system(size: 13))
                                .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            Button(L10n.text("返回", "Back"), action: onClose).buttonStyle(FeatureLightfieldRowButtonStyle())
        }.padding(24).frame(width: 640, height: 480)
            .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg)
    }
}

enum LocalModelInventoryPresentation {
    static var readOnlyNote: String {
        L10n.text(
            "只读盘点：本页不提供删除。删除模型后需要重新下载，且不保证仍能下载到同一版本。",
            "Read-only inventory: nothing can be deleted here. A deleted model must be downloaded again, and the same version may no longer be available."
        )
    }

    static func summary(_ inventory: LocalModelInventory) -> String {
        guard inventory.hasAnyRoot else {
            return L10n.text("没有找到 Ollama 或 LM Studio 的模型文件夹", "No Ollama or LM Studio model folder found")
        }
        return L10n.text(
            "\(ByteFormat.count(inventory.models.count)) 个模型 · 本地占用 \(ByteFormat.storageString(inventory.totalBytes))（共享文件只计一次）",
            "\(L10n.englishCount(inventory.models.count, "model", "models")) · \(ByteFormat.storageString(inventory.totalBytes)) local usage (shared files counted once)"
        )
    }

    static func detail(_ model: LocalModelEntry) -> String {
        var parts = [model.source.title]
        parts.append(model.format ?? L10n.text("格式未知", "Unknown format"))
        parts.append(L10n.text("\(ByteFormat.count(model.fileCount)) 个文件", L10n.englishCount(model.fileCount, "file", "files")))
        if model.missingFileCount > 0 {
            parts.append(L10n.text("缺少 \(ByteFormat.count(model.missingFileCount)) 个文件",
                                   L10n.englishCount(model.missingFileCount, "file", "files") + " missing"))
        }
        return parts.joined(separator: " · ")
    }

    static func sharing(_ model: LocalModelEntry) -> String? {
        guard model.sharedBytes > 0 else { return nil }
        let names = model.sharedWith.joined(separator: L10n.text("、", ", "))
        return L10n.text(
            "其中 \(ByteFormat.storageString(model.sharedBytes)) 与 \(names) 共用；合计只计一次，删除本模型不会释放共用部分。",
            "\(ByteFormat.storageString(model.sharedBytes)) is shared with \(names); counted once in the total, and deleting this model alone does not free it."
        )
    }

    static func rootLine(_ root: LocalModelRootStatus) -> String {
        let state: String
        switch root.state {
        case .absent: state = L10n.text("不存在", "Not found")
        case .scanned: state = L10n.text("已读取", "Read")
        case let .symbolicLink(destination):
            state = L10n.text("是符号链接，未跟随", "Symbolic link, not followed")
                + (destination.map { " → " + $0 } ?? "")
        case let .sameAs(other): state = L10n.text("与 \(other) 是同一文件夹，不重复计算", "Same folder as \(other); not counted twice")
        case let .linkedAncestor(path, destination):
            state = L10n.text("上级 \(path) 是符号链接，未跟随", "Parent \(path) is a symbolic link, not followed")
                + (destination.map { " → " + $0 } ?? "")
        case .unreadable: state = L10n.text("无法读取", "Unreadable")
        }
        return root.source.title + " · " + root.path + " · " + state
    }

    static func notices(_ inventory: LocalModelInventory) -> [String] {
        var lines = [String]()
        if !inventory.unknownManifests.isEmpty {
            lines.append(L10n.text(
                "\(ByteFormat.count(inventory.unknownManifests.count)) 个无法识别的模型清单，已保留、未计入",
                L10n.englishCount(inventory.unknownManifests.count, "unrecognised manifest", "unrecognised manifests") + " kept and not counted"
            ))
        }
        if inventory.unreferencedBlobCount > 0 {
            lines.append(L10n.text(
                "Ollama 中 \(ByteFormat.count(inventory.unreferencedBlobCount)) 个文件（\(ByteFormat.storageString(inventory.unreferencedBlobBytes))）没有被任何已识别模型引用，可能属于下载中或无法识别的模型，未计入合计",
                L10n.englishCount(inventory.unreferencedBlobCount, "Ollama file", "Ollama files") + " (\(ByteFormat.storageString(inventory.unreferencedBlobBytes))) not used by any recognised model (possibly partial downloads or unrecognised models); not counted"
            ))
        }
        if !inventory.skippedSymbolicLinks.isEmpty {
            lines.append(L10n.text(
                "跳过 \(ByteFormat.count(inventory.skippedSymbolicLinks.count)) 个符号链接（可能指向外部位置），未跟随、未计入",
                "Skipped " + L10n.englishCount(inventory.skippedSymbolicLinks.count, "symbolic link", "symbolic links") + " (possibly to external locations); not followed or counted"
            ))
        }
        if !inventory.skippedDeepFolders.isEmpty {
            lines.append(L10n.text(
                "\(ByteFormat.count(inventory.skippedDeepFolders.count)) 个文件夹层级过深，未进入、未计入；其余照常盘点",
                L10n.englishCount(inventory.skippedDeepFolders.count, "folder", "folders")
                    + " nested too deep; skipped and not counted, the rest was read"
            ))
        }
        if !inventory.unreadableFolders.isEmpty {
            lines.append(L10n.text(
                "\(ByteFormat.count(inventory.unreadableFolders.count)) 个文件夹无法读取，未计入，结果不完整",
                L10n.englishCount(inventory.unreadableFolders.count, "folder", "folders")
                    + " unreadable; not counted, results are incomplete"
            ))
        }
        if inventory.stoppedEarly {
            lines.append(L10n.text("条目过多或已停止，结果不完整", "Too many entries or stopped; results are incomplete"))
        }
        return lines
    }
}

/// D86：本地 AI 模型只读盘点。打开时在后台读一次，不提供删除。
struct LocalModelInventorySheet: View {
    @Environment(\.colorScheme) private var scheme
    let onClose: () -> Void
    var scanner = LocalModelInventoryScanner()
    @State private var inventory: LocalModelInventory?
    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("本地 AI 模型", "Local AI Models")).font(.system(size: 24, weight: .semibold))
            Text(LocalModelInventoryPresentation.readOnlyNote).font(.system(size: 13)).foregroundStyle(palette.fg2)
                .fixedSize(horizontal: false, vertical: true)
            if let inventory {
                Text(LocalModelInventoryPresentation.summary(inventory)).font(.system(size: 15, weight: .semibold))
                    .lightfieldComponentProbe("localModels.summary")
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(inventory.models) { model in row(model) }
                        ForEach(LocalModelInventoryPresentation.notices(inventory), id: \.self) { line in
                            Text(line).font(.system(size: 13)).foregroundStyle(palette.fg2)
                                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                        }
                        ForEach(inventory.roots) { root in
                            Text(LocalModelInventoryPresentation.rootLine(root)).font(.system(size: 13))
                                .foregroundStyle(palette.fg2).lineLimit(1).truncationMode(.middle)
                                .help(root.path).padding(.vertical, 4)
                        }
                    }
                }
            } else {
                Text(L10n.text("正在读取模型文件夹…", "Reading model folders…")).font(.system(size: 15))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Button(L10n.text("返回", "Back"), action: onClose).buttonStyle(FeatureLightfieldRowButtonStyle())
        }.padding(24).frame(width: 680, height: 500)
            .foregroundStyle(palette.fg)
            .task {
                let scanner = scanner
                let worker = Task.detached(priority: .utility) { scanner.scan() }
                let value = await withTaskCancellationHandler {
                    await worker.value
                } onCancel: { worker.cancel() }
                guard !Task.isCancelled else { return }
                inventory = value
            }
    }

    private func row(_ model: LocalModelEntry) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name).font(.system(size: 15)).lineLimit(1).truncationMode(.middle)
                Text(LocalModelInventoryPresentation.detail(model)).font(.system(size: 13))
                    .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).lineLimit(1)
                if let sharing = LocalModelInventoryPresentation.sharing(model) {
                    Text(sharing).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteFormat.storageString(model.bytes)).font(.system(size: 15)).monospacedDigit().lineLimit(1)
        }.padding(.vertical, 8)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .help(model.location)
            .accessibilityElement(children: .combine)
            .contextMenu {
                Button(L10n.text("在访达中显示", "Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.location)])
                }
            }
    }
}
