# r2-mini-cleanup-card：小窗清理页读取智能扫描明细

> 当前交付为第八轮 `prepared-r8/`，基线 `efae19b`。第七轮已由主会话提交并编译通过：94 类 1416 项、跳过 4，三个滚动托管方法失败；窗口 visible=true，但 AX 树在 DocumentView 截止、没有内容子元素。本轮仅改测试与清理页内 Debug 探针及本文，改用实际 body 的 Preference 字段和末行几何，保留三态非滚动 AX 方法、强持有与延后拆卸。构建、XCTest、红绿、反证与提交均 NOT RUN，详见末尾“第八轮”。

## 交付状态与范围

- 分支 `task/r2-mini-cleanup-card`，基线 `5defca5c3fc4ed8a8333858290601eeb00d32f12`，worktree `~/Developer/sc-worktrees/r2-mini-cleanup-card`。
- 本批实现按任务指定的 `openai/gpt-6.1-sol` 标识记录；模型身份不能由实现者自证。
- **代码、10 个新增测试方法、演示场景及分组补丁已准备；构建／XCTest／红绿／反证／性能计时／截图／提交均 NOT RUN。** `common.md` 和 D60 明确要求 Codex 沙箱只准备源码，不尝试构建、测试或写 `.git`。
- 实际执行的验证只有元数据检查：`git diff --check`、补丁正反向可应用性、最终文件和产物 SHA-256、未改变的受限文件核对。结果见本批 `prepared/static-checks.json`；它不构成编译或测试通过证据。
- 未改 `ScanStore.swift`、看板、决定、扫描器、清理执行器、私有 API 清单或性能预算；没有启动应用、安装、提交、清理文件或写硬件设置。

## 数据来源与取舍

| 来源 | 现有属性／类型与语义 | 本批用途 |
|---|---|---|
| 主窗口当前扫描会话 | `ScanStore.cleanupScanSession: ScanSession?`，`@Published private(set)`；主窗口结果页直接读它。包含候选、分档、测量完整性、所属应用状态、完成时间和完成／部分／取消结果。清理后候选被移除、所属应用退出后候选被更新时，会话 ID 可以不变 | 产品 2.0 模式有会话就以它为准；不从旧明细或持久摘要猜测当前候选。缩小范围的扫描和取消扫描也尊重这份会话，不拿先前全盘历史冒充本次结果 |
| 历史摘要 | `scanHistorySummary.latestStatus(): LastScanStatusSummary?`；封装最新 `ScanHistoryEntry` 与新鲜度／权限关注状态，只存体积、数量、日期等，不保存可执行的候选路径明细 | 没有内存会话时显示“上次扫描 · 时间”。有绿色项才提示“清理前请重新扫描”；绿色项为零则说明上次没有绿色项。没有历史则明确首次扫描。摘要不转成可执行明细 |
| 旧版明细 | `store.items(for: .green): [StorageItem]`；来自旧 `ScanResult`，`actionableCleanupItems` 沿用 `canMoveToTrash` 筛选与前四项截取 | 仅旧架构 `.legacy` 的标题、卡片和计数维持原行为。2.0 卡片不将 `ScanCandidate` 转成 `StorageItem`，也不创建平行扫描状态 |

N20 前批的历史写入仍保持：非取消、未缩小类别／规则的完整智能扫描才写历史，开发工具与安全清理范围扫描不写。历史的绿色数量来自 `CleanupScanTierTotals.safe`，**包括仍可勾选、但所属应用正在运行的绿色项**。因此摘要里的“绿色总数”和项目卡的“默认可清理数”可以不同，这与主窗口的风险卡／默认勾选两种口径一致，不把它们混成一个数。

- 摘要复用 `CleanupScanTierTotals(categories:)`：可选择、非永久删除的绿色项；不纳入黄色、红色或单独确认的“清空废纸篓”。会话存在时，清理页的数字也读当前会话投影，避免候选清理后仍显示历史总数。其他页面的既有 `safeCleanupBytesText`／`safeCleanupCountText` 仍读历史。
- 项目卡复用 `ScanCandidate.isPreselectedByDefault`（D47）筛选绿色项：未知所属应用、最近仍写入的日志、旧规则标为 optional 的绿色项仍在默认项里；正在运行的所属应用和 `.forbidden` 项除外。取消会话没有默认项目。只显示扫描顺序中的前四项，计数显示全部默认项目数；并未复制用户当前勾选状态，也不为用户改变选择。
- 行名用 `sourceURL.lastPathComponent`，大小与主窗口同用 `CleanupMeasurementPresentation.value(candidate)`；下限测量保留“至少／At least”。只把该已有枚举从 `private` 改为模块内可见，算法与文案未改。
- 会话不存在时不能根据摘要的 `shouldRescan == false` 声称能清理：历史再新也没有执行所需明细。反之，有会话且没有默认项目时不误报“需重新扫描”；可以在主窗口查看仍运行的绿色项等原因。
- 新 `MiniWindowCleanupDetails` 只缓存体积、数量、会话标识与至多四个展示候选，不持有整份会话、不持久化、不作为清理参数。`MiniWindowCleanupPresentation` 是文案投影；没有新增业务 Store。既有 `ScanStore` 属性已经足够，无需向所有者请求新接口。

## 每个按钮的真实行为

`GeekCleanupView` 中三个按钮保持原 closure：

| 按钮 | 调用 | 效果 |
|---|---|---|
| 查看安全清理／Review Safe Cleanup | `openApp(filter: .green)` | `store.showFilter(.green)`，关闭小窗并请求打开主窗口安全清理页 |
| 查看大型文件／Review Large Files | `openApp(filter: .largeFiles)` | 同样只切路由并打开主窗口文件分析页 |
| 打开内存管理／Open Memory Management（完整密度才有） | `openApp(filter: .memory)` | 同样只切路由并打开主窗口内存页 |

共同实现仍是 `MenuBarAdvancedStatusView.openApp`：`showFilter` → `dismissPanel` → `requestMainWindow`；不启动扫描，不提交清理计划，不移动或删除文件。新行没有按钮、复选框、Finder 操作或执行入口。“在主窗口确认”是说明，点击语义未变。

## 改动文件

| 文件 | 改动与理由 |
|---|---|
| `Support/MiniWindowCleanupPresentation.swift`（新增） | 三种数据源／准备中／取消状态的文案投影，D47 四行派生明细及后台缓存准备模型 |
| `Views/MenuBarAdvancedStatusView.swift` | 新增惰性的页面派生 `StateObject`；构造不扫描候选、不启动工作 |
| `Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift` | 2.0 标题与说明读新投影；新增仅清理页用的字节／数量适配器；旧模式与其他页历史数字保持 |
| `Views/MenuBarAdvanced/GeekCleanupView.swift` | 可见清理页订阅会话、离开时取消；2.0 项目卡读取候选投影与共用大小格式；旧项目行与三个按钮保持 |
| `Views/MenuBarAdvanced/MenuBarGeekPanel.swift` | 清理页概览块使用当前投影，显示全部默认项数量；区分准备中、历史、首次扫描、真实零项，避免卡片外仍误报重扫 |
| `Views/CleanupScanViews.swift` | 既有大小格式器开放模块可见性，名称／大小格式共用而不复制 |
| `Support/MiniWindowDemoData.swift` | Debug 新场景 `menu.cleanup.afterSmartScan`，复用现有惰性 Store 夹具与二级页路由 |
| `Tests/StorageCleanerMacTests/MiniWindowCleanupPresentationTests.swift`（新增） | 9 个模型／接线／旧模式测试，详见下文 |
| `Tests/StorageCleanerMacTests/MiniWindowDemoDataTests.swift` | 增加 1 个场景及禁止执行的夹具接线测试 |
| 本交接 | 数据来源、全部定向类清单、验证命令、反证和局限 |

## 文案与状态

| 情况 | 标题 | 项目卡说明（中文／英文） |
|---|---|---|
| 会话已加载、有默认项 | 可安全清理／Safe Cleanup | 默认可清理 N 项。在主窗口确认。／N default cleanup items. Confirm in the main window. |
| 会话已加载、无绿色项 | 可安全清理／Safe Cleanup | 本次扫描没有绿色清理项。／This scan found no green cleanup items. |
| 会话已加载、有绿色项但无默认项 | 可安全清理／Safe Cleanup | 本次扫描没有默认可清理项。在主窗口查看。／No default cleanup items. Review in the main window. |
| 会话准备中 | 可安全清理／Safe Cleanup | 正在整理扫描明细…／Preparing scan details…；不降级成“仅历史／需重扫” |
| 会话已取消 | 扫描已取消／Scan Cancelled | 扫描已取消。重新扫描后再确认清理。／Scan cancelled. Rescan before confirming cleanup.；保留发现的绿色摘要，默认项为零 |
| 只有历史、有绿色项 | 上次扫描 · 本地化年月日时分／Last Scan · date and time | 仅保留扫描摘要。清理前请重新扫描。／Only the scan summary is saved. Rescan before cleanup. |
| 只有历史、绿色零项 | 上次扫描 · 时间／Last Scan · time | 仅保留扫描摘要。上次没有绿色清理项。／Only the scan summary is saved. The last scan found no green items. |
| 没有任何扫描 | 尚未扫描／Not Scanned Yet | 先在主窗口扫描，再查看清理项。／Scan in the main window to see cleanup items. |

历史与首次扫描的“当前可操作”数为 `--`，不将未加载误称为零；已加载且默认项为空才显示 `0`。原来的完整／简化密度卡片可见性维持不变。

## 小窗性能与并发复核

- 仅 `geekCleanupPage` 的 `.onAppear` 启用模型，其 `.onReceive(store.$cleanupScanSession)` 接收会话更新并发起派生工作；根视图构造、概览、其他页没有 `request`。只拷贝 Sendable 会话值进入 worker，候选指纹及分档／D47 整理都在后台。
- 复用 `MenuBarDerivedCache`，缓存 family 是 `cleanup:default-items:d47-first-four-v1`。保留原字节、页数与淘汰预算；缓存估算成本为 64 KiB，保留最多四行，不保存整份 ScanSession。
- 键覆盖候选 ID、风险／动作、可选性／预选资格、大小／测量状态、名字路径和副标题；同一会话 ID 的所属应用状态变化、候选删除、大小变化都不会命中旧展示。重复打开同一份会话复用已有派生结果；仍需在后台计算内容指纹，不在主线程深比较或排序。
- `@MainActor` 模型管理 worker 和发布；generation 与取消检查阻止旧任务／已隐藏页面回写。离开清理页关闭 `isVisible` 门控并清空本地展示，共享缓存仍受原预算限制。即使保留的 hosting controller 仍有 publisher 订阅，隐藏时的后续会话通知也会被拒绝，不启动新工作。`MenuBarPanelSession.hide` 现有实现分离 hosting controller，保证隐藏时交付 `onDisappear`，本批没有改生命周期机制。
- 文案与时间在显示时按 `L10n.locale` 计算，缓存没有保存本地化字符串。性能计时与真实显示仍需主会话验证；没有执行或声称预算通过。

## 测试覆盖、旧断言及依据

新增 `MiniWindowCleanupPresentationTests`（Debug 和 Release 都可编译）：

1. `testInMemorySmartScanUsesResultsTotalsAndD47RowsInBothLanguages`：会话覆盖不相关历史，6 个绿色项／5 个默认项／4 行，名字、下限大小与中英文案；unknown owner、recent log、optional green 均保留，running／黄色／红色／Trash／失败测量不入默认卡。
2. `testHistoryOnlyStatesShowTheScanDateAndAskForRescanOnlyWhenThereAreItems`：仅历史的有项／零项，年月日时分、字节／数量、卡片空明细及两种语言说明。
3. `testNoScanSaysFirstScanWithoutPretendingToHaveHistoryOrZeroItems`：首次扫描标题、未知数值和中英文案。
4. `testEmptyAndRunningOwnerOnlySessionsAreLoadedWithoutARescanWarning`：真零项与“全是正在运行的绿色项”区分，不要求重扫。
5. `testPreparationAndCancelledSessionsNeverExposeOldOrExecutableRows`：准备中不冒充历史，不接收另一个会话的明细；取消会话不列默认项。
6. `testReopeningUsesSharedCacheAndSameIDChangesInvalidateIt`：重复打开只构建一次；同 ID 所属应用退出、候选移除构建新投影；缓存家族只留一个当前版本。
7. `testHiddenPageAndReplacementWithNilCannotDeliverAQueuedProjection`：构造不构建；立即隐藏、隐藏后收到会话更新或会话变 nil 后不构建／交付旧明细。
8. `testLegacyScanStillUsesStorageItemsAndOriginalTitlesAndNotices`：真实旧模式适配器的标题、前四个 StorageItem、历史数量、旧说明和未扫描行为保持；测试偏好仅用 `TestPreferenceDomain`，语言仅用现有可恢复的内存 scope。
9. `testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons`：模型与真实 Geek 卡片、概览块、源属性、页面订阅／取消的接线守卫；锁定三个原路由，禁止新增扫描／清理调用。

`MiniWindowDemoDataTests` 增加 `testCleanupAfterSmartScanScenarioUsesTheExistingInertSessionAndCleanupRoute`（仅 Debug），验证路由与惰性会话一致，不持久化扫描，不产生执行计划／进度。

**改写的旧断言：无。** 没有删除、放宽或跳过已有测试；`MiniWindowDemoDataTests` 仅追加测试。新的 2.0 展示语义直接依据本批任务、N20 前批交接第 7.4 节、D47。`.legacy` 的原文案与前四项规则用新的运行时回归锁定，D48 偏好守卫仍包含在定向清单里。

