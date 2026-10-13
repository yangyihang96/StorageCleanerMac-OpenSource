# r2-ui-v1：D62 全功能起始页与运行页

初版基线 `3fe50e3ebe05f0b0f3fff7b010b91562005ac9da`，分支 `task/r2-ui-v1`。第 10–19 节保留前十二轮记录；当前 R13 基线仍为 `facd1cf4c3bf40c219b311ca85376dd64f861052`，接手时 R12 源码已写入但未提交。`prepared-r13/` 为相对该基线的完整累计逻辑补丁，替代 `prepared-r12/`，详见第 20 节。主会话 R12 build 通过、982 项中 4 跳过／1 失败，是修复前外部证据；R13 尚待验证。本会话没有构建、类型检查、运行 XCTest、启动应用、拍图、暂存或提交。

## 1. 功能映射、动作和迁移

表中路径相对 `Sources/StorageCleanerMac/`。13 个初始页进入 `FeatureLandingTemplate`，内存按第 13 节使用同一 `FeaturePageScaffold` 的全宽仪表盘变体；`HeroScanPage` / `FeatureLandingPageShell` / `FileToolLandingPage` 保留兼容 API。重复文件包含相似照片模式。

| 功能 / 路由 | 基线起始页实现 | 本批迁移 | 主按钮文案 / 原动作 | 运行页与取消能力 |
|---|---|---|---|---|
| 智能扫描 `overview` | `Views/MainWorkspaceViews.swift` / `SmartCareLandingView` | 共用外壳；三类范围用 `FeatureOptionRow` | 开始扫描／重新扫描 → `startScanRespectingAccessGuide` | `SmartScanScanningPage` → 共用模板；`cancelMainScan` |
| 安全清理 `green` | `Views/ContentView.swift` / `ToolPreparationView` | 共用外壳；范围卡用 `FeatureOptionCard`，选择集合和全取消选择状态保留 | 开始扫描／原重新扫描文案 → `startScanRespectingAccessGuide` | `ScanProgressView(module:)` → `SmartScanScanningPage`；`cancelMainScan` |
| 开发工具与产物 `devCaches` | 同文件 / `ToolPreparationView` | 共用卡宽；四类图块与原阈值控件保留 | 原扫描文案 → `startScanRespectingAccessGuide` | 同上，保留阶段列表与分类数据 |
| 系统健康 `healthHub` | `Views/ComputerHealth/ComputerHealthWorkspaceView.swift` / `healthLanding` | 共用外壳；能力卡用同族表面；有／无／未知电池条件及说明保留 | 开始健康检查 → `startHealthCheck()` → `healthStore.refresh(force:)` | 共用运行页；现有健康读取没有取消 API，统一取消槽显示高对比度说明 |
| 浏览器隐私 `privacy` | `Views/BrowserPrivacyWorkspaceView.swift` / `heroPage` | 日期范围改 `CapsuleSegmentedControl`；自定义日期仍无预设高亮；分组、搜索与授权入口保留 | 原开始／重新扫描文案 → `startScan()` | 共用运行页；`cancel()`；保留旧结果的再次扫描也进入运行页 |
| 性能测试 `performance` | `Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift`，原来直接显示仪表盘 | 新 `PerformanceBenchmarkLandingView`；CPU/GPU/内存/存储四行；历史入口仍可达；已有结果仍走原仪表盘 | 开始性能测试 → `startOfficialBenchmark` | 共用运行页；原阶段网格与 `BenchmarkSystemMonitor` 保留；复用 `BenchmarkV7DashboardView.allowsCancellation(during:)` 和 `cancelV7`，最终保存不可取消 |
| 登录项与后台任务 `startup` | `Views/SystemUtilitiesView.swift` / `StartupItemsView.startupLanding` | 共用外壳；显式开始、不新增自动任务 | 读取启动项 → `refreshStartupItems()` | 共用运行页；读取进度的 `title` / `discoveredCount`；`cancelStartupScan` |
| 内存管理 `memory` | 同文件 / `MemoryOptimizerView`，原为仪表盘 | 同框架的仪表盘起始变体；恢复 V0 全宽总览与趋势图，进程表填满余下高度，选择／退出条固定，仅进程列表滚动；刷新沿用共用坐标和令牌 | 刷新 → `refreshMemory()` | 读取与优化进入共用运行页；读取无取消 API，优化调用原 `cancelMemoryOptimization`；采样、建议选择、退出确认和结果仪表盘保留 |
| 能耗 `energy` | `Views/EnergyImpactScanLandingView.swift` | 共用外壳；六阶段全文保留 | 开始测量 → `scanEnergyImpact()` | 共用运行页；原阶段明细和阶段进度；读取没有取消 API |
| 卸载 `uninstall` | `Views/AppUninstallScanLandingView.swift` | 共用外壳 | 读取应用列表 → `refreshInstalledApps()` | 共用运行页；读取没有取消 API；卸载确认／执行不改 |
| 应用更新 `updater` | `Features/AppUpdates/Views/AppUpdatesView.swift` / `AppUpdateIdlePage` | 共用外壳；四来源、上次摘要、管理按钮保留 | 检查更新 → `refreshAppUpdates` | `AppUpdateScanningPage` → 共用模板；阶段轨、当前应用、原停止帮助文案保留；`cancelAppUpdateScan`；本软件更新入口移入运行页页头 |
| 文件分析 `largeFiles` | `Views/LargeFilesView.swift` / `LargeFilesScanLandingView(.analysis)` | 原独立按钮移入卡底；原范围选择和图例保留 | 分析磁盘空间／重新分析磁盘 → `startSelectedScan` → 原存储索引读取 | 共用运行页；`cancelStorageAnalysis()`；有旧索引时再次分析也路由到运行页 |
| 文件搬家 `migration` | 同文件 / `LargeFilesScanLandingView(.migration)` | 共用外壳；来源／目标／类型／安全说明保留；类型用胶囊分段 | 扫描可搬移文件／扫描可搬移 App，及原重新扫描文案 → `startSelectedScan` | 文件扫描调用 `cancelScan()`；应用清单读取没有取消 API；复制、验证、原件处理和恢复不改 |
| 重复文件 `duplicates`（含相似照片） | `Views/SystemUtilitiesView.swift` / `DuplicateFilesView.duplicateScanHero` | 共用外壳；扫描范围改胶囊分段；“仅添加位置”原禁用理由与 setter 守卫保留；文件夹／外接卷入口和新增位置集合保留 | 原开始／重新扫描文案 → `scanDuplicateFiles` | 共用运行页；原暂停／继续动作和 `cancelDuplicateFileScan`；保留旧结果的再次扫描也进入运行页 |

本表所有功能都有可显示的读取／扫描／测量运行状态。健康、能耗、应用清单读取（卸载及搬家 App 模式）、内存读取没有可用取消接口；没有虚构接口，固定槽显示“此任务不可取消”。内存优化和文件搬家复制等操作的确认／执行流程仍由既有模型拥有。

## 2. 模板 API 与令牌

`FeatureLandingTemplate<Accessory>` 沿用 `FileToolLandingPage` 的构造参数：标题、副标题、模块图标、区块标题、主按钮文案／图标、状态、加载／禁用条件、安全说明、原动作和 accessory builder。保留 `optionsLayout: FeatureLandingOptionsLayout = .scrolling` 与旧 `.dashboard` 兼容入口；R5 内存直接使用 `FeaturePageScaffold(isDashboard: true)` 的全宽变体和 `FeatureFixedDashboardSlot`，只有内部列表滚动。`FileToolLandingPage` 是其类型别名；调用方无需重写业务动作。

`FeaturePageScaffold` 统一页头 → 左卡／右轨道 → 底部 `StatusFooter`。panel builder 收到**页面视口**解析出的 `LandingMetrics`，不会用卡片自身宽度再判断窗口档位。页头统一 `AppPageHeader(role: .landing)`，外壳占满可见高度；普通左卡只有选项区域滚动，仪表盘只有内部进程列表滚动。卡片的自然内容高度不再决定主按钮坐标。

`FeatureRunningTemplate<Details, Actions>` 参数：`module/title/subtitle/state/fraction/metrics/currentItem/elapsedSeconds/taskIdentity/pageTitle/pageSystemImage/trustText/canCancel/cancelTitle/cancelHelp/onCancel/litNodeCount`，以及 details/actions builder。原 `FeatureRuntimePage` 是新模板别名；旧执行页面明确使用 `LegacyFeatureRuntimePage`。阶段、原生 `ProgressView`、中间省略当前项、已用时间、取消槽位均有可访问标签与 Debug frame probe。路径帮助保留全文。停止状态禁用取消，暂停状态停止轨道旋转。

| 令牌或规则 | 值 / 来源 |
|---|---|
| 主按钮高度／字号／圆角 | `FeaturePageTokens.primaryHeight = 52`；`primaryFont = TypeScale.buttonLarge`；`primaryCorner = Corner.largeButton` |
| 主按钮图标圈／符号 | `38 / 18 pt`；智能扫描图标沿用原 emblem |
| 主按钮左右／上下内边距 | `20 / 6 pt`；原 `GradientButtonStyle.Size.large` 读取同一组令牌 |
| 主按钮位置 | 卡内底部；宽度为卡宽减两侧 `cardInset`；长标题最多两行、不缩放；图标保留 6 pt 垂直内边距，标题使用剩余宽度，完整可访问名称保留 |
| 取消槽 | 高度 `40 pt`，卡内底部全宽；所有模块同位同大；可取消用 `FeatureCancellationButtonStyle`，不可取消用同槽说明行 |
| 左卡宽 | 可用画布宽的 `0.58`，最大 `600 pt`；可用宽少于 `560 pt` 则占满单列 |
| 内容列高度（D63 / R8） | 无外层卡片；同一视口共用 `min(可用高度, 头部与动作等 chrome + 224, 380)`。正常／大窗列分别最多 365／380 pt，矮窗按实际可用高度收缩；页头＋内容列与插画整体居中，稀疏选项空带每侧 ≤80 pt |
| 卡片内边距／间距 | 矮窗 `8/4`、普通 `16/12`、大构图 `24/16 pt` |
| 插画 | 内存起始态按仪表盘例外不用插画；其他起始态及全部运行态同一方形槽；边长取剩余列宽、卡片高、档位上限三者最小值；矮／普通／大上限 `220/420/560 pt`；节点最多四个 |
| 页头／页尾 | 页头固定 `heroForm(.landing).tileSide + 20/24`；页尾矮或窄 `36 pt`，其他 `56 pt` |
| 动效 | 原 V0 namespace / `SmartScanFlowMatchModifier`；`AppMotion.pageChange/reducedFade`；旋转周期 `AppMotion.orbitRotationDuration = 2.4 s` |

选项组件族：`FeatureOptionCard` / 现有范围网格、`FeatureOptionRow`、`CapsuleSegmentedControl`、`FeatureFormRow` 与既有原生表单控件。分段控件新增按项禁用／帮助能力；自定义日期等不在预设数组里的选择只在原生可访问表示里保留对应 tag，不把它改成某个预设。文件分析原有范围行、文件夹按钮和 developer Stepper 继续复用其原生控件实现。

运行动画只存在于 `isActive` 时；`AppMotion.runsOrbit` 同时检查活动、视图出现与 Reduce Motion。`OrbitSweepView` 进一步检查窗口可见、未最小化及视图层级未隐藏，监听窗口遮挡／最小化通知并移除层动画。没有空闲循环或按帧 SwiftUI 状态更新。空闲 CPU 为 0 的实测 **NOT RUN**，不能从源码守卫推定。

## 3. 每页改动与范围隔离

- 起始页几何全部由共用模板升级，不为 14 页复制布局。智能扫描范围行、安全清理选择卡、健康能力卡、隐私日期分段、搬家类型分段及重复文件范围分段迁入同族；选项说明和绑定集合保留。
- 性能测试新增起始页，历史／本机最佳／社区提交入口仍通向既有仪表盘。运行页保留阶段网格和系统监控；官方计划、预检、资源互斥、排行确认和历史读写不改。
- 内存初始仪表盘使用定高左卡槽；总览与选择／退出条固定，仅进程列表滚动。矮槽建议、容量明细和趋势可经原“指标说明”按钮展开；原建议动作、进程选择、退出确认和采样逻辑保留。优化结果显示原 `resultDashboard`。只在 Debug 演示环境阻止自动刷新。
- 健康、隐私、能耗、卸载、重复文件在保留旧结果的再次扫描时优先显示运行页；旧结果的数据与返回逻辑不改。文件分析／搬家的宿主路由同样修复，避免旧索引／候选导致绕过运行模板。
- 应用更新初始／扫描阶段拥有页面高度，其余阶段仍保留原显式高度。扫描时“本软件更新”入口移入固定页头，避免单独的工具条改变进度卡坐标；确认、更新执行、报告内容不改。
- `CleanupExecutionViews.swift` 两处仅改调用名为 `LegacyFeatureRuntimePage`，保持清理执行／验证页的 V0 外壳。
- `SmartScanTerminalPage` 改用 `LegacyTerminalLandingPage`；该兼容类、metrics、选项高度 preference 从基线 V0 原代码复制并仅重命名，防止全局壳升级影响取消／失败／完成页。后续 V2–V4 可迁移并删除兼容层。
- 没有改 `ScanStore.swift`、依赖、菜单栏小窗或设置窗口文件。公共按钮尺寸值仍为原 52 pt，只把来源集中为令牌。

## 4. 规范偏离及输入缺口

1. **D62 文档缺口已解决**：初版以派工条款为依据，`babf790` 已合入 `DECISIONS.md` 的正式 D62。起始模板对应 D62②，运行模板对应 D62③，验收及语义边界对应 D62④。本轮按正式文本复核；第 5 节的依据编号同步纠正，初版代码注释中的①／②仍是当时派工项的编号。本轮没有修改决定表。
2. **R5 按主会话明确授权更新计时**：真实 `elapsedSeconds` 优先；无真实起点时用运行页首次显示时间，明确显示“已用时间约…”，帮助说明非任务精确总时长。窗口级视图缓存按模块／任务身份保持起点，读取既有活动状态清除已结束任务，不改 Store。当前项／比例未知仍明确“未提供”；Debug 12 秒只是夹具。详见第 13 节。
3. 单列档位不画装饰插画，与 V0 的窄宽护栏一致；标准五档详情宽与额外 `613×338` 都保留插画槽。超出这组尺寸的更窄页面只要求可用，不承诺隐藏插画的 frame 存在。
4. **更正初版误判**：D62②的“仪表盘起始”变体保留 D53/V0 的总览、列表、退出条及选择命令可见性。初版把整套仪表盘放进选项滚动区属于回退；R4 改为定高摘要／列表／操作条，只有列表滚动。不是规范允许的偏离。旧断言在本轮保持原样，另补六档卡内可见性检查。
5. V0 最终修复已随 `babf790` 合入，包含 `nodeSide(for:)`／`nodeOrbitRadius` 的 `nonisolated`、入场记忆及趋势浮层定位。R4 保持这些具体修复不变，只在 `OrbitLandingArtwork.swift` 调整扫光窗口可见性守卫；复核测试与实拍仍需由主会话执行。初版未修改 V0 并行修复指定的几何声明方式。

## 5. 改写旧断言（保留测试方法与原有覆盖）

| 测试方法 | 旧要求 → 新要求 | 依据 |
|---|---|---|
| `ConceptLandingNativeLayoutRegressionTests.testSafetyAndDeveloperColumnsKeepTheirReferenceHierarchyWithoutOverlaps` | 绿／开发不同概念图卡宽比例 → 共用视口卡宽，0.5 pt 容差；重叠、按钮动作及语言覆盖保留 | D62②跨功能相同 frame |
| 同类 `testLandingScopeListsShowEveryRowAcrossTheCommonSizeSweep` | 全部选项必须同时可见 → 真实滚动后末项可见，固定按钮仍可见 | D62②最矮尺寸卡内滚动 |
| 同类 `testEveryLandingPageFitsInTheRealPageContainerAcrossTheSizeSweep` | 内滚动不许有溢出、页头取标题自然高度 → 末项滚动可达、共用页头槽；原尺寸／语言／页头动作检查保留 | D62②固定结构与一致性 |
| `SafeCleanupLayoutTests.testLandingCardUsesItsOptionsHeightWhenTheWindowGetsTaller` | 小内容卡片保持自然高度 → 卡片按视口／上限定高，按钮恒 52；保留尺寸切换与页尾包含检查 | D62②主按钮坐标跨功能一致 |
| 同类 `testDeveloperCategoriesUseBalancedRowsThroughWidthChanges` | 开发独享至少 480 pt 卡宽 → 中间宽 760/660 为两列、280 为一列；仍断言完整行、不重叠、不孤立末行 | D62②共用左卡宽 |
| 同类 `testSmartScanReferenceProportionsKeepAllScopesReadableInBothAppearances` | 图标／卡片相对概念图比例和全部可见 → 列表图标 32 pt、共用卡宽、全部行在滚动内容内；两种底色和最小控件仍检查 | D62②同族列表与卡内滚动 |
| 同类 `testFileAnalysisKeepsStandaloneActionAlignedWithConfigurationThroughResizes` | 主按钮在卡外相隔 16 pt → 卡内全宽、同令牌边距、52 pt，0.5 pt 容差 | D62②主按钮固定卡底 |
| `DesignSystemV2Tests.testMemoryPageKeepsOverviewListAndQuitBarVisibleAtEverySize` | 初版曾改为固定刷新钮＋滚动到退出条；该解释不能免除总览、列表、退出条同时可见。R4 修产品恢复这些槽位固定，既有断言本轮未改 | 初版依据误判已撤回；D62①②保留获批 V0 行为，见第 12 节 |
| 同类 `testScanningSweepTurnsOnlyInAWindowAndNeverUnderReduceMotion` | 挂入未显示窗口就旋转 → 显示窗口才旋转；新增隐藏层级停转；原 Reduce Motion／脱离窗口断言保留 | D62③④只在运行且可见时转 |
| `StartupItemsDashboardContractTests.testStartupItemsWaitForAnExplicitSharedLandingScan` | 单一未扫描条件字符串 → 运行分支先行、未扫描起始分支；增加原取消接线；显式读取且无自动 task 仍检查 | D62②③统一两态 |
| `UIConsistencyRegressionTests.testSharedEmptyStateStaysFlatWhileSmartScanUsesDedicatedStage` | 智能扫描专属 dashboard 调用 → 共用 `FeatureRunningTemplate`；其余断言保留 | D62③ |
| 同类 `testSmartScanProgressUsesNativeAccessibleStatusControls` | 专属薄进度条／页尾源码 → 生产共用模板的原生进度、可访问值、中间省略路径、统一取消高度；不再检查已不在活动路径里的薄条 | D62③④ |
| 同类 `testEnergyImpactRequiresExplicitScanAndShowsRealPipeline` | 有历史就结果页的字符串 → 活动时优先运行页；原显式读取与 pipeline 守卫保留 | D62③每个运行状态使用模板 |
| `GeneratedArtTests.testPicturesAreDecorativeAndOnlyOnTheAgreedSurfaces` | 性能页头符号只在旧仪表盘查找 → 新起始页与宿主接线；旋转只检查 `!reduceMotion` / window 存在 → 检查活动、出现、可见、最小化、隐藏及周期令牌 | D62②③④ |
| `ItemListAndDuplicatePresentationTests.testDuplicateLocationCardsKeepScopeSelectionAndNativeActions` | 本地分段按钮持有选中可访问 trait → 共用胶囊分段；增加未配置位置的 setter 守卫；原位置增删、选项绑定断言保留 | D62②；D47/N17 可用性边界 |

初版新增 `FeatureTemplateContractTests` 五项：真实 14 起始页 × 5 标准详情尺寸＋338 pt × 日/夜，主钮／插画 x/y/宽/高差≤0.5 pt；卡内末项可达且按钮不动；14 运行页 × 同尺寸的阶段／进度／当前项／用时／取消存在与取消 frame 一致；28 参数合法性、缺少惯性演示标志／非法／重复参数拒绝；动效策略组合与原生层状态。复用 V0 AppKit 托管器并增加只读层状态入口。prepared-r2 再补生产启动项／内存运行状态；prepared-r3 按 SDK 27 的只读环境限制改用纯动效策略和原生层的显式 turns 入参，保留六个测试方法，详见第 11 节。

## 6. Debug 演示与完整参数表

**仅 `DEBUG` 编译可用**。每次启动必须带 `--debug-mini-window-demo-data`。仅传下面功能参数而缺少这个标志不启用新演示。起始页使用真实生产视图及固定内存样本；自动内存刷新、外接卷读取、隐私恢复维护在演示环境跳过。文件分析范围显示 `/Fixture/...`，不调用真实索引。主按钮 override 只改变演示 phase；演示视图关闭鼠标命中，截图管线额外暂时忽略窗口鼠标事件。没有启动真实扫描、测试负载或硬件写入；这些是代码接线，运行验证 **NOT RUN**。

R5 的全部运行夹具调用生产工作区使用的同一个运行视图，具体映射见第 13 节；性能包含同一张监视图，智能扫描含三个真实结构的分类组。数据是演示值，不是设备测量。取消回调只返回起始态，不调用 Store。

| 功能 | 起始参数 | 运行参数 |
|---|---|---|
| 智能扫描 | `--debug-feature-page=overview:landing` | `--debug-feature-page=overview:running` |
| 安全清理 | `--debug-feature-page=green:landing` | `--debug-feature-page=green:running` |
| 开发工具与产物 | `--debug-feature-page=devCaches:landing` | `--debug-feature-page=devCaches:running` |
| 系统健康 | `--debug-feature-page=healthHub:landing` | `--debug-feature-page=healthHub:running` |
| 浏览器隐私 | `--debug-feature-page=privacy:landing` | `--debug-feature-page=privacy:running` |
| 性能测试 | `--debug-feature-page=performance:landing` | `--debug-feature-page=performance:running` |
| 登录项与后台任务 | `--debug-feature-page=startup:landing` | `--debug-feature-page=startup:running` |
| 内存管理 | `--debug-feature-page=memory:landing` | `--debug-feature-page=memory:running` |
| 能耗 | `--debug-feature-page=energy:landing` | `--debug-feature-page=energy:running` |
| 卸载 | `--debug-feature-page=uninstall:landing` | `--debug-feature-page=uninstall:running` |
| 应用更新 | `--debug-feature-page=updater:landing` | `--debug-feature-page=updater:running` |
| 文件分析 | `--debug-feature-page=largeFiles:landing` | `--debug-feature-page=largeFiles:running` |
| 文件搬家 | `--debug-feature-page=migration:landing` | `--debug-feature-page=migration:running` |
| 重复文件 | `--debug-feature-page=duplicates:landing` | `--debug-feature-page=duplicates:running` |

相似照片：在任一 duplicates 参数上追加 `--debug-feature-similar-photos`，仍属于重复文件模式。整个矩阵用 `--debug-feature-page=all:landing --capture-feature-templates`，管线轮换 14 路由和两态。仅拍当前态则省略 `--capture-feature-templates`。非法路由／phase 或多个 `--debug-feature-page` 不启用；`utilityHub` 不是第 15 个功能。

现有管线参数：`--capture-main-window-directory=/绝对路径`、`--capture-main-window-sizes=820x560,1000x700,1280x764,1680x1050,2400x1350`、可选 `--capture-main-window-filters=memory,performance`、`--capture-settle-ms=1600`。默认矩阵是上述五档加 `677x390,1280x390` 两档；产物名 `宽x高-route-phase.png`，并写 `capture-feature-templates.json`，记录请求与实际尺寸、路由、phase 和 fixture 标记。必须核对实际尺寸，再做截图比较。

三种底色各启动一个 Debug 进程：

| 底色 | 附加参数 |
|---|---|
| 深空夜间 | `--debug-mini-window-appearance=dark -app.canvasTheme deepSpace` |
| 纯黑夜间 | `--debug-mini-window-appearance=dark -app.canvasTheme pureBlack` |
| 日间象牙白 | `--debug-mini-window-appearance=light -app.canvasTheme deepSpace` |

