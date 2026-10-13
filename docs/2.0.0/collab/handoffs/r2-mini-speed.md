# r2-mini-speed 交接：小窗反应速度

本文件两节：**第二阶段**（2026-10-05，D38、D39、BOARD N11-1～4、复核 P2-1～4、T5、未归因卡顿）在前；**第一阶段**（测量与定位、三处修复）在后，原文保留，只按复核意见把 `49b81bc` 的空闲 CPU 降幅改写为“趋势”（`256fe00`）。

## 第二阶段

- 实现：Claude 子代理（Opus 5.5）。复核：尚未安排。
- 范围：主会话第二阶段清单全部条目。按清单**未做**：T1、T3、T4；T6（三级卡片指纹按页收窄）仍只是方案（数据见下）。BOARD N11 中另两项（压缩边界极少见的峰值丢失、不可达的简单面板代码清理）不在本阶段清单内，未做。
- 分支：`task/r2-mini-speed`。开始时 `git merge integration/2.0.0-beta` 快进到 `724b06c`（含第一阶段合并 `8458275` 与 r2-privacy）；最终测量前按主会话通知再并入 `f5a8d45`（r2-junk-actionable，合并提交 `5a66619`）和 `5e6333e`（只有文档，合并提交 `6408da7`），都无冲突：r2-junk 改的是 `ScanStore.swift` 清理段与清理视图／服务，没有改任何小窗文件；`SystemUtilitySafetyTests.swift` 两边改动不重叠，自动合并。没有 rebase／reset；未 push、未打 tag、未安装、未碰 `/Applications`、未启动或退出已安装的测试版／正式版、未写风扇／充电／电源；没有改 `DECISIONS.md`、`BOARD.md`。
- `ScanStore.swift`：只改了 `MenuBarMonitorState` 段（D39、P2-1、计时段、审计记录），另有一处例外：N11-3 只能改内存退出段（`requestQuitMemoryApps`、`cancelQuitSelectedMemoryProcesses`、`clearPendingMemoryQuitConfirmation`，并入后在第 4285–4310、7152 行），不在 r2-junk 改动的清理段内，合并无冲突。
- 提交（按顺序；末尾均为 `Co-Authored-By: Claude Opus 5.5`）：
  - `724b06c` 并入集成分支（快进）
  - `6a00e28` 插桩：>150 ms 循环抓主线程栈、命名计时段、`hold`／悬停指定页与档的计划、脚本模式 `beginActivity`
  - `1583217` D38：内存空闲百分比读 `kern.memorystatus_level`
  - `ffb3f27` D39：隐藏时保留已准备的历史窗口，即时读数在历史未就绪时读实时快照
  - `dc98691` N11-1：只有时间窗不同才标“更新中”
  - `8a2b101` N11-2：重放触顶时保留最后一次切页及其后的调用
  - `0b79621` N11-3：简单面板退出请求取消时恢复原选择
  - `38c6a4d` N11-4：换入／换出说明恢复“也包含交换文件维护产生的读写”
  - `fefa77e` P2-1：传感器、电源三级页长档的统计随窗口在后台准备
  - `8e624d7` P2-2：修复 2 的偏移缓存按仪表盘配置清空、沿用时重新夹取
  - `b3bfda5` P2-3：修复 1 的行为测试改为真实检查
  - `da492a3` T5：处理器二级页高度不再随进程数跳动
  - `06877f1` 未归因卡顿：内存进程列表刷新时，运行中应用的固定属性按实例只读一次
  - `c5e1325` 插桩：`history.kept` 按窗口记字节；`holdHide` 计划键
  - `256fe00` 交接措辞：`49b81bc` 的降幅改写为趋势
  - `5a66619` 并入集成分支 `f5a8d45`（r2-junk-actionable）
  - `6408da7` 并入集成分支 `5e6333e`（只有文档：主会话按 N11-2 改写 D33 措辞、补充 D39“回收时不释放”、BOARD 记录 `f5a8d45` 安装）
  - `eb5bb55`、`0c48cd9`、`4cd6a5d` 交接：第二阶段一节、门禁结果、清理记录
  - 复核后：
    - `fbc4162` P1：内存应用属性缓存按 pid＋启动时间命中
    - `366aea4` 并入集成分支 `93e124a`（r2-hotfix-defaults-crash，无冲突）
    - `afe75a3` 该缓存的测试只在 Debug 编译
    - `035487a` P2-1 页面行为测试与摘要范围、D39 两条路径补测、一级 CPU／网络卡淡化
    - `183a351` 文档与注释
    - 本小节所在的交接提交（仅文档）
- **修前／修后对应的提交**（两边插桩相同。但 `cpu.placeholder` 的含义变了：修前是“历史窗口为空”，修后是“一级 CPU 总占用显示 —”。D39 之后历史未就绪时读实时快照，修后它必然为 0。判断 D39 的“打开即显示”要看 `chart.placeholder.overview` 与 `history.kept`）：
  - 修前（第二阶段基线）：`6a00e28`（集成分支 `724b06c`＋第二阶段插桩），build `20261005001116`，干净工作区，包 `~/Developer/.sc-build/r2-mini-speed/p2-base.app`。
  - 修后：`5a66619`（本节全部改动＋并入 `f5a8d45`），build `20261005013634`，干净工作区，包 `p2-post.app`。`6408da7` 只多了文档，`Sources/`、`Tests/` 与 `5a66619` 相同，所以修后包代表本分支最终代码。两者除本节改动外只差 r2-junk 的清理代码；本节的测量计划不触发扫描与清理。
  - `c5e1325` 只加审计字段与计划键，修前包没有 `history.kept`／`holdHide`（只在修后单独测）。
  - 复核后（`fbc4162`、`035487a`）代码又变了，同负载对比用的修后包已从 `b0d1cad` 重新打包（build 20261006115815，`dirty=false`，源码与集成分支 `6edfba3` 相同）。

### 复核后修改（2026-10-06）

第二阶段独立复核结论“需修改后合并”，无 P0。D38、D39、N11-1～4、P2-2、P2-3、T5、插桩核对成立。按复核意见改了下面几项。（本小节写成时同负载对比尚未进行；之后已完成，各项效果见“同负载对比结果”。）

| 复核项 | 改了什么 | 测试与反证（日志在 `~/Developer/.sc-build/r2-mini-speed/logs/`） | 提交 |
|---|---|---|---|
| P1：`06877f1` 的缓存实际不命中 | `RunningApplicationIdentityCache` 改按 pid＋进程启动时间（`proc_pidinfo` `PROC_PIDTBSDINFO`，探针逐进程本来就读）判定同一进程，不再比较对象身份；读不到启动时间时每次重读、不存缓存。应用来源抽成协议 `RunningApplicationIdentitySource`（`NSRunningApplication` 直接符合），测试可以注入每次新建的对象。只在 DEBUG 下有 `reusedCount`／`readCount`。离线实测 165 个应用，每种读法各在自己的运行循环、每次新对象，中位数：原读法 24.9 ms；只读名称／策略／活动 9.1 ms；再加启动时间 10.2 ms | 红：新测试跨运行循环复用 0 个，应为 164 个（`p2r-cache-red.log`）。绿：6 项（`p2r-cache-green.log`）。新增测试：同一进程换新对象不重读、pid 被复用时重读、读不到启动时间时每次重读。反证：“从不复用”5 处失败，“只看 pid”4 处失败（`p2r-cache-mutation.log`）。内存相关 50 项 0 失败（`p2r-cache-related.log`）。该测试文件用到仅 DEBUG 的计数，已加 `#if DEBUG`（`fbc4162` 漏了，Release 测试构建会因此失败，本轮补上） | `fbc4162`、`afe75a3` |
| P2-1：测试只查源码字符串 | ① 页面行为测试：给监视器注入一个与按点重算结果不同的“已准备摘要”，断言传感器页 `historySummary`、`fanTrendMaximum` 读到的正是它。为此监视器的摘要计算可替换（`MenuBarMonitorState.windowSummary`）；`MenuBarAdvancedStatusView` 可传入自己的 `FanControlCoordinator`，测试不连接硬件助手。② 摘要只为每个需求方最靠前的窗口（打开的历史或页面的时间档，即 `historyDemandPlan.durations` 第一项）准备；CPU、网络卡的窗口只绘制，不再算摘要（原来每次准备都为最多 4 个窗口计算）。若只是顺序变了，新的第一个窗口在下一次准备时得到摘要，期间在读取处按点计算。再按页只给传感器、电源页算，需要把页面信息放进需求，没有做。剩下每次准备一个窗口的后台开销，作为对比的观察项 | 页面测试 `testTheSensorsPageReadsTheSummaryPreparedWithItsWindow`；范围测试 `testOnlyEachConsumersMostVisibleWindowIsSummarized`（含换序）。红：去掉范围限制、保留接缝后，范围测试 2 处失败，改写后的 `testTheMonitorPreparesTheSummaryWithTheWindow` 1 处失败（`p2r-items234-red.log`）。反证“页面总按点重算”：页面测试 2 处失败（`p2r-mutation-a.log`） | `035487a` |
| D39 两条路径 | 只补测试：① 内存压力 `releaseKeptDisplayHistory` 只在无可见需求时释放；释放后切片为空、不标更新中、字节为 0；再打开照常准备。② 面板回收（隐藏、拆除两次撤需求）后窗口仍在；回收后新建的根视图先画保留窗口（标更新中），再被新窗口替换。③ 源码中只有内存压力处理器一个调用点（回收与 `teardown` 都不调用） | `testMemoryPressureReleasesTheKeptWindowsOnlyWhileNothingIsShown`、`testReclaimingTheHiddenPanelKeepsTheWindows`。这两项保护的是已有行为，没有可去掉的修复，用反证代替红灯：“内存压力在窗口可见时也释放”3 处失败（`p2r-mutation-b.log`） | `035487a` |
| D39：一级 CPU 卡 | 一级 CPU 卡与网络卡都接收 `isUpdating`（`cpuDisplayedHistory`／`networkDisplayedHistory`）。保留窗口或上一窗口按 D32 淡化到 45%；一级卡没有坐标行，不加“更新中…”文字。审计中把它标为旧帧，`chart.overview` 只计新帧 | `testTheLevelOneCardsDimAKeptWindow`（用 Mirror 读两张卡收到的 `isUpdating`）；`testOnlyTheChartOfTheCPUCardIsDimmed`（渲染后只有图表所在的行变化，标题与总占用不变）。红：去掉淡化后 3 处失败 | `035487a` |
| 措辞 | 上文“两边插桩相同”处注明 `cpu.placeholder` 的含义变化；`06877f1` 的“已修”改为“已改，修后待实测”。`docs/MENUBAR_PERFORMANCE.md` 写入 `holdHide`、`history.kept` 的 `byWindow`、`cpu.placeholder` 的含义、回收时不释放、摘要只为最靠前的窗口准备 | — | 本交接提交 |
| 零碎 | `MemoryOptimizerService.pressureSummary(from:)` 生产代码已不调用，保留并加注释：它是测试比对内核值与工具输出的参照，本身也有测试。删除会连带改 3 个已有测试 | — | `183a351` |
| 范围外，留作后续 | 以下仍在主线程逐次遍历整段数据，本批不改：电源页放电续航估算 `GeekPowerView.swift:152–158`（`GeekBatteryRemainingTime.estimate` 遍历电源历史）；网络页峰值 `MenuBarAdvancedComponents.swift:724`、`:728`（`history.compactMap(...).max()`，每次重绘遍历所选窗口） | — | — |

验证（本轮，在 `366aea4` 之后的提交上，全部 `--jobs 3`）：
- 红、绿与反证由 `red-green.sh` 完成（证据目录 `p2r/`，同目录的 `identity8.swift` 是上面 24.9／10.2 ms 的离线测量；两者都只输出时间与计数），结果见上表。
- 绿：`MiniWindowPhase2ReviewTests`、`MiniWindowReviewFollowUpTests` 共 12 项 0 失败（`p2r-items234-green.log`）；加上 `MemoryRunningApplicationIdentityCacheTests` 共 18 项 0 失败（`p2r-items234-compile.log`）。
- Debug 全量：
  - 第一次 3424 项、跳过 21、1 失败（`p2r-full.log`）。失败的是 `NetworkCompatibilitySpeedTestServiceTests.testCancellationStopsPendingURLSessionTasks`，断言网络测速取消时 URLSession 已停止挂起的请求，0.004 s 内失败，与本批改动无关。单独重跑该类 3 次，每次 46 项 0 失败（`p2r-network-rerun.log`），判断为负载下的偶发时序问题。
  - 第二次 3424 项、跳过 21、**0 失败**（`p2r-full-2.log`）。
- `check_private_api.py` 通过（6 处白名单）；`git diff --check` 通过。
- Release 小窗性能门禁 **PASS**（`perf-gate.sh`，`183a351`，工作区只有本交接未提交）：
  - 源码守卫 exit 0；Release 测试构建 exit 0，用时 5 min 59 s。这同时说明 `afe75a3` 之后 Release 下的测试能编译。
  - 3 次计时运行，开始时负载 5.32／5.29／5.29；每次 16 项 0 失败。
  - `preparation_p95_ms` 73.55／74.93／75.35（预算 100，未改）；`cached_delivery_p95_ms` 约 0.0015。
  - 日志 `p2r-perf-gate.log`。之后门禁 scratch 移到废纸篓。

### 同负载对比结果（2026-10-07）

**结论**：第二阶段各修复在实测中都达到预期，没有发现回归。
- D39 打开即显示：打开时 CPU“—”从每次都有降到 0，图表“采样中”只剩启动后第一次打开。
- D38：打开后内存新数据与 CPU 同时到达，暖打开 p50 109 → 64 ms。
- 缓存修复（`fbc4162`）：内存三级 28 天档空闲时，进程列表主线程读取 11.35 → 4.27 ms/s。
- P2-1：传感器、电源三级页长档空闲时主线程与 CPU 下降，电源 28 天档悬停 p50 4.5 → 3.2 ms。
- T5：处理器二级页静置时修前 48 s 内跳了 12 次，修后 0 次。
- 保留窗口的实际字节：2.1–2.9 MB；隐藏前开着 28 天档时 5.7–6.2 MB。
- 二级、三级、切档、回到一级、首帧都与修前持平。
- 按页缓存二级页高度仍有收益空间（见下）。

**方法**：
- 包：
  - 修前 `p2-base.app`：`6a00e28`，build 20261005001116。
  - 修后 `p2-post.app`：`b0d1cad`，build 20261006115815，`dirty=false`，源码与集成分支 `6edfba3` 相同，从最终代码重新打包，未安装。
  - 两包除本节改动外，还差集成分支后来并入的 r2-junk 与热修复。
- 运行：`p2-ab.sh`。
  - 每次运行在 1 分钟负载 <4 时才启动；表中的“开始时负载”是启动后几秒的读数，所以个别略高于 4。
  - 计划内每个阶段也以 `maxLoad=4` 把关，单次最多等 900 s，等不到就继续。
  - App Nap 关，并调用 `beginActivity`；只用隔离身份 `com.local.StorageCleanerMac.integration`，`SUEnableAutomaticChecks=false`；修前修后按轮交替先后。
- 轮次：
  - 打开、内存 28 天空闲、传感器／电源 28 天空闲与悬停、稳态、切档：各 2 轮。
  - 二级／三级／进程勾选：3 轮。
  - 7 天空闲、1 小时悬停：1 轮。
  - 保留字节（只跑修后包）：2 次；App Nap 校准（只跑修后包）：开、关各 2 轮。
