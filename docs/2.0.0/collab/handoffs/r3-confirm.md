# r3-confirm：统一确认页与完成页（R3-5 / D93）

工作区 `/Users/developer/Developer/sc-worktrees/r3-confirm`，分支 `task/r3-confirm`，基线集成 `f6e96574`（已含 D78、D82/D83、D84-86）。未启动 App、未扫描或删除真实文件、未读钥匙串／凭证、未安装、未 push。

## 实现

- `Models/OperationConfirmationModels.swift`（新）：
  - `OperationConfirmationFacts`：六个固定字段（动作、对象、容量、需退出的应用、恢复方式、权限覆盖），工厂 `cleanupPlan`／`cleanupPlanItems`、`uninstall`、`fileAnalysis`、`browserHistory`；`plainText` 供系统确认框使用。名单超过 3 个写“等 N 个”。
  - `OperationCompletionTally`：完成／跳过／失败／待核实四组与容量口径，来源 `CleanReport`、`FileAnalysisTrashOutcome`、`BrowserPrivacyProcessingReport`。
  - `CleanupPreselectionReason`、`CleanupRuleExplanation`（属于／处理后影响／预选原因，D82 来源，缺失时保守文案）、`OperationQuitNotice`（勾选时提示需退出的应用）、`OperationPermissionCoverage`。
- `Views/DesignSystem/OperationConfirmationViews.swift`（新）：`OperationConfirmationFactsView`（字段区上限 240pt，超出在面板内滚动；对象清单可展开，最高 160pt）、`OperationCompletionTallyView`（四组、容量行、可展开逐项原因）、`CleanupRuleExplanationView`。只用设计令牌，不用小字体覆盖、`minimumScaleFactor`、borderless 按钮。
- `CleanupScanModels.swift`：`preselectionExplanationText` 改为由 `preselectionReason` 派生，中文文本与判断顺序不变（D82 测试原样通过）。
- `ScanStore.swift`、执行器、计划构建、`Features/AppUpdates/**`、菜单栏、规则 JSON 均未改。

## 各页现状盘点：改前／改后字段对照

| 页面 | 改前确认页 | 改后确认页（新增） | 改前完成页 | 改后完成页（新增） |
|---|---|---|---|---|
| 安全清理／开发工具与产物／智能扫描结果（共用 `CleanupPlanConfirmationSheet`、`SmartScanCleanupCompletedPage`、`CleanupV2OperationOverlay`） | 项目数、将移入废纸篓体积、永久删除体积、检查通过数；黄／红／清空废纸篓分区与确认勾选；跳过项与“正常退出并清理” | 六字段面板：动作（移到废纸篓／隔离区／永久删除）、对象（通过检查的数量＋清单，未通过写“不会执行：原因”）、容量（本地占用，拆分废纸篓／永久删除口径）、需退出的应用（来自冻结计划的退出选项）、恢复方式、权限覆盖（`scanReadinessSummary`） | 原操作移走体积、已移动、跳过／失败、永久删除；`CleanupReportIssueList` 两组 | 四组统计（完成／跳过／失败／待核实）＋容量行（“已移到废纸篓 X（未释放…）”“实际释放 X（永久删除并回读确认）”、回执不完整提示）；逐项原因沿用原 IssueList，不重复 |
| 结果行（`CleanupScanViews`：lightfield 绿色分类与旧版智能扫描／开发工具列表） | 名称、路径、大小、风险标签；D82 字段未接入视图 | 行详情首项“属于 X”，悬停说明含三段；详情弹层 `CleanupRuleExplanationView`；旧版行加“属于 X · 预选原因”；勾选了所属应用运行中的项目时即时警示 | — | — |
| 卸载（含残留，`UninstallPreviewSheet`） | 已选 N 项、字节、“清空前不释放空间” | 六字段（卸载＋移到废纸篓、应用本体＋关联项、未知大小写“至少”、运行中的应用名、恢复、权限） | 逐项 outcome 文本 | 四组统计＋容量口径 |
| 重复文件（`DuplicateCleanupConfirmationSheet`、报告面板） | 可执行／跳过数、保留／移动路径分组 | 六字段（对象清单由原分组承担，面板不重复展开） | 移动／跳过／失败文字 | 四组统计＋可展开逐项原因 |
| 文件分析移到废纸篓（`FileAnalysisTrashReviewSheet`、`FileAnalysisTrashBar`、lightfield 操作详情） | N 项可移、合计、阻止原因、说明行 | 六字段（阻止项计“不会执行”、运行中的应用、外部卷废纸篓恢复方式、完全磁盘访问探针） | “已移到废纸篓 N 项”、前 3 个未移动原因 | 四组统计＋容量口径；lightfield 详情可展开逐项原因 |
| 浏览器隐私历史删除（`BrowserPrivacyRecordResultsView`） | 系统确认框纯文本（删除／运行中／手动部分、备份说明） | 两种确认框正文开头都是六字段文本（记录条数、不涉及磁盘空间、运行中的浏览器、备份恢复、完全磁盘访问）；所选记录所在浏览器运行中时在页面即时提示 | `BrowserPrivacyProcessingReportView` 摘要 | 四组统计（完成只计回读确认删除的记录）＋“删除浏览记录不涉及释放磁盘空间” |

