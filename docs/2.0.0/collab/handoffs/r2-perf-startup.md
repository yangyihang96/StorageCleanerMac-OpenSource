# r2-perf-startup 交接

日期：2026-10-11（Australia/Sydney）。分支 `task/r2-perf-startup`；基线 `7b94e3101ceee7927fbd5267ff433a8cb4be7900`。本轮仅修改该 worktree，初始工作区干净。实际 Git 管理目录位于主仓库，当前权限只读，故按 scratch `prepared/` 分组交付；没有提交、合并、安装或运行真实 App。

依据已读取：`~/Developer/.sc-build/_prompts/common.md`、`codex-build-common.md`、`r2-perf-startup.md`；协同 RULES 全文及 D5/D48/D55/D60/D74；只读排查 `r2-mini-prestored/logs/codex-startup-cost-review.log` 与 `measure/d74-report.md`。旧测量指出启动签名检查占大量样本、居民源启动集中，以及隐藏稳定段存在成本；这些是本轮定位依据，不能作为本轮 CPU 收益或最终门禁证据。

## 1. 到期自动更新与首帧／首样本错开

**实现完成；计数测试 PASS。** `StartupApplicationUpdateScheduler` 合并启动／激活请求，最早 6 s 开始自动策略检查；首轮显示机会或 CPU 样本尚未就绪时最多再等待 4 s，总上限 10 s。首轮优先条件来自生产采样上下文及已有 CPU 样本。实际执行时重新检查是否到期和能否扫描，之后仍调用原 `ScanStore.prepareApplicationUpdatesOnLaunch()`，没有修改 ScanStore 或自动安装策略。

主窗口真实可见且当前页为更新页时，立即提升已排队请求。扫描／重新扫描／重试按钮通过 `performUserRequest` 取消排队的自动请求，然后调用原扫描或带应用 ID 的重试方法；手动请求保持即时响应。终止阶段取消启动等待。所有等待有限，没有常驻轮询。

预期减少的工作：首帧／居民首轮阶段自动扫描调用为 **0**；多次激活合并为 **1**；未到期、关闭、手动自动策略的 sleep／scan 都为 **0**。提升执行 **1** 次，取消的旧等待不能再次执行。`StartupApplicationUpdateSchedulerTests` 6 项均 PASS，包含 `[6,4]`／`[6]` 的假时钟期限、策略变化、终止、手动刷新与立即提升。

反证：`startup-restored-immediate-scan` 恢复抢占首轮扫描，0→1 的计数断言应失败；`startup-page-promotion`、`startup-automatic-policy`、`startup-bounded-delay` 分别撤销提升、到期门控与上限。均仅准备，**NOT RUN**。

## 2. 清单展示的持久化元数据／签名缓存及执行重验

**实现完成；新增缓存与执行测试 PASS。** 新 `ApplicationInventoryMetadataReader` 仅接入 inventory scanner；默认 `ApplicationMetadataReader` 仍直接读取文件和 Security 签名，不接入缓存。缓存放在 `AppDataDirectories.applicationSupportRoot/AppUpdates/inventory-metadata-v1.json`，沿用 `STORAGE_CLEANER_INTEGRATION_ROOT` 隔离；版本 1，最多 8 MiB／2,048 条。信封含 payload checksum；损坏、未知版本、checksum 错、大小或条目超限时丢弃重建。缓存命中不写文件；新增／失效项在扫描末尾批量 flush。

指纹含设备、inode、ctime、mtime、出生时间、mode、size、flags，及整棵 bundle 子项 stat 摘要。因此 Info.plist、主可执行文件、`_CodeSignature`、收据、嵌套代码与子资源均参与失效，根目录时间不变也能识别。挂载身份含 fsid、路径、来源、flags、UUID；外部／未知卷再加进程会话与 mount/unmount generation。外卷保守地不跨真实进程重启复用，避免无法证明 App 停止期间未重挂载的情况。无法安全取得完整指纹时走未缓存读取。只持久化 `valid-code-signature` 元数据；暂时不可读或无效签名继续重试。运行状态、扫描日期和本地化来源显示在命中后更新。

预期减少的工作及实测测试断言：三个未变 bundle 冷读后重建 reader/cache，暖读新增完整元数据读取 **0**、签名检查 **0**、缓存写入 **0**；两个 bundle 重建 scanner 后累计签名检查仍为 **2**。同路径同版本替换、新增、子资源改动、Info／执行文件／签名资源变化、挂载身份变化均增加对应实际读取。暂时不可读→恢复→暖命中，累计完整读取／签名检查 **2**。`ApplicationInventoryMetadataCacheTests` 11 项 PASS。

执行信任边界逐 provider 补充：

| 路径 | 实际目标重验与测试证据 |
|---|---|
| Homebrew cask | 命令前后直接重新读取所选 bundle 和签名，比较冻结身份及实际版本；同版本子资源修改在命令前阻止执行、命令后不能报告成功。warm display cache不减少这两次实际验证。 |
| Homebrew formula | 命令前后重新查询所选实际 token 的当前 CLI inventory，不把 bundle 签名套用于 formula。 |
| Official website | installer 替换前直接读取所选目标，原替换 closure 继续验证 installed URL；executor 独立在前后读取实际路径与身份／版本。当前 running-state provider 显式走 `MainActor.run`。 |
| App Store／Sparkle／Vendor／Manual／System | 各 provider 都拒绝自动 prepare/install；逐个验证这些拒绝路径。外部更新结果通过未缓存 actual-path rechecker 核实，同版本子资源篡改不得接受。 |
| Homebrew reconciliation | 只验证被选择并通过 preflight 的路径；另一 artifact 的较新版本不能冒充该目标更新完成。 |

`AppUpdateFreshActualTargetTests` 9 项 PASS。既有 coordinator 成功夹具现在写入所选 `appURL`；原版本／状态断言保留。Homebrew provider 旧成功夹具注入新增的 fresh 验证响应，保持原断言。`TestScanStoreFactory`、live scan 夹具的 scanner 明确使用 `metadataCache: nil`，缓存专项夹具显式注入 TestFileSystem 根，避免读写真实 App 数据根。

反证：17 条展示命中、scanner 接线、替换／子资源／挂载／损坏／边界／暂时不可读，以及各执行验证和所选目标核对的撤销补丁，见总 JSON 的 scope `2`。**NOT RUN**。

限制：暖命中仍需完整子项 stat 遍历及首次读取缓存文件；有效签名以外的结果不持久化。物理完整读取与签名调用减少已由测试证明，CPU／磁盘总收益须实测，不能直接从调用数推导。

## 3. D74 居民首轮有界错峰

**实现完成；新错峰测试 PASS。** 仅生产 controller 调用 `MenuBarSamplingContext.beginStartup`；独立读者和既有显式测试不隐式延迟。CPU／内存轻量状态与网络计数先取得基线。有限首轮期限为：硬件 GPU／SMC 0.75 s；卷／电池／磁盘 1 s；进程及内存分组 2 s；CPU IOReport 2.5 s；功率 3 s；helper 连接／模式元数据 4 s。controller 使用六次有限启动机会，随后仍由原 resident tick 控制；没有第二个常驻采样时钟。

