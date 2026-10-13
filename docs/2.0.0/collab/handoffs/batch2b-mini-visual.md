# 批次 2b 交接：小窗视觉一致性

- 实现：Claude 子代理（Opus 5.5）。复核：全新上下文的 Claude 子代理，结论“小修后合并”；主会话实机截图确认 P1。复核意见已由实现子代理（Opus 5.5，新上下文）按下文“复核意见与处理”修改
- 分支：`task/batch2b-mini-visual`，基于集成分支 `a559084`。本批提交见文末；未合并、未 push、未打 tag、未安装、未启动应用、未截图
- 只改了允许范围：`Views/MenuBarAdvanced/**`、`Support/MiniWindowStyleTokens.swift`、`Support/PanelMetricColors.swift`、`docs/mini-window-design.md`、`Tests/**` 和本交接。没有改 `Stores/ScanStore.swift`、主窗口、设置窗口（`SettingsView.swift` 未动；它显示的配色名称来自 `PanelMetricColors.swift`）、服务层、`MenuBarAdvancedStatusView.swift`、`Support/MenuBarPanelSession.swift`

## 复核意见与处理（第二轮，2026-10-04 下午）

结论：复核 P1 已确认并修复（代码在允许范围内，原因与越界改进建议见下）；P2 第 1–9 项、第 11 项的无障碍部分已修，第 10 项按要求只记录，第 11 项其余两点只记录。三项“需用户决定”（二级页头全有／全无、磁盘一级横条改“已用”、级联内容顶边对齐）本轮未动。需主会话重拍 `menu.processor.secondary`、`menu.cpu.history` 核对。

### 复核 P1：已确认并修复（CPU 二级比 CPU 卡低 38.5 pt）

- 现象（主会话证据）：`menu.processor.secondary` 与 `menu.cpu.history` 中二级外框顶边比一级外框顶边低 46.5 pt（已安装测试版为 8 pt，即 CPU 卡顶边）；其余二级（内存、磁盘、网络、传感器）在两边一致。本地复核截图像素：已安装版二级顶边 16 px，2b 版 93 px；内存 240、磁盘 496、网络 664、传感器 838 px 两边相同。
- 机制（已用测试证实）：二级顶边 = `overviewFrame.maxY − 锚点.maxY`（`MenuBarPanelSession.registeredDetailTopOffset`，越界文件，只读）。一级卡片的锚点由 `SmallWindowAnchorNSView`（`Support/SmallWindowInteraction.swift`，越界）在挂到窗口、自身尺寸布局、跟踪区更新时报告；临时测试证明卡片只是移动（`.offset`、布局位置变化、窗口移动）时它不再报告，登记表保留旧位置。打开某一节时，概览卡片按所选页重新创建（`MenuBarCardIdentity` 含 page），在 `GeekAttachedPanelShell` 里首次布局用默认框：明细比概览高时概览底对齐（`defaultOverviewFrame.y = 展开高度 − 概览高度`），而只有 CPU 页（630–708 pt）比概览（605 pt）高，其余节的 `detailVerticalOffset` 使展开高度等于概览高度。新卡片若在这个临时框里报告，`registeredAnchorDidChange` 就按临时位置重新放置级联，卡片移回原位时不再报告，于是停在错误偏移。用真实 `MenuBarPanelSession`＋真实 `GeekAttachedPanelShell` 的测试复现：级联布局晚 150 ms 送达视图时 CPU 二级低 102 pt；不延迟时其余五张卡的锚点也偏 4 pt（居中过渡）。
- 是否 2b 引入：未能证实。基线截图用已安装的 Beta（Release 优化）包，2b 的所有截图（中期、最终、对齐对比）都用 `--bundle-only` 的 Debug 包；2b 没有改动锚点登记或级联放置，一级卡片几何也未变（逐个核对了 `bfe0943…e760c0d`，`a2015fd` 的 `GeekModuleHeader` 与原标题行几何相同），CPU 二级页只矮了约 2 pt。更可能是时序差异暴露了既有问题；具体偏移值（38.5 pt）取决于临时布局时的窗口与明细尺寸，未能在单元测试中逐点复现。若要定论：请主会话用 `a559084` 的 Debug 包按同一脚本拍一次 `menu.processor.secondary`。
- 修复（允许范围内，提交 `181623c`）：`GeekPanelComponents.swift` 新增 `GeekModuleAnchorRegistration`，一级卡片包装（`GeekOverviewModuleButton`、`GeekOverviewHoverRegion`）都改用它；`MenuBarGeekPanel.swift` 的概览页提供命名坐标空间和放置方式。
  - 概览单独显示：仍用原生屏幕框，另在卡片于窗口内移动后重新读取（下一主队列轮次读取，避免在视图更新中触发级联重排）。
  - 与二级页并排：锚点 = 卡片在概览中的布局框放在级联的概览框（`cascadeLayout.parentFrame`，正是会话计算偏移所用的框）上，窗口框与 SwiftUI 布局先后更新也不会登记临时位置；级联布局送达视图前不登记（保留概览单独显示时的锚点）。
- 测试 `MiniWindowLevelOneAnchorTests`（3 项）：卡片在窗口内移动后锚点跟随；并排时锚点在级联概览框上；真实会话＋真实外框端到端，打开 CPU 后二级顶边距概览顶边 8 pt，六张卡锚点在 8／120／248／332／419／533 pt，延迟 0 与 150 ms 都成立。把注册逻辑还原为 `c8c99be` 的写法后 3 项全部失败（20 处断言：锚点停在 773.5 而非 812；锚点在窗口而非概览框；CPU 二级低 102 pt，其余锚点偏 4 pt）。
- 越界改进建议（未改，交主会话／批次 4b）：
  1. `Support/SmallWindowInteraction.swift`：`SmallWindowAnchorNSView` 在自身原点变化、祖先移动、窗口移动／缩放后也应报告，所有锚点（不止一级卡片）都会受益。
  2. `Support/MenuBarPanelSession.swift`：`registeredAnchorDidChange` 在 `isApplyingProgrammaticFrame` 期间直接丢弃变化，应改为记下并在程序设框结束后补做一次 `setGeekSection`。
  3. 同文件：一级锚点其实是卡片在概览内的固定布局偏移，会话可直接用布局偏移而不是推送的屏幕框，彻底去掉窗口与布局时序的耦合。
