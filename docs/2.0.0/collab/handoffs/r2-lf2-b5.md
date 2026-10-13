# r2-lf2-b5 交接（2026-10-10）

## 状态与范围

代码与分组补丁已准备；Debug 沙箱编译 PASS。最终定向运行 202 个测试用例，193 个通过、9 个失败用例，共 14 个失败断言（6 个 unexpected）。其中 8 个用例有明确的文件/偏好服务权限证据，另 1 个剪贴板用例写入失败，原因需在沙箱外复核。没有跳过测试、删断言或放宽阈值。新增两类共 11 个测试全部 PASS。未提交、合并、安装、启动已安装应用或发布；C-UI2 与全量门禁尚未完成。

- worktree：`/Users/developer/Developer/sc-worktrees/r2-lf2-b5`。
- 分支：`task/r2-lf2-b5`；基线：`0ca11ff5b9ddc7e87d50b4c652685cb5c0092b7c`；开始时工作区干净。
- scratch：`/Users/developer/Developer/.sc-build/r2-lf2-b5`。
- 已读取 `lf2-pages-common.md`、`common.md`、`codex-build-common.md`、RULES、D5/D48/D55/D60/D69/D70/D71、B5 计划。按用户及新构建规则执行沙箱构建；旧说明中的禁止编译条款已被覆盖。
- 已实际打开冻结稿 `renders/a/privacy-result-day.png` 与 `privacy-result-night.png`，并读取对应 HTML、`shared.js` 的隐私数据结构和 `shared.css`。
- `Stores/ScanStore.swift`、所有生产 BrowserPrivacy Store/模型/分类器/扫描器/删除处理器/备份恢复服务，以及健康检查/评分/日志持久化逻辑均未改动。
- 本批不需要 Store 增加字段；使用已有 records、filteredDisplayItems、selection UUID、locator、scanSnapshot、coverage、report 等字段。

## 实现

### 浏览器隐私

`BrowserPrivacyLightfieldPresentation.swift` 只提供展示聚合与选择范围计算。按浏览器与配置文件分别聚合，浏览器页签只来自扫描到的记录；不同浏览器/配置文件的相同域名和相同地址不会混在一起。无域名的内部/本地页面放入“无网站信息”，展开后仍能看到具体页面。

`BrowserPrivacyLightfieldResults.swift` 复用 B2 的 Summary、TextSegments、AppIcon、StatusGlyph 和光场 checkbox、disclosure、按钮、令牌及滚动骨架。结构为页签/搜索 → 今天/7 天/全部和选择工具 → 配置文件分组 → 域名 → 页面。域名等宽；计数与最近时间来自当前筛选结果。页面有标题则显示标题，无标题则显示经过既有安全展示层处理的网址；页面还能展开完整地址和逐次访问，显式复制仍经过原有 concealed/transient 剪贴板包装器。

成人内容与金融/账户为当前枚举里的敏感类。每个配置文件分支合并一个“敏感网站”行，默认折叠，带“需审阅”。首次明确展开只显示打码域名；再次明确展开该域名才挂载原域名与具体页面。折叠时完整敏感域名、标题、URL 不在该分支的 AX 或 tooltip 中。敏感性以整次扫描为依据：同域名任何页面被标为敏感，就把该域名放入敏感分组，避免搜索/日期筛选隐藏敏感页面后泄露同域名。选择范围仍只用筛选后实际记录，不增加任何隐藏记录。

整组、全选和反选只作用于当前范围中带 locator 的可删项；反选保留范围外选择。批量加入沿用原有审阅确认，反选的加入与移除在确认后一起应用；单纯取消选择立即执行。单页仍可明确选择浏览器内处理项，沿用手动步骤。主按钮的删除计数使用真实直接删除候选数，纯手动选择显示“在浏览器内处理”，避免把手动项算成将删除的记录。备份、失败原因、退出浏览器预检、回执/恢复、删除备份的二次确认、读取状态和重新扫描入口保留。

`BrowserPrivacyWorkspaceView.swift` 接入光场起始/结果页，移除旧平铺结果和旧日期/分组 UI。起始页使用 B2 带类别图标的选项行。运行页继续复用现有 `BrowserPrivacyRunningPage`；`FeatureLightfield.owns(.privacy)` 使运行页、侧栏、视口和工具栏使用同一光场骨架。

### 系统健康

基线新增的安全检查与事件日志已经使用 52 pt 光场状态行、15/13 pt 字号和行末展开；保持它们的布局与交互。仅给 B2 `LightfieldStatusGlyph` 增加原 `FeatureLightfieldStatus` 的初始化路径，并让共用 `FeatureLightfieldStatusRow` 使用它。符号、20×20 尺寸、状态颜色和原检查状态映射不变，未重做健康结果页。

### 夹具与 Release 隔离

`BrowserPrivacyPreviewFixture` 扩充成人/账户记录，保留多配置文件、同站多页、多访问、无标题长网址、参数和内部页。注入惰性内存扫描器、无写入处理器和空运行状态检查器，测试/演示不读真实浏览器记录，也不检查或退出真实浏览器。

`FeatureLightfieldProductionResult` 增加 privacy 结果入口，沿用 `--debug-feature-page=privacy:<landing|running|result>`、`--capture-feature-templates`。夹具改为严格 `#if DEBUG`；App 和原快照管线的相关引用同步使用 DEBUG。**主会话截图使用 Debug 包；Beta Release 不包含 `--browser-privacy-preview` 夹具。** Release 源码隔离测试已覆盖该夹具；实际 Release 编译留给主会话。

## 验证证据

### 本轮最终结果

日志均在 scratch 的 `logs/`。

