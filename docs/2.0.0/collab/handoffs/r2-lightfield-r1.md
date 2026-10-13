# r2-lightfield-r1 第四轮交接

基线 `b5249d1d540854396e038dc465c37a6add105f0c`，分支 `task/r2-lightfield-r1`；交付目录 `/Users/developer/Developer/.sc-build/r2-lightfield-r1/prepared-r4/`。四组补丁与 `all.patch` 都从基线生成，包含此前未提交的三轮源码和主会话已经加入的两处编译修正（`SmartScanProgressDashboard.module` 透传、卸载刷新闭包）。没有修改 `ScanStore.swift`、执行清理、安装、提交或推送。

主会话对第三轮源码的证据：Debug build 通过，64 项旧反证 PASS；定向 978 项有 1 项失败，全量 Debug 4277 项有 2 项失败。断言见 `r3-failures.txt`，原生日志与截图在 `logs/main-prepared-r3-230935/` 和 `visual-r2/`。这些不是第四轮通过证据。本沙箱遵照 `common.md` 只做源码、Swift 语法解析和静态复核；第四轮原生 AX、XCTest、构建、反证和实际截图须由主会话执行。

## 第四轮修改与根因

| 问题 | 根因/改动 | 红、绿和单点反证 |
|---|---|---|
| 运行页原生 AX | 第三轮原生快照在 1070×735 的 `HostingScrollView`/`DocumentView` 处显示 `children=0`，但标题、按钮、状态行均在可访问树，且运行文本有几何探针。新运行组件原本无条件包在 `FeatureOptionsScrollView`，生产 `AdaptivePageViewport` 还为试点再包一层。第四轮用 `ViewThatFits` 让标准窗口直出阶段、字幕、进度、当前项、可见指标和细节；三试点跳过外层滚动。矮窗用内部滚动，并在滚动元素自身发布完整阶段、进度、当前项、全部指标和已用时间的 AX 值。多出的候选大小等只在 VoiceOver 辅助值中，不占可见事实行。 | 原有 `testVisibleRuntimeStateSubtitleCurrentItemMetricsAndUnknownProgressAreAccessible` 加强了指标与值断言，新增 `testRunningFactsKeepLongCurrentItemOnOneLineAndExposeAuxiliaryMetric` 实测标准/矮窗 AX 与长路径几何。反证 `runtime-no-outer-scroll`、`runtime-direct-ax`、`runtime-compact-spoken-facts`、`runtime-extra-metric-visible`、`runtime-middle-path`。绝不把已失败的 AX 断言替换成源码探针。 |
| 全量独有布局失败 | `SafeCleanupLayoutTests.testRuntimeStatesKeepPanelsAndLongPathsStableAcrossWindowSizes` 对 green 仍要求 D53 的 `runtime.panel/header/footer`，D67 页面只有 `lightfield.*`；旧短窗内容起点还把运行 viewport 压至约 1 pt。按 D67 为 green 检查新标题、内容、主按钮、状态行与进度 viewport，长路径滚动后仍落在 viewport；overview/devCaches 的 V1 精度契约原样保留。短窗把内容起点前移，插画缩到标题旁，不与按钮相交。 | 保留同名三尺寸/五状态测试，仍检查跨状态 x/宽度/起点稳定与页内包含；新 `testFullSizeBackdropAndCenteredHaloCoverThePilotCanvas` 断言短窗 viewport >80 和插画不压按钮。反证 `content-origin`。`SafeCleanupLayoutTests` 已加入定向清单。 |
| 顶部 40 pt 平色带 | 旧光场背板只在页面安全区内，标题栏后面露出另一套 `ModuleBackground`。`MainContentHost` 现在为试点持有同一光场背板并延伸到顶部安全区；页面收到环境标记后不重复绘制。phase 偏好把运行/结果光晕坐标带到 host，窗口仍沿用原生 `.fullSizeContentView`。 | `testFullSizeBackdropAndCenteredHaloCoverThePilotCanvas` 检查 host 背板覆盖画布及顶部安全区源码连接；`full-size-titlebar-canvas` 单点反证。实际标题栏像素连续性需要新截图确认。 |
| 夜间/日间光晕 | 内层渐变先乘 0.70，再乘 palette 0.55/0.32，中心实际只有 0.385/0.224；暗色图中明显偏弱。640 pt 的 halo 保持与插画同心，中心色不再二次衰减，最终中心强度夜间 0.55、日间 0.32；结果态仍为 420 pt、0.6 倍。 | 同一 host 几何测试检查 640 pt、同心及 0.55/0.32；`halo-centre-night-day` 单点反证。最终观感须与原型及新截图对照。 |
| 列表底部半行及提示 | 原 `FeatureOptionsScrollView` 为结果仍留一行“向下滚动查看更多”，而结果列表末行被裁半。结果专用滚动现在无提示文字；在溢出时按 52 pt 行高对齐 viewport，底部 24 pt 渐隐，文档底部再留 24 pt，使最后一行滚动后完全位于渐隐区上方。landing/V1 提示保留。 | `testResultLongListFadesPartialRowsAndLastItemIsReachable` 检查渐隐 24、无 hint、初始不完整行仅落在渐隐区、末行滚到底后完全在渐隐区上方、主按钮固定。`overlapping-hint`、`result-fade-24pt`、`result-last-row-above-fade` 反证。健康/卸载昼夜截图均需复核。 |
| 安全清理运行卡片与多余数字 | `SmartScanScanningPage` 的 `ScanProgressStageList` 带 `.glassPanel`，绿色试点误用了旧列表。该试点删掉阶段卡片，画面保留阶段标题、当前项（仅这一行中间截断）、“已发现”和步数；候选大小及已用时间作为阶段的 VoiceOver 值。非试点列表不动。健康运行页也不再重复 landing 检查选项；原电池可用性参数转成单行副标题，继续被 VoiceOver 读取。 | 运行事实 AX/几何测试加 `green-stage-card-return`、`runtime-extra-metric-visible` 反证；截图确认无底色框及三行事实。 |
| 健康结果状态列 | 旧末列把“证据完整 · 100 / 100”塞进 96 pt，且默认 `DisclosureGroup` 箭头在首列前，破坏与勾选框对齐。末列只用“正常 / 需关注 / 需检修 / 故障警告 / 异常 / 未取得”等短语并按语义着色；完整性、评分、解释及时间放在展开内容。可按的整行使用行尾箭头，状态符号仍占首列 20 pt。 | `testHealthStatusColumnAndEndDisclosureMatchSelectionColumn` 原生几何对比状态符号与清理勾选框 x，验证末尾箭头、按钮展开 AX 值和证据文字。`health-short-status`、`health-first-column-alignment`、`health-end-disclosure` 反证。D64 允许真实状态符号及可点击展开箭头，故 `DeclutterD4D5ContractTests` 的旧“因素文件纯文本”守卫按此改写，其余装饰限制不放宽。 |

