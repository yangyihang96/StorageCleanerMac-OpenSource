import SwiftUI

/// Reference-derived non-data artwork. Each bitmap contains only illustration;
/// production controls, status, measurement and accessibility remain native.
enum GoldenLandingAsset: String, CaseIterable {
    case health = "GoldenArtwork-Health-v1"
    case memory = "GoldenArtwork-Memory-v1"
    case startup = "GoldenArtwork-Startup-v1"
    case energyFlow = "GoldenArtwork-EnergyFlow-v1"
    case migrationFlow = "GoldenArtwork-MigrationFlow-v1"
    case uninstall = "GoldenArtwork-Uninstall-v1"
    case appUpdates = "GoldenArtwork-AppUpdates-v1"
    case duplicateFiles = "GoldenArtwork-DuplicateFiles-v1"
    case smartScan = "GoldenArtwork-SmartScan-v1"
    case developerArtifacts = "GoldenArtwork-DeveloperArtifacts-v1"
    case browserPrivacy = "GoldenArtwork-BrowserPrivacy-v1"

    // Decode once, not on telemetry publication or every SwiftUI body update.
    private static let images: [Self: NSImage] = Dictionary(uniqueKeysWithValues:
        allCases.compactMap { asset in
            guard let url = Bundle.main.url(forResource: asset.rawValue, withExtension: "png"),
                  let image = NSImage(contentsOf: url) else { return nil }
            return (asset, image)
        }
    )

    var image: NSImage? { Self.images[self] }
}

struct GoldenLandingArtwork: View {
    let image: NSImage

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(width: side, height: side)
                .clipped()
                .modifier(LandingArtworkCompositing())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Screen blending preserves the original night artwork but disappears on a
/// white canvas. In daylight, use the source luminance as an alpha mask while
/// retaining its RGB colors. The original bundled illustration is unchanged.
struct LandingArtworkCompositing: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.blendMode(.screen)
        } else {
            // Double the mask's midtones without lifting pure black. This
            // retains colored detail instead of making the artwork look disabled.
            content.mask(content.brightness(0.25).contrast(2).luminanceToAlpha())
        }
    }
}

/// Sizes taken from the main-window golden references, with smaller slots only
/// when the actual window cannot fit the regular composition.
enum GoldenLandingMetrics {
    static let outerInset: CGFloat = 8
    static let innerInset: CGFloat = 22
    static let topInset: CGFloat = 30
    static let scopeControlHeight: CGFloat = 38
    static let locationButtonHeight: CGFloat = 62
    static let statusIconSize: CGFloat = 36
}


extension GoldenLandingMetrics {
    struct Profile {
        let actionFraction: CGFloat
        let artworkScale: CGFloat
        let columnSpacing: CGFloat
    }

    /// Proportions measured independently in the 1624 × 969 references.
    static func profile(for symbol: String) -> Profile {
        switch symbol {
        case ReviewFilter.energy.systemImage: .init(actionFraction: 0.40, artworkScale: 1.0, columnSpacing: 24)
        case ReviewFilter.privacy.systemImage: .init(actionFraction: 0.51, artworkScale: 0.90, columnSpacing: 22)
        case ReviewFilter.startup.systemImage: .init(actionFraction: 0.54, artworkScale: 0.94, columnSpacing: 18)
        case ReviewFilter.healthHub.systemImage: .init(actionFraction: 0.47, artworkScale: 1.0, columnSpacing: 20)
        case ReviewFilter.migration.systemImage: .init(actionFraction: 0.45, artworkScale: 1.0, columnSpacing: 22)
        case ReviewFilter.largeFiles.systemImage: .init(actionFraction: 0.43, artworkScale: 1.0, columnSpacing: 24)
        case ReviewFilter.updater.systemImage: .init(actionFraction: 0.46, artworkScale: 0.96, columnSpacing: 24)
        case ReviewFilter.uninstall.systemImage: .init(actionFraction: 0.47, artworkScale: 0.95, columnSpacing: 20)
        default: .init(actionFraction: 0.47, artworkScale: 1.0, columnSpacing: 20)
        }
    }
}

/// Filesystem capacity and scan savings have separate meanings and lifetimes.
struct GoldenUnmeasuredCapacity: View {
    @State private var capacity: StorageCapacitySnapshot?
    @State private var sampledAt: Date?
    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 4)
                if let capacity, capacity.totalBytes > 0 {
                    Circle().trim(from: 0, to: capacity.usedRatio)
                        .stroke(Color.mint, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
            }
            .frame(width: 50, height: 50)
            .overlay(Text(capacity.map { "\(Int(($0.usedRatio * 100).rounded()))%" } ?? "—")
                .font(.system(size: 12, weight: .medium)).monospacedDigit())
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("磁盘已用", "Disk used"))
                Text(capacity.map { ByteFormat.string($0.usedBytes) + " / " + ByteFormat.string($0.totalBytes) } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text(L10n.text("预计可释放 —", "Potential savings —")).foregroundStyle(.secondary)
            }.font(.system(size: 10))
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(L10n.text("根卷文件系统容量；重复文件尚未扫描", "Root filesystem capacity; duplicates not yet scanned"))
        .task {
            guard sampledAt == nil else { return }
#if DEBUG || STORAGE_CLEANER_BETA
            guard !MiniWindowDemoData.isEnabled else { return }
#endif
            capacity = await Task.detached(priority: .utility) { StorageCapacityService.snapshot() }.value
            sampledAt = Date()
        }
    }
}

extension GoldenLandingMetrics {
    static func headerIconSide(for symbol: String) -> CGFloat {
        switch symbol {
        case ReviewFilter.privacy.systemImage, ReviewFilter.startup.systemImage: 76
        case ReviewFilter.healthHub.systemImage, ReviewFilter.performance.systemImage, "speedometer": 88
        default: 100
        }
    }
    static func headerTitleSize(for symbol: String) -> CGFloat {
        switch symbol {
        case ReviewFilter.privacy.systemImage, ReviewFilter.startup.systemImage: 28
        case ReviewFilter.healthHub.systemImage, ReviewFilter.performance.systemImage, "speedometer": 32
        default: 36
        }
    }
}
