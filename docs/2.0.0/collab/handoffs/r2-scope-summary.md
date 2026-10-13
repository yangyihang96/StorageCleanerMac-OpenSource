# r2-scope-summary：D68 扫描范围与清理摘要交接

## 第六轮：小窗测试会话范围与专项扫描切换（2026-10-09）

基线仍为 `91401863d8556dfaef56da2209199a32a35f3eb0`；`/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r6/` 的 `all.patch` 包含第五轮加本轮的**最终源码**。主会话报告第五轮 build 通过、5 项单点变异均 PASS；定向 1298 项与全量 4291 项各有相同的 3 处断言失败，记录在 `r5-failures.txt`。本轮没有把第五轮的部分验证当作最终通过。

### 根因与修复

- `MiniWindowCleanupPresentationTests` 的共享 `fixture()` 在第五轮已明确标为勾选垃圾范围的智能扫描会话。两个失败方法却另用 `ScanSession(...)` 手工构造“完成时间晚 1 秒”的副本，遗漏了 `smartScanScopes`。`ScanSession.coversCleanupCandidates` 正确地把副本判为无范围会话：可见小窗不再启动明细 worker，纯展示返回 `.empty`。生产智能扫描通过 `SmartScanReadOperation.withSmartScan` 写入范围，未发现真实会话被误判的证据，因此本轮不改产品覆盖判断。
- 这两个副本现在继承原会话的 `smartScanScopes`，并明确断言仍覆盖垃圾范围。原测试的等待、布局版本、身份／日期／结果变化时的 `.preparing` 及旧行排除断言全部保留。
- 新增 `testDedicatedSessionArrivalsKeepSmartHistoryOrUnscannedWithoutPreparing`：安全清理与开发文件专项会话分别进入已打开的小窗。在先前有智能扫描时，打开前快照及订阅都保留其历史数字；没有智能扫描时保持“尚未扫描”。两种情况均不进入 `.preparing`、不建立明细 worker，也不把专项扫描的空结果当成全局 0。旧的可操作行在会话移除时清除，避免过期明细被当作本次可操作项；布局版本只在原智能会话移除时推进一次，随后专项会话切换不再推进。

### 主会话沙箱外验证

