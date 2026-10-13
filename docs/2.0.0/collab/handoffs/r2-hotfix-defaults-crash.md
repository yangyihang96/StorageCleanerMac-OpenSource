# 批次 r2-hotfix-defaults-crash：移入废纸篓后写回执即崩溃（P0）

- 分支：`task/r2-hotfix-defaults-crash`，基于集成分支 `5e6333e`；worktree `~/Developer/sc-worktrees/r2-hotfix-defaults-crash`；scratch `~/Developer/.sc-build/r2-hotfix/`（`debug/`、`strict/`，日志在 `logs/`）。依赖从 `integration/debug` 只读复制（checkouts、repositories、artifacts、workspace-state.json 改写路径）。
- 实现：Claude 子代理（Claude Opus 5.5）。提交 `58ac2c1`（修复、回归测试、源码守卫）和本交接提交。
- 结论：根因在源头修复（一个 Combine 订阅闭包不再继承主 actor 隔离）。新测试在旧写法下让测试进程以与实机相同的 SIGTRAP 结束（红），修复后通过（绿）。全仓同类订阅逐个审计，没有发现其他"可能在后台线程收到通知、又继承主 actor 隔离"的闭包；另找到两处会在后台线程写 UserDefaults 的路径，旧代码下同样会触发这次崩溃，本修复一并覆盖（第 4.8 节）。产品行为不变。没有安装、没有启动应用、没有截图；实机核对清单见第 7 节。

## 1. 现象与根因

- 实机（主会话，2026-10-06 21:04）：测试版 20261005020648（提交 `f5a8d45`）清理 4 个测试夹具，点"确认移入废纸篓"后应用立即退出。文件已移入废纸篓，崩溃发生在写回执之后。EXC_BREAKPOINT／SIGTRAP，第 10 号线程，队列 `com.apple.root.utility-qos.cooperative`。
- 崩溃报告副本 `~/Developer/StorageCleanerMac-evidence/round2/live/StorageCleanerMacBeta-2026-10-06-210431.ips`，故障线程（节选）：

  ```
  0  libdispatch          _dispatch_assert_queue_fail
  2  libdispatch          dispatch_assert_queue
  3  libswift_Concurrency _swift_task_checkIsolatedSwift
  4  libswift_Concurrency swift_task_isCurrentExecutorWithFlagsImpl
  5  StorageCleanerMacBeta closure #3 in MenuBarStatusController.install(store:computerHealthStore:)
  6  Combine              Subscribers.Sink.receive(_:)
  8  Foundation           closure #1 in Notification.Subscription.init
  14 Foundation           -[NSNotificationCenter postNotificationName:object:userInfo:]
  15 StorageCleanerMacBeta CleanReportStore.record(_:defaults:journal:)   CleanupMigration.swift:147
  17 StorageCleanerMacBeta closure #1 in CleanReportStore.recordDetached   CleanupMigration.swift:113
  ```

- 机制：
  1. `CleanReportStore.recordDetached`（`365da00` 引入，为了不在主线程上等日志锁和 fsync）在 utility 工作线程上运行 `record`。
  2. `record` 写旧版回执缓存：`defaults.set(data, forKey: "cleanup.v2.reports.v1")`（`Services/CleanupMigration.swift:147`）。UserDefaults 在写入线程上同步发出 `UserDefaults.didChangeNotification`。
  3. `MenuBarStatusController.install` 订阅了这个通知。它的 `.sink` 闭包写在 `@MainActor` 方法里、没有标 `@Sendable`（`sink` 的参数类型也不是 `@Sendable`），Swift 6 推断闭包属于主 actor，并在闭包入口做运行时隔离检查（崩溃栈第 3–5 帧）。Combine 在发布线程上直接调用这个闭包，工作线程上检查失败 → `dispatch_assert_queue` 陷阱。闭包体本来只是 `Task { @MainActor … }`，在调用线程上不需要做任何事。
