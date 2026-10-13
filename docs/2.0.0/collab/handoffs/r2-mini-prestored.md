# r2-mini-prestored · D74 小窗后台预存

2026-10-10；worktree `~/Developer/sc-worktrees/r2-mini-prestored`；分支 `task/r2-mini-prestored`；基线 `5b07771309f7b6cae027eca60405e95e352a9d51`（包含 D73 风扇/充电恢复和 B4）。开始时工作区干净。已读 `common.md`、`codex-build-common.md`、RULES、BOARD、D5/D39/D48/D55/D60/D71/D74、`r2-mini-sampling.md` 原交接及其追加复核、原 `MenuBarPerformancePolicy.swift`。本批以 D74 局部替代 D71④ 的“不可见即停刷”，保留分档、合并和真实源时间约束。

用户原话：“为什么 CPU 数据是现场采样呢？而不是已经采好样？我希望这些数据是已经储存好的，而不是每次点开都进行现场采样。”

## 数据盘点

下表的“改前”均指本批基线；“隐藏”指 App 的菜单栏常驻控制器运行、面板不可见。“等待”区分首次尚无读数、切页重新启动读数、图表点不足、平台不支持四种情况。单位、来源和推断标记沿用已有实现。一级、二级、三级和悬停复用同一数据源，逐项列出消费位置，避免把同一源误当成多个采样器。

