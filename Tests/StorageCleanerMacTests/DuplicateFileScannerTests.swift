import AppKit
import Darwin
import XCTest
@testable import StorageCleanerMac

final class DuplicateFileScannerTests: XCTestCase {
    func testDifferentNamesWithSameContentShareVerifiedGroupAndSavingsRemainUnknown() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("verified duplicate payload".utf8)
        try payload.write(to: root.appendingPathComponent("first-name.bin"))
        try payload.write(to: root.appendingPathComponent("renamed-copy.data"))

        let groups = DuplicateFileScanner.scanGroups(configuration: configuration(root: root))

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].files.map(\.name)), ["first-name.bin", "renamed-copy.data"])
        XCTAssertEqual(groups[0].contentSizeBytes, Int64(payload.count))
        XCTAssertEqual(groups[0].matchKind, .logicalContentSHA256)
        XCTAssertEqual(groups[0].relationship, .independent)
        XCTAssertNil(groups[0].estimatedPhysicalReclaimableBytes)
    }

    func testSameNameAndSizeWithMiddleDifferenceIsRejectedByFullHash() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let firstFolder = root.appendingPathComponent("first", isDirectory: true)
        let secondFolder = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondFolder, withIntermediateDirectories: true)

        let blockSize = 64 * 1024
        let head = Data(repeating: 0x11, count: blockSize)
        let tail = Data(repeating: 0x33, count: blockSize)
        var first = head
        first.append(Data(repeating: 0x22, count: blockSize))
        first.append(tail)
        var second = head
        second.append(Data(repeating: 0x44, count: blockSize))
        second.append(tail)

        try first.write(to: firstFolder.appendingPathComponent("archive.bin"))
        try second.write(to: secondFolder.appendingPathComponent("archive.bin"))

        XCTAssertEqual(
            DuplicateFileScanner.scanGroups(configuration: configuration(root: root)),
            []
        )
    }

    func testIndependentMetadataRulesRemainManualCandidatesWhenContentsDiffer() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("AAAA".utf8).write(to: first.appendingPathComponent("report.pdf"))
        try Data("BBBB".utf8).write(to: second.appendingPathComponent("report.pdf"))

        let report = DuplicateFileScanner.scanReport(configuration: configuration(root: root))

        XCTAssertEqual(report.exactGroups, [])
        XCTAssertEqual(Set(report.candidates.map(\.rule)), [.sameName, .sameSize, .sameType])
        for candidate in report.candidates {
            XCTAssertEqual(Set(candidate.files.map(\.path)), [
                first.appendingPathComponent("report.pdf").path,
                second.appendingPathComponent("report.pdf").path
            ])
        }
    }

    func testCandidateRuleSelectionDoesNotAffectExactContentVerification() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first.bin")
        let second = root.appendingPathComponent("second.data")
        try Data("same content".utf8).write(to: first)
        try Data("same content".utf8).write(to: second)

        var scanConfiguration = configuration(root: root)
        scanConfiguration.candidateRules = []
        let report = DuplicateFileScanner.scanReport(configuration: scanConfiguration)

        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertTrue(report.candidates.isEmpty)
    }

    func testMetadataCandidatesCollapseExactMembersWithoutHidingDistinctFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let exactA = root.appendingPathComponent("exact-a.bin")
        let exactB = root.appendingPathComponent("exact-b.bin")
        let unrelated = root.appendingPathComponent("unrelated.bin")
        let exactPayload = Data(repeating: 0x41, count: 32)
        try exactPayload.write(to: exactA)
        try exactPayload.write(to: exactB)
        try Data(repeating: 0x42, count: exactPayload.count).write(to: unrelated)

        var scanConfiguration = configuration(root: root)
        scanConfiguration.candidateRules = [.sameSize]
        let report = DuplicateFileScanner.scanReport(configuration: scanConfiguration)

        XCTAssertEqual(report.exactGroups.count, 1)
        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(candidate.rule, .sameSize)
        XCTAssertEqual(candidate.files.map(\.path), [exactA.path, unrelated.path])
        XCTAssertFalse(candidate.files.contains(where: { $0.path == exactB.path }))
    }

    func testMetadataRulesCanBeSelectedIndependently() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("first", isDirectory: true)
        let second = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("AAAA".utf8).write(to: first.appendingPathComponent("report.pdf"))
        try Data("BBBB".utf8).write(to: second.appendingPathComponent("report.pdf"))

        for rule in [
            DuplicateFileCandidateGroup.Rule.sameName,
            .sameSize,
            .sameType,
        ] {
            var scanConfiguration = configuration(root: root)
            scanConfiguration.candidateRules = [rule]
            let report = DuplicateFileScanner.scanReport(configuration: scanConfiguration)
            XCTAssertEqual(report.candidates.map(\.rule), [rule])
        }
    }

    func testSimilarImageRuleUsesLocalFingerprintAndExcludesDifferentArtwork() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = root.appendingPathComponent("same-artwork.png")
        let second = root.appendingPathComponent("same-artwork.jpg")
        let different = root.appendingPathComponent("different-artwork.png")
        let matchingBitmap = try imageFixture(
            primary: NSColor(deviceRed: 0.10, green: 0.30, blue: 0.90, alpha: 1),
            secondary: NSColor(deviceWhite: 1, alpha: 1)
        )
        try write(matchingBitmap, as: .png, to: first)
        try write(matchingBitmap, as: .jpeg, to: second)
        try write(
            imageFixture(
                primary: NSColor(deviceRed: 0.90, green: 0.08, blue: 0.06, alpha: 1),
                secondary: NSColor(deviceWhite: 0, alpha: 1)
            ),
            as: .png,
            to: different
        )

        var scanConfiguration = configuration(root: root)
        scanConfiguration.candidateRules = [.similarImage]
        let report = DuplicateFileScanner.scanReport(configuration: scanConfiguration)

        XCTAssertTrue(report.exactGroups.isEmpty)
        let candidate = try XCTUnwrap(report.candidates.first)
        XCTAssertEqual(report.candidates.count, 1)
        XCTAssertEqual(candidate.rule, .similarImage)
        XCTAssertEqual(Set(candidate.files.map(\.path)), [first.path, second.path])
        XCTAssertFalse(candidate.files.contains(where: { $0.path == different.path }))
    }

    func testHardLinksDoNotCountAsSeparateDuplicates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        let alias = root.appendingPathComponent("hard-link.bin")
        try Data("one physical file".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: alias)

        XCTAssertEqual(
            DuplicateFileScanner.scanGroups(configuration: configuration(root: root)),
            []
        )
    }

    func testAPFSCloneIsLogicalDuplicateWithoutClaimingPhysicalSavings() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appendingPathComponent("original.bin")
        let clone = root.appendingPathComponent("clone.bin")
        let payload = Data("copy-on-write duplicate payload".utf8)
        try payload.write(to: original)

        guard clonefile(original.path, clone.path, 0) == 0 else {
            let error = errno
            if error == ENOTSUP {
                throw XCTSkip("Filesystem does not support clonefile")
            }
            throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
        }

        var originalMetadata = stat()
        var cloneMetadata = stat()
        XCTAssertEqual(original.path.withCString { Darwin.lstat($0, &originalMetadata) }, 0)
        XCTAssertEqual(clone.path.withCString { Darwin.lstat($0, &cloneMetadata) }, 0)
        XCTAssertNotEqual(originalMetadata.st_ino, cloneMetadata.st_ino)
        XCTAssertEqual(try Data(contentsOf: clone), payload)

        let groups = DuplicateFileScanner.scanGroups(configuration: configuration(root: root))

        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(group.files.map(\.path)), [original.path, clone.path])
        XCTAssertEqual(group.contentSizeBytes, Int64(payload.count))
        XCTAssertEqual(group.matchKind, .logicalContentSHA256)
        XCTAssertEqual(group.relationship, .apfsClone)
        XCTAssertNil(group.estimatedPhysicalReclaimableBytes)
    }

    func testSymlinksPackagesAndExcludedPathsStaySkipped() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let realFile = root.appendingPathComponent("real.bin")
        try Data("symlink payload".utf8).write(to: realFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("alias.bin"),
            withDestinationURL: realFile
        )

        let package = root.appendingPathComponent("Hidden.app", isDirectory: true)
        let packageFiles = package.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: packageFiles, withIntermediateDirectories: true)
        try Data("package duplicate".utf8).write(to: packageFiles.appendingPathComponent("one.bin"))
        try Data("package duplicate".utf8).write(to: packageFiles.appendingPathComponent("two.bin"))
        XCTAssertEqual(try package.resourceValues(forKeys: [.isPackageKey]).isPackage, true)

        let excluded = root.appendingPathComponent("Excluded", isDirectory: true)
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: true)
        try Data("excluded duplicate".utf8).write(to: excluded.appendingPathComponent("one.bin"))
        try Data("excluded duplicate".utf8).write(to: excluded.appendingPathComponent("two.bin"))

        XCTAssertEqual(
            DuplicateFileScanner.scanGroups(
                configuration: configuration(root: root, excludedPaths: [excluded.path])
            ),
            []
        )
    }

    func testSymlinkRootIsReportedAndNeverTraversed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("selected-link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("symlink-root payload".utf8)
            .write(to: target.appendingPathComponent("one.bin"))
        try Data("symlink-root payload".utf8)
            .write(to: target.appendingPathComponent("two.bin"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let report = DuplicateFileScanner.scanReport(
            configuration: configuration(root: link)
        )

        XCTAssertTrue(report.exactGroups.isEmpty)
        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.coverage.roots.count, 1)
        XCTAssertEqual(report.coverage.roots[0].status, .skipped)
        XCTAssertEqual(report.coverage.roots[0].skipReason, .symbolicLink)
        XCTAssertTrue(report.coverage.roots[0].rootPath.hasSuffix("/selected-link"))
    }

    @MainActor
    func testDuplicateWorkspacePreservesSymlinkRootForScannerBoundary() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target", isDirectory: true)
        let link = root.appendingPathComponent("selected-link", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let suiteName = "duplicate-symlink-root-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = DuplicateFilesStore(defaults: defaults)

        store.addCustomRoot(link.path)

        XCTAssertEqual(store.customRootPaths, [PathSafety.lexicalPath(link.path)])
        XCTAssertNotEqual(store.customRootPaths.first, PathSafety.normalizedPath(link.path))
        store.removeCustomRoot(link.path)
        XCTAssertTrue(store.customRootPaths.isEmpty)
    }

    func testUnreadableCandidateFailsClosed() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 fixtures") }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let readable = root.appendingPathComponent("readable.bin")
        let unreadable = root.appendingPathComponent("unreadable.bin")
        let payload = Data("same content".utf8)
        try payload.write(to: readable)
        try payload.write(to: unreadable)
        XCTAssertEqual(Darwin.chmod(unreadable.path, 0), 0)
        defer { _ = Darwin.chmod(unreadable.path, S_IRUSR | S_IWUSR) }

        let report = DuplicateFileScanner.scanReport(configuration: configuration(root: root))

        XCTAssertEqual(report.exactGroups, [])
        XCTAssertEqual(report.outcome, .partial)
        XCTAssertTrue(
            report.coverage.roots[0].skippedPaths.contains {
                $0.path == unreadable.path && $0.reason == .permissionDenied
            }
        )
    }

    func testPermissionDeniedRootDoesNotStopOtherRoots() throws {
        guard geteuid() != 0 else { throw XCTSkip("Root can read mode-000 fixtures") }

        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let denied = root.appendingPathComponent("Denied", isDirectory: true)
        let readable = root.appendingPathComponent("Readable", isDirectory: true)
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: readable, withIntermediateDirectories: true)
        try Data("same".utf8).write(to: readable.appendingPathComponent("one.bin"))
        try Data("same".utf8).write(to: readable.appendingPathComponent("two.bin"))
        XCTAssertEqual(Darwin.chmod(denied.path, 0), 0)
        defer { _ = Darwin.chmod(denied.path, S_IRUSR | S_IWUSR | S_IXUSR) }

        let report = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [denied.path, readable.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxDirectoriesScanned: 100,
                maxDepth: 5,
                maxResults: 100,
                maxScanSeconds: 5
            )
        )

        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(report.coverage.roots[0].skipReason, .permissionDenied)
        XCTAssertEqual(report.coverage.roots[1].status, .scanned)
        XCTAssertEqual(report.outcome, .partial)
    }

    func testFileChangingDuringContentReadFailsClosed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let changing = root.appendingPathComponent("changing.bin")
        let stable = root.appendingPathComponent("stable.bin")
        let payload = Data(repeating: 0x7f, count: 8 * 1024 * 1024)
        try payload.write(to: changing)
        try payload.write(to: stable)

        let descriptor = Darwin.open(changing.path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let control = DuplicateMutationControl()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            var byte: UInt8 = 0x7f
            _ = Darwin.pwrite(descriptor, &byte, 1, 0)
            started.signal()
            while !control.shouldStop {
                _ = Darwin.pwrite(descriptor, &byte, 1, 0)
            }
            Darwin.close(descriptor)
            finished.signal()
        }

        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        let groups = DuplicateFileScanner.scanGroups(configuration: configuration(root: root))
        control.stop()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)

        XCTAssertEqual(groups, [])
    }

    func testPausedScanDoesNotConsumeTimeBudgetAndResumesWithRealProgressTotals() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data(repeating: 0x42, count: 64 * 1024)
        try payload.write(to: root.appendingPathComponent("one.bin"))
        try payload.write(to: root.appendingPathComponent("two.bin"))

        let control = DuplicateFileScanControl()
        control.pause()
        let paused = expectation(description: "scanner reached paused checkpoint")
        let finished = expectation(description: "scanner finished after resume")
        let reportBox = DuplicateReportBox()
        let scanConfiguration: DuplicateFileScanner.Configuration = {
            var value = configuration(root: root)
            value.maxScanSeconds = 0.4
            return value
        }()

        DispatchQueue.global(qos: .userInitiated).async {
            let report = DuplicateFileScanner.scanReport(
                configuration: scanConfiguration,
                control: control
            ) { progress in
                if progress.phase == .paused {
                    paused.fulfill()
                }
            }
            reportBox.set(report)
            finished.fulfill()
        }

        wait(for: [paused], timeout: 1)
        XCTAssertNil(reportBox.get())
        Thread.sleep(forTimeInterval: 0.65)
        control.resume()
        wait(for: [finished], timeout: 5)

        let report = try XCTUnwrap(reportBox.get())
        XCTAssertEqual(report.outcome, .complete)
        XCTAssertFalse(report.coverage.reachedTimeLimit)
        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(report.progress.scannedFiles, 2)
        XCTAssertEqual(report.progress.scannedBytes, Int64(payload.count * 2))
        XCTAssertEqual(report.progress.hashedFiles, 2)
        XCTAssertEqual(report.progress.hashedBytes, Int64(payload.count * 2))
        XCTAssertEqual(report.progress.estimatedTotalFiles, 2)
        XCTAssertEqual(report.progress.estimatedTotalBytes, Int64(payload.count * 2))
    }

    func testCancelDuringHashingReturnsCancelledPartialWork() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data(repeating: 0x5a, count: 4 * 1024 * 1024)
        try payload.write(to: root.appendingPathComponent("one.bin"))
        try payload.write(to: root.appendingPathComponent("two.bin"))
        let control = DuplicateFileScanControl()

        let report = DuplicateFileScanner.scanReport(
            configuration: configuration(root: root),
            control: control
        ) { progress in
            if progress.phase == .hashing, progress.hashedBytes > 0 {
                control.cancel()
            }
        }

        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertTrue(control.isCancelled)
        XCTAssertGreaterThan(report.progress.hashedBytes, 0)
        XCTAssertLessThan(report.progress.hashedBytes, Int64(payload.count * 2))
        XCTAssertEqual(report.exactGroups, [])
    }

    func testCoverageRecordsPackageAndPseudoFilesystemSkips() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Archive.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)

        let report = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [package.path, "/dev"],
                excludedPaths: [],
                minimumBytes: 1,
                maxScanSeconds: 5
            )
        )

        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.coverage.roots.map(\.status), [.skipped, .skipped])
        XCTAssertEqual(report.coverage.roots.map(\.skipReason), [.package, .pseudoFilesystem])
    }

    func testCoverageMarksFileDirectoryTimeAndResultLimits() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("same".utf8).write(to: root.appendingPathComponent("one.bin"))
        try Data("same".utf8).write(to: root.appendingPathComponent("two.bin"))

        let fileLimited = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 1,
                maxDirectoriesScanned: 100,
                maxResults: 100,
                maxScanSeconds: 5
            )
        )
        XCTAssertTrue(fileLimited.coverage.reachedFileLimit)
        XCTAssertEqual(fileLimited.outcome, .partial)

        let directoryLimited = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxDirectoriesScanned: 0,
                maxResults: 100,
                maxScanSeconds: 5
            )
        )
        XCTAssertTrue(directoryLimited.coverage.reachedDirectoryLimit)

        let timeLimited = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxDirectoriesScanned: 100,
                maxResults: 100,
                maxScanSeconds: 0
            )
        )
        XCTAssertTrue(timeLimited.coverage.reachedTimeLimit)

        let resultLimited = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxDirectoriesScanned: 100,
                maxResults: 1,
                maxScanSeconds: 5
            )
        )
        XCTAssertTrue(resultLimited.coverage.reachedResultLimit)
        XCTAssertEqual(resultLimited.exactGroups, [])
    }

    func testDefaultRootsMergeCustomAndExplicitExternalVolumes() {
        let configuration = DuplicateFileScanner.Configuration.userFiles(
            customRoots: ["~/Custom", "~/Downloads"],
            externalVolumeRoots: ["/Volumes/Media"],
            excludedPaths: []
        )

        XCTAssertEqual(configuration.roots, [
            "~/Downloads",
            "~/Desktop",
            "~/Documents",
            "~/Movies",
            "~/Music",
            "~/Pictures",
            "~/Custom",
            "/Volumes/Media"
        ])
    }

    func testScopeLabelsAndProductionBoundsMatchActualCoverage() {
        let defaults = UserDefaults.standard
        let originalLanguage = defaults.string(forKey: L10n.languageDefaultsKey)
        defer {
            if let originalLanguage {
                defaults.set(originalLanguage, forKey: L10n.languageDefaultsKey)
            } else {
                defaults.removeObject(forKey: L10n.languageDefaultsKey)
            }
        }

        defaults.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(DuplicateFileScanScope.userFiles.title, "用户文件")
        XCTAssertEqual(DuplicateFileScanScope.wholeComputer.title, "用户数据区")
        XCTAssertFalse(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("20 MiB"))
        XCTAssertTrue(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("隐藏文件"))
        XCTAssertTrue(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("本地可浏览数据卷"))
        XCTAssertTrue(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("网络卷"))

        defaults.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)
        XCTAssertEqual(DuplicateFileScanScope.userFiles.title, "User Files")
        XCTAssertEqual(DuplicateFileScanScope.wholeComputer.title, "User Data Areas")
        XCTAssertFalse(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("20 MiB"))
        XCTAssertTrue(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("hidden files"))
        XCTAssertTrue(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("local browsable data volumes"))
        XCTAssertTrue(DuplicateFileScanScope.wholeComputer.coverageDescription.contains("network volumes"))
        XCTAssertEqual(DuplicateFileScanScope.allCases.map(\.rawValue), ["userFiles", "wholeComputer"])

        let userFiles = DuplicateFileScanner.Configuration.userFiles(excludedPaths: [])
        XCTAssertEqual(userFiles.minimumBytes, 0)
        XCTAssertEqual(userFiles.maxFilesScanned, 8_000)
        XCTAssertEqual(userFiles.maxResults, 120)
        XCTAssertEqual(userFiles.maxScanSeconds, 10)

        let allUserFiles = DuplicateFileScanner.Configuration.wholeComputer(
            userDataRoot: "/Users",
            excludedPaths: []
        )
        XCTAssertEqual(allUserFiles.minimumBytes, 0)
        XCTAssertEqual(allUserFiles.maxFilesScanned, 250_000)
        XCTAssertEqual(allUserFiles.maxResults, 200)
        XCTAssertEqual(allUserFiles.maxScanSeconds, 30)
    }

    func testProductionUserFilesConfigurationFindsSmallExactDuplicates() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let oneKiB = Data(repeating: 0x11, count: 1 * 1024)
        let oneMiB = Data(repeating: 0x22, count: 1 * 1024 * 1024)
        try oneKiB.write(to: root.appendingPathComponent("one-kib-a.bin"))
        try oneKiB.write(to: root.appendingPathComponent("one-kib-b.bin"))
        try oneMiB.write(to: root.appendingPathComponent("one-mib-a.bin"))
        try oneMiB.write(to: root.appendingPathComponent("one-mib-b.bin"))

        var configuration = DuplicateFileScanner.Configuration.userFiles(
            customRoots: [root.path],
            excludedPaths: []
        )
        // Keep the factory's production thresholds while isolating this test
        // to its temporary root rather than the user's default folders.
        configuration.roots = [root.path]

        let groups = DuplicateFileScanner.scanGroups(configuration: configuration)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(
            Set(groups.map(\.contentSizeBytes)),
            Set([Int64(oneKiB.count), Int64(oneMiB.count)])
        )
        XCTAssertTrue(groups.allSatisfy { $0.matchKind == .logicalContentSHA256 })
    }

    func testWholeComputerScopeOnlyUsesUserDataAndExplicitVolumeRoots() {
        let configuration = DuplicateFileScanner.Configuration.wholeComputer(
            userDataRoot: "/Users",
            customRoots: ["/System", "/Volumes/Custom"],
            externalVolumeRoots: ["/Volumes/Media", "/Applications"],
            excludedPaths: [],
            mountedVolumes: []
        )

        XCTAssertEqual(configuration.roots, ["/Users", "/Volumes/Custom", "/Volumes/Media"])
        for protectedRoot in [
            "/Applications",
            "/System",
            "/Library",
            "/private",
            "/usr"
        ] {
            XCTAssertTrue(
                configuration.excludedPaths.contains(protectedRoot),
                "Missing protected root: \(protectedRoot); exclusions: \(configuration.excludedPaths)"
            )
        }
    }

    func testWholeComputerAutomaticallyIncludesMountedLocalDataVolumesAndDeduplicatesNestedRoots() {
        let configuration = DuplicateFileScanner.Configuration.wholeComputer(
            userDataRoot: "/Users",
            customRoots: ["/Volumes/Work/Documents"],
            externalVolumeRoots: ["/Volumes/Media"],
            excludedPaths: [],
            mountedVolumes: [
                DuplicateFileScanner.MountedVolumeMetadata(
                    url: URL(fileURLWithPath: "/Volumes/Work"),
                    isLocal: true,
                    isBrowsable: true,
                    isReadOnly: false,
                    isInternal: false,
                    name: "Work"
                ),
                DuplicateFileScanner.MountedVolumeMetadata(
                    url: URL(fileURLWithPath: "/Volumes/Work/Child"),
                    isLocal: true,
                    isBrowsable: true,
                    isReadOnly: false,
                    isInternal: false,
                    name: "Child"
                )
            ]
        )

        XCTAssertEqual(configuration.roots, ["/Users", "/Volumes/Work", "/Volumes/Media"])
    }

    func testWholeComputerProtectsTopLevelSystemSubpathsInsideAutomaticAndExplicitVolumes() {
        let configuration = DuplicateFileScanner.Configuration.wholeComputer(
            userDataRoot: "/Users",
            customRoots: ["/Volumes/Explicit"],
            excludedPaths: [],
            mountedVolumes: [
                DuplicateFileScanner.MountedVolumeMetadata(
                    url: URL(fileURLWithPath: "/Volumes/Automatic"),
                    isLocal: true,
                    isBrowsable: true,
                    isReadOnly: false,
                    isInternal: false,
                    name: "Automatic"
                )
            ]
        )

        let protectedNames = [
            "Applications", "System", "Library", "private", "usr", "bin", "sbin", "opt", "cores"
        ]
        for volumeRoot in ["/Volumes/Automatic", "/Volumes/Explicit"] {
            for name in protectedNames {
                let protectedPath = "\(volumeRoot)/\(name)"
                XCTAssertTrue(
                    ScanExclusionService.isExcluded(
                        protectedPath + "/kernel",
                        excludedPaths: configuration.excludedPaths
                    ),
                    "Missing protected subpath exclusion: \(protectedPath)"
                )
            }
            XCTAssertFalse(
                ScanExclusionService.isExcluded(
                    "\(volumeRoot)/Documents",
                    excludedPaths: configuration.excludedPaths
                )
            )
        }
    }

    func testWholeComputerExcludesSystemNetworkUnreadableAndInvalidMountedVolumes() {
        let metadata = [
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(fileURLWithPath: "/"),
                isLocal: true,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: true,
                name: "Macintosh HD"
            ),
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(fileURLWithPath: "/System/Volumes/Data"),
                isLocal: true,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: true,
                name: "Macintosh HD - Data"
            ),
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(fileURLWithPath: "/Volumes/Recovery"),
                isLocal: true,
                isBrowsable: true,
                isReadOnly: true,
                isInternal: true,
                name: "Recovery"
            ),
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(fileURLWithPath: "/Volumes/Network"),
                isLocal: false,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: false,
                name: "Network"
            ),
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(fileURLWithPath: "/Volumes/Hidden"),
                isLocal: true,
                isBrowsable: false,
                isReadOnly: false,
                isInternal: false,
                name: "Hidden"
            ),
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(fileURLWithPath: "/Volumes/ReadOnlySystem"),
                isLocal: true,
                isBrowsable: true,
                isReadOnly: true,
                isInternal: true,
                name: "ReadOnlySystem"
            ),
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(fileURLWithPath: "relative-volume"),
                isLocal: true,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: false,
                name: "Invalid"
            ),
            DuplicateFileScanner.MountedVolumeMetadata(
                url: URL(string: "https://example.com")!,
                isLocal: true,
                isBrowsable: true,
                isReadOnly: false,
                isInternal: false,
                name: "Invalid URL"
            )
        ]

        let configuration = DuplicateFileScanner.Configuration.wholeComputer(
            userDataRoot: "/Users",
            excludedPaths: [],
            mountedVolumes: metadata
        )

        XCTAssertEqual(configuration.roots, ["/Users"])
    }

    func testWholeComputerTraversalSkipsCriticalTopLevelDirectories() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = root.appendingPathComponent("System", isDirectory: true)
        let userData = root.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        for name in ["one.bin", "two.bin"] {
            try Data("protected duplicate".utf8).write(to: protected.appendingPathComponent(name))
            try Data("user duplicate".utf8).write(to: userData.appendingPathComponent(name))
        }
        let report = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                scope: .wholeComputer,
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxDirectoriesScanned: 100,
                maxDepth: 5,
                maxResults: 100,
                maxScanSeconds: 5
            )
        )

        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(
            Set(report.exactGroups[0].files.map(\.path)),
            Set(["one.bin", "two.bin"].map { userData.appendingPathComponent($0).path })
        )
        XCTAssertTrue(report.coverage.roots[0].skippedPaths.contains {
            $0.path == protected.path && $0.reason == .policyExcluded
        })
    }

    func testTraversalSkipsCacheMountsBeforeDescending() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cacheMount = root.appendingPathComponent("Caches", isDirectory: true)
        let userData = root.appendingPathComponent("UserData", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheMount, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData, withIntermediateDirectories: true)
        for name in ["one.bin", "two.bin"] {
            try Data("cache duplicate".utf8).write(to: cacheMount.appendingPathComponent(name))
            try Data("user duplicate".utf8).write(to: userData.appendingPathComponent(name))
        }

        let report = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxDirectoriesScanned: 100,
                maxDepth: 5,
                maxResults: 100,
                maxScanSeconds: 5
            )
        )

        XCTAssertEqual(report.exactGroups.count, 1)
        XCTAssertEqual(
            Set(report.exactGroups[0].files.map(\.path)),
            Set(["one.bin", "two.bin"].map { userData.appendingPathComponent($0).path })
        )
        XCTAssertTrue(report.coverage.roots[0].skippedPaths.contains {
            $0.path == cacheMount.path && $0.reason == .policyExcluded
        })
    }

    func testTraversalSkipsTimeMachineLocationsBeforeDescending() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let backupRoot = root.appendingPathComponent("Backups.backupdb", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try Data("backup duplicate".utf8).write(to: backupRoot.appendingPathComponent("one.bin"))
        try Data("backup duplicate".utf8).write(to: backupRoot.appendingPathComponent("two.bin"))

        let report = DuplicateFileScanner.scanReport(
            configuration: DuplicateFileScanner.Configuration(
                roots: [root.path],
                excludedPaths: [],
                minimumBytes: 1,
                maxFilesScanned: 100,
                maxDirectoriesScanned: 100,
                maxDepth: 5,
                maxResults: 100,
                maxScanSeconds: 5
            )
        )

        XCTAssertTrue(report.exactGroups.isEmpty)
        XCTAssertTrue(report.coverage.roots[0].skippedPaths.contains {
            $0.path == backupRoot.path && $0.reason == .timeMachine
        })
    }

    func testCancelledDiscoveryResumesFromPersistedDirectoryBoundary() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 0..<18 {
            let directory = root.appendingPathComponent(String(format: "%02d", index))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("persisted duplicate".utf8).write(
                to: directory.appendingPathComponent("copy-\(index).bin")
            )
        }

        let scanConfiguration = configuration(root: root)
        let control = DuplicateFileScanControl()
        let resumeDataBox = DuplicateResumeDataBox()
        let interrupted = DuplicateFileScanner.scanReport(
            configuration: scanConfiguration,
            resumeIndexData: nil,
            control: control,
            resumeIndex: { resumeDataBox.set($0) }
        ) { progress in
            if progress.phase == .discovering, progress.scannedDirectories == 17 {
                control.cancel()
            }
        }

        XCTAssertEqual(interrupted.outcome, .cancelled)
        let resumeData = try XCTUnwrap(resumeDataBox.get())

        let firstResumedDirectoryCount = DuplicateIntegerBox()
        let resumed = DuplicateFileScanner.scanReport(
            configuration: scanConfiguration,
            resumeIndexData: resumeData,
            resumeIndex: { _ in }
        ) { progress in
            firstResumedDirectoryCount.setIfEmpty(progress.scannedDirectories)
        }

        XCTAssertEqual(firstResumedDirectoryCount.get(), 16)
        XCTAssertEqual(resumed.outcome, .complete)
        XCTAssertEqual(resumed.progress.scannedDirectories, 19)
        XCTAssertEqual(resumed.progress.scannedFiles, 18)
        XCTAssertEqual(resumed.exactGroups.count, 1)
        XCTAssertEqual(resumed.exactGroups[0].files.count, 18)
    }

    func testFileLimitResumeUsesFreshBudgetAndKeepsEveryCandidateOnce() throws {
        let root = try makeTemporaryDirectory()
        let outsideRoot = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        defer { try? FileManager.default.removeItem(at: outsideRoot) }

        let expectedPaths = Set((0..<5).map { index in
            root.appendingPathComponent("copy-\(index).bin").path
        })
        for path in expectedPaths {
            try Data("same resumed payload".utf8).write(to: URL(fileURLWithPath: path))
        }
        let outsideFile = outsideRoot.appendingPathComponent("outside.bin")
        try Data("same resumed payload".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("zz-alias.bin"),
            withDestinationURL: outsideFile
        )

        var scanConfiguration = configuration(root: root)
        scanConfiguration.maxFilesScanned = 2
        var resumeData: Data?
        var completedReport: DuplicateFileScanReport?
        var cumulativeFileCounts = [Int]()

        for _ in 0..<4 {
            let resumeDataBox = DuplicateResumeDataBox()
            let report = DuplicateFileScanner.scanReport(
                configuration: scanConfiguration,
                resumeIndexData: resumeData,
                resumeIndex: { resumeDataBox.set($0) }
            )
            cumulativeFileCounts.append(report.progress.scannedFiles)
            if report.outcome == .complete {
                completedReport = report
                break
            }
            XCTAssertEqual(report.outcome, .partial)
            XCTAssertTrue(report.coverage.reachedFileLimit)
            resumeData = try XCTUnwrap(resumeDataBox.get())
        }

        let report = try XCTUnwrap(completedReport)
        XCTAssertEqual(cumulativeFileCounts, [2, 4, 5])
        XCTAssertEqual(report.progress.scannedFiles, expectedPaths.count)
        let files = try XCTUnwrap(report.exactGroups.first).files
        XCTAssertEqual(files.count, expectedPaths.count)
        XCTAssertEqual(Set(files.map(\.path)), expectedPaths)
    }

    func testDirectoryLimitResumeUsesFreshBudgetAndKeepsEveryCandidateOnce() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        var expectedPaths = Set<String>()
        for index in 0..<4 {
            let directory = root.appendingPathComponent("folder-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("copy.bin")
            try Data("same resumed payload".utf8).write(to: file)
            expectedPaths.insert(file.path)
        }

        var scanConfiguration = configuration(root: root)
        scanConfiguration.maxDirectoriesScanned = 2
        var resumeData: Data?
        var completedReport: DuplicateFileScanReport?
        var cumulativeDirectoryCounts = [Int]()

        for _ in 0..<4 {
            let resumeDataBox = DuplicateResumeDataBox()
            let report = DuplicateFileScanner.scanReport(
                configuration: scanConfiguration,
                resumeIndexData: resumeData,
                resumeIndex: { resumeDataBox.set($0) }
            )
            cumulativeDirectoryCounts.append(report.progress.scannedDirectories)
            if report.outcome == .complete {
                completedReport = report
                break
            }
            XCTAssertEqual(report.outcome, .partial)
            XCTAssertTrue(report.coverage.reachedDirectoryLimit)
            resumeData = try XCTUnwrap(resumeDataBox.get())
        }

        let report = try XCTUnwrap(completedReport)
        XCTAssertEqual(cumulativeDirectoryCounts, [2, 4, 5])
        XCTAssertEqual(report.progress.scannedDirectories, 5)
        XCTAssertEqual(report.progress.scannedFiles, expectedPaths.count)
        let files = try XCTUnwrap(report.exactGroups.first).files
        XCTAssertEqual(files.count, expectedPaths.count)
        XCTAssertEqual(Set(files.map(\.path)), expectedPaths)
    }

    func testResumeIndexStoreRoundTripsAndRejectsSymlinkDestination() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("state/resume-index.json")
        let store = DuplicateFileResumeIndexStore(fileURL: fileURL)
        let payload = Data("resume".utf8)

        try store.save(payload)
        XCTAssertEqual(store.load(), payload)
        try store.clear()
        XCTAssertNil(store.load())

        let target = root.appendingPathComponent("target.json")
        try Data("target".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(payload))
        XCTAssertEqual(try Data(contentsOf: target), Data("target".utf8))
    }

    @MainActor
    func testWorkspacePersistsWholeComputerScope() throws {
        let suiteName = "DuplicateFilesStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = DuplicateFilesStore(defaults: defaults)
        first.scanScope = .wholeComputer

        XCTAssertEqual(DuplicateFilesStore(defaults: defaults).scanScope, .wholeComputer)
    }

    private func configuration(
        root: URL,
        excludedPaths: [String] = []
    ) -> DuplicateFileScanner.Configuration {
        DuplicateFileScanner.Configuration(
            roots: [root.path],
            excludedPaths: excludedPaths,
            minimumBytes: 1,
            maxFilesScanned: 100,
            maxDirectoriesScanned: 100,
            maxDepth: 5,
            maxResults: 100,
            maxScanSeconds: 5
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DuplicateFileScannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func imageFixture(primary: NSColor, secondary: NSColor) throws -> NSBitmapImageRep {
        let width = 64
        let height = 48
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        for y in 0..<height {
            for x in 0..<width {
                bitmap.setColor(x < width / 2 ? primary : secondary, atX: x, y: y)
            }
        }
        return bitmap
    }

    private func write(
        _ bitmap: NSBitmapImageRep,
        as fileType: NSBitmapImageRep.FileType,
        to url: URL
    ) throws {
        let properties: [NSBitmapImageRep.PropertyKey: Any] = fileType == .jpeg
            ? [.compressionFactor: 0.82]
            : [:]
        try XCTUnwrap(bitmap.representation(using: fileType, properties: properties)).write(to: url)
    }
}

private final class DuplicateMutationControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false

    var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
    }
}

private final class DuplicateReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var report: DuplicateFileScanReport?

    func set(_ report: DuplicateFileScanReport) {
        lock.lock()
        self.report = report
        lock.unlock()
    }

    func get() -> DuplicateFileScanReport? {
        lock.lock()
        defer { lock.unlock() }
        return report
    }
}

private final class DuplicateResumeDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?

    func set(_ data: Data?) {
        lock.lock()
        if let data {
            self.data = data
        }
        lock.unlock()
    }

    func get() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}

private final class DuplicateIntegerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int?

    func setIfEmpty(_ value: Int) {
        lock.lock()
        if self.value == nil {
            self.value = value
        }
        lock.unlock()
    }

    func get() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
