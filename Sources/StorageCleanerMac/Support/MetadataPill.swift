import SwiftUI

/// Symbols here communicate a state, rather than the pill's data category.
/// Callers must opt in; a legacy systemImage alone never enables a symbol.
enum MetadataPillStatus: CaseIterable, Equatable, Sendable {
    case none
    case locked
    case warning
    case failure
    case readOnly
    case systemSettingsOnly

    var systemImage: String? {
        switch self {
        case .none: nil
        case .locked: "lock.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .readOnly: "lock"
        case .systemSettingsOnly: "gearshape"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .none: ""
        case .locked: L10n.text("需要管理员", "Administrator Required")
        case .warning: L10n.text("警告", "Warning")
        case .failure: L10n.text("失败", "Failed")
        case .readOnly: L10n.text("只读", "Read-only")
        case .systemSettingsOnly: L10n.text("仅系统设置", "System Settings Only")
        }
    }
}

struct MetadataPill: View {
    let text: String
    // Kept for source compatibility; category/decorative symbols stay hidden.
    let systemImage: String
    let tint: Color
    let status: MetadataPillStatus

    init(text: String, systemImage: String, tint: Color, status: MetadataPillStatus = .none) {
        self.text = text
        self.systemImage = systemImage
        self.tint = tint
        self.status = status
    }

    var renderedSystemImage: String? { status.systemImage }

    var body: some View {
        HStack(spacing: AppDesignTokens.Spacing.compact) {
            if let renderedSystemImage {
                Image(systemName: renderedSystemImage)
                    .accessibilityHidden(true)
            }
            Text(text)
        }
        .font(AppDesignTokens.Typography.metadata)
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, AppDesignTokens.Layout.metadataPillHorizontalPadding)
        .padding(.vertical, AppDesignTokens.Layout.metadataPillVerticalPadding)
        .glassCapsule(tint: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityValue(status.accessibilityDescription)
    }
}
