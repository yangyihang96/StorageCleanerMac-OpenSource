import Darwin
import XCTest
@testable import StorageCleanerMac

private enum D184Fat {
    static let native = Data("native-arm-bytes!".utf8)
    static let foreign = Data("other-chip-bytes-here".utf8)

    static func put(_ value: UInt64, in data: inout Data, at offset: Int, length: Int = 4) {
        for index in 0..<length { data[offset + index] = UInt8(truncatingIfNeeded: value >> ((length - index - 1) * 8)) }
    }

    static func make(wide: Bool = false, nativeCPU: UInt32 = UniversalMachO.arm64,
                     otherCPU: UInt32 = UniversalMachO.x86_64) -> Data {
        var data = Data(repeating: 0, count: 256)
        put(wide ? 0xcafebabf : 0xcafebabe, in: &data, at: 0)
        put(2, in: &data, at: 4)
        for (index, entry) in [(nativeCPU, 128, native), (otherCPU, 192, foreign)].enumerated() {
            let base = 8 + index * (wide ? 32 : 20)
            put(UInt64(entry.0), in: &data, at: base)
            put(UInt64(entry.1), in: &data, at: base + 8, length: wide ? 8 : 4)
            put(UInt64(entry.2.count), in: &data, at: base + (wide ? 16 : 12), length: wide ? 8 : 4)
            data.replaceSubrange(entry.1..<(entry.1 + entry.2.count), with: entry.2)
        }
        return data
    }

    static func parse(_ data: Data, size: UInt64? = nil, cpu: UInt32 = UniversalMachO.arm64) throws -> UniversalMachO.Plan? {
        try UniversalMachO.parse(header: data, fileSize: size ?? UInt64(data.count), nativeCPU: cpu)
    }
}

private struct D184Fixture {
    let root: URL
    let app: URL
    let binary: URL
    let trash: URL
    let journal: CleanupReportJournal

    init(_ test: XCTestCase, name: String = "Example") throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        root = repo.appendingPathComponent(".build/d184-fixtures").appendingPathComponent(TestFileSystem.uniqueRoot("d184").lastPathComponent)
        // Like D185: sandbox-local UUID fixture, with strict teardown; no factory overrides.
        // The shared ownership registry only accepts its original HOME/temp parent.
        let ownedRoot = root
        test.addTeardownBlock { TestFileSystem.remove(ownedRoot) }
        app = root.appendingPathComponent("Applications/\(name).app")
        binary = app.appendingPathComponent("Contents/MacOS/fixture")
        trash = root.appendingPathComponent("fixture-trash")
        journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts", isDirectory: true))
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.d184.\(name)", "CFBundleName": name,
                    "CFBundleShortVersionString": "1.2.3", "CFBundleExecutable": "fixture"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try D184Fat.make().write(to: binary)
        XCTAssertEqual(chmod(binary.path, 0o751), 0)
    }

    func environment() -> UniversalBinaryEnvironment {
        var env = UniversalBinaryEnvironment()
        env.roots = [app.deletingLastPathComponent()]
        env.nativeCPU = UniversalMachO.arm64
        env.ownBundleID = "test.d184.this-app"
        env.signature = { _ in }
        env.isApple = { _ in false }
        env.gatekeeper = { _ in true }
        env.running = { _, _ in false }
        if !UniversalBinarySafety.isAPFS(root) {
            // Only a fake filesystem implementation for the isolated fixture; production has no fallback.
            env.isAPFS = { _ in true }
            env.clone = { try FileManager.default.copyItem(at: $0, to: $1) }
        }
        let trash = self.trash
        env.trash = { source in
            let target = trash.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.moveItem(at: source, to: target)
            return target
        }
        let journal = self.journal
        env.persist = { try journal.checkpoint($0, expectedIdentities: $1) }
        return env
    }

    func candidate(_ env: UniversalBinaryEnvironment? = nil) async throws -> UniversalBinaryCandidate {
        try await UniversalBinaryService.inspect(app, environment: env ?? environment())
    }

    func leftovers() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: app.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { UniversalBinarySafety.isStagingName($0.lastPathComponent) }
    }
}

private final class D184Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

