# 小窗采样审计（r2-mini-sampling）

基线 `0bd131b2f6e4debb24e1ffeed9bb9aaba71dd6fc`，2026-10-09。决定依据 D71④、D5、D27、D38、D39、D59⑤。先完成下面的源码审计再改代码。本 Codex 沙箱禁止运行应用、构建和测试，因此**实际耗时、CPU、唤醒次数、修前修后性能数字均 NOT RUN**；下面的成本是调用路径与已有注释，不是本轮实测。

| 源 | 修前频率／触发 | 单次工作及成本边界 | 使用者 |
|---|---|---|---|
| CPU 总量／每核 | 所选 1/2/5 秒，隐藏仍采；低电量隐藏 30 秒；自定义风扇最多 2 秒 | `host_processor_info`，失败才 `host_statistics`；无子进程／XPC。getloadavg、热状态和缓存启动时间同批 | 菜单栏 CPU；一级 CPU；二／三级 CPU 图 |
| 内存状态 | 所选 1/2/5 秒，隐藏仍采 | `SystemMemoryProbe` 的 `host_statistics64`、`sysctl`（压力、swap、memorystatus_level），不枚举进程。D38 的约 0.013 ms 是旧记录，本轮未验证 | 菜单栏内存／设备状态；一级；二／三级内存 |
| 网络上下行总量 | 所选 1/2/5 秒，隐藏仍采 | `getifaddrs` 累积计数，按实际两次样本时间算 B/s；无子进程 | 菜单栏网络；一级；二／三级网络 |
| GPU 负载／显存 | 最少 1 秒，主快照每次都请求 | `GPUPerformanceService` IOKit 注册表；后台物理 single-flight，8 秒显示 watchdog 不会强行取消驱动调用 | 一级 CPU/GPU；二级 CPU；三级 GPU 图 |
| 温度／风扇／环境光 | 消费者存在 2 秒，无消费者 15 秒 | 同批 SMC `SMCFanSpeedService`＋IOHID 温度＋电池电气（又一遍 SMC）＋环境光；12 秒 watchdog 保留旧值，不取消同步驱动 | 菜单栏温度；一级传感器；二／三级；自定义风扇控制安全反馈 |
| CPU/GPU 簇频率 | 可见需求，每 2 秒 | `CPUPerformanceStateService` 缓存 IOReport 订阅、IOKit 频率表；2 秒协调器 watchdog，无 `ps/top` | 一级 CPU/GPU 与传感器；二／三级 CPU／传感器 |
| 启动盘容量／名称 | 任意消费者每 30 秒；手动刷新 | `StorageCapacityService` 与 URL volume 属性；无子进程，但文件系统查询可能慢，独立 detached task | 一级磁盘；二／三级磁盘 |
| 外部／网络卷 | 磁盘页 300 秒 | mounted-volume inventory／URL 属性，可能有网络卷；独立于电池／网络发布 | 二级磁盘卷列表 |
| 磁盘 I/O 总量 | 可见需求 2 秒；隐藏 60 秒 | IOKit 驱动累积字节／操作数，按真实时间差算 B/s；无子进程 | 一级磁盘；二／三级磁盘图 |
| 电池百分比／电气 | 任意消费者 2 秒；隐藏 30 秒；电源变动强刷 | IOPowerSources、AppleSmartBattery 注册表＋SMC B0*。`onBatterySample` 另供真实能耗积分；不写充电 | 设备状态；一级电源；二／三级电源 |
| 充电上限 | 电源页／调板打开、用户操作后立即读；可见最多 30 秒 | 现有 `BatteryChargeLimitReadCache`＋PowerUI 只读查询。后台不读；D5 禁止自动解除暂停 | 一级电源打开的调板、二／三级电源 |
| 整机／SoC 功率、背光 | 电源页 2 秒 | 一批 SMC＋IOKit 背光＋IOReport Energy Model（旧注释约 6 ms，本轮未测）；暂停重置积分基线 | 二／三级电源；真实能耗另由 r2-energy-powermetrics 拥有 |
| Wi-Fi 强度 | 设备状态 5 秒；低电量且隐藏 30 秒 | CoreWLAN 只读；独立 detached task | 菜单栏设备状态 |
| 网络接口／拓扑 | 网络页 60 秒；NWPathMonitor／SCDynamicStore 变化去抖 500 ms | CoreWLAN、SystemConfiguration、Network；无 Shell；系统框架内部 IPC 未实测，不能标为“无 IPC” | 二／三级网络 |
| 公网 IP／国家 | 用户同意后，网络页成功 15 分钟／失败 60 秒，网络签名变化刷新 | URLSession 请求，沿用服务现有超时与体积上限；无 Shell | 二级公网信息、三级网络 |
| CPU／磁盘／功率进程列表 | 修前二级页触发；基线立即读、首个 delta 0.5 秒、之后 max(2 秒, 所选档位) | `EnergyImpactService.menuBarCounterFrame` 每帧先起 `/bin/ps`，再读 libproc rusage；ps 现有 3 秒截止＋1 秒退出等待后 SIGKILL，最后等自有子退出；Top-K 元数据准备；功率归因只用真实采样 | 二级 Top-K 卡片（保留布局与缓存）、相应三级 |
| 内存进程列表 | 修前内存二级触发，之后 max(2 秒, 所选档位) | `MemoryOptimizerService.snapshot(includeProcesses:true)`／libproc；独立任务 | 二级内存进程卡、三级 |
| 网络进程列表 | 修前完整网络二级每 2 秒 | 另一个采样子进程：`nettop -P -L 2 -d -x -n -s 1 -J bytes_in,bytes_out`；约 1 秒测量窗口＋启动／解析；已有 4 秒超时、2 MiB 输出上限、取消检查。项目内没有等价逐 PID 网络速率 API，保留测量口径 | 二级网络 Top-K（保留缓存）、相应三级 |
| 助手连接／电源模式 | 面板 onAppear 一次 | `FanControlCoordinator.refreshConnection`／电池模式服务，含 XPC。连接读取与控制写入不可混同，不新增硬件写操作 | 控制调板与二级控制 |
| 历史窗口／图形缓存 | 可见需求变动时准备；隐藏保留 | `MenuBarDerivedCache` 32 MiB、4 页、64 项；共用 build single-flight。D39 隐藏保留，内存压力清除；5 分钟回收面板但保留历史 | 一级／二级／三级图形 |

