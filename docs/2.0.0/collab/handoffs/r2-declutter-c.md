# r2-declutter-c：第四轮复核修复（D4＋D5）

2026-10-08。本轮基线 `db5f33c9c02707481faf0c055abecf73cdef3891`，分支 `task/r2-declutter-c`；开始时工作树干净。交付 `/Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r4/`，六组补丁是相对 db5f33c 的完整增量。本工作树已写入最终源码，主会话直接验证即可；新 checkout 只能对 db5f33c 应用此包，不叠加 R1–R3 的完整补丁。旧交付、原日志与复核截图保留。

## 复核证据与本轮验证状态

已阅读全文 `review/review-1.md`，检查了 `review/shots/head-zh-dark/10-startup.png` 和 `04-privacy.png`。独立复核结论为修后可合并，原源码 build 通过、29 个定向类共 636 项（跳过 1，失败 0），复核员五种反证均漏检。报告内记录了复核员实际 JEV 的 merge_after_fixes 结论；本轮没有独立调用 JEV，不把该结论当成本轮修复后的验收。证据路径/哈希与初始快照在 `review-evidence.json`。

本沙箱按共同要求不编译、不执行 Swift/XCTest、不运行原生 App、不安装、不提交。R4 的 `static-checks.json`、`counterproof-static.json` 是源码、范围、字面量及内存反证区分检查；**它们不代表 XCTest 变红或构建成功**。`validate-prepared.py` 在内存把每组补丁应用到 db5f33c 并校验最终 SHA-256；所有执行验收仍由主会话在沙箱外完成。

## P1-1：守卫的区分力

`DeclutterD4D5ContractTests` 保留原 14 个方法，加一项八种健康动作原因的值测试。健康级别按枚举逐项断言：SMART/当前容量压力/电池检修是 critical，备份/近期 panic 或重启/30 天内预测/低分是 warning，留意项是 information。逐级检查文字与双语字面量，并确认红橙蓝映射实际挂到结果行。

纯文字呈现区域统一拒绝 `Image(...)`、`Label(..., systemImage:)`、`Label { ... } icon: { ... }`，不再只匹配一个构造字符串或某个语言片段。作用区分别锁定健康标题/列表、性能最新/最佳/历史/排行榜标题、网站行、审阅说明、地图标题/空态、清理指标；信息性状态、失败、风险、勾选、箭头、真实身份与动作仍有正向断言。对指定装饰符号的负向检查同时覆盖 systemName/systemImage，因此两种 Label 写法都不能绕过。无障碍 accessibilityLabel 不会被误判为可见 Label。

整库备份和移到废纸篓说明检查完整中英文；额外补齐 SMART 非寿命证明、本地保存、不可撤销、剪贴板显式点击、手动指导不自动打开/删除、部分扫描非无历史证明、扫描不上传/同步、卸载回执/空间释放、残留证据边界两半。原手动分支、脱敏、管理员请求、权限/更新来源功能契约保持。

复核五种反证逐条列入 `run-counterproof.py`：

| 复核项 | 破坏写法 | 必须实际失败的方法（DeclutterD4D5ContractTests） |
|---|---|---|
| 1 | 核心健康指标标题恢复 Label(systemImage:) | testHealthResultsRemoveDecorationButRetainEvidenceAndWarnings |
| 2 | 最新结果恢复 Label 的 icon 闭包 | testBenchmarkResultHeadingsAndEmptyStatesStayTextOnly |
| 3 | 仅删除英文 empty Trash to free space | testFileReviewKeepsIdentityChecksRecoveryAndExternalVolumeLimits |
| 4 | 网站行恢复 Label(option.domain, systemImage: globe) | testBrowserRecoveryFeedbackAndBulkOptionsKeepSafety |
| 5 | 中英同时删掉仅本地、不上传、不进时间机器 | testBrowserRecoveryFeedbackAndBulkOptionsKeepSafety |

静态内存检查确认这些写法都被现行源码断言辨别；实际 XCTest 红灯尚未运行。反证脚本拒绝编译失败、方法缺失、skip 或未观察到全部指定失败。完整计划保留原 12 个安全/身份破坏，并新增上述 5 个及风险颜色脱挂、评分说明脱挂、容量口径删除、成功勾恢复、空行恢复 5 个，共 22 个定向破坏。

## P1-2：风险等级属于信息

