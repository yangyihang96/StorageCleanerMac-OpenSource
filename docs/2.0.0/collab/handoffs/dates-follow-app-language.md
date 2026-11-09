# dates-follow-app-language 交接：用户能看到的日期跟随 App 语言（D275）

- 分支：`release/2.0.2`，基线 `0b2e8e04`（D274）；工作树 `~/Developer/sc-worktrees/v2.0.2`；构建目录 `~/Developer/.sc-build/v2.0.2/debug`。
- 实现者：Claude（Opus 5.5）侧会话 `local_9593a13a`，由接口会话 `local_c6ef5aab` 开出，向协调会话 `local_8954e4e7` 报告。规则是协调会话定的，用户还没看过改后的样式。
- 状态：已本地提交（紧接 `0b2e8e04`，用户 11-02：“提交”），**未装机**。提交前协调会话补跑了整套非窗口 Debug（`gate/d275a.sh`，日志 `gate/verify-d275a-logs/`）：主测试包 6403 个、跳过 30、0 失败，桥接 92、组合图标 285、Swift Testing 135 和守卫都通过。
- 证据：`~/Developer/.sc-build/v2.0.2/gate/d275-evidence/`（测试日志、改调用点和查钉源码的脚本、离屏渲染）。调用点的逐行清点在接口会话的笔记 `日期跟随App语言-调用点分类-20261102.md`（行号是 `5e9b3d7b` 时的）。

## 1. 规则

见 `DECISIONS.md` D275。一句话：中文一律 `zh_Hans`（`2026年11月2日 15:23`，24 小时制）；英语沿用系统区域，进程的 locale 不是英语时用 `en_US_POSIX`。

## 2. 改了什么

| 位置 | 内容 |
|---|---|
| `Support/AppDateText.swift`（新） | `L10n.dateLocale`、`L10n.dateLocale(usesChinese:current:)`、`Date.appFormatted(date:time:)`、`Date.appFormatted(_:)` |
| `Support/L10n.swift` | `locale` 的构造拆出 `locale(usesChinese:)`，行为不变 |
| 50 个调用点文件 | 下面清单，括号里是增加的行数 |
| `Tests/StorageCleanerMacTests/AppDateTextTests.swift`（新） | 规则表、每种样式、真实调用点、两个源码守卫，以及一个设了 `SCM_DATE_RENDER_DIR` 才运行的渲染样张 |
| 3 个测试文件 | 6 个旧断言，都注明“D275＋旧值”（见 §5） |

路径相对 `Sources/StorageCleanerMac/`：

- Features：`AppLifecycle/Reminders/UI/AppLifecycleAlertCard.swift`（1）、`AppUpdates/Views/AppUpdatesView.swift`（4）、`Downloads/DownloadsStore.swift`（1）、`LargeFiles/Stores/LargeOldFilesStore.swift`（1）、`Maintenance/SystemMaintenanceProbes.swift`（1）
- Models、Services、Support：`Models/SystemModels.swift`（5）、`Services/CleanupHistoryService.swift`（1）、`Services/MaintenanceChecklistService.swift`（1）、`Services/MaintenanceReminderService.swift`（2）、`Services/ScanExclusionService.swift`（1）、`Services/ScanReportService.swift`（1）、`Services/UtilityListExportService.swift`（1）、`Support/MiniWindowCleanupPresentation.swift`（1）
- Views：`ApplicationsManager/ApplicationsManagerView.swift`（1）、`ApplicationsManager/OtherApplicationGroupRows.swift`（1）、`BrowserPrivacyLightfieldResults.swift`（1）、`BrowserPrivacyRecentDeletionsView.swift`（6）、`BrowserPrivacyRecordPresentation.swift`（2，删 `BrowserPrivacyDateFormatter`）、`CareStudio/CareStudioActivityCards.swift`（1）、`CareStudio/CareStudioMyActivity.swift`（2）、`CleanupScanViews.swift`（6）、`ComputerHealth/BenchmarkV7DashboardView.swift`（6）、`ComputerHealth/BenchmarkV7LeaderboardSection.swift`（5）、`ComputerHealth/BenchmarkV7PerformancePresentation.swift`（1）、`ComputerHealth/ComputerHealthWorkspaceView.swift`（2）、`ComputerHealth/HealthFactorGrid.swift`（1）、`ComputerHealth/HealthScoreHero.swift`（1）、`ComputerHealth/HealthSecurityChecksView.swift`（3）、`ComputerHealth/HealthTrendChart.swift`（1）、`ComputerHealth/PerformanceBenchmarkV11RawRow.swift`（2）、`ComputerHealthView.swift`（10）、`ContentView.swift`（1）、`DesignSystem/FeatureLightfieldCharts.swift`（1）、`FilesLightfield/DuplicateFilesLightfieldView.swift`（1）、`FilesLightfield/FileMigrationLightfieldView.swift`（1）、`FilesLightfield/MobileDeviceBackupInventoryView.swift`（1）、`FilesLightfield/PhotoLibraryLightfieldView.swift`（1）、`ItemListView.swift`（1）、`MenuBarAdvanced/GeekDiskView.swift`（1）、`MenuBarAdvanced/GeekHoverDetailTarget.swift`（1）、`MenuBarAdvanced/GeekSensorsView.swift`（4）、`MenuBarAdvanced/MenuBarAdvancedComponents.swift`（1）、`MenuBarAdvanced/PanelChartTimeline.swift`（3，含中文图表改 24 小时制）、`ProjectArtifactView.swift`（1）、`ReversibleOperationsView.swift`（5）、`Settings/SettingsAIAssistant.swift`（2，删 `settingsText(time:)`）、`Settings/SettingsIgnoreList.swift`（1）、`Settings/SettingsScan.swift`（1）、`SmartScanHealthResultsView.swift`（1）、`SystemUtilitiesView.swift`（5）

