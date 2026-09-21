import SwiftUI

struct MSeriesRawResultView: View {
    let result: MSeriesResult
    var body: some View {
        ContentPanel {
            VStack(alignment: .leading, spacing: AppDesignTokens.Spacing.medium) {
                Text(result.cancelled ? L10n.text("已取消 · 本次分项", "Cancelled · partial measurements") :
                        result.isCompleteCore ? L10n.text("Core 测量完整 · 原始结果", "Complete Core · raw results") :
                        L10n.text("分项测量结果", "Partial measurements"))
                    .font(AppDesignTokens.Typography.sectionTitle)
                Text(L10n.text("本协议整机性能指数：待真实参考校准", "Whole-machine performance index: awaiting reference calibration"))
                    .font(AppDesignTokens.Typography.secondary)
                Text(L10n.text("以下 A/B/C 仅表示样本稳定程度，不是统计置信度。", "A/B/C describe sample stability, not statistical confidence."))
                    .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                ForEach(result.metrics) { metric in
                    HStack(alignment: .firstTextBaseline) {
                        Text(title(metric.id)).frame(maxWidth: .infinity, alignment: .leading)
                        if let statistics = metric.statistics {
                            Text(statistics.median, format: .number.precision(.fractionLength(2)))
                                .monospacedDigit()
                            Text(metric.unit).foregroundStyle(.secondary)
                            Text("n=\(statistics.sampleCount) · \(statistics.confidence.rawValue)")
                                .foregroundStyle(.secondary).monospacedDigit()
                        } else {
                            Text(status(metric.availability)).foregroundStyle(.secondary)
                        }
                    }
                    .font(AppDesignTokens.Typography.metadata)
                    .help(metric.reason ?? "\(metric.workers) workers; \(metric.repetitions) repetitions")
                    .accessibilityElement(children: .combine)
                }
                DisclosureGroup(L10n.text("扩展项目状态", "Extension status")) {
                    ForEach(result.extensions) { metric in
                        HStack {
                            Text(title(metric.id)); Spacer()
                            if let statistics = metric.statistics {
                                Text("\(statistics.median.formatted(.number.precision(.fractionLength(2)))) \(metric.unit) · n=\(statistics.sampleCount)")
                                    .monospacedDigit()
                            } else { Text(status(metric.availability)) }
                        }.font(AppDesignTokens.Typography.metadata)
                    }
                }
                Text(L10n.text("测试写入：", "Test writes: ") + ByteFormat.string(Int64(result.writtenBytes)))
                    .font(AppDesignTokens.Typography.metadata).foregroundStyle(.secondary)
                Text(result.plan).font(AppDesignTokens.Typography.metadata).textSelection(.enabled)
            }
            .padding(AppDesignTokens.Layout.sectionPadding)
        }
    }
    private func title(_ id: String) -> String {
        let labels: [String: (String, String)] = [
            "integer": ("整数", "Integer"), "floating": ("浮点", "Floating point"),
            "compression": ("压缩", "Compression"), "image": ("图像", "Image"),
            "gpu.graphics.offscreen": ("GPU 离屏图形", "GPU offscreen graphics"),
            "gpu.compute.fp32": ("GPU FP32", "GPU FP32"), "gpu.compute.fp16": ("GPU FP16", "GPU FP16"),
            "memory.copy": ("内存复制", "Memory copy"), "memory.triad": ("内存 Triad", "Memory triad"),
            "memory.pointerChase": ("内存指针追逐", "Memory pointer chase"),
            "storage.seqRead": ("顺序读取", "Sequential read"), "storage.seqWrite": ("顺序写入", "Sequential write"),
            "storage.randomReadQD1": ("4K 随机读取 QD1", "4K random read QD1"),
            "storage.randomWriteQD1": ("4K 随机写入 QD1", "4K random write QD1")]
        if id.hasPrefix("cpu."), let family = id.split(separator: ".").last,
           let name = labels[String(family)] {
            return (id.contains("single") ? L10n.text("CPU 单线程 · ", "CPU single · ") : L10n.text("CPU 多线程 · ", "CPU multi · ")) + L10n.text(name.0, name.1)
        }
        if let label = labels[id] { return L10n.text(label.0, label.1) }
        return id
    }
    private func status(_ value: MSeriesAvailability) -> String {
        switch value {
        case .available: L10n.text("可用", "Available")
        case .unknown: L10n.text("未知", "Unknown")
        case .unsupported: L10n.text("不支持", "Unsupported")
        case .insufficientResources: L10n.text("资源不足", "Insufficient resources")
        case .failed: L10n.text("失败", "Failed")
        case .notImplemented: L10n.text("尚未实现", "Not implemented")
        case .cancelled: L10n.text("已取消", "Cancelled")
        }
    }
}
