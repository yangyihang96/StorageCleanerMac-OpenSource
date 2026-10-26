# 交接：D154 全界面照 CleanMyMac 5 改版（第一批：外壳＋应用管理）

日期：2026-10-20。会话：Claude「CleanMyMac 卸载升级功能逆向」。工作树：`~/Developer/sc-worktrees/cmm-ui`（分支 `task/cmm-ui`，基线树 `93483d78` = v2.0.1 工作区 2026-10-20 21:01:53 快照，2.0.1 会话确认当时空闲）。未提交、未安装、未推送。

## 1. 用户要求（原话）

> 去逆向工程 CleanMyMac，把他的 UI 界面都复制过来，把我们的 UI 界面做成和他们一样的，如果他们有的功能我们没有就直接 1:1 复制，如果我们有的他没有的就把界面逻辑学过来，如果都有的功能就 1:1 复制过来

依据和完整方案在 `~/Claude 好玩的/CleanMyMac全界面逆向-2026-10-20/`：`CMM模块规格.md`（CleanMyMac 5.7.2 全部 44 张本地化表、资源名、HEIF 动画按模块整理）、`我们的功能清单.md`、`改版方案.md`、`截图/`。

## 2. 第一批改了什么

### 2.1 侧栏＝CleanMyMac 的 10 个模块（`Views/SidebarView.swift` 重写）
- 平铺 10 行，无分组标题：智能扫描、垃圾清理、安全防护、性能优化、应用管理、杂乱文件、空间地图、云盘清理；底部我的工具、我的活动。模块名用通用词，不用 CleanMyMac 的产品名。
- 行高随窗口：高窗口 50 pt 一格（CleanMyMac 实测），矮窗口最低 36 pt，十行在最小窗口里放得下；比最小还矮时列表滚动（`ViewThatFits`）。
- 图标：D58 图按模块色调色（`CareStudioFamily.hueRotation(for:)` 按每张图的主色相算），26 pt；夜间未选中的去色成浅色玻璃，选中的保留颜色（CleanMyMac 侧栏同样做法）。
- 选中块：在模块渐变上是半透明白块（`CareStudioInk.sidebarSelection`）；还没改成 Care Studio 的页面上保留 D3 的模块色块。扫描中的模块行尾转小圈。
- 设置行从侧栏移出，走 App 菜单 ⌘,（CleanMyMac 侧栏没有设置）；底部保留版本行（D94 的测试版标记）和“收成图标栏”按钮。
- 一行打开模块的第一页（`CareStudioFamily.primaryRoute`），模块里的任何页都让这一行保持选中（`CareStudioFamily(route:utility:)`）。

### 2.2 模块与颜色（`Views/CareStudio/CareStudioTheme.swift`）
- 新增 `CareStudioFamily`（10 个模块：标题、配色、路由、图标、说明）。配色：原有的智能扫描、垃圾清理、性能；新增安全防护（取自本次截图 `截图/p01`）、应用管理、杂乱文件、空间地图、云盘清理、我的工具、我的活动（按各模块 3D 插画色相推算，待补截后校准）。
- 开发者垃圾归入“垃圾清理”，改用绿色（CleanMyMac 的 Xcode 垃圾、AI 垃圾都在 Cleanup 里）。
- `CareStudioModule` 新增 `.applications`、`.cloudCleanup`、`.myTools`、`.myActivity`；`CareStudioBackdrop` 可按模块族画（`init(family:)`），侧栏任何 Care Studio 页都铺同一张渐变。

### 2.3 新增三个页面（CleanMyMac 有、我们没有的入口）
- **我的工具**（`CareStudioMyTools.swift`）：工具卡网格＋搜索＋收藏（`myTools.favorites.v1`），每个不是模块首页的页面都有一张卡（性能测试、系统健康、能耗、文件搬家、开发者垃圾、内存管理、登录项、卸载程序、应用更新、浏览器隐私、重复文件、相似照片）。CleanMyMac 模块的单项工具用模块色，我们独有的工具保留原图颜色。
- **我的活动**（`CareStudioMyActivity.swift`、`Features/Activity/MyActivitySummary.swift`）：四张统计卡（本机清理、本月、清理次数、可以放回）＋最近操作＋“操作记录”入口。数字全部取自操作回执（与“操作记录”同一份日志），不估算；“移到废纸篓”和“清倒废纸篓释放”分开写（D93）。
- **云盘清理**（`CareStudioCloudCleanup.swift`、`Features/CloudCleanup/CloudDriveScanner.swift`）：起始 → 只读读取 iCloud 云盘（只读元数据，不下载、不改动）→ 结果卡（本机已下载、超过 100 MB 的、只在云端的、其他云盘）→ D90 原有的“释放本地副本”审阅（文件留在 iCloud，不删除、不进废纸篓）。CleanMyMac 登录 Dropbox/Google Drive/OneDrive 和“从云端删除”需要账户授权，没做。

