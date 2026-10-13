import Foundation

extension MSeriesV11PagePresentation {
    struct SpecificationRow: Identifiable, Equatable {
        let peerID: String
        let peerName: String
        let skuID: String
        let field: String
        let title: String
        let value: Double?
        let sources: [URL]
        let unknownReason: String?
        var id: String { peerID + "/" + skuID + field }
        var sourceLabel: String { peerName + " · " + skuID + " · " + title }
    }
    static func specificationRows(_ peer: AppleSiliconCatalog.Chip, skuIndex: Int) -> [SpecificationRow] {
        guard peer.skus.indices.contains(skuIndex) else { return [] }
        let sku = peer.skus[skuIndex]
        let cpu = peer.cpu.indices.contains(sku.cpuOption) ? Double(peer.cpu[sku.cpuOption].totalCores) : nil
        let fields: [(String, String, Double?)] = [
            ("/cpu/\(sku.cpuOption)/totalCores", "CPU", cpu),
            ("/skus/\(skuIndex)/gpuCores", "GPU", Double(sku.gpuCores)),
            ("/skus/\(skuIndex)/memoryBandwidthGBps", "GB/s", sku.memoryBandwidthGBps)
        ]
        return fields.map { field, title, raw in
            let sources = (peer.sources[field] ?? []).compactMap { address -> URL? in
                guard let url = URL(string: address), ["https", "http"].contains(url.scheme ?? ""), url.host != nil else { return nil }
                return url
            }
            let unverified = peer.unverified.first { $0.field == field }
            let value = unverified == nil && !sources.isEmpty ? raw.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } : nil
            return .init(peerID: peer.id, peerName: peer.marketingName, skuID: sku.id, field: field,
                title: title, value: value, sources: sources,
                unknownReason: unverified?.reason ?? (value == nil ? unread : nil))
        }
    }
}
