import Compression
import Foundation

/// Storage is lossless for sealed privacy-safe evidence (helper boot UUIDs are
/// stripped before sealing). rawPayloadSHA uses expanded canonical JSON, not
/// the compressed archive. Accounting fields stay outside it so changing the
/// atomic-write ledger cannot destabilize its compressed byte count.
enum MSeriesV11CompactStorage {
    static let expandedEncoding = CodingUserInfoKey(rawValue: "mseries-v11-expanded-json")!
    static let forceCompactEncoding = CodingUserInfoKey(rawValue: "mseries-v11-force-compact-json")!
    static let format = "mseries-v11-lzfse-json-1"
    static let maximumExpandedBytes = 64 * 1024 * 1024

    static func expandedBytes(_ result: MSeriesV11Result) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.userInfo[expandedEncoding] = true
        return try encoder.encode(result)
    }

    static func compress(_ bytes: Data) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= maximumExpandedBytes else { throw MSeriesV11RunError.metadataBudget }
        var destination = [UInt8](repeating: 0, count: bytes.count + 4096)
        let count = bytes.withUnsafeBytes { source in
            destination.withUnsafeMutableBytes { target in
                compression_encode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count > 0 else { throw MSeriesV11RunError.metadataBudget }
        return Data(destination.prefix(count))
    }

    static func expand(_ bytes: Data, expectedBytes: Int, sha256: String) throws -> Data {
        guard !bytes.isEmpty, bytes.count <= 1_048_576, expectedBytes > 0,
              expectedBytes <= maximumExpandedBytes, MSeriesV11Digest.isSHA256(sha256) else {
            throw MSeriesV11RunError.metadataBudget
        }
        // An extra byte detects a false advertised length; hash verifies all
        // decoded bytes, including the final record and otherwise valid JSON.
        var destination = [UInt8](repeating: 0, count: expectedBytes + 1)
        let count = bytes.withUnsafeBytes { source in
            destination.withUnsafeMutableBytes { target in
                compression_decode_buffer(target.bindMemory(to: UInt8.self).baseAddress!, target.count,
                    source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard count == expectedBytes else { throw MSeriesV11RunError.metadataBudget }
        let expanded = Data(destination.prefix(count))
        guard MSeriesV11Digest.sha256(expanded) == sha256 else { throw MSeriesV11RunError.metadataBudget }
        return expanded
    }
}

struct MSeriesV11BudgetForecast: Sendable {
    let measuredSeconds: Double
    let plannedSeconds: Double
    let currentStorageBytes: Int
    let projectedStorageBytes: Int
}

enum MSeriesV11EvidenceBudget {
    // Leave 256 KiB for final curves, telemetry and the outer atomic history
    // record. This is an early stop threshold, not an increased write budget.
    static let maximumProjectedEvidenceBytes = 768 * 1024
    static func forecast(_ envelope: MSeriesV11Result, core: MSeriesResult?,
                         measuredSeconds: Double, plannedSeconds: Double) throws -> MSeriesV11BudgetForecast {
        let current = try JSONEncoder().encode(envelope).count
        let coreBytes = try core.map { try JSONEncoder().encode($0).count } ?? 0
        var fixed = envelope
        fixed.workloadBatches = []
        fixed.perStageEnvironment = [:]
        let encoder = JSONEncoder()
        encoder.userInfo[MSeriesV11CompactStorage.forceCompactEncoding] = true
        let fixedBytes = try encoder.encode(fixed).count
        let factor = max(1, plannedSeconds / max(1, measuredSeconds))
        // Identity, preflight and already computed windows do not grow once
        // per batch. Extrapolate only accumulated batches and observations.
        let projected = Double(fixedBytes) + Double(max(0, current - fixedBytes)) * factor + Double(coreBytes)
        return .init(measuredSeconds: measuredSeconds, plannedSeconds: plannedSeconds,
            currentStorageBytes: current + coreBytes,
            projectedStorageBytes: projected >= Double(Int.max) ? Int.max : Int(ceil(projected)))
    }
}

/// Detached work is awaited, including after cancellation. No SHA/JSON worker
/// survives the owning operation or publishes directly onto the main actor.
enum MSeriesV11BackgroundValidation {
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility, operation: body).value
    }
}
