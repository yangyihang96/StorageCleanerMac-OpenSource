# r2-bench-v11 · B2b 内核与编排交接

日期：2026-10-10。基线：`48ec3ae66d800936fb2d15ec94b8537495b1b3ce`（B2a），分支 `task/r2-bench-v11`。D72 下唯一标准为 `docs/2.0.0/BENCHMARK-V11-SPEC.md`，本轮对照第 3–5、8、11 节实现；第 6 节评分复用 B2a。

交付状态：代码、替身测试、反证目录和 prepared 分组补丁已准备；沙箱增量编译通过。完整定向执行有 5 个沙箱相关失败断言，不能宣称全绿。未运行真实 benchmark、实机 powermetrics、sudo、真实媒体/GPU/模型推理；未安装、启动 App、写硬件设置、提交、合并或发布。

## 0. B2a 复核意见处理

已读取 `scratch/logs/codex-review-b2a.log` 末尾结论：无 P0，两项 P1、两项 P2。scratch 指 `~/Developer/.sc-build/r2-bench-v11`。

| 优先级 / 问题 | 依据与修复 | 对应行为测试 / 反证 |
|---|---|---|
| P1：Core 完整、`state=completed`、必需扩展全空仍判完整 | SPEC 3、8：`BenchmarkV7Result.isComplete` 增加必需阶段、窗口数量/连续时间/吞吐有效性检查；标准需三档 CPU、GPU 峰值、两段 90 s；压力需两段 300 s。功率缺失不阻断有效吞吐的完成状态。部分记录仍可持久化。 | `MSeriesV11RunnerTests/testP1CompletedCoreAndEmptyExtensionsCannotBecomeCompleteResult`：旧条件会错误返回 true；当前返回 false。`v11-empty-extension-completion` 删除必需测量条件，预期此断言变红。 |
| P1：聚合 work/J 没有绑定原始遥测与真实负载区间 | SPEC 3、4：生产 `inputs(core:envelope:)` 对全核效率复算原始 batch、sampleID、实际测量区间、时钟域、请求包围区间、独立样本数和各子窗交集；逐项对照匹配工作量、能量、时间及三窗效率。空遥测、倒置区间、重复/相交样本、错误时钟与非正功率不能造分。B2a `evaluate` 的直接输入语义保留，原 13 项反证仍适用。 | `MSeriesV11WindowTests/testP1ScoringRequiresRawTelemetryAndCoherentWorkIntervals` 同时检查合法证据被接收、空遥测/倒置负载被拒绝。`v11-raw-power-proof-bypass` 旁路原始证据校验，预期无效效率错误进入输入而变红。 |
| P2：同步身份采集接入主线程会阻塞 | 后台 `captureAsync` 与生产 runner 的 detached 身份采集；旧同步公开入口保留。 | `AppleSiliconCatalogTests/testAsyncHardwareCaptureRunsProfilerOffMainThread` 的注入 collector 断言 profiler 不在主线程。 |
| P2：`hw.model` 不匹配营销名而回退更高内存上限 | 复用 B2a 已冻结的机型内存表，补 M4 Mac16 系列映射；有机型特定上限但未知机型时返回未知，不回退家族最大值。未改规格资源 JSON。 | `AppleSiliconCatalogTests/testSKUSpecificationsNeverInheritFamilyMaximum` 新增硬件标识、未知机型断言。 |

两项 P1 对应的新行为断言在沙箱均通过；反证仅已准备、未执行。两项 P2 已修，无延期项。

## 1. 实现与数据流

### 1.1 固定负载、曲线与持续统计

- `MSeriesV11BatchDriving` 提供 prepare/next/finish 替身入口；生产 actor 复用原 C 整数内核和现有 `Metal3DBenchmarkKernel` driver，不重写负载。CPU pilot 后锁定 repetitions，GPU 固定 1 帧批次；预热上限 2 s，校验在计时外。
- 标准顺序为预检 → 原 Core 18 → CPU 1/最高性能层物理核数/全部逻辑核数各 10 s → 同一标准场景 GPU 30 s → CPU 90 s → GPU 90 s。最高性能拓扑未知时保留缺失原因，不用 logical 冒充 physical。标准路径禁用旧短持续扩展；v10 默认行为保留。
- `pressure10m` 显式模式只运行 CPU 300 s → GPU 300 s，各 60×5 s，负载共 600 s；不生成标准综合分、最佳或参考输入。
- 原始 batch 保存起止、工作量、GPU elapsed、checksum 与时钟域。跨窗按实际重叠比例分配工作量；校验/派发间隙仍计墙钟。GPU 可比分使用可靠 GPU 时间；GPU 能效用匹配功率区间内的墙钟工作量。单位分别为 fixed-fixtures/s、fixed-fixtures/J、Mtri/s、Mtri/J。
- CPU/GPU 持续逐 5 s 生成吞吐、可取得的可靠芯片温度及功率；缺值为 nil。头两窗与尾六窗中位数计算保持率，保留 >1；全窗 CV 用于诊断，尾窗 CV 用于派生门禁。迟到环境观察、不完整窗口、错误时间与 GPU fallback 保留原始值并标无效，不能缩短后宣称完成。

