#if DEBUG
import AppKit
import SwiftUI
import XCTest
@testable import StorageCleanerMac

/// The V0 review (10-07, eight P2 findings): each test guards one fix.
/// Hosted views read the real accessibility tree and layout probes; nothing
/// writes preferences outside the shared volatile scope, and fixtures live in
/// the temporary directory.
@MainActor
final class DesignSystemV2ReviewTests: XCTestCase {
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private var artDirectory: URL {
        projectRoot.appendingPathComponent("Resources/Art", isDirectory: true)
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: P2-1 Memory selection commands

    /// "Select Suggested Apps" and "Select All" stay offered with no, some
    /// and every app selected, as before V0; "Clear Selection" and the quit
    /// action join once something is selected. D67 uses text
    /// controls at both sizes; both read the same to VoiceOver.
    func testMemorySelectionCommandsStayAvailableWhateverIsSelected() async throws {
        let store = try Self.memoryStore(for: self)
        let apps = try XCTUnwrap(store.memorySnapshot?.appsByResidentUsage.filter(\.canQuit))
        XCTAssertGreaterThanOrEqual(apps.count, 3)
        XCTAssertFalse(try XCTUnwrap(store.memorySnapshot).recommendedQuitApps.isEmpty)
        // D67/B3 has a landing dashboard and a separate result view. Host
        // the real production result, not the removed V0 all-in-one page.
        let root = AdaptivePageViewport(resetID: .memory) {
            LightfieldMemoryPage(store: store, snapshot: store.memorySnapshot, displaySnapshot: store.memorySnapshot,
                trendPoints: [], startsWithProcesses: true, showsProcesses: .constant(true))
                .environment(\.featurePresentationIsFixture, true)
                .environment(\.featureDisablesLayoutAnimations, true)
        }.defaultAppStorage(TestPreferenceDomain.make(for: self))
        let host = CalibrationAppKitLayoutHost(root: root, size: CGSize(width: 1_084, height: 712), dark: true)
        defer { host.close() }

        for size in [CGSize(width: 1_084, height: 712), CGSize(width: 756, height: 468)] {
            host.resize(to: size)
            for selectedCount in [0, 1, apps.count] {
                store.clearMemoryProcessSelection()
                for app in apps.prefix(selectedCount) {
                    store.setMemoryAppUsageSelection(app, isSelected: true)
                }
                var commands = [("lightfield.memory.command.suggested", L10n.text("选择建议退出项", "Select Suggested Apps")),
                                ("lightfield.memory.command.selectAll", L10n.text("全选", "Select All"))]
                if selectedCount > 0 {
                    commands += [("lightfield.memory.command.clear", L10n.text("清空选择", "Clear Selection")),
                                 ("lightfield.primary", L10n.text("退出所选应用 · \(selectedCount) 个", "Quit Selected Apps · \(selectedCount)"))]
                }
                let frames = try await host.frames(required: Set(commands.map(\.0) + ["fixture.viewport"]), size: size)
                let viewport = try XCTUnwrap(frames["fixture.viewport"])
                let state = "at \(size) with \(selectedCount) of \(apps.count) selected"
                for (probe, label) in commands {
                    let frame = try XCTUnwrap(frames[probe], "\(label) \(state)")
                    XCTAssertTrue(viewport.insetBy(dx: -1, dy: -1).contains(frame), "\(label) visible \(state): \(frame)")
                    try await host.waitForAccessibility(labels: [label], expectedEnabled: [label: true],
                        pressLabels: [label], hitTestFrames: [frame])
                    let element = host.element(label: label, requiresPress: true)
                    XCTAssertEqual(element?.value(forKey: "accessibilityRole") as? String, NSAccessibility.Role.button.rawValue,
                        "\(label) is a button for VoiceOver \(state)")
                    XCTAssertTrue(["accessibilityTitle", "accessibilityLabel", "accessibilityValue"].contains {
                        element?.value(forKey: $0) as? String == label
                    }, "\(label) read \(state)")
                    XCTAssertEqual(element?.value(forKey: "accessibilityEnabled") as? Bool, true, "\(label) enabled \(state)")
                }
                if selectedCount == 0 {
                    XCTAssertNil(frames["lightfield.memory.command.clear"], "nothing to clear \(state)")
                    XCTAssertNil(host.element(label: L10n.text("退出所选应用 · 0 个", "Quit Selected Apps · 0")), "nothing to quit \(state)")
                }
            }
        }
        store.clearMemoryProcessSelection()
    }

    /// A page with six quittable apps sampled now (no refresh of its own),
    /// all heavy enough to be suggested.
    static func memoryStore(for testCase: XCTestCase) throws -> ScanStore {
        let store = try ScanStore.makeForTests(for: testCase)
        let gib: Int64 = 1_024 * 1_024 * 1_024
        let processes = (0..<6).map { index in
            let bundle = "/Applications/V0Review\(index).app"
            return MemoryProcess(
                id: Int32(9_300 + index), name: "V0 Review \(index)",
                path: "\(bundle)/Contents/MacOS/V0Review\(index)", iconPath: bundle, bundlePath: bundle,
                residentBytes: Int64(6 - index) * gib, percent: Double(6 - index) * 5, canQuit: true
            )
        }
        store.memorySnapshot = MemorySnapshot(
            generatedAt: Date(), physicalBytes: 16 * gib, freeBytes: 2 * gib, inactiveBytes: 0,
            speculativeBytes: 0, fileBackedBytes: gib / 2, purgeableBytes: 0, wiredBytes: 2 * gib,
            compressedBytes: gib, swapUsedBytes: 0, pressureFreePercentage: 30,
            pressureSummary: "fixture", topProcesses: processes
        )
        store.memoryShowsAllProcesses = false
        return store
    }

    // MARK: P2-2 Reduce Motion

    /// §3.1: entrances only fade, the scan button and progress card are not
    /// morphed, and layout changes land at once; every call site uses the
    /// shared rule.
    func testReduceMotionKeepsGeometryAtRest() throws {
        XCTAssertEqual(AppMotion.entranceScale(from: 0.9, hasEntered: false, reduceMotion: true), 1)
        XCTAssertEqual(AppMotion.entranceScale(from: 0.9, hasEntered: false, reduceMotion: false), 0.9)
        XCTAssertEqual(AppMotion.entranceScale(from: 0.7, hasEntered: true, reduceMotion: false), 1)
        XCTAssertFalse(AppMotion.morphsGeometry(reduceMotion: true))
        XCTAssertTrue(AppMotion.morphsGeometry(reduceMotion: false))
        XCTAssertNil(AppMotion.layout(reduceMotion: true))
        XCTAssertNotNil(AppMotion.layout(reduceMotion: false))

        let entranceScale = try NSRegularExpression(pattern: #"scaleEffect\(\s*hasEntered"#)
        for path in ["Sources/StorageCleanerMac/Views/DesignSystem/OrbitLandingArtwork.swift",
                     "Sources/StorageCleanerMac/Views/DesignSystem/GeneratedArtView.swift"] {
            let text = try source(path)
            XCTAssertEqual(entranceScale.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)), 0, path)
            XCTAssertTrue(text.contains("AppMotion.entranceScale(from:"), path)
        }
        let orbit = try source("Sources/StorageCleanerMac/Views/DesignSystem/OrbitLandingArtwork.swift")
        XCTAssertEqual(orbit.components(separatedBy: "AppMotion.entranceScale(from:").count - 1, 4, "D64 deletes the satellite entrance; all retained entrances still honor Reduce Motion")

        let landing = try source("Sources/StorageCleanerMac/Views/FileToolLandingPage.swift")
        XCTAssertTrue(landing.contains("if let namespace, AppMotion.morphsGeometry(reduceMotion: reduceMotion) {"))

        for (path, count) in [("Sources/StorageCleanerMac/Views/ModulePresentation.swift", 1),
                              ("Sources/StorageCleanerMac/Views/DesignSystem/PageHero.swift", 1),
                              // D176: the first scan folds the sidebar with the
                              // same Reduce Motion layout animation (was 2).
                              ("Sources/StorageCleanerMac/Views/ContentView.swift", 3),
                              ("Sources/StorageCleanerMac/Views/CleanupScanViews.swift", 4)] {
            let text = try source(path)
            XCTAssertEqual(text.components(separatedBy: "AppMotion.layout(reduceMotion: reduceMotion)").count - 1, count, path)
        }
        // D154: the sidebar is CleanMyMac's flat module list; its folding
        // groups (the two layout animations) are gone. Its only motion, the
        // selection block and the hover, still honors Reduce Motion.
        let sidebar = try source("Sources/StorageCleanerMac/Views/SidebarView.swift")
        XCTAssertEqual(sidebar.components(separatedBy: "AppMotion.layout(reduceMotion: reduceMotion)").count - 1, 0)
        XCTAssertEqual(sidebar.components(separatedBy: "withAnimation(").count - 1,
                       sidebar.components(separatedBy: "withAnimation(AppMotion.selection(reduceMotion: reduceMotion))").count - 1)
        XCTAssertGreaterThanOrEqual(sidebar.components(separatedBy: "withAnimation(AppMotion.selection(reduceMotion: reduceMotion))").count - 1, 1)
        XCTAssertEqual(sidebar.components(separatedBy: ".animation(").count - 1,
                       sidebar.components(separatedBy: ".animation(AppMotion.resolved(.hover, reduceMotion: reduceMotion), value: isHovered)").count - 1)
        // Symbol bounces and replacements stay still under Reduce Motion.
        let runtime = try source("Sources/StorageCleanerMac/Views/RuntimeWorkflowPresentation.swift")
        XCTAssertTrue(runtime.contains(".symbolEffect(.bounce, value: !reduceMotion && state == .completed)"))
        let scanning = try source("Sources/StorageCleanerMac/Views/SmartScanProgressView.swift")
        XCTAssertTrue(scanning.contains(".contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))"))
        XCTAssertTrue(scanning.contains(".symbolEffect(.bounce, value: !reduceMotion && "))
        // Rows that appear still fade in with their own curve.
        let motion = try source("Sources/StorageCleanerMac/Support/AppMotion.swift")
        XCTAssertTrue(motion.contains("guard !reduceMotion else { return AnyTransition.opacity.animation(reducedFade) }"))
    }

