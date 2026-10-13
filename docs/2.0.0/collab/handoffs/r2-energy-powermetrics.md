# r2-energy-powermetrics 交接

> 本轮安全修复以 `c002414b166d42e959ee9a770729b2a29177e2ee` 为基线，承接并保留前任未完成的 10 文件改动。**最终状态以文末“安全复核修复与续接轮”及 scratch `logs/security-fix/validation.json` 为准**。原始交付和“主会话验证轮”的通过记录属于修复前版本，不能继承为当前最终源码的通过证据。

日期：2026-10-09。分支 `task/r2-energy-powermetrics`，基线 `0bd131b2f6e4debb24e1ffeed9bb9aaba71dd6fc`。工作区初始干净。本批仅修改授权 worktree；拥有 `ScanStore.swift` 能耗部分，仅新增一个惰性按需监测入口。

依据：D71③ 固定只读采样及独立安全复核、D65 助手与 Mac mini 模式安全边界、D5 后台不解除充电暂停；同时遵守 common.md、RULES、D48、D55、D60 和当前会话的模型/权限规则。当前基线 BOARD 没有单列本批条目，DECISIONS D71 及派工消息均明确点名本批；未擅改调度看板。

## 实际交付与状态

> 下表是 Codex 准备阶段的状态。构建、测试、反证、Release/Beta 与打包的实际结果见文末“主会话验证轮”，以那一节为准。

| 项目 | 状态 | 证据 / 边界 |
|---|---|---|
| 源码、测试、交接、分组补丁 | 已准备 | scratch `prepared/manifest.json` 列最终文件及产物 SHA-256 |
| 空白与补丁适配检查 | PASS | `prepared/static-checks.json` 记录命令、exit code；包括新文件的补丁检查 |
| 新测试 | NOT RUN | 5 个类、31 个测试方法；沙箱内未执行 |
| Debug / Release / 严格并发 | NOT RUN | common.md 明确交主会话在沙箱外执行 |
| 真机功率、签名拒绝、窗口可见性 | NOT RUN | 没有启动应用、运行 powermetrics 或安装助手 |
| 助手更新、安装、提交、合并 | NOT RUN | 未改 `.git`，未碰 `/Applications`，未写硬件设置 |
| JEV 判断 | BLOCKED | 调用 `jev_decide` 返回 `MCP tool call requires approval, but approval policy is never`；未获得判断或模型标识 |
| 独立安全复核 | NOT RUN | 主会话按下节派新的复核员；准备源码不等于安全复核通过 |

## 改动及理由

1. `FanControlShared/PowermetricsSample.swift`：限定请求为 `samplePowerMetrics` 和协议版本两个键，拒绝额外键、旧版本、大于 512 B 的信封。结构化回复仅有 CPU/GPU/ANE mW、P/E 簇 MHz、GPU MHz、采样时长；故障只有固定枚举。字段缺失为 nil，真实零仍为零，未知单位/非法值不补零。最多 16 簇、名称限定 P/E 加数字，拒绝重复簇。解析一份 NUL 分隔 XML plist，不能把多份样本拼起来。
2. `FanControlShared/PowermetricsSampling.swift`：daemon 全局 actor 合并进行中的请求；开始到开始至少 2 秒，失败也限频；最多 32 个等待者。执行策略把 stdout 与 stderr 合计限制为 512 KiB，超限立即弃整份结果；5 秒到期强制 kill。计时使用 ContinuousClock，包含睡眠时间。策略可以注入时钟、读管道和终止回调，测试不启动特权子进程。
3. `FanControlHelper/PowermetricsProcessRunner.swift`：唯一新增 `posix_spawn`，在自身进程组启动，内部 `static let` 路径/参数固定为 `/usr/bin/powermetrics --samplers cpu_power,gpu_power,ane_power -n 1 -i 1000 -f plist`；固定环境、工作目录 `/`、stdin `/dev/null`。两个管道都是非阻塞读取，每次各至多 16 KiB，没有 `readDataToEndOfFile` 或无限 `waitUntilExit`。超时/超限在自身回收前向负 pgid 发送 SIGKILL；在两条管道 EOF 前保留组长 PID，自身 `waitpid` 回收；旧子进程尚未回收时拒绝启动新子进程。助手 SIGTERM/SIGINT 时先禁止新采样并 kill 活跃子进程，再沿用原风扇与睡眠恢复流程。
4. `FanControlHelper/main.swift`：仍通过原 listener 的 audit-token、证书与 bundle identifier 校验；新操作在同步 XPC dispatch 中使用 `NSXPCConnection.current()` 取 audit token，先按连接做廉价限频，再在独立签名验证队列检查动态代码、团队 `T9GZL52H8R`、当前构建对应的固定应用/可执行文件路径和 helper 所属 app 路径；通过后才检查完整静态 seal，并按连接代次与 audit-token pid/pidversion 缓存通过结果。采样有独立 utility 队列；不占用 smcQueue / commandQueue 执行采样。pending 计数复用现有 admission/idle 逻辑，避免采样期间 idle exit。没有新 pmset 调用或持久化写入。
5. `MacMiniMode.swift`、应用 `FanControlModels` 与 `FanControlCoordinator`：协议按已有方式从 3 升为 4。采样 transport 只编码专用信封；不发送旧风扇/电源字段或参数字符串。回复要求版本/operation 对齐、有效结构化样本，不允许混入风扇、曲线或 Mac mini payload。旧 v3 更新先用仅为移除提供的协议 3 `setMacMiniMode(.off)`，确认 mode OFF 且恢复责任已解除，再恢复自动风扇并注销；保留 v2 仅自动恢复兼容。兼容请求不能开启模式或采样。更新沿用原 `updateMacMiniModeHelper()`，只有用户点击才注销/注册/授权。
6. `HelperPowerMetricsMonitor`、`ScanStore`：共享一个按需流，使用 ScanStore 原有惰性 `fanControlCoordinator`，保留测试注入。监测没有独立的生产单例。只有可见消费者才请求；app 内开始到开始也至少 2 秒；撤销最后一个消费者取消 worker，迟到回复按 generation 丢弃，重新展开不能绕过限频。采样前后都检查助手可用性；不调用 prepare/register/授权页面。
7. `HelperPowerMetricsPresentation`、`HelperPowerMetricsView`、能耗页、小窗电源与传感器详情：显示三项功率和 P/E/GPU 频率；来源为“系统助手 · powermetrics”。缺字段、未批准、失败、过期显示 `—`，未批准说明“需要系统助手”。超过 6 秒的读数不会冒充当前数值。window 可见/遮蔽、最小化、关闭、应用隐藏、系统和显示器睡眠通知控制需求。链接只导航到本应用“设置 › 权限”并滚到系统助手项；该项提供原更新/授权按钮。主窗口使用紧凑三列读数组，小窗用行列表；复用现有字体、按钮样式与 tokens，功率/MHz 格式走 `HardwareReadingText`。
8. `SoCPowerTelemetry.swift`：macOS 26+ 不再显示冻结的旧 Energy Model 计数；保留 SMC 采样、旧系统 IOReport 实现及估算器测试。新分项没有混入整机 SMC 读数、进程归属估算或累计耗电积分。