- JEV（jev-latest）复核 P1 修复摘要：`escalate`，safe_to_apply 0.44，加权 0.84（正确性 1.92、需求吻合 1.89、测试缺口 0.24、影响面 1.47 但置信 0.21）。仅作参考，需实机重拍确认。

### 复核 P2：逐条处理

| # | 结果 | 处理 | 提交 |
|---|---|---|---|
| 1 外框高度与文档 | 已修 | 选“图表与坐标行间距为 0”：每个三级历史改用一个绘图块 `geekHistoryAxis`，图表 140 pt＋坐标行 14 pt、无间距＝154 pt，即加坐标行前的绘图区高度，与页面自身行距（6 或 4 pt）无关，所以图上下还有内容的页（网络、GPU、内存压力、内存组成、交换内存、风扇、传感器、磁盘 I/O 与读写）也恢复原高度；GPU 不可用状态与时长列表同样占 154 pt。测试实测绘图块高度＝154（中英文、有无“未记录”图例），并检查三个文件里每个坐标行都在绘图块中、不再单独写图表高度 | `87467d7` |
| 1 风扇纵轴 | 已修 | 文档与本交接改为“0 到按读数取整的上限（`fanTrendMaximum`），不是硬件最高转速”；图下三列改名“硬件最低／硬件最高／目标”（Hardware Min／Max／Target），并在代码注释说明与纵轴的区别 | `87467d7` |
| 2 间距字面量 | 已修 | 9 处全部换令牌：行间 5→`rowSpacing`（4）、行内 5→`inlineSpacing`（6）、并排数值列 10→新令牌 `columnSpacing`（8）；电池卡 5→6（随 #3）。全部探头温度网格的 10 pt 列距是测试锁定的标定几何（`GeekSensorsPowerHoverDetailTests` 锁 `gridColumnSpacing == 10`），改为引用同一命名常量 `GeekSensorTemperatureLayout.gridColumnSpacing`，数值不变。`MiniWindowConsistencyRuleTests` 改用正则覆盖栈、网格、内边距中所有 5／7／9／10 pt 写法 | `53c9732`、`87467d7` |
| 3 电池页头与图标色 | 已修 | 电池卡改用 `GeekModuleHeader`（12 pt；16 pt 图标槽，行高不变，卡高 64 pt 不变），左列取自然宽度，标题不会被右侧供电文字挤省略。`GeekModuleHeader` 去掉 `iconTint` 参数，所有一级卡图标与标题都用栏目标题色（CPU 原用负载色、网络原用下载色、电池原用电池色） | `87467d7` |
| 4 CPU 负载色回到数据 | 已修 | 负载色出口 `processorTint` 改为调用 `PanelMetricColors.cpuLoad`（75% 警告、90% 危险，其余为用户色，阈值不变）；一级 CPU 卡（也是二级首卡）页头右侧总占用、二级“CPU 占用”行的总占用数值用它，标题保持栏目色。单元测试锁阈值，源码规则锁用法 | `87467d7` |
| 5 自定义配色下同色 | 已修 | `PanelMetricColors` 新增 `gpu(chartAccent:)`、`sensorGraph(chartAccent:)`（自定义指标色优先，其次图表配色，再次默认色，与 `resolvedGPUTint`／`resolvedThermalTint` 同一规则）和唯一温度规则 `temperature(_:chartAccent:)`。风扇圆环（一级、传感器页、内置三级）与风扇历史、GPU 历史、温度历史都取这些出口，并关闭图表的单色重染（历史图直接用圆环颜色）。`temperatureTint`（芯片温度圆环）与 `geekTemperatureTint` 都改为调用同一规则，温度“正常”色只剩一个来源。测试：出口在默认／图表配色／自定义色三种情况的取值、温度阈值、各视图引用同一出口，以及 `MenuBarAdvancedStatusView` 中两个解析器的规则文本与新出口一致 | `87467d7` |
| 6 英文文案与布局 | 已修 | 卷行与一级磁盘卡英文 “free” → “available”；网络进程列 “Up／Down” → “Upload／Download”；`GeekProcessListHeader` 列标签不再截断：多列时保持 60 pt 槽位、略宽的 “● Download” 向左伸入列间距；单列只占标签宽度，英文电源页 “USING SIGNIFICANT ENERGY”（159 pt）＋加载指示＋“Power” 在 232 pt 内完整显示。`MiniWindowRowLayoutTests` 用布局探针实测电源、网络、磁盘、CPU 四种表头，中英文标题与列标签宽度都不小于自然宽度，且列右缘与数值列对齐；还原旧写法时失败（标题 139.5／159.5 pt，Download 48／51.5 pt） | `a91842f`、`87467d7` |
| 7 卷行缩字 | 已修 | 卷行保持两行和 47 pt 行高（三级偏移按它计算）：第一行卷名（唯一可省略）＋健康状态，第二行容量摘要占满整行、原字号、不再有 `minimumScaleFactor`，其后是健康读取时间，放不下时只隐去时间（悬停与读屏仍有完整说明）。测试用 “100% 已用 · 999.99 GB 可用”／英文 175 pt 长值实测完整显示且行高仍为 47 pt；还原旧写法时失败（141 pt） | `a91842f` |
| 8 显存叫法 | 已修 | 统一为“显存”（英文 GPU Memory），`GeekGPUVocabulary` 一处定义；CPU 页 56 pt 圆环内英文仍缩写 MEM（与 TMP 同列，“GPU Memory” 放不进圆环），新增 `GeekCombinedRing.accessibilityTitle`，读屏读全称；温度圆环读屏同样用全称 | `87467d7` |
| 9 “可用”圆点 | 已修 | 保持底轨色填充（表示圆环未填充部分），加一像素第三级文字色描边；测试检查描边色在黑、石墨卡片及所有自定义面板配色卡片上对比度 ≥ 3:1（底轨色本身约 1.5:1）。拟议 D4 补充见下 | `bff146b` |
| 10 截图证据局限 | 只记录 | 见下“截图证据局限” | — |
| 11 坐标行读屏 | 已修 | 坐标行无障碍值补上“浅灰色块表示未记录，没有采样，不代表数值为 0”（交换内存折线无此图例则不读） | `87467d7` |
| 11 规划器只剩测试使用 | 只记录 | `GeekDashboardLayoutPlanner`／`GeekDashboardCanvasPlanner` 生产代码已无调用，只被测试使用；本轮不删 | — |
| 11 语言缓存竞态 | 只记录（越界） | `Support/L10n.swift` 约 121–127 行：`usesChinese` 先读缓存、未命中时计算，再单独加锁写回；若中间收到 `didChangeNotification` 失效，可能把旧语言写回缓存直到下次失效。可能与全量测试偶发的英文“Command Complete”有关，未证实 | — |

