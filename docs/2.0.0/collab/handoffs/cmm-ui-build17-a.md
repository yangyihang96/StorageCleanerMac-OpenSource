# 交接：第 17 次 A 部分（D214 没能开始、D215 单个残留加入忽略列表、D216 经典列表展开的无障碍名字）

日期：2026-10-25。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是第 16 次最终门禁树 `f08697c2`。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。三项合成一个补丁。B 部分（第 4–7 项）的调查报告另交，不在这个补丁里。

## 1. D214 垃圾清理和杂乱如实说“没能开始”

### 1.1 原来

- 垃圾清理和杂乱共用 `SafeCleanupExecutor`。开始前被拒时，`terminalFailureReport` 把每一项都记成 `.failed`，失败码就是拒绝的原因。
- 开始前被拒有四种：
  - 拿不到工作租约：另一项任务占着，或另一个本软件实例在处理；
  - 计划失效：会话或规则变了、已执行过、批准的项目对不上；
  - 安全清理没启用；
  - 开始前写不进操作意图。
- 结果：
  - 垃圾清理完成页写“未完成 · 已移走 0 · 失败 N”，问题列表逐项写原因；
  - 杂乱写“已处理 0 个重复副本；项目仍可从废纸篓或隔离区恢复。”；
  - 两处都清空勾选，操作记录也记“失败”。

### 1.2 改了什么

只改报告和显示，执行逻辑不变：什么时候拒、拒了之后不动任何文件，都和原来一样。

- 报告（`CleanupExecutionModels.swift`、`SafeCleanupExecutor.swift`）：
  - `CleanReport` 加可选字段 `startRefusal: CleanFailure?`，记下为什么没开始。旧回执没有这个字段，读出来是 nil；旧版本读新回执会忽略它。
  - 开始前被拒时（`notStartedReport`，取代 `terminalFailureReport`）：每一项记 `.notProcessed`（未执行），报告的 `outcome` 仍是 `.failed`，同时写入 `startRefusal`。
  - 拿不到租约时，`detailCode` 记下是谁占着：`lease-busy:<任务>`、`instance-busy`（另一个实例）、`lock-unsafe`（操作锁检查没过）。
- 说法（`OperationResultPresentation.swift` 里新加 `CleanStartRefusalPresentation`），沿用 D205 应用管理的写法：
  - 标题“没能开始”；
  - 原因：
    - 租约被占：用现有的 `conflictMessage`，例如“正在进行应用更新，请等待完成或取消后再试。”；
    - 另一个实例在处理：用 `OperationFileLock` 现有的说法；
    - 计划失效：“这份清理计划已失效（扫描结果或规则有变化，或已经执行过），请重新扫描后再试。”；
    - 没启用：“安全清理没有启用。”；
    - 写不进记录：“无法写入操作记录，为安全起见没有开始。”；
  - 原因后面接“没有移动任何文件，选中的项目都还在。”。
- 操作记录：`OperationResultPresentation` 加可选的 `startRefusal`（同样兼容旧索引），标题写“没能开始”，摘要写“已移走 0 · 未执行 N”，不再出现“失败”。逐项写“未执行”，这是原来就有的标签。
- 垃圾清理（`CleanupExecutionViews.swift`、`CareStudioCleanupPages.swift`、`ScanStore.swift`）：
  - 完成页：
    - 标题“没能开始”，说明是原因加“没有移动任何文件，选中的项目都还在。”；
    - 不显示成功标记，不出清点、问题列表和清理详情；
    - 圆按钮写“返回”，没有“重新扫描”“恢复”“查看位置”；
    - 角注“没有移动任何文件”；
    - 智能扫描“运行”时，其他卡片的结果照常列在上面。
  - 勾选保留：执行结束后和点“返回”回到结果时，都不再把勾选重置为默认。
  - 经典版式的页面同样处理：只有“返回”，指标只写“未执行 N”。
- 杂乱（`ScanStore.swift`、`CareStudioClutter.swift`、`SystemUtilitiesView.swift`）：
  - 执行后的处理抽成 `finishVerifiedDuplicateCleanup(with:)`，可以单独测试。没开始时：不清勾选，不标记已移动，提示条写“没能开始：<原因>没有移动任何文件，选中的项目都还在。”。
  - 杂乱文件管理器列表上方出一条说明：“没能开始”加原因，带关闭按钮。重新执行或关闭后消失。提示条 2.4 秒就走，所以加了这条一直在的说明。
  - “扫描与操作详情”里的处理报告同样写“没能开始”和原因，不出“移动 0，跳过 0，失败 N”。
- 顺带受益：其他用同一执行器的地方（文件分析移到废纸篓、外接盘搬家、工具页等）开始前被拒时，结果和操作记录也写“没能开始”“未执行”，不写“失败”。