- 为什么单元测试没发现：测试不安装菜单栏控制器（唯一会出问题的订阅）；测试也从不让 `record` 写标准 UserDefaults（注入隔离日志时写完日志就返回，或写隔离 suite）。
- `recordDetached` 的 5 个调用方（`Stores/ScanStore.swift`），都会在写回执后触发：

  | 行 | 函数 | 场景 |
  |---|---|---|
  | 2290 | `confirmV2Cleanup` | 智能扫描／垃圾清理"确认移入废纸篓"（本次实机） |
  | 3150 | `confirmTrash` | 单项移入废纸篓、部分失败时保存回执 |
  | 4490 | `confirmUninstall` | 卸载 |
  | 4571 | `confirmRelatedAppCleanup` | 卸载相关文件 |
  | 6219 | `confirmVerifiedDuplicateCleanup` | 已验证的重复文件清理 |

  更正：任务卡把 6219 记为"恢复"，它实际是重复文件清理。恢复（操作历史恢复、"恢复最近一次清理"）只写日志文件，清理历史（`CleanupHistoryService.removeMoveRecords`）在主 actor 的 Task 里写 UserDefaults；静态审计没有发现恢复路径在后台线程写 UserDefaults。恢复仍列入实机核对。
- 只有能被旧版本读取的回执（不含永久删除结果）会写这份缓存；本次的"移入废纸篓"回执正是这种。

## 2. 修复（`58ac2c1`）

- `Sources/StorageCleanerMac/Support/MenuBarStatusController.swift`：订阅移到 `static func defaultsChangeSubscription(center:refresh:)`，`.sink` 闭包标 `@Sendable`（与 `MenuBarAuxiliaryMonitorState.swift:325` 已有写法一致），闭包里只有 `Task { @MainActor in refresh() }`。`install` 调用它，`refresh` 仍是 `updateStatusItem(snapshot: store?.menuBarMonitorSnapshot)`（弱引用 self）。
- 行为不变：任何 defaults 变化后，在主 actor 上异步刷新一次状态栏图标；订阅照旧保存在 `palettePreferenceCancellable`。
- `@Sendable` 与 `.receive(on: DispatchQueue.main)` 二选一，选 `@Sendable`：
  - 闭包变成非隔离，编译器会拒绝在闭包里同步访问主 actor 状态；以后有人在 sink 里直接调用 `self.updateStatusItem` 会编译失败，而不是到运行时才崩溃。
  - 与项目现有写法（`MenuBarAuxiliaryMonitorState`、`L10n` 的 `@Sendable` 回调）一致，只有一次线程跳转。
  - 不选 `.receive(on:)`：闭包仍被推断为主 actor，安全只靠链上那一个操作符，删掉它照样编译通过、运行时崩溃；加上闭包里已有的 `Task { @MainActor }`，还会多跳一次。
- 抽出工厂函数只为让测试运行 `install` 实际使用的同一段订阅代码；`install` 会创建真实状态栏项、启动刷新循环，测试里不能调用。

## 3. 测试与红绿证据

新文件 `Tests/StorageCleanerMacTests/MenuBarDefaultsChangeSubscriptionTests.swift`，3 个测试：

1. `testDefaultsNotificationOnWorkerThreadSchedulesStatusRefreshOnMainActor`：私有 `NotificationCenter`；`Task.detached` 在工作线程上发 `UserDefaults.didChangeNotification`（断言确实不在主线程）；断言 `refresh` 在主线程执行。
2. `testReceiptSavedOffMainThreadDoesNotTrapStatusItemSubscription`：实机崩溃路径本身。订阅挂在默认通知中心上，`Task.detached` 里调用 `CleanReportStore.record(report, defaults: 隔离 suite)`——同一行 `CleanupMigration.swift:147` 写入，在同一个工作线程上发通知；断言保存成功、`refresh` 被调度、隔离 suite 能读回该回执。只写隔离的 UserDefaults suite（测试结束删除），不碰日志目录和任何文件。
3. `testDefaultsChangeSubscriptionsDoNotInheritMainActorIsolation`：源码守卫，见第 5 节。

红：工厂函数已抽出、sink 保持原写法（无 `@Sendable`）时：

| 测试 | 结果 | 日志（`~/Developer/.sc-build/r2-hotfix/logs/`） |
|---|---|---|
| 守卫 | FAIL，报出 `Sources/StorageCleanerMac/Support/MenuBarStatusController.swift:70`（当时工厂函数的 `publisher(for:)` 行） | `red-guard.log`，exit 1 |
| 1 | `xctest … exited with unexpected signal code 5` | `red-runtime-worker-post.log`，exit 1 |
| 2 | 同上，signal 5 | `red-runtime-receipt.log`，exit 1 |

