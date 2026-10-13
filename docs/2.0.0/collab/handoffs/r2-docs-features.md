# r2-docs-features 交接

## 结果与范围

- 分支 `task/r2-docs-features`，基线 `9e53489e06f6a4e08540a9e0538bb9139cc338e7`。开始时工作区干净。
- 新建 `docs/FEATURES.md`：按实际侧栏分组，中英文各写做什么、怎么用、安全边界、限制；每条以公开证据注释关联本表。
- 只重写 `README.md` 的“当前能力 / Features”，缩为八组概览并链接功能详情；其余字节保持不变。
- 本文件记录逐条实测映射、测试版状态、初稿差异及主会话验证要求。不改源码、测试、协作看板或其他文档，不向只读交接目录写入。
- 实测采用《功能实测报告-20261007.md》；对照稿只帮助核对范围，不作为功能通过证明。修复状态以本基线的 BOARD、DECISIONS、相关 handoff 为准。

## 名称与顺序核对

来源：`Models/StorageModels.swift` 中 `ReviewFilter.title/sidebarTitle`，`Support/ModuleTheme.swift` 中 `SidebarGroup`、`ReviewFilter.sidebarGroup/sidebarItems`，`Views/SidebarView.swift` 中相似照片行。

| 层级 | 最终名称与顺序 | 与要求或初稿的差异 |
|---|---|---|
| 首项 | 智能扫描 / Smart Scan | 独立于五个分组 |
| 清理 / CLEANUP | 安全清理 / Safe Cleanup；开发工具与产物 / Dev Tools & Artifacts | 英文分组保持代码的大写形式 |
| 保护 / PROTECTION | 系统健康 / System Health；浏览器隐私 / Browser Privacy | 浏览器隐私为独立页面，不是安全清理子项 |
| 性能 / PERFORMANCE | 性能测试 / Performance Test；登录项与后台任务 / Login Items & Background Tasks；内存管理 / Memory Management；能耗 / Energy | 用侧栏的 Performance Test，不套用页面内部的 Performance Benchmark |
| 应用 / APPLICATIONS | 卸载 / Uninstall；应用更新 / App Updates | 英文分组按代码，不用初稿 Apps |
| 文件 / FILES | 文件分析 / File Analysis；文件搬家 / File Migration；重复文件 / Duplicates；相似照片 / Similar Photos | 文件分析按 sidebarTitle；旧内部 title 的“大型文件 / Large Files”不是侧栏名称。相似照片是同一重复扫描工作区的独立侧栏入口 |
| 小窗、设置 | 菜单栏小窗；设置 / Settings | 小窗补充说明，不虚构为主窗口侧栏分组。设置为侧栏底部入口；只有极客布局可用，不提供旧简单／详细切换 |

公开文案不写内部类型、决定号、缺陷号、批次名、测试应用名称、私人路径或截图个人内容。内部定位只放本交接。

实际操作字符串已经源码核对：`操作记录 / Operation History`、`扫描浏览器记录 / Scan Browser Records`、`复制网址 / Copy Address`、`最近的删除 / Recent Deletions`、`开始健康检查 / Start Health Check`、`开始性能测试 / Start performance test`、`退出所选应用 / Quit Selected Apps`、`开始测量 / Start Measurement`、`分析磁盘空间 / Analyze Disk Space`、`审阅并移到废纸篓 / Review and Move to Trash`、`复制并验证 / Copy and Verify`、`移到废纸篓 / Move to Trash`、`仅所选位置 / Selected Only`、`应用 / Apply`、`取消 / Cancel`。没写未经核对的快捷键或按钮别名。

## 每条“已支持”说法与实测对照

下表为本批文案的全部通过范围。共同来源为《功能实测报告-20261007.md》第二节“逐项结果”，只有明确写出的子流程进入“已支持”；不从单测、已合并代码、可见控件、同类产品或共同框架外推通过。

