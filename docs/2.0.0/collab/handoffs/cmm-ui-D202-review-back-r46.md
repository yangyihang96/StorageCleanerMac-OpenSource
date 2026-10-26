# 交接：D202 补二 r46 失败的修正（维护任务的返回键钩子）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话门禁树 `a94eef39`。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 失败

第 14 次的窗口全量 r46（“虚拟屏 1 · Codex”，21:06–21:21）655 过 1 败：

- 失败的是 `CareStudioNavigationTests.testSmartCaresReviewOfAppUpdatesAndMaintenanceGoesBackToSmartScan`，第 251 行：`ToolboxManagerTestHook.pressBack` 为空。
- 前半段（应用更新页）全过，截图 `w23-titlebar-smartcare-review-updater.png` 也对：“‹ Smart Scan”在标题栏带左边，侧栏选中 Smart Scan。
- 断在维护任务这一步：从智能扫描页下钻到维护任务以后，面板返回键的测试钩子为空。

## 2. 原因

产品没问题，问题出在测试钩子上：钩子只认一个持有者，换页时会被清空。

- `CareStudioCanvas` 的注释里记过同一个现象（D141 修订，10-20 实机）：
  - 一页换到另一页时，SwiftUI 可能先显示新页，旧页后走；
  - 还会短暂多出一份新页的副本，随后消失。
- `ToolboxManagerTestHook.pressBack` 原来是“出现就设、消失就清”。那份副本消失时，把钩子清空了，面板本身还在屏幕上。
- `CareStudioCanvas` 正因为这个，才按 id 记每一份的声明。
- 只在换页框架变化的场合出现。智能扫描页的外层页面框是滚动视图，维护任务页自己管滚动（`AdaptivePageViewport` 换分支）。前半段从垃圾清理到应用更新，两边都是自管滚动，没有这一换，所以没出事。
- 我这里不能跑窗口测试，所以“这一步时面板就在屏幕上”是推断，没有截图证实。r46 这一步没存图；这次加了截图和断言，见第 4 节。

## 3. 改了什么

- 新增 `ViewCopyHook`（DEBUG，`CareStudioPages.swift`）：
  - 测试钩子按每一份视图的 id 登记，最新登记且仍在屏幕上的那份作答；
  - 一份消失只撤掉自己的登记，不会清掉页面本身那份；
  - 做法和 `CareStudioCanvas` 的 claims 相同。
- `ToolboxManagerTestHook.pressBack`（面板的返回）和 `CareStudioTitleBarTestHook.pressBack`（下钻页标题栏的“‹ 智能扫描”）都改用它。
  - 后者这次没出事。它是 D202 我加的钩子，从智能扫描页直接下钻时会遇到同样的换页，所以一起改。
  - `pressStartOver`（第 12 条的旧钩子）是同一种单持有者写法，现在的测试没有出错，这次没动；以后在换页框架变化处用到它时，也该换成 `ViewCopyHook`。
- 产品代码不变：只动了 `#if DEBUG` 里的钩子。

## 4. 测试

- `CareStudioNavigationTests`（窗口类）的这一条：
  - 维护任务下钻后先存截图 `w23-smartcare-review-maintenance.png`；
  - 再断言面板在屏幕上（探针 `toolbox.manager`），失败消息带当时的路由和下钻标记；
  - 然后才按返回。
  - 再失败的话，截图和消息会直接说明当时是哪一页。
  - 其余断言不变，没有删改旧断言。
- `SmartCareIndependenceD202Tests`（非窗口）新增 `testAHookKeepsThePageWhenASecondCopyGoes`：
  - 页面和副本先后登记，副本消失后仍是页面那份；
  - 重新登记时最新的作答；
  - 全部消失后为空。

## 5. 验证

Xcode 27.1。树是 `a94eef39` 加本修正，在 heavy 锁里增量编译（含测试目标，窗口测试也编进去了），10-24 21:30–21:32。

- 6 个非窗口类，308 个测试，0 失败，1 个跳过（原来就跳过的 Setapp 只读审计）。
  - 6 个类：SmartCareIndependenceD202Tests、UIConsistencyRegressionTests、SystemUtilitySafetyTests、CareStudioToolboxWiringTests、CareStudioRenderReviewTests、SmartCareTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。
- 没跑：窗口类（没借屏）。请主会话跑：
  - `CareStudioNavigationTests`：含这一条和 D202 补一那条；两条都用 `CareStudioTitleBarTestHook.pressBack`；
  - `ToolboxWindowReviewTests`：面板版式不变，只是钩子的写法变了。
- 没装、没提交。

## 6. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| D202 补二 补记 | r46 里补二新加的窗口测试失败：从智能扫描页下钻到维护任务以后，面板返回键的测试钩子为空。原因是钩子只认一个持有者，换页时 SwiftUI 短暂显示的第二份新页消失，把它清空了（`CareStudioCanvas` 记过同一现象）。测试钩子改为按每份视图登记（`ViewCopyHook`，DEBUG），面板和下钻页标题栏的返回钩子都用它；这一步加截图和“面板在屏幕上”的断言。产品代码不变。 | `CareStudioPages`、`ToolboxManagerPanel`（DEBUG 钩子）；`CareStudioNavigationTests`、`SmartCareIndependenceD202Tests` |