### 2.4 应用管理整套换成 Care Studio（D151 逻辑不变）
- 起始页（左图右文＋三条要点＋圆按钮“扫描”）、读取页（`CareStudioApplications.swift`）。
- 结果卡（`CareStudioApplicationsOverview`）：应用更新、长期未用、应用残留（后台查找中有占位卡）、安装文件、32 位、macOS 更新、挑出用不到的应用；顶部“卸载记录”“重新扫描”，标题下“管理我的应用”。
- 管理器（`ApplicationsManagerView` 改用新的通用 `CareStudioManagerChrome`）：渐变上的浅色大面板，左栏是 CleanMyMac 的分类（全部、未使用、可疑、勾选的，商店、提供商、插件、其他），右边是 D151 原有的列头和行；底栏左“更多”菜单，中间计数，右边粉色主按钮（CleanMyMac 各模块的管理器都用同一个粉色）。
- 移除中、完成页也换成 Care Studio（`CareStudioApplicationsRemoving`、`CareStudioApplicationsCompletion`）。
- 改写成我们自己的话（D123/D141 不用对方整句）：卸载概览各卡说明、残留查找中的说明、卸载自身的确认、完成页标题与说明、`ManualUpdateExplanation` 两段说明——这些在 D151 里是 CleanMyMac 原句的直译。

### 2.5 所有模块的起始页、运行页换成 CleanMyMac 的样子（模板级）
- `FeatureLightfieldPage` 的起始、运行两种状态和 `FeatureRunningTemplate` 改由 Care Studio 模板画（`Views/CareStudio/CareStudioTemplatePages.swift`）：左图右文（模块名做标题、说明、页面自己的选项、状态行、“操作记录”等小按钮），底部居中圆按钮，右下角安全说明；运行页是浮动插画＋阶段＋当前项＋圆“停止”。每页的选项、动作、安全说明、进度都不变，只换版式。涉及隐私、重复文件/相似照片、大文件、文件搬家、应用更新、系统健康、能耗、性能测试等所有还在用 D67 模板的页面。
- 圆按钮只显示动词（CleanMyMac 的圆按钮都是一个词）：“扫描浏览器隐私”显示“扫描”，完整说法留在 VoiceOver 标签和悬停提示（`CareStudioActionTitle.short`、`CareStudioActionButton.fullTitle`）。
- 选项区按内容实际高度排（读 `FeatureOptionsScrollView` 量到的文档高度），最多约页高 60%，超出才滚动；窄而矮的窗口不放插画，给选项留地方。
- 结果页暂保留 D67 结果版式，铺在模块渐变上（分隔线改用 Care Studio 的颜色），后续各模块换成自己的管理器。
- `MainContentHost`：每个模块页都铺所属模块的渐变、去掉顶部操作记录带；测试里设 `careStudioClassicResults` 时保持原来的画布和 D94 操作记录带（沿用 D141 做法：旧版式测试继续量旧版式，新版式另有测试）。
- 修一个 macOS 菜单的显示问题：`borderlessButton` 菜单的标签若是两段 Text，只显示第一段（清理会话发现）。应用管理器、垃圾管理器（排序、“选择：”）、登录项管理器的标签都改成一个拼接的 Text。
- 颜色跟着模块走：D67 的强调色表（勾选框、链接、结果页主按钮）改为所在模块的圆按钮颜色（`CareStudioFamily(route:).palette.action`），例如隐私→安全防护粉、健康/能耗/性能测试/文件搬家→我的工具紫、卸载/更新→应用管理蓝；智能扫描和垃圾清理两项不变（设置页在用）。模块渐变上的 `.tint` 改为该模块的亮色（夜间）/深色（日间），原来青色渐变上的青色菜单标签几乎看不见。
- 版面在最小窗口也成立：安全说明只占圆按钮右侧的空间、放不下就换行；D141 起始页的文字栏放不下时原地滚动、窄而矮时不放插画；Care Studio 页框和管理器面板声明自己管滚动（`.pageOwnsScrolling()`），外层不再撑 468 pt 最小页高把圆按钮推出窗口。
- 应用管理器的列头固定在列表上方（CleanMyMac 同样），滚动区只放行：原来列头和行套在两层懒加载列表里，SwiftUI 对没显示的行估高不准（400 个应用只估出约 247 行高）。

