# 批次 3b 交接：主窗口与设置

- 实现：Claude（主会话）　复核：全新上下文的 Claude 子代理（只读）
- 分支：`task/batch3b-main-settings`，基于 `763fcd1`；首轮 6 个提交（`4ae00dc`…`0534e40`），复核后 2 个修复提交，另加本交接

## 改动

| # | 问题 | 改动 | 文件 |
|---|---|---|---|
| D3 | 侧栏选中统一蓝，页头与主按钮却按模块配色 | 选中行用该模块 `actionFill` 填充（深 26%/浅 14%）并描边；浅色选中图标保持模块色。锁定旧规则的源码契约测试按 D3 修改 | `Views/SidebarView.swift`、`Tests/.../SystemMonitorServiceTests.swift` |
| 设置 | 设置窗口与主窗口不是一套：行距大一倍、选中样式不同、列表外圈蓝色焦点框、孤立折叠按钮、版本号写法不同、标题出现两次 | 两个侧栏共用行背景组件 `SidebarRowBackground`（选中填充＋描边、悬停底色），设置行补悬停效果，浅色图标渲染方式与主侧栏一致；去掉整个列表的焦点框，行按钮在全键盘操作下仍有系统焦点环，列表获得焦点时选中描边加粗；去掉折叠按钮，侧栏被拖到折叠时自动恢复（“显示边栏”菜单只作用于主窗口）；两处侧栏共用 `SidebarVersionLabel`（完整版本与构建号在悬停提示，无版本信息时显示“开发构建”而不是旧版本号）；标题栏 `titleVisibility = .hidden` | `Views/SettingsView.swift`、`Views/SidebarView.swift`、`Tests/.../UIConsistencyRegressionTests.swift` |
| N3 | 应用更新页“本软件更新…”在卡片外单独一行或挤在角落 | 落地页页头新增可选操作（环境值 `landingHeaderAction`，落地页读取后对子视图清空，嵌套页面不会重复显示），空闲状态在任何窗口尺寸都放进页头 | `Views/FileToolLandingPage.swift`、`Features/AppUpdates/Views/AppUpdatesView.swift` |
| N5 | 结果页风险卡在 820 宽时数值被截成“至少 30.…” | 横排和自适应网格的卡片最小宽度都为 260（英文 “At least 30.5 GiB” 约需 253）；遵守既有规则，不缩放文字 | `Views/CleanupScanViews.swift` |
| 截断、N2 | 落地页选项列表在常见窗口尺寸被内层滚动区裁掉（智能扫描、安全清理、文件分析、开发工具、系统健康、卸载、迁移、应用更新） | 根因是中等宽度下操作列固定 340 pt：插图列只拿操作列剩余的宽度（插图列最窄 260，不够就不显示插图，操作列用满宽）；操作列最窄默认 400，开发工具 480、系统健康 470、应用更新 470（含页头按钮）。内容高 < 660 pt 用紧凑布局（`WindowLayoutMetrics.isCompactLanding`），落地页内的健康检查卡与能耗步骤也按同一阈值。迁移页紧凑布局下标签与控件同排、安全说明只留一行（详细说明在悬停提示和读屏提示中） | `Views/GoldenLandingArtwork.swift`、`Views/FileToolLandingPage.swift`、`Views/ModulePresentation.swift`、`Views/MainWorkspaceViews.swift`、`Views/LargeFilesView.swift`、`Views/ProtectionConceptComponents.swift`、`Views/EnergyImpactScanLandingView.swift` |
| 主按钮 | 各落地页主按钮高 66/68/72/80、图标栏 82/88/92，按图标名区分 | 统一 72/84，紧凑布局 54/64 | `Views/FileToolLandingPage.swift` |
| N2 图例 | 文件分析“分析范围”卡在短窗口裁掉文件类型一行 | 紧凑布局下类别图例为一行图标加文字，标签不折行；一行放不下时排成两行两列 | `Views/LargeFilesView.swift` |
| 页头 | 最窄宽度下“登录项与后台任务”标题折成两行 | 大页头横排时标题不换行，放不下才把操作移到标题下方；只按标题和操作判断（副标题不参与，照常换行）；没有操作的页头不预留操作行；横排时操作先于标题块取得宽度，不被长副标题挤压 | `Views/SmartCareComponents.swift`、`Views/FileToolLandingPage.swift` |
| 工具 | 设置窗口无法离屏截图；尺寸截图缺少中等宽度 | Debug/Beta 开关 `--capture-settings-window`：依次切换并截取每个设置分类，结束后写回原分类；找不到主窗口时直接退出（该开关混在 `358c93c` 提交里）。尺寸截图新增 1000×700、900×640 两档 | `Debug/MainWindowSnapshotPipeline.swift`、`Views/ContentView.swift`、`Views/SettingsView.swift` |

