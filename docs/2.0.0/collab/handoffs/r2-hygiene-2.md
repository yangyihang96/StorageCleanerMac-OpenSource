# r2-hygiene-2：N26 / N13 测试状态隔离

> **fix2 状态见第 8 节。** 主会话已提交 fix1 至 `92ca6f2`，报告测试目标编译通过，但定向运行失败并崩溃。第 1、2、5 节关于“操作夹具全部置于系统临时目录”“为夹具接受系统别名”的描述和对应反证已被 fix2 撤回；操作夹具位置及后续命令以第 8 节为准。偏好和普通 JSON 仍仅使用系统临时目录。

- 分支：`task/r2-hygiene-2`；基线：`9e53489e06f6a4e08540a9e0538bb9139cc338e7`。
- worktree：`~/Developer/sc-worktrees/r2-hygiene-2`；scratch：`~/Developer/.sc-build/r2-hygiene-2`。
- 依据：D5（写操作边界）、D48（测试偏好与夹具隔离）、D55 / D60（Codex 只准备源码、测试及分组补丁，主会话验证与提交）。垃圾分级与清理确认仍遵守 D19、D22–D25。
- 本批拥有 `ScanStore.swift`。没有修改其他 worktree、提交、构建、运行 Swift/XCTest、安装、启动应用、写硬件或清理本机残留。
- **实现与静态准备完成；运行验收 NOT RUN。** 不将静态扫描称为 Swift 编译、XCTest 守卫通过或本机零写入证据。

## 1. 改动与理由

### N26：ScanStore、能耗、功耗与偏好

新增测试唯一入口 `ScanStore.makeForTests(for:...)` 和 `TestFileSystem`。原 28 个文件的 **108 处**构造（包括带部分 mock 的构造）全部迁入工厂；逐文件数量见 scratch `prepared/scan-store-callers.json`。新增隔离契约测试也经过该入口。

工厂默认创建临时家目录、绝对路径偏好域、能耗文件、功耗历史、回执日志、模拟废纸篓、更新队列和文件分析环境。显式提供的数据目录也必须处于系统临时根下。偏好跨异步边界只传 suite 字符串，在工作线程重开；不把 `UserDefaults` 改成 Sendable。测试可继续传原有 mock，不移除其成功/拒绝断言。

`ScanStore` 新注入主偏好、采样间隙 store、功耗历史路径与文件分析环境；原有能耗 store 注入点继续使用。菜单刷新间隔、授权标记、更新偏好/忽略清单、书签、清理历史及两个独立工作区均使用相应注入偏好。操作记录列表/详情/启动读取及卸载、恢复、重复清理继续传递注入的 journal/home。否则即使构造时隔离，动作回调仍可能回到标准域或 live 日志。

`SystemEnergyAccumulator` 生命周期观察者使用注入的 `MenuBarSamplingGaps`；菜单暂停/恢复也使用同一个依赖。`MenuBarSamplingGaps` 本身原已有 `defaults:`，本批修复的是其上游默认 `.shared` 的泄漏。`BatteryPowerModeChangeTests` 给 `FanControlCoordinator` 注入 `TestPreferenceDomain`；`HeavyWorkIntegrationTests` 的 `ApplicationUpdatePreferences.set` 也改用该域。`PublicNetworkAddressServiceTests` 补上 `powerHistoryURL: nil`。Sparkle 临时域同步改为通过受检查的偏好工厂重开后同步，不再直接使用 CFPreferences 写/同步接口。

移除 `TestPreferenceDomain.isIsolatedSuiteName` 对个人 home 下 `.storage-cleaner-*` 目录的例外；只允许临时目录中的绝对路径。标准域现有键和文件没有被删除或恢复。

### N13：33 处及 1 处存疑的逐项核对

原位置沿用 `r2-junk-actionable.md` 第三轮清单（其行号属于当时版本，不是本批当前行号）。每个编号均已迁移，没有以跳过测试或改成拒绝断言代替成功路径。

| 文件 | 原清单位置 | 本批处理 |
|---|---|---|
| CleanupSafetyTests | 144、519 | 2 个临时根；清理显式 home，恢复使用原有 home 注入 |
| HeavyWorkIntegrationTests | 201 | 1 个临时回执根 |
| InterruptedOperationReconcileTests | 16 | 1 个临时回执根 |
| LegacyCleanupRestoreTests | 15 | 1 个临时根 |
| MSeriesCoreKernelTests | 62、84 | 2 个临时内核夹具根 |
| MSeriesResourceReceiptTests | 8、22 | 2 个临时内核/回执根；保留取消、未知资源不得递归清理断言 |
| RecordedCleanupRecoveryTests | 13 | 1 个临时根；保留成功恢复/冲突/中断回执断言 |
| RecordedTrashRecoveryTests | 30、68、94 | 3 个临时根；清理传入根，保留部分失败和身份校验 |
| SystemUtilitySafetyTests | 169、218、273、300 | 4 个临时卸载根；计划与动作使用该根 |
| SystemUtilitySafetyTests | 332、333、334 | 临时 home 下的缓存、偏好 plist、回执/模拟废纸篓；3 处 |
| SystemUtilitySafetyTests | 376、378 | 临时 home 下的缓存和临时回执根；2 处 |
| UninstallAuthorizationTests | 135、182 | 2 个临时根；计划使用 fixture home；真实 helper 位置拒绝判定保留 |
| UninstallExecutionTests | 12 | 1 个临时根 |
| UninstallExperienceTests | 12、28、63 | 临时 home 中的新增/消失候选、用户链接、签名残留回收目录；3 处 |
| UninstallOwnershipTests | 63、95 | 2 个临时根；缺少归属证明仍拒绝、有空选择仍可建计划 |
| UninstallRetryResultTests | 155、260 | 2 个临时根；多报告恢复显式传递 fixture home |
| UninstallStoreWiringTests | 20 | 1 个临时根；工厂传入相同 cleanup home |
| UninstallOwnershipTests | 142（原存疑项，另计） | 确认旧 helper 会写 manifest 指向的 container metadata。现在只读原 app/metadata，复制签名 app 后在临时 home 内建容器并篡改/移动副本。保留签名匹配、重复安装、metadata 篡改和残留恢复的断言 |

原 15 个文件合计 **33 处 + 1 个 metadata helper**，全部处理。

上批 N13 回退的原因不能只靠替换路径解决：旧日志中既有 home 边界拒绝，也有 `CleanupReportJournal.swift:138`、`MSeriesStorageKernel.swift:32` 对系统临时路径的 `unsafePath`。本批为清理/卸载/归属发现增加实例参数根，且复用已有 `OperationFileLock.systemAliasResolvedPath`：仅允许 root 所有、目标精确为 `/private/var` 或 `/private/tmp` 的系统别名。`PathSafety` 后续逐级检查、恢复的 `openat(O_NOFOLLOW)`、文件身份检查均保留；用户符号链接仍拒绝。文件分析对根路径的比较也只认可相同的已验证系统别名。

额外发现并处理：`ExternalMigrationReceiptTests`、`SystemUtilitySafetyTests` 的迁移源，`IndependentFeatureWorkspaceStoreTests` 的重复结果夹具，`StorageMapIndexEditingTests`、`StorageMapAnalysisEquivalenceTests`、`FileAnalysisTrashTests` 的个人 home 隐藏目录，以及 `CleanupStoreFollowUpTests` / `CleanupExecutionSafetyTests` 的 `/Users/Shared` 日志/隔离目录。迁移服务与重复文件选择新增 home 注入，成功复制/移动/还原/重新加载的断言保留。共享 `TrashFixture` 的两个测试类列入定向验收。

### 只读真实 Library 与源码守卫

`IndependentFeatureWorkspaceStoreTests` 两处及 `StorageTreemapLayoutTests` 一处改用临时文件分析环境，不再使用默认 `.live` 去丰富真实资源库信息。

`TestPreferenceHygieneTests` 仅枚举 `Tests/**/*.swift`。新增规则：显式/推断的 suite `.init`；无参数 UserDefaults；标准域直接或简单别名写入及默认参数；CFPreferencesSet* / AppSynchronize；绕过工厂的 ScanStore 构造；shared 采样间隙写入；真实 home 派生的缓存/偏好/本应用目录；真实 `~/Library/Caches` 与本应用数据目录字面量。另外，三个已知会间接落盘的构造器必须显式注入：FanControlCoordinator.defaults、SystemEnergyAccumulator.fileURL/samplingGaps、MenuBarAuxiliaryMonitorState.powerHistoryURL。嵌套闭包里的同名参数不能代替顶层注入。模拟 storageAnalysisOperation 与 treemap 布局测试还必须显式传夹具环境，拒绝默认/显式 `.live`。

保留 D48 既有的逐文件、定数量 `argumentDomain` 内存语言覆盖白名单；不允许持久写。新增路径例外仅为 3 个纯模型/临时 home 的产品目录名字面量，以及 Sparkle 对真实偏好目录的**只读文件名监测**。例外都锁定数量，真实 home 数据流规则始终执行。注释、字符串源码契约被词法器隔离，但字符串插值中的执行代码继续检查；UTF-16 范围与正则一致。

## 2. 生产默认值契约

以下是全部新注入点的生产默认；均与改前隐式依赖相同。没有进程级 HOME 开关、全局测试标志或可变全局根。

| 入口 | 默认值及改前对应 |
|---|---|
| ScanStore.menuBarPowerHistoryURL | `MenuBarPowerHistoryStore.defaultURL`；仍仅在无 MetricHistoryStore 时启用 legacy 功耗文件 |
| ScanStore.samplingGaps / SystemEnergyAccumulator.samplingGaps | `.shared`，即 `MenuBarSamplingGaps(defaults: .standard)` |
| ScanStore.preferences | `.standard`；对应改前各功能直接使用标准域 |
| ScanStore.fileAnalysisTrashEnvironment | `.live`；对应 LargeFilesStore 原默认环境 |
| PathSafety.isLexicallyInsideHome / isInsideHome | `FileManager.default.homeDirectoryForCurrentUser` |
| CleanupService 三个清理入口 | 同上；原 userTrashURL / restoreFromTrash 默认也未变 |
| AppUninstallService.moveToTrash / reviewableRelatedItems / moveRelatedItemsToTrash / isSafeRelatedPath | 同上 |
| InstalledAppItem.canMoveToTrash(homeDirectory:) | 新显式方法没有默认参数；旧属性仍传真实 home |
| UninstallOwnershipVerifier.prepare / discover / isCurrent | 真实 home |
| UninstallPlan.init / AppUninstallService.residualReview | 真实 home；计划冻结该根并用于执行时重验 |
| CleanupRecoveryService.restore(reports:) | 真实 home；单报告恢复的原默认不变 |
| CleanReportStore.summaryPage / report | `.live` journal；只有 live journal 继续合并标准域旧缓存，隔离 journal 不读取旧缓存 |
| DuplicateFilesStore.userHomeURL | 真实 home；ScanStore 传其既有 cleanupUserHomeURL，生产默认仍是真实 home |
| ExternalDriveMigrationService.migrate / moveOriginalToTrash | 真实 home；原复制/移除原件的安全根相同 |

能耗生产文件仍为 AppDataDirectories 根下的 `SystemEnergySession-v1.json`；功耗仍为 `Monitoring/MenuBarPowerHistory.json`，Beta / Release 根选择没有修改。`TestDataIsolationTests` 的两个生产默认源码契约覆盖以上声明、旧属性及文件位置；行为测试验证临时能耗持久化、功耗加载、偏好写入、采样间隙跨实例读取与系统别名/用户链接边界。默认路径不变与“临时路径现在可通过合法系统别名”是两项独立结论，后者仍需运行安全回归。

## 3. 旧断言调整说明

依据 D48 和本批用户明确要求，保留所有行为、计数、时间阈值、失败码及成功断言。以下只替换测试输入或被观察的域，并列出涉及旧断言的地方：

1. `CleanupSafetyTests`、`CleanupHistoryServiceTests`、`ScanReportServiceTests`、`SafeCleanupLayoutTests` 中纯模型/Markdown 的 `~/Library/Caches` 示例改为 `/Users/fixture/Library/Caches`，对应期望字符串同步变化。归类、包含关系、历史内容和计数断言不变。tilde 展开测试使用 `~/Documents`，仍断言展开与 home 包含。
2. `SystemUtilitySafetyTests.testAppUninstallRelatedCleanupOnlyAllowsCommonUserLibraryRoots` 使用临时 home 显式验证允许/拒绝边界；规则未放宽。初始授权测试使用同一个临时域模拟首次/再次启动；断言不变。
3. `testScanStoreBlocksAppUpdateListChangesDuringScanOrOneClickUpdate` 从真实标准域/volatile 遮罩改为临时持久域；保留 store 列表、状态、忽略判定及前后持久内容不变的断言。`HeavyWorkIntegrationTests` 不再保存/恢复真实更新偏好，而是同一临时域驱动产品与断言。
4. `PreferencesFolderContractTests` 的诊断与注释样本文字去掉指向个人目录的 `~/`，守卫仍查相同的 `Library/Preferences` 构造，不缩小范围。
5. `ExternalMigrationReceiptTests` 的生产调用源码契约新增禁止传 `homeDirectory:`，锁住生产仍使用默认根；原 journal/volumes/trash 断言全部保留。
6. `CleanupExecutionSafetyTests.testJournalReloadRetainsIdentityAndRejectsChangedIntent` 不再依赖 `/Users/Shared`，移除仅用于该目录是否存在的 `XCTSkipUnless`。没有增加跳过，身份和损坏日志断言保留。
7. 签名卸载测试只替换输入 app/container 为临时副本；原真实 metadata 位置/命名防写检查由“只读原件 + 随机临时目标”取代。签名、归属、篡改、重复安装和恢复结果断言均未删。

## 4. 主会话验收命令（本会话均 NOT RUN）

