import Foundation
import XCTest
import FileOperationShared

final class FileOperationBoundaryTests: XCTestCase {
    private func request(app: String = "/Applications/Fixture.app", trash: String = "/Users/fixture/.Trash/Fixture-test.app",
                         bundle: String = "org.fixture.app", direction: AuthorizedFileMove.Direction = .trash) -> AuthorizedFileMove {
        AuthorizedFileMove(sessionID: UUID(), direction: direction, applicationPath: app, trashPath: trash,
            bundleIdentifier: bundle, version: "1", build: "1", device: 1, inode: 2, birthNanoseconds: 3)
    }
    func testBothDirectionsUseSameNarrowAuthorizedRoots() {
        for direction: AuthorizedFileMove.Direction in [.trash, .restore] {
            XCTAssertTrue(FileOperationPathPolicy.permits(request(direction: direction), home: "/Users/fixture", uid: 501))
            XCTAssertTrue(FileOperationPathPolicy.permits(request(app: "/Users/fixture/Applications/Fixture.app", direction: direction), home: "/Users/fixture", uid: 501))
        }
    }
    func testTraversalAndProtectedRootsAreRejected() {
        for path in ["/System/Applications/Fixture.app", "/Library/Fixture.app", "/Applications/subdir/Fixture.app",
                     "/Applications/../Applications/Fixture.app", "/Applications/./Fixture.app", "/Applications/Fixture.app/",
                     "/Users/other/Applications/Fixture.app", "/Applications/Fixture", "relative.app", "/Applications/Fixture\0.app"] {
            XCTAssertFalse(FileOperationPathPolicy.permits(request(app: path), home: "/Users/fixture", uid: 501), path)
        }
    }
    func testCannotMoveIntoArbitraryDestinationOrOtherUsersTrash() {
        for path in ["/Applications/Target.app", "/Users/other/.Trash/Fixture.app", "/Users/fixture/.Trash/subdir/Fixture.app",
                     "/Users/fixture/.Trash/../Fixture.app", "/tmp/Fixture.app", "/Users/fixture/.Trash/file"] {
            XCTAssertFalse(FileOperationPathPolicy.permits(request(trash: path), home: "/Users/fixture", uid: 501), path)
        }
    }
    func testProtectedBundlesAndRootCallerAreRejected() {
        for bundle in ["com.apple.Safari", "Com.Apple.Safari", "com.local.StorageCleanerMac.beta", ""] {
            XCTAssertFalse(FileOperationPathPolicy.permits(request(bundle: bundle), home: "/Users/fixture", uid: 501))
        }
        XCTAssertFalse(FileOperationPathPolicy.permits(request(), home: "/Users/fixture", uid: 0))
    }
    func testRequestRoundTripKeepsSessionAndIdentity() throws {
        let original = request()
        let decoded = try JSONDecoder().decode(AuthorizedFileMove.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(original.sessionID, decoded.sessionID)
        XCTAssertEqual(original.requestID, decoded.requestID)
        XCTAssertEqual(original.birthNanoseconds, decoded.birthNanoseconds)
        XCTAssertEqual(original.expiresAt, decoded.expiresAt)
    }
}

import Security
@testable import StorageCleanerMac

extension FileOperationBoundaryTests {
    func testImportedPreauthorizationRequiresActualSystemAuthentication() throws {
        var requested = false
        try FileOperationAuthorization.checkImportedRights { flags in
            XCTAssertTrue(flags.contains(.extendRights))
            XCTAssertTrue(flags.contains(.interactionAllowed))
            XCTAssertFalse(flags.contains(.preAuthorize))
            XCTAssertFalse(flags.contains(.partialRights))
            requested = true
            return flags.contains(.extendRights) ? errAuthorizationSuccess : errAuthorizationDenied
        }
        XCTAssertTrue(requested)
    }

    func testAuthorizationFailuresKeepOSStatusAndCannotProceedToMove() {
        for status in [errAuthorizationDenied, errAuthorizationCanceled, errAuthorizationInvalidRef, errAuthorizationInternal] {
            var moved = false
            do {
                try FileOperationAuthorization.checkImportedRights { _ in status }
                moved = true
                XCTFail("Must not reach the filesystem after failed authorization")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSOSStatusErrorDomain)
                XCTAssertEqual((error as NSError).code, Int(status))
            }
            XCTAssertFalse(moved)
        }
    }

    func testRepliesKeepFailureStageAndDecodeLegacyReply() throws {
        for stage: AuthorizedFileFailureStage in [.request, .importAuthorization, .checkAuthorization, .commit, .fileMove] {
            let reply = AuthorizedFileReply(requestID: UUID(), errorDomain: NSOSStatusErrorDomain,
                                            errorCode: Int(errAuthorizationDenied), failureStage: stage)
            let decoded = try JSONDecoder().decode(AuthorizedFileReply.self, from: JSONEncoder().encode(reply))
            XCTAssertEqual(decoded.failureStage, stage)
            XCTAssertEqual(decoded.errorCode, Int(errAuthorizationDenied))
        }
        let legacy = Data("{\"requestID\":\"\(UUID().uuidString)\",\"errorDomain\":\"NSPOSIXErrorDomain\",\"errorCode\":13}".utf8)
        XCTAssertNil(try JSONDecoder().decode(AuthorizedFileReply.self, from: legacy).failureStage)
    }

