# r2-lf2-b3：性能组页面呈现交接

2026-10-10；分支 `task/r2-lf2-b3`；基线 `0ca11ff5b9ddc7e87d50b4c652685cb5c0092b7c`。
worktree `/Users/developer/Developer/sc-worktrees/r2-lf2-b3`；scratch `/Users/developer/Developer/.sc-build/r2-lf2-b3`。

本批按 D69、D70④⑤⑥和冻结 `approved-20261009/renders/a/`、`mockups/a/` 实现登录项与后台任务、内存管理、能耗。性能测试页归跑分 v11，本批不改。已先读取 `lf2-pages-common.md`、`common.md`、协同规则、计划 B3、D67 规范及指定决定。

## 实现与数据流

- 共用组件：在 B2 的 `LightfieldRing` 修复固定字号根因。`LightfieldRingTypography` 在主线程用实际字体宽度共同拟合数值、单位，标题单独拟合；仍在原内接方框内。B0 的 820×560「81%」与 1280×763「升高／压力」作为 64、76 pt 复现尺寸，并覆盖生产 120 pt、超长文本、日夜。扩展 B2 `AppIcon` 的捕获 bundle/PID 校验与 `NSRunningApplication.icon`，保留 bundle 缓存及守护进程灰占位；扩展 MetricGroup 的三列紧凑值、ExpandableRow 的副标题与尾部读数、StatusGlyph 的信息状态。原试点和 B3 共用抽出的 `LightfieldResultContent`，不保留两套结果滚动策略；原 110 pt 短窗口阈值、76 pt 摘要、20 pt 间距、结果渐隐保持原值。B3 紧凑行没有试点的顶部空白，按真实表头/逐子行边界吸附；原试点保留旧部分行切片策略，避免切过 B3 的名称/开关。骨架坐标、颜色令牌、动效表不改。
- 登录项起始页：复用安全清理的 Lightfield 骨架、Options、OptionRow 和风格 A 28 pt 图标 `opt-startup-login/background/startup-agent`。Store 现有扫描范围固定，没有逐范围选择接口；三行勾选表示「每次已包含」，不伪造可交互扫描开关。结果页按 all/login/background 分类与现有归一化应用分组，使用真实应用图标、状态符号、能力门禁开关／系统设置／仅查看。保留状态、来源、排序、技术明细、搜索、检查、完整检查、原撤销及 Inspector；键盘上下选择带滚动跟随，Return/Space 仍只查看详情。原 `startupActionCandidate(s)`、管理员条件及确认逻辑未改。
- 内存起始页：左侧圆环、真实 used/total/cache/swap、120 秒趋势（96 pt 图形），保留悬停与区间平均；「最新进程快照」和历史总量明确区分。结果页使用 Store 已有 `MemorySnapshot.appsByResidentUsage`、捕获 PID 子列表及原选择方法。应用、子进程真实图标；子进程名称保留已知 Renderer/GPU/Network/Helper 角色或实际 executable 名，PID/路径只在 help。勾选与展开独立，只读系统项不产生选择按钮。主按钮沿用已有选中应用的正常退出请求与 Store 确认，未新增单进程退出、强制结束或清理动作。保留原结果状态与验证 detail；用户的「只读、不新增退出／清理动作」按保留已有正常退出确认入口、不增加动作落实。
- 能耗结果页：累计 Wh／当前 W／平均 W 使用同一快照的独立证据；未知显示 `—`，当前摘要来源按当前证据计算，不沿用累计质量。保留排序、搜索、切换应用／Finder 的现有入口。归组应用展开先显示一个子进程，可再展开其余；用既有有界 libproc 路径读取器解析可读名，校验捕获 bundle 或 executable 归属再显示，拒绝将复用 PID 的无关名称归给原应用。PID 仅 help，未添加退出动作。已有 `HelperPowerMetricsView` 在可见三态内承载，用 B2 MetricGroup 每三项呈现 CPU/GPU/ANE 真实功率与簇频率；原 updateConsumer、窗口遮挡／最小化／睡眠／onDisappear 接线与采样周期保留。展示迁入页内，不另起计时器、XPC 或 powermetrics 任务；主会话须验证三态切换和隐藏窗口的需求生命周期。
- Debug：新的 `LightfieldPerformanceFixture` 和既有 Demo/ProductionResult 扩展均严格 `#if DEBUG`，B3 每页 landing/running/result 接原截图入口。假 PID 不解析活进程、不调用扫描／退出／助手需求。Release 与 Beta 均不引用新夹具。能耗夹具总量和覆盖率由逐应用数据相加，刻意不声称它们是冻结 HTML 演示数字的实测结果。

未改 `Stores/ScanStore.swift`、辅助程序协议或助手实现；未修改其他 worktree、BOARD、安装包、偏好或真实数据；未启动应用、构建、运行 XCTest、提交或安装。

## 需要 Store/快照提供的字段与现有边界

| 字段 | 本批处理 | 后续若产品要求完整展示 |
|---|---|---|
| 内存进程 CPU%、能耗影响 | 快照未提供，行与 AX 说明明确显示 `—` | Store/快照增加同采样时间、来源与可用性字段 |
| 能耗逐子进程 Wh/W | 快照只提供应用合计与 PID，子行显示 `—` 并说明 | 快照携带子进程数值和证据，不能从应用均分 |
| 逐历史时刻的应用占用 | 趋势仅总量，不将当前应用列表归给悬停历史时刻 | 同时刻应用样本或明确关联标识 |
| 登录项逐范围开关 | 固定包含三类范围，行不具 AXPress | 扫描入口明确接收范围并同步覆盖／权限语义 |
| 能耗捕获子进程名称／路径／身份 | 展开时只读解析并核对归属；已结束或不匹配显示名称不可用 | 捕获快照带路径/名称/start-time，避免展示时再解析 |

## 改写的旧视觉断言（保留安全断言与原测试方法）

1. `FeatureLightfieldContractTests.testNewTemplatePilotAdaptersCompatibilityAndSafetyHaveNoDecorativeContainers`：旧「11 个兼容路由」改为 8；原三个 pilots 列表不变，B3 由独立 performancePages 归属。依据 D69/D70。
2. `FeatureLightfieldComponentSourceTests.testCenterTextScalingMetricsPathsAndSummaryBaselineCannotRegress`：由仅检查 `.minimumScaleFactor(0.8)` 改查实际字体拟合及 0.1 的残余布局保险，禁止残留 0.8；新增独立字体宽度和原生实际 frame 验证。不放宽几何 0.5 pt、缩放预算或其他断言。
3. `StartupItemsDashboardContractTests` 的 `testManagementListKeepsAllResultsInNativeScrollWithFixedHeadersAndStatus`、`testDashboardIsValueDrivenManagementConsole`、`testDashboardKeepsResultsVisibleAndSupportsKeyboardNavigation`：旧 ManagementListPage/List/玻璃分段/计数卡片的视觉结构改为共享骨架、无容器结果滚动、B2 组件及键盘滚动。偏好键、搜索、完整结果、技术明细、回调能力门禁、只查看详情语义继续验证。
4. 同类 `testCoverageActionStaysInThePageHeader`：旧 header 槽位置改为页内结果控件区域；完整检查原 callback 保持，补查隐藏窗口工具栏后仍可见的 Undo。`StartupItemRow` 改内部可见供原生 AX 单行测试，未产生平行组件。
5. 同类 `testStartupItemsWaitForAnExplicitSharedLandingScan`：旧 HeroScanPage/读取标题结构改为共享安全清理模板，显式 onStart、无自动 task、三行固定范围保留；扫描与取消入口未改。
6. `FeatureTemplateContractTests.testProductionStartupAndMemoryRunningPagesUsePublishedStateAndCancellationSlots`：B3 从 V1 40 pt 取消槽迁入原 Lightfield 52 pt 主按钮，发布进度、动作存在性、禁用状态、原生按下与跨页几何比较保留。
7. 同类 `testMemoryDashboardKeepsOverviewListAndSelectionCommandsInsideTheContentColumn` 与 `testMemorySampledListUsesNativeScrollingAndVisibleOverflowHint`：D70⑤取代 V1 平铺仪表盘／提示条，改验证生产 Lightfield 结果页的选择总数/字节、固定主按钮、内容边界、原生滚动／渐隐与不产生待退出请求；短窗口阈值和半点精度未放宽。
8. 同类 `testD63SourceKeepsTheColumnAndStatusOnTheCanvas`：不再提取已删除的 memoryLandingPage 私有段，改查实际新内存页面无卡片容器。
9. `UIConsistencyRegressionTests.testMemoryEmptyStateHidesUnavailableActionsAndAvoidsRepeatedMetrics`：旧 display/process snapshot 调用拼写改为新页面参数与页面 fallback，原其他内存安全/未知字段断言保留。`testEnergyImpactRequiresExplicitScanAndShowsRealPipeline`：旧结果内部进度卡改为结果 LightfieldEnergyPage 与原显式 landing/running 六阶段链路；不删除扫描／阶段／禁止自动刷新的断言。

