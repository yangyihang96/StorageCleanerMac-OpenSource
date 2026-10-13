#if DEBUG || STORAGE_CLEANER_BETA
import Darwin
import Foundation

/// Audit only (`--menu-bar-performance-audit=`): stacks of the main thread
/// while one main run-loop iteration is still running past
/// `samplingStartsAfter`. A utility thread looks every `interval`; during a
/// long iteration it suspends the main thread for the few microseconds it
/// takes to read its registers and walk its frame pointers, then resumes it.
/// Nothing allocates, locks or symbolicates while the main thread is
/// suspended: return addresses go into buffers allocated up front, and the
/// main thread names them after the iteration (`MenuBarMainThreadMonitor`).
final class MenuBarStallSampler: @unchecked Sendable {
    static let shared = MenuBarStallSampler()

    static let samplingStartsAfter: Double = 0.05
    static let interval: Double = 0.01
    static let maximumSamples = 96
    static let maximumDepth = 48

    struct Sample {
        let offsetMs: Double
        let frames: [UInt]
    }

    private let lock = NSLock()
    private var iterationStart: Double?
    private var iterationID: UInt64 = 0
    private var sampledIteration: UInt64 = .max
    private var sampleCount = 0
    private var sampleOffsets = [Double](repeating: 0, count: MenuBarStallSampler.maximumSamples)
    private let frames = UnsafeMutablePointer<UInt>.allocate(capacity: maximumSamples * maximumDepth)
    private let depths = UnsafeMutablePointer<Int>.allocate(capacity: maximumSamples)
    private var mainThread: thread_act_t = 0
    private var stackLow: UInt = 0
    private var stackHigh: UInt = 0
    private var timer: DispatchSourceTimer?

    private init() {}

    /// Called on the main thread when the run-loop monitor is installed.
    func start() {
        guard timer == nil, Thread.isMainThread else { return }
        // Called on the main thread, so this thread is the main thread.
        let main = pthread_self()
        mainThread = pthread_mach_thread_np(main)
        let top = UInt(bitPattern: pthread_get_stackaddr_np(main))
        stackHigh = top
        stackLow = top - UInt(pthread_get_stacksize_np(main))
        let queue = DispatchQueue(label: "MenuBarStallSampler", qos: .userInteractive)
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + Self.interval, repeating: Self.interval, leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    func iterationBegan(at uptime: Double) {
        lock.lock()
        iterationStart = uptime
        iterationID &+= 1
        lock.unlock()
    }

    /// The samples taken during the iteration that just ended (main thread).
    func iterationEnded() -> [Sample] {
        lock.lock()
        defer {
            iterationStart = nil
            lock.unlock()
        }
        guard sampledIteration == iterationID, sampleCount > 0 else { return [] }
        var samples: [Sample] = []
        samples.reserveCapacity(sampleCount)
        for index in 0..<sampleCount {
            let base = frames + index * Self.maximumDepth
            samples.append(Sample(offsetMs: sampleOffsets[index],
                                  frames: Array(UnsafeBufferPointer(start: base, count: depths[index]))))
        }
        sampleCount = 0
        sampledIteration = .max
        return samples
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard let start = iterationStart, now - start >= Self.samplingStartsAfter else {
            lock.unlock()
            return
        }
        if sampledIteration != iterationID {
            sampledIteration = iterationID
            sampleCount = 0
        }
        guard sampleCount < Self.maximumSamples else {
            lock.unlock()
            return
        }
        let slot = sampleCount
        lock.unlock()
        // The main thread may be anywhere, including inside malloc or this
        // lock: between suspend and resume only registers and its own stack
        // are read, into memory allocated up front.
        let depth = captureMainThread(into: frames + slot * Self.maximumDepth)
        lock.lock()
        if sampledIteration == iterationID, slot == sampleCount, depth > 0 {
            depths[slot] = depth
            sampleOffsets[slot] = (now - start) * 1000
            sampleCount += 1
        }
        lock.unlock()
    }

    private func captureMainThread(into buffer: UnsafeMutablePointer<UInt>) -> Int {
#if arch(arm64)
        guard thread_suspend(mainThread) == KERN_SUCCESS else { return 0 }
        defer { thread_resume(mainThread) }
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.stride / MemoryLayout<natural_t>.stride)
        let result = withUnsafeMutablePointer(to: &state) { pointer in
            pointer.withMemoryRebound(to: natural_t.self, capacity: Int(count)) {
                thread_get_state(mainThread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        // Pointer-authentication bits are cleared; user addresses fit in 47 bits.
        let mask: UInt = 0x0000_7FFF_FFFF_FFFF
        var depth = 0
        buffer[depth] = UInt(state.__pc) & mask
        depth += 1
        let link = UInt(state.__lr) & mask
        var frame = UInt(state.__fp)
        // Only frames between the stack pointer and the top of the main
        // thread's stack are read; anything else ends the walk.
        let low = max(stackLow, UInt(state.__sp))
        if link != 0 {
            buffer[depth] = link
            depth += 1
        }
        while depth < Self.maximumDepth, frame >= low, frame < stackHigh - 16, frame % 8 == 0 {
            guard let pointer = UnsafePointer<UInt>(bitPattern: frame) else { break }
            let next = pointer[0]
            let returnAddress = pointer[1] & mask
            if returnAddress == 0 { break }
            if depth != 2 || returnAddress != link {
                buffer[depth] = returnAddress
                depth += 1
            }
            guard next > frame else { break }
            frame = next
        }
        return depth
#else
        return 0
#endif
    }

    /// Main thread, after the iteration: each distinct stack (most frequent
    /// first) as `image+offset symbol` lines, image names only, never paths.
    static func describe(_ samples: [Sample], stacks: Int = 4, frames: Int = 28) -> [[String: Any]] {
        var counts: [[UInt]: Int] = [:]
        for sample in samples { counts[sample.frames, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.prefix(stacks).map { stack, count in
            ["count": count, "frames": stack.prefix(frames).map(name)]
        }
    }

    private static func name(_ address: UInt) -> String {
        var info = Dl_info()
        guard address > 0, dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else {
            return String(format: "0x%lx", address)
        }
        let image = info.dli_fname.map { String(cString: $0).split(separator: "/").last.map(String.init) ?? "?" } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        let symbol = info.dli_sname.map { String(cString: $0) } ?? ""
        let symbolOffset = info.dli_saddr.map { address - UInt(bitPattern: $0) } ?? 0
        return String(format: "%@+0x%lx %@+%lu", image, address - base, symbol, symbolOffset)
    }
}
#endif
