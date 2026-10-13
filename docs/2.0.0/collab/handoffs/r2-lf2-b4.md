# r2-lf2-b4 · 卸载与应用更新

本批只交付呈现层、Debug 夹具、测试及准备补丁。构建、XCTest、截图、变异反证、提交、合并、安装均为 **NOT RUN**，由主会话按 `_prompts/common.md` 在沙箱外执行；静态检查结果见 scratch 的 `prepared/static-checks.json`。

工作区 `/Users/developer/Developer/sc-worktrees/r2-lf2-b4`，分支 `task/r2-lf2-b4`，实际基线 `396326b92394761fdad68922630368acfc995308`。本会话日志记录模型 `openai/gpt-6.1-sol`；没有切换模型或推理设置。

## 改动与数据流

- 卸载起始页：三个固定范围行复用 `LightfieldOptionRow`，分别使用 `uninstallApplication`、`uninstallContainers`、`uninstallRelatedFiles` 的 28pt 图标。没有新增可勾选范围或改变扫描范围。
- 卸载结果：保留原应用筛选、排序、搜索、拖入选择、箭头键、右键菜单、预览与历史入口。每行仍是 `Button { select(app) }`；图标为 `LightfieldAppIcon(path: app.path, size: .medium)` 的 24pt 真实路径图标，缺失时走 B2 灰色占位。版本移到名称下，路径用 `LightfieldPathText` 独立列中间省略、help/AX 保留完整内容。摘要改为“可审阅总量”，右侧显示当前筛选的应用数（不是写死 5）。总量沿用一期应用大小累计，没有增加关联文件预选或移动动作。
- 应用更新起始页：固定来源行复用四个 `opt-updater-*` 图标，不新增开关、不改来源偏好；上次检查的六个计数仍可查看，复用无卡片的计数组。本软件更新入口保留为文字按钮。
- 应用更新运行页：继续使用 `AppScanProgressSnapshot` 的阶段、已处理数、当前应用及会话 ID，复用 `FeatureRunningTemplate` 的光场分支。标题始终为“应用更新”，阶段在内容区显示；停止扫描仍调用原取消方法。
- 应用更新结果：标题恢复为“应用更新”；摘要取 `summary.scannedCount`；六个计数取原 Summary 分类，不自行重算系统应用的分类。系统管理项继续另行说明。列表取 `AppUpdateCatalogSnapshot(summary:).entries.filter(\.isUpdateAvailable)`，因此只有既有目录判定为已确认更新的应用进入列表及主按钮数量。版本未知但可打开应用内更新入口的项目继续留在“管理更新”，不冒称有更新。版本使用现有 `ApplicationVersion.display`，等宽、中间省略，help/AX 保留完整值。
- 更新主按钮保留原 `store.previewOneClickAppUpdates`，只设置待审阅计划；后续确认、安装、退出应用、授权、外部入口、版本复核全部走原流程。列表行打开既有管理页。“重新检查”“管理更新”“本软件更新…”以文字动作保留在结果列表末尾。
- B2 最小扩展：`LightfieldMetricGroup` 新增 `.inline` 数字＋标签布局，默认 `.stacked` 保持原用法；紧凑列的标签按 NSFont 实际测量选择字号，数值共用原缩放出口。`LightfieldSummary` 可由页面持有主插画，避免重复绘制；`LightfieldStatusGlyph` 可将“需授权”的锁符号着为告警色。新增共用 `LightfieldListRow`/`LightfieldApplicationColumns`，复用 52pt 行高、16pt 列间距、令牌、行按钮、细线及行顶位置上报。
- `FeatureLightfield.owns` 新增 updater，原三试点数组保持不变。Store、Service、Provider、安全规则、更新协调器和安装执行器均未修改；没有需要 Store 新增的字段。

## 原断言的调整

1. `FeatureLightfieldContractTests.testNewTemplatePilotAdaptersCompatibilityAndSafetyHaveNoDecorativeContainers`：旧断言剩余 11 条 V1 路由改为 10，依据 D69/D70、本批 updater 迁入 D67；所有几何、交互和禁止容器断言保留。
2. `ConceptLandingNativeLayoutRegressionTests` 的真实落地页夹具：把 updater 的旧 `HeroScanPage` 替身换成生产 `AppUpdateIdlePage`，带本软件更新动作的夹具也使用其真实文字入口。原尺寸、滚动可达、0.5pt 阈值未变。
3. `FeatureLightfieldReleaseIsolationTests` 的严格 Debug 文件清单加入 `FeatureLightfieldApplicationsFixture.swift`；未移除原断言。

新增 11 个测试方法，分布在 `FeatureLightfieldApplicationPageTests`（7）和 `FeatureLightfieldApplicationPresentationTests`（4）。覆盖三态、七尺寸、日夜、0.5pt 骨架、列表主按钮上方 24pt 边界、长应用名/版本/路径、图标尺寸、计数与摘要列、AXPress、未知/系统管理项、原预览入口及无安装调用。已有一期卸载 AX 测试继续覆盖单选只选中、主按钮开预览及关闭预览保留选择。

## 主会话验证

