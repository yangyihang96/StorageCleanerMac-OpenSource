# 交接：D202 补一 “查看”下钻停不住（r42 窗口全量 1 败）的修正

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话的 `000e9ca9`；补丁不碰 DECISIONS，也能直接打在门禁树 `033efa9b` 上。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 失败和原因

r42 窗口全量 654 过 1 败：

- `CareStudioNavigationTests.testSmartCaresReviewGoesBackToSmartScanInsteadOfStartingOver` 第 177 行；
- 下钻以后标题栏没有“‹ 智能扫描”（`careStudio.titleBar.back`），页面仍是性能首页，侧栏停在性能。

原因在产品代码，不在测试：App 里的“查看”下钻同样从来停不住。

1. `showSmartCareReview` 先调 `showFilter(.startup)`。它选中页面，同时把 `requestedFilter` 设成侧栏目标 `.utilityHub`。
2. 然后记下钻标记。
3. 紧接着，`ContentView` 的 `.onChange(of: store.requestedFilter)` 把同一页再选一次（`navigationState.select(.utilityHub)`）。
   - D202 第一版里，`select` 一进来就结束下钻。
   - 所以标记马上被清掉，页面回到首页。

单元测试 `testTheReviewShowsSmartCaresResultAndEndsWithAnotherPage` 没发现这个问题：单元测试里没有 ContentView 再选一次的这一步。

## 2. 改了什么

### 2.1 真的换页才结束下钻（`Stores/ScanStore.swift`，`AppNavigationState`）

- `select`、`selectSidebarDestination`、`selectUtilityTool` 不再一进来就结束下钻。
- 结束下钻挪到 `update` 里：只有路由真的变了才结束。
- 再选当前页时下钻还在。这包括 ContentView 对 `showFilter` 的回应，也包括扫描把路由设回同一页。
- `endSmartCareReview()` 改为公开，给侧栏用。

### 2.2 点侧栏照样结束下钻（`Views/SidebarView.swift`）

- 点侧栏任一行，先结束下钻，再选页面。
  - 写在行动作推迟执行的 `Task` 里：放在 `let route = family.primaryRoute` 之后、`selection = route` 之前。
  - D154 的源码检查要求 `Task { @MainActor in` 后第一句就是 `let route = …`（`SystemUtilitySafetyTests.testSidebarNavigationDefersObservableStateChangesUntilAfterViewUpdates`），所以不能放在最前面。
- 点的是当前页那一行也结束。例如下钻在性能页时点“性能”，会回到性能首页：结果是智能扫描的，按 D202 不在模块页显示。
- 侧栏行只有这一个点击入口（`row` → `select(family)`），读屏的激活也走它。

### 2.3 下钻页里的刷新仍算智能扫描的（`ScanStore.noteModuleScan`）

这个问题要等 2.1 修好才会出现：下钻能停住以后，用户可以在下钻页里操作。

- 例如在下钻页里停用一个登录项。操作完成后会调 `refreshStartupItems` 刷新。
  - 原来这次刷新算“模块自己的扫描”：这一项交还给模块，智能扫描的卡片全部回到首页。
  - 应用更新做完后的自动重查（`refreshAppUpdates`）也一样。
- 现在下钻停在哪一项，这一项的扫描就仍算智能扫描的：`noteModuleScan` 只在 `navigationState.smartCareReview != part` 时才把这一项交还模块。
- 离开下钻以后，模块自己的扫描照旧收回这一项。
- 限制：在下钻页里点了停用，操作还没做完就离开下钻，之后那次刷新会算模块自己的，智能扫描的卡片回到首页。显示的数据仍然正确。

## 3. 测试

`SmartCareIndependenceD202Tests`（非窗口）：

- 新增 `testTheReviewOutlastsThePageChosenAgain`（r42 的回归测试）：
  - 五种下钻都覆盖：性能→登录项、性能→维护、防护、应用、重复文件；
  - 照 `requestedFilter` 再选一次同一页，标记还在；
  - 扫描路由设回同一页，标记也还在。
- 新增 `testTheSidebarsRowsEndTheReview`：
  - 结束下钻后再选当前页，性能页回到首页；
  - 源码检查：侧栏行先结束下钻，再选页面。侧栏行的点击写在视图里，单元测试点不到；窗口测试也没有点侧栏。
