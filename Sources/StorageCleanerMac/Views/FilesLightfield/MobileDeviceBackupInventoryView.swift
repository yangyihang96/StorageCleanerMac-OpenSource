import AppKit
import SwiftUI

/// D116 G11：iPhone、iPad 备份只读盘点的文字。
enum MobileDeviceBackupPresentation {
    static var readOnlyNote: String {
        L10n.text(
            "只读盘点：备份可能是设备数据唯一的副本，本页不提供删除。要删除旧备份，请把 iPhone 或 iPad 连接到这台 Mac，在访达里选中设备，点“管理备份…”。",
            "Read-only inventory: a backup may be the only copy of a device's data, so nothing can be deleted here. To delete an old backup, connect an iPhone or iPad to this Mac, select it in Finder and click Manage Backups…"
        )
    }

    static func summary(_ inventory: MobileDeviceBackupInventory) -> String {
        switch inventory.rootState {
        case .absent:
            return L10n.text("这台 Mac 的默认位置没有 iPhone 或 iPad 备份", "No iPhone or iPad backups in the default location on this Mac")
        case .symbolicLink, .linkedAncestor:
            return L10n.text("备份文件夹经过符号链接，没有读取", "The backup folder goes through a symbolic link and was not read")
        case .unreadable:
            return L10n.text("无法读取备份文件夹", "The backup folder cannot be read")
        case .readable:
            break
        }
        guard !inventory.backups.isEmpty else {
            return L10n.text("备份文件夹里没有备份", "No backups in the backup folder")
        }
        return L10n.text(
            "\(ByteFormat.count(inventory.backups.count)) 个备份 · 本地占用 \(ByteFormat.storageString(inventory.totalBytes))",
            "\(L10n.englishCount(inventory.backups.count, "backup", "backups")) · \(ByteFormat.storageString(inventory.totalBytes)) local usage"
        )
    }

    /// 读不了或没有跟随时的原因；可读或不存在时为 nil。
    static func stateDetail(_ inventory: MobileDeviceBackupInventory) -> String? {
        switch inventory.rootState {
        case .unreadable:
            return L10n.text(
                "通常是还没有给本 App 完全磁盘访问权限。在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”里允许本 App 后，重新打开本页。",
                "Usually this app does not have Full Disk Access yet. Allow it in System Settings › Privacy & Security › Full Disk Access, then open this page again."
            )
        case let .symbolicLink(destination):
            return L10n.text("备份文件夹是符号链接，为安全起见不跟随", "The backup folder is a symbolic link and is not followed, for safety")
                + (destination.map { " → " + $0 } ?? "")
        case let .linkedAncestor(path, destination):
            return L10n.text("上级 \(path) 是符号链接，为安全起见不跟随", "Parent \(path) is a symbolic link and is not followed, for safety")
                + (destination.map { " → " + $0 } ?? "")
        case .absent, .readable:
            return nil
        }
    }

    static func title(_ backup: MobileDeviceBackup) -> String {
        backup.deviceName ?? L10n.text("没有读到设备名的备份", "Backup without a device name")
    }

    static func detail(
        _ backup: MobileDeviceBackup,
        formatDate: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }
    ) -> String {
        var parts = [backup.backupDate.map { L10n.text("备份于 \(formatDate($0))", "Backed up \(formatDate($0))") }
            ?? L10n.text("备份时间未知", "Backup date unknown")]
        if let version = backup.systemVersion {
            parts.append(L10n.text("系统版本 \(version)", "System \(version)"))
        }
        switch backup.isEncrypted {
        case true?: parts.append(L10n.text("已加密", "Encrypted"))
        case false?: parts.append(L10n.text("未加密", "Not encrypted"))
        case nil: break
        }
        if backup.isUnfinished { parts.append(L10n.text("上次备份没有完成", "The last backup did not finish")) }
        if backup.isIncomplete { parts.append(L10n.text("大小不完整", "Size incomplete")) }
        return parts.joined(separator: " · ")
    }

    static func sharing(_ backup: MobileDeviceBackup) -> String? {
        guard backup.sharedBytes > 0 else { return nil }
        return L10n.text(
            "其中 \(ByteFormat.storageString(backup.sharedBytes)) 与其他备份共用（硬链接），合计只算一次。",
            "\(ByteFormat.storageString(backup.sharedBytes)) is shared with other backups (hard links) and counted once in the total."
        )
    }

    static func notices(_ inventory: MobileDeviceBackupInventory) -> [String] {
        guard inventory.rootState == .readable else { return [] }
        var lines = [String]()
        if inventory.skippedSymbolicLinkCount > 0 {
            lines.append(L10n.text(
                "跳过 \(ByteFormat.count(inventory.skippedSymbolicLinkCount)) 个符号链接，未跟随、未计入",
                "Skipped " + L10n.englishCount(inventory.skippedSymbolicLinkCount, "symbolic link", "symbolic links")
                    + "; not followed or counted"
            ))
        }
        if inventory.skippedDeepFolderCount > 0 {
            lines.append(L10n.text(
                "\(ByteFormat.count(inventory.skippedDeepFolderCount)) 个文件夹层级过深，未进入、未计入",
                L10n.englishCount(inventory.skippedDeepFolderCount, "folder", "folders") + " nested too deep; skipped and not counted"
            ))
        }
        if inventory.unreadableFolderCount > 0 {
            lines.append(L10n.text(
                "\(ByteFormat.count(inventory.unreadableFolderCount)) 个文件夹无法读取，未计入，结果不完整",
                L10n.englishCount(inventory.unreadableFolderCount, "folder", "folders") + " unreadable; not counted, results are incomplete"
            ))
        }
        if inventory.stoppedEarly {
            lines.append(L10n.text("条目过多或已停止，结果不完整", "Too many entries or stopped; results are incomplete"))
        }
        return lines
    }
}

