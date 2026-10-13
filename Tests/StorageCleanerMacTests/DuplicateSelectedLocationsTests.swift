import Foundation
import XCTest
@testable import StorageCleanerMac

/// N17 (live test 2026-10-07): Duplicate Files and Similar Photos could not
/// scan only an added folder. Added locations were appended after six
/// default folders that share an 8,000-file / 900-folder / 10-second quota,
/// so they could be skipped entirely. Both pages share `DuplicateFilesStore`.
final class DuplicateSelectedLocationsTests: XCTestCase {
    // MARK: - "Selected only" scope

    @MainActor
    func testSelectedOnlyScopeScansTheAddedFolderAndNoDefaultFolder() async throws {
        let fixture = try makeDirectory("selected-only")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let added = fixture.appendingPathComponent("Added", isDirectory: true)
        try write("same selected payload", to: added.appendingPathComponent("Nested/a.bin"))
        try write("same selected payload", to: added.appendingPathComponent("b.bin"))
        try write("same selected payload", to: added.appendingPathComponent("cloud-only.bin"))

        let recorder = ScanRecorder(allowedRoot: fixture)
        let store = DuplicateFilesStore(
            defaults: try isolatedDefaults(),
            scanOperation: recorder.operation(cloudOnlySuffix: "/cloud-only.bin")
        )
        store.addCustomRoot(added.path)
        store.scanScope = .selectedLocations
        XCTAssertEqual(store.scanScope, .selectedLocations)
        store.startScan()
        await store.waitForCurrentScan()

        let configuration = try XCTUnwrap(recorder.configuration)
        XCTAssertEqual(configuration.scope, .selectedLocations)
        XCTAssertEqual(configuration.roots, [PathSafety.lexicalPath(added.path)])
        XCTAssertNil(configuration.selectedRootsPass, "One pass: the added locations are the whole scope")
        for folder in ["Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures"] {
            XCTAssertFalse(
                configuration.roots.contains { $0.hasSuffix("/" + folder) || $0 == "~/" + folder },
                "A default folder is in the selected-only scope: \(folder)"
            )
        }

        let addedRoot = PathSafety.normalizedPath(added.path)
        let visited = recorder.visitedPaths
        XCTAssertFalse(visited.isEmpty)
        XCTAssertEqual(
            visited.filter { !PathSafety.isContained($0, in: addedRoot, resolvingSymlinks: false) },
            [],
            "The scan touched something outside the added folder"
        )
        let report = try XCTUnwrap(recorder.report)
        XCTAssertEqual(report.coverage.roots.map(\.rootPath), [PathSafety.lexicalPath(added.path)])
        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(report.exactGroups.first?.files.count, 2)
        // 2c: discovery skips the cloud-only placeholder by its flag, never reads it.
        XCTAssertEqual(report.coverage.roots.first?.cloudOnlyFiles, 1)
        XCTAssertFalse(recorder.openedPaths.contains { $0.hasSuffix("/cloud-only.bin") })
        XCTAssertEqual(store.phase, .finished)
        // Review P2-5: one pass, so no coverage row says "scanned first".
        XCTAssertEqual(store.lastScanSelectedRootPaths, [])
    }

