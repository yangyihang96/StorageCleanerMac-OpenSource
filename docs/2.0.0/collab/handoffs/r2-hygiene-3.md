# r2-hygiene-3：review-3 P2-A～E

## 1. 基线、范围与验证边界

- worktree：`~/Developer/sc-worktrees/r2-hygiene-3`；分支 `task/r2-hygiene-3`；基线 `db0e3b345d06d4fda97bcb965601fe1e4bb6ae6c`。
- 依据：`common.md`、RULES 全文及第 3 节、D5／D48／D48 补充（10-08）／D55／D60、BOARD R9、`r2-hygiene-2/review/review-3.md` 第 3～5 节、前批交接第 9／10 节。
- 本批拥有 `ScanStore.swift`。所有改动只在本 worktree；scratch 为 `~/Developer/.sc-build/r2-hygiene-3`。
- **构建、严格并发、XCTest、源码反证执行、运行期反证执行及耗时实测均 NOT RUN**。遵守 common.md 的沙箱限制，没有尝试 Swift 构建、测试、提交、安装、应用启动或真实文件／硬件操作。
- JEV：工具元数据确认 `jev_decide` 可见，接口没有模型标识或模型参数；调用返回 `MCP tool call requires approval, but approval policy is never`。状态 **BLOCKED**，没有取得判断，不用它作为完成证据。

## 2. P2-A：生产默认入口与测试操作工厂

`PrivilegedBatteryPowerModeCommandRunner` 新增实例级 `@MainActor @Sendable` provider。默认仍惰性获取 `FanControlCoordinator.shared`；白名单检查、两次取消检查、helper 请求及读回验证不变。`BatteryHealthService` 已有 `powerModeWriter` 参数，其默认值保持原文；读电池的 10 个测试构造点补上工厂的拒绝 writer。

`SettingsView` 将 StateObject 的控制器来源移到实例参数，默认仍为同一 shared；使用 `@autoclosure @escaping @MainActor` 保持 StateObject 的惰性求值。`MenuBarStatusController` 增加惰性 provider，订阅、面板和刷新循环都使用该实例。`GeekDashboardConfigurationStore.applyLive` 经实例 provider 取得控制器，生产隐藏传感器前的四项忙状态检查完整保留。

`ControlPaletteRootView` 和 `MenuBarAdvancedStatusView` **本来已有**实例级 `fanControl` 注入；本批补守卫而不重复修改它们。守卫要求这两类、Settings、菜单栏控制器、配置 store、电池 service／privileged runner 显式注入；FanControlCoordinator 同时要求 `defaults` 与非 nil `requestSender`。可能为 nil 的注入仍拒绝，避免带着标签回落生产单例。

`TestOperationFactory.batteryPowerModeWriter()` 记录 `battery.changePowerMode` 后抛错，沿用 teardown 零意外写入断言。三个旧的 migration coordinator 构造补上拒绝 sender，使它们不安装真实生命周期观察者；原迁移断言全部保留。两个新增运行期测试分别实际经过 `changePowerMode` 到拒绝 writer、经过 privileged runner 到注入 coordinator 的拒绝 sender；它们只使用模拟读数与临时偏好。

## 3. P2-B／C：成员来源与真实 home

类型作用域中声明的成员采用该类型所有赋值的保守并集，包含 setUp、init、写入方法之后的赋值和条件分支；先将赋值绑定到真实声明，再合并，避免同名局部、形参、闭包参数和其他类型的成员污染。局部变量仍使用原可达赋值规则：明确的后续安全赋值可以覆盖旧来源。成员的后续安全赋值不擦除另一方法的危险来源。

`isUnsafeWritePath` 统一等于 `unisolatedHome`，真实 home 派生路径进入创建、写入、删除、移动等原有 sink 时拒绝。补充 tilde／绝对 `/Users/` 路径来源及 userDomain 的非 Library 目录 API，`create: true` 也使用统一判定；Desktop、Trash、Downloads 等包含在内。只读查询与 `TestFileSystem` 隔离根继续允许。报错文案统一为“真实 home 派生路径”。原 argumentDomain 数量白名单、数据模型字符串白名单及 benchmark 拒绝测试唯一清理例外未扩大。

新增源码反证 catalog：`Tests/StorageCleanerMacTests/Fixtures/Hygiene-3/source-cases.json`，**46 份，29 拒绝／17 允许**，由新增 XCTest 自测和外部反证生成器共享。保留前批全部 61 份后为 **107 份，78 拒绝／29 允许**。这些文本不编译、不执行，只交给已构建的守卫读取。

## 4. P2-D：整体时限、弱持有与失败保留

生产 `ScanStore` 仅将旧测试等待钩子换成两个具名任务快照：原六个 producer 的属性名、原八类回执 worker 的 UUID 名。任务登记、原主体、取消、队列刷新和安全判断没有修改。

等待实现移到 Tests 的 `TestOperationReportJoin.swift`，保持旧调用名，整体 deadline 默认 **30 秒**，覆盖 producer、detached 物理读取及后续排队刷新。用独立观察任务 await 每个原 task，同时按完成集合和 ContinuousClock deadline 观察；没有使用必须等待卡住子任务退出的 structured task-group race。10 ms 是状态检查间隔，完成依据仍是原任务退出，不是固定延时后删根。超时／等待被取消时 XCTFail，列出未结束任务并返回其名称。

复核修正（见第 10 节）：工厂 teardown 恢复 `[store]` 强持有，先取消并有界等待再允许夹具删除。额外 gate teardown 仍可弱持有，由工厂作为最终收尾关。`cleanupExecutionTask` 在升级 weak self 前已经开始搬文件，执行阶段未必持有 store，不能因 store 被释放而跳过等待。

