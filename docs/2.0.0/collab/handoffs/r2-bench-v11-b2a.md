# r2-bench-v11 / B2a 基础层交接

日期：2026-10-10。worktree `/Users/developer/Developer/sc-worktrees/r2-bench-v11`，分支 `task/r2-bench-v11`，基线为 B1 最终交接提交 `373141dc`（prepared manifest 记录完整 SHA）。scratch `/Users/developer/Developer/.sc-build/r2-bench-v11`。输入已通读：两份批次 prompt、RULES、D5/D48/D55/D60/D72、完整 v11 SPEC、B1 交接与目录；BOARD 没有本批专门行。本轮只完成基础层，没有调度 v11 扩展负载或采集参考。

## 1. 改动与依据

| 范围 | 实际实现 |
|---|---|
| 规格资源 | 新增 `AppleSiliconCatalog.manifest.json`，对 B1 JSON 原始字节 SHA-256 与版本核对。两个打包脚本沿用既有 `copy_resource_file`，只新增 Benchmark 子目录的资源复制、结构/hash/逐字节核对；Release 的解压/挂载回读与 Beta 的 bundle 核对也包含此资源。共同检查函数在 `script/benchmark_resources.sh`。没有修改 B1 目录值、来源或 reviewStatus。 |
| 加载与来源 | `AppleSiliconCatalog` schema v2 模型保留 CPU/SKU、机型内存限制、媒体能力、来源与未知原因。`AppleSiliconCatalogLoader` 使用 Bundle 的 Benchmark 子目录；纯 SwiftPM 注入 URL。缺文件、坏 JSON、hash/版本/结构不符返回未知规格；不依赖 Bundle.module、不从仓库偷偷回退。不将草案 reviewStatus 提升为已批准。 |
| 识别 | `AppleSiliconHardwareCollector` 注入数据源，采集 brand、全部命名物理/逻辑 perflevel、物理总数、Metal 名、profiler GPU 与内存。纯 `AppleSiliconIdentifier` 精确匹配品牌、按 Super/Performance/Efficiency 名称聚合，不按 index 猜；保留读数、时间、缺项和冲突。复用 HardwareProfileCollector 的解析/有界 Shell 路径，v11 只选唯一 Apple GPU，不取外接 GPU 最大值；5s 上限。 |
| v11 模型 | `BenchmarkV7Result` 新增 optional `mSeriesV11`，显式 `decodeIfPresent`；旧容器/旧 Core 的 schema、plan、hash 不变。独立 envelope 包含身份、能效点、5s 窗口、加速器、遥测时间质量、环境、参考、派生分和生命周期。根级新增数组缺失为 []/nil；未来 ID、availability、阶段状态保留字符串，未知身份状态可原值往返。v11 单独验证，不把旧记录改成 v11 再验证。 |
| 评分 | `MSeriesScoringV11` 冻结精确 v11.2 scoring JSON/SHA，独立样本 CV（样本标准差，n≥3），按 §6 权重做无量纲几何平均，再乘1000。GPU 峰值四项各1/4，持续使用末30s的六点绝对 GPU 吞吐；反向 pointerChase；能效单列。比值闭区间0.02…5，CV含端点；无校验、结构/计时/契约不符或不稳定则该项及父组 nil，不重配权重。环境按依赖聚合，可比/受限/不可比保留原因。能效要求 helperMeasured 与三个匹配 work/J 窗口证据；压力模式 raw-only。 |
| 参考 | `MSeriesReferenceV11` 只接受外部 manifest 对原始字节的 SHA 与版本校验、来源 artifact bytes 的 SHA、完整21个计分输入/契约、≥8个独立有效 run、两个 session 各≥4、session 冷却≥600s、不重叠、逐 run/跨 run CV和可比环境。UTC 日期使用 ISO8601。正式 M1 8C/8G与暂定 M5 Pro分开；无有效集 unavailable。所有示例数值只在测试夹具中，生产未增加参考资源/中位数。 |
| 重算 | 在既有 `BenchmarkV7HistoryRepository` 内实现派生缓存 sidecar，不另建数据库/定时器。key 包含 session/raw SHA/scoringVersion/referenceVersion/referenceSHA；同 key幂等。先算全部、写私有临时文件并核对字节，再原子替换派生缓存；失败不覆盖旧缓存、不写原历史。保存上一参考的展示快照、原始时间和参考。v10有效Core仍可单项/独立CPU组计算；缺v11峰值/持续/功率时完整GPU/芯片/整机/能效保持nil。v9等非MSeries记录记录 missingV11Inputs。 |
| 运行页 | 全18个Core、v10占位/动态扩展、v11扩展、加速器别名统一中文映射；动态数字只接受正整数，未来ID显示名称待适配。替换先前 v9 CPU 匹配造成的笼统标题回退。已有 app scoped MacBenchmarkStore提供真实单调已用时间，Workspace 的 TimelineView传入运行页；没有新测量后台定时器。 |
| 进度 | `MSeriesStageProgress` 在开始冻结预算，采用 completedWeight + activeWeight×min(elapsed/planned,1)，保存成功前≤99%，取消后冻结。v11标准预算5/180/45/35/95/95/5＝460；压力负载300+300；可选阶段开始前加入。仍运行的v10采用独立Core/旧扩展预算，不把未实现的扩展算作已执行v11。现有runner的18项序号保持Core语义；v11阶段切换入口已留在Store，B2b负责真实派发。 |

