import Foundation
import XCTest
@testable import StorageCleanerMac

final class BoundedHTTPSReaderTests: XCTestCase {
    func testRedirectRejectsForeignHostDowngradePortAndCredentials() throws {
        let policy = SameOriginRedirectPolicy(origin: try XCTUnwrap(URL(string: "https://api.example.test/start")))
        XCTAssertTrue(policy.permits(URL(string: "https://api.example.test/next")))
        for value in ["http://api.example.test/next", "https://other.example.test/next",
                      "https://api.example.test:444/next", "https://user@api.example.test/next"] {
            XCTAssertFalse(policy.permits(URL(string: value)))
        }
    }
    func testConsentRejectedBeforeNetworkRequest() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await BoundedHTTPSReader.data(for: URLRequest(url: URL(string: "https://fixture.test/ok")!),
                session: session, maximumBytes: 128, isAllowed: { false })
            XCTFail("A denied request must never start")
        } catch BoundedHTTPSReader.Failure.consentWithdrawn { }
    }
    func testChunkedResponseStopsAtByteLimitWithoutContentLength() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await BoundedHTTPSReader.data(for: URLRequest(url: URL(string: "https://fixture.test/large")!),
                session: session, maximumBytes: 128)
            XCTFail("Oversized response accepted")
        } catch BoundedHTTPSReader.Failure.responseTooLarge { }
    }
    func testSmallResponseRemainsExact() async throws {
        let session = stubSession()
        defer { session.invalidateAndCancel() }
        let (data, response) = try await BoundedHTTPSReader.data(
            for: URLRequest(url: URL(string: "https://fixture.test/ok")!), session: session, maximumBytes: 128)
        XCTAssertEqual(data, Data("fixture".utf8))
        XCTAssertEqual(response.statusCode, 200)
    }
    private func stubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [BoundedReaderFixtureProtocol.self]
        return URLSession(configuration: config)
    }
}
private final class BoundedReaderFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let data = request.url!.path == "/large" ? Data(repeating: 65, count: 1024) : Data("fixture".utf8)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