本轮沙箱仍依 `common.md` 不编译、不运行 XCTest、不执行变异。第五轮失败记录就是修复前红态；主会话需在独立 scratch 上确认修后绿态，并确认每条方法过滤实际执行 1 项：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-scope-summary
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
scope_r6=/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r6
scope_r6_debug=/Users/developer/Developer/.sc-build/r2-scope-summary/validation-r6/debug
swift build --build-tests --scratch-path "$scope_r6_debug" --jobs 4
swift test --skip-build --scratch-path "$scope_r6_debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests/testOnlyDeliveredResultKeysOrSessionRemovalAdvanceLayoutRevision'
swift test --skip-build --scratch-path "$scope_r6_debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests/testSessionIdentityDateOrOutcomeChangesUsePreparationInsteadOfOldRows'
swift test --skip-build --scratch-path "$scope_r6_debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests/testDedicatedSessionArrivalsKeepSmartHistoryOrUnscannedWithoutPreparing'
scope_r6_filter=$(paste -sd '|' "$scope_r6/targeted-classes.txt")
swift test --skip-build --scratch-path "$scope_r6_debug" --jobs 4 --filter "$scope_r6_filter"
swift test --skip-build --scratch-path "$scope_r6_debug" --jobs 4
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-scope-summary/validation-r6/concurrency --jobs 4 -Xswiftc -strict-concurrency=complete
git diff --check
```

`prepared-r6/counterexamples.json` 包含第五轮的 5 项产品反证和本轮 2 项“时间副本漏传智能范围”的单点反证。第五轮 5 项已由主会话在第五轮源码上验证，但最终源码仍须按清单逐项重跑；每项单独变异、编译成功、目标 filter 实际执行 1 项且目标断言变红，随后恢复 manifest 哈希。小窗订阅反证的目标 filter 已改为本轮新增的可见状态切换测试。`Executed 0 tests` 或编译失败都不算反证。

当前交付只验证补丁与哈希的静态一致性；Swift build、定向和全量 XCTest、变异、启动、提交、合并均由主会话完成。第六轮 JEV 复核调用被工具审批机制拒绝（需批准，但策略为 `never`），没有获得 JEV 判断。第六轮没有更改产品实现、D68 口径或清理安全规则。两组补丁及 `all.patch` 均相对 `91401863`，交接以下第五轮及更早记录仅供追溯。

---

## 第五轮：全局摘要只取智能扫描（2026-10-09）

本轮基线为已提交且干净的 `91401863d8556dfaef56da2209199a32a35f3eb0`，最终源码补丁在 `/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r5/`。已读 `review/review-2.md` 全文。复核员在内置规则中观察到智能扫描垃圾范围 69 条规则，而安全清理四类全选只覆盖其中 30 条，另有 40 条 safe 开发缓存规则不在安全清理范围。主会话据此补充 D68：全局“可安全清理”数字只来自勾选垃圾范围的智能扫描会话及其历史；安全清理和开发文件专项扫描只影响自己的页面。本轮已在 `DECISIONS.md` 的 D68 行写入这句口径。

### 源码与受影响断言

- `ScanSession.coversCleanupCandidates` 现在只检查会话明确保存的智能扫描范围。安全清理四类全选、缩小范围、开发文件和旧式无范围会话均返回 false；删去不再需要的安全清理范围会话快照。`ScanStore` 保留专项扫描自己的结果页路径，并阻止安全清理专项结果出现在开发文件页；全局菜单当前标量只从智能扫描会话生成，旧式 `result` 不再进入全局数字。小窗原有纯解析、打开前快照和订阅继续共用这个判断。
- 历史的 `coversCleanupCandidates` 同样要求明确的智能扫描范围。旧记录仍保留在文件历史、趋势兼容和提醒日期推导中，但不再被误认成智能扫描的全局垃圾数字。`SafeCleanupScanScope.defaultSelection` 成为四类默认勾选的单一常量，Store 和测试共用；全局覆盖判断不再依赖这组分类。
- 改写第四轮“全选四类即覆盖”的用例为 `testAllDefaultSafeCleanupScopesStillDoNotUpdateGlobalSummary`：分别在无旧智能历史、有一条 73,728 B 旧智能历史时断言菜单栏与小窗回退到空态／旧数字；专项页面仍取得本次会话，另一个专项页面不取得它。开发文件与缩小范围的原行为用例继续执行同样两种历史条件。新添旧式无范围当前会话的纯展示测试，以及旧式 `ScanResult` 不能覆盖智能扫描全局数字的 Store 测试。组合测试和真零测试的旧垃圾种子从无范围旧记录改为明确的智能扫描记录，以保持“有上一次智能扫描”的含义。
- `ScanScopeHistoryTests` 原“旧记录覆盖全量”的断言改为：其 `completedScopes` 仍供趋势兼容使用，但 `coversCleanupCandidates` 与 `latestCleanupEntry` 不提供全局数字；旧偏好仍从该文件历史推导提醒日期。菜单栏同日竞争测试继续使用智能历史，并新增更晚的无范围旧记录不会盖掉智能数字的断言。未放宽阈值、跳过测试或改变扫描及清理规则。
- 既有小窗测试的共享 `fixture()` 原来没有范围元数据，却按智能扫描断言会话／历史可见；本轮给它明确的垃圾范围，保留原小窗行为断言，并在旧式结果页面测试中新增“页面明细不覆盖智能扫描全局字节数”断言。截屏用的 `DebugSmartScanSessionFixture` 本来就是智能扫描，却同样缺少范围元数据；补上垃圾与需确认文件范围，维持 `MiniWindowDemoDataTests` 的会话卡展示。无范围旧会话反证改用显式无范围副本，与该演示夹具解耦。

### 主会话沙箱外验证

第四轮主会话提交及终审报告的 merge 副本全量 Debug 4290 项、25 跳过、0 失败，只适用于 `91401863`；不能代替本轮验证。本轮沙箱按 `common.md` 不构建、不运行 XCTest 或变异。主会话用独立 scratch 编译测试目标；以下每条方法过滤必须实际执行 1 项，再跑定向类和全量 Debug，记录 exit code、执行数、跳过与日志：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-scope-summary
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
scope_r5=/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r5
scope_r5_debug=/Users/developer/Developer/.sc-build/r2-scope-summary/validation-r5/debug
swift build --build-tests --scratch-path "$scope_r5_debug" --jobs 4
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'SmartScanScopeTests/testAllDefaultSafeCleanupScopesStillDoNotUpdateGlobalSummary'
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'SmartScanScopeTests/testDeveloperFilesScanDoesNotReplaceAppWideSafeCleanupSummary'
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'SmartScanScopeTests/testNarrowedSafeCleanupScanDoesNotReplaceAppWideSummary'
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'SmartScanScopeTests/testLegacyUnscopedSessionCannotSupplyGlobalSummary'
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'SmartScanScopeTests/testLegacyResultCannotReplaceSmartScanGlobalSummary'
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'ScanScopeHistoryTests/testLegacyRecordsKeepTrendCoverageButDoNotFeedGlobalCleanupSummary'
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'MiniWindowDemoDataTests/testCleanupAfterSmartScanScenarioUsesTheExistingInertSessionAndCleanupRoute'
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter 'MiniWindowCleanupPresentationTests/testLegacyScanStillUsesStorageItemsAndOriginalTitlesAndNotices'
scope_r5_filter=$(paste -sd '|' "$scope_r5/targeted-classes.txt")
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4 --filter "$scope_r5_filter"
swift test --skip-build --scratch-path "$scope_r5_debug" --jobs 4
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-scope-summary/validation-r5/concurrency --jobs 4 -Xswiftc -strict-concurrency=complete
git diff --check
```