改法是脚本 `d275-evidence/apply_d275.py`：每条写明原文和次数，有一条对不上就整次不写。`Sources/` 合计 51 个文件，+110 −109。

## 3. 没改的，为什么

都核对过，不是给人读的日期，或者已经跟随 App 语言：

| 位置 | 是什么 | 不改的原因 |
|---|---|---|
| `Views/MenuBarPanelChrome.swift` 的 `PanelTimestampFormat`（4 个 `DateFormatter`，小窗 7 个源文件在用） | 小窗的采样时间 | 两个只有时间（`HH:mm`、`HH:mm:ss`）；两个带日期，已按 `L10n.usesChinese` 选 `M月d日 HH:mm:ss` 或 `MMM d HH:mm:ss`。都是 24 小时制 |
| `Views/Settings/SettingsAbout.swift:63` | 构建日期，UTC 原文 | 构建脚本写入的记录，诊断时要能对上原文 |
| `Views/ComputerHealth/BenchmarkV7LeaderboardSection.swift:373,434` | 榜单测试日期 `yyyy-MM-dd` | 服务端返回的公开记录，编码时是 UTC，转成本地样式要另外处理时区 |
| `Features/AppUpdates/Providers/SparkleAutomaticUpdateAdapter.swift`、`Services/TimeMachineStatusService.swift`、`Services/AppUninstallService.swift` | `en_US_POSIX` 的 `DateFormatter` | 解析更新源、tmutil、Spotlight 输出 |
| `Features/Maintenance/SystemMaintenanceRunners.swift`、`Services/MaintenanceChecklistService.swift`、`Services/ScanReportService.swift` | `en_US_POSIX` 的 `DateFormatter` | 备份文件夹名、导出文件名 |
| `Models/CleanupRuleProvenance.swift`、`Models/BenchmarkV7LeaderboardModels.swift` | `en_US_POSIX` 的 `yyyy-MM-dd` | 规则元数据（不显示）、榜单上传字段 |
| ISO 8601 26 行、epoch 4 行 | 编码和解析 | AI 助手接口的 JSON、存储、日志、坏文件改名后缀 |
| `calendar.locale = en_US_POSIX` 4 处（`ComputerHealthStore`、`HealthScoreHero`、`HealthTrendChart`） | 日历 | 只用来按天分桶，不显示 |

另外两处写死中文的格式没动：`PanelChartTimeline` 的 `M月d日`（没有时间），`MenuBarPanelChrome` 的 `M月d日 HH:mm:ss`（已是 24 小时制）。时长和相对时间（“3 秒前”）不是日期。

## 4. 以后写日期

- 给人看的：`date.appFormatted(date: .abbreviated, time: .shortened)` 或 `date.appFormatted(.dateTime…)`。`Text(date, format: .dateTime…)`、`Text(date, style: …)` 下一行写 `.environment(\.locale, L10n.dateLocale)`。显示用的 `DateFormatter` 设 `formatter.locale = L10n.dateLocale`。
- 机器读的：`en_US_POSIX` 或 ISO 8601，不走入口。
- 守卫（`AppDateTextTests` 最后两个测试）拦得住 `formatted(date:`、`formatted(.dateTime`、`Date.FormatStyle(`、`formatter.locale = L10n.locale`，以及没设 locale 的日期 `Text`。拦不住日期上的裸 `.formatted()`（和数字写法一样），也拦不住新写的 `DateFormatter` 配别的 locale。

## 5. 测试和证据

