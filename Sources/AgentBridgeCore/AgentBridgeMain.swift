import AgentShared
import Darwin
import Foundation

/// `storage-cleaner-agent`: MCP over stdio (`mcp`) or one command-line call.
public enum AgentBridgeMain {
    public static func run(_ arguments: [String]) async -> Int32 {
        // A client that goes away must not kill the bridge mid-write; stdin
        // closing is what ends it (stdio page, "Shutdown").
        signal(SIGPIPE, SIG_IGN)
        let parsed: AgentCommandLine.Parsed
        do {
            parsed = try AgentCommandLine.parse(Array(arguments.dropFirst()))
        } catch {
            standardError(error.message)
            return 2
        }
        let environment = locate()
        switch parsed {
        case .help:
            standardOutput(AgentCommandLine.usage + "\n")
            return 0
        case .version:
            standardOutput("storage-cleaner-agent \(environment?.version ?? "dev")\n")
            return 0
        case .tools:
            standardOutput(AgentCommandLine.toolListing())
            return 0
        case .mcp, .call:
            break
        }
        guard let environment, let executable = Bundle.main.executableURL else {
            standardError("storage-cleaner-agent 只能在存储清理助手的应用包里运行（Contents/Helpers）。")
            return 1
        }
        let policy = environment.applicationPolicy(bridgeExecutable: executable)
        let transport = AgentSocketTransport(socketPath: environment.socketPath, authorizeApp: { peer in
            policy?.permits(peer) ?? false
        }, interfaceEnabled: { environment.interfaceEnabled() })
        defer { transport.close() }
        if case .call(let tool, let toolArguments) = parsed {
            let (output, status) = await AgentCommandLine.run(tool: tool, arguments: toolArguments, transport: transport)
            standardOutput(output)
            return status
        }
        await serve(AgentMCPServer(identity: environment.serverIdentity, transport: transport, output: { standardOutput($0) }))
        return 0
    }

    private static func locate() -> AgentBridgeEnvironment? {
        guard let executable = Bundle.main.executableURL, let home = AgentDataLocation.currentUserHome() else { return nil }
        return try? AgentBridgeEnvironment.locate(executable: executable, home: home)
    }

    /// Calls already running when stdin ends get this long to answer: a client
    /// may write its last request and close at once.
    static let closingGrace: UInt64 = 5_000_000_000

    /// Reads stdin on its own thread; returns when stdin ends and the running
    /// calls have answered, or the grace period is over (exit promptly).
    private static func serve(_ server: AgentMCPServer) async {
        let lines = AsyncStream<AgentLine> { continuation in
            Thread {
                var buffer = AgentLineBuffer(maximumLineLength: AgentChannel.maximumRequestLineBytes)
                var chunk = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = chunk.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { break }
                    buffer.append(Data(chunk[0..<count])).forEach { continuation.yield($0) }
                }
                buffer.finish().forEach { continuation.yield($0) }
                continuation.finish()
            }.start()
        }
        for await line in lines { await server.receive(line) }
        // Unstructured on purpose: whichever ends first lets the process exit,
        // and exit takes the other one with it.
        let first = AgentFirstOnly()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                await server.drain()
                if first.claim() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(nanoseconds: closingGrace)
                if first.claim() { continuation.resume() }
            }
        }
    }

    private static let outputLock = NSLock()

    private static func standardOutput(_ text: String) { standardOutput(Data(text.utf8)) }

    /// stdout carries MCP messages only (stdio page); one writer at a time.
    private static func standardOutput(_ data: Data) {
        outputLock.withLock { writeAll(STDOUT_FILENO, data) }
    }

    private static func standardError(_ text: String) { writeAll(STDERR_FILENO, Data((text + "\n").utf8)) }

    private final class AgentFirstOnly: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    private static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }
}