SystemMonitor 保留全部 primary kinds，尚未安排的硬件返回等待状态而不制造失败、时间戳或历史点。Aux 在设置 attempt／sampling state 之前检查期限。进程 timeout 的起点仍由 ScanStore 在实际开始安排该轮时设置，未提前启动计时。提前打开面板提升缺样源，且不取消已取得的首轮基线或覆写源时间戳。

预期减少的工作：t=0 非必要 GPU／SMC 和 Aux reader 调用为 **0**；各源到达对应期限后才有首个物理读取，重复启动机会不会绕过已有 5／15／60 s 门控。`ResidentStartupScheduleTests` 4 项 PASS，包含物理 reader 计数、`activeHardwareReadCount == 0`、未安排状态 `.sampling`／`.idle`、打开提升、4 s 元数据首轮和 60 s 后续门控。已有 sampling plan 28 项 PASS；既有 prestored 的两个 ScanStore 夹具因家目录权限受限未通过，主会话复跑。

首轮“约 5 s 内”是本轮有限调度预算，不是对阻塞驱动、系统负载或 Shell 返回时长的虚假保证。各源第一次读取与原 tick 的相位会发生变化；原六项保持其他源的周期常量、来源、数据内容和源时间戳定义；D75 对逐 App 网络的局部频率决定见追加节。实际首次有效样本与第一／第二轮间隔须在主会话实测中报告。

反证：`resident-hardware-first-round`、`resident-aux-first-round`、`resident-metadata-first-round` 恢复集中读取，应使首轮零调用断言失败；`resident-demand-promotion` 撤销面板提升应失败。**NOT RUN**。

## 4. GeneratedArt 可见性、当前页优先及取消

**实现完成；图片生命周期与既有图片测试 PASS。** ContentView 默认隐藏，实际附着 NSWindow 的 isVisible、最小化、occlusion、App 隐藏状态共同决定可见性；更新页提升也使用这一实际可见条件。当前页 landing art先加载，其余 header逐张预载。GeneratedArtView、FeatureLightfieldArtwork 和 option icon 的 task 同时以资源与可见性为 ID，隐藏时取消请求，不再由构造视图树无条件预载。

library 保留单资源在途合并与已解码缓存。每个请求登记 waiter；取消最后一个请求会取消 detached decoder；有其他可见请求时继续共用原解码。同步 ImageIO 不能安全强行中断，取消检查在读取／解码边界执行，物理在途门控直到解码退出才释放。取消不会被记成 missing；之后重新显示可重试。缺失资源继续原占位。

预期减少的工作：隐藏预载 resolver／decoder **0**；同资源显示、预载与重开累计解码 **1**；隐藏时 speculative 队列只完成已开始的 **1** 次，不启动后两张，并断言 detached decoder收到取消。两个 waiter共用 **1** 次物理解码。`GeneratedArtLifecycleTests` 4 项 PASS，`GeneratedArtTests` 5 项 PASS，UI 一致性 46 项 PASS；资源内容未改。

反证：`art-hidden-preload` 撤销可见性门控，应使零调用变成两次；`art-detached-cancel` 恢复 detached task脱离请求生命周期，应使取消计数 1→0／取消错误记为missing。**NOT RUN**。

## 5. SMC 与 HID 静态重复工作

**实现完成；传感器新增测试 PASS。** 风扇、芯片温度、完整热源、功率与电池共用 `SMCReadSession`。同一锁串行保护 open／close、key-info与实时 bytes。元信息和明确 missing 最多 512 项；不缓存实时值或临时 unreadable。只有明确 key-not-found 能作负缓存；transport loss结束本 pass连接，下个 pass惰性重连，不为每个剩余 probe重复open。sleep/wake同步清正负元信息与连接；睡眠期间不open或读bytes。open失败保持invalid／unreadable，不误称unsupported。

HID 沿用原已复用且串行化的 client，只缓存 service identity和名称；原生身份保留CF对象以防地址重用。每轮取得当前完整服务图、使用本轮服务对象读取新事件；图变化清名称缓存，服务不可读或临时无名称会重试，不回放旧温度。

预期减少的工作：八个 provider pass 的 open **8→1**；稳定key两读的key-info **2→1**，bytes仍 **2**；missing三读的key-info **3→1**、bytes **0**；两个HID服务两轮名称解析 **4→2**，图发现仍 **2**、事件仍 **4**。sleep/wake后重新取得正负元信息；并发 driver最大同时调用 **1**。`SMCReadSessionTests` 19 项、`HIDTemperatureMetadataCacheTests` 8 项全部 PASS；相关纯解码／无值规则／详细展示测试通过。

反证：17 条复用、key-info、missing、sleep/wake、并发、临时失败、HID名称／服务图／事件的独立撤销补丁，scope `5`。**NOT RUN**。无实际硬件写入或硬件收益测量。

## 6. 进程共享发现及静态元数据

**实现完成；进程新增测试 PASS。** CPU／磁盘帧在 ps前登记in-flight发现，memory通过生产入口最多等待250 ms取得同一完整清单；失败、超时或memory先到则回退完整native发现。清单最多借用一次、有效期1 s；不用Top-K替代完整内存清单。每轮仍读新的ps字段、rusage birth、BSD身份、权限与内存量；动态失败淘汰对应PID，成功全量发现淘汰退出者，出生身份或PS路径提示改变时重读静态路径／名称。缓存条目上限16,384。

直接应用的展示解析可复用，父进程归属与Launch Services fallback仍重新解析。RunningApplication成功名称／路径只读一次，birth、策略与active状态每轮读取；不完整字段继续重试。退出执行仍在MemoryOptimizerService中对实际NSRunningApplication重新验证，未使用展示缓存作为退出授权。

预期减少的工作：生产入口下memory在ps in-flight时，`ps + proc_listpids` 两次发现变为一次ps，native discovery **0**；稳定PID的三轮CPU＋三轮memory消费，path／fallback name **6→1**，动态usage／BSD读取次数不减少。直接应用展示解析 **3→1**；RunningApplication名称／路径 **3→1**，birth／policy／active仍 **3**。`ProcessSamplingCacheTests` 24 项、`MemoryApplicationMetadataReuseTests` 4 项 PASS，覆盖真实入口的并发顺序、timeout／failure fallback、双方取消隔离、同路径birth变化、权限恢复、PID复用和退出。

反证：11 条共享发现、path／name／presentation、birth、权限恢复、退出、完整清单、取消和容量的独立撤销补丁，scope `6`。**NOT RUN**。命中率受启动顺序与250 ms预算影响，额外有界等待的延迟及实际CPU收益由主会话测量。

## 旧断言与夹具调整

没有删除测试方法、放宽阈值或新增skip。唯一旧源码断言改写：`SystemUtilitySafetyTests.testToolsMenuKeepsOnlyGlobalUtilityCommands` 中 `onScan: store.refreshAppUpdates` 改为同时要求 `onScan: refreshImmediately` 和 `StartupApplicationUpdateScheduler.shared.performUserRequest { store.refreshAppUpdates() }`。依据本轮任务卡第1条“用户刷新立即提升”；仍要求更新页接入原扫描，额外证明它先取消启动等待。该方法单独复跑结果见下方验证表。

