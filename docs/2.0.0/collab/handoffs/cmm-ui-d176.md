# 交接：D176（侧栏照 CleanMyMac：第一次扫描后全局收成图标栏）

日期：2026-10-23。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `0bd6589f`：`0c4cbf26` 加上 D175 补丁 `D175-sidebar.patch`（sha256 `c702ab46…4261764`，已核对）。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 用户要求

- 起因（2.0.1 会话转述的用户原话）：“你要确保整体 UI 界面是统一的：智能扫描、性能优化、安全防护、垃圾清理都是左边的小图标，一到应用管理怎么就又变成大图标了？杂乱文件又变成小图标，空间地图又变成大图标，云盘清理是大图标。你要把这个整体做一致。”
- 用户先选了“始终完整侧栏”。2.0.1 会话在 CleanMyMac 上实测后，用户 10-23 改选 A，“照 CleanMyMac 1:1 (Recommended)”，选项说明：“第一次扫描前显示带文字的完整侧栏；从第一次扫描起，所有页面统一显示图标栏（鼠标停在图标上显示名字），之后一直保持。你仍然可以按 ⌃⌘S 或侧栏底部按钮手动展开，展开后就按你选的来。”
- CleanMyMac 实测（`1比1对照-20261023/cmm/01–20`）：
  - 扫描前所有页面都是完整侧栏；
  - 任何模块一开始扫描就全局收起，单个模块的扫描也算；
  - 切模块、Start Over 都保持收起；
  - 不跨启动，重开后恢复完整。

原因：D141 让扫描中、结果页、清理中这几种页面，还有各管理器，经 `CareStudioCanvas` 的 rail 登记，各自把侧栏收成图标栏，首页不收。所以有结果的模块和没结果的模块，侧栏看起来不一样。

## 2. 改了什么

- 侧栏形态改成全局一条规则（`SidebarPresentationState`）：用户手动选的 > 本次启动扫描过就是图标栏 > 按窗口宽度（窄于 960 点是图标栏）。
  - 新增 `foldedByScan` 和 `userHasToggled`，都只在内存里，不写偏好，重开 App 恢复完整侧栏。
  - `scanStarted()`：用户本次运行没手动切换过时，收成图标栏。
  - `toggle()`（侧栏底部按钮和 ⌃⌘S，D175）：按用户的选择来，此后再扫描也不自动收回去。
  - 窗口宽度跨过阈值时，清掉用户的选择，这条照旧（§2.2）。
- “扫描过”的信号：`CareStudioCanvas.hasWorked`。任何模块的扫描页或运行页一出现，就以“工作中”登记到画布，画布记下“这次启动后工作过”；`ContentView` 用 `onReceive` 读它，调 `scanStarted()`。这样所有模块都覆盖到，不用在每个扫描入口各接一遍。`ContentView` 不再整页观察画布。
- 去掉各页自己的收侧栏要求：
  - 画布登记不再带 `rail`，`prefersSidebarRail` 删掉；
  - `ContentView` 里 `let sidebarMode = sidebarPresentation.effective`（原来是 `careStudioCanvas.prefersSidebarRail ? .rail : …`）；
  - 页面框架的运行页、10 个模块页，以及 5 处直接登记的地方（结果中心页、垃圾管理器、通用管理器、登录项管理器、工具面板）都去掉了。
- 例外：`CareStudioPageFrame.prefersSidebarRail` 参数暂时保留，但已不读。空间地图页（`CareStudioSpaceLens.swift`）为 Disktree 第 3 期冻结，它的调用里还带着这个参数；第 3 期合入后，在第三批 S 里一起删掉。
- 没做（另排批次，见报告第四节）：扫描页和结果页标题栏居中的模块名，加左边的“重新开始”（第 12 条）；侧栏图标角标（第 16 条）；换页先模糊再清晰（第 17 条）。

## 3. 建议的 DECISIONS 行

