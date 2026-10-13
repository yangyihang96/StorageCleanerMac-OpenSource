import Darwin
import XCTest
@testable import StorageCleanerMac

final class MigrationPublicationFollowupTests: XCTestCase {
    func testReadOnlyApplicationRootPublishesWithOriginalModeAndValidSignature() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let item = try Self.makeApplication(in: fixture.root)
        XCTAssertEqual(chmod(item.sourceURL.path, 0o555), 0)
        let before = try Self.status(item.sourceURL)
        let result = try ExternalDriveMigrationService.migrate(item, to: fixture.volume, trustedVolumes: [fixture.volume])
        XCTAssertNil(result.publicationWarning)
        XCTAssertFalse(result.didMoveSourceToTrash)
        XCTAssertEqual(try Self.status(result.destinationURL).st_mode & 0o7777, 0o555)
        XCTAssertEqual(try Self.status(item.sourceURL).st_mode & 0o7777, before.st_mode & 0o7777)
        XCTAssertEqual(try Self.status(item.sourceURL).st_ino, before.st_ino)
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(result.destinationURL).st_birthtimespec),
                       GuardedFileCopy.Timestamp(before.st_birthtimespec))
        XCTAssertTrue(try CodeSignatureVerifier().verifyCode(at: result.destinationURL).isValid)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: result.destinationURL.deletingLastPathComponent().path),
                       [item.sourceURL.lastPathComponent])
    }

    func testReadOnlyRootPublicationFailureCleansStagingAndKeepsOriginalAndExistingDestination() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("ReadOnly.app", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try fixture.contents.write(to: source.appendingPathComponent("resource.bin"))
        XCTAssertEqual(chmod(source.path, 0o555), 0)
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("ReadOnly.app")
        let existing = fixture.root.appendingPathComponent("keep.bin")
        let sentinel = Data("keep destination".utf8)
        try sentinel.write(to: existing)
        let copied = try GuardedFileCopy(reader: .init()).copy(source, to: target, deferRootFlags: true)
        XCTAssertEqual(copied.deferredRootMode, 0o555)
        XCTAssertNotEqual(try Self.status(target).st_mode & mode_t(S_IWUSR), 0)
        // A real cross-parent publication refusal, followed by the production
        // staging owner, must neither strand a read-only root nor touch siblings.
        let missingParent = fixture.root.appendingPathComponent("missing/ReadOnly.app")
        XCTAssertThrowsError(try FileManager.default.moveItem(at: target, to: missingParent))
        try staging.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
        XCTAssertEqual(try Self.status(source).st_mode & 0o7777, 0o555)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent("resource.bin")), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: existing), sentinel)
    }

    func testLostHiddenFlagIsRestoredAfterProductionPublication() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        XCTAssertEqual(chflags(fixture.file.path, UInt32(UF_HIDDEN)), 0)
        let manager = PublicationFileManager { destination in
            var status = stat()
            XCTAssertEqual(lstat(destination.path, &status), 0)
            XCTAssertEqual(lchflags(destination.path, status.st_flags & ~UInt32(UF_HIDDEN)), 0)
        }
        let result = try ExternalDriveMigrationService.migrate(fixture.item, to: fixture.volume,
            fileManager: manager, trustedVolumes: [fixture.volume])
        XCTAssertNil(result.publicationWarning)
        XCTAssertNotNil(result.contentVerification)
        for url in [fixture.file, result.destinationURL] {
            XCTAssertNotEqual(try Self.status(url).st_flags & UInt32(UF_HIDDEN), 0)
            XCTAssertEqual(try Data(contentsOf: url), fixture.contents)
        }
        XCTAssertEqual(GuardedFileCopy.flagsAfterPublication(destinationFlags: UInt32(UF_COMPRESSED),
                                                            deferredFlags: UInt32(UF_HIDDEN)), UInt32(UF_COMPRESSED | UF_HIDDEN))
    }

    func testFlagRestorationRefusalReturnsPublishedCopyWithWarningAndKeepsOriginal() throws {
        // deny writeattr does not deny an owner's chflags operation. Exercise
        // the syscall's refusal after a real copy, verification and publication.
        for code in [EACCES, ENOTSUP] {
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            XCTAssertEqual(chflags(fixture.file.path, UInt32(UF_HIDDEN)), 0)
            let before = try Self.status(fixture.file)
            let trace = PublicationFlagTrace()
            let manager = PublicationFileManager { destination in
                var status = stat()
                XCTAssertEqual(lstat(destination.path, &status), 0)
                XCTAssertEqual(lchflags(destination.path, status.st_flags & ~UInt32(UF_HIDDEN)), 0)
            }
            let result = try ExternalDriveMigrationService.migrate(fixture.item, to: fixture.volume,
                fileManager: manager, trustedVolumes: [fixture.volume], publicationFlagOperation: { path, flags in
                    trace.record(path: String(cString: path), flags: flags)
                    XCTAssertEqual(String(cString: path), fixture.destination.path)
                    XCTAssertEqual(flags & UInt32(UF_HIDDEN), UInt32(UF_HIDDEN))
                    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destination.path),
                                  "B: the refused call must occur after publication")
                    errno = code
                    return -1
                })
            XCTAssertEqual(trace.paths, [fixture.destination.path], "B: must reach the failing flag syscall exactly once")
            XCTAssertEqual(trace.flags.count, 1)
            XCTAssertEqual(trace.flags.first.map { $0 & UInt32(UF_HIDDEN) }, UInt32(UF_HIDDEN))
            XCTAssertNotNil(result.publicationWarning)
            XCTAssertTrue(result.publicationWarning?.contains(L10n.text(
                "副本已生成，但未能恢复隐藏或锁定标志。原件保留，请检查副本。",
                "The copy was created, but its hidden or locked flags could not be restored. The original was kept. Check the copy.")) == true)
            XCTAssertNil(result.contentVerification)
            XCTAssertFalse(result.didMoveSourceToTrash)
            XCTAssertNil(result.trashURL)
            XCTAssertEqual(result.destinationURL, fixture.destination)
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.contents)
            XCTAssertEqual(try Self.status(result.destinationURL).st_flags & UInt32(UF_HIDDEN), 0)
            let after = try Self.status(fixture.file)
            XCTAssertNotEqual(after.st_flags & UInt32(UF_HIDDEN), 0)
            XCTAssertEqual(after.st_flags, before.st_flags)
            XCTAssertEqual(after.st_dev, before.st_dev)
            XCTAssertEqual(after.st_ino, before.st_ino)
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path),
                           [fixture.file.lastPathComponent], "B: keep the published copy and remove only its staging tree")
        }
    }

    func testBirthTimeIsRestoredEvenWhenSystemCopyReplacesItWithMtime() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let created = GuardedFileCopy.Timestamp(timespec(tv_sec: 1_546_300_800, tv_nsec: 111_111_111))
        let modified = GuardedFileCopy.Timestamp(timespec(tv_sec: 1_577_934_245, tv_nsec: 123_456_789))
        try Self.setBirthTime(fixture.file, to: created)
        let times = [modified.value, modified.value]
        XCTAssertEqual(times.withUnsafeBufferPointer {
            utimensat(AT_FDCWD, fixture.file.path, $0.baseAddress, AT_SYMLINK_NOFOLLOW)
        }, 0)
        XCTAssertEqual(chmod(fixture.file.path, 0o444), 0)
        let before = try Self.status(fixture.file)
        XCTAssertEqual(GuardedFileCopy.Timestamp(before.st_birthtimespec), created)
        let target = fixture.root.appendingPathComponent("copy.bin")
        let copied = try GuardedFileCopy(reader: .init(), allowsCloning: false, copyfileOperation: { from, to, state, flags in
            let result = Darwin.copyfile(from, to, state, flags)
            if result == 0 {
                // Reproduce the measured cross-volume system behavior even on
                // the single-volume fixture used by this targeted test.
                do {
                    XCTAssertEqual(chmod(to, 0o644), 0)
                    try Self.setBirthTime(URL(fileURLWithPath: String(cString: to)), to: modified)
                    XCTAssertEqual(chmod(to, 0o444), 0)
                }
                catch { XCTFail("Could not construct cross-volume time counterexample: \(error)"); errno = EIO; return -1 }
            }
            return result
        }).copy(fixture.file, to: target)
        XCTAssertTrue(copied.metadataWarnings.isEmpty)
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(target).st_birthtimespec), created)
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(target).st_mtimespec), modified)
        XCTAssertEqual(try Self.status(target).st_mode & 0o7777, 0o444)
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(fixture.file).st_birthtimespec), created)
        XCTAssertEqual(try Data(contentsOf: target), fixture.contents)
    }

    func testSystemMissingPathIsNeutralAndDatalessErrnoHasBothLanguages() throws {
        let preferences = TestVolatilePreferences()
        defer { preferences.restore() }
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let missing = fixture.root.appendingPathComponent("missing/copy.bin")
        var failure: Error?
        XCTAssertThrowsError(try GuardedFileCopy(reader: .init(), supportsACL: { _ in true }).copy(fixture.file, to: missing)) {
            failure = $0
        }
        for language in [AppLanguage.zhHans, .english] {
            preferences.set(language.rawValue, forKey: L10n.languageDefaultsKey)
            let message = FileContentReadError.userMessage(for: try XCTUnwrap(failure))
            XCTAssertNotEqual(message, ExternalDriveMigrationError.sourceMissing.localizedDescription)
            XCTAssertEqual(message, FileContentReadError.userMessage(for: POSIXError(.ENOENT)))
            XCTAssertEqual(FileContentReadError.userMessage(for: POSIXError(.EDEADLK)), FileContentReadError.cloudOnly.localizedDescription)
            XCTAssertNotEqual(FileContentReadError.copyTimedOut.localizedDescription, FileContentReadError.timedOut.localizedDescription)
            XCTAssertNotEqual(FileContentReadError.writingTimedOut.localizedDescription, FileContentReadError.copyTimedOut.localizedDescription)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testDirectoryAndLinkBirthTimesAreRestoredWithoutChangingLinkReferent() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: fixture.file.path)
        let created = GuardedFileCopy.Timestamp(timespec(tv_sec: 1_546_300_800, tv_nsec: 111_111_111))
        try Self.setBirthTime(source, to: created)
        try Self.setBirthTime(link, to: created)
        let referentBefore = GuardedFileCopy.Timestamp(try Self.status(fixture.file).st_birthtimespec)
        let target = fixture.root.appendingPathComponent("copy-directory", isDirectory: true)
        try GuardedFileCopy(reader: .init(), allowsCloning: false).copy(source, to: target)
        for url in [target, target.appendingPathComponent("link")] {
            XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(url).st_birthtimespec), created)
        }
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(fixture.file).st_birthtimespec), referentBefore)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: target.appendingPathComponent("link").path),
                       fixture.file.path)
    }

    func testChangedCtimeBeforeMetadataRestorationRehashesAndRejectsChangedCopy() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("copy.bin")
        let copier = GuardedFileCopy(reader: .init())
        let copied = try copier.copy(fixture.file, to: target, deferRootFlags: true)
        let proof = try MigrationContentVerification.verify(fixture.file, target, reader: .init())
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data(repeating: 0x59, count: fixture.contents.count))
        try handle.close()
        let beforeRestoration = try GuardedFileContentReader().open(target).snapshot
        XCTAssertNotEqual(beforeRestoration, proof.destinationSnapshot)
        try copier.restoreTimes(copied, at: target, onFailure: {})
        let published = fixture.root.appendingPathComponent("published.bin")
        try FileManager.default.moveItem(at: target, to: published)
        let probe = ContentReadProbe()
        let refreshed = proof.afterPublication(at: published,
            reader: .init(willRead: { _ in probe.recordRead() }), beforeMetadataRestoration: beforeRestoration)
        XCTAssertNil(refreshed)
        XCTAssertGreaterThan(probe.reads, 0, "F: changed ctime must trigger content hashing, even after mtime restoration")
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testMetadataOnlyCtimeChangeRehashesAndRenewsMatchingProof() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let target = fixture.root.appendingPathComponent("copy.bin")
        try GuardedFileCopy(reader: .init()).copy(fixture.file, to: target)
        let proof = try MigrationContentVerification.verify(fixture.file, target, reader: .init())
        XCTAssertEqual(chmod(target.path, 0o444), 0)
        let changed = try GuardedFileContentReader().open(target).snapshot
        let probe = ContentReadProbe()
        let refreshed = try XCTUnwrap(proof.afterPublication(at: target,
            reader: .init(willRead: { _ in probe.recordRead() }), beforeMetadataRestoration: changed))
        XCTAssertGreaterThan(probe.reads, 0)
        XCTAssertEqual(refreshed.destinationSnapshot, changed)
        XCTAssertEqual(refreshed.digest, proof.digest)
    }

    func testDeniedDeletePublicationCleansOnlyOwnedStagingAndPreservesOriginalACL() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let command = try Shell.run("/bin/chmod", ["+a", "everyone deny delete", fixture.file.path], timeout: 5)
        XCTAssertEqual(command.terminationStatus, 0, command.standardError)
        let before = try Self.aclText(fixture.file)
        // acl_to_text uses ':' between the tag and permissions; chmod's input
        // syntax is not an output contract. Check the principal and ACE itself.
        XCTAssertTrue(try Self.hasEveryoneDeleteDenial(fixture.file), before)
        let sibling = fixture.volume.url.appendingPathComponent("keep.bin")
        let sentinel = Data("keep target sibling".utf8)
        try sentinel.write(to: sibling)
        XCTAssertThrowsError(try fixture.migrate())
        let root = fixture.destination.deletingLastPathComponent()
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !(try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty,
              ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try fixture.assertNoPartialOrPublishedCopy()
        XCTAssertEqual(try Self.aclText(fixture.file), before)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: sibling), sentinel)
    }

    func testCleanupRefusesToChangeDeletionACLOnAnExternalHardLink() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let command = try Shell.run("/bin/chmod", ["+a", "everyone deny delete", fixture.file.path], timeout: 5)
        XCTAssertEqual(command.terminationStatus, 0, command.standardError)
        let before = try Self.aclText(fixture.file)
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        let link = staging.url.appendingPathComponent("shared.bin")
        XCTAssertEqual(Darwin.link(fixture.file.path, link.path), 0)
        defer {
            _ = try? Shell.run("/bin/chmod", ["-N", fixture.file.path], timeout: 5)
            try? staging.remove()
        }
        XCTAssertThrowsError(try staging.remove()) {
            guard let error = $0 as? CleanupMoveError, case .unsafeQuarantineRoot = error else {
                XCTFail("Expected owned-tree refusal, got \($0)"); return
            }
        }
        XCTAssertEqual(try Self.aclText(fixture.file), before)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testSecondPrecisionBirthTimeKeepsProofAndReusesItWhenHandlingOriginal() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let created = GuardedFileCopy.Timestamp(timespec(tv_sec: 1_546_300_800, tv_nsec: 111_111_111))
        try Self.setBirthTime(fixture.file, to: created)
        let writes = ContentReadProbe()
        let policy = MigrationCreationTime(write: { url, timestamp in
            XCTAssertNotEqual(url, fixture.file)
            writes.recordRead()
            do { try Self.setBirthTime(url, to: .init(timespec(tv_sec: timestamp.seconds, tv_nsec: 0))); return 0 }
            catch { errno = EIO; return -1 }
        }, precision: { _ in 1_000_000_000 })
        let result = try ExternalDriveMigrationService.migrate(fixture.item, to: fixture.volume,
            trustedVolumes: [fixture.volume], creationTime: policy)
        XCTAssertEqual(writes.reads, 2, "Both production metadata passes must use the rounding syscall")
        XCTAssertNil(result.publicationWarning)
        XCTAssertTrue(result.information.isEmpty, "Representable rounding is success, not a warning")
        XCTAssertNotNil(result.contentVerification)
        XCTAssertFalse(result.didMoveSourceToTrash)
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(result.destinationURL).st_birthtimespec),
                       .init(timespec(tv_sec: created.seconds, tv_nsec: 0)))
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(fixture.file).st_birthtimespec), created)
        let reads = ContentReadProbe()
        let trash = fixture.root.appendingPathComponent("simulated-trash.bin")
        let moved = try ExternalDriveMigrationService.moveOriginalToTrash(fixture.item,
            verifiedCopyAt: result.destinationURL, on: fixture.volume, trustedVolumes: [fixture.volume],
            trashOperation: { url in try FileManager.default.moveItem(at: url, to: trash); return trash },
            journal: CleanupReportJournal(directory: fixture.root.appendingPathComponent("journal")),
            contentVerification: result.contentVerification, contentReader: .init(willRead: { _ in reads.recordRead() }))
        XCTAssertEqual(reads.reads, 0, "Birth-time precision must not force content rehashing")
        XCTAssertTrue(moved.didMoveSourceToTrash)
        XCTAssertTrue(moved.canRestoreFromHistory)
        XCTAssertEqual(try Data(contentsOf: trash), fixture.contents)
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.contents)
    }

    func testUnavailableBirthTimeIsInformationalWithoutBlockingContentProof() throws {
        for code in [ENOTSUP, EINVAL, EACCES] {
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            let writes = ContentReadProbe()
            let result = try ExternalDriveMigrationService.migrate(fixture.item, to: fixture.volume,
                trustedVolumes: [fixture.volume], creationTime: .init(write: { url, _ in
                    XCTAssertNotEqual(url, fixture.file)
                    writes.recordRead(); errno = code; return -1
                }))
            XCTAssertEqual(writes.reads, 2)
            XCTAssertNil(result.publicationWarning)
            XCTAssertNotNil(result.contentVerification)
            XCTAssertEqual(result.information, [L10n.text("目标磁盘未能保留创建时间。", "The destination could not retain creation times.")])
            XCTAssertTrue(result.noticeMessage(fallback: "verified").hasPrefix("verified\n"))
            XCTAssertFalse(result.didMoveSourceToTrash)
            XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
            XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.contents)
        }
    }

    func testBirthTimeReadbackDoesNotHideWrongSecondsAsSupportedPrecision() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let created = GuardedFileCopy.Timestamp(timespec(tv_sec: 1_546_300_800, tv_nsec: 111_111_111))
        try Self.setBirthTime(fixture.file, to: created)
        let result = try ExternalDriveMigrationService.migrate(fixture.item, to: fixture.volume,
            trustedVolumes: [fixture.volume], creationTime: .init(write: { url, timestamp in
                do { try Self.setBirthTime(url, to: .init(timespec(tv_sec: timestamp.seconds + 5, tv_nsec: 0))); return 0 }
                catch { errno = EIO; return -1 }
            }, precision: { _ in 1_000_000_000 }))
        XCTAssertNil(result.publicationWarning)
        XCTAssertNotNil(result.contentVerification)
        XCTAssertEqual(result.information, [L10n.text("目标磁盘未能完整保留创建时间。", "The destination could not fully retain creation times.")])
        XCTAssertEqual(GuardedFileCopy.Timestamp(try Self.status(fixture.file).st_birthtimespec), created)
    }

    func testBirthTimeIOFailureStillRefusesPublicationAndKeepsOriginal() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        XCTAssertThrowsError(try ExternalDriveMigrationService.migrate(fixture.item, to: fixture.volume,
            trustedVolumes: [fixture.volume], creationTime: .init(write: { _, _ in errno = EIO; return -1 }))) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EIO)
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while !(try FileManager.default.contentsOfDirectory(atPath: fixture.destination.deletingLastPathComponent().path)).isEmpty,
              ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try fixture.assertNoPartialOrPublishedCopy()
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    private static func makeApplication(in root: URL) throws -> ExternalMigrationItem {
        let app = root.appendingPathComponent("ReadOnlyRoot.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let executable = contents.appendingPathComponent("MacOS/Fixture")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let identifier = "test.storagecleaner.readonly-root"
        let info: [String: String] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Fixture",
                                     "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        let signed = try Shell.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path], timeout: 15)
        XCTAssertEqual(signed.terminationStatus, 0, signed.standardError)
        return ExternalMigrationItem(id: "app:readonly", title: "ReadOnlyRoot", sourceURL: app,
                                     sizeBytes: 1024, kind: .application, bundleIdentifier: identifier)
    }

    private static func status(_ url: URL) throws -> stat {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw POSIXError(.EIO) }
        return status
    }

    private static func setBirthTime(_ url: URL, to timestamp: GuardedFileCopy.Timestamp) throws {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = attrgroup_t(ATTR_CMN_CRTIME)
        var value = timestamp.value
        guard setattrlist(url.path, &attributes, &value, MemoryLayout<timespec>.size, UInt32(FSOPT_NOFOLLOW)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private static func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var length = 0
        guard let text = acl_to_text(acl, &length) else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }

    private static func hasEveryoneDeleteDenial(_ url: URL) throws -> Bool {
        // Resolve everyone's UUID through the ACL parser rather than assuming
        // a numeric group ID or relying on acl_to_text's presentation format.
        guard let expected = acl_from_text("!#acl 1\ngroup::everyone::deny:delete\n") else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(expected)) }
        var expectedEntry: acl_entry_t?
        guard acl_get_entry(expected, ACL_FIRST_ENTRY.rawValue, &expectedEntry) == 0,
              let expectedEntry, let expectedQualifier = acl_get_qualifier(expectedEntry) else { throw POSIXError(.EIO) }
        defer { acl_free(expectedQualifier) }
        let everyone = Data(bytes: expectedQualifier, count: MemoryLayout<uuid_t>.size)

        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var cursor = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, cursor, &entry) == 0 {
            cursor = ACL_NEXT_ENTRY.rawValue
            guard let entry else { throw POSIXError(.EIO) }
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0,
                  let permissions, let qualifier = acl_get_qualifier(entry) else { throw POSIXError(.EIO) }
            defer { acl_free(qualifier) }
            if tag == ACL_EXTENDED_DENY, acl_get_perm_np(permissions, ACL_DELETE) == 1,
               Data(bytes: qualifier, count: MemoryLayout<uuid_t>.size) == everyone { return true }
        }
        return false
    }

    private final class PublicationFlagTrace: @unchecked Sendable {
        private let lock = NSLock()
        private var recordedPaths: [String] = []
        private var recordedFlags: [UInt32] = []
        var paths: [String] { lock.withLock { recordedPaths } }
        var flags: [UInt32] { lock.withLock { recordedFlags } }
        func record(path: String, flags: UInt32) {
            lock.withLock { recordedPaths.append(path); recordedFlags.append(flags) }
        }
    }

    private final class PublicationFileManager: FileManager, @unchecked Sendable {
        private let afterMove: @Sendable (URL) -> Void
        init(afterMove: @escaping @Sendable (URL) -> Void) { self.afterMove = afterMove; super.init() }
        override func moveItem(at srcURL: URL, to dstURL: URL) throws {
            try super.moveItem(at: srcURL, to: dstURL)
            afterMove(dstURL)
        }
    }

    func testBirthTimeComparisonUsesWholeTargetQuantaIncludingFATTwoSeconds() {
        func time(_ seconds: Int, _ nanoseconds: Int = 0) -> GuardedFileCopy.Timestamp {
            GuardedFileCopy.Timestamp(timespec(tv_sec: seconds, tv_nsec: nanoseconds))
        }
        let fat = 2_000_000_000
        // FAT stores odd seconds in the preceding even second.
        XCTAssertTrue(MigrationCreationTime.matches(time(1_700_000_013, 500_000_000), time(1_700_000_012), quantum: fat))
        XCTAssertTrue(MigrationCreationTime.matches(time(1_700_000_012, 999_999_999), time(1_700_000_012), quantum: fat))
        XCTAssertFalse(MigrationCreationTime.matches(time(1_700_000_013), time(1_700_000_010), quantum: fat))
        XCTAssertFalse(MigrationCreationTime.matches(time(1_700_000_014), time(1_700_000_012), quantum: fat))
        // Second-granular volumes and exact volumes keep their previous meaning.
        XCTAssertTrue(MigrationCreationTime.matches(time(1_700_000_013, 700), time(1_700_000_013), quantum: 1_000_000_000))
        XCTAssertFalse(MigrationCreationTime.matches(time(1_700_000_013), time(1_700_000_012), quantum: 1_000_000_000))
        XCTAssertFalse(MigrationCreationTime.matches(time(1_700_000_013, 700), time(1_700_000_013), quantum: 1))
        XCTAssertTrue(MigrationCreationTime.matches(time(-3, 500), time(-4), quantum: fat))
    }
}