`prepared-r5/counterexamples.json` 列出互不叠加的单点变异：把会话判断改回 nil 即覆盖、让 Store 或小窗直接纳入专项会话、让无范围旧历史再次提供全局数字。每一项必须在独立构建目录中编译成功、由对应 filter 实际运行 1 项并触发目标断言失败；`Executed 0 tests` 或编译失败都不是反证。每项结束还原并核对 manifest 的全部最终源码 SHA-256，最后在原源码上重建并重跑目标方法。主会话完成这些验证及复核后才可使用本目录 `commit-prepared.py` 按组提交。

本轮交付状态：**PASS（静态）**为基线、分组／整包补丁应用与反向检查、最终文件哈希、变异锚点和目标方法名，详见 `prepared-r5/static-checks.json`；**NOT RUN** 为 Swift build、严格并发、XCTest、变异、应用启动、安装、提交及合并。本轮调用 JEV 复核工具时，工具返回需要批准但当前审批策略为 `never`，因此没有 JEV 判断或实际模型标识。终审报告的“可合并”只评价第四轮源码，不代表本轮已复核。

本轮两组补丁：`01-smart-only-coverage`（会话与历史口径、Store 默认集合、行为测试）、`02-decision-handoff`（D68 与本交接）。两组补丁及 `all.patch` 均相对 `91401863`。

---

以下第四轮及更早记录是历史交接，描述当时的产品口径，不覆盖本节及 D68 第五轮补充。

## 第四轮：专门扫描的覆盖范围与未来提醒时间（2026-10-09）

本轮以已提交且干净的 `f2cc91cc12f6beb5ad2109bca0a60b73e9850f91` 为基线，最终源码补丁在 `/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r4/`。已读独立复核全文 `review/review-1.md` 和其探针 `review/evidence/ReviewProbeScopeSummaryTests.swift`。复核确认 D68 智能扫描 14 种组合正确；新增 P1 是开发文件和缩小范围的安全清理会话被三处 `?? true` 当作覆盖垃圾，覆盖菜单栏旧全量数字并让小窗显示部分数字或 0。其 P2 是未来的提醒日期被 `max(previous, date)` 永久保留。第三轮的 build、定向、全量与 18 项反证结果来自主会话和复核报告，本轮没有把它们当作新源码的验证。

### 本轮改动

1. `ScanSession.coversCleanupCandidates` 集中判断本次扫描的范围。智能扫描只看已完成会话保存的 `smartScanScopes`；安全清理专门扫描记录启动时的四类勾选集合，只有四类全选才覆盖默认安全清理分类；开发文件扫描的类别限制不算覆盖；其他非智能扫描仅在类别和规则均不受限时算全量。`mappingCandidates` 继续保存这个快照。`ScanStore` 的菜单标量摘要、小窗的纯 presentation 和明细订阅都用同一个判断，切换页面或勾选框不会改写已完成会话。
2. `ScanHistoryService.recordCompletedScan` 在已保存时间晚于当前参考时间时以本次完成时间替换它；正常旧时间仍保持原来的单调选择。`ScanHistorySummary.latestScanAt` 优先取已写入的完成时间，仅在旧偏好没有该键时从文件历史推导，避免未来日期历史条目把校正后的提醒再次盖掉。参考时间可注入，仅用于确定性测试；生产默认当前时间。
3. 新增三个 `SmartScanScopeTests` 行为用例：开发文件、缩小范围安全清理各在无历史／有旧全量历史两种情形下检查会话、菜单文本与数字、小窗纯解析、打开前快照、订阅与明细 worker；四类全选在显式规则 ID 存在时仍算覆盖，真正的 0 可替换旧数字。新增一个 `ScanScopeHistoryTests` 用例，在独立偏好域中注入未来提醒与未来文件历史，校正、重开和随后更旧扫描的行为均有断言。未改写或删除旧断言。

