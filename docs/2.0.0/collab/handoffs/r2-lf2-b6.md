# r2-lf2-b6：设置／小窗颜色／权限

2026-10-10；worktree `~/Developer/sc-worktrees/r2-lf2-b6`，分支 `task/r2-lf2-b6`，基线 `b3bacd0c`。交付为 prepared 分组补丁；本会话未提交、合并、安装、启动安装版、授权或写硬件。本轮读取了全部公共提示、协作规则、B6 全节、D53/D67/D69/D73 和冻结稿 NOTES/设置 HTML/日夜 PNG；冻结稿通过不等于实机验收。

## 实际实现

1. **先纯拆分**：`SettingsView.swift` 拆成 `Views/Settings/SettingsGeneral.swift`、`SettingsMiniWindow.swift`、`SettingsScan.swift`、`SettingsAccess.swift`、`SettingsSystem.swift`、`SettingsUpdates.swift`、`SettingsAbout.swift`。共享 state/helper 仅调整跨文件所需访问级别，声明体的归一化 token 对比通过；第一组的文件快照、hash、补丁hunk和构建日志已冻结在 scratch `phase1/`、`phase1-manifest.json`、`prepared/01-settings-split.patch`。
2. **七类共用光场布局**：复用 B2 `FeatureLightfieldBackdrop`、Artwork、Hairline、Check、ExpandableRow、按钮样式、路径文字和令牌。增加设置专用几何和行布局适配，移除原生 Form 卡片；固定可访问侧栏、键盘上下切页、版本、窗口恢复逻辑继续保留。普通页标题 x96/y92、内容 x96/y176；通用与小窗按冻结稿双列例外 x52/y12、内容 y64。窗口参考 1180×760，原生标题栏占 28 pt；最小窗口 560×390，内容最小高 362。窄窗口纵向滚动展示完整 304 pt 预览，不缩放。
3. **真实一级预览**：新增无服务的 `GeekOverviewPanel`，实际 Geek 概览与设置共同使用其模块组合（宽304、间隔6、inset8），设置卡片直接使用原有 Geek presentation 视图。一级六卡全开 304×605 pt，无电池 304×535 pt，全隐藏 304×64 pt；组件额外包含说明16/gap8/模拟菜单栏24/gap6，整体304×659。滚动只在外部预览列，不在面板内部；原有只读详情/历史另留入口。真实概览保留 liveCard、菜单、路由、锚点、采样；空态窗口修正到能容下原设置入口的64 pt。
4. **小窗颜色**：审计确认旧偏好已覆盖小窗外观、11项菜单栏预设及自定义日夜色、10项底色、6项图表主题及自定义背景/图表色、18项独立指标。没有新增第二套偏好键。新增 `PanelAppearanceEnvironment`，真实面板及设置共用同一 `AppStorage` 解析/指标注入，颜色更改不重建面板 identity；拍摄 forcedVisualMode 仅由原 live DEBUG/Beta 分支显式传入。通用页沿用即时保存，模块布局沿用草稿/应用/取消/离页与关闭确认，没有照 HTML 增加虚假的全局 Apply 事务。
5. **D73 入口**：演示传感器卡片直接显示真实 `FanControlEntryRow` 标题入口；模拟 telemetry、nil controlPaletteCoordinator 和关闭 hit testing 保证预览无真实控制，未用 disabled 导致灰化。
6. **权限**：行展示真实 `verified/notVerified/unknown`、按位置管理、按需确认及通知状态；没有把“未验证”推断成“未授权”。磁盘/文件/App Management/通知/助手按钮仍接对应系统设置 URL。设置可见时收到 `NSApplication.didBecomeActiveNotification`，general/access/system 调用现有只读刷新；不自动请求通知、不注册助手、不点击系统授权、不读钥匙串。若返回时已有读取在进行，合并为完成后的一次新读取，不丢掉返回事件、不启动重叠请求。助手“已批准运行中”要求注册 enabled **且**可信连接 enabled，否则显示“已安装 · 尚未连接”。
7. **拍摄权限夹具**：`Debug/SettingsAccessDemo.swift` 整文件 `#if DEBUG`，显式参数 `--debug-settings-access=pending|granted|unknown`；显示“演示状态”，读取刷新提前返回模拟状态，通知请求和助手动作无效果。Release 不含解析器或模拟授权状态。真实用户路径仍按现有服务读取，不按演示结果授权。
8. **系统控制**：原自动、曲线调节/自定义曲线、手动、最大转速命名来自现有 D73 model；保留辅助程序注册/迁移/授权、请求模式、观察硬件模式、真实可写范围门禁、曲线/手动目标、最大转速确认和“停用并恢复系统控制”。未改辅助程序协议或 `ScanStore.swift`。关于页保留构建、分发/授权诊断、复制和支持包预览导出；其品牌图按冻结稿76 pt。

