# 跑分功能重设计计划（供 Opus 5.5 执行，gpt-6.1-sol 协助）

版本：2026-10-10；作者：Claude（Fable 5.1 规划会话）。执行者读完本文和第 1 节列出的文件即可接手。

## 0. 结论

现在测试版的“性能测试”是一个**只出原始测量值、没有任何分数、不能和别的 Mac 比较**的 18 项协议（MSeries v10 draft2）。它的内核质量不错（固定夹具、3 样本取中位数、A/B/C 稳定度、写入 ≤512 MB、可取消、过热中止），但用户视角缺三样东西：**一个能看懂的分数、一条能看出芯片特性的曲线、一个“我的 Mac 在 M 系列里处在什么位置”的答案**。

本计划把它重做成一套**面向 Apple Silicon 特点**的跑分：以极客湾 SOCPK 的“芯片级、固定基准、性能与能效分开、峰值与持续分开”为骨架，借安兔兔／鲁大师“总分＋分项＋设备档案＋同类对比”的呈现，用我们已经合并的系统助手 `powermetrics` 采样把**功耗与能效**真正测出来，并用一张内置的 M 系列规格表让任何一台 M1–M5 Mac 都能立即得到“理论位置”，再逐步用真实校准数据替换。

四个需要用户先拍板的问题见第 3 节；其余按本计划直接执行。

## 1. 现状（已核实，执行前再读一遍）

| 项 | 事实 | 位置 |
|---|---|---|
| 协议 | `mseries-core18-v10-draft2`：CPU 单线程 4（整数／浮点／压缩／图像，fixed-fixtures/s）、多线程 4、GPU 3（离屏图形／FP32／FP16）、内存 3（复制／Triad GB/s，指针追逐 ns）、存储 4（顺序读写 GB/s、4K QD1 随机读写 IOPS）。每项预热 1 次＋3 样本，中位数＋MAD。扩展：CPU 线程曲线（1/2/4…）、约 6 秒短持续观察；12 个扩展项标“尚未实现” | `Sources/StorageCleanerMac/Services/Benchmark/MSeries/`（`MSeriesProtocol.swift` 契约常量；`MSeriesCoreRunner.swift` 顺序；`MSeriesCPUExtensions.swift`） |
| 评分 | **无**。`reference = "unavailable-raw-only"`，`overallIndex` 恒 nil。草案 `MSeriesScoring.swift`：对参考中位数取比值的加权几何平均（单 .20／多 .20／GPU .25／内存 .20／存储 .15）×1000，要求 ≥3 次 Release、插电、常温的独立运行做参考；基准机未定 | `MSeries/MSeriesScoring.swift` |
| 旧世代 | v6 “Standard” 曾在本机 M5 Pro 做过受控校准（6000 分参照、容量有界计入、CV 门禁 5%/10%），v9 有本机参考目录；排行榜服务只认 v9，新协议服务端未部署 | `docs/benchmarks/README.md`（方法依据：安兔兔 PC、鲁大师、Geekbench 6 内部文档、SPEC CPU 2017、PCMark 10、Cinebench、极客湾）；`BenchmarkV7ReferenceCatalog.swift`；`MacBenchmarkLeaderboardService.swift` |
| 加速器实验套件 | `mac-accelerator-suite-v1`（与综合分分开，raw-only）：Metal 3D 光栅 Mtri/s、Metal 光线追踪（需 `supportsRaytracing`）、MPS FP16 矩阵 TFLOPS、**H.264 硬件编解码 MPix/s（VideoToolbox，禁止软件回退）** | `Metal3DBenchmarkKernel.swift`、`MetalRayTracingBenchmarkKernel.swift`、`GPUTensorBenchmarkKernel.swift`、`VideoMediaBenchmarkKernel.swift`、`MacAcceleratorBenchmarkService.swift` |
| 遥测 | `SoCPowerTelemetry.swift`（IOReport 能耗计数器，macOS 26/27 对第三方冻结）；`CPUPerformanceStateService.swift`（P/E 簇与 GPU 的 DVFS 频率、驻留）；**已合并 r2-energy-powermetrics**：系统助手一条常量参数的 `powermetrics` 只读采样，返回 CPU/GPU/ANE 功率与簇频率，节流 ≥2 s，仅可见时请求 | `Services/SoCPowerTelemetry.swift`、`Services/CPUPerformanceStateService.swift`、`Sources/FanControlHelper/`、`FanControlShared/PowermetricsSample.swift` |
| 硬件档案 | `system_profiler` 抽取 GPU 核心数、机型、存储型号；`MSeriesHardware` 有逻辑核数、perflevel、内存、Metal 设备名、是否 Release/翻译 | `BenchmarkV7HardwareProfile.swift`、`MSeriesProtocol.swift:69-` |
| 运行页 | 阶段条 6 段、进度按序号 /19、芯片温度表盘、CPU/GPU 负载 2 分钟曲线；**当前子项名仍按旧 v9 ID 匹配，MSeries 子项多数显示为“正在测试 CPU”**；已用时间没传进去 | `BenchmarkV7PerformancePresentation.swift:360-372,617-621`、`Views/FeatureRunningPages.swift:74` |
| 结果页 | V7 仪表盘 4 标签（性能测试／本机最佳／历史／社区榜），运行态监控混在结果页；本机最佳与历史比较依赖已不存在的 `coreScore`，永远显示“尚无可比较” | `BenchmarkV7DashboardView.swift`（1315 行） |
| 用户已确认的效果图（D70） | 起始：固定 18 项清单（4+4／3／3／4，带类别图标，无勾选框）、预计 ≤3 分钟、写入 ≤512 MB、环境预检一行。运行：大百分比、18 格刻度进度条、“正在测试 · CPU 多线程 · 压缩”、第 n/18 项＋已用时间、芯片温度、CPU/GPU 负载双线。结果：“18/18 项完成 · 整机指数待校准”，按类别分组的原始值＋单位＋稳定度＋与上次比较，扩展两行，本机历史／社区榜分段 | `~/Developer/.sc-build/r2-lightfield-r2/approved-20261009/renders/a/performance-*`、`mockups/a/performance-*.html` |
| 本机 | MacBook Pro Mac17,9，Apple M5 Pro，6P＋12E（20 核显示为 18 逻辑核？以 `hw.perflevel` 为准），48 GB | `sysctl` |
| 同类软件 | 本机装的 CleanMyMac／腾讯柠檬／Mac Sai／MacOptimizer／PureMac／Stats **都没有跑分功能**（二进制字符串 0 命中）；CleanMyMac 的“Performance”是维护任务。安兔兔没有 Mac 版（iOS 有）。鲁大师有 Mac 版（应用宝列出 10.9.6，Apple 芯片，功能：CPU／显卡／内存／磁盘跑分＋全国排名），本机未安装。开源 Vitals（GPL-3，只借鉴思路）有可选项跑分：CPU 单核/全核、内存带宽、磁盘顺序读写、Metal 计算，历史与 CSV 导出 | 本机 `strings` 检查；网络检索 |

