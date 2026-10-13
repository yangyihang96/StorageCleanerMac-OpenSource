# 批次 r2-u1-preselect：D47 默认勾选全部绿色项 + U1（117／118 风扇模式、029 性能测试页、085 VPN 断开）

- 分支 `task/r2-u1-preselect`，基于集成分支 `7e4e481`（已含 r2-live-fixes-1、r2-live-fixes-2）；worktree `~/Developer/sc-worktrees/r2-u1-preselect`。
- scratch `~/Developer/.sc-build/r2-u1-preselect/`：`debug/`（Debug 与全量测试）、`strict/`（严格并发）、`logs/`（全部日志）、`shots/`（截图）、`dist-before/`、`dist-after/`（截图用 Debug 包；复核轮另有 `dist-before-r2/` 与叠加补丁 `before-overlay/`）、`tools/`（本批截图脚本）。依赖从 `r2-files-fixes/debug` 只读复制（checkouts、repositories、artifacts、workspace-state.json 改写路径），全部构建用 `--skip-update --disable-automatic-resolution` 离线。截图包的编译缓存按 `build_and_run.sh` 的要求放在 `/tmp/storage-cleaner-r2u1-bundle`（脚本只接受 `/tmp/storage-cleaner-*`，本批专用名，不是共用默认目录）。
- 实现：Claude 子代理（Claude Opus 5.5）。来源：DECISIONS D47、D45，《UI改进与升级计划》U1 行与第七节，《UI对照差距清单》117／118、029、085。
- 提交（按顺序）：`769a27e` D47、`c9db241` U1 117／118、`a5a9621` U1 085、`6c9822c` U1 029、`54174c1` U1 029 打磨（居中）、`8dbea54` 交接；复核后：`f45b08b` P1-1(a)、`273316f` P1-1(b)、`ef1fceb` P1-2、`58da842` P2-8／P2-6／P2-10、`6b54606` P2-5、`111d458` P2-3／P2-4、`462f7dc`、`78e43a3`、`c0e006a`、`cb44675`、`88e035c` P2-2 截图夹具与开关、`f0a2337` P2-1 截图管线，以及复核轮交接的提交。
- 没有修改 `Stores/ScanStore.swift`；没有修改 r2-files-fixes 正在复核的 `SystemUtilitiesView.swift`、`LargeFilesView.swift`、`DiskScanner.swift`、`ExternalDriveMigrationService.swift`、`SparkleProvider.swift`、`ReversibleOperationsView.swift`。没有修改 `DECISIONS.md`、`BOARD.md`（RULES：只由主会话记录）。
- 本批中途会话被中断一次（`a5a9621` 之后），恢复后核对：工作区干净、3 个提交在位，从 U1 029 继续；改前截图在中断前已用 `7e4e481` 的包拍好，未受影响。

## 结论

**复核后（2 个 P1、10 个 P2）**：P1-1(a)(b)、P1-2、P2-1、P2-2、P2-3、P2-4、P2-5、P2-6、P2-8、P2-10 全部完成，各有红 → 绿 → 反证（截图管线 P2-1 以截图记录为证）；P2-7、P2-9 按复核意见列入后续；P1-2 的键盘 Tab＋空格 NOT RUN（本机未开“键盘导航”，进实机清单）。复核轮门禁（代码 `88e035c`）：Debug 全量 3517 项、跳过 21、0 失败；严格并发含测试 0 错误；私有接口、空白检查、源码守卫通过。截图 24 组“改前｜改后”，主窗口全部精确尺寸、活动窗口。详见下节“复核后修改”。

第一轮：代码与自动测试：四项全部完成，每项都有红 → 绿 → 反证。截图 14 组“改前｜改后”（深色、浅色各 7 组）。门禁：Debug 全量第 2 次 3510 项、跳过 21、0 失败（第 1 次唯一失败是 N10 计时项，单独重跑通过）；严格并发含测试目标 0 错误、0 并发警告；私有接口检查、`git diff --check 7e4e481 HEAD` 通过（第 6 节）。实机核对按 RULES 没有做（NOT RUN），清单见第 7 节。JEV 对 D47 给出 escalate（不视为批准，第 1.4 节）。

| 项 | 内容 | 结果 | 提交 |
|---|---|---|---|
| D47 | 默认勾选全部绿色项，唯一例外是所属应用正在运行的行；推断不出所属应用的缓存、7 天内有写入的日志也勾选并在行内注明；大体积缓存（单行 ≥ 5 GiB）提示重建代价；黄、红、“清空废纸篓”仍不预选 | PASS | `769a27e` |
| U1 117／118 | 风扇三种模式改为纵向单选卡（图标＋标题＋副标题＋右侧圆形标记），开关只留给“双风扇同步”；只改界面 | PASS | `c9db241` |
| U1 029 | 性能测试页：默认窗口与 900×640 温度圆环完整显示、不被底栏遮住；负载曲线移出圆环，放到圆环下方独立图表区 | PASS | `6c9822c`、`54174c1` |
| U1 085 | 小窗 VPN“断开连接”改破坏性样式（红色描边）并加大点击区域（整宽、30 pt）；只改样式，确认框与请求路径不变 | PASS | `a5a9621` |
| D45 截图 | 2–4 各出深色、浅色“改前｜改后”；主窗口 1280×763.7 与 900×640 两档 | PASS（14 组，见第 5 节） | — |

没有安装、复制到 `/Applications`、启动或退出已安装的测试版／正式版；截图只启动 scratch 里自己构建的 Debug 包副本，用隔离身份 `com.local.StorageCleanerMac.integration`（见第 5 节）。没有写风扇、充电、电源等硬件设置；没有在真实文件上清理；没有 push；没有读凭证。新测试不写真实 `~/Library/Preferences`（语言切换只改测试进程的 volatile argument domain，与既有布局测试同法）。

## 复核后修改（复核结论“修后可合并”：2 个 P1、10 个 P2）

同一 worktree、同一分支续做，没有变基；每项红 → 修 → 绿 → 反证，小步提交。复核时集成分支已到 `7401e72`（含 r2-files-fixes，试合并无冲突）；本轮仍没有改 r2-files-fixes 的文件、`Stores/ScanStore.swift`、`DECISIONS.md`、`BOARD.md`。下文第 1–9 节是第一轮记录，与本节不一致处以本节为准（已在原处加注）。

| 项 | 改动 | 结果 | 提交 |
|---|---|---|---|
| P1-1(a) | `~/Library/Caches` 下能明确识别的开发工具缓存改由开发者规则管理，按 D22 活动分档 | PASS | `f45b08b` |
| P1-1(b) | 识别不出所属应用的行（缓存、日志）执行前复查写入，扫描后有新写入就跳过并写明原因 | PASS | `273316f` |
| P1-2 | 风扇模式卡可被读屏（VoiceOver）按下 | PASS；键盘 Tab＋空格 NOT RUN（见下） | `ef1fceb` |
| P2-1 | 截图管线：精确窗口尺寸、每次截图前激活窗口；性能页 4 张重拍 | PASS | `f0a2337` |
| P2-2 | 补拍 D47 结果页、风扇手动／曲线、双风扇同步（夹具与截图开关） | PASS | `462f7dc`、`78e43a3`、`c0e006a`、`cb44675`、`88e035c` |
| P2-3 | 运行中页面沿用首屏布局：监控位置、尺寸与未运行时相同（默认窗口圆环 162 → 240 pt） | PASS | `111d458` |
| P2-4 | 首屏看不到圆环时（窄窗口上下排、或矮窗口），底栏显示紧凑温度读数 | PASS | `111d458` |
| P2-5 | VPN 管理卡单行说明时上下留白对称 | PASS | `6b54606` |
| P2-6 | 风扇源码契约收窄到卡片视图 | PASS | `58da842` |
| P2-8 | “未识别所属应用”提示改用警示色 | PASS | `58da842` |
| P2-10 | `docs/mini-window-design.md`：选中描边用信息色；“双风扇同步”只在恰好两个风扇时出现，其余写“风扇同步” | PASS | `58da842` |
| P2-7、P2-9 | 复核意见为本批不做 | 列入后续（见下） | — |

### P1-1(a) 开发工具缓存按活动分档

