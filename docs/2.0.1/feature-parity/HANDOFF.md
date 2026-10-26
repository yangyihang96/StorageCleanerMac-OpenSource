# 竞品功能补齐交接（2026-10-20）

## 目标与验收

**目标**：把本机其他清理软件（腾讯柠檬 5.3.4、Mac Sai 1.21.3、PureMac 3.0.0、MacOptimizer 1.1.9）有、CleanMyMac 5.7.2 没有的功能做进来；同一功能别家做得更好的，改成更好的做法。用户原话和六条决定见 `DECISIONS.md`（临时编号 D-FP1–D-FP6），对照表见 `~/Claude 好玩的/清理软件全功能对比-2026-10-20/对比与实现计划.md`。

**验收**：每项先写测试；移动文件一律走记录式移到废纸篓（可放回），不新建删除链；不在本机做真实清理或维护；相关测试和非副屏全量通过；新面板在副屏窗口测试里不溢出。

## 位置与基线

- 工作区：`~/Developer/sc-worktrees/feature-parity`（分支 `task/feature-parity`）。**没有提交。**
- 基线：v2.0.1 工作区 2026-10-20 晚的快照树 `93483d786384b6cd9d9f1fcde250de4c6f6a9d8f`（与 CleanMyMac 界面会话 21:01:53 取的一致），已放进索引，并记在 `.git/worktrees/feature-parity/FEATURE_PARITY_BASELINE_TREE`。`git diff` 看到的就是本任务的改动，新文件看 `git ls-files --others --exclude-standard`。
- 编译目录：`~/Developer/.sc-build/feature-parity`。

## 改动清单

**新增（源码）**
- `Features/Extensions/`：`ExtensionInventoryModels`、`PluginKitListing`、`ExtensionInventoryScanner`（含 `ExtensionSigningReader`）、`ExtensionRemovalService`、`ExtensionManagerStore`
- `Features/Maintenance/`：`SystemMaintenanceModels`、`SystemMaintenanceProbes`、`SystemMaintenanceRunners`（`MailEnvelopeIndexVacuum`、`LaunchServicesRefresh`）、`SystemMaintenanceStore`
- `Features/ChatFiles/`：`ChatFilesModels`、`ChatFilesScanner`、`ChatFilesOperations`（`ChatFilesTrashService`、`ChatFilesCopyService`）、`ChatFilesStore`
- `Features/DuplicateFiles/CloneMerge/`：`APFSCloneReplacement`、`DuplicateCloneMergeService`（含 `DuplicateKeeperSuggestion`）、`DuplicateCloneMergeAction`
- `Features/ProcessNotes/SystemProcessNotes.swift`
- `Models/ToolboxOperationTitles.swift`
- `Views/Toolbox/`：`ToolboxManagerPanel`（共用审阅面板）、`ExtensionManagerPage`、`SystemMaintenancePage`、`ChatFilesPage`（含 `ChatFilesCopySheet`）、`DuplicateCloneMergeButton`（含确认面板）、`SystemProcessNoteButton`

**修改（源码与资源）**
- `Models/CleanupScanModels.swift`：`CleanupRule.contentRequirement`、`CleanupContentRequirement`、`BrokenPropertyListCheck`
- `Services/ReadOnlyCleanupScanner.swift`：内容检查、校验器约束、两个文案键
- `Models/CleanupCoverageCatalog.swift`：`brokenPreferencesRule`
- `Models/OperationConfirmationModels.swift`：影响说明译文一条
- `Models/OperationRecordPresentation.swift`、`Services/CleanupReportIndex.swift`：新操作在操作记录里的名称
- `Features/BrowserPrivacy/Providers/BrowserPrivacyProviderRegistry.swift`：QQ 浏览器
- `Resources/CleanupRules.v2.json`（规则集版本 2026.10.20.1）、`Resources/CleanupRules.baseline.json`（新规则修订 1）
- `docs/2.0.1/cleanup-rule-table.md`（重新生成，86 条）、`docs/CleanAnalysiser/Browser Privacy Parity Matrix.md`（Chromium 系 9 个）
- `script/display-bound-tests.txt`：登记 `ToolboxWindowReviewTests`（in-process）

