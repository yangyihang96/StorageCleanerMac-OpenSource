# 批次 r2-u1-followups：第三轮复核处理

2026-10-07，第三轮基线 `0f8240abbe15b44c978c2a59188a831871f6d4f5`，开始时工作区干净。此前四组改动已由主会话提交；本轮只修改代码、测试和文档，准备 `prepared-3/`，不构建、不运行测试、不暂存、不提交。**本轮编译、行为、高度和 AXPress 均待主会话验证。**

已更正此前交接前文的“XCTest 0 项、NOT_RUN、无提交”：这些仅描述当时沙箱内尝试，不代表随后主会话的结果。主会话在沙箱外构建成功，112 项定向测试通过并创建四个提交；本轮不能继续沿用“尚未编译、尚未提交”的旧批次结论，也不能借前两轮通过声称第三轮通过。

## 1. 范围与证据

- worktree：`/Users/developer/Developer/sc-worktrees/r2-u1-followups`；分支 `task/r2-u1-followups`。
- 输出：`/Users/developer/Developer/.sc-build/r2-u1-followups/prepared-3/`。此前 `prepared/` 和历史日志保持原样。
- 只改本 worktree；不改 `ScanStore.swift`、DECISIONS、BOARD、名单、活动阈值或受保护内容策略。新增测试沿用 `CleanPlanBuilder.makePlan`，不调用 `fileprivate` 初始化器，不放宽产品访问级别。
- 测试的真实文件仅在显式开启的临时／scratch 计时夹具中创建；预算测试的偏好套件使用临时目录绝对路径，语言仅用 volatile argument domain。没有新增写真实 `~/Library/Preferences`／`~/Library/Caches` 的路径。
- 没有安装、启动应用、硬件写入、push、读取凭证或沙箱绕过。这里的原生界面验证仅是给主会话的待执行步骤。
- `r2-u1-followups-review/` 下找到了复核日志，未找到独立的完整意见报告，处理范围以用户摘要为准。`test-head.log:161` 记录 P1-1 的既有契约失败；`test-temp-probe.log:16-17` 记录双风扇同步 280.0 pt／未同步 304.0 pt；`test-temp-probe2.log` 记录取消／跳过回执保存失败后留下未知移动意图。

## 2. 第三轮改动

### 2.1 风扇契约、预算与读屏（P1-1、P2-2、P2-5）

既有 `GeekSensorsPowerHoverDetailTests.testFanModeUsesSingleChoiceControlsWithoutFakeManualAccess` 的 `FanSyncToggleRow(` 断言改查 `FanControlInlineControls.swift`，并检查调用只有一个、主面板没有额外同步开关。**依据 U1 117/118、D53：这里只改布局，三种模式仍是单选卡，唯一开关仍是手动区同步开关，草稿／应用语义不变。** 没有删除“必须有开关”的断言。

紧凑多风扇手动区把同步开关固定在首行，未同步时目标风扇选择器共用首行；目标百分比放在滑杆旁，实际／草稿目标转速仍保留。非紧凑选择器保留原行。面板局部组间距从 6 pt 调到既有的 4 pt 行间距，保留模式卡字体、最小 36 pt 高度与同步开关最小 24 pt 点击高度。

`ControlPaletteTests` 分别覆盖双风扇同步与未同步，中英文、深浅色、紧凑和展开状态；原 ≤280 pt 断言保留，另要求两种紧凑状态各 ≤276 pt，至少留 4 pt 余量。语言切换增加缓存失效通知及 `L10n.usesChinese` 断言。复核 r3 实测同步、未同步均为 **274.0 pt**（中英文 × 深浅色）。余量来自把风扇面板根栈间距从 6 pt 改为 4 pt；这个间距由主会话决定接受，并已写进 `docs/mini-window-design.md`。

`FanControlModeCardTests.testVoiceOverPressTogglesFanSyncWithoutMovingTheSwitch` 只托管本地草稿控件：中英文检查 On→Off→On 原生 AXPress、禁用时不改草稿、目标风扇出现／收起时开关纵坐标不变、点击高度保留。帧探针仅在 DEBUG 编译。既有模式卡 AXPress、圆形标记和高度断言保留；保留的源码契约用 `r2SourceDeclaration` 按声明自身的括号范围取片段，不再把“下一函数／类型的位置”当作边界。

### 2.2 预检原因、写入复查与取消（P2-1、P2-3、P2-4、P2-5）