HealthActionList 将原因归入 HealthDashboardActionSeverity，并显示“需处理 / 需关注 / 留意”及 Action required / Needs attention / Review，沿用 destructive / warning / information。tint(action) 再次被实际调用。新测试覆盖全部八种原因与三级标题/颜色，`health-risk-color-disconnected` 反证移除结果行颜色必须使新方法失败。原排序、最多三项、推荐安全动作与管理员能力不变。

## P2：逐项处理及旧断言依据

| 项目 | 实现和依据 |
|---|---|
| 无用字段/参数 | 删除 ItemListStatusMetric.tint、evidencePanel/environmentHeader 的两个 symbol 参数及九处实参、FileAnalysisTrashPresentation.symbol(for:)、无效 Text.labelStyle。这些已不参与呈现或操作。 |
| L10n 孤立方法 | 用户本轮明确要求一起删除 countTierDetail，作为范围例外；其余 L10n 字节与 db5f33c 完全一致。无调用残留，不改 D6 其他内容。 |
| 登录项管理员提示 | 英文按中文顺序：辅助程序注册/系统批准 → 管理员授权 → 无应用内撤销/反向恢复；两种语言完整句测试。请求门控、单目标及可达操作不变。 |
| 折叠来源说明 | 按 D64 待定 #10 恢复：容量同时考虑可用比例与绝对余量；评分为磁盘/容量/稳定性/电池，备份/加密/当前电量/环境不计分，平均分不掩盖单项风险。短句仍在原 DisclosureGroup，不新增常显解释。total/available 缺失时“可用空间未读取”保留。 |
| 成功勾 | 按待定 #4，移到废纸篓结果成功只显示文字；未移动/回执落后警告、跳过原因符号、审阅可移动状态仍保留。 |
| 空行 | 清理记录 detail 为非空白字符串才生成 Text；概览耗时直接 Text(L10n.scanSeconds(...))，不再包相同中英文。 |
| DEBUG 守卫 | 删除整文件禁止 #if DEBUG 的断言，仅禁止无引用的 ComputerHealthDashboardDebugView；其余死 fixture 和真实环境/布局契约不减。 |
| 标识符次数 | 不再要求 benchmarkPrimaryAction 恰好三次，改为每个状态信息自适应分支均包含主动作，允许 V1 改变分支数量。其他持续动作区域、原生布局和嵌套面板边界保持。 |
| 文件/变量语义 | 读取 Leaderboard 的变量改 leaderboard；读取 MSeriesRawResultView 的变量改 rawResults，原正反断言不减。 |
| 图标孤立函数旧测试 | FileAnalysisTrashStoreTests 不再断言 folder.fill；改验 presentsAsFolder，仍验数据/应用类别、策略、选择和文件夹内容计数。新增该类至定向清单。 |

全部修改的方法、移除和替代的断言全文及依据由 `assertion-migrations.md` 和 manifest 记录；原方法未删、未跳过，未放宽阈值。当前守卫 15 个，定向清单 30 个类（原 29 加 FileAnalysisTrashStoreTests）。

## 跨批冻结及合并接入

StartupItemsDashboardView.swift **整文件**与 db5f33c 相同，特别是 680–751 行；没有预接 A 批尚未合并的 MetadataPill 状态 API。主会话合并时按复核表在 691–695 行接入管理员/配置/系统设置/只读/失败状态优先级，并核对外层无障碍没有覆盖 status 描述；本轮不改该位置。AppPageHeader、V7 起始/运行/持久动作、浏览器每行标题＋具体网址、a/b/V1 文件全部保持。可选缩短浏览器行内徽章不在本轮改动。

## 主会话在沙箱外运行

先验证产物；工作树已经是最终源码，不需要再次 apply。构建和定向测试应使用私有 scratch 并保存日志：

```sh
cd /Users/developer/Developer/sc-worktrees/r2-declutter-c
prepared=/Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r4
python3 "$prepared/validate-prepared.py"
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer swift build --scratch-path /Users/developer/Developer/.sc-build/r2-declutter-c/r4-build --jobs 4
filter=$(python3 -c 'from pathlib import Path; print("|".join(Path("/Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r4/targeted-classes.txt").read_text().splitlines()))')
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer swift test --scratch-path /Users/developer/Developer/.sc-build/r2-declutter-c/r4-build --jobs 4 --filter "$filter"
python3 "$prepared/run-counterproof.py" --run
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-declutter-c/r4-verify script/verify.sh
python3 "$prepared/commit-prepared.py"
```

