# 批次 4b 交接：小窗数据与逻辑

- 实现：Claude 子代理（第 1–10 项由 Fable 5.1 完成；同一会话后段切换为 Opus 5.5，完成 `ab4022e` 起的提交、第二轮修改与本交接）。复核：主会话安排的独立复核（范围 `2ac7902..8e00594`）结论“需小修后合并，无 P0”，复核者自跑 Debug 全量 3241／21／0、4 组反证均变红；第二轮按复核意见与用户决定 D28、D2 补充、D14 补充修改，见“第二轮：复核意见与处理”。
- 分支：`task/batch4b-mini-logic`，基于集成分支 `2ac7902`。未合并、未 push、未打 tag、未安装、未启动应用、未截图。
- 提交（按顺序）：`1f7ecae` 第 10 项 · `7875493` 第 1 项（D2）· `d24d331` 第 8 项（D14）· `e33d57f` 第 2 项 · `2cdc8cd` 第 6 项 · `fbbf98f` 第 7 项 · `96402f2` 第 5 项＋首轮 P2-1 · `543b58b` 第 3 项 · `3f78cf6` 第 9、4 项 · `ab4022e` 第 9、4 项补充（延后调用按顺序重放、锚点观察者随视图释放移除）· `7ba223a` 设计文档补一句（仅文档）· `8e00594` 交接。第二轮：`a83401a` 复核 P2-1／P2-2 · `67db4b9` P2-9（仅测试）· `a42081d` D28（P1-1、P2-6）· `69da4db` P2-7 · `d9e49ca` D2 补充 · `f3f96a9` P2-3／P2-4／P2-5 · `b34478c` 风扇历史缓存键（范围外）· `6448502` P2-10 · `e111e5e` P2-8 · 本交接更新单独一个提交。
- 改动范围：`Views/MenuBarAdvanced/**`、`Views/MenuBarAdvancedStatusView.swift`、`Views/MenuBarAdvancedComponents.swift`、`Views/MiniWindowConfigurationSettingsView.swift`、`Stores/ScanStore.swift`（`MenuBarMonitorState` 一段与其上方新增的 `MenuBarDisplayHistorySlice`；第二轮按 D2 补充在内存选择处新增 `requestQuitMemoryApps`、确认摘要带应用名）、`Views/MenuBarStatusView.swift`（D2 补充）、`Views/SystemUtilitiesView.swift`（D28 说明文字）、`Features/Memory/Application/MemoryCoordinator.swift` 与 `Features/Memory/Domain/MemoryDomain.swift`（D28）、`Support/MenuBarPowerHistoryStore.swift`（P2-7）、`Support/MenuBarPanelSession.swift`、`Support/SmallWindowInteraction.swift`、`Support/PanelMetricColors.swift`、`Support/PanelPaletteCatalog.swift`、`Support/MiniWindowDemoData.swift`、`Services/BatteryPowerService.swift`、`Features/Memory/Infrastructure/SystemMemoryProbe.swift`、`Models/SystemModels.swift`、`Models/MenuBarTelemetryModels.swift`、`docs/mini-window-design.md`、`Tests/**`。没有改 `Features/BrowserPrivacy/**`、`Views/BrowserPrivacy*.swift`、`DECISIONS.md`、`BOARD.md`，没有碰其他 worktree 和主仓库。
- 每项都先写复现测试并在修复前运行（红），再修复（绿）；红灯日志见“验证”。

## 逐项结果