## 安全复核要点

### 攻击面

- 新增一个现有 root XPC `execute(Data)` 的只读 operation，以及固定系统工具子进程的 stdout/stderr 解析。没有 shell、任意路径、任意参数、任意文件写入、网络或新系统设置操作。
- 入口继续要求现有应用/助手证书匹配；采样还要求固定团队、运行可执行文件路径与 helper 所属安装 app。Beta 为 `/Applications/测试版.app/Contents/MacOS/StorageCleanerMacBeta`，正式版为 `/Applications/存储清理助手.app/Contents/MacOS/StorageCleanerMac`（安全复核修复轮更正：原稿把 Beta 可执行名误写为 `StorageCleanerMac`，代码同样写错，见文末 P1）。开发目录、移动副本、其他团队、符号链接入口均拒绝采样。
- 原风扇/Mac mini operation 的 listener 和 executor 校验没有放宽；新增较严格校验只用于采样。未改原 pmset 白名单或 Mac mini 共享策略锁。

### 输入与边界

- 从调用方只接受枚举与协议版本。任何字符串参数键、风扇/曲线/电源 payload、超长信封都不能进入采样 executor。签名元数据来自 audit-token Security code object，不接受调用方 PID/路径/团队声明。
- 命令参数唯一常量，stdin 禁用；环境未继承调用方。只有 CPU/GPU/ANE 三个 sampler、一次、1000 ms、plist。
- 输出上限是两个管道之和，错误输出也计入；超限不返回部分样本。plist 只取需要的已知字段，输出不包含进程名/PID/机器标识或 raw stderr。
- 簇名称与数量、数值范围、实际采样时长、单位和文档分帧都有边界。标准 PropertyListSerialization 仍需要解析这份受限文档，字段白名单指的是提取/返回的范围；未另造 XML 解析器。

### 权限与生命周期

- 采样只在已经批准/登记的助手上发起，监测不自动安装或弹授权。授权/更新是现有设置按钮的显式行为，沿用 D65 的睡眠恢复门槛。
- pending request 计数防止正常 idle exit；SIGTERM/SIGINT 时用新 childLock 封住 launch、终止活跃子进程。childLock 仅保护 launch/reap/kill，不包围完整采样，也不用于普通风扇、Mac mini 控制。
- startup 恢复未就绪时采样拒绝，不绕过启动失败封锁。旧协议兼容仅用于恢复 OFF / 自动风扇和移除，不兼容未知未来版本。

### 失败模式与独立复核重点

- 未授权、协议/输入错误：不启动进程，不消耗 daemon 全局采样名额；按连接的廉价尝试限频与全局采样节流独立，签名失败、seal 失败和被限频的重试也更新连接尝试时间。繁忙、过频：固定故障，不排积压。
- launch/管道错误、非零退出、超时、输出超限、缺少所有目标字段：不发布样本。超时在 5 秒边界 SIGKILL，轮询粒度为 10 ms；这是软件 deadline，仍受系统调度延迟影响。
- app 隐藏/收起/睡眠不发后续采样；已交给 helper 的一次采样会在有界执行窗口内结束，app 不接收旧 visibility generation 的回复。
- 请独立检查 Security 动态/静态 seal 与路径查验是否绑定同一个运行 code object、原 auditToken 的 KVC 兼容性、安装更新 TOCTOU、`posix_spawn` / 自有 `waitpid` 的进程组终止竞态、终止期间 admission/launch 竞态、管道 EOF、限频 actor 及所有控制队列没有被采样阻塞。完整 seal 查验的实际耗时也应测量，不能仅凭源码推断。
- 源码守卫递归扫描全部 helper/shared 源码，锁定 main 的 pmset Process 与 runner 的唯一常量 posix_spawn、两个允许的 executable、powermetrics 常量参数、原 pmset whitelist 与替代 spawn/shell API。文本守卫不能证明所有潜在别名/动态调用都安全，独立代码复核仍必需。

## 已改写的旧断言

均由 D71 新 operation 和协议 4 的要求引起，没有放宽安全阈值、删除断言或跳过测试。

