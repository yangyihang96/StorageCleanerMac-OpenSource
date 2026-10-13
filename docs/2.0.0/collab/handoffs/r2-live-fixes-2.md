# 批次 r2-live-fixes-2：实机缺陷第二批（N19、N16 六项、D43、N20、N22、P2-5）

- 分支 `task/r2-live-fixes-2`，基于集成分支 `23bd624`；worktree `~/Developer/sc-worktrees/r2-live-fixes-2`；scratch `~/Developer/.sc-build/r2-live-fixes-2/`（`debug/`、`strict/`，日志在 `logs/`，反证用的修复后文件备份在 `mutation-backup/`）。依赖从 `r2-live-fixes-1` 的 scratch 只读复制（checkouts、repositories、artifacts、workspace-state.json 改写路径）。
- 实现：Claude 子代理（Claude Opus 5.5）。来源：BOARD N16、N19、N20、N22，DECISIONS D43，r2-live-fixes-1 交接第 6 节 P2-5。
- 提交（按顺序）：`cd90100` N19、`a5f40a8` N16-1、`5127f6e` N16-2／N16-3、`f9eee00` N16-4、`bbf74bd` N16-5／N16-6、`7b21d6c` D43、`b12aacb` N20、`6518b3c` N22、`c5f9c9e` P2-5、`3ff3b2a`（只改一处注释）、`25a3f34`（交接）。
- 复核（全新复核子代理，区间 `23bd624..25a3f34`）：修后可合并，无 P0／P1。复核后的修改与对 6 处说法的更正见第 13 节（提交 `414848c`…`f083c58` 及本次交接更新）。
- **修改了 `Stores/ScanStore.swift`**（N19、N16-2／N16-3、N20 三处，见各节）。本批是这一轮唯一修改它的批次；合并时注意 RULES“同一时间只允许一个批次修改 ScanStore.swift”。
- 没有修改 `DECISIONS.md`、`BOARD.md`（RULES：只由主会话记录）。需要主会话补记的决定见第 12 节。

## 结论

代码与自动测试：任务 1–6 共 11 个子项全部完成，每个修复提交都有红 → 绿 → 反证。Debug 全量、严格并发构建、私有 API 检查、`verify.sh` 源码检查、空白检查都通过（交付时的严格并发构建只覆盖非测试目标，见第 13 节的更正与复核后结果）。实机核对按 RULES 没有做（NOT RUN），清单见第 11a 节。

| 项 | 内容 | 结果 | 提交 |
|---|---|---|---|
| N19（P1） | 内存“退出”一律先确认 | PASS：第二下只弹确认，确认框列出应用名、说明未保存内容由各应用处理；按钮变形后 0.6 s 内的点击忽略；建议项排除前台应用；小窗选中后显示全宽红色“退出所选应用（N 个）”，主窗口按钮不再用绿色。“最近使用的应用”只排除了一个（第 1.4 节） | `cd90100` |
| N16-1 | GPU 频率 | PASS：读 IOReport GPU 性能状态 × pmgr 频率表，本机实测 338 MHz（活动 11%，最高 1620 MHz）；读不到时写明原因，GPU 关闭时显示“空闲” | `a5f40a8` |
| N16-2 | 二级页进程区打开后 1–2 秒为空 | PASS：保留的进程快照立即显示并带采样时间；第一次实测在基线后 0.5 s（原为常规间隔 ≥ 2 s）；什么都没保留时显示“正在采样…” | `5127f6e` |
| N16-3 | 一级网络卡切页后短暂“--” | PASS：读网络自己的历史；某次样本没有速率时沿用上次读数（最长 15 s，按现在计算；复核后更正：交付时按当前样本的时间计算，`2098940` 改正） | `5127f6e`、`2098940` |
| N16-4 | 能耗列表两个“测试版” | PASS：进程路径改读内核（`proc_pidpath`），附属进程并回所属应用；不同应用同名时加上区分（“测试版 · Applications”） | `f9eee00` |
| N16-5 | 能耗汇总 0.000 kWh／0%／0 秒 | PASS：接电时后台按电池控制器报告的整机负载积分（本机实测 61.10 W）；尚无记录时显示“—”并说明原因，不再显示测得的 0 | `bbf74bd` |
| N16-6 | 接电时电源二级“—”行 | PASS：只显示有数值的行；接电时显示“整机 · 系统负载”；去掉始终为“—”的“CPU / 显示器” | `bbf74bd` |
| D43 | 内存双环顺序、CPU 卡标题 | PASS：压力在左、占用在右（一级、二级、设置预览一致）；CPU 卡标题右侧为频率＋温度（只显示读到的部分），总占用移到悬停说明与读屏值（复核后更正：交付时读屏值挂在普通 HStack 上，未验证能读到；`925a981` 把页头合并成一个读屏元素，仍待实机核对） | `7b21d6c`、`925a981` |
| N20 | 智能扫描不写扫描历史 | PASS：完成的完整智能扫描写入与结果页同口径的历史；取消的、只扫开发工具或安全清理的不写。另发现一处残留（第 7.4 节） | `b12aacb` |
| N22 | 扩展阶段取消未入历史；后台负载提示 | PASS：取消的这次立即出现在历史；开始前后台 CPU 占用 ≥ 25%（或原有 1 分钟负载规则）时结果提示“开始前后台负载高，结果可能偏低。”，不阻止测试 | `6518b3c` |
| P2-5 | 浏览器真身再核对 Team ID | PASS：Google Chrome（`com.google.Chrome`）固定为 EQHXZ8M8AV；其余浏览器本机未安装，保持现状（第 10 节列明）；Safari 不变（D42） | `c5f9c9e` |

没有安装、打包、启动或退出已安装的测试版／正式版；没有在真实应用或真实文件上执行退出、清理、恢复；没有写硬件设置；没有 push；没有读凭证。本机只读操作：`codesign -dv`（Chrome、Safari）、IOReport／AppleSmartBattery 读数（实时测试）、`ps`／`proc_pidpath`（测试夹具进程）。

## 1. N19：内存“退出”一律先确认（P1）

### 1.1 根因

- `ScanStore.performRecommendedMemoryAction` 第二步连调 `requestQuitSelectedMemoryProcesses()` 与 `confirmQuitSelectedMemoryProcesses()`（BOARD 记录的基线 `ScanStore.swift:3938-3941`），所以第二下（包括双击的第二下）直接退出真实应用。
- 建议项排除 `isActive` 的应用（`SystemModels.swift:217`），但用户在本应用窗口里点按钮时，前台是本应用自己，用户正在用的应用（如 Claude、ChatGPT）不是 `isActive`，于是进了建议。

### 1.2 修复

- `ScanStore.swift:3983-4012`：第二步只请求确认，从不直接退出。第一步记下时间（`memoryActionUptime`，可注入）；按钮变形后 `recommendedMemoryActionDebounce = 0.6` s 内的点击忽略（macOS 默认双击间隔 0.5 s）。
- 确认文案统一为 `MemoryQuitSelectionSummary.confirmationMessage`（`SystemModels.swift:125-160`）：“将正常退出：A、B、C。未保存的内容由各应用自行处理，可能会提示你保存；不会强制退出。这些应用目前约占 X，预计释放量以退出后的刷新重测为准。”最多列 10 个名字（`confirmationNameLimit`），多出的写“等 N 个”；英文同步。
- 三个确认框共用该文案，沿用既有确认机制（D2 补充“列出建议＋确认”）：
  - 主窗口“退出所选应用？”（`ContentView.swift:386-398`），页头按钮的第二步和列表的“退出 N 个应用”都走这里；
  - 小窗 `GeekMemoryQuitConfirmationHost`（`GeekMemoryView.swift:612-660`），挂在进程卡上，按钮在页头与全宽两种形态间切换时确认框不丢；
  - 简单面板（`MenuBarStatusView.swift:88`）。按 D2 补充（2026-10-05 更正），简单面板不在产品中构建，没有运行效果。
