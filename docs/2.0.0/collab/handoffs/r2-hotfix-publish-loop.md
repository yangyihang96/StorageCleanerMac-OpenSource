# r2-hotfix-publish-loop：D74 常驻采样需求发布闭环

日期：2026-10-11。分支 `task/r2-hotfix-publish-loop`，完整基线 `aa1abaf9de1142b3024ec28d9ebf28134e3a836e`。本批明确拥有 ScanStore。Git 元数据只读，交付本批 scratch 的 `prepared/`，未提交、合并、安装或启动真实 App。

## 根因链与证据边界

用户提供的 `~/Developer/.sc-build/r2-hotfix-publish-loop/evidence/beta-main-thread-sample.txt:4383–4397` 显示 49 个样本：

```text
NSRunLoop.flushObservers → UpdateGroup.dispatchActions
→ SubscriptionView.Subscriber.updateValue
→ MenuBarAdvancedSamplingCoordinator.body closure #3
→ ScanStore.updateMenuBarProcessConsumer → setMenuBarProcessDemand
→ Published.subscript.setter → PublishedSubject.send → ObservableObjectPublisher.send
```

1. 源码 closure #3 是 `MenuBarAdvancedStatusView.swift:1465` 的 `.onReceive(samplingContext.planChanges.removeDuplicates())`，不是 `task`、`onAppear` 或普通 `onChange`。`MenuBarSamplingPlan.swift:58–62` 使用 CurrentValueSubject，`planChanges` 每次访问重新构造去重／类型擦除链。新订阅仍会收到当前值；removeDuplicates 的前值只属于该订阅，不能阻止订阅重建后的首值重放。`testCurrentPlanReplaysOnEveryNewSubscriptionButDoesNotPublishStore` 明确验证 100 次新订阅得到 100 次回调。
2. 隐藏／暂停／睡眠计划走 `MenuBarAdvancedStatusView.swift:1470–1476`，重置首帧并调用 `updateMenuBarProcessConsumer(id, section: nil)`。可见且首帧已完成时，同一回调重新声明三级进程页面。首次出现、首帧变化、页面变化、三级可见性、暂停、睡眠、唤醒和消失回调也声明同一需求（`1433–1555`）。普通 `onChange` 本身按值变化触发；它们共享 setter，但 sample 中持续反馈的订阅回调为上面的 closure #3。
3. 基线 `ScanStore.swift:4186` 每次推进 consumer 顺序；D74 的 `setMenuBarProcessDemand` 常驻分支没有有效需求守卫，还会把相同的 pending Bool 无条件赋给 @Published。隐藏页面 `nil → .overview → false` 也发布，不要求有 CPU 三级页面或真实进程数据。
4. 协调视图观察 ScanStore；这次 objectWillChange 让 SwiftUI 重算图、重建计划订阅，再收到当前计划，返回第 2 步。`StorageCleanerMacApp.swift:282` 的 @StateObject 和 `SidebarView.swift:9` 的 @ObservedObject 共享同一 store，解释 App.body、主窗口 Sidebar 也被不断求值。它们是被连带失效的观察者，不是 sample 中反向写需求的起点。
5. `MenuBarStatusController.install:91–95` 先附加常驻上下文；`241–253` 读取恢复标志，只有恢复／显式打开才创建 `406` 的 PanelScene／MenuBarPanelSession。`MenuBarPanelSession.swift:597` 创建 NSHostingController；`1279–1312` hide 会 orderOut、分离 contentViewController，但保留 hosting controller 到 teardown（`1348`）。`MenuBarStatusController.swift:625–646` 同时把面板可见性写入计划，隐藏时声明 .overview。这些都能进入同一幂等 setter；常驻采样和已保存数据本身不创建 SwiftUI 面板。