### 1.2 共享助手遥测与 D5

`HelperPowerMetricsMonitor` 继续拥有唯一 demand stream；新 observer 和 `MSeriesV11TelemetryBridge` 只订阅现有通道。请求起点间隔 ≥2 s、最多一条在途，完成后只等到下一个 due，修复旧“完成后再睡 2 s”约 3 s 的节奏。不可见时释放本消费者，忽略旧会话/可见之前的在途回包；其它消费者不受影响。上限 1024 条，溢出有明确原因，最终预算检查拒绝超限而非静默截断。

应用和助手复用系统绝对连续单调时钟 `mach-continuous-v1`。wire 新增可选 timing envelope，兼容旧回包；保留 sampleID、随机 helperBootID、requestStart、responseReceived、簇身份/频率。只有同域、区间与 duration 一致、落在请求包围区间内的 `helperMeasured` 才能进入能效计算。CPU 至少 4/5、GPU 至少 12/15 独立样本且三统计窗各有交集；mW→W 后按真实交集累加 J 与 work，不插值、不补缺口。

**当前生产助手仍不能证明 powermetrics 的实际测量区间。** `PowermetricsProcessRunner` 的 timing 仅标 `requestBracketOnly`，measurementStart/End 留空；不能把命令起止或回调时间当实际采样。即使返回 W，也仅作诊断，能效降级并附 `helperMeasurementIntervalUnavailable` / `timestampMissing`。该限制由规范第 4 节允许的降级处理覆盖，B5/B6 不能把此路径作为有效能效校准来源。

没有第二条 powermetrics、安装/授权动作、充电或风扇写入。采样代码不触碰充电暂停设置，遵守 D5；没有实现能耗页↔小窗采样联动。

### 1.3 取消、热保护、超时与保存

预检 `.serious/.critical` 拒绝；每批及 ≤1 s watcher 检查环境。`.fair`/未知环境按 B2a 可比性门禁保留限制。停止派发 deadline：CPU 15 s、GPU 峰值 35 s、持续 95 s；标准总 480 s、压力 660 s。Core 使用原算法，新增外层 180 s 和单项超时停止后续派发入口。

取消/热保护/超时均停止后续阶段，取消共享 token，并结构化等待 worker、GPU/VT 回调和 driver.finish 排空，再释放同一个 `HeavyWorkCoordinator` lease。正常阶段结束只取消自己的 watcher，不能误取消整轮 token。保留已完成 Core、原始 batch/窗口、请求时间与排空耗时；取消的实际有效时长不会被写成完整 90 s。不可抢占的驱动调用可能超过 UI 2 s 目标，本轮仅以替身确认等待排空和租约行为，真实延迟验收留 B5/B6。

`rawPayloadSHA256` 来自实际 Core＋原始 envelope 的 canonical JSON；排除自身、派生分/参考/缓存以及可复算的元数据写入账，保留测量、状态、环境等原始证据。引用或缓存重算不改变 raw SHA；改原始字段会改变 SHA。

复用同一历史仓库。v11 只在原子保存段不可取消；写前按整份历史实际 JSON 字节数核算临时＋最终副本 ≤2 MiB、最终 ≤1 MiB、Core＋元数据 ≤512 MiB。超限拒绝且旧历史字节不变，不截断历史或遥测。保存失败保留审计错误/回执。v10 保存流程保留。

### 1.4 独立加速单元与 ANE 闸门

- H.264/HEVC Main 8-bit/ProRes 422 使用固定 1080p、60 帧输入；一预热、各方向三样本、配对 deadline、输出校验与 RequireHardware/UsingHardware 回读。ProRes 不套 12 Mbps。共享 live memory/encoded budget，回调排空后释放，媒体数据不进历史。
- 光追复用原场景、build/traversal 配对，共享预热；MPS FP16 仍是纯 Metal 路径。按 SPEC 独立 5%/10% CV，不改变旧实验套件 8% 门限。编译、准备不计硬件吞吐。
- gate 区分目录 null、明确无硬件、运行时不可用、能力冲突、资源不足及未实现；未知但运行时有证据只出 raw，不能宣称专用单元。不支持返回状态/原因，不报错误分、不计 0。
- AV1：明确无硬件时 unsupported；其它机器因没有冻结且许可/来源/SHA 可核实的位流，返回 `notImplemented/av1FixtureMissing`。没有伪造 AV1 测量。
- ANE：先做 5.2 闸门。仓库无 `.mlmodel/.mlpackage/.mlmodelc` 固定资源，本地未安装 coremltools；SDK 有 MLComputePlan 接口，但没有 ≤2 MiB 的冻结模型、source/compiled SHA 或关键算子分配证据。本轮禁真实推理，未尝试运行，不能据配置或速度证明 ANE。返回 `notImplemented/aneAllocationUnverified`，标 **阶段 2**，不派发模型、不产加速比。证据：`scratch/evidence/b2b-ane-gate.json`。这不是认定硬件不支持或 SDK 无 API。