## 2. 参照对象研究结论（设计依据）

**极客湾 SOCPK（socpk.com）**：按**芯片**而不是按机型排行；固定基准芯片（骁龙 865＝100 分）；四张榜单：综合性能、CPU 性能、GPU 性能、CPU 能效，另有 CPU／GPU 能效曲线页（横轴功耗 W、纵轴性能分）、游戏能效、续航。权重：综合＝CPU 70%＋GPU 30%（不含功耗、AI、ISP）；CPU＝单核 30%＋多核 70%；GPU＝峰值 50%＋持续 50%；CPU 能效取 3–5 W 功耗段的多核性能。近期改版：单核 SPEC、多核 Geekbench 6、GPU 3DMark。要点：**性能榜与能效榜分开；峰值与持续分开；功耗用外部功率计实测。**

**极客湾 M 系列评测方法**：SPEC2017 整数／浮点单核＋对应功耗；能效曲线用 Geekbench 5／3DMark 在不同频率点画功耗–性能曲线；关注 P 核峰值频率与多线程降频（M4 超过三线程全核降到 3.94 GHz）、被动散热机型的持续性能、省电模式下的能效。要点：**M 系列的卖点是每瓦性能和持续释放，不是峰值。**

**安兔兔**：总分＝CPU＋GPU＋MEM＋UX 四分项之和（权重未公开）；MEM 含内存带宽／延迟＋存储顺序／随机 IO；UX 为日常体验场景；呈现“总分＋分项＋设备信息＋同价位击败百分比”；明确标注分数受温度、系统模式、后台应用影响，且不同版本不可比。**鲁大师**：硬件综合得分＋处理器／显卡／内存／磁盘分项＋全国排名，计分规则随版本调整。要点：**整机总分＋设备档案＋排名的呈现方式用户熟悉；但“击败 xx%”没有服务端数据就不能做。**

