import Foundation
import XCTest
@testable import StorageCleanerMac

/// Batch 3a: the administrator password is requested only where it can help:
/// a POSIX permission code or a lone Cocoa 513 (the field receipt for an
/// installer-owned app), a bundle or folder this user really cannot write, a
/// request the helper's policy accepts, and no lock flag the helper refuses.
/// Fixtures only: no real folder permissions, Trash or privileged helper.
final class UninstallAuthorizationTests: XCTestCase {
    private let appPath = "/Applications/Fixture.app"

    private func refusal(posix code: Int32?) -> NSError {
        let underlying = code.map { [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int($0))] }
        return NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: underlying ?? [:])
    }

    private func decision(_ error: Error, unwritable: Set<String>, helper: UninstallHelperVerdict = .accepts,
                          protection: UninstallBundleProtection = .none) -> UninstallAuthorizationDecision {
        UninstallAuthorizationDecision.evaluate(error, applicationPath: appPath,
                                                isWritable: { !unwritable.contains($0) },
                                                protection: { _ in protection }, helperVerdict: { helper })
    }

    /// Refines card item 2 (main session decision): the field receipt in
    /// docs/2.0.0/UNINSTALL-513-20260925.md holds only Cocoa 513 for an
    /// installer-owned /Applications app, exactly what the helper is for.
    func testLoneCocoa513AuthorizesOnlyWhenTheBundleOrItsFolderIsNotWritable() {
        let lone = refusal(posix: nil)
        XCTAssertTrue(UninstallErrorEvidence.isPermissionDenied(lone))
        XCTAssertTrue(UninstallErrorEvidence.isLoneWriteRefusal(lone))
        XCTAssertFalse(UninstallErrorEvidence.hasPOSIXPermissionDenial(lone))
        // Installer-owned bundle in an admin-writable /Applications.
        XCTAssertEqual(decision(lone, unwritable: [appPath]), .offer)
        // Standard user: /Applications itself is read-only.
        XCTAssertEqual(decision(lone, unwritable: ["/Applications"]), .offer)
        // Both writable: file permissions are not the obstacle; guidance only.
        XCTAssertEqual(decision(lone, unwritable: []), .systemRefused)
    }

    func testOtherCocoaRefusalsNeverAskForAPassword() {
        // 513 over a read-only volume or another domain is not a permission
        // problem administrator rights can fix, even on a read-only folder.
        let readOnlyVolume = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EROFS))])
        let otherDomain = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -54)])
        for error in [readOnlyVolume, otherDomain] {
            XCTAssertFalse(UninstallErrorEvidence.isLoneWriteRefusal(error))
            XCTAssertEqual(decision(error, unwritable: ["/Applications", appPath]), .systemRefused)
        }
    }

    func testPOSIXDenialOffersAuthorizationOnlyForAFolderThisUserCannotWrite() {
        for code in [EACCES, EPERM] {
            for error in [refusal(posix: code), NSError(domain: NSPOSIXErrorDomain, code: Int(code))] {
                XCTAssertEqual(decision(error, unwritable: []), .systemRefused)
                XCTAssertEqual(decision(error, unwritable: ["/Applications"]), .offer)
                XCTAssertEqual(decision(error, unwritable: [appPath]), .offer)
            }
        }
    }

    func testHelperPolicyAndLockFlagsDecideBeforeAnyPrompt() {
        for error in [refusal(posix: nil), refusal(posix: EACCES)] {
            // The helper refuses the path or the bundle: no prompt, separate reasons.
            XCTAssertEqual(decision(error, unwritable: [appPath], helper: .rejectsLocation), .unsupportedLocation)
            XCTAssertEqual(decision(error, unwritable: [appPath], helper: .rejectsBundle), .protectedApp)
            // A locked bundle also fails access(W_OK), but the helper refuses it.
            XCTAssertEqual(decision(error, unwritable: [appPath], protection: .userLocked), .locked)
            XCTAssertEqual(decision(error, unwritable: [appPath], protection: .systemProtected), .protectedApp)
        }
    }

    func testOtherFailuresKeepTheirErrorAndSkipEveryCheck() {
        let decision = UninstallAuthorizationDecision.evaluate(POSIXError(.ENOSPC), applicationPath: appPath,
            isWritable: { _ in XCTFail("No permission probe for a non-permission failure"); return true },
            protection: { _ in XCTFail("No flag probe for a non-permission failure"); return .none },
            helperVerdict: { XCTFail("No policy check for a non-permission failure"); return .accepts })
        XCTAssertEqual(decision, .notRefused)
        XCTAssertNil(decision.notOfferedError(wrapping: POSIXError(.ENOSPC)))
        XCTAssertNil(UninstallAuthorizationDecision.offer.notOfferedError(wrapping: refusal(posix: EACCES)))
    }

    func testNotOfferedDiagnosticKeepsTheRefusalChainForTheReceipt() throws {
        let native = refusal(posix: EPERM)
        let cases: [(UninstallAuthorizationDecision, String, UninstallFailureReason)] = [
            (.systemRefused, "system-refused", .systemRefused), (.unsupportedLocation, "location", .unsupportedLocation),
            (.protectedApp, "protected-app", .protectedApp), (.locked, "locked", .locked)
        ]
        for (decision, name, reason) in cases {
            let wrapped = try XCTUnwrap(decision.notOfferedError(wrapping: native))
            let codes = UninstallErrorEvidence.codes(wrapped)
            XCTAssertEqual(codes, "UninstallAuthorization.not-offered.\(name):1 > NSCocoaErrorDomain:513 > NSPOSIXErrorDomain:1")
            XCTAssertTrue(UninstallErrorEvidence.isPermissionDenied(wrapped), "Must still record a refusal, not an unknown move")
            XCTAssertEqual(UninstallFailureReason(CleanFailure(code: .trashMoveRejected, detailCode: codes)), reason)
            // Guidance belongs to a refusal in place only, never to an unknown move.
            XCTAssertNil(UninstallFailureReason(CleanFailure(code: .moveOutcomeUnknown, detailCode: codes)))
        }
        XCTAssertEqual(UninstallFailureReason(CleanFailure(code: .trashMoveRejected, detailCode: "NSCocoaErrorDomain:513")),
                       .refused)
    }

    func testClientOffersAuthorizationOnlyForPathsTheHelperAccepts() throws {
        try XCTSkipIf(getuid() < 501, "The helper serves regular user accounts only")
        let user = try XCTUnwrap(getpwuid(getuid()))
        let home = URL(fileURLWithPath: String(cString: user.pointee.pw_dir), isDirectory: true)
        let identity = FileIdentity(deviceID: 1, inode: 2, entryKind: .directory, creationTimeNanoseconds: 3)
        func verdict(_ path: String, bundle: String = "org.fixture.app") -> UninstallHelperVerdict {
            let app = InstalledAppItem(id: path, name: "Fixture", bundleIdentifier: bundle, path: path,
                version: "1", build: "1", category: "", appDescription: "", sizeBytes: 0, source: "fixture",
                modifiedAt: nil, scanIdentity: identity, relatedPaths: [], relatedItems: [], status: .installed)
            return AuthorizedApplicationMover.helperVerdict(
                AuthorizedApplicationMover.request(for: app, identity: identity, sessionID: UUID(), home: home))
        }
        XCTAssertEqual(verdict("/Applications/Fixture.app"), .accepts)
        XCTAssertEqual(verdict(home.appendingPathComponent("Applications/Fixture.app").path), .accepts)
        // The client used to offer authorization for any refused app path,
        // although the helper only accepts these two folders' direct children.
        for nested in ["/Applications/Utilities/Fixture.app", "/Applications/Setapp/Fixture.app",
                       home.appendingPathComponent("Applications/Games/Fixture.app").path,
                       home.appendingPathComponent("Library/Caches/Fixture.app").path] {
            XCTAssertEqual(verdict(nested), .rejectsLocation, nested)
        }
        // Bundles the helper never moves are reported as such, not as a location problem.
        for bundle in ["com.apple.fixture", "Com.Apple.Fixture", "", "com.local.StorageCleanerMac.beta"] {
            XCTAssertEqual(verdict("/Applications/Fixture.app", bundle: bundle), .rejectsBundle, bundle)
        }
        XCTAssertEqual(verdict("/Applications/Setapp/Fixture.app", bundle: "com.apple.fixture"), .rejectsLocation)
    }

    func testLockedBundleIsReportedLikeTheHelperSeesIt() throws {
        let fm = FileManager.default
        let root = TestFileSystem.uniqueOperationRoot("SCM-UninstallLock")
        TestFileSystem.registerCleanup(of: root, for: self)
        let bundle = root.appendingPathComponent("Locked.app", isDirectory: true)
        try fm.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        defer {
            _ = chflags(bundle.path, 0)
            TestFileSystem.remove(root)
        }
        XCTAssertEqual(UninstallBundleProtection.of(bundle.path), .none)
        XCTAssertEqual(chflags(bundle.path, UInt32(UF_IMMUTABLE)), 0, "Owner can lock the fixture")
        XCTAssertEqual(UninstallBundleProtection.of(bundle.path), .userLocked)
        // access(W_OK) also fails, so without the flag check a password would be asked for nothing.
        XCTAssertFalse(UninstallAuthorizationEnvironment.live.isWritable(bundle.path))
        let decision = UninstallAuthorizationDecision.evaluate(refusal(posix: EPERM), applicationPath: bundle.path,
            isWritable: UninstallAuthorizationEnvironment.live.isWritable,
            protection: UninstallAuthorizationEnvironment.live.protection, helperVerdict: { .accepts })
        XCTAssertEqual(decision, .locked)
        XCTAssertEqual(chflags(bundle.path, 0), 0)
        XCTAssertEqual(UninstallBundleProtection.of(bundle.path), .none)
    }

    func testAuthorizedRequestUsesTheSameTrashDestinationTheMoveExpects() {
        let identity = FileIdentity(deviceID: 1, inode: 2, entryKind: .directory, creationTimeNanoseconds: 3)
        let session = UUID()
        let app = InstalledAppItem(id: appPath, name: "Fixture", bundleIdentifier: "org.fixture.app", path: appPath,
            version: "1", build: "1", category: "", appDescription: "", sizeBytes: 0, source: "fixture",
            modifiedAt: nil, scanIdentity: identity, relatedPaths: [], relatedItems: [], status: .installed)
        let request = AuthorizedApplicationMover.request(for: app, identity: identity, sessionID: session,
                                                         home: URL(fileURLWithPath: "/Users/fixture"))
        XCTAssertEqual(request.trashPath, "/Users/fixture/.Trash/Fixture-\(session.uuidString).app")
        XCTAssertEqual(request.direction, .trash)
        XCTAssertEqual(request.applicationPath, appPath)
        XCTAssertEqual(request.inode, 2)
    }
}