所有页面原有文字与契约字符串保留；新增内容不出现“已释放”误称（永久删除的容量行写“实际释放”且仅在回读确认后计入）。

## 测试

- 新增 `OperationConfirmationModelTests`（15 项）：四组计数与原因、仅移到废纸篓时不出现“已释放／实际释放”、恢复／隔离区／回执不完整、文件分析与浏览器统计、七页六字段齐全且英文无中文字符、计划拆分与跳过原因、权限覆盖映射、卸载／文件分析／浏览器字段、勾选时退出提示、规则说明来源与回退、预选原因与 D82 中文一致、名单缩写。
- 新增 `OperationConfirmationContractTests`（5 项）：七页源码接入契约、完成页无 `"已释放` 文案、结果行与勾选提示两处接入、共享视图令牌守卫、最坏情况下中英文在 416／430pt 宽的 `NSHostingView` 高度上限。
- 定向 48 个类（`~/Developer/.sc-build/r3-confirm/targeted-classes.txt`，含 UIConsistencyRegressionTests、TestPreferenceHygieneTests）：870 项，0 失败，2 跳过（原有跳过）。
- Debug `--build-tests` exit 0；Release `--build-tests -enable-testing` exit 0（511.9 s，scratch `release`）。Release 之后只在契约测试里加了两条源码断言，Debug 重建与定向复跑通过，Release 未重跑。

## 反证

共 25 条（`~/Developer/.sc-build/r3-confirm/counterexamples.json`，结果 `counterexamples-results.json`）。每条：逐字替换 → `--build-tests` → 定向 filter 必须失败 → 还原原文 → 全部完成后重建并复跑全部 filter，exit 0；工作区与反证前一致。