在本 worktree 的普通沙箱外 shell 中执行。先构建再开始目录快照窗口，避免把编译器缓存写入混入测试运行。依赖按 RULES 从 `r2-u1-preselect/debug/{checkouts,repositories,artifacts,workspace-state.json}` 复制到本批独占 scratch；不借用其构建目录。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-2"
SC_PREPARED="$SC_SCRATCH/prepared"
SC_RUN="$SC_SCRATCH/logs/acceptance-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SC_RUN"
set -o pipefail
swift build --build-tests --scratch-path "$SC_SCRATCH/debug" --jobs 4 2>&1 | tee "$SC_RUN/build-tests.log"
SC_FILTER="$(paste -sd '|' "$SC_PREPARED/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/targeted.log"
```

定向清单包含全部改动测试类和共享夹具/别名校验的相关类，完整 61 类如下（Debug 下 `#if` 排除的 Release 契约类在 Release 门禁运行）：

```text
AppUpdateCoordinatorTests
AppUpdatePresentationIntegrationTests
ApplicationUpdateRelaunchTests
BatteryPowerModeChangeTests
ChartContinuityTests
CleanupExecutionSafetyTests
CleanupHistoryServiceTests
CleanupRuleScannerTests
CleanupSafetyTests
CleanupStoreFollowUpTests
ConceptLandingNativeLayoutRegressionTests
ControlPaletteTests
DebugAppUpdatePresentationFixtureTests
DebugAppUpdatePresentationReleaseIsolationTests
DebugSmartScanSessionFixtureTests
DebugSmartScanSessionReleaseIsolationTests
ExternalMigrationReceiptTests
FileAnalysisTrashProtectedScopeTests
FileAnalysisTrashStoreTests
FileAnalysisTrashTests
HeavyWorkIntegrationTests
IndependentFeatureWorkspaceStoreTests
InterruptedOperationReconcileTests
LegacyCleanupRestoreTests
MSeriesCoreKernelTests
MSeriesResourceReceiptTests
MemoryQuitConfirmationTests
MemorySelectionSummaryTests
MenuBarSimplePanelQuitTests
MiniWindowLiveReadingRetentionTests
MiniWindowMemoryQuitHeaderLayoutTests
MiniWindowMemoryQuitSelectionTests
MiniWindowPhase2ReviewTests
OperationFileLockTests
PreferencesFolderContractTests
PublicNetworkAddressServiceTests
RecordedCleanupRecoveryTests
RecordedTrashRecoveryTests
SafeCleanupLayoutTests
ScanReportServiceTests
ScanStorePerformanceTests
SmartScanHistoryTests
SparkleReadOnlyProbeTests
StartupItemsDashboardContractTests
StartupScanningTests
StorageMapAnalysisEquivalenceTests
StorageMapAnalysisPerformanceTests
StorageMapIndexEditingTests
StorageTreemapLayoutTests
SystemEnergyACTelemetryTests
SystemEnergyAccumulatorTests
SystemMonitorServiceTests
SystemUtilitySafetyTests
TestDataIsolationTests
TestPreferenceHygieneTests
UninstallAuthorizationTests
UninstallExecutionTests
UninstallExperienceTests
UninstallOwnershipTests
UninstallRetryResultTests
UninstallStoreWiringTests
```

全量 Debug 运行窗口的只读快照：

```bash
python3 "$SC_PREPARED/snapshot-real-state.py" take "$SC_RUN/before-debug.json"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 2>&1 | tee "$SC_RUN/full-debug.log"
# 给异步偏好同步短暂落盘时间；不要删除/恢复任何真实文件。
sleep 3
python3 "$SC_PREPARED/snapshot-real-state.py" take "$SC_RUN/after-debug.json"
python3 "$SC_PREPARED/snapshot-real-state.py" compare "$SC_RUN/before-debug.json" "$SC_RUN/after-debug.json" > "$SC_RUN/real-state-diff.json"
```

必须分别记录各命令 exit code、测试数量、跳过数量及具体失败。快照检查偏好目录新增/删除和根 mtime，`com.apple.dt.xctest.tool.plist` 的 mtime/大小/inode/键集合，非 Apple 缓存新增条目与缓存根 mtime，以及 `StorageCleanerMac*`（另含旧 `com.local.StorageCleanerMac*`）应用数据树的 mtime/结构。它只记录标准域键名，不导出键值。遇到不可读项返回 BLOCKED，不会把读取失败当成零变化。前后相同不能排除“写后删除/恢复”，因此差异归因或强证明还须同窗口文件系统 trace。

并发会话归因：主会话可在另一个已获系统权限的终端运行 `sudo fs_usage -w -f filesys > "$SC_RUN/fs-usage.log" 2>&1`，覆盖 XCTest 开始至结束后的同步窗口；只停止自己启动的 trace。用 `rg 'StorageCleanerMac|com.apple.dt.xctest.tool|Library/Preferences|Library/Caches' "$SC_RUN/fs-usage.log"` 找到目标路径，按时间、进程名和 PID 对齐测试日志。对真实路径的 write/rename/unlink/mkdir 事件逐条归因；其他已运行应用需有其 PID/事件证据，不能只凭“可能是别的会话”排除。`cfprefsd` 是代理写进程，单看到它不能证明是哪个客户端；若无法归因，在主会话协调其他写入会话后，逐个定向测试重复同一快照/trace，再判定。不要为验收擅自退出用户应用或清理残留。

守卫反证（已编译的守卫读取临时 Tests 副本；违规语句永不编译/执行）：

```bash
for SC_CASE in standard-write suite-init default-parameter cf-write cf-sync scan-store live-cache live-appdata fan-default energy-gaps auxiliary-history live-analysis; do
  SC_COPY="$SC_RUN/counterproof-$SC_CASE"
  python3 "$SC_PREPARED/make-guard-counterproof.py" "$SC_CASE" "$SC_COPY"
  STORAGE_CLEANER_TEST_SOURCE_ROOT="$SC_COPY/Tests" swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --filter 'TestPreferenceHygieneTests.testTestSourcesUseTemporaryDomainsAndDoNotPersistStandardDefaults' > "$SC_RUN/counterproof-$SC_CASE.log" 2>&1
  SC_EXIT=$?
  test "$SC_EXIT" -ne 0 || { echo "守卫漏报：$SC_CASE"; break; }
  # 每份日志还必须确认：指定 XCTest 实际运行，并在植入文件上报告对应卫生违规。
done
```

不能把编译失败、零测试或启动失败当成反证通过。`STORAGE_CLEANER_TEST_SOURCE_ROOT` 仅影响 Tests 源码枚举，生产无测试开关。另有 `testGuardFindsAnInjectedViolationInATemporarySourceCopy` 自动检查复制前零违规、复制后恰好一处标准域写入。

完整门禁仍由主会话执行：

```bash
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT="$SC_SCRATCH/verify" script/verify.sh 2>&1 | tee "$SC_RUN/verify.log"
```

## 5. 每项红 / 绿 / 反证做法

所有待运行；旧复核日志提供原污染和临时根拒绝的历史证据，不能替代本版本验证。不要重新运行会写真实路径的旧基线来制造红测。行为变异仅在主会话新建的临时包副本上做（复制 Package.swift / Package.resolved / Sources / Tests / Resources / docs / script；不复制 `.git`、不改本 worktree），每个变异独立 scratch，跑完按 RULES 清除该构建产物并留日志。

| 修复 | 红 / 反证（安全变异） | 绿 |
|---|---|---|
| 能耗、功耗、菜单偏好 | 副本工厂把能耗文件名改成 `wrong-energy.json`、功耗文件名改成 `wrong-power.json`，分别运行 `TestDataIsolationTests.testScanStoreFactoryUsesTemporaryEnergyPowerHistoryAndPreferences`；应因目标文件缺失/历史不符失败。把 preferences 改成工厂另一个临时域也应使菜单偏好断言失败，所有写入仍在临时目录 | 原工厂：功耗读到夹具、菜单设置进指定域、能耗 flush 后值为 `10/60 Wh` |
| 采样间隙、Battery 标准域 | 上述守卫 `energy-gaps` / `fan-default` / `standard-write` 副本反证；行为副本在采样间隙重开时使用另一个 TestPreferenceDomain，应无法读到前一域的 interval | ChartContinuityTests、SystemEnergy 两类、BatteryPowerModeChangeTests 及临时域 round-trip；真实标准 plist 零变化 |
| N13 家目录边界 | 副本中撤掉 `CleanupSafetyTests.testMoveToTrashReturnsExactSystemResultingURL` 的 `homeDirectory: testRoot`；仍保留临时夹具，应在到达 mover 前拒绝并使原成功断言变红。撤掉 SystemUtility 相关文件测试的 home 注入应使精确候选数量/成功恢复断言变红 | 原 15 类全部成功/拒绝/身份断言，33 处夹具不出临时目录 |
| 系统别名与恢复 | 副本中将 PathSafety 的物理根推导换回 `lexicalPath(path)`；`TestDataIsolationTests.testInjectedHomeKeepsItsBoundaryAndRejectsUserSymlinks` 应失败。只撤掉恢复 openDirectory 的别名转换，RecordedCleanupRecovery / RecordedTrashRecovery 成功还原应变红 | 系统别名可用；用户链接、越界、替换、冲突继续拒绝；OperationFileLockTests 不回退 |
| 额外迁移/重复结果夹具 | 副本中分别撤掉 ExternalMigrationReceiptTests 的 `homeDirectory: fixture.root`、IndependentFeatureWorkspaceStoreTests 的 `userHomeURL: fixture.root`；运行对应成功迁移/选择测试应变红，仍只操作临时输入 | 保留复制核验、恢复、选择/重新加载语义；FileAnalysisTrash 系列使用临时 home |
| 三处只读 live 环境 | 在临时 Tests 副本中把相应调用的环境换成默认 `.live`，用只读源差异确认本修复会捕获该回退；不要运行该变体去读取真实 Library。正常版定向运行结合 fs_usage，确认不再从三处调用读真实资源库 | IndependentFeatureWorkspaceStoreTests / StorageTreemapLayoutTests 状态保持断言，临时环境注入源码读回 |
| 守卫各绕过 | 12 类 `make-guard-counterproof.py` 副本必须使实际守卫 XCTest 报错；纯评论/源码字符串/临时相对 Library 路径则保持通过 | TestPreferenceHygieneTests 全类 + 原 Tests 扫描 |
| 生产默认值 | 在临时包副本中把任一新 root 默认改为 `URL(fileURLWithPath: "/Users/fixture")` 或 `.shared` 改为独立内存 gaps，**仅运行两个生产默认源码契约**，应失败；不要执行变体产品动作 | TestDataIsolationTests 两个默认契约和 ExternalMigrationReceiptTests 生产调用契约 |

## 6. 静态证据、补丁与剩余验证

本会话静态步骤：`python3 <scratch>/prepared/run-static-checks.py`、`git diff --check`、分组补丁的 `git apply --reverse --check <scratch>/prepared/all.patch`。结果、exit code 与数量由 `prepared/static-checks.json` / `prepared/source-audit.json` 保存。Swift 类型检查、严格并发、XCTest（含反证）、真实目录快照、Release/Debug 门禁、签名可选集成均 **NOT RUN**；测试执行数 0。

`prepared/` 分组顺序：

1. `01-production-injection`：生产依赖/根参数与系统别名边界；默认值保留。
2. `02-test-factories`：临时文件系统、ScanStore 工厂、严格临时偏好域。
3. `03-isolated-test-callers`：108 个构造点、N13 及补充夹具迁移、标准域与 live 环境修复。
4. `04-hygiene-guards`：强化守卫、临时副本反证、默认值/隔离行为契约。
5. `05-handoff`：本交接。

`manifest.json` 锁定基线、分支、各最终文件 SHA-256、组顺序及准备产物 SHA-256。`commit-prepared.py` 默认只检查；主会话完成验证与独立复核后以 `--commit` 逐组提交。它不运行测试、不合并、不 push；基线、文件、产物或暂存区不匹配会停止，不替用户回滚。中途失败需由主会话检查已完成组，不盲目重跑。

JEV：已发现 `mcp__jev__jev_decide` 并尝试方案判断，但工具返回 `MCP tool call requires approval, but approval policy is never`，状态 **BLOCKED**；没有获得或引用其判断，没有更换模型或绕过审批。

剩余边界：

- 必须由主会话编译，重点核对新增默认参数的调用、MainActor 与 Sendable，以及系统别名在本机 Foundation 下的实际表现。静态词法检查不是完整 Swift 数据流证明；运行快照/trace 是验收必需项。
- `SCM_SIGNED_UNINSTALL_FIXTURE` 原有显式签名夹具要求保留；未配置时仍按原测试跳过。配置后本批只读 manifest 原件，所有修改在临时副本。主会话应额外启用该夹具验证 1 个 metadata helper 修复，不创建/修改真实应用。
- `STORAGE_CLEANER_RC_TRASH_INTEGRATION` 原有编译条件保留；其系统 trashItem 验证使用独立可丢弃 APFS 卷，并原有断言禁止个人 home 卷。没有将这类真实系统集成伪装为 mock，也没有新增跳过。
- 计时/显式真实只读资源探测保持原 opt-in 条件。本批没有放宽超时、减少数据量或删除失败断言。`MacBenchmarkIOTests` 对真实 Application Support 的候选路径仍是拒绝测试：不允许创建目录；若它的拒绝失效，快照应报出变化。
- 本机已存在的 `com.apple.dt.xctest.tool` 键、缓存和应用数据残留未动；合并后是否清理由主会话按用户要求另行处理。

## 7. fix1：主会话编译回传后的修正（基线 `1e74007`）

主会话已将原 `prepared/` 五组提交到 `1e740079289a2982c04b8f73582f8fe727016b93`，随后在沙箱外编译测试目标，报告 `HeavyWorkIntegrationTests.swift` 第 555、586 行找不到 `defaults`。本节及 `prepared-fix1/` 对应后续修正，不覆盖原五组交付，也不将原有静态检查视为编译通过。

修正内容：

