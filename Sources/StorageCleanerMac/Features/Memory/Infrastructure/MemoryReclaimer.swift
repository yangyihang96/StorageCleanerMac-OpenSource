import Darwin
import Foundation

/// D144: "释放内存" (CleanMyMac "Free Up RAM", Lemon "释放内存") without
/// root and without `purge` (script/verify.sh exit 11).
///
/// CleanMyMac 5.7.2 `+[CMRAMCleaner _cleanMemoryWithCancellationBlock:]`
/// allocates 256 MB at a time, fills it with random bytes and stops when an
/// allocation fails, the compressor grows twice in a row, the memory report
/// cannot be read, or time runs out; Lemon 5.3.4 `+[QMPurgeRAM purgeByLocal]`
/// maps free + inactive + purgeable bytes at once and touches every page
/// (`清理软件逆向-2026-10-19/分报告/cleanmymac.md` §3, `lemon-macsai.md` §2.2).
/// Both make the kernel hand back file cache and purgeable memory. We keep
/// CleanMyMac's step and stop rules and add two of our own: the push never
/// exceeds what the kernel can drop without compressing anyone (free,
/// speculative and purgeable pages and the file cache, less 1 GiB, at most
/// half the RAM), and it stops as soon as the system's pressure level leaves
/// normal. It never starts under raised pressure: the system is already
/// reclaiming then, and more pressure only compresses or swaps other apps.
/// The counters before and after are reported as measured; macOS counts the
/// file cache as available memory, so the available total barely moves.
enum MemoryReclaimer {
    /// One `host_statistics64` reading, in bytes.
    struct Reading: Sendable, Equatable {
        var physicalBytes: UInt64
        var freeBytes: UInt64
        var speculativeBytes: UInt64
        var inactiveBytes: UInt64
        var fileBackedBytes: UInt64
        var purgeableBytes: UInt64
        var compressedBytes: UInt64
        /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
        var pressureLevelCode: Int32?

        /// Idle pages: free plus speculative read-ahead.
        var idleBytes: UInt64 { freeBytes &+ speculativeBytes }
        /// The cache macOS hands back on demand (as the memory page shows it).
        var cacheBytes: UInt64 { max(fileBackedBytes, purgeableBytes) }
    }

    enum StopReason: String, Sendable, Equatable {
        /// Pushed as far as the bound allows.
        case finished
        /// Less than one step could be handed back.
        case nothingToReclaim
        /// Pressure was already raised before starting; nothing was pushed.
        case pressureAlreadyRaised
        /// Pressure left normal during the push.
        case pressureRose
        /// The compressor grew on two steps in a row (CleanMyMac's rule).
        case compressorGrowing
        case allocationFailed
        case readingUnavailable
        case timedOut
        case cancelled
    }

    struct Outcome: Sendable, Equatable {
        let before: Reading
        let after: Reading?
        let budgetBytes: UInt64
        let pushedBytes: UInt64
        let stopReason: StopReason
        let duration: TimeInterval

        /// Idle memory gained, as measured (negative if it fell).
        var idleDeltaBytes: Int64? {
            after.map { Int64(clamping: $0.idleBytes) - Int64(clamping: before.idleBytes) }
        }

        /// Cache handed back, as measured (negative if it grew).
        var cacheDeltaBytes: Int64? {
            after.map { Int64(clamping: before.cacheBytes) - Int64(clamping: $0.cacheBytes) }
        }

        var compressedDeltaBytes: Int64? {
            after.map { Int64(clamping: $0.compressedBytes) - Int64(clamping: before.compressedBytes) }
        }
    }

    /// The system calls the push depends on; tests replace them.
    struct Environment: Sendable {
        var read: @Sendable () -> Reading?
        var allocate: @Sendable (Int) -> UnsafeMutableRawPointer?
        var fill: @Sendable (UnsafeMutableRawPointer, Int) -> Void
        var release: @Sendable (UnsafeMutableRawPointer, Int) -> Void
        var relieveMallocZones: @Sendable () -> Void
        var now: @Sendable () -> Date
        var settle: @Sendable () -> Void

