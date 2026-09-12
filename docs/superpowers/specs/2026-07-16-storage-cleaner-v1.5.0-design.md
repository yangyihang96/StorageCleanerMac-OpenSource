# 存储清理助手 v1.5.0 设计规格

日期：2026-07-16

状态：用户已于 2026-07-16 明确批准

目标版本：1.5.0

目标系统：macOS 14 及以上，重点验证 macOS 26

## 1. 版本目标

v1.5.0 是一次较大功能升级，需要在不牺牲菜单栏常驻性能和操作安全的前提下完成五项工作：

1. 修复菜单栏小窗只在第一个桌面出现的问题，使其始终出现在用户当前点击状态项的桌面与屏幕。
2. 修复网络测速把真实成功结果误判为失败的问题，并增加完整状态、流量安全、质量分析和受控兼容模式。
3. 将“电脑健康”升级为与主应用风格一致的健康驾驶舱，增加可解释评分、可信度、历史趋势和本应用独有算法。
4. 增加独立的“Mac 跑分”功能，真实测试 CPU、GPU、内存和启动卷临时文件吞吐。
5. 修复“安全清理”页面进入后整体上移、顶部内容进入标题栏并被裁切的问题，同时保持列表滚动位置稳定。

版本完成还包括自动化测试、真实运行、性能与卡死回归、打包安装、源码与更新仓库 Release、Sparkle appcast、真实 1.4.0 升级验证以及开发中间产物清理。

## 2. 已确认的现状与根因

### 2.1 菜单栏小窗

当前 `MenuBarStatusController` 在整个进程期复用同一个 `NSPopover`。它没有当前 Space 策略、屏幕定位策略，也没有监听 `NSWorkspace.activeSpaceDidChangeNotification`。AppKit 内部 popover 窗口会保留首次显示时的 Space 归属，因此在其他桌面点击后仍回到第一个桌面显示。

`NSPopover` 不公开其内部窗口，无法通过受支持 API 稳定修补 Space 行为。继续复用同一实例不是可接受方案。

### 2.2 网络测速

当前服务运行 `/usr/bin/networkQuality -c -M 20`，但解析器要求 `responsiveness` 必须是无小数的整数。当前 macOS 会合法返回诸如 `749.993347` 的 RPM，因此系统命令退出码为 0、结果完整，应用仍抛出 `invalidOutput` 并显示“测试未完成”。

本机同参数实测约 20.1 秒，下载约 730.5 Mbps、上传约 68.1 Mbps、空闲延迟约 31.6 ms、响应能力约 750 RPM，同时产生约 1.745 GB 流量。现有同意文案没有说明完整系统测速可能消耗数百 MB 至数 GB。

当前实现也没有区分系统测速服务不可用、离线、超时、受限网络、取消收尾和解析失败；成功退出还会被直接标成“健康”，没有真正根据质量指标判断。

### 2.3 电脑健康

当前健康中心已能探测磁盘、容量、Time Machine、稳定性和电池，也有单次刷新并发控制，但没有独立的电脑健康总分、评分解释、覆盖率或完整健康历史。

现有 `SmartScoreBreakdown` 是“存储扫描评分”，不能改名后冒充电脑健康分。CPU/GPU 使用率和频率属于瞬时遥测，也不能反推出真实性能分数。

### 2.4 Mac 跑分

当前项目没有真实跑分工作负载。`CPUPerformanceStateService` 和 `GPUPerformanceService` 读取的是 residency/利用率遥测，不是处理吞吐。新跑分必须执行受控、可取消、可复现的计算和 I/O，不能用使用率、温度或设备型号估算。

### 2.5 安全清理页面上移

真实安装版已经复现：`cleanupWorkspace` 在“可安全清理”标签中，把可变高度的 `PrivacyCleanupView` 叠在一个声明为全高的 `ItemListView` 或 `ToolPreparationView` 上。组合内容的理想高度超过窗口后，SwiftUI 将溢出内容居中，导致顶部分段控件和隐私面板进入标题栏并被裁切。

切换到没有隐私面板的“Codex 与开发产物”标签后布局立即恢复，证明问题来自容器高度与对齐，而不是用户手动滚动。

## 3. 设计原则

- 使用公开、受支持的 macOS API；不使用私有 Space、SMC 控制或裸磁盘接口。
- 只展示真实测得或明确推导的数据；缺失、不可用和不适用必须分开。
- 所有分数都必须显示算法版本、构成、数据覆盖率和时间，不制造虚假精确度。
- 健康评分、网络质量分和性能跑分是三个不同概念，不能混为一个数字。
- 扫描、测速、健康深度检查和跑分必须显式触发；进入页面和后台菜单栏刷新不能自动启动重任务。
- 菜单栏一秒刷新只读取轻量实时指标或缓存，不运行完整进程扫描、磁盘命令、测速或跑分。
- 所有外部命令、网络任务、计算工作负载和文件 I/O 都必须可取消、可超时、脱离主线程并有迟到结果保护。
- 只展示可操作、可解释的内容；没有实际用途的设置、重复按钮和装饰性数据不进入页面。
- 沿用 `AppDesignTokens`、`glassPanel`、系统动态颜色、等宽数字和现有网络上下行颜色。
- 电池、隐私与高流量网络行为继续采用“安全引导模式”。

## 4. 信息架构

主导航保持现有结构，并在“系统工具”组新增一个独立入口：

1. 智能扫描
2. 电脑健康
3. 存储
   - 安全清理
   - 文件分析
4. 系统工具
   - 登录项
   - 内存管理
   - 应用能耗
   - Mac 跑分
   - 应用卸载
   - 已安装应用更新

“Mac 跑分”使用新的 `ReviewFilter.benchmark`，但不增加第二套侧边栏或独立设置页。