| # | 决定 | 影响 |
|---|---|---|
| D176 | 侧栏照 CleanMyMac 1:1：第一次扫描前是带文字的完整侧栏；本次启动里任何模块开始扫描或运行后，所有页面统一显示图标栏并保持；用户按 ⌃⌘S 或侧栏底部按钮手动切换后，本次运行按用户的选择来；不跨启动保存。取消 D141 各页各管各的收侧栏规则。 | 主窗口所有页面 |

## 4. 测试

- 新增 `SidebarScanFoldTests`（非窗口，3 个）：
  - 扫描前完整，扫描后收起，宽窗口也保持，手动展开后再扫描也不收回，窗口变窄仍会收起，新启动从完整开始；
  - 扫描前用户已手动选过，就保持用户的选择；
  - 画布：首页不算扫描，运行页一出现就记下“工作过”，退出运行页后本次启动一直保持。
- `CareStudioRenderReviewTests`：画布登记的先后规则改为测“背景是否漂动”。测试名改为 `testStudioChromeFollowsTheNewestPageStillOnScreen`，注释写明原来是 `testSidebarChromeFollowsTheNewestPageStillOnScreen`、测 `prefersSidebarRail`，并写了原来的期望值。
- `CareStudioNavigationTests`（窗口类）：改为 `testTheFirstScanFoldsTheSidebarOnEveryStudioPage`。
  - 开头 `resetForTesting()`，免得同一进程里前面的窗口测试留下状态；
  - 带结果数据、但还没扫描时，每条路线的侧栏都是 210 点；
  - 模拟一次扫描（运行页登记画布）之后，每条路线都是 64 点图标栏，窗口 1024、1500 宽时也是。
  - 原来是结果路线收起、隐私路线展开。`script/display-bound-tests.txt` 里的说明同步改了。
- `CareStudioWindowReviewTests` 新增 `testResultAndScanningPagesFitBesideTheFullSidebar`（窗口类）。完整侧栏现在会出现在扫描前，或用户手动展开后，所以要确认放得下：用真的侧栏组件加真的页面，拼成主窗口那样的两栏，页面包括智能扫描结果、智能扫描中、垃圾结果、垃圾扫描中、清理中；在 960×700、1024×734、1280×763 三种尺寸下检查侧栏 210 点、页面得到剩下的宽度，标题、卡片和圆按钮都在页面里、文字在圆按钮上方。设了截图目录时出整窗截图 `w22-fullsidebar-*`。
- `CareStudioCanvas.resetForTesting()` 只在 DEBUG 里有。原有测试的其他期望没改。

## 5. 验证

全部在 Xcode 27.1、`0bd6589f` 加本批改动上，按 D106 补充②的三段式跑，重活都先拿了 `heavy-build.lock`：

- debug 编译通过；release 编译、release 测试目标（`--build-tests -Xswiftc -enable-testing`）编译通过，本批文件无警告。
- 单个测试类：`SidebarScanFoldTests` 3/3，`CareStudioRenderReviewTests` 7/7。
- debug 非窗口三段（10-23 09:58–10:03）：主包 XCTest 5658 个 0 失败（29 个跳过；比 r23 的 5655 多本批 3 个）；CombinedStatusIconTests 285 个 0 失败；Swift Testing 135 个通过；没有通讯录相关行。
- release 非窗口三段（10:37–10:51）：主包 5403 个 0 失败（28 个跳过）；CombinedStatusIconTests 285 个 0 失败；Swift Testing 135 个通过；没有通讯录相关行。
- **未做：窗口类。**“虚拟屏 3 · Claude”从 10-22 23:44 起不见了，现在只有内建屏和“虚拟屏 1 · Codex”；借不借虚拟屏 1，已在问用户。所以这三项都还没跑：`CareStudioNavigationTests`、新的“放得下”测试和 960–1280 截图、窗口全量。屏回来，或用户同意借屏后马上补跑，结果补报。
- 未核对：没在真实 app 里亲手试（这台机器的桌面现在由 2.0.1 会话在做 1:1 对照，同一时间只能一个 Agent 操作）；没装测试版。

## 6. 下一步

- 补跑窗口类：上面三项，加窗口全量。
- D178：单位和千分位统一。
- 报告第四节第 12、13、16、14、17、15、18、20 条，分批做。
