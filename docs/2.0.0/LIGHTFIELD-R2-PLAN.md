# 光场二期：UI 细节重做计划（供 Opus 5.5 会话执行）

版本：2026-10-09 上午；作者：Claude（Fable 5.1 规划会话）。执行者读完本文即可接手，不需要回看原会话。

## 0. 结论

用户对光场一期（D67，三个试点页）的评价：对齐做到了、风格统一、动画可以；但**细节太简单**。本计划把一期的骨架（标题／内容区／主按钮／状态行同位）保持不变，补上一层“有信息的视觉元素”，并把剩余 11 个功能页、设置 7 类、小窗颜色设置和权限授权页全部做到同一风格。做法按用户要求：**先让 Codex 出效果图，用户确认后再改代码**。

用户原话里的四个问题，对应到页面：

| # | 用户反馈 | 对应页面与根因（已核对） |
|---|---|---|
| 1 | 登录项、后台项、代理系统项只是文字，不好看 | 登录项与后台任务。D64 删掉了行首图标和状态胶囊，现在行里只剩名称＋来源＋状态文字 |
| 2 | 内存管理有些数字不在圆圈里 | 内存管理结果页的“压力／占用”双圆环。文字是固定字号，圆环按窗口宽度缩放，窄窗或“升高”这类两字文案时溢出；要在七尺寸矩阵复现 |
| 3 | 已采样进程应显示图标；能耗只有文字；卸载、应用更新只有文字，甚至“出了方框” | 内存进程表没有应用图标；能耗页 D64 后行首图标被删；卸载列表的路径列、应用更新的计数格在实际数据下文字超出区域（“出了方框”＝溢出），需在安装版实机复现 |
| 4 | 系统健康和整个软件对不上 | 系统健康结果页仍是旧结构（整页外框卡片、2×2 因子卡、主按钮在卡片中段、日间 #EBEBE7 暖灰），光场一期只改了它的起始／运行页和一个结果试点 |

额外要求：设置界面同风格；小窗“通用”里的颜色修改、权限授权这两处要做完整。

## 1. 现状（执行前必须核对）

| 项 | 状态 | 位置 |
|---|---|---|
| 集成分支 | `integration/2.0.0-beta`，HEAD `f4cf185f`（R20 BOARD 行） | `~/Developer/StorageCleanerMac` |
| 已安装测试版 | 2.0.0（20261008161734，提交 131bf04e），**用户看到的就是这一版**，还没有光场一期 | `/Applications/测试版.app` |
| 光场一期工作区 | 分支基于 `b5249d1d`，第五轮已完成并本地提交为 `20a5fc38`（实现者报告：全量 Debug 4280 项 0 失败、反证 30 条全红；Release／严格并发／七尺寸截图未跑）。**还差**：独立复核 → 合并树完整套件 → `--no-ff` 合并 → BOARD 行。交接文档 `docs/2.0.0/collab/handoffs/r2-lightfield-r1.md`，日志 `~/Developer/.sc-build/r2-lightfield-r1/logs/r5/` | `~/Developer/sc-worktrees/r2-lightfield-r1` |
| 光场规范 | D67 数值规范（骨架、动效、颜色令牌） | `docs/2.0.0/D67-LIGHTFIELD-SPEC.md` |
| 原型 | 用户认可的可交互原型 | https://claude.ai/artifact/BkYjgZZ5F7Hvzn7b8LaDGS ；源码 `~/Developer/.sc-build/r2-redesign/proto/template.html` + `art.js` |
| 一期截图 | 三个试点（安全清理、系统健康、卸载）三态、日夜 | `~/Developer/.sc-build/r2-lightfield-r1/visual-r5/` |
| 14 个结果页现状审计 | 逐页差异表（2.2 节）和统一方案 | `~/Developer/.sc-build/r2-lightfield-r1/reference/results-audit.md` |
| 一期验收遗留 | 9 条未勾 | `~/Developer/.sc-build/r2-lightfield-r1/reference/acceptance-checklist.md` |
| 插画资源 | 风格 A“玻璃光泽 3D”，26 张，含 prompt | `~/Developer/.sc-build/art/set-A/` |
| 决策记录 | D63–D68 | `docs/2.0.0/collab/DECISIONS.md` |

## 2. 先定一条新决策（D69，写进 DECISIONS.md 再动手）

D64 说“删掉所有不可点击的图标”，用户现在说“只有文字太单调”。两者不冲突，但要把边界写清楚：