final class UniversalMachOTests: XCTestCase {
    func testAllForeignSlicesAreSummed() throws {
        var data = D184Fat.make()
        D184Fat.put(3, in: &data, at: 4)
        D184Fat.put(12, in: &data, at: 48)
        D184Fat.put(224, in: &data, at: 56)
        D184Fat.put(8, in: &data, at: 60)
        XCTAssertEqual(try D184Fat.parse(data)?.savedBytes, Int64(D184Fat.foreign.count + 8))
    }

    func testBigEndianFat32And64ReadNativeAndSumForeignBytes() throws {
        for wide in [false, true] {
            let data = D184Fat.make(wide: wide)
            let plan = try XCTUnwrap(D184Fat.parse(data))
            XCTAssertEqual(plan.native.offset, 128)
            XCTAssertEqual(plan.native.size, UInt64(D184Fat.native.count))
            XCTAssertEqual(plan.savedBytes, Int64(D184Fat.foreign.count))
            XCTAssertEqual(plan.header.count, wide ? 72 : 48)
        }
    }

    func testIntelHostKeepsIntelSlice() throws {
        let plan = try XCTUnwrap(D184Fat.parse(D184Fat.make(), cpu: UniversalMachO.x86_64))
        XCTAssertEqual(plan.native.offset, 192)
        XCTAssertEqual(plan.savedBytes, Int64(D184Fat.native.count))
    }

    func testNonFatThinAndShortFilesAreNotCandidates() throws {
        for magic: UInt64 in [0xfeedface, 0xfeedfacf, 0xcefaedfe, 0xcffaedfe, 0x12345678] {
            var data = Data(repeating: 0, count: 8)
            D184Fat.put(magic, in: &data, at: 0)
            XCTAssertNil(try D184Fat.parse(data))
        }
        XCTAssertNil(try D184Fat.parse(Data([1, 2, 3])))
    }

    func testSwappedFatMagicIsRefused() {
        for magic: UInt64 in [0xbebafeca, 0xbfbafeca] {
            var data = D184Fat.make()
            D184Fat.put(magic, in: &data, at: 0)
            XCTAssertThrowsError(try D184Fat.parse(data))
        }
    }

    func testTruncatedTableAndImpossibleArchitectureCountsAreRefused() {
        let fat = D184Fat.make()
        for length in [4, 7, 8, 27, 47] { XCTAssertThrowsError(try D184Fat.parse(Data(fat.prefix(length)), size: 256)) }
        for count: UInt64 in [0, 65, UInt64(UInt32.max)] {
            var data = fat
            D184Fat.put(count, in: &data, at: 4)
            XCTAssertThrowsError(try D184Fat.parse(data))
        }
    }

    func testOffsetsSizesOverflowAndHeaderOverlapAreRefused() {
        for wide in [false, true] {
            for (offset, size): (UInt64, UInt64) in [(0, 16), (16, 16), (250, 20), (257, 1), (128, 0), (128, UInt64.max)] {
                var data = D184Fat.make(wide: wide)
                D184Fat.put(offset, in: &data, at: 16, length: wide ? 8 : 4)
                D184Fat.put(size, in: &data, at: wide ? 24 : 20, length: wide ? 8 : 4)
                XCTAssertThrowsError(try D184Fat.parse(data))
            }
        }
        var wide = D184Fat.make(wide: true)
        D184Fat.put(UInt64.max, in: &wide, at: 16, length: 8)
        XCTAssertThrowsError(try D184Fat.parse(wide))
    }

    func testOverlappingSlicesAndDuplicateArchitecturesAreRefused() {
        var overlap = D184Fat.make()
        D184Fat.put(132, in: &overlap, at: 36)
        XCTAssertThrowsError(try D184Fat.parse(overlap))
        var duplicate = D184Fat.make()
        D184Fat.put(UInt64(UniversalMachO.arm64), in: &duplicate, at: 28)
        XCTAssertThrowsError(try D184Fat.parse(duplicate))
    }

    func testAlignmentAndFat64ReservedWordAreValidated() {
        for alignment: UInt64 in [8, 63, UInt64(UInt32.max)] {
            var data = D184Fat.make()
            D184Fat.put(alignment, in: &data, at: 24)
            XCTAssertThrowsError(try D184Fat.parse(data))
        }
        var data = D184Fat.make(wide: true)
        D184Fat.put(1, in: &data, at: 36)
        XCTAssertThrowsError(try D184Fat.parse(data))
    }

