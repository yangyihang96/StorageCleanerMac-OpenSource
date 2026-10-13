# r2-lf2-b7：光场文件分析、文件搬家、重复文件、相似照片

日期：2026-10-09。worktree `/Users/developer/Developer/sc-worktrees/r2-lf2-b7`，分支 `task/r2-lf2-b7`，基线 `396326b92394761fdad68922630368acfc995308`（task/r2-lf2-b2 HEAD），scratch `/Users/developer/Developer/.sc-build/r2-lf2-b7`。

**初稿轮状态（2026-10-09；本轮结果以下文“变基与验证轮”为准）：呈现源码、测试源码、反证描述与分组补丁已准备；Swift 编译、XCTest、AX 实测、变异反证、日夜截图／像素对照、严格并发、Release/Beta 构建与提交全部 NOT RUN。** common.md 明令本 Codex 沙箱只能准备源码、测试与交接。静态核对见 prepared/static-checks.json；不能代替编译或实机验收。没有安装、启动应用、真实扫描／移动／清理、写真实偏好或提交。

## 实际改动

- 三个文件路由加入 FeatureLightfield.owns；一期三个 pilots 数组保持不变。ContentView 的分析／搬家结果不再套旧 FeatureDataPageShell，页面本身拥有统一骨架。四页起始／运行态沿用 B2、D67，起始选项使用 NOTES 指定图标。相似照片继续由 DuplicateFilesView 的 `.similarImage` 过滤入口呈现，没有新增独立 sidebar enum。
- 文件分析：新增 FileAnalysisLightfieldView，替换生产入口的矩形树图。左侧“目录／文件类型／最大的文件”；目录 52 pt 行有安全勾选、24 pt 类型图标、色点和 3 pt 占比条；类型使用 132 pt Donut 与可按下图例、点击高亮同类气泡；最大文件从完成索引取前 8 个，不另走文件系统。右侧 Bubble 复用 B2 的确定性布局，点击目录下钻、面包屑返回、hover 双向联动列表。目录宽344、图形宽510、间隔24、高268；窄屏上下排列并整体滚动。底部磁盘用量条。主按钮数量来自原 trashSelections，启用来自原 canReviewTrash，仍打开原 FileAnalysisTrashReviewSheet。
- 分析保留失败重试、Finder／快速查看／复制路径的显式菜单，以及选择与操作详情中的清除选择、通知关闭、跳过原因、外接盘恢复说明、回执失败／不完整提示。不会只把回执异常概括为“已移动”。大小、类型、排名、文件计数均来自已有不可变分析索引；类型／排名针对根索引，目录视图保留当前导航层。`inspectedItemCount` 含目录，摘要和 Donut 文件计数改为非目录 indexed entries。
- 文件搬家：目标盘图标、名称、可用量和细条；按类型／修改时间／位置分组，组头三态勾选、大小／数量与独立折叠状态；六列布局固定勾选、图标、日期、大小、行尾操作，名称／中间省略路径让出空间。已复制／已迁移／恢复原件／原处被替换仍读 workspace.migrationCompletions。应用使用 B2 LightfieldAppIcon 的24 pt缓存图标。行尾提供原复制确认、原件单独处理、原件／已校验副本定位和既有安全移到废纸篓入口。
- 重复文件：组头可折叠、保留份标记、SHA-256确认副本勾选、路径／日期／大小／行尾菜单；逻辑重复量与待确认的物理释放量分别显示。清理仍调用原 requestVerifiedDuplicateCleanup，原确认／恢复 sheet 留在 DuplicateFilesView 宿主。筛选、排序、候选规则、隔离区入口、取消剩余项目、扫描覆盖／执行详情保留。保留最新按钮在缺失或未来修改日期时禁用。
- 相似照片：组头、四列自适应照片网格、真实 SimilarImagePreviewCache 预览、建议保留、快速查看／Finder，以及本地人工比对标记。不可用预览明确提示，Debug 夹具不读取照片。相似候选不能进入安全清理的原边界不变，主清理按钮禁用。
- B2 最小扩展：可选页／摘要 artwork（相似照片）；页底可选文字操作按钮；OptionRow 增加标题／元数据探针及中间省略元数据列；DataBar 新 `.share` 高3 pt平色（既有 ratio=2／progress=6）；ChartItem 可选类型令牌色与完整 detail；Bubble 接收外部 hover 与强调 ID；Donut 可选点击图例。新 FeatureLightfieldFileComponents 只提供摘要／结果滚动容器、三态勾选、组头与六列布局。颜色仍单一归属 FeatureLightfieldPalette，骨架、尺寸与动画表未另造。
- Debug 结果夹具严格全文件 `#if DEBUG`，直接使用生产 value-only bodies，没有 ScanStore、扫描器、文件操作、外接设备或 Finder 回调。分析样本185.4 GB／16文件／24访问项目，搬家样本12项17.3 GB来自确认JS但路径改为 `/Fixture`，重复／相似样本用完成索引或值对象。新增分析 types／largest 参数与 capture 元数据；测试可独立注入相似照片和分析分段，不依赖进程参数。生产起始页的夹具 task 不调用外接盘刷新。

`Stores/ScanStore.swift`、服务、索引和安全模型没有修改。LargeFilesView 的 `migrationConfirmationText`、`startMigration`、`moveOriginalToTrash` 与基线逐函数静态比较；结果见 static-checks.json。

## 已知边界与需要 Store 提供的字段

1. **文件修改时间不足。** StorageItem、StorageMapIndexedEntry、ExternalMigrationItem 没有修改日期；InstalledAppItem 的可选 modifiedAt 可接入。展示适配器保留 nil，文件行显示“未知”，不在 View 中同步 stat、不按名称或顺序推算“最新”。“一年以上未修改且至少1 GB”只选已知、非未来的日期；当前普通文件数据下此快捷按钮禁用。要让生产功能可用，后续由数据拥有批次提供扫描时记录的修改时间并保持对应路径／身份。
2. **搬家没有现成批量执行器。** 勾选与分组属于本地审阅计划，主按钮为“审阅复制计划 · X”。审阅后逐项进入原 pendingMigration 确认；没有添加自动队列、自动删除原件或绕过 D61。效果图的批量按钮只落到这一安全审阅入口；自动批量复制需要独立行为批次。
3. **相似照片候选没有经确认的删除能力。** 新勾选为明确标注的“比对标记”，仅本地 View state；不调用 DuplicateFilesStore.setSelected，不能驱动删除。未落实效果图中的候选垃圾桶操作；需要后续单独的人工确认／身份复核契约，不能本批放宽现有安全流程。
4. **相似照片不是独立扫描模块。** 继续使用重复文件的真实扫描范围、候选规则和 `.similarImage` 结果入口。Pictures／Downloads 图标行目前是范围说明，真正范围经现有菜单／添加文件夹设置；没有伪造两项独立开关。若需要独立起始页选项，须由 Store 提供对等 scope 字段和扫描能力。
5. **Debug 示例不是真实照片或扫描证明。** 照片夹具显示“预览未提供”，不读取真实路径；截图选择初始为空。示例项目数、未知日期、安全说明和按钮状态可能不同于效果图的演示值，几何和信息层级需主会话用实际截图核对。
6. 旧 StorageTreemapView 和部分 DuplicateFilesView 私有旧呈现代码暂保留供已有索引／安全契约使用，但生产结果入口已切换；不把未使用代码的源码守卫当作新页运行证明。原生 mouse hover 的派送、气泡与列表真实联动、滚动到列表条目、快捷菜单与多个 sheet 的实际呈现仍需主会话手测。

## 测试与旧断言迁移

新增两类共12个方法：FeatureLightfieldFilesPresentationTests（计数／前八／稳定排序、七类守恒、日期与大小边界、路径边界、三态与行尾槽、回调／无提供器／风格守卫）；FeatureLightfieldFilesContractTests（三态×四页×七尺寸×日夜、分析三分段几何、长路径与行尾、勾选／分组／折叠／类型点击／下钻的AX、3pt条）。容差保持0.5pt，主按钮52、内容与按钮间24、状态64、summary76；偏好只用 TestPreferenceDomain，硬件探针和文件操作回调置为 XCTFail。没有执行新测试。

依据 D70，逐项迁移旧断言，未删除测试方法、增加 skip 或放宽数值阈值：