新 Debug 演示在主窗口应用既有 appearance 标志；canvas 使用参数域，不持久写用户偏好。主会话使用 Debug 构建的二进制／截图包路径，不使用以 release 配置构建而只有 `STORAGE_CLEANER_BETA` 的二进制。示例（由主会话替换二进制路径执行）：

```bash
"$SC_DEBUG_BINARY" --debug-mini-window-demo-data \
  --debug-feature-page=all:landing --capture-feature-templates \
  --debug-mini-window-appearance=dark -app.canvasTheme deepSpace \
  --capture-main-window-directory=/Users/developer/Developer/.sc-build/r2-ui-v1/shots/deep \
  --capture-main-window-sizes=820x560,1000x700,1280x764,1680x1050,2400x1350 \
  --capture-settle-ms=1600
```

## 7. 主会话定向测试与完整门禁

必须运行的类（实际检索既有页面布局／源码契约及行为边界；完整过滤表达式见 prepared 的 `directed-tests.txt`）：

```text
FeatureTemplateContractTests
UIConsistencyRegressionTests
TestPreferenceHygieneTests
DesignSystemV2Tests
ConceptLandingNativeLayoutRegressionTests
GeneratedArtTests
DesignSystemV2ReviewTests
SafeCleanupLayoutTests
SafeCleanupScopeCardLayoutTests
StorageAnalysisScopeLayoutTests
HealthCapabilityLayoutTests
BenchmarkMonitorLayoutTests
RuntimeWorkflowPresentationTests
StartupItemsDashboardContractTests
ItemListAndDuplicatePresentationTests
PrivacyCleanupPresentationTests
OwnedUIFlatteningContractTests
CompetitiveParityContractTests
ControlAccessibilityContractTests
DayAppearanceTests
AppUpdatePresentationIntegrationTests
AppUpdatePresentationModelsTests
DebugAppUpdatePresentationFixtureTests
ComputerHealthDashboardTests
OfficialBenchmarkPlanTests
MemorySelectionSummaryTests
MemoryQuitConfirmationTests
MemoryPressureLevelAppWideTests
SystemUtilitySafetyTests
UtilityPresentationPerformanceTests
AppResponsivenessTests
ScanModeTests
ScanStorePresentationLifecycleTests
DebugSmartScanSessionFixtureTests
DuplicateSelectedLocationsTests
ExternalMigrationReceiptTests
```

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug --jobs 4
SC_UI_V1_FILTER=$(cat /Users/developer/Developer/.sc-build/r2-ui-v1/prepared-r5/directed-tests.txt)
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug --jobs 4 --filter "$SC_UI_V1_FILTER"

STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-ui-v1/verify \
  script/verify.sh