电脑健康内部使用同页驾驶舱，不为磁盘、电池、备份等模块各建侧边栏入口。

## 5. 菜单栏当前桌面面板

### 5.1 窗口模型

将进程期永久复用的 `NSPopover` 替换为每次打开新建、关闭即销毁的短生命周期非激活式 `NSPanel` session。

职责拆分：

- `MenuBarStatusController`：状态项、轻量数据刷新和当前 session 协调。
- `MenuBarStatusPanel`：极薄的 `NSPanel` 子类，可成为 key、不能成为 main。
- `MenuBarPanelSession`：panel、hosting controller、事件 monitor、通知 observer 和幂等 teardown。
- `MenuBarPanelPlacement`：纯几何定位函数。
- `MenuBarStatusPanelRoot`：沿用现有 SwiftUI 精简/详细内容。

窗口策略：

- `styleMask = [.borderless, .nonactivatingPanel]`
- `collectionBehavior = [.moveToActiveSpace, .transient, .ignoresCycle, .fullScreenAuxiliary, .canJoinAllApplications]`
- 明确不包含 `.canJoinAllSpaces`
- `.canJoinAllApplications` 只允许该浮层加入其他应用的窗口集合和符合条件的全屏 Space，不表示在所有 Space 同时可见；它不与 `.fullScreenAuxiliary` 冲突，也不能再组合互斥的 `.primary` / `.auxiliary`。
- `level = .popUpMenu`
- 透明、非不透明、保留阴影，不在 AppKit 层重复添加材质
- 不调用 `NSApp.activate`，不使用 `orderFrontRegardless`
- 减少动态效果时关闭 panel 动画

### 5.2 当前屏幕定位

每次点击都从实际 `NSStatusBarButton` 重新计算锚点，不缓存首次屏幕：

1. 将 button bounds 转换到 screen 坐标。
2. 优先使用 `button.window?.screen`。
3. 若不可用，依次选择包含锚点的屏幕、鼠标所在屏幕和 `NSScreen.main`。
4. 水平以状态项中心对齐，垂直置于菜单栏下方。
5. 使用目标屏幕 `visibleFrame` 做左右与上下夹取。
6. 支持负坐标显示器、上下排列、不同缩放、隐藏菜单栏和菜单栏折叠工具。

精简模式切换到详细模式时必须使用保存的当前锚点重新计算完整 frame，不能只修改 content size。

### 5.3 打开与关闭语义

- 当前 Space 已显示时再次点击：关闭。
- 旧 session 可见但 `isOnActiveSpace == false`：销毁旧 session，在当前 Space 新建。
- Space 或屏幕配置改变：关闭并解除状态项高亮。
- Escape 或面板外鼠标点击：关闭。
- 面板内部、sheet、alert 和系统菜单交互：不能因为暂时失去 key 而误关。
- 点击状态项自身由 `togglePanel` 处理，不能出现 mouse-down 关闭、mouse-up 又打开。
- 打开主窗口时沿用现有显式关闭路径。
- 所有关闭路径必须移除 event monitor、notification token 和 hosting controller，重复关闭安全。

事件归属只使用公开窗口关系和菜单跟踪通知判断：

- 面板自身，以及其 `parent` / `childWindows` 链上的 sheet、alert 和辅助窗口，均视为面板内部交互。
- 状态项的 mouse-down / mouse-up 均视为允许事件；只由状态按钮 mouse-up 触发一次 `togglePanel`，禁止重复翻转。
- 监听 `NSMenu.didBeginTrackingNotification` / `NSMenu.didEndTrackingNotification`；系统菜单跟踪期间暂停外部点击关闭，结束后恢复。
- 面板模式选择直接使用分段控件，不再嵌套会因 hover 失焦而消失的 `Menu`。
- 用户切换到其他应用窗口时按外部交互正常关闭。
- 不依赖私有窗口类名，也不把 `windowDidResignKey` 当作主要关闭依据。

## 6. 网络测速 2.0

### 6.1 模式

保留“系统完整测速”为原生优先路径，并增加仅在原生服务不可用后出现的“兼容估算测速”。两者不得自动跨服务商切换。

系统完整测速：

- 使用固定绝对路径 `/usr/bin/networkQuality` 和固定参数白名单。
- 默认保持并发完整测试，结果与系统网络质量工具一致。
- 同意框明确提示：测试通常持续约 20 秒，高速网络可能消耗数百 MB 至数 GB，系统无法预先提供流量硬上限。
- `NWPathMonitor` 预检离线、`isExpensive` 和 `isConstrained`。
- 计费或受限网络必须再次确认，默认不运行。

兼容估算测速：

- 只有原生工具返回明确的服务/配置不可用状态后才展示。
- 用户必须第二次确认服务方、IP 可见性和最大流量。
- 使用 Cloudflare 官方开源测速端点的 HTTPS `__down`/`__up` 机制。
- ephemeral `URLSession`，禁用 cookie 与缓存。
- 只允许固定 HTTPS host，拒绝跨 host 或 scheme 重定向。
- 总下载和上传流量设 128 MB 硬上限；达到上限立即停止。
- 结果明确标记“兼容估算”，不能与系统完整测速伪装成同一种测量。
- 没有自有 TURN 服务时不展示或声称测得丢包率。

### 6.2 结果模型

`NetworkSpeedTestResult` 扩展为：

- 下载 Mbps
- 上传 Mbps
- Responsiveness，使用 `Double` RPM，显示时可以四舍五入
- 空闲延迟
- 可用时的负载延迟 P50/P95
- 可用时的 jitter/MAD
- 网络接口
- 测试来源与方法版本
- 测试耗时
- 实际传输字节数；系统完整测速仅在原生输出提供时显示，兼容估算必须精确计量
- 测试时间
- 数据完整度/可信度

