# Changelog

## 1.10.1 — 2026-09-21（应用内更新发布）

- 接通正式版与测试版的 Sparkle 更新链路：正式版沿用原 `appcast.xml`，测试版新增独立 `appcast-beta.xml`、签名公钥及自动检查；测试版安装新版本仍需用户确认。
- 移除测试版“只能本地构建更新”的拦截，工具菜单直接调用 Sparkle；保留原生兼容版本选择、归档签名验证和不同 Bundle ID，两个通道不互相覆盖。
- 发布对应的正式版与测试版 ZIP/DMG，更新包使用与旧正式版公钥匹配的 Sparkle EdDSA 签名。旧正式版可直接发现本版；原先禁用更新器的测试版先手动替换一次。
- 按用户要求不运行本次测试套件；构建、签名与发布回读单独记录，不沿用上一构建的通过数。构建脚本增加显式跳过测试选项，默认仍执行原有测试门槛，包身份和签名检查始终保留。
- 仍为 Apple Development 签名，未获得 Developer ID 公证；没有修改系统安全设置。Core18 原始结果模式、尚未完成扩展和独立视觉／性能验收边界不变。

本版包含下列初次 Beta 的功能更新；本次发行记录见 [RELEASE_VALIDATION_1.10.1.md](docs/RELEASE_VALIDATION_1.10.1.md)。

## 1.10.1 Beta — 2026-09-21（Build 20260921041501）

本次将当前本地测试版作为独立预发布快照提供，保留正式版 `1.9.13` 及其更新源。安装包为 Apple Development 签名，未公证，Gatekeeper 发行检查未通过。Core18 仍为无生产参考的原始结果模式；下列开发记录不代表所有扩展、性能预算、硬件或原 49 项视觉验收已完成。详见 [验收记录](docs/RELEASE_VALIDATION_1.10.1-beta.md)。

### 2026-09-21 白天模式

- 主窗口、侧栏及扫描／运行／结果共用组件现在遵循浅色、深色和系统外观选择；保留原有页面、功能和深色设计。
- 补齐浅色背景、白色卡片、深色文字、选中与悬停状态、进度轨道和边框；模块强调色提供更深的浅色变体。
- 原有插图增加白底显示方式，避免滤色叠加在浅色背景中消失；原素材保持不变。
- 小窗内置图表配色增加浅色变体，图表提示和风扇曲线提示随外观变化；保留自定义颜色及独立小窗外观选择。
- 切换明暗不再重建整个页面，保留当前交互状态。新增明暗颜色解析、文字对比度、降低透明度及主题继承回归。

### 2026-09-20 响应、内存与后台开销优化

- 电池与能耗复用已有真实采样；关闭相关界面后不再为累计能耗单独枚举进程。没有覆盖的区间保留缺口，不推算成零耗电。
- 取消采样时保留在途位置直到实际结束，阻止反复切换堆积读取；取消逐层传递，只终止本应用创建且身份仍匹配的采样子进程。
- 网络进程先筛选活动计数与前列候选，再读取身份和图标；保留并列排序及进程身份校验。
- 图标读取队列有界，离开页面取消等待，重复请求共享加载；内存压力下清理缓存，应用更新完成后使旧图标失效。
- 监控历史读取前检查文件类型、大小和解码条数；损坏文件保留，新读数继续在内存中使用。保存使用单个后台写入与最新待存状态，慢磁盘不堵塞新样本；失败按有界退避重试，不影响安全操作的逐项回执。
- 移除扫描完成后的展示性等待，已完成扫描直接呈现结果；更新签名校验移出主线程，仍在成功验证后才重启。后台、低电量或减少动态效果时跳过 Dock 图标过渡动画。
- 补充慢写盘、写入失败、损坏历史、取消排空、图标排队及子进程身份故障回归。真实功耗、屏幕延迟与自动测试分别验收，未测项目不标记通过。

### 2026-09-19 整合开发（部分验收仍在进行）

- 跑分结果页为底部状态栏保留独立布局空间，避免较矮窗口中的文字覆盖结果或按钮；环境提醒跟随中文/英文界面显示。
- 修复权限页在较小设置窗口中无法滚动、下方公网 IP/地区联网同意开关不可见的问题，保留原有卡片样式。

- 恢复动作增加逐项写前日志、原子禁止覆盖移动与中断后身份核实；成功恢复保留历史，取消和日志失败保留未执行项目，过期界面不能覆盖已有恢复记录。
- 跑分私有磁盘资源接入同一操作记录，创建前登记、清理后核销；遇到额外文件或路径替换保留残留，不递归删除未知资源。

- 修复网络兼容测速取消时把立即失效回调误当作任务排空、可能过早释放重任务锁的问题；先取消各请求，再等待所有任务结束后的失效回调。

- 修复 Release 下合法 Bundle ID 被误拒绝、卸载扫描与恢复回执身份字段不一致；增强指针追逐的全链正确性验证。
- 修复长结果页再次开始测试时继承滚动位置、导致取消按钮不在可见区域的问题。

- 追加 CPU 线程扩展曲线和独立约 6 秒短持续观察；保留全部批次原始样本，扩展环境不污染 Core 环境记录。
- 旧清理入口单项多路径结果接入同一逐路径回执，关联文件清理持有重任务锁。中断调用后的已移动项可按身份核实，恢复不覆盖新同名文件。
- 新协议服务端校验与重新计分已在本地加入；新提交路由保持关闭，未部署、未上传。
- 实机一键 Core18 与取消保留历史已验证；发现并调整结果表内边距、原始成绩摘要和重复测试按钮位置。扩展媒体/AI等仍未完成，不宣称全部整合验收通过。


