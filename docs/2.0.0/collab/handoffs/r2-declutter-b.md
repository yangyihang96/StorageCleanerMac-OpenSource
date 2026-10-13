# r2-declutter-b / D2 第七轮交接

交付：`/Users/developer/Developer/.sc-build/r2-declutter-b/prepared-r7/`。补丁基线 **`f5ca468c71864fb82092d22e46123421575388f7`**，分支 `task/r2-declutter-b`。all.patch 包含 R5/R6 已准备的改动与 R7 契约修复，应用于已提交 R4 的 f5ca468；工作树已是最终源码，不要重复应用。旧 prepared 至 prepared-r6、复核报告、日志和截图原样保留。

**R7 源码、静态审计和交付已准备；未编译、未运行 XCTest/反证/Release，也未提交。** common.md 禁止本 Codex 沙箱编译、测试、提交；主会话负责实际运行。R7 相对 R6 只改三个测试文件和本文，全部生产源码不变。补丁相对 f5ca468 共 25 路径：11 生产、13 测试、1 交接。

## 实测状态及来源

| 对象 | 状态 | 已核对的证据 |
|---|---|---|
| R6 build | PASS | `logs/main-prepared-r6-155541/build.log`：Build complete。 |
| R6 定向 | FAIL | `logs/main-prepared-r6-155541/test.log`：1055 / 跳过 3 / 失败 2，分别为悬停入口与颜色断言。 |
| R6 全量 Debug | FAIL | `logs/full-r6.log`：4058 / 跳过 25 / 失败 3，再加电池图标断言。 |
| R6 反证 | PASS（原选定范围） | `counterfactual-r6-5be2db6dde364926b6472c0b766c5768/result.json`；含同步单方法独立三次。不是全量测试通过。 |
| R7 静态检查 | 见 static-checks.json | 括号/引用/源码契约、读源覆盖、补丁应用与哈希；不等价 Swift 编译。 |
| R7 运行验收 | NOT RUN | 等待主会话执行本交付脚本。 |
| Release 性能 | 历史复核 BLOCKED | 基线与 R4 高负载下均超原 100 ms p95 门禁；R7 未重跑，仍需空闲机器验证，不放宽预算。 |

清单事实修正：GeekHoverDetailTargetTests 和 PanelChartNormalizationTests **已在 R6 的 51 类定向清单内**，对应那两项定向失败；MiniWindowBatteryStatusTests 当时漏列。原清单、实际失败行和日志 SHA 见 `r7-evidence.json`。

R5 的测试目标编译失败，随后旧二进制定向 1053/3/23、全量 4056/25/27 仍标为 INVALID；不据此改断言。R6 已修复该编译错误。历史记录见 `r5-invalid-evidence.json`。R4 主会话构建、1042/3/0 定向、反证 PASS，以及独立复核的 4056/25/1（旧 rail 状态断言）保留在 `review-and-r4-evidence.json`，不写成 R7 新验证。

## R7 三项根因与改写依据

### 截图悬停守卫

旧测试检查的是两条开启三级详情的指针入口：GeekHoverDetailTarget.targetHoverChanged，以及旧 tertiaryDetailButton → tertiaryButtonHoverChanged。后者已随 D64 死布局删除，不再有调用入口；它的 guard 随整个函数移除，不能把在该文件搜不到 guard 当成现存路径失去保护。

现存 targetHoverChanged 与 a6db3c5 **逐字一致**。DEBUG/BETA 的捕获 guard 在状态写入之前，也同时先于无 coordinator 时的直接 presentDetail 与正常 scheduleTertiaryPreview。当前三级表面的 hover 回调只维持/关闭现有详情，不是旧按钮的自动开启入口；快照由 session/coordinator 的显式请求建立，未在该路由添加会阻断截图的 guard。

保留原测试方法名 `testSnapshotCaptureBlocksPointerHoverAtBothTertiaryEntryPoints`，改为切出真实处理函数，断言 capture guard 先于这三项副作用，并保留 true/false 回调入口、断言两个退休按钮函数缺席。原 session.presentHistory、截图默认三级类型、历史窗口/范围和观察边界断言全部保留。此项不修改生产代码。

### 电池充电信息图标