| 检查 | 结果 | 证据 |
| --- | --- | --- |
| Debug build including tests | PASS，exit 0，38.48 秒 | `logs/build-final-2.log` |
| 全部列出的定向类 | FAIL，exit 1；202 用例/193 通过/9 失败用例/14 失败断言，0 skip | `logs/targeted-final.log` |
| BrowserPrivacyLightfieldTests | PASS，6/6 | 同上 |
| BrowserPrivacyLightfieldNativeTests | PASS，5/5 | 同上 |
| B2 ComponentTests / ComponentSourceTests | PASS，19/19、6/6 | 同上 |
| UIConsistencyRegressionTests | PASS，46/46 | 同上 |
| FeatureLightfieldReleaseIsolationTests | PASS，1/1，源码隔离检查 | 同上 |
| 健康安全与日志定向类 | PASS，4+3+8+13 用例 | 同上 |
| DeclutterD4D5ContractTests / 日期预设 | PASS，15/15、2/2 | 同上 |
| private API check | PASS，exit 0，7 个既有 allowlisted uses | `prepared/static-checks.json` |
| diff / 补丁与 SHA-256 校验 | 见 prepared 静态检查记录 | `prepared/static-checks.json` |

原生测试实际验证：日夜三态×七窗口的骨架位置（0.5 pt）与内容到按钮 24 pt；无标题长网址的七尺寸列边界；页面、访问选择与展开相互独立；敏感分组和域名需两次显式展开才暴露 AX 明细；组加入等待原有审阅确认；健康 glyph 20×20、52 pt 行高、展开状态及可按下操作。

整页滚动容器在项目 AppKit 测试宿主中不发布 AX 子节点（既有 N20）。为测试真实组件，生产配置文件分组拆为 `BrowserPrivacyLightfieldProfile`，原生测试直接承载这一组件，没有另造演示行。这不等于已验证实际主窗口里的滚动列表 AX，主会话仍须实机复核。

### 沙箱外需复跑的 9 个用例

以下前 6 个都在 `TestFileSystem.swift:60` 创建家目录操作夹具时抛出 Cocoa 513，Underlying POSIX 1（Operation not permitted）；产品与测试路径检查未放宽：

1. `FeatureLightfieldContractTests/testLongUninstallListLaysOutOnlyVisibleRows`
2. `FeatureLightfieldContractTests/testProductionCleanupGroupSelectionSpeaksItsState`
3. `FeatureLightfieldContractTests/testProductionPilotsKeepNativeSkeletonAcrossThreeStatesSevenSizesAndTwoSchemes`
4. `FeatureLightfieldContractTests/testProductionResultPagesEndAbovePrimaryWithoutHalfRowsAndShowHistory`
5. `FeatureLightfieldContractTests/testProductionUninstallRowSelectionNeverOpensPreview`
6. `FeatureLightfieldContractTests/testResultLongListFadesPartialRowsAndLastItemIsReachable`

这两个偏好持久化用例有明确的 `sandbox_extension_issue_file ... defaults.plist: 1 (Operation not permitted)` 日志：

7. `TestPreferenceHygieneTests/testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`
8. `TestPreferenceHygieneTests/testTemporarySuiteCanBeReopenedOnAWorkerThread`

最后一个是 FAIL，不能把原因未经复核就断言为权限：

9. `PrivacyCleanupPresentationTests/testCopiedAddressesAreMarkedConcealedAndTransient`：唯一命名的测试 pasteboard 写入返回 false，types/string 为 nil；5 个断言失败。原 `BrowserPrivacyClipboard` 包装器逐字节保持基线实现。疑似沙箱 pasteboard 服务限制，日志没有直接 pboard 拒绝原因，需在沙箱外复跑确认。

### 命令

```zsh
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b5
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b5/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
TARGET_FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b5/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$TARGET_FILTER"
python3 script/check_private_api.py
git diff --check
```

主会话最终仍须按项目 `script/verify.sh` 跑 Debug/Release 全量、严格并发、Bundle/UI smoke 等门禁。这个批次没有跑完整门禁或反证。

## 改写的既有断言与依据

- `DeclutterD4D5ContractTests.testBrowserRowsContinueToExposePageTitleAndAddress`：D70②允许默认域名；改为要求实际新分组入口、展开页标题/网址、访问选择和光场 checkbox/disclosure，保留具体页面可辨认的约束。
- 同类 `testBrowserResultsKeepBackupScopeAndManualGuidance`：D69/D70②用共享固定主按钮取代旧 compactSelectionHeader；改验证光场 shell 和原确认/运行浏览器分支，保留所有回执、备份、手动流程断言。
- `PrivacyCleanupPresentationTests.testResultRowsPrintOnlySanitizedPresentationText`：把实际新层级源文件加入安全文本守卫；原地址包装器、不得传原始 record 字段、不可选择完整地址文字、concealed/transient 复制和仅两处剪贴板写入断言保留。复制网址移动至展开页面组件，另一处仍是手动按浏览器复制域名。
- 同类 `testBrowserPrivacyResultsUseCompactHeaderSingleSearchAndLazyRows`：D70②取代 V1 compact header；要求新光场 shell、单搜索字段、200 ms debounce、LazyVStack、B2 summary 和实际 Store 选择出口。
- 同类 `testBrowserPrivacyRefreshKeepsCachedResultsAndEmptyStatesStayTruthful`：取消操作从旧 toolbar 调用写法移至原运行页的 callback；更新函数引用断言，不改变取消语义。新页面/组禁用条件替代被删除的 V1 行禁用写法，保留缓存与部分扫描/权限语义断言。
- 同类 `testBrowserPrivacyPrimarySurfacesOmitRedundantExplanatoryCopy`：D70④/②起始行改为 B2 图标选项，搜索绑定在结果页 debounce；更新旧 DateControls/直接绑定引用，保留安全提示断言。
- `FeatureLightfieldContractTests` 中 V1 未迁移模块数由 11→10，因为本批接入 privacy；一期三个 pilots 不变。
- `FeatureLightfieldReleaseIsolationTests` 增加 BrowserPrivacyPreviewFixture 的严格 DEBUG 检查。