| 层级 / 数据项 | 来源、原日期 / 缓存 | 改前隐藏行为 | 改前打开等待 | D74 后隐藏行为与展示 |
|---|---|---|---|---|
| 一级 CPU；CPU 二/三级与悬停：总占用、用户/系统占用 | `SystemMonitorSampler`，`host_processor_info` / aggregate fallback，`CPUUsageBreakdown` | 依赖所选状态栏/可见卡片需求；离开 CPU 会重置基线 | 无基线时 `—`，需下一次 delta | 5 s；持续保留 CPU 基线，打开使用已存 snapshot 与原日期；仅启动尚无 delta 时等待 |
| CPU 二/三级：逐核、P/E 核组占用 | 同一次内核 CPU ticks，`cpuCoreUsagePercent`；组统计由已存每核数据派生 | 同上，没有独立常驻每核采样 | 空值 / 无趋势 | 5 s；不为逐核再读一次内核；保留历史，点不足说明“趋势数据不足 · N 秒前” |
| CPU 二/三级：负载 1/5/15 分钟、开机时间、运行时间、系统热状态 | `getloadavg`、boot sysctl / `ProcessInfo`，snapshot | 随 primaryKinds | 未取得时 `—`；不是子进程等待 | primary 5 s；静态硬件型号/核数仍复用已有静态来源 |
| CPU/GPU 二/三级与悬停：GPU 占用、GPU 内存 | `GPUPerformanceService` 的 IORegistry 读取，`gpuSampledAt` | 隐藏 GPU 不在 plan，原缓存清除 | 首轮硬件任务未返回时 `—` / 空图 | 5 s；源任务单条在途；展示保留上一实际 GPU 日期，不把廉价发布时刻冒充 GPU 日期 |
| CPU 二/三级：簇频率、频率上限/性能状态等 IOReport 遥测 | `CPUPerformanceStateService.currentSnapshot()`；不可用时 `staticSnapshot()`，`processorTelemetryRefreshedAt` | 无可见 consumer 停止；可见至少 5 s | `—` / 首次遥测缺失 | 5 s；动态读取及静态 fallback 均在后台；fallback 返回前不释放源锁 |
| CPU / 磁盘 / 能耗三级：进程 App 名称、PID、CPU%、App 功率、读写速率、活跃 App 数等 | `MenuBarProcessSampler` → `EnergyImpactService.menuBarCounterFrame()`（有界 `ps` + libproc counters）→ `MenuBarPreparedProcesses`，`snapshot.generatedAt` | 仅对应三级可见时 10 s；离开重置 sampler | `ScanStore.isMenuBarProcessSamplePending`；GeekPanel 的“正在采样…”/“采样中”；磁盘 807 附近等待行 | 隐藏 15 s、可见 10 s；一套 frame 服务 CPU/磁盘/能耗；第一次基线后 0.5 s delta；切页不清样本/基线；原 Top5 过滤排序保持 |
| 内存一级/二级/三级/悬停：物理、已用、应用、wired、压缩、缓存、空闲/可用、swap、swap in/out、压力 | `SystemMemoryProbe` / `MemoryOptimizerService.statusSnapshot`，VM/sysctl，无进程枚举；`menuBarDisplayMemorySnapshot.generatedAt` | 所选状态/可见内存需求刷新；其余保留旧值 | 首次为空；原内存时刻文案为 HH:mm；压力 sysctl 失败显示不可用 | 5 s 的共享 primary tick；后台状态读与进程枚举分开；“N 秒前”，暂停/过期/不可用语义保留 |
| 内存二/三级：按 App 分组 RSS、进程数、可退出 PID、建议项 | `SystemMemoryProbe.snapshot(includeProcesses: true)`，`appsByResidentUsage`；prepared groups 与 `menuBarPreparedMemoryAppsSampledAt` | 只有可见内存进程需求才能刷新 | `MenuBarAdvancedComponents.swift` 首次采样中；已存主快照可能较旧 | 隐藏 15 s / 可见 10 s；分组在后台预存、有界；隐藏时不覆盖主窗口内存快照、选中项、退出确认或优化状态；显示缓存到达不代表已允许退出 |
| 磁盘一级/二级/三级/悬停：系统磁盘总量、已用、可用、比例 | `StorageCapacityService`，`storageRefreshedAt` | 只有可见容量需求；原容量 30 s | 首次 `—` / 空图 | 容量 5 s；首次在隐藏时预热；容量与 I/O 独立源时间 |
| 磁盘二/三级：挂载卷列表、卷名称/路径/容量等 | `StorageVolumeService`，同一个 storage worker | 可见需求，卷元数据 300 s 缓存 | 未取得列表/空行 | 隐藏首次预热；卷枚举保留 300 s 元数据 TTL，容量读 5 s；不把慢变卷枚举提升到 5 s |
| 磁盘一级/二级/三级/悬停：整机读写 B/s 与历史 | `DiskIOService.counters()` 的 IOKit 累计 counters，实际 elapsed 求差，`nativeDiskIOHistory.last.date` | 正式 context 下隐藏停读；standalone 后台历史分支另有 60 s | 新基线未形成速率时 `—` / 图表正在采样 | 合并到共享 tick，5 s；隐藏/显示不重置；睡眠重置 baseline；只有真实 delta 写历史 |
| 磁盘三级：SMART、寿命/磨损、磁盘温度与诊断 | `ComputerHealthStore` 已有启动健康检查 / 显式刷新快照；SMC 温度属于传感器源 | 既有启动预热与缓存，不是逐次开窗全面检查 | 未支持/未检测仍为未知；不是现场 CPU delta | 沿用启动缓存与显式刷新；SMC 温度 5 s；不增添 5 s SMART 全检 |
| 网络一级/二级/三级/悬停：整机上下行、会话累计、速率图 | `SystemMonitorService.currentNetworkSample` 内核接口累计，network baseline；历史/`MenuBarNetworkReading.date` | 所选状态栏 / 可见需求；断开需求清 baseline | 开窗首轮 delta / 超过原 15 s readout 保鲜期返回空 | 内核 counters 5 s；保留 baseline 与最后读数；居民模式超龄仍显示原日期；standalone 原 15 s freshness 行为保留 |
| 网络二/三级：接口、连接、Wi-Fi/SSID、IPv4/IPv6、MAC、路由/DNS、链路/信号/频段/信道/拓扑等已有详情 | `NetworkInterfaceService`、既有 topology snapshot 与通知；`networkInterfaceRefreshedAt` | 可见需求，接口元数据 60 s；拓扑通知防抖 | 首次缺失或受隐私权限限制时未知 / `—` | 隐藏首次预热；慢变接口元数据保留 60 s 与变更通知；状态栏 Wi-Fi 廉价读 5 s（低电量共享 tick 30 s） |
| 网络三级：逐 App 上下行、活跃进程 | `NativeNetworkProcessService`，有界 `nettop` / native provider，`networkProcessSnapshot.generatedAt` | 仅网络进程可见需求 10 s | 首次 `.sampling` / “采样中”；原刷新失败清列表 | 隐藏 15 s / 可见 10 s；有样本刷新时保持可见；居民刷新失败保留上一原日期，独立显式 probe 的失败清空语义保留 |
| 网络二/三级：公网地址 / 既有地点字段 | `PublicNetworkAddressService`，`publicNetworkAddressSnapshot.generatedAt`，已有许可与网络 signature | 有可见需求且已许可；15 min 有效缓存，失败重试 60 s | 未许可、首次请求、服务失败分别提示；不伪造公网地址 | 隐藏首次仅在原许可成立时预热；保留 15 min / 60 s 和网络变更失效；未许可绝不请求 |
| 传感器一级/二/三级/悬停：芯片、CPU P/E、GPU、RAM、SSD、机壳/环境、电池/充电线路等已支持温度及细分传感器 | `SystemMonitorService.temperatureAndFanReadings`，Native SMC/HID；`temperatureReadings` / details / 推断 zone；`sensorSampledAt` | 只有状态栏温度或可见需求；隐藏选中温度原 15 s | 开窗 SMC 首次 `—` / `.sampling`，原源日期过期后清空 | 5 s；保存读数、来源/推断标记和源日期；展示允许旧值带年龄，源历史仍拒绝把旧值当新点 |
| 传感器二/三级：风扇 RPM、数量、身份、min/max/target、零 RPM；环境光 | 同一个 SMC/HID 读，`fanReadings`、`ambientLight` | 无可见 consumer 停读；手动风扇安全读可 2 s | 首次等待；不支持/无法读是未知，真实零保留 | 常规 5 s；已有手动风扇安全档 2 s（低电量 30 s）；不改风扇写入/恢复逻辑 D73 |
| 风扇/功率/电池控制详情：助手连接、版本、可达状态 | `FanControlCoordinator.refreshConnection()`，既有只读 XPC；源自己拥有状态 | 开窗按 5 s gate 读 | 可见连接检查；无助手不是“首次 CPU 采样” | 与共享调度器的 per-source gate 合并，隐藏 60 s、可见 5 s、低电量 180 s；不安装/授权助手 |
| 电池一级/二/三级/悬停：是否存在、百分比、AC/电池、充电/满电、运行时间等 | IOPowerSources / `BatterySnapshot`；`batteryRefreshedAt` | 设备状态可读；后台电池能耗历史约 30 s | 首次/无内置电池/未知分开 | 5 s；无电池不显示伪零；已存值 + 年龄立即展示 |
| 电池二/三级/悬停：电压、电流、实际输入/输出功率、温度、容量/健康/循环/condition、适配器功率/电压/电流/名称等原字段 | `NativeBatteryElectricalService` 经 `MenuBarBatteryElectricalCache`，IORegistry/SMC；原 `generatedAt` | 无可见电气需求时约 30 s 电池历史读 | 首次缺失 / “—”；能力缺失为未知 | 5 s，与上述电池 worker 合并；实际 elapsed 积分；历史仍按 D39 28 天保留 |
| 电池控制：系统充电上限、暂停与“本次充到 100%” | `BatteryChargeLimitReadCache` 与原服务 / 用户操作 | D5 限制下隐藏不 reconcile、不解除暂停 | 原助手/读取能力状态 | 隐藏仍不读取/调和此控制服务；只保留已有值，可见明确需求才走原读取；本批未新增任何充电写操作 |
| 电池/功率三级：整机/部件 SMC 功率、显示背光与既有能耗模型数据 | `NativePowerTelemetryService`，SMC/backlight/IOReport，`powerTelemetryRefreshedAt` | 仅可见 power consumer，5 s | 首次未知；macOS 冻结能耗模型时不可用 | 5 s 后台只读；模型不可用仍如实标示，不用 CPU% 补功率 |
| 功率三级/详情：CPU/GPU/ANE W、簇 MHz、GPU MHz、采样 duration/source | `HelperPowerMetricsMonitor` → 既有助手固定只读 powermetrics 命令；`state.sampledAt` | 仅可见 consumer 2 s；关闭会改为 sampling；旧 6 s presentation age 过期 | `HelperPowerMetricsPresentation` 的等待/未测量；无助手/更新/授权缺失各自状态 | 隐藏 60 s、可见 5 s、低电量 180 s；单条物理请求在途；成功值带原日期；暂时失败保留值并附失败详情；助手不适用仍标示真实原因 |
| 电池控制：AC/电池低电量/高性能模式等原设置 | `ComputerHealthStore.refreshBatteryPowerModes()`，既有只读 pmset/助手路径 | 可见 gated metadata read | 初次设置未知 | 隐藏 60 s、可见 5 s、低电量 180 s；与可见请求同 key/gate；不写设置 |
| 健康、稳定性、安全摘要及上述硬件诊断补充 | `ComputerHealthStore.prepareMenuBarHealthOnLaunch()` 已在启动调用；已有健康/安全检查缓存 | 既有启动预热，不是打开小窗才开始全量扫描 | 首次检查 / 不可用仍如实标示 | 保留启动缓存与显式检查职责；不修改非小窗健康/安全模块行为 |
| 全部二/三级、悬停趋势：CPU/每核、内存、磁盘、网络、温度/风扇、电池电气与能耗等已支持历史 | `MetricHistoryStore` / `MenuBarMonitorState`、PowerHistoryStore 与派生图表缓存 | D39 28 天窗口存在；停源造成 gap | `PanelChartSampling`（至少两点且跨度≥6 s）；有读数但历史不足也曾写“正在采样…” | 原 28 天、gap、归一化规则不变；有当前样本就提示趋势不足 + 原年龄；不复制缓存点伪造连续线；helper 增加有界实际成功样本内存历史 |