### 拟议决定文字（主会话合并时写入 `DECISIONS.md`）

- D4 补充：内存组成“可用”行加与其他三项同尺寸的圆点，填充圆环底轨色并加一像素次要（第三级文字色）描边，表示圆环中未填充的部分；取代旧文档“Free 不显示颜色标记”。
- 小窗标题行：全部一级卡片（含电池卡）与 CPU、内存二级首卡用 `GeekModuleHeader`，模块图标与标题都用栏目标题色；负载、压力、温度等状态色只用于数据与按钮。CPU 负载色用在一级 CPU 卡总占用与二级“CPU 占用”总占用数值上。取代 `PanelChartNormalizationTests` 黄金概览中“电池图标用电池色（`GeekModuleLabel … tint: metricColors.battery`）”的锁定。
- GPU 内存叫法：统一为“显存”（英文 GPU Memory；CPU 页圆环英文缩写 MEM，读屏全称）。取代 `GeekHoverDetailTargetTests` 中“GPU 内存”字样的锁定。
- 配色出口：GPU、温度、风扇的圆环与其历史图在自定义指标色或图表配色下取同一出口（自定义指标色 > 图表配色 > 默认色），这些历史图不再被单色图表主题单独重染。
- 三级历史绘图块：图表与坐标行合成 154 pt（140＋14，无间距），三级外框不因坐标行变高。`GeekSensorsPowerHoverDetailTests` 对电池历史“使用共享图表高度”的源码检查改为检查绘图块。

### 本轮改动的源码契约测试（均有注释）

- `PanelChartNormalizationTests.testGoldenOverviewKeepsReferenceLabelsAndFixtureThemeDeterministic`：原断言电池卡为 `GeekModuleLabel(systemImage: AppSymbols.Monitor.battery, tint: metricColors.battery)` 与 `Text(L10n.text("电池", "Battery"))`，改为断言 `GeekModuleHeader(systemImage: AppSymbols.Monitor.battery, title: L10n.text("电池", "Battery"))`（标题文字仍锁定；对应上面“小窗标题行”拟议决定）
- `GeekSensorsPowerHoverDetailTests.testBatteryDetailsMatchTheCompactReferenceHierarchy`：原断言电池历史含 `.frame(height: MiniWindowStyleTokens.historyChartHeight)`，改为断言使用绘图块 `.geekHistoryAxis(GeekHistoryAxisFooter(duration: chartRangeSelection.range.duration`（绘图块内部仍按 `historyChartHeight` 设图表高度）
- `GeekHoverDetailTargetTests`（GPU 详情源码检查）：`"GPU 内存"` 改为 `"title: GeekGPUVocabulary.memory"`（对应“显存”拟议决定）
- `CompactGaugeRenderingTests.testProcessorCardRendersCalibratedGeometryWithReadoutAtTrailingInset`：原来按“主文字色”像素找 CPU 卡页头读数；P2 #4 让读数改用负载色后找不到（全量测试首次运行 12 处断言失败）。改为给卡片一个与标题色、图表色都不同的负载色（绿），按该色找读数，仍断言读数可见且右缘对齐卡片内边距（0%、100%、未知，深浅色），几何要求不变（对应“小窗标题行／CPU 负载色”拟议决定）
- 本批自己的 `MiniWindowConsistencyRuleTests`：随修复更新（风扇／GPU 出口、英文 available、坐标行计数与绘图块、正则字面量规则），并新增配色出口、标题与负载色、可用圆点、显存叫法、风扇量程、绘图块实测等测试；新增 `MiniWindowRowLayoutTests`（2 项，实测）与 `MiniWindowLevelOneAnchorTests`（3 项）

没有删除断言、放宽阈值或跳过测试。

### 截图证据局限（P2 #10）

- `menu.gpu.activityHistory` 等场景走调试路由（`presentDebugSnapshotScenario`，在越界文件 `MenuBarAdvancedStatusView.swift`），构造 `GeekGPUHoverDetail`／`GeekFanHoverDetail` 时不传颜色参数；本轮让这两个视图在内部取配色出口，调试路由与实际路由颜色一致，但调试路由仍不覆盖真实悬停路径。
- 基线截图来自已安装的 Beta（Release）包，2b 截图来自 Debug 包；构建配置不同，时序相关的现象（如 P1）不能直接归因于代码改动。演示数据只覆盖默认配色，自定义配色、浅色和英文界面的截图都没有拍。
- 行选中描边（#9 旧项）与压力“正常”配色仍只有代码和测试证据。