- 负载与时间：
  - 时间为 10-06 23:10 – 10-07 04:02（悉尼时间）。期间文件同步进程一度把负载推到 5–87。
  - `p2cal2-nap-2` 第一次等了 30 min 仍 ≥4，记为 NOT_RUN；之后把单次等待放宽到 120 min（门槛仍是 <4），在 `cal2` 步骤补跑成功。
  - 3 次运行到了 25 min 运行时限，迭代较少：`p2ab-open-post-1`，以及校准第 1 轮的两次。
  - 运行中负载 p50 ≥4 的运行在下表“每轮时间与负载”中逐个标出。
- 期间主会话可能用 LCU 操作已安装的测试版（不同 Bundle ID），交替轮次可以抵消一部分噪声。
- 原始记录与表：证据目录 `p2ab-*`、`p2kept-*`、`p2cal2-*`，以及 `compare-p2-{open,modules,ranges,hold,hover,steady,kept,stalls,calibration-lowload,runs}.md`。

| 项目 | 修前 | 修后 | 说明 |
|---|---|---|---|
| D39 打开：一级 CPU 总占用为“—” | 48 次打开中 48 次 | 30 次中 0 次 | `cpu.placeholder` 的含义已变（见上），这里只说明修后打开时不再出现“—” |
| D39 打开：图表先画“采样中” | 48 次中 48 次 | 30 次中 2 次 | 那 2 次都是启动后第一次打开，此前还没有可保留的窗口 |
| D38 打开后内存新数据画出 p50（暖／冷／启动后首次） | 109／128／144 ms | 64／80／99 ms | 修后与 CPU 新数据同时到达（CPU 暖 62／62 ms）。冷打开 p95 约 1.05 s 两边相同，是等下一次定时采样，与第一阶段相同 |
| 打开首帧 p50／p95（暖；冷） | 21／52；36／67 ms | 20／53；35／65 ms | 不变 |
| 一级图表新数据画出 p50（暖；冷） | 70；86 ms | 66；84 ms | 修后先画淡化的保留窗口，这里只计新帧 |
| 内存三级 28 天空闲：`memory.processes.main` | 11.35 ms/s（两轮 11.68／11.02） | 4.27 ms/s（3.61／4.94） | `fbc4162` 的缓存命中后，每次刷新只读名称、策略、活动状态和启动时间 |
| 同上：主线程忙 p50 ／ p95；CPU（两轮） | 52.2 ／ 68.0 ms/s；7.26／7.78% | 41.0 ／ 57.0 ms/s；6.48／6.85% | 两边都没有 >50 ms 的长循环（负载 3.0–3.8） |
| 二级／三级计划中每次运行的进程列表主线程读取合计 | 249–343 ms | 86–97 ms | 3 轮 |
| 传感器三级 28 天空闲：主线程忙 p50；CPU（两轮） | 45.1 ms/s；6.76／7.58% | 37.2 ms/s；5.93／6.90% | P2-1 |
| 电源三级 28 天空闲：主线程忙 p50；CPU（两轮） | 34.1 ms/s；7.43／7.66% | 29.6 ms/s；6.87／7.35% | P2-1 |
| 7 天档空闲（1 轮）：传感器；电源（主线程忙 p50） | 47.2；34.2 ms/s | 36.5；31.7 ms/s | 1 轮，只作趋势 |
| 电源三级 28 天悬停：绘制 p50 ／ p95；提交 max | 4.5 ／ 6.5；26.3 ms | 3.2 ／ 6.0；16.6 ms | 每轮 596 次移动，共 2 轮。电源帧可否画趋势已在后台算好 |
| 传感器 28 天悬停；1 小时档悬停 | 2.5 ／ 5.1；2.7–3.0 ms | 2.7 ／ 5.0；3.0–3.2 ms | 不变（原本就不在悬停时遍历） |
| T5：处理器二级页静置 60 s 的 `detailSize` 整窗重排 | 第 1 轮 1 次（只有切入时）；第 2 轮 13 次（切入 1 次，静置中 12 次在 662↔666 之间来回，间隔 2–12 s，每次 6.5–7.8 ms） | 两轮各 1 次（只有切入时，始终 666 pt） | 修前是否跳动取决于当时进程数是否在 5 行上下波动；修后高度固定 |
| 二级首次绘制 p50／p95（自一级；自其他二级） | 49／62；35／48 ms | 48／60；35／43 ms | 3 轮，不变 |
| 三级首次绘制；三级图表有数据 | 27／38；38／50 ms | 26／34；39／48 ms | 不变 |
| 切档新数据画出（各档 p50） | 17–29 ms | 16–31 ms | 不变，两边都无超时 |
| 回到一级；进程勾选 | 35／40；11／15 ms | 35／39；11／17 ms | 不变 |
| 稳态 CPU（一级可见；处理器页可见；隐藏未回收；已回收，两轮） | 3.52／4.40；6.83／7.90；1.13／1.29；1.02／1.12% | 3.78／4.10；6.79／7.25；0.84／1.25；0.83／0.90% | 不变。隐藏期间保留窗口没有增加开销 |
| >50 ms 主线程循环（全部 A/B 运行） | 243 次；≥150 ms 1 次 | 222 次；≥150 ms 0 次 | 修前那次 511 ms 发生在脚本结束、面板隐藏后：Core Animation 提交在等渲染服务回复（`CA::Render::Encoder::send_message`→`mach_msg`），属系统等待 |

**保留窗口的字节核算（D39）**，口径见上节：

| 隐藏时的情形 | 保留的数组 | 点数 | 窗口数组字节 | 读数数组（与完整历史共享，上限） |
|---|---|---|---|---|
| 一级卡（15 分＋1 时，遥测与内存各一份），共 103 次隐藏 | 4 | 6,581–9,064 | **2.08–2.87 MB** | ≤ 2.38 MB |
| 处理器三级 28 天档打开时隐藏（1 时＋28 天） | 4 | 18,017 | **5.65 MB** | ≤ 4.30 MB |
| 内存三级 28 天档打开时隐藏（15 分＋1 时＋28 天） | 6 | 19,783 | **6.22 MB** | ≤ 4.73 MB |

- 1 小时窗口约 3,500 点、1.1 MB；28 天窗口遥测约 4,860 点、1.5 MB，内存约 6,060 点、1.9 MB。D39 原文“约 1–15 MB”的估算，实测为 2.1–6.2 MB 自有缓冲；把共享的读数数组也算上，上限约 11 MB。

**App Nap 校准（复核 P2-4，修后包）**：

| 交互（p50／p95 ms） | App Nap 开（不调用 `beginActivity`） | App Nap 关（`NSAppSleepDisabled`＋`beginActivity`） |
|---|---|---|
| 二级首次绘制：自一级；自其他二级 | 51／66；35／46 | 51／70；36／44 |
| 回到一级 | 36／40 | 36／39 |
| 打开首帧：暖；冷 | 18／48；34／77 | 18／50；36／66 |
| 打开后内存新数据（暖） | 62／72 | 61／71 |

- 两种设置之间没有系统性差别。第 1 轮负载 p50 6.1–6.7，两次都到了 25 min 时限；第 2 轮负载约 3.6。
- 结论：App Nap 对离屏测量没有可测影响。第一阶段允许 App Nap 时测得的绝对值，与第二阶段关闭后的绝对值量级可比。表中“修前／修后”两列分别对应开、关。

**按页缓存二级高度：仍有收益空间。** 二级／三级计划 3 轮中，每次打开二级页都是先按 716 pt 放置（原因 `section`），再按实测高度重排一次（原因 `detailSize`），修前修后次数相同：
- 处理器：48 次打开中 36 次；
- 磁盘：36 次中 39 次（有时一次打开重排两次）；
- 内存：39 次中 39 次；
- 网络：36 次中 29 次；
- 传感器、电源：0 次。

处理器页这一次重排不是进程卡片引起的（原先的推测被否定），是首次放置用的默认高度与实测高度不同。T5 修好后处理器页高度固定为 666 pt，按页缓存的高度从此稳定可用。值不值得做是判断：收益是每次打开少一次 7–14 ms 的整窗重排和一次位置跳动，代价是要处理缓存过期；JEV 对“仍需要”只给出低置信度，见下。建议列为下一批候选，与 T4 一起评估。

JEV 复核（`jev_verify`，`auto_accept` 0.8）：
- “D39 去掉打开时的 CPU‘—’与‘采样中’（启动后首次除外）”：verified，confidence 1.00，auto。
- “缓存修复降低内存三级空闲时的进程列表主线程时间”：verified，0.98，auto。
- “处理器页静置时不再因 662／666 交替而整窗重排”：verified，0.94，auto。
- “T5 之后仍需要按页缓存二级高度”：contradicted，但 confidence 只有 0.07，标为 review（supports 0.28、says_nothing 0.34、contradicts 0.38）。这是设计判断，不是测量能直接回答的事实，所以本节只写“仍有收益空间”。

**观察（未归因，供复核）**：
1. **`monitor.update` 计时段修后多 0.2–0.4 ms/s**。修前 0.08–0.10，修后 0.31–0.50 ms/s，5 种空闲计划、两轮都如此。这段代码（历史追加、发布快照、调度准备）在两包之间没有改动；两包还差 r2-junk 与热修复，原因未查明。在同一批运行里，修后总主线程忙与 CPU 都更低。
2. **三级卡片重绘次数修后更少**：4.1 → 2.8–3.5 次/s。原因没有分析。
3. **修后二级／三级计划第 1、2 轮出现一次 CPU 总占用“—”**，都在开始后约 52 s，正是从电源二级页回到一级时，第 3 轮没有出现。修前这里读的是同一数据源（历史最后一点），但修前的探针在打开时就已回执，看不到之后是否也出现。推测是某次采样不含 CPU，未验证。建议后续在审计中记录该时刻快照是否含 CPU。
4. **修后在切换二级页的长循环里能看到 `memory.processes.main`**，3 轮合计 102 ms。但每次运行的总量反而更低（86–97 对 249–343 ms），长循环次数也不变（169 对 170，p50 都是 63 ms）。推测是 D38 让内存快照更早到达，与切页落进了同一次循环。

**每轮时间与负载**（开始时间为悉尼时间；“运行中负载”取每 2 s 的 1 分钟负载读数）：

| 运行 | 开始（悉尼） | 时长 | 开始时负载 | 运行中负载 p50 / max | 备注 |
|---|---|---|---|---|---|
| p2ab-open-pre-1 | 10-06 23:10 | 9.0 min | 3.98 | 5.60 / 10.38 | 运行中负载 p50 ≥ 4 |
| p2ab-open-post-1 | 10-06 23:19 | 25.1 min | 3.86 | 8.43 / 30.47 | 到运行时限；运行中负载 p50 ≥ 4 |
| p2ab-holdmem-pre-1 | 10-06 23:50 | 3.4 min | 3.74 | 3.37 / 3.97 |  |
| p2ab-holdmem-post-1 | 10-06 23:53 | 3.4 min | 3.29 | 3.15 / 4.46 |  |
| p2ab-hold-sensors-28d-pre-1 | 10-06 23:57 | 2.0 min | 3.71 | 3.53 / 4.22 |  |
| p2ab-hold-sensors-28d-post-1 | 10-06 23:59 | 2.0 min | 3.14 | 2.91 / 3.56 |  |
| p2ab-hold-power-28d-pre-1 | 10-07 00:01 | 2.0 min | 2.70 | 2.85 / 3.39 |  |
| p2ab-hold-power-28d-post-1 | 10-07 00:03 | 2.0 min | 3.28 | 3.16 / 3.76 |  |
| p2ab-hover-sensors-28d-pre-1 | 10-07 00:05 | 0.7 min | 3.01 | 3.41 / 3.81 |  |
| p2ab-hover-sensors-28d-post-1 | 10-07 00:06 | 0.7 min | 3.27 | 2.77 / 3.27 |  |
| p2ab-hover-power-28d-pre-1 | 10-07 00:06 | 0.7 min | 2.96 | 2.91 / 3.01 |  |
| p2ab-hover-power-28d-post-1 | 10-07 00:07 | 0.7 min | 3.02 | 3.02 / 5.91 |  |
| p2ab-modules-pre-1 | 10-07 00:09 | 2.8 min | 3.88 | 3.21 / 4.67 |  |
| p2ab-modules-post-1 | 10-07 00:12 | 3.4 min | 3.08 | 3.87 / 5.33 |  |
| p2ab-steady-pre-1 | 10-07 00:15 | 4.3 min | 3.38 | 3.20 / 4.43 |  |
| p2ab-steady-post-1 | 10-07 00:25 | 6.3 min | 3.88 | 3.63 / 16.57 |  |
| p2ab-ranges-pre-1 | 10-07 00:35 | 1.5 min | 3.96 | 3.95 / 4.30 |  |
| p2ab-ranges-post-1 | 10-07 00:37 | 1.1 min | 3.80 | 3.68 / 4.05 |  |
| p2kept-memory-28d | 10-07 00:40 | 0.9 min | 3.98 | 3.82 / 4.06 |  |
| p2kept-processor-28d | 10-07 00:41 | 2.2 min | 3.28 | 4.47 / 6.19 | 运行中负载 p50 ≥ 4 |
| p2cal2-nap-1 | 10-07 00:43 | 25.1 min | 3.76 | 6.13 / 22.83 | 到运行时限；运行中负载 p50 ≥ 4 |
| p2cal2-nonap-1 | 10-07 01:11 | 25.1 min | 3.93 | 6.66 / 20.74 | 到运行时限；运行中负载 p50 ≥ 4 |
| p2ab-open-post-2 | 10-07 02:11 | 2.2 min | 4.10 | 4.15 / 4.78 | 运行中负载 p50 ≥ 4 |
| p2ab-open-pre-2 | 10-07 02:13 | 1.2 min | 3.66 | 3.43 / 3.66 |  |
| p2ab-holdmem-post-2 | 10-07 02:14 | 3.5 min | 3.40 | 3.81 / 4.39 |  |
| p2ab-holdmem-pre-2 | 10-07 02:18 | 3.4 min | 3.61 | 3.61 / 4.60 |  |
| p2ab-hold-sensors-28d-post-2 | 10-07 02:21 | 3.2 min | 3.53 | 3.92 / 4.98 |  |
| p2ab-hold-sensors-28d-pre-2 | 10-07 02:25 | 2.0 min | 3.46 | 3.75 / 4.32 |  |
| p2ab-hold-power-28d-post-2 | 10-07 02:27 | 2.0 min | 3.61 | 4.49 / 4.90 | 运行中负载 p50 ≥ 4 |
| p2ab-hold-power-28d-pre-2 | 10-07 02:29 | 2.0 min | 3.77 | 3.81 / 4.34 |  |
| p2ab-hover-sensors-28d-post-2 | 10-07 02:33 | 0.7 min | 3.96 | 3.57 / 3.96 |  |
| p2ab-hover-sensors-28d-pre-2 | 10-07 02:33 | 0.7 min | 3.72 | 3.68 / 3.75 |  |
| p2ab-hover-power-28d-post-2 | 10-07 02:34 | 0.7 min | 3.70 | 4.07 / 4.78 | 运行中负载 p50 ≥ 4 |
| p2ab-hover-power-28d-pre-2 | 10-07 02:36 | 1.1 min | 3.99 | 4.05 / 4.52 | 运行中负载 p50 ≥ 4 |
| p2ab-modules-post-2 | 10-07 02:37 | 2.8 min | 3.72 | 3.73 / 4.26 |  |
| p2ab-modules-pre-2 | 10-07 02:40 | 4.0 min | 3.65 | 4.00 / 4.26 | 运行中负载 p50 ≥ 4 |
| p2ab-steady-post-2 | 10-07 02:44 | 4.3 min | 3.40 | 3.30 / 3.82 |  |
| p2ab-steady-pre-2 | 10-07 02:48 | 4.3 min | 2.79 | 4.35 / 5.50 | 运行中负载 p50 ≥ 4 |
| p2ab-ranges-post-2 | 10-07 02:53 | 1.1 min | 3.72 | 3.59 / 3.74 |  |
| p2ab-ranges-pre-2 | 10-07 02:54 | 1.1 min | 3.47 | 3.66 / 3.99 |  |
| p2cal2-nonap-2 | 10-07 02:55 | 2.7 min | 4.45 | 3.61 / 4.57 |  |
| p2cal2-nap-2 | 10-07 02:58 | 2.9 min | 3.71 | 3.67 / 4.26 |  |
| p2ab-modules-pre-3 | 10-07 03:01 | 2.6 min | 3.22 | 3.76 / 4.11 |  |
| p2ab-modules-post-3 | 10-07 03:03 | 3.4 min | 3.96 | 3.81 / 4.83 |  |
| p2ab-hold-sensors-7d-pre-1 | 10-07 03:07 | 2.6 min | 3.31 | 3.49 / 4.60 |  |
| p2ab-hold-sensors-7d-post-1 | 10-07 03:09 | 2.0 min | 3.43 | 3.80 / 4.21 |  |
| p2ab-hold-power-7d-pre-1 | 10-07 03:11 | 3.9 min | 3.89 | 4.15 / 5.09 | 运行中负载 p50 ≥ 4 |
| p2ab-hold-power-7d-post-1 | 10-07 03:21 | 2.0 min | 4.70 | 4.02 / 4.71 | 运行中负载 p50 ≥ 4 |
| p2ab-hover-sensors-1h-pre-1 | 10-07 03:31 | 0.6 min | 3.41 | 3.33 / 3.47 |  |
| p2ab-hover-sensors-1h-post-1 | 10-07 03:41 | 0.6 min | 3.41 | 3.78 / 4.19 |  |
| p2ab-hover-power-1h-pre-1 | 10-07 03:51 | 0.6 min | 3.14 | 3.66 / 3.88 |  |
| p2ab-hover-power-1h-post-1 | 10-07 04:01 | 0.6 min | 3.17 | 2.95 / 3.60 |  |