- 新增 M 系列 Core18 草案协议：真实 CPU、Metal GPU、内存和私有磁盘内核接入原一键入口及历史；无校准参考时仅展示原始样本，不借用旧分数，不要求先跑满 600 秒。扩展尚未完成的项目明确标示。
- 清理与卸载增加持久化逐项回执，取消保留已移动结果并等待在途操作；恢复复核身份并跳过同名冲突。设置新增可恢复操作入口。
- 卸载不以显示名或共享容器猜归属，不以低 App Store 评分直接推荐卸载；App 外接迁移保留原件，临时残留登记。
- 公网 IP、地区查询分别默认关闭，撤回后停止请求并清空显示；API 接收期间限制字节，转发前检查重定向。
- 修复合法 MAD=0 被拒绝；修复后台设置通知导致主线程隔离断言崩溃。
- 新协议尚无生产参考和已部署服务端，不生成总指数、不上传。其他 M 型号、发行公证与原 49 项视觉验收不因本地测试而视为完成。


- 修复隐藏的设置页面在监测数据刷新时反复同步查询登录项状态、拖慢小窗的问题；改为设置页显示时异步读取，首次读取完成前明确显示等待并暂不可切换。

- 修复系统运行应用列表出现重复进程编号时，内存进程读取可能直接崩溃的问题；忽略无效编号，同一编号保留较新的完整进程身份。
- 拆开小窗概览与详情的视图构建边界，首次打开不再连带构造所有详情页面的类型信息。

- 小窗先展示已有真实快照，再异步刷新；关闭后保留窗口 5 分钟，内存压力升高时提前回收隐藏窗口及派生缓存。
- 按 CPU、内存、磁盘、网络、传感器、电池及进程卡片分开更新；进程分组排序、历史范围准备和图表时间桶移到后台，相同输入复用有界缓存（32 MiB、最近四个页面）。
- CPU、磁盘和能耗进程改用独立连续计数基线，默认约 2 秒更新，尊重用户更慢的刷新设置；首次基线、失败、PID 重用及取消均不伪造新值。多层菜单统一声明读取需求，关闭一层不误停其他可见层；保留内存进程选择与确认状态。
- 本地验证和打包加入固定性能回归门槛；新增请求合并、过期返回隔离、卡片更新隔离、隐藏历史停止与缓存边界检查。诊断模式分别记录采样发布和 AppKit 绘制回执，不把绘制回执或采样间隔当作屏幕实际显示速度。

- 修复小窗定位在绘制期间反复触发布局更新，以及系统温度通知从后台线程更新界面的问题；定位回调合并到当前布局结束后，电源、温度与屏幕状态通知统一回到主线程处理。
- 小窗详情打开时，CPU、磁盘、能耗与内存进程列表复用主刷新节奏，默认约每 2 秒重新读取；修复几分钟前的进程快照长期不变。内存后台读取不清空进程选择、不重置确认框，离开详情后停止追加读取。

- 修复小窗实时显示延迟：三级历史图仅在展开时构造，新读数的合并等待由 0.9 秒缩短到 0.016 秒；保留末次更新、时间范围切换和悬停离开保护。
- 内存状态改为独立读取，CPU 与网络采样不再等待内存压力查询；电池、磁盘容量／共享盘和网络接口各自完成即更新，慢速共享盘不会拖住电池与网络信息。暂停及关闭时丢弃过期结果，继续使用真实数据、原有采样频率和历史规则。

- 文件分析移除旭日图与相关入口，保留矩形图、分栏、目录列表、容量统计、搜索筛选和文件操作；旧的旭日图显示偏好自动回退为矩形图，保留原有索引计算和文件内容。未扫描占位改为目录浏览图示。
- 扩大运行状态信息区，宽窗口的装饰图缩至辅助尺寸，窄窗口使用单列；修正运行卡片在浅色系统外观下的文字对比度。
- 清理执行结果明确区分完成、部分完成、取消和失败，详情可展开，底部操作保持可见。未移动文件时不显示“查看位置”，也不会提示可从废纸篓恢复。
- 应用更新管理页按实际可见高度布局，窄窗口将应用详情改为独立面板，避免挤出底部选择操作；保留批量选择、更新入口和原有安全检查。
- 登录项首次读取期间，分类计数与汇总统一显示未取得数据状态；删除能耗运行页重复的阶段说明。修正本地运行态证据的路由标记，智能扫描、安全清理和开发缓存分别采集实际对应界面。

