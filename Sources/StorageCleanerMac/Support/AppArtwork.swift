import AppKit
@preconcurrency import CoreImage
import ImageIO
import SwiftUI

enum AppArtwork {
    nonisolated(unsafe) private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 14
        return cache
    }()
    private static let maximumDecodedIconPixels = 512
    private static let dockIconBlendContext = CIContext(options: [
        .cacheIntermediates: false,
    ])
    @MainActor private static var dockIconTransitionTask: Task<Void, Never>?
    @MainActor private static var renderedDockIcon: NSImage?
    @MainActor private static var targetDockIconScheme: ColorScheme?

    static func image(named resourceName: String) -> NSImage? {
        let cacheKey = resourceName as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }

        let image: NSImage?
        if let url = Bundle.main.url(forResource: resourceName, withExtension: "png") {
            image = decodedImage(at: url)
        } else {
            let localURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/\(resourceName).png")
            image = decodedImage(at: localURL)
        }

        if let image {
            imageCache.setObject(image, forKey: cacheKey)
        }
        return image
    }

    static func iconImage() -> NSImage? {
        image(named: "AppIconClean") ?? image(named: "AppIcon")
    }

    static func iconImage(for colorScheme: ColorScheme) -> NSImage? {
        let suffix = assetSuffix(for: colorScheme)
        let cacheKey = "AppIconResolved\(suffix)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            return cached
        }
        guard let baseImage = image(named: "AppIconClean\(suffix)")
            ?? image(named: "AppIcon\(assetSuffix(for: colorScheme))")
            ?? iconImage() else { return nil }

        let resolvedImage = NSImage(size: baseImage.size)
        for representation in baseImage.representations {
            if let copy = representation.copy() as? NSImageRep {
                resolvedImage.addRepresentation(copy)
            }
        }
        for logicalSize in [16, 32, 64] {
            guard let source = image(named: "AppIconRuntime\(suffix)\(logicalSize)") else {
                continue
            }
            var sourceRect = NSRect(origin: .zero, size: source.size)
            guard let cgImage = source.cgImage(
                forProposedRect: &sourceRect,
                context: nil,
                hints: nil
            ) else { continue }
            let representation = NSBitmapImageRep(cgImage: cgImage)
            representation.size = NSSize(width: logicalSize, height: logicalSize)
            resolvedImage.addRepresentation(representation)
        }
        imageCache.setObject(resolvedImage, forKey: cacheKey)
        return resolvedImage
    }

    @MainActor
    static func applyDockIcon(for colorScheme: ColorScheme) {
        guard targetDockIconScheme != colorScheme,
              let targetImage = iconImage(for: colorScheme) else { return }

        targetDockIconScheme = colorScheme
        dockIconTransitionTask?.cancel()

        guard let startImage = renderedDockIcon,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              !ProcessInfo.processInfo.isLowPowerModeEnabled,
              NSApp.isActive else {
            renderedDockIcon = targetImage
            NSApp.applicationIconImage = targetImage
            dockIconTransitionTask = nil
            return
        }

        dockIconTransitionTask = Task { @MainActor in
            let totalSteps = 18
            for step in 1...totalSteps {
                try? await Task.sleep(for: .milliseconds(16))
                guard !Task.isCancelled else { return }
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                    || ProcessInfo.processInfo.isLowPowerModeEnabled || !NSApp.isActive {
                    renderedDockIcon = targetImage
                    NSApp.applicationIconImage = targetImage
                    dockIconTransitionTask = nil
                    return
                }

                let frame = blendedIcon(
                    from: startImage,
                    to: targetImage,
                    progress: transitionProgress(step: step, totalSteps: totalSteps)
                )
                renderedDockIcon = frame
                NSApp.applicationIconImage = frame
            }

            guard !Task.isCancelled else { return }
            renderedDockIcon = targetImage
            NSApp.applicationIconImage = targetImage
            dockIconTransitionTask = nil
        }
    }

    static func transitionProgress(step: Int, totalSteps: Int) -> CGFloat {
        guard totalSteps > 0 else { return 1 }
        let linear = min(max(CGFloat(step) / CGFloat(totalSteps), 0), 1)
        return linear * linear * (3 - 2 * linear)
    }

    static func blendedIcon(
        from startImage: NSImage,
        to targetImage: NSImage,
        progress: CGFloat
    ) -> NSImage {
        let fraction = min(max(progress, 0), 1)
        guard fraction > 0 else { return startImage }
        guard fraction < 1 else { return targetImage }

        let image = NSImage(size: targetImage.size)
        for logicalSize in [16, 32, 64, Int(targetImage.size.width)] {
            var startRect = NSRect(
                x: 0,
                y: 0,
                width: logicalSize,
                height: logicalSize
            )
            var targetRect = startRect
            guard let startCGImage = resolvedCGImage(
                from: startImage,
                logicalSize: logicalSize,
                fallbackRect: &startRect
            ), let targetCGImage = resolvedCGImage(
                from: targetImage,
                logicalSize: logicalSize,
                fallbackRect: &targetRect
            ), let blendedCGImage = blendedCGImage(
                from: startCGImage,
                to: targetCGImage,
                progress: fraction
            ) else { continue }

            let representation = NSBitmapImageRep(cgImage: blendedCGImage)
            representation.size = NSSize(width: logicalSize, height: logicalSize)
            image.addRepresentation(representation)
        }
        return image.representations.isEmpty
            ? (fraction < 0.5 ? startImage : targetImage)
            : image
    }

    private static func resolvedCGImage(
        from image: NSImage,
        logicalSize: Int,
        fallbackRect: inout NSRect
    ) -> CGImage? {
        let pointSize = NSSize(width: logicalSize, height: logicalSize)
        let pixelSize = logicalSize * 2
        if let representation = image.representations.first(where: {
            $0.size == pointSize
                && $0.pixelsWide == pixelSize
                && $0.pixelsHigh == pixelSize
        }) as? NSBitmapImageRep,
           let cgImage = representation.cgImage {
            return cgImage
        }
        return image.cgImage(
            forProposedRect: &fallbackRect,
            context: nil,
            hints: nil
        )
    }

    private static func blendedCGImage(
        from startImage: CGImage,
        to targetImage: CGImage,
        progress: CGFloat
    ) -> CGImage? {
        guard let filter = CIFilter(name: "CIDissolveTransition") else { return nil }
        let startCIImage = CIImage(cgImage: startImage)
        let targetCIImage = CIImage(cgImage: targetImage)
        filter.setValue(startCIImage, forKey: kCIInputImageKey)
        filter.setValue(targetCIImage, forKey: kCIInputTargetImageKey)
        filter.setValue(progress, forKey: kCIInputTimeKey)
        guard let outputImage = filter.outputImage else { return nil }
        return dockIconBlendContext.createCGImage(
            outputImage,
            from: targetCIImage.extent
        )
    }

    private static func assetSuffix(for colorScheme: ColorScheme) -> String {
        colorScheme == .dark ? "Dark" : "Light"
    }

    private static func decodedImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDecodedIconPixels
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(
            cgImage: image,
            size: NSSize(width: image.width, height: image.height)
        )
    }
}