### 结论（第二阶段）

1. **代码项全部完成**：主会话第二阶段清单中的 D38、D39 与第 1–11 项（N11-1～4、复核 P2-1～4、T5、未归因卡顿的计时与抓栈、`49b81bc` 措辞），另加一处由归因发现的修复（`06877f1`，复核后由 `fbc4162` 修正命中方式）；共 11 个功能提交（各带测试）、2 个插桩提交、1 个措辞提交。每项都先红后绿。没有删断言、放宽预算或跳过测试；锁定旧行为的源码契约只按 D38、D39 改写（见“源码契约”）。
2. **修前基线的归因**（负载偏高，只用于归因）：
   - 内存三级 28 天档空闲时 26 次 50–116 ms 的长循环中，25 次由内存进程列表的主线程读取主导（合计 17.9 ms/s）。`06877f1` 按应用对象身份缓存，复核发现从不命中：`runningApplications` 每个运行循环都返回新对象。`fbc4162` 改为按“pid＋进程启动时间”命中。同负载对比（两轮）：11.35 → 4.27 ms/s，长循环两边都没有出现。
   - 传感器、电源三级页空闲时 ≥150 ms 的循环，是系统空间切换和负载下的 Core Animation 提交等待，不是应用代码。
   - 打开、切页时 ≥150 ms 的循环，是 SwiftUI 建图、首次创建字体、首次实例化类型元数据这类框架首次开销。
   - 第一阶段 `base3` 中未归因的长循环，推断与上面第一条同类（当时没有计时段，无法逐次确认）；`post` 的 503 ms 没有复现。
3. **验证**：Debug 全量（`6408da7`，代码与 `5a66619` 相同）3411 项、跳过 21、**0 失败**，exit 0（`logs/p2-full-2.log`，开始时负载 30.8，结束时 7.0；第一次全量 `p2-full-1` 中受高负载影响失败的 `MacBenchmarkKernelTests` 计时项这次通过）；Release 小窗性能门禁 **PASS**：3 次，每次开始时负载 5.88、5.96、5.89，都 <6；每次 16 项 0 失败；`preparation_p95_ms` 79.98／75.84／73.69（预算 100），预算未改动；`python3 script/check_private_api.py` 通过（6 处白名单内的使用）；`git diff --check`（工作区，以及 `724b06c..HEAD`）无问题。
4. **同负载对比已完成**（2026-10-07，修后包为复核后最终代码 `b0d1cad`），结果见上节“同负载对比结果”。
   - 打开时 CPU“—”48/48 → 0/30；图表“采样中”48/48 → 2/30（只剩启动后首次打开）。
   - 打开后内存新数据（暖）109 → 64 ms，与 CPU 同时到达。
   - 内存三级 28 天空闲：进程列表主线程读取 11.35 → 4.27 ms/s，主线程忙 52.2 → 41.0 ms/s。
   - 传感器、电源三级 28 天空闲时主线程与 CPU 下降；电源 28 天悬停 p50 4.5 → 3.2 ms。
   - 处理器页静置时的 662↔666 跳动消失（修前一轮 12 次，修后 0 次）。
   - 保留窗口 2.1–6.2 MB；App Nap 对测量没有可测影响。
   - 其余交互与修前持平。
   - 按页缓存二级高度仍有收益空间（每次打开多一次 7–14 ms 整窗重排）。是否做由下一批与 T4 一起评估，JEV 对“仍需要”只给出低置信度。

### 各项：改了什么、依据、测试

| # | 条目 | 改了什么（行号为 `5a66619`） | 行为与依据 | 测试（红 → 绿；日志在 `~/Developer/.sc-build/r2-mini-speed/logs/`） |
|---|---|---|---|---|
| 1 | D38 内存空闲百分比 | `SystemMemoryProbe.swift:361` 读 `sysctlbyname("kern.memorystatus_level")`，读不到时仍为“压力数据不可用”；文字与数值共用 `MemoryOptimizerService.swift:127` `pressureSummary(freePercentage:)`（“压力余量 N%”，与解析工具输出相同） | D38；状态采样不再启动 `memory_pressure` 子进程（每次约 60 ms → 0.013 ms，第一阶段 R4） | 红：2 项 4 处失败（`d38-red.log`）；绿：`MemoryHeadroomSysctlTests`、`SystemUtilitySafetyTests`、内存相关共 248 项，跳过 1，0 失败（`d38-green.log`）。“工具读数与内核值”测试改为工具读数夹在其前后两次内核读数之间（不设容差，工具运行中值变动时最多重测 3 次） |
| 2 | D39 隐藏时保留历史窗口 | `ScanStore.swift:512–561`（需求为空时保留上次可见需求的已准备窗口并标记，记 `history.kept`）、`:564` `releaseKeptDisplayHistory`（只在无可见需求时释放，`MenuBarStatusController.swift:79` 内存压力时调用）、`:594` `displayHistorySlice`（保留的窗口标“更新中”）、`:639` 交付新窗口时整组替换并清除标记；`MenuBarHistoryDemandPlan.swift:20` `currentReading(live:)`；`MenuBarAdvancedStatusView.swift:198`、`:204`；`GeekOverviewPresentation.swift:23`；`MenuBarDisplayHistoryFootprint.swift`（按字节核算） | D39（用户同意“保留，打开即显示”）；隐藏期间不准备（门禁 `testHiddenHistoryStopsAndIdenticalDemandDoesNotRepeatPreparation` 仍断言）；保留窗口按 D32 淡化并显示“更新中…”；CPU 总占用／用户／系统、处理器页 CPU 占用、网速标题在历史未就绪或为保留窗口时读实时快照 | 红：6 项 17 处失败（`d39-red.log`）；绿：`MiniWindowKeptHistoryTests` 等 9 个测试类 168 项，跳过 1，0 失败（`d39-green.log`） |
| 3 | N11-1 “更新中”只比较时间窗 | `MenuBarPreparedChart.swift:27`、`:59–65`：请求带所示时间窗，两边都有时间窗时只比较时间窗；折线、网络、磁盘、电源历史帧传入各自时长 | 纵轴量程、采样间隔变化时旧帧仍保留到新帧交付，只是不再标“更新中”；没有时间窗的请求保持原判断 | 红：2 处失败（`n11-1-red.log`）；绿：127 项，跳过 1，0 失败 |
| 4 | N11-2 重放触顶 | `MenuBarPanelSession.swift:526`、`:782`、`:808–815`、`:841–842`：延后的几何调用记下是否为切页；触顶时执行最后一次切页及其后的调用各一次（无切页时仍只执行最新一个），它们产生的调用照旧丢弃并写日志 | 原来只执行队尾一个，队尾常是新页尺寸上报，会话会停在旧页却带新页高度 | 红：会话停在 processor 而最后一次切页是 power（`n11-2-red.log`）；绿：78 项 0 失败 |
| 5 | N11-3 简单面板退出请求取消 | `ScanStore.swift:4285–4310`、`:7152`：打开确认框时记下被替换的选择，取消时恢复，确认或刷新清除确认框时丢弃记录 | 入口目前不可达，行为按 N11 修正 | 红：2 处失败（`n11-3-red.log`）；绿：38 项 0 失败 |
| 6 | N11-4 换入／换出说明 | `GeekMemoryView.swift:382–387` 恢复“也包含交换文件维护产生的读写”／“It also includes I/O for swap file maintenance.”，注释注明 `man vm_stat` 第 107 行原文；`docs/mini-window-design.md:64` 同步 | D29 原意 | 红：4 处失败（`n11-4-red.log`）；绿：6 项 0 失败 |
| 7 | 复核 P2-1 传感器、电源三级页长档 | `MenuBarTelemetryWindowSummary.swift`（新）：可画的温度通道、是否有风扇目标转速、风扇最大值、GPU 温度统计，随每个遥测窗口在后台计算（`ScanStore.swift` 准备任务）；传感器三级页、`fanTrendMaximum` 读这份摘要（`MenuBarTertiaryDetail.swift`、`MenuBarAdvancedComponents.swift`）；`GeekPowerPreparationKernel.swift` 准备电源帧时算出 `hasRenderableTrend`，重绘与悬停直接读 | 每项与原来的计算逐项相等；没有已准备窗口时（演示数据、测试）在视图里按原法计算 | 红：6 处失败（`p2-1-red.log`）；绿：170 项，跳过 1，0 失败；摘要与原计算逐项相等（含缺口、缺通道、无风扇目标、空窗口） |
| 8 | 复核 P2-2 修复 2 的偏移缓存 | `MenuBarPanelSession.swift:506`、`:948–950`：记下缓存测得时的仪表盘配置，不同即清空；`:1393` `clampedDetailTopOffset`：沿用缓存值时按这次的上限重新夹取 | 仪表盘模块重排或隐藏（概览尺寸可以不变）后不再沿用旧偏移 | 红：3 处失败（`p2-2-red.log`）；绿：80 项 0 失败；换密度、概览尺寸变化两条清空路径补了测试 |
| 9 | 复核 P2-3 修复 1 的行为测试 | `MenuBarLiveCard.swift:45` `MenuBarCardIdentity.page(named:openSection:)`（liveCard 改调该纯函数，行为不变）；测试对每个可打开的页计算身份 | 原测试恒等成立 | 绿：5 项 0 失败；反证：把该函数改成忽略指名页面，新测试 2 处失败（`p2-3-mutation.log`），已从备份恢复 |
| 10 | 复核 P2-4 脚本模式不被节流 | `MenuBarLatencyScript.swift:109` 只在脚本模式 `beginActivity([.userInitiated, .latencyCritical])`（计划 `activity=0` 不调用，校准用）；运行脚本对隔离身份写 `SUEnableAutomaticChecks=false`、`NSAppSleepDisabled=true`（`APP_NAP=on` 时删除），结束时删除 `NSAppSleepDisabled` | 只影响测量副本 | 校准见下 |
| 11 | T5 处理器二级页高度跳动 | `GeekProcessorView.swift:474–535`：进程卡片抽成 `GeekProcessorProcessList`；行区按可列出的最多行数预留高度（5 行，紧凑 3 行） | 根因：卡片最小高度 111（紧凑 75）pt 只容得下比上限少一行，列满时长到 115（81）pt，页面与整个级联随快照伸缩；修后少于上限时下方留白 | 红：改前实测 0–5 行 111,111,111,111,111,115 pt、紧凑 0–3 行 75,75,75,81 pt（`t5-red.log`）；绿；`MiniWindow|MenuBar|Geek|Golden|Visual|Panel` 638 项，跳过 1，0 失败（`t5-broad.log`） |
| 12 | 未归因卡顿：计时段与抓栈 | `MenuBarStallSampler.swift`（新）、`MenuBarPresentationTrace.swift` `measure`；段：`monitor.deliver`／`update`／`memory`、`card.reconcile`、`memory.processes.main`、`process.demand`、`aux.consumer`／`refresh`、`session.windowDidMove` | 只在 Debug／测试版且带 `--menu-bar-performance-audit=` 时生效；采样线程每 10 ms 暂停主线程几微秒读寄存器、沿帧指针取返回地址，暂停期间不分配、不加锁；栈只记映像名＋偏移／符号，不含路径 | `MiniWindowSpeedInstrumentationTests`；667 项，跳过 2，0 失败（`p2-instr-tests.log`） |
| 13 | 归因到的卡顿：运行中应用属性 | `SystemMemoryProbe.swift` `RunningApplicationIdentityCache`：`06877f1` 按每个 `NSRunningApplication` 实例记下 bundleIdentifier、bundleURL、executableURL、launchDate，复核发现实例每个运行循环都换新，从不命中。`fbc4162` 改为按 pid＋进程启动时间（`proc_pidinfo` `PROC_PIDTBSDINFO`）判定同一进程：读不到启动时间就每次重读、不存缓存；pid 被复用时重读。名称、激活策略、是否活动每次读取；不再列出的应用移除 | 这四项在同一进程内不变；仍在主线程读取 | `fbc4162`：红（跨运行循环复用 0／164，`p2r-cache-red.log`）→ 绿 6 项（`p2r-cache-green.log`）；反证“从不复用”“只看 pid”都失败（`p2r-cache-mutation.log`）。`06877f1` 时的测试只在同一运行循环里连调，测不出不命中 |
| 14 | 交接措辞 | 第一阶段 `49b81bc` 的空闲 CPU 降幅（每种包 1 轮）改写为“趋势”，注明未补跑到 3 轮 | 复核意见 11 | — |

### D38：部署下限 macOS 14 上 `kern.memorystatus_level` 的可用性依据

- 本机（macOS 27.2）可读；`MemoryHeadroomSysctlTests` 中 `memory_pressure -Q` 打印的 “System-wide memory free percentage” 每次都落在它前后两次 `sysctl` 读数之间（不设容差）。
- 本机 `/usr/bin/memory_pressure` 的字符串里有 `memorystatus_get_level failed:`：该工具用 `memorystatus_get_level` 系统调用取同一个内核变量；系统 SDK 的 `libsystem_kernel.tbd` 在 MacOSX15.4.sdk（Command Line Tools）与 Xcode 27 SDK 中都导出 `_memorystatus_get_level`。这只证明该内核接口在 macOS 15 及以后存在，不直接证明 14。
- 按对 XNU 开源代码的了解：`bsd/kern/kern_memorystatus.c` 以只读 `SYSCTL` 导出内核变量 `memorystatus_level`（`kern.memorystatus_level`），`memorystatus_get_level` 系统调用拷出的是同一个变量；macOS 14 对应的 xnu-10002 中仍有该 sysctl（最早从哪一版开始不确定）。这一条是已有了解，本次不联网，**没有重新核对源码，也没有 macOS 14 机器实测**。
- 读不到时的行为：`sysctlbyname` 失败或长度不符返回 nil，内存页显示“压力数据不可用”（与原来子进程失败时相同），不会崩溃、不会显示错误数值。
- 建议：主会话若有 macOS 14 实机或虚拟机，跑一次 `sysctl kern.memorystatus_level` 或 `swift test --filter MemoryHeadroomSysctlTests` 确认。