## 复核（全新上下文的 Claude 子代理）与处理

结论“需修改后合并”，无 P0。

- **P1-1 页头回退**（首轮 `0534e40` 引入）：大页头按“标题＋副标题单行宽＋操作”判断横排，没有操作时竖排里空操作区仍占 32＋8 pt；英文默认窗口（详情区 1083×712）下智能扫描、安全清理、开发工具、迁移、卸载、重复文件的页头由 124 变 164 pt，开发工具在 803×712 标题上沿超出页面。
  处理：`{ EmptyView() }` 页头不再有操作行；横排只按标题和操作判断（副标题理想宽度为 0，实际排版照常换行）；落地页无操作时用 `EmptyView` 页头。新尺寸扫描逐页检查“页头高度＝标题块高度＋上下边距”“标题不超出页面”“有页头操作时 803 宽以上不竖排”。
- **P1-2 截断只修了一部分**：报告点修好了，但文件分析、开发工具、系统健康、卸载、迁移、应用更新在常见宽度仍被截（早于本批）；原尺寸扫描只测两页，且用裸 `GeometryReader` 而不是真实容器。
  处理：按根因改操作列宽度规则（见上表），新增 `testEveryLandingPageFitsInTheRealPageContainerAcrossTheSizeSweep`：真实容器 `AdaptivePageViewport`、12 个落地页变体（含带页头操作的应用更新）、中英文、详情区宽 655/703/760/803/903/1000/1083 × 高 468/520/560/600/640/660/680/712/760。修复前该测试报出 100 余处截断与页头问题，修复后为 0。
- **P2 处理**：N5 网格最小宽度改 260；文件分析紧凑图例不折行；健康检查卡、能耗步骤改用落地页阈值；设置侧栏共用行背景、补悬停与焦点提示、浅色渲染方式一致、侧栏不能被折叠到无法恢复；`landingHeaderAction` 不再传给嵌套页面；`SafeCleanupLayoutTests` 补紧凑高度组；设置截图找不到主窗口时退出；版本号不再回退到旧值。
- **P2 未改**：设置侧栏图标槽 22 pt（主侧栏 18 pt）——`AppSymbolGeometryTests.testSettingsNavigationUsesSameVisibleGlyphWithoutChangingItsSlot` 锁定“可见图形相同、槽位不同”，属既有审定设计；设置侧栏选中色用窗口自身的主题色（设置分类不是模块），见下方 D3 补充。

## 改动的既有测试（逐条说明）

