import AppKit
import ImageIO
import SwiftUI

/// D58 illustration set A ("glossy glass 3D"): module marks and state
/// pictures generated with Codex image generation from the main session's
/// prompts (masters stay outside the repository, see `Resources/Art`).
///
/// Shipped as HEIC with alpha in `Contents/Resources/Art`: `-192` for page
/// header marks (64–96 pt @2x) and `-512` for landing centers (up to 256 pt
/// @2x). Every picture is decorative. A missing or unreadable file yields
/// `nil`, and callers keep their code-drawn mark (`IconTile`, `GlossyOrb`).
enum GeneratedArt: String, CaseIterable, Sendable {
    case smartScan = "module-smartscan"
    case cleanup = "module-cleanup"
    case devCaches = "module-devcaches"
    case health = "module-health"
    case privacy = "module-privacy"
    case benchmark = "module-benchmark"
    case startup = "module-startup"
    case memory = "module-memory"
    case energy = "module-energy"
    case uninstall = "module-uninstall"
    case updater = "module-updater"
    case fileAnalysis = "module-fileanalysis"
    case migration = "module-migration"
    case duplicates = "module-duplicates"
    case similarPhotos = "module-similarphotos"
    case stateSuccess = "state-success"
    case stateAllClear = "state-allclear"
    case stateEmpty = "state-empty"
    case statePermission = "state-permission"
    case stateError = "state-error"

    /// The exported pixel sizes, chosen for their display sizes.
    enum Variant: Int, CaseIterable, Sendable {
        /// Page header marks, 52–72 pt.
        case header = 192
        /// Landing centers and state pictures, up to 256 pt.
        case landing = 512
    }

    static let resourceDirectory = "Art"
    static let similarPhotosSystemImage = "photo.on.rectangle.angled"
    /// The Performance page header (`PerformanceBenchmarkWorkspaceView`)
    /// shows its dashboard's speedometer, not the sidebar's gauge.
    static let performanceDashboardSystemImage = "speedometer"

    func resourceName(_ variant: Variant) -> String {
        "\(rawValue)-\(variant.rawValue)"
    }

    /// The module mark of a sidebar destination.
    static func module(for filter: ReviewFilter) -> GeneratedArt? {
        switch filter {
        case .overview: .smartScan
        case .green: .cleanup
        case .devCaches: .devCaches
        case .healthHub: .health
        case .privacy: .privacy
        case .performance: .benchmark
        case .startup: .startup
        case .memory: .memory
        case .energy: .energy
        case .uninstall: .uninstall
        case .updater: .updater
        case .largeFiles: .fileAnalysis
        case .migration: .migration
        case .duplicates: .duplicates
        case .utilityHub: nil
        }
    }

    /// Headers know their page by its symbol; Similar Photos is a mode of
    /// Duplicates with its own symbol, and Performance uses its dashboard's.
    /// Status headers (an update installing or finished) keep their status
    /// symbol and return `nil`.
    static func module(forSystemImage systemImage: String) -> GeneratedArt? {
        switch systemImage {
        case similarPhotosSystemImage: return .similarPhotos
        case performanceDashboardSystemImage: return .benchmark
        default:
            return ReviewFilter.allCases
                .first { $0.systemImage == systemImage }
                .flatMap(module(for:))
        }
    }

    /// The decoded picture if it is already loaded; never reads the disk,
    /// so views may ask from `body`.
    func cachedImage(_ variant: Variant, in library: GeneratedArtLibrary = .shared) -> CGImage? {
        library.cachedImage(named: resourceName(variant))
    }

    /// Every header mark, for loading ahead of the first page change.
    static var headerResourceNames: [String] {
        allCases.map { $0.resourceName(.header) }
    }
}

/// Where a picture's file is (review P2-6): the app reads
/// `Contents/Resources/Art` of its bundle; tests and previews point at a
/// directory, such as the repository's `Resources/Art`.
struct GeneratedArtResolver: Sendable {
    let url: @Sendable (String) -> URL?

    static func bundle(_ bundleURL: URL = Bundle.main.bundleURL) -> GeneratedArtResolver {
        GeneratedArtResolver { name in
            Bundle(url: bundleURL)?.url(forResource: name, withExtension: "heic",
                                        subdirectory: GeneratedArt.resourceDirectory)
        }
    }