    // MARK: P2-3 Bulk updates

    /// §3.3: one group of 201 rows, or several groups adding up to more
    /// than 200, are applied without animation.
    func testBulkUpdatesCountEveryRowTheyTouch() {
        XCTAssertTrue(BulkUpdateScope(rowCount: 200).allowsAnimation)
        XCTAssertFalse(BulkUpdateScope(rowCount: 201).allowsAnimation, "one group of 201 rows")
        XCTAssertFalse(BulkUpdateScope(rowCounts: [100, 100, 1]).allowsAnimation, "three groups, 201 rows")
        XCTAssertFalse(BulkUpdateScope(rowCounts: [120, 90]).allowsAnimation, "two groups, 210 rows")
        XCTAssertTrue(BulkUpdateScope(rowCounts: [100, 100]).allowsAnimation)
        XCTAssertEqual(BulkUpdateScope(rowCounts: [5, -3, 7]).rowCount, 12)

        let bulk = BulkUpdateScope(rowCount: 201).transaction(.easeOut)
        XCTAssertNil(bulk.animation)
        XCTAssertTrue(bulk.disablesAnimations)
        let small = BulkUpdateScope(rowCount: 3).transaction(.easeOut)
        XCTAssertNotNil(small.animation)
        XCTAssertFalse(small.disablesAnimations)
    }

    /// The rows' own implicit animations (checkbox, data) stay off for a
    /// bulk update, and play for a small one.
    func testABulkUpdateKeepsRowsFromAnimatingAgain() async throws {
        let model = BulkProbeModel()
        let recorder = TransactionRecorder()
        let host = V0LayoutHost(root: BulkProbeRows(model: model, recorder: recorder),
                                size: CGSize(width: 200, height: 200))
        defer { host.close() }
        _ = try await host.frames(required: ["v0.viewport"])
        for (counts, animates) in [([201], false), ([100, 100, 1], false), ([100, 100], true)] {
            await host.settle()
            recorder.reset()
            BulkUpdateScope(rowCounts: counts).perform { model.isOn.toggle() }
            await host.settle()
            XCTAssertTrue(recorder.sawUpdate, "\(counts): the rows updated")
            XCTAssertEqual(recorder.sawAnimation, animates, "\(counts)")
        }
    }

    /// The call sites use the summed scopes: a risk tier's checkbox and
    /// expansion, the report-wide selection commands, a group, and both
    /// memory lists (up to 256 rows).
    func testBulkScopesCoverTiersReportCommandsAndMemoryLists() throws {
        let results = try source("Sources/StorageCleanerMac/Views/CleanupScanViews.swift")
        XCTAssertTrue(results.contains("BulkUpdateScope(rowCount: tierSelectionIDs.count).perform {"))
        XCTAssertTrue(results.contains("BulkUpdateScope(rowCounts: displayedSubcategories(for: risk).map(displayedRowCount(in:)))"))
        XCTAssertEqual(results.components(separatedBy: "tierScope(for: risk).perform(AppMotion.layout(reduceMotion: reduceMotion))").count - 1, 3)
        XCTAssertEqual(results.components(separatedBy: "reportScope.perform {").count - 1, 4)
        XCTAssertTrue(results.contains("BulkUpdateScope(rowCount: subcategory.selectableCandidateIDs.count).perform {"))
        let memory = try source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        XCTAssertTrue(memory.contains(".appBulkAnimationGuard(listScope)"))
        XCTAssertTrue(memory.contains(".appBulkAnimationGuard(rowCount: sampledProcesses.count)"))
        XCTAssertEqual(memory.components(separatedBy: "listScope.perform {").count - 1, 3)
    }