**Apple Silicon 特点（设计必须覆盖）**：P/E 异构核（单核看 P 核，多核看全核与线程扩展性）；统一内存带宽（M4 120 GB/s → M4 Max 500 GB/s → M3 Ultra 800 GB/s，规格表可查）；GPU 核心数差异大（8 → 80）；M3 起硬件光线追踪与动态缓存；M1 Pro 起 ProRes 媒体引擎，所有 M 芯片有 HEVC/H.264 引擎；16 核神经网络引擎；被动散热（MacBook Air）与主动散热机型的持续性能差异；Ultra 为双晶片，多线程扩展与内存带宽都特殊；Rosetta 下运行无效；Intel Mac 不适用。

## 3. 需要用户先决定的四件事（C-B1）

| # | 问题 | 推荐 | 备选 |
|---|---|---|---|
| 1 | **分数基准**：以哪台机器为“1000 分” | **Apple M1（8 核 CPU／8 核 GPU／16 GB，2020）＝1000**，像 SOCPK 用骁龙 865；所有 M 芯片都比它强，分数直观。缺点：本机只有 M5 Pro，拿不到 M1 实测，需要第 7 阶段的外部采集或先用“暂定基准” | 以本机 M5 Pro＝1000（能立刻校准，但 M1 Air 会显示 300 多分，观感差）；或先只显示“相对上次”的变化 |
| 2 | **综合分的构成** | 做两个分：**芯片性能分**（SOCPK 口径：CPU 70%＝单核 30／多核 70；GPU 30%＝峰值 50／持续 50；不含能效）和**整机分**（安兔兔口径：芯片性能分＋内存＋存储，几何加权），能效单独一张“能效分／每瓦性能”不计入 | 只做一个整机分 |
| 3 | **持续性能测试时长** | 结果态默认跑 **3 分钟**持续段（CPU 全核＋GPU 各 90 秒），另给一个可选的“10 分钟压力”模式单独入口（Air 用户看降频曲线） | 只保留现有 6 秒短持续 |
| 4 | **可选扩展项是否纳入分数** | 媒体引擎（HEVC/H.264/ProRes 编解码）、神经网络引擎（Core ML 固定模型）、光线追踪作为**独立展示项**，不计入芯片分（SOCPK 也不计 AI/ISP）；不支持的芯片显示“此芯片无此单元”而不是 0 分 | 全部计入 |

另外一条沿用既有约束：**社区榜在新协议服务端部署前不显示排名和“击败 xx%”**，只显示“本机历史”和“规格表理论位置”。匿名上传功能保留开关但默认关闭（需用户另行授权联网）。

## 4. 目标设计

### 4.1 测试协议 v11（`mseries-core-v11`）

在 v10 的 18 项 Core 之上，**不改已有内核的夹具与算法**（保证历史可比），新增两类测量，并把扩展项真正实现：

| 组 | 项目 | 说明 | 用途 |
|---|---|---|---|
| Core（沿用 18 项） | 同 v10 | 不动 | 芯片分与整机分的基础 |
| 能效曲线（新） | CPU：1 线程、P 核数、全核三档各跑 10 秒固定负载；同时由系统助手每 2 秒采 `powermetrics` CPU 功率与簇频率 | 得到三点“性能–功耗”曲线、每瓦性能、实际运行频率；助手不可用时只记性能、能效标“需要系统助手” | 能效分、曲线图 |
| | GPU：峰值 30 秒 Metal 3D 光栅＋GPU 功率 | 每瓦性能 | 能效分、曲线图 |
| 持续性能（新） | CPU 全核与 GPU 各 90 秒循环（默认），逐 5 秒记录吞吐与温度、功率；输出持续/峰值比（降频比） | GPU 持续分（50%）；Air 的降频曲线 | 芯片分、持续曲线 |
| 可选扩展（独立展示） | 媒体引擎：H.264/HEVC 硬件编解码 MPix/s（已有内核）、ProRes（M1 Pro 及以上，`VTIsHardwareDecodeSupported`）；光线追踪 Mray/s（`supportsRaytracing`）；神经网络引擎：Core ML 固定小模型（打包进 Resources，`computeUnits = .cpuAndNeuralEngine`，与 `.cpuOnly` 对比得加速比） | 不支持即“无此单元”，不计分 | 芯片档案 |
| 环境 | 电源、低电量、热状态、省电模式、是否有其他重负载、风扇转速（有传感器时）、机型是否无风扇 | 预检与结果标注 | 可比性门禁 |

