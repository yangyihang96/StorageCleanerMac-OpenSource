# r2-helper-upgrade 交接（2026-10-10）

本批 worktree：`~/Developer/sc-worktrees/r2-helper-upgrade`，分支 `task/r2-helper-upgrade`，基线 `5b07771309f7b6cae027eca60405e95e352a9d51`。开始时工作区干净。已读 common.md、codex-build-common.md、RULES.md、DECISIONS D5/D48/D55/D60 和 BOARD；BOARD 基线没有本批条目，以本次用户任务为范围。遵守 10-09 起允许沙箱构建和定向测试的补充；.git 只读，交付 prepared 分组补丁。未修改 ScanStore、硬件能力探测或 launchd plist。

## 根因审计与证据边界

用户提供的 2026-10-10 只读现场：重装构建 20261010015823 后，system/com.local.StorageCleanerMac.beta.FanControlHelper 仍为安装前 PID 2424，runs=444；磁盘助手已替换；新 App 未获受信任连接，风扇和功率失效。本批未读取/启动/终止真实助手，也没有实机错误码、旧进程代码身份或签名证书链的独立读回。

**fix1 新现场证据（主会话 2026-10-10 16:52 只读系统日志，非本会话实机采集）**：构建 20261010015823 的 App 连接 PID 2424 时，10 分钟出现 23,476 条 `Peer connection was rejected by the listener (xpc_connection_cancel())`（约 39.1 次/秒），App CPU 100.5%，温度 83–88°C、风扇 5150 rpm。日志坐实 listener 返回拒绝，故障发生在 RPC 协议解码之前；不能再只按协议号不兼容解释。listener 的原实现既可能因 `clientMatchesHelper` 返回 false 拒绝，也可能因该函数的 Security 调用抛错而拒绝；系统通用日志不区分二者，不能据此断言命中某一 guard。

四条件中**第 2 条最符合当前证据，但不是已证实的分支**：已确认磁盘 helper 被替换而旧进程仍驻留，每次连接重新由旧进程取得磁盘 static code，正好落入该更新时序风险；SDK 对 static code 的文件系统来源说明支持这条推断。构建标签和当前协议没有入口比较，Beta App identifier 由 BuildIdentity 编译常量决定。第 4 条仍需排查：构建脚本把 App/helper 都用同一 `SIGN_IDENTITY` 签名并严格验证，因此能解释“同一新包内一致”，却不能证明旧进程证书链等于新包；脚本默认选 `security find-identity` 输出中的第一个 Apple Development/Developer ID 身份，不同安装之间换证书或显式 SIGN_IDENTITY 变化仍可能造成完整链不等。本批没有读取钥匙串或现场签名。第 3 条的客户端 Security 错误也不能只靠该日志排除。主会话应在改变现场前保留旧助手自己的签名校验 OSStatus、旧进程完整链/identifier 和新客户端相同证据；只比较 TeamIdentifier 不足以排除第 4 条。

基线 `CodeSigningCheck.clientMatchesHelper` 的**确切拒绝条件**如下，不把推测写成现场事实：

1. audit token 不存在，立即拒绝。
2. 每次连接执行 `SecCodeCopySelf → SecCodeCopyStaticCode → SecStaticCodeCheckValidity(DoNotValidateResources | CheckNestedCode)`，取得助手当前磁盘静态身份；任一 Security 调用失败抛错，立即拒绝。
3. audit-token 定位客户端，取得其 static code 并执行同样的签名有效性检查；任一步失败，立即拒绝。
4. 助手证书链为空、客户端完整证书链与助手不等、或客户端 identifier 不等于编译时 `StorageCleanerBuildIdentity.appBundleIdentifier`，立即拒绝。

**监听入口没有比较协议号、CFBundleVersion/构建号或客户端 cdhash，也没有团队/安装路径白名单检查。** 团队与路径检查实际在功率采样的 `PowermetricsClientPolicy`（T9GZL52H8R、Beta/release 各自 `/Applications` 路径）、动态有效性与完整静态封印检查中。Mac mini 的身份校验另用于持久睡眠策略。`MacMiniHardwareCapabilities` 只探测设备是否有电池/合盖开关，与连接拒绝无关；`macMiniHelperNeedsUpdate` 只是 App 对 v2/v3 协议不兼容的标志，原来不是“旧进程仍驻留”的探测器。

协议检查发生在 listener 接受之后的 `handle`/App `validated`。因此“旧/新构建标签不同”本身不是拒绝条件；相同证书链与 Bundle ID 的组合必须仍可通过。现有协议不升级。

本机 Xcode 27 SDK 的 `Security.framework/Headers/SecCode.h:67-95` 明确 `SecCodeCopyStaticCode` 定位运行代码的文件系统来源；该关联不是安全保证。`kSecCodeInfoUnique`（同文件 456 起）标识具体静态代码，稳定 identifier 跨更新保留。基线在更新后的路径上重新推导旧进程身份，存在丢失文件或静态签名不一致的拒绝路径；没有自动让位或设置页重连入口，是源码可证实的生命周期缺口。

**尚未证实现场具体落在条件 2、3 还是 4。** 没有 OSStatus、旧进程证书链或编译 identifier，不能宣称已证明“构建号不匹配”“协议不匹配”或“cdhash 不匹配”。代码新增启动签名快照失败和 listener 拒绝的错误输出（保留 OSStatus 的错误枚举描述），供主会话安全复核补证。

## 修改与攻击面