反证前后各 26 个具名方法必须全绿。R4 的基线现为已包含 D64 的 db5f33c，不继续拿原 a6db3c5 解释新问题：`baseline-r4-red` 回退本轮 9 个源文件的呈现实现，HealthActionList 保留新枚举定义以使新值测试能编译，只回退 View；要求六个列明的 R4 回归方法全部失败。原 R3 a6db3c5 基线至少 12/14 失败阈值和已全红的日志是历史证据，不冒充本轮执行或降低旧阈值。每次破坏恢复所有 touched source 字节，含本轮补丁外但原 C 批范围内的反证文件；不改测试/文档，最终校验全部 SHA。进程中断保留 originals 和原状态哈希供主会话恢复。

定向测试、22 个破坏、恢复全绿和 verify 完成后，主会话再以 `commit-prepared.py --commit` 创建六组本地提交，不 push。原生健康风险/折叠来源和废纸篓结果视觉验收尚缺；复核截图里的健康/性能只是起始页，不能充当结果验收。需要真实结果时仍须主会话验收，不能为截图自动探测或执行清理。

---

## 以下为 R1–R3 历史交接，路径/基线/状态仅对应当时交付

# r2-declutter-c：D4＋D5 结果与独立 sheet（第三轮）

基线 `a6db3c5ca0aad56bd0f4dd524cbbbc47ef541ef2`，分支 `task/r2-declutter-c`。交付目录 `/Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r3/`。依据 2026-10-08 的 `r2-declutter-common.md` 用户 D64 要求、审计清单第 0/2/3.3/4/5 节及当前生产引用实施。DECISIONS 基线尚未登记 D64；请主会话按共同要求登记，不在本批改共享决定或看板。

## 第三轮：系统设置管理项的一行边界

主会话第二轮 build 实际通过；定向测试执行 636 项、跳过 1 项、仅 1 项失败，原日志 `logs/main-prepared-r2-124213/test.log` 指向 `StartupItemsPresentationTests.testPrimaryConsoleKeepsUnattributedSystemSettingsRowsVisible:581`。原反证结果 `prepared-r2/counterproof-runs/20261008T014524Z-41bd353a/results.json` 已核对：基线 14 个守卫实际失败，原 11 个定向破坏均观察到指定失败，final-green/restored-green 各 24 个方法通过且无缺失/skip，源码恢复 SHA-256 验证通过。

R2 文案只剩“由系统设置管理”/“Managed in System Settings”，遗漏了原说明的“本应用只打开对应设置页，不直接改动”。依据 D64 压缩安全说明且用户第三轮明确保留该边界，本轮恢复为同一行：

- 中文：`由系统设置管理 · 本应用只打开设置页`
- 英文：`Managed in System Settings · This app opens Settings only`

`StartupItemsPresentation.swift` 仅改 `.manageableThroughSystemSettings` 的两个字符串。对应测试将原长句等值断言同步迁移到完整短句，原 primary/technical/attention 三种列表行可见及 `attention.allowsStartupMutationActions == false` 的覆盖全部保留；能力、归属、路由及动作实现未改。现有 D64 登录项源码守卫也检查管理说明分段中的中英完整短句，避免只验证当前语言。

逐条旧断言与依据见 `prepared-r3/r3-failure-analysis.md/json`，基线至最终的全部断言迁移见 `assertion-migrations.md`。新增 `system-settings-only-boundary-removed` 反证同时删除两种语言的仅打开设置后半句，要求值测试及双语源码守卫两个具名方法都实际失败。前后绿灯增加到 25 个方法；原基线至少 12/14 失败阈值、原 11 个破坏和最终 SHA-256 恢复要求保持。

`prepared/`、`prepared-r2/` 及其主会话日志保留不改。第三轮交付为相对原基线 a6db3c5 的完整最终补丁，不在第二轮补丁上叠加应用。第三轮构建/XCTest/反证尚未执行，下面给主会话的命令已切换到独立 r3 scratch。

## 第二轮：16 处失败逐项处理

主会话第一轮 `build.log` 实际含 `Build complete! (199.10 sec)`；定向测试实际执行 563 个测试，1 个原有的 live Setapp 测试按显式开关跳过，16 处断言失败，集中于 9 个方法。反证只跑了新守卫的 final-green：13/14 通过，健康 Label 匹配误判导致停止；未执行基线/标题/网址破坏，finally 已核验原源码 SHA-256。原 `prepared/` 与主会话日志保留不改。