## 数据流与兼容

`FeatureLightfield.swift` 仍是唯一新增 D67 三态骨架。安全清理的选择、风险、确认、移到废纸篓及回执，健康的只读探测和证据来源，卸载的预览、默认范围、确认及恢复均沿用既有 store/service。运行页只读传入的 state、fraction、metrics、currentItem、真实或标明“约”的时钟；停止时仍禁用取消。结果夹具仅在 `#if DEBUG` 中，用 `/Fixture/` 数据和空操作闭包。V1 `FeaturePageScaffold` 等作为其余 11 个功能的兼容入口保留；它们的滚动提示及布局没有换成 D67。

第四轮改写的旧契约只有：`SafeCleanupLayoutTests` 的 green 旧 D53 探针换成 D67 探针，overview/devCaches 分支仍按原阈值；`FeatureLightfieldContractTests` 结果提示断言换成 D67 长列表渐隐/完整行断言；`DeclutterD4D5ContractTests` 对健康因素的纯文本限制允许真实状态/展开控件。原生运行 AX 断言继续存在并加严。`UIConsistencyRegressionTests` 和 `TestPreferenceHygieneTests` 均在定向清单中。

## 主会话验证

`prepared-r4/targeted-classes.txt` 含 50 类，明确包括 `SafeCleanupLayoutTests`、所有读取改动源码的类，以及 UI 一致性和偏好隔离。`source-readers.json` 给出来源。主会话在隔离 scratch 中构建、跑 Debug 定向及全量/Release、逐条执行 `counterexamples.json` 的 79 个单点变异。每条须先核对 `before` 出现次数，只替换一处、运行其 `filter`、看到有意义的断言失败（编译失败不算），恢复原文和哈希。此沙箱仅验证反证锚点，不声称执行了 XCTest。建议先执行下面的失败点和几何契约，再跑完整定向及全量：

```sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
sc_verify=/Users/developer/Developer/.sc-build/r2-lightfield-r1/master-verify-r4
sc_prepared=/Users/developer/Developer/.sc-build/r2-lightfield-r1/prepared-r4
swift build --scratch-path "$sc_verify/debug" --jobs 2
swift test --scratch-path "$sc_verify/debug" --jobs 2 --filter 'FeatureLightfieldContractTests|SafeCleanupLayoutTests'
sc_filter="$(paste -sd '|' "$sc_prepared/targeted-classes.txt")"
swift test --scratch-path "$sc_verify/debug" --jobs 2 --filter "$sc_filter"
swift test -c release --scratch-path "$sc_verify/release" --jobs 2 -Xswiftc -enable-testing --filter "$sc_filter"
STORAGE_CLEANER_VERIFY_ROOT="$sc_verify/full" STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 ./script/verify.sh
```

随后按原 `--debug-mini-window-demo-data --debug-mini-window-appearance=dark/light --debug-feature-page=all:landing --capture-feature-templates --capture-main-window-filters=green,healthHub,uninstall` 截取七尺寸×三态×两主题（每主题 63 张），新目录勿覆盖 `visual-r2/`。重点并排看 1280×763 的顶部 titlebar/画布连续、640 pt 同心光晕、day-green-running 三行事实、uninstall/healthHub-result 底部渐隐、健康末列/箭头，并在 677×390 和 1280×390 检查长路径与按钮。静态 PNG 不能替代 VoiceOver；AX 测试应读取真实 AppKit 树，且在标准与矮窗都读到状态、字幕、当前项及全部指标。

## 静态自检与剩余边界

`static-selfcheck.json` 列出每个改动 Swift 文件的作用域、长 ViewBuilder/三元表达式及泛型关系审阅；`static-checks.json` 记录 Swift 解析、分隔符、反证锚点、`git diff --check`、补丁独立/组合应用与反向恢复。解析不等于 Swift 类型检查或编译。本批 JEV 调用仍受 approval policy `never` 阻止，没有得到 JEV 评审。

第四轮尚无主会话构建、原生 AX 回读或新截图；特别需确认 SwiftUI 在 macOS 27 的短窗可访问滚动元素发布、host 背板安全区高度和半行渐隐的实际像素。若任何测试/截图失败，保持 worktree 未提交并用失败日志继续修，不以本交接判定验收完成。基准 D67 x96 内容宽520与 x610 插画边界仍有 6 pt 的规范内重叠，维持原型坐标，未放宽 0.5 pt 测试阈值。

四组：01 共同骨架、画布/滚动与兼容；02 三试点适配；03 Debug 夹具及契约；04 本交接。`manifest.json` 锁定最终源码 SHA-256、基线、分组顺序与产物；`commit-prepared.py` 默认只核对，主会话验证后才显式 `--commit`，不会安装或推送。

## 第五轮（Claude 主会话接手，2026-10-09）