```

新测试偏好只用 `TestPreferenceDomain`；测试不执行移动／删除／卸载／硬件动作。既有移动或回执测试仍按 `common.md` / RULES 使用家目录内隔离夹具。不得把纯数据路径替换为真实文件，不能放宽产品路径安全检查。新测试仅 Debug；Release 全量门禁仍需运行既有类。计时／原生窗口测试在机器空闲时执行，失败不改阈值。

## 8. 红／绿／反证

| 项目 | 红 | 绿 | 反证（独立临时副本，用后恢复，不改产品安全规则） |
|---|---|---|---|
| 14 页一致几何 | 基线用各模块自然卡高、绿／开发／分析独享比例，native frame 不能一致 | 本批 `FeatureTemplateContractTests` 14×5＋338，差≤0.5，末项滚动后可达 | 仅给 devCaches 卡宽加 1 pt，或 memory 按钮下移 1 pt，应使对应差值断言失败；给最矮窗加 520 pt 外层最低高度，应使可见区断言失败 |
| 文件分析动作 | 基线按钮在卡外 | 卡内 inset、宽度、底距、52 pt 的原生测量通过 | 将按钮移回卡外，应使包含／底距断言失败 |
| 原生运行页 | 基线多种页尾取消与不同卡宽 | 14 页统一取消坐标，各阶段／路径／用时元素存在；再跑各页面既有契约 | 为 updater 取消高度改 41 pt 或删除 runtime.elapsed probe，应使运行契约失败 |
| 动效 | 基线窗口存在即旋转、没有视图隐藏护栏 | 空闲无层循环，Reduce Motion 静止；运行且显示的原生层转动；隐藏／脱离窗口停转 | 把运行状态 guard 改恒 true，空闲层测试应失败；绕过 Reduce Motion，原生 reduced 断言应失败；去掉窗口可见 guard，隐藏窗口测试应失败 |
| 语义 | 基线功能规则作为参考 | 原 D47/N17 选择测试、N19/内存确认、官方计划、更新确认／取消、迁移回执和恢复相关定向测试通过 | 对无追加位置强行接受 selectedLocations，原 setter／选择边界测试应失败；把 persisting 允许取消，官方 benchmark 阶段取消契约应失败 |
| Demo 隔离 | 基线无此 28 参数入口 | 参数解析拒绝缺少 inert 标志／非法／重复；新夹具可拍 420 张并读回尺寸清单；检查 Store 无实际活动、硬件无写入 | 去掉 memory fixture task guard、误接 primary override 为真实扫描，应在隔离 provider/人工运行检查中被发现；不在真实机器目录执行反证扫描 |
| 0 空闲 CPU | 原审计与 V0 行为作参考，非本批实测 | 所有起始页待入场结束后按现有性能采样管线测得空闲 0；运行不可见时 layer 动画键不存在 | 故意保留 idle 的无限 CA 动画，原生层断言和 idle 采样应抓住；不把构建成功视为 CPU 证据 |

红／绿／反证均由主会话执行，本批状态全部 **NOT RUN**。帧测试是实测 SwiftUI/AppKit frame，公式检查只保留在旧测试对应的一项，不把公式自证替代跨功能比较。

## 9. 实际状态、产物及未解决项

本节保留初版交付记录；第一轮结果见第 10 节，第二轮结果及当前修复交付以第 11 节为准。

- 静态差异、补丁反向可应用检查、最终文件 SHA-256、禁止触及文件和测试方法保留清单：以 `prepared/static-checks.json` 为准；这些不是编译或测试通过证据。
- 分组：`01-template-tokens` → `02-pages-cleanup-protection` → `03-pages-system-apps` → `04-pages-files` → `05-demo` → `06-tests` → `07-handoff`；另有 `all.patch`、manifest、提交助手与生成助手。提交助手只供主会话验证后执行，本会话不运行。
- JEV **BLOCKED**：尝试有限方案判断时工具返回 `MCP tool call requires approval, but approval policy is never`。接口未提供可选模型参数，实际模型请求未执行，没有 JEV 判断或批准；不绕过限制。
- 构建／严格并发／XCTest／截图矩阵／空闲 CPU／安装／提交：**NOT RUN**。未声称看到本批界面；用户附图属于 V0 参考。
- 待主会话确认：Swift 6 编译及 AppKit 原生测量；五档 × 三底色 × 两态实拍与真实尺寸记录；338 pt 下长说明、内存选择条、健康三卡的滚动可达性；新 Debug 入口的 provider 无调用；运行层隐藏窗口时停转；V0 并行补丁合并后的艺术发布和几何隔离。
- 若主会话先并入 V0 并行提交或修改冲突文件，提交助手会因基线或文件哈希变化停止；须在新基线重新核对、生成产物并完成验证，不能绕过检查。
- 数据限制：真实任务用时未提供时仍显示未知。若要统一真实任务起点的测量，需模型所有者提供值；本批不修改 `ScanStore.swift`。

## 10. 主会话第一轮结果与修复

### 10.1 第一轮实测与当前基线

主会话回传：初版七组已提交为 `ee64ad9`、`abc8656`、`6dccf06`、`2cdeb3b`、`0cd9926`、`0a75b83`、`0ef1997`，trailer 改为 `gpt-6.1-sol`；随后无冲突合并集成分支，形成 `babf790725c205ff3a5fa424cc61a21f641bad7b`。本会话用 `git log -1` 和干净工作区读回确认新基线。合入内容包括 V0 最终修复 `d7d0c7b`、iCloud 读取／复制隔离、隐私边界及正式 D62。

**主会话第一轮编译：FAIL。** 回传两处错误均在 `Views/SystemUtilitiesView.swift`：`StartupItemsScanProgress.message` 不存在，以及内存 `FeatureRunningTemplate` 表达式无法产出诊断。完整编译日志、命令和 exit code 未随消息提供，不推定更多结果。没有收到第一轮 XCTest 或截图通过的证据。

### 10.2 修复及类型核对

- 启动项：将 `store.startupScanProgress?.message` 改为 `.title`。模型声明位置为 `Features/StartupItems/Views/StartupItemsDashboardView.swift`；`title: String`、`discoveredCount: Int`，可选进度链的 title 与原 String fallback 相容。原取消回调 `cancelStartupScan() -> Void` 不变。
- 内存：运行页移为 `memoryRunningPage`，先计算 `isOptimizing: Bool`、`title: String` 和明确的 `cancelAction: (() -> Void)?`。优化分支使用 `{ store.cancelMemoryOptimization() }`，读取分支为 nil；模板显式为 `FeatureRunningTemplate<EmptyView, EmptyView>`，两段 `@ViewBuilder` 闭包仍各返回 `EmptyView`。减少原大 dashboard 表达式和条件方法引用的类型推断负担；**是否已排除编译错误需复编确认**。没有改模板 API、默认值、Store、采样或退出确认流程。
- 测试：新增 `FeatureTemplateContractTests.testProductionStartupAndMemoryRunningPagesUsePublishedStateAndCancellationSlots`。直接托管生产启动项读取、内存读取与内存优化三个状态；使用隔离 Store、固定启动项 title/count 和 fixture 环境，在普通详情尺寸及 `613×338` 下检查阶段可访问文字、读取／不可取消／优化取消文字、40 pt 取消槽、可见范围和跨状态 frame≤0.5 pt。只设置夹具状态，不调用扫描、优化、取消或退出动作；偏好仍用 `TestPreferenceDomain`，复用会拒绝真实读取的 provider。

全仓定向检索共 **26 处生产构造调用＋10 处测试构造调用**，含 `FeatureRunningTemplate` / `FeatureLandingTemplate`、`FeatureRuntimePage` / `FileToolLandingPage` 别名及 `HeroScanPage` / `FeatureLandingPageShell` 外壳；字符串／注释中的源码断言不计入调用。完整位置、构造 API 和模型声明核对见 `prepared-r2/template-call-audit.json`。这是文本清单与人工源码核对，不是 Swift 类型检查。

| 调用组 | 核对的模型字段／类型及闭包 |
|---|---|
| 智能扫描／安全清理／开发工具／搬家文件 | `DiskScanProgress.currentGroupTitle: String`、`currentPath: String?`、`progressKind`、`fractionCompleted: Double`、计数 `Int`、大小 `Int64`；比例只在 determinate 时转为 `Double?`，指标格式化为 String；原取消接口／`ScanProgressStageList` 保留 |
| 启动项 | `StartupItemsScanProgress.title: String`、`discoveredCount: Int`；可选进度 fallback 与类型一致，取消为原无参数 Void 方法 |
| 内存 | `isLoadingMemory/isOptimizingMemory: Bool`；标题 String，取消闭包明确为可选无参数 Void；读取与优化能力区分保留 |
| 文件分析／搬家 App | `StorageMapScanProgress.currentPath: String`、`inspectedItemCount: Int`、`measuredBytes: Int64`；可选链产生 `String?`；App 清单读取不假造进度和取消；实际扫描闭包调用现有 `cancelScan/cancelStorageAnalysis` |
| 重复文件／相似照片 | `DuplicateFileScanProgress.currentPath: String?`、文件计数 Int、内容字节 Int64；运行 state 为 `RuntimeWorkflowState`，暂停／继续／取消均为原方法 |
| 更新 | `AppScanProgressSnapshot.progressFraction: Double?`、`currentApplicationName: String?`、`completedUnitCount: Int`、`totalUnitCount: Int?`；`stage.title` 在同文件 extension 可见；details 为原阶段轨 |
| 性能 | `BenchmarkV7State.phase: BenchmarkV7Phase`、`progress: Double?`；presentation 标题／当前任务均为 String；原阶段取消谓词、`cancelV7`、监控及阶段网格保持 |
| 能耗 | `EnergyImpactScanPhase.fractionCompleted: Double` 经可选 map 得 `Double?`；同文件 `detail` 得 `String?`；保留原 pipeline，没有新增取消接口 |
| 健康／隐私／卸载 | 既有 Bool／扫描枚举分支；健康能力 enum、隐私无参数取消、卸载默认不可取消；未发布的比例／当前项／时间使用模板 nil 默认值 |
| 起始页与 Debug／测试 | 起始显式 init 的 String、Bool、`ScanStatusPresentation`、无参数 Void 动作与 accessory builder 对齐；带默认 priority 的刷新方法仍由无参数闭包／函数包裹。Debug 固定比例／用时、进度夹具和空闭包与模板类型一致；所有运行调用均有 details/actions 两个 builder，外壳 EmptyView overload 保留 |

本轮没有发现第三处需要修改的字段／签名不匹配；这个结论仅限源码核对，不能宣称编译已通过。当前 `elapsedSeconds` 仍可选，真实任务起点未知时继续显示“—”。正式 D62 已合入；第 5 节原断言的依据编号已按正式 D62②／③／④纠正，本轮不改写或移除任何旧测试断言。

### 10.3 prepared-r2 与主会话验证

本轮仅改三个仓库文件：`SystemUtilitiesView.swift`、`FeatureTemplateContractTests.swift`、本交接文档。新补丁基线 `babf790`，目录 `/Users/developer/Developer/.sc-build/r2-ui-v1/prepared-r2/`，不覆盖初版 `prepared/`。

分组：`01-production-running-fixes` → `02-production-contract-tests` → `03-handoff`。含各组 patch/message、`all.patch`、manifest、静态记录、调用审计、完整定向类过滤表达式及只供主会话运行的提交助手；trailer 使用 `Generated-By: Codex (gpt-6.1-sol)`。

主会话按第 7 节的 Debug build → 36 类定向 XCTest → 完整门禁顺序验证；过滤文件已经指向 `prepared-r2/directed-tests.txt`。新测试包含在现有类中，无新增测试类。旧阈值、断言和方法保留。成功构建后继续既定 420 张截图、338 pt 极矮窗及运行录屏，不跳过本批原验收。

| 修复 | 红 | 绿 | 反证（只在独立临时副本进行） |
|---|---|---|---|
| 启动项字段 | 第一轮编译已回传不存在 `message` 的错误 | 复编无该错误，新生产页测试显示夹具 title | 恢复 `.message` 应再次编译失败；若换成固定标题，测试的夹具阶段文字应失败 |
| 内存运行表达式及能力 | 第一轮内存表达式编译失败；演示页未直接托管该生产分支 | 复编与新读取／优化生产分支测试通过，frame 同位且取消能力文案正确 | 将读取的 `cancelAction` 改为非 nil，应使“此任务不可取消”断言失败；偏移任一分支取消槽 1 pt，应使 0.5 pt frame 比较失败；不触发真实取消动作 |
| 集成内容保护 | 以新基线文件为参照 | 受保护文件和未改调用文件逐字节／diff 保持 `babf790` 内容 | 不复用旧基线补丁覆盖 V0 几何、iCloud 或隐私修复；提交助手遇基线／哈希漂移应停止 |

本会话只执行静态差异、调用清单、模型声明、补丁可应用性与哈希核对，结果见 `prepared-r2/static-checks.json`。**本轮复编、Swift 严格并发、XCTest、截图、CPU、安装、提交均 NOT RUN；测试执行数 0。** JEV 沿用初轮工具审批阻断记录，本轮没有重复调用或获得判断。未解决项：复编与原生测试仍待主会话执行；真实用时数据限制保留。没有以静态核对替代运行验收。

## 11. 主会话第二轮结果与 SDK 27 测试修复

### 11.1 已报告结果与新基线

主会话回传 prepared-r2 三组已提交为 `b44fe5c`、`5398d2f`、`a7636f1`，trailer 使用 `gpt-6.1-sol`。本会话读回 HEAD 为 `a7636f1aa900f0bcb45923da7350026654e952e6`，修复前工作区和暂存区均为空。

**第二轮生产编译：PASS（主会话回传）；测试目标编译：FAIL（8 个错误）。** 三处根错误为 `FeatureTemplateContractTests.swift` 第 55／107／161 行写入 `accessibilityReduceMotion`，SDK 27 只提供不可写 KeyPath；其余五处 `XCTUnwrap` 泛型推断错误由前述表达式错误连带产生。没有收到 XCTest 执行通过或截图通过的证据；完整编译命令、日志及 exit code 未提供，不补造。

V0 交接第 11 节已说明：“SwiftUI 的 `accessibilityReduceMotion` 环境值是只读的（SDK 27 的 SwiftUICore 接口只有 `get`）”。本轮按第二轮回传要求和该限制修复测试，不增加自定义系统偏好替代键，也不修改系统设置。

### 11.2 测试改动与旧断言依据

本轮仅改 `Tests/StorageCleanerMacTests/FeatureTemplateContractTests.swift` 和本交接。生产代码、模板 API、`AppMotion`、V0 原生托管器和所有其他测试文件保持新基线内容。

| 方法 | 旧实现 → 本轮实现 | 依据及保留覆盖 |
|---|---|---|
| `testEveryRunningPageContainsProgressElementsAndAnIdenticalCancelFrame` | 写只读 Reduce Motion 环境以求稳定 → 正常托管并等待既有 `frames(required:size:)` 的连续稳定探针 | 第二轮要求②；D62③④。14 模块×原六档尺寸、40 pt 取消槽、可见范围及全部 frame／存在断言不变；Core Animation 的图层旋转不改变布局 frame |
| `testProductionStartupAndMemoryRunningPagesUsePublishedStateAndCancellationSlots` | 对读取／优化夹具写 Reduce Motion 环境 → 保留项目自定义 fixture/theme 环境，使用原稳定探针等待 | 第二轮要求②；D62③④。三个生产状态、两档尺寸、阶段／取消可访问文字及 frame≤0.5 pt 原样保留 |
| `testOrbitMotionPolicyIsOffForIdleHiddenAndReducedMotionStates` | 只测八种 `runsOrbit` 组合及 morph → 保留原断言，补齐全部 `AppMotion.Token` 的 `resolved` 与 reducedBehavior | 第二轮要求①；V0 `DesignSystemV2Tests.testReduceMotionMapsMovementToFadesAndDataToImmediateUpdates`；D62③④。非 reduced 时都有动画；reduced 的 hover／standard／emphasized 为 fade，press／data 立即更新（nil） |
| `testNativeArtworkLayerDoesNotAnimateIdleOrReducedMotionPages` | 伪造只读环境后检查托管页层数组 → 先检查生产空闲页无旋转，再把 `AppMotion.runsOrbit` 结果传给既有 `OrbitSweepView.configure(color:turns:)`，检查实际旋转键 | 第二轮要求①；V0 `DesignSystemV2Tests.testScanningSweepTurnsOnlyInAWindowAndNeverUnderReduceMotion`；D62③④。保留 idle／running×reduce false／true：活动且非 reduced 必须有旋转，其他必须没有。旧运行数组“非空且全转”改为指定原生层 `isTurning == true`，不以空数组视为通过；不假装测试已在系统 Reduce Motion 设置下托管整页 |

六个测试方法均保留，没有新增或删除方法，没有跳过测试、缩小尺寸集合或放宽 0.5 pt 阈值。没有为布局增加固定睡眠或改托管器的稳定等待阈值，也没有写 `Transaction` 来冒充系统 Reduce Motion。

全文件环境写入审计：原三处 `accessibilityReduceMotion` 写入全部移除；最终只剩 `featurePresentationIsFixture` 与 `moduleTheme` 两个项目自定义环境键，定义分别在 `Debug/FeaturePresentationDemo.swift` 和 `Support/ModuleTheme.swift`，均有 get/set。没有其他辅助功能、`colorScheme` 或系统环境值写入；没有新增 KVC、偏好或 setter 绕过。审计结果见 `prepared-r3/environment-write-audit.json`。

### 11.3 prepared-r3、主会话验证与反证

补丁基线 `a7636f1`，目录 `/Users/developer/Developer/.sc-build/r2-ui-v1/prepared-r3/`，保留前两轮产物。两组：`01-sdk27-test-motion` → `02-handoff`，含 patch/message、`all.patch`、manifest、静态核对、环境写入审计、定向过滤文件、生成助手及主会话提交助手。trailer 为 `Generated-By: Codex (gpt-6.1-sol)`。

主会话先以第 7 节命令复编测试目标并执行完整 36 类定向清单，尤其 `FeatureTemplateContractTests`、`DesignSystemV2Tests`、`DesignSystemV2ReviewTests`、`GeneratedArtTests`、`UIConsistencyRegressionTests` 和 `TestPreferenceHygieneTests`。随后继续完整门禁、420 张截图、338 pt 窗口和切换／运行录屏。过滤文件已指向 `prepared-r3/directed-tests.txt`。

| 项目 | 红 | 绿（尚待主会话） | 反证（独立临时副本） |
|---|---|---|---|
| SDK 只读环境 | 第二轮回传测试目标的三处 KeyPath 根错误与五处泛型连带错误 | 测试目标编译通过，所有环境写入只含可写项目键 | 恢复任一 `.environment(\.accessibilityReduceMotion, true)` 应再次编译失败；不修改 SDK 或系统设置 |
| 减弱动态效果策略 | 旧托管测试无法合法注入 | 八种 `runsOrbit` 组合、全部 Token 的 `resolved` 与显式原生层转／停断言通过 | 暂时去掉 `runsOrbit` 的 `!reduceMotion`，组合及原生停转断言应失败；令 `resolved(.data, true)` 返回动画，纯策略断言应失败 |
| 布局稳定性 | 旧测试依靠非法环境写入 | 原五档＋338、生产读取／优化、0.5 pt frame 和可访问断言通过 | 偏移某模块取消槽 1 pt，应继续失败；不放宽尺寸或等待预算 |

本会话执行的仅为源码和补丁静态核对，记录见 `prepared-r3/static-checks.json`。**本轮测试目标复编、XCTest、严格并发、截图、CPU、安装和提交均 NOT RUN，测试执行数 0。** 真实系统设置下整页 Reduce Motion 截图／录屏仍 NOT RUN，纯函数与显式原生层入参不能替代该证据；主会话可在用户已开启该设置的环境中验证。JEV 本轮未重复调用，沿用初轮审批阻断记录。真实任务起点未知时显示“—”的数据限制未变。


## 12. 主会话第三轮结果与回退修复（prepared-r4）

### 12.1 已收到的证据、基线和判定

主会话报告 prepared-r3 已提交为 `c6ba69e`、`10d981a`。本轮读回 HEAD 为 `10d981a7ab04f7eb782efd38b682de6521303c0a`；开始时工作区和暂存区为空。已读取 `~/Developer/.sc-build/r2-ui-v1/failures-r3.txt` 和 `logs/main-test-3.log`，包括两处异常之前的日志。

**第三轮编译全部通过；36 个定向类共 606 项、跳过 1、13 个失败测试、107 处错误点，其中 2 处抛错。** 这是主会话第三轮结果，不能当作本轮结果。R4 未在沙箱构建或执行 XCTest。

分类遵照本轮派工：语义类、V0 行为类只能修产品；层级、完整换行、颜色、文字与原生可达性的回退同样修产品。**本轮按 D62 改写旧契约的条目为 0。** 两个已有布局测试文件只修改托管器与错误诊断，测试方法、断言、阈值、尺寸和等待预算原样保留。新增内存可见性方法不替代旧方法。

### 12.2 十三个失败测试的逐项处理

| 失败测试 / 第三轮错误点 | 分类 | 修复与保留的要求 |
|---|---|---|
| `CompetitiveParityContractTests.testSmartScanCopyDoesNotClaimPrivacyOrPerformanceWorkItDoesNotRun` / 1 | 修回退（产品） | `SmartScanScanningPage` 传 `subtitle: module.pageSubtitle`；保留既有准确范围文案。真实当前分类在 `currentPath ?? currentGroupTitle` 及阶段列表中显示。不声称执行隐私或性能工作 |
| `OwnedUIFlatteningContractTests.testManagementPagesKeepSelectionSeparateFromExecution` / 1 | 修回退（产品） | 卸载页明确分开“正在读取”“从未读取”“已缓存清单”三分支。没有新增导航触发扫描、自动选择、拖入即卸载或确认执行；管理页选择绑定保留 |
| `SystemUtilitySafetyTests.testNavigationStressPathUsesCachedAnalysisAndExplicitUninstallScan` / 1 | 修回退（产品） | 同上，移除把未扫描与加载合并的条件；已有缓存分析／应用清单与显式扫描动作继续由原 Store 提供。`MemoryProcessAnalysis`、Store 和导航状态未改 |
| `DesignSystemV2ReviewTests.testMemorySelectionCommandsStayAvailableWhateverIsSelected` / 80 | 修回退（产品） | 取消总览＋300 pt 面板的整卡自然高度堆叠。定高仪表盘将建议选择、全选、清空及退出条固定在列表外；零选、部分选、全选的出现条件与 `canRequestMemoryQuitActions` 原样保留。左卡较窄时次要命令用图标，显式可访问名称仍为完整标题，退出按钮保留标题 |
| `DesignSystemV2Tests.testMemoryPageKeepsOverviewListAndQuitBarVisibleAtEverySize` / 3 | 修回退（产品） | 共用 `.dashboard` 槽把全部内容约束在选项视口高度内，外层没有滚动溢出，内部列表滚动；总览不因调整窗口而被滚到页头上方，刷新按钮仍 52 pt。退出条矮窗 44 pt、其余 56 pt。撤回第 4/5 节初版对仪表盘可见性的错误解释 |
| `DesignSystemV2Tests.testScanningSweepTurnsOnlyInAWindowAndNeverUnderReduceMotion` / 1 | 修回退（产品） | 用同步 `window.isVisible`、未最小化、视图未隐藏与 `turns` 判定；移除窗口服务器尚未发布 `.visible` 遮挡状态时的首帧阻断。仍监听窗口可见性／最小化通知；隐藏、脱离窗口、空闲或减弱动态效果移除旋转键 |
| `FeatureTemplateContractTests.testNativeArtworkLayerDoesNotAnimateIdleOrReducedMotionPages` / 1 | 修回退（产品） | 同一扫光修复，保留“活动且非 reduced 必须转”的阳性断言与全部静止反例，不把未生成旋转键视为通过 |
| `ConceptLandingNativeLayoutRegressionTests.testSafetyAndDeveloperColumnsKeepTheirReferenceHierarchyWithoutOverlaps` / 8 | 修回退（产品） | 窄档两列间距恢复为共享 24 pt、大构图 40 pt；图块与轨道之间继续满足至少 19 pt 的层级阈值，不改断言 |
| `SafeCleanupLayoutTests.testDeveloperCategoriesUseBalancedRowsThroughWidthChanges` / 2 | 修回退（产品） | 开发类别最小图块宽度 108 pt：900 pt 时仍四列、760/660/430 时两列、280/260 时一列；三列仍回退两列，保留完整行、标题全文与滚动可达性 |
| `SafeCleanupScopeCardLayoutTests.testDaylightProductionIconsKeepFourDistinctPigments` / 6 | 修回退（产品） | 安全清理四类图标显式读令牌：缓存 `.cleanup`、日志 `.smartScan`、临时文件 `.protection`、下载残留 `.files`。共用卡结构和模块主按钮颜色保留；不降低日间 0.04 色差阈值 |
| `UIConsistencyRegressionTests.testMainWindowTextAvoidsSmallSemanticFontOverrides` / 1 | 修回退（产品） | 删除 `PrimaryActionLabel` 的单行 0.7 缩放，最多两行、共享 17 pt 字号，标题拿到剩余宽度；6 pt 垂直边距只加在图标上，双行文字可留在 52 pt 按钮内。完整可访问名称保留 |
| `FeatureTemplateContractTests.testProductionStartupAndMemoryRunningPagesUsePublishedStateAndCancellationSlots` / 抛错 | 修回退（产品＋宿主） | 原日志先报 `Native AX did not publish ... Reading fixture startup items`，随后才有 `failed(deinit)`。运行阶段组合现在显式发布完整可访问标题与副标题值；原 fixture title、读取／优化能力及取消 frame 断言不变。托管器延迟拆卸见下文 |
| `SafeCleanupLayoutTests.testSmartScanOneButtonIdleAndActivePagesKeepWindowStable` / 抛错 | 修回退（产品＋宿主） | V1 运行外壳缺 `smart-scan.root/content`，补在实际根和实际内容区域；沿用结果壳底部 anchor，避免运行→结果页底部漂移。宿主真实显示，超时先输出 `missing` ID，异步拆卸；窗口 frame、侧栏、页头／页尾稳定断言仍全部保留 |

两个宿主原先已经以属性和 defer 持有强引用，现有日志不足以断言“探针前已释放”就是根因。R4 按实际证据修缺失标签／探针，同时修同步拆卸风险：`close()` 幂等、先隐藏窗口，主 actor 任务强持有 window/controller/recorder；让已排队回调获得执行机会，换为空视图并做原生布局，再拆 controller、关闭窗口。没有改等待轮数或放宽稳定条件。是否完全消除 SDK 27 的二次异常仍须由主会话运行验证。

### 12.3 API、令牌和影响范围

- `FeatureLandingTemplate` 新 `optionsLayout: .scrolling / .dashboard`，默认 `.scrolling`，所有已有调用兼容。`.dashboard` 是同一页头、左卡、轨道、底部状态条与主按钮槽；内容获得定高视口，复用同一原生滚动宿主，外层文档高度等于视口，只有进程列表实际滚动。仪表盘提供同族区块标题。
- `MemoryLandingDashboard` 将 `MemoryReleasePanel` 总览固定在顶部，`MemoryProcessSelectionPanel(isLandingDashboard: true, minimumListHeight: 0)` 填充剩余高度、固定操作条。空状态、全部进程／可退出应用切换、建议选择、确认、取消、退出和采样仍调用原实现。紧凑总览保留实测占用环与 macOS 等级环，建议详情、容量及趋势通过原“指标说明”入口完整保留；未更改默认选项或测量含义。紧凑条件为短窗或选项槽不足 350 pt；普通槽趋势高 48 pt、大槽 60 pt，全部仍使用原 TrendChart。338 pt 的静态高度预算为 158 pt 选项槽 = 32 pt 总览 + 34 pt 范围选择 + 44 pt 列表视口 + 44 pt 操作条 + 4 pt 内部间距；这只是源码预算，实际 frame 由新增原生测试核验。
- 矮档卡内边距统一由 12 改为 **8 pt**；卡内间距、页头后间距、状态条前间距统一 **4 pt**，页面底边距 **8 pt**，为 338 pt 下摘要、完整一行列表和操作条保留空间；所有模块使用同一值，主按钮继续 **52 pt / 17 pt 字号 / 38 pt 图标圈 / 18 pt 符号 / 20 pt 左右边距**。取消槽继续 **40 pt**。窄档两列间距由 16 改为 **24 pt**。这些是回退修复，没有改任何测试阈值。
- 运行页阶段有显式 AX heading / title / value，智能扫描当前分类继续由模型读取。运行外壳底部读取既有 `WindowLayoutMetrics.contentPadding`，与结果壳 anchor 对齐；结果页源码没有修改。
- 七个生产文件：`FileToolLandingPage.swift`、`DesignSystem/FeatureTemplates.swift`、`DesignSystem/GradientButtonStyle.swift`、`SystemUtilitiesView.swift`、`ContentView.swift`、`SmartScanProgressView.swift`、`DesignSystem/OrbitLandingArtwork.swift`。三个测试文件：`FeatureTemplateContractTests.swift`（只新增方法）、`ConceptLandingNativeLayoutRegressionTests.swift` 与 `SafeCleanupLayoutTests.swift`（只改宿主／诊断）。另改本交接。
- 共用 `PrimaryActionLabel` 的字体修复也作用于仍调用它的旧状态外壳；其页面实现和业务流程没有改。`LegacyTerminalLandingPage` 原代码、`RuntimeWorkflowPresentation.swift`、`CleanupScanViews.swift`、`CleanupExecutionViews.swift` 均保持基线。内存结果页复用的面板在新参数默认为 false 时保持原布局。
- `ScanStore.swift`、`AppMotion.swift` 的入场记忆、V0 非隔离几何声明、`GeneratedArtView.swift`、`DataVisuals.swift`、`DesignSystemV2Tests.swift`、`DesignSystemV2ReviewTests.swift`、DECISIONS、Debug 截图管线、iCloud／隐私业务修复、菜单栏与设置窗口均未修改。Debug 起始／运行 28 参数沿用第 6 节，不需新增参数。

### 12.4 测试和完整定向清单

`FeatureTemplateContractTests` 保留六个既有测试方法、所有原断言与原六档尺寸，新增 `testMemoryDashboardKeepsOverviewListAndSelectionCommandsInsideTheCard`：六档尺寸×零选／部分选／全选，检查总览、列表、退出条和命令全部在卡内，列表视口至少 44 pt，并等待命令实际可访问节点与动作。使用固定 MiniWindow 夹具、原 TestPreferenceDomain 与 fixture 环境；不扫描真实磁盘、不执行退出动作、不写系统辅助功能环境。

**按 D62 改契约：无。** 既有方法源码完整保留；宿主显示／异步释放和缺失 ID 诊断属于测试设施修回退。`frames(required:size:)` 与另一宿主均仍为 120×5 ms、原稳定次数，AX 等待仍为 100×5 ms；无 skip、阈值放宽或减弱动态效果环境写入。静态审计会逐字比较既有测试方法，不以运行结果作保证。

完整 36 类过滤清单仍为 `prepared-r4/directed-tests.txt`，含本轮修改页面的布局／语义／确认类以及所有共享基础守卫：

`FeatureTemplateContractTests`、`UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`、`DesignSystemV2Tests`、`ConceptLandingNativeLayoutRegressionTests`、`GeneratedArtTests`、`DesignSystemV2ReviewTests`、`SafeCleanupLayoutTests`、`SafeCleanupScopeCardLayoutTests`、`StorageAnalysisScopeLayoutTests`、`HealthCapabilityLayoutTests`、`BenchmarkMonitorLayoutTests`、`RuntimeWorkflowPresentationTests`、`StartupItemsDashboardContractTests`、`ItemListAndDuplicatePresentationTests`、`PrivacyCleanupPresentationTests`、`OwnedUIFlatteningContractTests`、`CompetitiveParityContractTests`、`ControlAccessibilityContractTests`、`DayAppearanceTests`、`AppUpdatePresentationIntegrationTests`、`AppUpdatePresentationModelsTests`、`DebugAppUpdatePresentationFixtureTests`、`ComputerHealthDashboardTests`、`OfficialBenchmarkPlanTests`、`MemorySelectionSummaryTests`、`MemoryQuitConfirmationTests`、`MemoryPressureLevelAppWideTests`、`SystemUtilitySafetyTests`、`UtilityPresentationPerformanceTests`、`AppResponsivenessTests`、`ScanModeTests`、`ScanStorePresentationLifecycleTests`、`DebugSmartScanSessionFixtureTests`、`DuplicateSelectedLocationsTests`、`ExternalMigrationReceiptTests`。

主会话在沙箱外沿用第 7 节命令：先复编，再跑完整 36 类，再完整门禁。两个抛错用例要确认日志不再报阶段缺失／布局缺失／`failed(deinit)`；如果仍失败，保留新增的 missing IDs 和 AX 原始诊断。全部绿色之后才运行提交助手。截图复核仍按主会话并行安排，本轮没有接到新的截图问题。

### 12.5 红／绿／反证

| 修复 | 红（已有证据） | 绿（主会话待执行） | 反证（仅独立临时副本） |
|---|---|---|---|
| 语义接线 | 三个语义类各 1 处失败 | 三类通过；准确范围、显式扫描、选择／执行分离仍守住 | 恢复加载与未扫描合并条件、把副标题换成隐私／性能声称，应使相应守卫失败，不触发真实扫描或卸载 |
| 内存固定槽和 AX | y=927、80 处命令失败，矮窗总览上移 | 两个 V0 内存用例＋新六档方法通过；14 页 action/art 差≤0.5 pt | 恢复旧自然高度堆叠应使视口包含断言失败；移除某个命令标签应使原生 AX 等待失败。原退出前确认／建议选择测试继续跑 |
| 扫光 | 两个可见运行阳性断言失败 | 可见且活动才转；hidden/no-window/idle/reduced 仍不转 | 恢复异步遮挡状态首帧门槛应使阳性失败；去掉 turns／hidden 守卫应使静止反例失败 |
| 层级、换行、颜色、字体 | 16/18.12<19、280 pt 两列、色差<0.04、0.7 缩放守卫 | 原四组布局／可读性测试全部通过，阈值不改 | 回退任一产品改动，应复现原阈值或 source guard 失败；不把类别同色写成 D62 要求 |
| 标签／探针与拆卸 | AX 原始缺失＋两个二次异常；运行壳缺 root/content | 原运行状态和 Smart Scan 窗口稳定用例通过，缺失原始诊断不再出现 | 删除实际 stage AX label 或 root probe，等待须失败并明确报缺失对象／ID，不能因空字典或 deinit 掩盖而成功；恢复同步拆卸只用作 SDK 对照，不能保证每次触发其二次异常 |

### 12.6 交付、静态核对与未解决项

`prepared-r4/` 基线 `10d981a`，五组顺序：`01-shared-templates` → `02-feature-regressions` → `03-native-motion` → `04-native-hosts-tests` → `05-handoff`。保留旧 prepared/prepared-r2/prepared-r3。每组 patch/message，另有 all.patch、manifest、文件与产物 SHA-256、提交助手、生成助手、逐项修复映射、定向清单、源码审计和 static-checks。trailer 为 `Generated-By: Codex (gpt-6.1-sol)`。

静态核对仅包括基线／分支、空暂存区、差分范围、既有测试方法和保护文件不变、新增参数和环境写入清单、patch 逆向可应用性、哈希；不是构建或 XCTest。**R4 build/test target/strict concurrency/XCTest/screenshots/CPU/hardware/install/commit 全部 NOT RUN，测试执行数 0。** 无法在沙箱确认测试转绿、SDK 原生 AX 发布、宿主二次异常已消除、真实 Reduce Motion 整页或 0 CPU。

本轮核对了可用 JEV gate 工具的实际参数（没有模型选择参数），请求对差分和 NOT RUN 声明复核。自动审批返回 `MCP tool call requires approval, but approval policy is never`，工具请求未执行、没有模型判断；没有改变模型或申请额外权限。完整拦截结果记录在 prepared-r4 的静态产物中。

未解决项保持明确：本轮编译和 36 类运行需主会话执行；截图复核尚未回传；生产任务开始时间普遍未发布，真实用时继续显示“—”，本批仍不得修改 ScanStore。不存在已获得的 R4 绿色证据。


## 13. 视觉第一轮（prepared-r5）

### 13.1 证据、基线与实际状态

完整阅读 `/Users/developer/Developer/.sc-build/r2-ui-v1-shots/visual-review-1.md`（含量化表、矩阵和管线记录）。Claude 的 588 张图来自 **a7636f1 的导出副本**，不是 R4 或当前源码；报告中原始几何和对比度 PASS 不可直接当作 R5 的结果。用户回传 R4 五组提交 `f18173d / 34eb084 / 4d7fcfd / bde26bb / d65e5e4`，随后无冲突并入 r2-hygiene-2 和 D48 补充，当前 HEAD 与本轮补丁基线均为 **3e5a8aee6d0ea1c649bf40632bed7ed6b007d1cc**。没有收到第四轮加并入后的新测试日志。

R5 状态：实现与分组补丁已准备；源码差分、保护范围、补丁反向可应用性及 SHA 清单做静态核对。**Debug/Release 构建、测试目标编译、严格并发、XCTest、截图、读屏、运行录屏、CPU、安装及提交全部 NOT RUN。** 不在 Codex 沙箱执行这些动作。

### 13.2 P1 逐项处理

| 问题 | 分类与依据 | R5 产品改动 | 主会话验收重点 |
|---|---|---|---|
| P1-1 内存仪表盘裁切 | **修回退**。D62①保留获批 V0，②允许仪表盘变体；用户第五轮明确指定报告方案 A | `FeaturePageScaffold(isDashboard: true)` 使用全宽仪表盘，取消起始插画；正常视口使用原 `MemoryReleasePanel` 的压力／占用圆环、建议和完整 118/170 pt 趋势图；进程表填满余下空间，退出条固定；约 338 pt 详情极矮窗保留两类测量环的紧凑摘要与至少 44 pt 列表、退出条，指标详情和趋势仍在原说明 popover。较小余量用紧凑选择条，不挤走列表。刷新采用其他功能的 x/y/宽/52 pt 高令牌 | 三种底色 1280/1680/2400 完整趋势坐标、至少三行进程；820 显示完整圆环和建议；零选/部分/全选的命令可见可用。V0 两个内存类断言继续执行 |
| P1-2 固定卡高、文字和能力卡横切 | **修回退**。D62②③适配真实视口，主按钮与取消槽固定 | `compositionHeight` 改为 body 实际高度；同一窗口仍同高。`FeatureOptionsScrollView` 测量底部溢出，显示 24 pt 渐隐和“向下滚动查看更多”，末项可滚到；按钮不滚动。健康起始为同族三张紧凑能力卡，运行缩为一行能力芯片，全文保留 help/AX；能耗已完成步骤汇总，当前与下一步排在前面，阶段标题也在运行卡顶；性能一般说明在 regular 以下一行+help，禁用原因/安全解释仍完整换行 | 820/1000 三底色文字与卡片无无提示裁断；当前能耗步骤不被已完成列表挤走；最矮窗口的隐藏内容有提示且可达 |
| P1-3 光晕方块 | **修回退**。D58 原合成方式保留，D62②③要求统一插画 | 两个静态 drawingGroup 在合成前 padding(bleed)，合成后 padding(-bleed)，bleed=max(32,nodeSide×1.5)。几何槽与 nodeSide/nodeOrbitRadius 的 nonisolated 声明不变；没有把光晕再框回 side×side | 820/677×390/1280×390 三底色，边缘亮度阶跃目标 <3，无矩形边界；CPU 和显存由主会话实测 |
| P1-4 智能扫描规格降级 | **修回退**。D62①保留 V0 规格，并按②③提升为共用规则 | `FeatureOptionRow` 图标 44 pt、行距令牌 16 pt；`FeatureOptionList` 在稀疏卡内分配余量，最后一行靠近主按钮。运行指标最多三列，标题在上、28 pt 等宽数字在下，分类 details 紧随。智能扫描及绿/开发运行夹具 60%、128 项、2.2 GiB、60/100，含用户缓存/浏览器数据/日志文件三组 | 1280 按钮上方空带 ≤48 pt；运行首屏大指标和分类可见；14 功能共同使用令牌 |

内存例外仅针对起始仪表盘的插画与主体宽度，**14 个功能的主按钮 frame 仍统一**；其余 13 个起始页和全部 14 个运行页的插画 frame 保持同位同大。没有为内存单独改变确认、退出、采样或推荐选择的规则。

### 13.3 P2 全部逐项处理

| 项 | 分类 | 处理与保留理由 |
|---|---|---|
| P2-1 大窗贴顶/空带 | 修回退，D62②③ | 卡片使用实际 body 高度，插画在等高两列中垂直居中；共用选项容器把较少的内容垂直居中，`FeatureOptionList` 按实际滚动视口减末项标记/间距后均分余量。去掉大窗固定 520 pt 后下方 263–563 pt 空白，不改 V0 页头到内容的层级间距 |
| P2-2 最矮无滚动提示 | 修回退，D62②④可达性 | 共用 measured fade+24 pt 文字提示；卡底按钮保持 52 pt，取消槽 40 pt。测试增加最矮窗口提示存在、提示位于选项区及按钮上方；所有末项可达测试保留 |
| P2-3 已用时间未知常驻 | 修回退，D62③及用户第五轮计时授权 | 真实有效 `elapsedSeconds` 优先；缺失时 `FeatureRuntimeClockHost` 按窗口、模块和 taskIdentity 保存首次出现时刻，阶段样本及页面切换不重置。读取既有模型活动旗标回收结束任务；搬家 App 模式复用卸载清单读取的活动状态。明确“约”和帮助说明；只在运行视图出现且 state.isActive、没有真实/演示 elapsed 时挂每秒 TimelineView，起始页无循环。**当前 BenchmarkV7State 源码并没有 elapsedSeconds 字段**，不按报告文字臆造属性或借上次结果时间；未来真实值沿现有参数优先传入 |
| P2-4 演示与生产不一致 | 修回退，D62③④ | 全部 14 个运行入口调用同一生产运行视图，固定值仅替代数据源；性能监视图 220 pt 保留，取消能力与文案跟生产；智能扫描三分类；相似照片的页头与中心插画读取 mode override。未知实际进度不硬填 42% |
| P2-5 不可取消低对比度 | 修回退，D62③可读性 | 有取消回调用 `FeatureCancellationButtonStyle` 的 textPrimary/inset 表面；不可取消用锁图标说明行，保持同一 40 pt 槽。停止时仍禁用回调，文本不靠灰度传递能力。目标三底色≥4.5:1，**像素对比度尚未重测** |
| P2-6 阶段条换行 | 修回退，D62③ | 模板内性能六阶段、更新五阶段用一行等分 HStack，6 pt 间距、单行文本、完整 help/AX；性能旧 dashboard 的 ViewThatFits/wrapping 分支保持 V0 规则，既有 wrapping 测试不改 |
| P2-7 组件族杂乱 | 修回退；其中开发图块列数按 D62②改契约 | 起始网格统一 `FeatureOptionCard` inset 表面；选择卡/能力卡同族。开发与登录项的大图块最多两列、图标32+标题；卸载和更新用44 pt图标选项行；文件分析四类别也改同族两列图块，保留各类别颜色与标题。健康按 P1-2 采用紧凑横排。重复文件两个位置按钮用 inset 表面（含令牌描边），搬家类型控件在原生 Grid 的值列明确 leading，对齐不改绑定或默认值 |
| P2-8 插画项目不一致 | 修回退，D58/D62② | 节点改为 CPU/GPU/内存/存储（顺序也一致）、系统状态、媒体、下载残留；共享 orbitNodes 数据仍来自对应范围定义，不改业务分组 |
| P2-9 取消动词不一致 | 修回退，D62③④ | 扫描用“取消扫描”，读取用“取消读取”，性能用“取消测试”，优化动作保持“取消”。更新保留“停止扫描”和原帮助：在扫描器安全边界停止，部分结果不当作完整扫描；不把两种语义强行改名 |
| P2-10 主按钮图标/动词（可选） | **保留，明确理由**，D62④ | 统一高度/字号/圆角/38 pt图标圈/18 pt符号/内边距，保留既有动作图标及“读取/检查/分析/刷新/扫描”文案；它们说明实际动作，全面换成“开始+名词”会减少动作辨识。没有引入第三种主按钮样式，长标题最多两行、不缩放 |
| P2-11a 布局动画中间帧 | 修回退，截图隔离 | capture 参数自动关闭 AdaptivePageViewport 的布局动画和 transaction 动画；侧栏跨阈值直接赋值；管线导航/phase 用 disablesAnimations transaction。单独演示可加 `--debug-feature-disable-layout-animations`。运行 CA 扫光仍按原护栏处理 |
| P2-11b 重复筛选污染 | 修回退，夹具隔离 | 演示 `presentationFilter` 明确 `.all`；仅 `--debug-feature-similar-photos` 时 `.similarImage`。使用只读 constant binding，不读取或写回共用 result-filter。生产无 override，继续原偏好和控件行为 |
| P2-11c 内存自动刷新闪动 | **保留既有流程，待录屏**，N19/D49/D62④ | 200 ms 延迟、30秒过期检查和 canRefresh/选择守卫逐字保留；演示/测试显式 fixture 时跳过。未经真实生产录屏不判定闪动通过或改采样语义；如仍闪动，由主会话回传同一任务证据处理 |

### 13.4 API、计时边界与文件改动

新增视图层文件 `DesignSystem/FeatureOptionsPresentation.swift`（滚动提示、稀疏列表布局、三列指标、取消样式和近似计时缓存）、`FeatureFixedDashboardSlot.swift`（固定总览/列表槽）、`FeatureRuntimeClockHost.swift`（只读活动状态观察）、`Views/FeatureRunningPages.swift`（值驱动生产适配页）。`FeatureRunningTemplate` 新参数 `taskIdentity/pageTitle/pageSystemImage`；后两者供重复/相似照片模式沿用真实标题及图标。`FeaturePageScaffold` 新 `isDashboard`，普通页面仍原默认。运行未知比例/路径保留“未提供”，不冒充引擎测量。

近似计时在任务第一次显示才开始，因此后台已运行的时间可能少算；应用退出后不持久保存；新的无 ID 操作通过已有模型活动→非活动→活动识别。Benchmark/更新有 sessionID 时直接作为任务身份，预检先没有身份时在 ID 发布后保留起点。同一窗口切换路由保持起点；完成/失败/取消后释放。缓存无磁盘写入或采样任务。真实起点若由模型发布，调用方应传入有效 elapsedSeconds，本批不添加 ScanStore 状态。

页面改动：智能扫描仅范围行升级，共用指标替换表单小数值；安全清理与开发工具继续既有绑定/阈值，只升级图块表面和列数；健康/隐私/能耗/卸载/启动项/内存/性能改用值适配运行页；更新仅扫描轨道/任务身份；文件分析升级类别图块，搬家只对齐类型值列；重复新增演示只读 mode 和运行适配。`ContentView` 仅窗口级计时观察和 capture 侧栏动画开关。没有改业务 Store/模型、执行器、依赖、菜单栏小窗或设置。

结果、确认、完成页实现保持基线；`SystemUtilitiesView.resultDashboard` 及 `FileToolLandingPage` 中 `LegacyTerminalLandingPage` 主体逐字不变。共享节点标题可能同步影响旧装饰插画，限词名一致性；旧按钮/内容/执行不迁移。性能旧 dashboard 的阶段分支不改变，不放宽其既有布局断言。

### 13.5 改写旧断言与 D48 补充

| 测试/旧断言 | 新断言或修改 | 分类、依据与保留的安全含义 |
|---|---|---|
| `SafeCleanupLayoutTests.testDeveloperCategoriesUseBalancedRowsThroughWidthChanges`：1280/900及回到1280期望四列 | 三个条目期望两列，其余2/1列边界不变 | **按 D62 改契约**：D62②统一选项组件族，用户视觉 P2-7明确“两列大瓦片”。保留完整行、顺序、无重叠、末项可达及可读性断言，未变任何误差阈值 |
| `FeatureTemplateContractTests.testAllFourteenLandingActionsAndIllustrationsHaveIdenticalNativeFrames` | 改名 `testAllFourteenLandingActionsAndIllustratedPagesHaveIdenticalNativeFrames`；14主按钮仍比较全部 x/y/宽/高≤0.5pt，插画比较13个有插画的起始页；新增1084×338详情档 | **按 D62 改契约**：D62②仪表盘变体，用户本轮P1-1明确恢复V0全宽且不用插画；不削弱14按钮/7尺寸可见性及末项可达，全部14运行态仍比较插画/取消元素 |
| 同类 `testProductionStartupAndMemoryRunningPagesUsePublishedStateAndCancellationSlots`：内存读取要求不可用取消按钮具备 press 角色 | 读取无取消时仅要求可读名称/槽frame，不要求 press；优化/启动项仍要求真实按钮可按 | **按 D62 改契约**：D62③取消槽及用户P2-5指定说明行；没有增加取消API，没有变可取消状态、调用或frame阈值 |
| 同类 `makeStore` 的直接 ScanStore init | `throws`→`try ScanStore.makeForTests(for: self, …)`；调用链传播throws | **修回退/测试卫生**：D48补充和RULES§3；强制隔离默认依赖，provider若被意外调用仍XCTFail |
| `GeneratedArtTests` 缺失插画根、`DesignSystemV2ReviewTests` 缺失资源根、`ConceptLandingNativeLayoutRegressionTests` 空历史JSON路径 | 三处用 `try TestFileSystem.makeHome(for: self)` 根帮助函数，保留原子路径/测试行为；去掉手写UUID临时根与try?吞删除失败 | **修回退/测试卫生**：D48补充和RULES§3；先登记所有权、teardown严格清理；原V0断言逐字保留，未放宽或跳过 |

本轮没有改 `DesignSystemV2Tests`、`OwnedUIFlatteningContractTests`、`CompetitiveParityContractTests`、`SystemUtilitySafetyTests`、`SafeCleanupScopeCardLayoutTests`、`TestPreferenceHygieneTests` 的源码或阈值。`DesignSystemV2ReviewTests` 仅改夹具根，上表之外没有改它的行为断言。V1新增/历史修改的测试均复核 factory/owned-root：FeatureTemplate、ConceptLanding、DesignSystemV2、Review、GeneratedArt、SafeCleanup、StartupItemsDashboard、ItemListAndDuplicate、UIConsistency；不把源码断言中的字符串误改为工厂调用。

新增三个有实际失效场景的测试：同一任务计时缓存及结束后新任务、最矮起始态溢出提示与按钮位置、性能演示中的实际 monitor/dial/stages。原宿主强持有生命周期和超时缺失IDs诊断保留；没有伪造 accessibilityReduceMotion 或其他只读辅助环境；既有探针的 accessibilityEnabled 在本机SDK27 SwiftUICore接口有get/set，保留其可写注入（同时确认displayScale/legibilityWeight也是get/set，未把它们误列为只读）。SDK 27 的 Reduce Motion 继续直接测 AppMotion 纯函数与原生 turns 注入。

### 13.6 Debug 运行映射与完整参数

以下参数均必须加 `--debug-mini-window-demo-data`；单个入口可加 `--debug-feature-disable-layout-animations`。生产与 Debug 两边使用表中的**同一个 View 类型**，只注入固定数据/能力/惰性回调；Debug不调用真实扫描、外接卷读取、负载或硬件。

| 功能 | 起始参数 | 运行参数 | 同一生产运行视图 / 数据 |
|---|---|---|---|
| 智能扫描 | `--debug-feature-page=overview:landing` | `--debug-feature-page=overview:running` | SmartScanScanningPage，60%/128/2.2GiB/60÷100/3组 |
| 安全清理 | `--debug-feature-page=green:landing` | `--debug-feature-page=green:running` | SmartScanScanningPage，同组数据，保留green模块 |
| 开发工具与产物 | `--debug-feature-page=devCaches:landing` | `--debug-feature-page=devCaches:running` | SmartScanScanningPage，同组数据，保留dev模块 |
| 系统健康 | `--debug-feature-page=healthHub:landing` | `--debug-feature-page=healthHub:running` | HealthCheckRunningPage，已确认内置电池能力 |
| 浏览器隐私 | `--debug-feature-page=privacy:landing` | `--debug-feature-page=privacy:running` | BrowserPrivacyRunningPage，取消读取 |
| 性能 | `--debug-feature-page=performance:landing` | `--debug-feature-page=performance:running` | PerformanceBenchmarkRunningPage，42%与真实结构的220pt monitor，固定遥测 |
| 登录项 | `--debug-feature-page=startup:landing` | `--debug-feature-page=startup:running` | StartupItemsRunningPage，已发现128，取消读取 |
| 内存 | `--debug-feature-page=memory:landing` | `--debug-feature-page=memory:running` | MemoryRunningPage，读取状态、无取消API，起始完整固定快照 |
| 能耗 | `--debug-feature-page=energy:landing` | `--debug-feature-page=energy:running` | EnergyImpactRunningPage，measuringChanges阶段，当前/下一步 |
| 卸载 | `--debug-feature-page=uninstall:landing` | `--debug-feature-page=uninstall:running` | AppUninstallRunningPage，读取应用清单、无取消API |
| 更新 | `--debug-feature-page=updater:landing` | `--debug-feature-page=updater:running` | AppUpdateScanningPage，42/100，五阶段单行，停止扫描 |
| 文件分析 | `--debug-feature-page=largeFiles:landing` | `--debug-feature-page=largeFiles:running` | LargeFilesRunningPage，128项/2.2GiB，进度未知保留未知 |
| 文件搬家 | `--debug-feature-page=migration:landing` | `--debug-feature-page=migration:running` | LargeFilesRunningPage，文件模式42%/128项/2.2GiB，取消扫描 |
| 重复文件 | `--debug-feature-page=duplicates:landing` | `--debug-feature-page=duplicates:running` | DuplicateFilesRunningPage，固定all，扫描128/校验64/读取2.2GiB |

重复的相似照片模式：以上任一 duplicates 参数追加 `--debug-feature-similar-photos`，起始和运行都显式 similarImage；不读共享筛选。每个演示运行页注入12秒（Benchmark也通过真实参数传12）；如要核实生产近似计时，**不要带这些固定演示入口**，用隔离实际任务或纯缓存测试，录制开始/阶段/换页/结束。

默认矩阵七档：820×560、1000×700、1280×764、1680×1050、2400×1350、677×390、1280×390；需要严格复现本次报告可显式请求1280×763。所有产物核对capture-feature-templates.json请求/实际尺寸；新增 productionRunningView、layoutAnimations、duplicateFilter 元数据。这些字段记录接线与参数，**不是测试或视觉PASS标记**。

```bash
"$SC_DEBUG_BINARY" --debug-mini-window-demo-data \
  --debug-feature-page=all:landing --capture-feature-templates \
  --debug-feature-disable-layout-animations \
  --debug-mini-window-appearance=dark -app.canvasTheme deepSpace \
  --capture-main-window-directory=/Users/developer/Developer/.sc-build/r2-ui-v1-shots/r5/deep \
  --capture-main-window-sizes=820x560,1000x700,1280x763,1680x1050,2400x1350,677x390,1280x390 \
  --capture-settle-ms=1600
