# 清理重写交接（2026-10-19）

## 目标与验收

**目标**：照竞品逆向结果重写垃圾清理全流程（智能扫描、安全清理、开发者垃圾），以及登录项与后台任务、内存；新增“释放内存”；补充规则。界面照 CleanMyMac 5 的版式，安全底线保持我们的。用户原话和决定见 `DECISIONS.md`（D141–D145），证据见 `~/Claude 好玩的/清理软件逆向-2026-10-19/汇总报告.md`。

**验收**：
- 版式、流程与 CleanMyMac 一致；
- 日间外观有独立设计；
- 清理确认、身份复核、回执、D93 用词不变；
- 受影响测试全部通过；
- 经典视图仍可用。

## 位置与基线

- 工作区：`~/Developer/sc-worktrees/cleanup-rewrite`（分支 `task/cleanup-rewrite`）。**没有提交。**
- 基线：开工时 v2.0.1 工作区的快照树 `aa88d05f4f0e9a2c03cafe9d346151c6f2dc50a9`，已放进索引，所以 `git diff` 看到的就是本任务的全部改动。另有未跟踪的新文件（`git ls-files --others --exclude-standard`）。
- 编译目录：`~/Developer/.sc-build/cleanup-rewrite/debug`。

## 改动清单

**新增**
- `Views/CareStudio/`（13 个文件）
- `Features/Memory/Infrastructure/MemoryReclaimer.swift`
- 测试：`CareStudioRenderReviewTests`、`CareStudioWindowReviewTests`、`MemoryReclaimerTests`、`CompetitorDerivedRuleTests`
- 本目录的 `DECISIONS.md` 和本文件

**修改**
- 页面：`ContentView`、`MainWorkspaceViews`、`SmartScanProgressView`、`CleanupScanViews`、`CleanupExecutionViews`、`SidebarView`、`SystemUtilitiesView`、`LightfieldStartupLandingView`
- 内存：`MemoryOptimizerService`、`SystemModels`（`MemoryOptimizationResult.reclaim`，可选字段）、`ScanStore`（`isReclaimingMemory`、`optimizeMemory` 可取消、`memoryReclaimMessage`）
- 规则：`Resources/CleanupRules.v2.json`（版本 2026.10.19.1）、`CleanupRules.baseline.json`（新增 4 行）、`Models/CleanupScanModels.swift`（Claude Code 遥测规则），并重新生成了 `docs/2.0.1/cleanup-rule-table.md`
- 测试与清单：`CleanupRuleScannerTests`（JSON 规则清单、安全规则数）、`FeatureTemplateContractTests`（经典开关）、`script/display-bound-tests.txt`（`CareStudioWindowReviewTests`，in-process）

## 集成注意

- 与 2.0.1 会话共用、可能冲突的文件：`ScanStore.swift`、`SystemModels.swift`、`SidebarView.swift`、`ContentView.swift`、`SystemUtilitiesView.swift`、`display-bound-tests.txt`。合并时以 v2.0.1 当前版本为准做三方合并（共同祖先是基线树），不要整文件覆盖。
- 规则版本号：如果 2.0.1 期间也改了规则，`rulesVersion` 取更新的日期号；基线的新增行按 ruleID 排序合并。改完后用 `STORAGE_CLEANER_RECORD_RULE_TABLE=1 swift test --filter CleanupRuleTableTests` 重新生成规则表。
- 决定已以 D141–D145 写进主表 `docs/2.0.0/collab/DECISIONS.md`（原临时编号 D-CR1–D-CR5）。

## 合并进 v2.0.1（2026-10-19 晚）

