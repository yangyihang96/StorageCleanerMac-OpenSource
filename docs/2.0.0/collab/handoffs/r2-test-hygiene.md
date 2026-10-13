# r2-test-hygiene 测试卫生交接

日期：2026-10-07。工作树：`/Users/developer/Developer/sc-worktrees/r2-test-hygiene`；分支：`task/r2-test-hygiene`；起点：`098edc08c4265b7358977f35d5bf8bc084876842`。开始时工作树干净。

**已准备代码及补丁，尚未编译、运行测试或提交。** 按本批明确指令，不绕过沙箱、不写 `.git`、不安装或启动应用、不 push、不读凭证，也没有清理用户残留。`Sources/` 和 `ScanStore.swift` 无改动。JEV 工具已核对参数并尝试调用，但要求审批，当前 `never` 策略拒绝；没有取得模型判断。

**完成的改动。** 原 48 个文件的 117 处 suite 创建全部经过 `TestPreferenceDomain`；普通随机／固定测试域改为临时目录内的绝对路径，已有临时绝对路径及 Sparkle 域保留同域重开的语义。清理先移除持久域并同步，再删除工厂的唯一目录及 `.plist`；去掉“新建域后马上清空”的多余 reset，不能把它误改成提前删目录。固定 `StorageCleanerMacTests.ScanExclusions` 仅是测试夹具，无产品固定域契约，改为逐次工厂创建、自动 teardown。

`TestPreferenceDomain.make()` 返回 `(defaults, suiteName)`；`makeSuite()` 用于已有 defer／tearDown 的夹具；`make(for:)` 自动登记 XCTest teardown；`open(suiteName:)` 用于重开并检查绝对路径和解析符号链接后的临时根。跨 actor／后台任务只捕获 `String`，在使用线程重开 `UserDefaults`，未添加 `@unchecked Sendable` 或全局可变登记表。`cleanup` 仅允许删除工厂直接拥有的临时目录，可重复调用，清理失败会 `XCTFail`。

**标准域处理。** 137 处原引用中：77 处直接持久化写、7 处随后持久化写的实例别名、1 处为持久化恢复读取旧值，共 85 处改为 `TestVolatilePreferences` 保存／覆盖／恢复 `argumentDomain`；另 52 处原引用保留（只读、通知对象、说明或现有内存覆盖）。`L10n` 无 defaults 注入点，直接换 suite 无法影响产品读取，所以使用仓库已有的不落盘语言 scope 方式，并发送 `didChangeNotification` 使语言缓存失效。首次授权标记也是直接读标准域，无注入点，测试在内存覆盖 true／false；原断言不变。更新忽略列表的阻断测试原先两次 `AppUpdateIgnoreService.clear()` 会持久化清空标准域，现改为内存覆盖空字典及恢复，仍用原产品读取断言验证阻断；该 `ScanStore` 路径没有忽略列表的 defaults 注入点。

已有注入参数的间接写入另补 11 处：`MenuBarPanelSettingsState` 3 处（2 处 `MenuBarPanelInteractionTests`、1 处 `SystemMonitorServiceTests`）；`MenuBarPanelSessionTests.makeSession` 默认几何 store 1 处（参数改 optional，函数体内创建临时域）；独立大型文件／重复文件 store 2 处；V7 promotion revocation defaults 4 处（普通跑分 helper、持续跑分 helper、布局 helper、显式实机捕获测试）；布局 V7 排行榜 identity provider 1 处。普通只读的标准域读取保留。

新增两个辅助／守卫文件，加上本交接，共 68 个改动文件（65 个已有 Swift 文件、2 个新 Swift 文件、1 个文档）。新守卫类有 6 个测试方法，全部 NOT RUN。

**逐文件改动数量。** 路径均在 `Tests/StorageCleanerMacTests/`。以下 suite／旧清空／standard 数量按起点源码统计；“最终手工清理”不计 helper 内部，也不计自动 teardown 的每次运行。标准引用不等于写入次数，逐处分类在后表。N13 只统计本批迁移的根创建点。