- `MacMiniModeProtocolTests.testNewRequestsHaveOnlyTheirOwnPayloadAndRoundTrip`：期望当前协议从 3 改成 4。
- `testHelperContractRefusesOldFutureAndMissingVersions`：允许当前 4；拒绝集合改成 nil、1、2、3、5、-1，旧版本 3 仍被 helper 拒绝。
- `MacMiniModeCoordinatorTests.testVersion2RemovalUsesOnlyRestoreCompatibleRequest`：第一条当前 OFF 请求从 `setMacMiniMode:3` 改成 `setMacMiniMode:4`；后续 v2 restore 与注销顺序不变。

## 主会话验证命令

本会话没有执行下述命令。定向类列表在 scratch `targeted-classes.txt`，含 `UIConsistencyRegressionTests` 和 `TestPreferenceHygieneTests`。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-energy-powermetrics
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
scratch=/Users/developer/Developer/.sc-build/r2-energy-powermetrics
swift build --scratch-path "$scratch/debug" --jobs 4
target_filter="$(paste -sd'|' "$scratch/targeted-classes.txt")"
swift test --scratch-path "$scratch/debug" --jobs 4 --filter "$target_filter"
STORAGE_CLEANER_VERIFY_BUNDLE=0 \
STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT="$scratch/verify" \
  script/verify.sh
git diff --check
```

必须把真实 exit code、测试数量与 skipped 数量、日志路径写回交接。若严格并发/访问级别/NSXPC API 编译失败，回到本会话修复，不降低并发检查或删断言。

## 红 / 绿 / 反证

详情见同目录 `r2-energy-powermetrics.counterexamples.json`，scratch 根另有内容相同的 `counterexamples.json`；所有执行状态目前都是 NOT RUN。

- 红：在隔离反证工作区按 JSON 指定突变，保留新测试断言；预期对应测试失败。未改过的基线也没有新 operation/监测入口，新的源码守卫必失败。不要在主 worktree 做突变或用真实硬件写入证明红。
- 绿：最终补丁上跑上述定向类，覆盖单位、缺字段、共享采样、拒绝调用方、降级、旧版本移除与原控制回归；随后完整门禁。编译通过不能替代真实 root XPC 及窗口停止行为验收。
- 反证：额外参数、其他签名/移动 app、1.999 s 重试、32 等待者并发、挂起子进程、stderr 洪水、第二份 plist、缺字段/坏单位、旧 v3 仍拥有睡眠恢复责任、隐藏或睡眠中迟到回复，均必须保持拒绝/未知/停止状态。

## 未验证限制与验收事项

- 解析测试中的 M1、Ultra 多簇及现代 direct-power 是明确标注的结构夹具，并非采集自真实多台机器。原生 `*_energy` 按 mJ/实际 elapsed_ns 转功率；CPU `freq_hz` 按 Hz，GPU 同名原生历史字段按 MHz，同时接受明确单位与不重叠的合理 Hz 范围。必须由主会话用脱敏真机 plist 确认 macOS 26/27 当前机型字段及单位，补入更多真实机型夹具；尚不能声称所有 M1–M5 都已验证。未知字段不会猜为零。
- 本机 `/usr/share/man/man1/powermetrics.1` 可确认 `-i` 为 ms、`-n` 样本数、plist 为 NUL-separated，也提示该工具的子系统功率属于系统模型。UI 因此标注“系统功率模型”，不把它冒称为额外物理测量或可跨机型比较的整机功率。没有读取或复制 Vitals 代码。
- 安装新 helper 后需验证实际 Team ID、路径、root 调用结果、XPC operation/version 回显、空闲/有负载读数，和 5 秒终止的实机证据。助手安装/替换仍按 common.md 留给主会话，并满足用户授权。
- 主窗口起始/结果页与小窗电源/传感器详情，需检查最小尺寸、中英文本、多簇机器、滚动和无助手状态。只有实际展开的相应详情持有可见 probe，概览不请求。截图/demo 模式禁止 live demand，数据夹具不连接真实助手。本批没有截图或窗口运行证据。
- 覆盖全部窗口：切页、收起小窗、关闭、最小化、完全遮蔽、隐藏应用、显示器睡眠/唤醒；关闭最后一个消费者后观察至少两个采样间隔，无新 powermetrics 启动。SIGTERM 期间也不得留下采样子进程。
- 风扇写入、充电、电源、Mac mini 策略的真机操作不在本次源码交付的执行授权中；先用隔离 fake / 原测试证明队列和恢复流程，再由主会话按既有权限边界验收。D5 无新充电动作。
- JEV 工具本轮被自动审批策略拒绝，不声称已调用其模型或得到安全判断；独立安全复核与真实构建均尚未完成。

## 补丁分组

scratch `prepared/`：`01-helper`（受限 DTO/解析/采样执行及相关测试）、`02-client`（应用协议、v3 安全移除和相关回归测试）、`03-display`（按需监测、三处显示、设置导航及降级测试）、`04-handoff`（本交接与反证）。`all.patch` 是依序连接的总补丁。manifest 固定基线、分支、文件 SHA-256、组顺序和产物哈希。`commit-prepared.py` 只供主会话完成构建、定向测试、反证、独立复核后使用，本会话未执行；它核对分支、基线、工作区改动集合、空暂存区、文件/产物哈希，再逐组应用到 index 并提交，不运行/替代验证，也不 push。

提交说明沿用用户要求的 Claude 联署。Generated-By 的 `openai/gpt-6.1-sol` 来自本批 scratch `logs/codex-r1.log:6` 的会话头。未自行切换模型；日志标识不构成后端真实模型身份的独立证明。

## 主会话验证轮（2026-10-09，Claude）

结论：Debug（含测试与 FanControlHelper）、Release、Beta 构建都通过；定向测试与全量 Debug 都是 0 失败；40 条反证全部变红；`--bundle-only` 打包和签名检查步骤通过。安全自查发现并修复了一处源码守卫漏洞（同一行追加参数能绕过），另把调用方路径比较改为与文件系统探测无关的写法。未安装、未启动应用、未注册助手、未执行 powermetrics、未提交。独立安全复核尚未进行。

所有路径相对 scratch `~/Developer/.sc-build/r2-energy-powermetrics`。

### 本轮改动

| 文件 | 改动 | 原因 |
|---|---|---|
| `Tests/.../FanControlPlannerTests.swift` | 测试假助手的 `switch request.operation` 补 `.samplePowerMetrics` | Codex 版本唯一的编译错误（switch 不完整）；只补枚举分支，没有改断言 |
| `Sources/FanControlShared/PowermetricsSample.swift` | `PowermetricsClientPolicy.permits` 改为比较规范路径字符串（`standardizedFileURL.path`、`resolvingSymlinksInPath().path`），另要求 file URL、helper app URL 非空 | 实测 `URL(fileURLWithPath:)` 在目录存在时带尾斜杠、不存在时不带，而助手用 `deletingLastPathComponent` 得到的 app URL 总是带尾斜杠。原写法是否放行取决于一次文件系统探测（安装 app 不在时拒绝，方向安全但不稳定）。新写法仍要求两条路径分别与 `/Applications/<名>.app` 和其中的 `Contents/MacOS/<可执行名>` 完全一致（此处原写 `StorageCleanerMac`，对 Beta 是错的，已在安全复核修复轮更正） |
| `Tests/.../PowermetricsHelperSourceGuardTests.swift` | ① 白名单守卫改为整行匹配：`process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")`、`process.arguments = arguments`、powermetrics 的两行各恰好一行；② 负例加入“同行追加参数”“同行链式改 URL”“pmset 同行追加参数”；③ 新测试 `testCallerVerificationPrecedesTheOnlySamplingEntryAndReplyIsStructured` | 首轮反证 `helper-extra-flag`（`process.arguments = Self.arguments + ["--show-process-energy"]`）**没有变红**：原守卫按子串计数，同行后缀能通过。③ 锁定顺序 解码 → `NSXPCConnection.current()` → 签名/团队/路径校验 → startup 就绪 → 准入 → `powerSampling.request`，且该调用全文唯一；采样段不含字符串插值、stderr、Mac mini 运行时、控制队列和 childLock；runner 只经 coordinator 调用；只有 stdout 进入缓冲 |
| `Tests/.../PowermetricsProtocolSafetyTests.swift` | 新测试 `testReplyDTOCarriesOnlyStructuredFields`；调用方策略测试补尾斜杠/无尾斜杠/`deletingLastPathComponent` 形式都放行，`../Evil.app` 与非 file URL 拒绝 | 锁定“只回传结构化字段”：样本 JSON 键集合、簇只有 name/kind/megahertz、名称必须是 P/E 加 1–3 位数字、失败只是固定枚举、含异常簇名的回复在 app 侧被拒 |
| `Tests/.../HelperPowerMetricsMonitorTests.swift` | 新测试 `testScanStoreWiringDegradesWithoutRequestingOrAuthorizing`、`testUnavailableAndUnauthorizedRepliesShowNeedsHelperWithoutNumbers`；用 `@MainActor` 小盒子替代被 Sendable 闭包捕获后修改的局部变量；重开节流测试只拦第一次请求 | 第一条走真实 `ScanStore` 接线（测试工厂的风扇假对象对任何 XPC 请求、注册、注销、打开授权页都记录并让 teardown 失败），证明助手未登记时显示“—”和“需要系统助手”且不请求、不弹授权。消除 5 条编译警告。反证 `reopen-bypasses-throttle` 首轮使测试挂起而不是失败，现在会以调用次数断言失败 |
| `Tests/.../PowermetricsSamplingTests.swift` | 第 33 个请求改在独立 Task 中发起，先确认它在采样进行中就已返回，再放开闸门，最后断言结果为 `busy` | 反证 `no-waiter-bound` 首轮使测试永久挂起（第 33 个请求加入在途采样后等待闸门），现在会失败而不是挂起；原断言（一次启动、32 个共享结果、排空为 0、溢出为 busy）全部保留 |