接手原因：第四轮源码在沙箱里不能编译和运行原生测试。本轮在同一 worktree 上，以第四轮未提交改动为基础继续修改，用 `--scratch-path ~/Developer/.sc-build/r2-lightfield-r1/debug` 实际构建、测试、截图。没有提交、没有 push，也没有安装或启动 /Applications 里的应用。日志都在 `~/Developer/.sc-build/r2-lightfield-r1/logs/r5/`。

### 第四轮遗留失败的根因与修复

| 失败 | 实测根因 | 修复 |
|---|---|---|
| `FeatureLightfieldContractTests.testRunningFactsKeepLongCurrentItemOnOneLineAndExposeAuxiliaryMetric`（原生 AX 未发布标签） | 不是 `accessibilityHidden`、不是 `.ignore`，也不是控件被包进不可访问的容器。第四轮日志里的 AX 快照已经有 `AXStaticText label="In Progress · Current stage" value="Candidate size · 2.2 GiB, Elapsed 12s"`，其余事实也都发布了。测试期望的是字面量 `"Running · Current stage"`，取的是页面 `status:` 参数，而实现（第三轮已通过的同类测试也一样）读的是 `RuntimeWorkflowState.running.title`，英文为 “In Progress”，中文为“进行中”。 | 测试改为 `RuntimeWorkflowState.running.title + " · Current stage"`，断言内容不变（标签、辅助值、长路径、两项可见指标、矮窗滚动元素的完整口述值）。新增两个单点反证：标签不再取自状态，以及给阶段元素加 `accessibilityHidden`。两者均变红。 |
| `testHealthStatusColumnAndEndDisclosureMatchSelectionColumn`（93.75 ≠ 96） | 状态符号用 `.font(.system(size: 20))` 渲染，SF Symbol 的自然宽度约 24.5，在 20 pt 列里居中，所以左边溢出 2.25 pt；探针挂在 Image 上，量到的就是 93.75。 | `FeatureLightfieldStatusRow` 的状态符号改为 `resizable().scaledToFit().frame(20×20)`（D67 §2：状态符号 20×20），首列与勾选框都在 x=96。 |
| `DeclutterD4D5ContractTests.testHealthResultsRemoveDecorationButRetainEvidenceAndWarnings` | 第四轮实现把行改成 `Button + if expanded`，测试却仍要求 `return DisclosureGroup {`。实测原生 `DisclosureGroup` 套上自定义样式后，macOS 27 把它发布为 `AXDisclosureTriangle`，`press=false`（见 `logs/r5/test-2.log`），VoiceOver 无法展开。 | 新增共享组件 `FeatureLightfieldStatusDisclosure`：整行是一个按钮，标签为“标题 · 简短状态”，值为“已折叠/已展开”，提示为证据摘要，按 AXPress 展开，证据默认折叠。断言按 D67 改写，依据见下文。 |
| `UIConsistencyRegressionTests.testViewsDoNotReintroduceLocalButtonColorMaterialOrMotionStyles`（3 处） | `HealthFactorGrid.swift` 用了 `.buttonStyle(.plain)`。 | 改用共享按钮族 `FeatureLightfieldRowButtonStyle()`。`HealthFactorGrid` 本身不再有按钮，统一走共享组件。 |
| `SafeCleanupLayoutTests.testRuntimeStatesKeepPanelsAndLongPathsStableAcrossWindowSizes` | 第四轮已改 | 本轮在定向和全量中都通过；该类已在 `prepared-r4/targeted-classes.txt` 第 39 行。 |

### 视觉自查补齐（截图对照后发现）