| 文件 | 原 suite 创建替换 | 原 removePersistentDomain | 最终手工 cleanup | 原 standard 引用 | 新内存 scope 创建点 | N13 根迁移 |
|---|---:|---:|---:|---:|---:|---:|
| `AppInstallationConflictServiceTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `AppUpdateModelsScanningProviderTests.swift` | 2 | 3 | 2 | 0 | 0 | 0 |
| `BatteryPresentationTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `BenchmarkV7CoordinatorWorkloadIntegrationTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `BenchmarkV7HistoryPresentationTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `BenchmarkV7LeaderboardTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `BenchmarkV7RealHardwareCaptureTests.swift` | 0 | 0 | 0 | 0 | 0 | 0 |
| `BrowserPrivacyHistoryProcessorTests.swift` | 0 | 0 | 0 | 1 | 1 | 0 |
| `BrowserPrivacyRecoveryTests.swift` | 0 | 0 | 0 | 3 | 3 | 0 |
| `ChartContinuityTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `CleanupExecutionSafetyTests.swift` | 4 | 6 | 6 | 0 | 0 | 0 |
| `CleanupHistoryServiceTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `CleanupReceiptHistoryTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `CleanupRuleScannerTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `ConceptLandingNativeLayoutRegressionTests.swift` | 1 | 1 | 1 | 3 | 0 | 0 |
| `ControlPaletteTests.swift` | 11 | 11 | 11 | 3 | 0 | 0 |
| `DuplicateFileScannerTests.swift` | 2 | 2 | 2 | 1 | 1 | 0 |
| `DuplicateSelectedLocationsTests.swift` | 1 | 0 | 0 | 0 | 0 | 0 |
| `ExternalMigrationReceiptTests.swift` | 3 | 0 | 0 | 3 | 0 | 0 |
| `FanControlPlannerTests.swift` | 23 | 23 | 23 | 0 | 0 | 0 |
| `FanControlProtocolSafetyTests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |
| `FanCurveCoordinatorTests.swift` | 3 | 3 | 3 | 0 | 0 | 0 |
| `FanCurveEditorInteractionTests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |
| `FanCurveStoreTests.swift` | 2 | 5 | 4 | 0 | 0 | 0 |
| `FileAnalysisTrashStoreTests.swift` | 1 | 0 | 0 | 0 | 0 | 0 |
| `GeekDashboardConfigurationTests.swift` | 2 | 10 | 9 | 0 | 0 | 0 |
| `HardwareControlPresentationTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `HeavyWorkIntegrationTests.swift` | 0 | 0 | 0 | 0 | 0 | 1 |
| `IndependentFeatureWorkspaceStoreTests.swift` | 11 | 6 | 6 | 0 | 0 | 0 |
| `InterruptedOperationReconcileTests.swift` | 0 | 0 | 0 | 0 | 0 | 1 |
| `ItemListAndDuplicatePresentationTests.swift` | 3 | 2 | 2 | 0 | 0 | 0 |
| `L10nTests.swift` | 0 | 0 | 0 | 13 | 1 | 0 |
| `LegacyCleanupRestoreTests.swift` | 2 | 2 | 2 | 0 | 0 | 1 |
| `MSeriesCoreKernelTests.swift` | 0 | 0 | 0 | 0 | 0 | 2 |
| `MSeriesResourceReceiptTests.swift` | 0 | 0 | 0 | 0 | 0 | 2 |
| `MacBenchmarkLeaderboardIdentityPersistenceTests.swift` | 1 | 5 | 4 | 0 | 0 | 0 |
| `MacBenchmarkLeaderboardTests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |
| `MacBenchmarkPresentationTests.swift` | 0 | 0 | 0 | 9 | 1 | 0 |
| `MacBenchmarkStoreTests.swift` | 0 | 0 | 0 | 0 | 0 | 0 |
| `MacSustainedBenchmarkStoreTests.swift` | 0 | 0 | 0 | 0 | 0 | 0 |
| `MenuBarDefaultsChangeSubscriptionTests.swift` | 2 | 1 | 1 | 0 | 0 | 0 |
| `MenuBarDeviceStatusTests.swift` | 1 | 1 | 1 | 4 | 1 | 0 |
| `MenuBarPanelInteractionTests.swift` | 0 | 0 | 0 | 1 | 0 | 0 |
| `MenuBarPanelPlacementTests.swift` | 1 | 7 | 6 | 0 | 0 | 0 |
| `MenuBarPanelSessionTests.swift` | 1 | 33 | 32 | 0 | 0 | 0 |
| `MiniWindowAnchorGeometryTests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |
| `MiniWindowCascadeSettleTests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |
| `MiniWindowConfigurationR2Tests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |
| `MiniWindowHistoryDemandTests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |
| `MiniWindowLevelOneAnchorTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `MiniWindowLiveReadingRetentionTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `MiniWindowPhase2ReviewTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `PrivacyCleanupPresentationTests.swift` | 0 | 0 | 0 | 1 | 1 | 0 |
| `RecordedCleanupRecoveryTests.swift` | 0 | 0 | 0 | 0 | 0 | 1 |
| `RecordedTrashRecoveryTests.swift` | 0 | 0 | 0 | 0 | 0 | 2 |
| `SafeCleanupLayoutTests.swift` | 0 | 0 | 0 | 0 | 0 | 0 |
| `ScanHistoryTestDefaults.swift` | 2 | 1 | 1 | 3 | 0 | 0 |
| `ScanReadinessServiceTests.swift` | 1 | 1 | 1 | 4 | 2 | 0 |
| `ScanReportServiceTests.swift` | 0 | 0 | 0 | 2 | 1 | 0 |
| `ScanStorePerformanceTests.swift` | 1 | 2 | 2 | 0 | 0 | 0 |
| `SparkleReadOnlyProbeTests.swift` | 1 | 0 | 0 | 0 | 0 | 0 |
| `StorageTreemapLayoutTests.swift` | 1 | 1 | 1 | 0 | 0 | 0 |
| `SystemMonitorServiceTests.swift` | 2 | 0 | 0 | 1 | 0 | 0 |
| `SystemUtilitySafetyTests.swift` | 3 | 7 | 2 | 47 | 25 | 0 |
| `UnifiedMenuBarPanelTests.swift` | 2 | 2 | 2 | 0 | 0 | 0 |

