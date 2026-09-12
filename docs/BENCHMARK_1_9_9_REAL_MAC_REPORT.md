# 1.9.9 v9 本机真实跑分报告（早期校准历史）

> 当前 1.9.9 / 202607302202 身份已重新完成三次 Release standard 采集；权威结果见 `docs/1.9.9-benchmark-validation.md` 和 `artifacts/1.9.9-benchmark-real-20260803/release-3-runs/v7-standard-3-runs.json`。本文件以下五轮仍保留为早期校准历史，其 XCTest host 版本不能证明应用版本。

日期：2026-08-01。本文只陈述本次工作区中的真实 Release XCTest 捕获；它不是线上排行榜、签名发布物或跨设备百分位结论。

## 证据与状态

- 校准原始记录：`/tmp/storage-cleaner-v1.9.9-v9-calibration/v7-standard-1-runs.json`，SHA-256 `ded079dc1d2599c57b67372d7f48168bff5e3524baa17d3d154d5897dee3fcfd`。
- 正式五轮原始记录：`/tmp/storage-cleaner-v1.9.9-v9-official-five-runs/v7-standard-5-runs.json`，SHA-256 `3713f72610fcf32a3fb7ee7c2db3f87754ea6c7323f351ba6824157eec7c14d7`。
- Harness：SwiftPM Release XCTest；`BenchmarkV7RealHardwareCaptureTests` 明确绕过应用历史和排行榜写入。
- 五轮捕获状态：全部 `completed`，0 个 failure，0 个 runtime warning，每轮 26 个指标。
- 当前环境：Apple M5 Pro、18 个 active processors、48 GiB RAM、arm64、macOS 27.0 (26A5388g)、交流电、100% 电量、Low Power Mode 关闭、thermal `nominal`、目标卷 `Macintosh HD` 可写。
- 每轮 preflight 的后台负载为 22.27%–52.78%，均未触发当前协议的 warning 阈值；可用内存约 15.67–20.12 GiB，可用目标卷约 321.84–321.94 GiB。
- 测试宿主的 `appVersion=16.0` / `appBuild=25181.5` 来自 XCTest host，不能作为已打包应用版本的证据；打包/安装态另行验证。

## 冻结协议

| 字段 | 值 |
| --- | --- |
| schema | `benchmark-result-v7` |
| plan / workload | `benchmark-standard-plan-v9` / `benchmark-standard-v9` |
| 时长承诺 | 240–360 秒 |
| scoring | `benchmark-scoring-v9`，Core baseline 6000 |
| Core 权重 | CPU 35%、GPU 25%、Memory 20%、Storage 20%；类别内均为版本化加权几何平均 |
| Display | `display-cadence-v8`；只进入 Experience Score，不进入 Core |
| Reference Set | `local-m5-pro-controlled-v9-r1`；单台受控本机 Release 校准、sampleCount=1、非排名/非百分位 |

v9 校准实际用时 253.960 秒，产生完整 26 指标；其 raw metric medians 被冻结为 r1 参考值。该校准记录仍带临时 `r0` 标识，因为 r1 正是由这份 raw 数据生成；不能把它误称为独立的 r1 评分结果。

## 正式五轮结果

| 轮次 | 用时 | Core | Experience | 结果级置信度 | 最大 Core rMAD |
| --- | ---: | ---: | ---: | --- | ---: |
| 1 | 253.271 s | 6037.161 | 5967.624 | 中 | 6.629% |
| 2 | 253.480 s | 6098.073 | 6026.610 | 中 | 9.005% |
| 3 | 251.602 s | 6113.960 | 6041.785 | 低 | 10.590% |
| 4 | 251.835 s | 6098.633 | 6052.166 | 低 | 13.619% |
| 5 | 252.069 s | 6099.950 | 6060.755 | 低 | 13.096% |