这里的“全量安全清理”严格指 UI 默认四类全选。当前 `Resources/CleanupRules.v2.json` 的开发缓存规则不属于这四类，但属于智能扫描的垃圾范围；因此两种扫描的实际规则集合并不完全相同。本轮按用户指定的四类全选口径判定当前安全清理会话，未改扫描分类、规则或持久历史格式；主会话复核菜单文案是否仍应视两类数字为同一口径。

### 主会话验证与单点反证

本沙箱按 `common.md` 没有运行 Swift 构建、XCTest 或变异；主会话在沙箱外使用独立 scratch。先编译测试目标，再分别按方法过滤以下四项，**每次检查实际执行数为 1**，然后跑 `prepared-r4/targeted-classes.txt` 的定向类集合及全量 Debug：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-scope-summary
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
scope_r4=/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r4
scope_r4_debug=/Users/developer/Developer/.sc-build/r2-scope-summary/validation-r4/debug
swift build --build-tests --scratch-path "$scope_r4_debug" --jobs 4
swift test --skip-build --scratch-path "$scope_r4_debug" --jobs 4 --filter 'SmartScanScopeTests/testDeveloperFilesScanDoesNotReplaceAppWideSafeCleanupSummary'
swift test --skip-build --scratch-path "$scope_r4_debug" --jobs 4 --filter 'SmartScanScopeTests/testNarrowedSafeCleanupScanDoesNotReplaceAppWideSummary'
swift test --skip-build --scratch-path "$scope_r4_debug" --jobs 4 --filter 'SmartScanScopeTests/testAllDefaultSafeCleanupScopesCountAsCoveredEvenWithExplicitRuleIDs'
swift test --skip-build --scratch-path "$scope_r4_debug" --jobs 4 --filter 'ScanScopeHistoryTests/testFutureReminderTimeIsReplacedByTheCompletedScanAndStaysCorrectAfterReopen'
scope_r4_filter=$(paste -sd '|' "$scope_r4/targeted-classes.txt")
swift test --skip-build --scratch-path "$scope_r4_debug" --jobs 4 --filter "$scope_r4_filter"
swift test --skip-build --scratch-path "$scope_r4_debug" --jobs 4
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-scope-summary/validation-r4/concurrency --jobs 4 -Xswiftc -strict-concurrency=complete
git diff --check
```

`prepared-r4/counterexamples.json` 列出七项**互不叠加**的单点变异及可真正选中目标的 filter：Store 与小窗两处各改回原来的 `?? true`，另测会话对开发文件／缩小范围的判断、四类全选保留、未来日期写入与摘要读回。每份变异用新构建目录；编译成功后目标测试必须实际执行且由对应断言失败，编译失败或 `Executed 0 tests` 不算变红。还原源码并核对 manifest 的最终文件哈希，再构建、重跑四个方法和整类。主会话保存命令、exit code、测试数和变异日志；若缺少这些结果，本轮只能算源码准备完成。

### 交付状态

- **PASS（静态）**：基线、差异、补丁可逆检查、最终文件 SHA-256、变异锚点和过滤方法名见 `prepared-r4/static-checks.json`。
- **NOT RUN**：本轮 Swift build、严格并发、定向／全量 XCTest、变异执行、应用启动、安装、提交、复核与合并。此前主会话全量通过只适用于 `f2cc91cc`。
- **BLOCKED**：本轮一次 `jev_decide` 调用被工具返回 `MCP tool call requires approval, but approval policy is never`；请求未执行，未得到 JEV 判断或实际模型标识。此边界与前轮相同，仍需主会话独立复核。

本轮分三组补丁：`01-coverage`（会话、Store、小窗及行为测试）、`02-reminder`（服务与历史测试）、`03-handoff`（本交接）。`all.patch` 相对 `f2cc91cc`。`commit-prepared.py` 仅给主会话在验证后按组提交，本沙箱未运行它，也未触碰安装或合并。

---

## 前三轮历史交接（以下基线为 c85f124f）

日期：2026-10-08。分支：`task/r2-scope-summary`。基线：`c85f124fdad8d9c7f51309b093445ee8847f7d7e`。
产物：`/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r3/`。

## 第三轮：恢复 XCTest 过滤选择

第二轮主会话日志 `logs/main-prepared-r2-222953/`：build 通过；定向 1271 项（3 项 skipped）和全量 Debug 4285 项（25 项 skipped）均 0 失败。18 项单点反证中 14 项真实运行且失败，4 项为无效反证：`trend-compares-different-coverage`、`space-delta-compares-different-coverage`、`clear-history-retains-reminder-time`、`clear-health-only-retains-reminder-after-reopen` 的日志均显示 `Executed 0 tests`，没有断言失败。原日志和 SHA-256 见 `prepared-r3/r2-filter-failure.json`，主会话原始记录保留。定向比预期少 8 项，正好是 `ScanScopeHistoryTests` 的 8 个方法；全量中这 8 个方法照常执行。这证明原 `override class var defaultTestSuite` 破坏 SwiftPM `--filter` 选取，不能把定向 0 失败或四项 0 测试变异视作覆盖该类的有效绿／红证据。

本轮从 `ScanScopeHistoryTests` **完全移除 `defaultTestSuite` 重写**，保留其 8 个测试方法及全部断言、独立 `TestPreferenceDomain` 偏好域。`testHistoryPreferenceDomainsStayIndependentInBothClearOrders` 自身按 `[0, 1]`、`[1, 0]` 两种顺序执行同一组写入、清空、重开读回与互不干扰断言；因此无需改变 XCTest 的类级发现或运行顺序。四项变异的 `filter` 字符串保持 `ScanScopeHistoryTests/<具体方法>`，源码锚点和方法名均经静态检查；**实际能否选中以第三轮 SwiftPM 日志里每个目标方法恰好执行 1 项为准**。

**主会话第三轮验证入口（沙箱外执行）：**

```bash
python3 /Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r3/validate-r3.py
```

脚本从新建目录显式 `swift build --build-tests`，核对 XCTest 中 `clear` 有两次删除调用，然后在绿色构建上分别运行原失败方法两次、整类两次，并按方法名倒序为每个方法各执行一次 `swift test --filter ScanScopeHistoryTests/<方法>`（共 8 次，重复两轮）。每条命令都核对实际输出中恰好选中对应方法。**逐方法倒序跨多个测试进程；它不宣称整个 XCTest 类在同一进程倒序。** 同进程的双顺序检查由上述双域测试负责。之后跑完整定向清单和全量 Debug，要求全量中该类 8 项均被执行；定向也必须包含这 8 项。

再为上述四项失败反证创建三份互不复用的变异构建：趋势、空间变化各一份，两个清空场景共用同一单点删除变异。每份先编译测试目标、检查测试二进制、按 `counterexamples.json` 的 `filter` 运行；脚本拒绝 `Executed 0 tests`、编译失败或非目标断言失败。`finally` 还原源码并检查 manifest 所有文件 SHA-256，最后重建绿色测试目标、检查两次删除调用、整类再跑一次。若失败则保留脚本自身构建和日志供审计，不能报 PASS。前轮另外 14 项已由主会话的原始日志记为有效反证，产品源码第三轮未变；是否复跑 18 项可由主会话门禁决定。

如需手工先确认 filter 行为，主会话可在独立 scratch 路径运行以下命令；**每条必须从输出核对执行数，`--list-tests` 不算执行**：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-scope-summary
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
scope_debug=/Users/developer/Developer/.sc-build/r2-scope-summary/validation-r3-manual/debug
swift build --build-tests --scratch-path "$scope_debug" --jobs 4
swift test --skip-build --scratch-path "$scope_debug" --jobs 4 --filter 'ScanScopeHistoryTests'
swift test --skip-build --scratch-path "$scope_debug" --jobs 4 --filter 'ScanScopeHistoryTests/testEveryScopePairComparesOnlyEqualCoverage'
swift test --skip-build --scratch-path "$scope_debug" --jobs 4 --filter 'ScanScopeHistoryTests/testReminderTimePersistsWithoutFabricatingFileHistoryAndClearsWithHistory'
swift test --skip-build --scratch-path "$scope_debug" --jobs 4 --filter 'ScanScopeHistoryTests/testHealthOnlyReminderClearsWithoutFileHistoryWhenReopened'
```