其余旧断言未改。AppUpdateCoordinator成功夹具从另一artifact改为所选appURL，落实实际目标验证；Homebrew旧成功夹具注入fresh before/after响应；两个scanner夹具禁用持久缓存以保持测试隔离。新的共用helper、计数Inspector／reader、Release引用的生产注入接口均不依赖`#if DEBUG`。

## 原六项首轮验证（D75 追加前）与待主会话确认

| 检查 | 实际结果／exit code | 证据（本批 scratch） |
|---|---|---|
| 最终 Debug `swift build "${F[@]}" --build-tests` | **PASS／0**；全部测试目标编译 | `logs/debug-build-delivery.log` |
| 用户要求的正常 Release `swift build -c release "${R[@]}" --build-tests -Xswiftc -enable-testing` | **BLOCKED／1**；`dsymutil` 生成 `MemoryFixtureApp.dSYM` 被拒 `Operation not permitted` | `logs/release-build-tests.log` |
| 补充 Release，同命令再加 `-debug-info-format none` | **PASS／0**；520.41 s，生产优化代码与全部测试目标编译 | `logs/release-build-tests-no-dsym.log` |
| 最终文件的补充 Release 增量复核 | **PASS／0**；旧源码守卫修改后再次编译全部测试目标 | `logs/release-build-final-no-dsym.log` |
| 29 类定向测试（初轮） | **FAIL／1**；757 tests，13 既有 skip，54 失败记录／51 失败 case；新增 9 类 89 项均 PASS，UI 一致性 46 项 PASS | `logs/targeted-tests.log`、`targeted-failures.json` |
| 手动更新入口旧源码守卫单独复跑 | **PASS／0**；1 test，0 failures；剩余失败 case 为 50 | `logs/targeted-source-guard-recheck.log` |
| `git diff --check`、private API 与 Views／memory-purge／冲突副本静态守卫、补丁完整性 | **PASS**；交付生成时逐命令记录；private API 为 7 allowlisted uses，allowlist 未改 | `prepared/static-checks.json` |
| 全量／严格并发专项／反证／实机／测量 | **NOT RUN**；按本轮授权边界交主会话 | `validation-summary.json`、`counterexamples.json` |

补充 Release 使用正常 `-c release` 优化且编译了全部测试，只取消符号信息以避开被拒的 dSYM 生成；没有把 Debug 编译冒充 Release，也不能据此声称正常 Release/dSYM 门禁 PASS。编译警告仅为既有 `--skip-update` deprecated 与用户级 SwiftPM 缓存权限。最终日志的 SHA-256 绑定在 `validation-summary.json` 与 prepared manifest。

依 RULES 第2.3节，Release 临时构建用后已删除（包含本批离线依赖副本），只留日志与 `release-cleanup.json`；Debug 产物留待主会话合并后清理。主会话若离线复跑 Release，请先从规则指定的 `r2-u1-preselect/debug/{checkouts,repositories,artifacts,workspace-state.json}` 复制到新建本批 `release/`，中立依赖源未改。

初轮定向失败的完整逐方法分类见 scratch `targeted-failures.json`。44个失败case包含家目录夹具／进程权限错误；2个live NSWorkspace case取得空应用列表；2个偏好case由于CFPreferences沙箱扩展／synchronize失败；1个旧源码断言已修复并单独复跑。另2个case需主会话核对：`SystemMonitorServiceTests.testLightweightMemoryStatusSnapshotSkipsProcessEnumeration` 的free-percentage断言，以及`SystemUtilitySafetyTests.testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt`的受限夹具teardown错误。不能把这些残余失败写成PASS。没有为此改测试、路径安全规则或偏好根。

初轮13个skip为既有可用性／live条件，日志逐条记录；本轮没有添加skip。严格并发专项、verify.sh完整门禁、Debug/Release全量、60条反证、真实App、硬件、安装、签名／打包和性能测量均未由本轮执行。

### 主会话命令与顺序

```zsh
cd ~/Developer/sc-worktrees/r2-perf-startup
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-perf-startup/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(paste -sd '|' ~/Developer/.sc-build/r2-perf-startup/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
R=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-perf-startup/release --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build -c release "${R[@]}" --build-tests -Xswiftc -enable-testing
```

随后在主会话范围内执行标准完整门禁：`DEVELOPER_DIR=... STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=<独立本批门禁根> script/verify.sh`。不要复用其他批次scratch，不因当前沙箱失败削弱断言。正常Release/dSYM、全量及严格并发须分别确认。

反证红／绿：先让定向全部绿；在隔离源码副本按 `counterexamples.json` 的每个 `mutations[].patch` 单独应用，重新编译Debug，执行该 `filter`，必须**编译通过且测试断言FAIL**；编译失败不能当作捕获。还原后同filter应PASS。60条已静态核对唯一anchor与存在的测试方法，没有在本交付树应用或运行。

测量由主会话在合并前执行：现有 `r2-mini-prestored/tools/measure-hidden-cost-v2.sh` 的 `--app <隔离QA包> --label before|after`，按before→after→before→after交错各≥2次。到期冷启动不加seed；未到期暖启动加 `--pre-seed-update-check`。分别用按真实时间顺序的四份summary执行 `--compare ...`，报告startup和600 s稳定段的主PID、子进程、合计CPU与唤醒，保持脚本预先固定的稳定判据。核对两包资源清单／hash一致、窗口隐藏与首次样本证据；报告首次有效样本及第一／第二轮间隔，而不只报告启动调度期限。这个warm条件预置的是更新检查时间，并不自动证明已缓存元数据的到期扫描收益；缓存收益可另补隔离root下持久化inventory的读次数／重启验证。正常Release签名／打包验收与测量另行记录。

完成必要验证后，由主会话在Git可写环境执行 `python3 ~/Developer/.sc-build/r2-perf-startup/prepared/commit-prepared.py --validated`。脚本核对分支、完整基线、空暂存区、最终文件和准备产物SHA后按顺序提交，不自动构建、运行App、合并、推送或安装。

## 分组及剩余边界

`prepared/` 六组：01启动／居民调度；02展示缓存／执行验证；03图片可见性／取消；04传感器复用；05进程复用；06交接。`manifest.json`包含完整基线、分支、每个最终文件SHA及组顺序，`static-checks.json`记实际检查与失败／未运行边界。scratch还包含`targeted-classes.txt`（31类）、`counterexamples.json`（60条）、`validation-summary.json`、`targeted-failures.json`、`release-cleanup.json`和逐模块证据。

原六项未改扫描周期常量；D75 追加仅改变逐 App 网络隐藏档位。D74来源、nettop实现、ScanStore、资源文件和private API allowlist未改（nettop服务仅更新说明注释）。现有读取内容／源日期继续走原所有者；未关闭数据源，其他源的5／15／60 s周期保留。

JEV：**NOT RUN**。可用工具`mcp__jev__jev_decide`没有模型／推理参数；调用被工具的`requires approval`要求阻止，审批策略为`never`，没有执行或返回判断。没有声称经过JEV复核，也没有替换当前模型设置。CPU实测、正常Release符号生成与沙箱外门禁仍是合并前的明确待办。


## D75 追加：仅逐 App 网络隐藏 60 秒

