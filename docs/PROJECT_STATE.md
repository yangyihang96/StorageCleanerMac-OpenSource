# StorageCleanerMac 项目状态

## 2026-09-12 发布验收入口

当前源码为 1.9.13 / Build 202609120014，本地验证已记录，所有者已明确授权按 Apple Development 签名、未公证的公开测试版方式发布。600 秒持续阶段受温度预检阻断，不能记为通过。最新证据见 [1.9.13 发布验收](RELEASE_VALIDATION_1.9.13.md) 与 [更新日志](../CHANGELOG.md)。下列 2026-08-30 及更早的 PID、安装副本、测试数量与发布状态均为历史记录，不代表当前机器状态。

## 历史状态快照

> 更新时间：2026-08-30（AEST）
> 本文记录当前仓库和本机安装版的事实状态，不把历史截图、Debug fixture 或旧日志当作当前实现证明。

## 当前基线

- 项目：macOS 原生 SwiftUI 应用「存储清理助手」/ `StorageCleanerMac`。
- 仓库：`/Users/developer/Documents/好玩的/StorageCleanerMac-v199`，GitHub `yangyihang96/StorageCleanerMac-OpenSource`（公开源码快照）。
- 分支：`main`；已发布基线为 `v1.9.12` 提交 `ba479345c26edcba63284c103b35350423a2badc`，该提交与 `origin/main` 一致。
- 1.9.11 校验和与发布验证报告已作为历史证据纳入仓库，不属于 1.9.13 产品逻辑。
- 已发布源码基线：`v1.9.12`（提交 `ba479345c26edcba63284c103b35350423a2badc`）；后续只能使用 1.9.13+ 的新提交、标签与资产，不得修改、移动、重打或覆盖 `v1.9.12` 及更早发布。
- 当前发布版本：`1.9.12`，Build `202608282037`。
- 当前源码开发版本：`1.9.13`，开发基准 Build `202608291312`；尚未发布。
- 最低系统版本：macOS 14；构建目标为 arm64。
- 开发工作流（用户指定）：每轮修改完成后用 `./script/build_and_run.sh --beta --install` 重建并重装测试版。
- 1.9.13 Debug 全量测试：`2658 tests / 16 skipped / 0 failures`（系统健康 v2 与窄窗布局修复后的独立本地完整复验，2026-08-30）；同一结果也由 Beta 打包流程内置测试复验。文件分析、文件搬家、重复文件的相关测试集另为 `179 tests / 0 failures`。
- 1.9.13 首轮性能验证：已把应用清单/深度签名扫描纳入既有重任务互斥，将长文件扫描、重复文件哈希和交流电能耗归因降为 utility QoS，并减少后台能耗采样中的同步 LaunchServices 查询；没有放宽扫描安全链或遥测计算。
- 1.9.13 浏览器隐私批选：结果工具栏新增可搜索的批量选择入口，可按今天、最近 7 天、最近 30 天、30 天以前或精确网站域名把记录加入选择；不会立即删除，仍复用既有需确认、浏览器运行预检、恢复备份、稳定 Visit 身份复核与删除后回读链。
- 1.9.13 风扇硬件兼容性：小窗继续复用唯一 `FanControlCoordinator`、长期 XPC 与受限 Helper；慢速热管理器解锁使用独立的 25 秒请求窗口，Helper 的 `Ftst` 回退等待保持在 30 秒 watchdog 内，并按每个风扇探测 `F?md`/`F?Md`。写后回读、范围限制、租约与自动恢复规则未放宽；无风扇机型仍应明确显示不可用。
- 1.9.13 系统健康 v2：健康分只综合磁盘可靠性、容量余量、30 天系统稳定性和电池寿命；任一核心项达到需处理阈值时不会被平均分掩盖。当前电量、FileVault、Time Machine、温控与网络继续独立展示但不计入硬件健康分；`shutdownStall` 归为系统卡顿而非意外重启，单个 App 的 crash/spin 报告不再污染整机稳定性。对照本机 CleanMyMac、iStat Menus 与 MacOptimizer 后，页面改为中性证据布局并在窄窗纵排可信度、覆盖率与时间。最终安装版只读复测为总分 `98`、磁盘 `96`、容量 `100`、稳定性 `93`、电池 `100`；30 天证据为内核崩溃 `0`、意外重启 `0`、系统卡顿 `1`。
- 1.9.13 本机 Beta：已安装并启动 `/Applications/测试版.app`，版本 `1.9.13`，Build `20260829171556`，Bundle ID `com.local.StorageCleanerMac.beta`，运行 PID `74610`；应用与内置 Helper 的严格代码签名回读通过，签名为 Apple Development、Team ID `T9GZL52H8R`。系统健康在 `1200 × 724` 与 `833 × 544` 真窗完成刷新前、刷新中、刷新后及滚动复验。当前系统注册 Helper 仍属于正式版父 Build `202608142241`，本轮未替换服务、未写入风扇转速，因此不能把本机界面复验当作其他机型真实写入矩阵。

## 1.9.12 已发布状态

- 私有源码 Release：`yangyihang96/StorageCleanerMac` tag `v1.9.12`，标签指向提交 `ba479345c26edcba63284c103b35350423a2badc`。
- 公开更新 Release：`yangyihang96/StorageCleanerMacUpdates` tag `v1.9.12`；appcast 提交 `0fb40e54e30a4969f7e6ab54385f63b1151a81c8`。
- appcast 首项：1.9.12 / Build `202608282037` / arm64 / macOS 14 / ZIP 长度 `20234624`。
- 5 个公开资产已匿名下载核对，字节长度与 SHA-256 均与发布记录一致。
- 该发布提交未运行 GitHub Actions；远端回读 Actions 运行数为 0。
- 本次为经所有者明确批准的 Apple Development 签名公开测试版；没有 Developer ID Application、Apple 公证或 stapling，不得描述为 Gatekeeper 已批准。