两次 signal 5 各生成一份系统崩溃报告（`~/Library/Logs/DiagnosticReports/xctest-2026-10-06-212249.ips`、`xctest-2026-10-06-212311.ips`），故障线程栈摘录在 `red-stacks.txt`：与实机报告逐帧一致——`_dispatch_assert_queue_fail` ← `dispatch_assert_queue` ← `_swift_task_checkIsolatedSwift` ← `closure #1 in static MenuBarStatusController.defaultsChangeSubscription(center:refresh:)` ← `Subscribers.Sink.receive` ← `-[NSNotificationCenter postNotificationName:…]`，队列 `com.apple.root.utility-qos.cooperative`，EXC_BREAKPOINT，异常码相同。测试 2 的栈里同样有 `CleanReportStore.record` `CleanupMigration.swift:147`。

绿（加 `@Sendable` 后）：`green-targeted.log`，exit 0。`MenuBarDefaultsChangeSubscriptionTests` 3/3 通过；`PublicNetworkAddressServiceTests` 5/5 通过，其中包括同一类问题的先例 `testDefaultsNotificationFromBackgroundDoesNotAssertMainActorIsolation`。

取舍：运行期测试放在主测试进程里，没有放子进程。理由：项目已有同样做法的先例（上面那条）；以后若回退，`swift test` 会以 signal 5 中止并留下正在运行的测试名，失败足够明显，代价是同一次运行里后面的测试结果缺失。为此另加了不会崩溃的源码守卫：同样的回退会让守卫断言失败并给出文件和行号；并保留了上面的手工红灯日志。

## 4. 审计清单

### 4.1 判断依据（Xcode 27.0.0 Beta SDK）

- `NotificationCenter.addObserver(forName:object:queue:using:)` 的 block 带 `NS_SWIFT_SENDABLE`（`Foundation.framework/Headers/NSNotification.h:184`）：闭包按 `@Sendable` 处理，不会继承主 actor 隔离。剩下的风险只有 `queue: nil` 时在闭包里用 `MainActor.assumeIsolated`。
- KVO `observe(_:options:changeHandler:)` 的 `changeHandler` 是 `@Sendable`（Foundation 的 swiftinterface）。
- Combine `sink(receiveValue:)`、SwiftUI `onReceive(_:perform:)` 的闭包参数不是 `@Sendable`（Combine、SwiftUI 的 swiftinterface）：写在主 actor 上下文里就继承隔离。Combine 在发布线程上直接调用 sink 闭包（本次崩溃的形态）；`onReceive` 按同样标准审计：发布线程可能不是主线程的，必须先 `.receive(on:)`。
- `ProcessInfo.thermalStateDidChangeNotification`、`NSProcessInfoPowerStateDidChange`："posted on the global dispatch queue"（`NSProcessInfo.h`）。
- 选择器形式的 `addObserver(self, selector:…)`：`@MainActor` 类的 `@objc` 方法在 Swift 6 下也有运行时隔离检查，所以同样要看通知在哪个线程发出。

### 4.2 Combine `.sink`（全仓 9 处）

| 位置 | 上游 | 发布线程 | 结论 |
|---|---|---|---|
| `Support/MenuBarStatusController.swift:77`（原 109） | `UserDefaults.didChangeNotification` | 写入线程，可能是工作线程 | **本次崩溃，已修**（`@Sendable`） |
| `Support/MenuBarStatusController.swift:129` | `store.menuBarAuxiliaryMonitorState.objectWillChange` | `@MainActor` 类，只在主线程修改 | 安全，不改 |
| `Support/MenuBarStatusController.swift:139` | `store.$isMenuBarRefreshPaused` | `ScanStore` 是 `@MainActor` | 安全 |
| `Support/MenuBarStatusController.swift:147` | `menuBarMonitorState.$snapshot` | `MenuBarMonitorState` 是 `@MainActor` | 安全 |
| `Support/MenuBarStatusController.swift:155` | `store.$menuBarRefreshInterval` | `ScanStore` | 安全 |
| `Support/MenuBarStatusController.swift:164` | `FanControlCoordinator.shared.$selectedMode` | `FanControlCoordinator` 是 `@MainActor` | 安全 |
| `Support/MenuBarAuxiliaryMonitorState.swift:325` | `UserDefaults.didChangeNotification` | 任意线程 | 已是 `@Sendable`，安全 |
| `Views/MenuBarPanelSettingsView.swift:51` | `GeekDashboardConfigurationStore.shared.$configuration` | `@MainActor` 类 | 安全 |
| `Views/MenuBarAdvanced/MenuBarLiveCard.swift:65` | `ScanStore`、`MenuBarMonitorState`、`MenuBarAuxiliaryMonitorState`、`ComputerHealthStore`、`FanControlCoordinator` 的 `objectWillChange` | 五个都是 `@MainActor` 类 | 安全 |