    @MainActor
    func testSelectedOnlyNeedsAnAddedLocationAndSaysWhy() async throws {
        let fixture = try makeDirectory("selected-only-empty")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let defaults = try isolatedDefaults()
        let recorder = ScanRecorder(allowedRoot: fixture)
        let store = DuplicateFilesStore(defaults: defaults, scanOperation: recorder.operation())

        XCTAssertFalse(store.canSelectScanScope(.selectedLocations))
        XCTAssertNotNil(store.scopeUnavailableReason(.selectedLocations))
        XCTAssertTrue(store.canSelectScanScope(.userFiles))
        XCTAssertNil(store.scopeUnavailableReason(.userFiles))
        store.scanScope = .selectedLocations
        XCTAssertEqual(store.scanScope, .userFiles, "Without an added location the scope cannot be chosen")

        store.addCustomRoot(fixture.path)
        XCTAssertTrue(store.canSelectScanScope(.selectedLocations))
        XCTAssertNil(store.scopeUnavailableReason(.selectedLocations))
        store.scanScope = .selectedLocations
        XCTAssertEqual(store.scanScope, .selectedLocations)
        XCTAssertTrue(store.canScan)
        XCTAssertNil(store.scanUnavailableReason)

        // Removing the last location keeps the user's choice but refuses to
        // scan, instead of silently falling back to the default folders.
        store.removeCustomRoot(fixture.path)
        XCTAssertEqual(store.scanScope, .selectedLocations)
        XCTAssertFalse(store.canScan)
        XCTAssertFalse(store.isBusy, "Unavailable is not the same as busy")
        let reason = try XCTUnwrap(store.scanUnavailableReason)
        XCTAssertFalse(reason.isEmpty)
        store.startScan()
        await store.waitForCurrentScan()
        XCTAssertNil(recorder.configuration, "No scan may start without an added location")
        XCTAssertTrue(recorder.refusedRoots.isEmpty)
        XCTAssertEqual(store.phase, .idle)

        XCTAssertEqual(DuplicateFilesStore(defaults: defaults).scanScope, .selectedLocations)
    }

    @MainActor
    func testSimilarPhotosAndDuplicatesUseTheSameScopeAndLocations() async throws {
        let fixture = try makeDirectory("shared-scope")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let recorder = ScanRecorder(allowedRoot: fixture)
        let store = DuplicateFilesStore(defaults: try isolatedDefaults(), scanOperation: recorder.operation())
        store.addCustomRoot(fixture.path)
        store.scanScope = .selectedLocations

        store.resultFilter = .all
        store.startScan()
        await store.waitForCurrentScan()
        let duplicatesPage = try XCTUnwrap(recorder.configuration)

        recorder.reset()
        store.resultFilter = .similarImage
        store.startScan()
        await store.waitForCurrentScan()
        let similarPhotosPage = try XCTUnwrap(recorder.configuration)

        XCTAssertEqual(duplicatesPage, similarPhotosPage)
        XCTAssertEqual(similarPhotosPage.roots, [PathSafety.lexicalPath(fixture.path)])
        XCTAssertTrue(similarPhotosPage.candidateRules.contains(.similarImage))
        XCTAssertTrue(recorder.refusedRoots.isEmpty, "Only the fixture may ever be scanned")
    }

    // MARK: - Added locations first, with their own quota

    func testAddedLocationsLeadTheOtherScopesWithTheirOwnQuota() {
        let userFiles = DuplicateFileScanner.Configuration.userFiles(
            customRoots: ["~/Documents/Photos To Sort", "/private/tmp/Extra"],
            externalVolumeRoots: ["/Volumes/Media"],
            excludedPaths: []
        )
        XCTAssertEqual(Array(userFiles.roots.prefix(3)), [
            "~/Documents/Photos To Sort", "/private/tmp/Extra", "/Volumes/Media",
        ])
        XCTAssertEqual(Array(userFiles.roots.dropFirst(3)), [
            "~/Downloads", "~/Desktop", "~/Documents", "~/Movies", "~/Music", "~/Pictures",
        ], "A folder inside Documents no longer swallows Documents, nor the other way round")
        XCTAssertEqual(userFiles.selectedRootsPass, DuplicateFileScanner.SelectedRootsPass(
            rootCount: 3, maxFilesScanned: 8_000, maxDirectoriesScanned: 900, maxScanSeconds: 10
        ))
        XCTAssertEqual(userFiles.maxFilesScanned, 8_000)
        XCTAssertEqual(userFiles.maxDirectoriesScanned, 900)
        XCTAssertEqual(userFiles.maxScanSeconds, 10)

        // A location that contains default folders replaces them.
        let home = DuplicateFileScanner.Configuration.userFiles(customRoots: ["~"], excludedPaths: [])
        XCTAssertEqual(home.roots, ["~"])
        XCTAssertEqual(home.selectedRootsPass?.rootCount, 1)

        let unchanged = DuplicateFileScanner.Configuration.userFiles(excludedPaths: [])
        XCTAssertNil(unchanged.selectedRootsPass, "Without added locations nothing changes")

        let wholeComputer = DuplicateFileScanner.Configuration.wholeComputer(
            userDataRoot: "/Users",
            customRoots: ["/Volumes/Work/Documents", "/Users/Shared/Scans", "/Library/Caches"],
            externalVolumeRoots: ["/Volumes/Media"],
            excludedPaths: [],
            mountedVolumes: [
                DuplicateFileScanner.MountedVolumeMetadata(
                    url: URL(fileURLWithPath: "/Volumes/Work"),
                    isLocal: true, isBrowsable: true, isReadOnly: false, isInternal: false, name: "Work"
                ),
            ]
        )
        XCTAssertEqual(wholeComputer.roots, [
            "/Volumes/Work/Documents", "/Users/Shared/Scans", "/Volumes/Media", "/Users", "/Volumes/Work",
        ])
        XCTAssertEqual(wholeComputer.selectedRootsPass, DuplicateFileScanner.SelectedRootsPass(
            rootCount: 3, maxFilesScanned: 250_000, maxDirectoriesScanned: 30_000, maxScanSeconds: 30
        ))
        XCTAssertTrue(wholeComputer.excludedPaths.contains("/Library"), "Protected roots stay protected")
    }