batterySystemImage 确实属于 R5 删除清单，但当时只传给已经不渲染 systemImage 的 AdvancedPanelCard 参数；恢复这段无调用属性不能验证可见图标。**存活的信息符号并未删除，也不是本轮新搬家**：从 a6db3c5 起，充电中/即将充满均由 GeekBatteryRingState.resolve 映射为 charging → bolt.fill，geekBatteryRingSymbol 传入 GeekCombinedRing，后者实际绘制 Image(systemName: statusSymbol)。状态枚举、symbol getter 与图标渲染分支均核对为基线已有实现，R7 不改它们。

`testFinishingChargeKeepsTheChargingRingAndIcon` 保留即将充满、耗电/未知、文案及估算状态断言，增加普通充电状态的 charging/bolt.fill 断言；把退休 battery.100percent.bolt 属性字符串断言替换为**状态解析 → 卡片传参与充电色 → Image 分支及颜色渲染**的完整存活链路。依据 D64：信息性状态符号必须保留；仅清理不参与渲染的死参数/属性。没有把信息图标当装饰删除。

### 图表与圆环颜色

MenuBarAdvancedComponents 不再包含无调用的 processorChartSeries，因此不再有旧 resolvedPrimaryTint/SecondaryTint/GPUTint 字符串。现存 memoryRingSegments 直接引用 panelMetricColors.memoryApp / memoryWired / memoryCompressed；它们经统一 PanelMetricColors.resolved 处理用户覆盖值和视觉模式。memoryRingSegments 与完整 PanelMetricColors 文件均与 a6db3c5 相同，未发生配色回退。

`testPanelAccentThemePreservesSemanticContrastForPairedSeries` 保留 root 的 resolved tint、CPU/系统成对语义颜色优先于 stacked-bar accent 的顺序，以及所有原文件不得直接使用 CPU/网络 palette 的守卫。仅对 Components 检查实际三条内存颜色通道及对应 resolved 赋值，并断言旧 processorChartSeries 缺席；其他图表文件仍使用原检查。没有用“文件包含任意颜色字样”放宽契约。

逐方法相对 f5ca468 的完整 diff 见 `contract-migrations.md`；基线比较、保留的状态/渲染路径和生产文件 SHA 见 `r7-evidence.json`。

## 定向读源覆盖

`targeted-classes.txt` 从 51 扩为 **68 类**，保留全部原性能、行为、一致性与测试卫生类。

- 以 `git diff a6db3c5 --name-only -- Sources` 的 **26 路径（含 8 个删除文件）**为依据，对全部 324 个测试文件逐文件名运行 rg。直接引用文件/路径的 54 个测试类全部覆盖，其中 14 类为新增。
- 核对 Sources/Views/MenuBarAdvanced 的目录枚举，新增三个会遍历整个 Sources 的类：ExternalMigrationReceiptTests、MiniWindowPhase2ReviewTests、PreferencesFolderContractTests；原有目录扫描类继续保留。
- 核对 R2ProductionSource 的全部调用类、MiniWindowLogicFixtures.source 的参数、路径前缀/扩展名拼接与不带扩展名的命中；保守保留已有类，不按文件名一次 grep 就宣称覆盖完成。
- 原三个失败类均在最终清单内。没有未纳入的已识别读源类。逐类依据、目录范围、原始命中和排除的非相关枚举见 `targeted-reader-coverage.md` / `.json`。

R6 的删除名称检查继续保留：59 个删除声明、累计类型/函数、8 个文件名及 7 个删除的测试局部变量，187 个唯一搜索名称；按原作用域核对，不把其他类型的同名存活成员误删。R7 对全部 **13 个改动测试文件**重新进行括号与条件编译配对、20 个改变函数的代码标识符/局部绑定核对，记录实际 Sources/Tests 与 SDK 声明位置。`source-contract-review.json` 增加对 MiniWindowLogicFixtures.source 与跨行 contains 的识别；未解析循环/动态表达式仍明确保留，不能据静态结果宣称 XCTest 通过。

## 本交付保留的 R5 处理

