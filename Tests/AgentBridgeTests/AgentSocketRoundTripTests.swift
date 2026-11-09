import AgentBridgeCore
import AgentGatewayCore
import AgentShared
import Darwin
import FileOperationShared
import Foundation
import XCTest

/// D263 end to end on a real socket in a short private directory. The test
/// process plays both the App and the bridge, so the peer policies here accept
/// "this process"; the signature rules themselves are pinned in
/// AgentLocationAndPeerTests with injected identities.
final class AgentSocketRoundTripTests: XCTestCase {
    private let client = AgentClientIdentity(kind: .signed, identifier: "com.apple.Terminal", team: nil, cdhash: nil,
                                             executablePath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
                                             displayName: "Terminal")

    /// D267: `willTerminate` stops the server on the main thread, so a client
    /// that stopped reading must not hold it up until the write times out.
    func testStoppingDoesNotWaitForAWriteToAClientThatStoppedReading() throws {
        let path = try AgentTestDirectory.make(self).appendingPathComponent("s").path
        let answering = expectation(description: "the answer is being built")
        let server = try AgentSocketServer(socketPath: path, authorizePeer: { $0.pid == getpid() }, identifyClient: { [client] _ in client }, handle: { request, _ in
            answering.fulfill()
            return .success(request.id, ["text": .string(String(repeating: "x", count: 3 * 1024 * 1024))])
        })
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try UpdateAskpassPeer.address(path)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        let request = try AgentLineCodec.encodeLine(AgentChannelRequest(id: "1", tool: "big", arguments: [:], surface: .mcp))
        XCTAssertEqual(request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }, request.count)
        wait(for: [answering], timeout: 10)
        // Far more than a socket buffer holds, and this end reads nothing.
        Thread.sleep(forTimeInterval: 0.5)

