# 交接：报告第四节第 12 条（标题栏的“重新开始”和居中的模块名）

日期：2026-10-23。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `922203b6`：你 10-23 发来的最终树（第九次测试版装的就是它）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。编号请你定。

## 1. 要求

- 用户的总要求：照 CleanMyMac 1:1，对方有我们也有的功能，照它做。
- 1:1 对照报告第四节第 12 条：
  - CleanMyMac 结果页只有一个“Start Over”，在标题栏左边，点了先确认；标题栏正中是模块名（cmm/14、20、24）。
  - 扫描中只显示模块名（cmm/19）。
  - 我们各模块不统一（ours/01–08）。
- 你 10-23 的补充：
  - 有独占操作时禁用“重新开始”，确认页开着时也是；确认文案写清“回到首页，本次结果不保留”；
  - 应用更新页的“重新检查”“管理更新”保留；
  - 避开 `CareStudioApplications.swift` 末尾和 `ApplicationsOverviewView.swift` 里 D190 的计数；
  - 工具栏项要有可访问性标签和标识。
- 设计稿：`/Users/developer/Claude 好玩的/CleanMyMac全界面逆向-2026-10-20/设计-第12条-标题栏重新开始与模块名.md`，你已同意。

## 2. 改了什么

### 2.1 标题栏（`Views/CareStudio/CareStudioPages.swift`）

- `CareStudioPageFrame` 新增参数 `titleBar: CareStudioTitleBar`，取值三种：
  - `.hidden`：首页用，这是默认值；
  - `.title`：只显示模块名；
  - `.startOver(CareStudioStartOver)`：模块名加“重新开始”。
- `isWorking` 的页面（扫描中、运行中）默认显示模块名。
- 用 SwiftUI 的 `.toolbar` 放进窗口工具栏：
  - “重新开始”放 `.navigation` 位，在侧栏右边，和红绿灯同一行；带逆时针箭头、没有底色、白字。
  - 模块名放 `.principal` 位，用 `CareStudioModule.family.title`，就是侧栏那一行的名字，例如安全清理和开发者垃圾的结果页都写“垃圾清理 / Cleanup”，和 cmm/20 一致。原先用的是 `sidebarTitle`，窗口截图里标题栏写成了页面自己的标题“安全清理 / Safe Cleanup”，和侧栏对不上，已改。
  - ContentView 里工具栏背景本来就是透明的，两者直接叠在模块渐变上。ContentView 和 D175 的那几处都没动。
  - macOS 26 起，工具栏会给每个项加一层共享的玻璃胶囊底。第一次窗口截图里，“重新开始”和模块名都套着深色胶囊，CleanMyMac 没有。现在两项都经 `CareStudioBareToolbarItem` 放进工具栏：macOS 26 及以后用 `sharedBackgroundVisibility(.hidden)` 去掉胶囊，更早的系统照旧（本来就没有）。
- 确认框统一由页面框架弹：“重新开始？”加“回到首页，本次结果不保留；需要重新扫描才能再看到这些项目。”
  - 点“重新开始”时会再查一次：问的时候如果已经开始了独占操作，就什么都不做。
- `CareStudioStartOver` 带 `activity`（`HeavyWorkActivityStore`）和 `isEnabled`。有会改动东西的工作拿着重活租约时，按钮变灰：清理、卸载、应用更新、系统缓存清除、云盘释放。确认框是窗口级弹窗，开着的时候工具栏本来就点不了。
  - 哪些租约挡住“重新开始”，由新加的 `HeavyWorkCoordinator.Owner.holdsStartOver` 决定，用穷举 switch 写：`cleanup`、`restore`、`emptyTrash`、`memoryOptimization`、`appUpdates`、`cloudLocalCopy` 挡；只读的 `mainScan`、`largeFilesScan`、`duplicateScan` 和测量类的 `networkTest`、`benchmark` 不挡。
  - 原因：10-23 的窗口跑发现，垃圾清理结果页一出现，D184 的应用瘦身检查就拿着 `mainScan` 租约读全部应用。按原来“有租约就灰”的规则，每次打开结果页，“重新开始”都要灰到这次检查跑完。CleanMyMac 的 Start Over 随时能点。这类只读检查挂在页面上，离开页面就随之结束；别处的扫描也碰不到这一页。确认时那次复查用同一规则。
- 可访问性：“重新开始”有标签和帮助说明，标识 `careStudio.titleBar.startOver`；模块名有标题特征，标识 `careStudio.titleBar.title`。
- 字号用 `.system(size:)`，颜色用 `CareStudioInk`，符合主窗口字体规范。

### 2.2 各模块结果页