- **保留删除**：纯装饰图标（分区标题前的小图标、按钮里的图标、卫星、填充插画）。
- **必须有**：**承载信息的图形**——应用图标（识别进程／应用／登录项是谁）、状态符号（正常／警告／失败／锁定／只读，带 AX 文字）、数据图形（圆环、条形、趋势线、计数）、每个功能一张主插画（起始／运行态大图、结果态缩小到摘要区）。
- **图形来源只有两种**：真实应用图标（`NSWorkspace` 经 `CachedAppIconView`，守护进程无图标时用统一的灰色占位符号），以及风格 A 插画缩略（侧栏 20×20、摘要区 76×76）。不再混用彩色 SF Symbols 方块。

把这条作为 D69 写入 `docs/2.0.0/collab/DECISIONS.md`（日期 2026-10-09，注明“用户在 Claude 会话中提出：元素过于单调、进程应显示图标”）。

## 3. 工作流程（每一页都走同一条线）

```
B0 基线截图 ──► B1 Codex 效果图 ──► C-UI1 用户确认 ──► B2 共用组件 ──► B3–B7 分批实现 ──► B8 验收/门禁/安装 ──► C-UI2 用户实机确认
```

### 3.1 Codex 效果图怎么做

用户要求“把现在的图喂给 Codex，告诉它要做成什么样，让它生成效果图”。两种产物，分开生成：

1. **页面效果图（主产物）**：让 Codex 在原型 `template.html` 基础上写每页的 HTML 效果图（同一画布 1070×735、同一令牌、同一骨架），再用内置浏览器或 Playwright 在 1280×763 渲染成 PNG（日夜各一张）。选 HTML 而不是直接生图，因为 HTML 能量出位置和字号，直接变成规范数值；生图只能看个大概。
2. **插画与图标（辅产物）**：缺的功能主图、侧栏缩略、摘要区小图，按 `~/Developer/.sc-build/art/set-A/prompt.md` 的风格 A 续生成（透明底 1024×1024，无文字），命名沿用 `module-<feature>.png`。

Codex 调用（全部用 `openai/gpt-6.1-sol`，Codex 不能编译，只写 HTML／资源／文档）：

```bash
/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex exec -m openai/gpt-6.1-sol -s workspace-write \
  -C ~/Developer/.sc-build/r2-lightfield-r2/mockups --skip-git-repo-check \
  --add-dir ~/Developer/.sc-build/r2-lightfield-r1/reference \
  --add-dir ~/Developer/.sc-build/r2-redesign/proto \
  --add-dir ~/Developer/.sc-build/art/set-A \
  --add-dir ~/Developer/.sc-build/_prompts -- "$(cat ~/Developer/.sc-build/_prompts/lf-r2-mockups.md)"
```

- 提示词文件用**带引号的 heredoc**写（`<<'EOF'`），否则反引号会被执行。
- 容量错误用 `~/Developer/.sc-build/_prompts/resume-retry.sh <worktree> <scratch> <session> <msgfile> <logprefix>` 续跑。
- 喂给 Codex 的输入：每页的现状截图（B0）、一期三张试点截图、D67 规范、原型源码、`results-audit.md` 对应行、以及下面第 4 节该页的“要做成什么样”。
- 效果图要求 Codex 同时交付：`<page>-<state>-<theme>.html`、渲染好的 PNG、以及一张 `measurements.json`（每个元素的 x/y/w/h/字号），这样 B2 直接把数值写进规范。

### 3.2 实现、验证、合并（沿用一期流程）

- 每批一个工作区 `~/Developer/sc-worktrees/r2-lightfield-r2-<batch>`，从合并了一期的集成分支拉。依赖拷贝自 `~/Developer/.sc-build/r2-u1-preselect/debug`，sed 替换 `workspace-state.json` 里的路径；构建用 `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8`，离线参数 `--skip-update --disable-automatic-resolution --manifest-cache local`。
- 实现者：Codex（sol）写 SwiftUI；编译和运行时问题（AX、布局探针）交给能构建的 Claude 子代理。
- 验证顺序固定：构建（失败即停）→ 定向测试 → 完整 Debug 套件 → 变异反证**最后**跑 → 重新构建。脚本 `scratchpad/batch-verify.sh <batch> <prepdir> full`、`scratchpad/run-mutations.py`。
- 提交后 `MODEL=gpt-6.1-sol git rebase -q --exec "$HOME/Developer/.sc-build/_prompts/fix-trailer.sh" <base>`；`--no-ff` 合并；合并树再跑完整套件；BOARD 加一行；立刻删该批的构建缓存（保留日志、截图、证据）。
- 门禁 `~/Developer/.sc-build/integration-verify/gate.sh`（含 beta-config-build）；安装 `STORAGE_CLEANER_SKIP_TESTS=1 SWIFT_BUILD_JOBS=4 script/build_and_run.sh --beta --install --verify`，装前问用户。