    // MARK: P2-4 / P2-6 Pictures

    /// The view starts with its fallback, the library reads and decodes the
    /// picture in the background, and the view then shows it; the SwiftPM
    /// test environment resolves the repository's real files through the
    /// injected resolver.
    func testViewsShowRealPicturesOnceLoadedInTheBackground() async throws {
        let library = GeneratedArtLibrary(directory: artDirectory)
        let name = GeneratedArt.memory.resourceName(.header)
        XCTAssertNil(library.cachedImage(named: name), "nothing is read before a view asks")
        let root = GeneratedArtView(art: .memory, variant: .header) { Color.red }
            .frame(width: 64, height: 64)
            .environment(\.generatedArtLibrary, library)
        let host = V0LayoutHost(root: root, size: CGSize(width: 120, height: 120))
        defer { host.close() }
        let frames = try await host.frames(required: ["generatedArt.image.\(name)"])
        XCTAssertNil(frames["generatedArt.fallback.\(name)"], "the fallback gives way")
        let image = try XCTUnwrap(library.cachedImage(named: name), "the decoded picture is kept")
        XCTAssertEqual(image.width, GeneratedArt.Variant.header.rawValue)
    }

    func testAMissingPictureKeepsTheFallbackWithoutRetrying() async throws {
        let empty = try TestFileSystem.makeHome(for: self)
        let library = GeneratedArtLibrary(directory: empty)
        let name = GeneratedArt.memory.resourceName(.header)
        let root = GeneratedArtView(art: .memory, variant: .header) { Color.red }
            .frame(width: 64, height: 64)
            .environment(\.generatedArtLibrary, library)
        let host = V0LayoutHost(root: root, size: CGSize(width: 120, height: 120))
        defer { host.close() }
        _ = try await host.frames(required: ["generatedArt.fallback.\(name)"])
        for _ in 0..<100 where !library.isKnownMissing(named: name) {
            await host.settle(milliseconds: 5)
        }
        XCTAssertTrue(library.isKnownMissing(named: name))
        await host.settle()
        XCTAssertNil(host.currentFrames["generatedArt.image.\(name)"])
        XCTAssertNotNil(host.currentFrames["generatedArt.fallback.\(name)"])
    }

    /// A slow file read does not hold the cache lock: other pictures are
    /// served and loaded meanwhile, and concurrent requests share one load.
    /// (The check runs on its own task with a deadline, so a held lock fails
    /// the test instead of hanging it.)
    func testASlowPictureDoesNotBlockTheCacheOrOtherPictures() async throws {
        let gate = DispatchSemaphore(value: 0)
        let directory = artDirectory
        let slowName = GeneratedArt.smartScan.resourceName(.landing)
        let otherName = GeneratedArt.memory.resourceName(.header)
        let resolver = GeneratedArtResolver { name in
            if name == slowName { gate.wait() }
            return GeneratedArtResolver.directory(directory).url(name)
        }
        let library = GeneratedArtLibrary(resolver: resolver)
        let slow = Task.detached { await library.image(named: slowName) }
        let shared = Task.detached { await library.image(named: slowName) }
        try await Task.sleep(nanoseconds: 50_000_000)

        let answered = CompletionFlag()
        let probe = Task.detached {
            _ = library.cachedImage(named: slowName)
            let other = await library.image(named: otherName)
            answered.set(other != nil)
        }
        let deadline = Date().addingTimeInterval(2)
        while answered.value == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let answeredInTime = answered.value
        // Release the slow read (twice, in case the loads were not shared).
        gate.signal()
        gate.signal()
        await probe.value
        XCTAssertEqual(answeredInTime, true, "the cache and another picture answered during the slow read")

        let first = await slow.value
        let second = await shared.value
        XCTAssertNotNil(first)
        XCTAssertTrue(first === second, "one load for concurrent requests")
        XCTAssertTrue(library.cachedImage(named: slowName) === first)
    }

    // MARK: P2-5 Memory trend chart

    /// VoiceOver reads both series (current, average, lowest, highest) and
    /// says when the latest sample has no reading; the pointer readout shows
    /// the sample under it.
    func testTrendChartReadsBothSeriesAndTheSampleUnderThePointer() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func series(_ values: [Double?]) -> [TrendChart.Sample] {
            values.enumerated().map { offset, value in
                TrendChart.Sample(date: now.addingTimeInterval(Double(offset - values.count + 1) * 2), value: value)
            }
        }
        let usage = series([50, 60, 70])
        let pressure = series([30, 40, nil])
        let label: (Double) -> String = { "\(Int($0))%" }
        let memory = L10n.text("内存占用", "Memory Usage")
        let estimate = L10n.text("压力趋势估算", "Pressure estimate")
        let summary = TrendChart.accessibilitySummary(series: [(memory, usage), (estimate, pressure)], valueLabel: label)
        XCTAssertEqual(summary, L10n.text(
            "内存占用：当前 70%，平均 60%，最低 50%，最高 70%；压力趋势估算：当前无数据，平均 35%，最低 30%，最高 40%",
            "Memory Usage: current 70%, average 60%, minimum 50%, maximum 70%; Pressure estimate: no current reading, average 35%, minimum 30%, maximum 40%"
        ))
        XCTAssertEqual(TrendChart.accessibilitySummary(series: [(memory, []), (estimate, series([nil, nil]))], valueLabel: label),
                       PanelChartSampling.statusText)

        let plot = CGRect(x: 40, y: 4, width: 200, height: 100)
        XCTAssertEqual(TrendChart.nearestSampleIndex(toX: 240, plot: plot, samples: usage, duration: 120), 2)
        XCTAssertEqual(TrendChart.nearestSampleIndex(toX: 238, plot: plot, samples: usage, duration: 120), 1)
        XCTAssertNil(TrendChart.nearestSampleIndex(toX: 40, plot: plot, samples: usage, duration: 120),
                     "no sample near the start of the window")
        XCTAssertEqual(
            TrendChart.readoutLines(index: 2, samples: usage, secondarySamples: pressure,
                                    titles: (memory, estimate), valueLabel: label),
            [L10n.text("现在", "Now"), "\(memory) 70%", "\(estimate) \(L10n.text("无数据", "No data"))"]
        )
        XCTAssertEqual(
            TrendChart.readoutLines(index: 1, samples: usage, secondarySamples: pressure,
                                    titles: (memory, estimate), valueLabel: label).first,
            L10n.text("2 秒前", "2 s ago")
        )