先按 RULES 准备本批私有离线依赖；本会话未复制依赖、运行 SwiftPM 或启动应用。定向类清单见 `/Users/developer/Developer/.sc-build/r2-lf2-b4/targeted-classes.txt`。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b4
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b4/debug --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b4/debug --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local --filter "$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b4/targeted-classes.txt)"
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b4/debug --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local
```

Debug 全量通过后才执行 `counterexamples.json` 的 9 个变异。每个变异的替换串、唯一出现次数和精确测试 filter 均已提供；在主会话的临时副本上逐条执行、保留红日志、恢复源码后重新构建并重跑对应绿测试。不得在真实工作区留下变异，不放宽阈值或跳过断言。反证覆盖列宽、24pt 图标、中间省略、真实更新过滤、原预览入口、48pt 横向组、标题、来源图标和 Release 隔离。

完整验证及 Release/Beta 配置隔离由主会话执行；规定脚本使用 bash：

```bash
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-lf2-b4/verify \
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 SWIFT_BUILD_JOBS=4 \
bash script/verify.sh
```

还需主会话实际构建 `STORAGE_CLEANER_BETA` 配置，确认新增 Debug 夹具未被引用；本批源码守卫不能代替实际 Release/Beta 构建。完成验证、独立复核后才使用 `prepared/commit-prepared.py --commit`。脚本默认只核对、拒绝基线/分支/文件/产物哈希或暂存区不匹配，不执行构建、安装或 push。

## 截图与视觉核对

沿用 `--debug-mini-window-demo-data --debug-feature-page=<uninstall|updater>:<landing|running|result> --capture-feature-templates` 及 `--capture-main-window-directory=<本批目录>`、`--capture-main-window-sizes=820x560,1000x700,1280x763,1680x1050,2400x1350,677x390,1280x390`。

- 加 `--debug-feature-applications-reference` 可将卸载结果的生产夹具切为 5 个、40.8GB 演示条目；不加时保留一期 36 行夹具，继续验证滚动到底及懒加载。
- 更新结果默认使用 7 个已检查、5 个有更新、`2/1/1/1/1/1` 六类计数的确定性值夹具。加 `--debug-feature-applications-stress` 使用长名称和长版本。
- 日夜分别用既有 `--debug-mini-window-appearance=dark|light` 参数，主会话核对实际参数效果并保存快照管线 JSON。与 `approved-20261009/renders/a/uninstall-result-*`、`updater-result-*` 对照，重点检查路径列、版本列、处理状态列、摘要及计数组。
- 夹具路径均为词法占位，截图可能显示统一灰色占位。真实图标需在实际已有扫描结果上只读核对；不能把夹具占位当作真实图标读取成功，也不能为截图启动扫描、卸载或安装真实应用。
- 首选使用本批 scratch 中的 Debug 包做离屏拍摄。不得替换或启动已安装的测试版、正式版；安装不属于本批授权。

## 基线前移与限制

准备交付时发现 B2 HEAD 已前移至 `9c6cc9e2e1672e786190185160b70530273f5198`。本批补丁仍以 `396326b9` 为基线；主会话重放/合并时需保留 B2 后续的选项图标 pointSize、趋势/气泡/分段进度改进及更严格的 UI 缩放守卫。本批 Components 的数值缩放仍为 6 处且全部带 `// lightfield-scale-ok`；新列表/状态文字不使用 `minimumScaleFactor`，没有放宽任何守卫。不要整文件覆盖较新的 Components。

JEV 决策调用为 **BLOCKED**：工具返回 `MCP tool call requires approval, but approval policy is never`。接口没有可传模型/推理参数的字段，本会话没有获得 JEV 推断或结果复核，不把该尝试列为通过。交付前完成的是人工源码复核与静态产物核对；Swift 6 类型检查、原生布局、AX、截图、反证、Release/Beta 与更新管理页后续流程仍需主会话执行。

## 补丁分组

1. `01-components`：B2 组件最小扩展、应用列与 updater 骨架所有权。
2. `02-app-pages`：卸载起始/结果及更新三态、真实目录展示适配。
3. `03-debug-fixtures`：严格 Debug 的应用组夹具及原截图工厂接线。
4. `04-contracts-handoff`：两类新回归、三处既有夹具/契约扩展与本交接。

每组补丁、提交说明、`all.patch`、最终文件/产物 SHA-256、基线、分支、组顺序及提交脚本均在 `/Users/developer/Developer/.sc-build/r2-lf2-b4/prepared/`。静态日志和结果由准备脚本生成；不得用其 PASS 推断 Swift 构建、测试、截图或安装已完成。

## 变基与验证轮（2026-10-10）

本节记录本轮实际状态；上文保留为基于 `396326b9` 的初稿历史。主会话已完成变基，进入本轮时工作区干净、无冲突残留：HEAD 为 `1d373beaf40b555161dfbe01fe1800f518067150`，父提交为集成基线 `d4136103`。本轮未再次变基；保留该基线中的 B2 最终组件、健康安全检查、真实功率和小窗采样。未修改 `ScanStore.swift`，没有需要 Store 新增的字段。

### 实际修改与根因

1. `FeatureLightfieldComponents.swift`：六项计数的一个窄窗场景中，每列实际为 58.194444pt；SwiftUI 将极长数字压缩后的文字宽度向上取整为 59pt，超过原有 0.5pt 包含阈值。仅在 `.inline` 的紧凑竖排候选中，把数值宽度固定到同一分数列宽并裁切。保留 24pt 数字、13pt 基准标签、48pt 高度、`minimumScaleFactor(0.5)`、AX 完整数值及 `.stacked` 默认布局。B2 共用组件 19 项、几何 17 项、源码 6 项均通过；六处缩放例外及阈值未变。
2. `SystemUtilitiesView.swift`、`FeatureLightfieldUninstallList.swift`：定稿卸载夹具为 40,800,000,000 字节。旧 `ByteFormat.string` 使用二进制单位，会显示 `38.0 GiB`，与定稿 `40.8 GB` 不同。本轮复用项目已有 `ByteFormat.storageString`，让卸载结果摘要、行大小、help 和 AX 标签统一使用十进制存储显示；夹具字节、排序、选择、预览、相关文件确认与卸载执行均不变。新增回归验证总量 `40.8 GB`、五行 `21.4/7.9/5.6/4.8/1.1 GB`，并守住三个展示出口。
3. 两个旧契约文件更新三条迁移后的源码写法；另更新一期卸载 AX 标签使用的大小格式。每条依据见下一节。`FeatureLightfieldApplicationPageTests` 只增强失败矩形诊断，保留全部断言和 0.5pt 阈值；极长数值测试现已通过。

本轮新增 1 个测试方法；加上初稿为 12 个。没有删断言、放宽阈值、新增跳过、变更测试偏好工厂或操作夹具位置。

### 逐条旧断言调整