- 用户要求“在这里完成此任务：把清理重写合并进 StorageCleanerMac v2.0.1”。合并前与 2.0.1 会话约定：它不改这批文件，D141–D145 归本次，D146 起归它。
- 做法：逐文件三方合并，base = 基线树 aa88d05f，ours = v2.0.1 当前文件，theirs = cleanup-rewrite。21 个修改文件在 v2.0.1 里都和基线一致，所以没有冲突，结果就是 cleanup-rewrite 的版本；19 个新文件直接加入。写入前逐个复核过一致性。
- 原 v2.0.1 文件备份（23 个，含 DECISIONS.md、CHANGELOG.md）和本次补丁存档在 `~/Claude 好玩的/清理软件逆向-2026-10-19/合并存档/`。
- 主决定表 `docs/2.0.0/collab/DECISIONS.md` 顶部新增一节 D141–D145（即 D-CR1–D-CR5），D140 原样保留；代码注释里的临时编号已统一改成 D141–D145。CHANGELOG 2.0.1 段加了 3 条。
- 合并后验证：v2.0.1 源码在单独的编译目录 `~/Developer/.sc-build/v2.0.1-merge` 全新编译通过。全量非副屏测试 5319 个，0 失败，25 个按设计跳过。副屏复核结果见下一条。
- 合并后副屏复核（已编好的测试程序加 `--skip-build`，避免编进对方改到一半的源码）：7 个窗口类共 101 个用例，门禁日志正常，共 459 次窗口放置、没有拒绝。CareStudioWindowReviewTests、DesignSystemV2Tests、ConceptLandingNativeLayoutRegressionTests、StartupItemsDashboardContractTests 全部通过。10 个失败都是合并前就有的已知问题：9 个是虚拟屏放不下大窗口，1 个是 D118 小窗设置预览宽度 301 vs 304。合并没有引入新失败。
- 合并时没有 commit、push，也没有安装测试版；安装见下面“测试版安装（2026-10-20）”。

## 已验证

- 全量非副屏测试（`swift test --skip <副屏类>`）：5304 个，0 失败，24 个按设计跳过。之后又改了经典分支、侧栏所有权和测试宿主，补跑受影响的 1025 个：0 失败。
- 规则相关 48 个：0 失败。新增单测 16 个：0 失败。
- 离屏渲染：中文深色、中文浅色、英文深色三套，共 13 页。
- 副屏窗口截图：管理器、结果、清理中、完成页，在“虚拟屏 1 · Codex”上运行，事先已和两个会话协调。
- 17 个受影响的副屏窗口类测试（203 个用例）：27 个用例失败，归因如下。
  - 本次改动造成的 2 个，已修并在副屏重跑通过：
    - `FeatureLightfieldContractTests.testRoundSixPresentationContracts`：侧栏调用要求原样，模块色改由环境值 `careStudioSidebarModule` 传入；
    - `CareStudioWindowReviewTests` 的圆按钮测试：坐标基准误含标题栏，改为相对根视图换算。
  - 环境限制 16 个：虚拟屏 1920×1080，放不下 1470×1022（实得 1018）、1998 宽、2204×1298 和 1100 高的窗口，报错都是“布局未稳定”。涉及 `FeatureLightfieldApplicationP2Tests` 2、`FeatureLightfieldContractTests.testProductionPilots…` 1、`FeatureLightfieldPerformanceTests` 5、`FeatureTemplateContractTests` 7、`SafeCleanupLayoutTests.testLandingCardUses…` 1。卸载/提醒会话在未改动的基线上看到了同类失败。
  - 基线不同步 9 个：
    - `SmartScanScopeTests` 8 个：小窗面板改用 `IStatNumberFormat.space`（D128，1000 进制），测试仍按 `ByteFormat.string` 断言，相关文件本任务未改动，已告知 2.0.1 会话；
    - `SafeCleanupLayoutTests.testMiniSettingsPreview…` 1 个：D118 宽度 301 vs 304，卸载会话已指出。
