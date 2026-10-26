import Darwin
import Foundation
import FileOperationShared

/// D177: the only command this helper runs. Path and argument are fixed and
/// nothing from the client reaches them; `resetbtm` or any other verb is
/// never sent. The run is time-limited, its output capped, and only the
/// caller's own and the system-wide records leave the helper.
enum BackgroundTaskInventoryCommand {
    static let executable = "/usr/bin/sfltool"
    static let arguments = ["dumpbtm"]
    static let timeout: TimeInterval = 15
    static let outputLimit = 16 * 1_024 * 1_024
    /// One dump at a time across all connections, apart from the move queue.
    static let queue = DispatchQueue(label: "file-operation.background-task-inventory")

    static func read(uid: uid_t) -> BackgroundTaskInventoryReply {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["LANG": "C", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return BackgroundTaskInventoryReply(failure: .launch) }

        let output = BoundedOutput(limit: outputLimit)
        let reading = DispatchGroup()
        reading.enter()
        DispatchQueue.global(qos: .utility).async {
            output.drain(pipe.fileHandleForReading)
            reading.leave()
        }
        let exited = finished.wait(timeout: .now() + timeout) == .success
        if !exited {
            process.terminate()
            if finished.wait(timeout: .now() + 1) != .success {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
        if reading.wait(timeout: .now() + 1) != .success {
            try? pipe.fileHandleForReading.close()
            _ = reading.wait(timeout: .now() + 1)
        }
        guard exited else { return BackgroundTaskInventoryReply(failure: .timeout) }
        let (data, overflowed) = output.result
        guard !overflowed else { return BackgroundTaskInventoryReply(failure: .tooLarge) }
        guard process.terminationStatus == 0 else {
            return BackgroundTaskInventoryReply(failure: .exitStatus, exitStatus: process.terminationStatus)
        }
        guard let records = BackgroundTaskInventoryFilter.records(
            in: String(decoding: data, as: UTF8.self), uid: uid) else {
            return BackgroundTaskInventoryReply(failure: .format)
        }
        return BackgroundTaskInventoryReply(output: records)
    }
}

private final class BoundedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var data = Data()
    private var overflowed = false
    init(limit: Int) { self.limit = limit }
    /// Reads to the end so the command never blocks on a full pipe; past the
    /// limit the text is dropped and only the overflow is remembered.
    func drain(_ handle: FileHandle) {
        while let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty {
            lock.withLock {
                if overflowed || data.count + chunk.count > limit {
                    overflowed = true; data = Data()
                } else {
                    data.append(chunk)
                }
            }
        }
    }
    var result: (Data, Bool) { lock.withLock { (data, overflowed) } }
}

extension ConnectionService {
    func backgroundTaskInventory(reply: @escaping (Data) -> Void) {
        let callback = trackedReply(reply)
        BackgroundTaskInventoryCommand.queue.async {
            let response = BackgroundTaskInventoryCommand.read(uid: self.uid)
            callback.call((try? JSONEncoder().encode(response)) ?? Data())
        }
    }
}
