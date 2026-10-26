# 交接：D202 智能扫描和各模块的结果各自独立

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是 D203 的结果树（叠在 `9ba4a562`、D204、D203 上，见交付消息）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求

用户 10-24 同意主会话的建议（主会话转告，用户原话：“两个都照你建议的改，门禁过了就装”）。建议原文：

> 跑完智能扫描后，垃圾清理、防护等模块页会接住同一份结果，侧栏多出白点。CleanMyMac 是各模块回到自己的首页。要不要改成各自独立？我建议照 CleanMyMac 改。

第 11 次测试版还看到反方向的问题：在垃圾清理模块里扫一次，智能扫描页也直接显示“清理任务已准备好，看看发现了什么”。

要做到：

- 智能扫描的结果只在智能扫描页（包括它的“查看”下钻）里出现；扫完后，垃圾清理、防护、性能、应用、杂乱文件各页仍是自己的首页，侧栏只有智能扫描亮黄点。
- 模块自己扫出的结果只在这个模块页；智能扫描页仍是首页，或者保持它自己上一次的结果。
- 任一页的“重新开始”只清自己那一份。
- 不能让同一类扫描在后台跑两遍、抢重活租约。

## 2. 原来为什么会串

智能扫描（`LiveSmartCareScanner`）是逐项调用各模块自己的入口，结果都存在共用的 store 里：

- 清理会话：`ScanStore.cleanupScanSession`；
- 浏览记录：`BrowserPrivacyStore`；
- 登录项：`ScanStore` 的 startup 状态；
- 应用更新：`ScanStore` 的更新检查状态；
- 重复文件：`DuplicateFilesStore`，它的结果开机还会恢复。

模块页只看 store 里有没有结果，不知道是谁扫的。智能扫描的卡片也是实时读这些 store。所以三个方向都会串：

- 智能扫描的结果跑到模块页；
- 模块自己扫的结果改掉智能扫描卡上的数字；
- 垃圾清理页的结果被当成智能扫描页的来显示：智能扫描页在阶段空闲时退回旧的垃圾扫描流程，不看会话是谁的。

只有清理会话本身带来源（智能扫描的会话有 `smartScanScopes`），其余四项没有来源字段。

顺带找到的问题：智能扫描的垃圾扫描是按“当前停在哪一页”选范围的（`startCleanupV2Scan` 读 `selectedFilter`）。

- 停在垃圾清理页时，会扫成垃圾清理页自己的会话；
- 停在空间地图、文件搬家、重复文件页时，`refreshFileWorkspaceIfSelected` 会去启动那一页的扫描，垃圾根本没扫。

## 3. 做法：记来源，不复制状态

不分两份状态。这些 store 很大、彼此关联（会话、勾选、计划、执行、租约），复制一份不现实，还会让同一类扫描各跑一遍。

只记“哪几项的结果是智能扫描扫的”，每个页面据此决定显示首页还是结果。扫描次数一次不加。

- `ScanStore.smartCareResultParts`：
  - 智能扫描扫出结果的那几项，存在 `smartCarePreferences`，键 `smart-care.result-parts.v1`；
  - 要存下来，因为重复文件的结果开机会恢复。
- `ScanStore.smartCareScanningPart`：智能扫描此刻正在扫的那一项。
- 规则：
  - 智能扫描扫第 X 项前，把 X 记成它的（`beginSmartCarePart`），扫完清掉“正在扫”（`endSmartCarePart`）。
  - 任何地方开始扫 X、而智能扫描当时不在扫 X，就是模块自己的扫描（`noteModuleScan`）：
    - X 从记号里拿掉；
    - 智能扫描如果停在结果页或运行完成页，就回到首页，它留下的其他几项结果也一起清掉（`SmartCareCoordinator.follow`）；
    - “运行”进行中不打断。
  - 记号的结果已经不在（清掉了、开机没恢复），就当没有记号（`smartCareHolds` 每次都核对结果在不在），不会留下孤儿记号让模块页一直显示首页。
- 入口（只在扫描真的开始时记）：
  - 垃圾：`startCleanupV2Scan` 开始后，按扫描的页面判断（垃圾清理页、开发者页的算模块）；
  - 登录项：`refreshStartupItems`；
  - 重复文件：`scanDuplicateFiles`；
  - 应用更新：`refreshAppUpdates`、应用页首页扫描里的检查（`ApplicationsScanCoordinator`）；
  - 浏览记录：防护页的 `startProtectionScan`（`BrowserPrivacyStore` 不认识 `ScanStore`，由页面传 `onScan`）。

## 4. 改了什么

`Stores/ScanStore.swift`：

- 记号、正在扫的项、回调 `onModuleScanReplacedSmartCarePart`，以及：
  - `beginSmartCarePart`、`endSmartCarePart`、`noteModuleScan`；
  - `smartCareHolds`、`moduleShowsResult`；
  - `showSmartCareReview`、`clearSmartCareResults`。
- 智能扫描的垃圾扫描：
  - `startSmartCareJunkScan()` 在启动的那一刻按智能扫描页启动；
  - 扫描开始路径里读页面的地方改读 `scanPage`（这一刻是智能扫描时就是 `.overview`），包括 `activePresentationRoute`。