两个新增文件：`TestPreferenceDomain.swift`（唯一 suite 创建入口、工厂／重开／清理、内存覆盖 scope）；`TestPreferenceHygieneTests.swift`（源码守卫、拒绝样例／字面量处理、临时文件位置及清理、后台重开、路径拒绝，共 6 个待执行测试）。

**有意保留的绝对域。** `ExternalMigrationReceiptTests` 3 处、`FileAnalysisTrashStoreTests` 1 处、`DuplicateSelectedLocationsTests` 1 处原来就使用其临时夹具目录里的 `suite` 路径；仅把打开动作换成有路径检查的 `open`，保留同域重开和原外部夹具根的清理（避免删掉仍需使用的 fixture）。`SparkleReadOnlyProbeTests` 1 处必须使用产品传回的 `defaultsDomain`，才能验证 SUDefaultsDomain 实际在 shadow root 写盘及产品清理；同样经 `open` 检查，不换成独立域，不改产品逻辑。

**不能在本批完全隔离的产品路径。** 所有“测试源码直接创建 suite／直接持久化写 standard”的点已处理，但下列产品固定读取／内部默认值不受源码守卫的完整数据流证明覆盖，不宣称 D48 的所有运行期写入已归零：

| 产品位置／入口 | 触发条件与剩余影响 | 本批处理及后续 |
|---|---|---|
| `ScanStore.swift:1337` 内部 `DuplicateFilesStore` | 初始化不给内部 workspace 传 defaults；`DuplicateFilesStore.swift:159-166` 在标准域规则版本缺失／较旧时写候选规则及版本。每次构造 ScanStore 都可能触发；标准域已有新版本时不会新增写。 | 无内部 workspace 注入点；不改产品或 ScanStore。下表列全部 108 处构造／28 个文件。后续产品批应增加内部 workspace defaults 注入，再在测试中传临时域。 |
| `ScanStore.swift:1342` 内部 `LargeFilesStore` | 内部仍默认 standard；其可写偏好属性未来被测试修改时会落盘。 | 无内部 workspace 注入点。当前直接构造独立 store 的缺失注入已补；仅替换测试数据的路径不能证明整个内部 store 永远只读。 |
| `ScanStore.swift:7252` 首次授权完成写入，`:1023` 刷新周期 didSet | 这些状态直接写 standard，`cleanupPreferences` 并不能注入它们。 | 本批直接测试设置改为内存 scope；仍需产品批提供独立注入点。当前唯一直接调用 `prepareInitialPermissionCheckOnLaunch` 的超时测试先覆盖已完成标记，走不重新持久化完成标记的路径。 |
| ScanStore 的 `AppUpdateIgnoreService`／`ApplicationUpdatePreferences` 等默认服务 | 内部直接调用固定标准域服务；store 层没有相应偏好注入。 | 当前阻断测试只检查操作被拒绝，空忽略列表使用内存覆盖且恢复。后续若测试实际完成忽略／默认检查状态保存，需产品注入点。 |
| `MenuBarAdvancedStatusView.swift`、`MenuBarStatusController.swift` 的 `StorageCleanerMac.Snapshot.FanControl` | Debug snapshot 分支的产品代码使用固定普通域；在开启快照模式并触发该分支时有持久化风险。 | 测试源码没有直接创建此域，不能简单改测试创建行；不改产品。默认全量测试与快照显式开启分开记录，给 snapshot factory 加注入点后再隔离。快照只读运行并不保证不写偏好。 |
| N13 的真实 Preferences 文件夹具 | `SystemUtilitySafetyTests.testRelatedFileReviewMovesOnlySelectedExactCandidateAndCanRestoreIt` 直接创建 `com.example.storage-cleaner-fixture-<UUID>.plist`，随后删除，属于旧卸载路径保护测试。 | 产品相关项安全根固定 `PathSafety.homePath/Library`，没有根注入；保持原断言与产品行为，列为未解决。只看测试前后清单无法捕捉这种中途创建又删除。 |

ScanStore 构造清单（起点源码；只列位置数量，不代表每次一定持久化写）：

| 测试文件 | ScanStore 构造点 |
|---|---:|
| `AppUpdateCoordinatorTests.swift` | 3 |
| `AppUpdatePresentationIntegrationTests.swift` | 8 |
| `ApplicationUpdateRelaunchTests.swift` | 1 |
| `CleanupExecutionSafetyTests.swift` | 5 |
| `CleanupRuleScannerTests.swift` | 3 |
| `CleanupSafetyTests.swift` | 1 |
| `CleanupStoreFollowUpTests.swift` | 1 |
| `ConceptLandingNativeLayoutRegressionTests.swift` | 3 |
| `ControlPaletteTests.swift` | 3 |
| `DebugAppUpdatePresentationFixtureTests.swift` | 1 |
| `DebugSmartScanSessionFixtureTests.swift` | 1 |
| `HeavyWorkIntegrationTests.swift` | 11 |
| `IndependentFeatureWorkspaceStoreTests.swift` | 2 |
| `InterruptedOperationReconcileTests.swift` | 2 |
| `MemoryQuitConfirmationTests.swift` | 1 |
| `MemorySelectionSummaryTests.swift` | 13 |
| `MenuBarSimplePanelQuitTests.swift` | 1 |
| `MiniWindowLiveReadingRetentionTests.swift` | 3 |
| `MiniWindowMemoryQuitSelectionTests.swift` | 2 |
| `MiniWindowPhase2ReviewTests.swift` | 1 |
| `SafeCleanupLayoutTests.swift` | 2 |
| `ScanStorePerformanceTests.swift` | 9 |
| `SmartScanHistoryTests.swift` | 1 |
| `StartupItemsDashboardContractTests.swift` | 1 |
| `StartupScanningTests.swift` | 1 |
| `SystemMonitorServiceTests.swift` | 1 |
| `SystemUtilitySafetyTests.swift` | 26 |
| `UninstallStoreWiringTests.swift` | 1 |

