# M 系列性能测试 v11：协议、评分与界面数据契约

版本：B1 review r2，2026-10-10；按主会话本轮评审修订。批次 `r2-bench-v11`，基线 `3e5eead099fb60487a47dc54647b6524d1979bc2`。依据：`collab/DECISIONS.md` D72；执行分工见 `BENCHMARK-REDESIGN-PLAN.md`。本文件是 B2–B4 的实现输入，不代表内核、参考集、界面或服务端已经实现。B1 只交付文档和数据，现有 Swift 仍使用 v10。

## 1. 版本与兼容边界

| 字段 | v11 约定 | 说明 |
|---|---|---|
| schema | `mseries-result-v11` | 新 envelope；内部保留原始 v10 Core payload |
| plan | `mseries-core-v11` | 完整标准流程；压力模式另用 `mseries-pressure-v11` |
| coreWorkload | `mseries-fixed-kernels-v1` | 与 v10 相同 |
| coreFixture | `procedural-mit-seed-619a27de-v1` | 与 v10 相同 |
| coreImplementation | `native-c-metal-posix-v1` | 原算法、精度、校验和不变 |
| coreStatistics | `median-mad-all-samples-v1` | 原始中位数/MAD/A-B-C 不变 |
| extendedStatistics | `mseries-window-cv-v11.1` | 新窗口统计和 CV；不篡改历史统计 |
| extensions | `mseries-efficiency-sustained-v11.1` | 时间窗、负载、对齐方式独立版本 |
| scoring | `mseries-d72-geomean-v11.2` | 与 v10 草案、v6 容量分隔离 |
| reference family | `reference-v11` | 实际激活版本带机型、日期、revision 与 SHA-256 |
| catalog schema | `apple-silicon-catalog-v2` | 数据在 `Resources/Benchmark/AppleSiliconCatalog.json` |

Core 契约字符串必须逐字保持：

```text
CPU:integer262144u64;float128x128f32;LZFSE1MiB;gaussian512x512u8;memory:32MiB-copy-triad,16MiB-chase;GPU:1024x1024-rgba8,262144x256-fp32-fp16;storage:64MiB-seq,1024x4KiB-QD1;warmup1;samples3;disk:F_NOCACHE+fsync-write;seed619a27de
```

`coreContractHash = SHA256(UTF8(上面字符串，不含换行))`，与 `MSeriesProtocol.contractHash` 相同。本轮计算值：`c8b75dff7897d6ff8055d51fdf37afce20d1b656037e042a98c68e03e9083318`。扩展契约另有 `extensionContractHash`，冻结负载配置、时间轴、窗口划分、计时域、输出校验、功率来源与对齐版本。`scoringContractHash` 覆盖第 6 节所有权重、方向、门限。不能以新 plan 名替换旧 Core 哈希，不能把新 Metal 3D 场景的 Mtri/s 当作 v10 离屏绘图 fixed-fixtures/s。

## 2. Core 18 项：夹具、采样、单位与预算

所有 Core 项预热 1 次、正式样本 3 次；预热不参与统计，保留全部正式样本，不选最好值、不丢慢值。表中的时长是**现有自适应批次目标**，不是固定倒计时；不允许为了固定时长更改 v10 repetitions、夹具或算法。CPU 工作空间按 worker 分离，准备和校验在计时外；GB/s 为十进制，空间预算 MiB 为二进制。

| ID / 中文名 | 固定夹具与算法 | 正式单位 | 计时与典型样本目标 | CV 上限 |
|---|---|---|---|---|
| `cpu.single.integer` / CPU 单线程 · 整数 | 262144 个 UInt64，原 C 整数固定单元 | fixed-fixtures/s | 1 worker；pilot 后每样本约 0.15 s，repetitions 1…4096 | 5% |
| `cpu.single.floating` / CPU 单线程 · 浮点 | 128×128 Float32，原浮点固定单元 | fixed-fixtures/s | 同上 | 5% |
| `cpu.single.compression` / CPU 单线程 · 压缩 | 1 MiB LZFSE，原数据种子 | fixed-fixtures/s | 同上 | 5% |
| `cpu.single.image` / CPU 单线程 · 图像处理 | 512×512 UInt8 高斯处理 | fixed-fixtures/s | 同上 | 5% |
| `cpu.multi.integer` / CPU 多线程 · 整数 | 与单线程相同，每 worker 独立空间 | fixed-fixtures/s | workers＝运行时逻辑核数；约 0.15 s，1…4096 | 5% |
| `cpu.multi.floating` / CPU 多线程 · 浮点 | 同单线程 | fixed-fixtures/s | 同上 | 5% |
| `cpu.multi.compression` / CPU 多线程 · 压缩 | 同单线程 | fixed-fixtures/s | 同上 | 5% |
| `cpu.multi.image` / CPU 多线程 · 图像处理 | 同单线程 | fixed-fixtures/s | 同上 | 5% |
| `gpu.graphics.offscreen` / GPU · 离屏图形 | 1024×1024 RGBA8，固定全屏三角形 | fixed-fixtures/s | GPU 时间；pilot 后每样本约 0.04 s，1…256 | 10% |
| `gpu.compute.fp32` / GPU · 单精度计算 | 262144 元素×256 次 FMA，Float32 | fixed-fixtures/s | 同上，关闭 fast math | 10% |
| `gpu.compute.fp16` / GPU · 半精度计算 | 同规模 Float16，逐值校验 | fixed-fixtures/s | 同上 | 10% |
| `memory.copy` / 内存 · 复制 | 32 MiB 固定复制 | GB/s | 1 worker；约 0.15 s，1…4096 | 5% |
| `memory.triad` / 内存 · 三数组运算 | 32 MiB 原 Triad | GB/s | 同上 | 5% |
| `memory.pointerChase` / 内存 · 指针追逐 | 16 MiB 固定链 | ns/access | 同上；越低越好 | 5% |
| `storage.seqRead` / 存储 · 顺序读取 | 私有 64 MiB 文件、1 MiB 块 | GB/s | 每样本完整一轮；F_NOCACHE | 5% |
| `storage.seqWrite` / 存储 · 顺序写入 | 同一文件 | GB/s | 1 次预热＋3 轮；计入每轮 fsync | 10% |
| `storage.randomReadQD1` / 存储 · 4K 随机读取 | 1024×4096 B，固定偏移，QD1 | IOPS | 完整一轮；逐 IO 原始时延单独保存 | 5% |
| `storage.randomWriteQD1` / 存储 · 4K 随机写入 | 同偏移/QD1 | IOPS | 每轮末 fsync；时延与重复吞吐统计分开 | 10% |

Core 目标 ≤180 s。单项软超时 30 s；存储共享原来的 120 s 安全截止；整个 Core 硬停止派发上限 180 s。超时只阻止后续派发并发起取消，必须等待已提交 GPU command、POSIX IO 和 worker 真正结束后才释放租约，不以到时返回表示内核已停止。实现若无法在此范围保留固定算法，记录失败原始证据，不能缩夹具。