第二轮逐断言分析在 `prepared-r3/r2-failure-analysis.md` 与 JSON；含 R1 断言全文、原行号、D64/安全依据、替代语义、保留覆盖和具名反证阶段。下表逐条对应 16 处（行号均为 R1 日志，不是新文件行号）：

| # | R1 类/方法与行号 | 分类 | 最终处理 |
|---|---|---|---|
| 1 | `ComputerHealthDashboardTests.testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe:28` | D64 旧契约迁移 | 本条要求旧 fixture 存在的 True 原样改为 False，禁止复活；额外检查真实紧凑/双列布局与 scoreEvidenceTitle。 |
| 2 | `ComputerHealthDashboardTests.testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe:29` | D64 旧契约迁移 | 本条要求旧 fixture 存在的 True 原样改为 False，禁止复活；额外检查真实紧凑/双列布局与 scoreEvidenceTitle。 |
| 3 | `ComputerHealthDashboardTests.testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe:30` | D64 旧契约迁移 | 本条要求旧 fixture 存在的 True 原样改为 False，禁止复活；额外检查真实紧凑/双列布局与 scoreEvidenceTitle。 |
| 4 | `ComputerHealthDashboardTests.testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe:31` | D64 旧契约迁移 | 本条要求旧 fixture 存在的 True 原样改为 False，禁止复活；额外检查真实紧凑/双列布局与 scoreEvidenceTitle。 |
| 5 | `ComputerHealthDashboardTests.testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe:32` | D64 旧契约迁移 | 本条要求旧 fixture 存在的 True 原样改为 False，禁止复活；额外检查真实紧凑/双列布局与 scoreEvidenceTitle。 |
| 6 | `ComputerHealthDashboardTests.testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe:33` | D64 旧契约迁移 | 本条要求旧 fixture 存在的 True 原样改为 False，禁止复活；额外检查真实紧凑/双列布局与 scoreEvidenceTitle。 |
| 7 | `ComputerHealthDashboardTests.testDashboardIsComposedFromApprovedSectionsWithoutAutomaticProbe:34` | D64 旧契约迁移 | 本条要求旧 fixture 存在的 True 原样改为 False，禁止复活；额外检查真实紧凑/双列布局与 scoreEvidenceTitle。 |
| 8 | `ComputerHealthDashboardTests.testEmptyHealthDashboardDefersResultSectionsUntilEvaluationExists:113` | D64 旧契约迁移 | 禁止旧中英副标题复活，要求活跃 environmentSection 及四张真实环境卡。 |
| 9 | `DeclutterD4D5ContractTests.testHealthResultsRemoveDecorationButRetainEvidenceAndWarnings:30` | 守卫误判 | 使用带标识符边界的正则禁止可见 Label 调用，正向要求 Text 与 accessibilityLabel；无需改产品实现。 |
| 10 | `OfficialBenchmarkPlanTests.testPerformanceWorkspaceExposesOnlyTheOfficialFlow:193` | D64 旧契约迁移 | 禁止中英旧句复活，新增实际 history 输入/排序/渲染、可比性、状态 badge 和历史错误检查。 |
| 11 | `PrivacyCleanupPresentationTests.testBrowserPrivacyCopyMatchesManualOnlyProductionBoundary:679` | D64 旧契约迁移 | 改为要求双语压缩句；复制按钮须调用 copyDomains，空域名不可复制；新增已验证删除候选/手动指导的分支检查。 |
| 12 | `PrivacyCleanupPresentationTests.testResultRowsPrintOnlySanitizedPresentationText:775` | D64 旧契约迁移 | 改为要求双语压缩句；复制按钮须调用 copyDomains，空域名不可复制；新增已验证删除候选/手动指导的分支检查。 |
| 13 | `StartupItemsDashboardContractTests.testInspectorMakesSingleVerifiedAdministratorRequestReachable:252` | 真实安全提示回归 | 在同一行双语补回辅助程序可能需注册与批准；保持管理员授权、无应用内撤销、反向操作恢复；新增详情/help 挂载检查。 |
| 14 | `StartupItemsDashboardContractTests.testInspectorMakesSingleVerifiedAdministratorRequestReachable:253` | D64 旧契约迁移 | 锁定中英无撤销/反向恢复/管理员授权完整短句，并确认挂载到管理员详情和按钮 help。 |
| 15 | `SystemUtilitySafetyTests.testStandaloneCleanupHistoryPageIsRemovedAfterRecordIntegration:3911` | D64 旧契约迁移 | 旧恢复图标改为禁止复活，要求 Undo Latest Cleanup 文字和 canRestoreLatestCleanup 门控。 |
| 16 | `UIConsistencyRegressionTests.testBenchmarkWrapsMetadataAndAvoidsNestedContentCards:1726` | 守卫误判 | 全文件 glassPanel 精确为 1 且 body 精确为 1，因而任何 header/行内面板都会失败；raw 结果继续完全禁止 glassPanel/RoundedRectangle。 |