没有删除或放宽任何断言、阈值，也没有跳过测试。

### 测试数字（命令见 RULES 第 3 节；`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，`--skip-update --disable-automatic-resolution --manifest-cache local --jobs 3`）

| 项目 | 结果 | 日志 |
|---|---|---|
| Debug 构建（`--build-tests`，含 FanControlHelper），Codex 原稿 | FAIL：1 个编译错误（`FanControlPlannerTests.swift:1548` switch 不完整），修后通过并有 5 条测试 Sendable 警告 | `logs/v1/build.log`、`logs/v1/build2.log` |
| Debug 构建，最终（反证结束后重新构建） | PASS，exit 0，0 错误 0 警告 | `logs/final/rebuild-after-mutations.log` |
| 定向测试（`targeted-classes.txt` 24 个类，含 UIConsistencyRegressionTests、TestPreferenceHygieneTests） | PASS：295 个测试，0 失败，0 跳过 | `logs/v3/targeted.log` |
| 全量 Debug，首次（改动前，另有 3 个批次同时跑全量，负载 16–50） | 4341 个测试，25 跳过，2 失败：`FileAnalysisTrashCostTests.testARowsRuleCheckFoldsOnlyItsOwnPath`（30.49 µs，预算 30 µs）、`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`（`resourceLimit`）。两者都是计时类、与本批文件无关；单独重跑时前者通过，后者在负载约 16 时仍失败 | `logs/v1/full.log`、`logs/v2/flaky-rerun.log` |
| 全量 Debug，最终（负载约 9） | **PASS：4345 个测试，25 跳过（各批全量相同的既有跳过），0 失败，exit 0** | `logs/final/full.log` |
| `git diff --check`、`script/check_private_api.py` | PASS（后者：7 处白名单用法） | — |

