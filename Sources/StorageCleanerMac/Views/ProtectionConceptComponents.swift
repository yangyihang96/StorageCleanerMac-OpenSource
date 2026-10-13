import SwiftUI

/// Non-data decoration for the privacy landing state. Interactive filters and
/// records remain separate SwiftUI controls owned by BrowserPrivacyStore.
struct PrivacyConceptArtwork: View {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color
    @Environment(\.moduleTheme) private var theme

    var body: some View {
        GeometryReader { proxy in
            let diameter = min(proxy.size.width * 0.90, proxy.size.height * 0.75)
            VStack(spacing: 24) {
                ZStack {
                    if theme.isImmersive, let image = GoldenLandingAsset.browserPrivacy.image(for: colorScheme) {
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
    @AppSurfaces private var surfaces
    @Environment(\.windowLayoutMetrics) private var layout
    @Environment(\.featureCardPresentation) private var cardPresentation
    let internalBatteryAvailability: InternalBatteryAvailability

    enum CheckKind: String, Hashable {
        case disk, battery, system
    }

    struct Check: Identifiable {
        let id: CheckKind
        let title: String
        let systemImage: String
        let tint: Color
        let details: [String]
    }

    // Scope is driven by the latest native capability, never by chip names or
    // a previously saved health scan. Unknown has no claimed battery metrics.
    var checks: [Check] {
        var result = [Check(id: .disk, title: L10n.text("磁盘", "Disk"),
                            systemImage: "internaldrive.fill", tint: AppIconPalette.scope(.protection, index: 0, night: MonitorPalette.cyan),
                            details: ["SMART", L10n.text("介质寿命", "Media lifespan"),
                                      L10n.text("可用容量", "Free space")])]
        if internalBatteryAvailability != .absent {
            let isConfirmed = internalBatteryAvailability == .present
            result.append(Check(
                id: .battery, title: L10n.text("电池", "Battery"),
                systemImage: isConfirmed ? "battery.75" : "questionmark.circle", tint: AppIconPalette.scope(.protection, index: 1, night: MonitorPalette.yellow),
                details: isConfirmed
                    ? [L10n.text("最大容量", "Maximum capacity"), L10n.text("循环次数", "Cycle count"),
                       L10n.text("电池状况", "Condition")]
                    : [L10n.text("内置电池待确认", "Internal battery not confirmed")]
            ))
        }
        result.append(Check(id: .system, title: L10n.text("系统状态", "System"),
                            systemImage: "waveform.path.ecg.rectangle", tint: AppIconPalette.scope(.protection, index: 2, night: MonitorPalette.blue),
                            details: [L10n.text("崩溃与卡顿", "Crashes & hangs"), "FileVault",
                                      L10n.text("备份状态", "Backup status")]))
        return result
    }

    var body: some View {
        if cardPresentation == .legacy {
            fullCards
        } else {
            FeatureOptionList {
                ForEach(checks) { check in
                    FeatureOptionCard(padding: 0) {
                        HStack(spacing: 8) {
                            Text(check.title).font(FeaturePageTokens.optionTitleFont)
                                .foregroundStyle(surfaces.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if check.id == .battery && internalBatteryAvailability == .unknown {
                                Text(L10n.text("内置电池待确认", "Internal battery not confirmed"))
                                    .font(AppDesignTokens.TypeScale.caption).foregroundStyle(surfaces.textSecondary)
                                    .lineLimit(1)
#if DEBUG
                                    .layoutProbe("health.scope.availability.battery")
#endif
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, minHeight: FeaturePageTokens.optionRowMinimumHeight)
                    }
                    .help(check.details.joined(separator: " · "))
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(check.details.joined(separator: " · "))
                }
            }
        }
    }

    private var fullCards: some View {
        CardLayout {
            ForEach(checks) { check in
                FeatureOptionCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text(check.title)
                        .font(AppDesignTokens.TypeScale.bodyEmphasis)
                        .foregroundStyle(surfaces.textPrimary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
#if DEBUG
                        .layoutProbe("health.scope.title.\(check.id.rawValue)")
#endif
                    if check.id == .battery && internalBatteryAvailability == .unknown {
                        Text(L10n.text("内置电池待确认", "Internal battery not confirmed"))
                            .font(AppDesignTokens.TypeScale.secondary).foregroundStyle(surfaces.textSecondary)
                            .lineLimit(1)
#if DEBUG
                            .layoutProbe("health.scope.availability.battery")
#endif
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 56,
                       maxHeight: .infinity, alignment: .top)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("health.scope.card.\(check.id.rawValue)")
#if DEBUG
                .layoutProbe("health.scope.card.\(check.id.rawValue)")
#endif
            }
        }
#if DEBUG
        .layoutProbe("health.scope")
#endif
    }

    /// Use the actual card proposal, which is narrower than the page viewport.
    /// Limit columns to the real item count so an absent battery leaves no slot.
    private struct CardLayout: Layout {
        private let minimumCardWidth: CGFloat = 128
        private let spacing: CGFloat = 10

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard !subviews.isEmpty else { return .zero }
            let naturalWidth = minimumCardWidth * CGFloat(subviews.count)
                + spacing * CGFloat(subviews.count - 1)
            let width = proposal.width.flatMap { $0.isFinite ? max(1, $0) : nil } ?? naturalWidth
            let rows = rowMetrics(width: width, subviews: subviews)
            return CGSize(width: width,
                          height: rows.heights.reduce(0, +) + spacing * CGFloat(rows.heights.count - 1))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            guard !subviews.isEmpty else { return }
            let rows = rowMetrics(width: bounds.width, subviews: subviews)
            var y = bounds.minY
            for (row, height) in rows.heights.enumerated() {
                let first = row * rows.columns
                for index in first..<min(first + rows.columns, subviews.count) {
                    subviews[index].place(
                        at: CGPoint(x: bounds.minX + CGFloat(index - first) * (rows.cardWidth + spacing), y: y),
                        anchor: .topLeading,
                        proposal: ProposedViewSize(width: rows.cardWidth, height: height)
                    )
                }
                y += height + spacing
            }
        }

        private func rowMetrics(width: CGFloat, subviews: Subviews) -> (columns: Int, cardWidth: CGFloat, heights: [CGFloat]) {
            let columns = min(subviews.count, max(1, Int((width + spacing) / (minimumCardWidth + spacing))))
            let cardWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            var heights = [CGFloat]()
            for first in stride(from: 0, to: subviews.count, by: columns) {
                let height = (first..<min(first + columns, subviews.count)).map {
                    subviews[$0].sizeThatFits(ProposedViewSize(width: cardWidth, height: nil)).height
                }.max() ?? 0
                heights.append(height)
            }
            return (columns, cardWidth, heights)
        }
    }
}