/// Explicit allow-list for generated brand artwork. Functional controls stay
/// on SF Symbols so imagery never replaces navigation or status semantics.
enum AppArtworkAsset {
    case appMain
    case smartCareHero

    func image(for colorScheme: ColorScheme) -> NSImage? {
        switch self {
        case .appMain:
            AppArtwork.iconImage(for: colorScheme)
        case .smartCareHero:
            AppArtwork.image(named: "AppIconSmartCareHero")
        }
    }

    var fallbackSystemImage: String {
        switch self {
        case .appMain:
            "arrow.triangle.2.circlepath"
        case .smartCareHero:
            "externaldrive.fill.badge.checkmark"
        }
    }
}

struct AppIconView: View {
    @Environment(\.colorScheme) private var colorScheme

    let asset: AppArtworkAsset
    let size: CGFloat
    var cornerRadius: CGFloat = 8
    var showsShadow = true
    var isDecorative = true

    var body: some View {
        Group {
            if let image = asset.image(for: colorScheme) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                fallbackIcon
            }
        }
        .frame(width: size, height: size)
        .shadow(
            color: AppDesignTokens.Elevation.contentShadow(
                elevated: showsShadow,
                colorScheme: colorScheme,
                opacityInDark: 0.16,
                opacityInLight: 0.16
            ),
            radius: size * 0.08,
            y: size * 0.04
        )
        .accessibilityHidden(isDecorative)
        .accessibilityLabel(isDecorative ? "" : L10n.appName)
    }

    private var fallbackIcon: some View {
        Image(systemName: asset.fallbackSystemImage)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(AppDesignTokens.Palette.accent)
            .frame(width: size, height: size)
            .background(AppDesignTokens.Palette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension ReviewFilter {
    var accentColor: Color {
        // Page identity follows the user's system accent. Semantic status and
        // chart colors remain local to the data they communicate.
        AppDesignTokens.Palette.accent
    }
}

struct ArtworkIconTile: View {
    let systemImage: String
    var filter: ReviewFilter?
    let tint: Color
    let size: CGFloat
    var glyphSize: CGFloat? = nil
    var cornerRadius: CGFloat? = nil
    var showsGlass = false
    var showsGlow = false

    var body: some View {
        Image(systemName: effectiveSystemImage)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: resolvedGlyphSize, weight: .semibold))
            .foregroundStyle(effectiveTint)
            .frame(width: size, height: size)
            .fixedSize()
            .shadow(
                color: effectiveTint.opacity(showsGlow ? 0.16 : 0),
                radius: showsGlow ? size * 0.22 : 0,
                y: showsGlow ? size * 0.09 : 0
            )
            .accessibilityHidden(true)
    }

    private var resolvedGlyphSize: CGFloat {
        min(glyphSize ?? size * 0.48, size * 0.50)
    }

    private var effectiveSystemImage: String {
        filter?.systemImage ?? systemImage
    }

    private var effectiveTint: Color {
        filter == nil ? tint : AppDesignTokens.Palette.steadyChrome
    }
}