- `HeavyWorkIntegrationTests` 的 `testCancellationWhileInitialSnapshotSaveIsBlockedNeverStartsExecutorOrRescans`、`testCancellationPersistenceFailureIsShownInsteadOfCancellationSuccess` 删除不存在的 `preferences: defaults`。两项测试没有设置或观察特定偏好；省略后由 `ScanStore.makeForTests` 创建并注入临时域，保留隔离。`testExecutionTimeQuitResumesExactBatchItemAndScansInventoryOnceAfterCompletion` 确实创建、设置并共享 `defaults`，其显式注入保留。
- `CleanupRuleScannerTests` 类加 `@MainActor`。迁移后的 `makeScanOnlyStore` 在 `MainActor.run` 内新增 `for: self`，原测试类没有 actor 隔离；统一隔离测试及其实例辅助方法，避免非 Sendable 的 XCTestCase 实例跨入该闭包。底层 `ReadOnlyCleanupScanner` 仍是独立 actor，扫描实现和取消断言不变。此项是源码复核发现的并发风险修正，尚未取得编译器验证。
- 没有新增或放宽断言，没有新增跳过或改动阈值；没有新增 `@unchecked Sendable`。本轮 13 个产品文件均保持 `1e74007` 的内容和生产默认值。

复核覆盖原 manifest 中全部 **57 个测试文件、13 个产品文件**：对完整文件做词法、作用域与导入盘点，并逐文件对照迁移差异、所属函数/类型、依赖声明和异步捕获上下文。重点包括嵌套 `Page` / `Fixture.scannedStore` 的 `testCase` 参数、卸载签名夹具的返回 tuple、持久化工厂的清理闭包、history loader 的跨 actor 传值，以及 `ScanStore` 新注入依赖在 `Task.detached` / `withLease` 中的使用。

`prepared-fix1/reviewed-files.json` 逐文件保存 SHA-256、行数、imports、工厂调用和注入变量引用；同时保存产品接口调用与真实声明的标签比较。结果：109 处工厂调用的标签/顺序无遗漏或乱序，107 处显式限定产品注入接口调用的标签/顺序匹配；未发现其他迁移引入的未定义局部引用、缺少 import 或访问级别问题。实例调用、闭包及 actor 检查属于人工源码复核，不宣称完整 Swift 类型推断或严格并发验证已通过。

新增静态作用域检查有已知错误反证：读取 **git 对象中的基线文件**，能报出原 555、586 行的两个 `defaults`；读取修正工作区时无同类命中。该检查只分析源码，不执行 XCTest、持久化偏好或产品动作；复杂表达式及完整控制流仍需编译器验证。

主会话在沙箱外继续验证：

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-2"
SC_FIX1="$SC_SCRATCH/prepared-fix1"
SC_RUN="$SC_SCRATCH/logs/fix1-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SC_RUN"
set -o pipefail
swift build --build-tests --scratch-path "$SC_SCRATCH/debug" --jobs 4 2>&1 | tee "$SC_RUN/build-tests.log"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter 'HeavyWorkIntegrationTests|CleanupRuleScannerTests|TestPreferenceHygieneTests|TestDataIsolationTests' \
  2>&1 | tee "$SC_RUN/fix1-targeted.log"
SC_FILTER="$(paste -sd '|' "$SC_SCRATCH/prepared/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/all-changed-targeted.log"
python3 "$SC_FIX1/commit-prepared.py"
# 构建、定向/全量测试、目录快照、反证及独立复核完成后，由主会话提交：
# python3 "$SC_FIX1/commit-prepared.py" --commit
```

绿灯要求：测试目标完整编译通过（含 Swift 6 严格并发），上述定向通过，再继续第 4 节全量 Debug 和真实状态前后对比。红灯证据是主会话回传的两个编译错误；反证可在临时包副本中仅恢复这两行无定义参数，再编译测试目标，必须重新报出 `cannot find 'defaults' in scope`，不要改回本 worktree。偏好守卫的临时源码副本反证仍用第 4、5 节命令。

本轮分组：`01-test-compilation`（两个测试文件），`02-fix1-handoff`（本节）。`prepared-fix1/manifest.json` 固定完整基线、分支、最终文件哈希及组序；`static-checks.json` 记录实际静态结果。补丁及提交脚本仅准备，本会话没有编译、运行测试、提交、安装或启动应用。真实状态验收仍由主会话完成，本机旧残留未触碰。

JEV 本轮调用 `mcp__jev__jev_review` 返回工具声明的 `jev-latest` / `typesafe`，结果为 `escalate`（`safe_to_apply = 0.2`，未提供文字理由，测试缺口置信度为 0）。这是对早期修正方案的低置信静态评分，不能据此宣称编译或复核通过；独立复核及编译仍待主会话执行。本轮没有沿用上一轮工具被阻止的状态作为本次调用结果。

## 8. fix2：恢复操作夹具的家目录边界，避免断言后的数组越界（基线 `92ca6f2`）

### 8.1 原因与修正范围

基线为 `92ca6f24b4c68dc16d76bb188cba57c0e05bc51d`，分支仍为 `task/r2-hygiene-2`。主会话报告 fix1 含测试目标编译通过；随后执行本交接的 61 个定向类，出现 `symbolicLinkPath`、`unsafePath`、Receipts 目录不存在，以及 `LegacyCleanupRestoreTests.testRecordsWithJournalReceiptsRestoreThroughTheJournalOnlyOnce` 的数组越界崩溃。证据保留在 scratch 的 `logs/failures-1.txt` 和 `logs/main-test-2.log`；崩溃后的类没有运行，不能将此前部分通过视为全批通过。

根因是本批把需要经过生产移动、回执和恢复路径安全检查的夹具迁入系统临时目录。产品原有检查要求实际路径位于当前用户家目录，并拒绝符号链接组件；仅注入一个临时 home 参数不能改变这些检查。回执写入被拒后没有生成 Receipts，后续恢复匹配为空；旧测试的 `XCTAssertEqual` 失败不会中断方法，继续访问 `plan.matches[0]` 就使进程崩溃。第一批交接末尾记录的 N13 回退与此相同。

本轮按主会话明确裁定修正：

1. `TestFileSystem.uniqueOperationRoot` 只生成 `~/.storage-cleaner-<用途>-<UUID>`；调用方继续创建目录并以原 `defer` / `fixture.remove()` 清理。`makeOperationHome` 为需要规则家目录结构的测试创建该根内的 `home`，以 `addTeardownBlock` 只清理本次唯一根。不会创建真实 `~/Library/Caches` 或真实偏好文件。
2. `ScanStore.makeForTests` 分开管理操作 home 与普通数据根。默认操作 home、journal、模拟 `.Trash` 和文件分析环境使用 `~/.storage-cleaner-scan-store-<UUID>/home`；调用方显式提供的隔离 home 继续透传。偏好、能耗、功耗、应用更新队列和网站更新 JSON 仍在系统临时目录，数据根的临时目录前置检查保留。工厂的签名、参数顺序及生产 initializer 不变。
3. 原 N13 **15 类的 33 处 + 1 个 metadata helper** 全部重新核对并放到隐藏家目录隔离区；同类文件分析、外置迁移、真实恢复、基准资源回执、严格路径分析和共享 ScanStore 夹具一并处理。`TrashFixture` 使用 `.storage-cleaner-file-analysis-trash-test-<UUID>`，与主会话指出的另一分支 `def2321` 前缀和位置一致，没有拣入该分支的其他功能改动。
4. 防止根目录迁移带走普通持久化数据：`FileAnalysisTrashStoreTests` 的一处、`ExternalMigrationReceiptTests` 的两处偏好改用独立 `TestPreferenceDomain.make(for:)`；重复结果 `result.json` 和 MSeries `history.json` 使用独立系统临时根。`TestPreferenceDomain` 本轮无改动，个人 home 下的 suite 例外没有恢复。用于卸载归属的容器 metadata / 模型 preference plist 是待操作文件，放在隔离 home 的 `Library` 内；不是实际 UserDefaults 域。
5. 撤销本批对 **PathSafety、DiskScanner、ExclusiveRecoveryMove** 加入的系统别名兼容逻辑，恢复 `9e53489` 对应检查函数/根比较/`openat(O_NOFOLLOW)` 的实现。原有生产默认 home 和本批默认值保持不变的依赖注入仍保留；没有新增产品参数、测试目录识别、全局开关或路径检查后门。`CleanupStoreFollowUpTests` 同时删除原来清掉 `hasSymbolicLinkComponent` 的测试文件系统替身，直接使用 `FoundationReadOnlyFileSystem`。
6. 对实际产物先 `XCTUnwrap` 再使用：`LegacyCleanupRestoreTests` 的 matches / legacy records / report items；`InterruptedOperationReconcileTests`、`RecordedTrashRecoveryTests`、`UninstallExecutionTests` 的回执；`UninstallStoreWiringTests` 的第二条操作报告；`CleanupExecutionSafetyTests` 的计划项/回执/请求；`CleanupSafetyTests` 的失败项；`IndependentFeatureWorkspaceStoreTests` 的扫描结果。保留原成功、失败、计数与恢复次数断言，异常前提只使当前测试失败，不再对空数组取下标。固定的非空模型数组及由循环条件保证范围的下标未作无关改写。

本轮实际改动 3 个产品文件、27 个测试文件和本交接。重新盘点原 manifest 的全部 70 个 Swift 文件及其迁移块，并补查共享 TrashFixture 的两个调用文件：`reviewed-files.json` 覆盖 **59 个测试文件、13 个产品文件**。`fixture-locations.json` 保存各迁移块、当前行号、SHA-256 和下述类级位置。

### 8.2 每个受影响测试类的最终夹具位置

记 `H(p)` 为本次唯一的 `~/.storage-cleaner-p-<UUID>`，`T` 为系统临时目录中的本次独占目录；“工厂”表示默认操作目录为 `H(scan-store)/home`（其中含 `receipts`、`.Trash` 和文件分析环境），普通 JSON/偏好仍在 `T`。每一行均只清理自己的随机目录；原有 opt-in 和跳过条件不变。这里列出 **47 个受影响类**，包括通过共用工厂/TrashFixture 间接受影响的类。

| 测试类 | 工厂调用数 | 夹具位置 |
|---|---:|---|
| `AppUpdateCoordinatorTests` | 3 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `AppUpdatePresentationIntegrationTests` | 8 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `ApplicationUpdateRelaunchTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `CleanupExecutionSafetyTests` | 5 | 工厂；H(cleanupquarantine)、H(cleanuprestoreswap)、H(journalfixture)；无磁盘动作的内存模型路径保留 /tmp；ScanStore 通用隔离另列。 |
| `CleanupRuleScannerTests` | 3 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `CleanupSafetyTests` | 1 | 工厂；H(storagecleanersymlinktests)、H(storagecleanerrestoretests)、H(trash-summary)；恢复和模拟 .Trash 均在其内部。 |
| `CleanupStoreFollowUpTests` | 1 | 工厂；H(store-follow-up)/home；H(store-follow-up)/Journal；该隔离 home 中的模拟废纸篓和卸载夹具。 |
| `ConceptLandingNativeLayoutRegressionTests` | 3 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `ControlPaletteTests` | 3 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `DebugAppUpdatePresentationFixtureTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `DebugSmartScanSessionFixtureTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `ExternalMigrationReceiptTests` | 0 | H(migrationreceipt)/{Source,External,Trash,Receipts}；偏好改为独立 T 域，纯展示夹具仍在 T。 |
| `FileAnalysisTrashProtectedScopeTests` | 0 | 复用 TrashFixture 的 H(file-analysis-trash-test)。 |
| `FileAnalysisTrashStoreTests` | 0 | 复用 TrashFixture 的 H(file-analysis-trash-test)；偏好独立 T 域。 |
| `FileAnalysisTrashTests` | 0 | H(file-analysis-trash-test)/{Analyzed,Trash,Receipts}。 |
| `HeavyWorkIntegrationTests` | 11 | 工厂；H(storagecleanerheavyworkjournal)；其余 ScanStore 使用通用隔离。 |
| `IndependentFeatureWorkspaceStoreTests` | 2 | 工厂；重复文件在 H(duplicateresult)，result.json 独立 T；两处分析环境在 H(operation)/home。 |
| `InterruptedOperationReconcileTests` | 2 | 工厂；H(storagecleanerreconcilefixture)/{trash,receipts} 和根内源文件；两处 ScanStore 使用通用隔离。 |
| `LegacyCleanupRestoreTests` | 0 | H(storagecleanerlegacyrestorefixture)/{trash,receipts} 和根内源文件。 |
| `MSeriesCoreKernelTests` | 0 | 两处 H(storagecleanerfixture)；资源回执在根内 receipts；history.json 独立 T。 |
| `MSeriesResourceReceiptTests` | 0 | 两处 H(storagecleanerresourcefixture)，内核资源和 receipts 均在根内。 |
| `MemoryQuitConfirmationTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `MemorySelectionSummaryTests` | 13 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `MenuBarSimplePanelQuitTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `MiniWindowLiveReadingRetentionTests` | 3 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `MiniWindowMemoryQuitHeaderLayoutTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `MiniWindowMemoryQuitSelectionTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `MiniWindowPhase2ReviewTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `RecordedCleanupRecoveryTests` | 0 | H(storagecleanerrecoveryfixture)/{trash,receipts} 和根内源文件。 |
| `RecordedTrashRecoveryTests` | 0 | H(uninstall-denial)；另外三处 H(storagecleanerfixture)，模拟废纸篓、staging 和 receipts 在根内。 |
| `SafeCleanupLayoutTests` | 2 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `ScanStorePerformanceTests` | 9 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `SmartScanHistoryTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `StartupItemsDashboardContractTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `StartupScanningTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `StorageMapAnalysisEquivalenceTests` | 0 | LateWorker 在 H(lateworker)；另外三个未迁移的纯只读分析夹具保留 /private/tmp 中随机目录。 |
| `StorageMapIndexEditingTests` | 0 | EditingTree 在 H(indexediting)。 |
| `StorageTreemapLayoutTests` | 0 | 分析环境在 H(operation)/home；原有五个纯只读布局/分析夹具保留 /private/tmp 中随机目录。 |
| `SystemMonitorServiceTests` | 1 | 工厂；原有普通数据/纯模型夹具不迁移。 |
| `SystemUtilitySafetyTests` | 26 | 工厂；五处 H(storagecleanerfixture)；迁移夹具 H(migration)；三处注入 home 为 H(operation)/home，包含 Library/Caches、Library/Preferences 模型文件。其他纯解析/只读临时输入仍在 T。 |
| `TestDataIsolationTests` | 1 | 工厂；边界/链接/分析使用 H(operation)/home；能耗、功耗、偏好及 home 外拒绝对照使用 T。 |
| `UninstallAuthorizationTests` | 0 | H(scm-uninstalllock)、H(scm-uninstallauthorization)，模拟 trash 和 receipts 在根内。 |
| `UninstallExecutionTests` | 0 | H(scm-uninstall)，模拟移动目标和 journal 在根内。 |
| `UninstallExperienceTests` | 0 | 三处 H(operation)/home；Library/Caches 模型、签名 app/container 副本与 residual-trash 在内部。 |
| `UninstallOwnershipTests` | 0 | 两处 H(scm-ownership)；签名夹具副本 H(operation)/home，原 manifest 对象只读。 |
| `UninstallRetryResultTests` | 0 | H(scm-uninstallretry)、H(scm-uninstallreason)，模拟 trash 和 receipts 在根内。 |
| `UninstallStoreWiringTests` | 1 | 工厂；H(scm-uninstallstore)，ScanStore 显式传同一个根、receipts、fixture-trash。 |

