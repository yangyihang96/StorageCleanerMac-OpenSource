# r2-small-fixes：取消测试、风扇短名及预检缓存边界

日期：2026-10-07。工作区 `/Users/developer/Developer/sc-worktrees/r2-small-fixes`，分支 `task/r2-small-fixes`，基线 `9e53489e06f6a4e08540a9e0538bb9139cc338e7`。scratch `/Users/developer/Developer/.sc-build/r2-small-fixes/`。

**交付状态：代码／测试／文档与 prepared 补丁已准备；构建、XCTest、严格并发、红绿、反证、原生界面验收、提交均 NOT RUN。** 本会话遵守 D60，不尝试沙箱内编译、测试或写入 `.git`。实际只读静态检查的命令、exit code 与文件 SHA-256 见 `prepared/static-checks.json`、`prepared/manifest.json`。没有修改 `ScanStore.swift`、`SafeCleanupExecutor.swift`、偏好卫生守卫或移动授权逻辑；没有安装、启动应用或写入硬件。

## 1. N4：取消测试缺少回调顺序约束

### 原因与证据

`batch1-foundation.md` 的门禁表明确记录：Debug 3101 项中，`testStoreCancellationWaitsForRealCompatibilitySessionShutdownBeforeLeaseRelease` 失败的是 **stopCount 0 < 1**；“负载下先释放了租约”是当时的推测，不是已观察到的产品状态。读取 `b55cd70` 与本批基线的该测试，内容相同；专属 URLProtocol 的 ownedState 及跨 reset 守卫当时已经存在，不能把本次问题说成又修了一次共享计数器串台。

旧测试只轮询到 pendingCount > 0，取消后等待 store 当前操作结束，立即读取 URLProtocol 的 stopCount。它没有为 `stopLoading()` 的测试观察、真实 `didBecomeInvalidWithError`、关闭期限三个事件建立顺序。会话失效是产品生命周期屏障，测试桩 stop 计数是另一项观察；直接读取后者假设它总已先完成，是测试的时序竞态。Apple `finishTasksAndInvalidate()` 与 `URLSessionDelegate.urlSession(_:didBecomeInvalidWithError:)` 的文档描述的是最后一个任务与 delegate 回调后的失效通知，没有给自定义 URLProtocol 的计数观察建立同等契约。

另一个独立假设也需控制：若真实失效通知晚于现有 1 s 关闭期限，服务合法返回 cleanup-pending，store 进入 `.failed` 并安装 cleanup quarantine，租约直到真实通知到达才清除；`waitUntilIdle()` 只等当前操作，不等这项独立清理。该路径不能套用“立即 cancelled、owner nil”的正常取消断言。它**不能解释历史门禁中只有 stopCount 失败**，本交接不将两者混为一个已实测根因。

本轮没有当时完整的 Foundation 回调轨迹，也未运行高负载复现，因此不能断言还原了那次内部调度。源码审计未发现需改变租约／隔离逻辑的产品竞态；修复的是测试未声明的事件顺序，产品只增加期限调度注入点，默认行为不变。主会话仍需按下述高负载步骤验证。

### 改法与确定性

- `NetworkCompatibilitySpeedTestService` 将关闭期限的排程注入为 `CompatibilityShutdownTimeoutScheduler`，默认仍是原 `DispatchQueue.global(qos: .utility).asyncAfter`。原默认 1 s、最大 2 s、非有限值及非负钳制全部保留；期限没有延长。
- 两个正常取消测试使用线程安全、可先发后等的 continuation 信号：pending 开始 → 取消 → stop 观察 → 收到关闭请求并注册期限 → 显式放行真实失效通知 → 等待操作。手动期限不会因机器负载抢先触发；真实通知仍由 URLSession 产生，不伪造 delegate 回调。通知到达后再触发晚到期限，必须无副作用。
- store 正常路径在放行通知前另断言仍为 running 且 owner 为 networkTest；放行后保留 cancelled、owner nil、stopCount ≥ pending、能取得 benchmark 租约等原断言。
- 新增 `testCancellationDeadlineQuarantinesLeaseUntilRealInvalidation`，在真实通知被扣留时显式触发同一 1 s 期限的回调，等待当前操作结束后要求 failed、owner networkTest、benchmark 被拒绝。放行真实通知，再通过既有 `waitUntilOwnerInactive` 等隔离清除，才能取得 benchmark 租约。此等待用于读回最终状态，不重跑测试或重试失败断言。
- 信号登记与状态修改均在 NSLock 保护下，continuation 在解锁后恢复；不使用阻塞 semaphore。正常路径先观察 stop，再放行通知，因此测试不再将两个独立事件的调度顺序当成产品保证。