| 项目 | 实现与依据 | 覆盖 |
|---|---|---|
| P1 旧状态断言 | DetailedPanelViewProfileTests 改为断言 `selectedRailSection` 不存在；同方法原有 `panelCoordinator.reset()`、overview 启动与协调器路由/测量断言保留。依据 D64 删除不可达 rail，现存 `selectedSection` 直接读协调器。 | 加入 targeted-classes，清单从 50 增至 51 类；runner 增加 Debug 全量。反证注入旧 @State，要求该方法执行并失败。 |
| P2 无用参数 | `AdvancedPanelCard` 去掉未渲染的 `systemImage` 和未读取的 `tint`；11 处实际生产调用同步清理。`GeekSection` 已无生产调用，整段删除。审计的约 50 处包含已退休调用，不能继续据此保留空 API。 | 标题文字、字体、header trait 不变；一级 `GeekModuleHeader` 不变。守卫要求旧类型缺席、存活卡片构造器不再接受无效参数。 |
| P2 swap tooltip | `GeekMemoryView` 的交换内存环不再传 `detail: ""`，沿用默认 nil，避免末尾 ` · `；标题 `.help(geekSwapExplanation)` 保留。 | 守卫要求这张卡不传 detail，数值与 help 保留。 |
| P2 返回按钮 | 风扇曲线页与小屏紧凑外壳均用 `chevron.backward`、`.titleAndIcon`、`ResponsivePlainButtonStyle`、captionStrong 和 small control size。依据本轮主会话明确决定：返回箭头是导航提示。 | 新守卫锁定两处箭头/样式与原返回动作；风扇按钮原“返回风扇控制”AX 标签保留。 |
| P2 残留死代码 | 沿旧面板删除链清理 59 个声明，包括复核指出的 simpleChoices/simpleTitle、navigationWidth、tertiaryDetailButton、updatedUnavailableText/selectedSectionUpdatedAt、authorizationHeight，以及依赖它们的旧格式化、行/指标组件、GeekSection、AdvancedAppIcon、旧进程访问器等。 | `removed-declarations.json` 列出每个被删声明；新增缺席守卫；逐方法迁移见下表及 contract-migrations.md。 |
| P2 同步诊断噪音 | 两状态证据先缓存在当前 helper 中，仅当该 helper 增加 XCTest failureCount 时在 defer 输出 stderr。诊断与 XCTUnwrap/最终位置比较使用同一份 frame 快照。 | 位置 maxX/minY ±0.5、80 pt 菜单、260.5 pt 宽度、其他大小/等待预算及原公开测试方法不变。runner 要求所有绿运行无 FAN_SYNC_LAYOUT；26 pt 注入失败须有诊断，且记录的坐标与失败断言值一致。 |
| P2 不可信诊断结论 | R5 runner 删除四组旧宿主重放和 `prior_host_diagnostics.comparisons` 推断。旧日志/结果只读保留，明确撤回其中“未复现位置失败”的结论。 | 正式绿/红、独立单跑×3、状态倒序、整类和位移注入保留；不依赖旧比较器决定 PASS。 |

`tertiaryDetailButton` 删除后，其专属 `tertiaryButtonHoverChanged`、`presentTertiaryDetail`、无调用的 `presentFanCurveEditor` 和 `hoveredTertiaryButton` 一并删除。该状态只有退休按钮能写入非 nil；根视图与延迟关闭条件中相应恒真判断/置空也去掉。当前 `GeekHoverDetailTarget` 的预览、列模式检查、inline request → `panelCoordinator.presentHistory`、真实三级表面 hover、锁定和关闭协调仍保留并受测试约束。

59 个声明中也包括同名遮掩项：旧 root 的 `loadAverage`、`metricColumns`、`timestampText`。其他类型中同名的服务/renderer/局部变量仍有用途，不按名字一并删除。保留偏好迁移值和解码逻辑。本次扫描围绕 D64 删除链及其新孤儿，不扩展为全仓历史未使用 API 清理。

两个明确的范围外项未修改：**`ScanStore.requestQuitMemoryApps` / 恢复分支归 V1；`Support/AppControls.swift` 中的 `AppSelectionButton` 归 A 批**。两文件 SHA 与 f5ca468 一致，其后续清理由各所有者处理。

## 契约迁移逐项依据

所有既有测试方法保留；没有新增 skip、放宽阈值或删除现存行为覆盖。下列只替换退休实现的断言，完整旧/新 diff、方法名在 `contract-migrations.md`。