    func testDefaultFoldersCannotUseUpTheAddedLocationsQuota() throws {
        let fixture = try makeDirectory("quota")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let added = fixture.appendingPathComponent("Added", isDirectory: true)
        let busy = fixture.appendingPathComponent("BusyDefault", isDirectory: true)
        // Deep enough that a shared breadth-first walk would never reach it.
        try write("added duplicate", to: added.appendingPathComponent("a/b/c/one.bin"))
        try write("added duplicate", to: added.appendingPathComponent("d/e/two.bin"))
        for folder in 0..<30 {
            for file in 0..<20 {
                try write("busy \(folder)-\(file)", to: busy.appendingPathComponent("f\(folder)/x\(file).bin"))
            }
        }

        let configuration = DuplicateFileScanner.Configuration(
            roots: [added.path, busy.path],
            excludedPaths: [],
            minimumBytes: 1,
            maxFilesScanned: 25,
            maxDirectoriesScanned: 100,
            maxDepth: 6,
            maxResults: 100,
            maxScanSeconds: 10,
            selectedRootsPass: .init(rootCount: 1, maxFilesScanned: 50, maxDirectoriesScanned: 50, maxScanSeconds: 10)
        )
        let report = DuplicateFileScanner.scanReport(configuration: configuration)

        let addedCoverage = try XCTUnwrap(report.coverage.roots.first)
        XCTAssertEqual(addedCoverage.status, .scanned)
        XCTAssertEqual(addedCoverage.scannedFiles, 2)
        XCTAssertEqual(addedCoverage.scannedDirectories, 6)
        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(
            Set(report.exactGroups.first?.files.map(\.name) ?? []),
            ["one.bin", "two.bin"]
        )
        let busyCoverage = try XCTUnwrap(report.coverage.roots.last)
        XCTAssertEqual(busyCoverage.status, .scanned)
        XCTAssertEqual(busyCoverage.scannedFiles, 25, "The default folders keep their own file quota")
        XCTAssertTrue(report.coverage.reachedFileLimit)
        XCTAssertEqual(report.outcome, .partial)
    }

    func testAnAddedFolderInsideADefaultFolderIsScannedFirstAndCountedOnce() throws {
        let fixture = try makeDirectory("nested")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let outer = fixture.appendingPathComponent("Documents", isDirectory: true)
        let inner = outer.appendingPathComponent("Photos To Sort", isDirectory: true)
        try write("inner duplicate", to: inner.appendingPathComponent("one.jpg"))
        try write("inner duplicate", to: inner.appendingPathComponent("Album/two.jpg"))
        try write("outer only", to: outer.appendingPathComponent("letter.txt"))

        let configuration = DuplicateFileScanner.Configuration(
            roots: [inner.path, outer.path],
            excludedPaths: [],
            minimumBytes: 1,
            maxFilesScanned: 100,
            maxDirectoriesScanned: 100,
            maxDepth: 5,
            maxResults: 100,
            maxScanSeconds: 10,
            selectedRootsPass: .init(rootCount: 1, maxFilesScanned: 100, maxDirectoriesScanned: 100, maxScanSeconds: 10)
        )
        let report = DuplicateFileScanner.scanReport(configuration: configuration)

        XCTAssertEqual(report.coverage.roots.map(\.scannedFiles), [2, 1])
        XCTAssertEqual(report.progress.scannedFiles, 3, "Files under the added folder are counted once")
        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(report.exactGroups.first?.files.count, 2)
        XCTAssertEqual(report.outcome, .complete)
    }