新增 13 个测试方法（8 原生/值验证、5 源码守卫），准备 21 个逐项变异。`targeted-classes.txt` 含共用要求的五类、UI 一致性／偏好卫生、B2 几何/源码、新类及相关选择／正常退出确认／压力／能耗／助手监测回归。没有删除测试方法、增添 skip 或放宽阈值。

## 验证状态与主会话命令

当前只完成代码与交付准备。静态命令、退出码、补丁反向校验、文件及产物 SHA-256、变异字串次数／方法存在性写入 `prepared/static-checks.json`、`manifest.json`。这些不是 Swift 编译或 XCTest 通过证据。构建、定向 Debug/Release、原生 AX/几何、反证、截图、严格并发与完整门禁均 `NOT RUN — 主会话执行`；提交、合并、安装也均 NOT RUN。

JEV 实际工具调用及代码图入口被工具层拒绝：`MCP tool call requires approval, but approval policy is never`。本批没有 JEV 判断结果，未假定已完成独立模型复核，也未改模型配置。主会话能力可用后再复核实际 diff 与证据。

以下命令只供主会话在沙箱外执行，先核对有本批授权及临时产物所有权：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b3
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
sc_b3_scratch=/Users/developer/Developer/.sc-build/r2-lf2-b3
python3 "$sc_b3_scratch/prepared/commit-prepared.py"
swift build --scratch-path "$sc_b3_scratch/debug" --jobs 4 > "$sc_b3_scratch/logs/build.log" 2>&1
sc_b3_filter=$(paste -sd '|' "$sc_b3_scratch/targeted-classes.txt")
swift test --scratch-path "$sc_b3_scratch/debug" --jobs 4 --filter "$sc_b3_filter" > "$sc_b3_scratch/logs/targeted-debug.log" 2>&1
swift test -c release --scratch-path "$sc_b3_scratch/release" --jobs 4 -Xswiftc -enable-testing --filter "$sc_b3_filter" > "$sc_b3_scratch/logs/targeted-release.log" 2>&1
python3 "$sc_b3_scratch/prepared/run-counterexamples.py" --execute --green-log "$sc_b3_scratch/logs/targeted-debug.log"
```

每条命令需逐条检查退出码，失败则停止，不能因后续命令成功把前项标绿。反证 runner 默认只读取清单和哈希；`--execute` 才逐项变异并运行过滤测试，只有测试实际执行且失败才计红，编译失败或零执行计 INCONCLUSIVE。逐项保留日志/原字节备份、恢复并校验原哈希；遇到并发修改或未结束测试不覆盖，交回主会话处理。

- 红：B0 修复前的 81%／压力文字可从 B0-NOTES 和基线复现。其他呈现迁移的旧视觉契约与 D69/D70冲突，不能把旧样式通过当新验收；`counterexamples.json` 列出每个修复点的具体回退。
- 绿：上述定向 Debug/Release 均应通过，新增 AX 需真实按下动作并读取状态；不得把源码字符串守卫当原生界面证据。
- 反证：运行 21 个独立变异，恢复后重新确认绿色。范围为圆环字体/内接方框、B3 归属、可读名与目录误判、PID 显示/归属/图标、未知值与当前来源、助手可见需求、Debug 泄漏、选择/展开/保护、短窗口滚动、数值溢出、紧凑子行边界和图标样式。完整明细和过滤方法见 JSON。

合并前由主会话在相应集成树执行项目完整门禁，专属根不与其他批次共用：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 SWIFT_BUILD_JOBS=4 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-lf2-b3/gate \
bash script/verify.sh > /Users/developer/Developer/.sc-build/r2-lf2-b3/logs/verify.log 2>&1
```

另需实测正常三态切换、离页、遮挡、最小化、睡眠的助手需求状态及功率过期/不可用表示。真实功率是否返回、原生布局是否吻合冻结稿、Swift 6 是否编译通过尚未验证。按 RULES 清理本批用完的临时构建/截图 app 副本，保留日志/截图/证据；不清理未知目录或其他批次。

## 主会话要重拍的离屏场景

沿用严格 Debug 隔离截图包和既有入口（不是已安装 Beta）：`--debug-mini-window-demo-data --debug-feature-page=all:landing --capture-feature-templates --capture-main-window-filters=startup,memory,energy --capture-main-window-directory=<本批截图根>`；日夜分别加 `--debug-mini-window-appearance=light` / `dark`，保存到独立 `captures/day`、`captures/night`。已有默认七尺寸可用；只拍基准时加 `--capture-main-window-sizes=1280x763`。检查 `capture-feature-templates.json`，需要实际 content size 与命名吻合。

标准场景命名为 `{尺寸}-{模块}-{状态}.png`，两主题各 63 张：

| 模块 | 1280×763 的核心场景名（日夜各一） | 其余同名尺寸 |
|---|---|---|
| 登录项 | `1280x763-startup-landing`、`1280x763-startup-running`、`1280x763-startup-result` | 820x560、1000x700、1680x1050、2400x1350、677x390、1280x390 |
| 内存 | `1280x763-memory-landing`、`1280x763-memory-running`、`1280x763-memory-result` | 同上 |
| 能耗 | `1280x763-energy-landing`、`1280x763-energy-running`、`1280x763-energy-result` | 同上 |

优先复核 `820x560-memory-landing` / `1280x763-memory-landing` 的圆环、左布局和趋势；三页 `677x390-*-result` 的末项可达与主按钮上方 24 pt；能耗展开子行的名字/悬停 PID；内存选中与展开分离；登录项的固定范围图标与只读/可管理区别。由于结果滚动承载抽到共用组件，另重拍原试点 `1280x763-uninstall-result`、`677x390-uninstall-result` 和 healthHub/green 的相同结果场景，检查摘要与短窗口插画无回归。超长名字/路径、未知/过期值用定向夹具原生用例补充，不将未生成的画面标为已重拍。

## prepared 分组

1. `01-shared-components`：归属、圆环根因、B2 最小扩展与结果共用滚动。
2. `02-startup-pages`：登录项两页与原操作门禁呈现。
3. `03-memory-energy-pages`：内存/能耗页面、展示适配、生产接线和真实功率呈现。
4. `04-debug-fixtures`：严格 Debug 三态夹具与原截图入口接入。
5. `05-contracts-handoff`：新回归、按决定改写的旧契约、本文。

prepared 有每组 patch/message、all.patch、最终 SHA-256 manifest、只读默认 commit-prepared.py、counterexamples.json、targeted-classes.txt、static-checks.json。主会话完成构建、测试、反证和独立复核后才加 `--commit`；该脚本不构建、不安装、不合并、不 push。若继续改代码，先重新生成 prepared，不沿用旧哈希或旧验证状态。当前没有提交 SHA，基线仍为上述提交。

## fix1（2026-10-10，主会话 r1 复验反馈）

增量基线是 `0ca11ff5 + prepared/` 原 r1 五组，不是单独 `0ca11ff5`。原五组与 manifest 保留；fix1 放 `prepared/fix1/`。改前逐文件快照与 r1 manifest 的 24 个 SHA-256 全部相符。全文读取 `main-failures.txt`，从 `logs/main-final-1039/full.log` 提取并读取 17 个失败测试的完整诊断，保存在 `fix1-work/diagnostic-00.txt` 至 `diagnostic-16.txt`。

### 根因与实现修复