## 4. 分批任务

### B0 基线与复现（半天，不改代码）

1. 等一期实现者完成；跑完整套件、提交、派独立复核、合并进集成分支（一期先落地，二期在它之上）。
2. 用 Debug 包拍**所有页面**现状：14 个功能三态、设置 7 类、小窗通用页、权限页，日夜各一套，1280×763。起始／运行用 `capture-main.sh ... --debug-feature-page=all:landing --capture-feature-templates`；结果页用 `~/Developer/.sc-build/r2-results-unify/tools/`（`ResultsUnifyCapture.swift` + `apply-harness.py`，只打在 scratch 副本上）；设置窗口用 `--capture-settings-window`。存到 `~/Developer/.sc-build/r2-lightfield-r2/current/`。
3. 在安装版上**只读复现**三处布局缺陷并截图（LCU `mcp__lcu__js` 截图，不点任何执行按钮）：内存双圆环文字溢出（拖窗口到 820×560、677×390）；卸载列表路径列溢出；应用更新计数格溢出。记录触发尺寸和数据。
4. 写 D69（第 2 节）。

### B1 Codex 效果图（1 天，Codex 为主）

按页写“要做成什么样”，交给 Codex 出 HTML + PNG + measurements。每页三态、日夜，骨架不变，只设计内容区：

| 页 | 内容区要做成什么样 |
|---|---|
| 登录项与后台任务 | 结果列表每行：应用图标 24（无图标用灰色齿轮占位）｜名称＋一行来源（登录项／后台任务／代理）｜状态符号＋状态文字（运行中绿／已禁用灰／受保护锁／等待触发）｜右侧开关（可管理项）或“只在系统设置”文字。顶部摘要区：插画 76 ＋“N 项，M 项可直接管理”大数字。筛选只保留“全部／登录时打开／后台运行”三个文字分段，去掉下拉行 |
| 内存管理 | 摘要区：一个压力圆环（文字按圆环直径缩放，最小 0.8 倍，保证永远在圆内）＋ 右侧三组数字（已用／缓存／交换）＋ 一条 2 分钟趋势线（绘图区高 96、左轴 42、右侧当前值槽 62，依据确认图 memory-landing 的 SVG 520×96；无卡片；B2 复核轮更正，原写高 48 是性能运行页小趋势的尺寸）。列表“已采样进程”：图标 24｜进程名｜PID 等宽｜占用右对齐＋一条与占用成比例的细条（高 3，accent）。“可退出应用”分段：勾选框代替图标列的位置 |
| 能耗 | 摘要区：插画 ＋ 当前功率大数字（单位 W 用 accent）＋ 运行时间；列表每行：应用图标｜名称＋“N 进程 · CPU x%”｜累计 Wh｜当前 W｜平均 W，数值等宽右对齐，行底一条能耗比例细条。去掉“系统测量”说明卡，改成状态行右侧一句 |
| 卸载 | 保持一期结果布局；路径列改为中间省略（`truncationMode(.middle)`）并限制在列宽内；行首加真实应用图标 24；摘要区大数字为“可审阅总量” |
| 应用更新 | 标题恢复为“应用更新”（现在写成“扫描完成”）；摘要区：插画 ＋ “7 个已检查”；下面一行 6 个计数**不是卡片**，是“数字＋标签”的横向组（等分、文字自适应缩小、不溢出）；列表直接列出有更新的应用：图标｜名称｜当前 → 新版本｜处理方式（可直接更新／退出后更新／需授权／手动）；主按钮“查看并处理更新 · N 个” |
| 系统健康 | 按一期试点那张（`visual-r5/night-1280x763-healthHub-result.png`）为准，补：评分圆环（数字在环内）替代纯数字；每行状态符号＋因子名＋证据＋状态词；展开行显示建议；去掉整页外框和日间 #EBEBE7；“重新检查”在主按钮位 |
| 性能测试 | 起始：插画＋“开始测试”；运行：大百分比＋当前子项；结果：总分大数字在摘要区，四项分数（CPU／GPU／内存／存储）为“数字＋细条”，历史与社区榜放到列表下方分段，温度／负载曲线只在运行态 |
| 浏览器隐私 | 结果：摘要“N 条记录 · M 个站点”；分组头用细线＋站点图标＋域名，不用实色横条；行：勾选｜浏览器图标 16｜标题＋完整网址（等宽，中间省略，可展开）｜时间；工具按钮只留文字的“全选／反选” |
| 设置（7 类） | 同一画布：左侧分类列表（与主窗侧栏同令牌），右侧标题 34 pt＋细线分区，行高 52，开关／下拉在右；无卡片、无磨砂。「小窗」类里的预览保持实时 |
| 小窗 · 通用 · 颜色 | 一行色板（深空／晨雾蓝＋强调色 8 选），选中态有勾；更改后预览与真实小窗即时同步，退出重开保留 |
| 权限授权 | 每项一行：权限名｜一句用途｜状态符号＋状态词（已授权／未授权／需重启）｜“前往授权”按钮（打开对应系统设置面板）；返回应用自动重查；系统助手（Mac mini 模式）审批也在这一页，有“等待批准／已批准／已失效”三态 |
| 文件四页（分析／搬家／重复／相似照片） | 本批只出效果图，实现放 B7 |