**预检原因**：同一 `SafeCleanupExecutor` 按不可变 `CleanPlanID` 保留最新完成预检的报告；重新预检先清掉该计划旧报告，执行时取出并移除，在局部执行上下文 `preflightSkipReasons` 中带上原原因。未获批准的行用原预检跳过原因；没有原因时仍回落 `.preflightNotApproved`。原因只用于未批准行的展示，不批准移动，不跨计划借用，也不缓存／复用批准行的修改时间。`ScanStore` 原有“同一执行器预检→仅传 ready IDs→执行”的调用无需修改。

新增 `CleanupExecutionSafetyTests.testPreflightStillInUseReasonsSurviveTheExistingConfirmationRoute` 使用一项 ready＋一项 skipped 的真实冻结计划，分别覆盖新写入和应用运行；要求原原因进入执行报告、仍在使用分组及 JSON 往返，未批准行绝不调用移动器，ready 行仍执行。原 `testExecutionNeverMovesAnItemSkippedByConfirmedPreflight` 保留，继续验证没有原因时的通用回落。

**检查时机更正**：执行入口先核对功能、会话、规则集版本、计划是否已用和批准集合，然后持久化整份未处理计划。每项的两次意图前 `skipReason(rechecksWrites: false)` 仍核对冻结规则字段与开发者活动策略、身份、路径、卷、权限、云状态及应用运行；写入目录遍历只在意图保存后的最终 `skipReason` 执行。这里核对的是执行上下文提供的规则快照；不会在三次检查间重新加载规则文件，也不会重新扫描所有名单／受保护子目录。预检一次＋执行一次遍历，既有精确次数断言与“意图保存期间新写入必须跳过”的行为测试保留。

**取消语义更正**：写入探测只在 `Task.isCancelled` 为真时返回给调用方走取消分支。读取器在未取消时抛出的 `CancellationError`，包括子项元数据读取抛错，沿用读取失败类 `.permissionChanged` 保守跳过；子项的这种错误不再被 `try?` 吞掉。新增 `testReaderCancellationErrorWithoutTaskCancellationIsSkipped` 分别覆盖根目录枚举和子项读取、执行与预检，要求不放行、不移动、不批准。

任务真正取消时，执行报告在保存成功条件下为 `.cancelled`，当前和后续项 `.notProcessed`。意图后的取消分支立即写取消检查点，再读容量、写最终回执；新增 `testCancelledTraversalCheckpointsBeforeAFailedFinalReceipt` 注入最终保存失败，要求最后成功的持久记录已经是 cancelled／notProcessed，无未知移动意图、无移动。若检查点本身也失败，仍可能保留旧意图，不能承诺所有磁盘失败下都落盘。

原“界面显示已取消”说法过宽：`CleanFailurePresentation` 能把 `detailCode=cancelled` 本地化，预检返回失败且不批准；但 `ScanStore.requestV2Cleanup` 的失败分支仍使用通用预检提示。只有直接走该本地化出口的界面／测试可证明“已取消”文案，不能声称真实预检界面一定显示它。本轮依约不改 `ScanStore`。

两个取消测试改为在注入读取器第 256 次读取时取消当前任务，然后 `await task.value` 等待结果；同步读取器不能 await，采用确定位置的取消避免阻塞并发线程池。已移除 `DispatchSemaphore.wait()`，原 ≤512 次读取、零移动及报告断言保留。2 万真实文件计时测试在入口要求 `STORAGE_CLEANER_RUN_TIMING=1`；默认 XCTest skip 是用户明确要求的基准开关，不是绕开产品断言。

**P2-4 可选重排未采用**：唯一写入遍历仍在移动意图之后。提前会漏掉持久化意图期间的子项写入；维持该安全断言就需要再加一遍，违反“不重新引入多遍遍历”。因此保留顺序，完成“取消后立即检查点”，并记录剩余风险：新写入被跳过后，若跳过检查点和最终回执都失败，持久记录仍可能停在 `interrupted-move-needs-verification`，但并不证明调用了移动。

### 2.3 完成页和操作记录（P2-6、P2-5）

完成页仍保留完整跳过原因与重新扫描建议。操作记录改为“仍在使用，已跳过 · 扫描后有新写入或变化”，英文为 `Skipped: still in use · Written or changed after the scan`；应用运行使用自己的具体原因，不重复 skipped／已跳过。

`CleanupReportSkipPresentationTests` 发送 defaults 变更通知让 L10n 缓存失效，先断言实际语言，再分别与中文／英文常量比较。`OperationRecordLabelTests` 把按两个函数先后顺序切片的源码断言改为行为断言：保留统一分组标题与具体原因的要求。仅保留必要的视图接线／禁止 rawValue 契约。

**清理浮层更正**：`CleanupReportIssueList` 被完成页使用；另有浮层视图实现复用它，但浮层未接入产品流程。文档和注释不再把它当作已接入界面。