- 根因：`~/Library/Caches/go-build`、`ms-playwright` 等没有专门规则，落入 `system.user-caches`，成为“识别不出所属应用”的绿色行；D47 起默认勾选，工具正在用时也会被带走。
- 改动：`CleanupCoverageCatalog.developerToolCacheDefinitions`（`Models/CleanupCoverageCatalog.swift`）与 `DeveloperToolArtifactCatalog` 的 `developer.claude-code-cli-cache`（`Models/CleanupScanModels.swift`）为下列目录名建开发者规则（类别 `developer`，根 `Library/Caches`），由 `DeveloperCleanupAgePolicy` 按最近写入分档：阈值内红、一年内黄，都不预选；一年以上未改才绿并预选。`system.user-caches` 的排除表同步加入这些名字（容器规则校验要求），规则版本 `2026.10.05.1` → `2026.10.07.1`。
- 名单（只认这些确切目录名）：Go `go-build`、`gopls`、`golangci-lint`；Playwright 浏览器 `ms-playwright`、`ms-playwright-go`；`pnpm`、`Yarn`、`node-gyp`、`typescript`、`deno`、`electron`、`electron-builder`、`Cypress`；Poetry `pypoetry`；`CocoaPods`；Carthage `org.carthage.CarthageKit`；`Mozilla.sccache`；Flutter `flutter_engine`；Claude Code 命令行 `claude-cli-nodejs`。挑选方法：从绿色用户缓存规则里能明确对应到开发工具的名字中选取；本机实际存在的有 `ms-playwright`、`ms-playwright-go`、`pnpm`、`claude-cli-nodejs`、`flutter_engine`（只看了目录名）。
- 测试：新增 `CleanupJunkActionableTests.testDeveloperToolCachesInLibraryCachesAreGradedByActivity`（D47 夹具家目录：新写入的 go-build、ms-playwright 为红且不预选，一年以上未改的为绿并预选）；`CleanupRuleScannerTests.testBundledRulesEncodeStorageAnalyzerDecisionTiersWithNativeSafetyGuards` 加断言：每个名字都在 `system.user-caches` 的排除表里，且有一条 `DeveloperCleanupAgePolicy.applies` 的开发者规则。
- 红：26 个失败（`logs/rv-p1-1a-red.log`）；绿：68 项，跳过 2，0 失败（`logs/rv-p1-1a-green.log`）；反证（撤掉新规则与排除）：28 个失败（`logs/rv-p1-1a-reverse.log`），已恢复。

### P1-1(b) 识别不出所属应用的行：执行前复查写入

- 根因：这类行没有应用可查，执行前的“应用在运行就跳过”对它无效，所以一直可执行。
- 改动：`CleanPlanItem.rechecksWritesAfterScan`（`Models/CleanupExecutionModels.swift`，`ownerResolution == .unresolved` 时为真）；`SafeCleanupExecutor` 预检时对这类行按扫描时同样的方式重读可读部分的最近修改时间（与开发缓存共用 `writesAfterScanSkipReason`，即原有“扫描后有新写入”检查），与扫描时记录不同就跳过，原因 `.candidateBecameActive`；扫描时没有记录基准则同样跳过（失败即保守）。已识别所属应用的行仍按“应用在运行”检查。
- 原因文字两种情况共用：“扫描后仍有新写入或变化，可能正在使用；已跳过，如需清理请重新扫描”（确认面板与完成页）。没有新增跳过原因枚举：`CleanReport` 会持久化，旧版本读不出新值。
- 测试：新增 `CleanupJunkActionableTests.testUnidentifiedOwnerRowsWrittenAfterTheScanAreSkipped`（临时家目录、真实只读扫描器）：未改动时三行都 `.ready`；写入后两条未识别行 `.skipped(.candidateBecameActive)`，已识别的那行仍 `.ready`（改由应用检查）；原因文字断言。
- 红：3 个失败（两条未识别行仍可执行等，`logs/rv-p1-1b-red.log`）；绿：`Cleanup|SafeCleanup|Junk|SmartScan` 411 项，跳过 2，0 失败（`logs/rv-p1-1b-green.log`）；反证（标志恒为假）：2 个失败（`logs/rv-p1-1b-reverse.log`），已恢复。
- JEV（只提交了上面的 diff 摘要、需求原文与测试摘要）：`jev_review` action=**escalate**，safe_to_apply=0.57，composite=0.845（correctness 1.94／置信度 0.91，spec_match 1.97／0.95，test_gap 0.45／0.32，blast_radius 1.39／0.38）。**不视为批准**；低置信度集中在测试缺口与影响面，实机核对见第 7 节第 9 条。

### P1-2 风扇模式卡的读屏按下

- 根因（`ControlPaletteViews.swift`，复核指出的 `:869`）：卡片按钮上的 `.accessibilityElement(children: .ignore)` 新建了一个读屏元素，它带标签和“按钮”特征，却没有按钮的按下动作，AXPress 无效。
- 改动：去掉该修饰与手加的按钮特征，让按钮本身就是唯一元素；只设标签（模式名）、提示（副标题）、值（已选择／未选择／正在应用）与“已选中”特征。
- 测试：新增 `FanControlModeCardTests.testVoiceOverPressChoosesTheMode`：经原生读屏树找到卡片（按钮、标签、提示、值），执行 AXPress，断言选择回调被调用（同 `SafeCleanupScopeCardLayoutTests` 的做法；离屏测试窗口需 `.environment(\.accessibilityEnabled, true)` 才建读屏树）。
- 红：4 个失败（`logs/rv-p1-2-red.log`）；绿：`FanControlModeCardTests|ControlPaletteTests|GeekSensorsPowerHoverDetailTests` 76 项 0 失败（`logs/rv-p1-2-green.log`）；反证（恢复两处旧修饰）：4 个失败（`logs/rv-p1-2-reverse.log`），已恢复。
- 键盘 Tab＋空格：**NOT RUN**。SwiftUI 按钮只有在系统开启“键盘导航”（全键盘访问）后才进入 Tab 顺序；本机该设置未开启，单元测试里也不能切换系统设置。卡片仍是标准 `Button`、未加 `.focusable(false)`，按设计开启后可用 Tab 到达、空格按下；已加入实机核对清单第 8 条。

### P2-1 截图管线：精确尺寸与窗口激活

- 根因：管线用 `setContentSize` 后 `center()`，主屏可见高度只有 746 pt，1280×763.7 被 AppKit 压到 754；截图时窗口不是 key window，控件按非活动样式（去饱和）绘制。
- 改动（`Debug/MainWindowSnapshotPipeline.swift`，仅 Debug／Beta）：`place(_:contentSize:)` 把窗口放到可见区域装得下的屏幕上并设精确尺寸（先试窗口所在屏）；每次截图前 `NSApp.activate()` 并 `makeKeyAndOrderFront`；`capture-sizes.json` 记录 `isKeyWindow`、`appIsActive`；新增 `--capture-main-window-sizes=`、`--capture-main-window-filters=` 只拍需要的尺寸和页面。
- 结果：本轮所有主窗口截图 `actualWidth×actualHeight` 为 1280×764（窗口框按像素取整，与第一轮改前图相同）、900×640、1280×1040，`isKeyWindow`／`appIsActive` 全为 true（`shots/*-perf-*/capture-sizes.json`、`shots/*-d47-*/capture-sizes.json`）。性能页 4 张（2 尺寸 × 深浅）改前、改后都重拍。
- 验证方式：没有为 Debug 管线加单元测试；以上记录即证据。
- 截图脚本（scratch，不在仓库）另修一处：AppKit 把命令行参数按“-键 值”配对，落单的值会被当成要打开的文档，SwiftUI 就不建主窗口。`--debug-smartscan-session results` 放在 `--capture-main-window-directory=…` 之后时 `results` 正好落单，所以第一次拍 D47 结果页 0 张（改前包同样如此，不是本批引入）。`tools/capture-main.sh` 改为把额外参数放在最前。

### P2-2 补拍的截图与所需夹具