如果工厂最终等待失败，`TestFileSystem.preventCleanup` 标记当前 XCTestCase 的所有登记根；严格 remove 报告并保留它们，unlock 不改写被标记根。工厂自身偏好域也保留并报告。不会在任务仍可能使用目录时删除、重试或静默当作成功。主会话须依据任务诊断检查失败根，任务停止后再处理；本批不自动删除超时证据。

新增测试使用不响应取消的物理 read gate，100 ms deadline 必须产生严格匹配的 XCTest issue、指出 worker、在 2 秒内返回，然后开 gate 并实际等到退出。另有空闲 store 释放测试。原两个物理读取／排队刷新断言、15 秒阶段预算全部保留。

## 5. P2-E：解析缓存与扫描范围

- 一次词法遍历同时生成 code／保留字符串视图，raw、多行、嵌套注释和插值规则保留。
- 缓存编译后的正则；每份源码自己的 facts／resolved 缓存包含范围、使用位置和完整 visited 集合，避免循环截断结果污染其他路径。
- 花括号位置查询与括号配对预先计算；每条赋值只绑定声明一次；可达来源、构造及实参解析缓存；推断 `.init` 候选只扫描一次。
- 原全部写入 sink 用同一轮匹配识别，再检查相同标签；没有省略任何文件或 sink。所有 `.swift` 文件继续扫描。
- 新增测试验证前后位置的来源不同、重复查询不增加 facts 求值次数，以及循环成员别名仍检出危险来源。

**耗时 NOT RUN，不能宣称已经恢复至 11 秒。** `benchmark-guard.py` 使用已构建的 db0e3b3／当前守卫，交替扫描相同的最终 Tests 语料，至少三轮，保存语料 SHA-256、文件数、每次 XCTest 内部耗时及进程耗时、中位数和比值。只有两边实际成功执行一次守卫的记录才有效；当前中位数未降低则脚本返回非零，须继续调查。前批 11 s／50 s 是复核报告的历史测量，不充当本批实测。

## 6. 红／绿／反证计划（本会话均 NOT RUN）

| 项目 | 红：复现旧缺陷 | 绿：最终代码 | 安全反证：必须实际失败 |
|---|---|---|---|
| A | 基线守卫读新 catalog，省略入口注入被放行；不编译这些违规文本 | TestOperationFactoryTests、TestFanControlIsolationTests、BatteryHealthServiceTests、FanControlPlanner／ProtocolSafetyTests、原 UI 类；拒绝写请求有记录 | `unexpected-battery-write` 抓住拒绝后 teardown 仍失败；`missing-battery-forwarding` 不调用任何控制器，转发计数断言失败 |
| B | 基线守卫读 setUp/init/晚赋值文本，应出现错误放行 | 新 catalog 自测与全部 107 外部源码反证；保留局部／参数／闭包遮蔽允许样例 | `missing-member-union` 只撤掉测试解析器成员合并，新 catalog 自测失败 |
| C | 基线守卫读 Desktop/Trash/appending(path:) 文本，应出现错误放行 | 真实 home 写位置均拒绝、隔离写入及只读查询允许；全语料守卫零违规 | `library-only-home-guard` 只恢复旧 Library 判定，新 catalog 自测失败 |
| D | 复核原无限等待及工厂强引用位置；禁止故意让旧等待无限卡住进程 | OperationReportTaskLifecycleTests 的 4 项、HeavyWork、CleanupStoreFollowUp、UninstallStoreWiring | `unfinished-report-join` 仅让测试 waiter 提前返回，gate 与真正 teardown 保持完整；`strong-factory-teardown` 释放断言失败；`missing-timeout-issue` 有界等待保留但严格预期 issue 缺失导致失败 |
| E | db0e3b3 的守卫扫描同一最终语料 | 缓存位置／循环自测、107 反证不变；三轮前后中位数降低 | `disabled-facts-cache` 不改变危险来源判定，只禁缓存命中，求值次数断言失败 |

`runtime-case-plan.json` 指定 8 个独立反证，每个只跑一个精确方法；runner 必须核对实际执行 1 项、指定方法失败、无其他失败、诊断存在。编译错误、0 测试、崩溃或超时均不能算反证通过。反证没有恢复 live 写入；runner 用完删除自己新建的 package/build，只留日志。

## 7. 主会话命令

以下在沙箱外执行，**先编译成功再跑任何测试**，每步失败停止并回传本会话。离线依赖来源固定为 RULES 指定目录，不借用其他会话正在写的 build。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-3
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-3"
SC_PREP="$SC_SCRATCH/prepared"
SC_RUN="$SC_SCRATCH/logs/main-$(date +%Y%m%d-%H%M%S)"
SC_CACHE="$HOME/Developer/.sc-build/r2-u1-preselect/debug"
mkdir -p "$SC_RUN" "$SC_SCRATCH/debug"
# 新 debug 根中缺少依赖时复制下列四项；已有时先核对，不能覆盖其他运行。
cp -R "$SC_CACHE/checkouts" "$SC_CACHE/repositories" "$SC_CACHE/artifacts" \
  "$SC_CACHE/workspace-state.json" "$SC_SCRATCH/debug/"
set -o pipefail
swift build --build-tests --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-tests.log"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter 'TestPreferenceHygieneTests|TestOperationFactoryTests|TestFanControlIsolationTests|OperationReportTaskLifecycleTests' \
  2>&1 | tee "$SC_RUN/focus.log"
SC_FILTER="$(paste -sd '|' "$SC_PREP/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_SCRATCH/debug" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/targeted-88.log"
python3 "$SC_PREP/run-source-counterproofs.py" "$SC_SCRATCH/source-counterproofs/cases.json" \
  --build "$SC_SCRATCH/debug" --logs "$SC_RUN/source-counterproofs"
