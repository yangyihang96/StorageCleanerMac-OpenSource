# r2-lf2-b2：光场二期共用组件与选项图标

日期：2026-10-09。工作区 `/Users/developer/Developer/sc-worktrees/r2-lf2-b2`；分支 `task/r2-lf2-b2`；基线 `f89de61ec38782070e5c64346e408a99eb7527db`。

状态：**代码、测试源码和分组补丁已准备；构建、XCTest、变异反证、运行截图、严格并发、Release/Beta 配置构建、提交均 NOT RUN**（Codex 阶段原文；主会话验证结果见文末“主会话验证轮”，以该节为准）。遵守 `_prompts/common.md`：本 Codex 沙箱不执行这些步骤、不启动应用、不写 `.git`。主会话完成验证后才能认定实现通过。未修改任何功能页的接入或扫描/执行逻辑，`ScanStore.swift` 与安装包未改。

## 改动与依据

1. D70 选项资源：确认源 `art/set-A-mini/manifest.json` 的 85 条映射对应 70 个独立 `opt-*` 图标。原封不动复制 56／84 像素 RGBA 导出件，共 140 个 PNG；`Resources/Art/lightfield-options.json` 保留完整映射与导出清单。`LightfieldOptionIcon` 的 70 个 case、2x／3x 变体、目录／包解析器复用 `GeneratedArtLibrary` 的后台解码、缓存、缺失记录；视图缺图不显示，不改行名与 AX。导出说明追加到 `Resources/Art/README.md`。
2. HEIC 回退：本沙箱 `sips -s format heic` 返回 `sysctlbyname ... failed`／Error 13，没有可读 HEIC。该次多个命令共用 shell，整体 exit 0，**未捕获单独 sips 的退出码**，不能写作转换成功。详情 `scratch/logs/alpha-conversion.json`。按本批授权采用 PNG，并给 `build_and_run.sh`、`make_release_dmg.sh` 只新增 PNG／清单复制规则，正式包完整性核对同步增加，原 HEIC 规则未改。
3. 共用层三个新文件：`FeatureLightfieldComponents.swift`、`FeatureLightfieldCharts.swift`、`FeatureLightfieldChartGeometry.swift`。提供 OptionRow、AppIcon、StatusGlyph、Ring、MetricGroup、PathText、DataBar、ExpandableRow、TextSegments、TrendChart、BubbleChart、DonutChart、Summary。颜色仍来自 `FeatureLightfieldPalette`，字体／尺寸取 D67 与确认 CSS；动画仍取 `FeatureLightfieldMotion`。没有新状态目录、新颜色表、材质或卡片背景。
4. 小幅扩展一期共用骨架：`FeatureLightfieldPage.showsArtwork` 默认 true；陈列页设 false，防止骨架插画覆盖被拍的组件。`FeatureLightfieldRowButtonStyle.circular` 默认 false；气泡设 true，使圆形命中范围与视觉相符。原生产调用默认行为不变。
5. Debug 陈列：`Debug/LightfieldComponentGallery.swift` 全文件严格 `#if DEBUG`，12 类典型状态；启动参数 `--debug-lightfield-gallery`；`ContentView` 仅增加 Debug 入口；`MiniWindowDemoData` 仅在 DEBUG 下让该参数启用既有惰性演示监测；两个持久记录恢复 task 在该模式提前返回。参数解析和不可变清单显式 nonisolated，避免非主线程演示判断跨入 SwiftUI 主 actor。截图管线输出 `gallery-<组件>.png`。Release/Beta 无陈列类型、入口或引用。

视觉输入已读取 D67、D69／D70、计划 B2 与确认目录 a/b 的 CSS；已查看确认渲染：memory-landing、memory-result、files-analysis-result 夜间。圆环中心 57% 框、大数最大 34、单位最大 15、标签最大 13；趋势底色三等分且 6% 透明，面积 accent 12%；气泡门槛 100、悬停 1.04；文件类型环 132、中心框 76×60、字体 15／13、图例行 24，来自确认 CSS。**这不是实现截图验收**；日夜和坐标误差仍由主会话拍照核对。

## 接入契约