```

三底色参数仍按第6节；各启动独立隔离进程，不必额外写 `duplicate-files.result-filter`。同一矩阵全14×两态×7档×3底色仍为588张，内存起始采用明确的dashboard例外。补充2400→677首次截图切换验证，以及非演示生产内存刷新录屏。

### 13.7 定向测试、红/绿/反证与交付

必须以 `prepared-r5/directed-tests.txt` 运行第7节命令。保留原36类；追加 `WindowGlassConfigurationTests`（窗口/捕捉壳）和 `ScanStorePerformanceTests`（ContentView历史启动与只读观察接线）两类，共38类。没有改这两类或运行它们。三项语义类、两个V0类、TestPreferenceHygiene 和所有已有页面布局类仍在清单内。

| 修复 | 红证据 | 绿验收（主会话执行） | 反证（主会话的隔离源码副本） |
|---|---|---|---|
| 内存仪表盘 | key/01、02；第三轮AX命令越界 | V0内存/Review/FeatureTemplate全尺寸零选/部分/全选均通过；三底色完整趋势和≥3行表 | 恢复窄卡/固定380高，应再触发列表/命令越界和对应截图失败 |
| 动态高度/溢出 | key/03、04、05、10 | 820/1000完整阶段；两最矮都有提示，末项滚到按钮不动；14按钮/13起始插画/14运行取消frame≤0.5pt | 恢复固定高度或移除hint，新最矮提示测试或截图应失败；任一按钮偏1pt应失败 |
| 光晕 | key/06、07亮度阶跃 | 三底色小图无方块，边缘阶跃<3；空闲CPU0；隐藏/Reduced不旋转 | 撤回bleed应复现阶跃，不降低阈值，不用新底色掩盖 |
| 智能扫描与生产演示 | key/08、09及旧夹具groups空 | 大号3指标/3分类；性能monitor真实；同mode页头；P2-8标签对应 | 清空groups或删monitor，应使截图/新monitor存在测试失败 |
| 近似计时 | 13处未传elapsed的源码记录 | 新缓存测试；真实隔离任务开始/换阶段/切路由计时持续，新任务重置，明确约 | 每次阶段更新reset或不回收结束任务，新缓存测试/录屏应失败；不能借夹具12秒宣称生产通过 |
| 取消/阶段/组件 | 报告P2-5/6/7/9 | 三底色文字≥4.5:1、阶段单行、图块2列、动作语义原样 | 恢复disabled灰度应使对比度复核失败；错误增加读取取消API须被能力测试拦下 |
| D48卫生 | 本轮原FeatureTemplate直接init及三处手写根 | TestPreferenceHygiene通过，所有工厂/根属于当前XCTest且严格清理 | 测试副本恢复ScanStore(...)或手写UUID根，源码卫生守卫应报告违规；不在真实目录做反证 |
| capture布局/筛选 | 报告P2-11a/b | 2400→677首次PNG为最终布局；共享域similarImage仍不改变默认all演示 | 去掉transaction或显式mode，应复现中间帧/污染；只操作隔离进程域 |

`prepared-r5/` 顺序：`01-templates-tokens` → `02-dashboard-utilities` → `03-feature-running-pages` → `04-file-options` → `05-demo-capture` → `06-contracts-hygiene` → `07-handoff`。含patch/message、all.patch、最终文件/产物SHA、manifest、只供主会话验证后运行的commit-prepared.py、metadata生成器、静态核对、38类过滤文件、逐项视觉修复清单及JEV拦截原文。旧轮交付目录保留。

剩余限制：上述源码已修，**不能宣称任何P1/P2视觉或CPU验收通过**；Swift类型/严格并发仍待外部编译。光晕余量增加离屏合成面积，需实拍和性能复核；近似时间有首次可见边界；内存200ms自动刷新必须录屏核实。P2-10保留原动作措辞，P2-11c保留既有采样流程，理由已列，不把它们记作已实测解决。

实际尝试JEV gate（工具实际无模型选择参数），自动审批返回 `MCP tool call requires approval, but approval policy is never`。请求没有执行、没有取得模型判断；没有申请绕过权限。原结果见 `prepared-r5/jev-gate-result.json`。

## 14. 主会话第五轮编译结果与纯趋势修复（prepared-r6）

### 14.1 基线、已收到证据和本轮状态

主会话已将 R5 七组提交为 `4f605df`、`03a27ba`、`8fd5b88`、`00c4e64`、`4dcee2b`、`e4944f6`、`04d487c`。`FeatureFlowTransitionModifier` 中被 `#if DEBUG` 截断的条件链由主会话改成提前返回的完整分支，提交 `a94269b`；本轮不改这项修复。完整基线为 `a94269b2142cb77a9664feae46e7b7f667438eac`，工作区开始时干净。

`logs/main-build-6.log` 是主会话提供的 **FAIL** 证据：`SystemUtilitiesView.swift` 第 3798、3868、3923、3961 行报不透明返回类型以自身定义。四个错误共享一条源码循环：`MemoryReleasePanel.metricDetailsButton` 的弹层引用 `memoryTrend`，`memoryTrend` 又包含同一个详情按钮，`body` 和 `compactDashboardSummary` 随之无法推导。

本轮只编辑一个生产文件和本交接，未新增或修改测试。**Swift 编译、测试目标编译、严格并发、XCTest、截图、录屏、CPU、安装和提交全部 NOT RUN。** 静态结果仅证明补丁格式及下述源码边界；实际编译和行为回归须由主会话在沙箱外执行。

### 14.2 根因修复、调用关系和语义边界

本轮均属于**修回退（编译阻断及弹层自我嵌套）**，没有按 D62 改写契约，也没有放宽或删除 V0 断言。

| 位置／API | 修复方式 | 保留的行为 |
|---|---|---|
| 独立 `private struct MemoryTrendChartView: View` | 从原趋势区域抽出 `TrendChart`，输入 `trendPoints`、`updatedAt`、`chartHeight`，`showsHeader` 默认为 `true`；不持有 Store、回调、详情按钮或弹层状态 | 同一内存／压力两条序列、可选未知值、`0...100` 范围、120 秒窗口、主题色／压力估算色、曲线读数及数据动画 |
| 独立 `private struct MemoryTrendHeader: View` | 抽出原 `ViewThatFits` 表头、图例和更新时间，页面与纯图表共用 | 保留先去标题、再去时间的窄列回退顺序、原字体与间距、两条图例、`最近更新` 读屏标签 |
| `MemoryReleasePanel.memoryTrendRegion` | 页面趋势等于共用表头＋原详情按钮＋纯图表；纯图表传 `showsHeader: false`，不重复表头 | 原表头按钮位置、8 pt 区块间距；图表高度仍按原公式选择摘要高度／170／118 pt |
| `metricDetailsButton` 的弹层 | 紧凑摘要的弹层构造 `MemoryTrendChartView`，不再引用页面趋势区域 | `showsMetricDetails` 开关、320 pt 弹层宽度、14 pt 内边距、D28 指标说明、原推荐动作及可见条件；趋势内部没有第二个详情按钮 |
| `body`／`compactDashboardSummary` | `body` 三个趋势入口改用 `memoryTrendRegion`；紧凑摘要继续引用修复后的同一个 `metricDetailsButton`，无需改它的布局或命令 | 普通、宽列、起始摘要入口一致；紧凑摘要圆环、文本、help 和读屏行为沿用原实现 |

两种纯视图作为独立结构体放在同一个 `SystemUtilitiesView.swift` 中、`MemoryReleasePanel` 后面，避免引入第二套绘图实现。仍使用 V0 的 `TrendChart`，没有 `AnyView` 类型擦除、额外动画、计时或新依赖。原文件中的图表标题与指标说明仍在，既有源码守卫无需迁移。

源码调用现在是单向关系：

```text
body → memoryTrendRegion → metricDetailsButton → 弹层的 MemoryTrendChartView
compactDashboardSummary → metricDetailsButton → 弹层的 MemoryTrendChartView
MemoryTrendChartView → MemoryTrendHeader / TrendChart（均不返回 MemoryReleasePanel）
```

内存页采样、刷新、选择命令、执行前确认、按钮防抖和退出请求没有改动。`MemoryReleasePanel` 前面的工作区源码及 `MemoryInlineMetric` 开始之后的选择／进程表／退出条源码与基线逐字相同；圆环、推荐摘要和推荐动作成员也逐字相同。`ScanStore.swift`、`DataVisuals.swift`、`FeatureTemplates.swift`、全部测试文件均保持基线内容。

### 14.3 全仓同类循环检查

`prepared-r6/audit-view-references.py` 只读取源码，不调用 Swift 工具链。它扫描仓库全部 **798 个 Swift 文件**（含 Sources、Tests、脚本与 Package 文件），屏蔽注释和字符串，对同一类型及 extension 的不透明 View 成员做引用图和强连通分量检查，另加入名义视图构造边观察跨视图嵌套。基线识别 **1408 个声明／611 个所有者**；修复后 **1410 个声明／613 个所有者**。

基线发现六组词法候选；其中内存两成员互指是真实循环，修复后消失。其余五组逐项阅读调用体后均为**同名重载的单向转发**，没有修改：

| 文件／成员 | 实际调用 | 被调用实现为何不形成循环 |
|---|---|---|
| `ComputerHealth/BenchmarkV7DashboardView.swift`：`comparisonCard` | 无参计算属性 → `comparisonCard(first:second:)` | 双结果构图函数没有回调无参属性 |
| `ComputerHealth/BenchmarkV7PerformancePresentation.swift`：`stageGrid` | 无参计算属性 → `stageGrid(columns:)` | 网格函数只构造 `LazyVGrid` 和阶段行 |
| `ComputerHealthView.swift`：`thermalReadinessCard` | 无参计算属性 → `thermalReadinessCard(now:)` | 时间参数函数只计算状态并构造指标区域 |
| `DesignSystem/FeatureTemplates.swift`：`elapsedLabel` | 无参计算属性 → `elapsedLabel(at:)` | 时间参数函数只构造已用时间 `Label` |
| `Support/GlassStyle.swift`：`adaptivePopoverChrome` | `cornerRadius:` 重载 → `cornerRadii:` 重载 | 后者只应用 `AdaptivePopoverChromeModifier` |

把名义构造边纳入引用图后，修复前后都没有额外跨视图循环候选。记录见 `view-reference-audit-before.json`、`view-reference-audit-after.json` 和 `view-reference-review.json`。没有发现另一处需要修复的同类展开循环。

**限制：这是词法源码审计，不是 Swift 类型检查。** 名称图会合并重载，条件编译分支不求值，宏生成代码、泛型／注入子视图和重载推导仍须编译器验证；不以候选消失宣称全仓已编译通过。

### 14.4 定向验证、红／绿／反证

继续使用 R5 的完整 **38 类**清单，本轮在 `prepared-r6/directed-tests.txt` 提供相同过滤表达式。必须包括 `UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`、`DesignSystemV2Tests`、`DesignSystemV2ReviewTests`、`ConceptLandingNativeLayoutRegressionTests`、`GeneratedArtTests`、`FeatureTemplateContractTests`，并保留所有页面已有布局与语义类。本轮没有新建 Store／夹具或改写任何旧断言；D48 的工厂与所有权规则继续适用。