**守卫规则和白名单。** 守卫从 `#filePath` 定位整个 `Tests/` 并遍历 `.swift`；源码不存在／不能读直接失败。只允许辅助文件中的一个 `UserDefaults(suiteName:)` 创建入口，其余任何 `UserDefaults`／`NSUserDefaults` 的 suite 创建都失败（包含换行、空白写法）。检查 `standard.set/setValue/setValuesForKeys/setPersistentDomain/removeObject/removePersistentDomain/register/addSuite/removeSuite/setVolatileDomain/removeVolatileDomain`，传播简单 let／var 别名及显式 `UserDefaults = .standard`；不为持久化写设置白名单。屏蔽普通／raw／多行字符串及嵌套注释中的源码断言，但检查字符串插值里的执行代码。

唯一白名单类别是 `setVolatileDomain(..., forName: UserDefaults.argumentDomain)`，必须同时匹配文件和精确调用数量；其它 volatile 域／删除操作也失败。以下 15 个现有 scope 各允许 2 次（设置及恢复），新公共 scope 的实现允许 1 次（同一方法执行设置和恢复）。规则不允许某文件任意增加同类调用。

| 白名单文件 | 允许次数 | 逐条理由 |
|---|---:|---|
| BenchmarkMonitorLayoutTests.swift | 2 | 跑分布局中英矩阵；恢复原内存域。 |
| ConceptLandingNativeLayoutRegressionTests.swift | 2 | 首页布局中英矩阵；恢复原内存域。 |
| ControlPaletteTests.swift | 2 | 系统控制面板布局中英矩阵；恢复原内存域。 |
| ExternalMigrationReceiptTests.swift | 2 | 搬家回执文案；恢复原内存域。 |
| FanControlModeCardTests.swift | 2 | 风扇卡布局中英矩阵；恢复原内存域。 |
| FileAnalysisTrashTests.swift | 2 | 文件分析移到废纸篓文案；恢复原内存域。 |
| GeekOverviewLabelLayoutTests.swift | 2 | 极客概览标签；恢复原内存域。 |
| GeekVPNManagementActionTests.swift | 2 | VPN 操作标签；恢复原内存域。 |
| HealthCapabilityLayoutTests.swift | 2 | 健康能力提示；恢复原内存域。 |
| MemoryHeadroomSysctlTests.swift | 2 | 内存余量文案；恢复原内存域。 |
| MenuBarSecondaryVisualConsistencyTests.swift | 2 | 二级页视觉矩阵；恢复原内存域。 |
| MiniWindowConsistencyRuleTests.swift | 2 | 小窗一致性文案；恢复原内存域。 |
| MiniWindowLogicTestSupport.swift | 2 | 小窗逻辑共用语言 scope；恢复原内存域。 |
| MiniWindowRowLayoutTests.swift | 2 | 小窗行布局中英矩阵；恢复原内存域。 |
| SafeCleanupScopeCardLayoutTests.swift | 2 | 清理范围卡中英矩阵；恢复原内存域。 |
| TestPreferenceDomain.swift | 1 | L10n／首次授权／忽略列表阻断读取无 store 注入点，公共内存 scope；每次显式恢复并通知缓存。 |

源码守卫不是 Swift 全程序分析，不覆盖产品内部默认值、任意复杂别名／闭包转发／反射／CFPreferences 写入。它没有进程级禁止偏好写入的钩子；主会话仍需实际全量测试和磁盘比对。argumentDomain 是进程级内存状态，保留了已有 scope 的并行限制：不要把同进程的不同语言 scope 改成重叠执行；并行 XCTest worker 的各自进程不共享内存域。

**137 处 standard 逐处审计。** 行号对应起点 `098edc08`，不是修改后的文件行号。代码片段仅用于定位，全部原始引用逐条列出（字符串／注释也记入原 137 处）。