- `DebugSmartScanSessionFixture`（`462f7dc`）：带 `--debug-smartscan-d47-rows` 时，用户缓存组前面加入 D47 示例——所属应用识别不出的缓存（640 MB）、所属应用正在运行的缓存（虚构包名 `com.example.editor`）、6.4 GB 的大缓存（超过 5 GiB 重建提示阈值）、7 天内有写入的日志；路径都在 `/DebugFixture` 下。不带该参数时夹具不变，依赖它的测试与扫描历史数字不受影响。`--debug-smartscan-expand-green` 让结果页一出现就展开绿色档及其分组（`78e43a3`、`c0e006a`；`CleanupScanViews.swift` 里 `#if DEBUG` 的 `onAppear`），截图不需要点击。第一版把绿色档的初始值改成了函数，Debug 全量被 `UIConsistencyRegressionTests.testSmartScanResultHierarchyUsesCompactNestedDisclosure`（锁定 `expandedRiskTierIDs` 初始为空、各档默认收起）拦下，`88e035c` 改为 `onAppear` 插入，声明与发布行为恢复原样。夹具里“运行中”的那行原本会被结果页的 A2 运行状态刷新（读本机真实进程）改回“未运行”，行内就不出现“正在运行，清理前需退出”；`cb44675` 让夹具生效时（仅 Debug）跳过这次刷新，A2 源码契约仍通过。
- `MiniWindowDemoData.HardwareControlDemoState.dualFanManual`（`462f7dc`）：两个风扇、手动 65%，用来显示“双风扇同步”开关。只是演示数据，只读夹具协调器仍拒绝一切写入。
- 测试：`DebugSmartScanSessionFixtureTests.testD47ExampleRowsCoverEachPreselectionCase`（四种示例各一行、都是绿色可选；除应用在运行的那行外全部预选；提示与色调）；`HardwareControlPresentationTests`（状态数 22 → 23，双风扇手动两个风扇都是 65%）；`DebugSmartScanSessionReleaseIsolationTests` 检查展开开关与跳过刷新都在 `#if DEBUG` 内。
- 红：夹具测试 2 个失败（`logs/rv-p2-2-fixture-red.log`）；绿：10 项 0 失败（`logs/rv-p2-2-fixture-green.log`）、双风扇 59 项 0 失败（`logs/rv-p2-2-dualfan-green.log`）、展开开关 5 项 0 失败（`logs/rv-p2-2-expand-green2.log`）、跳过刷新与 A2 契约 30 项 0 失败（`logs/rv-p2-2-fixture-running-owner.log`）、改为 `onAppear` 后 `UIConsistencyRegressionTests` 等 76 项 0 失败（`logs/rv-gate-fix-ui-contract.log`）；反证：去掉“运行中”行的运行包名并把大缓存改为 4.4 GB → 1 个失败（`logs/rv-p2-2-fixture-reverse.log`）；去掉双风扇的第二个风扇 → 1 个失败（`logs/rv-p2-2-dualfan-reverse.log`）。均已恢复。
- 改前截图：用 `7e4e481` 加上同样的 Debug 截图文件（管线、夹具、演示数据，以及 `CleanupScanViews.swift` 里作用相同的 `#if DEBUG` 展开开关与跳过刷新；展开开关用的是第一版写法）构建（`dist-before-r2/`，构建信息 commit 7e4e481、dirty=true）；产品代码就是 `7e4e481`。叠加改动存为 `before-overlay/7e4e481-debug-capture-overlay.patch`；临时 worktree（`git worktree add --detach`）拍完已移除，`/tmp/storage-cleaner-r2u1-before` 编译缓存已删。

### P2-3 运行中监控不再缩小

- 根因：运行中把监控叠在进度下方并固定 330 pt，默认窗口下圆环约 162 pt，负载图表大半被底栏挡住（改前证据：监控下沿 750 pt，底栏上沿 640 pt）。
- 改动：`BenchmarkLandingLayout`（`BenchmarkV7PerformancePresentation.swift`）统一首屏排法：放得下时左卡右监控（理想宽 300＋16＋300，与原 `ViewThatFits` 断点相同），否则上下排。未运行时左边是测试卡，运行中左边换成进度（`BenchmarkV7RunProgressView` 不再内嵌监控），监控位置与尺寸不变（高度同为 `landingHeight`）。默认窗口运行中圆环 240 pt、整个监控在底栏上方；900×640 运行中约 160 pt（未运行约 152 pt，两者底栏高度不同），也都在底栏上方。
- 测试：`BenchmarkMonitorLayoutTests.testRunningTestKeepsTheLandingMonitorAndDialSize`（真实页容器 `MainContentHost`＋页头＋看板，1280×763.7、900×640、677×764，中英文、深浅色）：前两种圆环 ≥ 230／140 pt、为正圆、整个监控在底栏上方并与进度并排；677×764 上下排并有紧凑读数。
- 截图：运行中状态无法在 App 里安全触发（会真的跑性能测试），改为布局测试把实测画面存成 PNG（设 `STORAGE_CLEANER_LAYOUT_EVIDENCE` 时才写，未设时不写文件）。

### P2-4 窄、矮窗口保留紧凑温度读数

- 改动：`BenchmarkCompactTemperature`（温度计图标＋“芯片温度 61°C”，读的是圆环同一份最新采样），在首屏看不到完整监控时放进底栏、紧挨主按钮；条件 `BenchmarkLandingLayout.showsCompactTemperature`：上下排（内容宽 < 616 pt，如 677×764、820×520、677×390），或滚动区在选择器下方的可见高度不到监控最小高度 250 pt（如 1280×390）。默认窗口、900×640、1000×700 不显示（圆环已在首屏）。底栏三档排法（一行；说明一行＋读数与按钮一行；说明、读数、按钮各一行），最窄时也不把按钮挤出。
- 测试：`testNarrowAndShortWindowsKeepACompactTemperatureReading`（677×764、1280×390 显示且在底栏内、在首屏；1280×763.7、900×640 不显示；中英文、深浅色）；`OfficialBenchmarkPlanTests.testFirstScreenArrangementAndCompactTemperatureReading`（断点、矮窗口边界、零尺寸与非有限尺寸不显示且高度有限）。
- P2-3／P2-4 红：32 个失败（`logs/rv-p2-3-4-red.log`）；绿：`BenchmarkMonitorLayoutTests|OfficialBenchmarkPlanTests|ControlPaletteTests|UIConsistencyRegressionTests` 104 项 0 失败（`logs/rv-p2-3-4-green.log`）；反证 ① 紧凑读数恒不显示：14 个失败（`logs/rv-p2-4-reverse.log`）；反证 ② 运行中改回“进度下方、固定 330 pt”：20 个失败（`logs/rv-p2-3-reverse.log`）；恢复后 16 项 0 失败（`logs/rv-p2-3-4-restored.log`）。

### P2-5、P2-6、P2-8、P2-10

- P2-5（`GeekNetworkView.swift`，管理卡内容）：说明只有一行时内容贴顶，上方 6 pt、按钮下方 20 pt。改为在卡内垂直居中：一行时上下各约 13 pt，两行时各 6 pt。`GeekVPNManagementActionTests` 加对称断言（±1 pt，PPP、第三方、系统三种隧道，中英文）。红：2 个失败（`logs/rv-p2-5-red.log`）；绿：87 项 0 失败（`logs/rv-p2-5-green.log`）。
- P2-6：`FanControlModeCardTests` 的源码契约只截取 `FanControlModeCard` 到 `FanControlModeSelectionMark` 的源码检查“不用胶囊”，不再禁止整个文件里出现胶囊；反证：往卡片里放一个胶囊仍失败（`logs/rv-p2-6-reverse.log`）。
- P2-8：`CleanupCandidateRowHint` 中“未识别所属应用，清理前无法确认它是否在运行”色调由次要色改为警示色（与日志提示一致）。红：1 个失败（`logs/rv-p2-8-red.log`）；P2-6／P2-8 绿：24 项 0 失败（`logs/rv-p2-6-8-green.log`）。
- P2-10：见上表；文档改动在 `58da842`。

### 不做、列入后续

- P2-7：手动模式面板高度只余约 5 pt。本轮没改；双风扇手动（多一行“双风扇同步”）的新截图里面板仍完整，但余量更紧，建议后续把预算测试扩到双风扇手动状态。
- P2-9：“选择推荐项目”与默认预选在“绿色但规则不推荐”的行上不同（第 8 节第 2 条）。本轮没改。

### 本轮发现的既有问题（未修，建议后续）