由主会话在沙箱外执行，以下命令在本轮均 **NOT RUN**：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug --jobs 4
SC_UI_V1_R6_FILTER=$(cat /Users/developer/Developer/.sc-build/r2-ui-v1/prepared-r6/directed-tests.txt)
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug --jobs 4 --filter "$SC_UI_V1_R6_FILTER"
```

| 项目 | 红证据 | 绿验证（主会话执行） | 反证（只在隔离导出副本） |
|---|---|---|---|
| 不透明类型递归 | 基线 `main-build-6.log` 四个编译错误及 before 引用图 | Debug 生产及测试目标编译通过，after 图内存循环消失 | 在隔离副本把弹层纯图表换回 `memoryTrendRegion`；静态图应重新出现两成员循环，编译应再次报递归诊断；不修改本 worktree |
| V0 布局与命令 | 第三轮内存命令越界证据及 V0 既有断言 | `DesignSystemV2Tests.testMemoryPageKeepsOverviewListAndQuitBarVisibleAtEverySize`、`DesignSystemV2ReviewTests.testMemorySelectionCommandsStayAvailableWhateverIsSelected`，零选／部分选／全选均保持可达 | 若把命令改成只在非零选择时显示，原 V0 断言应失败；本轮没有这项变更 |
| 指标与读屏 | 原 D28 说明和趋势双序列契约 | `DesignSystemV2ReviewTests.testTrendChartReadsBothSeriesAndTheSampleUnderThePointer`、`UIConsistencyRegressionTests.testMemoryEmptyStateHidesUnavailableActionsAndAvoidsRepeatedMetrics`、`MemoryPressureLevelAppWideTests` | 只在副本去掉第二序列或压力估算标题，应使原契约／读屏复核失败；本轮保留原参数与全部本地化文本 |
| 选择／退出安全 | 原 N19／D49 行为契约 | `MemorySelectionSummaryTests`、`MemoryQuitConfirmationTests`、`OwnedUIFlatteningContractTests`、`SystemUtilitySafetyTests` | 不以截图按钮可见作为已验证退出安全；必须保留选择与确认测试的原断言 |
| 紧凑详情及常规趋势 | 基线弹层自我嵌套 | 以隔离夹具在最矮紧凑摘要点开“指标说明”，只出现一层指标说明与纯图表；关闭后页面按钮仍可用；常规窗口图例、时间、曲线及悬停读数一致 | 在隔离副本恢复带按钮的整块趋势，应复现源码循环；不要调用退出或硬件操作 |

Debug 参数仍按第 6、13.6 节。重点复核 `--debug-mini-window-demo-data --debug-feature-page=memory:landing --debug-feature-disable-layout-animations`，覆盖五档及 `677×390`、`1280×390`，三底色。自动截图入口会关闭鼠标命中，**不能用它宣称已点开详情弹层**；弹层交互由主会话用独立隔离偏好域与内存夹具托管或录屏验证。运行态 `memory:running` 的生产视图、数据接线与演示参数没有改动。

### 14.5 交付与未解决项

`prepared-r6/` 基线 `a94269b`，补丁顺序为 `01-memory-trend`（唯一生产文件）→ `02-handoff`。包含 patch/message、`all.patch`、文件及产物 SHA-256、manifest、静态核对、引用审计脚本及前后证据、人工候选解释、38 类过滤表达式，以及仅供主会话验证后运行的 `commit-prepared.py`。提交助手本轮未执行，不暂存、不提交。`generate-prepared.py` 只生成补丁和静态元数据。

**PASS（仅静态）**：补丁 whitespace／反向应用检查、源码边界比对、图表调用参数与本地化文本保留、内存循环消失及五组候选人工解释。具体命令及 exit code 见 `static-checks.json`。没有结果页、确认页、设置或菜单栏行为变更。

**NOT RUN／未解决验证项**：修复后的 Swift／严格并发结果、V0 和语义回归、趋势区域原生 frame／读屏与紧凑弹层交互仍等主会话实测。R5 视觉与性能待验证项继续按第 13 节执行，本轮不把它们记为通过。

本轮实际尝试 JEV gate；该工具没有模型选择参数。自动审批返回 **BLOCKED**：`MCP tool call requires approval, but approval policy is never`。请求未执行，没有取得 JEV 判断，没有申请绕过限制；原返回保存为 `prepared-r6/jev-gate-result.json`。

## 15. 主会话第六轮验证结果与五项回归修复（prepared-r7）

### 15.1 基线、失败证据与交付状态

主会话已提交 R6 的 `65d6d2e`、`fb38d48`，并将 `EnergyImpactScanPhase.shortTitle/detail` 所在扩展由 `private` 改为 `internal`，提交 `85af09f`。本轮基线为 `85af09fd21134e6be1ae1ab631f72de7d346c05b`，开始时工作区干净；不改这项访问级别修复或已解除循环的内存趋势实现。

主会话提供 `failures-r6.txt` 和 `logs/main-test-8.log`：生产与测试目标编译通过，38 个定向类加守卫共 **660 项、跳过 1、5 个失败测试、8 处失败**；清单包括 AX 和布局探针等待抛错。以下是对该失败清单的源码修复及定向契约调整，**不是新一轮测试通过记录**。Swift 编译、严格并发、XCTest、原生布局／AX、截图、录屏、CPU、安装和提交全部 **NOT RUN**。

### 15.2 五项问题的处理及分类

| 主会话问题 | 本轮处理 | 分类、依据及保留的约束 |
|---|---|---|
| ① 运行阶段 AX 等待到 `HostingScrollView` 后没有子元素 | `FeatureRunningTemplate.body` 在 Debug 上报真实渲染输入；宿主等待已发布的阶段与取消槽快照，独立要求阶段、取消槽 frame 存在。启动项测试在同一个宿主发布第二个阶段，要求探针随实际 Store 输入更新。可操作取消按钮位于卡外，继续检查原生 AX press 动作 | **修测试观测回退**：N20 的宿主限制、D62③阶段与取消槽契约；不读取滚动内容的 AX 树，不伪造 AX 元素或系统环境。读取内存仍无取消回调，优化与启动项仍有原回调；不以 PreferenceKey 宣称真实 VoiceOver 已验收 |
| ② 613×338 缺少 `landing.scrollHint` | 内容和可见区统一用 `.global` 坐标比较；PreferenceKey 合并时不让零尺寸兄弟节点覆盖文档测量。滚动内容保留自然高度，不接受短视口压缩；内容末端超过可见区 0.5 pt 时显示原有渐隐与“向下滚动查看更多”探针 | **修产品回退**：D62②最矮页主按钮可见且选项在卡内滚动，视觉 P1-2/P2 要求可见提示。失败日志中的文档约 203 pt、可见区约 130 pt，确有溢出。主按钮、提示高度及原误差不变；新增滚到底后提示消失、末项可见、按钮 frame 不动的验证 |
| ③ `GeneratedArtTests` 第 106／109 行 | 实际两行分别锁定 `guard turns, window != nil, window?.isVisible == true` 和 `window?.occlusionState.contains(.visible) == true`，并非内存插画位置断言。恢复产品中的附着／可见窗口检查和已发布遮挡检查，收到完全遮挡通知即移除旋转 | **修产品回退**：D62①保留 V0、D62③空闲／减弱动态效果静止及窗口可见性护栏。`GeneratedArtTests` 整文件不变。隐藏的新窗口在首个遮挡通知之前按同步 `isVisible` 启动；已显示窗口插入新视图时立即使用遮挡状态。这样保留 R4/R5 处理过的窗口服务器首显发布时序，不重引入首显不转问题 |
| ④ 900／1100 高窗卡实际 528、期望 694／894 | `LandingMetrics.compositionHeight` 已按实际详情视口计算，没有 528 上限，本轮不改公式。旧 `AppKitLayoutHost` 使用普通 NSWindow，区别于 V0 Calibration 的屏幕约束覆写；统一测试宿主允许逻辑高窗，并要求原生 bounds 和 `landingRoot` 达到请求尺寸才接受稳定 frame。稀疏内容以自然行距在卡内垂直居中 | **修宿主回退及产品稀疏构图回退**：D62②统一卡／按钮与视觉 P1-2 的“随窗口增高、同窗口等高、稀疏内容居中”。694／894 期望、公式及 0.5 pt 容差保留，不把期望改成 528。屏幕约束是否为原生失配的全部原因仍须主会话实测；超时现在同时报告请求尺寸、原生 bounds 和 landingRoot |
| ⑤ 473×360／1072×360 范围卡 `panel.contains(card)` 失败 | 产品滚动文档保持自然高度；测试逐一滚入三个完整范围卡，再执行原有 panel 包含断言，另要求每张卡完整落在选项可见区，操作按钮及状态条 frame 完全不动。外层页无需滚到状态条 | **产品修回退＋按 D62 改布局契约检查时机**：D62②“最小尺寸下随卡片贴底仍可见”，初版任务明确“选项列表在卡内滚动”，视觉 P1-2 明确溢出时卡内滚动。取消旧的“未滚动时所有项同时可见／外层滚到 footer”假设；完整可达性、可读性及原包含断言保留，并新增更严格可见区检查，不放宽阈值 |

稀疏内容不再把剩余高度摊入每两行之间，而由共同滚动容器居中；图标 44 pt、原说明、默认值、选择绑定、卡片尺寸、按钮令牌及大窗视口公式都不变。动态卡高仍由 `FeaturePageScaffold` 和原 `LandingMetrics` 统一，新增 14 功能起始卡高度／纵向槽 ≤0.5 pt 的原生一致性断言（内存仪表盘例外只有内容／插画，卡槽继续比较）。

### 15.3 API、文件边界与改写旧断言

新增 `Debug/FeatureRuntimeRenderProbe.swift`，整个文件在 `#if DEBUG` 内：

```text
FeatureRuntimeRenderSnapshot: Equatable, Sendable
  stageTitle / cancellationTitle / cancellationHasAction / cancellationIsEnabled
FeatureRuntimeRenderPreferenceKey
  [module.rawValue: FeatureRuntimeRenderSnapshot]
CalibrationAppKitLayoutHost.runtimeContent(module:stageTitle:)
  等待实际 body 发布值及连续稳定；超时报告模块、预期阶段和实际内容
```

模板使用同一 `title` 和同一 `cancellationText` 同时构造可见文本与 Debug 快照，能力来自原 `onCancel/canCancel/state`，没有从测试预期或演示 fixture 回填探针。Release 不编译探针类型与上报分支。阶段 frame 仍由可见阶段视图的布局探针提供；取消的可操作槽继续走原生 AX，不调用取消动作。无操作的“此任务不可取消”槽用渲染值、能力及原生布局验证，实际读屏标签实现保持基线。

生产改动只有五个文件：`FeatureOptionsPresentation.swift`（测量、自然高度和稀疏居中）、`FileToolLandingPage.swift`（去掉旧行间摊高用的 inset）、`OrbitLandingArtwork.swift`（仅原生扫光的遮挡护栏）、`FeatureTemplates.swift`（共用取消文字和 Debug 上报），以及新增 Debug 探针。三处测试文件改动：`ConceptLandingNativeLayoutRegressionTests.swift` 的宿主观察、`FeatureTemplateContractTests.swift` 的模板／动效契约、`SafeCleanupLayoutTests.swift` 的逻辑视口和原生滚动。

`OrbitArtworkGeometry`、`nodeOrbitRadius`、`nodeSide(for:)` 等几何声明与 `OrbitSweepView` 之前的源码逐字不变。`ScanStore.swift`、内存纯趋势／选择／退出实现、EnergyImpact 的 internal 修复、`AppMotion`、`DataVisuals`、结果／确认／完成页、菜单栏和设置均不改。三个语义类、`DesignSystemV2Tests`、`DesignSystemV2ReviewTests`、`GeneratedArtTests` 和 `TestPreferenceHygieneTests` 的源码保持基线。

| 旧断言／观测 | 修改 | 依据及没有削弱的含义 |
|---|---|---|
| `FeatureTemplateContractTests.testProductionStartupAndMemoryRunningPagesUsePublishedStateAndCancellationSlots` 同时从滚动 AX 树找阶段与取消名称 | 阶段／取消名称及能力改用 Debug body 探针，仍要求阶段与取消原生 frame；有操作的取消保留原生 press 要求，增加阶段实时更新断言 | **修观测回退，N20；D62③要求验证阶段与取消，不要求用宿主无法发布的 AX 后代**。没有改生产读屏标签，不把这个观测替换作为 VoiceOver 已通过的证据 |
| `SafeCleanupLayoutTests.testResizingDetailColumnKeepsScopeReadableAndShortPageScrollable` 未滚动就要求三范围卡都在 panel；短页可选外层滚到 footer | 在各范围卡滚入后执行同一 `panel.contains(card)`，新增完整可见区包含及操作／状态条完全固定；footer 使用最后稳定 frame | **按 D62②改契约**：选项在卡内滚动、主按钮贴底、底部状态条保留。仅改变滚动拥有者和检查时机；没有删掉包含、footer 可见或可读性断言 |

高窗 `testLandingCardUsesItsOptionsHeightWhenTheWindowGetsTaller` 不改原高度断言；只修宿主并加实际尺寸等待。`GeneratedArtTests` 不改任何旧断言。`testShortestLandingHasAnOverflowHintAndKeepsItsPinnedAction` 原提示位置／高度／主按钮可见断言保留，追加滚到底验证。14 功能一致性原按钮／插画误差全部保留。

新增两个定向测试：`testSparseLandingOptionsAreCenteredWithoutStretchingRowSpacing`，确认三个大窗稀疏区居中、智能扫描行间距仍为令牌 16 pt；`testNativeSweepTracksPublishedOcclusionWithoutChangingSystemSettings`，用只改自身报告值的测试 NSWindow，发布可见→完全遮挡→可见通知，确认停止／恢复及空闲不被通知重启。它没有写辅助功能或系统设置。

三个改动测试文件复核 D48／RULES 第 3 节：Store 仍经 `try ScanStore.makeForTests(for: self, …)` 构造；原有磁盘／历史夹具使用 TestFileSystem 所有权根；没有新增磁盘夹具、直接 Store init 或只读辅助环境写入。原宿主强持有及延后 teardown 保留。

### 15.4 定向验证与红／绿／反证

完整清单继续为 **38 类**，在 `prepared-r7/directed-tests.txt` 保留第 14.4 节的相同过滤表达式；本轮没有替换或减少页面既有、V0、语义、卫生、动画或资源测试类。以下由主会话在沙箱外执行，本轮均 **NOT RUN**：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug --jobs 4
SC_UI_V1_R7_FILTER=$(cat /Users/developer/Developer/.sc-build/r2-ui-v1/prepared-r7/directed-tests.txt)
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug --jobs 4 --filter "$SC_UI_V1_R7_FILTER"
```

| 项目 | 红证据 | 绿验证（主会话执行） | 反证（只在隔离导出副本） |
|---|---|---|---|
| 实际运行内容 | AXScrollArea 不发布阶段的基线抛错 | 原测试能读到实际阶段、阶段变更和取消能力；卡外可取消仍有原生 press | 改实际阶段视图／输入为错误文本或删实际布局节点，渲染／frame 检查应失败；去掉取消回调应使能力及原生 press 失败。不得只从预期生成探针来证明界面正确 |
| 最矮溢出提示 | 613×338 missing=`landing.scrollHint` | 提示在可见区底部、主按钮上方；滚至末项提示消失且按钮不动；588 张矩阵中的矮页仍可达 | 恢复旧坐标／零值覆盖或移除提示，原最矮断言应失败；禁用内部滚动，末项可见检查应失败 |
| 遮挡／首显动画 | GeneratedArt 第 106／109 行；此前首显 `Visible running layers turn` 回退 | 原 GeneratedArt、V0 动效和原生首显测试通过；新遮挡测试停止／恢复；隐藏、减弱及空闲仍静止 | 去掉已发布遮挡条件，新遮挡测试和源码守卫应失败；改成新窗口尚未发布时也无条件按空遮挡值停转，既有首显测试应失败 |
| 高窗、统一与稀疏构图 | 900／1100 高窗 528 对 694／894 | 请求尺寸和真实视口匹配；原 694／894、0.5 pt 断言通过；14 卡同高；稀疏区居中、16 pt 行距不变 | 在小屏导出副本恢复屏幕约束，实际尺寸等待／原高度断言应失败；任一卡槽错 1 pt 应触发一致性测试；恢复摊高行距应触发稀疏测试 |
| 短页完整可达 | 473×360／1072×360 原卡包含失败 | 三个范围卡逐项完整可见，原 panel 包含通过，动作／状态条 frame 完全固定 | 禁用内部滚动或夹断自然内容，应使对应卡可见区断言失败；让主按钮随内容移动，新增精确 frame 断言应失败 |
| 语义／V0／卫生 | 原基线契约，用户要求不能改 | 原三个语义类、两个 V0 类、TestPreferenceHygiene 和38类清单全部执行 | 不以布局探针替代语义测试；隔离副本恢复直接 Store init 时卫生守卫应失败，不在真实偏好域试验 |

Debug 起始／运行参数及固定数据接线继续使用第 13.6 节，无新参数。重点补拍最矮两个窗口的起始／运行滚动前后，高窗 900／1100 详情列、2400×1350 稀疏构图，以及实际窗口完全遮挡／恢复的运行录屏。截图不能验证遮挡 CPU 或真实 VoiceOver；这些仍由主会话用隔离进程／托管夹具复核。

### 15.5 交付、静态核对和剩余限制

`prepared-r7/` 基线 `85af09f`，顺序为 `01-layout-motion` → `02-render-probe` → `03-contracts-hosts` → `04-handoff`。包含各组 patch/message、`all.patch`、最终文件与产物 SHA-256、manifest、38 类过滤表达式、静态源码核对、JEV 原返回及仅供主会话验证后使用的提交助手。生成器只生成补丁和静态元数据，提交助手未执行，没有暂存或提交。

**PASS（仅静态）**：补丁 whitespace／反向应用检查、基线及文件边界、禁止改动文件逐字比对、Debug 探针隔离、原高度／动效／语义断言保留、工厂与所有权写法核对；记录在 `source-audit.json`、`static-checks.json`。这些检查不调用 Swift 编译器或 XCTest，也不代表原生布局结果。

**NOT RUN／剩余限制**：Debug PreferenceKey 的 Swift 6 编译／并发、宿主越屏高窗实际 frame、滚动测量及提示更新、真实窗口服务器遮挡首显时序、原生取消 AX 与 VoiceOver、38 类回归、588 张视觉复核及空闲 CPU 仍等主会话验证。R5 未验证的内存刷新录屏／近似计时／光晕性能边界继续保留。所有旧失败在交接中标记为“源码已处理、外部绿验收待执行”，没有声称已转绿。

本轮实际调用 JEV gate；工具元数据没有模型选择参数。自动审批拒绝该复核，返回 `MCP tool call requires approval, but approval policy is never`；没有执行模型复核或取得 JEV 判断，没有申请绕过限制。原返回见 `prepared-r7/jev-gate-result.json`。

## 16. 修订版 R8：视觉第二轮、D63 与反证交付

### 16.1 输入与边界

基线 `13f10c0d96dbd1a5bf2afa2f19d1ee2dcc68a08a`。此前被中止的旧 R8 没有 worktree 修改；本轮从干净基线开始。已读 D63、完整 `visual-review-2.md`、`key-r2/` 重点对照及测量脚本。报告被审对象为 `de8d3cf`，不能把它的像素数值当成 R8 输出。本轮以 D63 取代 D62 的外层卡片外观，保留 D62 几何、选项、默认值和动作。主会话确认的 R7「662 项、0 失败」是外部历史结果；R8 一律 NOT RUN。

`ScanStore.swift` 不变；内存采样／选择／退出确认、导航压力路径、预选、风险分层、执行／恢复、结果页与确认页的结构逻辑不变。主按钮与取消能力／动词仍来自各功能的现有操作。设置／小窗的结构与独立图表色不变。日间共享令牌按 D63 更新，影响它们的消费者色彩；不宣称 R8 已通过这些消费者的实图复核。

### 16.2 逐项处理与验证

| 项目 | 修复分类与产品处理 | 有区分力的验证／反证 |
|---|---|---|
| D63① 外层卡片与状态条 | **按 D63 改外观合同**。`FeatureLandingTemplate` 与 `FeatureRunningTemplate` 移除背板；`StatusFooter(isIntegrated: true)` 无填充／描边／阴影，只有顶部 0.5 pt 分隔线。选项格使用低透明度 hover 面和细线，三套日间都没有亮白大矩形。其他状态条消费者保留默认容器 | `testD63SourceKeepsTheColumnAndStatusOnTheCanvas` 的限定源码守卫＋`testD63ColumnsHaveNoBackplateAndLargeCompositionsAreCenteredAndBounded` 的真实 body 偏好／框检查；`backplate` 反证恢复背景后必须失败。偏好报告的是构造政策，不是独立像素证明，仍要实图检查 |
| 大窗构图与空白 | **按 D63① 改 R7 满高合同**。内容列最多 380 pt，三行 V0 范围的自然高度 200 pt，加 24 pt 翻译换行余量；列高仅取相同视口与共用 chrome，稀疏内容居中。页头与列组成左侧整体，同插画一起在状态行以上的可用区域居中，避免页头与构图分离。稀疏选项上下空带各 ≤80 pt，运行页也居中 | 大窗全功能／两态：实际列 ≤380.5、构图 midY 与可用区域 midY 差 ≤0.5、自然空带各 ≤80；`unbounded-column`、`top-aligned` 独立反证。SafeCleanup 高窗原公式／0.5 容差保留，新增独立 380.5 上限 |
| D63② 三套完整日间主题 | **按 D63② 改底色合同**。`AppDaylightTheme` 语义色板；晨雾蓝正式默认，另两套 case／参数／环境变量解析在 `#if DEBUG`。画布、侧栏、文字、分隔、内嵌控件、状态行和光晕统一。模块图标保留色相，按候选中最暗表面校准亮度，夜间及风险／图表语义不改 | `DayAppearanceTests` 新增全候选表面／叠加真实模块光源文字 ≥4.5、Debug 参数优先与默认、Release 单 case；原图标色相／夜间回退／白字动作对比度继续保留；`ivory-day`、`low-contrast-day` 反证。三套各 28 张待主会话拍，不宣称用户已选定 |
| R2-P1-2 提示误报／漏报／重叠 | **修回退**。旧 wrapper 居中用 minHeight，外层又有 2 pt 上下 padding；Debug 末项探针作为独立 VStack 子项还参与高度与间距。自然高度因此不是实际选项高度。删除未写入的 `featureOptionsHeight`，列表不自行撑高；在 centering frame 之前测量实际自然文档高度，每个滚动区使用独立字典键。末项探针改为覆盖层，不参与高度。与可用区比较仍用 0.5 pt，提示独占 24 pt 槽，内容明确裁切，滚到底时提示文字消失但槽保留 | 最矮智能扫描必须有提示且末项可滚入；820／1000／1280 三套日间与夜间无误提示；所有有溢出的短起始／运行页提示出现、在 viewport.maxY 之后、在 action.minY 之前，容差 ≤0.5。纯函数测 200 / 200.5 / 200.51 边界；`false-hint`、`missing-hint`、`overlapping-hint` 反证。源码定位已确认；实际 SDK 渲染测量将在主会话用 native host 和 capture JSON 完成，本会话不声称做过实测 |
| R2-P1-3 智能扫描起始页 | **修回退**。全族图标 48、标题 15、说明 13、行最小 56、自然行距 16 pt。原三级安全文案保留；1280 末行至主按钮 ≤48 pt。运行页三指标、分类进度及正式监视图继续沿用 R5–R7 | 原生图标宽高 48±0.5、行高 ≥56、间距原断言保留、末行空白 ≤48；`small-smart-scan` 反证。稀疏原 midY / 0.5 容差不变 |
| R2-P2-a 内存进程表被刷新遮挡 | **修回退**。保留已批准的全宽、无装饰插画的仪表盘变体；宽 ≥800 pt 时摘要与列表并列，窄窗用紧凑摘要在上。外层 dashboard slot 明确限制大小并裁切；应用和采样进程列表在剩余空间中各自滚动，提示独占槽，退出命令保持卡外固定，不修改采样或退出流程 | 原零选／部分选／全选 AX 命令和框断言继续执行；新增两种列表 maxY ≤刷新 minY+0.5、退出条同条件、剩余行提示及提示不重叠。`memory-unclipped` 恢复外层未裁切政策必须触发源码合同失败；实际遮挡还须截图。V0 `DesignSystemV2Tests` 内存行为、`DesignSystemV2ReviewTests` 全文件保留 |
| R2-P2-b 两态底边与状态行跳动 | **修回退**。Scaffold 两态统一 bottomPadding，不再运行态使用另一组窗口内边距。共同内容列上限与整体居中计算，不依赖选项或运行详情数量 | 14 功能 ×七尺寸同时托管两态，状态行全框相同，内容列与取消／主按钮 maxY 差 ≤0.5。`bottom-jump` 复原运行态额外 8 pt 后失败 |
| R2-P2-c 相似照片运行副标题 | **修回退**。正式 `DuplicateFilesRunningPage` 根据模式使用与相似照片起始页一致的中英安全说明；重复文件模式保留原副标题 | 托管正式运行页，实际 body 渲染探针检查两模式，相似说明与重复文件不同；`similar-subtitle` 复原重复文案后失败。只改文案，没有改变模式或扫描行为 |
| R2-P2-d 三页节点顺序 | **修回退**。四节点角度只改数组读取顺序为 TL / TR / BL / BR，安全清理、文件分析、性能共用其卡片目录；三节点位置不变 | 对三路由实际目录与四节点中心分别断言上下、左右阅读顺序；`clockwise-nodes` 复原顺时针顺序后失败。`nodeSide(for:)`、`nodeOrbitRadius`、几何声明与全部 native sweep 代码逐字保持基线 |
| R2-P2-e 未使用返回值警告 | **修回退**。截图导航用 `_ = withTransaction(...)`，其返回值不参与后续逻辑 | 限定源码检查显式丢弃返回值，`unused-return` 复原后失败；主会话再确认编译日志中该警告消失 |

### 16.3 模板、令牌、探针与 Debug 参数