系统输出中的公网 IP、服务器 URL、测试端点和操作系统版本必须在解析后立即丢弃，不进入模型、日志或历史。

### 6.3 错误与状态机

状态至少区分：

- `idle(lastResult?)`
- `consentRequired`
- `preflighting`
- `constrainedWarning`
- `nativeRunning(elapsed, limit)`
- `nativeParsing`
- `nativeServiceUnavailable`
- `compatibilityConsentRequired`
- `compatibilityRunning(stage, progress)`
- `cancelling(stage)`
- `succeeded`
- `offline`
- `timedOut`
- `cancelled`
- `failed`

先解析 stdout/stderr 中的结构化 error envelope，再结合退出码判断：离线、超时、系统服务不可用和未知失败不能都压成“测试未完成”。取消后绝不能自动进入兼容模式。

保留现有 process runner 的 PID identity、输出上限、pipe drain、SIGINT → TERM → KILL、reaper、single-flight 和 generation 防迟到能力。若增加命令模式，改为枚举构造的参数白名单，绝不接受任意 path/arguments。

### 6.4 网络体验评分

网络体验分独立于电脑健康总分。算法版本 `network-experience-v1`：

- 下载 25%
- 上传 15%
- 空闲延迟 20%
- 负载延迟 20%
- jitter 10%
- RPM 10%

归一化函数：

```text
higherLog(x, bad, good) =
  clamp(ln(max(x, bad) / bad) / ln(good / bad) × 100, 0, 100)

lowerLinear(x, good, bad) =
  clamp((bad - x) / (bad - good) × 100, 0, 100)
```

各指标锚点：下载 `higherLog(5, 250)`、上传 `higherLog(1, 50)`、空闲延迟 `lowerLinear(20, 150)`、负载延迟 P95 `lowerLinear(50, 500)`、jitter/MAD `lowerLinear(5, 80)`、RPM `higherLog(100, 1000)`。单位分别为 Mbps、ms 和 RPM。

所有输入必须为有限数；吞吐和 RPM 必须大于等于 0，延迟与 jitter 必须大于等于 0。非法值按缺失处理并降低可信度，不得传播 NaN 或无穷值。缺少可选指标时在已测项目内重新归一化，同时降低可信度；缺少下载、上传或空闲延迟任一核心项时不发布总分。

页面始终优先展示原始值。总分大于等于 80 为“稳定”，55–79 为“一般”，低于 55 为“拥塞”；可展开查看公式和缺失项。历史最多保留最近 20 次，只保存聚合指标、方法版本和时间。

## 7. 电脑健康驾驶舱

### 7.1 页面结构

采用已批准的 B“健康驾驶舱”：

1. 顶部综合健康环：分数或“数据不足”、状态、可信度、较 7/30 天变化和“立即检查”。
2. “本周最值得处理”：最多三条可执行建议，每条只有一个安全动作。
3. 30 天趋势图：健康分、覆盖率和模型版本分开。
4. 分项摘要：磁盘可靠性、容量、备份、稳定性、电池。
5. 环境状态：网络体验和热/性能就绪度，明确不计入核心健康总分。
6. 可展开的“评分构成”：每项原始证据、扣分、可用性和更新时间。

页面继续使用现有 `AppDesignTokens`、`glassPanel`、`MetadataPill` 和系统语义色，不另建 iStat 风格主题。

### 7.2 核心评分模型

新增纯函数：

```swift
ComputerHealthScoring.evaluate(
    snapshot: ComputerHealthSnapshot,
    history: ComputerHealthHistory,
    referenceDate: Date
) -> ComputerHealthAssessment
```

核心适用权重：

- 磁盘可靠性：30
- 容量余量：25
- 稳定性：20
- 备份：15
- 电池：10

明确无电池的 Mac 将电池标记为 `notApplicable` 并对其余项重新归一化；探测失败必须标记为 `unknown`，不能当成台式机或健康。

探测层必须保留这些证据差异：

- 电池探测返回 `present(snapshot)`、`notPresent` 或 `failed(reason)`；只有系统明确证明无电池时才映射 `notApplicable`。
- 容量评分只使用 `availableForImportantUsageBytes`；普通 `availableBytes` 可展示但不能代替评分证据。
- 稳定性探测输出 `event(type, occurredAt)`；聚合历史不保存报告路径、进程参数或调用栈。
- SMART unsupported 与整张磁盘卡可读是两件事；磁盘可靠性信用必须由 SMART 证据本身决定。

可用性信用：

- available = 1.0
- partial = 0.5
- permissionDenied / timedOut / unavailable = 0
- notApplicable 从分母排除

覆盖率：

```text
coverage = Σ(weight × availabilityCredit) / Σ(applicableWeight)
```

分数：

```text
score = 100 -
  Σ(weight × availabilityCredit × (1 - componentScore / 100))
  / Σ(weight × availabilityCredit) × 100
```

若 `Σ(applicableWeight) == 0` 或 `Σ(weight × availabilityCredit) == 0`，结果必须为 `dataInsufficient`，不能执行除法或发布数字。覆盖率低于 70% 时保存检查结果，但不发布数字总分，只显示“数据不足”。所有结果附带 `modelVersion = computer-health-v1`。

内部保留 clamp 到 0–100 的 `Double` 分数，历史保存该 Double；界面使用四舍五入到最近整数。数字分大于等于 85 为 `healthy`，60–84 为 `attention`，低于 60 为 `actionRequired`；SMART failing 无条件为 `actionRequired` 并继续应用总分上限 20。数据不足映射 `unavailable`，不能按 0 分展示。

### 7.3 分项规则

磁盘可靠性：

- SMART verified = 100。
- SMART failing = 0，并将综合分上限限制为 20。
- unsupported/unavailable 只降低覆盖率。
- TRIM 和 FileVault 作为硬件/安全背景展示，不和容量重复扣分。