python3 "$SC_PREP/run-runtime-counterproofs.py" "$SC_SCRATCH/runtime-main-$(date +%Y%m%d-%H%M%S)" \
  --logs "$SC_RUN/runtime-counterproofs" --offline-cache "$SC_CACHE"
```

基线 package／build 只用于编译守卫和运行一个源码扫描方法；不运行旧完整测试，以免故意触达旧默认入口。以下量测由主会话执行，记录真实结果，使用空闲机器：

```bash
python3 "$SC_PREP/prepare-baseline.py" "$SC_SCRATCH/timing-baseline/package"
mkdir -p "$SC_SCRATCH/timing-baseline/build"
cp -R "$SC_CACHE/checkouts" "$SC_CACHE/repositories" "$SC_CACHE/artifacts" \
  "$SC_CACHE/workspace-state.json" "$SC_SCRATCH/timing-baseline/build/"
swift build --build-tests --package-path "$SC_SCRATCH/timing-baseline/package" \
  --scratch-path "$SC_SCRATCH/timing-baseline/build" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-timing-baseline.log"
python3 "$SC_PREP/benchmark-guard.py" \
  --baseline-package "$SC_SCRATCH/timing-baseline/package" \
  --baseline-build "$SC_SCRATCH/timing-baseline/build" \
  --current-build "$SC_SCRATCH/debug" --logs "$SC_RUN/guard-timing" --runs 3
```

若需要重新取得 P2-A／B／C 的红证据，在上述基线构建后只运行基线源码守卫读取新文本：

```bash
for SC_CASE in missing-BatteryHealthService setup-member-standard home-Desktop-write; do
  STORAGE_CLEANER_TEST_SOURCE_ROOT="$SC_SCRATCH/source-counterproofs/$SC_CASE/Tests" \
    swift test --skip-build --package-path "$SC_SCRATCH/timing-baseline/package" \
    --scratch-path "$SC_SCRATCH/timing-baseline/build" --jobs 4 \
    --filter 'TestPreferenceHygieneTests.testTestSourcesUseTemporaryDomainsAndDoNotPersistStandardDefaults' \
    2>&1 | tee "$SC_RUN/red-$SC_CASE.log"