- 为 14 个主功能、设置权限及 6 类小窗制作运行态概念图，并依据实际数据能力改进进度、暂停、停止、结果与异常显示。统一运行卡片、数字层次、当前对象和操作区；短窗口中的运行操作保持可见，正文按可用宽度排布。
- 浏览器记录、文件分析、文件搬家、重复文件、首次健康检查、能耗及卸载识别改用专用运行状态；重新读取时保留已有结果。清理执行明确区分已移动、跳过和失败，复制与原件处理显示各自状态。
- 修复重复文件暂停后仍显示运行指示，以及性能测试收尾固定显示 98% 的问题。未知总量使用活动指示，数值进度只使用实际测量；修正进度条绘制，避免短暂滞后于百分比。
- 小窗二级页面统一显示简短的暂停提示，整页高度包含该提示；风扇提交中明确显示“正在应用”，待提交显示“待应用”。保留全部历史、Free 数值不入图、无滚动布局及硬件回读确认。
- 权限卡片在窄窗口下自动换行，状态和操作不互相挤压。运行态验证与原 49 项黄金视觉验收分别记录。
- 实机复查修正登录项首次扫描的重复加载提示、原生列表零高度警告，以及内存刷新过渡中趋势图的位置跳动。小窗暂停后，空图与尚未取得网络信息的区域显示暂停状态，不再持续显示正在采样或读取。
- 修复暂停状态下切换小窗详情时，三级图表可能沿用上一项历史而时间标签已更新的问题；节流期间保留最新内容并在间隔结束后显示，立即切换会取消旧的待显示内容。

- 所有小窗二级、三级详情改为单页完整显示，移除纵向滚动与旧的固定高度上限；硬盘及网络共享盘列表、网络接口详情也同步调整。菜单按全部内容长高，仅在屏幕可用高度不足时整体适配，保留首尾信息、控件与悬停位置；风扇、能源模式和充电上限继续使用原有确认及硬件保护流程。

- 内存二级菜单在双圆环下新增 App、Wired、Compressed、Free 四项容量；悬停显示四项当前百分比和可切换时间范围的堆叠图。Free 保留数值，图表只绘制 App、Wired、Compressed，不绘制 Free 的白色／灰色部分。比例仍按总物理内存计算；复用现有系统组成、历史数据与时间平均规则，图表三项颜色与圆环一致，保留已有采样、缺失值及刷新规则。

- 参考 iStat 的纵向风扇模式布局，统一自动、曲线和手动选项；手动选项展开同步、百分比滑杆与可编辑 RPM，曲线选项展开预览。控制面板移除重复历史图，风扇条悬停历史保留；继续只在点击“应用”后提交并校验硬件回读。
- 统一小窗各层样式：外框 12 pt、卡片 10 pt、自绘控件 6 pt 圆角，外边距和卡片左右内距均为 8 pt，卡片上下内距 6 pt；普通文字使用 11 pt，数字使用等宽数字。能源模式、充电上限和风扇控制共用可按内容伸展的卡片，消除重复内边距；能源模式和充电上限共用原生等宽分段控件，修复按钮条未铺满及 RPM 单位竖排的问题。

- 加快小窗悬停展开：取消首次展开的额外等待，修复上下切换项目时被误判为移入详情、额外等待 0.32 秒的问题；斜向进入详情、离开宽限、快速移开取消和硬件控制保护继续有效。
- 放大小窗内存占用与压力评估圆环并增加间距，概览和二级详情同步调整卡片高度与百分比字号，保留原有实时数据和压力计算。
- 根据新生成的运行态效果图整理扫描界面：进度、实时统计、步骤和当前位置集中在同一面板，保留原有插图；窄窗口改为单列，长路径保持单行，页头与底部操作不再被运行内容挤压。
- 清理结果页移除重复标题，突出真实容量、风险分类与扫描未完成提示；详细覆盖信息仍可展开，选择和清理安全检查保持原有规则。
- 应用更新检查采用一致的运行布局；文件工具加载前后保持图文宽度，并修复浏览器隐私页扫描时“取消扫描”按钮被加载状态禁用的问题。
- 应用更新检查取消后保留模块页头、插图和操作区，明确显示“扫描已取消”，可直接返回或重新检查；实际安装任务仍展示原有执行报告。清理结果的三类汇总在宽窗口三等分铺满，窄窗口自动换行。
- 修复主窗口缩小、变矮及系统分屏时内容区被压缩的问题：按实际内容宽度调整卡片列数与图文布局，高度不足时整页滚动；保留宽窗口的原有素材、扫描流程及操作入口。
- 本地验收中的标准工作量性能时限检查改在 Release 配置执行，使用完整工作量与原有正式时限；其余回归保留 Debug 检查，避免未优化代码在高负载下超时而误判发布版本。

- 修复不返回容量的 WebDAV 共享盘被过滤的问题：已挂载网络盘显示在硬盘列表，缺失容量显示“—”，支持悬停详情；本地磁盘和网络硬盘条目全部显示在同一页。
- 风扇条内加入独立控制按钮，转速区域悬停显示该风扇历史，移除底部重复控制行；保留授权、硬件量程、热保护和读回机制。
- 移除传感器页的 CPU 频率卡片及三级详情；统一精简 CPU、GPU、磁盘、传感器和电池历史中的重复时间、采样统计与说明。

- 修复截图完成后固定详情、抑制悬停的状态残留；内存三级视图仅保留组成历史与已用内存，移除占用百分比、交换和采样说明；CPU 标题与网络卡片统一图标及边距。

- 内存一级卡片改为居中的双圆布局，移除采样时间和已用／总量分数块；压力评估复用系统余量的补值百分比，数值与圆环同步，缺失读数显示“—”。

- 精简 CPU 三级时间视图：移除覆盖时长、额外统计、采样说明和系统悬停提示；进一步移除“时间”“用户”“系统”文字标签，保留图表、时间与分类数值及该段总 CPU 峰值。