入口与等待审计：`ScanStore.isMenuBarProcessSamplePending`；`PanelChartSampling.placeholderText`；`MenuBarGeekPanel.swift` 原 94（进程时刻）、466（App 能耗 source）、550 附近（详细页内容）；`MenuBarAdvancedComponents.swift` 原 49（内存状态）；`GeekDiskView.swift` 原 807（进程加载行）；`HelperPowerMetricsPresentation`。这些等待分支仍保留给 App 本次启动从未采到相应样本的情况。真实不支持、权限拒绝、无电池、断网、解析失败不转成假零或“已采样”。既有进程首次 5 s 超时后显示“未测量”及原因，避免永久等待。

## 调度和缓存

唯一常驻时钟仍为 `MenuBarStatusController.refreshTask`。状态/页面变化更新 plan，不重启或推迟既有截止时间。`ScanStore.refreshMenuBarResidentSamples` 启动有限的后台 worker；辅助来源只执行到期的一次读取，不创建独立居民 timer。UI 的 Timeline 只在显示时更新年龄/绘制，standalone 服务的显式 demand 路径保留，正式居民 context 接入后不启用其循环。

| 情况 | primary 廉价读 | GPU/SMC/电气/IOReport | CPU/磁盘/能耗、内存、网络进程 | 固定 helper 功率 / 连接/模式元数据 |
|---|---:|---:|---:|---:|
| 隐藏、正常电源 | 5 s | 5 s | 15 s | 60 s |
| 可见、正常电源 | 用户 1/2/5 s | 5 s | 10 s | 5 s |
| 隐藏或可见、低电量模式 | 30 s | 30 s | 60 s | 180 s |
| 系统睡眠、屏幕关闭、用户暂停 | 暂停 | 暂停 | 暂停 | 暂停 |

数值集中于 `MenuBarPerformancePolicy` / `MenuBarSamplingCadence`。5/15/60 是低频预算，三档均能在一个 5 s tick 上对齐；枚举/子进程降低到三次 tick 一次，固定 helper 降到十二次 tick 一次。低电量 30/60/180 延长全部档位。手动风扇原安全读取 2 s 保留，低电量随 30 s 档位。这些依据是 D74 成本限制与 D71④ 分层，并非已实测的能耗改善结论。慢变挂载卷/接口/公网数据保留上述元数据 TTL，避免昂贵枚举跟随 5 s。