done
```

这三个**基线**扫描方法通过代表错误放行，是红证据；最终守卫拒绝同一文本才是绿。禁止编译或执行 probe 中的真实路径／默认入口文本。

量测后由主会话删除本次 timing-baseline package/build，仅保留日志。再完成 Release 全量、Debug 全量、严格并发、源码守卫、小窗性能及 diff 检查。采用项目 verify 时设置 `STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0` 和本批私有 `STORAGE_CLEANER_VERIFY_ROOT`。安装、提交与合并仍由主会话分别处理。

全量前后沿用前批真实偏好／应用数据／Caches 快照和 fs_usage 的 xctest PID 归因；不能把并发已安装 Beta／浏览器自身写入判成测试写入，也不能只靠目录名免责。确认本轮夹具无残留；若超时保留，门禁失败并报告根和任务，不自动清理或重试。

## 8. 静态交付、旧断言与限制

prepared 四组：`01-entrypoints`、`02-source-guard`、`03-bounded-teardown`、`04-handoff`。包含组补丁／提交说明、all.patch、manifest、只供主会话验证后运行的 commit-prepared.py、targeted-classes.txt、静态结果、107 源码反证及 8 运行期反证生成／执行工具、计时与生产归一化工具。

定向 **88 类**，完整包含前批 83 类，新增 BatteryHealthServiceTests、FanControlPlannerTests、FanControlProtocolSafetyTests、MiniWindowConfigurationR2Tests、FanControlPackagingTests；UIConsistencyRegressionTests 与 TestPreferenceHygieneTests 保留。

**没有删除旧断言，没有放宽原阈值，没有跳过测试。** 旧方法只调整构造和 teardown 捕获；两条断言中的构造表达式有签名同步，依据 D48 及本批 P2-A 显式注入要求，比较语义不变，逐条列明：

- `MiniWindowConfigurationR2Tests.testDraftCancelApplyAndRestartPreserveCommittedSettings`：重新构造配置 store 时增加 `fanControlProvider`，仍逐值比较重新打开后的 configuration 与 `owner.configuration`。
- `MiniWindowConfigurationR2Tests.testMalformedSavedConfigurationRecoversDefaults`：构造配置 store 时增加 `fanControlProvider`，仍要求损坏数据恢复为 `.defaultValue`。

其余旧业务／源码断言原文保留。新增 7 个测试方法；超时自测使用严格 issueMatcher，只有故意卡住的 read gate 超时 issue 被认领，其他错误仍失败。

静态结果见 prepared/static-checks.json 与 production-equivalence.json：git diff --check、旧测试方法保留、定向覆盖、Python 语法、补丁独立重放／文件 SHA-256；移除列明的注入与观测钩子后 5 个生产文件与基线逐字节相同。静态字节相同不等于运行期验证。

待主会话验证：Swift 6 actor/Sendable 与 SwiftUI 编译、全部定向／门禁、107＋8 反证、JEV 不可用的独立复核替代、真实状态归因以及实际扫描耗时。词法守卫仍不是完整 Swift 跨函数参数分析器；本批覆盖类型成员来源，没有声称补齐 review-3 中未列入本批的任意辅助函数参数传播。

## 9. 主会话第一轮验证后的 r2 修正

### 9.1 基线与已取得的证据

主会话已把前四组提交为 `bc170bf1`、`34d25f6e`、`dd763c7e`、`c30093cc`，trailer 为 `gpt-6.1-sol`。本次修正基线为 **`c30093ccd383053ab72192e8372117e0efb4ae91`**，交付目录为 `~/Developer/.sc-build/r2-hygiene-3/prepared-r2/`；原 prepared 交付保留。

主会话报告编译通过。已读取 `failures-r1.txt` 和 `logs/main-test-1.log`：原 88 类共 **1411 项、跳过 12、失败 2**。日志中的全语料守卫耗时为 **50.277 秒**，整轮 410.372 秒。这是 c30093cc 第一轮结果，不能当作本次 r2 的绿证据，也不能据此声称 P2-E 已降至 11 秒。

本沙箱仅修改测试、源码守卫和文档并生成交付；**r2 构建、XCTest、运行反证、扫描耗时与提交均 NOT RUN**。JEV 的既有审批阻断仍未解除，没有取得新的判断。

### 9.2 调色板源码契约同步（第一项失败）

`ControlPaletteTests.testFixtureFactorySealsTransportAndBothPaletteRoutesReuseProductionContent` 的旧断言 `controller.contains("paletteFanControl = .shared")` 与前轮实例注入后的写法不符。依据 **D48 补充（10-08）②生产默认惰性单例、③源码契约可随注入调用写法同步**，以及本批 P2-A 的实例入口注入要求，把这条旧字面量断言改为四条明确契约：

1. provider 参数的生产默认表达式仍是 `{ FanControlCoordinator.shared }`。
2. `fanControl` 仍经 `private lazy var fanControl = fanControlProvider()` 惰性取得。
3. DEBUG/BETA 非演示分支和非 DEBUG/BETA 分支都取 `paletteFanControl = fanControl`。
4. 上述取值恰好出现两次。

原演示分支 `makeReadOnlyFixture`、其 sender/serviceRegistrar 拒绝、禁止 selectMode/publishObservedMode、实际根视图传入 `paletteFanControl` 等断言全部保留。生产默认仍是实际单例；演示仍是只读夹具；显式注入能到达两条非演示路由。本次 **`git diff c30093cc -- Sources` 为空**，没有修改生产默认值或安全检查，没有删除测试、放宽阈值或跳过测试。

### 9.3 四条守卫告警的逐条判定（第二项失败）

| 日志中的告警 | 判定与根因 | 精确修正与边界 |
|---|---|---|
| FanControlPlannerTests：requestSender 可能为 nil | **误报**。`testSlowFanUnlockUsesFanWriteTimeoutInsteadOfGenericXPCTimeout` 显式传闭包；`try? await Task.sleep` 在闭包内部，返回值是 FanControlHelperReply，闭包本身非 nil | 仅完整 `{ ... }` 闭包字面量（及已有括号解包后的同一值）获得非 nil 证明；不把内部 try?/可选数据当成闭包存在性的证据 |
| FanCurveCoordinatorTests：requestSender 可能为 nil | **误报**。`testApplyValidatesThenActivatesAndNeverSendsGenericRPMWrites` 显式传闭包；内部 state 是可选数据，`state?.targetRPMByFan` 不使 sender 可选 | 同一闭包值修正；可选类型声明/参数在解析值后仍重新合并 mayBeNil，因此 `Sender?` 即使初始是闭包仍拒绝 |
| RuntimeWorkflowPresentationTests：createDirectory.at 真实 home | **误报**。输出目录来自 `STORAGE_CLEANER_RUNTIME_SNAPSHOT_DIR`；`/Users/example/...` 是展示用 currentItem。旧 expressionRange 把 `if let path = environment[...] { ... }` 的整个语句体吞进 RHS，经 bitmap→host→root 连到展示字符串 | if/guard/while 的直接条件绑定在 RHS 后的顶层语句花括号前终止；嵌套括号/实参闭包仍按原配对跳过。条件标识只向前读紧邻关键词，不重扫整个类型/函数前缀 |
| RuntimeWorkflowPresentationTests：write.to 真实 home | **误报**。与上一条同源；写入位置是 directory，不是展示字符串 | 相同 RHS 边界修正，仍独立扫描整个源码中的 sink、赋值和条件体；真实 home 进入 RHS 或在条件体内被另行写入依旧拒绝 |

没有更换这些测试的非 nil 模拟 sender，没有扩大白名单，没有跳过任何文件或 sink。闭包值修正只清除该值的 nilOnly/mayBeNil，**standard/shared/live/真实 home 等危险来源仍保留**。未知环境变量值在既有来源规则中不等于已知真实 home；这里仅消除与展示内容之间的错误传播，不宣称任意环境变量目录都已被证明隔离。

### 9.4 新增反证与红／绿方案

共享 JSON catalog 从 46 份增为 **59 份（37 拒绝／22 允许）**；新增 **13 份（8 拒绝／5 允许）**。已有 46 份逐项保留，外部源码反证保留前批 61 份后共 **120 份（86 拒绝／34 允许）**。所有危险样例都是惰性文本，只由已构建的守卫读取，绝不编译或执行。

新增允许样例覆盖 try? sender、内部可选 state、闭包别名、括号闭包和展示路径与输出目录独立。新增拒绝样例覆盖可选 sender 变量（含闭包初值）、nil sender、括号可选 sender、闭包 live 捕获、shared provider、条件绑定真实 home、条件体独立真实 home 写入、guard 后真实 home 写入。新样例通过现有 catalog 自测方法和外部逐份源码守卫运行，不增减任何旧 XCTest 方法。

| 修正 | 红证据 | 绿（主会话执行） | 反证（必须实际失败） |
|---|---|---|---|
| 调色板契约 | 第一轮日志中的 ControlPaletteTests:95 失败，已取得 | 修正后的精确方法通过；两条非演示注入与演示只读封闭同时保留 | `palette-bypasses-injection` 只把测试读取的文本中的两条注入路由改为 .shared，要求该方法失败；不修改/运行任何生产入口 |
| 闭包存在性 | 第一轮两个 sender 告警，已取得；新增允许样例在旧判定下也应误报 | catalog 自测、两个实际类和全语料守卫通过；nil/可选/shared/live 样例继续拒绝 | `missing-closure-nonnil-proof` 只撤销非 nil 证明，要求 catalog 自测因 `r2-explicit-sender-try-optional-allowed` 失败 |
| 条件绑定 RHS | 第一轮两个输出目录告警，已取得 | 实际 RuntimeWorkflowPresentationTests、catalog 自测和全语料守卫通过；if/guard/条件体真实 home 写入仍拒绝 | `conditional-binding-absorbs-body` 只恢复吞入语句体，要求 catalog 自测因 `r2-runtime-display-path-independent-output-allowed` 失败 |

r2 的 `runtime-case-plan.json` 在最终 c30093cc＋r2 副本上保留前 8 项、增加上述 3 项，共 **11 项**。每项精确运行 1 个方法，必须核对指定断言失败和诊断；编译失败、0 测试、崩溃、超时不能算通过。旧 prepared 的 runtime 工具只重建原 db0e3b3＋首轮补丁；最终复核应使用 **prepared-r2 工具**。

### 9.5 主会话复跑命令

r2 `targeted-classes.txt` 完整保留原 88 类（含前批 83 类），补入 FanCurveCoordinatorTests、RuntimeWorkflowPresentationTests，共 **90 类**。本次没有改两个类的实现，但它们是误报修复必须复核的实际语料。

以下仅供沙箱外主会话执行，每步失败停止。debug-r2 必须是新的本批私有 build 根，离线缓存只读复制。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-3
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-3"
SC_PREP="$SC_SCRATCH/prepared-r2"
SC_BUILD="$SC_SCRATCH/debug-r2"
SC_CACHE="$HOME/Developer/.sc-build/r2-u1-preselect/debug"
SC_RUN="$SC_SCRATCH/logs/main-r2-$(date +%Y%m%d-%H%M%S)"
test ! -e "$SC_BUILD"
mkdir -p "$SC_BUILD" "$SC_RUN"
cp -R "$SC_CACHE/checkouts" "$SC_CACHE/repositories" "$SC_CACHE/artifacts" \
  "$SC_CACHE/workspace-state.json" "$SC_BUILD/"
set -o pipefail
swift build --build-tests --scratch-path "$SC_BUILD" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-tests.log"
swift test --skip-build --scratch-path "$SC_BUILD" --jobs 4 \
  --filter 'ControlPaletteTests|TestPreferenceHygieneTests|FanControlPlannerTests|FanCurveCoordinatorTests|RuntimeWorkflowPresentationTests' \
  2>&1 | tee "$SC_RUN/focus.log"
SC_FILTER="$(paste -sd '|' "$SC_PREP/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_BUILD" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/targeted-90.log"
python3 "$SC_PREP/run-source-counterproofs.py" "$SC_SCRATCH/source-counterproofs-r2/cases.json" \
  --build "$SC_BUILD" --logs "$SC_RUN/source-counterproofs"
python3 "$SC_PREP/run-runtime-counterproofs.py" "$SC_SCRATCH/runtime-r2-$(date +%Y%m%d-%H%M%S)" \
  --logs "$SC_RUN/runtime-counterproofs" --offline-cache "$SC_CACHE"
git diff c30093cc -- Sources
git diff --check
```