| # | 项目 | 结果 | 改动与文件 | 复现测试与反证（修复前的失败） | 提交 |
|---|---|---|---|---|---|
| 1 | D2 “退出所选应用” | 已修 | `GeekMemoryView.swift`：新增 `GeekMemoryQuitSelection`（标题“退出所选应用”／Quit Selected Apps、可用条件 `selectedMemoryAppCount > 0 && canRequestMemoryQuitActions`、帮助与读屏文案）和 `GeekMemoryQuitSelectedButton`（纯文字按钮，无选择时禁用，不再自动带入建议项；“选择建议项”菜单保留，`GeekMemoryProcessSelectionMenu` 改为 internal）。进程行读屏改为“已选择退出／未选择退出”。按钮不带图标：带图标时英文操作行实测 289／295 pt，超过 280 pt 卡宽。设计文档更新 | 新增 `MiniWindowMemoryQuitSelectionTests`（5）＋`MiniWindowMemoryQuitHeaderLayoutTests`（1，中英文、有无选择四种情况实测操作行宽度）。红：旧实现在无选择时产生 `MemoryQuitSelectionSummary(appCount: 1, estimatedBytes: 943718400)`（自动带入建议），源码含 `ensureMemorySelectionForQuit()`／“已选择清理”；布局红：英文 289／295 pt > 280 pt | `7875493` |
| 2 | 换入／换出口径 | 已修 | `MemorySnapshot` 的 `pageInsCount/pageOutsCount` 改为 `swappedInBytes/swappedOutBytes`（`SystemModels.swift`）；`SystemMemoryProbe` 取 `vm_stat` 的 Swapins／Swapouts（页）按页大小换算为字节，不再读 Pageins／Pageouts；内存页两行改为“换入（累计）／换出（累计）”（英文 Swapped In／Swapped Out (Total)），`ByteFormat.string` 显示、读不到显示“—”，悬停与读屏说明含义与换算（`GeekMemorySwapActivity`）；演示数据更新；设计文档新增“内存换入／换出” | 新增 `MiniWindowMemorySwapActivityTests`（4，含一项只读内核计数比对）。红：本机“换入”显示 82,133,638（Pageins 次数）而 Swapins×页大小＝18,831,966,208 字节；“换出”257,929 对 23,645,831,168；标题与数值不是一个量且无单位 | `e33d57f` |
| 3 | 切换时间档保留旧数据 | 已修 | `ScanStore.swift`（`MenuBarMonitorState`）：新增 `MenuBarDisplayHistorySlice` 与 `displayHistorySlice(slot:within:memory:)`，新档未就绪时返回同一槽位上次所画窗口并标 `isUpdating`；需求变化不再先过滤旧窗口，由新结果整组替换，只在无需求时释放；被取代的准备任务不再清掉后继任务句柄。`MenuBarPreparedChart.swift`：请求带 `shape`，形状相同的旧帧保留到新帧交付（折线、网络、磁盘、电源各补形状）。`MenuBarGeekCharts.swift`：`GeekHistoryPlotBlock` 所画窗口≠所选档时淡化至 45% 不透明度，坐标行中部“更新中…”、暂不显示“未记录”图例，悬停／读屏说明，无动画（第二轮改为显式状态并覆盖新帧准备期，见 P2-3／P2-4）。根视图改读 `MenuBarDisplayedHistory`（selected／cpu／network／memory／route 槽），页面时长与标题取所画窗口；`MenuBarLiveCard.swift` 新增 `MenuBarCardHistoryRevision`：硬件控制卡在风扇历史打开时取遥测历史版本（风扇历史空白 1–4 秒的直接原因）。设计文档新增“切换时间档保留旧数据” | 新增 `MiniWindowRangeSwitchTests`（9）。红：切档后新档 `displayHistory(within:)` 返回 `[]`、旧窗口已被过滤；`MenuBarPreparedChartModel` 在 family 变化时帧被清为 nil；快速二次切换丢失上次所画窗口（300 对 3600）；控制卡历史版本停在 0 | `543b58b` |
| 4 | 切档时整组窗口偶发左移约 48 pt | 候选原因已修，用户场景未复现 | 见下文“第 4 项分析”。`MenuBarPanelSession.swift`：`setGeekSection`、`setOverviewSize`、`setDetailSize`、`setTertiaryPresented` 在求解级联（`isResolvingCascade`）或程序设框（`isApplyingProgrammaticFrame`）期间整个调用延后，按收到的顺序在当前放置完成后重放，运行时重新检查会话状态；还有排队调用未执行时（顺延到下一轮期间）新到的直接调用也先入队，保证后到的不先执行；同步重放 8 个后其余顺延到下一主队列轮次（只排一个）；同一次操作累计重放 32 个仍未收敛时只执行最新的一个、它产生的调用丢弃、写日志并停止（第二轮，复核 P2-1／P2-2）；`show`／`teardown` 清空队列。原实现静默丢弃这些调用 | `MiniWindowAnchorGeometryTests`（真实会话＋宿主 NSView 在 `layout()`／`viewWillDraw()`／`setFrameSize` 中回调会话，模拟 `setFrame(display: true)` 同步运行的视图更新）。红：设框期间请求的 power→processor 切页被丢弃，会话仍按 264 pt 电源列放置而视图已是 312 pt 页，相差 48 pt；设框期间送达的二级尺寸 600 未生效（框仍为 650）。补充提交前的单槽实现另有一红：同一帧内先切页再上报该页尺寸，后一个调用按旧页重解并覆盖切页，会话停在 power（264×630），`testCallsDeliveredDuringOneFrameAreReplayedInOrder` | `3f78cf6`、`ab4022e`、`a83401a` |
| 5 | 需求时长超过 4 个被截断且重复重建；首轮 P2-1 | 已修 | `MenuBarMonitorState`：`maximumDisplayDurationCount = 4`，`selectDisplayDurations` 按各消费者的可见顺序轮转选取、去重、只收有限正数，`droppedDisplayDurations` 记录被截断的窗口并写日志，比较在截断之后进行；新增 `MenuBarHistoryDemandPlan`（打开的历史／页面、CPU 卡、网络卡的顺序），根视图所有图表的档位都来自它；按路由打开的内存历史改读页面档位（`routedMemoryRange`），与标签、选择器一致 | 新增 `MiniWindowHistoryDemandTests`（6）。红：同一请求重复 5 次版本号 1→6；6 个窗口的请求丢掉了一天档与一小时档（保留最短四个）；路由打开的内存历史读的是 `oneDay` 而页面是 `oneHour`，窗口为空 | `96402f2` |
| 6 | 电池“正在计算” | 已修 | `BatteryPowerService.swift`：`BatteryPresentationState` 去掉 `calculating`，`charging/discharging` 带 `isEstimating`，新增 `finishingCharge`；快照新增 `isFinishingCharge`、`isCalculatingTimeToEmpty/FullCharge`（IOPS 时间键为 −1 即 “Still Calculating the Time”）；`MenuBarAdvancedComponents.swift` 新增 `BatteryPresentationText`：“即将充满／正在充电／使用电池／已充满／已接通电源／已暂停充电／状态未知”，“正在计算”只在 `isEstimating`；`GeekPowerView.swift` 圆环把 `finishingCharge` 当充电。设计文档新增“电池状态文字” | 新增 `MiniWindowBatteryStatusTests`（5）。红：18 处断言全部是本应显示其他文字却显示“正在计算”／Calculating（100%＋finishing charge、充电或用电池但系统未给时间、充电标志未知，中英文与完整／简短两种标题） | `2cdc8cd` |
| 7 | 内存压力等级映射 | 已修 | `SystemModels.swift`：`MemoryPressureLevel` 新增 `init?(systemCode:)`（1／2／4）、`systemCode`、`severity`、`estimated(fromPressurePercent:)`（≥85% 升高、≥95% 高，即 `MemoryPressurePolicy.classify(pressureFreePercentage:)`）；`SystemMemoryProbe` 每次采样读 `kern.memorystatus_vm_pressure_level`，读不到／未知时该测量为不可用、显示按百分比规则估算，不再用自有推算（第二轮按 D28 推广到全应用）；`MenuBarTelemetryPoint.memoryPressureLevelCode` 逐采样记录；`GeekPreparedLineFrame.pressureLevels` 每桶取最严重等级；`GeekPrecisionLineChart.pressureLevelColor`／`GeekStackedBarSeries.bucketColor` 逐柱着色，悬停圆点同色；演示数据带等级码。设计文档新增“内存压力等级” | 新增 `MiniWindowMemoryPressureLevelTests`（12，含渲染取色与注入等级码的探针测试）。红：47 个失败（含渲染测试取不到等级色时抛出的 1 个错误）：读不到系统等级时仍给出 `normal`、推算等级覆盖系统等级、历史柱不按采样等级着色 | `fbbf98f` |
| 8 | D14 磁盘一级横条改“已用” | 已修 | `GeekOverviewPresentation.swift`：一级文字改为 `GeekDiskCapacityWording.volumeSummary`（“44% 已用 · 560 GB 可用”），横条填充已用比例，颜色取新出口 `GeekDiskVolumeColors.capacityTint`（正常磁盘写入色、可用 ≤20% 橙、≤10% 红；卷圆环同一出口，`GeekDiskView.swift`）；调用点 `MenuBarGeekPanel.swift`、`MiniWindowConfigurationSettingsView.swift`；设计文档“磁盘容量口径”更新 | 新增 `MiniWindowDiskLevelOneBarTests`（3，ImageRenderer 实测横条像素宽）。红：440/1000 GB 已用时横条 152.5 pt 而已用份额应为 119.68 pt（填的是可用比例） | `d24d331` |
| 9 | N9 一级锚点 | 已修（三条建议都做） | `SmallWindowInteraction.swift`：`SmallWindowAnchorNSView` 在自身原点／尺寸变化（重写 `setFrameOrigin/Size`）、祖先移动（观察祖先 `frameDidChangeNotification`）、窗口移动／缩放（`NSWindow.didMove/didResize`）后重新上报；`SmallWindowAnchorSnapshot.layoutOffset` 新字段，`GeekPanelComponents.swift` 的 `GeekModuleAnchorRegistration` 两种放置都登记卡片在概览布局中的顶边偏移；`MenuBarPanelSession.registeredDetailTopOffset` 优先用布局偏移（原生框上报不带布局信息时保留已登记的偏移）；`registeredAnchorDidChange` 在求解或设框期间延后（同一帧只排一次）而非丢弃；锚点视图的通知观察者放入释放时移除的持有对象（`SmallWindowAnchorGeometryObservers`，与会话的 `MenuBarMenuTrackingObservers` 同一做法）。设计文档“一级卡片锚点”更新 | 新增 `MiniWindowAnchorGeometryTests`（第一轮 7 项，含上一项的顺序测试；第二轮再加 3 项，见第二轮）。红：窗口、祖先、自身原点移动后报告数停在 1；登记表无布局偏移；设框期间登记的内存卡锚点被丢弃，二级停在默认 79 pt 而非登记的 120 pt。`MiniWindowLevelOneAnchorTests`（3）继续通过。观察者在视图释放时移除这一点没有专门测试 | `3f78cf6`、`ab4022e` |
| 10 | `resolvedGPUTint`／`resolvedThermalTint` 调用配色出口 | 已修 | `MenuBarAdvancedStatusView.swift` 两个解析器改为 `panelMetricColors.gpu(chartAccent:)`／`sensorGraph(chartAccent:)`；`PanelPaletteCatalog.swift` 的 GPU 色块同样走出口；`MiniWindowConsistencyRuleTests` 的间接规则文本检查改为直接断言（解析器调用出口；根视图与配色目录不再读 `gpuIsCustomized`／`sensorGraphIsCustomized`） | 红：`MiniWindowConsistencyRuleTests.testFanAndGPUHistoriesUseTheirRingColors` 5 处失败（解析器仍自带规则） | `1f7ecae` |