- 红：入口占位（直接返回 `current`）时，`AppDateTextTests` 8 个里 7 个红，`testEnglishNeverShowsChinese` 本来就绿（`red-test.log`，11-02 17:45）。
- 绿：定向 35 个前缀，含卫生守卫，跳过窗口类，共 2920 个，18 个跳过，1 个失败；桥接 92 个通过（`d275-green.out`，17:59）。失败的是 `MemorySelectionSummaryTests:141`：它钉的是 `process.capturedAt.formatted`，比清点时查的片段短，没被查出来。改后跑 `AppDateTextTests|MemorySelectionSummaryTests|MSeries|PanelChart` 加卫生守卫，279 个，2 个跳过，0 失败；桥接 92（`d275-render.out`，18:17）。两次构建里，改动的文件都没有警告。
- 查钉源码的测试：`pin_check.py` 只查“删掉的片段在不在测试里”，漏了上面那条。`pin_check2.py` 反过来，拿测试里每个字符串字面量比对改动前后的源文件（含窗口类），结果只有已知的 6 条和守卫自己的模式（`pin2.out`）；`pin_check3.py` 查三引号字符串，0 条。
- 改的 6 个旧断言：`PanelChartNormalizationTests` 的 `8月3日 下午 3:20`、`8月4日 上午 12:05`、`8月4日 下午 12:00` 改成 `8月3日 15:20`、`8月4日 00:05`、`8月4日 12:00`；`MSeriesV11ScaleContractTests` 的 `migration-date`、`duplicate-date` 和 `MemorySelectionSummaryTests:141` 改成入口的写法。测试名 `testMultiDayChartDateFormattingUsesLocalDateAndAMPMAtMidnight` 没改：英语部分还是 `pm`。
- 离屏渲染（`render-sample/`、`render-settings/`、`render-care/`），中英文逐张看过：AI 助手页“上次使用”和访问记录（`2026年11月2日 18:16:57`），内存面板“采样于”和 `Text(_, style:)`（`2026年11月2日 15:23:45`），“我的活动”的“检查于”（`2026年9月22日 00:13`，英文 `Sep 22, 2026 at 12:13 AM`），扫描提醒卡（`2026年10月24日 18:17`）。渲染进程的 `Locale.current` 是 `en_US`，英文因此是美式；中文路径已经不读它，所以看到的中文就是打包后的样子。

## 6. 依赖测试机的 8 个断言（这次没改）

| 位置（`Tests/StorageCleanerMacTests/`） | 期望值怎么算 | 什么机器上会红 |
|---|---|---|
| `FeatureLightfieldComponentTests.swift:266,290,322` | 普通 `.formatted`（系统区域） | 系统语言中文、区域 12 小时制（如 `zh-Hans_AU`） |
| `GBatchReceiptAndReadoutD249D253Tests.swift:110,112` | 同上 | 同上 |
| `PanelChartNormalizationTests.swift:2391` | 同上 | 同上 |
| `AgentSettingsPageTests.swift` 的 `Last used Sep` | 写死的美式英文 | 非美国英语区域（如 `en_AU`） |
| `MiniWindowCleanupPresentationTests.swift:84` | `L10n.locale`，英语时是 `en_US_POSIX` | 同上 |

`FeatureLightfieldComponentTests` 和 `MiniWindowCleanupPresentationTests` 只在窗口运行里跑。要让它们不依赖测试机，期望值改用 `appFormatted`；这次按“旧断言不改”没动。

## 7. 没验证的

1. 真实窗口和打包后的 App：上面都是测试、探针和离屏渲染。
2. 窗口类和窗口全量：中文作用域下日期从英文变成中文，文字宽度会变（多数变窄），只有窗口全量能确认布局；也包括上表里两个只在窗口运行里跑的类。
3. Release、严格并发、全量门禁：协调会话安排。
4. 系统的“24 小时制”开关：进程参数改不了 `hourCycle`，没测。英语路径直接用 `Locale.current`，预计跟随；中文路径用固定标识符，预计不跟随（就是 D275 的代价）。
5. 菜单栏面板是热路径：图表每次格式化多算一次 `L10n.dateLocale`（缓存键里有 locale 标识，切换语言不会用错格式），看门禁的 `menubar_perf`。
6. 运行中切换语言：渲染时才算的文字立刻变；算好存起来的文字要等重算，和 `L10n.text` 一样，没逐处查。
7. ICU 的输出可能随系统版本变（如 AM/PM 前的窄空格 U+202F，测试里已归一），`AppDateTextTests` 比的是完整文字。

## 8. 下一步

1. 协调会话核对 diff，问用户是否提交（一个提交：上面 51 个源文件、2 个新文件、3 个测试文件，加 `DECISIONS.md`、`BOARD.md`、`CHANGELOG.md`、`agent-interface-batch-1.md` 和这份交接）。
2. 全量门禁，含窗口全量（要不小于 2400×1340 的非主屏）。
3. 装测试版后在真实窗口看：扫描页的“上次扫描”、“我的活动”、菜单栏图表的悬停时间、AI 助手页；再切到英文看一遍，然后重启再看。
