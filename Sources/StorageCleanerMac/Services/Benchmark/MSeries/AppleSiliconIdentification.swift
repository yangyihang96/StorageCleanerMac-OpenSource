import Darwin
import Foundation
import Metal

enum AppleSiliconIdentificationStatus: Equatable, Codable, Sendable {
    case matched, ambiguous, unknownAppleSilicon, intel, rosetta
    case unrecognized(String)

    var rawValue: String {
        switch self {
        case .matched: "matched"
        case .ambiguous: "ambiguous"
        case .unknownAppleSilicon: "unknownAppleSilicon"
        case .intel: "intel"
        case .rosetta: "rosetta"
        case .unrecognized(let value): value
        }
    }
    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = switch value {
        case "matched": .matched
        case "ambiguous": .ambiguous
        case "unknownAppleSilicon": .unknownAppleSilicon
        case "intel": .intel
        case "rosetta": .rosetta
        default: .unrecognized(value)
        }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct AppleSiliconHardwareEvidence: Codable, Equatable, Sendable {
    struct PerfLevel: Codable, Equatable, Sendable {
        let index: Int
        let name: String?
        let physicalCores: Int?
        let logicalCores: Int?
    }
    let capturedAt: Date
    let nativeARM64: Bool
    let translated: Bool?
    let brandString: String?
    let modelIdentifier: String?
    let perfLevelCount: Int?
    let perfLevels: [PerfLevel]
    let physicalCPUCount: Int?
    let metalDeviceName: String?
    let profilerGPUName: String?
    let profilerGPUCores: Int?
    let physicalMemoryBytes: UInt64?
    let missingReasons: [String]
}

struct AppleSiliconIdentity: Codable, Equatable, Sendable {
    let identificationStatus: AppleSiliconIdentificationStatus
    let chipID: String?
    let matchedCPUOption: Int?
    let matchedSKU: AppleSiliconCatalog.SKU?
    let candidateSKUIDs: [String]
    let catalogVersion: String?
    let catalogSHA256: String?
    let identificationEvidence: AppleSiliconHardwareEvidence
    let reasonCodes: [String]
}

enum AppleSiliconIdentifier {
    static func normalizedName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// A pure function. Missing evidence and incomplete catalog topology stay unknown.
    static func identify(_ evidence: AppleSiliconHardwareEvidence,
                         catalog: AppleSiliconCatalogLoader.Loaded) -> AppleSiliconIdentity {
        func identity(_ status: AppleSiliconIdentificationStatus, chip: String? = nil,
                      option: Int? = nil, sku: AppleSiliconCatalog.SKU? = nil,
                      candidates: [String] = [], reasons: [String] = []) -> AppleSiliconIdentity {
            AppleSiliconIdentity(identificationStatus: status, chipID: chip, matchedCPUOption: option,
                matchedSKU: sku, candidateSKUIDs: candidates, catalogVersion: catalog.catalog?.catalogVersion,
                catalogSHA256: catalog.sha256, identificationEvidence: evidence,
                reasonCodes: reasons + (evidence.translated == nil ? ["translatedUnknown"] : []))
        }
        if evidence.translated == true { return identity(.rosetta, reasons: ["nativeARM64Required"]) }
        guard evidence.nativeARM64 else { return identity(.intel, reasons: ["nativeARM64Required"]) }
        guard let brand = evidence.brandString, let table = catalog.catalog,
              let chip = table.chips.first(where: { normalizedName($0.marketingName) == normalizedName(brand) }) else {
            return identity(.unknownAppleSilicon, reasons: [catalog.reason ?? "brandUnrecognized"])
        }
        for name in [evidence.metalDeviceName, evidence.profilerGPUName].compactMap({ $0 }) {
            if normalizedName(name) != normalizedName(chip.marketingName) {
                return identity(.ambiguous, chip: chip.id, reasons: ["deviceNameConflict"])
            }
        }
        let levels = evidence.perfLevels
        guard let count = evidence.perfLevelCount, count > 0, count == levels.count,
              Set(levels.map(\.index)) == Set(0..<count),
              levels.allSatisfy({ ($0.physicalCores ?? 0) > 0 }),
              let physical = evidence.physicalCPUCount, physical > 0,
              levels.reduce(0, { $0 + ($1.physicalCores ?? 0) }) == physical,
              let gpu = evidence.profilerGPUCores, gpu > 0 else {
            return identity(.ambiguous, chip: chip.id, reasons: ["skuUnverified"])
        }
        var topology: [String: Int] = [:]
        for level in levels {
            guard let name = level.name, let type = coreType(name),
                  level.logicalCores.map({ $0 >= (level.physicalCores ?? 0) }) ?? true else {
                return identity(.ambiguous, chip: chip.id, reasons: ["perfLevelUnverified"])
            }
            // Multiple distinct DIE levels add exactly once; index uniqueness was checked above.
            topology[type, default: 0] += level.physicalCores ?? 0
        }
        let candidates = chip.skus.filter { sku in
            let option = chip.cpu[sku.cpuOption]
            return sku.gpuCores == gpu && option.totalCores == physical
                && (!option.topologyVerified ||
                    (topology["super", default: 0] == option.superCores
                     && topology["performance", default: 0] == option.performanceCores
                     && topology["efficiency", default: 0] == option.efficiencyCores))
        }
        guard candidates.count == 1, let sku = candidates.first else {
            return identity(.ambiguous, chip: chip.id, candidates: candidates.map(\.id), reasons: ["skuUnverified"])
        }
        guard chip.cpu[sku.cpuOption].topologyVerified else {
            return identity(.ambiguous, chip: chip.id, candidates: [sku.id], reasons: ["skuTopologyUnverified"])
        }
        return identity(.matched, chip: chip.id, option: sku.cpuOption, sku: sku, candidates: [sku.id])
    }