### D39：保留窗口的字节核算

- 口径（`MenuBarDisplayHistoryFootprint`，不用 footprint）：每个保留窗口是一个 `[MenuBarTelemetryPoint]`，计“数组头 32 字节＋容量 × `MemoryLayout<MenuBarTelemetryPoint>.stride`”，按 malloc 16 字节取整；每点的温度、风扇读数数组另计一列（窗口里的点是完整历史中点的拷贝，这些数组的缓冲区与完整历史共享，不重复占用，只作上限）。遥测窗口与内存窗口按需求的每个时长各准备一份，所以 1 个时长 = 2 个数组。
- 审计模式下每次隐藏记一条 `history.kept`（`c5e1325` 起带每个窗口的种类、时长、点数、字节）。
- 实测（`compare-p2-kept.md`，详见“同负载对比结果”）：只有一级卡窗口（15 分＋1 时，遥测与内存各一份）时 2.08–2.87 MB；隐藏前开着处理器、内存三级 28 天档时分别为 5.65、6.22 MB。以上是自有缓冲，另有与完整历史共享的读数数组，上限 2.4–4.7 MB。D39 原文“约 1–15 MB”的估算，实测为 2.1–6.2 MB。
- 保留到何时：下一次打开时，新需求的窗口准备好后整组替换；没有可见需求时收到系统内存压力（warning 或 critical）即释放；面板隐藏 5 分钟被回收时**不**释放（与 DECISIONS D39 补充一致：主会话在 `1341a7b` 写入，本分支 `6408da7` 并入）。

### 校准：App Nap 与脚本模式（复核 P2-4）

- **校准前后的口径**：第一阶段的所有绝对值（下文“第一阶段”各表）是在允许 App Nap 的情况下测得的：运行脚本没有写 `NSAppSleepDisabled`，应用也没有调用 `beginActivity`；离屏的附属应用可能被系统节流。第二阶段的基线运行（`p2b-*`）以及待跑的对比，都在关闭 App Nap 并调用 `beginActivity([.userInitiated, .latencyCritical])` 的情况下进行，属于“校准后”。第一阶段运行记录的开始行没有 `appNap` 字段，`script.start` 也没有 `latencyCriticalActivity`，与此一致。另一个环境差别：第一阶段运行时 `script.start` 记录 1 块屏，第二阶段基线记录 2 块。第一阶段的结论都来自同一设置下的修前／修后交替对比，不受影响；但两阶段之间的绝对值暂不宜直接比较。
- **高负载校准**（`p2cal-*`）：同一修前包，App Nap 开（`activity=0`，不写 `NSAppSleepDisabled`）与关各 2 轮，计划 `openclose,modules`，迭代 6 次。开始时负载 20.4–46.8，整个过程在 20–47 之间，对比表见 `compare-p2-calibration.md`（其中“修前”列为 App Nap 开，“修后”列为关）。没有看到系统性差别，p50／p95 ms 如下：
  - 二级首次绘制：自一级 92／123 对 92／130，自其他二级 59／95 对 58／90；
  - 回到一级：61／81 对 61／79；
  - 暖打开首帧：27／89 对 31／84；冷打开首帧：59／109 对 71／131。

  负载这么高，节流的影响会被淹没，所以这一轮**不能**下结论。
- **低负载校准**（修后包，开、关各 2 轮，见“同负载对比结果”）：两种设置之间没有系统性差别。例如二级首次绘制自一级 51／66 对 51／70 ms，暖打开首帧 18／48 对 18／50 ms。结论是 App Nap 对离屏测量没有可测影响，第一、二阶段的绝对值量级可比。

### 未归因卡顿的归因（复核意见 10）

修前基线（`6a00e28`，App Nap 关；负载 11–85，偏高）的运行中，每次超过 50 ms 的主线程循环都记录了当次各计时段的耗时；≥150 ms 的循环还抓了主线程栈，每 10 ms 采一次，保留最多 4 种不同的栈。汇总脚本为 `stall_attr.py`，抓栈明细用 `stall_stacks.py`。

| 场景（运行） | >50 ms 次数（p50／max ms） | 单个计时段占该次一半以上 | ≥150 ms 的栈 | 结论 |
|---|---|---|---|---|
| 内存三级 28 天档空闲 300 s（`p2b-hold-mem28`） | 26（54／116） | 25 次是 `memory.processes.main`（合计 1482 ms，17.9 ms/s） | 无 ≥150 ms | **真实开销，已修**（`fbc4162`；同负载两轮 11.35 → 4.27 ms/s）：内存二级页的进程列表每次刷新都在主线程读所有运行中应用的包标识、路径、启动时间（约 57 ms／次）。`06877f1` 想按实例只读一次，但按对象身份判断，复核发现从不命中；`fbc4162` 改按 pid＋启动时间判断。离线实测 165 个应用、每次新对象：原读法 24.9 ms，修后 10.2 ms（名称、策略、活动与启动时间）。第一阶段 `base3` 中同一场景的 15 次 50–228 ms 未归因长循环，推断属于这一类（第一阶段没有计时段，无法逐次确认；228 ms 比第二阶段这类最长的 116 ms 长，当时负载也不同） |
| 传感器、电源三级页 7／28 天档空闲各 120 s、悬停 600 次（8 次运行） | 空闲 39（60／319），悬停 15（61／144） | 无 | 空闲时 3 次：236 ms 是 Core Animation 提交中的 commit handler 用 `dispatch_sync` 等另一条队列（负载 85 时）；319、281 ms 是系统切换桌面空间（`_NSMenuBarDisplayManagerActiveSpaceChanged`）后与 WindowServer 的往返 | **系统事件或负载所致，非应用代码**，应用内无法消除。50–150 ms 的空闲循环里没有哪个计时段占主导（`card.reconcile` 合计 26 ms），主要是重绘本身；这类重绘的代价已由 P2-1 减少（同负载对比：传感器 28 天空闲主线程忙 45.1 → 37.2 ms/s，电源 34.1 → 29.6 ms/s） |
| 打开、二级打开／切换（`p2b-modules` 等） | 二级 101（89／151），打开 2（119／201） | 二级里有 1 次是 `memory.processes.main` | SwiftUI 视图图建立、首次创建字体（CoreText）、Swift 泛型类型元数据首次实例化 | **框架的首次开销**，与第一阶段 R2、R3 一致；减少它要靠 T3（一级列不换外层结构）等结构改动 |
| 稳态可见（`p2b-steady`，负载最高 85） | 62（63／185） | 无 | 2 次（185、157 ms）：SwiftUI 视图图更新，以及首次实例化泛型类型元数据（栈中的应用帧是一级 CPU 卡 `GeekProcessorPresentation.body` 和二级页 `geekSelectedDetailPage`，在实例化泛型类型元数据） | 同上：框架首次开销，不是应用逻辑循环 |

- 第一阶段 `post` 中那一次 503 ms：在 15 次第二阶段基线运行里没有复现。第二阶段测到的 ≥250 ms 循环只有系统空间切换和打开时的框架首次开销两类，推测属于其中一类，**无法确认**。
- 是否“测量假象”：关掉 App Nap 后，内存进程列表这一类仍然存在，所以是真实开销。236 ms 的提交等待只出现在负载 85 时，属于负载造成的。其余都是框架或系统事件。修后在低负载下重跑同一计划（`holdmem`、`modules`、`steady`），见“同负载对比结果”：内存 28 天空闲两边都没有 >50 ms 的长循环；所有 A/B 运行中 ≥150 ms 的只有修前 1 次（系统等待）。

JEV 复核（`jev-latest`，`jev_verify`，`auto_accept` 0.8；只提交非敏感的数字、阶段名和框架函数名；结果仅作参考，不作批准）：

| 结论 | 结果 |
|---|---|
| 内存三级 28 天档空闲的长循环主要由 `memory.processes.main` 造成 | verified，confidence 1.00，auto |
| 传感器、电源三级空闲时 3 次 ≥150 ms 的循环在系统或框架等待中，不在应用代码里 | verified，confidence 0.99，auto |
| T5 的 662／666 pt 跳动来自进程卡片高度随进程数变化，固定卡片高度即去掉这一重排来源 | verified，confidence 0.98，auto。注意：修后的运行时测量还没做 |
| 高负载校准没有系统性差别，不能据此判断 App Nap 的影响 | verified，但 confidence 只有 0.55，标为 **review**（supports 0.70，contradicts 0.20）。冷打开 p50 59 对 71 ms 是 App Nap 关时反而更慢，差别两个方向都有。本节只说“不能下结论”，不当作“没有影响”的证据 |

### T5 与“按页缓存高度”是否还需要

- 根因与修复见上表第 11 项（`da492a3`）：进程卡片高度随快照里的进程数在 111／115 pt（紧凑 75／81 pt）之间变化，带动处理器页在 662／666 pt 之间伸缩，每次都触发一次整窗 `setFrame`（原因 `detailSize`）。
- 修前基线（`p2b-modules`，每页打开 16–24 次）中，原因为 `detailSize` 的 `setFrame` 次数如下，这就是第一阶段 T5 方案“按页缓存高度”想省掉的那一次：
  - 磁盘 17 次／16 次打开；
  - 内存 16／16；
  - 处理器 17／24；
  - 网络 2／16；
  - 传感器、电源 0。
- 打开处理器页时，进程列表先空着（卡片 111 pt），按需快照到达、列满 5 行后长到 115 pt，这很可能就是处理器页那一次 `detailSize` 的来源；修复后卡片高度固定，预计这一次消失。磁盘、内存页的那一次来自其他异步到达的内容，与 T5 无关。
- 对比结果：修后处理器页每次打开的 `detailSize` 没有消失（48 次中 36 次，与修前相同）。它来自首次放置用的 716 pt 与实测 666 pt 不同，不是进程卡片，上面的推测被否定。静置时的 662↔666 跳动已消失（修前一轮 12 次，修后 0 次）。
- 是否还需要“按页缓存高度”：**仍有收益空间**。磁盘、内存、处理器、网络页每次打开都会多一次 7–14 ms 的整窗重排和一次位置跳动。T5 修好后处理器页高度稳定，缓存从此有效。是否做由下一批与 T4 一起评估。

### 源码契约与锁定旧行为的测试（RULES §4）

没有删断言、放宽阈值或跳过测试；下面的修改都是按已定决定改写锁定旧行为或旧写法的断言：

| 测试 | 原断言 | 现断言 | 依据 |
|---|---|---|---|
| `SystemUtilitySafetyTests.swift:1891–1894` | `memoryProbeSource.contains("timeout: 2")` | 不含 `"/usr/bin/memory_pressure"`、含 `sysctlbyname("kern.memorystatus_level"`；其他工具的期限断言不变 | D38 |
| `MiniWindowRangeSwitchTests.swift:100`、`:134`（原第 96 行 `testAHiddenPanelReleasesEveryWindow`） | 隐藏后所有窗口为空、不标更新中 | `testAHiddenPanelKeepsTheLastVisibleWindowsUntilTheNextOpeningReplacesThem`：隐藏期间不准备（版本不变）、保留上次窗口并标“更新中”、再打开先显示保留窗口再被新窗口替换；新增 `testOnlyTheLastVisibleDemandsWindowsAreKept`（最多 4 个） | D39 |
| `MenuBarPerformanceRegressionTests.swift:116–135`（`testHiddenHistoryStopsAndIdenticalDemandDoesNotRepeatPreparation`） | 末项 `displayHistory(within: 3600).isEmpty` | 隐藏期间版本不变（原断言保留）；末项改为窗口保留且等于隐藏前的窗口（不按新历史重新准备） | D39；预算未动 |
| `PanelChartNormalizationTests.swift:1674`、`GeekHoverDetailTargetTests.swift:464`、`MiniWindowConsistencyRuleTests.swift:230` | 锁定 `geekChartHistory.last`、`percentText(cpuChartHistory.last?.cpuTotal)` 的写法 | 改为 `currentReading(of: selectedDisplayedHistory)`、`percentText(cpuCurrentReading?.cpuTotal)`（原意“显示最新读数”不变，颜色等其余断言不变） | D39 |

另：第二阶段插桩曾把电源图 `tooltipHoverTracking` 里的 `content.onContinuousHover` 拆开，使 4b 的源码契约 `GeekSensorsPowerHoverDetailTests` 失败；`fefa77e` 恢复原写法、探针放在其后，该契约未改。

### 未完成与接续

**同负载对比已完成**（见“同负载对比结果”）。各修复的判定结果如下：

| 修复 | 判定标准 | 结果 |
|---|---|---|
| D39 | 打开时不再画“采样中”、隐藏时有 `history.kept`、一级图表在新窗口到来前淡化 | 达到：“采样中”48/48 → 2/30（只剩启动后首次打开）；103 次隐藏都记了保留字节 |
| D38 | 打开后内存新数据与 CPU 基本同时 | 达到：暖打开 109 → 64 ms（CPU 62 ms） |
| P2-1 | 传感器三级长档空闲时主线程与 CPU 下降；电源 28 天悬停变快 | 达到：主线程忙 45.1 → 37.2 ms/s；电源悬停 p50 4.5 → 3.2 ms |
| T5 | 处理器页静置时没有 `detailSize` 重排 | 达到：修前一轮 12 次，修后 0 次。每次打开时的那一次仍在，属按页缓存高度的范围 |
| `06877f1`＋`fbc4162` | 内存三级 28 天空闲时 `memory.processes.main` 明显下降 | 达到：11.35 → 4.27 ms/s；50–116 ms 长循环两边都没有出现（负载 3.0–3.8） |
| 回归 | 二级、切档、悬停、关闭与修前同量级 | 没有回归 |

**后续建议**（本批不做）：
- 评估按页缓存二级页实测高度（与 T4 一起）。
- 查明二级／三级计划中从电源页回到一级时那一次 CPU“—”。
- 查明 `monitor.update` 计时段修后多出的 0.2–0.4 ms/s。

**清理**（共移到废纸篓约 5 GB，未永久删除）：
- 门禁完成后：`/tmp/storage-cleaner-r2speed-build`、`~/Developer/.sc-build/r2-mini-speed/{verify,beta-dist,beta-package}`。
- 对比完成后：`p2-base.app`、`p2-post.app`、第一阶段的三个对比包、`beta-dist`／`beta-package`、`/tmp/storage-cleaner-r2speed-build`，以及本批的 Debug scratch。其他 worktree 的 scratch 仍可作离线依赖来源。
- 每次运行用过的应用副本与专用数据根，运行脚本当场已移到废纸篓。
- 保留：`~/Developer/.sc-build/r2-mini-speed/logs` 与证据目录。

### 需要主会话处理

1. （已处理）D33 措辞按 N11-2 改写、D39 补充“回收时不释放”：主会话已在 `1341a7b` 写入，实现与之一致。
2. BOARD N11：本批完成 1–4；“压缩边界极少见的峰值丢失”“不可达的简单面板代码清理”未做。
3. 后续批次：评估按页缓存二级页高度（与 T4 一起）；查明从电源页回到一级时的那一次 CPU“—”；查明 `monitor.update` 修后多出的 0.2–0.4 ms/s。
4. 实机复测（离屏测不到的部分），见第一阶段“请主会话实机复测”，另加：打开小窗时 CPU 总占用不再出现“—”、图表不再闪“采样中”；隐藏前开着的三级 28 天档再打开时先淡化显示“更新中…”再替换；处理器二级页静置时不再每隔几秒整窗跳 4 pt。

### 实际命令与结果（第二阶段）

所有 SwiftPM 命令都带 `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`、`--skip-update --disable-automatic-resolution`，未联网。