1. 性能页顶部分段选择器在英文、约 900 pt 宽的窗口里有时按理想宽度 686 pt 排版，超出 624 pt 可用宽度，“Community submissions”被裁（布局测试宿主里改前代码同样复现，是否出现与排版先后有关）。中文标签短，不受影响。可考虑窄宽度时改用较短英文标签或菜单样式。
2. 见 P2-1：`--debug-smartscan-session results` 的取值落单时主窗口不出现（夹具入口的参数形式问题，代码未改）。
3. 上下排（窄窗口）时，运行中与未运行一样，圆环在首屏下方、被底栏遮住一部分，需要滚动；温度由紧凑读数补足。

### 测试卫生

本轮新增的测试都不写真实 `~/Library/Preferences`：语言切换只改测试进程的 volatile argument domain（`git diff 7e4e481 HEAD -- Tests` 里新增的偏好相关代码只有这一种）；其余新增测试不碰偏好。复核点名的 `CleanupRuleScannerTests.testTopLevelSelectAllSelectsOnlyGreenCandidates`、`testScanOnlyFeatureFlagDisablesAllLegacyTrashEntryPoints` 本批没有修改，仍按原样写真实偏好域（留待 D48 清理方案处理）。

### 复核轮截图（`~/Developer/.sc-build/r2-u1-preselect/shots/pairs-review/`，24 组）

| 内容 | 深色 | 浅色 |
|---|---|---|
| P2-1 性能测试 1280×763.7（精确尺寸、活动窗口） | `p2-1-performance-1280x763-dark.png` | `p2-1-performance-1280x763-light.png` |
| P2-1 性能测试 900×640 | `p2-1-performance-900x640-dark.png` | `p2-1-performance-900x640-light.png` |
| P2-2 D47 结果页 1280×1040（绿色档与分组展开：徽标、行内提示、分组文案） | `p2-2-d47-results-1280x1040-dark.png` | `p2-2-d47-results-1280x1040-light.png` |
| P2-2 D47 结果页 1280×763.7（同上，默认窗口首屏） | `p2-2-d47-results-1280x763-dark.png` | `p2-2-d47-results-1280x763-light.png` |
| P2-2 风扇手动 65% | `p2-2-fan-fanManual65-dark.png` | `p2-2-fan-fanManual65-light.png` |
| P2-2 风扇曲线 | `p2-2-fan-curveActive-dark.png` | `p2-2-fan-curveActive-light.png` |
| P2-2 双风扇手动（“双风扇同步”开关） | `p2-2-fan-dualFanManual-dark.png` | `p2-2-fan-dualFanManual-light.png` |
| P2-3 运行中 1280×763.7 | `p2-3-4-running-1280x763.7-dark.png` | `p2-3-4-running-1280x763.7-light.png` |
| P2-3 运行中 900×640 | `p2-3-4-running-900x640-dark.png` | `p2-3-4-running-900x640-light.png` |
| P2-3／P2-4 运行中 677×764（上下排＋紧凑读数） | `p2-3-4-running-677x764-dark.png` | `p2-3-4-running-677x764-light.png` |
| P2-4 未运行 677×764 | `p2-3-4-idle-677x764-dark.png` | `p2-3-4-idle-677x764-light.png` |
| P2-4 未运行 1280×390 | `p2-3-4-idle-1280x390-dark.png` | `p2-3-4-idle-1280x390-light.png` |

- App 截图（P2-1、P2-2）：改前 = `7e4e481` 加同一套 Debug 截图文件（`dist-before-r2/`，构建信息 dirty=true；叠加的改动存为 `before-overlay/7e4e481-debug-capture-overlay.patch`，只有管线、夹具、演示数据和 `CleanupScanViews.swift` 里的 `#if DEBUG` 开关）；改后 = `88e035c`（`dist-after/`，dirty=false；与最终 HEAD 的产品代码相同，之后只有本交接）。主窗口每张的尺寸与 `isKeyWindow`／`appIsActive` 见各目录 `capture-sizes.json`（全部 1280×764 或 900×640 或 1280×1040，全部 true）。小窗“日间”按 D44⑤ 仍是石墨深色。性能页的温度、负载是截图当时本机的实时读数，前后不是同一时刻，不作数值对比。
- 布局测试证据（P2-3、P2-4）：同一个测试在改前代码（`6b54606`，红灯那次运行）与改后代码（`111d458`）各存一份，只含详情栏（无侧栏），监控用测试里的固定采样（61°C），不是实时数据；原图含中英文两种语言：`shots/p2-3-4-{before,after}/`。
- 原图目录：`shots/{before,after}-perf-{dark,light}/`、`shots/{before,after}-d47-{dark,light}/`、`shots/{before,after}-mini-fan-{dark,light}/`；拼图脚本 `tools/make_pairs_review.py`，整套拍摄脚本 `tools/capture-review-set.sh`。小窗偶发漏拍（第 5 节所述）本轮仍有：改前深色第一次 0/3、浅色漏 1，改后浅色漏 2，都单独补拍齐全（补拍目录 `shots/before-mini-fan-light-r2/`、`shots/after-mini-fan-light-r2/`、`shots/after-mini-fan-light-r3/`，图已复制进对应目录）。

### 复核轮门禁（代码在 `88e035c`；之后只有本交接文档）

日志在 `~/Developer/.sc-build/r2-u1-preselect/logs/`。

| 门禁 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| Debug 全量，第 1 次（`cb44675`） | `swift test --scratch-path …/debug --jobs 4 --skip-update --disable-automatic-resolution` | 1 | 3517 项，跳过 21，**失败 1**：`UIConsistencyRegressionTests.testSmartScanResultHierarchyUsesCompactNestedDisclosure`——本轮 Debug 截图开关改了它锁定的 `@State private var expandedRiskTierIDs: Set<String> = []`。没有改测试，改实现（`88e035c`，见 P2-2） | `gate-review-debug-full.log` |
| Debug 全量，第 2 次（`88e035c`） | 同上 | 0 | **3517 项，跳过 21，0 失败**，198 s（负载约 5–7） | `gate-review-debug-full-2.log` |
| 严格并发（含测试目标，删掉构建产物后完整重编） | `swift build --build-tests -Xswiftc -strict-concurrency=complete --scratch-path …/strict --jobs 4 --skip-update --disable-automatic-resolution` | 0 | 0 错误；唯一编译警告仍是基线已有的 `BrowserPrivacyRecoveryTests.swift:474`（非并发警告）；另有 `--skip-update` 弃用提示；370 个任务，98.4 s | `gate-review-strict-tests-clean.log`（先跑的一次增量构建结果相同：`gate-review-strict-tests.log`） |
| 私有接口检查 | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `gate-review-private-api.log` |
| 空白检查 | `git diff --check 7e4e481 HEAD` | 0 | 无输出（交接提交后重跑） | `gate-review-diff-check.log` |
| `verify.sh` 中的源码守卫 | Views 不起进程／不 terminate；内存功能不 purge；无冲突副本 | 0 | 三项均通过 | `gate-review-source-guards.log` |
| 截图用 Debug 包 | `STORAGE_CLEANER_SKIP_TESTS=1 BUNDLE_CONFIGURATION=debug SWIFT_BUILD_DIR=/tmp/storage-cleaner-r2u1-bundle … script/build_and_run.sh --bundle-only`（改后最终 `88e035c`，改前 `7e4e481`＋Debug 截图叠加，编译缓存 `/tmp/storage-cleaner-r2u1-before`，已删） | 0 | 只用于离屏截图；前置测试按变量明确跳过（脚本打印 NOT RUN），签名与 Sparkle 校验照常通过 | `bundle-after-r7.log`、`bundle-before-r5.log` |
| Release 全量、小窗性能脚本 | — | — | NOT RUN（同第一轮：完整门禁由主会话在集成分支跑） | — |

计时类测试（N10）本轮两次全量都没有失败，没有改任何阈值。

## 1. D47：默认勾选全部绿色项

### 1.1 现状与根因

- 预选判断在 `ScanCandidate.isHeldBackFromPreselection`／`isPreselectedByDefault`。改前：缓存行“所属应用识别不出（`ownerResolution == .unresolved`）”不预选（D22）；日志行“7 天内有写入或无法确认”不预选（D40）；并且要求规则级 `defaultSelection == .selected`。
- 盘点规则数据：内置 JSON 与 `CleanupCoverageCatalog` 里非开发者的绿色规则本来就是 `recommended／selected`；开发者缓存规则（npm、Homebrew、uv、Xcode DerivedData、pip、SwiftPM、Clang、Bun、Playwright MCP、各 AI 工具缓存）规则级的“optional／unselected”只是占位，由活动分档（`DeveloperCleanupAgePolicy`）取代，绿色档（一年以上未改）本来就是 `selected`。所以**目录里的绿色规则不需要改 `defaultSelection` 数据**；产品里 D47 实际改变的只有上面两类被挡住的行。为了不再依赖规则数据，判断改为“绿色即预选”，规则级取值对绿色行只剩 `forbidden` 起作用（校验器本来就不允许绿色规则用 `forbidden`）。