| ID | 类别 | 文件 | Filter | 结果 |
|---|---|---|---|---|
| `trash-counted-as-released` | capacity-semantics | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testReportTallyCountsFourBucketsAndOnlyReadBackDeletionsAreFreed` | RED |
| `unverified-receipt-as-completed` | bucket-mapping | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testReportTallyCountsFourBucketsAndOnlyReadBackDeletionsAreFreed` | RED |
| `restored-still-counted-in-trash` | capacity-semantics | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testRestoredQuarantinedAndUnsavedReceiptsAreNotCountedAsTrash` | RED |
| `unknown-outcome-as-failed` | bucket-mapping | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testReportTallyCountsFourBucketsAndOnlyReadBackDeletionsAreFreed` | RED |
| `not-processed-as-completed` | bucket-mapping | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testReportTallyCountsFourBucketsAndOnlyReadBackDeletionsAreFreed` | RED |
| `trash-line-says-freed` | wording | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testTrashOnlyCompletionNeverSaysFreed` | RED |
| `receipt-incomplete-dropped` | bucket-mapping | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testRestoredQuarantinedAndUnsavedReceiptsAreNotCountedAsTrash` | RED |
| `file-analysis-review-skips-dropped` | bucket-mapping | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testFileAnalysisTallyAddsReviewSkipsAndWorksWithoutReceipt` | RED |
| `browser-counts-unverified-records` | bucket-mapping | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testBrowserTallyMapsOutcomesAndNeverTalksAboutDiskSpace` | RED |
| `browser-indeterminate-as-completed` | bucket-mapping | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testBrowserTallyMapsOutcomesAndNeverTalksAboutDiskSpace` | RED |
| `plan-counts-preflight-skips` | confirmation-fields | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testCleanupPlanFactsSplitTrashFromPermanentDeletionAndExplainSkips` | RED |
| `plan-hides-permanent-deletion` | confirmation-fields | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testCleanupPlanFactsSplitTrashFromPermanentDeletionAndExplainSkips` | RED |
| `permission-misses-blocked-locations` | confirmation-fields | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testPermissionCoverageSaysWhatIsSkippedWithoutFullDiskAccess` | RED |
| `quit-notice-never-shown` | quit-notice | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testRunningOwnerIsNamedWhenTheRowIsChecked` | RED |
| `impact-fallback-skipped` | rule-provenance | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testRuleExplanationUsesProvenanceAndFallsBackConservatively` | RED |
| `running-owner-reason-lost` | rule-provenance | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testRuleExplanationUsesProvenanceAndFallsBackConservatively` | RED |
| `uninstall-unknown-size-not-lower-bound` | confirmation-fields | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testUninstallFactsNameTheRunningAppAndKeepUnknownSizesAsLowerBound` | RED |
| `file-analysis-blocked-not-counted` | confirmation-fields | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testFileAnalysisFactsCountBlockedItemsAndNameRunningApps` | RED |
| `browser-claims-disk-space` | capacity-semantics | `OperationConfirmationModels.swift` | `OperationConfirmationModelTests/testBrowserFactsUseRecordsBackupRecoveryAndNoDiskSpace` | RED |
| `plan-sheet-facts-removed` | page-contract | `CleanupExecutionViews.swift` | `OperationConfirmationContractTests/testCleanupPlanSheetAndCompletionPagesUseSharedModel` | RED |
| `duplicate-sheet-facts-removed` | page-contract | `SystemUtilitiesView.swift` | `OperationConfirmationContractTests/testUninstallDuplicateFileAnalysisAndBrowserPagesUseSharedModel` | RED |
| `browser-report-tally-removed` | page-contract | `BrowserPrivacyRecordResultsView.swift` | `OperationConfirmationContractTests/testUninstallDuplicateFileAnalysisAndBrowserPagesUseSharedModel` | RED |
| `result-row-explanation-removed` | rule-provenance | `CleanupScanViews.swift` | `OperationConfirmationContractTests/testScanResultRowsExplainRuleAndWarnAboutRunningOwnersOnSelection` | RED |
| `facts-scroll-fallback-removed` | layout-D77 | `OperationConfirmationViews.swift` | `OperationConfirmationContractTests/testSharedViewsKeepDesignTokensAndNoFreedWording` | RED |
| `facts-unbounded-height` | layout-D77 | `OperationConfirmationViews.swift` | `OperationConfirmationContractTests/testWorstCaseLayoutsStayBoundedAtSheetWidths` | RED |

首轮第 24 条（去掉字段区滚动后备）**未被抓到**：`frame(maxHeight:)` 仍限住高度，内容被裁切而 `fittingSize` 测不出。已在契约测试补充滚动后备与高度上限的源码断言，并新增“去掉高度上限”一条，两条复跑均 RED。

## 残余

- 安全清理、开发工具与智能扫描共用同一张冻结计划确认表；`OperationSurface.inferred` 只能区分开发工具（全部 `developer.` 规则）与重复文件，智能扫描的计划显示为安全清理口径。字段内容一致，只是 surface 标签不区分。
- 规则库的处理影响说明只有中文；英文界面使用保守的通用说明（`usesImpactFallback` 为 false 但内容是通用文案）。
- 1280×763 验证是组件级 `NSHostingView` 高度测量，没有启动 App 截取整张表单；原确认表在大量黄／红分区时本已接近上限，新增面板最多增加约 300pt（字段区超出 240pt 时滚动）。需要主会话在视觉验收时实测最坏情况。
- 卸载页运行中检测用 `NSRunningApplication` 按 Bundle ID 判断，只在打开预览时计算；预览期间新启动的应用以执行前检查为准。
- 文件分析的权限覆盖只读一次完全磁盘访问探针，不列出具体受限位置。