共 13 处按 D64 迁移、2 处修守卫、1 处修实现。七处旧 DEBUG fixture 断言逐条改为禁止复活，并保护真实证据/布局；没有恢复死代码。健康标题的正则区分可见 Label 与 accessibilityLabel，后者继续必须存在。排行榜恰好一个原有外层面板，内层仍禁止。

浏览器两条旧剪贴板句改为要求双语“内存会话保留、仅点击复制写入”，第一条限定实际 manualWorkflow 展示区，并要求对应按钮回调及空域名禁用。已通过的手动模式方法增加 verified/else 分支检查，manual else 只能 prepareManualGuidance，不得 processSelectedRecords；双语不打开网页、不自动删除说明保留。原始字段禁用、脱敏 presentation 标题＋地址、精确两处 Clipboard.write/一处 setString 等断言全部保留。

管理员提示补回“系统控制辅助程序可能需注册与批准”，与管理员授权、无应用内撤销、反向操作恢复压在同一行，两种语言一致。测试继续执行候选/能力值判断，新增单项与多项 UI 候选门控及提示挂载检查。权限测试锁定扫描权限证据，更新来源开关与权限区别的原方法未改，继续由 SystemUtilitySafetyTests 整类执行。

## 实际改动与边界

本批涉及 29 个源文件（24 个修改、5 个删除）、11 个测试文件（10 个修改、1 个新增）和本交接。a/b/V1 的源文件未改。AppPageHeader 及共享页头定义不改，Overview 的 DashboardPage 标题、副标题、systemImage 参数保留；V7 `benchmarkPrimaryAction`、`actionCard`、`benchmarkCategoryOverview`、statusBar、页面选择/路由均保留原实现。所有业务存储、扫描、处理、身份校验、回执、恢复和硬件服务未修改。

| 分组 | 具体处理 | 保留的结果与安全边界 |
|---|---|---|
| 01-health-startup | ComputerHealthView 及四个 Health 视图去除静态标题、因子和动作装饰，删除重复计分/环境说明；登录项摘要指标去除图标，管理说明双语缩短 | 分数、置信度、检查时间、原始 SMART/电池/事件数据、风险与错误、趋势、网络同意和硬件只读边界；真实应用图标、状态、管理方式、管理员请求可达、辅助程序可能需注册与批准、授权与无应用内撤销/反向恢复提示 |
| 02-browser-results | 四个浏览器结果文件去除重复的标题、搜索提示、成功反馈及有文字操作图标；精简手动流程、刷新/处理说明和恢复备份文字 | 每行具体页面标题＋网址、无标题时的地址兜底、完整地址展开、D20 查询参数折叠、来源/访问量/时间、搜索命中说明、勾选与展开控件、失败/警告、剪贴板只在点击时写入、核验前保留记录、备份保留规则 |
| 03-benchmark-results | V7 最新、最佳、历史、比较和排行榜标题改纯文字；内联空态只留结果文字；成功反馈去勾、失败保留；删除旧视图 | 原始测量、样本稳定性、待校准口径、评分/协议版本、当前可比性、历史失败状态、导出/删除/比较控件、匿名发布和移除确认及公开字段说明 |
| 04-file-app-sheets | 九个独立文件/应用界面去除静态摘要、标题、成功图标；说明双语压缩；清除 Overview 死分区及配套私有类型 | 路径、容量和数量、图例、选中/锁定/未知状态、风险、完整性警告、真实应用图标、只图标操作、所有操作回调及无障碍标签；移动前复核、变化跳过、恢复/外部卷/清空后释放空间边界 |
| 05-contract-tests | 十个现有类的相关源码契约迁至生产路线并处理第二轮失败；新增 DeclutterD4D5ContractTests 的 14 项源码守卫 | 原方法全部保留，无 skip，无数值性能/安全阈值调整；值测试、模型/服务测试保持；新增测试仅读源文件，不创建偏好或调用清理 |
| 06-handoff | 本交接 | 静态检查、编译、测试、反证、原生验收、提交分别报告 |