全程写入硬预算 ≤512 MiB（负载与结果元数据合计；UI 延续“≤512 MB”，详情明确实际 536870912 B）。v10 预计固定写入：初始化 64 MiB＋顺序写入 4×64 MiB＋随机写入 4×4 MiB＝336 MiB，Core原有512 MiB独立守卫保持不变，外层总预算另外包含元数据；固定Core336 MiB仍满足两层预算。Core写入全部通过同一 `MSeriesWriteBudget` 预留和实际记账；不包括读回校验。应用只能操作自身具身份回执的夹具，不能读用户素材、自动删除未知路径或放宽路径安全检查。

## 3. 新测量与标准时间轴

默认顺序：预检 → Core 18 → CPU 三档能效 → GPU 30 s 峰值 → CPU 90 s 持续 → GPU 90 s 持续 → 保存。能效和持续段都串行，占用同一个 `HeavyWorkCoordinator` 租约；不并跑 CPU/GPU，不改变电源/风扇设置，不结束其他进程。开始扩展前记录环境边界，Core 环境在此封存。

| ID | 固定负载、单位 | 预热 / 有效测量 / 样本 | 统计和 CV 门禁 | 超时 / 负载写入 |
|---|---|---|---|---|
| `power.cpu.single` | v10 整数单元，1 worker；fixed-fixtures/s、CPU W、fixed-fixtures/J、簇 GHz | 1 个完整单元预热（≤2 s）；10 s；3 个等长吞吐窗口 | 吞吐和对齐后的效率分别取中位数/MAD/CV；5% | 预热＋测量总 ≤15 s；0 B |
| `power.cpu.performanceCores` | 同负载；worker 数＝最高性能层物理核数，旧 M1–M4 为 P 核数，M5 Pro/Max 为超级核心数；单位同上 | 同上；10 s | 同上；5%；记录 resolvedWorkers 与核心类型 | ≤15 s；0 B |
| `power.cpu.allCores` | 同负载；worker 数＝全部逻辑核数 | 同上；10 s | 同上；5%；全核效率作为能效分唯一输入 | ≤15 s；0 B |
| `power.gpu.peak` | `Metal3DBenchmarkKernel` 的 standard 1920×1080、262144 立方体实例、每实例 12 三角形；Mtri/s、GPU W、Mtri/J、GPU GHz | 1 个固定帧批预热（≤2 s）；30 s；3×10 s 窗口 | 原始 GPU 吞吐、墙钟吞吐分别保存；中位数/MAD/CV；10% | ≤35 s；0 B |
| `sustained.cpu.allCores` | v10 整数单元，全逻辑核；fixed-fixtures/s、°C、CPU W | 1 完整批预热（≤2 s）；90 s；18×5 s 窗口 | 全部 18 点；首 10 s 中位数、末 30 s 中位数和比；末 6 点 CV≤5% 才可生成对应派生分 | ≤95 s；0 B |
| `sustained.gpu` | 与 `power.gpu.peak` 完全相同的 3D 场景和计时方式；Mtri/s、°C、GPU W | 同上；90 s；18×5 s | 同上，末 6 点 CV≤10%；末 30 s 吞吐进入 GPU 持续分 | ≤95 s；0 B |

窗口半开区间 `[t0,t1)`；已跨窗的工作单元按实际时间重叠比例分配 workUnits，不能把一个完整批次都算到结束所在窗口。必须保留每批开始/结束时间与工作量以复算。repetitions/批次大小在 pilot 后锁定，不自适应追逐高分。循环时校验仍在计时外，但实际墙钟间隙保留。窗口迟到/不完整、后台挂起、测量时钟不单调均标记，不能缩短有效时长后宣称完成。

GPU 吞吐可同时记录 `gpuTimedThroughput`（实际 GPU 时间）与 `wallThroughput`（固定窗口墙钟）。第 6 节 GPU 峰值/持续评分均使用可靠 GPU 时间的吞吐，明确这是 GPU 场景吞吐；GPU 每瓦性能必须使用**同一个功率测量区间中的墙钟工作量**，不能把 GPU 活跃时间吞吐除以墙钟平均功率。不允许以 `usedWallClockFallback` 的值替代可比 GPU 分。

持续降频比（更准确的 UI 名“持续保持率”）：

```text
retention = median(末 30 s 的 6 个吞吐窗口) / median(前 10 s 的 2 个吞吐窗口)
```

默认尾窗 `[60,90)`，头窗 `[0,10)`；同一个负载和计时域。保留 >1 的比值，不截为 100%；它是吞吐保持率，不是频率读数，也不证明硬件一定热降频。功率或温度缺失时仍可画吞吐、算保持率；缺失处显示空白/原因，不能填 0、连过缺口或用整机电池功耗替代 CPU/GPU 功率。持续曲线的整体 CV 可作诊断，不能把真实衰减当作离群值删掉；仅末 30 s 的 CV 对持续评分设门禁。

标准流程正常目标约 7 分钟，预算上限 480 s（含预检、准备、保存）；2×90 s＝3 分钟只是持续段。超时进入停止/排空状态，GPU/系统调用排空耗时单列，不能承诺驱动卡住也能硬停在 480 s。可选加速套件、线程曲线、压力模式不在此上限内，起始页单独显示预计时长。

### 3.1 可选 10 分钟压力模式

入口必须显式选择。`mode=pressure10m`，CPU 全核 300 s → GPU 300 s，固定有效负载共 600 s，准备/预热/排空另计；各 60×5 s 窗口。分别以各段首 10 s 与末 30 s 算保持率。沿用同一负载、热保护、2 s 功率节流和写入预算；总停止派发 deadline 660 s。只出压力曲线/原始吞吐，不更新标准芯片分、本机最佳或标准参考集；90 s 与 300 s 不能混为同一种持续分。不要把 10 分钟 CPU 再加 10 分钟 GPU 称为 10 分钟模式。

### 3.2 旧 CPU 扩展

`cpu.threadCurve.<N>` 与 `cpu.sustained.short.<K>` 的算法、1/2/4…全逻辑核序列、最多 12 批约 6 s 行为仍可读取和可选运行，raw-only。标准 v11 的 90 s 项不以短观察替代。Ultra 不按“2 倍 Max”推定实测；在可选线程曲线中保留全核点和运行时拓扑。

## 4. 助手遥测与时间对齐

当前 `HelperPowerMetricsMonitor` 仅对可见消费者采样，最短请求间隔 2 s、最多一条在途；助手命令固定为 `--samplers cpu_power,gpu_power,ane_power -n 1 -i 1000 -f plist`。**每 2 s 是请求起点节流，不是每个 sample 覆盖 2 s**。当前每份 `PowermetricsSample.durationSeconds` 约 1 s，且没有测量区间时间戳；应用的 `sampledAt` 是完成回调时的墙钟，不能假装为采样开始或结束。

B2 必须沿用共享 demand stream，按单调时钟定期请求，绝不新开第二条 powermetrics 进程。现有“完成后 sleep 2 s”循环实际上约 3 s，需按上次 requestStart 对齐下一次 due，同时守住 ≥2 s、不重叠。可见运行页和小窗共用同一个消费者集合；不可见时依既有策略停止遥测并将功率缺失标注，性能循环可继续。不自动安装/更新助手或弹权限；当前用户主动操作仍按产品既有流程。

新遥测 envelope 至少包含：

