# Mac 跑分生产校准

这里保存 Standard v6 的可复核聚合校准报告，以及只用于读取旧历史的 v3/v4 报告。v6 的六项真实性能 workload 使用加权几何综合，同时把内存和系统盘容量以有界比例纳入对应分项；异常性能比直接拒绝，不截断成看似正常的分数。v5 从未形成可发布基线。生产基线只能来自最终 workload 的 Release 构建和指定参考机，不能填写估算值或测试 fixture。

参考机固定为：MacBook Pro `Mac17,9`、Apple M5 Pro、18 核、48 GiB、arm64。收集器会从 `sysctl hw.model` 读取机型标识，并再次核对真实跑分结果里的芯片、核心数、内存、架构、电源和 thermal 状态；不能通过环境变量伪填硬件。

## 方法设计依据

- [安兔兔 PC 版说明](https://www.antutu.com/doc/132827.htm)把 CPU、GPU、内存和体验拆成独立场景，并把稳定性压力测试与一次综合跑分分开。这里采用同样的“分项原始指标 + 综合分”思路，但不复制其封闭工作负载或分数。
- [鲁大师 PC 版](https://www.ludashi.com/page/pc.php)公开呈现硬件综合得分，其[更新日志](https://www.ludashi.com/page/pclog.php)也说明计分规则会随版本调整；但公开页面没有给出足够细的 workload、权重与归一化公式。因此这里只参考“分项结果 + 综合分 + 规则版本化”的产品表达，不把其分数或排名当作本项目基线。
- [Geekbench 6 Benchmark Internals](https://www.geekbench.com/doc/geekbench6-benchmark-internals.pdf)公开了参照机归一化、几何平均与分组加权思路；这里同样固定参照值和 workload version，同时保留可直接审计的六项线性分数。
- [SPEC CPU 2017](https://www.spec.org/cpu2017/Docs/overview.html)以参照机比值、三次正式运行的中位数和几何平均构成可比较结果；v6 同样不选择最好一次成绩，也不让单项极值主导整机指数。
- [PCMark 10 计分说明](https://support.benchmarks.ul.com/support/solutions/articles/44002182065-how-are-pcmark-10-benchmark-scores-calculated-)使用分组后的几何综合；v6 借鉴这一结构，但公开自己的固定权重与全部原始中位数。
- [Cinebench](https://www.maxon.net/en/tech-info-cinebench)和 [Blender Benchmark](https://www.blender.org/news/introducing-blender-benchmark/)都使用真实渲染场景，而不是只执行抽象 GPU 算术。因此 Standard 的 GPU 项使用离屏 Metal 3D 渲染，并以 Mtri/s 报告；旧版 Gops/s 记录不与其混用。
- [极客湾的硬件实测](https://www.bilibili.com/video/BV1f1d6YfE6i/)通常同时观察性能释放、温度和功耗。这里不自动改变用户电源模式，也不终止其他进程；只在运行前后检查电源、低电量模式和 thermal 状态，环境失配就不生成可比分。

当前 Standard 固定为 3 次采样并取中位数，同时展示 CV。CPU 分单核/多核，GPU 为真实 Metal 3D，内存为带宽，磁盘为受控私有文件的持久读写。CPU/GPU 分项为 `1000 × 性能比`；内存分项为 `75% × 性能分 + 25% × 容量分`，磁盘读取和写入分项分别为 `90% × 性能分 + 10% × 容量分`。容量比使用实际容量与参考容量比值的平方根，并限制在 `0.25...2.0`；参考容量为 48 GiB 内存和 994,610,155,520 字节系统盘。综合分为 `6000 × single^0.14 × multi^0.21 × gpu^0.25 × memory^0.20 × read^0.11 × write^0.09`，其中内存和磁盘变量使用上述有效分项比。参照机为 6000 分；容量有界且只影响自己的分项，不能盖过真实吞吐。

评分器只接受精确登记的 profile/workload 组合：v2 保留旧加权指数，v3/v4 保留冻结的直接求和，v5 只用于读取从未公开发布的容量实验历史，v6 使用上述几何公式；未知版本绝不猜测或回退到相邻公式。任何从历史或网络恢复的结果都必须再次满足对应 workload 的 3/5 次样本数，而且同一分项的全部样本校验和必须一致，否则只保留原始数据、不生成综合分。v6 的单项性能比只接受闭区间 `0.02...5`，越界视为异常证据而不是截断成一个看似正常的分数。

v6 的 CPU 单核、CPU 多核、内存和磁盘读取 CV 上限为 5%，GPU 和持久写入上限为 10%；超限时不生成可比分。CV 只作为稳定性门禁，不直接扣分。全部工作负载完成后的终测快照若发现电源、低电量模式、热状态或磁盘条件变差，六项样本仍会保存为 raw-only 证据；只有终测快照无法读取或结构损坏时才拒绝整条结果。下一次增加 workload 时应升级到 v7 并重新校准，优先补充内存延迟、随机磁盘访问和第二个 3D 场景。持续压力、散热衰减和能耗应作为独立测试展示，不能偷偷混入一次综合分。

排行榜服务与客户端必须使用同一份冻结 v6 基准、权重、容量公式和参考容量。v6 协议会随六项中位数一并携带样本数、CV、物理内存和系统盘容量；服务端独立验证 3 次采样、5%/10% 的含端点门限，并重新计算分项与总分。旧 v3/v4 请求仍按冻结协议兼容，但不会混入 v6 榜单。

## 图形与媒体加速实验套件

`mac-accelerator-suite-v1` 是与现有 Mac 综合跑分完全分开的 raw-only 实验套件。它不修改 `mac-benchmark-standard-v6` 的六项工作负载、权重、参照值或源码指纹，也不会上传公共排行榜。在完成独立的参考机采样、跨会话稳定性验证和版本冻结前，界面只能显示原始中位数、单位、CV 和可用性状态，不能生成子分或综合分。每条结果同时持久化加速套件自己的 SHA-256 工作负载指纹；场景、shader、矩阵参数、批次或视频内容校验发生变化时必须更新指纹，旧记录不能混作同一工作负载。

固定指标如下，每项测量均执行 3 次并取中位数：

- 离屏 Metal 3D 光栅化：程序内生成固定立方体场景，以 Metal command-buffer GPU 时间报告 Mtri/s。
- Metal 光线追踪结构构建和遍历：程序内生成固定三角形场景与光线，分别报告 Mtri/s 和 Mray/s。只有同时满足 [`supportsRaytracing`](https://developer.apple.com/documentation/metal/mtldevice/supportsraytracing) 与 [Apple GPU family 9/10](https://developer.apple.com/metal/capabilities/) 的设备才标记为固定功能光追硬件；不支持时记为 `unsupported`，不写入 0 值。
- GPU FP16 矩阵计算：使用 [`MPSMatrixMultiplication`](https://developer.apple.com/documentation/metalperformanceshaders/mpsmatrixmultiplication) 和显式 Metal 命令缓冲区报告有效 TFLOP/s。这里不使用 Core ML `cpuAndGPU` 来冒充纯 GPU 数值，因为[该计算单元允许 CPU 和 GPU 共同参与](https://developer.apple.com/documentation/coreml/mlcomputeunits/cpuandgpu)。
- H.264 硬件编码与解码：分别报告 MPix/s，并通过 VideoToolbox 的 `RequireHardwareAcceleratedVideoEncoder` / `RequireHardwareAcceleratedVideoDecoder` 禁止软件回退；再读取 `UsingHardwareAcceleratedVideoEncoder` / `UsingHardwareAcceleratedVideoDecoder` 验证真实路径。媒体引擎指标必须标记为 Media Engine，不得冒充 GPU 子项。

固定工作负载、几何、材质、相机、分辨率、编解码帧和校验摘要全部在内存中确定性生成，不下载外部模型，不读取用户素材，不把测试文件留在用户目录。GPU 矩阵 CV 上限为 5%，光追遍历和硬件解码为 8%，光栅 3D、光追结构构建与硬件编码为 10%。CV 仅是稳定性信号，不换算分数。硬件不支持与资源暂时不可用必须分开展示；两者都不能通过重新分配权重来抬高结果。未来若纳入总分，必须升级新的综合跑分协议（至少 v7）并重新完成整套冻结校准。

## 安全边界

- 普通 `swift test` 不会执行真实跑分。
- 只有 `swift test -c release`，且显式设置 `MAC_BENCHMARK_CALIBRATION_ACTION=collect` 与当前发布运行护栏时，才会运行工作负载；Debug 构建直接失败。
- 原始记录只含跑分模型已有的聚合环境与指标，以及 `session-1` / `session-2` 这类非设备唯一标签。
- 不保存序列号、硬件 UUID、UDID、用户名、文件路径或 IP。
- 当前 Standard workload 至少 8 个有效 run，覆盖两个充分冷却的 session；每个 session 至少 4 个有效 run，拒绝 7+1 等失衡样本。旧 quick/full 只保留历史解码和审计，不再生成新公开分数。
- `session-1` 与 `session-2` 的时间窗不得重叠，前一段结束后至少冷却 10 分钟再开始下一段。
- 每个 run 的 CPU 单核、CPU 多核、内存和磁盘读取 CV 必须不高于 5%，GPU 与持久写入必须不高于 10%；同模式跨 run 继续使用相同的分项门限。GPU 因 macOS 在自动电源模式下会使用动态性能档，256 MiB 持久写入则会放大 APFS 完整同步延迟；报告必须保留真实 CV，不能修改原始值或跳过任一 session 样本。
- 每项参考值取全部有效 run 的中位数；源记录与报告都使用 canonical JSON 和 SHA-256。
- 单次命令最多采集 8 个 Standard run，避免输错次数造成长时间重负载。
- harness 的 app version/build 从校准当时的 `script/release_version.env` 注入，所有 run 必须完全一致；它用于审计，不属于用户机器的评分 key。后续不改跑分协议的补丁版可继续使用同一基线，但发布门会同时核对 workload、结果处理和评分公式源码指纹；任何指纹变化都必须重新校准。
- SHA-256 证明冻结字节未被改动，不证明采集者身份；真实采集仍需按本流程人工核对电源、散热和时间窗。

## 收集

先确认交流电、自动电源模式、电池不少于 50%、thermal nominal，且没有扫描、清理、测速或其他重任务。以下路径仅为受控临时目录，发布完成后删除。

第一段冷却 session：

```bash
MAC_BENCHMARK_CALIBRATION_ACTION=collect \
MAC_BENCHMARK_CALIBRATION_RUN_GUARD="$ONE_TIME_CALIBRATION_TOKEN" \
MAC_BENCHMARK_CALIBRATION_SESSION=session-1 \
MAC_BENCHMARK_CALIBRATION_PROFILES=standard \
MAC_BENCHMARK_CALIBRATION_RUNS_PER_PROFILE=4 \
MAC_BENCHMARK_CALIBRATION_OUTPUT_DIR=/tmp/storage-cleaner-macbench-calibration \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test -c release --scratch-path /tmp/storage-cleaner-macbench-release-build \
  -Xswiftc -disable-batch-mode \
  --filter MacBenchmarkCalibrationWorkflowTests/testExplicitCalibrationWorkflow
```

`ONE_TIME_CALIBRATION_TOKEN` 只在本次正式校准的受控终端中提供；仓库只提交其 SHA-256 摘要，不能提交或复用明文令牌。每次重新做正式校准时都要生成新令牌并同步轮换测试中的摘要。

第一段全部结束后至少等待 10 分钟，并再次确认 thermal nominal。第二段 session 使用同样命令，只把标签改为 `session-2`。如果任何 run 因 thermal 变化、预检、CV 或组件完整性失败，该 run 不会被写成有效记录；补跑直到 Standard 有至少 8 个有效记录。

## 聚合

冻结时间必须显式给出，避免同一批数据重复生成不同报告：

```bash
MAC_BENCHMARK_CALIBRATION_ACTION=aggregate \
MAC_BENCHMARK_CALIBRATION_INPUT_DIR=/tmp/storage-cleaner-macbench-calibration \
MAC_BENCHMARK_CALIBRATION_OUTPUT_DIR="$PWD/docs/benchmarks" \
MAC_BENCHMARK_CALIBRATION_BASELINE_VERSION=m5-pro-2026-07-v6 \
MAC_BENCHMARK_CALIBRATION_FROZEN_AT="$V6_FROZEN_AT" \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test -c release --scratch-path /tmp/storage-cleaner-macbench-release-build \
  -Xswiftc -disable-batch-mode \
  --filter MacBenchmarkCalibrationWorkflowTests/testExplicitCalibrationWorkflow
```

`V6_FROZEN_AT` 必须由操作者显式设置为本次冻结使用的 UTC ISO-8601 时间，不能复用 v4 的时间。聚合会输出 Standard 的 canonical JSON、便于人工复核的 Markdown，以及一个仅供 `apply_patch` 冻结到 `MacBenchmarkProductionBaselineCatalog` 的 Swift 片段。提交前必须核对 JSON 的 SHA-256、参考中位数、session 数和 CV。

## 发布门禁

冻结 Standard 真实报告后运行：

```bash
MAC_BENCHMARK_CALIBRATION_ACTION=validate-production \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift test -c release --scratch-path /tmp/storage-cleaner-macbench-release-build \
  -Xswiftc -disable-batch-mode \
  --filter MacBenchmarkCalibrationWorkflowTests/testExplicitCalibrationWorkflow
```

缺少任一 profile、报告字节不是 canonical JSON、外层或内层 SHA 不符、harness 版本与冻结校准来源不一致、工作负载源码指纹变化、报告证据与中位数/CV 不一致时都会失败。`make_release_dmg.sh` 会强制执行同一门禁，空 catalog 不能打正式包。用户机器运行时直接校验嵌入 Base64 原始字节的 SHA 后解码，不依赖目标系统重新编码 JSON；任何验证失败都会安全降级为空 catalog，只展示原始指标，不崩溃也不生成分数。