    func testSingleSliceMissingNativeAndAmbiguousNativeAreKept() throws {
        var single = D184Fat.make()
        D184Fat.put(1, in: &single, at: 4)
        XCTAssertNil(try D184Fat.parse(single))
        XCTAssertNil(try D184Fat.parse(D184Fat.make(), cpu: 42))
        var ambiguous = D184Fat.make(otherCPU: UniversalMachO.arm64)
        D184Fat.put(2, in: &ambiguous, at: 32)
        XCTAssertNil(try D184Fat.parse(ambiguous))
    }

    func testExtractionPreservesBytesModeAndExtendedAttributes() throws {
        let fixture = try D184Fixture(self)
        let attribute = "com.storagecleaner.d184-fixture"
        let value = Data("preserve this".utf8)
        XCTAssertEqual(value.withUnsafeBytes { setxattr(fixture.binary.path, attribute, $0.baseAddress, value.count, 0, 0) }, 0)
        let clone = fixture.app.deletingLastPathComponent().appendingPathComponent("Fixture.storagecleaner-thin-\(UUID().uuidString).app")
        try fixture.environment().clone(fixture.app, clone)
        let target = clone.appendingPathComponent("Contents/MacOS/fixture")
        let plan = try XCTUnwrap(UniversalMachO.inspect(target, nativeCPU: UniversalMachO.arm64))
        try UniversalMachO.extract(plan, at: target, clone: clone)
        XCTAssertEqual(try Data(contentsOf: target), D184Fat.native)
        XCTAssertEqual(try UniversalBinarySafety.stamp(target).mode & 0o7777, 0o751)
        XCTAssertEqual(try APFSCloneReplacement.extendedAttributes(target.path)[attribute], value)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
    }

    func testExtractionRejectsOriginalAndChangedHeader() throws {
        let fixture = try D184Fixture(self)
        let plan = try XCTUnwrap(UniversalMachO.inspect(fixture.binary, nativeCPU: UniversalMachO.arm64))
        XCTAssertThrowsError(try UniversalMachO.extract(plan, at: fixture.binary, clone: fixture.app))
        let clone = fixture.app.deletingLastPathComponent().appendingPathComponent("Fixture.storagecleaner-thin-\(UUID().uuidString).app")
        try fixture.environment().clone(fixture.app, clone)
        let file = clone.appendingPathComponent("Contents/MacOS/fixture")
        var changed = D184Fat.make()
        changed[11] ^= 1
        try changed.write(to: file)
        XCTAssertThrowsError(try UniversalMachO.extract(plan, at: file, clone: clone))
        XCTAssertEqual(try Data(contentsOf: file), changed)
    }
}