这四条过滤测试的预期执行数依次为 8、1、1、1；最终是否通过，以主会话实际 exit code 和日志为准。第三轮沙箱只做源码、补丁、哈希与日志回读，没有运行 Swift build/test/变异。旧版 `prepared-r2/validate-r2.py` 使用已删除的 suite 重写，**不再作为本轮验证入口**。

## 第二轮根因与修复（2026-10-08）

第一轮主会话日志回读：build 通过；定向执行 1277 项、3 项 skipped、0 失败；17 个变异均变红；全量执行 4283 项、25 项 skipped，1 个方法中的 2 条断言失败。单独重跑两次失败是主会话提供的信息，本轮未找到对应独立日志，不冒充本轮执行。

**根因证据是源码与二进制不一致，不能据此认定共享偏好或执行顺序污染。** 当前 `ScanHistoryService.clear(defaults:)` 两行分别删除 `scan.history` 与 `scan.history.last-completed-at`；整个源码的 SHA-256 与第一轮 manifest 完全相同。原失败测试也已经使用每次唯一的 `TestPreferenceDomain.make(for:)`，所有持久化调用均注入该实例，没有另外一个共享历史文件。

对第一轮现存 app object、testable object、最终 XCTest 二进制只读执行 `nm` / `llvm-objdump`：三个 `clear` 函数均只调用一次 `removeObjectForKey:`，只访问 `defaultsKey`，没有访问 `lastCompletedScanKey`。最终测试二进制 SHA-256 是 `9c6fe3ebf3f66d58991bf363aecebc433d712500eeef72162c1d7cfa6b47861e`。这就是第一轮最后一项 `clear-history-retains-reminder-time` 变异的行为：该变异 21:23:31 开始、21:23:32 结束，全量 21:23:33 开始，失败值与变异日志完全相同。源码已经还原，但测试产物仍残留变异。缺少第一轮驱动脚本及逐次构建输入记录，无法再区分是跳过测试目标重建还是增量构建未刷新；不猜测具体缓存机制。