### 2.6 其他
- 导航菜单改成 CleanMyMac 的“显示”菜单：10 个模块按侧栏顺序，⌘1–⌘9。
- Care Studio 页不再画顶部 52 pt 的 `MainWindowHistoryBand`，模块渐变一直铺到标题栏下（清理会话列出的“顶部色带不一致”）；这些页的“操作记录”入口在“我的活动”。
- 修 2.0.1 测试版启动日志里的两条运行时警告：
  - AppKit “layoutSubtreeIfNeeded on a view which is already being laid out”（`AppLifecycleAlertPanelController`）：卡片尺寸改为读 intrinsic size，在 SwiftUI 让卡片失效尺寸后下一轮主线程再调整，不再在布局中途强制布局。
  - SwiftUI “onChange(of: CGRect) action tried to update multiple times per frame”（`CareStudioBackdrop`）：窗口尺寸的报告合并到下一轮主线程统一写一次。

## 3. 建议写入 DECISIONS 的条目（编号由 2.0.1 会话分配）

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D154 | **全界面照 CleanMyMac 5.7.2 改版**（用户 2026-10-20，原话见交接 §1）。照搬版式、流程、交互、配色关系和用词风格，不用对方代码、图片、品牌和整句原文（同 D123/D141）；安全语义全部不变（只读扫描、进废纸篓＋回执、D23/D101 L5、D47/D52、D93、D143、D144、D151）；日间独立设计不变。<br>**侧栏**＝CleanMyMac 的 10 个模块平铺（上 8 下 2），模块里任何页都让该模块行选中；设置走 App 菜单 ⌘,；版本行保留。<br>**模块与颜色**：每个模块一个颜色族（`CareStudioFamily`），开发者垃圾归入垃圾清理（绿）。<br>**新页面**：我的工具（工具卡＋搜索＋收藏）、我的活动（回执统计，不估算）、云盘清理（只读 iCloud＋D90 释放本地副本，不接第三方云账户）。<br>**应用管理**整套换成 Care Studio（D151 逻辑不变），D151 中直译 CleanMyMac 的句子改写。<br>**所有模块的起始页、运行页**换成 Care Studio 模板（左图右文、页面选项按内容高、圆按钮只写动词，完整说法在 VoiceOver 和悬停提示）；结果页暂保留 D67 版式铺在模块渐变上。<br>模块页不再有顶部操作记录带；测试设 `careStudioClassicResults` 时保持旧画布（同 D141）。 | D53/D3/D44① 的模块色映射与侧栏分组；UI-V2 侧栏分组折叠；D94 中模块页的 `MainWindowHistoryBand`；D67/D70 起始页、运行页版式（生产页面，测试里的经典版式保留）；D67/D77 卸载结果骨架（卸载页）；D151 中 CleanMyMac 原句 | 侧栏、导航菜单、Care Studio 主题与模板、三个新页面、卸载页、所有模块的起始页和运行页；测试见交接 §4 |

## 4. 测试（改期望的都注明 D154）

- 新增 `CareStudioModuleShellRenderTests`：侧栏＋新页面、应用管理各页的离屏渲染（设 `STORAGE_CLEANER_CARESTUDIO_EVIDENCE` 出图），模块归属与“每页都有入口”的检查，最短窗口十行放得下。
- 改：`GeneratedArtTests`（26 pt 模块图标）、`L10nTests`（新增三个目的地标题）、`PrivacyCleanupPresentationTests`（隐私说明改查模块说明与工具卡）、`SystemMonitorServiceTests`、`SystemUtilitySafetyTests`（侧栏、导航菜单、延后更新选择）、`UIConsistencyRegressionTests`（侧栏结构、设置入口、图标大小、行高）。
- 新增（模板级改版）：`CareStudioWindowReviewTests.testTemplatePagesKeepTextOptionsArtAndActionApartAtEverySize`（窗口类，8 个模块的起始页和运行页＋应用管理起始/移除中＋云盘清理起始，4 种窗口尺寸：文字、选项、插画互不遮挡，都在圆按钮上方和窗口内，圆按钮在窗口内，安全说明不压圆按钮）；`testTemplatePagesRenderInAWindowForReview`（真窗口出图，含选项列表和结果页）；`CareStudioModuleShellRenderTests.testRendersEveryModuleLandingAndRunningPageForReview`（离屏出图）。
- 改（注明 D154）：`DesignSystemV2ReviewTests`（侧栏不再有折叠分组的两处布局动画，只剩选中与悬停，仍按“减少动态效果”）、`FeatureLightfieldApplicationP2Tests`（管理器：搜索排序在面板标题行，列头固定在行上方，可见顺序不变）、`FeatureLightfieldContractTests`（侧栏 26 pt 图标、`SidebarChrome` 带模块族、操作记录带规则加模块页）。
- 改（卸载结果页＝管理器，D154）：`FeatureLightfieldContractTests` 里卸载结果的四个窗口测试按原意改到管理器上——点行只勾选、不打开预览、不开始移除（等管理器底栏主按钮）；400 个应用只排可见行（管理器的懒加载文档 `careStudio.manager.document`）；参考窗口至少 10 行完整可见、滚到底能看到最后一个应用、底栏主按钮滚动时不动（`testUninstallManagerListUsesThePanelShowsTenRowsAndLastItemIsReachable`，取代 `testResultLongListUsesFullViewport…`）；结果页保留“卸载记录”入口（`testUninstallResultsKeepTheUninstallHistoryEntry`）。两个 D67 骨架测试（pilots 三态、结果页填满）跳过卸载结果，其余模块照旧。

