# r2-mini-sampling 交接

本轮最新状态见文末“独立复核修复轮”；上方为既有批次与主会话的历史记录，旧性能数字不能代表本轮修复后的实测。

2026-10-09；分支 `task/r2-mini-sampling`；基线 `0bd131b2f6e4debb24e1ffeed9bb9aaba71dd6fc`。决定 D71④、D5、D27、D38、D39、D48、D59⑤。已读 RULES／DECISIONS／BOARD；此基线 BOARD 没有以 `r2-mini-sampling` 命名的单独条目，本批由用户本次任务界定。没有修改 ScanStore.swift。

## 状态与边界

- PASS：源码审计先完成，随后修改；分组补丁、基线计时补丁、SHA-256 manifest、提交脚本、定向类清单及反证计划已准备。静态检查命令、exit code 与哈希见 scratch `prepared/static-checks.json`。
- NOT RUN：构建、严格并发、XCTest（执行数 0）、真实性能、反证执行、安装、提交、合并。common.md 明确禁止本 Codex 沙箱执行这些工作；由主会话补齐，不能据此称性能通过。
- BLOCKED：JEV 的 `jev_decide` 调用被工具层拒绝：`MCP tool call requires approval, but approval policy is never`。可调用适配器没有模型／推理参数，未得到 provider 返回的模型标识或判断。代码图 `list_projects` 同样被阻断，使用本 worktree 的定向检索。未尝试绕过或降级。
- 本会话工具未提供可核对的运行模型标识，提交 trailer 标为 `Codex (current-session-model-unverified)`；不把项目派工约定当作实际运行身份。

准备包在 scratch `prepared/`，19 个最终文件按 `01-audit`、`02-sources`、`03-presentation`、`04-tests-handoff` 四组整理；`all.patch` 含新文件。静态记录含 53 条读取／检查命令，正向基线检查、当前树反向检查、范围／哈希／不可改文件及预算核对通过。定向清单为 22 类，反证计划为 16 项，执行数均按本轮证据保持 0。`commit-prepared.py --check-only` 供主会话复核身份、范围与哈希；实际提交仅在主会话完成验证和复核后执行。

## 改动及理由

1. `mini-sampling-audit.md`：逐源列明修前频率、系统 API／SMC／IOKit／子进程／框架 IPC、用途与修后集合；没有编造单次成本或实测改善比例。
2. `MenuBarSamplingPlan`／context：菜单栏、可见卡片和当前页面合并需求；控制器同步实际可见性、status item 显示、自定义风扇与暂停；status item KVO／active space／低电量通知立即重排，切换状态模式先更新集合再读。`SystemMonitorService` 最终过滤实际采样源，而非仅把整批计时器拉长。独立显式 probe／测试未装 controller 时仍用原参数。
3. 主源：廉价可见读数沿用用户 1/2/5 秒档位；隐藏最低 5 秒、低电量或无状态项 30 秒。GPU／SMC 的可见下限 5 秒，温度图标隐藏 15 秒；自定义风扇仍 1/2 秒反馈。新 `sensorSampledAt`／`gpuSampledAt` 保留真实源时间，避免重复发布缓存被当作新传感器读数。
4. 辅助：容量和电池新增明确需求；电气／磁盘 I/O／簇频率／功率下限 5 秒。隐藏状态只读 IOPowerSources，停止 SMC 电气回调与无用途磁盘历史；在可见面板不显示电源卡时仍保持设备状态图标的必要电池读取。电池短缓存合并同 tick SMC 查询。
5. 缓存与取消：回放最近可见主快照只用于展示、保留原时间；恢复 CPU／网络先建基线。辅助缓存不清空；取消前已开始的同步读取保持 single-flight；关闭发生在 task 真正开始之前时，不启动新昂贵 provider。功率旧任务结束后只按当前需求补一遍。
6. 进程：二级保留 Top-K 显示，当前相应三级才声明进程需求；context 通知还覆盖面板不在 active space。常规 ps／内存进程／nettop 10 秒，ps 首次基线／0.5 秒首 delta 和原 5 秒占位期限不变。保留 ps 和 nettop 的原口径；ps 增加 stdout/stderr 2 MiB 合计上限。没有引入新 Shell／新私有 API。
7. 计时：复用 opt-in MenuBarPresentationTrace，新增 `kind=sample` 与 `trace.phase`；记录源、开始／结束 uptime 和时长，不写原始数据。连接／电源模式只读 XPC 按可见性与 5 秒下限合并快速重开请求，用户主动操作仍走原入口。后台 worker 计时与 UI draw ack 区分；未开启参数时不新建计时任务。

## 改写的旧断言

依据均为 D71④；保留原测试方法与其余断言，没有删除／跳过测试，也没有改性能预算。

- `SystemMonitorServiceTests.testMenuBarSamplingKeepsSelectedCadenceAcrossVisibilityAndStatusIcons`：仅隐藏且非低电量的断言从用户档位变为 5 秒下限；可见 1/2/5 秒、低电量隐藏 30 秒、自定义风扇 1/2 秒及原内存档位断言仍在。
- `SystemMonitorServiceTests.testSystemMonitorServiceUsesHIDSMCAndGPUDriverSensors`：GPU throttle 的源码字段由固定 `Self.gpuSamplingInterval` 改为传入 `samplingInterval`，加断言证明默认独立 probe 仍取原值。
- `UnifiedMenuBarPanelTests.testBackgroundDiskHistoryKeepsRealSamplesWhenThePanelIsClosed`：可见 I/O interval 的常量从 2 秒更新为 5 秒；其原独立状态背景历史真实性测试保留。生产 controller 已装 context 时停止这项背景需求，新测试另外验证零调用。
- `UnifiedMenuBarPanelTests.testComplexDemandTracksCurrentModuleAndGeekKeepsAttachedOverviewAlive`：完整网络二级 `needsNetworkProcesses` 改为 false，同时增加相应三级 true 断言；其余一级附着需求仍在。
- `visibleProcessInterval` 2→10 秒是子进程节流要求，不是延迟预算放宽。`warmPresentationBudget=100ms`、`coldPresentationBudget=250ms`、`publicationBudget=100ms`、`mainThreadBlockBudget=50ms`、32 MiB/4 页派生缓存和 `MenuBarPerformanceRegressionTests` 原文件保持不变。

## 主会话构建与测试