### 旧断言处理

只把旧 `XCTAssertTrue(didStartRequest)` 的 5,000 次计时轮询改成等待 pending 信号后 `XCTAssertGreaterThan(pendingCount, 0)`；验证的仍是请求已经开始。取消结果、stopCount、租约、后续 benchmark 的所有旧断言保留。依据为本批用户明确要求用信号／可注入时钟消除测试时序假设，及 D60 的沙箱交付流程；没有改产品决定或预算。

### 红／绿／反证

1. **红（历史基线）**：主会话另备基线 worktree，在 `9e53489` 构建原测试包，使用本交接的并行压力脚本跑原 store 取消方法，保存全部运行结果。历史失败是 stopCount 0 < 1，未必每次能重现；若没有重现，报告“本次未复现”，不能称已证明原版无竞态。原基线的完整 Debug 全量也需记录结果。
2. **绿**：新旧取消方法、bounded cleanup 与 delayed invalidation 所在整个 `NetworkCompatibilitySpeedTestServiceTests` 类，Debug／Release 均执行；再并行跑正常取消与新增期限先到的方法。正常路径必须保留原断言，期限先到必须保留隔离。不能靠重跑后的绿覆盖先前失败。
3. **反证 A**：只在主会话的隔离反证 worktree 中，将服务真实通知对 `timedWaiters` 的 `resume(returning: true)` 改为 false，保留调度注入、信号与其他代码。正常取消测试的 cancelled／状态断言应失败；这是一项能编译的行为变异，不以编译错误当反证。
4. **反证 B**：只删除 `NetworkSpeedTestStore` 兼容服务 cleanup-pending 分支的 `beginCleanupQuarantine`／`monitorCleanup`，保留错误抛出。新增期限先到方法在 `await store.waitUntilIdle()` 后的 owner／benchmark 拒绝断言应失败。恢复源码字节与 prepared 哈希。

## 2. 英文长风扇名在 80 pt 中截断

### 原因与改法

旧紧凑未同步首行使用显示完整 `displayName` 的原生 Picker，并限定 80 pt。`Optical Drive Fan` 或 `.named(...)` 的长硬件名超过按钮可用宽度。扩大该列或换行会侵占开关空间和已接受的 276 pt 高度余量。

采用短按钮名＋完整菜单名：紧凑区外层使用 Menu，英文按钮固定为 `Fan \(reading.index + 1)`（与无 identity 时既有命名一致）；中文仍用既有 `displayName`。第 2 轮恢复菜单内绑定当前风扇的 Picker，完整名配 `.tag(fan.index)`，由原生单选控件提供勾选和读屏选中语义。每个菜单项、悬停提示与 `Target Fan: <完整名>` 读屏标签使用完整名称。选择仍只改变 selectedFanID／本地草稿，展开区保留原 Picker。80 pt、首行位置、同步开关及提交边界保持原实现。规范同步更新 `docs/mini-window-design.md`。