/// D116 G11：iPhone、iPad 备份只读盘点。打开时在后台读一次，不提供删除。
struct MobileDeviceBackupInventorySheet: View {
    @Environment(\.colorScheme) private var scheme
    let onClose: () -> Void
    var scanner = MobileDeviceBackupInventoryScanner()
    @State private var inventory: MobileDeviceBackupInventory?

    var body: some View {
        let palette = FeatureLightfieldPalette.resolve(scheme)
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("iPhone 和 iPad 备份", "iPhone and iPad Backups")).font(.system(size: 24, weight: .semibold))
            Text(MobileDeviceBackupPresentation.readOnlyNote).font(.system(size: 13)).foregroundStyle(palette.fg2)
                .fixedSize(horizontal: false, vertical: true)
            if let inventory {
                Text(MobileDeviceBackupPresentation.summary(inventory)).font(.system(size: 15, weight: .semibold))
                    .lightfieldComponentProbe("deviceBackups.summary")
                if let detail = MobileDeviceBackupPresentation.stateDetail(inventory) {
                    Text(detail).font(.system(size: 13)).foregroundStyle(palette.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(inventory.backups) { backup in row(backup) }
                        ForEach(MobileDeviceBackupPresentation.notices(inventory), id: \.self) { line in
                            Text(line).font(.system(size: 13)).foregroundStyle(palette.fg2)
                                .fixedSize(horizontal: false, vertical: true).padding(.vertical, 6)
                        }
                    }
                }
            } else {
                Text(L10n.text("正在读取备份文件夹…", "Reading the backup folder…")).font(.system(size: 15))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            HStack(spacing: 12) {
                Button(L10n.text("返回", "Back"), action: onClose).buttonStyle(FeatureLightfieldRowButtonStyle())
                if inventory?.rootState == .unreadable {
                    Button(L10n.text("打开完全磁盘访问权限设置", "Open Full Disk Access Settings")) {
                        CleanupService.openFullDiskAccessSettings()
                    }.buttonStyle(FeatureLightfieldRowButtonStyle())
                }
                if let inventory, inventory.rootState == .readable {
                    Button(L10n.text("在访达中显示备份文件夹", "Show Backup Folder in Finder")) {
                        try? CleanupService.reveal(inventory.rootPath)
                    }.buttonStyle(FeatureLightfieldRowButtonStyle())
                }
            }
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

    private func row(_ backup: MobileDeviceBackup) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(MobileDeviceBackupPresentation.title(backup)).font(.system(size: 15)).lineLimit(1).truncationMode(.middle)
                Text(MobileDeviceBackupPresentation.detail(backup)).font(.system(size: 13))
                    .foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2).lineLimit(1)
                if let sharing = MobileDeviceBackupPresentation.sharing(backup) {
                    Text(sharing).font(.system(size: 13)).foregroundStyle(FeatureLightfieldPalette.resolve(scheme).fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(ByteFormat.storageString(backup.bytes)).font(.system(size: 15)).monospacedDigit().lineLimit(1)
        }.padding(.vertical, 8)
            .overlay(alignment: .bottom) { FeatureLightfieldHairline() }
            .accessibilityElement(children: .combine)
            .contextMenu {
                Button(L10n.text("在访达中显示", "Show in Finder")) { try? CleanupService.reveal(backup.location) }
            }
    }
}