## 修复轮 1（独立复核 `review-claude.md`：P1×2、P2×10 全部处理）

先 `git merge integration/2.0.0-beta`（带入 D87/D88；`DECISIONS.md` 用 `resolve-decisions.py ours-first` 解决，D93 在上），再按复核逐项修复。执行器计数语义、ScanStore、菜单栏与 AppUpdates 未改；未启动 App、未做真实清理。

| 编号 | 修复 |
|---|---|
| P1-1 | “对象”有不会执行项时写“共 N 项：R 项将执行，M 项不会执行（原因见清单）”；`readyCount` 与表头“检查通过”、文件分析表头的可移数量同数。计划确认表头“项目”改为全部计划项。 |
| P1-2 | 确认页：重复文件（`verifiedDuplicateEvidence`，移到废纸篓）与文件分析硬链接设 `physicalReleaseUnknown`，写“清空废纸篓后最多释放 X，可回收量待确认”，不再写“至少”（“至少”只留给大小未知）。完成页：沿用执行器 `reclaimableAfterEmptyingTrashBytes == nil`，文件分析用新增只读字段 `FileAnalysisTrashOutcome.otherHardLinkPaths`，写“最多释放 X，可回收量待确认”。 |
| P2-1 | 每页一种单位（`OperationByteStyle`：清理计划、重复文件、卸载、回执页用 `ByteFormat.string`，文件分析用 `storageString`）；计划确认表头的移入／永久删除体积与“清空后最多可释放”改用面板同一组（只算通过检查的项目）；完成页另列“已移动但结果待核实”“已恢复到原位置”，各行加起来等于“原操作移走体积”。 |
| P2-2 | 恢复结果 `outcomeUnknown` 或恢复回执保存失败的项目归入待核实，不计入已移到废纸篓；恢复回执失败时提示回执不完整。 |
| P2-3 | 新增 `OperationCompletionTally(uninstall:app:appIsRunning:)`：`changedSinceScan` 且应用正在运行时写“跳过（应用正在运行）”；其余拒绝用 `UninstallPresentation.recordLabel`。 |
| P2-4 | 新增 `CleanupImpactText` 英文译文表（11 条，覆盖全部已加载规则，测试核对）；无译文时用不含“未登记”的英文通用说明。 |
| P2-5 | `OperationQuitNotice.runningBrowserNames` 只看可直接删除（有 locator）的记录，页面提示与确认字段共用。 |
| P2-6 | lightfield 单行详情改由 `CleanupRuleExplanation.lightfieldDetail` 生成：重建代价提示 → 所属状态 → “属于 X” → 路径。 |
| P2-7 | `OperationCompletionTallyView(showsReceiptNote:)`；文件分析操作条、lightfield 文件分析、智能扫描完成页、卸载结果页自带回执提示，统计里不再重复。 |
| P2-8 | `OperationSurface.inferred(for:session:)` 按计划所属会话的 `smartScanScopes` 判断智能扫描；“七页都有”的断言改为与 `allCases` 完全相等，且各页 surface 都由推断得出。 |
| P2-9 | 新增模型级测试（真实 `VerifiedDuplicateCleanPlanBuilder` 计划＋`CleanPreflightReport`、按执行器口径填写 summary 的回执、`UninstallErrorEvidence.codes` 生成的真实失败码、带／不带 locator 的 `BrowserPrivacyRecord`、`CleanupRuleSetLoader.loadBundled()`），断言完整字符串和数值；浏览器夹具改为 deleted 条目全部回读确认、合计等于所选条数；版式测试加 480pt 宽和修复后最坏字段（拆分对象、两条警示、“最多”容量），阈值未放宽。 |
| P2-10 | 卸载勾选 D87“含个人资料／含镜像与数据卷”行时，“对象”字段追加警示（要求先备份）并标黄，清单条目也带标签。 |