| 编号 | FEATURES 与 README 的已支持说法 | 实测报告条目／证据 | 边界 |
|---|---|---|---|
| S01 | 智能扫描清理项目按风险分组，测试中的列出分组可选 | 第一节硬标准 (a)，绿 8/8、黄 3/3、红 12/12；第二节“智能扫描／安全清理／开发工具与产物” | “全部”仅指本轮列出分组，不是全规则或所有 Mac |
| S02 | 测试文件清理到废纸篓、操作记录恢复 | 同一条目：勾选 4 个夹具、清理、完成页、操作记录恢复；第一节确认崩溃热修复已安装并实机复测不再崩溃 | 仅夹具；完成后结果保留修复未复测。报告的 P0 复测结论比 BOARD N14 的旧“待复测”记录更新 |
| S03 | 安全清理与开发工具页面的共同分组可选、清理／恢复流程 | 同一合并条目及硬标准 (a) | 不声称每种工具、每个目录都测过；新增规则仍测试版 |
| S04 | 系统健康只读检查，四项有证据、显示评分 | “系统健康”：检查、四项指标与总分、只读 PASS | 不外推全部健康检查项、测速或硬件诊断 |
| S05 | Safari、Chrome 历史扫描和显示；标题、网址、日期；单行选择、复制网址 | “浏览器隐私”，第一节硬标准 (b)：两浏览器扫描，显示 PASS，可单行勾选、复制网址 | 查询参数折叠有报告与界面双重依据；未外推搜索、展开全部访问、其他 14 种浏览器或任何删除 |
| S06 | 性能测试启动、核心阶段完成、扩展阶段取消并停止；上次完整结果仍保留 | “性能测试”：约 6 秒后取消，18 项核心完成，1.2 秒停止，保留上次完整结果 | 不写性能数字承诺；本次完整跑分、评分、上传、排行榜未验证 |
| S07 | 登录项读取与分组列表 | “登录项与后台任务”：读取列表，部分 PASS | 管理标记不是停用／启用通过；两项操作 NOT_RUN |
| S08 | 内存压力、占用、趋势、进程快照；选择建议与取消选择 | “内存管理”：刷新、选择、全部取消；未执行退出 | 缺陷不抹掉读取通过，但退出确认、正常退出与释放量不写已支持 |
| S09 | 六步能耗测量能运行并产生应用／进程结果 | “能耗”：测量、六步说明，应用与进程结果 | 缺陷结论保留；不宣称汇总正确、全覆盖或续航准确 |
| S10 | 测试应用预览只选本体、卸载进废纸篓、操作记录恢复；未核实关联文件保留 | “卸载”：预览→卸载夹具→恢复，本体移走，3 个未核实文件保留，PASS | 不外推真实应用、授权、重试、关联文件清理 |
| S11 | 更新检查，来源和版本差展示 | “应用更新”：检查 PASS，来源与版本差清楚 | 安装未做；不写任一种安装成功 |
| S12 | 文件分析、下钻、当前层搜索、返回、分栏切换 | “文件分析”：个人范围只读分析及浏览 PASS | 不写访达定位／复制路径已实测（初稿有，报告没有）；新版移动与恢复未验证 |
| S13 | 测试文件复制到外接盘、SHA-256 一致、单独确认移原件 | “文件搬家”：复制验证、哈希一致、原件移到废纸篓 | 该条总体为缺陷；只承认复制／移原件子流程，不宣称操作记录恢复通过或应用可运行 |
| S14 | 菜单栏六模块二级、三级与时间档切换 | “菜单栏小窗”；《小窗与iStat对照-20261007.md》第一至三节 | 只承认操作与展示，不将缺值、精度、所有传感器、硬件控制或速度承诺写为通过 |
| S15 | 设置七分区可打开 | “设置（7 个分区）”：逐个打开完整 | 分区名称经 SettingsView 源码核对；没有逐项保存／授权通过 |
| S16 | 小窗设置编辑草稿后取消恢复原值 | 同一条目：改一项，取消，原值恢复 | Apply 保存和全部设置持久化未测 |