    func testAddedLocationResultsAreKeptWhenTheResultCapIsReached() throws {
        let fixture = try makeDirectory("result-cap")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let added = fixture.appendingPathComponent("Added", isDirectory: true)
        let other = fixture.appendingPathComponent("Other", isDirectory: true)
        try write("small", to: added.appendingPathComponent("one.bin"))
        try write("small", to: added.appendingPathComponent("two.bin"))
        let large = String(repeating: "L", count: 4_096)
        try write(large, to: other.appendingPathComponent("big-one.bin"))
        try write(large, to: other.appendingPathComponent("big-two.bin"))

        let configuration = DuplicateFileScanner.Configuration(
            roots: [added.path, other.path],
            excludedPaths: [],
            minimumBytes: 1,
            maxFilesScanned: 100,
            maxDirectoriesScanned: 100,
            maxDepth: 5,
            maxResults: 2,
            maxScanSeconds: 10,
            candidateRules: [],
            selectedRootsPass: .init(rootCount: 1, maxFilesScanned: 100, maxDirectoriesScanned: 100, maxScanSeconds: 10)
        )
        let report = DuplicateFileScanner.scanReport(configuration: configuration)

        XCTAssertTrue(report.coverage.reachedResultLimit)
        XCTAssertEqual(Set(report.exactGroups.flatMap(\.files).map(\.name)), ["one.bin", "two.bin"])
    }

    func testEachPassResumesWithItsOwnFreshQuota() throws {
        let fixture = try makeDirectory("resume")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let added = fixture.appendingPathComponent("Added", isDirectory: true)
        let other = fixture.appendingPathComponent("Other", isDirectory: true)
        var expected = Set<String>()
        for index in 0..<5 {
            let url = added.appendingPathComponent("added-\(index).bin")
            try write("resumable payload", to: url)
            expected.insert(PathSafety.normalizedPath(url.path))
        }
        for index in 0..<3 {
            let url = other.appendingPathComponent("other-\(index).bin")
            try write("resumable payload", to: url)
            expected.insert(PathSafety.normalizedPath(url.path))
        }
        let configuration = DuplicateFileScanner.Configuration(
            roots: [added.path, other.path],
            excludedPaths: [],
            minimumBytes: 1,
            maxFilesScanned: 2,
            maxDirectoriesScanned: 100,
            maxDepth: 5,
            maxResults: 100,
            maxScanSeconds: 10,
            selectedRootsPass: .init(rootCount: 1, maxFilesScanned: 2, maxDirectoriesScanned: 100, maxScanSeconds: 10)
        )

        var resumeData: Data?
        var cumulative = [[Int]]()
        var completed: DuplicateFileScanReport?
        for _ in 0..<5 {
            let box = ResumeBox()
            let report = DuplicateFileScanner.scanReport(
                configuration: configuration,
                resumeIndexData: resumeData,
                resumeIndex: { box.set($0) }
            )
            cumulative.append(report.coverage.roots.map(\.scannedFiles))
            if report.outcome == .complete {
                completed = report
                break
            }
            XCTAssertTrue(report.coverage.reachedFileLimit)
            resumeData = try XCTUnwrap(box.get())
        }

        // Each run gives the added folder 2 files and the other folder 2 files.
        XCTAssertEqual(cumulative, [[2, 2], [4, 3], [5, 3]])
        let report = try XCTUnwrap(completed)
        let files = try XCTUnwrap(report.exactGroups.first).files.map(\.path)
        XCTAssertEqual(files.count, expected.count)
        XCTAssertEqual(Set(files), expected)
    }

    // MARK: - Page wiring (both pages render DuplicateFilesView)