scratch：`/Users/developer/Developer/.sc-build/r2-mini-sampling`。先核对 manifest，再在本 worktree 执行；不安装。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-mini-sampling
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
MINI_SCRATCH=/Users/developer/Developer/.sc-build/r2-mini-sampling
MINI_FILTER=$(paste -sd '|' "$MINI_SCRATCH/targeted-classes.txt")
swift build --scratch-path "$MINI_SCRATCH/debug" --jobs 4
swift test --scratch-path "$MINI_SCRATCH/debug" --jobs 4 --filter "$MINI_FILTER"
swift build --scratch-path "$MINI_SCRATCH/strict" --jobs 4 -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
swift test -c release --scratch-path "$MINI_SCRATCH/release" --jobs 4 -Xswiftc -enable-testing --filter MenuBarPerformanceRegressionTests
STORAGE_CLEANER_VERIFY_ROOT="$MINI_SCRATCH/verify" STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 script/verify.sh
```

保存每条命令 exit code、日志、测试总数／跳过／失败。主会话空闲时跑性能；失败先核实同机负载，不能放宽预算。Swift 编译／隔离报错请回本会话修复，未编译情况下不能称一次编译已通过。

## 修前／修后实测方法

先运行 **修前**，再运行 **修后**；不要并行运行两个包。二者使用相同机型、电源、基础档位、一级模块、历史输入和 `activity`。每轮冷／热／二／三级／切档至少 20 次，稳态各 120 秒，至少 3 轮；保留 load1、App Nap 模式、签名／构建身份和主会话的 CPU／RSS／唤醒采样。硬件控制保持系统自动，仅测量只读源。

修前诊断 worktree 从基线 detached 创建，先 `git apply --check` 再应用 scratch `prepared/baseline-audit.patch`。这份补丁只加计时，无采样分层、缓存、频率或上限变化，**不提交／不合并**。修后使用本 worktree 的完整代码。离线依赖沿用 RULES 的唯一保留来源；两个 scratch 独立。

```bash
MINI_SCRATCH=/Users/developer/Developer/.sc-build/r2-mini-sampling
MINI_BEFORE=/Users/developer/Developer/sc-worktrees/r2-mini-sampling-before
git worktree add --detach "$MINI_BEFORE" 0bd131b2f6e4debb24e1ffeed9bb9aaba71dd6fc
git -C "$MINI_BEFORE" apply --check "$MINI_SCRATCH/prepared/baseline-audit.patch"
git -C "$MINI_BEFORE" apply "$MINI_SCRATCH/prepared/baseline-audit.patch"
cd "$MINI_BEFORE"
SWIFT_BUILD_DIR="$MINI_SCRATCH/before-release" DIST_DIR="$MINI_SCRATCH/before-package" BETA_DIST_DIR="$MINI_SCRATCH/before-artifact" ./script/build_and_run.sh --beta
cd /Users/developer/Developer/sc-worktrees/r2-mini-sampling
SWIFT_BUILD_DIR="$MINI_SCRATCH/after-release" DIST_DIR="$MINI_SCRATCH/after-package" BETA_DIST_DIR="$MINI_SCRATCH/after-artifact" ./script/build_and_run.sh --beta
```

上述 `--beta` 不含安装选项，只组包。主会话按现有隔离 QA 方法把临时测量包身份改为 `com.local.StorageCleanerMac.integration` 并重新签名；用 `AppDataDirectories` 已有 `STORAGE_CLEANER_INTEGRATION_ROOT`（仅此身份接受、`~/Library/Caches/StorageCleanerIntegration-<唯一后缀>`）隔离数据。准备相同历史输入的前后两份目录，偏好只属于 QA 身份，关闭恢复面板和非小窗的后台工作。临时包只留 scratch，测完按 RULES 回收，不替换已安装 Beta 或正式版。

下面的 binary 用组包中已有的 `Contents/MacOS/StorageCleanerMacBeta`，QA 身份只改 Info.plist／签名而不改可执行名。先运行 before，再把变量切到 after 并重复三轮；在启动参数末尾分别加原 1／2／5 秒偏好参数 `-menuBar.refreshInterval oneSecond|twoSeconds|fiveSeconds`（UserDefaults 参数域，不写真实偏好）。

```bash
MINI_LABEL=before
MINI_AUDIT="$MINI_SCRATCH/logs/$MINI_LABEL-1.jsonl"
MINI_BINARY="$MINI_SCRATCH/$MINI_LABEL-artifact/测试版.app/Contents/MacOS/StorageCleanerMacBeta"
MINI_QA_ROOT="$HOME/Library/Caches/StorageCleanerIntegration-r2-mini-sampling-$MINI_LABEL-<唯一后缀>"
STORAGE_CLEANER_INTEGRATION_ROOT="$MINI_QA_ROOT" "$MINI_BINARY" \
  -ApplePersistenceIgnoreState YES \
  -menuBar.refreshInterval oneSecond \
  --menu-bar-performance-audit="$MINI_AUDIT" \
  '--menu-bar-latency-script=phases=first,openclose,modules,tertiary,ranges,steady;iterations=20;rangeIterations=20;rangeSections=processor,memory,disk,network,sensors,power;settle=20;maxLoad=4;steady=120;activity=0'