| 命令（摘要） | 结果 |
|---|---|
| `git merge integration/2.0.0-beta`（三次，未 rebase／reset） | `724b06c` 快进；`5a66619`（并入 `f5a8d45`）与 `6408da7`（并入 `5e6333e`，只有文档）自动合并，无冲突 |
| `SWIFT_BUILD_DIR=/tmp/storage-cleaner-r2speed-build DIST_DIR=…/beta-package BETA_DIST_DIR=…/beta-dist STORAGE_CLEANER_SKIP_TESTS=1 SWIFT_BUILD_JOBS=4 script/build_and_run.sh --beta`（未加 `--install`） | 修前 `6a00e28`：exit 0（7 min 10 s），build 20261005001116，`dirty=false`；修后 `5a66619`：exit 0（13 min 13 s，负载 7–11），build 20261005013634，`dirty=false`。另有两次被后续提交取代的构建（`06877f1`、`c5e1325`）由我中途停止，产物未使用 |
| 基线（`p2-baseline.sh`，修前包，App Nap 关，负载 11–85） | `p2cal-*` 4 次、`p2b-*` 11 次，全部正常结束；负载高，只用于归因（见上），不与修后比较 |
| Debug 全量：`swift test --scratch-path ~/Developer/.sc-build/r2-mini-speed/debug --jobs 4 --skip-update --disable-automatic-resolution` | `6408da7`：3411 项，跳过 21，0 失败，exit 0（4 min 58 s；开始时负载 30.8，结束时 7.0；`logs/p2-full-2.log`）。此前 `p2-full-1`（在 `06877f1` 之前）：3364 项，跳过 21，1 失败（`MacBenchmarkKernelTests` 的计时项，负载最高 85，BOARD N10），这次重跑已通过。日志中的 CoreData／通讯录 XPC 报错是环境输出，与第一阶段相同（242 行） |
| Release 小窗性能门禁：`perf-gate.sh`，按 `script/verify_menu_bar_performance.sh` 的步骤离线执行：脚本自带的源码守卫原样运行；在私有 scratch `~/Developer/.sc-build/r2-mini-speed/verify/release` 中 `swift build -c release … -Xswiftc -enable-testing --build-tests`；之后 `swift test -c release … --skip-build --filter MenuBarPerformanceRegressionTests` 跑 3 次，每次开始前等 1 分钟负载 <6（最多等 60 min，否则记为 NOT_RUN） | PASS（`6408da7`，工作区干净）：源码守卫 exit 0；Release 测试构建 exit 0（6 min 55 s，开始时负载 6.3）；等负载降到 6 以下约 20 min 后连跑 3 次，开始时负载 5.88／5.96／5.89，每次 16 项 0 失败，exit 0；`preparation_p95_ms` 79.98／75.84／73.69（预算 100），`cached_delivery_p95_ms` 0.0025／0.0016／0.0019（`logs/p2-perf-gate.log`）。第一阶段同一门禁（`49b81bc`，负载 5.7–6.2）为 72.13／72.12／79.27 |
| `python3 script/check_private_api.py` | 通过：“private API check passed (6 allowlisted uses)”（`logs/p2-private-api.log`） |
| `git diff --check`（工作区；`724b06c..256fe00`；`724b06c..HEAD`） | 全部 exit 0 |
| JEV `jev_verify`（4 条归因与校准结论） | 见“未归因卡顿的归因”后的表 |
| 修后包重新打包：`SWIFT_BUILD_DIR=/tmp/storage-cleaner-r2speed-build … SWIFT_BUILD_JOBS=3 script/build_and_run.sh --beta`（未加 `--install`；先把依赖缓存从 Debug scratch 复制进构建目录，离线） | `b0d1cad`：exit 0（4 min 12 s），build 20261006115815，`dirty=false` |
| 同负载对比：`QUIET_MINUTES=… p2-ab.sh r1 kept cal`，之后 `p2-ab.sh r2 cal2 r3`（中途为延长负载等待而重启一次，无运行进行中） | 52 次运行全部 exit 0。1 次 NOT_RUN（`p2cal2-nap-2` 第一次尝试，之后在 `cal2` 补跑）；3 次到 25 min 运行时限。时间与负载见“每轮时间与负载” |
| 出表：`p2-report.sh`（`compare.py`、`p2_tables.py`、`steady.py`、`stall_attr.py`、`runs_table.py`） | `compare-p2-*.md`（证据目录） |

## 第一阶段：测量与定位、三处修复（2026-10-04～05）

> 第一阶段之后的变化：待决定中的 D-1、T2 已成为 DECISIONS D38、D39，并在第二阶段实施；T5 的根因（处理器页高度跳动）已在第二阶段修复，“按页缓存高度”是否还需要待修后对比再定；R5 中“`base3` 未归因的长循环”已归因到内存进程列表的主线程读取（`06877f1`）。以下为第一阶段原文。

- 实现：Claude 子代理（Opus 5.5）。复核：尚未安排。
- 用户原话：“另外我希望提高小窗模式的反应速度”。本阶段只做两件事：用数字说明慢在哪里、慢多少、为什么；只实施“行为不变的明确性能修复”。涉及内存、交互时序、动画、默认刷新、常驻面板、预热的改动只写方案与数据（见“待决定”）。
- 分支：`task/r2-mini-speed`，基于 `task/batch4b-mini-logic`。按主会话两次通知并入 4b：`6fa1767`（并入到 `d9e49ca`，含 `a83401a` 延后调用重放队列、`a42081d` D28）；`29060de`（并入到 `ed69c25`，含 `f3f96a9`、`b34478c`、`6448502`、`e111e5e`；冲突在 `MenuBarPreparedChart.swift`、`MenuBarGeekCharts.swift`，4b 的 `GeekHistoryPreviousFrameKey` 偏好与本批的探针修饰都保留）。已核对上述提交都是 `29060de` 的祖先。未合并到集成分支、未 push、未打 tag、未安装、未碰 `/Applications`、未启动或退出已安装的测试版／正式版、未写风扇／充电／电源。
- 提交（按顺序）：
  - `2d37041` 插桩与离屏延迟驱动（只在 Debug／测试版编译，且只在带 `--menu-bar-performance-audit=` 时生效）
  - `6fa1767` 并入 4b（`d9e49ca`）
  - `6847248` 插桩补充：打开后图表“采样中”占位与 CPU 总占用“—”是否出现
  - `c9c1abc` 插桩补充：`commit_ack`（改动所在的那次主运行循环结束）、打开路径分段计时
  - `08c5e13` 修复 1：一级卡片的身份不随打开的二级页变化
  - `9a7fb7c` 修复 2：一级卡片被重建、锚点暂缺时，二级页沿用该页上次对齐的偏移
  - `b727d17` 修复 3：从二级页打开的三级页随数据重绘
  - `29060de` 并入 4b（`ed69c25`）
  - `49b81bc` 修复 3 补充：三级页的图表沿用根视图的准备键（测得修复 3 的副作用后补上，见“修复与效果”）
  - 本交接单独一个提交（仅文档）
- **修前基线与修后对应的提交**（两边插桩相同、4b 改动相同，只差三处修复）：
  - 修前基线：在 `29060de` 的工作区反向套用三处修复的源码部分（`08c5e13`、`9a7fb7c`、`b727d17` 的 `Sources/` 改动，补丁见证据目录 `fixes123-sources.patch`）后打包，build `20261004131706`（构建时工作区 dirty，打包后已恢复，`git status` 干净）。
  - 修后：`29060de`（干净工作区），build `20261004131104`。第 1–11 项的“修后”都是这个包。
  - 修后补充：`49b81bc`（`29060de`＋三级图表准备键），build `20261004145948`。只影响三级页，所以只对三级打开、切档、三级空闲重测（第 4、5、11 项中标“补充”的数字）。
  - 定位根因时的早期基线：`6847248`（4b 到 `d9e49ca`，无修复），build `20261004120351`，运行 `base2`、`base3`。
- 改动范围：`Support/MenuBarPresentationTrace.swift`、`Support/MenuBarLatencyScript.swift`（新）、`Support/MenuBarStatusController.swift`、`Support/MenuBarPanelSession.swift`、`App/StorageCleanerMacApp.swift`、`Views/MenuBarAdvancedStatusView.swift`、`Views/MenuBarPanelSettingsView.swift`、`Views/PanelChartSampling.swift`、`Views/MenuBarAdvanced/{MenuBarLiveCard,MenuBarGeekPanel,MenuBarTertiaryDetail,MenuBarPreparedChart,MenuBarGeekCharts,GeekOverviewPresentation,GeekMemoryView}.swift`、`docs/MENUBAR_PERFORMANCE.md`、新测试 3 个文件。插桩之外的产品代码改动只有三处修复与修复 3 的补充（`Sources/` 共新增 94 行、删除 31 行，含注释）。没有改 `Stores/ScanStore.swift`、`DECISIONS.md`、`BOARD.md`，没有碰其他 worktree 和主仓库。
- 证据目录：`~/Developer/StorageCleanerMac-evidence/round2/mini-speed/`（每次运行一个子目录：`audit.jsonl` 原始记录、`summary.txt`、`transitions.txt`、`ps.log`、`footprint-*.txt`；脚本 `run-latency.sh`、`analyze.py`、`compare.py`、`steady.py`、`l3idle.py`、`sample_tree.py`、`ab-*.sh`、`perf-gate.sh`；对比表 `compare-*.md`）。日志：`~/Developer/.sc-build/r2-mini-speed/logs/`。审计记录只有数值、阶段名和源码位置，不含进程名、路径、网址。

### 结论

修前最慢的三处（数字均为离屏驱动实测，口径见“方法”）：

1. **三级历史切换时间档后，新数据迟迟不画（最严重，已修）。** 旧数据 13 ms 内淡化并显示“更新中…”，但新窗口要等一次无关的根视图刷新才画出：负载 <4 时，处理器页未预备的档 p50 1.6–5.6 s、p95 7.2–9.2 s；内存页 1 分／1 天／7 天／28 天共 28 次全部超过 10 s 未画（其中一次 28 天档 40 s 后才画）。原因是从二级页打开的三级页由不观察监视器的根视图构建、也不在 `liveCard` 里。修复 3 后各档绘制 p50 16–52 ms、p95 ≤ 75 ms，处理器页 49 次、内存页 48 次切换无一超时。修复 3 让三级图表的准备键随卡片版本变化，带来一点尾部延迟和空闲开销；补充提交 `49b81bc` 后尾部延迟回落（同负载 2 轮），空闲开销呈下降趋势（只测 1 轮，见第 4、11 项）。
2. **进入／切换二级页：一次 50–80 ms 的主运行循环里做 3–4 次同步整窗布局（部分已修）。** 一级卡片的身份含当前打开的页，换页就重建全部一级卡片；被重建的卡片先移除锚点再登记，各触发一次 `setFrame(display: true)`，二级页中途还会错位一帧。修复 1、2 后（同负载 A/B），二级页之间切换：首次绘制 p50 49→32 ms、p95 59→46 ms，该次循环结束 p50 61→39 ms，`setFrame` 每次 2–4 次→0–2 次，二级段 >50 ms 的循环 210→132 次。从一级进入二级基本不变（绘制 p50 49→47 ms、循环结束 63→61 ms），剩下的原因是一级列换外层容器（T3）和二级页实测高度引起的再排（T5）。
3. **打开面板：首帧快，但同一运行循环继续 40 ms；CPU 总占用先显示“—”、图表先画“采样中”；内存新数据晚 ~50 ms（未改，需决定）。** 首帧 p50 暖 17–20 ms、冷 32–38 ms，但该次循环到暖 ~60 ms／冷 ~71–76 ms 才结束；一级 CPU 总占用在每次首帧里都是“—”，CPU 图表暖 ~58 ms／冷 ~70 ms 先画“采样中”，打开后的新采样暖 ~59 ms／冷 ~72 ms 才画出，内存新采样暖 ~110 ms。原因是隐藏时释放全部已准备的历史窗口（4b 锁定）、每次内存采样起一个 `memory_pressure -Q` 子进程（~60 ms）、冷打开重建面板（`open.build` 16–19 ms）。三处修复不涉及打开路径，A/B 中修前修后相同。方案见 D-1、T1、T2。

其他各项都在预算内（修后）：图表悬停每次移动 p50 3 ms、p95 6 ms、max 13 ms（目标 16 ms）；进程勾选 12 ms；关闭（Esc／外部点击）3 ms；三级页打开 26 ms、图表有数据 37 ms；回到一级 35 ms。

### 方法与环境

- 机器：Mac17,9（Apple M5 Pro，18 核，48 GB），macOS 27.2，内建屏 3024×1964 Retina；工具链 `Xcode-27.0.0-Beta`。
- 构建：`script/build_and_run.sh --beta`（Release，`-D STORAGE_CLEANER_BETA`），未加 `--install`，没有用 `run/--verify/--logs/--telemetry/--debug`。
- 运行：把打包产物复制到证据目录，改为隔离身份 `com.local.StorageCleanerMac.integration` 并临时签名，`STORAGE_CLEANER_INTEGRATION_ROOT` 指向本次专用目录；监控历史用测试版数值历史文件的只读副本（只写副本），让长档位准备真实数据量；`-ApplePersistenceIgnoreState YES`。同一身份一次只运行一个实例，结束时 `kill -TERM` 自己启动的进程。
- 驱动（`--menu-bar-latency-script=<计划>`，`MenuBarLatencyScript`）：应用设为附属（不出现在 Dock、不激活、不抢焦点），主窗口隐藏；面板放在所有屏幕左侧之外的虚拟显示区（与主屏同尺寸），只 `orderFrontRegardless`、不成为关键窗口；不向系统发送鼠标键盘事件，脚本运行时忽略外部点击。打开、二级、三级、切档、回到一级用与点击相同的入口（`MenuBarStatusController`、`GeekPanelCoordinator`、`setGeekChartRange`）；Esc 走会话的 `handleKeyEvent`，外部点击走 `handleMouseDown`；悬停把位置送进与 `onContinuousHover` 相同的状态（SwiftUI 的悬停只认真实指针，指针进不了离屏面板）。
- 计时（`MenuBarPresentationTrace`，全部单调时钟）：
  - 绘制回执：交互开始到受影响视图里 1×1 探针被 AppKit 绘制。
  - 提交回执：同一次主运行循环结束（Core Animation 在此提交；实屏还要加合成与显示 1–2 帧，120 Hz 约 8–17 ms，离屏测不到）。
  - 主线程：运行循环观察者记录每次唤醒到休眠的时长，超过 50 ms 记 `main_stall`（带当时的交互）；每 10 s 记 `main_busy`。
  - 同步段：`open.build`、`open.sync`、`show.*`、`hide.*`、`teardown`、`setFrame`（带触发原因：`section`／`detailSize`／`anchor`／`anchorRemoved`／`tertiary`／`windowMove`／`deferred`）。
  - 新鲜度：`fresh.<域>` 为打开后第一次画出打开之后的采样；`cpu.placeholder`、`chart.placeholder.overview` 为首帧里出现的“—”与“采样中”。
- 冷／暖：暖＝隐藏 1 s 后再打开（面板保留）；冷＝走与 5 分钟回收相同的隐藏＋拆除后 2 s 再打开；首次＝启动后第一次。
- 次数：打开暖 21、冷 20；二级每页自一级 40–63、自其他二级 20；三级每页 20–22；切档每档 8（修前未画出的计为超时）；悬停 596 次移动；进程勾选 40；稳态每相位 45–60 s。统计取最近秩 p50／p95／max。
- 负载：机器同时有其他会话编译和同步，1 分钟负载大多高于 4。`base3` 全程 <4（2.5–4.0）；`base2` 120 次标记中 25 次 <4，根因数字取这一子集；修前基线全量运行 `pre` 负载 p50 9.0（3.6–24.7），修后 `post` p50 13.8（9.4–24.0）。因为两次全量运行负载不同，又做了**同负载交替 A/B**（修前、修后两个包轮流跑同一计划）：二级／三级 3 轮、打开 2 轮、切档 2 轮、稳态 2 轮；修复 3 补充对修后：三级打开与切档 2 轮、三级空闲各 1 轮（三种包）。每次运行记录 `vm.loadavg`。
- 插桩开销：审计写盘在主线程，`sample` 中占主线程忙碌样本约 1%；修前、修后两个包相同。