| 原文件:行 | 类型 | 处理 | 原行 |
|---|---|---|---|
| `BenchmarkMonitorLayoutTests.swift:384` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `BenchmarkMonitorLayoutTests.swift:395` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `BenchmarkMonitorLayoutTests.swift:397` | 通知对象引用 | 保持；不写偏好 | `object: UserDefaults.standard)` |
| `BrowserPrivacyHistoryProcessorTests.swift:100` | 实例别名后有持久化写 | 改 TestVolatilePreferences，原值按 scope 恢复 | `let defaults = UserDefaults.standard` |
| `BrowserPrivacyRecoveryTests.swift:265` | 实例别名后有持久化写 | 改 TestVolatilePreferences，原值按 scope 恢复 | `let defaults = UserDefaults.standard` |
| `BrowserPrivacyRecoveryTests.swift:1113` | 实例别名后有持久化写 | 改 TestVolatilePreferences，原值按 scope 恢复 | `let defaults = UserDefaults.standard` |
| `BrowserPrivacyRecoveryTests.swift:1130` | 实例别名后有持久化写 | 改 TestVolatilePreferences，原值按 scope 恢复 | `let defaults = UserDefaults.standard` |
| `CleanupStoreFollowUpTests.swift:745` | 说明／断言字面量 | 保持；不执行偏好调用 | `/// test, never UserDefaults.standard (r2-live-fixes-2 review P2-1).` |
| `ConceptLandingNativeLayoutRegressionTests.swift:924` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `ConceptLandingNativeLayoutRegressionTests.swift:933` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `ConceptLandingNativeLayoutRegressionTests.swift:934` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `ControlPaletteTests.swift:1535` | 只读内存域 | 保持 | `let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)` |
| `ControlPaletteTests.swift:1536` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }` |
| `ControlPaletteTests.swift:1540` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)` |
| `DuplicateFileScannerTests.swift:631` | 实例别名后有持久化写 | 改 TestVolatilePreferences，原值按 scope 恢复 | `let defaults = UserDefaults.standard` |
| `ExternalMigrationReceiptTests.swift:584` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `ExternalMigrationReceiptTests.swift:594` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `ExternalMigrationReceiptTests.swift:595` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `FanControlModeCardTests.swift:154` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `FanControlModeCardTests.swift:163` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `FanControlModeCardTests.swift:164` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `FileAnalysisTrashTests.swift:731` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `FileAnalysisTrashTests.swift:741` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `FileAnalysisTrashTests.swift:742` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `GeekOverviewLabelLayoutTests.swift:231` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `GeekOverviewLabelLayoutTests.swift:240` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `GeekOverviewLabelLayoutTests.swift:241` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `GeekVPNManagementActionTests.swift:131` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `GeekVPNManagementActionTests.swift:140` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `GeekVPNManagementActionTests.swift:141` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `HealthCapabilityLayoutTests.swift:164` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `HealthCapabilityLayoutTests.swift:174` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `HealthCapabilityLayoutTests.swift:175` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `L10nTests.swift:6` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:11` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:18` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:37` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:40` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:45` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:51` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:79` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:86` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:95` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:98` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:103` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `L10nTests.swift:118` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:7` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:70` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:89` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:164` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:168` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:173` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:202` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:226` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MacBenchmarkPresentationTests.swift:254` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MemoryHeadroomSysctlTests.swift:70` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `MemoryHeadroomSysctlTests.swift:79` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `MemoryHeadroomSysctlTests.swift:80` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `MenuBarDeviceStatusTests.swift:169` | 读旧值并准备持久化恢复 | 改保存／恢复整个原 argumentDomain | `let previous = UserDefaults.standard.object(forKey: L10n.languageDefaultsKey)` |
| `MenuBarDeviceStatusTests.swift:172` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(previous, forKey: L10n.languageDefaultsKey)` |
| `MenuBarDeviceStatusTests.swift:174` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)` |
| `MenuBarDeviceStatusTests.swift:179` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(language.rawValue, forKey: L10n.languageDefaultsKey)` |
| `MenuBarPanelInteractionTests.swift:193` | 说明／断言字面量 | 保持；不执行偏好调用 | `"UserDefaults.standard.set(density.rawValue, forKey: PanelDensity.defaultsKey)"` |
| `MenuBarSecondaryVisualConsistencyTests.swift:550` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `MenuBarSecondaryVisualConsistencyTests.swift:559` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `MenuBarSecondaryVisualConsistencyTests.swift:560` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `MiniWindowConsistencyRuleTests.swift:371` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `MiniWindowConsistencyRuleTests.swift:381` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `MiniWindowConsistencyRuleTests.swift:382` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `MiniWindowLogicTestSupport.swift:15` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `MiniWindowLogicTestSupport.swift:25` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `MiniWindowLogicTestSupport.swift:26` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `MiniWindowRowLayoutTests.swift:108` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `MiniWindowRowLayoutTests.swift:118` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `MiniWindowRowLayoutTests.swift:119` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `PrivacyCleanupPresentationTests.swift:947` | 实例别名后有持久化写 | 改 TestVolatilePreferences，原值按 scope 恢复 | `let defaults = UserDefaults.standard` |
| `SafeCleanupScopeCardLayoutTests.swift:369` | 获取标准实例 | 保持；后续仅 argumentDomain 覆盖及恢复 | `let defaults = UserDefaults.standard` |
| `SafeCleanupScopeCardLayoutTests.swift:378` | 内存覆盖写 | 保持；仅 argumentDomain，按文件／次数白名单 | `UserDefaults.standard.setVolatileDomain(original, forName: UserDefaults.argumentDomain)` |
| `SafeCleanupScopeCardLayoutTests.swift:379` | 通知对象引用 | 保持；不写偏好 | `NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: UserDefaults.standard)` |
| `ScanHistoryTestDefaults.swift:8` | 说明／断言字面量 | 保持；不执行偏好调用 | `/// into \`ScanStore\`'s \`scanHistoryDefaults\`, which is \`UserDefaults.standard\`` |
| `ScanHistoryTestDefaults.swift:39` | 说明／断言字面量 | 保持；不执行偏好调用 | `"The test wrote scan history to UserDefaults.standard",` |
| `ScanHistoryTestDefaults.swift:56` | 只读持久值 | 保持；扫描历史未改断言的基线读取 | `UserDefaults.standard.data(forKey: ScanHistoryService.defaultsKey)` |
| `ScanReadinessServiceTests.swift:127` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `ScanReadinessServiceTests.swift:128` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `ScanReadinessServiceTests.swift:163` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `ScanReadinessServiceTests.swift:164` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `ScanReportServiceTests.swift:7` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `ScanReportServiceTests.swift:11` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey)` |
| `SmartScanHistoryTests.swift:89` | 说明／断言字面量 | 保持；不执行偏好调用 | `"UserDefaults.standard keeps its scan history")` |
| `SystemMonitorServiceTests.swift:2161` | 说明／断言字面量 | 保持；不执行偏好调用 | `XCTAssertTrue(controllerSource.contains("UserDefaults.standard.set(density.rawValue, forKey: PanelDensity.defaultsKey)"))` |
| `SystemUtilitySafetyTests.swift:517` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:518` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:551` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:552` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:567` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:568` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:583` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:584` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:854` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:855` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:877` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:878` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:889` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:890` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:899` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:900` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:1051` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:1052` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:1119` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.english.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:1120` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:1370` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:1371` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:1754` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(true, forKey: ScanStore.initialPermissionCheckDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:1755` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: ScanStore.initialPermissionCheckDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2015` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2016` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2121` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2122` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2252` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2253` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2279` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2280` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2296` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2297` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2478` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2479` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2489` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2490` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:2520` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:2521` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:4160` | 实例别名后有持久化写 | 改 TestVolatilePreferences，原值按 scope 恢复 | `let defaults = UserDefaults.standard` |
| `SystemUtilitySafetyTests.swift:4281` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:4282` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:5503` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:5504` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |
| `SystemUtilitySafetyTests.swift:5543` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `UserDefaults.standard.set(AppLanguage.zhHans.rawValue, forKey: L10n.languageDefaultsKey)` |
| `SystemUtilitySafetyTests.swift:5544` | 标准域持久化写 | 改共用 argumentDomain 覆盖／恢复，不改产品读取 | `defer { UserDefaults.standard.removeObject(forKey: L10n.languageDefaultsKey) }` |