final class UniversalBinaryWorkflowTests: XCTestCase {
    func testInFlightReceiptIsDurableBeforeSwap() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let flag = D184Flag()
        let journal = fixture.journal
        var env = fixture.environment()
        env.persist = { report, identities in
            try journal.checkpoint(report, expectedIdentities: identities)
            if let row = report.items.first, case .failed(let failure) = row.outcome,
               failure.code == .moveOutcomeUnknown,
               try UniversalBinarySafety.stamp(fixture.app).identity == candidate.tree[""]?.identity {
                let loaded = try journal.read(journal.directory.appendingPathComponent(report.planID.rawValue.uuidString + ".json"))
                XCTAssertEqual(loaded.report.items.first?.outcome, row.outcome)
                flag.set()
            }
        }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .success, result.first?.detail ?? "")
        XCTAssertTrue(flag.value)
    }

    func testOriginalCanBePutBackBesideThinnedApplication() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let result = await UniversalBinaryService.execute([candidate], environment: fixture.environment())
        let receipt = try XCTUnwrap(result.first?.report?.restorableReceipts.first)
        let recovered = await CleanupRecoveryService().restoreOne(receipt, userHomeURL: fixture.root,
            trashURL: fixture.trash, quarantineRootURL: fixture.root.appendingPathComponent("quarantine"),
            allowedApplicationPaths: [])
        XCTAssertEqual(recovered.outcome, .restored)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: receipt.originalPath).appendingPathComponent("Contents/MacOS/fixture")), D184Fat.make())
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.native)
    }

    func testRunningApplicationImmediatelyBeforeSwapIsSkipped() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let flag = D184Flag()
        var env = fixture.environment()
        env.signature = { url in if UniversalBinarySafety.isStagingName(url.lastPathComponent) { flag.set() } }
        env.running = { _, _ in flag.value }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .skipped, result.first?.detail ?? "")
        XCTAssertTrue(result.first?.detail.contains(UniversalBinarySkip.running.title) == true)
        XCTAssertEqual(try UniversalBinarySafety.stamp(fixture.app).identity, candidate.tree[""]?.identity)
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    func testChangeDuringCloningIsDetectedBeforeSwap() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        let clone = env.clone
        var changed = D184Fat.make()
        changed[130] ^= 1
        let injectedUpdate = changed
        env.clone = { source, target in
            try clone(source, target)
            try injectedUpdate.write(to: source.appendingPathComponent("Contents/MacOS/fixture"))
        }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .skipped)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), injectedUpdate)
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    func testAmbiguousTrashMoveUsesOriginalDescriptorToRestoreApplication() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        let move = env.trash
        env.trash = { source in
            _ = try move(source)
            throw CocoaError(.fileWriteUnknown)
        }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .failed)
        // D184＋旧值：未知移动后保留瘦身包；现在通过原包 fd 取回并交换回原位置。
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        XCTAssertEqual(try UniversalBinarySafety.stamp(fixture.app).identity, candidate.tree[""]?.identity)
        let originals = try FileManager.default.contentsOfDirectory(at: fixture.trash, includingPropertiesForKeys: nil)
        XCTAssertEqual(originals.count, 0)
        XCTAssertEqual(try fixture.leftovers(), [])
        guard let outcome = result.first?.report?.items.first?.outcome, case .failed(let failure) = outcome else {
            return XCTFail("Expected an unknown move")
        }
        XCTAssertEqual(failure.code, .moveOutcomeUnknown)
        XCTAssertEqual(result.first?.report?.recoveryAttempts?.last?.restoredCount, 1)
    }

    func testRollbackIdentityConflictPreservesOriginalAndThinnedCopy() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        let move = env.trash
        let retained = fixture.root.appendingPathComponent("retained-thinned.app")
        env.trash = { source in
            _ = try move(source)
            try FileManager.default.moveItem(at: fixture.app, to: retained)
            try FileManager.default.createDirectory(at: fixture.app, withIntermediateDirectories: true)
            throw CocoaError(.fileWriteUnknown)
        }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .failed)
        XCTAssertNotEqual(try UniversalBinarySafety.stamp(fixture.app).identity, candidate.tree[""]?.identity)
        let kept = try XCTUnwrap(fixture.leftovers().first)
        XCTAssertEqual(try UniversalBinarySafety.stamp(kept).identity, candidate.tree[""]?.identity)
        XCTAssertEqual(try Data(contentsOf: kept.appendingPathComponent("Contents/MacOS/fixture")), D184Fat.make())
        XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("Contents/MacOS/fixture")), D184Fat.native)
        XCTAssertTrue(result.first?.detail.contains("；") == true || result.first?.detail.contains(";") == true)
    }

    func testIncorrectTrashReceiptDoesNotPreventRestoringOriginal() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let unrelated = fixture.root.appendingPathComponent("unrelated.app")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        let unrelatedIdentity = try UniversalBinarySafety.stamp(unrelated).identity
        var env = fixture.environment()
        let move = env.trash
        env.trash = { source in _ = try move(source); return unrelated }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        XCTAssertEqual(try UniversalBinarySafety.stamp(fixture.app).identity, candidate.tree[""]?.identity)
        XCTAssertEqual(try UniversalBinarySafety.stamp(unrelated).identity, unrelatedIdentity)
        XCTAssertEqual(try fixture.leftovers(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
    }

    func testExistingRecordedMoveWithoutPreparationStillRecordsAndMoves() async throws {
        let fixture = try D184Fixture(self)
        let env = fixture.environment()
        let identity = try UniversalBinarySafety.stamp(fixture.app).identity
        let report = await RecordedTrashOperation.runAsync(items: [.init(path: fixture.app.path, bytes: 100, identity: identity)],
            ruleID: "fixture.d184.default-hook", validate: { _ in }, move: { try env.trash($0) }, persist: env.persist)
        XCTAssertEqual(report.summary.movedItemCount, 1)
        XCTAssertEqual(report.restorableReceipts.first?.movedIdentity, identity)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testSuccessfulSwapMovesOriginalToRecordedTrash() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let identity = try UniversalBinarySafety.stamp(fixture.app).identity
        let result = await UniversalBinaryService.execute([candidate], environment: fixture.environment())
        XCTAssertEqual(result.map(\.status), [.success], result.map(\.detail).joined())
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.native)
        XCTAssertNotEqual(try UniversalBinarySafety.stamp(fixture.app).identity, identity)
        let report = try XCTUnwrap(result.first?.report)
        let receipt = try XCTUnwrap(report.restorableReceipts.first)
        XCTAssertEqual(try UniversalBinarySafety.stamp(receipt.resultingItemURL).identity, identity)
        XCTAssertEqual(try Data(contentsOf: receipt.resultingItemURL.appendingPathComponent("Contents/MacOS/fixture")), D184Fat.make())
        XCTAssertTrue(receipt.originalPath.contains("storagecleaner-thin-"))
        XCTAssertFalse(URL(fileURLWithPath: receipt.originalPath).lastPathComponent.hasPrefix("."))
        XCTAssertEqual(report.summary.permanentlyFreedBytes, 0)
        XCTAssertEqual(report.summary.reclaimableAfterEmptyingTrashBytes, Int64(D184Fat.foreign.count))
        XCTAssertEqual(try fixture.leftovers(), [])
        XCTAssertEqual(try fixture.journal.loadAvailable().reports.count, 1)
    }

    func testCloneSignatureFailureDeletesCloneAndKeepsOriginalIdentityAndBytes() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let before = try UniversalBinarySafety.tree(fixture.app)
        var env = fixture.environment()
        env.signature = { url in if UniversalBinarySafety.isStagingName(url.lastPathComponent) { throw UniversalBinarySkip.signature } }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .failed)
        XCTAssertEqual(try UniversalBinarySafety.tree(fixture.app), before)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    func testGatekeeperFailureDeletesCloneAndKeepsOriginal() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        env.gatekeeper = { !UniversalBinarySafety.isStagingName($0.lastPathComponent) }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    func testOriginallyDeniedAssessmentDoesNotRequireAnAllowedClone() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        env.gatekeeper = { _ in false }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .success, result.first?.detail ?? "")
    }

    func testUnavailableAssessmentSkipsBeforeCloning() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        env.gatekeeper = { _ in throw UniversalBinarySkip.unavailable }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .skipped)
        XCTAssertEqual(try fixture.leftovers(), [])
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
    }

    func testRunningApplicationAndNonAPFSVolumeAreSkipped() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        for running in [true, false] {
            var env = fixture.environment()
            env.running = { _, _ in running }
            env.isAPFS = { _ in false }
            let result = await UniversalBinaryService.execute([candidate], environment: env)
            XCTAssertEqual(result.first?.status, .skipped)
            XCTAssertEqual(try fixture.leftovers(), [])
            XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        }
    }

    func testChangedIdentityAndChangedContentsAreSkipped() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let moved = fixture.root.appendingPathComponent("old.app")
        try FileManager.default.moveItem(at: fixture.app, to: moved)
        try FileManager.default.copyItem(at: moved, to: fixture.app)
        let replacementID = try UniversalBinarySafety.stamp(fixture.app).identity
        let result = await UniversalBinaryService.execute([candidate], environment: fixture.environment())
        XCTAssertEqual(result.first?.status, .skipped)
        XCTAssertEqual(try UniversalBinarySafety.stamp(fixture.app).identity, replacementID)
        let next = try await fixture.candidate()
        var data = D184Fat.make()
        data[130] ^= 1
        try data.write(to: fixture.binary)
        let changed = await UniversalBinaryService.execute([next], environment: fixture.environment())
        XCTAssertEqual(changed.first?.status, .skipped)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), data)
    }

    func testCloneFailureAndInitialReceiptFailureKeepOriginal() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        env.clone = { _, _ in throw UniversalBinarySkip.cloneFailed }
        let failed = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(failed.first?.status, .skipped)
        env = fixture.environment()
        env.persist = { _, _ in throw CocoaError(.fileWriteNoPermission) }
        let receipt = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(receipt.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        XCTAssertEqual(try UniversalBinarySafety.stamp(fixture.app).identity, candidate.tree[""]?.identity)
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    func testTrashFailureSwapsBackAndDeletesOnlyRejectedClone() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        env.trash = { _ in throw CocoaError(.fileWriteNoPermission) }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        XCTAssertEqual(try UniversalBinarySafety.stamp(fixture.app).identity, candidate.tree[""]?.identity)
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    func testReceiptFailureAfterTrashMoveRestoresOriginal() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        var env = fixture.environment()
        let journal = fixture.journal
        env.persist = { report, identities in
            if report.summary.movedItemCount > 0 { throw CocoaError(.fileWriteNoPermission) }
            try journal.checkpoint(report, expectedIdentities: identities)
        }
        let result = await UniversalBinaryService.execute([candidate], environment: env)
        XCTAssertEqual(result.first?.status, .failed)
        XCTAssertEqual(try Data(contentsOf: fixture.binary), D184Fat.make())
        XCTAssertEqual(try UniversalBinarySafety.stamp(fixture.app).identity, candidate.tree[""]?.identity)
        XCTAssertEqual(try fixture.leftovers(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.trash.path), [])
    }

    func testEachAppHasIndependentOutcomeAndDuplicateSelectionsRunOnce() async throws {
        let a = try D184Fixture(self, name: "Alpha")
        let b = try D184Fixture(self, name: "Bravo")
        var env = a.environment()
        env.roots.append(b.app.deletingLastPathComponent())
        env.signature = { url in
            if url.lastPathComponent.hasPrefix("Alpha"), UniversalBinarySafety.isStagingName(url.lastPathComponent) {
                throw UniversalBinarySkip.signature
            }
        }
        let candidates = try await [a.candidate(env), b.candidate(env)]
        let result = await UniversalBinaryService.execute(candidates + [candidates[0]], environment: env)
        XCTAssertEqual(result.map(\.status), [.failed, .success], result.map(\.detail).joined())
        XCTAssertEqual(try Data(contentsOf: a.binary), D184Fat.make())
        XCTAssertEqual(try Data(contentsOf: b.binary), D184Fat.native)
    }

    func testCloneDeletionRefusesOrdinaryApplicationAndDifferentIdentity() throws {
        let fixture = try D184Fixture(self)
        let identity = try UniversalBinarySafety.stamp(fixture.app).identity
        XCTAssertThrowsError(try UniversalBinarySafety.discardClone(fixture.app, identity: identity))
        let fake = fixture.app.deletingLastPathComponent().appendingPathComponent("Fake.storagecleaner-thin-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: fake, withIntermediateDirectories: true)
        XCTAssertThrowsError(try UniversalBinarySafety.discardClone(fake, identity: identity))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.binary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fake.path))
    }
}