用户 2026-10-11 在主会话明确选择“隐藏时 60 秒一次”，授权局部修改 D74②。基线仍为 `7b94e3101ceee7927fbd5267ff433a8cb4be7900`，继续同一分支及 prepared 交付。追加前核对43个交付文件及准备产物SHA，原 prepared、handoff和证据快照保留于 scratch `before-d75/`；没有覆盖未知文件或修改原六项之外的其他功能。

### 产品决定和实施

`DECISIONS.md` 首张表 D74 上方新增 D75，记录用户原选择及 `r2-mini-prestored/measure/d74-report.md` 末节依据：稳定隐藏600 s主进程约1.7%、子进程约9.18%，合计约10.9%单核；nettop单次约1.37 CPU s，15 s一次约40次／10 min，占约9.1 pp。该报告的before为incomplete、after为unstable，保留这些脚本状态，不能写成complete，也不能把旧测量当成本轮改后收益。

`MenuBarPerformancePolicy` 新增独立 `hiddenNetworkProcessInterval = 60`、`lowPowerHiddenNetworkProcessInterval = 180`；`MenuBarSamplingCadence.networkProcesses` 独立于 `.processes`。Auxiliary owner的 `refreshNetworkProcesses` 改用这一独立门控。180 s沿用已有隐藏helper 60 s→低电量180 s的三倍预算，未将网络频率套用于ps／内存分组。

| 面板／电量状态 | 逐 App 网络（nettop） | ps／内存分组 | helper |
|---|---:|---:|---:|
| 可见，普通 | 10 s | 10 s | 5 s |
| 隐藏，普通 | 60 s | 15 s | 60 s |
| 可见，低电量 | 60 s（保留既有策略） | 60 s | 180 s |
| 隐藏，低电量 | 180 s | 60 s | 180 s |

本批按“仅修改隐藏档位”保留既有低电量可见网络60 s与30 s总时钟，普通可见仍10 s；未把“可见10 s”扩展成改变既有低电量可见策略。已发出该边界的可选澄清；若后续要求低电量可见也严格10 s，须另改独立调度，不能只改常量。本轮没有将过密假时钟作为生产10 s的证据。未改变NativeNetworkProcessService的命令、参数、读取／解析实现或新增常驻时钟，该服务只更新说明注释。普通隐藏列表最多约60 s前、低电量隐藏约180 s前，打开网络三级显示原列表与原源日期；resident owner随后按10 s可见频率刷新，已有快照在刷新在途期间保持available，不改为等待空白。用户手动刷新原即时行为保留。

### 可测工作与测试

已有 `MenuBarPrestoredSamplingTests.testSchedulingMatrixAndStatusVisibilityDoesNotDisablePrestorage` 在隐藏／可见×低电量×暂停／睡眠×1/2/5 s用户档位矩阵中补 `.networkProcesses` 断言；原`.processes == 15`普通隐藏、低电量60与helper等断言全部保留，没有删断言或放宽阈值。

新增 `MenuBarNetworkProcessCadenceTests` 4项，复用未受DEBUG守卫的 `StartupWorkCounter`／`StartupTestWait`，通过实际 `refreshResidentSamples` 入口调用计数型 network provider：

- 假时钟采用生产 `MenuBarRefreshInterval.fiveSeconds.sleepNanoseconds` 的5 s普通／30 s低电量tick，区间 `[0,600)`：普通隐藏物理provider **10次**（原15 s应为40次），低电量隐藏 **4次**（含t=0首样本，之后180/360/540），普通可见 **60次**、低电量可见 **10次**（保留既有60 s网络策略）。十分钟区间不把t=600端点重复算入；长期低电量平均约3.33次／10 min。
- 无样本／读取失败仍以attempt节流：t=0一次，15/30/59 s不追加，60 s第二次；不因unavailable加速重试。
- 隐藏取得非空列表后在59 s打开，先同步断言原列表／“59 秒前”；阻塞可见刷新provider时仍保留available及源日期，完成后再公布新日期；9 s不重读，10 s重读。
- 睡眠／暂停已到期仍零新增provider调用，保留原快照；恢复后按门控取得新样本。

原网络10 s floor、关闭后保留Top-K、已存首样本／原日期等测试继续执行。`ResidentStartupScheduleTests` 的一条说明字符串更新为D75独立网络floor，断言值未改。新测试无真实nettop子进程、App启动、硬件写入或持久数据根。

| D75 本轮检查 | 实际结果／exit code | 本批 scratch 证据 |
|---|---|---|
| 最终 Debug 全部测试目标编译 | **PASS／0** | `logs/d75-debug-build-final.log` |
| 正常 Release，`--build-tests -Xswiftc -enable-testing` | **BLOCKED／1**；同一 `MemoryFixtureApp.dSYM` 的 `Operation not permitted`；最终可见低电量保留策略之前的打包尝试，未冒充最终正常Release通过 | `logs/d75-release-build-tests.log` |
| 最终 Release，同flags加 `-debug-info-format none` | **PASS／0**；Release优化生产代码及全部测试目标编译，包含未受DEBUG守卫的共用helper | `logs/d75-release-build-final-no-dsym.log` |
| 7类相关定向 | **FAIL／1**；120 tests，0 skip，5失败记录／4失败case；新4项均PASS，矩阵／旧网络floor及存储展示相关纯逻辑通过；UI46、plan28、resident4、native6 PASS | `logs/d75-targeted-final.log`、`d75-targeted-results.json` |
| 本轮4个未通过case | **BLOCKED**：两个resident ScanStore夹具写家目录被拒；两个CFPreferences synchronize／plist定位被沙箱拒绝；没有改断言／安全路径／新增skip | `d75-targeted-results.json`逐方法与原始错误 |
| 补丁／源码／private API 静态守卫 | **PASS**；生成交付时记录；nettop代码去除说明注释后与基线逐行相同 | `prepared/static-checks.json` |
| 全量／反证／真实App／CPU与唤醒测量 | **NOT RUN** | `validation-summary.json`；主会话在合并前执行 |

本轮计数结果是调用次数证据，不是CPU／磁盘／唤醒收益实测。原六项的50个待复验case保留，D75本次4个受限case与其中已有项重叠，不能相加成新的54个case。正常Release/dSYM仍须主会话复验。最终Release临时目录已按RULES删除，记录在 `release-cleanup-d75.json`；离线依赖的中立来源未修改，Debug留待主会话合并后清理。

### 反证与 prepared 更新

D75新增5条定义，总 `counterexamples.json` 现为 **60条，全部NOT RUN**：

1. `d75-hidden-network-restored-fifteen`：隐藏网络60→15，十分钟provider计数应10→40。
2. `d75-ps-memory-slowed-with-network`：误把`hiddenProcessInterval`15→60，原ps／内存矩阵应失败；ScanStore两个生产分支仍共用`.processes`，源码未修改。
3. `d75-network-restored-shared-process-gate`：owner错误重新读`.cadence.processes`，生产入口计数应捕获，不能只靠常量断言。
4. `d75-low-power-hidden-restored-sixty`：180→60，十分钟含首样本计数应4→10。
5. `d75-opening-network-clears-stored-state`：有快照仍改为sampling，打开刷新在途的available断言应失败。