初始构建曾发现缺 probePrefix、测试构造缺 UUID，均修复。原生健康夹具曾未填满宿主视口，已改为标准固定视口；未修改几何阈值。各中间结果保存在 `logs/build-*.log` 和 `targeted-1.log`、`targeted-2.log`。

## 反证与主会话离屏场景

`counterexamples.json` 有 10 个可精确替换的 mutation，before 各匹配一次。状态为 NOT RUN（按 codex-build-common 交主会话）。每次只改一个、跑指定测试应红、恢复后应绿；禁止在真实数据上操作。覆盖 finance 敏感分类、筛选解密泄露、manual 项误选、错误反选、默认敏感展开、域名未打码、组选择绕过审阅、展开误触选择、glyph 尺寸和 Release guard。

主会话需重拍/验收（全部使用夹具）：

- `--debug-mini-window-demo-data --debug-feature-page=privacy:landing|running|result`：日夜三态及七尺寸，特别是 677×390、1280×390 的内滚动和固定按钮/状态行。参考画布 1280×763 对照冻结日夜图。
- 浏览器页签只显示夹具有记录的 Safari/Chrome；切浏览器、两个 Chrome 配置文件、组折叠、混合勾选状态、全选/反选审阅确认；另扩展匿名 Edge/Firefox 值检查更多页签与横向滚动，禁止读真实 profile。
- 普通域名折叠、展开页面、无标题/长网址、完整参数/片段与逐访问选择；搜索标题和 URL/编码参数；今天/7 天/全部；跨筛选选择保留。
- 敏感分组默认、第一次展开的打码域名、第二次展开的具体页面；重新扫描再次锁定；正常页与敏感页同域名在搜索后的隐藏边界。检查实际窗口 AX 树与 tooltip，无静默揭示。
- 健康保持原布局，滚动至 SIP/FileVault/Gatekeeper/防火墙与最近变化，展开证据；日夜符号、行高与字号。
- 原确认/退出浏览器预检、部分覆盖/权限受限/刷新取消或失败、处理报告、回读中文失败原因、最近删除与恢复入口的演示/隔离夹具场景。

截图入口已接好，但本批未启动已安装应用或拍真实主窗口，未声称像素验收、真实浏览器删除/恢复或 C-UI2 完成。处理报告/恢复弹层保留原视图与处理链，没有重做它们的流程。

## prepared 与集成

四组：`01-lightfield-status`（B2 glyph/ownership）、`02-browser-privacy`（展示聚合与页面）、`03-debug-fixtures`（严格 Debug 夹具/入口）、`04-tests-handoff`（断言、测试与本文）。scratch/prepared 含各 patch/message、all.patch、最终文件/产物 SHA-256 manifest、static-checks 和 commit-prepared.py。

沙箱 `.git` 为只读，未尝试提交。主会话完成外层复跑、反证和复核后，先运行脚本只读校验，再明确使用 `--validated --commit` 按组提交。脚本默认不写 Git；核对工作区、分支、完整基线、空暂存区、范围、最终文件与产物 hash，范围漂移立即停止，不重置或清理。

其他页面批次也可能改 `FeatureLightfield.owns` 和共用组件；合并时保留各批新增模块，并同步未迁移模块数量，不把本批的 `.privacy` 覆盖掉。

JEV 状态 BLOCKED：`mcp__jev__jev_decide` 返回 `MCP tool call requires approval, but approval policy is never`，未获得推理/判断结果。该工具接口没有 model 参数；未擅自替换模型，也未把自动拒绝写成 JEV 通过。记录在 `jev-decision.json`，主会话可在可用环境追加独立判断。

## fix1（2026-10-10）

### 主会话 r1 反馈与根因

本节为增量交接，基线是 HEAD `0ca11ff5b9ddc7e87d50b4c652685cb5c0092b7c` 加上原 prepared 的四组 r1；没有覆盖或重生成原四组补丁。开工逐一核对了 r1 的 17 个最终文件 SHA-256，全部匹配。增量补丁、r1 文件快照及校验脚本在 scratch `prepared/fix1/`。

已读取 `logs/main-final-1240/`：r1 沙箱外定向 202/0；全量 4477 项、1 个失败、25 项既有 skip；反证 8/10。全量唯一失败为 `ConceptLandingNativeLayoutRegressionTests.testEveryLandingPageFitsInTheRealPageContainerAcrossTheSizeSweep`。完整诊断位于 `full.log:3237–3238`：中文第一轮的 privacy 起始页在真实详情区 **655×468**，缺少 `lightfield.title`、`lightfield.content`、`lightfield.primary`、`lightfield.status`、`lightfield.options.scrollViewport`、`lightfield.optionsEnd`。现存帧的资源名 `module-privacy-512` 与旧 `concept-landing.*` 骨架确认该页仍挂载旧 HeroScanPage；健康不是本次缺探针的页面。

原因是 r1 已令 `FeatureLightfield.owns(.privacy)` 成立，但全页测试的 privacy 夹具仍使用 V1 hero。真实生产隐私起始页已经走光场，不过它的选项探针仍用独有前缀且没有最后一项探针；切到真实页后，还需补齐共用的滚动契约。

### 改动与原断言保留