`CleanupRuleScannerTests` 的纯扫描临时家目录、`CleanupExecutionSafetyTests` 的内存 metadata/mover 模型地址，以及原有 `/private/tmp` 物理目录内的只读分析/布局夹具均保留：这些输入没有真实移动、回执写入或恢复，产品也无需为其接受系统别名。这里的物理 `/private/tmp` 与别名 `/tmp` 不混用。原有系统临时目录中的源码守卫副本、解析、只读安装清单、假脚本输出不迁移。自动盘点有 52 处操作根/操作 home 调用和 6 处普通 `makeHome` 调用；数量用于对照，不是运行时零污染证明。

### 8.3 旧断言调整与生产安全契约

- `FileAnalysisTrashStoreTests.testTheAppMovesWithTheLiveJournalAndTheRealTrash`：旧 `XCTAssertFalse(creation.contains("trashEnvironment:"))` 改为断言准确转发 `trashEnvironment: fileAnalysisTrashEnvironment`，并新增断言 `ScanStore` 默认 `.live`。理由是 D48 / N26 已授权环境注入；此处需要锁住生产默认与传递关系，不能继续禁止注入。原 `LargeFilesStore` 默认 `.live`、live journal 和真实 Trash 实现契约全部保留。
- `TestDataIsolationTests.testInjectedHomeKeepsItsBoundaryAndRejectsUserSymlinks`：被操作的隐藏目录现在应处于生产 home 边界内，原否定断言改为肯定，并另以普通数据 `T` 保留 home 外拒绝断言；增加隐藏目录前缀、父目录和 `/home` 结构断言。用户链接和不同注入根之间的拒绝、目标内容不变断言保留。
- `testStorageAnalysisAcceptsSystemAliasesAndRejectsUserLinkRoots` 更名为 `testStorageAnalysisAcceptsIsolatedHomeAndRejectsUserLinkRoots`，输入改用隐藏隔离 home；分析结果与用户链接拒绝断言保留。接受系统别名不再是本批目标，旧反证作废。
- 新增 `testProductionPathGuardsKeepTheirOriginalSymlinkChecks`，锁住逐级符号链接检查、两个原始扫描根比较及恢复目录 `O_NOFOLLOW`，同时拒绝再次在这三个位置引入系统别名转换。第 2 节列出的全部生产默认值没有变化，原两个默认值源码契约继续保留。
- 其余断言只把下标换成先解包的同一个元素；没有删断言、放宽数量/精度/超时阈值或增加跳过。

### 8.4 主会话重跑命令与红 / 绿 / 反证

本轮仅准备源码和补丁，**没有执行 Swift 编译、XCTest、运行反证或真实目录快照**。主会话应先完整编译，再跑此前崩溃与其相邻回执类，之后重新执行全部 61 个类；不能只补跑上次未到达的类。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-2"
SC_FIX2="$SC_SCRATCH/prepared-fix2"
SC_RUN="$SC_SCRATCH/logs/fix2-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SC_RUN"
set -o pipefail
swift build --build-tests --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-tests.log"
# 只有编译成功才继续。先检查崩溃和路径拒绝链。
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter 'LegacyCleanupRestoreTests|InterruptedOperationReconcileTests|FileAnalysisTrashTests|FileAnalysisTrashStoreTests|FileAnalysisTrashProtectedScopeTests|RecordedCleanupRecoveryTests|RecordedTrashRecoveryTests|UninstallStoreWiringTests|TestDataIsolationTests|TestPreferenceHygieneTests' \
  2>&1 | tee "$SC_RUN/receipt-regressions.log"
SC_FILTER="$(paste -sd '|' "$SC_FIX2/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/all-61-targeted.log"
```

`prepared-fix2/targeted-classes.txt` 与原 61 类清单相同，包含全部 47 个直接/间接受影响类及原有卫生/默认值/只读安全回归。Debug 编译条件排除的 Release 类仍由原 Release 门禁覆盖，已有 opt-in 的签名卸载/完整 Core18 条件不变。

定向全部通过后，按第 4 节目录快照和进程 trace 方法重新执行全量 Debug：先构建，快照运行前状态，再在测试运行窗口内采集 `fs_usage` 和 PID 时间关系，最后保存运行后快照。命令核心如下，快照/归因的详细步骤沿用第 4 节：

```bash
python3 "$SC_SCRATCH/prepared/snapshot-real-state.py" take "$SC_RUN/before.json"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/full-debug.log"
sleep 3
python3 "$SC_SCRATCH/prepared/snapshot-real-state.py" take "$SC_RUN/after.json"
python3 "$SC_SCRATCH/prepared/snapshot-real-state.py" compare \
  "$SC_RUN/before.json" "$SC_RUN/after.json" > "$SC_RUN/state-diff.json"
python3 "$SC_FIX2/commit-prepared.py"
# 只有主会话完成构建、测试、反证、快照和独立复核后，才执行：
# python3 "$SC_FIX2/commit-prepared.py" --commit
```

真实 `Library/Preferences`、非 Apple 缓存项与本应用 Application Support 的验收条件不变；新建且清理的 `~/.storage-cleaner-*` 是本次明确授权的操作夹具，不属于真实 Library。不要清理本机旧残留，也不要为消除快照差异删除其他会话文件。若其他应用同期写入，按进程与时间归因后单列证据；不能仅凭路径名推断属于测试。

| 修复 | 红 / 安全反证（仅临时包副本） | 绿灯要求 |
|---|---|---|
| 操作夹具路径、Receipts | 红证据使用 `failures-1.txt` / `main-test-2.log`。反证仅将副本中 Legacy 的 fixture 根改回 `TestFileSystem.uniqueRoot("StorageCleanerLegacyRestoreFixture")`，运行 `LegacyCleanupRestoreTests`；必须出现回执/匹配失败，且通过 XCTUnwrap 结束测试，不能发生数组越界进程崩溃。可单独同样改 TrashFixture 检查路径拒绝；不要放宽产品校验 | Legacy、Interrupted、FileAnalysisTrash 三类及恢复/卸载/资源回执类原成功与拒绝断言全部通过；回执由真实 journal 生成，不预造 Receipts 掩盖写入拒绝 |
| 共享工厂与普通数据分离 | 副本仅将 `TestFileSystem.makeOperationHome` 的根改成 `uniqueRoot(purpose)`，只运行 `TestDataIsolationTests.testInjectedHomeKeepsItsBoundaryAndRejectsUserSymlinks`；真实 home/隐藏前缀断言必须失败。原能耗/功耗反证仍按第 5 节，写入始终局限独立临时根 | TestDataIsolation 全类、109 工厂调用涉及类通过，偏好与普通 JSON 实际仍在 T，操作 home 与 journal 在 H |
| 数组越界 | 上述 Legacy 临时根反证同时验证前提失败后不会再 fatal error；不得把零测试、编译失败或进程启动失败算作通过。其他回执类用原失败分支核对报告解包 | 断言失败只结束对应 XCTest 方法；正常路径仍精确检查结果数量、恢复次数和持久化内容 |
| 生产默认 / 路径安全 | 仅在临时 Sources 副本中恢复 `92ca6f2` 被撤回的别名代码，运行 `TestDataIsolationTests.testProductionPathGuardsKeepTheirOriginalSymlinkChecks` 这个源码契约，必须失败；不运行该变体的文件操作。默认 `.live` 及根默认的反证继续使用源码契约 | 三项路径安全检查恢复原实现；两个默认值契约、live 环境传递契约、用户链接/替换/冲突拒绝回归全部通过 |
| 偏好守卫 | 第 4 节 12 类临时 Tests 源码变体命令继续有效；不得把 home 夹具加入偏好白名单 | `TestPreferenceHygieneTests` 实际执行通过；标准域/真实偏好快照没有测试引入的持久写 |

### 8.5 静态结果、补丁和剩余限制

`prepared-fix2/` 按组准备：

1. `01-production-path-guards`：三个产品文件撤销别名兼容，恢复原路径检查。
2. `02-operation-fixtures`：测试工厂、夹具根、普通数据分离、空数组解包和对应契约。
3. `03-fix2-handoff`：本节、逐类位置和主会话命令。

`manifest.json` 固定完整基线、分支、31 个最终文件 SHA-256、组顺序和产物哈希；`all.patch` 为三组完整差异。`commit-prepared.py` 默认只读检查，不提交；`--commit` 只供主会话验证后逐组提交。本会话不修改 `.git`。旧 `prepared/` 与 `prepared-fix1/` 不覆盖。

实际静态检查结果保存在 `static-checks.json`：Tests 290 个源码的偏好盘点零违规；109 处 ScanStore 工厂和 108 处显式产品接口参数标签/顺序检查无问题；原 70 文件迁移块及 52 个操作根调用均有位置清单；全部 47 个受影响类均在 61 类清单中；三处产品安全实现与原始基线对照；补丁在 scratch 基线副本按组三次应用后与工作区字节相同，工作区反向 `--check` 通过。上述均为静态证据，不等价于 Swift 类型检查、XCTest 通过或本机零污染。

JEV 本轮实际调用 `mcp__jev__jev_review`（工具返回 `jev-latest` / `typesafe`，输入未截断），审阅关键完整 diff 和其余改动摘要，结果为 `escalate`、`safe_to_apply = 0.11`，未提供文字理由；原始评分保存在 `jev-review.json`。没有据此声称获批或通过验证；保持主会话构建、运行及独立复核分工。

剩余验证：fix2 完整编译/严格并发、定向 61 类、全量 Debug、运行反证、目录快照与进程归因、原有 opt-in 集成均待主会话执行。没有已知未迁移的本批操作夹具；不宣称静态检查能证明所有动态路径都安全。没有删除旧残留、触碰真实应用、安装、启动应用、硬件设置、提交或 push。

## 9. fix3：默认写操作拒绝、守卫作用域与夹具失败清理

### 9.1 基线、复核意见和验证边界

基线为 `6d4e351b8439df603f16429cef08395f452ccc54`（`task/r2-hygiene-2`）。主会话已报告 fix2 的 61 类、1053 个测试、0 失败；这不是本会话对 fix3 的运行结果。依据 `review/review-1.md` 的 P1、P2-2 至 P2-5 实施本次修改。所有修改在本 worktree；**没有修改任何生产 Sources，没有构建、执行 Swift/XCTest、提交或改动真实用户残留**。

本轮交付 `prepared-fix3/`。只做源码静态检查和 scratch 内补丁应用检查；严格并发、定向测试、反证和真实状态快照由主会话执行。

### 9.2 改动与理由

| 复核项 | 最终改法 |
|---|---|
| P1：测试工厂遗漏操作时仍接入真实写入 | 新增 `TestOperationFactory`。两个只读扫描默认保留原实现；`moveToTrash`、`emptyTrash`、`restoreFromTrash`、`optimizeMemory`、`runHomebrewUpgrade` 五个可抛错入口记录后抛错；非抛错的 `prepareOneClickUpdate` 记录并返回未执行。卸载原生移动和授权移动均拒绝，授权请求的预检也记录。记录器受锁保护，不捕获 XCTestCase；每个公共工厂在 teardown 断言记录为空，迟到调用继续报告 XCTest 失败。 |
| P1：其他默认操作链 | ScanStore 测试工厂的 SafeCleanup mover/deleter、文件分析 mover、恢复元数据入口、内存/清理归属应用退出、启动项命令、更新执行/退出/重新打开、网站打开也接入拒绝实现。没有返回真实 mover 的默认回落。接口本身不抛错的退出/打开回调返回未执行并由零调用断言失败；恢复服务没有 mover 参数，以拒绝元数据读取阻止进入 rename。偏好、普通 JSON 和隔离回执的预期写入继续使用各自夹具目录。 |
| P1：部分 mock 与成功流程 | HeavyWorkIntegration、SmartScanHistory、CleanupStoreFollowUp 中的部分 Operations 全部通过 `TestOperationFactory.scanOperations(...)`，没有省略字段回落 live 的 `.init(scan: ...)`。CleanupStoreFollowUp 和 UninstallStoreWiring 显式注入用于自有根的恢复服务；前者显式提供只接受自身 `.Trash` 的删除器。`SystemUtilitySafetyTests.testScanStoreBlocksTrashActionsDuringMainScanPreparation` 同时检查拒绝记录为空；业务拦截回归时，默认操作只报错，不执行真实删除。 |
| P2-2：工厂例外与参数 | 工厂例外必须有唯一 ScanStore 构造，逐项校验 25 个隔离依赖标签及其值，包含 preferences、samplingGaps、能耗/功耗 URL、各写操作、journal/home/trash、历史与启动恢复入口。拒绝必需注入的字面量 nil，以及 standard/shared/live。`makeForTests` 覆盖参数也传播别名并检查这些 live 值；部分 Operations 构造必须走安全工厂。构造识别涵盖显式 Type/Type.init、带类型声明/后续赋值的 `.init`、直接返回和已知参数标签中的 `.init`。 |
| P2-3：真实 Library 数据流 | 纳入 userDomainMask 的 cachesDirectory、applicationSupportDirectory、libraryDirectory、preferencePanesDirectory、applicationScriptsDirectory、autosavedInformationDirectory，`url(..., create: true)`，真实 home 的连续 appendingPathComponent、派生变量、字符串路径，以及已知生产数据 URL。检查创建、写文件、移动、复制/链接目标、删除、文件写句柄和登记删除等写入位置；能耗/功耗持久 store 也不能接收真实 Library URL。读取地址与列目录可以保留。 |
| P2-4：别名作用域 | 新增仅供 Tests 使用的 `TestSourceFacts`，按函数/闭包/类型及嵌套花括号范围处理声明、形参、捕获、遮蔽、同一词法链上的重新赋值和已知实例属性。一个函数只读 standard、另一个函数同名变量写临时域不再互相污染。保留原语言 argumentDomain 的逐文件、定数量内存覆盖白名单。 |
| P2-5：创建/删除失败 | `TestFileSystem.makeHome` / `makeOperationHome` 在首次变更前登记清理，创建失败删除自有根并重新抛错；不再 preconditionFailure。`ScanStore.makeForTests` 改为 throws；所有 109 个调用点及转接 helper 传播 try/throws。直接创建根的测试提前登记清理；13 个 throwing fixture 初始化块用 do/catch 回收其唯一根。`TestFileSystem.remove` 只忽略不存在，其他错误 XCTFail；相关 defer/remove/teardown 的静默 try? 改为错误报告。 |

生产默认契约增加 `TestDataIsolationTests.testProductionWriteOperationDefaultsKeepTheirOriginalImplementations`：锁定生产 ScanStore 的 `.init()` / `.live`、Operations 六个原写操作实现和卸载 native/helper 默认组合。原根路径、默认偏好、能耗/功耗与符号链接安全契约保留；本轮所有生产文件的工作区差异为空。

`TestOperationFactoryTests` 检查遗漏的移动/删除/恢复/内存/Homebrew/打开操作确实拒绝，显式注入某一成功操作不会启用其他未注入入口。`TestFixtureLifecycleTests` 检查部分创建失败保留原错误且立即清根、删除失败确实发出 XCTest issue。最后一项使用严格的 `XCTExpectFailure` 检验错误报告；不是跳过测试或把产品失败当作成功。

夹具位置沿用第 8.3 节：文件操作仍在 `~/.storage-cleaner-<用途>-<UUID>`，需要 home 结构时使用其 `home` 子目录；偏好/普通 JSON 仍在系统临时目录。新增失败创建反证使用 `~/.storage-cleaner-failed-initialization-<UUID>/home` 或临时根，并注册清理；拒绝操作的 URL 只生成随机临时地址，不创建文件。新增 startup undo JSON 使用该 ScanStore 的临时 dataRoot。

### 9.3 旧断言与精确例外

- 没有删除原业务断言、改数量/精度/超时阈值，或新增跳过条件。已有 XCTest 方法名及所属类型清单保持完整；部分签名新增 throws，使初始化错误由 XCTest 接收。
- 原 `testGuardRejectsRealLibraryPathsButAllowsTemporaryHomeRelativePaths` 的真实 home 派生样例增加写入语句，再要求拒绝；单纯读取地址改为允许。这依据本轮明确裁定 P2-3“在实际写入／夹具创建处判断”，不是放行真实写入。真实 `~/Library/Caches` / Preferences 和本应用数据目录的原字面量规则保持。
- Sparkle 的真实 Preferences 文件名只读对比继续允许，不再需要用整文件派生路径计数豁免。MacBenchmarkIO 的只读拒绝测试仅保留一处清理兜底例外：精确文件、`testSystemDiskManagerRejectsNonBenchmarkApplicationSupportRoot` 方法、`forbiddenParent` 参数，以及 `applicationSupport.appendingPathComponent("StorageCleanerMacTests-\(UUID().uuidString)", ...)` 初始化表达式同时匹配，最多一次。其他函数、参数、路径或该方法内新增 create/write 都拒绝。该兜底也改为报告删除错误。
- 原三个数据目录字符串白名单和语言 argumentDomain 定数量白名单未扩大。新增反证包括丢失任一必要工厂标签、直接/别名 live 覆盖、推断 init、分段 Library 写入、跨函数与闭包遮蔽、捕获标准域，以及篡改只读拒绝例外。

### 9.4 主会话编译、定向类和快照

以下命令**本会话均未执行**。先在沙箱外编译；任何失败应回传本会话，不把编译失败、零测试或测试进程崩溃算作反证成功。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-2"
SC_FIX3="$SC_SCRATCH/prepared-fix3"
SC_RUN="$SC_SCRATCH/logs/fix3-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SC_RUN"
set -o pipefail
swift build --build-tests --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-tests.log"
# 仅在编译成功后继续，先检查新增支持层及本次 P1 入口。
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter 'TestPreferenceHygieneTests|TestOperationFactoryTests|TestFixtureLifecycleTests|TestDataIsolationTests|SystemUtilitySafetyTests|HeavyWorkIntegrationTests|CleanupStoreFollowUpTests|UninstallStoreWiringTests|MacBenchmarkIOTests' \
  2>&1 | tee "$SC_RUN/fix3-focus.log"
SC_FILTER="$(paste -sd '|' "$SC_FIX3/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/all-64-targeted.log"
```