### 第 4 项分析（候选原因，需实机核对）

- 48 pt 正好是 `detailWidth`（312）− `powerDetailWidth`（264），即电源页二级列与其他页的宽度差。
- 排除的路径：`CascadeViewportLayout.solve` 只在子级总宽变化且贴屏幕边界时移动父级；切档只改三级列高度（历史宽度恒为 380），求解器本身不会因切档水平移动整组。`attachedOverviewFrame` 在 `windowDidMove`（面板不可拖动）与 `translatedCascadeLayout` 的更新路径也查过，没有发现 48 pt 的来源。
- 复现到的机制（基线行为）：`panel.setFrame(display: true)` 同步运行 SwiftUI 视图更新，该更新会把所选页、测得尺寸、锚点转发给会话；`setGeekSection` 在 `isResolvingCascade` 期间、`registeredAnchorDidChange` 在 `isApplyingProgrammaticFrame` 期间都直接返回，于是会话几何落后于视图：测试中设框期间请求的切页（power→processor）被丢弃，会话仍按 264 pt 列放置而视图已显示 312 pt 页面，差 48 pt，直到下一次无关请求才纠正。这类丢弃依赖时序，与“偶发”一致。
- 未能证明的部分：用户操作是“切档”，切档本身不换页；是否在用户的构建里切档会引发设框期间的嵌套请求（例如切档引起二级重新测量、同时有页面或锚点变化），本机未复现，也不允许启动应用核对。
- JEV（jev-latest，`jev_decide`）对措辞的判断：推荐 `candidate_fixed_needs_machine_check`，概率 1.0，无 escape；“确认已修”在“不断言现场原因已确认”“主会话可实机核对”两项被判 contradicted。仅作参考。
- 实机核对建议：在贴近屏幕边缘（左右各试）的位置打开电源页与其他页的历史，反复切换时间档并切页，观察整组是否左移 48 pt 且不回弹；若仍出现，记录当时的页面、档位、屏幕位置与是否刚打开三级。

## 第二轮：复核意见与处理

每项先写复现测试并在修复前运行（红）；需要新接口的项先放一个保持现行为的桩函数取得红灯，再换成实现。日志名见“验证”。