### 反证

运行器：`mut/run-mutations-multi.py`（多文件编辑：应用 → `swift test --filter` → 逐文件恢复并核对 SHA-256；“变红”= 过滤测试实际运行、至少一条断言失败、无编译错误）。规格 `mut/mutations.json`（由 `mut/build-spec.py` 生成），结果已并入 `docs/2.0.0/collab/handoffs/r2-energy-powermetrics.counterexamples.json`（每个反证用例下的 `mutations` 列出编辑、结果和失败测试）。

- 首轮 38 条：35 条变红；`helper-extra-flag` 存活（守卫漏洞，已修）；`no-waiter-bound`、`reopen-bypasses-throttle` 使测试挂起（已手动结束这两个测试进程，测试已改为失败而不是挂起）。日志 `logs/mutations/`。
- 修复后新增 `pmset-arguments-suffix`、`powermetrics-url-chain` 两条，共 40 条全部重跑：**40/40 变红**。日志 `logs/mutations-final/`，摘要 `logs/mutations-final/summary.json`。
- 跑完后核对 worktree 全部改动文件 SHA-256 与反证前一致（0 不符），并重新构建（exit 0），之后才跑最终定向与全量。

覆盖：请求键/版本、团队/可执行路径/助手 app 路径、删除或后移调用方校验、未授权消耗节流、节流 1 s/失败不计、取消合并/取消等待上限、超时 6 s/不 kill、stderr 不计入/上限放大、多文档拼接/未知单位/缺失补零/簇名不限、迟到回复发布/重开绕过节流/无需求也请求、过期仍显示/未知显示 0/在途撤销仍发布、未批准也发送/ScanStore 接线发送/视图弹授权、间隔 500 ms/额外参数/第三个 Process/pmset 白名单绕过/pmset 同行追加/powermetrics URL 链、采样走 commandQueue/回复带插值、v3 仍持有睡眠责任仍注销/先恢复后 OFF/v3 兼容放宽。

### Release、Beta 与打包

| 项目 | 结果 | 说明 |
|---|---|---|
| Release：`swift build -c release`，独立 scratch `release/`（从 `debug/` 复制 checkouts/repositories/artifacts/workspace-state.json，并把其中路径 sed 为新目录） | PASS，exit 0，470.9 s，0 错误 0 警告；产物含 `StorageCleanerFanControlHelper` | `logs/v2/release.log` |
| Beta：`swift build -c debug -Xswiftc -D -Xswiftc STORAGE_CLEANER_BETA`，独立 scratch `beta/`（同样复制依赖） | PASS，exit 0，307.1 s，0 错误 0 警告；产物含 helper | `logs/v2/beta.log` |
| 打包：`SWIFT_BUILD_DIR=/tmp/storage-cleaner-epm-build STORAGE_CLEANER_SKIP_TESTS=1 SWIFT_BUILD_JOBS=3 script/build_and_run.sh --bundle-only`（打包前确认 `/tmp/storage-cleaner-run-dist` 不存在；完成后立即改名为 `/tmp/storage-cleaner-epm-app`） | PASS，exit 0。脚本自检全部通过：helper 可执行、LaunchDaemon plist 的 Label/BundleProgram/MachServices、`codesign --verify --strict` helper、Info/BuildInfo、`verified: macOS 14.0+, linked SDK 27.0, arm64`、`codesign --verify --deep --strict` 整包（valid on disk、satisfies its Designated Requirement）、`verified: app bundle assembled without launching` | `logs/v2/bundle.log`。默认配置 Debug、ad-hoc 签名（非 Beta 的 `--bundle-only` 默认 `SIGN_IDENTITY=-`）。另核对 helper `Identifier=com.local.StorageCleanerMac.FanControlHelper`，二进制内含 `/usr/bin/powermetrics`、`/usr/bin/pmset`、`cpu_power,gpu_power,ane_power` |

未安装、未碰 `/Applications`、未启动应用。ad-hoc 包没有证书，现有 listener 本来就拒绝，因此无法用它演示团队 T9GZL52H8R 放行；带真实身份的 Beta 打包需要查询签名身份，本轮没做。

### 安全自查结果