    func testScopeControlDisablesSelectedOnlyAndSaysWhyOnScreenAndToVoiceOver() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(source.range(of: "private var duplicateScanAccessory"))
        let end = try XCTUnwrap(source.range(of: "private var duplicateLocationButtons", range: start.upperBound..<source.endIndex))
        let accessory = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertTrue(accessory.contains("let unavailableReason = workspace.scopeUnavailableReason(scope)"))
        XCTAssertTrue(accessory.contains(".disabled(unavailableReason != nil)"))
        XCTAssertTrue(accessory.contains(".help(unavailableReason ?? scopeDetail(scope))"))
        XCTAssertTrue(accessory.contains(".accessibilityHint(unavailableReason ?? scopeDetail(scope))"))
        XCTAssertTrue(accessory.contains("if let reason = workspace.scopeUnavailableReason(.selectedLocations)"))

        let filters = try XCTUnwrap(source.range(of: "private var duplicateFilterControls"))
        let filtersEnd = try XCTUnwrap(source.range(of: "private var duplicateScanAccessory", range: filters.upperBound..<source.endIndex))
        let menu = String(source[filters.lowerBound..<filtersEnd.lowerBound])
        XCTAssertTrue(menu.contains(".disabled(!workspace.canSelectScanScope(scope))"))
        XCTAssertTrue(source.contains(".help(workspace.scanUnavailableReason ?? \"\")"))
        // Unavailable is not busy: the hourglass only means a running scan.
        XCTAssertTrue(source.contains("if workspace.isBusy {\n            return \"hourglass\""))
        XCTAssertTrue(source.contains("只扫描你添加的文件夹和外接卷，不碰默认位置。"))
    }

    // MARK: - Helpers

    private func makeDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateSelectedLocations-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    /// An absolute-path suite keeps its plist in a temporary folder; a plain
    /// suite name would leave a file in the real ~/Library/Preferences.
    // MARK: - Review P2-6: the resume index is injected

    @MainActor
    func testAScanReadsAndWritesOnlyTheResumeIndexItIsGiven() async throws {
        let fixture = try makeDirectory("resume-index")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let resumeStore = DuplicateFileResumeIndexStore(
            fileURL: fixture.appendingPathComponent("state/resume-index.json")
        )
        try resumeStore.save(Data("earlier scan".utf8))
        let seen = ResumeBox()
        let store = DuplicateFilesStore(
            defaults: try isolatedDefaults(),
            scanOperation: { _, resumeIndexData, _, resumeIndex, _ in
                seen.set(resumeIndexData)
                resumeIndex(Data("this scan".utf8))
                return Self.emptyReport(outcome: .complete)
            },
            resumeIndexStore: resumeStore
        )
        store.startScan()
        await store.waitForCurrentScan()

        XCTAssertEqual(seen.get(), Data("earlier scan".utf8), "The scan resumed from the given index")
        XCTAssertEqual(resumeStore.load(), Data("this scan".utf8), "and saved its place there")

        // A store with its own defaults and no index passed gets none.
        let unseen = ResumeBox()
        let isolated = DuplicateFilesStore(
            defaults: try isolatedDefaults(),
            scanOperation: { _, resumeIndexData, _, resumeIndex, _ in
                unseen.set(resumeIndexData)
                resumeIndex(Data("dropped".utf8))
                return Self.emptyReport(outcome: .complete)
            }
        )
        isolated.startScan()
        await isolated.waitForCurrentScan()
        XCTAssertNil(unseen.get())
        XCTAssertEqual(resumeStore.load(), Data("this scan".utf8))
    }

    /// Review P2-5: only a scan with a lead pass for added locations marks
    /// them "scanned first, counted on their own".
    @MainActor
    func testOnlyALeadPassMarksAddedLocationsAsScannedFirst() async throws {
        let fixture = try makeDirectory("lead-pass")
        defer { try? FileManager.default.removeItem(at: fixture) }
        let added = fixture.appendingPathComponent("Added", isDirectory: true)
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        // The operation scans nothing; only the configuration the store
        // built and remembers matters here.
        let store = DuplicateFilesStore(
            defaults: try isolatedDefaults(),
            scanOperation: { _, _, _, _, _ in Self.emptyReport(outcome: .complete) }
        )
        store.addCustomRoot(added.path)

        store.scanScope = .userFiles
        store.startScan()
        await store.waitForCurrentScan()
        XCTAssertEqual(store.lastScanSelectedRootPaths, [PathSafety.lexicalPath(added.path)])

        store.scanScope = .selectedLocations
        store.startScan()
        await store.waitForCurrentScan()
        XCTAssertEqual(store.lastScanSelectedRootPaths, [])
    }

    private static func emptyReport(outcome: DuplicateFileScanOutcome) -> DuplicateFileScanReport {
        DuplicateFileScanReport(
            exactGroups: [],
            candidates: [],
            coverage: DuplicateFileScanCoverage(
                roots: [],
                reachedTimeLimit: false,
                reachedFileLimit: false,
                reachedDirectoryLimit: false,
                reachedResultLimit: false
            ),
            progress: .initial,
            outcome: outcome
        )
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let folder = try makeDirectory("defaults")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try XCTUnwrap(TestPreferenceDomain.open(suiteName: folder.appendingPathComponent("suite").path))
    }
}