### 4.3 SwiftUI `.onReceive`（全仓 16 处）

| 位置 | 通知或发布者 | 发布线程依据 | 结论 |
|---|---|---|---|
| `App/StorageCleanerMacApp.swift:551` | `NSApplication.didBecomeActiveNotification` | AppKit 在主线程发出 | 安全 |
| `App/StorageCleanerMacApp.swift:559` | `NSWorkspace.didTerminateApplicationNotification` | 见下方说明 | 不改，残余风险低 |
| `App/StorageCleanerMacApp.swift:711` | `.storageCleanerShowMainWindow` | 唯一发送方 `MainWindowReopenCoordinator`（`@MainActor`） | 安全 |
| `Features/StartupItems/Views/StartupItemsDashboardView.swift:175` | `.storageCleanerFocusStartupItemsSearch` | 唯一发送方是 `ContentView` 的键盘动作（主线程） | 安全 |
| `Views/MenuBarAdvancedStatusView.swift:532`、`Views/ComputerHealth/ComputerHealthWorkspaceView.swift:48` | `internalBatteryAvailabilityPublisher`（`@MainActor` 类的 `@Published`） | 主线程 | 安全 |
| `Views/MenuBarAdvancedStatusView.swift:668`、`:676` | 低电量模式、热状态（全局队列发出） | 已有 `.receive(on: DispatchQueue.main)` | 安全 |
| `Views/MenuBarAdvancedStatusView.swift:684`、`:692` | `screensDidSleep`／`screensDidWake` | 已有 `.receive(on: DispatchQueue.main)` | 安全 |
| `Views/MenuBarAdvancedStatusView.swift:1467`、`:1472` | `willSleep`／`didWake` | 已有 `.receive(on: DispatchQueue.main)` | 安全 |
| `Support/MenuBarLatencyScript.swift:503` | `hoverLocations`（`PassthroughSubject`） | 只由 `@MainActor enum MenuBarLatencyScript` 发送 | 安全 |
| `Views/CachedAppIconView.swift:60` | `.storageCleanerAppIconChanged` | 唯一发送方 `ScanStore.swift:5776`，在继承主 actor 的 `Task` 里 `await` 之后发送 | 安全 |
| `Views/CleanupScanViews.swift:350`、`:355` | `NSWorkspace.didTerminateApplicationNotification`、`didLaunchApplicationNotification` | 见下方说明 | 不改，残余风险低 |

NSWorkspace 启动／退出通知：`NSRunningApplication.h` 说明运行中应用的状态只在主 run loop 以 common 模式转动时更新，这两个通知随之在主线程发出；`StorageCleanerMacApp.swift:559` 挂在主窗口上，每有一个应用退出就触发一次。本机诊断报告目录（含 `Retired/`）里测试版的崩溃报告只有本次这一份；另一份是 10-03 正式版 1.10.1 的 SIGSEGV（主线程排空主队列时 `objc_release`），与本问题不同类，未调查。没有加防御性的 `.receive(on:)`，因为那会把处理推迟一个 run loop 周期，属于行为变化。如果主会话希望零残余风险，可以单独加，不影响本修复。

### 4.4 `addObserver(forName:object:queue:using:)`（block 形式）

block 都是 `@Sendable`（SDK），不会继承隔离；只需看 `queue: nil` 时是否 `assumeIsolated`。

