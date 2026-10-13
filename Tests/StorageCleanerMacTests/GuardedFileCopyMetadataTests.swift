import CryptoKit
import Darwin
import XCTest
@testable import StorageCleanerMac

final class GuardedFileCopyMetadataTests: XCTestCase {
    func testReadOnlyFileRetainsAttributesPermissionsAndNanosecondTimes() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        try setAttribute(fixture.file, name: "test.storagecleaner.copy", data: Data("metadata".utf8))
        XCTAssertEqual(chmod(fixture.file.path, 0o444), 0)
        try setTimes(fixture.file)
        let before = try metadata(fixture.file)
        let copy = fixture.root.appendingPathComponent("copy.bin")
        try GuardedFileCopy(reader: .init()).copy(fixture.file, to: copy)
        let after = try metadata(copy)
        XCTAssertEqual(after.st_mode & 0o7777, 0o444)
        assertTimes(after, equalTo: before)
        XCTAssertEqual(try attribute(copy, name: "test.storagecleaner.copy"), Data("metadata".utf8))
        XCTAssertEqual(try Data(contentsOf: copy), fixture.contents)
    }

    func testReadOnlyApplicationDirectoriesAndResourcesRetainMetadataAndLinkTimes() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("ReadOnly.app", isDirectory: true)
        let resources = source.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let file = resources.appendingPathComponent("read-only.bin")
        try fixture.contents.write(to: file)
        try setAttribute(file, name: "test.storagecleaner.resource", data: Data([1, 2, 3]))
        try setAttribute(resources, name: "test.storagecleaner.directory", data: Data([4, 5, 6]))
        XCTAssertEqual(chmod(file.path, 0o444), 0)
        let link = source.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Contents/Resources/read-only.bin")
        let nestedLink = resources.appendingPathComponent("nested-link")
        try FileManager.default.createSymbolicLink(atPath: nestedLink.path, withDestinationPath: "read-only.bin")
        XCTAssertEqual(chmod(resources.path, 0o555), 0)
        for clone in [false, true] {
            // Source enumeration can update directory atime; establish and
            // capture a fresh fixture before each independent copy mode.
            try setTimes(link)
            try setTimes(nestedLink)
            try setTimes(resources)
            let linkBefore = try metadata(link)
            let nestedLinkBefore = try metadata(nestedLink)
            let directoryBefore = try metadata(resources)
            let copy = fixture.root.appendingPathComponent("Copy-\(clone).app")
            try GuardedFileCopy(reader: .init(), allowsCloning: clone, copyfileOperation: { from, to, state, flags in
                var status = stat()
                guard lstat(from, &status) == 0 else { return -1 }
                if status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                    XCTAssertEqual(flags & copyfile_flags_t(COPYFILE_CLONE | COPYFILE_EXCL), 0)
                } else {
                    XCTAssertEqual(flags & copyfile_flags_t(COPYFILE_CLONE), clone ? copyfile_flags_t(COPYFILE_CLONE) : 0)
                }
                return Darwin.copyfile(from, to, state, flags)
            }).copy(source, to: copy)
            let copiedResources = copy.appendingPathComponent("Contents/Resources")
            let copiedFile = copiedResources.appendingPathComponent("read-only.bin")
            XCTAssertEqual(try metadata(copiedResources).st_mode & 0o7777, 0o555)
            assertTimes(try metadata(copiedResources), equalTo: directoryBefore)
            assertTimes(try metadata(copy.appendingPathComponent("link")), equalTo: linkBefore)
            assertTimes(try metadata(copiedResources.appendingPathComponent("nested-link")), equalTo: nestedLinkBefore)
            XCTAssertEqual(try attribute(copiedResources, name: "test.storagecleaner.directory"), Data([4, 5, 6]))
            XCTAssertEqual(try attribute(copiedFile, name: "test.storagecleaner.resource"), Data([1, 2, 3]))
            XCTAssertEqual(try metadata(copiedFile).st_mode & 0o7777, 0o444)
            XCTAssertEqual(try Data(contentsOf: copiedFile), fixture.contents)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copy.appendingPathComponent("link").path),
                           "Contents/Resources/read-only.bin")
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: copiedResources.appendingPathComponent("nested-link").path),
                           "read-only.bin")
        }
    }

    func testLockedHiddenFileCanBePublishedAndKeepsItsFlags() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        XCTAssertEqual(chflags(fixture.file.path, UInt32(UF_HIDDEN | UF_IMMUTABLE)), 0)
        let result = try fixture.migrate()
        XCTAssertNil(result.publicationWarning)
        XCTAssertNotNil(result.contentVerification)
        for url in [fixture.file, result.destinationURL] {
            XCTAssertEqual(try metadata(url).st_flags & UInt32(UF_HIDDEN | UF_IMMUTABLE), UInt32(UF_HIDDEN | UF_IMMUTABLE))
            XCTAssertEqual(try Data(contentsOf: url), fixture.contents)
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: result.destinationURL.deletingLastPathComponent().path)
        XCTAssertEqual(remaining, [fixture.file.lastPathComponent])
    }

    func testMigrationRestoresAccessAndModificationTimesAfterVerification() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        try setAttribute(fixture.file, name: "test.storagecleaner.read-only", data: Data([7]))
        XCTAssertEqual(chmod(fixture.file.path, 0o444), 0)
        try setTimes(fixture.file)
        let before = try metadata(fixture.file)
        let result = try fixture.migrate()
        XCTAssertNil(result.publicationWarning)
        XCTAssertNotNil(result.contentVerification)
        let after = try metadata(result.destinationURL)
        assertTimes(after, equalTo: before)
        XCTAssertEqual(after.st_mode & 0o7777, 0o444)
        XCTAssertEqual(try attribute(result.destinationURL, name: "test.storagecleaner.read-only"), Data([7]))
        XCTAssertEqual(try Data(contentsOf: result.destinationURL), fixture.contents)
    }

    func testACLIsPreservedAndUnsupportedACLDestinationStillCopies() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let command = try Shell.run("/bin/chmod", ["+a", "everyone allow read,readattr,readextattr,readsecurity", fixture.file.path], timeout: 5)
        XCTAssertEqual(command.terminationStatus, 0, command.standardError)
        let expected = try aclText(fixture.file)
        XCTAssertTrue(expected.contains("allow"))
        let copy = fixture.root.appendingPathComponent("with-acl.bin")
        try GuardedFileCopy(reader: .init()).copy(fixture.file, to: copy)
        XCTAssertEqual(try aclText(copy), expected)
        let withoutACL = fixture.root.appendingPathComponent("without-acl.bin")
        try GuardedFileCopy(reader: .init(), supportsACL: { _ in false }).copy(fixture.file, to: withoutACL)
        XCTAssertFalse(try aclText(withoutACL).contains("allow"))
        XCTAssertEqual(try Data(contentsOf: withoutACL), fixture.contents)
    }

    func testTransparentCompressionIsRetainedWithAndWithoutCloning() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        // System volume's already-compressed, read-only input. Same-volume
        // ditto only clones on APFS and therefore cannot construct this fixture.
        let compressed = URL(fileURLWithPath: "/usr/share/dict/web2")
        guard FileManager.default.fileExists(atPath: compressed.path) else {
            throw XCTSkip("宿主没有 /usr/share/dict/web2 压缩源；须在支持压缩的跨卷夹具上复测")
        }
        let before = try metadata(compressed)
        guard before.st_flags & UInt32(UF_COMPRESSED) != 0 else {
            throw XCTSkip("宿主的 /usr/share/dict/web2 没有透明压缩；须用跨卷 ditto --hfsCompression 构造夹具复测")
        }
        let payload = try Data(contentsOf: compressed)
        for clone in [false, true] {
            let copy = fixture.root.appendingPathComponent("compressed-copy-\(clone).bin")
            try GuardedFileCopy(reader: .init(), allowsCloning: clone).copy(compressed, to: copy)
            let after = try metadata(copy)
            XCTAssertNotEqual(after.st_flags & UInt32(UF_COMPRESSED), 0)
            XCTAssertLessThan(after.st_blocks * 512, Int64(payload.count / 2))
            XCTAssertEqual(try Data(contentsOf: copy), payload)
        }
    }

    func testSourceRewriteAfterPreflightWithRestoredSizeAndMtimeNeverReachesCopyfile() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let before = try metadata(fixture.file)
        let accessed = GuardedFileCopy.Timestamp(before.st_atimespec)
        let modified = GuardedFileCopy.Timestamp(before.st_mtimespec)
        let changed = GuardedFileCopy.Timestamp(before.st_ctimespec)
        let attempted = ContentReadProbe()
        let reader = GuardedFileContentReader(willRead: { url in
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(repeating: 0x59, count: fixture.contents.count))
            let times = [accessed.value, modified.value]
            XCTAssertEqual(times.withUnsafeBufferPointer {
                utimensat(AT_FDCWD, url.path, $0.baseAddress, AT_SYMLINK_NOFOLLOW)
            }, 0)
            var status = stat()
            XCTAssertEqual(lstat(url.path, &status), 0)
            XCTAssertNotEqual(GuardedFileCopy.Timestamp(status.st_ctimespec), changed,
                              "The equal-size/mtime counterexample must really change ctime")
        })
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("copy.bin")
        let cleaned = XCTestExpectation(description: "changed source staging cleaned")
        let copier = GuardedFileCopy(reader: reader, copyfileOperation: { from, to, state, flags in
            attempted.recordRead()
            return Darwin.copyfile(from, to, state, flags)
        })
        XCTAssertThrowsError(try copier.copy(fixture.file, to: target, onFailure: {
            do { try staging.remove() } catch { XCTFail("Cleanup failed: \(error)") }
            cleaned.fulfill()
        })) { XCTAssertEqual($0 as? FileContentReadError, .changed) }
        await fulfillment(of: [cleaned], timeout: 1)
        XCTAssertEqual(attempted.reads, 0, "M5b must fail before any source content is copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testExistingDestinationIsNeverOverwrittenOrRemovedOnFailure() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let copy = fixture.root.appendingPathComponent("existing.bin")
        let original = Data("keep this destination".utf8)
        try original.write(to: copy)
        let attributeData = Data("keep metadata".utf8)
        try setAttribute(copy, name: "test.storagecleaner.existing", data: attributeData)
        XCTAssertEqual(chmod(copy.path, 0o444), 0)
        XCTAssertEqual(chflags(copy.path, UInt32(UF_HIDDEN | UF_IMMUTABLE)), 0)
        let before = try metadata(copy)
        for clone in [false, true] {
            XCTAssertThrowsError(try GuardedFileCopy(reader: .init(), allowsCloning: clone).copy(fixture.file, to: copy)) {
                XCTAssertEqual(($0 as? POSIXError)?.code, .EEXIST)
            }
            XCTAssertEqual(try metadata(copy).st_ino, before.st_ino)
            XCTAssertEqual(try metadata(copy).st_mode, before.st_mode)
            XCTAssertEqual(try metadata(copy).st_flags, before.st_flags)
            XCTAssertEqual(try attribute(copy, name: "test.storagecleaner.existing"), attributeData)
            XCTAssertEqual(try Data(contentsOf: copy), original)
        }
    }

    func testExistingDirectoryIsRejectedBeforeChangingAnyDescendant() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("source-directory", isDirectory: true)
        let destination = fixture.root.appendingPathComponent("existing-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try fixture.contents.write(to: source.appendingPathComponent("new.bin"))
        let sentinel = destination.appendingPathComponent("keep.bin")
        let original = Data("keep this directory".utf8)
        try original.write(to: sentinel)
        let before = try metadata(destination)
        XCTAssertThrowsError(try GuardedFileCopy(reader: .init()).copy(source, to: destination)) {
            XCTAssertEqual(($0 as? POSIXError)?.code, .EEXIST)
        }
        XCTAssertEqual(try metadata(destination).st_ino, before.st_ino)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), ["keep.bin"])
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
    }

    func testNestedCallbackErrorsRetainErrnoStopPublicationAndCleanOwnedStaging() async throws {
        // A callback may report a data or metadata failure, and copyfile may
        // subsequently replace errno with ECANCELED after QUIT. Neither may
        // become a successful or publishable PreparedCopy.
        for (what, code) in [(Int32(COPYFILE_COPY_DATA), POSIXErrorCode.ENOSPC),
                             (Int32(COPYFILE_COPY_XATTR), POSIXErrorCode.EACCES)] {
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            let source = fixture.root.appendingPathComponent("Nested.app", isDirectory: true)
            let resources = source.appendingPathComponent("Contents/Resources", isDirectory: true)
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let child = resources.appendingPathComponent("fail.bin")
            try fixture.contents.write(to: child)
            let staging = try MigrationStagingDirectory(parentURL: fixture.root)
            defer { try? staging.remove() }
            let target = staging.url.appendingPathComponent("Nested.app")
            let published = fixture.root.appendingPathComponent("Published.app")
            let injected = ContentReadProbe()
            let cleaned = XCTestExpectation(description: "failed child staging cleaned")
            let copier = GuardedFileCopy(reader: .init(), copyfileOperation: { from, to, state, flags in
                let result = Darwin.copyfile(from, to, state, flags)
                guard result == 0, String(cString: from).hasSuffix("/fail.bin") else { return result }
                injected.recordRead()
                var callbackPointer: UnsafeMutableRawPointer?
                var context: UnsafeMutableRawPointer?
                guard copyfile_state_get(state, UInt32(COPYFILE_STATE_STATUS_CB), &callbackPointer) == 0,
                      copyfile_state_get(state, UInt32(COPYFILE_STATE_STATUS_CTX), &context) == 0,
                      let callbackPointer else { errno = EIO; return -1 }
                let callback = unsafeBitCast(callbackPointer, to: copyfile_callback_t.self)
                errno = code.rawValue
                let response = callback(what, Int32(COPYFILE_ERR), state, from, to, context)
                XCTAssertEqual(response, Int32(COPYFILE_QUIT), "ERR must stop copyfile, never ignore the failure")
                errno = ECANCELED
                return response == COPYFILE_CONTINUE ? 0 : -1
            })
            do {
                try copier.copy(source, to: target, onFailure: {
                    do { try staging.remove() } catch { XCTFail("Failed to clean staging: \(error)") }
                    cleaned.fulfill()
                })
                try FileManager.default.moveItem(at: target, to: published)
                XCTFail("An incomplete tree was accepted for publication")
            } catch { XCTAssertEqual((error as? POSIXError)?.code, code) }
            await fulfillment(of: [cleaned], timeout: 1)
            XCTAssertEqual(injected.reads, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
            XCTAssertEqual(try Data(contentsOf: child), fixture.contents)
        }
    }

    func testUnreadableNestedChildThrowsAccessErrorAndCleansOwnedStaging() async throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let source = fixture.root.appendingPathComponent("denied-tree", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        let child = source.appendingPathComponent("denied.bin")
        try fixture.contents.write(to: child)
        XCTAssertEqual(chmod(child.path, 0), 0)
        defer { _ = chmod(child.path, 0o600) }
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        defer { try? staging.remove() }
        let target = staging.url.appendingPathComponent("denied-tree")
        let published = fixture.root.appendingPathComponent("published-tree")
        let cleaned = XCTestExpectation(description: "access failure staging cleaned")
        do {
            try GuardedFileCopy(reader: .init(), allowsCloning: false).copy(source, to: target, onFailure: {
                do { try staging.remove() } catch { XCTFail("Failed to clean staging: \(error)") }
                cleaned.fulfill()
            })
            try FileManager.default.moveItem(at: target, to: published)
            XCTFail("An unreadable child was accepted for publication")
        } catch { XCTAssertEqual((error as? POSIXError)?.code, .EACCES) }
        await fulfillment(of: [cleaned], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
        XCTAssertEqual(chmod(child.path, 0o600), 0)
        XCTAssertEqual(try Data(contentsOf: child), fixture.contents)
    }

    func testPublicationFlagHandlingKeepsCompressionAndDoesNotRequireSystemFlags() throws {
        let compressed = UInt32(UF_COMPRESSED)
        let ownerFlags = UInt32(UF_HIDDEN | UF_IMMUTABLE | UF_APPEND)
        let systemFlags = UInt32(SF_IMMUTABLE | SF_APPEND | SF_RESTRICTED)
        let sourceFlags = compressed | ownerFlags | systemFlags
        let deferred = sourceFlags & GuardedFileCopy.renameBlockingFlags
        let duringPublication = sourceFlags & ~GuardedFileCopy.renameBlockingFlags
        XCTAssertNotEqual(duringPublication & compressed, 0)
        XCTAssertEqual(deferred, UInt32(UF_IMMUTABLE | UF_APPEND))
        XCTAssertEqual(GuardedFileCopy.flagsAfterPublication(destinationFlags: compressed | UInt32(UF_HIDDEN),
                                                            deferredFlags: sourceFlags), compressed | ownerFlags)
        // Synthetic compressed bits are tested without constructing an invalid
        // compressed file. The real setter separately proves SF_* alone is a
        // no-op on an ordinary fixture, requiring no privileged chflags call.
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let before = try metadata(fixture.file)
        try GuardedFileCopy.PreparedCopy(entries: [], deferredFlags: systemFlags).restorePublishedFlags(at: fixture.file)
        XCTAssertEqual(try metadata(fixture.file).st_flags, before.st_flags)
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testChildBecomingCloudOnlyOrDownloadingAfterPreflightIsNotPassedToCopyfile() async throws {
        for reason in [FileContentReadError.cloudOnly, .downloading] {
            let fixture = try MigrationContentFixture()
            defer { fixture.remove() }
            let source = fixture.root.appendingPathComponent("changed-cloud-tree", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
            let child = source.appendingPathComponent("cloud.bin")
            try fixture.contents.write(to: child)
            let childPath = child.path
            let preflightFinished = ContentReadProbe()
            let contentAttempts = ContentReadProbe()
            let reader = GuardedFileContentReader(guardPolicy: .init(
                isPlaceholder: { $0 == childPath && preflightFinished.reads > 0 && reason == .cloudOnly },
                cloudState: { $0.path == childPath && preflightFinished.reads > 0 ? reason : nil },
                needsCloudState: { _, _ in true }
            ), willRead: { _ in preflightFinished.recordRead() })
            let staging = try MigrationStagingDirectory(parentURL: fixture.root)
            defer { try? staging.remove() }
            let target = staging.url.appendingPathComponent("copy")
            let cleaned = XCTestExpectation(description: "newly cloud-only child staging cleaned")
            let copier = GuardedFileCopy(reader: reader, copyfileOperation: { from, to, state, flags in
                if String(cString: from) == childPath { contentAttempts.recordRead() }
                return Darwin.copyfile(from, to, state, flags)
            })
            XCTAssertThrowsError(try copier.copy(source, to: target, onFailure: {
                do { try staging.remove() } catch { XCTFail("Failed to clean staging: \(error)") }
                cleaned.fulfill()
            })) { XCTAssertEqual($0 as? FileContentReadError, reason) }
            await fulfillment(of: [cleaned], timeout: 1)
            XCTAssertEqual(contentAttempts.reads, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
            XCTAssertEqual(try Data(contentsOf: child), fixture.contents)
        }
    }

    func testStagingCleanupRemovesReadOnlyDirectoriesAndLockedChildren() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let staging = try MigrationStagingDirectory(parentURL: fixture.root)
        let directory = staging.url.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let file = directory.appendingPathComponent("locked")
        try fixture.contents.write(to: file)
        XCTAssertEqual(chflags(file.path, UInt32(UF_IMMUTABLE)), 0)
        XCTAssertEqual(chmod(directory.path, 0o555), 0)
        try staging.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.url.path))
        XCTAssertEqual(try Data(contentsOf: fixture.file), fixture.contents)
    }

    func testFIFOAndExcessiveDepthHaveAccurateReasonsAndReadNoContent() throws {
        let fixture = try MigrationContentFixture()
        defer { fixture.remove() }
        let fifo = fixture.root.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let probe = ContentReadProbe()
        let reader = GuardedFileContentReader(willRead: { _ in probe.recordRead() })
        XCTAssertThrowsError(try GuardedFileCopy(reader: reader).copy(fifo, to: fixture.root.appendingPathComponent("copy-pipe"))) {
            XCTAssertEqual($0 as? FileContentReadError, .unsupportedType)
        }
        XCTAssertThrowsError(try reader.pool.read(at: fixture.root) { control in
            try reader.guardPolicy.checkTree(fixture.root, control: control, depth: 128)
        }) { XCTAssertEqual($0 as? FileContentReadError, .tooDeep) }
        let deepRoot = fixture.root.appendingPathComponent("deep", isDirectory: true)
        var deepest = deepRoot
        for _ in 0...128 {
            try FileManager.default.createDirectory(at: deepest, withIntermediateDirectories: true)
            deepest.appendPathComponent("d", isDirectory: true)
        }
        XCTAssertThrowsError(try GuardedFileCopy(reader: reader).copy(deepRoot, to: fixture.root.appendingPathComponent("deep-copy"))) {
            XCTAssertEqual($0 as? FileContentReadError, .tooDeep)
        }
        XCTAssertEqual(probe.reads, 0)
    }

    private func metadata(_ url: URL) throws -> stat {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw POSIXError(.EIO) }
        return value
    }
    private func setTimes(_ url: URL) throws {
        let times = [timespec(tv_sec: 1_690_000_000, tv_nsec: 987_654_321), timespec(tv_sec: 1_700_000_000, tv_nsec: 123_456_789)]
        let result = times.withUnsafeBufferPointer { utimensat(AT_FDCWD, url.path, $0.baseAddress, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { throw POSIXError(.EIO) }
    }
    private func assertTimes(_ actual: stat, equalTo expected: stat, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.st_atimespec.tv_sec, expected.st_atimespec.tv_sec, file: file, line: line)
        XCTAssertEqual(actual.st_atimespec.tv_nsec, expected.st_atimespec.tv_nsec, file: file, line: line)
        XCTAssertEqual(actual.st_mtimespec.tv_sec, expected.st_mtimespec.tv_sec, file: file, line: line)
        XCTAssertEqual(actual.st_mtimespec.tv_nsec, expected.st_mtimespec.tv_nsec, file: file, line: line)
    }
    private func setAttribute(_ url: URL, name: String, data: Data) throws {
        let result = data.withUnsafeBytes { setxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw POSIXError(.EIO) }
    }
    private func attribute(_ url: URL, name: String) throws -> Data {
        let count = getxattr(url.path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard count >= 0 else { throw POSIXError(.EIO) }
        var data = Data(count: count)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard read == count else { throw POSIXError(.EIO) }
        return data
    }
    private func aclText(_ url: URL) throws -> String {
        guard let acl = acl_get_link_np(url.path, ACL_TYPE_EXTENDED) else {
            let code = errno
            if code == ENOENT { return "" }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var count = 0
        guard let text = acl_to_text(acl, &count) else { throw POSIXError(.EIO) }
        defer { acl_free(UnsafeMutableRawPointer(text)) }
        return String(cString: text)
    }
}