证据保存为 `prepared-r2/r1-root-cause.json`（源码、3 个二进制及 5 份原日志哈希、只读命令）和 `r1-clear-disassembly.txt`（三个完整函数反汇编）。原 prepared 和原日志均保留。

第二轮在 `ScanScopeHistoryTests` 补强测试，不更改正确的清空实现：

- 持久化用例均通过现有历史测试工厂分配独立偏好域，读取前先断言空态；历史和提醒键同域注入，teardown 清理且守卫 standard 的两个键未改变。
- 原失败方法保留全部断言，增加重开后写入/清空读回、原实例读回、原始两键都消失、提醒推导为 nil。
- 新增健康单独扫描且没有文件历史时的清空测试，清空后重新打开同域验证提醒不存在。
- 新增双域测试：两套不同历史和提醒同时存在，按 `[0, 1]` 和 `[1, 0]` 清空；每一步重开两个域，验证被清空域为空、另一个域数据完整、无关偏好保留。

第二轮所附反序 suite 验证入口经主会话发现无法用于 `--filter`，第三轮入口和实际计数要求以上节为准。第二轮增强的双域断言继续保留。

## 实现与依据

1. P1 / D68：`ScanHistorySummary.latestCleanupEntry`、`latestCleanupStatus` 只取覆盖 `.cleanupCandidates` 的最近历史。没有范围元数据的旧条目按旧版全量扫描兼容；显式空范围或健康／需确认文件范围不能提供垃圾数字。保留 `latest`、`latestStatus` 的文件历史语义，权限修复入口不换成垃圾历史。
2. 菜单栏读取 `ScanStore.latestSafeCleanupEntry`，在上述历史和当前覆盖垃圾的结果之间按日期选最近一条；同日期优先当前加载的数字，使清理后的结果不被原扫描历史盖回。当前结果只缓存标量历史投影，在 `result` / `cleanupScanSession` 变更时计算，面板打开不遍历候选项。取消的会话不作为菜单数字来源。没有覆盖垃圾的结果时显示“尚未扫描”，数量为“等待扫描”。原有主窗口历史清理数字也改用垃圾历史。
3. 小窗的纯 presentation 检查会话和历史范围；来源订阅及打开前快照均选垃圾历史。未扫垃圾的会话不进入明细 worker、不保留执行行，直接回退到历史或空态。扫描中、取消、默认选择和已有清理操作入口不变。
4. 提醒使用 `ScanHistorySummary.latestScanAt`，取文件历史日期与单独保存的完成日期的较新值。新增本机偏好键 `scan.history.last-completed-at`：健康单独扫描只写这个日期，不制造文件数量或评分条目；已完成的文件扫描仍按 D64 补充记录实际范围。取消不写日期；清空历史同时清空日期；旧偏好没有新键时从原文件历史推导。只有健康扫描日期时也允许显式清空历史记录。
5. P2：趋势及存储空间变化只比较最新记录与最近一条 `completedScopes` 相同的历史，包括健康范围；没有匹配则为 nil。原始 `previous` 仍表示相邻历史，不改评分公式、评分模型版本或保存的计数。未请求的“需确认文件”零值不再与全量评分／计数作趋势比较。
6. P2 / D64：`ScanHistoryHealthStatusLine` 在设置页扫描提醒及主窗口历史摘要中显示历史健康状态，一行 Text、无装饰图标。“文件扫描 · 未做健康检查”明确属于文件历史，避免健康单独扫描已更新提醒时间时误读为那次健康扫描未执行。旧条目缺少健康元数据时不编造检查结果。现有产品没有单独历史列表页，沿用现有摘要入口，不新增列表页面。
7. 编译警告源码修正：`MigrationDurabilityTests` 明确丢弃 worker 成功返回值，仍在成功时失败、仍核对失败类型和超时。小窗生命周期测试的三处 weak var 改为 let 弱捕获读取闭包，读值时调用闭包；不改成强引用，继续验证 XCTest teardown lease 保活。