| 位置 | 通知 | 队列 | 闭包 | 结论 |
|---|---|---|---|---|
| `Support/L10n.swift:105`、`:111` | `UserDefaults.didChangeNotification`、`currentLocaleDidChangeNotification` | nil | 只在锁内清缓存 | 安全 |
| `Support/MenuBarPanelSession.swift:2029` | `didChangeScreenParametersNotification` | nil | 只建 `Task { @MainActor }` | 安全 |
| `Support/MenuBarPanelSession.swift:2038`、`:2049`、`:2075` | `didResignActive`、`NSMenu` 开始／结束跟踪 | `.main` | `assumeIsolated` | 安全 |
| `Support/SmallWindowInteraction.swift:190` | `NSWindow.didMove`、`didResize` | `.main` | `assumeIsolated` | 安全 |
| `Services/FanControlCoordinator.swift:1677`、`:1689` | NSWorkspace 睡眠、会话、关机、唤醒 | `.main` | `Task { @MainActor }` | 安全 |
| `Services/SystemEnergyAccumulator.swift:473`、`:483` | NSWorkspace 睡眠、唤醒 | `.main` | `Task { @MainActor }` | 安全 |

### 4.5 选择器形式的 `addObserver`（`@MainActor` 类的 `@objc` 方法）

| 位置 | 通知 | 发布线程依据 | 结论 |
|---|---|---|---|
| `Views/ModulePresentation.swift:232`–`250`（`MainWindowChromeConfigurator.Coordinator`） | `NSWindow`／`NSApplication` 的屏幕、全屏通知 | AppKit 主线程 | 安全 |
| `Features/AppUpdates/Providers/SparkleProvider.swift:356`、`:362`（`SparkleTargetBoundProbeSession`） | `SUUpdaterDidFindValidUpdate`、`SUUpdaterDidNotFindUpdate` | `SPUUpdater.h`："This class must be used on the main thread"；通知由更新驱动在主队列回调里发出（Sparkle 2.9.4 源码 `SPUBasicUpdateDriver.m:160`、`:273`） | 安全 |
| `Features/AppUpdates/Scanning/SpotlightApplicationScanner.swift:46`（`SpotlightApplicationQuerySession`） | `NSMetadataQueryDidFinishGathering` | 没有设 `operationQueue`（`NSMetadata.h`：通知与委托回调所用的队列；`startQuery` 必须在该队列或主线程上调用），查询在主 actor 上启动，通知在主线程发出 | 安全 |

### 4.6 KVO

| 位置 | 闭包 | 结论 |
|---|---|---|
| `Support/MenuBarStatusController.swift:117` `effectiveAppearance` | `changeHandler` 是 `@Sendable`（SDK），闭包只建 `Task { @MainActor }` | 安全 |
| `App/StorageCleanerMacApp.swift:43` `NSApp.effectiveAppearance` | 同上 | 安全 |

`DistributedNotificationCenter`、`notifications(named:)`：仓库里没有使用。

### 4.7 修复后对 `UserDefaults.didChangeNotification` 的订阅

只有 3 处：状态栏（本次修复，`@Sendable`）、辅助监控（`@Sendable`）、L10n 语言缓存（`@Sendable` block，锁保护）。都不依赖发布线程。后台写入的键（回执缓存、文件夹书签、Sparkle 影子宿主域）都没有 `@AppStorage` 绑定。

### 4.8 在后台线程写 `UserDefaults.standard` 的地方

| 写入 | 线程 | 什么时候写 | 结论 |
|---|---|---|---|
| `CleanReportStore.record`（`Services/CleanupMigration.swift:147`），经 `recordDetached` 的 5 个调用方 | utility 工作线程 | 每次保存能被旧版本读取的回执 | 本次崩溃路径，已覆盖 |
| `FolderAccessGrantService.restoreSavedAccess`（`Services/FolderAccessGrantService.swift:117`） | `ScanStore.restoreFolderAccessForLaunch` 的 `Task.detached(priority: .utility)`；`ScanStore.performScanReadinessCheck` → `ScanReadinessService.summary` 的 `Task.detached(priority: .userInitiated)` | 只在已保存的文件夹书签过期需要刷新、或无法解析需要移除时 | 旧代码下若菜单栏控制器已安装，同样会崩溃（启动或扫描前检查时，取决于书签状态，偶发）；本修复一并覆盖，不需改写入方 |
| `SparkleShadowHost` 创建失败分支与 `remove()`（`Features/AppUpdates/Providers/SparkleProvider.swift:308`、`:314`，`removePersistentDomain`） | `SparkleReadOnlyProbe.probe(bundleURL:)` 是非隔离 async 函数，在全局执行器上运行 | 每次只读 Sparkle 探测结束时清掉影子宿主的 defaults 域；Foundation 文档说这等同于对该域每个键 `removeObject`，可能发出通知 | 同上，已覆盖 |
| 其余写入方 | 都在 `@MainActor` 类型、主 actor 的 `Task`、或 View 里 | — | 不涉及 |