        static let live = Environment(
            read: { MemoryReclaimer.liveReading() },
            allocate: { size in
                let pointer = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0)
                return pointer == MAP_FAILED ? nil : pointer
            },
            fill: { pointer, size in MemoryReclaimer.fillWithNoise(pointer, size: size) },
            release: { pointer, size in _ = munmap(pointer, size) },
            relieveMallocZones: { _ = malloc_zone_pressure_relief(nil, 0) },
            now: { Date() },
            settle: { usleep(500_000) }
        )
    }

    static let stepBytes: UInt64 = 256 << 20
    static let headroomBytes: UInt64 = 1 << 30
    static let timeout: TimeInterval = 30
    /// Compressor growth that counts as "growing" on one step.
    static let compressorGrowthBytes: UInt64 = 32 << 20

    /// What the kernel can hand back without compressing anyone, less the
    /// headroom, at most half the RAM; 0 when that is under one step.
    static func budget(for reading: Reading) -> UInt64 {
        let fileCache = min(reading.fileBackedBytes, reading.inactiveBytes)
        let reclaimable = reading.freeBytes
            .addingReportingOverflow(reading.speculativeBytes).partialValue
            .addingReportingOverflow(reading.purgeableBytes).partialValue
            .addingReportingOverflow(fileCache).partialValue
        guard reclaimable > headroomBytes else { return 0 }
        let bounded = min(reclaimable - headroomBytes, reading.physicalBytes / 2)
        return bounded >= stepBytes ? bounded : 0
    }

    /// Pushes, releases and measures. Blocking; run it off the main actor.
    static func run(environment: Environment = .live,
                    isCancelled: @Sendable () -> Bool) -> Outcome? {
        let start = environment.now()
        guard let before = environment.read() else { return nil }
        func outcome(_ reason: StopReason, budget: UInt64, pushed: UInt64, after: Reading?) -> Outcome {
            Outcome(before: before, after: after, budgetBytes: budget, pushedBytes: pushed,
                    stopReason: reason, duration: environment.now().timeIntervalSince(start))
        }
        if let level = before.pressureLevelCode, level != 1 {
            return outcome(.pressureAlreadyRaised, budget: 0, pushed: 0, after: before)
        }
        let budget = budget(for: before)
        guard budget > 0 else {
            return outcome(.nothingToReclaim, budget: 0, pushed: 0, after: before)
        }

        var chunks: [UnsafeMutableRawPointer] = []
        var pushed: UInt64 = 0
        var previousCompressed = before.compressedBytes
        var growingSteps = 0
        var reason = StopReason.finished
        let step = Int(stepBytes)
        while pushed + stepBytes <= budget {
            if isCancelled() { reason = .cancelled; break }
            if environment.now().timeIntervalSince(start) > timeout { reason = .timedOut; break }
            guard let chunk = environment.allocate(step) else { reason = .allocationFailed; break }
            environment.fill(chunk, step)
            chunks.append(chunk)
            pushed += stepBytes
            guard let reading = environment.read() else { reason = .readingUnavailable; break }
            if let level = reading.pressureLevelCode, level != 1 { reason = .pressureRose; break }
            if reading.compressedBytes > previousCompressed + compressorGrowthBytes {
                growingSteps += 1
                if growingSteps >= 2 { reason = .compressorGrowing; break }
            } else {
                growingSteps = 0
            }
            previousCompressed = reading.compressedBytes
        }
        for chunk in chunks { environment.release(chunk, step) }
        environment.relieveMallocZones()
        environment.settle()
        return outcome(reason, budget: budget, pushed: pushed, after: environment.read())
    }

    /// Random bytes on every page, so the compressor cannot shrink the push
    /// (CleanMyMac copies ten random 1 KB blocks over each allocation).
    static func fillWithNoise(_ pointer: UnsafeMutableRawPointer, size: Int) {
        let blockSize = 64 << 10
        var block = [UInt8](repeating: 0, count: blockSize)
        arc4random_buf(&block, blockSize)
        block.withUnsafeBytes { noise in
            var offset = 0
            while offset < size {
                let length = min(blockSize, size - offset)
                (pointer + offset).copyMemory(from: noise.baseAddress!, byteCount: length)
                offset += length
            }
        }
    }

    static func liveReading() -> Reading? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var rawPageSize: vm_size_t = 0
        guard status == KERN_SUCCESS,
              host_page_size(mach_host_self(), &rawPageSize) == KERN_SUCCESS, rawPageSize > 0 else { return nil }
        let page = UInt64(rawPageSize)
        func bytes(_ pages: natural_t) -> UInt64 { UInt64(pages).multipliedReportingOverflow(by: page).partialValue }
        return Reading(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: bytes(stats.free_count),
            speculativeBytes: bytes(stats.speculative_count),
            inactiveBytes: bytes(stats.inactive_count),
            fileBackedBytes: bytes(stats.external_page_count),
            purgeableBytes: bytes(stats.purgeable_count),
            compressedBytes: bytes(stats.compressor_page_count),
            pressureLevelCode: SystemMemoryProbe.readSystemPressureLevelCode())
    }
}

/// Set from a cancelled task; read by the blocking push between steps.
final class MemoryReclaimCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() { lock.withLock { cancelled = true } }
}
