# r2-power-fan-restore · D73 交接

- 日期：2026-10-10（Australia/Sydney）。基线 `0ca11ff5b9ddc7e87d50b4c652685cb5c0092b7c`，分支 `task/r2-power-fan-restore`。
- 已读 `_prompts/common.md`、`codex-build-common.md`、RULES，以及 D73 → D59 → D64/D67/D69，另核对 D5/D48/D55/D60。BOARD 中没有本批条目，未自行改协调看板。
- 四张任务卡参考 PNG 均已用图像工具打开。git 查证 `b8f650e8` / `23c99d68` 的充电界面改动与 `aafdcd06` 的界面精简提交存在。
- 本轮未安装、启动已安装应用、写风扇、修改实际充电、电源配置、调用 pmset/sudo、改 ScanStore、改 FanControlHelper/FanControlShared 协议或安全检查、改 SettingsView 或 Mac mini 控件。`.git` 为只读，交付 prepared 补丁，不声称已提交或合并。

## 最终实现

### 充电上限

`GeekChargeTargetSetting` 改回原生分段控件，标签只有百分比。选项只取当前 `BatteryChargeLimitState.availableTargets`，没有硬编码生产档位；超过五档使用一行可横向滚动的分段，不截掉后面的档位。

分段 Binding 的 getter 直接调用 `BatteryChargeLimitPresentation.selectedSegment`，按 `effectiveLimit` 精确匹配。既不读存储目标作为高亮，也不把发送中的目标当已生效；未知或不在原生选项中的有效值不高亮任何段。不再维护视图内的 `selectedTarget`。原生 NSSegmentedControl 测试实测 80%、100%、nil、83% 四种回读，并发送假写入后验证仍按原回读高亮。

分段下保留“本次充到 100%”及原来的临时状态与中文失败提示；“打开电池设置”移到其后，作为次要链接。移除“手动上限”下拉、“100%（不设手动上限）”和常显“不限”摘要。`sourceCaption` 仅在非纯手动来源显示一行短说明；手动＋优化仍显示优化来源。完整安全解释函数继续保留供诊断及原行为测试使用。

`BatteryFullChargeService`、ObjC NSError ABI、过渡确认、手动＋优化两步处理、读取缓存与节流均没有修改；卡片仍用同一 `energyModeCardTitle` 和实际值，演示充电控件依然禁用。

### 风扇入口与模式

在概览显示转速的位置，以及传感器二级页的风扇读数下增加“风扇控制”行，右侧为回读模式（系统自动／手动 65%／自定义曲线）或明确的辅助程序状态，再加展开箭头。不是风扇硬件时仅显示“无风扇 · 被动散热”，不提供控制行。

该行复用 `ControlPaletteAnchorButton(kind: .fan)` 的真实 Button，点击/AXPress → `ControlPaletteCoordinator.toggle` → 现有 `present(.fan)` 路由，浮层固定住供交互；原 RPM 悬停入口及单风扇索引保留。概览初始高度增加恰好 24 pt，二级风扇卡按是否有入口行计高，避免底部裁切。

小窗的呈现选择与设置中的写入能力列表区分：小窗始终显示自动／曲线／手动三项，`FanControlPaletteAvailability` 决定禁用原因，卡片、选择回调和手动滑杆均接同一门控；设置使用的 `GeekFanControlAvailability.availableModes` 保持原样。未注册／待批准／连接中断／未受信任／不可用时卡片不消失，理由可见且进入 AX hint。现有 helper 操作分别复用 `registerHelper`、`openApprovalSettings`、`refreshConnection`；风扇浮层文案为“启用风扇控制”“在系统设置中批准”“重新检测”，电源浮层的现有 helper 文案不变。

选择手动只改草稿，立即显示原来的转速滑杆和“应用”；已回读手动模式再次打开或重选也始终显示“应用”，未修改前禁用，不显示假的“待应用”。选择曲线可进入原编辑器。实际写入仍由“应用”及现有提交/回读/热保护/信任检查决定。演示允许本地风扇草稿预览，提交与授权操作仍被只读 fixture 拒绝。

无调用方的 `GeekFanControlCard` / `GeekPowerModeControlCard` 及其布局/徽章/直接写入实现已删除；原文件现在只承载共用入口呈现与小窗可用性，不保留第二套控制 UI。

## 演示场景与截图参数

必须加 `--debug-mini-window-demo-data`。下面的百分比和量程是明确的模拟数据，不构成本机能力声明。

充电场景新增参数 `--debug-charge-limit-state=<值>`，默认 `manual80`：

| 值 | 预期 |
|---|---|
| `manual80` | 手动有效 80%，80% 高亮，无来源小字 |
| `optimized80` | 手动目标 100%，实际 80%，80% 高亮，优化来源小字 |
| `temporaryFullCharge` | 手动目标 80%，临时实际 100%，100% 高亮，临时状态替代满充按钮 |
| `unsupported` | 无可选段，显示不支持信息及次要设置链接 |
| `manySegments` | 模拟七档 70/75/80/85/90/95/100，实际 85%，一行横向可滚动 |

这些数据同时接入二级电源摘要、真实 power palette 演示分支和 `menu.power.modeAndChargeTarget` 离屏三级内容。