修前根因：`ScanStore.performMenuBarRefresh` 固定请求全部指标；辅助 `refreshLocalData` 以“任意消费者”代替容量／电池的具体需求；GPU 在隐藏时仍每 tick 读；后台磁盘／电池历史无菜单栏用途也采；进程在二级启动。`ScanStore.swift` 本批只读，不修改。

测量步骤、修后矩阵和执行命令在本批交接中追加；现有 `--menu-bar-performance-audit=<绝对 JSONL>`、`--menu-bar-latency-script=` 复用。计时只写源标识、时长、集合和层级，不写进程名、PID、地址或原始读数。

## 修后调度（代码预期，尚非实测）

| 状态 | 主采样集合／频率 | 辅助与昂贵源 |
|---|---|---|
| 一级可见 | 菜单栏模式 ∪ 配置中可见卡片；廉价源沿用所选 1/2/5 秒 | 温度／风扇、GPU、簇频率、磁盘 I/O、电池电气为 5 秒下限；容量 30 秒；同 tick 电池电气合并为一遍，缓存保留原时间 |
| 二级可见 | 保持附着一级，加当前页需要的主源 | 当前页功率 5 秒、接口 60 秒、卷 300 秒；连接／模式 XPC 打开时按同源 single-flight／5 秒下限合并；公网沿用成功 15 分钟／失败 60 秒；进程枚举停止，二级 Top-K 卡保留旧结果 |
| 相应三级可见 | 廉价源不改档位 | CPU／磁盘／功率 ps、内存 libproc、网络 nettop 常规 10 秒；ps 首个基线／delta 仍立即／0.5 秒（现有首次体验）；网络 nettop 仍用自身真实 1 秒 delta，不把累计字节当 B/s |
| 面板隐藏，设备状态图标 | 内存每至少 5 秒；Wi-Fi 5 秒 | 30 秒 IOPowerSources 百分比／充电状态；**不读电池 SMC、不调用电气回调、不用旧瓦数续积分、不读充电上限**；其余源停 |
| 面板隐藏，其他菜单栏模式 | 仅所选模式所需 CPU／内存／网络，至少 5 秒；温度模式 SMC 15 秒 | 与图标无关的辅助源停。CPU-only 仍允许内存 facade 首次初始化一个状态样本（返回类型非可选），以后缓存原时间，无重复系统内存读 |
| 隐藏且低电量模式 | 基础 tick／Wi-Fi 30 秒 | 辅助源仍按必要集合；不改可见档位 |
| 状态项关闭显示，面板也隐藏 | 30 秒检查可见性，跳过主采样 | 无图标的电池／Wi-Fi／磁盘／功率／进程停 |
| 已由用户选定自定义风扇 | 保留温度／风扇需求与 min(所选档位, 2 秒) 安全反馈 | 只保持既有控制所需读数；不选择风扇模式、不写充电设置 |

5 秒下限是昂贵源的发起间隔；辅助完成时间受所选基础 tick 与服务耗时影响，正常新鲜度界限为 `源间隔 + 基础 tick + 单次成本`。传感器／GPU原采样时间单独保存，不以廉价快照发布时间冒称新鲜。IOKit 同步调用不可强行取消，隐藏后允许已开始的一遍结束，但不追加新的读数；物理 single-flight 不因显示 watchdog 或隐藏重开而解除。

缓存回放只影响展示，不写成新的历史点。CPU／网络恢复时重新建立差分基线；在首个新 delta 前显示上次可见快照及其原时间，最多沿用原 5 秒占位期限，真实失败随后显示未知。D39 的历史／图形缓存、五分钟回收、内存压力释放规则保留。

`ps` 保留原因：Apple `adv_cmds/ps/print.c` 的 `getpcpu` 使用任务/线程 `cpu_usage`，`tasks.c` 经 task 信息累加；直接拿 libproc 累计 CPU 时间或 PID 枚举无法等价替代这一现有百分比口径。`MenuBarCounterFrame` 另用 libproc 算真实 delta／能耗／磁盘速率。本批按“不改显示含义”保留固定 ps，增加 stdout＋stderr 合计 2 MiB 上限；现有截止、取消、直接子进程身份核对、SIGTERM／SIGKILL和物理退出等待保留。一次性的主窗口能耗扫描也复用此输出保护，但其启动行为不改。源码出处：`https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/print.c`、`https://github.com/apple-oss-distributions/adv_cmds/blob/main/ps/tasks.c`；只核对口径，未复制上游实现。

修前／修后可比较指标：同负载各阶段的源调用次数、相邻发起间隔、单次时长 p50/p95、工作线程累计时长；AppKit draw ack 冷／热／二级／三级／切档 p95、主线程最长阻塞、空占位；进程 CPU／RSS／唤醒与能耗需主会话用其已有测量工具取得，不能从上述工作线程时长推算整机 CPU 或功耗。`prepared/baseline-audit.patch` 只给基线加同一计时探针，避免以修后逻辑冒充原实现。