## 审计纠偏与死代码证据

- 容量图 `mapHeaderDetail` 含实际目录/文件数量，保留；不能因为是副行就按废话删除。可点击 tile/list 的类型图标和容量颜色图例保留。
- Health 风险等级/失败、浏览器核验错误与权限警告、文件/应用锁定和风险符号保留，部分状态改为带颜色的文字。确认、勾选框和展开箭头不是装饰。
- 浏览器身份视图只将 `Label(searchHint, ...)` 改为 `Text(searchHint)`；title/address 渲染、截断、tooltip、辅助功能和地址清洗模型与基线一致。先检查范围，再删装饰，不回退 D20 验收。
- 浏览器备份仍说明整库含被删页面、仅本地、不上传、不进 Time Machine、保留天数和份数、恢复/待核实不计、可提前删。文件审阅保留身份变化跳过，外部卷恢复差异另列。登录项一行双语提示补回系统控制辅助程序可能需注册与批准，并保留管理员授权、无应用内撤销和反向操作恢复；这是第二轮修复的真实文案回归，不能仅剩管理员授权。
- 删除五个无生产引用的旧 UI 文件：`MacBenchmarkDashboardView.swift`、`MacBenchmarkResultSections.swift`、`MacBenchmarkLeaderboardSection.swift`、`MacAcceleratorBenchmarkSection.swift`、`MacSustainedBenchmarkSection.swift`。旧 Dashboard 中的调试视图随文件删除。`MacBenchmarkPresentation.swift` 不在这五个具体 UI 清单内，仍有评分/展示值测试，因此保留；不把测试引用声称为生产入口。模型、服务、历史仓库、旧值测试不删。
- 删除 ComputerHealthView 尾部无调用的 DEBUG dashboard fixture，以及 Overview 无引用的 `header`、`scanFreshnessSection`、`systemStatusSection`、`moduleSection`、`diskSection`、`topItemsSection`、旧 MetricCard/CompactModuleCard/TopItemRow 与孤立 CardArtworkIcon/DiskSegmentBar/LegendDot、仅供这些分区的私有 helper/缓存字段。活跃 body、风险导航、扫描重试、权限复核和任务交互保留。
- 删除静态图标之后，一并清理本地未使用的 systemImage 参数/属性及 Health factorSymbol；共享组件参数签名不改。

## 旧断言迁移依据

`prepared-r3/assertion-migrations.md` 逐方法列出每条不再原样存在的旧断言、替代断言与 D64 依据，`manifest.json.assertion_migrations` 记录前后断言数和理由；完整测试差异在 `05-contract-tests.patch`。不是单纯删除失败断言。

| 原方法/契约 | 旧依据 | 当前依据 |
|---|---|---|
| UIConsistency 的 shared empty、benchmark flat scroll、health shapes、sustained、one-standard、metadata wrapping、small overrides | 未引用 v6 Dashboard/ResultSections/Accelerator/Sustained UI 的源码布局和图标 | 现行 V7/MSeries/Leaderboard 原生输出；所有无关共享一致性断言保留 |
| health shapes 的两处 fixedSize、metadata wrapping 的至少两处 ViewThatFits | 旧私有实现计数 | 当前开始/取消两个原生 Button 精确计数＋两动作；当前 statusBar 三个完整 action fallback 精确计数；V7 排行榜恰好一个整体外层面板，body 同样恰为一个，任何 header/行内 glassPanel 都失败；不是放宽阈值 |
| native buttons 的旧性能输入 | 未引用 v6 UI 的全文件控件契约 | V7 结果区继续严格禁止局部 bordered/borderedProminent；V1 起始/运行的原生按钮由精确数量与 onStart/onCancel 断言另行保护 |
| UIConsistency 的 Overview `isDecorative: true` | 已删除死 header 的装饰约定 | 禁止该文件恢复 AppSymbolIcon；活跃 DashboardPage 参数另由静态比较保护 |
| MacBenchmarkPresentation 源码契约 | 五个旧 UI 类型、v6 冻结基准、示例尺寸、重复工作量说明、旧对比条 | 旧 UI 必须不存在＋现行手动操作、历史、可比性、动态硬件、原始值/校准口径、错误/确认和布局；该类其他值测试原样保留 |
| MacBenchmarkLeaderboard UI 字段 | v6 内存字节、公开磁盘容量、旧分数标题 | V7 memoryGB/completedOn/scoreText；模型/解码值断言不动，V7 公共字段回归一起运行 |
| AppResponsiveness 只在选择后构建 | v6 private let store、禁止 DisclosureGroup | V7 app-scoped observed store＋switch selectedPage；LazyVStack/禁止私有重建保持 |
| StartupItemsPresentation 的系统设置管理等值断言（第三轮） | 原长句明确系统管理、本应用只打开对应设置页 | 一行中英仍明确系统管理/仅打开设置，保留三个列表可见及禁止直接操作原断言；专门反证不能删掉后半句 |
| SystemUtilitySafety 的 scanReadinessCheckedAt | 死 scanFreshnessSection 展示时间 | 活跃权限摘要有已验证来源＋重新检查动作；进一步锁定仅 scanReadinessSummary/result.deniedPaths，不混入更新来源偏好；授权、状态和系统设置路径断言保持 |