这些补丁只静态核对唯一anchor、源SHA和测试方法，未应用或执行；主会话必须验证编译通过且对应断言FAIL，再还原并验证PASS。

追加并入第01组；仍六组，累计48个文件、93个新增测试方法。manifest版本2、revision `D75`，更新全部最终SHA、补丁、分组消息、static-checks及提交脚本；脚本显式核对D75 revision、93个新测试／60条反证及组顺序。`targeted-classes.txt`累计31类，另有 `d75-targeted-classes.txt` 指定本次7类复验范围。Git管理目录仍只读，未暂存或提交。

主会话复跑：使用上文Debug flags，`FILTER=$(paste -sd '|' ~/Developer/.sc-build/r2-perf-startup/d75-targeted-classes.txt)`，`swift test "${F[@]}" --skip-build --filter "$FILTER"`；正常Release/dSYM、全量、严格并发、原六项及D75反证、两种条件下交错CPU／唤醒测量仍分别验收。旧失败记录保留，不能将本次局部测试覆盖写成整组／全量PASS。JEV仍未执行：可用工具要求审批，策略never，未取得判断。


## fix1（2026-10-11 复核回修）

本节对应 `logs/codex-review.log` 末尾全部 P1／P2，以及主会话全量 F1／F2。基线仍为 `7b94e3101ceee7927fbd5267ff433a8cb4be7900`，沿用已有六组 prepared；回修前 prepared／证据快照为 `before-fix1/`。未运行真实App，未读写真实偏好／缓存，未修改ScanStore或路径安全检查。

| 项目 | 生产文件:行 | 处理与可测工作量断言 | 对应测试（方法所在文件:行） |
|---|---|---|---|
| P1-1 | `Sources/StorageCleanerMac/Support/StartupWorkSchedule.swift:51`、`Sources/StorageCleanerMac/Support/StartupWorkSchedule.swift:118`、`Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:299` | 策略资格与执行可用性分离。6/10秒是首轮等待截止，重任务未可用前不执行；截止时仅执行可用性不足则保留意图，由App初始化建立、跨窗口生存的既有重任务activeOwner发布订阅再检查策略、恰好执行一次；新增轮询／定时器数为0；完成订阅跨窗口生存，退出同步取消。单次执行前清空动作，旧代际不能提升新截止任务。 | `Tests/StorageCleanerMacTests/StartupPerformanceTests.swift:139` `testBusyDeadlineRetainsIntentAndExistingOwnerReleaseRunsExactlyOnce`；`Tests/StorageCleanerMacTests/StartupPerformanceTests.swift:176` `testBusyIntentRechecksDisabledPolicyAndManualCompletionBeforeReplay`；`Tests/StorageCleanerMacTests/StartupPerformanceTests.swift:199` `testBusyIntentCannotReplayOrRescheduleAfterTermination`；`Tests/StorageCleanerMacTests/StartupPerformanceTests.swift:220` `testOldGenerationCannotPromoteNewDeadlineOnOwnerRelease` |
| P1-2 | `Sources/StorageCleanerMac/Services/SMCReadSession.swift:53`、`Sources/StorageCleanerMac/Services/SMCReadSession.swift:95`、`Sources/StorageCleanerMac/Services/SMCReadSession.swift:123` | 通知只在独立短锁内更新睡眠／代际并入队清理，不等待硬件。关闭连接／清key-info缓存排在在途读取结束后；睡眠请求物理读取增量0，旧代际结果不可发布，唤醒后下一轮懒重连。受控慢driver期间通知返回必须<50ms，阈值未放宽。 | `Tests/StorageCleanerMacTests/SMCReadSessionTests.swift:291` `testSleepReturnsWithinFiftyMillisecondsDuringBlockedReadAndDefersInvalidation`；`Tests/StorageCleanerMacTests/SMCReadSessionTests.swift:366` `testSleepWakeDuringBlockedPassRejectsOldGenerationAndDefersFurtherReads` |
| P2-1 | `Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:68`、`Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:101`、`Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:123`、`Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift:515` | 退出入口任何await／Task创建／提前terminateNow之前同步取消；即时取消钩子与系统退出路径也覆盖。提取的生产prepareForTermination顺序先清启动任务与繁忙意图，再等待benchmark；退出等待阶段自动scan增量0，并拒绝后续激活重新排期。 | `Tests/StorageCleanerMacTests/StartupPerformanceTests.swift:243` `testProductionTerminationCancelsTimerAndBusyIntentBeforeBenchmarkAwait`；`Tests/StorageCleanerMacTests/StartupPerformanceTests.swift:276` `testTerminationEntryAndImmediateCancellationHookCoverStartupScheduler` |
| P2-3／F1 | `Sources/StorageCleanerMac/Services/EnergyImpactService.swift:203`、`Sources/StorageCleanerMac/Services/EnergyImpactService.swift:388`、`Sources/StorageCleanerMac/Support/ProcessSamplingCache.swift:64`、`Sources/StorageCleanerMac/Support/ProcessSamplingCache.swift:157`、`Sources/StorageCleanerMac/Features/Memory/Infrastructure/SystemMemoryProbe.swift:553` | 独立提取有效PID，RSS／CPU等指标损坏不丢PID；任何PID无法解析则提示不完整。共享提示只消费同轮完整、未过期清单；缺失／过期／不完整走SystemMemoryProbe实际proc_listpids。损坏指标仍共享时原生读取0；需回退时恰好1次；动态usage／BSD每轮读取，不完整提示不能误淘汰仍活跃元数据。 | `Tests/StorageCleanerMacTests/ProcessSamplingCacheTests.swift:151` `testValidPIDWithMalformedMetricsRemainsInSharedMemoryInventory`；`Tests/StorageCleanerMacTests/ProcessSamplingCacheTests.swift:185` `testAllMalformedMetricsStillPublishValidPIDsForMemory`；`Tests/StorageCleanerMacTests/ProcessSamplingCacheTests.swift:201` `testUnparseablePIDMakesEnergyHintIncompleteAndMemoryUsesFullNativeDiscovery`；`Tests/StorageCleanerMacTests/ProcessSamplingCacheTests.swift:225` `testMissingExpiredAndIncompleteHintsEachPerformOneFullNativeDiscovery` |
| P2-4 | `Sources/StorageCleanerMac/Services/SMCReadSession.swift:107` | 原smc-session-serialization ID保留，更新锚点及filter为预热正缓存后两条受控物理读取。去串行只影响执行队列，不移除短状态锁；测试区间没有缓存写入或连接改变，driver用独立短锁记录maximumConcurrentCalls，正确值1。反证预期XCTest断言FAIL；未执行，若主会话实际观察runtime crash必须另列、不得算断言捕获。 | `Tests/StorageCleanerMacTests/SMCReadSessionTests.swift:406` `testPrewarmedMetadataSerializesControlledPhysicalReadsWithoutDictionaryMutation` |
| P2-2 | `Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift:846`、`docs/2.0.0/collab/DECISIONS.md:9` | 保持网络打开行为的生产代码不变。先即显已存列表／采样时间；不无条件强制nettop，按当前可见attempt floor普通10秒、低电量60秒判断。普通隐藏上次尝试30秒前打开立即采一次；普通9秒／低电量30秒不补采，低电量60秒可补采。D75行已明确此行为。 | `Tests/StorageCleanerMacTests/MenuBarNetworkProcessCadenceTests.swift:112` `testOpeningUsesCurrentVisibleAttemptFloorIncludingThirtySecondHiddenSample` |
| F2 | `Sources/StorageCleanerMac/Support/MenuBarAuxiliaryMonitorState.swift:1037` | 恢复原声明形态并直接await CPUPerformanceStateService.currentSnapshot；随后只用一个已等待.value的有限detached worker读取static fallback，不允许detached IOReport等待者。保留测试注入provider，用于物理调用计数；默认生产路径遵循原契约。 | `Tests/StorageCleanerMacTests/CPUPerformanceStateServiceTests.swift:90` `testAdvancedMenuRefreshAwaitsSharedSnapshotWithoutDetachedIOReportWaiter` |