        let page = try source("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift")
        XCTAssertTrue(page.contains("title: L10n.text(\"内存占用\", \"Memory Usage\")"))
        XCTAssertTrue(page.contains("secondaryTitle: L10n.text(\"压力趋势估算\", \"Pressure estimate\")"))
        let chart = try source("Sources/StorageCleanerMac/Views/DesignSystem/DataVisuals.swift")
        XCTAssertTrue(chart.contains(".onContinuousHover { phase in"))
    }

    // MARK: P2-7 Risk card captions

    /// At 1000, 1280 and 1680 pt in Chinese and English, every risk card's
    /// count and selection line is shown whole: on one line at its full
    /// width, or on its own line below; never truncated or shrunk.
    func testRiskCardCaptionsAreNeverTruncated() async throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            XCTAssertEqual(L10n.appLanguage, language)
            let store = try ScanStore.makeForTests(for: self)
            store.installDebugSmartScanSessionFixture(.results)
            let session = try XCTUnwrap(store.cleanupScanSession)
            let view = CleanupScanResultsView(store: store, filter: .overview, session: session)
            let risks: [CleanupRisk] = [.safe, .reviewOnly, .protected]
            let ideal = Dictionary(uniqueKeysWithValues: risks.map { risk in
                (risk, Self.idealWidth(of: view.riskCaption(for: risk)))
            })
            let root = AdaptivePageViewport(resetID: .overview) {
                CleanupScanOverviewView(store: store, session: session)
                    .environment(\.moduleTheme, ReviewFilter.overview.moduleTheme)
            }
            let host = V0LayoutHost(root: root, size: CGSize(width: 1_000, height: 700))
            defer { host.close() }
            let required = Set(risks.flatMap { ["results.riskCaption.\($0.rawValue)", LayoutProbeID.cleanupRiskSummary($0)] })
            for width in [CGFloat(1_000), 1_280, 1_680] {
                host.resize(to: CGSize(width: width, height: 764))
                let frames = try await host.frames(required: required)
                for risk in risks {
                    let caption = try XCTUnwrap(frames["results.riskCaption.\(risk.rawValue)"])
                    let card = try XCTUnwrap(frames[LayoutProbeID.cleanupRiskSummary(risk)])
                    let idealWidth = try XCTUnwrap(ideal[risk])
                    let context = "\(language) \(width) \(risk): caption \(caption) in card \(card), ideal \(idealWidth)"
                    XCTAssertTrue(card.insetBy(dx: -0.5, dy: -0.5).contains(caption), context)
                    XCTAssertTrue(caption.width >= idealWidth - 0.5 || caption.height >= Self.lineHeight * 1.8, context)
                }
            }
        }
    }

    private static var lineHeight: CGFloat {
        NSHostingController(rootView: Text("Ag").font(AppDesignTokens.TypeScale.caption).fixedSize()).view.fittingSize.height
    }

    private static func idealWidth(of text: String) -> CGFloat {
        NSHostingController(rootView: Text(text).font(AppDesignTokens.TypeScale.caption).monospacedDigit().fixedSize())
            .view.fittingSize.width
    }

    // MARK: P2-8 Orbit drawing

    /// From a short window's 220 pt up to 600 pt, the outer orbit, every node
    /// and its label stay inside the square; labels are left out below
    /// 320 pt instead of being cut.
    func testOrbitDrawingKeepsNodesAndLabelsInsideItsSquare() throws {
        // D64 removes every satellite and its label, retaining centered art,
        // orbits, halo and the existing native visibility/motion safeguards.
        for side in stride(from: CGFloat(220), through: 600, by: 20) {
            let geometry = OrbitArtworkGeometry.resolve(side: side)
            let square = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: -0.01, dy: -0.01)
            XCTAssertTrue(square.contains(geometry.outerOrbitBounds), "orbit at \(side)")
            XCTAssertEqual(geometry.center.x, side / 2, accuracy: 0.01)
            XCTAssertEqual(geometry.center.y, side / 2, accuracy: 0.01)
            XCTAssertGreaterThan(geometry.drawing, 0)
            XCTAssertLessThanOrEqual(geometry.drawing, side)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/StorageCleanerMac/Views/DesignSystem/OrbitLandingArtwork.swift"), encoding: .utf8)
        for deleted in ["ForEach(Array(nodes", "nodeView(", "struct Node", "nodeBounds(", "orbCenter("] {
            XCTAssertFalse(source.contains(deleted), deleted)
        }
        for retained in ["centerMark(side: drawing)", "halo(side: drawing)", "orbits(side: drawing)",
                         ".padding(bleed)", ".padding(-bleed)"] {
            XCTAssertTrue(source.contains(retained), retained)
        }
    }


    // MARK: Review 2

    /// Review 2, P2-1: opening a tier whose groups add up to more than 200
    /// rows, and a group that appears later in it, start no entrance
    /// animation; a small tier still staggers its groups in (control).
    func testALargeTierOpensItsGroupsWithoutEntranceAnimations() async throws {
        let small = try await staggeredEntrancesWhenOpeningGreenTier(rowCounts: [5, 5, 5])
        XCTAssertEqual(small.opened, 3, "a small tier staggers its three groups")

        let large = try await staggeredEntrancesWhenOpeningGreenTier(rowCounts: [80, 80, 80], thenAddGroupOf: 80)
        XCTAssertEqual(large.opened, 0, "240 rows: the groups appear at once")
        XCTAssertEqual(large.added, 0, "a group added to the open 320-row tier appears at once")
        XCTAssertTrue(large.addedGroupShown, "the added group is on screen")
    }

    /// Waits without yielding the main actor (so no view task can run).
    private static func blockMainThread(seconds: TimeInterval, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func staggeredEntrancesWhenOpeningGreenTier(
        rowCounts: [Int], thenAddGroupOf addedRows: Int? = nil
    ) async throws -> (opened: Int, added: Int, addedGroupShown: Bool) {
        let store = try ScanStore.makeForTests(for: self)
        let model = BulkSessionModel(session: DebugSmartScanSessionFixture.makeBulkSession(rowCounts: rowCounts))
        let host = V0LayoutHost(root: BulkResultsHost(store: store, model: model), size: CGSize(width: 1_280, height: 1_100),
                                accessibility: true)
        defer { host.close() }
        let card = LayoutProbeID.cleanupRiskSummary(.safe)
        let frames = try await host.frames(required: [card, "v0.viewport"])
        // Let the page's own entrances (summary cards) finish, then count.
        await host.settle(milliseconds: 600)
        AppMotionDebugCounters.staggeredEntrances = 0
        // The green risk card opens its tier (what a click or VoiceOver does).
        let pressed = await AccessibilityTree.pressButton(
            at: try XCTUnwrap(frames[card]), viewport: try XCTUnwrap(frames["v0.viewport"]), in: host)
        XCTAssertTrue(pressed, "the green risk card can be pressed")
        let groups = Set(rowCounts.indices.map { "results.group.bulk-\($0)" })
        _ = try await host.frames(required: groups)
        await host.settle(milliseconds: 100)
        let opened = AppMotionDebugCounters.staggeredEntrances

        guard let addedRows else { return (opened, 0, false) }
        AppMotionDebugCounters.staggeredEntrances = 0
        model.session = DebugSmartScanSessionFixture.makeBulkSession(rowCounts: rowCounts + [addedRows])
        let added = try await host.frames(required: groups.union(["results.group.bulk-\(rowCounts.count)"]))
        await host.settle(milliseconds: 100)
        return (opened, AppMotionDebugCounters.staggeredEntrances, added["results.group.bulk-\(rowCounts.count)"] != nil)
    }

    /// Review 2, P2-2: a preload that fills the cache after the view's body
    /// drew its fallback, but before the view's own task looks at the cache,
    /// still ends with the picture on screen, with nothing else changing.
    /// The fallback's body itself lets the preload finish, so the cache is
    /// filled exactly in that window.
    func testAPreloadThatFinishesFirstStillShowsThePicture() async throws {
        let name = GeneratedArt.memory.resourceName(.header)
        let directory = artDirectory
        let gate = DispatchSemaphore(value: 0)
        let library = GeneratedArtLibrary(resolver: GeneratedArtResolver { requested in
            if requested == name { gate.wait() }
            return GeneratedArtResolver.directory(directory).url(requested)
        })
        // A preload of the picture is on its way, held at the gate.
        let preload = Task.detached { await library.image(named: name) }
        try await Task.sleep(nanoseconds: 30_000_000)
        let finishPreload = OnceAction {
            gate.signal()
            Self.blockMainThread(seconds: 3) { library.cachedImage(named: name) != nil }
        }
        let root = GeneratedArtView(art: .memory, variant: .header) {
            CacheFillingFallback(whenDrawn: finishPreload)
        }
        .frame(width: 64, height: 64)
        .environment(\.generatedArtLibrary, library)
        let host = V0LayoutHost(root: root, size: CGSize(width: 120, height: 120))
        defer { host.close() }
        host.layoutNow()
        XCTAssertTrue(finishPreload.didRun, "the fallback was drawn while the cache was empty")
        XCTAssertNotNil(library.cachedImage(named: name), "the preload filled the cache")
        // Nothing else changes; the view must still show the picture.
        _ = try await host.frames(required: ["generatedArt.image.\(name)"])
        for _ in 0..<100 where !PageMarkerView.identifiers(in: host.hostingView).isEmpty {
            await host.settle(milliseconds: 10)
        }
        XCTAssertTrue(PageMarkerView.identifiers(in: host.hostingView).isEmpty, "the fallback faded out")
        _ = await preload.value
    }

    /// Review 2, P2-4: a pointer resting at the right edge reads the newest
    /// sample as samples keep arriving (it is not pinned to an old index).
    func testAPointerAtRestFollowsNewSamples() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 820_000_000)
        let model = TrendProbeModel(samples: [TrendChart.Sample(date: start, value: 50)])
        let host = V0LayoutHost(root: TrendProbe(model: model, hoverFraction: 1), size: CGSize(width: 420, height: 170))
        defer { host.close() }
        func key(_ date: Date) -> String { "trend.readout.\(Int(date.timeIntervalSinceReferenceDate))" }
        _ = try await host.frames(required: [key(start)])
        for step in 1...3 {
            let date = start.addingTimeInterval(Double(step) * 2)
            model.samples.append(TrendChart.Sample(date: date, value: 50 + Double(step) * 10))
            let frames = try await host.frames(required: [key(date)])
            XCTAssertNil(frames[key(start)], "step \(step): the readout left the first sample")
            for earlier in 0..<step {
                XCTAssertNil(frames[key(start.addingTimeInterval(Double(earlier) * 2))], "step \(step)")
            }
        }
    }

    /// Review 2, P2-5: the readout shows every line whole, in Chinese and
    /// English, for a normal value, 100% and no data.
    func testTheTrendReadoutShowsEveryLineWhole() async throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        let now = Date(timeIntervalSinceReferenceDate: 820_000_000)
        let label: (Double) -> String = { "\(Int($0))%" }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let titles = (L10n.text("内存占用", "Memory Usage"), L10n.text("压力趋势估算", "Pressure estimate"))
            for (usage, pressure) in [(Double?(56), Double?(40)), (100, 100), (nil, nil)] {
                let lines = TrendChart.readoutLines(
                    index: 0,
                    samples: [TrendChart.Sample(date: now, value: usage)],
                    secondarySamples: [TrendChart.Sample(date: now, value: pressure)],
                    titles: titles, valueLabel: label
                )
                let host = V0LayoutHost(root: TrendChartReadout(lines: lines), size: CGSize(width: 320, height: 120))
                defer { host.close() }
                let probes = Set(lines.indices.map { "trend.readout.line.\($0)" })
                let frames = try await host.frames(required: probes)
                for (index, line) in lines.enumerated() {
                    let frame = try XCTUnwrap(frames["trend.readout.line.\(index)"])
                    let font = index == 0 ? AppDesignTokens.TypeScale.caption : AppDesignTokens.TypeScale.captionEmphasis
                    let ideal = NSHostingController(rootView: Text(line).font(font).monospacedDigit().fixedSize())
                        .view.fittingSize.width
                    XCTAssertGreaterThanOrEqual(frame.width, ideal - 0.5, "\(language) “\(line)” whole (\(frame.width) of \(ideal))")
                }
            }
        }
    }


    // MARK: Review 3

    /// Review 3, P2-1: groups first shown at once in a tier of more than 200
    /// rows stay visible when the tier shrinks below 200 rows and keeps
    /// their identities (as a filter does); checked on the screen pixels of
    /// the real results page, not only by their probes.
    func testGroupsShownInALargeTierStayVisibleWhenItShrinks() async throws {
        let store = try ScanStore.makeForTests(for: self)
        let model = BulkSessionModel(session: DebugSmartScanSessionFixture.makeBulkSession(rowCounts: [80, 80, 80]))
        let host = V0LayoutHost(root: BulkResultsHost(store: store, model: model), size: CGSize(width: 1_280, height: 1_100),
                                accessibility: true)
        defer { host.close() }
        let card = LayoutProbeID.cleanupRiskSummary(.safe)
        let frames = try await host.frames(required: [card, "v0.viewport"])
        let pressed = await AccessibilityTree.pressButton(
            at: try XCTUnwrap(frames[card]), viewport: try XCTUnwrap(frames["v0.viewport"]), in: host)
        XCTAssertTrue(pressed, "the green risk card opens its tier")
        let groups = (0..<3).map { "results.group.bulk-\($0)" }
        _ = try await host.frames(required: Set(groups))
        await host.settle(milliseconds: 300)
        for group in groups {
            XCTAssertGreaterThan(try Self.brightestPixel(of: group, in: host), 0.6, "\(group) visible in the 240-row tier")
        }
        // The same three groups, 30 rows each: 90 rows in all.
        model.session = DebugSmartScanSessionFixture.makeBulkSession(rowCounts: [30, 30, 30])
        await host.settle(milliseconds: 800)
        _ = try await host.frames(required: Set(groups))
        for group in groups {
            XCTAssertGreaterThan(try Self.brightestPixel(of: group, in: host), 0.6, "\(group) still visible at 90 rows")
        }
    }

    /// The same rule on the entrance itself: items shown at once inside a
    /// large scope keep taking the mouse (they stay opaque) after the scope
    /// shrinks.
    func testEntrancesShownAtOnceStayShownWhenTheScopeShrinks() async throws {
        let model = StaggerScopeModel(rowCounts: [80, 80, 80])
        let host = V0LayoutHost(root: StaggerScopeProbe(model: model), size: CGSize(width: 240, height: 160))
        defer { host.close() }
        await host.settle(milliseconds: 300)
        let items = (0..<3).map { "stagger.\($0)" }
        for item in items {
            XCTAssertTrue(PageMarkerView.receivesMouse(item, in: host.hostingView), "\(item) shown in the large scope")
        }
        model.rowCounts = [30, 30, 30]
        await host.settle(milliseconds: 800)
        for item in items {
            XCTAssertTrue(PageMarkerView.receivesMouse(item, in: host.hostingView), "\(item) still shown at 90 rows")
        }
    }

    /// The brightest pixel (0...1 luminance) inside a probed frame of the
    /// rendered window: text of a visible group is near white on the dark
    /// canvas, a transparent group shows only the canvas.
    private static func brightestPixel(of probe: String, in host: V0LayoutHost) throws -> CGFloat {
        let frames = host.currentFrames
        let frame = try XCTUnwrap(frames[probe], probe)
        let viewport = try XCTUnwrap(frames["v0.viewport"])
        let view = host.hostingView
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        let local = frame.offsetBy(dx: -viewport.minX, dy: -viewport.minY).intersection(view.bounds)
        var brightest: CGFloat = 0
        for y in stride(from: local.minY + 1, to: local.maxY - 1, by: 2) {
            for x in stride(from: local.minX + 1, to: local.maxX - 1, by: 2) {
                guard let color = rep.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) else { continue }
                let luminance = 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
                brightest = max(brightest, luminance * color.alphaComponent)
            }
        }
        return brightest
    }

    /// Review 3, P2-2: in charts 220, 260 and 300 pt wide, with the pointer
    /// at the left, middle and right, in Chinese and English, for no data and
    /// 100%, the readout lies inside the chart with every line whole.
    func testTheTrendReadoutStaysInsideNarrowCharts() async throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        let end = Date(timeIntervalSinceReferenceDate: 820_000_000)
        let dates = (0...12).map { end.addingTimeInterval(Double($0 - 12) * 10) }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            for value in [Double?.none, 100] {
                let samples = dates.map { TrendChart.Sample(date: $0, value: value) }
                for width in [CGFloat(220), 260, 300] {
                    for fraction in [CGFloat(0.05), 0.5, 0.95] {
                        let probe = TrendPlacementProbe(samples: samples, width: width, fraction: fraction)
                        let host = V0LayoutHost(root: probe, size: CGSize(width: width + 40, height: 160))
                        defer { host.close() }
                        let frames = try await host.frames(required: ["trend.chart", "trend.readout.line.2"])
                        let chart = try XCTUnwrap(frames["trend.chart"])
                        let readout = try XCTUnwrap(frames.first { $0.key.hasPrefix("trend.readout.") && !$0.key.contains(".line.") }?.value)
                        let context = "\(language) \(value.map { "\($0)" } ?? "no data") \(width) pt at \(fraction): readout \(readout) in chart \(chart)"
                        XCTAssertGreaterThanOrEqual(readout.minX, chart.minX - 0.5, context)
                        XCTAssertLessThanOrEqual(readout.maxX, chart.maxX + 0.5, context)
                        for index in 0..<3 {
                            let line = try XCTUnwrap(frames["trend.readout.line.\(index)"])
                            XCTAssertTrue(readout.insetBy(dx: -0.5, dy: -0.5).contains(line), "line \(index) inside: \(context)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Contract #11 Page changes

    /// While the old page fades out, only the new page can be operated or
    /// read by VoiceOver.
    func testAPageChangeLeavesOnlyTheNewPageReachable() async throws {
        let model = PageProbeModel()
        let host = V0LayoutHost(root: PageProbe(model: model), size: CGSize(width: 480, height: 320), accessibility: true)
        defer { host.close() }
        _ = try await host.frames(required: ["review.page.0"])
        _ = await AccessibilityTree.wait(in: host) { $0.contains { $0.isButton && $0.reads("页面 0") } }
        // Before the change the old page takes the mouse (the check works).
        XCTAssertTrue(PageMarkerView.receivesMouse("review.page.0", in: host.hostingView))
        model.key = 1
        var sampledBoth = false
        for _ in 0..<80 {
            await host.settle(milliseconds: 2)
            // Both pages exist while the old one fades out (their platform
            // markers are still in the view tree).
            let markers = PageMarkerView.identifiers(in: host.hostingView)
            let pages = AccessibilityTree.elements(in: host.hostingView).filter { element in
                element.isButton && (element.reads("页面 0") || element.reads("页面 1"))
            }
            XCTAssertFalse(pages.contains { $0.reads("页面 0") }, "the leaving page is not reachable (markers \(markers))")
            XCTAssertLessThanOrEqual(pages.count, 1)
            if markers.contains("review.page.0"), markers.contains("review.page.1") {
                sampledBoth = true
                // The mouse path: a click on the old page's button reaches
                // nothing of it; the new page's button takes clicks.
                XCTAssertFalse(PageMarkerView.receivesMouse("review.page.0", in: host.hostingView),
                               "a click on the leaving page reaches \(String(describing: PageMarkerView.mouseTarget(of: "review.page.0", in: host.hostingView)))")
                XCTAssertTrue(PageMarkerView.receivesMouse("review.page.1", in: host.hostingView))
            }
            if sampledBoth, !markers.contains("review.page.0") { break }
        }
        XCTAssertTrue(sampledBoth, "sampled while both pages were on screen")
        let settled = await AccessibilityTree.wait(in: host) { $0.contains { $0.isButton && $0.reads("页面 1") } }
        XCTAssertTrue(settled.contains { $0.isButton && $0.reads("页面 1") })
    }

    func testTheLeavingPageModifierHidesAndDisablesItsPage() async throws {
        for isLeaving in [false, true] {
            let host = V0LayoutHost(
                root: Button("离开的页面") {}
                    .overlay(PageMarker(identifier: "leaving.page"))
                    .modifier(AppMotionOutgoingPageModifier(isLeaving: isLeaving)),
                size: CGSize(width: 240, height: 120), accessibility: true
            )
            defer { host.close() }
            let elements = await AccessibilityTree.wait(in: host) { elements in
                elements.contains { $0.reads("离开的页面") } != isLeaving
            }
            XCTAssertEqual(elements.contains { $0.reads("离开的页面") }, !isLeaving, "VoiceOver path")
            await host.settle()
            XCTAssertEqual(PageMarkerView.receivesMouse("leaving.page", in: host.hostingView), !isLeaving, "mouse path")
        }
    }
}

// MARK: - Fixtures

/// A value set once from another task.
final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool?

    var value: Bool? { lock.withLock { stored } }

    func set(_ value: Bool) {
        lock.withLock { stored = value }
    }
}

final class BulkProbeModel: ObservableObject {
    @Published var isOn = false
}

/// Records whether a row update carried an animation. Read and written on
/// the main thread only.
final class TransactionRecorder: @unchecked Sendable {
    private(set) var sawUpdate = false
    private(set) var sawAnimation = false

    func reset() {
        sawUpdate = false
        sawAnimation = false
    }

    func record(_ transaction: Transaction) {
        sawUpdate = true
        if transaction.animation != nil { sawAnimation = true }
    }
}

/// Rows that animate their own changes, like a checkbox.
struct BulkProbeRows: View {
    @ObservedObject var model: BulkProbeModel
    let recorder: TransactionRecorder

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Rectangle()
                    .frame(width: model.isOn ? 40 : 20, height: 8)
                    .transaction { recorder.record($0) }
                    .animation(.easeOut(duration: 0.3), value: model.isOn)
            }
        }
    }
}