睡眠依据是 `NSWorkspace.willSleep/didWake` 和 `screensDidSleep/screensDidWake` 两组通知；独立记录系统/屏幕标志，必须两者恢复才重启时钟。睡眠取消时钟和有限 worker，generation 拒绝 primary、进程、磁盘、GPU/SMC、helper 的晚到数据；物理读没有退出前不释放其 single-flight。CPU/网络/磁盘 delta baseline 重置，醒来不跨睡眠虚构速率；展示缓存保留原年龄。已提交的只读连接/pmset 元数据请求可以返回到原 owner，但睡眠期间不再发起新请求。未使用 power assertion、`beginActivity`、caffeinate 或禁止睡眠 API。

进程 baseline/frame、prepared processes、prepared memory groups、helper 成功历史各自使用派生缓存 32 MiB 的 1/4，即 **8 MiB** 保守 payload 上限；进程 count 上限 **4096**。PS 原输出体积上限保持。超限进程 frame/快照拒绝保留，内存分组按上限截断，helper 历史逐点驱逐。估算涵盖固定行开销、双倍 UTF-8 字节和 PID 数组，属于保守缓存成本预算，不承诺等同实际 RSS。历史图表仍遵循既有 D39 28 天、点数/派生页上限；派生图表仍 32 MiB / 四页。没有新增无限进程列表历史。

原硬件 sampler 的 freshness 与历史过滤保留；单独的展示合并方法 `retainingStoredHardwareReadings` 保存旧 GPU/SMC 日期和字段，只供 presentation，不写历史。CPU 基线恢复期沿用上一完整实际 snapshot；没有把“显示一次”当成“新样本一次”。

居民电池和容量读数遇到暂时读取失败时保留最后成功值及其日期，失败不追加历史。另存 attempt date，失败重试仍遵守 5/30 s 档位，不因成功日期变旧而每个可见 tick 重试。已确认硬件不存在的电池状态仍如实更新。既有 `SystemEnergyAccumulator` 的 30 s 积分 gate 未改；采样/电池历史 5 s 和累计积分 30 s 是不同职责。

## 文件与行为边界

- policy/plan/primary sampler：隐藏需求独立于状态栏选项；保留每核 baseline、硬件源日期、sleep discard gate。
- ScanStore/controller/auxiliary：同一个时钟派发有限 worker；可见进程需求只管展示和既有归因，不再清后台样本；内存 owner/退出选择与 D5 充电控制边界保持。
- helper monitor：使用居民 cadence，单条在途；原固定助手命令/协议/调用参数、授权检查、超时和输出上限未改；成功值/有界实际历史保留。
- 展示：一级概览与二/三级框架增加样本年龄，卡片/趋势用相应 domain 原日期；已存进程、内存、网络、helper 不因开窗变成空白等待。`GeekDiskView` 的首样本等待行保留，条件由预存源驱动。
- 不改真实清理、卸载、优化、助手协议或 D73 硬件写恢复行为；未启动 App、安装或发布。

## 验证与断言依据

验证结果由最终日志补记。要求的类清单在 scratch `targeted-classes.txt`；新增 `MenuBarPrestoredSamplingTests` 覆盖隐藏/可见/低电量/睡眠矩阵、状态栏关闭仍采样、久未打开立即读原值、源日期分离、首次无样本等待、相对时刻、helper 60→5 s、单条在途/晚到 sleep 回包、失败保留与缓存驱逐、进程预热/切页基线和共享 tick 超时。旧测试没有删断言或跳过新增失败。

旧断言改写理由（均为 D74 明确取代的语义）：

| 原测试区域 | 新预期与保留的反证 |
|---|---|
| `MenuBarSamplingPlanTests` 状态栏/隐藏来源集合 | active 时为全部小窗 defaultSelection；显式暂停/睡眠才空；thermal 隐藏 5 s，低电量 30 s；取消真实在途仍不得重复启动 |
| 原 source leaves / GPU quick reopen | 以显式睡眠或 pause 替代“切到内存等于离开源”；继续断言硬件缓存失效、晚到回包拒绝及快速重开单条在途 |
| 原 hidden battery 30 s / disk 不读 | 居民 tick 5 s 七次实读与七个原日期历史点，磁盘同 tick；既有 accumulator 30 s 独立 gate 不改，满 30 s 仍验证真实 elapsed 积分；charge-limit 调用仍为 0；暂停继续不读 |
| kept primary/hardware age | D74 允许旧值显示；严格保留生成和硬件源日期，不新增历史；原未来时间拒绝保留 |
| HelperPowerMetricsMonitor presentation 超过 6 s | 仍显示真实旧 5 W 和年龄；invalid/unauthorized/needsUpdate、不伪零等断言保持 |
| SystemMonitorService 低电量 visible/custom fan cadence | 30 s；正常用户 1/2/5 s、隐藏 5 s 和手动安全 2 s 不变 |
| PanelChartNormalization 内存 HH:mm | 改为实际 elapsed 秒；暂停/过期≥60 s、无样本、invalid 与真实 0 全部继续断言 |

`counterexamples.json` 为主会话准备的精确文本变异（格式 `{mutations:[{id,path,before,after,expected_occurrences,filter}]}`）。只检查 anchor 次数与测试类/方法存在，本子会话未运行反证或全量套件。原性能阈值、图表两点/6 s、私有 API allowlist 和偏好卫生检查没有放宽。

JEV 判断调用被工具层拒绝：`MCP tool call requires approval, but approval policy is never`。未得到实际模型标识/判断，没有声称 JEV 评估通过。方案和结果依据本地代码与实际构建/测试证据。

## 主会话能耗实测

脚本：`~/Developer/.sc-build/r2-mini-prestored/tools/measure-hidden-cost.sh`。本子会话只做语法与 `--self-test`，未运行任何真实 App 测量。