- 建议项排除前台应用：新增 `UserFrontmostApplicationTracker`（`Features/Memory/Infrastructure/`），在 `applicationDidFinishLaunching` 启动，跟随 `didActivateApplicationNotification`。“用户正在用的应用”定义如下：
  - 前台不是本应用时，取前台应用；
  - 前台是本应用时，取在它之前的前台应用。

  `SystemMemoryProbe.identities` 把这个应用标为 `isActive`（`SystemMemoryProbe.swift:625`），既有规则就会把它排除出建议。
- 界面（U1 066／068／070）：
  - 小窗：选中应用后，页头小按钮隐藏，进程列表下方出现全宽 `.borderedProminent`、红色（`Palette.destructive`）的“退出所选应用（N 个）”（`GeekMemoryView.swift:171`、`prominentTitle`）。
  - 主窗口：页头推荐按钮原来用 `releaseTint`，也就是压力色，压力正常时是绿色。现在未选中前用内存模块的操作色（mauve），选中后是红色并带 destructive 角色（`SystemUtilitiesView.swift:3771-3800`），帮助文字同步。
  - 退出类操作不再出现绿色等安全色。

### 1.3 测试与反证

- 新增 `MemoryQuitConfirmationTests`（7 个），覆盖以下行为：
  - 第二下只请求确认、从不自行退出；
  - 按钮变形后立即点击被忽略，防抖覆盖系统双击间隔；
  - 列表已选中建议时，变形后的按钮立即请求确认；
  - 列表的退出按钮只请求确认；
  - 确认文案列出名字、超过 10 个写“等 N 个”、说明未保存内容（中英），三处确认框都用它；
  - 建议排除用户正在用的应用（`resolve` 与 `identities`）。
- 同时修改的契约测试见第 9 节。
- 红：8 个测试、25 处失败（`n19-red.log`）。
- 绿：相关 9 个测试类 84 个、0 失败（`n19-green.log`）。包括 Memory 开头的各类、`MenuBarSimplePanelQuitTests`、`MiniWindowMemoryQuit*`、`DetailedPanelViewProfileTests`、`GeekHoverDetailTargetTests`。
- 反证：把 `ScanStore.swift`、`UserFrontmostApplicationTracker.swift` 还原到修复前行为后，8 个测试中 6 个失败（15 处，`n19-mutation.log`）；已还原。

### 1.4 限制

- BOARD N19 写的是“排除前台与最近使用的应用”。本批按任务说明排除“前台应用”，本应用在前台时排除它之前的那个应用，只覆盖一个。更早用过的应用（例如先用 ChatGPT、再用 Claude、再切到本应用时的 ChatGPT）仍可能被建议。要扩大需要定规则（例如 N 分钟内激活过的都排除），建议在 U1 定。
- 主窗口列表的“退出 N 个应用”按钮本批没改样式：它是 destructive 角色＋主按钮样式，没有显式红色着色，界面上没有绿色。实际颜色请实机确认（第 11a 节）。

## 2. N16-1：GPU 频率

### 2.1 根因

小窗 CPU 页“GPU 频率”行是写死的占位（无数据源），所以永远没有数值（iStat 同机 0.34 GHz）。

### 2.2 修复（`CPUPerformanceStateService.swift`、`GeekSensorsView.swift`、`GeekProcessorView.swift`、`GeekOverviewPresentation.swift`）

- 采样时多订一个 IOReport 组：“GPU Stats”／“GPU Performance States”的 GPUPH 通道（OFF、P1…P15 驻留时间）。频率表读 pmgr 的 `voltage-states9`（`loadGPUDVFSStates`，第 612 行）：
  - 第一条 0 Hz／125 mV 记录跳过；
  - 其余要求频率、电压都递增；
  - 频率必须在 100–3000 MHz（`validGPUFrequencyMHz`）；
  - 超出表长的 P 状态必须没有驻留，否则不出数。
- `gpuReading(residencies:states:)`：活动时段按各工作点驻留时间加权的平均频率、活动占比、表中最高频率。全部为 OFF 时频率为空，显示“空闲”。读不到时整行显示“—”，并写明“未能读取 GPU 工作点：本机没有可识别的 GPU 频率表或性能状态”。CPU 与 GPU 部分互不影响，任一部分读不到不会让另一部分失效。
- 显示位置：
  - CPU 二级页“GPU 频率”行，说明写来源 IOReport 与活动占比；
  - 新增第四个圆环“频率”，弧长 = 当前／最高；
  - 传感器页与一级传感器卡的 GPU 圆环说明，有温度时优先显示频率。
- 私有 API 清单只改了既有 `libIOReport` 条目的理由（“CPU and GPU”），没有新增调用（仍是 6 处）。

### 2.3 测试与反证

- 新增 `GPUFrequencyTelemetryTests`（8 个）：
  - 频率表解码：0 Hz 首条不算工作点；空数据、夹在中间的 0 Hz、递减、超过 3000 MHz 都不出数。**复核后更正**：交付时“夹在中间的 0 Hz 不出数”只对电压非零的记录成立，(0 Hz, 0 mV) 被当作填充跳过，后面的工作点会错位；`574fa2b` 改为首条之后的全零记录只能出现在末尾（第 13 节 P2-4）；
  - 加权平均、全 OFF 为“空闲”、超表驻留不出数；
  - 三种显示状态（中文）；
  - 圆环与频率行读同一读数（源码契约）；
  - 本机实时读数：没有 Apple 芯片拓扑或 IOReport 时跳过，本次没跳过。
- 红：8 个、17 处失败。绿：213 个、0 失败；实时 338.0 MHz（`n16-1-green2.log`）。
- 反证：还原 GPU 读取与显示后 2 个测试 5 处失败；已还原。

## 3. N16-2：二级页进程区打开后 1–2 秒为空

### 3.1 根因

进程采样器先读一次基线，之后按常规间隔（`max(visibleProcessInterval, 刷新间隔)`，≥ 2 s）才出第一次实测。D39 保留的快照存在，但页头没有区分“保留的快照”和“还没测”。

### 3.2 修复

- `MenuBarPerformancePolicy.firstProcessSampleInterval = 0.5` s：基线后 0.5 s 出第一次实测，之后恢复常规间隔（`ScanStore.swift` 进程需求循环，约第 3861-3925 行）。进程 CPU% 要两次读数求差，所以 0.5 s 是最短等待。
- 保留的进程快照（D39）打开即显示，页头显示其采样时间（`GeekOnDemandSnapshotFreshness`）。什么都没保留时，页头显示“正在采样…”（`isMenuBarProcessSamplePending`），不再是空表或“未测量”。CPU、磁盘、电源页的加载态同步。
- 网络页进程表头也显示采样时间。

## 4. N16-3：一级网络卡切页后短暂“--”

### 4.1 根因

一级网络卡的上下行读数取的是“当前打开页面”的显示历史（`selectedDisplayedHistory`），切到别的二级页时取到的不是网络历史。另外，与上次相隔 < 0.2 s 或网卡切换后的样本没有速率，此时显示“--”。