| 位置 | 原写法与本轮调整 | 依据及保留的验证 |
| --- | --- | --- |
| `AppUpdatePresentationIntegrationTests.testHomebrewCommandIsAnAdvancedFallbackBehindOneClickUpdate` | 主按钮数量 `oneClickPlan.totalCount` → `presentation.entries.count` | D69/D70 定稿主按钮与直接列出的已确认更新数量一致；补充原计划可用性门控及 `onUpdateAll: store.previewOneClickAppUpdates` 断言。原高级备用命令、不执行显示文本、手动入口隔离断言全部保留。 |
| `SystemUtilitySafetyTests.testAppUpdatesDashboardShowsVerifiedUpdatesAndKeepsAutomaticBatchSeparate` | `HeroScanPage(` → `FeatureLightfieldPage(module: .updater, phase: .landing` | D67/D69/D70 要求 updater 使用 B2 光场骨架；原所有阶段、管理页、执行页、报告页、状态横幅及列表结构断言保留。 |
| `SystemUtilitySafetyTests.testAppUpdaterBatchButtonsCreateVerifiedAutomaticRequests` | `store.previewOneClickAppUpdates()` → `onUpdateAll: store.previewOneClickAppUpdates` | 同一方法改为回调引用，语义仍为先预览；批量请求次数、禁止直接执行和管理页隔离断言保留，并补充禁止管理页接入该回调的断言。 |
| `FeatureLightfieldContractTests.testProductionUninstallRowSelectionNeverOpensPreview` 的行标签夹具 | `ByteFormat.string(first.sizeBytes)` → `ByteFormat.storageString(first.sizeBytes)` | D70 卸载定稿使用 GB；AX 与可见行使用同一标准格式化出口。单选、预览、关闭预览保留选择等原断言保留。此方法本轮因家目录夹具权限未能到达原生 AX 验证，须主会话复跑。 |

### 构建与定向测试证据

日志根：`/Users/developer/Developer/.sc-build/r2-lf2-b4/logs/rebase-validation/`。机器可读结果为 `validation-results.json`，包含 18 个类、75 个失败用例的精确 filter、分类及日志。`collect-rebase-validation.py` 仅汇总已有日志，不运行或跳过测试。

| 检查 | 状态、退出码与结果 | 日志 |
| --- | --- | --- |
| 首轮 Debug，含所有测试目标 | **PASS**，exit 0，161.12s；无编译错误 | `build-initial.log` |
| 初次 18 类定向测试 | **FAIL**，exit 1；439 项、85 次失败断言、2 项既有跳过 | `targeted-initial.log` |
| 极长数字诊断复跑 | **FAIL**，exit 1；1 项、6 次边界失败，明确打印 59pt 数值 / 58.194444pt 列宽 | `metric-red.log` |
| 计数组修复后的构建及定向测试 | 构建 **PASS**，exit 0，29.49s；测试 **FAIL**，exit 1，439 项、76 次失败断言、2 项跳过；六次数值越界及三条旧契约转绿 | `build-final.log`、`targeted-final.log` |
| 十进制展示修复后的最终构建，含测试目标 | **PASS**，exit 0，44.04s | `build-storage.log` |
| 最终 18 类定向测试 | **FAIL**，exit 1；440 项：363 用例通过、75 用例失败、2 项既有跳过；76 次失败断言。其中 **74 用例 BLOCKED**、1 用例未解决，不能称全绿 | `targeted-storage.log` |
| 私有 API、`git diff --check`、补丁逆向适用性、文件与产物 SHA-256、反证替换次数和 filter | **PASS**，命令/结果写入本轮 `prepared/static-checks.json`；提交助手仅做只读核对 | `prepared/static-checks.json` |

最终通过的整类包括 `UIConsistencyRegressionTests`（46）、`FeatureLightfieldComponentTests`（19）、`FeatureLightfieldComponentGeometryTests`（17）、`FeatureLightfieldComponentSourceTests`（6）、`FeatureLightfieldApplicationPresentationTests`（5）、`FeatureLightfieldReleaseIsolationTests`（1）、`AppUpdatePresentationModelsTests`（16）、`UtilityPresentationPerformanceTests`（15）。本轮四项原失败回归及新增单位回归全部通过。

沙箱阻塞与未解决项：

- **BLOCKED：72 用例**在创建家目录下 `~/.storage-cleaner-*` 操作夹具时被拒（NSCocoa 513 / POSIX 1，`Operation not permitted`）。涉及 `AppUpdatePresentationIntegrationTests`、`ConceptLandingNativeLayoutRegressionTests`、`DebugAppUpdatePresentationFixtureTests`、`FeatureLightfieldApplicationPageTests`、`FeatureLightfieldContractTests`、`FeatureTemplateContractTests`、`SystemUtilitySafetyTests`、`UninstallExperienceTests`、`UninstallStoreWiringTests`。完整方法清单见 JSON；未改路径安全检查或夹具位置。身份替换测试在整类运行中报 `InvalidTransition`，单独复跑明确为家目录创建被拒，证据 `uninstall-isolated.log`。
- **BLOCKED：2 用例 / 3 次断言**：`TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory` 和 `testTemporarySuiteCanBeReopenedOnAWorkerThread`。日志显示临时绝对路径域的 `sandbox_extension_issue_file ... defaults.plist: 1 (Operation not permitted)`，偏好同步或 plist 存在性断言失败。本批未写真实偏好域；静态卫生守卫方法本轮通过。不得把整个卫生类记为 PASS。
- **FAIL / 未解决：1 用例**：`SystemUtilitySafetyTests.testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt` 在 `TestFileSystem.swift:72` 收尾中报 NSCocoa 4 / POSIX 2 `No such file or directory`。单独复跑 `uninstall-receipt-isolated.log` 仍为同一 ENOENT，未直接给出权限错误，不能武断归为已确认的沙箱阻塞。该测试及夹具工厂在本轮与 `d4136103` 对应代码一致；需要可创建家目录夹具的主会话环境复跑定位，本批未修改公共收尾逻辑。
- 原有 2 项跳过：只读实机 Setapp 清单需显式环境变量；卸载残留恢复用例需一次性已签名夹具。本轮没有开启真实扫描、构造真实应用或新增跳过。

最终使用的命令（主会话复跑同样的 18 类，不删掉受阻方法）：