- 主窗口保持原生可缩放与既有 85% 可读最小尺寸，不改成固定窗口。对照本机 CleanMyMac、iStat Menus、MacOptimizer 真实界面与 Apple HIG 后，共享 `AppButton` 改由原生 SwiftUI `Label` 维护图标/文字基线和间距；主要、次要、危险等含义型操作在窄窗仍保留可见文字，只有 toolbar、icon、smallUtility 三类熟悉的小操作可由 `ViewThatFits` 退化为仅图标，且始终保留 tooltip 与无障碍标签。`ModulePageHeader` 与 `AppPageHeader` 在紧凑宽度把操作区移到标题下方，常规宽度维持单行。安装版在 `833 × 544` 最小尺寸重新完成全部 15 个主路由截图复核，未见按钮图标与文字重叠；内存页“刷新”等关键动作保持完整显示。
- 登录项普通「重新扫描」恢复为快速只读扫描；只有独立「完整扫描」按钮会执行最长 30 秒的 BTM 诊断，普通刷新不再被系统数据库超时拖慢。
- 启动项引用应用的签名身份读取改为最多 4 路并发，应用 Bundle 元数据逐项进入自动释放池，降低首次扫描耗时和临时内存压力；签名、归属和管理能力判定没有放宽。
- 启动项归属预先索引规范路径、Bundle ID 与标签 token，去重阶段为每项只生成一次比较指纹。15 秒真机 Time Profiler 对照中，归属解析 CPU 约 `1124 ms → 55 ms`，去重约 `1585 ms → 47 ms`，配对判断约 `1542 ms → 7 ms`；排序、最深父应用匹配和 fail-closed 合并规则保持不变。
- 应用自身权限身份与 App/Helper 签名契约不再在 MainActor 初始化或小窗首次连接时同步执行；检查分别延迟到后台扫描/确认操作和单次后台签名任务，失败仍拒绝管理或硬件控制。最终安装版启动后未再记录主线程 Security 性能诊断。
- 智能扫描首页复用原有固定 60pt accessory 槽展示上次绿色候选与需确认容量，并为中央主按钮预留等宽间隔；页面几何和统一 `AppDesignTokens` 体系保持不变。
- 应用更新清单的进度与增量结果改为可等待的 MainActor 串行交付，避免迟到批次覆盖最终的来源关闭/忽略策略；应用元数据按 URL 顺序、最多 4 路并发读取并维持原 16 项 UI 批次，取消会立即抛出，不再继续 Spotlight、Homebrew 与来源分类；同时移除每个应用都会分配但始终为空的本地化字典。
- 同机同路径实测 622 个应用的首次更新扫描由 75.95 秒降至 49.95 秒（单次观测约快 34%，两次均得到 19 个可直接更新项目）；扫描取消约 1.88 秒恢复，完成后 `vmmap` 物理 footprint 约 140.9 MB、峰值 436.5 MB。该结果是短时真机证据，不代表长期 RSS 泄漏结论。
- 应用更新列表和右侧详情现在优先显示扫描到的真实 `.app` 图标；Homebrew formula、命令行工具等没有 App Bundle 图标的项目改为清晰的来源型占位，不再加载弱通用文件图标。需手动处理的每行直接显示「前往」，详情显示「打开官方更新页」或准确的 App/命令后备动作；网页入口只接受身份匹配、信任等级达标且通过 allowed-host HTTPS 校验的来源。真机重新扫描 622 个项目后，6 个可见手动更新项均显示行级入口；未执行任何实际软件更新。
- 应用卸载页取消进入页面后延迟 300ms 自动扫描，改为复用统一落地页并显示「一键扫描」主操作；点击前保持“尚未扫描”，点击后才调用既有只读应用清单扫描，扫描结束回到原有搜索、排序和卸载列表。安装版真窗已验证待扫描、扫描中、结果列表三种状态；未执行任何应用卸载。
- 能耗页取消进入后延迟 250ms 扫描和每 6 秒自动重算，改为统一落地页上的「一键扫描」；小窗后台预取继续复用同一底层服务，但不能替代主界面的主动扫描状态。扫描界面按真实数据流展示进程、归属、基线、初算、1.2 秒采样、汇总六阶段；节点、无缓动进度条和阶段文案同步。重新扫描时保留上一份完整结果，不再被 `0.0 s` 的中间预览覆盖。安装版真窗已验证待扫描、第五阶段约 83% 进度、结果页和结果内重新扫描四种状态。
- 能耗六阶段条的图标列固定为 14pt，图标与标题统一为 8pt 间距并禁止内部横向压缩；结果页的「重新扫描」、实时采样窗口与排序控件同步使用显式间距。安装版 Retina 真窗前后快照确认圆形阶段图标、连接线和中文标题不再相互挤压。
- 能耗页进一步按真实最小窗口复现到根因：共享落地页原先用上下 overlay 固定页头/页脚，短窗时中央「一键扫描」会盖住六阶段文字；现改为顺序布局并在高度不足时滚动。结果页在窄窗时把测量说明和应用行切换为上下布局，应用名、测量徽标、进程数及累计/当前/平均能耗均保持完整间距；760pt 与 980pt 安装版真窗均已复验。
- 浏览器隐私结果现在以真实浏览器 App 图标和名称作为一级身份，并显示本机历史记录中的页面标题摘要、域名、配置文件、访问次数和最近时间；搜索同时匹配页面标题。完整 URL 路径、查询参数、解析出的搜索词及密码、Cookie、书签、自动填充和网页正文仍不展示、不持久化、不上传。真机只读扫描返回 `5902` 条记录，Chrome 图标、标题与域名均已显示；未打开任何历史 URL，也未执行浏览记录处理。
- 性能测试默认结果页不再堆叠六组原始单位，改为显示 CPU、GPU、内存和存储的相对强项、相对短板/整体均衡、四项得分及相同 V7 基准下的差异；原始指标与协议版本仍保留在折叠详情中。运行页复用既有 V7 状态展示当前项目、采样次数、总进度和 7 阶段轨迹，没有新增第二套跑分、计时器或成绩。
- 安装版真窗复验：旧完整成绩 `5,582` 的强弱摘要与百分比正常显示；真实跑分由 CPU 第 1 阶段推进至 GPU 第 2 阶段，进度 `0% → 16%`，采样次数和阶段完成状态同步更新。随后安全取消，旧完整成绩保留，本次不完整结果没有保存。
- 电池模式浮层改用二级电源页的稳定列锚点，固定显示在二级菜单旁；电池信息行展开/收起或重排不再改变浮层顶边。
- 设置新增「权限与教程」：集中展示完整磁盘访问、文件与文件夹、应用管理、系统控制 Helper、通知的状态、用途、macOS 路径与跳转。
- 设置内加入三步教程，并明确联网用途以及无需申请的权限（辅助功能、屏幕录制、相机、麦克风、定位、自动化）。
- 首次启动页与设置页复用 `PermissionSetupCard`，没有建立第二套权限卡片样式。
- 开发工具残留统一标出所属工具和类型，覆盖 npm、Codex、Claude Code、Cursor、GitHub Copilot、OpenCode 与 OpenClaw。缓存/临时文件沿用 30/365 天安全分级；日志只允许审查和 Finder 定位；会话、聊天、项目状态、凭据与设置继续排除。
- 风扇控制浮层继续与监测界面分离，并统一复用小窗主题色、卡片边框、悬停反馈和状态回读样式；宽度由 250pt 调整为 270pt，手动同步模式新增 25/50/75/100% 快捷目标。
- 手动滑杆每 1% 的视觉变化保留在局部 View 状态，仅每 5% 向共享协调器发布一次实时预览，松手提交精确值；0→100% 连续拖动的协调器发布上限由 100 次降为 20 次，Helper 的回读、租约、watchdog 与热保护没有改变。
- 安装版真机验证：进入手动模式后 25% 快捷目标真实写入并回读，目标显示 25%、实际约 3698 rpm；测试结束后恢复系统自动并显示“系统自动散热已回读确认”。该单次观测证明本轮路径可用，不代表完整硬件矩阵。
- 重复文件页与文件搬家页统一复用现有落地页/数据页壳：重复文件拥有独立准确副标题、响应式搜索与筛选条、正确的 SHA-256 已确认文件计数；扫描覆盖说明固定使用实际完成扫描时的范围，不会被下一次范围选择改写。
- 重复文件页的「添加文件夹」「选择外接卷」及覆盖报告位置操作改用现有统一按钮组件的显式图标间距，扫描范围菜单同步处理；Retina 真窗复核中复合 SF Symbol 角标不再压住中文文字，原生菜单、键盘焦点和无障碍行为保持不变。
- 文件搬家首次进入改为与文件分析、重复文件一致的主操作页；完成只读扫描后才进入迁移工作区。文件分析不再刷新外接硬盘或加载迁移 App，搬家页也不再继承文件分析留下的搜索/类型筛选，只显示位于用户目录且满足安全边界的普通文件。
- 文件分析、文件搬家和重复文件的扫描态继续复用同一落地页与既有 Store：共享配置区固定使用现有 60pt 槽，计数采用单行等宽数字；文件分析不再用持续换行的当前路径推动整页重排，重复文件数据页路径保持单行并保留完整 tooltip/无障碍文本。三类扫描只在 UI Store 层以 250ms 间隔合并同阶段进度，相位变化和最终结果立即交付；扫描器回调、取消同步、身份验证及清理安全链均未改动。
- 大型文件扫描现在可在落地页或数据页取消；迁移确认明确说明 SHA-256 校验和原件移入废纸篓。执行前会拒绝扫描后大小已变化的源文件，并拒绝源签名无效的 App；复制、校验、不覆盖、原件身份复核和失败保留原件的既有边界不变。
- 真窗复验：Build `20260829154120` 在 `833 × 544` 最小窗口分别运行文件分析、文件搬家和重复文件只读扫描；连续快照确认计数变化时标题、配置区、主按钮、状态文字与插图不再上下抖动，重复文件扫描完成 `56` 组结果。文件分析随后取消，文件搬家和重复文件只读完成；没有选择候选，也未执行任何文件搬移、删除或清理。