- `cleanupSession(for: .green/.devCaches)` 不再返回智能扫描的会话（原来只要它含垃圾范围就返回）。
- `junkFlowIsAModules(...)`：智能扫描页上正在显示的垃圾流程，是不是模块的。
- `AppNavigationState.smartCareReview`：智能扫描“查看”打开的是哪一项。选任何其他页面（`select`、`selectSidebarDestination`、`selectUtilityTool`）都会清掉它。
- 调试夹具 `installDebugSmartScanSessionFixture(_:page:)`：`page: .green` 装成垃圾清理页自己的会话（`DebugSmartScanSessionFixture.cleanupPageSession`，同样的行，没有 Smart Scan 范围）。

`Stores/SmartCareLiveScanner.swift`：

- 每一项扫描前后做记号；
- 垃圾项改用 `startSmartCareJunkScan()`；
- `SmartCareCoordinator.of(store)` 接上 `follow`。

`Models/SmartCareModule.swift`：`SmartCareCoordinator.follow(_:privacy:)`，模块接管时回首页。

`Views/ContentView.swift`：

- 智能扫描主机页：阶段空闲时，模块的垃圾扫描、模块的结果都显示首页；清理中、核对、完成页仍全局显示，不变。
- 智能扫描运行完的“完成”改为 `clearSmartCareResults`。
- 防护页传 `recordsAreSmartCares`、`onScan`。
- `DetailRouterView` 观察导航状态。
- 给页面注入“返回智能扫描”（`careStudioReviewReturn`）。

模块页：

- `Views/SystemUtilitiesView.swift`：性能页、杂乱文件页在原来的首页条件上加“结果不是智能扫描的”，扫描中的页面也一样。
- `Views/BrowserPrivacyWorkspaceView.swift`：
  - 防护页同样处理；
  - `showsLanding(..., recordsAreSmartCares:)`；
  - 智能扫描正在读浏览记录时，页面的“扫描”不去重启它。

`Views/CareStudio/CareStudioSmartCare.swift`：

- “查看”：防护、性能、应用、杂乱打开对应页面时带下钻标记（`showSmartCareReview`）；清理仍在本页打开管理器。
- “重新开始”改为 `clearSmartCareResults`。

`Views/CareStudio/CareStudioPages.swift`：

- 下钻打开的结果页，标题栏左边的“重新开始”换成“‹ 智能扫描”（探针 `careStudio.titleBar.back`，读屏名“返回智能扫描”）；
- 位置、字号和“重新开始”相同；
- 测试钩子 `CareStudioTitleBarTestHook.pressBack`。

侧栏：

- `Views/SidebarBadge.swift`：模块的进度和白点只看模块自己的扫描和结果；规则本身不变。
- `Views/SidebarView.swift`：下钻时侧栏选中智能扫描。

## 5. 行为

| 情形 | 现在 |
|---|---|
| 智能扫描扫完 | 只有智能扫描页显示结果、侧栏亮黄点；垃圾清理、防护、性能、杂乱各页是首页，没有白点 |
| 智能扫描正在扫第 X 项 | X 的模块页是首页，侧栏不显示 X 的进度；扫描按钮照旧：重活租约、加载中的保护不变，防护页不重启智能扫描的读取 |
| 智能扫描“查看”防护、性能、应用、杂乱 | 打开该页并显示智能扫描的结果，侧栏选中智能扫描，标题栏左边是“‹ 智能扫描”；点它或点侧栏任何一行，下钻结束 |
| 模块页自己扫 X | X 的结果只在模块页（有白点）。智能扫描若在结果页，就回首页，它其他几项的结果也清掉 |
| 垃圾清理页扫完再去智能扫描页 | 智能扫描页是首页，不再显示“清理任务已准备好…” |
| 智能扫描“重新开始”、运行完点“完成” | 只清智能扫描扫出的几项（清理会话、浏览记录、登录项“已扫描”、重复文件结果），记号清空；模块自己的结果不动 |
| 模块页“重新开始” | 原逻辑；只有模块自己的结果时才看得到这一页 |
| 开机时记号还在，结果没恢复 | 当没有记号 |

## 6. 取舍（请写进 DECISIONS）

- 模块重扫 X 后，智能扫描回到首页，其他几项的智能扫描结果也随之不再显示（一并清掉）。它的卡片实时读共用的 store，X 换了，整页就不再可靠。
- 防护页的扫描同时读浏览记录和恶意软件。智能扫描扫过浏览记录后，防护页先前自己的恶意软件结果也跟着不显示，直到防护页再扫。
- 应用更新是应用自己的事实，没有“清掉”：
  - 智能扫描“重新开始”只清记号；
  - 更新页（工具页）仍显示最近一次检查；
  - 更新页或应用页自己的检查，会让在结果页的智能扫描回首页。
- 下钻里浏览记录列表的“重新扫描”，仍算智能扫描那一份（看的是智能扫描的结果）。
- 旧清理架构（`cleanupFeatureConfiguration` 为 legacy，不是产品默认）异步权限检查之后的启动不带智能扫描标记。