## 5. 验证

- 编译：`swift build`、`swift build --build-tests` 均通过（Xcode 27.0.0 Beta，`-disable-batch-mode`）。
- 非窗口全量（`--skip` 显示器类）：5390 个测试，25 个跳过，0 失败（2026-10-20 22:54；全部修改完成后 2026-10-21 00:1x 复跑，同样 0 失败）。
- 补丁：`~/Claude 好玩的/CleanMyMac全界面逆向-2026-10-20/cmm-ui-D154-第一批.patch`（基线树 93483d78 → 结果树 a7c02a74，48 个文件），在 v2.0.1 当时的工作区 `git apply --check` 通过。
- 窗口类（D106，`script/run_display_bound_tests.sh`，虚拟屏 1 · Codex 1920×1080，独立 scratch）：
  - 基线（快照 93483d78 原样，`~/Developer/sc-worktrees/cmm-ui-base`）：614 个测试中 85 个方法失败，全部是环境原因或基线已有问题：测试要的窗口比这块屏大（1998/2190/2204 宽、1022 高被压到 1920/1018，“frames did not settle”）、菜单栏小窗/设置预览（D118–D152 在这块屏上的已知差异）、风扇卡、GPU 字形覆盖率、常驻启动计时、照片源码表。
  - 第一批（外壳＋应用管理）：比基线多 9 个，5 个是源码契约（侧栏折叠动画、卸载管理器结构、侧栏 26 pt、`SidebarChrome`、操作记录带规则），4 个是卸载结果页窗口测试（卸载页已是管理器）；均已按原意改写（见 §4），没有放松断言。
  - 模板级改版后全量窗口类（虚拟屏 1）：与基线相比只多 2 个，均已修（见下）。
  - 加了一块更大的测试屏（用户同意“可以再开一块屏幕”）：“虚拟屏 2 · Claude”，2560×1600，由 `~/Developer/.sc-build/virtual-display/vd` 进程维持（结束进程屏即消失）。在这块屏上基线只剩 43 个方法失败（菜单栏小窗、设置预览、风扇卡、GPU 字形、照片源码表、常驻计时——都与本批无关）；cmm-ui 最终版 617 个测试的失败集合与基线**完全相同（43 对 43，无新增）**。第一次大屏运行中途 xctest 崩过一次（`MSeriesV11NativeLayoutTests` 量文字时 CoreText 复制字体属性遇到空值，系统 beta），复跑和基线都通过，判为偶发。
  - 新写的窗口测试在大屏通过：模板页 4 种窗口尺寸版面（含 D141 起始页）、卸载管理器十行/滚到底/底栏固定、卸载记录入口；真窗口截图（含选项列表）在 scratchpad。截图用 AppKit 缓存绘制，不画图层滤镜（色相旋转、模糊），所以截图里插画是原色、圆按钮光晕不模糊；颜色和模糊以离屏渲染图为准。

## 6. 下一批

安全防护（隐私、安全检查、应用权限只读）、性能优化（维护任务＋登录项＋后台项目＋释放内存；维护任务页由清理会话在 `feature-parity` 做）、杂乱文件、空间地图、我的工具里各工具页、通知中心铃铛、设置窗口改成 CleanMyMac 的页签、首次引导、智能扫描的 5 张模块卡。菜单栏小窗是否也照 CleanMyMac Menu 改，等用户决定（与 D118–D140、D152 的 iStat 方案冲突）。
