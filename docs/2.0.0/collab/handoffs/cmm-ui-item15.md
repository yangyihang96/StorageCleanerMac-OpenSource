# 交接：报告第四节第 15 条（智能扫描扫描中的动态拼贴）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是第 17 条的结果树（见交付消息）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求

报告原文：“扫描中：CleanMyMac 正在扫的那张卡放大到主位，其他卡跟着让位，是动态拼贴（cmm/11–13）；我们格子固定，只转小圈。”

CleanMyMac 实测（`1比1对照-20261023/cmm/11`、`12`、`13`，窗口 1200×720 点）：

- 五张卡和结果页一样，上排清理、防护、性能，下排应用、杂乱。
- 正在扫的那张卡所在的一排高 392 点，另一排高 169 点。
- 上排有卡在扫时，那张宽 599 点，另外两张各 210 点（cmm/11、12）；下排的应用在扫时，宽 697 点，杂乱 340 点，上排三张平分（cmm/13）。
- 扫描中的卡：用模块色从下往上的渐变，顶上是大字“Looking for junk…”，中间是插画，底部是当前路径或说明。
- 等待中的卡：左上角模块名，加一张很大、半透明的插画。
- 扫完的卡：和结果页一样写结果（“73 GB of junk / to clean”），右上角放插画，没有“Review”。

## 2. 改了什么（`Views/CareStudio/CareStudioSmartCare.swift`）

- `SmartCareScanningPage` 原来是 `CareStudioRunningPage` 的大插画、标题和进度环，下面加一排五张小卡（`SmartCareModuleStrip`，现已删掉）。现在改成 `CareStudioPageFrame` 加新的 `SmartCareScanningCollage`。
  - 圆按钮仍是“停止”，带进度环，按“已结束部分 ÷ 选中部分”算，和侧栏的饼一致；停止前的确认框文字和原来一样。
  - 标题栏照第 12 条显示“智能扫描”。
- `SmartCareScanningCollage.frames(count:current:in:)`：
  - 正在扫的那张卡所在的一排占 70% 高（CleanMyMac 是 70%）；
  - 在这一排里，那张卡在三张一排时占 58% 宽，在两张一排时占 67% 宽；
  - 另一排平分；没有卡在扫时，两排、各卡都平分；
  - 换到下一部分时，用 `AppMotion.standard` 动画重新排（开了“减少动态效果”就不动画）；
  - 两排至少要 380 点高，窗口矮时卡片在自己的区域里滚动，和结果页一样；
  - 探针沿用 `careStudio.tiles`、`careStudio.tiles.scroll`、`careStudio.tile.<模块>`。
- 三种卡：
  - `SmartCareScanningCard`：模块 `actionGlow` 色从上到下的渐变（10% 到 55%）；大字是这一部分在做什么（`scanningLine`，窄卡用 22 点，其余 30 点）；中间是插画；底部是垃圾扫描的当前路径，其他部分写这一部分查什么（`scope`）。
  - `SmartCareWaitingCard`：模块名加一张很大、半透明的插画；没选的部分加一行“已关闭”。
  - 扫完、跳过、失败、停止的卡：直接用第 14 条的 `SmartCareResultCard`，不带勾选和“查看”。
- 和 CleanMyMac 的差别：
  - 扫描中的卡上没有转圈，进度在圆按钮和侧栏上；
  - 圆按钮仍在页面底部，CleanMyMac 的在单独的子窗口里。

## 3. 测试

- `SmartCareTests.testTheScanningCollageGrowsThePartScanning`：
  - 上排第一张在扫时：那一排占 70%，那张卡占 58%；
  - 下排第一张在扫时：那一排占 70%，那张卡占 67%；
  - 没有在扫的：平分；
  - 每张卡都在区域内，每排都排到右边缘。
- `CareStudioModuleShellRenderTests.testRendersTheSmartCareScanForReview`：离屏渲染，扫到防护时的样子（防护放大，清理已出结果，其余等待），中英文、深浅色各一张，要设 `STORAGE_CLEANER_CARESTUDIO_EVIDENCE`。
- 会经过这一页的窗口类不用改，交主会话的窗口全量：
  - `CareStudioWindowReviewTests` 的圆按钮在窗口内、卡在网格内且在圆按钮上方；
  - 全宽侧栏旁的扫描页截图。

## 4. 验证

Xcode 27.1，树是第 17 条结果树加本批，在 heavy 锁里增量编译，10-24 02:29–02:31。

- 非窗口定向 4 个类，84 个测试，0 失败：SmartCareTests、CareStudioModuleShellRenderTests、SidebarBadgeTests、UIConsistencyRegressionTests。
- 截图核对（`~/Developer/.sc-build/cmm-ui-items-evidence/smartcare-scanning-*`，扫到防护时）：
  - 防护的卡放大在上排中间，粉色渐变，写着“正在读取浏览记录…”，底部是“浏览器里的浏览记录”；
  - 清理已扫完，显示“3.24 GB 垃圾 / 可清理”，右上角有插画；
  - 性能、应用、杂乱在等待，是淡淡的大插画；
  - 下排变矮；
  - 圆按钮写“停止”，进度环走到 1/5；
  - 标题栏是“智能扫描”。
- 没跑的：CareStudioWindowReviewTests（扫描页的圆按钮、卡片网格、全宽侧栏旁的尺寸）交主会话的窗口全量。
- 没在测试版里亲手看；没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| 第 15 条 | 智能扫描扫描中改为结果页的五张卡逐张填好：正在扫的卡所在的一排占七成高，那张卡在一排里放大，其他卡让位；扫完的卡显示结果，等待中的卡显示淡淡的大插画；进度在圆按钮上。 | 智能扫描扫描页 |