## 主会话验证命令（沙箱外运行）

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
export SWIFT_BUILD_JOBS=4
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared"
mkdir -p "$mini_cleanup_scratch/logs"
```

已有构建夹具按 RULES 从 `~/Developer/.sc-build/r2-u1-preselect/debug/{checkouts,repositories,artifacts,workspace-state.json}` 只读复制到本批专属的相应 scratch，并按既有流程改写 workspace-state 的 scratch 路径；不要共用其他批次的写入目录。

优先运行新增行为与强制界面／偏好守卫，失败则先回交同一实现会话修正：

```bash
swift build --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 > "$mini_cleanup_scratch/logs/build.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|CleanupDefaultSelectionPolicyTests|SmartScanHistoryTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/focused-debug.log" 2>&1
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/targeted-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/strict-tests.log" 2>&1
script/verify_menu_bar_performance.sh > "$mini_cleanup_scratch/logs/menu-performance.log" 2>&1
```

完整集成门禁由主会话在验证与合并流程中运行 `script/verify.sh`，沿用以上环境变量，预算不得调整；计时失败只允许按 RULES 在机器空闲时复跑。Debug 专有的 `SmartScanHistoryTests`／`MiniWindowDemoDataTests` 在 Release 不会被发现，必须在 Debug 记录实际数量；新的 9 个核心测试没有 Debug 条件，不能靠 Release 排除它们。

## 定向测试类完整清单

按 `MenuBar*`／`MiniWindow*`／`MiniSensors*`／`Geek*` 的 XCTest 类定义，并补入直接引用小窗／共享缓存／演示基础设施的测试、D47／N20、UI／偏好守卫检索得出，共 90 类（本批新增类包含其中）；没有只按文件名推测，单文件里的 `MiniWindowMemoryQuitHeaderLayoutTests` 也已列入。补丁目录中的 `targeted-test-classes.txt` 与此清单一致，供 `--filter` 构造使用。

```text
AppIconCacheTests
BatteryChargeLimitPresentationTests
BatteryChargeLimitReadCacheTests
BatteryPresentationTests
BetaDistributionTests
CleanupDefaultSelectionPolicyTests
ComputerHealthIntegrationTests
ComputerHealthModelsTests
ControlAccessibilityContractTests
ControlPaletteTests
DaylightRefinementTests
DetailedPanelViewProfileTests
EnergyImpactServiceTests
EnergyProcessNamingTests
FanControlModeCardTests
FanCurveEditorInteractionTests
GPUFrequencyTelemetryTests
GeekDashboardConfigurationTests
GeekHistoryAveragingTests
GeekHoverDetailTargetTests
GeekInlineTertiaryAnchorUpdateTests
GeekInlineTertiaryContentStoreTests
GeekOverviewLabelLayoutTests
GeekPowerViewTests
GeekProcessorCorePresentationTests
GeekSensorsPowerHoverDetailTests
GeekVPNManagementActionTests
HardwareControlPresentationTests
L10nTests
MacMiniPortraitRegressionTests
MemoryPressureLevelAppWideTests
MemoryQuitConfirmationTests
MemorySelectionSummaryTests
MenuBarCachedHealthTests
MenuBarDefaultsChangeSubscriptionTests
MenuBarDeviceStatusTests
MenuBarHistoryGapTests
MenuBarMonitorSessionTests
MenuBarPanelInteractionTests
MenuBarPanelPlacementTests
MenuBarPanelSessionTests
MenuBarPerformanceRegressionTests
MenuBarPowerHistoryStoreTests
MenuBarSecondaryVisualConsistencyTests
MenuBarSimplePanelQuitTests
MenuBarStatusPanelTests
MenuBarTertiaryDetailTests
MiniSensorsDecodingTests
MiniSensorsLiveReadingTests
MiniSensorsNoValueRuleTests
MiniWindowAnchorGeometryTests
MiniWindowBatteryStatusTests
MiniWindowCascadeSettleTests
MiniWindowCleanupPresentationTests
MiniWindowConfigurationR2Tests
MiniWindowConsistencyRuleTests
MiniWindowD43LayoutTests
MiniWindowDemoDataTests
MiniWindowDiskLevelOneBarTests
MiniWindowFanHistoryCacheTests
MiniWindowHistoryDemandTests
MiniWindowIconConsistencyTests
MiniWindowKeptHistoryTests
MiniWindowLevelOneAnchorTests
MiniWindowLiveReadingRetentionTests
MiniWindowMemoryPressureLevelTests
MiniWindowMemoryQuitHeaderLayoutTests
MiniWindowMemoryQuitSelectionTests
MiniWindowMemorySwapActivityTests
MiniWindowPhase2ReviewTests
MiniWindowPressureHistoryCompactionTests
MiniWindowRangeSwitchTests
MiniWindowReviewFollowUpTests
MiniWindowRowLayoutTests
MiniWindowSinglePageTests
MiniWindowSpeedBehaviourTests
MiniWindowSpeedInstrumentationTests
MiniWindowSpeedTests
MiniWindowUpdatingStateTests
NativeNetworkInterfaceControlTests
NetworkSpeedTestServiceTests
OwnedUIFlatteningContractTests
PanelChartNormalizationTests
ScanStorePerformanceTests
SmartScanHistoryTests
SystemMonitorServiceTests
SystemUtilitySafetyTests
TestPreferenceHygieneTests
UIConsistencyRegressionTests
UnifiedMenuBarPanelTests
```

## 红／绿／反证

本批运行结果均 **NOT RUN**；下表是预期失败及主会话操作，不能当作已经出现的红绿证据。

| 场景 | 对最终源码施加的反证补丁 | 应失败的测试与原因 |
|---|---|---|
| 恢复本批之前的旧标题／说明／项目卡读取路径（保留新模型与 API，让测试能编译） | `counterexamples/01-legacy-card.patch` | `testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons`：标题与 notice 不再走会话，项目卡不再渲染会话候选。纯投影测试仍可能通过，这一接线守卫用于发现“模型正确但 UI 没用它”的假修复 |
| 有会话仍只看历史 | `counterexamples/02-history-only.patch` | 内存、空会话、准备／取消三个测试的来源、标题和说明失败；仅历史与首次扫描测试应保持通过 |
| 默认卡列出所有绿色项，忽略 D47 运行中所属应用例外 | `counterexamples/03-ignore-d47.patch` | 内存与缓存复用测试的默认项数量、候选 ID／名字、运行中排除失败；所属应用全部运行的测试也失败 |
| 缓存只按会话 ID／时间／outcome，不含候选变化 | `counterexamples/04-stale-cache.patch` | 缓存同 ID 变更测试的键、不命中旧值、数量及候选移除断言失败 |

“红”可先应用第 1 份，复现基线 UI 的错误接线；“绿”必须逆向还原反证补丁后跑全部定向与性能；再逐份应用其余反证，验证测试能识别错误实现。`prepared/run-counterexamples.py` 会先做补丁适用性检查，逐份应用、运行相关 Debug 测试、在 `finally` 逆向还原，并写日志；任何反证意外通过立即停止。它**未在本批执行**，不修改 `.git`，不提交，不代替最终绿验证。

```bash
python3 "$mini_cleanup_prepared/run-counterexamples.py"
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/after-counterexamples-green.log" 2>&1
```

记录每条 exit code、实际测试数量／跳过／失败名称，补写本交接或独立主会话验证记录。不能把“反证编译失败”替代测试断言报红；若遇编译问题，先修复并保持这四份反证意图。

## 演示场景与截图核对

新增场景仅 Debug 可用，因为既有 `ScanStore.installDebugSmartScanSessionFixture` 和执行拦截只在 `#if DEBUG` 内。本批不能扩大 `ScanStore` 条件；普通 `--beta` 构建是 Release，**不会识别此 Debug 场景**。主会话须用已准备的 Debug 截图包或本批 Debug 可执行文件；无需安装替换单一 Beta。

参数：

```text
--debug-mini-window-demo-data
--capture-menu-bar-panel-directory=<本批 scratch>/screenshots/cleanup-zh-light
--capture-menu-bar-panel-scenario=menu.cleanup.afterSmartScan
--debug-mini-window-appearance=light
-app.language zhHans
```

英文改 `-app.language english`，夜间改 `--debug-mini-window-appearance=dark`，各组合用独立截图目录。可追加 `--debug-smartscan-d47-rows` 显示未知所属、运行中所属与大缓存示例；该参数仍由既有主窗口夹具生成相同会话，未造第二份演示状态。输出文件名为 `menu-cleanup-afterSmartScan.png`（同目录附带既有布局 JSON），路线是 `.secondary(.cleanup)`，应有一级＋清理二级两个面板，不出现三级。

主会话在已有授权的 Debug 截图环境中可按下面的可执行文件入口运行（**本批未启动**）：

```bash
mini_cleanup_bin="$(swift build --scratch-path "$mini_cleanup_scratch/debug" --show-bin-path)"
"$mini_cleanup_bin/StorageCleanerMac" --debug-mini-window-demo-data --capture-menu-bar-panel-directory="$mini_cleanup_scratch/screenshots/cleanup-zh-light" --capture-menu-bar-panel-scenario=menu.cleanup.afterSmartScan --debug-mini-window-appearance=light -app.language zhHans
```

核对中英／昼夜：标题为可安全清理；有前四个默认绿色项，名称和完整／至少大小与主窗口一致；“正在运行”的示例不入默认卡；未出现过时的重扫提示。若开启 D47 示例，摘要总数可以比默认数多一个。另核对简化密度保持原卡片可见性、长历史日期的标题截断／读屏、异步准备期间不闪出错误历史说明；截图机制现有等待时间不构成明细绘制完成证据，须检查图片内容，忙机器上必要时手动等待再捕捉。实机生产扫描与重启后的历史状态由主会话在其既有授权范围验收。

## 分组与提交准备

`~/Developer/.sc-build/r2-mini-cleanup-card/prepared/`：

1. `01-cleanup-card.patch`：只读投影、异步缓存、2.0 真实卡片接线、共用大小格式器。
2. `02-regressions.patch`：新增 9 个核心测试。
3. `03-demo.patch`：惰性 Debug 清理场景与 1 个演示测试。
4. `04-handoff.patch`：本交接。

还有逐组 message、`all.patch`、`manifest.json`（基线／分支／顺序／10 个最终文件 SHA-256 与产物哈希）、`static-checks.json`、`commit-prepared.py`、测试清单及四份反证。主会话验证、反证和复核完成后才执行 `python3 "$mini_cleanup_prepared/commit-prepared.py"`；脚本先核对基线、分支、空暂存区及哈希，再只按组暂存并提交，不 push。如果收到修订或文件已变，应重新生成产物后复核，不跳过哈希。

## 未解决与限制

- 编译、严格并发、实际 XCTest、性能预算、主窗口／小窗原生截图与重启验收均等待主会话；不得把静态产物交付当作这些环节已通过。
- JEV 判断调用实际返回 `MCP tool call requires approval, but approval policy is never`，在推理开始前被权限策略阻断。工具接口没有模型选择参数，未验证服务器实际模型标识，没有声称 JEV 给出判断或复核通过；主会话仍需全新 Claude 复核员。
- 演示采用现有 Debug 入口，仅 Debug，普通 Release Beta 不支持；不改所有权冲突文件来扩大演示范围。
- 内容指纹在后台仍是线性遍历，派生明细命中缓存后不重复分档；并未声称候选遍历为零或首次页面没有异步准备状态。
- `MenuBarCombinedPanel.cleanupPage`／简单面板不是本产品 Geek 路径，按前批交接是不可达展示；本批未扩展这两条旧展示路径。旧扫描架构在 Geek 页的行为有独立回归测试。

## 第二轮（基线 7c8fd76）

本轮交付在 `~/Developer/.sc-build/r2-mini-cleanup-card/prepared-r2/`，完整基线 `7c8fd76694f9de925d39951bd1124f54bf716aac`，分支仍为 `task/r2-mini-cleanup-card`。前面的章节保留第一轮的设计与沙箱交付记录；本节覆盖其中已经变更的缓存、排序、占位与接线口径。第二轮仅写源码、测试、文档及补丁；**编译、XCTest、红／绿／反证执行、性能、截图、安装、提交均 NOT RUN**。静态检查只检查补丁与文件元数据，不代替这些验证。

### 第一轮实际验证与复核证据（P2-10）

第一轮已由主会话在沙箱外完成：**编译一次通过；90 个定向类，1358 项，跳过 4，0 失败；4 份反证均使 MiniWindowCleanupPresentationTests 失败并已还原；check_private_api 通过**。四组已提交为 `2695cc0`、`0ca4014`、`9071438`、`7c8fd76`。这些是第一轮证据，不是第二轮结果。

本轮只读核对了 `~/Developer/.sc-build/r2-mini-cleanup-card/logs/main-build-1.log`（末行 `Build complete! (109.00 sec)`）、`main-test-1.log`（Selected tests：1358 项、4 skipped、0 failures）、`counterexamples-results.json`（四条 exit 1，均列出实际失败测试）、`private-api.log`（7 allowlisted uses）。编译一次、还原完成及提交状态由主会话报告，HEAD 通过只读 git 元数据确认。

完整复核报告为 `~/Developer/.sc-build/r2-mini-cleanup-card-review/review-1.md`。复核员 Claude 的结论是“修后可合并”，P1 一项、P2 十一项；其 Debug 包构建、四组截图及性能门禁记录均为第一轮。性能门禁 16 项通过，preparation p95 77.85 ms、cached delivery p95 0.0019 ms，**该门禁不覆盖清理页，不能证明本轮打开路径已修复**。

本轮已读两份插桩日志 `logs/probe-open-timeline.log`、`logs/probe-open-timeline-d47.log`：首帧为 preparing，默认两行由 312×302 变为 312×370；D47 四行三次由 312×302 变为 312×438，请求至交付 26.3／24.4／20.8 ms。截图见报告的 `screenshots/head/` 与 `screenshots/baseline/`；它们只证明第一轮数据接线正确及排序问题，不是本轮观感验收。

### 逐项处理与取舍

下表“红”指施加本轮反证后应出现的失败，“绿”指恢复最终源码后同一测试应通过；都由主会话执行，目前 **NOT RUN**。末两项属于文档或合并协调，分别列出核验方法，不伪装成已经运行的产品测试。

| 项目 | 本轮处理与依据 | 红／绿／反证 |
|---|---|---|
| P1-1 | 保留 `details` 与 `deliveredKey`；stop 仅取消 worker，构造和隐藏都不遍历候选。同 ID／完成时间／outcome 刷新仍显示旧投影并标“更新中…”，行按 D32 淡化至 45%；键相同时直接结束，不重新交付或构建。不同三元身份由 resolver 进入 preparing；权威会话为 nil 则回到历史或首次扫描，不显示残留行。准备态用 `…`；四行区固定预留 132 pt，说明预留至少 34 pt，避免初次交付及同会话更新缩回空卡。D32／D39、用户第二轮要求。 | `05-clear-request`、`06-clear-hide`、`07-republish-same-key`、`08-unavailable-placeholders`、`15-remove-row-reservation`、`17-ignore-session-identity`、`19-ignore-updating`；对应测试见下表。恢复后同组测试须绿。需另做原生打开／重开尺寸与录屏核对。 |
| P2-1 | worker 内按 `estimatedSizeBytes` 降序；大小相同时按 `snapshot.standardizedPath.localizedStandardCompare` 升序，然后取四项。与主窗口 `topCandidates` 比较器一致，D47 总数仍包括全部默认项。 | `09-scan-order` 使预览和大小平手测试红；恢复后绿。D47 截图顺序应为 video-renders、cache.db、unknown-helper、image-cache。 |
| P2-2 | 2.0 未知数使用非数值占位 `…`，不是 0；这样现有 GeekMetricCell 会保留“需重新扫描／历史摘要／等待首次扫描／正在整理明细”。真实卡片 notice 在扩展与简化密度都呈现；不改变共享指标组件的未知值规则。 | `08-unavailable-placeholders` 使实际指标渲染测试红；`10-hide-notices` 使真实页文字验证红；恢复后绿。 |
| P2-3 | 计数复用 `L10n.items`；默认项目说明对 1 单列 `item`，其余为 `items`。旧模式原文保持。 | `11-plurals` 使 0／1／2 模型测试红；恢复后绿；真实卡片渲染测试亦包括单项会话。 |
| P2-4 | 提取真正用于产品的 GeekSmartCleanupContent 与 GeekSmartCleanupPage。ImageRenderer 光栅化真实卡片，再用系统 Vision 读取实际字形，按识别框的纵向位置断言真正首行标题（避免误把同名遥测标签当标题）、计数、各态说明、候选名及大小；NSHostingView 核对页面高度和真实宿主的可见订阅。没有额外构造 2.0 Store；保留源码守卫仅锁定按钮与观察边界。 | `01-legacy-card` 现在应使**真实渲染**测试红，而不只依赖 contains；`10-hide-notices` 同样红。恢复后绿。 |
| P2-5 | 新增 2.0 渲染与模型测试均无 Store 构造。原两处构造确有 Store 行为要验证，按用户要求保留，不提前复制尚未合并的测试工厂；主会话合并 hygiene-2 后迁移，详见下面清单。 | 合并后未迁移时，其 `TestPreferenceHygieneTests` 工厂守卫为红；替换两处为 `ScanStore.makeForTests` 后，运行该守卫、旧模式回归及演示测试须绿；反证为仅将其中一处改回直接构造，应再次红。本基线没有该工厂／新守卫，当前不能执行这项反证。 |
| P2-6 | `cleanupSummaryTitle`／`staleCleanupSummaryNotice` 及旧数字适配器恢复旧语义，供 dormant simple panel 和 legacy Geek 使用；2.0 文案只在真实 Geek 宿主解析，防止没有 worker 的简单页永久 preparing。D2 补充明确简单布局不可达；本轮不扩展它。 | `16-dormant-adapters` 使原接口边界守卫红；恢复后绿，旧模式行为测试仍须通过。 |
| P2-7 | 继续复用既有 MenuBarDerivedCache，遵守用户“复用已有缓存”要求，未自建平行 actor 或扩大页槽。新增局部交付保留后，同键重开甚至被 LRU 淘汰也不再访问缓存；不同内容才请求缓存。cleanup 仍占一个共享页槽，第一次打开或内容更新仍可能驱逐最旧图表页，这是现有四页 LRU 的明确取舍，不声称消除了驱逐。 | `testRetainedDeliverySurvivesSharedCacheEvictionWithoutIncreasingItsBudget` 用一页测试缓存验证淘汰后重开不回填、不多构建；`06-clear-hide` 使其红；恢复后绿。产品预算原文件逐字节保持。 |
| P2-8 | 根视图仅以 `@State` 持有有界模型引用，维持跨路由交付，不订阅其 Published；真正清理宿主用 `@ObservedObject` 接收明细。将模型完全改为临时子页 StateObject 会在切走后丢掉交付，违背 P1／D39，因此采用“父持有、子观察”。 | `12-observe-root` 使产品观察边界守卫红；恢复后绿。真实宿主测试进一步验证候选刷新交付且保留父视图不因明细发布重新求值。原生整组 body 数量仍待插桩。 |
| P2-9 | 新智能扫描行的大小 Text 加 `.fixedSize()`，名称仍单行截断；继续共享主窗口的完整／下限格式。 | `13-shrink-size-column` 使大小列契约守卫红；恢复后绿；另用 280 pt 实际渲染验证长文件名下完整的 `At least …`。不声称旧行也已修改。 |
| P2-10 | 补入第一轮实测、提交与复核证据；当前阶段与历史 NOT RUN 分开，避免沿用旧交付状态冒充当前状态。 | 文档核验：对照第一轮四份日志与报告；若把本节改回“第一轮测试 NOT RUN”或错误计数，和原日志矛盾，第二轮生成器也要求本节含精确 `1358 项，跳过 4，0 失败`。正确证据说明与本轮 NOT RUN 同时保留才为绿。这是证据／元数据核验，不是 XCTest 反证。 |
| P2-11 | 只读现有 `store.isScanning`；历史／首次扫描态扫描过程中说明为“扫描中…等待本次结果。”，不催用户再启动一次扫描。历史数字、日期仍是历史，不新造扫描状态。 | `14-ignore-active-scan` 使扫描中中英文模型测试红；恢复后绿；实际渲染测试含扫描中的历史态。 |

### 改写第一轮断言（逐条）

没有删除测试方法、跳过新测试或放宽性能阈值。本轮原 9 个方法保留，新增 11 个，共 20 个核心方法；演示测试保留原方法。

