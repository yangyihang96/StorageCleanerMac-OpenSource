# 交接：D149 充电上限改回一行分段（2.0.1）

日期：2026-10-19。会话：Claude「CleanMyMac 卸载升级功能逆向」（用户在此会话提出并选择在此处做）。工作树：`~/Developer/sc-worktrees/charge-limit`（分支 `task/charge-limit`，基线树 `6478cdb8` = v2.0.1 工作区 2026-10-19 20:10:30 快照，主会话确认当时 D146、D147 已编过）。未提交、未安装、未推送。

## 1. 用户要求与选择
- 用户 2026-10-19：「充电上限选择没做好，需要去做好了」。
- 追问后用户选择「恢复分段按钮」：一行分段 80/85/90/95/100% 直接点选；选中段＝系统回读的手动上限（100%＝不设上限）；macOS 优化充电把实际上限压住时，下面一行写明；点下去要有进度反馈。

## 2. 原因
- D73、D124 让选中项只跟**实际生效上限**（`effectiveLimit`）走。本机 macOS 27.2 的优化充电（powerd `optimizedChargeLimit`，D59）把实际上限压在 80%，所以选 85/90/95/100% 写入成功后，勾或选中段仍停在 80%，看起来像没选上。
- D73 的系统分段控件点下去先显示新段、再弹回 80%；D124 的勾选行写入期间没有任何反馈。
- 只读核对：本机 2026-10-19 20:00 接电源、电量 80%、未充电（`pmset -g batt`、`ioreg AppleSmartBattery`），与 80% 被压住一致。

## 3. 改了什么
- **选中段**：`BatteryChargeLimitPresentation.selectedSegment` 改为系统回读的手动上限（`state.target`；没开手动上限即 100%）。仍然不用 UserDefaults 里存的偏好，也不用发送中的请求；不支持手动上限（无可选档）时为 nil。
- **实际上限说明**：新增 `effectiveLimitNote`：实际生效值与手动上限不同时一行说明，优化充电（含“手动＋优化”）写「实际 80% · macOS 优化充电暂时压住」，其他来源写「实际 83%」；两者一致或本次临时满充进行中（另有状态行）时不显示。视图里用 `effectiveLimitNote ?? sourceCaption`，所以“优化充电已开启，目前没有限制”“来源未知”这些原有说明照旧。
- **分段行**（`GeekSensorsPowerHoverDetails.swift`，全部在 `GeekChargeTargetSetting` 与 `enum GeekEnergyModePowerTitle` 之间）：`GeekChargeLimitSegments`、`GeekChargeLimitSegment`、`GeekChargeLimitPendingMark`。等宽分段、行高 20、下方 2 pt 间距，左右各缩进 8（文本分区的内缩）；圆角 5、1 pt 边框和分隔线用面板的图表边框色；选中段用 iStat 强调色里的 control／controlText（与分区开关同源，D135）；选中段两侧不画分隔线。写入期间被点的段文字变淡并转一个小圈（开“减少动态效果”时不转），行高不变、其余段禁用；回读确认后选中段才移动；点当前已选中的段不写入。超过 5 档（现有机型没有）用 10 pt 字，保证“100%”放得下。悬停时该段淡底。读屏：每段是按钮（标签“95%”、值“已选择／未选择”、写入中提示“正在设置”），分段组的值是「手动上限 95%，实际 80%」；`accessibilityIdentifier("charge-limit-targets")` 不变。
- **没变**：D59 的读写与验证（`setPreferredTarget` 写入后最多 10 次回读确认、`.userOperation` 立即刷新）、D5（只在用户点击时写）、“本次充到 100%”与“打开电池设置…”两个动作行、失败提示与位置、只读夹具禁用。