### 仍需实机核对

1. 重拍 `menu.processor.secondary`、`menu.cpu.history`（Debug 与 Beta 包各一次）：二级与 CPU 历史顶边应距一级顶边 8 pt（16 px）；可加拍 `a559084` 的 Debug 包验证时序判断。再随手检查其他二级（内存、磁盘、网络、传感器、电源）位置未变。
2. 三级历史：坐标行紧贴图表的观感；网络、GPU、内存压力、内存组成、风扇等页高度应回到 2b 之前。
3. CPU 总占用数值在正常负载下为用户色（蓝），75%／90% 变橙／红；CPU、网络、电池卡图标改为栏目色。
4. 磁盘卷行两行新布局（含网络盘）；“可用”圆点描边在深浅色下的可见度。
5. 英文界面：网络进程列 Upload／Download、电源页 “USING SIGNIFICANT ENERGY … Power”、卷行 “available”。
6. 选一个图表配色主题和自定义 GPU／传感器颜色：GPU、温度、风扇的圆环与历史图同色。
7. 一级锚点：在 CPU 卡与其他卡之间来回悬停、关闭再打开、拖动小窗后再打开二级，二级顶边都应对齐所悬停卡片（窗口移动后的原生锚点刷新属越界建议 1）。

## 结论

部分完成。12 项中：

- 完成：1（D4）、3、4、5、6、8、9、10、11
- 部分完成、方向待用户决定：2（统一了页头组件与样式；“全部有／全部无”会改动测试锁定的参考几何）、7（文字、悬停说明、精度已统一；一级横条改为“已用”会推翻测试锁定的决定）
- 核对为现行设计、未改：12（子级外框顶边对齐来源卡片或行，由会话几何与测试锁定）

## 问题号 → 改动