python3 "$MINI_SCRATCH/prepared/summarize-sampling.py" "$MINI_AUDIT"
```

`openclose` 自带回收后冷开与复用热开；`modules` 是二级；`tertiary` 是三级；`ranges` 是时间档；`steady` 含一级、二级 CPU、隐藏缓存、隐藏回收。另跑 `phases=hold;holdSection=power;hold=120;holdHide=60;maxLoad=4;settle=20;activity=0`，以及 memory/network/sensors 的 hold；三级结束后确认进程源停止。再重复 `activity=1` 校准。手动改变状态模式／关闭 status item／系统低电量设置的读回只由主会话做，采样无需解除充电暂停或切换风扇模式。

输出统计按 `trace.phase` 的**开始 uptime**归组，报告源次数、间隔 p50/p95、单次耗时、总 worker wall time；同时报告 AppKit draw ack 和 main_busy/main_stall。源耗时不是 CPU 时间；draw ack 不是物理上屏；不同成本的 source 不能简单相加声称整机省电。修前源频率与修后预计集合见审计，不填入未跑的实际数字。

## 红／绿／反证

`$MINI_SCRATCH/counterexamples.json` 给出每个最小反向改动、定向 test、预期红灯和恢复／绿灯步骤；全部状态 NOT RUN。由主会话在独立可写副本逐项施加，一次只改一项；得到失败日志后恢复到 manifest 的最终哈希并重跑相同 test。

新测试 `MenuBarSamplingPlanTests` 18 项：需求集合、可见／隐藏／自定义风扇、三级进程、context 消费者合并、缓存原时间与失效、内存读缓存、同 tick 电气合并、D5 隐藏零电气／上限／积分调用、假时钟 5／10 秒新鲜度、GPU／传感器调用集、原子 single-flight、任务启动前关闭和 ps 输出限额、XPC 连接／模式同源合并及 5 秒下限。实际执行数仍 0。既有 `MenuBarPerformanceRegressionTests`、`UIConsistencyRegressionTests`、`TestPreferenceHygieneTests` 和充电 D5／缓存测试必须一起跑。

## 未解决与合并注意

- Swift 6 的 actor／Sendable、可选 tuple 推断、UI 接线和新鲜度已静态核对，但编译与运行证明待补。
- 不支持传感器、挂住的 IOKit、权限不足的进程计数和已有占位语义仍显示未知；不伪造 0。同步驱动／ps 的物理退出无法由 UI watchdog 硬取消，保留单任务等待。
- 二级从冷启动到第一次相应三级前没有新的 Top-K；按用户任务保留旧列表／未知展示，主会话要实机核对文字和可操作项不会把旧数据当最新。
- 本批涉及 EnergyImpactService 的 ps 输出保护与只读源时间元数据；与 r2-energy-powermetrics 合并时须保留双方最终入口。能耗业务、powermetrics 助手、充电写操作和 ScanStore 均不在本批改动中。
- 从本轮静态源码不能证明功耗下降，也不能确认现有预算在真实机器上通过。实测达不到目标则返回本会话继续修改，不能把文档与补丁准备当成验收。

## 主会话验证轮（2026-10-09，Claude 子代理，沙箱外）

工具链 `Xcode-27.0.0-Beta`，机器 18 核 / 48 GB，macOS 27.2。期间其他会话在编译和跑测试，1 分钟负载 6–63，始终没有降到 4 以下。日志都在 scratch `~/Developer/.sc-build/r2-mini-sampling/logs/`。未安装，未碰 `/Applications`，未启动已安装的测试版或正式版，未提交、未 push，未写风扇、充电、电源设置，也未读取钥匙串（Beta 包用临时签名，见下文“Release／Beta”）。

### 本轮改动

Codex 的 19 个文件第一次编译即通过，没有 Swift 报错或警告。验证中发现 4 处问题，均已修复：

1. `SystemMonitorServiceTests.testGeekOnlyPanelKeepsRealDataAndSharesOneWindowSession`（源码守卫）：电池 SMC 读取已移到 `MenuBarBatteryElectricalCache`，所以把断言改为：辅助状态里有 `MenuBarBatteryElectricalCache.shared.snapshot()`，缓存文件里有 `NativeBatteryElectricalService.snapshot()`。依据 D71④，仍然核对真实 SMC 来源。
2. `UnifiedMenuBarPanelTests.testGeekOverviewDefersProcessReadsUntilVisiblePageDeclaresDemand`：进程需求改由 `processSection` 声明（只在对应三级可见时有效）。断言改为 `section: processSection`，并新增一条，核对 `MenuBarProcessSamplingDemand.section(selectedSection, tertiaryVisible: tertiaryVisible)`。依据 D71④。
3. `GeekHoverDetailTargetTests.testOnDemandSnapshotFreshnessHasExplicitCurrentAndStaleStates`：按需快照的刷新间隔随 `visibleProcessInterval` 从 2 秒改为 10 秒。断言改为 10 秒，并与 policy 常量相等；边界检查从 1.8／2 秒相应改为 9.8／10 秒。依据 D71④，子进程类采样降频。
4. **源码修复** `MenuBarProcessSampler.swift`：间隔改为 10 秒后，`MiniWindowLiveReadingRetentionTests.testAReaderThatGivesNothingEndsInNotMeasuredWithAReason` 在全量中失败。原因是读者先给空、恢复后要再等一个完整的 10 秒周期，才能从基线算出第一个差值。修复方法：记录 `missedRead`。读者恢复后如果没有基线，先按 N16-2 的 `firstProcessSampleInterval`（0.5 秒）补读一次，直接给出第一个差值。正常首次读取仍只建基线，不会多调用一次 ps。新增确定性测试 `MenuBarSamplingPlanTests.testRecoveredProcessReaderTakesFirstDeltaWithoutAnotherFullCadence`。原测试的 10 秒期限**没有改**。
5. 修正 `MenuBarSamplingPlanTests.testHiddenPrimaryGateDoesNotInvokeGPUOrSensorsAndVisibleRefreshesWithinFloor` 的等待方式。原来的“200 次 × 2 ms”轮询在负载约 25 时偶发失败，改为 5 秒期限的功能等待。这是等待假 provider 完成，不是延迟预算。
6. `targeted-classes.txt` 增加 `GeekHoverDetailTargetTests` 和 `MiniWindowLiveReadingRetentionTests`，共 24 类。`counterexamples.json` 新增一项 `recovered-reader`，共 17 项。`prepared/generate-prepared.py` 已同步：组 04 加入 GeekHover 测试，测试方法数改为 19，定向类 24，反证 17，状态如实记录；原版保存在 `logs/generate-prepared.codex-orig.py`。

`MenuBarPerformanceRegressionTests.swift`、`ScanStore.swift` 和所有延迟预算都没有改动；generate 脚本的不可变哈希检查覆盖这些文件。

### 构建与测试（证据）

| 项目 | 结果 | 证据 |
|---|---|---|
| Debug 构建（含测试） | PASS，exit 0，无 warning | `logs/main-r3/build2.log` |
| 定向 24 类（含 TestPreferenceHygiene、UIConsistency） | PASS：699 项，跳过 4，失败 0（负载约 60） | `logs/main-r3/targeted.log` |
| Debug 全量（修复前） | FAIL：4328 项，6 条失败断言／4 个测试，负载 16→27 | `logs/main-r2/full.log` |
| **Debug 全量（修复后）** | **PASS：4329 项，跳过 25，失败 0**，用时 776 s，负载 44→7 | `logs/main-r3/full.log` |
| 反证 17 项 | **17/17 变红**；恢复时每个文件都核对了 SHA-256，之后重建 exit 0 | `logs/main-r3/mutations/*.log`、`summary.json`；`counterexamples.json` |
| 严格并发 `-strict-concurrency=complete -warnings-as-errors` | PASS，exit 0 | `logs/strict-build.log` |
| `script/check_private_api.py`、`git diff --check` | PASS（7 处在许可清单内） | 本轮命令输出 |
| Release `swift build -c release` | PASS，exit 0 | `logs/release-build.log` |
| Beta（Release，`-D STORAGE_CLEANER_BETA -g`，组包） | PASS，exit 0，包结构、Info.plist、Sparkle、BuildInfo 校验通过 | `logs/after-beta-build.log` |
| Release `MenuBarPerformanceRegressionTests`（`-enable-testing`） | **FAIL 1/16，环境原因**：`testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 的 preparation p95 为 101.7–129 ms，预算 100 ms（未放宽）。修前基线在同机同负载下交替跑 3 次，结果 117–119 ms，同样失败。本批没有改这条路径（`MenuBarPreparedChart.swift`）。需要在负载 <4 时复跑 | `logs/release-perf*.log`、`logs/release-perf-ab.log` |

Beta 构建用的是 scratch 中的 `tools/build_beta_adhoc.sh`。它与 `script/build_and_run.sh` 只有三处不同：ROOT 固定为 worktree；不查询钥匙串签名身份，统一用临时签名；去掉要求 Developer 身份、团队 ID 和 runtime 标志的 6 行断言。其余组包和校验步骤原样执行。运行时设了 `STORAGE_CLEANER_SKIP_TESTS=1`，跳过脚本内置测试（测试已单独跑过），不带 `--install`，不安装。

### 修前／修后实测

**方法**

- 修前：用 `git worktree add --detach` 在 scratch 临时检出 `0bd131b2`，只加 `prepared/baseline-audit.patch` 的计时探针。
- 修后：本 worktree。
- 两边都用同一个 Beta 构建脚本组包，复制后改为隔离身份 `com.local.StorageCleanerMac.integration`，设 `SUEnableAutomaticChecks=false`，临时签名。数据隔离在 `STORAGE_CLEANER_INTEGRATION_ROOT=~/Library/Caches/StorageCleanerIntegration-r2-mini-sampling-<轮>`，每轮结束删除。
- 参数：`-menuBar.refreshInterval oneSecond -menuBar.statusDisplay.v1 deviceStatus`，计划为 `phases=first,openclose,modules,tertiary,ranges,steady;iterations=10;rangeIterations=3;rangeSections=processor,memory;settle=10;maxLoad=1000;steady=60;activity=1`。
- 按修前→修后→修后→修前交替各跑 2 轮，每轮约 11 分钟。负载一直没有低于 4，所以关掉了等待（maxLoad=1000），只记录负载：各轮运行中 load1 中位 8.7–9.5，四轮接近。
- 面板为极客模式，历史为空（新隔离目录）。
- 驱动脚本：`tools/measure.sh`、`tools/measure-ab.sh`；统计脚本：`tools/compare.py`；原始数据：`logs/measure/*.jsonl|.ps|.meta`；完整表：`logs/compare-ab.md`。

**交互延迟**（AppKit 绘制回执，单位 ms，最近秩 n / p50 / p95；两轮合计）

| 项目 | 修前 | 修后 |
|---|---|---|
| 暖打开·首帧 | 22 / 15.7 / 20.2 | 22 / 19.8 / 30.5 |
| 冷打开·首帧 | 20 / 34.9 / 46.3 | 20 / 43.7 / 54.6 |
| 启动后首次打开 | 2 / 86.0 / 87.5 | 2 / 70.3 / 74.5 |
| 暖打开后 CPU 新数据画出 | 22 / 142.6 / 157.2 | 22 / 54.6 / 91.7 |
| 冷打开后 CPU 新数据画出 | 20 / 167.6 / 201.6 | 20 / 82.0 / 116.5 |
| 冷打开后内存新数据画出 | 20 / 172.6 / 1048.2 | 20 / 81.1 / 132.9 |
| 二级（自一级） | 266 / 55.9 / 76.9 | 266 / 51.4 / 77.3 |
| 二级（模块间切换） | 120 / 39.8 / 52.1 | 120 / 39.1 / 56.2 |
| 回一级 | 266 / 37.6 / 47.4 | 266 / 35.2 / 48.6 |
| 三级页面 | 124 / 27.9 / 45.2 | 124 / 26.2 / 37.3 |
| 三级图表 | 104 / 39.9 / 51.4 | 104 / 39.2 / 52.5 |
| 切档·新图表 | 74 / 29.5 / 43.0 | 74 / 26.5 / 38.4 |
| 切档·旧图变暗 | 52 / 12.3 / 14.2 | 48 / 11.5 / 15.4 |
| 同步段 open.sync 暖／冷 p50 | 6.6 / 27.4 | 8.7 / 35.2 |
| main_stall（>50 ms）每轮 | 203、214 | 153、207 |

切档时“旧图变暗”的超时次数两边都有（修前 22，修后 26），是既有现象。

**面板隐藏和稳态的采样调用**（两轮各 60 s 合计；括号内为每 60 s）

| 阶段 | 修前 调用次数 / 工作线程累计 ms | 修后 |
|---|---|---|
| 隐藏（暖，面板保留） | 515（257.5）/ 992 | **46（23.0）/ 144** |
| 隐藏（已回收） | 530（265.0）/ 1123 | **52（26.0）/ 172** |
| 一级可见 | 852（426.0）/ 7188 | 544（272.0）/ 2813 |
| 二级 CPU 可见 | 910（455.0）/ 10574 | 545（272.5）/ 2940 |

隐藏 60 s 内按源计（每 60 s）：

| 源 | 修前 | 修后 |
|---|---|---|
| CPU | 59 | 0 |
| GPU 注册表 | 59 | 0 |
| 网络计数 | 59 | 0 |
| 内存状态 | 59 | 11 |
| Wi-Fi | 11.5 | 11 |
| 电池 SMC | 4.5 | 0 |
| 传感器 SMC/HID | 3.5 | 0 |
| 电池电气回调 | 1 | 0 |
| 磁盘 IOKit | 1 | 0 |
| 电池状态（IOPowerSources） | 0 | 1 |

二级 CPU 页稳态：`ps` 由 62 次降到 0。脚本各阶段每轮的子进程类调用：

- 二级阶段：`ps` 140→0、`nettop` 20→0、内存进程枚举 20→0。
- 三级阶段：不变（60／10／10）。每次停留约 1.3 s，主要是首个基线加 0.5 s 后的第一个差值。
- 切档阶段：`ps` 12→3.5。

可见时 GPU、传感器、电池 SMC、簇频率等昂贵源降到每 5 s 一次（例如一级可见时 GPU 每 60 s 由 59.5 次降到 12 次）。廉价源仍按 1 s 档位（CPU、网络各约 60 次/60 s）。

进程 CPU% 中位按每 5 s 一次的 `ps` 统计，噪声大：修前隐藏阶段 0.5–0.6% 对修后 0.0–0.2%。不能据此推算整机功耗。

### 未解决

1. **打开首帧略变慢**：暖开 p50 +4 ms、p95 +10 ms；冷开 p50 +9 ms。同步段 `open.sync` 暖开 p50 +2.1 ms，`show.total` p50 +3.8 ms。仍在预算内（暖 100 ms、冷 250 ms），但各轮结论一致。推测原因：打开路径里同步执行了 `updateSamplingContext(panelVisible: true)`，其中 `setPresentationVisible(true)` 会让辅助状态重新协调、启动任务，并发布 `plan`；`startRefreshLoop` 也先对隐藏状态做了一次配置。建议下一轮在 `updateSamplingContext` 和 `setPresentationVisible` 外加 span 确认，再考虑把辅助协调推迟到首帧之后（缓存先显所需的 `plan.panelVisible` 仍保持同步）。
2. Release 计时测试 `testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 在本机负载 ≥7 时修前、修后都超预算，需要在负载 <4 时复跑，再判定 PASS 或 FAIL。
3. 启动后首次打开时，内存新数据画出 p95 约 1.09 s，两边相同，未改。
4. `MiniWindowLiveReadingRetentionTests` 原 10 秒期限仍然通过（修后约 1 s），但现在依赖测试在约 0.5 s 那次读取前放开读者。极端负载下，如果放开晚于这次读取，要等到下一个 10 s 周期，可能接近期限。
5. 实测只覆盖“设备状态”菜单栏模式、1 s 档位、空历史和极客面板；其他菜单栏模式、低电量模式、状态项隐藏、自定义风扇未实测（有单元测试覆盖）。iterations 为 10，不是交接原建议的 20。负载未达 <4。
6. 与 **r2-energy-powermetrics** 的冲突面：两批改动的文件**没有重叠**（对方改 ScanStore、GeekPowerView、GeekSensorsView、HelperPowerMetricsMonitor、SoCPowerTelemetry 等；本批改 SystemMonitorService、MenuBarAuxiliaryMonitorState、EnergyImpactService 等）。但有语义交叉：
   - 对方新增的功率或传感器读取，如果在小窗面板或二三级显示，需要接入 `MenuBarAuxiliaryMonitorDemand`（`needsPowerTelemetry`／`needsBattery`／`primaryKinds`）和 `MenuBarSamplingPlan`，否则隐藏时不会停，或者可见时被本批的门控挡住。
   - `ScanStore.performMenuBarRefresh` 归对方，本批的过滤在 `SystemMonitorService` 内按 `samplingPlan` 执行，合并后要核对两者衔接。
   - 两批都会用到 `GeekPowerView`／`GeekSensorsView` 的显示数据。合并后要重跑 `MenuBarSamplingPlanTests`、`MenuBarPerformanceRegressionTests`，以及 powermetrics 相关测试类。
7. 已删除：`/tmp/storage-cleaner-r2-mini-sampling-{before,after}-beta`、临时修前 worktree（`git worktree remove --force`）、release／before-release／strict scratch，以及测量用 `.app` 副本和隔离数据目录。`debug/` scratch 保留，供主会话提交和复核。隔离 QA 偏好域 `com.local.StorageCleanerMac.integration` 在本轮之前就存在，本轮只用参数域覆盖设置，没有删除它。


## 独立复核修复轮（2026-10-09，Codex，r2-mini-sampling）

### 基线、保存与范围

本轮基线 `6ba97b278e30e6ef411d5a61a15cc29fa7a7fce5`，分支 `task/r2-mini-sampling`。先读 common.md、codex-build-common.md、RULES、D5／D39／D48／D55／D60／D71④、BOARD、本交接和完整 diff。接手的 10 个未完成修改没有丢弃，原始文件、diff 和 SHA-256 存于 scratch `review-entry/`；网络重连后再次核对，diff 与保存副本完全一致。没有修改 ScanStore、硬件设置或安装包；没有启动应用、安装、提交、合并或发布。

common.md 末尾的 2026-10-09 更新允许沙箱内编译与定向测试，本轮按更新执行。`.git` 实际只读，交付分组 prepared 补丁，供主会话验证后提交。旧 prepared 包基于 `0bd131b2`，另存为 scratch `prepared-original-0bd131b2-20261009/`；当前 `prepared/` 以本轮 HEAD 为基线，包含接手修改和本轮补充。

### 修复内容

- **P1-1，缓存、历史与显示**：GPU／SMC 离开计划时清空缓存；已开始的同步读取继续保持物理 single-flight，但退出前的结果完成后丢弃。仍有需求时，服务层以原采样开始时间判断新鲜度，超过 `max(10 秒, 2 × 该源采样周期)` 或时间在未来则不返回硬件值；慢读期间过期缓存同样变成未知。GPU 和 SMC 都使用启动读取时的 `now`，不会用便宜发布 tick 重标时间。
- `MenuBarTelemetryPoint` 增加可选 `sensorSampledAt`／`gpuSampledAt`，在 `replacingMemory`／`replacingFanRPM`、JSON 编解码中保留；CPU／网络仍用原 `date`。硬件图表在后台准备时投影到源时间并合并同一观测的重复发布，晚到的观测先排序再分桶。原始混合历史仍存发布时刻，但每个硬件值有自己的原采样时刻，不能把混合点的 `date` 当成硬件新观测。旧历史没有新字段时沿用原日期；早期版本读取新文件会忽略新增可选字段。
- 环境光、详细温度的全部入口改用 `sensorReadingDate`；GPU 三级详情显示 `gpuReadingDate`，GPU 日期进入 `.sensors` 卡片指纹，CPU 页 GPU 频率读数也接入已有频率源日期。
- **P1-2，隐藏电池积分**：任意菜单栏模式、状态项不可见时，仍由已有 resident 时钟约每 30 秒调用只读电池电气 provider 和 `onBatterySample`。不增加独立能耗时钟。隐藏路径根本不调用充电上限缓存刷新；可见且明确 `needsChargeLimit` 时才读。暂停时不启动新读取，取消后等待同步读结束再释放句柄。生产 `SystemEnergyAccumulator.start(passive: true)` 继续通过既有 callback 积分，不改 SystemEnergyAccumulator。
- **P1-3，重开新鲜度**：保留快照和传入 live 快照都检查年龄，不能因 live 参数来自缓存就绕过判断；当前 1／2／5 秒档位对应至少 10 秒年龄上限。最近一次 cheap 发布也不能让老 GPU／SMC 数据变新，分别清掉过期硬件值。超龄显示占位，新数据到达后替换；D39 已准备历史窗口仍按原淡化／“更新中…”路径显示。
- **P2，截止时间与首帧**：运行中的 resident 循环不因状态变化取消或重建；只更新采样计划，保留已经等待的绝对截止时间，下一周期读取新档位。打开时仍主动请求一次刷新，并且 `beginPanelPresentation` 只调用一次 `updateSamplingContext(panelVisible: true)`。CPU 差分保留 0.2 秒最短间隔，间隔内不挪动计数基线。CPU counter provider 可注入，测试无需读取真实 CPU 或固定 sleep。
- context 的 `paused` 仅由控制器 `configure` 写入，辅助消费者不覆盖共享暂停状态。同步 samplers 读 `plan`；观察者读本主线程 turn 合并后的 `planChanges`，接收端再 `removeDuplicates`。
- 进程需求等待 AppKit display／Core Animation commit 的 run-loop 机会后声明，而不是仅启动一个可能抢在首帧前运行的 MainActor Task。隐藏、销毁时取消门控；缓存面板每次重开也重置门控；task 只打开状态门，随后从最新视图路由声明 ps／nettop 需求，避免使用打开时捕获的旧路由。实际物理首帧改善仍须主会话实测。

### 改写旧断言的依据（没有删除、跳过或放宽预算）

1. `testHiddenStatusBatteryNeverReadsElectricalChargeLimitOrDisk` 改为 `testHiddenBatteryKeepsReadOnlyEnergyIntegrationWithoutChargeLimitOrDisk`：依据本轮明确要求、N16-5 和 D5；原“电气和 callback 为 0”是错误禁读，D5 禁止自动改变充电暂停，不禁止只读电气。改成隐藏 fake clock 35 秒产生两次电气／callback，并把真实 `SystemEnergyAccumulator` 推进到 `20 W × 35 s / 3600`；10 秒时零额外读取、充电上限 reader 与磁盘 provider 始终为 0、暂停后不读。源码守卫覆盖后台入口、recordBatterySample 和 NativeBatteryElectricalService 的写入禁用；既有 D5 充电服务测试保留且通过。
2. 原重开快照测试的 100 秒间隔改成 8 秒，保留“建基线前显示旧值、真实 delta 后替换”的所有断言；另加一小时旧缓存、旧 live、有数值的过期 live、未来日期和最近发布中含旧硬件的反例。10 秒边界仍显示，超过则占位。依据本轮 P1-3、D39。
3. `testBackgroundDiskHistoryKeepsRealSamplesWhenThePanelIsClosed` 改名为 `testStandaloneBackgroundDiskHistoryKeepsRealSamplesWithoutSamplingContext`，准确说明它不经过生产 context 分支；另测正式 context 下 provider 调用为 0、无 counters／history。依据 D71④，保留独立 probe 分支的原真实性测试。
4. 网络 provider 计数、任务启动前关闭测试、便宜／昂贵源测试均等待实际任务句柄退出后再断言，不以 `isRefreshing` 被取消时变为 false 当成完成，也不依赖固定 yield 次数。CPU 最短间隔测试用注入 counters 精确锁定调用数。
5. `MiniSensorsDecodingTests.testSavedHistoryRoundTripsEveryField` 的字段数由 21→23，fixture 填满两项新增且不同的原采样日期，逐字段和完整键集合检查保留。旧版本兼容测试仍逐字段验证原 21 项，只将两项新字段明确列为旧版本不认识的可选键，并断言旧版本重写后它们为 nil。依据 P1-1、D71④ 的原采样时间要求，不是删掉兼容性验证。

### 编译、定向测试与剩余失败

scratch：`/Users/developer/Developer/.sc-build/r2-mini-sampling`；日志：`logs/review-fixes/`。

| 检查 | 状态与证据 |
|---|---|
| 最终 Debug + build-tests | **PASS**，exit 0，`build-final.log` |
| 36 类定向测试 | **FAIL / 环境待复跑**，exit 1，838 项、11 项原有 skip、101 个失败断言（100 个失败用例），`targeted-final.log`；没有将整体记为 PASS |
| 最终代码的 28 类可运行核心复验 | **PASS**，exit 0，404 项、4 项原有 skip、0 失败，`local-core-final.log`；跳过原因见原测试日志，没有改测试的 skip 条件 |
| 采样计划测试 | **PASS**，26 项；包括过期 single-flight、原日期 JSON、硬件准备图表合并、隐藏实际能耗积分、0.2 秒 CPU 和源码接线 |
| UIConsistencyRegressionTests | **PASS**，46 项；两个定向运行均通过 |
| TestPreferenceHygieneTests | **BLOCKED**，21 项中两个用例产生 3 个断言失败；日志有 `sandbox_extension_issue_file ... Operation not permitted`，临时偏好 plist 无法落盘／重新打开。源码卫生守卫未报新增问题；不得称整类通过 |
| 私有 API 守卫、diff 检查、ScanStore 原文比较 | **PASS**，exit 0，7 个原 allowlisted 使用；ScanStore 与 HEAD 逐字节一致 |
| Release／独立 strict／全量 verify／反证／首帧实测／安装／提交 | **NOT RUN**；主会话补齐。Debug 编译沿用 Swift 6，不能据此称独立 strict 或 Release 门禁通过 |
| JEV | **BLOCKED**，`jev_decide` 返回 `MCP tool call requires approval, but approval policy is never`。工具 schema 不提供模型或推理参数，未取得 provider 模型标识或判断；未降级、未绕过 |

已修正前两次编译报错（默认参数里 covariant Self、测试换行）和首轮测试暴露的原兼容 fixture／异步读等待问题。完整首轮记录保留 `build.log`、`build-2.log`、`targeted.log`；修正后编译和测试以表内最终日志为准。

8 类需要在主会话复跑：`EnergyProcessNamingTests`、`MemoryHeadroomSysctlTests`、`MenuBarPanelSessionTests`、`MiniWindowLiveReadingRetentionTests`、`ScanStorePerformanceTests`、`SystemMonitorServiceTests`、`SystemUtilitySafetyTests`、`TestPreferenceHygieneTests`。列表也在 scratch `main-session-rerun-classes.txt`。

失败逐用例证据见 `logs/review-fixes/environment-failures.json`：47 个用例不能取得 NSScreen，47 个用例涉及家目录夹具／受限进程读取，3 个 sysctl 相关用例（额外执行 `/usr/sbin/sysctl kern.memorystatus_level` 确认 `Operation not permitted`），2 个偏好 plist 用例。另有 1 个 `SystemUtilitySafetyTests.testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt` 报隔离夹具清理 `ENOENT`，现有日志不足以单独确定其根因，主会话须确认，不能直接当作权限问题消掉。没有改这些安全检查、卫生工具或环境测试。

主会话在当前 worktree 执行，保存 exit code；先复跑 8 类，再跑完整 36 类，及项目全量门禁：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-mini-sampling
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
MINI_SCRATCH=/Users/developer/Developer/.sc-build/r2-mini-sampling
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$MINI_SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$MINI_SCRATCH/main-session-rerun-classes.txt")"
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$MINI_SCRATCH/targeted-classes.txt")"
STORAGE_CLEANER_VERIFY_ROOT="$MINI_SCRATCH/verify-review" STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 script/verify.sh
python3 "$MINI_SCRATCH/prepared/commit-prepared.py" --check-only
# 主会话完成测试、反证与实机复核后：
python3 "$MINI_SCRATCH/prepared/commit-prepared.py" --validated
```

### 供 r2-energy-powermetrics 接线的采样需求 API

- resident 控制器安装时调用 `auxiliaryState.attachSamplingContext(.shared)`，只有控制器通过 `MenuBarSamplingContext.configure(...)` 写菜单栏模式、状态项可见性、小窗可见性、自定义风扇和 `paused`。辅助消费者只用 `registerConsumer(id, demand: ..., paused: store.isMenuBarRefreshPaused)`／`updateConsumer`／`unregisterConsumer`；不要另写 context 的暂停、可见性或 plan。
- 卡片／页面由 `PanelDensity.auxiliaryDemand(for:geekConfiguration:tertiaryVisible:)` 声明：GPU 注册表用 `primaryKinds: [.gpuUsage]`；SMC/HID 温度／风扇用 `.chipTemperature`／`.fanSpeed`；簇频率用 `needsProcessorTelemetry`；功率二／三级用 `needsPowerTelemetry`；可见电池用 `needsBattery`。真正需要充电上限的可见控制界面才声明 `needsChargeLimit`，它不是电气读数的依赖。
- `primaryKinds` 经 auxiliary 合并进 context，`SystemMonitorService.snapshot(..., samplingPlan: ...)` 最终执行交集过滤。生产入口省略 plan 时取 resident context；独立测试／probe 可显式传 plan 或直接用 sampler，不应借用真实 controller 状态。
- **读取需求不等于显示刷新周期**：可见廉价源保持用户 1／2／5 秒；GPU、SMC、簇频率和功率默认至少 5 秒；三级进程 ps／nettop／内存枚举至少 10 秒，第一基线后的 0.5 秒 delta 不变。新的 helper powermetrics provider 应接进已有需求门、single-flight、超时和读取完成回填，不另启一个随页面隐藏仍运行的 Task。源返回实际采样日期，不能拿计划合并／UI publish 的日期代替。
- 进程只在对应三级声明 `MenuBarProcessSamplingDemand.section(selectedSection, tertiaryVisible: true)`；网络进程由 demand 的 `needsNetworkProcesses` 管。页面打开／每次缓存面板重开先显示已有 Top-K，commit 机会后再允许进程需求。消费者消失、隐藏或暂停后仍需等物理任务返回，旧 generation 不得发布。
- 能耗总积分是 **N16-5 的独立后台只读需求**：隐藏仍约 30 秒读电池电气并回调 `SystemEnergyAccumulator.recordBattery`，不依赖状态栏选择 `.deviceStatus`，不依赖 power/sensors 页可见，不读充电上限、不改变充电暂停。powermetrics 的可见 SoC 功率与这个整机积分需求不要混淆。
- 同步采样读取 `context.plan`；SwiftUI 观察 `context.planChanges.removeDuplicates()`，不再用 `$plan`。原 `$plan` 发布是多次中间状态，现在同一主线程 turn 合并一次。
- 新硬件源历史必须传原 `sampledAt`；已有 GPU／SMC 混合历史用新增可选日期，图表使用 `MenuBarTelemetryPoint.historyPoints(_:channels:)`。读取端丢弃 `max(10, 2×周期)` 以外的缓存。不得为接线修改 ScanStore 所属权；与对方合并后重跑两批定向类、菜单栏性能和真实 UI。

### 红／绿／反证及首帧测量

`prepared/counterexamples-review.json` 列出本轮具体最小反向改动与红灯方法；**反证全部 NOT RUN**，主会话在独立副本执行，每次恢复到 manifest 哈希后跑相同测试，不修改真实硬件设置。

首帧测量需要运行原生应用；本沙箱 UI 测试已显示无法取得 NSScreen；本轮 **未运行修前／修后应用，不报改善比例**。测量基线是本轮 `6ba97b27`，不是旧表中的 `0bd131b2`；使用 `prepared/measure-first-frame.sh`（供主会话执行）按顺序构建 before／after 临时 QA 包、隔离数据并运行同一 trace 脚本。默认 3 轮、每轮 20 次 first／热开／冷开／二三级／时间档，load <4；原 100ms／250ms／100ms／50ms 预算不变。

```bash
# 主会话，在沙箱外；脚本不安装、不替换 /Applications 的应用：
bash /Users/developer/Developer/.sc-build/r2-mini-sampling/prepared/measure-first-frame.sh
```

脚本保存构建日志和 opt-in trace JSONL，以 AppKit draw ack、commit ack、open.sync、main_busy／main_stall、process.demand、每源读取次数／间隔复核；AppKit/commit ack 仍不等于物理屏幕刷新。先核对运行二进制与 manifest 的源码身份，完成后主会话按 RULES 回收本轮新建的临时 worktree、构建／QA 数据与 app，仅保留日志证据。未实测的首帧收益、Release 性能、8 类环境失败和卸载夹具 ENOENT 是剩余验收事项。


## 反证补齐轮（2026-10-10，Codex，r2-mini-sampling）

### 保留范围与改动

基线仍为 `6ba97b278e30e6ef411d5a61a15cc29fa7a7fce5`，分支 `task/r2-mini-sampling`。接手的 18 个未提交文件、原 diff、源码 SHA-256 和 prepared 完整保存在 scratch `mutation-followup-entry-20261010/`。本轮只增加／补强 `MenuBarSamplingPlanTests.swift` 并追加本节；生产源码与另两份测试保持接手版本。工作区仍为原 18 个未提交文件，未暂存、未提交，未安装或启动应用。

五条失效反证锚点按最终源码改写，并同步到 scratch `counterexamples.json`、`ce-main.json`（25 条）和仅供本轮的 `ce-six.json`（6 条）。全部 25 条 `find` 均恰好命中一次；转换保持 `path=file`、`before=mutation.find`、`after=mutation.replacement`、`expected_occurrences=replace_count`、原测试 filter（在途项更新为新测试）。

- GPU／SMC：锚点改为多行退出分支，只关闭退出时的清缓存分支，保留独立的过期清理。原测试新增隐藏 1 秒、2 秒内重开的断言，证明新鲜缓存也必须清掉；一小时重开和原在途断言均保留。
- `inflight-discard`：新增 `testGPUReadInFlightWhenSourceLeavesIsDiscardedBeforeQuickReopen`。fake GPU 被 gate 挡住，1 秒退出需求、2 秒重开仍保持单次物理读取；放行旧读数后，3 秒再次读取必须仍无缓存并启动一份替代读取；放行替代读取后，4 秒的快照必须是第二次读数及其 3 秒源日期。全程处于原新鲜度窗口内，过期过滤不能掩盖未丢弃结果。gate 超时另有 0 次断言。
- 隐藏充电上限：变异同时绕过 `recordBatterySample` 的可见／需求守卫及缓存可见参数；测试只使用注入的充电上限 reader，不执行真实充电接口或设置写入。
- `kept-age`：变异删除 `presentationSnapshot.fresh` 的原日期检查，保留硬件源日期过滤，锁定旧 live／kept 快照年龄。
- `loop-deadline`：变异把“已有刷新任务立即返回”改为 cancel/restart，锁定状态变化不得丢失待执行截止时间。此条红灯来自原源码接线守卫，不代表本轮做了原生运行时截止时间实测。

没有删除、改弱或跳过旧断言，也没有放宽任何时限。首次编译报 MainActor 测试向异步实例辅助方法发送 `self`；将不依赖实例的 `waitForHardware` 改成静态方法、调用使用 `Self.waitForHardware` 后通过，原等待 2 秒上限保持不变。

### 实际验证

本轮日志：`~/Developer/.sc-build/r2-mini-sampling/logs/mutation-followup-20261010/`。

| 检查 | 状态、exit code 与证据 |
|---|---|
| 最终 Debug + build-tests | **PASS**，exit 0，`build-final.log`；最初隔离错误与修复见 `build.log` |
| 36 类定向 | **FAIL / 环境待主会话复跑**，exit 1，839 项、11 项既有 skip、101 个失败断言／100 个失败用例，`targeted.log`；失败用例集合与前轮沙箱 `review-fixes/targeted-final.log` 完全一致，没有新增失败，见 `targeted-summary.json` |
| 采样计划与 UI 守卫 | **PASS**，27/0 和 46/0，包含新增在途测试；原 36 类运行和恢复后复验均通过 |
| 指定六条反证 | **PASS / RED 6/6**，runner exit 0，各条执行 1 项，均为 XCTest 断言红灯、无编译失败；见下表和 `mutations/summary.json` |
| 原文件恢复 | **PASS**，runner 每条 finally 恢复并核对 SHA-256；追加交接前的 17 个未改文件均与接手 hash 相同，生产源码全部保持；`restore-checks.json` |
| 恢复后重建与绿灯 | **PASS**，build exit 0，`rebuild-after-mutations.log`；73 项、0 skip、0 失败，test exit 0，`green-after-mutations.log` |
| 静态／封装 | diff、私有 API 守卫、ScanStore 与 HEAD 原文比较均 **PASS**；prepared 封装与 hash／补丁验证结果见 `prepared/static-checks.json` |
| JEV | **BLOCKED**，`jev_review` 返回 `MCP tool call requires approval, but approval policy is never`；schema 不暴露模型标识／推理参数，未取得模型判断；`jev.json` |
| 本轮全量／Release／独立 strict／首帧实测／安装／提交／合并 | **NOT RUN** |

| 反证 | 执行项数 | 失败断言 | 证据（均在本轮 `mutations/`） |
|---|---:|---:|---|
| `gpu-cache-exit` | 1 | 3 | `gpu-cache-exit.log` |
| `thermal-cache-exit` | 1 | 3 | `thermal-cache-exit.log` |
| `inflight-discard` | 1 | 8 | `inflight-discard.log` |
| `hidden-charge-limit` | 1 | 1 | `hidden-charge-limit.log` |
| `kept-age` | 1 | 3 | `kept-age.log` |
| `loop-deadline` | 1 | 2 | `loop-deadline.log` |

36 类的沙箱失败仍在这 8 类：`EnergyProcessNamingTests`、`MemoryHeadroomSysctlTests`、`MenuBarPanelSessionTests`、`MiniWindowLiveReadingRetentionTests`、`ScanStorePerformanceTests`、`SystemMonitorServiceTests`、`SystemUtilitySafetyTests`、`TestPreferenceHygieneTests`。日志记录家目录夹具 `Operation not permitted`、不可取得 NSScreen、sysctl／进程读取限制及临时偏好无法落盘；没有修改测试或产品安全规则。`TestPreferenceHygieneTests` 21 项中 2 项有 3 个失败断言，整类仍不能报 PASS。

主会话本轮之前在 `logs/main-final-0015/` 的定向 **838/0（4 skip）**、全量 **4337/0（25 skip）**和反证 **19/25**已核对日志；是新增测试之前的证据。本轮只跑上述六条，另外 19 条红灯引用原主会话日志，不声明本轮执行了 25/25 或全量通过。

### 复跑与 prepared

提供的原 `run-mutations.py` 固定未带编译沙箱标志。本轮在 scratch 保存只向 `F` 加 `--disable-sandbox -Xswiftc -disable-sandbox` 的副本 `run-mutations-sandbox.py`，原文件未改；来源及两份 hash 见 `runner-provenance.json`。使用同一批 debug scratch，无另建反证构建目录。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-mini-sampling
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
MINI_SCRATCH=/Users/developer/Developer/.sc-build/r2-mini-sampling
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$MINI_SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
# 主会话沙箱外复跑完整 36 类（本轮多 1 项，预期执行 839 项）：
MINI_FILTER=$(paste -sd '|' "$MINI_SCRATCH/targeted-classes.txt")
swift test "${F[@]}" --skip-build --filter "$MINI_FILTER"
# 只跑这六条；logdir 使用新的独立目录，完成后恢复并重建绿色二进制：
python3 "$MINI_SCRATCH/run-mutations-sandbox.py" "$MINI_SCRATCH/ce-six.json" "$PWD" "$MINI_SCRATCH/debug" "$MINI_SCRATCH/logs/main-followup-six"
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter 'MenuBarSamplingPlanTests|UIConsistencyRegressionTests'
python3 "$MINI_SCRATCH/prepared/commit-prepared.py" --check-only
# 主会话完成必要复跑及验收后，才在沙箱外使用 --validated 提交。
```

prepared 仍以 `6ba97b27` 为基线，保持四组：`01-source-times`、`02-demand-lifecycle`、`03-hardware-presentation`、`04-tests-handoff`。本轮源文件增量归组 04，其余组保留已有修复；`counterexamples.json`、`ce-main.json`、`ce-six.json` 与 runner 副本同步进 prepared，manifest 记录所有 18 个最终源码 hash 和产物 hash。维护源 `prepare-review-fixes.py` 已改为读本轮 `static-input.json`，前轮状态保留在 history，不会再把旧 NOT RUN／旧定向失败数字当作本轮执行。提交脚本只做 `--check-only`，没有写 `.git`。

剩余：主会话复跑这 8 类沙箱失败及新增后的全量门禁；原生首帧／截止时间实测仍沿用此前交接要求。本轮六条反证没有未解决项。
