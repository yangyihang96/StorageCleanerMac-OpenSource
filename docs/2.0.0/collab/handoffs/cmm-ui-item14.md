# 交接：报告第四节第 14 条（智能扫描结果版式）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是第 16 条的结果树（见交付消息），即 `55581c6f` 加第 16 条。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求

报告原文：“智能扫描结果版式：CleanMyMac 上排 3 张、下排 2 张；用整句大字写结果，比如‘73 GB 垃圾、待清理’‘1 个威胁、待移除’‘2 个任务、待运行’；插画从卡片右上角溢出（cmm/14）。我们是左边一张大卡、右边 2×2（ours/01）。”

CleanMyMac 实测（`1比1对照-20261023/cmm/14`，窗口 1200×720 点，按像素量）：

- 卡片：
  - 上排 3 张，每张 340.5 点宽；下排 2 张，每张 519 点宽；两排都是 229 点高；
  - 卡与卡、排与排之间的间距都是 16.5 点；
  - 内容区左右各留约 31 点。
- 标题：居中，约 31 点。
- 卡内：
  - 左上角是勾选框加模块名（约 16 点）；
  - 插画在右上角，约 116×132 点可见，其余被卡片边缘裁掉；
  - 结果是一行约 32 点的大字（“73 GB of junk”），下面一行约 16 点写用途（“to clean”）；
  - 右下角是“Review”；
  - 什么都没找到的卡写“No vital updates / to install”，没有“Review”。

## 2. 改了什么（只改 `Views/CareStudio/CareStudioSmartCare.swift`）

- `SmartCareCardSummary`：
  - 原来是数值加说明（`value` + `caption`，如“11.6 GB”+“垃圾 · 可清理”），改成一行大字加用途（`headline` + `subtitle`，如“11.6 GB 垃圾”+“可清理”）；
  - 加 `reviews`：没找到东西、模块关着时没有“查看”；
  - `line` 把两行接成一行，给扫描页的小卡用，文字和原来相同，例如“3.2 GB 垃圾 · 可清理”。
- 文案按 CleanMyMac 的句式（数量加名词 / 用途）：

  | 模块 | 找到时 | 没找到时 |
  |---|---|---|
  | 清理 | X 垃圾 / 可清理；X 待确认文件 / 待查看 | 没有垃圾 / 不用清理 |
  | 防护 | N 条浏览记录 / 待查看 | 没有浏览记录 / 不用清理 |
  | 性能 | N 个维护任务 / 可运行；N 个登录项 / 待查看 | 没有维护任务 / 不用运行 |
  | 应用 | N 个更新 / 可安装 | 没有更新 / 不用安装 |
  | 杂乱 | N 组重复文件 / 待查看 | 没有重复文件 / 不用处理 |

  - 英文的单复数用 `L10n.englishCount`。
  - 原来的“性能良好”“所有应用都是最新版本”“没有找到内容完全相同的文件”“很干净，没有发现垃圾”换成上表的写法。
  - 读不到结果的几种（没有结果、需要完全磁盘访问权限、没有读到更新、跳过、失败、已停止）只有一行，仍有“查看”。
- 版式：
  - 新的 `SmartCareResultsGrid`：上排前三张，下排其余两张，两排一样高，最高 232 点（CleanMyMac 是 229 点），最低 168 点；放不下时在自己的区域里滚动，不压到圆按钮，和模块结果页的 `CareStudioTileGrid` 一样。
  - 探针沿用 `careStudio.tiles`、`careStudio.tiles.scroll`、`careStudio.tile.<模块>`，窗口检查“卡片在网格内、不碰圆按钮”继续有效。插画会伸出卡片（被裁掉），所以插画上不加 `careStudio.tile.` 开头的探针。
- 卡片 `SmartCareResultCard`：
  - 左上角：勾选框（只有能“运行”的清理、性能，照 D168）加模块名，16 点 medium；
  - 右上角：插画，边长取卡片高度的 0.64 倍和宽度的 0.44 倍中较小的一个，右边伸出 18%、上边伸出 12%，被卡片圆角裁掉；
  - 左下角：大字 30 点 medium（CleanMyMac 约 32 点），最多两行，进场时数字递增（沿用 `CareStudioCountingText`）；下面是 15 点的用途；
  - 右下角：“查看”胶囊按钮。
  - 卡片底色、细边、圆角、内边距和悬停效果都沿用 `CareStudioTile`。
- 标题：原来 26 点 light、靠左，改成和模块结果页标题一样的 24 点 semibold、居中。
- 原来清理卡上“勾选的垃圾会移到废纸篓，可以恢复。”这行说明拿掉了。CleanMyMac 的卡上没有说明，页面底部的安全说明“清理前逐项确认 · 文件移入废纸篓可恢复”还在。
- 和 CleanMyMac 的差别：
  - 防护卡没有勾选框，因为我们的“运行”不处理防护（D168）。
  - 字号用我们自己的结果页规格（标题 24 点，大字 30 点）。

## 3. 测试

- `SmartCareTests`：
  - `testTheCleanupCardCountsLikeTheJunkResults`：断言改为大字和用途，测试里写了“第 14 条 + 旧断言 + 原因”；
  - 新增 `testACardThatFoundNothingSaysSoWithoutReview`；
  - 新增 `testTheResultsGridPutsThreeCardsAboveAndTwoBelow`：上 3 下 2、等高、不超过最高行高，窗口矮时保持最低高度并滚动。
- `CareStudioModuleShellRenderTests.testRendersTheSmartCareResultsForReview`：离屏渲染，不在 D106 窗口名单里。截图分中文深色、英文深色、中文浅色，各有正常和矮窗口两种，要设 `STORAGE_CLEANER_CARESTUDIO_EVIDENCE`。
- 会经过这一页的窗口类不用改，交主会话的窗口全量：`CareStudioWindowReviewTests` 里智能扫描结果页的截图和“卡片在网格内、不碰圆按钮”检查。

## 4. 验证

Xcode 27.1，树是第 16 条结果树加本批，在 heavy 锁里增量编译，10-24 02:24–02:26。

- 非窗口定向 5 个类，90 个测试，0 失败：SmartCareTests、CareStudioModuleShellRenderTests、SystemCachePresentationTests、UIConsistencyRegressionTests、CareStudioRenderReviewTests。
- 截图核对（`~/Developer/.sc-build/cmm-ui-items-evidence/smartcare-results-*`）：
  - 上 3 下 2；
  - “3.24 GB 垃圾 / 可清理”“14 条浏览记录 / 待查看”带“查看”，“没有维护任务 / 不用运行”“没有重复文件 / 不用处理”没有“查看”，“没有读到更新”带“查看”；
  - 插画从右上角伸出、被卡片边缘裁掉；标题居中；
  - 矮窗口时卡片在自己的区域里滚动。
- 没跑的：CareStudioWindowReviewTests（智能扫描结果页的圆按钮、卡片网格检查）交主会话的窗口全量。
- 没在测试版里亲手看；没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| 第 14 条 | 智能扫描结果页照 CleanMyMac：上排 3 张、下排 2 张，两排一样高；卡上是模块名、右上角伸出被裁的插画、一行大字的结果加一行用途；没找到东西的卡没有“查看”；标题居中。 | 智能扫描结果页、扫描页小卡的文字 |