| 组件 | 调用与边界 |
|---|---|
| OptionRow | `selection: Binding<Bool>?`。非 nil 是整行按钮，20 勾选 + 28 图标 + 16 名称 + 13 元数据，高 56、底线。AX 已选/未选。nil 为固定静态文本，无勾选、无 AXPress。图标自行按显示倍率选档。 |
| AppIcon | 真实 app bundle path 交给 `CachedAppIconView`，16／24／28；nil／缺图统一 `fg3` 齿轮。默认随行读屏隐藏；单独使用可给 `accessibilityName`。不调用进程发现或图标提供器之外的服务。 |
| StatusGlyph | 直接接收 `MetadataPillStatus`。normal 是 `.none` 在该组件内的别名；systemOnly 对应 `.systemSettingsOnly`。其他符号／AX 说明复用旧映射；旧 MetadataPill `.none` 仍无图标、不改变 allCases。20×20。 |
| Ring | `progress: Double?`，nil 不填弧；传入令牌色与完整 value/unit/label。`LightfieldRingGeometry.textBounds` 同时约束到 57% 和圆内接方形；每段文字单行、自适应缩小，超长文字仍保留完整 AX。Debug 探针：`<probeID>`、`.text`、`.value`、`.unit`、`.label`。 |
| MetricGroup / PathText | 每列显式等宽；13 标签、22 数值、15 单位，最小缩放 0.5。路径 12.5 等宽、单行中间截断并保留完整 help/AX。七尺寸测试测真实文本和列边界，不能用裁切代替断言。 |
| DataBar | `.ratio` 高 2（验证轮：平涂 60% accent，同确认图）；`.progress(segments: 0)` 连续高 6；n>0 等分 n 格，当前格按一期 halo 周期呼吸。nil 为未提供；reduceMotion／禁动画时停止 Timeline 调度并立即显示。 |
| ExpandableRow | 一个整行 Button，末列复用一期箭头；`Binding<Bool>`；AXPress 与折叠/展开值；子内容缩进 36。调用方提供 leading 和子行，子行的独立动作不能嵌在父按钮里。 |
| TextSegments | 标题数组、选中索引 Binding、模块令牌色；13 文字，选中 fg、2 accent 下划线，无填充底。 |
| TrendChart | `LightfieldTrendSample(time:value:)`，value 为 0...1，nil 留断线。按输入索引悬停回调 `onHoverIndex(Int?)`；退出悬停回调 nil。拖选回调范围、非缺失样本平均与 measuredCount，反向拖动也支持。AX 可逐时刻调整。不会推断“该时刻最多应用”，页面应按回调索引查询它自己的快照。当前值默认显示最新点。 |
| BubbleChart | 稳定唯一 item id、真实正数 value、已格式化大小、类别使用的既有模块令牌色和选项图标。纯几何按值降序／id 升序；最大在画布中心，其他相切环绕，全局缩放保持圆面积比例；预留 1.04 悬停包络，无随机、无重叠。小于 100 仅图标。回调高亮 id/nil 和点击下钻 id，不执行文件动作。 |
| DonutChart | 同样的 item 数据；132 环和两行中心；图例色点、类型、大小、占比。正数按归一化求和避免大数溢出；没有测量值显示破折号，零值保留真实 0%。 |
| Summary | 76 插画、13 标签、52 主数值 + 24 单位；note 紧邻 12，满足“· 2 项可直接管理”；secondary 数字组（验证轮按确认图改）放在行尾、间距 34、右留 6，13 标签在上、24 数值 + 15 fg2 单位在下。一期只有 Results 内部私有摘要，没有同名可扩展组件，因此新增共用 Summary 供后批接入。 |

## 测试与唯一旧断言改写

新增 **30 个测试方法**，分四类：`LightfieldOptionIconTests`、`FeatureLightfieldComponentGeometryTests`、`FeatureLightfieldComponentTests`（仅 DEBUG）、`FeatureLightfieldComponentSourceTests`（Release 也运行）。Native 测试复用 `CalibrationAppKitLayoutHost`，测七尺寸、两种主题的真实圆环文字框；测等宽列和路径、图标与状态尺寸、AXPress/静态项、展开 36 缩进、分段选择、趋势 AX 历史回调、气泡点击身份、环尺寸、Summary 临近说明及 12 陈列夹具。没有写真实偏好，新测试的纯文件夹具只用 `TestFileSystem.makeHome(for:)` 登记和清理。

唯一改写旧断言：`GeneratedArtTests.testEveryPictureDecodesWithAlphaAtItsExportedSizeWithinTheSizeBudget` 原要求 Art 无 PNG；D70 明确允许选项 PNG 回退，因此改为 **PNG 文件集合必须精确等于 70 case × 2 档**。原 40 HEIC 数量、解码、alpha、尺寸、1 MB HEIC 预算断言均保留；未删测试、跳过测试或放宽阈值。

定向类清单：`scratch/targeted-classes.txt`，包含 UIConsistencyRegressionTests、TestPreferenceHygieneTests、FeatureLightfieldContractTests、FeatureLightfieldReleaseIsolationTests、上述四新类、GeneratedArtTests、D64DeclutterAContractTests。

`scratch/counterexamples.json` 和 `prepared/counterexamples.json` 为一期 r6 的同格式：33 条，每条含 id/path/before/after/expected_occurrences/filter；30 个新方法每个至少对应一条。额外反证覆盖取消 toggle、放大悬停包络和圆形命中区域。生成器只核对片段出现数和筛选名存在，**没有运行变异，也不声称全红**。

红／绿／反证步骤：先在完整本批改动下构建（失败即停），跑 targeted 后跑完整 Debug；确认绿色后，每条只按 expected_occurrences 替换对应片段，跑 filter，必须失败；日志保留测试名和断言失败，不把编译错误当有效反证。每条恢复源文件并校验最终 SHA-256；最后重新构建，随后执行 Release、严格并发、Beta 配置和主门禁。旧基线不包含新类型，不能以旧基线编译失败冒充本批红测试。

## 主会话执行命令（本会话未执行）

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
export BATCH_SCRATCH=/Users/developer/Developer/.sc-build/r2-lf2-b2
# 按 RULES 先由主会话准备本批离线依赖。
swift build --scratch-path "$BATCH_SCRATCH/debug" --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local
swift test --scratch-path "$BATCH_SCRATCH/debug" --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local --filter "$(paste -sd '|' "$BATCH_SCRATCH/targeted-classes.txt")"
swift test --scratch-path "$BATCH_SCRATCH/debug" --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local
```

变异执行器与完整门禁由主会话复用现有调度位置；本 worktree 没有 `scratchpad/run-mutations.py`，没有另造执行器，也没有假定其 CLI。项目完整门禁使用私有根：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-lf2-b2/verify \
bash script/verify.sh
```

陈列必须使用主会话已准备的 **Debug bundle**，不可用 release/Beta 包替代。主会话确定 `DEBUG_APP` 后：

