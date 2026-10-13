import Foundation
import XCTest
@testable import StorageCleanerMac

/// The download size limit must stop a response while it streams, including
/// a chunked one without Content-Length, not after the file reached the disk.
/// A cancelled caller must always get its answer, and a refused redirect must
/// be reported as such.
final class OfficialUpdateDownloaderTests: XCTestCase {
    private let appURL = URL(string: "https://downloads.example.com/app.zip")!

    private func downloader(
        limit: Int64,
        protocolClass: AnyClass,
        writes: WriteRecorder? = nil
    ) -> OfficialUpdateDownloader {
        var downloader = OfficialUpdateDownloader(maximumBytes: limit, allowedHosts: ["downloads.example.com"])
        downloader.makeConfiguration = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [protocolClass]
            return configuration
        }
        if let writes {
            downloader.testHooks.didWrite = { writes.record($0) }
        }
        return downloader
    }

    private func staging() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("download-\(UUID().uuidString).partial")
    }

    func testUnboundedChunkedResponseStopsAtTheLimit() async throws {
        let chunkSize = 64 * 1024
        let limit: Int64 = 256 * 1024
        StreamingProtocol.reset(chunks: 256, chunkSize: chunkSize, declaredLength: nil, interval: 0.005)
        let writes = WriteRecorder()
        let target = staging()
        do {
            _ = try await downloader(limit: limit, protocolClass: StreamingProtocol.self, writes: writes)
                .download(URLRequest(url: appURL), stagingURL: target)
            XCTFail("An oversized response must not complete")
        } catch {
            XCTAssertEqual(error as? PackageValidationError, .fileTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "The partial file is removed")
        XCTAssertGreaterThan(writes.maximum, limit, "The transfer stopped because it crossed the limit")
        XCTAssertLessThanOrEqual(
            writes.maximum, limit + Int64(chunkSize),
            "The transfer stops at the first write past the limit"
        )
        XCTAssertLessThan(StreamingProtocol.sentChunks, 256, "The transfer stops early instead of writing 16 MiB")
    }

    func testDeclaredLengthOverTheLimitStopsAtTheFirstWrite() async throws {
        let chunkSize = 64 * 1024
        let limit: Int64 = 1024 * 1024
        // Declares 4 MiB. Checking only the written bytes would run past 1 MiB.
        StreamingProtocol.reset(chunks: 64, chunkSize: chunkSize, declaredLength: 64 * chunkSize)
        let writes = WriteRecorder()
        let target = staging()
        do {
            _ = try await downloader(limit: limit, protocolClass: StreamingProtocol.self, writes: writes)
                .download(URLRequest(url: appURL), stagingURL: target)
            XCTFail("A declared oversize must not complete")
        } catch {
            XCTAssertEqual(error as? PackageValidationError, .fileTooLarge)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "The partial file is removed")
        XCTAssertGreaterThan(writes.count, 0)
        XCTAssertLessThan(
            writes.maximum, limit,
            "A declared oversize stops at the first write, before the written bytes reach the limit"
        )
    }

    func testResponseWithinTheLimitIsKept() async throws {
        StreamingProtocol.reset(chunks: 4, chunkSize: 1024, declaredLength: 4096)
        let target = staging()
        defer { try? FileManager.default.removeItem(at: target) }
        let result = try await downloader(limit: 1024 * 1024, protocolClass: StreamingProtocol.self)
            .download(URLRequest(url: appURL), stagingURL: target)
        XCTAssertEqual(result.fileURL, target)
        XCTAssertEqual(try Data(contentsOf: target).count, 4096)
        XCTAssertEqual((result.response as? HTTPURLResponse)?.statusCode, 200)
    }

    /// A caller cancelled before the transfer starts makes URLSession finish
    /// the task on its own. When that completion arrives before the download
    /// registered for it, the download must still return instead of keeping
    /// its caller (and the app-update lease it holds) waiting forever.
    func testCancelledCallerReturnsWhenTheCompletionArrivesFirst() async throws {
        StreamingProtocol.reset(chunks: 4, chunkSize: 1024, declaredLength: 4096)
        var downloader = downloader(limit: 1024 * 1024, protocolClass: StreamingProtocol.self)
        // Hold the registration long enough for the completion to arrive first.
        downloader.testHooks.beforeStart = { usleep(200_000) }
        let target = staging()
        let returned = expectation(description: "The cancelled download returns")
        let request = URLRequest(url: appURL)
        let caller = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await downloader.download(request, stagingURL: target)
                XCTFail("A cancelled caller must not receive a file")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cancelled)
            }
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 10)
        caller.cancel()
        XCTAssertEqual(StreamingProtocol.startedLoads, 0, "A cancelled caller never starts the transfer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancellingTheCallerStopsTheTransferAndRemovesThePartialFile() async throws {
        StreamingProtocol.reset(chunks: 256, chunkSize: 64 * 1024, declaredLength: nil, interval: 0.005)
        let downloader = downloader(limit: 1 << 30, protocolClass: StreamingProtocol.self)
        let target = staging()
        let returned = expectation(description: "The cancelled download returns")
        let request = URLRequest(url: appURL)
        let caller = Task {
            do {
                _ = try await downloader.download(request, stagingURL: target)
                XCTFail("A cancelled caller must not receive a file")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cancelled)
            }
            returned.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        caller.cancel()
        await fulfillment(of: [returned], timeout: 10)
        XCTAssertLessThan(StreamingProtocol.sentChunks, 256)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// Refusing a redirect only stops following it; the task would otherwise
    /// complete with the redirect's own body and be misreported as an invalid
    /// response.
    func testRefusedRedirectFailsAsAnInvalidRedirect() async throws {
        RedirectingProtocol.reset()
        let target = staging()
        do {
            _ = try await downloader(limit: 1024 * 1024, protocolClass: RedirectingProtocol.self)
                .download(URLRequest(url: URL(string: "https://downloads.example.com/redirect")!), stagingURL: target)
            XCTFail("A refused redirect must not complete")
        } catch OfficialApplicationUpdateInstallerError.invalidRedirect {
            // Expected.
        } catch {
            XCTFail("Expected an invalid redirect, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "The redirect body is not kept")
        XCTAssertEqual(RedirectingProtocol.requestedHosts, ["downloads.example.com"], "The refused host is never contacted")
    }
}

/// Collects the running totals the size limit sees.
private final class WriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var totals: [Int64] = []

    func record(_ total: Int64) { lock.withLock { totals.append(total) } }
    var count: Int { lock.withLock { totals.count } }
    var maximum: Int64 { lock.withLock { totals.max() ?? 0 } }
}

private final class StreamingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var chunks = 0
    nonisolated(unsafe) private static var chunkSize = 0
    nonisolated(unsafe) private static var declaredLength: Int?
    nonisolated(unsafe) private static var interval: TimeInterval = 0.002
    nonisolated(unsafe) private static var sent = 0
    nonisolated(unsafe) private static var started = 0
    private let stopped = NSLock()
    private var isStopped = false

    static func reset(chunks: Int, chunkSize: Int, declaredLength: Int?, interval: TimeInterval = 0.002) {
        lock.withLock {
            self.chunks = chunks
            self.chunkSize = chunkSize
            self.declaredLength = declaredLength
            self.interval = interval
            sent = 0
            started = 0
        }
    }
    static var sentChunks: Int { lock.withLock { sent } }
    static var startedLoads: Int { lock.withLock { started } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let (count, size, length, pause) = Self.lock.withLock { () -> (Int, Int, Int?, TimeInterval) in
            Self.started += 1
            return (Self.chunks, Self.chunkSize, Self.declaredLength, Self.interval)
        }
        var headers = ["Content-Type": "application/zip"]
        if let length { headers["Content-Length"] = String(length) }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        DispatchQueue.global().async { [self] in
            let chunk = Data(repeating: 0x5A, count: size)
            for _ in 0..<count {
                if stopped.withLock({ isStopped }) { return }
                client?.urlProtocol(self, didLoad: chunk)
                Self.lock.withLock { Self.sent += 1 }
                Thread.sleep(forTimeInterval: pause)
            }
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {
        stopped.withLock { isStopped = true }
    }
}

/// Answers `/redirect` with a 302 to a host outside the allow list, followed by
/// the redirect's own body, the way an HTTP loader does when a redirect is not
/// followed.
private final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var hosts: [String] = []

    static func reset() { lock.withLock { hosts = [] } }
    static var requestedHosts: [String] { lock.withLock { hosts } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        Self.lock.withLock { Self.hosts.append(url.host ?? "") }
        let target = URL(string: "https://elsewhere.example.net/app.zip")!
        let redirect = HTTPURLResponse(
            url: url,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": target.absoluteString, "Content-Length": "5"]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: redirect)
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("moved".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