```bash
~/Developer/.sc-build/r2-mini-prestored/tools/measure-hidden-cost.sh --app /path/to/built-before.app --label before
~/Developer/.sc-build/r2-mini-prestored/tools/measure-hidden-cost.sh --app /path/to/built-after.app --label after
~/Developer/.sc-build/r2-mini-prestored/tools/measure-hidden-cost.sh --compare /path/to/before/summary.json /path/to/after/summary.json
```

指定非 `/Applications` 的 Debug/Beta `.app`，脚本 `ditto` 到本批 scratch，改为应用已认可的隔离 QA id `com.local.StorageCleanerMac.integration`、ad-hoc 签名复制品，设置唯一 integration data root，禁止面板恢复与自动更新。原 App/安装版不变；已有 QA 偏好或另一测量实例则拒绝，不覆盖。结束仅移除本次复制品/唯一 data root；自身 PID 未退出则保留现场。只发正常终止给自身 Popen PID。

相同 30 s 预热后，面板隐藏测 **600 s**；每 10 s `ps`（61 个累计 CPU 点），每个区间 `top -l 2 -s 1`（60 次，使用第二次）记录。主指标 `100 × CPU 时间差 / monotonic 实际秒`，单核=100%；另给 ps 瞬时均值和 top 区间均值。以公开 libproc `proc_pid_rusage` / SDK `rusage_info_v2` 读取 cumulative idle/interrupt/退出子进程 idle wakeups，分别求差；权限拒绝输出 NOT AVAILABLE，不用上下文切换或 tick 数代替唤醒。无需 sudo、不创建唤醒断言。

记录二进制 SHA-256、系统版本、pmset 电源/模式、采样 JSONL、top、App log、performance audit。audit 必须存在 `sampling.plan` 且全程没有 panelVisible=true，否则结果标 incomplete。改前改后必须同一电源来源，均 complete 且满 600 s；比较输出 Markdown 表。主会话还须确保相同低电量/屏幕/工作负载条件；记录两个 run 的 pmset custom；若睡眠中断则重测，不用保持唤醒绕过 D74。

统计范围：CPU 主表只含指定 App 主 PID，不含外部助手或仍运行子进程；退出子进程 wakeups 单列，不能据此称整机耗电。隔离 QA 签名/路径若不被已安装助手授权接受，其功率档可能不可用；不得为实测放宽助手 caller 验证。表格和 audit 来源计数必须同时说明这项覆盖限制。helper 真机完整成本仍由主会话在合法 caller 环境另行复核。

## 主会话提交 / 复核入口

`.git` 只读，scratch `prepared/` 包含分组 patch、完整 patch、提交说明、SHA-256 manifest、`commit-prepared.py`。`--check-only` 是只读基线/分支/文件/补丁检查；`--validated` 仅由主会话在外部验证通过后执行，按组提交。提交说明保留 common 要求的 `Generated-By: Codex (gpt-6.1-sol)` 和 Claude co-author trailer；它是派工要求的 trailer，不是本子会话另行核验运行模型的证据。

## 本轮最终验证（2026-10-10）

构建 **PASS**：按 `codex-build-common.md` 的 Xcode 27 Beta 和沙箱参数，`swift build --build-tests`，最终日志 scratch `logs/build-13.log`（11.18 s）。最后源码变更后重新构建，没有把先前增量构建/链接失败冒充通过；构建中的 Swift 集合类型推断、测试 actor 标注已修正。

定向 **未全绿，沙箱外需复跑**：scratch `logs/targeted-3.log`，17 个指定类，共 **427 tests，7 个原有 skip，12 次 failure（8 unexpected）**。未新增 skip、未改偏好夹具、未放宽产品路径/性能/图表检查。`MenuBarSamplingPlanTests` 28/0；`UIConsistencyRegressionTests` 46/0；`MenuBarPerformanceRegressionTests` 16 个、原有 debug skip 1、失败 0；新增 prestored 类 11 个中 9 个通过，2 个在 factory 创建家目录夹具阶段被阻挡。

全部最终失败归类与具体方法在 scratch `validation-summary.json`，共 **11 个需外部复跑的方法**：

| 类 / 方法 | 最终环境证据 |
|---|---|
| `HelperPowerMetricsMonitorTests.testScanStoreWiringDegradesWithoutRequestingOrAuthorizing` | `TestFileSystem.swift:60` 创建 `~/.storage-cleaner-*/home`，Cocoa 513 / POSIX 1 Operation not permitted |
| `MenuBarPrestoredSamplingTests.testResidentFirstNoSampleWaitsThenBecomesUnavailableOnSharedTick` | 同上，尚未进入 ScanStore 行为断言 |
| `MenuBarPrestoredSamplingTests.testResidentProcessSampleExistsBeforeAnyPageAndReopenDoesNotResetIt` | 同上，尚未进入进程预热/重开行为断言 |
| `MiniWindowLiveReadingRetentionTests.testAReaderThatGivesNothingEndsInNotMeasuredWithAReason` | 同上 |
| `MiniWindowLiveReadingRetentionTests.testTheFirstMeasurementFollowsSoonAfterAPageOpens` | 同上 |
| `MiniWindowLiveReadingRetentionTests.testTheLastMeasurementIsShownAtOnceWhenThePageOpensAgain` | 同上 |
| `MiniWindowLiveReadingRetentionTests.testTheOverviewNetworkRatesKeepTheLastReadingOnASecondaryPage` | 同上 |
| `SystemMonitorServiceTests.testMenuBarMonitorStatePublishesWithoutInvalidatingScanStore` | 同上 |
| `SystemMonitorServiceTests.testLightweightMemoryStatusSnapshotSkipsProcessEnumeration` | headroom `XCTAssertNotNil`；独立 `/usr/sbin/sysctl kern.memorystatus_level` 也返回 Operation not permitted，`logs/sysctl-headroom.log` |
| `TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory` | 两条 plist 创建/落盘断言；同日志 `sandbox_extension_issue_file ...defaults.plist ...Operation not permitted` |
| `TestPreferenceHygieneTests.testTemporarySuiteCanBeReopenedOnAWorkerThread` | worker 重开偏好失败一条；其个别 case 尾行可能写 passed，但错误实际计入类和总汇，不能把它当作通过 |

