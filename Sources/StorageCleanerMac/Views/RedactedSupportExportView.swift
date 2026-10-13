import SwiftUI
import UniformTypeIdentifiers

struct RedactedSupportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct RedactedSupportExportView: View {
    let snapshot: RedactedSupportSnapshot
    @Environment(\.dismiss) private var dismiss
    @State private var isExporting = false
    @State private var document = RedactedSupportDocument(data: Data())
    @State private var notice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L10n.text("脱敏支持包", "Redacted Support Bundle"))
                    .font(AppDesignTokens.Typography.sectionTitle)
                Spacer()
                Button(L10n.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isExporting)
            }
            Text(L10n.text("仅保存到本地，不上传；不含身份、路径、IP、密钥、进程清单与文件内容。",
                "Saved locally, never uploaded; excludes identity, paths, IPs, secrets, process lists and file contents."))
                .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent(L10n.text("版本", "Version"), value: snapshot.appVersion ?? "—")
                    LabeledContent(L10n.text("构建号", "Build"), value: snapshot.appBuild ?? "—")
                    LabeledContent(L10n.text("通道", "Channel"), value: snapshot.channel)
                    LabeledContent("macOS", value: snapshot.macOSVersion)
                    LabeledContent(L10n.text("处理器架构", "Architecture"), value: snapshot.architecture)
                    AppSeparator()
                    LabeledContent(L10n.text("已加载操作记录（最多 100 条）", "Loaded Operations (up to 100)"), value: String(snapshot.loadedOperationCount))
                    ForEach(snapshot.operationStates.keys.sorted(), id: \.self) { key in
                        LabeledContent(stateTitle(key), value: String(snapshot.operationStates[key] ?? 0))
                    }
                    DisclosureGroup(L10n.text("完整导出内容（JSON）", "Complete Export (JSON)")) {
                        Text(preview).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }.padding(12)
            }
            .background(AppAppearanceColors.secondarySurface, in: RoundedRectangle(cornerRadius: 10))
            if let notice { Text(notice).font(AppDesignTokens.Typography.metadata) }
            HStack {
                Spacer()
                Button(L10n.text("导出 JSON…", "Export JSON…")) {
                    do {
                        document = RedactedSupportDocument(data: try snapshot.encoded())
                        notice = nil
                        isExporting = true
                    } catch { notice = L10n.text("无法生成支持包。", "Unable to prepare the support bundle.") }
                }.appButtonChrome(.primary).disabled(isExporting)
            }
        }
        .padding(20)
        .frame(minWidth: 380, idealWidth: 640, minHeight: 360, idealHeight: 520)
        .background(AppAppearanceColors.panel)
        .fileExporter(isPresented: $isExporting, document: document, contentType: .json,
            defaultFilename: "StorageCleanerMac-Support") { result in
                switch result {
                case .success: notice = L10n.text("已导出到本地。", "Exported locally.")
                case .failure: notice = L10n.text("未能保存支持包；请检查所选位置。", "Could not save the support bundle. Check the selected location.")
                }
            }
    }

    private func stateTitle(_ key: String) -> String {
        switch key {
        case "processing": L10n.text("处理中", "Processing")
        case "draining": L10n.text("取消收尾", "Finishing cancellation")
        case "completed": L10n.text("已完成", "Completed")
        case "partial": L10n.text("部分完成", "Partially completed")
        case "failed": L10n.text("失败", "Failed")
        case "cancelled": L10n.text("已取消", "Cancelled")
        case "needsVerification": L10n.text("待核实", "Needs verification")
        case "partiallyRestored": L10n.text("部分恢复", "Partially restored")
        case "restored": L10n.text("已全部恢复", "Fully restored")
        case "retained": L10n.text("已保留", "Retained")
        case "recoveryFailed": L10n.text("恢复失败", "Restore failed")
        default: L10n.text("状态未知", "Unknown state")
        }
    }

    private var preview: String {
        guard let data = try? snapshot.encoded(), let text = String(data: data, encoding: .utf8) else {
            return L10n.text("无法生成预览。", "Preview unavailable.")
        }
        return text
    }
}
