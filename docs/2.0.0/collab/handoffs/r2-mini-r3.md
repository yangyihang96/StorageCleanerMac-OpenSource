# r2-mini-r3：2026-10-11 小窗实机意见修订

## 基线、授权与交付状态

- Worktree：`/Users/developer/Developer/sc-worktrees/r2-mini-r3`；分支 `task/r2-mini-r3`；基线 `1a3b6822990634a4aaea5ed20894956f7bd81fc4`。开始时 `git status --short` 为空。
- 已读批次 common.md、codex-build-common.md、RULES.md、D5/D48/D55/D60/D74/D75、BOARD.md。BOARD 里没有 r2-mini-r3 独立条目，本用户消息为批次范围依据。沙箱内构建按 codex-build-common.md 2026-10-09 补充执行；只读 .git 按 prepared/ 交付，不提交、不合并。
- 已直接查看 user1011 全部 8 张原截图与四张指定 iStat 参考图；追加 (c) 又查看 live1011 六张实数据图及 JSON。电源三级卡片内容保持原设计；CPU 图表按后续授权调整，具体结论见追加节。输入截图是改前证据，不能作为本批改后通过证明。
- 禁止范围未改：ScanStore.swift、Features/AppUpdates/**、硬件控制写入路径。CPU 图表在第一阶段保持不动，追加 (c) 后仅改共用 CPU 卡片比例，历史时间映射保持。未启动/安装 App，未写硬件设置。

## 实现与理由

1. 顶部采样行：删除共用 MiniWindowStoredSampleAge 及总览/二级页调用；取消总览 24 pt + sectionSpacing 与二级 24 pt + detailSpacing 的高度预留。保留 contentPadding；显式暂停状态行、历史时间轴、采样来源与悬停帮助仍表达真实状态。移除原来每秒刷新的顶部 TimelineView。
2. 电池二级页：仍走 GeekOverviewModuleButton → preview/selectGeekSection → 共用 GeekPanelCoordinator → MenuBarPanelSession 级联。根因是自然高度超屏时 CascadeViewportLayout 的 compact 回退；在拥有范围内给 MenuBarAdaptiveCascade 的 reflowingCascade 新增默认 false 的 scrollsTallDetails，电源的二级和预留三级两处传 true。只约束列的视口高度；原有 MiniWindowFittedPage 保持自然高度、列内滚动，总览保留，悬停/固定/Esc 沿用共用路由。电池/健康、历史、电气、功耗、能源模式、显著能耗卡片全部保留。其他模块未开启此选项。真正无法容纳共用列宽的极窄屏仍遵守已有通用回退，不缩放字号或覆盖列；这不是电池独有导航。
3. 公网 IP：PublicNetworkConsent 缺键使用 true，已保存 false 仍为 false，不登记/写入默认键；小窗与设置 AppStorage 用同一 defaultAllowsAddress。设置说明默认开启、可关闭，以及实际服务 api.ipify.org / api6.ipify.org；国家/地区继续单独允许 api.country.is。原请求服务无新计时器，沿用成功 15 分钟、失败 60 秒、网络签名变更刷新与单次在途请求。移除 combinedDemand 中 prestored 对公网 IP 的隐含需求，以可见网络消费者为准；隐藏/退出消费者取消在途请求，原 resident 的 CPU/温度/进程/网络等 D75 节奏不改。恢复网络页按缓存检查，不 force。
4. 系统助手：新增 GeekHelperPowerMetricsCards，使用同一个 store.helperPowerMetricsMonitor 的被动叶级订阅，由已有 resident 调度采样；呈现本身不注册额外需求、不启动计时器、不调用 XPC。功率 CPU/GPU/神经网络引擎与频率 性能簇/能效簇/GPU 复用 geekSensorReadoutCard。缺失通道省略、有效零保留；整类无读数用同款卡片的一行灰色说明和“开启”入口；入口只请求设置导航到 accessAndSetup 与 SystemHelperSettingsNavigation.anchor，不安装/授权助手。powermetrics 来源与原采样时间放在悬停帮助/现有读数详情。主窗口 HelperPowerMetricsView 与原格式不改。

### 范围外最小改动（用户在本会话明确追加授权）

- Services/BoundedHTTPSReader.swift：仅 PublicNetworkConsent 地址默认值，新增 defaultAllowsAddress 与可注入 UserDefaults 的读取入口以验证缺键/显式关闭；BoundedHTTPSReader、重定向、响应限制、country 同意逻辑不动。
- Views/SettingsView.swift：仅对应 @AppStorage 初始值从 false 改为 PublicNetworkConsent.defaultAllowsAddress；其他内容不动。

## 旧断言逐项改写依据（D76）

| 原断言 | 本轮断言 | 依据 |
|---|---|---|
| UIConsistencyRegressionTests 的设置说明必须含“公网 IP 与地区查询须分别同意” | 必须含“公网 IP 可关闭，地区查询须另行同意” | 用户已授权地址查询默认开启，地区仍单独同意；仍锁定可关闭与地区边界 |
| 同测试的英文说明必须含 public-IP and region lookups require separate consent | 必须含 public-IP lookup can be turned off, and region lookup requires separate consent | 同上，双语行为一致 |
| D64DeclutterAContractTests 的同两条中英文说明字符串 | 改为同样两条新版说明字符串 | 同上；实际服务域名、不保存密码、硬件失联/过热保护等原断言保留 |
| HelperPowerMetricsMonitorTests.testEverySurfaceUsesTheSameMonitorAndWindowVisibilityControlsDemand：三处页面必须直接调用 HelperPowerMetricsView(monitor: store.helperPowerMetricsMonitor...) | 主窗口仍直接调用原组件；传感器/电源页使用 geekHelperPowerMetricsCards，新卡片必须接同一 store.monitor 并 ObservedObject 订阅、不得 updateConsumer | 用户要求仅小窗改分类卡片；仍锁定单个共享采样流。原组件的遮挡/睡眠/隐藏检测断言保留 |

没有找到既有测试直接锁定“缺键地址默认 false”或“电源必须单栏导航”；这些是基线实现行为，D76 记录取代依据，新增默认值、列内滚动与公共路由测试。原 HelperPowerMetricsPresentation 的缺助手六个“—”断言保留，因为它仍用于未要求改动的主窗口；小窗使用独立分类呈现，新增测试明确要求没有空值行，未删除/跳过旧断言。

## 场景

| 场景 | 行为 |
|---|---|
| menu.sensor.secondary | 默认有助手读数：功率/频率卡片 |
| menu.sensor.secondary.noHelper（新增） | 无助手读数：两类灰色说明与开启入口 |
| menu.power.secondary | 原电源卡片 + 功率/频率，左侧二级列滚动 |
| menu.power.secondary.noHelper（新增） | 原电源卡片 + 无读数入口，保留总览 |
| menu.network.secondary | 固定演示 IPv4/IPv6 示例，默认开启即可展示 |
| menu.network.secondary.unavailable（新增） | 无公网读数，显示暂不可用，保留本地 IP/网络卡片 |

新场景都是 secondary 路由，expectedPanelCount=2，不允许演示调用真实助手/公网服务，不伪造真实机器的测量完成。原时间与 CPU fixture 未变。主会话应通过同一 capture-mini-demo.sh 离屏入口按上述场景生成改后证据，与 user1011 原图并排。此脚本不在本 worktree 的已跟踪文件中；本批遵守“不启动 App”，未运行截图入口。

## 定向测试、构建与反证

清单：`/Users/developer/Developer/.sc-build/r2-mini-r3/targeted-classes.txt`（含 UIConsistencyRegressionTests、TestPreferenceHygieneTests、MenuBarPerformanceRegressionTests、MiniWindowSpeedTests、MiniWindowSpeedBehaviourTests）。新增纯偏好夹具只用 TestPreferenceDomain，helper/公网提供者注入，无需家目录操作夹具。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
B=/Users/developer/Developer/.sc-build/r2-mini-r3
F=(--disable-sandbox -Xswiftc -disable-sandbox --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --scratch-path "$B/debug" --build-tests
FILTER=$(paste -sd '|' "$B/targeted-classes.txt")
swift test "${F[@]}" --scratch-path "$B/debug" --skip-build --filter "$FILTER"
swift build "${F[@]}" --build-system native --scratch-path "$B/release" -c release --build-tests -Xswiftc -enable-testing
swift test "${F[@]}" --build-system native --scratch-path "$B/release" -c release -Xswiftc -enable-testing --skip-build --filter "$FILTER"
```

离线依赖仅复制自 `/Users/developer/Developer/.sc-build/r2-u1-preselect/debug/{checkouts,repositories,artifacts,workspace-state.json}`，Debug/Release 用本批 scratch，不改全局缓存。

第一阶段反证计划写入 scratch `counterexamples.json`（最初 9 项，追加后 15 项，NOT RUN，主会话执行）：恢复顶部行、移除 power 的视口选项/绕过其约束、默认关闭、覆盖显式关闭、恢复隐藏公网预存请求、缩短缓存/重试、恢复助手空值行、频率错入功率标题。每项提供真实可编译变更与会失败的测试名；在隔离副本逐项应用，预期 red，恢复本轮最终文件后跑同测试预期 green；不要在当前 worktree 或真实偏好上做反证。

## 第一阶段验证记录（CPU 追加前）

- 首轮 Debug：应用源码编译成功；新增场景测试缺少 tuple 显式枚举类型，编译失败（exit 1），已补类型。日志 debug-build.log 保留。

| 项目 | 结果 | 证据 |
|---|---|---|
| Debug --build-tests | PASS，exit 0（修正场景 tuple 类型后的最终构建） | scratch/logs/debug-build-2.log；Build complete 38.32 s |
| Release 默认 Swift Build 引擎 | BLOCKED，exit 1 | scratch/logs/release-build.log：GenerateDSYMFile MemoryFixtureApp.dSYM 返回 Operation not permitted；已清理这次失败的 release/out 临时产物 |
| Release Native Build System | PASS，exit 0，548.34 s | scratch/logs/release-build-native.log；使用工具链 --help 列出的 --build-system native，其余为 -c release --build-tests -Xswiftc -enable-testing；有既存 weak-mutability 与 native 引擎弃用提示，无本轮源码错误 |
| Debug 20 类定向清单 | FAIL（环境限制），exit 1：340 项、1 个既有跳过、54 条失败断言 / 53 个失败用例 | scratch/logs/debug-targeted.log；优化性能计时测试仅在 Release 执行，所以 Debug 原有跳过保留 |
| Release 同清单 | FAIL（环境限制），exit 1：325 项、0 跳过、53 条失败断言 / 52 个失败用例 | scratch/logs/release-targeted.log；演示测试按既有 DEBUG 编译条件不进入普通 Release |
| 新增 MiniWindowUser1011Tests | PASS：Debug 10 / Release 9 项，0 失败 | 上述定向日志；Release 不包含 Debug-only 场景检查 |
| PublicNetworkAddressServiceTests | PASS：Debug / Release 各 8 项，0 失败 | 默认缺键/显式关闭、可见范围注入请求计数、缓存/重试边界通过 |
| UIConsistencyRegressionTests | PASS：Debug / Release 各 46 项，0 失败 | 上述定向日志 |
| 小窗性能与速度 | PASS：MenuBarPerformanceRegressionTests 各 16 项（Debug 既有跳过 1、Release 0），MiniWindowSpeedTests 各 3、MiniWindowSpeedBehaviourTests 各 2 | Release optimized preparation p95=82.422 ms（预算 100 ms），cached delivery p95=0.001625 ms，未放宽预算 |
| TestPreferenceHygieneTests | BLOCKED：两用例 / 三断言在两种构建均失败，其余通过 | 偏好 daemon sandbox_extension_issue_file ... Operation not permitted，无法产生/跨线程落盘读取 plist；保留测试原文，交主会话复跑 |

环境受限用例完整清单和每项原始错误：`/Users/developer/Developer/.sc-build/r2-mini-r3/evidence/sandbox-blocked-tests.json`。分类如下，没有删除断言、新增 XCTSkip 或放宽路径检查：

- MenuBarPanelSessionTests：47 个需要 NSScreen 的原生面板用例，沙箱中取得 nil（Tests require an attached screen）。逻辑路由、纯屏幕矩形布局测试通过；实机hover/窗口行为仍需主会话复验。
- HelperPowerMetricsMonitorTests：1 个 ScanStore 工厂接线用例；MenuBarPrestoredSamplingTests：2 个工厂用例；Debug 的 MiniWindowDemoDataTests：1 个 cleanup 演示工厂用例。都在创建 `~/.storage-cleaner-scan-store-UUID/home` 时 Operation not permitted，不改工厂和产品安全规则。
- TestPreferenceHygieneTests：testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory（两断言）、testTemporarySuiteCanBeReopenedOnAWorkerThread（一断言）受偏好落盘沙箱限制。新增偏好逻辑测试的进程内读取通过，不能代替这两个实际落盘守卫。

本批没有测试需要主会话另行清理的保留 operation fixture；失败发生在根创建阶段，日志保留。完整定向清单仍保留受限类，主会话应在沙箱外原样复跑，不只跑成功子集。

- 静态：git diff --check、python3 script/check_private_api.py 已通过（7 个允许用途）；后续交付再次核对。
- JEV：工具元数据可用，jev_decide 参数没有 model 配置；一次评估调用在执行前被拒绝：MCP tool call requires approval, but approval policy is never。没有取得模型标识或判断，不记为已调用/通过；未绕过审批或换模型。
- 完整门禁、反证、改后离屏截图、独立复核、提交、合并、安装、实机验收：NOT RUN，由主会话执行。本批无 .git 写入。

## 第一阶段 prepared/（由追加交付更新）

最终分组（21 个改动文件）：01-public-ip（默认/显示/需求约束/偏好与说明测试），02-mini-panels（去顶部行、电源滚动、分类卡片、演示与小窗回归），03-handoff（D76 与本交接）。manifest.json 记录完整基线、分支、最终文件及各产物 SHA-256；all.patch 含新增文件。commit-prepared.py 仅在主会话验证后显式 --validated 执行，先核对基线/分支/工作区/所有 SHA 与暂存区，再按顺序提交；脚本不构建/安装/推送。

最终准备校验：git diff --check、私有 API 守卫通过；prepared/ 在本批拥有的临时源码副本上反向 all.patch 恢复精确基线，再按 01→02→03 应用并核对全部 21 个最终 SHA-256，PASS。未写 .git。临时源码副本与独立 dSYM 探针产物已删除；保留正常 Debug/Native Release 构建以供主会话复验，合并后按 RULES 清理。

## 2026-10-11 追加 (c)：CPU 图表与处理器频率

### 时间轴调查结论与只读证据

已看 live1011 的 processor secondary/history、sensors secondary/history、power secondary/history 六张实数据图及对应 JSON，并重看 iStat 的 CPU/GPU 和 combined 图。截图版本为 20261011071824，JSON 没有原始样本数、最早时间或准确截图时刻，因此不能仅凭“QA 运行约 90 秒”推断输入历史只有 90 秒。

**本基线未复现稀疏历史被拉伸的缺陷，确认 QA 根里有恢复的旧历史。** 修改图表源码之前，新增两个真实准备路径测试，用 90 条一秒样本（最近 −89 s 至现在）、1 小时窗口、1×/2× 与参考时刻偏移，原始桶、平均桶、CPU 直接/共享帧、网络/内存/GPU/传感器均只在最右约 90/3600 有值，左侧至少 116/120 桶未记录，无 estimated。日志 cpu-history-baseline-tests.log（2 项 PASS）；这部分映射代码与当前主开发副本逐字节相同。

只读读取 `/Users/developer/Library/Caches/StorageCleanerIntegration-mini-live1011/Monitoring/MetricHistory-v1.json` 的日期与条数，没有改动该文件或真实偏好：

| 系列 | 检查点条数 | 最早 UTC | 最晚 UTC | 按运行开始 +90 s 推算的小时内条数 / 有观察的 30 s 桶 |
|---|---:|---|---|---|
| telemetry | 4,231 | 2026-10-06 01:49:59.443302 | 2026-10-11 09:00:59.091809 | 3,294 / 116 |
| memoryTelemetry | 4,231 | 2026-10-06 01:49:59.443329 | 2026-10-11 09:00:58.063405 | 3,293 / 116 |
| power | 5,885 | 2026-09-13 09:04:34.755648 | 2026-10-11 09:00:41.234282 | 114 / 112 |

run.log 的开始为 Sydney 2026-10-11 20:01:47.824，即 UTC 09:01:47.824。检查点所有上述样本都早于这次运行开始。小时覆盖数使用报告的约 90 秒估算，不冒充准确捕获时刻或检查点之外的 journal 最终条数。完整只读元数据、SHA-256 与计算说明在 scratch/evidence/cpu-history-qa-provenance.json；没有复制原始历史内容。

恢复链：AppDataDirectories 为 integration bundle 提供隔离根 → MetricHistoryStore.live() 把新 URL 与旧 `~/Library/Application Support/com.local.StorageCleanerMac/MetricHistory-v1.json` 同时传入 → load() 在新记录不存在时解码旧记录 → ScanStore 的只读恢复调用 restoreHistory(snapshot.telemetry/memoryTelemetry)，辅助状态恢复 power。新目录依旧接受 legacy 迁移，不能视为无历史。新增 `testAFreshDestinationCanRestoreHistoryFromTheExplicitLegacySource` 在纯临时 JSON 夹具验证此链，来源文件保持相同；没有改 ScanStore 或迁移规则。

barRange 的 start/end 始终是完整选定窗口，dataStart 只排除采样前记录；barBucketMarksWithSlots 的比例分母是 end-start，不是 end-dataStart。1 小时分支按 600 个固定 6 s 观察窗投影，空窗没有均值。短窗 estimated 只在实测前后点之间且未跨暂停时填补；新增短窗边界测试单独守住这一点。增加功率共享路径及实际左侧灰色块渲染检查，不删除短缺口估算或有效旧历史。

按用户“若查明并非缺陷则写清证据”的分支交付：本项没有捏造源码修复，也不把基线已绿说成 red→green。counterexamples 中增加把 barRange.start 错改为 dataStart、去掉插值的 before 边界两个真实可编译变更，它们必须使新增测试变红，恢复正确时间映射后回绿；主会话按 common 执行，沙箱内未做反证。

### CPU 卡片比例与频率空值

- GeekPanelComponents / GeekOverviewPresentation / MenuBarGeekCharts：共享 CPU 卡片图表高 51→60 pt，VStack 间距 3→1 pt，CPU 专用 verticalInset=0；外框 106 pt、字体、0–100% 纵轴、用户/系统叠放顺序和现有蓝/粉（或用户颜色）保持。原有效绘图高 47 pt，现在 60 pt，增加约 27.7%。二级顶部调用同一 geekProcessorCard；其他图表默认 4 pt 上缘保持，时间映射没有修改。
- 1×/2× ImageRenderer 用纯值组件验证：100% 柱占至少 58 pt，标题后不出现额外空白，系统在上/用户在下，外框不增高，所有柱宽相同、间隙一个物理像素。不启动 App、无真实采样或硬件请求。RGB 夹具按色相主通道识别，兼容 SwiftUI 色域转换；第一次测试把转换后红色的绿色分量 0.149 误当非红，已修正分类方法，高度与布局断言不变，失败/probe 日志保留。
- GeekSensorsView 的 GeekProcessorFrequencyPresentation：只创建存在且有效的原生频率行，最高核心组/逐簇/GPU 缺测不输出“—”；有限非负零照常显示，实际 GPU 关闭的 IOReport 读数仍显示“空闲”。来源与原 sampledAt 保留，GPU ring 的既有 formatter/未知行为不改。
- GeekProcessorView：无原生频率时复用 GeekHelperPowerMetricsCards 的被动订阅与 geekHelperReadoutCard。助手有频率就显示；无值就一行灰色说明和现有“开启”入口，只跳转设置 › 权限 › 系统助手。存在的原生 IOReport 读数优先，不把助手缺连接当成这些独立读数失效；不加消费者、计时器、XPC 或授权调用。
- 此阶段没有改写旧测试断言；原 GPU 缺值 formatter、D43 标题、CPU 固定量程、性能预算、D74/D75 守卫保留。D76 CPU 补充取代第一阶段“不改 CPU”的范围决定。前轮公网 IP 的两处追加授权修改保持最小，没有再扩展。

### 新增离屏场景

| 场景 | 输入及预期 |
|---|---|
| menu.cpu.history.shortRecording | 正好 90 条、−89 s 到现在；三级 1 小时左侧未记录，仅右侧约 2.5% 有柱；expectedPanelCount=3 |
| menu.processor.secondary.noFrequency | 原生频率 nil、助手 needsHelper；频率卡一行灰色说明 + 开启；expectedPanelCount=2 |
| menu.processor.secondary / menu.cpu.history | 原有有频率/一小时 fixture 保留；CPU 卡片使用同一新比例 |

短记录 fixture 重新通过初始化器构造日期及来源时间，不写真实存储，不缩放旧时间轴。采样服务/CPUPerformanceStateService、GeekHistoryAveraging、D74/D75 的频率与保留规则未改。

### 追加验证与 prepared 状态

最终清单为 27 类，保留 UIConsistencyRegressionTests、TestPreferenceHygieneTests 和三类小窗性能/速度测试，加入共享历史平均、gap、D43、悬停详情、需求与范围切换守卫。主会话沿用上文命令与全部清单；Release 继续使用 native 引擎、`-c release --build-tests -Xswiftc -enable-testing`，scratch 为本批 release。最终源码已在 Debug 与 Release 均编译通过。

| CPU 追加最终项目 | 结果 | 证据 |
|---|---|---|
| 修改生产图表之前的 90 s / 1 h 基线复现 | PASS：2 项，确认原映射正确 | scratch/logs/cpu-history-baseline-tests.log |
| Debug --build-tests | PASS，exit 0；最终增量 7.20 s，前次完整编译 66.39 s | scratch/logs/cpu-final-debug-build-3.log、cpu-final-debug-build-2.log |
| Release Native --build-tests -enable-testing | PASS，exit 0，380.24 s | scratch/logs/cpu-release-build.log；未重试受限的默认引擎 dSYM |
| Debug 27 类定向清单 | FAIL，exit 1：423 项，1 个既有跳过，54 条断言 / 53 个失败用例 | scratch/logs/cpu-debug-targeted.log；逐个失败用例与第一阶段完全相同 |
| Release 同 27 类清单（26 类实际编入，MiniWindowDemoDataTests 既有 DEBUG 条件） | FAIL，exit 1：402 项，0 跳过，53 条断言 / 52 个失败用例 | scratch/logs/cpu-release-targeted.log；逐个失败用例与第一阶段完全相同 |
| MiniWindowCPUChart1011Tests（新增） | PASS：Debug 11 / Release 10，0 失败 | 两份当前定向日志；Release 不包含 Debug-only 场景检查 |
| 共享历史、D43 与需求守卫 | PASS：两种构建分别有 GeekHistoryAveragingTests 13、MenuBarHistoryGapTests 9、MiniWindowD43LayoutTests 4、MiniWindowHistoryDemandTests 6、MiniWindowRangeSwitchTests 10；GeekSensorsPowerHoverDetailTests 为 Debug 30 / Release 25 | 两份当前定向日志 |
| 原本批意见、公网与 UI 回归 | PASS：MiniWindowUser1011Tests Debug 10 / Release 9；PublicNetworkAddressServiceTests 各 8；UIConsistencyRegressionTests 各 46 | 两份当前定向日志 |
| 小窗性能与速度 | PASS：性能各 16 项（Debug 既有跳过 1、Release 0），速度各 3 + 2 项 | Release preparation p95=82.443667 ms < 100 ms，cached delivery p95=0.001750 ms；预算与断言不改 |
| TestPreferenceHygieneTests / 原生面板及工厂环境守卫 | BLOCKED，与第一阶段完全同一组用例，未删除/跳过或降低要求 | scratch/evidence/sandbox-blocked-tests.json 更新每项当前原始错误；两份 cpu-*-tests.json 记录完整分类汇总 |
| 静态与保护范围 | PASS：git diff --check、私有 API 守卫（7 个允许用途）；采样计划、历史平均/迁移、ScanStore、AppUpdates、CPUPerformanceStateService 均未改 | scratch/evidence/static-checks.json |

CPU 追加开发过程的失败日志保留：最初新增测试误用不存在的 fan 指标，改为既有 fanRPM；短记录 fixture 曾直接设置只读 date 导致编译失败，改为初始化器；原生渲染颜色分类问题见上文。它们已经修正，未将失败日志覆盖为通过。当前定向失败不包含新增 CPU 测试，原因仍为 NSScreen 不可用、家目录夹具写入限制与偏好 daemon 落盘限制。整体定向运行没有全绿，不能把新增测试通过替代完整门禁或实机验收。

counterexamples.json 现为 15 项（NOT RUN）：原 9 项保留，新增小时拉伸、短窗越界插值、CPU 旧高度/额外标题空白、处理器空值行、短记录场景退回一小时。所有 from/count 静态核对；每项红后恢复最终文件、同测试绿，不改真实 QA 记录。

最终 prepared/ 覆盖本批全部 26 个文件（22 个已跟踪改动 + 4 个新文件），3 组：01-public-ip → 02-mini-panels → 03-handoff；02 增加 CPU 比例、频率与历史证据测试。`all.patch` 是整个批次的最终累积改动，manifest.json 的全部源文件和产物 SHA-256 已更新；新增只读 QA 来源元数据、Debug/Release 分类结果与环境失败清单随 prepared 一起交付。

最终分组往返 PASS：在本批临时源码副本反向 all.patch 恢复 1a3b6822 的精确内容，再按三组顺序应用并核对全部 26 个最终 SHA-256；临时副本已清理。没有写 .git。提交/合并/安装/新离屏截图、完整门禁、反证、独立复核和用户实机验收仍由主会话执行；commit-prepared.py 只在主会话完成这些验证后显式 `--validated` 使用。

主会话实数据复验应在采样前记录输入最早/最晚日期、条数、恢复来源；验证“仅新 90 秒”时用注入且不带 legacy URLs 的临时 MetricHistoryStore 或上述短记录 fixture，不能仅靠新 QA 目录推断空历史。保留旧记录和有效历史；这不是把原始图表截图作废。当前新比例和频率样式仍需改后离屏与用户实机验收。