原模板调用 API 保留。`FeatureRunningTemplate` 增加可选 `pageSubtitle`，现有调用跳过它不受影响；相似照片正式页面传自己的文案。`FeaturePageScaffold` 两态共享全部几何，其页头、列与插画一起居中。`StatusFooter`／`SurfaceCard` 增加默认 `false` 的 `isIntegrated`，只有明确调用者去容器；既有结果和其他页面仍用原结构。

主按钮原生槽 52 pt、绘制区 51±0.5、原生框容差 0.5、像素跨功能差 1 pt 均不变。取消槽 40 pt，图标／内边距／圆角沿用第 2 节令牌。新增列高上限 380；三行自然预算 200＋换行预算 24，正常／大窗最大实际列为 365／380，矮窗取较小可用高度。提示槽 24、三行图块 48／最小行高 56／行距 16、字体 15／13。运行稀疏文档也居中，仍只滚动内容，不动主动作或状态行。

Debug 真实渲染内容探针新增页面副标题、自然／分配／可见高度、提示政策，截图记录同树的 `LayoutFramePreferenceKey` 实际框，均在 `#if DEBUG`。没有更改 macOS 只读辅助功能环境；宿主仍保留 N20 卡外原生 AX 读取，不能把渲染探针视为 AX 后代证据。没有周期任务或偏好写入：只有已发生的 body 偏好改变才记录；运行 sweep／AppMotion／生成图加载与离屏合成余量不变。

参数：`--debug-daylight-theme=morning-mist|clean-white|light-aurora`，或 `STORAGE_CLEANER_DEBUG_DAYLIGHT_THEME`；参数优先，无效值回默认。其他 14 起始／运行演示参数继续采用第 13.6 节，截图时增加 `--capture-feature-templates --debug-feature-disable-layout-animations`。重复文件显式 `.all`，相似照片用既有 `--debug-feature-similar-photos`；原隔离域污染不影响演示入口。`prepared-r8/capture-daylight.py` 每套独立复制 Debug 包为 Integration 身份，以启动参数选择日间／中文，默认 1280×763 各 28 张；实际执行命令见 `DAYLIGHT-CAPTURE.md`。Release 只有晨雾蓝，不新增设置入口。

### 16.4 旧断言逐条变更依据

1. `DesignSystemV2Tests.testEverySurfaceSetKeepsReadableTextAndOpaqueReducedTransparencyCards`：日间 Spec 从 ivory 改为 morningMist；三个 RGB 断言分别从 `F0ECE2/F7F0E6/FBF7EF` 改为 `EDF3F9/E7EFF7/EDF3F9`，依据 D63②。日间卡面比画布亮的断言改为二者相等，依据 D63①。夜间抬升、文字 4.5／辅助 3、提高对比度描边、减少透明度和该类其余方法均逐字保留；新增候选文本合同为更严格的全部文字 ≥4.5。
2. `DaylightRefinementTests` 第一项：主画布与侧栏的暖色通道排序改为冷色排序，原 0.07 tint 上限不变；原“侧栏比画布亮 0.02”改为“比画布暗 0.02”，保留差值阈值，依据 D63② 的协调冷调侧栏。旧共享 panel／secondarySurface 的暖色、cardLift 0.06–0.16、选择色、图标色差／3:1 及夜间原色断言不变。第二项仅重命名日间主题，原亮度 <0.9、<0.98、4.5 对比度全部保留。
3. `SafeCleanupLayoutTests.testLandingCardUsesItsOptionsHeightWhenTheWindowGetsTaller`：R7 满高 694／894 等值不再是外观要求，依据 D63① 的有上限内容列。原精确 `metrics.compositionHeight(available:)`／0.5 容差和其余 6 个条件保留，只更新相应描述并新增独立 380.5 上限，避免只跟实现镜像比较。
4. `FeatureTemplateContractTests` 已有断言全部保留，新增主题／纯黑覆盖、运行插画一致性、独立提示槽和内存列表边界；没有删断言或放宽 0.5、52、40、44、16 等阈值。`ConceptLandingNativeLayoutRegressionTests` 只扩展同一宿主的偏好记录和稳定等待，不修改既有行为断言。
5. `GeneratedArtTests`、`DesignSystemV2ReviewTests`、语义类及卫生守卫整文件不变。内存起始的无插画例外继续沿用 R7 已通过合同，本轮不恢复会挤占列表的装饰插画。日间验收文件在本基线缺失，本轮新建 `docs/2.0.0/DAY_APPEARANCE_ACCEPTANCE.md`；旧图标文件保留历史验收结果并明确其暖色表已由 D63 取代，不将历史 PASS 写成新结果。

### 16.5 定向清单、红／绿／反证与交付

`prepared-r8/directed-tests.txt` 为完整过滤表达式：保留 R7 的 38 类，新增 `DaylightRefinementTests` 共 39 类，含 `UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`、`DesignSystemV2Tests`、`DesignSystemV2ReviewTests`、`ConceptLandingNativeLayoutRegressionTests`、`GeneratedArtTests`、`SafeCleanupLayoutTests`、`SafeCleanupScopeCardLayoutTests`、`StorageAnalysisScopeLayoutTests`、`HealthCapabilityLayoutTests`、`BenchmarkMonitorLayoutTests`、`RuntimeWorkflowPresentationTests` 及所有前轮页面／语义／性能／恢复合同。所有新增／修改测试继续经 `try ScanStore.makeForTests(for: self, …)`，偏好用 `TestPreferenceDomain.make(for: self)`，无新增真实文件夹具或临时目录写法。

红：在独立 R8 最终导出副本保留全部测试，使用 `counterproof.py --source <导出副本> --output <新的绝对目录>` 默认准备 14 个独立缺陷变体。变体只复原缺陷行为、保留新 API 与测试，避免整文件回滚造成编译失败假红。每个目标过滤方法写入 JSON。脚本拒绝 worktree、`.git`、已有目标、嵌套目标和越出副本的符号链接写入。

绿：主会话在沙箱外对完整 R8 源码编译、运行 39 类与卫生守卫，再拍七尺寸 ×深空／纯黑／三套日间候选。`measure-buttons.py` 的 `measure/refine` 逐字复制第二轮脚本，14/14 完整组、绘制高度 51±0.5、跨功能 x/y/宽/高差 ≤1 必须全过；真实 native 几何仍更严格地用 0.5。其余布局使用实际探针，不继续按已被删除的卡片边框计算空带。还有原 OCR 提示重叠 0、文字对比度、内存原生命令及截图复核。

反证：主会话对每个隔离变体用 `--run`，确认指定方法产生断言失败；源码编译错误或进程未启动不算红。14 个变体覆盖容器、列无上限、贴顶、误提示、漏提示、提示重叠、图标缩水、内存未裁切、底边 8 pt、相似说明、节点顺序、象牙白、低对比度、导航返回值警告。测试和反证脚本本轮均未执行；准备锚点／Python AST／哈希检查只能证明交付文件可解析。

补丁六组：日间令牌；无容器模板与构图；内存／相似照片；Debug 探针／截图；契约／宿主；交接与日间文档。`all.patch`、`manifest.json`、文件／产物 SHA-256、`commit-prepared.py`、源审计、三套截图脚本及反证脚本都在 `prepared-r8/`。全部组互有 API 依赖，先核验完整最终源码，再按组提交，不对半套源码声明编译通过。

### 16.6 未验证与 JEV

R8 Swift 编译、严格并发、测试目标、XCTest、反证、native frame／AX／VoiceOver、真实文字换行、截图、Release 候选符号消除、CPU、安装、提交都是 NOT RUN。主会话需复核 800 pt 内存摘要布局断点两侧、英文三行换行余量、生成图入场和所有底色下滚动提示位置；新背景最终取舍仍等待用户看三套实图。计时仍沿用 R5 的视图近似起点与已有真实起点优先规则，本轮不改采样口径。

实际调用了可用 `jev_gate` 工具（接口无模型覆盖参数），但自动审批拒绝：`MCP tool call requires approval, but approval policy is never`。未获得 JEV 模型判断，也未绕过审批；原返回在 `prepared-r8/jev-gate-result.json`。本轮静态核对和人工源码复核不能替代 JEV 或主会话验收。

## 17. R9：主会话第八轮结果与修复

### 17.1 输入、基线和证据口径

继续以 `13f10c0d96dbd1a5bf2afa2f19d1ee2dcc68a08a` 为基线。修改前逐文件 SHA-256 核对：worktree 与 `prepared-r8/manifest.json` 的最终源码一致；R8 文件及外部日志摘要保留在 scratch 的 `r9-inputs/`。`prepared-r9/` 提供相对基线的完整 R8＋R9 六组补丁，不能当作只需叠加在 R8 补丁上的增量。

主会话 `logs/main-r8-100057/build.log` 构建通过；`test.log` 总结为 684 项、跳过 1、110 处失败（其中 1 个抛错），对应五个失败方法，分布 56／45／6／2／1。本会话核对的是这些已提供的日志和失败附件，不是重新运行宿主；不能把源码推导写成已经实测 R9 的 frame。R9 未构建、类型检查、执行 XCTest／反证、启动应用、截图、测 CPU、安装、暂存或提交。

### 17.2 逐项根因、修改与红／绿／反证

| 主会话红证据 | 根因与修复分类 | 实现与不放宽的验证 | 隔离反证 |
|---|---|---|---|
| 56 次构图 midY=288，期望 455／605±0.5 | **修回退：绘制偏移和被测布局框分离**。R8 在 HStack 的 `.offset(y:)` 后挂背景探针，记录仍停留在原布局位置；附带更新来源 frame 显示子项已经偏移。不能只移动探针来制造通过，必须让构图真正参与布局 | `FeatureCompositionGeometry` 统一计算列高、插画边长、构图高、顶部留白和页头偏移；Scaffold 改为顶部固定布局留白＋真实 HStack＋剩余 Spacer，不再用 drawing offset。原居中 0.5、列上限 380.5、空白带 80 全部原值保留，新增构图包含真实页头／列／插画的 0.5 条件，避免测量框与子项分离。两态和所有功能共用同一计算 | `drawing-offset` 保留顶部视觉偏移却恢复未移动的布局；`top-aligned` 将真实顶部留白置零；原居中方法应出现断言失败 |
| 45 次 `header.maxY` 大于 `runtimeViewport.minY`，例 201.5>41 | **修观测回退，产品布局合同不改**。原 runtimeViewport 挂在包含页头的整个构图区域，不能代表页头下方的内容视口；这不是把空白上限放宽 | probe 移到实际运行列的固定 frame，与 runtimePanel 是同一布局边界；整体区域另名 runtime.compositionViewport。原 `SafeCleanupLayoutTests.testRuntimeStatesKeepPanelsAndLongPathsStableAcrossWindowSizes` 断言逐字不动。全功能运行合同新增二者 frame 相等、页头在列前、列在页尾前，误差仍 0.5 | `wrong-runtime-viewport` 恢复整体区域为旧 probe，同时保留 probe 存在；指定旧测试必须报几何断言失败，不能以缺失探针抛错充当反证 |
| 1084×338，三个选择数量共 6 次 overview/list 不在 options 内 | **修回退＋按 D63① 更新合同命名与语义**。宽窗始终使用完整摘要，矮窗口同一选项槽放不下；D63 去卡并没有允许图表或命令越出视口 | 宽≥800 的并排仪表盘，在实际可用高度<200时用已有紧凑摘要；横向容器明确按顶部及实际宽高布局。采样／应用两种列表、零选／部分选／全选、命令可见与原生 AX press 保留。旧 options.contains 的断言仍逐字保留，并加 contentColumn／实际 viewport 包含；列表至少44、列表／退出条在刷新之前、提示出现条件仍原值 | `wide-short-memory` 将宽窗摘要改回总是完整；`testMemoryDashboardKeepsOverviewListAndSelectionCommandsInsideTheContentColumn` 必须失败。未通过删列表、禁命令或放宽包含容差来解决 |
| preparing→results 页头60/92.5，footer maxY664/662 | **修回退：真实结果页还走旧 shell 锚点**。本方法也检查结果，不只是起始／运行。旧结果 shell 使用旧顶部／底部 padding，未沿用共用构图 | 仅智能扫描 overview 结果调用启用 `SmartScanPageShell(alignsWithFeatureFlow:)`；用同一纯几何与 LandingMetrics 给结果页头顶和底部锚点，保留原 footer 最小高度、结果表和所有动作。该流自行滚动，避免矮窗从模板的可见高度退回外层468pt最小高。原 Smart Scan 窗口稳定方法及1pt容差逐字保留，已有两态合同再增加页头 frame 0.5 条件 | `legacy-result-anchors` 仅关闭 overview flow flag，应在原 preparing／running／results 方法中失败；完整表和风险组动画源码继续存在 |
| Homebrew 原生 AX 缺失；第四来源超出可见区 | **修回退：行的空白预算过大**。四个生产来源行原自然高306，分配225且提示占24，第四行487.5–559.5越过可见下边454.5；原宿主 ScrollView 不发布被裁内容 | 仅更新来源列表改用 `FeatureOptionCard(padding: 0)`，保留48pt图标、标题／描述、四来源顺序与动作；其他图块默认 padding=12不变。四行210pt适合普通视口，极矮窗口仍按实际高度滚动并提示。原英文／中文四来源、原生 AX、按压与回调数覆盖保留；在同一尺寸扫测里新增全部行属于真实 optionsViewport、无溢出／无错误提示断言 | `padded-update-sources` 恢复来源12pt内边距，几何断言须失败；不能把读屏标签断言改成仅查源码／仅查渲染探针 |

R8 的 `featureOptionsHeight` 删除、自然渲染高度、24pt独立提示槽、48pt图标、主按钮／取消一致性、无外层背板、三套日间语义色板、相似照片说明与节点顺序继续保留。全功能自然尺寸和主按钮同框等值仍按原阈值，未回退到满高列。

### 17.3 五行 warning 的核对

日志五个 `warning:` 输出对应三个不同诊断，其中编译器的两项各重复输出一次：

1. `SafeCleanupLayoutTests` 原 line279 未使用 `viewport`：改为 `_ = try frame(...)`，仍执行探针存在／类型检查，未删验证步骤。
2. `BrowserPrivacyRecoveryTests` 原 line467：无抛错调用的 async `withAppLanguage` 闭包移除多余 `try`；保留 `await`、外层 throws、所有恢复文案断言及 TestFileSystem 所有权根。该行在基线已存在，不为了避免 warning 把恢复合同改弱。
3. `--skip-update` 废弃警告属于外部 SwiftPM 命令行，非 Swift 源码诊断。本交付所有建议 build/test 命令都不含该旗标；主会话清理实际验证命令后再确认日志。没有修改外部脚本或声称本会话已得到零 warning 构建。

`check-build-warnings.py` 只读主会话提供的新日志，拒绝出现任一 warning。warning 反证由 `counterproof.py` 的 `unused-viewport-warning`／`redundant-try-warning` 两个独立副本在主会话执行：原目标测试需要正常完成并确实出现指定 compiler warning，编译失败和 XCTest 失败不算警告反证。`--skip-update` 的反证是主会话原已保存的命令行日志；不需在沙箱重复编译。

### 17.4 旧断言、范围例外与卫生

唯一按新决定更新的已有契约标识：`testMemoryDashboardKeepsOverviewListAndSelectionCommandsInsideTheCard` 改名为 `…InsideTheContentColumn`，依据 **D63①取消卡片容器**。旧“在卡内”对应的 options 包含断言没有删除／放宽，新增内容列和页面包含，并保留刷新不遮挡列表与退出命令的条件。不是把 D63 当作允许裁切的理由。

居中期望455／605±0.5、所有45处运行几何、Smart Scan 1pt稳定、Homebrew实际AX和其他三来源、按钮52pt原生／51±0.5绘制区、取消40、图标48、所有对比度均不放宽。R8 的 D63 日间与列高旧期望修改依据继续见16.4；R9不再次更改它们。

必要的范围例外：`CleanupScanViews.swift` 仅 overview 结果页 shell 调用增加 flag，以满足已存在的运行→结果窗口稳定合同和 D62②的过渡连续性。该文件其他字节逐字等于基线，风险组入场护栏、结果条目、选择、确认、执行与恢复未改。`SmartScanPageShell` 的其他消费者默认 flag=false，继续旧布局。实际结果页短窗滚动与1pt锚点还需主会话验收。

`ScanStore.swift`、生成图加载、轨道几何 actor 声明及 native sweep、AppMotion、DataVisuals、FeatureRunningPages、Energy phase extension、V0 Review／GeneratedArt 和语义／卫生测试整文件保持基线。新增／改动测试经 `try ScanStore.makeForTests(for: self, …)` 或既有测试工厂；本轮没有新增磁盘夹具、偏好域、辅助功能系统环境写入或 Store 直接初始化。Browser 恢复类现有拥有根与所有断言保留。

### 17.5 交付、完整定向与反证

六组仍按：主题令牌；模板与画布；内存／运行／overview结果过渡；Debug截图；契约与宿主；交接与日间验收。共25个最终源码／测试／文档文件，全部相对13f10c0。`prepared-r9/` 包含分组patch/message、all.patch、最终源码和产物SHA、manifest、`commit-prepared.py`、40类定向清单、静态审计、反证及三套日间截图／第二轮同口径按钮测量工具。旧 prepared-r8 不改写，不能用其文件哈希对新 worktree 提交。

完整定向为 **40类**：R8的39类逐个保留，追加本轮消警告触及的 `BrowserPrivacyRecoveryTests`。包含 UIConsistency、TestPreferenceHygiene、DesignSystemV2、DesignSystemV2Review、ConceptLandingNativeLayoutRegression、GeneratedArt、全部修改页面的原有布局／语义／恢复合同。可复制主会话命令：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug-r9 --jobs 4
SC_UI_V1_R9_FILTER=$(cat /Users/developer/Developer/.sc-build/r2-ui-v1/prepared-r9/directed-tests.txt)
env -u STORAGE_CLEANER_DEBUG_DAYLIGHT_THEME swift test \
  --scratch-path /Users/developer/Developer/.sc-build/r2-ui-v1/debug-r9 --jobs 4 --filter "$SC_UI_V1_R9_FILTER"