- `SystemMonitorServiceTests`（侧栏选中规则）、`UIConsistencyRegressionTests`（设置选中样式原锁定 `AppAppearanceColors.selectedSurface`）：按 D3 及其补充修改。
- `SafeCleanupLayoutTests.testLandingCardUsesItsOptionsHeightWhenTheWindowGetsTaller`：常规布局组起始高度 680（660 以下现在是紧凑布局），另加紧凑高度组 560/600/650；断言不变。
- `SafeCleanupLayoutTests.testDeveloperCategoriesUseBalancedRowsThroughWidthChanges`：开发工具操作列最窄 480 后，宽 900、760、660 时四个类别排成一行四列（原来操作列 340、两行两列并在中等宽度裁掉选项）；“只排完整行”的断言不变，只更新各宽度的预期列数。
- `SafeCleanupLayoutTests.testSmartScanReferenceProportionsKeepAllScopesReadableInBothAppearances`：图标比例断言原按 `高 ≥ 560` 判断常规布局，改为按 `isCompactLanding`，并加 980×680 常规尺寸；比例阈值不变。

## 拟议的 DECISIONS 补充（合并时写入）

D3 补充：设置窗口侧栏与主侧栏共用同一行样式（选中填充＋描边、悬停），选中色用设置窗口自身的主题色——设置分类不是模块，没有模块色。

## 测试

- 首轮：Debug 全量 3102／跳过 22／0 失败。
- 复核后：相关类（`ConceptLandingNativeLayoutRegressionTests`、`SafeCleanupLayoutTests`、`UIConsistencyRegressionTests`、`AppSymbolGeometryTests`、`SystemMonitorServiceTests` 及文件分析／迁移相关）全部通过；Debug 全量结果见“验证”。

## 验证

| 命令（`~/Developer/.sc-build/batch3b/debug`） | 结果 |
|---|---|
| 相关类 `ConceptLandingNativeLayoutRegressionTests`、`SafeCleanupLayoutTests`、`UIConsistencyRegressionTests`、`AppSymbolGeometryTests`、`SystemMonitorServiceTests` | 172 项 0 失败；另 `LargeFiles`／`Migration` 相关 38 项 0 失败 |
| Debug 全量 `swift test`（`debug-full-145636.log`） | exit 1：3103 项，跳过 22，1 项失败：`NetworkCompatibilitySpeedTestServiceTests.testCancellationStopsPendingURLSessionTasks`（已知偶发 N4，与本批无关）；单独重跑该类 46 项 0 失败 |
| `python3 script/check_private_api.py` | exit 0（6 处白名单） |
| `git diff --check` | exit 0 |
| `build_and_run.sh --bundle-only`（前置小窗性能测试，`STORAGE_CLEANER_VERIFY_ROOT=~/Developer/.sc-verify/batch3b-bundle/scratch`） | exit 1：16 项中 `MenuBarPerformanceRegressionTests.testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 0.1046 s > 0.1 s，当时负载约 17（其他批次在编译测试）；本批未改小窗代码，按规则不放宽阈值，合并后空闲时由完整门禁重跑 |
| 截图包 `STORAGE_CLEANER_SKIP_TESTS=1 build_and_run.sh --bundle-only`（只用于离屏截图） | exit 0（前置测试明确跳过） |
| 离屏尺寸截图 `--capture-main-window-responsive`（新增 1000×700、900×640 两档，共 7 档 × 14 页） | 已核对：中等宽度下开发工具、应用更新去掉插图后操作列用满宽、四个类别一行；应用更新页头按钮与标题同排；迁移页紧凑布局字段同排、选项完整；常规尺寸不变。证据在不同步的 `~/Developer/StorageCleanerMac-evidence/p1/responsive-3b-fix-dark/` |

## 未完成

- 文件分析初始插图（插图风格三种混用、文件分析初始页最空）：需要新的插图资产或统一风格的取舍，留待设计决定或批次 5。
- 需要实机核对（需要辅助功能/屏幕录制权限）：D3 选中态在浅色、深色、增强对比度下的观感；设置窗口行高、焦点、侧栏拖拽、标题隐藏后“窗口”菜单与读屏；中等宽度下插图消失时的整体观感。设置窗口侧栏离屏截图为空白，属截图方法限制。
- 非落地页（扫描中、结果页）页头在英文下的高度跳动只做了机理分析：无操作的页头现在都不预留操作行，未逐页实测。