- `HelperUpgradeSafety.swift`：可注入的完整证书链/identifier 策略、可比较的常规文件元数据、让位条件和退出前恢复顺序。元数据取 device/inode/size/mtime/ctime 纳秒，拒绝未知、非文件和符号链接。元数据是失效证据，不是认证。
- `main.swift`：监听开放前使用公开 `_NSGetExecutablePath` 取得本进程镜像路径（不依赖外层 Bundle 的解释），校验自身运行代码并读取静态身份，在元数据前后稳定时保留身份/代码哈希。每次客户端仍通过 audit-token 获取的 static code 有效性检查和原有完整证书链/identifier 等值检查；不会从替换后的文件重新定义旧进程的信任根。
- 只有原有认证通过的客户端才进入让位检查，额外要求运行代码有效、功率采样现有固定团队/安装路径策略通过、客户端完整资源封印通过。旧助手自身也必须位于对应固定安装路径、团队相同。再严格验证替换助手签名、helper identifier、完整证书链及团队，校验前后元数据稳定且代码哈希不同，才拒绝这条连接并在 commandQueue 请求终止。不增加升级 RPC，不接受 JSON/PID/构建字符串授予权限。
- 退出复用信号终止的恢复路径：先关闭请求闸门、停止采样子进程、取消空闲退出，等已计数请求完成，再在 smcQueue 取消曲线/看门狗计时器、清除曲线执行器，恢复本助手拥有的睡眠设置，恢复所有风扇自动控制，然后决定退出码。失败不会清掉现有风扇恢复标记；下一次启动仍走原 startup safety。启动恢复失败的进程不再写风扇。
- plist 未改：`RunAtLoad=true`，`KeepAlive={SuccessfulExit:false}`，MachServices 保留。恢复成功且无需保活时 `EXIT_SUCCESS`，随后 Mach 请求按需启动；恢复失败或持久睡眠策略仍要求驻留时 `EXIT_FAILURE`，launchd 可立即重启。启动失败锁存状态保留原成功退出口径，避免失败进程的 KeepAlive 循环。
- App：普通连接失败或旧协议只做初始 ping 加一次新连接重试，间隔 500 ms；自身打包签名不可信不重试；取消不假装升级；`.fanCrashRecoveryFailed` 仍锁存、隐藏重连，不发送额外风扇写入。重连期间撤销旧控制意图；只有本来有自定义控制责任时保留原恢复路径。成功 ping 仅证明连接，硬件模式仍未知。
- 只有协议错误显示“需要更新”；普通拒绝/中断显示“连接中断，正在重新连接”，最终失败提供“可能需要更新或重新批准”的操作说明。系统控制页在已安装但未连接时提供“重新连接”；重试失败再提供“在系统设置中重新批准”；保留停用操作。小窗继续复用既有重新检测入口和 lastMessage。
- 安装脚本：增加仅查询对应 launchd job 与文件 stat 的安装前后快照。如果磁盘文件变化、安装前后 PID 与 runs 一致，提示旧进程仍驻留；新 PID、无进程、不可读状态分别如实报告，不把新 PID当作受信任连接或硬件验收。不 sudo、不 kickstart、不 bootout、不发助手进程信号。此批不执行安装脚本。

**攻击面变化**：增加一个在正常连接认证后触发的退出分支，能力仅为恢复本助手的系统控制责任并退出。无新 Mach service、RPC、可配置路径、shell 命令或第三方依赖。随机进程、同团队但不在固定路径的副本、仅改构建字符串、签名无效/团队错误的客户端、符号链接/无签名替换文件均不能触发。完整证书链限制不放宽为仅同团队，换证书需单独批准迁移。自身身份的校验时机从每次读取磁盘改为启动时稳定校验；该缓存只代表已运行且原本受信任的助手，不信任更新文件改变其身份。主会话合并前必须另做安全复核，特别复核此证据生命周期、请求排空、计时器关闭及恢复失败重启分支。

## 测试与旧断言

新增 `HelperUpgradeSafetyTests` 8 项、`HelperUpgradeCoordinatorTests` 8 项、Python 安装快照测试 7 项；Swift 测试只用 TestPreferenceDomain、TestOperationFactory 和 TestFileSystem 临时纯数据夹具，无真实 XPC、硬件、偏好或 launchctl 调用。

改写两处既有源码断言：`PowermetricsHelperSourceGuardTests.testSamplingCannotBypassAuthenticationOrReachControlQueues` 的源码调用文本从 `clientMatchesHelper(auditToken: token)` 更新为带 `helperIdentity: startupIdentity.signing` 的调用。依据是本次用户明确要求保留原客户端认证并让旧助手安全让位；完整认证的断言保留，新增让位检查顺序、额外封印、同证书链、请求排空与计时器关闭守卫。另将 `FanControlPackagingTests.testFanControlUsesSMAppServiceAndAuthenticatedXPC` 的旧 inline identifier 文本断言改为同时验证 helper 的调用参数与共享策略的完整证书链/identifier 等值条件（抽取逻辑位置改变，安全条件不变）。没有删测试、降阈值或跳过测试。

红/绿与反证（主会话负责真实红测/变异，不在本批沙箱运行反证）：

1. 原因组合：旧/新构建标签 + 相同/不同证书链、Bundle ID、空签名。绿：构建标签不影响身份结果；证书链/ID 不符始终拒绝。真实旧进程 Security 失败的红测需要先独立采集 OSStatus，不以纯策略测试代替现场复现。
2. 让位矩阵：原认证 × 团队路径动态封印 × 替换签名，8 组合仅全真触发；无元数据、无哈希、未替换、仅元数据变化均不得让位；新哈希和新元数据且全校验通过才让位。红：移除任一授权 guard、只按 mtime 判定、移除证书链比较；相应矩阵测试失败。
3. 恢复顺序：stop → sleep → fans → exit decision，sleep/fan 成功失败 4 组合，任一失败不能宣称恢复成功，sleep 失败也必须尝试风扇恢复。红：跳过风扇恢复或提前决定退出。
4. App：一次中断后成功、两次失败、旧协议提示、注册路径重试、取消、重试期间取消、启动故障锁存与设置入口。红：取消重试、去掉 attention 状态、错误开放启动故障重连。
5. 安装：同 PID/替换磁盘、同 PID/未变、换 PID、PID 复用但 runs 变化、按需无 PID、权限未知、runs 与 PID 区分；纯 Python 变异测试，不能读取/终止真实 helper。

## 主会话命令和产物

scratch：`~/Developer/.sc-build/r2-helper-upgrade`。`targeted-classes.txt` 为定向类清单，`counterexamples.json` 有逐条变异字符串、预期出现次数和定向 filter；反证执行状态 NOT RUN。`prepared/` 按以下顺序：01-helper、02-app、03-install、04-handoff；含 all.patch、提交说明、文件 SHA-256 manifest、static-checks.json、commit-prepared.py（需 `--validated`），以及定向/反证清单副本。主会话在当前 worktree 检查后提交；脚本只在 HEAD、分支、文件与补丁哈希完全匹配且暂存区干净时按组暂存提交，不执行安装/合并/push。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$HOME/Developer/.sc-build/r2-helper-upgrade/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER="$(paste -sd '|' "$HOME/Developer/.sc-build/r2-helper-upgrade/targeted-classes.txt")"
swift test "${F[@]}" --skip-build --filter "$FILTER"
PYTHONDONTWRITEBYTECODE=1 python3 script/test_helper_upgrade_status.py
python3 script/check_private_api.py
bash -n script/build_and_run.sh
git diff --check
# 主会话完成构建、测试、反证和独立安全复核后：
python3 "$HOME/Developer/.sc-build/r2-helper-upgrade/prepared/commit-prepared.py" --validated
```

完整门禁只由主会话在集成分支执行：`script/verify.sh` 使用指定 Xcode、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0` 和私有 `STORAGE_CLEANER_VERIFY_ROOT`。Release、严格并发、全量、截图和实机升级均未在本批执行。

## 未解决与首次迁移