`identificationStatus` 按本轮调用约定使用 matched/ambiguous/unknownAppleSilicon/intel/rosetta；matched 对应规范中的 matchedSku。39个SKU独立正例矩阵全部覆盖，其中38个拓扑已知且唯一匹配；`m5-ultra-36c-80g`仅保留唯一候选与 `skuTopologyUnverified`，不猜目录中缺失的拆分，因此不标matched。未知 translated保持nil和原因，不当作false。带宽不从chip单值继承；内存不从家族最大值覆盖SKU，实际内存不作为抹掉CPU/GPU身份的依据。

没有改旧测试断言，没有改 ScanStore.swift、v10 Core协议/夹具/算法、旧MSeriesScoring或v6计分。没有真实跑分、清理/移动真实文件、硬件设置写入、安装、应用启动、上传、合并或发布。

## 2. 实际验证

| 状态 | 命令/证据 | 结果 |
|---|---|---|
| PASS | 初始 git status/branch/log；当前 diff/source hashes | 正确分支、初始工作区干净；只改本批范围。 |
| PASS | `swift build ... --build-tests`，`logs/b2a-build-final.log`，exit0 | Xcode 27 Beta；沙箱禁用SwiftPM内部沙箱与宏插件沙箱的已授权参数；scratch专属；最终编译51.20s。之前类型名、私有访问级别及数组静态成员的编译错误已经修复，历史日志保留，不视为最终通过日志。 |
| PASS（新增） | `logs/b2a-targeted-final.log` | 新增五类22项测试全部通过，含39 SKU矩阵、相邻SKU反例、缺/坏/hash不符资源、实际fixture Bundle路径回读、参考门禁、几何评分、旧解码、缓存幂等/部分写后失败回滚、真实时间计算与预算。 |
| PASS（相关） | 同上 | HardwareProfile 3项、MacBenchmarkModels 16项、UIConsistencyRegressionTests 46项全部通过。 |
| FAIL / BLOCKED（沙箱偏好） | 最终定向命令exit1，115 tests / 4 assertion failures / 0 unexpected / 无跳过 | 涉及3个旧测试方法，详见下节；不是22个新测试失败。不能写成全套通过。 |
| PASS | `git diff --check`，`bash -n`三份打包脚本，`python3 script/check_private_api.py`，exit0 | 空白/语法/私有API守卫通过，仍为7项允许使用。 |
| PASS（复制路径） | `evidence/b2a-resource-copy.json`，exit0 | 在本批隔离资源目录执行共同复制/核对函数，两文件逐字节与manifest核对通过。fixture Bundle测试证明目标子目录可加载，不代表已经构建/签名/安装正式app或DMG。 |
| PASS（准备） | `prepared/b2a/static-checks.json`、`commit-prepared.py --check-only` | 基线、全部最终文件和分组补丁SHA、combined patch对基线应用预检。没有写真实git索引。 |
| BLOCKED | JEV decide、代码图 list_projects | 返回 `MCP tool call requires approval, but approval policy is never`，未获得JEV供应商判断或图数据；按源码/测试核对，不能宣称模型复核通过。 |
| NOT RUN | counterexamples mutation执行、全量 verify、Release/严格并发、实际bundle/DMG/实机 | 按批次prompt留主会话；反证清单仅校验替换目标与过滤器，未把其绿/红结果伪记为已运行。 |