1. **圆环/长行的宿主尺寸，而非帧抖动。** 日志中 `missing=[]` 的圆环 viewport 是 64×64，长行 viewport 是 520×56，窗口分别是 610×532、520×200。新测试误将固有尺寸当窗口 viewport，永远无法通过尺寸就绪条件。按 B2 已有 `lightfieldHost` 的做法只给测试外层补满窗口；组件实际尺寸、120×5ms 等待、连续 3 次稳定、0.5pt 断言原值不变。继续运行 B0 又发现中文 fallback/optical 字体并不随字号线性缩放：初版长标签宽度 39.48/46.40/73.40 超过内接方框。`LightfieldRingTypography` 现在对候选字号实际测量，以有界二分拟合数值+单位及标签，原反证锚点 `valueSize = number * scale` 保留。
2. **能耗 landing 实际仍走旧模板。** `FeatureLandingPageShell` 是 `HeroScanPage` 的别名，后者调用 `FileToolLandingPage`，不会因为光场 owner 环境就自动转成光场。直接接 `FeatureLightfieldPage` 和 B2 Options；真实六阶段、显式 `scanEnergyImpact()`、刷新可用性、运行态及 powermetrics visibility/demand 接线不变。修正旧诊断里缺光场探针的根因；不是增加等待。
3. **AX 数据与发现。** 原生 switch 的 AXValue 是数值 1，即便 `.accessibilityValue(item.displayStatus)` 也不能改成管理状态。保留可见 switch，使用原能力门禁的 `accessibilityRepresentation` Button 发布原期望的完整状态及 AXPress；禁用条件与 requestEnablement 仍共用。内存选择 Button 明确发布独立 AX 元素/真实控件探针；宿主用 20pt 勾选框的真实中心调用公开 native hit-test，继续查原生标签、值和按下动作，不制造 AX 节点、不改期望值。
4. **实际实现回退。** 内存建议/全选/清空从菜单恢复成可见文本控件，沿用原选择方法、忙碌门禁和 AX 名称；窄窗口用同页 `ViewThatFits` 换行。退出条仍请求既有正常退出确认，无新退出/清理行为。能耗 body 的 presentation 只创建一次，应用、排序最大值均从这个对象读取。B2 结果组件承载懒加载行，固定表头/页尾置于其外，避免污染 LazyVStack 未加载行的高度估算；原三个试点的已有行容器策略显式保留。应用展开初值只应用一次，懒加载重新出现不覆盖用户展开状态。
5. **懒加载滚动需要共同收敛。** 新 400 行生产能耗结果回归实际暴露表头参与平均高度估算及一次滚底后估算更新的问题。固定/懒加载分层解决估算污染；native `bottomFrames` 在原 120×5ms、3 次精确稳定的同一个 gate 内持续锚定文档底部，检查真实帧。没有追加等待预算或放宽阈值。400 行、七尺寸、两主题全部通过，沿用 D67 卸载回归已有的 `<60` 实际布局行预算；末项可达，主按钮不动，列表结束距按钮 24pt。
6. **未知计数语义保留。** 登录项读取中且没有快照，摘要值仍是 `—`、状态仍是实际读取进度；不把未知显示成已读取 0 项。

未改 ScanStore、辅助程序协议、产品路径安全检查或测试工厂。没有删除测试方法、添加 skip 或放宽等待/性能/几何阈值。新增一个有意义的生产能耗 400 行原生回归。

### 17 个失败测试及断言迁移依据

所有旧视觉锚点按 D67/D69/D70 迁到实际生产 B2 adapter/组件；下列每项守护的行为继续检查。

| 测试 | 修复或迁移；保留的守护 | 本地证据 |
|---|---|---|
| ConceptLandingNativeLayoutRegressionTests.testEveryLandingPageFitsInTheRealPageContainerAcrossTheSizeSweep | 能耗实际 landing 接光场，保留七宽/九高、双语言、固定按钮与末选项可达检查 | Store 家目录夹具 BLOCKED；主会话复跑 |
| ControlAccessibilityContractTests.testStartupConsoleExposesFocusedKeyboardAndVoiceOverContracts | `focus:`→真实 `.focused($isSearchFocused)`；开关标签加应用身份；焦点命令、Return/Space、搜索和状态 AX 继续守护 | PASS |
| DeclutterD4D5ContractTests.testStartupResultsKeepManagementAndAdministratorSafety | 旧 startupMetric→共享 LightfieldSummary；保留无图标计数、未知 `—`、管理员说明、组织/系统只读与只打开设置页 | PASS |
| DesignSystemV2ReviewTests.testMemorySelectionCommandsStayAvailableWhateverIsSelected | 宿主实际结果页；旧 memory.command→lightfield.memory.command，退出条→lightfield.primary；保留 0/1/全选、两尺寸、可见/AXButton/原标签/启用及无选择时无退出命令 | Store 夹具 BLOCKED；主会话复跑 |
| DesignSystemV2Tests.testMemoryPageKeepsOverviewListAndQuitBarVisibleAtEverySize | 宿主实际结果页；概览/列表/退出条迁光场；保留四尺寸、概览可见、列表可达、固定主按钮高度/位置，并查末应用与 24pt 间距 | Store 夹具 BLOCKED；主会话复跑 |
| FeatureLightfieldContractTests.testNewTemplatePilotAdaptersCompatibilityAndSafetyHaveNoDecorativeContainers | `VStack(spacing: 20)` 位于抽出的 B2 ResultContent；其余令牌/无装饰容器断言原位保留 | PASS |
| FeatureLightfieldPerformanceTests.testB0Occupancy81AndPressureWordsFitTheRingBaseline | 测试 viewport 修正及实际字号重测；原 64/76/120、字体宽度/真实 frame/双主题检查保留 | PASS |
| FeatureLightfieldPerformanceTests.testLongNamesAndNumericGroupsStayInsideTheRowAtSevenWidths | 三种单行宿主补满 viewport；行本身尺寸、名称/数值列包含关系与七宽保持 | Store 夹具 BLOCKED；主会话复跑 |
| FeatureLightfieldPerformanceTests.testMemorySelectionAndExpansionPressAreIndependentAndNeverRequestQuit | 真实选择控件中心做 AX hit-test；保留三次勾选、展开独立、字节/计数与无待退出请求 | Store 夹具 BLOCKED；主会话复跑 |
| FeatureLightfieldPerformanceTests.testProductionPerformancePagesKeepTheSkeletonInThreeStatesSevenSizesAndTwoSchemes | 修能耗 landing 模板；原三页三态七尺寸双主题骨架比较不改 | Store 夹具 BLOCKED；主会话复跑 |
| FeatureLightfieldPerformanceTests.testStartupNativeRowsAndSwitchesKeepProtectedItemsReadOnly | 修实际 AX 状态与按下动作；原只读项目无 switch、原门禁回调次数/身份检查保留 | PASS |
| SystemUtilitySafetyTests.testStartupDashboardShowsAllScannedRowsAndGatesActionsByCapability | CachedAppIconView/GlassSegmentedControl→B2 AppIcon/TextSegments；全部扫描项、能力门禁、管理员/系统设置安全断言保留 | PASS |
| SystemUtilitySafetyTests.testUtilityListsPreferActionableApplications | presentation 锚点移到 LightfieldEnergyPage，并检查 production delegate；presenter 的 isApplication 筛选与卸载可操作优先不变 | PASS |
| UIConsistencyRegressionTests.testEnergyImpactRequiresExplicitScanAndShowsRealPipeline | 旧刷新 AppButton→LightfieldEnergyPage 的 refresh/可用性与共用主按钮；保留显式 scan、无自动刷新、六真实阶段及真实采样链路 | PASS |
| UIConsistencyRegressionTests.testSharedEmptyStateStaysFlatWhileSmartScanUsesDedicatedStage | 旧两 AppEmptyState/List/RuntimeInlineStatus→两种实际扁平文本状态、真实 progress 与稳定 item.id 选择；智能扫描专用 stage 等原断言不改 | PASS |
| UtilityPresentationPerformanceTests.testEnergyImpactViewCreatesOnePresentationAndHasNoLegacyComputedLists | 移到实际能耗 adapter；除了调用数恰好 1，新增 body 局部 presentation/apps/maxima 及无 computed apps 检查，修重复计算 | PASS |
| UtilityPresentationPerformanceTests.testLargeEnergyAndUninstallListsUseLazyContainers | 查 production delegate→B2 ResultContent→LazyVStack 链路，卸载原惰性列表断言保留；新增真实 400 行回归防止仅字符串通过 | PASS |