| # | 结果 | 做了什么 | 提交 · 主要文件 |
|---|---|---|---|
| 1 D4 术语 | 完成 | 内存组成四项中文“应用／联动／压缩／可用”，英文保持 App／Wired／Compressed／Free（“联动”沿用活动监视器“联动内存”译名）。可用行补同尺寸圆点，颜色取圆环底轨色（可用就是圆环未填充部分）；图表仍只画三项。悬停说明、图表无障碍标签、圆环说明、设置窗口里的配色名称同步改为中文；旧布局两行英文 File Backed／Speculative 本地化。设计文档“内存组成”段按 D4 改写 | `bfe0943` · `GeekMemoryCompositionView.swift`、`PanelMetricColors.swift`、`MenuBarAdvancedComponents.swift`、`MenuBarMemoryPanel.swift`、`docs/mini-window-design.md` |
| 2 二级页头 | 部分 | 新组件 `GeekModuleHeader`（模块图标＋12 pt 标题＋右侧读数），CPU、内存二级首卡与一级 CPU／内存／网络／传感器／磁盘卡共用；内存页头原为 11 pt，现与 CPU 一致。页头右侧“16:13”核对为内存快照的采样时间：超过 60 秒变“已过期 · 时间”，暂停变“已暂停 · 时间”，读数不可用时显示原因，悬停有完整证据，所以保留；正常状态改为“采样 16:13”，不再像当前时钟（新增 `headerText`，原 `text` 与其测试不变）。哪些页有页头未改，见“需用户决定” | `a2015fd`、`e760c0d` · `GeekPanelComponents.swift`、`GeekOverviewPresentation.swift`、`GeekMemoryView.swift`、`MenuBarAdvancedComponents.swift` |
| 3 分区标题色 | 完成 | `GeekSectionTitle`：11 pt 半粗体＋栏目标题色（自定义面板配色时跟随）。原来：内存“进程组”用内存压力色（压力升高时橙／红），CPU“进程／CPU 占用／运行时间”用 CPU 负载色，GPU 标题用 GPU 色，网络地址卡与网络三级标题、传感器读数标题、能源模式分组用系统强调色，电源“能源模式／使用显著能耗”用固定信息蓝。现在全部同一规则；状态色只留在数据和按钮上 | `27db359` |
| 4 进程表头 | 完成 | `GeekProcessListHeader`：标题＋采样状态＋可选操作＋列标签。列标签与该页图例同形（彩色圆点＋次要色文字，60 pt 列宽，与行内数值右对齐）：磁盘“读取／写入”（原“读／写”）、网络“上传／下载”（原 ↑／↓），CPU 加“占用”、电源加“功率”（无对应色，只写字）；内存保留“查看全部／选择／内存清理”作为操作区 | `27db359` |
| 5 用词 | 完成 | CPU 一律“用户／系统”：二级“CPU 占用”行（原“34% · 应用 22% · 系统 12%”）、旧处理器面板、未被引用的系统负载卡；英文 Apps → User | `27db359`、`6f718d3` |
| 6 图表配色 | 完成 | 内存压力：圆环与历史图共用 `PanelMetricColors.memoryPressure(for:)`（正常为指标色，升高／严重为警告／危险色，未知为次要色），历史图随当前等级着色。风扇：转速历史由固定青色改为风扇圆环的传感器图表色（含内置传感器三级）。GPU：历史图由 `AppChartPalette.gpu` 改为 GPU 指标色；显存圆环原借用系统内存压力色（压力升高时变橙），改为内存数据色，历史图图例与圆环同色。温度：CPU 页 GPU 温度 80 °C 用的是黄色（caution），传感器页用橙色（warning），统一为同一规则；一级 GPU 圆环显示温度时用温度色 | `af1f786` · `PanelMetricColors.swift`、`GeekHoverDetailTarget.swift`、`GeekProcessorView.swift`、`GeekSensorsPowerHoverDetails.swift`、`GeekSensorsView.swift`、`MenuBarGeekPanel.swift`、`MenuBarTertiaryDetail.swift` |
| 7 磁盘 | 部分 | 一级卡片：文字“X 可用”与横条都表示可用；健康度未知时不再在页头显示与横条相反的“已用 N%”。二级卷行：小圆环为已用，旁边文字改为“44% 已用 · 560 GB 可用”（概念图 107 写法）。“可用”是含可清除空间的系统可用（important usage），一级、二级、三级“系统可用”均加同一悬停说明（含可清除空间，通常大于 df 的空闲）。精度：磁盘页容量用十进制 `storageString`（994.61 GB），累计读取／写入原用二进制 `string`（2.0 TiB），现统一为 `storageString`。横条方向未改，见“需用户决定” | `e760c0d` · `GeekOverviewPresentation.swift`、`GeekDiskView.swift`、`GeekHoverDetailTarget.swift`、`MenuBarDiskPanel.swift` |
| 8 三级坐标 | 完成 | 每个带时间档的三级历史（CPU、GPU、内存压力、内存组成、交换内存、网络、磁盘 I/O、磁盘读／写、温度、风扇、电池）图下加一行 `GeekHistoryAxisFooter`：“−1 小时 … ▢ 未记录 · 纵轴 0–100% … 现在”。量程按图：0–100%、0–100°C、风扇 0 到按读数取整的上限（第二轮更正：原写“0–最高 rpm”不准确，上限来自 `fanTrendMaximum`，不是硬件最高转速），字节类为“纵轴自动”。未记录色块与图内空档共用 `GeekChartDrawing.gapFill`，悬停说明“没有采样，不代表 0”；交换内存是折线、没有空档色块，不显示该图例。图表内部坐标仍关闭（既有契约），视口、悬停、预处理不变，新行只是静态文字；绘图区 154 → 140 pt 让出这一行，三级外框保持 216 pt（第二轮更正：坐标行 12 pt 加页面行距实占 16–18 pt，只有纯图页保持 216 pt，图下有内容的页高 2–4 pt；现改为 140＋14 无间距的 154 pt 绘图块，见“复核意见与处理”） | `e9b1b83`、`8967d43` · `MenuBarGeekCharts.swift`、`MiniWindowStyleTokens.swift`、各历史详情 |
| 9 风扇行描边 | 完成（代码与测试） | `GeekHoverDetailTarget` 新增 `selectionOutset`：选中描边水平外扩。风扇行、温度格、读数行用 4 pt（行距），不压行首文字，仍在卡片 8 pt 内边距内；行布局和悬停区不变。演示截图不呈现“行已选中”状态，未能用截图验证 | `d7d4578` · `GeekHoverDetailTarget.swift`、`GeekSensorsView.swift` |
| 10 间距与图标 | 完成 | `spacing: 7` 全部改 `inlineSpacing`；行级 5 pt 间距、`padding 5/7/9/10` 改 8／6／4 令牌（网络进程行与磁盘进程行同为 6 pt）。测试锁定的标定几何（磁盘 I/O 卡节奏、核心卡高度公式、电源与传感器卡）不变。独立图标槽改用 `AppSymbolGlyph` 与共享槽尺寸：磁盘卷与 VPN 图标（16 pt）、内存选择圈（12 pt）、电源采样与历史不可用图标（11／14 pt）、网络盘徽记、旧布局卡片／行／按钮图标。与文字同排的内联符号（勾选、箭头、标题徽记）继续随字体；`AdvancedAppIcon` 的回退图标属于全应用受审的图标视图，保持原写法 | `5e773f1`、`8967d43`、`165d17e` |
| 11 死代码 | 完成（有保留） | 删除：`TimeRangeSelector`（菜单式时间档，历史页头用的是画布自带选择器）、`GeekDashboardEditor.swift`（从未实例化）、`MenuBarGeekPanel.swift` 里旧仪表盘的指标磁贴生成器、摘要单元、仪表盘行／块、清理摘要卡和两个无人读取的私有属性，约 590 行。保留：`geekFansCard`、`geekSystemLoadCard`、`GeekSection` 虽无调用方，但被测试当作断言目标或分段锚点；旧（非极客）布局 `MenuBar*Panel.swift` 仍由 `MenuBarAdvancedStatusView.swift` 引用（越界文件），未删 | `3bdb10e`、`165d17e` |
| 12 外框逐级下移 | 核对：设计如此，未改 | 二级外框顶边 = 一级被悬停卡片顶边（`MenuBarPanelSession.registeredDetailTopOffset`），三级外框顶边 = 二级外框顶边＋来源行在页内的偏移（`GeekPanelPresentationMetrics.tertiaryVerticalOffset`，测试 `testInlineTertiaryAlignsItsTopWithTheOwningSecondaryRow` 锁定“三级顶边对齐所属行”）。每级外框另有 8 pt 内边距，所以内容看起来逐级下移约 8 pt。概念图（105、107）的级联位置不一致，无法作为反证。改成“内容顶边对齐”需改会话几何（越界文件），见“需用户决定” | 文档 |

## 改动的源码契约测试（每处都只因本批删除死代码，且有注释）

