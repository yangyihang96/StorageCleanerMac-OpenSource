import AppKit
import SwiftUI

/// Read-only leads next to the app uninstaller. The scanner never feeds the
/// uninstall plan because absence from an inventory does not establish owner.
struct ResidualFileEvidenceView: View {
    @Environment(\.dismiss) private var dismiss
    let installedBundleIdentifiers: Set<String>
    let inventoryComplete: Bool

    @State private var result: ResidualFileEvidenceScanner.Result?
    @State private var worker: Task<ResidualFileEvidenceScanner.Result, Never>?
    @State private var generation: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text("残留文件线索", "Residual File Leads"))
                        .font(AppDesignTokens.Typography.sectionTitle)
                    Text(L10n.text(
                        "只读线索，不会加入清理计划",
                        "Read-only leads; excluded from cleanup plans"
                    ))
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button(L10n.text("关闭", "Close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    startScan()
                } label: {
                    Text(L10n.text("检查线索", "Check Leads"))
                }
                .disabled(worker != nil)
            }

            Text(L10n.text(
                "未匹配到应用不代表可以删除",
                "No app match does not mean safe to delete"
            ))
            .font(AppDesignTokens.Typography.secondary)
            .foregroundStyle(AppDesignTokens.Palette.information)

            if !inventoryComplete {
                Label(
                    L10n.text(
                        "应用清单尚未完整；未匹配到应用不代表文件已经孤立。",
                        "The app inventory is incomplete; an unmatched entry is not proof that it is orphaned."
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(AppDesignTokens.Palette.warning)
                .font(AppDesignTokens.Typography.secondary)
            }

            if worker != nil {
                ProgressView(L10n.text("正在检查本机文件名", "Checking local file names"))
            }

            if let result {
                Text(L10n.text(
                    "已检查 \(ByteFormat.count(result.inspectedEntryCount)) 项 · \(ByteFormat.count(result.candidates.count)) 条待复核线索",
                    "\(ByteFormat.count(result.inspectedEntryCount)) inspected · \(ByteFormat.count(result.candidates.count)) leads for review"
                ))
                .font(AppDesignTokens.Typography.secondary)
                .foregroundStyle(.secondary)
                if result.reachedLimit || result.unreadableRootCount > 0 || result.cancelled {
                    Label(
                        L10n.text("检查不完整，结果仅覆盖已读取位置。", "The check is incomplete; results cover only readable locations."),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(AppDesignTokens.Typography.secondary)
                    .foregroundStyle(AppDesignTokens.Palette.warning)
                }
                if result.candidates.isEmpty {
                    ContentUnavailableView {
                        Text(L10n.text("没有发现线索", "No Leads Found"))
                    } description: {
                        Text(L10n.text(
                            "这不是整个磁盘或所有应用数据的证明。",
                            "This does not prove that the whole disk or all app data is clear."
                        ))
                    }
                } else {
                    List(result.candidates) { candidate in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.bundleIdentifier)
                                    .font(AppDesignTokens.Typography.compactLabelEmphasis)
                                    .lineLimit(1)
                                Text(candidate.path)
                                    .font(AppDesignTokens.Typography.metadata)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 8)
                            Text(candidate.location)
                                .font(AppDesignTokens.Typography.metadata)
                                .foregroundStyle(.secondary)
                            Button(L10n.text("在访达中显示", "Show in Finder")) {
                                NSWorkspace.shared.activateFileViewerSelecting([
                                    URL(fileURLWithPath: candidate.path)
                                ])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .background(AppAppearanceColors.panel, in: RoundedRectangle(cornerRadius: 10))
                }
            } else if worker == nil {
                ContentUnavailableView {
                    Text(L10n.text("尚未检查", "Not Checked Yet"))
                } description: {
                    Text(L10n.text(
                        "按需只读检查，不会自动删除。",
                        "Run a read-only check when needed; nothing is removed automatically."
                    ))
                }
            }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 430)
        .background(AppAppearanceColors.canvasTop)
        .tint(AppAppearanceColors.controlAccent)
        .onDisappear {
            generation = nil
            worker?.cancel()
            worker = nil
        }
    }

    private func startScan() {
        guard worker == nil else { return }
        result = nil
        let currentGeneration = UUID()
        generation = currentGeneration
        let installedIDs = installedBundleIdentifiers
        let operation = Task.detached(priority: .utility) {
            ResidualFileEvidenceScanner.scan(
                installedBundleIdentifiers: installedIDs
            )
        }
        worker = operation
        Task { @MainActor in
            let scanned = await operation.value
            guard generation == currentGeneration else { return }
            result = scanned
            worker = nil
            generation = nil
        }
    }
}
