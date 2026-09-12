# 1.9.8/v6 与 1.9.9/v9 跑分协议对比

本文比较的是协议能力与证据边界，不比较两个版本的总分高低。v6 被冻结为 Legacy；v9 是新的、不可混合的版本化协议。

## 两组真实证据

| 记录 | 证据 | 环境 | 用途 |
| --- | --- | --- | --- |
| 修改前 v6 本机五轮 | `/tmp/storage-cleaner-v1.9.9-benchmark-baseline-v6/v6-current-machine-five-runs.json` | AC、100%、LPM off、thermal nominal | 保留旧实现的真实快照 |
| v6 冻结参考 | `docs/benchmarks/mac-benchmark-m5-pro-standard-m5-pro-2026-07-v6.md` | M5 Pro，8 次 Release / 2 次独立冷却 session | 仅 v6 Legacy 比较 |
| 新 v9 校准 | `/tmp/storage-cleaner-v1.9.9-v9-calibration/v7-standard-1-runs.json` | AC、100%、LPM off、thermal nominal | 构建本机 r1 参考值 |
| 新 v9 正式五轮 | `/tmp/storage-cleaner-v1.9.9-v9-official-five-runs/v7-standard-5-runs.json` | AC、100%、LPM off、thermal nominal | 验证 v9 连续稳定性 |

## 协议差异

| 方面 | v6 Legacy | v9 新协议 |
| --- | --- | --- |
| 标准时长 | 约 25–30 秒 | 240–360 秒；本次五轮 251.602–253.480 秒 |
| CPU | 单/多核确定性 mix loop | 单核 mixed application-style + 多核真实粒子 workload，固定 seed、warm-up、checksum、24 raw samples/项 |
| GPU | 单一离屏 3D | 固定 2560×1440 graphics + FP16 compute，GPU execution 与 wall time，15 samples/项 |
| Memory | 64 MiB copy | 512 MiB copy、triad、pointer chase latency，15 samples/项 |
| Storage | 256 MiB 顺序 QD1 读写 | 顺序 + 4 KiB 随机 QD1/QD16、IOPS、P50/P95、13 samples/项、私有可清理测试目录 |
| Display | 无 executor | 真实 CVDisplayLink callback cadence P50/P95/P99、jitter、effective FPS；只计 Experience |
| 统计 | 3 samples / 项，中位数与 CV 门禁 | 保存全部 raw samples、median、MAD、relative MAD、sample count；raw samples 可事后推导 min/max，不选择最快值 |
| 评分 | 容量因素混入旧 Core | 版本化 35/25/20/20 加权几何 Core；Display 独立 Experience；缺项不重分权重 |
| 参考 | `m5-pro-2026-07-v6` | `local-m5-pro-controlled-v9-r1`，单台透明本机参考，不是排名 |
| 历史 | Legacy 保留 | schema / plan / workload / statistics / scoring / reference 版本全部记录，v2–v6 不改写 |

## 修改前 v6 本机五轮快照

| v6 项目 | 跨轮 median | relative MAD |
| --- | ---: | ---: |
| CPU single (Mops/s) | 420.416 | 0.085% |
| CPU multi (Mops/s) | 6714.639 | 1.777% |
| GPU (Mtri/s) | 2943.948 | 0.140% |
| Memory copy (GB/s) | 28.373 | 4.720% |
| Disk read (GB/s) | 0.185 | 2.399% |
| Disk write (GB/s) | 1.974 | 1.815% |

v6 冻结参考文档还记录了 8 次 Release / 2 次独立冷却 session，且只含聚合指标与 SHA-256，不含设备唯一标识。

## 新 v9 正式五轮摘要

- Core 跨轮中位数：6098.633；跨轮 relative MAD：0.0216%。
- Experience 跨轮中位数：6041.785；跨轮 relative MAD：0.2512%。
- 每轮均为 26 指标、无 runtime warning；结果级置信度为 2 次“中”、3 次“低”，原因是每轮内部某些 Core raw sample 的 rMAD 超过 5%/10%。
- 详细原始指标、显示 P50/P95/P99、随机存储 P50/P95 与证据 SHA-256 见 `docs/BENCHMARK_1_9_9_REAL_MAC_REPORT.md`。

## 禁止的直接比较

不得把 v6 与 v9 的 Core 数字、同名吞吐百分比或历史曲线直接相除/排名。输入、工作集、计时边界、样本量、磁盘缓存语义、统计、权重、参考集与评分语义均已改变；例如 v6 Memory 是 64 MiB copy，而 v9 是 512 MiB 的三项内存组，v6 GPU 是单图形 workload，而 v9 同时含 graphics 和 compute。

允许的结论仅是：v9 已补齐 v6 缺失的显示体验、随机存储、内存延迟/带宽、多类 GPU、版本化环境/统计/参考和独立持续性能路径；v6 历史仍保留在 Legacy，未被静默重算。

## 仍待发布级验证的事项

- 完整的真实应用 UI 手动开始、取消、离页返回与临时文件清理；
- 10 分钟持续 CPU→冷却→GPU 测试及其热/保持率记录；
- 已签名、已公证、已安装包的运行状态；
- 截图与录屏；
- 多设备、多个独立冷却 session 的参考集；
- 用户明确选择后的匿名上传端到端验证。