风扇场景参数沿用 `--debug-hardware-control-state=<值>`：

| 值 | 入口/浮层预期 |
|---|---|
| `fanAutomatic` | 系统自动，三种草稿模式可预览 |
| `fanManual65` | 手动 65%，原滑杆与读数，“应用”可见且未修改前禁用 |
| `curveActive` | 自定义曲线，编辑入口 |
| `awaitingSystemApproval` | 等待系统批准，三项禁用，“在系统设置中批准” |
| `connectionInterrupted` | 连接中断，三项禁用，“重新检测” |
| `fanless` | 无风扇 · 被动散热，无控制入口或模式 |
| `helperNotRegistered` | 辅助程序未启用，三项禁用，“启用风扇控制” |
| `helperUntrusted`（新增） | 辅助程序未受信任，三项禁用，“重新检测” |
| `helperUnavailable`（新增） | 辅助程序不可用，三项禁用，“启用风扇控制” |

主会话使用现有离屏管线：`menu.overview.baseDark`、`menu.sensors.secondary`、`menu.fan.control.full`、`menu.fan.control.compact`、`menu.power.modeAndChargeTarget`；输出目录参数为 `--capture-menu-bar-panel-directory=<独立输出目录>`、场景为 `--capture-menu-bar-panel-scenario=<场景>`。检查明/暗色、所有 helper 状态、七档不裁切，以及概览新增行后的卡片锚点/窗口大小。本轮未运行应用截图/录屏，不声称实机视觉验收通过。

## 旧断言改写依据（不删断言、不放宽阈值）

1. `BatteryChargeLimitPresentationTests.testManual100MeansNoManualLimitAndOtherTargetsKeepTheirNumbers`：两种语言的 100% 标签改为精确 `100%`；D73 明确删除括号说明，底层 100% 关闭手动限制语义未变。
2. 同类 `testUIUsesSharedSummaryAndPickerNeverRequestsTemporaryFullCharge`、`testUnsupportedManualLimitReplacesOnlyPickerAndKeepsOtherControls`、`testPendingRequestKeepsExplanationAndOnlyDisablesActionWithoutAddingHeight`、`testDemoFixturesDisableControlsAndFailureKeepsSeparateSummaryLine`：下拉/常显 summary/长解释锚点改为分段组件、独立来源短说明/临时状态；保留不调用临时满充、按钮状态、失败分行、演示禁用、过渡回读与清除旧成功提示的断言。更新保护回调锚点为 `availableTargets.contains(target)`；新增真实原生分段点击测试与纯映射断言。
3. `GeekSensorsPowerHoverDetailTests.testCapturedReferencePopoverSizesRemainExplicit`：删除的死卡片尺寸断言对应改为实际入口 24 pt 和两张旧类型确实不存在；其他所有 popover 尺寸精确断言保留。D73 要求不保留第二套死控制 UI。
4. 同类 `testFanModeUsesSingleChoiceControlsWithoutFakeManualAccess`：退休卡片的 `monitoringTitle` 调用改为真实 `ControlPaletteAnchorButton(kind: .fan)`；标题/能力详情四条检查移到 `paletteContent`，并补查 fanless 分流与 body 确实使用该内容，避免误锁包装 body。
5. 同类 `testSensorAndPowerCardsExposeContextualHoverDetailsWithoutNewSamplingInfrastructure`：死卡片的前两条风扇读数循环与电池能力检查改锁实际传感器读数循环、真实 power palette 的电池能力传参及能源组能力分支；不降低数量/尺寸阈值。
6. `HardwareControlPresentationTests.testAllRequiredDemoStatesResolveToConsistentProfiles`：严格数量 23 → 25，对应 D73 新增未受信任/不可用两个场景，同时增加两种 helper 状态与未知模式断言；原 23 场景及全部原行为断言保留。
7. `GeekPowerViewTests.testBatterylessOverviewRemovesExactlyThePowerCardFootprint`：完整概览精确 605 → 629，正好增加 24 pt 入口行；无电池删除电源卡及间距的精确关系不变。
8. `PanelChartNormalizationTests.testMiniWindowUsesOneEqualOuterInsetAndOneSmallerCardGap`：总高求和的传感器项加入口行 24 pt，仍精确验证外边距/间距/各卡高度，不改容差。
9. `ControlPaletteTests.testPowerPaletteFitsMeasuredNaturalHeightInBothLanguages`：只新增七段案例，原有浅/深色、中英、自然高度与窗口等宽/不裁切断言完全保留。

## 验证与环境限制