纯值映射已在第 2 轮移到不受条件编译限制的 `ControlPaletteTests.testCompactFanNamesMapShortButtonsToFullHardwareNames`：两个长英文硬件名仍分别检查完整名与 `Fan N`，中文映射仍检查保留既有 `displayName`。不创建 ScanStore，不改偏好或语言。`testLongFanNamesUseShortCompactButtonsAndFullMenuNames` 保留原布局矩阵；Debug 在隐藏 NSHostingView 中测量真实短名和菜单边界，要求完整短名落在 80 pt 菜单内，且两种同步状态的开关 maxX 与 minY 相同。语言作用域复用原布局函数，仍只有已获白名单的两处 volatile argumentDomain 写入；不改 `TestPreferenceHygieneTests`。**覆盖更正：风扇布局矩阵及辅助函数位于 `#if DEBUG || STORAGE_CLEANER_BETA`，普通 Release 不编入；只有 Debug 或显式定义 STORAGE_CLEANER_BETA 的构建编入。帧探针和 80 pt／开关几何检查另受 `#if DEBUG` 限制，只在 Debug 中运行。** 普通 Release 编入上述纯值测试及新增的暂停顺序、内嵌 Picker 源码契约；不能把普通 Release 的类过滤命令说成已执行布局矩阵。

原 ≤280 pt、两种紧凑状态各 ≤276 pt、语言、深浅色、硬件只读及窗口边界断言全部保留。`maxX` 的原生读屏切换断言实际在 `FanControlModeCardTests.testVoiceOverPressTogglesFanSyncWithoutMovingTheSwitch`，本轮不改它，主会话须同时执行。

### 红／绿／反证

1. **红**：在有新测试／探针的隔离 worktree，只把 `FanTargetPickerPresentation.buttonTitle` 恢复为 fullName。独立纯值方法 `testCompactFanNamesMapShortButtonsToFullHardwareNames` 的英文短名断言必须失败；Debug 长名布局方法的完整文本宽度／边界也应暴露溢出。保留类型和探针，不用编译失败或丢探针当反证。
2. **绿**：运行完整 `ControlPaletteTests` 和 `FanControlModeCardTests`。保存中英、深浅、同步／未同步的自然高度证据；仍须各 ≤276 pt。主会话在只读夹具中打开菜单、切换两个长名，检查选中后的短按钮、完整菜单项、悬停提示与 VoiceOver 标签；不得连接或写真实硬件。
3. **反证**：上述 fullName 变异是本项行为反证；另可把紧凑选择器还原成独占新行来反证既有高度断言。逐字节恢复后再验证正常版本。没有改写任何旧 UI 断言或阈值。

## 3. 预检原因缓存：原始意见缺失，锁定现有正确边界

### 查找结果及范围

**未找到原始描述。** 已检查指定 `r2-u1-followups-review/logs/` 的测试／探针日志，检索 P2-4、preflight、cache／boundary、缓存／边界等；`evidence-*` 内是布局／结果截图，没有独立文字报告。`evidence-r3-probe/review-issue-list-english.png` 是跳过原因展示夹具，不能当作缓存边界意见。`r3-test-T1-disabled.log:5-6` 能证明关闭原原因传递会退回 preflightNotApproved；`r3-test-head.log` 与 `r4-test-head.log` 记录正常路由通过，但未描述 P2-4 的具体边界。

依本批用户指令，**不凭示例猜改产品**。`SafeCleanupExecutor` 仍按不可变 CleanPlanID 保存最近完成预检，重新预检入口清除旧报告，有效执行取出报告；缓存只在未批准行的显示分支使用。原有 D47、D49、D52 的批准、运行应用、写入复查及移动语义均未改。

### 新增测试

`CleanupExecutionSafetyTests` 新增六个方法，使用现有内存 metadata／mover 夹具，所有“移动”只记录路径，不操作真实文件：

- `testPreflightReasonCacheDoesNotCrossImmutablePlans`：相同候选重建的新计划，未批准行不得借用旧计划原因。
- `testRepeatedPreflightUsesOnlyLatestCompletedReasons`：同一计划再次预检全 ready 时旧原因清除；新原因变成 excludedByUser 时只保留新原因。
- `testFailedPreflightClearsEarlierReasonsWithoutChangingApproval`：功能禁用、会话不符、规则版本不符三个失败入口都清除旧原因；后续有效执行只移动明确批准的那一行。
- `testCancelledPreflightClearsEarlierReasonsWithoutChangingApproval`：子任务在调用预检前确定性取消，旧原因清除、报告不批准任何项；外层执行任务没有被取消。
- `testCachedReasonsNeitherApproveMovesNorReplaceLiveRechecks`：预检时在运行的应用退出后，仅明确批准的行可以按当前状态移动；应用仍运行时，批准行也必须实时跳过。缓存原因始终不能批准另一行。
- `testRejectedApprovalRetainsReasonsForTheNextValidExecution`：空集合或计划外 UUID 被拒绝、零移动；同一未消费计划随后使用有效批准集合时仍保留预检原因。