1. **健康结果行尾箭头破坏网格**：第四轮把箭头放在行外的 HStack 里，因果有三：箭头列下面没有细线，所以分隔线断开；有箭头的行和没箭头的行（如“时间机器”）末列不对齐；路径列起点也错开。修复：`FeatureLightfieldResultRow` 增加一个 20 pt 的行尾列（`reservesTrailing`），箭头画在行内；状态行一律预留这一列。新增断言检查因素行与无箭头状态行的末列 maxX 相等，以及箭头位于末列之后。
2. **生产页仍有行首箭头**：截图用的夹具碰不到生产代码。安全清理结果的子类行（`CleanupScanViews.lightfieldSubcategoryRow`）和系统健康“保护与当前状态”的四行，仍然用 macOS 默认的 `DisclosureGroup`，箭头在行首，会把勾选框列和状态列推离 x=96。修复：子类行改用 `FeatureLightfieldResultRow(reservesTrailing: true)`，行尾放展开按钮（展开状态存在 `expandedLightfieldSubcategoryIDs`），勾选按钮和选择逻辑不变；健康环境的四行改用 `FeatureLightfieldStatusDisclosure`。另加源码断言，并为两处各补一个反证。注意：这两处只有源码契约，没有原生几何测试，夹具截图也看不到。
3. **长列表半行文字**：第四轮的 24 pt 渐隐下仍能看到下一行的字顶（像素可辨）。改为视口停在“列表细线 + 整行 + 15 pt”：下一行只露出文字和勾选框上方的空白带，24 pt 渐隐只盖住行距和细线。常量为 `FeatureLightfield.resultListHairline` 和 `resultPartialRowSlice`。新增断言：第一条不完整行的文字框 minY 不小于视口 maxY。
4. **状态行竖线位置**：竖线原来在整行正中，离右侧安全提示约 500 pt。按原型 `.status .r` 改为紧贴安全提示左侧 20 pt，几何测试锁定。
5. **未知进度显示成“— %”**：进度未知时不再显示单位“%”，只显示“—”；有测试锁定。
6. **主按钮顶部高光溢出圆角**：按钮上方露出一条 2 pt 的平条，越过 12 pt 圆角。高光改为沿圆角描边的渐变（对应原型 `inset 0 1px 0` 白 25%），加了源码守卫。

已核实达标、无需再改：标题栏下方画布连续到顶（取样夜间 #0E1332、日间 #ECF1F9，0–130 pt 一致）；640 pt 光晕与插画同心，夜间明显，日间偏淡（0.32）；运行页无底色阶段框，只有三行事实，长路径在中间截断；健康结果末列为简短状态加语义色。

### 按 D67 改写的旧契约

- `FeatureLightfieldContractTests` 运行事实测试：字面量 "Running" 改为 `RuntimeWorkflowState.running.title`，是对错误期望值的更正，没有删除或放宽断言。
- `DeclutterD4D5ContractTests`：`return DisclosureGroup {` 是第四轮自己加的断言，不是基线契约；基线的 `DisclosureGroup(L10n.text("指标来源"…))` 在第四轮已移除。依据是 D67 §2（状态型行：首列状态符号，末列简短状态）、D64（可点击的展开箭头属于有效图标）和 #10（来源说明放在默认折叠的次级详情里）。现在锁定：共享组件 `@State private var expanded = false`，证据（`Text(detail(for: factor))`、`scoreText`）只出现在展开内容里，箭头字面量在模板里，`FeatureLightfieldStatusDisclosure(` 被使用。
- `ComputerHealthDashboardTests`：第四轮的 `FeatureLightfieldStatusRow(` 改为 `FeatureLightfieldStatusDisclosure(`，并禁止 `} label: { FeatureLightfieldStatusRow(` 这种行首箭头写法。
- 所有阈值（0.5 pt 等）都没有改。

### 验证（全部用 `--skip-update --disable-automatic-resolution --manifest-cache local --jobs 4`，环境 `DEVELOPER_DIR=Xcode-27.0.0-Beta`、`LC_ALL=en_US.UTF-8`）