```bash
"$DEBUG_APP/Contents/MacOS/StorageCleanerMac" \
  --debug-lightfield-gallery --debug-mini-window-appearance=dark \
  --debug-feature-disable-layout-animations \
  --capture-main-window-directory=/Users/developer/Developer/.sc-build/r2-lf2-b2/gallery/night
# 日间改 appearance=light，目录改 gallery/day。
```

拍照之外要在陈列里实测趋势悬停／拖选和气泡悬停／点击：鼠标手势由源码接线守卫、纯几何/平均测试及趋势 AX 回调测试覆盖，**原生鼠标 hover/drag 的事件派送本批没有自动化用例**。按七尺寸查看圆环、数字组、路径与摘要次要数字，确认不溢出、没有材质／卡片，减少动态效果下无呼吸或过渡。位置／颜色与确认图的 ≤2 pt 比较仍 NOT RUN。

## 补丁与实际证据

`scratch/prepared/`：

- `01-option-art`：140 PNG、映射清单、enum／解析器、两个打包脚本、图标测试和唯一旧断言改写。
- `02-components`：三个共用文件与一期骨架／按钮样式可选扩展。
- `03-debug-gallery`：陈列、Debug 入口、惰性演示判断与截图管线。
- `04-contracts-handoff`：其余 27 个新测试与本交接。
- 每组 `.patch`／`-message.txt`，合并 `all.patch`，`manifest.json`（完整基线、分支、组序、159 个最终文件 SHA-256 和产物哈希），`commit-prepared.py`，`generate-prepared.py`，`static-checks.json`，定向类清单与反证 JSON。生成器不写 git index；提交脚本仅供主会话通过验证后执行，先核对工作区、基线、暂存区、文件／产物哈希，然后按组提交，不 push。

静态证据见 `prepared/static-checks.json`：git diff 空白检查、分组/合并补丁反向 check、资源像素与透明像素核对、case／manifest／导出件对应、Debug 引用 guard、无禁用 UI 风格、反证片段计数和测试筛选对应、没有移除旧测试、ScanStore 与基线相同、shell `bash -n`、新 Swift 文件括号词法检查。括号检查**不等于 Swift 语法/类型检查**。

JEV：已尝试调用当前暴露的 `mcp__jev__jev_decide`，其接口不提供模型标识／model 参数；返回 `MCP tool call requires approval, but approval policy is never`。状态 **BLOCKED**，没有 JEV 判断或复核结果；未换模型或绕过审批。需要主会话独立复核及真实编译结果。

提交来源尾注按 common.md 保留 `Generated-By: Codex (...)` 与指定 Claude Co-Authored-By 两行。当前会话没有暴露实际模型标识（只核对 CODEX_MODEL／OPENAI_MODEL 两个模型变量，均无值），括号如实写 `model identifier not exposed`，没有根据旧派工示例冒称模型；若主会话有可靠 harness 标识，可在提交前替换并重新生成产物哈希。

没有安装、提交、上传、发布或真实文件/硬件操作。当前交付不能替代 B3–B7 页面接入，也不能称为实机 UI 验收通过。

## 主会话验证轮（2026-10-09，Claude）

结论：Debug 构建（含测试目标）通过；定向 140 个测试 0 失败；全量 Debug 4342 个测试（25 跳过）0 失败；反证 37 条全部变红；Release 与 Beta 配置均构建成功且不含陈列页；日夜截图已逐项对照确认图并修正差异。未提交、未安装、未推送。

### 改了什么