1. `testInMemorySmartScanUsesResultsTotalsAndD47RowsInBothLanguages`：前四项从扫描顺序 `cache-1/2/4/5` 改为大小降序 `cache-6/5/4/2`，资格仍按 D47；新增平手独立测试。依据主窗口默认 largest 和 P2-1；总数 6／默认数 5 不变。
2. `testHistoryOnlyStatesShowTheScanDateAndAskForRescanOnlyWhenThereAreItems`：当前可操作占位从 `--` 改为 `…`，不伪造可操作数；配套实际渲染断言保证说明不会被组件换成“不可用”。依据 P2-2、RULES 未知不等于 0。
3. `testNoScanSaysFirstScanWithoutPretendingToHaveHistoryOrZeroItems`：字节及可操作占位同样改为 `…`，原首次扫描标题、说明保持；补实际卡片渲染断言。依据 P2-2。
4. `testReopeningUsesSharedCacheAndSameIDChangesInvalidateIt`：关闭后的 nil 改为保留已交付四行；重开同步保留且不多构建。依据 P1-1、D39。候选／所属应用变更的失效断言仍保留。
5. 等待工具从“details 非 nil 就结束”改为“details 非 nil 且最新 worker 结束”；否则保留旧投影后会错误地把旧结果当作新交付。5 s 截止时间未放宽，另断言 worker 已结束。
6. `testHiddenPageAndReplacementWithNilCannotDeliverAQueuedProjection`：原断言保持，并加隐藏时绝不能创建 worker 的同步断言。nil 权威会话仍不会交付旧行；没有用隐藏保留来绕过会话清空。
7. `testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons`：接线期望改为清理子宿主的 start／publisher／stop；根 State 保留但不观察；共享旧适配器无 v2 分支。新卡实际输出由运行期测试承担。按钮仍三项、filter／dismiss／requestMainWindow 与禁止执行入口断言原样保留。依据 P2-4／6／8 与 P1-1。
8. 同一方法新增大小列 `.fixedSize()` 契约，另加长文件名实际渲染验证。依据 P2-9，未为方便修改旧行。
9. `MiniWindowDemoDataTests.testCleanupAfterSmartScanScenarioUsesTheExistingInertSessionAndCleanupRoute`：只将四项候选期望改为大小排序；Store 安装、无历史写入、执行拦截等原断言全部保留。依据 P2-1，同一演示会话仍用于主窗口和小窗。

### hygiene-2 合并协调清单

本轮没有新增直接构造。必要的两处为：

- `MiniWindowCleanupPresentationTests.swift` 的 `testLegacyScanStillUsesStorageItemsAndOriginalTitlesAndNotices`（当前直接构造位于约 191 行）：验证真正旧视图的 Store.result、history 与旧适配器，改成纯投影会失去旧模式回归。hygiene-2 合并后改成 `ScanStore.makeForTests(historyLoader: EmptyHistoryLoader(), scanHistoryDefaults: defaults, cleanupFeatureConfiguration: .legacy, cleanupPreferences: defaults, cleanReportLoader: { [] }, interruptedOperationReconciler: { [] })`；以合并后的真实工厂签名为准。
- `MiniWindowDemoDataTests.swift` 的 `testCleanupAfterSmartScanScenarioUsesTheExistingInertSessionAndCleanupRoute`（当前 19 行）：验证现有 Store 安装过程的 Debug 执行拦截、workflow、无清理计划及无历史写入，纯投影不能覆盖这些语义。合并后改成工厂并保持相同隔离偏好／空报告与恢复 loader 参数。

该迁移由主会话在 hygiene-2 工厂可用后做；不得把最终两批都已合并但未迁移的状态称为卫生守卫通过。迁移后源码／HEAD 将不匹配本轮 manifest，主会话应先完成本轮补丁提交，再独立迁移提交，或重新生成对应基线的 prepared；不能跳过哈希检查。本轮不修改 `ScanStore.swift`，不复制工厂或另建 Store 状态。

### 定向类与沙箱外命令

`prepared-r2/targeted-test-classes.txt` 为本轮重新检索后的完整清单，**仍 90 类**。新增方法放在现有类，无新增 XCTest 类；上文 90 类逐项仍有效。生成器对所有 `MenuBar*`、`MiniWindow*`、`MiniSensors*`、`Geek*` XCTest 类重新核对，含单文件第二个 `MiniWindowMemoryQuitHeaderLayoutTests`；强制保留 `UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`。这不是把第一轮 1358 数量直接当作第二轮测试数量。

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r2"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
export SWIFT_BUILD_JOBS=4
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r2"
mkdir -p "$mini_cleanup_scratch/logs/round2"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
swift build --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 > "$mini_cleanup_scratch/logs/round2/build.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/round2/focused-debug.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round2/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round2/targeted-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/round2/strict.log" 2>&1
python3 script/check_private_api.py > "$mini_cleanup_scratch/logs/round2/private-api.log" 2>&1
script/verify_menu_bar_performance.sh > "$mini_cleanup_scratch/logs/round2/menu-performance.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py"
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round2/after-counterexamples-green.log" 2>&1
```

主会话记录每条 exit code、实际数量、跳过与失败名称。Debug 专有演示／历史类不能以 Release 未发现代替通过；20 个核心方法没有 Debug 排除。系统 Vision 测试实际识别本机光栅化字形，大小写／空白／标点被规范化，词句与数字没有放宽；若本机 OCR 失败，日志会打印期望与真实识别文字，回交同一实现会话处理，不能改成仅断言输入字符串或跳过渲染测试。

### 第二轮反证清单

`run-counterexamples.py` 按 manifest 中每份的明确方法过滤运行，必须找到预期方法的 XCTest 失败；编译失败、未发现测试或其他方法意外失败都不能充当成功反证。每份在 finally 中逆向还原并核对全部最终文件 SHA-256；结果写 `logs/round2-counterexamples/`，不会覆盖第一轮日志。全部反证 **NOT RUN**。

| 补丁名（counterexamples/） | 应失败方法（MiniWindowCleanupPresentationTests 内） |
|---|---|
| 01-legacy-card | testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages |
| 02-history-only | testInMemorySmartScanUsesResultsTotalsAndD47RowsInBothLanguages |
| 03-ignore-d47 | testInMemorySmartScanUsesResultsTotalsAndD47RowsInBothLanguages；testEmptyAndRunningOwnerOnlySessionsAreLoadedWithoutARescanWarning |
| 04-stale-cache | testReopeningUsesSharedCacheAndSameIDChangesInvalidateIt；testSameSessionContentChangesKeepOldRowsUntilTheLatestDelivery |
| 05-clear-request | testSameKeyRefreshAndReopenRetainTheDeliveryWithoutRebuilding；testSameSessionContentChangesKeepOldRowsUntilTheLatestDelivery |
| 06-clear-hide | testSameKeyRefreshAndReopenRetainTheDeliveryWithoutRebuilding；testRetainedDeliverySurvivesSharedCacheEvictionWithoutIncreasingItsBudget |
| 07-republish-same-key | testSameKeyRefreshAndReopenRetainTheDeliveryWithoutRebuilding |
| 08-unavailable-placeholders | testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages；testSessionIdentityDateOrOutcomeChangesUsePreparationInsteadOfOldRows |
| 09-scan-order | testInMemorySmartScanUsesResultsTotalsAndD47RowsInBothLanguages；testSizeTiesUseTheMainWindowPathComparator |
| 10-hide-notices | testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages |
| 11-plurals | testEnglishCountsAndNoticesHaveSingularAndPluralForms |
| 12-observe-root | testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons |
| 13-shrink-size-column | testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons；testHostedLongFileNameKeepsTheCompleteLowerBoundSize（契约必红，渲染是否受影响由平台布局决定） |
| 14-ignore-active-scan | testActiveScanDoesNotAskForAnotherScanInHistoryOrEmptyState |
| 15-remove-row-reservation | testHostedPreparationAndUpdatingReserveTheDeliveredPageHeight |
| 16-dormant-adapters | testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons |
| 17-ignore-session-identity | testSessionIdentityDateOrOutcomeChangesUsePreparationInsteadOfOldRows |
| 18-prepare-while-hidden | testHiddenPageAndReplacementWithNilCannotDeliverAQueuedProjection |
| 19-ignore-updating | testSameKeyRefreshAndReopenRetainTheDeliveryWithoutRebuilding |

### 演示、打开路径验收与未解决项

演示场景继续为 Debug `menu.cleanup.afterSmartScan`，参数沿用第一轮；追加 `--debug-smartscan-d47-rows`、`-app.language zhHans/english` 与 `--debug-mini-window-appearance dark/light` 做四组复核。预览排序现在按大小；绿色总数／默认数／运行中例外与主窗口同口径。没有新增清理执行入口，三个原导航按钮共用同一实现；没有新增演示 Store 状态。

原生验收需重新记录首次打开、重开和同一会话重复发布：第一次 preparing 不应再有“— 不可用”，四行区域先预留；有交付后重新打开应首帧带旧四行和“更新中…”；同键完成不重新交付。用原插桩意图或 MenuBarPresentationTrace 核对 detail-size 只上报稳定大小，重点反证 302→438 pt 跳高。原补丁的行锚点和旧命名已变，主会话应只在隔离副本调整插桩，不能直接把第一轮证据补丁当本轮产品改动。还需核对同一会话更新、首次／历史／扫描中三态，以及全页长期停留的重复刷新；第一轮 CPU 采样因截图结束后回概览没有结论，本轮不沿用。

保持 132 pt 空行区会让零／少量候选的内存会话页有一定留白，这是避免异步收缩／增高的本轮取舍；它不表示有虚构项目。历史和首次扫描页不占该行区。日期或不同语言的自然高度变化不属于同会话异步闪空，仍由现有面板布局处理。既有磁盘环中文截断、英文按钮省略及按钮对比度不在本轮修改范围。

`ScanStore.swift`、性能政策、性能脚本、私有 API allowlist、BOARD 与 DECISIONS 保持基线字节。共享四页 LRU 仍可能在首次清理投影时淘汰旧图表，未增加预算。hygiene-2 后两处工厂迁移、第二轮 Swift 编译／严格并发、真实渲染识别、性能与原生尺寸观感待主会话；没有声称第二轮已绿或可合并。

JEV 本轮决策调用仍被工具策略以 `MCP tool call requires approval, but approval policy is never` 阻断，未在服务器模型开始推理前获得可用结果，接口也无模型选择参数。复核报告里的 `jev-latest / typesafe` 判断属于复核员第一轮记录，不能作为本轮已调用模型的证据。

分组为 `01-cleanup-card`（5 个产品文件）、`02-regressions`（核心 20 方法）、`03-demo`（演示排序断言）、`04-handoff`（本节与当前状态提示），共 8 个最终仓库文件。manifest、all.patch、逐组 message、90 类清单、19 份反证、自动还原 runner、元数据生成器和 commit-prepared.py 一并交付；主会话验证与独立复核后才运行提交脚本。本轮不执行它。

## 第三轮（基线 f279377）

### 第二轮实测与本轮范围

主会话已将第二轮四组提交为 `8e9d36a`、`ddf96ad`、`966ea68`、`f279377`，trailer 为 `Generated-By: Codex (gpt-6.1-sol)`。本轮只读 git 元数据确认分支 `task/r2-mini-cleanup-card`、基线 `f2793779250faca85bf3703d71218fcb3277128c`。

主会话报告第二轮编译通过。只读核对 `~/Developer/.sc-build/r2-mini-cleanup-card/logs/main-test-2.log`：90 类共 **1369 项，跳过 4，1 个测试方法失败、98 处断言失败**。唯一失败方法为 `MiniWindowCleanupPresentationTests.testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages`；日志把“1 KiB”等识别成 `1kiв`，把中文和数字识别成混合文字。“98 failures”是该方法内的断言次数，不能写成 98 个失败测试。

同一日志中，长文件名测试、高度预留测试、宿主更新边界测试均 passed。第二轮关于系统 Vision 能稳定验证字形的取舍被本机实测否定；本节替代第二轮 P2-4 及命令说明中的 OCR 判定要求。没有据此撤回第二轮产品修复，也不把旧测试的识别失败称为产品回归。

本轮最终仓库改动严格限制为两个文件：`Tests/StorageCleanerMacTests/MiniWindowCleanupPresentationTests.swift` 和本交接。前者只改目标测试方法及文字读取辅助代码；20 个测试方法保留，其余 19 个函数体与基线逐字节一致。高度测试继续用 `NSHostingView.fittingSize`，宿主更新测试继续用真实订阅、等待交付与父视图求值计数，两者没有 OCR 依赖且未改。产品、演示代码及 `ScanStore.swift` 均未修改，偏好隔离、现有构造位置和性能预算均保持。

### 确定性读取与改写的断言

测试不再导入 Vision，不再用 ImageRenderer、识别语言、识别模型或像素缩放来判定文字。测试专用宿主将真实视图放入 `NSHostingView` 和内存中的 `NSWindow`，开启 `accessibilityEnabled`，沿原生 `accessibilityChildrenInNavigationOrder`、`accessibilityChildren`、`accessibilityContents` 遍历，读取 label、title、value 和 help。读取方式复用仓库已有 FanControlModeCardTests／SafeCleanupScopeCardLayoutTests 的平台接口；不启动产品、不获取跨进程 AX 权限、不往原生树注入期望文案。

原生布局探针只记录实际挂载和内容尺寸。读取必须满足已挂载、宽高非零、有原生文字且连续两次树快照稳定；有界 run loop 只推进布局／AX 回调，不按期望文案等待。树为空或布局不稳定会抛错并输出原生节点和尺寸，不跳过、不回退成只读期望字符串。

| 原断言／辅助逻辑 | 第三轮改写与依据 |
|---|---|
| 可操作指标显示当前数值和各态说明 | 核对页面既有 `tiles[2]` 的 value／detail，再托管真正 `GeekMetricCell`，从原生树核对 value、从 help 核对说明，并要求非零挂载布局。指标组件显式隐藏子文本，不能把 hint 当作实际子 Text；额外禁止空值、`—` 和含 `--` 的输入，逐项排除基线组件替换成“— 不可用”的条件。用户允许的“只读展示模型＋托管布局探针”用于这一个组件。 |
| 安全清理指标显示大小、项目数，没有不可用 | 同样核对 `tiles[0]`、原生 value／help 和布局；未知值仍须为产品现有 `…`。真实零项保留 0，不以未知占位冒充零，不允许旧 `--` 路径通过。 |
| 摘要卡第一行是当前标题，而不是“上次扫描摘要” | 将 OCR 第一行改为原生树中第一个文字元素的精确标题。不能只在整张卡 contains “Safe Cleanup”：第一条遥测标签同名，会掩盖标题回归。计数与已知大小继续从实际树读取。 |
| 三态 notice 在页面中出现，完整／简化密度都覆盖 | 从真正 `GeekSmartCleanupContent` 的原生 label／title／value 收集文字后断言。用于可见说明的集合明确排除 help，避免说明仅残留在 tooltip／hint 就误过。会话、仅历史、首次扫描三态保留，另外保留单项、D47 多项、准备中、历史零项、更新中、扫描中的原覆盖。 |
| 候选同名同大小，运行中项与预览外项不显示 | 候选名称来自完整页面原生文字，大小来自托管的真实 `AdvancedSmartCleanupItemRow`；D47 资格、四行限制不改。负断言从 OCR 归一化后的 `cache1/cache3` 恢复为原名 `cache-1/cache-3`。 |
| 文本比较的 normalize／共享 renderedText | 只规范空白，不再忽略大小写或删除标点、单位、中文字符。共享辅助函数全部改成 AX 读取，因此长文件名测试本体虽不改，也不会继续调用 OCR。没有移除旧断言的词句、计数或单位。 |

原生树能确认已挂载内容及其语义文字，不等同于逐像素证明未截断；尤其指标块采用现有只读模型和组件分支约束验证说明。它不能捕捉“故意把组件私有 displayDetail 硬编码为其他字形、同时保留原 AX 元数据”的任意产品变更；本轮不改该组件以增加测试接口。大小列原 `.fixedSize()` 守卫与原高度／宿主测试保持，主会话的原生截图验收仍有独立价值。

### 红／绿／反证

**已观察到的红**：第二轮上述唯一方法的 98 处 OCR 断言错误。**本轮绿与反证均 NOT RUN**；下面是主会话沙箱外执行的具体验收，不是已经得到的结果。

`prepared-r3/counterexamples/` 含四份独立补丁。只生成可应用的文本补丁，不在本轮工作树施加产品变更。每份都必须让同一个目标方法产生 XCTest 断言失败；编译失败、没有发现该方法、测试工具错误均不能作为反证通过。

| 补丁 | 反向改动 | 新测试必须失败的依据 |
|---|---|---|
| 01-legacy-card | 摘要标题恢复“上次扫描摘要”，候选列表恢复为空，模拟小窗仍取不到旧明细的展示 | 原生第一标题与内存会话标题不符；整页候选名称缺失。旧标题或旧空列表不能被模型测试独自掩盖。 |
| 02-unavailable-placeholders | 展示模型未知占位从 `…` 改回 `--` | 仅历史／首次扫描／准备态指标的输入违反可见说明分支约束，原生 value 亦包含旧占位；基线 GeekMetricCell 会将其换成“— 不可用”。 |
| 03-hidden-notice | 页面的 `Text(presentation.notice)` 改成空 Text，保留模型里的正确文案 | 完整和简化页原生可见文字中缺少 notice；help 不计入可见内容，不能靠 tooltip 误过。 |
| 04-legacy-heading-only | 只恢复错误标题，保持正确计数、同名遥测标签与候选 | 精确首个原生文字断言失败；说明测试不会把正确的遥测标签当作正确标题。 |

runner 首先在未施加反证的最终源码上运行目标方法，要求 exit 0 且明确存在该方法的 XCTest passed 记录，否则立即停止，不应用任何补丁。随后逐份施加、按方法过滤、记录失败名称与退出码，在 finally 中逆向还原并核对两个最终文件以及两份可能受反证影响的产品文件 SHA-256。日志独立写入 `logs/round3-counterexamples/`，不会覆盖第一、二轮证据。还原后须再次跑最终绿色测试，不能用 runner 的失败日志代替绿色结果。

### 主会话命令与交付

`prepared-r3/targeted-test-classes.txt` 沿用并重新核对 90 类完整清单，包含全部现有 `MenuBar*`、`MiniWindow*`、`MiniSensors*`、`Geek*` XCTest 类，保留 `UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`。没有新增或删除测试方法，核心类仍 20 项；本轮预期总体发现数量不因测试重写增加，但仍以主会话实际发现记录为准。

以下命令仅供主会话沙箱外执行。本轮未运行任何一条构建、测试、反证或提交命令。

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r3"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r3"
mkdir -p "$mini_cleanup_scratch/logs/round3"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
swift build --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 > "$mini_cleanup_scratch/logs/round3/build.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests[./]testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages' > "$mini_cleanup_scratch/logs/round3/native-readback.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/round3/focused-debug.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round3/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round3/targeted-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/round3/strict.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py"
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round3/after-counterexamples-green.log" 2>&1
```