/// Runs the real scanner for the configuration the store builds, recording
/// every path the scan reports. It never calls the resume handler, and the
/// stores here use isolated defaults, which give them no resume index at all
/// (review P2-6), so the app's real resume index is neither read nor written.
private final class ScanRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private let allowedRoot: String
    private var storedConfiguration: DuplicateFileScanner.Configuration?
    private var storedReport: DuplicateFileScanReport?
    private var visited: [String] = []
    private var opened: [String] = []
    private var refused: [String] = []

    /// Only configurations whose every root lies inside `allowedRoot` are
    /// scanned; anything else (for example the real default folders) is
    /// recorded and answered with an empty cancelled report.
    init(allowedRoot: URL) {
        self.allowedRoot = PathSafety.normalizedPath(allowedRoot.path)
    }

    var configuration: DuplicateFileScanner.Configuration? { lock.withLock { storedConfiguration } }
    var report: DuplicateFileScanReport? { lock.withLock { storedReport } }
    var visitedPaths: [String] { lock.withLock { visited } }
    var openedPaths: [String] { lock.withLock { opened } }
    var refusedRoots: [String] { lock.withLock { refused } }

    func reset() {
        lock.withLock {
            storedConfiguration = nil
            storedReport = nil
            visited = []
            opened = []
            refused = []
        }
    }

    func operation(cloudOnlySuffix: String? = nil) -> DuplicateFilesStore.ScanOperation {
        { [self] configuration, _, control, _, _ in
            lock.withLock { storedConfiguration = configuration }
            let outside = configuration.roots.filter {
                !PathSafety.isContained(PathSafety.normalizedPath($0), in: allowedRoot, resolvingSymlinks: false)
            }
            guard outside.isEmpty, !configuration.roots.isEmpty else {
                lock.withLock { refused = outside }
                return DuplicateFileScanReport(
                    exactGroups: [],
                    candidates: [],
                    coverage: DuplicateFileScanCoverage(
                        roots: [],
                        reachedTimeLimit: false,
                        reachedFileLimit: false,
                        reachedDirectoryLimit: false,
                        reachedResultLimit: false
                    ),
                    progress: .initial,
                    outcome: .cancelled
                )
            }
            let report = DuplicateFileScanner.scanReport(
                configuration: configuration,
                resumeIndexData: nil,
                control: control,
                resumeIndex: nil,
                progress: { [self] progress in
                    guard let path = progress.currentPath else { return }
                    lock.withLock {
                        visited.append(path)
                        if progress.phase == .fingerprinting || progress.phase == .hashing {
                            opened.append(path)
                        }
                    }
                },
                isCloudPlaceholder: { path in
                    cloudOnlySuffix.map { path.hasSuffix($0) } ?? false
                }
            )
            lock.withLock { storedReport = report }
            return report
        }
    }
}

private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func set(_ value: Data?) { lock.withLock { if let value { data = value } } }
    func get() -> Data? { lock.withLock { data } }
}