```text
sampleID, helperBootID(进程级随机值，不是设备唯一标识), clockDomain
measurementStartMonotonicNs, measurementEndMonotonicNs, durationSeconds
requestStartMonotonicNs, responseReceivedMonotonicNs
cpuMilliwatts?, gpuMilliwatts?, aneMilliwatts?, clusters[], gpuMegahertz?
timestampQuality: helperMeasured | requestBracketOnly | legacyUntimed
```

隐私边界（helper-interval fix1）：`helperBootID` 仅留在本次运行内存，用于对齐与去重；封存和历史保存前剥离，明文 JSON 与压缩 payload 均不得包含它或其可逆/哈希派生标识。历史仅保留从 1 开始的本次结果内 `helperProcessOrdinal`，表示样本是否来自同一助手进程；不同结果的编号不具有身份比较意义。新 `rawPayloadSHA256` 对剥离后的展开规范 JSON 计算（沿用原来的派生缓存/写入记账排除规则），不包含助手进程 UUID。旧历史仍按原始摘要解码和验证；读取不改文件，下一次显式历史写入时，对重写的旧记录先剥离再封存。实现、兼容测试及限制见 `collab/handoffs/r2-bench-v11-helper-interval.md` 的 fix1 交接。

优先助手输出实际测量区间起止（ContinuousClock/相同系统连续单调域），与 workload 批时间同域。仅 request/response 包围区间不是实际采样区间；`requestBracketOnly` 只能诊断，不能进入能效评分。没有可验证时间戳时能效 unavailable，不能在未核实的排队延迟上推算区间。墙钟 UTC 仅用于历史排序与审计；系统时钟变化不影响吞吐计时。

mW→W 除以 1000。按测量区间与负载/窗口的交集加权：`E = Σ(Pwatts × overlapSeconds)`，`Wmean = E / ΣoverlapSeconds`；同一区间 `matchedWork = ΣworkUnits × overlapFraction`，`efficiency = matchedWork / E`。不能把未测到的一秒补成上一点的功率。记录 observedSeconds、expectedSampleCount、validSampleCount、alignmentQuality、missingReasons。CPU 10 s 三档各至少 4/5 个有效独立样本（80% 预期请求覆盖），GPU 30 s 至少 12/15；3 个统计子窗各至少 1 个有效测量交集，功率 >0、时间有效、输出校验通过；覆盖不足保留吞吐、能效无分。覆盖百分比明确是有效**样本数**覆盖，另显示实际时间覆盖率，不能声称实际连续监测 80%。

温度来自现有可靠芯片传感器；缺传感器不造温度。`thermalState` 仍是中止依据。频率优先同 interval 的助手簇频率，DVFS 服务作为带单独时间戳/来源的诊断；不能把不同区间的频率混为同一点。M5 的 PCPU/MCPU/ECPU 或 Ultra DIE 前缀保留原簇身份与映射，不把 MCPU 误当传统 E 核。IOReport Energy Model 更新中、冻结计数器、过期点均不得作为能效输入；SMC 整机功率也不得替代 CPU package 功率。

## 5. 独立加速单元（不计分）与保护

### 5.1 测量项

| ID | 夹具 / 单位 | 预热 / 样本 / 时长预算 | 可用性与门禁 |
|---|---|---|---|
| `media.h264.encode`、`media.h264.decode` | 沿用标准 H.264 1920×1080、60 帧、60 fps、12 Mbps，确定性图像；MPix/s | 驱动预热 1 次，每方向 3 样本；每对完整 kernel ≤15 s，整个配对采集 ≤60 s | RequireHardware＋UsingHardware 回读；编码 CV10%、解码 CV5% |
| `media.hevc.encode`、`media.hevc.decode` | 同分辨率/帧数/像素夹具，HEVC Main 8-bit，12 Mbps；MPix/s | 预热 1；各 3；每对 ≤15 s，采集 ≤60 s | 同上，不以 H.264 结果替代；CV10%/5% |
| `media.prores.encode`、`media.prores.decode` | 固定 ProRes 422 profile、1920×1080、60 帧；MPix/s | 预热 1；各 3；每对 ≤20 s，采集 ≤80 s | 编解码分别查能力与真实硬件路径；CV10%/5% |
| `media.av1.decode` | 打包固定 AV1 Main 8-bit 1080p、60 帧位流，明确 encoder/version/license 与 SHA-256；MPix/s | 预热 1；3 样本；单样本 ≤15 s，总 ≤60 s | 仅解码；不能用本机软件编码的时间作硬件解码测量；CV5% |
| `gpu.hardwareRayTracing.build` | 现有 131072 三角形固定场景；Mtri/s | 预热 1；3 样本；每次 kernel ≤20 s，采集 ≤80 s | supportsRaytracing＋明确硬件 family/capability；CV10% |
| `gpu.hardwareRayTracing.traversal` | 现有 262144 光线、64 passes；Mray/s | 与 build 配对，共享 1 次预热；3 样本 | GPU 时间可靠、命中与场景校验；CV10% |
| `gpu.tensor.fp16` | 现有 2048³ MPS 矩阵、128 iterations、4 warmup iterations；TFLOP/s | 每样本已有固定 warmup，3 样本；单次 ≤20 s，总 ≤80 s | 纯 MPS Metal，不以 Core ML cpuAndGPU 冒充；CV5% |
| `ai.smallModel.cpu`、`ai.smallModel.aneCandidate` | 固定小模型推理；inferences/s、ms/inference | 编译/加载在计时外，1 次预热；各 3×5 s；每方向 ≤30 s | 可行性闸门先行，CV5%，同输入/输出校验 |
| `ai.smallModel.accelerationRatio` | CPU 中位时延 / 候选路径中位时延；× | 派生值，不独立采样 | 只在两条路径有效且有分配证据时展示 ANE 标签 |

新媒体方向共享最大内存预算：输入 ≤512 MiB、编码缓存 ≤128 MiB且不超 live sharedBudget；顺序采样并释放回调/缓冲，不存用户目录，不计任何额外负载磁盘写入（0 B）。ProRes 码率不假定 12 Mbps；固定 profile、像素格式、位流和 decoded semantic checksum 由 B2 可行性确认后冻结 `mediaFixtureVersion`。AV1 位流尚未交付，必须先验证来源/许可/字节哈希；没有冻结夹具时记 `notImplemented`。新方向不继承现有实验套件的 8% 门限；v11 独立规范使用上表 5%/10%，旧 `mac-accelerator-suite-v1` 继续保持自己的旧门限/记录。

规格表的 null 代表未核实，不能直接变为 `unsupported`。双重门控：规格表明确支持＋运行时确认才宣称对应专用硬件；规格未知但运行时支持可测 raw-only，标“规格待核实”；目录与运行时冲突时标 `capabilityConflict`。明确无硬件显示“无此单元”，软件/API路径不可用显示“当前系统不可用”，实现没交付显示“尚未实现”；资源不足/临时分配失败不是“无此单元”。现有光追仅 apple9/apple10 枚举不能据此把 M5/M6 判无硬件，B2 需按官方 Metal capabilities 核对新 family；目录代号本身不替代查询。

### 5.2 ANE 先验可行性闸门

