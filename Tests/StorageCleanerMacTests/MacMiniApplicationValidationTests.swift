import FanControlShared
import Foundation
import XCTest

final class MacMiniApplicationValidationTests: XCTestCase {
    func testUnchangedPathAndMtimeAvoidFullValidationAndChangedMtimeInvalidates() {
        let fixture = SignatureFixture()
        for _ in 0..<8 { XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), true) }
        XCTAssertEqual(fixture.verifications, 1)
        fixture.token = "updated"
        fixture.result = false
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), false)
        XCTAssertEqual(fixture.verifications, 2)
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "other.app"), false)
        XCTAssertEqual(fixture.verifications, 3, "Expected app identifier participates in the cache")
        let moved = MacMiniApplicationIdentity(installationPath: "/Moved.app", signingIdentity: "team:A")
        XCTAssertEqual(fixture.cache.validate(moved, identifier: "app"), false)
        XCTAssertEqual(fixture.verifications, 4)
        fixture.cache.invalidate()
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), false)
        XCTAssertEqual(fixture.verifications, 5)
    }

    func testTransientSignatureFailureIsUnknownAndNeverCached() {
        let fixture = SignatureFixture()
        fixture.result = nil
        XCTAssertNil(fixture.cache.validate(fixture.identity, identifier: "app"))
        XCTAssertNil(fixture.cache.validate(fixture.identity, identifier: "app"))
        XCTAssertEqual(fixture.verifications, 2)
        fixture.result = true
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), true)
        XCTAssertEqual(fixture.verifications, 3)
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), true)
        XCTAssertEqual(fixture.verifications, 3)
    }

    func testMissingAndUnknownMetadataDoNotReusePreviouslyTrustedResult() {
        let fixture = SignatureFixture()
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), true)
        fixture.metadata = .absentOrUnsafe
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), false)
        fixture.metadata = .unknown
        XCTAssertNil(fixture.cache.validate(fixture.identity, identifier: "app"))
        XCTAssertEqual(fixture.verifications, 1)
        fixture.metadata = nil
        fixture.result = false
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), false)
        XCTAssertEqual(fixture.verifications, 2)
    }

    func testBundleReplacementDuringValidationIsUnknownUntilStableRetry() {
        let fixture = SignatureFixture()
        fixture.changesDuringVerification = true
        XCTAssertNil(fixture.cache.validate(fixture.identity, identifier: "app"))
        fixture.changesDuringVerification = false
        XCTAssertEqual(fixture.cache.validate(fixture.identity, identifier: "app"), true)
        XCTAssertEqual(fixture.verifications, 2)
    }
}

private final class SignatureFixture {
    let identity = MacMiniApplicationIdentity(installationPath: "/Installed.app", signingIdentity: "team:A")
    var token = "original"
    var metadata: MacMiniSignatureMetadata?
    var result: Bool? = true
    var verifications = 0
    var changesDuringVerification = false
    lazy var cache = MacMiniApplicationValidation(metadata: { [unowned self] path in
        self.metadata ?? .present(.init(path: path, modificationToken: self.token))
    }, verify: { [unowned self] _, _ in
        self.verifications += 1
        if self.changesDuringVerification { self.token = "replacement" }
        return self.result
    })
}