| 要求 | 结论 | 证据 |
|---|---|---|
| powermetrics 命令完全由常量构造 | PASS（守卫已加固） | `static let arguments` 固定 `--samplers cpu_power,gpu_power,ane_power -n 1 -i 1000 -f plist`；可执行文件与参数两行整行匹配各一次；环境、工作目录、stdin 固定。反证：间隔 500、额外参数、URL 链、第三个 Process、/bin/sh 均变红 |
| XPC 请求不带字符串参数 | PASS | 采样信封只允许 `operation`、`protocolVersion` 两键且 ≤512 B，版本只收 4；app 侧 `encodedForTransport` 只编码这两键。反证 `request-keys`、`request-version` 变红 |
| 调用方校验（安装路径 + 团队 T9GZL52H8R）先于执行 | PASS（路径比较已加固） | listener 原有证书一致校验不变；采样请求另用 audit token 取运行中代码对象，做动态有效性、静态完整封印（含资源与嵌套代码）、团队、bundle id、可执行路径、助手所在 app 路径校验，全部在 `powerSampling.request` 之前；未授权不进入 coordinator，不消耗节流。顺序由新守卫锁定。反证 6 条变红 |
| 节流 ≥2 s、并发合并、5 s 超时 kill、输出上限 | PASS（注入时钟/管道的单元层面） | coordinator 开始到开始 ≥2 s（失败也计）、单一 inFlight、等待者 ≤32；`collect` 5 s 到期直接 SIGKILL、stdout+stderr 合计 ≤512 KiB、超限丢弃整份。反证 8 条变红。真实子进程的 SIGKILL 未实测（需要 root） |
| 只回传解析后的结构化字段 | PASS | 回复为 `PowermetricsResult`：数值字段、受限簇名、固定失败枚举；message 为常量；stderr 只计数不保留；app 侧要求 success 与样本一致、不混入风扇/曲线/Mac mini 字段。反证 `cluster-name-unbounded`、`sampling-stderr-in-reply` 变红 |
| 风扇控制与 Mac mini 模式的锁和行为不变 | PASS（源码守卫 + 回归） | 采样不进 smcQueue/commandQueue，不碰 macMiniRuntime、pmset、策略锁；childLock 只在 runner 内；只与原有逻辑共用 `requestLock` 做准入计数，并在终止处理开头先 kill 采样子进程。MacMini*/FanControl* 共 12 个定向类和全量 Debug 都通过 |
| 助手白名单源码守卫 | PASS（已修漏洞） | 只允许 main.swift 的 pmset 一处与 runner 的 powermetrics 一处 Process；禁止 posix_spawn/fork/exec*/system/popen；pmset 白名单在启动前检查；行为测试 `MacMiniModeEngineTests` 仍锁定白名单参数集合 |
| 应用侧降级 | PASS（单元/接线层面） | 未登记、需批准、未找到、`unavailable`/`unauthorized` 回复都显示“—”与“需要系统助手”，链接只跳到“设置 › 权限”的系统助手项；ScanStore 接线测试证明不请求、不注册、不打开授权页。按需：只有可见消费者才请求，关闭/最小化/遮蔽/隐藏/睡眠撤销需求，迟到回复丢弃，重开不绕过 2 s。反证 9 条变红。实际窗口行为与截图未做 |

额外测量：在 153 MB 的 Debug 包上，单次 `SecStaticCodeCheckValidity`（含资源与嵌套代码）为 93–110 ms，默认参数 90–96 ms，不查资源 76–88 ms（负载约 45）。也就是说每个采样请求都会在 root 助手的 XPC 线程上做一次约 0.1 s 的完整封印校验，而且这一步发生在节流之前。能耗页可见时大约每 3 s 一次。这份修复前测量解释了 P2-1 的耗时问题；本轮已迁出 XPC 交付线程并缓存完整 seal，修后真实耗时尚未测量。不能把旧稿的安全判断作为本轮复核结论。

### 未解决 / 待验收

1. 独立安全复核未做（主会话另派）。上文“安全复核要点”所列的 TOCTOU、PID 回收与 kill 的竞态（`isRunning` 检查与 `kill` 之间）、KVC 取 auditToken、终止期间 admission 竞态仍需人工审。
2. 真机未验：root XPC 往返、macOS 27 实际 plist 字段与单位（解析夹具是结构样例，不是真机采集）、正式签名包在 `/Applications` 下的团队/路径放行、5 s SIGKILL、助手终止时无残留子进程、窗口可见性实际行为、界面截图（中英文、最小尺寸、多簇机器）。
3. 每次请求约 0.1 s 的封印校验开销（见上）。
4. `MacBenchmarkKernelTests` 与 `FileAnalysisTrashCostTests` 在高负载下会超预算，最终全量在负载约 9 时通过；未放宽阈值。
5. 严格并发门禁、`script/verify.sh` 完整门禁留给集成分支。
6. 准备包已按最终文件重新生成：`generate-prepared-r2.py` 在 `02-client` 组加入 `FanControlPlannerTests.swift`，不再用内置计划覆盖已执行的 counterexamples，`validation` 改读 `logs/main-verification.json`。原 `generate-prepared.py` 保留未动。


## 安全复核修复与续接轮（2026-10-09，Codex）

### 范围与保留证据

- 起点：HEAD `c002414b166d42e959ee9a770729b2a29177e2ee`、分支 `task/r2-energy-powermetrics`，8 个已跟踪文件修改及 2 个未跟踪测试文件。已先查 `git status` / 完整 `git diff`；没有丢弃前任改动。原状 diff、10 个文件副本及 SHA-256 保存在 scratch `logs/security-fix-initial/`。
- 当前只修用户给出的 P1、P2-1～3，以及同一缓存/回收数据流发现的两处竞态。没有改 `ScanStore.swift`、界面、控制行为、硬件设置、助手登记或安装路径中的文件；没有执行 powermetrics、sudo、应用启动或系统助手。
- `.git` 受当前权限配置只读保护。本轮按 `codex-build-common.md` 的回退约定生成 scratch `prepared/`，不尝试突破权限提交。原 prepared 完整保留到 `logs/prepared-before-security-fix/`。

### 最终修改