完整命令及统计由 scratch `validation-results.json`、`logs/` 记录，最终实际结果见文末。本轮用 Xcode 27 Beta 和专属 scratch，构建 flags 与 codex-build-common 一致。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-power-fan-restore/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
filter=$(paste -sd '|' ~/Developer/.sc-build/r2-power-fan-restore/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$filter"
python3 script/check_private_api.py
git diff --check
```

定向清单含 TestPreferenceHygieneTests、UIConsistencyRegressionTests，未删/跳过任何原测试。原生 Button/AX/分段测试使用临时偏好和只读 fixture，不创建真实硬件传输。

中断审计：用户告知 Claude 进程重启，中断日志 `targeted.log` 无完整摘要，旧工具句柄失效；不作为完整测试结果。源码完整、diff 无空白错误、最终编译日志完整。`ps` 被沙箱拒绝，无法独立枚举残留进程；恢复后的测试成功启动并正常结束，没有 SwiftPM 锁阻塞，保留 scratch 正常构建缓存供主会话续用。

沙箱限制有直接证据：`logs/panel-probe.log` 中普通 NSPanel 可设置 frame，但 `NSScreen.screens.count == 0` / `NSScreen.main == nil`，现有 `ControlPaletteCoordinator.reposition` 在 ScreenContextResolver 无结果时退出，所以依赖定位的窗口仍是零 frame。未改该无关生产定位器，也未注入假屏幕以让测试变绿。三项依赖 `~/.storage-cleaner-*` 操作 home 的方法报 `Operation not permitted`；偏好卫生两项方法出现临时 plist sandbox extension 失败及回读失败。全部交主会话沙箱外复跑。另外 `ControlPaletteTests.testLongFanNamesUseShortCompactButtonsAndFullMenuNames` 报 `InvalidTransition idle → failed(deinit)`，本轮保留为待主会话复查，未把它无依据归为通过。

JEV：实际调用 `jev_decide`，适配器无模型/推理参数；自动审批返回 `MCP tool call requires approval, but approval policy is never`，未取得模型标识、provider 结果或判断。未声称完成 JEV 评审，未绕过或换模型。

## 红 / 绿 / 反证

- 绿：纯映射、来源、临时状态、全部 helper 状态入口/三种模式、真实 AXPress 呈现、手动滑杆/应用、曲线编辑、原生分段发送与回读一致性，以及原有 D59 服务/ABI/节流安全测试。
- 红：主会话如需原树复现，保持新增行为测试，在独立临时副本恢复目标实现后跑对应 filter；缺失新类型导致编译失败不算红证。
- 反证文件为 `~/Developer/.sc-build/r2-power-fan-restore/counterexamples.json`，格式 `{mutations:[{id,path,before,after,expected_occurrences,filter}]}`，11 项所有 before 均在最终源码精确命中一次。测试分别检查错误手动目标高亮、手动来源小字、临时状态丢失、helper 故障隐藏入口、写模式隐藏、helper 未信任仍可选、入口错开电源页、批准按钮文案错误、手动滑杆丢失、已回读手动模式的“应用”消失、曲线编辑不开。
- 本轮按照共用构建指令不在沙箱跑反证/全量。主会话逐项在独立副本应用 mutation，构建必须成功，随后由指定行为断言/真实控件断言变红；不允许把编译失败、源码字符串断言、脚本错误算红。恢复后同一 filter 必须绿。

## prepared 交付

`~/Developer/.sc-build/r2-power-fan-restore/prepared/`：四组 patch/message、all.patch、manifest.json、static-checks.json、generate-prepared.py、commit-prepared.py、README.md。分组为充电呈现 → 风扇入口/门控/共用演示数据与测试 → 演示路由与七档布局 → 交接。manifest 固定基线/分支/最终文件 SHA-256/分组顺序和产物 SHA-256。

`commit-prepared.py --check-only` 只读核对；`--validated --check-only` 同样不写 git。主会话完成剩余沙箱外验证和独立复核后，才运行 `commit-prepared.py --validated`；该脚本不构建、安装、推送、合并，不把参数当测试证据。


## 本轮最终结果（2026-10-10）

| 项目 | 实际状态与证据 |
|---|---|
| 最终 Debug 构建全部测试目标 | **PASS**，exit 0，27.04 秒，`logs/build-final-manual.log`；新并发/未使用变量警告已修，仅 SwiftPM skip-update 和沙箱缓存访问环境警告 |
| 中断前核心行为 | **PASS**，28 项 / 0 失败，`logs/focus.log` |
| 中断后原生充电分段新增行为 | **PASS**，1 项 / 0 失败，`logs/resume-focus.log`；同次旧几何探测失败使该进程 exit 1，不把整次调用标绿 |
| 完整定向尝试 | **FAIL**，exit 1，415 项、203 个断言失败（8 unexpected），`logs/targeted-resumed.log` |
| D73 旧契约修正复跑 | **PASS**，exit 0，43 项 / 0 失败，`logs/targeted-contracts-fixed.log`（GeekSensorsPowerHoverDetailTests + HardwareControlPresentationTests） |
| 当前逐方法证据汇总 | 415 方法中 393 已通过、22 仍未通过、0 skip；这是按最新方法结果汇总，不代表完整清单一次性绿 |
| 新增纯行为 + 全部原生风扇/分段行为 | **PASS**，末次 `logs/final-manual-tests.log` 共 59 项 / 0 失败，exit 0：PowerFanRestoreTests 5/0，FanControlModeCardTests 8/0，UIConsistencyRegressionTests 46/0；包含六种及扩展 helper 场景、AXPress、手动滑杆/应用（含已回读手动 65%）、曲线编辑、原生分段 |
| D59 原安全类 | **PASS**，Service 32/0、ObjCCall 3/0、ReadCache 8/0、Presentation 16/0；未改服务/缓存/ABI |
| UIConsistencyRegressionTests | **PASS**，46/0；TestPreferenceHygieneTests **BLOCKED**，21 项中 2 方法 / 3 断言受偏好落盘限制 |
| 源码/私有 API | **PASS**，diff check exit 0，私有 API 守卫 exit 0，7 个既有 allowlist 用法 |
| 11 条反证 | 所有最终 before 锚点精确匹配一次；**NOT RUN**，主会话按规则执行行为反证 |
| 真实截图、安装、硬件写入、提交、合并 | **NOT RUN**；只交最终 worktree 与 prepared，未声称完成上述阶段 |

22 个未通过方法均完整列入 `validation-results.json`：16 项屏幕/定位相关、3 项操作 home 权限、2 项偏好回读、1 项 InvalidTransition 待复查。原断言/预算/产品路径与助手安全规则未放宽。

prepared 的 `commit-prepared.py --validated --check-only` / `--check-only` 均已通过，exit 0，`logs/prepared-checks.log`；只做产物可提交性核对、未写 git。主会话仍需补齐沙箱外门禁、11 项行为反证及离屏视觉验收后再提交合并。


## fix1 · 主会话复核修复（2026-10-10）

### 基线与主会话证据

fix1 的基线是当前 HEAD `0ca11ff5b9ddc7e87d50b4c652685cb5c0092b7c` 加上一轮 prepared 四组。开始前逐文件核对上一轮 manifest SHA-256，18 个文件完全一致，保留原改动与原 prepared；原树冻结在 scratch `fix1-base/`。本节只追加，不改上一轮验证记录。

全文读了 `followup-notes.md`，打开 r1 概览、手动风扇浮层及充电上限 PNG。核对 `logs/main-final-0829/`：11/11 行为反证全红；定向 415 项 / 28 断言失败；全量 4474 项 / 33 断言失败 / 25 skip，集中于任务卡七个方法。旧沙箱里的屏幕/家目录限制不能代替这轮真实高度失败，已修布局。

### A1 / B2：四模式与原高度预算

- 新增“最大转速”，小窗卡片、入口右侧、已确认模式胶囊、设置请求模式及确认按钮统一读取 `GeekFanControlMode.maximum.title`。设置确认对话框、注册、批准、重试和应用流程原样保留，仅统一最大转速名称。
- 最大转速选择只改 `FanControlDraft`，由原“应用”调用现有 `selectMode(.maximum)`；fixture、helper 信任、量程、热保护、提交和回读门控保留，没有修改 helper 或协议安全检查。最大转速当前回读不再映射为手动卡片。
- 自动与最大转速并排，自定义曲线/手动保留整行宽度。36 pt 点击卡、16 pt 单选标记和键盘/VoiceOver 操作保留；窄卡名称保持完整 AX 文案。
- 紧凑浮层不重复显示 CPU 风扇读数行；详细信息/展开读数仍可打开。实际 RPM → 草稿目标 RPM 与取消/应用合并一行；滑杆百分比、双风扇同步、目标风扇菜单、完整硬件名和曲线编辑器保留。只读安全提示在手动行简写“预览”，help/AX 保留完整禁止写入说明，避免重复长提示占高。
- 原 `ControlPaletteTests` 的 280 pt、276 pt、4 pt 余量断言与容差全部保留。新增不依赖屏幕定位/家目录的原生尺寸测试，测相同 280 pt 宽度与 8 pt 外边距。

最终原生测量（中英 × 浅深色，双风扇同步开/关均一致）：自动 **184 pt**（预算 230）；单风扇手动 **210 pt**（预算 280）；双风扇手动 **238 pt**（预算 276）。不是硬编码窗口高，而是 NSHostingView 的自然布局框。原生测试还验证三个草稿操作加最大转速选择不会发出真实写入。

### A2 / B1：卡内入口、总高恢复

“风扇控制 · 模式 ›”行移入 `GeekSensorsPresentation` 的同一 `GeekCombinedCard` 底部，使用同一内边距与卡片表面。概览不再在传感器/电池之间单独加行。三个圆环在带入口时用 52 pt，保留各自温度/RPM/频率信息与点击反馈，卡片自然测量仍为 **108 pt**。

原概览总高恢复 **605 / 535 pt**（有/无电池）。`MenuBarPanelPlacementTests.testPracticalOverviewGroupsFitTheFixedPanelWithoutScrolling` 通过，未改该断言或固定面板滚动条件。新增原生几何断言在 248/280/304/312/320/360/400 七个宽度和中英两种语言下，验证入口位于卡内、24 pt 点击高度和左右同内边距；二级风扇入口与原 RPM 悬停入口保留。

### B3 / B4 / B5：状态与演示

- helper 不可用时，右上状态胶囊显示“等待批准 / 未连接 / 未启用 / 未受信任”；增加明确 AX 标签，实际 AX 树断言检查短文案存在。四项卡片仍可见、不可用时禁用且有原因，原启用/批准/重试按钮可达。
- 演示差异源于基线 D71 的 `MenuBarSamplingContext.presentationSnapshot` 对固定演示日期进行实时过期过滤，概览/二级丢失硬件读数，而浮层直接用了演示快照。本批只在展示端把 demo 替换为同一固定快照，**未改生产采样/过期/缓存逻辑**。
- 同时修了 fixture 里的硬编码 `1,620 rpm` 指标和历史末点。当前指标、概览圆环、二级读数、浮层及历史当前点都取同一硬件场景；手动 65% 为 3,020 rpm，自动为 1,620 rpm，最大为 4,000 rpm，CPU/GPU 为 53/49°C。历史变化仍保留，限制在场景硬件范围内；无风扇没有伪造 RPM。
- 原生安全夹具检查了可写/只读 × 明暗四种分段控件：实际 80% 选中，可写控件启用，演示控件禁用。`shots/fix1-native/charge-*.png` 已打开核对：可写态选中背景与未选标签可辨，演示变暗来自原生禁用样式。**没有改生产样式，也没有真实写充电**；这些是控件夹具截图，实际小窗重拍仍由主会话执行。

### 断言迁移依据（逐条，原断言不删、阈值不放宽）

1. `BetaDistributionTests.testUnifiedRunScriptOwnsStableSignedBetaInstallFlow` 两个退休卡片锚点迁移到 `ControlPaletteViews.swift` 的 `if telemetry.hasVerifiedRanges` 与 `Button { presentation.showFanCurveEditor() } label:`，分别覆盖真实滑杆能力门控与曲线编辑动作；补检查真实“编辑曲线”文字。Beta 构建、签名、安装、启动路径等其他断言原样保留。
2. `MenuBarDeclutterContractTests.testAlwaysVisibleMeasurementCopyIsGoneAndDeepSourcesRemain` 的 AX hint 锚点改为当前禁用原因优先、可用时仍读 `choice.subtitle` 的实现。保留禁止常显副标题/伪 subtitle 的断言。
3. `FanControlModeCardTests` 原三模式精确数组改为四模式、最大转速从 nil 改为对应模式，并补单一名称与 hint 断言；原 fanSet 不提供、图标/单选标记/尺寸/AXPress 断言保留。该方法更名 `testPaletteOffersFourSingleChoiceModesWithIconTitleAndSubtitle`，依据 B2 四项要求。
4. `PowerFanRestoreTests` 的每种 helper 状态精确数组扩为四项，原禁用与原因断言全部保留；追加真实最大转速选择及胶囊文案行为。
5. `GeekPowerViewTests` 概览精确总高 629 → 605、`PanelChartNormalizationTests` 去掉额外 24 pt，依据 B1 把入口纳入原 108 pt 卡片，不降低面板预算或修改原固定面板测试。
6. `HardwareControlPresentationTests` 场景数量 25 → 26，唯一新增 `fanMaximum`，补回读模式和最大 RPM 断言；旧 25 场景保留。
7. `GeekSensorsPowerHoverDetailTests.testFanModeUsesSingleChoiceControlsWithoutFakeManualAccess` 最大转速的中英文精确预期改为“最大转速 / Maximum RPM”，依据 B2 全局统一，其他原断言保留。

### 编译、定向与待主会话复跑

- **PASS**：最终构建，exit 0，26.59 秒，`logs/fix1/build-final-data.log`；无源码警告，只有 SwiftPM 旧参数/沙箱缓存访问警告。
- 完整定向清单扩为 **24 类**（新增 BetaDistribution、MenuBarDeclutterContract、MenuBarPanelPlacement、MenuBarSamplingPlan，保留偏好卫生和 UIConsistency）。`targeted-final.log` 一次跑 **500 项 / 198 断言失败（8 unexpected）/ 0 skip**，exit 1；不能标绿。
- 最大转速旧名称契约修正后，`contract-final.log` **30 项 / 0 失败**，exit 0。
- 最后演示历史一致性修正后，`final-data.log` 跑 **43 项 / 1 失败**，exit 1；FanControlModeCard 11/0、PowerFanRestore 6/0、HardwareControlPresentation 13/0，MiniWindowDemoData 12 项通过，唯一失败是家目录 operation home 被拒。
- 最新逐方法汇总：**500 项中 477 通过、23 未通过、0 skip**，并非完整清单一次性全绿。未通过名称/原因均在 `validation-results-fix1.json`：7 项 operation home 权限、12 项屏幕/定位、2 项偏好落盘回读、1 项 process_command/ps 空读回、1 项 `InvalidTransition idle → failed(deinit)` 待外部复查。没有注入假屏幕、放宽路径、跳过测试或改安装进程校验来掩盖沙箱限制。
- 任务卡 A 的固定面板测试与两个源码契约均通过；四个原 ControlPalette 高度测试在沙箱内分别遇到 home/InvalidTransition，需主会话复跑。新增独立原生高度行为已按相同预算测量通过。
- 私有 API 守卫 **PASS**，7 个既有 allowlist 用法；diff check 必须通过。ScanStore、D59 服务/缓存、ControlPaletteCoordinator、MenuBarSamplingPlan、MacMiniModeControls、FanControlHelper/FanControlShared 完全未改。
- JEV 沿用本会话已记录的自动审批拒绝（approval policy = never），无 provider/model 判断，不声称完成模型复核。

主会话构建/定向命令沿用上节 F，filter 取更新后的 scratch `targeted-classes.txt`；再跑全量和以下反证。不在本沙箱执行全量或反证。

### 反证与重拍清单

`scratch/counterexamples.json` 现有 **20 项**：原 11 项对象与锚点原样保留，均精确命中一次；新增 9 项分别使入口移出卡片、概览增高、最大模式隐藏、最大选择误选手动、状态胶囊变破折号、取消/应用与读数拆成多行超预算、demo 丢失读数、指标硬编码、历史忽略模式。每项指定纯行为/AX/自然几何断言；必须先构建成功，再由行为断言红，恢复后同 filter 绿。上一轮 11/11 红是旧实现证据，fix1 全部 20 项由主会话重新执行，本轮只验证替换锚点与方法存在。

主会话重拍 **明暗两套**（全都加 `--debug-mini-window-demo-data`，方法沿用已有离屏管线）：

| 离屏场景 | 硬件/充电参数 | 核对 |
|---|---|---|
| `menu.overview.baseDark` | fanAutomatic、fanManual65、fanMaximum、fanless | 卡内入口、605/535 原总高、圆环温度/RPM 与模式一致 |
| `menu.sensors.secondary`（主会话复合管线名；代码枚举 `menu.sensor.secondary`） | fanAutomatic、fanManual65、fanMaximum、awaitingSystemApproval、fanless | 二级入口、当前 RPM、与概览/浮层一致 |
| `menu.fan.control.autoCompact` | fanAutomatic、fanManual65、dualFanManual、fanMaximum | 四项可见、手动滑杆/应用、原 280/276 高度预算 |
| `menu.fan.control.full` | fanManual65、dualFanManual、fanMaximum、curveActive | 展开读数/风扇选择/同步、曲线编辑、全局最大转速名称 |
| `menu.fan.control.full` 与 `menu.fan.control.autoCompact` | helperNotRegistered、awaitingSystemApproval、connectionInterrupted、helperUntrusted、helperUnavailable | 短状态胶囊、四卡禁用原因、启用/批准/重试 |
| `menu.power.modeAndChargeTarget` | manual80、optimized80、temporaryFullCharge、unsupported、manySegments | 分段回读、只读外观、来源/临时状态与七档不裁切 |

硬件参数统一 `--debug-hardware-control-state=<值>`，充电参数 `--debug-charge-limit-state=<值>`；新增硬件值为 `fanMaximum`。双风扇同步开/关和长风扇名需再跑原布局矩阵，启用 `STORAGE_CLEANER_LAYOUT_EVIDENCE` 输出对应紧凑/展开几何截图。

### prepared/fix1

本目录四组增量补丁基于 HEAD + 上一轮四组；manifest 写入虚拟基线 Git 树、最终树、父补丁 SHA-256、全部最终文件 SHA-256 和顺序。旧 prepared 根目录完整保留。新脚本在原 HEAD 上可先仅暂存并提交原四组再提交 fix1；若 HEAD 已是上一轮完整树，则只提交 fix1。只读 `--check-only` / `--validated --check-only` 用来核对产物，实际提交仍由主会话完成所有门禁后执行，不安装、合并或推送。

fix1 两种只读 prepared 检查均已 **PASS**，exit 0，记录于 `logs/fix1/prepared-checks.log`；基线、空暂存区、父补丁、增量逆向可应用性和 SHA-256 一致。本轮未写 git、未提交。

增量链复核 **PASS**：`check-patch-chain.py` 在一次性源码副本中按顺序应用原四组 + fix1 四组，25 个最终文件 SHA-256 全部一致，记录于 `logs/fix1/patch-chain.log`；未改原文件或 git 元数据。

## fix2 · 恢复概览圆环与标题行入口（2026-10-10）

### 基线与改动

本轮基线为 HEAD `0ca11ff5b9ddc7e87d50b4c652685cb5c0092b7c` + 原 prepared 四组 + fix1 四组，完整树 `14384c0683e08a8ed5246ec14fa1b357a7fba23c`。开始前核对 fix1 manifest 的 25 个最终文件，SHA-256 全部一致；冻结至 scratch `fix2-base/`，旧补丁不改写。已打开 r2 深色概览、r2 手动 65% 一级页、r1 概览参考，确认 fix1 的 `fanControlEntry == nil ? 72 : 52` 同时缩小了圆环与字体，导致频率省略号。

- `GeekSensorsPresentation` 三个圆环恢复固定 **72 pt**，使用原数字排版算法：CPU/GPU 数字 15 pt，标题/次行 10 pt，RPM 按原内框宽度适配。不引入一套更小字号。常规宽度保留原 16 pt 环间距；248 pt 最窄卡片只将间距收至 8 pt，圆环不压缩、不相交。
- 入口放在 `GeekModuleHeader` 的 trailing 区：**“传感器”同一行右侧、“风扇控制 · 当前模式 ›”**，次要文字色；复用 `FanControlEntryRow(isHeader: true)` 和原 `ControlPaletteAnchorButton(kind: .fan)`，整个标签仍是原生 Button，键盘与 VoiceOver 走既有路由。二级页继续使用 24 pt 整行入口。
- 标题入口高 20 pt，使用原卡片留白：`20 + 4 + 72 + 2×6 = 108 pt`。卡片 108 pt、含电池概览 **605 pt**、无电池 **535 pt**，均保留原预算与原断言。
- 英文标题入口的系统自动显示 `Automatic`，授权状态复用短胶囊文案，例如 `Awaiting Approval`；中文仍显示“系统自动／等待批准”等。VoiceOver `accessibilityValue` 保留完整模式或辅助程序原因。七宽度下另断言传感器标题保持原宽度、入口全句在原生缩放范围内可放下，避免以标题或入口截断换空间。
- **无风扇机型标题右侧不显示入口**。依据：没有可调风扇，标题按钮不应宣称能控制；原二级页“无风扇 · 被动散热”只读信息保留，圆环亦继续呈现无风扇状态。
- 双风扇英文圆环短标题用 `Fans`，完整辅助功能标题用 `Fans average`。原 `Fans avg` 在 72 pt 的内框会折成两行，挤占数值与次行；复用既有 `accessibilityTitle` 保留均值含义，中文“风扇均值”不变。
- `GeekCombinedRing` 三个字号计算属性仅从 private 改为模块内可读，以便测试核对原字号；计算和渲染算法未变。本轮不修改充电、安全服务、生产采样、设置行为、Mac mini 模式或辅助程序。

### 几何回归与旧断言迁移依据

新增 `GeekOverviewLabelLayoutTests.testSensorRingTextStaysCompleteAtOriginalDiameterAcrossSizeLanguageAndAppearance`：七宽度 `[248, 280, 304, 312, 320, 360, 400]` × 中英文 × 明暗 × 单/双/无风扇，共 **84 张卡片、252 个圆环**。断言实测直径 ≥72 pt 且等于 72 pt、环位于卡内、环之间不相交；测量完整标题、数值、次行的原生文字宽度 ≤ 圆环内径可用宽度，并检查完整字形在原有最小缩放范围内可放下。锁定原字号，完整期望字符串无省略号；实际生产圆环像素与独立的原尺寸、完整文字参考环按原 **0.95** 阈值比较，不能靠 AX 全文或宽外框蒙混。无风扇场景另断言标题入口不存在。

首次新字形测试在深色有转速风扇上失败：参考环没有进度而生产环有进度，中性色环弧进入灰度字形掩码。修正测试夹具，使参考与生产使用相同遥测进度与蓝色圆弧；未改阈值、未改变生产颜色，最终全部通过。该失败与纠正记录保留在日志，未删除。

旧 `FanControlModeCardTests.testOverviewEntryLivesInsideTheSensorCardWithoutIncreasingItsFootprint` 逐条迁移：

1. 卡片高度 108 pt 和入口位于卡内的断言原样保留，尺寸精度仍为 0.5 pt。
2. 原底部整行 `row.height == 24` 改为标题入口 `row.height == 20`，新增二级页 `FanControlEntryRow.height == 24`，分别锁定两种布局；依据本轮明确“标题同一行、圆环 72 pt、卡片总高不变”。不是放宽原高度预算。
3. 原整行左边缘等于卡片内边距，迁移为**标题行左边缘**等于同一内边距；原右边缘仍由入口对齐卡片内边距。新增入口位于标题行、中心同高、标题行与圆环至少 4 pt 间距。
4. 新增完整标题的原字号宽度与入口全句宽度约束；由手动 65% 扩展到九个有风扇的模式/辅助程序状态，共 126 个语言/宽度组合。
5. 原 AX 点击、完整状态、`present(.fan)`/一次呈现断言全部保留，增加标题布局与二级页布局两种变体，各覆盖九状态。未删断言、未跳过测试、未放宽几何或字形阈值。

### 沙箱内验证

- 编译 **PASS，exit 0**：最终测试参考修正后的 `logs/fix2/build-glyph-reference.log`，5.99 秒；最终生产源构建为 `logs/fix2/build-final.log`，14.16 秒。没有源码编译警告。
- 本轮八类定向执行 151 项：`logs/fix2/targeted.log`。当时有 28 条新字形比较断言失败和三个既有偏好断言失败；修正参考后只重跑受影响的 `GeekOverviewLabelLayoutTests`，`logs/fix2/geometry-final.log` **4 项 / 0 失败，exit 0**。
- 最新逐方法结果 **149 / 151 通过、2 方法未通过、0 skip**，是以上两次执行的最新证据汇总，不声称一次完整全绿。原生 `FanControlModeCardTests` 11/0，卡片位置/整句宽度与两入口 AX 路由均通过；`MenuBarPanelPlacementTests` 39/0，仍锁 605/535；`UIConsistencyRegressionTests` 46/0；其余通过类与结果见 scratch `validation-results-fix2.json`。
- 待沙箱外复跑的两个原有方法：`TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`（308/309 行）、`testTemporarySuiteCanBeReopenedOnAWorkerThread`（324 行）。日志有 sandbox preference plist `Operation not permitted`，偏好落盘/回读不可用；不迁移夹具、不放宽路径、不修改断言。
- 手动浮层原生预算复核仍通过：自动 184 pt，单风扇手动 210 pt，双风扇手动 238 pt，原 280/276 pt 阈值不变。
- `script/check_private_api.py` **PASS**，7 个已有 allowlisted uses，`logs/fix2/private-api.log`。`git diff --check` PASS。
- `shots/fix2-native/` 有 12 张仅视图夹具图片；已打开中文深色手动及英文浅色双风扇核对：频率全文、72 pt 圆环与标题入口可辨。不是安装或真机验收。
- 原完整 `targeted-classes.txt` 保留 24 类；本轮执行子集在 `targeted-classes-fix2.txt`，包含两个必跑守卫。未重跑已验证的充电服务、协议及无关设置测试；全量和 mutation 执行仍由主会话完成。
- JEV 沿用本会话既有实际调用的自动审批拒绝：`MCP tool call requires approval, but approval policy is never`，没有获得模型判断。

### 反证与主会话命令

scratch `counterexamples.json` 更新到 **24 项**，prepared/fix2 内有副本。原 11 项对象完全不变、仍各命中一次；fix1 九项 ID 保留，其中 `overview-entry-leaves-card` 按 fix2 将锚点迁移到新卡片完整 body，变异把入口从标题移回底部，由原卡高/标题行几何行为断言判红。其余八项 fix1 变异对象不变。新增：

- `overview-sensor-rings-shrink-to-52`：三个 72→52 锚点，`expected_occurrences = 3`，实测直径与原尺寸字形比较判红。
- `overview-frequency-renders-an-ellipsis`：GPU 次行变成 `0.34 G…`，实际字形与完整 `0.34 GHz` 参考比较判红。
- `overview-number-font-shrinks`：原 15 pt 数字改为 11 pt，原字号断言判红。
- `overview-fanless-title-advertises-control`：移除标题 `showsControl` 门控，无风扇入口应不存在的断言判红。

本轮只核对全部 24 项锚点数量和行为 filter；**未在沙箱跑 mutation**。主会话需逐项确认“编译成功→行为断言红→恢复同 filter 绿”，不能用编译失败或环境失败计红。

```sh
cd ~/Developer/sc-worktrees/r2-power-fan-restore
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-power-fan-restore/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
FILTER=$(paste -sd '|' ~/Developer/.sc-build/r2-power-fan-restore/targeted-classes-fix2.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
python3 ~/Developer/.sc-build/r2-power-fan-restore/prepared/fix2/commit-prepared.py --check-only
python3 ~/Developer/.sc-build/r2-power-fan-restore/prepared/fix2/commit-prepared.py --validated --check-only
python3 ~/Developer/.sc-build/r2-power-fan-restore/prepared/fix2/check-patch-chain.py
```

### 需重拍的离屏场景

以下均拍明/暗，重点核对 **一级概览传感器卡片**，二级页与浮层保持前轮认可状态：

- `menu.overview.baseDark`。
- `menu.sensors.secondary@fanAutomatic`、`@fanManual65`、`@fanMaximum`、`@curveActive`。
- `menu.sensors.secondary@helperNotRegistered`、`@awaitingSystemApproval`、`@connectionInterrupted`、`@helperUntrusted`、`@helperUnavailable`。
- `menu.sensors.secondary@fanless`：标题右侧无入口；`@dualFanManual`：英文 `Fans` 全文、RPM 完整，VoiceOver 含均值含义。

保留主会话现有 r2 管线，输出新目录；另拍英文最窄 248 pt 与常规 304 pt 传感器卡片。验收：72 pt 三圆环与旧字号，`3.60 GHz`/`0.34 GHz` 完整，标题与入口不重叠、不省略；标题按钮单击打开既有浮层，二级整行入口与 hover 仍可用，概览 605/535 无滚动。

### prepared/fix2

三组增量：`01-overview-header-layout`（三个源文件）、`02-regression-tests`（两个测试文件）、`03-handoff`。只含本轮六文件差异；完整最终清单 26 文件。manifest 固定完整 fix1 树作为增量基线，记录父轮补丁 SHA-256、组顺序与最终文件 SHA-256。原 prepared 与 prepared/fix1 不改写。

`commit-prepared.py` 支持 HEAD 为原提交、原四组完整树或 fix1 四组完整树；验证后只提交缺失父轮和 fix2，不接受半轮树、不自动安装/合并/推送。本轮 `.git` 只读，实际提交仍由主会话完成验证后执行。

fix2 两种只读提交检查均已 **PASS，exit 0**，分别记录于 `logs/fix2/prepared-check-only.log`、`prepared-validated-check-only.log`。增量链复核 **PASS，exit 0**：一次性源码副本按原四组 + fix1 四组 + fix2 三组应用，全部 26 个最终文件 SHA-256 一致，记录于 `logs/fix2/patch-chain.log`。未写 git 元数据、未提交、未改原补丁。

本轮所有编译/测试 tool session 均已返回完成，没有仍在运行的本轮会话。系统进程清单只读核对无法执行：沙箱拒绝启动 `ps`（`Operation not permitted`）；不据此声称已排除其他会话遗留进程。工作区文件完整性由成功编译、manifest 哈希和补丁链复核确认。