**测试**
- 新增：`ExtensionManagerTests`、`SystemMaintenanceTests`、`SystemProcessNotesTests`、`DuplicateCloneMergeTests`、`BrokenPreferencesRuleTests`、`QQBrowserPrivacyProviderTests`、`ChatFilesTests`、`ToolboxRenderReviewTests`（离屏渲染）、`ToolboxWindowReviewTests`（副屏）、`ToolboxLiveReadOnlyTests`（本机只读核对，需 `STORAGE_CLEANER_RUN_LIVE_TOOLBOX_SCAN=1`，只打印数量和用时）
- 随改：`CompetitorDerivedRuleTests`（规则集版本）、`BrowserPrivacyHistoryProcessorTests`、`BrowserPrivacyRecordScannerTests`（Provider 数 15、必备列表加 qq-browser）、`CleanupRuleScannerTests`（需确认规则清单加 `system.broken-preferences`）

## 给接线方（CleanMyMac 界面会话）的接口

所有页面都把 `module: CareStudioModule` 从外面传入；Store 用 `ScanStore` 已有的 `heavyWorkCoordinator` 和 `heavyWorkActivityStore` 构造。

| 功能 | 入口视图 | Store / 服务 | 结果卡片数据 |
|---|---|---|---|
| 扩展（应用模块） | `ExtensionManagerPage(store:module:onBack:)` | `ExtensionManagerStore(coordinator:activityStore:)`；`scan()` | `store.summary`：`itemCount`、`movableCount`、`movableBytes`、`obsoleteCount` |
| 维护任务（性能模块） | `SystemMaintenancePage(store:module:onBack:openFreeUpMemory:)` | `SystemMaintenanceStore(coordinator:activityStore:)`；`refresh()` | `store.summary`：`runnableCount`、`recommendedCount` |
| 聊天文件（杂乱文件模块） | `ChatFilesPage(store:module:onBack:)` | `ChatFilesStore(coordinator:activityStore:)`；`scan()`（没有完全磁盘访问时 `phase == .needsFullDiskAccess`，不读） | `store.summary`：`totalBytes`、`fileCount`、`olderBytes`、`appCount` |
| 克隆合并（重复文件管理器） | `DuplicateCloneMergeButton(action:)` | `DuplicateCloneMergeAction(coordinator:activityStore:)`；`update(groups:keepers:)`；`isOffered(for:)` | `action.preview?.reclaimableBytes` |
| 保留建议 | — | `DuplicateKeeperSuggestion.rank(_:homePath:)`（带理由）、`.keeper(for:)` | — |
| 进程说明（内存、能耗页） | `SystemProcessNoteButton.forProcess(name:path:tint:openRelated:)` | `SystemProcessNotes.note(forName:path:)`、`.note(for: MemoryProcess)` | — |
| 损坏的偏好设置 | 走现有垃圾清理（类别 `system` → 系统垃圾） | 规则 `system.broken-preferences` | — |
| QQ 浏览器隐私 | 走现有浏览器隐私 | Provider `qq-browser` | — |

操作记录名称：`extensions.trash.v1`（扩展）、`duplicates.clone-merge.v1`（重复文件合并为克隆）、`chat-files.trash.v1`（聊天文件）。

## 验证情况

见同目录 `VERIFICATION.md`（全量和副屏结果补在那里）。各功能自己的测试全部通过；本机只读核对：扩展 0.6 秒列出 62 个第三方应用扩展等，维护任务 0.3 秒读完 9 项状态（只打印数量）。

## 未完成与限制

- 入口和路由等界面会话接线；合并进 v2.0.1 要和 2.0.1 会话约窗口，正式编号由它分配。
- 没装测试版；没有在本机实际运行加速邮件、刷新“打开方式”数据库、克隆合并、移到废纸篓或复制到外置盘——这些都需要用户批准。
- 需要 root 的维护任务没做（需用户单独决定）。
- 聊天软件的目录布局来自柠檬 5.3.4 的路径字符串，没有在装了这些软件的真实数据上核对过；遇到新版本布局会少列，不会多删。