统计沿用：预热 1＋3 样本、中位数＋MAD、A/B/C 稳定度；CV 门禁沿用 v6 的 5%/10%；超限不出分只出原始值。总时长目标：Core ≤3 分钟＋能效 1 分钟＋持续 3 分钟 ≈ 7 分钟；起始页写清；可随时取消（保存阶段除外）。

### 4.2 评分

- **参考集**：`reference-v11`，每个 Core 项、能效点、持续比都有参考中位数；来源必须是 Release 构建、插电、常温、独立 ≥3 次的受控采集（沿用 `MSeriesScoring.calibrate` 的门槛与 `docs/benchmarks/README.md` 的采集流程）。
- **分项分**＝1000 × 本机值/参考值（指针追逐取倒数）。
- **CPU 分**＝几何加权（单核 0.3、多核 0.7）；**GPU 分**＝几何加权（峰值 0.5、持续 0.5）；**芯片性能分**＝几何加权（CPU 0.7、GPU 0.3）；**整机分**＝几何加权（芯片 0.55、内存 0.20、存储 0.25），内存／存储不再掺容量（v6 的容量有界公式废弃，容量只在档案里显示）。
- **能效分**＝全核能效点的每瓦性能 ÷ 参考每瓦性能 × 1000；无功率数据时不显示。
- **可比性标签**：每个分数带“可比 / 受限（热状态非常温、电池供电、省电模式、后台负载高）/ 不可比（CV 超限、Rosetta、Debug）”；受限分数灰显并说明原因。
- **基准未就绪时的显示**：在参考集到位前显示“暂定（相对 M5 Pro 参考机）”或“待校准”，绝不编造。决定 1 选 M1 基准但暂无 M1 数据时：先发布“暂定基准＝本机 M5 Pro”，分数前缀“暂定”，参考集换成 M1 后自动重算历史（原始值都在）。

### 4.3 M 系列适配

- **内置规格表** `AppleSiliconCatalog.json`：M1／M1 Pro／Max／Ultra、M2 系列、M3 系列、M4 系列、M5 系列（本机可验证 M5 Pro），字段：发布年、制程、P/E 核数、GPU 核数（含可选配置）、内存带宽 GB/s、神经网络引擎 TOPS、媒体引擎能力（ProRes／AV1 解码）、是否支持硬件光追、常见机型与散热方式（主动／被动）。每条写来源（Apple 新闻稿／技术规格页）；**sol 起草，Opus 逐条核对来源后才能入库**；未核实的字段留空，不猜。
- **识别**：`machdep.cpu.brand_string`＋`hw.perflevel0/1.physicalcpu`＋Metal 设备名＋`system_profiler` GPU 核数，匹配到规格表条目；匹配不到（未来芯片）走“未知 Apple 芯片”分支：仍能跑、仍出原始值与暂定分，档案显示“规格未知”。Intel／Rosetta：起始页直接说明不支持，不出分。
- **门控**：光追（M3+）、ProRes（M1 Pro+）、AV1 解码（M3+）、动态缓存等按规格表与运行时查询双重判断；Ultra 的双晶片在多线程项记录线程扩展曲线；无风扇机型把“持续性能”放到结果摘要第一行。
- **测试矩阵**：本机只有 M5 Pro。其余靠：①规格表驱动的夹具（每个家族一套假数据，验证 UI 与门控）；②用户另有 M4 Mac mini 时做一次真实跨机验证（阶段 7）；③留出匿名上传接口以后收集。

### 4.4 界面（遵守 D67/D69/D70 光场规范，用 B2 共用组件）

