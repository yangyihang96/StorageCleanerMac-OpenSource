# 交接：报告第四节第 16 条（侧栏图标角标）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `55581c6f`（第 10 次测试版的树，含 r35 修复）。草稿最早写在 `ec158fba` 上，叠到 `55581c6f` 时没有冲突。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求

报告原文：“侧栏图标角标：扫描中显示进度饼；智能呵护有待处理结果显示黄点；单个模块有结果显示白点（cmm/15、20、24）。我们只有转圈。”

CleanMyMac 实测（`1比1对照-20261023/cmm/11`–`24`、`cmm2/01`，按像素量）：

- 三种角标都是一个约 17 点的玻璃圆（白色约 15% 的底，约 30% 的细边），压在图标块的右上角。当前模块和其他模块都显示，图标条里看得到；完整侧栏只在扫描前出现，所以没有截到角标。
- 扫描中：白色扇形从 12 点顺时针长。智能扫描按整轮进度（cmm/11、12、13 约 17%、37%、65%）；单模块扫描按自己的进度（cmm/19 约 96%）。防护的恶意软件扫描在后台进行，切到别的模块页面时防护图标上照样显示（cmm/24、cmm2/01）。
- 智能扫描有待处理的结果：黄色光点（实测 #EECD57，cmm/14、15）。Start Over 后消失（cmm/17）。
- 单个模块有结果：白色光点，可以同时亮好几个（cmm/20、24，cmm2/01 里性能、应用、空间透镜三个）。
- 智能扫描时只有智能扫描一个图标有饼，被扫的各模块图标上没有（cmm/11–13）。

## 2. 改了什么

- 新文件 `Views/SidebarBadge.swift`：
  - `SidebarBadge`：`.progress(Double?)`（扫描中；不知道总量时是 `nil`）、`.attention`（黄点）、`.results`（白点），带读屏文字。
  - `SidebarBadgeInputs`：从各 store 读的标志。`SidebarBadge.badge(for:_:)` 是不依赖 store 的纯函数，方便单测。
  - `SidebarBadgeMark`：16 点玻璃圆。CleanMyMac 的是 17 点，配 50 点左右的图标块；我们的块是 44 点。
    - 饼是从 12 点顺时针的扇形（`SidebarBadgeSector`）；
    - 不知道总量时，在同一个玻璃圆里转 `CareStudioSpinningArc`；
    - 白点、黄点是带柔光的小圆点。
    - 颜色都走 `CareStudioInk`：夜间白色，日间深色字墨。
- 规则（“有结果”一律用页面自己的判断，侧栏和页面说法一致）：
  - 智能扫描：
    - 扫描中显示饼，比例 = 已结束的部分 ÷ 选中的部分，和扫描页的进度环（`SmartCareScanningPage`）同一种算法，两边一致，所以每扫完一部分跳一格。CleanMyMac 在一部分内部也会走（cmm/11 第一部分时约 17%）；要做到这样，得连扫描页的进度环一起改，归第 15 条（扫描中的页面）；
    - 运行（Run）中转圈；
    - 结果页等着处理（`stage == .results`）时显示黄点；
    - 完成或 Start Over 后什么都不显示。
  - 垃圾清理：主扫描（路由在垃圾清理）进行中显示饼，比例取 `DiskScanProgress`；页面不在首页时显示白点（与 `CleanupWorkspaceView` 的条件相同）。
  - 防护：
    - 浏览记录或恶意软件扫描中，转圈（两者都没有总量）；
    - 不在首页时显示白点。首页条件从 `BrowserPrivacyWorkspaceView.shouldUseHeroPresentation` 抽成 `static func showsLanding(browserPrivacyStore:malware:)`，页面和侧栏共用。参数名保持 `browserPrivacyStore`，因为 `PrivacyCleanupPresentationTests` 查的是 `!browserPrivacyStore.hasCachedResults` 这句原文。
  - 其他模块，扫描中转圈，有结果显示白点：
    - 性能：`isLoadingStartupItems` / `hasScannedStartupItems`；
    - 应用：`isLoadingInstalledApps` / `hasScannedInstalledApps`；
    - 杂乱：`isScanning` / `hasScanned`；
    - 空间地图：`isAnalyzingStorage` / `hasStorageAnalysis`；
    - 云盘：扫描中 / 扫完且有快照。
  - 我的工具：可搬移文件扫描中显示饼（有总量时画比例）。不显示白点（CleanMyMac 的“New”角标是第 20 条）。
  - 我的活动：不显示。
  - 智能扫描正在扫某一部分时，那个模块（防护的浏览记录、性能、应用、杂乱）不另画进度；恶意软件扫描照常显示在防护上。