### 4.2 修复

- 读网络自己的显示历史（`networkDisplayedHistory`）。
- `MenuBarNetworkReadout.rates(current:lastReading:now:)`（`MenuBarHistoryDemandPlan.swift:39`）：当前样本没有速率时，沿用最近一次读数，最长 `maximumAge = 15` s，超过就显示“--”。**复核后更正**：交付时这 15 s 是按当前样本的时间算的，不是按现在；面板重新打开、保留的旧样本还没被新样本替换时，会显示很久以前的速率。`2098940` 改为按现在计算（第 13 节 P2-7）。
- 最近读数存在 `MenuBarMonitorState.lastNetworkReading`（`ScanStore.swift:441`、`778`）。
- 与 D39“即时读数在历史未就绪时……不再显示‘—’”一致。

### 4.3 N16-2／N16-3 测试与反证

- 新增 `MiniWindowLiveReadingRetentionTests`（5 个）：
  - 打开页面后第一次实测很快到达；
  - 再次打开时保留的快照立即显示，并带时间；
  - 进程表头说明显示的是什么（采样中或采样时间）；
  - 二级页上一级网络速率在无速率的样本后保留上次读数，过久的读数不保留；
  - 网络读数取网络自己的历史。
- 修改 `PanelChartNormalizationTests` 一处契约（第 9 节）。
- 红：5 个、14 处失败。绿：198 个，2 个原有跳过，0 失败。
- 反证：还原首次间隔与速率保留后 3 个测试 7 处失败；已还原。

## 5. N16-4：能耗列表两个“测试版”

### 5.1 根因（以夹具复现）

能耗列表的进程路径取自 `ps -o comm=`，有两个问题：

- 从访达或程序坞打开的应用没有 UTF-8 locale，`ps` 把非 ASCII 路径转义（夹具：“测试版.app”变成 `M-fM-5…`），无法归到应用包；
- launchd 启动的附属进程路径是相对的 argv[0]（`Contents/Resources/…`），同样归不进应用。

于是同一应用分成两组，又都按包名显示成“测试版”。另一种可能是隔离的集成测试副本（同样叫“测试版”）也在运行。实机当时是哪一种无法事后确认，见第 11a 节。

### 5.2 修复（`EnergyImpactService.swift:259-310`、`660-676`）

- `resolvingExecutablePaths`：每行改用内核报告的绝对路径（`proc_pidpath`），附属进程据此并回所属应用。进程已退出时保留 `ps` 的路径。
- `qualifiedName`：不同应用显示同名时加上区分，取包自身的文件名；与显示名相同时取所在文件夹，例如“测试版 · Applications”与“测试版 · StorageCleanerIntegration”。
- 用在能耗页扫描与小窗电源页两处。

### 5.3 测试与反证

- 新增 `EnergyProcessNamingTests`（4 个）：用临时目录里“测试版.app”中复制的 `/bin/sleep` 跑真实夹具进程，在空环境下验证 `ps` 输出确为转义路径，而内核路径正确。
- 另含：附属进程并回、同名区分、本进程的内核路径。夹具在测试结束时退出并删除。
- 红：4 个、7 处失败。绿：59 个，1 个原有跳过。
- 反证：还原后 3 个测试 4 处失败；已还原。

## 6. N16-5／N16-6：接电时的能耗与功耗行

### 6.1 根因

- 能耗汇总只在电池供电时用电池侧读数积分。接电时只有能耗页扫描期间的“应用归属估算”，而且该扫描在自己的样本前先断开记录，所以一直接电的会话是 0.000 kWh、覆盖 0%、记录 0 秒，与逐应用 Wh 矛盾。
- 电源二级页无条件列出三行，接电时“整机 · 电池侧”“CPU / 显示器”恒为“—”。

### 6.2 修复

- `NativeBatteryElectricalService.systemLoadWatts`（第 164 行）：取 AppleSmartBattery `PowerTelemetryData` 的 SystemLoad（mW），满足以下条件才采用：
  - `ExternalConnected` 为真；
  - 交叉核对 |SystemVoltageIn × SystemCurrentIn / 1000 − SystemPowerIn| ≤ max(1 W, 10%)；
  - 结果在 0.1–1000 W 之间。

  不满足就不出数。
- `SystemEnergyAccumulator`：
  - 接电时用同一次后台电池读数（约每 30 s）记录一个“实测”样本（`systemLoadSource`）；
  - 90 s 内有实测负载时，归属估算既不替代它，也不断开它；
  - 没有读数时什么也不记，也不断开。
- 汇总卡（`EnergyImpactSummaryGrid`）：
  - 没有记录时数值为“—”，说明写“尚未记录：需要连续两次功率读数（外接电源时读整机负载，电池供电时读电池侧）”；
  - 标题只有在非估算、有记录、覆盖 ≥ 99% 时才叫“本次开机耗电”，否则叫“监测期间耗电”；
  - 当前功率注明来源：整机负载实测（外接电源）／电池电压与电流实测／应用进程归属估算。
- 电源二级页（`GeekPowerReadouts.rows`，`GeekSensorsView.swift:149`）只列有数值的行：
  - 电池供电：“整机 · 电池侧”；
  - 接电：“整机 · 系统负载”，说明写“不含电源适配器损耗，不是插座功率”；
  - 有读数时：“电池净功率”。

  去掉恒为“—”的“CPU / 显示器”。没有任何行时隐藏“功耗”卡。

### 6.3 测试与反证

- 新增 `SystemEnergyACTelemetryTests`（6 个）：
  - 只在外接电源时读，并做交叉核对：不一致、缺字段、为 0 都不出数；
  - 接电时后台积分；
  - 归属估算不打断实测；
  - 空会话不显示测得的 0；
  - 功耗行只列有数值的；
  - 本机实时读数：不是“内置电池＋外接电源”时跳过。本次未跳过，实测 61.10 W（`n16-5-6-live.log`）。
- 红：5 个、21 处失败。绿：141 个，1 个原有跳过。
- 反证：还原积分与功耗行后 4 个测试 12 处失败；已还原。

## 7. D43 与 N20

### 7.1 D43 改动（`7b21d6c`）

- 内存双环：压力在左、占用在右。一级 `GeekMemoryPresentation`、二级 `geekMemoryRingsCard`、设置里的模拟预览三处一致；预览用的就是一级组件。
- 一级 CPU 卡标题右侧显示 `headerReadout(frequency:temperature:)`：
  - 例如“4.43 GHz · 80°C”，只显示读到的部分，都读不到时不显示；
  - 有温度时用温度色，否则用主文字色；
  - 总占用由下方用户／系统图例表达，并保留在悬停说明（“CPU 总占用 …”）与读屏值里。**复核后更正**：交付时 `.help`／`.accessibilityValue` 挂在没有 `.accessibilityElement` 的 HStack 上，读屏能否读到没有验证；`925a981` 给页头加了 `.accessibilityElement(children: .combine)`，由源码契约锁定（测试进程里取不到 SwiftUI 的读屏树），仍需实机用 VoiceOver 核对。悬停提示可能被“悬停即开二级页”抢先；二级页的“CPU 占用”卡显示总占用；
  - 设置预览用示例值“3.20 GHz”“42°C”。
