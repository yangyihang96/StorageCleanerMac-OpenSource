# 交接：r35 两个失败的修复（第 12 条标题栏、D193② 可清除空间一行）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `ec158fba`（v2.0.1 当前树）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. MainWindowControlsTests.testContentViewNeverHidesTheWindowToolbar（D94 守卫）

- 原因：第 12 条把“重新开始”和模块名做成了窗口工具栏项（`CareStudioPages.swift` 里有 `ToolbarItem` 和 `.toolbar {`）。结果页有工具栏项、首页没有，窗口在这两种页面之间切换时，红绿灯和整个侧栏会上下跳 10 点。主会话量了 r35 的截图：
  - `w23-titlebar-cleanup-results-full`：红绿灯 y≈26，侧栏第一项 y≈78；
  - `w23-titlebar-protection-landing`：红绿灯 y≈16，侧栏第一项 y≈68。

  这正是 D94 修掉的问题，守卫没错，不放宽。
- 改法（`CareStudioPages.swift`）：
  - 去掉工具栏项，整个 Sources 里不再出现 `ToolbarItem` / `.toolbar {`。
  - 页面布局完全不变：内容仍在安全区里，从标题栏那一条下面开始。
  - `CareStudioPageFrame` 用 `GeometryReader` 读页面在窗口里的顶边（`frame(in: .global).minY`），也就是页面上方那一条的高度。窗口是 full-size content，这一条就是标题栏。
  - 结果页、扫描页把 `CareStudioTitleBarRow` 用 `offset(y: -band)` 挪进这一条：模块名居中（13 点 semibold，不接收点击，那里仍能拖动窗口），“重新开始”在左边，离页面左缘 `pageInset`。首页什么都不画。
  - 页面上方没有至少 28 点的空间时（全屏、离屏渲染、普通标题栏的测试窗口），这一行在页面顶部自己占 28 点，内容往下让，不会互相压住。
  - 没有用安全区来定高度。第一版是在 `ignoresSafeArea` 的 GeometryReader 里读 `safeAreaInsets.top`，在分栏视图里读到的是 0，结果这一行偏高 2 点、内容上移 4 点，被窗口检查查出来（CareStudioWindowReviewTests 报结果页标题伸出页面）。现在这个写法不动页面布局。
  - 确认框、Start Over 的启用条件（工作租约）、测试钩子都不变。

## 2. SpaceMapTreemapWindowTests.testTheTopOfADiskEndsWithItsPurgeableSpace（D193②）

- 结论：是产品问题，不是测试定位不对。r35 的 `evidence-spacemap/b-purgeable-1024-zh-dark.png`、`b-purgeable-1024-en-light.png` 里，“目录”只有 Users、Applications、System 三行，那一行确实没画出来。
- 原因：
  - 页面上的显示条件写成了 `atTop: navigation.isEmpty`。可是 store 扫完后在顶层时，navigation 就是 `[rootSnapshot]`（`LargeFilesStore` 第 529、580、1287 行），从来不是空的。所以真实 App 的 / 根上同样永远不显示，测试宿主也是 `[root]`。
  - 非窗口单测直接给规则函数传 `atTop: true`，没测到调用处。
  - “The blocks map did not settle” 只是等这一行出现等到超时的通用提示。
- 改法：
  - `SpaceLensPurgeable.bytes` 改成接收当前显示的目录（`snapshot:`），用 `snapshot.path == result.rootSnapshot.path` 判断是否在顶层；
  - `CareStudioSpaceLens.swift` 的调用处传页面自己的 `snapshot`（`navigation.last ?? result.rootSnapshot`）。
- 真实的 / 根：扫内置磁盘时 `target.kind` 是 `.internalVolume`，`rootSnapshot.path` 是 `/`，扫完 navigation 是 `[rootSnapshot]`，所以 `snapshot.path == "/"`，在可清除空间大于 0 时显示。打开子文件夹后不显示；回到顶层又显示。

## 3. 测试

- `CareStudioNavigationTests.testResultsShowStartOverAndTheModuleNameInTheTitleBar`（窗口类）：
  - 原来从窗口工具栏的项里按 x 排序找这两个按钮。现在改为读布局探针（`careStudio.titleBar.startOver`、`careStudio.titleBar.title`），测试里写了“第 12 条 + 旧断言 + 原因”。宿主照 `SafeCleanupLayoutTests` 的做法记录探针。
  - 每个结果页都查：“重新开始”在模块名左边，不压到红绿灯；两者和红绿灯在同一行（垂直中心差 ≤ 2 点）；在“重新开始”中心点一下，命中的是页面内容（`window.contentView` 的子视图），不是标题栏。
  - D94：首页、图标条结果页、Start Over 之后，红绿灯的位置和结果页完全一致；侧栏的 y 一致；窗口工具栏里没有任何带视图的项。
- `SpaceLensPurgeableTests`：调用改成传目录（写明旧断言）；新增 `testThePagesTopIsTheRootTheStoreKeeps`，即 store 在顶层时 navigation 为 `[root]` 的回归测试。

## 4. 验证

用 Xcode 27.1，树是 `ec158fba` 加本批；换树后在 heavy 锁里重新编译，编译通过。

- 非窗口定向（10-24 01:00–01:01），全部通过：
  - CareStudioModuleShellRenderTests、CareStudioMotionTests、CareStudioRenderReviewTests、DayAppearanceTests、SpaceLensPurgeableTests、UIConsistencyRegressionTests；
  - 第一轮还跑过 SpaceLensSidebarTests、GeneratedArtTests，都通过。
- 窗口类：在虚拟屏 1 · Codex 上跑，属于用户借屏给第 12 条做窗口检查的范围，先拿 heavy 锁、再拿窗口锁；10-24 01:01–01:07，3 个类 17 个测试，0 失败，和基线一致。
  - CareStudioNavigationTests：含新加的标题栏和 D94 检查；
  - MainWindowControlsTests：含 `testContentViewNeverHidesTheWindowToolbar`；
  - CareStudioWindowReviewTests：含 `testResultAndScanningPagesFitBesideTheFullSidebar`。
- 整窗截图（`~/Developer/.sc-build/cmm-ui-fix-window-evidence2/w23-*`）：
  - `w23-titlebar-cleanup-results-full`、`w23-titlebar-protection-landing`：红绿灯都在 y≈16，侧栏第一项都在 y≈68；
  - 结果页的“重新开始”和居中的“Cleanup”文字在 y 10–22 之间，中心 16，和红绿灯同一行；
  - r35 时结果页是 26 / 78。
- 测试里用断言确认：红绿灯的位置在首页、图标条结果页、Start Over 之后都和结果页完全相同；侧栏的 y 一致。
- 第一版的窗口运行查出“这一行偏高 2 点、内容上移 4 点”（CareStudioWindowReviewTests 报结果页标题伸出页面），已在第二版改掉，见 §1。
- 三项静态检查通过：D106 窗口类登记、删除清单、私有 API；Sources 里没有 `ToolbarItem` / `.toolbar {`。
- 没跑的：
  - D193 的窗口类 SpaceMapTreemapWindowTests：用户没有就 D193 同意我借屏，由主会话合并后跑；
  - DesignSystemV2ReviewTests、FeatureLightfieldContractTests 里开窗口的用例：它们是窗口类，我误放进了非窗口批次，被 D106 门拒绝，没在窗口里跑。这两个类没读本次改过的文件里会变的内容。
- 没有装测试版，没有提交。