逐条记录退出码、实际发现数量、跳过与失败名称。基线已通过的高度／宿主边界方法仍须随核心类绿色复验。若原生树为空、节点顺序与预期不符或 Swift 6 编译有误，将日志交回本实现会话；不得改回 OCR、放宽文案为乱码匹配或跳过目标测试。没有产品修改，本轮不增加新的性能任务；集成流程如重跑原有性能和私有 API 门禁，仍使用原预算和 allowlist。

`prepared-r3/` 分为 `01-test-readback.patch`（测试及辅助代码）、`02-handoff.patch`（当前状态提示与本节），附逐组 message、`all.patch`、manifest、static-checks、90 类清单、四份反证、runner、元数据生成器和主会话提交脚本。提交说明保留 `Generated-By: Codex (gpt-6.1-sol)`。最终源码已在 worktree 中；不要再次应用 all.patch，主会话验证和复核后由 `commit-prepared.py` 按 manifest 暂存两组补丁并提交。脚本本轮未执行。

本轮实际执行的检查仅为源码／文档审阅、补丁正反向可应用性、Python 产物语法解析、文件／产物 SHA-256、基线及修改范围核对；见 `prepared-r3/static-checks.json`。它不是 Swift 编译、XCTest 或反证通过证据。第三轮构建、测试、严格并发、红绿、反证、性能、截图、安装、提交均 NOT RUN。JEV 前轮调用被审批策略阻断，本轮未重试，未声称获得其判断。hygiene-2 合并后的两处测试工厂迁移仍按第二轮协调清单处理，本轮不扩大范围。

## 第四轮（基线 75023ec）

### 第三轮实测与问题定位

主会话将第三轮两组提交为 `cbfc244`、`75023ec`，trailer 为 `Generated-By: Codex (gpt-6.1-sol)`，并报告编译通过。本轮只读确认 HEAD 为 `75023ec476e169cb01e3e12b61250ccfe1c64887`，分支仍为 `task/r2-mini-cleanup-card`，开始修改前工作树干净。

只读核对 `~/Developer/.sc-build/r2-mini-cleanup-card/logs/main-test-3.log`：90 类 **1369 项，跳过 4，1 个失败方法、32 处断言失败**，全部在 `MiniWindowCleanupPresentationTests.testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages`。原 428／437 行分别希望读到可操作数和安全清理体积，但辅助函数最终只返回“当前可操作／可安全清理”等标签。

产品 `GeekMetricCell` 保持 `.accessibilityElement(children: .ignore)`、`.accessibilityLabel(model.title)`、`.accessibilityValue(model.value)`；子 Text 被隐藏，所以不能从标签找数值。第三轮辅助函数虽已通过 selector 尝试现代 `accessibilityValue`，本机桥接没有给这条路径提供可用文字；原树稳定条件只要求有任何文字，标签出现就足以提前通过，未要求指标值已出现。失败日志不足以进一步证明值究竟尚未发布，还是仅由 AXValue／值描述表示。本轮同时处理读取兼容与值的就绪条件，不修改产品或从展示模型补造原生值。

仓库 `ConceptLandingNativeLayoutRegressionTests` 的 `nativeValue` 已使用“现代 getter → 同一元素的 AXValue → 同一元素的现代／旧式 valueDescription”顺序。本轮复用其公开平台读取方式，并核对本机 AppKit SDK 的 NSAccessibilityProtocols.h／NSAccessibility.h 声明。旧式 attribute getter 是公开但已弃用的兼容接口，不是旧产品扫描明细，也不需要私有 API allowlist 变更。

### 修改范围与逐条断言依据

仍只修改 `MiniWindowCleanupPresentationTests.swift` 和本交接。核心 20 个测试方法保留；仅目标方法和测试辅助代码变化，其余 19 个函数体与基线逐字节一致。高度预留、真实宿主更新、旧模式回归、D47 模型测试均未重写。所有产品源码、`ScanStore.swift`、演示、性能政策／脚本、私有 API 清单、BOARD 和 DECISIONS 保持基线。

| 第三轮断言／辅助逻辑 | 第四轮改写及依据 |
|---|---|
| 指标数值在整棵树中 contains | 在单独托管的指标块和真正 GeekMetricSummaryGrid 中，按精确 label 找到对应指标，要求唯一，并用**同一个元素的 value** 与期望值精确比较；同一个元素的 help 继续核对说明。标签用 label，不拿标题充当值，也不从其他指标、notice 或遥测行找数字。完整／简化页继续保留实际标题、计数、候选和 notice 读取。 |
| “可安全清理”同名节点可能误配 | 摘要遥测行也有 help，所以不能仅靠 help 存在来辨认指标。配对的托管范围限定在真实指标网格，避免同名摘要标题／遥测标签进入查找；只按 label 选节点，不按期望 value 或期望说明挑节点。缺 hint、重复指标或错误值都会失败，不能用正确摘要数字代替错误指标。 |
| 每个节点通过 generic selector 读 value | 优先直接调用可用 NSAccessibilityProtocol 的 `accessibilityValue()`；SwiftUI 桥接未静态采用协议时仍尝试公开现代 selector。每个节点同时采集原生 AXValue／现代值描述／AXValueDescription，按上述顺序取同一元素的第一份非空文字。统一支持 String、NSAttributedString、NSNumber；缺失仍为 nil，不用 model、label 或期望值补齐。 |
| 有标签且树稳定即可结束 | 对本次托管的指标标签要求其原生值已存在，然后等待完整节点记录与探针尺寸连续两次稳定，且视图确实挂载、宽高非零。沿用最多 100 次原生 run loop 推进，没有固定 sleep；不等待 value 等于期望值，错误值应稳定后进入精确断言。 |
| 错误信息只有扁平文字 | 全树记录所有实际遍历到的节点，包括空容器、窗口和图片。断言及超时错误打印带层级的 `(role, label, value)`，并附节点类型、title／help 和四条值读取路径，方便定位 nil 来自哪里。可见文字的断言仍排除窗口、图片及 help，避免诊断信息或 tooltip 被用来满足可见内容。 |
| 原长文件名共享辅助函数仅保留字符串 | 调用点／测试函数体不改，辅助函数返回原生快照，由断言读取可见文字并在失败时输出全树。目标方法的候选、notice、负断言也输出对应托管树；没有恢复 OCR 或放宽空白以外的文本匹配。 |

会话／历史／首次扫描三态、中英文以及原单项、D47 多项、准备中、零历史、更新中、扫描中覆盖保留。第三轮对未知输入的不可用分支约束继续保留，因此旧 `--` 即使存在于原生值，也不能被当作正确的未知占位。AX 读取和布局探针仍不等同于逐像素截断验收；本轮没有声称解决第三轮已明确的这项验证边界。

### 红／绿／反证

已观察到的红为第三轮上述 32 处失败。第四轮绿色 XCTest、严格并发和反证均 **NOT RUN**，由主会话沙箱外执行。

`prepared-r4/counterexamples/` 保留前三轮对应的四份展示反证，并增加一份只破坏原生配对值的反证；本轮只生成、核对补丁可应用性，不向当前产品文件施加补丁。五份都只过滤目标方法，必须找到该方法实际 failed 记录；编译失败、未发现测试不算反证。

| 补丁 | 应使目标方法失败的原因 |
|---|---|
| 01-legacy-card | 恢复“上次扫描摘要”和空候选列表，原生标题／候选文字断言失败。 |
| 02-unavailable-placeholders | 未知值恢复 `--`，指标模型分支约束与原生未知值负断言失败；仍证明不能回到“— 不可用”。 |
| 03-hidden-notice | 把可见 notice Text 改空，完整与简化页原生可见文字断言失败；hint 不能替代 notice。 |
| 04-legacy-heading-only | 只改错误标题，保留同名正确遥测标签，摘要首标题断言仍须失败。 |
| 05-wrong-metric-value | 只把共享组件的“当前可操作”原生 accessibilityValue 改成 `999`；模型、可见数值 Text、其他指标和 notice 均正确。新 label／value 精确配对必须失败，不能因全树其他位置有正确计数而误过。这份仅为反证文本，不是本轮产品改动。 |

runner 沿用先绿后反证的防误判机制：先运行最终源码目标方法，要求 exit 0 且有该方法的 passed 记录，再逐份施加和运行；finally 逆向还原并核对两个最终文件及三份可能受反证影响的产品文件 SHA-256。第四轮日志单独写 `logs/round4-counterexamples/`，不覆盖第三轮。每次反证还原后及最终提交前，仍须复跑最终绿色定向测试。

### 沙箱外验证与交付

