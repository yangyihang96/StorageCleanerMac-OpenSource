import SwiftUI

struct MetadataPill: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(AppDesignTokens.Typography.compactSymbol)
                .foregroundStyle(tint)
                .frame(width: 14)
                .accessibilityHidden(true)

            Text(text)
                .font(AppDesignTokens.Typography.metadata)
                .foregroundStyle(AppDesignTokens.Palette.secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, AppDesignTokens.Layout.metadataPillHorizontalPadding)
        .padding(.vertical, AppDesignTokens.Layout.metadataPillVerticalPadding)
        .glassCapsule(tint: tint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }
}