- `GeekDashboardConfigurationTests.testChartRangePickerLivesInHistoryHeaderAndPersistsSelection`：原断言 `struct TimeRangeSelector` 存在、`Image(systemName: "chevron.up.chevron.down")` 与 `.menuIndicator(.hidden)`（均只在已删除的菜单式选择器里）。改为断言该结构不存在、现用选择器保留上下箭头；其余断言不变
- `UIConsistencyRegressionTests.testViewsUseNativeButtonsAndPanelUsesNativeSegmentedControls` 与 `OwnedUIFlatteningContractTests.testCompactPanelUsesSemanticFlatControlsAndExplicitDirections`：删除读取 `GeekDashboardEditor.swift` 的断言（随文件删除）；前者改为断言文件已不存在
- `SystemMonitorServiceTests.testGeekOnlyPanelKeepsRealDataAndSharesOneWindowSession`：删去 `GeekDashboardLayoutPlanner.rows`、`Est. Download`、`Est. Upload`（只在已删除的磁贴生成器里；规划器有自己的单元测试，估算累计量仍由“估算下载量／Estimated Download”等断言覆盖）；风扇平均转速改查仍在显示的“平均转速 / Average Fan Speed”
- `GeekSensorsPowerHoverDetailTests.testSensorAndPowerCardsExposeContextualHoverDetailsWithoutNewSamplingInfrastructure`：`温度 / Temperature` 只出现在已删除的磁贴里，改查一级 GPU 圆环现用的 `温度 / Temp`

D4 没有改动任何既有测试（原测试没有锁定英文四项）。新增测试：`MiniWindowConsistencyRuleTests`（6 项：压力色出口、风扇／GPU 配色、磁盘文字与精度、三级坐标行、选中行外扩、间距令牌与图标槽）、`MenuBarSecondaryVisualConsistencyTests.testMemoryCompositionTermsFollowLanguageAndFreeUsesRingTrackMarker`、`PanelChartNormalizationTests.testMemoryHeaderLabelsOnlyTheBareSampleTime`。

## 需用户决定（本批未改，均有测试锁定现状）

1. **二级页头“全部有”还是“全部无”**（#2）。现状与概念图一致：CPU、内存有标题行，磁盘以卷行作页头，网络、传感器、电源没有。
   - 全部有：网络、传感器、电源首卡需加标题行，会改动 `MenuBarSecondaryVisualConsistencyTests`（传感器圆环卡 74 pt）、`GeekPowerViewTests.testSecondarySurfaceMatchesReferenceCardGeometry`（112／492 pt 与 126／390／163 偏移，偏移还用于电源模式浮层定位）、`UIConsistencyRegressionTests`（网络首卡 150 pt），且偏离概念图 110、111
   - 全部无：去掉 CPU、内存首卡标题，需给共享 CPU 卡加无标题变体并把总占用移到图例行，内存的采样状态要另找位置；偏离概念图 105、106
   - 已用 JEV（jev-latest）对四个方案打分：推荐“保持现有分布、统一样式并交用户决定”，置信 0.84（未达自动通过线），仅作参考
2. **磁盘一级横条改为“已用”**（#7，审阅建议，也与概念图 107 一致）。需改 `DetailedPanelViewProfileTests.testDiskCascadeKeepsOverviewFreeRatioAndRealVolumeCapacity`（锁定一级为可用比例）。改后一级文字可写“44% 已用 · 560 GB 可用”，与二级一致
3. **级联改为内容顶边对齐**（#12）。需改 `Support/MenuBarPanelSession.swift`（批次 4b 文件）与 `Models/SystemMonitorModels.swift` 的偏移计算，以及 `MenuBarPanelSessionTests` 中“三级顶边对齐所属行”的测试

## 未做或做不到

- 容量数值的小数位仍随数值变化（如“299 GB”与“548.36 GB”）：两者都来自 `ByteFormat.storageString`（`ByteCountFormatStyle` 文件样式，去掉末尾 0，与访达一致）。改成固定小数位要改 `Support/ByteFormat.swift`（不在允许范围）和锁定它的 `SystemMonitorServiceTests.testStorageByteFormatUsesDecimalFileStyle`
- 速率单位（KiB/s、MiB/s 等二进制）未动，属批次 5“单位与精度统一出口”
- 换入／换出、切档、窗口位移、“内存清理”改名、电池“正在计算”、压力等级映射、历史时长截断：按要求留给批次 4b
- 内存压力历史按“当前”等级整体着色，不是逐采样着色：历史里只有压力百分比，没有等级；逐点着色需要等级映射（批次 4b）
- 内存进程区的“选择／内存清理”按钮仍用内存压力色：测试锁定（`GeekHoverDetailTargetTests` 断言 `tint: memoryTint`），且与 4b 的改名一并处理更合适
- 演示截图无法呈现“行已选中”的描边（#9）与压力“正常”状态的配色，这两项只有代码与测试证据，需实机复核

## 运行的命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，scratch `~/Developer/.sc-build/batch2b/debug`，`--jobs 4`。