`prepared-r4/targeted-test-classes.txt` 仍为重新核对后的 90 类完整清单，含全部既有小窗相关类、`UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`。核心类仍 20 项；本轮没有增加发现数量。下列命令只供主会话执行，本轮未运行。

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r4"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r4"
mkdir -p "$mini_cleanup_scratch/logs/round4"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
swift build --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 > "$mini_cleanup_scratch/logs/round4/build.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests[./]testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages' > "$mini_cleanup_scratch/logs/round4/native-value-pairs.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/round4/focused-debug.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round4/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round4/targeted-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/round4/strict.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py"
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round4/after-counterexamples-green.log" 2>&1
```

逐条记录退出码、实际发现数量、跳过和失败。重点核对值到底由 modernValue、AXValue 还是值描述提供；若仍缺值或有多个同名指标，回交全树日志，不删配对断言、不回退成 model 期望值、不恢复 OCR 或跳过测试。集成流程的性能与私有 API 门禁仍用原预算和 allowlist；本轮未增加产品性能任务。

`prepared-r4/` 为两组：`01-accessibility-values.patch`（目标测试及辅助代码）、`02-handoff.patch`（当前状态提示与本节），附逐组提交说明、all.patch、manifest、static-checks、90 类清单、五份反证及 runner、元数据生成器和主会话提交脚本。trailer 保留 `Generated-By: Codex (gpt-6.1-sol)`。最终修改已在 worktree 中，主会话不要再次向该工作树应用 all.patch；验证与复核后才运行 commit-prepared.py。本轮未运行 runner 或提交脚本。

本轮实际完成的核对仅为源码／日志审阅、补丁差异及正反向可应用性、Python 产物语法、文件／产物 SHA-256、19 个未变测试函数体和受限文件比对；结果写入 static-checks.json。它不是 Swift 编译或 XCTest 通过证据。第四轮构建、测试、严格并发、红绿、反证、性能、截图、安装、提交均 NOT RUN。公开 AX 兼容路径及原生树唯一性仍须主会话运行确认；hygiene-2 工厂迁移保持原协调范围。JEV 此前被审批策略阻断，本轮未重试，也未声称获得判断。


## 第五轮（基线 b0f97d7）

### 输入证据与本轮范围

开始时 HEAD 为 `b0f97d7dba9af54a7bd9bfda59fd369a82906ffd`，分支仍为 `task/r2-mini-cleanup-card`，工作树干净。该合并包含 V0、r2-icloud-reads 和 r2-hygiene-2。本轮已读新版 RULES 全文与 D5、D48 及补充、D55、D60；不修改 ScanStore、这些集成批的实现或卫生工厂／守卫。

主会话报告第四轮 **90 类 1369 项，跳过 4，0 失败**，第四轮五份反证全部按预期失败且已恢复，私有接口检查通过。本轮只读核对既有日志，不重新运行。独立复核全文为 `~/Developer/.sc-build/r2-mini-cleanup-card-review/review-2.md`，结论“修后可合并”；时间线在 `r2/logs/probe-timeline-summary.txt`，截图 `r2/screenshots/probe-stale-props-sheet.png` 已查看。`r2/evidence/review-only-probe-r2.patch` 是复核私有副本的插桩证据，包含 Store 注入，不进入交付。

复核实测的红：新 ID 明细已在约 1.6 ms 交付，页面却继续“扫描中…”约 3.1 s，根重算才恢复；开始新扫描后旧 session 普通属性与新 details 不匹配，停在 preparing。父视图重算引起约 2–3 ms 重订阅提示；重开同键提示持续约 13–16 ms。原 132 pt 行区在取消与 1–3 行时有空白。以上是复核证据，不是第五轮实测。

改动六个文件：`Support/MiniWindowCleanupPresentation.swift`、`Views/MenuBarAdvanced/GeekCleanupView.swift`、`Views/MenuBarAdvanced/MenuBarGeekPanel.swift`、`MiniWindowCleanupPresentationTests.swift`、`MiniWindowDemoDataTests.swift` 和本交接。根 `MenuBarAdvancedStatusView.swift` 仍仅用 `@State` 持有模型；legacy 适配器、按钮三个导航动作、Store、扫描／清理操作、演示数据、缓存与性能预算均未改。

### 数据来源与生命周期的取舍

`MiniWindowCleanupSource` 仅封装现有三个 Publisher，根求值时不订阅、不 erase、不遍历候选。生产适配器接 `store.$cleanupScanSession`、`store.$isScanning`、`store.$scanHistorySummary`；测试可接 CurrentValueSubject，无需构造 Store。所有输入遵循 Store 的主 actor 发布契约。

展示模型 `start(source)` 在隐藏→可见时建一次订阅；先接扫描中和历史，后接初始会话，三项最新值由子页观察。可见期间再次 start 直接返回，不因父重算续订。只有会话发布调用 request；扫描状态／历史更新不重启明细整理。`stop()` 取消三项订阅、worker、提示任务，释放整个输入会话／历史，只保留至多四行的投影及 deliveredKey；可返回被取消任务给托管夹具等待退出。隐藏期间不做候选计算，重开从 Publisher 当前值恢复。

`GeekSmartCleanupPage` 只用 `model.presentation`，不再接根捕获的会话／扫描中／历史普通属性。会话仍是主窗口的那份 `ScanSession`，既有绿色总量与 D47 默认项口径、按大小降序和平手路径排序不变；没有另建扫描状态来源。历史仍用 `scanHistorySummary.latestStatus()`（无候选明细，O(1)），只在当前会话为 nil 时展示。旧 `StorageItem` 明细仅用于 legacy。按钮继续只打开主窗口的 green／largeFiles／memory 路由。

同身份复核继续显示旧投影；超过 **200 ms** 且请求还未完成时才发布“更新中…”及 45% 淡化。同键完成不重新交付、不访问共享缓存、不发布更新提示；真正慢的更新仍遵守 D32／D39。换请求、完成、隐藏均取消提示，Task 取消、请求代次和可见性三个条件拦截晚到发布。这里按本轮用户要求对 D39 的即时标记增加宽限，不改决定文件。测试注入可控 fingerprint 与 grace 等待，证明先后关系，不用墙钟猜测，也不增大性能预算。

### 窗高与真实行数

删除四行固定 frame，行 VStack 随 0–4 个真实项目自然布局；行最小高度 30 和间距 4 由 `GeekCleanupRowLayout` 共用，文字变高时容器自然增长。取消态没有项目行；未知状态不伪造行数或总量。

`GeekCleanupStableViewport` 在首份可用输入／会话投影完成布局后，按 visibilityID 接受一次自然尺寸。准备态不报窗高；异步交付后才锁定实际高度。根的既有测量通道通过 `GeekDetailContentMeasurement.canReportSize` 检查 readiness、当前可见代次，拒绝 initial unrestricted、旧页和隐藏页报告；其他页面和 legacy 默认 unrestricted，测量语义不变。具体容器用 VStack 保持身份，首次自然布局切换到滚动容器不会成为页面消失／重新订阅。

同一次打开期间如果新扫描结果更长，复用 `MiniWindowFittedPage` 在已锁定高度内滚动，不缩字号、不剪掉不可达的末行；离开重开再按新行数收紧。若结果减少，同一次打开暂留视口底部余量，重开消失。这是“每次打开只定一次高度”与“新结果仍可达”的明确取舍，余量不再是项目与说明之间的虚构行。首次没有会话／只有历史可以立即测量，首次有未投影会话则等待 worker；首开仍允许真实的“正在整理”短阶段，但不传 `--`，不重新引入“— 不可用”。实机是否只有一次上报、自然布局切换是否平滑仍须主会话录屏／插桩确认。

### 测试、夹具与改写旧断言（逐条）

核心类由 20 项变成 **27 项**：改写原高度测试为实际行高测试，新增七项；五个既有方法有必要改写，其余十四个函数体与基线逐字节一致。已通过第四轮的中英文三态原生读取方法函数体保持不变；仍按同一元素 label/value 精确配对，支持 String／NSAttributedString／NSNumber，超时及失败输出全树，不使用 OCR。

| 原断言／辅助方式 | 第五轮改写与依据 |
|---|---|
| `testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons` 要求普通 session/history 属性及 `.onReceive(erasedPublisher)` | 要求 Source 接线、model.presentation、start(source)/stop、禁止 onReceive/erase；P1-A/P2-A 明确要求模型拥有订阅。原三按钮、filter、主窗口路由、禁止新增执行入口、根 State／子页 ObservedObject 和尺寸列 fixedSize 断言保留。 |
| `testSameKeyRefreshAndReopenRetainTheDeliveryWithoutRebuilding` 立即要求 isUpdating=true | 改为宽限内 false、正常默认项说明、快复核全过程无 true 发布；仍要求旧明细同步保留、零空发布、零同键交付、一次构建。P2-B 的 200 ms 宽限是依据；时钟用 gate，不靠机器快慢。 |
| `testSameSessionContentChangesKeepOldRowsUntilTheLatestDelivery` 立即要求更新标记 | 改为宽限开始时 false，旧行保持；后续交付移除最大项的断言不变。另加 slow gate 验证宽限到达后的更新标记与旧行。 |
| `testHostedPreparationAndUpdatingReserveTheDeliveredPageHeight` 以固定框要求 preparing=四行高度 | 更名／改写为 `testHostedRowsUseTheirNaturalHeightIncludingCancelledAndOneToFourItems`：0–4 行逐项自然增高，新增行高度等于真实 row.fittingSize 加共用间距，取消=零行，更新=正常高度。另用真实 Page 的 readiness 和窗高探针验证 pending 零上报、首份交付一次定高、新四行结果不重定高且末项／notice 可滚到。P2-C/D 要求删除空槽；没有删掉“一次定高”的行为约束。 |
| `testHostedSmartPageOwnsUpdatesWithoutInvalidatingItsRetainingParent` 固定 session 属性、单一 Publisher，两处固定 40 ms sleep | 改用同一 Source 的三项 Publisher，真实 Page 与无障碍／布局宿主；按状态和原生布局探针等待，没有固定 sleep。仍断言同 ID 删除项目后父求值次数不增加。另加不同 ID/nil/扫描中/历史变化的中英文托管测试，防止旧测试锁住错误普通属性。 |
| `testLegacyScanStillUsesStorageItemsAndOriginalTitlesAndNotices` 直接 ScanStore/FanControlCoordinator | 改成 throws 与 `try ScanStore.makeForTests(for: self, …)`；风扇依赖用 `TestOperationFactory(for: self).fanControl(defaults:)`。D48 补充与新版 RULES §3 要求；原标题、StorageItem 列表、字节数、说明和按钮语义断言不变。 |
| `MiniWindowDemoDataTests` 直接构造 Store | 仅改为 `try ScanStore.makeForTests(for: self, …)`，其场景、惰性会话、禁执行、无历史持久化等断言逐字节保留。 |
| 辅助 waitForDetails 的固定 5 ms 轮询 | 用 bounded deadline + Task.yield 等待最新 worker 退出；宿主先 layout，原生值／尺寸沿用稳定探针；可控 gate 支持取消，隐藏测试显式 await 被取消任务后再断言晚到提示／交付。 |

新增方法覆盖：`testLayoutSettlesOnlyReadyCurrentOpeningAndRejectsRepeatedOrInvalidMeasurements`、`testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults`、`testHostedParentDoesNotRedrawWhenScanningFinishesNewIdentityOrHistoryChanges`、`testSourceSubscribesOncePerVisibleLifetimeAndDoesNoHiddenWork`、`testHostedParentRedrawDoesNotResubscribeOrRestartPreparation`、`testUpdatingNoticeWaitsForGraceRetainsRowsAndCancelsOnHide`、`testHidingBeforeGraceDoesNotPublishLateUpdatingNotice`。身份托管测试在真正 Page 中检查两种语言的扫描完成文案、新会话候选、按标签配对的可操作数，以及历史／首次扫描说明；父视图不观察输入且求值计数保持不变。强制父刷新测试确认父确实重算三次，但订阅仍三项各一次、会话零重发布、worker 不重启。

两处需要 Store 的测试分别验证 legacy 适配器和正式演示配置，保留 Store 有依据；其余新覆盖均测展示模型／真实 Page，不造 Store。工厂自动登记并清理 owned data root、operation home、临时偏好，并在 teardown 等待 Store 记录任务；不覆盖任何真实根，不手写新文件夹。模拟 `/MiniCleanupFixture` 候选只参与内存计算，无读写／移到废纸篓操作。挂载 NSWindow 是托管 XCTest 夹具，不启动产品应用。

静态检索确认两个受影响测试文件无直接 ScanStore 构造、无测试 Task.sleep，工厂和守卫保持基线字节；**TestPreferenceHygieneTests 的运行结果仍 NOT RUN**，主会话须验证，不能把“搜索无违规”称作守卫通过。

### 每项红／绿／反证

第五轮所有绿色测试与反证执行均 **NOT RUN**。每项的红来自 review-2 已记录现象或本轮静态可见的违规；对应新／改写测试和精确反证如下。原基线接口不满足新测试编译，不能将“编译失败”称作红；用下列基于最终接口的语义还原补丁得到真正 XCTest 红。

| 项 | 红的证据 | 主会话绿色验证 | 反证补丁与预期失败 |
|---|---|---|---|
| P1-A、P2-E | 扫描结束后仍扫描中 3.1 s／新 ID 交付被旧属性丢弃 | identity 托管测试，中英、新 ID、nil、扫描开始／结束、历史变化，父不重算 | 06 冻结页面三项旧输入；07 忽略 scanning；08 忽略 history；identity 方法必须出现 XCTest failed。 |
| P2-A | 根重算续订并重启 worker，约 2–3 ms 提示 | lifecycle 与强制父 redraw：每生命周期三项各一次、取消后隐页零工作、重开只收当前值 | 09 可见期间重复订阅；10 隐藏后保留订阅；lifecycle 方法失败。 |
| P2-B | 重开同键“正常→更新中→正常”13–16 ms | fast：宽限内零更新发布；slow：宽限后旧行+更新说明；late：隐藏后 join 无晚到提示 | 11 恢复即时标记；12 永不发布慢更新；13 绕过取消／代次／可见检查。fast／slow／late 对应方法失败。 |
| P2-C/D | 取消与 1–3 行固定预留132；行高变更会溢出而 fittingSize 无感 | rows 实测0–4行；settlement gate；真实 Page pending零上报、仅一次定高、后续可滚到最后 | 14 恢复132；15 pending提前定高；16 每次结果重定高；17 改成不可滚动框；20 根忽略ready。rows／viewport／settlement 方法失败。 |
| hygiene | 合并后的守卫禁止本批两处直接构造；源码尚可见 | TestPreferenceHygieneTests 真实扫描测试源码 + 旧模式、演示测试 | 18/19 分别恢复 core/demo 直接构造；只运行卫生守卫，必须报告指定方法 failed；不运行不安全构造方法。 |

另将第四轮五份反证 **01–05** 重新生成到第五轮源码上，仍验证旧标题／旧读取空行、`--` 不可用、隐藏说明、错误标题和错误原生指标值；必须使已验证的原生三态目标方法失败。反证合计 **20 份**，详情及指定完整 class.method 在 manifest 中；只检查了补丁适用性，没有应用任何反证到当前最终源码。

runner 将卫生守卫源码根显式指向当前 worktree 的 Tests，避免沿用主会话旧副本环境；先运行所有反证目标的最终源码，要求每个目标被发现且 passed；再逐个施加补丁，要求其指定 XCTest 失败，编译失败／未发现／无关方法失败不算成功反证。finally 还原并核对全部最终及保护文件 SHA；最后再跑所有目标绿色，日志独立放 `logs/round5-counterexamples/`。完整93类门禁仍须另跑。

旧第二轮反证证据按 review-2 补齐归属：复核员在私有副本跑过 **05/06/07/15/17/19 六份，失败数11/7/1/1/15/1；还原后六项绿色**，路径 `r2/logs/cx-summary.log` 及 `r2/logs/cx/`。这是复核报告的运行记录；其他十三份没有执行记录，不标通过。第五轮用新的20份补丁和runner验证当前实现，不把旧报告推算成第五轮结果。

### 主会话命令、定向清单与演示验收

`prepared-r5/targeted-test-classes.txt` 在原90类基础上增加 `TestOperationFactoryTests`、`TestFixtureOwnershipTests`、`TestFixtureLifecycleTests`，共 **93 类**；原有 `TestPreferenceHygieneTests`、`UIConsistencyRegressionTests` 已在90类内，保持唯一条目。逐个类名已对源码核对；全部 MenuBar／MiniWindow／MiniSensors／Geek 既有类仍在清单中。发现测试总数须按主会话输出记录，不能把核心27项或第四轮1369外推为合并后总数。

以下命令仅供沙箱外，**本轮未执行**：

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r5"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r5"
mkdir -p "$mini_cleanup_scratch/logs/round5"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
swift build --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 > "$mini_cleanup_scratch/logs/round5/build.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|TestPreferenceHygieneTests|TestOperationFactoryTests|TestFixtureOwnershipTests|TestFixtureLifecycleTests|UIConsistencyRegressionTests' > "$mini_cleanup_scratch/logs/round5/focused-debug.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round5/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round5/targeted-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|MiniWindowDemoDataTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests' > "$mini_cleanup_scratch/logs/round5/strict.log" 2>&1
python3 script/check_private_api.py > "$mini_cleanup_scratch/logs/round5/private-api.log" 2>&1
script/verify_menu_bar_performance.sh > "$mini_cleanup_scratch/logs/round5/menu-performance.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py" > "$mini_cleanup_scratch/logs/round5/counterexamples.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round5/after-counterexamples-green.log" 2>&1
```

分别记录退出码、发现数量、跳过与失败。机器空闲时跑性能门禁，预算不改；该既有门禁不直接涵盖本页的闪动／每次测量次数，仍须复核插桩或录屏。新版 RULES要求主会话用完临时 Release／strict／反证／截图构建副本即清理，仅留日志和证据；本轮不删除他人的构建。

演示参数不变：`--debug-mini-window-demo-data --capture-menu-bar-panel-scenario=menu.cleanup.afterSmartScan --capture-menu-bar-panel-directory=<本批独立截图目录> --debug-mini-window-appearance=dark/light -app.language zhHans/english`；D47 追加 `--debug-smartscan-d47-rows`。默认两行、D47四行应按真实数收紧，取消0行与1/2/3行需要私有注入场景核对，不能以已有演示场景声称覆盖取消。复核插桩补丁只能在主会话独立副本中适配新Source／Page接口后重跑，**不能原样应用到新HEAD**，也不能把其中ScanStore改动提交。验收 finish-while-open、新扫描开始／结束、根无关重算、同键重开：实时结果显示；快复核无更新闪；慢复核有标记；每次打开只一次真实尺寸上报；后续更长结果末行和说明能滚到；中英／深浅色均核对。暂无新增正式演示状态接口。

### 交付与剩余限制

`prepared-r5/` 三组为 `01-visible-cleanup.patch`（模型、Page、测量门禁）、`02-regressions-and-hygiene.patch`（核心测试和演示工厂迁移）、`03-handoff.patch`（本轮状态及本节）。附 all.patch、逐组提交说明、manifest、static-checks、93类清单、20份反证、runner、commit-prepared.py、generate-prepared.py 和 README；trailer 为 `Generated-By: Codex (gpt-6.1-sol)`。worktree 已含最终修改，**不要再次向它应用 all.patch**。主会话完成构建／测试／反证／独立复核后才运行提交脚本，本轮未执行。

本轮实际检查仅为源码与证据阅读、git diff --check、正反向补丁可应用性、Python AST、类名／方法范围、文件和产物SHA、保护文件基线比对。没有 Swift 编译、XCTest、反证、严格并发、性能、截图、应用启动、安装或提交；static-checks.json 的 PASS 仅表示这些静态检查。

保留 review-2 的测试边界：AX完整字符串不能证明视觉不截断，指标help不能独立证明屏幕说明，源码接线守卫不能代替运行期；本轮实际Page身份托管／订阅计数补上P1-A，实际行高与scroll document末端检查补上固定frame溢出盲点，但实机观感、首次测量与滚动行为仍待沙箱外确认。单次打开结果缩短的底部余量是明确取舍；字体、密度、语言改变后的重新定高需按现有页面生命周期核对，不能将27个核心方法等同于完整产品验收。没有尚待ScanStore提供的接口，也没有绕道复制业务Store。

JEV 的候选取舍调用本轮被审批策略拒绝：`MCP tool call requires approval, but approval policy is never`。未得到判断，不声称JEV已认可；本轮判断依据是用户要求、review-2与源码。阻断仅涉及JEV，未阻止已授权代码与交付准备。


## 第六轮（基线 `7efe80e2e`）：托管测试宿主生命周期与等待诊断

### 证据与范围

主会话提供第五轮提交 `2534ada9`、`ea0b0ede`、`4647bc74`；随后将测试中的 `CGSize(width: 312, height: .infinity)` 修为 `CGFloat.infinity`，提交 `7efe80e2e`。本轮基线完整值为 `7efe80e2e8b5b30a64575cf6d4babe28d7870a57`，分支仍为 `task/r2-mini-cleanup-card`。工作区开始时干净，编译修正保持基线。

已阅读 `logs/main-test-6.log`：93 类共 1397 项、跳过 4、2 个 unexpected failures；`testHostedParentDoesNotRedrawWhenScanningFinishesNewIdentityOrHistoryChanges` 与 `testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults` 分别约 1.270 s、1.305 s 结束，均仅报告 `InvalidTransition { phase: idle, targetPhase: failed(deinit) }`。同类其他托管测试及第四轮原生标签／值三态测试通过。这是主会话运行证据，不是本轮绿色结果。

主会话将问题定位为异步等待中宿主释放，并要求沿用 V1 的先隐藏、延后拆卸和强持有做法。本轮静态检查发现原宿主已将窗口和裸 NSHostingView 存为强属性，但没有 hosting controller 或 XCTest 生命周期所有权；`defer` 会立即清空 contentView 并关闭窗口。原日志没有等待位置，不能仅凭它证明首次释放点，也不能排除原生探针超时后立即拆卸掩盖错误。本轮修复所有权和拆卸边界，并保留真实等待失败的诊断，供主会话确认根因；未读取或声称复用了 V1 的实现文件。

只改 `Tests/StorageCleanerMacTests/MiniWindowCleanupPresentationTests.swift` 和本文。**整个 Sources 树与基线相同**；不改 ScanStore、展示逻辑、订阅、窗高、按钮、演示配置、性能预算、私有接口清单、测试工厂或卫生守卫。

### 修复与取舍

| 要求 | 具体改动 | 目的与验证边界 |
|---|---|---|
| 全部 await 期间强持有 | 每个 readback 宿主接收当前 XCTestCase，登记显式 `[self]` 的 async teardown block，持有宿主直至收尾完成。Debug 直接复用 `DesignSystemV2Tests.swift` 的 `V0LayoutHost`，由其强持有 NSHostingController；Release 用同样的强 controller 属性。窗口 `isReleasedWhenClosed` 为 false。 | 局部变量、框架窗口引用和 ARC 活跃范围不是唯一所有者。四处真实 Page 宿主及同步 `hostedSnapshot` 帮助都登记同样的生命周期所有权，避免共享帮助仍留薄弱调用点。 |
| 最后断言之后拆卸 | 测试现有 defer 保留 `mounted.close(); model.stop()`；close 只 orderOut 隐藏，保留内容、窗口和 controller。XCTest teardown 再隐藏，等待一个主队列轮次，随后才 detach contentViewController 并关闭窗口；强捕获保持到 teardown 返回。 | 正常、抛错及两种语言循环都在最后断言／原始错误记录之后收尾。队列轮次用 continuation，不设固定 sleep；没有取消断言或吞掉等待异常。 |
| 有界稳定等待 | 两个失败方法初次挂载与各次 AX 读取前等布局稳定。Debug 调用现成 V0 `frames(required:)`，要求 `cleanup.readback.content` 与 `v0.viewport`，保留原 160 次、每次 5 ms、连续三次相同帧的帮助边界。Release 对现有 native content probe 至多 100 次布局/yield，要求连续稳定；不依赖 debug-only 类型。 | 不等待预期文案、数值或窗高。原 AX 的 100 次／连续稳定读取与模型的 5 s deadline 保持；没有放宽行为阈值。V0 的有界轮询属于复用探针等待，并非固定延迟后假定就绪。 |
| 超时明确报缺失项 | V0 自身先 XCTFail，列真实缺失 ID（全出现但不稳定则列 required IDs），再抛错误；本宿主 AX 超时先 stderr + XCTFail，列内容／attachment／文字／标签对应 metric 缺失项、当前尺寸和完整 `(role,label,value)` 树。两个方法分别标记 initial mount、首交付、新身份、历史等阶段。尺寸上报等待另列 `cleanup.page.settled` 就绪标识，模型等待列 visible/preparing/source 与宿主状态。 | 这些 ID 是测试探针或明确的测试就绪标识，没有给产品添加无障碍内容。XCTest 与日志先保留原始失败，避免之后只见通用 failed(deinit)。 |