- **已经运行的旧助手没有此逻辑，不能通过更新 App 给旧进程补代码。** 对该 PID 的首次恢复仍由主会话取得相应批准后走系统后台项目重新批准/重新启用流程；若需要管理员权限，仅提供操作说明，不能据此自动 sudo/kill。此补丁负责新助手首次启动后的后续更新。
- 缺少现场 OSStatus 和旧进程签名身份，具体拒绝分支 BLOCKED；请主会话在改变现场前保存必要签名错误证据。新日志保留错误枚举的 OSStatus。纯签名矩阵不是运行 Security.framework、launchd 和 AppleSMC 的升级验收。
- App 500 ms 一次重试可能早于慢速签名/恢复完成；失败后显示可手动重新连接及系统批准入口，不增加无限重试。
- 团队/固定路径复用现有功率采样白名单，`~/Applications` 副本不得触发退出。已有安装脚本对该目录的 fallback 不改；此范围外路径仍按原权限边界工作。
- JEV 尝试一次 bounded decision 调用返回 `MCP tool call requires approval, but approval policy is never`，没有实际模型结果或判断。未绕过权限或重复申请。主会话的独立安全复核仍必需。

## 本轮实际验证

| 项目 | 结果与实际证据 |
|---|---|
| Swift 编译含测试 | PASS，最终 logs/build-delivery-final.log（3.75 s）退出 0；首轮 logs/build.log（219.67 s）及中间增量构建也退出 0。最终含进程镜像路径和修正后的源码断言，无代码编译警告或错误；只有 SwiftPM 沙箱缓存不可写及弃用参数环境警告。 |
| 完整定向清单 | 执行 204 项、0 跳过，首轮退出 1：5 失败断言落在 4 个用例；logs/targeted.log。新增 16 项全部 PASS；UIConsistencyRegressionTests 46 项 PASS。 |
| 修正源码守卫复跑 | FanControlPackagingTests 8 项 0 失败，退出 0；logs/packaging-rerun.log。之后镜像路径改动曾因本地变量名 executablePath 命中禁止外部可执行路径的旧文本守卫；改名为 imagePath，原负向断言不改。最终助手/启动安全/打包/新增测试 48 项 0 失败，退出 0；logs/delivery-focused-final.log。 |
| 合并测试结论 | 204 个不同用例中 201 项已通过，3 项环境 BLOCKED；不能声称完整定向 PASS。见下表。 |
| 安装快照 Python | 7 项 0 失败，退出 0；logs/install-tests.log。没有调用 capture/launchctl。 |
| 私有 API 守卫 | PASS，退出 0，7 项既有 allowlisted uses；logs/private-api.log；allowlist 未修改。 |
| shell 语法与 diff | bash -n、git diff --check 退出 0；prepared/static-checks.json 记录补丁反向校验与变异字符串匹配。 |
| 反证、全量、Release、严格并发独立构建 | NOT RUN，主会话负责；默认 Swift 6 编译不等同于另跑完整严格并发门禁。 |
| 安装、真实助手、硬件、提交、合并 | NOT RUN。没有运行助手可执行文件、sudo 或硬件命令。 |
| JEV | BLOCKED，工具策略拒绝调用，无实际模型判断。 |

需主会话在沙箱外复跑的三个用例（保留全部断言与 targeted-classes.txt）：

| 用例 | 阻碍证据 |
|---|---|
| TestFanControlIsolationTests.testLiveCPUAndNetworkRefreshUsesAnIsolatedFanController | TestFileSystem.makeOperationHome 创建 ~/.storage-cleaner-scan-store-UUID/home 时 Cocoa 513、底层 EPERM/Operation not permitted。夹具工厂报告错误，未改变家目录安全边界。 |
| TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory | CFPreferences 的 sandbox_extension_issue_file 对本测试临时绝对域反复返回 Operation not permitted；synchronize 与实际 plist 存在性两项断言失败。 |
| TestPreferenceHygieneTests.testTemporarySuiteCanBeReopenedOnAWorkerThread | 同样的 CFPreferences 扩展权限失败，工作线程 synchronize 返回 false；不改偏好域或规避权限。 |

纯源码偏好卫生守卫其他用例通过；不以它们代替上述真实临时域持久化用例。主会话可以先用这三项 filter 定向复跑，再在整份清单与完整门禁中确认。

## fix1：监听拒绝后的重连热循环（2026-10-10）

本节替代上文 App“500 ms 加一次重试”的实现、测试和提交步骤；helper 认证/让位、安装脚本三者与原交付完全相同。fix1 基线为 HEAD 5b077713 + 原四组 prepared 补丁，原目录及其 manifest 哈希保持不变，增量交付在 scratch `prepared/fix1/`。当前 worktree 已包含原四组及 fix1，不应再正向应用这些补丁。

### 确切循环与修复

- 基线的 `helperConnection().interruptionHandler` 无条件调用 `failClosed()`。`failClosed()` 清除控制状态、invalidate，然后调用 `beginRestoreRecovery()`；后者每次 cancel 上一任务并新建任务，第 0 次立即 `send(.restoreAutomatic)`，`send()` 经 `helperConnection()` 创建新 XPC。listener 再拒绝，新的 interruption 又 cancel/recreate，永远绕过循环中 attempt > 0 才等待的 250 ms。这条递归任务创建链正是可达的立即重连热循环。invalidation 分支在有自定义/已观察状态时也进入同一路径。日志频率证明现场有高频入口拒绝；本会话没有 CPU profiler，不能把全部 CPU 开销精确归因到某一个函数。
- `refreshStatus()` 原先只查询 SMAppService/legacy 状态并更新缓存，没有直接发送 XPC。ScanStore 的功率 availability 回调调用它；监测本身已限制采样每 2 秒且单在途，所以单凭这个回调不能解释约 40 次/秒。旧 `samplePowerMetrics()` 在“已安装但未连接”时仍可 send，从而另开连接。可见页面的 `refreshConnection()` 另发 ping；原四组的局部 ping 两次/500 ms 没有覆盖恢复任务和功率路径，不能作为全局限流。
- `HelperReconnectBackoff` 用单调秒数记录 deadline：基数 1、2、4、8…，0.8–1.2 抖动，实际最长 300 秒；失败计数饱和。缓存读取不消耗尝试、不推进 deadline。`connectHelper()` 是连接任务入口，`send()` 对所有可能创建新连接的路径再次执行 deadline 和单在途闸门，防止功率、恢复、控制等旁路。签名前置检查完成后才准入，准入到创建连接之间没有 await。
- interruption/invalidation 与请求失败共用 `recordTransportFailure()`：检查 connection generation，先脱离准确的旧 connection、推进 generation、再 invalidate，记录一次失败、撤销旧控制意图并保留自动恢复责任。重复/迟到回调不会再建连接或重复推进退避。只有一个 `automaticReconnectTask`，取消通过 schedule generation 拒绝迟到唤醒。成功验证回复复位退避；ping 不代表硬件已验证。
- `refreshStatus()`、页面 `refreshConnection()` 只读缓存；`samplePowerMetrics()` 与 `refreshMacMiniMode()` 在未连接时不打开连接（启动风扇故障状态下既有只读/睡眠恢复能力保留）。无需修改不属于本批的 ScanStore。App 初始化、回到前台/系统唤醒、失败后的唯一任务、显式注册是连接 owner；普通页面刷新和 availability 不是 owner。批准后回到 App 仍可经同一退避闸门查询注册状态并连接。
- 用户“重新连接”使用独立 `reconnectHelper()`：若已有尝试在途直接返回；否则取消旧 timer、清空 deadline，并只做一轮 ping。失败后从第一档重新开始自动退避，绝不在该点击内加第二次 ping。设置、小窗风扇/电源调板和传感器页的相应按钮统一接此入口；普通 appearance 保留缓存刷新。
- 恢复系统自动控制的责任不会随 UI 选择回到 automatic 而丢失。传输被拒时不立即恢复/重开连接；待可信 ping 成功再发送恢复请求，保留最初错误说明，当前硬件模式仍未知。已认证的恢复 RPC 失败保留既有最多三次、间隔 250 ms 的恢复尝试；传输失败立即结束该 worker，由共享退避调度下一连接，不 cancel/recreate 第 0 次。启动恢复故障锁存继续终止重连和风扇写入。
- v2/v3 协议移除兼容仍保留：仅 `unregisterHelper()` 的 OFF 请求可让已解码的旧协议错误进入原 removal-only fallback；普通 ping/采样的不兼容仍退避。listener 拒绝、传输错误或其他协议错误不能走这个例外，不绕过已有连接 deadline。