## 修改的旧断言

唯一口径改写：`MiniWindowCleanupPresentationTests.testLegacyScanStillUsesStorageItemsAndOriginalTitlesAndNotices` 在无当前结果、无历史时，`cleanupSummaryTitle` 从“上次扫描摘要 / Last Scan Summary”改为“尚未扫描 / Not Scanned Yet”，依据 D68。原有菜单摘要、数量、导航、清理安全、超时和生命周期断言均保留。弱读取闭包只改断言参数写法，未删断言或降低阈值。另在既有取消测试中补充提醒时间不更新的断言。

## 新增测试

相对基线共 16 个新增测试方法；第二轮新增 2 个，另补强原持久化测试。第二轮主会话曾完成 build、定向和全量，但过滤器遗漏本类；第三轮修复后仍须重新取得按类／按方法过滤的运行证据。

- `SmartScanScopeTests` 新增 7 项：8 种勾选组合 × 无历史／旧垃圾历史两种情况；使用 `ScanStore.makeForTests`、假扫描器和假健康读取，逐项检查菜单数字、小窗打开前快照、实际来源订阅、明细缓存、提醒日期及持久化。空选择不扫描；完成后改勾选不改写覆盖范围。另测可见小窗连续全量→需确认文件→健康、纯 presentation 防御、真正的零项垃圾结果、清空历史后仍有当前结果，以及当前／历史时间选择与同日期优先加载数字。
- `ScanScopeHistoryTests` 新增 8 项：7 × 7 范围配对、跨不同范围查找最近匹配、旧全量历史兼容、垃圾摘要自身时效与真零值、健康单独扫描日期保存／清空、旧偏好日期回退，以及独立双域按正／逆序清空、只有健康提醒时重开清空。所有持久化测试均经 `ScanHistoryTestDefaults` → `TestPreferenceDomain` 分配唯一临时绝对路径域，历史 JSON 与提醒键同域注入；重开读回、初始空态和 standard 两键未改变均有断言。
- `MiniWindowCleanupPresentationTests` 新增 1 项：真实 NSHostingController / AX 读取中英文“未做健康检查”，并守卫一行 Text、无图标和设置页提醒接线。

偏好全部走 `TestPreferenceDomain`；ScanStore 走 `makeForTests`；假扫描器路径采用测试工厂登记的操作 home，不写真实用户文件。

## 主会话验证命令