### 1.2 改动

- `Models/CleanupScanModels.swift:906-927`：
  - `isHeldBackFromPreselection` 只剩 `isOwnerRunning`；
  - `isPreselectedByDefault = selectionEligibility == .selectable && defaultSelection != .forbidden && !isOwnerRunning`（`.selectable` 只给绿色、直接移入废纸篓、无需额外审阅的行，黄、红、清空废纸篓天然排除）；
  - “选择推荐项目”（`isRecommendedForSelection`）仍按规则的“推荐”取项，只是挡住条件换成同一个“应用在运行”。内置规则的绿色行全是“推荐”，产品里与默认预选一致。
- `CleanupRecommendationDisplayPolicy.level(for:)`（`:1006`）：识别不出所属应用的缓存不再降为“可选”徽标（它现在被预选，显示“推荐”）。
- 行内提示抽成 `CleanupCandidateRowHint`（`:1050`），视图 `CleanupScanViews.swift:2369` 使用：
  - 日志“最近 7 天内仍有写入”“无法确认最近 7 天内是否有写入”（原样保留）；
  - 新增：识别不出所属应用的缓存行显示“未识别所属应用，清理前无法确认它是否在运行”（次要色；复核 P2-8 起改为警示色）。原来靠“可选”徽标表达，现在徽标是“推荐”，这句话补上这层信息。
- 新增 `CleanupRebuildCostPolicy`（`:1024`）：缓存类行（浏览器、应用、系统、开发缓存，不论风险等级；日志、下载、邮件附件副本、重复应用副本、废纸篓除外）估算占用 ≥ 5 GiB 时，行内另起一行“体积较大：重建需要重新下载或生成，可能较慢”（`CleanupScanViews.swift:2236`）。
- 文案：绿色分组说明（`CleanupScanViews.swift:306、310`）、规则说明（`ReadOnlyCleanupScanner.swift` 的 `CleanupRuleCopy`：用户缓存、诊断日志、应用日志、用户日志、开发工具日志）改为 D47 口径；“软件未运行时默认勾选”的已知缓存说明本来就符合 D47，未改。界面文字不含内部编号。
- 文档：`docs/cleanup-rules.md` 规则表“默认预选”列与“默认预选与所属应用”一节改为 D47。

### 1.3 锁定 D22／D40 旧规则的测试（按 D47 修改）

| 测试 | 原来锁定 | 现在（D47） |
|---|---|---|
| `CleanupLogPreselectionTests.testLogsArePreselectedOnlyAfterSevenQuietDays` → `testGreenLogsAndCachesArePreselectedUnlessTheirAppIsRunning` | D40：7 天内写入的日志不预选；D22：识别不出所属应用的缓存不预选、徽标“可选” | 只有应用在运行的日志不预选；近期写入的日志、识别不出所属应用的缓存都预选；写入状态仍记录（提示用）；徽标“推荐” |
| `CleanupLogPreselectionTests.testALogRowThatCannotBeReadCompletelyIsNotPreselected` → `…IsPreselectedAndSaysSo` | D40：部分不可读的日志不预选 | 预选，行内提示“无法确认最近 7 天内是否有写入”（改为断言共享提示函数，源码检查改为视图调用该函数） |
| `CleanupJunkActionableTests.testPreselectionSkipsRunningOwnersAndUnidentifiedRows` → `testPreselectionSkipsOnlyRowsWhoseAppIsRunning` | D22：识别不出所属应用的行与 7 天内写入的日志不预选 | 只排除应用在运行的行（`com.example.running`、运行中的 Chrome）；新增两条提示文案断言 |
| `CleanupRuleScannerTests.testExactNameMatcherIsCaseSensitiveAndUnicodeCanonicalEquivalent` 末条 | 规则级“optional”的绿色夹具行不预选（D22 之前的规则级语义） | 绿色行预选（该夹具规则不按开发者活动分档） |
| `DebugSmartScanSessionFixtureTests.testFixtureContainsDeterministicSafeReviewAndProtectedCandidates` | 截图夹具默认只选 1 个“推荐”绿色行 | 两个绿色行都选，黄、红不选 |
| `CleanupRuleScannerTests` 两处注释、`testStorageAnalyzerGoldenSnapshot…` 注释 | D22／第 10 项措辞 | 改为 D47 措辞（断言未改） |

新增 `CleanupDefaultSelectionPolicyTests`（4 个，内存中构造行，不碰文件系统）：绿色各种情形预选、应用在运行／黄／红／清空废纸篓不预选、应用退出后恢复预选、取消的扫描不预选；“推荐”徽标与三种行内提示；5 GiB 阈值（含边界、少 1 字节不提示）与不提示的类别；视图使用共享提示、分组文案不再写旧条件。

### 1.4 红 → 绿 → 反证

| 步骤 | 结果 | 日志 |
|---|---|---|
| 红（提示已实现、预选逻辑未改） | 67 项中 27 个断言失败，全部是预选与徽标 | `logs/d47-red.log` |
| 绿 | 67 项，跳过 2，0 失败；扩大到 `Cleanup|UIConsistency|SafeCleanup|SmartScan|DebugSmartScan|Junk` 395 项，跳过 2，0 失败 | `logs/d47-green.log`、`logs/d47-broad.log` |
| 反证 1：恢复旧 `isHeldBackFromPreselection`／`isPreselectedByDefault` | 23 个失败（5 个类都有）→ 已恢复 | `logs/d47-reverse.log` |
| 反证 2：关掉“未识别所属应用”与“重建代价”两条提示 | 16 个失败 → 已恢复 | `logs/d47-hints-reverse.log` |

开发中途一度把“选择推荐项目”也改成等于默认预选，`testStorageAnalyzerGoldenSnapshot…`（黄色但规则“推荐”的夹具行）因此失败；按最小改动原则改回“按规则推荐取项”，只换挡住条件，测试恢复通过（见 1.2）。

JEV（只提交了上面的模型 diff、需求原文与测试摘要，没有个人数据）：`jev_review` action=**escalate**，safe_to_apply=0.52，composite=0.745（correctness 1.65／置信度 0.48，spec_match 1.79／0.69，test_gap 0.19，blast_radius 1.86）。JEV 没有给出理由，**不视为批准**；影响面大是 D47 本身的性质（所有用户的默认勾选都变了），需要复核与实机核对（第 7 节）。

## 2. U1 117／118：风扇模式改为纵向单选卡

- 根因：`ControlPaletteViews.swift` 的 `ControlPaletteModeRow` 画的是 32×18 胶囊开关，三种互斥模式看起来像能同时打开的三个开关（差距清单 117／118，`docs/mini-window-design.md` 早已写明应为单选卡）。
- 改动：
  - `FanControlModeChoice`（`ControlPaletteViews.swift:739`）：面板提供的三种模式及其标题、副标题、图标——自动控制／交给 macOS 动态调节（`fanblades`）、自定义风扇曲线／按温度曲线调节转速（`chart.xyaxis.line`）、手动控制／直接设置目标转速（`slider.horizontal.3`），都复用 `AppSymbols` 既有常量。
  - `FanControlModeCard`（`:792`）：图标、标题（主文字色，不再是链接蓝）、副标题、右侧 16 pt 圆形标记（`FanControlModeSelectionMark`，`:885`）；整张卡可点；只有选中的卡加信息色描边与浅底；应用中显示小转圈。卡高 36 pt、卡间距 2 pt。
  - 选择仍只改草稿（`draft.selectMode`），“应用”与回读确认流程没动；面板打开不触发辅助程序。
  - 手动区的同步开关是面板里唯一的开关，文字改为“双风扇同步”（两个风扇时；其他数量为“风扇同步”，`FanControlInlineControls.swift:184`），读屏标签不变。
  - `docs/mini-window-design.md` 风扇控制一节补写卡片尺寸与预算。