B1 不承诺 ANE 已可测，不交付虚构模型或加速比。B2 先验证：可许可/程序生成的固定模型 ≤2 MiB，固定输入 shape、精度、batch=1、权重种子、计算图/输出误差界限；在 scratch 编译并记 source/compiled SHA-256，不临时联网下载。`.cpuOnly` 与 `.cpuAndNeuralEngine` 分别运行同模型。后者允许 CPU 参与，选择此配置或时延更快均**不能证明实际使用 ANE**。

需通过可用系统的 `MLComputePlan` 或等价官方分配证据核对关键算子实际/计划设备，并记录 API/OS 与证据限制；只有计划信息时明确“计划分配”，不能称执行轨迹。若不能证明 ANE 路径，显示“CPU/神经网络候选路径对比（未验证分配）”，不显示 ANE 实测加速比，记录 `notImplemented`/`aneAllocationUnverified` 留给后续阶段。NE 核数/TOPS 不用于估算跑分。

### 5.3 取消、超时、热保护和保存

所有项目继承此规则：预检 `.serious/.critical` 拒绝；运行每批/每 ≤1 s 环境检查发现它们即停派发、取消并排空，保留已完成点并标 `thermal-protection`。`.fair` 可继续但对应时间段 `restricted`。不以温度固定 °C 阈值猜安全边界；热状态 unknown 不能进入可比校准。

取消请求 UI 目标 ≤2 s 响应，状态转 `cancelling`；核对未提交下一批，等待 GPU/IO/VT 回调/模型 worker 排空再终态、回收夹具和释放 lease。现有不可抢占命令可能超过 2 s，B2 必须用有界批次验证响应/排空耗时；不能丢后台任务换取“取消成功”。超时采用同样路径，不和成功混淆。原始部分结果保存但无缺项综合分；已完成且独立的组件分可显示“部分结果”。保存原子 JSON 阶段短暂不可取消，UI 说明“正在保存”；失败保留可审计错误与夹具回执，不自动清除历史。

全程实际写入累计 ≤512 MiB；外层预算先预留结果 envelope＋原子替换临时副本合计 ≤2 MiB，负载剩余预算 ≤510 MiB，单份最终结果 ≤1 MiB，按 byte count 验证，超限记失败，不能静默截断遥测。标准/压力只保留 ≤1024 条遥测，最多 120 个持续窗口，媒体压缩位流/像素不嵌入历史。需要导出大证据时走显式导出，不增加默认写入预算。压力和扩展均不反复写盘。软件编解码、shader/model 编译、准备耗时单列，不能算进硬件吞吐。

## 6. 统计与评分（D72）

### 6.1 基础统计与门禁

`median` 使用现有线性百分位实现，`MAD = median(abs(x-median))`，相对 MAD `1.4826×MAD/median`。稳定度 A≤2%、B≤5%、C>5%，沿用 `BenchmarkStatistics`，不是置信概率。CV 单独采用 v6 的样本标准差：`sqrt(Σ(x-mean)²/(n-1))/mean`，要求 n≥3；CV 不扣分。三点例 `[100,100,130]` 的 MAD 可以为 0 而 CV超限，因此 A 不保证可比。

Core 表和第 3/5 节所列 5%/10% 为含端点门限，无重新试到门限之下。失败、NaN、Infinity、≤0、无校验和、样本数量/计时损坏、资源不足不能评分。重复吞吐 CV 不从单个 IO latency 数组计算。持续时间窗口是同一运行的观察值，必须标明不是三次独立运行；参考跨 run 的稳定性另校验。CV 不稳定的分项只保留 raw 值；依赖它的父分为 nil，不重分配权重。

### 6.2 分项与权重

令有效本机中位数为 x，参考为 b（同负载/单位/计时域/统计契约）：

```text
r(id) = x/b                            # 越高越好
r(memory.pointerChase) = b/x           # 唯一 Core 反向项
S(id) = 1000 × r(id)
GM(r,w) = exp(Σ(w_i × ln(r_i))), Σw_i=1
```

每个参与计分的基础比值必须有限、正、在闭区间 `0.02…5`，越界直接拒绝该项与依赖分，不截断、不放大门限以容纳 Ultra。若未来芯片合法地超过此区间，也只能保留 raw-only 并升级评分协议；这是目前门限的实际适用限制。

| 分项 | 完整输入与几何权重 | 输出 |
|---|---|---|
| CPU 单线程 | 四个 `cpu.single.*`，各 1/4 | `1000×Rsingle` |
| CPU 多线程 | 四个 `cpu.multi.*`，各 1/4 | `1000×Rmulti` |
| CPU 分 | single 0.30、multi 0.70 | `1000×Rcpu` |
| GPU 峰值分 | 三个 `gpu.*` Core 比值＋`power.gpu.peak` GPU 吞吐比值，各 1/4 | `1000×RgpuPeak` |
| GPU 持续分 | `sustained.gpu` 末 30 s 的 GPU 吞吐中位数 / 参考同窗口中位数，权重 1 | `1000×RgpuSustained` |
| GPU 分 | peak 0.50、sustained 0.50 | `1000×Rgpu` |
| 芯片性能分 | CPU 0.70、GPU 0.30 | `1000×Rchip` |
| 内存分 | copy、triad、反向 pointerChase，各 1/3 | `1000×Rmemory` |
| 存储分 | 四项 storage，各 1/4 | `1000×Rstorage` |
| 整机分 | chip 0.55、memory 0.20、storage 0.25 | `1000×Rsystem` |
| 能效分 | CPU 全核点 matched fixed-fixtures/J / 参考同负载全核点效率，权重 1 | `1000×Refficiency` |

D72 锁定 CPU/GPU/芯片/整机大组权重；本 B1 将峰值组细化成“3 个原 Core GPU 项＋30 s 3D 峰值各等权”，让 18 项都参与且新峰值不闲置。主会话已在本轮评审确认这项**组内细化**，它现在是v11.2的冻结评分规则；后续变更必须升级scoring版本/哈希。GPU 持续直接比较绝对吞吐，不拿保持率代替持续性能分，也不把 90 s 原始吞吐和不同场景的 v10 值直接相除。CPU 持续、GPU 每瓦性能、媒体/光追/MPS/ANE、容量、散热形式均不加入综合分。

所有几何运算先用无量纲 ratio，再统一乘 1000，避免重复乘 1000。每个父组缺一项即 nil；CPU 单/多核、内存等有效独立组可以继续显示。能效缺功率只影响能效，不影响可靠吞吐分。能效不使用 GPU/ANE 功率求和、整机耗电或空闲扣除；说明“CPU 报告功率口径的全核每瓦性能”，不是插座能耗或续航分。示例：所有 ratio＝1 时每分＝1000；CPU single=2、multi=1 则 CPU＝`1000×2^0.3`；pointerChase 本机为参考一半则该分＝2000。


已确认评分契约 `scoringContractHash`：`fc154594b7f4f2877b6ace113b544f05db7bfbbe8176966c0fb2bf0a96d1f16e`。哈希输入是以下完整代码块的ASCII原始字节（排序键、紧凑JSON、无BOM、**不含末尾换行**）；`1/3`权重以块中固定的数值表示。实现/参考集必须校验这组精确字节，不从不同语言重新格式化后猜哈希。版本从草案v11.1升为已确认v11.2，Core契约与18项算法不变。