1. **编译错误（8 个）**：`.environment(\.accessibilityReduceMotion, true)` 是只读键。按一期测试已有做法改为 `.environment(\.featureDisablesLayoutAnimations, true)`（组件都以 `reduceMotion || disablesAnimations` 判断，等价覆盖“减少动态效果”路径）。
2. **测试宿主**：`CalibrationAppKitLayoutHost` 只在传入的根视图上发布 `fixture.viewport`；单个组件按内在尺寸布局，帧永远等不到视口大小（10 个测试超时）。在 `FeatureLightfieldComponentTests` 内加 `lightfieldHost`，把根视图铺满视口（左上对齐），组件内部尺寸不变。共享宿主未改。
3. **AXPress 丢失**：OptionRow、ExpandableRow、气泡把 `Button` 包在 `.accessibilityElement(children: .ignore)` 里，macOS 27 上变成 AXUnknown、无按下动作。照一期 `FeatureLightfieldStatusDisclosure` 的写法去掉这一层，标签/值仍在按钮上。
4. **选项图标缺图**：缺图时 `Group` 为空，28 pt 槽位和探针一起消失。改为放 `Color.clear` 保留槽位（仍不显示、不崩溃）。
5. **字号缩放守卫**：`UIConsistencyRegressionTests.testMainWindowTextAvoidsSmallSemanticFontOverrides` 只允许两个文件用 `minimumScaleFactor`。依据 `LIGHTFIELD-R2-PLAN.md` B2（圆环文字必须用 minimumScaleFactor），把 `FeatureLightfieldComponents.swift`、`FeatureLightfieldCharts.swift` 加入白名单，仍要求 `.lineLimit(1)`；同时把普通文字（选项名/元数据、分段、数字组标签、摘要说明、气泡名）的缩放改为尾部截断，只保留数字和圆内/气泡内紧凑文字的缩放。
6. **按确认图修正视觉**（夜/日两套都核对）：
   - 圆环：单位改 fg、500 字重（原为环色）；新增 `labelIsStatus`，状态词 15 pt semibold 用环色（确认图内存页“58 % 正常”）。
   - 数字组 / 摘要次要数字：单位改 fg2；摘要次要数字组移到行尾（energy/memory 确认图），不再贴在主数字基线后。
   - 趋势图：默认高 96；左轴 36 pt“100% / 50% / 0”（原“0%”且“100%”被挤成两行）；最新点改 accent 点 + 18% 光晕，当前值放在右侧 62 pt 槽内（600 13 pt 等宽），悬停时才在上方显示时刻值；底部时间改相对时间“X 分 Y 秒前 … 现在”，中间可传 `hint`，拖选时换成区间平均。
   - 数据条：分段 3 pt 间隔、每格胶囊、整条 accent2→accent 渐变（确认图逐格从 accent2 过渡到 accent）+ 柔光；连续进度胶囊 + 柔光；行内比例条平涂 60% accent。
   - 气泡：打包改为优先贴合画布长宽比（原先竖向堆叠，宽画布里气泡过小），最大直径封顶 180、间隙 0.08 R（≈7 pt），仍保持面积比例、最大居中、确定性、无重叠；填充补齐确认 CSS 的右下色池、左上高光、带色描边；图标 14/24/32 三档；名称 15 medium，仅在直径 ≥100 且放得下时显示。
   - 类型环：相邻弧之间留细缝；中心说明允许两行；图例按确认网格（色点 6｜名称 fg2｜大小 fg 右对齐｜占比 44）。
   - 选项行：右侧留 6 pt（确认图元数据不贴线）。
   - **令牌**：一期 `FeatureLightfieldPalette.accents` 缺 B3–B7 模块，性能/能耗/登录项/应用更新/文件分析/文件搬家回落到旧主题色（日间性能进度条是暗酒红）。按确认图 `shared.js` 补：startup/energy/performance `#FF5FA2/#AD1653`，updater `#A285FF/#5137C7`，largeFiles/migration `#2CC9D6/#0E7C8C`。只影响这些尚未接入光场的模块；一期三个试点模块的令牌未变（原契约测试仍通过）。
7. **陈列页**按确认图尺寸摆放：数字组/趋势 520 宽，气泡 510×268，类型环 340 宽，新增 112 圆环状态词样例，摘要第二例改为能耗式行尾次要数字。

### 测试与断言改动依据

- 新增 2 个方法：`FeatureLightfieldComponentTests.testSummarySecondaryMetricsSitAtTheTrailingEdgeAcrossSevenWindows`（七尺寸：摘要铺满列宽、次要组距右 6、组间 34、在主数字右侧）、`FeatureLightfieldComponentGeometryTests.testApprovedMockupAccentTokensCoverTheB3ToB7Modules`。新方法合计 32。
- 改写 1 条源码断言：`FeatureLightfieldComponentSourceTests` 原断言 `.alignmentGuide(.firstTextBaseline) { $0[.lastTextBaseline] }`（次要数字贴主数字基线），与确认图不符，改为断言 `HStack(alignment: .top, spacing: 34)`，几何由上面的新测试负责。
- 改写 1 条全局守卫白名单（见上 5）。没有删除断言、放宽阈值或跳过测试。

### 数字

| 项目 | 结果 | 日志 |
|---|---|---|
| Debug 构建（含测试） | PASS | `scratch/logs/main-prepared-183149/build.log`、`logs/v-final-build.log` |
| 定向（`targeted-classes.txt` 10 类） | 140 个，0 失败 | `main-prepared-183149/test.log`、`logs/v-final-targeted.log` |
| 全量 Debug | 4342 个，25 跳过，0 失败（809 s）；补摘要测试断言后最终复跑同为 4342／25 跳过／0 失败（794 s） | `main-prepared-183149/full.log`、`logs/v-final-full.log` |
| 反证 | 37 / 37 变红（原 33 + 新 4：摘要行尾、选项行 AXPress、图标槽位、令牌）。`summary-secondary-trailing` 首轮未变红（测试只量相对摘要自身），给测试补“摘要铺满列宽”后单独重跑变红（7 处失败） | `main-prepared-183149/mutations/`、`mutations-rerun/` |
| 反证后重新构建 | PASS；私有 API 检查通过（7 处白名单） | `main-prepared-183149/rebuild-after-mutations.log` |
| Release `swift build -c release` | PASS（独立 scratch `scratch/release`） | `logs/v-release.log` |
| Beta（同参数 + `-D STORAGE_CLEANER_BETA`） | PASS（`scratch/beta`） | `logs/v-beta.log` |

Release/Beta 隔离：两个二进制里 `LightfieldComponentGallery`/`captureLightfieldGallery` 符号 0、`--debug-lightfield-gallery` 字符串 0、`gallery-` 文件名 0、`lightfield.ring.text` 等探针 ID 0；共用组件符号存在（62）。Debug 二进制含陈列符号（对照）。

### 截图

Debug 包（`SWIFT_BUILD_DIR=/tmp/storage-cleaner-lf2b2-build`，离屏截图管线，QA 标识，未装到 /Applications），`--debug-lightfield-gallery`，深空画布，日夜各 12 张：

- 最终：`/Users/developer/Developer/.sc-build/r2-lf2-b2/visual/r4-dark/`、`visual/r4-light/`（`gallery-<组件>.png`）。
- 修正前后过程：`visual/r2-*`（首轮修正后）、`visual/r3-*`；对照拼图与确认图裁切：`visual/compare/`（`r4-*-sheet-*.png`、`b2-r4.png`、`ml-crop.png` 等）。

