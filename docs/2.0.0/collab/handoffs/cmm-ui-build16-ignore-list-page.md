# 交接：第 16 次 P1 忽略列表设置页版式、P2 提醒重置改名

日期：2026-10-25。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线 `dd49642f`（`41d5415f` 加“留一份”补丁）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 问题

- P1（第 15 次实测）：忽略列表设置页不能用。
  - 窗口矮时大标题和插画下面只剩约 100 pt。
  - 左边 11 个类别加 5 个分组标题放在 142 宽的滚动视图里，一次只看到 3 个。
  - 右边三行的条目只露出一行，LCU 报 `cannotClickOffscreenElement`。
- P2：“扫描与安全”页提醒一节的“重置忽略列表”清的是废纸篓与卸载提醒的忽略记录（`AppLifecycleIgnoreList`），和 D207 的忽略列表同名。

## 2. 原因

- 设置页的冻结几何（B6）：窗格矮于 650 时，标题在 y=24，内容从 108 开始，页脚占底部 108 pt，另加 24 pt 间隔。内容区高 = 窗格高 − 240。
  - 第 15 次的“只剩约 100 pt”相当于窗口约 441 高（窗格 340）。
  - 测试版保存的窗口是 934×673（窗格 572，内容区 332）。
- 旧页面有两层各自的滚动：
  - 左边类别每行约 32 pt（文字 24 加间距 8），11 类加分组标题约 489 pt；
  - 右边 `List` 和标题、提示、＋/－ 一起分剩下的高度，矮窗口里只剩一行。
- 在约 100 pt 的内容区里，任何排法都放不下 11 个类别。

## 3. 改了什么

选法：**给这一页一个最小内容高度，窗口不够高时整页一起滚动，同时压缩类别行距。**

- 理由：
  - 只在内容区里滚动，441 高的窗口仍然一次只看到三四个类别，等于没修。
  - 整页（大标题、内容、页脚）一起滚动时，标题和页脚可以滚出去。滚到列表处，类别、条目、＋/－ 一屏都在。
  - 不动窗口：不改窗口最小尺寸，切页签时也不改窗口高度。其他页签的高度和顶部页签栏（D154 3I）都不受影响。
  - 窗口够高时就是原来的冻结几何，不出现滚动。“够高”指内容区 ≥ 316 pt，即窗口高约 657 以上，包括测试版保存的 934×673 和默认的 1180×760。
- 新的 `SettingsIgnoreListPage`（`Settings/SettingsIgnoreList.swift`）：
  - 左列 152 宽，5 个分组标题（16 pt）加 11 个类别（每行 20 pt），组间 4 pt，共 316 pt，不再单独滚动。选中项用页签栏同款浅色底块。
  - 右列第一行是类别名，右侧是 ＋ 和 －（24 pt 方块，不可用时变淡）。下面一行“下次扫描起生效”；有提示时再一行，最多两行。
  - 条目列表每条固定 52 pt，三行：
    - 名称；
    - 路径，一行，中间省略，悬停看全路径；
    - bundle id（应用类才有）和加入时间。
  - 条目多了列表自己滚动。
  - ＋/－ 原来在列表下面，窗口矮时最先被挤掉。现在在类别名那一行：整页滚动时它们在页面内容的顶部，打开页面时就在屏幕上。
  - 条目列表从 `List` 改为自绘行：点一下选一项，⌘ 加选或取消，⇧ 连选，↑↓ 移动。选择逻辑抽成 `SettingsIgnoreListSelection`，可单独测试。
    - 改的原因：行高固定；几何断言要读到每一行的位置，`List` 行里的布局探针传不出来；观感也与设置页其他平铺行一致。
    - 多选和移除的行为不变。
  - 页内没有加图标（D64/B6）。＋/－ 是有动作的按钮符号，原来就有。