- 菜单栏组合图标：底部 Wi-Fi 三点收拢，上方电量／内存圆弧从 180° 扩展至 240°，保留中央内存数字、颜色规则及固定点击区域。

## 1.9.13 — 2026-09-12 (Build 202609120014)

### 菜单栏与监控历史

- 新增“电量＋内存＋Wi-Fi”菜单栏模式：中心数字显示内存占用，上半环显示电量，下方三点显示 Wi-Fi 强度。充电绿色，未充电黄色，低于 50% 深橙色、低于 20% 红色；无内置电池的 Mac 自动改用内存环。保留其他显示模式和有效用户偏好。
- Wi-Fi 使用真实无线接口信号，区分关闭、断开与读取失败；不会把 RSSI 的错误返回值 0 当成满格。电量及无线状态单独变化也能刷新图标，小窗关闭后继续采样。
- 历史图按固定时间窗口平均，避免采样时刻的轻微偏差直接表现为离散空柱：1 小时按 6 秒、1 天按 144 秒；3/6/12 小时及 3/7/14/28 天按相同的约 600 点密度扩展，并增加 10 分钟选项。后者是本应用的计算规则，不声称是 iStat 未公开的内部算法。
- CPU、内存、网络、磁盘、传感器及电池共用时间投影，图形与悬停使用一致数值。真实零值保留，磁盘计数差按实际测量区间加权；短时估算柱沿用普通柱外观，来源仍可核对。睡眠、暂停、应用未运行和长期缺失不伪造补点。
- 网络与磁盘纵轴完整容纳当前图中平均柱的高峰，修复按第 90 百分位缩放时高峰被截断的问题。CPU 和内存百分比仍使用 0–100% 量程。
- 修复菜单栏外观通知导致重复重绘，以及图表渲染中反复扫描同一份历史数据的问题；图表的时间推进与真实采样分开处理，切换范围不改写历史。

### 主窗口、小窗与文件工作区

- 更新主要功能页的素材、页头、状态区、操作区与紧凑布局，保留现有扫描、真实结果与清理流程；改善登录项、性能、内存及能耗页面的信息层次。
- 小窗悬停可打开风扇控制的三级详情，调整能源模式、充电控制与级联菜单的边界和排布，并精简重复说明。未知硬件模式仍按真实状态处理，不会因为隐藏冗余文字而绕过控制安全检查。
- 文件分析增加按文件/文件夹过滤、搜索与排序，并提供按真实字节占比展开的目录图；列表筛选不会改变原始容量及图形统计。
- 改善浏览器隐私的日期范围批量选择、结果列表和空状态；所有删除继续使用原有确认、备份与操作后核对。
- 文件搬家只有在复制校验成功、原件成功移入废纸篓之后才完成；无法移除原件时保留原件及已验证副本并报告真实结果。
- 风扇、电池控制继续保留硬件能力判断、Helper 身份验证、租约、读回和失败恢复；测试展示数据与实际硬件写入路径分开。

### 本地验证与发布流程

- 修复正式安装包遗漏 13 张现有界面插图而退回旧视觉的问题。Release 打包与 Beta 使用相同素材，并在解出的 ZIP 和挂载的 DMG 中逐文件比对资源内容。
- 修复部分界面测试在 Release 配置中引用 Debug 专用截图与演示工具而无法编译的问题；演示数据仍只存在于调试/测试版，正式功能和安全逻辑继续执行 Release 回归。
- GitHub CI、CodeQL 与发布候选验证改为手动触发，并停用本次发布的远端验证流程；构建、测试、签名和安装包检查全部在本机完成。
- 本轮完整验证与运行观察的最终结果记录在 `docs/RELEASE_VALIDATION_1.9.13.md`。测试通过不等于不存在任何潜在缺陷，也不代替独立的黄金视觉验收。

### Responsiveness and background efficiency

- Serialize application inventory and deep signature scans through the existing
  heavy-work coordinator so they cannot compete with storage analysis,
  duplicate scanning, cleanup, network tests, or benchmarks.
- Run long file-analysis, duplicate-hashing, and AC energy-attribution work at
  utility QoS so visible interaction keeps scheduler priority without reducing
  scan safety checks or telemetry calculations.
- Resolve direct and parent application bundle paths before querying
  LaunchServices, avoiding repeated synchronous process metadata lookups during
  the 30-second background energy sample.

### Stable file-tool scan UI

- Keep File Analysis, File Mover, and Duplicate Files on one fixed landing-page
  geometry while their read-only scans run, so changing counters and paths no
  longer move the configuration card, action, status, or artwork.
- Coalesce UI-only progress snapshots to a bounded cadence while preserving
  every scanner callback, phase transition, pause/cancel action, safety check,
  and final result. Volatile paths no longer wrap the File Analysis landing
  page; Duplicate Files keeps a single-line middle-truncated path with full
  hover and accessibility text.

### Browser privacy bulk selection

- Add a visible bulk-selection popover that groups selectable history by local
  date ranges and exact website domains, with a searchable lazy website list
  instead of requiring row-by-row selection.
- Keep bulk selection additive and review-gated. It never deletes immediately;
  the existing browser-running preflight, immutable cleanup plan, recovery
  backup, exact Visit transaction, and post-delete read-back remain required.

### Fan-control hardware compatibility

- Give bounded Apple Silicon SMC takeover operations enough time for slower
  thermal-manager unlocks instead of treating the generic five-second XPC
  deadline as a failed fan write.