逐项对照结果（以 r4 为准）：选项行、应用图标（真实图标 + 灰齿轮）、状态符号、圆环文字在圆内、数字组、比例条/分段进度条、展开行、文字分段、趋势图、气泡图、类型环、摘要区——与确认图一致或已修到一致；剩余差异见下。

### 仍未解决 / 未覆盖

- 悬停/拖选态（趋势游标、区间阴影、气泡 1.04 放大）只有静态截图，原生鼠标事件派送仍无自动化用例；确认图趋势悬停是浮动小气泡（时刻 + GB · %），本组件是上方一行文字，页面接入（B4 内存页）时需决定是否补这个浮层。
- 气泡最小半径：确认图 JS 设了 14 pt 下限，本组件按测试保持严格面积比例（无下限），极小值的气泡会比确认图小。
- 选项行固定型（性能测试）图标从行首开始，与确认图一致；但确认图中性能行的元数据含“/”分隔说明，长文案在窄窗下尾部截断，需页面批次核对。
- `prepared/` 补丁、`manifest.json`、`static-checks.json` 已按验证轮后的文件重新生成（见下）；**提交仍由主会话执行**。
- JEV 本轮未调用。

## 复核修复轮（2026-10-09，续接 d89ed724）

本节为最新状态，覆盖上节“仍未解决”中趋势浮动气泡、最小半径以及旧 prepared 的描述。进入时核对 HEAD `d89ed724d0fa5381265483e89df100bf5f23d196`、分支 `task/r2-lf2-b2`、工作区干净；已逐项检查 `396326b9..HEAD` 的六个修复提交。网络重连续接后再次确认 `git status` / `git diff`，未丢弃已有改动。

**源码核对 PASS；最终 Debug 构建（含测试）PASS；完整定向清单 BLOCKED（沙箱环境，命令 exit 1）：152 个测试，144 个通过，8 个测试产生 9 个失败断言，0 跳过。反证、Release/Beta、严格并发、全量和安装本轮 NOT RUN。** 不将上一节或 scratch 中旧轮日志作为本轮通过证据。

### 意见落实与测试对应

以下 `Geometry` / `Native` / `Source` 分别指 `FeatureLightfieldComponentGeometryTests` / `FeatureLightfieldComponentTests` / `FeatureLightfieldComponentSourceTests`。列出的测试均在本轮最终定向运行中通过；原生鼠标事件派送的限制另列于下。