计时仍沿用第 7 节的 `prepared/prepare-baseline.py` 和 `prepared/benchmark-guard.py`（db0e3b3 对比最终 r2，扫描同一最终语料），把 `--current-build` 改为本次 `debug-r2`、日志放进本次 SC_RUN。其余全量、严格并发、真实状态归因、夹具残留门禁和主会话复核仍按第 7 节执行。没有本次耗时实测，P2-E 性能结论仍待验证。

### 9.6 静态交付与限制

prepared-r2 三组：`01-palette-contract`（1 个测试文件）、`02-guard-precision`（TestSourceFacts＋共享 JSON）、`03-handoff`（本节）。共 **4 个文件**，提交说明 trailer 均为 `gpt-6.1-sol`。附 all.patch、manifest/SHA-256、commit-prepared.py、static-checks.json、90 类清单、120 源码反证生成/执行工具及 11 项安全运行反证计划/工具。

静态校验范围：diff --check、相对 c30093cc 生产目录零改动、旧方法保留、原 catalog 和 88 类清单保留、Python AST、逐组补丁在独立 scratch 的重放及最终文件 SHA-256 一致。**这些不替代 Swift 编译或 XCTest 通过**。词法守卫的条件绑定修正针对紧邻 if/guard/while 的直接绑定；它不是完整 Swift 语法分析器，未声称新增任意辅助函数参数传播能力。

## 10. 独立复核后的 r3 修正

### 10.1 基线、已验证结果与本轮边界

基线 **`7cf30209534590051a9b1b1df83be070ad6946d7`**，分支/worktree 不变。交付 **`~/Developer/.sc-build/r2-hygiene-3/prepared-r3/`**；原 prepared、prepared-r2 保留为历史交付。

已读 review/review-1.md 全文、review scratch patch 以及 probes 下全部 48 份文本。主会话 r2 日志确认：**90 类、1419 项、跳过 12、0 失败**，全语料守卫 **50.426 秒**；两份 summary.json 确认源码反证 **120/120（86 拒绝、34 允许）**、运行期 **11/11**。独立 Claude 结论为“修后可合并”，P1 必须修复；review 的正则比对/计时和弱/强探针结果属于复核员证据，不是本会话重跑。

**本轮编译、XCTest、运行反证、严格并发、计时、提交均 NOT RUN。** 只进行了代码/文档修改、惰性探针准备和静态校验。复核员的 JEV 判断按报告归属 Claude；本实现会话没有新的 JEV 判断，既有审批阻断不能当作成功调用。

