# 交接：D202 补二 应用卡和维护任务的“查看”也能回到智能扫描

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话门禁树 `8c95cdc5`（D202 补一已合入）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 缺口

第 13 次装机后，主会话用 LCU 实测（10-24）发现：

- 应用卡的“查看”打开“应用更新”工具页，侧栏选中智能扫描，但页面上没有“‹ 智能扫描”，只能点侧栏回去。
- 原因：返回键挂在 studio 结果页的页框上（`CareStudioPageFrame` 的“重新开始”位置）。应用更新的结果页是 Lightfield 页面，管理页是它自己的版式，都不经过这个页框。

我查其余“查看”入口时发现同类的第二处：

- 性能卡有建议的维护任务时，“查看”打开“维护任务”（`SystemMaintenancePage`，管理器面板）。
- 面板自己的“‹ 返回”去的是性能页（`showFilter(.startup)`）：下钻结束，落在性能首页，回不到智能扫描。
- 主会话这次实测时没有建议任务，所以打开的是登录项页，没遇到这一处。

其余三处“查看”（登录项、防护、重复文件）都是 studio 结果页，返回键已在。

## 2. 选哪种做法

主会话问：给应用更新页加返回，还是改成打开应用管理的结果页？选前者，理由：

- CleanMyMac 的做法（`CMM模块规格.md` Smart Care 第 5 条）：从卡片点 Review，进入对应模块的管理器，只改选择、不执行。
- 智能扫描的应用卡只查更新，CMM 对应的是 “Vital Updates”，管理器是应用更新程序。我们的应用更新页就是这一块。
- 应用管理的结果页要应用管理自己先读一遍应用清单，智能扫描没读。改去那一页，看到的不是智能扫描的结果。
- 应用更新页本来就显示最近一次检查（D202 第 6 节取舍：“更新页（工具页）仍显示最近一次检查”）。

## 3. 改了什么

### 3.1 应用更新页（`Views/CareStudio/CareStudioPages.swift`、`Features/AppUpdates/Views/AppUpdatesView.swift`）

- 新增 `careStudioReviewBack(_:)`：下钻时，在窗口标题栏带的左边画“‹ 智能扫描”。
  - 位置、外观、探针（`careStudio.titleBar.back`）、读屏名、测试钩子，都和 studio 结果页的返回键相同。
  - 直接复用 `CareStudioTitleBarRow`：只放返回键，不放标题。
  - 没有标题栏带（全屏）时，返回键自己在页面顶部占一行（28 点），和 studio 页一样。这一行下面是外层 `MainContentHost` 画的模块渐变。
  - 它把下钻的环境值对页面内部清掉。所以页面里若有 studio 页框，也不会再画第二个返回键。
- `AppUpdaterView` 最外层套上 `.careStudioReviewBack(.updater)`。结果、管理、扫描中、首页、日志各阶段都有返回键。
- 不在下钻时，这一页的样子和以前完全一样。

### 3.2 维护任务（`Views/Toolbox/ToolboxManagerPanel.swift`）

- 面板的“‹ 返回”和 Esc：下钻时回智能扫描，其他时候照旧回模块页（`back` = `reviewReturn?.action ?? onBack`）。
- 字样仍是“返回”，和智能扫描里垃圾管理器的返回键一样。下钻时读屏名改为“返回智能扫描”。
- 加了 DEBUG 测试钩子 `ToolboxManagerTestHook.pressBack`，和 `CareStudioTitleBarTestHook` 同一种做法。
- 同一面板的另外两页（扩展管理、聊天文件）不经过“查看”，不受影响。

## 4. 测试

- `CareStudioNavigationTests`（窗口类）新增 `testSmartCaresReviewOfAppUpdatesAndMaintenanceGoesBackToSmartScan`，全程用夹具数据，不联网，不读系统：
  - 应用更新页自己打开时没有返回键；
  - 应用卡下钻（结果页夹具）后有返回键：在窗口按钮右边、和窗口按钮同一行，窗口按钮不动，没有工具栏项；
  - 换到管理页夹具，返回键还在、位置一样；
  - 按返回结束下钻，回到智能扫描；
  - 维护任务（装预览状态，不读系统）下钻后，按面板的“返回”结束下钻，回到智能扫描，不去性能页；
  - 不在下钻时，面板的“返回”照旧去性能页（登录项）。