## 7. 测试

新增 `SmartCareIndependenceD202Tests`（非窗口），10 个：

- 智能扫描扫 X 时把 X 记为它的；它自己调模块入口不算模块扫描；模块扫 X 时拿掉 X，回调只报一次；
- 智能扫描扫 X 时，模块页是首页，侧栏不显示 X 的进度；
- 记号存下来；重新创建 store（相当于开机）时，结果不在的记号当作没有；
- “重新开始”只清智能扫描的那几项和记号，模块自己的结果和清理会话不动；
- 智能扫描的清理会话不进垃圾清理、开发者页；垃圾清理页自己的会话不进智能扫描页；
- 智能扫描页对模块的扫描中、取消中、结果都显示首页，清理执行的几页不变；
- 下钻显示智能扫描的结果；导航到别处或点侧栏后标记清掉；
- 侧栏白点只看模块自己的结果，清理也一样；
- 模块接管智能扫描结果页上的某一项时，智能扫描回首页；不是它的项不受影响；
- 智能扫描的垃圾扫描在垃圾清理页、重复文件页、智能扫描页启动时，都是智能扫描的范围和路由，不启动重复文件扫描。

窗口类（请放进窗口全量）：

- `CareStudioNavigationTests`：
  - 新增 `testSmartCaresReviewGoesBackToSmartScanInsteadOfStartingOver`：下钻页有 `careStudio.titleBar.back`、没有“重新开始”；返回钮在红绿灯同一行、不压红绿灯；红绿灯和侧栏不动、没有工具栏项（D94）；按返回后标记清掉、到智能扫描；性能页回到首页。
  - `hostedMainWindow` 改装垃圾清理页自己的会话。注明“D202＋旧值”：原来装智能扫描的会话，D202 起它只在智能扫描页显示。
- `SmartScanScopeTests.testCleanupPageRoutesUseCompletedCoverageRatherThanEmptyResultsOrNewCheckboxes`：智能扫描的会话不再填进垃圾清理、开发者页，`showsResults` 改为始终是首页（注明“D202＋旧值”）。

## 8. 验证

Xcode 27.1。树是 D203 结果加本项，在 heavy 锁里增量编译。

- 第一轮（10-24 12:02–12:05）：非窗口 21 个类，500 个测试过，1 个失败。
  - 失败的是 `SystemUtilitySafetyTests.testNavigationStatePublishesOnlyActualRouteChanges`：每次选页都给下钻标记赋 nil，标记本来就是空的时候也会发通知。
  - 已改为只在有标记时才清（`endSmartCareReview`），这条测试的期望没动。
- 第二轮（12:06–12:07）：改完重编，D202 相关的 14 个类，427 个测试，0 失败。包括 SmartCareIndependenceD202Tests（新增）、SystemUtilitySafetyTests、SidebarBadgeTests、SmartCareTests、CareStudioToolboxWiringTests、CareStudioModuleShellRenderTests、UIConsistencyRegressionTests、ApplicationsScanD192Tests、DebugSmartScanSessionFixtureTests、StartOverTests、CleanupStoreFollowUpTests、BrowserPrivacyRecordScannerTests、MenuBarCachedHealthTests、IndependentFeatureWorkspaceStoreTests。
- 第一轮里的另外 7 个类也都过了，改动只碰导航通知，没有重跑：CareStudioRenderReviewTests、CleanupResultGroupsD203Tests、CleanupScopeD192Tests、CloudDriveD185Tests、LandingNamesOnlyTests、PrivacyCleanupPresentationTests、ScanAccessReturnTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过；没有新增删除调用；改到的源码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项。
- 没跑的：
  - 窗口类，交给主会话的窗口全量（清单见交付消息）；
  - 测试版里的实际流程：智能扫描后各模块页、“查看”下钻和返回、模块重扫后智能扫描回首页。
- 没装、没提交。

## 9. 建议的 DECISIONS 写法

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D202 | 智能扫描和各模块的结果各自独立（用户 10-24 同意）：<br>• 共用的 store 不分两份，记下哪几项结果是智能扫描扫的（`smart-care.result-parts.v1`），模块页对这几项显示首页、侧栏不亮，只有智能扫描“查看”下钻时显示，此时侧栏选中智能扫描，标题栏左边是“‹ 智能扫描”；<br>• 模块页自己扫的结果只在模块页，智能扫描页空闲时不再显示模块的垃圾扫描和结果；<br>• 模块重扫某一项后，智能扫描回首页，其他几项的智能扫描结果也随之不再显示；<br>• 智能扫描“重新开始”、运行后“完成”只清它自己扫出的几项。 | D168 中“智能扫描用模块原入口、结果进各模块页”的部分；D196 中模块白点的口径 | 智能扫描页与下钻、垃圾清理、防护、性能、杂乱文件页、侧栏 |
| D202 附 | 智能扫描的垃圾扫描始终按智能扫描页的范围和路由启动，与当前停在哪一页无关（原来停在垃圾清理页会扫成那一页的会话，停在空间地图、文件搬家、重复文件页会去启动那一页的扫描）。 | — | 智能扫描 |
