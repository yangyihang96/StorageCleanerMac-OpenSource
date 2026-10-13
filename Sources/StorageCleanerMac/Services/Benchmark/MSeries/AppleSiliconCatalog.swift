import CryptoKit
import Foundation

/// Specifications are provenance, never benchmark reference values.
struct AppleSiliconCatalog: Codable, Equatable, Sendable {
    struct CPUOption: Codable, Equatable, Sendable {
        let performanceCores: Int?
        let efficiencyCores: Int?
        let superCores: Int?
        let totalCores: Int
        var topologyVerified: Bool {
            guard let performanceCores, let efficiencyCores, let superCores else { return false }
            return (0...1024).contains(performanceCores) && (0...1024).contains(efficiencyCores) && (0...1024).contains(superCores)
                && performanceCores + efficiencyCores + superCores == totalCores
        }
    }
    struct MacMemoryLimit: Codable, Equatable, Sendable {
        let model: String
        let maxUnifiedMemoryGB: Int
    }
    struct SKU: Codable, Equatable, Sendable {
        let id: String
        let cpuOption: Int
        let gpuCores: Int
        let memoryBandwidthGBps: Double?
        let maxUnifiedMemoryGB: Int?
        let memoryLimitsByMac: [MacMemoryLimit]?

        func memoryLimit(for model: String?) -> Int? {
            guard let model else { return maxUnifiedMemoryGB }
            // Apple Support 108052 / 102852: 2024 identifiers. Unknown hw.model
            // stays unknown when a SKU has machine-specific limits.
            let knownModels = [
                "Mac16,6": "MacBook Pro (14-inch, M4 Pro or M4 Max, 2024)",
                "Mac16,8": "MacBook Pro (14-inch, M4 Pro or M4 Max, 2024)",
                "Mac16,7": "MacBook Pro (16-inch, M4 Pro or M4 Max, 2024)",
                "Mac16,5": "MacBook Pro (16-inch, M4 Pro or M4 Max, 2024)",
                "Mac16,10": "Mac mini (2024)", "Mac16,11": "Mac mini (2024)"
            ]
            let catalogModel = knownModels[model] ?? model
            if let limits = memoryLimitsByMac, !limits.isEmpty {
                return limits.first { $0.model == catalogModel }?.maxUnifiedMemoryGB
            }
            return maxUnifiedMemoryGB
        }
    }
    struct Chip: Codable, Equatable, Sendable {
        struct Codec: Codable, Equatable, Sendable { let encode: Bool?; let decode: Bool? }
        struct MediaEngine: Codable, Equatable, Sendable {
            let proResEncode: Bool?
            let proResDecode: Bool?
            let av1Decode: Bool?
            let h264: Codec
            let hevc: Codec
            let videoDecodeEngines: Int?
            let videoEncodeEngines: Int?
            let proResEncodeDecodeEngines: Int?
        }
        struct Mac: Codable, Equatable, Sendable { let model: String; let cooling: String? }
        struct Unverified: Codable, Equatable, Sendable {
            let field: String
            let reason: String
            let checkedSources: [String]
        }
        let id: String
        let marketingName: String
        let year: Int?
        let process: String?
        let processDescription: String?
        let cpu: [CPUOption]
        let gpuCoreOptions: [Int]
        let skus: [SKU]
        let neuralEngineCores: Int?
        let neuralEngineTOPS: Double?
        let mediaEngine: MediaEngine
        let hardwareRayTracing: Bool?
        let dynamicCaching: Bool?
        /// Family provenance only. Never inherited by SKU.
        let memoryBandwidthGBps: Double?
        let maxUnifiedMemoryGB: Int?
        let typicalMacs: [Mac]
        let reviewStatus: String
        let sources: [String: [String]]
        let unverified: [Unverified]
    }
    let schemaVersion: String
    let catalogVersion: String
    let verifiedAsOf: String
    let reviewStatus: String
    let chips: [Chip]

    var isValid: Bool {
        schemaVersion == "apple-silicon-catalog-v2" && !catalogVersion.isEmpty && !chips.isEmpty
            && Set(chips.map(\.id)).count == chips.count
            && Set(chips.flatMap { $0.skus.map(\.id) }).count == chips.reduce(0) { $0 + $1.skus.count }
            && chips.allSatisfy { chip in
                !chip.id.isEmpty && !chip.marketingName.isEmpty
                    && chip.cpu.allSatisfy { option in
                        (1...1024).contains(option.totalCores) && ([option.performanceCores, option.efficiencyCores, option.superCores]
                            .allSatisfy { $0 == nil } || option.topologyVerified)
                    }
                    && chip.skus.allSatisfy { sku in
                        !sku.id.isEmpty && chip.cpu.indices.contains(sku.cpuOption)
                            && sku.gpuCores > 0 && chip.gpuCoreOptions.contains(sku.gpuCores)
                            && (sku.memoryBandwidthGBps.map { $0.isFinite && $0 > 0 } ?? true)
                            && (sku.maxUnifiedMemoryGB.map { $0 > 0 } ?? true)
                            && (sku.memoryLimitsByMac?.allSatisfy { !$0.model.isEmpty && $0.maxUnifiedMemoryGB > 0 } ?? true)
                    }
            }
    }
}

enum AppleSiliconCatalogLoader {
    struct Loaded: Equatable, Sendable {
        let catalog: AppleSiliconCatalog?
        let sha256: String?
        let reason: String?
        var specificationsUnknown: Bool { catalog == nil }
    }
    struct Manifest: Codable, Sendable { let catalogVersion: String; let sha256: String }

    static func load(bundle: Bundle = .main) -> Loaded {
        load(catalogURL: bundle.url(forResource: "AppleSiliconCatalog", withExtension: "json", subdirectory: "Benchmark"),
             manifestURL: bundle.url(forResource: "AppleSiliconCatalog", withExtension: "manifest.json", subdirectory: "Benchmark"))
    }

    /// SwiftPM tests inject URLs. No Bundle.module or repository fallback in production.
    static func load(catalogURL: URL?, manifestURL: URL?) -> Loaded {
        guard let catalogURL, let manifestURL else {
            return Loaded(catalog: nil, sha256: nil, reason: "catalogMissing")
        }
        do {
            let bytes = try Data(contentsOf: catalogURL)
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
            return decode(bytes, manifest: manifest)
        } catch { return Loaded(catalog: nil, sha256: nil, reason: "catalogUnreadable") }
    }

    static func decode(_ bytes: Data, manifest: Manifest) -> Loaded {
        guard bytes.count <= 1_048_576 else { return Loaded(catalog: nil, sha256: nil, reason: "catalogTooLarge") }
        let digest = MSeriesV11Digest.sha256(bytes)
        guard digest == manifest.sha256 else { return Loaded(catalog: nil, sha256: digest, reason: "catalogHashMismatch") }
        guard let catalog = try? JSONDecoder().decode(AppleSiliconCatalog.self, from: bytes),
              catalog.isValid, catalog.catalogVersion == manifest.catalogVersion else {
            return Loaded(catalog: nil, sha256: digest, reason: "catalogInvalid")
        }
        return Loaded(catalog: catalog, sha256: digest, reason: nil)
    }
}

enum MSeriesV11Digest {
    static func sha256(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
