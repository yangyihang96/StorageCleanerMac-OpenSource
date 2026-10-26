import CoreServices
import Foundation

/// Watches the Trash folders with FSEvents and reports changes after a quiet
/// period (CleanMyMac `TrashMonitoringService` + `debounceTimeInterval`).
/// It only observes; reading what changed is the caller's job.
final class TrashFolderMonitor: @unchecked Sendable {
    typealias Handler = @Sendable () -> Void

    private let queue = DispatchQueue(label: "StorageCleanerMac.TrashFolderMonitor", qos: .utility)
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    private var pending: DispatchWorkItem?
    private let debounce: TimeInterval
    private let handler: Handler

    /// The stream holds an unretained pointer to the monitor: keep the monitor
    /// alive until `stop()` has run on its queue.
    init(debounce: TimeInterval = 2, handler: @escaping Handler) {
        self.debounce = debounce
        self.handler = handler
    }

    /// Starts (or restarts, when the set of folders changed) watching.
    func watch(_ locations: [URL]) {
        let requested = locations.map(\.path).sorted()
        queue.async { [weak self] in
            guard let self, requested != self.paths || self.stream == nil else { return }
            self.stopOnQueue()
            self.paths = requested
            self.startOnQueue()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    private func startOnQueue() {
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<TrashFolderMonitor>.fromOpaque(info).takeUnretainedValue().scheduleNotification()
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagWatchRoot)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    private func stopOnQueue() {
        pending?.cancel()
        pending = nil
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Runs on `queue` (the stream's dispatch queue).
    private func scheduleNotification() {
        pending?.cancel()
        let handler = self.handler
        let item = DispatchWorkItem { handler() }
        pending = item
        queue.asyncAfter(deadline: .now() + debounce, execute: item)
    }
}
