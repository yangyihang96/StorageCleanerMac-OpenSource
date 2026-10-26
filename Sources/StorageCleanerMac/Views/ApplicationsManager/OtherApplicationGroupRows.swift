import SwiftUI

/// D218: a group selects bundles only; expanding it exposes a checkbox for
/// each path. There is deliberately no related-resource disclosure here.
/// D225: Add to Ignore List on the app's row takes every copy, on a copy's
/// row that copy alone.
struct OtherApplicationGroupRows: View {
    @ObservedObject var model: ApplicationsManagerModel
    let group: OtherApplicationGroup
    let index: Int
    let copyPath: (String) -> Void
    let reveal: (String) -> Void
    @Environment(\.ignoreListFeedback) private var ignoreListFeedback

    private var isExpanded: Bool { model.expanded.contains(group.id) }
    private var selectedCount: Int { group.copies.filter { model.otherApplicationSelection.contains($0.path) }.count }

    var body: some View {
        VStack(spacing: 0) {
            Button { model.toggleOtherApplications(group) } label: {
                LightfieldListRow(kind: .uninstall, probeID: "otherApplications.group.\(index)") {
                    HStack(spacing: 16) {
                        FeatureLightfieldCheck(selected: selectedCount == group.copies.count, module: .uninstall,
                                               mixed: selectedCount > 0 && selectedCount < group.copies.count)
                        LightfieldAppIcon(path: group.copies.first?.path ?? "", size: .medium)
                    }
                } name: {
                    Text(group.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                } detail: {
                    if group.copies.count == 1, let copy = group.copies.first {
                        LightfieldPathText(path: copy.path)
                    } else {
                        Text(L10n.text("\(ByteFormat.count(group.copies.count)) 份副本 · 展开查看路径",
                                       "\(ByteFormat.count(group.copies.count)) copies · Expand to see paths"))
                            .font(.system(size: 12)).foregroundStyle(CareStudioManagerInk.secondary)
                    }
                } trailing: {
                    HStack(spacing: 4) {
                        Text(ByteFormat.storageString(group.sizeBytes)).font(.system(size: 15)).monospacedDigit()
                        Color.clear.frame(width: 20, height: 20)
                    }
                }
            }
            .buttonStyle(FeatureLightfieldRowButtonStyle())
            .accessibilityLabel(group.name)
            .accessibilityValue(L10n.text("已选择 \(selectedCount) 份，共 \(group.copies.count) 份",
                                         "\(selectedCount) of \(group.copies.count) copies selected"))
            // D225 (CleanMyMac's Add to Ignore List): every copy, by path, under Uninstaller.
            .contextMenu {
                if let ignoreListFeedback {
                    Button(IgnoreListMenu.title(count: group.copies.count)) {
                        model.ignoreOtherApplications(group.copies.map(\.path), feedback: ignoreListFeedback)
                    }
                    .disabled(!model.canIgnore)
                }
            }
            .overlay(alignment: .trailing) {
                Button {
                    if isExpanded { model.expanded.remove(group.id) } else { model.expanded.insert(group.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(CareStudioManagerInk.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(FeatureLightfieldRowButtonStyle())
                .accessibilityLabel(isExpanded ? L10n.text("收起副本", "Collapse Copies") : L10n.text("展开副本", "Expand Copies"))
                .padding(.trailing, 6)
            }
            if isExpanded {
                ForEach(group.copies) { copy in
                    copyRow(copy)
                }
            }
        }
    }

    private func copyRow(_ copy: InstalledAppItem) -> some View {
        Button { model.toggleOtherApplication(copy.path) } label: {
            HStack(spacing: 12) {
                FeatureLightfieldCheck(selected: model.otherApplicationSelection.contains(copy.path), module: .uninstall)
                VStack(alignment: .leading, spacing: 4) {
                    LightfieldPathText(path: copy.path)
                    Text(copy.modifiedAt.map {
                        L10n.text("修改于 ", "Modified ") + $0.formatted(date: .abbreviated, time: .shortened)
                    } ?? L10n.text("修改时间未知", "Modification date unknown"))
                        .font(.system(size: 11)).foregroundStyle(CareStudioManagerInk.secondary)
                }
                Spacer(minLength: 8)
                Text(ByteFormat.storageString(copy.sizeBytes)).font(.system(size: 13)).monospacedDigit()
            }
            .foregroundStyle(CareStudioManagerInk.primary)
            .padding(.leading, 28).padding(.trailing, 26).padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(FeatureLightfieldRowButtonStyle())
        .accessibilityLabel(copy.path)
        .accessibilityValue(model.otherApplicationSelection.contains(copy.path) ? L10n.text("已选择", "Selected") : L10n.text("未选择", "Not Selected"))
        .contextMenu {
            Button(L10n.text("复制路径", "Copy Path")) { copyPath(copy.path) }
            // D225 补: the app's own wording (“在访达中显示” throughout).
            Button(L10n.text("在访达中显示", "Show in Finder")) { reveal(copy.path) }
            // D225: this copy alone.
            if let ignoreListFeedback {
                Button(IgnoreListMenu.title(count: 1)) {
                    model.ignoreOtherApplications([copy.path], feedback: ignoreListFeedback)
                }
                .disabled(!model.canIgnore)
            }
        }
    }
}
