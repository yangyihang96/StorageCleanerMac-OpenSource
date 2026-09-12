import AppKit
import XCTest
@testable import StorageCleanerMac

final class AppIconCacheTests: XCTestCase {
    @MainActor
    func testIconLoaderRunsAwayFromTheMainThread() async {
        let probe = AppIconLoadProbe()
        let cache = AppIconCache(capacity: 32) { _ in
            probe.recordLoad(onMainThread: Thread.isMainThread)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        _ = await cache.loadedIcon(for: "/Applications/Test.app")

        XCTAssertEqual(probe.loadCount, 1)
        XCTAssertFalse(probe.loadedOnMainThread)
    }

    @MainActor
    func testConcurrentRequestsForTheSamePathShareOneLoad() async {
        let probe = AppIconLoadProbe()
        let cache = AppIconCache(capacity: 32) { _ in
            probe.recordLoad(onMainThread: Thread.isMainThread)
            Thread.sleep(forTimeInterval: 0.05)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        async let first = cache.loadedIcon(for: "/Applications/Test.app")
        async let second = cache.loadedIcon(for: "/Applications/Test.app")
        _ = await (first, second)

        XCTAssertEqual(probe.loadCount, 1)
    }

    @MainActor
    func testIconCacheLoadsEachPathOnce() async {
        let probe = AppIconLoadProbe()
        let cache = AppIconCache(capacity: 32) { _ in
            probe.recordLoad(onMainThread: Thread.isMainThread)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        _ = await cache.loadedIcon(for: "/Applications/Test.app")
        _ = await cache.loadedIcon(for: "/Applications/Test.app")

        XCTAssertEqual(probe.loadCount, 1)
    }

    @MainActor
    func testIconCacheUsesStandardizedPathAsItsKey() async {
        let probe = AppIconLoadProbe()
        let cache = AppIconCache(capacity: 32) { _ in
            probe.recordLoad(onMainThread: Thread.isMainThread)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        _ = await cache.loadedIcon(for: "/Applications/Test.app")
        _ = await cache.loadedIcon(for: "/Applications/../Applications/Test.app")

        XCTAssertEqual(probe.loadCount, 1)
    }

    @MainActor
    func testIconCacheLoadsDifferentPathsIndependently() async {
        let probe = AppIconLoadProbe()
        let cache = AppIconCache(capacity: 32) { _ in
            probe.recordLoad(onMainThread: Thread.isMainThread)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        _ = await cache.loadedIcon(for: "/Applications/First.app")
        _ = await cache.loadedIcon(for: "/Applications/Second.app")
        _ = await cache.loadedIcon(for: "/Applications/First.app")
        _ = await cache.loadedIcon(for: "/Applications/Second.app")

        XCTAssertEqual(probe.loadCount, 2)
    }

    @MainActor
    func testIconCacheBoundsMissingPathResultsWithTheImageCache() async {
        let probe = AppIconLoadProbe()
        let cache = AppIconCache(capacity: 32) { _ in
            probe.recordLoad(onMainThread: Thread.isMainThread)
            return nil
        }

        _ = await cache.loadedIcon(for: "/Applications/Missing.app")
        _ = await cache.loadedIcon(for: "/Applications/Missing.app")

        XCTAssertEqual(probe.loadCount, 1)
    }

    @MainActor
    func testIconCacheDoesNotLoadAnEmptyPath() async {
        let probe = AppIconLoadProbe()
        let cache = AppIconCache(capacity: 32) { _ in
            probe.recordLoad(onMainThread: Thread.isMainThread)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        let image = (await cache.loadedIcon(for: "")).image

        XCTAssertNil(image)
        XCTAssertEqual(probe.loadCount, 0)
    }

    @MainActor
    func testIconCacheCapacityIsConfigurableAndInstancesDoNotShareState() async {
        let firstProbe = AppIconLoadProbe()
        let secondProbe = AppIconLoadProbe()
        let firstCache = AppIconCache(capacity: 0) { _ in
            firstProbe.recordLoad(onMainThread: Thread.isMainThread)
            return NSImage(size: NSSize(width: 16, height: 16))
        }
        let secondCache = AppIconCache(capacity: 32) { _ in
            secondProbe.recordLoad(onMainThread: Thread.isMainThread)
            return NSImage(size: NSSize(width: 16, height: 16))
        }

        _ = await firstCache.loadedIcon(for: "/Applications/Test.app")
        _ = await secondCache.loadedIcon(for: "/Applications/Test.app")

        XCTAssertEqual(firstCache.capacity, 1)
        XCTAssertEqual(secondCache.capacity, 32)
        XCTAssertEqual(firstProbe.loadCount, 1)
        XCTAssertEqual(secondProbe.loadCount, 1)
    }

    @MainActor
    func testIconCacheDownsamplesLargeMultiRepresentationImagesBeforeRetainingThem() async throws {
        let source = NSImage(size: NSSize(width: 512, height: 512))
        source.addRepresentation(try bitmapRepresentation(pixels: 512))
        source.addRepresentation(try bitmapRepresentation(pixels: 1_024))
        let sourceValue = AppIconCache.LoadedImage(image: source)
        let cache = AppIconCache(capacity: 32) { _ in sourceValue.image }

        let loaded = (await cache.loadedIcon(for: "/Applications/LargeIcon.app")).image
        let cached = try XCTUnwrap(loaded)
        let representation = try XCTUnwrap(cached.representations.first)

        XCTAssertEqual(cached.size, NSSize(width: 80, height: 80))
        XCTAssertEqual(cached.representations.count, 1)
        XCTAssertEqual(representation.pixelsWide, 160)
        XCTAssertEqual(representation.pixelsHigh, 160)
        XCTAssertFalse(cached === source)
    }

    func testBundleIconLoaderCreatesOneBoundedRepresentationWithoutWorkspaceLookup() throws {
        let appURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: resourcesURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: appURL) }

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.local.IconFixture.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "FixtureIcon.icns",
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        let source = try bitmapRepresentation(pixels: 512)
        let pngData = try XCTUnwrap(source.representation(using: .png, properties: [:]))
        try pngData.write(to: resourcesURL.appendingPathComponent("FixtureIcon.icns"))

        let loaded = try XCTUnwrap(AppIconCache.loadBundleIcon(atPath: appURL.path))
        let representation = try XCTUnwrap(loaded.representations.first)

        XCTAssertEqual(loaded.size, NSSize(width: 80, height: 80))
        XCTAssertEqual(loaded.representations.count, 1)
        XCTAssertLessThanOrEqual(representation.pixelsWide, 160)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 160)
    }

    func testBundleIconLoaderResolvesWrappedIOSBundleIconInsideWrapperDirectory() throws {
        let outerAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let wrapperURL = outerAppURL.appendingPathComponent("Wrapper", isDirectory: true)
        let innerAppURL = wrapperURL.appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: innerAppURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outerAppURL) }

        try FileManager.default.createSymbolicLink(
            atPath: outerAppURL.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/Fixture.app"
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.local.WrappedIconFixture.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["AppIcon60x60"],
                    "CFBundleIconName": "AppIcon",
                ],
            ],
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: innerAppURL.appendingPathComponent("Info.plist"))