- `BrowserPrivacyWorkspaceView.swift`：只把选项滚动探针改为共用 `lightfield.options`，并在 DEBUG 下加 1 pt 的末项测量探针 `lightfield.optionsEnd`；保持真实选项、滚动实现与 D67 骨架。
- `ConceptLandingNativeLayoutRegressionTests.swift`：privacy 夹具换成真实 `BrowserPrivacyWorkspaceView`，注入惰性匿名扫描器并标记 fixture，避免 onAppear 的维护动作。**没有改该测试的尺寸数组、双语循环、页面列表、阈值或断言**。原 7×9 详情尺寸、真实 AdaptivePageViewport、52 pt 按钮、0.5 pt 边界、标题至少 48 pt、末项滚动可达的原意全部保留；依据 D67 与 D70②迁移实际页面。
- `BrowserPrivacyLightfieldNativeTests.swift`：新增独立 privacy 实页测试，复用同一真实容器、同一 7×9 尺寸和双语组合，共 126 个布局场景，能在沙箱内运行；额外要求标题/内容/按钮/状态行均在容器内，内容到按钮间距为 24 pt。
- `BrowserPrivacyPreviewFixture.swift`：惰性 fixture 工厂可选注入匿名 scan outcome，默认原夹具不变。只在 DEBUG，仍注入无写入处理器和空运行状态检查器。
- `BrowserPrivacyLightfieldTests.swift`：新增共享匿名 test fixture，把两个可单独审阅、但 locator 为 nil 的手动项放进同一个 Chrome 默认配置文件，分别与普通/敏感可删项共享站点；校验筛选组中确实存在这些项，再以独立期望集合验证批量选中和反选仍排除它们，同时保留筛选外原已选手动项。
- 同一原生敏感测试：初始 bucket 的 AX 值必须是折叠，所有敏感站点的**打码名、原域名、页面标题/网址均不存在**，实际生产页面行探针也不存在；第一次显式点击后出现打码名但没有页面行；第二次站点点击后才出现原域名及真实 `BrowserPrivacyLightfieldPageRow`；收起后再次不存在。测试同时实际按下配置文件/敏感分组的勾选按钮，要求请求集合精确排除同组手动项；仅模拟审阅通过后的 Store 选择回调，核对它们仍未选择，不调用删除。

`ScanStore.swift`、生产 BrowserPrivacy Store/处理器/备份恢复/手动流程、健康检查与事件逻辑均未改。现有敏感状态与整组选取实现本来正确；本轮加强行为测试以防这两个变异漏检。

### 沙箱验证

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| Debug 含测试编译 | PASS，exit 0，16.07 秒；无新增源码警告 | `logs/fix1/build-final.log` |
| 定向清单（加入原全页失败用例） | FAIL，exit 1；204 项、194 通过、10 失败用例、15 失败断言（7 unexpected），0 skip | `logs/fix1/targeted-1.log` |
| 隐私原生测试 | PASS，6/6；包括 126 个真实容器场景与两步敏感披露 | 同上 |
| 隐私展示/选择测试 | PASS，6/6；包括同组手动项排除 | 同上 |
| UIConsistencyRegressionTests | PASS，46/46 | 同上 |
| private API / diff / 增量 replay / SHA-256 | 见 fix1 静态检查记录 | `prepared/fix1/static-checks.json` |

原全页 sweep 与原 6 个 FeatureLightfieldContractTests 用例都在 `TestFileSystem.swift:60` 创建家目录操作 fixture 时抛出 Cocoa 513/POSIX 1，明确 `Operation not permitted`，尚未进入页面布局。两项原偏好持久化测试仍有 `sandbox_extension_issue_file ... defaults.plist ... Operation not permitted`。原剪贴板测试仍失败；r1 已被主会话沙箱外 202/0 验证，本轮保留其五个断言，未改剪贴板实现或把本轮服务失败声称为通过。10 个失败用例的完整名称在 `prepared/fix1/validation-summary.json`。

第一次编译已通过，但匿名 tuple 的类型推断产生 Optional 字符串插值警告；为夹具站点列表声明明确的 `(String, BrowserPrivacyCategory)` 类型后重新编译通过，最终测试只用该最终构建。没有删断言、放宽阈值、跳过测试或调整产品路径安全检查。

### 红/绿/反证与主会话剩余检查

原红证据是 `main-final-1240/full.log` 的唯一失败及 `mut/summary.json` 的两项未捕获。沙箱绿色行为证据是两类隐私测试 12/12 和新增 126 场景；**不能代替原全页 sweep 的沙箱外复跑**。

`counterexamples.json` 保留原 10 个变异的 path/before/after。`group-manual-exclusion` 的 filter 扩为展示选择测试加实际原生分组操作测试，两者都带同组 locator-nil 项的独立期望。`sensitive-default-open` 仍指向原生敏感测试，现在以打码域名行的初始缺席拦住变异，而不仅检查原域名缺席。另加第 11 个 `privacy-landing-stale-fixture`，精确把全页测试 privacy 夹具变回旧 hero，要求在 655×468 重现六个缺探针的红诊断。每个 before 静态匹配一次。

本轮按 `codex-build-common.md` **没有跑全量或执行变异**，fix1 11 项反证状态为 NOT RUN。主会话应在空闲的沙箱外环境：

```zsh
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b5
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b5/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
TARGET_FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b5/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$TARGET_FILTER"
swift test "${F[@]}" --skip-build
```

按更新后的 JSON 每次只改一项、运行对应 filter 应红，恢复后应绿；记录原 10 项及新增第 11 项实际捕获结果。再完成项目完整门禁。离屏场景沿用 r1 清单；fix1 优先重拍隐私起始页 655×468 详情区（双语）、两个低高窗口，以及敏感“初始/打码/具体页面”三步与整组勾选后的手动项未选状态。全部使用匿名夹具。

### prepared/fix1 与状态

三组增量：`01-landing-and-fixture`（生产选项探针、可注入惰性 fixture、全页测试迁移）、`02-selection-and-sensitive-tests`（真实容器尺寸 sweep、敏感初始缺席、同组手动项排除）、`03-handoff`（仅追加本节）。补丁以 r1 最终文件为旧版本，不是直接以原 HEAD 为旧版本；manifest 记录原 HEAD、r1 四组 hash、组合基线 tree、fix1 最终文件/产物 hash。`base/` 保留已核对的 r1 版本。