F1 原断言 `Tests/StorageCleanerMacTests/UnifiedMenuBarPanelTests.swift:776` `UnifiedMenuBarPanelTests.testMemoryProcessSnapshotUsesNativeIdentityAndFootprintAPIs` 未改，F2 原 `CPUPerformanceStateServiceTests` 断言也未改：仍要求命名声明、恰好一个共享await、静态fallback体逐字相符且已等待、无其它detached／sleep／Timer循环。因此没有旧／新断言替换或阈值放宽；旧测试只为异步SMC清理增加受控完成等待，原期望值全部保留。

主会话在回修前报告：构建OK、定向767项0失败（8个既有opt-in skip）；全量4926项、两项真实失败F1／F2。这是用户提供的沙箱外结果，未由本会话重跑或读回主会话全量日志，不能当作fix1最终全量已通过。两类及原AppDelegate退出类已加入 `targeted-classes.txt`，最终全量由主会话再执行。

| fix1 检查 | 实际结果／exit code | 本批 scratch 证据 |
|---|---|---|
| Debug 全部测试目标编译 | **PASS／0** | `logs/fix1-debug.log` |
| 标准 Release，`-c release --build-tests -Xswiftc -enable-testing` | **BLOCKED／1**；最终`StorageCleanerMac.dSYM`生成报`Operation not permitted`（首次尝试为MemoryFixtureApp.dSYM） | `logs/fix1-release-standard.log` |
| Release相同参数加`-debug-info-format none` | **PASS／0**；优化生产代码及全部Release测试目标编译，包含未受DEBUG守卫的共用辅助；不能替代正常dSYM门禁 | `logs/fix1-release-no-dsym.log` |
| F1／F2两个完整同名类 | **PASS／0**；Unified28＋CPU17＝45项，0失败；CPU有2个既有本机拓扑不可用skip，未新增skip | `logs/fix1-f1-f2.log` |
| 其它12类相关定向 | **FAIL／1**；394项、2个既有live opt-in skip、38失败事件／37case；其中36case BLOCKED、1个既有ENOENT夹具case待主会话复验 | `logs/fix1-targeted.log`、`fix1-targeted-results.json` |
| fix1新增14项 | **PASS**；启动6、SMC3、进程4、网络打开1；逐方法PASS已从日志核对 | `fix1-targeted-results.json`的`new_tests` |
| 关键完整类 | **PASS**；Startup12、SMC22、Process28、Network5、AppDelegate5、Resident4、MemoryMetadata4、Energy21（1个既有live skip）、UI46 | `fix1-targeted-results.json`的`suites` |
| 36个受限case | **BLOCKED**；34个操作家目录夹具EPERM（Prestored2／SystemUtility32），2个CFPreferences case权限失败产生3条断言；逐名保留，未改测试／安全路径／skip | `fix1-targeted-results.json`的`failures` |
| 1个既有未闭合case | **FAIL**；`SystemUtilitySafetyTests.testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt`记录fixture清理Cocoa4／ENOENT；与原交付同名、同错误，不能仅凭日志宣称已证明是EPERM根因。主会话先前报告其定向767/0，本轮仍需沙箱外复验 | `logs/fix1-targeted.log:810`、原`targeted-failures.json` |
| 反证／交付静态检查 | **PASS**锚点／filter／patch文本；原60条保留，追加17条，累计77；反证执行 **NOT RUN** | `counterexamples.json`、`prepared/static-checks.json` |
| 全量／实机／真实CPU与唤醒测量 | **NOT RUN** | 主会话执行；不将主会话回修前4926项结果视为fix1已通过 |

本轮实际两次定向合计439项，4个既有skip，38失败事件／37失败case；14个新增测试均PASS。SMC原105条XCTest断言行全部保留，F1／F2原源码契约逐字未改。当前六组包含48个最终文件，累计新增107测试与77反证定义。Release临时产物已在最终编译退出后删除，见`release-cleanup-fix1.json`；离线依赖来源未修改，Debug留待合并后清理。

JEV未执行：工具需要审批而当前策略为never；没有获得或声称JEV外部判断。

反证保留原60个ID，更新受影响的SMC／启动锚点，另追加每项fix1定义。`counterexamples.json` 的状态均为NOT RUN；生成仅核对锚点、方法和patch文本，不应用或运行反证。红：主会话报告F1／F2真实FAIL、复核指出其余边界。绿：见本节实际sandbox日志。反证：主会话逐条在隔离副本应用指定patch，Debug编译通过后运行filter，预期XCTest断言FAIL；还原同filter须PASS。编译FAIL不算捕获，运行时崩溃单列并不计入断言失败。

主会话命令：沿用专属scratch的F参数，`swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' targeted-classes.txt)"`；正常Release `swift build -c release "${R[@]}" --build-tests -Xswiftc -enable-testing`。全量、反证、严格并发专门门禁及交错measure-hidden-cost-v2.sh（到期冷启动／未到期暖启动）仍由主会话执行。本节修复不改变D75频率、其它D74源、充电／睡眠边界，也不声称真实CPU收益已确认。

## fix2（2026-10-11 复核回修）

对应 `logs/codex-review-fix1.log` 末尾 1 项 P1、1 项 P2。基线仍为 `7b94e3101ceee7927fbd5267ff433a8cb4be7900`；fix1 prepared／源码／证据已先核对 SHA 后保存到 `before-fix2/`。主会话提供的 fix1 沙箱外定向 **831/0** 是用户报告，本会话没有重跑或读回该完整日志；本节结果仅来自 fix2 的实际命令。未运行 App，未触碰真实偏好／缓存、ScanStore、路径安全边界或 D75/D74 频率。