产物放 `~/Developer/.sc-build/r2-lightfield-r2/mockups/`，用 `for_user.py` 一类脚本拼成“现状｜效果图”并排图，`SendUserFile` 发给用户。

**检查点 C-UI1**：用户逐页确认或改。确认后把 measurements 写进 `docs/2.0.0/D67-LIGHTFIELD-SPEC.md` 第 2 节（内容区各态）扩成每页一小节，动效表不变。

### B2 共用组件（1 天）

在 `Views/DesignSystem/FeatureLightfield*.swift` 旁新增，全部无卡片、无磨砂，颜色只用令牌：

- `LightfieldAppIcon`（24／20／16，经 `CachedAppIconView`，占位符号统一）
- `LightfieldStatusGlyph`（normal／warning／failure／locked／readOnly／systemOnly，带 AX 文字；合并现有 `MetadataPillStatus`）
- `LightfieldRing`（直径、进度、中心文字；文字用 `minimumScaleFactor` 并以几何探针断言“文字框 ⊂ 圆内接方形”）
- `LightfieldMetricGroup`（横向等分数字＋标签，不溢出）
- `LightfieldDataBar`（高 3，比例条）
- `LightfieldListRow`（勾选型／状态型／开关型三种首尾列，中列弹性）
- `LightfieldSummary`（插画 76 ＋ 标签 ＋ 大数字 ＋ 单位）

测试：`FeatureLightfieldContractTests` 扩展——每个组件在 7 尺寸下几何断言；源码守卫禁止 `Material`／`glassEffect`／卡片背景出现在光场页。变异反证各留一条。

### B3 性能组（1.5 天）：登录项 ／ 内存管理 ／ 能耗 ／ 性能测试

- 文件：`StartupItemsDashboardView.swift`、`StartupItemsPresentation.swift`、内存相关视图（`SmartCareComponents.swift` 内的内存仪表盘、进程表）、`EnergyImpactScanLandingView.swift` 及能耗结果视图、`ComputerHealth/PerformanceBenchmark*.swift`、`BenchmarkV7DashboardView.swift`。
- 内存圆环溢出：根因在固定字号，修在 `LightfieldRing`；用 B0 复现的尺寸写回归测试。
- 进程图标：进程快照模型要带 bundle 路径／PID → `NSRunningApplication` 图标；守护进程占位。只读，不新增任何退出／清理动作。

### B4 应用组（0.5 天）：卸载 ／ 应用更新

- 文件：`FeatureLightfieldUninstallList.swift`、`AppUninstallScanLandingView.swift`、应用更新结果视图（搜 `installDebugAppUpdatePresentationFixture`）。
- 修路径列与计数格溢出；标题改回功能名；列表直出。更新只检查不安装（既有约束）。

### B5 保护组（1 天）：系统健康 ／ 浏览器隐私

- 文件：`ComputerHealthView.swift`、`ComputerHealth/ComputerHealthWorkspaceView.swift`、`HealthFactorGrid.swift`、`HealthScoreHero.swift`、`BrowserPrivacyRecordResultsView.swift`、`BrowserPrivacyWorkspaceView.swift`。
- 一期验收清单第 8、9、11 条在这批关掉。
- 浏览器隐私行“标题＋完整网址”是第二轮硬标准，不得退回只显示域名。

### B6 设置 ／ 小窗颜色 ／ 权限（1 天）