**为什么 QA 未复现：** 全新域加 `-menuBar.restorePanelOnLaunch NO` 绕过启动恢复，未创建面板协调视图，就缺少反馈订阅；常驻采样仍可运行。真实测试版域存在 `menuBar.restorePanelOnLaunch`、`menuBar.panelMode`、`menuBar.panelSection`、`menuBar.panelFrame.geek` 和主窗口 frame／sidebar 键；本批只读并输出键名，未检查值，因此**不能证明当时恢复标志为 true、选中某页面，或确切的隐藏/可见窗口状态**。源代码和 sample 证明常驻上下文＋已挂载/保留的面板订阅足以构成闭环；具体真实偏好组合留待主会话隔离复现。隔离测试手动写合成恢复/页面标志，不复制真实偏好。

## 修复与语义

- `ScanStore.swift:4184`：声明确实变化时才更新字典与优先级。重复声明仍解析有效需求，确保暂停把需求降为 overview 后，恢复刷新时同一声明能重新生效；不会让老 consumer 的重放抢占最新页面。
- `ScanStore.swift:4200`：有效需求相同时直接返回，放在常驻和独立可见采样两分支之前。无重复发布、取消、reset、超时任务、内存任务或能量归属结束。实际需求变化保留原分支逻辑。
- `ScanStore.swift:4295`：pending/unavailable 经统一比较出口赋值。页面变化而 Bool 未变也不发布；常驻超时、样本完成、独立可见采样和演示出口复用它。保留首次无样本 pending、5 秒超时和成功样本恢复语义。
- `ScanStore.swift:4452`：相同刷新档位无发布或重复偏好写入。
- `MenuBarAuxiliaryMonitorState.swift:422–491`：同 context 附加、同 demand/paused 注册、未知/已注销 consumer 的重复注销均提前返回；updateConsumer、setPaused、setPresentationVisible 原已有比较守卫，保留。真实需求变化仍更新 primaryKinds/reconcile，未关闭 provider 或改变暂停条件。
- `MenuBarAdvancedStatusView.swift:1374`：协调视图改为 internal，并允许注入隔离 MenuBarSamplingContext，生产默认仍为 shared。回调和首帧规则保留；不靠删掉订阅来掩盖发布错误。
- `menuBarProcessDemand` 改为 private(set)，仅开放内部只读以核验优先级/暂停行为。

没有修改 `MenuBarPerformancePolicy.swift`、`MenuBarSamplingCadence` 或计划解析：D74 ps／内存普通隐藏 15 s、低电量 60 s；D75 nettop 普通隐藏 60 s、低电量隐藏 180 s、可见 10/60 s；其他周期、睡眠/暂停、可见性、首帧、缓存及来源时间均保留。

唯一旧断言调整：`UnifiedMenuBarPanelTests.testAdvancedPanelKeepsLiveObservationBelowShellAndNavigation` 原要求字符串 `private struct MenuBarAdvancedSamplingCoordinator`，现要求完整声明 `struct MenuBarAdvancedSamplingCoordinator: View`，用于直接托管同一协调视图。该断言的观察边界、shell、navigation、live card 预算断言全部保留；不改 D64/D74 产品契约或阈值，没有删断言或新增 skip。

## 新回归测试与反证

文件 `Tests/StorageCleanerMacTests/MenuBarPublishLoopTests.swift`，12 项运行期测试：