### 1.3 改了旧期望（测试里写了“D214＋旧值”和原断言）

- `CleanupExecutionSafetyTests`：重复执行同一计划。原为 `XCTAssertEqual(second.summary.failedItemCount, 1)`，现在失败 0、未执行 1、`startRefusal` 是 `.planIntegrityFailed`。
- `CleanupTrashItemIntegrationTests`：同上。原为 `secondExecution.summary.failedItemCount == 1`。
- `CleanupRuleProvenanceTests`：规则变了之后执行。原为“失败数等于项目数、第一项 `.failed(.planIntegrityFailed)`”，现在是“未执行数等于项目数、第一项 `.notProcessed`、`startRefusal` 是 `.planIntegrityFailed`”。
- 只检查 `outcome == .failed` 的那些断言不受影响（`outcome` 仍是 `.failed`）。

## 2. D215 应用管理器里单个残留文件的右键“加入忽略列表”

- `ApplicationsManagerModel.ignoreLeftovers` 本来就按资源 id 工作：
  - 按路径加入，类别“卸载”；
  - 组里剩下的照常显示，组空了一起拿出；
  - “放回原处”回到原位，勾选还原。
- 这次只接界面（`ApplicationsManagerView.swift`）：残留组展开后，每个文件行的右键菜单有“加入忽略列表”。
  - 只给残留文件行。已安装应用展开后的文件行不给：那里没有传入忽略动作，右键没有菜单。
  - 子分组标题行（如“偏好设置 2”）没加，任务书没要。
- 没改 `ApplicationsManagerModel.swift`。

## 3. D216 经典列表两处展开的无障碍名字

- 位置：`CleanupScanViews.swift` 原第 588 行“清空废纸篓 · 永久删除”、原第 629 行“扫描详情与权限”。两处都是原生 `DisclosureGroup(标题)`。
- 核对：
  - 我没有自己读真实的无障碍树。经典列表在智能扫描或垃圾清理结果页里面，那一页有默认勾选和一键执行按钮，按约定不在上面点。另外进程内的无障碍检查读不到滚动视图里的行（D193 的结论）。
  - 依据有两条：
    - 第 9 次实测（第二轮报告 5.2 第 12 条）LCU 读到这两个展开按钮没有名字，只读成“显示三角形”；
    - 现在的代码仍是同样的 `DisclosureGroup(标题)`，没改过。
- 改法：
  - 换成新的 `CleanupListDisclosure`：一个按钮，标题加行尾箭头，箭头用现有的 `FeatureLightfieldDisclosureChevron`；
  - 无障碍名字就是标题，值是“已展开/已收起”，按下切换。
  - 展开内容不变。外观从原生三角形改成和光场列表一致的行尾箭头。
- 装机后请主会话用 LCU 只读核对一次：两处的元素名字是标题，值是“已收起”。

## 4. 测试

- 新测试：
  - `CleanupExecutionSafetyTests.testABusyLeaseRefusesTheRunBeforeItsFirstItem`（非窗口）：
    - 租约被应用更新占着；不调用移动；两项都是未执行、失败 0；
    - `startRefusal` 是 `lease-busy:appUpdates`，说法是现有的冲突提示；
    - 结果标题、操作记录索引的标题都是“没能开始”，摘要没有“失败”；清点里失败 0、跳过 2；
    - 回执编码往返一致；删掉新字段的旧回执照样能读，标题“未完成”。
  - `CleanupStoreFollowUpTests.testACleanupThatCouldNotStartKeepsTheSelectionAndRecordsNotRun`（非窗口，真实的 ScanStore 流程）：
    - 先占住租约再确认清理；文件都还在；勾选保留；
    - 操作日志里的回执是未执行且带原因；
    - “返回”回到同样的行，勾选还在，可以再清理。
    - 夹具的 `scannedStore` 加了 `coordinator` 参数（默认值不变）。
  - `CleanupNotStartedD214Tests`（新的非窗口类）：
    - 每种拒绝的原因和“没有移动任何文件，选中的项目都还在。”；
    - 杂乱：没开始时勾选和报告都保留，提示条写“没能开始”；开始过的运行照旧清勾选。
  - `CareStudioRenderReviewTests.testRendersCleanupThatCouldNotStart`（非窗口，离屏渲染）：单独一页，以及智能扫描运行时带其他结果的一页。图在 `~/Developer/.sc-build/cmm-ui-items-evidence/d214/`。
  - `D207IgnoreFromManagersTests.testASingleLeftoverFileLeavesAloneOrTakesItsGroupWithIt`（非窗口）：
    - 单个文件按路径、类别“卸载”加入，名称“组名 · 文件名”；
    - 组里其余照常；放回原处回到原位，勾选还原，原来没勾的仍然没勾；
    - 组里最后一个文件带走整组，放回后组回原位；
    - 源码断言：只有残留行接了这个菜单。
  - `FeatureLightfieldComponentTests.testCleanupListDisclosuresReadTheirNamesAndStateAndPress`（窗口类，请主会话跑）：
    - 两个展开按钮的无障碍名字是标题，值“已收起”，可以按；
    - 按下后值“已展开”，内容出现，另一个仍然收着；再按收起。