python3 /Users/developer/Developer/.sc-build/r2-ui-v1/prepared-r9/check-build-warnings.py /主会话新日志路径/build.log
```

红：已保存外部R8日志与五失败方法计数。绿：对完整最终源码先编译和40类，再原生 frame／AX／视觉；不是只运行新断言。反证脚本共 **21个变体：19个几何／合同断言反证＋2个warning反证**，含R8全部14项和本轮五项几何根因。默认仅在新的、无.git、SHA匹配的导出副本准备；主会话用新的绝对目录加 `--run` 才实际执行。断言变体须命中指定方法的 XCTAssert 失败，警告变体须目标测试完成且匹配指定诊断，编译错误不算反证。实际准备／执行均NOT RUN。

日间候选参数和14功能入口不变，截图说明见 `prepared-r9/DAYLIGHT-CAPTURE.md`。三候选各28张基准图后，继续七尺寸×三候选／深空／纯黑、最矮窗口提示不重叠、内存命令与列表、结果过渡锚点。`measure-buttons.py` 的 measure/refine 与第二轮原脚本逐字同算法；跨功能像素差≤1、绘制高51±0.5、native误差≤0.5继续验收。

### 17.6 当前验证与限制

本会话只做静态交付检查：基线／空暂存区、输入哈希、保留断言、受保护文件／区段字节比较、Python AST、反证唯一锚点、补丁 whitespace和反向应用。详见 source-audit.json／static-checks.json；它们不证明 Swift 6 编译、原生布局或视觉通过。

R9未解决的验收项是外部40类、21反证、新build零warning、布局实际居中／真实child包含、wide-short内存、Homebrew原生AX、overview结果短窗滚动、完整视觉／CPU／Release候选符号及用户最终日间主题选择。源码已按反馈处理，外部验收待执行。本轮实际调用 JEV gate（工具接口没有模型选择参数），自动审批拒绝源码复核，返回 `MCP tool call requires approval, but approval policy is never`。没有获得 JEV 模型判断，也没有绕过限制；原返回保存为 `prepared-r9/jev-gate-result.json`，不能把静态核对或历史结果写成 JEV 已通过。

### 17.7 R10 输入、权限和证据口径

基线为 **a2f87ca7f47a80bb04bbabe3c8cad44e8ac1751f**，分支 task/r2-ui-v1；入场 worktree 干净。R9 已由主会话提交，R10 的 prepared-r10 是相对这个基线的增量，不能与 R8/R9 的累计补丁再叠加。主会话提供的 R9 验证为 build 通过、Swift 源码零 warning、39 类715项、跳过1、8处失败；本会话读取对应日志，原始失败摘要与 SHA 在 external-r9-validation.json。

本轮明确拥有 ScanStore.swift，新增范围只读扫描；仍不改清理风险、预选、确认、执行与恢复规则。D63 已由用户选定晨雾蓝，另两候选及 Debug 切换删除。D64 的 D0 范围为14功能起始／运行、共用页头／按钮／状态行／轨道；结果页因共用页头变为纯标题属于预期，不实施 D1–D6 的其他减字工作。

根因定位口径：下面依据外部实际失败 frame／缺失ID，加本地源码及布局机制核对。没有在沙箱重新实测宿主、编译、类型检查、跑 XCTest／反证、启动应用、截图、测CPU、安装、暂存或提交；静态证据不能冒充本轮绿结果。

### 17.8 R10 两项回退修复、D63收尾与D64呈现

| 项目 | 根因／实施 | 保留或新增验证 | 反证变体 |
|---|---|---|---|
| 7处 memory 两态页头宽不等 | **修回退**：仪表盘 panel 的全宽需求被同时用于 header，运行页仍使用普通 actionWidth。Scaffold 将 header 显式约束为同一 metrics.actionWidth×headerHeight，仪表盘仅扩展数据区，不缩放文字 | 原 testLandingAndRunningKeepIdenticalBottomSlotsAcrossAllSevenSizes 原值0.5保留，七尺寸、所有14功能均查页头完整frame及底部槽 | memory-header-width |
| protected 风险探针等待失败 | **修回退**：fallback LazyVGrid 在窄／矮结果视口下可延迟第三组布局，等待要求的是全部三组。只把三组 fallback 换成 eager AdaptiveCardGrid；前两个 ViewThatFits 排列、风险内容及动画护栏保留 | 原 testSmartScanOneButtonIdleAndActivePagesKeepWindowStable 不改期望或等待容差。原 missing-ID 报告继续生效；仍需主会话验证这项机制修复实际消除失败 | lazy-protected-risk；须命中 protected ID 的原生等待错误，不能编译失败充当红 |
| D63唯一主题 | AppDaylightTheme 仅 morningMist；删除 cleanWhite/lightAurora、参数／环境解析、环境候选光源字段、画布候选分支、截图 daylightTheme 元数据。晨雾蓝现有颜色值不变 | 单成员枚举＋固定RGB＋源码无切换守卫；逐语义文字、实际背景和每模块光晕4.5对比度原阈值保留。两个日间验收文件更新，历史证据明确标为历史 | candidate-theme／ivory-day／low-contrast-day |
| D64①卫星全删 | OrbitLandingArtwork 删除 Node、节点标签、nodeView与旧节点几何／目录，保留中央 GeneratedArt／GlossyOrb、轨道、星点、光晕及合成余量；同一方形槽和原native sweep不改 | 中心／轨道边界0.01、无节点声明／渲染守卫、中央资源映射及原不可见／空闲／减弱动态效果测试 | satellite-return；实际恢复渲染节点，不能只在未用目录写入文字 |
| D64②页头／区块／状态／主按钮装饰全删 | PageHero 和 AppPageHeader 纯标题＋真实actions，删除存储副标题／图片；模板区块标题普通标签、StatusFooter纯状态＋一行安全提示。PrimaryActionLabel和模板刷新／开始按钮为居中文本，GradientButtonStyle的Label使用titleOnly。运行阶段小状态标题、文件夹／时钟、绿盾等装饰删除；真实进度、失败／警告／锁及勾选／展开符号保留 | D64共享源码守卫；14×7 native actionText中心与button中心误差≤0.5，按钮高度52±0.5原生／51±0.5绘制；旧取消槽40、插画槽、两态底边与状态条原断言保留 | header-glyph／primary-glyph／button-label-icons／section-glyph／footer-shield |
| D64③副标题与描述 | 删除整个 ReviewFilter.pageSubtitle；所有引用迁移。选项描述不渲染，保留实际数据、未知能力／不可用状态和一行安全文案；相似照片用自己的中英文安全提示。PageHero/AppPageHeader/FeatureLandingTemplate等仅保留忽略的旧调用参数标签以兼容并行消费者，不存储／渲染这些描述 | 无描述／副标题守卫；相似和重复两模式×中英文渲染输入安全行分别断言；正文对比度、实际字体／标题可达性保留 | subtitle-property／option-description；相似照片安全行仍由原方法覆盖 |
| D64⑤删除后构图 | 不改共同居中计算、380上限、按钮／取消位置或真实溢出判定。健康非legacy分支由短横排三格改为共同列表行，避免删图后自然高过小，保留“内置电池待确认”。删除约900行未使用旧 FileToolLandingArtwork，只保留实际选项目录与在用 Terminal 流 | 大窗真实构图midY≤0.5、自然空白上下各≤80、智能扫描最后行到按钮≤48、48图标／56行高、提示24且不覆盖、内存数据／列表结束于刷新前的旧覆盖继续 | sparse-health-row；另保留 unbounded-column／top-aligned／false-hint／missing-hint／overlapping-hint／small-smart-scan／memory-unclipped／bottom-jump 等旧反证 |

日间选项控件继续共用浅蓝灰 inset 和细边，无大白色背板；保留可点击选项识别图标。安全清理四类可勾选图标配色及差异0.04、可读性4.6等既有阈值不改。主按钮位置由原共同几何决定，不因为无图标而换到其他位置。起始页不增加计时器或循环动画；运行计时仍是已有真实起点优先、否则视图首次运行起点的近似值。

### 17.9 D64④真实扫描范围、API及组合

新增 SmartScanScope 三项（cleanupCandidates/filesToReview/health），偏好key `smart-scan.selected-scopes`。缺失偏好默认全选；明确保存[]保留空选，不能悄悄恢复全选。旧／未知值只识别现存枚举。点击 SmartScanScopeButton 调用 Store.toggleSmartScanScope，扫描／权限准备／执行期间不变更捕获范围。主按钮全空禁用，两个扫描入口也在读取权限准备或启动任务之前拒绝全空。

范围按既有行的含义划分，**不是按风险分档重分组**：downloads/mail/applications 规则为“需确认文件”，其他现有规则为“可清理垃圾”。因此近期开发缓存仍在垃圾范围，保持它原有高风险、双重确认与不预选规则；废纸篓原独立确认不变。两文件范围合起来恰为原全规则集合，默认全选没有缩减默认文件扫描与默认清理预选。

| 垃圾 | 需确认文件 | 健康 | 实际任务及结果 |
|---|---|---|---|
| 0 | 0 | 0 | 按钮禁用；Store无任务、无权限准备、无文件／健康操作 |
| 1 | 0 | 0 | 仅非downloads/mail/applications规则；无健康数据 |
| 0 | 1 | 0 | 仅downloads/mail/applications规则；无健康数据 |
| 1 | 1 | 0 | 原完整文件规则；不运行磁盘／电池健康探测 |
| 0 | 0 | 1 | 不调用文件扫描器；仅健康读操作，文件分类／计数／候选bytes为0 |
| 1 | 0 | 1 | 垃圾规则后健康读操作；结果只有该文件范围与真实健康证据 |
| 0 | 1 | 1 | 需确认规则后健康读操作；结果只有该文件范围与真实健康证据 |
| 1 | 1 | 1 | 原全文件规则后健康读操作；全量文件扫描历史口径保留 |

Store 在既有 mainScan lease 内运行 SmartScanReadOperation。选一文件范围时 request.includedCategoryIDs/includedRuleIDs 均实际过滤；选两文件范围保持原nil全量请求。健康为一个独立进度组，保留已完成文件组、发现数和bytes，强制发布健康阶段，避免节流掩盖短阶段。未勾健康不调用 health closure；勾健康调用既有只读 DefaultComputerHealthProbe（磁盘、容量、备份／稳定性、电池证据），不调用任何调整电源／风扇／清理接口。这里的“不做磁盘健康检查”不等于文件扫描不读取文件系统容量元数据。

ScanSession 新增可选 smartScanScopes/smartScanHealthSnapshot，init默认nil兼容已有构造；mappingCandidates 保留元数据。范围标记的会话明确路由 overview，不混入安全清理；健康单选显示实际健康结果，混合扫描把健康证据加在本会话结果前。健康信息不可用不报健康；失败保留文件结果并标partial，文件取消不开始健康，健康取消保留已完成文件并遵守原 cancelled 预选策略。子集不记成完整扫描历史。

Legacy诊断全选保留旧文件扫描结果格式与调用，追加只读健康；子集转规则扫描，防止旧磁盘扫描器越过选择范围。Legacy健康读失败也保留完成的文件结果并提示不可用，单独测试保护；子集完成后回到Legacy全选时清除旧范围会话，避免旧结果遮住新结果。正式 productDefault=v2Full、截图与新范围组合合同都使用生产规则路径；没有重做 Legacy 诊断结果页。主会话应检查旧 Legacy 诊断合同仍过。

测试 API：ScanStore.makeForTests 新增 `smartScanHealthOperation` 注入，默认nil且不接触真实健康设备。Fake扫描器使用生产 scopedRuleSet处理实际request，记录执行规则、分类、计数与bytes；健康假操作分别记录磁盘／电池调用。SmartScanScopeTests 八个方法覆盖七非空组合、全空偏好与真实起始按钮AX禁用、分区完整／不按风险、健康失败与文件取消、健康阶段组数／冻结范围、实际取消、UI真实toggle及Debug演示默认、Legacy失败不丢文件。

测试均经 makeForTests/TestOperationFactory；目录只用 TestFileSystem.makeOperationHome，未创建真实候选文件；偏好用 TestPreferenceDomain.make(for:self)，Store工厂登记任务排空与根清理。演示只在DEBUG明确选择默认全选，且不覆盖用户保存的范围；重复文件演示继续显式all／相似照片参数，截图禁布局动画。

### 17.10 旧断言逐条改写依据（不删测试，不放宽阈值）

| 原合同／原断言 | R10改写与决定依据 | 保留的实质 |
|---|---|---|
| DayAppearanceTests 的候选枚举／解析、候选光源 | D63最终用户选择：只允许morningMist、精确RGB、无解析器／参数／环境／候选光源符号。每主题循环现在只走正式色板，去掉已经删除的两种候选光源组合 | 正文与每模块实际光晕复合4.5，所有底色、对比度/系统主题守卫 |
| GeneratedArtTests.testPicturesAreDecorativeAndOnlyOnTheAgreedSurfaces 原页头 GeneratedArt | D64②页头大图删除，改为页头无GeneratedArt/IconTile而有Text标题；中央装饰性图、允许表面、加载／发布／解码／资产合同保留 | 中央插画及其AX装饰属性、资源可用性 |
| DesignSystemV2ReviewTests.testReduceMotionKeepsGeometryAtRest entranceScale调用5 | D64①删除卫星入场，变4；每个剩余入场仍经AppMotion、减弱动态护栏 | 原所有动态／静止／可见性要求 |
| ReviewTests.testOrbitDrawingKeepsNodesAndLabelsInsideItsSquare 原3/4节点及标签边界 | D64①全部卫星/标签删除，改为每side220–600中心0.01、轨道包含与无节点／标签源守卫，并保留padding合成余量 | 同一方形槽边界、无裁切、中央mark／halo／轨道；不把字图缩小遮问题 |
| FeatureTemplateContractTests.testD63SourceKeepsTheColumnAndStatusOnTheCanvas 原13pt描述存在 | D64③描述删除，改成无Text(detail)；15pt标题仍正向守卫 | 无容器、状态一体、数据可读性、内存／布局合同 |
| FeatureTemplateContractTests 相似照片副标题方法 | D64③整个副标题属性删除，改测两语言×两模式各自安全行；方法保留，新增输入探针承载safetyText | 相似候选须人工确认、不会自动清理；重复模式须确认移废纸篓 |
| FeatureTemplateContractTests 原4节点阅读顺序 | D64①取消全部节点，改为无节点、中央精确居中及三个原路由中央资源映射 | 所有页面同插画槽与中央图保留；不存在再需排序的卫星 |
| HealthCapabilityLayoutTests assessment subtitle | D64③改验证实际系统健康标题；不能引用已删pageSubtitle | 两语言准确标题、原生能力而非猜电池硬件 |
| HealthCapabilityLayoutTests icon/detail正向几何 | D64②③静态图标／描述删除，逐项断言对应frame不存在；标题仍被真实card包含，未知电池另有真实warning frame包含 | 266/404等断点、所有标题和真正不可用提示、无假电池数据、无覆盖 |
| ConceptLandingNativeLayoutRegressionTests 六能耗步骤的overview描述AX／段落几何 | D64③逐步断言描述不出现；保留全部六真实标题、状态／当前步、progress值、原生字体完整尺寸及每行间隔≥6 | 中英六步骤、重排／不覆盖／完整标题、真实步骤反馈。不是删掉步骤或只查源码 |
| ConceptLanding… 原测试传ReviewFilter.pageSubtitle | D64③传空的兼容参数，不读取已删属性；相关标题和所有动作／AX合同不变 | 尤其Homebrew等四真实来源和回调数原断言不改 |
| SafeCleanupLayoutTests.testGoldenLandingKeepsRealControlsAndArtworkSeparateAtEverySupportedSize 原静态scope icon | D64②改为icon frame不存在，标题具有正尺寸并被card包含；所有控制、插画、页脚边界断言保留 | 实际可达控制、无相交，原1pt容差不变 |
| SafeCleanupLayoutTests runtime header 原tileSide+padding | D64②大图删除，改验证同HeroForm的titleHeaderHeight；不会保留一个已不存在图块的最小高 | 标题完整、路径20、位置关系／空白41、窗口稳定不变 |
| UIConsistencyRegressionTests 健康subtitle、共用header AppSymbolIcon/role.pageFeature | D64②③反向断言subtitle/icon不再存在、纯Text标题正向守卫 | 设置等D1段原断言不改；导航／侧栏／页头仍集中实现 |
| StartupItemsDashboardContractTests pageSubtitle | D64③仅由存在改为不存在，所有管理页选择／执行分离断言不改 | 命令、导航压力与安全约束 |
| CompetitiveParityContractTests “垃圾清理＋健康体检”宣传描述 | D64③说明删除，改测实际三范围词及操作不调用隐私／性能入口；原不得声称隐私／性能工作的否定断言保留 | 不声称没做的工作，真实健康执行由新的全组合假操作合同证明 |

新增加D64源码／真实按钮文字中心合同；旧0.5几何、51±0.5像素、空白80／48、progress要素、取消40、滚动0.5判定及24槽、内存选择命令、对比度与所有清理语义阈值没有放宽。没有修改V0入场记忆、GeneratedArt发布、DataVisuals悬停或native sweep。

### 17.11 范围例外与并行合并说明

SmartCareComponents **仅AppPageHeader区段**改变，AppEmptyState/AppStateIconRing/SmartCareMetric及前后所有字节保持基线。ProtectionConceptComponents 仅HealthCheckScopeCards呈现改变，前面的PrivacyConceptArtwork原字节保留。AppMotion、DataVisuals、GeneratedArtView、设置／菜单小窗、首次启动／操作记录等D1–D6负责的文件不改。

两个机械D0引用迁移单独分组：ComputerHealthView.swift 与 StartupItemsDashboardView.swift 各删除一行旧 `subtitle: ReviewFilter….pageSubtitle` 参数。这是删除整个共用属性后保证这些消费者可编译的必要迁移，不改健康／登录项结果内容、命令、选择、确认或安全性；不能把这两行理解为已经完成D4减字批次。AppUpdates的两条同类调用点也仅移除旧属性引用，其独立结果描述和其他内容留给D5。

CleanupScanViews风险fallback为本轮明确指定回退；另增加SmartScanHealthResultsView只用于D64④本会话的已选择真实健康证据／健康单选结果。ContentView仅修范围结果路由与删旧页头引用，不实施D6其他减字。清理风险组动画与风险/选择/确认/执行/恢复内容不改；ScanSession重建保留选择元数据。旧未用FileToolLandingArtwork删除符合D64⑤死代码要求，在用Terminal流不移除。

### 17.12 交付、定向、红／绿／反证与截图

prepared-r10 含八组增量：正式日间色板；D64共用呈现；两个D0机械调用迁移；范围模型/只读操作/Store；各功能与健康结果接入；Debug截图探针；契约与工厂；交接／日间验收。包含all.patch、message、manifest最终文件SHA、commit-prepared.py、source-audit/static-checks、外部R9红证据、反证规格／脚本、52类清单、正式日间截图说明及两个测量脚本。

定向52类：前轮清单逐项保留，新增SmartScanScopeTests、SmartScanHistoryTests、CleanupRuleScannerTests、CleanupExecutionSafetyTests、CleanupSafetyTests、HeavyWorkCoordinatorTests、AppSymbolGeometryTests、CleanupDefaultSelectionPolicyTests、CleanupLogPreselectionTests、CleanupStoreFollowUpTests、CleanupHistoryServiceTests、CleanupWriteRecheckTests。完整逐类名和过滤表达式在directed-test-classes.txt/directed-tests.txt，包含UIConsistencyRegressionTests、TestPreferenceHygieneTests、DesignSystemV2Tests、DesignSystemV2ReviewTests、ConceptLandingNativeLayoutRegressionTests、GeneratedArtTests及每个触及页面既有布局／安全／契约类。

红：外部R9日志的七header宽差和protected缺失；D64正向旧图标／描述合同按决定表改写，不把合法新行为当回退。绿：主会话对完整最终源码运行README命令的build和52类／卫生守卫，并确认Swift源码零warning；之后正式晨雾蓝28基准图、七尺寸三底色及原生AX／VoiceOver、空闲CPU与不可见动画。只跑新方法不足以验收。

反证共 **42种：40个产品变体＋2个历史warning变体**，case与唯一源码锚点／目标方法在counterproof-spec.json。逐组恢复：memory-header-width、lazy-protected-risk；candidate-theme／ivory／低对比度；卫星／标题／主按钮／区块／页尾图标、选项描述／副标题；scope-leak、health-when-unchecked、empty-redefaults、empty-button-enabled、health-failure-misreported、cancelled-health-lost、empty-cleanup-selection、fixture-preference-leak、legacy-health-drops-files、legacy-session-shadows-result、empty-backend-start、sparse-health-row；另外保留前轮列高、实际居中、假/漏/重叠提示、图标缩水、内存裁切、两态跳变、viewport、结果锚点、真实更新来源等反证。默认仅在新导出副本准备；--run由主会话执行。除两个指定原生缺失ID变体外要求目标XCTAssert/XCTFail，编译失败或不相关抛错不算红；warning变体要求目标测试通过且有指定诊断。

正式日间脚本只晨雾蓝，参数不含候选开关。measure-buttons.py 的measure/refine逐字等于第二轮算法，继续跨14功能≤1pt、51±0.5；measure-rendered-frames.py查body发布真实frame，native≤0.5、文字中心、无背板、居中／上限、实际提示不覆盖、两态页头／状态／底边及内存列表不遮挡。命令见DAYLIGHT-CAPTURE.md。脚本只能记录证据，不替代截图人工复核或CPU验证。

### 17.13 R10 静态结果和待主会话验证

本会话执行的仅为：输入／基线读取、源字段与调用点核对、并行区段字节比对、测试卫生源码检查、定向类存在核对、Python AST、42组唯一反证锚点、measure/refine原算法比对、git diff --check及补丁反向应用检查。静态JSON逐项记录实际结果；没有执行任何Swift编译／解析器、XCTest、应用、反证变体或截图。

待验证：两个原失败真实宿主转绿；新增Swift 6严格并发／可选值调用编译；52类全过；所有七尺寸／三底色按钮51±0.5与原生0.5一致；D64删除后实际字／安全行可读；健康标题列表空白上限；内存零/部分/全选命令AX及列表；范围各组合和health取消／失败；旧清理确认与恢复；正式晨雾蓝视觉、中央插画光晕、Release候选／Debug入口符号、空闲CPU。Legacy诊断结果格式未重做，正式范围结果覆盖以productDefault规则流为准。

实际调用可用mcp__jev__jev_gate（接口没有模型覆盖参数），自动审批拒绝：`MCP tool call requires approval, but approval policy is never`。未获得JEV模型判断、未绕过限制；原返回在jev-gate-result.json。本会话没有把源码复核或历史build/test结果写为R10或JEV已通过。

## 18. 第十一轮：主会话第十轮结果与修复

### 18.1 输入、保留的修正与范围

基线仍为 `a2f87ca7f47a80bb04bbabe3c8cad44e8ac1751f`。本轮入口相对 `prepared-r10/manifest.json` 的最终文件 SHA 只有两个文件不同，已把入口 SHA 和文件副本留在 scratch 的 `r11-inputs/`；没有覆盖主会话修改。保留 `SystemUtilitiesView.swift` 能耗结果 `UtilityHeader(..., subtitle: nil, ...)` 和 `ConceptLandingNativeLayoutRegressionTests.swift` 的 internal `final class CalibrationLanguageScope`。`UtilityHeader` 的可选 subtitle 兼容参数继续保留，共用 `AppPageHeader` 不存储或绘制该副标题；不为机械移除参数扩展结果页范围。

外部日志为 `logs/main-r10-130434/build.log`、`test.log`，摘要 `r10-failures.txt`。日志确认为 build PASS、934 项、4 项跳过、9 处失败（1 unexpected）。`prepared-r11/external-r10-validation.json` 记录两份日志 SHA、九条失败行及主会话修正，摘要另原样保存。这是修正版 R10 的外部证据，不是本轮验证。

R11 相对入口只修改三个契约测试文件、原生测试宿主所在文件和本交接；生产源码保持主会话编译通过的入口版本（其中 `SystemUtilitiesView.swift` 与入口逐字相同）。不改扫描／清理／确认／恢复、UI 布局或动效。相对基线的分组补丁仍完整包含 R10 的 D63、D64 与真实范围扫描实施，不能叠加 `prepared-r10`。

### 18.2 安全口径：修正新增测试的误述

`FeatureTemplateContractTests.testSimilarPhotoRuntimeUsesItsOwnBilingualSubtitle` 的两处失败都发生在普通重复文件分支。产品正常分支是“只读扫描 · 保留原件，清理前确认”／“Read-only scan · Originals retained until cleanup is confirmed”；相似照片分支是“只读扫描 · 相似候选须人工确认，不会自动清理”／“Read-only scan · Review similar candidates; no automatic cleanup”。这两条产品安全行保留。

核对的真实链路：`DuplicateFilesStore.storageItems(from:)` 为未确认／相似候选设 `trashPaths: []`；`setSelected` 只允许完整 SHA-256 已确认副本、每组至少留一份、外接卷仅审阅；`SystemUtilitiesView` 清理菜单由 `!isSimilarPhotosRoute && !selectedItems.isEmpty` 门禁，仅普通重复文件可选择经确认的 `.quarantine` 或 `.trash` 计划。因此把普通运行态固定描述为“确认后移到废纸篓”会漏掉隔离区流程，把同一描述给相似照片则会虚构它的清理能力。

本轮只把新增测试的普通分支期望改回准确的原件保留／确认口径。中英两语言、两模式的四次真实 body 渲染安全行相等断言及相似／普通不相等断言都保留。方法名作为历史入口保持不变；D64③已经删除副标题，此测试实际读取安全行 PreferenceKey，不尝试读取滚动内容的 AX 树。语义证明继续包含未改的 `ItemListAndDuplicatePresentationTests.testSimilarImageCandidatesHaveTheirOwnFilterAndRemainUnconfirmed`、`testDuplicateSelectionKeepsOneCopyAndRejectsManualCandidates`、`testDuplicateCleanupConfirmationUsesOnlyPreflightReadyFrozenPaths`。

### 18.3 禁用按钮：修复测试宿主的原生发现路径

外部失败快照只到 `HostingScrollView → DocumentView`，整个页面下方无 SwiftUI 子元素，`hits=[]`。该调用没有传 `hitTestFrames`；共用按钮已有真实 `Button`、`Text(actionTitle)`、`.accessibilityLabel(actionTitle)` 与实际 `.disabled(...)`，没有 `.accessibilityHidden`。这是 N20 已记录的惯性宿主遍历限制；不能从缺失树直接断言产品隐藏了禁用按钮，也不能把 Debug 内容探针当作原生 AX 按钮证据。

`SmartScanScopeTests.testEmptySelectionPersistsDisablesTheRealStartButtonAndRunsNothing` 现在先用原布局探针等稳定，再把真实主按钮 frame 传给既有公开 `accessibilityHitTest` 发现路径。frame 只决定询问平台的位置，标签、AXButton 角色、press selector、启用状态、native frame 都来自平台实际对象。保留原来的禁用状态读回；增加中英文分别验证、native frame 可见／命中动作中心、同一页选一项后启用、再次全不选持久化及选择变更不触发扫描／磁盘／电池调用。真实生产按钮测试没有换成替身或只查源码。

宿主 `waitForAccessibility` 增加默认空的 `expectedEnabled`，与现有 label／value／role 一起等待实际状态。布尔 getter 经 `isAccessibilityEnabled` 能力检查后用 KVC `accessibilityEnabled` 读取，不把 BOOL getter 用 `NSObject.perform` 当对象调用。原 100×5 ms 等待预算、布局稳定条件、既有测试调用与缺失诊断保留；换状态时 resize 到同一尺寸以清掉之前保留的原生命中对象，不复用旧 AX 快照。没有伪造系统只读环境值或放宽时限。

### 18.4 六条旧源码断言逐条改写依据

| 外部 R10 失败位置／旧含义 | 分类与决定依据 | 新合同与保留覆盖 | 对应反证 |
|---|---|---|---|
| UIConsistency… `testEnergyImpactRequiresExplicitScanAndShowsRealPipeline:920` 要求 `Text(step.overview)` | 按 D64③改契约：选项说明小字删除 | 反向断言可见说明不存在；正向保留 `Text(step.shortTitle)`、每步 help；原六阶段、真实进度、显式测量、布局和安全动作守卫全部保留 | `energy-option-description-return` |
| `testGeneratedArtworkIsAllowListedForBrandSurfacesOnly:1877` 要求共用组件有 `AppSymbolIcon` | 按 D64①②改契约：页头装饰删除，中心插画保留 | 页头段禁止装饰／生成图片，保留 PageHero 与标题 AX trait；中央 Orbit 仍有 GeneratedArtView 且 decorative。原六资源 allow-list、设置 appMain、侧栏真实路由图标守卫不改 | `shared-header-decoration-return`，原 `satellite-return` |
| `testMainModulesUseGoldenSurface…:701` 要求独立 `case .startup:` | 按 D64③改契约：该独立分支原位于已删除的 pageSubtitle switch | 用实际 `ReviewFilter.startup.moduleTheme` 检查 performance 分组、pigment、immersive，不再靠说明文案分支间接证明主题映射；原主窗口底色与路由动效守卫不改 | `startup-wrong-theme` |
| 同方法 `:702` 要求独立 `case .updater:` | 按 D64③改契约，同上 | 实际 updater 的 applications 分组、pigment、immersive；原设置原生表面和文件分组守卫不改 | `updater-wrong-theme` |
| `testPageHeadersUseOneOuterPageGrid:1934` 要求旧 title/subtitle VStack 上的 literal `.fixedSize(horizontal: false, vertical: true)` | 按 D64③改契约：只剩 Text title，单行测量与可换行回退由 wrapsTitle 参数明确控制 | 锁 `.fixedSize(horizontal: !wrapsTitle, vertical: true)` 及 false／true 两真实 fit 路径、Text title、header trait；原 padding=24、单外层网格、无 lineLimit、无宽度硬编码和所有结果／设置消费者覆盖不改 | `header-loses-wrapped-fallback` |
| `testV2SmartScanShowsCleanupSelectionWithoutNavigatingAway:297` 整个 Overview 不许 AppPageHeader | 按 D64④改契约：真实健康单选没有清理选择结果，需要自有结果页头 | 健康单选恰有一个自有 header／shell／健康证据；含文件结果分支仍禁止第二个 header、仍 `.overview` 直接嵌入 CleanupScanResultsView；原不得 showCleanupReview／外接 selection binding 守卫不改 | `file-result-wrong-route`、`health-only-result-wrong-scope` |

这六条没有通过增加旧无用图标、虚构副标题分支或删除所有页头覆盖来转绿。新主题映射合同只给一个方法加 `@MainActor` 和 testable import，以实际调用现有 API；不改变其他类或产品隔离。

### 18.5 红、绿与反证交付

红证据为主会话修正版 R10 的九条失败及原生 DocumentView 快照。绿由主会话对 `prepared-r11` 的完整最终源码构建，并用 `directed-tests.txt` 的 52 类过滤式重跑（清单包含 TestPreferenceHygieneTests）；不得只跑被改方法。继续要求 Swift 源码零 warning、原 0.5 pt 几何／51±0.5 pt 绘制高、80／48 pt 空白上限、24 pt 独立提示槽、4.5:1 对比度、全部范围组合、清理安全与确认恢复合同。

`counterproof-spec.json` 为原 42 项加 11 项，共 53 项：新增两模式安全口径错误、开始按钮 AX 隐藏／错误标签、startup／updater 实际主题错误、能耗说明复现、页头图标复现、换行回退丢失、文件结果错误路由及健康分支错误范围。`empty-button-enabled` 原反证仍保留。每个变体仅改变一个产品位置，原测试文件保持字节相同（只有原两项 warning 反证例外）；编译失败不算红。

`counterproof.py` 新增仅针对已声明 `expected_native_error_labels` 的开始按钮 AX 变体，接受同一目标方法抛出的、明确含“开始扫描”／“Start Scan”的原生等待错误。其他普通等待抛错不算反证；原缺失 protected／滚动提示 ID 的两项例外保留。等待到错误启用状态也必须命中实际按钮标签，不能把任意 fixture 出错算成通过。默认只准备变体，`--run` 仅供沙箱外主会话；本轮没有准备或运行变体。

交付仍为八组：正式日间；共享呈现；两个 D0 机械迁移；智能范围与 Store；功能接入（含主会话 subtitle:nil）；Debug 截图；合同与测试工厂（含 internal CalibrationLanguageScope）；日间验收和交接。`all.patch`、各组 message、manifest SHA、commit-prepared.py、static-checks/source-audit、外部 R10 证据、52 类清单、53 项反证与正式晨雾蓝截图说明齐备。脚本命令详见 `prepared-r11/README.md`、`DAYLIGHT-CAPTURE.md`，均采用新的 r11 输出目录，不覆盖旧截图／日志。

### 18.6 验证边界

本会话只执行源码读取与核对、入口 SHA 比对、并行／安全区段保护检查、Python AST、反证锚点唯一性与 API 核对、定向类存在与工厂卫生检查、独立测量函数比对、diff 空白和补丁反向应用检查。均不等价于 Swift 编译、XCTest、AX 或实图通过。R11 的 build、测试、53 项反证、截图、VoiceOver、空闲 CPU、Release 检查和提交一律 NOT RUN，待主会话验证。

本轮实际调用 `mcp__jev__jev_gate` 的只读复核被自动审批拒绝：`MCP tool call requires approval, but approval policy is never`，原返回记录在 `jev-gate-result.json`。没有取得 JEV 模型判断，不标成 JEV PASS，也不绕过审批策略。


## 19. 第十二轮：智能扫描范围、当前页刷新与历史正确性

本节保留 R12 当时的实现与未运行记录；外部验证结果及刷新入口／回执生命周期修正见第 20 节，以 R13 最终源码为准。

### 19.1 输入、权限与边界

- 基线 `facd1cf4c3bf40c219b311ca85376dd64f861052`，分支 `task/r2-ui-v1`，接手时工作区／暂存区均为空。
- 已全文阅读 `~/.sc-build` 对应的实际报告路径 `~/Developer/.sc-build/r2-ui-v1/review/review-v1-r8-r11.md` 及 `review/evidence/ReviewProbeSmartScanTests.swift`、`merge-fix-hygiene.patch`。复核探针断言“旧问题存在”，不能直接当作修复测试；本轮另加正向行为测试。
- 主会话 R12 明确授权修扫描路由、刷新和历史，沿用 R10 的 `ScanStore.swift` 所有权。本轮只改逻辑；D67 光场布局、图标、颜色、动效、尺寸和截图脚本均未改。当前 worktree 的 DECISIONS 尚无 D67 行，以本轮用户指令为范围依据。
- 新口径已记在 `DECISIONS.md` 的“D64 补充（R12，10-08）”，取代 R10/R11 的“三项全选才写历史”和“健康失败使文件结果 partial”。不改规则集合、绿黄红分级、预选、确认、执行、恢复和真实写操作。

### 19.2 四项根因与修复

| 项目 | 根因 | 最终实现 | 关键正向测试 / 单点反证 |
|---|---|---|---|
| P1 未扫描却显示没有项目；含复核 P2-4 | 健康专扫的 `includedCategoryIDs == nil` 被解释成全量；文件页只看类别过滤，不看智能扫描的实际范围 | 健康专扫同时记录空类别集和空规则集。`ScanStore.cleanupSession(for:)` 对智能扫描会话按已完成的 `smartScanScopes` 判定：只有包含 `.cleanupCandidates`，安全清理／开发文件页才消费结果；健康专扫、文件审阅专扫都回到原起始页。勾选随后变化不能改写旧会话的覆盖范围 | `testCleanupPageRoutesUseCompletedCoverageRatherThanEmptyResultsOrNewCheckboxes` 托管实际 `CleanupWorkspaceView`，7 组合×2 路由，读真实分支的布局探针；`unscanned-page-uses-health-session` 把范围判断单点改为始终返回会话。另有 `health-only-claims-unscoped-files` 守住空集合语义 |
| P2-1 当前文件页 Cmd-R 污染智能扫描 | 菜单统一入口把文件页送进 legacy 主扫描，清了会话，未同步清其选择／流程 | 在修改主扫描状态前分派到功能自身入口：分析 → `startStorageAnalysis`，文件搬家 → `startScan`，应用搬家 → 原 `refreshInstalledApps`，重复文件 → `scanDuplicateFiles`。文件页不走主扫描权限预检，不清智能扫描会话、选择、dry-run 或流程。确实替换主扫描的 legacy 路径同步清会话、规则集、选择、计划任务、预检、回执展示与 workflow，防止旧状态悬空 | `testFileWorkspaceRefreshPreservesTheSmartScanSessionSelectionWorkflowAndHistory` 从 Cmd-R 的真实方法进入，三功能注入只读假扫描器、核对精确调用及原会话／选择／dry-run／流程／历史身份。`file-refresh-enters-main-scan` 只改变分派条件。原 legacy 测试增加非空选择和清空断言，`legacy-replacement-keeps-selection` 反证 |
| P2-2 文件扫描未更新历史 | 历史写入要求三项全选并且规则／类别不收窄，错误排除了用户选择的完整文件范围 | 任一文件范围的智能扫描完成且未取消即写历史；独立安全清理／开发文件扫描和健康专扫仍不作为智能文件扫描历史。新增可选 `smartScanScopes`、`smartScanHealthStatus` 并持久化；不勾健康为 `.notRequested`，中文“未做健康检查”、英文“Health check not performed”。历史读取和评分重算保留字段，旧记录缺字段保持未知 | `testEveryFileScopeWithoutHealthPersistsCoverageAndRefreshesHistoryStatus` 覆盖两个单选和双选，检查 persisted entry、提醒 `.current`、菜单摘要所用字节、无健康调用。`file-history-requires-health` 恢复健康门槛即红；另两条反证检查健康标记写入和重算覆盖保留 |
| P2-3 健康失败误称文件 partial / 安全边界并扣分 | catch 给文件 outcome 改成 `.partial`，把健康错误塞进文件 issues；历史据此扣完整性分 | `SmartScanHealthStatus` 独立表达未请求、完成、无信息、读取失败、取消。catch 只写 `.failed`，保留文件 outcome、issues、permissions 和 metrics；现有健康区块／健康专扫状态行显示“健康信息读取失败”。没有新增视觉容器。文件本身完整则不显示安全边界提示，也不扣完整性分；真实文件 partial／权限失败仍如实保留 | `testHealthReadFailureDoesNotDowngradeFileOutcomeHistoryScoreOrPermissionEvidence` 覆盖完整／部分／部分且拒绝权限，与同一文件证据的成功健康读取比较分数，检查原因中英、持久化、mapping、提醒。`health-failure-downgrades-files` 只加回 `.partial`；`health-failure-hides-cause` 只改原因 |

`CleanupWorkspaceView` 只是从 ContentView 提取现有生产分支，用于直接托管路由测试；原页头、内容、间距、状态条都未改变。Debug 新增 `cleanup.route.landing`、`cleanup.route.results` 几何探针，分别由实际渲染的分支上报，Release 无探针。测试不从有 N20 限制的滚动内容里读取 AX。

历史仍是原有 `scan.history` 数据源，没有新建历史系统或界面。具体范围和健康标记写在每条历史记录中；旧入口继续通过 `scanHistorySummary.latestStatus()` 与 `greenBytes` 取得已更新数据。本轮未给设置或菜单栏新增视觉元素。没有健康字段的旧记录不推测补填、不自动改旧分数；独立健康失败以后才不再扣文件完整性分。

### 19.3 测试注入、覆盖与旧断言逐条依据

- `ScanStore` 增加两个默认 nil 的依赖参数，将现有 LargeFilesStore 的 `storageMapTargets`、`storageAnalysisOperation` 透传；生产仍用原默认实现。测试入口仍只有 `ScanStore.makeForTests(for:)`，工厂透传相同参数，文件分析刷新不扫真实磁盘。
- 偏好仍为 `TestPreferenceDomain`，源路径与回执根用 `TestFileSystem.makeOperationHome` 所属根；无自行拼接唯一根或真实偏好写入。测试仅假扫描／读取结果／选择／生成 dry-run，不执行清理。刷新测试等到扫描和文件分析保护读取结束后才结束。
- 保留原 8 个 `SmartScanScopeTests` 方法，新增 5 个方法：页面路由、文件页刷新、文件范围历史、健康失败隔离、历史编码／重算兼容。所有已有布局容差和定向类保留。

| 旧断言 | 改写 | 依据与保留的含义 |
|---|---|---|
| `testEveryCheckboxCombination…`：`mask != 7` 都无历史 | 仅健康专扫无文件历史；另外六种含文件组合必须有历史，并校验具体范围、健康状态及非 limited | R12 P2-2 明确“一项或两项文件范围都写历史”，已补 DECISIONS。7 组合的实际规则、分类、数量、字节、健康调用和预选断言全部保留 |
| `testFailedHealthKeepsCompletedFileResultsAndCancelledFilesNeverStartHealth`：健康抛错后文件 `.partial` | 文件仍 `.complete`；取消仍 `.cancelled` | R12 P2-3。候选结果、健康调用次数、取消时不启动健康、nil 健康快照断言保留 |
| 同测试：把 `smart.health` 记进文件 issues | 文件 issues 不新增健康问题，独立状态为 `.failed`；取消为 `.cancelled` | R12 P2-3 要求原因真实、不得假称文件安全边界。新增完整／真实部分／权限受限三种文件证据对照，未取消真实文件问题 |
| `UIConsistencyRegressionTests.testV2SmartScanShowsCleanupSelectionWithoutNavigatingAway`：健康视图只传 snapshot 的源码字串 | snapshot 仍从原 session 读取，同时必须传 session 的 health status | 健康失败原因须在原区块真实显示；没有移除健康区块、路由、页头单一、禁止另页选清理等断言 |

定向清单 `prepared-r12/directed-test-classes.txt`：沿用 R11 的 52 类，再加 `IndependentFeatureWorkspaceStoreTests`、`HeavyWorkIntegrationTests`、`ScanReadinessServiceTests`，共 55 类；正则见 `directed-tests.txt`。按用户约束，本会话未执行这些测试。

### 19.4 红、绿与单点反证

- 红：复核报告与 `review/evidence/ReviewProbeSmartScanTests.swift` 是旧行为的外部证据，不将其“问题存在的 PASS”写成修复通过。新的正向测试守护相反行为。
- 绿：主会话在沙箱外先跑 `SmartScanScopeTests|SmartScanHistoryTests`，随后 `directed-tests.txt` 的 55 类及构建；必须记录数量、跳过、失败、exit code。本轮状态为 NOT RUN。
- 反证：`prepared-r12/counterproof-spec.json` 有 9 个独立缺陷，每个只替换一个生产代码锚点，不改测试、阈值或夹具。`counterproof.py` 要求独立无 `.git` 的最终源码导出副本，校验 manifest 哈希后才复制；默认只准备，主会话加 `--run` 才运行。仅目标方法的 XCTest 断言失败算 RED；编译失败、普通宿主超时和意外抛错不算反证。
- `history-rebalance-drops-coverage` 专门覆盖持久化读取后重新计算 score 的分支；`legacy-replacement-keeps-selection` 先留下真实非空选择，不能靠空集合获得假绿。
- 前十一轮视觉反证留在 `prepared-r11/`，本轮没有重跑，也不把报告指出的 overlapping-hint 缺口写成通过；D67 后续视觉重做接管该问题。

### 19.5 交付与静态核对

交付目录 `~/Developer/.sc-build/r2-ui-v1/prepared-r12/`，全部补丁相对 `facd1cf`，不要叠加 `prepared-r10/` 或 `prepared-r11/`。

1. `01-scan-evidence-history`：范围／健康状态模型、只读扫描结果、历史编码与重算。
2. `02-current-page-routing`：当前功能刷新、cleanup 页实际范围路由、现有健康区块的真实失败原因。
3. `03-contracts`：测试依赖注入、原范围测试口径更新、新增五项行为契约及源码接线守卫。
4. `04-handoff`：R12 决策补充、本节交接。

每组都有补丁、提交说明；`all.patch` 为总补丁。`manifest.json` 记录基线、分支、顺序与每个最终文件／产物 SHA-256。`commit-prepared.py` 只供主会话验证后按组提交，本会话未执行。`README.md` 包含构建、定向与独立反证命令。

静态核对结果以 `static-checks.json` 为准：只包括 `git diff --check`、空暂存区、补丁反向适用性、哈希／分组完整性、Python AST、反证锚点唯一性、测试方法保留及受保护源码片段比较；这些不是 Swift 编译或 XCTest 结果。

### 19.6 外部验证边界与合并注意

- R12 编译、Swift parser/typecheck、XCTest、反证执行、启动应用、截图、CPU、安装、提交均 NOT RUN。未对其编造通过状态。
- JEV 本轮尝试的是当前可用 `mcp__jev__jev_gate`，schema 无模型选择参数，未擅自指定或替换模型。自动审批返回 `MCP tool call requires approval, but approval policy is never`，因此没有取得判断；原始结果见 `jev-gate-result.json`。未绕过拒绝。
- 独立复核第 4 节的 hygiene-3 合并适配仍须主会话在并入集成分支时带上：`FeatureTemplateContractTests.makeFixture` 的 `ComputerHealthStore` 显式注入 `TestOperationFactory(for: self).batteryPowerModeController()`。本基线尚没有这个工厂方法，不能在本 worktree 直接套用那行而制造编译错误；报告副本已有 44 项外部通过证据，补丁位置为 `review/evidence/merge-fix-hygiene.patch`。本轮未改该测试或移植并行卫生批实现。
- 应用搬家刷新复用现有 `refreshInstalledApps()`；本轮行为测试执行文件搬家分支，未在沙箱或测试里运行真实应用库存读取。其余复核 P2-5～P2-11 与视觉／通用页头问题不在这四项逻辑修复内，保留给 D67／对应后续批次。

## 20. 第十三轮：清理完成后新扫描的生命周期回归

### 20.1 外部红证据与根因

基线仍为 `facd1cf`，接续未提交的 R12 源码。主会话报告 build 通过，定向 982 项、跳过 4、1 项失败；日志 `~/Developer/.sc-build/r2-ui-v1/logs/main-r12-183902/test.log` 第 509 行为 `CleanupStoreFollowUpTests.testDoneAfterAnotherScanStartedDoesNotReturnToTheResults` 抛出 `FixtureTimeout()`。该类 25 项中 1 失败；`SmartScanScopeTests` 的 13 项通过。单独复跑两次稳定复现来自主会话说明，不冒称本会话重新执行。

源码数据流确认这是入口分流造成的状态回归，不是十秒预算不足：

1. 原失败测试完成一次夹具清理，选择 `.largeFiles`，直接调用 `startScan()`。原 API 建立新 presentation token，进入注入的主扫描假操作；假操作抛错，因此等待 `.failed`。随后回执上的“完成”必须回到 `.idle`，不能返回旧扫描结果。
2. R12 把 `refreshFileWorkspaceIfSelected()` 放进了 `startScan()`，在 `beginScanPresentation` 之前提前返回。测试实际进入文件分析，主 presentation 保持 `.completed`，永远等不到 `.failed`。增加等待没有作用。
3. R12 还在 legacy 主扫描复位时清除了 `lastCleanReport`。只移开分流仍会破坏原测试下一条“回执仍在”的断言。清理回执是已完成操作的记录，不等于可继续执行的旧选择／计划。

原测试注释提到旧 Cmd-R 路径，但其可执行代码调用的是 `startScan()`。当前真实 Cmd-R 在 `StorageCleanerMacApp` 调用 `startScanRespectingAccessGuide()`。本轮按两个实际入口的职责修复，保留原测试完整方法及十秒等待 helper；没有改期望、加 sleep、延长超时或跳过覆盖。

### 20.2 最终实现与保留的 R12 行为

| 入口／状态 | 最终行为 | 依据 |
|---|---|---|
| 文件页 Cmd-R：`startScanRespectingAccessGuide()` | busy／清理执行 guard 通过后，直接调用当前文件功能的原刷新入口；不进入主扫描权限预检、不换智能扫描 token、不清会话／有效选择／dry-run／历史。三个文件功能和应用搬家原分派保持 | R12 P2-1；R13 不回退 |
| 显式新主扫描：`startScan()` | 恢复基线文件路由的 legacy 主扫描分支，建立新的 presentation token；不被“刷新当前文件页”的分流截走 | facd1cf 既有生命周期与本轮失败测试 |
| 主扫描确实替换旧扫描 | 继续清除旧 session、活动规则、选择、dry-run、计划任务、预检、workflow，并清除 `cleanupResultReturn`；保留已完成的 `lastCleanReport` 与已有 recovery 信息直到用户关闭 | 既保留 R12 状态一致性，也恢复旧回执生命周期 |
| 回执“完成” | `dismissV2CleanupReport()` 本轮零改动。显式新主扫描后，旧回执不可返回旧结果；仅刷新独立文件功能时，原清理 token 未变，仍可回到清理后剩余结果，选择为空 | 旧清理后续／安全契约 |

没有新增 UI 状态，没有改视觉、清理规则、预选、确认、执行、恢复或超时。R13 相对 R12 只改 `ScanStore.swift`、`CleanupStoreFollowUpTests.swift` 和本交接。R12 的范围证据、页面路由、历史写入和健康失败隔离代码及新增 13 项范围测试保持原样。

### 20.3 测试与单点反证

原 `CleanupStoreFollowUpTests` 的 25 个测试方法逐字保留，新增两项，各覆盖大文件／迁移／重复文件三路由：

- `testExplicitMainScanFromFileRoutesReplacesTheTokenButRetainsTheReceipt`：清理后调用显式主扫描，**等待之前**断言 `isScanning`、`.preparing`、新 token、正确 route、旧选择／计划／流程复位及回执同 ID；随后检查只有主假扫描被调用、失败不新增历史、“完成”回到 idle 且清理不可执行。这样分流回退由明确断言变红，不只剩普通超时。
- `testFilePageRefreshAfterCleanupKeepsTheReceiptBoundToItsOriginalResults`：同样的清理后状态改用真实 Cmd-R 方法，三种文件假读取分别抛错，精确核对只有当前功能被调用、主会话／回执／历史未变；“完成”仍能回到剩余结果，选择为空。R12 原刷新测试继续覆盖已有 results／非空选择／dry-run 下的成功刷新。

测试沿用 `ScanStore.makeForTests`、`TestOperationFactory` 和已登记的 `TestFileSystem.uniqueOperationRoot`。补入三个独立文件读取假操作与主扫描调用计数，错误分流也不再触及真实文件扫描；清理仍只使用已有夹具 Trash mover 和回执根。没有改产品安全校验。全部旧断言、旧方法和 `waitUntil(timeout: 10)` 保持不变，无需按 D62/D64 改契约。

反证保留 R12 九项并增加三项，共十二项：

| 单点变体 | 只改一处产品代码 | 预期目标失败 |
|---|---|---|
| `explicit-main-is-page-refresh` | 在 `startScan()` 的 route 赋值前重新插入文件刷新提前返回 | 新显式主扫描测试的同步 `isScanning`／`.preparing`／token 断言失败；不以旧测试十秒超时作反证 |
| `explicit-main-file-routes-use-rules` | 删除显式主扫描 guard 的文件路由 legacy 分支 | 主假扫描精确调用／`.failed`／回执 ID 断言失败 |
| `explicit-main-loses-cleanup-receipt` | 在 legacy 主扫描复位处重新清空 `lastCleanReport` | 相同回执 ID 的同步断言失败 |

`file-refresh-enters-main-scan` 原反证现在作用于命令入口中的唯一分流锚点，仍由 R12 的精确扫描调用／会话保留断言识别。每个反证只改一个生产文件中的一个唯一锚点；全部测试逐字不变。编译错误、普通超时或非目标抛错均不能算 RED。

### 20.4 交付与主会话验证

目录 `~/Developer/.sc-build/r2-ui-v1/prepared-r13/`，四组补丁及 `all.patch` 均相对 `facd1cf` 的最终累计源码，**不要叠加 R12 补丁**。分组：范围／历史；Store 与页面路由；测试；交接。共 14 个改动文件，`manifest.json` 记录最终文件／产物 SHA-256。保留原 R12 目录作为历史证据。

定向清单仍为 R12 的 55 类，含 `CleanupStoreFollowUpTests`、`SmartScanScopeTests`、全部原布局／安全／测试卫生守卫；没有为快速转绿缩减清单。建议主会话先构建，然后单独原失败方法，再跑 `CleanupStoreFollowUpTests|SmartScanScopeTests|SmartScanHistoryTests`，最后跑完整清单和十二项独立反证。确切命令见 `prepared-r13/README.md`。若测试发现新问题，须按失败定位，不把本节静态分析写成测试已绿。

`static-checks.json`、`source-audit.json`、`contract-coverage-audit.json`、`prior-validation.json` 分别记录静态检查、与 R12／基线的源码边界、旧断言保留、主会话旧失败日志哈希。反向补丁适用性、Python AST、锚点唯一、方法原文和超时原文比较可在沙箱静态执行；Swift 编译／类型检查、XCTest、反证运行、应用／截图、安装、暂存、提交均 **NOT RUN**。

JEV 本轮调用 `mcp__jev__jev_gate`（实际工具无模型选择参数）被自动审批拒绝：`MCP tool call requires approval, but approval policy is never`。没有获得 JEV 判断、没有绕过限制；返回见 `jev-gate-result.json`。§19.6 的 hygiene-3 合并注入事项仍留给主会话；本轮没有引入缺失的工厂 API。