```zsh
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b4
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b4/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b4/targeted-classes.txt)"
swift test "${F[@]}" --skip-build --filter 'SystemUtilitySafetyTests/testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt'
```

### 定稿结构与数值自查

指定的 `approved-20261009/renders/b/uninstall-*`、`updater-*` 实际不存在；b 目录为设置/文件页。本轮实际读取 a 目录的卸载、更新结果日夜四张 PNG，并核对 `mockups/a/shared.css` / `shared.js` 和生产源码。没有生成原生应用截图；以下是源码、定稿声明和已运行几何测试的核对，不能代表整页像素验收。

| 项目 | 核对结果与限制 |
| --- | --- |
| 共同骨架 | 规范标题 `(96,92)`、内容 `(96,176)`、主按钮 `(96,595,520,52)`；结果内容宽 878，摘要高 76，按钮上方 24pt；继续复用 B2。组件七尺寸几何通过；B4 整页三态矩阵在 Store 夹具构造阶段被阻塞，须主会话复跑。 |
| 卸载结果 | 行 52pt、真实路径图标 24pt、版本小字、独立中间省略路径列；基准名称/路径列为 250.5/417.5pt，大小列 96pt，勾选与图标首列合计 60pt。长名称/版本/路径在七尺寸日夜几何通过；5 个应用、40.8 GB 及五行大小经过标准格式化回归核对。摘要计数与主量在七尺寸不重叠。 |
| 更新结果 | 标题“应用更新”；7 个已检查、5 个确认更新，六类为 `2/1/1/1/1/1`。计数组高 48pt、基准间距 16pt、数字 24pt / 标签 13pt，窄窗紧凑排布。基准列为 `[24,380,274,146]` 加 48pt 间距及 6pt 尾部；版本等宽、中间省略、处理状态符号和文字。长版本/名称、计数组、更新行与主按钮 AXPress 均通过。列表与按钮接真实目录/原预览流程。 |
| 起始/运行 | 起始行 56pt、类别图标 28pt，卸载三行与更新四行源码映射正确；运行态仍接原进度与取消。B4 起始实际 Store 夹具及完整三态测试受阻，未声称截图或整个矩阵通过。 |
| 演示与真实数据 | 更新夹具沿用虚构名称、版本与词法路径；总数及处理类别符合定稿，但不把夹具图标占位或样本版本当作真实图标/已安装应用读回。真实生产数据仍按 Summary/目录派生，不写死定稿计数。 |

### 红 / 绿 / 反证及交付

本轮 scratch `counterexamples.json` 严格使用 `{ "mutations": [...] }`，共 **12 条**，全部核对替换串出现次数和精确方法 filter。保留原 9 条，新增：去掉紧凑数字固定列宽（1 处）、卸载摘要退回二进制格式（1 处）、卸载行/help/AX 退回二进制格式（3 处）。**反证 NOT RUN**，遵守 `codex-build-common.md` 由主会话在临时副本执行；不在本工作区留下变异。

- 计数组红：`metric-red.log` 已实测 1 项 / 6 次失败；绿：最终长数值几何与完整 AX 标签通过。反证 `updater-compact-value-width` 回退该调用，保持同一 0.5pt 阈值。
- 三条迁移契约红：初次定向日志各 1 次失败；绿：最终同方法通过。保留既有主按钮改接管理入口/结果标题改“扫描完成”等反证，验证原预览入口与功能标题。
- 卸载单位修复由定稿十进制字节与旧 `ByteFormat.string` 的二进制换算差异定位；绿：新增 `testUninstallApprovedAmountsUseTheSameDecimalStorageFormatterInSummaryRowsAndAX` 通过。两条新单位反证将明确触发该方法的实际展示出口断言；这里未执行变异红测试。

本轮 `prepared/` 为在已提交的变基初稿 **`1d373bea` 之后**应用的增量，分四组：`01-metric-bounds`、`02-uninstall-storage-units`、`03-rebased-contracts`、`04-rebase-handoff`。包含分组补丁/提交说明、`all.patch`、基线/组顺序/最终文件与产物 SHA-256、只读核对的 `commit-prepared.py`、`static-checks.json`、验证结果及反证规范。原基于 `396326b9` 的包逐字节保留于 `prepared-initial-396326b9/`；不要重放旧包覆盖 B2 最终组件。生成脚本是 scratch `prepare-rebase-delivery.py`。

提交 **NOT RUN**：实际 index 位于 `/Users/developer/Developer/StorageCleanerMac/.git/worktrees/r2-lf2-b4/index`，超出本会话可写根。主会话在完成受阻测试、定位 ENOENT、反证及独立复核后，先运行 `python3 prepared/commit-prepared.py` 核对，再用 `--commit --validated` 按四组提交。脚本拒绝基线、分支、暂存区、文件/产物哈希及改动范围不匹配；不会重置、安装或 push。

Release/Beta 实际构建、严格并发单独构建、全量 `script/verify.sh`、新原生截图、反证执行、独立复核、合并、安装均 **NOT RUN**，仍由主会话完成。Debug/Release 夹具隔离源码守卫已通过，不替代实际配置构建。

JEV **BLOCKED**：本轮核对的 `mcp__jev__jev_decide` schema 不提供模型或推理参数入口；调用被自动审批策略拒绝，原文 `MCP tool call requires approval, but approval policy is never`，没有取得判断。没有切换当前模型或推理设置，不把该尝试作为复核通过证据。


## fix1 · 原生更新页光场探针与紧凑数字反证（2026-10-10）

本节覆盖本轮实际交付状态。进入时 HEAD 为 `1d373beaf40b555161dfbe01fe1800f518067150`，分支 `task/r2-lf2-b4`；9 个未提交文件全部匹配上一轮 `prepared/manifest.json`。本轮增量基线是 **当前 HEAD＋上一轮 prepared 四组（按原顺序）**，不是纯 HEAD。前置 prepared 的文件、补丁、提交说明及 manifest 原样保留；没有变基、提交或修改真实 index。

### 核实的路由、探针与同类审计