| 意见 | 最终处理 | 对应测试 / 反证 |
|---|---|---|
| P1：趋势单击不留选区 | `minimumDragDistance = 3`；小于阈值不生成单点范围；释放单击清除已有范围。保留上一轮实现。 | Geometry `testTrendClickBelowDragThresholdNeverCreatesARange`；Native `testTrendMultiSeriesWithoutAxisOrGutterSpansTheChart` 守卫释放接线。`trend-click-threshold`、`trend-click-clears-range`。 |
| P2：刷新保留悬停 / 选区 | `hoveredTime` / `selectedTimes` 按时间戳锚定；刷新后回报新索引，范围部分移出时夹到窗口内，全部移出才清除。 | Geometry `testTrendHoverAndRangeStayAnchoredToTimestampsAcrossRefresh`；Native `testTrendLiveRefreshKeepsTheHoveredMomentAndShowsTheBubble` 真实 AX 调整及刷新回读。`trend-anchor-geometry`、`trend-refresh-reports-new-index`，新增 `trend-selection-timestamp-lower-bound`。 |
| P2：趋势多线、图例、色带开关、可配置 Y 轴 | 保留 `series`、`legend`、`showsPressureBands`、`axis` 配置。本轮增加沿用既有 DEBUG 探针的轴 / 色带 / 附加曲线 / 图例探针，实际布局测试确认 GPU 曲线、CPU/GPU 图例存在、关闭色带和轴时节点不存在、AX 包含 GPU 值；补默认及自定义轴的 96/42/62 几何。 | Native `testTrendMultiSeriesWithoutAxisOrGutterSpansTheChart`（加强）及新增 `testTrendMemoryDefaultAndCustomAxisKeepTheApproved96PointPlot`。新增 `trend-series-drawn`、`trend-series-legend-rendered`、`trend-pressure-bands-switch`；既有 `trend-axis-hidden`。 |
| P2：气泡缓存、合并“其他”、14pt、过小不进 AX | 布局按值 / 尺寸缓存；悬停状态属于单泡；24 个以上保留 23 项并合并尾部。**本轮补漏**：合并总量可能超过任一单项，布局须再按合并后的真实大小排序，以最大显示气泡归一化并居中，才能保证正常画布 14pt 下限。极小 80×60 / 90×60 画布保留无重叠的比例回退，直径 <20pt 隐藏 AX；不将 14pt 圆强行挤到不可能容纳的画布中。 | Geometry `testBubbleLayoutIsCachedByValuesAndSize`、`testBubbleTailMergesBeyondTwentyFourAndKeepsTheTotal`、`testBubblePackingIsDeterministicCenteredAreaProportionalAndNonoverlapping`（216pt 也须满足下限）、新增 `testMergedTailCanBeTheLargestCenteredBubbleWithoutBreakingTheMinimumRadius`；Native `testTinyBubblesStayOutOfAccessibility`；Source `testTrendGesturesAndBubbleHoverHaveIdentityCallbacks`。既有缓存 / 合并 / 最小半径 / AX 反证，新增 `bubble-center-largest-merged-tail`。 |
| P2：分段进度只当前格呼吸 | `breathingSegments` 只返回 `.current`；仅该格创建 `LightfieldBreathingCell`，完整格和底轨静态；减少动态效果立即显示。 | Geometry `testSegmentedProgressBreathesOnlyTheCurrentCell`；Source `testTrendGesturesAndBubbleHoverHaveIdentityCallbacks`；Native `testEveryAnimatedComponentUsesReduceMotionAndSingleTimingOwner`。`segment-breathes-current-only`、`segment-track-not-pulsed`。 |
| P2：minimumScaleFactor 白名单收窄 | 两个光场文件每一处缩放行必须带 `// lightfield-scale-ok`，每文件最多 6 行；普通行标签未获整文件豁免。 | `UIConsistencyRegressionTests/testMainWindowTextAvoidsSmallSemanticFontOverrides`。`scale-marker-required`、`scale-budget-cap`。 |
| P2：PNG 预算、选项 JSON 不打包（两个脚本） | PNG 140 件总量 **934343 bytes**，独立预算 `< 1100000`；原 HEIC `<1000000` 保持。两脚本仅复制 `opt-*.png`；release 包完整性核对也只查 PNG，选项 JSON 为源码 / 测试清单。 | `GeneratedArtTests/testEveryPictureDecodesWithAlphaAtItsExportedSizeWithinTheSizeBudget`；Source `testBothPackagersAddPNGWithoutReplacingHEICRules`。`options-json-not-shipped` 及新增 `release-options-json-not-shipped`；真实 PNG 体积反证见下，不能以收紧测试阈值代替资产增长反证。 |
| P2：气泡图标取 84px | 变体按 `pointSize × displayScale` 选；32pt / 2x 取 84px，行图标 28pt / 2x 仍取 56px；气泡将真实 `iconSide` 传给图标视图。 | Geometry `testOptionIconVariantFollowsDrawnPixelSize`；Source `testTrendGesturesAndBubbleHoverHaveIdentityCallbacks`；`LightfieldOptionIconTests/testEveryOptionDecodesWithAlphaAndExactPixelSize`。`icon-variant-by-size`、`bubble-icon-84px`。 |
| P2：计划文档趋势高度 96 | `LIGHTFIELD-R2-PLAN.md` 明确内存绘图区 96、左轴 42、当前值槽 62；性能运行 48 属另一用法。新测试同时核对实际布局与计划文字。 | Native `testTrendMemoryDefaultAndCustomAxisKeepTheApproved96PointPlot`。新增 `trend-default-plot-height`、`trend-plan-plot-height`。 |
| P2：趋势悬停浮动气泡 | 默认 `hoverStyle = .bubble`，180pt 浮层、时间 / 值两行、sidebar 色、边界夹紧、禁止命中；保留可选旧 topLine。 | Native `testTrendLiveRefreshKeepsTheHoveredMomentAndShowsTheBubble`，核对浮层宽度和刷新后的同一时刻；Geometry `testTrendValueFormatsKeepPercentDefaultAndAddUnits`。`trend-bubble-default`。 |

### 本轮修改与红 / 绿证据

- `FeatureLightfieldChartGeometry.swift`：合并后的气泡按真实总量重新排序。红：把原断言“仅宽 ≥500 要求 14pt”加强到“宽 ≥216”，原代码在 30 个等值项 / 216×216 失败，最小半径约 12.6406pt，日志 `scratch/logs/review-fixes-new-tests.log`；修后该测试和新增“其他最大且居中”测试通过，日志 `review-fixes-new-tests-2.log` 及最终定向日志。
- `FeatureLightfieldComponentGeometryTests.swift`：保留面积比例、悬停包络、不重叠和原阈值；中心值断言从原输入表改为合并后的显示表，并增加必须为显示最大值的断言。依据为本轮复核要求“合并其他”和 D70 气泡图语义：合并项不再是原表单项。此为加强而非降低断言；无测试跳过。
- `FeatureLightfieldCharts.swift` / `FeatureLightfieldComponentTests.swift`：6 处沿用既有 `lightfieldComponentProbe`，本体探针在 `#if DEBUG` 内；加强性能趋势的真实曲线 / 图例 / 关闭节点 / GPU AX 值断言；新增内存默认 / 自定义 Y 轴及文档几何测试。未改变配置默认值、生产手势或功能页接入。
- 不可靠的原生鼠标派送试验未纳入最终补丁：在隔离 fixture 中合成 NSEvent 未驱动 SwiftUI 的手势，不能将其失败当作产品 P1 的红证据。试验补丁 `scratch/native-gesture-experiment.patch` 和 `review-fixes-gesture-3.log` 保留以供主会话调查。已提交的旧断言均保留；最终仍以几何与源码接线覆盖点击 / 拖选，真实鼠标事件实测 **NOT RUN**。

### 实际运行与沙箱边界

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox \
   --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b2/debug \
   --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build \
  --filter "$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b2/targeted-classes.txt)"