## 1.9.10 发布状态

- 源码 Release：`yangyihang96/StorageCleanerMac` tag `v1.9.10`。
- 公开更新 Release：`yangyihang96/StorageCleanerMacUpdates` tag `v1.9.10`；appcast 提交 `e9f34cb`。
- 公开资产：ASCII/中文名 DMG 与 ZIP 各一对，加 `CHECKSUMS-SHA256-1.9.10.txt`；均已匿名下载核对 SHA-256。
- Sparkle appcast 首项：1.9.10 / Build 202608131925 / ZIP 长度 19567053；EdDSA 签名已反向验证。
- 签名边界：Apple Development 签名；没有 Developer ID、公证或 stapling；不得描述为 Gatekeeper 已批准；首次运行可能需要 Control-点击 → 打开。
- 不要修改或重打 `v1.9.10` 标签；后续对外发版使用新版本号。

## 本机安装状态

- 正式版：`/Applications/存储清理助手.app`，1.9.12 / Build `202608282037`，Bundle ID `com.local.StorageCleanerMac`；当前从该路径运行（回读 PID `62836`）。这里只核对版本、Build 与运行路径，没有证明与 GitHub 资产逐字节一致。
- 测试版：`/Applications/测试版.app`，1.9.13 / Build `20260829154120`，Bundle ID `com.local.StorageCleanerMac.beta`；应用与内置 Helper 已严格签名验证并从该路径运行（安装回读 PID `35217`）。它是 Beta 验证产物，不等同于任何已发布正式资产。
- 回退副本：`/Applications/测试版.previous.app`，1.9.13 / Build `20260829150513`。
- 仍保留历史隐藏副本 `/Applications/.测试版.final.202608132005.app`（1.9.10 / Build `20260813095930`）；未获删除确认，未处理。旧 staging 孤儿已由安装脚本安全清除。

## 1.9.11 前端统一（2026-08-14 晚）

对照 16 张主窗口快照和 3 张小窗快照后，只改共享壳，不另开一套视觉语言：

- 标题栏改为「存储清理助手」+ 测试版胶囊，不再单独漂浮「测试版」。
- 落地页与数据页共用 `AppSymbolIcon`（`.pageFeature`）；`ModulePageHeader` 不再手写字号。
- 沉浸式页头去掉设置页才需要的底部分隔线；侧栏页脚显示「版本 1.9.11 · 测试版」。
- 小窗 Helper / 风扇模式共用 `MiniWindowStatusCapsule`，监测卡与控制浮层字号都走 `AdvancedPanelTypography`。

## 1.9.11 开发中（本轮已完成）

### Beta 打包 FinderInfo 根因修复

