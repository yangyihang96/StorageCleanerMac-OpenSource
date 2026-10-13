# r2-results-space — 2026-10-11 实机意见修复

基线：task/r2-results-space，1a3b6822990634a4aaea5ed20894956f7bd81fc4。工作区修改已准备，未创建提交；.git 按只读处理，交付 scratch prepared/。未启动 App、安装、扫描真实数据、执行文件移动或硬件写入。

## 已审阅的输入与根因

先逐张查看七张用户截图：卸载、登录项、能耗、系统健康、内存、浏览器隐私 active、安全清理 before-scan。路径及 SHA-256 见 scratch review-inputs.json。浏览器截图只有运行态，不能作为结果页实机读回；本批以惰性数据夹具验证其结果布局。

1. 共用结果几何仍从落地页标题、窄列和大按钮的位置扣高度；内容内再占 76 pt 摘要与 20 pt 间距。1280×763 的详情画布为 1070×735，旧内容框仅 878×395，实际列表更小。内存生产入口有样本后仍默认压力预览，必须额外点击才能进入列表。
2. content 的阶段 identity 使用 opacity/offset 退场过渡，外层 featureFlowTransition 和页内 phase 动画会保留旧状态树。旧截图管线把 busy=false 当成 settled，最长 0.56 s 布局/1.42 s 局部进入尚未结束就截图，旧文字、按钮和插画可能同时出现。本批立即替换阶段树并清除继承阶段动画；状态层计数放在 content 子树本身，旧身份若被保留也会计入。没有靠透明度遮蔽旧文字。

## 结果布局与数据流

D77 已追加到 DECISIONS.md，依据本次 A/C/D/E 局部取代 D67/D69 和 D70①/D71② 的结果布局冻结。启用范围：安全清理、系统健康、浏览器隐私、性能测试、登录项、内存、能耗、卸载。应用更新、文件页面保留原几何分支。

