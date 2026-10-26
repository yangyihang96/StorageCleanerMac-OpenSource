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

extension FileOperationBoundaryTests {
    /// D99: the installed 2.0.0 helper's move function calls `fstatat` with
    /// `AT_SYMLINK_NOFOLLOW`, `openat` with `O_CLOEXEC | O_DIRECTORY | O_NOFOLLOW`
    /// and `renameatx_np` with `RENAME_EXCL` (evidence `ev_4567415c`, that
    /// binary only). This keeps the source on them. Nothing in `RestrictedMove`
    /// is compiled conditionally. Paths are opened from `/` one component at a
    /// time without following links, the flags written as a plain `|` of known
    /// names. Each function opens with its first guard, and every guard of
    /// `directory()` and `perform` is pinned in order, condition and else
    /// branch exactly (layout and comments aside, literal text as written), so
    /// weakening a check, moving it into a block, putting a statement before
    /// the first one or returning instead of throwing fails. No directory is
    /// opened before the path policy, nor the app before its identity is
    /// checked; the identity is checked again after Info.plist is read and
    /// matched, right before the one exclusive rename, the only change anywhere
    /// in the helper's main file (app updates live in another file). Calls are
    /// found in lexed code, plain, escaped (`` `unlink` ``) or qualified by
    /// capitalized names (`Darwin.`). Text, not data flow: the values a check
    /// reads, aliases, function values, other files and interfaces outside the
    /// list are not followed.
    func testRestrictedMoveFollowsNoLinksAndOnlyRenamesExclusively() throws {
        let raw = try String(contentsOf: SwiftSourceScanning.projectRoot
            .appendingPathComponent("Sources/FileOperationHelper/main.swift"), encoding: .utf8)
        // An escaped name reads as the plain one; a scalar for a scalar keeps the offsets of `raw`.
        let code = String(String.UnicodeScalarView(SwiftSourceScanning.code(raw).unicodeScalars.map { $0 == "`" ? " " : $0 }))
        let enumStart = try XCTUnwrap(code.range(of: "private enum RestrictedMove")).lowerBound
        let move = try XCTUnwrap(SwiftSourceScanning.bodyRange(from: enumStart, in: code))
        XCTAssertNil(code[move].range(of: #"(?m)^[ \t]*#(if|elseif|else|endif)\b"#, options: .regularExpression),
                     "every check in RestrictedMove is compiled")
        func body(_ declaration: String) throws -> Range<String.Index> {
            let start = try XCTUnwrap(code.range(of: declaration, range: move), declaration).lowerBound
            return try XCTUnwrap(SwiftSourceScanning.bodyRange(from: start, in: code), declaration)
        }
        func calls(_ function: String, in range: Range<String.Index>) throws -> [(start: String.Index, arguments: [String])] {
            try Self.calls(to: function, in: range, of: code, raw: raw)
        }
        /// The flags of a plain `|` of known names; nil for any other expression.
        func flags(_ argument: String?) -> Set<String>? {
            let names = (argument ?? "").split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let known: Set = ["O_RDONLY", "O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK", "O_CLOEXEC"]
            return names.allSatisfy { known.contains($0) } ? Set(names) : nil
        }
        /// Only whitespace in lexed code, comments included, comes before the first guard.
        func startsWithGuard(_ range: Range<String.Index>, _ checks: [(text: String, range: Range<String.Index>)]) -> Bool {
            guard let first = checks.first else { return false }
            return code[range.lowerBound..<first.range.lowerBound].allSatisfy(\.isWhitespace)
        }

        // Only the root is opened by path; every other open names one component of a held directory.
        let directory = try body("static func directory(")
        let pathChecks = try Self.guards(in: directory, of: code, raw: raw)
        XCTAssertTrue(startsWithGuard(directory, pathChecks), "directory() starts with its path check")
        XCTAssertEqual(pathChecks.map { $0.text }, [
            #"path.hasPrefix("/"),URL(fileURLWithPath:path).standardizedFileURL.path==path,"#
                + #"!path.split(separator:"/").contains("..") else throwPOSIXError(.EINVAL)"#,
            "fd>=0 else throwPOSIXError(.EIO)",
        ])
        XCTAssertTrue(SwiftSourceScanning.compactKeepingLiterals(Self.text(of: directory, in: code, from: raw))
            .contains(#"forcomponentinpath.split(separator:"/"){letnext=openat(fd,String(component),"#))
        XCTAssertEqual(try calls("open", in: move).count, 1)
        let roots = try calls("open", in: directory).map { $0.arguments }
        XCTAssertEqual(roots.map { $0.first }, [#""/""#])
        XCTAssertTrue(flags(roots.first?.last)?.isSuperset(of: ["O_RDONLY", "O_DIRECTORY", "O_CLOEXEC"]) == true, "\(roots)")
        let opens = try calls("openat", in: move).map { $0.arguments }
        XCTAssertEqual(opens.count, 4, "\(opens)")
        for arguments in opens {
            XCTAssertEqual(arguments.count, 3, "\(arguments)")
            XCTAssertTrue(["String(component)", "source.lastPathComponent", #""Contents""#, #""Info.plist""#]
                .contains(arguments.dropFirst().first ?? ""), "\(arguments)")
            XCTAssertTrue(flags(arguments.last)?.isSuperset(of: ["O_RDONLY", "O_NOFOLLOW", "O_CLOEXEC"]) == true, "\(arguments)")
        }
        XCTAssertEqual(try calls("fstatat", in: move).map { $0.arguments }, [
            ["sourceFD", "source.lastPathComponent", "&info", "AT_SYMLINK_NOFOLLOW"],
            ["sourceFD", "source.lastPathComponent", "&final", "AT_SYMLINK_NOFOLLOW"],
        ])
        XCTAssertEqual(try calls("renameatx_np", in: code.startIndex..<code.endIndex).map { $0.arguments }, [
            ["sourceFD", "source.lastPathComponent", "destinationFD", "destination.lastPathComponent", "UInt32(RENAME_EXCL)"],
        ])

        // Every check in `perform`, in this order, is a top-level guard that throws.
        let perform = try body("static func perform(")
        let checks = try Self.guards(in: perform, of: code, raw: raw)
        XCTAssertTrue(startsWithGuard(perform, checks), "perform starts with its caller check")
        XCTAssertEqual(checks.map { $0.text }, [
            "uid>=501,Date()<authorizedUntil,authorizedUntil.timeIntervalSinceNow<=16,letuser=getpwuid(uid)"
                + " else throwPOSIXError(.EPERM)",
            "FileOperationPathPolicy.permits(request,home:home,uid:uid) else throwPOSIXError(.EPERM)",
            "fstat(trashParent,&trashInfo)==0,fstat(appParent,&appInfo)==0,trashInfo.st_uid==uid,"
                + "trashInfo.st_mode&0o077==0,trashInfo.st_dev==appInfo.st_dev else throwPOSIXError(.EPERM)",
            "fstatat(sourceFD,source.lastPathComponent,&info,AT_SYMLINK_NOFOLLOW)==0"
                + " else throwPOSIXError(POSIXErrorCode(rawValue:errno)??.EIO)",
            "info.st_mode&S_IFMT==S_IFDIR,UInt64(info.st_dev)==request.device,UInt64(info.st_ino)==request.inode,"
                + "birth==request.birthNanoseconds,FileProtectionFlags.lock(info.st_flags)==.none"
                + " else throwPOSIXError(.EPERM)",
            "appFD>=0 else throwPOSIXError(.EIO)",
            "contents>=0 else throwPOSIXError(.EINVAL)",
            "plistFD>=0 else throwPOSIXError(.EINVAL)",
            "fstat(plistFD,&plistInfo)==0,plistInfo.st_mode&S_IFMT==S_IFREG,plistInfo.st_size>=0,"
                + "plistInfo.st_size<=1_048_576 else close(plistFD);throwPOSIXError(.EINVAL)",
            "letdata=tryhandle.read(upToCount:1_048_577),data.count<=1_048_576,"
                + "letplist=tryPropertyListSerialization.propertyList(from:data,format:nil)as?[String:Any],"
                + #"plist["CFBundleIdentifier"]as?String==request.bundleIdentifier,"#
                + #"(plist["CFBundleShortVersionString"]as?String??"")==request.version,"#
                + #"(plist["CFBundleVersion"]as?String??"")==request.build else throwPOSIXError(.EINVAL)"#,
            "NSRunningApplication.runningApplications(withBundleIdentifier:request.bundleIdentifier).isEmpty"
                + " else throwPOSIXError(.EBUSY)",
            "fstatat(sourceFD,source.lastPathComponent,&final,AT_SYMLINK_NOFOLLOW)==0,final.st_dev==info.st_dev,"
                + "final.st_ino==info.st_ino,final.st_birthtimespec.tv_sec==info.st_birthtimespec.tv_sec,"
                + "final.st_birthtimespec.tv_nsec==info.st_birthtimespec.tv_nsec,Date()<authorizedUntil"
                + " else throwPOSIXError(.ESTALE)",
            "renameatx_np(sourceFD,source.lastPathComponent,destinationFD,destination.lastPathComponent,"
                + "UInt32(RENAME_EXCL))==0 else throwPOSIXError(POSIXErrorCode(rawValue:errno)??.EIO)",
        ])

        // No directory is opened before the path policy, nor the app before its identity is checked;
        // every open precedes the final check, and the rename follows it directly.
        func check(_ prefix: String) throws -> Range<String.Index> {
            try XCTUnwrap(checks.first { $0.text.hasPrefix(prefix) }, prefix).range
        }
        let policy = try check("FileOperationPathPolicy.permits("), identity = try check("info.st_mode&S_IFMT==S_IFDIR,")
        let final = try check("fstatat(sourceFD,source.lastPathComponent,&final,"), rename = try check("renameatx_np(")
        let directories = try calls("directory", in: perform).map { $0.start }
        XCTAssertEqual(directories.count, 2)
        XCTAssertTrue(directories.allSatisfy { $0 >= policy.upperBound }, "a directory is opened before the path policy")
        let appOpens = try calls("openat", in: perform).map { $0.start }
        XCTAssertEqual(appOpens.count, 3)
        XCTAssertTrue(appOpens.allSatisfy { $0 >= identity.upperBound && $0 < final.lowerBound },
                      "the app is opened before its identity is checked or after the final check")
        XCTAssertTrue(final.upperBound <= rename.lowerBound && code[final.upperBound..<rename.lowerBound].allSatisfy(\.isWhitespace),
                      "nothing runs between the final check and the rename")

        // Nothing else in the file changes the file system or starts a process.
        let mutation = try NSRegularExpression(pattern: Self.qualified + #"(unlink|unlinkat|rmdir|remove|rename|"#
            + #"renameat|renamex_np|renameatx_np|exchangedata|copyfile|fcopyfile|clonefile|clonefileat|fclonefileat|"#
            + #"chown|fchown|lchown|fchownat|chmod|fchmod|lchmod|fchmodat|chflags|fchflags|lchflags|mkdir|mkdirat|mkfifo|"#
            + #"symlink|symlinkat|link|linkat|truncate|ftruncate|write|pwrite|setxattr|fsetxattr|removexattr|"#
            + #"fremovexattr|utimes|futimes|utimensat|futimens|setattrlist|fsetattrlist|system|posix_spawn|"#
            + #"posix_spawnp|Process)\s*\("#
            + #"|\.\s*(removeItem|moveItem|copyItem|replaceItem|replaceItemAt|trashItem|createDirectory|createFile|"#
            + #"createSymbolicLink|linkItem|setAttributes|write)\s*\(|\b(O_CREAT|O_WRONLY|O_RDWR|O_TRUNC|O_APPEND)\b"#)
        XCTAssertEqual(mutation.matches(in: code, range: NSRange(code.startIndex..., in: code)).compactMap {
            Range($0.range, in: code).map { SwiftSourceScanning.compact(code[$0]) }
        }, ["renameatx_np("])
    }

    /// Where a call starts: no name or member access ends there; capitalized
    /// module or type names may qualify it (`Darwin.unlinkat(`).
    private static let qualified = #"(?<![\w.])(?:[A-Z]\w*\s*\.\s*)*"#

    /// Each call to `function` inside `range` of lexed `code`: where it starts,
    /// and its arguments split at top-level commas, each read from `raw` at the
    /// same offsets with `compactKeepingLiterals`.
    private static func calls(to function: String, in range: Range<String.Index>, of code: String,
                              raw: String) throws -> [(start: String.Index, arguments: [String])] {
        try NSRegularExpression(pattern: qualified + function + #"\s*\("#)
            .matches(in: code, range: NSRange(range, in: code)).map { match in
                let call = try XCTUnwrap(Range(match.range, in: code))
                var depth = 0, index = call.upperBound, start = call.upperBound, arguments: [String] = []
                while index < code.endIndex {
                    let character = code[index]
                    if depth == 0, character == "," || character == ")" {
                        arguments.append(SwiftSourceScanning.compactKeepingLiterals(text(of: start..<index, in: code, from: raw)))
                        if character == ")" { return (call.lowerBound, arguments) }
                        start = code.index(after: index)
                    } else if "([{".contains(character) {
                        depth += 1
                    } else if ")]}".contains(character) {
                        depth -= 1
                    }
                    index = code.index(after: index)
                }
                return (call.lowerBound, ["<unparsed>"])
            }
    }

    /// Each `guard` at the top level of `body` in lexed `code`, read from `raw`
    /// at the same offsets as "condition else branch" (`compactKeepingLiterals`),
    /// and the range of the whole statement.
    private static func guards(in body: Range<String.Index>, of code: String,
                               raw: String) throws -> [(text: String, range: Range<String.Index>)] {
        let otherwise = try NSRegularExpression(pattern: #"\belse\s*\{"#)
        return try NSRegularExpression(pattern: #"\bguard\b"#).matches(in: code, range: NSRange(body, in: code))
            .compactMap { match in
                let keyword = try XCTUnwrap(Range(match.range, in: code))
                let before = code[body.lowerBound..<keyword.lowerBound]
                guard before.filter({ $0 == "{" }).count == before.filter({ $0 == "}" }).count else { return nil }
                let branch = try XCTUnwrap(otherwise.firstMatch(
                    in: code, range: NSRange(keyword.upperBound..<body.upperBound, in: code)).flatMap { Range($0.range, in: code) })
                let block = try XCTUnwrap(SwiftSourceScanning.bodyRange(from: branch.lowerBound, in: code))
                let condition = text(of: keyword.upperBound..<branch.lowerBound, in: code, from: raw)
                return (SwiftSourceScanning.compactKeepingLiterals(condition) + " else "
                            + SwiftSourceScanning.compactKeepingLiterals(text(of: block, in: code, from: raw)),
                        keyword.lowerBound..<code.index(after: block.upperBound))
            }
    }

    /// The text of `source` at the same unicode scalar offsets as `range` of
    /// `code`, which `SwiftSourceScanning.code(_:)` keeps in place.
    private static func text(of range: Range<String.Index>, in code: String, from source: String) -> String {
        let scalars = code.unicodeScalars, target = source.unicodeScalars
        let start = target.index(target.startIndex, offsetBy: scalars.distance(from: scalars.startIndex, to: range.lowerBound))
        let end = target.index(start, offsetBy: scalars.distance(from: range.lowerBound, to: range.upperBound))
        return String(target[start..<end])
    }
}