```

| 检查 | 本轮结果 | 证据 |
|---|---|---|
| 最终 Debug 构建含测试 | PASS，exit 0，14.88s | `scratch/logs/review-fixes-final-build.log` |
| 全部 10 类定向 | BLOCKED，exit 1；152 项 / 144 通过 / 8 测试失败 / 9 断言失败 / 0 跳过，22.049s | `scratch/logs/review-fixes-final-targeted.log` |
| UI 一致性、图标、二期几何 / 原生组件 / 源码契约、Release 源码隔离等 8 个类 | PASS；另外两个类仅下述环境失败 | 同上 |
| shell 语法、私有 API、diff 空白 | PASS：`bash -n` 两个打包脚本；`python3 script/check_private_api.py`（7 处白名单）；`git diff --check` | `prepared/review-fixes/static-checks.json` |
| 64 条文本反证静态预检 | PASS：id 唯一、片段出现次数、测试筛选名存在；执行 NOT RUN | 同上、`scratch/counterexamples.json` |
| JEV | BLOCKED；当前接口没有 model 参数，调用 `jev_decide` 返回 `MCP tool call requires approval, but approval policy is never`；没有判断结果，未换模型或绕过审批 | 本轮工具返回 |

主会话需在沙箱外复跑**原完整定向清单**，不能跳过以下 8 项；机器可写家目录夹具与 CFPreferences 时才能判断“全部通过”。失败列表也在 `scratch/sandbox-blocked-tests.txt`：

- `FeatureLightfieldContractTests/testLongUninstallListLaysOutOnlyVisibleRows`
- `FeatureLightfieldContractTests/testProductionCleanupGroupSelectionSpeaksItsState`
- `FeatureLightfieldContractTests/testProductionPilotsKeepNativeSkeletonAcrossThreeStatesSevenSizesAndTwoSchemes`
- `FeatureLightfieldContractTests/testProductionResultPagesEndAbovePrimaryWithoutHalfRowsAndShowHistory`
- `FeatureLightfieldContractTests/testProductionUninstallRowSelectionNeverOpensPreview`
- `FeatureLightfieldContractTests/testResultLongListFadesPartialRowsAndLastItemIsReachable`
- `TestPreferenceHygieneTests/testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`
- `TestPreferenceHygieneTests/testTemporarySuiteCanBeReopenedOnAWorkerThread`

前六项为 `NSCocoaErrorDomain 513`，底层 `NSPOSIXErrorDomain 1 / Operation not permitted`，无法在 `~/.storage-cleaner-scan-store-…/home` 创建操作夹具。后两项附近有 `sandbox_extension_issue_file failed …defaults.plist: 1 (Operation not permitted)`；CFPreferences synchronize 返回失败、未写入 plist。未改 HOME、偏好工厂、产品路径检查、真实文件或测试阈值，也未为这些失败新增跳过。

### 反证清单与提交准备

`scratch/counterexamples.json` 保留原 56 条并追加 8 条文本反证（现 64 条）；备份 `counterexamples-before-review-fixes.json`。每条继续使用 id/path/before/after/expected_occurrences/filter，新增项包括真实 GPU 曲线 / 图例 / 关闭色带 / 默认高度 / 计划高度 / 范围时间下限 / release 不带 JSON / 合并后最大气泡。主会话逐条执行，要求测试断言红而非编译错误，恢复后校验哈希；**本轮未执行变异**。

另在 `manual_counterexamples` 增加真实 PNG 体积反证，不混入文本执行器。`scratch/review-fixes-png-budget.py` 的 `--apply` 先核对原 PNG SHA-256、备份，再在 IEND 前加入合法 CRC 的 tEXt 块；不改 IHDR / IDAT / alpha。主会话按以下顺序操作（helper 本轮仅作语法检查）：

1. `python3 /Users/developer/Developer/.sc-build/r2-lf2-b2/review-fixes-png-budget.py --apply`
2. 单独跑 `LightfieldOptionIconTests/testEveryOptionDecodesWithAlphaAndExactPixelSize`，仍须绿；单独跑 `GeneratedArtTests/testEveryPictureDecodesWithAlphaAtItsExportedSizeWithinTheSizeBudget`，只应在“Option PNG budget”断言变红。既有 `png-budget-measures-bytes` 仅是预算阈值自检，不能代替此资产反证。
3. `python3 /Users/developer/Developer/.sc-build/r2-lf2-b2/review-fixes-png-budget.py --restore`，核对恢复哈希后复跑预算测试须绿。出现其他改动或恢复失败即停，保留备份，不自动覆盖。

本沙箱 `.git` 只读，**提交 NOT RUN**。保留原 `prepared/` 不覆盖；本轮单独放在 `scratch/prepared/review-fixes/`，基线 **d89ed724**，三组：`01-bubble-minimum`、`02-trend-verification`、`03-review-handoff`。含各组 patch/message、all.patch、manifest（分支、基线、最终文件和产物 SHA-256、顺序）、static-checks、反证清单 / helper / 定向清单及 `commit-prepared.py`。默认执行该脚本仅作只读核对；主会话完成沙箱外完整定向、反证和复核后才可加 `--validated` 分组提交。历史 prepared 的 f89de61e 基线不能用于本轮续接提交。

## 趋势选区时间戳下界补测（2026-10-10，续接 d89ed724）

本轮入口 HEAD 仍为 `d89ed724d0fa5381265483e89df100bf5f23d196`，原 5 个未提交修复文件均保留。修改前执行 review-fixes 的 `commit-prepared.py` 默认只读核对通过，随后将这 5 个文件、review-fixes prepared 和 scratch 反证清单备份到 `scratch/timestamp-lower-bound-before/`。本轮只在已有几何测试文件新增一个测试，并追加本节；两个产品源码及原生组件测试的已有修复逐字节保持。

主会话交回的**补测前**沙箱外结果已核对 `scratch/logs/main-final-0015/`：Debug 构建 PASS；定向 152/0；全量 4354/0（25 跳过）；文本反证 63/64。`mut/trend-selection-timestamp-lower-bound.log` 中变异构建成功，但旧筛选执行 1 项、0 失败，故该条反证 FAIL。这些是上一版证据，不能作为本轮新增测试或更新后的反证清单通过的依据。

### 原因与补强

原 `testTrendHoverAndRangeStayAnchoredToTimestampsAcrossRefresh` 的两个有效选区在刷新后都从索引 0 开始；因此把 `samples.firstIndex { $0.time >= times.lowerBound } ?? upper` 改为 `0` 仍满足所有旧断言。

新增 `FeatureLightfieldComponentGeometryTests/testTrendSelectionExcludesSamplesBeforeTimestampLowerBoundAcrossRefresh`，使用明确时间戳和不同的测量值，分别锁定索引范围、有效样本数及平均值（原精度 `1e-12`）：

| 场景 | 正确结果：范围 / 样本数 / 平均值 | 下界变异为 0 的结果（按夹具推算，非本轮执行证据） |
|---|---|---|
| 原窗口，时间 15…20 | 3…4 / 2 / 0.35 | 0…4 / 5 / 0.2 |
| 丢弃头两项并追加新样本，时间 15…20 | 1…2 / 2 / 0.35 | 0…2 / 3 / 0.3 |
| 刷新窗口，下界在采样点之间：时间 16…20 | 2…2 / 1 / 0.4 | 0…2 / 3 / 0.3 |

旧测试、钳制到首样本、全部移出窗口及 nil 断言全部保留，未改写任何既有断言、阈值或跳过条件；未修改产品下界算法。`scratch/counterexamples.json` 与 `scratch/prepared/review-fixes/counterexamples.json` 中仅将 `trend-selection-timestamp-lower-bound` 的 filter 指向新方法，id/path/before/after/expected_occurrences 保持，仍为 64 条文本反证及 1 条手动反证。

### 本轮沙箱内验证

下列日志均在 `scratch/logs/`；使用两份最新构建约定允许的 `--disable-sandbox -Xswiftc -disable-sandbox` SwiftPM 参数，未修改宿主权限。

| 检查 | 结果 | 日志 |
|---|---|---|
| Debug 编译含测试 | PASS，exit 0，14.20s | `timestamp-lower-bound-build.log` |
| 新增下界测试单项 | PASS，exit 0，1 项 / 0 失败 / 0 跳过 | `timestamp-lower-bound-single.log` |
| 原 10 类定向清单（含 UIConsistencyRegressionTests、TestPreferenceHygieneTests） | BLOCKED，exit 1；153 项 / 145 通过 / 8 测试失败 / 9 失败断言 / 0 跳过 | `timestamp-lower-bound-targeted.log` |
| 几何 / 原生组件 / 源码契约 / UI 一致性类 | PASS，分别 17/0、19/0、6/0、46/0 | 同上 |
| diff 空白、64 条反证片段和筛选名、prepared 补丁适用性与最终哈希 | PASS | `prepared/review-fixes/static-checks.json`、manifest 与只读提交检查 |
| JEV 复核 | BLOCKED；已核对接口没有 model 参数，`jev_review` 返回 `MCP tool call requires approval, but approval policy is never`；无判断结果 | 本轮工具返回、static-checks |

8 个环境失败仍为上一节逐项列出的 6 个 `FeatureLightfieldContractTests` 和 2 个 `TestPreferenceHygieneTests`：前者在创建家目录操作夹具时返回 `NSCocoaErrorDomain 513 / NSPOSIXErrorDomain 1`，后者的临时偏好域出现 `sandbox_extension_issue_file … Operation not permitted`，plist 未写入。实际失败名已核对与上一轮集合相同，并保留在 `sandbox-blocked-tests.txt`；不增加跳过、不改变测试工厂或路径安全检查。

### 主会话重跑与准备产物

正常代码的绿色验证命令（本轮已执行）：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b2
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox \
   --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b2/debug \
   --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build \
  --filter 'FeatureLightfieldComponentGeometryTests/testTrendSelectionExcludesSamplesBeforeTimestampLowerBoundAcrossRefresh'
swift test "${F[@]}" --skip-build \
  --filter "$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b2/targeted-classes.txt)"
```