全部在沙箱外执行。产物中的 `targeted-classes.txt` 包含本批必需类、源码读取类和相关运行时回归类；`source-readers.json` 提供清单来源。不要为了节省耗时缩减清单。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-scope-summary
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
scope_prepared=/Users/developer/Developer/.sc-build/r2-scope-summary/prepared-r3
scope_filter=$(paste -sd '|' "$scope_prepared/targeted-classes.txt")
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-scope-summary/validation-r3-manual/debug --jobs 4
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-scope-summary/validation-r3-manual/debug --jobs 4 --filter "$scope_filter"
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-scope-summary/validation-r3-manual/concurrency --jobs 4 -Xswiftc -strict-concurrency=complete
git diff --check
```

主会话记录每条命令的 exit code、测试数量／跳过、warning 和日志。构建日志须确认所指 4 处警告不再出现。编译或访问级别问题交回本会话修复，不删除测试、不放宽阈值。

合并后的项目门禁：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-scope-summary/verify \
SWIFT_BUILD_JOBS=4 script/verify.sh
```

## 红／绿／单点反证

第三轮未运行红、绿或反证；下列是主会话执行计划，不能作为本轮已通过的证据。第二轮 14 项变异有真实断言失败，4 项执行 0 测试须重做。

1. 红：在可恢复副本中按 `counterexamples.json` 的单项 before→after 替换模拟原缺陷。每项只替换一处（`expected_occurrences=1`）。先确保变异源码编译成功，再运行其 `filter`；必须由指定数值、来源、日期或可见文字断言失败，编译失败不能算反证。主要原缺陷由 `menu-bytes-latest-any-scope`、`mini-session-ignores-coverage`、`trend-compares-different-coverage` 重现；独立复核原始探针见提示引用的 `ReviewProbeR12Tests.swift`。
2. 绿：还原到 manifest 记录的最终文件 SHA-256，跑完整定向类清单。8 种组合 × 2 情况及 49 组趋势配对都必须通过。真零、空选择、取消、历史清空和日期兼容保持既有或新增断言。
3. 反证：逐项独立执行全部 mutations，不叠加变异，不改断言。清单覆盖历史范围过滤、菜单 bytes/count 接线、当前结果范围／同日优先、小窗纯解析／订阅／打开前快照、趋势范围和空间变化、健康单独扫描日期、设置提醒日期、健康文字及清空日期。保存每项编译结果、目标断言、exit code；恢复并核对 SHA-256 后才能跑下一项。
4. 产品只读验收由主会话进行：新状态中只扫需确认文件／健康，菜单和小窗显示未扫；先扫垃圾再扫需确认文件／健康，垃圾数字与原日期保留，提醒更新；真正垃圾零项显示已扫零项；未选健康的文件历史显示一行“未做健康检查”。本批没有启动、安装应用或进行真实扫描／清理。

## 补丁分组和提交

1. `01-scope-history`：历史覆盖／趋势／提醒日期、Store 当前标量投影及写入、新历史测试。
2. `02-summary-ui`：小窗和菜单数字来源、历史健康文字、主窗口历史清理数字、组合与可见小窗测试；生命周期 weak 警告修正随其测试文件交付。
3. `03-migration-warning`：MigrationDurability 未使用表达式警告源码修正。
4. `04-handoff`：本交接。

`commit-prepared.py` 仅供主会话验证及复核后执行；执行前检查基线、分支、索引空态、最终源码与产物哈希，按组暂存补丁并提交。它不执行构建／测试、不推送、不合并。第三轮未运行此脚本。

## 实际状态和限制

- PASS：第三轮基线／分支／差异与产物哈希只读审计见 `prepared-r3/static-checks.json`；第二轮主会话 build、1271 项定向、4285 项全量及 14 项有效反证有原始日志。
- NOT RUN（第三轮）：Swift 编译、严格并发、XCTest（执行 0）、四项无效反证的重做、应用启动、实机验收、安装、提交、合并。原提示 `common.md` 明确禁止本沙箱尝试编译／测试，仍由主会话在沙箱外执行。第二轮主会话的构建、定向与全量通过仅适用于当时源码，不能代替本轮过滤器修复的绿／红证据。
- BLOCKED：JEV `jev_decide` 请求返回 `MCP tool call requires approval, but approval policy is never`，模型请求未执行，未得到判断或实际模型标识。已检查工具 schema（无可指定模型参数），没有添加旧模型标识或以重复调用寻求批准。方案与源码仍需主会话独立复核。
- 第二轮没有改产品实现：当前 `clear` 删除两个键的源码与第一轮 manifest 一致；不为测试二进制残留变异重写正确实现。本批未修改清理阈值、默认范围、选择、确认、执行或恢复规则；仅更改摘要／历史比较和提醒时间语义。第三轮尚未通过构建和 XCTest，不应把 prepared-r3 交付视为已验证、已提交或已合并。
