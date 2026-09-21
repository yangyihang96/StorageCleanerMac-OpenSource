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
        private struct Request {
            var subscribers: [UUID: CheckedContinuation<LoadedImage, Never>]
            var invalidated = false
        }
        private var requests: [String: Request] = [:]
        private var pending: [String] = []
        private var activePath: String?
        private var cacheGeneration = 0
        private let maximumPending: Int

        init(capacity: Int, maximumPending: Int, loader: @escaping @Sendable (String) -> NSImage?) {
            let cache = NSCache<NSString, Entry>()
            cache.countLimit = capacity
            cache.totalCostLimit = capacity * AppIconCache.cachedBitmapCost
            self.cache = cache
            self.loader = loader
            self.maximumPending = maximumPending
        }

        func image(for path: String) async -> LoadedImage {
            let subscriber = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard !Task.isCancelled else { continuation.resume(returning: LoadedImage(image: nil)); return }
                    if let cached = cache.object(forKey: path as NSString) {
                        continuation.resume(returning: LoadedImage(image: cached.image))
                        return
                    }
                    if var request = requests[path] {
                        guard request.subscribers.count < 256 else {
                            continuation.resume(returning: LoadedImage(image: nil)); return
                        }
                        request.subscribers[subscriber] = continuation
                        requests[path] = request
                        return
                    }
                    // A recent visible request takes the place of the oldest
                    // queued request. No synchronous decoder is interrupted.
                    if pending.count >= maximumPending, let oldest = pending.first {
                        pending.removeFirst()
                        complete(oldest, with: LoadedImage(image: nil))
                    }
                    requests[path] = Request(subscribers: [subscriber: continuation])
                    pending.append(path)
                    pump()
                }
            } onCancel: {
                Task { await self.cancel(path: path, subscriber: subscriber) }
            }
        }

        private func cancel(path: String, subscriber: UUID) {
            guard var request = requests[path], let waiter = request.subscribers.removeValue(forKey: subscriber) else { return }
            waiter.resume(returning: LoadedImage(image: nil))
            requests[path] = request
            if request.subscribers.isEmpty, activePath != path {
                requests[path] = nil
                pending.removeAll { $0 == path }
            }
        }

        private func pump() {
            guard activePath == nil, !pending.isEmpty else { return }
            let path = pending.removeFirst()
            activePath = path
            let loader = self.loader
            let generation = cacheGeneration
            Task {
                let loaded = await Self.load(path: path, using: loader)
                finish(path, loaded: loaded, generation: generation)
            }
        }

        private func finish(_ path: String, loaded: LoadedImage, generation: Int) {
            activePath = nil
            if var request = requests[path], request.invalidated, !request.subscribers.isEmpty {
                request.invalidated = false
                requests[path] = request
                pending.insert(path, at: 0)
            } else {
                if requests[path]?.subscribers.isEmpty == false, generation == cacheGeneration {
                    cache.setObject(Entry(image: loaded.image), forKey: path as NSString,
                                    cost: AppIconCache.memoryCost(of: loaded.image))
                }
                complete(path, with: loaded)
            }
            pump()
        }

        private func complete(_ path: String, with value: LoadedImage) {
            let request = requests.removeValue(forKey: path)
            request?.subscribers.values.forEach { $0.resume(returning: value) }
        }

        func purge() {
            cacheGeneration &+= 1
            cache.removeAllObjects()
            let queued = pending
            pending.removeAll()
            for path in queued { complete(path, with: LoadedImage(image: nil)) }
        }

        func invalidate(_ path: String) {
            cache.removeObject(forKey: path as NSString)
            if activePath == path { requests[path]?.invalidated = true }
        }

        var queueCounts: (active: Int, pending: Int) { (activePath == nil ? 0 : 1, pending.count) }

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
        maximumPending: Int = 64,
        loader: @escaping @Sendable (String) -> NSImage?
    ) {
        let capacity = max(1, capacity)
        self.capacity = capacity
        state = State(capacity: capacity, maximumPending: max(1, maximumPending), loader: loader)
    }

    func loadedIcon(for path: String) async -> LoadedImage {
        guard !path.isEmpty else { return LoadedImage(image: nil) }

        await Task.yield()
        guard !Task.isCancelled else { return LoadedImage(image: nil) }

        let standardizedPath = (path as NSString).standardizingPath
        return await state.image(for: standardizedPath)
    }

    func purge() async { await state.purge() }
    func invalidate(path: String) async {
        await state.invalidate((path as NSString).standardizingPath)
    }
    func queueCounts() async -> (active: Int, pending: Int) { await state.queueCounts }

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
