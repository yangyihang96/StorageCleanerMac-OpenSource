# r2-bench-v11 · ui 交接

日期：2026-10-10。worktree `/Users/developer/Developer/sc-worktrees/r2-bench-v11`，分支 `task/r2-bench-v11`，基线 `6e60469b1e33c1a6a7e93b3915c90b4091ecad26`。开始时分支、HEAD 和干净工作区已读回。只做本批 UI、展示适配及读取既有测量证据；没有运行真实跑分负载、安装、提交、push 或社区上传。

## 标准与依赖

已读 `_prompts/common.md`、`codex-build-common.md`、`lf2-pages-common.md`，以及 RULES、BOARD 相关条目、D5/D48/D55/D60/D67/D69/D70③/D72、BENCHMARK-V11-SPEC 第 9/11 节。构建许可按较新的 codex-build-common；`.git` 仍只读，交付 prepared 补丁。

视觉依据只取本轮用户确认的 `r2-bench-v11/mockups/approved-20261010/`：起始、运行、结果、暂定结果、无助手结果五个 HTML 及十张日夜 PNG，逐页查看；HTML 用 `?theme=night|day&static=1`，不把演示数字当生产值。输入 SHA 见 scratch `evidence/ui-approved-inputs.json`。原 10-09 效果图只作为 B2 依赖背景，不替代本轮视觉标准。

基线尚无 B2 公共组件。本批从开发仓固定提交 `5b07771309f7b6cae027eca60405e95e352a9d51` 移植四个组件/布局/图形文件、70 项图标枚举、Debug gallery、组件测试和四类跑分图标（56/84 两档，共八张 PNG）。未修改上游。PNG 保持原字节，放入基线 `GeneratedArtLibrary` 查找的 `Resources/Art/`，两个打包脚本一并复制。完整来源、blob、导入和最终 SHA、适配理由见 `prepared/ui/b2-import-provenance.json`；未引入另一个组件体系。

## 生产接线和页面行为

- Workspace 的“开始测试”调用既有 `MacBenchmarkStore.startV11Benchmark(mode:accelerators:)`。重新测试先回到可配置起始页，再启动；压力与加速独立，ANE 灰显“阶段 2”。芯片档案只用实际硬件识别和同版本/同 SHA 目录；缺失为“未读取”。预检显示交流电、低功耗、热状态、背景负载与助手可用性，时长取 v11 plan 和所选加速项 deadline，写入预算沿用 512 MB。压力模式沿用 B2b 独立 CPU 300 s＋GPU 300 s，不冒称标准测量后附加压力；压力不计综合分。
- 运行页使用冻结预算进度（标准 460 权重单位，所选扩展在开始前加入），保存成功前封顶 99%，不会把 Core 18 项结束当总进度完成。Core 格子独立，进入扩展/保存为 18/18，停止时保留已完成数；压力模式不假报 Core 已测。中文名取既有 ID 映射并补英文显示，不显示第 19/18 项。
- W、GHz、°C 三条曲线独立尺度。现值要求最近 6 s，历史超 60 s 留缺口，功率缺失不填 0。CPU 用性能簇频率，GPU 阶段用 GPU 频率/功率。每瓦性能从 runner **现有五秒预算检查边界**读取已完成 batch 与已采样 helper 区间，发布到 bridge/store 的只读属性；没有新增采样器、内核调用、调度时间点或持久化字段。同会话/同阶段且不超过 10 s 才展示，CPU 与 GPU 单位分开。
- 结果由 v11 envelope/core 原始记录、既有评分结果与参考状态适配。大芯片分、整机分、能效分各带口径；final 是相对 Apple M1＝1000，provisional 每个分数前有“暂定”及实际暂定基准说明，unavailable 为“待校准”。本批没有启用合成参考集；生产 runner 尚无可用受控参考时正确保持待校准。
- 四分项比值条有参考 1× 标记；无参考留空并说明待校准。英文缺失文案占完整比值列，避免挤压。CPU 三个实测能效点按真实 W 横坐标，纵轴为原始固定负载/秒；GPU 使用独立墙钟重叠区间和百万三角形/焦，只有一个真实点时不插值成参考曲线。展示前重建功率重叠证据，不能仅信任存档里一个 `helperMeasured` 标志。无有效区间显示“需要系统助手”和两个去设置入口，能效不补 0。
- CPU/GPU 持续性能使用真实五秒窗口，吞吐与温度独立双轴，保持率直接取记录并标明末 30 s/首 10 s 中位数。芯片档案、同代 CPU/GPU/带宽各自按规格画条，标“规格位置，非实测”，附目录来源，缺值和未核实状态保留。
- 18 项原始表按 4+4/3/3/4 分组，可展开，单位中文化，显示中位数、稳定度及同 Core 契约的上次比较。指针追逐降低为改善，其余提高为改善；稳定度不称置信度，超过 CV 门槛注明不计分。非常大数值以科学计数法显示，AX 包含完整显示值与单位，原始精度留在 JSON，不溢出列。
- 加速单元独立不计分，“无此单元”“未知”“当前不可用”分开；记录未测不造值。历史综合分只在同 v11 协议、契约、参考下比较，旧记录仍可打开，兼容 Core 可逐项比较；v10/v9 生产路由保留原 Dashboard。社区显示“暂不可提交（服务端未上线）”和匿名上传关闭，没有排名或“击败 xx%”。导出复用已保存原始 JSON，只有用户点击并选择保存位置才写文件。

B2 最小扩展均为默认兼容：分数口径/小“暂定”前缀、固定摘要分数列、紧凑导航文字；TrendChart 可选非均匀横坐标、真实点、第二温度轴与单位标注，悬停/拖动也按真实横坐标选择。ResultLayout 在短窗把摘要纳入滚动，只有下方至少 96 pt 详情空间时固定摘要。标题、内容、主按钮、状态行继续使用共用骨架；没有新增卡片、Material 或装饰 SF 图标。

## 测试、修复和断言依据

最终结果及日志索引见 scratch `evidence/ui-static-checks.json` 和 prepared 副本。最后编译 `logs/ui-build-final.log`：成功，7.80 s。原生测试窗口只是内存合成值的 `NSHostingView`；没有创建跑分 Store/provider、执行真实负载或写历史。

按每个方法最后一次实际运行汇总（并非一次完整测试套件）：**19 类、214 个不同测试方法，206 通过，8 个受沙箱权限阻塞**。新增本批页面/读取/原生类 34 项全部通过。

| 类别 | 测试数 | 最后结果 |
|---|---:|---|
| MSeriesV11PagePresentationTests | 21 | 通过 |
| MSeriesV11LiveObservationTests | 7 | 通过 |
| MSeriesV11NativeLayoutTests | 6 | 通过；原 Raw/分数/Settings/legacy 失败修正后分别复跑 |
| B2 component/geometry/import/icon/Release isolation | 46 | 通过 |
| UIConsistencyRegressionTests | 46 | 通过 |
| catalog/reference/scoring/history/presentation/runner/window/bridge | 51 | 通过；runner 仅合成驱动，不运行系统内核 |
| FeatureLightfieldContractTests | 16 | 10 通过、6 受家目录夹具权限阻塞 |
| TestPreferenceHygieneTests | 21 | 19 通过、2 受 CFPreferences 阻塞（3 个断言） |

原生覆盖三态 × 七尺寸 × 日夜 × 中英；结果四参考/助手变体 × 普通/大数值，18 项值可真实滚入视口并读到数值/单位；运行值列和取消的无副作用 fixture 回调；两个系统助手入口的真实 AXButton、原生 frame 和 press 能力；旧 v9/v10 编解码及原结果子视图。最后分数矩阵复跑 `ui-native-summary-final-tests.log` 为 1 项/0 失败，134.16 s；Settings+legacy 的修复过程见 `ui-native-settings-legacy-tests.log`，legacy 最后单独复跑 `ui-native-legacy-final-tests.log` 为 1 项/0 失败。不要把 AXPress selector 能力当成实际 Settings 窗口导航验收。

最后纯数据/来源守卫定向 `ui-data-final-tests.log`：173 项，171 个方法通过、2 个方法权限受阻，共 3 个断言失败。B2/既有光场/Native 的整组运行 `ui-native-final-tests.log` 保留原始失败过程，最终方法状态由对应修正后定向日志覆盖，未覆写为成功日志。失败方法清单和日志 SHA 在 evidence 中：

- `FeatureLightfieldContractTests`：`testLongUninstallListLaysOutOnlyVisibleRows`、`testProductionCleanupGroupSelectionSpeaksItsState`、`testProductionPilotsKeepNativeSkeletonAcrossThreeStatesSevenSizesAndTwoSchemes`、`testProductionResultPagesEndAbovePrimaryWithoutHalfRowsAndShowHistory`、`testProductionUninstallRowSelectionNeverOpensPreview`、`testResultLongListFadesPartialRowsAndLastItemIsReachable`。均在 `TestFileSystem.swift:60` 创建 `~/.storage-cleaner-scan-store-<UUID>/home` 时报 `NSPOSIXErrorDomain Code=1 Operation not permitted`；未修改夹具位置、放宽路径规则或跳过测试。
- `TestPreferenceHygieneTests`：`testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`（同步与 plist 存在两个断言）、`testTemporarySuiteCanBeReopenedOnAWorkerThread`（同步一个断言）。日志含临时 `defaults.plist` 的 `sandbox_extension_issue_file ... Operation not permitted`，未改偏好卫生守卫。

`git diff --check`、29 个新增文件的 no-index 空白检查、两个打包脚本 bash 语法、private API 守卫（7 处已在 allowlist）通过。Release 隔离是现有源码守卫检查，不代表构建了 Release 安装包。

