# 小窗性能边界（1.10.1）

策略集中在 `MenuBarPerformancePolicy`。总体状态沿用用户原有刷新设置；可见进程以 2 秒为默认下限，用户选择更慢周期时遵从该周期。主窗口的完整检测独立运行。

## 数据与界面

- `MenuBarAdvancedSamplingCoordinator` 按消费者声明当前页面；CPU、磁盘、能耗和内存进程只在需要时读取。概览不预读所有进程，移除一个消费者不能停止其他可见消费者。
- `MenuBarProcessSampler` 一次只读一组计数器，保存连续基线；用实际 uptime 差计算速率。首次、失败、计数回退、PID 身份改变不给出伪造零值。取消后旧任务可以完成底层读取，但不能写回新页面。
- `MenuBarCardModel` 比较值类型指纹，只通知相应卡片。历史准备有独立版本，内存历史不随 CPU 更新而重新发布。
- 视图提交显示意图、消费准备结果；系统读取、进程分组排序、完整历史筛选和桶计算不得进入 body、Canvas 或鼠标事件处理。
- `MenuBarPreparedChartModel` 合并待处理展示请求，仅发布最后仍需要的结果。时钟作为数据版本，不作为图表尺寸配置，刷新期间保留上一帧，避免闪空。
- `MenuBarDerivedCache` 保存派生结果，按页面、数据版本、时间范围、尺寸、比例和图表配置区分。保守核算缓存成本，最多 32 MiB、4 个页面、64 项；同一配置仅留最新版本。该额度是结果复用缓存额度，不是整个进程的内存上限；可见工作集、原始历史和现有独立图标缓存另计。
- 关闭小窗移除可见需求、停图表时钟，隐藏期间不再准备历史窗口；最近一次可见需求已准备好的历史窗口（最多 4 个）保留，下次打开立即显示，按 D32 淡化并显示“更新中…”，新一次需求的窗口准备好后整组替换（D39，取代批次 4b“需求为空即释放全部窗口”）。CPU 总占用、网速等即时读数在历史未就绪或仍是保留窗口时读实时快照，不显示“—”。一级 CPU、网络卡没有坐标行，保留窗口只淡化。保留窗口的实际占用按缓冲区字节核算（`MenuBarDisplayHistoryFootprint`，审计记录 `history.kept`）。隐藏窗口最多保留 5 分钟；回收面板时保留的历史窗口不随之释放（D39 补充）。内存压力回收共享派生缓存、隐藏时保留的历史窗口（只在无可见需求时）和符合回收条件的隐藏窗口，原始历史不删。传感器页用到的窗口统计（可画的温度通道、风扇目标与最大转速、GPU 温度统计）随窗口在后台准备，只为每个需求方最靠前的窗口（打开的历史或页面的时间档）准备。

## 本地保护

`script/verify_menu_bar_performance.sh` 运行源路径约束和优化构建下的性能回归；已接入 `verify.sh` 和打包脚本。不得为让检查通过而放宽阈值，所有验证在本地运行。

固定验收预算：缓存打开和层级切换 P95 100 ms；首次无缓存内容 P95 250 ms；发布到对应读数显示 P95 100 ms；功能引起的主线程连续阻塞不超过 50 ms。44,000 点历史准备和缓存交付另有优化代码检查，不能替代上述端到端验收。

诊断启动参数 `--menu-bar-performance-audit=/absolute/new-file.jsonl` 仅在 Debug/Beta 有效。记录 `appkit_draw_ack`、请求起点和可关联的原生输入时间。AppKit 的 draw 回调不等于合成器完成上屏，因此不可用该日志单独宣称真实显示 P95 通过。`--telemetry-audit=` 继续记录真实采样/发布时间。日志不采集进程名、文件路径、网络身份，也不增加采样器。