- 旧断言：只改了第 1.3 节那三处，都写了编号、原断言和原因；没有删除，没有放宽。

## 5. 验证

Xcode 27.1。树是 `f08697c2` 加本补丁，在 heavy 锁里增量编译（含测试目标，窗口测试也编进去了）。最终一遍在 10-25 20:02–20:03。

- 18 个非窗口类，278 个测试，0 失败，1 个跳过（`CleanupWriteRecheckTests` 的两万文件计时测试，原来就跳过）：
  - CleanupExecutionSafetyTests、CleanupTrashItemIntegrationTests、CleanupRuleProvenanceTests、CleanupStoreFollowUpTests、CleanupNotStartedD214Tests、D207IgnoreFromManagersTests；
  - OperationRecordLabelTests、OperationConfirmationContractTests、UIConsistencyRegressionTests、CareStudioRenderReviewTests、SmartCareTests、ApplicationsManagerTests；
  - FeatureLightfieldFilesPresentationTests、CleanupWriteRecheckTests、ProjectArtifactTests、HeavyWorkCoordinatorTests、FileAnalysisTrashFollowupPresentationTests、OwnedUIFlatteningContractTests。
- 中途第一遍有 1 败：我的杂乱测试用了普通临时目录，不是操作夹具目录（`unownedPath`）。改用 `makeOperationHome` 后通过。产品代码没有为此改动。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。改到的源码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项、具名颜色。
- 离屏渲染核对：“没能开始”一页标题、原因和说明各一行，只有“返回”，右下角注“没有移动任何文件”，没有成功标记。
- 没跑：窗口类（没借屏）。请主会话跑：
  - `FeatureLightfieldComponentTests`（含 D216 新断言）；
  - `CareStudioWindowReviewTests`：清理完成页加了参数，默认外观不变；
  - `MiniWindowCleanupPresentationTests`：小窗读同一份报告，没开始时标题会是“没能开始”；
  - `SafeCleanupLayoutTests`：经典清理页。
- 实机未看：
  - “没能开始”要在租约被占时按清理才会出现，可能真的移动文件，按约定不在真机上做；
  - D215 的右键：只读实测可以在“应用管理 → 残留”里右键一个文件，加入后立刻用“放回原处”，或在设置里移除那一条；
  - D216 需要进到结果页的经典列表，按约定由主会话决定怎么只读核对。
- 没装、没提交。

## 6. 建议的 DECISIONS 写法

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D214 | **垃圾清理和杂乱开始前被拒时如实说“没能开始”**（D205 在这两处补齐）：执行器把开始前被拒的项目记成“未执行”（`.notProcessed`），不再记“失败”；报告带 `startRefusal`（拿不到租约时记下谁占着：某项任务、另一个实例、操作锁），旧回执兼容。结果页写“没能开始”、原因和“没有移动任何文件，选中的项目都还在”，不显示成功标记和清点，只有“返回”，勾选保留；杂乱管理器列表上方出同样的说明；操作记录标题写“没能开始”、摘要写“未执行 N”。执行逻辑不变。 | 开始前被拒记成“失败 N”、清空勾选、杂乱提示“已处理 0 个重复副本” | `SafeCleanupExecutor`、`CleanupExecutionModels`、`OperationResultPresentation`、`CleanupExecutionViews`、`CareStudioCleanupPages`、`CareStudioClutter`、`SystemUtilitiesView`、`ScanStore`；测试见交接第 4 节，三处旧期望写“D214＋旧值” |
| D215 | **应用管理器里单个残留文件可以右键“加入忽略列表”**（D207 补全）：按路径、类别“卸载”，组里其余照常显示，忽略的是组里最后一个文件时整组拿出；“放回原处”回到原位并还原勾选。只给残留文件行。 | D207“单个残留资源行没接” | `ApplicationsManagerView`；`D207IgnoreFromManagersTests` |
| D216 | **经典列表的两处展开（清空废纸篓、扫描详情与权限）有无障碍名字**：原生 `DisclosureGroup` 的三角形在无障碍树里没有名字（第二轮报告 5.2 第 12 条），改成标题加行尾箭头的按钮，名字就是标题，值是“已展开/已收起”。 | — | `CleanupScanViews`；`FeatureLightfieldComponentTests`（窗口类） |