| 命令 | 结果 |
|---|---|
| 基线 `swift build`（`a559084`） | exit 0，87 s |
| 基线全量 `swift test`（`a559084`） | exit 0：3101 项，跳过 22，失败 0（127 s） |
| 各提交后的定向测试（`--filter` 小窗相关 10–19 个测试类） | 每次 exit 0（最多 455 项）；中途发现并修正的失败：`UIConsistencyRegressionTests`（图表文件禁用圆角装饰，`8967d43` 修正） |
| 全量 `swift test`（`dd241ba`） | exit 1：3109 项，跳过 22，3 个断言失败（2 个测试：`AppIconCacheTests` 受审图标回退写法、`GeekSensorsPowerHoverDetailTests` 指向已删磁贴），由 `165d17e` 修正 |
| 全量 `swift test`（`165d17e`）第 1 次 | exit 1：3109 项，跳过 22，1 个测试 2 处断言失败：`SystemUtilitySafetyTests.testOneClickHomebrewSuccessAsksForRescanBeforeClaimingVersions` 取到英文“Command Complete”而非“命令完成”。该测试与本批无关（应用更新文案）；把它与本批两个切换语言的测试放在同一进程连跑 3 次均通过，原因未确认（可能是其他会话同时跑测试、共用 xctest 的 UserDefaults） |
| 全量 `swift test`（`165d17e`）第 2 次 | exit 0：3109 项，跳过 22，失败 0（129 s） |
| **全量 `swift test`（最终 `c8c99be`）** | **exit 0：3109 项，跳过 22，失败 0**（130 s） |
| `python3 script/check_private_api.py`（`c8c99be`） | exit 0（6 处白名单） |
| `git diff --check a559084..HEAD` 与工作区（`c8c99be`） | exit 0 |
| `script/build_and_run.sh --bundle-only`（`e760c0d`，`SWIFT_BUILD_DIR=/tmp/storage-cleaner-batch2b-build`、`DIST_DIR=/tmp/storage-cleaner-batch2b-dist`） | exit 0；其中小窗性能测试 `MenuBarPerformanceRegressionTests`（Release）16 项通过。注意：这次没有设 `STORAGE_CLEANER_VERIFY_ROOT`，性能测试用了默认的 `/tmp/storage-cleaner-verify/release` |
| 截图 `capture-mini-demo.sh … batch2b-mid dark`（14 个场景，`e760c0d` 包） | 14/14 |
| `build_and_run.sh --bundle-only`（`165d17e`，另设 `STORAGE_CLEANER_VERIFY_ROOT=/tmp/storage-cleaner-batch2b-verify`） | exit 0；性能测试 16 项通过 |
| `build_and_run.sh --bundle-only`（最终 `c8c99be`，同上设置） | **exit 0；性能测试 16 项通过**；包 `/tmp/storage-cleaner-batch2b-dist/StorageCleanerMac.app` |
| 截图（最终 `c8c99be` 包，深色，38 个场景） | 分 5 次补齐：`batch2b-after` 12/38、`-r2` 7/26、`-r3` 8/19、`-r4` 10/11、`-r5` 1/1，合计 38/38。漏拍是环境原因，见下 |

### 第二轮（复核意见处理）命令与结果

同一环境与 scratch。没有启动应用、没有截图、没有安装。

| 命令 | 结果 |
|---|---|
| 临时实验测试（未提交）：锚点视图在卡片 `.offset`／布局移动／窗口移动后是否重新报告 | 三种情况登记表都停在旧位置（证实 P1 机制）；修复后跟随 |
| 临时复现测试（真实会话＋外框，级联布局晚 150 ms 送达） | 修复前 CPU 二级顶边偏移 110／33 pt、内存锚点 145 pt；成为正式测试 `MiniWindowLevelOneAnchorTests` |
| 定向测试 20 个类（小窗相关 15 类＋`MiniWindowRowLayoutTests`、`MiniWindowLevelOneAnchorTests`、`GeekOverviewLabelLayoutTests`、`DaylightRefinementTests`、`HoverIntentControllerTests`），最终代码 | exit 0：514 项，失败 0。中途一次 exit 1（4 个测试、5 处断言）：两处是源码写法触到既有检查——枚举 `case .window` 触到 `SystemMonitorServiceTests` 对旧窗口模式的禁止、风扇圆环调用换行触到 `GeekSensorsPowerHoverDetailTests` 的单行检查——已改源码（改名 `overviewOnly`、恢复单行）；另两处是本轮决定改动的契约（电池页头、电池历史图表高度），已按上文更新测试 |
| 反证：注册逻辑还原为 `c8c99be` 写法跑 `MiniWindowLevelOneAnchorTests` | 3 项全部失败（20 处断言），恢复后通过 |
| 反证：表头与卷行还原为旧写法跑 `MiniWindowRowLayoutTests` | 2 项失败（6 处断言），恢复后通过 |
| 各中间提交 `swift build`（`53c9732`、`a91842f`、`bff146b`） | 均 exit 0 |
| `python3 script/check_private_api.py`（`87467d7`） | exit 0（6 处白名单） |
| `git diff --check a559084..HEAD` 与工作区 | exit 0 |
| 全量 Debug `swift test`（`4a7508e`，后被修订为 `87467d7`） | exit 1：3120 项，跳过 22，1 个测试 12 处断言失败（`CompactGaugeRenderingTests` 按主文字色找 CPU 读数，见“本轮改动的源码契约测试”），修订测试后重跑 |
| **全量 Debug `swift test`（`87467d7`）** | **exit 0：3120 项，跳过 22，失败 0**（185 s；未出现已知偶发的 `NetworkCompatibilitySpeedTestServiceTests`／`SystemUtilitySafetyTests` 失败） |
| Release 小窗性能门禁 `STORAGE_CLEANER_VERIFY_ROOT=~/Developer/.sc-verify/batch2b-fix/scratch script/verify_menu_bar_performance.sh`（`87467d7`） | 前 3 次在高负载下 exit 1：16 项中 15 项通过，失败的都是 `testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`（长历史准备 p95 126.7／129.4／115.6 ms，预算 100 ms），当时本机 1 分钟负载 34–39（其他会话的 `toktx`、`fileproviderd`、Google Drive、Blender 等，不是本会话进程），被测的 `MenuBarPreparedChart.swift`、`MenuBarDerivedCache.swift`、`GeekHistoryAveraging.swift` 自 `a559084` 起未改。等 1 分钟负载降到 11.65 后第 4 次：**exit 0，16 项全部通过**（准备 p95 87.4 ms，缓存交付 p95 0.003 ms）。未放宽阈值 |

JEV（jev-latest）对本批改动摘要的复核：`escalate`（需人工复核），safe_to_apply 0.30，加权 0.71（正确性 1.71、需求吻合 1.85、测试缺口 0.88、影响面 1.91，满分 2）。这只是参考，不代替复核与实机检查。

### 截图漏拍的原因（环境，不是代码）