容量余量：

- 使用 `availableForImportantUsageBytes / totalBytes`。
- 25% 及以上 = 100。
- 15%–25% 线性映射到 70–100。
- 10%–15% 线性映射到 40–70。
- 0%–10% 线性映射到 0–40。
- 容量值不可用时不猜测。

稳定性：

只持久化事件类型和日期，不保存报告路径、调用栈或应用参数。每个事件使用 14 天半衰期：

```text
eventPenalty = typeWeight × 0.5^(ageDays / 14)
```

类型权重：panic 60、unexpected restart 40、hang 8、spin 4、crash 2。总惩罚上限为 100，稳定性分为 `100 - penalty`。

备份：

- 已配置且最近完整备份在 24 小时内 = 100。
- 1–3 天 = 90。
- 3–7 天 = 75。
- 7–14 天 = 50。
- 超过 14 天 = 25。
- 未配置 = 0。
- 目标暂时不可达且有最近成功备份 = 40。
- 命令失败或日期不可读只降低覆盖率，不假定没有备份。
- 当前目标不可达且本次没有返回最近成功日期时，只能使用健康历史中最近一次已验证成功备份时间作为证据；不得把“曾配置”当成“近期已备份”。

电池：

```text
capacityScore = clamp((maximumCapacityPercent - 60) / 40 × 100)
```

- 系统 condition 为第一优先级。
- service recommended 时电池分上限为 40。
- 没有机型设计循环寿命时，循环次数只展示，不单独扣分。
- 充电策略继续使用系统设置安全引导，不写 SMC、不直接限制充电。

### 7.4 本应用独有算法

空间压力预测：

- 至少 7 个不同日期的数据点，并覆盖至少 14 天。
- 使用 Theil–Sen 中位斜率估算每日可用空间变化，降低单日清理或大型下载的影响。
- 在整个候选窗口内，以总容量中位数为基准，`(maxTotal - minTotal) / medianTotal` 大于 5% 时拒绝预测。
- 计算所有按真实日间隔归一化的两点斜率；至少 70% 必须为负，Theil–Sen 中位斜率 `s` 必须小于 0。
- 斜率 MAD 为 `m`，稳健尺度 `r = 1.4826 × m`；只有 `-s > max(64 MiB/day, r)` 且 `s + r < -64 MiB/day` 时才视为持续下降。
- 压力线取 `max(总容量 15%, 20 GiB)`。当前可用空间已经低于压力线时返回“已进入压力区”且天数为 0，不伪装成未来预测。
- 中位天数为 `(currentAvailable - pressureLine) / -s`；范围使用 `s - r` 与 `s + r` 计算并向外取整。超过 365 天统一显示“超过一年”。
- 数据不足、重要用途可用空间缺失、趋势不稳定或任一中间值非有限时不预测。

电池磨损趋势：

- 每天最多记录一次最大容量和循环次数。
- 至少 8 个有效点并跨越至少 45 天后才显示趋势。
- 最大容量样本 MAD 必须小于等于 1.5 个百分点；否则只显示“波动较大，暂不判断”。
- 使用 Theil–Sen 中位斜率分别计算 `lossPer90Days` 与 `lossPer100Cycles`；循环次数无有效增长时后者缺失，不以 0 代替。
- 两个可用指标均小于 1 个百分点时为“近期稳定”；任一为 1–3 时为“建议观察”；任一大于 3 且趋势可信度大于等于 70 时为“下降较快”。
- 只描述趋势，不预测电池死亡日期；采样为整数或离散度升高时降低趋势可信度。

电池趋势可信度固定为：

```text
sampleCredit = clamp(validSampleCount / 16, 0, 1)
spanCredit = clamp(spanDays / 90, 0, 1)
stabilityCredit = 1 - clamp(capacityMAD / 1.5, 0, 1)
trendConfidence = round(100 × (
  0.40 × sampleCredit +
  0.30 × spanCredit +
  0.30 × stabilityCredit
))
```

容量 MAD 大于 1.5 时仍直接拒绝趋势；该可信度只用于趋势文字，不进入核心健康分。

健康可信度：

算法版本 `health-confidence-v1`：

```text
factorFreshness = exp(-ln(2) × ageHours / 72)
freshness = Σ(applicableWeight × factorFreshness) / Σ(applicableWeight)
historySpan = clamp(distinctHistoryDays / 30, 0, 1)
consistency = 1 - clamp(scoreMAD / 15, 0, 1)
confidence = round(100 × (
  0.50 × coverage +
  0.25 × freshness +
  0.15 × historySpan +
  0.10 × consistency
))
```

- `ageHours` 小于 0 时按 0；超过 30 天时该因子 freshness 直接为 0。
- 只有至少 5 个相同 `modelVersion` 的数字健康分时计算 consistency，否则 consistency 为 0。
- 可信度大于等于 80 为高，60–79 为中，低于 60 为低。
- 可信度只说明证据质量，不改变原始硬件状态；分母为 0 时结果为数据不足。

7/30 天变化只比较相同 `modelVersion` 的数字分。以当前本地日减去 7 或 30 天为目标日，分别在目标日前后 2 天或 5 天内选择绝对日差最小的样本，同差时选较新的；没有候选则不显示变化。可信度 consistency 只使用本次评估前已经持久化的相同模型分数，避免候选分数反过来改变自己的可信度。

“本周最值得处理”先按因子去重，再最多取三条，每条只有一个动作。固定优先级为：SMART failing、已进入容量压力区、电池 service recommended、备份未配置或超过 14 天、最近 7 天 panic/unexpected restart、预测 30 天内进入压力区、其余分项低于 60、其余分项 60–84。相同优先级按 `weight × (1 - componentScore / 100)` 降序，再按磁盘、容量、稳定性、备份、电池稳定排序；没有安全动作的纯信息不进入该列表。