媒体夹具标识、参数和 semantic checksum 载体已实现，但原生 VT/Metal 路径未在本轮运行；冻结原生可重复输出、实际硬件回读、内存和取消延迟仍需 B5/B6 可行性验收。

### 1.5 接入边界

coordinator 增加 v11 plan 派发，Store 增加显式 `startV11Benchmark(mode:accelerators:)`，App 从已有 ScanStore monitor 构造 bridge。可选阶段开始前冻结权重，复用 B2a 加权进度、保存前 99% 上限与既有中文映射，仅追加独立加速阶段标题。Workspace 仅补可见性 hook。

旧起始页官方入口仍沿原 v10，B4 负责经确认的 v11 起始/结果 UI；本轮未重做运行页或评分布局。`ScanStore.swift`、Core C 负载/夹具、v10 contract 字节、规格 JSON、B2a 已过测公开语义未改；新增 optional 字段/默认参数保持兼容。

## 2. 实际验证与中断恢复

2026-10-10 约 08:02 主会话进程重启导致旧命令被强制中断。恢复后先检查 git status/diff stat、冲突标记与文件尾部；没有发现半写源文件，保留全部已有修改和 SwiftPM scratch。旧 tool session 不存在；`ps` 被沙箱禁止，未据此声称已证明系统没有其它进程。续用原 scratch 增量编译，没有重做已通过的原生负载或测试。

| 验证 | 实际结果 / 日志 |
|---|---|
| 完整 B2b 源码＋测试编译 | PASS，`logs/b2b-build-final.log`，20.79 s |
| 最后新增 accelerator 中文标题后的增量编译 | PASS，`logs/b2b-build-title.log`，36.98 s，exit 0 |
| 16 类定向（标题新增前） | 181 tests / 5 failures（1 unexpected）/ 0 skipped，exit 1；`logs/b2b-targeted-final.log`。四个全新测试类共 42 个测试全部 PASS。 |
| 标题新增后的受影响类 | `MSeriesV11PresentationTests` 4 tests / 0 failures，exit 0；`logs/b2b-targeted-title.log`。未无理由重复其余已通过类。 |
| 静态 | `git diff --check` PASS；`script/check_private_api.py` PASS（7 allowlisted uses）；反证 schema、28 个 before 精确匹配一次及 filter 行为方法存在已检查。 |
| 反证执行 | 未执行；按 `codex-build-common.md` 留主会话。原 B2a 13 条完整保留，追加 15 条，总 28 条。不能宣称 28/28 变红。 |
| prepared | `prepared/b2b/` 5 组补丁、SHA manifest、检查/提交脚本。只运行 `--check-only`，未写真实 git index、未提交。 |

沙箱失败的具体方法（不删、不开 skip、不改夹具位置、不放宽产品路径/阈值）：

1. `BenchmarkV7HistoryPresentationTests/testDeletingLastConfirmedRecordCannotRevealRevokedLateSuccess`：171 行 synchronize 断言；附近 `sandbox_extension_issue_file … defaults.plist … Operation not permitted`。
2. `TestPreferenceHygieneTests/testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`：308、309 行两个断言；同类 plist sandbox extension 拒绝。
3. `TestPreferenceHygieneTests/testTemporarySuiteCanBeReopenedOnAWorkerThread`：324 行 synchronize 断言；同类拒绝。
4. `HelperPowerMetricsMonitorTests/testScanStoreWiringDegradesWithoutRequestingOrAuthorizing`：`TestFileSystem.swift:60`，NSCocoaError 513 / underlying POSIX 1，无法创建 `~/.storage-cleaner-scan-store-<UUID>/home`，一项 unexpected failure。

旧断言改写：**无**。新增窗口测试早期把浮点精确相等改为数学期望值的 `accuracy: 1e-12`，原因是区间比例运算舍入，未改产品门限或任何旧断言。早期新增编排失败暴露正常 watcher 结束误取消 token 的竞态，已从根因修复并通过后续编排/租约测试。

JEV decide 与 review 均返回 `MCP tool call requires approval, but approval policy is never`，未得到任何模型判断；没有声称独立复核通过。

## 3. 反证、定向与主会话命令

`scratch/targeted-classes.txt` 保留 B2a 十类，新增窗口、编排、加速门控、遥测 bridge、共享 monitor、parser 六类；包含强制偏好与 UI 一致性类。没有选真实 Core/GPU/媒体负载类；新增测试全部注入 driver、时钟、identity、environment、core/provider，绝不调用生产 factory。

新增 15 条反证各自绑定行为断言，覆盖：空扩展完整性、原始功率证据旁路、跨窗整批重复计量、GPU 活跃吞吐错配墙钟能量、样本覆盖门槛、请求包围时间冒充测量、保持率截为 1、deadline、热保护、排空前释放 lease、恒定 raw SHA、null 当无硬件、ANE 闸门旁路、请求起点节流和整份历史预算。格式保持 `{mutations:[{id,path,before,after,expected_occurrences,filter}]}`。