- Debug build（含测试目标）：PASS，exit 0（`logs/r5/build-*.log`；构建失败的轮次一律没有接着跑测试）。
- 定向（`prepared-r4/targeted-classes.txt`，50 类，包含 SafeCleanupLayoutTests、TestPreferenceHygieneTests、UIConsistencyRegressionTests）：在最终源码前一版上 1002 项，跳过 3 项，失败 0（`logs/r5/targeted-2.log`，exit 0）。此后只改了状态行探针位置，相关类单独复跑通过。
- 全量 Debug（最终源码）：4280 项，跳过 25，失败 0，exit 0（`logs/r5/full-debug.log`）。
- Release、严格并发、`script/verify.sh`：NOT RUN。
- 单点反证：
  - 第四轮清单中与本轮修改相关的 16 条，复跑全部 PASS（变异后出现断言失败），见 `logs/r5/mutations-r4-recheck/summary.json`。另有两条第四轮反证（`health-first-column-alignment`、`health-end-disclosure`）的锚点因代码迁移已不存在，由 r5 的等价反证替代。
  - 新增 `counterexamples-r5.json` 共 14 条，全部 PASS（`logs/r5/mutations-r5/`）。其中 `r5-status-divider-beside-safety` 第一次仍是绿的，原因是探针挂在 frame 之后、量的是外框；把探针移到 Text 本身后复跑 PASS（`logs/r5/mutations-r5b/`）。
  - 每条变异都先核对出现次数，只替换一处，跑完恢复原文并校验 SHA-256。
- 截图：快照目录 `~/Developer/.sc-build/r2-lightfield-r1/snap-r5`（rsync 复制后 git init 提交）。Debug 包由 `script/build_and_run.sh --bundle-only` 打出，build 目录为 `/tmp/storage-cleaner-lf-build`。用 `capture-main.sh` 拍了深空和日间，各三页三态，尺寸 1280×763，共 18 张，存放在 `~/Developer/.sc-build/r2-lightfield-r1/visual-r5/`（`night-*`、`day-*`）。

### 剩余问题

- 七尺寸矩阵（820×560、677×390、1280×390 等）本轮只做了原生几何测试，没有拍截图。
- 安全清理子类行和健康环境行改为行尾展开后，只有源码契约，没有原生几何测试，夹具截图也看不到。生产页面需要实机复核。
- 长列表的“还有更多”现在只靠系统滚动条和最后一条细线渐隐来提示；原型本身也没有更强的提示。如需要，可以按 D67 放在状态行。
- 截图中侧栏“文件分析”一行和起始页第一项选项都带悬停底色，应该是截图时鼠标所在位置造成的；没有用拿掉鼠标的方式复拍确认。
- 日间光晕强度为 0.32，观感偏淡，符合规范值；是否要调整需要用户决定。
- JEV 本轮没有调用。

## 第六轮（主会话独立复核意见，Claude 修复，2026-10-09）

基线是第五轮本地提交 `20a5fc38`，工作区原本干净。开始改源码前，已等到 `r2-lightfield-r2/logs/base-bundle.log` 出现 `exit=0`；`/tmp/storage-cleaner-lf2-base*` 没有碰。本轮没有提交，也没有安装或启动 /Applications 里的应用。日志都在 `~/Developer/.sc-build/r2-lightfield-r1/logs/r6/`。

### P1 修复