final class BulkSessionModel: ObservableObject {
    @Published var session: ScanSession

    init(session: ScanSession) {
        self.session = session
    }
}

/// The results page of a session that can be replaced while it is open.
struct BulkResultsHost: View {
    @ObservedObject var store: ScanStore
    @ObservedObject var model: BulkSessionModel

    var body: some View {
        AdaptivePageViewport(resetID: .overview) {
            CleanupScanResultsView(store: store, filter: .overview, session: model.session)
                .environment(\.moduleTheme, ReviewFilter.overview.moduleTheme)
        }
    }
}

/// Runs its action the first time it is called (main thread only).
final class OnceAction: @unchecked Sendable {
    private let action: () -> Void
    private(set) var didRun = false

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func run() {
        guard !didRun else { return }
        didRun = true
        action()
    }
}

/// A fallback whose first body runs an action (the test lets a preload
/// finish there, between the picture view's body and its task).
struct CacheFillingFallback: View {
    let whenDrawn: OnceAction

    var body: some View {
        whenDrawn.run()
        return PageMarker(identifier: "art.fallback")
    }
}

final class StaggerScopeModel: ObservableObject {
    @Published var rowCounts: [Int]

    init(rowCounts: [Int]) {
        self.rowCounts = rowCounts
    }
}