### 各项结果（修前 → 修后）

全量运行 `pre`（修前基线）对 `post`（修后），单位 ms，格式 n / p50 / p95 / max。完整表：证据目录 `compare-pre-post.md`；同负载 A/B：`compare-ab-*.md`。

#### 1–2　打开与打开后的新数据

| 项目 | 全量 修前 | 全量 修后 | A/B 修前（2 轮，负载 4.2–5.4） | A/B 修后 |
|---|---|---|---|---|
| 暖打开·首帧（绘制） | 21 / 17 / 45 / 48 | 21 / 20 / 22 / 49 | 24 / 19 / 48 / 49 | 24 / 20 / 48 / 48 |
| 暖打开·该次循环结束 | 21 / 58 / 62 / 63 | 21 / 62 / 65 / 66 | 24 / 60 / 62 / 63 | 24 / 59 / 65 / 65 |
| 冷打开·首帧 | 20 / 35 / 64 / 65 | 20 / 38 / 67 / 68 | 22 / 33 / 63 / 63 | 22 / 32 / 61 / 66 |
| 冷打开·该次循环结束 | 20 / 76 / 79 / 81 | 20 / 75 / 79 / 80 | 22 / 71 / 78 / 80 | 22 / 71 / 76 / 79 |
| 启动后首次·首帧 | 1 / 82 | 1 / 96 | 2 / 72 / 76 / 76 | 2 / 71 / 73 / 73 |
| `open.build`（冷，新建面板与宿主） | 21 / 16 / 18 / 50 | 21 / 19 / 20 / 62 | 24 / 17 / 51 / 52 | 24 / 17 / 50 / 53 |
| `open.sync` 暖／冷（p50） | 7.5／27 | 11／29 | 10／27 | 11／26 |
| 首帧里一级 CPU 总占用为“—” | 暖 21/21、冷 20/20 次 | 暖 21/21、冷 20/20 次 | 每次 | 每次 |
| CPU 图表先画“采样中” 暖／冷 | 20 / 58 / 60 / 62；20 / 73 / 78 / 80 | 21 / 60 / 63 / 64；20 / 74 / 82 / 84 | 24 / 58；22 / 69（p50） | 24 / 57；22 / 69 |
| 打开后 CPU 新采样画出 暖／冷 | 21 / 59 / 63 / 63；20 / 74 / 79 / 81 | 21 / 60 / 64 / 64；20 / 76 / 83 / 85 | 24 / 59；22 / 73 | 24 / 58；22 / 71 |
| 一级 CPU 图表有数据 暖／冷 | 21 / 66 / 71 / 71；20 / 82 / 88 / 89 | 21 / 67 / 75 / 75；20 / 83 / 89 / 90 | 24 / 66；22 / 80 | 24 / 66；22 / 79 |
| 打开后内存新采样画出 暖／冷 | 21 / 111 / 117 / 118；20 / 128 / 1108 / 1111 | 21 / 110 / 121 / 125；20 / 125 / 1104 / 1117 | 24 / 115；22 / 129 / 1101 | 24 / 113；22 / 126 / 131 |

打开路径没有被三处修复改动，A/B 中修前修后一致；全量运行的差别来自负载（修后那次负载更高）。冷打开时内存新数据有 10–15% 的次数要等下一次定时采样（约 1.1 s）。

#### 3、6　进入二级、二级之间切换（同负载 A/B，3 轮，负载 p50 12.6；p50 / p95 ms）

| 页 | 自一级 修前 → 修后 | 自其他二级 修前 → 修后 |
|---|---|---|
| 磁盘 | 46 / 62 → 44 / 61 | 50 / 57 → 32 / 59 |
| 内存 | 52 / 60 → 50 / 60 | 55 / 59 → 40 / 49 |
| 网络 | 45 / 53 → 44 / 52 | 46 / 48 → 29 / 33 |
| 电源 | 45 / 49 → 42 / 50 | 48 / 57 → 31 / 39 |
| 处理器 | 52 / 62 → 50 / 59 | 53 / 68 → 37 / 46 |
| 传感器 | 49 / 57 → 47 / 53 | 45 / 54 → 25 / 27 |
| 合计·首次绘制（n / p50 / p95 / max） | 156 / 49 / 60 / 68 → 156 / 47 / 59 / 61 | 72 / 49 / 59 / 68 → 72 / 32 / 46 / 59 |
| 合计·该次循环结束 | 156 / 63 / 80 / 90 → 156 / 61 / 77 / 84 | 72 / 61 / 71 / 76 → 72 / 39 / 57 / 69 |
| 每次 `setFrame` 次数（原因） | 2–4（section、anchorRemoved、anchor、detailSize）→ 1–2（section、detailSize） | 2–4 → 0–2 |
| 级联最后一次放置完成（p50） | 50–61 → 31–57 | 52–64 → 0–44 |
| >50 ms 的主线程循环（二级段合计） | 210 次 → 132 次（p50 60 → 61 ms） | 同左 |

全量运行（负载不同）：自一级 265 / 48 / 59 / 68 → 265 / 49 / 60 / 70；自其他二级 120 / 49 / 63 / 80 → 120 / 33 / 45 / 57；回到一级 265 / 33 / 38 / 115 → 265 / 35 / 40 / 47。

#### 4　从二级打开三级与图表

| 项目 | 全量 修前 → 修后 | A/B 修前 → 修后（3 轮） |
|---|---|---|
| 三级首次绘制 | 123 / 25 / 32 / 47 → 123 / 26 / 34 / 39 | 72 / 26 / 34 / 41 → 72 / 26 / 35 / 41；补充：修后 52 / 24 / 35 / 40 → 补充 52 / 25 / 35 / 37 |
| 三级图表有数据 | 103 / 35 / 41 / 55 → 103 / 37 / 50 / 63 | 60 / 37 / 43 / 48 → 60 / 36 / 50 / 67；补充：修后 44 / 35 / 47 / 47 → 补充 44 / 35 / 43 / 44 |
| `setFrame`（原因 tertiary） | 每次 2–3 | 每次 2–3 |

三级图表有数据的 p50 不变，p95／max 修后高 7–19 ms（两组数据都如此；A/B 中每页 12 次里各有 1 次较慢）。代码上的原因：修复 3 后三级内容在卡片里，图表准备键带卡片版本；三级卡片跟随的读数多，版本约每秒变 4 次，准备途中键一变，`MenuBarPreparedChartModel` 就丢弃快要交付的帧、按新键重做。修复 3 补充（`49b81bc`）让三级图表沿用根视图的准备键后，同负载 2 轮 p95 47 → 43 ms、max 47 → 44 ms（p50 不变）。

#### 5　三级切换时间档

新数据画出 = 切档到该档图表第一次画出所选档的预处理帧。修前没在 10 s 内画出的计为超时（脚本先等淡化 2 s、再等新数据 10 s）。

| 档 | 全量 修前 | 全量 修后 | A/B 修前（2 轮，负载 3.0–5.0） | A/B 修后 |
|---|---|---|---|---|
| 处理器 1 分（未预备） | 2 / 4756 / 7319 / 7319＋超时 6 | 8 / 28 / 35 / 35 | — | — |
| 处理器 15 分（未预备） | 2 / 1592 / 3599 / 3599＋超时 6 | 9 / 29 / 34 / 34 | 1 / 6160＋超时 5 | 8 / 29 / 36 / 36 |
| 处理器 1 天（未预备） | 1 / 304＋超时 7 | 8 / 29 / 45 / 45 | 0＋超时 8 | 8 / 27 / 29 / 29 |
| 处理器 7 天（未预备） | 3 / 4812 / 7802 / 7802＋超时 5 | 8 / 30 / 31 / 31 | — | — |
| 处理器 28 天（未预备） | 2 / 3585 / 3589 / 3589＋超时 6 | 8 / 52 / 75 / 75 | — | — |
| 内存 1 分（未预备） | 0＋超时 8 | 8 / 32 / 74 / 74 | — | — |
| 内存 1 天（未预备） | 0＋超时 8 | 8 / 26 / 31 / 31 | 0＋超时 8 | 8 / 26 / 30 / 30 |
| 内存 7 天（未预备） | 0＋超时 8 | 8 / 26 / 40 / 40 | — | — |
| 内存 28 天（未预备） | 0＋超时 8 | 8 / 34 / 42 / 42 | — | — |
| 处理器 1 时（一级卡片已预备） | 8 / 18 / 28 / 28 | 8 / 20 / 34 / 34 | 8 / 19 / 26 / 26 | 8 / 19 / 29 / 29 |
| 内存 1 时（已预备） | 8 / 19 / 23 / 23 | 8 / 16 / 21 / 21 | 8 / 16 / 25 / 25 | 8 / 18 / 38 / 38 |
| 内存 15 分（已预备） | 8 / 18 / 22 / 22 | 8 / 27 / 37 / 37 | 8 / 18 / 28 / 28 | 8 / 24 / 27 / 27 |
| 旧数据淡化（“更新中…”） | 50 / 13 / 18 / 19 | 70 / 14 / 17 / 19 | 24 / 13 / 15 / 15 | 25 / 14 / 15 / 15 |

已预备档（不需要后台准备）本来就快；内存 15 分档修后 p50 高 6–9 ms（上面两组数据都如此），推测原因同第 4 项：三级卡片版本进入了图表准备键。修复 3 补充（`49b81bc`）与修后（`29060de`）同负载轮流 2 轮（负载 4.4–5.6）：未预备档 内存 1 天 25 / 36 → 25 / 30、处理器 15 分 28 / 40 → 29 / 36、处理器 1 天 27 / 31 → 24 / 30；已预备档 内存 15 分 19 / 26 → 16 / 24、内存 1 时 15 / 41 → 15 / 20、处理器 1 时 20 / 34 → 22 / 28（p50 / p95，各 8 次；`compare-ab-fix3b.md`）。这一轮修后本身的内存 15 分档 p50 只有 19 ms，没有复现前两组的 6–9 ms 差，所以补充对切档的作用只能说 p95 略降、p50 不变。

#### 7　进程列表

| 项目 | 修前 | 修后 |
|---|---|---|
| 内存页勾选进程后重绘 | 40 / 11 / 15 / 16 | 40 / 12 / 14 / 32 |
| 内存页进程列表刷新（数据发布→绘制） | 309 / 6.7 / 11.8 / 15.8 | 132 / 8.0 / 13.4 / 32.1 |
| 处理器页能耗进程刷新（数据发布→绘制） | 215 / 3.4 / 9.5 / 20.6 | 50 / 4.1 / 11.2 / 21.6 |

小窗的进程列表没有排序控件（按数值排序），排序一项不适用。

#### 8　图表悬停（每次移动到重绘；目标 16 ms）

修前 596 / 4 / 6 / 10，修后 596 / 3 / 6 / 13（该次循环结束 4 / 7 / 23 → 4 / 7 / 24）。负载 <4 的 `base3`：596 / 2.3 / 5.1 / 10.5。

#### 9　关闭

`hide.total`：Esc 修前 22 / 1.9 / 4.4 / 5.1，修后 22 / 3.2 / 4.0 / 4.4；外部点击 20 / 1.8 / 2.0 / 2.5 → 20 / 3.0 / 4.5 / 4.8（A/B：Esc 3.1 → 3.0、外部 2.8 → 2.9 ms p50）。其中 `orderOut` 0.3–0.5 ms。

#### 10　主线程 >50 ms 的运行循环（次数 / p50 / p95 / max ms）

| 阶段 | 全量 修前 | 全量 修后 | A/B 修前 | A/B 修后 |
|---|---|---|---|---|
| 二级打开／切换 | 327 / 60 / 78 / 99 | 262 / 62 / 85 / 503 | 210 / 60 / 76 / 91 | 132 / 61 / 78 / 88 |
| 打开 | 35 / 61 / 79 / 81 | 42 / 62 / 79 / 82 | 42 / 61 / 78 / 99 | 43 / 62 / 79 / 100 |
| 回到一级 | 10 / 52 / 105 / 105 | 2 / 54 / 54 / 54 | 1 / 52 | 2 / 50 / 51 / 51 |
| 三级打开 | 1 / 52 | 0 | 0 | 0 |

归因见 R2（二级）与 R3（打开）。修后全量运行中有一次 503 ms（处理器页切入后 550 ms、页面已画完，负载约 11），之前没有任何记录，3 轮修后 A/B 中没有再出现，未归因。

#### 11　稳态（同负载 A/B，2 轮；CPU 为累计 CPU 时间差÷墙钟）

负载 2.5–3.8（全部 <4）；每相位 60 s，去掉前 6 s 的过渡，取约 52 s。

| 相位 | 修前（2 轮） | 修后（2 轮） |
|---|---|---|
| 一级可见（只有概览） | CPU 4.04／3.98%；主线程 23.1／21.4 ms/s（p95 35／33） | CPU 4.10／3.96%；主线程 22.9／21.8 ms/s（p95 36／32） |
| 二级处理器页可见 | CPU 6.61／6.63%；主线程 31.8／31.6 ms/s | CPU 6.42／6.60%；主线程 31.7／32.2 ms/s |
| 隐藏未回收（暖） | CPU 0.83／1.25%；主线程 1.8／2.6 ms/s | CPU 0.94／0.98%；主线程 2.0／2.1 ms/s |
| 已回收（冷） | CPU 0.71／0.71%；主线程 0.4／0.4 ms/s | CPU 0.80／0.79%；主线程 0.6／0.4 ms/s |
| footprint（每相位 20 s 时一次） | 129–215 MB | 105–225 MB |

修复不影响稳态（这些相位不切页、不开三级）。面板可见时整个进程约 4%（概览）／6.5%（处理器页）一个核，其中主线程 2.2–3.2%；隐藏后约 0.8–1%（后台采样与历史记录）。隐藏未回收比已回收多约 0.1–0.5% CPU、1.5–2 ms/s 主线程（T1 的持续代价）。footprint 同一相位两轮相差可达 60 MB，不能用来比较。

三级页打开并空闲时的代价见下（`ab-l3idle`，一轮，修前／修后／修后补充三种包轮流）：

| 三级页（保持 140 s） | 修前（页面冻结，不随数据重绘） | 修后 `29060de` | 修后补充 `49b81bc` |
|---|---|---|---|
| 内存历史：CPU | 6.01% | 7.11% | 6.68% |
| 内存历史：主线程 ms/s（p50 / p95） | 37.3 / 39.4 | 46.3 / 49.0 | 44.7 / 47.1 |
| 处理器历史：CPU | 6.54% | 7.54% | 6.85% |
| 处理器历史：主线程 ms/s（p50 / p95） | 32.9 / 34.9 | 41.0 / 45.5 | 34.2 / 36.8 |
| 三级卡片重绘 次/s（其中不与其他卡片同一次绘制） | 0 | 4.1（0.3–0.4） | 4.1（0.4–0.5） |
| >50 ms 的主线程循环 | 0 | 0 | 0 |

负载 3.8–5.8（`compare-ab-l3idle.md`）。修前数字低，是因为三级页根本不随数据重绘（本批修的问题），不是可以保留的状态。修复 3 让三级页打开时多用约 1% CPU、8–9 ms/s 主线程；补充之后处理器页多 0.3% CPU、1.3 ms/s，内存页多 0.7% CPU、7.4 ms/s。这组数字每种包只有 1 轮，只能说明补充后空闲开销下降的趋势，不能作为降幅的定量结论（第二阶段复核意见；未补跑到 3 轮）。剩下的是三级页本身每秒约 4 次重绘（指纹含 7 个数据源的时间，见 T6）。