| 复核项 | 修改与理由 | 绿测试 / 红反证 |
|---|---|---|
| P1 可执行名 | `StorageCleanerBuildIdentity` 以 `static let` 定义 Beta `StorageCleanerMacBeta`、正式 `StorageCleanerMac` 及当前构建可执行名；安装路径统一由身份构造，`PowermetricsClientPolicy` 不再自行拼同名路径；修正协议测试与交接错误路径 | `BuildIdentityPackagingTests` 对照两个脚本的 APP_NAME、显示名、CFBundleExecutable 及 Beta 打包自检；`PowermetricsProtocolSafetyTests` 保留原身份/路径拒绝并新增另一构建可执行名拒绝。`p1-*` 突变改名、硬编码或错安装路径，预期断言失败 |
| P2-1 身份/封印与队列 | 同步 XPC 交付只取 `current()` / audit token、按连接限频、startup/32 pending 准入；签名在独立 utility 验证队列。每次先动态 `SecCodeCheckValidity` 和固定路径/团队/id，通过后才全 seal；成功结果仅在连接代次和 audit pid+pidversion 相同才缓存。1 s 尝试间隔对失败、拒绝重试也计数；原 daemon 全局 2 s 采样节流不变 | `PowermetricsClientGateTests` 锁定廉价检查每次执行、seal 一次、失败不缓存、pidversion 变化重新验、失败尝试时间、抛错拒绝及 audit 布局；源码守卫锁定签名不在 XPC 同步段。`gate-*` / `seal-on-xpc-thread` / `admission-*` / `audit-*` 反证 |
| 缓存生命周期补强 | 连接准入时注册随机代次，失效时删除；登记与失效在原连接生命周期串行区内排序。廉价限频返回携带代次的 Admission；验证前、廉价检查后及写回 seal 前均要求代次仍一致。解决失效中 seal 回调重新创建缓存，以及 ObjectIdentifier 被复用后旧请求命中新连接缓存 | 新测试在 cheap/seal 回调里失效，模拟同一 ObjectIdentifier 新代次及已缓存 cheap 中失效；保证旧票据拒绝、缓存不复活、失效后不自动登记。`gate-late-seal-recreates-state`、`gate-reused-connection-accepts-old-ticket`、`listener-no-gate-registration` 反证 |
| P2-2 源码守卫 | 递归读取 FanControlHelper 与 FanControlShared 全部源码文件（含子目录、非 Swift 扩展），拒绝 posix_spawn 各变体、exec[l/v] 各变体、vfork、NSTask、Process.run/init/typed .init、shell/动态调用等。只有 runner 的常量 spawn 与 main 的既有 pmset Process 可通过。pmset executable/arguments 整行、完整 environment 赋值块及环境引用数锁定，拒绝同行追加、继承与后续写环境；spawn 向量、环境、文件动作与引用数锁定 | 守卫测试在 main/runner/shared/新子目录对每类拼写注入字符串副本；额外锁定 qualified typed init、空白 Process.run、spawn 别名及环境尾部合并/二次赋值。对应 `bypass-*`、`runner-*`、`pmset-environment-*` 反证 |
| P2-3 子进程 | 唯一常量 `posix_spawn` 用 SETPGROUP 创建 pgid=pid，默认信号/空 mask、CLOEXEC_DEFAULT；stdin `/dev/null`、工作目录 `/`、固定环境。启动/自身 WNOHANG waitpid/负 pgid SIGKILL 共用 childLock，回收后清空 activeChild；停止期间拒绝 spawn。检查 spawn action/attr 初始化和 strdup 分配失败，不启动参数截断的命令 | `PowermetricsHelperSourceGuardTests` 检查唯一 spawn、自身 waitpid、组参数、负 pgid、activeChild 与锁、停止准入和信号退出码；`kill-*`、`reap-*`、`no-process-group`、`wait-any-child`、`spawn-while-stopping` 反证 |
| 管道/进程组补强 | 正常路径到 stdout/stderr 都 EOF 后才 reap，防止组长已退出但后代仍持管道时过早释放 PID，导致 deadline 无法安全 kill 组。超时/超限先 kill unreaped 组，再最多 100×10 ms 轮询回收；未回收保持 busy，不重叠新进程。已回收不再等或 kill | 守卫锁定 EOF 条件；`leader-reaped-before-pipe-eof` 反证。运行期进程组/PID 实测仍交主会话，未在本轮启动任何 powermetrics 子进程 |

5 s deadline、512 KiB 两管道合计、32 等待者、固定命令、现有 pmset 白名单及控制队列边界都没有放宽。SIGKILL 在 5 s 软件 deadline 触发；之后最多约 1 s 的回收轮询不延迟发出 SIGKILL，仍受系统调度影响。

### 本轮旧断言变化的依据

1. 采样守卫原要求 helper/shared 合计两处 Process、禁止全部 posix_spawn；按用户 P2-3 和 D71 改为 main 的 pmset 一处 Process + runner 一处常量 posix_spawn，同时锁定 spawn 属性/向量/自有回收及所有其他创建拼写。禁止项覆盖增加，没有删安全要求。
2. 身份校验顺序从完整 seal 逐请求同步发生，改为 XPC 同步廉价准入 → 独立验证队列 → 动态身份 → 连接代次/pid+pidversion seal 缓存 → coordinator；按用户 P2-1 锁定新顺序，控制队列隔离断言全部保留。
3. 协议调用方策略的预期可执行路径改从构建身份读。正式名保持原值，Beta 改为真实打包名；保留错误团队、id、重定位、非文件、helper app、尾斜杠全部断言。
4. 前任未提交的 gate 测试为了覆盖显式连接生命周期，增加 register / Admission 夹具与失效中回调断言；原检查次数、pidversion、失败缓存、节流断言仍保留。测试只使用纯内存对象与现有 TestPreferenceDomain，无新增偏好域或产品安全例外。

### 实际命令与结果

scratch 为 `/Users/developer/Developer/.sc-build/r2-energy-powermetrics`。全部日志在 `logs/security-fix/`，机器当前 SDK 的 SwiftPM 有 `--skip-update` 弃用警告和 user-level cache 不可写提示；没有 Swift 源码编译诊断。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-energy-powermetrics
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8 CLANG_MODULE_CACHE_PATH=/Users/developer/.cache/clang
scratch=/Users/developer/Developer/.sc-build/r2-energy-powermetrics
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$scratch/debug" \
   --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
# 完整批次 26 类：包含两个新增类、TestPreferenceHygieneTests、UIConsistencyRegressionTests
target_filter="$(paste -sd'|' "$scratch/targeted-classes.txt")"
swift test "${F[@]}" --skip-build --filter "$target_filter"
# 最后身份常量改为 static let 后，仅重跑受影响的安全 6 类
swift test "${F[@]}" --skip-build --filter \
  'BuildIdentityPackagingTests|PowermetricsClientGateTests|PowermetricsHelperSourceGuardTests|PowermetricsParserTests|PowermetricsProtocolSafetyTests|PowermetricsSamplingTests'