- 文件：`SettingsView.swift`（2215 行，按 7 类拆成 `Views/Settings/` 下 7 个文件再改）、`MiniWindowConfigurationSettingsView.swift`、`MenuBarPanelSettingsView.swift`、权限页在 `SettingsView.swift` 的 `accessAndSetup`、首次引导 `FirstLaunchOnboardingView.swift`。
- **设置里的小窗预览必须与真实小窗 1:1**（用户 10-09：“设置中，调颜色、调方向，右边显示的小窗模式应该是完全模拟、完全一致 size 的小窗模式，而不是精简过的”）：通用页（颜色）和小窗页（模块显示与顺序）右侧直接嵌入真实一级面板视图（`MenuBarStatusPanelRoot`／Geek 面板，演示数据），304 pt 宽、按模块实际高度（全开 605 pt），不缩放、不裁切、不省略模块；外观、菜单栏项目颜色、展开菜单底色、图表颜色、模块显隐与顺序改动即时反映；加几何测试锁定预览尺寸等于真实面板尺寸。
- 小窗颜色：先核对现有偏好键（D53：外观和画布只走启动参数的是测试拍摄，用户设置走共享域），确认“通用”里到底有哪几项颜色；缺的加上，改完实机验证小窗即时变色、重启保留。
- 权限：每项权限的“前往授权”要打开正确的系统设置 URL（`x-apple.systempreferences:...`），返回时重查（`NSApplication.didBecomeActiveNotification`）。**不替用户点授权，不读钥匙串**。
- 一期验收清单第 12、13 条在这批关掉。

### B7 文件组（1.5 天）：文件分析 ／ 文件搬家 ／ 重复文件 ／ 相似照片

- 按 B1 效果图实现；搬家行尾按钮截断（results-audit 2.2 第 12 行）一并修。一期验收清单第 6 条在此关掉。

### B8 验收、门禁、安装（1 天）

1. 对每一页：实现截图｜效果图并排，位置误差 ≤ 2 pt，颜色令牌一致；七尺寸矩阵（820×560、1000×700、1280×763、1680×1050、2400×1350、677×390、1280×390）无溢出、无重叠（几何探针断言）。
2. 一期 `acceptance-checklist.md` 全部勾完；本计划第 0 节四个问题各附“修前／修后”截图。
3. 门禁全绿；`--beta` 安装（装前问用户）；LCU 只读实机截图核对内存圆环、进程图标、卸载／更新无溢出、系统健康同风格、设置同风格、小窗换色即时生效、权限页状态正确。
4. BOARD 加行；DECISIONS 补 D69 执行结果；清缓存。

**检查点 C-UI2**：用户在安装版实机确认。

## 5. 验收标准（硬条件）

- 每个进程／应用／登录项行都有图标（真实图标或统一占位），不得只有文字。
- 任何圆环内的文字在 7 尺寸下都在圆内；任何数字组、路径列、计数格都不溢出所在列。
- 14 个功能、设置 7 类、权限页、小窗设置页：标题、内容区起点、主按钮、状态行的位置尺寸一致（误差 0.5 pt）；无卡片框、无磨砂、无装饰图标。
- 系统健康日间为晨雾蓝令牌，不再是 #EBEBE7。
- 所有新图形都带 AX 文字；减少动态效果时即时切换。
- 测试只增不删；不为通过检查放宽阈值。

## 6. 不做的事（沿用，原文有效）

- 不 push、不打 tag、不发布，不改正式版 `/Applications/存储清理助手.app`（哈希 0231149d…）和任何更新源。只有一份测试版 `/Applications/测试版.app`。
- 不运行会启动真实同步、创建训练计划、扫描清理、控制电器、修改用户记录或发布的命令；不读钥匙串、凭证、`.env`、令牌；不输出敏感原始记录。
- 真实数据上的删除只限 1–3 个绿色安全项（移入废纸篓后恢复）和自造测试文件；不清空废纸篓，不卸载真实应用，不安装真实应用更新。
- 桌面控制只用 LCU（`mcp__lcu__js`），不用 `mcp__computer-use__*`。退出 Chrome 前问用户。
- 用户数据只进废纸篓；构建缓存可直接删，而且合并后立刻删。
- 硬件设置改完立刻改回；后台采样不覆盖 macOS 充电暂停（D5）。

## 7. 节点

| 节点 | 交付 | 需要用户 |
|---|---|---|
| B0 | 一期合并；全页面基线截图；三处溢出复现图；D69 | — |
| B1 → C-UI1 | 每页“现状｜效果图”并排图 | 逐页确认或改 |
| B2–B7 | 每批：合并记录、修前／修后截图 | — |
| B8 → C-UI2 | 门禁、安装版 | 装前确认；实机看一遍 |

预计总量：Codex 效果图 1 天，实现 6–7 天（可两批并行，`ScanStore.swift` 同一时间只让一批改），验收 1 天。

B2 图表共享口径（ui 依赖补齐）：绘图区高 96、左轴 42、右侧当前值槽 62（单位 pt）。v11 按确认图传入绘图区高度及是否显示当前值槽；功率、频率、温度分轴，能效可传入非等距功率横坐标。