红/绿记录保留：`ui-data-tests-red.log`、`ui-native-tests-red.log`。首次原生矩阵暴露英文待校准过窄，现改为完整比值列；数据测试暴露 GPU peak 被 CPU 专用对齐规则拒绝，现将 CPU 10 s 对齐门槛只用于 CPU，GPU 继续按自身完整 raw 区间重建验证，未放松 CPU 门槛。增加停止/保存 Core 保留和短窗可滚动空间回归。原 Raw AX 读取误取整窗文本，测试改为命中当前滚入行的实际 AX 节点并验证原生 frame/数值/单位；没有用期望字符串充当读回。无助手摘要的设置按钮通过独立 AX contain 分组暴露真实按钮并左对齐到能效列；普通数值和骨架位置未改。

旧断言调整逐条依据：

1. `FeatureLightfieldContractTests` 非试点模块计数 11→10，并显式检查 performance 使用共用页面；原三个试点不变，D70③/D72 批准性能页进入完整三态。
2. `UIConsistencyRegressionTests` 只给 B2 数值、长路径及本批已标记数值站点有限缩放预算；全文件实际站点数必须等于标记数，未允许其他页面任意缩字。依据 D69 数字不得出圆环/列和七尺寸要求。
3. B2 import source 守卫保留默认摘要间隔 34 pt，新增 fixed-score-columns 时显式 24 pt 的条件断言；分数列依据 D72 和已确认结果图，默认 B2 行为不变。
4. B2 chart 布局说明追加精确的 96/42/62 pt 规格句，满足未改变的组件文档断言。
5. Legacy 原生 AX 断言读取原视图组合后的完整 value（例“相对强项, CPU, 接近 V7 基准”），不把只有标题的期望误当 AX 实际值。仍要求真实 label、value 和 frame；v10 标题发现器在原视图顶部 80 pt、左侧 512 pt 每 4 pt 命中，避免超宽窗口的稀疏 grid 错过左侧文本。

原 47 条反证 JSON 已完整备份到 `prepared/ui/counterexamples-original.json`，逐对象比对前缀完全相同；追加 13 条，总计 60 条。新增覆盖每分暂定前缀、助手缺失补零、指针比较方向、未保存 100%、跨参考/跨 Core 契约比较、原始功率证明被绕过、GPU/CPU 对齐混淆、保存 Core 重置、短窗详情被挤光、功率横坐标悬停错误及跨阶段 live 值污染及摘要设置按钮 AX 被合并吞掉。60 条 before 字符串的次数与 filter 方法存在性全部核验；**没有执行 mutation runner**，不能称反证已杀死。

## 主会话验证命令与离屏重拍