- 整页滚动的实现（`Settings/SettingsLightfield.swift`）：
  - `SettingsCategory.minimumContentHeight`：忽略列表是 316，其余页签为 0。
  - `SettingsLightfieldGeometry`：冻结的内容区矮于这个高度时，内容区撑到 316，页脚跟在内容后 24 pt，并记下 `documentHeight`；否则与原来逐字相同，`documentHeight` 等于视口高度。
  - `SettingsLightfieldPane`：有最小高度的页面（只有忽略列表）始终放在一个竖向滚动视图里，`documentHeight` 不大于视口时禁用滚动。这样窗口缩放跨过门槛时页面不会被重建，已选条目和列表位置都保留。其他页签仍走原来的代码路径。
  - 其他页签的几何不变，契约测试新断言了“其他页签不滚动”。
- P2（`AppLifecycleReminderSettingsSection.swift`），只改文字：
  - 按钮改为“重置已忽略的提醒”（Reset Ignored Reminders）；
  - 确认框标题改为“确定要重置已忽略的提醒吗？”，破坏性按钮同名；
  - 说明改为“之前选择忽略的卸载和废纸篓提醒会重新出现；忽略列表里的项目不受影响。”（这份记录只有卸载和废纸篓大小两种提醒）；
  - 按钮旁边的“已忽略的提醒：N 项”原本就没有提忽略列表，未改；
  - 仍调用 `center.ignoreList.reset()`（`AppLifecycleIgnoreList`），不碰 D207 的 `IgnoreListStore`；
  - 位置备注：这个按钮在“扫描与安全”页的“应用与废纸篓提醒”一节，紧接在“扫描提醒”一节下面。
- 没碰 `LeftoverAndInstallerScanners.swift` 和 `ApplicationsManagerModel.swift`。DECISIONS 没改，建议写法见第 6 节。

## 4. 测试

- 新的窗口断言，在设置窗口类 `SettingsLightfieldGeometryTests` 里，请主会话跑：`testIgnoreListShowsEveryCategoryWholeEntryRowsAndItsButtons`。
  - 7 个窗口：1180×760、934×673（测试版保存的窗口）、1000×700、1680×1050、820×560、560×441（第 15 次约 100 pt 的情形）、677×390。中英文各一遍。夹具是临时目录里的 `IgnoreListStore`，系统垃圾类 8 条。
  - 每个尺寸都断言：
    - 内容区不矮于 316；
    - ＋ 和 － 在屏幕内；
    - 11 个类别行都是 20 pt 高，按顺序，不重叠，都在内容区里。
  - 不滚动的尺寸：列表里至少 3 条完整条目，每行 52 pt；11 个类别和 ＋/－ 都在屏幕内。
  - 整页滚动的尺寸：先把页面滚到内容区顶端（宿主的 `scrollOptionsToReveal`，用法与 `ConceptLandingNativeLayoutRegressionTests` 相同），再断言同样的内容。
  - 677×390（窗格 289，比页面本身 316 还矮）：只断言能同时看到 3 条完整条目，滚到底能看到最后一个类别。
- 改了两条旧断言，测试里都写了编号、原断言和原因：
  - `SettingsLightfieldContractTests.testFrozenSettingsReferenceGeometryAndSevenSizeMatrix`（非窗口）：
    - 原为 `let bounds = CGRect(origin: .zero, size: size)`，现在按页面文档的范围；
    - 新加：其他页签的 `documentHeight` 等于视口高度（不滚动），忽略列表的内容区不矮于 316。
  - `SettingsLightfieldGeometryTests.testAllSevenPaneHostsMatchTheirGeometryAcrossSizesAndThemes`（窗口类）：
    - 原为 `XCTAssertTrue(viewport.insetBy(dx: -0.5, dy: -0.5).contains(actual))`，页脚也是同样的包含断言；
    - 现在对 `document` 断言。其他页签的 `document` 就是 `viewport`，并加了“不滚动”的断言。
  - 其余断言未删、未放宽。