final class UniversalBinaryInventoryTests: XCTestCase {
    func testReadOnlyAppAndMissingOptionalApplicationDirectory() async throws {
        let fixture = try D184Fixture(self)
        XCTAssertEqual(chmod(fixture.app.path, 0o555), 0)
        defer { XCTAssertEqual(chmod(fixture.app.path, 0o755), 0) }
        var env = fixture.environment()
        env.roots.append(fixture.root.appendingPathComponent("missing-Applications"))
        let inventory = await UniversalBinaryService.inventory(environment: env)
        XCTAssertEqual(inventory.skipped[.notWritable], 1)
        XCTAssertTrue(inventory.apps.isEmpty)
        XCTAssertEqual(inventory.unreadableLocations, 0)
    }

    func testUtilitiesRestoreAuthorizationIsRestrictedToD184() async throws {
        let fixture = try D184Fixture(self)
        let candidate = try await fixture.candidate()
        let result = await UniversalBinaryService.execute([candidate], environment: fixture.environment())
        let row = try XCTUnwrap(result.first?.report?.items.first)
        let identity = try XCTUnwrap(candidate.tree[""]?.identity)
        let path = "/Applications/Utilities/Fixture.storagecleaner-thin-\(UUID().uuidString).app"
        let receipt = CleanupMoveReceipt(originalPath: path, resultingItemURL: fixture.trash.appendingPathComponent("Fixture.app"),
            disposition: .trash, movedIdentity: identity, verification: .identityVerified, movedAt: Date())
        let item = CleanReportItem(id: row.id, planItemID: row.planItemID, ruleID: UniversalBinaryService.ruleID,
            sourcePath: path, estimatedBytes: row.estimatedBytes, outcome: .moved(receipt))
        let allowed = CleanupRestoreAuthorization(sourcePath: path, allowedRootPath: "/Applications/Utilities",
            sourceIdentity: identity, ruleID: UniversalBinaryService.ruleID, planItemID: row.planItemID)
        XCTAssertTrue(allowed.permitsApplication(item, receipt: receipt))
        let other = CleanupRestoreAuthorization(sourcePath: path, allowedRootPath: "/Applications/Utilities",
            sourceIdentity: identity, ruleID: "other.rule", planItemID: row.planItemID)
        XCTAssertFalse(other.permitsApplication(item, receipt: receipt))
    }