- `docs/mini-window-design.md` 同步了这两条。
- D4 顺序的契约：基线 `23bd624` 里没有锁定内存双环顺序的测试（检索过 `GeekMemoryPresentation`、`geekMemoryRingsCard`、压力／占用相关断言，只锁了压力环内容）。新增 `MiniWindowD43LayoutTests` 锁定 D43 顺序；CPU 标题相关的两处契约按 D43 修改（第 9 节）。
- 红：3 个、10 处失败。绿：168 个。反证：还原后 3 个测试 5 处失败；已还原。

### 7.2 N20 根因与修复（`b12aacb`）

- 根因：只有旧版全盘扫描写 `ScanHistoryService.record(scanResult)`；产品里的智能扫描 `startCleanupV2Scan` 不写。设置的“扫描提醒”、菜单栏“可安全清理”因此一直“等待首次扫描”。
- 新增 `CleanupScanTierTotals`（`CleanupScanModels.swift:1310`）：按档统计可勾选、非永久删除的候选（D19、D23），结果页（`CleanupScanViews.swift`）与历史共用这一定义。
- `ScanHistoryService.entry(from:scanMode:)`（第 589 行）按结果页口径写绿／黄／红的体积与项数，以及“可操作”的绿色体积与项数。其余字段：
  - 被拒数：权限报告里 `.permissionDenied` 的条数；
  - 是否受限：结果不是 complete，或有规则超时，或候选被截断；
  - 评分：来自会话的评分明细；
  - 磁盘已用／可用：来自会话的系统快照。
- `ScanStore.swift:3046-3051`：结果不是“已取消”、且没有按类别或规则缩小范围时才写，所以开发工具、安全清理页的扫描不写。`scanHistoryDefaults` 可注入，默认 `.standard`。**复核后更正**：交付时只有新测试类注入了隔离 suite，既有测试（`CleanupRuleScannerTests` 2 个、`CleanupStoreFollowUpTests` 16 个、`SafeCleanupLayoutTests` 1 个，以及改前就有的 `HeavyWorkIntegrationTests` 旧版扫描 1 个）跑完扫描后仍写测试进程的 `UserDefaults.standard`；`414848c` 起由 `ScanHistoryTestDefaults` 统一注入并在 teardown 检查（第 13 节 P2-1）。

### 7.3 N20 测试与反证

- 新增 `SmartScanHistoryTests`（DEBUG）：
  - 完成的扫描写入并持久化，数值等于结果页口径；
  - 部分完成 → 建议重扫，有被拒文件夹 → 权限受限；
  - 取消、开发工具、安全清理都不写；
  - 结果页与历史共用定义。
- 修改 `UIConsistencyRegressionTests` 一处（第 9 节）。
- 红：4 个、6 处失败。绿：127 个。反证：去掉写入后 2 个测试 5 处失败；已还原。

### 7.4 `latestStatus()` 的其他读取方（逐个核对）

- 以下读取方现在都能看到智能扫描的记录：
  - 主窗口工具页准备态（`ContentView.swift:1217`）；
  - 智能扫描首页“上次扫描”（`1579`）；
  - 清理摘要（`2439`）；
  - 小窗清理页（产品中的菜单栏摘要，`GeekCleanupView`）的“可安全清理”“项目数”（`MenuBarAdvancedComponents.swift:929-940`）；
  - 设置“扫描提醒”（`MaintenanceReminderService`，读同一份 `.standard` 历史）。
- 简单面板（`MenuBarStatusView.swift:606-612`、`729`）也读它。按 D2 补充，简单面板不在产品中构建。
- 访问修复引导（`ScanStore.swift:1914`）：产品模式下只用于文件类页面，提示前会重新检查就绪状态，结论合理。
- **残留（未改）**：小窗清理页的卡片标题 `cleanupSummaryTitle` 和“可操作项目”卡仍读旧版扫描明细（`actionableCleanupItems`，`MenuBarAdvancedComponents.swift:942-956`）。在 v2 模式下，即使刚扫完，标题也是“上次扫描摘要”，“可操作项目”卡显示“……请重新扫描后再确认清理”。数字本身已来自智能扫描；修复前这里是“--”和“等待扫描”。建议后续批次改读智能扫描会话的明细。
- 合并面板的 `detailPage` 在产品中不可达。

## 8. N22：取消入历史与后台负载提示（`6518b3c`）

- 扩展阶段取消，根因：`finishV7` 在被取消的运行任务里执行。保存记录与重载历史的 `BenchmarkTimedOperation` 在已取消的任务里立即返回“已取消”，所以记录落盘晚（实机历史文件里确有该条取消记录），列表要到下次启动才重载。
- 修复（`MacBenchmarkStore.swift:678-692`）：已取消时在一个不继承取消的非结构化 `Task {}` 里完成保存与重载，并等待它结束。新增 `testACancelledRunIsSavedAndListedAtOnce`（`BenchmarkV7CoordinatorWorkloadIntegrationTests`）。
- 后台负载（`BenchmarkV7PreflightService.swift`）：
  - 环境检查原有 1 s 等待，现在在等待前后各读一次全部 CPU 的 tick（`host_statistics(HOST_CPU_LOAD_INFO)`，忙 = user＋system＋nice），算出这 1 s 内忙的占比；
  - 占比 ≥ `highBackgroundCPUBusyRatio = 0.25`，或原有规则（1 分钟负载 ≥ 活动处理器数的 0.75）成立时，给出 `.highBackgroundLoad` 警告，详情写实测百分比；
  - 只是警告，不阻止测试。占比存入预检报告（`backgroundCPUBusyRatio`），随结果保留。
  - 结果卡文案为“开始前后台负载高，结果可能偏低。”，英文为“Background load was high before the test; results may read low.”。
  - 阈值 25% 是本批选择：在本机 18 线程上约相当于 4–5 个核心持续忙，比原有规则（需要约 13.5 个可运行线程）敏感得多。1 s 窗口内也包含本应用自身的预检工作（读内存、显示器信息），量很小。协议名与单位按任务留给 U6。
- 测试：新增 `BenchmarkBackgroundLoadTests`，覆盖：
  - 忙占比 30% 报警且不阻止；
  - 安静机器不报；
  - 负载平均规则仍有效；
  - 占比由两次 tick 计算，本机可读 tick；
  - 结果卡文案。
- 红：6 个、4 处失败。绿：性能测试相关测试类（Benchmark、MacBenchmark、MSeries 等）347 个，6 个原有跳过。反证：还原后 2 个测试 4 处失败；已还原。

## 9. 改动的源码契约测试（RULES §4）