| 编号 | 意见 | 结果 | 改动 | 复现与反证 | 提交 |
|---|---|---|---|---|---|
| P1-1／D28 | 共用探针改等级来源影响全应用；用户决定 D28：全应用取系统等级、用词“正常／升高／高”、百分比只作数字 | 已修 | `MemorySnapshot` 删去 `pressureLevel`（自有推算＋缺数时当作 elevated），清理建议、`MemoryCoordinator` 的 `pressureBefore／After`、小窗优化结果行都读 `reportablePressureLevel`（系统等级，否则百分比规则估算，否则未知）；`MemoryOptimizationExecutionResult.pressureBefore` 改为可选；删除 `MemoryPressurePolicy.classify(physicalBytes:…)`；等级未知时建议写“继续观察／暂时读不到系统内存压力等级”；`MemoryPressureLevel.title` 改“升高／高”；主窗口压力环说明改为“macOS 报告的内存压力等级（与活动监视器同源）”。主窗口内存页、概览、简单面板原本就读 `reportablePressureLevel`，随之统一 | `MemoryPressureLevelAppWideTests`（3）＋`MemoryCoordinatorTests` 新增 1 项。红：15 处失败——用词“上升／偏高”；无系统等级、压力 50%、可用 6% 时建议仍写“继续观察压力”、`pressureBefore` 记 elevated；无等级无百分比时建议写“系统有压力信号” | `a42081d` |
| P2-6 | 设计文档“读不到系统等级时不可用”与代码（按百分比估算）不一致 | 已修 | 设计文档第一条改为：读不到或取值未知时按同一百分比规则估算，连百分比也没有才显示不可用；写明全应用统一（D28） | 文档 | `a42081d` |
| D2 补充 | 简单面板保留“列出建议＋确认”：按钮“退出这 N 个应用”，确认框列应用名 | 已修 | 按钮 `MenuBarRecommendedAppsQuit.title(count: recommendedApps.count)`（英文 Quit These N Apps，N＝1 时 Quit This App）；点按调用新的 `ScanStore.requestQuitMemoryApps`，只把卡片列出的应用设为所选并请求确认；`MemoryQuitSelectionSummary.appNames`／`appNameList`（最多列 3 个，多于 3 个写“A、B、C 等 N 个”）；简单面板确认框写“将正常退出：…”；删除不再使用的 `runMemoryAction`。小窗内存页仍按 D2 | `MenuBarSimplePanelQuitTests`（3）。红：16 处失败——列出 3 个、实际选中全部 5 个建议；确认摘要无应用名；按钮“正常退出” | `d9e49ca` |
| D14 补充 | 一级磁盘横条与二级卷圆环同一颜色出口，≤20% 橙、≤10% 红 | 已确认（第一轮已实现） | `GeekDiskVolumeColors.capacityTint(capacity:)`，阈值来自 `StorageCapacitySnapshot.pressure`（可用比例 ≤0.20 attention、≤0.10 critical） | `MiniWindowDiskLevelOneBarTests.testBarUsesTheVolumeRingColorWhenSpaceRunsLow`、`MenuBarSecondaryVisualConsistencyTests` | `d24d331` |
| P2-1 | 延后调用顺延到下一轮后，之前到达的直接调用先执行、随后被更早排队的调用覆盖 | 已修 | 队列非空且不在重放循环内时，直接调用也先入队，再统一按顺序重放；重放循环内由被重放调用发出的调用仍直接执行（不会再入队造成循环）。理由：只有“按收到顺序”能保证用户最后的请求最后生效，按类型合并会丢掉调用之间的先后（先切页再报尺寸） | 复核者的演示测试移入为 `testACallMadeWhileSpilledCallsWaitRunsAfterThem`。红：会话停在 power 而非 memory | `a83401a` |
| P2-2 | 两个互相抵消的调用每轮重放 8 次、反复设框、持续写日志 | 已修 | 同一次操作（队列自上次清空以来）累计重放 32 次仍未收敛时，只执行最新的一个调用一次，它产生的调用丢弃，写一条日志，停止重放直到下一次外部调用；顺延的异步轮次只排一个。新增仅测试用的 `programmaticFrameDidApplyForTesting`（设框内调用，模拟设框同步运行的视图更新） | `testCallsThatKeepUndoingEachOtherStopAfterABoundedNumber`。红：30 个主队列轮次后测试钩子已发出 489 个嵌套调用（每个都被重放、设框），再 20 轮到 809 个，仍在增长；之后用户切页也被覆盖 | `a83401a` |
| P2-3 | 新帧准备期间（保留上一时长的帧）没标“更新中” | 已修 | `MenuBarPreparedChartModel.isShowingPreviousValue`：保留的是另一时长（family 不同、形状相同）的帧时为真，新帧交付或同一时长的新采样时为假；`MenuBarPreparedChart` 经 `GeekHistoryPreviousFrameKey` 上报，`GeekHistoryPlotBlock` 并入同一“更新中”（淡化＋“更新中…”），偏好只在本绘图块内生效 | `MiniWindowUpdatingStateTests`：模型标记、并入规则、窗口内端到端（上报上一帧的图表实测 α＝0.45）。红：模型从不标记、端到端 α＝1 | `f3f96a9` |
| P2-4 | “更新中”靠环境中的所选档推断 | 已修 | 去掉推断：8 个读遥测切片的历史视图新增 `isUpdating` 参数传给坐标行，卡片与路由三级传入各自切片的状态（`cpuDisplayedHistory`／`networkDisplayedHistory`／`geekMetricIsUpdating(_:)`／routed memory／`geekTelemetryChartIsUpdating`） | 同上。红：一天的历史在没有所选档环境时被淡化（α＝0.45）；显式传入的更新中不生效（α＝1）；绘图块读环境 | `f3f96a9` |
| P2-5 | 路由打开的磁盘、电源三级用所选档，不跟遥测窗口淡化 | 已修 | `geekChartDuration`／`geekChartRangeTitle` 恢复为所选档（磁盘、电源三级读各自存储）；新增 `geekTelemetryChartDuration`／`RangeTitle`／`IsUpdating` 给读遥测切片的三级（处理器、温度、风扇）与调试路由；调试场景的内存组成用内存指标自己的时长 | 同上（源码断言）。红：两者都取遥测所画窗口 | `f3f96a9` |
| P2-7 | 压缩历史时等级码取最新样本，短时“升高／高”会丢 | 已修 | `MenuBarTelemetryPoint.standingForBucket(replacing:)`：代表样本取最新采样的数值，等级码取该段记录到的最严重系统等级（本采样自己的等级取系统等级，没有时取百分比估算；只搬运已记录的系统等级）。用于内存中历史的分钟压缩、同时刻替换与恢复归一化，`MenuBarHistoryRetention.append／compactOlderPoints`（经通用 `bucketRepresentative`，非遥测类型不变），`MenuBarPowerHistoryStore` 持久化多分辨率取样 | `MiniWindowPressureHistoryCompactionTests`（4）。红：8 处失败——同一分钟先“高”后“正常”压成“正常”；持久化 5 分钟桶内的“升高”丢失 | `69da4db` |
| P2-8 | 删去“也包含系统整理交换文件产生的读写”（无出处） | 已按意见删除 | 悬停说明与设计文档都删去。供参考：本机（macOS 27.2）`man vm_stat` 有原文 “Both swap counters also include I/O used for swapfile maintenance.”，如需恢复可引此出处 | `MiniWindowMemorySwapActivityTests` 通过 | `e111e5e` |
| P2-8（交接） | 交接中 `rates(...)` 的说明更正 | 已是正确表述 | `8e00594` 的交接已写明“实际传入的一直是 Swapins／Swapouts 页数（基线即如此）”，本次未改 | — | — |
| P2-9 | 祖先改挂时重装观察链 | 无需改代码，已加测试 | 本机实测：祖先在同一窗口内改挂时，AppKit 仍对整个子树调用 `viewWillMove(toWindow:)`／`viewDidMoveToWindow()`，锚点视图在这两处移除并重装观察链 | `testAnchorFollowsANewAncestorAfterItsAncestorIsReparented` 在现代码上通过；反证：把锚点视图临时改成同窗口内保留旧观察链后 2 处断言失败（已从备份还原） | `67db4b9` |
| P2-10 | `MiniWindowMemoryPressureLevelTests` 能在 Release 运行的部分移出 `#if DEBUG`；`inlineMemoryRange` 只有测试用 | 已修 | 去掉该文件与 `MiniWindowDiskLevelOneBarTests` 整文件的 `#if DEBUG`（演示数据那项仍在 `#if DEBUG || STORAGE_CLEANER_BETA`），Release 编译由最终性能门禁验证；删除 `MenuBarHistoryDemandPlan.inlineMemoryRange`，测试改为断言内存指标档位等于打开时的 `selectedRange` 且在需求内 | 相关 21 项通过 | `6448502` |
| 范围外 | 风扇历史帧缓存键不区分风扇 | 已修 | `GeekPrecisionLineChart.preparationConfiguration／preparationShape` 并入系列 id（形状也含 id：切换风扇时不把另一台的旧帧当“更新中”显示）；`GeekFanHoverDetail.chartSeries` 的 id 为 `fan-hover-<编号>`／`fan-hover-average` | `MiniWindowFanHistoryCacheTests`（2）。红：平均与两台风扇得到同一个配置 | `b34478c` |