git diff --check
python3 script/check_private_api.py
```

| 项目 | 本轮结果 | 证据 |
|---|---|---|
| Debug `--build-tests`，含 helper 与测试 | **PASS，exit 0** | `build.log`、`build-final.log`、最终 `build-final2.log` |
| 完整批次定向 26 类 | **BLOCKED（沙箱），exit 1：304 项、1 跳过、4 用例/5 个失败断言或异常** | `targeted.log`。22 类全部通过；其余 3 类含环境失败、1 类既有 SMC 无键跳过 |
| 最终安全 6 类 | **PASS，exit 0：35 项、0 失败、0 跳过** | `safety-final.log`；包装身份 1、gate 6、helper 源码守卫 6、parser 6、protocol 9、sampling 7 |
| 空白 / private API | **PASS，exit 0** | `git diff --check`；private API 7 个允许使用点。prepared 静态检查也单独记录 |
| 96 条突变编辑锚点 | **PASS（仅静态），exit 0** | `mut/build-spec.py` 生成 96 条，逐突变顺序核对每条编辑恰好 1 次匹配；没有执行突变测试 |
| 全量、Release/Beta、严格并发专项 / verify.sh | **NOT RUN** | 主会话沙箱外及集成门禁 |
| powermetrics、应用、助手 / 安装 / git 提交 | **NOT RUN** | 未运行；prepared 路径代替提交 |
| JEV 判断 | **BLOCKED** | 工具参数已核对，未暴露模型选择参数；一次 `jev_decide` 请求返回 `MCP tool call requires approval, but approval policy is never`。没有实际模型响应或判断，不重试讨好结果 |

四个环境失败的用例必须由主会话在沙箱外原样复跑，不删除断言、改夹具位置或加跳过：

- `HelperPowerMetricsMonitorTests.testScanStoreWiringDegradesWithoutRequestingOrAuthorizing`：TestFileSystem.swift:60 创建家目录 `.storage-cleaner-scan-store-*/home` 失败，NSPOSIX Code 1 `Operation not permitted`。
- `TestFanControlIsolationTests.testLiveCPUAndNetworkRefreshUsesAnIsolatedFanController`：同上家目录操作夹具权限异常。
- `TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`：临时绝对域出现 `sandbox_extension_issue_file ... Operation not permitted`，synchronize 与 plist 存在性两条失败。
- `TestPreferenceHygieneTests.testTemporarySuiteCanBeReopenedOnAWorkerThread`：同一沙箱扩展错误，synchronize 为 false，一条失败。

`MiniSensorsLiveReadingTests.testThisMacsLiveReadingsAreInPlausibleRanges` 的 1 项跳过来自既有“本机没有 SMC power keys”条件，本轮未加跳过。其余临时偏好用例虽然有 CFPreferences 沙箱提示，断言通过；不能用它们替代上述落盘与跨线程验证。

### 反证与主会话下一步

当前完整规格是 scratch `mut/mutations.json`，共 **96 条**，覆盖原 40 条及 P1/P2 每类绕过和本轮两处竞态。同样完整编辑列表已追加到交接旁 counterexamples 的 `security_fix_round`，全部明确 **NOT RUN**；原始 40/40 执行记录保留并标明历史范围。

前任留下的 `logs/mutations-r3/summary.json` 是修复中版本 **76/78** 的历史记录，不是当前结果。`bypass-popen` 被新 SDK 的 Swift unavailable 拦在编译阶段，已改为 `#if false` 内的同样语法，让全源码文本守卫断言变红；`bypass-shared-module` 只留下不完整构建片段，已显式 nonisolated，仍须主会话重跑。vfork、NSTask、C varargs 等易产生 SDK/签名编译错误的拼写同样放入排除分支；对应方法永不调用、守卫仍扫描它们，不把编译失败当反证成功。

主会话在独占的反证工作区执行（不要与其他会话共同改源码或共用 scratch）：

```bash
python3 "$scratch/mut/build-spec.py"
python3 "$scratch/mut/run-mutations-multi.py" \
  "$scratch/mut/mutations.json" \
  /Users/developer/Developer/sc-worktrees/r2-energy-powermetrics \
  "$scratch/debug" "$scratch/logs/mutations-security-final"
```

runner 每条应用 → 定向测试 → finally 恢复源码/新文件并核对 hash；成功必须是测试实际运行且断言失败，编译失败/挂起/锚点失配都不算。`store-wiring-sends` 及涉及产品操作 home 的用例必须在沙箱外执行。跑完按最终文件 hash 确认恢复，再构建并跑 26 类及门禁；补充真实签名包/连接失效/进程组和 EOF 的独立复核。真实采样耗时、pid/pidversion 行为、SIGKILL 与窗口可见性仍未实测。

### prepared 交付

scratch `prepared/` 以本轮 HEAD 为基线，顺序四组：`01-identity`（4 文件）、`02-admission`（3 文件）、`03-runner-guard`（2 文件）、`04-handoff`（2 文件），共 **11 文件**。含各组 patch/message、all.patch、最终源码/产物 SHA-256 manifest、static-checks.json、commit-prepared.py、targeted-classes.txt、counterexamples.json 和 mut/ 规格/生成脚本/runner 副本。commit-prepared 只在主会话完成本轮沙箱外失败复跑、96 条反证与独立复核后以 `--validated` 执行，不构建、不安装、不合并、不 push；当前未执行。

未解决的是上述实际验证与权限限制；P1/P2 的代码修复已交付，没有把历史通过数字当成本轮通过。