| 测试 | 原来锁定 | 现在 | 依据 |
|---|---|---|---|
| `MemorySelectionSummaryTests.testRecommendedActionSelectsFirstAndExecutesOnlyOnSecondClick` → 改名 `…AsksForConfirmationOnSecondClick` | 第二下直接退出（断言 `isOptimizingMemory`） | 第二下只弹确认；取消后不退出 | BOARD N19（P1，主会话写明“第二步必须弹确认”）。DECISIONS 里没有“第二下直接退出”的决定；建议主会话把 N19 规则补记为决定（第 12 节） |
| `MenuBarSimplePanelQuitTests` | 源码含 `summary.appNameList` | 源码含 `Text(summary.confirmationMessage)`，且该文案包含名字列表 | D2 补充（确认框列出应用名）不变，只是三处共用一个文案 |
| `MiniWindowMemoryQuitSelectionTests`、`MiniWindowMemoryQuitHeaderLayoutTests` | 按钮源码的缩进；页头组合恒含小按钮 | 缩进随包装变化；两种形态都只请求确认；页头 `if selectedMemoryAppCount == 0`；全宽按钮在列表下方并能放下完整标题（中英、12 个应用） | BOARD N19＋U1 066／068／070 |
| `PanelChartNormalizationTests.testNetworkHeadlineAndMirroredBarsUseTheirLatestHistorySample` | 网络读数两处 `currentReading(of: selectedDisplayedHistory)` | 读 `networkDisplayedHistory`，经 `networkCurrentRates` 保留上次读数；断言旧写法不再出现 | BOARD N16-3；与 D39“即时读数不再显示‘—’”一致 |
| `CompactGaugeRenderingTests` | 按负载色找 CPU 卡总占用读数的像素 | 按读数色找频率＋温度读数的像素 | D43（取代 D13 中“负载色用在一级 CPU 卡总占用”） |
| `MiniWindowConsistencyRuleTests` | CPU 卡含 `.foregroundStyle(processorTint)` | 不含；含 `headerReadout(...)`；二级“CPU 占用”总占用仍用负载色（原断言保留） | D43 |
| `UIConsistencyRegressionTests` | 结果页源码含 D23 过滤式 | 结果页用 `CleanupScanTierTotals(categories:)`，过滤式在 `CleanupScanModels.swift` 中断言 | D23 规则不变，只是位置移到共享口径（N20） |

只有新增断言、没改原断言的：`BenchmarkV7CoordinatorWorkloadIntegrationTests`（加一个测试）。

## 10. P2-5：浏览器 Team ID（`c5f9c9e`）

- `BrowserPrivacyProviderDescriptor` 增加 `teamIdentifiers: [String: String]`（按 bundle ID）。`productionWriteRoot` 在原有检查之外要求：有固定值时，签名 Team ID 必须等于它。原有检查包括：
  - 引擎、ID、bundle ID；
  - 签名身份完整（Apple 签发证书链 D42、Team ID 非空、签名标识等于 bundle ID、DR 非空）；
  - 应用包与可执行文件真实存在；
  - 配置根目录是登记路径并包含该数据库。

  扫描时（`BrowserPrivacyRecordScanner.swift:196`）与写入前（`BrowserPrivacyHistoryProcessor.swift:691`）都走这里。**复核后更正**：写入前用的是扫描时读到的签名身份，没有重新读取签名；恢复流程会重新发现浏览器。本批没有改这一点（第 13 节剩余问题）。
- 只固定 `com.google.Chrome` → `EQHXZ8M8AV`：本机已安装的 Google Chrome，经只读 `codesign -dv` 核实 TeamIdentifier=EQHXZ8M8AV。
- 本机未安装、保持现状（未固定）：Chrome Beta、Chrome Canary、Chromium、Microsoft Edge、Brave、Arc、Opera、Opera GX、Vivaldi、Orion，以及 Firefox 系（含 Developer Edition、Nightly）、Zen、LibreWolf、Waterfox。Firefox 系本来就不可直接写入。
- Safari：只读 `codesign -dv` 显示无 Team ID（平台二进制）。Safari 不在 Chromium 直接写入路径上（`productionWriteRoot` 只接受 `.chromium`），身份读取仍按 D42 用 `anchor apple generic`，本批不改。运行时发现的未知浏览器路径也不改。
- 测试：新增 `BrowserPrivacyTeamIdentifierTests`，覆盖：
  - 只有 Chrome 稳定版有固定值；
  - 用临时目录里伪造的“Google Chrome.app”，Team EQHXZ8M8AV 可写，ABCDE12345 与空 Team 都不可写。
- 红：先只加属性（不固定、不比较），2 个测试都失败。绿：`--filter 'BrowserPrivacy|StartupApplicationSigningIdentity'` 188 个，1 个原有显式开启项跳过，0 失败。反证：只删比较这一行后 1 处失败（另一个 Team 被接受）；已逐字节还原。
- 残留（与改前相同，未扩大改动）：同一 Chrome 提供方还登记了 Beta／Canary 的 bundle ID，且它们只登记了稳定版的配置根目录。发现时取 bundle ID 字典序第一个已安装的应用，所以装了稳定版时总是取稳定版。若本机没装稳定版、却有一个 Apple 证书链签名、bundle ID 为 `com.google.Chrome.beta`／`.canary` 的应用，残留的稳定版配置仍按旧规则（任意 Team ID）可直接写入。可选做法：
  - (a) 在装有 Beta／Canary 的机器上核实 Team ID 后固定；
  - (b) 稳定版根目录只认稳定版 bundle ID。

  两者都超出本批“未安装保持现状”的范围，留给主会话决定。

## 11. 命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`、`LC_ALL=en_US.UTF-8`；`swift` 命令都带 `--scratch-path ~/Developer/.sc-build/r2-live-fixes-2/<debug|strict> --jobs 4`；日志在 `~/Developer/.sc-build/r2-live-fixes-2/logs/`。本机 Apple M5 Pro（Mac17,9，18 个逻辑核：perflevel0 6 个＋perflevel1 12 个），macOS 27.2。运行期间本机还有其他会话在编译（进程表里有 swift-frontend），负载见下表。

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| 基线构建（改动前，含测试） | `swift build --build-tests` | 0 | Build complete 117.65 s（总 2 分 01 秒） | `baseline-build.log` |
| 各项红／绿／反证 | 见第 1–10 节 | 红、反证 1；绿 0 | 见各节 | `<项>-red.log`、`-green.log`、`-mutation.log` |
| N16-1 实时 | GPU 频率实时测试 | 0 | 338.0 MHz，活动 0.11，最高 1620 MHz | `n16-1-green2.log` |
| N16-5 实时 | 接电系统负载实时测试 | 0 | 61.10 W，交叉核对通过 | `n16-5-6-live.log` |
| Debug 全量（`c5f9c9e`） | `swift test` | 0 | 3486 个执行，21 个跳过，0 失败；测试耗时 199.6 s，总 3 分 44 秒（09:47:19–09:51:03）；负载 9.2–10.2 | `full-test.log`、`full-test.meta` |
| 严格并发（`3ff3b2a`，新 scratch 全量编译） | `swift build -Xswiftc -strict-concurrency=complete` | 0 | 非测试目标 0 错误、0 警告；202.4 s；负载 8.7–12.5。**复核后更正**：这次没有编译测试目标，当时测试目标里有 `SmartScanHistoryTests` 的 5 个新警告；覆盖测试目标的结果见第 13 节 | `strict-concurrency.log`、`.meta` |
| 私有 API | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `guards.log` |
| `verify.sh` 的源码检查 | Views 不启动进程、内存功能不调用 purge、没有冲突副本 | — | 都没有匹配，PASS | `guards.log` |
| 空白检查 | `git diff --check`；`git diff --check 23bd624 HEAD` | 0；0 | — | `guards.log`；本交接提交后再跑一次，结果同 |

- 21 个跳过与 r2-live-fixes-1 的全量逐类相同：AppUpdateOfficialSecurity 4、BenchmarkV7RealHardwareCapture 3、CleanupRuleScanner 2，其余 12 类各 1。本批新增测试都没有跳过；它们只在环境不具备时跳过，例如非 Apple 芯片、无 IOReport、不是“内置电池＋外接电源”、夹具无法运行。
- 没有计时项失败，没有放宽阈值，没有删断言或跳过测试。
- `3ff3b2a` 只改 `GeekProcessorView.swift` 的一处注释（D43 后“as on the CPU card”不再成立）。全量测试在它之前的 `c5f9c9e` 上跑；严格并发构建与源码检查在 `3ff3b2a` 上跑。
- NOT RUN（主会话门禁或实机）：Release 全量、`script/verify_menu_bar_performance.sh`、打包、安装、启动应用、截图、实机核对。