- `AppUpdateIdlePage` 与 `AppUninstallScanLandingView` 的起始态均直接构造 `FeatureLightfieldPage`，不受 1024×734 的旧 concept 分支控制。`FeatureLightfield.owns(.updater/.uninstall)` 均为真。`AppUpdaterView` 的 `.idle(saved)` 仍经原 Store 状态机提供上次统计，本轮没有改路由、状态机或执行流程。
- 主会话 `logs/main-final-0804/targeted.log` 的失败帧已经有 `lightfield.canvas/title/content/primary/status`、`lightfield.options.scrollViewport/optionsEnd` 及六列 `lightfield.updater.previousMetrics.*`；缺的是旧探针。因此不是页面误路由。日志里 fixture 是 1024×734，实际光场 canvas 是 1024×706（上方 28pt Debug 演示提示），本轮包含检查使用真实 canvas 坐标，不能把 fixture 高度当 canvas 高度。
- `testActualInertUpdaterLastCheckKeepsFiveStatisticsAndManageButtonAtNarrowWidths`：迁到真实光场帧与 AX 语义，原 Store 的惰性/禁扫描/禁安装断言保留。函数名保留，原五项全部保留，另加未知计数。
- `testPublicUpdateLandingKeepsFourRealSourcesAndReachableActionsWhenReflowing`：发现其仍以 `HeroScanPage` 模拟 updater，虽旧测试能绿，却不覆盖迁移后的生产页。本轮也迁到真实 `AppUpdateIdlePage`，保留六次尺寸变化、中英两种语言、四个来源均存在、逐项可达、主按钮可按及每次只记一个检查回调。
- `testEveryLandingPageFitsInTheRealPageContainerAcrossTheSizeSweep`：既有 `FeatureLightfield.owns(page.route)` 分支已取光场探针，真实卸载、updater、updater＋本软件更新三种夹具均已接线，无需再改。其余四个方法覆盖能耗、兼容/安全/开发列或智能扫描/安全清理，无 B4 已迁移生产页遗留。本轮不改变这些用例。

### 改动文件及逐条断言依据

本轮只修改三份代码/测试并追加本交接；上一轮的其他文件保持原样。

1. `Tests/StorageCleanerMacTests/ConceptLandingNativeLayoutRegressionTests.swift`：
   - 探针映射：`concept-landing.canvas/header/action-panel/action-button/footer` → `lightfield.canvas/title/content/primary/status`；`landing.optionsViewport` → `lightfield.options.scrollViewport`。依据 D67 的单一骨架和生产页面实际发布的帧，不补回已经废弃的旧探针。
   - `landing.optionsContent` 的包含对象迁为真实 `NSScrollView.documentView.bounds` 转换到 hosting view 的矩形（新 `optionsDocumentFrame`）。这继续验证整个自然滚动文档的包含关系，不能拿裁剪后的 viewport 替代文档；AX 与探针均使用同一 native 坐标。
   - 原 `assertLandingReachability` 所验证的 fixture 宽高准确度 **1pt**、主按钮和底部行的 viewport/canvas 包含容差 **1pt**、主按钮不得越过底部行的 **1pt** 容差及按钮高度 **>40pt**，在新的光场 helper 中逐条保留；原 helper 继续用于未迁移旧布局的用例。原八次尺寸及中英语言不变。
   - 原五个 `summary.*Count` 仍各自作为预期值，未从被测 adapter 反推预期。D69 的生产 `LightfieldMetricGroup` 使用 `children: .ignore`，数值属于完整 AX 标签 `标签 · 数值 单位`，没有单独的 AX value。原 value 相等断言因此迁为实际 AX label/title 与独立期望完整串相等；本地中文名称同步生产的“退出后更新/需授权/需手动”，不是删掉标签或数值校验。第六个 unknown 也按独立 Summary 计数加入。
   - 六个统计 AX 矩形仍必须在自然文档 **1pt** 容差内，两两不得重叠。增加每列数字/标签的 **0.5pt** 包含及计数组 **48pt/0.5pt** 高度检查，不能只靠完整 AX 字符串掩盖可视越界。
   - 管理按钮必须在文档和滚动后 viewport 的 **1pt** 容差内，宽度 **>70pt**、高度 **>20pt** 原封不动；新增按钮与每个统计矩形不得相交及原生 button/press 能力检查。测试只检查可按能力，不执行管理、扫描或安装动作。
   - 公开来源用例的旧 1/2 列网格、同排 y 相等、横向至少 7pt 间隔、下一排至少 5pt 间隔，按 D67 第 2 节改为生产的 **四个连续 56pt 行**：每行高度 56/0.5pt、同行列起点 x 相等/1pt、后一行 minY 等于前一行 maxY/0.5pt。旧网格几何不适用于已获批的光场行，新的准确度没有放宽。
   - 公开来源从旧 `App Store/Sparkle/官网/Homebrew` 替身标签改为生产的“软件包线索/App Store/应用内更新源/开发者官网”；仍是四种来源，不改来源偏好或 Provider。
   - 旧“全部尺寸都不滚动”的 `overflowing == false` 改为实际文档高度与实际可用高度的 overflow 判定一致；D67 第 7 节明确短窗内容区内滚动。每个来源都必须通过真实 scroll container 滚到可见且完全在 **0.5pt** viewport 包含容差内，然后读原生 AX。原文档 **1pt** 包含、四个来源存在、检查按钮 AXPress 和六次回调总数均保留。无溢出时不许提示，滚到底后无更多内容提示的 `XCTAssertFalse` 也保留。
2. `Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift`：给“管理更新”的文字 label 加最小 **72×24pt** 点击区域，保持 13pt 字体、光场 row button style、原 `onManage` 回调及原色彩。原文字按钮没有显式点击面积；迁探针后仍须守住原 >70/>20 断言，不能放宽测试来迁就文字固有尺寸。本项只改呈现区域；包含上次统计的 Store 用例在沙箱内仍受阻，所以此点击区域的实际 native AX 读回仍须主会话证明。
3. `Tests/StorageCleanerMacTests/FeatureLightfieldApplicationPageTests.swift`：保留七尺寸、正常/极长数值、48pt 高度、数字/标签 **0.5pt** 包含及完整 AX 标签；对实际竖排紧凑分支增加数字 minX/width 与所在分数列相等/0.5pt。另在原方法内限定 `LightfieldMetricGroup` 和 `inlineValue` 声明，守住紧凑候选传列宽以及数值 frame/clipped 的源码契约。
4. 本交接追加 fix1；没有修改 `ScanStore.swift`、卸载实现、扫描范围、选择、安全检查、卸载或更新执行路径，也没有新增 Store 字段。