**N13（可选）处理。** 完成 7 个文件的 10 个真实缓存根创建点迁移：MSeriesCoreKernelTests 2、MSeriesResourceReceiptTests 2、HeavyWorkIntegrationTests 1、InterruptedOperationReconcileTests 1、LegacyCleanupRestoreTests 1、RecordedCleanupRecoveryTests 1、RecordedTrashRecoveryTests 2。这些调用已能传根／journal／userHomeURL／trashURL，或使用显式记录 move 闭包；只改根创建两行，既有身份、回执、冲突、权限、取消及资源预算断言不变。临时根先 `resolvingSymlinksInPath()`，避免 `/var`／`/tmp` 链接触发现有 `O_NOFOLLOW`／journal 路径守卫；目录仍由原生命周期清理。

以下保留，不借本批改变真实 home 安全策略。N13 旧清单有 33 个已确认的 Library 夹具点和 1 个当时存疑的 Containers 点；本批移走 10 个，旧清单剩余 23 个已确认点。该统计是旧清单口径，不能当作全仓实时写文件调用数。

| 文件／起点位置 | 未迁移理由／处理办法 |
|---|---|
| CleanupSafetyTests.swift:144、519 | 验证旧清理 API 的真实 home 边界；PathSafety 的全局 home 无根注入。另有 homeURL 已是临时根的 restore 测试，保持。 |
| RecordedTrashRecoveryTests.swift:68 | `CleanupService.moveToTrashRecorded` 明确要求 `PathSafety.isLexicallyInsideHome/isInsideHome`，不接受临时根且无 home 注入；该文件另两处可注入路径已迁移。 |
| SystemUtilitySafetyTests.swift:169、218、273、300、332、333、334、376、378 | 卸载／相关文件的 home 安全根是产品固定值；其中 :333 直接写真实 Preferences，不能靠 defaults 工厂替换。需先给安全策略或被测服务提供测试根注入，不能用改路径导致拒绝来弱化原成功断言。 |
| UninstallAuthorizationTests.swift:135、182 | 授权／锁夹具包含真实位置策略反证，live helperVerdict 不接测试 home。应在产品批分离可注入策略，再移夹具。 |
| UninstallExecutionTests.swift:12 | 卸载路径验证使用固定 PathSafety home；移动／journal 有注入但上游安全根没有，不能只换 root。 |
| UninstallExperienceTests.swift:12、28、63 | 真实 home 下卸载／相关项位置语义；同上，需根策略注入。 |
| UninstallOwnershipTests.swift:63、95 | 相关项所有权及卸载路径策略固定 home；移动和 journal 注入不能替代 home 策略。 |
| UninstallOwnershipTests.swift:142（旧清单存疑） | 已确认外部像素夹具恢复 helper 的确执行 `data.write(to: metadata)`，仅在显式 manifest 给定且 app/container 路径及身份校验通过后执行；不是默认 suite 创建。该 helper 必须指向约定的真实 Applications／Containers，仍不改。 |
| UninstallRetryResultTests.swift:155、260 | 拒绝／重试原因须经过真实卸载路径验证；无全局 home 注入。 |
| UninstallStoreWiringTests.swift:20 | store 到卸载入口的完整接线；上游 home 根不可注入，不能只改移动环境。 |