<!-- scoring-contract:start -->
```json
{"acceleratorContribution":0,"aggregation":"weighted-geometric-mean-of-ratios","capacityContribution":0,"comparability":{"batteryFairLowPowerHighBackgroundOrUnknown":"restricted","debugRosettaInvalidOrUnstable":"incomparable","precedence":["incomparable","restricted","comparable"]},"coreCompatibility":"unchanged-v10-fixtures-and-algorithms","cv":{"definition":"sample-standard-deviation-divided-by-mean","endpointsInclusive":true,"minimumSamples":3,"relaxed":0.1,"relaxedDomains":["gpu-core","gpu-peak","gpu-sustained-tail","storage-write","ray-tracing","media-encode"],"strict":0.05,"strictDomains":["cpu","memory","storage-read","cpu-efficiency","cpu-sustained-tail","tensor","ai","media-decode"]},"groups":{"chip":{"cpu":0.7,"gpu":0.3},"cpu":{"cpuMulti":0.7,"cpuSingle":0.3},"cpuMulti":{"cpu.multi.compression":0.25,"cpu.multi.floating":0.25,"cpu.multi.image":0.25,"cpu.multi.integer":0.25},"cpuSingle":{"cpu.single.compression":0.25,"cpu.single.floating":0.25,"cpu.single.image":0.25,"cpu.single.integer":0.25},"efficiency":{"power.cpu.allCores.matchedFixturesPerJoule":1.0},"gpu":{"gpuPeak":0.5,"gpuSustained":0.5},"gpuPeak":{"gpu.compute.fp16":0.25,"gpu.compute.fp32":0.25,"gpu.graphics.offscreen":0.25,"power.gpu.peak":0.25},"gpuSustained":{"sustained.gpu.tail30.gpuTimedThroughput":1.0},"memory":{"memory.copy":0.3333333333333333,"memory.pointerChase":0.3333333333333333,"memory.triad":0.3333333333333333},"storage":{"storage.randomReadQD1":0.25,"storage.randomWriteQD1":0.25,"storage.seqRead":0.25,"storage.seqWrite":0.25},"system":{"chip":0.55,"memory":0.2,"storage":0.25}},"missingInput":"dependent-parent-null-no-reweight","provisionalReference":"local-M5-Pro-controlled-v11-only-no-estimated-medians","ratios":{"acceptedMaximum":5,"acceptedMinimum":0.02,"endpointsInclusive":true,"higherIsBetter":"measuredMedian/referenceMedian","inverseCoreIDs":["memory.pointerChase"],"lowerIsBetter":"referenceMedian/measuredMedian","outOfRange":"reject-no-clamp"},"referenceScore":1000,"timing":{"efficiency":"work-and-joules-in-matching-measured-wall-intervals","gpuScores":"reliable-gpu-timeline-only","pressure10m":"raw-only","retention":"median-last30/median-first10","sustainedScoreWindow":"last-30-of-90-seconds"},"version":"mseries-d72-geomean-v11.2"}
```
<!-- scoring-contract:end -->

### 6.3 可比性标签

每个 metric/window 保存环境，再按**实际评分依赖的时间段**聚合；不让扩展失败追溯污染已封存的 Core 环境。优先级 `incomparable > restricted > comparable`，保留所有原因码。

| 标签 | 触发 | 展示/纳入 |
|---|---|---|
| `comparable` / 可比 | Release、原生 arm64、非 Rosetta、完整有效样本和相同契约；全程交流电、thermal nominal、非省电、无高后台负载；CV/比值/参考哈希通过 | 可显示分；可参与本机同口径最佳；未部署服务端仍不可上传/排名 |
| `restricted` / 受限 | 电池供电、电源变化、低功耗/非自动电源模式、thermal fair、后台负载高或环境关键项 unknown | 结构有效可算但灰显附原因；不进入最佳/校准/社区；不能写为“可比” |
| `incomparable` / 不可比 | Debug、Rosetta/Intel、未知/不符 workload/hash、CV 超限、比值越界、核心缺项、超时/取消/serious/critical、样本结构无效 | 对受影响分为 nil，raw/已完成独立组保留；Intel/Rosetta 在起始页阻止标准新运行 |

后台负载预检：5 s CPU 系统聚合采样，扣除本应用已知线程负载后中位数 >10% 整机 CPU 或 GPU >10% 为 high；不可获取则 unknown，校准必须人工核对。运行时负载不能把自身跑分误判为后台。环境记录含取样时段、检测版本、阈值与功率/温度状态；阈值是 B1 可复现产品门禁，不是 Apple 官方限制。电池 <20% 阻止开始高负载，unknown 至少受限；校准按原流程要求≥50%。

“待校准/暂定”是参考状态，和上述标签正交；可比性不是社区名次。v10 ↔ v11 只在相同 `coreContractHash`、单位、timing、统计、环境与 CV 验证通过的**Core 单项**比较原始值；v10 没有新峰值/持续/功率，不能补算完整 v11 GPU/芯片/整机/能效分。v6/v9 无转换关系，只读各自历史。

## 7. 参考集、暂定基准和重算

正式目标 Apple M1（8 CPU/8 GPU）＝1000。**M1参考机具体机型、内存、SSD与散热配置由B5再确定并写入参考身份**；本B1不锁定2020 Mac mini/16 GB/512 GB，也不以取得该机阻塞B2–B4。B5待办是选择可实际取得的M1配置、受控采集并冻结，避免混用不同散热或SSD的系统参考；容量不计分仍影响实测吞吐。无真实M1数据不生成M1 medians。

**B5之前采用本机M5 Pro作为暂定基准策略**；正式M1具体配置留在B5处理。用于出分的数值仍必须来自真实受控v11参考集；没有有效冻结集时显示“待校准”，本机识别成功不等于校准完成。真实受控本机 M5 Pro 作为 `referenceStatus=provisional`、`provisionalAgainst=Apple M5 Pro`、该机各分=1000；每个分数前均显示“暂定”，口径写“相对本机 M5 Pro 参考机＝1000”。它不是已换算到 M1 的绝对分。没有冻结有效参考集时 `referenceStatus=unavailable`，显示“待校准”，原始值继续显示。B1 没有参考数值，不能以目录核数、带宽、TOPS 或第三方跑分估算基准。

参考数据结构（此例只示结构，不是可激活数据）：

```json
{
  "schema": "reference-v11",
  "version": "m5-pro-provisional-YYYYMMDD-r1",
  "status": "provisional",
  "scoringVersion": "mseries-d72-geomean-v11.2",
  "coreContractHash": "<sha256>",
  "extensionContractHash": "<sha256>",
  "scoringContractHash": "fc154594b7f4f2877b6ace113b544f05db7bfbbe8176966c0fb2bf0a96d1f16e",
  "referenceHardware": {"chipID":"m5-pro","modelIdentifier":"Mac17,9","cpuTotal":18,"gpuCores":20,"memoryBytes":51539607552,"storageCapacityBytes":null},
  "timingPolicy": "gpu-timeline-and-aligned-wall-v11.1",
  "powerPolicy": "helper-powermetrics-cpu-package-v11.1",
  "independentRunIDs": [],
  "sessions": [],
  "medians": {},
  "crossRunCV": {},
  "sourceArtifacts": [{"relativePath":"<aggregate-only>","sha256":"<sha256>"}],
  "frozenAt": "<explicit UTC ISO-8601>"
}
```