### 根因（按对使用者的影响排序）

行号为本分支最终源码 `49b81bc`；修前位置另注。

#### R1　三级历史切档：新数据要等一次“无关”的根视图刷新才画（已修，`b727d17`）

- 现象（修前，负载 <4 子集）：切到未预备的档后旧数据 9–13 ms 内淡化，新窗口 p50 1.6–5.6 s、p95 7.2–9.2 s 才画（处理器页，`base2`）；内存页 28 次全部 >10 s（`base3`）。已被其他卡片预备的 1 小时档 16 ms 画出。修前全量运行 `pre`：处理器页 40 次切到未预备档中 30 次超过 10 s 未画、画出的 10 次也要 0.3–7.8 s；内存页 32 次全部超时，其中 1 分、7 天、28 天档 24 次中 23 次连“更新中”淡化也没在 2 s 内画出。
- 证据：每一次迟到的绘制都紧跟一次 `setFrame`（原因 `detailSize`，二级页内容高度变化引起的重排，会让根视图重算），11/11 次在其后 0–15 ms 内。
- 代码：三级页由根视图 body 构建（`MenuBarTertiaryDetail.swift:146` `tertiaryDetailSurface`），根视图不观察监视器（`MenuBarAdvancedStatusView.swift:73` `let monitorState`，不是 `@ObservedObject`），三级页也不在 `liveCard` 里；监视器在后台几毫秒就交付新窗口（`ScanStore.swift` `MenuBarMonitorState` → `objectWillChange`），只有卡片会重绘。同理，从二级页打开的三级历史平时也不随新采样前进。
- 修复：三级页内容包进 `liveCard(.levelThree)`（`MenuBarTertiaryDetail.swift:155`；新卡片域的指纹含各类采样时间，历史版本标签同时含遥测与内存两个已准备窗口的版本，`MenuBarLiveCard.swift:211`、`:245`）。“更新中”的淡化与新窗口交付后显示新数据都是 4b 设计文档已有的行为，修复只是让它按时发生。
- 代价：三级页打开时，它像其他卡片一样随读数重绘，约 4 次／s，其中约 90% 与同页其他卡片在同一次绘制中。修复 3 起初还让三级图表的准备键随卡片版本变化，每次重绘都重新准备历史帧，并会丢弃快要交付的帧；补充提交 `49b81bc` 改回根视图的准备键。空闲代价（第 11 项，各 1 轮，趋势）：处理器历史 +1.0% CPU、+8 ms/s 主线程 → 补充后 +0.3%、+1.3 ms/s；内存历史 +1.1%、+9 ms/s → +0.7%、+7.4 ms/s。

#### R2　进入／切换二级页：一次运行循环 50–80 ms，期间 3–4 次整窗同步布局（主要部分已修，`08c5e13`、`9a7fb7c`）

- 现象（修前）：二级页首次绘制 p50 48–49 ms、p95 59–63 ms，该次运行循环在 61–62 ms（p95 78–80 ms）才结束；绘制前主线程一直在同一次循环里（主线程忙≈耗时）。打开或切换二级页几乎每次都有一次 >50 ms 的循环（`pre` 327 次，p50 60 ms，p95 78 ms）。
- 每次打开 `setFrame(display: true)` 2–4 次、合计 15–29 ms，顺序为 `section` → `anchorRemoved` → `anchor`（处理器页另有 `detailSize`）。`base2` 全部 1728 次 `setFrame` 中 `anchor`＋`anchorRemoved` 700 次（40%），单次 p50 7.6 ms、p95 13.9 ms。`sample`（1 ms）在二级切换段的主线程忙碌样本中：`MenuBarPanelSession.resolveCascade` 21%、`applyProgrammaticFrame` 21%（其下是 `NSWindow` 整窗约束布局与 Core Animation 提交）、`setGeekPanelSection` 11%、`registeredAnchorDidChange` 9%、`registerAnchor` 5%、`SmallWindowAnchorRegistry.remove` 4%。
- 代码：
  - 一级卡片身份含当前打开的页：修前 `MenuBarLiveCard.swift:137` `MenuBarCardIdentity.key(page: selectedSection.rawValue, …)`；调用点 `MenuBarGeekPanel.swift:189`、`MenuBarAdvancedStatusView.swift:1327`。切换二级页即重建六张一级卡片（新卡片模型、5 个订阅、图表重新准备）。
  - 被重建的卡片 `onDisappear` 移除锚点（`GeekPanelComponents.swift:1078`、`:1147` → `SmallWindowInteraction.swift:108` `remove`），会话立刻重排（`MenuBarPanelSession.swift:1364` `registeredAnchorDidChange`），此时没有锚点，用默认偏移（`:940` `GeekPanelPresentationMetrics.detailVerticalOffset`），二级页错位一帧；新卡片一回合后登记同一偏移，再排回来。
  - 每次重排都是同步整窗布局：`MenuBarPanelSession.swift:1426` `panel.setFrame(alignedFrame, display: true)`。
- 修复：一级卡片固定用 `MenuBarCardIdentity.overviewPage`（`MenuBarLiveCard.swift:41`；二级页之间切换不再重建一级列）；会话按页记住上次有锚点时的卡片偏移，锚点暂缺时沿用（`MenuBarPanelSession.swift:502`、`:936–940`；`show`、换密度、概览尺寸变化时清空）。锚点移除与重新登记算出同一框，不再 `setFrame`。
- 未修部分：从概览进入二级页时一级列换外层容器（`MenuBarAdvancedStatusView.swift:753` `panelSurface` 的 `PanelShell` ↔ `GeekAttachedPanelShell`），一级卡片仍整体重建（T3）；二级页实测高度在首次布局后变化引起的 `detailSize` 重排（磁盘、内存、处理器页每次多一次，T5）；`display: true` 本身（T4）。

#### R3　打开面板：首帧后同一循环继续；CPU“—”与图表“采样中”（未改，需决定）

- 现象（修前）：首帧暖 p50 17 ms／冷 35 ms，同一运行循环到 58／76 ms 才结束（打开时 `main_stall` p50 ~60 ms）。首帧里一级 CPU 总占用显示“—”（`cpu.placeholder` 与首帧同时）；CPU 图表在暖 58 ms／冷 73 ms 先画“采样中”，暖 66 ms／冷 82 ms 图表才有数据；打开后的 CPU 新采样暖 59 ms／冷 74 ms 画出。
- 代码：隐藏时根视图撤销历史需求（`MenuBarAdvancedStatusView.swift:662` `updateDisplayHistoryConsumer(historyDemandID, durations: [])`），监视器在需求为空时释放全部已准备窗口（`ScanStore.swift:526–530`）；再打开时要在后台重新准备。一级 CPU 总占用读的是已准备历史的最后一点（`GeekOverviewPresentation.swift:23` `cpuChartHistory.last?.cpuTotal`），窗口没准备好时显示“—”。4b 的测试锁定“隐藏即释放”（`MiniWindowRangeSwitchTests.testAHiddenPanelReleasesEveryWindow`、`MenuBarPerformanceRegressionTests.testHiddenHistoryStopsAndIdenticalDemandDoesNotRepeatPreparation`），改它属于决定（T2）。
- 冷打开（隐藏超过 5 分钟被回收，`MenuBarStatusController.swift:412` `schedulePanelReclamation`，`MenuBarPerformancePolicy.cachedWindowLifetime = 300 s`）比暖打开首帧多 12–18 ms（同负载 A/B 为 12 ms）：`open.build`（新建面板、宿主、协调器）p50 16–19 ms，`open.sync` 冷 26–29 ms 对暖 8–11 ms（T1）。
- 冷打开 20 次中有 2–3 次内存新数据要等下一次定时采样（~1.1 s）。

#### R4　内存新数据比 CPU 晚约 50 ms：每次内存采样起一个 `memory_pressure -Q` 子进程，~60 ms（补丁已备，待决定 D-1）

- 证据：`SystemMemoryProbe.shared.snapshot(includeProcesses: false)` 40 次：子进程版 p50 60.4 ms、p95 64.3 ms；改读 `kern.memorystatus_level` 后 p50 0.013 ms、p95 0.014 ms。`memory_pressure -Q` 印出的 “System-wide memory free percentage” 就是这个内核值（本机 68 对 68）。60 ms 主要是 `Shell.run` 等待进程组退出的轮询（`Shell.swift:375`、`:406` `waitForExit(timeout: 0.05)`），不是工具本身（直接起进程约 2 ms）。打开时 `fresh.memory` 比 `fresh.cpu` 晚约 50 ms（暖 111 对 59 ms）。
- 代码：`Features/Memory/Infrastructure/SystemMemoryProbe.swift:361`；所有调用方都走带压力读数的路径（`includePressureReading: false` 没有调用方）。
- 阻碍：`SystemUtilitySafetyTests.swift:1891` 源码契约 `XCTAssertTrue(memoryProbeSource.contains("timeout: 2"))`（锁定“阻塞调用要有期限”的实现细节）。按 RULES §4 改源码契约需要 DECISIONS 条目，所以本批没有提交，补丁与测试在证据目录。

#### R5　其他观察（未改）

- 内存进程列表刷新时，`SystemMemoryProbe.processes` 用 `MainActor.run` 在主线程读取所有运行中应用的 `NSRunningApplication` 属性（`SystemMemoryProbe.swift:395`）。`sample` 中占主线程忙碌样本约 1%（二级切换段 56 ms／27 s），单次不构成 >50 ms 阻塞。
- 处理器二级页内容高度在 662↔666 pt 之间来回，约每 9 s 触发一次 `detailSize` 整窗重排（~7 ms）。
- 卡片常在一次采样后连画两次（数据一次、后台准备好的图表帧一次，间隔 <50 ms），一级 CPU 卡约 40% 的相邻两次绘制间隔 <50 ms。修前修后相同。
- `base3` 中面板停在内存三级页 28 天档等待负载下降的 ~15 分钟里，主线程忙 p50 52 ms/s，并有 15 次 50–228 ms 的循环，未归因（没有在该状态下采样剖析）。

### 修复与效果

| # | 修复 | 为什么行为不变 | 测试（红→绿） | 效果（修前→修后） | 提交 |
|---|---|---|---|---|---|
| 1 | 一级卡片的身份固定用概览页（`MenuBarCardIdentity.overviewPage`），不再随打开的二级页变化 | 身份只用来区分卡片与订阅；一级卡片的内容、外观、锚点、点击都不依赖当前二级页 | `MiniWindowSpeedTests.testLevelOneCardsKeepOnePageWhateverPageIsOpen`（源码契约，修前 2 处失败）；`MiniWindowSpeedBehaviourTests.testLevelOneCardIdentityDoesNotDependOnTheOpenPage`（新符号，修前无法编译，只在修后跑） | 二级之间切换首次绘制 p50 49→32 ms、循环结束 61→39 ms（同负载 A/B）；`setFrame` 每次 2–4→0–2 次；一级列不再整体重建 | `08c5e13` |
| 2 | 锚点暂缺时二级页沿用该页上次对齐的偏移，而不是先跳到默认偏移 | 偏移是卡片在概览布局中的位置，与窗口位置无关；只有概览布局变化（换密度、概览尺寸变化、重新显示）才会变，这些时候清空 | `MiniWindowCascadeSettleTests.testARebuiltLevelOneCardDoesNotMoveTheOpenPage`（修前 4 处失败：卡片重建期间二级页由 332 移到 228 pt；重建多施加 2 次框，真实移动时共 3 次而非 1 次） | 去掉 `anchorRemoved`／`anchor` 两次整窗布局（各 7–14 ms）和一帧错位 | `9a7fb7c` |
| 3 | 从二级页打开的三级页包进 `liveCard(.levelThree)` | 4b 设计：新窗口准备好就画、“更新中”只到新帧交付为止；修复让它按时发生 | `MiniWindowSpeedTests.testLevelThreePagesRedrawWhenTheirDataChanges`（源码契约，修前 2 处失败）；`MiniWindowSpeedBehaviourTests.testLevelThreeCardRedrawsWhenAPreparedWindowIsDelivered`（真实 `MenuBarMonitorState`＋`MenuBarCardModel`，修后跑） | 切到未预备档：数秒～超过 10 s → p50 16–52 ms、p95 ≤ 75 ms；三级历史随采样前进 | `b727d17` |
| 3 补充 | 三级卡片内重新设置根视图的图表上下文（`rootChartContext`：所选页、版本 0），三级历史图表的准备键不再带卡片版本 | 与这页放进卡片之前的准备键相同：历史帧只取决于窗口（起止与点数已在键里），页面仍随读数重绘 | `MiniWindowSpeedTests.testLevelThreeChartsArePreparedAgainOnlyForANewWindow`（源码契约，修前 2 处失败，`logs/fix3b-red.log`）；相关 6 个测试类 32 项通过（`logs/fix3b-green.log`） | 三级图表首次有数据 p95 47→43 ms（2 轮）；三级页打开空闲时（对修复 3，各 1 轮，只表示下降趋势）CPU 7.54→6.85%（处理器）、7.11→6.68%（内存），主线程 41.0→34.2、46.3→44.7 ms/s | `49b81bc` |

JEV（`jev-latest`，`jev_decide`；只提交非敏感的方案与证据摘要，作参考，不作批准；该工具的返回没有 auto／review 字段）：修复 3 推荐 `implement_as_clear_fix`，概率 0.88，confidence 0.84，无 escape，三项要求均 supported（第一次调用因要求超过 3 条被参数校验拒绝，删减后重发）；修复 2 推荐 `implement_as_clear_fix`，概率 0.84，confidence 0.79，三项要求均 supported。交接前用 `jev_verify`（auto_accept 0.8）核对三条结论：“修复 1 不改变一级卡片显示的内容”verified，confidence 0.99，auto；“修复 2 最坏情况与修前放置相同、随后由重新登记纠正”verified，confidence 0.81，auto（contradicts 0.12；本交接“未完成与风险”写了更准确的边界：缓存过期时那一刻用的是旧偏移而非默认偏移）；“修复没有让从一级进入二级变快，只让二级之间切换变快”verified，confidence 0.95，auto。修复 3 补充（`jev_decide`）：推荐 `keep_as_clear_fix`，概率 0.97，confidence 0.97，无 escape，三项要求（不改变显示与新窗口出现的时机、相对修复 3 降低开销、不会让三级页重新变旧）均 supported；“同时收窄指纹”两项为 unknown，所以留作 T6。

### 待决定（本阶段只写方案，未实施）