| 模块 | 原来的页头 | 现在 | “回到首页”做什么 |
|---|---|---|---|
| 智能扫描 | 左“重新开始” | 标题栏 | 现有的 `smartCare.reset()` 加 `startOverV2Results()` |
| 垃圾清理（含开发者垃圾） | 左“重新开始”加右“重新扫描” | 标题栏；“重新扫描”去掉 | 现有的 `startOverV2Results()` |
| 云盘清理 | 左“重新开始”加右“重新扫描” | 标题栏，现在会先确认；“重新扫描”去掉 | 现有的 `model.startOver` |
| 防护 | 右“重新扫描”（D186 起同时扫恶意软件，D188 起也重读最近使用项目） | 标题栏；“重新扫描”去掉 | 新加 `MalwareScanStore.startOver()`、`RecentItemsStore.startOver()`（都只加），再调用现有的 `privacy.clearSession()` |
| 杂乱文件 | 右“重新扫描” | 标题栏；“重新扫描”去掉 | 新加 `DuplicateFilesStore.startOver()`：清结果、选择和存盘快照，设置保留 |
| 应用 | 左“卸载记录”加右“重新扫描” | 标题栏；“卸载记录”挪到右边，“重新扫描”去掉 | 新加 `ApplicationsManagerModel.startOver()`（清选择和筛选），以及 `ScanStore.startOverInstalledApps()` |
| 性能 | 左“重新扫描”加右“撤销上次更改” | 标题栏；“撤销”留在右边，“重新扫描”去掉 | 新加 `ScanStore.startOverStartupItems()`：只清已扫描标记，读到的项目留着，首页那句“上次读取到 N 项”继续可用 |

- 各页拿掉页头那一行后，下面的内容用同样高度的上边距补回，位置不变：
  - 垃圾清理、防护、杂乱文件补 38 点（紧凑窗口 34 点），云盘补 38 点；
  - 性能那一行保留为 26 点高。
- 卡片里的“重新扫描”提示保留，例如“完全磁盘访问权限已变化”；应用更新页的“重新检查”“管理更新”也不动。
- 空间透镜有自己的页头，这一条没动。
- 防护页的三路刷新（你说按 1:1 定）：照 CleanMyMac，结果页不留“重新扫描”，要再扫就“重新开始”回首页再扫。
  - 首页的扫描（`BrowserPrivacyWorkspaceView.startProtectionScan()`）本来就同时扫浏览记录和恶意软件；结果页一出现，它的 `.task` 会重读最近使用项目。所以回首页再扫就是三样都刷新，不用往首页挪逻辑。
  - “重新开始”把三样都清掉（恶意软件和最近使用项目用新加的 `startOver()`，浏览记录用现有的 `clearSession()`），符合确认框里说的“本次结果不保留”。
  - 禁用条件在 D186 的基础上加了最近使用项目的读取和清理（`isScanning`、`isCleaning`）。
  - 防护结果页里只给原来“重新扫描”用的 `startProtectionScan()` 删掉了。
- 性能页的“重新开始”也等重活租约（`CareStudioStartupActions.startOverActivity`）：第 13 条的“运行任务”会在这页拿清理租约跑维护任务，跑着的时候不让回首页。
- `store.rescanV2Results()` 保留，它在 store 层还有自己的测试。
- 杂乱文件的存盘快照用新加的 `DuplicateFileResultStore.remove()` 删除，只删 App 自己的 `result.json`。删除清单 `script/deletion-process-inventory.txt` 加了一行，校验已通过。

## 3. 测试

- 新增 `StartOverTests`（非窗口）：
  - 性能：清标记、留项目；读取中和执行修改中都不动；
  - 应用：清标记、选择和筛选；卸载中不动；
  - 防护的恶意软件：结果、行和进度清掉；
  - 防护的最近使用项目：列表和勾选清掉，没有移走任何东西；
  - 哪些租约挡住“重新开始”：只有 `cleanup`、`restore`、`emptyTrash`、`memoryOptimization`、`appUpdates`、`cloudLocalCopy`，`mainScan` 不挡。
- 新增 `IndependentFeatureWorkspaceStoreTests.testDuplicateStoreStartOverForgetsTheResultAndItsSavedSnapshot`：
  - 结果、选择、存盘快照都清掉；
  - 自定义位置和排序保留；
  - 再建一个 store（相当于重开 App）是首页。
