import Foundation

/// Hosted by the existing app-scoped coordinator. No timers, history store or
/// standalone application. A cancelled worker is awaited until it has drained.
enum MSeriesCoreRunner {
    static func run(sessionID: UUID, root: URL, resourceJournal: CleanupReportJournal?,
                    progress: @escaping @Sendable (UUID, String, Int) async -> Void) async -> MSeriesResult {
        let cancellation = MSeriesCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            await execute(sessionID: sessionID, root: root, cancellation: cancellation,
                          resourceJournal: resourceJournal, progress: progress)
        }
        return await withTaskCancellationHandler {
            await worker.value
        } onCancel: { cancellation.cancel(); worker.cancel() }
    }

    private static func execute(sessionID: UUID, root: URL, cancellation: MSeriesCancellation,
                                resourceJournal: CleanupReportJournal?,
                                progress: @escaping @Sendable (UUID, String, Int) async -> Void) async -> MSeriesResult {
        let startedAt = Date()
        let hardware = MSeriesHardware.capture()
        var metrics: [MSeriesMeasurement] = []
        var environment = [MSeriesEnvironmentPoint.capture()]
        var cancelled = false
        var failure: String?
        var disk: MSeriesStorageKernel?
        var writtenBytes: UInt64 = 0
        let writeBudget = MSeriesWriteBudget()
        for (index, id) in MSeriesProtocol.coreIDs.enumerated() {
            await progress(sessionID, id, index)
            environment.append(.capture())
            do {
                try cancellation.check()
                guard hardware.nativeARM64, hardware.translated != true else {
                    metrics.append(unavailable(id, status: .unsupported, reason: "native-arm64-required")); continue
                }
                let budget = min(hardware.sharedBudgetBytes, MSeriesHardware.capture().sharedBudgetBytes)
                let measurement: MSeriesMeasurement
                if id.hasPrefix("cpu.") {
                    let parts = id.split(separator: ".")
                    let families = ["integer", "floating", "compression", "image"]
                    guard let kind = families.firstIndex(of: String(parts[2])) else { throw MSeriesKernelError.invalidOutput }
                    let workers = parts[1] == "multi" ? hardware.logicalCores : 1
                    measurement = try MSeriesCPUMemoryKernel(kind: Int32(kind), workers: workers,
                        budgetBytes: budget).measure(id: id, cancellation: cancellation)
                } else if id.hasPrefix("memory.") {
                    let kind: Int32 = id == "memory.copy" ? 4 : id == "memory.triad" ? 5 : 6
                    measurement = try MSeriesCPUMemoryKernel(kind: kind, workers: 1,
                        budgetBytes: budget).measure(id: id, cancellation: cancellation)
                } else if id.hasPrefix("gpu.") {
                    guard hardware.metalDevice != nil else {
                        metrics.append(unavailable(id, status: .unsupported, reason: "no-metal-device")); continue
                    }
                    let gpu = try MSeriesGPUKernel(budget: budget)
                    measurement = id == "gpu.graphics.offscreen"
                        ? try gpu.graphics(cancellation: cancellation)
                        : try gpu.compute(halfPrecision: id == "gpu.compute.fp16", cancellation: cancellation)
                } else {
                    if disk == nil {
                        disk = try MSeriesStorageKernel(root: root, sessionID: sessionID,
                            budget: budget, cancellation: cancellation, writeBudget: writeBudget,
                            resourceJournal: resourceJournal)
                    }
                    guard let disk else { throw MSeriesKernelError.io }
                    measurement = try disk.measure(random: id.contains("random"), write: id.contains("Write"))
                    writtenBytes = disk.writtenBytes
                }
                metrics.append(measurement)
            } catch is CancellationError { cancelled = true; break }
            catch MSeriesKernelError.thermalProtection { failure = "thermal-protection"; break }
            catch MSeriesKernelError.resourceBudget {
                metrics.append(unavailable(id, status: .insufficientResources, reason: "fixed-workspace-exceeds-live-budget"))
            } catch MSeriesKernelError.allocation {
                metrics.append(unavailable(id, status: .insufficientResources, reason: "allocation-failed"))
            } catch {
                metrics.append(unavailable(id, status: .failed, reason: String(describing: error)))
            }
            environment.append(.capture())
        }
        writtenBytes = writeBudget.writtenBytes
        disk = nil // Cleanup completes while the coordinator still owns its lease.
        environment.append(.capture())
        let cpuExtensions: MSeriesCPUExtensions.Result
        if !cancelled && failure == nil && hardware.nativeARM64 && hardware.translated != true {
            cpuExtensions = await MSeriesCPUExtensions.run(hardware: hardware, cancellation: cancellation) { id in
                await progress(sessionID, id, MSeriesProtocol.coreIDs.count)
            }
        } else {
            cpuExtensions = .init(measurements: [], environment: [])
        }
        let extensions = cpuExtensions.measurements + ["gpu.advanced", "gpu.hardwareRayTracing", "memory.workingSetCurve",
            "storage.workingSetQueueCurve", "media.h264", "media.hevc", "media.prores", "media.av1.decode",
            "ai.image", "ai.text", "display.framePacing", "power.efficiency"].map {
                unavailable($0, status: .notImplemented, reason: "kernel-integration-pending")
            }
        var result = MSeriesResult(sessionID: sessionID, schema: MSeriesProtocol.schema, plan: MSeriesProtocol.plan,
            workload: MSeriesProtocol.workload, fixture: MSeriesProtocol.fixture,
            implementation: MSeriesProtocol.implementation, statisticsVersion: MSeriesProtocol.statistics,
            scoringVersion: MSeriesProtocol.scoring, referenceVersion: MSeriesProtocol.reference,
            contractHash: MSeriesProtocol.contractHash, hardware: hardware, coreEnvironment: environment,
            metrics: metrics, extensions: extensions, cancelled: cancelled || cancellation.isCancelled,
            globalFailure: failure, writtenBytes: writtenBytes, startedAt: startedAt, completedAt: Date())
        result.extensionsVersion = MSeriesCPUExtensions.version
        result.extensionEnvironment = cpuExtensions.environment
        return result
    }
    private static func unavailable(_ id: String, status: MSeriesAvailability, reason: String) -> MSeriesMeasurement {
        MSeriesMeasurement(id: id, unit: "unavailable", availability: status, reason: reason,
            samples: [], statistics: nil, repetitions: 1, workers: 1)
    }
}