需要 Store 新增的字段：**无**。

## 旧断言迁移依据

`phase1` 仅迁移读取方式，原10个源守卫读 `SettingsView` 时合并7个页文件，跨声明范围改为逐声明提取；393个原方法/3316个原断言保留，详见 scratch `test-migration.md`。基线已有 `CalibrationLanguageScope.swift` 的2处 volatile language domain 调用，但偏好卫生白名单仍指向旧文件；改为实际维护源、允许次数仍是2，未删除持久化断言。

第二组依据 D69/B6，逐项改写如下（没有降低阈值）：

| 测试 | 原实现定位 | 现在检查 |
|---|---|---|
| D64 七类别/标题 | `settingsDetailHeader`、所有 Image 都禁用、旧 sidebar role | B2单一标题、48 pt头图、20 pt导航图，禁止装饰SF；语义色板勾选/模拟读数允许；类别和无教程约束保留 |
| D64 权限安全 | `detail: PermissionSafetyDisclosure.settingsHelper.text` | 实际 `Text(PermissionSafetyDisclosure.settingsHelper.text)`；中英文密码、失联/过热恢复、联网同意和权限边界原文继续检查 |
| D64 排除路径 | 原 Text(path)/minus-circle AppIconButton | B2中间省略路径、文本移除、原回调及明确AX标签；新增长路径/实际AX按下测试 |
| D64 小窗编辑 | checkbox/chevron.up/down/旧简版预览文案 | B2 Check、显隐状态、文本上下移AX、拖动、共享完整预览出处；applyLive仍检查 |
| D64 列对齐 | 原600宽 Form/Header padding | 冻结稿新几何的标题/内容同列与同宽、对应实际 offset；0.5 pt阈值未变 |
| UIConsistency 设置结构/行 | Native NavigationSplitView/List/Form/旧局部hover | 固定可访问侧栏、B2行按钮/选中面、光场背景、无Form；主窗/项目浏览器原约束不变 |
| UIConsistency 页标题 | 旧可换行 V1标题 | 设置固定48 pt单行标题及header AX；其他页原换行契约不变 |
| PanelChart 外层 inset | live 文件自己 padding | shared组合只padding一次，live接组合；旧detail/palette inset检查不变 |
| PanelChart 色板/拍摄 | 旧ForEach及PanelScene内色彩解析 | 完整allCases色板绑定，live接共享解析，shared背景/图表解析仍检查；原语义图表/真实风扇证据不变 |
| UnifiedMenuBar 颜色 identity | PanelScene 内旧变量名 | shared的原AppStorage键、live接modifier、禁止颜色id；语言id保留 |
| WindowGlass | 原480×420最小尺寸 | B6支持560×390；原最大尺寸、原生chrome、恢复位置/禁止强制居中全保留 |

五个视觉守卫文件的方法数量分别19/46/83/28/12均不变；断言数181→192、1014→1015、659→662、224→226、61→61，详情 `visual-guard-migration.json`。

## 本轮验证

验证汇总以 scratch `test-results.json` 的每个方法最新结果为准，构建日志、测试完整日志均保留；没有将反证定义或截图模板计为通过。