审计键（2.0.0 r2-mini-speed）：`presentation`（打开，标签 `open.first/cold/warm`：启动后首次、回收后、复用）、`fresh.<cpu|memory|network|…>`（打开后第一次画出打开之后的采样）、`chart.overview`／`chart.empty.overview`（打开后第一张有数据／空的概览图表帧）、`secondary`（二级页首次绘制，标签 `module.<页>.from.<来源>`）、`summary`（回到一级）、`tertiary`／`chart.tertiary`（三级首次绘制／三级图表画出所请求的数据）、`range.dimmed`（切档后旧数据淡化）、`hover`（图表悬停位置变化到重绘）、`process.select`（内存进程勾选）、卡片 `card:*`（发布到绘制）。每条带 `mainBusyMs`、`mainMaxIterationMs`：从开始到绘制期间主线程忙碌时间和最长一次运行循环。另有 `span`（打开、隐藏、`setFrame` 等同步段落，`setFrame` 带触发原因 `cause`）、`main_stall`（单次运行循环超过 50 ms，带当时的交互标签）、`main_busy`（每 10 秒主线程忙碌汇总）。探针只在带参数时插入，探针大小 1×1 pt。

审计补充（r2-mini-speed 第二阶段）：`main_stall` 带 `segments`（该次运行循环内各计时段的主线程毫秒：`monitor.deliver`／`monitor.update`／`monitor.memory` 监视器交付与采样、`card.reconcile` 卡片对账、`memory.processes.main` 进程列表读运行中应用、`process.demand` 进程采样需求、`aux.consumer`／`aux.refresh` 辅助采样消费者、`session.windowDidMove`），`main_busy` 带每 10 秒的段合计；超过 16 ms 的段另写 `span`。单次循环超过 150 ms 时，`main_stall` 还带 `stacks`：采样线程在该循环超过 50 ms 后每 10 ms 暂停主线程几微秒、读寄存器并沿帧指针取返回地址，循环结束后按“映像名+偏移 符号”汇总（只有映像名，不含路径；`MenuBarStallSampler`）。脚本计划新增 `hold` 阶段（`holdSection`、`holdRange`、`hold` 秒：三级历史保持打开空闲；`holdHide=<秒>`：保持后以外部点击直接隐藏，三级页仍打开，过该秒数再打开，用来实测保留长档窗口的字节）、悬停的 `hoverSection`／`hoverRange`，以及 `activity=0`（不调用 `beginActivity([.userInitiated, .latencyCritical])`，用于与 App Nap 对照校准；默认调用）。`history.kept`（隐藏时）带合计与 `byWindow`（每个保留窗口的种类、时长、点数、数组字节、读数数组字节）。`cpu.placeholder` 是“一级 CPU 总占用显示为 —”：D39 之前即历史窗口为空，D39 之后总占用在历史未就绪时读实时快照，只有连实时快照也没有时才出现，所以修前修后不能用它比较“打开即显示”，应看 `chart.placeholder.overview` 与 `history.kept`。

`--menu-bar-latency-script=<plan>`（Debug/Beta，必须同时带审计参数，且不能是演示数据）按点击使用的同一入口驱动面板：打开（含回收后的冷打开）、逐个二级、三级、各时间档、切页、隐藏（Esc 与外部点击处理器）、悬停（向三级图表送悬停位置）、进程勾选、稳态。面板放在所有屏幕之外的虚拟显示区，不激活应用、不成为关键窗口、不显示主窗口，也不向系统发送输入事件。计划写法见 `MenuBarLatencyScript`。

每次涉及采样、历史、菜单宿主、布局、图表或状态观察的修改都必须跑相关回归和打包门槛；运行证据、签名、安装回读、端到端性能与原 49 项视觉验收分别记录。

首开调用采样发现宿主挂载期间的大型嵌套视图类型实例化成本；概览、详情和旧布局在导航边界拆开，只构建当前页面，并保持卡片内部稳定身份。性能日志关闭窗口时清除待绘制请求，隐藏期间的通知不计入可见延迟。

应用级场景也在性能边界内：隐藏的设置窗口会随 App 状态更新重新构造，`@State` 初始值不得同步查询 `SMAppService.status`。登录项状态保持未知，设置页实际出现时后台读取；取消或提交切换时，旧读取不能覆盖新状态。此处已有本地构建路径检查。
