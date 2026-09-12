# 1.9.9 跑分现状审计（修改前）

审计日期：2026-08-01。本文只记录仓库当前 `mac-benchmark-standard-v6` 的真实行为；它不是新协议的发布声明。

## 执行边界

- 工作区：`/private/tmp/storage-cleaner-v1.9.9-login-items`
- 分支：`codex/login-items-v1.9.9`，基线提交 `29b4c2b`
- 运行时：Xcode 27.0 / Swift 6.4 / macOS arm64
- 已有冻结参考：`m5-pro-2026-07-v6`，8 次 Release run、两次独立冷却 session；其文档为 `docs/benchmarks/mac-benchmark-m5-pro-standard-m5-pro-2026-07-v6.md`。
- 修改前的五次本机 Release 捕获：`/tmp/storage-cleaner-v1.9.9-benchmark-baseline-v6/v6-current-machine-five-runs.json`。该捕获通过显式 XCTest 开关执行 `MacBenchmarkService`，未写入应用历史、未调用排行榜上传。
- 当时环境：交流电、100%、Low Power Mode 关闭、pre/post thermal 均为 `nominal`、磁盘可靠性 `verified`、无遗留 `BenchmarkTemporary/*.tmp` 文件。

## 当前模块与计时协议

| 项目 | 当前 workload / 输入 | 正式计时边界 | 采样与验证 | 已知限制 |
| --- | --- | --- | --- | --- |
| CPU 单核 | 固定 seed 的 4,096 `UInt64` 输入上的整数/浮点 mix loop；`96,000,000` operations | `DispatchTime.uptimeNanoseconds` 在 input 分配、初始化和 warm-up 后开始，到 loop 完成后结束 | 3 次；每次固定 checksum；中位数进入评分 | 不是压缩、图像、JSON、FFT 或物理应用 workload；无 calibration |
| CPU 多核 | 同一确定性 mix，固定 worker 数 `activeProcessorCount - 1`，每 worker `768,000,000` operations | 每个 worker warm-up 后，经 start gate 同步的 monotonic timestamp 开始，所有 worker 完成后结束 | 3 次；每 partition 输出汇总 checksum；样本间 2 秒恢复 | 是并行真实工作分片，但仍是合成 mix；无 calibration |
| GPU | Metal 离屏 3D：1920×1080、262,144 instances、600 frames、固定程序几何/Shader | device / queue / pipeline / texture 创建与 warm-up 在正式段外；command-buffer GPU timestamp 可用时为结果，否则回退到 submit-to-completion wall time | 3 次；最后 frame readback checksum，command buffer status/error 检查 | 没有独立保存 GPU-time 与 wall-time；最终 readback blit 仍在 timed command buffer；没有 compute 子项 |
| Memory | 64 MiB 总工作集，32 MiB source + 32 MiB destination，固定 xorshift seed，`memcpy` copy | 分配、初始化、seed 填充和预拷贝在正式段外；copy pass 开始至最后 pass 完成 | 3 次；每 pass `memcmp`，结束后 checksum | 只有 copy bandwidth；`memcmp` 在 timed loop 内；无 read/write/triad/random/pointer-chase/多线程；工作集不足以构成新版 Standard 的 512 MiB 语义 |
| Disk 写 | 私有 `BenchmarkTemporary` 内唯一文件，256 MiB，1 MiB block，QD1，固定低可压缩 block，3 durable passes | 每 pass 从首个 write 到 `F_FULLFSYNC`/`fsync` 完成；三个 pass 用中位数 | 每个 standard run 3 次；固定 file checksum；失败/取消 `defer` 清理 | 没有随机 4 KiB、IOPS、latency/QD16 或用户选择卷；缓存策略未记录为结果字段 |
| Disk 读 | 同一 256 MiB 文件，1 MiB sequential QD1 | rewind 后首个 read 到最后 read 完成 | 每块与固定 block 比对；file checksum | 虽请求 `F_NOCACHE`，写后立即读，不能证明完全绕过系统缓存；没有随机读或 P50/P95 latency |
| Display | 无 executor | 不适用 | 不适用 | 没有 display-link cadence、frame pacing 或 Experience Score；当前不把刷新率写入 Core，保留这一正确边界 |