主会话先在沙箱外用同一 scratch 复跑完整定向（当前含新增标题共 182 个测试），确认上述环境失败消失；不得跳过失败方法：

```zsh
cd ~/Developer/sc-worktrees/r2-bench-v11
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-bench-v11/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' ~/Developer/.sc-build/r2-bench-v11/targeted-classes.txt)"
```

主会话按已有 mutation harness 执行全部 28 条：每次精确替换指定次数，编译后只跑该 filter，红必须来自列出的行为断言；编译失败、找不到测试、环境失败不能算反证成功。恢复原文件后按受影响类确认绿。新目录完整快照随 prepared 提供。

项目完整验证由主会话按既有约定执行，使用私有 `STORAGE_CLEANER_VERIFY_ROOT`、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`。本轮没有执行 `script/verify.sh` 全量，也没有放宽其门禁。任何可能运行真实负载的验证需由 B5/B6 单独安排，不能在本 B2b 自动启动。

prepared 的基线、工作树文件与产物 SHA 需先核对；主会话完成上述必要验证后才使用显式提交入口：

```zsh
python3 ~/Developer/.sc-build/r2-bench-v11/prepared/b2b/commit-prepared.py --check-only
# 主会话验证通过后执行；本沙箱未执行：
python3 ~/Developer/.sc-build/r2-bench-v11/prepared/b2b/commit-prepared.py --validated
```

## 4. 未解决与后续责任

- 沙箱外定向、28 条反证与独立复核仍待主会话；本轮不宣称全量、Release、Bundle、安装或发布通过。
- 现有助手没有可验证实际 interval，生产能效暂 unavailable；补助手测量证据与实机采样对齐应单独验证，不能伪造解决。
- ANE 阶段 2：固定许可模型、≤2 MiB 编包、source/compiled SHA、官方关键算子分配证据尚未交付；AV1 冻结位流、许可和 SHA 尚未交付。
- 原生 CPU/GPU/VT 性能、持续温度/功率、驱动排空延迟、内存与媒体夹具可重复性留 B5/B6；本轮只有替身行为验证，不形成任何真实参考值或实机验收。
- B4 接入显式 v11 起始选择与新结果 UI；能耗页↔小窗联动属另批。

## 5. fix1：冻结 v6 源码与两条存活反证

日期：2026-10-10。主会话 `scratch/logs/main-final-0847/` 已确认原 B2b 定向 **182/0**；全量 4467 项中 `MacBenchmarkCalibrationWorkflowTests/testFrozenV6ProtocolFingerprintMatchesCalibrationGate` 一个方法失败（93、97 两个失败报告）；反证 **26/28**，两条存活。本节覆盖前文相应旧状态，但不修改原 prepared/b2b 五组或其 manifest。

### 5.1 冻结源码指纹恢复

冻结路径来自原校准测试的 `frozenWorkloadSourcePaths`，按顺序拼接 `path + NUL + bytes + NUL` 后计算 SHA-256，共 11 个文件：

```text
Sources/StorageCleanerMac/Models/MacBenchmarkModels.swift
Sources/StorageCleanerMac/Services/Benchmark/CPUBenchmarkKernel.swift
Sources/StorageCleanerMac/Services/Benchmark/DiskBenchmarkKernel.swift
Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkPreflightService.swift
Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkResultProcessor.swift
Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkService.swift
Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkServiceProtocol.swift
Sources/StorageCleanerMac/Services/Benchmark/MemoryBenchmarkKernel.swift
Sources/StorageCleanerMac/Services/Benchmark/MetalBenchmarkKernel.swift
Sources/StorageCleanerMac/Services/Benchmark/Metal3DBenchmarkKernel.swift
Sources/StorageCleanerMac/Services/MacBenchmarkScoring.swift
```

与 B2b 改动的交集只有 `Metal3DBenchmarkKernel.swift`：新增的工厂、execution 时间字段和 driver 连续时钟读数改变了整个源码指纹，即使旧算法没改，也违反字节冻结边界。fix1 将该文件恢复为 HEAD 原字节，校准测试、覆盖列表和 expected **均未修改**。

- before：`9e86b9932f89f7c935eec36df18db97d9f685cc03b95c3dbb5bf232703f8f40b`
- after / 原 expected：`b6f20c14c535e5d6ca025d1cc2370a924cd4f392018c7aead92ce1b8cc41510d`

原 driver 与工厂是文件私有，外部 Swift extension 无法常规访问。为避开共享改动，新 `MSeriesV11Metal3DDriver.swift` 使用 v11 独立 execution/protocol，迁出 B2b 工厂与时间证据；其中 driver 从同一冻结实现沿用，仅重命名类型、增加连续时钟区间。shader、场景、准备、一次预热、GPU 时间算法、checksum、waitUntilCompleted 和资源回收代码保持一致。没有通过每批重跑 legacy `Kernel.run` 混入重复预热/编译，也没有放宽原 private 可见性。

`MSeriesV11KernelBoundaryTests/testV11RendererPreservesFrozenSceneValidationAndDrainCode` 逐字检查迁移 driver：只移除明确的 v11 名称/时间附加代码后，必须等于冻结 driver 全文。另一个注入 driver 测试确认固定 1920×1080/262144/1 frame/12 triangles、一次预热、validation 不延长 batch 区间、finish 排空；不创建 Metal 设备或运行 GPU。

结果：11 个冻结文件及原指纹校准测试均与 HEAD 字节一致；原失败方法在沙箱定向 **PASS**。证据：`prepared/b2b-fix1/fingerprint-evidence.json`。Core C 夹具/算法和 ScanStore 未改。

### 5.2 请求包围时间反证的漏检

原测试已有 requestBracketOnly 数据，但只断言最终效率 nil：变异放宽 `measuredTelemetry` 后仍被独立 `timestampMissing` 门禁挡住，导致变异存活。新增隔离用例使用五个唯一 ID、合法同域起止/duration、正功率和完整负载；正对照 helperMeasured 必须有能效，仅 quality 改为 requestBracketOnly。

除效率 nil 与 `alignmentQuality=unavailable` 外，明确断言：有效样本数 0、`timestampMissing` 与 `insufficientPowerSampleCoverage` 原因存在，原始功率交集的 observedSeconds/J/matchedWork 均为 0、sampleIDs 为空，吞吐仍保留。原有五组无效条件和断言全部保留。对应原 filter `MSeriesV11WindowTests/testMissingUntimedWrongDomainInvertedAndZeroPowerCannotFabricateEfficiency` 绿；原变异仍是“接受 requestBracketOnly”，现在预期由非零功率交集/有效计数的行为断言变红，不能用最终 nil 的冗余门禁判成功。

### 5.3 历史写入预算反证与一字节边界

两个原常量确实不同：v11 最终上限 `1_048_576`（1 MiB），旧历史 `Self.maximumFileBytes=8*1_024*1_024`（8 MiB）。原反证单独换成 8 MiB 后，仍会被原子副本的 2 MiB metadata 条件拒绝；原 1.1 MB 用例同时违反两道等价预算，不能检测该变化。

fix1 将 v11 最终上限集中为 `maximumV11ResultBytes=1_048_576`，最终 JSON 与两份原子副本都从它核算；生产数值仍为 1 MiB/2 MiB，旧历史 8 MiB 不变。保留原大历史拒绝/旧字节不变断言，并追加精确边界：构造整份实际 JSON 恰好 1 MiB，保存成功、两记录仍在；增加一个 ASCII 字节后为 1 MiB+1，必须在写入前拒绝、旧文件字节完全不变、旧记录仍可读。incoming record 本身、raw SHA 和初始 envelope metadata 均合法，防止在更早门禁被意外拒绝。边界来自 SPEC 字面量，不随实现常量改变。

`v11-history-write-budget-bypass` 保留 ID/filter，改为 `maximumV11ResultBytes = 1_048_576` → `1_048_577`，同时放宽相同来源的最终/副本预算；预期确实写入超限一字节历史，触发“必须拒绝”和“旧字节不变”行为断言。两条测试绿，变异执行仍留主会话。

### 5.4 fix1 验证与补丁基线

- 编译：`logs/b2b-fix1-build.log`，**PASS / exit 0 / 35.62 s**。
- 定向：原 17 类（原 16＋新 KernelBoundary）另加**仅**冻结指纹方法，`logs/b2b-fix1-targeted.log`，**185 tests / 5 failures（1 unexpected）/ 0 skipped**。窗口 7、runner 10、kernel boundary 2、原 fingerprint 1，共 20 个相关测试全部 PASS；剩余失败仍为前文四个方法中的五个沙箱权限断言，未修改/排除它们。
- `targeted-classes.txt` 保留旧十六类并追加 `MSeriesV11KernelBoundaryTests`；校准工作流类可能含真实采集，故只把 fingerprint 方法写入 `prepared/b2b-fix1/targeted-filter.txt`，不选整个类。
- `git diff --check`、私有 API 检查通过；28 条 before 均匹配一次、filter 方法存在，原 B2a 前 13 条逐对象一致。counterexamples 仍 28 条，只修改历史预算那一条；未在沙箱执行变异或全量。
- JEV 本次决定调用仍被 `approval policy is never` 拒绝，没有获得判断。

交付 `prepared/b2b-fix1/` 是 **HEAD `48ec3ae66d800936fb2d15ec94b8537495b1b3ce`＋原 prepared/b2b 五组之后的增量**，不是再次提交 B2b。三组：恢复冻结 renderer/迁出 v11 → 反证边界与共享预算 → 追加交接。manifest 记录复合基线、原 B2b artifact SHA、before/final 文件 SHA、组顺序；保留 baseline 快照供增量检查。另有 `combined-from-head.patch` 仅用于复合工作树审阅/只读应用检查。

`--check-only` 核对原 HEAD、原 B2b 快照与产物、fix1 增量对快照可应用性、最终组合对 HEAD 可应用性及所有最终文件 SHA；使用私有 index，不写真实 `.git`。`--validated` **要求主会话先提交原 B2b 五组**，核对当前提交树与原 B2b 最终文件一致，才按 fix1 三组提交；如果仍在原 HEAD，会拒绝并说明前置条件，不重放五组。本沙箱未执行 `--validated`。

当前工作树已含 fix1，原 B2b 脚本的旧工作树 SHA 检查会拒绝直接提交。为使复合基线可实际建立，fix1 脚本提供显式 `--validated --include-b2b-baseline`：仅在旧 HEAD 时，先将已验证原五组 patch 暂存/提交，保持工作树 fix1 字节，再提交本轮三组；如果原 B2b 已在 HEAD 中，此选项拒绝执行以防重复。默认 `--validated` 仍只提交增量；本沙箱未执行任一写 git 入口。

主会话最小复验（沿用前文 F 参数）：

```zsh
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(cat ~/Developer/.sc-build/r2-bench-v11/prepared/b2b-fix1/targeted-filter.txt)"
python3 ~/Developer/.sc-build/r2-bench-v11/prepared/b2b-fix1/commit-prepared.py --check-only
```

优先复跑两条存活反证，红必须来自本节列出的行为断言，之后复验全部 28 条与原全量；本轮没有声称反证已达 28/28 或全量已绿。继续遵守不跑真实负载、ANE/AV1/helper 证据限制及 B5/B6 的实机边界。


## 6. fix2：高速批次预算、生产计时守卫与后台验证

日期：2026-10-10。基线 **09ac24ebcb8ddb44f9a40b9cfb69e75aad3caadc**，分支 `task/r2-bench-v11`；该 HEAD 已含 B2b 与 fix1。本轮开始时工作区干净。全文读完 `scratch/logs/codex-review-b2b.log` 末尾独立复核结论：无 P0，1 P1、2 P2。复核所引用的主会话上一版结果为定向 184/0、全量 4469/0（25 skips）、反证 28/28；这些是 **fix2 之前**的证据，不替代本轮验证。

### 6.1 P1：保留所有原始证据，紧凑落盘并中途预判

依据：SPEC §3 要求每批起止时间与工作量保留、跨窗按交集复算；§3.1 压力为 CPU 300 s → GPU 300 s、各 60×5 s；§5.3 单份最终 JSON ≤1 MiB、原子副本合计 ≤2 MiB，不能截断遥测；§8 要求完整窗口、环境、版本与生命周期证据。旧批数组在 50 ms 下仅 GPU 6000 行已超预算，末尾才拒绝会浪费整轮。

新增 `MSeriesV11CompactStorage.swift`，使用系统公开 Apple Compression / LZFSE **无损**存储 v11 envelope 的展开 JSON。没有丢弃或聚合原始行：全部 batch 的 stageID、UInt64 起止/checksum、Double workUnits/GPU 时间、clockDomain，以及所有环境观测、遥测、统计窗口、空值和原因均保留。磁盘 wrapper 有明确 `payloadEncoding=mseries-v11-lzfse-json-1`、展开长度、展开字节 SHA、base64 payload；decode 检查长度和 SHA 后恢复原模型，业务/评分/窗口接口语义保持原样。旧展开 JSON 仍可读取；无 batch 的旧夹具继续使用原展开格式。这里增加的是存储格式标识，不改测量、Core 或评分契约版本/hash。

`rawPayloadSHA256` 仍由**原展开、排序键的 JSONEncoder 字节**计算，仍只排除 digest 自身及原有派生缓存/写入账本；不是压缩流 SHA，也不因压缩算法或原子 metadata 变化而改变。wrapper 的展开 SHA 是另一个完整性检查。accounting 字段置于压缩流外，避免更新 metadata 时压缩长度循环抖动。64 MiB 展开上限仅限制内存解码/编码规模，**不是磁盘或写入额度**；最终整个历史 JSON 仍由原 repository 以实际 byte count 守住 1,048,576 B，预算常量和两份副本核算均未修改。

运行中每 5 s 在后台编码当前证据，按已测/计划时长预测剩余数据：固定身份、预检和已有窗口只计一次，增长项为 batch/环境记录。预测阈值 768 KiB，为最终曲线、最多 1024 遥测点和父记录保留 256 KiB；超过时立即停后续派发，等待 driver/watchers 排空、保存未截断的部分证据，原因 `evidenceBudgetForecast`。这是基于已观测压缩增长的预判，不声称能预知任意未来数据的熵；最终实际 JSON 的硬预算仍独立检查。预判只做内存编码，不在压力循环中反复写盘。

测试：

- `MSeriesV11RunnerTests/testHighFrequencyStandardAndPressurePreserveAllBatchesAndFitAtomicBudget`：CPU/GPU 都使用 50 ms 的合法替身批次、长 UInt64 时钟；标准完整 240 s / 4800 批，压力完整 600 s / 12000 批（GPU 6000），真实 repository 原子保存。逐行 equality、环境、18/60 窗口、metadata=最终文件×2 和 raw SHA 均验证；从读回 batch 重算每个持续窗口的 workUnits、墙钟吞吐和 GPU 吞吐。
- 最终定向日志实际文件：标准 **58,120 B**，压力 **97,576 B**，分别有 **48 / 120** 次运行中预算检查；这些是**替身 JSON 大小**，不是实机性能数据。watcher 调度会改变合法观测数/文件大小，所以不锁某个压缩字节数，只锁 ≤1 MiB、所有证据相等及窗口复算。
- `testBudgetForecastStopsEarlyAndPersistsPartialWithoutDroppingEvidence`：每次环境带独立可复现高熵文本，第一轮 5 s / 100 批即预测超限，GPU 不派发，driver 清理；实际 partial JSON 仍在预算内，所有已收集批次/环境完全保留，SHA 正确，保存后可读。替身限制为最多 100 个正常请求并断言没有第 101 次提交；禁用预测门禁的变异会快速触发请求数与 failure 原因断言，避免反证被大量高熵编码拖到超时。
- `MSeriesV11CompactStorageTests` 4 项：独立固定原 JSON 字节 oracle 证明 SHA 契约不变、旧记录可读；UInt64.max/Double bitPattern/全部证据精确回读；写入账本变化不改变压缩流或 raw SHA；错误长度、超大展开声明、坏 payload/SHA/format 拒绝；固定 20 KB 身份信息不随 120 倍时长比例重复计算。

新 oracle 在初次测试中发现当前 SDK 的 JSONSerialization 把 0.025 写为 0.025000000000000001，而原 JSONEncoder 使用 0.025。只修正**新测试 oracle**为原 JSONEncoder 的独立固定字节，不改 raw 编码规则、不放宽断言、不更新任何冻结指纹。

### 6.2 P2-1：锁定之前豁免的生产计时、工厂与执行结构

保留原归一化 renderer 全文检查及注入 driver 的场景/校验/排空行为测试；新增 `MSeriesV11KernelBoundaryTests/testProductionTimingFactoryAndExecutionContractArePresent`：

- 锁定 driver 之前的全部源码（execution 字段/初始化、protocol、工厂）SHA：`a4d274d03ab8ce346f666cb64bad50203280807cdba74557f243f562f55825b1`。
- 四条生产计时代码每条恰好出现一次，并检查 begin → commit → waitUntilCompleted → end → 写入 execution → return 顺序。
- 实例化工厂返回的 actor 类型；只创建空 actor，**不调用 prepare、不创建 Metal 设备、不执行 GPU**。execution 初始化的 GPU/wall/fallback/mainThread 字段与 nil timing、UInt64 时间赋值做行为断言。

`v11-delete-production-gpu-timing` 删除 execution 的两个时间赋值（代码仍可编译、默认 optional 为 nil），filter 只选新增测试：预期“赋值恰好一次”和顺序存在的断言失败，不能把编译失败当红。没有改生产 driver 字节，更没有改 v6 冻结文件。

原 `frozenWorkloadSourcePaths` 11 个源文件均与 HEAD 逐字节一致，聚合指纹仍是 **b6f20c14c535e5d6ca025d1cc2370a924cd4f392018c7aead92ce1b8cc41510d**。原 expected、路径列表、校准测试未改；原 fingerprint 方法定向 PASS。证据 `prepared/b2b-fix2/fingerprint-evidence.json`。

### 6.3 P2-2：SHA/JSON 移出主 actor，等待后台完成后发布

`MacBenchmarkStore.finishV11Result` 的保存前 isPersistable（含 raw SHA、模型与 JSON 预算验证）移入 `.utility` detached task，并等待其 value；保存后 isComplete 的复核也在后台。用户已请求取消时，取消 envelope 的重新封装/SHA 同样在后台完成并等待，随后走原一次原子保存路径。所有发布仍在 main actor，后台结果回来后再次核对 operation generation。没有将 SHA task 交给不受跟踪的后台队列，取消不丢任务；仍遵循 SPEC §5.3/§11：“正在保存”阶段不可取消，提交成功或失败后才发布终态。

只增加默认等于原 `result.isPersistable` 的验证 closure 注入口，方便验证真实 Store 路径；repository 仍独立验证，不能借注入越过生产保存硬门禁。旧非 v11 路径语义不变。

`MSeriesV11PersistenceTests`（位于 RunnerTests 文件，共用私有替身）3 项 PASS：

- 真实 Store 调用验证 closure 的 Thread.isMainThread 必须 false；保存恰好一次，历史/最新结果等于已保存记录，之后才 completed。
- 有界 gate 阻塞后台验证时，main actor 仍能执行断言；历史尚未写入/最新结果未发布，cancelV7 保持 persisting；gate 放行后一次保存并 completed。gate 有 3 s 保护，线程回退也以断言失败结束，不制造死锁反证。
- 替身 batch 在途时从 Store.cancelV7 请求取消，立即 cancelling；排空前没有历史写入/终态，放行并清理后保存 raw SHA 可验证的 cancelled 记录，再发布 cancelled。

### 6.4 定向、反证与未运行边界

最终编译 `logs/b2b-fix2-build-final2.log`：**PASS / exit 0 / 5.63 s**。前一轮完整源改动增量编译 `logs/b2b-fix2-build-05.log`：PASS / 13.42 s。最终定向 `logs/b2b-fix2-targeted-final2.log`：**195 tests / 5 failures（1 unexpected）/ 0 skipped / exit 1 / 24.964 s**；19 类另加仅冻结 fingerprint 方法。本轮新增 10 项全 PASS；runner 12、compact 4、kernel 3、persistence 3、fingerprint 1 共 **23 个直接相关测试全 PASS**，时间对齐窗口 7 项也全 PASS。

仍受沙箱权限限制的是之前同样四个方法中的五个断言，未删/跳过/改写：

1. BenchmarkV7HistoryPresentationTests/testDeletingLastConfirmedRecordCannotRevealRevokedLateSuccess（171）：临时偏好 synchronize 被拒。
2. HelperPowerMetricsMonitorTests/testScanStoreWiringDegradesWithoutRequestingOrAuthorizing：TestFileSystem 60，家目录操作夹具 `NSCocoaErrorDomain 513 / NSPOSIX 1 Operation not permitted`。
3. TestPreferenceHygieneTests/testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory（308、309）：临时绝对路径域持久化/回读未获得权限。
4. TestPreferenceHygieneTests/testTemporarySuiteCanBeReopenedOnAWorkerThread（324）：相同偏好域权限限制。

scratch `targeted-classes.txt` 保留原 17 类，加 compact/persistence 两类；原校准类可能触发真实采集，**不选择整类**，只在 `prepared/b2b-fix2/targeted-filter.txt` 追加 fingerprint 方法。未执行真实跑分、GPU/VT/Core ML、sudo/实机 powermetrics、安装、应用启动或硬件设置写入。ScanStore、Core C 源/夹具算法、目录/参考资源、11 个冻结文件全部未改。

scratch `counterexamples.json` 保留原 **28 条逐对象一致**，追加 5 条，共 33；原格式不变。`mutation-targets.json` 确认每条 before 匹配 1 次、filter 方法存在。按 codex-build-common 要求，**本沙箱不执行反证或全量**，不能宣称新 33 条已红：

| 新 ID | 变异 | 预期红的断言 |
|---|---|---|
| v11-disable-lossless-storage | 禁用紧凑表示 | 整轮 completed、批数/窗口、可保存、实际 JSON ≤1 MiB |
| v11-budget-forecast-disabled | 禁用运行中 forecast 门禁 | 第一轮 100 批即停、failure=evidenceBudgetForecast、不派 GPU、partial 可保存 |
| v11-delete-production-gpu-timing | 删除 production execution 时间赋值 | 两条赋值存在且仅一次、计时顺序完整 |
| v11-store-validation-on-main | 绕过 detached 直接验证 | Store 验证线程必须非 main（不选阻塞 gate 用例） |
| v11-hash-storage-instead-of-original-payload | raw bytes 改用存储表示 | 原展开独立字节 equality 及对应 raw SHA equality |

`git diff --check`、private API 检查（原 7 个 allowlist uses）PASS；33 个反证目标静态检查、冻结文件字节/聚合 SHA 检查 PASS。JEV 决策调用返回 `MCP tool call requires approval, but approval policy is never`，没有获得 JEV 判断，也没有以本地分析冒充模型复核。

### 6.5 prepared 交付与主会话复验

`prepared/b2b-fix2/` 是从 **HEAD 09ac24eb** 出发的增量，无需重放旧 prepared/b2b 或 fix1：

1. `01-lossless-budget`：紧凑 envelope、展开兼容、原 SHA、运行中预算。
2. `02-background-validation`：Store 等待后台 SHA/JSON 和取消重封装。
3. `03-regression-tests`：完整高速替身、损坏/复算/预算、生产计时工厂、main actor/取消测试。
4. `04-handoff`：追加本节。

含各组 patch/message、all.patch、manifest（基线/分支/最终与基线文件 SHA/产物 SHA）、commit-prepared.py、static-checks.json、prepared-verification.json、冻结/反证证据、原 28 条快照、最终 33 条和定向清单快照。`--check-only` 用私有 index 核对 HEAD、分支、文件/产物 SHA 和补丁可应用性；不写真实 .git。`--validated` 仅供主会话完成规定复验后按四组提交，沙箱未执行提交。

主会话命令（不跑真实负载）：

```zsh
cd ~/Developer/sc-worktrees/r2-bench-v11
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-bench-v11/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(cat ~/Developer/.sc-build/r2-bench-v11/prepared/b2b-fix2/targeted-filter.txt)"
python3 ~/Developer/.sc-build/r2-bench-v11/prepared/b2b-fix2/commit-prepared.py --check-only
```

在沙箱外确认上述五个权限断言恢复后，按既有反证脚本优先执行新增 5 条，再复验全部 33 条；红必须为上述断言、编译/基础绿失败不算杀死。全量仍由主会话执行。本轮只交付代码、测试及证据，不产生实机参考值；既有 helper 实测时间戳不可得时能效 unavailable、ANE 阶段 2、AV1 夹具缺失和 B5/B6 实测边界保持有效。