新的 `commit-prepared.py` 默认只读校验，不使用旧 r1 脚本的过期最终文件 hash。主会话完成外层验证后明确传 `--validated --commit`：若 HEAD 仍是原基线，就先按原四组补丁提交 r1，再按三组增量提交 fix1；若 HEAD tree 已是 r1 四组完成后的组合 tree，就只提交 fix1。分支、空暂存区、范围、基线 tree、文件和产物 hash 任一不匹配立即停止；没有自动 reset/clean/push/安装。沙箱内只执行只读校验，未写 Git、提交或安装。

JEV 复核再次 BLOCKED：`mcp__jev__jev_review` 被工具审批机制拒绝，返回 `MCP tool call requires approval, but approval policy is never`。没有获得模型判断；记录在 `prepared/fix1/jev-review.json`。fix1 全量、反证捕获、外层页面验收及提交均待主会话完成。

## fix2（2026-10-10）

### 合并解冲突部分（与 fix2 修复分组）

本轮开工时 HEAD 是 `2d223d937adaa7a605503c2031e0a94c357eedbb`，未完成合并的 MERGE_HEAD 是 `a674de6a01fe006d2f2c9f70e74e548d604819c5`。只编辑工作文件，未执行 add、commit、abort 或其他 Git 写操作。开工与交付的 index SHA-256 都是 `e711ae6e33f07f4a17d2b31fe82b617e4c4fd35ec6aec46d0288f8b52297f320`；五文件的索引仍显示 UU，工作文件已无冲突标记，等主会话 staging 和提交合并。

- `FeatureLightfieldResultFixture.swift`：同时保留 privacy 与 updater 结果入口，保留 B4 应用夹具。
- `FeatureLightfield.swift`：一期 pilots、privacy、updater 的 ownership 合并为同一判断。
- `FeatureLightfieldComponents.swift`：同时保留 B4 的状态初始化和 B5 的 `featureStatus` 覆盖；状态取值优先级为 featureStatus、tone、模块默认值。统计列/卸载组件及 20 pt 状态符号契约保留。
- `FeatureLightfieldContractTests.swift`：按已接入的 privacy/updater 迁移未接入模块数为 9，保留双方原生布局和卸载断言。
- `FeatureLightfieldReleaseIsolationTests.swift`：合并双方严格 DEBUG 夹具名单；fix2 再为无内容标识的 `BrowserPrivacyRenderProbe` 添加相同守卫。

另外 40 个自动合并文件逐一核对 SHA-256，未再编辑，包含 B4、D73 风扇/充电恢复和偏好迁移。`CalibrationLanguageScope` 只在独立文件定义一次，偏好卫生白名单只保留该文件的 2 次 volatile domain 调用，旧内联文件条目已由集成分支移除。解冲突后单独编译 PASS，`logs/fix2/merge-build.log`，206.03 秒。

### 独立复核 P1/P2 修复

已阅读 `logs/codex-review.log` 全文及末尾诊断，并实际打开冻结日夜 PNG、读取对应 HTML。新增会话内 `BrowserPrivacyDisclosurePolicy`，用浏览器、配置文件、域名标识敏感站点；一个站点中有成人/金融记录时，该站点的普通页面也受保护。生产列表、批量选择、确认、运行浏览器预检、手动确认、回执、搜索和计数均传递同一披露状态。

未明确展开的项只提供“敏感网站 · N 条”汇总；域名候选、页面清单、标题/地址包装器、访问明细与 AX 不发布域名、标题或路径。回执遇到敏感项使用现有结构化中文原因，隐藏可能含标题/路径的旧自由文本 detail；手动按浏览器列域名与复制域名只接收已披露记录。回执提供显式审阅按钮后才恢复详情。删除前保存展示记录和敏感站点集合，即使删除已回读成功，回执及同站点剩余普通页面仍打码，不因敏感记录从当前列表移除而解密。

搜索后台匹配仅覆盖可见记录；未披露的敏感汇总数量不随域名/标题/路径查询变化，避免以匹配数量确认敏感内容存在。搜索后的全选/反选不会取得隐藏匹配项的 UUID。无文本搜索时仍可从敏感组整组勾选可删项；新的批量敏感选项排除 locator 为 nil 的手动项，只有手动项时禁用。原浏览器退出确认、整页删除、备份、失败原因、回读及恢复处理器未更改。

P2 的多个配置文件问题也已修：每个浏览器只有一行敏感汇总，跨该浏览器的配置文件收集敏感站点，显示在首个配置文件组的普通域名前。保持两步显式披露：打开敏感汇总只出现打码站点，进一步点击站点才显示真实域名和具体页面；收起敏感组或配置文件组会重新锁定该浏览器。

性能修复在 Store 的呈现投影内完成，未改扫描/处理器语义。`BrowserPrivacyResultIndex` 在后台建立记录索引、归一化搜索字段、浏览器/配置文件元数据和聚合；按记录集版本、筛选、排序、披露状态缓存最多 4 个快照。新扫描/删除使记录版本变化并失效，选择重绘复用已有聚合。文字条件变化使用 200 ms 去抖、后台任务、取消和 generation 校验，最终快照回到主线程发布；过时任务不能覆盖新查询。筛选待更新时锁住选择和删除确认，搜索输入仍可编辑。

配置文件、域名、页面均用 LazyVStack。共用 `FeatureOptionsScrollView` 增加默认关闭的惰性布局选项，仅 privacy 开启，避免外层 fixedSize 迫使整份列表展开测量；B4 原默认行为保留。严格 DEBUG 的渲染探针只计数，不记录页面或域名内容。

`ScanStore.swift` 及 BrowserPrivacy 模型/扫描器/处理器/备份恢复等 13 个保护源文件相对 HEAD SHA-256 完全一致。Store 的变更限于本轮明确授权的异步筛选、缓存、披露与回执展示记录；没有扩大删除范围或改变 SQL/处理 API。

### 测试覆盖与旧断言迁移依据