- Resolve each fan's `F?md`/`F?Md` mode key independently and retain the same
  helper watchdog, hardware-range clamp, write read-back, and automatic restore
  requirements.

### Explainable system health

- Rebuild the health score around four measured core factors: disk reliability,
  usable capacity, 30-day stability, and battery lifespan. A critically weak
  factor can no longer be hidden by a healthy average.
- Keep current battery charge, FileVault, Time Machine, network, and thermal
  readiness visible as supporting status without mixing them into the hardware
  health score. SMART Verified is reported as a current check, not invented as
  100% remaining SSD life when no media-life sensor exists.
- Treat macOS `shutdownStall` diagnostics as hangs rather than unexpected
  restarts, and keep per-app crash/spin reports out of the device-stability
  score, while preserving the diagnostic evidence and action guidance.
- Replace the full-page warning tint and nested score cards with a neutral,
  responsive evidence view that shows the measured value, score, availability,
  and observation time for every scored factor.

## 1.9.12 — 2026-08-28 (Build 202608282037)

### Adaptive main-window layout

- Keep native window resizing and the existing readable minimum size instead of
  locking the main window to one fixed frame.
- Replace the shared button's hand-built icon/text `HStack` with native SwiftUI
  `Label`, keeping system alignment, spacing, focus, tooltip, and accessibility
  behavior. Primary, secondary, destructive, and other meaning-bearing actions
  now keep their visible title under pressure; only toolbar, icon, and small
  utility actions may use `ViewThatFits` to fall back to an icon-only label.
- Stack shared page-header actions below the page identity at compact window
  density, while regular windows retain the original single-row arrangement.
  All 15 main routes were recaptured from the installed Beta at the supported
  `833 × 544` minimum size without icon/title overlap; the compact memory page
  keeps both the refresh glyph and its visible “刷新” title.

### Startup performance and Smart Scan

- Keep ordinary startup-item refreshes on the fast read-only path; the separate
  **Full Scan** button remains the only entry that runs the bounded macOS BTM
  diagnostic.
- Read referenced application signing identities with at most four concurrent
  checks and drain temporary bundle metadata per application to reduce first-scan
  latency and transient memory pressure.
- Pre-index normalized application paths, bundle identifiers, and attribution
  tokens once per startup scan. Embedded helpers no longer standardize every
  application URL again for every startup item, while deepest-parent matching
  and attribution confidence remain unchanged.
- Precompute startup-item merge fingerprints once per item so deduplication no
  longer normalizes plist and executable URLs again for every candidate pair;
  merge ordering and evidence rules remain unchanged.
- Avoid Foundation URL normalization for startup items whose paths cannot resolve
  into sealed `/System` locations, while retaining dot-segment safety checks.
- Defer self-signature capability inspection from MainActor store construction
  until the first background scan or confirmed startup-item operation.
- Move the app-and-Helper signature contract check off the main thread and reuse
  its single fail-closed result, keeping the mini-window responsive on first open.
- Fill the existing fixed Smart Scan accessory slot with the last verified green
  and review totals, reserving the center width for the primary action instead of
  adding another card system or allowing the summary to overlap it.
- Serialize application-inventory progress and incremental-result delivery with
  the main actor so late batches cannot overwrite final source/ignore policy, and
  propagate cancellation immediately from metadata reads instead of continuing
  Spotlight, Homebrew, and source classification work.
- Remove an always-empty localized metadata dictionary allocated for every app.
- Read application metadata with a four-task ceiling while preserving URL order
  and the existing 16-item UI batches, reducing full inventory latency without
  launching an unbounded task per installed application.

### Application updates

- Show the scanned `.app` artwork in every update catalog row and detail view.
  Homebrew formulae, command-line tools, and other items without an application
  bundle now receive a clear provider-specific icon instead of a weak generic
  file glyph.
- Add a visible **Open** action to every manual-update row and a matching detail
  action. Provider-verified Homebrew and confirmed official sources open only an
  HTTPS page whose identity and allowed host pass the existing source checks;
  items without a trusted page retain their existing app or command fallback.
- Keep manual hand-off truthful: opening a page, app, or copied command never
  marks the item updated; the installed version must change on a later scan.

### Application uninstaller

- Replace the automatic scan on page entry with an explicit **Scan Apps**
  action. The initial page now stays idle until the user starts the read-only
  scan, then returns to the existing searchable application list.
- Reuse the shared feature landing shell, status treatment, and design tokens so
  the uninstaller follows the same visual language as the other main modules.

### File analysis space map

- Change the default tile action from opening Finder to an in-app directory
  drill-down. A child list, proportional map, back control, and breadcrumb path
  now stay synchronized while the user explores successive folder levels.
- Replace the vertically stacked summary, type bars, map, and duplicate file
  list with a dedicated analysis workspace: one compact result toolbar, one
  segmented **Space Map / File List** switch, and an edge-to-edge split between
  the current directory list and its treemap. The map is no longer clipped by
  the outer page scroll view.
- Label every sufficiently large tile with both size and percentage, reduce the
  visual gutter to two points, and keep the parent folder's known size as the
  layout denominator. Items beyond the tile limit are grouped as **Other
  Measured Items**, while time-, access-, exclusion-, or cloud-limited space is
  retained as a non-interactive gray **Measurement Incomplete** tile. A partial
  child scan can no longer inflate 150 MB into 42% of a 3.8 GB parent folder.