## 改了锁定旧行为的测试（RULES §4）

| 测试 | 改法 | 依据 |
|---|---|---|
| `GeekHoverDetailTargetTests`（内存页标签、`ensureMemorySelectionForQuit` 断言反转、行状态文案、结构名 `GeekMemoryQuitSelectedButton`） | 按新行为改写，注明 D2 | D2 |
| `MemorySelectionSummaryTests`（分段标记 `struct GeekMemoryProcessSelectionMenu: View {` → `enum GeekMemoryQuitSelection {`，禁用规则；第二轮：确认摘要期望值加应用名） | 同上 | D2、D2 补充 |
| `DetailedPanelViewProfileTests.testDiskCascadeKeepsOverviewFreeRatioAndRealVolumeCapacity` → `testDiskCascadeShowsTheUsedShareOnEveryLevelAndRealVolumeCapacity` | 一级横条断言改为已用份额，注明 D14 | D14 |
| `MiniWindowConsistencyRuleTests.testDiskTextNamesWhatEachCapacityGraphicShows` | 一级文字＝卷行同一句话 | D14 |
| `MiniWindowConsistencyRuleTests.testFanAndGPUHistoriesUseTheirRingColors` | 间接规则文本检查改为直接断言 | 本卡第 10 项 |
| `SystemUtilitySafetyTests` 7 处 `pressureLevel` | 改为 `reportablePressureLevel`，期望值不变 | D28（删去 `pressureLevel`） |
| `MemoryDomainTests.testPressureClassificationPrioritizesCriticalSignals` 第一条断言 | 针对已删除的自有推算函数；改为百分比规则 ≤5% 余量为严重 | D28 |
| `SystemMonitorServiceTests` 简单面板源码契约 `store.performRecommendedMemoryAction(presentConfirmationInMenuBar: true)` | 改为 `MenuBarRecommendedAppsQuit.request(store: store, apps: recommendedApps)` | D2 补充 |
| `UnifiedMenuBarPanelTests` 第 678–679 行 | 第一轮曾改为所画窗口；第二轮 `geekChartDuration／RangeTitle` 恢复为所选档，测试已恢复为基线原文（与 `2ac7902` 无差异） | — |
| `PanelChartNormalizationTests.testGeekDiskCardHidesUnavailableActivityPlaceholder` | 未改测试：新静态函数的参数命名为 `storageSnapshot`，既有断言仍成立 | — |

本批自己的测试在第二轮也有调整（`MiniWindowRangeSwitchTests` 两处推断相关断言、`MiniWindowMemoryPressureLevelTests` 去掉推断用的环境值与 `pressureLevel`、`MiniWindowHistoryDemandTests` 的 `inlineMemoryRange`、`MiniWindowMemoryQuitSelectionTests` 摘要期望值）。

新增测试：第一轮 8 个文件 52 项；第二轮新文件 5 个 18 项（`MemoryPressureLevelAppWideTests` 3、`MenuBarSimplePanelQuitTests` 3、`MiniWindowPressureHistoryCompactionTests` 4、`MiniWindowUpdatingStateTests` 6、`MiniWindowFanHistoryCacheTests` 2），另在既有文件新增 4 项（`MiniWindowAnchorGeometryTests` 3、`MemoryCoordinatorTests` 1），共 74 项；共用夹具 `MiniWindowLogicTestSupport.swift`。

## 决定

用户已决定并写入集成分支 `DECISIONS.md`（`cb719fa`），本批已按其实现：D28（全应用内存压力等级取系统等级）、D14 补充（一级横条与卷圆环同一颜色出口，≤20% 橙、≤10% 红）、D2 补充（简单面板“退出这 N 个应用”＋列名确认）。

拟议（请主会话写入 `DECISIONS.md`）：