热/性能就绪度：

- 使用 `ProcessInfo.thermalState` 和已有缓存遥测做即时提示。
- 当前单个温度样本不进入健康总分。
- 只有未来具备独立 sampledAt、去重和至少 10 分钟有效历史时，才允许增加热稳定性评分。

### 7.5 历史持久化

- 每天最多保存一个健康摘要，保留最近 90 天。
- 保存分项分、覆盖率、模型版本、最近一次已验证完整备份时间、必要的聚合趋势字段和时间。
- 不保存进程名、浏览域名、文件路径、磁盘序列号、IP 或诊断报告内容。
- 使用 Application Support 原子 JSON 写入，损坏时安全回退为空历史。
- 失败、取消和迟到 generation 不写入历史。

## 8. Mac 跑分系统

### 8.1 产品定位

功能名称为“Mac 跑分”。它是本应用自己的可复现本机基准，不是 Geekbench、Cinebench 或 Apple 官方分数。页面必须说明：

- 原始指标优先。
- 综合分只在相同 workload/baseline 版本和相同模式间比较。
- 不提供公共排行榜，不上传硬件或成绩。
- 温度、电源模式和后台负载会影响结果。

### 8.2 模式与阶段

快速模式（默认）：目标约 30 秒，完成全部组件的一轮受控测试。

完整模式：目标约 90 秒，每项运行三次取中位数，并报告变异系数 CV。

阶段：

1. 安全预检
2. CPU 单核
3. CPU 多核
4. Metal GPU
5. 内存
6. 磁盘写入
7. 磁盘读取与校验
8. 评分与保存

每个阶段有独立超时和取消检查。进度发布不超过每秒 5 次。

### 8.3 真实工作负载

CPU 单核：

- 固定种子的确定性整数与浮点 kernel。
- 运行时生成输入，保留 checksum，防止编译器消除。
- 单线程执行，报告 operations/second。

CPU 多核：

- 使用相同 kernel 分块并行。
- 至少保留一个逻辑核给界面和系统。
- 每个小块检查取消，报告聚合 operations/second 和扩展效率。

Metal GPU：

- 使用公开 Metal compute pipeline。
- library 编译、资源创建和 warm-up 不计时。
- 使用固定大小缓冲区和 checksum 校验。
- Metal 不可用或 kernel 失败时展示原因，不伪造 GPU 分。

内存：

- 在受限缓冲区上执行 copy、scan 和 checksum。
- 快速模式最大工作集 64 MiB，完整模式最大 128 MiB。
- 报告有效 GB/s，不申请接近物理内存的大缓冲区。

磁盘：

- 仅在用户确认后，于本应用私有临时目录创建一个文件。
- 快速模式最大 128 MiB，完整模式最大 256 MiB。
- 顺序写入、`fsync`、顺序读取和内容校验。
- 使用受支持方式降低文件缓存干扰，同时明确 APFS 与缓存仍会影响结果。
- 所有成功、失败、超时和取消路径都用 `defer` 删除临时文件。
- 不访问裸设备、不做随机写、不在后台自动运行。

### 8.4 安全预检与重任务互斥

新增进程内 `HeavyWorkCoordinator` actor，以租约形式让以下任务双向互斥：

- 主磁盘扫描与重复文件扫描
- 清理、恢复和废纸篓操作
- 网络测速
- Mac 跑分
- 内存优化
- 应用批量更新

租约语义固定为 fail-fast、无等待队列：

- `tryAcquire(owner)` 在空闲时返回唯一 token；占用时立即返回 `busy(activeOwner)`，UI 显示正在运行的任务和可返回入口。
- 租约不可重入；同一 owner 再次申请也返回 busy，避免嵌套死锁。
- 只有匹配 token 才能释放；同一 token 重复释放安全，错误 token 为 no-op。
- `withLease(owner, operation)` 必须在成功、抛错、超时和取消的所有退出路径中用 `defer` 释放。
- 页面离开只取消该页面持有 token 的任务，不能取消其他 owner；应用终止时各 Store 先取消自身任务，下一次启动清除跑分孤儿临时文件。
- 因为没有队列，不存在公平性或等待中取消语义；用户可在当前任务结束后重新点击。

集成边界：

- 每个显式异步重操作独立申请租约，只持有到该操作及其子进程、文件句柄和缓冲区收尾结束；等待用户浏览结果、编辑选择或确认下一步期间不得持有租约。
- `ScanStore`：主扫描、重复文件扫描、清理、恢复、废纸篓批处理、内存优化、应用批量更新分别独立持有租约；扫描完成后在结果页等待用户操作时释放，用户确认清理后重新申请。
- 若“扫描后自动执行安全清理”未来成为一个明确的单次用户动作，才可作为复合会话持有同一租约；v1.5.0 不新增该自动清理会话。
- `NetworkSpeedTestStore`：一次原生尝试从预检开始，到原生会话、解析和资源收尾结束持有一个租约；若进入 `compatibilityConsentRequired`，必须先释放原生租约。用户明确确认兼容测速后再申请一个新的租约，持有到兼容会话、解析和资源收尾结束；等待第二次确认期间不得占用。
- `MacBenchmarkStore`：从安全预检开始，到 kernel、Metal、磁盘临时文件和资源收尾结束全程持有同一租约。
- 每个 service 入口都校验有效 token；互斥不能只靠按钮 disabled 或页面层判断。

跑分预检：