`targeted-classes.txt` 保留原 61 类，新增 `TestOperationFactoryTests`、`TestFixtureLifecycleTests`、`MacBenchmarkIOTests`，共 64 类，包含所有本轮修改类和共享夹具消费者。原 61 类不因 fix2 已通过而省略。新增默认拒绝可能发现以前没有明确 mock 的成功操作；应给该测试补隔离实现，不得把缺省改回 live 或删掉 teardown 断言。

定向及反证全部通过后，按第 4 节执行完整 Debug 测试前后快照、测试进程/子进程的 fs_usage 归因；继续使用 `prepared/snapshot-real-state.py`。真实 Preferences 新增项及 xctest plist 时间/键、非 Apple Caches 新增项、本应用与同前缀 Application Support 修改时间，仍应在测试窗口内零变化。其他会话的变更单独用 PID、父子关系和时间证据归因。不要清理已有残留。

### 9.5 红、绿、反证命令

| 修复 | 红证据与反证 | 绿灯要求 |
|---|---|---|
| 默认写操作 | 静态红证据为 review-1 的 `.init()` / `.live` 默认。严禁为了做红灯恢复 live emptyTrash。用下面 `unexpected-write` 副本只调用当前拒绝实现并接住错误，teardown 仍必须令 1 个 XCTest 失败 | 操作拒绝测试、SystemUtility 的业务拦截、成功清理/卸载/恢复测试全部通过，默认记录为空 |
| 工厂标签、别名、推断 init | 21 份惰性源码副本中，18 个拒绝样例必须让源码守卫失败，3 个允许样例必须通过；不编译、不执行这些违规文本 | 全仓守卫及所有新增拒绝/允许反证通过 |
| Library 来源与作用域 | 惰性副本包含目录 API、分段拼接、闭包捕获、跨函数同名变量和闭包遮蔽；新增 XCTest 还覆盖六类目录、写入位置及精确拒绝例外的反例 | 真实 Library 写入被拦；临时家目录写入及只读真实目录均保持允许 |
| 初始化失败与删除错误 | `missing-failure-cleanup` 仅删副本 helper 的失败清理语句；三个“抛错后根不存在”测试必须失败，注册的 teardown/defer 仍回收本次根。删除错误报告由严格 XCTExpectFailure 检查，若吞错，该测试失败 | 无 fatal error；原错误交给 XCTest；根已清理；删除错误实际报告 |
| 生产行为 | 新增及原有 TestDataIsolation 源码契约，配合 `git diff 6d4e351 -- Sources` 为空；不运行生产写操作来证明默认值 | 原默认值及原安全检查均未变 |

先生成并运行惰性源码反证；运行的是主 worktree 已编译的守卫，只让它读取不同的 Tests 文本：

```bash
SC_SOURCE_CASES="$SC_SCRATCH/fix3-source-counterproof-$(date +%Y%m%d-%H%M%S)"
python3 "$SC_FIX3/source-counterproofs.py" "$SC_SOURCE_CASES"
python3 "$SC_FIX3/run-source-counterproofs.py" "$SC_SOURCE_CASES/cases.json" \
  --build "$SC_SCRATCH/debug" --logs "$SC_RUN/source-counterproofs"
```

runner 对每个样例检查实际执行 1 个指定 XCTest、对应 passed/failed 行及退出码，保存独立日志和 `summary.json`。不能把不含 XCTest 断言失败的非零退出视为成功。

两个运行期反证分别使用新的 scratch 包副本，由准备脚本从完整基线导出并应用 fix3 补丁，不修改原 worktree 或 git index。每个副本准备独立构建根；按 RULES 从指定离线依赖缓存复制 checkouts/repositories/artifacts/workspace-state.json：

```bash
SC_COUNTER_COPY="$SC_SCRATCH/fix3-denial-copy-$(date +%Y%m%d-%H%M%S)"
SC_COUNTER_BUILD="$SC_SCRATCH/fix3-denial-build-$(date +%Y%m%d-%H%M%S)"
python3 "$SC_FIX3/runtime-counterproofs.py" unexpected-write "$SC_COUNTER_COPY"
mkdir -p "$SC_COUNTER_BUILD"
for entry in checkouts repositories artifacts workspace-state.json; do
  cp -R "$HOME/Developer/.sc-build/r2-u1-preselect/debug/$entry" "$SC_COUNTER_BUILD/"
done
# 预期测试失败；确认日志是指定方法的断言失败，不是编译或启动失败。
if swift test --package-path "$SC_COUNTER_COPY" --scratch-path "$SC_COUNTER_BUILD" --jobs 4 \
  --filter UnexpectedDefaultWriteCounterproofTests 2>&1 | tee "$SC_RUN/default-write-counterproof.log"; then
  printf '反证失败：意外写操作没有导致测试失败\n'
fi
rg 'Test Case.*testUnexpectedWriteIsReportedByTeardown.*failed' "$SC_RUN/default-write-counterproof.log"
rg '未注入的写操作|Executed 1 test' "$SC_RUN/default-write-counterproof.log"
```

然后使用新的目录，以同样离线依赖复制步骤运行清理反证：

```bash
SC_CLEANUP_COPY="$SC_SCRATCH/fix3-cleanup-copy-$(date +%Y%m%d-%H%M%S)"
SC_CLEANUP_BUILD="$SC_SCRATCH/fix3-cleanup-build-$(date +%Y%m%d-%H%M%S)"
python3 "$SC_FIX3/runtime-counterproofs.py" missing-failure-cleanup "$SC_CLEANUP_COPY"
mkdir -p "$SC_CLEANUP_BUILD"
for entry in checkouts repositories artifacts workspace-state.json; do
  cp -R "$HOME/Developer/.sc-build/r2-u1-preselect/debug/$entry" "$SC_CLEANUP_BUILD/"
done
if swift test --package-path "$SC_CLEANUP_COPY" --scratch-path "$SC_CLEANUP_BUILD" --jobs 4 \
  --filter TestFixtureLifecycleTests 2>&1 | tee "$SC_RUN/cleanup-counterproof.log"; then
  printf '反证失败：移除失败清理后测试未报错\n'
fi
rg 'Test Case.*testDataHomeCreationFailureRemovesPartialRootAndThrows.*failed' "$SC_RUN/cleanup-counterproof.log"
rg 'Test Case.*testOperationHomeCreationFailureRemovesPartialRootAndThrows.*failed' "$SC_RUN/cleanup-counterproof.log"
rg 'Test Case.*testThrowingFixtureInitializationPreservesTheOriginalErrorAndRemovesItsRoot.*failed' "$SC_RUN/cleanup-counterproof.log"
```

反证完成后按 RULES 删除本轮新建的包副本与构建目录，只留日志和 prepared 证据；不处理本机旧残留或其他会话的目录。

### 9.6 静态交付与待验证项

补丁分三组：`01-safe-operations-and-fixtures`（安全操作、初始化错误传播、夹具清理及调用点），`02-source-hygiene-guard`（有作用域的数据流、规则和反证），`03-fix3-handoff`（本节）。验证对象是全部补丁组成的最终工作区；主会话验证后按组提交，不要求中间组单独构建。

`manifest.json` 固定基线、分支、各最终文件 SHA-256、组顺序和产物哈希。`commit-prepared.py` 默认只读验证；主会话完成编译、64 类、反证、全量快照及独立复核后，才使用 `--commit`。原 prepared、fix1、fix2 目录保持不变。

```bash
python3 "$SC_FIX3/commit-prepared.py"          # 默认只读核对，不提交
# 主会话完成全部验证与复核后：
# python3 "$SC_FIX3/commit-prepared.py" --commit
```

实际静态结果见 `static-checks.json`、`source-audit.json`、`call-sites.json`、`reviewed-files.json`：293 个 Swift 测试源的 Python 词法盘点零违规，119 条反例/允许样例的静态结果符合预期（`source-counterexamples.json`）；109 个工厂调用参数标签/顺序和 try 已核对；原测试方法及其所属类型保留；原 57 测试/13 产品文件、共享夹具消费者和本轮新增文件的同类检查共 76 个 Swift 文件有最终哈希记录；生产源码差异为空。补丁应用检查记录在 static-checks 的 patch_validation 项。这些检查不替代 Swift 6 编译器或 XCTest。