**运行期文件数守卫：未实现（可选项）。** 没有稳定的测试进程启动／退出挂钩可在不修改产品及测试 runner 的前提下覆盖全套；CFPreferences 延迟写回、其他测试进程及旧缓存会使进程内简单计数无法可靠归因。改由主会话在串行全量运行前后记录文件名集合，新增和删除不能按总数互相抵消；对标准／固定域另比 SHA-256。比较只记录和报告，不搬移或删除。

**本会话验证状态。** `git diff --check` PASS，exit 0；`git apply --reverse --check prepared/all.patch` PASS，exit 0（只读检查与当前最终文件一致，不执行反向应用）；两个交接 Python 脚本的 AST 语法解析及 manifest 摘要核对 PASS，未执行提交／真实目录快照脚本；源码 token 盘点 PASS（工厂外实际 suite 创建 0、测试源码标准域直接／简单别名持久化调用 0）；65 个已有改动测试文件的 `XCTAssert*` 类型／数量静态比对未变化，括号／方括号／花括号的净计数未新增差异。后两项是 Python 读取源码文本的检查，不是 Swift 编译或执行守卫测试。构建、6 个新测试、全量 Debug／Release、严格并发、运行时偏好比对、提交、安装均 NOT RUN。

**主会话验证步骤。** 先让其他测试进程结束，确认偏好目录没有旧批次持续新增文件；保留现有 21.5 万残留作为基线，不在前后比对期间清理。由主会话在沙箱外执行：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-test-hygiene
python3 /Users/developer/Developer/.sc-build/r2-test-hygiene/prepared/preference-snapshot.py snapshot /Users/developer/Developer/.sc-build/r2-test-hygiene/preferences-before.json
```

若测试进程的标准域不是 `com.apple.dt.xctest.tool`，在 snapshot 时以 `--standard-domain <实际域名>` 补充，两次使用相同参数。脚本还记录固定 ScanExclusions 和 Snapshot.FanControl 文件指纹，完整清单只保存所有 `.plist` 的名称；不会读其它软件 plist 内容。重复验证换新的输出文件名，脚本用排他创建，不覆盖旧证据。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
export STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-test-hygiene/verify
./script/verify.sh > /Users/developer/Developer/.sc-build/r2-test-hygiene/verify.log 2>&1
```

确认门禁包含 Release 全量、Debug 全量、严格并发、源码守卫、小窗性能；记录实际 exit code、测试数、跳过和日志。新测试类必须实际执行，不能仅编译。显式实机／快照 opt-in 测试保持原开关与跳过条件，不为本批启动应用或硬件操作。若主会话需要定位新 guard，可在其私有 scratch 单独 `swift test --filter TestPreferenceHygieneTests`，仍须最后全量验证。

全量结束后给 CFPreferences 写回留出时间，再记录；若文件仍在增长，先归因并重取稳定基线，不把外部进程的新增归咎于本批。

```bash
python3 /Users/developer/Developer/.sc-build/r2-test-hygiene/prepared/preference-snapshot.py snapshot /Users/developer/Developer/.sc-build/r2-test-hygiene/preferences-after.json
python3 /Users/developer/Developer/.sc-build/r2-test-hygiene/prepared/preference-snapshot.py compare /Users/developer/Developer/.sc-build/r2-test-hygiene/preferences-before.json /Users/developer/Developer/.sc-build/r2-test-hygiene/preferences-after.json
git diff --check
```

**期望：本仓库测试前缀 + UUID 的新增 `.plist` 为 0。** 前缀清单来自起点原 suite 表达式（74 条，含 N23 Sparkle 探测前缀），另纳入已知相关文件夹具前缀 `com.example.storage-cleaner-fixture-`。裸 UUID 新文件只报告、不归因或搬移。compare 仅在匹配前缀新增文件时返回 1；标准／固定域内容变化另外报告，即使 exit 0 也不能把上述未注入产品写路径说成已修复。前后清单不能发现中途创建并删除的文件，尤其 N13 的 Preferences 夹具仍需后续根注入。

**补丁和提交交接。** `~/Developer/.sc-build/r2-test-hygiene/prepared/` 中按文件不重叠分为 5 组：

| 补丁组 | 内容 |
|---|---|
| 01-preference-helper | 临时域工厂、受路径保护的重开／清理、公共内存 scope。 |
| 02-temporary-suites | 原 48 个 suite 文件的最终改动；含这些文件里的标准写修复／注入，以及 LegacyCleanupRestoreTests 的临时根迁移。 |
| 03-standard-injections | 其它语言偏好修复及已有产品参数的临时域注入。 |
| 04-cache-fixtures | 其余 6 个 N13 临时根迁移文件。 |
| 05-guard-handoff | 源码／路径卫生测试及本交接。 |