新增 `BrowserPrivacyDisclosureTests` 7 项：中英双语逐出口隐藏/披露、搜索计数与候选不泄露、同浏览器两配置文件合并一行、真实批量弹层/回执 AX、混合敏感站点与回执存档、强制残留展开状态仍不挂载敏感访问明细、删除回读成功后剩余普通页面和批量候选仍保持敏感。新增 `BrowserPrivacyPerformanceTests` 3 项：实际搜索输入在去抖期间可编辑、50,000 条/2,000 域名的缓存与响应预算、所有域名展开的首屏预算；另用单域名 50,000 页面检测嵌套页面栈的惰性。

- `BrowserPrivacyRecordScannerTests`、`BrowserPrivacyLightfieldTests`、原生敏感测试：由于本轮后台投影改为异步，在筛选/排序变化后等待实际发布，保留所有原期望集合与次序。敏感内容的精确匹配用例先显式披露，原域名/标题/路径/关键词匹配断言不变；新测试另要求未披露时不匹配。原生测试补充待更新时整组选取无回调，再等待 AX 按钮真正恢复可用后执行原精确 UUID/手动项排除断言。
- `PrivacyCleanupPresentationTests`：普通页面格式 helper 默认类别从 finance 改为 shopping；成人/金融由新增显式敏感测试覆盖，不能继续把隐藏金融记录当作普通格式样本。回执改为 internal 以便实际原生宿主测试，只迁移源码定位标记，保留备份/删除/保留期断言。200 ms 源码守卫移到实际 Store，并加后台任务守卫；刷新禁用条件守卫加入 isFiltering，原处理/扫描锁定条件保留。
- `DeclutterD4D5ContractTests`：文字行从 domain 改为安全 option.title，选取出口迁移为普通网站/敏感汇总两种 scope，保留文字行不加装饰、选择仅加入 UUID 的原意。
- `FeatureLightfieldReleaseIsolationTests`：严格 DEBUG 名单增加计数探针。D67 全页 sweep 的尺寸、语言、阈值和断言未变；隐私独立真实容器的 126 场景继续通过。没有为沙箱权限问题删除断言、跳过测试、迁移家目录操作夹具或放宽产品路径检查。

### 沙箱实际验证

| 检查 | 结果 | 日志 |
| --- | --- | --- |
| 最终 Debug 含测试编译 | PASS，9.39 秒 | `logs/fix2/build-tested.log` |
| 23 类定向清单 | 300 项：287 通过、12 失败用例、1 既有 skip；17 失败断言（9 unexpected），53.789 秒 | `logs/fix2/targeted-tested.log` |
| 新披露 / 性能测试 | 7/7、3/3 PASS | 同上 |
| 原隐私原生 / 展示选择 | 6/6、6/6 PASS；原生含 126 个真实容器布局场景 | 同上 |
| BrowserPrivacyRecordScannerTests | 51 PASS、1 既有 opt-in 真实扫描 skip；未启用真实数据测试 | 同上 |
| D73 风扇恢复 / 充电展示 / B4 应用展示 | 6/6、16/16、5/5 PASS | 同上 |
| UIConsistency / private API / diff | 46/46 PASS；7 处已允许 private API；diff 无空白错误 | 同上及 `static-checks.json` |

50k 无磁盘夹具扫描到索引 2.481 秒（预算 6 秒），按键请求 0.0525 ms（50 ms），搜索含 200 ms 去抖 448 ms（800 ms）。2,000 域名/单域名两种全展开首屏分别 187/279 ms（1 秒）；都只构建 5 个域名行和 10 个页面行（少于 200/300）。这些是当前沙箱的实测与测试预算，不代表真实数据库扫描或目标设备端到端性能验收。

失败用例全名及分组见 `prepared/fix2/validation-summary.json`：原全页 sweep、B4 两项原生页面测试、光场六项原生操作测试，共 9 项在 `TestFileSystem.swift:60` 创建家目录 fixture 时已抛 Cocoa 513/POSIX 1 `Operation not permitted`，尚未进入布局；两项原偏好持久化测试因 defaults.plist 沙箱扩展权限失败。另一个原剪贴板测试保留五项安全断言，但本轮 URL 回读 nil，须主会话沙箱外复测，未声称通过。新增行为、性能及原敏感默认折叠/手动排除断言均通过。中间失败（AX 未就绪及旧源码定位）已修，专项复测与最终定向日志都留存。

按 `codex-build-common.md`，本轮未执行全量或任何变异。没有安装、启动已安装 App、读真实浏览记录或写硬件。

### 反证、离屏验收与主会话后续

`counterexamples.json` 原 11 个 mutation 字典原样保留，path/before/after/filter 未改，所有 before 仍精确命中一次。`logs/main-final-1420/mut/summary.json` 记录 fix1 的 11/11 捕获，仅为旧版本证据；本轮需重新执行。新增 11 条覆盖批量敏感域名、确认页面、回执自由文本、搜索计数、残留页面 AX、域名/页面非惰性、去抖移除、缓存禁用、删除后敏感分类丢失、去抖禁用搜索框。全部 22 条当前状态 NOT RUN，不能把精确定位或绿色原版测试当成实际捕获。

主会话先在当前合并工作文件完成验证，再自行 staging/提交；不要在已含改动的文件上重复应用补丁：

```zsh
cd /Users/developer/Developer/sc-worktrees/r2-lf2-b5
python3 /Users/developer/Developer/.sc-build/r2-lf2-b5/prepared/fix2/verify-prepared.py
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b5/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
TARGET_FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b5/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$TARGET_FILTER"
swift test "${F[@]}" --skip-build
```

按 JSON 每次只施加一个精确变异，编译后跑对应 filter 应红，恢复并重新编译后应绿；记录 22 项实际捕获和所有原全量门禁。全页 sweep 不得放宽；家目录/偏好/剪贴板失败均需在沙箱外消除。

主会话需重拍/读回（仅匿名夹具，日夜、中英与原七尺寸）：