    func testInventoryIsReadOnlyAndLimitedToFirstLevelApplications() async throws {
        let fixture = try D184Fixture(self)
        let nested = fixture.app.deletingLastPathComponent().appendingPathComponent("Other/Nested.app")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.app, to: nested)
        let before = try UniversalBinarySafety.tree(fixture.app)
        let result = await UniversalBinaryService.inventory(environment: fixture.environment())
        XCTAssertEqual(result.apps.map(\.name), ["Example"])
        XCTAssertEqual(result.apps.first?.version, "1.2.3")
        XCTAssertEqual(result.apps.first?.files.count, 1)
        XCTAssertEqual(result.savedBytes, Int64(D184Fat.foreign.count))
        XCTAssertEqual(try UniversalBinarySafety.tree(fixture.app), before)
        XCTAssertEqual(try fixture.leftovers(), [])
    }

    func testAppleAppStoreSelfAndInvalidSignaturesAreExcluded() async throws {
        let fixture = try D184Fixture(self)
        var apple = fixture.environment()
        apple.isApple = { _ in true }
        let appleResult = await UniversalBinaryService.inventory(environment: apple)
        XCTAssertEqual(appleResult.skipped[.apple], 1)
        var own = fixture.environment()
        own.ownBundleID = "test.d184.Example"
        let ownResult = await UniversalBinaryService.inventory(environment: own)
        XCTAssertEqual(ownResult.skipped[.ownApp], 1)
        var invalid = fixture.environment()
        invalid.signature = { _ in throw UniversalBinarySkip.signature }
        let invalidResult = await UniversalBinaryService.inventory(environment: invalid)
        XCTAssertEqual(invalidResult.skipped[.signature], 1)
        let receipt = fixture.app.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1]).write(to: receipt)
        let storeResult = await UniversalBinaryService.inventory(environment: fixture.environment())
        XCTAssertEqual(storeResult.skipped[.appStore], 1)
    }

    func testExternalDanglingAndAbsoluteInternalSymlinksExcludeWholeBundle() async throws {
        let fixture = try D184Fixture(self)
        let link = fixture.app.appendingPathComponent("Contents/external")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../../../../outside")
        var env = fixture.environment()
        env.signature = { _ in XCTFail("External links must be refused before Security reads bundle resources") }
        let result = await UniversalBinaryService.inventory(environment: env)
        XCTAssertTrue(result.apps.isEmpty)
        XCTAssertEqual(result.skipped[.unsafeBundle], 1)
        let other = try D184Fixture(self)
        try FileManager.default.createSymbolicLink(atPath: other.app.appendingPathComponent("Contents/internal-absolute").path,
                                                   withDestinationPath: other.binary.path)
        let absolute = await UniversalBinaryService.inventory(environment: other.environment())
        XCTAssertEqual(absolute.skipped[.unsafeBundle], 1)
    }

    func testInternalFrameworkSymlinksAreKeptAndPhysicalBinaryCountedOnce() async throws {
        let fixture = try D184Fixture(self)
        let framework = fixture.app.appendingPathComponent("Contents/Frameworks/Fixture.framework")
        let version = framework.appendingPathComponent("Versions/A")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try D184Fat.make(wide: true).write(to: version.appendingPathComponent("Fixture"))
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Versions/Current").path, withDestinationPath: "A")
        try FileManager.default.createSymbolicLink(atPath: framework.appendingPathComponent("Fixture").path, withDestinationPath: "Versions/Current/Fixture")
        let candidate = try await fixture.candidate()
        XCTAssertEqual(candidate.files.count, 2)
        let result = await UniversalBinaryService.execute([candidate], environment: fixture.environment())
        XCTAssertEqual(result.first?.status, .success, result.first?.detail ?? "")
        XCTAssertEqual(try Data(contentsOf: framework.appendingPathComponent("Fixture")), D184Fat.native)
    }

    func testNativeAbsentThinFileAndMalformedFatAreNotListed() async throws {
        let fixture = try D184Fixture(self)
        var env = fixture.environment()
        env.nativeCPU = 42
        let missing = await UniversalBinaryService.inventory(environment: env)
        XCTAssertEqual(missing.skipped[.noNativeSlice], 1)
        try D184Fat.native.write(to: fixture.binary)
        let thin = await UniversalBinaryService.inventory(environment: fixture.environment())
        XCTAssertEqual(thin.skipped[.noNativeSlice], 1)
        var broken = D184Fat.make()
        D184Fat.put(255, in: &broken, at: 16)
        try broken.write(to: fixture.binary)
        let bad = await UniversalBinaryService.inventory(environment: fixture.environment())
        XCTAssertTrue(bad.apps.isEmpty)
        XCTAssertEqual(bad.skipped[.unsafeBundle], 1)
    }

    func testNestedRunningBundleIDsAreChecked() async throws {
        let fixture = try D184Fixture(self)
        let helper = fixture.app.appendingPathComponent("Contents/Helpers/Helper.app/Contents")
        try FileManager.default.createDirectory(at: helper, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test.d184.helper"], format: .xml, options: 0)
            .write(to: helper.appendingPathComponent("Info.plist"))
        var env = fixture.environment()
        env.running = { _, ids in ids.contains("test.d184.helper") }
        let result = await UniversalBinaryService.inventory(environment: env)
        XCTAssertEqual(result.skipped[.running], 1)
    }

    func testSourceGuardsRequireNativeAPIsAndCloneOnlyDeletion() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = ["Services/UniversalBinaryService.swift", "Services/UniversalBinarySafety.swift", "Services/UniversalMachO.swift"]
        let source = try paths.map { try String(contentsOf: repo.appendingPathComponent("Sources/StorageCleanerMac/" + $0), encoding: .utf8) }.joined()
        for forbidden in ["Process(", "Shell.run", "/usr/bin/lipo", "/usr/bin/codesign", "/usr/sbin/spctl"] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        for required in ["clonefile(", "renamex_np(", "RENAME_SWAP", "SecStaticCodeCheckValidity", "kSecCSCheckNestedCode", "SecAssessmentCreate", "RecordedTrashOperation.runAsync"] {
            XCTAssertTrue(source.contains(required), required)
        }
        // Integration review: the only deletion moved to UniversalBinarySafety so
        // the file that moves the original to the Trash deletes nothing (D98 ⑤);
        // was one `removefile(` and these guards in UniversalBinaryService.swift.
        let service = try String(contentsOf: repo.appendingPathComponent("Sources/StorageCleanerMac/Services/UniversalBinaryService.swift"), encoding: .utf8)
        XCTAssertEqual(service.components(separatedBy: "removefile(").count - 1, 0)
        let safety = try String(contentsOf: repo.appendingPathComponent("Sources/StorageCleanerMac/Services/UniversalBinarySafety.swift"), encoding: .utf8)
        XCTAssertEqual(safety.components(separatedBy: "removefile(").count - 1, 1)
        XCTAssertTrue(safety.contains("isStagingName(clone.lastPathComponent)"))
        XCTAssertTrue(safety.contains("stamp(clone).identity == identity"))
    }
}