`medians` 必须精确包含 18 Core、GPU 30 s 峰值、GPU 90 s 末 30 s 吞吐、CPU 全核效率所有计分输入；另存 CPU 三点、GPU 效率、CPU/GPU 保持率和 5 s 参考曲线供展示。键携带单位/timing/样本数/统计版本，不能把一个普通 Double 无条件当作匹配项。非计分遥测缺失可标 unknown；计分输入缺一项参考不可激活为完整集，可显示 raw-only。

参考采集遵守 `docs/benchmarks/README.md`：Release 原生、不重叠的独立 run，最低 3 次为草案数学下限；**发布/暂定激活采用 ≥8 次有效 run，两个 session 各≥4，间隔冷却至少10分钟**，电源/模式/thermal/版本一致，逐 run 与跨 run 继续过对应 5%/10% 门限。取全部有效 run 的中位数，失败 run 另保留而非篡改，不从一个 run 切 8 个片段冒充独立。采集窗口与重复次数由主会话安排；本轮不运行高负载采集。

冻结字节使用固定 canonical UTF-8 JSON（排序键、禁止 NaN、明确换行/数值编码规范），SHA-256 写在外部 manifest；hash 不包含自己的 digest，不循环自指。运行时对**原始资源字节**校验再 decode，不依赖 Swift 重编码得到相同小数。版本/hash、来源文件hash、契约hash之一不符即空参考安全降级。SHA 只证明字节一致，不证明真实硬件或采集人身份。

换基准先校验新集，再由原始值重算、原子替换派生缓存；cache key＝`sessionID + rawPayloadSHA256 + scoringVersion + referenceVersion + referenceSHA256`。幂等；保留原始时间、原始参考与之前展示的分数快照用于审计，不能改历史原始值。新 M1 集到位后前缀去掉“暂定”，口径变“相对 Apple M1＝1000”；无完整新增字段的旧记录分为 nil，原因 `missingV11Inputs`，不拿当前硬件功率倒填旧结果。同一界面不得并排比较不同参考的 cached score；先统一重算或标不可比。重算失败回滚派生缓存，不删除历史。

## 8. 结果模型与兼容解码

复用 `BenchmarkV7Result` 历史容器、app scoped coordinator 和现有 history repository；不新造并行数据库/定时器。建议 v11 envelope 搭配保留的 Core payload，以下是字段契约而非本轮已新增的 Swift 成员。

| 字段组 | 新字段 | 缺失/旧版本行为 |
|---|---|---|
| 身份与版本 | schema, plan, mode, sessionID, coreContractHash, extensionContractHash, scoringContractHash, catalogVersion/catalogSHA256, rawPayloadSHA256 | 按明确 schema switch；未知 schema 原字节只读留存，不猜测为 v11 |
| 硬件 | chipID?, identificationStatus, brandString?, modelIdentifier?, perfLevels[{index,name?,physicalCores?,logicalCores?}], metalDeviceName?, profilerGPUCores?, physicalMemoryBytes, cooling?, matchedCPUOption?, matchedSKU?, identificationEvidence | 旧硬件 logicalCores/coreLevels 保留；不存在 physical/name 时 null，不复制 logical 充当 physical |
| 测量 | core metrics(旧格式), efficiencyPoints[], sustainedCPU?, sustainedGPU?, accelerators[], legacyExtensions[] | v10 三样本校验不套到 18 点曲线；新数组缺失解为[]/nil且标 legacy |
| 曲线窗口 | id, start/endMonotonicNs, elapsedSeconds, workUnits, wallThroughput?, gpuTimedThroughput?, temperatureC?, powerW?, frequencies[], validityReasons[] | nil 不改成0；缺窗口不能拼装成功曲线 |
| 环境 | preflight, perStageEnvironment, postflight, backgroundLoadAssessment, telemetryAvailability, missingReasons | 只记录可取得字段，unknown 会影响可比性 |
| 统计 | median, MAD, relativeMAD, confidence, sampleCV, sampleCount, windowCount, expected/validTelemetrySampleCount, observedSeconds, timestampQuality |旧统计保持原值；新增CV由原样本复算，失败为nil |
| 评分 | componentScores?, chipScore?, systemScore?, efficiencyScore?, scoreStatus, comparability, reasonCodes, referenceIdentity, derivedCacheKey | decodeIfPresent；不得旧缺省=0；v10旧 overallIndex 恒nil不伪迁移 |
| 生命周期 | startedAt/completedAt UTC, measuredDurationSeconds, elapsedSeconds, dispatchDeadlineSeconds, drainDurationSeconds, cancellationRequestedAt?, state, failure, writtenBytes, metadataWrittenBytes |保留旧 cancelled/globalFailure；新缺省不声称已完整跑v11 |

`availability` 延续 available/unknown/unsupported/insufficientResources/failed/notImplemented/cancelled，新增 reasonCode（timestampMissing/capabilityConflict/aneAllocationUnverified等），不要为每种原因造一个假数值。状态、统计与样本数量互相验证：available需要完整合法样本；其它状态必须有非空原因，不能伴随0分。`partial` 保存已完成 Core 指标、窗口和被取消阶段，父分需完整依赖且环境有效；最终系统完整性与“可展示某个CPU分”区分。

解码顺序：先识别 schema→按原 schema 验证→映射只读适配层→需要时计算兼容 CV/展示；旧记录绝不改 schema/plan/hash 再调用 v11 `isValid`。新字段 optional/default 要用明确 `decodeIfPresent`；Swift 合成 Codable 的 stored default 并不保证缺 key 自动兼容。未知 ID/状态只读显示中文未知项并保留原字段，不能令整段历史崩溃或默默赋 available。迁移/换参考在临时文件验证成功后原子替换派生缓存，保护旧 JSON。

## 9. 所有运行 ID → 中文映射

第 2 节是全部 18 Core ID 的正式映射。以下涵盖 `MSeriesCoreRunner`、`MSeriesCPUExtensions` 的全部旧扩展 ID 和本规范全部 v11 ID；动态数字必须校验正整数。UI 内部 ID 不直接显示给用户。