## 3. 历史验证与计时：已更正

这些是读取既有主会话日志／交接得到的历史结果，本轮没有重新运行。

| 阶段 | 既有结果与证据 |
|---|---|
| 前两轮沙箱内尝试 | 当时 SwiftUI 宏服务被 sandbox-exec 阻断，实际 XCTest 0 项；这是历史环境结果，不是当前源码编译失败结论 |
| 主会话 build --build-tests | exit 0；`logs/main-build-2.log`／`main-build-3.log`，CleanPlanBuilder 夹具修正可以编译 |
| 主会话定向验证与恢复后复跑 | 112 项，0 失败；`logs/main-targeted.log`／`main-targeted-2.log` |
| 风扇反证 | 47 项中 4 处失败；`logs/rev-fan.log` |
| 复查反证 | 6 项中 9 处失败；`logs/rev-recheck.log` |
| 跳过分组反证 | 撤去接口导致构建失败；源码契约 7 处失败。不是完整行为反证，应保留接口再只撤回语义补做 |
| 已有四个提交 | `dc8bc8d`、`fe4192d`、`85bc706`、`713319c`，均早于本轮基线 |
| 额外 HEAD 复核 | review 的 `test-head.log`：94 项、1 失败，即 P1-1；不是 112 项集合之外所有契约均通过 |
| 本轮构建／测试／反证／提交 | **NOT RUN**，按用户要求没有启动；没有测试 exit code 或新提交 |

同一 20,000 文件夹具，旧方案与前两轮方案的计时，以日志实测为准：

| trial | 改前预检／执行／合计（s） | 改后预检／执行／合计（s） |
|---|---|---|
| 1 | 1.238／3.561／4.799 | 1.298／1.174／2.472 |
| 2 | 1.263／3.882／5.145 | 1.140／1.178／2.318 |
| 3 | 1.183／3.649／4.831 | 1.206／1.129／2.334 |

改前合计 **4.80–5.15 s、遍历 4 次**，改后 **2.32–2.47 s、遍历 2 次**。来源是 `logs/rev-recheck.log:31-33` 与 `logs/main-targeted-2.log:258-260`；不是沙箱内失败命令的耗时，也不是第三轮的新实测。review 另一次受负载影响的计时保留在其日志，不替代这组对比。

## 4. Flutter 来源更正与限制

本轮只更正引用，不改归类：保留 `developer.flutter-cache`、D22 活动分档及现有排除／保护策略；没有读取本机真实缓存。历史抓取文件仍在 scratch 的 `logs/flutter-current-*`。