公开注释 `cleanup` 对应 S01–S03，`health` 对应 S04，`privacy` 对应 S05，`benchmark` 对应 S06，`startup` 对应 S07，`memory` 对应 S08，`energy` 对应 S09，`uninstall` 对应 S10，`updates` 对应 S11，`analysis` 对应 S12，`migration` 对应 S13，`mini` 对应 S14，`settings` 对应 S15–S16。`scope/safety/requirements` 只概括这些边界和静态系统要求，不增加功能通过范围。README 八组按同一表概括。

## “测试版”条目及原因

| 条目 | 原因与当前资料状态 | 静态约束定位／已有测试名（未在本批执行） |
|---|---|---|
| 清理新版默认选择与新增工具规则 | D47/D52 及 followups 已合并，报告验证的是旧预选，不外推；完成页保留结果 N15 修复已合并，待安装复测 | `docs/cleanup-rules.md`；`CleanupDefaultSelectionPolicyTests`、`CleanupJunkActionableTests`、`CleanupStoreFollowUpTests` |
| 清空废纸篓 | 实测报告第四节明确未做；永久删除，不提供恢复保证 | `CleanupExecutionViews.swift`；`CleanupTrashDeletionTests`；冻结扫描时旧项目、两次确认 |
| 浏览器直接删除及恢复 | N15/D42 修复和 D50 身份约束已合并；报告仅显示 PASS，Chrome 整页删除、Safari、恢复仍未测 | `handoffs/r2-privacy.md`、`r2-live-fixes-1.md`、`r2-live-fixes-2.md`；`BrowserPrivacyTeamIdentifierTests`、`BrowserPrivacyHistoryProcessorTests`、`BrowserPrivacyRecoveryTests` |
| 浏览器备份规则 | 按 D26/D34–D37 及当前源码写为实现约束；7 天、份数限制、到期／手动删除不进废纸篓，旧备份恢复会覆盖其后新增的历史与下载列表，并可能带回之后删除记录 | `BrowserPrivacyRecentDeletionsView.swift`；同上处理与保留测试。本轮没有恢复实测，不称已支持 |
| 登录项停用／启用／撤销 | 夹具步骤被自动操作权限拦截，NOT_RUN | `StartupItemManagementTests`、`StartupItemsPresentationTests`；须先解决操作授权与夹具方法，不让文档批默认授权持久化 |
| 内存退出 | N19/D49 确认、双击防抖、前台排除已合并，待安装实机 | `MemoryQuitConfirmationTests.testTheSecondClickAsksForConfirmationAndNeverQuitsByItself`、`testEveryConfirmationNamesTheAppsAndLeavesUnsavedWorkToThem`、`testSuggestionsSkipTheAppTheUserIsWorkingIn`；小窗 `GeekMemoryView.swift` 确认路径 |
| 能耗汇总与小窗读数 | N16/D49 接电积分、进程名、采样等待、网速沿用已合并，尚未装机核对 | `SystemEnergyACTelemetryTests`、`EnergyProcessNamingTests`、`handoffs/r2-live-fixes-2.md` |
| 性能测试完整流程与取消历史 | 报告只验证开始／取消，N22 的取消历史与负载提示已合并但未复测；参考评分和跨设备验证未完成 | `BenchmarkBackgroundLoadTests`、`MacBenchmarkHistoryRepositoryTests`、`handoffs/r2-live-fixes-2.md` |
| 卸载扩展流程 | 只测测试应用本体；真实卸载、管理员授权、重试、残留处理未测 | `handoffs/batch3a-uninstall.md`，权限边界 D12；不写“强力卸载”或清除全部残留 |
| 更新安装与自身更新 | 报告只检查，安装未做；来源／签名／租约约束是源码依据 | `handoffs/batch4a-update-safety.md`、`Features/AppUpdates`；`AppUpdaterPolicyTests` |
| 文件分析审阅移动与恢复 | D46/D54 已合并（BOARD R7），实测报告仅只读；外接卷应用内恢复仍有边界 | `FileAnalysisTrashViews.swift` 外接卷提示要求访达放回；`FileAnalysisTrashTests`、`FileAnalysisTrashProtectedScopeTests`、`handoffs/r2-file-analysis-trash.md`；不承诺所有卷应用内恢复 |
| 文件分析性能 | N21 合成树性能优化已合并，不是同一实机云盘范围通过 | `StorageMapAnalysisEquivalenceTests`、`handoffs/r2-files-fixes.md`；不引用合成树倍数为用户速度承诺 |
| 搬家原件回执与恢复 | N18/D51② 已合并；实测复制哈希通过，但原件恢复失败且未复测 | `ExternalMigrationReceiptTests.testTheProductionMoveWritesTheLiveJournal`、`testARestoreFromOperationHistoryUpdatesTheMovedRowWithoutAPageSwitch`；应用搬家当前只复制，未实测应用可运行 |
| 重复文件／相似照片 | N17/D51①“仅所选位置”修复已合并，原实测 BLOCKED | `DuplicateSelectedLocationsTests.testSelectedOnlyScopeScansTheAddedFolderAndNoDefaultFolder`、`testSimilarPhotosAndDuplicatesUseTheSameScopeAndLocations`；相似照片只读，不虚构应用内删除 |
| 小窗新增读数与硬件写入 | N16 修复、D57 传感器补全已合并，待安装；N25/D59 充电修复复核中；风扇／电源写入没有本轮实测 | `handoffs/r2-mini-sensors.md`、BOARD N25；D5 禁止后台解除系统暂停；只保留监控流程通过 |
| 设置保存、权限恢复、提醒 | S16 只验证 Cancel；N20 提醒修复已合并未复测；小窗清理摘要仍有遗留 | `SettingsView.swift`、`MiniWindowConfigurationSettingsView.swift`、`handoffs/r2-live-fixes-2.md`；预览明确模拟数据 |