### 验证

- Debug `--build-tests` exit 0；定向 58 类（`targeted-classes.txt` 新增 11 个卸载／重复文件／执行安全／版式相关类）：992 项，0 失败，3 跳过（原有）。日志 `logs/fix1-targeted.log`。
- `OperationConfirmationModelTests` 26 项（新增 11 项）、`OperationConfirmationContractTests` 5 项全过。
- 反证：`counterexamples.json` 改为 `{"mutations":[…]}`，共 42 条。本轮新增 17 条（P1-1×2、P1-2×5、P2-1×2、P2-2×2、P2-3、P2-4×2、P2-5、P2-6、P2-10）并更新 2 条锚点已变化的旧条目（`trash-line-says-freed`、`receipt-incomplete-dropped`），用 `run-mutations.py` 跑这 19 条：19/19 RED（`logs/mutations-fix1/summary.json`）。其余 23 条旧条目锚点仍逐字存在、未重跑。还原后重建并复跑定向测试全绿。
- Release `--build-tests -enable-testing` exit 0（502.1 s），之后删除 `release` 目录。

### 残余

- 卸载完成页“应用正在运行”按显示结果时的运行状态判断；用户在执行后、查看结果前退出应用时，显示为卸载自己的失败原因（“扫描后已变化或正在运行”）。
- 英文译文表需随规则库新增的影响说明同步；`testEveryRecordedImpactHasAnEnglishText` 会在缺译文时失败。
- 仍未做 1280×763 整表截图；组件级高度测量已覆盖 416／480pt。

## 修复轮 2（复核轮 2：P2-11、P2-12）

只改计划确认表与共享确认模型；ScanStore、执行器语义未改；未启动 App，未接触真实数据。

| 编号 | 修复 |
|---|---|
| P2-11 | `CleanupPlanConfirmationSheet.body` 开头 `let facts = confirmationFacts`，每次刷新只构建一次（以前 4 次，每次都查询运行中应用）；`cleanupPlanItems` 改为先建 `Set(planItems.map(\.id))` 再过滤跳过 ID，O(S·N) → O(S+N)。 |
| P2-12 | 标题、表头、面板统一为“全部计划项＋将执行几项”。新增 `OperationConfirmationFacts.cleanupPlanTitle`：“清理 N 个项目（将执行 R 项）？”／“清理 N 个项目并清空废纸篓（将执行 R 项）？”／“清空废纸篓：N 个项目？”，N 为全部计划项（含清空废纸篓条目），与“对象”字段的“共 N 项”一致。表头改为“项目 N”“将执行 R”（`facts.readyCount`，原为“检查通过” `preflight.readyCount`）。新增 `cleanupTrashReleaseNote`：移入项全部不会执行时写“移到废纸篓的项目都不会执行，本次不会移动任何项目。”，不再显示“最多可释放 0 B”。中英文同步。 |

### 验证

- Debug `--build-tests` exit 0；定向类（`targeted-classes.txt`）995 项，0 失败，3 跳过（原有）。日志 `logs/fix2-test.log`。
- 新增模型测试 3 项：标题／表头／对象同口径（中英）、移入项全跳过时的提示、4000 项计划含 600 个跳过和 200 个外来 ID 的计数（无计时断言）。契约测试：`confirmationFacts` 在表内只定义一次、读取一次；模型用 Set 过滤。`UIConsistencyRegressionTests` 中释放提示的源码断言改为指向模型与 `cleanupTrashReleaseNote` 调用（文案未变）。
- 反证：`counterexamples.json` 新增 6 条（共 48 条；本轮子集另存 `counterexamples-fix2.json`）：P2-11×2、P2-12×4。`run-mutations.py` 跑这 6 条，6/6 RED（`logs/mutations-fix2/summary.json`）。还原后重建，复跑三类 80 项全绿。

### 残余

- `dispositionSummary`（“选中项目将移入废纸篓…”）在移入项全部跳过时仍按计划描述，没有改成按将执行项描述；下方释放提示已写明不会移动任何项目。
- P2-11 的“只算一次”由源码契约约束，没有运行时计数或计时测试。