- privacy 起始/运行/结果，特别 655×468 真实详情区及 677×390、1280×390 低高窗口；内容滚动、最后一行可达、列表与固定主按钮间距 24 pt。
- Chrome 两个配置文件只有一个敏感汇总；默认折叠 → 打码站点 → 明确披露具体页面 → 收起重新锁定。每阶段核对实际 AX、tooltip、域名/标题/路径。
- 未展开就打开批量选择、勾敏感组、删除/退出浏览器预检、手动确认、回执摘要与按浏览器复制域名；隐蔽搜索和无匹配查询的汇总数量一致。再显式披露，核对相应出口可审阅具体内容，整组选取仍排除手动项。
- 混合敏感站点删除回读成功后的剩余普通页面、回执及批量选项；收起后继续打码。处理失败中文原因、备份/最近删除/恢复入口继续沿用隔离夹具。
- 50,000 条、2,000 域名及单域名 50,000 页全部展开：首屏、连续搜索、快速切筛选、滚动到末尾；输入可编辑，待更新期间不能对旧列表选取/确认，固定按钮不被列表覆盖。
- 健康现有结果布局下 SIP/FileVault/Gatekeeper/防火墙及事件日志的 StatusGlyph、行高与字号；B4 卸载/更新统计列和 D73 恢复入口由主会话合并后的对应批次门禁复核，不写硬件。

### prepared/fix2

四组：`00-merge-resolution`（原五文件冲突输入 → 双方保留的解冲突版本）、`01-privacy-disclosure-and-index`、`02-behavior-and-performance-tests`、`03-handoff`。`merge-input/` 保存开工 45 文件，`resolved-base/` 保存解冲突后增量基线，`final/` 保存最终 23 个文件；四组及 all.patch 在独立临时目录顺序回放后与工作文件 SHA-256 一致。manifest 包含 HEAD/MERGE_HEAD/index、其余 40 文件、13 个保护源文件、补丁顺序及产物 hash。旧 r1/fix1 包未覆盖。

`verify-prepared.py` 只读检查未完成合并、范围、文件/产物 hash 与 22 个定位，没有 add/commit/abort 入口；主会话修改索引或提交后可传 `--files-only` 只查文件，不能把该模式当 Git 状态验收。本轮不提供自动提交未完成合并的脚本。

JEV 调用 `mcp__jev__jev_decide` 被工具审批策略拒绝：`MCP tool call requires approval, but approval policy is never`。未取得模型判断，记录在 `prepared/fix2/jev-review.json`；未擅自换模型。全量、22 条变异捕获、七尺寸离屏验收和合并提交仍待主会话完成。

## merge2（2026-10-10）

### 本轮基线与解冲突

主会话已完成 fix2 沙箱外验证并获得“可以合并”的 r2 复核；本轮以 HEAD `682636701b7b7b4743386f64c2a9cb52e5a96a28` 和未完成合并的 MERGE_HEAD `f8c2874ef373feb73719b74cb081e6309d2ab1ed` 为基线。只编辑工作文件，没有 add/commit/abort 或其他 Git 写操作。index SHA-256 保持 `99791ecd356507a5933c32ad0226d0f5f94f97fd4bbbf3441df9da073c0a1ea7`，三文件索引仍 UU，工作内容已清除冲突标记，等待主会话 staging/提交。

- `FeatureLightfield.swift`：保留一期 green/healthHub/uninstall，并集加入 B4 updater、B5 privacy、B7 largeFiles/migration/duplicates，共 8 个光场路由。保留 B7 的 `primaryHeight: CGFloat = 52` 和几何/按钮对令牌的引用，未改坐标、尺寸或动效。
- `FeatureLightfieldContractTests.swift`：保留集成分支的精确路由集合断言，加入 privacy；14 个演示模块减去 8 个已迁移路由，剩余计数为 6。计数 9/7 → 6 是双方路由并集的迁移，不是范围或阈值放宽；所有其他布局、AX、安全与卸载断言保留。
- `FeatureLightfieldReleaseIsolationTests.swift`：严格 DEBUG 检查取双方六文件并集：ResultFixture、PresentationDemo、FileResultFixture、ApplicationsFixture、BrowserPrivacyPreviewFixture、BrowserPrivacyRenderProbe。前后 guard、禁止 DEBUG/BETA 混用、截图入口隔离断言全部保留。

其余 78 个自动合并文件逐一核对开工/最终 SHA-256，未再编辑：保留 B4-P2 统计列、B7 四文件页面、B6 设置拆分、辅助类移动及 D74 文档。26 个保护文件（完整隐私生产目录/相关视图、ScanStore、CalibrationLanguageScope、偏好卫生守卫）也与开工完全一致。因此 B5 层级、披露、懒加载和处理链沿用已获外层验证的实现。

`CalibrationLanguageScope` 仅在 `Tests/StorageCleanerMacTests/CalibrationLanguageScope.swift` 定义一次；偏好卫生白名单仍只登记该独立文件的两次 volatile domain 写入，未恢复旧内联定义或条目。

### r2 第 5 条 P2：先行数断言，再压力测试

已读 `logs/codex-review-r2.log` 末尾完整六条复核。第 5 条指出非懒加载变异在原五万页测量/预算断言前 signal 6；本轮只按该条调整 `BrowserPrivacyPerformanceTests`，未扩展到第 3/4 条的既有 P2 生产逻辑。

`testFiftyThousandExpandedPagesBuildOnlyViewportRows` 先在同一真实生产结果页宿主中运行 **1,000 页单域**，随后运行 **400 页/400 域**。单域小夹具检查页面栈，多域小夹具检查域名栈，让两个非懒加载变异都能在有界数据集上检查。每次先断言域名/页面构建数大于 0、少于 **200/300**，任何行数预算失败就返回 false，由调用方 guard 立即结束当前失败用例；不会继续建立更大的压力宿主。XCTest 失败已记录，不是 skip 或吞掉错误。