- 高度：卡片比原行高，但既有尺寸矩阵 `ControlPaletteTests.testFanPaletteNativeLayoutMatrixFitsAndKeepsHardwareReadOnly` 的预算（自动紧凑 ≤ 230 pt、手动 ≤ 280 pt）**没有放宽**。第一版卡（40 pt、间距 4）超出 11–25 pt 被它拦下，改成 36 pt、间距 2、英文曲线副标题改短（“Follows a temperature curve”，避免折行）后通过。
- 测试：新增 `FanControlModeCardTests`（3 个；复核后加读屏按下测试为 4 个，源码契约收窄，见“复核后修改” P1-2、P2-6）：三种模式与文案图标；中英文、选中／未选中各 12 种卡片的实际布局（圆形标记 16×16、位于右侧并垂直居中，图标在左，副标题在标题下方且都在标记左边，卡宽 248、卡高 ≥ 35.5）；源码契约（用卡片、不再有 32×18 胶囊，同步开关仍是开关并写“双风扇同步”）。`GeekSensorsPowerHoverDetailTests.testFanModeUsesSingleChoiceControlsWithoutFakeManualAccess` 原来锁定开关填充色一行，改为断言使用单选卡（依据：已批准的 U1 计划 D44、D45，与设计文档）。
- 红：新类型不存在，编译失败（`logs/fan-red.log`）。绿：`FanControlModeCardTests|GeekSensorsPowerHoverDetailTests|ControlPaletteTests|FanControl` 136 项，0 失败（`logs/fan-green.log`）。反证：把圆形标记换回 32×18 胶囊：25 个失败（12 种卡片的标记尺寸与位置断言 24 条，源码契约 1 条，`logs/fan-reverse.log`），已恢复。

## 3. U1 029：性能测试页温度圆环完整、负载曲线移出

- 根因：`BenchmarkSystemMonitor` 把 0–100% 负载曲线画在 0–100 °C 圆环里（量纲混用）；圆环最大 380 pt，叠在 CPU／GPU 小环下面，默认窗口下整块约 520 pt 高，而底栏上方可见约 441 pt，圆环下部被底栏遮住；900×640 时测试卡和监控只能上下排，监控整个在测试卡下面，首屏只露出“系统实时监控”标题（改前截图）。
- 改动：
  - `BenchmarkV7PerformancePresentation.swift:444` `BenchmarkMonitorLayout`：给定监控内容的宽高，分出圆环直径（≤ 240 pt，并给右侧 CPU／GPU 小环留位）与图表高度（80–120 pt，取可分高度的 38%）；非有限或非正尺寸一律得 0。
  - `BenchmarkSystemMonitor`（`:502`）：页头（标题＋最近采样时间）；一行居中排完整圆环与 CPU、GPU 两个小环；圆环下方独立的负载图表区（“当前负载 ● CPU ● GPU · 最近 2 分钟 · 0–100%”、百分比纵轴、沿用 `GeekPrecisionLineChart`）。圆环中心只显示“芯片温度”、读数和“0–100°C”。原来页头右上孤立的温度数字去掉（读数在圆环里）。
  - `BenchmarkV7DashboardView.swift:84`：用 `GeometryReader` 量出滚动区可见高度，`BenchmarkMonitorLayout.landingHeight`（`:494`）减去页内边距、分段选择器（按 28 pt 预留）与间距，得到监控高度（250–430 pt），所以整个监控在底栏上方。测试卡与监控的并排宽度改为理想 300＋300（`:187-189`），900 宽的窗口也并排。
  - `PerformanceBenchmarkWorkspaceView.swift:139` 抽出 `PerformanceBenchmarkPageChrome`（页头与说明弹层），工作区和布局测试共用，测试量到的就是真实页头。
  - 打磨（`54174c1`）：默认窗口下圆环行右侧留出大块空白（第一轮改后截图），改为圆环与小环整组居中。
- 测试：
  - `BenchmarkMonitorLayoutTests.testNativeMonitorKeepsTheChartInsideTheDialAtWideAndNarrowWidths`（锁定“图表在圆环内”）换成 `testLoadChartSitsOutsideACompleteTemperatureDial`：五种尺寸下圆环为正圆、图表在圆环下方且不相交、图表占满监控宽度、监控不超过给定高度。
  - 新增 `testTemperatureDialIsCompleteAboveTheStatusBarAtDefaultAndCompactWindows`：真实页容器（`AdaptivePageViewport`＋`PerformanceBenchmarkPageChrome`＋`BenchmarkV7DashboardView`），1280×763.7、900×640、1000×700 三种窗口的详情栏尺寸，中英文：圆环与整个监控都在底栏上方、圆环直径 ≥ 140 pt、监控在第一行（与测试卡并排）。实测（测试窗口坐标，取自反证日志：反证 ② 只把图表叠进圆环，圆环位置与修复版相同；反证 ① 给出底栏位置）：1280×763.7 圆环下沿约 460 pt、底栏上沿 628 pt；900×640 圆环下沿约 372.5 pt、底栏上沿 512 pt。
  - `OfficialBenchmarkPlanTests` 中锁定旧几何的三条改写：`testMonitorDialAndChartShareTheGivenHeight`、`testMonitorKeepsTheDialAndTheChartSeparateThroughContinuousSizes`（宽 200–600、高 234–480 连续扫描：圆环＋小环不超宽、圆环＋图表＋文字不超高、图表 ≥ 80 pt）、`testInvalidMonitorDimensionsCannotProduceNonFiniteViewFrames`；新增 `testLandingMonitorHeightFollowsTheVisibleScrollArea`。源码契约（`Text("100%")`、`GeekPrecisionLineChart(`、两个通道、`value: telemetryPoints.last?.cpuTotal` 等）原样保留并通过。
  - 依据：U1 计划（D44 批准）写明“性能页默认窗口完整显示温度圆环（900×640 也完整），圆内不再混画负载曲线”，D45 打磨要点同。
- 红：新接口不存在，编译失败（`logs/bench-red.log`）。绿：13 项 0 失败（`logs/bench-green.log`、`logs/bench-green2.log`）；扩大到 `Benchmark|UIConsistency|SafeCleanupLayout|ConceptLanding|Performance` 594 项，跳过 6，0 失败（`logs/bench-broad.log`）。中途 `UIConsistencyRegressionTests.testMainWindowTextAvoidsSmallSemanticFontOverrides` 拦下圆环文字用的 `.minimumScaleFactor`（项目只允许两处使用），已去掉并加宽文字框。
- 反证：① 监控高度固定 560 pt＋恢复旧并排宽度 340／360：三种窗口、中英文 18 个失败（`logs/bench-reverse-page.log`）；② 把图表叠回圆环里：21 个失败（`logs/bench-reverse-chart.log`）。均已恢复。
- 复核后：运行中页面改为与首屏同一排法（P2-3），窄、矮窗口底栏加紧凑温度读数（P2-4），并排判断由 `ViewThatFits` 改为 `BenchmarkLandingLayout`（断点不变），见“复核后修改”。

## 4. U1 085：VPN“断开连接”

- 根因：`GeekVPNHoverDetail.managementCard` 用小号 `.bordered` 蓝色文字按钮（约 20 pt 高），断开属破坏性操作（差距清单 085）。
- 改动（`GeekNetworkView.swift`）：
  - `actionPresentation(for:)`（`:790`）：只有 macOS 断开请求是破坏性的；打开 VPN 应用、打开系统设置不是。
  - `GeekVPNManagementActionButton`（`:894`）：整宽、30 pt 高、圆角描边按钮；断开用 `Palette.destructive` 红色描边与浅红底、`role: .destructive`，其余两种用信息色。点按仍走原来的 `requestAction`：断开先弹“断开 VPN？”确认框，请求路径未改。
  - 管理卡高度（`:745`）：隧道有服务标识或提供方应用（可能出现操作按钮）时 76 pt，否则仍 64 pt；只读隧道本身，不跑 SystemConfiguration 预检，网络页渲染不增加开销。
  - 操作结果文字改为替换说明文字（原来追加两行，卡片固定高度下会溢出）。