- Keep **Show in Finder** as a separate explicit row/header action. Selecting a
  file only shows its local details and never opens Finder or performs cleanup.
- Reuse the existing `LargeFilesStore`, `DiskScanner`, heavy-work coordinator,
  scan exclusions, and safety rules. A bounded low-power scan divides its
  remaining time fairly among immediate child folders, preventing one large
  first folder from starving later map tiles. Results are cached for instant
  back navigation and marked as lower bounds when time, access, exclusions,
  symbolic links, or cloud placeholders prevent a complete result.

### Duplicate files

- Use the existing shared button content with explicit icon-to-title spacing for
  the add-folder and external-volume actions, including the coverage report.
  Compound SF Symbol badges no longer overlap Chinese text at Retina scaling.
- Give the scan-scope menu the same explicit spacing while preserving native
  menu, focus, keyboard, and accessibility behavior.

### Browser privacy

- Identify every history result with the installed browser's real app icon and
  name, then show a bounded local page-title summary, domain, profile, visit
  count, and latest visit time. Full URL paths, query parameters, parsed search
  keywords, passwords, cookies, bookmarks, autofill, and page contents remain
  outside the result UI.
- Include local page titles in the existing result search without adding a new
  scanner or persistence path. Remove the meaningless per-row size placeholder
  so the review, handling, and running-state badges remain readable at the
  supported compact window width.

### Performance benchmark

- Replace the default wall of raw benchmark units with an at-a-glance comparison
  of CPU, GPU, memory, and storage scores, including the relative strength,
  relative weakness, and an honest V7-reference explanation. Keep all original
  metrics available in one collapsed technical-details section.
- Show the real benchmark workload, repetition number, overall progress, and the
  seven-stage run path while testing. This reuses the existing V7 state and
  coordinator without adding another benchmark flow, timer, or persisted score.

### Energy impact

- Replace the automatic page-entry scan and six-second refresh loop with an
  explicit **Scan Energy** action built on the shared feature landing shell.
- Show the existing measurement pipeline as six real stages: running processes,
  app attribution, baseline counters, initial attribution, the 1.2-second live
  sample, and calibrated result aggregation.
- Keep menu-bar background prefetch separate from the main page's explicit scan.
  Rescans retain the previous complete result until the new measurement finishes,
  and the stage nodes and progress bar update together without visual lag.
- Give every six-stage pipeline node a fixed glyph column and the shared 8pt
  icon-to-title spacing. Apply the same spacing to rescan, sample-window, and
  sort controls so icons cannot crowd localized text at Retina scaling.
- Prevent the shared landing action from covering header content when the main
  window is short. Energy results now switch to a stacked measurement bar and
  app row at compact widths, keeping app names, status badges, and all three
  energy values readable instead of compressing badges down to bare glyphs.

### Developer artifacts

- Add a persisted 30–364 day activity threshold to the existing developer-cache scan. The latest readable modification anywhere inside each candidate now classifies it as green (over one year, selected by default), yellow (older than the chosen threshold, manual confirmation), or red (within the threshold, off by default with two confirmations).
- Recheck nested modification activity during preflight and immediately before moving an item; any post-scan change fails closed and requires a new scan.
- Identify every supported AI developer artifact by owner and type in scan rows and evidence details: Codex, Claude Code, Cursor, GitHub Copilot, OpenCode, and OpenClaw. Regenerable caches and temporary files keep the time-based safety policy; logs remain review-only and can only be revealed in Finder.
- Keep sessions, chat history, project state, credentials, settings, extension state, and OpenCode storage outside the cleanup allowlist.

### Fan control stability

- Keep verified manual and maximum targets active while physical RPM catches
  up. Helper target-register readback, lease renewal, thermal protection, and
  the watchdog remain the control safety boundary.
- Refine the attached fan-control palette with the mini-window's active theme,
  clearer hover/selection borders, live progress feedback, a wider readable
  layout, and 25/50/75/100% synchronized fan presets.
- Keep every 1% slider movement local for immediate pointer response, publish a
  bounded 5% live hardware preview, and commit the exact target on release so
  UserDefaults and shared SwiftUI observers are not invalidated for every pixel.

### Mini-window power controls

- Keep the battery power-mode palette top-aligned beside the secondary power
  page. Expanding or collapsing battery information no longer moves the
  palette with its source row.

### Access setup

- Add **Settings → Access & Setup**, consolidating Full Disk Access, per-folder
  access, App Management, the restricted system-control helper, and optional
  notifications.
- Show current status, exact System Settings paths, direct jump buttons, and a
  three-step setup tutorial.
- Explicitly document that Accessibility, Screen Recording, Camera,
  Microphone, Location, and Automation permissions are not required.

### Duplicate files and file migration

- Give Duplicate Files and File Migration the same shared landing/data-page
  hierarchy as the rest of the file tools, with route-specific copy, semantic
  icons, shared empty states, and responsive controls.
- Keep the duplicate-results search, filter, rules, sort, and scope controls
  usable at compact widths; report only full SHA-256 matches as content-confirmed
  files and keep the coverage description tied to the completed scan's scope.
- Keep File Analysis and File Migration on the same scanner and Store while
  separating their presentation: migration no longer inherits hidden analysis
  filters, and external-drive/app discovery runs only on the migration route.