| # | 决定 | 取代／补充 | 影响 |
|---|---|---|---|
| D2 补充之补充 | 小窗“退出所选应用”按钮为纯文字（无图标）：带图标时英文操作行超过 280 pt 卡宽 | D2 | 小窗内存页 |
| 新 | 内存“换入／换出”表示开机以来从交换文件读回／写入的数据量：取 `vm_stat` Swapins／Swapouts（页，压缩后的数据）× 页大小，按内存字节格式显示，标题带“（累计）”，读不到显示“—” | 原 Pageins／Pageouts 次数 | 内存二级页两行 |
| 新 | 电池状态文字：“正在计算”只在 macOS 对当前有效的时间键给出 −1 时显示；已充满“已充满”、充电中且 `Is Finishing Charge`“即将充满”、接通未充电“已接通电源”、优化充电暂停“已暂停充电”、充电未给时间“正在充电”、用电池未给时间“使用电池”、电池供电而充电标志未知“状态未知” | 原凡无估算即“正在计算” | 一级电池卡、电源页、悬停 |
| 新 | 内存压力历史逐采样着色，一根柱合并多个采样时取最严重等级；历史压缩（1 小时外每分钟、持久化 1 天外每 5 分钟）时代表样本保留该段最严重的系统等级 | D28 的显示细则 | 内存压力历史 |
| 新 | 历史窗口需求按屏幕可见顺序（打开的历史或页面、CPU 卡、网络卡）排列，最多准备 4 个窗口，超出的按该顺序截断并记录、写日志；按路由打开的内存历史读页面档位 | 原保留最短四个、静默截断 | `MenuBarMonitorState` |
| 新 | 切换时间档后，新窗口就绪前保留同一图表上一次所画的窗口；历史切片仍是上一时长（显式传入）或图表仍显示上一时长的预处理帧时，淡化至 45% 并在坐标行显示“更新中…”，就绪后替换；磁盘、电源三级读各自存储，始终用所选档 | 原先清空再画 | 全部三级历史与卡片内历史 |
| 新 | 一级锚点优先用卡片在概览布局中的顶边偏移；锚点视图在自身、祖先、窗口移动后重报。会话在求解级联或程序设框期间收到的几何调用不丢弃：按收到的顺序延后重放，还有排队调用未执行时新到的调用也先入队；同步重放 8 个后其余顺延到下一主队列轮次；同一次操作累计 32 个仍未收敛时只执行最新一个并停止 | 批次 2b P1 修复的补充（N9） | `MenuBarPanelSession`、`SmallWindowInteraction` |
| 说明 | “切档时整组左移约 48 pt”：复现到的是候选原因（设框期间的切页等调用被丢弃，会话按 264 pt 电源列放置而视图已是 312 pt 页面），用户场景未复现，需实机核对 | — | 第 4 项 |

## 需要实机核对

1. 第 4 项：按上文“实机核对建议”操作，确认是否仍有 48 pt 左移。
2. 第 3 项：各页历史切档时图表不再空白，先淡化并显示“更新中…”再替换；风扇历史（硬件控制卡内）切档不再空白 1–4 秒；坐标行左端在更新中显示的是旧档时长，是否接受。
3. 第 6 项：需要有电池的机器：已充满、即将充满（100% 仍在补充）、优化充电暂停、接通未充电、充电中无估算，各自文字；真正估算中才显示“正在计算”。
4. 第 7 项：与活动监视器“内存压力”比对等级与颜色；压力历史逐柱颜色；演示数据 49% 配“升高”是演示夹具自带等级，非推算。
5. 第 8 项：一级磁盘卡文字“N% 已用 · X 可用”、横条为已用份额；空间紧张机器上的橙／红色（D14 补充）。
6. 第 1 项：内存页头部“查看全部／选择／退出所选应用”中英文都在卡内（测试已量 ≤280 pt），禁用态观感。
7. 第 2 项：与 `vm_stat` 比对：Swapins×页大小≈“换入（累计）”。
8. 第 9 项：屏幕边缘级联翻转、切换显示器、打开／关闭二级后，二级顶边仍对齐一级卡顶边；快速切页、打开三级时整组不抖动（原先被丢弃的几何调用现在都会执行）。
9. D28：主窗口内存页、概览、简单面板、小窗的压力等级与活动监视器一致，用词“正常／升高／高”；系统等级读不到时的建议文案“继续观察”。
10. D2 补充：简单面板“可退出应用”卡片按钮“退出这 N 个应用”（英文 Quit These N Apps／Quit This App）在 420 pt 宽面板内不截断（本批未做布局测量）；确认框列出应用名（最多 3 个＋“等 N 个”），取消不退出、确认后只退出列出的应用。
11. P2-3：切换时间档后，旧帧仍在准备新帧期间也显示淡化与“更新中…”，新帧到后恢复；同一时长内每秒的新采样不闪“更新中”。
12. 范围外：传感器页逐个悬停不同风扇与平均转速，各自显示自己的历史，不出现另一台的曲线。

## 验证