- `CareStudioRenderReviewTests`（非窗口）新增 `testRendersD202ReviewBackOnTheAppUpdatesPage`：
  - 离屏渲染应用更新结果页，比较下钻和不下钻两张图，检查确实画出了返回键；
  - 证据图在 `~/Developer/.sc-build/cmm-ui-items-evidence/d202b/d202-updater-summary(-review).png`。
  - 离屏没有标题栏带，走的是全屏时的占行版式，顶部那条黑底只是离屏没有外层背景。
  - 管理页里是 AppKit 控件，离屏画不出来，交给窗口类检查。
- `SmartCareIndependenceD202Tests`（非窗口）新增 `testTheManagerPanelsBackGoesBackToSmartCareOnTheReview`：
  - 源码检查面板的返回键和 Esc 都走 `back`；
  - 面板里没有跳过下钻的 `Button(action: onBack)`。
- 没有改动、删除任何旧断言。

## 5. 验证

Xcode 27.1。树是 `8c95cdc5` 加本项，在 heavy 锁里增量编译（含测试目标，新窗口测试也编进去了），10-24 15:01–15:06，跑了两轮：

- 第一轮渲染测试含管理页，见第 4 节。
- 第二轮：8 个非窗口类，327 个测试，0 失败，1 个跳过（原来就跳过的 Setapp 只读审计）。
  - 8 个类：SmartCareIndependenceD202Tests（14 条）、CareStudioRenderReviewTests、SystemUtilitySafetyTests、UIConsistencyRegressionTests、CareStudioToolboxWiringTests、SmartCareTests、SidebarBadgeTests、ScanAccessReturnTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。改到的源码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项、具名颜色。
- 截图核对：`d202-updater-summary-review.png` 顶部是“‹ 智能扫描”一行；页面让出这 28 点后重新排版，标题“应用更新”下移约 14 点，和返回键不重叠，底部按钮和状态行位置不变。
- 没跑：窗口类（没借屏）。请主会话跑：
  - `CareStudioNavigationTests`：含本项新加的一条；
  - `ToolboxWindowReviewTests`：维护任务等面板，只是返回键改了动作；
  - `FeatureLightfieldContractTests`：应用更新页是 Lightfield 页面，外面多套了一层修饰。
- 没装、没提交。

## 6. 装机后请用 LCU 看

1. 智能扫描跑完后点应用卡“查看”：标题栏左上有“‹ 智能扫描”，页面是应用更新的检查结果，侧栏选中智能扫描。
2. 在这一页点“管理更新”，“‹ 智能扫描”还在原位。
3. 点“‹ 智能扫描”，回到智能扫描结果，卡片都还在。
4. 有建议的维护任务时（性能卡写“N 项任务”），点性能卡“查看”，打开维护任务；点面板左上“‹ 返回”，回到智能扫描结果，不是性能首页。
   - 没有建议任务时，这一条做不了。
   - 不点“运行”：运行维护任务会改系统。

## 7. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| D202 补二 | 智能扫描“查看”打开的页面，凡不是 studio 结果页的，也能回到智能扫描。应用卡打开应用更新页（照 CleanMyMac：Review 进入对应模块的管理器，应用卡对应应用更新），下钻时在标题栏带左边加“‹ 智能扫描”，位置、外观和其他下钻页相同，结果、管理各阶段都有。性能卡在有建议任务时打开维护任务，面板的“返回”下钻时回智能扫描，其他时候照旧回性能页。起因是第 13 次 LCU 实测应用卡下钻没有返回键；维护任务那处是 CMM 会话查其余入口时发现的。 | `CareStudioPages`（`careStudioReviewBack`）、`AppUpdatesView`、`ToolboxManagerPanel`；`CareStudioNavigationTests`、`CareStudioRenderReviewTests`、`SmartCareIndependenceD202Tests` 各新增 1 条 |