`InvalidTransition` **没有被判定为本批无关，也没有声称基线复现**。`full.log:3340–3344` 显示先缺旧 memory.command 探针，再出现 `idle→failed(deinit)`。该测试原用 V0LayoutHost 同步 `window.close()`；迁移到现有 CalibrationAppKitLayoutHost，其 SDK27 收尾会保留宿主并 drain 主线程回调，避免二次析构异常遮住原失败。该测试需主会话实跑确认；如仍出现异常，应单独复验，不可当作无关失败忽略。本地 Store 工厂权限失败发生在建窗口之前，不能作为基线窗口错误的复现证据。

### 本轮实际验证

按新的 `codex-build-common.md` 运行，覆盖早先 common.md 的禁止构建说明；全部使用本批 debug scratch、Xcode 27 Beta、`LC_ALL=en_US.UTF-8`、jobs 4、两处 `--disable-sandbox` 和离线解析参数。

| 项目 | 状态与实际证据 |
|---|---|
| 最终 Swift build --build-tests | PASS，exit 0，`logs/fix1/build-verified.log` |
| 第一轮定向 | 291 项，原有 1 skip，24 断言失败涉及 23 个方法；均是家目录/CFPreferences/libproc 权限限制。exit 1，`logs/fix1/targeted.log` |
| B0 继续诊断 | viewport 修正后暴露 3 次真实字体宽度超限，修在统一字体测量；红日志 `logs/fix1/native-capability.log` |
| 新懒加载回归红→绿 | 红 `energy-lazy.log`；分层与滚动收敛后绿 `energy-lazy-final.log`，1 项、0 失败 |
| 最终可运行定向 | PASS，exit 0，292 项、原有 1 skip、0 失败；`logs/fix1/targeted-verified.log`。筛选清单逐方法列在 prepared/fix1/runnable-filter.txt，完整命令/exit code 另存 validation-command.json |
| 原生组件 | 上述最终绿结果包含 B2 19 项及 B3 5 项：圆环、开关 AX、能耗展开/证据、大列表七尺寸双主题；不是仅源码检查 |
| 偏好卫生 | 可运行方法 PASS；两个 broker 写盘方法 BLOCKED，未放宽隔离规则。已有实机能耗 opt-in skip 未修改 |
| 反证 | r1 主会话 21/21 PASS 是历史证据；fix1 实际变异 NOT RUN（主会话负责）。原 21 条完整对象保持不变；新增 4 条保护真实懒加载、重复 presentation、标签字号和 switch AX 值，共 25 条精确一次命中 |
| Git/补丁静态检查 | prepared/fix1/static-checks.json，含原方法保留、原等待预算、SHA、补丁往返、原锚点及 git diff --check |
| 全量/Release/严格并发/截图/独立复核 | NOT RUN，主会话负责；不以本地部分定向替代 |
| 提交/安装/合并 | NOT RUN；.git 只读，交付分组补丁；未安装/发布 |

23 个权限失败方法的精确清单与日志位置在 `prepared/fix1/sandbox-blocked-tests.json`。其中 HelperPowerMetricsMonitor、MemoryQuitConfirmation、MemorySelectionSummary、StartupItemsDashboardContract 的 Store 工厂建 `~/.storage-cleaner-*` home 被拒；EnergyProcessNaming 的 libproc 读取被拒；TestPreferenceHygiene 两个 `synchronize()`/文件落盘方法有 sandbox_extension_issue_file / Operation not permitted。不能用这些失败反推产品不正确，也不能把它们计为通过。