- 测试：新增 `GeekVPNManagementActionTests`（3 个）：破坏性映射（含预检失败时不出按钮）；用演示 PPP、第三方、系统三种隧道在中英文实际布局：按钮宽度 = 卡宽 − 2×8、高 ≥ 29.5，按钮在卡内、卡在面板内（注入的控制动作一旦被调用即令测试失败，从未断开任何连接）；源码契约（破坏性角色与红色、旧小按钮已去掉、确认框仍在）。
- 红：编译失败（`logs/vpn-red.log`）。绿：`GeekVPNManagementActionTests|UIConsistencyRegressionTests|GeekHoverDetailTargetTests|DetailedPanelViewProfileTests|VPN` 98 项 0 失败（`logs/vpn-green.log`）。反证：按钮改回非整宽 20 pt、断开改为非破坏性：13 个失败（破坏性映射 1 条，6 种场景的宽度与高度各 6 条，`logs/vpn-reverse.log`），已恢复。

## 5. D45“改前｜改后”截图

- 方法：离屏截图管线（主窗口 `MainWindowSnapshotPipeline` 的 `--capture-main-window-responsive`，含 1280×763.7 与 900×640；小窗 `MiniWindowDemoData` 演示场景），本批脚本 `~/Developer/.sc-build/r2-u1-preselect/tools/capture-main.sh`、`capture-mini.sh`（由 `evidence/tools/run-audit-src.sh`、`capture-mini-demo.sh` 改写），拼图 `tools/make_pairs.py`。
- 隔离身份：包副本改为 `com.local.StorageCleanerMac.integration`，数据目录在 `~/Library/Caches/StorageCleanerIntegration-r2u1-*`（跑完已删）。注意：只有这个确切的 Bundle ID 才接受隔离数据目录（`AppDataDirectories`），换别的 ID 会与已安装应用共用数据，所以没有按 batch2b 的建议换成批次专用 ID；改为每次启动前等待其他会话的同 ID 截图进程结束、串行拍。该域里本批写入的 `app.language`、`app.appearance` 跑完已删除；`firstLaunch.accessGuideCompleted.v1`、`SUEnableAutomaticChecks`、`SUAutomaticallyUpdate` 与既有脚本相同。
- 改前：`7e4e481` 的 Debug 包（`dist-before/`，构建信息 commit 7e4e481，dirty=false）；改后：`54174c1` 的 Debug 包（`dist-after/`，dirty=false）。小窗“日间”按 D44⑤ 保持石墨深色，所以浅色组的小窗看起来也是深色。
- 并排图（`~/Developer/.sc-build/r2-u1-preselect/shots/pairs/`）：

| 任务 | 深色 | 浅色 |
|---|---|---|
| 3 性能测试 1280×763.7 | `u1-029-performance-1280x763-dark.png` | `u1-029-performance-1280x763-light.png` |
| 3 性能测试 900×640 | `u1-029-performance-900x640-dark.png` | `u1-029-performance-900x640-light.png` |
| 2 风扇控制（完整） | `u1-117-fan-full-dark.png` | `u1-117-fan-full-light.png` |
| 2 风扇控制（自动紧凑） | `u1-118-fan-auto-compact-dark.png` | `u1-118-fan-auto-compact-light.png` |
| 4 VPN 可由系统断开 | `u1-085-vpn-ppp-dark.png` | `u1-085-vpn-ppp-light.png` |
| 4 VPN 第三方应用管理（非破坏性，同形） | `u1-085-vpn-third-party-dark.png` | `u1-085-vpn-third-party-light.png` |
| 4 VPN 系统设置管理（非破坏性，同形） | `u1-085-vpn-system-dark.png` | `u1-085-vpn-system-light.png` |

- 原图：`shots/before-main-{dark,light}/`、`shots/after-main-{dark,light}/`（各 100 张，7 种尺寸 × 14 页；对应文件名 `1280x763-performance.png`、`900x640-performance.png`），`shots/before-mini-{dark,light}/`、`shots/after-mini-{dark,light}/`（各 5 张）。性能页的实时读数（温度、负载、曲线有无）取自截图当时的本机，前后两张不是同一时刻，不作数值对比；1280 档改后图的曲线区显示“正在采样…”是拍摄时尚无历史，不是布局问题。
- 复核后：第一轮性能页改后图实际高 754 pt、窗口未激活（控件去饱和），已由复核轮 P2-1 重拍的 4 张取代；D47 结果页、风扇手动／曲线／双风扇同步为复核轮新增，见“复核后修改”的截图表。
- 截图脚本可靠性：小窗场景偶发漏拍（实例在等待时间内没出图就被跳过，`run.log` 无输出，原因未查明，高负载时更明显）。改前 10/10 一次拍齐；改后 `6c9822c` 包深浅各漏 1 个，`54174c1` 包深色漏 4、浅色漏 2，给脚本加 `MINI_WAIT_STEPS=180` 补拍后深色仍漏 1 个（自动紧凑），再单独补拍成功。最终改后 10/10 都来自 `54174c1` 包。主窗口每次 100/100。

## 6. 门禁

日志都在 `~/Developer/.sc-build/r2-u1-preselect/logs/`。

| 门禁（均在 `54174c1`） | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| Debug 全量，第 1 次 | `swift test --scratch-path …/debug --jobs 4 --skip-update --disable-automatic-resolution` | 1 | 3510 项，跳过 21，失败 1：`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits` 用时 15.003 s，超过 15 s 上限（N10 计时类；当时负载 26–31，来自其他会话）。本批没有改跑分内核 | `logs/gate-debug-full.log` |
| 该项单独重跑 | `swift test … --filter 'MacBenchmarkKernelTests/testStandardQuickKernelsCompleteWithinDeclaredLimits'` | 0 | 通过，11.886 s；阈值未改 | `logs/gate-n10-rerun-1.log` |
| Debug 全量，第 2 次（负载降到 8–16 后） | 同第 1 次 | 0 | **3510 项，跳过 21，0 失败**，202.4 s | `logs/gate-debug-full-2.log` |
| 严格并发（含测试目标，新 scratch 全量编译） | `swift build --build-tests -Xswiftc -strict-concurrency=complete --scratch-path …/strict --jobs 4 --skip-update --disable-automatic-resolution` | 0 | 0 错误；并发警告 0；唯一 1 条编译警告是基线已有的 `BrowserPrivacyRecoveryTests.swift:474`“no calls to throwing functions occur within 'try' expression”（非并发警告，本批未改该文件，基线构建 `logs/debug-build-base.log` 同样有）；另有 `--skip-update` 弃用提示；177.7 s | `logs/gate-strict-tests.log` |
| 私有接口检查 | `python3 script/check_private_api.py` | 0 | Private API check passed (6 allowlisted uses) | `logs/gate-private-api.log` |
| 空白检查 | `git diff --check 7e4e481 HEAD` | 0 | 无输出（交接提交后重跑一次，见报告） | `logs/gate-diff-check.log` |
| `verify.sh` 中的源码守卫（同样的 grep） | Views 不起进程／不 terminate；内存功能不 purge；无冲突副本 | 0 | 三项均通过 | `logs/gate-source-guards.log` |
| 截图用 Debug 包 | `STORAGE_CLEANER_SKIP_TESTS=1 BUNDLE_CONFIGURATION=debug SWIFT_BUILD_DIR=/tmp/storage-cleaner-r2u1-bundle DIST_DIR=… script/build_and_run.sh --bundle-only`（`7e4e481`、`6c9822c`、`54174c1` 各一次） | 0 | 只用于离屏截图；前置测试按变量明确跳过（脚本打印 NOT RUN），签名与 Sparkle 校验照常通过 | `logs/bundle-before.log`、`bundle-after.log`、`bundle-after2.log` |
| Release 全量、小窗性能脚本 | — | — | NOT RUN（任务卡：Release 只在必要时建；完整门禁由主会话在集成分支跑） | — |

基线（`7e4e481`，本批开工时）：Debug 构建 exit 0，唯一编译警告同上（`logs/debug-build-base.log`）；相关 9 个测试类 181 项，跳过 2，0 失败（`logs/base-targeted.log`）。

## 7. 实机核对清单（主会话安装后做；本批 NOT RUN）