| 类／方法 | 原断言 → 新断言与理由 |
|---|---|
| FeatureLightfieldContractTests.testNewTemplatePilotAdaptersCompatibilityAndSafetyHaveNoDecorativeContainers | 非 Lightfield 模块11→8；新增三个文件路由拥有新骨架，pilots仍3。 |
| StorageAnalysisScopeLayoutTests 的两个方法 | 336宽两列卡片／8间隔→始终单列56pt／0间隔；标题与路径上下→同一行的主／尾列；探针迁到B2标题与元数据，保留范围身份与边界断言。 |
| UIConsistencyRegressionTests.testFileWorkspaceOwnsTheOnlyPageHeader | Duplicate FeatureDataPageShell→DuplicateFilesLightfieldView，仍禁止额外页头。 |
| UIConsistencyRegressionTests.testSharedEmptyStateStaysFlatWhileSmartScanUsesDedicatedStage | LargeFiles 的 emptyPanel／emptyStateTitle→新搬家结果体的空集／搜索空态；保留“尚无可安全搬移的文件”与无第二卡片要求。 |
| UIConsistencyRegressionTests.testMainWindowTextAvoidsSmallSemanticFontOverrides | 精确允许本批5个呈现文件的紧凑日期／大小／磁盘数字缩放；原小字号禁用、单行和其他文件约束保留。普通名称和路径中间省略，普通动作标签不缩放。 |
| AppIconCacheTests.testAuditedIconViewsDeferSharedCacheRequestsToTask | 删除的28pt ExternalAppMigrationRow→新24pt LightfieldAppIcon调用，并同时要求共用 CachedAppIconView 与无同步 fileExists。 |
| CompetitiveParityContractTests.testStorageMapUsesOneReusableIndexAndKeepsFinderAsExplicitAction | 旧矩形图／列浏览／原生填充分段→新Body的 TextSegments／Bubble／Donut、同一 Store 的导航回调和显式 Finder；已有索引与旧 map 安全契约保留。 |
| ExternalMigrationReceiptTests.testAnOriginalPutBackOrReplacedNoLongerShowsAsMoved／testAMovedRowShowsItsNewLocationAcrossPageSwitchesUntilTheNextScan | 旧宿主内展示 switch／displayPath→新行呈现文件；宿主执行器、completion 持久身份及回执断言保留。 |
| FeatureLightfieldReleaseIsolationTests.testResultAndDemoFixturesHaveStrictDebugGuards | 严格 DEBUG 文件列表追加新值夹具，Release仍不可引用。 |

反证17条存 scratch/counterexamples.json，并复制到 prepared；格式与 B2 相同。每个新方法至少对应一条。静态只核对 before 片段计数、筛选方法存在和新方法覆盖，**没有执行变异、没有红绿结果**。主会话应先编译、跑绿；逐条应用单一变异，跑指定filter必须断言失败，编译错误不算反证；恢复最终源码SHA，再重新验证。特别查看 nil／未来时间、Sibling路径、候选清理禁用、按钮列重叠和AX状态改变。

## 主会话验证命令（本会话未执行）

先按 RULES 配好离线依赖，然后：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b7
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export BATCH_SCRATCH=/Users/developer/Developer/.sc-build/r2-lf2-b7
swift build --scratch-path "$BATCH_SCRATCH/debug" --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local
swift test --scratch-path "$BATCH_SCRATCH/debug" --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local --filter "$(paste -sd '|' "$BATCH_SCRATCH/targeted-classes.txt")"
swift test --scratch-path "$BATCH_SCRATCH/debug" --jobs 4 --skip-update --disable-automatic-resolution --manifest-cache local
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT="$BATCH_SCRATCH/verify" bash script/verify.sh
```

定向清单包含指定五类、共用几何／源码守卫、本批两新类、旧范围／图标／回执／安全／模板／原生起始页，以及 FileAnalysisTrashStore／ProtectedScope、DuplicateSelectedLocations／Scanner／Presentation。真实文件操作夹具只允许已有 TestFileSystem.makeHome 管理的家目录；不放宽 D46/D54。

主会话准备 Debug bundle 后，`DEBUG_APP` 指向该 Debug包（不安装）。例如：

```bash
"$DEBUG_APP/Contents/MacOS/StorageCleanerMac" \
  --debug-mini-window-demo-data --debug-feature-page=largeFiles:landing \
  --capture-feature-templates --debug-feature-disable-layout-animations \
  --debug-mini-window-appearance=dark \
  --capture-main-window-directory=/Users/developer/Developer/.sc-build/r2-lf2-b7/captures/analysis/night
```

日间改appearance=light。分析类型／最大文件加 `--debug-feature-analysis-types`／`--debug-feature-analysis-largest`（分别输出到新目录，避免覆盖同名capture）。搬家改 `--debug-feature-page=migration:landing`；重复改 `duplicates:landing`；相似另加 `--debug-feature-similar-photos` 并输出独立目录。`--capture-feature-templates` 沿用七尺寸三态；元数据记录分析surface和重复filter。实际截图才可与 renders/b 的已确认夜／日图逐页≤2pt对照。结果值夹具上的AX／组件按钮由本批native tests测；截图入口外层仍禁用点击，不能在那里声称完成交互验收。

另需 Release、严格并发、Beta 配置与 Debug symbols 隔离核对；主会话在集成分支执行完整门禁、复核和提交，不把本补丁准备提升为安装／发布。

## 分组补丁与证据

prepared 包含四组 `.patch`／`-message.txt`、all.patch、manifest.json（基线、分支、最终源码与产物哈希、组序）、commit-prepared.py、generate-prepared.py、static-checks.json、targeted-classes.txt、counterexamples.json。

1. 01-shared-file-components：B2最小扩展和文件列表共用组件。
2. 02-file-pages：真实生产接线、展示适配器和四页入口。
3. 03-debug-file-fixtures：值夹具、截图／测试注入与捕获元数据。
4. 04-contracts-handoff：两新类、旧断言迁移与本交接。

所有组／合并补丁只做反向 `git apply --check`，没有应用到Git index。commit-prepared.py 默认只核对；主会话通过构建、测试、反证和复核后才可 `--commit`，不push。模型标识未由当前harness暴露，尾注如实为 `Generated-By: Codex (model identifier not exposed)`，保留要求的 Claude Opus 5.5 Co-Authored-By，不冒称 JEV 或 Astra 实际调用。

JEV decide和gate均已尝试，接口不暴露model参数；返回 `MCP tool call requires approval, but approval policy is never`。自动审批拒绝，**BLOCKED，无模型判断或复核结果**。没有换模型或绕过审批；需要主会话独立审阅与真实验证证据。


## 变基与验证轮（2026-10-10）

本节更新前文初稿轮的 NOT RUN 状态。变基目标为 `d41361039ceaa327490150081431e5696387b43f`，旧基线为 `396326b92394761fdad68922630368acfc995308`。**文件内容的 5 处冲突标记已经解决；Git index 仍由主会话 `git add` 并继续变基，本轮没有完成 Git 变基、提交或合并。** 所有 Git 调用仅用于只读 `show`、`rev-parse`、`diff --check`，未修改 `.git`。

### 合并与编译修复

- `FeatureLightfieldCharts.swift`：保留 B2 的整个趋势实现（多线、图例、悬停气泡、默认 96pt 图形、时间戳锚定和刷新回调）逐字不变。保留按数值／尺寸缓存的气泡布局、24 项尾部合并、14pt 最小半径、微小气泡 AX 隐藏和消失时清理 hover；类型颜色和完整详情为可选值，尾部仍用 B2 的中性颜色和可选 formatter。通过独立的初始化重载加入 `highlightedID`／`emphasizedIDs`，原 memberwise 调用仍可用，单气泡保留本地 hover 状态，外部联动使用不可变 `linkedID`。Donut 的图例成为可选按钮，默认静态图例的尺寸、百分比、缩放行标记保持原样。
- `UIConsistencyRegressionTests.swift`：保留 B2 每行 `// lightfield-scale-ok` 的断言、每文件数量上限和单行约束。原共用文件预算仍为 6／6；D69／D70 新页面按实际数字／日期位置设上限：LargeFiles=1、Analysis=3、Migration=3、Duplicates=3、FileComponents=1，并逐行补标记。没有整文件豁免，没有提高原预算或放宽 0.5pt、1GB 等阈值。
- 修复新增 Debug 夹具遗漏的 `StorageItem.status`（明确 `.available`）、`ByteFormat.storageString` 的双参数函数引用（改为明确单参数闭包）；将分析页面构造提取为 `resultPage`，并明确返回目录／重试闭包，解决 SwiftUI 表达式诊断失败。未改选择、确认、搬移、恢复或安全执行器。
- 修复原生测试夹具的容器：重复列表放进与生产一致的滚动容器；3pt／2pt／6pt 比例条测试的根填满既定视口。保留所有控件尺寸、容纳、Press 和状态变化断言。
- 滚动区的原生 AX 节点按 B2 已有 `accessibilityHitTest` 方式发现：新增选择框、人工比对标记和禁用快捷动作的 Debug 几何探针；从真实框取得平台节点后，仍执行实际 AX Press 并断言选中／三态／折叠变化。没有制造 AX 节点、替换 Press 回调或增大等待预算。共享 `FeatureOptionsPresentation.swift` 逐字恢复为 B2 原版。
- 新增结果态专用矩阵 `testCompletedFilePagesKeepSkeletonAcrossSevenWindowsAndTwoSchemes`：四页 × 七尺寸 × 日夜可直接使用值夹具，不依赖家目录操作根。三态原测试完整保留；骨架断言提取到共用方法，阈值不变。原三态测试在本沙箱仍因 Store 操作根无法创建而失败，不能将结果态通过扩展为三态全通过。

`FeatureLightfieldChartGeometry.swift`、B2 的 3 个 Component 测试文件、`ScanStore.swift`、`DuplicateFileScanner.swift`、`TestPreferenceHygieneTests.swift` 与 `d4136103` 完整逐字核对相同，记录及 SHA-256 在 scratch `rebase-validation/B2-preservation-checks.json`。

### 定稿结构与数值自查

依据冻结的 `renders/b/files-*`、r4 分析 CSS／JS 与 r3 搬家 CSS／JS核对；18 个参考 PNG 均为 2560×1526（1280×763@2x）。本轮没有应用截图或像素差值验收，具体源码／数值记录为 `rebase-validation/approved-files-audit.json`。