- thermal nominal 才直接开始；fair 提示冷却后重试；serious/critical 拒绝或立即取消。
- 完整模式要求接入电源且关闭低电量模式。
- 快速模式在电量低于 30% 或低电量模式下先警告，默认不开始。
- SMART failing 时禁止磁盘阶段。
- 容量压力必须正常，临时可用空间至少为测试文件两倍并额外保留 2 GiB。
- 跑分期间暂停 `EnergyImpactService` 重采样和菜单栏重型传感器刷新；轻量状态条保持可交互。

页面进入、切换或恢复历史时不得自动获得重任务租约。

### 8.5 评分

原始指标：

- CPU 单核 Mops/s
- CPU 多核 Mops/s
- GPU compute throughput
- 内存 GB/s
- 磁盘读 GB/s
- 磁盘写 GB/s

每项与版本化参考值比较，比例限制在 0.2–5.0，避免异常值支配综合分：

```text
MacPerf = 1000 × exp(
  0.20 × ln(CPU1 / RefCPU1) +
  0.25 × ln(CPUN / RefCPUN) +
  0.20 × ln(GPU / RefGPU) +
  0.15 × ln(Memory / RefMemory) +
  0.10 × ln(Read / RefRead) +
  0.10 × ln(Write / RefWrite)
)
```

参考机固定为当前验证机：MacBook Pro `Mac17,9`、Apple M5 Pro、18 核（6 个 Super + 12 个 Performance）、48 GB 内存。校准与用户报告都不得持久化或展示序列号、硬件 UUID、UDID 等设备唯一标识。

参考值必须来自 release 优化构建的最终 workload 真机校准，不得凭空填写：

1. 使用交流电、自动电源模式、电池大于等于 50%、thermal nominal，且没有其他 `HeavyWorkCoordinator` 重任务。
2. 在两次独立且充分冷却的 session 中采样；每种模式每个 session 至少 5 次，或每种模式累计至少 8 个有效样本。
3. 运行中 thermal 状态变化、发生重任务冲突，或任一组件 CV 大于 5% 时，该轮校准无效。
4. 每项参考值取所有有效样本的中位数；快速和完整模式分别校准。
5. 聚合校准报告保存在 `docs/benchmarks/`，源代码内冻结相同数值、`baselineVersion`、`workloadVersion` 和报告 SHA-256。
6. 参考值为 0、NaN、无穷、缺失、未冻结，或 SHA-256 不匹配时，测试与发布验证必须失败，不能生成综合分。

成绩可比较键固定为：

```text
workloadVersion + baselineVersion + profile(quick/full) +
architecture(runtime: arm64/x86_64) +
capabilitySet(CPU/GPU/Memory/Read/Write)
```

v1.5.0 只冻结经过真机校准的 arm64 基线。x86_64 Mac 仍可运行其支持的 CPU、Metal、内存和磁盘真实工作负载并查看原始指标，但明确显示“尚无此架构参考基线”，不生成分项分或综合分；未来只有加入独立 x86_64 真机校准和新 `baselineVersion` 后才允许评分。不同架构的结果永不直接连线或比较。

app/build 版本只作为审计元数据，不参与相等判断；历史必须按完整可比较键分组。任一必需能力或组件缺失时不生成综合分。

任一必需组件被跳过、取消或热保护中止时，不生成完整综合分，只展示已完成组件。完整模式 CV 超过 5% 时标记“结果波动较大”。

### 8.6 跑分页面

- 顶部综合分环、模式、可信度和开始/取消按钮。
- 分项条形图，同时显示原始指标和分项分。
- 当前阶段、已用时间和安全状态。
- 测试环境：芯片、核心数、内存、电源、热状态、系统版本和跑分版本。
- 最近 30 次历史趋势；不同 baseline 版本分组，不能直接连线比较。
- “复制报告”只复制聚合结果，不包含用户名、序列号、路径或 IP。

历史保留最近 30 次，使用 Application Support 原子 JSON。

## 9. 安全清理布局稳定

### 9.1 结构修复

`ReviewWorkspaceShell` 必须是受父容器高度约束、从顶部对齐的布局，不能依赖多个 `maxHeight: .infinity` 子视图的理想高度协商。

“可安全清理”标签调整为：

1. 固定在页面内的紧凑隐私清理摘要卡，展示安全模式、扫描状态和主要按钮。
2. 详细隐私结果在独立 sheet 中显示，沿用现有只读快照和浏览器原生清理引导。
3. 下方 `ItemListView` 或 `ToolPreparationView` 只占剩余可用高度。

这样保留隐私功能入口，同时避免结果增高时挤压整个清理工作区。

### 9.2 滚动与刷新

- 切换“可安全清理 / Codex 与开发产物”时根容器保持稳定顶部位置。
- 扫描进度和行内容更新不得重建整个 `ScrollView`。
- 移除以 `rawItems.map(\.id)` 驱动整列动画的行为；筛选和排序可以保留局部动画。
- 只在用户主动切换筛选、项目已不存在或列表清空时调整选择。
- 用户滚动查看中间项目时，后台大小/状态刷新不能调用 `scrollTo` 或改变 view identity。
- 缩小窗口、隐藏/展开侧边栏、切换语言和减少动态效果时都不能把顶部内容推入标题栏。

## 10. 状态、并发与卡死治理

### 10.1 Store 边界

- `ComputerHealthStore`：快照、评估、历史和手动刷新。
- `NetworkSpeedTestStore`：测速状态机、最近成功结果和网络历史。
- `MacBenchmarkStore`：跑分状态、历史和用户动作。
- `HeavyWorkCoordinator`：重任务租约。
- `ScanStore` 继续管理扫描/清理，但通过 coordinator 与新增重任务互斥。

不得把跑分 kernel、测速 URLSession 或健康历史重新塞进大型 `ScanStore`。

### 10.2 主线程与刷新