1. 智能扫描结果：绿色分组默认全勾，只有“正在运行，清理前需退出”的行没勾；“最近 7 天内仍有写入”“未识别所属应用，清理前无法确认它是否在运行”两种行已勾并显示提示；黄色、红色、“清空废纸篓”不勾。
2. 有 ≥ 5 GiB 的缓存行（如 Xcode DerivedData 在一年以上未改时、浏览器缓存）显示“体积较大：重建需要重新下载或生成，可能较慢”。
3. “恢复默认选择”回到上述勾选；“选择推荐项目”与默认一致。
4. 退出某个缓存所属应用后，结果页刷新运行状态，该行仍不自动勾（A2：刷新不改已勾选内容）——与 D47 无冲突，确认观感可接受。
5. 小窗传感器 › 风扇控制：三张单选卡观感、点卡只切换草稿（状态胶囊显示“待应用”），**只点取消、不点应用**；双风扇机器上手动区的“双风扇同步”开关。
6. 性能测试页：默认窗口与 900×640（若能调到）圆环完整、底栏不遮挡；负载曲线在圆环下方；浅色、深色各看一次。**不点“开始性能测试”**。
7. 有 PPP VPN 时：“断开连接”为红色描边整宽按钮，点开确认框后**只点取消**；说明只有一行时上下留白对称（复核 P2-5）。
8. （复核 P1-2）系统设置开启“键盘导航”后，在风扇控制里用 Tab 移到三张模式卡、空格选中（只切换草稿，**不点应用**）；开启 VoiceOver 时 VO＋空格同样能选中，读出“模式名、副标题、已选择／未选择”。
9. （复核 P1-1）智能扫描结果：最近用过的 `~/Library/Caches/go-build`、`ms-playwright` 等显示在开发缓存里，为红或黄、不勾选；识别不出所属应用的绿色行在扫描后若有新写入，执行时被跳过并写明“扫描后仍有新写入或变化，可能正在使用；已跳过，如需清理请重新扫描”（只用自建测试目录核对，**不在真实缓存上执行清理**）。
10. （复核 P2-4）把主窗口调窄到约 677 宽、或调矮到约 390 高：性能测试页底栏出现“芯片温度 xx°C”紧凑读数；恢复默认窗口后读数消失、圆环完整。
11. （复核 P2-3）运行中布局只在主会话决定实跑一次性能测试时顺带核对（会真实满载约 3 分钟）：进度在左、监控在右，圆环与未运行时同大；本批没有实跑。

## 8. 未解决问题与风险

1. **D47 的取舍**：识别不出所属应用的缓存行现在默认勾选，执行前无法按“应用在运行”跳过（识别不出就查不到）。行内已注明；若实机发现某些常驻后台工具的缓存被默认带走，需要主会话决定是否把这类行加回例外或补识别规则。（复核 P1-1 后：常见开发工具缓存已改由开发者规则按活动分档；其余识别不出所属应用的行执行前复查写入，扫描后有新写入即跳过。仍有残余：扫描后没有新写入、但正被某个识别不出的程序读取的缓存会被清理。）
2. “选择推荐项目”与默认预选只在“绿色但规则不推荐”的行上不同；内置规则没有这种行，夹具里有（`DebugSmartScanSessionFixture` 的 `image-cache`）。
3. 5 GiB 阈值是本批自定的（任务卡给的例子），没有用户数据支撑；按类别（`categoryID` 字符串）判断“缓存类行”，新增规则类别时要同步。
4. 性能页监控高度按“滚动区可见高度 − 页内边距 − 选择器 28 pt 预留 − 间距”计算；分段选择器若因辅助功能字号变高，监控可能略微超出可见区（测试覆盖中英文三种窗口，不含放大字号）。比 900×640 更矮的窗口（如 820×520）监控用最小 250 pt 并在测试卡下方，需要滚动——不在本批要求内。
5. 性能页去掉了页头右上的温度数字（差距清单称其“孤立、无说明”），读数在圆环中心；读屏标签随之移到圆环读数上。
6. VPN 管理卡在“有服务标识或提供方应用、但预检后没有按钮”的情况下多留 12 pt 空白。
7. 截图脚本偶发漏拍（见第 5 节），未查根因。

## 9. 提交与文件

- 提交：`769a27e`、`c9db241`、`a5a9621`、`6c9822c`、`54174c1`、`8dbea54`（第一轮交接）；复核后 `f45b08b`、`273316f`、`ef1fceb`、`58da842`、`6b54606`、`111d458`、`462f7dc`、`f0a2337`、`78e43a3`、`c0e006a`、`cb44675`，加复核轮交接提交。
- 复核后新增或修改的文件：`Resources/CleanupRules.v2.json`、`Models/CleanupCoverageCatalog.swift`、`Models/CleanupScanModels.swift`、`Models/CleanupExecutionModels.swift`、`Services/SafeCleanupExecutor.swift`、`Views/CleanupExecutionViews.swift`、`Views/CleanupScanViews.swift`（`#if DEBUG` 截图开关与夹具运行状态）、`Views/MenuBarAdvanced/ControlPaletteViews.swift`、`Views/MenuBarAdvanced/GeekNetworkView.swift`、`Views/ComputerHealth/BenchmarkV7DashboardView.swift`、`Views/ComputerHealth/BenchmarkV7PerformancePresentation.swift`、`Debug/MainWindowSnapshotPipeline.swift`、`Debug/DebugSmartScanSessionFixture.swift`、`Support/MiniWindowDemoData.swift`；测试 `CleanupJunkActionableTests`、`CleanupRuleScannerTests`、`FanControlModeCardTests`、`GeekVPNManagementActionTests`、`BenchmarkMonitorLayoutTests`、`OfficialBenchmarkPlanTests`、`DebugSmartScanSessionFixtureTests`、`HardwareControlPresentationTests`、`CleanupDefaultSelectionPolicyTests`（P2-8 色调断言）；文档 `docs/cleanup-rules.md`、`docs/mini-window-design.md`、本交接。
- 源码：`Models/CleanupScanModels.swift`、`Models/CleanupCoverageCatalog.swift`（只改注释）、`Services/ReadOnlyCleanupScanner.swift`（文案与注释）、`Views/CleanupScanViews.swift`、`Views/MenuBarAdvanced/ControlPaletteViews.swift`、`Views/MenuBarAdvanced/FanControlInlineControls.swift`、`Views/MenuBarAdvanced/GeekNetworkView.swift`、`Views/ComputerHealth/BenchmarkV7PerformancePresentation.swift`、`Views/ComputerHealth/BenchmarkV7DashboardView.swift`、`Views/ComputerHealth/PerformanceBenchmarkWorkspaceView.swift`。
- 测试：新增 `CleanupDefaultSelectionPolicyTests`、`FanControlModeCardTests`、`GeekVPNManagementActionTests`；修改 `CleanupLogPreselectionTests`、`CleanupJunkActionableTests`、`CleanupRuleScannerTests`、`DebugSmartScanSessionFixtureTests`、`GeekSensorsPowerHoverDetailTests`、`BenchmarkMonitorLayoutTests`、`OfficialBenchmarkPlanTests`。
- 文档：`docs/cleanup-rules.md`、`docs/mini-window-design.md`、本交接。
- 需要主会话补记（本批未改 DECISIONS／BOARD）：D47 已落地的细节（“绿色即预选、规则级 `defaultSelection` 对绿色行只剩 forbidden”“5 GiB 重建提示”“未识别所属应用的行内提示”）；U1 117／118、029、085 完成，差距清单对应条目待实机重拍后改“已修正”。

## 复核后更正

- 双风扇手动最初实测约 303 pt。已更正：前两轮 `r2-u1-followups` 由主会话构建、112 项定向验证并提交；后续复核实测同步 280.0 pt、未同步 304.0 pt（`r2-u1-followups-review/logs/test-temp-probe.log`），仍有预算／余量问题。第三轮补同步和未同步各 ≤276 pt（280 pt 内至少留 4 pt）的约束、固定首行开关；复核 r3 实测同步、未同步均为 274.0 pt。
- P1-1(b) 只能发现改变修改时间的写入，更精确地说要改变可读部分的最大修改时间；修改时间被还原、不可读子目录和超过 32 层的变化不能据此发现。
- `deno` 含用户数据，已由主会话提交 `8f31d4b` 改为不列出；该提交及保护逻辑已在本批基线中核对。
- 上一批模式卡片高约 37 pt，由内容决定；源码的 36 pt 是最小高度，不是固定高度。
- P2-3、P2-4 那几组布局测试截图里的灰色按钮，原因是测试窗口未激活且测试设定为不可开始，不是回归。