| ID / 模式 | 中文运行名 | 展示说明 |
|---|---|---|
| `cpu.threadCurve.<N>` | CPU 线程曲线 · N 线程 | 单独扩展，不改18项序号 |
| `cpu.sustained.short.<K>` | CPU 短持续观察 · 第 K 批 | 历史约6秒，不称3分钟 |
| `cpu.extensions.remaining` | CPU 扩展观察 · 未完成项 | 失败/取消原因 |
| `gpu.advanced` | GPU 高级图形 | 旧占位，尚未实现 |
| `gpu.hardwareRayTracing` | GPU 硬件光线追踪 | 旧占位别名，仅历史 |
| `memory.workingSetCurve` | 内存工作集曲线 | 旧占位 |
| `storage.workingSetQueueCurve` | 存储工作集与队列曲线 | 旧占位 |
| `media.h264` | 媒体引擎 · H.264 编解码 | 旧占位/历史，与新两个方向区分 |
| `media.hevc` | 媒体引擎 · HEVC 编解码 | 同上 |
| `media.prores` | 媒体引擎 · ProRes 编解码 | 同上 |
| `media.av1.decode` | 媒体引擎 · AV1 解码 | v10占位，v11有真实方向 |
| `ai.image` | 神经网络 · 图像推理 | 旧占位，无假值 |
| `ai.text` | 神经网络 · 文本推理 | 旧占位，无假值 |
| `display.framePacing` | 显示 · 帧间隔稳定性 | 旧占位，与芯片分无关 |
| `power.efficiency` | 能效观察 | 旧占位，不能从历史推算新三点 |
| `power.cpu.single` | CPU 能效 · 单线程 | 10 s |
| `power.cpu.performanceCores` | CPU 能效 · 最高性能核心数量线程 | 旧芯片P核数；M5 Pro为超级核心数，不宣称绑核 |
| `power.cpu.allCores` | CPU 能效 · 全核心 | 10 s |
| `power.gpu.peak` | GPU 峰值与能效 · 三维图形 | 30 s |
| `sustained.cpu.allCores` | 持续性能 · CPU 全核心 | 90 s |
| `sustained.gpu` | 持续性能 · GPU 三维图形 | 90 s |
| `pressure.cpu.allCores` | 压力观察 · CPU 全核心 | 300 s |
| `pressure.gpu` | 压力观察 · GPU 三维图形 | 300 s |
| `media.h264.encode` / `media.h264.decode` | 媒体引擎 · H.264 编码 / 解码 | 两个独立方向 |
| `media.hevc.encode` / `media.hevc.decode` | 媒体引擎 · HEVC 编码 / 解码 | 两个独立方向 |
| `media.prores.encode` / `media.prores.decode` | 媒体引擎 · ProRes 编码 / 解码 | 两个独立方向 |
| `gpu.hardwareRayTracing.build` / `gpu.hardwareRayTracing.traversal` | GPU 光线追踪 · 结构构建 / 遍历 | 两个独立测量 |
| `gpu.tensor.fp16` | GPU 矩阵计算 · 半精度 | 独立展示 |
| `ai.smallModel.cpu` | 神经网络小模型 · CPU | 不计分 |
| `ai.smallModel.aneCandidate` | 神经网络小模型 · 神经网络引擎候选路径 | 未验证时不称纯ANE |
| `ai.smallModel.accelerationRatio` | 神经网络小模型 · 加速比 | 派生结果，不作为运行步骤 |
| `preflight` / `finalizing` / `cancelling` | 环境预检 / 正在保存 · 本机历史 / 正在停止测试 | 保存禁取消，停止等待排空 |

加速器旧套件的适配别名：`gpu.raster3d`→GPU三维光栅、`gpu.rayTracing.build`→GPU光追结构构建、`gpu.rayTracing.traversal`→GPU光追遍历、`gpu.tensor.fp16Gemm`→GPU半精度矩阵；保留其原协议/门限，不直接改写旧历史为v11。

未知未来 ID 显示“扩展测试 · 名称待适配”，保留日志ID但用户页面不泄漏英文枚举；不能一律退回“正在测试 CPU”。运行页传入真实单调 `elapsedSeconds`，不用 mockup 固定 1分08秒。

## 10. Apple Silicon 规格与具体SKU识别

目录逐字段来源见 `apple-silicon-catalog-sources.md`。schema升级为 `apple-silicon-catalog-v2`，`catalogVersion=2026-10-10-b1-review-r2`；保留原来的cpu/gpu选项、能力、逐字段来源及未知原因，新增 `skus[]`作为配置的唯一权威列表。删除v1并列的configurationPairs/memoryBandwidthOptions，不能同时维护两份不一致的组合表；v1快照和上一轮prepared已归档在scratch `revisions/b1-r1/`。

每个SKU结构：`{id,cpuOption,gpuCores,memoryBandwidthGBps?,maxUnifiedMemoryGB?,memoryLimitsByMac?}`。`cpuOption`是cpu数组的零基索引，GPU必须在gpuCoreOptions中。例：`m3-max-14c-30g`为300GB/s、`m3-max-16c-40g`为400GB/s；`m4-max-14c-32g`为410GB/s、`m4-max-16c-40g`为546GB/s。不得把家族最大带宽填给所有SKU，也不以CPU/GPU选项笛卡尔积补出不存在的配置。

当官方未明确某一配置的带宽，SKU值为null并在unverified指明缺证据；如果已有芯片级单值，保留可选 `chip.memoryBandwidthGBps`作为**未分配置的来源记录**。这个单值不继承到SKU，不用它表示当前配置已核实，也不能用于参考分/理论实测分；UI写“芯片级规格，当前配置未核实”。所有SKU带宽已确认的行不再保留顶层单值。精确TSMC节点仍null，性能/带宽/TOPS均不替代实测或产生参考分。

`maxUnifiedMemoryGB`同样读取当前SKU。芯片顶层历史上限保留作来源审计，不能覆盖SKU值；SKU最大值取已明确确认的Mac机型中最大值，已知机型时用 `memoryLimitsByMac`收窄。例如M4 Pro的MacBook Pro配置上限48GB、Mac mini可64GB；M5 Pro15C/16G的MacBook Pro上限48GB、当前Mac mini可64GB。M2 Max30G/38G为64/96GB，M5 Max32G/40G为36/128GB。M3 Ultra现行规格的256GB与发布时家族512GB历史上限分开保留，不把后者自动灌入每个SKU。内存bytes属于实际硬件回读；超出当前可售上限仅提示资料/历史配置差异，不能据此抹掉一个已由CPU/GPU识别的SKU。

`cpu[]`为不同CPU选项，完整资料满足 performanceCores + efficiencyCores + superCores = totalCores。M5 Pro18核为6超级＋12性能，performanceCores=12、efficiencyCores=0、superCores=6；两层perflevel不是所有世代都对应P/E。已取得总数但没有核心类型拆分的选项保留null/原因，不按其他bin比例估算；它不能被标作“拓扑完全核实”。中档能效使用最高性能层**数量**的workers，不提供绑核保证。

识别算法：

1. 原生arm64、Rosetta不为true才进入标准支持检查；translated未知单列，不虚构false。
2. `machdep.cpu.brand_string`完整名称归一化精确匹配chip（不能以包含M5把Pro当base）。brand是主证据；MTLDevice.name可用时做一致性旁证，冲突则ambiguous。Metal名称缺失不阻止已有品牌、CPU、GPU的SKU匹配；它不被伪填为profiler名称。
3. 读取hw.nperflevels及所有perflevel的name/physicalcpu/logicalcpu，保留原值；按Super/Performance/Efficiency名称匹配目录cpuOption，不按索引盲猜类型。hw.physicalcpu校验各物理层之和；logical未知不得复制physical当作读数。Ultra的die前缀不导致重复计数。
4. profiler读取选中内建Apple GPU的sppci_model/sppci_cores，核数为正整数，机型对应一致。5s超时降级，不收集序列号/显示器标识；名称不能代替GPU核数。
5. 以chip+CPU选项+GPU核数在skus中筛选；仅一个候选且拓扑与官方资料一致时返回`identificationStatus=matchedSku`、chipID、skuID、cpuOption和GPU。多个候选或缺关键层级则ambiguous/skuUnverified；总数唯一但类型资料不完整则skuTopologyUnverified，不能猜分拆。未来同CPU/GPU却受内存配置影响的带宽需要显式条件，资料没有条件时保持歧义，不能任选一个。
6. 展示带宽/容量从matchedSKU及适用机型profile取，不读取家族最大值充作当前SKU。字段缺值只降级该规格，不妨碍原生Core运行和可靠原始值；保留每项识别证据来源、时间、状态和缺失原因。