本轮实际调用 JEV `mcp__jev__jev_review`，返回 `jev-latest` / `typesafe`，输入未截断；关键工厂/夹具补丁得到 `escalate`，`safe_to_apply = 0.28`，没有文字理由。原始结果保存在 `jev-review.json`；没有将其描述为通过复核或获准合并。

剩余验证：Swift 6 编译与严格并发、64 类定向、运行反证、完整 Debug、真实状态快照与进程归因、独立复核，全部待主会话执行。没有已知未处理的本轮五项意见；源码守卫是词法防回归检查，不证明任意反射、跨函数返回值或运行时拼接的安全性，真实状态运行验收仍不可省略。

## 10. fix4：风扇旁路、来源证明与回执收尾（2026-10-08）

### 10.1 基线、范围与证据边界

本节对应 `review-2.md` 的全部五项意见，基线为 `9bdf35639942c743effb2ad3ccd84089c88caf3c`，分支 `task/r2-hygiene-2`。基线已经包含主会话在 `TestOperationFactoryTests` 的 `FileIdentity` 调用补上的 `entryKind: .regularFile, creationTimeNanoseconds: 3`，本轮保留它。本批明确拥有 `Sources/StorageCleanerMac/Stores/ScanStore.swift`，生产改动只允许实例注入点及测试可等待的任务收尾钩子。

新会话接续中断前的 12 个改动文件，没有重做它们；最终静态核对另修正 `CleanupRuleScannerTests` 的临时根命名与新登记规则的兼容问题，并追加本交接；主会话第一轮反馈后另同步登录项源码契约，fix4 三组共 15 个文件，交付目录为 `~/Developer/.sc-build/r2-hygiene-2/prepared-fix4/`。Codex 沙箱中只完成源码核对、Python AST 解析、补丁应用及哈希验证；没有构建、执行 XCTest 或反证、暂存、提交、安装、启动应用或请求硬件写入。首版失败及修正见第 10.8 节；修正后的主会话实际结果已为 **PASS：67 类 1107 项、跳过 10、0 失败；61 源码／7 运行期反证全部符合预期；完整 Debug 3723 项、跳过 24、0 失败**。真实状态快照的剩余写入经主会话归因为已安装 Beta 自身。证据路径及本次合并准备见第 10.9 节；合并后新增适配尚未构建或运行，状态为 **NOT RUN**，不复用合并前的通过数字。

### 10.2 每项修改、理由与生产边界

**P1-1：实例级风扇入口。** `ScanStore` 增加 `@MainActor` 的 `fanControlProvider`，生产默认仍为 `{ FanControlCoordinator.shared }`，通过 `private lazy var fanControlCoordinator` 缓存。原来刷新遥测的 `process(snapshot:)` 及启动项管理的 `manageStartupItem(plan)` 两处共享单例调用都经过该实例入口。保留首次使用才创建控制器、两个入口沿用同一生产单例、原参数和调用顺序，不在 store 初始化时提前创建 live 单例。原 FanControlCoordinator、标准域默认值、启动项安全拒绝以及生产生命周期逻辑未修改。

`TestScanStoreFactory` 必须注入 provider；缺省闭包调用 `TestOperationFactory.fanControl(defaults:)`。该控制器只接收 `TestPreferenceDomain` 的临时偏好，提供非 nil 的拒绝 request sender，记录每个请求为 `fanControl.<operation>` 后抛错；legacy 卸载、service 注册也记录并拒绝，状态提供器为 `.notRegistered`。现有 coordinator 仅在 sender 为 nil 时安装真实生命周期观察者，因此这条测试路径不安装观察者。沿用现有 teardown 的“未注入写操作为零”断言。新增运行期测试实际调用两次 `refreshMenuBarLiveStatus()`，等待真实 CPU／网络只读刷新，检查 provider 惰性创建、缓存一次和零意外调用；没有跳过刷新来绕开旁路。源码守卫要求工厂标签包含 provider，且禁止测试可执行源码中直接出现 `FanControlCoordinator.shared`（注释和字符串不计）。

**P2-1：非空来源与本测试根的所有权。** `TestSourceFacts` 记录 nil、可选注解／参数、relay、`try?`／可选链等来源；必要工厂依赖不能只带标签却把可能 nil 的值传入生产回落，必须有明确非可选安全回落。测试工厂的 `cleanReportLoader` 改为 `cleanReportLoader ?? { [] }`，避免显式 nil 透传到生产 loader。其他原有隔离缺省保留。

`TestFileSystem` 增加按 `ObjectIdentifier(testCase)` 登记的根集合，只接纳 HOME 的直接子目录 `.storage-cleaner-<用途>-<UUID>` 或系统临时目录的直接子目录 `StorageCleanerMac-Tests-<用途>-<UUID>`；登记在 teardown 中撤销。`requireOwned` 验证 file URL、词法边界、当前测试登记和现存祖先无用户符号链接；`requireOwnedData` 另要求临时偏好根；操作根须为 HOME 隐藏夹具。journal 验证 directory，trash environment 验证 home/appData/trash/journal。未来尚不存在的 JSON／receipts 叶节点允许创建。只在测试帮助层复用现有 `OperationFileLock.systemAliasResolvedPath` 处理平台 `/var`、`/tmp` 别名；未改变产品 PathSafety 或文件锁检查。

工厂对 `dataRoot`、`operationHome`、journal、power history URL、trash environment、trash URL 逐一验证，因此覆盖参数不能凭“位于 HOME／temp”或“带 UUID”绕过当前测试登记。源码守卫同时要求实际工厂调用中的这些路径有 `requireOwned` 证明，并拒绝 caller 的已知真实 home、`.Trash` 和真实 journal 来源。新测试拒绝真实路径及未登记根，允许登记根的未创建叶节点并拒绝符号链接逃逸；真实 URL 只交给拒绝验证函数，不传给 live store 或写操作。

最终核对所有 `registerCleanup` 调用点时发现，`CleanupRuleScannerTests.makeFixtureHome` 原用 `StorageCleanerCleanupFixture-<UUID>`，不符合新登记规则，会新增测试失败。仅将两行手工临时 URL 换为现有 `TestFileSystem.uniqueRoot("CleanupFixture")`；仍在相同系统临时目录、仍唯一 UUID、仍先登记再创建，测试方法／路径结构／业务断言不变。其类已在原 64 类中，无需增加定向类数。

**P2-2：分支、成员和括号别名。** 赋值关联到可见声明；保守合并同一函数／闭包执行边界内分支退出后的可能来源，嵌套条件亦保留危险来源。明确的后续无条件安全赋值可以覆盖此前来源。`self.<属性>` 独立解析为成员声明，写接收器支持一层或多层括号。保留跨函数同名局部、闭包参数遮蔽和分支内新声明的允许语义，避免把另一函数中的危险赋值污染安全局部。

**P2-3：Library 常量组件。** 解析 `appendingPathComponent` 的常量字符串及常量别名；分支可能产生不同字符串时不冒充确定安全组件。真实根下组件未知且进入 `Data.write`、创建、复制、移动、删除、`TestFileSystem.remove` 等原有写位置时拒绝，要求隔离依据。只读目录查询仍允许，已隔离根的未知组件仍允许。此项仅增强测试源码守卫，未改变产品扫描或路径检查。

**P2-4：等待回执链结束再删根。** `ScanStore` 按 UUID 保留八类原有回执／操作 worker：刷新、启动协调、详情读取、记录恢复、单项 trash、批量 trash、关联应用清理、最近清理恢复。每个 worker 的原有主体保留，只加登记和 defer 移除。刷新原有 defer 在移除本 task 之前启动排队刷新，因此等待钩子继续看到新 worker。`waitForOperationReportTasksForTesting(cancelPending:)` 先等六个可继续产出回执任务的原任务（卸载准备／执行、清理执行／恢复、重复项清理／恢复），再循环等全部登记 worker；await worker 也覆盖它内部 `.value` 等待的 detached 物理读取。`cancelPending` 仅由测试收尾主动调用，不是生产的新取消策略。

工厂最后登记 async teardown，使其在先登记的偏好及夹具删除之前运行。`UninstallStoreWiringTests` 把同步 defer 删除改成最先登记的 teardown，正常恢复后显式 await 钩子并检查 `!isLoadingOperationReports`；失败／超时路径最后登记的 teardown 先开 gate、取消并等相关任务退出。`HeavyWorkIntegrationTests` 同一最近清理恢复链也等待钩子，其 journal 改为登记清理；相关 trash/bulk/多 owner gate 全部在失败 teardown 开放。`CleanupStoreFollowUpTests` 的 gated mover 同样先开放再等待。其他通过工厂创建的 store 由统一 async teardown 收尾。新增 `OperationReportTaskLifecycleTests` 用两个阶段的 detached read gate 证明当前读取和排队刷新都不能被提前返回，并单独覆盖“取消仍须等待物理读取”。没有固定 sleep、重试删除或容忍残留；`TestFileSystem.remove` 的严格报错实现未改。

生产差异的逐项静态证明见 `production-equivalence.json`：生成脚本仅在内存中去掉列明的 provider、八处任务登记／移除及等待钩子，还原两处 shared 调用与 launch Task 的原排版，结果与基线 `ScanStore.swift` 文本完全相等。`git diff 9bdf356 -- Sources` 只有该文件；原 worker 主体、生产缺省、安全 guard、FanControlCoordinator、文件锁和 private API allowlist 均未改。该证明只说明源码范围，运行行为仍须主会话验证。

### 10.3 旧断言、夹具与定向清单

旧测试方法全部保留，没有删除业务断言、改数量／精度／超时阈值、加 skip 或取消严格删除失败。首版重写的旧测试支持文本为 `TestPreferenceHygieneTests.testFactoryExceptionRequiresEveryIsolationDependency` 的合成工厂：增加 checked `dataRoot`／`operationHome` 及 `fanControlProvider` 必要标签，使原“完整注入允许、缺项／live 拒绝”断言继续验证新契约，期望和断言表达式未改（D48 与本轮 review-2 的来源证明要求）。第一轮反馈后另外改写五处 URL 比较为完整标准化路径比较，并同步一处登录项调用名称契约，逐项依据见第 10.8 节；断言数量、目标、顺序、重新扫描条件保留。新增三个守卫方法、一个拒绝 fan sender 方法，以及三类共七个方法，总计仍为新增 11 个测试方法。

操作夹具仍在 HOME 的本测试隐藏 UUID 根内，纯数据与偏好仍在临时目录；真实 HOME／Trash 反例只读或作为拒绝函数输入，不创建真实位置。成功卸载、移到夹具 trash 和恢复流程保留真实隔离 mover／journal／恢复服务，未把成功业务改成缺省拒绝。

`prepared-fix4/targeted-classes.txt` 为完整 67 类清单，保留 fix3 的 64 类，新增 `TestFanControlIsolationTests`、`TestFixtureOwnershipTests`、`OperationReportTaskLifecycleTests`；原列表已包含本轮修改的 `TestPreferenceHygieneTests`、`TestOperationFactoryTests`、`CleanupStoreFollowUpTests`、`HeavyWorkIntegrationTests`、`UninstallStoreWiringTests`。没有 Views 改动。新增清单按类名称排序，脚本静态确认原 64 类未少。

### 10.4 每项红、绿与反证

下表记录 review-2 已确认的基线漏检及 fix4 的红／绿／反证做法。主会话已完成修正后的定向、全量及全部反证，实际结果见第 10.9 节；这些结果属于合并前的 fix4。源码反证仅把惰性文本交给已编译守卫读取，绝不编译或执行违规文本。运行期反证从固定基线导出新包副本、应用 all.patch 后仅修改安全拒绝／等待接线，保留清理；不恢复 live 旁路来做红灯。

| 意见 | 红证据与具体反证 | 绿灯要求 |
|---|---|---|
| P1-1 风扇单例 | 基线两处 shared 绕过工厂。源码 `fan-shared`、`fan-shared-alias`、`factory-missing-fanControlProvider` 必须让守卫失败；运行 `unexpected-fan-write`，只调用安全拒绝 sender 且接住错误，零调用 teardown 必须令指定 XCTest 失败；`missing-fan-forwarding` 只删副本 process 转发，实际 CPU／网络刷新保留，新运行期测试必须因 provider 未调用失败 | 原生产默认源码契约、两次真实只读刷新经过注入 controller、缓存一次、无意外写；TestOperationFactory sender 的记录并拒绝测试通过 |
| P2-1 来源／根 | `factory-nil-alias`、`factory-nil-relay`、`factory-optional-relay`、`factory-optional-default`、`factory-unsafe-coalescing` 和六份去掉 ownership wrapper 的反例必须失败；真实 home／trash／journal 覆盖反例必须失败；`factory-safe-optional-fallback-allowed` 必须通过 | 当前完整工厂守卫通过；TestFixtureOwnershipTests 拒绝未登记及真实根，允许登记叶节点，符号链接拒绝；实际隔离操作仍成功 |
| P2-2 别名 | branch／else／nested branch、member／member branch、parenthesized standard／alias 拒绝样例必须失败；独立函数、闭包／分支遮蔽、明确后续安全赋值允许样例必须通过 | 新旧守卫测试及全仓守卫通过，既有允许语义保留 |
| P2-3 Library | constant-library、constant-library-alias、unknown-real-component、branch-real-root、branch-constant-library 必须失败；readonly constant／unknown、isolated unknown 必须通过 | 所有写位置拒绝危险来源，只读查询和隔离写仍允许 |
| P2-4 收尾 | 基线已出现一次 teardown Cocoa 513／EPERM；`unfinished-report-join` 只删新测试正常 waiter 的 await，阻塞物理读取及排队刷新时提前返回的两个断言必须失败，所有 teardown hook／gate 保留；原 `missing-failure-cleanup` 三个根仍存在的断言仍须失败 | 两阶段读 gate、取消等待测试、卸载两测试及同链恢复通过；所有 67 类／全量测试无严格删除失败、无本轮夹具残留 |