每组有 `NN-name.patch` 和 `NN-name-message.txt`；另有 `all.patch`、`manifest.json`、`commit-prepared.py`、`preference-snapshot.py`、`preference-prefixes.json`、`README.md`。提交说明以约定两行 trailer 结尾。主会话完成验证和复核后可复制：

```bash
python3 /Users/developer/Developer/.sc-build/r2-test-hygiene/prepared/commit-prepared.py
```

提交脚本只针对本 worktree／分支，核对起点 HEAD、空暂存区、改动范围、每个最终文件的 SHA-256 及所有补丁摘要，先检查总补丁可进暂存区，再逐组 `git apply --cached` 和 `git commit --file`；不重新改工作区、不跑验证、不 push。未执行该脚本，没有任何已创建提交。本批合并后残留移到废纸篓仍由主会话单独执行 D48；这里没有提供或执行删除／搬移脚本。

## 主会话验证与更正（沙箱外，2026-10-07 晚）

- **编译**：第一次失败，原因是 `IndependentFeatureWorkspaceStoreTests.swift:428` 的 `LargeFilesStore` 参数顺序写错。主会话已改正。
- **全量测试第 1 次**：进程中途退出。`TestPreferenceDomain.open` 的 precondition 拒绝了 `ExternalMigrationReceiptTests` 在个人目录 `.storage-cleaner-…` 夹具里的绝对路径域。主会话把规则放宽为：只要是绝对路径，且 plist 不会落进 `~/Library/Preferences`，就允许打开，即本工厂的临时目录，或测试自己建的 `~/.storage-cleaner-…` 夹具目录。清理规则仍只删本工厂拥有的目录。
- **全量测试第 2 次**：3609 个，跳过 22 个，32 处失败。失败全部来自 N13 的夹具迁移：恢复、回执、跑分的夹具被移到临时目录后，产品的路径安全规则只接受个人目录下的位置，于是报 `unsafePath`。主会话撤回了全部 N13 迁移：
  - 撤回 `04-cache-fixtures` 组的 6 个文件；
  - 撤回 `LegacyCleanupRestoreTests` 里那一处夹具迁移，偏好域部分保留。
  - N13 仍作为遗留问题处理，要等产品提供注入点后再迁。
- **撤回后定向重跑**：受影响的 10 个类共 76 个测试，跳过 1 个，0 失败。
- **偏好目录比对**：第 2 次全量期间，新增 33 个本仓库前缀加 UUID 的 plist。
  - 31 个时间都在 19:12 前后，名称为 `FanControlPlannerTests.` 等。本分支已没有生成这类名称的代码；同一时间，另一条开发线在用旧代码跑风扇和电池相关测试，应该是它生成的。
  - 2 个是 `StorageCleanerMacTests-<UUID>.plist`，空 plist，来源不明。
  - **结论**：要在没有其他测试进程的时候，再做一次干净的前后比对，才能判定是否达标。

## 复核后主会话修正与更正（2026-10-07 晚）

**复核 P1 已修复：**
- `SystemUtilitySafetyTests.testScanStoreBlocksAppUpdateListChangesDuringScanOrOneClickUpdate`：内存覆盖会盖住持久值，所以改为同时断言两点：store 的状态不是 `.ignored`；`com.apple.dt.xctest.tool` 持久域里的忽略列表前后不变。
  - 反证：去掉 `ScanStore.ignoreAppUpdate` 的 guard 后，两条新断言都失败。
  - 反证运行确实往 xctest 持久域写进了一条忽略记录，留给 D48 清理时一起删。
- `BenchmarkV7CoordinatorWorkloadIntegrationTests.makeStore` 和 `BenchmarkV7HistoryPresentationTests.makeStore`：defaults 参数的默认值从 `.standard` 改为 nil，没有传入时使用 `TestPreferenceDomain.make(for: self)`。
- 定向测试 4 组、42 个，0 失败。

**更正本交接前文：**
- 本批是**单个提交**，不是 5 组。
- N13 迁移已**全部撤回**：迁移数为 0，仍在真实 `~/Library` 建夹具的有 33 处。前文表中的 6 个文件已不在提交里。
- 改动文件 62 个，断言数量不变的是 59 个文件。
- `open` 的放宽只放行两类路径：临时目录下的子目录，以及 `~/.storage-cleaner-*`。
- 主会话第二次全量时，另有 2 个 `StorageCleanerMacTests-*` 和 3 个只含 UUID 的文件。复核已查明它们来自起点代码，即并行会话。
- 守卫能拦住任务点名的写法，但拦不住 `.init(suiteName:)`、参数默认值 `= .standard`、`CFPreferencesSet*` 等写法，列为后续。

**后续批（不在本批）：**
- 测试会改写本应用在 Application Support 下的真实数据：`SystemEnergySession-v1.json`、`Monitoring/MenuBarPowerHistory.json`。
- `MenuBarSamplingGaps.shared` 和 `BatteryPowerModeChangeTests` 仍写标准域。
- 守卫的绕过写法。
- 工厂中的 precondition 一出错会让整个测试进程崩溃。
- N13 需要产品提供注入点。
