import AppKit
import ImageIO

final class AppIconCache: Sendable {
    private static let cachedPointDimension = 80
    private static let cachedPixelDimension = 160
    private static let cachedBitmapCost = cachedPixelDimension * cachedPixelDimension * 4

    static let shared = AppIconCache(capacity: 192) { path in
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return AppIconCache.loadBundleIcon(atPath: path)
    }

    // NSImage is handed across the worker boundary as an immutable display value.
    struct LoadedImage: @unchecked Sendable {
        let image: NSImage?
    }

    private actor State {
        private static let loadingQueue = DispatchQueue(
            label: "com.local.StorageCleanerMac.app-icon-loader",
            qos: .utility
        )

        private final class Entry {
            let image: NSImage?

            init(image: NSImage?) {
                self.image = image
            }
        }

        private let cache: NSCache<NSString, Entry>
        private let loader: @Sendable (String) -> NSImage?
        private var inFlight: [String: Task<LoadedImage, Never>] = [:]

        init(capacity: Int, loader: @escaping @Sendable (String) -> NSImage?) {
            let cache = NSCache<NSString, Entry>()
            cache.countLimit = capacity
            cache.totalCostLimit = capacity * AppIconCache.cachedBitmapCost
            self.cache = cache
            self.loader = loader
        }

        func image(for path: String) async -> LoadedImage {
            let key = path as NSString
            if let cached = cache.object(forKey: key) {
                return LoadedImage(image: cached.image)
            }

            if let task = inFlight[path] {
                return await task.value
            }

            let loader = self.loader
            let task = Task.detached(priority: .utility) {
                await Self.load(path: path, using: loader)
            }
            inFlight[path] = task

            let loadedImage = await task.value
            cache.setObject(
                Entry(image: loadedImage.image),
                forKey: key,
                cost: AppIconCache.memoryCost(of: loadedImage.image)
            )
            inFlight[path] = nil
            return loadedImage
        }

        private static func load(
            path: String,
            using loader: @escaping @Sendable (String) -> NSImage?
        ) async -> LoadedImage {
            await withCheckedContinuation { continuation in
                loadingQueue.async {
                    let image = autoreleasepool {
                        AppIconCache.preparedForCaching(loader(path))
                    }
                    continuation.resume(returning: LoadedImage(image: image))
                }
            }
        }
    }

    let capacity: Int
    private let state: State

    init(
        capacity: Int,
        loader: @escaping @Sendable (String) -> NSImage?
    ) {
        let capacity = max(1, capacity)
        self.capacity = capacity
        state = State(capacity: capacity, loader: loader)
    }

    func loadedIcon(for path: String) async -> LoadedImage {
        guard !path.isEmpty else { return LoadedImage(image: nil) }

        await Task.yield()
        guard !Task.isCancelled else { return LoadedImage(image: nil) }

        let standardizedPath = (path as NSString).standardizingPath
        return await state.image(for: standardizedPath)
    }

    static func loadBundleIcon(atPath path: String) -> NSImage? {
        guard let bundle = resolvedBundle(atPath: path) else { return nil }

        if let iconURL = bundleIconURL(in: bundle),
           let image = thumbnailImage(at: iconURL) {
            return image
        }

        if let iconName = bundle.object(forInfoDictionaryKey: "CFBundleIconName") as? String,
           !iconName.isEmpty,
           let image = bundle.image(forResource: NSImage.Name(iconName)) {
            return preparedForCaching(image)
        }

        if let iconURL = wrappedBundleIconURL(in: bundle),
           let image = thumbnailImage(at: iconURL) {
            return image
        }

        return nil
    }

    private static func resolvedBundle(atPath path: String) -> Bundle? {
        if let bundle = Bundle(path: path) {
            return bundle
        }

        let outerURL = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let wrapperURL = outerURL.appendingPathComponent("Wrapper", isDirectory: true)
        let wrappedBundleURL = outerURL.appendingPathComponent("WrappedBundle")
        guard let wrapperValues = try? wrapperURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        wrapperValues.isDirectory == true,
        wrapperValues.isSymbolicLink != true,
        (try? FileManager.default.destinationOfSymbolicLink(
            atPath: wrappedBundleURL.path
        )) != nil else {
            return nil
        }

        let resolvedWrapperURL = wrapperURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedBundleURL = wrappedBundleURL.resolvingSymlinksInPath().standardizedFileURL
        let wrapperPrefix = resolvedWrapperURL.path + "/"
        guard resolvedBundleURL.path.hasPrefix(wrapperPrefix),
              resolvedBundleURL.pathExtension.lowercased() == "app" else {
            return nil
        }
        return Bundle(url: resolvedBundleURL)
    }