### 反证证据与修后检测能力

复查主会话证据后需纠正原因：`logs/main-final-0804/mut/updater-compact-value-width.log` 的变异目标实际是 **1 项、0 失败**，即变异存活；它不是因 `ConceptLandingNativeLayoutRegressionTests` 的既有失败而红/绿不可判。`mut/summary.json` 也记录 `FAIL [1,0]`。另一个旧探针失败是独立问题。

`updater-compact-value-width` 的 path、before/after、expected_occurrences=1 和 filter **全部保持不变**：

- `before`: `inlineValue(metric, width: width)`。
- `after`: `inlineValue(metric)`。
- `filter`: `FeatureLightfieldApplicationPageTests/testSixInlineMetricsContainLongValuesAndReadTheirCompleteLabels`。

该精确替换会移除紧凑候选唯一的列宽实参；同一目标方法新增的限定声明断言必须失败，并报告 `Compact numbers must receive their fractional column width`，不依赖此屏幕 backing scale 恰好把 Text 向外还是向内取整。仍保留原生包含断言以检测实际溢出，并校验紧凑数值实际 frame 的完整列宽。不能把源码约束红等同于每台机器都出现同样的原生取整越界。

静态检查 **PASS**：12 个变异的替换次数及 filter 各自精确命中；限定 compact 声明在精确替换后确实失去被要求的实参调用，证据 `logs/fix1/counterexample-anchor-checks.json`。本轮未执行真实源码变异、未做变异构建/XCTest，不将静态判断记为反证通过。修后该目标方法在真实 native host 的沙箱内绿测试已通过。

### 沙箱内实际验证