- Show only regular user files that satisfy the migration safety boundary,
  expose scan cancellation, and state that files are SHA-256 verified before
  the original is moved to Trash.
- Reject a file when its current size no longer matches the scanned candidate,
  and reject an application whose source signature is invalid before copying.

## 1.9.11 — 2026-08-14 (Build 202608142241)

### Interface

- Replaced the floating Beta-only title with the product name and a compact
  Beta capsule so every main-window page shares one chrome.
- Gave idle landing pages the same page-feature icon as data pages, and routed
  module headers through `AppSymbolIcon` so Smart Scan, health, utilities, and
  file tools use one glyph size and rendering mode.
- Kept immersive pages free of the settings-only header divider, and showed the
  version plus Beta mark in the sidebar footer.

### Menu-bar window and hardware control

- Kept fan monitoring and fan control on separate surfaces: the sensors card
  only reads speeds and helper status; mode switches, sliders, and the curve
  editor live in the attached palette.
- Replaced the blocking AppKit slider with a DragGesture control, widened the
  helper watchdog to 30 seconds, and stopped a second GUI instance from
  stealing the helper lease.
- Hovering from a control anchor to its palette no longer dismisses the
  tertiary column; the session hover envelope now includes the palette frame.
- Palette rows stay clickable after relaunch so a stale “connection
  interrupted” state can self-heal instead of dead-ending the controls.
- Shared one status capsule between the sensors card and the fan palette.

### Application updates

- Added a vendor-updater path for apps that ship Keystone or Squirrel, and
  surfaced Sparkle apps with a trusted in-app update path even when the
  remote version is still unknown. Automatic install gates are unchanged.

### Performance and maintenance

- Cached localization language lookup, merged CPU sampling into one mach call,
  replaced per-item `du`/`mdls` with native size reads, windowed mini-window
  telemetry history, and throttled duplicate-file progress publication.
- Removed unused privacy adapters, old menu-bar charts, and other dead views.
- Moved Beta verification copies out of Documents so File Provider cannot
  reattach `FinderInfo` and break strict codesign.

By owner decision, version 1.9.11 is published as an explicitly unnotarized
public test release using the locally validated Apple Development-signed build.
It is not Developer ID signed or Apple notarized and must not be described as
Gatekeeper approved. First launch may require Control-click → Open.

## 1.9.10 — 2026-08-13 (Build 202608131925)

### Smart Scan and cleanup safety

- Aligned the read-only scanner and three-tier presentation with the installed
  `storage-analyzer` policy while preserving stable item identities and the
  existing plan, preflight, confirmation, identity recheck, Trash/Quarantine,
  verification, and report chain.
- Kept regenerable cache items selected by default, review items opt-in with an
  extra warning, and protected or incomplete-evidence items out of executable
  cleanup plans.
- Rebuilt the result hierarchy around compact risk summaries and collapsed
  parent groups, with disk capacity, Top 5, coverage, and technical evidence
  retained as secondary detail instead of crowding the first screen.
- Stabilized the idle, scanning, and completed page geometry and throttled
  progress publication so file discovery no longer shifts the page or rebuilds
  the whole result view for every candidate.

### Menu-bar monitoring and hardware control

- Tightened the existing three-level menu-bar window attachment, hover intent,
  screen-edge flipping, panel mutual exclusion, equal outer insets, and compact
  card geometry without creating another panel architecture.
- Improved cached CPU, GPU, fan, memory, disk, network, battery, external disk,
  and network-volume telemetry while moving heavy disk work away from the main
  interaction path.
- Added structured helper, fan telemetry, capability, control-mode, and power
  state instead of ambiguous optimistic labels; all successful control states
  still require helper readback.
- Added temperature-curve fan control to the existing privileged helper, with
  typed validation, per-fan RPM mapping, filtering, hysteresis, rate limits,
  lease/watchdog protection, write verification, and automatic restoration.
- Unified automatic, manual, and curve control with one helper authorization;
  removed the legacy privileged installation path and arbitrary command/key
  surfaces.

### Browser privacy, applications, and files

- Expanded installed-browser discovery and profile scanning while keeping URL,
  title, visit time, and visit count processing local and read-only.
- Added recovery-aware browser history processing and clearer per-browser
  coverage without reading passwords, cookies, bookmarks, or page content.
- Improved application update discovery, official-source verification, queue
  progress, failure recovery, and the usable result surface without treating a
  failed package identity check as success.
- Restored file moving as a first-class sidebar workflow, kept copy/verify before
  Trash semantics, and hardened duplicate-file resume data and application data
  locations.

### Interface, accessibility, and performance

- Unified the main feature pages with the existing application shell, spacing,
  material, typography, button hierarchy, and compact explanatory copy.
- Improved application icons, process selection, keyboard/accessibility labels,
  reduced-motion behavior, and fixed-width numeric presentation.
- Reduced redundant timers, monitor work, state publication, formatter creation,
  and repeated panel connections to make the mini window respond faster.

By owner decision, version 1.9.10 is published as an explicitly unnotarized
public test release using the locally validated Apple Development-signed build.
It is not Developer ID signed or Apple notarized and must not be described as
Gatekeeper approved. First launch may require Control-click → Open.

## 1.9.9 — 2026-08-05 (Build 202608052103)

### Application updates