- 根因：`publish_beta_artifact` 把已签名的包 `ditto` 进 `$ROOT_DIR/dist/beta`（Documents/File Provider 根下），File Provider 立即给 App 与 Sparkle 子组件重挂 `com.apple.FinderInfo`，导致 strict codesign 失败。`/tmp` 同源包干净且验证通过；release 链在 `16197f6` 已把验证副本挪出 Documents，Beta 未跟进。
- 修复：`script/build_and_run.sh` 的 `BETA_ARTIFACT_DIR` 默认改为 `/tmp/storage-cleaner-beta-dist`（仍可用 `BETA_DIST_DIR` 覆盖）；`install_beta` 开始时清除 `.测试版.staging.*.app` 孤儿。
- 同一根因也影响仓库内 `swift test`（`.build` 测试包 ad-hoc 签名失败）：测试必须用 `--scratch-path /tmp/...` 运行，与 `script/verify.sh` 的既有做法一致。
- 旧 `dist/beta/测试版.app` 已被污染且不再被脚本引用，可在确认后删除。

### 界面修复（对应 1.9.10 遗留审计项）

- 性能测试页：分段 Picker 加 `.labelsHidden()` 并保留无障碍标签，消除「性能测试页面」与页面标题的重复视觉层级（`BenchmarkV7DashboardView.swift`）。
- 登录项页：两个空态（无匹配、扫描中）改用 `.inline` 密度；列表在 ≤8 行时按实测行高收紧内容面板，不再把面板撑满整页；面板收紧只在登录项页面生效，未改通用 `ManagementListPage`（`StartupItemsDashboardView.swift`）。
- 浏览器隐私页：删除约 700 行未挂载死代码（`summary`/`coverage` 卡片横向滚动条、旧 `filters`/`selectionActions`/`recordContent`/`BrowserPrivacyRecordRow` 等）；覆盖范围改为工具栏 `checklist` 按钮 → 垂直行弹出层（`BrowserPrivacyCoverageRow`），窄窗口不再可能截断覆盖卡片；完整安全边界文案保留在 help/无障碍文本。
- `ContentPanel` 阴影：非沉浸式（中性主题）表面改用 `Elevation.contentShadow` 按外观分级（深 0.22 / 浅 0.10）；沉浸式模块保持原有 0.20 常量，因为这些路由在浅色系统外观下也绘制饱和深色渐变。
- Token 等值收敛：`LargeFilesView` 两处 `spacing: 16` → `Spacing.large`；登录项搜索框 `padding 6`/`cornerRadius 8` → `Spacing.tight`/`Radius.glassControl`。

### 测试更新

- `PrivacyCleanupPresentationTests` 三个源码契约测试此前锚定的字符串位于死代码中；已更新为锚定活跃实现（`运行中` 角标、`.disabled(isDisabled || !item.selectionEligibility.canSelect)`），并新增契约：覆盖弹出层存在、横向覆盖卡片与旧 summary 不得复活。

### 死代码清理（约 2600 行）

- 整文件删除：`BrowserProfileAdapters.swift`（旧隐私栈残留适配器，零外部引用）、`MenuBarStatusGlyph.swift`（被 `MenuBarStatusRenderer` 取代）。
- `MenuBarTelemetryChart.swift` 删除两个被 Geek 图表取代的旧图表 View 及私有辅助，仅保留共享的 series/sample/geometry 类型；相关契约测试改锚 Geek 图表并断言旧图表不得复活。
- `SystemMonitorService` 删除 `ps`/`netstat`/`powermetrics` 输出解析器（生产路径已用 `host_statistics`/`getifaddrs`/IOKit，项目禁 sudo）；`isPhysicalUplinkInterface` 过滤器改为可直接测试。
- 另删 14 个零引用视图/类型（Overview 旧评分面板一族、Geek 重复行组件、旧批量更新结果面板等）；「终端启动 ≠ 更新成功」的安全规则从死代码字符串断言改为 `AppUpdateService.oneClickSummary` 行为测试。
- 刻意保留：两个 Debug fixture 视图（契约测试保护的截图取证工具）与 SwiftUI Preview。

### 底层性能优化（本轮已落地）

- `L10n.text` 语言解析缓存（`OSAllocatedUnfairLock` + defaults/locale 变更失效）：此前每个本地化标签渲染都读一次 UserDefaults。
- CPU 采样合并：总量由分核 tick 求和推导，每次采样从两次 mach 调用（`host_statistics` + `host_processor_info`）减为一次，分核读取失败时回退。
- 大文件扫描去除每子项一次的 `/usr/bin/du` 子进程（最坏每根 36 个进程、超时即丢项），改为原生枚举求 allocated size；保留卡死保护，超预算返回部分和（下界）而不是丢掉最大的项；`mdls`（每 .app 一个子进程）同样换成原生。
- 小窗遥测窗口化：图表取数从每次刷新拼接整个 28 天 ~4.4 万点历史，改为按可见窗口二分取数（`MenuBarTelemetryHistory.points(within:)`）；recent ring 容量从 4.4 万槽修正为高分辨率一小时窗口（3664），直接降内存。
- 文件分析、文件搬家与重复文件扫描进度复用同一 Store 层 UI 快照节流：相位变化立即透传（暂停/恢复/取消即时性不变），同相位计数更新最多每 250ms 一次；扫描器自身回调契约未动（测试依赖其做取消同步）。
- 小窗「上次扫描」时间戳 formatter 改用 `PanelTimestampFormat` 缓存，不再每次渲染新建 `DateFormatter`。

### 新功能：菜单栏常驻显示模式（iStat 对比第一优先级）