- 结果头部预算 72 pt：40 pt 模块图标、20 pt 标题、紧凑数字/摘要，只加载 header 导出。摘要通过数据 preference 传给头部，原摘要不渲染第二份视图。
- 1280×763：内容 x=24,y=72,w=1022,h=607；底栏 y=687,h=48；主按钮 x=846,y=695,w=200,h=32。内容宽高随窗口增加。全高原生滚动替代旧五行/行边界吸附，末端仍有淡出。
- 操作记录、状态、刷新、安全说明与主按钮在底栏内各有空间；原生测试测量每项实际文字/按钮框互不相交。窄窗安全说明仍在主按钮辅助提示中保留。
- 内存生产入口 showsResultsWhenSampled=true，完成采样直接显示进程/应用；显式压力预览与未采样起始页保留。内存、能耗首项默认折叠；选择/确认/正常退出流程不变。
- 能耗首项位于列表 header 中但不自动展开，避免用户展开长进程组后污染其余 400 行的 LazyVStack 高度估计；展开才异步读取子进程身份。400 行、<60 构建行、末项可达、缓冲复用、不在主线程解析继续验证。
- 未修改 ScanStore.swift、Views/MenuBar* 或 Features/AppUpdates/**。登录项通过共用框架获得结果布局，未改其 Features/StartupItems 管理实现。

## 性能测试：定稿要求 → 现状 → 改动

已读 UI-V2-SPEC.md、LIGHTFIELD-R2-PLAN.md、r2-bench-v11-ui.md。本 worktree 没有未跟踪的 concept-comparison artifacts，已只读查看 Developer/StorageCleanerMac 下的 comparison-matrix.json 与 references/029；矩阵该项是 NOT ACCEPTED，旧四类未测试原图不能覆盖 D72。较新唯一标准为 r2-bench-v11/mockups/approved-20261010/；已查看 landing、running、标准 result、provisional、nohelper 的日/夜代表图，哈希见 review-inputs.json。

| 定稿要求/依据 | 基线现状 | 本批处理 |
|---|---|---|
| D72/10-10 起始页：CPU 4+4、GPU 3、内存 3、存储 4；独立扩展 | v11 Landing 已实现，但自动加载旧 v9/v10 记录会跳过它进入旧 Dashboard | 未手动选历史且最新记录非 v11 时使用批准的 v11 Landing；旧 Dashboard 仍用于显式历史记录 |
| 运行态：真实阶段/原始观测、可取消、独立压力/加速单元 | v11 Running 已有批准的适配 | 保留，消除跨阶段旧内容；不改 workload、取消规则或采样 |
| 芯片/整机/能效三分及口径 | 数据适配正确，旧摘要占内容 76/150 pt | 宽窗放入紧凑头部；内容宽度 <600 pt 时次分数放可滚动详情首行，三项均可读 |
| 暂定前缀与实际基准；待校准不得编造 | ScoreDisplay 与参考状态正确 | 完整数值、前缀、辅助朗读保留；参考正文放结果详情，大数仍遵守 0.5 原下限 |
| 四个 CPU/GPU 倍率、1× 参考、CPU 能效与持续性能双轴曲线 | 图形已实现，但只在很小区域可见 | 保留 4/2 列响应、粉色倍率/吞吐、温度轴、线程标签；扩大 viewport，去掉大按钮占用 |
| 无助手：能效不可用、可进设置 | 摘要底部 overlay 设置按钮，易挤占文字 | 设置与说明放独立滚动详情；曲线区域入口保留，两个真实 AXPress 均可达 |
| 六分区、18 原始值、规格来源、历史 | 已实现；历史结果仍扣摘要及 96 pt 左缩进 | 分区留在滚动区上方；历史使用共用全高列表，保留原始值/来源/记录打开 |
| 社区榜未上线不可提交、匿名上传默认关、旧协议不重释 | 已正确实现 | 保留；未启用参考集、发上传或实际跑分 |
| 10-10 图中高标题、大芯片分、大重测按钮 | 与最新 A 要求冲突 | D77 压缩三处，保留内容组织与图形；不宣称逐像素复刻或严格视觉验收 |

## 四个安全清理范围图标

实际用 image_gen.imagegen 生成透明背景橙色玻璃 3D 图：缓存为叠层/闪电、日志为横线卷页、临时文件为沙漏、下载残留为向下箭头/托盘。参考 set-A prompt、style-A-scan、style-A-memory、module-cleanup，沿用 #FF8A3D→#C44A16、左上光及圆润高光。

请求 1024×1024，工具实际返回 1280×1280；原件保留 scratch/icons/*-generated.png，再导出 1024 主文件及 192/512 PNG。未返回模型标识，未声称具体图像模型。全部 RGBA，alpha min=0/max=255；提示词/尺寸/哈希见 icon-prompts.json、icon-assets.json。

项目仅收录 Resources/Art/scope-cleanup-{cache,logs,temporary,downloads}-{192,512}.png，通过现有 LightfieldOptionIconView / PNG resolver 加载。40 pt 图在复选框与文字之间，另有灰色说明；下载残留说明要求逐项审阅。测试解码八份资产并等待真正图像分支的 loaded probe，空白占位不算图标。

必要配套修改 build_and_run.sh 的复制循环、make_release_dmg.sh 的复制/复用核对循环：三个循环只增加 scope-cleanup-*.png。未执行打包/安装。原 HEIC 与 70 组 mini-option 的库存/体积预算不变；四范围另有严格 <1 MB 导出预算，原图与 1024 不打包。

## 截图稳定门

runtime audit 在 busy=false 后预热小图，观察正确模块/阶段、content 状态层恰一份、实际内容/底栏，以及稳定帧 ≥0.35 s。最低等待覆盖 1.42 s 局部动画预算（0.38+12×0.04+0.30，再加 art fade 0.26）。5 s 超时后文件名为 unsettled，JSON settled=false，附 stateLayers/frames。

模板、响应尺寸结果和普通 live runtime 结果也使用此门；坐标相对 canvas 原点，避免 titlebar 偏移误判。浏览器实机审计仍只导出 active，未增加真实记录的结果导出；用惰性 privacy 模板及本地人工读回验收。新 App 截图未在本批采集。

## 改写的旧断言

全部依据 D77 / 本次 A/C/D/E；数据安全、旧协议、最小数字缩放和虚拟化预算未放宽。

| 旧测试/断言 | 新合同 |
|---|---|
| FeatureLightfieldContractTests.testProductionPilotsKeepNativeSkeleton…：三态同原点、52 按钮/64 底栏/24 双间距/76 图 | 落地/运行保留；结果独立 72/48/32、40 图、列表与底栏 8 pt |
| 同类 testResultLongListFadesPartialRows…：第 5 行只能位于空白渐隐带 | 改名 UsesFullViewportShowsTenRows…；全高 viewport、≥10 完整应用、末项可达、fade/贴底不动 |
| 同类 testProductionResultPagesEndAbovePrimaryWithoutHalfRows…：边缘文字不得部分裁剪，24 间隔 | 改名 FillContentRemainClipped…；原生全高滚动可有边缘部分行，但裁剪区与按钮相隔 16，历史可达 |
| 同类 testNewTemplatePilotAdapters…：标题固定 34、按钮 17 | 结果 20/13，落地保留 34/17；原样式/安全/复用合同保留 |
| FeatureLightfieldPerformanceTests.testProductionPerformancePages…、testMemoryCheckAndSelectedPrimary…：三态同原点/52 AX 按钮 | 独立结果矩阵/32 实际 AX 按钮；选择、禁用、确认回调保留 |
| 同类 testMemorySelectionAndExpansion…：首项默认展开，第一次按行折叠 | 默认折叠，第一次按行展开；选择不退出、展开不改变选择仍验证 |
| 同类 testResultViewportAndLastItem…：24 与整行吸附 | 全高裁剪/16 间隔；末项可达与 fade 保留 |
| 同类 testEnergyProductionResultKeepsALazyList…：自动首项展开、400×56 文档 | 先按真实 disclosure，再测异步读取期间响应；稳定行 48，400 行/<60/末项/缓冲保持 |
| FeatureLightfieldApplicationPageTests.testApplicationPages…：卸载/更新同旧结果坐标 | 仅卸载结果切新矩阵；更新旧坐标、指标和列对齐全部保留 |
| BrowserPrivacyLightfieldNativeTests.testProductionPrivacyThreeStates…：结果也用旧 Geometry | 结果独立验收边界，起始/运行、敏感分组和选择合同保留 |
| FeatureLightfieldComponentTests.testGalleryArgumentAndAllTwelveFixtures…：520×52 按钮、878 宽 | 12 个画廊结果均满足全高合同 |
| MSeriesV11NativeLayoutTests：同骨架、摘要在内容内/76或150/pinsSummary、设置 overlay | 头部 ≤72；三分含大数/参考变体在各自列内，窄窗次分数在详情可达；参考说明/两设置入口滚动可达，原 0.5 与完整朗读仍验证 |
| GeneratedArtTests：PNG 只允旧 mini 集合，art 只用 landing | 新增精确 8 文件/alpha/尺寸/独立预算；结果 header，旧库存预算不变 |
| UIConsistencyRegressionTests、MSeriesV11ScaleContractTests：未知文件禁缩放 | compact-result-value 只 1 处、原 0.5、精确 receiver/lineLimit；普通标签仍禁缩放 |

## 编译、定向验证与限制

- Debug：最终 `swift build … --build-tests` 退出 0，20.02 s，日志 `logs/debug-build-final.log`。
- Release：最终 `-c release --build-tests -Xswiftc -enable-testing` 退出 0，477.46 s，scratch `release/`，日志 `logs/release-build-native-2.log`。默认 SwiftBuild 引擎首次在 `MemoryFixtureApp` 的 GenerateDSYMFile 被沙箱拒绝（Operation not permitted）；独立 dsymutil 诊断成功后改用本机 CLI 提供的 `--build-system native`。仍保留 Release 优化、测试编译及符号，没有放宽测试阈值；CLI 的 native 引擎弃用警告保留在日志。第一次 native 编译期间测试源仍在修改，失败记录也保留；第二次在源文件固定后成功。
- 最终 26 类：运行 243 项，228 项通过；15 项因权限阻塞，产生 16 条失败记录（其中 13 条 unexpected）。测试进程退出 1，不能称为全绿。完整测试名、错误和各类统计见 scratch `validation.json` / `logs/targeted-final.log`。
- 阻塞分布：FeatureLightfieldApplicationPageTests 2 项、FeatureLightfieldContractTests 6 项、FeatureLightfieldPerformanceTests 5 项，全部在 TestFileSystem.swift:60 建 `~/.storage-cleaner-scan-store-*/home` 时 Code=513 / Operation not permitted，尚未进入布局断言；TestPreferenceHygieneTests 2 项的 CFPreferences 临时 plist 被 sandbox_extension_issue_file 拒绝，产生 3 条持久化断言失败。未移动夹具、删断言、跳过或放宽路径保护。内存生产页的“完成采样后 ≥10 行/放大增行”仍须沙箱外复跑。
- 通过项包含 FeatureLightfieldResultSpaceTests 9/9（实际卸载/登录项/能耗行、8 模块结果预算、窗口增高、单状态树、真实四图加载、底栏无相交、稳定门）、MSeriesV11NativeLayoutTests 9/9（七尺寸/中英/日夜/参考变体、大数完整朗读、两设置入口）、UIConsistencyRegressionTests 46/46、GeneratedArtTests 5/5、浏览器隐私原生 6/6。能耗 400 行惰性构建与异步展开的原预算也通过。没有发现其他非权限失败。
- `git diff --check`、两份打包脚本 `bash -n`、`check_private_api.py` 已通过（7 项允许的已有私有 API 用法）。未运行全量 verify.sh、反证、Release XCTest 或 App 实机截图；后两项以本批授权范围为界，截图验收交主会话。

scratch：/Users/developer/Developer/.sc-build/r2-results-space。targeted-classes.txt 为 26 类，含 UIConsistencyRegressionTests、TestPreferenceHygieneTests、FeatureLightfield*、v11/隐私合同。counterexamples.json 有 18 个逐点反证，已核对锚点/出现次数，未执行。全量门禁与反证由主会话执行。

红/绿/反证均对应实际对象：红来自本次原始截图与已审阅的旧布局/入口代码；绿来自上述最终定向执行；下表的反证只准备锚点及预期失败测试，未宣称已杀死变异。主会话须在独立 scratch 副本逐条变异、编译及执行其 filter，确认退出非零后恢复原件，再运行原始合同为绿。

| 修复 | 红证据 | 绿检查 | 反证 ID / 预期失败 |
|---|---|---|---|
| A/C 全高结果及贴底操作 | 用户卸载/登录项/能耗/健康/内存截图的狭窄结果；旧 878×395 内容 | ResultSpaceTests 的窗口/十行/实际底栏框；内存生产夹具暂被权限阻塞 | result-header-restores-landing-budget、result-artwork-becomes-landing-size、result-primary-is-large-again、result-width-restores-narrow-column、result-list-restores-summary-space 应使结果预算原生断言失败；footer-no-reserved-primary-space 应使实际框相交；memory-completed-sample-stays-on-landing 应使生产路由守卫失败 |
| A 状态叠印 | 旧阶段退场＋外层过渡保留两棵状态树，用户截图旧文字压在结果上 | animated phase 与 reducer 原生/纯数据合同要求字典仅 results:1、旧文本退出 | state-layer-counter-conceals-duplicates 应使 2+1 计数断言失败 |
| B v11 定稿入口/结果 | 自动采用旧记录跳过批准起始页，摘要/设置挤在结果小区域 | PerformanceSourceTests 入口守卫及 MSeriesV11NativeLayoutTests 9 项 | legacy-result-bypasses-approved-v11-landing 应使入口守卫失败；缩回结果宽高还应使新原生摘要/滚动合同失败 |
| D 四图与打包 | green-before-scan 仅复选框/文字 | 四个不同 decoded PNG、真实 loaded 分支、40 pt、两行文本/顺序；两打包循环源守卫 | cleanup-two-scopes-share-one-artwork、cleanup-removes-bitmap-overrides、cleanup-icons-shrink-to-old-mini-size 应使图像合同失败；build-loop-omits-cleanup-pngs、release-loops-omit-cleanup-pngs 应使打包守卫失败 |
| E settled 门 | busy=false 即 settled，60/500 ms 小于过渡预算 | 稳定门拒绝 busy/两层/错误页面/几何变化/未满期限，超时命名源守卫 | settle-does-not-require-one-state-layer、settle-skips-animation-budget、settle-skips-stable-geometry-budget、runtime-labels-busy-false-as-settled 应使对应 gate/命名合同失败 |

JEV：核对 callable jev_decide 没有 model 参数；一次有界判断调用被工具拒绝：MCP tool call requires approval, but approval policy is never。没有返回判断或模型身份，不能声称 JEV 复核通过；主会话可在允许调用的会话补评。

## prepared 交付

`.git` 不写入。三组二进制补丁及对应提交说明：01-results-space（共用结果框架、各功能适配、状态/截图稳定门、四图与必要打包入口及合同测试），02-benchmark-alignment（v11 入口/结果内容与原生布局测试），03-decisions-handoff（D77 与本交接）。最终改动以三组全部应用后的状态编译和测试；未逐组验证中间 HEAD。

prepared/ 提供 all.patch、manifest.json（源文件与产物 SHA-256）、static-checks.json、证据 JSON/定向类副本及 commit-prepared.py。`--check-only` 只核对基线、分支、空暂存区、文件/产物哈希与补丁反向检查；`--validated` 只供主会话完成外部复核、全量门禁和反证后按组提交，不替代这些检查。未运行 `--validated`。基线改变、文件改变或存在其他暂存内容时脚本停止，不能直接在新的集成 HEAD 上套用本包。

## 主会话复跑与验收

1. 检查 prepared/manifest.json、文件/产物哈希与基线，commit-prepared.py --check-only；外部验证/复核后才可 --validated。
2. 沙箱外复跑全部 26 类，包含 ScanStore 家目录夹具和两项 CFPreferences 持久化测试；不移动夹具或放宽路径安全。
3. 执行 counterexamples.json；再用项目 verify.sh 的私有根、VERIFY_BUNDLE=0、UI_SMOKE=0 跑完整门禁。本批没有宣称全量通过。
4. 隔离 QA 副本按原 run-audit.sh --capture-feature-runtime-audit 复拍，检查 JSON settled、singleStateLayer、框坐标；另拍 v11 五种页和七尺寸；privacy 使用惰性模板/本地人工读回。
5. 1280×763 数应用/登录项/内存/能耗完整行 ≥10，放大增加可见行，末项可达；文字/按钮/40 pt 图均不相交，图标实际出现，确认流程不变。
6. 未提交/合并/安装，本批实机接受状态待主会话读回。

~~~sh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
SCRATCH=/Users/developer/Developer/.sc-build/r2-results-space
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$SCRATCH/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$SCRATCH/targeted-classes.txt")"
swift build --disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$SCRATCH/release" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4 --build-system native -c release --build-tests -Xswiftc -enable-testing
python3 "$SCRATCH/prepared/commit-prepared.py" --check-only
# 外部复核/门禁/反证后，主会话可按组提交：
# python3 "$SCRATCH/prepared/commit-prepared.py" --validated
~~~

## 修复轮 1 — 主会话完整测试与外部复核反馈

前文为首次交付快照。本节是主会话在 logs/main-final-2138/ 完成外部验证后追加的修复；不能把旧日志当作修复后的全量通过证明。已读取 build、targeted、full、mut/summary.json、rebuild、release-build 及 codex-review.log 末尾，输入哈希见 scratch main-review-inputs-repair1.json。旧 prepared 包保留在 scratch prepared-before-repair1/。

主会话旧包的定向 243/0、完整 4972 项中 4 个失败方法/64 条失败记录；分布为 DesignSystemV2Tests 16、FeatureTemplateContractTests 46、UtilityPresentationPerformanceTests 2。反证 7 和 16 实测存活，与外部复核指出的缺口一致。

### A：四个失败方法逐条判定

| 方法与失败项 | 判定/依据 | 本轮处理 |
|---|---|---|
| DesignSystemV2Tests.testMemoryPageKeepsOverviewListAndQuitBarVisibleAtEverySize：32≠52 | D77 合法替代旧视觉槽，不恢复 52 pt | 独立断言视觉 32；实际原生目标 ≥44，包含于 48 pt 底栏 |
| 同方法：Overview is visible 为 0 | 真回归，不属于 D77 授权 | summary 的 overview probe 移到实际头部 renderer；总览持续显示已用/总量，缓存/交换/选中估计量在宽头部或窄窗详情保留。原生夹具检查真实头部与完整 AX 数值 |
| 同方法：列表底边较旧上限多约 7.5 pt | 旧 24 pt 空隙阈值不再适用；不允许真实重叠 | 保留 16 pt 视觉空隙；直接检查实际视口等于 content、距 footer 8 pt、与 44 pt hit target 不相交，滚动末项后总览与操作区仍固定 |
| 同方法：点击目标 32<44 | 真回归 | 32 pt chrome 加上下各 6 pt 原生点击区；单独测视觉、hit probe、实际 AXFrame 与 AXPress；操作记录/刷新也保持 44 pt |
| FeatureTemplateContractTests.testMemoryDashboardKeepsOverviewListAndSelectionCommandsInsideTheContentColumn：16≠24、32≠52 | D77 合法替代 | 改为 16/32，新增 ≥44 实际点击区、footer/content/viewport 分离、总览可见；选择语义与“呈现不请求退出”断言保留 |
| FeatureTemplateContractTests.testMemorySampledListViewportEndsBeforeRefreshAndAdvertisesHiddenRows：越旧阈值约7.5 pt | 24 pt 旧阈值替代；裁剪/底栏分离仍是硬要求 | 直接比较实际 scrollViewport 与 content 起止/宽高，检查 footer、hit target 无相交，fade 与末端可达保持；源码只锁紧凑 preservesLazyLayout 分支，不再要求结果吸附整行 |
| UtilityPresentationPerformanceTests.testLargeEnergyAndUninstallListsUseLazyContainers：425/426 | “首项默认展开”已被 D77 取代；身份与惰性容器不得退化 | 首项仍默认折叠，恢复 .id(first.id)；ForEach(apps.dropFirst()) 与共用 LazyVStack 保留；新增卸载 renderer 的 LazyVStack/稳定 ID 源码守卫。原 400 行/<60 构建行/异步展开/末项可达测试保持 |

### B：外部复核三项修复

- 旧性能历史：Workspace 使用 PerformanceBenchmarkLegacyResultPage，Dashboard 的 compact mode 将 page picker 与旧 raw/details 放入 LightfieldResultContent。显式选择的记录直接使用原始值，不通过 current-comparable/best-result 过滤替换；本机最佳、历史、社区、导出/删除确认组件保留。旧兼容 chrome 仍供原有预览/合同测试使用，生产旧历史路径已不调用它。新增 synthetic-v9/v10 原生夹具验证实际 viewport、40 pt 图、无旧监控/独立动作条、旧 raw renderer 与编码不变。
- 反证 7：重复层连续观察 10、10.2、10.4、11.5、20 s，期间没有 wrong-page/busy 重置；超过动画与稳定期限仍必须拒绝。反证 16：直接比较真实 scrollViewport 与 content 的 min/max X/Y 和高度，不再仅以“能放十行”判断。
- 能耗首项身份：恢复 .id(first.id)。回归测试实际展开 A、点“再显示”打开所有子项、筛选使 B 成为首项，再切排序；B 默认折叠、首次展开只显示一个子项，不继承 A 的 showsAllChildren，排序后的新首项也折叠。
- 叠印根因：phase 测试通过真实 featureFlowTransition 父容器，关闭 fixture 的禁动画捷径；在每次 0.9 s 动画期间连续采集状态层，并检查旧文本退出。源码守卫同时要求 content identity transition、清空继承动画和真实 Lightfield 父容器不施加 phase animation；新增反证恢复退场 opacity/offset、父 phase 动画及继承动画，使这套合同必须失败。

聚焦原生测试另外暴露旧 raw 组件在窄窗会把 viewport 推到 688/456 pt（content 为435 pt）。紧凑滚动区现按实际 proxy 宽高固定；旧四段选择器在窄窗回退原生 menu，数据/分区组件不变。能耗“再显示”补显式辅助标签和实际按钮 probe，测试从真实 native hit 获取按钮后操作，不用构造闭包替代点击。

### 本轮反证与验证

counterexamples.json 现在 24 条：原 7/16 的目标测试已加强，新增 phase 退场/父动画、32 pt 点击区回退、能耗 header 固定身份、旧历史恢复监控首屏、大列表 eager、内存总览消失六项。全部锚点与目标方法已核对；本批仍不执行变异，主会话执行确认。

targeted-classes.txt 现在 31 类：原 26 类加 DesignSystemV2Tests、FeatureTemplateContractTests、UtilityPresentationPerformanceTests，以及受影响旧组件的 MacBenchmarkPresentationTests、BenchmarkMonitorLayoutTests。四个失败方法位于前三个类中，全部纳入。

- Debug 最终编译退出 0，7.57 s：`logs/repair1-debug-build-final.log`。本轮各次产品/测试修订的中间日志保留；最终编译对应固定后的全部 Swift 源文件。
- Release 最终 `-c release --build-tests -Xswiftc -enable-testing --build-system native` 编译退出 0，370.65 s：`logs/repair1-release-build-final.log`，scratch 为 `release/`。沿用首次沙箱交付的 native 引擎，保留优化、测试编译及符号；native 引擎弃用警告在日志，未运行 Release XCTest。
- 31 类定向执行 320 项：289 项通过、31 项未通过，32 条失败记录（29 unexpected），265.148 s，进程退出 1：`logs/repair1-targeted-final.log`。不能称为全绿。阻塞分布：DesignSystemV2Tests 2、FeatureLightfieldApplicationPageTests 2、FeatureLightfieldContractTests 6、FeatureLightfieldPerformanceTests 5、FeatureTemplateContractTests 14、TestPreferenceHygieneTests 2。逐个方法、原始错误、各类统计和日志 SHA-256 在新 `validation.json`。
- 其中 28 项的组合日志直接报告 TestFileSystem.swift:60 创建 `~/.storage-cleaner-scan-store-*/home` 被 Code=513 / Operation not permitted 拒绝；两项偏好持久化失败有 CFPreferences `sandbox_extension_issue_file` 拒绝证据。另一个旧模板方法 `testAllFourteenLandingActionsAndIllustratedPagesHaveIdenticalNativeFrames` 在组合运行报 SDK 原生生命周期 `idle → failed(deinit)`；单独复跑 `logs/repair1-template-lifecycle-isolation.log` 明确为同一 TestFileSystem.swift:60 家目录权限错误，尚未进入布局断言。保留组合运行的原始生命周期诊断，依据独立日志将该方法列入外部复跑，不将其计为通过。未移动夹具、删除断言、放宽路径保护或跳过测试。
- 通过项：FeatureLightfieldResultSpaceTests 13/13（实际 viewport/content 起止与宽高、原生 44 pt AXFrame/AXPress、真实内存 overview renderer、v9/v10 原始组件与编码、能耗应用身份、动画/稳定门）；UtilityPresentationPerformanceTests 15/15，包含能耗/卸载惰性源码合同；原能耗 400 行/<60 构建行/异步展开/末项可达原生预算也通过。UIConsistencyRegressionTests 46/46、MSeriesV11NativeLayoutTests 9/9、GeneratedArtTests 5/5、MacBenchmarkPresentationTests 10/10、BenchmarkMonitorLayoutTests 7/7。
- 能耗身份测试在结构变化后用同尺寸 native host layout 清除之前保留的 AX hit 对象，再从当前实际按钮获取 AXFrame/AXPress；同一 SwiftUI 根及应用状态仍保留。避免把旧首行/惰性行的旧原生节点当作新首行点击，不修改产品回调或构造假辅助功能节点。
- `repair1-compiled-source-sha256.json` 固定 30 个受影响 Swift 文件的编译/测试输入；最终包生成前再次逐个核对未变。24 条反证的锚点/出现次数/目标方法检查写入 `counterexample-anchor-check-repair1.json`；反证仍未执行，不能声称本轮已杀死 7/16 或新变异。
- 新 `prepared/` 重新生成三组补丁、`all.patch`、源文件/产物 SHA-256 manifest 和验证副本；第二组包含旧 Dashboard 的紧凑适配。交付脚本只执行 `--check-only`，不写 .git。旧包仍在 `prepared-before-repair1/`。前文的 26 类/243 项/18 条反证为旧快照，主会话本轮应使用新包的 31 类/320 项/24 条反证。

本轮没有启动 App、安装、执行真实扫描/退出/移动、写硬件、写 .git 或执行全量/反证。主会话需用新包重新跑全量门禁与 24 项反证，尤其确认 7/16 和新的 phase 根因反证不再存活；再用隔离 QA 复拍并读回实际点击区/总览/旧历史/能耗换位。JEV 的原审批阻塞未解除，本轮未声称模型复核通过。