其余写入方逐个核对过：`ScanStore`、`FanControlCoordinator`、`MenuBarPanelSettingsState`、`GeekDashboardConfigurationStore`、`BatteryFullChargeService`、`MacBenchmarkStore`、两个排行榜身份提供者、`DuplicateFilesStore`、`LargeFilesStore`、`FanCurveStore`、`AppInstallationConflictController`、`AuthorizedApplicationMover` 是 `@MainActor`；`ScanHistoryService.record`、`CleanupHistoryService.recordMovedItems`、`ApplicationUpdateCheckSchedule.markChecked` 在 `Task { @MainActor … }` 里调用；`CleanupMigration.migrateIfNeeded` 在 `ScanStore.startCleanupV2Scan`（主 actor）里同步调用；`MenuBarSamplingGaps.end` 由 `ScanStore` 和 `Task { @MainActor }` 调用。

## 5. 源码守卫

`testDefaultsChangeSubscriptionsDoNotInheritMainActorIsolation` 扫描 `Sources/**/*.swift`：

- 每个 `publisher(for: UserDefaults.didChangeNotification`：之后到第一个 `{` 之间要有 `.receive(on:`，或者是 `.sink` 且闭包以 `@Sendable` 开头，否则报"文件:行"。`.onReceive(…publisher(for: UserDefaults.didChangeNotification))` 不加 `receive(on:)` 也会被拦下。
- 每个 `addObserver(forName: UserDefaults.didChangeNotification` 调用（参数表加尾随闭包）：不是 `queue: .main` 时不得出现 `assumeIsolated`。
- 至少找到 2 处发布者、1 处 observer，防止改名后守卫静默失效。
- 反向验证：临时加入一个只含注释的探针文件，写了 4 种形式。守卫恰好报出"`.onReceive` 没有 `receive(on:)`"和"`queue: nil` 加 `assumeIsolated`"两行，没有报"`receive(on: DispatchQueue.main)`"和"`queue: .main`"两行（`guard-probe.log`，exit 1）。探针文件已删除，没有提交。
- 局限：按文本匹配，不解析语法，注释里写出这些形式也会被检查；只管 `UserDefaults.didChangeNotification`，其余通知按第 4 节逐处说明。

## 6. 命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`；所有 `swift` 命令都带 `--jobs 4 --skip-update --disable-automatic-resolution`；Debug scratch `~/Developer/.sc-build/r2-hotfix/debug`，严格并发 scratch `~/Developer/.sc-build/r2-hotfix/strict`。

| 步骤 | 命令 | exit | 结果 | 日志（`logs/`） |
|---|---|---|---|---|
| 基线构建（改动前，含测试） | `swift build --scratch-path …/debug --build-tests` | 0 | 165.7 s | `baseline-build.log` |
| 红：守卫 | `swift test --scratch-path …/debug --filter 'MenuBarDefaultsChangeSubscriptionTests/testDefaultsChangeSubscriptionsDoNotInheritMainActorIsolation'` | 1 | 1 个断言失败（预期） | `red-guard.log` |
| 红：运行期 1 | 同上，`--filter '…/testDefaultsNotificationOnWorkerThreadSchedulesStatusRefreshOnMainActor'` | 1 | signal 5（预期） | `red-runtime-worker-post.log` |
| 红：运行期 2 | 同上，`--filter '…/testReceiptSavedOffMainThreadDoesNotTrapStatusItemSubscription'` | 1 | signal 5（预期） | `red-runtime-receipt.log`、`red-stacks.txt` |
| 绿：定向 | `swift test --scratch-path …/debug --filter 'MenuBarDefaultsChangeSubscriptionTests\|PublicNetworkAddressServiceTests'` | 0 | 8 个执行，0 失败 | `green-targeted.log` |
| 守卫反向验证 | 临时探针文件加守卫测试 | 1 | 恰好 2 处违规（预期），探针已删除 | `guard-probe.log` |
| Debug 全量（`58ac2c1`） | `swift test --scratch-path …/debug` | 0 | 3394 个执行，21 个跳过，0 失败；测试耗时 184.9 s；负载 6.5–14.5 | `full-debug-1.log` |
| 严格并发（`58ac2c1`，新 scratch 全量编译） | `swift build --scratch-path …/strict -Xswiftc -strict-concurrency=complete` | 0 | 0 错误、0 编译警告（唯一一条是 `--skip-update` 选项已弃用）；171.9 s；负载约 9–14 | `strict-concurrency.log` |
| 私有 API | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `check-private-api.log` |
| `verify.sh` 的源码检查 | Views 不启动进程、内存功能不调用 purge、没有冲突副本（与 `verify.sh` 相同的 grep／find） | — | 都没有匹配，PASS | — |
| 空白检查 | `git diff --check 5e6333e HEAD` | 0 | — | — |