完整主会话定向清单现在 27 类：原 20 类加本次失败涉及的 7 类。修复验收必须沙箱外跑完整清单与项目全量；本地 runnable 筛选只报告可执行子集，不改测试 skip、不改变主会话清单。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b3
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
sc_b3_fix1=/Users/developer/Developer/.sc-build/r2-lf2-b3
python3 "$sc_b3_fix1/prepared/fix1/commit-prepared.py"
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$sc_b3_fix1/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$sc_b3_fix1/targeted-classes.txt")"
python3 "$sc_b3_fix1/prepared/fix1/run-counterexamples.py" --execute --green-log <本轮完整定向绿日志>
# 按协同规则另跑全量/Release/严格并发及截图复核。完成后主会话按组提交：
python3 "$sc_b3_fix1/prepared/fix1/commit-prepared.py" --validated
```

脚本默认只读校验。`--validated` 是主会话确认完整验证已完成后的提交入口：若 r1 仍未提交，先只在 index 按原五组提交 r1，再按 fix1 五组提交；工作区最终文件不回写、不撤销。若 HEAD 已有 r1 五组，则核对其树与基线文件 SHA 后仅提交 fix1。既有暂存内容、额外工作区改动、分支/基线/文件/补丁哈希不符均停止；不自动重置。fix1 组为 shared-layout、performance-adapters、native-regressions、source-contracts、handoff。

### fix1 需要重拍的离屏场景

日夜各拍：`1280x763-startup-result`（AX representation 保持可见 switch）；`820x560-memory-landing`、`1280x763-memory-landing`（字号）；`1280x763-memory-result`、`677x390-memory-result`、`1280x390-memory-result`（可见选择命令/换行/固定退出条）；`1280x763-energy-landing`、`677x390-energy-landing`（真实光场骨架/六阶段/可见功率）；`1280x763-energy-result`、`677x390-energy-result`、`1280x390-energy-result`（表头分层、展开、列表末项）。原试点 smoke 重拍 `1280x763-uninstall-result`、`677x390-uninstall-result` 及 green/healthHub 同尺寸结果，确认其既有容器策略保持。完整三态七尺寸矩阵仍按上节执行，不把纯组件绿结果当截图验收。

## fix2（2026-10-10，主会话 fix1 复验反馈）

交付为 `prepared/fix2/`，增量基线是当前 `HEAD 0ca11ff5 + r1 五组 + fix1 五组`。改前 31 个最终文件逐项匹配 fix1 manifest；原 r1/fix1 补丁、消息及产物不覆盖。读取 `logs/main-final-1324/full.log` 的五项完整诊断，逐用例原始块保存在 `fix2-work/main-diagnostic-00.txt` 至 `main-diagnostic-04.txt`。该日志与 `mut/summary.json` 的 SHA-256 已记录在本轮反证计划：主会话 fix1 的 25/25 通过是历史证据，不能当成本轮 29 条已运行。

### 实现根因与修复

1. **能耗起始页没有末尾标记。** 在 655×468 的原生内容列，六阶段和 powermetrics 均已出现在同一个滚动文档中，`lightfield.optionsEnd` 完全没有发布。fix1 直接用了底层 `FeatureOptionsScrollView`，漏掉 B2 `FeatureLightfieldOptions` 附带的末尾探针，并非主按钮挤压或等待时间不足。最小扩展 B2 Options：标题可选，不传标题时保留原内容的布局而不插入标题/分隔线，末尾仍走唯一的共用标记。能耗与内存起始页都改用该容器；内存同样直接使用底层 ScrollView，会成为尺寸扫到它时的下一处漏探针。六阶段、真实读数、显式扫描入口和 HelperPowerMetricsView 的采样需求接线均保持原样。
2. **勾选 AX 角色与动作被忽略子元素包装丢失。** 原诊断实际已读到 `Select Google Chrome`，但节点角色为 `AXUnknown`，没有 AXPress。在 B2 `FeatureLightfieldCheck` 最小添加可选 action 与完整 localized label：可操作时将原 20×20 图形放入 Button，再以同一个 Button 回调作 `accessibilityRepresentation`，明确发布 label 和 Selected/Not selected 值。去掉内存行的 `accessibilityElement(children: .ignore)`，保持原 `setMemoryAppUsageSelection` 和 `canRequestMemoryQuitActions` 门禁。装饰用途仍隐藏于 AX；只读系统行仍没有选择控件。未增加退出/清理动作。
3. **退出按钮 AX 使用旧文字。** 日志中的原生主按钮已是 AXButton 且可按，但 label 为 `Quit 1 Apps`，可见文字是 `Quit Selected Apps · 1`。现在页适配器明确传 `actionAccessibilityLabel: actionTitle`，中文为「退出所选应用 · N 个」、英文为 `Quit Selected Apps · N`。仍由同一主按钮调用既有确认流程；勾选不调用主按钮。
4. **大分组测试混用了宿主坐标系。** 两个 nil CGRect 都来自 `frames["fixture.viewport"]`，不是分组帧；它们仍由 `V0LayoutHost` 托管，等待的也是 `v0.viewport`。fix1 在迁移内存宿主时误改了这两个点击位置及 `brightestPixel` 的坐标原点。三处恢复 `v0.viewport`；无需修改安全清理的分组实现或增加光场别名。`testALargeTierOpensItsGroupsWithoutEntranceAnimations`、其 helper、`testGroupsShownInALargeTierStayVisibleWhenItShrinks`、`brightestPixel` 四个完整函数均与 HEAD 逐字相同：小档 3 次入场、240 行 0 次、新增至 320 行仍 0 次、新增组可见，以及缩至 90 行后各组亮度 >0.6 的所有断言保留。这两项仍需主会话实跑来确认 native 动画/像素结果。

没有改 ScanStore、助手协议、HelperPowerMetricsView、布局骨架、动画常量、等待循环、稳定次数或超时；没有修改 `ConceptLandingNativeLayoutRegressionTests` 的判定。

### 断言迁移与新增回归

- `DesignSystemV2ReviewTests.testMemorySelectionCommandsStayAvailableWhateverIsSelected`：按 D67、D70 内存结果页的可见主按钮及本轮明确要求，选中 1/N 时的标签从「退出 N 个应用 / Quit N Apps」迁至「退出所选应用 · N 个 / Quit Selected Apps · N」；零选中对应的否定检查同步名称。可见、AXButton、读出文本、enabled、选择命令始终可用等原断言数量与阈值不变。
- 两项大分组测试的 viewport 及像素 helper 恢复原宿主探针，属于纠正 fix1 的错误替换，没有改期望。安全清理组 ID、动画计数和像素阈值保持不变。
- 新增 `FeatureLightfieldPerformanceTests.testEnergyOptionsKeepPowerMetricsAndTerminalMarkerReachableAcrossSizes`：直接托管生产共用 Options、真实六阶段和 HelperPowerMetricsView，在 655×468 复现尺寸及 B3 七尺寸、日夜下检查文档末尾可滚到、最后一组功率读数可达、主按钮保持 52pt/24pt 间隔；夹具没有需求或请求。无需构造有写操作 home 的 Store。
- 新增 `testMemoryCheckAndSelectedPrimaryPublishLocalizedNativePressAndMatchingFrames`：在中英文、日夜下调用真实 native AXPress，验证 Check 的完整 label/选择值、20×20 框，选中后的主按钮完整 label、52pt 框及与可见控件一致的位置/大小（0.5pt），选择不调用主动作；disabled 继承同时覆盖两个控件。使用 B2 实际控件及同一动作回调，未伪造 AX 节点。
- 原所有测试方法和原 25 条反证对象保持不变。新增四条精确反证：`fix2-options-end-missing`、`fix2-check-ax-action-missing`、`fix2-memory-quit-label-drift`、`fix2-bulk-coordinate-system-mixed`。29 个 before 字串均精确命中一次；本轮不在沙箱里执行变异。

### 本轮验证

- **PASS：编译**，`logs/fix2/build-final.log`，exit 0。初次抽出 glyph 的 opaque View 少写 return，已修复后重新编译；初次失败日志保留，未把失败算通过。
- **PASS：可运行定向**，`logs/fix2/targeted-final.log`，exit 0，294 项、0 失败、1 项既有 opt-in live energy 跳过。两项新增原生用例均在该最终集合中，原有 292 项和跳过条件保持。最初独立的两项用例日志为 `native-controls.log`，加强 AX 原点检查后以最终定向日志为准。
- **BLOCKED：六项 Store 用例**，`logs/fix2/store-dependent.log`，exit 1、6 项/6 失败，均在 `TestFileSystem.swift:60` 创建 `~/.storage-cleaner-scan-store-UUID/home` 时出现 Cocoa 513/POSIX 1 `Operation not permitted`，尚未建立 Store/窗口或执行 AX/像素断言。六项是本轮五个报告失败用例，加上同步主按钮名称的 memory selection command 用例；详细清单见 `prepared/fix2/sandbox-blocked-tests.json`。不得将这一日志作为产品回归通过证据，也未移动夹具或放宽安全检查。其余已知 libproc/CFPreferences 限制见 fix1 的阻断清单。
- **PASS：静态/交付**，`prepared/fix2/static-checks.json`：精确增量范围、31 个前置 SHA、父产物不变、29 个锚点/测试存在、旧测试与断言保留、骨架和需求接线不变、四个大分组函数恢复 HEAD、补丁 forward/reverse 和 r1→fix1→fix2 逐层哈希校验；`git diff --check` 和 `git apply --reverse --check`。
- **NOT RUN：完整定向、全量、29 条反证、离屏截图、提交/合并/安装**，主会话执行。完整定向 27 类预计 318 项，全量预计 4482 项（fix1 实跑数量各加 2）；以本轮实际输出为准。
- **BLOCKED：JEV**，本会话此前调用被要求审批，但权限为 never，未取得模型判断；本轮没有声称通过独立模型复核。

### 主会话复验与交付

精确命令和环境见 `prepared/fix2/validation-command.json`；定向仍用 `prepared/fix2/targeted-classes.txt` 全部 27 类。沙箱内排除已证实权限阻断的正向 filter 另列 `runnable-filter.txt`，不能用它代替主会话完整定向。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
S=~/Developer/.sc-build/r2-lf2-b3
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$S/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$S/prepared/fix2/targeted-classes.txt")"
swift test "${F[@]}" --skip-build
python3 "$S/prepared/fix2/run-counterexamples.py"
# 完整定向通过并把输出保存在主会话日志后执行：
python3 "$S/prepared/fix2/run-counterexamples.py" --execute --green-log <本轮完整定向的绿色日志>
python3 "$S/prepared/fix2/commit-prepared.py"
# 主会话完成完整验证与复核后：
python3 "$S/prepared/fix2/commit-prepared.py" --validated
```

fix2 四组：`01-shared-options-ax`（B2 Options/Check）、`02-performance-adapters`（能耗/内存接线和标签）、`03-native-regressions`（新原生回归及 V0 修复）、`04-handoff`。`all.patch` 仅含 r1+fix1 之后六个文件的增量；manifest 保存前后 SHA 和父 manifest 哈希。新提交器默认只读，能识别原始 HEAD、已提交 r1、已提交 r1+fix1，按需先 index-only 应用原组，再提交 fix2；不覆盖最终工作区、不调用已过时的父提交器。`.git` 只读，未在本沙箱提交。

本轮优先重拍日夜离屏场景：`820x560-energy-landing`、`1000x700-energy-landing`、`677x390-energy-landing`、`1280x390-energy-landing`（选项滚到 powermetrics/末尾）；`820x560-memory-landing`、`677x390-memory-landing`（同一末尾容器）；`1280x763-memory-result`、`677x390-memory-result`、`1280x390-memory-result`（选择、展开、主按钮）。655×468 是失败测试的内容列尺寸，对应整窗 865×496，可补拍 `865x496-energy-landing`。AX 中英文/动作/禁用状态由原生测试验证，截图只做视觉核对。fix1 已列的其余三态矩阵和原试点 smoke 重拍仍保留。

## fix3（2026-10-10，c26a2189 未完成合并与独立复核 P1/P2）