- **起始页**：按已确认效果图；把“测试内容”从 18 项改为“18 项核心 ＋ 能效曲线 ＋ 持续性能（3 分钟）”三组，并显示本机芯片档案一行（“Apple M5 Pro · 6P+12E · GPU 20 核 · 48 GB · 主动散热”）；预检一行加“系统助手：可用／不可用（能效将不显示）”。
- **运行页**：按已确认效果图；修复子项名映射（MSeries ID → 中文）；进度按阶段加权时间而不是序号；实时曲线改成**功率（W）＋频率（GHz）＋温度**三条（数据来自助手采样与 DVFS 服务），“每瓦性能”实时数字。
- **结果页**（结果态 878 宽）：摘要区插画＋**芯片性能分**大数字（或“待校准”）＋右侧整机分、能效分；第二行四条横向数据条（CPU 单核／多核、GPU 峰值／持续）带与参考的比值；**能效曲线图**（LightfieldTrendChart 多线：本机三点曲线 vs 参考机曲线，横轴 W）；**持续性能曲线**（90 秒吞吐与温度）；“芯片档案”卡：规格表字段＋同代 base/Pro/Max/Ultra 的理论位置（横向条，按核数与带宽，不是实测）；18 项原始值表（保留现有分组、单位、稳定度、与上次比较）；可选扩展项列表（无此单元灰显）；本机历史（按时间，同协议可比）；社区榜分段显示“服务端未上线”。全程无卡片框、无磨砂，颜色用令牌。
- **文案**：所有“分”旁边有一句口径（“相对 Apple M1＝1000”或“暂定”），不出现“击败 xx%”。

## 5. 执行阶段与分工

执行者：Opus 5.5 主会话负责决策落地、构建、测试、反证、复核、合并、实机采集；gpt-6.1-sol 经 Codex 承担起草与编码（Codex 现在可在沙箱内编译与跑定向测试：`swift build --disable-sandbox -Xswiftc -disable-sandbox` 并把 `~/.cache/clang` 加为可写根，见记忆文件；全量与反证仍由主会话跑）。所有 Codex 调用用 `~/Developer/.sc-build/_prompts/codex-run.sh`（看门狗）或 `codex-resume.sh`（固定 `-m openai/gpt-6.1-sol`），同时最多两个会话。

| 阶段 | 内容 | 谁 | 产出／验收 |
|---|---|---|---|
| B0 决策 | 向用户提第 3 节四个问题，写入 DECISIONS（D72） | Opus | DECISIONS 条目 |
| B1 协议与评分规范 | 写 `docs/2.0.0/BENCHMARK-V11-SPEC.md`：测量项、夹具、时长、统计、门禁、评分公式、可比性标签、规格表字段与来源要求；同时起草 `AppleSiliconCatalog.json` | sol 起草，Opus 核对每个规格字段来源 | 规范评审通过；规格表每行有来源 URL |
| B2 内核与编排 | 能效曲线编排（固定负载×三线程档＋助手功率采样对齐时间戳）、持续性能循环（吞吐／温度／功率逐 5 秒）、GPU 持续、ProRes／AV1／光追门控接入加速器套件、Core ML 固定模型（可行性验证先行：模型体积 ≤2 MB、编译进包、ANE 实际分配可由 `MLComputePlan` 或耗时对比证明；不可行则记为“阶段 2”）、运行页子项名映射与加权进度 | sol 编码，Opus 构建与定向测试 | 单测：编排顺序、取消、超时、功率缺失降级、门控矩阵；反证全红 |
| B3 评分与参考 | `MSeriesScoringV11`（分项／CPU／GPU／芯片／整机／能效、可比性标签）；`reference-v11` 数据结构与“暂定基准”机制；历史自动重算 | sol 编码，Opus 验证 | 单测用合成参考集验证公式、单调性、越界拒绝；Release 隔离 |
| B4 界面 | 按 4.4 用光场组件实现三态；夹具覆盖 M1 Air（被动散热）、M2 Pro、M3 Max（有光追）、M4、M5 Pro、未知芯片、助手不可用、Rosetta 七种；七尺寸矩阵 | sol 出 HTML 效果图（沿用 `approved-20261009` 的模板）→ 用户确认（C-B2）→ sol 编码 → Opus 截图对照 | 几何契约、AX、源码守卫、Release 隔离；效果图并排对照 |
| B5 受控校准采集 | 在本机 M5 Pro 做 Release 受控采集（沿用 `docs/benchmarks/README.md` 流程：交流电、常温、两段 session 各 ≥4 run、冷却 10 分钟、CV 门禁），生成 `reference-v11` 暂定基准；写入 `docs/benchmarks/` 带 SHA-256 | Opus 实机操作（D6 已授权跑分一次；多次 run 前再向用户确认时间窗，约 1 小时高负载） | 聚合报告、冻结字节哈希 |
| B6 真实运行验收 | 安装测试版后在本机跑一次完整流程（起始→运行→结果），核对：时长、取消、能效曲线有数据、持续曲线、档案识别、历史可比、分数口径文案；用户另有 M4 Mac mini 则跑一次做跨机对照 | Opus（LCU 只读截图） | 《跑分实测报告》 |
| B7 文档与门禁 | `docs/FEATURES.md` 跑分一节；BOARD；完整门禁；安装前问用户 | Opus | 门禁全绿 |