## 静态验证与实际执行状态

沙箱中仅执行只读 Git/源码审计、`git diff --check`、Python 交付脚本语法解析，以及 `prepared-r3/static-check.py` 和 `validate-prepared.py`。静态报告在 `static-checks.json`：基线/分支/索引、白名单、Swift 括号/字符串/注释闭合、禁改文件字节、冻结 V7 起始/运行与浏览器身份区、测试方法保留、死类型引用清除、脚本语法。交付核对另外在内存中将六组 unified hunks 应用于基线内容，重建 41 个最终文件状态（含五个删除）并逐一匹配 SHA-256；不调用 git apply、不写索引。

Swift 静态检查只是词法和引用复核，不替代编译、宏展开、Swift 6 隔离或 SwiftUI 渲染。第三轮核对双语仅打开设置页提示、12 个反证目标唯一性/词法及具名 XCTest 解析；解析器只读取第二轮真实日志。**第三轮构建、XCTest、红/绿/反证、严格并发、原生窗口、安装和提交均 NOT RUN，沙箱执行测试数 0**。第一轮证据在 r1-validation.json；第二轮 build PASS、636 tests/1 skip/1 failure、反证全部成功与恢复全绿在 r2-validation.json，和第三轮未运行状态分别记录。

第一轮 JEV gate 已按实际可调用 schema 核对参数（auto_accept=0.8、review_at=0.5、composite_floor=0.7），该接口未暴露模型选择/标识，未更改模型。调用被环境审批策略拦截，原文 `MCP tool call requires approval, but approval policy is never`。当前审批策略仍为 never，未重复发起或绕过同一受限调用，仍没有获得 JEV 判断；第一轮原始返回复制保存为 `prepared-r3/jev-review.json`。主会话须补独立复核，不能将此返回当作审查通过或模型调用成功。

## 主会话验证命令

