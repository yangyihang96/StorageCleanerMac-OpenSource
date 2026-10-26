# 交接：D203 垃圾结果恢复 6 组，起始页仍是 4 个开关

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是 D204 的结果树（叠在 `9ba4a562` 上，见交付消息）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求

用户 10-24 同意主会话的建议（主会话转告，用户原话：“两个都照你建议的改，门禁过了就装”）。建议原文：

> 垃圾结果页现在分 4 组，开发者垃圾和待确认文件并在“系统垃圾”里；CleanMyMac 的结果页是分开显示的。我建议结果页恢复分开，只让起始页的开关按 4 项归。

要做到：

- 结果一侧恢复 6 组：系统垃圾、开发者垃圾、AI 垃圾、邮件附件、废纸篓、待确认文件。
  - 范围包括模块结果页、智能扫描清理下钻页、清理管理器左栏。
- 起始页仍是 4 个开关：系统垃圾（含开发者垃圾和待确认文件）、AI 垃圾、邮件附件、废纸篓。
  - 扫描范围、`cleanup.selected-scopes.v1` 的存取和映射都不变。

## 2. 原因

D192①（Codex A 线）为了让起始页开关、扫描进度和结果用同一套分类，改的是 `CareJunkGroup.group(...)` 本身：

- 非 AI 的开发者规则，以及下载、应用副本、用户数据三类规则，都归到“系统垃圾”；
- `SafeCleanupScanScope.includes` 直接比较这个分组的名字。

`CareJunkGroup` 里 `developerJunk`、`filesToReview` 两个类别还在，只是再也分不到，所以结果页只剩 4 组。

## 3. 改了什么

`Views/CareStudio/CareJunkGrouping.swift`：

- `group(categoryID:ruleIDs:)` 恢复 6 组：
  - 非 AI 的开发者规则 → 开发者垃圾；
  - `downloads`、`applications`、`user-data` → 待确认文件；
  - 其余和 D192 相同：废纸篓、邮件、AI 工具、其他归系统垃圾。
- 新增 `CareJunkGroup.scanScope`：每组属于哪个开关。系统垃圾、开发者垃圾、待确认文件属于“系统垃圾”开关，其余三组一一对应。
- 分组仍只看规则（D192 的做法），所以一个开关总是包含完整的几组。D192 之前“凡是永久删除的项目都归废纸篓组”的那条没有恢复，否则开关和结果组会对不上。
- 系统垃圾的一句说明恢复为 D192 之前的写法（“应用和系统反复生成的缓存与日志，清掉后会按需重建。”）：开发工具产物、待确认文件又各有自己的组。
- 扫描页的类别（`CareStudioScanCategories`）跟着回到 6 行，和 D192 之前一样。用户说的是“只让起始页的开关按 4 项归”，扫描页不是开关。

`Models/CleanupScanModels.swift`：

- `SafeCleanupScanScope.includes(rule)` 改为 `CareJunkGroup.group(for: rule).scanScope == self`。
- 每个开关扫的规则和 D192 完全相同，`CleanupScopeD192Tests` 不改也要通过。

### 跟着变的

- 结果页标题“你的 Mac 上有 X 垃圾”和智能扫描清理卡的大字，又不把待确认文件算进“垃圾”。这是 D192 之前的口径，代码（`group != .filesToReview`）没改。
- 只找到待确认文件时，智能扫描卡写“X 待确认文件 / 待查看”（第 14 条的文案表）。
- 清理管理器左栏是 6 组，D200（第 18 条）的左栏、中栏规则照样适用。
- 清理过程页的任务也按 6 组列。

## 4. 测试

- `CareStudioRenderReviewTests`：
  - `testCleaningTasksFollowThePlanOrder`、`testJunkGroupingFollowsCleanMyMacOrder` 恢复 6 组的期望；
  - 每处写了“D203＋旧值（D192）”。
- 新增 `CleanupResultGroupsD203Tests`（非窗口）：
  - 内置规则逐条：结果组符合上面的划分，规则所属的开关就是它那一组的开关（一个开关包含完整的几组）；
  - 内置规则覆盖全部 6 组；
  - 开关仍是 4 个，偏好键不变。
- `CleanupScopeD192Tests` 不改。

## 5. 验证

Xcode 27.1。树是 D204 结果加本项，在 heavy 锁里增量编译，10-24 11:59–12:02。

- 非窗口定向 11 个类，183 个测试，0 失败：CleanupResultGroupsD203Tests（新增）、CleanupScopeD192Tests（未改）、CareStudioRenderReviewTests、SmartCareTests、CareStudioJunkManagerTagTests、BrokenPreferencesRuleTests、CleanupRuleScannerTests、ScanAccessReturnTests、CleanupStoreFollowUpTests、ICloudDriveTrashTests、UIConsistencyRegressionTests。
- 截图核对（`~/Developer/.sc-build/cmm-ui-items-evidence/d20x/06-cleanup-results-*`）：“发现 2.16 GB 系统垃圾”和“发现 1.08 GB 开发者垃圾”是两张卡。D192 时是一张 3.24 GB 的系统垃圾卡。
- 没跑的：清理管理器和结果页的窗口类交给主会话的窗口全量（CareStudioWindowReviewTests、SafeCleanupLayoutTests、DesignSystemV2ReviewTests、FeatureLightfieldContractTests）。
- 没装、没提交。

## 6. 建议的 DECISIONS 写法

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D203 | 垃圾结果恢复 6 组（系统垃圾、开发者垃圾、AI 垃圾、邮件附件、废纸篓、待确认文件），结果页、智能扫描清理下钻、清理管理器左栏、扫描页类别都按 6 组；起始页仍是 D192 的 4 个开关，“系统垃圾”开关包含开发者垃圾和待确认文件，扫描范围和 `cleanup.selected-scopes.v1` 不变。分组只看规则，`CareJunkGroup.scanScope` 给出每组的开关。 | D192① 中“结果和开关共用 4 组” | 垃圾清理结果页、智能扫描清理卡与下钻、清理管理器、扫描页 |