- 实际结果态几何测试覆盖四页 × 七窗口 × 两主题：标题 `(96,92)`，结果内容 `(96,176,878,395)`，主按钮 `(96,595,520,52)`，状态行 `(52,671,966,64)`，内容与按钮间隔 24pt；分析三视图另核对左 344／间距24／右510、主体299、图形268、摘要76，Donut132和占比条3pt。短窗口使用滚动，名称／路径让出固定行尾操作列。
- Debug 分析改用 r4 冻结稿的同一棵完整树：185.4GB；七类分别为应用14.6、系统7.4、代码19.6、媒体87.1、归档49.0、文档7.1、其他0.6GB。文件、目录下钻和最大文件来自同一完成索引，种类与容量守恒。实际夹具是27个文件／38个访问项；图中的12,480为示例计数，没有硬填到实际索引。索引中的 kind 是演示类型标签，路径全部 `/Fixture`，没有文件系统或设备读写。
- 搬家为12项／17.3GB、目标可用640GB；重复为4组／逻辑4.5GB、物理释放“待确认”；相似为3组／10张／87MB，Debug 摘要也补齐候选总量与确认组信息，与生产摘要语义一致。
- 原有边界继续有效：生产普通文件修改时间仍未知；搬家仍逐项进入 D61 复制确认，主按钮为审阅计划；相似勾选仅人工比对标记，不驱动删除；相似照片仍由现有重复文件入口呈现。未把效果图演示按钮提升为新的批量执行器。

本轮改写的旧数值／探针断言（均有 D67／D69／D70 依据）：

| 方法 | 本轮修改与保留要求 |
|---|---|
| FilesPresentation.testCompletedIndexCountsFilesAndLimitsLargestToEightWithoutDirectoriesOrDuplicates | 夹具由简化树改为冻结 r4 完整树：文件16→27、访问项24→38。仍断言最大8个、不含目录／重复、大小降序、同值稳定排序。 |
| FilesPresentation.testSevenTypesConserveMeasuredRootBytesAndMediaAggregatesExistingKinds | 媒体74.5→87.1GB；另外逐类锁定全部7种批准稿容量。原总量守恒、类型聚合与饱和加法断言保留。 |
| FeatureTemplateContractTests.testSimilarPhotoRuntimeUsesItsOwnBilingualSubtitle | D70 文件页已由 D67 拥有，取消动作的几何探针改用当前 `lightfield.primary`；保留 stage、双语安全文案与相似／重复边界断言。 |
| FilesContract 中 AX／容器方法 | 仅补正确视口与原生命中测试；Press、选中状态、组头三态、折叠、微小控件安全与0.5pt几何断言保留。 |

### 实际验证与剩余失败

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`、`LC_ALL=en_US.UTF-8`。使用本批 scratch 的 debug 缓存；下列命令中的 `F` 没有改变产品安全边界：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b7
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
BATCH_SCRATCH=/Users/developer/Developer/.sc-build/r2-lf2-b7
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$BATCH_SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$BATCH_SCRATCH/targeted-classes.txt")"
```

| 检查 | 实际结果 | 证据 |
|---|---|---|
| 含测试的 Debug 构建 | PASS，最终 exit 0；前两轮编译错误已修，3–8轮通过 | `rebase-validation/build-1.log` 至 `build-8.log`；`validation-results.json` |
| 本轮组件、文件、结果矩阵、AX、界面守卫、Release源码隔离与取消文案焦点集 | PASS，102项，0失败，0跳过，exit 0 | `rebase-validation/focused-final.log` |
| scratch 全部22个定向类 | FAIL，530项：432方法通过、97方法失败、1项既有跳过；失败记录98条，exit 1 | `rebase-validation/targeted-final.log`、`targeted-final-summary.json` |
| B2 Component native／geometry／source | PASS，19／17／6项；原测试未修改 | 同上完整定向日志 |
| UIConsistencyRegressionTests | PASS，46项 | 同上完整定向日志 |
| FilesPresentation | PASS，6项 | 同上完整定向日志 |
| FilesContract | 7项中的6项PASS；三态 Store 夹具1项因家目录权限BLOCKED | 同上完整定向日志 |
| 反证 | 30条的片段计数和 filter 存在性 PASS；变异执行 NOT RUN | scratch `counterexamples.json`、`rebase-validation/counterexample-static-checks.json` |
| Git 内容空白检查／冲突标记 | PASS；不写 index | `git diff --check`，Sources／Tests 无冲突标记 |

完整清单的失败不能写成通过：

1. **92个方法**在创建 `~/.storage-cleaner-*` 操作夹具时明确 `Operation not permitted`；涉及 ConceptLandingNativeLayoutRegressionTests、ExternalMigrationReceiptTests、FeatureLightfieldContractTests、FilesContract 三态测试、FeatureTemplateContractTests、FileAnalysisTrashTests／StoreTests／ProtectedScopeTests 与 SystemUtilitySafetyTests。另1个 SystemUtilitySafety 方法因创建被拒后的 teardown 删除不存在根失败。操作根未移到临时目录，产品路径保护未改。
2. **2个偏好持久化方法**（TestPreferenceHygieneTests 的 plist 同步／后台重开）记录 `sandbox_extension_issue_file failed … Operation not permitted`；其中一个方法有2条断言失败。没有换真实偏好域或跳过断言。上述95个方法的精确 filter 在 `rebase-validation/sandbox-rerun-filters.txt`，需主会话在沙箱外复跑。
3. **2个既有失败尚未归因**：`DuplicateFileScannerTests/testAPFSCloneIsLogicalDuplicateWithoutClaimingPhysicalSavings` 实际 `.independent` 而断言 `.apfsClone`；`FileAnalysisTrashProtectedScopeTests/testAnAppThatStartsInsideAFolderAfterTheReviewKeepsTheFolder` 报 `idle → failed(deinit)` InvalidTransition。服务、Store与这两个测试均未被本轮修改，不为本呈现批次更改执行逻辑或断言；精确filter在 `rebase-validation/unresolved-rerun-filters.txt`。需主会话确认基线／运行环境并分派数据或安全逻辑拥有者，未声称都是沙箱错误。
4. 唯一跳过的是既有 opt-in 的 `SystemUtilitySafetyTests/testLiveSetappUninstallInventoryWhenExplicitlyEnabled`，本轮没有添加 skip。

沙箱外沿用上面的环境与 `F`，可分别复跑：

```bash
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$BATCH_SCRATCH/rebase-validation/sandbox-rerun-filters.txt")"
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$BATCH_SCRATCH/rebase-validation/unresolved-rerun-filters.txt")"
```

本轮没有运行全量、变异反证、Release/Beta构建、严格并发完整门禁、应用截图／像素对比、安装、真实清理／复制／恢复、硬件写入或 Git 提交。原生几何／AX仅使用 XCTest 内的惰性值夹具窗口，未启动已安装 Beta或正式版。

### 本轮交付与主会话接续

- 新包：scratch `prepared/rebase-20261010/`，以 `d4136103` 为基线，四组源码／页面／Debug夹具／测试交接补丁、all.patch、manifest、静态证据及只读校验脚本。旧 `prepared/` 根的396326b9补丁保留为初稿历史，**不代表当前文件，也不要在这个正在变基的工作树上重新应用**。
- 正在变基的仓库应由主会话审阅当前文件、`git add`并继续现有变基；新包用于审阅／重建证据。`commit-prepared.py --validated`只核对当前文件与包哈希，不替主会话写 index或继续变基。
- 主会话仍须复跑上述权限方法与2个未归因失败、运行30条反证、完成完整门禁、独立复核和实际应用视觉验证；构建与焦点集通过不等于合并、安装或C-UI2获批。

JEV `jev_review` 已尝试；工具接口没有模型或推理参数入口，使用其配置但没有获得执行结果。自动审批拒绝原文为 `MCP tool call requires approval, but approval policy is never`。状态 BLOCKED，未获得任何 JEV 判断，也没有擅自切换模型或绕过审批。

## fix1：重复文件旧起始入口与光场归属不一致（2026-10-10）

本轮基线为已提交的 `4e2ee392d213e817354f92a98788944514d69b71`，其父提交为 `d41361039ceaa327490150081431e5696387b43f`。交付 `prepared/fix1/`，不续用上轮正在变基的校验脚本。本轮没有写 Git index 或提交。

### 定位、决定依据与实现

主会话 `logs/main-final-0740/full.log` 的缺帧诊断对应 **重复文件起始页**：`generatedArt.fallback.module-duplicates-512`、77 pt 中文标题与整套 `concept-landing.*` 帧。不是照片结果页、气泡布局或等待时间不足；旧入口在所有尺寸都走另一套骨架，655×468 是尺寸遍历的第一个失败点。

数据流：`realLandingPages` 的 duplicates 夹具 → `HeroScanPage` → `FileToolLandingPage` 类型别名 → `FeatureLandingTemplate` → 原先固定调用 `FeaturePageScaffold`。`AdaptivePageViewport` 提供尺寸与主题，但不提供 `featureLightfieldModule`；不能只靠该环境值修复。生产 `DuplicateFilesView.duplicateScanHero` 已直接使用 `FeatureLightfieldPage`／`FeatureLightfieldOptions`，原问题在仍可调用的共用兼容入口。

`d4136103` 的 `FeatureLightfield.owns` 只有三个 pilots；B7 增加 `.largeFiles`、`.migration`、`.duplicates`，使原测试对 duplicates 从 V1 分支转为光场分支。`ModulePresentation.swift`（含 HeroScanPage／AdaptivePageViewport）、原回归测试和 `ScanStore.swift` 在 d4136103、4e2ee392、当前工作树中逐字相同，哈希见 `unchanged-source-audit.json`。