// MARK: - Execution with an isolated fixture application

extension UninstallAuthorizationTests {
    private struct AppFixture {
        let root: URL
        let trash: URL
        let app: InstalledAppItem
        let journal: CleanupReportJournal

        init() throws {
            let fm = FileManager.default
            root = TestFileSystem.uniqueOperationRoot("SCM-UninstallAuthorization")
            trash = root.appendingPathComponent("fixture-trash")
            journal = CleanupReportJournal(directory: root.appendingPathComponent("receipts"))
            do {
                try fm.createDirectory(at: trash, withIntermediateDirectories: true)
                let url = root.appendingPathComponent("Fixture.app", isDirectory: true)
                let contents = url.appendingPathComponent("Contents", isDirectory: true)
                try fm.createDirectory(at: contents, withIntermediateDirectories: true)
                let bundleID = "org.storagecleaner.fixture." + UUID().uuidString.lowercased()
                let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleName": "Fixture",
                                           "CFBundleShortVersionString": "1.0", "CFBundleVersion": "1"]
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: contents.appendingPathComponent("Info.plist"))
                app = InstalledAppItem(id: url.path, name: "Fixture", bundleIdentifier: bundleID, path: url.path,
                    version: "1.0", build: "1", category: "", appDescription: "", sizeBytes: 0, source: "fixture",
                    modifiedAt: nil, scanIdentity: AppUninstallService.uninstallFileIdentity(at: url.path),
                    relatedPaths: [], relatedItems: [], status: .installed)
            } catch {
                TestFileSystem.remove(root)
                throw error
            }
        }

        func remove() { TestFileSystem.remove(root) }
    }

    actor Attempts {
        private(set) var count = 0
        func record() { count += 1 }
    }

    /// Never reaches the real helper: either refuses or moves within the fixture.
    private func environment(helperVerdict: @escaping @Sendable (InstalledAppItem, FileIdentity, UUID) -> UninstallHelperVerdict = { _, _, _ in .accepts },
                             unwritable: Bool, attempts: Attempts, trash: URL,
                             protection: @escaping @Sendable (String) -> UninstallBundleProtection = { _ in .none }) -> UninstallAuthorizationEnvironment {
        UninstallAuthorizationEnvironment(helperVerdict: helperVerdict, isWritable: { _ in !unwritable },
            protection: protection, move: { app, _, _, beforeMove in
                await attempts.record()
                try await beforeMove()
                let destination = trash.appendingPathComponent(URL(fileURLWithPath: app.path).lastPathComponent)
                try FileManager.default.moveItem(at: URL(fileURLWithPath: app.path), to: destination)
                return destination
            })
    }

    /// For runs that must never reach authorization: records and refuses.
    private func refusingEnvironment(_ attempts: Attempts) -> UninstallAuthorizationEnvironment {
        UninstallAuthorizationEnvironment(helperVerdict: { _, _, _ in .accepts }, isWritable: { _ in true },
            protection: { _ in .none }, move: { _, _, _, _ in
                await attempts.record()
                throw POSIXError(.EPERM)
            })
    }

    private func uninstall(_ fixture: AppFixture, refusal posixCode: Int32?,
                           environment: UninstallAuthorizationEnvironment) async throws -> CleanReport {
        let plan = try UninstallPlan(app: fixture.app, selectedPaths: [], homeDirectory: fixture.root)
        let coordinator = HeavyWorkCoordinator()
        let journal = fixture.journal
        let result = try await coordinator.withLease(owner: .cleanup) { lease in
            await AppUninstallService.execute(plan, coordinator: coordinator, lease: lease,
                recycle: { _ in
                    let underlying = posixCode.map { [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int($0))] }
                    throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError, userInfo: underlying ?? [:])
                },
                authorization: environment,
                persist: { try journal.checkpoint($0, expectedIdentities: $1) })
        }
        return try XCTUnwrap(result.report)
    }

    private struct UnexpectedOutcome: Error {}

    private func failure(_ report: CleanReport, file: StaticString = #filePath, line: UInt = #line) throws -> CleanFailure {
        guard case .failed(let failure) = try XCTUnwrap(report.items.first).outcome else {
            XCTFail("Expected the application row to be refused in place", file: file, line: line)
            throw UnexpectedOutcome()
        }
        return failure
    }

    func testLoneCocoa513OnWritableFoldersRecordsGuidanceWithoutAPrompt() async throws {
        let fixture = try AppFixture(); defer { fixture.remove() }
        let attempts = Attempts()
        let report = try await uninstall(fixture, refusal: nil, environment: environment(
            unwritable: false, attempts: attempts, trash: fixture.trash))
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 0, "No password prompt for a refusal administrator rights cannot lift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
        let failure = try failure(report)
        XCTAssertEqual(failure.code, .trashMoveRejected)
        XCTAssertEqual(failure.detailCode, "UninstallAuthorization.not-offered.system-refused:1 > NSCocoaErrorDomain:513")
        XCTAssertEqual(UninstallFailureReason(failure), .systemRefused)
        guard case .failed(let saved) = try XCTUnwrap(fixture.journal.load().first?.items.first).outcome else {
            return XCTFail("The refusal must be saved in the receipt")
        }
        XCTAssertEqual(saved, failure)
    }

    func testPOSIXRefusalOnWritableFoldersIsNotOfferedAPassword() async throws {
        let fixture = try AppFixture(); defer { fixture.remove() }
        let attempts = Attempts()
        let report = try await uninstall(fixture, refusal: EPERM, environment: environment(
            unwritable: false, attempts: attempts, trash: fixture.trash))
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 0)
        XCTAssertEqual(try failure(report).code, .trashMoveRejected)
        XCTAssertEqual(UninstallFailureReason(try failure(report)), .systemRefused)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    func testLocationTheHelperRefusesIsNotOfferedAPassword() async throws {
        let fixture = try AppFixture(); defer { fixture.remove() }
        let attempts = Attempts()
        // 临时家目录中的嵌套应用也不属于真实 /Applications 或用户 Applications 的直接子项；
        // 继续经过 live helperVerdict 验证拒绝位置，不能把拒绝替换成假实现。
        let report = try await uninstall(fixture, refusal: EACCES, environment: environment(
            helperVerdict: UninstallAuthorizationEnvironment.live.helperVerdict, unwritable: true,
            attempts: attempts, trash: fixture.trash))
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 0)
        let failure = try failure(report)
        XCTAssertEqual(failure.code, .trashMoveRejected)
        XCTAssertEqual(failure.detailCode,
                       "UninstallAuthorization.not-offered.location:1 > NSCocoaErrorDomain:513 > NSPOSIXErrorDomain:13")
        XCTAssertEqual(UninstallFailureReason(failure), .unsupportedLocation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }

    /// After enabling App Management the user retries: only the refused
    /// application runs, in a new receipt, and the review merges both.
    func testRetryAfterARefusedApplicationRunsOnlyItAndMergesTheResult() async throws {
        let fixture = try AppFixture(); defer { fixture.remove() }
        let attempts = Attempts()
        let first = try await uninstall(fixture, refusal: nil, environment: environment(
            unwritable: false, attempts: attempts, trash: fixture.trash))
        XCTAssertTrue(AppUninstallService.canRetryUninstall(first, applicationPath: fixture.app.path,
                                                           applicationAlreadyMoved: false))
        let plan = try UninstallPlan(app: fixture.app, selectedPaths: [], homeDirectory: fixture.root)
        let coordinator = HeavyWorkCoordinator()
        let journal = fixture.journal, trash = fixture.trash
        let refusing = refusingEnvironment(attempts)
        let retry = try await coordinator.withLease(owner: .cleanup) { lease in
            await AppUninstallService.execute(plan, coordinator: coordinator, lease: lease, retrying: first,
                recycle: { source in
                    let destination = trash.appendingPathComponent(source.lastPathComponent)
                    try FileManager.default.moveItem(at: source, to: destination)
                    return destination
                },
                authorization: refusing,
                persist: { try journal.checkpoint($0, expectedIdentities: $1) })
        }.report
        let second = try XCTUnwrap(retry)
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 0)
        XCTAssertEqual(second.items.map(\.sourcePath), [fixture.app.path])
        XCTAssertNotEqual(second.planID, first.planID)
        let merged = try XCTUnwrap(UninstallReviewResult(receipts: [first, second])?.display)
        XCTAssertEqual(merged.items.count, 1)
        XCTAssertEqual(merged.restorableReceipts.map(\.originalPath), [fixture.app.path])
        XCTAssertFalse(AppUninstallService.canRetryUninstall(merged, applicationPath: fixture.app.path,
                                                            applicationAlreadyMoved: true))
        XCTAssertEqual(try fixture.journal.load().count, 2, "Both receipts stay in the journal")
    }

    func testReadOnlyFolderOffersAuthorizationOnceAndRecordsTheVerifiedMove() async throws {
        for posixCode in [EACCES, nil] as [Int32?] {
            try await assertAuthorizedMove(refusal: posixCode)
        }
    }

    /// The field case (lone Cocoa 513, installer-owned bundle) and a POSIX denial.
    private func assertAuthorizedMove(refusal posixCode: Int32?, file: StaticString = #filePath, line: UInt = #line) async throws {
        let fixture = try AppFixture(); defer { fixture.remove() }
        let attempts = Attempts()
        let report = try await uninstall(fixture, refusal: posixCode, environment: environment(
            unwritable: true, attempts: attempts, trash: fixture.trash))
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 1, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.app.path), file: file, line: line)
        XCTAssertEqual(report.restorableReceipts.map(\.originalPath), [fixture.app.path], file: file, line: line)
        XCTAssertEqual(try fixture.journal.load().first?.restorableReceipts.count, 1, file: file, line: line)
    }

    /// uchg makes access(W_OK) fail, but the helper refuses locked bundles:
    /// no password, and the receipt says how to unlock it.
    func testLockedApplicationIsNotOfferedAPassword() async throws {
        let fixture = try AppFixture(); defer { fixture.remove() }
        XCTAssertEqual(chflags(fixture.app.path, UInt32(UF_IMMUTABLE)), 0, "Owner can lock the fixture")
        defer { _ = chflags(fixture.app.path, 0) }
        let attempts = Attempts()
        let report = try await uninstall(fixture, refusal: EPERM, environment: environment(
            unwritable: true, attempts: attempts, trash: fixture.trash,
            protection: UninstallAuthorizationEnvironment.live.protection))
        let attemptCount = await attempts.count
        XCTAssertEqual(attemptCount, 0)
        let failure = try failure(report)
        XCTAssertEqual(failure.code, .trashMoveRejected)
        XCTAssertEqual(failure.detailCode,
                       "UninstallAuthorization.not-offered.locked:1 > NSCocoaErrorDomain:513 > NSPOSIXErrorDomain:1")
        XCTAssertEqual(UninstallFailureReason(failure), .locked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.app.path))
    }
}
