# 交接：操作没能开始时，结果页不再说“有些没能移走”“文件在废纸篓里”

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话工作区快照 `765f53ae`（`35f6b33a` 加 DECISIONS“D202 补二”一行）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 问题

主会话在第 13 次上误点时发现（10-24，没有任何文件被动）：

- 应用管理页在后台任务忙时触发“卸载”或“移除”。当时应用页的首页扫描正在查更新，持有 `.appUpdates` 租约。
- 应用日志写的是“无法开始：未能完成操作。（StorageCleanerMac.HeavyWorkCoordinator.Error错误0。）”。
- 结果页却写“有些文件没能移走 / 可能有应用还在用这些文件……”，底部写“文件在废纸篓里 · 可在‘操作记录’恢复”。

## 2. 原因

`ApplicationsManagerModel.startRemoval`：

- `withLease(owner: .cleanup)` 拿租约失败时抛出 `HeavyWorkCoordinator.Error.busy`。
- catch 里造了一条假结果：标题“无法开始”，失败 1 项，日志是 `error.localizedDescription`。于是结果页按“部分失败”出文案。
- 底部那句“文件在废纸篓里”是写死的，不看到底移没移。
- 失败后照常走完成流程：清空勾选、重扫残留。用户想等别的任务结束后重试，得从头再选。
- `HeavyWorkCoordinator.Error` 没有可读说法（不是 `LocalizedError`），所以日志里出现“错误0”。

## 3. 改了什么

### 3.1 应用管理（`ApplicationsManagerModel.swift`、`CareStudioApplications.swift`）

- 新增 `startFailure`：没能开始的原因。拿租约是唯一会抛错的地方，而且在处理第一项之前，所以进到 catch 就是一项都没动。
- 没能开始时：
  - 记下原因，进完成页，不造假结果，不清勾选，不重扫；
  - 标题“没能开始”；
  - 说明是原因加“没有移动任何文件，选中的项目都还在。”；忙时原因是现有的说法“正在进行应用更新，请等待完成或取消后再试。”；
  - 不显示成功标记，不播放清倒废纸篓的声音；
  - 只有一个“返回”，回到列表，勾选都在；不显示“应用日志”，因为什么都没跑。
- 底部角注改为看结果：确有文件移入废纸篓时才写“文件在废纸篓里 · 可在‘操作记录’恢复”，否则写“没有移动任何文件”。
  - 这也修正了真失败但一项都没移走时的同一句假话。
- 正常完成、部分失败的标题和说明都不变。

### 3.2 错误的可读说法（`HeavyWorkActivityStore.swift`、`FileContentReadGuard.swift`）

- `HeavyWorkCoordinator.Error` 实现 `LocalizedError`：
  - 忙：用现有的 `HeavyWorkActivityStore.conflictMessage`，如“正在进行应用更新，请等待完成或取消后再试。”；
  - 凭证失效：用 `ScanStore` 里现有的“操作安全凭证已失效，未继续执行。”。
- 错误域和错误码不变，“详情”里仍只写代码（`FileAnalysisTrashFollowupPresentationTests` 不受影响，照样通过）。
- 这样所有直接显示这个错误的地方都变成人话：旧版卸载和关联文件清理的 `errorMessage`、系统缓存清除的结果（原来会退成“系统缓存未能全部清除”，像是清了一部分）。
- `FileContentReadError.userMessage`：遇到租约错误直接用它的说法。原来恶意软件移除时会说“无法完成文件操作，请检查访问权限和磁盘连接后重试”，把原因说错了。

## 4. 其他模块的执行结果页（按主会话要求逐个查过）

| 模块 | 拿不到租约时 | 结论 |
|---|---|---|
| 垃圾清理（含智能扫描运行） | 执行器出一份“全部失败、原因：其他任务正在运行”的报告；完成页标题“未完成”，摘要“已移走 0 · 失败 N”，角注“未移动任何文件”，问题列表写原因 | 不说移走了，也不说在废纸篓；不改 |
| 杂乱（重复文件） | 同一执行器；报告面板“移动 0，跳过 0，失败 N。尚未永久删除。”，并按原因分组 | 不改 |
| 空间地图移除 | 回到审阅，提示“正在进行……，请等待完成或取消后再试。” | 本来就对；应用页这次照它的思路 |
| 防护：浏览记录 | 不用这把租约（浏览器数据库“忙”是另一回事） | 不涉及 |
| 防护：恶意软件移除 | 提示说成权限或磁盘问题；方案保留可重试，没有假称移走 | 已随 3.2 修正 |
| 防护：最近使用记录 | “未能开始这次清理，列表未移走；请等待其他操作结束后再试。” | 本来就对 |
| 顺带看到：系统缓存清除 | 结果写“系统缓存未能全部清除” | 已随 3.2 修正 |