当前源码样例计划共 **61 个：49 拒绝、12 允许**，包含原 21 个、首版 fix4 的 37 个和第一轮反馈后的 3 个参数标签／值引用／字典键样例，见 `source-case-plan.json`。运行期共 **7 个**，保留原 5 个，增加完整路径不同与失败后刷新标记遗漏两项，见 `runtime-case-plan.json`。runner 验证指定 XCTest 实际执行数、指定方法的 passed／failed 行、退出码和运行期诊断；编译失败、启动失败、零测试或只有崩溃不得充当成功反证。对于 `missing-failure-cleanup` 预期执行 4 个 TestFixtureLifecycleTests，其中指定 3 个失败，严格删除错误测试仍应通过。

### 10.5 主会话执行命令

以下保留 fix4 第一轮修正后在 9bdf356 重提和验收时使用的历史命令；主会话已完成该流程，最终三组为 `f75968c`、`d265150`、`85e3f06`。它们不是当前合并的指令：当前 HEAD 85e3f06 正与 integration 19b9b14 合并，不要撤回这三个提交，也不要在合并状态运行旧 `commit-prepared.py`。本次合并的验证命令及 83 类清单见第 10.9 节和 `prepared-merge/README.md`。以下历史命令中的构建、测试及反证均由沙箱外主会话执行；任何失败都先停止并交回修复，依赖缓存仅复制，不改源缓存。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-2"
SC_FIX4="$SC_SCRATCH/prepared-fix4"
SC_RUN="$SC_SCRATCH/logs/fix4-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SC_RUN"
set -o pipefail
python3 "$SC_FIX4/commit-prepared.py"  # 默认只读核对，尚不提交
swift build --build-tests --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-tests.log"
# 只在编译成功后继续；优先检查新支持层、恢复链和生产注入默认。
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter 'TestFanControlIsolationTests|TestFixtureOwnershipTests|OperationReportTaskLifecycleTests|TestPreferenceHygieneTests|TestOperationFactoryTests|TestFixtureLifecycleTests|TestDataIsolationTests|CleanupRuleScannerTests|StartupItemsDashboardContractTests|UninstallStoreWiringTests|HeavyWorkIntegrationTests|CleanupStoreFollowUpTests|ScanStorePerformanceTests' \
  2>&1 | tee "$SC_RUN/fix4-focus.log"
SC_FILTER="$(paste -sd '|' "$SC_FIX4/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/all-67-targeted.log"
```

接着运行全部源码反证（包括允许样例），这些源码副本绝不能交给 Swift 编译器：

```bash
SC_SOURCE_CASES="$SC_SCRATCH/fix4-source-counterproof-$(date +%Y%m%d-%H%M%S)"
python3 "$SC_FIX4/source-counterproofs.py" "$SC_SOURCE_CASES"
python3 "$SC_FIX4/run-source-counterproofs.py" "$SC_SOURCE_CASES/cases.json" \
  --build "$SC_SCRATCH/debug" --logs "$SC_RUN/source-counterproofs"
```

运行期 runner 自动创建七份新的 scratch 包及各自 build 根，从 `r2-u1-preselect/debug` 复制离线依赖；每项结束或异常时严格删除它自己创建的包与 build，只保留日志／summary 和空的父目录。不会清理 HOME 夹具、原 worktree、缓存源或其他会话目录；XCTest 本身必须完成 gate／任务收尾和夹具 teardown，无残留由主会话检查。可以用 `--offline-cache` 指定另一个已确认完整的只读缓存源。

```bash
SC_RUNTIME_CASES="$SC_SCRATCH/fix4-runtime-counterproof-$(date +%Y%m%d-%H%M%S)"
python3 "$SC_FIX4/run-runtime-counterproofs.py" "$SC_RUNTIME_CASES" \
  --logs "$SC_RUN/runtime-counterproofs"
# 定位失败时可用 --variant 单独重跑，但 output 必须是新的目录；最终仍须七项齐全。
```

源码反证完成、日志 summary 确认齐全后，只删除本次新建的惰性副本（检查路径和 cases.json，禁止泛化清理）：

```bash
python3 - "$SC_SOURCE_CASES" <<'PY'
from pathlib import Path
import shutil, sys
root = Path('/Users/developer/Developer/.sc-build/r2-hygiene-2').resolve()
path = Path(sys.argv[1]).resolve()
assert path.parent == root and path.name.startswith('fix4-source-counterproof-')
assert (path / 'cases.json').is_file()
shutil.rmtree(path)
PY
```

定向和反证全部通过后，按第 4 节继续用 `prepared/snapshot-real-state.py` 做完整 Debug 前后快照和 fs_usage 的测试 PID／子进程归因，再运行完整 Debug：

```bash
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/full-debug.log"
# 如主会话完整验收要求 Release／严格并发／项目门禁：使用本轮独占根。
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
  STORAGE_CLEANER_VERIFY_ROOT="$SC_SCRATCH/fix4-verify-$(date +%Y%m%d-%H%M%S)" \
  ./script/verify.sh 2>&1 | tee "$SC_RUN/verify.log"