在此 worktree、提交前执行；使用 Xcode 27 Beta、独立 scratch。`targeted-classes.txt` 有 29 个类，包含 TestPreferenceHygieneTests、UIConsistencyRegressionTests、审计 3.3 与本批相关的类，并补入 V7、容量图与独立 sheet 回归；第二轮保留原 26 类并加入 BrowserPrivacyCleanupRouterTests、StartupItemsPresentationTests、StartupItemManagementTests，覆盖浏览器内路由及登录项归属/管理能力。不要删除/跳过失败测试来换取绿灯。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-declutter-c
python3 /Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r3/validate-prepared.py
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
batch_filter=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r3/targeted-classes.txt)
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-declutter-c/main-r3-tests --jobs 4 --filter "$batch_filter"
python3 /Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r3/run-counterproof.py --run
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-declutter-c/main-r3-verify STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 SWIFT_BUILD_JOBS=4 ./script/verify.sh
python3 /Users/developer/Developer/.sc-build/r2-declutter-c/prepared-r3/commit-prepared.py
```

`verify.sh` 负责 debug/release 全套、严格并发、私有 API、菜单栏性能及仓库静态约束；本批未执行。会触发移动/恢复的现有测试须继续使用家目录 UUID 夹具，偏好用 TestPreferenceDomain；不修改产品路径检查。原生验收由主会话在当前 D60 窗口/主题矩阵下检查健康、浏览器（长标题＋网址、展开、失败、恢复）、V7（空态、历史、取消/失败、排行榜）、登录项与独立 sheet；本批不提供未实拍截图或已验证布局结论。安装需用户原有授权，提交不代表安装或发布。

## 红／绿／反证

`run-counterproof.py` 默认只显示计划，`--run` 才编译测试并临时改本批源文件。核对 manifest、分支/基线、范围和暂存区，备份 29 个源文件的最终内容。先要求 14 项新守卫＋11 个相关旧方法共 25 个具名方法全绿；保留最终测试并还原 29 个源文件到基线（包括五个旧 UI 文件），要求 14 个新方法全部实际执行且至少 12 个出现 XCTest 失败，阈值与第一轮一致。

随后每次只在本批源文件制造一个明确缺陷并要求全部指定方法失败：

| 阶段 | 临时缺陷 | 要辨别的边界 |
|---|---|---|
| missing-title / missing-address | 分别清空 Text(title)/Text(collapsed address) | 每行具体页面标题＋网址 |
| visible-health-decoration | Text(assessmentTitle) 改成带 heart 的 Label，accessibilityLabel 保留 | 可见装饰不得复活，辅助功能标签不能被误判 |
| clipboard-notice-removed | 中英句只留内存，不再说明点击后写入 | 精简后仍需同等剪贴板安全提示 |
| manual-branch-processes-database | 手动 else 的 prepareManualGuidance 改成 processSelectedRecords | 手动分支不得进入数据库处理 |
| raw-history-text-reaches-row | presentation.title 改成原始 item.address | 脱敏 presentation 不能绕过 |
| system-settings-only-boundary-removed | 中英管理说明删回“由系统设置管理”/“Managed in System Settings” | 值测试与双语守卫必须同时辨别仅打开设置页边界丢失 |
| administrator-helper-prerequisite-removed | 双语删除辅助程序注册/系统批准前提 | 一行提示仍含完整管理员前提 |
| administrator-request-unreachable | 单候选 UI gate 的 includesAdministratorRequests 改 false | 已验证管理员请求真实可达 |
| undo-callback-disconnected | requestRestoreLatestCleanup 改成打开废纸篓 | 保留文字还必须保留实际请求动作 |
| nested-leaderboard-panel | 列表行增加 glassPanel | 原有唯一外层可留，内层严格禁止 |
| permission-evidence-disconnected | fallback 放弃真实 deniedPaths 改空数组 | 权限卡仍取实际扫描权限证据 |

每轮 finally 恢复到 manifest 的最终 SHA-256；最后再次要求 25 个具名方法全绿。具名方法缺失、被 skip、编译失败或仅有非预期错误均不接受为反证。反证脚本不改测试/交接，不 stage/commit，不调用产品清理或硬件；第三轮基线反证和上述 12 个破坏阶段均尚未执行；第二轮的基线红及原 11 个破坏已实际通过。

日志和恢复副本在 `prepared-r3/counterproof-runs/<UTC-UUID>/`。若强制 kill 导致 finally 不执行，先按 original-state/originals 恢复本批路径，再核对 manifest。第三轮两次绿、基线红和 12 个具名反证都需由主会话实际观察；Python 静态目标核对不等于反证通过。

## 合并依赖与未解决事项

- 留给 D6：跨批集成后重跑一致性、偏好、截图/窗口验收；b 负责 AppButton/MetadataPill/AppEmptyState/AppStateIconRing 等共享渲染。本批保留共享调用与必要状态，不能从本 worktree 当前样式声称全局去图标已完成。
- V1 继续处理 AppPageHeader、页头文案/图标与 V7 起始/运行；本批不动这些源文件。现有共享测试由 V1/b/a 也可能改，集成时按方法语义合并，不能整文件覆盖其中一方。
- 第三轮 Swift 编译与定向测试、新反证及原生双语/长路径/主题验收尚未执行；第二轮已有真实构建/反证证据，其唯一测试失败在本轮修订，当前仍不能宣称第三轮运行验收通过。
- 主会话验证、复核后运行 `commit-prepared.py --commit`，按六组提交。脚本默认只核对，拒绝基线漂移、文件/产物哈希变化、删除文件复活、已有暂存或范围外改动；失败后保留状态供检查，不自动 reset。

本包是相对原基线 a6db3c5 的完整最终源码与测试补丁，包含 R1、R2 和 R3 的最终改动。当前 worktree 已是最终内容，不能再次 apply all.patch；仅在同基线的干净工作区可重建。R1 最终路径快照与未修改测试的基线副本保留在 `/Users/developer/Developer/.sc-build/r2-declutter-c/r1-final-snapshot-20261008T010647Z`，用于逐项来源核对。
