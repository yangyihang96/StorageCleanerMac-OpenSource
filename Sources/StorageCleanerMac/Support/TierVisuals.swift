import SwiftUI

extension StorageTier {
    var color: Color {
        switch self {
        case .green: AppDesignTokens.Palette.success
        case .yellow: AppDesignTokens.Palette.warning
        case .red: AppDesignTokens.Palette.destructive
        case .other: AppDesignTokens.Palette.information
        }
    }

    var softColor: Color {
        color.opacity(0.12)
    }
}