- 新增 `CareStudioNavigationTests.testResultsShowStartOverAndTheModuleNameInTheTitleBar`（窗口类，用真实 ContentView）：
  - 安全清理的结果页工具栏有“重新开始”和模块名；
  - 防护首页两样都没有；
  - 点“重新开始”先出确认框，取消后结果还在，确认后回到首页。
  - 建窗口的代码抽成 `hostedMainWindow()`，和原来的侧栏测试共用。
  - 标题栏里的两样不走无障碍：SwiftUI 把每个工具栏项放在单独的宿主视图里，这个视图在测试进程的无障碍树里只是一个空的 AXGroup，没有子元素也没有标签。10-23 前三次窗口跑就是这样失败的：按标识、按文字都找不到，截图里两样其实都在。所以改成：
    - 结果页的工具栏里应有两个带视图的项（`window.toolbar.items` 的 view），左边是“重新开始”，右边是模块名，按位置区分；收成图标栏后也一样。
    - “重新开始”通过按钮自己的动作来按：Debug 下按钮出现时把动作登记到 `CareStudioTitleBarTestHook`，可用状态变化时重新登记，消失时清掉；只有按钮可用时才执行，租约挡住时返回 false。不用鼠标事件，是因为别的 App 在前台时，测试进程切不到前台（macOS 14 起激活是协商式的），点击到不了工具栏项。按下后应弹出确认框；确认框是 AppKit 的，用无障碍按“取消”，结果保留；再按一次、按确认框里的“重新开始”，回到首页，工具栏变空，登记也随之清掉。
    - 首页的工具栏里没有任何带视图的项。
    - 模块名写的是哪几个字，进程里读不到，靠整窗截图核对。截图里的标题栏就是用户看到的样子。
    - 失败时信息里附上每个工具栏项的类型和无障碍子树。
    - 去掉了两处断言：确认框里按“取消”的 `XCTAssertTrue(press(cancel))`、按“重新开始”的 `XCTAssertTrue(press(confirm))`。这两个按钮的 `accessibilityPerformPress` 返回 false，但动作照样执行了：第五次窗口跑里，紧跟着的效果检查都过了。现在只按、不断言返回值，紧跟着的效果检查都保留：按“取消”后确认框关闭、结果还在；按确认框里的“重新开始”后回到首页、标题栏清空、测试入口也随之清掉。测试里写了原文和原因。
  - 整窗截图（含标题栏）只在设了截图目录时导出：智能扫描结果、安全清理结果、防护首页、收成图标栏后的安全清理结果，四张。
- 改了的测试：
  - `CleanupStoreFollowUpTests` 那条按原文核对结果页的测试，改为检查标题栏的“重新开始”、页面上没有“重新扫描”。原名和原来的要求写在注释里。
  - `CareStudioModuleShellRenderTests`、`CareStudioWindowReviewTests` 里的参数名 `onScanAgain:` 改为 `onStartOver:`。

## 4. 验证

Xcode 27.1，基线是最终树 `922203b6`。

- 第 12、13 条合起来的完整非窗口门禁（门禁树 `b2cf54c0`，21:30–22:17，持 heavy 锁）：
  - debug：主测试包 5967 个，29 个跳过，1 个失败：`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`，15 秒时报 `BenchmarkKernelError` 2（资源上限）。这两条都没碰跑分代码，这个测试在负载高时就会这样失败，当时 5 分钟平均负载在 50 左右。机器空闲时单独重跑的结果见交付消息。CombinedStatusIconTests 285 个 0 失败；Swift Testing 135 个通过。
  - release：主测试包 5710 个，28 个跳过，0 失败；CombinedStatusIconTests 285 个 0 失败；Swift Testing 135 个通过。
- 第 12 条单独（只打第 12 条的结果树）：工作树切过去重新编译，跑相关的非窗口类，结果见交付消息。
- 窗口类（借“虚拟屏 1 · Codex”，用户 10-23 同意；时间按你给的空档排）：
  - 20:19–20:33，5 个窗口类（`CareStudioNavigationTests`、`CareStudioWindowReviewTests`、`SpaceLensSidebarWindowTests`、`SpaceMapTreemapWindowTests`、`ToolboxWindowReviewTests`），树是最终树加第 12、13 条的第一版：36 个里 33 个通过、2 个截图用例跳过，1 个失败，就是新加的标题栏测试。
  - 之后单独重跑这个类六次，按 §2.1、§3 查出并改掉了：工具栏的玻璃胶囊底、模块名的来源、测试读不到工具栏项、应用瘦身的只读检查占着租约让“重新开始”变灰、确认框按钮的返回值。21:26–21:28 第六次 2 个全过，和 r18 基线一致；之后只改了注释。
  - 那一轮里另外 4 个窗口类都过了。之后改的 `CareStudioPages.swift` 只动标题栏，这 4 个类不检查标题栏，没有重跑，合并后你的窗口全量会再覆盖。
  - 截图：`~/Developer/.sc-build/cmm-ui-evidence-i12nav6/` 的 `w23-titlebar-*`（4 张），对照 cmm/14、20、24：
    - 结果页标题栏左边“重新开始”，没有底色；正中是模块名，安全清理页写“Cleanup / 垃圾清理”，和侧栏一致。
    - 收成图标栏后，“重新开始”挨着图标栏，可以点。
    - 防护首页标题栏是空的。
- 删除清单、私有 API、窗口类登记三项检查都通过。
- 没在真实 App 里亲手试；没装测试版。

## 5. 下一步

- 第 13 条（结果卡按钮、性能页维护任务卡）另附补丁，基线是本条的结果树。
- D193 ②③（空间地图的可清除空间一行、气泡名字门槛约 80 点）接着做。
