import AppKit
import ImageIO
import SwiftUI

/// Module marks, state pictures and (D166) result-card objects. D166 remade
/// the D58 set and added marks for the D154 modules, a celebration state and
/// `tile-*` objects as Blender models rendered in style A "glossy ceramic"
/// (models and renders stay outside the repository, see `Resources/Art`).
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
    // D166: own marks for the D154 modules and tool pages that borrowed
    // another module's picture.
    case performance = "module-performance"
    case applications = "module-apps"
    case clutter = "module-clutter"
    case cloudCleanup = "module-cloudcleanup"
    case myTools = "module-mytools"
    case myActivity = "module-myactivity"
    case extensions = "module-extensions"
    case maintenance = "module-maintenance"
    case chatFiles = "module-chatfiles"
    case stateSuccess = "state-success"
    case stateAllClear = "state-allclear"
    case stateEmpty = "state-empty"
    case statePermission = "state-permission"
    case stateError = "state-error"
    case stateCelebration = "state-celebration"
    // D166②: the first-run screens (welcome and privacy, Full Disk Access).
    case onboardWelcome = "onboard-welcome"
    case onboardDiskAccess = "onboard-diskaccess"
    // D166: one object per result card and manager row, in its module's
    // colour; shipped at the header size only.
    case tileSystemJunk = "tile-systemjunk"
    case tileDevJunk = "tile-devjunk"
    case tileAIClutter = "tile-aiclutter"
    case tileMail = "tile-mail"
    case tileTrash = "tile-trash"
    case tileReview = "tile-review"
    case tileAppUpdates = "tile-appupdates"
    case tileUnused = "tile-unused"
    case tileLeftovers = "tile-leftovers"
    case tileInstallers = "tile-installers"
    case tileLegacyApps = "tile-legacyapps"
    case tileSystemUpdate = "tile-systemupdate"
    case tilePickApps = "tile-pickapps"
    case tileAppStore = "tile-appstore"
    case tileOtherSources = "tile-othersources"
    case tileVendors = "tile-vendors"
    case tileCompare = "tile-compare"
    case tileMaintenance = "tile-maintenance"
    case tileLoginItems = "tile-loginitems"
    case tileBackground = "tile-background"
    case tileSync = "tile-sync"
    case tileAttention = "tile-attention"
    case tilePressure = "tile-pressure"
    case tileTopApps = "tile-topapps"
    case tileFreeable = "tile-freeable"
    case tileProcesses = "tile-processes"
    case tileHistory = "tile-history"
    case tileSensitive = "tile-sensitive"
    case tileCookies = "tile-cookies"
    case tileBrowsers = "tile-browsers"
    case tileDownloaded = "tile-downloaded"
    case tileLargeCloud = "tile-largecloud"
    case tileCloudOnly = "tile-cloudonly"
    case tileOtherClouds = "tile-otherclouds"
    case tileCleaned = "tile-cleaned"
    case tileMonth = "tile-month"
    case tileCount = "tile-count"
    case tileRestore = "tile-restore"
    // D166②: the completion bell and the Settings tabs (General, Mini
    // Window, Scan & Safety, System Control), drawn in their final colours.
    case tileNotifications = "tile-notifications"
    case tileGeneral = "tile-general"
    case tileMiniWindow = "tile-miniwindow"
    case tileScanSafety = "tile-scansafety"
    case tileSystemControl = "tile-systemcontrol"
    // D166③: the maintenance and extension tool sidebars (purgeable space,
    // permissions; Quick Look, screen savers, audio, app extensions).
    case tilePurgeable = "tile-purgeable"
    case tilePermissions = "tile-permissions"
    case tileQuickLook = "tile-quicklook"
    case tileScreenSaver = "tile-screensaver"
    case tileAudio = "tile-audio"
    case tileAppExtension = "tile-appextension"
    // D166④: hero pictures for the protection and space map modules (a
    // shield with a raised hand; a cluster of bubbles); the classic privacy
    // and file analysis pages keep `privacy` and `fileAnalysis`.
    case protection = "module-protection"
    case spaceMap = "module-spacemap"

    /// The exported pixel sizes, chosen for their display sizes.
    enum Variant: Int, CaseIterable, Sendable {
        /// Page header marks, 52–72 pt.
        case header = 192
        /// Landing centers and state pictures, up to 256 pt.
        case landing = 512
    }

    /// A result-card or manager-row object (D166) rather than a module mark
    /// or state picture.
    var isTile: Bool { rawValue.hasPrefix("tile-") }

    /// The sizes shipped: tiles are drawn at 96 pt or less, so only `header`.
    var variants: [Variant] { isTile ? [.header] : Variant.allCases }

    static let resourceDirectory = "Art"
    static let similarPhotosSystemImage = "photo.on.rectangle.angled"
    /// The Performance page header (`PerformanceBenchmarkWorkspaceView`)
    /// shows its dashboard's speedometer, not the sidebar's gauge.
    static let performanceDashboardSystemImage = "speedometer"

    /// A tile asked for its landing size gets its header picture.
    func resourceName(_ variant: Variant) -> String {
        "\(rawValue)-\((variants.contains(variant) ? variant : .header).rawValue)"
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
        // D166: the D154 module and tool pages have their own pictures.
        case .cloudCleanup: .cloudCleanup
        case .myTools: .myTools
        case .myActivity: .myActivity
        case .extensions: .extensions
        case .maintenance: .maintenance
        case .chatFiles: .chatFiles
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

    /// Every header mark, for loading ahead of the first page change; tiles
    /// load when a card or row shows them.
    static var headerResourceNames: [String] {
        allCases.filter { !$0.isTile }.map { $0.resourceName(.header) }
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