- 新增 `testARefreshOnTheReviewKeepsThePartSmartCares`：
  - 下钻时刷新这一项，标记和智能扫描的卡片都保留；
  - 刷新别的项，智能扫描的卡片也不动；
  - 离开下钻后，模块自己的扫描收回这一项。
- 改 `testTheReviewShowsSmartCaresResultAndEndsWithAnotherPage`：
  - 去掉 `selectSidebarDestination(.startup)` 之后断言标记为空（"the sidebar's own row too"）那一条；
  - 测试里写了“D202＋旧值”和原因：侧栏行不走这个调用，而且再选当前页现在要保留下钻；
  - 侧栏行改由 `testTheSidebarsRowsEndTheReview` 检查。

`CareStudioNavigationTests`（窗口类）不改：本修正就是要让 r42 失败的那条通过。

## 4. 验证

Xcode 27.1。树是 `033efa9b` 加本修正，在 heavy 锁里增量编译（含测试目标，窗口测试也编进去了）。

- 第一轮（10-24 13:44–13:47）：14 个非窗口类里 1 条失败。
  - 失败的是 D154 的源码检查 `SystemUtilitySafetyTests.testSidebarNavigationDefersObservableStateChangesUntilAfterViewUpdates`：我把 `endSmartCareReview()` 写在了 `let route = family.primaryRoute` 前面。
  - 改法：把这一句挪到 `let route` 之后、`selection = route` 之前。断言没动。
- 第二轮（13:47–13:48）：14 个非窗口类，400 个测试，0 失败，1 个跳过。
  - 跳过的是 `testLiveSetappUninstallInventoryWhenExplicitlyEnabled`：要设环境变量才跑的只读审计，原来就跳过。
  - 14 个类：SmartCareIndependenceD202Tests（13 条，含新增 3 条）、SystemUtilitySafetyTests、SidebarBadgeTests、CareStudioToolboxWiringTests、UIConsistencyRegressionTests、SmartCareTests、ScanAccessReturnTests、CareStudioModuleShellRenderTests、CleanupStoreFollowUpTests、IndependentFeatureWorkspaceStoreTests、MyActivityPageTests、SmartScanHistoryTests、StartOverTests、DebugSmartScanSessionFixtureTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。改到的源码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项。
- 没跑：窗口类（没借屏）。请主会话跑：
  - `CareStudioNavigationTests`：r42 失败的那条；
  - `SmartScanScopeTests`：D202 第一版改过它的断言，又大量切页面；
  - 其他会切页面的窗口类：`SafeCleanupLayoutTests`、`CareStudioWindowReviewTests`、`FeatureLightfieldContractTests`、`MainWindowControlsTests`、`ExternalUninstallRequestTests`、`FeatureTemplateContractTests`、`MiniWindowCleanupPresentationTests`。所有换页都经过这次改的 `update`。
- 没装、没提交。

## 5. 装机后请用 LCU 看

1. 智能扫描跑完后，点性能卡的“查看”：
   - 标题栏左上是“‹ 智能扫描”；
   - 页面是智能扫描读到的登录项；
   - 侧栏高亮“智能扫描”。
2. 点“‹ 智能扫描”，回到智能扫描结果，卡片都还在。
3. 再点性能卡的“查看”，然后点侧栏“性能”：进入性能首页，标题栏没有“‹ 智能扫描”。
4. 防护、应用、重复文件三张卡的“查看”也都停得住，返回同样回到智能扫描结果。
5. 2.3 的刷新：在下钻页里停用一个登录项会真的改系统设置，要用户另行同意才能做。不做的话，这一条只有单元测试覆盖。

## 6. 建议的 DECISIONS 写法

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D202 补一 | “查看”下钻只在换页时结束。再选当前页不结束，包括 ContentView 对 `showFilter` 的回应和扫描把路由设回同一页；点侧栏任一行（含当前页那一行）结束。下钻页里刷新这一项，如停用登录项后、更新做完后的重查，仍算智能扫描的结果：不交还模块，智能扫描的卡片不回首页。起因是 r42 窗口全量里 `CareStudioNavigationTests` 的下钻测试失败：第一版的 `select` 一进来就结束下钻，App 里下钻从来停不住。 | D202 第一版“任何选页都结束下钻” | `AppNavigationState`、`SidebarView`、`ScanStore.noteModuleScan`；`SmartCareIndependenceD202Tests` 新增 3 条、改 1 条 |