| 测试 | 旧断言的对象 | 当前覆盖 |
|---|---|---|
| DetailedPanelViewProfileTests / overview 场景 | 已删除 selectedRailSection 赋值 | 旧状态不存在；原 reset/路由/窗口测量不变。 |
| PanelChartNormalizationTests / density budget | 旧 rail 宽 44 | 旧宽度不存在；当前 primaryChartHeight 与 GeekPanelLayout 一致；其余高度/宽度预算不变。 |
| PanelChartNormalizationTests / memory pressure | 未调用的三级状态进度 1/3、2/3、旧 headroom 属性 | 现存 `geekMemoryPressureRing` 使用 pressureEstimatePercent/100、等级色 memoryTint；仍保留系统等级、缺失余量 help、历史、主窗口压力来源契约。 |
| GeekSensorsPowerHoverDetailTests / captured sizes | 退休授权卡高度 30/112 | 旧函数缺席；现存 ControlPaletteHelperStatusView 入口存在；其余实用弹层/风扇/电源尺寸不变。 |
| MenuBarTertiaryDetailTests / third column | 退休 tertiaryDetailButton 的列模式/禁用检查 | 原按钮缺席；现存 hover target 的 column/unavailable 检查及 root inline coordinator 路由；真实遥测、内容 host、hover/关闭与无新增采样断言保留。 |
| MenuBarPanelInteractionTests / hover drilldown | 退休三级按钮的 scheduleTertiaryPreview 和赋值 | 现存 GeekHoverDetailTarget 预览/inline request 与 root 接收；原延迟关闭、锁定/展开协调不变。 |
| UIConsistencyRegressionTests / circular metrics | 无调用 AdvancedMetricTile / CompactGauge / PlainMetric 的百分号推断 | 旧类型缺席；现存 GeekMetricCell 内容按 model.progress 使用 PanelCircularGauge；原生 Gauge/AX/不可用状态和控件守卫保留。 |
| AppIconCacheTests / shared cache | 无调用 AdvancedAppIcon | 旧组件及其 fallback 项删除；三种原生 Image 回退、GeekSecondaryProcessIcon 的独立 AppSymbolGlyph 回退、缓存/无同步查询契约全部保留。R6 补齐漏删的测试局部变量。 |
| SystemMonitorServiceTests / compact layout | simpleTitle 的“系统” | 旧属性缺席；现存 PanelSection“概览”/“清理”及原路由/刷新覆盖。 |
| SystemMonitorServiceTests / geek live data | 旧 topProcesses、sensorTiles 风扇值、AdvancedAppIcon | 当前 store.menuBarPreparedMemoryApps、实际 GeekOverviewPresentation 的 RPM/fanless/sampling、GeekSecondaryProcessIcon 缓存；session/历史/数据安全断言保留。 |
| UnifiedMenuBarPanelTests / memory source | 旧 processMemorySnapshot / geekTopProcesses | 旧访问器缺席；现存显示快照、prepared apps、memoryProcesses liveCard 与原快照 generatedAt 的观察边界。 |
| UnifiedMenuBarPanelTests / decimal disk | 旧 7 日变化格式化函数 | 旧函数缺席；当前五处显示入口使用 storageString、容量纯数据 fixture、用户已用/可用比例仍完整保留。 |
| MenuBarDeclutterContractTests | GeekSection、空 detail 等旧 D64 实现细节 | 删除后的缺席守卫、AdvancedPanelCard 无占位参数、swap 不传 detail；新增导航一致性与孤儿缺席两方法，总计 11 方法。 |

退休符号、8 个删除文件及删除的测试局部变量继续逐名复查，完整结果见 `deleted-reference-search.json`；同名存活成员按所属类型核对。`source-contract-review.json` 另外解析整个 Tests 目录中能静态解析的源码读取与 literal 断言，未解析作用域/循环/拼接明确列出，**不把静态扫描写成 XCTest 通过**。

## 保留的行为、预算与历史限制

D64 的一级模块图标（#2）、真实应用图标、选择/披露/告警状态保留；常显测量口径说明删除，三级来源/必要 help 保留（#10）。清理提示仍是“需重新扫描后才能清理 / Rescan before cleanup”，必须重新扫描才可清理。内存只退出手动所选且需确认，容量仍使用用户已用/可用口径。