    private static func coreType(_ name: String) -> String? {
        let tokens = name.lowercased().split { !$0.isLetter }.map(String.init)
        let matches = ["super", "performance", "efficiency"].filter { tokens.contains($0) }
        return matches.count == 1 ? matches.first : nil
    }
}

protocol AppleSiliconHardwareDataSource: Sendable {
    var nativeARM64: Bool { get }
    func string(_ key: String) -> String?
    func integer(_ key: String) -> Int?
    func memoryBytes() -> UInt64?
    func metalDeviceName() -> String?
    func profilerGPU() -> BenchmarkV7HardwareProfileCollector.AppleGPU?
}

enum AppleSiliconHardwareCollector {
    static func captureAsync(source: any AppleSiliconHardwareDataSource = SystemAppleSiliconHardwareDataSource(),
                             now: Date = Date()) async -> AppleSiliconHardwareEvidence {
        await Task.detached(priority: .utility) { capture(source: source, now: now) }.value
    }
    static func capture(source: any AppleSiliconHardwareDataSource = SystemAppleSiliconHardwareDataSource(),
                        now: Date = Date()) -> AppleSiliconHardwareEvidence {
        let count = source.integer("hw.nperflevels")
        let levels: [AppleSiliconHardwareEvidence.PerfLevel] = count.map { count in
            guard count > 0, count <= 256 else { return [] }
            return (0..<count).map { index in
                .init(index: index, name: source.string("hw.perflevel\(index).name"),
                      physicalCores: source.integer("hw.perflevel\(index).physicalcpu"),
                      logicalCores: source.integer("hw.perflevel\(index).logicalcpu"))
            }
        } ?? []
        let gpu = source.profilerGPU()
        let brand = source.string("machdep.cpu.brand_string")
        let translated = source.integer("sysctl.proc_translated").map { $0 != 0 }
        return AppleSiliconHardwareEvidence(capturedAt: now, nativeARM64: source.nativeARM64,
            translated: translated, brandString: brand, modelIdentifier: source.string("hw.model"),
            perfLevelCount: count, perfLevels: levels, physicalCPUCount: source.integer("hw.physicalcpu"),
            metalDeviceName: source.metalDeviceName(), profilerGPUName: gpu?.name, profilerGPUCores: gpu?.cores,
            physicalMemoryBytes: source.memoryBytes(), missingReasons:
                (brand == nil ? ["brandMissing"] : []) + (gpu == nil ? ["profilerGPUMissing"] : []))
    }
}

struct SystemAppleSiliconHardwareDataSource: AppleSiliconHardwareDataSource {
    var nativeARM64: Bool {
        #if arch(arm64)
        true
        #else
        false
        #endif
    }
    func string(_ key: String) -> String? {
        var size = 0
        guard sysctlbyname(key, nil, &size, nil, 0) == 0, size > 0, size <= 4096 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(key, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(bytes: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8)
    }
    func integer(_ key: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(key, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
    func memoryBytes() -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &value, &size, nil, 0) == 0, value > 0 else { return nil }
        return value
    }
    func metalDeviceName() -> String? { MTLCreateSystemDefaultDevice()?.name }
    func profilerGPU() -> BenchmarkV7HardwareProfileCollector.AppleGPU? {
        BenchmarkV7HardwareProfileCollector.captureAppleGPU()
    }
}