垃圾清理和杂乱有一处可以更准：从没开始的项目记作“失败”，没记作“未执行”。没说假话，这次不改；要改得动执行器的报告格式，影响操作记录，要的话另排。

## 5. 测试

都是非窗口测试；没有改动、删除任何旧断言。

- `ApplicationsManagerTests` 新增 `testARemovalThatCouldNotStartSaysWhyAndKeepsTheSelection`：
  - 测试里先占住 `.appUpdates` 租约，再按“卸载”；
  - 检查完成页的标题、说明、角注；没有“没能移走”“废纸篓”“HeavyWorkCoordinator”；
  - 结果列表为空，勾选保留；
  - 移动函数被调用就判失败；
  - 放开租约后“返回”回到列表，勾选还在。
- `HeavyWorkCoordinatorTests` 新增 `testRefusalsReadAsPeoplesWords`：
  - 两种错误的说法都可读；
  - 恶意软件提示用的是这个说法；
  - 错误域不变。
- `CareStudioRenderReviewTests` 新增 `testRendersApplicationsRemovalThatCouldNotStart`：离屏渲染“没能开始”一页。证据图在 `~/Developer/.sc-build/cmm-ui-items-evidence/start-failure/applications-could-not-start.png`。

## 6. 验证

Xcode 27.1。树是 `765f53ae` 加本项，在 heavy 锁里增量编译（含测试目标），10-24 18:38–18:41。

- 12 个非窗口类，337 个测试，0 失败，1 个跳过（原来就跳过的 Setapp 只读审计）。
  - 12 个类：ApplicationsManagerTests、HeavyWorkCoordinatorTests、CareStudioRenderReviewTests、FileAnalysisTrashFollowupPresentationTests、D186MalwareTrashAdapterTests、D186MalwarePresentationTests、SystemCacheClearingTests、SystemCachePresentationTests、OwnedUIFlatteningContractTests、UIConsistencyRegressionTests、SystemUtilitySafetyTests、OperationRecordLabelTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。改到的源码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项、具名颜色。
- 截图核对：标题“没能开始”，说明一段两行，只有“返回”，右下角注“没有移动任何文件”，没有成功标记。
- 没跑：窗口类。这次没改窗口里的版式，只改了文案和按钮数量。应用页的窗口检查在 `CareStudioWindowReviewTests`、`FeatureLightfieldContractTests`，主会话跑第 14 次全量时会经过。
- 没装、没提交。
- 说明：用户重启过 Mac，我放在临时目录的锁脚本和测试脚本被清掉，已照原样重建，锁规则不变。

## 7. 装机后请用 LCU 看

先说风险：这一步要靠后台任务正占着租约。如果按下时那个任务刚好结束，“移除”会真的把选中的文件移进废纸篓（可恢复，但算真实清理）。所以要先征得用户同意；不做的话，这一条只有单元测试和离屏截图覆盖。

1. 用户同意后，让应用页首页扫描跑起来（它会查更新，占住租约）。趁它没结束，在“应用管理器”里只勾一个应用的缓存，按“移除”：
   - 页面标题“没能开始”，说明“正在进行应用更新，请等待完成或取消后再试。没有移动任何文件，选中的项目都还在。”；
   - 只有“返回”，没有“应用日志”；
   - 右下角是“没有移动任何文件”。
2. 点“返回”：回到列表，刚才的勾选还在。
3. 不要在扫描结束后再按“移除”：那会真的移动文件。

## 8. 建议的 DECISIONS 写法（编号由主会话定）

| # | 决定 | 影响 |
|---|---|---|
| D20x | 执行没能开始（另一项任务占着独占租约，或另一个本软件实例在处理）时，结果页单独写“没能开始”、原因和“没有移动任何文件”，不出“有些没能移走”“文件在废纸篓里”，勾选保留以便重试。租约错误一律用人话（`HeavyWorkCoordinator.Error` 实现 `LocalizedError`，复用现有的冲突说法），恶意软件移除、系统缓存清除的提示不再把原因说成权限、磁盘或“未能全部清除”。应用页完成页的角注看实际结果。垃圾清理、杂乱、空间地图、最近使用记录查过，本来就不说假话。 | `ApplicationsManagerModel`、`CareStudioApplications`、`HeavyWorkActivityStore`、`FileContentReadGuard`；3 个测试类各新增 1 条 |
