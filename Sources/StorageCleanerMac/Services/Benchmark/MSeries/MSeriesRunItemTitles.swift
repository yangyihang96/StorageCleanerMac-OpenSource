import Foundation

enum MSeriesRunItemTitles {
    static let titles: [String: String] = {
        var result: [String: String] = [:]
        for (prefix, group) in [("cpu.single", "CPU 单线程"), ("cpu.multi", "CPU 多线程")] {
            for (suffix, name) in [("integer", "整数"), ("floating", "浮点"), ("compression", "压缩"), ("image", "图像处理")] {
                result[prefix + "." + suffix] = group + " · " + name
            }
        }
        let fixed = [
            "gpu.graphics.offscreen": "GPU · 离屏图形", "gpu.compute.fp32": "GPU · 单精度计算",
            "gpu.compute.fp16": "GPU · 半精度计算", "memory.copy": "内存 · 复制",
            "memory.triad": "内存 · 三数组运算", "memory.pointerChase": "内存 · 指针追逐",
            "storage.seqRead": "存储 · 顺序读取", "storage.seqWrite": "存储 · 顺序写入",
            "storage.randomReadQD1": "存储 · 4K 随机读取", "storage.randomWriteQD1": "存储 · 4K 随机写入",
            "cpu.extensions.remaining": "CPU 扩展观察 · 未完成项", "gpu.advanced": "GPU 高级图形",
            "gpu.hardwareRayTracing": "GPU 硬件光线追踪", "memory.workingSetCurve": "内存工作集曲线",
            "storage.workingSetQueueCurve": "存储工作集与队列曲线", "media.h264": "媒体引擎 · H.264 编解码",
            "media.hevc": "媒体引擎 · HEVC 编解码", "media.prores": "媒体引擎 · ProRes 编解码",
            "media.av1.decode": "媒体引擎 · AV1 解码", "ai.image": "神经网络 · 图像推理",
            "ai.text": "神经网络 · 文本推理", "display.framePacing": "显示 · 帧间隔稳定性",
            "power.efficiency": "能效观察", "power.cpu.single": "CPU 能效 · 单线程",
            "power.cpu.performanceCores": "CPU 能效 · 最高性能核心数量线程", "power.cpu.allCores": "CPU 能效 · 全核心",
            "power.gpu.peak": "GPU 峰值与能效 · 三维图形", "sustained.cpu.allCores": "持续性能 · CPU 全核心",
            "sustained.gpu": "持续性能 · GPU 三维图形", "pressure.cpu.allCores": "压力观察 · CPU 全核心",
            "pressure.gpu": "压力观察 · GPU 三维图形", "gpu.hardwareRayTracing.build": "GPU 光线追踪 · 结构构建",
            "gpu.hardwareRayTracing.traversal": "GPU 光线追踪 · 遍历", "gpu.tensor.fp16": "GPU 矩阵计算 · 半精度",
            "ai.smallModel.cpu": "神经网络小模型 · CPU", "ai.smallModel.aneCandidate": "神经网络小模型 · 神经网络引擎候选路径",
            "ai.smallModel.accelerationRatio": "神经网络小模型 · 加速比", "preflight": "环境预检",
            "finalizing": "正在保存 · 本机历史", "cancelling": "正在停止测试", "accelerators": "独立加速单元",
            "gpu.raster3d": "GPU 三维光栅", "gpu.rayTracing.build": "GPU 光追结构构建",
            "gpu.rayTracing.traversal": "GPU 光追遍历", "gpu.tensor.fp16Gemm": "GPU 半精度矩阵"
        ]
        result.merge(fixed) { _, new in new }
        for codec in ["h264", "hevc", "prores"] {
            let name = codec == "h264" ? "H.264" : codec == "hevc" ? "HEVC" : "ProRes"
            result["media.\(codec).encode"] = "媒体引擎 · \(name) 编码"
            result["media.\(codec).decode"] = "媒体引擎 · \(name) 解码"
        }
        return result
    }()

    static func chineseTitle(for id: String) -> String {
        if let title = titles[id] { return title }
        for (prefix, format) in [("cpu.threadCurve.", "CPU 线程曲线 · %d 线程"),
                                 ("cpu.sustained.short.", "CPU 短持续观察 · 第 %d 批")] where id.hasPrefix(prefix) {
            let suffix = String(id.dropFirst(prefix.count))
            if !suffix.isEmpty, suffix.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(suffix), n > 0 {
                return String(format: format, n)
            }
        }
        return "扩展测试 · 名称待适配"
    }
}