- 纯拆分：sandbox `--build-tests` PASS；367项定向测试发现9个家目录夹具权限阻断、2个偏好持久化阻断，以及1个基线白名单定位错误。白名单修正后4项重查 PASS；第一组不能宣称全量全绿。
- 视觉：production与tests成功编译。首次393项定向运行定位了新探针的modifier顺序/两个夹具缺少viewport frame，以及已抽取实现的旧源码定位失败；均保留红日志并修正。实际布局探针在offset之前记录，全七类×八尺寸×日夜均维持0.5 pt检查。
- 完整预览：64组合×日夜的实际卡片宽高/inset/gap、304×605/535/64、组件659、同host显隐顺序、全部18指标/外观/背景/图表/菜单栏自定义日夜偏好即时读回、无颜色identity重建、D73入口AX与无硬件效果测试。
- 权限：URL表与回调接线、实际AX两个按钮、应用恢复活动通知、未知/按需状态、DEBUG隔离检查；均无真实授权或助手连接。
- 私有API检查：`python3 script/check_private_api.py` PASS（7个allowlisted uses）。`git diff --check` PASS。
- **持久化与安装版读回仍未验收**：临时绝对路径 suite 的 CFPreferences synchronize 在本沙箱被拒；新重开同suite测试也保留断言并失败，不能据此宣称重启保留已验证。主会话必须沙箱外复跑并做真实小窗颜色/重启读回。

最终构建与复跑的具体计数在文末“最终读回”追加；上一轮失败总数不作为最终产品失败数。

## 主会话验证与提交