统一环境与 flags：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b4/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b4/targeted-classes.txt)"
```

| 检查 | 状态与结果 | 日志（scratch） |
| --- | --- | --- |
| 最终 Debug 构建，含全部测试目标 | **PASS**，exit 0，5.83s；首轮及中间构建也通过 | `logs/fix1/build-delivery.log` |
| 最终 18 类定向 | **FAIL**，exit 1，440 项：363 通过、75 失败、2 项既有跳过；76 次失败断言，35.572s | `logs/fix1/targeted-delivery.log` |
| 生产公开更新来源用例 | **PASS**，中英、六次尺寸变化、四个 56pt 来源行的原生 AX/滚动和主按钮回调 | 同上，`testPublicUpdateLanding…` |
| 紧凑数字正常/长值用例 | **PASS**，保留原生 0.5pt 边界并增加列宽契约 | 同上，`testSixInlineMetrics…` |
| 原 Store 上次检查用例 | **BLOCKED**：`ScanStore.makeForTests` 创建操作 home 时报 NSCocoa 513/POSIX 1，未到新原生布局断言 | 同上，`testActualInertUpdater…` |
| 私有 API、diff 空白、12 个反证锚点/filter | **PASS**，private API exit 0；diff exit 0 | `logs/fix1/private-api.log`、`prepared/fix1/static-checks.json` |
| 前置四组＋fix1 补丁临时目录重放与最终文件 SHA-256 | **PASS**；默认 `--check-only` 与 `--validated --check-only` 均只读，无真实 index 写入 | `logs/fix1/commit-prepared-check.log`、`commit-prepared-validated-check.log` |

最终失败用例按当前日志保守分类：**71 项**直接记录家目录夹具 `Operation not permitted`；**2 项**偏好测试对应临时 plist 的 sandbox extension 失败；**1 项**卸载身份测试是继承的 `InvalidTransition { idle → failed(deinit) }`，本轮整类日志未直接给出 permission 根因；**1 项**卸载回执测试是继承的收尾 NSCocoa 4/POSIX 2 ENOENT。后两项本轮不冒称已定位或修好。之前沙箱外主会话日志除旧探针一项之外已通过全部定向用例；该记录不是 fix1 的绿验证。所有失败方法/分类/行号及实际代码 SHA-256 在 `validation-results.json`；没有改夹具位置、放宽路径安全或加入 skip。

整类通过包括 `UIConsistencyRegressionTests`（46）、`FeatureLightfieldComponentTests`（19）、`FeatureLightfieldComponentGeometryTests`（17）、`FeatureLightfieldComponentSourceTests`（6）、`FeatureLightfieldApplicationPresentationTests`（5）、`FeatureLightfieldReleaseIsolationTests`（1）、`AppUpdatePresentationModelsTests`（16）与 `UtilityPresentationPerformanceTests`（15）。`TestPreferenceHygieneTests` 的源码卫生守卫通过，整类因上述两项不能记 PASS。

### 主会话红/绿/反证与提交交接

1. 红依据保留在 `logs/main-final-0804/targeted.log`（440/1）和 `full.log`（4478/1），均在真实 1024×734 上因旧探针缺失失败；无须再次改回源码以制造相同红。compact 原反证存活日志也保留。
2. 在沙箱外先运行上述最终构建和 18 类定向，优先单独绿验证：

```bash
swift test "${F[@]}" --skip-build --filter 'ConceptLandingNativeLayoutRegressionTests|FeatureLightfieldApplicationPageTests'
```

必须证明实际 Store → idle 页的五项统计、unknown、管理按钮点击区域/可见性/不重叠及窄列包含全部通过；沙箱内的公开来源绿测试不能代替这一项。
3. 沿用主会话的隔离副本反证流程，读取 **`prepared/fix1/counterexamples.json`**，12 个规格没有改变。先确保 fix1 的全部对应目标在无变异源码上绿，再依次精确替换、构建、跑各 filter、记录真正失败的断言并恢复。尤其 compact 必须得到上述明确的宽度实参契约失败，不能接受缺探针、家目录权限、编译失败或基线本来失败作为有效红。恢复后重建并确认同一 filter 再绿。本轮反证执行 **NOT RUN**。
4. 主会话按原流程补全 Debug/Release/Beta/严格并发、全量门禁、必要截图与独立复核。fix1 这些项目均 **NOT RUN**，不复用旧主会话全量结果冒称 fix1 已全绿。
5. `prepared/fix1/all.patch` 只含本轮两个增量组：`01-updater-native-contracts`（呈现目标＋两份测试）和 `02-fix1-handoff`；基线为 HEAD＋上一轮四组。`prerequisites/` 保存前置四组及 manifest，`replay-all.patch` 可从原 HEAD 重放六组。不要把 fix1 all.patch 当成纯 HEAD 补丁，也不要再用父目录旧助手核对已经变动的最终文件。

```bash
python3 /Users/developer/Developer/.sc-build/r2-lf2-b4/prepared/fix1/commit-prepared.py --check-only
python3 /Users/developer/Developer/.sc-build/r2-lf2-b4/prepared/fix1/commit-prepared.py --validated --check-only
# 仅主会话全部验证与独立复核完成后：
python3 /Users/developer/Developer/.sc-build/r2-lf2-b4/prepared/fix1/commit-prepared.py --commit --validated
```

助手核对分支、空暂存区、改动范围、文件/产物哈希及临时目录重放。当前仍在原 HEAD 时，按上一轮四组＋fix1 两组提交；若主会话已按原四组提交，只有其 HEAD 内容逐文件准确匹配前置基线且无其他改动时，才提交 fix1 两组。`--validated` 只是主会话的验证确认参数，不运行验证，也不把 `--check-only` 变成提交。未传 --validated 的提交会拒绝；不自动 reset、清理、安装或 push。

JEV 复核 **BLOCKED**：本轮核对了实际可调用 `mcp__jev__jev_gate` 的 schema（没有模型/推理参数可传），调用返回 `MCP tool call requires approval, but approval policy is never`。没有取得 JEV 模型判断，证据 `logs/fix1/jev-status.json`。未为此更换模型或绕过审批限制；仍需主会话独立复核。


## fix2 · 原生滚动文档与宽度动画取帧时序（2026-10-10）

本轮进入时 HEAD 仍为 `1d373beaf40b555161dfbe01fe1800f518067150`，11 个未提交文件全部匹配 `prepared/fix1/manifest.json`。增量基线为 **该 HEAD＋原 prepared 四组＋fix1 两组**，前置包均原样保留。本轮只修改 `ConceptLandingNativeLayoutRegressionTests.swift` 并追加本交接；没有修改任何产品源码、Store、页面路由、滚动实现或执行逻辑。

### 查明的原因与可复核证据

主会话 `logs/main-final-0933/` 的定向 440、全量 4478 各剩 1 次失败，均为原 Store 上次检查用例的 `NSScrollView` 匹配为空；反证 `mut/summary.json` 已证明 fix1 **12/12 PASS**，其中 compact 的目标出现 48 次失败断言，不再存活。本轮不改变这 12 个规格或被变异的产品代码。

不是选项区域没有原生滚动容器，也不是“无需滚动时移除了 scroll view”。主会话失败前的 AX 诊断两次找到 `HostingScrollView`，并读出 `documentSubviews`（352pt 高）；生产 `FeatureOptionsScrollView` 无条件使用 `ScrollView(.vertical)`。普通大窗下自然内容可以全显示，但 native scroll view 仍然存在。

根因是 **宽度动画期间的探针/原生几何取帧时序不一致**。`FeatureLightfieldPage` 对 `geometry.content.width` 应用 560ms 的 completion 动画；原 Store 用例未设置其他几何夹具已有的 `featureDisablesLayoutAnimations=true`。`frames()` 等待的是 SwiftUI preference 稳定，AX wait 又会泵 native layout，不能用先前快照假定 native view 仍有同一宽度。

本轮新增不依赖 Store 操作 home 的生产页回归：真实 `AppUpdateIdlePage(lastSummary:)`，只以 `Color.clear.frame(height: 28)` 保持 Debug 演示提示的布局留白，保留原中英语言和八次尺寸变化，不模拟原生 scroll view 或 document。在修复前实际复现红：

```text
hostSize=(899.0, 734.0)
requested/latestProbe=(48.0, 189.5, 511.0, 380.5)
nativeFrames=[(48.0, 190.0, 512.0, 380.0)]
XCTUnwrap failed: expected non-nil value of type "NSScrollView"
```

证据 `logs/fix2/viewport-red-diagnostic.log`：1 项、1 失败，exit 1。实际 `NSScrollView` 存在，x 同为 48；其宽度仍为上一轮 900pt 画布的 512pt，而探针已经是 899pt 画布的 511pt。差值正好 1pt，被既有严格 `<1pt` 谓词正确拒绝。y 的 0.5pt 原生取整不是匹配失败条件（原匹配只比 x 和宽度）。探针已减去 fixture global origin，原生 bounds 也已 convert 到同一 `controller.view`；没有发现固定坐标系偏移，故没有再加一次转换。

### 最小修复及不变的断言

1. 仅为原 Store 几何用例设置 `.environment(\.featureDisablesLayoutAnimations, true)`，沿用其他 D67 几何夹具的静态布局口径。该用例验证尺寸、AX、包含和可达性，不承担 560ms 动画验收；没有改生产动效常量或页面行为。
2. 将 AX wait 前的帧命名为 `accessibilityFrames` 供 hit-test 定位；AX wait 完成后重新调用原 `frames(required:size:)`，用随后发布的 `frames` 做原生文档与 AX 包含检查。没有延长等待预算、增加重试或改变稳定采样数。
3. 新增 `testUpdaterLastCheckViewportMatchesNativeDocumentAfterAXAcrossResizes`，使用上述真实生产页及 28pt 留白，也按相同静态几何/AX 顺序观察真实 document。覆盖原八次尺寸、中英两种语言，并保留 document 对管理按钮的 1pt 包含。它不调用扫描/管理，只验证 press 能力；不能代替原 Store → idle 状态机用例。
4. 为 `scrollView(matching:)` 的失败分支增加实际 requested/latest probe/native scroll frames 与 host size 的诊断；匹配谓词仍是原 `abs(minX差)<1` 与 `abs(width差)<1`，没有改为 `<=1` 或扩大范围，也没有“找不到就选第一个”或“不需要滚动就默认通过”的回退。

静态核对 **PASS**：原 Store 用例的全部 `XCTAssert` 行逐行一致；`optionsDocumentFrame(matching:)` 的文档转换声明逐字不变；严格 `<1pt` 匹配表达式与整个 `frames(required:size:)` 等待实现均保持原样。原五项计数＋unknown、48pt 统计组、数字/标签 0.5pt 列内包含、统计互不重叠、管理按钮 >70/>20、文档/viewport 的 1pt 包含及惰性状态断言没有删除或放宽。证据 `prepared/fix2/counterexample-anchor-checks.json`。

关闭夹具动画并在 AX 后重取帧后，同一回归绿：`logs/fix2/viewport-stability.log`，1 项、0 失败，exit 0，1.382s。最终 18 类运行中该回归再次通过，1.307s，且没有 native viewport mismatch。

### 实际验证与边界

环境和 flags 延续 common：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b4/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b4/targeted-classes.txt)"
```