- [Darwin 缓存路径实现](https://github.com/flutter/flutter/blob/master/engine/src/flutter/fml/platform/darwin/paths_darwin.mm#L20)：`GetCachesDirectory` 从 `NSCachesDirectory`／`NSUserDomainMask` 取缓存目录；此前 L21 更正为函数起点 L20。
- [引擎持久缓存创建与保存](https://github.com/flutter/flutter/blob/master/engine/src/flutter/common/graphics/persistent_cache.cc#L113)：创建 `flutter_engine/<引擎版本>/skia/<Skia版本>` 等版本化目录，保存／读取 Skia 缓存数据。
- [缓存接口定义](https://github.com/flutter/flutter/blob/master/engine/src/flutter/common/graphics/persistent_cache.h#L28)：用途主要是着色器缓存，不能把所有内容绝对称为“只有着色器”。
- [运行时 Shell 的缓存接线](https://github.com/flutter/flutter/blob/master/engine/src/flutter/shell/common/shell.cc)：本轮读取官方源码确认 Shell 初始化配置缓存路径／shader cache，替换此前笼统的 `FlutterEngine.mm` 引用。目录名不能确定具体所属应用，也不能证明是开发工具独占缓存。
- [历史不可变持久缓存实现](https://github.com/flutter/engine/blob/ae5c3603d013477d37ae301993fc0967d4ad7ed2/common/graphics/persistent_cache.cc#L113) 保留，便于对照旧 engine 仓库。

`flutter_engine` 具体本机所属应用及所有内容未核实；修改时间复查仍有时间还原、不可读子目录、深度上限、非最大修改时间变化与 TOCTOU 盲区，详见 `docs/cleanup-rules.md`。

## 5. 主会话验证：红、绿、反证

先使用本 worktree 独享 scratch 在沙箱外编译测试，设 `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，`--jobs 4`。不在本沙箱执行，不使用旧 XCTest 二进制冒充本轮结果；所有反证在隔离源码副本／逐字节备份上进行，不改本基线提交、不覆盖其他改动。

建议定向集合：`ControlPaletteTests|FanControlModeCardTests|GeekSensorsPowerHoverDetailTests|CleanupWriteRecheckTests|CleanupExecutionSafetyTests|CleanupJunkActionableTests|CleanupReportSkipPresentationTests|OperationRecordLabelTests|OperationResultPresentationTests|CleanupReceiptHistoryTests|CleanupRuleScannerTests`。兼跑既有 `UIConsistencyRegressionTests/testSmartScanCleanupKeepsSquareSelectionAndDedicatedSafetyPages` 和 `ExternalMigrationReceiptTests/testTheRestoreBannerOnlyShowsAResultFromThisVisit`。不要求全量测试，不放宽阈值或删断言。

| 项目 | 红：基线／撤回目标 | 绿：本轮要求 | 反证：仅撤回产品语义，保留测试接口 |
|---|---|---|---|
| P1-1 风扇契约 | `0f8240a` 的既有方法在旧文件位置失败，已有 review 日志 | 方法在新位置通过，手动区只有一个同步开关 | 临时移除手动区 `FanSyncToggleRow` 调用，存在／唯一性断言须失败；恢复旧文件位置断言也应重现原失败 |
| P2-2 预算 | 新增未同步方法在旧布局测 304.0 pt；同步原 280.0 pt 不能满足新增 ≤276 pt | 两种状态、中英文、深浅各实测 ≤276 pt；原 ≤280 pt、单风扇、展开状态均保留 | 只还原面板间距／未同步选择器独占行，保留 DEBUG 帧探针；对应高度测试须失败，再逐字节恢复 |
| P2-2 AXPress／位置 | 新 AX 方法配旧独占行布局，应发现未同步时下移 | On→Off→On；标签／值正确；纵坐标不变、点击高度不减；禁用不编辑草稿 | 恢复“选择器在开关上方”布局应触发位置断言；另把按钮动作改为空应触发状态断言 |
| P2-1 原因传递 | mixed ready/skipped 测试配旧执行器，报告变 `.preflightNotApproved` | 两种原因从实际预检进入执行、分组和 JSON；只有 ready 项移动；通用回落测试仍通过 | 保留 context 字段，只关闭预检报告转入上下文或恢复通用返回；原因断言须失败，不能把编译失败算行为反证 |
| P2-3 非任务取消的错误 | 原 `catch CancellationError → nil`、子项 `try?` 会批准／移动 | 根枚举与子项读取、预检与执行均跳过 `.permissionChanged`；当前测试任务未取消、零移动 | 分别恢复 catch 放行和子项吞错，两个分支各须失败；真正取消测试仍须通过 |
| P2-4 取消检查点 | 删除意图后立即检查点，最终容量读取后的保存故障应使最后成功记录停在未知意图 | 最终保存失败时，最后成功记录为 cancelled／notProcessed；零移动 | 只删除新增检查点代码，保留持久化接口；最后成功检查点内容断言须失败 |
| P2-5 计时与语言 | 不设开关须 skip 且不创建夹具；原语言循环第二种语言可能复用缓存 | 默认唯一计时方法 skip；设开关真实测 3 次；中英文常量、usesChinese 都通过；取消方法无 semaphore | 去掉语言失效通知应在第二种语言暴露缓存问题；两种语言结果逐项记录，不以双方都调用 L10n.text 当作证据 |
| P2-6 记录文案 | 旧记录组合与新增精确字符串断言失败 | 两种原因、中英文记录通过，完成页完整原因保留 | 只恢复旧 recordLabel 组合，接口保留；重复用词精确断言须失败 |
| 文档 | 对照历史日志和旧说法 | 历史 112 项／四提交、计时、规则时机、预检取消显示边界、未接入浮层、两种高度及官方引用一致 | 改回旧说法，应能由日志／源码直接反驳；不需要为文字改动造形式化测试 |

计时单独在空闲时开启：`STORAGE_CLEANER_RUN_TIMING=1 STORAGE_CLEANER_RECHECK_BENCHMARK_ROOT=/Users/developer/Developer/.sc-build/r2-u1-followups/benchmark`，过滤 `CleanupWriteRecheckTests/testTwentyThousandFileWriteRecheckTimings`；保存每轮预检／执行／合计与次数，不能放宽阈值。默认回归报告要明确写“该计时方法按显式开关跳过”，不称所有方法都执行。

按项目要求补 Swift 6 严格并发、私有 API 守卫和空白检查；`script/verify.sh` 若会启动全量或其他未授权阶段，主会话按其相关步骤定向执行，使用独占 `STORAGE_CLEANER_VERIFY_ROOT`、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`。本轮没有执行这些命令。

## 6. 补丁与提交准备

`prepared-3/` 按下列顺序，各含 patch 与 message，另有 `all.patch`、`manifest.json`、`commit-prepared.py` 和使用说明：

1. `01-fan`：风扇布局、两种预算、AXPress、P1-1 契约和声明范围辅助方法（6 文件）。
2. `02-execution`：预检原因、CancellationError、立即取消检查点、取消与显式计时测试（3 文件）。
3. `03-report`：简洁记录原因、真实语言切换、记录行为断言（3 文件）。
4. `04-docs`：cleanup-rules、mini-window-design、上一批更正及本交接（4 文件）。

每份 message 尾部保持：

```text
Generated-By: Codex (openai/gpt-6.1-sol)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

manifest 记录仓库、分支、本轮基线和 16 个文件的最终 SHA-256。脚本只给完成验证的主会话使用：检查基线、分支、暂存区和文件／补丁内容未变，按组暂存已有工作区改动并提交；不替代测试、不推送、不安装。本轮未执行。不要在已有改动上重复正向应用 all.patch；主会话如补填实测或修代码，先重新生成对应文档补丁、all.patch 和 manifest，不绕开哈希检查。

## 7. 未解决项

- 第三轮由主会话验证（见文末），复核 r3 补跑严格并发 0 错误；双风扇两种状态均为 274.0 pt。
- P2-4 可选“复查早于意图”未采用；保留意图后遍历的安全优先顺序与持久化失败边界。
- 真正的预检界面取消文案仍走 ScanStore 通用提示，未改该文件；取消报告与展示出口的测试不能替代实机验收。
- 清理浮层未接入，不能声称覆盖了产品里的浮层流程；此前跳过分组反证因删接口编译失败，需主会话按本轮的行为反证补做。
- JEV 已核对可调用的 `jev_decide` 参数：该工具不暴露模型标识参数；实际模型未获运行核验。本轮判断请求被自动审批拒绝：`MCP tool call requires approval, but approval policy is never`。未获得模型判断，未绕过审批；最终 `jev_review` 也被同样的自动审批策略拒绝。没有返回模型标识或判断结果，只做了源码自查，不声称已获 JEV 验收。

## 主会话验证：第三轮（复核意见修复，沙箱外）

| 步骤 | exit | 结果 |
|---|---|---|
| `swift build --build-tests` | 0 | 一次编译通过 |
| 定向 11 类：ControlPaletteTests、FanControlModeCardTests、GeekSensorsPowerHoverDetailTests、CleanupWriteRecheckTests、CleanupJunkActionableTests、CleanupExecutionSafetyTests、CleanupReportSkipPresentationTests、OperationRecordLabelTests、OperationResultPresentationTests、CleanupReceiptHistoryTests、CleanupTrashDeletionTests | 0 | 151 个，跳过 1 个（计时测试，需显式开启），0 失败；复核 P1-1 的契约测试通过 |
| 反证：风扇，两个视图文件还原到上一提交 | 测试 1 | 49 个中 13 处失败 |
| 反证：执行，`SafeCleanupExecutor` 还原 | 测试 1 | 37 个中 12 处失败 |
| 反证：文案，`CleanupExecutionViews` 还原 | 测试 1 | 7 个中 3 处失败 |
| 逐字节恢复后重建并重跑 | 0／0 | 151 个，跳过 1 个，0 失败 |

## 复核 r3 后，主会话补修

- **P1-1**：契约重新把 `FanControlSlider` 纳入“不得直接调用 `fanControl.update/commitManualPercentage`”的检查范围，并要求开关调用写在 `FanManualSliderList` 之内。探针：在滑杆里插入一行禁用调用，测试失败；去掉后恢复通过。
- **P2-1**：紧凑手动区首行改为“左侧固定宽度的目标风扇选择器 + 开关”。开关固定贴在行尾，同步与未同步两种状态下都不横移。测试新增 `maxX` 断言；把版式还原到上一提交后，该测试失败。
- **P2-2**：风扇面板根栈间距用 4 pt，经主会话决定接受，已写进 `docs/mini-window-design.md`；V4 小窗打磨时再统一复看。
- **P2-3**：文档中“待实测”的地方都已填为 274.0 pt。
- **P2-5**：完成页“仍在使用，已跳过”分组下，每行只显示原因和建议，例如“扫描后有新写入或变化，如需清理请重新扫描”，不再重复“已跳过”。
- **P2-4**：预检原因缓存的边界问题列入后续。它只影响未批准行显示的原因，不影响移动授权。
- **验证**：定向 9 类共 130 个测试，跳过 1 个（计时），0 失败。
