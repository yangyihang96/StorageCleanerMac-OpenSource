import SwiftUI
import ImageIO

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

    var image: NSImage? { image(for: .dark) }

    func image(for scheme: ColorScheme) -> NSImage? {
        GoldenArtworkCache.image(named: resourceName(for: scheme))
    }

    func resourceName(for scheme: ColorScheme) -> String {
        rawValue + (scheme == .light ? "-Day" : "")
    }

}


/// Bounded, lazy image decoding shared by all decorative landing surfaces.
/// The key includes the source variant and raster size; views only resize the
/// decoded image, never run a luminance mask on every display update.
enum GoldenArtworkCache {
    nonisolated(unsafe) private static let cache: NSCache<NSString, NSImage> = {
        let value = NSCache<NSString, NSImage>()
        value.countLimit = 16
        value.totalCostLimit = 32 * 1024 * 1024
        return value
    }()

    static func image(named name: String, maximumPixels: Int = 1024) -> NSImage? {
        let pixels = min(1280, max(1, maximumPixels))
        let key = "\(name):\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        cache.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
        return image
    }
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

/// Night keeps the original screen compositing. Day assets have their own
/// alpha and opaque material detail; never infer transparency from brightness.
struct LandingArtworkCompositing: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    @ViewBuilder
    func body(content: Content) -> some View {
        if colorScheme == .dark {
            content.blendMode(.screen)
        } else {
            content.blendMode(.normal)
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
    /// Narrowest illustration column; below it the page drops the artwork and
    /// gives the actions the full width.
    static let artworkColumnMinimumWidth: CGFloat = 260

    struct Profile {
        let actionFraction: CGFloat
        let artworkScale: CGFloat
        let columnSpacing: CGFloat
        /// Narrowest action column that still shows the page's options without
        /// cutting them off in ordinary windows (size sweep in
        /// `ConceptLandingNativeLayoutRegressionTests`). Pages with denser
        /// options or a header action need more than the shared 400 pt.
        var minimumActionWidth: CGFloat = 400
    }

    /// Proportions measured independently in the 1624 × 969 references.
    static func profile(for symbol: String) -> Profile {
        switch symbol {
        case ReviewFilter.overview.systemImage: .init(actionFraction: 0.43, artworkScale: 1.0, columnSpacing: 20)
        case ReviewFilter.green.systemImage: .init(actionFraction: 0.43, artworkScale: 1.0, columnSpacing: 20)
        case ReviewFilter.devCaches.systemImage: .init(actionFraction: 0.522, artworkScale: 1.0, columnSpacing: 20, minimumActionWidth: 480)
        case ReviewFilter.energy.systemImage: .init(actionFraction: 0.40, artworkScale: 1.0, columnSpacing: 24)
        case ReviewFilter.privacy.systemImage: .init(actionFraction: 0.51, artworkScale: 1.0, columnSpacing: 22)
        case ReviewFilter.startup.systemImage: .init(actionFraction: 0.54, artworkScale: 1.0, columnSpacing: 18)
        case ReviewFilter.healthHub.systemImage: .init(actionFraction: 0.47, artworkScale: 1.0, columnSpacing: 20, minimumActionWidth: 470)
        case ReviewFilter.migration.systemImage: .init(actionFraction: 0.407, artworkScale: 1.0, columnSpacing: 18)
        case ReviewFilter.largeFiles.systemImage: .init(actionFraction: 0.384, artworkScale: 1.0, columnSpacing: 22)
        case ReviewFilter.duplicates.systemImage: .init(actionFraction: 0.462, artworkScale: 1.0, columnSpacing: 17)
        case ReviewFilter.updater.systemImage: .init(actionFraction: 0.46, artworkScale: 0.96, columnSpacing: 24, minimumActionWidth: 470)
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
                Text(L10n.text("文件系统已用", "Filesystem used"))
                Text(capacity.map { ByteFormat.string($0.usedBytes) + " / " + ByteFormat.string($0.totalBytes) } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text(L10n.text("预计可释放 —", "Potential savings —")).foregroundStyle(.secondary)
            }.font(.system(size: 10))
        }
        .accessibilityElement(children: .combine)
        .help(L10n.text("已用容量未扣除可回收空间；文件扫描尚未完成", "Used space has not subtracted reclaimable space; the file scan is not complete"))
        .accessibilityHint(L10n.text("根卷文件系统已用容量，未扣除可回收空间；文件扫描尚未完成", "Root filesystem used space has not subtracted reclaimable space; the file scan is not complete"))
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
    static func usesFileReferenceInsets(for symbol: String) -> Bool {
        [ReviewFilter.largeFiles.systemImage, ReviewFilter.migration.systemImage,
         ReviewFilter.duplicates.systemImage].contains(symbol)
    }

    static func headerIconSide(for symbol: String) -> CGFloat {
        switch symbol {
        case ReviewFilter.privacy.systemImage, ReviewFilter.startup.systemImage: 84
        case ReviewFilter.healthHub.systemImage, ReviewFilter.performance.systemImage, "speedometer": 88
        default: 100
        }
    }
    static func headerTitleSize(for symbol: String) -> CGFloat {
        switch symbol {
        case ReviewFilter.largeFiles.systemImage, ReviewFilter.migration.systemImage,
             ReviewFilter.duplicates.systemImage: 34
        case ReviewFilter.green.systemImage, ReviewFilter.devCaches.systemImage: 34
        case ReviewFilter.privacy.systemImage: 32
        case ReviewFilter.startup.systemImage: 30
        case ReviewFilter.healthHub.systemImage, ReviewFilter.performance.systemImage, "speedometer": 32
        default: 36
        }
    }

    static func headerSpacing(for symbol: String) -> CGFloat {
        if usesFileReferenceInsets(for: symbol)
            || symbol == ReviewFilter.green.systemImage
            || symbol == ReviewFilter.devCaches.systemImage { return 23 }
        return AppDesignTokens.Spacing.large
    }

    static func headerSymbolSize(for symbol: String) -> CGFloat {
        switch symbol {
        case ReviewFilter.green.systemImage: 56
        case ReviewFilter.devCaches.systemImage: 62
        default: 44
        }
    }

    static func actionColumnMaximumWidth(for symbol: String) -> CGFloat {
        switch symbol {
        case ReviewFilter.largeFiles.systemImage: 540
        case ReviewFilter.devCaches.systemImage: 660
        default: 570
        }
    }

    static func configurationInset(for symbol: String) -> CGFloat {
        switch symbol {
        case ReviewFilter.energy.systemImage, ReviewFilter.uninstall.systemImage,
             ReviewFilter.updater.systemImage: 22
        default: 16
        }
    }
}