静态 **PASS**：`git diff --check`、`script/check_private_api.py`（7 个既有 allowlisted uses）、测量脚本 `bash -n` 与 `--self-test`（CPU 时间解析、SDK rusage_info_v2 160-byte 布局）；20 条反证的每个 anchor 出现数为 1、目标测试方法存在。未执行变异。失败保留与 5 s 历史/30 s 积分测试在最终定向通过。

分组为 `01-sampling`、`02-resident-driver`、`03-presentation`、`04-tests-handoff`，24 个工作区文件；scratch 脚本/清单单独记录 SHA-256。`--check-only` 的只读预检结果另存 scratch `logs/prepared-check.log`，核对 HEAD/branch、文件/产物哈希、私有临时 index 下正向应用、当前文件逆向应用，实际仓库 index/commit 不写入。

未提交、未合并、未安装、未实际能耗测量；未运行全量/反证或原生截图。主会话须完成上述环境失败外部复跑、全量/反证、真实打开页面/悬停、睡眠/屏幕关闭/低电量恢复，以及改前改后各 600 s CPU/唤醒实测，再执行 `--validated`。本批不声称实际功耗下降或真机验收已通过。

## fix1（2026-10-10）：保留共享 IOReport 等待约束，迁移静态 fallback 守卫

**判断：原意在 D74 下仍成立，本轮只迁移测试，不修改采样实现。** D74③ 明确保留 D71④ 的分层与合并请求，只改变隐藏时的采样需求；没有授权每次高级菜单刷新另起 IOReport 等待者或独立轮询。主会话 r1 全量唯一失败是 `CPUPerformanceStateServiceTests.testAdvancedMenuRefreshAwaitsSharedSnapshotWithoutDetachedIOReportWaiter`，`full.log:1809` 的旧 `XCTAssertFalse(refresh.contains("Task.detached"))` 命中了静态 fallback worker，不能据此判断新增了 IOReport 等待者。

核对完整数据流：`refreshProcessorTelemetry` 在原 owner Task 中直接 `await CPUPerformanceStateService.currentSnapshot()`；后者等待唯一 `snapshotCoordinator.snapshot()`，由现有 coordinator 合并等待者并维护一个物理 IOReport worker。其 timeout task 是既有的有限超时保护，不是新增的定时采样器。随后 `await Task.detached(...).value` 只执行 `dynamicSnapshot ?? CPUPerformanceStateService.staticSnapshot()`，没有第二次 IOReport snapshot 调用、sleep 或 timer。static fallback 在共享快照返回后开始，读取同一个已初始化 Store 的静态 configuration，必要时读静态 sysctl；不新建动态 IOReport 等待或订阅。Store 首次初始化本来包含共享 IOReport client 的建立，不能把静态路径概括为永远不涉及 IOReport 初始化。居民采样仍由既有同一时钟调用此函数，`processorTelemetryTask` 在静态 worker 被等待完后才释放，原 cancellation/generation/single-flight 保护不变。

fix1 入场快照保存在 scratch `prepared/fix1/entry-r1/`。与入场 SHA-256 对比，r1 的 **18 个生产文件全部不变**；仓库增量仅为 CPU 测试和本交接追加段。既有 coordinator 的 cancellation storm / timeout 单条物理 worker 测试未改。

| 原断言 / 锚点 | fix1 迁移及保留的约束 |
|---|---|
| 以相邻方法名切片整个 refresh | 复用 `r2SourceDeclaration` 的平衡括号提取，方法重排不改变检查范围 |
| `XCTAssertTrue` 包含 shared snapshot await | 保留并定位到 `dynamicSnapshot` 的测量 closure；另断言整个 refresh 只出现一次 `currentSnapshot()` |
| 整段 `XCTAssertFalse(...Task.detached...)` | shared IOReport closure 仍断言无 detached；仅豁免精确为 `dynamicSnapshot ?? CPUPerformanceStateService.staticSnapshot()` 的静态 closure；去掉该精确 closure 后，剩余 refresh 继续 `XCTAssertFalse` 禁止任何 detached |
| 隐含等待 / 调度约束 | 新增断言静态 worker 必须紧接 `.value` 并在共享 await 之后；整个 refresh 禁止 `Task.sleep`、`Timer`、`asyncAfter`、`while`、`repeat` 独立轮询。没有删除测试、降低阈值或新增 skip |

`targeted-classes.txt` 在原 17 类基础上增加 `CPUPerformanceStateServiceTests`（共 18 类），继续包含 `MenuBarPerformanceRegressionTests`、`UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`。`counterexamples.json` 原 20 条的字段完全保留，新增 3 条，均限定到上述 CPU 守卫：