## 与初稿的主要差异

1. 不再用“所有扫描只读、所有删除均先入废纸篓且可恢复”覆盖所有操作；明确永久清空、浏览器数据库备份、备份到期、外接卷访达恢复以及尚未验证的恢复。
2. 清理新预选从初稿“规划”更新为“已合并待实机复测”，不用旧 D40 预选规则描述当前实现；新开发规则也不冒充旧实测覆盖。
3. 浏览器支持范围只承认本轮 Safari／Chrome 读取显示，不宣称十四种浏览器、搜索、直接整页删除或恢复均已通过。直接删除差异与含浏览内容的备份生命周期明示。
4. 系统健康只承认四项证据与评分，不把初稿列举的所有健康或网络项目当实测；完整跑分、参考分、上传和排行榜不写已支持。
5. 文件分析新增审阅移动从“规划”更新为“已合并待实机验证”；不能按初稿笼统写永远只读，也不能把新移动写成已支持。性能优化无真实加速承诺。
6. 搬家保持已通过的文件复制校验与移原件，恢复明确待复测；应用只复制，不按“文件或应用都可移原件”描述。
7. 重复文件／相似照片保留 BLOCKED 边界，即使所选位置修复已合并也不转 PASS；相似照片仍只读对照。
8. 菜单栏仅一种可用布局，删除旧三种密度、多模块数量和不可靠尺寸／0.1 秒速度承诺；硬件读数新增与写入各自待验证，充电缺陷不隐藏。
9. 设置 Cancel 与 Apply 区分，预览是模拟数据；显示权限或打开设置不等于授权成功。
10. README 只改指定节，移除该节旧导航、旧小窗模式、旧隐私口径及版本相关旧能力描述。其前面的实现历史、后面的安全边界与 1.10.1 发布状态仍按任务要求原样保留，可能与当前 2.0.0 概览有口径差异；未扩大范围修改。

## 本批验证与运行状态

本批不编译、不运行 XCTest、不启动应用、不安装、不提交。定向测试类清单：**无，本批仅文档修改**。上表测试名仅用于定位既有证据／后续原功能验证，不是本批运行结果，也不能替代实测报告。