        let source = try bitmapRepresentation(pixels: 120)
        let pngData = try XCTUnwrap(source.representation(using: .png, properties: [:]))
        try pngData.write(to: innerAppURL.appendingPathComponent("AppIcon60x60@2x.png"))

        let loaded = try XCTUnwrap(AppIconCache.loadBundleIcon(atPath: outerAppURL.path))
        let representation = try XCTUnwrap(loaded.representations.first)

        XCTAssertEqual(loaded.size, NSSize(width: 80, height: 80))
        XCTAssertEqual(loaded.representations.count, 1)
        XCTAssertLessThanOrEqual(representation.pixelsWide, 160)
        XCTAssertLessThanOrEqual(representation.pixelsHigh, 160)
    }

    func testBundleIconLoaderRejectsWrappedBundleOutsideWrapperDirectory() throws {
        let fixtureRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outerAppURL = fixtureRoot.appendingPathComponent("Outer.app", isDirectory: true)
        let wrapperURL = outerAppURL.appendingPathComponent("Wrapper", isDirectory: true)
        let escapedAppURL = fixtureRoot.appendingPathComponent("Escaped.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: wrapperURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: escapedAppURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }

        try FileManager.default.createSymbolicLink(
            atPath: outerAppURL.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "../Escaped.app"
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.local.EscapedIconFixture.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["AppIcon60x60"],
                ],
            ],
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: escapedAppURL.appendingPathComponent("Info.plist"))
        let source = try bitmapRepresentation(pixels: 120)
        let pngData = try XCTUnwrap(source.representation(using: .png, properties: [:]))
        try pngData.write(to: escapedAppURL.appendingPathComponent("AppIcon60x60@2x.png"))

        XCTAssertNil(AppIconCache.loadBundleIcon(atPath: outerAppURL.path))
    }

    func testWrappedBundleIconNamesWithExtensionsChooseLargestCandidate() throws {
        let outerAppURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("app")
        let innerAppURL = outerAppURL
            .appendingPathComponent("Wrapper", isDirectory: true)
            .appendingPathComponent("Fixture.app", isDirectory: true)
        try FileManager.default.createDirectory(
            at: innerAppURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: outerAppURL) }
        try FileManager.default.createSymbolicLink(
            atPath: outerAppURL.appendingPathComponent("WrappedBundle").path,
            withDestinationPath: "Wrapper/Fixture.app"
        )

        let info: [String: Any] = [
            "CFBundleIdentifier": "com.local.ExtensionIconFixture.\(UUID().uuidString)",
            "CFBundlePackageType": "APPL",
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconFiles": ["Icons/AppIcon60x60.png"],
                ],
            ],
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: innerAppURL.appendingPathComponent("Info.plist"))

        let smallIcon = try bitmapRepresentation(pixels: 60, color: .systemRed)
        let largeIcon = try bitmapRepresentation(pixels: 120, color: .systemGreen)
        try XCTUnwrap(smallIcon.representation(using: .png, properties: [:]))
            .write(to: innerAppURL.appendingPathComponent("AppIcon60x60.png"))
        try XCTUnwrap(largeIcon.representation(using: .png, properties: [:]))
            .write(to: innerAppURL.appendingPathComponent("AppIcon60x60@2x.png"))

        let loaded = try XCTUnwrap(AppIconCache.loadBundleIcon(atPath: outerAppURL.path))
        let tiffData = try XCTUnwrap(loaded.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiffData))
        let centerColor = try XCTUnwrap(
            bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)
        ).usingColorSpace(.deviceRGB)

        XCTAssertGreaterThan(try XCTUnwrap(centerColor).greenComponent, 0.8)
        XCTAssertLessThan(try XCTUnwrap(centerColor).redComponent, 0.3)
    }

    func testIconRequestStateRejectsStaleAndCancelledCompletions() {
        var state = CachedAppIconRequestState()

        let requestA = state.begin(path: "/Applications/A.app")
        let requestB = state.begin(path: "/Applications/B.app")

        XCTAssertFalse(
            state.canCommit(
                token: requestA,
                path: "/Applications/A.app",
                isCancelled: false
            )
        )
        XCTAssertTrue(
            state.canCommit(
                token: requestB,
                path: "/Applications/B.app",
                isCancelled: false
            )
        )
        XCTAssertFalse(
            state.canCommit(
                token: requestB,
                path: "/Applications/A.app",
                isCancelled: false
            )
        )
        XCTAssertFalse(
            state.canCommit(
                token: requestB,
                path: "/Applications/B.app",
                isCancelled: true
            )
        )
    }

    func testAuditedIconViewsDeferSharedCacheRequestsToTask() throws {
        let systemUtilitiesSource = try source(
            at: "Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"
        )
        let compactMenuSource = try source(
            at: "Sources/StorageCleanerMac/Views/MenuBarStatusView.swift"
        )
        let advancedMenuSource = try source(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvancedStatusView.swift"
        )
        let advancedMenuComponentsSource = try source(
            at: "Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift"
        )
        let largeFilesSource = try source(
            at: "Sources/StorageCleanerMac/Views/LargeFilesView.swift"
        )
        let combinedSource = systemUtilitiesSource
            + compactMenuSource
            + advancedMenuSource
            + advancedMenuComponentsSource

        XCTAssertEqual(occurrences(of: "AppIconCache.icon(forFile:", in: combinedSource), 0)

        let uninstallPreviewSegment = try structSegment(
            named: "UninstallPreviewAppIcon",
            endingAt: "struct OneClickUpdatePreviewSheet",
            in: systemUtilitiesSource
        )
        let processSegment = try structSegment(
            named: "ProcessIcon",
            endingAt: "private struct InstalledAppRow",
            in: systemUtilitiesSource
        )
        let installedAppSegment = try structSegment(
            named: "InstalledAppIcon",
            endingAt: "private struct LoadingPanel",
            in: systemUtilitiesSource
        )
        let externalAppMigrationSegment = try structSegment(
            named: "ExternalAppMigrationRow",
            endingAt: "private struct ExternalMigrationNotice",
            in: largeFilesSource
        )
        let compactProcessSegment = try structSegment(
            named: "MenuBarProcessIcon",
            in: compactMenuSource
        )
        let advancedAppSegment = try structSegment(
            named: "AdvancedAppIcon",
            in: advancedMenuComponentsSource
        )
        let auditedSegments = [
            uninstallPreviewSegment,
            processSegment,
            installedAppSegment,
            compactProcessSegment,
            advancedAppSegment,
        ]

        for segment in auditedSegments {
            XCTAssertFalse(segment.contains("FileManager.default.fileExists"))
            XCTAssertTrue(segment.contains("CachedAppIconView("))
        }
        XCTAssertTrue(externalAppMigrationSegment.contains("CachedAppIconView(path: item.sourceURL.path, size: 28)"))

        let uninstallPreviewFallback = try fallbackClosure(in: uninstallPreviewSegment)
        let processFallback = try fallbackClosure(in: processSegment)
        let installedAppFallback = try fallbackClosure(in: installedAppSegment)
        let compactProcessFallback = try fallbackClosure(in: compactProcessSegment)
        let advancedAppFallback = try fallbackClosure(in: advancedAppSegment)
        let fallbackClosures = [
            uninstallPreviewFallback,
            processFallback,
            installedAppFallback,
            compactProcessFallback,
            advancedAppFallback,
        ]

        for fallback in fallbackClosures {
            XCTAssertTrue(fallback.contains("Image(systemName:"))
            XCTAssertTrue(fallback.contains(".symbolRenderingMode(.hierarchical)"))
            XCTAssertTrue(fallback.contains(".foregroundStyle(.secondary)"))
        }

        XCTAssertTrue(uninstallPreviewFallback.contains(".resizable()"))
        XCTAssertTrue(uninstallPreviewFallback.contains(".scaledToFit()"))
        XCTAssertTrue(uninstallPreviewFallback.contains(".frame(width: 32, height: 32)"))
        XCTAssertTrue(installedAppFallback.contains(".resizable()"))
        XCTAssertTrue(installedAppFallback.contains(".scaledToFit()"))
        XCTAssertTrue(installedAppFallback.contains(".frame(width: 24, height: 24)"))
        XCTAssertTrue(processFallback.contains(".resizable()"))
        XCTAssertTrue(processFallback.contains(".scaledToFit()"))
        XCTAssertTrue(processFallback.contains(
            ".frame(width: UtilitySizing.supportGlyph, height: UtilitySizing.supportGlyph)"
        ))
        XCTAssertFalse(processFallback.contains(".background(iconFill, in: Circle())"))
        XCTAssertFalse(
            try sourceAfterFallback(in: processSegment)
                .contains(".background(iconFill, in: Circle())")
        )
        XCTAssertTrue(compactProcessFallback.contains(".font(MenuBarTypography.value)"))
        XCTAssertFalse(compactProcessFallback.contains(".background(.thinMaterial"))
        XCTAssertFalse(
            try sourceAfterFallback(in: compactProcessSegment)
                .contains(".background(.thinMaterial")
        )

        let cachedViewSource = try source(
            at: "Sources/StorageCleanerMac/Views/CachedAppIconView.swift"
        )
        let cacheRequest = "AppIconCache.shared.loadedIcon(for: requestedPath)"
        let beforeTask = try XCTUnwrap(cachedViewSource.components(separatedBy: ".task(id: path)").first)
        let taskAndFollowingSource = try XCTUnwrap(
            cachedViewSource.components(separatedBy: ".task(id: path)").last
        )

        XCTAssertEqual(occurrences(of: cacheRequest, in: cachedViewSource), 1)
        XCTAssertEqual(occurrences(of: cacheRequest, in: beforeTask), 0)
        XCTAssertEqual(occurrences(of: cacheRequest, in: taskAndFollowingSource), 1)
        XCTAssertTrue(cachedViewSource.contains("@ViewBuilder fallback: () -> Fallback"))
        XCTAssertFalse(cachedViewSource.contains(".background("))
    }

    private func source(at relativePath: String) throws -> String {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: projectRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }

    private func bitmapRepresentation(
        pixels: Int,
        color: NSColor? = nil
    ) throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        if let color, let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.setFillColor(color.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: pixels, height: pixels))
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap
    }

    private func structSegment(
        named name: String,
        endingAt endMarker: String,
        in source: String
    ) throws -> String {
        let afterStart = try XCTUnwrap(
            source.components(separatedBy: "struct \(name): View").dropFirst().first
        )
        return try XCTUnwrap(afterStart.components(separatedBy: endMarker).first)
    }

    private func structSegment(
        named name: String,
        in source: String
    ) throws -> String {
        try XCTUnwrap(
            source.components(separatedBy: "struct \(name): View").dropFirst().first
        )
    }

    private func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
    }

    private func fallbackClosure(in segment: String) throws -> String {
        let afterCallStart = try XCTUnwrap(
            segment.components(separatedBy: "CachedAppIconView(").dropFirst().first
        )
        return try XCTUnwrap(afterCallStart.components(separatedBy: "\n        }").first)
    }

    private func sourceAfterFallback(in segment: String) throws -> String {
        let afterCallStart = try XCTUnwrap(
            segment.components(separatedBy: "CachedAppIconView(").dropFirst().first
        )
        let components = afterCallStart.components(separatedBy: "\n        }")
        XCTAssertGreaterThan(components.count, 1)
        return components.dropFirst().joined(separator: "\n        }")
    }
}

private final class AppIconLoadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedLoadCount = 0
    private var storedLoadedOnMainThread = false

    var loadCount: Int {
        lock.withLock { storedLoadCount }
    }

    var loadedOnMainThread: Bool {
        lock.withLock { storedLoadedOnMainThread }
    }

    func recordLoad(onMainThread: Bool) {
        lock.withLock {
            storedLoadCount += 1
            storedLoadedOnMainThread = storedLoadedOnMainThread || onMainThread
        }
    }
}