新增 `testReadbackHostIsRetainedAcrossAwaitAndCloseOnlyHidesUntilTeardown`：先只保留宿主／窗口／controller 的弱引用，清空本地强变量并跨一个主队列轮次，确认 XCTest 所有权仍维持三者；隐藏后再跨队列轮次，确认仍 attached、对象身份不变且窗口不可见，并继续读取真正托管的文字。测试结束由已登记 teardown 拆卸。它不创建 ScanStore、偏好、文件或产品执行入口。

### 原断言逐条保留

| 原方法 | 原行为断言与本轮处理 |
|---|---|
| `testHostedParentDoesNotRedrawWhenScanningFinishesNewIdentityOrHistoryChanges` | 中英初始“扫描中”、首次完成的候选／默认项说明／可操作数、nil 会话扫描中加历史、新 ID 的会话与明细 ID／候选／数值、零绿色历史说明、首次扫描说明均保留；父求值次数不变的最终断言及不可用值反断言不变。只改变读取前的稳定等待及失败上下文。 |
| `testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults` | pending 零尺寸上报、首交付真实一行 fittingSize、native probe 与首尺寸相同、较长交付仍只有 `[firstSize]`、后续 viewport 高度不变、document 显著高于视口、滚到末端并可见底部边界全部保留。原 inline snapshot 高度断言改为先 await 得到 `laterSnapshot` 再断言同一高度与原 accuracy 1；不是改期望值。 |
| `testHostedSmartPageOwnsUpdatesWithoutInvalidatingItsRetainingParent`、`testHostedParentRedrawDoesNotResubscribeOrRestartPreparation` | 仅宿主初始化新增 `testCase: self`，以登记相同的强持有收尾。两方法所有断言逐字保留。 |
| `testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages` 与其他原方法 | 函数体保持基线；共享宿主改为 controller 与 teardown 所有权，原标签／同元素值配对、说明来自 visible Text、禁止“— 不可用”及无障碍完整树诊断不变，未引入 OCR。 |

原 27 个方法全部保留，四个方法受宿主调用／等待调整，另 23 个函数体保持基线；新增一个生命周期方法，核心共 28 个。辅助 `waitForDetails` 仍要求最新请求退出，超时 preparing 时在记录失败后明确抛出；不会把保留的旧交付当作新请求完成。产品接口、断言期望、精度、滚动阈值、扫描状态语义、D47 与 hygiene 工厂均不变。

### 红／绿／反证

本轮绿色执行、反证执行均 **NOT RUN**。现有红为主会话上述两项失败；新生命周期测试的反证是以下精确改坏补丁，不以构建失败当红。

| 项 | 沙箱外绿色目标 | 反证与应出现的失败 |
|---|---|---|
| 强持有宿主到 teardown | 新生命周期方法 + 原两个失败方法 | `21-weak-host-teardown-lease.patch` 将登记闭包改为 weak self；新测试清空本地强变量跨 await 后，XCTUnwrap 必须报告 XCTest 没有继续持有宿主。 |
| close 只隐藏、延后拆卸 | 同上，原窗口与 controller 身份断言 | `22-immediate-host-dismantle.patch` 恢复 close 立即 detach/close；新测试的 attached／controller 身份断言或随后原生读取明确失败。 |
| 真正等待缺失探针时有诊断 | 新生命周期方法，Debug V0 布局路径 | `23-missing-content-probe.patch` 改坏实际发布的 content probe ID，等待仍要求原 ID；该方法必须 XCTest failed，日志必须含 `Layout probes did not appear` 与 `cleanup.readback.content`。没有把超时改成 success 或取消稳定要求。 |
| 父不重算时仍随会话更新 | 原 identity 方法，中英文全部断言 | 保留重基 `06-stale-page-inputs`、`07-ignore-scanning`、`08-ignore-history`，指定 identity 必须失败。 |
| 首尺寸只上报一次，后续更长可滚动 | 原 viewport 与 settlement 方法 | 保留 `14-fixed-four-row-height`、`15-settle-pending-layout`、`16-resize-every-delivery`、`17-clip-later-results`、`20-ignore-parent-readiness`，原指定方法必须失败。 |
| 三态原生文案／数值和 hygiene | 原三态方法／卫生守卫 | 保留 `01–05` 和 `18–19`，禁止不可用占位、旧读取路径、隐藏说明、错误标题／metric；工厂反证只运行源码守卫，不执行不安全 Store 方法。 |

第五轮 20 份反证全部重新对本轮最终源码生成，新增三份共 **23 份**；只是 `git apply --check`，未向 worktree 应用或运行。runner 先要求全部目标发现且通过，再逐份施加、只认指定 XCTest 失败；新增缺探针例还校验指定诊断文字。runner 将 Darwin 的 `-[Module.Class method]` 与 SwiftPM 的 `Class.method`／`Class/method` 规范为同一精确 class.method（本次日志是前一种）；避免沿用旧 runner 的子串匹配漏认已发现的测试。finally 还原且验 SHA，最后所有目标再次绿色。日志独立写 `logs/round6-counterexamples/`。所有反证均不得将仅有编译错误、缺测试、无关失败视为成功。

### 主会话命令与交付

`prepared-r6/targeted-test-classes.txt` 保留第五轮全部 93 类，新增直接复用的帮助所在 `DesignSystemV2Tests`，共 **94 类**；`TestPreferenceHygieneTests`、`UIConsistencyRegressionTests` 及全部既有小窗相关类保持唯一条目。V0 的类及 layoutProbe 是 Debug-only，Release fixture 走 native probe fallback；Release 不应将未发现 DesignSystemV2Tests 误报为成功运行了它。实际发现／跳过／失败数量以主会话本轮输出为准。

以下仅供沙箱外执行，本轮未运行：

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r6"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r6"
mkdir -p "$mini_cleanup_scratch/logs/round6"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
mini_cleanup_focus='MiniWindowCleanupPresentationTests[./](testHostedParentDoesNotRedrawWhenScanningFinishesNewIdentityOrHistoryChanges|testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults|testReadbackHostIsRetainedAcrossAwaitAndCloseOnlyHidesUntilTeardown)'
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_focus" > "$mini_cleanup_scratch/logs/round6/host-focus.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round6/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter 'MiniWindowCleanupPresentationTests' > "$mini_cleanup_scratch/logs/round6/host-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|DesignSystemV2Tests|TestPreferenceHygieneTests|UIConsistencyRegressionTests' > "$mini_cleanup_scratch/logs/round6/host-strict.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py" > "$mini_cleanup_scratch/logs/round6/counterexamples.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round6/after-counterexamples-green.log" 2>&1
python3 script/check_private_api.py > "$mini_cleanup_scratch/logs/round6/private-api.log" 2>&1
```

逐项记录命令退出码、发现测试名／数量、跳过与失败。新增的三个焦点方法应全部被发现；identity 仍在单方法内覆盖中英。若仍失败，先看具体阶段、缺失 ID 和 AX 树，再定位宿主／探针，不能删断言或扩大窗口高度／数值等待门槛。沿用 RULES，Release／strict／反证临时构建用完由主会话清理，保留日志；本轮没有删除他人的构建。产品未变，无需新增截图场景；第五轮演示参数、产品视觉验收和性能预算继续有效。

`prepared-r6/` 两组：`01-host-lifetime-and-waits.patch`（唯一测试源码），`02-handoff.patch`（本文），附 all.patch、逐组提交说明、manifest、static-checks、94类清单、23份反证、runner、commit-prepared.py、generate-prepared.py、README。trailer 为 `Generated-By: Codex (gpt-6.1-sol)`。最终修改已在 worktree 中，**不要再向它应用 all.patch**；主会话完成验证与复核后才运行提交脚本，本轮没有提交。

实际检查仅源码／日志阅读、`git diff --check`、最终与保护文件基线核对、Python AST、方法／断言范围、类名、SHA、补丁正反向 `--check`；不构成 Swift 编译、XCTest、严格并发或运行期验收。仍须主会话验证两项原失败和新生命周期方法、94类门禁、Release fallback 及23份反证；若等待仍超时，新增诊断是调查依据，不能在未运行时宣称 deinit 已消失。本轮没有 JEV 判断；第五轮已记录其调用被审批策略拒绝，本轮未重试，判断基于用户要求和源码。


## 第七轮（基线 `77e7eb9`）：可见窗口的原生无障碍读取

### 主会话证据与本轮范围

主会话已将第六轮两组提交为 `051327c`、`77e7eb9`；本轮基线完整值为 `77e7eb9ac0740d0f063fc55baf2964797afc0623`，分支 `task/r2-mini-cleanup-card`，修改前工作区干净。已阅读 `failures-r6.txt` 与 `logs/main-test-7.log`：编译通过，94 类共 1415 项、跳过 4；两个方法失败，日志合计 4 条失败（2 条显式 XCTFail、2 条抛错报告），其中 2 unexpected。原 `InvalidTransition … failed(deinit)` 不再出现；本轮不重复修改已奏效的所有权边界。

identity 失败在 `identity initial scanning: zhHans`，native probe 为 `(312,272)`；viewport 在 `viewport first delivery`，尺寸为 `(312,306)`。均 attached=true、mounted=true，没有缺失原生布局探针，但没有页面文字或指标值。`failures-r6.txt` 只保留首行，完整日志的树并非零节点：有 NSHostingView 的 AXGroup、HostingScrollView 的 AXScrollArea、窗口和装饰节点，页面内容没有展开。已通过的第四轮三态方法仍能读取独立 cell／card／content，耗时约 5.557 s；生命周期方法也通过。不能从这些证据断言是产品数据缺失，也不能把失败摘要误当完整树。

区别在于两个失败方法读真实 `GeekSmartCleanupPage`，其中已有稳定视口和 ScrollView；原生三态方法主要托管独立组件。第六轮 Debug 的 AX 宿主采用从不 orderFront 的 V0 几何窗口；根尺寸正确不足以证明滚动内容 AX 已生成。本轮采用用户指定的可见窗口读取方式，并复用已有 `ConceptLandingNativeLayoutRegressionTests.nativeChildren` 对滚动 documentView 的公共关系遍历，不合成节点或抄展示模型当文字。

仍只改 `Tests/StorageCleanerMacTests/MiniWindowCleanupPresentationTests.swift` 和本文。产品 Sources 全部保持基线，不改 ScanStore、页面、数据源、缓存、窗高、按钮、演示、预算、工厂或卫生守卫；`CGFloat.infinity` 修正保留。

### 修改与依据

| 修改 | 实现与理由 |
|---|---|
| AX 统一到原生宿主 | `CleanupAccessibilityReadbackHost` 在 Debug／Release 都强持有直接创建的 NSHostingController 和 borderless NSWindow，沿用已验证读取帮助的 native getters、原生背景探针和 accessibilityEnabled 环境。AX 不再使用 V0LayoutHost；未创建第二份页面副本，避免重复订阅或让父视图计数失真。V0 及其测试源码不改。 |
| 读取时窗口可见 | 初始化 fixture 时 orderFront 并布局，在父计数采样之前完成初次显示；每次 settledSnapshot／同步 snapshot 进入读取前都 orderFront、layout 并确认 isVisible。不 makeKey、不激活应用、不改系统无障碍偏好。隐藏后再次读取会重新显示同一个保留的宿主，不重建窗口／controller。 |
| 等真正的树和同元素值 | 所有配置统一使用现有 native content probe 的 100 次 layout/yield、连续稳定判断；AX 仍以至多 100 次 RunLoop 轮询等待真实文字、所需标签的同元素 value/help 和尺寸稳定。没有等待“正确”的值或说明，没有加固定 sleep，没有扩大窗口高度或行为精度。Debug 原 V0 帧等待退出 AX 帮助；产品尺寸上报仍由真实 Page 的 readiness/probe 决定。 |
| 展开滚动文档的原生关系 | 保留 children／navigation／contents 三项公共 getter，另对 NSScrollView 遍历实际 documentView，沿用 ConceptLanding 的处理方式；ObjectIdentifier 去重保持，值仍从该节点的 String／NSAttributedString／NSNumber getter 及同元素 AXValue 兼容路径读取。没有私有 API、OCR、虚构字符串或全树值误配。 |
| 保留诊断与生命周期 | 诊断增加 visible 与宿主类型，缺可见窗口时先报告 `cleanup.readback.visible-window` 和完整树，再抛错；文字／metric／尺寸超时仍输出完整 `(role,label,value)` 树。XCTest `[self]` teardown 所有权、close 仅隐藏、跨主队列轮次后才 detach/close 原样保留。 |

新增 `testVisibleNativeScrollReadbackPublishesLabelsValuesAndTextInBothLanguages`：托管真正的 SwiftUI ScrollView、产品 GeekMetricCell 和说明 Text，中英逐项检查真实 scrollView、窗口可见、标题对应的同元素值／help、实际说明；隐藏后确认仍 attached，再读取时检查同一保留宿主重新显示且原生内容仍可读。仅纯数据会话与托管组件，无 Store／文件操作或持久偏好写入；语言切换沿用现有 volatile argument scope，并在 defer 恢复。原生命周期方法另增加一条读后窗口可见断言；其隐藏后仍 attached 和对象身份断言保留。

### 原断言与红／绿／反证

两个原失败方法 **函数体逐字节保持基线**：identity 的中英扫描完成／新会话／历史／首次扫描、标签对应值、不可用反断言和父求值计数全部保留；viewport 的 pending 不上报、实际一行 fittingSize、仅一次 `[firstSize]`、后续同高度、document 高于视口及滚至末端阈值全部保留。已通过三态方法函数体保持基线。原 28 个方法无删除，27 个原函数体不变，生命周期方法只加可见性断言；新增一个后核心共 29 方法。

本轮运行绿色和反证均 **NOT RUN**。红来自第六轮主会话实际日志；不能把 `git apply --check` 当反证成功。各项沙箱外做法：

| 修复／保持项 | 绿色目标 | 反证及指定失败 |
|---|---|---|
| 可见窗口读取真实滚动内容 | 原 identity／viewport、新滚动读取方法，第四轮三态与生命周期方法 | `24-hidden-readback-window.patch` 去掉 fixture 的两个 orderFront；新滚动方法必须报告指定 XCTest failed，日志含 `cleanup.readback.visible-window`、visible=false。`25-r6-offscreen-v0-readback.patch` 只将整个共享宿主还原成已提交第六轮实现，两项原失败方法必须都失败，日志含各自阶段及 Native text/layout/values did not settle。 |
| 真实 native content 探针诊断 | 生命周期方法与原两个方法 | `23-missing-content-probe.patch` 更新为将实际背景探针的 mounted 回报改坏，使 content probe 始终缺失；必须指定方法失败且日志含 Native layout did not settle 与 cleanup.readback.content。V0 帧 ID 不再用于本帮助，因此不能沿用旧补丁宣称仍覆盖。 |
| 保留强持有／延后拆卸 | 原生命周期方法 | `21-weak-host-teardown-lease`、`22-immediate-host-dismantle` 重新对最终源码生成，继续要求指定方法失败。 |
| 原数据、单次定高、可滚动、三态、hygiene | 原 identity、viewport、settlement、三态及卫生守卫 | 原 `01–20` 全部重基保留，06/07/08 仍守父不重算时状态更新，14/15/16/17/20 守尺寸及滚动；工厂绕过仅执行源码守卫。 |

反证共 **25 份**。runner 保留精确 class.method 名称配对，先要求全部目标发现并通过，再改坏、只认指定 XCTest failed，带诊断要求的例子另核对日志；25 要求两项原方法均失败，编译失败或只有一个目标失败不算该例成功。finally 还原且验 SHA，最后目标重跑绿色。均未施加到本轮最终 worktree，执行日志放 `logs/round7-counterexamples/`。

### 主会话命令与交付

定向清单 `prepared-r7/targeted-test-classes.txt` 保留第六轮完整 **94 类**，含 UIConsistencyRegressionTests、TestPreferenceHygieneTests、DesignSystemV2Tests 与全部既有小窗类。没有因为 AX 不再用 V0 就缩减既有门禁；实际总项数仍以本轮输出为准。

以下仅供沙箱外执行，本轮未运行：

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r7"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r7"
mkdir -p "$mini_cleanup_scratch/logs/round7"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
mini_cleanup_focus='MiniWindowCleanupPresentationTests[./](testHostedParentDoesNotRedrawWhenScanningFinishesNewIdentityOrHistoryChanges|testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults|testVisibleNativeScrollReadbackPublishesLabelsValuesAndTextInBothLanguages|testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages|testReadbackHostIsRetainedAcrossAwaitAndCloseOnlyHidesUntilTeardown)'
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_focus" > "$mini_cleanup_scratch/logs/round7/host-focus.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round7/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter 'MiniWindowCleanupPresentationTests' > "$mini_cleanup_scratch/logs/round7/host-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|TestPreferenceHygieneTests|UIConsistencyRegressionTests' > "$mini_cleanup_scratch/logs/round7/host-strict.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py" > "$mini_cleanup_scratch/logs/round7/counterexamples.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round7/after-counterexamples-green.log" 2>&1
python3 script/check_private_api.py > "$mini_cleanup_scratch/logs/round7/private-api.log" 2>&1
```

分别记录发现方法、退出码、跳过、失败及 visible/树诊断；焦点五项必须全部发现。托管窗口是 XCTest 惰性 fixture，命令由主会话执行，不启动已安装产品，不请求辅助功能权限或改变系统偏好。按 RULES 由主会话清理用完的临时构建；本轮未删除任何构建副本。演示参数及产品视觉／性能验收仍沿用第五轮，不新增产品场景。