定向类清单 `prepared/ui/targeted-filter.txt`（19 类）及 `targeted-classes.txt`（保留批次原清单并追加）已准备。使用独立 scratch，不改变应用真实偏好：

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-bench-v11/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(cat /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui/targeted-filter.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui/commit-prepared.py --check-only
```

主会话在沙箱外复跑家目录夹具和 CFPreferences 受阻的既有测试，执行已准备反证并审查实际结果。`script/verify.sh` 全门禁本会话未执行（本批禁止全量），构建/定向成功不等于全门禁、安装或 C-UI2 验收。不要为了截图启动真实性能负载。

沿用 Debug 离屏管线：`--debug-mini-window-demo-data --debug-feature-page=performance:<landing|running|result> --capture-main-window-directory=<独立输出目录> --debug-mini-window-appearance=<light|dark>`；完整三态矩阵可用 `--capture-feature-templates`。语言用进程参数 `-app.language zhHans` 或 `-app.language english`，不写真实偏好。新增选择参数仅 DEBUG：

- `--debug-benchmark-v11-variant=standard|provisional|nohelper|unavailable|partial|legacy-v10|legacy-v9`。
- `--debug-benchmark-v11-section=0..5`：概览、档案、原始值、加速单元、历史、社区。
- `--debug-benchmark-v11-stage=core|extension|saving|stopping`：运行态。

必须重拍并逐图核对：

1. 用户批准五页：landing/running/standard result/provisional result/nohelper result，日夜及中英；七尺寸 820×560、1000×700、1280×763、1680×1050、2400×1350、677×390、1280×390。
2. 最短/最窄窗口的摘要滚动、两个设置入口、英文待校准、长单位及暂定前缀；尤其 677×390、1280×390、820×560。
3. 结果档案/原始值/加速/历史/社区所有滚动锚点；raw 普通和大数值、指针改善方向、未知目录/参考/功率空态。CPU/GPU 持续切换和各自温度轴、能效 W 轴 hover 也需截图和交互读回。
4. 运行 Core→扩展→保存≤99%→停止；压力/加速独立勾选与 ANE 灰显；实际 Workspace 重新测试返回起始页再启动的按钮路径，以合成依赖验证，不执行真实负载。
5. 旧 v10/v9：Debug 降级/原摘要已有 fixture；还需主会话在隔离测试环境从生产本机历史路由打开各一条，确认原版式、返回、滚动和导出边界。

离屏 PNG、真实 Beta/AppKit 最终画面、安装包中图标/目录资源、设置跳转的实际 Settings 窗口及生产助手读回均尚未在本会话验收。合成 helper fixture 证明展示/证据判定，不代替 helper-interval 的设备测量。主会话需重新核对装包资源的 Bundle.main 读取。

## 交付与未解决边界

`prepared/ui/` 四组：01 共用 B2 导入/扩展/图标打包，02 v11 页面和只读测量展示接线，03 回归测试，04 本交接；另有 all.patch、before/final/artifact SHA manifest、静态结果、来源证据及主会话提交脚本。`--check-only` 已通过分支/基线/范围、before/final/artifact SHA、私有 index 补丁可应用性与工作树反向匹配检查；真实 HEAD 和 index 的 SHA 读回均未变。报告见 `prepared/ui/prepared-verification.json`。`--validated` 仅由主会话完成门禁后运行；其固定 footer 来自 codex-build-common，不能当本会话实际模型标识证明。

保护读回：`Stores/ScanStore.swift`、`Sources/FanControlHelper/main.swift` 与基线字节一致；旧历史评分/内核/清理/卸载/充电/风扇行为不改。唯一 runner 变更是在既有五秒检查边界发布已完成 batch 的只读观察；没有更改内核、评分契约或存档结构。新增读取/转换及 MainActor 回调的实际设备开销尚未量化，本批禁止真实跑分，因此不能声称对实际吞吐影响为零。

JEV 调用被工具的审批策略 `never` 阻止，未获得可用模型标识或判断，不能声称完成 JEV 复核。两个现有子代理分工完成 B2 导入/原生布局测试和纯数据夹具测试，父会话统一编译与实际结果核验。

## ui-fix1 · 主会话全量六项失败回修（2026-10-10）

本轮开始时核对原 UI 45 个变更文件均与 `prepared/ui/manifest.json` 的 SHA 一致，HEAD 仍为 `6e60469b`。主会话反馈定向 329/0、反证 60/60；全量 4578 项出现六项失败，原始诊断已从 `logs/main-final-1954/full.log` 的 `error: -[` 逐条读回。此处主会话结果是外部验证反馈，不冒称由本沙箱执行。

### 逐项判断与守护迁移

1. **ComputerHealthDashboardTests.testHealthAndPerformanceUseIndependentWorkspaces**：旧守卫要求 v10 `startOfficialBenchmark` 字符串。D72 与 v11 SPEC 第 9/11 节要求新协议入口；改为精确要求 `startV11Benchmark(mode: selection.mode, accelerators: selection.units)`，新增禁止旧入口、要求 v11 运行/结果路由及禁止健康页触发 v11 的断言。原健康独立工作区、旧历史 Dashboard、加载历史和禁止混合页面等断言全部保留。
2. **FeatureTemplateContractTests.testBenchmarkDemoUsesTheProductionMonitorAndStages**：原生日志实际已读到 v11 三列、独立 TrendChart 和 52 pt 主按钮，缺失的是被替代的单轴 monitor.dial 与 40 pt runtime.cancel 探针。D69/D72 及批准的 `performance-running`（`v11.js` 的 running 函数）要求 W/GHz/°C 三条独立轴、加权/18 Core 两组进度。本轮只在生产 RunningPage 增加 DEBUG 共用布局探针，未调整布局或组件。迁移后仍要求 monitor 高度 **>100**；对三条曲线和各现值逐一要求非零 frame、包含于 monitor、曲线互不重叠；要求中文阶段、两条进度均非零；取消严格 **52 pt ±0.5** 且在视口内，并检查真实 AXButton 的 press 能力。没有放宽几何容差。
   初次沙箱运行在旧通用 fixture 创建不相关的 ScanStore 家目录时阻塞；该测试现在先核验 FeaturePresentationDemo 的性能路由，然后以同一个 `PerformanceBenchmarkV11DemoPage` 值夹具及 AdaptivePageViewport 承载生产页，保留对应 module 环境。v11 路由本来没有 ScanStore/provider/写盘依赖。没有改 TestFileSystem、家目录路径守卫或产品安全检查。其他模块测试仍按原夹具运行。
3. **GeneratedArtTests.testEveryPictureDecodesWithAlphaAtItsExportedSizeWithinTheSizeBudget**：原测试禁止所有 PNG，合法取代依据为 D70③批准四组测试图标、B2 PNG 原始输出与 D72 起始页。现在精确允许 **cpu/gpu/memory/storage × 56/84 = 8** 个文件；任何其他 PNG 仍失败。八张均实际解码、要求精确像素及 alpha，并计入原 **1,000,000 bytes** 总预算。40 张 HEIC 的原解码、尺寸、透明通道、数量、README 断言保留。实际 HEIC 818,948 bytes＋PNG 55,432 bytes＝874,380 bytes；未提高预算。
4. **GeneratedArtTests.testPicturesAreDecorativeAndOnlyOnTheAgreedSurfaces**：旧 header systemImage 被 D67/D72 的共用光场中央插画替代。新守卫精确要求 `.performance/.landing` 的 FeatureLightfieldPage、performance→benchmark 映射、共用 Artwork 模块解析与 decorative/accessibilityHidden 行为。原 PageHero 不放插画、sidebar 20 pt、轨道运动可见性、HEIC 两脚本打包等断言保留；新增两个脚本精确包含批准 PNG glob 的断言。
5. **OfficialBenchmarkPlanTests.testPerformanceWorkspaceExposesOnlyTheOfficialFlow**：旧入口合法迁移为 v11 精确 mode/accelerators 调用并禁止旧入口；要求起始/运行/结果三路由及 `result.mSeriesV11 != nil` 分流。旧 Dashboard 的历史、导出、删除、监控和社区原协议守卫全部保留，保护旧 v9/v10 打开路径。新版社区关闭、无排名、分数口径等继续由原 v11 定向类验证。

前五项均属于新设计替代的旧约定，未发现需要恢复旧视觉布局的证据。迁移只增加生产 RunningPage 的只读 DEBUG 探针和修改四个测试文件；不重造组件，不改评分、内核、原始历史或已批准图片。新的五个失败方法最终均通过。

### 内存项：仅诊断，不改

第六项保持 `MemoryHeadroomSysctlTests` 与 `SystemMemoryProbe` 的 HEAD 字节不变，三次夹逼/零容差断言不变。不能仅以三次 (70,69,70) 认定工具截断、sysctl 四舍五入，也不能因其他分支通过就判定无关。

本机 man 未描述 `-Q` 的取整语义；本机工具反汇编显示 `_memorystatus_get_level` 返回整数直接用 `%d` 打印。Apple XNU 公开源码快照中 sysctl 和该 syscall 都读取同一个 `memorystatus_level` 整数，没有两套取整步骤，因此目前证据不支持取整差异。公开快照未精确匹配当前 `xnu-13432.40.177.0.3~56`；沙箱拒绝读取 sysctl，不能在此完成配对实测。非原子采样的瞬时变化仍是候选解释，未证明根因，不修判断方式。

完整证据、地址、源码行、版本与 SHA 在 `prepared/ui-fix1/memory-headroom-diagnosis.md`、`memory-source-provenance.json`、man/源码/反汇编快照；只读命令输出在 `logs/ui-fix1/memory-{sysctl-readonly,pressure-query}.log`。只用了 `memory_pressure -Q`，没有施加压力。本轮未将第六项算作已解决。

### 沙箱内实际验证

- 含测试编译两次成功：`logs/ui-fix1/build.log` 27.69 s；最终 `build-final.log` 8.15 s。固定 Xcode 27 Beta、`--disable-sandbox -Xswiftc -disable-sandbox` 和批次 debug scratch；未构建安装包或启动应用。
- 原定向 **33 类/329 项**：**319 通过、10 个方法因沙箱权限受阻，共 11 个断言失败**，日志 `original-targeted.log`。六个 FeatureLightfieldContract 方法、一个 HelperPowerMetricsMonitor ScanStore fixture 在 TestFileSystem:60 家目录创建时报 Code=1；BenchmarkV7HistoryPresentation 删除记录测试在 :171 `defaults.synchronize()` 失败，旁有 CFPreferences 的 sandbox_extension_issue_file；TestPreferenceHygiene 两个方法共三断言同样被偏好持久化权限阻塞。没有其他失败。v11 原生六方法全部通过（含 18 原始值、大数值摘要、七尺寸三态、两个设置入口及旧历史）。该运行后只改了不在原 33 类中的 FeatureTemplate 测试夹具，生产源码和原清单代码未再变。
- 六个失败方法所属 **五个类/58 项**：最后 **43 通过、15 个方法权限受阻**，日志 `six-failures-classes-final.log`。其中 FeatureTemplate 的性能方法通过（0.255 s），其余 13 个通用 native fixture 方法在家目录创建前被拒；MemoryHeadroom 两项在 sysctl 返回 nil 时 XCTUnwrap 失败，未跳过。健康类 17/0、GeneratedArt 5/0、OfficialPlan 9/0。初次 `six-failures-classes.log` 的 58/16 过程保留，不覆盖成绿日志。
- `git diff --check`、两个脚本 bash 语法、69 个反证锚点/方法静态核验通过。资源、Probe、ScanStore、helper main 与内存类保护 SHA 记录在 `prepared/ui-fix1/static-checks.json`。全量与 mutation runner 没有在沙箱运行。

红：主会话 full.log 的六个诊断，以及初次沙箱日志。绿：上述五个迁移方法最后实跑通过；第六项等待外部内核读回。反证：原 60 条对象逐个完全相同、每个 before 次数正确，锚点没有位移，无需更新；追加 9 条，总 **69**，分别针对丢失 v11 选择、旧历史误入 v11、三曲线重叠、总/Core 进度被移除、错误性能插画、错误 PNG 解析和两脚本遗漏图标。这里只核验目标，新增九条尚未执行，不能称 69/69 杀死。

### 替代包与主会话重验

`prepared/ui-fix1/` 保留本轮开始前 50 个文件快照及原 60 条反证。`incremental/` 三组共 6 文件，是相对该未提交工作树的增量；`full/` 四组共 49 文件，是相对原 HEAD 的完整替代包。主会话提交应替代旧 `prepared/ui/`，不要把增量和完整包叠加应用。两者由根目录 `commit-prepared.py --check-only` 核验 SHA、反向匹配，并在 scratch 的私有 index/**私有 objects** 重建相同最终 blob；真实 `.git` 不写。manifest 与 `prepared-verification.json` 记录结果。`--validated` 仅由主会话完成门禁后运行，固定 footer 不代表运行模型身份。

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-bench-v11/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(cat /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui-fix1/targeted-filter.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui-fix1/commit-prepared.py --check-only
```

合并清单为原 33 类＋新增五类，共 38 类。主会话沙箱外必须复跑这些定向、全量门禁和 69 条反证，记录 MemoryHeadroom 的三次前/工具/后读数。全量内存失败根因尚未确定，不能用本轮 UI 绿结果替它验收。

离屏重拍沿用上节完整五页/七尺寸/日夜/中英要求；fix1 优先重拍运行页的 **1084×712 内容视口（对应原窗口矩阵 1280×763）**，核对三轴、两组进度与取消；起始页 CPU/GPU/内存/存储八张图标在 2x/3x 与日夜装包解析。大数值/暂定/无助手/英文待校准短窗、Core→扩展→保存≤99%→停止和旧 v9/v10 历史打开仍需主会话真实管线截图。fix1 没有更改最终视觉，原生 frame 通过不能替代离屏像素或实际装包读回。不得为截图启动真实性能负载。

JEV 本轮调用同样被 `approval policy never` 阻止，没有取得模型标识或判断；未声称完成 JEV 复核。没有提交、安装、push 或运行真实跑分。

## ui-fix2 · 独立复核 P1/P2 回修（2026-10-10）

依据 `logs/codex-ui-review.log` 末尾“修复后合并”报告逐条处理全部两个 P1、八个 P2。开始时 HEAD/分支仍为 `6e60469b1e33c1a6a7e93b3915c90b4091ecad26` / `task/r2-bench-v11`；49 个原 UI/fix1 工作树文件逐一匹配 `prepared/ui-fix1/full/manifest.json`。先在 `prepared/ui-fix2/before/` 冻结当时字节并保存原 69 条反证，再修改；随后要改动的原 HEAD 文件也先补齐快照。此轮不提交、不改真实 `.git`，不运行真实跑分负载。

### 复核编号与处理

| 编号 | 最终处理与守护 |
| --- | --- |
| P1-1 | 新增纯展示 `ResultDisposition`：测量是否完成读取内层 envelope，保存成功必须有本机历史读回匹配；终止原因读取**外层** `BenchmarkV7Result.failure`。保存失败显示“保存失败 · 仅当前会话可查看”，字幕分别表达测量完成/部分测量与保存失败/取消/中止，并说明会话内结果的生存期。Store 原子 save 后找不到相同 record/session/raw SHA/failure 的读回记录也按保存失败处理。`MSeriesV11PersistenceTests.testThrowingMemorySaveSeparatesMeasurementCompletionFromPersistenceFailure` 使用抛错内存仓库，验证 18 项测量完成仍为外层 `.persistenceFailed`、未保存、终止说明；`testMissingReadbackCannotBePresentedAsSaved` 验证缺失读回不冒称成功。 |
| P1-2 | 移除 `.persisting/.completed` 推断 Core 18 项的分支。Store 冻结运行配置维护已知完成数，接受实际待保存 Core 有效测量数；压力模式为独立 0 项。取消守卫原先会丢弃已由 Core 返回、已 drain 的部分结果，因此在既有 run ledger 保留该返回值，结构化任务退出后取回再封装/校验/保存；不改变内核、任务 drain 或租约释放顺序。连续链合成测试 `testCoreItemEightCancellingPersistingCancelledKeepsSevenAndRecreatedWorkspace` 严格要求 running→cancelling→persisting→cancelled、全过程 Core 7、总进度不回退且 ≤99%，最终记录 7 项且 `isPersistable`。 |
| P2-1 | 三个 restricted 分数通过既有 B2 Summary/Metric/DataBar 的 status 灰显，保留数字、参考口径和暂定前缀；逐个分数展示受限原因。评分器抽出与原判定完全相同的 `evidenceLabel`，原始值比较同时检查双方单项的环境、CV、有效计时、checksum 和固定合同；受限/未知/不合格均不可比。对所选单项使用固定 Core 验证器，其他单项计时无效不连带屏蔽这一行。环境/样本/计时双方反例、灰显原因和“不相关坏行不屏蔽好行”由 `MSeriesV11EvidencePresentationTests` 覆盖；原方向/单位/缺值断言仍全部保留，补入真实 eligibility 上下文。 |
| P2-2 | `v11RunConfiguration` 在 Store 的 v11 start 入口冻结 session、mode、加速单元选择与完成数。Workspace 的 `runningPresentation` 只读它；删除本地完成数累积，不再从重建后的勾选默认值读运行模式。合成运行中销毁并重建实际 Workspace **值**，检查稳定的 state/mode/Core 数和继续增长的 elapsed；标准取消链、压力运行及其终止均验证。未启动 Workspace 的 `.task`、真实助手或负载；真实窗口卸载/重建的最终画面仍交主会话重拍。 |
| P2-3 | 新增一个 `AsyncStream.bufferingNewest(1)` 发布器：只有一个 worker、一个在途回调、一个待处理快照。五秒检查边界同步 yield 快照，读遥测、算展示值、MainActor 回调均在测量循环外执行。终止时 finish/cancel 不等待展示；Bridge 按 active session ID 拒绝旧回调并在 finish/reset 清空展示。`MSeriesV11LivePublisherTests` 人为挂起 MainActor 回调，要求合成驱动先完成 600 秒虚拟测量及两次 driver cleanup；另要求 1→100 密集发布实际只交付 [1,100]，finish 后不发布；Bridge 测试覆盖 finish/reset/旧会话污染。没有声称设备吞吐开销为零。 |
| P2-4 | `FeatureTemplateContractTests.testBenchmarkDemoUsesTheProductionMonitorAndStages` 使用 `makeFixture(.performance, .running)`，实际 hosting `FeaturePresentationDemoView` 外壳的生产分支；保留其 fail-fast status/process/cleanup/hardware 提供者。保留 monitor >100、三个轴非零/包含/不相交、双进度非零、取消 **52pt ±0.5**/视口/AX press，并补齐每个现值 width/height >0。沙箱内此旧夹具的建目录路径被拒绝，未移走夹具或删断言；需主会话沙箱外真正执行该外壳测试。 |
| P2-5 | 用 `MSeriesV11ScaleContract` 替代按文件计数的缩放预算：18 个批准站点逐一绑定**完整文件路径、唯一 site ID、具体文字表达式、最低比例与紧邻的单行 modifier**，所有扫描文件都检查，包括批准站点被整体删除的情况。原缩放下界 0.5/0.8 保留，轴新增站点下界 0.75；禁止未标记/非字面比例/移植/重复站点。新增 0.01、三行、错误 receiver、重复和额外站点的反例；原主窗口字体/controlSize 禁令仍在。 |
| P2-6 | 既有 TrendChart 轴文字取消横向 fixedSize 溢出，固定 36pt 列，以紧凑科学计数表示大值并保持单位、完整 AX 口径与 0.75 最低比例。Darwin 的科学计数大小写统一，极端负数也保持可容纳长度。`MSeriesV11CurvePresentationTests` 检查到 Double 极值的文字度量；原生测试将实际 workload workUnits 放大 10¹² 倍，重新构造匹配的功率/能效窗口和持续输入，确认真实三个 CPU 点仍可用，再经七尺寸×日夜×中英检查轴 frame、36pt 列、文字界限和点线程标签界限。没有只放大缓存总分代替曲线输入。 |
| P2-7 | 按批准 running 图，单独每瓦性能**数字 24pt 半粗体**，标签/单位 13pt；CPU 每个效率点直接标实际 resolvedWorkers 线程数；持续图复用 B2 series legend，标吞吐与温度及相应颜色。来源/字重/图例源守卫、原生点标签与实际双图例 frame 均覆盖。 |
| P2-8 | 新增纯 `SpecificationRow` 适配目录，逐 peer/SKU/字段生成 CPU、GPU、带宽行；URL 来自该 peer 的 `/cpu/<option>/totalCores`、`/skus/<index>/gpuCores`、`/skus/<index>/memoryBandwidthGBps` 精确字段，链接标签包含 peer/SKU/字段，取代只给当前芯片笼统来源。未核实/缺 URL/缺值/非法数保持未知；规格条最大值也只取已核实行。整个目录及不同字段独立 URL、冲突 SKU、无来源但有数值的合成反例由 `MSeriesV11SpecificationPresentationTests` 覆盖。保留“规格位置，非实测”，不显示排名或百分位。 |

### 定向验证与反证

完整实际结果写入 `prepared/ui-fix2/static-checks.json`（日志 SHA、方法级通过/失败、失败诊断、已测 Swift 源 SHA、保护文件 SHA）。最终源码含测试编译成功，见 `logs/ui-fix2-build-delivery.log`（11.92 s）；回修相关的八个类加原生大值/栅格边界方法：**50 项 / 0 失败**，见 `logs/ui-fix2-focused-delivery.log`。扩展定向清单保留原 38 类并加入 EvidencePresentation、LivePublisher、ScaleContract、CurvePresentation、SpecificationPresentation 五类，共 **43 类 / 407 项：381 通过、26 个方法失败，共 27 个断言**，见 `logs/ui-fix2-targeted-final.log`。

反证由原 69 条增至 **86 条**。原 69 个 ID 与测试意图全部保留，68 条 JSON 未变；仅 `ui-v11-saving-core-reset` 因移除按 persisting 推断的旧分支，等价重定位到 Store 提供的 `knownCoreCount`，仍用原 `testSavingAndCancellingKeepCoreSubprogressAndPressureRemainsIndependent` 的保存 Core **18** 断言反驳“保存时归零”。新增 17 条逐条标 `review_issue`，覆盖全部 P1-1/P1-2/P2-1…P2-8，另加强保存读回、Core drain、逐项 eligibility、单槽队列与线程点标签。86 个文本锚点均严格核对每条约定的出现次数（新增均为 **1**）、过滤类/方法确实存在；审计见 `counterexample-anchor-audit.json`。本沙箱按批次规则**未执行 mutation**，不能把锚点核对称为 86/86 反证通过；主会话仍须实际运行。

### 交付、重拍与未验证边界

交付根目录 `prepared/ui-fix2/`：`incremental/` 相对此次开始时已有 UI/fix1 工作树；`full/` 是相对 HEAD **6e60469b** 的四组完整替代包。原 `prepared/ui/`、`prepared/ui-fix1/` 不覆盖。两包分别有 all.patch、分组 patch/message、before/final/artifact SHA manifest；根 `commit-prepared.py --check-only` 同时检查两包并用 scratch 内**私有 index 和私有 objects**与真实只读 objects alternate 比对最终 blob/index，不修改真实 `.git`。主会话只选择完整替代包提交；不能把三套原/增量/完整补丁重复应用。固定 commit footer 沿用 prompts 模板，不表示本会话实际模型标识或外部模型审查。

需主会话重拍/读回（全部使用合成数据，禁止真实负载）：

1. 保存失败（内层测量完成/外层 `.persistenceFailed`）、取消 7/18、timeout/restartRequired/validationFailed 终止说明；验证未保存结果的安全文案不出现“结果保存在本机”。
2. Core 第 8 项→停止→保存≤99%→已取消的连续画面；压力模式的 Workspace 窗口卸载/重建，不受初始勾选默认值干扰。
3. restricted 三分灰显、逐项原因和不可比；provisional/无助手旧降级，以及含受限/高 CV/无效计时的上次记录比较。
4. running 每瓦数字 24pt、CPU 1/性能簇/全核点线程标签、持续吞吐/温度双图例；七尺寸、日夜、中英，特别 677×390 与 1280×390，能效和持续的大值轴及 hover。
5. 同代各 SKU 的 CPU/GPU/带宽独立来源、缺值/冲突的未知行，档案滚动和链接目标；同时从装包 Beta 检查目录资源读回。
6. 外壳三轴/双进度/52pt/AX 的原生测试、沙箱受阻旧夹具、旧 v9/v10 历史生产路由及实际 Settings 窗口；全量和 86 条 mutation 仍由主会话执行。

`ScanStore.swift`、helper main、SystemMemoryProbe、MemoryHeadroomSysctlTests 均逐字节等于 HEAD。内存 headroom 旧项仍沿用 fix1 交接“不确定则不改”的结论，不用整数容差掩盖。本轮没有安装、提交、push、正式发布或真实负载测量。JEV 仍被工具的 `requires approval` 与 approval policy `never` 阻止，未取得其模型标识或审查结果，不声称完成 JEV 判断。

扩展清单首次执行暴露 1000×700 右侧比值列 1pt 溢出（普通/大值/各参考状态均可复现）。保留原 0.5pt 断言，改为在实际内容宽度内向下取整的固定列宽并保持 24pt 间距、2/4 列断点；新增纯几何与原生边界反证，重新编译并复跑。首次失败日志保留，不作为最终通过证据。


最终定向失败逐项归档在 static-checks：21 个方法在旧通用 fixture 的家目录创建被拒（FeatureLightfield 6、FeatureTemplate 14、HelperPower 1）；3 个方法在 CFPreferences synchronize/plist/reopen 读回失败（History 1、PreferenceHygiene 2）；MemoryHeadroom 2 个方法读取内核值为 nil。保留原断言、路径、0 容差和失败日志，未跳过或视为通过。相比 fix1，新增的一个受阻方法正是 P2-4 迁回真实外壳后经过原 fixture 的运行页测试；本轮没有出现其他新的失败方法。内核 nil 本身不能证明此前 69/70 差异的根因，仍待主会话沙箱外读回。

43 类清单执行后，仅将保存失败说明改成“仅当前**应用会话**可查看”，避免误称离开页面就丢失 Store 中的未保存结果；`post-full-targeted-change.json` 记录该唯一 Swift 文件前后 SHA。此后重新编译含测试并跑上述最终 50 项；交付源 SHA 见 `tested-source-sha256.json`，完整清单当时 SHA 见 `full-targeted-source-sha256.json`。未重新执行全量或 mutation。保留首次定向暴露溢出的日志及中间修复日志。

重拍清单第 1–3 项的新保存失败、restricted 和连续取消画面需使用本轮合成测试/展示适配器注入相应状态；现有 Debug variant/stage 参数仍只覆盖前文列出的状态，不把尚无 CLI 参数的新场景写成可直接启动的场景。


最终包核验：增量 **28 文件 / 4 组**（运行与证据 7、展示 9、回归 11、交接 1），完整替代 **60 文件 / 4 组**（共用 B2 18、v11 页面与接线 22、回归 19、交接 1）。根 `commit-prepared.py --check-only` 成功：两包私有 index 的最终路径/blob 一致，完整包可应用于 HEAD，增量可对当前工作树反向匹配，所有 before/final/artifact SHA 正确，真实 HEAD/index 未变。核验命令与日志 SHA 记录于 `prepared/ui-fix2/prepared-verification.json`。

```zsh
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui-fix2/commit-prepared.py --check-only
```

主会话沙箱外先复跑根目录 `targeted-filter.txt` 的 43 类（特别是真实外壳 P2-4）、全量、86 条反证和上述重拍；确认门禁后再由主会话选择完整替代包提交。本会话未执行 `--validated`。


## ui-fix3 · fix2 复核四项 P2 回修（2026-10-11）

依据 `logs/codex-ui-fix2-review.log` 最后的“补四项 P2 后合并”结论处理。开始时 HEAD 仍为 `6e60469b1e33c1a6a7e93b3915c90b4091ecad26`，分支 `task/r2-bench-v11`；fix2 的 60 个变更文件逐一匹配完整包 manifest。先冻结当前工作树字节、原 86 条反证和 43 类清单到 `prepared/ui-fix3/`，再修改。此前主会话 `main-final-0016/targeted.log` 记录 407/0；`full.log` 记录 4598 项、原有 25 skip、0 失败；只读复核已核验原 86 个变异均由对应测试实际杀死。这是 **fix2 的外部验证**，不当作本轮新源码或新反证执行结果。

### 四项编号及处理

| 复核编号 | 实现、测试与反例 |
| --- | --- |
| fix3 P2-1 历史三分 | 摘要和历史统一从 `ScoreDisplay` 读取数字/暂定前缀、status、原因及口径；当前受限记录仍可显示，但三个历史 Metric 都保留灰显，原因逐项显示。`scoreComparable` 同时检查双方 chip/system/efficiency 三个标签。新增 `MSeriesV11HistoryScorePresentationTests` 检查当前受限记录、芯片可比但整机/能效受限、双方顺序、日夜颜色出口与中英文原因；原生新增方法实际 hosting 历史组件，检查三项数值/原因非零及原边界容差。反证删除历史 status、退回只检查 chip。 |
| fix3 P2-2 同行缩放 | 先用 `matches` 枚举每行全部 `.minimumScaleFactor` 调用，明确一行最多一个调用，再核对原 site/receiver/单行属性/最低比例。两调用即失败，第二个比例即便也是 0.5 也拒绝；不能以首个合法值遮住 overlay。新增 Swift 合成反例使用复核原样 `overlay { Text("ordinary caption").lineLimit(1).minimumScaleFactor(0.01) }`，原允许站点不改。反证包括实际运行页同一行 overlay 和移除多调用守护。 |
| fix3 P2-3 停止与保存 | Store 新增按 record/session/raw SHA 精确匹配的 `v11SaveState`，在运行开始清空。v11 保存异常保留原 BenchmarkV7Result 与 sealed envelope，另记录保存失败；终态仍为 persistenceFailed，测量失败字段保持原停止原因。ResultDisposition 分别表达 measurementCompleted、failure（停止）和 saveFailed/savedLocally；Workspace 传本机保存状态，打开另一个历史记录不会继承它。字幕同时保留“已取消/已中止”和“保存失败”，正文分别呈现停止原因与会话保存说明。thermalProtection/timeout/warmupTimeout/clockInvalid/invalidBatch/metadataBudget/evidenceBudgetForecast/coreIncomplete/partial-v11-result/native-arm64-required 与结构化 timeout/restart 均有中英文案，未知码显示校验失败，不露内部码或 `context.detail`。新增真实 Store＋合成 driver＋内存仓库测试：取消/热保护/超时 × 保存成功/失败 × 中英，共 12 组合；补纯展示所有已知码与身份隔离。反证恢复覆盖停止原因、直接显示 thermalProtection。未改存档 schema、哈希或旧 v9/v10 路径。 |
| fix3 P2-4 终止发布 | 保留原有容量/不同会话隔离断言，新增回调 gate 挂起时提交有效**同会话**最新 100，finish 后释放 gate，要求终态仅交付 [1]。另用只推进虚拟时钟的驱动，在真实五秒展示边界后挂起一个批次及展示回调；取消时要求持有租约到批次排空，随后驱动 finish、遥测清理、租约释放和 cancelled 终态都先于展示 gate 释放完成。反证为遗漏 worker.cancel，以及终止时 await 展示 worker。未启动真实 C/Metal 负载；finish 表示发出终止，不冒称挂起回调已返回。 |

### 原断言迁移依据

P2-3 明确要求停止、测量、保存分别保留，因此原“完整测量遇仓库异常后 outer failure 等于 persistenceFailed”三个断言改为测量 failure 仍为 nil／原停止原因，另以新增 saveState.failed 和保留的 v7State.failed 断言守护保存失败。保存失败文案、18 项完成、空历史、未保存和保存失败字幕断言保留；旧 `terminationText != nil` 改为 `saveFailureText != nil` 并要求此完整测量没有停止原因。原 outer-failure mutation 仍使用原测试方法：增加内层 completed／外层 cancelled 的矛盾夹具，严格要求读取外层 cancelled，避免该变异因完整测量 failure 为 nil 而失效。P2-1 原摘要三个源码调用守卫改为共享适配器接线及逐项实际 status/reason 检查，保留 B2 共用灰色出口断言，并增加历史接线和实际原生 frame 检查。没有删去测试意图、提高最低比例或放宽几何/CV/预算阈值，没有新增 skip。

### 反证、包与主会话后续

`counterexamples.json` 从 86 增至 **94**：原 86 个 ID/测试意图保留，85 个对象逐字相同；仅 `ui-fix2-gray` 等价重定位为 `primaryStatus: chip.status`，仍由原灰显方法反驳 primaryStatus=nil。新增 8 条逐项标本轮四项 P2，含复核给出的同行 0.01 overlay、同会话 pending 和停止×保存组合。全部锚点按约定出现次数核对，方法存在；本沙箱按 prompts **未运行 mutation**，原 86 的杀死证据是主会话 fix2 日志，新 8 条及重定位需主会话在 fix3 上执行。

`targeted-classes.txt` 保留原 43 类，补 HistoryScorePresentation、TerminationPresentation，共 **45 类**。交付 `prepared/ui-fix3/incremental/` 相对此次开始的 fix2 工作树；`full/` 相对 HEAD 6e60469b，供主会话替代旧包。根 `commit-prepared.py --check-only` 使用 scratch 内私有 index/objects 核对两包相同最终路径/blob，真实 `.git` 只读；`--validated` 本轮不执行。before/final/artifact SHA、日志 SHA、保护源及定向结果在 manifest/static-checks/prepared-verification。

主会话需以合成数据重拍：当前受限历史三分及原因、芯片可比但整机/能效受限的历史行；取消/热保护/超时 × 保存成功/失败的双说明与字幕（中英、日夜，重点最窄/最短窗口）。保存失败和新受限状态仍需适配器/合成依赖注入，现有 CLI variant 没有新增这些参数。原七尺寸五页、旧历史与设置入口的重拍边界继续有效。重跑 45 类、全量和 94 条 mutation；前轮 MemoryHeadroom 成功不表示此前 69/70 差异已定位。

JEV 本轮实际调用被 `MCP tool call requires approval, but approval policy is never` 拒绝，未获得模型标识或判断；Store 独立保存状态的选择由当前代码证据及定向测试核验。本轮不提交、不安装、不 push、不启动真实负载。


### fix3 沙箱实际验证

- 最终含测试编译成功：`logs/ui-fix3-build-second.log`，28.35 s，exit 0。首次编译仅新原生测试的 Set/flatMap 长表达式触发 type-check 时间预算，拆成明确的字符串插入后通过；首次失败日志保留，未改产品或断言来绕过。
- 相关 **8 类 / 54 项 / 0 失败**：`logs/ui-fix3-related-first.log`，exit 0，265.047 s。包括全部新方法，旧七尺寸/日夜/中英原生矩阵、保存/取消/重建、精确缩放及摘要灰显断言。
- 为避免重复执行已通过的原生矩阵，其余 **37 类 / 362 项：336 通过、26 个方法失败，共 27 个断言**：`logs/ui-fix3-remaining.log`，exit 1。两批类集合互不重叠、Swift 源 SHA 相同，完整覆盖 **45 类 / 416 项：390 通过、26 失败**；不是一次 45 类单命令日志。UIConsistency 46/0；26 个失败方法逐个等于 fix2 沙箱内集合：TestFileSystem 家目录创建 21、CFPreferences 持久化/重开 3、MemoryHeadroom 内核 nil 2。没有新失败方法；不将环境受阻算通过，不改变路径、断言或阈值。
- `static-checks.json` 保存两个执行过滤器对应的方法级结果和诊断、编译/日志 SHA；`tested-source-sha256.json` 为最终已测 51 个变更 Swift 文件。所有 Swift 源自最终编译后未再修改。
- `git diff --check`、94 个反证锚点及测试方法核对通过。ScanStore、helper main、SystemMemoryProbe、MemoryHeadroomSysctlTests、BenchmarkV7RuntimeModels 均逐字节等于 HEAD。真实 HEAD/index 与本轮开始 SHA 一致。未跑本轮全量、Release/安装或 mutation，未进行真实测量；主会话应复跑受阻项及新的合并门禁。


最终包：增量 **14 文件 / 四组**（运行与证据 2、展示 5、回归 6、交接 1）；完整替代 **63 文件 / 四组**（共用 B2 18、v11 接线/页面 23、回归 21、交接 1）。`commit-prepared.py --check-only` 已通过 SHA、补丁可应用性、当前工作树反向匹配及私有 index 的最终 blob 一致性；真实 `.git` 未写，HEAD/index 与开始时一致。结果记录在 `prepared-verification.json`，日志为 `logs/ui-fix3-prepared-check.log`。

主会话沙箱外命令：

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-bench-v11/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(cat /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui-fix3/targeted-filter.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui-fix3/commit-prepared.py --check-only
```

完整替代包包含原 UI/fix1/fix2 与本轮修复，主会话完成本轮全量、94 条反证及视觉门禁后选择它提交；不与原包或增量包叠加应用。`--validated` 本会话未运行。

## ui-fix4 · fix3 复核两项 P2 回修（2026-10-11）

依据 `logs/codex-ui-fix3-review.log` 末尾“修复后合并”的两项 P2。开始时 HEAD 仍为 `6e60469b1e33c1a6a7e93b3915c90b4091ecad26`，分支 `task/r2-bench-v11`；fix3 完整包的 63 个文件 SHA 与工作树一致。先冻结当前工作树到 `prepared/ui-fix4/before/`，保存 baseline manifest、原 94 条反证和原 45 类定向清单。fix3 审查仅为只读复核，本轮不把其静态反证核对称为 mutation 杀死证据，也不冒称主会话正在执行的门禁结果。

### 两项编号与处理

| 复核编号 | 实现与守护 |
| --- | --- |
| fix4 P2-1 Core 实际停止码 | `ResultDisposition.reasonText` 为 `thermal-protection` 增加热保护别名，为 `core-timeout`、`core-item-timeout` 增加超时别名；中英文沿用对应明确文案。Core、v11 Runner、封装与归档均保留原始码，未改内核或 schema。新增 `MSeriesV11CoreFailurePresentationTests` 静态读取**实际 Core 文件**全部 `failure` 字面赋值及 `globalFailure: failure` 返回，要求当前三种码全部有明确中英文案；新未知码、非字面赋值或返回形式变化会失败，要求维护契约。另用真实 Store/Coordinator/v11 Runner 加合成 Core 返回，三种码 × 中英共 6 组合，严格核对 core.globalFailure、envelope.failure、outer failure、sealed SHA、内存归档原样、7 项已完成及具体停止文案；确认不派发后续扩展、遥测正常清理。没有调用真实 Core 负载。 |
| fix4 P2-2 后续读回恢复 | `loadHistory` 在已有 operation/generation 校验及撤销过滤之后，只于 loadStatus 为 `.loaded`、当前独立保存状态 `.failed` 且精确匹配当前结果、record 非空和 raw SHA 非空、读回 record/session/raw SHA 与原停止原因相同时改为 `.saved`。只校正保存确认，不重写测量结果或原停止原因。新内存仓库成功保存但首次隐藏读回；后续空读回仍失败，同一精确记录成功 loaded 后恢复“结果保存在本机”，保存失败正文/字幕消失，已完成/热保护原因保持原样，重复加载幂等。另逐一仅改变 record、session、raw SHA 或 outer failure，要求仍失败；同一记录但 missing/failed/corrupt 状态也不能恢复，最后 loaded 才成功。 |

Core 定义守护是针对当前字面赋值形式的源码契约，不声称是 Swift 全语法解析器。它检测到新码或形式变化时要求明确更新测试与翻译；不从翻译表反向推断 Core 定义，也不自动把未知码当作已翻译。

### 沙箱实际编译与定向结果

- 含测试编译成功：最终 `logs/ui-fix4-build-final.log`，**6.72 s / exit 0**；首次编译 `ui-fix4-build-first.log` 为 16.63 s / exit 0。最终 52 个变更 Swift 文件 SHA 留在 `tested-source-sha256.json`，此后未改 Swift 源。
- 相关 **6 类 / 52 项 / 0 失败**：`logs/ui-fix4-related-final.log`，17.246 s / exit 0。包括 CoreFailurePresentation、Persistence、TerminationPresentation、Runner、PagePresentation、History 六类的全部方法，新增五个方法均实际通过。
- 必须的共用守卫：`UIConsistencyRegressionTests` **46/0**；`TestPreferenceHygieneTests` **21 项 / 19 通过 / 2 个方法失败、3 个断言**，见 `logs/ui-fix4-common-final.log`（两类合计 67 项 / exit 1）。失败方法仍为 `testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`（:308 synchronize、:309 plist 存在）和 `testTemporarySuiteCanBeReopenedOnAWorkerThread`（:324 synchronize）；日志包含 CFPreferences 临时 plist 的 `sandbox_extension_issue_file … Operation not permitted`。精确方法集合与 fix3 沙箱相同，未改路径/断言/阈值、未加 skip，不视为通过。
- 两个最终过滤器互不重叠，均使用同一份最终编译的 Swift 源，合计 **8 类 / 119 项 / 117 通过 / 2 个方法失败、3 个断言**。完整主会话清单从 45 增至 **46 类**，补 `MSeriesV11CoreFailurePresentationTests`；本轮只跑受影响类及必须共用守卫，其余 38 类（含未改布局的原生矩阵）保留在清单供主会话复跑，不宣称本轮已执行全部 46 类、全量或 mutation。
- 首次相关测试为 52 项 / 12 个失败断言，全部位于新读回身份反例方法：夹具给压缩 v11 JSON 的外层增加 raw SHA 键，解码仍读取 compact payload，导致反例实际上是同一记录并被正确恢复。仅修正新夹具为既有 `replacingRawDigest`/`replacingV11Envelope`，增加直接检查 SHA 确实改变的断言；产品隔离逻辑不变。重新编译并复跑全部相关六类，最终通过；首次日志 `ui-fix4-related-first.log` 保留，不隐藏失败。

`static-checks.json` 保存每个执行过滤器、方法级结果、诊断、日志 SHA、已测源 SHA 与保护文件 SHA。`git diff --check` 通过。ScanStore、helper main、SystemMemoryProbe、MemoryHeadroomSysctlTests、BenchmarkV7RuntimeModels、MSeriesV11Models、MSeriesCoreRunner、TestPreferenceHygieneTests 均逐字节等于 HEAD；真实 HEAD/index 与本轮开始一致。

### 反证、交付与主会话重拍

`counterexamples.json` 从 **94 增至 104**。原 94 个 ID/测试意图保留，其中 93 个 JSON 对象不变；仅 `ui-fix3-internal-stop-code` 因新增别名，等价把原 thermalProtection 分支锚点改为同一分支的新 case 列表，变异仍直接显示内部 `thermalProtection`，仍由原中英文准确文案方法反驳。新增 **10 条**逐条标 `review_round=ui-fix4` 及 P2 编号：分别移除三个 Core 别名、在实际 Core 定义加入未翻译新码、成功重读仍置 failed，以及绕过 record/session/raw SHA/loadStatus/停止原因五种隔离。**104 个锚点出现次数和对应测试方法存在性均核对**，见 `counterexample-anchor-audit.json`；按批次规则未执行 mutation，104 条的实际杀死结果须主会话运行。

`prepared/ui-fix4/incremental/` 为相对本轮开始的 fix3 工作树的 **5 文件 / 四组**增量（Store 1、展示 1、回归 2、交接 1）；`full/` 为相对 HEAD **6e60469b** 的 **64 文件 / 四组**完整替代包（共用 B2 18、v11 页面/接线 23、回归 22、交接 1）。两包含分组 patch/message、all.patch、before/final/artifact SHA manifest；根目录有 `commit-prepared.py`、`static-checks.json`、完整 targeted 清单及本轮实际执行的 related/common 过滤器。保留原 UI/fix1/fix2/fix3 包。根 `--check-only` 以 scratch 私有 index/objects 和真实 objects 只读 alternate 核对两包最终 blob 相同，检查完整包可用于 HEAD、增量可在当前工作树反向匹配及全部 SHA；核验结果见 `prepared-verification.json`。未执行 `--validated`。

主会话需用合成依赖重拍两个新增语义场景（中英、日夜，重点最窄/最短窗口）：

1. Core 第 8 项停止后保留 7/18，分别注入 core-item-timeout、core-timeout、thermal-protection，结果说明应具体显示超时/温度保护；与保存成功/失败的存储说明并列时检查换行、字幕及数字边界。
2. 成功写入但首次隐藏读回→重新进入页面成功加载同一记录，保存失败说明与字幕消失，历史可读，原热保护说明保持；不同身份或未确认读回画面仍保持失败。现有 CLI variant 未新增这些参数，需要使用本轮合成依赖/适配器注入，不能启动真实跑分验证。

前轮七尺寸五页、旧历史/设置入口等重拍要求继续有效。主会话沙箱外先复跑 46 类、两个受阻偏好方法、全量和 104 条反证；随后选择 `full/` 完整替代包，不与旧包或增量重复叠加。

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-bench-v11/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(cat /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui-fix4/targeted-filter.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/ui-fix4/commit-prepared.py --check-only
```

JEV 本轮调用仍被 `MCP tool call requires approval, but approval policy is never` 拒绝，未取得模型标识或判断，不声称完成 JEV 复核。本轮未安装、提交、push、发布、运行全量/mutation 或启动真实负载；MemoryHeadroom 69/70 差异仍沿用前轮未定位结论，不改其容差或实现。

## fix5（主会话，2026-10-11）

fix4 只读复核（`logs/codex-ui-fix4-review.log`）结论“修复后合并”，唯一 P2：Core 停止码守护只识别 `failure = …`，`var failure: String? = "新码"` 这类声明初始化会静默漏检。处理：守护要求 `MSeriesCoreRunner.swift` 中 `failure` 只有一处声明且必须是无初始化的 `var failure: String?`，否则抛 `changedFailureDefinition`；守护自测补“声明初始化”“另起同名声明”两种反例。反证 `ui-fix5-core-declaration-initializer` 在源码声明处加初始化，由 `testActualCoreFailureAssignmentsHaveSpecificChineseAndEnglishPresentation` 反驳。产品代码未改，未删断言、未放宽阈值。


## merge · integration dcb946e7 合入 benchmark v11（2026-10-11，范围适配待确认）

起点 HEAD `7cb985b4cd32d5fcfa77fd36f1bac3079f2450b0`，MERGE_HEAD `dcb946e7043a13f0f270a70ea2dca25fef29e143`，merge-base `3e5eead099fb60487a47dc54647b6524d1979bc2`。用户报告合并前沙箱外定向 421/0、全量 4612/0、反证 104/104，fix5 另 1/1；这些是合并前证据，不能用于声称本轮合并验证全绿。冻结 1538 个工作树文件 SHA、真实 index SHA、十份冲突态及各 stage 的 base/ours/theirs。没有 add、commit、abort、安装或真实跑分。

十个冲突文件已去除冲突标记，保留真实 Git 合并 index。**工作树尚不能声明可以合并：另有四处非冲突文件必须适配，但用户限定“其余自动合并文件不要改，除非编译需要”。现工作树能编译，因此未把测试失败解释为编译例外，四处原文件保持冻结 SHA；已准备独立候选补丁并验证，待用户确认范围。**

### 逐文件取舍

| 冲突文件 | 取舍和理由 |
| --- | --- |
| `LightfieldComponentGallery.swift` | 采用集成侧 Gallery 的参数顺序，完整保留十二组件示例、DEBUG 隔离和无副作用捕获路径；适配 Page 的 artwork/showsArtwork 顺序。 |
| `MainWindowSnapshotPipeline.swift` | 保留自动合并的集成侧捕获、健康能力元数据及 B7 analysisView；与 v11 的 variant/section/stage 元数据并存。没有从新捕获元数据回退到旧版。 |
| `HelperPowerMetricsMonitor.swift` | 保留 D74 居民 cadence、单条物理在途 gate、sleep generation、成功缓存原日期、lastFailure、三重历史上限。叠加 v11 请求单调时钟、requestSequence、latestReading 和 observer。新 API 将测量 observer 显式绑定 consumer；只有它本人的可见租约请求 2 秒，普通可见 5 秒、隐藏 60 秒、低电量 180 秒，睡眠优先。快速 worker 和居民 tick 共用一个 gate；取消 worker 后等旧物理请求排空才能清槽或重启。居民刷新失败保留原成功值/日期，却清除 latestReading 且不发布新能效证据。**Bridge 调用这一 API 的一行接线只在隔离候选中，未写入原工作树。** |
| `FeatureLightfield.swift` | 以集成侧 B2–B7 控件、状态与 palette 为准，保留 fileType 色、action AX、artwork override；叠加 v11 subtitle/accessory/placement。模块拥有权取并集：精确十二个光场路由，精确剩余 overview/devCaches 两个。清除实际重复 showsArtwork 声明。 |
| `FeatureLightfieldChartGeometry.swift` | 集成侧 timestamp lower-bound、hover 身份、缓存气泡布局算法原样保留；只增加 v11 非均匀 xFractions 的 index/point/drag API。比值像素栅格舍入与原容差不变。 |
| `FeatureLightfieldCharts.swift` | 保留集成侧 ChartItem 自定义色/detail、Bubble 指针局部 hover 和缓存、linkedID/emphasizedIDs、Donut 选择/可交互图例。Trend 在集成侧已有逻辑上叠加 v11 独立双轴、轴标签容纳/完整 AX 值、非均匀功率坐标、线程点标签和双图例；默认时间轴和 hover 时刻保持。为已有缩放点赋精确站点 ID，既有 chart/disk 0.8、donut 0.5 不变，v11 轴 0.75 不变。 |
| `FeatureLightfieldComponents.swift` | 保留 B2–B7 OptionRow inclusion/metadata、PID 图标校验、StatusGlyph 自定义符号/色/AX、MetricGroup showsLabels/原生布局、DataBar share 色、ExpandableRow subtitle/trailing/compact boundary、公共 ResultContent。叠加 v11 caption/prefix、primary/secondary/status 灰显、DataBar status 优先、每瓦数值层级依赖。TextSegments 间距/高度可配置，默认 26/32 保持集成语义，修正真实 v11 调用的编译错误。Summary 默认 34pt 及 v11 24pt 列间距各有实际调用，二侧守护原样保留。Ring 采用集成侧 `LightfieldRingTypography` 对数字＋单位整条基线测量、二十步字体搜索；不是保留旧固定字体再把旧站点阈值降低。增加 48/76/100/160pt 下长数字＋中文单位＋状态宽度的无新增容差断言。 |
| `FeatureLightfieldContractTests.swift` | 路由集/计数按 D72 并集迁移，仍精确比较集合与 12/2 数量。原双方 16 方法全保留；新增 4 个 Helper 生命周期方法与 3 个组件/捕获/精确缩放方法，全部无真实请求和负载。 |
| `GeneratedArtTests.swift` | 保留 HEIC＋八张 benchmark PNG 的原 `<1 MB` 合计预算，八张各自尺寸/alpha；并保留全 140 张 D70 PNG 的精确库存和尺寸守护（全量解码由 LightfieldOptionIconTests）。同一选项预算取严格 `<1 MB`，比集成侧 `<1.1 MB` 更严，未提升任何数值阈值；未知文件大小必须 XCTUnwrap，不能填零。装饰性 Surface 守护保留，默认 artwork 表达式接受集成侧 override。 |
| `UIConsistencyRegressionTests.swift` | v11 精确路径/接收表达式/最低比例/单行属性检查与集成侧逐行 marker/文件调用预算同时保留；组件 6、图表 6、B7 1/3/3/3/1 原预算不变，加入 v11 页面各 2。冲突态已自动带入集成侧 Settings 守护的 D69/B6 改名（native grouped→Lightfield）；该完整新方法原样保留，公共断言不丢失，旧 Form 路径被已批准 B6 设计取代，不恢复旧 Form。 |

测试方法盘点见 `test-intent-audit.json`，设置方法的既有迁移单独列出，不把它当作本轮无声删除。所有修改均可由 frozen conflict-state 重建。

### 四处必要的非冲突适配：仅为可审阅候选

`01-proposed-required-adapters.patch` 共四文件，未应用到工作树：

1. `MSeriesV11TelemetryBridge.swift`：唯一生产接线改为 `observeReadings(for: consumerID)`。隐藏 v11 后留下 observer 时，其他页面的 consumer 不能延长它的 2 秒周期。
2. `MSeriesV11ScaleContractTests.swift`：冻结整条基线测量后新 Ring 的三处精确表达式及集成侧原 0.1 兜底；旧 fixed-font ring-* 站点不再存在。添加 B7 五个真实路径的全部数值/日期/容量/占比表达式，最低 0.5，逐项固定数量，duplicate size 恰为两次；generic marker 只能匹配该文件指定表达式，不免检文件，同行多个调用仍禁止。分析页实际有三处，全部纳入，没有只测首处。
3. `FeatureLightfieldB2ImportSourceTests.swift`：旧检查要求 Components 出现 0.8，集成侧 ComponentSource 明确禁止 0.8、要求 whole-baseline typography/0.1，两者逻辑相斥。候选迁移旧固定字体字面守护为三个字体均取 fitted typography、三处 0.1 精确数量、禁止旧 0.8；配合新增定量基线宽度测试及精确 Site 契约，保持原意并加强表达式/边界约束，其余原断言全部保留。
4. `LightfieldBenchmarkOptionIconTests.swift`：D70 整目录已有 140 张导出，旧“整目录恰八张”应迁移为 benchmark 家族精确八张＋整目录精确 140 张 enum 导出。原 70 家族、28pt、56/84、PNG alpha/cache/缺图等断言保留，未允许未知文件。

四个改动的 before/final 在 `extra-before/`、`proposed-extra-final/`；原工作树文件均等于冻结内容。候选在 `validation-source/` 独立副本执行，使用 `merge-candidate-debug/` 私有构建输出、已存在只读 Sparkle 缓存。尚未取得这四处原文件改写的范围授权，不能把候选验证声称为原工作树最终全绿。

### 沙箱验证与限制

- 原工作树含测试编译成功，`ui-merge-build-fifth.log` 7.69s/exit 0。初次仅 TextSegments 缺 spacing/height；新增合成测试最初误用了 `.timeout`（实际 `.timedOut`）及提取 Summary 后缺显式 return，均在冲突文件内修复，早期失败日志保留。
- 定向清单 46→80 类（原 78 类整轮加补两个 helper 类），补 B2/B3/B4/B5/B6/B7、D74 prestored/sampling、helper upgrade 等受影响类。原工作树执行完整 78 类：710 方法，666 通过、44 方法失败，60 断言/错误，其中 31 unexpected。日志 `ui-merge-targeted-first.log`。7 方法是未应用适配引起的失败：B2Import 字面站点、Benchmark 图库存、2 个 Bridge 租约链、Merge 数值站点、ScaleContract、UIConsistency 数值守护；37 方法为下述受阻读写，留主会话外复跑。
- 隔离候选首次含测试编译 202.91s/exit 0；78 类首次 710 方法，670 通过、40 失败方法（44 断言/错误、31 unexpected）。其中 3 方法失败是新白名单表达式定位：迁移页 review 和 result 同字段字体不同，分析页另两处数值缩放漏纳。只修候选表的精确表达式/完整库存；未改产品、预算、断言或加 skip。
- 候选最终含测试编译 `ui-merge-candidate-build-final2.log` 7.67s/exit 0；复跑全部受影响 8 类，`ui-merge-candidate-related-final2.log` **76/0**（2.053s），含新 7 方法、原 Scale/B2 导入/组件 Source/图片两套检查及完整 UIConsistency 46 方法。首次全定向与这次整类复跑的最新方法证据合并为 673 通过、37 受阻；补两个 helper 类 9/0 后，候选 80 类最新证据合计 682 通过、37 受阻；这不是声称执行了一次 710/0，也不是本机工作树最终通过。
- 受阻项均逐方法记录 `static-checks.json` 和方法表：31 个家目录 fixture/cache 写入失败（Code 513/Operation not permitted）；偏好落盘/重读四个方法（BenchmarkV7History、SettingsMiniWindowPreview、TestPreferenceHygiene 两个），CFPreferences 日志明确 `sandbox_extension_issue_file … Operation not permitted`；MemoryHeadroom 两个方法读 kern.memorystatus_level 得 nil，本轮 `/usr/sbin/sysctl kern.memorystatus_level` 独立返回 Operation not permitted。没有为此改测试、改路径、放宽容差或 skip。无法在本沙箱确认新的 69/70 差异，原精确判断保留。
- 新增 11 个候选反证引用的正常方法全部通过；原 105 中四条反证引用的同一个 FeatureTemplate 方法仍因家目录夹具受阻。补 HelperReplyBoundary/MSeriesV11TelemetryPrivacy 两类各视图合计 9/0 后，所有引用均有实际执行记录；**没有执行 mutation 或全量测试**。当前 workspace 的 115 条只有静态锚点/方法核对，不能称为已杀死。

### 反证和交付

原 105 个 ID 和测试意图保留；仅 `v11-request-start-throttle-disabled` 的 before 从 `time - $0 >= Self.minimumInterval` 等价改为同一节流判断的 `time - $0 >= interval`，after 仍 `time - $0 >= 0`、原 filter 和次数不变。当前 scratch `counterexamples.json` 为 **115**：增加 owner 隔离、低电量优先、失败不作实时证据、原日期、物理在途、整基线单位宽度、Donut identity、analysis capture、B7 最低缩放及同行 overlay 0.01 十条。隔离候选 `counterexamples-candidate.json` 为 **116**，再加一条 Bridge 去掉 consumer 绑定反证；只有采用四处候选后它的 before 才存在于实际工作树。分别逐条核对所有锚点出现次数及测试方法，见 anchor audit。

交付 `prepared/merge/`：十文件冲突态增量 `00-merge-resolution.patch`、stage 副本 `resolved-base/`、恰十文件 `final/`、提交信息模板、只读 `verify-readonly.py`、manifest/static-checks、方法表、source SHA、80 类清单和本交接独立补丁。另列未应用 `01-proposed-required-adapters.patch`；不得把它误称为本机已实施。只读脚本检查十份 final/工作树、冲突标记、其它文件保护、index/HEAD/MERGE_HEAD、内存重建 patch、原反证保留及锚点/方法。`--candidate` 单独核对四处适配后的隔离副本。此时真实 Git index 仍有原十个 UU/AA 项，用户主会话完成范围决策后自行 stage/commit。

需主会话确认四处范围，采用后沙箱外复跑 80 类、37 个受阻方法、全量及 116 条反证。视觉仍需原 v11 五页、七尺寸×日夜×中英；合并重点重拍：窄/短窗口圆环长单位和暂定/受限分、三轴加大输入及每瓦 24pt/线程标签/双图例、B7 bubble/donut 联动与长日期数值列、Gallery、B3 能量/内存摘要默认 34pt，以及 D74 隐藏保留原日期→可见刷新→v11 会话租约结束。使用合成输入，不启动真实负载。

JEV 工具调用被自动审批拒绝：`MCP tool call requires approval, but approval policy is never`。未取得实际模型标识或评审结果，不声称调用成功。原工作树非冲突源/测试四处适配待确认是用户的显式范围边界；JEV 拒绝不构成本轮停止实现的理由。


### merge · 四处必要适配获批并应用（2026-10-11）

主会话明确批准 `01-proposed-required-adapters.patch` 的四处改动。本节更新前述“范围待确认”状态：四个文件已实际写入原工作树，不再只是隔离候选。应用前分别核对原文件与 `extra-before/` 字节相等，候选与 `proposed-extra-final/`、`validation-source/`、manifest SHA 相等；应用后四文件逐字节一致，全部 **984 个候选已测试 Swift/Package 源文件**也与实际工作树 SHA 一致。除这四个源/测试文件、原十个冲突解决文件及本交接外，冻结的其它自动合并文件未改。HEAD、MERGE_HEAD、真实 index SHA 不变，没有 add/commit/abort。

已应用的四处：Bridge 使用 `observeReadings(for: consumerID)`，修复 consumer 绑定；B2Import 守护迁移到集成侧整基线字体测量/三处 0.1 兜底并禁止旧 0.8；benchmark 图标守护保留精确八张 family，同时核对 D70 的全 140 张导出；ScaleContract 按文件、接收表达式、最低比例及精确次数接纳集成侧真实站点，同一行多个调用仍拒绝。没有再次修改候选、断言、阈值、容差或添加 skip。

交付采用两个源码分组：**00** 为 `00-merge-resolution.patch`＋原 `final/` 的十个冲突文件；**01** 为 `01-required-adapters.patch`＋`01-required-adapters/final/` 的四个必要适配。旧 `01-proposed-required-adapters.patch` 与 `proposed-extra-final/` 作为已审阅来源保留，补丁与正式 01 字节相同；提交信息模板分别对应两组。交接另有 `02-merge-handoff.patch`，不混入源码分组。manifest、README、static-checks 及只读脚本已更新为“已获批且已应用”，脚本内存重建 00/01/交接三个补丁，并核对十四份 final、所有冻结路径、984 个源码 SHA、无冲突标记、HEAD/MERGE_HEAD/index、116 条锚点和 80 个类。

原工作树沙箱验证（最终源码，此后未改 Swift）：

- 含测试编译成功，`logs/ui-merge-approved-build.log`，**19.18s / exit 0**。
- 十个受影响类 **85 项／0 失败**，`logs/ui-merge-approved-related.log`，2.293s / exit 0：HelperPowerMetricsMerge、LightfieldMergeContract、MSeriesV11ScaleContract、FeatureLightfieldB2ImportSource、FeatureLightfieldComponentSource、LightfieldBenchmarkOptionIcon、GeneratedArt、UIConsistencyRegression、HelperReplyBoundary、MSeriesV11TelemetryPrivacy。
- 补跑 HelperPowerMetricsMonitor、MSeriesV11TelemetryBridge、MenuBarPrestoredSampling 三个完整生命周期类：**36 项，33 通过、3 失败**，`logs/ui-merge-approved-lifecycle.log`，2.548s / exit 1；其中 Bridge 九项全部通过。三个失败均在 `TestFileSystem.swift:60` 创建家目录 `~/.storage-cleaner-scan-store-*/home` 夹具时被 Code 513／底层 Operation not permitted 拦截，分别为 `HelperPowerMetricsMonitorTests/testScanStoreWiringDegradesWithoutRequestingOrAuthorizing`、`MenuBarPrestoredSamplingTests/testResidentFirstNoSampleWaitsThenBecomesUnavailableOnSharedTick`、`MenuBarPrestoredSamplingTests/testResidentProcessSampleExistsBeforeAnyPageAndReopenDoesNotResetIt`。按 common 指令保留原测试和路径，交主会话沙箱外复跑。

counterexamples 采用候选 **116 条**，scratch 与包逐字节一致；原 105 个 ID 保留，唯一节流锚点等价迁移不变，十一条新增锚点及其正常测试方法均核对，新增十一条引用的正常方法此次均通过。全部 116 条的锚点次数及源码行重新审计，见 `counterexample-anchor-audit.json`；没有执行 mutation，不能声称 116 条反证已杀死。`targeted-classes.txt` 保持 **80 类**并核对类名存在。此轮只实际执行上述十三类 121 项：118 通过、3 项环境受阻；前节 80 类历史记录及 37 项环境限制仍保留，不将分轮结果称为一次完整全绿门禁。

需主会话沙箱外复跑 80 类、全量、116 条反证及前节重拍场景。JEV 沿用前节工具自动审批拒绝事实，未取得模型判断。本轮没有真实跑分、全量、mutation、安装或提交。