预计：B1 1 天；B2 2–3 天；B3 1 天；B4 2 天（含效果图确认）；B5 半天实机；B6 半天；B7 半天。

## 6. 验收标准

1. 任意 M1–M5 Mac：起始页显示正确芯片档案；不支持的单元显示“无此单元”而不是 0 或崩溃；Intel／Rosetta 明确拒绝。
2. 结果页：18 项原始值全部保留并可与上次比较；芯片分、整机分、能效分带口径文案；可比性标签正确（电池供电／过热／省电模式各一个夹具）；无参考集时显示“待校准”，绝不出编造分数。
3. 能效曲线：助手可用时至少三点、单位 W 与分；不可用时整块隐藏并给“需要系统助手”说明与跳转。
4. 持续性能：90 秒曲线、降频比；被动散热机型摘要第一行提示。
5. 时长：默认流程 ≤8 分钟；写入 ≤512 MB；取消 ≤2 秒生效；不改电源模式、不结束其他进程。
6. 评分公式由单一常量表定义并被测试锁定；参考集带版本与哈希；历史重算幂等。
7. UI 符合 D67 骨架（0.5 pt）、七尺寸无溢出、日夜两套、减少动态效果即时；无卡片／磨砂／装饰图标。
8. 规格表每一行有来源；未核实字段为空。
9. 社区榜不显示排名与百分比，直到服务端上线并另行决策。

## 7. 不做的事（沿用）

- 不 push、不打 tag、不发布，不改正式版与更新源；只有一份测试版 `/Applications/测试版.app`。
- 不改电源模式、不解除充电暂停（D5）、不终止其他进程；持续测试前检查热状态，过热自动中止。
- 不读钥匙串、凭证、`.env`；不上传任何数据（匿名上传默认关闭，需另行授权）。
- 不复制 Vitals（GPL-3）或任何第三方跑分的代码与夹具；SPEC／Geekbench／3DMark 只借鉴口径，不使用其负载。
- 不为通过检查放宽 CV 门禁或删断言；旧协议历史只读兼容，不混入新榜。
- 规格表不填估算值；基准未就绪时不显示绝对分。

## 8. 参考资料

- SOCPK 榜单口径与权重：[SOCPK 综合性能排行](https://www.socpk.com/allperf/?brand=all)、[极客湾 SOCPK 芯片榜怎么看](https://warpnav.com/sites/socpk)、[SOCPK 镜像（页面结构）](https://kqakqakqa.github.io/socpk/)、[SOCPK 全面更新讨论](https://disp.cc/ptt/MobileComm/1ge2aCYz)
- 极客湾 M4 测评方法与数据：[M4 测评汇总](https://www.bilibili.com/read/cv34788559/)、[MacBook Pro 14 2024 评测](https://news.qq.com/rain/a/20250402A06PWF00)、[M4 性能分析](https://blog.csdn.net/weixin_41496173/article/details/139162593)
- 安兔兔构成与呈现：[AnTuTu Benchmark : Explained](https://community.iqoo.com/in/thread/10353)、[AnTuTu 8 说明](https://www.apkmirror.com/?p=862378)
- 鲁大师 Mac 版：[应用宝条目](https://sj.qq.com/appdetail/com.ludashi.benchmark)、[Mac 版下载页](https://m.downza.cn/mac/10412577.html)
- 项目既有方法依据：`docs/benchmarks/README.md`（安兔兔 PC、鲁大师、Geekbench 6 internals、SPEC CPU 2017、PCMark 10、Cinebench、Blender、极客湾）
- Vitals（思路参考，GPL-3）：`~/Developer/.sc-build/r2-lightfield-r2/inputs/competitors/vitals/NOTES.md`

## 9. 执行时的注意

- Claude 子代理周额度 2026-10-13 21:00（悉尼）重置；之前能用 Codex 做编码和沙箱内编译，主会话做全量、反证与实机。
- B5 的受控采集需要机器空闲约 1 小时且插电常温，开始前和用户约时间。
- 与光场二期的 B3（登录项／内存／能耗／性能测试页）有重叠：性能测试页的 UI 由本计划 B4 负责，光场 B3 不再单独改性能测试页。
