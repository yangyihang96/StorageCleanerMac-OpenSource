# Clean Analysiser Parity Matrix

## 对标证据

- 对标名称：`storage-analyzer`（用户需求中的“Clean Analysiser”拼写变体）。
- 规范来源：[`KKKKhazix/khazix-skills/storage-analyzer`](https://github.com/KKKKhazix/khazix-skills/tree/741eb55ba5acf2050b0e209723c2985e956e4f7c/storage-analyzer)。
- 审计 Commit：`741eb55ba5acf2050b0e209723c2985e956e4f7c`（2026-08-11）；不依赖本机是否安装同名 Skill。
- `SKILL.md` SHA-256：`4b41cc77494638ee0f010f5c50b8015e4dff82e522c9184d4bbeba14b776eae4`。
- `SKILL.md` 修改时间：`2026-06-02T20:22:25+1000`。
- 已完整读取：`SKILL.md`、`references/macos.md`、`references/windows.md`、`scripts/scan.py`、`scripts/build_report.py`、`scripts/server.py`、`assets/report_template.html`。目录中没有 fixtures/examples。
- 安全边界：Skill 将黄色定义为“需人工判断”，通常仅打开审查。App 只允许 Downloads 明细显式手选；其他黄色主项目只读。按产品要求，规则明确验证的红色应用也可逐项手选、双重确认并仅移入废纸篓。App 保留比 Skill 网页脚本更严格的 Plan/Preflight/身份复核/执行后验证链。

## 对标矩阵

| 项目 | Skill 规则 | 当前 App 行为 | 目标行为 | 代码位置 | 测试 |
|---|---|---|---|---|---|
| 1. 扫描状态机 | 先扫描，再分类和展示报告 | 单一 `ScanPresentation` 控制 idle/preparing/scanning/finalizing/results/terminal | 不用互相矛盾的 Bool，状态不改变根布局 | `Models/ScanPresentationState.swift`; `Stores/ScanStore.swift` | `testSmartScanFlowUsesOneMutuallyExclusivePageInsteadOfLayeredTransitions` |
| 2. 扫描阶段 | Skill 按预定目标扫描后生成报告 | `CleanupScanPhase` 为 preparing/enumerating/finalizing | 阶段语义明确，不伪造文件级进度 | `Models/CleanupScanModels.swift`; `Services/ReadOnlyCleanupScanner.swift` | `testProgressPrebuildsEveryRuleAndOnlyUpdatesRowState` |
| 3. 规则展示顺序 | `scan.py` 用固定 macOS 目标表 | 顺序来自版本化 bundled rules | 从扫描开始到结束保持不变 | `Resources/CleanupRules.v2.json`; `progressSnapshot` | `testProgressPrebuildsEveryRuleAndOnlyUpdatesRowState` |
| 4. 扫描进度 | Skill 记录分组和容量，未定义虚假精确百分比 | App 以已完成规则/总规则表示进度 | 进度、数量、容量同一 Snapshot 发布 | `DiskScanProgress`; `ScanStore.publishMainScanProgress` | `testProgressPrebuildsEveryRuleAndOnlyUpdatesRowState` |
| 5. 结果分类 | Skill 使用绿/黄/红三级 | App 使用 `safe/reviewOnly/protected` | 分类由规则/模型输出，View 不二次猜测 | `CleanupRisk`; `ReadOnlyCleanupScanner.candidate` | `testReadOnlyFixtureProducesCategoriesRiskReasonsAndSeparateSpaceTotals` |
| 6. 风险等级 | 绿=可再生，黄=需判断，红=不建议手删 | 风险是独立字段 | 风险不再代替选择资格 | `Models/CleanupScanModels.swift` | `testStorageAnalyzerGoldenSnapshotUsesStableIdentityAndSelectsOnlyGreenByDefault` |
| 7. 颜色语义 | Skill 报告以绿/黄/红表示安全语义 | 风险图标曾受信息 Accent 影响 | safe 显式绿、review 显式黄、protected 显式红 | `CleanupRiskPresentation`; `CleanupReportSectionHeader` | `testSmartScanCleanupKeepsSquareSelectionAndDedicatedSafetyPages` |
| 8. 可选择性 | Skill 黄色需人工判断，不能当绿色自动处理 | `SelectionEligibility` 独立于 risk | 绿 `selectable`；Downloads 黄 `selectableWithReview`；其他黄只读；受验证红 `selectableWithProtectedReview` | `CleanupSelectionPolicy.eligibility` | review/protected plan tests |
| 9. 默认选择 | Skill 未定义持久或默认勾选 | `CleanupDefaultSelection` 与风险、推荐分离 | recommended `_npx` 默认选；optional `_cacache` 默认不选；黄色和红色仍需显式选择 | `CleanupDefaultSelection`; `CleanupSelection.defaults` | exact/default-selection tests |
| 10. 黄色项目 | Skill 建议先打开审查，仅已核实安全内容才可 Trash | 黄色可显式手选，默认不选 | 必须额外勾选风险确认，且只移入废纸篓 | `moveToTrashAfterReview`; `CleanupPlanConfirmationSheet` | `testReviewedYellowRequiresExplicitSelectionBeforePlanBuild`; UI contract tests |
| 11. 红色项目 | 不建议手工删除，使用系统/卸载器 | 仅重复 Bundle ID 或 Bundle ID 白名单应用可选 | 默认不选；双重确认、Preflight 和身份复核后只移入废纸篓 | `CleanupSelectionPolicy`; `CleanPlanBuilder`; `SafeCleanupExecutor` | protected application plan/allowlist tests |
| 12. 父级三态 | Skill 未定义 UI selection store | 绿、黄基于可选子项计算 checked/mixed/unchecked；红色仅逐叶选择 | 顶层快速全选只选绿色；红色不得批量默认加入 | `CleanupSelection.state`; `CleanupTriStateButton` | `testThreeStateSelectionIgnoresUnselectableCandidates` |
| 13. 结果分组 | Skill JSON 按 groups 输出 | App 为 category/subcategory/candidate | 同一稳定 rule ID 连接进度行和结果组 | `categories(from:)`; `CleanupScanCategory` | read-only fixture category assertions |
| 14. 结果排序 | Skill 按容量降序 | App 默认容量降序，路径作稳定 tie-break | 排序/过滤不改变选择 ID | `candidateSort`; `CleanupResultSort` | `testScanCapsEachRuleAtFortyLargestCandidatesAndBuildsTopFive` |
| 15. 容量统计 | macOS Skill 使用 `du -sk` | App allocated bytes 优先，logical fallback | 队列、排序、勾选和确认使用同一口径 | `ScanCandidate.estimatedSizeBytes`; `CleanupByteCount` | byte accounting and Golden tests |
| 16. 底部清理操作 | Skill 操作取决于风险和人工确认 | 仅绿色时显示“安全清理”，有黄色时显示“清理所选” | 底栏固定，容量仅统计已选可执行项 | `CleanupScanResultsView.cleanupActionBar` | `testSmartScanResultsFollowStorageAnalyzerReportOrderAndKeepCleanupBarFixed` |
| 17. 清理前确认 | Skill 铁律是先展示风险再执行 | App 已有 immutable plan + preflight + confirmation | 黄色单列数量、容量、原因、位置并要求独立勾选 | `CleanupPlanConfirmationSheet`; `ScanStore.confirmV2Cleanup` | `testSmartScanCleanupKeepsSquareSelectionAndDedicatedSafetyPages` |
| 18. 扫描中布局 | Skill 报告界面不因结果增长改变窗口 | 共享固定 Header/Content/Footer shell | 只中间规则列表独立滚动 | `SmartScanPageShell`; `SmartScanScanningPage` | `testSmartScanIdleScanningAndResultsKeepStableOuterGeometry` |
| 19. 扫描完成布局 | Skill 报告按总览/Top5/建议/三级展开 | App 保留同顺序的原生页 | 与空闲/扫描共用同一 shell，底栏不滚动 | `CleanupScanResultsView`; `SmartScanPageShell` | report-order and layout-stability tests |
| 20. 文字密度 | Skill 报告以简短行显示路径/大小/风险 | 普通扫描行 34 pt，只有当前路径行使用 44 pt | 删除重复说明，不用 scaleEffect 缩整页 | `SmartScanProgressView.swift`; `ScanProgressGroupRow` | UI consistency contracts |
| 21. 信息层级 | Skill 要求关键数据和处置建议可快速阅读 | 顶部三指标，中部规则/结果，底部操作 | 详细路径用截断 + tooltip，不重复大段文案 | `SmartScanProgressDashboard`; `CleanupCandidateRow` | UI consistency contracts |
| 22. 空状态 | Skill 无命中也生成可理解报告 | App 显示“未发现绿色候选”及分级空状态 | 空状态不改变 shell 对齐 | `resultHeaderSubtitle`; `tierSection` | UI result source contracts; layout stability test |
| 23. 错误状态 | Skill 将 denied 路径写入报告 | App 结构化 permission/issue/partial/failed | 不把权限失败显示成空成功 | `ScanIssue`; `CleanupPermissionReport`; terminal page | `testPermissionDenialIsExplicitAndNotReportedAsEmptySuccess` |
| 24. 取消扫描 | Skill CLI 未定义产品 UI 取消 | App Task 取消后只保留已完成的可信结果 | 停止任务，不伪造完成，不修改文件 | `ScanStore.cancelMainScan`; scanner cancellation checks | `testCancellationStopsFixtureScanAndReturnsOnlyCompletedReadOnlyResults` |
| 25. 重新扫描 | Skill 每次从新鲜 JSON 快照开始 | App 新 Session 重置选择，稳定 ID 仅用于当次快照协调 | 不把旧的黄色授权自动带入新扫描 | `ScanStore.startCleanupV2Scan`; `CleanupSelection.defaults` | stable-ID/default-selection tests |

## 结论

- 扫描输入、分组、阈值、容量排序和绿/黄/红语义以 `storage-analyzer` 为规格。
- Skill 未定义稳定候选 ID、默认勾选、SwiftUI 状态机或执行前文件身份链；App 以“绿色默认选择、黄色和红色默认不选”的产品策略和更严格原生安全链补齐，不伪装成 Skill 原生规则。
- 黄色手选是本轮明确产品要求；它不降低安全链，仍需显式选择、额外风险确认、Preflight、身份复核、Trash 和执行后验证。
- 红色应用手选也是明确产品要求；只接受受验证应用规则，不开放任意应用、任意路径或任意 Bundle ID。