```

门禁不授权安装／启动应用、修改硬件或放宽真实路径规则。记录测试计数、跳过、失败／fatal、本轮 HOME 和 temp 夹具残留、状态快照及独立复核结果；不要把其他会话／进程的修改自动算成本轮污染，也不要清理已有残留。

### 10.6 fix3 主会话结果及 EPERM 判断边界

以下为主会话提供的 **基线 HEAD 9bdf356 的历史结果**，不是 fix4 的新运行证据：64 类 1096 项，跳过 10，失败 1，失败为卸载恢复后的严格删除（`logs/main-test-5.log` 第 2436–2440 行）；夹具只剩 receipts 下两个零字节 `.lock`，该类随后单独连跑 5 次通过。21 个源码反证符合预期（18 拒绝／3 允许），两个运行期反证让指定测试失败且无残留，日志在 `logs/fix3-main-20261008-002709/`。

主会话后补的完整 Debug 为 3712 项、跳过 24、0 失败、无 fatal／残留，见 `logs/acceptance-fix3-20261008-004640/full-debug.log`。同目录真实状态 diff：`com.apple.dt.xctest.tool` 无变化、无新增偏好文件；7,997 个新缓存均为 `Library/Caches/CloudKit/com.apple.bird/…` 的 iCloud daemon 条目；`Application Support/StorageCleanerMac-Beta/` 的两份文件由运行中的已安装 Beta 写入，测试结束后继续更新；非 Beta 的 `Application Support/StorageCleanerMac/` 无变化。快照工具未自动归因所以判 FAIL。本轮不改工具；归因须结合访问 PID／父子关系、路径、时间窗口及测试后持续写入证据，不凭目录名称单独免责。看板 N27 的 ContactsUICore／XCTest 类元数据初始化归因由主会话处理，本批不修改。

源码可以确认恢复完成与独立刷新之间有竞态窗口；等待钩子覆盖这条链，修正后的 fix4 主会话定向及全量未复现 EPERM，结果见第 10.9 节。这不证明首轮 EPERM 的具体系统机制，也不替代本次合并后的验证。零字节锁文件在释放后按设计保留，存在不证明锁仍持有，也不能称为 flock 阻止删除。若后续仍有 Cocoa 513／EPERM，继续采集实际失败子路径、删除 syscall、同期访问 PID 与权限／ACL／文件标志，不吞错、不重试删除、不容忍残留。

### 10.7 交付、静态结果与未解决项

补丁按三组交付：`01-isolation-and-task-lifecycle`（12 个生产／测试支持／恢复调用点、临时根兼容及登录项契约文件），`02-source-provenance-guard`（2 个守卫文件），`03-fix4-handoff`（本交接）。主会话验证对象为三组组成的最终工作区，不要求中间提交单独构建。各提交说明末尾固定为本轮要求的 `Generated-By: Codex (gpt-6.1-sol)` 和 Claude Opus 5.5 协作者两行。

`manifest.json` 固定完整基线、分支、组顺序、15 个最终文件 SHA-256 和 prepared 产物 SHA-256；`all.patch` 包含三组。`generate-prepared.py` 只生成及检查，不执行反证脚本：Python AST 解析、旧方法／明确列明的断言改写盘点、64→67 类包含关系、计划计数、生产文本精确还原、工作区 reverse check、两份 owned `/private/tmp` 基线副本的 all.patch／按组 forward apply 与最终文件哈希等检查见 `static-checks.json`、`source-audit.json`、`production-equivalence.json`。临时补丁验证副本在检查后删除。这些是已提交 fix4 的历史交付检查，不等同 Swift 6 编译或行为验证；随后主会话已完成编译、67 类、61／7 反证和完整 Debug，均通过，证据见第 10.9 节。失败的第一轮证据仍独立保存于 `main-session-r1.json`。本次合并不重新生成三组补丁，不修改旧 manifest 基线，另交付 `prepared-merge/`。

```bash
python3 "$SC_FIX4/commit-prepared.py"  # 默认只读：基线／分支／空 index／文件集合／哈希／反向补丁检查
# 主会话完成构建、67 类、61 源码反证、7 运行期反证、全量／快照与独立复核之后才执行：
# python3 "$SC_FIX4/commit-prepared.py" --commit
```

JEV 在本轮接续会话曾尝试 `mcp__jev__jev_decide` 评估惰性 provider 与提前单例注入，工具返回 `MCP tool call requires approval, but approval policy is never`，没有实际模型调用、模型标识或判断；记录于 `jev-review.json`，不代表 JEV 已复核或认可。审批阻断来自工具，不影响已授权的源码和静态准备。

review-2 的五项意见已经过主会话运行验收和三组提交，独立 Claude 复核结论为“修后可合并”；其中“修”是第 10.9 节列出的合并适配，不是尚未通过的原 fix4 测试。当前仍待主会话构建、83 类、完整 Debug／真实状态快照验证最终合并内容，并完成 git add 和合并提交。词法守卫不证明任意跨函数返回值、反射或运行时构造的安全性；根所有权与现存祖先检查是测试帮助层约束，不替代产品安全检查。复核新列的 P2-A～E 按用户要求留给后续批，不在本轮修改。

### 10.8 主会话第一轮结果与修复

主会话在沙箱外把首版三组提交为 `2a1bfa1`、`4a63e0e`、`6143deb`，HEAD 为 `6143deb8f045cbaa083609db72e08408d951fa48`，提交 trailer 为 `gpt-6.1-sol`。编译通过，67 类执行 1107 项、跳过 10，**6 个测试共 9 处断言失败**。本次读取并核对 `~/Developer/.sc-build/r2-hygiene-2/fix4/failures-r1.txt` 的九行错误及 `logs/main-test-6.log` 第 2481／2483 行的汇总；错误站点、日志位置和失败文件哈希保存于 `prepared-fix4/main-session-r1.json`。这些是修正前的运行证据；本次修正未编译、未运行测试或反证，没有执行撤回／提交。

**一、目录 URL 比较的五处失败。** 首版把 CleanupRuleScanner 的手工临时根改为 `uniqueRoot` 后，URL 带目录提示；同一文件系统路径的 URL 可能分别带／不带末尾斜杠，`.standardizedFileURL` 仍保留 URL 表示差异。按本轮明确授权，五处改为 `PathSafety.lexicalPath(url.path)` 的完整路径等值比较，没有只比较 basename／后缀，没有丢掉数组顺序或数量：

| 测试及首轮行号 | 保留的断言含义 |
|---|---|
| `testRootCandidateScopeEmitsOneStableSelectableRootAndBuildsPlan`，774 | 候选来源必须等于完整 `.cache` 目标路径 |
| 同上，775 | allowedRoot 必须等于完整 fixture Home 路径 |
| 同上，788 | plan 来源数组必须按原顺序精确等于一个 `.cache` 路径 |
| `testDeepStorageAnalyzerCandidateCountsDataBeyondEightLevels`，817 | 候选必须是完整 `Library/Application Support/DeepApp` 路径；原深度、大小、风险、完整度及选择断言保留 |
| `testLowerBoundMeasurementIsVisibleButCannotEnterPlan`，1334 | plan 来源数组精确等于一个完整 `Library/Caches/candidate` 路径；原 lowerBound／选择／计数断言保留 |

依据为本轮用户允许“按标准化路径比较”，而非改变产品决定或放宽安全范围。帮助层命名仍符合当前测试登记规则，产品扫描和 PathSafety 实现未修改。红证据为首轮上述五条失败；绿灯为三个原测试和整类通过；安全反证 `wrong-cleanup-candidate-root` 只把一条比较的期望改为同一夹具 Home 下 `.cache-other`，不创建该路径，指定原测试必须因完整路径不同失败，证明标准化仍校验目标一致性。

**二、登录项契约同步，保留两个注入入口。** 首轮 `StartupItemsDashboardContractTests.testAdministratorFailureKeepsPostMutationRescanEnabled` 第 317 行仍查找 shared 的旧拼写。P1-1 的最低范围是遥测注入；本轮选择继续让管理员登录项也经过同一实例 controller，避免测试走该入口时重新创建带标准域／生命周期观察者的真实单例。生产 provider 仍返回原 shared，`manageStartupItem` 的实现和安全拒绝不变；没有增加新的生产行为。

只把契约字符串中的 `FanControlCoordinator.shared.manageStartupItem(plan)` 改为 `fanControlCoordinator.manageStartupItem(plan)`，仍要求它前一行是 `shouldRefresh = true`，仍验证两个 catch 都保留 `shouldRefresh = shouldRefresh || recoveryRecordID != nil`，仍要求 defer 中 `if shouldRefresh` 调用 `refreshStartupItems(priority: .utility)`。没有删掉“失败后仍允许重新扫描”的任何条件。红证据为首轮契约失败；绿灯为原契约、整类及 TestFanControlIsolationTests 通过；`missing-startup-postfailure-rescan` 只在副本删掉管理员调用前的刷新标记，原源码契约必须失败。反证测试只读源码，不实际创建 store 或执行管理员操作。

**三、网站流程安全回落的来源误报。** 工厂本来就是 `websiteUpdateWorkflow ?? WebsiteUpdateWorkflow(...)`，显式构造非可选 actor，queue store 在 checked `dataRoot/website-updates.json`，opener 记录并拒绝打开；没有传 nil 给生产回落。词法 alias 扫描把 `WebsiteUpdateQueue(store: ...)` 的 `store:` 标签误识别成外围 `let store = ScanStore(...)` 引用，从后者整段初始化混入 live／可选等来源。此处选择修守卫的词法识别，不豁免 website 标签，不移除 nil 检查，不把工厂换回 live，也不以泛化“构造器都安全”掩盖危险值。

`argumentLabelLocations` 只识别圆括号内、紧跟 `(` 或逗号的 `<标识符>:` 标签，在 alias 合并时跳过标签；值部分仍逐词解析，方括号字典键仍是引用。既有网站非空隔离构造保留，必要标签及五个 nil／optional 反例全部保留。现有 `testFactoryRequiresNonnilProvenanceAndCheckedOwnership` 增加三条成对检查：`Box(store: isolated)` 与外层 standard store 同名允许，`Box(store: store)` 拒绝，`Box(values: [store: isolated])` 的危险字典键也拒绝。三份样例同步加入源码反证；完整实际工厂允许样例和括号安全回落仍须通过。红证据为首轮该方法两处及全仓方法一处误报；绿灯为完整 TestPreferenceHygieneTests 与全部源码反证符合预期。

第一轮反馈后的修正相对 HEAD 6143deb 仅改四个测试文件：`CleanupRuleScannerTests`、`StartupItemsDashboardContractTests`、`TestSourceFacts`、`TestPreferenceHygieneTests`，另更新本交接和 scratch 交付脚本／计划。**该次修正没有新增生产改动**；相对 9bdf356 的完整生产证明仍为第 10.2 节所列注入和任务收尾。测试方法数不变；随后主会话完整定向实际为 67 类 1107 项、跳过 10、0 失败，源码 61 份（49 拒绝／12 允许）及运行期 7 项全部符合预期，完整 Debug 3723 项、跳过 24、0 失败。对应日志见第 10.9 节，不能仅以首轮六个失败方法的复跑代替完整清单。

主会话已完成撤回旧三组到 9bdf356、保留修正内容后按第 10.5 节构建，执行完整 67 类、61／7 反证和全量／快照验收，再提交新的三组。`commit-prepared.py` 的历史基线仍严格为 9bdf356，不自动 reset，也不用于本次合并。生成器只允许 BASE 或当时已知三提交链作为读取来源，始终导出 BASE→最终文件的补丁，manifest 记下 `prepared_from_head` 和撤回前置条件。原第一轮 prepared 包保留在 `prepared-fix4-before-r1-6143deb/`，不覆盖其证据。

该次修正的编译、定向、反证、全量及状态验收已由主会话回传，不能再写为 NOT RUN；当前未执行的是第 10.9 节的合并后适配验证。实现会话的 JEV 工具审批阻断记录沿用首版；独立复核员后来另有实际 JEV 判断，见 `review-3.md` 第 7 节，不混同为 Codex 的模型调用。严格删除和 EPERM 的后续判断仍按第 10.6 节的证据边界执行。

### 10.9 合并准备：review-3 第 6 节的适配

**合并状态。** 主会话已经在本 worktree 执行 `git merge --no-ff integration/2.0.0-beta`，HEAD 为 `85e3f067da5d0a5158db29db809fa11c528af1cf`，MERGE_HEAD 为 `19b9b148ed091e3f074df59ee40a2767e15b714c`。静态核对 `git diff --name-only 80d00ed 19b9b14 -- Sources Tests` 无输出，与复核模拟使用的 integration 代码一致。本轮按 `review/review-3.md` 第 6 节和 `~/Developer/.sc-build/r2-hygiene-2-review4/logs/merge-sim-resolution/` 的保存差异完成工作区适配。只写工作区和 `prepared-merge/`；没有构建、测试、反证、git add 或提交，没有改 `.git`。五个冲突文件的文本标记已全部去掉；index 仍保留主会话原来的五个 unmerged 条目，须由主会话暂存后结束合并。

**A、B：冲突及接口适配。**

| 文件 | 最终处理与保留的语义 |
|---|---|
| `ExternalDriveMigrationService.swift` | 两个公共入口同时保留 integration 的 `contentReader` 和本批的 `homeDirectory`，默认值各自不变；采用 integration 的 `inspectSource` 结构，两处调用显式传入 home，内部再传给 `isAllowedSource`；后两个私有函数不新增真实 home 默认值，不恢复旧内联检查。最终文件与复核员的 `vs-integration.diff` 逐字一致。 |
| `ControlPaletteTests.swift` | `checkFanPaletteLayout` 使用本批的 `try ScanStore.makeForTests(for: self, cleanupPreferences: defaults, cleanReportLoader: { [] })`，紧接下一行保留 integration 的 `store.menuBarAuxiliaryMonitorState.setPaused(true)`，在任何 await 前暂停。 |
| `FileAnalysisTrashTests.swift` | 保留本批 `uniqueOperationRoot("file-analysis-trash-test")`、init do/catch 回收及严格 remove；内容保留 integration 的 `Tool.app/Contents/MacOS/Tool` 和 APPL `Info.plist`。自动合并的只读卷注入、隔离 home 的 protected-link 查询等改动也完整保留，最终与保存的 `vs-batch.diff` 一致。 |
| `HeavyWorkIntegrationTests.swift` | 保留 `TestOperationFactory(for: self).scanOperations`，仅移除废弃的 `duplicateScan:` 参数；`duplicateFilesScanOperation` 中的 duplicateGate 和 owner／收尾断言保留。 |
| `RecordedTrashRecoveryTests.swift` | 四处根沿用本批 `uniqueOperationRoot`，四处 defer 使用 `TestFileSystem.remove`；最终文件与 HEAD 的本批版本一致，不恢复手写 home 根或 try? 删除。 |
| `TestOperationFactory.swift` | 删掉 `duplicateScan` 可选形参及转发，与 integration 已删除的 Operations 字段一致；注释改为“一个只读扫描入口”。六个写入口的拒绝／记录闭包和 teardown 零调用断言不变。 |

本轮唯一重新编辑的生产文件是上述 `ExternalDriveMigrationService.swift`，仅合并两边既有参数和转发；其他生产文件包括 `ScanStore.swift` 与主会话进入冲突状态时的工作区哈希一致。integration 已暂存的大量生产改动属于合并输入，本轮没有额外修改或撤销它们。没有修改生产默认值、路径检查、内容校验及调用顺序。

**C：旧源码契约的三处拼写同步，依据 D48。** `testFanLayoutFixturePausesAuxiliaryMonitoringBeforeSuspending` 现在要求 `let store = try ScanStore.makeForTests(` 在该 fixture 中恰好出现一次；完整构造行之后的下一行必须是 `setPaused(true)`；仍切出构造后的代码并要求第一个 await 之前已暂停。这三处只是把直接构造的字面量替换为隔离工厂，不删断言、不改变计数、不放宽“紧邻下一行”和“首次挂起前”的条件。D48 要求测试使用临时绝对路径偏好域，本批工厂还封闭 journal 和风扇写入口；保留 integration `210567f` 的同步暂停才能同时满足隔离和生命周期通知约束。

**D：复核报告的十条守卫违规适配。** `Audit20260919RegressionTests` 用 `uniqueOperationRoot("staging-tests")`，先 `registerCleanup` 再创建，移除吞错的 defer；两个 DesignSystemV2 测试、四个 DesignSystemV2Review 构造点都改为 `try ScanStore.makeForTests`。`memoryStore(for testCase: XCTestCase) throws` 把归属测试传给工厂，唯一调用方同步传 `self` 并 `try`，所有原断言保留。`fixtureDataPathAllowlist` 仅增加 `FileAnalysisTrashCostTests.swift: 1`，注释说明其 `/Users/fixture` 是规则模型字符串，没有文件系统写入；真实写位置检查仍执行，30 µs／200 ms 性能阈值不变。`MigrationContentFixture` 改用 `uniqueOperationRoot("content-tests").resolvingSymlinksInPath()`，创建和写入放在 do/catch 内，失败先严格回收 root 再抛原错误；正常 remove 同样用 `TestFileSystem.remove`。`MigrationVerificationReuseTests` 及其他复用该夹具的测试一并列入定向。此处“适配”是静态源码结论，不冒充合并后守卫已经运行通过。

**P2-F：规则同步。** RULES 第 3 节现在点名 `uniqueRoot`／`makeHome`、`uniqueOperationRoot`／`makeOperationHome`、`ScanStore.makeForTests`。make 帮助函数在创建前自动登记；unique 帮助函数只返回地址，夹具负责失败回收及结束清理；自建根或其子路径要覆盖传入工厂时，须先用 `registerCleanup` 登记，已有严格收尾的夹具可只 `registerOwnership`。说明 `requireOwned` 以当前 XCTestCase 为边界，及后台任务退出后再严格删除，与现有帮助层和守卫一致。

**合并前已完成的主会话运行结果。** 以下数字经本会话只读核对原日志／summary，并采用主会话提供的实际进程归因；不是本次合并代码的运行结果。

| 验证 | 实际结果与证据（路径相对本批 scratch） |
|---|---|
| 编译及 67 类定向 | PASS，1107 项、跳过 10、0 失败；`logs/main-test-7.log`。 |
| 源码反证 | PASS，61 份（49 拒绝／12 允许）全部符合预期；`logs/fix4-main-20261008-021725/source-counterproofs/summary.json`。 |
| 运行期反证 | PASS，7 项全部符合预期，均实际执行指定测试并只出现预期失败；`logs/fix4-main-20261008-021725/runtime-counterproofs/summary.json`。 |
| 完整 Debug | PASS，3723 项、跳过 24、0 失败；`logs/acceptance-fix4-20261008-023850/full-debug.log`。 |
| 真实状态快照 | 按主会话归因，仅剩已安装 Beta 自身写入；同目录 `real-state-diff.json`。没有新增偏好文件，xctest.tool 无变化；差异涉及 Beta 的能耗／指标文件及 `com.local.StorageCleanerMac.beta/fsCachedData`。原工具仍标 FAIL，因其不自动区分并发进程；不修改工具状态、不把目录名独自当作免责依据。 |
| 独立复核 | Claude 的 `review/review-3.md` 结论“修后可合并”；第 6 节模拟只完成 A、B 后，12 类 81 项通过、原 67 类 1123 项中 C／D 两个测试共四处断言失败。C、D 和本轮新增类未在该模拟中跑过，不能把模拟结果当作本轮绿灯。 |

**本轮红／绿／反证及主会话命令。** A/B 的红证据为真实五文件冲突和旧 duplicateScan 编译接口不兼容；绿灯须是最终合并结果构建、迁移／文件分析／重工作／恢复及工厂测试通过。C/D 的红证据为复核实际模拟的契约失败和十条守卫报告；绿灯须是修后的 ControlPalette、守卫、两个 DesignSystem 类、Audit 和共享迁移夹具消费者通过，并用全量快照确认真实状态未被测试写入。反证保留第 10.4 节既有 61 源码／7 运行期的实际结果；合并后可用新编译守卫重跑 61 份惰性源码。若进一步验证本轮 C，主会话只在自有源码副本把暂停行挪到第一个 await 后，该只读契约必须失败；D 的回退片段只作为惰性文本交给守卫，禁止编译直接 ScanStore 或手写真实根的违规文本。详细验证边界见 `prepared-merge/README.md`。

`prepared-merge/targeted-classes.txt` 完整保留原 67 类，加入 16 类后为 **83 类**：Audit、DesignSystem 两类、UIConsistency，以及原清单之外所有 `TrashFixture`／`MigrationContentFixture` 消费者；ControlPalette 等已在原清单中，不重复计数。README 列明全部新增类、每个文件的解决方式、沙箱外主会话命令和后续项。合并使用现有 index，不生成分组补丁或运行旧提交脚本。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-2"
SC_PREP="$SC_SCRATCH/prepared-merge"
SC_RUN="$SC_SCRATCH/logs/merge-hygiene-2-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$SC_RUN"
set -o pipefail
# debug 根须由本主会话独占；先构建成功再执行下面的测试。
swift build --build-tests --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-tests.log"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter 'ControlPaletteTests|TestPreferenceHygieneTests|TestOperationFactoryTests|DesignSystemV2Tests|DesignSystemV2ReviewTests|Audit20260919RegressionTests|GuardedMigrationReadTests|MigrationVerificationReuseTests|FileAnalysisTrashCostTests' \
  2>&1 | tee "$SC_RUN/merge-focus.log"
SC_FILTER="$(paste -sd '|' "$SC_PREP/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/all-83-targeted.log"
# 全量前后快照及 fs_usage 的 PID／子进程归因按第 4 节／README 执行。
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/full-debug.log"
```

每步成功后才继续；保留合并后实际计数，不能预填 1107、1123 或 3723。构建、83 类、全量、状态归因及无本轮夹具残留确认完成后，由主会话 git add 和合并提交。

**后续批（用户明确本轮不做）。** review-3 P2-A：其他视图／电源路径的默认真实风扇单例入口和 coordinator 生命周期观察者注入要求；P2-B：setUp／init 跨函数成员赋值来源的保守合并；P2-C：所有未隔离真实 home 写位置统一拦截，保留只读查询；P2-D：记录任务收尾等待上限及 teardown 强引用；P2-E：词法守卫全仓扫描约 4.5 倍耗时及缓存优化。它们仍未解决，不以本轮定向或历史全量通过宣称不存在。尚在途分支的合并适配继续遵循 review-3 第 6 节 E“谁后合并谁处理”，本轮不修改其他分支。