沙箱明确拒绝的是临时偏好域的 `sandbox_extension_issue_file ... Operation not permitted`（并非本批在真实Library写入）。原断言未删/未放宽：

- `BenchmarkV7HistoryPresentationTests.testDeletingLastConfirmedRecordCannotRevealRevokedLateSuccess`：171行 synchronize失败（1个断言）。
- `TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`：308、309行 synchronize/临时plist存在断言失败（2个断言）。
- `TestPreferenceHygieneTests.testTemporarySuiteCanBeReopenedOnAWorkerThread`：324行后台 synchronize失败（1个断言）。

这两个类须主会话沙箱外复跑全部方法。没有增加例外或skip，也没有尝试绕过权限。其余偏好域代码/源码卫生守卫仍执行；沙箱测试的临时根由TestFileSystem/TestPreferenceDomain按既有收尾清理。

## 3. 主会话命令与红/绿/反证

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-bench-v11/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-bench-v11/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
```

scratch `targeted-classes.txt`为实际存在的10个类，包括强制UI与偏好卫生类；没有选入会执行真实内核负载的MSeriesCoreKernelTests。沙箱外完整定向须exit0后再进行主会话审批/提交。

反证文件：scratch `counterexamples.json`，严格 `{mutations:[{id,path,before,after,expected_occurrences,filter}]}`，13项，每项替换目标恰好一次。主会话在隔离副本按单项变异、重新编译、用其实际Class/testMethod过滤器运行并保存失败证据，随后恢复并验证绿；不得在这个prepared最终文件上留下变异。覆盖越界比值、缺项造值、CPU/GPU权重、反向项、CV、按index猜核心、目录hash绕过、参考冷却/source hash、保存前100%、能效错位与覆盖原历史。红必须由对应行为断言触发；构建失败不充当行为反证通过。B2a没有执行这些变异。

集成门禁仍由主会话运行：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-bench-v11/verify-main \
script/verify.sh
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/b2a/commit-prepared.py --check-only
# 完成所需验证与复核后，主会话才执行：
python3 /Users/developer/Developer/.sc-build/r2-bench-v11/prepared/b2a/commit-prepared.py --validated
```

## 4. prepared 与后续边界

`.git`按当前会话权限只读，未尝试实际提交。B1已有prepared完整保留；B2a独立放 `prepared/b2a/`：01-hardware-resources → 02-model-scoring → 03-history-cache → 04-running-presentation → 05-handoff。每组有patch/message，另有all.patch、manifest（完整基线、分支、顺序、最终文件与产物SHA）、static-checks、带 --validated/--check-only 的commit-prepared.py。脚本先核对身份、空索引、全部hash和基线，再分组提交；它不能替代缺失的沙箱外检查，不安装/合并/push。

B2b需实现实际负载、遥测时间区间、窗口计算与阶段派发，并由真实原始payload生成rawPayloadSHA；本轮仅提供模型、校验/评分/进度入口。有效参考仍为空，B5采集前始终待校准。目录逐字段来源的主会话复核/批准与生产包回读仍未完成；hash通过不等于来源获批。B4结果布局、参考切换触发的UI投影/统一参考展示、最终取消/保存实机验收不属于这次基础层完成证明。