| 测试名 | 覆盖 |
| --- | --- |
| testRepeatedResidentConsumerSectionsDoNotPublishAfterFirstChange | nil、processor、disk、power、memory、overview，每次首次变化后 N=100，objectWillChange 必须为 0 |
| testRepeatedDirectResidentDemandDoesNotPublish | 绕过 consumer，重复有效需求仍零发布 |
| testChangedResidentSectionWithSamePendingStateDoesNotPublish | processor→disk→power 仍 pending=true 时零发布，转 memory 后恰好一次真实变化 |
| testReplayedOlderConsumerDoesNotStealLatestPagePriority | 重放旧 consumer 不抢新 consumer；真实注销恢复前一个页面 |
| testSameEffectiveDemandAcrossConsumersDoesNotPublish | 新增/移除第二个同需求 consumer，不发布 |
| testSameDeclaredConsumerRestoresEffectiveDemandAfterPause | 暂停/恢复重新解析有效需求，同时保留声明优先级 |
| testRepeatedVisibleConsumerDoesNotRestartSampler | 独立可见分支，100 次重复不发布；一个 baseline＋一个 delta，无重新 reset |
| testUnchangedRefreshIntervalDoesNotPublish | 同刷新档位 100 次零发布 |
| testCurrentPlanReplaysOnEveryNewSubscriptionButDoesNotPublishStore | 隐藏/可见的 100 次新订阅重放，store 零发布 |
| testHostedRestoredCachedPanelHasBoundedBodiesAndNoDemandPublications | 隔离恢复/页面偏好＋真实协调视图＋NSHostingView，12 次主动重绘；零发布、body ≤16；64 发布时熔断防止还原代码挂死 XCTest，触发仍断言失败 |
| testFreshQAPreferencesDoNotRequestRestoredPanel | 全新隔离域默认不恢复、默认 overview |
| testRepeatedAuxiliaryLifecycleDemandDoesNotPublishOrStartProbes | 注册/更新/暂停/注销重复不发布、不启动假 provider |

托管测试用 suspended 的隐藏计划避免真实硬件采样，直接覆盖 sample 的 nil-demand 路径；它不代替真实恢复窗口/AX/CPU 验收。新测试均用 TestPreferenceDomain、ScanStore.makeForTests；没有真实偏好、应用目录或路径安全例外。

scratch `counterexamples.json` 有 5 个独立 mutations，单点用 id/path/before/after/expected_occurrences/filter，多点用 replacements：

1. `restore-aa1abaf9-resident-feedback`：同时还原 consumer 顺序、有效需求守卫、常驻 pending 无条件赋值。重复需求、订阅重放、托管测试应断言 FAIL。
2. `restore-unconditional-sample-state`：保留方法和参数，去掉两个 Bool 比较；页面变化测试应 FAIL。
3. `replay-steals-consumer-priority`：重复推进序号；优先级测试应 FAIL。
4. `incorrect-declaration-only-early-return`：错误地按声明直接 return；暂停/恢复测试应 FAIL。
5. `unchanged-refresh-interval-publishes`：去掉档位比较；档位测试应 FAIL。

所有替换 anchor 静态核对出现次数，替换不改变闭包参数/返回类型/访问级别。**本批没有执行反证**：主会话必须每项单独在隔离副本应用、确认 Debug 编译 exit 0、运行 filter 得到断言 FAIL，再还原并确认 PASS；编译错误、夹具权限错误、超时或 crash 不算有效红灯。

## 本轮验证

以下均为本轮实际结果，日志相对 `~/Developer/.sc-build/r2-hotfix-publish-loop/`，完整计数及日志 SHA-256 在 `validation-summary.json`。

| 检查 | 状态 / exit code | 证据 |
| --- | --- | --- |
| Debug `swift build F --build-tests` | PASS / 0；264.79 s | `logs/debug-build.log` |
| 最终源码 Debug 增量编译 | PASS / 0；29.09 s | `logs/debug-build-final.log` |
| 标准 Release `-c release --build-tests -Xswiftc -enable-testing` | BLOCKED / 1；MemoryFixtureApp.dSYM 的 dsymutil 被拒 `Operation not permitted` | `logs/release-build.log` |
| 补充 Release，同参数加 `-debug-info-format none` | PASS / 0；449.26 s；生产优化代码和全部 Release 测试目标编译 | `logs/release-build-no-dsym.log` |
| 8 个定向类 | FAIL / 1；170 方法，151 PASS、19 FAIL、0 skip；20 条失败断言 | `logs/targeted-tests.log`、`targeted-results.json`、`targeted-failures.json` |
| 独立 Combine 当前值重放探针 | PASS / 0；100 个新订阅收到 100 次不变值 | `evidence/plan-replay.swift`、`logs/plan-replay.log` |
| 私有 API 源码检查 | PASS / 0；7 处既有 allowlist 调用 | `static-checks.json` |
| git diff --check | PASS / 0 | `static-checks.json` |
| 反证、全量、安装、App/AX/CPU、提交 | NOT RUN / 未完成 | 主会话分别验证 |