本轮基线是主会话已启动但尚未提交的合并：`task/r2-lf2-b3` HEAD `90a3320b5b719de9ec7c5eaa521233c95a7f3a87`，MERGE_HEAD `c26a2189ec7e029c8c9dea3cbe0a77594e818032`。开工 index SHA-256 为 `cf926a651aef9c33ea51cbd50dcdc5f0082e7cebaa7a58e800ae368c3e972b35`。读取 `logs/codex-review.log` 末尾第 5 条及 P1/P2 完整复核依据。本轮只编辑文件，未 add、commit、abort、checkout 或修改 Git 索引；四个文件已无冲突标记，但索引仍有原四个 UU，合并仍由主会话完成。原 r1、fix1、fix2 产物保留。

### 第 00 组：三方合并意图

- `FeatureLightfield.owns` 保留 B3 startup/memory/energy、B4 updater、B7 largeFiles/migration/duplicates 与三个原试点的并集：14 个 demo 模块中 10 个走光场、4 个保留旧模板。B7 的四个文件页面与 `FeatureLightfield.primaryHeight = 52` 保留；几何使用这个主按钮常量。复核里的“剩余 7 路”对应更早的集成树，本轮 c26a2189 已有 B7，因此迁为 4，并以显式 Set 逐个校验所有权，不删除断言。
- `FeatureLightfieldResults` 使用 B3 的唯一 `LightfieldResultContent` 滚动/摘要分层，保留 76pt 摘要图、短窗口叠图与旧行空白顶带；将 B4 六项 `.inline` 统计放入该组件的 `listHeader`，保留其 summary secondary 分支，避免另造滚动文档或重复 `lightfield.listDocument`。
- `LightfieldStatusGlyph` 同时保留 B3 的可选 symbol/color 和 B4 的 tone；显式 color 优先，tone 次之，再取 status。`LightfieldMetricGroup` 同时保留 B3 的 `showsLabels`/紧凑值与 B4/P2 的 stacked/inline 结构。inline 的 24pt/13pt 内在文字布局、不截断/不缩放策略原样保留；B3 圆环自适应不回退。
- Release 夹具守卫取五个文件并集：原结果夹具、演示路由、B3 性能夹具、B7 文件夹具、B4 应用夹具。测试辅助文件的移动保留，`CalibrationLanguageScope` 只在独立 helper 文件定义一次。B4/P2 卸载列头/列边缘文件、D73/D74 决定与其他自动合并文件没有再次编辑。

`logs/fix3/merge-build.log`：解冲突树单独编译 **PASS，exit 0，207.46s**。`resolved-base/` 是这一阶段的文件快照；随后仅补正路由说明注释，并为未变的 UtilityPresentationPerformanceTests 保存前置快照，没有把 P1/P2 实现混入 00 组。

### P1/P2 根因修复

1. **后台批量命名。** `.task` 属于 View 的主执行器；原逐 PID `EnergyImpactService.executablePath` 为每个 PID 新建缓冲并同步读内核。现在由 `LightfieldEnergyProcessResolver.resolve` 建立一个 utility `Task.detached`，每批仅创建一次既有 `ExecutablePathReader`，复用其 `4 * MAXPATHLEN` 缓冲；kernelRead 和 runningName 为 Sendable 注入点，生产默认仍用 `proc_pidpath` 和 `NSRunningApplication.localizedName`。本机 SDK 的 NSRunningApplication 头文件明确声明实例线程安全；未引入新进程命令、助手请求或协议。bundle 子路径及独立 executable 两项身份门禁完整保留，拒绝退出 PID、相似 bundle 前缀和已复用 PID 后才读取名称。无证据继续显示“进程名称不可用”，不伪造身份。
2. **取消与重采样。** 任务键携带展开状态、app ID/name/path/bundle、PID 集合和采样时间。父任务取消传播给 detached worker，批内检查取消，视图发布前再检查取消；只在主执行器一次性写回结果。新测试实际抓到 onAppear 先展开、旧任务随后读 live `expanded` 的竞态，现改读该任务捕获的 namingRequest，防止旧折叠键启动解析。正常尺寸档切换可以取消旧 appearance 并建立新批，不要求整个宿主生命周期只能有一批。
3. **能耗子行图标。** 已验证的 child 带 name/path/bundlePath 回传；子行复用 B2 `LightfieldAppIcon` 的 medium（24pt），再由它核对当前运行应用 bundle 后读取真实图标。守护进程或无法验证者不给 bundle 路径，使用 B2 灰色 gear 占位；图标与名字间隔 16pt，PID 仍只在 help，子行 AX label 不含 PID。未动 powermetrics 可见性/采样需求所有者。
4. **400 行生产路径。** 夹具保留 400 个真实生产展示模型、七尺寸、日夜、首屏 <60 行、52pt 主按钮、24pt 间距、最后 399 项可达等原断言。首项含 256 PID，并注入既有 reader 的假内核，经过真实后台批量/身份/命名路径；fixture 标志只禁止真实 PID 图标查询，不再绕过命名。每批首读可阻塞，主线程须在读取被持有时完成原几何稳定判定。探针按 reader 批次记录等待、读取和缓冲地址，取消后的批不会覆盖另一批的等待状态。10,000 PID 独立回归仍严格要求 reader factory=1、缓冲地址=1、读取=10,000、所有操作不在主线程。
5. **变高首项与懒列表估算。** 首项改为多 PID 后，短窗实际只能滚到 382–384 项，document 的估算高度持续偏大；不是缺 probe 或需要增加等待。默认展开的首项（包括 More 行）抬高了 LazyVStack 对其余 399 个折叠行的估算。现将这一个首项放在同一滚动文档的 listHeader，带稳定 `.id(first.id)`；其余 app 使用 `ForEach(apps.dropFirst())`，仍由唯一 B2 LazyVStack 虚拟化。全部原几何、首屏数量和末项判定随后通过；没有调整 host 的 120×5ms / 3 稳定、AX 100×5ms 或 0.5pt 精度。

ScanStore、助手协议、HelperPowerMetricsView、运行阶段、显式采样入口和现有退出确认行为没有改。无需 Store 新字段。性能测试/跑分页面不在本批；新增 naming resolver 只处理已有能耗快照。

### 旧断言迁移依据

`UIConsistencyRegressionTests.testMemoryEmptyStateHidesUnavailableActionsAndAvoidsRepeatedMetrics` 原来仍查未被生产路由采用的 MemoryReleasePanel/MemoryProcessSelectionPanel。按 D67、D70⑤及复核 P2，改查实际 LightfieldMemoryPage，19 个原 assert 调用迁为 28 个（循环另覆盖五类装饰），方法保留。逐条意图对应如下；不再用旧面板字符串证明新页行为。

| 原断言 | 新锚点与保留的原意 |
|---|---|
| Used / Total title | 唯一 memoryMetrics 的同名 label，数值为 used / total |
| snapshot.measurements.physicalBytes.value.map | display.measurements.physicalBytes.value.map，未知保留横线 |
| Pressure estimate title | D70⑤ 改为真实 memory trend/chart；占用环用 measuredUsedRatio，不恢复旧面板自算压力说明 |
| 100 − 系统压力余量 | D70⑤ 不以旧公式伪造使用量；measuredUsedRatio 与已有 MemoryPressureLevel/MemoryDomain 测试守护真实来源，图表用实际 trendSamples |
| displaySnapshot: store.menuBarDisplayMemorySnapshot | 原 route 锚点保留，并检查实际委托 LightfieldMemoryPage |
| displaySnapshot ?? snapshot | 原新页锚点原样保留 |
| processSnapshot.cleanupPlan | 表头展示 canonical memoryOutcome(result.status) 与 result.detail，保留真正验证结论而不重复计划标题 |
| selectionPanel 的进程快照 | 新页 Latest Process Snapshot 与历史曲线分开，禁止“该时刻占用最多”归因 |
| 无 Available 重复指标 | metrics 禁止 Available，同时检查四处 unknown 横线及 Cache/Swap 真实值 |
| if !isObserving | primary 的 canRefreshMemory/canRequestMemoryQuitActions 及 selectionCommands disabled 门禁，不提供忙碌时可执行退出 |
| Quit High-Usage Apps 文案 | D70⑤ 的固定主按钮：无选择时 Refresh Memory Snapshot，选中后才退出；命令区从不 requestQuit |
| : cleanupPlan.title | canonical 结果 status/detail；禁止重复 Text(cleanupPlan.title) |
| xmark.circle.fill | D67 扁平空态禁 Image/Material/面板/背景，不恢复退役面板装饰；实际结果语义由 canonical status/detail 读出 |
| checkmark.circle | 同上，结果以真实状态与 detail 表达，不用成功图标暗示清理成功 |
| 禁止 Text(cleanupPlan.title) | 新页同一否定锚点保留 |
| if !apps.isEmpty | groups.isEmpty 的 flat Text；建议按钮额外要求 recommendedQuitApps 非空，退出仍要求选中 |
| if selectedAppCount > 0 | selectionCommands 和 primary 两处 selectedMemoryAppCount > 0 |
| 不用 visibleApps.isEmpty 直接禁掉选择 | 选择用现有 canRequestMemoryQuitActions 门禁；建议项另判 snapshot 的建议集合，不以当前 scope 列表为空破坏其他状态 |
| selectionPanel 不含退出所选应用 | 新 selectionCommands 不含 requestQuit，退出仍仅走 primary 和既有确认 |