- 竞品研究结论：iStat Menus 的核心壁垒是菜单栏常驻多模式显示；我们的独有优势是 Hover 层级面板、图表 hover 时间戳/固定值域和租约+watchdog+回读的控制安全模型。研究记录于本轮对话（iStat Menus 7.3，2026-05 基线）。
- 已实现 `MenuBarStatusDisplayMode`（defaults 键 `menuBar.statusDisplay.v1`）：内存占用（默认，渲染与旧版逐字节一致）、CPU 占用、CPU+内存双行、网络速率双行（↓/↑）、芯片温度。
- 渲染仍是模板 NSImage、等宽数字、按文本实测宽度自适应 `statusItem.length`；入口在小窗工具栏「更多」菜单的「菜单栏常驻显示」Picker；模式立即生效并持久化。
- 契约测试更新：`memorychip.fill` 字面量断言改为 `statusSymbol("memorychip.fill")` 工厂；新增模式渲染（高度 24、模板、宽度下限）与持久化回退测试。
- 视觉验收：渲染布局有单元测试覆盖，但菜单栏实际观感需要用户肉眼确认（本进程无屏幕录制权限，无法自行截图）。
- 竞品研究中的后续候选（未实现）：多状态项拆分、Top processes（CPU/内存/磁盘 I/O，公共 API）、规则/通知引擎（差异化：磁盘不足通知带一键清理动作）、历史持久化 28 天、S.M.A.R.T. 健康、公网 IP/连通性。明确不做：per-app 网络吞吐与 AirPods 完整电量（需私有框架）、天气/日历（偏离定位）。

### 小窗修复：指向控制浮层途中三级/浮层被误杀（2026-08-14）

用户报告：鼠标移向电源模式选择浮层时，三级层级总是消失。根因有两个，均已修复并有回归测试：

- 悬停劫持：电源模式行仅 25pt 高，浮层 202pt 且优先停靠在整窗外侧，指针斜穿相邻悬停目标（行/导航栏）时，15ms 切换延迟后 `scheduleOpen` 会先把状态标成 `.open(tertiary)` 再执行 action，导致 `presentHistory` 里保护浮层的 `ownsCurrentHover` 守卫恒真、形同虚设，三级展示随即 `dismiss()` 浮层。修复：`ControlPaletteCoordinator.claimsHoverPointer()`（锚点∪浮层∪走廊包络）注入 `GeekPanelCoordinator.controlPaletteClaimsPointer`；`scheduleModulePreview` / `scheduleTertiaryPreview` 在浮层认领指针期间返回不扰动挂起任务的 `expiredRequest()`（新增 API，区别于会取消挂起工作的 `beginRequest+cancel`）；`presentHistory` 对非固定三级增加同一否决。指针离开包络后行为回到原互斥设计（悬停三级可替换浮层、pinned 点击始终生效）。
- 会话包络缺口：`pointerLocationChanged` 的包络只含附着列，指针跨到浮层（浮层在窗外）即判定"已离开面板"，且反向判定给 90ms 短收合延迟，未固定层级连同浮层被收掉。修复：`attachedHoverFrames` 把已展示的浮层窗口帧并入包络与走廊；浮层内指针移动经 `pointerLocationObserver` 回灌会话；浮层消失时 `didDismiss` 立即用实时指针重采样包络，避免延迟收合任务读到过期的"仍在包络内"。

回归测试：`testClaimsHoverPointerCoversAnchorPaletteAndCorridor`（ControlPaletteTests）、`testHoverPreviewsStandDownWhilePointerTravelsToPresentedPalette`、`testPresentHistoryYieldsToPaletteOnlyWhileItClaimsThePointer`、`testHoverEnvelopeIncludesPresentedPaletteFrame`（MenuBarPanelSessionTests）。既有两个互斥测试的浮层坐标源改为确定性远点，消除对真实鼠标位置的隐性依赖。注意设计事实：`cascadeGap = 0`，附着面板边贴边，浮层与窗口共享边缘。

### "总是已失效 + 界面慢半拍"根因：NSSlider 事件跟踪冻结 MainActor（2026-08-14 晚）

用户反馈手动控制总出现"已失效"且界面更新慢半拍。根因是 AppKit 经典陷阱：SwiftUI `Slider` 底层是 NSSlider，按住/拖动期间运行阻塞式事件跟踪 RunLoop，**主线程 GCD 队列（即全部 MainActor 任务）冻结**——遥测发布、`process()` 续约、UI 更新全部暂停。拖动超过看门狗窗口 → Helper 恢复自动 → 松手后续约收到 `fanLeaseExpired`/状态不符 → 显示"租约已失效"；松手时积压更新一起涌出 → "慢半拍"。满速保持探针（无拖动）稳定 50s 通过，正是因为没有跟踪循环。修复：

- **非阻塞滑杆 `FanControlSlider`**（`FanControlInlineControls.swift`）：DragGesture 驱动（拖动期间 RunLoop 正常运转），流式 update + 松手 commit 语义保留，含无障碍 adjustable ±5%。`FanManualSliderList` 全面替换 SwiftUI `Slider`；契约测试禁止该文件再出现 NSSlider 系滑杆。
- **看门狗窗口 15→30s**：`FanControlSafetyPolicy.watchdogSeconds = 30`，Helper 端校验范围 `(3...15)`→`(3...30)`（main.swift ×4、FanCurveController ×2）。容忍菜单/窗口拖动等其他事件跟踪暂停，安全语义保持：应用死亡后最迟 30 秒风扇交还系统。
- 端到端复验（新 Helper 二进制）：满速爬升 3628→7826、保持至 48.5s 零撤销、恢复自动带回读确认。

### 风扇监测与控制界面分离（2026-08-14 晚，用户指定按 iStat 模式）

用户反馈"调完风扇参数后一点监测界面就跳回自动"，并要求控制界面独立于监测界面。排查结论：小窗监测视图中无任何显式 selectMode 调用；最可疑机制是下午加入的内联分段选择器（`FanModeSegmentedPicker`）——点击监测行会触发三级面板展示、面板重排导致卡片重建，AppKit 分段控件在重建瞬间可能误发段 0（自动）选中事件并真实调用 `selectMode(.systemAutomatic)`。按用户要求的架构分离直接消灭该机制：

- **监测（传感器页「风扇」卡）只读**：每风扇转速行（悬停历史保留）+ Helper 状态胶囊 + 只读模式文本 + 常驻状态行；卡内不再有任何改变硬件状态的控件（分段选择器、滑杆全部移除）。
- **控制（附着浮层）唯一**：模式三档开关、同步勾选、百分比滑杆、曲线编辑器只存在于浮层。入口两个：卡片「风扇控制」行（点击固定展示，`ControlPaletteAnchorButton`）与右列 FANS 环（悬停展示）。
- `FanControlInlineControls.swift` 删除 `FanControlSegment`/`FanModeSegmentedPicker`/`FanCurveEditorLink`（连同其"曲线段直开编辑器"逻辑并入浮层既有行为）；保留浮层使用的 `FanSyncToggleRow`/`FanManualSliderList`。
- 契约测试 `testSensorsPageSeparatesFanMonitoringFromControl`：监测源文件禁止出现 `FanModeSegmentedPicker`/`FanManualSliderList`/`fanControl.selectMode`/`Picker(`。
- 视觉经快照管线实拍确认（风扇卡：两行转速 + 分隔线 + 风扇控制入口行 + 状态行）。