定向逐类：HelperPowerMetricsMonitorTests 16/15 PASS/1 FAIL；MenuBarPrestoredSamplingTests 11/9/2；MenuBarPublishLoopTests 12/2/10；MenuBarSamplingPlanTests 28/28/0；MiniWindowLiveReadingRetentionTests 8/4/4；TestPreferenceHygieneTests 21/19/2；UIConsistencyRegressionTests 46/46/0；UnifiedMenuBarPanelTests 28/28/0。没有 skip。

19 个失败方法的分类已逐条核对：17 个在 TestFileSystem.makeOperationHome 创建 `~/.storage-cleaner-*` 时报 Code=513、底层 `Operation not permitted`；核心 store/托管测试未运行到发布断言。另两个是 `TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`（2 条断言）和 `testTemporarySuiteCanBeReopenedOnAWorkerThread`（1 条断言），对应 CFPreferences `sandbox_extension_issue_file failed ... Operation not permitted`、synchronize/落盘失败。偏好源码守卫 `testTestSourcesUseTemporaryDomainsAndDoNotPersistStandardDefaults` 本轮 PASS；不能把整类或整组报成 PASS。未改夹具、路径检查、阈值、偏好根或 skip 来消除失败。

独立 Combine 探针只验证订阅重放机制，不证明 ScanStore / NSHostingView 的核心断言通过。新测试通过的是全新 QA 默认偏好和暂停状态下辅助生命周期；另 10 项包括 hosted/body 上限必须主会话在沙箱外复跑。

补充 Release 保留 release 优化和 enable-testing，只取消调试信息；不能冒充标准 Release/dSYM 门禁通过。编译警告为用户级 SwiftPM 缓存权限、skip-update deprecated 与未改动的旧测试警告，改动文件无新编译警告。Release 临时目录已按 RULES 验证 CACHEDIR.TAG 后清理，`release-cleanup.json` 记录所有权、删除和日志保留；Debug 留给主会话合并后清理，中立离线依赖来源未改。

构建与定向测试只在本批 scratch；没有运行 script/verify.sh 的全量步骤。

## 主会话命令与交付

```zsh
cd ~/Developer/sc-worktrees/r2-hotfix-publish-loop
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8 CLANG_MODULE_CACHE_PATH=/Users/developer/.cache/clang
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-hotfix-publish-loop/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(paste -sd '|' ~/Developer/.sc-build/r2-hotfix-publish-loop/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
# 本轮 Release 临时目录在验证后按 RULES 清理；先恢复离线依赖。
python3 ~/Developer/.sc-build/r2-hotfix-publish-loop/seed-offline-dependencies.py release
R=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-hotfix-publish-loop/release --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build -c release "${R[@]}" --build-tests -Xswiftc -enable-testing
# 五项反证按上文要求单独还原/重编译/红绿验证，不能用本批绿包 --skip-build。
# 主会话验证与复核完成、Git 可写后：
python3 ~/Developer/.sc-build/r2-hotfix-publish-loop/prepared/commit-prepared.py --validated
```

prepared 分三组：01 ScanStore／辅助需求幂等；02 真实协调视图测试入口／12 条运行期回归／源码守卫；03 交接。manifest 核对分支、完整基线、最终文件和产物 SHA-256；脚本只在已有改动的本 worktree 将补丁按组应用到 index 并提交，不重新修改工作文件，不合并/推送/安装。

JEV：工具 schema 只提供 TypeSafe Jev 的判断字段，没有可选模型/推理参数。本轮方案评估调用遭工具审批拒绝，原文 `MCP tool call requires approval, but approval policy is never`；没有实际模型响应或判断，未声称 JEV 验证通过，未改变当前模型/推理设置。

剩余限制：真实偏好值和具体启动面板状态未读；真实 App、AX 可见性、CPU 98–99% 回落、安装、全量门禁、反证和提交均由主会话后续分别验证。本批只提供源码修复和其可审查证据。