    static func directory(_ directory: URL) -> GeneratedArtResolver {
        GeneratedArtResolver { name in
            let url = directory.appendingPathComponent(name).appendingPathExtension("heic")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
    }
}

/// A decoded picture handed between the loader and the views.
struct GeneratedArtImage: @unchecked Sendable {
    let image: CGImage
}

/// Reads and decodes each picture once, off the main thread, at its exported
/// size, and keeps it (review P2-4). Views draw their code-drawn fallback
/// until the picture arrives, then the cache serves it at once. The lock
/// guards only the cache state, never the file read or the decode.
final class GeneratedArtLibrary: @unchecked Sendable {
    static let shared = GeneratedArtLibrary(resolver: .bundle())

    private let resolver: GeneratedArtResolver
    private let lock = NSLock()
    private var images: [String: GeneratedArtImage] = [:]
    private var missing: Set<String> = []
    private struct Load {
        let id: UUID
        let task: Task<DecodeResult, Never>
        var waiters: Set<UUID>
    }
    private enum DecodeResult: Sendable {
        case resolved(GeneratedArtImage?)
        case cancelled
    }
    typealias Decoder = @Sendable (URL) async -> GeneratedArtImage?
    private let decoder: Decoder
    private var loads: [String: Load] = [:]

    init(resolver: GeneratedArtResolver,
         decoder: @escaping Decoder = { GeneratedArtLibrary.decode($0).map(GeneratedArtImage.init(image:)) }) {
        self.resolver = resolver
        self.decoder = decoder
    }

    /// `directory` nil reads `Contents/Resources/Art` of the app bundle.
    convenience init(directory: URL?) {
        self.init(resolver: directory.map(GeneratedArtResolver.directory) ?? .bundle())
    }

    func cachedImage(named name: String) -> CGImage? {
        lock.withLock { images[name]?.image }
    }

    func activeWaiterCount(named name: String) -> Int {
        lock.withLock { loads[name]?.waiters.count ?? 0 }
    }

    func isKnownMissing(named name: String) -> Bool {
        lock.withLock { missing.contains(name) }
    }

    /// The picture, read and decoded on a background task the first time.
    /// Concurrent requests for one picture share that work.
    func image(named name: String) async -> CGImage? {
        while !Task.isCancelled {
            let waiter = UUID()
            let pending: Load? = lock.withLock {
                if images[name] != nil || missing.contains(name) { return nil }
                if var running = loads[name] {
                    running.waiters.insert(waiter)
                    loads[name] = running
                    return running
                }
                let resolver = resolver, decoder = decoder
                let task = Task.detached(priority: .utility) { () -> DecodeResult in
                    guard !Task.isCancelled else { return .cancelled }
                    guard let url = resolver.url(name) else { return .resolved(nil) }
                    guard !Task.isCancelled else { return .cancelled }
                    let decoded = await decoder(url)
                    return Task.isCancelled ? .cancelled : .resolved(decoded)
                }
                let load = Load(id: UUID(), task: task, waiters: [waiter])
                loads[name] = load
                return load
            }
            guard let pending else { return cachedImage(named: name) }
            let result = await withTaskCancellationHandler {
                await pending.task.value
            } onCancel: { [self] in
                cancelWaiter(waiter, name: name, loadID: pending.id)
            }
            lock.withLock {
                guard loads[name]?.id == pending.id else { return }
                if case let .resolved(loaded) = result, !pending.task.isCancelled {
                    if let loaded { images[name] = loaded } else { missing.insert(name) }
                }
                loads[name] = nil // Physical decode has finished; a new flight is now safe.
            }
            guard !Task.isCancelled else { return nil }
            if case .resolved = result, !pending.task.isCancelled { return cachedImage(named: name) }
            // A cancelled preload can have a newly visible waiter. Retry after
            // that physical decode exits, without caching cancellation as missing.
        }
        return nil
    }

    private func cancelWaiter(_ waiter: UUID, name: String, loadID: UUID) {
        lock.withLock {
            guard var load = loads[name], load.id == loadID else { return }
            load.waiters.remove(waiter)
            if load.waiters.isEmpty { load.task.cancel() }
            loads[name] = load
        }
    }

    /// At most one speculative decode; caller owns visibility and cancellation.
    func preload(_ names: [String], whileVisible visible: Bool) async {
        guard visible else { return }
        for name in names {
            guard !Task.isCancelled else { return }
            _ = await image(named: name)
        }
    }

    private static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options)
    }
}

private struct GeneratedArtLibraryKey: EnvironmentKey {
    static let defaultValue = GeneratedArtLibrary.shared
}

extension EnvironmentValues {
    /// The picture library views load from; tests inject one that reads the
    /// repository's `Resources/Art`.
    var generatedArtLibrary: GeneratedArtLibrary {
        get { self[GeneratedArtLibraryKey.self] }
        set { self[GeneratedArtLibraryKey.self] = newValue }
    }
}