`prepared-r7/` 两组：`01-visible-native-readback.patch`（唯一测试源码），`02-handoff.patch`（本文）；附 all.patch、逐组提交说明、manifest、static-checks、94类清单、25份反证、runner、生成／提交脚本和 README。trailer 为 `Generated-By: Codex (gpt-6.1-sol)`。最终修改已在 worktree，**不要再向它应用 all.patch**，主会话完成沙箱外验证和复核后才提交。

实际检查仅源码／日志阅读、git diff --check、方法／断言与类名范围、全部产品源码基线比对、Python AST、哈希和补丁正反向 --check；构建、XCTest、红绿、反证、严格并发、性能、截图、安装和提交均 NOT RUN。仍待主会话确认可见窗口的滚动文档树能生成且两个原方法通过；若失败，优先看 visible、宿主／scroll document 节点和阶段，不能以读模型替代页面文字或删行为断言。本轮没有 JEV 结果；之前的调用被审批策略阻断，本轮未重试。


## 第八轮（基线 `efae19b`）：实际 body 字段与原生滚动几何

### 主会话证据与放弃滚动 AX 读取的理由

第七轮两组已由主会话提交为 `7ed0e62`、`efae19b`；本轮基线为 `efae19b5a2dd87af6fe71a2b3883b444e1c8d2e6`，分支不变。已阅读 `logs/main-test-8.log`：编译通过，94 类 1416 项、跳过 4；三个方法失败，合计 6 条失败记录（3 条显式 XCTFail、3 条 caught error，其中 3 unexpected）。三个方法分别为 identity、viewport 和上一轮新增的滚动 AX 读取方法。`testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages` 仍通过。

与第六轮相比，窗口确实 visible=true；identity 初始扫描的 nativeSize 为 `(312,272)`，viewport 首交付为 `(312,306)`，mounted=true、attached=true、dismantled=false，原生 content 布局探针齐全。这次完整日志的内容树仍只有下列节点（摘自 identity 首个失败诊断；role、label、value 原样，去掉重复 nil 的扩展属性）：

```text
(role: Optional("AXGroup"), label: nil, value: nil) type=NSHostingView<AnyView>
  (role: Optional("AXScrollArea"), label: nil, value: nil) type=HostingScrollView
    (role: Optional("AXUnknown"), label: nil, value: nil) type=DocumentView
(role: Optional("AXWindow"), label: nil, value: nil) type=NSWindow
```

DocumentView 后没有任何内容子元素。可见窗口、真实 controller、实际 documentView 遍历和正确布局尺寸仍不足以让这个 SwiftUI ScrollView 测试宿主暴露 AX 子树；不能继续把空树当产品没有更新的证据。遵照本轮用户要求，三个滚动托管方法放弃 AX 文字／值读取，使用实际页面内 DEBUG 探针。没有滚动容器、已通过的三态 AX 方法及其共享 NSAccessibility 帮助保持基线，包括同一元素的 label/value/help 配对、兼容 getter、完整树诊断与原生命周期方法。

### 改动、数据读回与编译边界

| 文件／位置 | 改动与理由 |
|---|---|
| `Support/LayoutProbe.swift` | 在原有整个文件的 `#if DEBUG` 内增加 `GeekCleanupRenderedField`、稳定字段 ID、PreferenceKey 与修饰器，复用 V0 的 `LayoutFramePreferenceKey`。字段不持有模型／会话，只存 body 使用的 heading、notice、metric、item 字符串；行和视口的 frame 使用同一具名 SwiftUI 坐标空间，避免 NSView flipped／屏幕坐标换算误差。原 V0 probe 定义不改。 |
| `GeekCleanupView.swift` | 仅 DEBUG 分支：metric grid 使用 `renderedTiles` 同一数组渲染和上报；status card 的真实标题与 heading 探针共用 `renderedTitle`；实际说明 Text 与 notice 探针共用 `renderedNotice`；项目行的真实文件名、大小、类别与 item 探针共用三个局部值。实际 ForEach 行加 frame 探针，稳定视口加具名空间和 viewport frame 探针。没有独立生成一份页面或从测试复制展示字符串。 |
| `MiniWindowCleanupPresentationTests.swift` | 新增 DEBUG-only 只读 Preference recorder／snapshot 与宿主包装，直接托管现有 `CleanupRetainingTestHost → GeekSmartCleanupPage`。复用原生宿主对窗口／controller 的强持有、真实 scrollView、native 布局等待及 close 只隐藏；包装自身也登记 XCTest 强捕获的异步 teardown，最后断言后先隐藏，再交由既有 teardown 延后拆卸。读取 fixture 不调用 AX snapshot，也不读 model.presentation 合成字段。 |
| 本文 | 记录空树、替换读取方式、原行为断言、反证、条件编译与主会话命令。本轮无新演示场景。 |

所有新增探针类型、Preference 回调数据、GeometryReader 以及产品中的调用均在 `#if DEBUG` 内。为让真实 Text／grid 输入与探针共用局部值，相关 Debug body 显式 return；`#else` 保留原 Release body。生成器做文本层的 DEBUG 条件选择，比较两个改动 Sources 的 Release 选中源码与基线：逐字节一致。此检查能说明 Release 选中源码没有探针类型、构造或调用，**不等于 Release 编译或二进制检查通过**。其余 471 个追踪 Sources 文件逐字节保持基线，包含 ScanStore、模型订阅／缓存、MiniWindowFittedPage、按钮行为、扫描与清理执行路径；性能脚本和预算不变。

三个使用新探针的托管方法与辅助代码跟随 DEBUG 条件编译；用户要求 Release 不含探针，因此 Release 不能执行这三个读回方法。Debug 核心仍 29 个方法（改两项、替换一项），Release 为 26 个；没有 XCTSkip、没有把缺失探针当通过，runner 默认 Debug 并要求这些指定方法被发现。原三态 AX、长文件名、生命周期、纯模型和其他原方法在 Debug／Release 保留。主会话必须单独记录两配置实际发现数量，不能把 Release 没发现的三项记作已通过。编译和运行期效果仍待沙箱外验证。

稳定读取先确认宿主挂载与 native 尺寸，再等待 heading、notice、三个 metric ID 和必要 frame 出现且连续稳定；不等待值恰好等于期望。等待有 5 秒上界，沿用已有布局／RunLoop 推进和 Task.yield，没有新增固定 sleep。缺失时明确 XCTFail 并抛出带阶段、missing fields、missing frames、宿主状态和全部字段／frame 的错误，保持宿主到 teardown，不产生新的中途释放边界。notice 断言直接查实际 notice 字段；metric 按 kind 和标签选择唯一字段，校验该字段的值和说明，其他指标的值不能误配。

### 原断言逐项保留与读取替换

| 原方法／断言 | 本轮变化与依据 |
|---|---|
| identity：初始扫描、首扫描完成、新扫描历史、新 ID 完成、session=nil 的零绿色历史和空历史 | 全部状态转换与中英文期望文案保留。AX snapshot 换为由实际 body Preference 生成的 snapshot，notice 从全树包含判断加强为真实 notice 字段的精确文本。项目名仍必须来自实际已构建的行；当前可操作标签与 `1`／`2` 值及说明按同字段配对。model sessionID/detailsID/history/source、旧扫描／准备提示消失、“— 不可用”反断言和最终父求值计数不变全部保留。 |
| identity：历史及空状态标题 | 历史标题原全树 contains(model.presentation.title) 改为 heading 字段等于同一完整标题；空状态原全树 contains“尚未扫描”改为 heading 字段精确相等。只有真正的标题字段能满足，期望文案不变。 |
| viewport：pending 不上报、首交付只有一行实际自然高度、后续尺寸只上报一次 | 全部保留。原 native AX snapshot 的 layoutSize.height 改为具名 viewport frame 的 height，与同一个 firstSize 比较，accuracy 仍为 1；保留独立 NSHostingView.fittingSize 对自然一行高度的校验，后续记录仍必须恰为 `[firstSize]`。 |
| viewport：document 大于视口、滚到末端 | 原 `document.frame.height > scroll.contentSize.height + 2 * minimumHeight` 与滚后 clip bounds.maxY 到文档底的容差 1 保留。新增真实末行 candidate ID 的布局探针，要求非零行高、具名 viewport 的尺寸与原生 clip contentSize 相同（accuracy 1），且滚后最后一行的四边都落在视口内（沿用容差 1）。只有文档很高／底部边界到位仍不足以过关。 |
| 原第三项 `testVisibleNativeScrollReadbackPublishesLabelsValuesAndTextInBothLanguages` | 替换为 `testHostedRenderedProbePublishesLabelsValuesAndTextInBothLanguages`，托管真实清理 Page，而非单独拼 ScrollView。保留中英文指标值、实际说明、真实 scrollView、显示／隐藏／仍挂载／重新显示可读断言，以字段代替 AX；它专门验证新读回途径。 |
| 已通过的三态 AX 方法、原生命周期方法和其他原测试 | 三态方法与共享 AX 宿主及其 children/value getter 逐字节不变；原生命周期方法也逐字节不变。原 29 个函数中另 26 个函数体保持基线，未删除其他行为断言。 |

上述读取改写依据为本轮用户明确要求；没有修改源码契约的产品决定、标题文案、D47 预选、大小排序、性能阈值或状态逻辑。新方法仍用纯 ScanSession 和原生托管夹具，语言切换沿用既有 volatile argument scope、defer 恢复；无需新增 Store、文件根、真实偏好或清理操作。受影响测试的 makeForTests／TestOperationFactory 仍保持，卫生守卫未修改。

### 红／绿／反证

本轮绿色与反证执行均 **NOT RUN**。红的实际依据是主会话第七轮上述三项失败及空树。本轮准备的沙箱外验收如下；只认指定 XCTest 失败，不以编译错误、未发现方法或无关失败代替反证。

| 行为／修复 | 绿色目标 | 反证与应失败的断言 |
|---|---|---|
| 父不重算、页面跟随 session／scanning／history | identity，覆盖中英及全部状态转换 | `06-stale-page-inputs` 恢复 Page 的三个普通输入属性，由根读取 store、由不观察发布的测试父视图一次传入 model 值，Page.resolve 改读这些捕获属性；真实 body 探针也随之读到旧状态，identity 必须失败。`07-ignore-scanning`／`08-ignore-history` 保留，分别忽略模型输入发布后同一方法必须失败。06 同时调整被测 Page 的普通属性和测试父调用，仅为让旧读取路径可编译，没有伪造探针。 |
| 首次定高、之后长结果能滚动且实际末行可见 | viewport、自然行高、settlement | 原 `14-fixed-four-row-height`、`15-settle-pending-layout`、`16-resize-every-delivery`、`17-clip-later-results`、`20-ignore-parent-readiness` 重基保留。17 去掉真实滚动容器后必须在 scrollView／几何断言失败；新增 `26-fixed-scroll-document-height` 保留容器却固定内容文档高度并裁切，必须在 document 高度／末行几何断言失败。 |
| 末行 frame 断言确实参与验收 | viewport | 新 `25-last-row-outside-viewport` 只将 item 探针坐标移到视口外，保持原 document／viewport／滚动边界，必须在末行包含断言失败，日志含 layout probes。不会用 clip bounds 抵消缺失的行证据。 |
| 实际页面必须发布 notice，不能由测试补造 | 新 rendered probe 方法 | 新 `24-missing-rendered-notice` 仅去掉实际 notice Text 上的字段上报，保留可见 Text；指定方法必须失败且报告 `Rendered body probes did not settle` 和 `mini-cleanup.notice`。fixture 不从模型补一条 notice，让 missing ID 可诊断。 |
| 三态原生标题／值／文案、保留交付与订阅、hygiene 和宿主所有权 | 原三态、纯模型、原生命周期、卫生守卫 | `01–05`、`09–13`、`18–19`、`21–23` 全部保留重基；01／03／04 同时改坏 Debug 实际 title／notice 局部值与 Release body，避免只改到不会执行的条件分支。工厂绕过仅跑卫生源码守卫，不执行不安全 Store 方法。 |

第七轮的 24（隐藏 AX 窗口）和 25（还原第六轮 AX 宿主）已被上面两个新案例替换：新途径不再靠 AX 子树，这两份旧补丁无法证明字段与几何读回正确，不能继续充当有效反证。共 **26 份**，01–23 重基并更新必要输入路径，24–25 改写，26 新增。全部仅做 `git apply --check`，未向 worktree 施加或运行。

runner 更新旧方法名为新读回目标，由 manifest 取精确测试名；先要求所有目标发现且全绿，每次只认对应方法 failed，带诊断的案例核对指定文字，finally 还原且校验 SHA，最后目标再次全绿。日志写 `logs/round8-counterexamples/`。各阶段实际退出码、方法名、数量和失败摘要由主会话保存。

### 主会话命令、交付与未验证边界

`prepared-r8/targeted-test-classes.txt` 保留完整 **94 类**，包括 UIConsistencyRegressionTests、TestPreferenceHygieneTests、DesignSystemV2Tests 和现有全部小窗相关类；未缩减门禁。以下仅供主会话沙箱外执行，本轮未运行：

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r8"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r8"
mkdir -p "$mini_cleanup_scratch/logs/round8"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
mini_cleanup_focus='MiniWindowCleanupPresentationTests[./](testHostedParentDoesNotRedrawWhenScanningFinishesNewIdentityOrHistoryChanges|testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults|testHostedRenderedProbePublishesLabelsValuesAndTextInBothLanguages|testHostedSmartScanCardsRenderAllStatesAndNotUnavailableInBothLanguages|testReadbackHostIsRetainedAcrossAwaitAndCloseOnlyHidesUntilTeardown)'
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_focus" > "$mini_cleanup_scratch/logs/round8/host-focus.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round8/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter 'MiniWindowCleanupPresentationTests' > "$mini_cleanup_scratch/logs/round8/host-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|DesignSystemV2Tests|TestPreferenceHygieneTests|UIConsistencyRegressionTests' > "$mini_cleanup_scratch/logs/round8/host-strict.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py" > "$mini_cleanup_scratch/logs/round8/counterexamples.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round8/after-counterexamples-green.log" 2>&1
python3 script/check_private_api.py > "$mini_cleanup_scratch/logs/round8/private-api.log" 2>&1
```

Debug 焦点五项必须全部被发现；其中三个探针方法在每次运行都要读真实 body 字段／几何，不允许改成模型 getter。Release 应发现原三态与生命周期方法，核心 26 项不包含三个 DEBUG 方法；不要把 Release 未发现的三个探针方法当绿色。严格并发也使用 Debug，继续覆盖实际探针的 MainActor／Sendable。按 RULES 由主会话清理使用完的临时 Release／strict／反证构建，保留日志；本轮未删除别人的构建或启动任何应用。演示参数、截图／录屏验收和 `script/verify_menu_bar_performance.sh` 预算继续沿用，性能运行未执行。

`prepared-r8/` 三组：`01-debug-rendered-probes.patch`（两个 Sources 的 DEBUG 探针）、`02-rendered-and-scroll-tests.patch`（测试及帮助）、`03-handoff.patch`（本文）；附 all.patch、提交说明、manifest（最终文件和产物 SHA、组序、基线）、static-checks、94 类清单、26 份反证、runner、生成／提交脚本和 README。trailer 仍为 `Generated-By: Codex (gpt-6.1-sol)`。修改已在当前 worktree，**不要再次向它应用 all.patch**；主会话完成沙箱外验收与复核后才运行 commit-prepared.py。

实际执行的检查只有源码／日志阅读、git diff --check、补丁正反向 --check、Python AST、方法与类名范围、保护文件和 SHA，以及两个改动 Sources 的 Release 条件选中源码对比。构建、XCTest、严格并发、红绿、反证执行、性能、截图、安装和提交均 NOT RUN；这三个 Debug 方法能否在本机稳定得到 Preference，以及程序滚动后具名空间的末行 frame 是否正确更新，仍须主会话验证。探针证明实际构建的 Text／grid 输入与布局，不声称替代像素截图、Release 编译或系统 AX 可访问性验收。本轮没有 JEV 结果；先前被审批策略阻断的情况不变，本轮未重试，不声称外部模型已判断通过。

## 第九轮：说明与按钮贴底，真实结果变化可重新定高

### 基线、复核证据与第九轮方案

本轮基线 `0c4dd255ce06ff594c98ba878019e36bce6b6ca3`，分支 `task/r2-mini-cleanup-card`。先完整阅读 `~/Developer/.sc-build/r2-mini-cleanup-card-review/review-3.md`，核对 `r3/logs/probe-timeline-summary.txt` 与 `r3/screenshots/probe-finish-while-open-sheet.png`。第八轮的 **94 类、1416 项、跳过 4、0 失败，26/26 反证与私有接口检查通过**为主会话既有证据，本轮没有重跑。第三轮复核实测 P1-A 扫描完成后 4.6–6.9 ms 显示结果、新扫描开始后 0.5–1.7 ms 显示扫描中，订阅与宽限期修复成立。

新增红证据：`finish-while-open-1/2/3` 都把自然 442 pt 的内容放在锁住的 306 pt 视口里；说明和三个按钮在视口外，重算根不恢复。开始新扫描时 442→306 pt 又留下 136 pt 空白。订阅前两次 body 读取清空的模型，17 次首开、8 次重开都出现“尚未扫描”的输入；复核没有确认正常运行时这段是否上屏，延迟订阅实验能看到错误页。本轮不把 body 时间线当作正常首帧已被截图证明。

**第九轮方案来自本轮用户／主会话明确决定**：说明与三个已有导航按钮固定在列表外；只有项目行滚动；首份就绪布局在每次打开上报一次尺寸，随后只有会话 ID、完成时间或结果的缓存键真正变化（含结果被 nil 替换）才允许再定高一次，可在屏幕许可范围内增长或缩回。同键重开、同键重算、根重算不增加结果修订，也不产生额外重定高。列表溢出有底部渐隐和中英文“向下滚动查看更多”。这取代第五至八轮交接中“整个可见期间锁住同一高度”的取舍；历史章节保留作为记录，以本节为准。没有改变 D47、风险计数、默认项、按钮行为或 ScanStore 所有权。

### 修改、数据流与边界

| 项 | 本轮实现及理由 |
|---|---|
| P1-B：底部不可见 | `GeekSmartCleanupPage` 把 header、仅行列表、footer 交给同一稳定布局。footer 包含真实 notice Text 和 `GeekCleanupActions` 三个原导航按钮，位于列表 ScrollView 外。共享按钮组件仍调用 `openApp(.green/.largeFiles/.memory)`；无执行清理入口。 |
| P1-B：真正变化后重定高 | 模型只在新缓存键交付或已存在的会话／交付被 nil 替换时推进 `layoutRevision`；开始准备、同键完成、重开和父重算不推进。自然尺寸测量和就绪偏好携带 revision，同一 opening/revision 只接受一次，旧 revision 的排队测量不能回滚新尺寸。待标题、footer、行、列表视口和卡片都属于该 revision 后才结算。 |
| P1-B：屏幕限制与外层滚动 | `GeekAttachedPanelShell` 仅对智能清理页让页面拥有滚动；普通附属面板及 compact 导航都不再把其 footer 包进外层滚动容器。外壳传入实际可用高度（扣共享 padding）；暂停采样行另按真实测量扣除。原 `MiniWindowFittedPage` 不改，旧扫描及其他页面仍用原路径。 |
| P1-B：列表可发现、可达 | 列表按可用高度滚动，溢出时显示共享 alpha 渐隐与短句“向下滚动查看更多 / Scroll down to see more”，提示不覆盖行。沿用现有隐藏原生滚动条的样式，但滚动能力由常显提示直接说明，不依赖系统滚动条的显示偏好。高度不足时优先保留 footer、至少一行及提示，再压缩摘要显示区；足够高时恢复摘要的完整自然高度。 |
| P2-G：结果变短留空 | 用自然 header + 卡片装饰 + 真实行高 + footer + 共享间距计算首选高度；真实结果缩短／nil 后允许对应 revision 再结算。自然高度与屏幕裁限的可见高度分开，上报给外壳的尺寸包含实际 padding／暂停行，避免把旧面板的截断高度当成新自然高度。无固定 132 pt 行槽。 |
| P2-F：订阅前错误内容 | `MiniWindowCleanupSource.current()` 用 store 的三个当前值返回只读快照；Page 在 model 不可见时用该快照解析 title/notice/metrics。它不订阅，不计算候选指纹，不投影候选，不修改模型；会话尚无投影时如实显示整理中。已隐藏模型仍仅保留最大四行投影及缓存键，stop 继续释放完整旧会话；没有复制一套可写状态。可见期间继续只读模型三项发布者。 |
| P2-H：重复视图体 | content/header/status/notice/item 均只保留一份视图，实际 Text 与 Debug 上报共用同一局部值。Debug 探针类型仍仅在 `#if DEBUG`；Release 私有 `@inline(__always)` 修饰函数直接返回 self，没有 ID、Preference、GeometryReader、payload 或回调。八个空修饰函数的二进制消除须主会话用 Release 编译及符号检查确认，本轮只做条件源码检查。 |