| 项 | 命令（摘要） | 结果 |
|---|---|---|
| 基线构建 | `swift build --scratch-path …/batch4b/debug --jobs 4` | PASS，exit 0（149.66 s，`baseline-build.log`） |
| 基线 Debug 全量 | `swift test --scratch-path …/batch4b/debug --jobs 4` | PASS，exit 0，3189 项，跳过 21，0 失败（`baseline-test.log`） |
| 第 10 项红／绿 | `--filter MiniWindowConsistencyRuleTests…` | 红：12 项 5 失败（`t10-red.log`）；绿：106 项 0 失败（`t10-green.log`） |
| 第 1 项红／绿 | `--filter MiniWindowMemoryQuit…` 等 | 红：5 项 10 失败（`t1-red.log`）、布局红 289／295 pt（`t1-layout-red.log`）；绿：197 项 0 失败（`t1-green.log`） |
| 第 8 项红／绿 | `--filter MiniWindowDiskLevelOneBarTests…` | 红：3 项 9 失败（`t8-red.log`）；绿：153 项 0 失败（`t8-green.log`） |
| 第 2 项红／绿 | `--filter MiniWindowMemorySwapActivityTests…` | 红：4 项 23 失败（`t2-red.log`）；绿：173 项 0 失败（`t2-green.log`） |
| 第 6 项红／绿 | `--filter MiniWindowBatteryStatusTests…` | 红：26 项 18 失败（`t6-red.log`）；绿：26 项（`t6-green.log`）、260 项 0 失败（`t6-green2.log`） |
| 第 7 项红／绿 | `--filter MiniWindowMemoryPressureLevelTests…` | 红：12 项 47 失败（`t7-red.log`）；绿：12 项（`t7-green.log`）、572 项跳过 2、0 失败（`t7-wide.log`） |
| 第 5 项红／绿 | `--filter MiniWindowHistoryDemandTests…` | 红：22 项 19 失败（`t5-red.log`）；绿：283 项跳过 1、0 失败（`t5-green.log`） |
| 第 3 项红／绿 | `--filter MiniWindowRangeSwitchTests…` | 红：9 项 28 失败（`t3-red.log`）；绿：31 项（`t3-green.log`）；大范围（小窗、面板、契约类 19 个过滤器）第一次 707 项 7 个失败（5 个测试：`GeekHoverDetailTargetTests`、`MenuBarTertiaryDetailTests` 两个的源码契约文本，改源码保留原写法、测试未动；`UnifiedMenuBarPanelTests` 按本卡第 3 项改测试，见下表；本批新渲染测试补所选档环境值，`t3-wide.log`），处理后加 `BatteryPresentationTests` 共 20 个过滤器 717 项，跳过 1、0 失败（`t3-wide2.log`） |
| 第 9、4 项红／绿 | `--filter MiniWindowAnchorGeometryTests MiniWindowLevelOneAnchorTests MenuBarPanelSessionTests HoverIntentControllerTests MenuBarPanelInteractionTests` | 红：6 项 18 失败（`t9-red.log`）；绿：107 项 0 失败（`t9-green2.log`）；大范围（第 3 项的 20 个过滤器＋`ControlPalette`、`CascadeViewportLayoutTests`）765 项跳过 1、0 失败（`t9-wide.log`） |
| 第 9、4 项补充（顺序重放） | 同上＋`ControlPalette` | 红：7 项 2 失败（`t9b-red.log`：会话停在 power，帧 264×630）；绿：151 项 0 失败（`t9b-green.log`、加入观察者持有对象后 `t9b-green2.log`） |
| 第二轮 P2-1／P2-2 红／绿 | `--filter MiniWindowAnchorGeometryTests`；绿另加 `MiniWindowLevelOneAnchorTests MenuBarPanelSessionTests HoverIntentControllerTests MenuBarPanelInteractionTests ControlPalette` | 红：9 项 4 失败（`r1-red3.log`：会话停在 power 而非 memory；嵌套调用 489→809 个仍在增长）；绿：153 项 0 失败（`r1-green.log`）。注：首版乒乓测试用布局钩子在异步轮次不稳定（`r1-red.log` 46 次后自停、`r1-red2.log` 通过），改用设框测试钩子后可稳定复现 |
| 第二轮 P2-9 | `--filter MiniWindowAnchorGeometryTests` | 新测试在现代码上通过，10 项 0 失败（`r9-test.log`）；反证：临时变异后 1 项 2 失败（`r9-mutation.log`），已从备份还原 |
| 第二轮 D28 红／绿 | `--filter MemoryPressureLevelAppWideTests MemoryCoordinatorTests/...`；绿另加内存、面板、契约类 10 组 | 红：4 项 15 失败（`d28-red.log`）；绿：515 项跳过 1、0 失败（`d28-green.log`） |
| 第二轮 P2-7 红／绿 | `--filter MiniWindowPressureHistoryCompactionTests`；绿另加历史、持久化、性能回归等 | 红：4 项 8 失败（`p27-red.log`）；绿：154 项跳过 1、0 失败（`p27-green.log`） |
| 第二轮 D2 补充红／绿 | `--filter MenuBarSimplePanelQuitTests`；绿另加内存选择与契约类 7 组 | 红：3 项 16 失败（`d2s-red.log`）；绿：474 项跳过 1、0 失败（`d2s-green.log`） |
| 第二轮 P2-3／4／5 红／绿 | `--filter MiniWindowUpdatingStateTests`；绿另加 11 组 | 红：6 项 21 失败（`upd-red.log`）；绿：334 项跳过 1、0 失败（`upd-green.log`） |
| 第二轮风扇缓存键红／绿 | `--filter MiniWindowFanHistoryCacheTests`；绿另加 7 组 | 红：2 项 4 失败（`fan-red.log`）；绿：184 项跳过 1、0 失败（`fan-green.log`） |
| 第二轮 P2-10、P2-8 | `--filter MiniWindowHistoryDemandTests MiniWindowMemoryPressureLevelTests MiniWindowDiskLevelOneBarTests`；`MiniWindowMemorySwapActivityTests` | 21 项 0 失败（`p210.log`）；4 项 0 失败（`p28.log`） |
| Debug 全量（`3f78cf6`） | `swift test --scratch-path …/batch4b/debug --jobs 4` | PASS，exit 0，3240 项，跳过 21，0 失败（191.75 s，`final-test.log`） |
| Debug 全量（`ab4022e`） | 同上 | PASS，exit 0，3241 项，跳过 21，0 失败（179.34 s，`final-test2.log`；比基线 3189 项多 52 项＝本批新增测试数；开始时负载 6.64） |
| 私有接口（`ab4022e`，第一轮） | `python3 script/check_private_api.py` | PASS，exit 0（6 处白名单，`final-checks2.log`） |
| 空白（`ab4022e`，第一轮） | `git diff --check 2ac7902 HEAD`；各提交前 `git diff --check` | PASS，exit 0 |
| Release 小窗性能门禁（`3f78cf6`） | `mkdir -p ~/Developer/.sc-verify/batch4b/scratch`；`STORAGE_CLEANER_VERIFY_ROOT=…/.sc-verify/batch4b/scratch script/verify_menu_bar_performance.sh` | 首次 FAIL，exit 1：`testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 的 preparation p95 101.24 ms > 100 ms，其余 15 项通过；负载 9.16 → 17.30（脚本先做 Release 构建，另有本机其他编译与同步进程）（`perf-gate.log`）。按 N10 等 1 分钟负载降到 6 以下（等了 130 s）后连跑三次：p95 70.55／69.82／96.71 ms，三次均 PASS（`perf-gate-rerun.log`）。参照：集成分支此前门禁 79.44、79.91 ms 通过，高负载时 116.03 ms 失败 |
| Release 小窗性能门禁（`ab4022e`） | 同上，先等 1 分钟负载降到 6 以下（等了 260 s），连跑三次 | PASS，三次 exit 0，每次 16 项 0 失败，源码守卫通过；preparation p95 70.07／70.16／73.81 ms，cached delivery p95 约 0.002 ms；第 1 次含 240.49 s 的 Release 增量构建；负载 5.64 → 4.83（`perf-gate-final.log`） |
| Debug 全量（第二轮最终代码 `e111e5e`） | 同上 | PASS，exit 0，3263 项，跳过 21，0 失败（226.99 s，`final-test3.log`；比基线 3189 项多 74 项＝两轮新增测试数；开始时负载 10.51、结束时 12.34） |
| 私有接口（`e111e5e`） | `python3 script/check_private_api.py` | PASS，exit 0（6 处白名单，`final-checks3.log`） |
| 空白（`e111e5e`） | `git diff --check 2ac7902 HEAD` | PASS，exit 0（`final-checks3.log`）；各提交前另跑 `git diff --check` |
| Release 小窗性能门禁（`e111e5e`） | 同上，先等 1 分钟负载降到 6 以下（等了 460 s），连跑三次（同时验证去掉 `#if DEBUG` 的测试能在 Release 下编译） | PASS，三次 exit 0，每次 16 项 0 失败，源码守卫通过；第 1 次含 393.21 s 的 Release 增量构建（全部测试在 Release 下编译通过）；preparation p95 93.32／80.47／90.83 ms，cached delivery p95 约 0.002 ms；负载 5.78 → 11.59（构建后其他进程负载回升）→ 10.82（`perf-gate-final3.log`） |
| 未运行 | 启动应用、截图、实机核对、安装；严格并发构建；Release 全量 | NOT RUN（启动、截图、实机由主会话负责；后两项本卡未要求） |