1. **卸载的选择与预览分开**：删除了 `onChange(of: selectedApplicationID)` → `requestUninstall` 这条链，也删除了“预览关闭就清空选择”的两处代码（`onChange(pendingUninstallApp)` 和预览 binding 的 setter）。现在点行、方向键都只改选择；主按钮“卸载所选”打开预览；右键“查看卸载预览”先选中该行再打开。原生测试 `testProductionUninstallRowSelectionNeverOpensPreview` 用真实 `AppUninstallerView` 和 store 验证：按行后 AX 值为“已选择”，`pendingUninstallApp` 仍为 nil，主按钮变为可用；按主按钮后进入该应用的预览；`cancelUninstall` 之后选择仍保留，主按钮仍可用。`SystemUtilitySafetyTests.testUninstallRowUsesNativeSelectionWithoutExecutingCleanup` 的旧断言 `.onChange(of: selectedApplicationID)` 按本轮复核改写为：页面里只有主按钮一处 `requestUninstall`、binding 不清空选择、列表点击只调 `select`、方向键处理中不出现 `review(`。`FeatureLightfieldContractTests` 中对应的那条也同步反转。
2. **安全清理分组勾选能读出状态**：`lightfieldSelectionButton` 补回 V1 三态控件的读屏值（已选择 / 部分选择 / 未选择，抽成共享的 `TriStateSelection.cleanupAccessibilityValue`）和提示语（可切换时：按空格切换；不可切换时：此分组没有可选择项目）。原生测试 `testProductionCleanupGroupSelectionSpeaksItsState` 在真实结果页里用 AX 命中测试读取每个绿色分组的值，与 store 中的三态逐一比对。
3. **页内“操作记录”入口**：D67 页面隐藏了窗口工具栏，入口改放在状态行最左侧，是一个文字按钮，不带图标，后面跟一条 1 pt 竖线。`ContentView` 通过环境值 `featureOperationHistoryAction` 打开同一个 `ReversibleOperationsView` sheet。测试验证：入口位于状态行内、在竖线左侧；按下后触发同一动作；安全清理、卸载、系统健康三张生产结果页都能找到它。
4. **生产结果页的几何与截图**：截图时 `--debug-feature-page=…:result` 现在渲染真实页面 `FeatureLightfieldProductionResult`，用的是真实 store：安全清理用现有的 `installDebugSmartScanSessionFixture(.results)`；卸载用固定的应用值列表（`/Applications/Lightfield Fixture N.app` 只是字面路径，不对应实际文件；选择不会打开预览）；系统健康用新增的 `ComputerHealthStore.installDebugPresentationFixture`（仅 DEBUG，不做探测，不写历史）。模板夹具 `FeatureLightfieldResultFixture` 仍然只供模板测试使用。
   - 列表截断位置改为按真实行位置计算：每行在结果文档坐标里上报自己的顶边，只有 snapped 结果列表才上报。截断位置取“某行顶边 + 15 pt（只露出该行上方空白）”或“某行底边”中、不超过可用高度的最大值。工具条、提示文字、DisclosureGroup、搜索栏都在截断线之上，所以完整显示。行被滚出视口后，保留最后一次的测量结果，滚动时截断位置不变。
   - 新测试 `testProductionResultPagesEndAbovePrimaryWithoutHalfRowsAndShowHistory`：3 个试点 × 1280×763、1000×700、677×390 三种尺寸，检查主按钮上方 24 pt、视口不超出内容区、渐隐贴底、没有任何行文字跨在截断线上、工具条左对齐。长列表测试补了一条：滚动前后视口高度一致。
5. **Release 与 Beta 构建**：两者都已实际运行，参数均为 `--skip-update --disable-automatic-resolution --manifest-cache local --jobs 4`。Release：PASS，exit 0，用时 303 s（`build-release-2.log`，最终源码）。Beta（`-Xswiftc -D -Xswiftc STORAGE_CLEANER_BETA`）第一次 FAIL：`MainWindowSnapshotPipeline.swift:1184` 找不到 `DebugSmartScanFlowDemo`（`build-release-beta.log`）。这是 `11160fcb`（10-07）就有的问题：该文件在 `DEBUG || BETA` 下编译，而它引用的类型只在 DEBUG 下存在。已把这一处引用包进 `#if DEBUG`，重跑 PASS，exit 0，用时 187 s（`build-release-beta-2.log`）。

### P2 修复