- 新的非窗口类 `SettingsIgnoreListPageTests`，6 条：
  - 最小高度的算法；
  - 分组标题落在 `IgnoreCategory.group` 变化的地方（中英文）；
  - 哪些窗口整页滚动，滚动时内容区和页脚的位置，不滚动时与冻结几何相同；
  - 点选、⌘、⇧；
  - ↑↓；
  - P2 的源码断言。

## 5. 验证

Xcode 27.1。树是 `dd49642f` 加本改动，在 heavy 锁里增量编译（含测试目标，窗口测试也编进去了）。先在 10-25 16:03–16:06 跑了一遍；随后把忽略列表页改为始终在滚动视图里（见第 3 节），16:12–16:13 用最终的树重编、重跑了下面全部。本机 15:54 重启过，暂存区的脚本已按原样重建，锁照旧。

- 12 个非窗口类，128 个测试，0 失败，0 跳过：
  - SettingsIgnoreListPageTests、SettingsLightfieldContractTests、SettingsSourceContractTests、D64DeclutterAContractTests；
  - D207IgnoreListStoreTests、SettingsIgnoreListD207Tests、AppUpdateIgnoreD207Tests、D207IgnoreScannerTests；
  - UIConsistencyRegressionTests、AppLifecycleReminderTests、SettingsAccessTests、L10nTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。
- 离屏渲染自查（`ImageRenderer`，不开窗口；临时测试，不在补丁里）：
  - 934×673 亮色、1180×760 暗色：类别全部可见，条目三行完整，＋/－ 在右上角。这组渲染在改为“始终在滚动视图里”之前做（之后离屏渲染画不出这一页），页面本身的版式代码没有变。
  - 离屏渲染画不出滚动视图里的内容。条目行是临时去掉滚动视图后单独渲染看的，看完已恢复源码（与跑测试的源码相同）。
  - 布局探针给出的位置：
    - 934×673：类别列 108–424（内容区 108–440），条目列表 174–440，完整的 5 条；
    - 1180×760：内容区 176–527，完整的 5 条；
    - 560×441（整页滚动）：内容区 316 高、页脚在 448，完整的 4 条。
- 没跑窗口类（没借屏）。请主会话跑：
  - `SettingsLightfieldGeometryTests`：含新断言和改过的那条；
  - 建议顺带跑 `SettingsMiniWindowPreviewTests`、`CombinedStatusIconSettingsWindowTests`：它们的代码这次没改，但和设置窗格在同一处。
- 实机未看：整页滚动在真实设置窗口里的手感，以及 ↑↓ 的焦点（点过条目后生效）。
- 没装、没提交。

## 6. 建议的 DECISIONS 写法

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D2xx（第 16 次 P1） | **忽略列表设置页照 CleanMyMac 改版式**：左边 11 类连同 5 个分组标题一屏看全（行高 20、分组标题 16、组间 4，共 316 pt），不再单独滚动；右边类别名一行带 ＋/－（右上角），条目每条固定 52 pt 三行（名称、一行中间省略的路径、bundle id 与加入时间），条目多了列表自己滚动；自绘行支持点选、⌘、⇧、↑↓。页面最小内容高度 316（`SettingsCategory.minimumContentHeight`，其余页签为 0）：窗口够高时是原冻结几何；更矮时页脚跟在内容后，整页（大标题、内容、页脚）一起滚动。窗口尺寸、其他页签和顶部页签栏不变。 | D207 设置页的类别滚动列表和 `List` 条目 | `Settings/SettingsIgnoreList.swift`、`Settings/SettingsLightfield.swift`；测试 `SettingsIgnoreListPageTests`（新）、`SettingsLightfieldGeometryTests`（窗口类，新断言，改写一条）、`SettingsLightfieldContractTests`（改写一条） |
| D2xx（第 16 次 P2） | “扫描与安全”页提醒一节的“重置忽略列表”改为**“重置已忽略的提醒”**，确认框写明忽略列表里的项目不受影响；只改文字，仍只清提醒的忽略记录（`AppLifecycleIgnoreList`）。 | — | `AppLifecycleReminderSettingsSection.swift`；`SettingsIgnoreListPageTests` |