本批脚本（`t.sh`）与全量 `swift test` 都带 `--skip-update --disable-automatic-resolution`，不联网；Debug 依赖缓存从集成 scratch 复制并改写路径。性能门禁脚本自身不带这两个参数，日志显示 Sparkle 从本机缓存取得（`Fetched … from cache`），未见下载。日志目录：`~/Developer/.sc-build/batch4b/logs/`。

## JEV 记录（jev-latest，`jev_decide`；只提交非敏感的方案与证据摘要，均为参考，不作批准）

`jev_decide` 返回推荐、概率与逐项检查，不返回 auto／review 字段。

| 决定 | 结果 |
|---|---|
| 第 2 项：换入／换出改为交换字节还是保留分页次数 | 首次调用因 requirements 超过 3 条被参数校验拒绝；重发后 selected `swap_bytes`（0.83；`page_counts` 0.11、investigate 0.04、none 0.02），confidence 0.80，escaped false |
| 第 7 项：只有百分比的旧采样如何估算等级 | 唯一一次调用返回 `status: invalid_response`（无推荐、无置信度）；逐项检查中 `existing_percent_rule` 三项均 supported，`kernel_like_thresholds` 两项 contradicted。没有当作批准；按既有的唯一百分比规则 `MemoryPressurePolicy.classify(pressureFreePercentage:)` 实现，不引入新阈值 |
| 第 4 项：交接措辞 | selected `candidate_fixed_needs_machine_check`，confidence 1.0，escaped false；`confirmed_fixed` 在“不断言现场原因已确认”“主会话可实机核对”两项 contradicted |
| 第二轮 P2-1／P2-2：延后调用的顺序与上限方案（实现后复核） | 首次调用因候选 id 格式被参数校验拒绝；重发后 selected `enqueue_with_newest_once`（0.95；`merge_by_type` 0.01、investigate 0.01、none 0.03），confidence 0.92，escaped false；`merge_by_type` 在“不会无限重放”“保持顺序”两项 contradicted，`enqueue_with_drop_all` 在“用户最后的请求生效”一项 contradicted |

## 未完成与风险

- 第 4 项用户场景未在本机复现（见上）；修复针对复现到的机制，仍是候选原因，需实机核对。
- 原先被丢弃的几何调用现在都会按顺序执行，可能比原实现多做几次级联求解；同步 8 个、同一次操作 32 个的上限见上，超限写 `PerformanceTelemetry.logger` notice。本机测试只有刻意构造的互相抵消调用触发上限；实机若出现这条日志，说明有调用在互相抵消。
- `ScanStore.ensureMemorySelectionForQuit` 没有生产调用方了（D2 后），本批未删。
- `MemoryPressurePolicy.classify(pressureFreePercentage:)` 只剩百分比规则；`SystemMemoryProbe` 仍通过 `memory_pressure -Q` 子进程取空闲百分比，可改读 `kern.memorystatus_level`。
- 清理建议在等级未知时的新文案“继续观察／暂时读不到系统内存压力等级”是 D28 的直接结果，原文案会在不知道等级时说“系统有压力信号”。
- 简单面板按钮文字变长（“退出这 3 个应用”），未做布局测量，列入实机核对。
- `GeekAttachedPanelShell` 在级联子框数量与是否显示三级不一致时仍回退默认框（瞬时错位），未改。
- `displayHistorySlice` 在视图 body 中记录槽位所画窗口（非 `@Published` 状态，不触发更新），属有意为之。
- 更新中状态下坐标行左端显示旧档时长，若用户希望显示新档需改 `GeekHistoryAxisFooter`。
- `programmaticFrameDidApplyForTesting` 是仅供测试的钩子（生产中为 nil，多一次可选闭包判断）。
- 性能：长历史预处理的测量路径（`GeekPreparedLineFrame`，CPU 两通道）上本批只多了一次 `channels.contains(.memoryPressure)`；`MenuBarTelemetryPoint` 多了一个 `Int?` 字段（按字段推算每点约多 16 字节，未实测）；历史压缩的 `bucketRepresentative` 在泛型代码里做一次类型判断（Release 下特化）。空闲时 p95 与集成基线同一量级，未做严格 A/B。该计时测试在高负载下会超过 100 ms（BOARD N10），本批未放宽阈值。
- 锚点视图观察者在视图释放时移除这一点没有专门测试（按会话里已有的同类写法实现）。