没有改写旧断言；没有为这些测试新增偏好域或真实文件目录。并发／重入预检或其他未描述的边界仍需主会话取得复核原文后另行定界，本轮不声称修复了它们。

### 红／绿／反证

本项属于新增回归覆盖：原产品在基线上应为绿，不能编造一个基线必红的“缺陷”。红使用以下各自独立、可编译的行为变异：

1. 删除 `preflight` 入口的 `preflightReports.removeValue(forKey: plan.id)`：失败／取消后的旧原因应使对应新测试失败。
2. 把未批准行的返回固定成 `.preflightNotApproved`：原原因传递测试、最新 excluded 原因及拒绝后有效执行的新断言应失败。
3. 对明确批准行在 `skipReason` 入口直接返回 nil：运行应用仍运行时的新测试必须因移动计数／路径错误失败。
4. 删除未批准行的入口拦截：未批准路径被记录移动，应使多个新测试失败。

绿：恢复原产品，运行完整 `CleanupExecutionSafetyTests` 及 `CleanupWriteRecheckTests`；必须逐项保留移动路径、批准集合与原因断言。上述变异就是反证，各自记录 exit code／失败断言，不同时引入多个变异，不用编译失败替代行为失败。主会话执行完恢复源文件与 manifest 哈希。

## 4. 主会话验证命令与压力复现

以下命令仅供主会话在沙箱外执行，本会话未运行。依 RULES 将离线依赖复制到本批专属 scratch；不要与其他批次共用 SwiftPM 的写入目录。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-small-fixes
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
scratch=/Users/developer/Developer/.sc-build/r2-small-fixes
swift build --scratch-path "$scratch/debug" --jobs 4
swift test --scratch-path "$scratch/debug" --jobs 4 --filter 'NetworkCompatibilitySpeedTestServiceTests|ControlPaletteTests|FanControlModeCardTests|CleanupExecutionSafetyTests|CleanupWriteRecheckTests|CleanupReportSkipPresentationTests|TestPreferenceHygieneTests'
swift test -c release --scratch-path "$scratch/release" --jobs 4 --filter 'NetworkCompatibilitySpeedTestServiceTests|ControlPaletteTests|FanControlModeCardTests|CleanupExecutionSafetyTests|CleanupWriteRecheckTests|CleanupReportSkipPresentationTests|TestPreferenceHygieneTests'
swift build --scratch-path "$scratch/strict" --jobs 4 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
git diff --check
```

定向类清单：`NetworkCompatibilitySpeedTestServiceTests`、`ControlPaletteTests`、`FanControlModeCardTests`、`CleanupExecutionSafetyTests`、`CleanupWriteRecheckTests`、`CleanupReportSkipPresentationTests`、`TestPreferenceHygieneTests`。`CleanupWriteRecheckTests` 原有显式计时方法仍按原开关处理，本批没有新增 skip；不要将既有 skip 说成全执行。

并行压力：主会话先构建一个完整 Debug `.xctest` 测试包，向 `prepared/stress-cancellation.py` 传入该包的实际绝对路径。脚本直接用 xcrun xctest 启动独立测试进程，避开多份 swift test 共用 SwiftPM 写入锁；每次必须实际执行一个测试，全部 exit／失败／watchdog 都记入 JSON，不将失败当作重试丢弃。先在基线包跑旧方法，再在新包跑同方法与期限方法，各 8 进程 × 20 轮。60 s watchdog 只把卡住的独立测试进程记为失败，不改变产品关闭期限或测试断言。

```bash
python3 /Users/developer/Developer/.sc-build/r2-small-fixes/prepared/stress-cancellation.py \
  --bundle <主会话构建得到的实际Debug测试包.xctest路径> \
  --output /Users/developer/Developer/.sc-build/r2-small-fixes/stress-green \
  --workers 8 --rounds 20