另外：

- `FeatureLightfieldPerformanceSourceTests.testPIDsAreTooltipOnlyAndSnapshotChildrenKeepTheirRealIdentity` 把旧 per-PID convenience reader 锚点迁为 detached / reused reader / cancellation / captured key / child B2 icon；两项原身份 guard、PID 仅 help、B2 图标身份/灰占位断言保留。
- `UtilityPresentationPerformanceTests.testLargeEnergyAndUninstallListsUseLazyContainers` 把 ForEach(apps) 迁为稳定 ID 首项在同一 document header、ForEach(apps.dropFirst()) 及共用 LazyVStack 三项；全部原 delegation、lazy 与卸载断言保留。presentation 仍只建一次、maxima 仍共享。
- 原能耗展开 native AX 测试保留所有按下/展开/名称/不可见 PID 断言，新增真实 24pt icon frame 与 16pt 间距。为调用 frames gate，单行 fixture 增加 maxWidth/maxHeight 填满已声明的 878×300 viewport；不改生产行高或稳定预算。

### 实际验证与红/绿证据

| 项目 | 结果与证据 |
|---|---|
| 解冲突阶段编译 | PASS，exit 0，logs/fix3/merge-build.log，207.46s |
| 最终编译含 tests | PASS，exit 0，logs/fix3/build-ready.log，6.69s（增量；此前同产品树完整增量 build-verified.log 36.10s） |
| 最终可运行定向 | PASS，exit 0，325 项、0 失败、既有 1 项 opt-in live energy skip；logs/fix3/targeted-ready.log，31.46s |
| 私有 API 守卫 | PASS，exit 0，python3 script/check_private_api.py：7 个既有 allowlisted uses |
| 反证定位 | PASS：原 29 条对象完整不变；新增 9 条，共 38 个 before 精确一次命中且测试方法存在；实际变异 NOT RUN |
| 交付静态核对 | prepared/fix3/static-checks.json：四组 forward/reverse 回放、raw→resolved→final SHA、原方法/断言保留、原 host 完整不变、保护文件及原 60 个 prepared 产物哈希、Git index 不变 |
| 35 类完整定向、全量、Release、严格并发、离屏截图 | NOT RUN，主会话沙箱外负责；不能以本地可运行子集替代 |
| Git 暂存/提交/abort、安装/发布 | NOT RUN；只编辑文件，未完成 Git 合并 |
| JEV | BLOCKED：本轮 mcp__jev__jev_review 返回 MCP tool call requires approval, but approval policy is never；jev-review.json 保存实际结果，未取得模型判断 |

红日志保留：`build.log` 的未指定空字典闭包类型造成 Sendable 推断失败，补明确返回类型后 build-typed.log 通过；`targeted.log`（326 项/33 断言失败）暴露捕获键竞态、单行宿主 viewport 与一项真实家目录权限阻断；`targeted-final.log`（325 项/1 失败）证明多 PID 首项使短窗末行不可达；`targeted-verified.log`（325 项/50 断言失败）暴露新测试探针跨批覆盖等待状态和错误的“全宿主仅一批”假设。最终按实际 batch 修正探针，并保持单批 10,000 PID/一次分配断言、原几何/稳定预算，得到 targeted-ready.log 的绿色结果。不是延长等待或把产品失败划成权限失败。

本轮确实执行且被权限阻断的一项是 `FeatureLightfieldFileMetadataTests.testDuplicateResultCacheRecoversDatesFromItsAlreadyValidatedSnapshot`：Cocoa 513 / POSIX 1，创建 `~/.storage-cleaner-duplicate-metadata-cache-UUID` 被拒；未进入缓存断言。其余 Store home、libproc 和两个 CFPreferences 写盘方法沿用 fix1/fix2 已证明的限制，本轮未重跑、未改 fixture 位置或产品路径安全。精确说明在 `sandbox-blocked-tests.json`。完整定向清单仍保留全部方法；local runnable-filter 仅报告沙箱可执行子集。

### 交付与主会话复验

`prepared/fix3/` 四组：`00-merge-resolution.patch`、`01-energy-background-names-and-icons.patch`、`02-performance-and-contract-regressions.patch`、`03-handoff.patch`；附 all.patch、message、manifest、merge-input/、resolved-base/、final/ 和只读 verify-prepared.py。第 00 组只改原四处冲突，第 01–03 组从 resolved-base 生成，不夹带自动合并文件。所有工作文件已经是最终版本，**不要在当前 worktree 重复应用补丁**。本轮不提供可写 Git 的提交器，主会话审阅后自行完成当前合并/分组提交。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b3
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
S=~/Developer/.sc-build/r2-lf2-b3
python3 "$S/prepared/fix3/verify-prepared.py"
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$S/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$S/prepared/fix3/targeted-classes.txt")"
swift test "${F[@]}" --skip-build
python3 "$S/prepared/fix3/run-counterexamples.py"
# 完整定向绿日志出来后，在沙箱外执行实际变异；结束后重跑绿色定向。
python3 "$S/prepared/fix3/run-counterexamples.py" --execute --green-log <本轮完整定向绿日志>
# 主会话改变索引或提交后，只核文件可用 --files-only；不会伪称 Git 状态核对通过。
python3 "$S/prepared/fix3/verify-prepared.py" --files-only
```

本轮优先重拍日夜离屏场景：`1280x763-energy-result`、`677x390-energy-result`、`1280x390-energy-result`（首项展开、真实 child icon/灰占位、More、末项）；加 `820x560-energy-result` 检查短表头。合并 smoke：`1280x763-updater-result`、`677x390-updater-result`（六项 inline 统计/主按钮），`1280x763-uninstall-result`、`677x390-uninstall-result`（列头/列对齐），以及 B7 `1280x763-largeFiles-result`、`1280x763-migration-result`、`1280x763-duplicates-result` 和相应 677×390 结果态。B7 文件分析的 `largeFiles` 结果名在默认 surface、`--debug-feature-analysis-types`、`--debug-feature-analysis-largest` 三种参数下分别输出独立目录；相似照片用同一 `duplicates-result` 场景另加 `--debug-feature-similar-photos` 输出独立目录，避免覆盖重复文件图。场景名已核对当前 MainWindowSnapshotPipeline 的 width×height-module-phase.png 规则。原三态七尺寸矩阵、fix1/fix2 其余 smoke 仍保留。截图只作视觉核对；后台线程、身份和 AX 原意仍靠完整定向复验。

## merge（2026-10-10，f17d0415 未完成合并）

本轮按用户要求解决五个冲突文件，未 add、commit、abort 或改写 Git 索引。HEAD 为 `8a3d9a656fe3bd4f4b6fdf6273106cf753eedaea`，MERGE_HEAD 为 `f17d04155eebc845f96dbb1412d190e228da7124`，开工 index SHA-256 为 `0f832c3965fde28641cdaabca6f9fb9133c38ad965199af03a3c1734882a32d2`。文件内冲突标记已去除；索引仍保持原五个 UU，Git 合并由主会话随后完成。用户提供的合并前主会话结果为定向 318/0、全量 4541/0、反证 38/38；这是 HEAD 8a3d9a65 的历史证据，不作为新合并树的验证结果。

### 五处解冲突与双方意图

| 文件 | 解决方式与依据 |
| --- | --- |
| FeatureLightfield.swift | 保留原三试点、B3 startup/memory/energy、B4 updater、B5 privacy、B7 largeFiles/migration/duplicates 的并集。共 11 路迁移；余下 overview/devCaches/performance 共 3 路。`performancePages` 与原反证锚点保留。自动合并的结果摘要/统计列、52pt primaryHeight 与健康状态行初始化路径不回退。 |
| FeatureLightfieldComponents.swift | glyph 同时保留 symbol/color/tone 和 B5 featureStatus 初始化及中英文 AX 标签。B5 的显式 initializer 会替代 Swift 的成员初始化器，因此补全 status initializer 的 symbol/color 默认参数，保持 B3 调用兼容；符号/颜色显式覆盖优先，随后用 featureStatus、tone、原 status。自动合并已保留 B3 真实 PID 图标身份校验、圆环自适应、紧凑指标/展开行和共用结果容器，均未再改动。 |
| FeatureOptionsPresentation.swift | 两个参数取并集：B3 `allowsPartialResultRows` 仍决定紧凑行只在真实边界裁切；B5 `preservesLazyLayout` 仍决定隐私懒加载文档接受视口提议、避免无界理想高度。默认值与各页面现有调用保持，未添加第二套滚动容器。 |
| FeatureLightfieldContractTests.swift | 按 D69/D70 将双方旧 10/4 与 8/6 所有权更新为精确并集 11/3；保留迁移集合和计数断言，补已迁移计数及未迁移精确集合，禁止遗漏或误纳路由。其他测试方法、断言和几何/等待阈值保留。 |
| FeatureLightfieldReleaseIsolationTests.swift | 五个 B3/B4/B7 夹具与六个集成夹具取去重并集，共 7 个：ResultFixture、PresentationDemo、PerformanceFixture、FileResultFixture、ApplicationsFixture、BrowserPrivacyPreviewFixture、BrowserPrivacyRenderProbe。逐个保留严格 `#if DEBUG` 首尾、禁止 DEBUG-or-BETA 和快照管线隔离断言。 |