**本机识别已由主会话在沙箱外回读，唯一匹配 `m5-pro-18c-20g`（m5-pro 18C/20G SKU）**。本轮用户转交的主会话读数：

```text
hw.nperflevels = 2
hw.perflevel0.name = Super;       physicalcpu = 6
hw.perflevel1.name = Performance; physicalcpu = 12
hw.physicalcpu = 18
machdep.cpu.brand_string = Apple M5 Pro
system_profiler GPU cores = 20
hw.memsize = 51539607552 bytes
```

该SKU cpuOption=1、6超级/12性能、20GPU，官方规格带宽307GB/s、内存上限64GB；48GiB实际内存符合已确认配置。身份状态为PASS（主会话回读数据＋本轮唯一SKU匹配）；这是明确的主会话证据，本Codex没有再次自行读取受限sysctl。logicalcpu与Metal API名称未在本轮提供，仍保持unknown/NOT RUN，不宣称四路API都由本会话实测。上一轮沙箱sysctl被拒绝、profiler成功和原用户夹具记录保留为历史证据，不再作为当前本机SKU识别BLOCKED的理由；回读不证明v11跑分、能效、受控参考或app显示已经完成。

## 11. UI 数据契约与已确认效果图

唯一视觉基底：`~/Developer/.sc-build/r2-lightfield-r2/approved-20261009/mockups/a/performance-{landing,running,result}.html`，实际内容来自同目录 `shared.js`。其演示数字、协议、时长不能当真实产品数据。D72 改变数据口径；B4按计划先生成新HTML并经用户确认，不能宣称本B1批准新评分布局。

| 状态 / 已确认锚点 | 输入字段 | v11 必须展示 / 降级 |
|---|---|---|
| 起始 `performance.scope/options/option.*` | coreGroups/count=18、efficiencyPlan、sustainedPlan、mode、acceleratorSelection | 类别28pt图标、固定18项4+4/3/3/4无逐项勾选；新增三组说明；压力/加速独立选择 |
| 起始 `performance.budget/preflight` | estimatedDurationRange、writeBudget、power/thermal/lowPower/background、helperStatus | 完整标准预计约7–8分钟；持续3分钟单列；写入≤512MB；助手需要更新/不可用说明能效缺失；不过滤未知为成功 |
| 起始新增档案一行 | chipIdentity/configuration、GPU、memory、cooling、verification | 本机确认后“Apple M5 Pro · 6超级＋12性能核心 · GPU20核 · 48GB · 主动散热”；缺值“未读取” |
| 运行 `performance.running-label/item-position` | activeID→中文映射、phase、coreCompletedCount、stageElapsed、elapsedSeconds | “正在测试 · CPU多线程 · 压缩”；Core第n/18仅在Core；扩展显示阶段时间，不第19/18 |
| 运行 `performance.progress/progress-track` | frozenStageWeights、completedStages、phaseElapsed、plannedPhaseDuration | 总进度按预计耗时加权；18格仅Core子进度，不能Core结束就总100%；等待排空、保存状态清晰 |
| 运行 `performance.running-monitor` | timestamped power/frequency/temperature/efficiency、availability | 各单位独立轴/颜色；W/GHz/°C不共用假尺度；CPU/GPU负载作辅助；功率缺失显示“需要系统助手”，不填0 |
| 结果 `performance.summary` | state、coreCompletedCount、chip/system/efficiencyScores、referenceStatus、comparabilityReasons | 大芯片性能分与整机分/能效分；暂定前缀每分都有；未参考待校准；取消/中止明确完成项数 |
| 结果 `performance.metric/median/group.*` | 18项raw中位数/单位/MAD/confidence/CV、同契约上次值 | 原分组表保留；指针追逐越低越好；上次比较符号按方向计算；CV超限保留原值并注明无分 |
| 结果新增曲线 | CPU三效率点、GPU点、参考曲线、持续18窗口/保持率、timestampQuality | CPU横轴W纵轴相对吞吐分或原始吞吐（必须标单位）；没有参考用raw不造分；CPU/GPU不同单位分图 |
| 结果新增加速/档案 | accelerators、catalog field sources/unverified、cooling、sameGenerationConfigurations | 无此单元/未知/当前不可用分开；理论位置只画核数/匹配SKU带宽独立尺度，不能合成为实测分/名次；无风扇摘要优先持续保持率 |
| 结果 `performance.history/history-toolbar/community` |历史schema/contract/ref状态/时间，leaderboardProtocolStatus |同协议/同参考比较；旧Core可单项比较；服务端未上线显示“暂不可提交”，没有排名或击败百分比；匿名上传默认关闭 |

进度标准固定预算表：预检5、Core180、CPU效率45、GPU峰值35、CPU持续95、GPU持续95、保存5，共460权重单位；按 `completedWeight + activeWeight×min(elapsed/planned,1)` 归一化，再在成功保存前上限99%。这是用于展示的预算权重，480s为实际停止派发deadline；慢硬件到阶段上限可显示“正在等待完成”而不回退百分比。可选阶段在开始前加入并冻结权重；不会因助手不可用临时把总进度倒退。压力模式用独立600s负载权重。`canCancel=false`只在原子保存段；取消之后按钮与进度都进入停止态。

## 12. 资源打包与交付边界

仓库根 `Resources/Benchmark/` 新建目录。现有 `Package.swift` 没有SwiftPM resources，`script/build_and_run.sh` 只显式复制少数文件/根级图片，**当前不会自动把此JSON打入app**。B2/B3需按现有 `copy_resource_file` 模式复制目录下冻结资源至 `.app/Contents/Resources/Benchmark/AppleSiliconCatalog.json`（连同外部SHA manifest/后续模型与AV1位流），通过 `Bundle.main.url(forResource: "AppleSiliconCatalog", withExtension: "json", subdirectory: "Benchmark")` 读。纯SwiftPM测试/开发采用显式注入 fixture URL，不假定 `Bundle.module` 存在；若改成SwiftPM资源需移动/明确target资源路径并同步包脚本，本B1不改Package.swift或打包脚本。

B3验证文件hash/JSON结构后启用目录，失败降级为未知规格且仍可测raw。目录版本、原始byte SHA与field来源共同保存；修订源值重新生成hash，不能靠hash宣称官方来源已验证。B1目录是待主会话逐字段复核草案，内置生产启用前必须完成来源、SKU与机型内存限制和打包回读。

B1主会话检查和B2–B4输入清单见 `collab/handoffs/r2-bench-v11-b1.md`。本轮没有构建、Swift测试、参考采集、安装、提交、上传或发布；静态检查只证明文档/JSON/补丁的一致性。