python3 /Users/developer/Developer/.sc-build/r2-small-fixes/prepared/stress-cancellation.py \
  --bundle <同一新版Debug测试包.xctest路径> \
  --output /Users/developer/Developer/.sc-build/r2-small-fixes/stress-deadline \
  --method testCancellationDeadlineQuarantinesLeaseUntilRealInvalidation \
  --workers 8 --rounds 20
```

整个 verify 门禁由主会话在集成分支执行：按项目说明设置 `STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0` 与本批私有 `STORAGE_CLEANER_VERIFY_ROOT`；本批不替主会话运行门禁或安装。

## 5. 分组与剩余限制

`prepared/` 按以下顺序提供四组：

1. `01-cancellation`：关闭期限调度注入及确定性取消／隔离测试（2 文件）。
2. `02-fan-names`：紧凑菜单短名与长名／布局测试（2 文件）。
3. `03-preflight-tests`：仅预检原因边界测试（1 文件）。
4. `04-docs`：本交接及小窗规范（2 文件）。

另有 all.patch、各组 message、manifest.json、commit-prepared.py、static-checks.json、generate-prepared.py、压力脚本与 README。提交脚本只供主会话验证后运行：核对分支、完整基线、空暂存区、最终文件及准备产物哈希，然后按组仅向 index 应用补丁并提交。它不构建、不测试、不安装、不 push。

JEV：**BLOCKED**。已发现实际可调用的 `mcp__jev__jev_decide` 与其参数；工具封装标识 TypeSafe Jev，不暴露可选模型标识／模型参数。一次有界方案判断调用被拒绝：`MCP tool call requires approval, but approval policy is never`，模型请求未执行，不声称获得 JEV 判断。没有切换当前模型或擅自降级。运行环境也未暴露本 Codex 的实际模型标识，message 的 Generated-By 使用 `model-not-exposed` 并如实记录；主会话有实际 CLI 启动记录时可据证据补齐，不能据 D60 默认派工规则自行冒充具体模型。

剩余事项：主会话编译／严格并发及全部定向测试；原生菜单、VoiceOver 与高度截图；基线／新版高负载结果；四组行为反证；取回 P2-4 原始描述后的进一步定界。源码改完不等于以上事项通过，也不等于提交、复核或合并。

## 主会话验证结果（2026-10-07 21:5x）

- **提交**：Codex 四组按 `prepared/commit-prepared.py` 提交，哈希校验通过：
  - `ecc8d7e` 取消测试；
  - `dbc350c` 风扇短名；
  - `cd8eecb` 预检原因测试；
  - `f27da8c` 交接。
  - 原提交说明里的模型写的是“未暴露”，已按派工记录改为 `openai/gpt-6.1-sol`。
- **构建**：`swift build --build-tests`（scratch `~/Developer/.sc-build/r2-small-fixes/debug`，离线参数）exit 0。
- **首轮定向测试**：7 个类共 150 个，跳过 1 个，失败 2 处，都在 `testLongFanNamesUseShortCompactButtonsAndFullMenuNames`。原因是测试本身：无边框 `Menu` 的标题由 AppKit 绘制，标题上的 `layoutProbe` 永远不上报。
- **主会话修正**（`a84fab1`）：改为量菜单框（80 pt），再按 11 pt 正文字体算短名宽度并留出指示箭头空间；同时删掉视图里这个不会生效的探针。
- **复跑**：150 个，跳过 1，0 失败，exit 0。
- **压力复现**：用 `prepared/stress-cancellation.py` 跑 `testStoreCancellationWaitsForRealCompatibilitySessionShutdownBeforeLeaseRelease`，8 路并行 × 20 轮，160/160 通过，结果在 `~/Developer/.sc-build/r2-small-fixes/stress-214352/`。没有在改前基线上跑同样的压力。
- **反证**：`buttonTitle` 改回完整风扇名，`testLongFanNames…` 失败（exit 1，3 处）；还原后工作区干净。
- **预检原因**：只新增测试，没有改产品逻辑，不需要反证。
- **未运行**：Release、严格并发、原生菜单和读屏的实机核对，统一放到完整门禁和安装后实测。

## 第 2 轮（复核修复）

日期：2026-10-07。独立复核输入为 scratch 下 `review/review-1.md`，报告基线范围 `9e53489..d8cccc5`。**本轮补丁基线为当前 HEAD `d8cccc5b9ebe167b280ea7e22f98c7e658c70e3e`**，包含主会话 `a84fab1` 修正及以上验证记录。产物单独放 `prepared-r2/`，第 1 轮 `prepared/` 与历史验证结果保留。

**本轮状态：代码、测试源码、交接及分组补丁已准备；编译、XCTest、严格并发、红／绿／反证、原生界面、安装、提交均 NOT RUN，执行测试数量 0。** 上述主会话 150 项与 160 次压力结果属于第 1 轮，不能作为本轮变更后的通过证据。只读差异／补丁检查与哈希见 `prepared-r2/static-checks.json`、`manifest.json`。

### 各项改法

1. **P1 — 布局夹具电源通知旁路。** `checkFanPaletteLayout` 每次创建 `ScanStore` 后的下一行立即调用 `store.menuBarAuxiliaryMonitorState.setPaused(true)`，之后才更新快照、构建视图或 await 布局。类处于 MainActor；`BatteryPowerSourceObserver.callback` 用 MainActor Task 回调，通知不能在这两条同步语句之间经本测试让出执行。源码核对：`refreshFromPowerSourceNotification` 的第一项是 `guard !isPaused`；后台电池采样入口也检查暂停；`setPaused(true)` 取消本地采样并更新 generation；异步结果在 `canPublishLocalData` 再检查取消、generation 和暂停，通过后才进入 `recordBatterySample` 的标准域 reconcile／历史持久化。故本处暂停能阻断复核指出的通知写路径，不需要改构造器。新增 `testFanLayoutFixturePausesAuxiliaryMonitoringBeforeSuspending` 源码契约锁定该辅助函数只有一个创建点、下一行暂停、创建后的第一个 await 前已暂停。**这只是本批使用点的最小防护；不改 ScanStore.swift，不声称建立全仓测试工厂或证明其他测试全部隔离。** `r2-hygiene-2` 负责不注册通知、临时历史及通用测试工厂的系统性修复；该批可据此契约迁移本使用点，不应据本处暂停宣布系统性问题解决。
2. **P2-2 — 原生当前项标记。** `compactTargetFanMenu` 保留外层短名 Menu，内部改为 `Picker`，selection getter 为 `selectedFanID ?? reading.index`（初次展开也有当前项），setter 为 `selectedFanID = $0`，每个完整名 Text 配 `.tag(fan.index)`，使用 inline picker。中英文走同一绑定路径。新增 `testCompactFanMenuUsesBoundPickerForNativeSelection` 源码契约锁住嵌套位置、双向绑定、完整名、tag、inline 样式、短按钮和 80 pt。80 pt、禁用、悬停、完整读屏标签、两种同步状态的开关 maxX／minY 及双风扇 ≤276 pt 断言保留。实际菜单勾选、AX 选中状态仍需主会话读回，源码契约不等于原生验收。
3. **P2-3 — 信号失败出口。** `CompatibilityTestSignal.wait` 返回 Bool；每个 waiter 用独立锁保存终止结果、continuation 和 10 s 诊断 watchdog。成功信号、超时、取消只能完成一次；取消先于 continuation 登记时，登记后读回终止结果立即返回。超时／取消先 `XCTFail`（事件名和调用方 file／line），再执行失败清理并恢复等待；成功时取消 watchdog。三个取消用例所有信号等待均改为 guard，失败后返回，defer 取消 service task 或 store，并放行当前及将来的 invalidator 请求、触发已登记手动期限，避免再进入一个可能卡死的产品状态等待。成功路径仍按 pending → cancel → stop → invalidation request → deadline registration → 手动放行／手动 fire 执行原产品断言。**10 s 只报告测试事件缺失，不判断 cancelled／failed／租约正确性；产品原 1 s 期限值及先后仍由注入调度器决定。** 本轮未改服务产品源码。
4. **P2-4 — 检出跨计划缓存被误消费。** 保留 otherPlan 的计划不同、未批准原因 `.preflightNotApproved`、移动计数及获准路径断言；随后再次 execute 原 plan，仅批准原第二行，要求原第一行仍是 `.relatedAppStillRunning`，移动计数为 1。录制 mover 的最终序列必须是两个计划各自批准的第二行；路径集合只允许原第二行这一条路径。这是内存 mover 对同一夹具路径的两次记录，不移动真实文件。产品 `SafeCleanupExecutor.swift` 字节保持基线，不改缓存或授权逻辑。
5. **P2-5 — Release 覆盖口径。** 原 `checkCompactTargetFanNames` 中完整名／短名两条值断言移到独立纯值方法，用 `usesChinese` 的 true／false 遍历替代依赖布局语言作用域的检查，保留两只风扇及中英映射预期。新方法不依赖 DEBUG/BETA 夹具；源码契约同样在条件块外。布局矩阵仍在 DEBUG/BETA 条件块，几何帧探针另限 DEBUG。上文已直接更正原来“Release 保留高度矩阵”的错误表述。

### 改写的断言与等待（逐条）

- 仅移写两条值断言：`presentation.fullName == language == .english ? longNames[index] : reading.displayName` 与 `presentation.buttonTitle == language == .english ? "Fan N" : reading.displayName` 的原语义，分别改为独立纯值方法中的 `usesChinese ? reading.displayName : longNames[index]` 和 `usesChinese ? reading.displayName : "Fan N"`。检查仍覆盖两个 index 和两个语言映射分支；不再把这两条值断言限定在布局夹具构建中。
- 三个网络用例的四次无界信号 await 各改为带诊断失败清理的 Bool guard；后三个仍按原次序在列表中等待。正常路径的 pendingCount、stopCount、cancelled／failed、1 s 期限、租约、quarantine 与 benchmark 断言全部保留，没有改写数值或预期。
- 跨计划原断言全部保留，只增加原计划执行后的原因、计数、最终路径序列及路径集合断言；UI 原高度、宽度、开关位置与硬件只读断言全部保留。没有删除测试方法，没有新增 skip，没有放宽阈值。

### 红／绿／反证做法（仅交主会话执行，本轮 NOT RUN）

1. **P1 红／反证：**在隔离反证 worktree 只移除辅助函数的暂停行，单独运行 `testFanLayoutFixturePausesAuxiliaryMonitoringBeforeSuspending`，必须因相邻／等待前暂停契约失败；不运行缺少防护的布局夹具，不触发真实电源采样。恢复后源码契约与所有布局方法均应绿。系统性无真实偏好／历史写入的动态证据由 `r2-hygiene-2` 配合验证；本轮只有所述通知路径静态核对。
2. **P2-2 红／反证：**只将菜单内 Picker 改回普通 Buttons，源码契约应行为失败（能编译的变异）；恢复后 Debug 跑完整布局，保持 80 pt、两状态开关同位置、≤276 pt。主会话使用只读硬件夹具在中英菜单中选择两项并重新展开，读回恰有当前项勾选／AX 选中，确认短按钮与完整菜单名。普通 Release 只要求纯值与契约覆盖，不能计入未编译的矩阵。
3. **P2-3 红／诊断反证：**只抑制一次测试夹具 `markStopped` 的 `stopped.signal()`，保留 stop 计数及真实 URLSession 回调，运行正常取消方法；约 10 s 后应在该事件的诊断断言失败、释放 invalidator 并结束方法，不能挂至压力脚本 60 s watchdog。取消反证由主会话在临时测试中取消一个等待任务，核对返回 false、一次诊断失败、失败回调放行且方法结束；同时覆盖“先取消、后登记 continuation”。这两项预期 exit 非零，要保存失败与收尾记录，不能作为正常绿测。恢复后跑三个正常用例和压力脚本；结果先后仍只由 manual deadline 控制，不用墙钟选成功／失败分支。
4. **P2-4 红／反证：**在隔离反证 worktree 将执行器取预检缓存的 `removeValue(forKey: plan.id)` 故意改为取字典 first 的 key（仍保留条目 UUID），模拟 otherPlan 错误消费原报告。old otherPlan 断言可继续通过，但新增回到原计划的 `.relatedAppStillRunning` 断言必须失败；恢复执行器字节后完整安全测试应绿。本批不修改该产品文件。
5. **P2-5 红／反证：**只将 `buttonTitle` 改回 fullName，普通 Release 的独立纯值方法必须实际被发现且失败；恢复后 Debug 与普通 Release 均运行该方法和两个源码契约，Debug 另执行布局矩阵／帧探针。记录配置与发现的方法名，不能把类名过滤成功当成矩阵执行证据。

### 主会话定向类、分组及剩余事项

定向类仍为 `NetworkCompatibilitySpeedTestServiceTests`、`ControlPaletteTests`、`FanControlModeCardTests`、`CleanupExecutionSafetyTests`、`CleanupWriteRecheckTests`、`CleanupReportSkipPresentationTests`、`TestPreferenceHygieneTests`。Debug 和普通 Release 的命令可沿用上文，普通 Release 的布局覆盖按本节更正；另跑严格并发与全量门禁。既有计时 skip 按原开关记录。重点方法为三个取消方法、跨计划方法及本轮新增三个风扇纯值／源码契约方法。

`prepared-r2/` 保持原 prepared 格式，按 `01-cancellation`（仅网络测试）、`02-fan-names`（风扇菜单、暂停、纯值／源码契约）、`03-preflight-tests`（跨计划补强）、`04-docs`（本交接与小窗规范）交付；附 all.patch、各组 message、manifest、静态记录、生成脚本、提交脚本与压力脚本。提交说明末尾采用用户指定两行 `Generated-By: Codex (openai/gpt-6.1-sol)` 和 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`；本轮没有运行提交脚本。