除这五个源/测试文件外，只追加本交接。开工捕获的 67 个自动合并/重点保护文件 SHA-256 全部不变，含 B5 隐私层级、披露策略、Store/index/夹具、B6 设置与小窗、已迁移测试等；ScanStore 与 B3 能耗/内存生产页、后台 PID 回归不变。`CalibrationLanguageScope` 全树定义仍只有一处。没有新增退出、清理、助手协议、安装或硬件操作。

`targeted-classes.txt` 保留原 35 类，追加 BrowserPrivacyLightfieldTests、BrowserPrivacyLightfieldNativeTests、BrowserPrivacyDisclosureTests、BrowserPrivacyPerformanceTests、PrivacyCleanupPresentationTests，共 40 类。原 38 个 mutation 对象逐字段不变，before 锚点逐条恰好一次命中；无需迁移锚点。根 counterexamples.json 仅更新当前 NOT RUN 状态与用户提供的合并前历史结果；`prepared/merge/anchor-checks.json` 保存本轮位置。

### 实际验证

| 检查 | 本轮结果 |
| --- | --- |
| Debug 编译含测试 | PASS，exit 0，127.42s；`logs/merge/build.log`。 |
| 完整 40 类定向 | FAIL，exit 1，719 项、623 个通过用例、94 个失败用例、2 个既有 opt-in skip；99 个失败记录（91 unexpected），66.894s；`logs/merge/targeted.log`。本轮覆盖范围更广，不能与旧 318 项直接比较数量。 |
| B5 四类 | PASS，22/0：披露 7、原生 6、展示/契约 6、性能 3。包含原起始页尺寸扫描、敏感 AX 边界、50,000 条记录缓存/响应及 <200 域名/<300 页面首屏预算。 |
| B3 后台/身份及可运行原生回归 | PASS：批量 PID 解析 5/0，10,000 PID 主线程响应/单缓冲/身份/取消；400 应用生产命名路径及七尺寸末项、子行 AX/图标、B0 圆环、选中主按钮/checkbox AX、能耗选项末尾。 |
| 私有 API 守卫 | PASS，exit 0；`python3 script/check_private_api.py`，7 个既有 allowlisted uses。 |
| 交付静态核对 | PASS：五个文件 raw→resolved 正向及反向内存回放；resolved-base 与 final 全部逐字节相同；双方测试方法并集保留；67 文件哈希不变；38 锚点精准命中。见 static-checks.json 与只读 verify-prepared.py。 |
| 新合并树全量、Release、严格并发、实际反证、离屏截图 | NOT RUN，主会话沙箱外负责。源码 Release 隔离测试通过不等于实际 Release 构建通过。 |
| Git 暂存/提交/abort、安装/发布 | NOT RUN；索引未写，当前合并尚未完成。 |

94 个失败用例逐项记录于 `prepared/merge/sandbox-blocked-tests.json`，附完整诊断所在日志行。89 项为家目录操作夹具创建被拒（Cocoa 513 / POSIX 1），1 项 libproc 读路径为 POSIX 1，2 项 CFPreferences 有 defaults.plist 的 sandbox_extension_issue_file 拒绝日志，共 92 项有直接权限证据。未调整夹具位置、安全校验、等待预算或断言。

另两项保留 **FAIL，沙箱外原因未验证**，不以“权限”掩盖：`PrivacyCleanupPresentationTests/testCopiedAddressesAreMarkedConcealedAndTransient` 私有命名剪贴板写入 false、types/string 为 nil，5 个断言失败，与 B5 交接中既有现象一致，但本轮没有直接 pboard 拒绝诊断；`SystemUtilitySafetyTests/testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt` 在家目录隔离夹具清理报告 Cocoa 4 / POSIX 2（No such file or directory），没有该用例的直接权限诊断。两项都不涉及五个冲突文件的改动，按范围约束没有改自动合并文件；主会话须复跑确认。两个 skip 分别是既有 live energy 和 live Setapp 只读审计 opt-in，未新增跳过条件。

JEV 为 BLOCKED：本轮真实调用 `mcp__jev__jev_review` 被自动审批拒绝，返回 `MCP tool call requires approval, but approval policy is never`；`jev-review.json` 保存返回值，未取得模型判断、未更换模型或提升权限。

### 交付与主会话复验

`prepared/merge/00-merge-resolution.patch` 仅含五个冲突标记文件到解决后文件的增量。`merge-input/` 留原稿，`stages/1|2|3/` 留三方版本，`resolved-base/` 与 `final/` 各仅五个文件且完全相同；本轮无额外源代码修复组。另提供 `01-handoff.patch`（仅追加本文）和 all.patch 供审阅。不要在当前已解决的工作区重复应用补丁。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b3
S=/Users/developer/Developer/.sc-build/r2-lf2-b3
python3 "$S/prepared/merge/verify-prepared.py"
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$S/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$S/prepared/merge/targeted-classes.txt")"
swift test "${F[@]}" --skip-build
# 使用 prepared/merge/counterexamples.json 在沙箱外执行实际变异，并恢复后复跑绿色定向。
# 主会话暂存或提交后，只核文件时：
python3 "$S/prepared/merge/verify-prepared.py" --files-only
```

核对脚本默认只读：文件/日志/产物哈希、原 38 对象与精准锚点、路由/夹具并集、单个语言 helper、追加交接、补丁正反回放，以及当前 HEAD/MERGE_HEAD/index/五个 UU。没有 apply/add/commit/abort 或写盘分支；`--files-only` 明确标识未核 Git 状态。本轮只保留全类定向结果，不另造排除未证实失败的绿色子集。

主会话离屏 smoke 沿用此前性能/应用/文件场景，补 B5 `1280x763-privacy-landing`、`1280x763-privacy-running`、`1280x763-privacy-result`、`677x390-privacy-result`、`1280x390-privacy-result`，均日夜；隐私结果另核两次敏感披露、展开/懒加载与主按钮。B3 优先 `677x390-energy-result`、`1280x390-energy-result`、`1280x763-memory-result`、`820x560-startup-landing`；B4 `677x390-updater-result` / `677x390-uninstall-result` 与 B7 已列 smoke 保留。截图与实际窗口 AX 仍由主会话验收。