**变异反证由主会话在沙箱外执行，本轮 NOT RUN**：按更新后的 JSON 对该 id 做唯一片段替换，将下界变为 `let lower = 0`；重新执行上面的 `swift build … --build-tests`（必须 exit 0，不能以编译失败充当红证据），再执行新单项测试，要求执行 1 项且出现范围 / 样本数 / 平均值断言失败，按夹具预期 9 个失败断言。恢复该产品文件并核对 manifest SHA-256，重新编译后单项必须恢复绿色。随后主会话按更新的完整清单复跑文本反证，并在沙箱外复跑 153 项完整定向，不能跳过 8 个环境阻断项。

`prepared/review-fixes/` 保持原 d89ed724 基线和三组顺序，重新生成组补丁、all.patch、消息及文件/产物 SHA-256；第一组包含同一几何测试文件中的气泡与本轮时间下界测试，第二组保留趋势原生组件验证，第三组包含交接。历史顶层 prepared 和补测前备份均保留。默认 `commit-prepared.py` 仅只读检查；`.git` 只读，**提交 NOT RUN**。

剩余限制：本轮未执行变异、全量、Release/Beta、严格并发、安装或实机交互；不声称反证已达到 64/64。JEV 无可用判断。本轮新增测试已编译并通过，剩余验证为沙箱外反证及环境阻断测试的复跑。