### 安全与旧断言

fix1 不改变任何 helper 的 audit token、签名、完整证书链、团队、路径、让位检查或恢复退出逻辑，不新增 RPC 或非授权退出能力；增加的状态/定时器完全在 App。新攻击面是本地调度状态，不是 helper 授权接口。拒绝/失效只会减缓请求，不能授予写权限；后台也不会自动 register 或打开批准设置。主会话的独立安全复核仍是合并前要求。JEV 在原轮被工具审批策略阻止，本轮没有可用的模型判断，未声称通过 JEV。

逐项改写依据均为用户 2026-10-10 fix1 指令“只读缓存、单次手动、指数退避”，没有删断言/跳过测试/提高阈值：

1. HelperUpgradeCoordinatorTests 原“初始 ping + 一次 500 ms retry”的两次请求断言改为一轮一次，新增模拟 10 分钟 <=15 次且精确 10 次、成功复位、并发、缓存、恢复责任、自动任务 deadline 测试。原 register 路径同样改为一次；取消与启动故障的终止断言保留。取消第二次 ping 的旧场景由手动单次/并发门控场景覆盖，因为当前不再有第二次立即 ping。
2. FanControlStartupCoordinatorTests（2 个用例、4 个调用点）、FanControlProtocolSafetyTests（1 个调用点）从页面刷新转为显式 `connectHelper()`；全部原安全断言保留。
3. FanControlPlannerTests 的失效恢复用例：新增 0.99 秒前无请求、1 秒后 ping 和恢复断言；超时用例先验证停写/未恢复，再推进模拟时钟后验证恢复，原超时提示、单写、迟到回复不得覆盖模式全部保留。公共 recorder 夹具注入模拟 reconnectClock/中性抖动并关闭真实自动 timer；超时夹具补齐已启用服务 provider，避免读取真实服务状态。
4. PowermetricsProtocolSafetyTests 的工厂明确注入缓存的批准状态和受信任 reachability；批准不能等于连接，测试 DTO 的场景必须先有已连接夹具。未批准不发送、旧协议更新标志与 v3 移除三项原断言均保留。

### 红/绿与反证

- 绿：40 需求/秒持续 600 模拟秒（24,001 个 tick），中性抖动恰为 10 次 ping，且抖动两端都 <=15；不是禁用全部重连来得到 0 次。成功后下一失败从第一档开始；deadline 未到不请求；手动跳过 deadline 一次并重新启用第一档；并发刷新/手动/模式/功率路径只有一个连接请求在途。
- 缓存链集成使用与 ScanStore 相同的 `helper.refreshStatus()` availability 闭包和真实 HelperPowerMetricsMonitor，600 秒缓存刷新/采样不发送任何请求、不发布 coordinator 变化。自动 scheduler 用 continuation 唤醒，验证只有一个 sleeper 并只在 deadline 后发第二次 ping。全部新用例没有真实 XPC、launchctl、硬件或真实偏好。
- scratch counterexamples.json 保留原安全/安装反证，替换已失效的“取消第二次 ping”配方，增补移除退避、deadline 不推进、取消单在途、手动不复位、成功不复位、刷新打开连接、功率旁路、恢复责任丢失。17 个 Swift + 1 个 Python 配方，每个 before/出现次数静态核对。**反证实际执行 NOT RUN**：公共补充要求由主会话跑。本地没有执行变异，也不称“去掉退避已跑红”。移除 `permitsAttempt` deadline 的配方必须使两端抖动/10 分钟集成红，不红不得接受。

### fix1 实际验证与主会话步骤