## 11a. 需要实机核对（主会话）

确认退出只在隔离夹具应用上点。对真实应用只做到确认框出现，然后点“取消”。

1. **N19 主窗口**：
   - 内存管理页先点一次推荐按钮，建议项被选中，按钮变成红色“退出高占用应用”。
   - 再快速双击这个按钮：第二下不应有任何反应（防抖取系统的双击间隔，至少 0.6 s；复核后 `6a7483e`）。
   - 稍等再点：出现“退出所选应用？”，正文列出应用名，并写“未保存的内容由各应用自行处理……不会强制退出”。点“取消”后没有应用退出。
   - 列表的“退出 N 个应用”同样先出确认框；看一眼它的颜色（应为红色系，不能是绿色）。
   - 压力正常时，推荐按钮未选中前不是绿色。
2. **N19 建议排除**：先在某个应用（例如 Claude）里操作，再切到测试版主窗口点推荐按钮，该应用不在建议里。若先后用过两个应用，更早的那个仍可能在建议里（已知限制，第 1.4 节）。
3. **N19 小窗**：在内存页手动选中应用：
   - 页头小按钮消失，列表下方出现全宽红色“退出所选应用（N 个）”，中英文标题完整；
   - 点它出现带应用名的确认框，点“取消”。
4. **N16-1**：
   - CPU 二级页“GPU 频率”有数值，例如 0.3x GHz，说明里有“活动 N%”；与 iStat 同时读数对照；
   - 播放视频或做 GPU 负载时数值上升，不超过 1.62 GHz；
   - 空闲时可能显示“空闲”；
   - 第四个圆环“频率”、传感器页 GPU 圆环说明都有频率。
5. **N16-2**：
   - 首次打开 CPU、磁盘、电源二级页时显示“正在采样…”，约 0.5–1 s 内出列表；
   - 关小窗 1 分钟后再开，上次的列表立即显示并带采样时间，随后刷新；
   - 网络页进程表头有采样时间；
   - 复核后 `e222f4c`：若 5 s 内一直取不到进程数据，表头从“正在采样…”变为“未测量”，悬停表头看到原因，列表处写“未取得进程数据”（正常机器上不易出现，能看到就记下）。
6. **N16-3**：在各二级页之间来回切，再回一级，网络卡上下行不出现“--”。网卡切换时最多沿用上次读数 15 s（按现在计算）；关小窗几分钟后再开，网络卡不应显示几分钟前的速率。
7. **N16-4**：
   - 能耗列表里不再有两个都叫“测试版”的行；
   - 测试版的附属进程能耗并在测试版行里；
   - 若同时运行隔离副本，两行分别带“· Applications”和“· 副本名”；
   - 从访达或程序坞打开的中文名应用，名字不乱码。
8. **N16-5**：
   - 接电状态下打开能耗页：头约 30 s 内能耗卡显示“—”和“尚未记录：……”；
   - 约 1 分钟后显示非零 kWh，标题“监测期间耗电”，覆盖率逐步上升；
   - 当前功率注明“整机负载实测（外接电源）”，数值与 iStat 的系统功率同量级（本机实测时 61 W，复核后再测 57 W）；
   - 复核后 `c8873d5`：读数中断超过 90 s 时，当前功率显示“—”，说明写“暂无当前读数（上次读数 时:分:秒）”；刚打开、还没有读数时写“暂无当前读数”。
9. **N16-6**：
   - 接电时电源二级页没有“—”行，显示“整机 · 系统负载 xx.xx W”和“电池净功率”；
   - 拔电后变为“整机 · 电池侧”＋“电池净功率”；
   - 没有“CPU / 显示器”行。
10. **D43**：
    - 一级内存卡：压力在左、占用在右；内存二级页、设置里的模拟预览一致；
    - 一级 CPU 卡标题右侧为“x.xx GHz · NN°C”，有温度时带温度色；
    - 用 VoiceOver 或“辅助功能检查器”核对 CPU 卡页头：读出“CPU”、频率＋温度和“总占用 N%”（复核后 `925a981`）；悬停提示可能因悬停即开二级页而看不到，二级页“CPU 占用”卡有总占用。
11. **N20**：
    - 跑一次完整智能扫描后，设置“扫描提醒”不再是“等待首次扫描”，显示刚才的日期；
    - 小窗清理页的“可安全清理”“项目数”等于结果页“安全”档；
    - 中途取消的扫描、开发工具页和安全清理页的扫描不改变它们；
    - 该卡标题仍是“上次扫描摘要”，“可操作项目”卡写“……请重新扫描后再确认清理”（已知残留，第 7.4 节）。
12. **N22**：
    - 性能测试在扩展阶段点取消，历史列表立即出现这次“已取消”，不需要重启；
    - 开始前让后台占用超过四分之一 CPU（例如一次编译），结果卡出现“开始前后台负载高，结果可能偏低。”，测试照常进行；
    - 复核后 `db1d666`：只开着本应用、不跑别的负载时，不应出现这条提示（本应用自身的 CPU 时间已扣除）。
13. **P2-5**：浏览器隐私扫描后，真实 Chrome（EQHXZ8M8AV）的未同步记录仍可直接删除，只读查看标记即可；直接删除需要先退出 Chrome，按既有流程先问用户。

## 12. 未解决与风险

- **决定待主会话补记**（本批没改 `DECISIONS.md`）：
  - N19 规则：一律先确认、0.6 s 防抖、排除用户正在用的应用的定义。该规则改了一个契约测试，依据是 BOARD N19。
  - N16-5：接电能耗取电池控制器的整机负载；没有记录显示“—”。
  - N22：后台忙占比阈值 25%。
  - P2-5：只固定本机核实过的 Team ID。
- N19“最近使用的应用”只排除一个（第 1.4 节）；更宽的规则需要产品决定。主窗口列表按钮颜色待实机确认。
- N16-1：GPU 频率表键 `voltage-states9` 与解码规则只在本机（M5 Pro，macOS 27.2）验证。其他芯片若键或格式不同，会失败关闭（显示“未能读取 GPU 工作点”），不会显示错数。
- N16-2：隐藏期间不预热进程采样（D27 的取舍，隐藏时不为能耗、CPU 采样）。重新打开时，新的实测最少还要约 0.5 s。
- N16-4：实机两个“测试版”究竟是附属进程还是隔离副本，本批不能事后确认，修复同时覆盖两种情况；请按第 11a 节第 7 条核对。
- N16-5：SystemLoad 的含义只在本机一台机器上核对过（与 V×I、PowerIn 交叉一致）。它不含适配器损耗，不是插座功率。其他机型读数不一致或缺字段时不出数，回到改前行为（只在能耗页扫描期间估算）。没有内置电池的台式机没有这个来源，与改前相同。覆盖率 = 记录时长 / 开机时长，应用启动晚于开机很久时覆盖率低，标题因此是“监测期间耗电”，这是有意的。
- N20：小窗清理摘要在 v2 模式下的“请重新扫描”残留（第 7.4 节）。
- N22：25% 阈值只经单元测试验证，实机有待第 11a 节第 12 条。协议名、单位留给 U6。
- P2-5：Beta／Canary 共用稳定版根目录的残留（第 10 节）。
- JEV（P2-5 提交，只提交了代码 diff 与测试摘要，没有个人数据）：action=escalate，safe_to_apply=0.32，composite=0.64，correctness 置信度 0。JEV 没有给出理由，**不视为批准**。我随后复查了发现路径，找到上面的 Beta／Canary 残留，属改前已有、未扩大改动。其余各项没有调用 JEV。