| 检查 | 状态及结果 | scratch 日志 |
| --- | --- | --- |
| 最终 Debug 构建，含全部测试目标 | **PASS**，exit 0，5.33s | `logs/fix2/build-final.log` |
| 无家目录依赖的 native 文档回归 | 红 **FAIL**（预期），1/1；修后绿 **PASS**，1/0 | `viewport-red-diagnostic.log`、`viewport-stability.log` |
| 最终 18 类定向 | **FAIL**，exit 1，441 项（新增 1 项）：364 通过、75 失败、2 项既有跳过；76 次失败断言，36.244s | `logs/fix2/targeted-final.log` |
| 原 Store 上次检查用例 | **BLOCKED**，操作 home 创建报 NSCocoa 513/POSIX 1，未执行到新布局断言 | 同上，`testActualInertUpdater…` |
| 源码守卫、断言/阈值保留、12 个锚点/filter、diff 空白 | **PASS**；私有 API exit 0 | `private-api.log`、`counterexample-anchor-checks.json`、`static-checks.json` |
| 基线前置六组＋fix2 两组临时重放与最终哈希 | **PASS**；两种 check-only 均只读 | `logs/fix2/commit-prepared-check.log`、`commit-prepared-validated-check.log` |

75 个失败用例与 fix1 沙箱运行分类一致：71 项直接为家目录夹具 `Operation not permitted`，2 项为临时偏好 plist 的 sandbox extension，另有继承的 `InvalidTransition`、收尾 ENOENT 各 1 项，后两项本轮未重新定位。`validation-results.json` 记录方法/行号及最后受测代码 SHA-256。8 个整类通过仍包括 UIConsistency（46）、共用组件（19）、组件几何（17）、组件源码（6）、应用呈现（5）、Release 隔离源码（1）、更新呈现模型（16）和工具呈现性能（15）；TestPreferenceHygiene 的源码守卫通过，整类因上述两项受阻不能记 PASS。

首轮临时诊断字符串有 Swift 插值语法错误，`build-red.log` exit 1；在运行红用例前已修正，后续诊断构建、修复构建和最终构建全部通过。保留该日志，不将编译失败算作上述有效红。

本轮全量、真实变异、Release/Beta、单独严格并发、截图、提交、合并、安装均 **NOT RUN**。主会话 fix1 的 12/12 反证已核实；它不是 fix2 的全量或实际 Store 绿证明。

### 主会话复跑与 fix2 交付

在沙箱外优先重建并跑两个用例：

```bash
swift test "${F[@]}" --skip-build --filter 'ConceptLandingNativeLayoutRegressionTests/(testActualInertUpdaterLastCheckKeepsFiveStatisticsAndManageButtonAtNarrowWidths|testUpdaterLastCheckViewportMatchesNativeDocumentAfterAXAcrossResizes)'
```

随后跑定向和全量。必须证明原 Store 用例所有统计、按钮和惰性断言全部通过；若仍有 native 匹配失败，新增诊断会给出实际 probe/native frame/host size，不能把沙箱中新值夹具的绿替代 Store 用例。定向现在应包含新增 1 项；数量以实际日志为准。

`prepared/fix2/` 是两组增量：`01-scroll-geometry-sync`（一份测试文件）、`02-fix2-handoff`（本节）。`all.patch` 仅含 fix2，不能直接对纯 HEAD 应用；`prerequisites/` 保留原四组＋fix1 两组和 fix1 manifest，`replay-all.patch` 可从原 HEAD 顺序重放八组。原 prepared 与 fix1 包均不覆盖。最终文件、基线文件和产物 SHA-256、组序、测试结果及反证锚点见 fix2 manifest/JSON。

```bash
python3 /Users/developer/Developer/.sc-build/r2-lf2-b4/prepared/fix2/commit-prepared.py --check-only
python3 /Users/developer/Developer/.sc-build/r2-lf2-b4/prepared/fix2/commit-prepared.py --validated --check-only
# 主会话完成实际 Store 绿验证、门禁及独立复核后：
python3 /Users/developer/Developer/.sc-build/r2-lf2-b4/prepared/fix2/commit-prepared.py --commit --validated
```

助手当前可从原 HEAD 按前置六组＋fix2 两组提交；若前置六组已经提交，必须 HEAD 内容精确匹配其基线且无额外改动，才只提交 fix2 两组。默认只读，拒绝未 validated 的提交；不写真实 index 做 check，不自动 reset、清理、安装或 push。当前 HEAD 与真实 index 未变。

JEV 本轮复核 **BLOCKED**：核对实际 `mcp__jev__jev_gate` schema（无可指定模型/推理参数），调用仍返回 `MCP tool call requires approval, but approval policy is never`，没有获得判断。记录在 `logs/fix2/jev-status.json`；主会话仍需独立复核。