| 反证 ID | 单条变异与预期 RED |
|---|---|
| `io-report-detached-waiter` | 把直接 shared await 包进额外 detached worker；必须被 shared closure / 剩余 detached 检查拒绝 |
| `io-report-static-worker-becomes-waiter` | 把静态 fallback 换为第二次 `currentSnapshot()` await；必须被一次 shared 调用与精确静态 body 检查拒绝 |
| `io-report-independent-timer` | 在同步 refresh 内、owner Task 创建前加 repeating Timer；必须被禁止独立轮询的检查拒绝 |

红／绿／反证：r1 外部 `full.log:1809` 是已观察 RED；fix1 沙箱定向中同一方法通过是已观察 GREEN；主会话需逐一应用新 3 条变异，以正常编译后该方法的断言失败为 RED，再恢复源码验证 GREEN。新反证只做了 23 个 anchor 的单次出现数和测试方法存在检查，**未执行变异**，不能把原 20/20 当成新 23/23。

| 验证对象 | 实际结果及日志 |
|---|---|
| 主会话 r1 定向 | `logs/main-final-1808/targeted.log`：427 项、2 skip、0 失败 |
| 主会话 r1 反证 | `logs/main-final-1808/mut/summary.json`：原 20/20 PASS |
| 主会话 r1 全量 | `logs/main-final-1808/full.log`：4508 项、25 skip、1 失败；就是本次迁移的旧 source 断言 |
| fix1 沙箱构建 | `logs/fix1/build.log`：`swift build --build-tests` PASS，25.56 s |
| fix1 沙箱 CPU 类 | `logs/fix1/targeted.log:61-99`：17 项、2 个原有硬件不可用 skip、0 失败；共享 coordinator timeout / cancellation storm 测试通过 |
| fix1 沙箱扩展定向 | 同日志：444 项、9 个原有 skip、12 次 failure（8 unexpected），29.388 s；不是全绿 |
| fix1 静态与补丁 | 23 个 anchor/filter PASS，原 20 条不变、18 生产文件 SHA-256 不变；`--check-only` 核对基线、文件哈希、完整补丁与增量补丁的正反向应用；详见 `prepared/fix1/static-checks.json` 和 `logs/fix1/prepared-check.log` |
| fix1 全量 / 新反证 / 真机 | 本子会话均未运行，交主会话；r1 外部结果不能替代 fix1 结果 |

扩展定向的 12 次 failure 与 r1 沙箱同类：8 个方法在 `TestFileSystem.swift:60` 写 `~/.storage-cleaner-*/home` 时 Cocoa 513 / POSIX 1；`SystemMonitorServiceTests.testLightweightMemoryStatusSnapshotSkipsProcessEnumeration` 的 headroom sysctl 受限（既有独立 `logs/sysctl-headroom.log` 为 Operation not permitted）；两个偏好卫生方法共 3 条 plist/worker 重开断言失败，日志包含 `sandbox_extension_issue_file ...defaults.plist ...Operation not permitted`。完整方法名、分类和日志位置在 `logs/fix1/validation-summary.json`。未修改夹具、偏好或产品路径保护。fix1 JEV 判断调用被工具授权层拒绝：`MCP tool call requires approval, but approval policy is never`，没有获得判断。