小夹具通过后，仍执行原 **50,000 条/2,000 域** 和 **50,000 条/单域** 两种全展开压力。共用 helper 保留原 **1 秒首屏**预算，并把耗时断言放到行数断言之后；计数不合格优先报告行数失败。fixture 新增默认 50,000 的 recordCount 参数，压力数据规模和搜索目标仍是原值。索引 6 秒、按键 50 ms、主线程 heartbeat 150 ms、搜索含去抖 800 ms 等其他原阈值与断言均未改。

### 沙箱编译与定向结果

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r2-lf2-b5/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
TARGET_FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-lf2-b5/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$TARGET_FILTER"
```

| 检查 | 实际结果 | 日志 |
| --- | --- | --- |
| Debug 含测试编译 | PASS，exit 0，218.42 秒；只有既有 SwiftPM 缓存/弃用提示，无新增源码警告 | `logs/merge2/build.log` |
| 34 个定向筛选项 | exit 1；352 项，336 通过、15 失败用例、1 既有 skip；20 失败断言（11 unexpected），88.018 秒 | `logs/merge2/targeted.log` |
| B5 性能 / 披露 / 原生 / 展示选择 | 3/3、7/7、6/6、6/6 PASS | 同上 |
| 路由精确集合与计数 / 六夹具严格 DEBUG | 对应源码契约和隔离测试 PASS | 同上 |
| B4-P2 / B7 性能 | 4/4、3/3 PASS | 同上 |
| B6 设置光场 / 原生几何 / 权限 | 3/3、5/5、5/5 PASS | 同上 |
| UI 一致性 / private API / diff | 46/46 PASS；7 处允许的 private API；diff 无空白错误 | 同上及 `logs/merge2/private-api.log`、`diff-check.log` |

视口实测与计数：

| 夹具 | 首屏 | 域名 / 页面构建数 |
| --- | --- | --- |
| 1,000 页 / 1 域，前置检查 | 99 ms | 5 / 10 |
| 400 页 / 400 域，前置检查 | 96 ms | 11 / 6 |
| 50,000 页 / 2,000 域 | 135 ms | 5 / 10 |
| 50,000 页 / 1 域 | 200 ms | 5 / 10 |

同轮 50k 索引建立 1.694 秒、按键请求 0.0186 ms、搜索含去抖 337 ms，均在原预算内。这是匿名无磁盘夹具/当前沙箱的实测，未作为真实历史数据库或目标设备验收。

15 个失败用例完整名称与证据分组见 `prepared/merge2/validation-summary.json`：**11 个家目录夹具创建权限失败**（旧 9 项，以及 B7 的 duplicate metadata cache 和四文件三态矩阵），都明确为 Cocoa 513/POSIX 1 `Operation not permitted`；**3 个偏好持久化失败**（旧两项加 B6 的重新打开隔离偏好套件），日志为 defaults.plist sandbox extension 权限失败；**1 个原剪贴板用例**保留五项安全断言，本轮 URL 回读 nil，仍需沙箱外确认。B7 的无 Store 结果矩阵通过，完整三态矩阵只在后续家目录 Store 夹具创建时阻塞；未削弱它的全尺寸/三态要求。真实浏览器 opt-in 用例保持既有 skip，未启用或读取真实记录。

按 `codex-build-common.md`，本轮未跑全量或任何变异，未为环境阻塞改路径规则/夹具、删除断言、跳过测试或放宽阈值。

### counterexamples、交付与主会话后续

原 **22 条 mutation 字典全部原样保留**（path/before/after/filter/expected_occurrences），每个 before 仍精确命中一次，无需位移改写；只更新顶层 merge2 基线和 NOT RUN 状态。旧 fix2 的 21/22 是 r2 复核记录，不代表本轮捕获；本轮行数先失败的行为仍需主会话实际施加变异验证。

`prepared/merge2/` 三组：`00-merge-resolution.patch`、`01-perf-test-order.patch`、`02-handoff.patch`，含 all.patch、message、manifest、只读校验脚本及证据。`merge-input/` 保留三个带标记文件；`resolved-base/` 保存解冲突版本与性能/交接旧版本；`final/` 保存本轮五个最终文件。三组在独立临时目录回放后与 worktree SHA-256 一致，78 个自动合并文件、26 个保护文件及 index hash 均未变。旧 prepared/fix2 等包未覆盖。

主会话先在当前文件上只读核验（不要重复应用补丁）：

```zsh
python3 /Users/developer/Developer/.sc-build/r2-lf2-b5/prepared/merge2/verify-prepared.py
```

再在沙箱外用本轮 34 项清单复跑定向及完整门禁，消除 15 项环境/回读失败。按原 JSON 每次只施加一个精确变异、编译后跑指定 filter、恢复并重新编译后应绿。优先核对 `lazy-page-stack` 在 1,000 页单域检查以 **pages < 300** 的 XCTest 断言失败并退出，`lazy-domain-stack` 在有界多域检查以 **domains < 200** 等原行数预算失败退出；日志不应出现五万页测量或 signal 6。记录全部 22 条实际红/绿结果后，主会话自行 staging 并提交这次未完成合并。校验脚本没有 Git 写入口；提交后 `--files-only` 仅查文件，不代替 Git 状态核验。

离屏场景沿用 fix2 清单，并在合并后的 B7 四文件页面确认主按钮实测 52 pt、七尺寸结果/滚动结束，B4 统计列边界和 B6 真实小窗预览布局保持原对应批次契约。B5 默认敏感折叠、两步披露、整组手动项排除和懒列表继续使用匿名夹具重拍；本轮未启动已安装 App 或安装新包。

JEV `mcp__jev__jev_review` 调用被工具审批策略拒绝，原因为 `MCP tool call requires approval, but approval policy is never`，未取得模型判断。接口不提供 model 字段，未换模型；结果保存于 `prepared/merge2/jev-review.json`。