- `@MainActor` 只发布 UI 状态，不执行同步 kernel、文件 I/O、`system_profiler` 或等待 Metal command buffer。
- 当前 `confirmTrash` / `confirmTrashAllGreen` 的同步移动循环必须迁入可取消的后台 service；恢复、清空废纸篓和批量文件操作同样不能在 MainActor 执行。
- 不把 `Task.detached` 当作阻塞线程隔离的唯一保证；外部命令和磁盘 I/O 使用明确的执行边界。
- 网络与跑分进度最多 5 Hz，图表最多按可见刷新率合并。
- 页面切换不得取消并重建根 Store。
- 取消先进入 `cancelling`，确认子进程、URLSession、Metal 和文件任务收尾后再显示 `cancelled`。
- 所有异步结果带 generation；旧任务完成不能覆盖新状态。
- 运行结束后释放大缓冲区、Metal 资源、临时文件和租约。
- Homebrew 批量更新必须由应用自己的受限进程 runner 持有并等待进程树退出；若只打开 App Store/系统设置，则状态只能是“已打开，等待用户操作”，不能报告完成，也不能把不可观测 Terminal 脚本当成已结束任务。

### 10.3 macOS 26 兼容

- 部署目标保持 macOS 14。
- 小窗 Space 行为只使用公开 AppKit API。
- macOS 26 的紧凑控件 metrics 使用现有 availability 判断。
- `networkQuality` 解析支持 macOS 14/15/26/27 已知 JSON/plist 形态和小数 RPM。
- SwiftUI 布局不依赖固定标题栏高度或旧系统安全区常量。
- 跑分只使用公开 Metal、Foundation、Darwin 和 ProcessInfo API。

## 11. 自动化测试

测试能力分层，避免把进程内断言误报成真实系统行为：

- 纯 SwiftPM XCTest：评分、解析、状态机、placement、滚动位置 resolver、历史持久化和 coordinator 语义。
- AppKit-hosted SwiftUI 集成测试：在固定窗口尺寸中挂载真实 view，使用仅 Debug 可用的 `LayoutProbe` / anchor preference 记录 frame、scroll identity 和 titlebar safe area。
- 真实运行验收：Space 归属、全屏 Space、标题栏、状态栏折叠工具和真实系统菜单行为；这些不能只由 SwiftPM 测试证明。

### 11.1 菜单栏面板

- 主屏幕、负坐标外屏、上下排列、左右边缘和隐藏菜单栏的 placement 纯函数测试。
- 精简 → 详细仍保持同一顶部锚点。
- policy 包含 `.moveToActiveSpace` / `.canJoinAllApplications`，不包含 `.canJoinAllSpaces`。
- 当前 Space 再点关闭，旧 Space session 被销毁后重建。
- Space/screen 通知关闭；alert/sheet 不误关。
- 状态按钮 mouse-down/mouse-up 只翻转一次；直接分段选择精简/详细时菜单不因 hover 消失。
- `NSMenu` tracking 期间不误关，结束后外部点击恢复关闭；其他应用窗口点击关闭。
- 所有关闭路径 monitor/observer 清零；重复 teardown 安全。
- 连续打开关闭 100 次不累积 panel、hosting controller、线程或内存。

### 11.2 网络测速

- macOS 14/15/26/27 合成 fixture，包括小数 RPM。
- stdout/stderr、exit 0/非 0 error envelope 和已知错误分类。
- 缺字段、非有限、负数、巨大值、数组数量上限和输出字节上限。
- NWPath 离线、expensive、constrained 状态。
- 原生失败后必须第二次同意，取消后不得 fallback。
- URLProtocol 覆盖流量硬上限、恶意 redirect、非 HTTPS、错误 host、HTTP 错误、early EOF、缓存/cookie 禁用和取消。
- 隐私字段永不进入模型、日志或历史。
- 旧结果明确标“上次成功”，不能覆盖当前失败状态。

### 11.3 电脑健康

- 满分、权重、分档、覆盖率阈值、partial 和 notApplicable。
- SMART failing 总分上限，容量不重复扣分。
- 稳定性半衰期和事件权重。
- 备份时间分档与不可达/未知区分。
- 电池无电池、探测失败、service recommended 和最大容量。
- 空间 Theil–Sen 斜率、MAD 范围、样本不足、总容量变化和噪声拒绝。
- 电池磨损趋势样本跨度与可信度。
- 历史原子写入、损坏恢复、排序、90 天上限、模型版本隔离。
- 失败、取消和迟到结果不记录。

### 11.4 Mac 跑分

- 注入 fake clock、kernel、Metal、thermal、power 和 disk runner。
- 几何平均公式、比例 cap、参考版本和模式隔离。
- 快速/完整阶段顺序、中位数、CV 与不完整结果。
- 低电量、低功耗、thermal fair/serious、SMART failing、低空间和活动扫描门控。
- 任意成功、失败、超时和取消都不残留临时文件或 coordinator 租约。
- MainActor heartbeat 在跑分期间持续响应。
- 取消或页面离开不产生迟到综合分。

### 11.5 安全清理布局

- 空状态、扫描中、完成、部分失败和有大量隐私结果的布局状态。
- 使用 AppKit-hosted SwiftUI 在固定小/中/大窗口挂载真实页面；两个标签连续切换 100 次，`LayoutProbe` 证明顶部 frame 不进入标题栏。
- 小窗口、侧边栏隐藏/展开、语言切换和 Reduce Motion。
- 对纯 scroll resolver 做单元测试，并在 hosted view 中滚动到列表中部后发布模拟刷新；首个可见项目和 scroll identity 保持不变。
- `rawItems` 更新不驱动整列 transition。

### 11.6 全量回归

- 运行 `./script/test.sh`，0 失败；环境相关跳过单独说明。
- 运行 `build_and_run.sh --verify`。
- 主窗口连续切页至少 120 次，不出现 100% CPU 持续占用或约 20 秒无响应。
- 详细小窗连续切换至少 80 次。
- 网络、跑分、扫描、清理和内存优化互斥状态组合测试。