生产文件共七个：`Support/MiniWindowCleanupPresentation.swift`、`Support/LayoutProbe.swift`、`Views/MenuBarAdvanced/GeekCleanupView.swift`、`MenuBarGeekPanel.swift`、`Views/MenuBarAdvancedStatusView.swift`、`Views/MenuBarPanelChrome.swift`、`Views/DesignSystem/SurfaceComponents.swift`。`LayoutProbe` 新增 footer、三个 action、列表 viewport、scroll hint ID；沿用 V0 PreferenceKey／同一具名坐标空间，测试不另造页面。`SurfaceComponents` 的 bottom fade 复用已有 top fade 的 alpha 遮罩做法，供列表调用。生产尺寸的 GeometryReader 是有限区域测量；候选指纹与投影仍在原 worker/cache，开面板路径不增加遍历或排序，隐藏时不整理。性能预算和脚本不改。

### 改写旧断言：逐项依据

| 原方法 | 改写及保留内容 |
|---|---|
| `testHostedStableViewportReportsOnceAfterDeliveryAndScrollsLaterLargerResults` | 原 later-result 仍 `[firstSize]`、锁住打开高度的断言，改为真实新键交付恰有 `[firstSize, largerSize]`，revision 恰推进一次。这是用户第九轮决定直接取代旧取舍。首开 pending 不上报、一行自然 fittingSize、`accuracy: 1` 均保留。用固定的模拟屏幕上限继续验证列表 document 比 clip 高至少两行、滚到底原生边界到位、实际最后一行四边在列表视口内；原末行基准改为仅列表的 viewport，因为整个页已不滚动。新增 notice 和三个按钮在实际页 viewport 内、滚动不增加报告，以及真实提示字段。 |
| `testLayoutSettlesOnlyReadyCurrentOpeningAndRejectsRepeatedOrInvalidMeasurements` | 同 opening/revision 重复尺寸仍拒绝；新增新 revision 可增长／缩短一次、旧 revision 不能回滚，以及父侧拒绝旧 revision。原 pending、错 opening、invalid/NaN 类尺寸、legacy 不受限制等断言保留。反证 16 现在只破坏同 revision 的重复拒绝；新反证 27 专门恢复“同 opening 永不改高度”的错误旧契约。 |
| `testSameKeyRefreshAndReopenRetainTheDeliveryWithoutRebuilding` | 原 no blank、no republish、no build、无快速更新中等断言保留；新增同键重算／重开 revision 不变。 |
| `testHostedParentRedrawDoesNotResubscribeOrRestartPreparation` | 原真正重算父、订阅一次、无请求、无更新中、builds=1 全保留；先按有界探针等待初始就绪，再新增父重算后 revision 与结算记录完全不变。 |
| `testProductCardsAreWiredToTheSessionAndKeepAllNavigationButtons` | 原源码字面量 `Text(presentation.notice)`、`Text(candidate.sourceURL.lastPathComponent)`、inline measurement 分别改为验证实际输入局部值 + 对应 Text；这是 P2-H 单一视图体的重构，产品契约不变，三态运行期 AX 方法仍验证真实文字。原 `presentation:model.presentation` 调用改为可见时 model、不可见时 current 快照两段，依据 P2-F 修法；订阅模型／D47／三按钮和禁执行入口断言全部保留。 |

已通过的三态 AX 方法、共享 AX host/children/label/value/hint 读取、生命周期方法、以及其余未列原方法的函数体保持基线。滚动行为用真实 body 的 Debug 字段与 frame，不再尝试 ScrollView 空 AX 子树、不用 OCR。现有强持有、close 先隐藏、XCTest teardown 延后拆卸与 5 秒有界等待继续保留；超时输出缺失 ID、实际字段/frame、宿主状态，等待不以期望文字当就绪条件，不增加固定 sleep。

### 新增验收与红／绿／反证

核心 Debug 方法 **35 项**（基线 29，新增 6）；Release **29 项**，六个 Debug 探针方法不在 Release 中发现。没有删除、跳过或放宽测试。94 类清单完整保留，含 UIConsistencyRegressionTests、TestPreferenceHygieneTests、DesignSystemV2Tests、MiniWindowLevelOneAnchorTests、MiniWindowSinglePageTests、级联／外壳／性能等全部现有小窗类。新夹具只有纯会话、CurrentValueSubject 和惰性 AppKit 宿主，三个按钮的测试 action 若被调用会 XCTFail；不构造新 Store，不触及文件清理、硬件或真实偏好。既有一处 Store 仍经 `ScanStore.makeForTests`，演示测试也保持工厂构造。

绿色和本轮反证执行均 **NOT RUN**；红为上面的独立复核实际证据，以及下面为沙箱外准备的故障注入。

| 项 | 绿色目标及断言 | 红／反证（指定 XCTest 必须失败） |
|---|---|---|
| P1-B 新键增长，footer 可见 | 新 `testHostedVisibleResultChangesGrowAndShrinkOnceWithFooterAlwaysVisible` 覆盖中英，从一项到新 ID 四项，footer/notice/三 action frames 全在实际视口内，恰一次新增 settlement，父不重算；旧 viewport 方法另覆盖限高及滚动末行 | 27 恢复整次 opening 锁高；28 新键交付不推进 revision；29 把 footer 恢复到整页滚动区并放开行区，限高时 footer frame 必须越界。 |
| P1-B 外壳与提示 | 新 `testHostedAttachedAndCompactShellKeepFooterOutsideTheirScrollers` 托管真实 attached 和 compact 外壳，结果增多后底部仍可见、实际 viewport 遵守外壳限高、原生只有一个列表 scroller、真实提示可读；旧 viewport 方法要求最后一行实际进入列表 viewport | 32 去掉实际提示；33 恢复外壳包住整页的 scroller；17 去掉列表 ScrollView；25 行探针移出 viewport；26 固定文档高度裁掉后续行。 |
| 同键重开／根重算 | 新 `testHostedSameKeyReopenDoesNotResettleAndUsesCurrentPreAppearInputs` 真正移除 Page 后重挂载：opening ID 变化，但结果 revision、尺寸不变，每次打开仍仅一次初始报告，订阅恰两套。重挂载后再次同键发布不增加报告 | 09 重复 start 订阅；16 接受同 revision 反复结算（纯 settlement 直接断言失败）；35 同键验证也推进结果 revision，重开／同键发布必须失败。 |
| P2-F 首帧当前输入 | 新 `testPreAppearPageUsesCurrentInputsWithoutSubscriptionsOrCandidateWork` 直接读取 Page 使用的同一个只读 presentation getter，中英分别覆盖已有会话整理中、扫描中、只有历史、真空；订阅 0、缓存 build 0、model 不可见；新 reopen 方法覆盖旧投影仍在时的首帧 | 30 删除 pre-appear current fallback，恢复读清空模型；36 Source.current 返回空而非传入的当前三项，首帧源读取断言必须失败。 |
| P2-G 变短／nil 收起空白 | 新 grow/shrink 方法同 ID 下减到一项再 nil，分别恰一次重定高，真实高度缩回且 footer 可见；新 `testOnlyDeliveredResultKeysOrSessionRemovalAdvanceLayoutRevision` 验证完成时间变化、ID 变化、pending 不推进、重复同键与重复 nil 不推进 | 27 锁住整个 opening；31 nil 时不推进 revision，变短阶段必须没有所需报告／高度变化。 |
| P2-H 一份视图体、Release 无探针实现 | 新 `testSharedBodiesUseReleaseIdentityProbeModifiers` 检查实际公共 body 区无条件重复、八个 Release 修饰符皆 self、无 Debug payload；原三态 AX 仍实测实际 Text | 34 在共享 notice 源码中恢复两份 DEBUG/Release 相同实现，虽当前语义相同，维护结构守卫必须失败。Release 符号检查另外执行，不能由此源码守卫代替。 |

01–26 必要变更处均重基到最终源码，保留标题/说明、`--` 不可用、普通父属性旧读取路径、三发布者、更新宽限、天然行高、卫生工厂、生命周期和探针诊断反证。16 的旧含义明确改写；27–36 新增。Runner 使用 manifest 中的精确方法名，先发现全部目标且绿，再逐份施加反证，编译错误／缺失测试／无关失败不算证据；带诊断的案例仍检查缺失 ID，finally 反向还原并验 SHA，最后全目标再绿。日志放 `logs/round9-counterexamples/`。本轮仅生成补丁并做 `git apply --check`，没有向当前源码施加故障。

### 主会话命令与交付

以下命令仅供沙箱外执行，本轮未运行；建议先焦点、再完整 94 类、Release/严格并发、全部反证后复绿、性能及私有接口。须记录各阶段实际发现数、跳过、失败、exit code 与日志。

```bash
cd ~/Developer/sc-worktrees/r2-mini-cleanup-card
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-mini-cleanup-card/verify-r9"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
mini_cleanup_scratch="$HOME/Developer/.sc-build/r2-mini-cleanup-card"
mini_cleanup_prepared="$mini_cleanup_scratch/prepared-r9"
mkdir -p "$mini_cleanup_scratch/logs/round9"
mini_cleanup_filter="$(paste -sd '|' "$mini_cleanup_prepared/targeted-test-classes.txt")"
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter MiniWindowCleanupPresentationTests > "$mini_cleanup_scratch/logs/round9/core-debug.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round9/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter MiniWindowCleanupPresentationTests > "$mini_cleanup_scratch/logs/round9/core-release.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete --filter 'MiniWindowCleanupPresentationTests|DesignSystemV2Tests|TestPreferenceHygieneTests|UIConsistencyRegressionTests|MiniWindowLevelOneAnchorTests' > "$mini_cleanup_scratch/logs/round9/strict.log" 2>&1
python3 "$mini_cleanup_prepared/run-counterexamples.py" > "$mini_cleanup_scratch/logs/round9/counterexamples.log" 2>&1
swift test --scratch-path "$mini_cleanup_scratch/debug" --jobs 4 --filter "$mini_cleanup_filter" > "$mini_cleanup_scratch/logs/round9/after-counterexamples-green.log" 2>&1
script/verify_menu_bar_performance.sh > "$mini_cleanup_scratch/logs/round9/performance.log" 2>&1
python3 script/check_private_api.py > "$mini_cleanup_scratch/logs/round9/private-api.log" 2>&1
swift build -c release --scratch-path "$mini_cleanup_scratch/release" --jobs 4 --product StorageCleanerMac > "$mini_cleanup_scratch/logs/round9/build-release-product.log" 2>&1
mini_cleanup_release_bin="$(swift build -c release --scratch-path "$mini_cleanup_scratch/release" --show-bin-path)/StorageCleanerMac"
nm -a "$mini_cleanup_release_bin" | swift-demangle > "$mini_cleanup_scratch/logs/round9/release-symbols.txt"
strings "$mini_cleanup_release_bin" > "$mini_cleanup_scratch/logs/round9/release-strings.txt"
```

Release 符号文件中 `GeekCleanupRenderedField|GeekCleanupProbeID|GeekCleanupRenderedPreferenceKey|cleanupRenderedProbe|cleanupRowLayoutProbe|cleanupViewportProbe|cleanup(Metrics|Heading|Notice|Item|Action|Hint|Region|Viewport)Readback` 必须 **0 个**，strings 中 `mini-cleanup\.` 必须 0；生产 `GeekCleanupStableViewport|MiniWindowCleanupSource` 的符号必须非零，避免检查到空／错误二进制。源码的 identity 条件展开不能证明编译器已消除符号。Beta 为 Release 加 BETA 而无 DEBUG，继续核对这一配置。

演示场景参数保持此前 `afterSmartScan` 及 D47 rows 夹具、中英文×深浅色；本轮没有另改 `MiniWindowDemoData.swift`。主会话用复核 `r3/evidence/review-only-probe-r3.patch` 的隔离状态注入思路重新检查 `finish-while-open`、结果减项／开始新扫描、同键重开：完成后标题和真实行及时更新、说明／三按钮无需滚动即可见、溢出提示可见、真实键只新增一次尺寸、不变键不闪动，窄屏／compact／暂停采样也要截图确认。该 review-only patch 不是产品补丁，不应直接覆盖本轮产品文件。

`prepared-r9/` 三组依次为 `01-session-inputs-and-layout`（七个生产逻辑／Debug ID 文件）、`02-debug-probes-and-tests`（托管探针读回与测试）、`03-handoff`（本文）；包含 all.patch、messages、manifest（基线／文件／产物 SHA／组序）、static-checks、94 类清单、36 份反证、runner、提交与生成脚本、README。最终文件共九个。工作树已是最终源码，**不要再次向此工作树应用 all.patch**；提交脚本仅供主会话在验证和复核后使用，本轮没有运行。

实际只执行只读审计、源码编辑、`git diff --check`、分组/总补丁正反向可应用检查、反证可应用检查、Python AST、条件源码选择与类/方法清单、SHA/保护文件检查。构建、Swift/XCTest、严格并发、红绿／反证执行、性能、Release 符号与像素截图、启动/安装/提交均 **NOT RUN**。ScanStore.swift、性能政策/脚本、其他批次与原生三态 AX 读取均不改。

本轮 JEV 判断调用被自动审批拒绝，返回“requires approval, but approval policy is never”，没有获得 JEV 判断，不声称外部模型判定通过。用户已明确第九轮方案，继续据授权及源码证据实施，没有请求额外批准。剩余验收是主会话运行期确认有限区域测量的稳定性、真实屏幕 resize／compact／暂停行布局、Release identity 消除及预算。本轮不报告未执行的绿色。