编译、定向和静态结果见 scratch `test-summary-fix1.json`、logs/fix1/ 和 prepared/fix1/static-checks.json（实际结果见下表）。完整定向含原清单、HelperReconnectBackoffTests、HelperPowerMetricsMonitorTests、ControlPaletteTests、HardwareControlPresentationTests；UIConsistencyRegressionTests、TestPreferenceHygieneTests 保留。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$HOME/Developer/.sc-build/r2-helper-upgrade/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER="$(paste -sd '|' "$HOME/Developer/.sc-build/r2-helper-upgrade/targeted-classes.txt")"
swift test "${F[@]}" --skip-build --filter "$FILTER"
# 再按 counterexamples.json 每条变异单独构建/定向，记录实际红并恢复原文件。
# 全部验证、反证及独立安全复核后，使用新的组合提交脚本：
python3 "$HOME/Developer/.sc-build/r2-helper-upgrade/prepared/fix1/commit-prepared.py" --validated
```

新脚本可在原 HEAD 未提交时按原四组再 fix1 两组提交；若原四组已提交，先核对 composite baseline 的文件哈希，再只提交 fix1 两组。它核对最终工作区、原产物、fix1 产物和干净暂存区，逐组先 `git apply --cached --check` 再提交。原 prepared/commit-prepared.py 针对 fix1 前的工作区，当前不应再用。本会话 .git 只读，没有提交、安装、启动真实 helper、sudo、硬件或外部消息。

| fix1 项目 | 实际结果 |
|---|---|
| 最终 Swift 编译含测试 | PASS，exit 0，21.35 秒，logs/fix1/build-delivery.log。无源码编译警告；只出现 SwiftPM 的沙箱缓存/弃用参数环境提示。首轮因捕获可变布尔值出现编译警告，改为 MainActor clock 对象的字段后消除。 |
| 新的退避/协调器用例 | 4 + 12 = 16 项全部 PASS；10 分钟 24,001 需求精确 10 次 ping。logs/fix1/targeted-final.log。 |
| 风扇/启动/旧协议/停用兼容回归 | FanControlPlannerTests 43、StartupCoordinator 9、ProtocolSafety 10、MacMiniModeCoordinator 11、PowermetricsProtocolSafety 9 均 PASS。首轮发现旧即时恢复断言和 legacy removal 被误记为传输失败，已按本节依据修正/修复并复跑通过。 |
| 全部 20 类首次运行 | 283 项、0 skip，exit 1；198 失败断言在 23 用例。logs/fix1/targeted.log。ControlPaletteTests 49 中 33 通过、16 失败；没有修改该类或面板尺寸代码。 |
| 最终相关复跑 | 235 项、0 skip，231 PASS、4 明确环境 BLOCKED；5 失败断言，exit 1，logs/fix1/targeted-final.log。保留之前其余 48 项 ControlPalette 原始结果，没有把它们删出 targeted-classes 或标为已通过。 |
| 合并不同用例结果 | 283 个不同用例：263 PASS、9 明确 EPERM BLOCKED、11 FAIL 待主会话复核。完整定向 NOT PASS。明细在 test-summary-fix1.json，分类依据及用例如下。 |
| 界面/偏好卫生 | UIConsistencyRegressionTests 46 PASS；TestPreferenceHygieneTests 21 中 19 PASS、2 CFPreferences EPERM BLOCKED。不改变偏好路径或持久化断言。 |
| Python/私有 API/shell/diff | Python 安装快照 7 PASS；private-api 守卫 7 既有 allowlisted uses PASS；bash -n 和 git diff --check PASS。对应 logs/fix1/install-tests.log、private-api.log。 |
| prepared 组合/反证配方 | static-checks.json 记录按普通 scratch 文件依次应用 HEAD + 原四组 + fix1 两组并校验所有最终 SHA-256，以及增量反向检查、原产物哈希、18 配方匹配次数。无 git index/object 写入；实际变异 NOT RUN。 |
| 实机/安装/硬件/sudo/提交/合并/全量门禁 | NOT RUN，主会话负责实际验证及独立安全复核。 |

明确环境 BLOCKED 的九项：

- `ControlPaletteTests.testConfirmedAutomaticUsesShortNativeLayoutAndCancelledDraftNeverWrites`：home fixture/CFPreferences EPERM。
- `ControlPaletteTests.testDualFanManualPaletteFitsTheSameHeightBudget`：home fixture/CFPreferences EPERM。
- `ControlPaletteTests.testFanPaletteNativeLayoutMatrixFitsAndKeepsHardwareReadOnly`：home fixture/CFPreferences EPERM。
- `ControlPaletteTests.testProductionRootMeasuresFanControlsAndEditorInsideHiddenNativePanel`：home fixture/CFPreferences EPERM。
- `ControlPaletteTests.testUnsynchronizedDualFanManualPaletteFitsWithHeadroom`：home fixture/CFPreferences EPERM。
- `HelperPowerMetricsMonitorTests.testScanStoreWiringDegradesWithoutRequestingOrAuthorizing`：home fixture/CFPreferences EPERM。
- `TestFanControlIsolationTests.testLiveCPUAndNetworkRefreshUsesAnIsolatedFanController`：home fixture/CFPreferences EPERM。
- `TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`：home fixture/CFPreferences EPERM。
- `TestPreferenceHygieneTests.testTemporarySuiteCanBeReopenedOnAWorkerThread`：home fixture/CFPreferences EPERM。

以下十一项均保留 FAIL，不能仅按“沙箱环境”豁免：

- `ControlPaletteTests.testConnectionInspectorKeepsSharedGapFromParentPanelEdge`。
- `ControlPaletteTests.testEscapeAndParentMovementKeepPaletteLifecycleBounded`。
- `ControlPaletteTests.testLongFanNamesUseShortCompactButtonsAndFullMenuNames`。
- `ControlPaletteTests.testMeasuredContentHeightRemovesUnusedBottomSpaceWithoutChangingWidth`。
- `ControlPaletteTests.testNativeHostingMeasuresCompactExpandedAndEditorWithoutAutomaticWindowSizing`。
- `ControlPaletteTests.testNativeResizeRecoversOutOfBoundsFrameWhenNoPreferenceMeasurementArrives`。
- `ControlPaletteTests.testPaletteReplacesAttachedTertiaryBeforePlacement`。
- `ControlPaletteTests.testPowerModeHoverOpensAttachedPaletteAndCrossingKeepsItVisible`。
- `ControlPaletteTests.testPowerPaletteAttachesToVisibleSecondaryColumnInUnionWindow`。
- `ControlPaletteTests.testPowerPaletteFitsMeasuredNaturalHeightInBothLanguages`。
- `ControlPaletteTests.testPowerPaletteUsesItsOwningRowInsideTheSecondaryColumn`。

这些 FAIL 包括 NSPanel 实际 frame 为 0、原生自然高度不上报和一个 `InvalidTransition { idle → failed(deinit) }`。其中 `testConnectionInspectorKeepsSharedGapFromParentPanelEdge` 与 `testMeasuredContentHeightRemovesUnusedBottomSpaceWithoutChangingWidth` 只构造 NSPanel/ControlPaletteCoordinator，不调用 helper 或此次修改的重连入口；说明至少这两项不能由热循环修复的数据流解释，但本批没有独立运行修前基线或无沙箱原生 UI 核对，不能把十一项概括为“原来就失败”或 PASS。主会话需在其正常原生测试环境复跑该类；仍红时再归因，不在本批放宽尺寸/超时断言或扩展到面板布局修复。

剩余实机边界：旧 PID 2424 无法从 App 更新获得 helper 的新退出代码；fix1 可限制新 App 的拒绝请求，但不代表现场旧进程已让位或风扇自动控制已恢复。第一次 helper 迁移、签名条件 2/4 的现场 OSStatus/完整链核对，以及实际 CPU/日志下降，仍由主会话按已批准的实机流程验证。等待期间 UI 模式保持未知，不能用 ping 或恢复 ACK 代替硬件读回。

## fix2：独立安全复核修正（2026-10-10）

依据 `logs/codex-review-security.log`（5,928 行，含复核过程、源码回显及完整末尾结论）：无 P0；P1 为同链旧助手可按 cdhash 变化触发降级、排空后缺少复验；两个 P2 为缺少跨进程让位去重/冷却、手动重连可反复清空退避。修改前逐一校验原四组和 fix1 两组产物/最终源码 SHA-256 并保留。fix2 基线为 **HEAD 5b077713 + 原四组 + fix1 两组**；前文保留阶段历史，本节描述最终行为。

### P1：签名版本单调及退出前复验

正式/Beta 打包都由 `script/helper_build_info.py` 生成助手专属 Info.plist，仅重链 helper product，将固定 identifier/executable 和 App 同一 CFBundleVersion 嵌入 `__TEXT,__info_plist`，再按原流程签名。链接输入文件名含构建号，保证缓存 helper 源码时版本变化仍改变链接命令；没有改签名后的 Mach-O 字节。

助手在签名校验后读取 `SecCodeCopySigningInformation/kSecCodeInfoPList`，且要求字典 CFBundleIdentifier 是编译期 helperLabel。SDK `SecCode.h:427-430` 将它定义为 code signing 所见的 secured Info.plist。**外层 App Info.plist、BuildInfo.plist、旁路文本、客户端标签/请求都不是版本凭据。** 版本须为正的 ASCII 十进制 UInt64，缺失、零、前导零、分段/带符号/空白/溢出均失败关闭。普通客户端认证仍与构建号无关。

原 audit token、签名有效性、完整证书链、客户端 identifier 校验保留；通过后才检查原团队/安装路径/动态有效性及客户端封印。候选须固定安装路径、严格签名有效（所有架构）、helper identifier/团队/完整链一致、前后元数据稳定、cdhash 改变，并且**候选签名版本严格大于启动时自己的签名版本**。同版不同哈希、旧版、未知版本都不能让位。

初次候选保存 build/cdhash/stamp。排空请求、停曲线/看门狗并恢复本助手的睡眠/风扇责任后，在持久准入锁内创建全新的 SecStaticCode，重新完整校验路径/签名/团队/完整链/单调版本，并要求仍是同一候选；持久记录成功才退出。任一步失败/抛错或记录写失败，取消让位，重新开放请求和采样、恢复原睡眠策略监测及安全计时器，不重施旧手动风扇/曲线，也不解除启动恢复故障锁存。另阻止取消后的原 15 秒空闲退出，避免随后悄悄加载失败候选；可以继续服务、下一合法候选仍能让位，原信号退出保留。硬件恢复失败仍不能宣称自动模式，原标记/看门狗责任保留。

### P2：持久去重及 600 秒冷却

新增固定 `/var/run/<编译期 helperLabel>.handoff`，与 `.active` 同目录。生产要求父目录 root 所有且组/其他不可写，文件 root 所有、常规文件、单链接、权限严格 0600。目录 fd + openat/O_NOFOLLOW/O_NONBLOCK，拒绝链接、错误属主/权限、非文件、超过 1 KiB 或损坏记录。测试内部构造器只用于本测试拥有的临时目录/uid，不是 RPC 输入；生产固定 root/目录。

内容只有 `highestYieldedBuild`、`yieldedAtUptime`：最高目标只能递增，同一目标只预约一次，旧目标也不能复用；两次准入至少 600 秒。systemUptime 在同一主机跨 helper 进程连续，改墙钟不清空冷却。常规 `/var/run` 重启清理边界不属于安装数据库；如果记录异常跨系统重启保留且时间在未来，失败关闭。root 删除/修改记录属于管理员边界。

所有实例对同一个 inode 非阻塞 flock；不使用换 inode 的 rename，避免各进程锁不同文件。准入、最后镜像校验和记录串行，完整写入 + ftruncate + fsync 成功才退出。初次 eligibility 只读记录/首次创建空文件，不消费版本；复验失败不消费。记录持久化后若退出前崩溃，目标仍视为已预约，保守地不重复让位。部分写/格式损坏只取消退出、恢复服务，不自动删 root 文件，后续可能需另行授权的管理员修复。

**攻击面变化**：新增一种固定、root 0600、最多 1 KiB 的状态写入，只有签名构建号及启动后时间。没有用户数据、网络、新 RPC/路径输入、新子进程命令或新风扇/充电策略。未经原客户端校验者不会打开记录或消耗次数；完整链未放宽为只比团队。powermetrics 固定命令、两秒限频、五秒超时、512 KiB 上限及每连接身份闸门保留。

剩余安全边界：最终校验与 launchd 的后续 exec 无法针对“拥有安装目录写权者”组成跨进程原子操作。本轮补了排空后/退出前复验和候选一致性，不能承诺抵抗最终校验后继续改镜像的管理员/目录写入者。安装/启动目录保护、实际加载镜像及首次旧 helper 迁移须主会话重新独立安全复核并按已授权实机流程确认；缺少签名版本的旧 helper 不能被放宽成可信版本。

### P2：手动重连独立 10 秒门槛

`HelperManualReconnectCooldown` 与自动退避分开，使用单调时间；首次手动尝试消费 10 秒，失败、成功、再点击和自动 reset 都不清空它。准入在取消自动任务/reset/XPC 前执行，并保留单在途。按钮显示“等待 N 秒”并禁用；设置、风扇/功率浮层、紧凑状态入口都复用这个倒计时。生产倒计时仅点击后最多十秒每秒发布缓存变化，不查 availability、不发 XPC，终止时取消；假 sender 使用注入时间，不开这个 UI 工作者。fix1 自动退避、抖动/五分钟上限及缓存刷新行为保留。

### 测试与旧断言

新增 15 项 Swift 测试，最终核心 39 项全通过：HelperUpgradeSafetyTests 12、HelperUpgradeLedgerTests 6、HelperUpgradeCoordinatorTests 14、HelperReconnectBackoffTests 5、HelperSignedBuildPackagingTests 2。覆盖同版不同哈希/旧版拒绝、新版允许、未知版本、恢复后复验失败取消退出、失败/抛错不消费版本、新实例去重、599.999 秒拒绝/600 秒允许、flock 互斥及不可信文件失败关闭。非 root 临时文件测试的多实例验证持久策略，不冒充真实 root helper/launchd 跨进程验收。

模拟 40 次/秒连点持续十分钟，手动恰 61 次（0、10、…、600）；成功不能重置手动门槛。自动拒绝十分钟仍 10 次、不超过 15；并发仍单在途。新增 Python 版本生成测试 3 PASS，原安装快照 7 PASS。

另编译、ad-hoc 签名普通 Foundation 隔离镜像，**没有运行真实 helper，也未执行这个被检查的镜像**。独立静态签名读取器两次查询（单文件/模拟 App Resources 内）均 `valid=0/signingInfo=0`，版本均 20261010015824；外层未签名 App plist 故意设 99999999999999，不影响结果。只证明嵌入/读取来源，不证明真实团队/完整链或旧驻留进程行为；日志 `logs/signed-build-fixture-fix2.log`。

旧断言依据：原安全矩阵补明确递增版本，8 组合/未知/未变拒绝断言保留；设置固定标题守卫改为倒计时标题+禁用守卫，批准/停用保留。`ControlPaletteTests.testFixtureFactorySealsTransportAndBothPaletteRoutesReuseProductionContent` 的 send 签名守卫落后于 fix1 removal-only legacy fallback 参数，更新为当前完整声明，仍逐字锁定**第一句**拒绝 data-only fixture，所有生产路由/隔离断言保留；不放宽 D48。

`counterexamples.json` 共 28 条（27 Swift + 1 Python），新增降级、同版、最后策略复验/真实 adapter 复验、取消后空闲退出、持久去重/冷却、ledger 复验、手动冷却/闸门反证；每条目标文本恰出现一次。**NOT RUN，主会话执行真实变异并要求对应测试红。** 保留 fix1 去退避必红、成功复位、单在途、缓存/恢复反证；原封印变异只同步 Optional 返回类型（false → nil）。

### 实际结果与交付

最终构建 **PASS**：exit 0、21.29 秒，`logs/build-fix2-delivery.log`（首轮 126.15 秒、一次增量 20.00 秒亦通过）。仅 SwiftPM 用户缓存权限/弃用提示，无源码错误。22 类完整定向 298 项首轮 exit 1（195 断言失败、21 失败用例），再仅复跑最终变动/core 与修正的源码守卫 40 项，40 PASS、exit 0，`logs/targeted-fix2-final.log`。

| 最终唯一用例 | PASS | BLOCKED | FAIL |
|---|---:|---:|---:|
| Swift 定向共 298 项 | 278 | 9 | 11 |
| 核心 39 项 | 39 | 0 | 0 |
| UIConsistencyRegressionTests | 46 | 0 | 0 |
| TestPreferenceHygieneTests | 19 | 2 | 0 |

九项 BLOCKED 和十一项 FAIL 与 fix1 一节最终清单相同：七项操作夹具 Cocoa 513/EPERM、两项偏好明确有 `sandbox_extension_issue_file ... Operation not permitted`；FAIL 是原生 frame/自然高度/InvalidTransition。没有无沙箱基线复跑，不能宣称“原本就失败”。逐项耗时/日志在 `test-summary-fix2.json` 及交付副本；整体 **NOT PASS**，主会话复跑归因后才能关门禁。

Python 3+7、两份打包脚本 bash -n、私有 API（仍 7 项）及 diff --check PASS。真实 helper、硬件、sudo、安装、全门禁、反证、提交、合并和 fix2 独立安全复核 **NOT RUN**。既有 JEV 调用被 `MCP tool call requires approval, but approval policy is never` 阻塞，无模型结果，未绕过/重复申请。

交付 `prepared/fix2/`：01-helper-security（版本/复验/ledger/正式及 Beta 嵌入）、02-manual-cooldown（10 秒门槛/倒计时/测试/旧守卫）、03-handoff。20 个增量文件，最终组合 28 个文件；含 trailers、all.patch、SHA-256 manifest、static-checks、定向/反证/test-summary 和提交脚本。普通 scratch 文件树验证 **HEAD + 原四组 + fix1 两组 + fix2 三组**，不写索引/对象。原产物保持原样，请用 fix2 脚本处理完整组合。

主会话沿用前文 F 环境，filter 用 `prepared/fix2/targeted-classes.txt` 的 22 类；跑两份 Python、28 反证、新独立安全复核，并按清单处理原生/权限失败。先 `python3 prepared/fix2/commit-prepared.py --check`，完成上述验证后 `--validated` 提交尚未提交的组；脚本不安装、运行 helper、合并或 push。

## fix3：第二轮安全复核修正（2026-10-10）

输入为 `logs/codex-review-security-r2.log` 全文（6,263 行，含历次复核回显、执行记录、源码及末尾完整结论）。签名版本主体、最终复验、正常账本去重和手动门槛已获该轮静态复核确认；本轮处理其账本损坏、构建信息符号链接两个 P2，以及主会话明确接受的剩余 P1。修改前验证三轮全部产物和最终 28 文件 SHA-256，保存 fix3 基线快照。**基线为 HEAD 5b077713 + 原四组 + fix1 两组 + fix2 三组**；前三轮产物不重生成、不覆盖，前文为阶段历史，最终行为以本节为准。

### 安全说明：主会话接受的剩余 P1

主会话明确接受“最终复验到 exit，再到 launchd 按路径启动”的剩余窗口。**判断前提：有足够权限替换安装目录内助手镜像的主体，本来就能直接替换该文件，待 launchd 下一次启动加载同团队旧版；这项让位机制没有扩大该主体的既有替换能力。** 此接受只适用于具有该目录/镜像替换权限的主体，不把普通未认证进程视为同等权限，也不意味着任何同团队代码都能请求退出。

缓解保留：签名保护的版本严格递增；排空及恢复硬件责任之后，对同一候选再次完整复验签名、团队、完整链、固定安装路径、cdhash、元数据和版本；持久版本去重、600 秒让位冷却；原 SMAppService/BTM 注册批准及签名团队身份边界。客户端仍须通过全部原监听认证，再满足额外路径/团队/封印检查，未通过者不能检查/改账本或触发退出。BTM 和这些检查不固定最终 exec 的镜像，不能宣称消除窗口；实机注册批准及加载仍须主会话验证。

本项不改退出流程。账本持久化必须先于退出，去掉 fsync 会削弱跨进程去重，无法因此消除 launchd 路径窗口；不声称有跨进程原子保证。本节的“主会话接受”取代 fix2 对该窗口尚待判断的表述，不冒充本轮新的独立安全复核结论。`main.swift` 本轮仅把启动时读取的签名版本传给账本，缺失则不准入。

### P2：恢复损坏账本且保留冷却

账本接口现在同时接收经签名验证的候选和启动时自身版本。只有 `previous > target && previous > running` 才把高版本视作无效；位于自身/候选范围内的真实历史保留，去重仍为 `target > previous`。非空解析损坏、不可解析版本、超出 UInt64、超过 1 KiB 的内容和已有零长度文件，都按无版本历史恢复。保留 **1 KiB 读取上限**；超长内容不整体读取，使用已验证文件的 mtime 恢复。

修复发生在原目录 root 所有、组/其他不可写以及文件 root、常规文件、0600、单链接检查之后；目录 fd、openat/O_NOFOLLOW/O_NONBLOCK 和同 inode 非阻塞 flock 均保留。属主/模式/链接/目录不符或读写失败仍拒绝，绝不自动删文件、换 inode 或改权限。测试专用内部构造器只用本测试的临时目录及当前 uid，不是 XPC 输入。

损坏记录的 mtime 按当前墙钟年龄转为主机 uptime，与仍可解析的记录时间取较晚值，写成“无历史版本但有冷却”的有效记录。损坏记录时间或 mtime 在未来时，保守保留从当前 uptime 起完整 600 秒；不把异常未来值变成永久阻断。该恢复结果先完整 pwrite/ftruncate/fsync 到同一锁定 inode，后续实例读取持久 uptime，**不会因修复写入更新 mtime而重新开始计时，也不会因清零而即时放行**。合法历史继续只用 uptime，后续墙钟调整不重置它；墙钟仅用于无法直接恢复损坏时间的首次 mtime 换算。

新文件用 O_CREAT/O_EXCL 区分，且拿到锁后仍须零长度才初始化 `neverYielded` 标记；若竞争进程已写入，则读取该记录。首次准入不消费目标，最终镜像复验失败/抛错仍可再尝试。已有空文件不能冒充首次创建。修复只恢复可用性，不赋予退出资格；600 秒过后仍须最终全镜像复验并持久记录目标才退出。

**攻击面变化**：受保护的固定 root 状态文件新增有界自修复写入，内容仍仅版本、时间及首次创建标记。普通用户不能写 root 0600 记录，未认证客户端也不能进入该路径；没有新 RPC、网络、用户内容读取、子进程或硬件写入。丢失的损坏版本历史不能重建，恢复期以持久冷却限制重启频率；root 主动编辑/删除记录仍属于原管理员边界，不宣称对 root 篡改保留完整去重证明。

### P2：构建信息拒绝符号链接

`helper_build_info.py` 先保留原 canonical UInt64、固定标签/可执行名校验，再用 `os.open(O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o644)` 打开链接输入；写入通过 fd 上下文完成。已有链接及悬空链接都以 ELOOP 拒绝，不覆盖目标、不创建链接目标，链接本身保持。普通新文件和既有常规文件仍可生成正确 plist。本轮没有执行打包/安装或真实助手。

**攻击面变化**：构建缓存写入者不能再借预置符号链接让这个写入器覆盖构建用户的其他文件。这不改变构建缓存本身的权限，也不宣称阻止拥有目标文件直接写权限者改内容；root 账本的链接/权限边界未放宽。

### 测试、旧断言及反证

账本最终 11 项全通过；新增 5 项独立用例并扩展原损坏用例矩阵，覆盖合法极高版本与损坏恢复、mtime/记录时间取较晚值、超长/非空/清零、未来异常时间、持久冷却、同 inode/0600 保持及不可信目录/文件不被修写。原正常去重、600 秒、flock、复验失败/抛错、非法时间和链接拒绝断言保留。

旧断言依据是本次用户明确要求损坏内容可恢复：原 `testMalformedOversizedStateAndUntrustedParentFailClosed` 拆为“数据损坏需冷却后恢复”和“目录/属主/模式不可信仍失败关闭”，没有删权限断言或放宽 600 秒。新增 `running` 参数后，去重夹具在模拟已更新的自身版本时传 21/22，保持旧目标拒绝及冷却断言；首轮发现一处仍传旧自身 20，修正后原测试通过。这是夹具身份修正，没有改产品准入条件。本轮没有改界面/原生失败测试，也没有放宽阈值或跳过用例。

Python 生成器 5 项 PASS（新增已有目标/悬空链接两项），安装状态快照原 7 项 PASS。核心 44 项 PASS：账本 11、安全策略 12、App 协调 14、退避 5、签名打包守卫 2。

`counterexamples.json` 共 **36 条（34 Swift + 2 Python）**，新增 8 条：极高版本不修复、可信自身历史被丢弃、修复清掉冷却、忽略 mtime、忽略可读时间、清零冒充首次、修复不持久化、构建写入删除 O_NOFOLLOW。每个目标文本恰出现一次；两个 fix2 账本配方只同步拆开的 guard 文本，断言和 filter 保留。**NOT RUN，主会话逐条做真实变异并要求指定测试红**，本轮只验证配方锚点及数量，保留去退避必红等既有反证。

### 实际验证与交付

初次构建 PASS，exit 0、21.49 秒，`logs/build-fix3.log`；修正夹具后增量构建 PASS，exit 0、6.99 秒，`logs/build-fix3-final.log`。只有 SwiftPM 缓存权限/弃用提示，无源码错误。22 类首轮 303 项，exit 1、196 断言失败、21 失败用例、72.427 秒，`logs/targeted-fix3.log`；最终核心复跑 44 项全部 PASS，exit 0、0.174 秒，`logs/targeted-fix3-final.log`。

| 本轮最终唯一用例 | PASS | BLOCKED | FAIL |
|---|---:|---:|---:|
| Swift 定向 303 项 | 283 | 9 | 11 |
| 核心 44 项 | 44 | 0 | 0 |
| UIConsistencyRegressionTests | 46 | 0 | 0 |
| TestPreferenceHygieneTests | 19 | 2 | 0 |

九项 BLOCKED 与十一项 FAIL 的逐项清单沿用 fix1/fix2，均在本轮日志中再次出现。九项逐项确认 EPERM/Cocoa 513；十一项仍为原生 frame/自然高度/InvalidTransition。无法据此宣称“本来就失败”，主会话仍须在合适原生环境复跑归因。整体 **NOT PASS**；逐例时间/状态/日志在 `test-summary-fix3.json` 及 prepared 副本中。

Python 5+7、bash -n 两份打包脚本、私有 API 守卫（仍 7 项）、Python 脚本语法和 diff --check PASS。实际 root 权限/launchd/BTM、真实 helper、硬件恢复、sudo、安装、全门禁、反证、提交、合并及 fix3 新独立复核 NOT RUN。JEV 既有调用因 approval policy=never 被拒，没有模型判断，未绕过权限。

交付 `prepared/fix3/` 三组：01-ledger-recovery（账本/main 参数/Swift 测试）、02-build-info-safe-write（写入器/Python 测试）、03-handoff。6 个增量文件，最终组合仍 28 文件；含 trailers、all.patch、manifest、static-checks、test-summary、定向和反证清单及提交脚本。普通 scratch 文件树逐组验证 **HEAD + 原四组 + fix1 两组 + fix2 三组 + fix3 三组**，每个历史边界 SHA-256 与原清单一致，最终所有文件一致，不写 git 索引/对象。提交脚本支持 12 组任一已验证边界续接，核对全部四轮产物和未知改动。

主会话先 `python3 prepared/fix3/commit-prepared.py --check`；沿用前文 F 环境并用 `prepared/fix3/targeted-classes.txt` 的 22 类复跑，执行 `python3 -B script/test_helper_build_info.py`、`python3 -B script/test_helper_upgrade_status.py`、36 反证和 fix3 独立安全复核，处理权限/原生失败后再用 `--validated` 提交剩余组。已接受的 P1 窗口按以上前提记录，测试门禁和新的独立复核仍分别按实际结果判定。