## 4. 测试（改期望的都注明 D149 和旧值）
- `PowerFanRestoreTests`：`testSegmentsSelectEffectiveReadbackInsteadOfManualOrStoredTarget` 改名为 `testSegmentsSelectTheManualReadbackAndNoteTheLimitInForce`（新语义＋说明行和读屏值断言）；演示场景里“优化 80%”选中 100%、“临时满充”选中 80%（原为 80%、100%）。
- `BatteryChargeLimitPresentationTests`：源码约束里的 `chargeTargetRows` 改为 `chargeTargetSegments`。
- `MiniWindowIStatEnergyModeLayoutTests`：充电上限分区高度 132 → 79（标签 17＋分段 22＋两个动作行 30＋上下 10）；像素检查改为只有手动上限那一段填色，两个动作行没有勾。
- 窗口类 `FanControlModeCardTests`：`testChargeSegmentsUseEffectiveReadbackAndDoNotHighlightUnconfirmedWrites` 改名为 `testChargeSegmentsSelectTheManualReadbackAndDoNotHighlightUnconfirmedWrites`（选中的是回读的手动上限 100%，写入后未回读不选中）；`testWritableChargeSegmentAppearanceUsesEnabledNativeControls` 只改注释。夹具 `FanCardAccessibilityFixture` 改两处，否则这两个测试根本跑不起来（快照基线上同样报 InvalidTransition）：`close()` 先 `orderOut`、等一轮主线程再拆宿主（同步拆会让 SDK 27 的渲染状态机把 `failed(deinit)` 抛进下一个 await，`CalibrationAppKitLayoutHost` 有同样的规避）；根视图加 `.environment(\.accessibilityEnabled, true)`（同一宿主的做法；不然 SwiftUI 自绘控件不建读屏树，D124 以来按标签找按钮一直找不到）。文件里第二个夹具（`testOverviewEntryLivesInsideTheSensorCardWithoutIncreasingItsFootprint` 用的那个）没动，主会话在 R9f 里处理。

## 5. 验证
见第 7 节。

## 6. 建议写入 DECISIONS 的条目（用户已确认形态；编号 D149 由主会话分配）

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D149 | 充电上限改回一行分段（用户 2026-10-19：“充电上限选择没做好，需要去做好了”；追问后选“恢复分段按钮”）。**选中段**＝系统回读的手动上限（没开手动上限即 100%），不用存储的偏好或发送中的请求；**实际生效上限**与它不同时下一行说明（优化充电：“实际 80% · macOS 优化充电暂时压住”）。写入期间被点的段转小圈、行高不变，回读确认后选中段才移动；点已选中的段不写入。分段自绘：等宽、20 pt、圆角 5、强调色 control 填充；超过 5 档用 10 pt 字。D59 的写入、回读验证、节流和 D5 不变。 | D73 与 D124 的“选中项只跟实际生效值”；D124 充电上限的勾选行形态（能耗模式两个分区的勾选行不变） | `GeekSensorsPowerHoverDetails.swift`（`GeekChargeTargetSetting` 及新增的三个私有视图）、`BatteryChargeLimitPresentation.swift`（`selectedSegment`、`effectiveLimitNote`、`segmentsAccessibilityValue`）；测试见交接 `handoffs/charge-limit-d149.md` §4 |

## 7. 验证记录（2026-10-19，本工作树，未安装、未提交）
- 定向非窗口测试（充电上限、电源面板版式、设计守卫、演示数据扫描等 14 类）192 项全过。
- 非窗口全量 5331 项，跳过 25，失败 3 处，都不在本补丁的文件里，是快照时 D146 进行中的状态（主会话已确认并会改）：`OwnedUIFlatteningContractTests.testCompactPanelUsesSemanticFlatControlsAndExplicitDirections`（网络页箭头断言）、`MiniWindowRangeSwitchTests.testEveryHistoryFrameDeclaresItsShapeWithoutTheTimeWindow`（磁盘摘要 shape 计数）。
- 严格并发 `-strict-concurrency=complete` 构建通过，改动文件无警告；verify.sh 的守卫（Views 不启动进程、无删除/提权命令串、私有 API、删除与进程清单、无冲突副本、`git diff --check`）通过。
- 窗口类（虚拟屏 1 · Codex，`script/run_display_bound_tests.sh`）：`ControlPaletteTests` 49 项全过；`FanControlModeCardTests` 11 项，修夹具后两个充电上限测试通过，仅剩基线同样失败的 `testOverviewEntryLivesInsideTheSensorCardWithoutIncreasingItsFootprint`。
- 离屏渲染自查（临时用例，已删除）：手动 85%、选 95% 被优化充电压在 80%、未设手动上限被压在 80%、临时满充中、7 档、只读，中英文、夜间／日间；7 档时“100%”原先被截断，改成超过 5 档用 10 pt 字后完整。
- **未做**：真实写入充电上限（属硬件写入，需用户另行同意）；新分段没有装进测试版（现装的是 CleanMyMac 卸载那一版，build 20261019080930）。