- 用时中位数：252.069 秒，全部处于 4–6 分钟承诺内。
- Core 跨轮中位数：6098.633；跨轮 relative MAD：0.0216%。
- Experience 跨轮中位数：6041.785；跨轮 relative MAD：0.2512%。
- 结果级“低”不表示 run 无效：它诚实反映某一 Core 原始指标在**该轮内部**的 relative MAD 超过 10%。五轮均保留，没有按分数或波动筛掉任何一轮。

## 跨轮聚合原始指标

下表是“每轮内部 raw samples 的 median”再跨五轮取 median；最后一列为跨轮 relative MAD。所有完整 raw samples、checksum（适用项）、within-run statistics 与计时仍保存在上方 JSON 证据中。

| 指标 | 跨轮中位数 | 跨轮 rMAD | 五轮范围 |
| --- | ---: | ---: | ---: |
| CPU single mixed (Mops/s) | 622.052 | 0.204% | 620.781–625.271 |
| CPU multi particle (Mops/s) | 19843.583 | 0.062% | 19029.343–20008.615 |
| GPU graphics offscreen (Mtri/s) | 2087.453 | 0.034% | 2085.992–2090.197 |
| GPU compute FP16 (TFLOPS) | 30.810 | 0.025% | 30.777–30.830 |
| Memory copy (GB/s) | 125.227 | 0.682% | 123.216–126.389 |
| Memory triad (GB/s) | 118.060 | 1.097% | 116.583–119.355 |
| Memory pointer chase (ns) | 106.116 | 0.394% | 105.645–106.846 |
| Sequential read (GB/s) | 0.190225 | 0.056% | 0.190118–0.191709 |
| Sequential write (GB/s) | 6.652 | 0.089% | 6.603–6.709 |
| Random read QD1 (IOPS) | 11553.255 | 0.524% | 11445.674–11657.802 |
| Random read QD1 P50 / P95 (ns) | 80250 / 114333 | 0.312% / 2.806% | 80000–81250 / 109916–119250 |
| Random read QD16 (IOPS) | 121121.579 | 1.665% | 118539.741–123247.818 |
| Random read QD16 P50 / P95 (ns) | 122167 / 189375 | 1.995% / 0.968% | 119167–128167 / 187542–193083 |
| Random write QD1 (IOPS) | 9382.280 | 0.116% | 9303.436–9393.163 |
| Random write QD1 P50 / P95 (ns) | 89542 / 132167 | 0.093% / 0.284% | 89458–89625 / 131791–134083 |
| Random write QD16 (IOPS) | 33868.848 | 0.510% | 33034.999–34279.127 |
| Random write QD16 P50 / P95 (ns) | 246562.5 / 1464584 | 0.668% / 0.486% | 242750–249334 / 1441042–1471916 |
| Display cadence P50 / P95 / P99 (ms) | 8.3310 / 10.2927 / 10.3136 | 0.006% / 0.013% / 0.049% | 8.3304–8.3316 / 10.2888–10.2940 / 10.3084–10.3192 |
| Display jitter (ms) | 1.0060 | 2.015% | 0.9553–1.0262 |
| Effective display FPS | 120.0096 | 0.005% | 119.9851–120.0201 |

## 已验证与未验证边界

已验证：Release 构建、版本化 v9 协议、CPU/GPU/Memory/Storage/Display 的真实本机采样、Core 与 Experience 分离、五轮连续捕获、无自动上传，以及原始样本与统计写入本次证据 JSON。

尚未验证：真实应用窗口中的手动开始/取消与返回页面恢复、应用内 v7 历史持久化的端到端行为、完整 10 分钟持续性能 run、最终包装后的签名/公证/安装态、录屏、跨设备参考集、匿名上传 opt-in 的端到端行为。此次 XCTest 捕获明确绕过应用历史库；历史仓库仅有源码与单元测试覆盖。Reference r1 只有一台机器/一个校准会话，不能用于“超过多少 Mac”或任何全网排名表述。