## 12. 真实运行与性能验收

### 12.1 小窗与桌面

1. 在桌面 1 打开并确认是本应用状态条与页脚。
2. 切到桌面 2，一次点击即在桌面 2 出现。
3. panel 打开时切换 Space，应立即消失且返回旧 Space 不残留。
4. 精简、详细和内联设置分别重复。
5. 在其他 App 全屏 Space、外接显示器和菜单栏折叠工具启用状态验证。
6. 明确区分存储清理助手、LemonMonitor 和 iStat Menus。

### 12.2 网络

- 应用内系统测速能接受本机真实小数 RPM 结果并显示完整原始指标。
- 测试前确认文案显示潜在 GB 级流量。
- 早期与后期取消后都没有残留 `networkQuality` 进程。
- 原生服务不可用时只显示兼容模式入口，不自动运行。
- 兼容模式真实流量不超过声明硬上限。

### 12.3 健康与跑分

- 健康页真实数据与系统来源交叉核对；不可用项不显示健康。
- 健康分、分项、覆盖率、趋势和 top 3 建议相互一致。
- 空间预测只在满足样本条件时出现。
- 快速与完整跑分各执行一次；原始值、分项和综合分一致。
- 运行中窗口拖动、取消、切页和菜单栏点击保持响应。
- 跑分前后 CPU、线程、内存回落；临时文件不存在。

### 12.4 安全清理

- 在真实安装版进入“安全清理”，顶部不再进入标题栏。
- 两个标签反复切换、隐私 sheet 打开/关闭和窗口缩放均稳定。
- 扫描只读复现，不执行真实清理；移动废纸篓必须保持独立确认。

### 12.5 常驻性能

- 主窗口关闭、菜单栏常驻采样不少于 60 秒。
- 与 1.4.0 基线比较 CPU、内存和线程，不因新功能出现持续回退。
- 网络测速和跑分结束后 2 秒内 CPU 明显回落，重型后台刷新恢复正常节奏。
- 使用 Time Profiler/signpost 检查 MainActor、SwiftUI 重建和重任务队列。

## 13. 发布规格

- 正式版本：1.5.0。
- Build：发布时生成当前时间戳，不复用旧 build。
- 应用：`存储清理助手.app`。
- Bundle ID：`com.local.StorageCleanerMac`。
- 安装位置：`/Applications/存储清理助手.app`。
- 源码分支：新建 `codex/health-benchmark-v1.5.0`。
- DMG：`StorageCleanerMac-1.5.0.dmg`。
- ZIP：`StorageCleanerMac-1.5.0.zip`。
- 同时生成 SHA-256 校验文件。

发布证明必须拆开：

1. 源码已提交并推送。
2. 自动化测试通过。
3. 本地包已生成并验证。
4. `/Applications` 安装版已替换并真实打开。
5. 源码 GitHub Release 已发布。
6. 公开更新仓库 Release 已发布。
7. Sparkle appcast 已更新且外部可访问。
8. 使用真实 1.4.0 安装副本完成检测、下载、签名校验、替换和重启到 1.5.0。

当前仍为 Apple Development 签名时，更新日志和验收记录必须明确说明不是 Developer ID 公证版。

## 14. 文件保护与开发产物

- 手工编辑必须使用 `apply_patch`。
- 不回退用户已有改动。
- 永远不修改或删除：
  - `README 2.md`
  - `release/发布说明 2.txt`
  - `release/发布说明 3.txt`
- 测试截图、测速原始输出、跑分临时文件、临时安装副本和构建缓存优先写入受控临时目录。
- 发布验收结束后删除开发截图、临时测速输出、跑分文件、临时 app、`.superpowers` 草图与不再需要的中间缓存。
- 最终版本化 DMG、ZIP、SHA-256、appcast 和必要发布记录保留。

## 15. 明确不做

- 不使用私有 CGS/Space API。
- 不让 panel 同时常驻所有桌面。
- 不在用户未同意时自动运行测速或兼容服务。
- 不宣称测得没有真实数据来源的丢包率、SSD 寿命或电池剩余寿命。
- 不用 CPU/GPU 使用率冒充跑分。
- 不上传跑分、健康、浏览或硬件数据，不增加账户和排行榜。
- 不直接修改充电上限，不写 SMC。
- 不把网络体验分加入核心电脑健康总分。
- 不在进入页面时自动跑分或执行深度健康探测。
- 不为每个新指标增加设置开关。

## 16. 完成定义

只有以下证据全部成立，v1.5.0 才能称为完成：

1. 菜单栏小窗在当前 Space/当前屏幕一次点击出现，并通过精简、详细、全屏和多显示器验证。
2. 网络系统测速能正确解析真实小数 RPM，错误分类、流量提示、受限网络和兼容模式均通过测试。
3. 电脑健康驾驶舱显示可解释分数或明确的数据不足状态，独有趋势算法只在证据充分时出现。
4. Mac 跑分真实完成 CPU、GPU、内存和磁盘工作负载，原始指标、分项和综合分一致，无残留文件。
5. 安全清理页面不再上移，后台刷新不改变用户滚动位置。
6. 重任务互斥、取消、超时、迟到结果和 MainActor 响应测试通过。
7. 全量测试、构建验证、真实界面、性能和 macOS 26 兼容检查通过。
8. 版本化 DMG/ZIP/SHA-256、源码 Release、更新仓库 Release 和 appcast 全部验证。
9. 真实 1.4.0 → 1.5.0 Sparkle 更新完成并重启到正确版本。
10. 开发截图、中间文件和缓存按约定清理，三个受保护用户文件保持原样。