所有正式短时计时均用单调 uptime，不用 `Date`。UI 进度由 sample/stage 完成事件驱动，不在内核逐迭代发布；但 GPU 阶段仍有 30fps Canvas/TimelineView，可能争抢 GPU。

## 统计、评分、版本与持久化

- 当前每个 core 项 3 个 raw sample，评分用中位数；CV 用作稳定性门禁；MAD、relative MAD、P50/P95/P99 仅为诊断，不改变 v6 分数。
- 失败 checksum、无效值或不同 sample checksum 会拒绝完整结果；没有显式 rejected-sample/reason 字段，因而也没有确定性 outlier policy。
- v6 Core 权重为 `CPU single 14% + CPU multi 21% + GPU 25% + Memory 20% + Disk read 11% + Disk write 9%` 的几何平均，显示基线为 `6000`。
- v6 同时把内存容量 25%、磁盘容量各 10% 混入分项；这不符合 1.9.9 的纯性能 Core 语义，必须作为 Legacy 保留，不能静默改写。
- 当前 `BenchmarkAlgorithmManifest` 为读取时计算属性，并非不可变结果字段；历史仓库虽按 profile/workload 分桶并具备防损坏锁，但 Store 重新处理原始结果时可能按当前 processor 重算同 workload 的旧结果。
- 当前 profile：公开 UI 仅暴露 `standard`；`quick`/`full` 只为旧历史解码。标准实测约 20–35 秒，不满足新定义的 4–6 分钟；持续测试当前固定约 120 秒且 CPU/GPU 并行。

## 当前 Preflight、状态与资源清理

- 已检查：外部电源/电量、Low Power Mode、thermal、SMART 摘要、可用空间。
- 当前策略把非 AC、fair/serious/unknown thermal 直接阻止；不含后台 CPU/GPU 观察、可用内存、目标卷只读、显示模式或镜像检查，也没有“继续但降低置信度”的结构化记录。
- `MacBenchmarkStore` 是 App scoped，页面离开不会销毁当前 task；`HeavyWorkCoordinator` 排斥其他重任务；UUID generation 丢弃旧回调；退出会取消并等待清理。
- 但 core、accelerator、sustained 各自维护状态/task，尚不是单一权威 session state machine。持续 workload 当前用 `async let` 同时跑 CPU/GPU，违反新的串行类别要求。
- 磁盘测试只触及 App 私有临时目录，使用唯一文件名，成功/失败/取消均会关闭 descriptor 并删除测试文件；本次五次捕获后已核对目录为空。

## 修改前真实五次基线

五次 runs 的总时长为 25.42–29.46 秒，中位数 25.97 秒。以下是“每次 run 内三个 sample 的中位数”再跨 run 聚合的结果；MAD 为未缩放 median absolute deviation。

| 项目 | 跨 run median | MAD | relative MAD |
| --- | ---: | ---: | ---: |
| CPU 单核（Mops/s） | 420.416 | 0.357 | 0.085% |
| CPU 多核（Mops/s） | 6714.639 | 119.304 | 1.777% |
| GPU（Mtri/s） | 2943.948 | 4.131 | 0.140% |
| Memory copy（GB/s） | 28.373 | 1.339 | 4.720% |
| Disk read（GB/s） | 0.185 | 0.004 | 2.399% |
| Disk write（GB/s） | 1.974 | 0.036 | 1.815% |

第三次 run 的 memory/disk read 和第四次 run 的 CPU 发生了可见波动，正是新协议需要保存所有 raw samples、显示 MAD，并禁止“只选最快一次”的原因。这个 v6 基线不与后续 v7 结果直接比较。

## 修改结论

1. 冻结 v6 输入、工作负载、评分、参考与历史为 Legacy；不修改其基线或伪装为 v7。
2. 新协议必须建立一等的 plan/workload/statistics/scoring/reference schema，持久化原始样本、环境、计时与版本。
3. 新 Core 只使用 CPU、GPU、Memory、Storage；Display 只生成 Experience 结果；AI 保持实验模块；上传改为显式 opt-in。
4. 先消除 GPU UI 污染与持续 CPU/GPU 并行，再把新的 measurement、preflight、statistics、scoring 与 history 连接到同一个 App-scoped coordinator。