- `Views/FileToolLandingPage.swift`：容器明确提供的光场归属优先；无路由环境时只对 B7 `ReviewFilter.fileWorkspaceCases` 的既有符号及相似照片符号回退到光场。复用 B2 的 `FeatureLightfieldPage`／`FeatureLightfieldOptions`，保留 accessory、状态、安全文字、主动作及 Debug 动作覆盖，按钮可用条件仍等价于原 `isActionDisabled || (isLoading && !allowsActionWhileLoading)`。一期试点的无路由 V1 兼容入口保持原模板；现有专门回归测试通过。
- 新增 `FeatureLightfieldLandingAdapterTests.swift`：惰性 HeroScanPage／AdaptivePageViewport，无 ScanStore、扫描器或文件操作；先测真实失败的 duplicates，再测相似照片、分析、搬家。655×468 加七个 D67 详情区尺寸、日夜、中英文共128个组合，0.5 pt 骨架／52 pt 主按钮／视口包含／光场探针与原生 AX Press；另测禁用、加载与允许加载期间动作的5种组合。
- `targeted-classes.txt` 追加新类，原22类全部保留；`counterexamples.json` 原30条不变。

依据 D67 三态统一骨架、D69 共用图形与令牌、D70④／⑥冻结起始页。**原回归测试及其夹具、阈值、断言全部未修改**；没有启用 D70⑤ 的测试例外，也没有把重复文件重新排除在光场归属外。D70⑤不构成将该入口退回旧模板或删掉光场断言的依据。

### 基线、红／绿与沙箱验证

专属证据目录为 scratch `fix1-validation/`。运行时已有一处主会话未知修改：`FeatureLightfieldChartGeometry.swift` 中 `anchoredSelection` 的 `let lower = 0`，与反证 `rebase-B2-trend-selection-timestamp-lower-bound` 的 after 完全一致。本轮未覆盖它，备份及哈希见 `preserved-chart-working-copy.swift`、`preexisting-changes.json`。因进程清单读取也被沙箱拒绝，不能声称主会话反证已经结束。

为避免混入该变异，从只读 Git archive 建了独立 d4136103 与 HEAD+fix1 源码副本和离线依赖缓存；没有建新 Git 仓库、修改其他 worktree 或改变 HOME。最终编译的两个代码文件与本工作树逐字一致，见 `compiled-source-hashes.json`。下列结果均是沙箱内实际执行：

| 检查 | 结果与 exit code | 日志 |
|---|---|---|
| d4136103 含测试构建 | PASS，0 | `baseline-build.log` |
| d4136103 原失败方法 | BLOCKED，1；工厂创建家目录 operation home 被拒，未到几何断言 | `baseline-test.log` |
| d4136103 重复文件路由探针 | PASS，1项／0失败，0；原 HeroScanPage 路由、中英文、原7×9尺寸网格，共126组合 | `baseline-probe-build.log`、`baseline-probe-test.log` |
| 修前 HEAD + 新回归测试 | EXPECTED FAIL，1；duplicates 655×468 复现相同六个缺失光场探针及旧布局帧 | `red-build.log`、`red-test.log` |
| 最终 fix1 含测试构建 | PASS，0 | `final-build.log` |
| 新 LandingAdapter 类 | PASS，2项／0失败／0跳过，0 | `green-adapter.log` |
| ConceptLandingNativeLayoutRegressionTests 全类 | FAIL／部分BLOCKED，6项：3通过、3权限失败，1；V1兼容方法PASS | `concept-class.log` |
| scratch全部23个定向类 | FAIL，532项：434方法通过、97方法失败、1既有跳过；98条失败诊断，1 | `targeted.log`、`test-summary.json` |
| B2 Component native／geometry／source | PASS，19／17／6项 | `targeted.log` |
| UIConsistency、FilesPresentation、Release源码隔离 | PASS，46／6／1项 | `targeted.log` |
| FilesContract | 6通过、1因家目录权限BLOCKED | `targeted.log` |
| 30条反证 before／filter | PASS；HEAD和HEAD+fix1均严格符合原expected_occurrences，全部filter存在 | `counterexample-anchor-checks.json` |

基线完整原方法是否通过仍 **未确认**，不能用126组合探针冒充全页面原方法通过；它只证实本次出问题的重复文件路由在 d4136103 符合当时契约。结合 HEAD 修前原生复现与修后绿测，可以确认本次路由／归属不一致由 B7 新增归属暴露。

定向失败必须分开处理：

1. **94个方法有明确 `Operation not permitted`**：92个创建家目录操作夹具，2个偏好 plist 持久化／重开（其中1个方法两条诊断）。没有挪动操作夹具、改偏好安全规则或放宽产品路径保护。
2. **1个夹具收尾错误**：`SystemUtilitySafetyTests/testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt` 只报 home fixture 根不存在。源码先创建 home 操作根、随后 defer 严格删除；创建被拒后收尾掩盖原错误是推断，本方法没有直接记录权限错误。与94项一起列入95条 `sandbox-rerun-filters.txt`，需沙箱外核实。
3. **2个此前已记录但仍未归因**：APFS clone 实际 `.independent` 而期望 `.apfsClone`；`FileAnalysisTrashProtectedScopeTests/testAnAppThatStartsInsideAFolderAfterTheReviewKeepsTheFolder` 报 InvalidTransition。见 `unresolved-rerun-filters.txt`；没有修改服务、Store或测试迁就它们。
4. 唯一跳过仍为既有 opt-in `SystemUtilitySafetyTests/testLiveSetappUninstallInventoryWhenExplicitlyEnabled`，没有新增 skip。

实时工作树反证锚点为29／30：那处预先存在的趋势变异使正确 before 片段暂时计数0。**不是锚点失效，不能将before改成`let lower = 0`或削弱expected_occurrences。** 主会话结束反证并恢复它后应再核对；HEAD及fix1包的30条已全部通过。此次仅做用户要求的锚点／filter核对，没有执行30条变异反证。