    private static func bundleIconURL(in bundle: Bundle) -> URL? {
        guard let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
              !iconFile.isEmpty else {
            return nil
        }

        let name = iconFile as NSString
        let fileExtension = name.pathExtension.isEmpty ? "icns" : name.pathExtension
        let resourceName = name.deletingPathExtension
        return bundle.url(forResource: resourceName, withExtension: fileExtension)
    }

    private static func wrappedBundleIconURL(in bundle: Bundle) -> URL? {
        var iconNames = mobileIconFileNames(
            from: bundle.object(forInfoDictionaryKey: "CFBundleIcons")
        )
        iconNames.append(contentsOf: mobileIconFileNames(
            from: bundle.object(forInfoDictionaryKey: "CFBundleIcons~ipad")
        ))
        if let legacyNames = bundle.object(forInfoDictionaryKey: "CFBundleIconFiles") as? [String] {
            iconNames.append(contentsOf: legacyNames)
        }
        let uniqueNames = Set(
            iconNames.compactMap { rawName -> String? in
                let lastComponent = (rawName as NSString).lastPathComponent
                let normalizedName = (lastComponent as NSString).deletingPathExtension
                return normalizedName.isEmpty ? nil : normalizedName
            }
        )
        guard !uniqueNames.isEmpty,
              let resourceURL = bundle.resourceURL,
              let resources = try? FileManager.default.contentsOfDirectory(
                  at: resourceURL,
                  includingPropertiesForKeys: nil,
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        let candidates = resources.filter { url in
            guard url.pathExtension.lowercased() == "png" else { return false }
            let filename = url.deletingPathExtension().lastPathComponent
            return uniqueNames.contains { name in
                filename == name
                    || filename.hasPrefix(name + "@")
                    || filename.hasPrefix(name + "~")
            }
        }
        return candidates.max { imagePixelArea(at: $0) < imagePixelArea(at: $1) }
    }

    private static func mobileIconFileNames(from value: Any?) -> [String] {
        guard let icons = value as? [String: Any],
              let primaryIcon = icons["CFBundlePrimaryIcon"] as? [String: Any],
              let files = primaryIcon["CFBundleIconFiles"] as? [String] else {
            return []
        }
        return files
    }

    private static func imagePixelArea(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  nil
              ) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return 0
        }
        return width * height
    }

    private static func thumbnailImage(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: cachedPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return nil
        }
        return NSImage(
            cgImage: thumbnail,
            size: NSSize(
                width: cachedPointDimension,
                height: cachedPointDimension
            )
        )
    }

    private static func preparedForCaching(_ source: NSImage?) -> NSImage? {
        guard let source else { return nil }

        let representations = source.representations
        let alreadyBounded = representations.count == 1
            && representations.allSatisfy {
                $0.pixelsWide <= cachedPixelDimension
                    && $0.pixelsHigh <= cachedPixelDimension
            }
        guard !representations.isEmpty, !alreadyBounded else { return source }

        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: cachedPixelDimension,
            pixelsHigh: cachedPixelDimension,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return source
        }

        let targetSize = NSSize(
            width: cachedPointDimension,
            height: cachedPointDimension
        )
        bitmap.size = targetSize

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            return source
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        context.cgContext.clear(CGRect(origin: .zero, size: targetSize))
        source.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: .zero,
            operation: .copy,
            fraction: 1
        )
        context.flushGraphics()

        let prepared = NSImage(size: targetSize)
        prepared.addRepresentation(bitmap)
        prepared.isTemplate = source.isTemplate
        return prepared
    }

    private static func memoryCost(of image: NSImage?) -> Int {
        guard let image else { return 1 }
        let cost = image.representations.reduce(into: 0) { total, representation in
            total += max(1, representation.pixelsWide)
                * max(1, representation.pixelsHigh)
                * 4
        }
        return max(1, cost)
    }
}