| 复核项 | 生产文件:行 | 修复、工作量与边界证据 |
|---|---|---|
| P1：真实任务结束不发布，补跑依赖页面 | `Sources/StorageCleanerMac/Services/HeavyWorkCoordinator.swift:71`、`Sources/StorageCleanerMac/Services/HeavyWorkCoordinator.swift:86`、`Sources/StorageCleanerMac/Services/HeavyWorkCoordinator.swift:115`、`Sources/StorageCleanerMac/Services/HeavyWorkCoordinator.swift:136`；`Sources/StorageCleanerMac/Stores/HeavyWorkActivityStore.swift:18`、`Sources/StorageCleanerMac/Stores/HeavyWorkActivityStore.swift:37` | coordinator 在取得／释放租约、进入／解除隔离的真实状态变更中发布带版本的状态；初始快照和注册在同一 actor 内完成。Store 自有生命周期任务持续消费，页面观察取消不影响它；旧页面 refresh 返回不能覆盖较新的版本。晚到 busy 错误另做一次 actor 状态核对，避免结束事件已消费后重新残留 benchmark。新增轮询／定时器 **0**；真实 v11 在途期间自动扫描 **0** 次，runner 清理并返回、真实 release 后 **1** 次，之后再次释放其它任务仍 **1** 次。保留既有策略重查、手动覆盖、退出同步取消、单次执行与代际验证。 |
| P2：第一项旧值随失效聚合返回 | `Sources/StorageCleanerMac/Services/SMCReadSession.swift:107`、`Sources/StorageCleanerMac/Services/SMCReadSession.swift:108` | body 完成后再核对本轮代际，不符返回整轮 supplied fallback。生产功率聚合测试先完成 PSTR=12，再阻塞 PDTR 跨睡眠／唤醒；整轮必须等于生产 fallback，PSTR 也为 invalid。旧轮只物理读取 PSTR/PDTR 各 **1** 次，fallback 增量 **0**，其余旧轮探针发现 **0**；唤醒不立即重连，新轮懒重连后两项物理读取累计各 **2** 次、metadata 各重查 **2** 次，值为 18/20。 |

所有 10 类 owner 的真实释放点已逐个审计，完整位置及调用文本在 `fix2-lease-release-audit.json`：mainScan（ScanStore 2210/3330）、largeFilesScan（LargeFilesStore 322/408/637）、duplicateScan（DuplicateFilesStore 299）、cleanup（ScanStore/LargeFilesStore 的 withLease；SafeCleanupExecutor 544/780）、restore（ScanStore 2941/3008/3189/6866/7352）、emptyTrash（3807）、memoryOptimization（4312）、appUpdates（ScanStore 5554、ProviderBackedExecutor 198/273、AppUpdater 41/68/77/93）、networkTest（NetworkSpeedTestStore 121，隔离清除 271/284）、benchmark（BenchmarkV7Coordinator 802/832/835/863/900、v10 1473/1477/1487、v11 1519/1530；超时实际结束后 894 清隔离，以及 legacy/accelerator/sustained 路径）。withLease 的成功／错误／取消均由既有 defer 进入统一 release。Homebrew 清理在 ScanHeavyWorkService 382 验证进程结束后清隔离。RecordedCleanupRecovery/UninstallExecution 对尚未验证的真实隔离继续保持 busy；没有伪造 idle 或提前解除真实重任务。

新增 8 项测试全部通过；没有调用页面 .task，真实 v11 新测试取消模拟页面订阅，测试内不显式 refresh()：

| 测试文件:行 | 新增测试方法 | 沙箱结果 |
|---|---|---|
| `Tests/StorageCleanerMacTests/SMCReadSessionTests.swift:406` | `testPowerTelemetryDiscardsEntirePassWhenSecondReadSpansSleepWakeAndRereadsAfterWake` | **PASS** |
| `Tests/StorageCleanerMacTests/MSeriesV11RunnerTests.swift:324` | `testRealV11CompletionAfterPageObservationCancellationReplaysDueScanExactlyOnce` | **PASS** |
| `Tests/StorageCleanerMacTests/HeavyWorkActivityStoreTests.swift:73` | `testCancelledAndThrowingOperationsPublishIdleThroughLeaseDefer` | **PASS** |
| `Tests/StorageCleanerMacTests/HeavyWorkActivityStoreTests.swift:41` | `testCleanupQuarantineRemainsBusyUntilRealClearThenPublishesIdle` | **PASS** |
| `Tests/StorageCleanerMacTests/HeavyWorkActivityStoreTests.swift:17` | `testEveryOwnerPublishesCompletionWithoutPageRefresh` | **PASS** |
| `Tests/StorageCleanerMacTests/HeavyWorkActivityStoreTests.swift:114` | `testLateConflictAfterRealReleaseCannotLeaveStaleOwner` | **PASS** |
| `Tests/StorageCleanerMacTests/HeavyWorkActivityStoreTests.swift:100` | `testObservationDoesNotRetainReleasedStore` | **PASS** |
| `Tests/StorageCleanerMacTests/HeavyWorkActivityStoreTests.swift:60` | `testStoreCreatedDuringExistingLeaseObservesSnapshotAndLaterRelease` | **PASS** |

本节以前的行号对应各轮历史快照；当前睡眠标记位置为 `Sources/StorageCleanerMac/Services/SMCReadSession.swift:127`，物理读取串行位置为 `Sources/StorageCleanerMac/Services/SMCReadSession.swift:111`，预热串行化测试为 `Tests/StorageCleanerMacTests/SMCReadSessionTests.swift:463`。反证源 SHA 与 patch hunk 使用当前文件重新生成。

原断言逐字保留，见 `fix2-test-preservation.json`：旧 SMC 22 项方法／166 行 XCTest 断言全部保留，MSeriesV11RunnerTests 原方法和断言也保留。SMC 两个旧 fix1 测试只把 supplied fallback 的空数组改为两项 unreadable，使整轮 fallback 与原本保留的结果断言一致；没有修改期望值或原 50 ms 阈值。共用测试辅助未放入 DEBUG 条件，Debug 与 Release --build-tests 都实际编译。F1/F2 原测试文件仍逐字等于基线。

| fix2 检查 | 结果 | scratch 证据 |
|---|---|---|
| Debug 全部测试目标编译 | **PASS／0** | `logs/fix2-debug.log` |
| 标准 Release --build-tests -Xswiftc -enable-testing | **BLOCKED／1**：MemoryFixtureApp.dSYM 的 dsymutil 报 Operation not permitted | `logs/fix2-release-standard.log` |
| 同一 Release 命令加 -debug-info-format none | **PASS／0**；生产优化代码及全部 Release 测试目标编译；普通 dSYM 仍需主会话 | `logs/fix2-release-no-dsym.log` |
| F1/F2 两个完整类 | **PASS／0**：45 项、0 失败、2 个既有拓扑可用性 skip | `logs/fix2-f1-f2.log` |
| 核心九类完整定向 | **FAIL／1**：156 项、14 失败事件／13 个 BLOCKED case、无 skip；其中 Store6、Coordinator13、v11 Runner13、SMC23、Startup12、AppDelegate5、UI46 全部 PASS | `logs/fix2-core.log`、`fix2-targeted-results.json` |
| 初次扩展定向（含 BenchmarkV7CoordinatorWorkloadIntegrationTests） | **BLOCKED／130**：19 个已完成 case 的部分日志保留；隔离 CFPreferences 被拒，既有持久化 case 记录 persistenceFailed 后停滞，主动中断本次测试进程；该完整类未验证通过 | `logs/fix2-targeted.log`、`fix2-run-results.json` 的 targeted-interrupted |
| 8 项新测试 | **PASS**，逐方法日志已核对 | `fix2-targeted-results.json` 的 new_tests |
| 84 条反证定义／源码与补丁静态检查 | 锚点、filter、patch 文本 **PASS**；执行 **NOT RUN** | `counterexamples.json`、`prepared/static-checks.json` |
| 全量、反证、实际 App、CPU／唤醒交错测量 | **NOT RUN**，由主会话执行 | 不将局部编译或定向视为最终门禁 |