- 应用启动时 `terminateIfDuplicateInstance()` 会让同一 Bundle ID 的较新实例直接退出。截图工具和主会话的主窗口审计脚本（`p1/run-audit-src.sh`）都用 `com.local.StorageCleanerMac.integration`，两边同时跑时会互相让对方的实例退出。13:23–13:29 我对 `165d17e` 包的第一次全量截图与其 `settings-3b-dark`／`responsive-3b-dark` 审计重叠，只拍到 6/38（该目录已被后来的同名运行覆盖）；对方那段时间的输出也可能因此缺图。两边还共用该域的 `app.language` 默认值，脚本结尾会删除它。**建议主会话把这两类截图串行执行，或给每个批次用不同的集成 Bundle ID。**
- 之后没有其他实例时仍有漏拍：被漏掉的实例停在主线程空闲（`sample` 显示在 `NSApplication run` 等事件），既没有崩溃报告也没有日志，重拍同一场景即成功（例如 `menu.overview.baseDark` 在 `c8c99be` 包第 1 轮漏拍、第 2 轮成功）。属于截图流程本身的偶发问题，原因未确认；与改动无关的证据是各轮漏拍的场景互不相同。

## 截图

- 改前：`~/Developer/StorageCleanerMac-evidence/mini/baseline-dark/`（主会话用已安装测试版生成）
- 中途：`~/Developer/StorageCleanerMac-evidence/mini/batch2b-mid/`（`e760c0d`，未含 #8–#11）
- 改后（最终 `c8c99be`，深色）：`~/Developer/StorageCleanerMac-evidence/mini/batch2b-after/` 及同级的 `batch2b-after-r2`…`-r5`（同一个包分批补拍，场景不重复，合计 38 个）
- 对照要点：`menu.memory.composition`（中文术语、可用圆点、页头“采样”、进程组标题）、`menu.memory.history`（压力图随圆环变橙＋坐标行，`-r3`）、`menu.cpu.history`（坐标行，外框仍 216 pt）、`menu.processor.secondary`（进程表头、“用户”、显存圆环，`-r3`）、`menu.disk.secondary`／`menu.disk.volumeInspector`（“44% 已用 · 560 GB 可用”，后者在 `-r2`）、`menu.network.history`（纵轴自动）、`menu.gpu.activityHistory`／`menu.sensor.fanSpeedHistory`（`-r4`，后者为采样占位下的坐标行）、`menu.power.secondary`（“使用显著能耗 … 功率”，`-r3`）

## 风险与复核要点

- 三级历史绘图区矮了 14 pt（154 → 140），坐标行 14 pt 紧贴其下，绘图块仍为 154 pt，三级外框高度与 2b 之前相同（第二轮修正；第一轮实际让图下有内容的页高了 2–4 pt）
- 标题不再随负载／压力变色（例如 CPU 高负载时“进程”标题不再变橙）；状态仍体现在圆环、柱和按钮上
- 显存圆环颜色从“内存压力色”改为内存数据蓝；一级 GPU 圆环显示温度时会在 80／90 °C 变橙／红
- 删除约 590 行死代码，`MenuBarGeekPanel.swift` 改动较大；本批没有改 `GeekMemoryView.swift` 的逻辑，只改标题、表头、间距与图标，4b 合并时应只有小冲突
- 传感器、风扇三级在“正在采样”时也显示坐标行（`c8c99be`），避免数据到达时外框突然变高；第一轮这两页比改前高约 5 pt，第二轮改为绘图块后恢复原高度
- 未跑：严格并发、Release 全量、`script/verify.sh`（按分工由主会话合并后跑）；浅色截图未拍
- 第二轮新增风险：一级卡片锚点在并排时改为“布局框＋级联概览框”推算（`GeekModuleAnchorRegistration`），悬停预览、Escape 抑制等读登记表的逻辑在稳定状态下拿到的仍是真实屏幕框，但过渡中登记的是会话自己的概览框位置；概览单独显示时窗口被拖动后原生锚点仍不刷新（越界建议 1），打开二级后会在级联布局送达时自我校正
- 每张一级卡片多一个背景 `GeometryReader`（只在位置变化时登记）；Release 小窗性能门禁在负载降下来后 16 项全部通过，高负载时长历史准备预算会超时（被测代码未改），合并后的完整门禁应在空闲时跑
- GPU、温度、风扇历史关闭图表单色重染，自定义图表配色下颜色来自与圆环相同的出口（仍是主题色，除非用户自定义了该指标色）
- CPU 总占用数值在正常负载下变为用户色（蓝），不再是主文字色；磁盘卷行结构改为两行新布局

## 本批提交

第二轮（`95626aa..`）：`181623c` 复核 P1 一级锚点 · `53c9732` P2 #2 间距字面量 · `a91842f` P2 #6／#7 卷行与 available · `bff146b` P2 #9 可用圆点描边 · `87467d7` P2 其余（绘图块、配色出口、标题与负载色、表头、显存、坐标行读屏）· 文档与本交接另作一个提交。

第一轮（`a559084..c8c99be`，共 14 个）：

`bfe0943` D4 术语与可用圆点 · `27db359` 标题色／进程表头／CPU 用词 · `a2015fd` 模块页头与“采样”标签 · `af1f786` 环与历史同色 · `e760c0d` 磁盘文字、说明与精度 · `e9b1b83` 三级坐标行 · `d7d4578` 选中行描边外扩 · `8967d43` 方形“未记录”色块（含两处间距）· `5e773f1` 间距令牌与图标槽 · `6f718d3` 其余 CPU“用户” · `3bdb10e` 删除死代码 · `dd241ba` 设计文档 · `165d17e` 受审图标回退与一处断言 · `c8c99be` 采样占位下的坐标行。本交接另作一个提交。