## 13. 复核后修改（2026-10-07）

复核（全新复核子代理，区间 `23bd624..25a3f34`）的结论是修后可合并，无 P0／P1。主会话要求合并前必须修 4 项，另有 9 项顺带修（复核编号 P2-1～P2-12，第 4 项是交接更正，P2-12 分两次提交）。按要求留后续、未做的两项：N19“排除最近使用的多个应用”（待产品决定）；N20 小窗清理卡的标题与“可操作项目”残留（另批）。

### 13.1 逐项（红 → 修 → 绿 → 反证）

日志都在 `~/Developer/.sc-build/r2-live-fixes-2/logs/`，以 `r-` 开头。反证前的修复后文件备份在 `mutation-backup/`，每次反证后都已逐字节还原。

| 复核项 | 提交 | 改动 | 红 | 绿 | 反证 |
|---|---|---|---|---|---|
| P2-1 N20 测试隔离（合并前必修） | `414848c` | 见下方说明 1 | 112 个、20 处失败：CleanupRuleScanner 2、CleanupStoreFollowUp 16、SafeCleanupLayout 1、HeavyWorkIntegration 1，全部是 teardown 检查发现测试改了 `.standard` | 112 个，2 个原有跳过，0 失败 | 只去掉 CleanupStoreFollowUp 工厂的注入：25 个、16 处失败 |
| P2-3 并发警告（合并前必修） | `cc257dd` | `SmartScanHistoryTests` 去掉主线程类里由非隔离 setUp／tearDown 读写的存储属性，每个测试从 `ScanHistoryTestDefaults` 取自己的 suite | 改前构建日志里 5 个警告（`SmartScanHistoryTests.swift:18-23`，`r-p2-1-red.log`） | 该文件 0 警告，5 个测试通过（`r-p2-3-green.log`）；覆盖测试目标的严格并发见 13.4 | 改前写法即反证（5 个警告） |
| P2-2 D43 读屏与悬停（合并前必修） | `925a981` | CPU 卡页头加 `.accessibilityElement(children: .combine)`，`.help` 与 `.accessibilityValue`（总占用）挂在合并后的元素上。测试进程里取不到 SwiftUI 的读屏树（复核也验证过），所以用源码契约锁定修饰符和先后顺序 | 4 个、1 处失败 | 相关 8 个测试类共 76 个，0 失败 | 与红状态是同一份源码，红即反证 |
| P2-4 GPU 频率表 | `574fa2b` | 首条关闭态之后出现 (0 Hz, 0 mV) 即进入尾部填充；此后只要再出现工作点就不出数 | 9 个、2 处失败（`[关闭态, 338, (0,0), 486, 636]` 等） | 26 个，0 失败；本机实时仍读出 338 MHz | 9 个、2 处失败 |
| P2-5 整机负载 | `f43e607` | 外接电源时还要求“负载 ≤ 输入 + 电池放电 + max(1 W, 10%)”；电池充电或读数未知时放电记 0 | 7 个、4 处失败（900 W 对 20 W 等） | 能耗相关 172 个，1 个原有显式开启项跳过，0 失败；本机接电实时 57.37 W | 7 个、4 处失败 |
| P2-6 当前功率卡 | `c8873d5` | 见下方说明 2 | 8 个、7 处失败 | 349 个，2 个原有跳过，0 失败 | 去掉 90 s 判断：8 个、3 处失败 |
| P2-7 网速沿用 | `2098940` | 15 s 改按现在计算 | 1 个、2 处失败（10 分钟前的读数仍被沿用） | 115 个，0 失败 | 改回按当前样本时间：6 个、2 处失败 |
| P2-8 “正在采样…”超时 | `e222f4c` | 见下方说明 3 | 2 个、8 处失败 | 80 个，1 个原有跳过，0 失败 | 去掉超时后的状态切换：8 个、3 处失败 |
| P2-9 防抖与英文 | `6a7483e` | 防抖 = max(0.6 s, `NSEvent.doubleClickInterval`)；英文确认文案改为 “These apps will quit normally: … the memory freed is measured again after they quit.” | 7 个、3 处失败 | 37 个，0 失败 | 防抖不跟随系统设置：7 个、1 处失败 |
| P2-10 扣除本进程 CPU | `db1d666` | 见下方说明 4 | 7 个、3 处失败 | 62 个，0 失败；`BenchmarkBackgroundLoadTests` 7 个复跑通过（`r-p2-10-green2.log`） | 去掉扣除：7 个、2 处失败 |
| P2-11 根目录绑定（方案 b） | `c30e8ef` | 描述符新增 `rootBundleIdentifiers`；稳定版 Chrome 配置根目录只认 `com.google.Chrome`；Beta／Canary 的 Team ID 仍不固定（本机未核实） | 3 个、5 处失败（Beta、Canary 各配两个 Team ID 都能写稳定版根目录） | 浏览器隐私与签名身份 189 个，1 个原有跳过，0 失败 | 去掉绑定检查：3 个、4 处失败 |
| P2-12 采样器改为初始化时注入 | `973580d` | `ScanStore` 的进程采样器改回 `private let`，由 init 参数 `menuBarProcessSampler` 注入（基线就是 `private let`） | 重构，无行为变化，不适用 | 39 个，1 个原有跳过，0 失败 | 不适用 |
| P2-12 路径缓冲区复用 | `f083c58` | 见下方说明 5 | 重构，无行为变化，不适用 | 53 个，1 个原有跳过，0 失败；新增复用正确性测试 | 不适用（分配次数不可观测） |

表中较长的改动说明：

1. **P2-1**：新增测试工具 `ScanHistoryTestDefaults`。
   - 它给每个能跑完扫描的夹具一个独立 suite，teardown 时删掉；
   - 同时在 teardown 检查 `.standard` 的 `scan.history` 不变，夹具漏传 suite 时测试会失败，不会再写进去。
   - 接入的夹具工厂：`CleanupRuleScannerTests` 新工厂 `makeScanOnlyStore`（2 处）、`CleanupStoreFollowUpTests` 的 Fixture、`SafeCleanupLayoutTests.makeSmartScanContext`、`HeavyWorkIntegrationTests` 的旧版全盘扫描（1 处，改前就写）。
   - `SmartScanHistoryTests` 增加显式断言。
2. **P2-6**：
   - 没有样本时说明写“暂无当前读数”；
   - 样本按其墙钟时间超过 90 s，就隐藏数值，说明写“暂无当前读数（上次读数 时:分:秒）”；
   - 卡片放进 `TimelineView` 每 15 s 重算。
3. **P2-8**：
   - 超时时长 5 s（`processSampleTimeout`，可由 init 注入）；
   - 超时后 CPU、磁盘进程表头显示“未测量”，帮助文字后缀写原因，空列表处写“未取得进程数据”；
   - 采样继续，之后到来的测量照常显示。