/// Three staggered items inside a bulk scope that can shrink.
struct StaggerScopeProbe: View {
    @ObservedObject var model: StaggerScopeModel

    var body: some View {
        VStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { index in
                PageMarker(identifier: "stagger.\(index)")
                    .frame(width: 120, height: 24)
                    .appStaggeredAppearance(index: index)
            }
        }
        .appBulkAnimationGuard(BulkUpdateScope(rowCounts: model.rowCounts))
    }
}

/// A memory-style trend chart of a given width, pointer resting at
/// `fraction`, with both series named as on the Memory page.
struct TrendPlacementProbe: View {
    let samples: [TrendChart.Sample]
    let width: CGFloat
    let fraction: CGFloat

    var body: some View {
        TrendChart(
            samples: samples,
            secondarySamples: samples,
            color: .purple,
            accessibilityLabel: "trend",
            title: L10n.text("内存占用", "Memory Usage"),
            secondaryTitle: L10n.text("压力趋势估算", "Pressure estimate"),
            debugHoverFraction: fraction
        )
        .frame(width: width, height: 118)
        .layoutProbe("trend.chart")
    }
}

final class TrendProbeModel: ObservableObject {
    @Published var samples: [TrendChart.Sample]

    init(samples: [TrendChart.Sample]) {
        self.samples = samples
    }
}