### 10.2 P1-1：工厂必须持有 store 到收尾结束

`TestScanStoreFactory` 改回 `[store]`，移除弱引用失效时的直接返回。所有 producer 仍先取消、按统一 30 秒 deadline 实际等待，然后循环等待 worker/排队刷新；只有完成后才允许更早登记的夹具/偏好清理。生产 `ScanStore` 的 weak self、执行器、任务登记和取消逻辑完全没改。

把复核员的探针改为正式 `CleanupStoreFollowUpTests.testFactoryTeardownWaitsWhenTestExitsDuringCleanupExecution`：两项隔离缓存、带 gate 的 mover，第一项进入后释放局部 store 并退出测试方法。gate teardown 先打开；登记在工厂之前的检查在工厂 join 后、原夹具删除前运行，要求第一项移动已结束，第二项未启动，夹具仍存在。mover 的 0.5 秒不可取消暂停沿用复核探针，模拟物理 syscall；收尾依据是真正任务完成，不按固定延时删除。

反证安全网独立保存 producer 的任务句柄，绝不通过 weak store 找任务。即使故意把工厂改坏、后置检查发现移动未完成，也先取消并有界 join 这些句柄；10 秒失败时标记保留本测试根并报告，避免为了制造红证据而让删除与搬文件竞跑。

**旧契约改写（依据 RULES §3、用户本轮明确修法及 DECISIONS 的 D48 r2-hygiene-3 复核补充）：**

- `testFactoryTeardownDoesNotKeepAnOtherwiseIdleStoreAlive` 改名为 `testFactoryTeardownKeepsStoreAliveUntilItsJoin`；将“释放局部引用后必须为 nil”改为“工厂收尾前必须非 nil”。这是修正错误生命周期要求，不能继续保留原弱持有结论。
- `strong-factory-teardown` 运行反证由 **`weak-factory-teardown`** 替代，要求上面两个精确方法均实际失败（共执行 2 项）。其余已有测试方法/断言保留；第 4 节的不准确说法已直接更正。

顺带处理 P2-7：producer 超时后，若要求 cancelPending，也取消当前 worker 后再列入诊断；夹具报错改用完整 `root.path`。RULES §3 补记强持有、30 秒整体上限、超时保留及主会话确认任务退出后处理的步骤。不会自动删除超时根或重试。

### 10.3 P2-E：消除正则回溯并锁定复杂度

两处正则采用复核 scratch 的准确写法：写入接收者只能从左括号/接收者开始，空白和相关重复改为占有量词；闭包头前导改为 `\A\s*+`。没有改变写入方法集合、匹配后的来源判断或扫描文件范围。另把 expressionRange 换行后的“复制整份剩余源码再 trim”改为在 UTF-16 units 上查下个非空白字符，继续条件仍是 `.` 或 `??`。

新增 `testLongMaskedInterpolationHasBoundedGuardCostAndStillRejectsWrites`：两侧各 1000 个空白夹住 appIDColumn，末尾带真实标准域写入；必须检出恰好一个写入且 **2 秒内**完成。旧正则约 23 秒是 review 合成输入实测，本轮没有自行量测。反证只恢复旧写入正则，不能把编译错误/超时当作复杂度断言失败。

`prepared-r3/benchmark-guard.py` 仍交替至少三轮、同一最终 Tests 语料、记录语料 SHA-256 和 XCTest/进程时间。通过必须同时满足：

1. 当前中位数严格低于基线；
2. **不超过基线一半，或绝对中位数不超过 15 秒**。

因此 50 秒基线下仅约 1% 的改善不再通过。基准包现在导出 **7cf3020**，直接比较本轮前后；生产字节归一化的基线仍是 db0e3b3，二者用途不同。复核给出的 Debug 8.046 秒、Release 2.7 秒只作为外部证据；r3 达标结论待主会话三轮量测。

### 10.4 P2-2、P2-4 与调色板契约

`ComputerHealthStore` 指定构造器原本已有 `batteryPowerModeController`；本轮只给便利构造器增加同一可选参数并透传。默认仍是 nil，指定构造器中 `?? BatteryHealthRuntime.shared` 原文保持。没有重复新增控制机制，也没有改电源/健康数据安全检查。

`TestOperationFactory.batteryPowerModeController()` 返回 Sendable 拒绝替身：只读返回 nil，写入登记 `battery.changePowerMode` 后返回 `.failed`，沿用 teardown 零意外写入规则。新增 `testComputerHealthStoreForwardsToTheRefusingController` 实际经便利构造器调用 store 的改电源方法，要求返回失败且准确登记一次；不进入 runtime/shared/helper。

全测试 `.swift` 构造审计发现 **32 处**未传 controller（比报告点名的 12 处范围更完整），分布在 ComputerHealthIntegration/Models、ControlPalette、MiniWindowLiveReadingRetention/Phase2Review、NetworkSpeedTestService、SafeCleanupLayout；全部补上非 nil 工厂 controller。已有 3 处 BatteryPowerModeChangeTests 的脚本控制器及其它显式注入保留。

守卫加入 ComputerHealthStore 的必传、非 nil 参数，并识别 computerHealthStore 标签下的上下文 .init；禁止 BatteryHealthRuntime/GeekDashboardConfigurationStore/MenuBarStatusController 的 `.shared` 及 FanControlCoordinator 类型标注后 `= .shared`。选择禁止测试直接构造 MenuBarStatusPanelRoot，避免额外改生产视图。MenuBarStatusController 构造器恢复 private，解决可见性扩大；生产 `static let shared = MenuBarStatusController()` 不变，ControlPalette 的原方法追加这条精确断言。