4. **P2-10**：
   - 用 `getrusage(RUSAGE_SELF)` 读本进程 CPU 时间（用户＋系统），求同一 1 s 窗口内的差，按主机 tick 速率（`_SC_CLK_TCK`=100）换算成 tick 后扣除；阈值保持 25%。
   - 实测本机主机计数器约每秒成批更新一次（每次约 1772 tick，18 核 × 100 Hz）。因此窗口内累计不足“全部处理器半秒”（本机 900 tick）时不出比例。
5. **P2-12 缓冲区**：
   - 每次采样用一个 `ExecutablePathReader`，复用一块 4 × MAXPATHLEN = 4096 字节的缓冲区（复核写 16 KiB，实际 4 KiB），按内核返回的长度截取。
   - 测试锁定“先读长路径、再读短路径”不残留。

### 13.2 对复核第三节 6 处说法的更正（已在原位改正）

| 原说法（位置） | 与代码不符之处 | 现在 |
|---|---|---|
| “`scanHistoryDefaults` 可注入，供测试隔离”（7.2） | 只有新测试类注入了隔离 suite，既有测试仍写测试进程的 `UserDefaults.standard` | `414848c` 起所有能跑完扫描的夹具都注入独立 suite，teardown 检查 `.standard` 不变 |
| “夹在中间的 0 Hz……都不出数”（2.3） | 只对电压非零的记录成立；(0 Hz, 0 mV) 被当作填充跳过，后面的工作点会错位 | `574fa2b` 起全零记录只能出现在末尾 |
| “沿用上次读数（最长 15 s）”（结论表、4.2） | 15 s 按当前样本的时间算，不是按现在 | `2098940` 起按现在算 |
| “严格并发 0 错误 0 警告”（结论、第 11 节） | 只覆盖非测试目标；测试目标有 5 个新警告 | `cc257dd` 消掉；覆盖测试目标的结果见 13.4 |
| “总占用保留在悬停说明与读屏值”（结论表、7.1） | 没有验证；值挂在没有 `.accessibilityElement` 的 HStack 上 | `925a981` 合并为一个读屏元素并用源码契约锁定；仍需实机 VoiceOver 核对，悬停提示可能被悬停即开二级页抢先 |
| “扫描时与写入前都走这里”（第 10 节） | 成立，但写入前用的是扫描时读到的签名身份，没有重新读取 | 说法已补全；本批未改这一点（见 13.5） |

### 13.3 本轮改动的测试

- **既有契约测试**：本轮没有修改。
  - `CleanupRuleScannerTests`、`CleanupStoreFollowUpTests`、`SafeCleanupLayoutTests`、`HeavyWorkIntegrationTests` 只是给夹具传入独立 suite，没有改任何断言。
  - `GeekHoverDetailTargetTests` 锁定的“按需快照 · \(geekOnDemandSnapshotStatusText)”保留不动，原因接在它后面。
- **本批自己的测试随修复调整的**：
  - `MemoryQuitConfirmationTests.testTheDebounceCoversADoubleClick`：原来断言防抖 ≤ 1 s，用户把双击设得慢时会误报；改为断言跟随系统设置的纯函数（P2-9）。
  - `MiniWindowLiveReadingRetentionTests.testTheOverviewNetworkRatesKeepTheLastReadingOnASecondaryPage`：第三步原来用一个未来 60 s 的样本代表“读数很久以前”；改按现在计算后，改为上次读数在真实时钟的 60 s 前（P2-7）。
  - `SystemEnergyACTelemetryTests`：`currentPowerDetail` 由属性改为带时间的函数（P2-6）。
  - `BenchmarkBackgroundLoadTests`：直接调用 `busyRatio` 的断言显式给出窗口下限，避免核数更多的机器上默认下限超过测试窗口（P2-10）。
  - `BrowserPrivacyTeamIdentifierTests`：夹具应用按渠道使用不同路径。`Bundle(url:)` 按路径缓存，同一路径重建的包会读到旧的标识，导致假通过。

### 13.4 命令与结果

环境同第 11 节（`--jobs 4`）。各项定向测试见 13.1。

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| Debug 全量（`f083c58`） | `swift test` | 0 | 3498 个执行，21 个跳过（与之前两次全量逐类相同），0 失败；测试耗时 195.4 s，总 3 分 19 秒（11:36:43–11:40:02）；负载 8.2→5.4；没有计时项失败 | `r-full-test.log`、`.meta` |
| 严格并发，含测试目标（`f083c58`） | `swift build --build-tests -Xswiftc -strict-concurrency=complete`（strict scratch；测试目标在该 scratch 首次完整编译） | 0 | 0 错误；并发警告 0；唯一 1 条警告是 `BrowserPrivacyRecoveryTests.swift:474`“no calls to throwing functions occur within 'try' expression”，不是并发警告，该文件在本批区间没有提交，属基线已有；69.1 s；负载 5.0–7.1 | `r-strict-tests.log`、`.plain.log`、`.warnings.txt`、`.meta` |
| 私有 API | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `r-guards.log` |
| `verify.sh` 的源码检查 | Views 不启动进程、内存功能不调用 purge、没有冲突副本 | — | 都没有匹配，PASS | `r-guards.log` |
| 空白检查 | `git diff --check 23bd624 HEAD` | 0 | — | `r-guards.log`；本交接提交后再跑一次 |

NOT RUN（主会话门禁或实机）：Release 全量、`script/verify_menu_bar_performance.sh`、打包、安装、启动应用、实机核对。

### 13.5 仍未解决

- 按要求留后续：N19 排除最近使用的多个应用；N20 小窗清理卡标题与“可操作项目”残留。
- **测试域里已有的扫描历史**：测试进程的标准偏好域 `com.apple.dt.xctest.tool` 仍留着此前运行写入的 `scan.history`，来源如下：
  - 本批 09:47 的全量测试写满 60 条；
  - 复核写了 2 条；
  - 本轮 P2-1 的红测试和反证运行又写入了一些（按 60 条上限轮替）。

  本批不删除数据，请主会话决定是否清理（例如 `defaults delete com.apple.dt.xctest.tool scan.history`）。

  这个域由本机所有 `swift test` 进程共用：
  - 本分支 11:36–11:40 的全量测试没有写入任何记录（最新一条的时间早于这次运行）；
  - 最新一条（11:26:47，0 项，磁盘 500/500）与 `HeavyWorkIntegrationTests` 旧版扫描夹具一致，写入时并行批次 r2-files-fixes 的全量测试正在运行（11:28 结束）。

  尚未合并本修复的分支，测试仍会写入这里。
- **P2-2 读屏**：只能实机用 VoiceOver 或“辅助功能检查器”核对（第 11a 节第 10 条）。
- **浏览器写入前不重新读签名**（复核 §8）：写入前用的是扫描时读到的签名身份，没有重新读取。本轮没有改，如需要可另立一项。
- **Chrome Beta／Canary 的 Team ID**：仍未固定（本机未安装，未核实）；稳定版根目录已不受它们影响。
- **P2-10 的近似**：主机 CPU 计数器约每秒成批更新一次。1 s 窗口内的 tick 差与本进程 CPU 时间差不一定精确对齐，比例是近似值；窗口不足半秒时不出比例，此时只看原有的负载平均规则。
- **决定待主会话补记**，在第 12 节之外新增：
  - 防抖跟随系统双击间隔（下限 0.6 s）；
  - “正在采样…”5 s 超时；
  - 当前功率 90 s 时效；
  - 整机负载必须有能量来源；
  - 后台负载扣除本进程（阈值 25% 不变）；
  - 稳定版 Chrome 根目录只认稳定版 bundle ID。
- **JEV**：本轮未调用。