    func testWorkerFilesystemFailureIsNotReportedAsDeniedAuthorization() {
        let original = NSError(domain: NSCocoaErrorDomain, code: 513)
        let filesystem = NSError(domain: NSPOSIXErrorDomain, code: 13)
        let worker = NSError(domain: "FileOperationHelper.fileMove", code: 1,
                             userInfo: [NSUnderlyingErrorKey: filesystem])
        let result = UninstallAuthorizationFailure.wrap(worker, nativeError: original)
        XCTAssertEqual(result.domain, "UninstallAuthorization.helper-failed")
        XCTAssertEqual(UninstallErrorEvidence.chain(result).map(\.domain), [
            "UninstallAuthorization.helper-failed", "FileOperationHelper.fileMove", NSPOSIXErrorDomain, NSCocoaErrorDomain
        ])
    }

    func testActualAuthorizationCancellationAndDenialRemainDistinct() {
        let original = NSError(domain: NSCocoaErrorDomain, code: 513)
        for (status, reason) in [(errAuthorizationDenied, "authorization-denied"),
                                 (errAuthorizationCanceled, "authorization-cancelled"),
                                 (errAuthorizationInternal, "authorization-failed")] {
            let result = UninstallAuthorizationFailure.wrap(NSError(domain: NSOSStatusErrorDomain, code: Int(status)), nativeError: original)
            XCTAssertEqual(result.domain, "UninstallAuthorization." + reason)
            XCTAssertEqual(UninstallErrorEvidence.chain(result)[1].code, Int(status))
        }
    }
}


extension FileOperationBoundaryTests {
    func testClientPreflightNeverReplacesHelperAuthentication() throws {
        try FileOperationAuthorization.requestClientRights { flags in
            XCTAssertTrue(flags.contains(.interactionAllowed))
            XCTAssertTrue(flags.contains(.extendRights))
            XCTAssertTrue(flags.contains(.preAuthorize))
            return errAuthorizationSuccess
        }
        // The real right can still be rejected after a successful preflight.
        XCTAssertThrowsError(try FileOperationAuthorization.checkImportedRights { _ in errAuthorizationDenied })
    }

    func testClientDenialCannotBeExportedAsSuccessfulAuthorization() {
        XCTAssertThrowsError(try FileOperationAuthorization.requestClientRights { _ in errAuthorizationDenied }) { error in
            XCTAssertEqual((error as NSError).code, Int(errAuthorizationDenied))
        }
    }
}


extension FileOperationBoundaryTests {
    func testPreparedOperationRequiresApprovalAndCanOnlyCommitOnce() throws {
        let value = request()
        var gate = AuthorizedFileCommitGate()
        XCTAssertThrowsError(try gate.consume(value))
        try gate.approve(value)
        try gate.consume(value)
        XCTAssertThrowsError(try gate.consume(value))
    }

    func testPreparedOperationBindsEveryRequestField() throws {
        let value = request()
        let original = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        let changes: [String: Any] = ["sessionID": UUID().uuidString, "requestID": UUID().uuidString,
            "applicationPath": "/Applications/Other.app", "trashPath": "/Users/fixture/.Trash/Other.app",
            "direction": "restore", "bundleIdentifier": "org.other.app", "version": "2", "build": "3",
            "device": 9, "inode": 9, "birthNanoseconds": 9, "expiresAt": 1]
        for (key, changed) in changes {
            var json = original; json[key] = changed
            let replacement = try JSONDecoder().decode(AuthorizedFileMove.self, from: JSONSerialization.data(withJSONObject: json))
            var gate = AuthorizedFileCommitGate()
            try gate.approve(value)
            XCTAssertThrowsError(try gate.consume(replacement), key)
            XCTAssertThrowsError(try gate.consume(value), "Rejected commit must consume the gate")
        }
    }

    func testCancelledOrExpiredPreparationNeverCommits() throws {
        let value = request(); let now = Date()
        var gate = AuthorizedFileCommitGate()
        try gate.approve(value, now: now)
        gate.invalidate() // cancellation/disconnection discards the pending operation
        XCTAssertThrowsError(try gate.consume(value, now: now))
        try gate.approve(value, now: now)
        XCTAssertThrowsError(try gate.consume(value, now: now.addingTimeInterval(15)))
        XCTAssertThrowsError(try gate.approve(value, now: value.expiresAt))
        XCTAssertThrowsError(try gate.consume(value))
    }
}


extension FileOperationBoundaryTests {
    func testInteractiveAuthenticationWaitDoesNotConsumeCommitWindow() throws {
        let value = request()
        let received = value.expiresAt.addingTimeInterval(-60)
        let approved = received.addingTimeInterval(180)
        var gate = AuthorizedFileCommitGate()
        try gate.approve(value, receivedAt: received, now: approved)
        XCTAssertEqual(try gate.consume(value, now: approved.addingTimeInterval(1)), approved.addingTimeInterval(15))
        XCTAssertThrowsError(try gate.consume(value, now: approved.addingTimeInterval(2)))
        try gate.approve(value, receivedAt: received, now: approved)
        XCTAssertThrowsError(try gate.consume(value, now: approved.addingTimeInterval(15)))
        XCTAssertThrowsError(try gate.approve(value, receivedAt: value.expiresAt, now: approved))
    }
}