        let started = Date()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the send timeout is 5 seconds")
    }

    /// A read waiting for the main thread must not hold up a stop on it.
    func testStoppingDoesNotWaitForARequestStillBeingAnswered() throws {
        let path = try AgentTestDirectory.make(self).appendingPathComponent("s").path
        let answering = expectation(description: "the request reached the handler")
        let release = AsyncStream<Void>.makeStream()
        let server = try AgentSocketServer(socketPath: path, authorizePeer: { $0.pid == getpid() }, identifyClient: { [client] _ in client }, handle: { request, _ in
            answering.fulfill()
            for await _ in release.stream {}
            return .success(request.id, [:])
        })
        defer { release.continuation.finish() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try UpdateAskpassPeer.address(path)
        _ = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        let request = try AgentLineCodec.encodeLine(AgentChannelRequest(id: "1", tool: "stuck", arguments: [:], surface: .mcp))
        _ = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        wait(for: [answering], timeout: 10)

        let started = Date()
        server.stop()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    private func echoServer(_ path: String, peers: LockedValues<pid_t>? = nil, accept: Bool = true,
                            identify: Bool = true) throws -> AgentSocketServer {
        let client = client
        return try AgentSocketServer(socketPath: path, authorizePeer: { peer in
            peers?.append(peer.pid)
            XCTAssertEqual(peer.uid, getuid())
            XCTAssertEqual(peer.auditToken.count, MemoryLayout<audit_token_t>.size, "Peer facts come from the kernel")
            return accept && peer.pid == getpid()
        }, identifyClient: { _ in identify ? client : nil }, handle: { request, client in
            if request.tool == "slow" { try? await Task.sleep(nanoseconds: 50_000_000) }
            return .success(request.id, ["tool": .string(request.tool), "client": .string(client.displayName)])
        })
    }

    private func transport(_ path: String, enabled: Bool? = true, acceptApp: Bool = true) -> AgentSocketTransport {
        AgentSocketTransport(socketPath: path, authorizeApp: { acceptApp && $0.pid == getpid() }, interfaceEnabled: { enabled })
    }

    func testRequestsRoundTripAndRequestIDsComeBackAsSent() async throws {
        let path = try AgentSocketDirectory.prepare(dataDirectory: try AgentTestDirectory.make(self))
        let peers = LockedValues<pid_t>()
        let server = try echoServer(path, peers: peers)
        defer { server.stop() }
        let bridge = transport(path)
        defer { bridge.close() }

        let result = await bridge.call(.init(id: "m7", tool: "get_overview", arguments: [:], surface: .mcp))
        XCTAssertEqual(result, .result(["tool": "get_overview", "client": "Terminal"]))
        XCTAssertEqual(peers.values, [getpid()])

        let answers = await withTaskGroup(of: AgentCallResult.self) { group in
            for index in 0..<6 {
                group.addTask { await bridge.call(.init(id: "same", tool: index.isMultiple(of: 2) ? "slow" : "t\(index)", arguments: [:],
                                                       surface: .commandLine)) }
            }
            return await group.reduce(into: [AgentCallResult]()) { $0.append($1) }
        }
        XCTAssertEqual(answers.count, 6)
        XCTAssertEqual(Set(answers.compactMap { if case .result(let value) = $0 { value["tool"] } else { nil } }).count, 4,
                       "Concurrent calls with the same caller ID each get their own answer")
        XCTAssertEqual(server.connectionCount, 1, "One connection carries every call")
    }

    func testEitherSideRefusingEndsTheConversation() async throws {
        let path = try AgentSocketDirectory.prepare(dataDirectory: try AgentTestDirectory.make(self))
        do {
            let server = try echoServer(path, accept: false)
            defer { server.stop() }
            let result = await transport(path).call(.init(id: "1", tool: "get_overview", arguments: [:], surface: .mcp))
            guard case .refused(let refusal) = result else { return XCTFail("\(result)") }
            XCTAssertEqual(refusal.reason, .internalError, "The App hung up on an unverified bridge")
        }
        do {
            let server = try echoServer(path)
            defer { server.stop() }
            let result = await transport(path, acceptApp: false).call(.init(id: "1", tool: "get_overview", arguments: [:], surface: .mcp))
            XCTAssertEqual(result, .refused(AgentRefusal(.appUnverified)))
        }
        do {
            let server = try echoServer(path, identify: false)
            defer { server.stop() }
            let result = await transport(path).call(.init(id: "1", tool: "get_overview", arguments: [:], surface: .mcp))
            XCTAssertEqual(result, .refused(AgentRefusal(.clientUnidentified)))
        }
    }

    func testStoppingTheServerReadsAsOffOrNotRunning() async throws {
        let path = try AgentSocketDirectory.prepare(dataDirectory: try AgentTestDirectory.make(self))
        let server = try echoServer(path)
        let bridge = transport(path, enabled: false)
        let before = await bridge.call(.init(id: "1", tool: "a", arguments: [:], surface: .mcp))
        XCTAssertEqual(before, .result(["tool": "a", "client": "Terminal"]))
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path), "Stopping removes the socket")
        let off = await bridge.call(.init(id: "2", tool: "a", arguments: [:], surface: .mcp))
        XCTAssertEqual(off, .refused(AgentRefusal(.interfaceOff)), "Switch off: the bridge says so instead of 'not running'")
        let notRunning = await transport(path, enabled: true).call(.init(id: "3", tool: "a", arguments: [:], surface: .mcp))
        XCTAssertEqual(notRunning, .refused(AgentRefusal(.appNotRunning)))
        let unknown = await transport(path, enabled: nil).call(.init(id: "4", tool: "a", arguments: [:], surface: .mcp))
        XCTAssertEqual(unknown, .refused(AgentRefusal(.appNotRunning)))
    }

    func testListeningReplacesOnlyAStaleSocketOfThisUser() throws {
        let data = try AgentTestDirectory.make(self)
        let path = try AgentSocketDirectory.prepare(dataDirectory: data)
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try UpdateAskpassPeer.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(bound, 0)
        close(stale)
        XCTAssertNoThrow(try echoServer(path).stop(), "A socket left by a crash is replaced")

        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data("x".utf8)))
        XCTAssertThrowsError(try echoServer(path), "Anything else at that path is never removed")
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "x")
    }

    func testPreparedDirectoryIsPrivateAndTooLongPathsAreRefused() throws {
        let data = try AgentTestDirectory.make(self)
        let path = try AgentSocketDirectory.prepare(dataDirectory: data)
        XCTAssertEqual(path, data.appendingPathComponent("Agent/s").path)
        var status = stat()
        XCTAssertEqual(lstat(data.appendingPathComponent("Agent").path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o700)

        let long = data.appendingPathComponent(String(repeating: "x", count: 90), isDirectory: true)
        XCTAssertThrowsError(try AgentSocketDirectory.prepare(dataDirectory: long)) {
            guard case .pathTooLong = $0 as? AgentSocketLocationError else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: long.path), "Nothing is created for a path that cannot work")
    }

    func testOverlongRequestClosesTheConnection() throws {
        let path = try AgentSocketDirectory.prepare(dataDirectory: try AgentTestDirectory.make(self))
        let server = try echoServer(path)
        defer { server.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try UpdateAskpassPeer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        XCTAssertEqual(connected, 0)
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var greeting = [UInt8](repeating: 0, count: 512)
        XCTAssertGreaterThan(read(fd, &greeting, greeting.count), 0)
        let junk = [UInt8](repeating: 0x61, count: AgentChannel.maximumRequestLineBytes + 10)
        _ = junk.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        var buffer = [UInt8](repeating: 0, count: 64)
        // 0 (end of stream) or -1 (reset, when unread bytes were left behind).
        XCTAssertLessThanOrEqual(read(fd, &buffer, buffer.count), 0, "The App hangs up instead of buffering without end")
    }
}