### 手动风扇"调到最大后弹回"根因与修复（2026-08-14 晚，真机复现定案）

用户反馈手动调到最大后会自动弹回。新增 Beta 专用探针 `--diagnose-fan-max-hold`（`HardwareControlDiagnostics.runMaxHoldProbe`，500ms 高频状态采样 + 进程内实例计数），真机两次对照实验定案：

- **双实例（复现）**：提交 100% 后 SMC 目标转速被冻结在入场值，12.5s 后反馈看门狗如实触发「风扇实际转速未达到已验证目标」→ 恢复自动。根因：两个 GUI 实例共享唯一特权 Helper，连接互相顶替时 Helper 按断连安全设计恢复自动散热，静默抹掉另一实例的手动目标。实例来源：安装脚本启动一个 + `open -n` 又开一个（07:36 起本机长期双实例）。
- **单实例（验证）**：同一探针下 100% 手动完美工作——目标按 500 RPM/s 限速爬升 2644→7826，实际转速精确跟随（7822/7826），满速稳定保持 50s，`observedMode=manual` 稳定，恢复自动干净利落。控制链路本身无缺陷。
- **修复**：`StorageCleanerMacApp.init` 首行单实例守卫 `terminateIfDuplicateInstance()`——存在更早启动的同 Bundle ID 实例时激活对方并 `exit(0)`（启动竞态只退较新者）；在任何 store/监视器/Helper 连接创建之前执行。契约测试 `testAppYieldsToExistingInstanceBeforeTouchingTheHelper`。
- **顺带修复**：分段选择器点「曲线」而无已应用曲线时，现在直接打开浮层曲线编辑器（原先只弹消息且跳回自动，曲线区域永远进不去——即用户说的"选模式也没办法在里面设置"）。
- 工作流注意：今后本地起 Beta 用 `open`（不带 `-n`）；诊断探针运行前必须先杀主实例，结束后杀探针实例。
- 补充事实：`selectMode(.manual)` 会以当前转速为入场值（刻意设计，平滑接管）；SMC 上报的风扇最大值随电源状态变化（观测到 5959 与 7826 两种）。
- **1.9.12 后续真机修复（2026-08-15）**：单实例 PID `44186` 仍两次触发「实际转速未达到目标」。根因是上层把物理 RPM 收敛当成控制有效性，并在逐级升速时持续比较早期目标；风扇正确跟随新目标也可能在 12 秒后被误判。已删除这条不可靠的自动回退，Helper 对手动位与目标寄存器的写后回读、5 秒租约回读、30 秒 watchdog、热保护和硬件范围变化继续 fail-closed。新构建真机 100% 保持 50 秒稳定在约 7830 RPM，随后恢复系统自动并回读确认。

### 传感器页内联风扇控制卡（2026-08-14 下午，直接回应"手动控制在哪里设置"）

用户反馈"手动控制还是有问题，它在哪里设置？可以在小窗直接设置吗"。结论：控制不再藏在悬停浮层后面，传感器页的"高级控制"卡重做为**内联风扇控制卡**（`GeekSensorsView.geekHardwareControlSummaryCard`）：

- 结构：`风扇控制` 标题 + Helper 状态胶囊（可点：注册/打开系统设置/重新检测）→ `自动 | 曲线 | 手动` 分段选择器（始终可点，热保护时除外）→ 模式内容区 → 常驻状态行（`lastMessage` 或情境提示）。
- 手动模式：`同步所有风扇` 勾选 + 内联百分比滑杆（同步单杆 / 每风扇最多 2 杆），实时转速显示在行内；曲线模式：当前曲线名 + 输出% + `编辑` 链接（`FanCurveEditorLink` 直接打开浮层曲线编辑器页）；自动模式：每风扇转速行（保留悬停历史三级）。
- 卡高按状态确定性计算（chrome 75 + 各模式 body），最坏情况（双风扇手动不同步）约 157pt，传感器页 544pt 预算内实测有余量。
- 共享组件抽到 `FanControlInlineControls.swift`：`FanControlSegment`、`FanModeSegmentedPicker`、`FanSyncToggleRow`、`FanManualSliderList`、`FanCurveEditorLink`；浮层 `FanControlPaletteView` 的手动滑杆改用同一 `FanManualSliderList`。
- 滑杆提交从 `DragGesture.onEnded`（点击轨道不触发）改为 `Slider(onEditingChanged:)`（拖动流式 update + 松手 commit），两个表面共用。
- 视觉验证：经 `--capture-menu-bar-panel-directory` 快照管线对真实数据实拍确认（自动模式：分段选中"自动"、两行转速、绿色"高级控制已启用"胶囊、状态行文案正常）。
- 契约测试：`testSensorsPageOffersInlineFanModeAndManualSliders`；浮层滑杆断言迁移到共享文件并锁定 `onEditingChanged` 提交与 `DragGesture` 缺席。

### 风扇/电源浮层重启后假死修复（2026-08-14）

用户反馈"手动控制和系统自动都无法点击"。根因：`FanControlCoordinator` 每次应用启动 `isHelperReachable=false`，已批准的 Helper 在 ping 通之前 `helperState` 呈现 `.connectionInterrupted`，而唤醒时之外**没有任何自动 ping**；`modeIsDisabled` 又对一切非 `.enabled` 状态硬禁用模式行——每次重装/重启后风扇模式行必然全灭，只能靠不显眼的「重新检测」救活。修复（`ControlPaletteViews.swift`）：

