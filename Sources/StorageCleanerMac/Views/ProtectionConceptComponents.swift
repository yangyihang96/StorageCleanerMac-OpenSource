import SwiftUI

/// Non-data decoration for the privacy landing state. Interactive filters and
/// records remain separate SwiftUI controls owned by BrowserPrivacyStore.
struct PrivacyConceptArtwork: View {
    let tint: Color
    @Environment(\.moduleTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width * 0.90, proxy.size.height * 0.75)
            VStack(spacing: 24) {
                ZStack {
                    if theme.isImmersive, let image = GoldenLandingAsset.browserPrivacy.image {
                        GoldenLandingArtwork(image: image)
                    } else {
                        ForEach([CGFloat(0.60), 0.76, 0.90, 1], id: \.self) { scale in
                            Circle().stroke(tint.opacity(scale == 0.76 ? 0.42 : 0.17), lineWidth: 0.8)
                                .frame(width: diameter * scale, height: diameter * scale)
                        }
                        Image(systemName: "shield.fill")
                            .font(.system(size: diameter * 0.48, weight: .regular))
                            .foregroundStyle(LinearGradient(colors: [.green, tint.opacity(0.68)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .shadow(color: tint.opacity(0.22), radius: 12)
                            .overlay {
                                Image(systemName: "shield")
                                    .font(.system(size: diameter * 0.43, weight: .regular))
                                    .foregroundStyle(tint.opacity(0.85))
                                Image(systemName: "lock.fill")
                                    .font(.system(size: diameter * 0.12, weight: .medium))
                                    .foregroundStyle(Color(red: 0.07, green: 0.36, blue: 0.20))
                            }
                        ForEach(0..<4) { index in
                            let angle = Double(index) * .pi / 2 - .pi * 0.68
                            Image(systemName: ["clock", "circle.dotted", "trash", "list.bullet.rectangle"][index])
                                .font(.system(size: diameter * 0.065, weight: .regular))
                                .foregroundStyle(tint)
                                .frame(width: diameter * 0.155, height: diameter * 0.155)
                                .background(Color(red: 0.04, green: 0.09, blue: 0.13), in: Circle())
                                .overlay(Circle().strokeBorder(tint.opacity(0.40)))
                                .offset(x: cos(angle) * diameter * 0.38, y: sin(angle) * diameter * 0.38)
                        }
                    }
                }
                .frame(width: diameter, height: diameter)
                HStack(spacing: 14) {
                    Image(systemName: "checklist")
                        .font(.system(size: 24, weight: .light))
                        .frame(width: 42, height: 42)
                        .background(AppAppearanceColors.ink.opacity(0.08), in: Circle())
                    Text(L10n.text("扫描后选择记录", "Select records after scanning"))
                        .font(AppTypography.cardTitle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(AppAppearanceColors.ink.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppAppearanceColors.ink.opacity(0.12)))
                .padding(.horizontal, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct HealthCheckScopeCards: View {
    @Environment(\.windowLayoutMetrics) private var layout
    private let checks: [(String, String, Color, [String])] = [
        (L10n.text("磁盘", "Disk"), "internaldrive.fill", .cyan,
         ["SMART", L10n.text("介质寿命", "Media lifespan"), L10n.text("可用容量", "Free space")]),
        (L10n.text("电池", "Battery"), "battery.75", .yellow,
         [L10n.text("最大容量", "Maximum capacity"), L10n.text("循环次数", "Cycle count"), L10n.text("电池状况", "Condition")]),
        (L10n.text("系统状态", "System"), "waveform.path.ecg.rectangle", .blue,
         [L10n.text("崩溃与卡顿", "Crashes & hangs"), "FileVault", L10n.text("备份状态", "Backup status")])
    ]

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(checks.indices, id: \.self) { index in
                let check = checks[index]
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: check.1)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: layout.isShort ? 32 : 46, weight: .regular))
                        .foregroundStyle(check.2)
                        .frame(maxWidth: .infinity, minHeight: layout.isShort ? 46 : 70)
                    Text(check.0)
                        .font(AppTypography.cardTitle)
                        .frame(maxWidth: .infinity)
                    ForEach(check.3, id: \.self) { label in
                        Text("· " + label)
                            .font(AppTypography.secondaryText)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, minHeight: layout.isShort ? 174 : 216, alignment: .top)
                .background(AppAppearanceColors.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(AppAppearanceColors.ink.opacity(0.12)))
            }
        }
    }
}