- 位置：圆心在 26 点图标的右边缘、图标上方 6 点。图标条和完整侧栏都在这个位置。完整侧栏原来在行尾转圈，现在改到图标角上，和 CleanMyMac 的“New”角标一样挂在图标上。
- 读屏：行的 accessibilityValue 原来只有“已选择”，现在后面接角标说明，例如“已选择，有结果”“进行中，已完成 40%”。
- 改的地方：
  - `SidebarView.swift`：多观察 `SmartCareCoordinator.of(store)`、`BrowserPrivacyStore`、`MalwareScanStore`、`CloudCleanupModel.shared`；init 加可选的 `privacy:`、`malware:`，不传时用空的新实例；`isWorking` 换成 `badge`。SidebarView.swift 里没有加 `.animation` 或 `withAnimation`（`DesignSystemV2ReviewTests` 有计数），饼的动画放在新文件里，用 `AppMotion.resolved(.data, …)`。
  - `ContentView.swift`：SidebarView 多传 `privacy: browserPrivacyStore, malware: malwareScanStore`。
  - `CareStudioTheme.swift`：`CareStudioInk` 加 `badgeFill`、`badgeRim`、`badgeAttention`。
- 和 CleanMyMac 的差别：
  - 只有真实知道总量时才画比例：智能扫描、垃圾清理、我的工具的文件扫描。防护、性能、应用、杂乱、空间地图、云盘读不到总量，转圈，不编比例。
  - 智能扫描之后，CleanMyMac 的垃圾清理、防护等模块页回到首页（cmm/15），所以只有黄点。我们的模块页会显示同一份结果（例如 `cleanupSession(for: .green)` 接住智能扫描的会话），按“页面在结果页就亮白点”，会多出几个白点。主会话已记下，留给用户定，不在第 16 条里改。

## 3. 测试

- 新增 `SidebarBadgeTests`（非窗口）：
  - 智能扫描的饼、运行中、黄点，完成或 Start Over 后不显示；
  - 进度比例：按扫描页的算法数已结束的部分，未选中的部分不算；
  - 各模块先显示进度、后显示结果，空状态什么都不显示；
  - 智能扫描扫到的部分只画在智能扫描上，恶意软件扫描照常；
  - 进度比例沿用扫描页的规则（只有 determinate 才有比例）；
  - 用真实的 store 走一遍：登录项读取中、读完、恶意软件结果、Start Over、智能扫描扫描后立即停止（结果页等着处理，显示黄点）、重置；
  - 读屏文字；扇形从 12 点顺时针。
- `CareStudioModuleShellRenderTests.testRendersTheSidebarMarksForReview`（离屏渲染，不在 D106 窗口名单里）：
  - 图标条和完整侧栏，深色和浅色：智能扫描黄点，防护、性能、应用白点；
  - 深色图标条按像素检查：黄点、三个白点都在算出的位置上，垃圾清理、杂乱、空间地图那个位置上没有角标；
  - 另有“性能读取中”的转圈图，和七种角标单独放大的图；
  - 截图要设 `STORAGE_CLEANER_CARESTUDIO_EVIDENCE`。

## 4. 验证

Xcode 27.1，树是 `55581c6f` 加本批，在 heavy 锁里增量编译，10-24 02:20–02:24。

- 非窗口定向 9 个类，435 个测试，跳过 2 个，0 失败：SidebarBadgeTests、CareStudioModuleShellRenderTests（含角标截图和像素检查）、UIConsistencyRegressionTests、PrivacyCleanupPresentationTests、GeneratedArtTests、DayAppearanceTests、CareStudioMotionTests、SystemUtilitySafetyTests、SystemMonitorServiceTests。
- 静态检查：窗口类登记（D106）、删除清单、私有 API 三项通过。
- 截图核对（`~/Developer/.sc-build/cmm-ui-items-evidence/sidebar-marks-*`）：
  - 图标条：智能扫描黄点，防护、性能、应用白点，其余模块没有角标；
  - 完整侧栏：角标挂在图标右上角；
  - 单独放大的 7 种角标：17%、37%、65%、96% 的饼，转圈，黄点，白点。
- 没跑的：经过侧栏的窗口类交给主会话的窗口全量，用户没有就第 16 条同意我借屏。包括 CareStudioNavigationTests、CareStudioWindowReviewTests、MainWindowControlsTests、SafeCleanupLayoutTests、DesignSystemV2ReviewTests、FeatureLightfieldContractTests。
- 没在测试版里亲手看；没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| 第 16 条 | 侧栏模块图标右上角加 CleanMyMac 式玻璃角标：扫描中显示进度（知道总量时是从 12 点顺时针的白色扇形，不知道时转圈），智能扫描结果待处理显示黄点，模块页在结果页显示白点；判断沿用各页面自己的首页/结果条件；智能扫描扫到的部分只画在智能扫描上。 | 侧栏（图标条和完整侧栏） |