- `ControlPaletteRootView` 增加 `.task(id: presentation.kind)`：风扇/电源浮层一打开就 `refreshConnection()`（内部仅在 `helperStatus == .enabled` 时 ping，绝不触发注册或审批弹窗），电源浮层的按钮禁用态同样受益。
- `modeIsDisabled` 重写：仅在切换中/应用中、热保护、以及（已连接时）无验证转速范围时禁用；可恢复的 Helper 状态（连接中断/未注册/待批准）保持可点——`performSelectMode` 本身就会走 refreshStatus → prepareHelperForControl → ping 的完整自愈流程（选自动成功即回读确认并置 reachable）。安全边界不变：真正的强制层在协调器与 Helper（fail-closed），UI 门只是提示。
- 契约测试：`testFanPaletteSelfHealsAfterRelaunchInsteadOfDeadDisabling`（HardwareControlPresentationTests）。

### 小窗风扇控制入口重做（2026-08-14，对照用户提供的 iStat 截图）

用户反馈"风扇控制没看到加进去"。排查确认浮层本体（自动/自定义曲线/手动三档 + 同步勾选 + 百分比滑杆 + 实际转速回读，`ControlPaletteViews.swift` 的 `FanControlPaletteView`）与 iStat 截图的交互设计一致且后端已真机验证，问题全在入口不可发现：

- 根因 1：传感器页中间"高级控制"卡在**检测到风扇时**（用户 M5 Pro 有 2 个风扇）只显示每风扇转速历史行，「风扇控制」入口行被顶掉——有风扇的机器反而没有控制入口。修复：控制行常驻（转速 · 模式 + 披露符号），历史行列在其下，卡高改为 `31 + (1 + min(2, 风扇数)) * 24`。
- 根因 2：风扇不在悬停展示白名单（`supportsHoverPresentation` 原来只有 power/networkConnection），FANS 环和控制行都是纯点击按钮，悬停毫无反馈。修复：`.fan` 加入白名单，传感器页 FANS 环与「风扇控制」行改用 `ControlPaletteHoverAnchor`——悬停即出浮层（与电源模式一致），点击固定。一级总览的风扇环保持点击（与总览电源锚一致，避免与模块预览悬停冲突）。
- 契约测试同步：`PanelChartNormalizationTests`、`GeekSensorsPowerHoverDetailTests` 的锚点断言改为 HoverAnchor；新增 `testFanHoverOpensAttachedPaletteAndClickPinsIt`（ControlPaletteTests）。
- 注意：悬停到浮层的路径能活下来依赖本轮早些时候的"浮层指针认领 + 会话包络含浮层"修复。

### 应用更新：为"自维护"应用补齐可见升级路径（2026-08-14）

背景：两份覆盖面研究（本机 `/Applications` 81 个有效应用）确认约 27%（22 个）应用无任何已验证更新来源、17 个 Sparkle 应用只读探测全部不合格——这些应用此前只出现在摘要计数里，目录列表完全不可见，用户感知为"无法升级"。本轮在**不放宽任何自动安装安全门**的前提下补齐引导路径：

- 新增 `VendorUpdaterProvider`（`Features/AppUpdates/Providers/VendorUpdaterProvider.swift`）：只凭包内无歧义标记识别自维护应用——Info.plist `KSUpdateURL`/`KSProductID` 或 `KeystoneRegistration.framework`（Google Keystone）、`Contents/Frameworks/Squirrel.framework`（Squirrel.Mac/Electron）。纯本地只读，不联网、不信任应用自报 URL。命中后 provider=`vendorUpdater`、capability=`.inApplication`、状态 `latestVersionUnknown`（诚实：不声称有更新），文案引导"打开应用内更新"。注册顺序在 OfficialWebsite 之后、Manual 之前。本机实测命中：Chrome（Keystone）、Discord/Cursor/Kimi（Squirrel）。
- 目录列表纳入规则新增 `hasActionableInApplicationPath`（`AppUpdatePresentationModels.swift`）：Sparkle（有 framework/feed 证据但版本未知/探测失败）与 vendorUpdater 应用现在会出现在目录中，类别为「应用内更新」，行内版本显示为当前版本、不显示"→ 新版本"，`isUpdateAvailable=false`、不可进一键批次。原「已确认更新」语义（`hasConfirmedPresentableUpdate`）未动。
- `vendorUpdater` 能力/文案从 manual 桶拆出：`updateHandlingTitle`「请在应用内检查」、详情说明自带更新器维护；`inferredUpdateCapability` 与 registry `capability()` 均映射 `.inApplication`。
- 明确不做（保持安全边界）：不代装 Sparkle/厂商更新、不恢复 mas CLI 自动升级、不做通用 HTML 爬虫。Steam/Zoom/WhatsApp/Teams 等无包内标记的应用保持手动分类（后续可经签名注册表扩容收编）。
- 回归测试：`testVendorUpdaterDetectionRequiresUnambiguousInBundleMarkers`、`testVendorUpdaterClassificationYieldsInApplicationGuidanceWithoutVersionClaims`（AppUpdateModelsScanningProviderTests）、`testCatalogSurfacesInApplicationPathsWithoutClaimingUpdates`（AppUpdatePresentationModelsTests）；既有 `testClassificationKeepsSourceResolutionSeparateFromVersionCheckFailure` 断言随能力映射更新为 `.inApplication`。
- 后续候选（未实施，按研究优先级）：签名注册表扩容 30–50 款热门应用（Chrome/Discord/Steam/Zoom 的官网确认路径）、Sparkle 只读探测门分级（`SURequireSignedFeed` 从硬门槛改分级）、Homebrew `auto_updates` cask 路由到应用内、未知应用默认"搜索并确认官网"闭环。

### 性能审查中暂缓的项（需专项设计或 profiling）

- 清理扫描 per-entry syscall 合并与 symlink 检查降本：触及"不跟随 symlink / 不越根"安全不变量，需先补专项测试再动。
- Top-40 剪枝：排序键需要全量聚合才可知，保语义的剪枝需要先设计粗筛比较键。
- 浏览器隐私 snapshot 策略与 Processor 校验链：明确不为性能削弱备份与校验；只可在保持只读与身份校验前提下做流式聚合设计。
- 规则级并行扫描：必须先解决共享 `seenIdentityKeys` 的并发一致性，否则硬链去重与安全边界会坏。
- APFS clone 可回收字节口径（logical vs reclaimable）：正确性改进，涉及 UI 口径，另行处理。

### 设计事实（后续开发注意）