/// A trend chart with the pointer resting at `hoverFraction` of the plot.
struct TrendProbe: View {
    @ObservedObject var model: TrendProbeModel
    let hoverFraction: CGFloat

    var body: some View {
        TrendChart(
            samples: model.samples,
            color: .purple,
            accessibilityLabel: "trend",
            title: "Usage",
            debugHoverFraction: hoverFraction
        )
        .frame(width: 400, height: 150)
    }
}

final class PageProbeModel: ObservableObject {
    @Published var key = 0
}

struct PageProbe: View {
    @ObservedObject var model: PageProbeModel

    var body: some View {
        PageTransitionContainer(key: model.key) {
            // Page 0 keeps its button at the bottom, page 1 at the top, so
            // during the change a pointer on the old button has nothing of
            // the new page under it.
            VStack(spacing: 0) {
                if model.key == 0 { Spacer(minLength: 0) }
                // The marker lies over the button: whatever the mouse reaches
                // there is this page's content.
                Button("页面 \(model.key)") {}
                    .overlay(PageMarker(identifier: "review.page.\(model.key)"))
                    .layoutProbe("review.page.\(model.key)")
                if model.key != 0 { Spacer(minLength: 0) }
            }
            .frame(height: 280)
        }
    }
}

/// A platform view that marks a page in the view tree while it exists,
/// including while it fades out.
struct PageMarker: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> PageMarkerView {
        let view = PageMarkerView()
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
        return view
    }

    func updateNSView(_ view: PageMarkerView, context: Context) {
        view.identifier = NSUserInterfaceItemIdentifier(identifier)
    }
}

final class PageMarkerView: NSView {
    static func identifiers(in root: NSView) -> [String] {
        markers(in: root).compactMap { $0.identifier?.rawValue }
    }