- Unified scanning, review, confirmation, execution, post-update inventory, and completion reporting into one recoverable queue.
- Kept ordinary App Store items in the system-managed flow while allowing only receipt-, signature-, identity-, and product-ID-verified MAS items into the automatic queue.
- Preserved frozen click-time identity and target versions, execution-time running-app checks, graceful quit, cancellation, reconciliation, relaunch, and one final inventory refresh.
- Separated preview dismissal from active-batch cancellation so confirming an update can no longer cancel the queue as the sheet closes.
- Corrected the completion summary so verified App Store work reports its real succeeded, failed, cancelled, or skipped result instead of always appearing skipped.

### Browser privacy

- Reworked the page into a usable read-only scan, masked review, per-browser manual action, and confirmation-scan flow.
- Kept raw URLs, titles, search terms, and domains in the in-memory session; real domains reach the clipboard only after an explicit copy action.
- Added fail-closed per-profile coverage proof and multiset visit matching so a different profile, partial scan, permission failure, or duplicate record cannot be reported as cleared.
- Moved the privacy session to the main-window lifetime so navigating to another page no longer discards scan results or verification state.
- Deduplicated browser filter options by browser ID so ordinary multi-record scan results no longer trigger a duplicate-key crash while rendering the filter menu.

### Performance benchmark and leaderboard

- Kept one official V9 product flow covering CPU, GPU, memory, storage, display, and a 600-second sustained run, with an expected total duration of 14–16 minutes.
- Preserved the exact power, thermal, or Low Power Mode reason and sustained telemetry when a safety stop ends the official run early.
- Added compatible latest, best, history, and public leaderboard presentation without automatic score submission.
- Froze the client/server V9 contract and added it to the Release packaging gate alongside scoring, leaderboard, official-plan, and legacy calibration checks.

### Compatibility and release safety

- Integrated the current `main` Swift 6, Xcode 16.2, runner portability, icon-loading, update-event buffering, and benchmark compatibility fixes.
- Corrected the compact panel's memory-pressure semantics: the primary value and ring now report the three-level pressure state, system headroom remains explicit, and `100−headroom` is identified only as a history-trend estimate rather than an iStat or Activity Monitor percentage.
- Added explicit release-state separation for local builds, installed apps, Developer ID signing, notarization, public assets, appcast publication, and real Sparkle replacement.

By owner decision, version 1.9.9 is designated for an explicitly unnotarized public test release using the validated Apple Development-signed build. It must not be described as Developer ID signed or notarized, and macOS may require Control-click → Open before first launch. Anonymous artifact verification and a real 1.9.8-to-1.9.9 Sparkle replacement remain mandatory publication checks.

## 1.9.8 — 2026-07-30 (Build 202607301737)

### Interface and settings

- Refined the main window, cleanup selection, settings, and compact menu-bar panels with shared spacing, typography, borders, and semantic colors.
- Focused the Smart Scan preparation screen on one primary action and strengthened the existing module tint without introducing saturated full-window backgrounds.
- Added light and dark application artwork plus compact menu-bar artwork that follows the active appearance.
- Improved compact-panel sizing, edge attachment, routing, and multi-display placement so empty content no longer leaves fixed gaps.

### Performance benchmark

- Restored an explicit score for every benchmark run while keeping the highest verified score as the leaderboard entry.
- Added automatic best-score refresh and clearer per-test and Apple Silicon baseline presentation.

### Startup items and app updates

- Expanded startup discovery and now exposes only operations that the current system can actually perform, with explicit administrator or System Settings guidance where required.
- Improved App Store and website-update discovery, capability reporting, queued actions, and post-update version verification.

### Memory diagnosis and optimization

- Replaced `ps` RSS sampling with native physical-footprint and identity probes.
- Added explicit complete/partial/unavailable measurement quality and reasons.
- Switched paging trend input from generic Pageins/Pageouts to kernel Swapins/Swapouts.
- Stopped summing VM counters that may overlap; cached memory uses a conservative estimate.
- Removed cache purge actions, purge result language, and mixed disk/RAM “opportunity bytes.”
- Added immutable, single-use optimization plans and an application-scoped state machine.
- Added PID-reuse protection, graceful/force separation, cancellation, timeout, partial-result, and verification reporting.
- Separated estimated app reduction from observed app and available-memory deltas.

### Menu-bar charts

- Added one shared panel timeline derived from `ContinuousClock`.
- Added visibility, display sleep, Low Power Mode, thermal, and Reduce Motion cadence policy.
- Added continuous horizontal bar motion, clock-skew tolerance, future-sample rejection, and out-of-order sorting.
- Added persistent real battery history and unified CPU, memory, network, disk, sensor, fan, and battery chart geometry, hover targeting, and localized presentation.

### System monitoring and control

- Added richer memory, battery, power, sensor, disk, and network detail while preserving unavailable-data states instead of displaying false zeroes.
- Tightened fan-control capability checks and helper packaging without silently escalating privileges.

### Engineering

- Added a dedicated controllable memory fixture app and GUI behavior smoke test.
- Added reproducible bootstrap, verification, and release-candidate scripts.
- Added macOS 14/macOS 26 CI, CodeQL, and Dependabot configuration.

Version 1.9.8 has been published to the private source repository, the public updates repository, and the public Sparkle appcast. Build 202607301737 has not been installed, Developer ID signed, notarized, or exercised through a real Sparkle replacement.