### 主会话复跑与准备包

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b7
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
BATCH_SCRATCH=/Users/developer/Developer/.sc-build/r2-lf2-b7
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$BATCH_SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
# 先由主会话结束反证并恢复它自己的趋势变异；本轮没有自动恢复未知修改。
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter 'ConceptLandingNativeLayoutRegressionTests|FeatureLightfieldLandingAdapterTests'
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$BATCH_SCRATCH/targeted-classes.txt")"
# 需要分开归因时：
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$BATCH_SCRATCH/prepared/fix1/sandbox-rerun-filters.txt")"
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$BATCH_SCRATCH/prepared/fix1/unresolved-rerun-filters.txt")"
python3 "$BATCH_SCRATCH/prepared/fix1/commit-prepared.py" --check-only
python3 "$BATCH_SCRATCH/prepared/fix1/commit-prepared.py" --validated --check-only
# 主会话完成所需门禁与复核后才可：
python3 "$BATCH_SCRATCH/prepared/fix1/commit-prepared.py" --validated --commit
```

独立沙箱验证实际使用相同 F 参数，仅将 package-path／cwd 指向 `fix1-validation/baseline-source` 或 `fixed-source`，scratch-path 分别指向 `baseline-debug`／`fixed-debug`；`--skip-build` 只在对应构建通过后使用。基线完整原方法的沙箱外复跑须使用 d4136103 源码及它自己的重新构建，不能把 HEAD 二进制当作基线结果。scratch-only `Fix1BaselineDuplicateProbeTests.swift` 不在仓库补丁中，原测试与其工厂没有修改。

`prepared/fix1/` 两组：`01-landing-compatibility`（呈现入口、新回归类），`02-fix1-handoff`（本节交接）；另含all.patch、manifest、代码及产物SHA-256、原测试不变证据、30条锚点核对、实际测试摘要、两份复跑清单、原counterexamples及更新后targeted清单、静态检查与校验／提交脚本。`--check-only`及默认模式只读，允许明确登记且哈希相同的预先存在变异；`--commit`要求`--validated`、空暂存区、基线和文件哈希匹配，并拒绝尚未恢复的非fix1修改，不会将它混入提交。

全量、30条变异执行、Release/Beta完整构建、严格并发完整门禁、实际应用截图／像素验收、安装、真实扫描／清理／复制／恢复、硬件写入、提交／合并均NOT RUN。独立临时构建缓存按RULES清除，保留日志、源码探针和证据；没有删除主会话原debug目录。

本轮JEV `jev_decide`接口未提供模型／推理参数入口，沿用工具配置；自动审批拒绝 `MCP tool call requires approval, but approval policy is never`，请求未执行、没有JEV判断，没有更换模型或绕过审批。

## fix2：文件起始页旧探针迁移与实际主按钮高度反证（2026-10-10）

本轮基线是 `4e2ee392d213e817354f92a98788944514d69b71` **加已交付 fix1 的完整文件覆盖层**，不是只按 Git HEAD 差分。开始修改前核对 fix1 manifest 的三份最终文件 SHA-256，全部相符；六份相关基线文件保存在 scratch `fix2-validation/baseline-files/`，登记见 `baseline.json`。上一轮那处趋势变异已由主会话恢复，本轮没有替主会话恢复未知文件。fix1 的源码、新回归类及原交接章节保持原字节。本轮未写 index 或创建提交。

主会话 `logs/main-final-0907/` 已验证 fix1 定向 530 项零失败、全量 4481 项四失败、反证 28/30。四个失败都是 SafeCleanupLayoutTests 的文件工具起始夹具仍索取旧探针；两条漏检都是主按钮 token 52→53。本节仅报告 fix2 新增工作，不把主会话的 fix1 结果视为 fix2 已通过全量。

### 四个方法逐条迁移依据与保留的断言

依据为 `DECISIONS.md` D67 覆盖 D62 的旧卡片布局，`D67-LIGHTFIELD-SPEC.md` §1、§7、§8 定义独立主按钮、同宽同左边、52 pt 高、内容到按钮 24 pt、按钮到状态行 24 pt、状态行 64 pt、超高内容内部滚动及 0.5 pt 几何误差；D69/D70 冻结稿继续使用该骨架。冻结 `approved-20261009/mockups/b/shared.css` 的 `.primary` 高度仍为 52，`.main>.primary` 的参考坐标为 left 96、top 595、width 520。本轮没有启用 D70⑤ 路由例外，也没有修改 FeatureLightfield.owns。

| 原方法 | 迁移后的取帧与断言 | 原意及明确被 D67 替代的旧假设 |
|---|---|---|
| `testFileAnalysisKeepsStandaloneActionAlignedWithConfigurationThroughResizes` | `lightfield.content/primary/status/canvas`；同一五尺寸往返序列；左边差 0、宽差 0、内容到按钮间距 24，全部 accuracy 0.5；canvas 同时包含配置和独立按钮；保留 action.maxY ≤ footer.minY + 1 及 minimumControlHeight。夹具显式使用实际分析路由 `.largeFiles`。 | 保留缩放时独立动作与配置对齐、可见且有最小可点击高度。旧 cardInset、双倍 cardInset、卡片底部内边距及 card.contains(action) 是 D62 的“按钮在卡内”假设，被 D67 无卡片且按钮独立放置明确推翻；逐项替换为同边、同宽、24 pt 分隔及真实画布包含，不扩大误差。 |
| `testFileToolActionsRemainInsideActualShortViewport` | `lightfield.primary` 和 `lightfield.options.scrollViewport`；保留全部 fileWorkspaceCases、390/490/620 高度、options.height ≥ 79、action.minY ≥ viewport.minY、action.maxY ≤ viewport.maxY + 1；增加真实 lightfield.canvas 尺寸一致检查。 | 保留每个文件工具在实际短视口中动作可见、选项区仍可用；仅探针归属更新。 |
| `testLandingCardUsesItsOptionsHeightWhenTheWindowGetsTaller` | `lightfield.options.content/scrollViewport/content/primary/status/canvas`；保留八步高度往返与三行夹具；保留 viewport.height ≥ naturalContent.height − 1、action 高 52 ±0.5、action.minY − options.maxY ≤ 26、panel.maxY ≤ footer.minY + 1。增加自然文档高度在全部缩放间相等（0.5）；公共 slot 高按 D67 Geometry 精确比较（0.5），并独立要求 slot ≤ canvas 剩余高度 −164 +0.5，164 = 52 +24 +24 +64。 | 保留稀疏选项按自身自然高度、窗口变高时不拉伸行内容、主按钮/状态留有空间。旧 LandingMetrics.compositionHeight 与固定 380.5 上限是 D63 slot 假设；冻结参考内容本就高 395，故不能继续断言380.5。用 D67 slot 及字面尺寸预留上限代替，同时新增不随窗口伸长的真实自然高度断言；所有原有 1/26/0.5 阈值不变。 |
| `testLongLandingOptionsScrollWithoutTakingTheActionOffscreen` | `lightfield.options.content/scrollViewport/optionsEnd/primary/canvas`；保留30行夹具、390→620→390、content.height > options.height +500、options.height ≥79、按钮上下边可见断言。增加实际 NSScrollView 文档确有溢出、滚到底后 optionsEnd 在真实可见区内（0.5），主按钮 CGRect 与滚前完全相同，滚后仍在视口内。 | 保留长选项确实可滚且不挤走按钮；除迁移原探针外还验证真实滚动行为，没有把滚动区换成静态几何推算。 |

`AppKitLayoutHost.waitForFrames` 增加 `expectedRootProbe` 参数，默认仍是旧 landingRoot；上述四方法显式选 lightfield.canvas。原稳定轮数、帧比较及尺寸误差 0.5 均保持。`FeatureLightfieldOptions` 给其真实自然 VStack 增加 DEBUG-only `lightfield.options.content`，不是伪造旧探针的别名，也不是外层 slot 尺寸。

同类旧探针检索覆盖全部测试目录。`FeatureTemplateContractTests` 的旧模板矩阵已用 `!FeatureLightfield.owns` 排除迁移页，重复文件运行态已有光场分支；ConceptLanding 的真实全页面 sweep 已按 owns 分支，其余是 updater 或无路由的 V1 safety/developer 兼容夹具；SafeCleanup 余下旧探针属于 overview/devCaches、明确 V1 health 兼容夹具，运行态已对 green 分支；DesignSystemV2 的相关探针来自独立 V1 memory 夹具。没有发现另一个 B7 文件页仍用旧探针的方法。依据和范围见 `legacy-probe-audit.json`；这些有意保留的兼容用例未修改。

### 两条主按钮反证的根因与实际红／绿

原 `assertSkeleton` 已断言渲染探针高度等于字面 52 ±0.5，但 `FeatureLightfieldGeometry.primary` 的 CGRect **硬编码52**，未读取 `FeatureLightfield.primaryHeight`。因此两条变异改 token 后渲染仍为52，根因是未接线的 token，不是允许53通过的容差。

- `FeatureLightfield.swift`：primary CGRect 高改为读取该 token；正常52的实际几何不变，所有光场页共用同一个高度来源。
- `FeatureLightfieldFilesContractTests.swift`：在两个指定方法的每一组原生渲染帧后明确断言 `lightfield.primary.height == 52`、accuracy 0.5。期望仍是独立字面52，未改成被变异的token；原helper全部断言保留。
- 三态矩阵先遍历 value-only result，再遍历其余原Phase.allCases；完整4页×3态×7尺寸×2主题=168组合及原Store所有权要求保留。沙箱可先验证渲染再遇到家目录夹具限制，未新增skip、未移动操作夹具。
- 两条counterexample定义、filter和expected_occurrences全部不变。它们具有相同源码变异，因此共享一次53构建，但分别以各自原filter执行并独立记日志；不以编译失败或HOME权限失败充当捕获。

| 变异 | 真实失败证据 |
|---|---|
| `four-pages-primary-height` | 原filter exit 1；7个实际帧明确触发方法内高度断言 `53.0 != 52.0 +/-0.5`，之后landing工厂另报HOME权限错误；高度错误已先独立成立。 |
| `rebase-completed-pages-primary-height` | 原filter exit 1；56个实际帧明确触发方法内同一精确高度断言，无HOME权限错误；另有保留helper的高度及24→23间距失败。 |
| 恢复52并重新构建 | source SHA-256恢复到变异前fix2源码；build exit0；四布局方法、结果矩阵和fix1 adapter类共7项／0失败，exit0。 |

证据 `height-counterexample-results.json` 与 `logs/fix2-sandbox/{four-pages-primary-height,rebase-completed-pages-primary-height,restored-build,restored-green}.log`。scratch runner最初漏识别XCTest的`XCTAssertEqualWithAccuracy`诊断名，导致日志汇总校验exit1；实际两次测试红测日志未修改。仅修正解析器并以`--verify-existing`读取原日志，校验exit0；未因此重复变异或修改产品／测试阈值。现源码token为52。

### 沙箱编译与定向结果

实际执行统一 Xcode27 beta、`--disable-sandbox -Xswiftc -disable-sandbox --scratch-path <batch>/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4`；所有skip-build都在相应源码构建通过后运行。证据目录 `logs/fix2-sandbox/`，机器摘要 `fix2-validation/test-summary.json`。

| 检查 | 实际结果 |
|---|---|
| 含测试构建、恢复后的含测试构建 | 两次PASS，exit0 |
| 四个修改的布局方法 | 4通过／0失败；恢复后再次4/0 |
| SafeCleanupLayoutTests 全类 | 21项：12通过、9失败；九项全部明确Operation not permitted创建HOME夹具 |
| FeatureLightfieldFilesContractTests 全类 | 7项：6通过、1失败；三态方法先通过首个结果尺寸矩阵，随后HOME工厂被拒 |
| 更新后的scratch24类定向 | 553项：446方法通过、106方法失败、1既有skip；107条断言／异常诊断，exit1 |
| 定向失败归因 | 103方法有明确权限错误（101操作HOME夹具、2偏好plist授权）；1操作夹具不存在的收尾错误，创建被拒可能被掩盖仍需外部核实；2未改动的既有失败：APFS clone `.independent` 与 `.apfsClone`，以及受保护文件夹方法InvalidTransition |
| 主会话旧验证对照 | 上述收尾方法、两项既有失败及两个偏好方法均在`main-final-0907/targeted.log`中通过；不声称本轮沙箱内已通过 |
| 重点未涉及操作的公共组件 | Component19/0、Geometry17/0、Source6/0、FilesPresentation6/0、ReleaseIsolation1/0、LandingAdapter2/0；四布局与完成态实际几何通过 |
| 30条锚点／filter | 30/30，全部严格符合原expected_occurrences，filter方法存在；counterexamples.json与本轮基线逐字相同 |
| 静态检查 | git diff --check、private-api检查PASS（7个原allowlisted使用）；补丁重建与文件哈希核对PASS |

`targeted-classes.txt`保留原23类，追加SafeCleanupLayoutTests，防止四个失败方法继续漏在定向之外；所以本轮定向553项而不是主会话原530项。没有新增测试方法或skip。104条权限／收尾复跑filter列入`sandbox-rerun-filters.txt`，其余2条列入`unresolved-rerun-filters.txt`。

### prepared/fix2 与主会话接续

fix2包只包含三份源码／测试变化与追加本节的文档补丁，以冻结的HEAD+fix1文件差分生成：`01-lightfield-layout-contracts`、`02-fix2-handoff`，另有all.patch、manifest、四份包内baseline文件、SHA256SUMS、基线／编译源码／锚点／旧探针审计、测试摘要、两条变异证据、复跑filter、scratch清单和只读核对／按组提交脚本。**all.patch不重复携带fix1修改；当前工作树已含最终文件，不要再正向应用到它。**

```bash
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b7
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
BATCH_SCRATCH=/Users/developer/Developer/.sc-build/r2-lf2-b7
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$BATCH_SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter 'SafeCleanupLayoutTests|FeatureLightfieldFilesContractTests'
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$BATCH_SCRATCH/targeted-classes.txt")"
# 主会话还须完成全量和原30条变异；本轮只执行两条高度变异。
python3 "$BATCH_SCRATCH/prepared/fix2/commit-prepared.py" --check-only
python3 "$BATCH_SCRATCH/prepared/fix2/commit-prepared.py" --validated --check-only
```

默认、`--validated`、`--check-only`均只核对；允许原4e2ee392加fix1未提交覆盖层，或已提交并具有登记HEAD+fix1文件树的后继HEAD。核对会在临时副本真实应用补丁，比较重建后的四份SHA-256，不修改仓库、index或任何既有文件。提交模式必须`--validated --commit`、空暂存区、登记文件与清单不变，并且fix1已先提交；否则拒绝混入fix1。

当前fix1仍是未提交覆盖层。主会话在审阅和门禁完成后，可先按原fix1包的两组patch仅应用到index并用原message提交（工作树保持当前fix2最终文件）；不要用已被fix2追加文档／targeted清单的工作树再次运行旧fix1最终文件checker。具体命令见fix2包README。随后fix2 helper以文件树而非猜测fix1提交号确认基线，才可`--validated --commit`。本轮没有执行任何git apply --cached或git commit。

fix2全量、其余28条变异执行、Beta/Release完整门禁、实际应用像素／C-UI2、安装／发布／合并均未执行。保留主会话debug目录；本轮没有生成另一个独立大构建缓存，没有真实扫描、清理、迁移或ScanStore修改。

本轮JEV `jev_review`已请求，接口没有模型／推理参数入口；自动审批拒绝 `MCP tool call requires approval, but approval policy is never`。请求未执行，无JEV判断，不更换模型也不绕过审批。当前范围内可完成的源码和测试工作已完成；独立JEV复核仍BLOCKED。

## fix3：生产修改日期、重复结果懒加载与复核 P2（2026-10-10）

基线为已提交且开始时干净的 `2e59d52e4e497fb8441ab3df8def04dd29d16616`，分支 `task/r2-lf2-b7`。fix1/fix2 已包含在该 HEAD；本包只交付 HEAD → fix3，不重带之前补丁。已读取主会话 `logs/codex-review.log`，复核最后完整结论及日志内全部审阅叙述提取在 scratch `fix3-validation/review-narratives.txt`，原日志 SHA-256 与起始状态登记在 `baseline.json`。没有 P0，本轮处理两项 P1；此前主会话的 530/0、4481/0、30/30 不能作为 fix3 的验证结果。

### P1：日期沿既有扫描与缓存链传递

- `DirectoryEntry`、`StorageItem` 新增可选 `modifiedAt`，旧初始化默认 nil 保持兼容。普通文件在 `DiskScanner.scanChildren` 已有的目录属性预取与 `resourceValues` 读取中一并取 `contentModificationDateKey`；分类器保留该日期。没有第二次遍历、独立扫描或视图内文件属性读取。将原私有 `scanChildren` 改为模块内访问，仅用于隔离三文件夹具直接覆盖既有扫描路径，没有新增生产扫描入口。
- 重复扫描直接使用已采集的 `FileCandidate.snapshot.modificationSeconds/Nanoseconds`，随后 exact 项重建和 candidate 项转换都保留日期。`DuplicateFileResultStore` 复用原缓存中已经存在并在 load 前重新验证的 `FileSnapshot` 恢复日期；旧 schema 1 缓存也适用，格式不变、不增加 stat。已移走且快照不存在的终态项目仍不伪造时间、不恢复可操作性。
- 文件搬家的生产适配器 `LightfieldMigrationPresentation.fileEntries` 沿用 `ExternalMigrationItem.largeFile` 的状态、目录、家目录／符号链接安全边界，把原 `StorageItem.modifiedAt` 传给 `LightfieldMigrationEntry`。应用搬家的原安装清单日期来源保持原逻辑。
- 重复列表按真实 `StorageItem.modifiedAt` 判断“保留最新”，Debug 注入日期仅作已有夹具覆盖。只对内容确认且可操作的副本判断；缺失、非有限或未来日期不自动选择，时间相同时按路径稳定决定。按下按钮先取消最新副本的删除选择，再选择其余副本，沿用原 workspace 的至少保留一份门控和实际清理确认链。
- “未知”仅用于 nil。已知但在未来的修改日期单独归到“修改时间在未来”，仍不参与“一年以上大文件”快捷选择；这依据本次用户明确要求，不把已知日期伪装成未知，也不更改清理／复制资格。

新增 `FeatureLightfieldFileMetadataTests` 六个方法覆盖：真实三文件普通扫描／分类日期；生产搬家适配与五种日期归组；真实重复扫描 exact/candidate 两条转换；缓存已验证快照恢复日期；真实扫描结果的原生 AX “保留最新”启用、按下并检查最新副本保留状态；未知／未来／同日并列及指定保留项语义。所有文件内容与按钮回调均为测试拥有的隔离夹具，没有扫描用户内容或触发真实清理。

### P1：重复结果懒列表与一次预计算

`DuplicateLightfieldBody` 恢复 `LazyVStack(alignment: .leading, spacing: 0)`，原 stable group/item ID、52 pt 组头／行、折叠、相似照片 LazyVGrid、AX 与按钮回调保持原契约。新的 `DuplicateLightfieldPresentation.make` 在每次 body 更新时做一次线性计算，产出保留 ID、最新项及日期字典；普通行／相似 tile 只查字典，删除逐行 `keeper(group)` 搜索。自动选择复用最新项字典，不重新排序每组。

新增 `FeatureLightfieldFilesPerformanceTests` 三个方法：

| 回归 | 不可削弱的约束 | 本轮完整定向实测 |
| --- | --- | --- |
| 2,000 组 × 3 副本的展示计算 | 200 ms 内；2,000 个保留项和最新项、6,000 日期逐组正确；实际 body 只有一次 make，行／tile 两处字典查找，不能出现逐行 keeper 或 first(where:) 搜索 | 6.24 ms，通过 |
| 同一 6,000 副本的原生首屏 | 从 NSHostingController/window 构建到稳定帧 < 1 秒，含生产展示计算；实际行数 > 0 且 < 120（2%），末行不在首屏；组头／所有已实现行／实际主按钮均 52 ± 0.5 pt | 11 行，101.83 ms，通过 |
| 搬家 6,000 项选择快照 | 200 ms 内；剔除 10 个已完成项、忽略范围外 ID、保留原顺序与精确字节总量；body 一次构造资格集合，行收到该集合 | 7.15 ms，通过 |

计时使用既有测试采用的 `ContinuousClock`，首屏一秒预算参照 `FanCurveEditorInteractionTests` 的预算风格，模型／源码守卫参照 `UtilityPresentationPerformanceTests`。排除数据夹具生成和 `NSApplication.shared` 初始化，包含实际页面 body、懒行与窗口构建、布局稳定等待；这些是本机 Debug 沙箱观测，不等同于发布版或实机 C-UI2 验收。

### P2 的处理与剩余偏差

- 已修搬家 `eligibleIDs` 逐行重建：`LightfieldMigrationSelection` 在 body 中一次生成 eligible/selected/bytes，传给组头、可见全选、快捷选择和行，消除原平方重复过滤。资格与选择语义不变，新增 6,000 项回归锁住已完成排除和总量。
- 已恢复冻结 `mockups/b/shared.js` 的主按钮表达：“复制到〈目标盘名〉并校验 · 〈选中大小〉”。**逐项审阅流程仍保留**：冻结预览呈现批量按钮，但当前执行器仍逐项确认；本批规则要求不改变执行／确认流程，本次用户也未要求新增批量执行队列。只修文案与数据表达，不能据此宣称批量流程同稿。原复制、原件处理、回执与恢复服务未改。
- 相似照片起始页“图片／下载”目前仍是说明行，未补独立范围开关。真实扫描与重复文件共用 `duplicateFilesWorkspace`，现有 scope 是用户文件／整台电脑／仅所选位置；没有两个独立的默认目录绑定。补真开关需要明确默认目录、切换 scope、与共享 customRootPaths 的持久化／移除语义，会扩大到扫描配置和另一页面的行为，不能只加外观勾选假装改变范围。已有“添加文件夹”和真实范围菜单仍工作。该 P2 继续待闭合，`SystemUtilitiesView.swift` 未修改。

`ScanStore.swift`、`ExternalDriveMigrationService.swift`、`Features/LargeFiles/Services/FileAnalysisTrashService.swift` 与 HEAD 的 SHA-256 相同，登记在 `protected-source-hashes.json`；未新增需 ScanStore 提供的字段。

### 既有测试的修改依据

| 既有测试 | 改动与保留的原意 |
| --- | --- |
| `FeatureLightfieldFilesPresentationTests.testOldLargeQuickSelectionRequiresKnownPastDateAndOneGigabyteBoundary` | 本次要求未知仅用于真的缺日期：原未来／nil 混归未知改为分别精确断言；原 1 GB 边界、至少一年、未来不得选、分组覆盖与字节守恒断言全部保留。 |
| `…testProductionRoutingRetainsExistingSafetyCallbacksAndInertFixturesHaveNoProviders` | 旧内联日期判定已移到一次预计算 helper：源码守卫改查 helper 的已知／有限／过去日期 gate，并新增实际按钮禁用绑定守卫；真实生产日期与 AX 行为另由新增测试锁定。原安全 callbacks、无 Provider 夹具和无 Material 等断言保留。 |
| `IndependentFeatureWorkspaceStoreTests.testDuplicateStoreReloadsResultAndFiltersWithoutSelection` 及其共享扫描夹具 | 夹具现在从自身文件 resource-values 携带真实日期，并给文件设置固定实际修改时间，避免 URL Date 与纳秒快照的精度偶然差异。原 `XCTAssertEqual(restored.items, first.items)` 完整保留，新增首次结果日期非 nil 断言；没有忽略日期或拆弱整体相等断言。该 HOME 夹具在本轮沙箱被拒，必须主会话复跑。 |

未删测试方法、断言或提高既有阈值；fix2 的 52 pt 实测和四个布局用例没有修改，四个本轮均通过。

### 编译、定向与失败归属

本轮 Debug `swift build --build-tests` 成功，最终构建 10.19 秒；初次新夹具尝试写只读系统 reduce-motion 环境失败，已改用项目原有 `featureDisablesLayoutAnimations` 并重新编译。scratch `targeted-classes.txt` 保留原类并新增元数据、性能和工作区缓存类。日志都在 `fix3-validation/`。

- 新增两类：9 个方法，8 通过、1 失败。失败为 `FeatureLightfieldFileMetadataTests/testDuplicateResultCacheRecoversDatesFromItsAlreadyValidatedSnapshot` 创建 `~/.storage-cleaner-duplicate-metadata-cache-<UUID>` 时 `NSCocoaErrorDomain 513 / NSPOSIXErrorDomain 1 / Operation not permitted`；未挪动需要产品路径门控的夹具、修改门控或增加 skip。
- 完整 scratch 定向：577 个方法，461 通过、115 失败、1 跳过；XCTest 汇总 116 个 failure diagnostics。UIConsistency 46/0；文件展示 6/0、性能 3/0、元数据 5 通过＋1 HOME 阻塞；文件几何 6 通过＋1 HOME 阻塞；TestPreferenceHygiene 源码守卫通过，21 个方法中两个持久化读回测试失败，不能称整个类通过。
- 初次定向 110 个失败有明确 HOME `Operation not permitted`，2 个偏好 plist 方法有 `sandbox_extension_issue_file … Operation not permitted`（3 个断言 diagnostics）；另外 3 个与 fix2 沙箱诊断相同，逐条证据见 `baseline-sandbox-comparison.json`。单独复跑这三项仍失败，其中 `FileAnalysisTrashProtectedScopeTests/testAnAppThatStartsInsideAFolderAfterTheReviewKeepsTheFolder` 已直接显示 HOME `Docs/Nested` 创建被拒，原汇总中的 `InvalidTransition idle→failed(deinit)` 不能替代实际根因证据。
- 另两项仍留待沙箱外确定：`DuplicateFileScannerTests/testAPFSCloneIsLogicalDuplicateWithoutClaimingPhysicalSavings` 检测成 independent 而非 apfsClone；`SystemUtilitySafetyTests/testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt` 在未建成的 HOME 根 teardown 报不存在。两者与 fix2 沙箱记录相同，本轮未改这些测试或关系／卸载实现；不把“相同旧失败”当作通过或已证明是沙箱所致。
- `python3 script/check_private_api.py` 通过（原 7 个 allowlisted uses）；`git diff --check`、保护源码哈希、空 index、HEAD 未变通过。`compiled-source-hashes.json` 登记最终编译的 14 份 Swift 文件，包核对会再次验证。

主会话需在沙箱外运行全部定向以覆盖缓存恢复和以上阻塞；`sandbox-rerun-filters.txt` 列出全部 115 个未通过方法，`unresolved-rerun-filters.txt` 保留三个初始非明确权限诊断用于重点复核，不作测试排除名单。

### 反证目录与主会话验证

原 `counterexamples.json` 的 30 个 mutation 对象逐对象完全不变，before 文本仍按每条登记次数精确命中，原两个主按钮 52→53 反证及其实际帧断言保留。新增 11 条：普通扫描日期、分类日期、重复快照日期、exact/candidate 日期转换、缓存快照日期、搬家适配、重复列表生产日期、LazyVStack→VStack、逐行保留项搜索、搬家已完成资格排除。全部 **41/41 锚点及 filter 方法存在**，证据在 `counterexample-anchor-checks.json`。

本次沙箱没有执行 mutation 或全量，不能写 41/41 已抓到。新增反证的红／绿方法：基线当前完整 filter 先通过，再按目录只替换登记 before，编译并运行该 filter 必须失败，恢复原文件并核对 SHA-256，最后重编译恢复产物。日期 mutation 必須由非 nil／精确日期／分组／实际 AX 断言抓到；懒加载 mutation 由实际首屏行数、时间和生产容器守卫抓到；行内搜索 mutation 由实际 render 源码守卫抓到。缓存 filter 须沙箱外运行，否则权限错误不能计作 mutation 被抓到。

主会话命令：

```zsh
cd ~/Developer/sc-worktrees/r2-lf2-b7
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r2-lf2-b7/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
B7_FIX3_FILTER=$(paste -sd '|' ~/Developer/.sc-build/r2-lf2-b7/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$B7_FIX3_FILTER"
```

随后运行主会话既有全量／mutation runner，对更新后的 41 条逐条验证并确认最终源码／构建已恢复。之前 30/30 的记录不能替代本轮新代码上的反证。Release 完整门禁、应用像素／C-UI2、安装、合并与发布均未执行。

### prepared/fix3

三组：`01-scan-file-modification-dates`、`02-lazy-file-lightfield-presentations`、`03-fix3-handoff`；共 15 份仓库文件，另含 all.patch、manifest、包内 HEAD 基线、SHA256SUMS、源码／锚点／失败归属／日志证据、scratch 清单及 `commit-prepared.py`。

```zsh
python3 ~/Developer/.sc-build/r2-lf2-b7/prepared/fix3/commit-prepared.py --check-only
python3 ~/Developer/.sc-build/r2-lf2-b7/prepared/fix3/commit-prepared.py --validated --check-only
```

默认、`--validated`、`--check-only` 只读核对：要求确切基线 HEAD、分支、空 index、登记修改范围与最终哈希；在临时副本从包内基线真实应用 all.patch 并比对 15 份结果。当前工作树已含 fix3，不要再正向套补丁。主会话全部门禁完成后才可 `--validated --commit`，仅按组应用到 index 并用登记 message 提交。本轮没有提交、写 index、push、安装或碰真实用户文件。

JEV `jev_review` 已请求，工具没有模型／推理参数可设置；自动审批拒绝 `MCP tool call requires approval, but approval policy is never`。调用未执行，无 JEV 判断；该限制记录在 `jev-status.json`，没有绕过审批或更换模型。

## merge-integration：保留 B7 与 B4 的光场合并（2026-10-10）

本轮开始时 HEAD 为 `2889a782e984a0b52db35a614a679b864aa2165f`，分支 `task/r2-lf2-b7`；主会话已发起合并，MERGE_HEAD 为 `a674de6a01fe006d2f2c9f70e74e548d604819c5`。fix3 已提交，用户报告合并前沙箱外定向 530/0、全量 4490/0、反证 41/41；这些是合并前结果，不能代替本轮验证。`.git` 只读，本轮只编辑四份冲突文件及追加本节；没有 add、commit、abort 或改变合并元数据，不生成 prepared 包。工作树中的冲突标记已清除，Git 的四项 UU 状态留给主会话暂存并完成合并。

### 四处冲突的取舍及断言依据

| 文件 | 合并结果与依据 |
| --- | --- |
| `FeatureLightfield.swift` | `owns` 取双方并集：原三试点 green／healthHub／uninstall，加 B4 updater 和 B7 largeFiles／migration／duplicates。duplicates 的两种页面覆盖重复文件与相似照片，故 B7 四页对应三个 route。注释随真实归属更新。保留 B7 `primaryHeight: CGFloat = 52` 及 geometry 使用该常量；B4 自动合并的结果摘要、统计列及应用页接入保持原文。依据 D67 骨架、D69／D70 二期页面归属，以及本次明确要求保留双方。 |
| `FeatureLightfieldComponents.swift` | `LightfieldSummary` 同时保留 B7 的可选 `artwork` 与 B4 的 `showsArtwork`。默认显示时以指定插画优先，相似照片继续使用自己的插画；B4 页面传 false 时保持 76×76 透明占位及顶部对齐，由页面在 D67 锚点放唯一插画。默认 true 的旧调用不变。B4 的环内 0.8 缩放下限、统计列的 `ViewThatFits`／列宽约束、卸载摘要布局等非冲突部分逐字保留。 |
| `FeatureLightfieldContractTests.swift` | 两边的“非光场 demo 数”分别为 8（14−6，B7）和 10（14−4，B4）。并集有 7 个 owner，精确余数必须为 **7**（14−7）。保留精确计数断言，并增加 owner **完整集合相等**断言，锁住七个具体 route，防止仅计数正确但误丢 updater／文件 route；不是放宽布局阈值。该方法 `testNewTemplatePilotAdaptersCompatibilityAndSafetyHaveNoDecorativeContainers` 本轮通过。 |
| `FeatureLightfieldReleaseIsolationTests.swift` | fixture 检查取并集：ResultFixture、PresentationDemo、B7 FileResultFixture、B4 ApplicationsFixture 四个文件都检查严格 `#if DEBUG` 前缀／`#endif` 后缀，仍拒绝 `DEBUG || STORAGE_CLEANER_BETA`。pipeline 的 Debug 区间断言全部保留。该类本轮 1/0。 |

只有五段冲突区域发生替换；四份文件的所有非冲突文本原样保留。其余 **42 份自动合并文件**与开始时快照 SHA-256 完全一致，包含 D73 风扇／充电恢复、B4 应用行／卸载组件、语言辅助类及偏好卫生迁移。fix3 的 **14 份 Swift 文件**均与 HEAD 逐字相同，日期传递、最新项选择、LazyVStack、一次预计算和性能断言保留。文件契约两个矩阵方法的实际按钮 **52 ± 0.5 pt** 断言及共享骨架高度断言没有变动；所有尺寸、对齐、行高、预算和阈值保持原值。`ScanStore.swift` 未变。

### 语言辅助类与偏好卫生

全 Tests 中 `CalibrationLanguageScope` 仅在独立文件 `Tests/StorageCleanerMacTests/CalibrationLanguageScope.swift` 定义一次，定义没有条件编译（注释中提到 Debug 不构成编译 guard）。仍通过 argument domain 临时切换语言并恢复，两次 `setVolatileDomain` 与白名单 `"StorageCleanerMacTests/CalibrationLanguageScope.swift": 2` 精确对应，旧 ConceptLanding 文件的例外条目已移除。辅助类与卫生测试均保留 integration 版本。

`TestPreferenceHygieneTests.testTestSourcesUseTemporaryDomainsAndDoNotPersistStandardDefaults` 通过，确认实际测试代码与完整白名单匹配；全类 19 通过、2 个偏好持久化读回方法有明确 `sandbox_extension_issue_file … Operation not permitted`，没有把全类写成通过。

### 沙箱构建与定向测试

使用 Xcode 27 beta 和统一参数，在既有 batch/debug 中执行一次含测试目标构建；成功后执行 scratch 定向清单。原 27 类全部保留，追加 B4 `FeatureLightfieldApplicationPageTests`、`FeatureLightfieldApplicationPresentationTests`；`ConceptLandingNativeLayoutRegressionTests` 原已在清单，不重复添加。实际 29 类。

| 检查 | 实际结果 |
| --- | --- |
| `swift build --build-tests` | PASS，exit 0，208.63 秒；应用及测试目标均编译。 |
| 完整 29 类定向 | 590 个方法：472 通过、117 失败、1 个既有跳过；118 条 failure diagnostics，exit 1。 |
| 失败归属 | 112 个方法明确 HOME `Operation not permitted`，2 个偏好 sandbox-extension 错误；另 3 个与 fix3 沙箱诊断相同，仍待主会话复跑，不能宣称通过或已证明全由权限导致。 |
| B4 两类 | ApplicationPage 5 通过／2 HOME 阻塞；ApplicationPresentation 5/0。长应用名／版本／路径列、六列长值、卸载摘要数字不重叠、实际 AX 审阅按钮及纯展示／执行隔离守卫通过。两个 HOME 阻塞为生产三态七尺寸矩阵和起始页 28 pt 图标／主动作方法。 |
| ConceptLandingNativeLayoutRegressionTests | 4 通过／3 HOME 阻塞，包含 integration 新增的更新起始页重排方法通过。原每页 sweep 在创建 ScanStore 的 HOME/home 夹具时即被拒，未进入布局 sweep，不把它记为已通过。 |
| B7 四个修复布局方法 | 独立按钮随缩放对齐、短视口按钮、增高窗口按选项高度、长选项滚动四项全部通过。SafeCleanup 全类 12 通过／9 HOME 阻塞。 |
| B7 文件回归 | FilesPresentation 6/0；FilesContract 6 通过／1 HOME 阻塞；FileMetadata 5 通过／1 HOME 缓存阻塞；FilesPerformance 3/0，2,000×3 副本首屏用例整个方法 0.088 秒，原 <1 秒、可见行 <120、52 ± 0.5 pt 约束保留。 |
| 共用组件及守卫 | Component 19/0、ComponentGeometry 17/0、ComponentSource 6/0、LandingAdapter 2/0、ReleaseIsolation 1/0、UIConsistency 46/0；路由并集及非装饰容器方法通过。Contract 全类 10 通过／6 HOME 阻塞。 |
| 静态／状态检查 | `git diff --check`、private API（原 7 个 allowlisted uses）、冲突标记、42 份自动合并文件哈希、14 份 fix3 文件、ScanStore、HEAD、index 与 MERGE_HEAD 核对通过。 |

与 fix3 沙箱失败清单比较：原 115 个失败方法完整保留，只多两个 B4 HOME 方法，没有其它新增失败方法。三个非明确权限诊断为 `DuplicateFileScannerTests/testAPFSCloneIsLogicalDuplicateWithoutClaimingPhysicalSavings` 的 independent／apfsClone，`FileAnalysisTrashProtectedScopeTests/testAnAppThatStartsInsideAFolderAfterTheReviewKeepsTheFolder` 的 InvalidTransition，以及 `SystemUtilitySafetyTests/testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt` 的 HOME 根收尾不存在。没有改这些测试或产品行为；本轮没有再次单独复跑它们。合并前用户报告全量已绿，但合并后仍须沙箱外复核。

证据统一在 scratch `merge-integration-validation/`：`build.log`、`targeted.log`、`test-summary.json`、逐方法诊断 `test-method-results.json`、`baseline-sandbox-comparison.json`。`sandbox-rerun-filters.txt` 列出全部 117 个未通过方法；`unresolved-rerun-filters.txt` 单列上述三个，均为复跑清单而非排除／skip 清单。起始状态、四文件 ancestor／两边版本、自动合并哈希、冲突区域和保护文件核对也保存在该目录。

### 41 条反证锚点

41 条 before 均在合并后文件精确命中 `expected_occurrences` 次，41 个 filter 方法均存在。仅 `rebase-B2-scale-marker-required` 的 before／after 从环内数值 `minimumScaleFactor(0.5)` 更新为 integration 已改成的 `minimumScaleFactor(0.8)`；缩进及行位置语境对应原同一值行。反证仍只移除 `// lightfield-scale-ok`，`expected_occurrences: 1` 与 `UIConsistencyRegressionTests/testMainWindowTextAvoidsSmallSemanticFontOverrides` 完全不变。B4 0.8 可读性下限、守卫预算和断言没有改动，其余 40 个 mutation 对象逐对象相同。原两条 52→53 及 fix3 日期／懒加载反证原样保留。

本轮 **41/41 是锚点／filter 核对，不是变异执行结果**；按公共要求未在沙箱执行全量或变异。证据 `baseline-counterexamples.json`、`counterexample-anchor-checks.json`、`counterexample-filter-checks.json`。主会话在最终合并树上先跑绿色 filter，再逐条变异要求失败，恢复文件／哈希并重新构建；权限失败不能作为反证抓到的依据。

主会话接续命令（沿用 scratch 更新后的 29 类清单）：

```zsh
cd ~/Developer/sc-worktrees/r2-lf2-b7
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
B7_MERGE_SCRATCH=/Users/developer/Developer/.sc-build/r2-lf2-b7
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$B7_MERGE_SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
B7_MERGE_FILTER=$(paste -sd '|' "$B7_MERGE_SCRATCH/targeted-classes.txt")
swift test "${F[@]}" --skip-build --filter "$B7_MERGE_FILTER"
# 随后按主会话既有 runner 跑合并后的全量与 41 条反证，并恢复构建产物。
```

本轮没有完成 Git 合并、Release 配置构建、全量／变异运行、安装、发布或 C-UI2 实机验收。原 fix3 的未闭合 P2（相似照片独立范围开关，以及搬家仍逐项确认的执行流程）没有由合并改变，不将它们记为已修。

本轮 JEV `jev_review` 已请求，工具没有模型／推理参数入口；自动审批拒绝 `MCP tool call requires approval, but approval policy is never`。调用未执行，没有 JEV 判断，记录在 `merge-integration-validation/jev-status.json`；没有绕过审批或更换模型。