    static func markers(in root: NSView) -> [PageMarkerView] {
        var result: [PageMarkerView] = []
        func walk(_ view: NSView) {
            if let marker = view as? PageMarkerView { result.append(marker) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return result
    }

    /// What a mouse click at this marker's center would reach: AppKit routes
    /// mouse events to the view `hitTest` returns, and SwiftUI answers it
    /// with its own hit-testing rules (`allowsHitTesting`).
    static func mouseTarget(of identifier: String, in root: NSView) -> NSView? {
        guard let marker = markers(in: root).first(where: { $0.identifier?.rawValue == identifier }),
              let container = root.superview else { return nil }
        let center = marker.convert(CGPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: container)
        return root.hitTest(center)
    }

    static func receivesMouse(_ identifier: String, in root: NSView) -> Bool {
        (mouseTarget(of: identifier, in: root) as? PageMarkerView)?.identifier?.rawValue == identifier
    }
}

/// Reads the native accessibility tree of a hosting view through the public
/// NSAccessibility getters (no fake nodes).
@MainActor
enum AccessibilityTree {
    struct Element {
        let role: String?
        let label: String?
        let title: String?
        let isEnabled: Bool?
        let frame: CGRect?

        var isButton: Bool { role == NSAccessibility.Role.button.rawValue }

        func reads(_ text: String) -> Bool {
            label == text || title == text
        }
    }

    static func elements(in root: NSObject, limit: Int = 8_000) -> [Element] {
        var result: [Element] = []
        var visited = Set<ObjectIdentifier>()
        func walk(_ object: NSObject) {
            guard result.count < limit, visited.insert(ObjectIdentifier(object)).inserted else { return }
            result.append(describe(object))
            for name in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                for case let child as NSObject in (value(object, name) as? [Any]) ?? [] {
                    walk(child)
                }
            }
            // Scroll areas publish their content through their document view.
            if let scroll = object as? NSScrollView, let document = scroll.documentView {
                walk(document)
            }
            if let view = object as? NSView {
                for subview in view.subviews { walk(subview) }
            }
        }
        walk(root)
        return result
    }

    /// The button VoiceOver finds at the center of a probed frame (a public
    /// accessibility hit test, then the button under the point). Probe
    /// frames are SwiftUI global coordinates; `viewport` (the root's global
    /// frame) translates them into the hosting view.
    static func button(at frame: CGRect, viewport: CGRect, in host: V0LayoutHost) async -> Element? {
        let view = host.hostingView
        let local = CGPoint(x: frame.midX - viewport.minX, y: frame.midY - viewport.minY)
        let windowPoint = view.convert(local, to: nil)
        let screenPoint = host.window.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin
        var found: Element?
        for _ in 0..<60 {
            await host.settle(milliseconds: 5)
            guard let hit = view.accessibilityHitTest(screenPoint) as? NSObject else { continue }
            // The hit may be the container (the pinned bar); look inside it
            // for the button under the point, then up its parents.
            if let button = descendantButton(of: hit, containing: screenPoint) { return describe(button) }
            var current: NSObject? = hit
            for _ in 0..<10 {
                guard let node = current else { break }
                let element = describe(node)
                if element.isButton { return element }
                found = found ?? element
                current = value(node, "accessibilityParent") as? NSObject
            }
        }
        return found
    }

    private static func descendantButton(of root: NSObject, containing point: CGPoint) -> NSObject? {
        var visited = Set<ObjectIdentifier>()
        func search(_ object: NSObject, depth: Int) -> NSObject? {
            guard depth < 12, visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = describe(object)
            if element.isButton, element.frame?.insetBy(dx: -1, dy: -1).contains(point) == true { return object }
            for name in ["accessibilityChildren", "accessibilityChildrenInNavigationOrder"] {
                for case let child as NSObject in (value(object, name) as? [Any]) ?? [] {
                    if let match = search(child, depth: depth + 1) { return match }
                }
            }
            return nil
        }
        return search(root, depth: 0)
    }

    private static func describe(_ object: NSObject) -> Element {
        Element(
            role: text(object, "accessibilityRole"),
            label: text(object, "accessibilityLabel"),
            title: text(object, "accessibilityTitle"),
            isEnabled: flag(object, getter: "isAccessibilityEnabled", key: "accessibilityEnabled"),
            frame: rect(object)
        )
    }

    /// Presses the button VoiceOver finds at the center of a probed frame,
    /// through its public accessibility action.
    static func pressButton(at frame: CGRect, viewport: CGRect, in host: V0LayoutHost) async -> Bool {
        let view = host.hostingView
        let local = CGPoint(x: frame.midX - viewport.minX, y: frame.midY - viewport.minY)
        let windowPoint = view.convert(local, to: nil)
        let screenPoint = host.window.convertToScreen(CGRect(origin: windowPoint, size: .zero)).origin
        let selector = NSSelectorFromString("accessibilityPerformPress")
        for _ in 0..<60 {
            await host.settle(milliseconds: 5)
            guard let hit = view.accessibilityHitTest(screenPoint) as? NSObject else { continue }
            var button = descendantButton(of: hit, containing: screenPoint)
            var current: NSObject? = hit
            for _ in 0..<10 where button == nil {
                guard let node = current else { break }
                if describe(node).isButton { button = node }
                current = value(node, "accessibilityParent") as? NSObject
            }
            guard let button, button.responds(to: selector), let implementation = button.method(for: selector) else { continue }
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(implementation, to: Press.self)(button, selector)
        }
        return false
    }

    /// Presses the first button read as `label` through its public
    /// accessibility action (what VoiceOver does).
    @discardableResult
    static func press(_ label: String, in host: V0LayoutHost) -> Bool {
        var visited = Set<ObjectIdentifier>()
        func find(_ object: NSObject) -> NSObject? {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return nil }
            let element = describe(object)
            if element.isButton, element.reads(label) { return object }
            for name in ["accessibilityChildren", "accessibilityContents", "accessibilityChildrenInNavigationOrder"] {
                for case let child as NSObject in (value(object, name) as? [Any]) ?? [] {
                    if let match = find(child) { return match }
                }
            }
            if let view = object as? NSView {
                for subview in view.subviews {
                    if let match = find(subview) { return match }
                }
            }
            return nil
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard let button = find(host.hostingView), button.responds(to: selector),
              let implementation = button.method(for: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(implementation, to: Press.self)(button, selector)
    }

    /// Polls with layout passes until `condition` holds (or about a second).
    static func wait(in host: V0LayoutHost, until condition: ([Element]) -> Bool) async -> [Element] {
        var last: [Element] = []
        for _ in 0..<120 {
            await host.settle(milliseconds: 5)
            last = elements(in: host.hostingView)
            if condition(last) { return last }
        }
        return last
    }

    private static func value(_ object: NSObject, _ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func text(_ object: NSObject, _ name: String) -> String? {
        switch value(object, name) {
        case let text as String: text
        case let text as NSAttributedString: text.string
        default: nil
        }
    }

    private static func flag(_ object: NSObject, getter: String, key: String) -> Bool? {
        guard object.responds(to: NSSelectorFromString(getter)) else { return nil }
        return object.value(forKey: key) as? Bool
    }

    private static func rect(_ object: NSObject) -> CGRect? {
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")) else { return nil }
        return (object.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue
    }
}
#endif