实际文档检查及产物结果见 scratch `prepared/static-checks.json`；检查命令退出码随产物记录。本文件不嵌入自身 SHA-256，最终文件哈希写入 `prepared/manifest.json`。

| 状态 | 项目 |
|---|---|
| PASS | 分支和基线核对、开始时无已有改动；源码、报告、协作资料只读审计 |
| PASS | 仅三个指定文档改动；README 指定节以外字节保持；双语结构、侧栏顺序、脚注及文档链接静态检查；补丁隔离应用后字节／哈希一致（详见最终 static-checks.json） |
| NOT RUN | SwiftPM build、XCTest（0 项）、实机、安装、提交、合并与发布 |
| BLOCKED | JEV：已发现 `mcp__jev__jev_decide`，核对其支持参数（没有可指定模型标识的参数），尝试一次有界文案状态方案评估。工具返回 `MCP tool call requires approval, but approval policy is never`；未得到判断，未声称通过。没有绕过权限或改用旧模型 |

## 主会话要做的验证与红／绿／反证

文档批无需新增构建、测试类或改写断言；不运行真实目录夹具。本批没有改写任何旧测试断言。

在本 worktree 核对文档，再决定提交；命令不编译、不启动应用：

```bash
git diff --check
python3 ~/Developer/.sc-build/r2-docs-features/prepared/check-docs.py
git diff -- README.md
cat ~/Developer/.sc-build/r2-docs-features/prepared/manifest.json
```

- **红：**基线 README 的当前能力含过时导航、三种小窗模式、浏览器隐私旧口径及没有逐项实测依据的支持说法；基线不存在 FEATURES 或本交接。本批校验器用基线内容检查新标准应报告缺少新概览／链接，不运行或修改基线应用。
- **绿：**检查上述 16 条通过范围逐条对应实测；未测或仅合并项标测试版；中英状态一致；只改三文件；README 节外字节一致；隔离套用补丁后与工作区文件完全相同。
- **反证：**在 scratch 中的文档字节副本上分别注入私人路径、内部决定号、删掉英文安全边界、把待验证恢复改成已支持、改动 README 节外内容、篡改 prepared 文件哈希，校验器必须拒绝（不改本 worktree 最终文档）。这是文档约束反证，不是功能／硬件反证。
- **人工复核：**自动检查只能验证范围、结构和已锁定的文案状态，不能证明中文语义或实机功能。请另一模型复核 S01–S16、脚注和“测试版”表，尤其同一模块通过的子流程与未通过写入操作；JEV 没有给出可用判断。
- **若要把测试版升为已支持：**由主会话沿对应原 handoff 运行定向类及隔离夹具实机清单，取得安装版本与逐项操作证据后再改文档。本批不授权真实应用退出、登录项持久化、浏览器删除、更新安装、清空废纸篓或硬件写入，也不要求为这次文档交付重新运行所有功能测试。

## prepared 交付

一组 `01-docs.patch`，包含 README、FEATURES、本交接；相应 `01-docs-message.txt`、相同内容的 `all.patch`、`manifest.json`、`commit-prepared.py`、`static-checks.json`，另附只读检查与再生成脚本。主会话验证后，才在沙箱外运行提交脚本；本批没有运行它。提交脚本校验工作区、分支、完整基线、暂存区空、所有最终文件及准备产物哈希，再仅暂存本组补丁并提交，不 push、不安装。

## 未解决

- 公开范围只依据 2026-10-07 报告及当前基线；未来安装或复测应更新对应状态，不能自动继承“已支持”。
- BOARD 没有 `r2-docs-features` 专属行，文档整理按 R4 和用户本轮明确授权执行；未修改看板。
- JEV 权限受阻；仍需主会话安排不同模型复核。
- 本会话未暴露可核实的底层模型标识；提交尾注如实写 `Generated-By: Codex (model identifier not exposed)`，未把任务默认型号冒充运行证据。主会话可用启动头中已核实的型号更新该尾注，更新后需再生成产物哈希。
- README 指定节外的历史和安全口径按要求未动；若希望 GitHub 全页与 2.0.0 一致，需要另行安排文档范围。