| # | 方案 | 收益（本机数据） | 代价 | 建议 |
|---|---|---|---|---|
| D-1 | 内存状态采样改读 `kern.memorystatus_level`，不再起 `memory_pressure -Q` 子进程。补丁与测试：证据目录 `fixD-memory-pressure-sysctl.patch`（源码部分可在本分支（源码同 `49b81bc`）上直接 `git apply --include='Sources/*'`，已 `--check`；其中的测试文件部分写于 `MiniWindowSpeedTests.swift` 还不存在时，应改为把 `MiniWindowSpeedTests.fixD.swift` 的两个测试并入现有文件）；数值和文字（“压力余量 N%”）与原输出相同，红灯已验证 | 每次内存采样 60.4 ms → 0.013 ms（p50）；打开时内存新数据预计提前约 50 ms（与 CPU 同时，暖 ~110 → ~60 ms）；每次采样少一次进程创建 | 要改源码契约 `SystemUtilitySafetyTests.swift:1891`（`contains("timeout: 2")` 改为断言不再启动 `memory_pressure`），按 RULES §4 需要 DECISIONS 条目 | **建议采纳**：没有阻塞调用比“有期限的阻塞调用”更符合该契约的本意 |
| T1 | 面板隐藏后不在 5 分钟回收（或延长 `cachedWindowLifetime`） | 冷→暖（A/B 修后）：首帧 p50 32→20 ms、p95 61→48 ms，该次循环结束 p50 71→59 ms；`open.build` 17 ms 省掉 | 隐藏期间保留整棵视图树与面板：比已回收多 0.1–0.5% CPU、1.4–2.2 ms/s 主线程（第 11 项）。footprint 在同一次运行里“隐藏未回收”减“已回收”为 −59～+16 MB（6 次运行），由 Malloc 缓冲主导，测不出 MB 级差别 | 收益约 12 ms，不是主要瓶颈；**暂不建议**，除非实机冷打开明显更慢 |
| T2 | 隐藏时保留已准备的历史窗口（随面板回收或内存压力释放），或一级 CPU 总占用改读实时快照 | 打开时不再出现 CPU“—”（现在每次首帧都是“—”，暖 ~60、冷 ~72 ms 才有值）和图表“采样中”闪现（暖 ~58、冷 ~69 ms 出现，约 8–10 ms 后被数据替换） | 保留窗口：隐藏期间多占已准备数组（估算一级 1 小时窗口约 0.6–1.2 MB；隐藏前开着 28 天档最多约 15 MB，最长 5 分钟，未实测）；要改 4b 锁定“隐藏即释放”的两项测试与设计文档 | 建议采纳“保留窗口”，属 4b 决定的修订，需要用户／主会话确认 |
| T3 | 一级列在“只有概览”和“二级页旁”用同一外层结构，从概览进入二级页不再重建一级卡片 | 从概览进入二级页预计接近“二级之间切换”修后的水平（A/B p50 47 对 32 ms，循环结束 61 对 39 ms） | 改 `PanelShell`／`GeekAttachedPanelShell` 布局，需要黄金图与锚点几何测试回归、截图核对 | 下一批单独做 |
| T4 | 级联重排合并到每次运行循环一次（`setFrame(display: false)` 或下一回合合并） | 修后仍有的 1–2 次 `setFrame`（各 7–14 ms）合并成一次 | 动 4b 刚改完的延后几何重放顺序；需要重验 `MiniWindowAnchorGeometryTests` 与实机拖动、贴边翻转 | 二级首帧实机若仍 >50 ms 再做 |
| T5 | 二级页按页缓存上次实测高度，首次放置就用它 | 磁盘、内存、处理器页每次打开少一次 7–14 ms 的整窗布局与一次位置跳动（修后这三页每次仍有 1 次 `detailSize`） | 内容高度变化时仍要再排；缓存过期时的表现要确认 | 可与 T4 一起做 |
| T6 | 三级卡片的指纹按页收窄（只看本页用到的数据源；“准备键不带卡片版本”这一半已由 `49b81bc` 做了） | 三级页打开时重绘从约 4 次/s 降到 1–2 次/s；按第 11 项，内存历史页剩下的 +7.4 ms/s 主线程、+0.7% CPU 大部分可省 | 指纹漏掉某页实际用到的数据源会让该页重新变旧（本批修的问题）；需要逐页列出数据源并各写一个“该源变化时重绘”的测试 | 收益小（不到 1% 一个核，只在三级页打开时）；可放到下一批 |

### 请主会话实机复测

离屏驱动测不到：真实指针事件的分发与命中、窗口合成上屏、真实悬停、Esc 键与外部点击的系统路径、5 分钟真实回收。建议在合并后的测试版上做：

1. 按主会话的安装流程装好后（或用隔离身份副本），带 `--menu-bar-performance-audit=<文件>` 启动（只在测试版／Debug 生效；不带脚本参数即为正常交互）。
2. 用真实鼠标各做 ≥10 次：点状态栏图标打开（暖：隐藏后 1 分钟内再开；冷：隐藏 >5 分钟后再开）；点各一级卡片进入二级；二级打开时点另一张一级卡片；从二级页打开历史（三级）；在三级切换 1 分／15 分／1 时／1 天／7 天／28 天；在三级图表上移动指针；Esc 与点外部关闭。
3. 分析：`python3 analyze.py <文件>` 与 `python3 analyze.py --transitions <文件>`（证据目录）。真实点击会记录 `inputToDrawMs`（事件时间戳到绘制）。
4. 验收：三级切档后“更新中…”在 0.1 s 内消失、新档画出（`chart.tertiary range.*` p95 < 100 ms，无 >1 s）；三级历史打开期间随采样前进；二级页之间切换时二级页不先跳再回、一级列不闪（`secondary (from module)` p50 ≈ 30–45 ms，每次 `setFrame` ≤ 2）；打开、悬停、关闭与本表同量级。
5. 目视：切换二级页、在屏幕左右边缘打开时，整组位置与 4b 的几何一致（本批改了锚点暂缺时的偏移来源）；当前二级页对应的一级卡片高亮跟随切换。
6. 对比包：修前基线、修后、修后补充三个包在 `~/Developer/.sc-build/r2-mini-speed/`；`run-latency.sh <标签> <计划> <包>` 可在隔离身份下重跑本交接的任一计划（`ab-*.sh` 里有原样的计划串）。

### 实际命令与结果

所有 SwiftPM 命令都带 `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`；依赖缓存从 `~/Developer/.sc-build/batch4b/debug` 只读复制（checkouts、repositories、artifacts，并改写 `workspace-state.json` 中的路径），未联网。

| 命令（摘要） | 结果 |
|---|---|
| `git merge task/batch4b-mini-logic`（两次，未 rebase／reset） | `6fa1767`：无冲突；`29060de`：`MenuBarGeekCharts.swift`、`MenuBarPreparedChart.swift` 冲突，按两边意图合并（4b 的 `GeekHistoryPreviousFrameKey` 偏好＋本批探针都保留） |
| `swift build -c release --scratch-path /tmp/storage-cleaner-r2speed-build --jobs 4 --skip-update --disable-automatic-resolution` 加打包脚本相同的 `-Xswiftc -D STORAGE_CLEANER_BETA -g` 与链接参数（预热、确认离线可解析） | exit 0（195 s），`logs/warmup-release-build.log` |
| `SWIFT_BUILD_DIR=/tmp/storage-cleaner-r2speed-build DIST_DIR=…/r2-mini-speed/beta-package BETA_DIST_DIR=…/r2-mini-speed/beta-dist STORAGE_CLEANER_SKIP_TESTS=1 SWIFT_BUILD_JOBS=4 script/build_and_run.sh --beta`（未加 `--install`） | 8 次，全部 exit 0：冒烟 3 次、`6fa1767`（随后被 `6847248` 取代）、`6847248`（早期基线，build 20261004120351）、`29060de`（修后，build 20261004131104）、`29060de` 反向套用三处修复（修前基线，build 20261004131706）、`49b81bc`（修后补充，build 20261004145948，297 s；BuildInfo 标 dirty 只因工作区有未跟踪的本交接文档）。偏差：主会话给的 `SWIFT_BUILD_DIR=~/Developer/.sc-build/…` 会被脚本拒绝（`prepare_swift_build_dir` 只接受 `/tmp/storage-cleaner-*`），所以用了 `/tmp/storage-cleaner-r2speed-build` |
| `run-latency.sh <标签> <计划> <应用>`（隔离身份、本次专用数据根、`-ApplePersistenceIgnoreState YES`、`--menu-bar-performance-audit=`＋`--menu-bar-latency-script=`；结束 `kill -TERM`） | 全部正常结束：`smoke1–3`、`prof1`（同时 `sample` 1 ms 采样三段）、`base1`（门限 4 下一直等负载，9 分钟后手动结束，无数据）、`base2`、`base3`、`pre`、`post` |
| `ab-modules.sh`：修前／修后轮流 3 轮，计划 `phases=modules,tertiary;iterations=4;settle=15;maxLoad=100` | 6 次全部 exit 0；两边负载 p50 均 12.6 |
| `ab-ranges-steady.sh`：打开 2 轮（`phases=openclose;iterations=12`）、切档 2 轮（`phases=ranges;rangeIterations=4;rangeSections=processor,memory;ranges=900,3600,86400`）、稳态 2 轮（`phases=steady;steady=60`） | 12 次全部 exit 0；负载：打开 4.2–5.4、切档 3.0–5.0、稳态 2.5–3.8（`compare-ab-open.md`、`compare-ab-ranges.md`、`compare-ab-steady.md`） |
| `ab-fix3b.sh`：① 三级打开与切档，修后 `29060de` 与修后补充 `49b81bc` 轮流 2 轮（`phases=tertiary,ranges;iterations=4;rangeIterations=4;rangeSections=processor,memory;ranges=900,3600,86400`）；② 三级页打开后保持空闲（借切档阶段开始时的负载等待，门限 0.5 不可达，由 170 s 运行时限结束），内存页、处理器页各跑修前／修后／修后补充三种包（`ab-l3idle.sh` 写好后没有单独运行，内容并入此脚本） | 10 次全部 exit 0；三级打开与切档负载 4.4–5.6，三级空闲负载 3.8–5.8（`compare-ab-fix3b.md`、`compare-ab-l3idle.md`） |
| `python3 compare.py`／`analyze.py`／`steady.py`（证据目录） | 输出 `compare-pre-post.md`、`compare-ab-*.md`、各运行的 `summary.txt`／`transitions.txt` |
| Release 小窗性能门禁（`49b81bc`）：按 `script/verify_menu_bar_performance.sh` 的步骤离线执行（`perf-gate.sh`）：脚本自带的源码守卫原样运行；`swift build -c release --scratch-path ~/Developer/.sc-build/r2-mini-speed/verify/release --jobs 4 --skip-update --disable-automatic-resolution -Xswiftc -enable-testing --build-tests`；等 1 分钟负载 <6（N10）后 `swift test -c release … --skip-build --filter MenuBarPerformanceRegressionTests` 连跑 3 次 | PASS：守卫 exit 0；构建 exit 0（约 4.5 min）；3 次各 16 项 0 失败，exit 0；`preparation_p95_ms` 72.13／72.12／79.27（预算 100），`cached_delivery_p95_ms` 约 0.0015；第 1 次开始时负载 5.72，第 2、3 次 6.22（`logs/perf-gate.log`）。之后门禁 scratch 移到废纸篓 |

### 测试

- Debug 全量（`49b81bc`，即本分支最终源码）：`swift test --scratch-path ~/Developer/.sc-build/r2-mini-speed/debug --jobs 4 --skip-update --disable-automatic-resolution`，exit 0，3269 项，跳过 21，0 失败（178 s，`logs/test-fix3b-full.log`）。此前：`29060de` 3268／21／0（205 s，`logs/test-merged-full.log`）；插桩提交后、并入 4b 第二轮前 3241／21／0（`logs/test-instrumented-full.log`）。日志中的 CoreData／通讯录 XPC 报错是环境输出，三次全量都有、数量相同（242 行）。
- 修复 3 补充：红 `--filter MiniWindowSpeedTests`，exit 1，1 项 2 处失败（`logs/fix3b-red.log`）；绿 `MiniWindowSpeedTests`、`MiniWindowSpeedBehaviourTests`、`MiniWindowCascadeSettleTests`、`MiniWindowRangeSwitchTests`、`MiniWindowHistoryDemandTests`、`MenuBarSecondaryVisualConsistencyTests` 共 32 项 0 失败（`logs/fix3b-green.log`）。`git diff --check` 通过。
- 红（暂存三处修复的源码，只留测试）：`--filter MiniWindowSpeedTests --filter MiniWindowCascadeSettleTests`，exit 1，3 项 8 处失败（`logs/fixes123-red.log`）。行为测试用到修复新增的符号，修前无法编译，没有红灯。
- 绿：同上加 `--filter MiniWindowSpeedBehaviourTests`，exit 0，5 项 0 失败（`logs/fixes123-green.log`）。
- D-1（未提交）：红 2 处失败（`logs/fixD-red.log`）；绿（相关 8 个测试类 347 项）唯一失败是 `SystemUtilitySafetyTests.swift:1891` 源码契约（`logs/fixD-green.log`），所以撤回并保存为补丁。
- 没有删断言、放宽阈值或跳过测试；没有改任何已有源码契约测试。

### 未完成与风险

- **离屏测量的局限**：没有窗口合成上屏（实屏还要加 1–2 帧）、没有真实指针事件的分发与命中、悬停是注入位置而非真实指针、Esc 与外部点击走会话入口而非系统事件、面板不是关键窗口。结论需要主会话按上文实机复测。
- **负载**：多数样本在 1 分钟负载 >4 时测得（其他会话在编译与同步）；用同负载交替 A/B 抵消，但绝对值偏高。负载 <4 的数字只有 `base2` 子集、`base3` 与第 11 项稳态；切档 A/B 负载 p50 约 4。
- **未提交的修复**：D-1（受源码契约阻碍）；T1–T6 只写了方案。
- **修复 2 的边界**：缓存的偏移只在锚点暂缺的那一刻使用；若概览布局变了却没有经过清空路径（`show`、换密度、概览尺寸变化），那一刻会用旧偏移（修前用默认偏移），同样在卡片重新登记后纠正。
- **修复 3 的代价**：三级页打开时随数据重绘（约 4 次/s，约 90% 与其他卡片在同一次绘制中）。补充 `49b81bc` 之后，三级页打开空闲时比修前（页面冻结）多 0.3–0.7% CPU、1.3–7.4 ms/s 主线程（各 1 轮，趋势）；三级图表首次有数据的 p95 尾部与修前基本相同（第 4 项）。补充只做了离屏测量，三级页“随采样前进、切档后按时画出”的实机目视仍需要。
- **修复 1 需要目视的一点**：一级卡片不再随切页重建，当前二级页对应的一级卡片高亮靠正常的视图更新切换；全量测试通过，实机请顺带确认高亮跟随。
- **未归因**：`base3` 中面板停在内存三级页 28 天档时的 15 次 50–228 ms 循环；`post` 中一次 503 ms 循环（见第 10 项）。都没有在当时采样剖析。
- **内存数字**：`footprint` 受 Malloc 缓冲影响大，同一次运行里两相位可差 40 MB，T1／T2 的 MB 级代价没有实测；`heap` 采集只得到表头，没有可用数据。
- **测量工具本身**：审计写盘在主线程，约占主线程忙碌样本 1%，修前修后相同；驱动只在 Debug／测试版且带参数时编译和运行，正式版不受影响。
- **构建目录与副本**：每次运行用过的应用副本与专用数据根都已移到废纸篓；Release 构建目录 `/tmp/storage-cleaner-r2speed-build`、门禁 scratch、`beta-dist`／`beta-package` 在交接提交前移到废纸篓（见“实际命令与结果”）。保留 `~/Developer/.sc-build/r2-mini-speed/` 下的 `baseline-29060de-minus-fixes.app`、`after-29060de.app`、`after-fix3b.app`（各 88 MB）供主会话复测对比，Debug scratch 保留。
- **隔离身份副本的更新检查**：包内 `SUEnableAutomaticChecks = true`（间隔 21600 s，`SUAutomaticallyUpdate = false`）。隔离身份的 `SULastCheckTime` 为 2026-10-04 15:05:05Z，比 `ab-tr-post-1` 启动晚 2 s，说明本批的一次运行触发过一次 Sparkle 定时检查（读取公开的测试版 appcast）；没有下载或安装（自动更新关闭，进程在运行结束时被 `kill -TERM`）。本批没有改该隔离身份的设置；以后用这个身份做离屏测量，建议先写 `SUEnableAutomaticChecks=false`，避免联网。
- 本批没有改 `ScanStore.swift`（任务允许的 `MenuBarMonitorState` 采样范围未用到）。