主会话定向命令（Xcode 与 flags 同 `codex-build-common.md`；这里包含本次新增 CPU 类）：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-mini-prestored/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' ~/Developer/.sc-build/r2-mini-prestored/targeted-classes.txt)"
```

外部须复跑全量及新 3 条反证（可按更新清单复跑全部 23 条）；其它真机/能耗验收要求沿用 r1。`.git` 仍只读，未提交。`prepared/fix1/fix1-only.patch` 是相对入场 r1 的 **2 文件增量**，用于单独审阅或已有 r1 状态的迁移；该目录 `all.patch` 与 4 组补丁是从 `5b077713` 开始的 **r1 + fix1 完整替代包（25 文件）**。旧 `prepared/` 顶层包保留作 r1 历史，其哈希已过期；主会话最终使用 `prepared/fix1/commit-prepared.py --check-only`，外部验证后才使用同脚本 `--validated`。两种补丁不可重复应用。

## merge（2026-10-10）：D74 与 B6 共享概览合并

主会话报告 r1+fix1 已提交 `40cefc1f..859d4ffb`，沙箱外定向 444/0、全量 4508/0、反证 23/23。此次入场 HEAD 为 `859d4ffb4eaec1eaea027c8db3c47a1f87558f1e`，MERGE_HEAD 为 `f17d04155eebc845f96dbb1412d190e228da7124`（集成分支，含 D73、B4/B4-P2、B6、B7、B5）。以上是合并前结果，不作为本次合并树通过的证据。

只编辑 `MenuBarGeekPanel.swift` 和本交接追加段。保留 B6 的 `GeekOverviewPanel(modules:) { empty } content:`，每个真实模块仍通过 `liveCard` 接入原数据；不改共享组成、设置模拟预览、采样服务、历史或任何自动合并的测试。入场记录了 **96 个自动合并文件**的 SHA-256，以及真实 index 和 stage 清单 SHA-256；最终核对这些均不变。没有 add、commit、abort；冲突文本已解决，**Git index 中仍为未合并，merge 尚未完成**。

空状态判断：**空概览不显示采样时间行**。当前没有展示任何数据，后台缓存的日期不能被标成空配置的读数日期；D74 的数据＋实际采样时间要求适用于正在展示的数据。保留原设置入口 48 pt 和上下各 8 pt inset，即 304×64 pt。非空且已有真实样本时，在共享模块区之外显示 D74 年龄行，仍使用 `liveCard(.cpu, page: overviewPage)` 与 `MiniWindowStoredSampleAge(monitorSnapshot.generatedAt)`；无样本时不渲染这行，也不预留空白。原首样本等待语义及打开即显示已存值的路径保持。

尺寸与渲染共用 `geekOverviewShowsStoredSampleAge`（非空且日期存在）和同一个 24 pt 行高；实际行显式 `.frame(height:)`，窗口只在该行存在时增加 `24 + sectionSpacing`（共 30 pt）。原模块区只由共享 `GeekOverviewPanel` 添加一次 contentPadding；年龄行仅添加水平 inset。新增监听显示条件的 `onChange`，首样本到达、时间行开始显示时同步窗口尺寸；模块显隐仍走原监听。没有新采样或等待任务。

| 内容 | 设置预览共享模块区 | 真实概览无样本 | 真实概览已有样本 |
|---|---|---|---|
| 全部隐藏 | 304×64 | 304×64 | 304×64，不显示年龄 |
| 六模块全开 | 304×605 | 304×605 | 304×635（605 模块区＋30 实时年龄区） |
| 不展示电池 | 304×535 | 304×535 | 304×565（535 模块区＋30 实时年龄区） |

B6 的 1:1 卡片宽高、间隔、inset、顺序、自然模块区高度均未改变；模拟预览不声称有真实采样时间，因此实时年龄区由真实宿主负责。设置原生 64 组合×日夜及 605/535/64/659 pt 断言保持原值并实际通过；没有通过压缩卡片、叠放年龄或修改断言实现合并。

验证日志为 scratch `logs/merge/`：

| 验证 | 实际结果 |
|---|---|
| `swift build --build-tests` | PASS，exit 0，210.84 s，`build.log` |
| 30 类定向 | 526 项、9 个既有 skip、23 次 failure（8 unexpected），exit 1，55.583 s；`targeted.log`，未全绿 |
| SettingsMiniWindowPreviewTests | 8 项：7 PASS；64 组合×日夜与共享真实组成等尺寸、605/535/64/659、颜色环境即时变化、显隐重排、D73 无控制效果均通过；仅隔离偏好重开测试的 synchronize 断言受阻 |
| 设置／布局／D74 守卫 | SettingsLightfieldGeometry 5/0，SettingsLightfieldContract 3/0，SettingsSourceContract 3/0，PanelChartNormalization 83/0，UIConsistency 46/0，MenuBarPerformanceRegression 16 项／0 失败／1 既有 skip，CPUPerformanceStateService 17 项／0 失败／2 既有 skip |
| 23 条反证核对 | 原 JSON 全部字段不变；逐条 before 出现数精确为 1，filter 方法存在；位置和哈希在 `prepared/merge/counterexample-anchors.json`。未运行实际变异 |
| 工作区与补丁 | `git diff --check` PASS；只读核对脚本检查两个授权文件、96 自动合并文件、真实 index、resolved-base→final 补丁正反向及产物哈希；日志 `prepared-check.log` |
| 合并树全量／实际反证／真实开窗 | 本子会话 NOT RUN，由主会话验证；不以合并前全绿代替 |

本次 23 次 failure 分开记录，不放宽断言：8 次家目录操作夹具 Cocoa 513 / POSIX 1；1 次 headroom sysctl 受限（既有独立日志 `logs/sysctl-headroom.log`）；4 次偏好落盘/重开断言，含新增设置预览 synchronize，均有同日志 `sandbox_extension_issue_file ...defaults.plist ...Operation not permitted`；9 次锚点/窗口测试无法取得 NSScreen；**另 1 次** `MiniWindowLevelOneAnchorTests.testCardAnchorsFollowAMoveInsideTheWindow` 的独立 `MovableCards` 夹具在 top=38.5 时回报 773.0/661.0，预期 773.5/661.5，未满足原 `<0.5`。该夹具未调用本次概览宿主，相关自动合并文件未改；偏差原因尚未以沙箱外运行确认，单独列为待复跑，不能算通过。完整 22 个失败方法和 23 个事件见 `logs/merge/validation-summary.json`。未为这些失败修改夹具、跳过、路径保护、性能或几何阈值。

红／绿依据：入场源码的两组冲突标记不能编译，是本轮 RED；清除后含测试构建 PASS，共享预览原生几何与 D74 守卫通过。主会话需要外部复跑 30 类、合并树全量及实际 23 条反证，尤其上述独立锚点夹具；真实开窗核对非空已有样本立即显示原年龄、空配置 64 pt 设置入口、首样本后只增加 30 pt、显隐切换后窗口和级联锚点同步。不要降低误差阈值。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-mini-prestored/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' ~/Developer/.sc-build/r2-mini-prestored/targeted-classes.txt)"
python3 ~/Developer/.sc-build/r2-mini-prestored/prepared/merge/check-merge.py --check-only
```

交付 `prepared/merge/00-merge-resolution.patch`、`resolved-base/`、`final/`、提交说明、manifest、只读核对脚本和证据。`resolved-base/` 是入场自动合并内容仅在两组冲突选择集成分支块后得到的干净比较基线，**不是整文件直接取 theirs**；`entry/` 另存原冲突文本与三 stage blobs。补丁从此干净基线到最终两文件，用于审阅／已选该基线的迁移；当前 worktree 已是 final，不要重复应用。核对脚本须在主会话 stage/完成 merge 之前执行，它不含提交功能。

JEV 本次有界语义判断及代码图项目查询均被工具授权层拒绝：`MCP tool call requires approval, but approval policy is never`。未获得模型判断或索引证据；本轮依据实际源码和日志核对。不安装、不启动真实 App、不运行清理或硬件控制。