两次已完整结束的定向合计 **201 项、2 个既有 skip、14 失败事件／13 个 BLOCKED case**。另有中断的部分扩展定向，不能计为完整通过或混进 201 的总数。13 个受限 case 中，HeavyWorkIntegrationTests 的 11 项均有操作家目录夹具 EPERM；TestPreferenceHygieneTests 两项共 3 条断言有隔离 CFPreferences 权限拒绝。逐名交主会话沙箱外复跑：

- `HeavyWorkIntegrationTests.testApplicationInventoryRefreshCannotOverlapOtherHeavyWork`
- `HeavyWorkIntegrationTests.testBulkCleanupUsesCleanupOwnerAndPublishesAfterGenerationMatch`
- `HeavyWorkIntegrationTests.testBusyBenchmarkBlocksMemoryOptimizationWithoutInvokingService`
- `HeavyWorkIntegrationTests.testCancellationPersistenceFailureIsShownInsteadOfCancellationSuccess`
- `HeavyWorkIntegrationTests.testCancellationRequestedBeforeDrainedDoesNotFinishNotifyOrRefresh`
- `HeavyWorkIntegrationTests.testCancellationWhileInitialSnapshotSaveIsBlockedNeverStartsExecutorOrRescans`
- `HeavyWorkIntegrationTests.testConfirmationPreviewHoldsNoLeaseAndCleanupReacquiresNewLease`
- `HeavyWorkIntegrationTests.testDuplicateEmptyTrashRestoreAndAppUpdatesUseIndependentOwners`
- `HeavyWorkIntegrationTests.testExecutionTimeQuitResumesExactBatchItemAndScansInventoryOnceAfterCompletion`
- `HeavyWorkIntegrationTests.testMainScanOwnsLeaseOnlyDuringPhysicalScanAndReleasesBeforeBrowsing`
- `HeavyWorkIntegrationTests.testPartialUpdateFailureWaitsForEveryTaskThenRunsOneFullInventoryRefresh`
- `TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`
- `TestPreferenceHygieneTests.testTemporarySuiteCanBeReopenedOnAWorkerThread`

初次扩展定向中还需完整复跑 BenchmarkV7CoordinatorWorkloadIntegrationTests；以下两个既有 case 有持久化断言失败／停滞记录，附近日志明确拒绝对应 TestPreferenceDomain 的 defaults.plist，生产 revoke/acknowledge 以 synchronize() 失败转 persistenceFailed：

- `BenchmarkV7CoordinatorWorkloadIntegrationTests.testHistoryReloadTimeoutPublishesPersistenceFailureAndLateReloadIsDiscarded`
- `BenchmarkV7CoordinatorWorkloadIntegrationTests.testPersistencePhaseLatchesResultAndIgnoresLateCancellation`

本轮实际命令（完整 flags、exit code 与日志亦在 fix2-run-results.json）：

- `swift build --disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-perf-startup/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4 --build-tests`；exit 0；`logs/fix2-debug.log`
- `swift build -c release --disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-perf-startup/release --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4 --build-tests -Xswiftc -enable-testing`；exit 1；`logs/fix2-release-standard.log`
- `swift build -c release --disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-perf-startup/release --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4 --build-tests -Xswiftc -enable-testing -debug-info-format none`；exit 0；`logs/fix2-release-no-dsym.log`
- `swift test --disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-perf-startup/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4 --skip-build --filter 'UnifiedMenuBarPanelTests|CPUPerformanceStateServiceTests'`；exit 0；`logs/fix2-f1-f2.log`
- `swift test --disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-perf-startup/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4 --skip-build --filter 'HeavyWorkActivityStoreTests|HeavyWorkCoordinatorTests|HeavyWorkIntegrationTests|MSeriesV11RunnerTests|StartupApplicationUpdateSchedulerTests|SMCReadSessionTests|AppDelegateBenchmarkTerminationTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests'`；exit 1；`logs/fix2-core.log`

新增 7 条反证：真实 lease release 发布、隔离清除发布、10 类 acquire 发布、已有租约初始快照、Store 生命周期消费、晚到 busy 错误一次状态核对，以及 SMC 聚合后代际 guard。保留全部原 **77** 个 ID，累计 **84**。原 smc-connection-reuse 更新到 let result = body(...) 锚点，其余受影响 source SHA／patch／行号已重算。预期均为 **XCTest 断言失败**；事件测试的有界等待返回 Boolean，随后检查 owner/nil/扫描计数，不把测试进程超时当捕获；SMC 第二项 gate 在断言前与 defer 均释放并等待 worker。定义没有执行，不声称实际反证红绿已获证；主会话须编译通过、对应断言 FAIL、还原同 filter PASS，编译失败／运行时崩溃另列且不得计入断言捕获。

交付仍为六组，fix2 并入 01-startup-resident、04-sensors、06-handoff：累计 **52** 个最终文件、**115** 个新增测试方法、**84** 条反证，本轮相对 fix1 改动 **7** 个工作树文件（3 生产、3 测试、1 交接；其中 HeavyWorkActivityStoreTests.swift 新增）。manifest revision fix2，提交脚本核对 115/84、完整 HEAD、分支、空 index、组顺序及全部文件/制品/证据 SHA。Git 管理目录只读，未提交，未执行提交脚本。临时 Release 在最终编译进程退出后按 RULES 2.3 删除，记录 `release-cleanup-fix2.json`；Debug 留待合并后清理。

主会话沿用 F/R 专属 scratch flags，运行 `swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' ~/Developer/.sc-build/r2-perf-startup/targeted-classes.txt)"`（累计 39 类；本轮完整 12 类另见 fix2-targeted-classes.txt），重跑受限及中断类、普通 Release/dSYM、全量、严格并发专门门禁、84 条反证，以及原定到期冷启动／未到期暖启动交错测量。JEV 调用被工具审批要求和 never 策略阻止，未获得判断。

## 主会话验收（2026-10-11）

- 沙箱外 `main-verify-generic.sh`（日志 `~/Developer/.sc-build/r2-perf-startup/logs/main-final-1107`）：Debug 构建 0；定向 39 类 909 项 0 失败（8 个既有 opt-in skip；沙箱受限的跑分 2 项与卸载夹具 1 项通过）；全量 4948 项 0 失败（25 skip）；重建 0；Release `--build-tests -Xswiftc -enable-testing`（正常 dSYM）0。
- 反证 84/84：83 条按交付定义断言失败；`fix1-memory-native-pid-discovery-path` 原定义使闭包不再引用 `$0` 导致编译失败（不算捕获），主会话以 `Int32(0 * $0.count)` 更正后断言失败（`counterexamples-main-corrections.json`；原 `counterexamples.json` 因 SHA 固定未改）。
- 只读复核：首轮 2 P1 + 4 P2 → fix1；二轮 1 P1 + 1 P2 → fix2；三轮 0/0/0，结论可合并（`logs/codex-review*.log`）。
- CPU／唤醒收益尚未实测；40→10 次 nettop 只是调用计数证据。