DECISIONS 补记第三条调色板契约与强持有规则。没有再改动旧业务断言；新 shared 默认断言的反证只变更测试读取的字符串，不创建/运行真实控制器。

### 10.5 其余守卫建议：已处理和后续

**已处理：**

- 声明按平衡括号读取类型，覆盖实际 `((FanControlHelperRequest) async throws -> FanControlHelperReply)?/!`；显式 `!` 与可选参数也标记为可能 nil。原概念性 Sender? 样例保留，同时增加真实函数类型样例。
- 顶层三元分支分别分析，nil/可选/shared/live/真实 home 任一分支都保留；与 `??` 的优先关系及常量证明同步保守处理。
- 闭包识别排除 if/else/for/while/do/switch/catch/guard/repeat/defer 语句体；真实实参闭包仍解析参数，补允许的参数遮蔽与拒绝的标准域捕获样例。
- 多子句 if/guard/while 的后续直接绑定也截断语句体，不扩大白名单。覆盖复核 F2/F2b 和新拒绝样例。
- 来源加入 URL.homeDirectory/desktop/documents/downloads/library/caches/applicationSupport/trash/movies/music/pictures、homeDirectory(forUser:)/NSHomeDirectoryForUser、userDomainMask 的 NSSearchPath、environment["HOME"]、pw_dir。只读来源保持允许。
- 隔离根 `appendingPathComponent` 的常量组件/别名与明确常量 URL 构造器的安全 lastPathComponent（排除空值/. /..） 不把虚拟 `/Users` 标签当成写入根。实际 home receiver、实际 home API 组件、三元/coalescing 的真实 home 分支及未知对象同名 lastPathComponent 属性仍保守拒绝，均有对应拒绝样例；处理复核 F1。

**明确后续，未作为允许样例写入 catalog：**

| 缺口 | 理由与后续边界 |
|---|---|
| B1：extension 跨词法作用域的成员来源 | 需要按类型标识合并声明/扩展，并保留同名局部和不同类型的遮蔽；直接合并同名变量会误报。本轮继续只追踪同一类型词法作用域 |
| B4：父类声明、子类赋值/使用 | 需要可解析的继承图/成员归属，不能按文本名字认为所有同名成员互相可达 |
| B2：另一个实例的属性赋值 | 需要接收者类型和对象别名分析；当前 self/局部规则不足，盲目丢掉接收者会污染无关对象 |
| B3：类型名限定的静态成员 | 需要区分类型限定、实例限定和跨类型遮蔽；与前三项一起做类型关系分析，避免增加无法验证的猜测规则 |
| worker UUID 缺少具体登记点名称 | 为每个 worker 加原点需要改变生产任务登记/元数据；本轮 Sources 仅允许注入点，因此仍使用已有 UUID 诊断，producer 名已足够定位清理执行。后续可设计测试侧观测注入 |
| 更深的词法/作用域性能重写 | UTF-16 重写 lexicalViews、合并三个 init 扫描、类型/构造扫描继续缓存等仅为 review 未实测估计；先验证两处已比对正则及本轮复杂度门禁，避免同轮引入大范围解析重写 |

四个已知成员缺口完整保存在 prepared-r3/deferred-probes.json，状态 FOLLOWUP，不是“应允许”。A1 的 BatteryHealthService.shared、A9 的 FanControlCoordinator.RequestSender 不存在，未作为有效 API 漏检回归；实际 BatteryHealthRuntime.shared 和函数类型分别已有正式拒绝样例。

`homeComponents/isRealLibrary/unknownHomeComponent` 保留并在代码注明：用于来源诊断兼容与既有 `library-only-home-guard` 红反证，实际写位置判定只看 unisolatedHome。stringConstant 仍用于明确组件/别名证明，不能删。词法守卫仍不是完整 Swift 类型/控制流分析器，未宣称填满所有辅助函数传播或嵌套语法形式。

### 10.6 红／绿／反证（本轮执行均 NOT RUN）

| 项目 | 红证据 | 绿：主会话执行 | 安全反证：必须实际失败 |
|---|---|---|---|
| P1-1 | review 弱持有 3/3 失败、强持有 2/2 通过 | CleanupStoreFollowUp、OperationReportTaskLifecycle、HeavyWorkIntegration、UninstallStoreWiring 及两个精确生命周期方法 | weak-factory-teardown：恢复弱引用，两个方法均失败；句柄安全网完成后才删除 |
| P2-E | 主会话旧守卫 50.426 秒、review 合成旧正则约 23 秒 | 2 秒复杂度测试、93 类、185 源码反证、至少三轮收紧基准 | backtracking-write-regex：只恢复旧正则，复杂度断言失败；不恢复任何写入口 |
| ComputerHealth 默认入口 | review A10/A11/A12 放行文本 | 工厂转发/拒绝记录测试、32 个实际构造点、全语料守卫 | missing-computer-health-guard 自测失败；unrecorded-health-controller-write 计数失败；unexpected-health-controller-write teardown 失败 |
| shared 默认路由 | 旧契约缺少生产 shared 默认构造检查 | ControlPalette 原方法全部断言通过 | palette-shared-bypasses-default：仅改变被读取文本，新增断言失败；旧 palette-bypasses-injection 保留 |
| 函数类型、IUO、三元 nil | review A5/A6/R2 放行文本 | 真实函数类型和分支正反例 catalog 全部符合预期 | missing-function-type-binding-proof / missing-ternary-proof 使对应拒绝样例自测失败 |
| 语句体与多条件误报 | review F6b/F6d 漏报、F2/F2b 误报 | catalog 的拒绝/允许及真正实参闭包遮蔽样例 | missing-statement-body-proof / missing-conditional-clause-proof 使自测失败 |
| home 新来源与虚拟路径 | review C1～C6 放行、F1 误报 | catalog 新来源拒绝、只读与隔离组件允许、实际 home 分支仍拒绝 | missing-home-source-apis / missing-virtual-component-proof 使自测失败 |