JEV：**BLOCKED**。已核对当前 `mcp__jev__jev_decide` 可用标识／参数：TypeSafe Jev 工具封装，无可选模型标识或模型参数。为信号失败收尾方案发起一次有界判断，工具返回 `MCP tool call requires approval, but approval policy is never`；模型请求未执行，未取得判断，不改模型、不请求绕过权限。剩余事项为主会话编译／严格并发、全部定向测试、红绿与失败收尾反证、原生菜单／读屏和布局读回，以及 `r2-hygiene-2` 的系统性工厂修复。本轮不声称复核问题已经通过动态验证、提交或获准合并。

## 主会话验证结果（第 2 轮，2026-10-07 23:0x）

- **提交**：Codex 四组按 `prepared-r2/commit-prepared.py` 提交（`55fb2a1`、`210567f`、`c6b2fec`、`62b9d66`），模型名按派工记录改为 `openai/gpt-6.1-sol`。
- **构建与测试**：构建 exit 0。同 7 个定向类共 153 个，跳过 1 个，0 失败。
- **反证**：把紧凑风扇菜单内容改回普通按钮（复核指出的选中标记回归）→ `testCompactFanMenuUsesBoundPickerForNativeSelection` 6 处断言失败；还原后工作区干净。
- **复核意见落实情况**：
  - P1：新增布局夹具在第一次等待前暂停辅助监控，系统性修复留给 `r2-hygiene-2`；
  - P2-2：菜单内为绑定当前风扇的 `Picker`，恢复原生勾选；
  - P2-3：测试信号有 10 秒诊断看门狗；
  - P2-4：跨计划之后复查原计划；
  - P2-5：交接中 Release 覆盖口径已更正。
- **合并**：主会话验证后合并，没有再派复核。理由：五项都是复核给出的具体修法，契约测试已由反证锁定。