定向清单在 scratch `targeted-classes.txt`（包含公共提示要求的三个B2类、UIConsistency、TestPreferenceHygiene及本批新类；SystemUtilitySafety只列相关方法，不启动全类）。

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
B6_SCRATCH="$HOME/Developer/.sc-build/r2-lf2-b6"
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$B6_SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(paste -sd '|' "$B6_SCRATCH/targeted-classes.txt")
swift test "${F[@]}" --skip-build --filter "$FILTER"
```

受阻方法完整名单在 `sandbox-blocked-tests.txt`；必须在沙箱外重跑，不移动家目录夹具到tmp、不放宽unsafePath、不跳过或删assert。之后主会话执行项目 `script/verify.sh`：`STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=<私有scratch>`；全量门禁属于主会话。

反证按 `counterexamples.json` 的20条定义，一次一个在验证副本替换before→after、构建并运行filter，应红；恢复原文件/hash后构建filter应绿。此会话按 codex-build-common **不运行变异反证**，只逐条检查before occurrence；`counterexample-anchors.json` 不代表变异已红。覆盖间隔/inset/标题/底部24pt间隔、显隐/排序、颜色identity/指标注入、D73入口、hit testing、正确URL、可见性策略及禁止refresh请求授权。不要把原版依旧受沙箱限制的持久化方法选作红证明。

补丁顺序：01纯拆分→02光场/共享预览/权限/旧守卫→03新契约与交接。01的中间文件与最终不同是预期，01/02可以包含同一路径，必须按顺序应用；`all.patch` 是基线到最终的一次性补丁。`manifest.json`记录基线、最终hash、组间状态hash和顺序；`commit-prepared.py`默认只读验证，主会话完成上述验证后才用`--validated`分组暂存提交，不push。

提交footer采用任务提示指定的`Generated-By: Codex (gpt-6.1-sol)`与Claude co-author；这是请求的元数据标识。本会话工具没有暴露可核实的当前模型名，没有调用模型切换或降低推理设置。

## 主会话重拍清单

- 七类：general、miniwindow、scan、access、system、updates、about，各自日/夜。常用设置窗口尺寸1180×760、1000×700、820×560、677×390；最小560×390补看。完整七尺寸矩阵另含1280×763、1680×1050、2400×1350、1280×390。
- 权限额外拍`access-pending`日/夜（DEBUG pending），granted/unknown及正常实际读取状态；返回系统设置后自动刷新、每条“前往授权”落到正确pane。不点授权、不读钥匙串。pending是演示结果，不是当前设备的授权判定。
- general：接口折叠/展开、11/10/6色板、custom日夜/图表/背景、18指标展开；与真实一级面板并排核对同304 pt/同模块高度、即时变色、重启读回。真实菜单栏颜色也单独核对。
- miniwindow：六卡全开605、MacBook关闭535、全隐藏64、电池移首、隐藏磁盘、取消/应用、拖动与上下移、离页/关闭草稿确认；完整659组件在右列或窄窗滚动可达，没有缩放/模块省略；传感器标题含“风扇控制 · 模式 ›”，设置预览不可触发控制。
- scan：长路径中间省略及全文help、排除项移除/清空确认、维护提醒/通知、操作记录入口。
- system：真实助手未注册/等待批准/已批准但未连接/可信连接、硬件只读门禁、四模式名称、最大确认、停用恢复。此批不执行真实模式切换；必要实机操作另按用户授权。
- updates：来源开关/全部关闭提示、独立更新开关与Sparkle检查动作边界；about：品牌76、版本/构建/安装授权信息展开、诊断复制、支持包预览。
- 沿用 DEBUG `--capture-settings-window`入口；窗口尺寸由主会话设定。几何测试验证共用shell及真实预览卡片，**没有**替代七类完整内容在安装版上的逐页截图对比（B8位置误差≤2pt与C-UI2仍待主会话）。一期验收12/13需在上述实机颜色/重启与授权状态验证后关闭。

JEV决策/结果复核尝试被自动审批拒绝：`MCP tool call requires approval, but approval policy is never`，工具未返回判断，不能宣称JEV通过。

## 最终读回（2026-10-10）

- `final-build-readback.log`：`swift build --build-tests` PASS，84.73秒；随后没有再改 production/test 源码，仅补交接和交付元数据。
- `final-recheck-tests.log`：231项、4条assert失败，落在3个CFPreferences持久化方法；0 unexpected。新几何/AX/权限/完整预览即时读回及旧视觉守卫均已通过。
- 与首次393项运行按方法取最新结果：**393项，381 PASS，12 ENVIRONMENT BLOCKED**；9个家目录夹具 NSPOSIXErrorDomain Code1 / NSCocoaErrorDomain513，3个临时suite落盘被CFPreferences sandbox_extension_issue_file拒绝。完整名单 `sandbox-blocked-tests.txt`，结果 `test-results.json`，没有跳过方法或把阻断计为PASS。
- 新增19项方法18 PASS、1持久化受阻；另3项split-source契约全部PASS。七类共用shell在8尺寸×日夜原生几何通过，64种组合×日夜预览几何及实际窗口size resolver（非空）一致。
- 20条变异锚点 occurrence检查 PASS；变异运行/全量verify/安装版截图/真实偏好重启验证 **NOT RUN**，按公共任务划分交主会话。

第一组新增文件的Git扩展diff曾缺`new file mode 100644`元数据；封装时补齐，hunk逐字不变，原序列化备份在`phase1-prepared/01-settings-split.original.patch`，校验证据`phase1-patch-format-check.json`。三组均在无git仓库的基线文件副本按顺序apply及hash读回通过；没有初始化git或写真实index。

最后边界修复新增一个权限刷新gate测试：并发返回事件合并成一次后续读取，先前读取结束后仍能取到新授权状态。构建/测试读回将在下一段记录；原393项的结果保持为历史证据，不重复执行已通过的无关测试。

最终边界修复读回：`access-followup-build.log`构建PASS（66.64秒），`access-followup-tests.log`79项、3条assert失败在原2个CFPreferences持久化方法、0 unexpected；新增gate、实际返回通知、权限AX、共用几何、源拆分及UIConsistency均PASS。按方法最新结果汇总为 **394项，382 PASS，12 ENVIRONMENT BLOCKED**；视觉新测试20项中19 PASS、1持久化受阻。没有重跑未受影响且已通过的B2组件/完整64组合测试，其既有证据继续有效。20条反证定义仅完成静态锚点检查，运行仍由主会话负责。


## fix1（2026-10-10，基线 HEAD + r1 三组）

主会话 `logs/main-final-1350/full.log` 已验证 r1 定向 394/0、原反证 20/20；全量 4502 项中三方法产生八条失败断言。当前 HEAD 仍为 `b3bacd0ccf157a4e30dbafa6a1ec0582694dc998`，r1 三组未提交，37 个交付文件 SHA-256 全部与原 manifest 一致。先保存 r1 内容快照到 scratch `fix1-base/`；本次只对六文件做增量修改，保留原 prepared 三组及其所有校验和。

### 窄布局与真实尺寸

选择“预览区横向滚动”：宽 280 pt 的视口无法包含 304 pt 面板，横向滚动允许访问面板右端并保留原尺寸。窄布局（内容宽 <760 pt）将设置项及其下方的完整预览放在纵向滚动主体，预览单独横向滚动；操作区固定在主体下方，并沿用原 `ViewThatFits` 在窄宽下纵排按钮。纵向滚动用于访问所有设置项和完整面板底部，横向滚动只作用于预览。面板没有 scale、裁切 modifier、固定压缩高度或模块删减；全开面板仍为 **304×605 pt**，连说明与模拟菜单栏读数的完整组件为 **304×659 pt**。宽布局仍为左右栏，操作区位置保持原实现。

增加 B2 `lightfieldComponentProbe` 观测滚动视口、自然内容、末尾设置开关及三个操作按钮；探针在 Release 中无 GeometryReader。原恢复默认、取消、应用语义没有变动。新 AX 用例按下真实恢复默认/取消按钮，验证临时绑定值改变；应用只验证公开 AX 动作存在，不调用共享配置写入。

### 旧断言逐条迁移依据

| 原断言 | fix1 | 依据 |
| --- | --- | --- |
| `preview.minX >= viewport.minX - 1` | `preview.minX >= scrollContent.minX - 1` | 用户要求原尺寸面板，边界参照应是可滚动文档；误差仍为 1 pt。 |
| `preview.maxX <= viewport.maxX + 1` | `preview.maxX <= scrollContent.maxX + 1` | 304 pt 内容不能被要求压入 280 pt 可视区；另测原宽304、panel实际高度及完整预览位于内容区。误差仍为 1 pt。 |
| `actions.minY >= viewport.minY` | 原样保留 | 操作始终在可视区。 |
| `actions.maxY <= viewport.maxY + 1` | 原样保留 | 操作始终在可视区，阈值没有放宽。 |
| 两个 SystemMonitor 方法各自的 `ForEach(geekVisibleOverviewModules)` | 真实宿主 `GeekOverviewPanel(modules: geekVisibleOverviewModules)` + 共享文件 `ForEach(modules)` + `moduleContent(module)` + 原 `liveCard(...){ geekOverviewModule(module) }` | r1 把迭代搬入共享组合，必须证明生产宿主仍传真实模块、共享组合调用每个模块且连接真实卡片，不能只换一个弱字符串。 |

原文件中其余按钮可见性/互不重叠以及生产数据、分页路由、图表、单窗口会话断言均保留。新增动作横向边界、滚动主体在操作区上方、原宽/实际高度、纵向滚至面板底部、280 pt 时横向滚至右端及滚动后按钮原位检查；最后的 MacBook 示例开关能通过真实 NSScrollView 滚入主体可见区。新增三个实际操作按钮逐一处于视口、互不相交、提供原生 AX 按压动作的检查。

### 生产路径审计

`MenuBarStatusController.panelSession` 仍复用一个 `MenuBarPanelSession`，原 session-count、live-store、telemetry 及各页路由断言通过。`MenuBarGeekPanel.geekCanvas` 将 `geekVisibleOverviewModules` 传给共享组合，每项经 `liveCard` 调用 `geekOverviewModule`；真实读取仍来自原 store/history/hardware 路径。共享 `GeekOverviewPanel` 只组合传入内容，无 sampler/window/session；设置预览只实例化不可交互演示卡片，不创建 `ScanStore` 或 `MenuBarPanelSession`。本次没有修改生产数据/会话代码，并增加对应守卫，防止以后演示数据污染生产路径。

### 红、绿、反证及限制

- `logs/fix1-red.log`：修复前沙箱精确复现三方法/八条断言失败（预览宽一条、按钮高度五条、旧 ForEach 两条）。
- `logs/fix1-final-build.log`：沙箱 `swift build --build-tests` PASS，40.17 秒。之后没有修改 production/test 源码。
- `logs/fix1-targeted.log`：按 `prepared/fix1/targeted-classes.txt` 跑 111 项，**103 PASS、8 ENVIRONMENT BLOCKED**。其中三原失败方法及新增窄窗按钮 AX/几何方法通过；UIConsistency、B2 Component/ReleaseIsolation 和可运行 Hygiene 守卫通过。
- 六个 B2 Contract 方法因家目录 `~/.storage-cleaner-scan-store-…/home` 写入失败（NSCocoaErrorDomain 513 / NSPOSIXErrorDomain 1），两个 Hygiene 方法因 CFPreferences `sandbox_extension_issue_file` Code1 拒绝临时 suite 落盘而失败。名单 `prepared/fix1/sandbox-blocked-tests.txt`；保持原路径与断言，没有跳过或计为 PASS。
- `logs/fix1-final-recheck.log`：本轮四个关键方法 **4/0**，2.384 秒；结果明细在 `prepared/fix1/test-results.json`。
- `script/check_private_api.py` PASS（7 项既有 allowlist），`git diff --check` PASS。
- scratch 根 `counterexamples.json` 与 fix1 副本含 **26 条**：原 20 条 JSON 逐项完全相同，before 锚点次数仍分别精确匹配；新增6条为横向滚动、操作按钮越界、预览内容宽缩小、生产模块清空、真实卡片替换为演示卡片、共享顺序反转。`counterexample-anchors.json` 记录26条精确命中。**未在沙箱执行变异或全量测试**，依据 codex-build-common 由主会话执行；r1 的20/20只能作为主会话上一轮证据，不能计为fix1已执行26/26。
- JEV 方案判断和最终复核调用均被自动审批拒绝：`MCP tool call requires approval, but approval policy is never`；没有返回判断，未宣称 JEV 通过。

### prepared/fix1 交付与主会话复跑

三个增量组按顺序：`01-narrow-preview-scroll.patch`（布局与几何/AX），`02-live-overview-contracts.patch`（两个源码契约），`03-fix1-handoff.patch`（本节）。`all.patch` 的前态是 HEAD+r1 三组，不能直接应用在裸 b3bacd0c；基线说明、六文件前/后 SHA-256、原 r1 组 hash、应用验证都在 `manifest.json`。原 r1 prepared 仍保留原 hash。

`commit-prepared.py` 默认只读验证；主会话完成外部验证后才用 `--validated`。若本 worktree 仍是 b3bacd0c+r1+fix1 的未提交状态，脚本先从原 r1 三组补丁向 index 按组提交，再从 fix1 三组补丁提交（最终工作文件已包含 fix1，因此不调用会要求 r1 旧工作文件 hash 的原 r1 commit helper）。若 HEAD 已提交完整 r1，则核对 r1 的文件内容并只提交 fix1。任何 hash、index、分支或修改范围漂移都停止，不清空既有修改、不 push。

主会话用公共 SwiftPM 参数及 `prepared/fix1/targeted-classes.txt` 重新运行定向，复跑八个环境受阻方法；随后按 scratch 根 `counterexamples.json` 做26条反证与全量 verify。运行之前保持 working files 与fix1 manifest一致；通过后才执行提交 helper。

需要重拍的新增重点是 **general/miniwindow × day/night**：常用 820×560、1000×700、1180×760、1280×763；短窗 677×390、1280×390；大窗1680×1050、2400×1350。窄视口/容器 280×500 与449×362另拍设置项、完整预览底部及右端、固定操作区，确认滚动时按钮不移动、无重叠，面板304×实际高度并保留D73风扇入口。r1 七类设置×日夜×常用尺寸矩阵及 access-pending 真实安装版截图需求仍按上一节执行；此修复不代替安装版重拍或真实偏好重启读回。

未解决的产品失败：本轮定向未发现。等待主会话验证项：八个环境阻断方法、26条实际反证、全量 verify、安装版截图；本会话没有写git index/提交/安装/硬件/授权。