两处返回按钮都保留 chevron.backward，风扇曲线页与紧凑外壳样式一致；swap 不传空 detail；passing 同步测试不输出 FAN_SYNC_LAYOUT。同步 maxX/minY ±0.5、80 pt 菜单、260.5 pt 宽度与稳定采样预算保持。R4 的单一固定 260×120 宿主和共同坐标系保留，未把字体/语言缓存声称为唯一已证实原因。旧 prior_host_diagnostics 对实际失败日志的错误推断已撤回，R7 不重放或生成它，历史文件不改。

性能阈值仍为 warm 100 ms、cold 250 ms、publication 100 ms、main-thread block 50 ms，Release preparation p95 ≤100 ms。未改采样、刷新、准备、缓存、窗口 session 或性能测试。静态 SHA/声明一致不能替代性能实测。

ScanStore.swift / requestQuitMemoryApps 归 V1，Support/AppControls.swift / AppSelectionButton 归 A，其他 a/c 文件和已知 warning 文件未修改；没有新增查询/刷新/常驻任务、真实清理或硬件操作。

## 主会话执行与反证

补丁顺序：**01-source → 02-contracts → 03-handoff**。源与测试一起应用；manifest 记录 f5ca468 基线、最终 SHA、组顺序、68 类清单、边界哈希和产物哈希。

```sh
python3 /Users/developer/Developer/.sc-build/r2-declutter-b/prepared-r7/verify-prepared.py
python3 /Users/developer/Developer/.sc-build/r2-declutter-b/prepared-r7/run-targeted.py
python3 /Users/developer/Developer/.sc-build/r2-declutter-b/prepared-r7/run-counterfactual.py
```

run-targeted：`swift build --build-tests` 成功后才进入 68 类定向、Debug 全量、原 Release 性能门禁。编译非零立即停止；没有 --skip-build，不复用旧测试二进制。全量至少 4058 项，所有定向类必须实际出现且零失败。默认 Xcode-27.0.0-Beta、jobs 4（可选 1–4）、离线依赖 r2-u1-preselect/debug，使用随机私有 scratch；结束删除自建构建目录，保留日志/result。

反证在隔离 f5ca468 archive 应用最终补丁，先编译测试；所有测试文件始终保留最终 SHA，编译失败/未执行不能算红：

1. 原 D64/原生模式卡/既有回归方法及本轮三个方法均实际绿。
2. 同步长名称方法**独立进程单跑 3 次**、状态倒序一次、ControlPaletteTests 整类一次；所有绿日志不得输出 FAN_SYNC_LAYOUT。
3. 三个 R7 变体分别实际红：移除现存 targetHoverChanged 的 capture guard；把现存电池环 statusSymbol 参数改为 nil；把 memoryApp 色改成直接 AppChartPalette.cpuUser。每次只改相应生产副本、要求对应方法实际断言失败，随后恢复源码。
4. 保留原 26 pt 位移变体，原位置阈值必须失败，失败诊断坐标对应断言；保留旧 rail 状态注入与 DetailedPanelViewProfileTests 反证。
5. 恢复本交付生产源码到 f5ca468，导航/孤儿缺席/参数/swap 四守卫实际红；再恢复 26 个累计生产路径至 a6db3c5，保留原 D64 累计反证。a6db3c5 仅是累计反证源版本，交付补丁基线仍为 f5ca468。

验证与复核后，主会话可运行 commit-prepared.py --validated 按组提交；此参数不是验收证据。集成仍需 script/verify.sh 的完整门禁与原生验收，环境保持 DEVELOPER_DIR、STORAGE_CLEANER_VERIFY_BUNDLE=0、STORAGE_CLEANER_UI_SMOKE=0 和本批私有 STORAGE_CLEANER_VERIFY_ROOT。Release 高负载失败不得放宽预算或标为 PASS。

R7 未编译、未运行 XCTest/运行反证、未提交、未安装/启动应用、未清理真实对象、未写硬件。JEV 复核调用被工具审批策略拒绝（requires approval, but approval policy is never），没有模型判断；共同要求内的静态工作已继续完成。