- 全部主模块路由为 `isImmersive`：浅色系统外观下内容区仍是饱和深色渐变、正文白字。侧边栏品牌深色是有意设计，与内容区匹配；不要因「浅色模式侧栏是深色」而改成自适应浅色。
- `AppUpdatesView` 存在约 70 处硬编码半点字号（10.5–13.5pt）与散落圆角，是刻意做密的排版；统一到 `AppTypography`（基于 13pt body）会明显放大字号、改变密度，必须配合真窗截图逐屏验证后再动。

## 验收与测试结果（本轮）

| 检查 | 命令/证据 | 结果 |
| --- | --- | --- |
| Debug 构建 | `swift build`（仓库内增量） | 通过 |
| 全量单元测试 | Beta 安装流程内置 `swift test`（2026-08-15） | `2574 tests / 15 skipped / 0 failures` |
| 真机手动风扇验证 | `--diagnose-fan-max-hold` 探针（单实例） | 100% 手动：目标限速爬升 2644→7826、实际精确跟随、稳定保持 50s、恢复干净 |
| Shell 语法 | `bash -n script/build_and_run.sh` | 通过 |
| Beta 打包/安装全流程 | `./script/build_and_run.sh --beta --install`（2026-08-15 18:23 实跑） | 通过：内置仓库验证 `2574 / 15 / 0`，strict codesign + Designated Requirement 满足；1.9.12 Build `20260815081858` 已安装并运行 |
| AI 开发工具残留真机只读扫描 | 已安装 Beta 的智能扫描 + 候选详情弹层 | 通过：Codex、Cursor、OpenCode 实际候选显示所属工具、残留类型、最近活动和风险；Claude Code、GitHub Copilot、OpenClaw 未发现时不伪造候选；实际清理 0 项 |
| 真窗截图 | 已安装 Beta 的全可见窗口截图 + 电源模式 fixture | 通过：电源模式浮层固定在电池二级菜单旁并顶边对齐；源行移动回归测试通过 |

注意：仓库内 `.build` 目录跑 `swift test` 会间歇性因 File Provider 重附 `FinderInfo` 导致 xctest 签名失败（`resource fork ... detritus not allowed`），`xattr -cr` 后仍可复发；稳定做法是 `--scratch-path` 指向 `/tmp`。

## 真实硬件控制验证（2026-08-14，Mac17,9 / M5 Pro）

此前文档记录「没有完成真实 SMC 风扇写入矩阵 / 真实 pmset 电源模式写入矩阵」。本轮已在真实硬件上完成首次端到端验证（证据：`/tmp/storage-cleaner-hardware-writes.txt`，经 Beta 专用 `--diagnose-hardware-writes` 探针走生产 `FanControlCoordinator` 路径生成）：

- Helper 注册链路：`SMAppService` 状态 `requiresApproval` → 用户在系统设置批准 → `enabled`，root Helper 进程运行，XPC 连通。
- 电源模式（电池侧）：`lowPower(1)`、`highPower(2)`、`automatic(0)` 三档全部真实 `pmset` 写入并回读一致（VERIFIED）；即 M5 Pro 14" 支持完整三档。
- 风扇手动控制：请求 fraction 0.30，安全地板策略生效（不低于系统当前需求，实际应用 0.36）；目标写入 `F0Tg`/`F1Tg` 后实际转速跟随（4121/4126、4461/4456，误差 ≤6 RPM），`observedMode=manual` 回读确认；恢复自动后 `observedMode=systemAutomatic` 确认，系统接管转速。
- 修复了授权死锁：`SMAppService.status == .notFound` 时协调层现在也会尝试 `register()`（原先只在 `.notRegistered` 时注册）；`ControlPaletteHelperStatusView` 与 `GeekSensorsView` 在 `.unavailable` 状态下现在提供「启用高级控制」而非只有无效的「重新检测」；`.unavailable` 诊断文案不再错误声称需要 Developer ID + 公证（Apple Development 签名的 SMAppService daemon 实测可注册、可批准、可运行）。
- 新增 Beta/DEBUG 专用诊断：`--diagnose-hardware-control`（注册状态探针，写 `/tmp/storage-cleaner-hardware-probe.txt`）与 `--diagnose-hardware-writes`（真实写入探针，全程回读、结束恢复原状）。

## 已知未完成与待决事项

1. 【需用户决定】红色扫描项目最终策略：当前实现为红色不可选（fail-closed）；历史需求曾出现「红色可选但强警告」。改动前必须用户确认，不得自行降低保护等级。
2. 【需用户确认】清理 `/Applications` 中多份 Beta 副本（含 `previous` 回退版本去留）与被污染的 `dist/beta` 残留。
3. `AppUpdatesView` 排版 token 统一：需截图驱动逐屏验证（见上文设计事实）。
4. 智能扫描空闲态 `minHeight: 430`、Cleanup 弹层固定宽 360/380、重复文件确认 sheet 固定 700：调整前需真窗验证，且不得破坏 1.9.10 固化的页面几何回归测试。
5. 小窗长期能耗：短时 CPU 约 0.2%–0.8%、RSS 约 203 MB；尚未证明泄漏，也未做长时间监测。
6. 硬件控制剩余未验证项：Helper 撤销/升级流程与 watchdog 自动回退仍未在真实授权下执行（SMC 风扇写入、pmset 三档电源模式写入与首次批准链路已于 2026-08-14 真机验证，见上文）。
7. 完整真实 Sparkle 旧版到新版交互更新过程未验证。
8. Developer ID 签名与 Apple 公证仍不可用（本机无证书）。
9. `RealMacUIAccessibilitySmokeTests` 默认跳过；截图不能替代完整无障碍自动化。

## 1.9.13 开发与发版提醒

- 每轮 1.9.13 修改先运行最小相关测试；完成一批改动后再运行完整本地测试，并用 `./script/build_and_run.sh --beta --install` 生成、安装和回读新的 1.9.13 Beta Build。
- 准备发布时更新 `script/release_version.env`（1.9.13+ 新版本号 + 新 Build）、`CHANGELOG.md`、`RELEASE.md`，并走 `docs/RELEASE_CHECKLIST.md` 完整流程。
- 未获明确发布授权前，不推送、不创建标签或 GitHub Release、不更新 appcast、不触发 GitHub 工作流；任何后续发布均不得覆盖 1.9.12 资产。