- **侧栏**：完整侧栏在所有页面固定为 210 pt，切页不再跳 14 pt。V1 页面在夜间纯黑主题下，侧栏底色和分隔线跟随主题（`surfaces.sidebar`）；D67 页面仍用光场侧栏。截图对照：纯黑主题下 V1 页侧栏取样为 (6,6,7)，D67 页为光场色；试点页与 V1 页的侧栏标题和行位置完全一致。工具栏显隐目前没有造成侧栏位移；V1 页与 D67 页详情区的上边距不同，这是两套模板本身的差别，留待 V1 页迁移时处理。
- **安全清理结果**：恢复了 V1 的“无法读取废纸篓”说明和“打开系统设置”文字按钮，也恢复了清空废纸篓“只永久删除扫描时废纸篓里已有的 N 项”的范围说明。
- **单项行**：“所属应用运行中”等原因从路径中分出来，用警示色显示，不截断，路径优先让出空间（`FeatureLightfieldResultRow.note`）。子项行相对分组行缩进 36 pt，即勾选框宽度加列间距。
- **运行页状态行**：从“进行中 · 正在扫描”改为“进行中 · 60%”，与原型一致。进度未知时只显示状态。
- **结果态光晕**：在画布左侧 96 pt 内渐隐，不再被侧栏边缘硬切。
- **卸载长列表**：行的四列改用 `Layout`（`FeatureLightfieldRowColumns`）计算，去掉了每行一个 GeometryReader。另外实测了外层 `.fixedSize` 的影响：新测试 `testLongUninstallListLaysOutOnlyVisibleRows` 放 400 个应用，只有视口附近不到 60 行被布局，第 400 行没有布局，文档高度仍为完整的 400 × 52。我试过给列表加显式高度，这个测试无论加不加都通过（反证 `r6-uninstall-list-known-height` 保持绿色），说明 `.fixedSize` 并没有让 LazyVStack 全量布局，所以没有保留那个改动。把 LazyVStack 换成 VStack 的反证会变红。
- **测试**：`SystemUtilitySafetyTests` 中近乎恒真的 `contains("isHighlighted")` 改为三条有意义的断言：高亮行画那块滑动的选择底块、文字为白色、非高亮行只有悬停底色。
- 按复核意见，SMART 故障保持琥珀色，没有改。
- 截图中还发现结果工具条和提示文字是居中的，已改为左对齐，并有几何断言。

### 验证

- Debug 构建：PASS。构建失败的轮次一律没有接着跑测试。
- 定向测试（50 类）：1007 项，跳过 3，失败 0（`targeted.log`）。
- 全量 Debug：4285 项，跳过 25，失败 0（`full-debug.log`）。
- 之后改动只有三处：新增 `testRoundSixPresentationContracts`、在长列表测试里加滚动断言、Beta 编译修正。复跑受影响的类（FeatureLightfieldContractTests、SystemUtilitySafetyTests、所有读取 MainWindowSnapshotPipeline 的类、发布隔离测试）：282 项，跳过 1，失败 0（`test-final.log`）。没有再跑一次全量。
- 单点反证：
  - 新增 `counterexamples-r6.json` 18 条，全部变红（`mutations-r6/`）。其中 `r6-snap-stable-when-scrolled` 第一次是绿的，补上“滚动前后视口高度一致”的断言后变红（`mutations-r6b/`）。
  - 第五轮 13 条（第 14 条 `r5-result-no-half-row-text` 的锚点已被 r6 的实测行位替代）全部变红。
  - 第四轮相关 16 条全部变红。
- 截图：`~/Developer/.sc-build/r2-lightfield-r1/visual-r6/`，共 33 张，覆盖深空、日间、纯黑三种主题，各含 green、healthHub、uninstall 三种状态以及 memory（V1 对照页）的 landing 和 running。其中安全清理结果页带 D47 示例行，并展开了绿色分组，可以看到子项缩进和“正在运行”的警示。
- `git diff --check` 干净。自建的 `/tmp/storage-cleaner-lf6-*`、快照目录、Release 和 Beta 的 scratch 都已删除。

### 仍未解决

- 七尺寸矩阵中，只有 1280×763 拍了截图；1000×700 和 677×390 只有几何测试。
- 子项行缩进、警示色、光晕渐隐、侧栏颜色只有源码契约和截图作证据，没有原生几何断言。
- 卸载结果的搜索框是无边框的纯文本输入框，在深色背景上不太容易看出来是输入框，以后可以再调。
- V1 页和 D67 页详情区上边距不同（工具栏显隐造成），要等 V1 页面迁移时统一。