- “释放内存”真机运行一次：当时系统压力等级是 2（其他会话在编译），按设计拒绝执行、没有占用任何内存。读数：空闲 2.17 GiB、文件缓存 6.69 GiB、压缩内存 18.18 GiB。命令：`STORAGE_CLEANER_LIVE_MEMORY_RECLAIM=1 swift test --filter MemoryReclaimerTests/testLivePushOnThisMacReportsMeasuredCounters`。

## 测试版安装（2026-10-20）

- 2.0.1 会话把 CleanMyMac 卸载/更新/提醒、D149、D150 合进 v2.0.1，跑完验证后统一安装（它报告 Debug 全量 5362 项、Release 全量 5146 项都是 0 失败），用户在该会话确认。`/Applications/测试版.app` 现为 2.0.1 build 20261019130500（10-20 00:06），含 D141–D145。旧版 20261019080930 备份在 `~/Developer/StorageCleanerMac-beta-backups.noindex/20261019T130447Z-merge/`。验证和安装记录见 `~/Documents/Claude-软件开发总交接-2026-10-03/02-内存助手测试版/2.0.1-小窗重写-20261018/10-R9复核记录.md` 文末“测试版安装（10-20）”。
- 本会话装后只读核对：版本号和签名（`codesign --verify --deep --strict`）通过。v2.0.1 里本次的 17 个新代码和测试文件、20 个修改文件与 cleanup-rewrite 逐字节一致；`SystemUtilitiesView.swift` 之后又被 2.0.1 改过，本次加的 138 行都还在。安装包里有“返回释放内存”“查看占用最多的应用”“返回卡片视图”等新界面文字；规则文件 `rulesVersion` 为 2026.10.19.1，新规则都在（Claude Code 遥测那条写在 `CleanupScanModels.swift` 里，不在 JSON）。
- 5 个问题的修正（2026-10-20）先在 cleanup-rewrite 隔离编译验证：非窗口全量 5312 个，1 个失败（`MacBenchmarkKernelTests` 限时用例在负载约 24 时报 resourceLimit，单独重跑 3/3 通过，与本次无关）；窗口类 `CareStudioNavigationTests`（新增，修正前复现失败、修正后通过）和 `CareStudioWindowReviewTests` 全过，门禁日志正常。10:46 合进 v2.0.1（13 个文件三方合并无冲突，另加 1 个测试文件），v2.0.1 上的复测（2026-10-20，由 2.0.1 会话在它的验证里一起跑）：非窗口 `CleanupStoreFollowUpTests`、`CareStudioRenderReviewTests` 全部通过（`~/Developer/.sc-build/v2.0.1/r9f/headless-1.log`）；窗口类 `CareStudioNavigationTests`、`CareStudioWindowReviewTests` 在虚拟屏 1 通过（`window-1.log`，门禁 `gate-1.jsonl`：installed 1、moved 18、placed 10，无拒绝）。

## 未完成或未验证

- 已装测试版实机核对（2026-10-20，LCU 逐页截图，深色 18 张、浅色 13 张，存于 `~/Claude 好玩的/清理软件逆向-2026-10-19/截图/已装测试版-20261020/`）发现的 5 个问题已在 2026-10-20 修正并合进 v2.0.1（见主决定表“D141 补充”“D144 补充”）：结果页“重新开始/重新扫描”无效、标题和卡片数字口径不一致、矮窗口里卡片压到圆按钮、从智能扫描切到安全清理侧栏不收、原内存页“返回释放内存”紧贴页眉指标。相关测试已跑（见“已验证”末条）；修正后的界面还没装成测试版实机看过。没处理的小问题：智能扫描/开发工具页顶部有工具栏色带而安全清理/登录项/内存页没有；内存压力升高时“释放”仍可点；经典视图侧栏仍是模块色。
- “释放内存”在压力正常时的完整施压还没有在真机上跑过（单测用的是模拟系统调用），要等机器空闲时用上面的命令再测一次。
- 上述 16 个环境失败没有在更大的显示器上复核。
- 没有提交、推送或发布。