共享 catalog **124 份（85 拒绝、39 允许）**，新增 **65 份（48 拒绝、17 允许）**，原 59 份原文/预期保留。保留外部前批 61 份后为 **185 份（134 拒绝、51 允许）**。所有危险文本仅由已构建守卫读取，不编译、不执行。运行计划 **22 个 variant**（其中 weak-factory 运行 2 方法，其余各 1 方法），保留前轮全部有效反证，替换错误的强持有反证，并增加本轮覆盖；必须核对实际 XCTest 失败、方法和诊断，编译错误/0 测试/崩溃/超时不得计 PASS。

### 10.7 主会话命令与交付

targeted-classes.txt 保留前轮 90 类（及前批 83 类），加 ComputerHealthIntegrationTests、ComputerHealthModelsTests、NetworkSpeedTestServiceTests，共 **93 类**。先编译再测试，每步失败停止回传。本段替代前轮工具/计时基线选择。

```bash
cd ~/Developer/sc-worktrees/r2-hygiene-3
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
SC_SCRATCH="$HOME/Developer/.sc-build/r2-hygiene-3"
SC_PREP="$SC_SCRATCH/prepared-r3"
SC_BUILD="$SC_SCRATCH/debug-r3"
SC_CACHE="$HOME/Developer/.sc-build/r2-u1-preselect/debug"
SC_RUN="$SC_SCRATCH/logs/main-r3-$(date +%Y%m%d-%H%M%S)"
test ! -e "$SC_BUILD"
mkdir -p "$SC_BUILD" "$SC_RUN"
cp -R "$SC_CACHE/checkouts" "$SC_CACHE/repositories" "$SC_CACHE/artifacts" \
  "$SC_CACHE/workspace-state.json" "$SC_BUILD/"
set -o pipefail
swift build --build-tests --scratch-path "$SC_BUILD" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-tests.log"
swift test --skip-build --scratch-path "$SC_BUILD" --jobs 4 \
  --filter 'CleanupStoreFollowUpTests|OperationReportTaskLifecycleTests|HeavyWorkIntegrationTests|UninstallStoreWiringTests|TestPreferenceHygieneTests|TestOperationFactoryTests|ControlPaletteTests|ComputerHealthIntegrationTests|ComputerHealthModelsTests' \
  2>&1 | tee "$SC_RUN/focus.log"
SC_FILTER="$(paste -sd '|' "$SC_PREP/targeted-classes.txt")"
swift test --skip-build --scratch-path "$SC_BUILD" --jobs 4 \
  --filter "$SC_FILTER" 2>&1 | tee "$SC_RUN/targeted-93.log"
python3 "$SC_PREP/run-source-counterproofs.py" "$SC_SCRATCH/source-counterproofs-r3/cases.json" \
  --build "$SC_BUILD" --logs "$SC_RUN/source-counterproofs"
python3 "$SC_PREP/run-runtime-counterproofs.py" "$SC_SCRATCH/runtime-r3-$(date +%Y%m%d-%H%M%S)" \
  --logs "$SC_RUN/runtime-counterproofs" --offline-cache "$SC_CACHE"
python3 "$SC_PREP/production-equivalence.py"
git diff --check
```

计时只构建旧包并运行一个源码扫描方法，不运行旧完整测试。基线 **7cf3020** 与最终 r3 扫描相同最终语料：

```bash
python3 "$SC_PREP/prepare-baseline.py" "$SC_SCRATCH/timing-r3-baseline/package"
mkdir -p "$SC_SCRATCH/timing-r3-baseline/build"
cp -R "$SC_CACHE/checkouts" "$SC_CACHE/repositories" "$SC_CACHE/artifacts" \
  "$SC_CACHE/workspace-state.json" "$SC_SCRATCH/timing-r3-baseline/build/"
swift build --build-tests --package-path "$SC_SCRATCH/timing-r3-baseline/package" \
  --scratch-path "$SC_SCRATCH/timing-r3-baseline/build" --jobs 4 \
  2>&1 | tee "$SC_RUN/build-timing-baseline.log"
python3 "$SC_PREP/benchmark-guard.py" \
  --baseline-package "$SC_SCRATCH/timing-r3-baseline/package" \
  --baseline-build "$SC_SCRATCH/timing-r3-baseline/build" \
  --current-build "$SC_BUILD" --logs "$SC_RUN/guard-timing" --runs 3
```

如需新增入口/来源的旧守卫红证据，只让基线守卫读取 r3-review-A10/C1/A5/F6b 等惰性文本，放行就是红证据；不编译或执行 probe。量测后删除本次 timing package/build，只留日志。完整 Release/Debug、严格并发、小窗性能、真实状态快照/xctest 写入归因及无夹具残留仍由主会话按第 7 节完成；超时保留根须按新 RULES §3 处理，不能忽略门禁。

四组：01-lifecycle（5 文件）、02-guard-speed-precision（3 文件）、03-power-entries（10 文件）、04-docs（3 文件），共 **21 个文件**。含分组补丁/提交说明、all.patch、manifest、commit-prepared.py、static-checks、93 类清单、185 源码与 22 运行反证工具、收紧基准与导出工具、db0e3b3 生产归一化证据。trailer 均为 gpt-6.1-sol。

静态校验：差异空白检查、独立补丁逐组重放/文件 SHA-256、所有旧方法保留（仅上述一个明确替换）、原 59 catalog/90 类清单保留、工具 Python AST、6 个生产文件去掉列明注入/测试观测点后与 db0e3b3 字节相同。**这些不是编译/测试绿证据**。本轮当前可交主会话验证，不能据此称已获合并批准。