- 21 个跳过都是其他测试类里原有的条件跳过：需要环境变量或显式请求才运行的实测项，外加一条只在打包门禁里计时的性能项（AppUpdateOfficialSecurity 4、BenchmarkV7RealHardwareCapture 3、CleanupRuleScanner 2，其余 12 类各 1；跳过原因见日志）。本批没有新增跳过。新测试类 3/3 通过。
- 这次全量没有出现 N10 计时项失败；没有放宽任何阈值。
- NOT RUN（属于主会话门禁或实机）：Release 全量、`script/verify_menu_bar_performance.sh`、打包、安装、启动应用、截图、实机清理／卸载／恢复。

## 7. 需要实机核对（主会话）

只用隔离夹具，每项确认应用不退出、状态栏图标正常、操作历史里出现对应回执：

1. 智能扫描／垃圾清理：选夹具，"确认移入废纸篓"（本次崩溃的原操作）。
2. 卸载一个夹具应用；再对它做一次"卸载相关文件"。
3. 恢复：在操作历史里恢复一次；再用"恢复最近一次清理"一次。
4. 重复文件清理（有夹具时）。
5. 主窗口存储列表里单项"移到废纸篓？"一次：成功路径只在主线程写清理历史，作回归；部分失败时才经过 `recordDetached`，不易制造。
6. 改一个会影响状态栏显示的设置（例如状态色或显示模式），确认图标仍立即刷新（订阅行为未变）。
7. 可选：启动时若有已过期的文件夹书签，应用不再退出（第 4.8 节第二行）；不容易人为制造，可只观察。

## 8. JEV 复核

只提交了 diff 摘要、审计结论和测试结果摘要，没有私人数据。分数 0–2，括号内为置信度。

| 时机 | correctness | spec_match | test_gap（越低越好） | blast_radius | composite | safe_to_apply | action |
|---|---|---|---|---|---|---|---|
| 提交前，只有红绿定向结果 | 1.85（0.77） | 1.87（0.81） | 0.61（0.34） | 0.93（0） | 0.835 | 0.31 | escalate |
| 全量测试、严格并发构建之后 | 1.88（0.81） | 1.98（0.96） | 0.12（0.83） | 0.66（0.02） | 0.915 | 0.67 | escalate |

两次都是 escalate：影响面一项的置信度接近 0，低于自动通过的门槛。这与正常流程一致——仍需主会话复核和实机核对；没有把 JEV 结果当作批准。

## 9. 未解决与风险

- 第 4.3 节 NSWorkspace 启动／退出通知的 3 处 `onReceive` 没有改，依据是主线程 run loop 发出和实际没有崩溃记录，不是逐帧证明。
- 运行期回归测试一旦回退会中止整个测试进程（第 3 节取舍）。
- 守卫是文本级检查（第 5 节局限）。
- `recordDetached` 仍在后台线程写 UserDefaults，这是 `365da00` 的设计（避免主线程等锁与 fsync），本批没有改；修复后对它没有剩余订阅风险。
- 没有改 `DECISIONS.md`、`BOARD.md`、`Stores/ScanStore.swift`。
