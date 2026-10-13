# 第二轮 r2-junk-actionable 交接：垃圾扫描列出即可选、可删（第一步 A1）

- 实现：Claude 子代理（Opus 5.5）　复核：主会话两轮独立复核；第三轮（A1 第二轮＋A2：需修改后合并，无 P0、1 个 P1）的修改见最前的“第三轮”，第一轮复核的修改见“第一步复核修复”
- 分支：`task/r2-junk-actionable`，基于集成分支 `561e2df`
- 依据：DECISIONS D19、D22、D23、D24、D25（另参照 D1、D12、D21）
- 第一步（A1 与复核修复）未修改 `Stores/ScanStore.swift`；第二步 A2 在合并集成分支后修改，见“第二步 A2”。
- 提交：见文末“提交”。

## 第三轮（主会话 A1 第二轮＋A2 独立复核：需修改后合并，无 P0、1 个 P1；2026-10-05）

- 开始前 `git merge integration/2.0.0-beta`（`724b06c`，含 r2-mini-speed 第一阶段与 r2-privacy），无冲突，合并提交 `0073e39`；没有 rebase／reset。合并后 Debug 构建通过（184 s，负载约 33）。
- 规则同前：每项先写测试（红）再修（绿），不删断言、不放宽阈值；没有启动或退出任何真实应用（退出服务、运行检查都是假的）；没碰真实缓存、日志、废纸篓、邮件目录。复核材料与探针在主会话 scratchpad `review-junk2/`。
- 关于 `~/Developer/.sc-build/r2-junk/` 下两个 scratch 的 `out` 目录被删：**不是我做的**。我的命令对 `.sc-build` 只有 `swift build`、`mkdir`、复制日志，没有任何删除；第二轮开始时（约 02:4x）和本轮开始时（11:2x，strict 的 `out` 不在、目录修改时间 10:53；Debug 的 `out` 是复核者 11:05 后重建的）我都只是观察到它们已经不在。这两个目录里都有 SwiftPM 写的 `CACHEDIR.TAG`（标明“这是缓存目录”），会按这个标记清理缓存的工具可能删除它们，未核实。

| 项 | 状态 | 改动 | 测试（红 → 绿） | 提交 |
|---|---|---|---|---|
| P1-1 预检全部未通过时真实界面不弹面板、结果页被锁 | 已修 | `ScanStore.isV2CleanupConfirmationPresented` 成为唯一判断（等待确认、展示状态为确认中、计划与预检都在），`ContentView` 通过新的 `CleanupPlanConfirmationPresentation.binding(for:)` 绑定到它，不再另加“可确认”条件；面板在全部未通过时也出现、逐项列原因、确认不可用，关闭面板即 `cancelV2CleanupConfirmation()` 回到可编辑的结果页 | `CleanupStoreFollowUpTests.testSheetBindingOpensWhenNothingPassesAndClosingUnlocksTheResults` 驱动**视图实际使用的绑定**：全部跳过时为真；设为假后计划清空、可勾选、可发起清理、回到结果页。红：绑定为假（复核探针 A 的情形）。另在 `testViewsWireTheFollowUpFlow` 断言 `ContentView` 的面板就用这个绑定、不再含 `isConfirmable` 条件 | `15134b0` |
| P2-1 不能请求退出的所属应用 | 已修 | `CleanupOwnerQuitService.options(among:)` 把运行中的实例分成可请求退出与需手动退出（菜单栏／后台应用、Finder、本应用；同一标识只要有一个实例不能请求，就整体归入手动）；行在只有手动项时显示“需手动退出：…”、不显示按钮；确认面板同样；`ScanStore` 找不到可退出应用但有手动项时提示“需手动退出：…”，不再说“相关应用已经退出”（只有确实都不在运行时才这样说）。重复副本不提供退出（运行副本按 P2-7 受保护） | `testOwnersThatCannotBeAskedToQuitAreNamedForAManualQuit`（行与面板两条路径）。红：两种应用都被说成“已经退出”（复核探针 B） | `194ac3a` |
| P2-2 同一标识多个实例 | 已修 | 确认框列出将被请求退出的每个实例，同名实例写明个数（`CleanupOwnerQuitPresentation.names`）；实际请求的就是这些标识的全部运行实例（复用的实现按标识对每个运行实例发 `terminate()`），与列出的集合一致 | `testTheConfirmationNamesEveryInstanceThatWillBeAskedToQuit`。红：确认框只列“Dup”、实际请求了两个实例（复核探针 C） | `194ac3a` |
| P2-3 等待退出后核对扫描会话 | 已修 | 退出请求记下发起时的扫描会话（从确认面板发起时还记下计划）；等待结束后两者有变就只刷新行状态，不自动发起预检或重新检查 | `testANewScanWhileAppsQuitStopsTheAutomaticFollowUp`（等待期间重新扫描）。红：等待后对新扫描自动建了计划并预检 | `9d1bf98` |
| P2-6 复用已有的等待实现 | 已修 | 选用 `BrowserPrivacyHistoryProcessor.swift` 的 `BrowserPrivacyRunningApplicationChecking.requestNormalTermination`：它本身就是“正常退出＋等待”，对每个运行实例 `terminate()`，按 `Date` 截止时间每 100 ms 检查，超时上限 5 秒；`ApplicationUpdateGracefulQuitRequester` 只发请求、不等待，且按已安装应用（路径）匹配，不合用。本服务只负责决定哪些应用可请求退出、列给用户，再把标识和 5 秒交给它；原来按轮询次数累加的循环删除。界面与提示改为“最长等待 5 秒”。未改 `Features/BrowserPrivacy/**` | `testTheQuitWaitUsesTheReusedDeadlineBasedImplementation`。红（旧接口）：暂停变慢时 1 秒超时实际用了 3.0 秒。绿：服务把 5 秒交给复用实现；源码断言复用实现用 `Date` 截止时间且上限 5 秒；真实实现对不在运行的标识立即返回。旧的红测随接口一起替换（被测的自写循环已不存在），见下表 | `194ac3a` |
| P2-7 重复副本的保留 | 已修 | `DuplicateApplicationRetentionPolicy.isProtected`：正在运行的副本和 `xcode_select_link` 指向的副本都受保护，总会保留、不能勾选（单选、整组、计划都去掉它们），两者不同时两份都保留；一组全是受保护副本时没有可移除项，扫描在解析运行状态后整组去掉并计入未列出。没有受保护副本的组仍按“整组勾选保留一份”。界面改为“命令行工具当前使用的 Xcode”（英文“the Xcode the command line tools use”），中文界面与说明文案不再出现 `xcode-select` | `CleanupDuplicateApplicationTests` 新增 3 项：两份受保护副本＋一份普通副本时只能选普通那份；两份都受保护时整组不列出、计 2 个未列出；源码中无“xcode-select 当前使用”。红：均失败 | `f524517` |
| P2-4 补测试 | 已做 | D40“读不全、无法确认 7 天内有无写入”：日志行有读不到的子目录时为 `.unverified`、可选、不预选、不进“选择推荐项目”，行内文案存在；`ContentView` 真实绑定的行为测试见 P1-1 | `CleanupLogPreselectionTests.testALogRowThatCannotBeReadCompletelyIsNotPreselected`（行为原已存在，首跑即通过，属补覆盖） | `19b1d45` |
| P2-5 交接更正 | 已改 | 下方“真实 `~/Library` 下的测试夹具”取代此前“约 11 处”的说法；本批不修 | — | 本文件所在提交 |

改动的测试：`testTheQuitWaitEndsAtItsDeadlineWhenPausesRunLong`（本轮红测，驱动旧服务自写循环的 `pause` 参数）随 P2-6 改为 `testTheQuitWaitUsesTheReusedDeadlineBasedImplementation`，因为被测的循环已删除；`testQuitServiceAsksNormallyAndReportsAppsThatStayOpen`、`testWorkspaceQuitServiceQuitsNothingForIdentifiersThatAreNotRunning` 改用新接口（`options(among:)`、`quitNormally(_:)`），原断言（只请求可请求的应用、Finder／本应用不请求、顽固应用报告仍在运行、真实工作区不请求任何应用）全部保留并加了后台应用不被请求。其余断言未删、阈值未放宽。

### 真实 `~/Library` 下的测试夹具（P2-5 更正）

复核实测：15 个测试文件、33 处（含 1 处 `~/Library/Preferences/<随机>.plist`）在真实用户目录 `~/Library` 下建删夹具，此前写的“约 11 处”不对。我用同一口径（字符串 `Library/…` 前 3 行内出现 `homeDirectoryForCurrentUser`／`NSHomeDirectory()`）复查为 15 个文件、34 处，多出的 1 处是 `UninstallOwnershipTests.swift:142`（像素夹具的 `Library/Containers/<标识>` 路径校验，未确认是否写入）。文件与行号（合并 `724b06c` 后）：

- `CleanupSafetyTests.swift`：144、519
- `HeavyWorkIntegrationTests.swift`：201
- `InterruptedOperationReconcileTests.swift`：16
- `LegacyCleanupRestoreTests.swift`：15
- `MSeriesCoreKernelTests.swift`：62、84
- `MSeriesResourceReceiptTests.swift`：8、22
- `RecordedCleanupRecoveryTests.swift`：13
- `RecordedTrashRecoveryTests.swift`：30、68、94
- `SystemUtilitySafetyTests.swift`：169、218、273、300、332、333（`Library/Preferences/<标识>.plist`）、334、376、378
- `UninstallAuthorizationTests.swift`：135、182
- `UninstallExecutionTests.swift`：12
- `UninstallExperienceTests.swift`：12、28、63
- `UninstallOwnershipTests.swift`：63、95、142（存疑）
- `UninstallRetryResultTests.swift`：155、260
- `UninstallStoreWiringTests.swift`：20

本批不修。回执日志拒绝经过链接的路径，系统临时目录只能经 `/var`、`/tmp` 链接访问，需要回执日志的夹具可按 P2-11 的做法改到 `/Users/Shared/<UUID>/`（目录 URL 带结尾斜杠）。

### 第三轮命令与结果

环境与 scratch 同前（未新建构建目录）；日志在 `~/Developer/.sc-build/r2-junk/round3/`。本轮期间机器负载约 17–33（其他会话）。

| 步骤 | 命令要点 | 结果 |
|---|---|---|
| 合并后构建 | `swift build --build-tests` | PASS，exit 0（184 s，`merge-build.log`） |
| 红测 | `swift test --filter 'CleanupStoreFollowUpTests\|CleanupDuplicateApplicationTests\|CleanupLogPreselectionTests'` | 按预期 FAIL，exit 1：21 项中 9 项失败、共 22 处（`r3-red-test.log`）；`testALogRowThatCannotBeReadCompletelyIsNotPreselected` 首跑通过（补覆盖） |
| 各项绿测 | 同上分项 | PASS（`r3-p11-green-test.log`、`r3-r2-test.log`、`r3-p23-test.log`、`r3-p27-test.log`） |
| 相关测试类 | 14 个类 | PASS：419 项，跳过 3，失败 0，exit 0（`r3-related.log`） |
| 完整 Debug 第 1 次 | `swift test` | 3391 项，跳过 21，失败 2，exit 1（340 s，负载 20→78，`r3-full-debug.log`）：`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`（CPU 基准超出 15 秒上限，`resourceLimit`，看板 N10）与 `NetworkCompatibilitySpeedTestServiceTests.testCancellationStopsPendingURLSessionTasks`（计时）；后者单独重跑与整个类 46 项均通过；本分支自 `561e2df` 起没改过基准代码与测试 |
| 完整 Debug 第 2 次 | `swift test`（等 1 分钟负载降到 15 以下） | 3391 项，跳过 21，失败 1，exit 1（292 s，`r3-full-debug-2.log`）：仍是上面的基准测试（5 分钟负载仍约 38） |
| 基准测试单独重跑 | `--filter MacBenchmarkKernelTests/testStandardQuickKernelsCompleteWithinDeclaredLimits`（等 5 分钟负载降到 8 以下） | PASS（13.7 s，`r3-bench-retry.log`）；未改阈值 |
| 完整 Debug 第 3 次（本轮最终代码） | `swift test` | PASS：3391 项，跳过 21，失败 0，exit 0（228 s，负载 6.8→7.1，`r3-full-debug-3.log`） |
| 严格并发构建 | `swift build -Xswiftc -strict-concurrency=complete`（strict scratch，`out` 又不在，完整重建） | PASS，exit 0（297 s，负载约 70–95），无警告（`r3-strict.log`） |
| 私有接口、源码守卫、空白检查 | `check_private_api.py`；`verify.sh` 三项守卫；`git diff --check 561e2df..HEAD` 与工作区 | 均 PASS，exit 0（`Views` 中没有 `.terminate(`；退出服务里没有 `forceTerminate`） |

### 第三轮 JEV

`jev_review`（第三轮改动摘要与测试摘要，无个人路径）：正确性 1.70、需求符合 1.81、测试缺口 0.59、影响面 1.95、safe_to_apply 0.49、综合 0.721，动作 **escalate**（需人工复核，不视为通过）。测试缺口主要在真实应用的退出路径（自动化不退出真实应用）和 SwiftUI 面板实际呈现（测的是视图使用的绑定，不是渲染）。

### 第三轮剩余与未验证

- 真实应用上的“正常退出并清理”（`terminate()`、5 秒等待、应用弹出“保存？”时）仍需实机核对；复用的实现按标识请求退出，等待期间新开的同标识实例也会被请求。
- 面板“弹出”本身没有渲染级测试（测的是 `ContentView` 用的绑定与 store 状态）。
- 受保护副本在应用启动／退出后会随运行状态刷新而变化；扫描时整组都受保护而被去掉的组，要重新扫描才会再列出。
- 第 10 项仍需主会话记入 `DECISIONS.md`（复核者称为 D40）。

## 结论

结果页（智能扫描、安全清理、开发工具与产物）列出的每一项都能勾选、能处理；除“清空废纸篓”外都只移入废纸篓。核心不变量由新测试 `CleanupJunkActionableTests.testEveryBundledRuleCategoryProducesOnlyActionableResults` 锁定：用临时目录夹具为全部内置规则各造一个命中项目，并加入目录内符号链接、超过深度上限、无权限子目录、根目录无法列出四种变体。旧实现上该测试失败（80 项中只有 41 项可选，见“反证”）；新实现上全部列出项可选，根目录无法列出的项目不列出、计入安全跳过。

## 第一步复核修复（主会话 A1 独立复核：需小修后合并，无 P0；2026-10-05）

复核材料（含 6 个探针）在主会话 scratchpad `review-junk/`。本轮在同一分支逐项“先写能复现的测试（红）→ 修 → 绿”，每项单独提交（P2-2 与 P2-6 同属回执、合为一个提交；P1-1、P2-8、P2-9 同改扫描器计数与不变量测试、合为一个提交）。仍未修改 `Stores/ScanStore.swift`；未启动、未退出任何应用；所有夹具都在临时目录（P2-11 的回执日志夹具在 `/Users/Shared`，见该项）。红绿日志在 `~/Developer/.sc-build/r2-junk/a1-review/`。

### 逐项结果

| 项 | 状态 | 改动 | 测试（红 → 绿） | 提交 |
|---|---|---|---|---|
| P1-1 用户排除的子目录 | 已修 | 行、开发缓存、重复副本、废纸篓条目只要包含用户排除的路径（与执行器同一判断 `ScanExclusionService.intersectsExcludedTree`），扫描就不列出、不测量、废纸篓不冻结；计入“未列出”，原因单独记录（`ScanIssueKind.candidateContainsExcludedPath`、`ScanMetrics.excludedPathCandidateCount`），提示写成“其中 N 项包含你排除的路径”。“活动无法核实”等级的说明去掉“你排除的子目录”。废纸篓一行“至少”的说明改为“这些项目不会被删除，大小只计入将删除的项目” | `CleanupJunkActionableTests.testItemsHoldingUserExclusionsAreCountedNotListed`（新）、不变量测试第 5 种情况。红：`com.example.idle`、`_npx` 列出，`Folder` 被冻结，预检 3 项 `excludedByUser`（`g1-red-test.log`） | `24a4cb8` |
| P2-1 重复应用 | 已修 | 应用标识、`CFBundleShortVersionString`、`CFBundleVersion` 全相同才算重复（每次扫描直接读 `Contents/Info.plist`，不用 `Bundle` 缓存；两份都无版本键时视为相同）；只测量重复组，其他大应用不遍历；每行显示“版本 X（构建 Y）”，`xcode-select` 使用的副本标“xcode-select 当前使用”；保留顺序：运行中 → `/var/db/xcode_select_link` 指向的 `.app`（只读链接、不起子进程，扫描器新增可注入的 `developerDirectoryLinkURL`）→ 直接位于 `/Applications` → 最新修改 → 路径短 → 字典序 | `CleanupDuplicateApplicationTests`（新，3 项）。红：两份 Xcode 被列为重复并被测量、无版本证据、保留了较新的 `Xcode.app`（`g678-red-test.log`） | `9ae17f3` |
| P2-2 降级 | 已修 | 含“已永久删除”或“永久删除未完成”的回执不写旧版 UserDefaults 回执缓存（`CleanReport.isReadableByOlderVersions`）；回执日志照常保存 | `CleanupReceiptHistoryTests.testReceiptsWithPermanentDeletionsStayOutOfTheLegacyCache`。红：三份都写入缓存 | `1f19d99` |
| P2-3 永久删除加固 | 已修 | 计划项记下扫描时废纸篓文件夹身份（`CleanPlanItem.allowedRootIdentity`）；删除器改为 `removeTrashEntry(_:)`：`O_NOFOLLOW|O_DIRECTORY` 打开 `~/.Trash`，核对设备号、inode、类型、创建时间；`fstatat(AT_SYMLINK_NOFOLLOW)` 核对条目身份、拒绝其他卷；`unlinkat` 相对该目录删除，文件夹逐层 `openat(O_NOFOLLOW)` 后清空、遇挂载点停止、最多 128 层。删除前被拒绝记为跳过（`pathOutsideAllowedRoot`／`identityChanged`／`volumeChanged`），删到一半出错仍记“永久删除未完成”。三次复核保留，并加“废纸篓文件夹与扫描时相同”一条 | `CleanupTrashDeletionTests`（新，3 项）。红：在最后一次复核之后把废纸篓换成指向另一文件夹的链接（内放同身份硬链接），旧删除器删掉了废纸篓之外的文件并记为“已永久删除”（`g3459-red-test.log`）。跨卷拒绝没有夹具（需挂载卷），只有代码路径 | `f47c6d2` |
| P2-4 完全磁盘访问判断 | 已修 | 错误按所属错误域判断，并读取底层错误：Cocoa 257/513、POSIX `EPERM`/`EACCES` → 无权限；Cocoa 4/260、POSIX `ENOENT` → 已不存在；POSIX 4（`EINTR`）不再误判为“已不存在”。列目录与读元数据共用同一映射 | `CleanupRuleScannerTests.testPermissionErrorsAreRecognizedInEveryDomain`（新）。红：8 处断言失败 | `92a73a7` |
| P2-5 废纸篓云端占位 | 已修 | 冻结时按废纸篓规则的云策略跳过未下载的占位文件并计入“云文件”；计划生成遇到占位条目跳过而不是整份失败；执行前复核新增“变成占位即跳过（`cloudStateChanged`）” | `CleanupJunkActionableTests.testCloudPlaceholdersInTheTrashAreSkippedNotFatal`。红：占位被冻结，含废纸篓的计划抛 `invalidCandidate` | `d4cb4af` |
| P2-6 清空后的“可恢复”回执 | 已修 | “操作记录”打开回执详情时在后台逐项核对移入位置（`lstat` + 身份，`CleanupReceiptAvailability.departedOriginalPaths`）：已不在或已被替换显示“已不在废纸篓 · 无法在此恢复”，全部如此时“恢复”不可用；读不到（如无完全磁盘访问权限）保持原样。确认面板提醒“其中如有早先清理移入的文件，之后也无法再从‘操作记录’恢复” | `CleanupReceiptHistoryTests` 两项。红：始终报告为空、界面无此文案 | `1f19d99` |
| P2-7 本地历史与审计记录 | 已修 | 扫描遇到 `LocalHistory`／`local-history`／`local_history`／`Local History`（不区分大小写）文件夹即停止向内读，所在行不列出，计入“未列出”（`candidateContainsProtectedData`、`protectedDataCandidateCount`，提示“含本地历史记录等个人数据”）；WorkBuddy 日志不再列 `audit-log`。JEV `jev_decide` 选此方案（置信度 1.0）。代价：含本地历史的 JetBrains 缓存整行不清理，只清索引需后续规则 | `CleanupJunkActionableTests.testLocalHistoryAndAuditRecordsAreNotListed`。红：`JetBrains`、`com.example.tool`、`audit-log` 均列出 | `57bea99` |
| 第 10 项 日志 7 天规则（D22 补充，用户可推翻） | 已做 | 用户日志、诊断日志、开发工具日志：该行最近一次写入早于 7 天且（能识别所属应用时）所属应用未运行才预选，识别不出所属应用不再挡预选；7 天内有写入的行显示“最近 7 天内仍有写入”，读不全的行不预选并显示“无法确认最近 7 天内是否有写入”；`DiagnosticReports` 视为无所属应用；开发工具日志不再无条件预选；缓存规则不变；“选择推荐项目”同一口径。证据码 `log-write-window:quiet/recent/unverified`；相关说明文案同步 | `CleanupLogPreselectionTests`（新）。红：新写入的日志被预选、未识别来源的安静日志未预选、`DiagnosticReports` 为“未识别” | `722c6a0` |
| P2-8 “未列出”口径 | 已修 | 大小未知的行（根目录无法列出）不再被单列阈值静默丢弃，一律进入未列出计数；含排除路径、含本地历史的行同样不受阈值影响。文档写明四种原因 | `CleanupJunkActionableTests.testUnlistableRowsAreCountedEvenBelowTheSizeThreshold`（生产阈值）。红：未列出计 0 | `24a4cb8` |
| P2-9 不变量测试扩展 | 已做 | 不变量测试在第 5 种情况（行内有用户排除的子目录）下，对全部列出项（重复副本除外：其计划只接受真实 `/Applications`）生成计划、执行前检查全部就绪、在临时夹具里全部移入废纸篓或永久删除，链接目标与排除路径保留 | 同上测试；红：`fixture-excluded` 列出且预检 `excludedByUser` | `24a4cb8` |
| P2-11 测试夹具 | 已修 | `testJournalReloadRetainsIdentityAndRejectsChangedIntent` 先断言夹具不在真实 `~/Library`（不在则立即失败、不写任何文件），夹具改到 `/Users/Shared/StorageCleanerJournalFixture-<UUID>/`。系统临时目录不可用：回执日志拒绝含链接的路径，而 `/var`、`/tmp` 是链接，路径规范化又会把 `/private/var` 变回 `/var`，经数据卷访问时列目录又返回 `/private/var`。其余 11 处同类夹具（其他测试类）未改 | 红：守卫断言失败（未写文件）；绿：通过，`/Users/Shared` 无残留 | `e0325a7` |

另外：`rulesVersion` 升为 `2026.10.05.1`（WorkBuddy 候选与日志预选口径变化），`docs/cleanup-rules.md` 同步（四种未列出原因、本地历史、日志 7 天规则、重复副本定义与保留顺序、删除加固、权限识别、回执处理）。

### 改动锁定旧行为的测试

| 测试 | 原断言依据 | 现在 | 依据 |
|---|---|---|---|
| `CleanupJunkActionableTests.testPreselectionSkipsRunningOwnersAndUnidentifiedRows` | 刚写入的 `com.example.idle` 日志与诊断日志被预选 | 这两项夹具改为 10 天前写入，原断言不变；`DiagnosticReports` 保持新写入，仍不预选，新增断言其为“无所属应用”、状态 `recent` | 第 10 项 |
| `CleanupRuleScannerTests.testDeveloperToolArtifactsExposeOwnerAndTypeWhileProtectedStateStaysExcluded` | 刚写入的 Codex 日志被预选 | 夹具改为 10 天前写入，断言不变 | 第 10 项（开发工具日志不再无条件预选） |
| `CleanupRuleScannerTests.testStorageAnalyzerGoldenSnapshotUsesStableIdentityAndSelectsOnlyGreenByDefault` | “选择推荐项目”含刚写入的日志（共 3 项） | 该日志夹具改为 10 天前写入，断言不变 | 第 10 项 |
| `CleanupTrashDeletionTests.testDeletionRefusesATrashSwappedAfterTheLastCheck`（本轮新写） | 红阶段预期“永久删除未完成” | 改为更严格的“跳过：路径不在允许范围”（证明一项也没删）；“外部文件仍在”“已删除 0 项”断言不变 | P2-3 |

没有删除断言，没有放宽阈值，没有新增跳过（P2-11 只在 `/Users/Shared` 不存在时跳过）。

### JEV

- `jev_decide`（P2-7 方案）：`generic_not_listed` 概率 1.0，三条要求均“支持”；另两案各有一条“矛盾”（按产品拆分规则超出 P2 范围；静默排除不计数）。
- `jev_review`（P2-3 删除加固的源码摘录与测试摘要，未含个人路径）：正确性 1.76、需求符合 1.94、测试缺口 1.03、影响面 1.80、safe_to_apply 0.40、综合 0.731，动作 **escalate**（需人工复核，不视为通过）。测试缺口主要是跨卷拒绝没有夹具；据此补了“删到一半”的测试（见下）。

### 命令与结果（本轮）

环境同下文“命令与结果”：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，沿用原 scratch（`~/Developer/.sc-build/r2-junk/debug`、`…/strict`，未新建构建目录；原 `out` 目录已不在，首次为完整重建），命令带 `--jobs 4 --skip-update --disable-automatic-resolution`。日志在 `~/Developer/.sc-build/r2-junk/a1-review/`。

| 步骤 | 命令要点 | 结果 |
|---|---|---|
| 基线重建（`90eb4a6`） | `swift build --build-tests` | PASS，exit 0（122 s，`build-baseline.log`） |
| 各项红测 | `swift test --skip-build --filter …`（见上表） | 均按预期 FAIL，exit 1（`g1-red-test.log`、`g2-red-test.log`、`g3459-red-test.log`、`g678-red-test.log`、`g8-red-test.log`） |
| 各项绿测 | 同上 | 均 PASS，exit 0（`g1-green-test.log` … `g8-green-test.log`、`p23-extra-test.log`） |
| 相关测试类 | `--filter 'CleanupRuleScannerTests\|CleanupExecutionSafetyTests\|UIConsistencyRegressionTests\|SafeCleanupLayoutTests\|CodexArtifactScannerTests\|SystemUtilitySafetyTests\|CleanupJunkActionableTests\|CleanupLogPreselectionTests'` | PASS：383 项，跳过 3，失败 0（`g7-green-test.log`）；另 `CleanupReceiptHistoryTests`、`LegacyCleanupRestoreTests`、`RecordedCleanupRecoveryTests`、`InterruptedOperationReconcileTests` 等 96 项 0 失败（`g8-green-test.log`） |
| 完整 Debug 第 1 次（`1f19d99` + 文档与 `rulesVersion`） | `swift test` | 3213 项，跳过 21，失败 1：`NetworkCompatibilitySpeedTestServiceTests.testStoreCancellationWaitsForRealCompatibilitySessionShutdownBeforeLeaseRelease`（取消后 URLProtocol 停止计数 0 < 1，与清理无关、计时相关）；exit 1（177 s，负载 2.65→3.64，`step1-full-debug.log`）。单独重跑 3 次均 PASS，整个测试类 46 项 PASS（`rerun-network-*.log`）；未改该测试 |
| 完整 Debug 第 2 次（`19662c3` + 文档与 `rulesVersion`，即本轮最终代码） | `swift test` | PASS：3214 项，跳过 21，失败 0，exit 0（178 s，负载 4.49→2.89，`step1-full-debug-2.log`） |
| 严格并发构建（同上代码） | `swift build -Xswiftc -strict-concurrency=complete`（strict scratch，完整重建） | PASS，exit 0（78 s），无警告（`step1-strict.log`） |
| 私有接口检查 | `python3 script/check_private_api.py` | PASS（6 处白名单），exit 0 |
| 源码守卫 | `script/verify.sh` 中的 Views 进程／结束应用、purge、冲突副本三项 | PASS |
| 空白检查 | `git diff --check 561e2df..HEAD`、工作区 `git diff --check` | PASS，exit 0 |

未运行 Release 全量、小窗性能脚本与界面截图（主会话门禁）；未安装、未启动或退出任何应用；未 push。

### 本轮剩余与未验证

- P2-3 的跨卷拒绝没有夹具（需要挂载卷），只有代码路径与审阅；JEV 复核为 escalate，需人工复核删除代码。
- P2-1 执行前不再核对版本号：扫描后、清理前若有副本被原地升级，仍依赖既有的“保留副本身份与修改时间未变”检查；如需更严，可在执行前重读 Info.plist（会触及既有以假路径构造的测试）。
- P2-6 只在打开回执详情时核对；列表页摘要的“已移走 N”不变（它是历史事实）。没有完全磁盘访问权限时读不到废纸篓，回执保持“可恢复”字样（恢复时仍会核对身份，遇缺失如实报告）。
- P2-7 只识别文件夹名；JetBrains 含本地历史时整行不清理，若需清理其索引与缓存，需要按产品子目录分行的新规则。
- P2-11 只修了复核点名的一个测试；其余建在真实 `~/Library` 下的测试夹具见“第三轮”中的更正（复核实测 15 个文件、33 处，此处原写“约 11 处”有误）。
- 第 10 项是主会话决定，作为 D22 补充、用户可推翻；本分支未改 `DECISIONS.md`（按任务卡），需主会话记入。

## 逐项改动

| # | 任务 | 改动 | 主要文件 |
|---|---|---|---|
| 1 | 核心不变量 | 扫描器在每条规则结束时只保留 `isSelectable` 的结果，其余记 `ScanIssueKind.candidateNotActionable` 并计入 `ScanMetrics.notActionableCandidateCount`，使扫描结果为“部分”，界面在“部分范围已因安全边界跳过”中显示数量。规则校验器不再允许 `descendantAggregate`（只读汇总）规则；`/Applications` 规则只允许重复副本 | `Services/ReadOnlyCleanupScanner.swift`、`Models/CleanupScanModels.swift` |
| 2 | 规则调整 | 见“新规则表”。JSON 删除 8 条（照片图库、微信、Chrome 用户数据、Codex 会话、ego lite、CrossOver、已安装应用、大型创作应用）；`system.user-caches`、`system.user-logs` 改为绿色、可选、预选，按子目录分行（`ownerInference: candidateName`），带排除清单；开发工具目录删除 15 条会话、检查点与 `.codex/.tmp` 规则，9 条日志改为绿色预选（`DeveloperArtifactCleanupPolicy.disposableLogs`，不按活动分级）；目录表中浏览器与应用缓存改为推荐预选，诊断日志与 Codex 应用日志改为绿色预选，CloudKit 与邮件附件副本改为黄色可选，邮件库附件删除；`rulesVersion` 升为 `2026.10.04.1` | `Resources/CleanupRules.v2.json`、`Models/CleanupCoverageCatalog.swift`、`Models/CleanupScanModels.swift` |
| 2 | 不重复列出 | 新增校验：按行列出的容器规则必须排除每个更具体规则占用的子目录（同根的精确名或位于其下的根，如 `Caches/Google`）；自动规则重叠检查改为认可这种排除（`haveDisjointNames`）。排除比较按 Unicode 规范化；新增 `exclude.namePrefixes`（前缀排除） | `Services/ReadOnlyCleanupScanner.swift`、`Models/CleanupScanModels.swift` |
| 3 | 测量不完整 | `CleanupSelectionPolicy` 只把“无法计算”（`failed`）视为不可选；计划生成与执行前复查同样接受“至少”。开发缓存：只因跳过符号链接而不完整时照常分级（`DeveloperCleanupAgePolicy.verifiesActivity`）；有无法读取、深度上限或用户排除部分时为新等级 `activityUnverified`（红色、可选、不预选、双重确认）。合并不完整原因时，“跳过符号链接”让位于其他原因，因此原因可区分。执行前的开发活动复查改为与扫描完全相同的读取方式（跳过链接不跟随、跳过排除与不可读部分、深度上限处取目录自身时间），根目录仍须不是链接、在允许范围内 | `Models/CleanupScanModels.swift`、`Models/CleanupExecutionModels.swift`、`Services/SafeCleanupExecutor.swift`、`Services/ReadOnlyCleanupScanner.swift` |
| 4 | 默认预选（D22） | 扫描结束时经 `CleanupApplicationEnvironment` 读取一次正在运行与已安装的应用（正式扫描用 `WorkspaceCleanupApplicationEnvironment`，测试与默认用不读系统的空环境）。候选新增 `ownerResolution`、`ownerBundleIdentifiers`、`runningOwnerBundleIdentifiers`。所属应用：规则写明的 `requiredClosedBundleIDs`；按行列出的缓存与日志按名称或其至少三段的反向域名前缀匹配已安装应用；重复副本按应用包路径判断运行。`CleanupSelection.defaults`、`.recommended` 跳过所属应用在运行或未识别的行；行内显示“正在运行，清理前需退出”；未识别的行徽标显示“可选”。从名称识别出的应用也写入计划项 `inferredOwnerBundleIDs`，执行前仍在运行则跳过 | `Models/CleanupScanModels.swift`、`Services/ReadOnlyCleanupScanner.swift`、`Models/CleanupExecutionModels.swift`、`Services/SafeCleanupExecutor.swift`、`Views/CleanupScanViews.swift` |
| 5 | 重复应用（D25） | 重复副本规则自己扫描 `/Applications`：先读应用标识，只测量重复组内副本（深度 32），整组列出、按组截断。保留规则 `DuplicateApplicationRetentionPolicy`：扫描时正在运行的副本 → 应用包修改时间最新 → 路径较短 → 路径排序在前。整组勾选时自动去掉保留副本；单独勾选最后一份不生效，行内显示“将保留此副本”；分组与分层勾选框按“可选副本”判断全选状态（`CleanupSelection.groupState`）；计划生成时若整组仍全选，同样按规则去掉保留副本，不再整份失败 | `Models/CleanupScanModels.swift`、`Models/CleanupExecutionModels.swift`、`Services/ReadOnlyCleanupScanner.swift`、`Views/CleanupScanViews.swift` |
| 6 | 清空废纸篓（D23） | 新动作 `CleanupRuleAction.emptyTrash`。扫描冻结 `~/.Trash` 第一层项目（`permanentDeletionEntries`），指向废纸篓外的符号链接不列入、无法列出的文件夹不列入；无读取权限时报告权限不足。计划按冻结项目逐项生成删除项；执行前逐项核对仍直接位于 `~/.Trash`、身份未变、卷可写、链接仍指向废纸篓内；删除用 `CleanupPermanentDeleting`（默认 `FileManager.removeItem`，删除链接本身、不跟随）。回执新结果 `.deleted(CleanupDeletionReceipt)`，汇总 `deletedItemCount`、`permanentlyFreedBytes`；中断或未删干净记 `deletionOutcomeUnknown`，不参与“在废纸篓中找回”的对账。结果页单独一节，确认面板单独一节两项确认，与移入废纸篓的项目分开显示和计数；无权限时给出“完全磁盘访问权限”指引和“打开系统设置” | `Models/CleanupCoverageCatalog.swift`、`Services/ReadOnlyCleanupScanner.swift`、`Models/CleanupExecutionModels.swift`、`Services/SafeCleanupExecutor.swift`、`Views/CleanupScanViews.swift`、`Views/CleanupExecutionViews.swift` 等 |
| 7 | 数字口径 | 三张风险卡的数值与分组数只统计可选、非“清空废纸篓”的项目；扫描进度的“候选大小”与项目数同一口径（不含废纸篓） | `Views/CleanupScanViews.swift`、`Services/ReadOnlyCleanupScanner.swift` |
| 8 | 文案 | 三个风险层说明、执行建议、容量“至少”说明、可访问性提示、分组指引、规则说明（用户缓存、用户日志、诊断日志、应用日志、CloudKit、邮件附件副本、废纸篓、重复应用、开发工具日志，并为开发活动等级补上中文原因，原先确认面板会显示内部键名）、首页扫描范围两行；开发工具页“部分结果”提示原为“会话与检查点仅采集顶层元数据”（会话已不再列出），改为说明“至少”的原因；删去只为已移除的会话行服务的“顶层目录修改时间”分支；开发工具日志的详情不再显示活动阈值；`docs/cleanup-rules.md` 重写为现行规则；`AGENTS.md` 第 6 行；`docs/PROJECT_STATE.md` 第 271 行 | `Services/ReadOnlyCleanupScanner.swift`、`Views/*.swift`、文档 |
| 9 | 跳过原因可见 | 把未接线的 `CleanupV2OperationOverlay` 中的逐项列表提取为共享视图 `CleanupReportIssueList`，完成页直接显示每个跳过、失败、未处理项目及原因（覆盖层同样使用它）；完成页另显示“永久删除”体积 | `Views/CleanupExecutionViews.swift` |
| — | 供 A2 接线的纯模型函数 | `ScanSession.removingCleanedItems(report:plan:)`（清理后去掉已移走或已删除的行，废纸篓只留未删项目）、`ScanSession.updatingRunningOwners(from:)`、`ScanSession.mappingCandidates(_:)`、`ScanCandidate.withRunningOwners(from:)`，均有测试 | `Models/CleanupExecutionModels.swift`、`Models/CleanupScanModels.swift` |

`Views`、回执与记录页的其余改动只是为新的结果 `.deleted` 与失败码 `deletionOutcomeUnknown` 补齐分支（`OperationResultPresentation`、`ReversibleOperationsView`、`UninstallPreviewSheet`、`UninstallExecution`、`RecordedTrashOperation`、`CleanupReportJournal`、`CleanupReportIndex`、`DebugSmartScanSessionFixture`）。`DiskScanner`（旧版扫描）只改了策略名称引用，路径集合不变。

## 新规则表

| 类别 | 规则 ID | 风险 | 可选 | 默认预选 | 是否移出结果 |
|---|---|---|---|---|---|
| `~/Library/Caches` 各应用缓存（按应用分行） | `system.user-caches` | 绿 | 是 | 所属应用识别成功且未运行 | 否 |
| 浏览器缓存（6） | `browser-cache.*` | 绿 | 是 | 浏览器未运行 | 否 |
| 应用缓存（5） | `application-cache.*` | 绿 | 是 | 应用未运行 | 否 |
| 用户日志（按来源分行） | `system.user-logs` | 绿 | 是 | 所属应用识别成功且未运行 | 否 |
| 诊断日志 | `system-log.diagnostics` | 绿 | 是 | 是（无所属应用） | 否 |
| Codex 应用日志 | `application-log.codex` | 绿 | 是 | Codex 未运行 | 否 |
| 开发工具日志（9） | `developer.*-logs` | 绿 | 是 | 所属应用未运行（Cursor 日志新增 Cursor 应用标识） | 否 |
| 开发缓存与临时文件（npx、npm、Homebrew、uv、DerivedData、pip、SwiftPM、Clang、Bun、Playwright MCP、各 AI 工具缓存与 tmp） | `developer.*` | 按活动：>365 天绿、>阈值黄、阈值内红；部分不可读红 | 是 | 绿色且所属应用未运行 | 否 |
| CloudKit 缓存 | `system-cache.cloudkit` | 黄 | 是 | 否 | 否 |
| 邮件附件副本（Mail Downloads） | `mail.downloaded-attachments` | 黄 | 是 | 否 | 否 |
| 下载安装包、下载大项目 | `downloads.installers`、`downloads.large-items` | 黄 | 是 | 否 | 否 |
| 重复安装的应用副本 | `applications.duplicate-installed-apps` | 红 | 是 | 否 | 否 |
| 清空废纸篓 | `trash.user-trash` | 红（单独一节） | 是 | 否 | 否 |
| 照片图库 | `personal.pictures-library` | — | — | — | 已移出（D19） |
| 微信、Chrome 用户数据、Codex 会话、ego lite、CrossOver | `user-data.*` | — | — | — | 已移出（D19） |
| 开发工具会话、检查点、`.codex/.tmp`（15） | `developer.*-agent-data`、`developer.codex-runtime-temporary-files`、`developer.gemini-cli-data`、`developer.cline-*`、`developer.roo-code-*` | — | — | — | 已移出（D19） |
| 邮件库内附件 | `mail.library-attachments` | — | — | — | 已移出（D24） |
| 已安装应用、大型创作应用 | `applications.installed-apps`、`applications.large-creative-apps` | — | — | — | 已移出（D25） |

## 排除清单

写入 `docs/cleanup-rules.md` 与 JSON。`system.user-caches` 排除：更具体规则占用的 `Homebrew`、`Claude`、`claude-code`、`com.todesktop.230313mzl4w4u92`、`GitHub Copilot`、`OpenClaw`、`Google`、`Microsoft Edge`、`BraveSoftware`、`Firefox`、`company.thebrowser.Browser`、`net.whatsapp.WhatsApp`、`Codex`、`com.openai.codex`、`Citro Labs`、`typeless-updater`、`us.zoom.xos`、`ms-playwright-mcp`、`pip`、`org.swift.swiftpm`、`clang`、`bun`、`CloudKit`；系统关键 `com.apple.accountsd`、`com.apple.akd`、`com.apple.amsaccountsd`、`com.apple.appleaccountd`、`com.apple.bird`、`com.apple.cache_delete`、`com.apple.containermanagerd`、`com.apple.nsurlsessiond` 与前缀 `com.apple.FileProvider`、`com.apple.XProtect`；本应用 `com.local.StorageCleanerMac`、`com.local.StorageCleanerMac.beta`。`system.user-logs` 排除 `com.apple.diagnosticextensionsd`、`com.openai.codex`、`GitHub Copilot`、`OpenClaw`。前一类由校验器强制，漏写即加载失败。

## 测试与反证

### 反证

1. **旧实现**：在基线 `561e2df` 上只加入新测试文件，`testEveryBundledRuleCategoryProducesOnlyActionableResults` 失败：80 个列出项中只有 41 个可选（开发工具日志、会话与检查点、深度超限的 `_npx`、用户缓存与日志、CloudKit、诊断日志、邮件附件、废纸篓、照片图库、微信、Chrome、ego lite、CrossOver、已安装应用都“列出但不可选”）。日志：`~/Developer/.sc-build/r2-junk/counterproof-old-invariant.log`。
2. **定点破坏**（先把 4 个源文件备份到会话临时目录，改坏、构建、运行，再从备份还原并核对 SHA-1 与备份一致）：

| 破坏 | 预期失败的测试 | 结果 |
|---|---|---|
| R1 删掉废纸篓项目的身份复核 | `testEmptyTrashDeletesOnlyFrozenEntriesInsideTheTrash` | 失败：被替换的项目也被删除，删除数 3 |
| R2 计划生成不再自动保留重复副本 | `CleanupExecutionSafetyTests.testProtectedApplicationPlanRequiresExplicitSelectionAndApprovedScope` | 失败：`invalidCandidate` |
| R3 默认预选不看所属应用 | `testPreselectionSkipsRunningOwnersAndUnidentifiedRows` | 失败（预选集合两处） |
| R4 执行前不再复查从名称识别的应用 | 同上 | 失败：预检为 `ready` 而非“相关应用仍在运行” |
| R5 开发活动复查遇到链接即拒绝（旧行为） | `testLowerBoundDeveloperCachesStaySelectableAndPreflightMatchesTheScan` | 失败（三处预检结果） |
| R6 扫描器不再过滤不可操作项 | `CleanupRuleScannerTests.testFailedMeasurementIsVisibleButUnavailable`；收紧门槛后的 `testEveryBundledRuleCategoryProducesOnlyActionableResults` | 均失败（后者 57/58 可选） |

日志：`counterproof-new-tests.log`、`counterproof-invariant-r6.log`（同一目录）。R6 第一次没有让不变量测试失败——夹具里无法测量的根目录被降为 1 字节的大小门槛先挡掉了；已把该测试的门槛改为 0 并补断言，再次破坏确认失败。还原后相关测试全部通过（见下）。

### 新增测试

新增 `Tests/StorageCleanerMacTests/CleanupJunkActionableTests.swift`：

| 测试 | 覆盖 |
|---|---|
| `testEveryBundledRuleCategoryProducesOnlyActionableResults` | 核心不变量；全部内置规则各一项、四种变体；被列出的都可选；根目录不可列出的项目不列出，并记为安全跳过。JSON 与开发工具目录规则的门槛降为 0（目录表规则保持 1 MiB，夹具写入 1 MiB 以上），使无法测量的根目录确实走到 D19 过滤而不是被大小门槛挡掉 |
| `testRemovedPersonalDataAndApplicationBundlesAreNotListed` | D19/D24/D25：照片图库、微信、Chrome 用户数据、Codex 会话、`.codex/.tmp`、Claude 项目、ego lite、CrossOver、邮件库附件、创作应用与普通应用都不出现 |
| `testPreselectionSkipsRunningOwnersAndUnidentifiedRows` | D22：运行中、未识别不预选；前缀识别；声明的浏览器运行；诊断日志无所属应用；“选择推荐”同口径；刷新运行状态后恢复预选；执行前从名称识别的应用仍在运行则跳过 |
| `testLowerBoundDeveloperCachesStaySelectableAndPreflightMatchesTheScan` | D19：只有链接时仍为绿色并预选、执行前复查通过；部分不可读为红色可选；复查通过；可读部分被修改后跳过；链接目标不受影响 |
| `testEmptyTrashDeletesOnlyFrozenEntriesInsideTheTrash` | D23：只冻结废纸篓内项目，外指链接不列入；不预选；需明确勾选；进度口径不含废纸篓；与移入项目同计划执行：被替换的项目因身份变化跳过，扫描后新增的、本次移入的、外指链接及其目标都保留，文件夹内链接的目标保留；回执与汇总；清理后会话只留未删项目 |
| `testEmptyTrashStopsWhenTheTrashIsReplacedAndRecordsFailedDeletions` | D23：删除抛错记为“永久删除未完成”（`needsVerification`），不算移走、不可恢复；扫描后 `.Trash` 被换成指向别处的链接时预检全部拒绝，别处文件不受影响 |
| `testUnreadableTrashIsReportedNotEmpty` | D23：无权限时记“权限不足”，不报空 |
| `testValidatorKeepsEmptyTrashAndContainerRulesNarrow` | 清空动作只能用于 `.Trash`；容器漏排除即拒绝 |
| `testOwnerInferenceUsesReverseDomainNamesOnly` | 名称推断规则 |
| `testDuplicateRetentionPrefersRunningThenNewestCopy` | D25 保留规则 |

所有测试只用临时目录夹具（含夹具内的 `.Trash` 与 `Applications`），没有读写真实的 `~/Library/Caches`、`~/Library/Logs`、`~/.Trash` 或邮件目录。

## 改动的旧测试及依据

| 测试 | 原来锁定 | 现在 | 依据 |
|---|---|---|---|
| `CleanupRuleScannerTests.testDeveloperToolArtifactsExposeOwnerAndTypeWhileProtectedStateStaysExcluded` | Codex 日志只读、会话类规则存在 | 日志绿色可选并预选；会话、检查点、`.codex/.tmp`、Claude 项目、工作区存储都不列出 | D19、D22 |
| `…testBundledRulesEncodeStorageAnalyzerDecisionTiersWithNativeSafetyGuards` | 旧规则表（含只读规则与应用本体） | 新规则表（见上） | D19、D22–D25 |
| `…testKnownBrowserCacheWinsOverGenericCacheWithoutDoubleCounting` | 通用规则只读、Chrome 缓存默认不选 | 通用容器可执行并排除 `Google`；Chrome 缓存默认预选；容器漏排除即被拒 | D19、D22 |
| `…testIncompleteOptionalCacheDisplaysViewOnlyWithoutChangingRuleSafety` | “至少”项目显示为仅供查看、不可选 | 可选、显示“推荐”、默认预选（名称保留以便追溯） | D19、D22 |
| `…testMailAttachmentDiscoveryAggregatesOnlyMatchedDescendants`、`…testMailAttachmentAggregateBecomesLowerBoundWhenTraversalSkipsSymlink` | 邮件库附件只读汇总 | 删除；新 `testMailDownloadsAreReviewedAndMailLibraryAttachmentsAreNotListed` | D24 |
| `…testDeepStorageAnalyzerCandidateCountsDataBeyondEightLevels` | 只读规则 `reviewRequired` | 规则改为黄色可选，断言 `selectableWithReview`；深度断言保留 | D19 |
| `…testDuplicateApplicationBundlesBecomeProtectedDecisionItems` | 依赖“已安装应用”清单规则，其他应用列为信息项 | 只列重复副本，测量完整，其他应用不列出 | D25 |
| `…testApprovedCreativeApplicationsUseBundleIdentifierAllowlist` | 白名单应用可列为红色 | 白名单规则与信息规则被校验器拒绝 | D25 |
| `…testReadOnlyFixtureProducesCategoriesRiskReasonsAndSeparateSpaceTotals` | 只读日志列出 | 只读日志不列出，结果为“部分”，计 1 个未列出 | D19 |
| `…testLowerBoundMeasurementIsVisibleButCannotEnterPlan` | “至少”不可进入计划 | 可选、预选、计划只含根目录（名称保留） | D19 |
| `…testFailedMeasurementIsVisibleButUnavailable` | 列出但不可选 | 不列出，计入未列出与权限失败 | D19 |
| `…testLegacyReviewOnlyCandidateCannotEnterSelectionEvenWithForgedID` | 扫描列出只读项后验证伪造选择 | 扫描不再列出；伪造选择改用手工会话验证，断言不变 | D19 |
| `CleanupExecutionSafetyTests.testProtectedApplicationPlanRequiresExplicitSelectionAndApprovedScope`（原 261–274 行） | 整组全选使计划失败 | 整组勾选保留一份；分组勾选状态；单独勾选最后一份无效；伪造整组的计划同样保留一份 | D25 |
| `CleanupExecutionSafetyTests.testAllowlistedProtectedApplicationDoesNotRequireDuplicateCopy` | 白名单应用可进入计划 | 白名单规则被拒，计划报 `rulesChanged` | D25 |
| `UIConsistencyRegressionTests.testSmartScanResultsPrioritizeDecisionListAndCollapseSecondaryDetails`（401–405 行） | “只读参考”卡与可选／只读两类黄色 | 卡片只统计可选项、无只读卡、有清空废纸篓单节与完全磁盘访问指引 | D19、D23 |
| `UIConsistencyRegressionTests.testSmartScanCleanupKeepsSquareSelectionAndDedicatedSafetyPages`（506–507 行） | “受保护／仅供查看，不能加入清理计划” | 这两句不再出现；新增空分组提示、运行中提示、保留副本提示、确认面板的清空单节与两项确认、完成页逐项原因 | D19、D22、D23、D25 |
| `UIConsistencyRegressionTests.testSmartScanResultHierarchyUsesCompactNestedDisclosure`（451 行） | 分层勾选用 `state(for:)` | 改用 `groupState(for:in:)` | D25 |
| `SystemUtilitySafetyTests.testDeveloperCacheScanIncludesCodexCachesButSkipsCodexHistory` | 目录表含 `~/.codex/sessions`（只读） | 不再包含，`developer.codex-agent-data` 不存在 | D19 |
| `CodexArtifactScannerTests.testKnownAgentArtifactPathsOnlyIncludeExplicitCachesTemporaryFilesAndReviewLogs` | 策略名 `.reviewOnly` | 改为 `.disposableLogs`，路径集合不变 | 重命名 |
| `SafeCleanupLayoutTests.testCleanupExecutionAndTerminalPagesKeepActionsInTheViewport` | — | 新增一个带跳过、失败与永久删除行的完成页，断言不变 | 新增覆盖 |

没有删除断言来放宽检查，也没有放宽计时阈值或新增跳过。

## 第二步 A2（合并集成分支后修改 `Stores/ScanStore.swift`）

- 合并：第一步提交后 `git merge integration/2.0.0-beta`（`c7ee511`，含批次 4b 的 `MenuBarMonitorState` 与内存退出改动），无冲突，合并提交 `0f79b05`；合并后 Debug 构建通过（82 s，`merge-build.log`）。没有 rebase／reset。
- `ScanStore.swift` 只改清理段落。本步改动后的行号（相对 `0f79b05` 的增改）：818–822（新增发布状态：`cleanupOwnerQuitRequest`、`isQuittingCleanupOwners`、`isRecheckingCleanup`）、1039–1045（存储属性）、1185–1187 与 1250–1252（`init` 新参数与赋值：`cleanupUserHomeURL`、`cleanupApplicationEnvironment`、`cleanupOwnerQuitService`）、2065–2069（`isV2CleanupConfirmationPresented`）、2105 与 2128–2131（`requestV2Cleanup`）、2167–2170（`cancelV2CleanupConfirmation`）、2184–2227（`confirmV2Cleanup` 参数与门槛）、2288–2296（回执写入与结果刷新）、2324–2459（新函数：`refreshCleanupOwnerRunningState`、`requestQuitCleanupOwners`、`requestQuitCleanupOwnersForPendingPlan`、`cancelQuitCleanupOwners`、`quitOwnersAndRecheckCleanup`、`recheckPendingCleanup`、`presentCleanupOwnerQuitRequest`）、2711（执行上下文的主目录）、2785（扫描请求的主目录）。其余文件：`Services/CleanupOwnerQuitService.swift`（新）、`Views/CleanupExecutionViews.swift`、`Views/CleanupScanViews.swift`。

| 项 | 状态 | 改动 | 测试（红 → 绿） |
|---|---|---|---|
| 1 清理后刷新结果 | 已做 | `confirmV2Cleanup` 设置 `lastCleanReport` 后用 `session.removingCleanedItems(report:plan:)` 更新同一会话：移入废纸篓、永久删除的行离开结果，跳过与失败的行保留；选择仍清空 | `CleanupStoreFollowUpTests.testCleanedRowsLeaveTheResultsAndSkippedRowsStay`；红：清理后两行都还在 |
| 2 清空废纸篓独立确认 | 已做 | `confirmV2Cleanup(..., permanentDeletionAcknowledged:)`；红色门槛只看移入废纸篓的红色项目（`plan.protectedMoveItems`），清空废纸篓必须另给该参数，否则提示“请先完成清空废纸篓的两项确认。”；确认面板的两项清空确认单独传入，不再并入红色两项。旧版清空入口 `canRequestEmptyTrash` 仍只在旧版模式可用（测试断言为 false） | `testEmptyingTheTrashNeedsItsOwnConfirmation`；红：只给红色两项确认就把废纸篓项目删了 |
| 3 运行状态刷新与“正常退出并清理” | 已做（第三轮修改：只对可请求退出的应用提供、其余写“需手动退出”；列出每个实例；等待改为复用 `requestNormalTermination`、最长 5 秒；等待后核对扫描会话。见“第三轮”） | `refreshCleanupOwnerRunningState()`：重读运行中的应用，`updatingRunningOwners` 更新各行“正在运行”，不改选择；结果页出现时及 `NSWorkspace` 应用启动／退出通知时调用。`requestQuitCleanupOwners(for:cleanupScope:)`（运行中的行，只对已勾选的、所属应用在运行的行；重复应用副本不提供，因为运行副本按路径识别）与 `requestQuitCleanupOwnersForPendingPlan()`（确认面板中因“相关应用仍在运行”跳过的项目）先列出应用名，用户确认后 `quitOwnersAndRecheckCleanup()` 在服务层逐个发送 `NSRunningApplication.terminate()`（不强制结束），每 200 ms 检查一次、最长 10 秒，刷新行状态后：从行进入则按当前页选择重新发起清理（预检后进入确认面板），从确认面板进入则对同一冻结计划重新预检（`recheckPendingCleanup()`，期间面板保持、确认不可用）。未退出的应用逐个点名，相关项目照常跳过。只提供普通可见应用，不含本应用、Finder 与后台代理 | `testRunningStateRefreshesWithoutChangingTheSelection`、`testQuittingOwnersFromARunningRowThenCleans`、`testNothingReadyShowsReasonsAndQuittingRechecksThePlan`（红：均无反应）；`testQuitServiceAsksNormallyAndReportsAppsThatStayOpen`、`testWorkspaceQuitServiceQuitsNothingForIdentifiersThatAreNotRunning`（服务本身，随实现一起写，未单独取红）；`testViewsWireTheFollowUpFlow`（界面接线源码检查，同上） |
| 4 预检全部失败时逐项原因 | 已做（第三轮更正：store 层改了，但真实界面 `ContentView` 的绑定当时仍要求“可确认”，面板实际不弹、结果页被锁；第三轮 P1-1 修正） | 预检有项目但一项都没通过时，不再丢弃计划回到结果页，而是打开确认面板：新增“所有项目都未通过检查，暂不能执行”一节，逐项列出名称与原因（`CleanSkipReasonPresentation`），确认按钮不可用；有项目因相关应用仍在运行而跳过时提供“正常退出并清理”。预检本身无法进行（计划失效、功能关闭）时仍按原样回到结果页并提示 | `testNothingReadyShowsReasonsAndQuittingRechecksThePlan`；红：计划被丢弃、回到结果页 |

为在测试中跑通整条链路新增的注入点（生产默认值与原行为相同）：`cleanupUserHomeURL`（扫描请求与执行检查的主目录，默认真实主目录）、`cleanupApplicationEnvironment`、`cleanupOwnerQuitService`；`confirmV2Cleanup` 的回执改写入注入的 `operationJournal`（生产默认 `.live`，与原来写入的日志相同），测试因此写到隔离目录而不碰真实回执。测试夹具：主目录在临时目录，回执日志在 `/Users/Shared/StorageCleanerStoreFollowUpJournal-<UUID>/`（结束即删，原因同 P2-11），运行中的应用、退出服务与执行前的运行检查都是假的，没有退出任何真实应用。

### A2 命令与结果

环境与 scratch 同上（未新建构建目录）；日志在 `~/Developer/.sc-build/r2-junk/a2/`。

| 步骤 | 命令要点 | 结果 |
|---|---|---|
| 合并后构建 | `swift build --build-tests` | PASS，exit 0（82 s，`merge-build.log`） |
| 红测 | `swift test --filter CleanupStoreFollowUpTests`（注入点与空实现就位后） | 按预期 FAIL：6 项中 5 项失败、共 10 处，exit 1（`a2-red-test.log`）；退出服务自身的测试已通过 |
| 绿测 | 同上 | PASS：8 项，exit 0（`a2-green-test3.log`） |
| 相关测试类 | 14 个类（清理、界面一致性、布局、调试夹具、系统工具等） | PASS：408 项，跳过 3，失败 0（`a2-related.log`） |
| 完整 Debug（A2 中间版） | `swift test` | PASS：3295 项，跳过 21，失败 0（181 s，`a2-full-debug.log`）；之后又改了“应用已退出时直接重新检查”并加 1 个测试，见下一行 |
| 完整 Debug（A2 最终代码） | `swift test` | PASS：3296 项，跳过 21，失败 0，exit 0（180 s，负载 2.29→2.94，`a2-full-debug-2.log`） |
| 严格并发构建（A2 最终代码） | `swift build -Xswiftc -strict-concurrency=complete`（strict scratch） | PASS，exit 0（69 s），无警告（`a2-strict.log`） |
| 私有接口、源码守卫、空白检查 | `check_private_api.py`；`verify.sh` 的 Views 进程／结束应用、purge、冲突副本三项守卫；`git diff --check 561e2df..HEAD` 与暂存区 `git diff --cached --check` | 均 PASS，exit 0（`Views` 中没有 `.terminate(`；退出只在 `Services/CleanupOwnerQuitService.swift`） |

### A2 JEV

`jev_review`（A2 的 `ScanStore` 改动摘要、服务与界面说明、测试摘要；无个人路径）：正确性 1.79、需求符合 1.98、测试缺口 0.93、影响面 1.69、safe_to_apply 0.44、综合 0.759，动作 **escalate**（需人工复核，不视为通过）。测试缺口主要是真实 `NSWorkspace` 退出路径没有自动化覆盖；据此补了只读的真实工作区测试（不退出任何应用）。

### A2 未做与限制

- 没有在真实应用上验证“正常退出”（自动化不退出真实应用）：需实机用一个测试应用核对确认框文案、`terminate()` 后的等待、应用弹出“保存？”时的超时提示。
- 应用退出后不自动重新勾选它的行（选择不被改动是有意的）；用户可手动勾选或用确认面板的“正常退出并清理”。
- 等待上限固定 10 秒。从运行中的行进入时，所选其他行若所属应用仍在运行，会在确认面板中列为跳过，可在那里再退出。
- `confirmV2Cleanup` 外的旧版清空流程（`requestEmptyTrash`／`confirmEmptyTrash`）保持原状、只在旧版模式可用，未删除。

## 需要实机核对

- 真实 `~/Library/Caches` 按应用分行的结果：每行是否确为一个应用的缓存、排除清单是否足够（尤其系统守护进程缓存，它们识别不出应用，列出但不预选）、预选数量是否合理。
- 日志已按第 10 项改为“最近 7 天没有写入、且所属应用（能识别时）未运行才预选”；需在真实 `~/Library/Logs` 上核对预选数量与“最近 7 天内仍有写入”的提示。
- 扫描结束时在主线程逐个查询已安装应用（`urlForApplication(withBundleIdentifier:)`，按行名最多约三次），大量缓存目录时是否有可感知卡顿。
- 真实 `~/.Trash`：没有完全磁盘访问权限时是否显示指引；有权限时冻结项目、二次确认、删除与回执、“永久释放”数字；外接卷 `.Trashes` 不在范围内。
- 确认面板同时有黄色、红色、清空三节时的高度（已在多节时把列表高度上限降到 104 pt）。
- 重复副本：真实 `/Applications` 中的重复组与保留副本的选择；运行中副本作为保留副本。
- 含永久删除的回执不再写入旧版 UserDefaults 回执缓存（P2-2）；回执日志里的这类回执降级到旧版本时仍读不出（只影响这一份，不影响其他回执）。
- 真实 `/Applications` 中 `Xcode.app` 与 `Xcode-27.0.0-Beta.app` 版本不同，应不再列为重复；同版本的重复组中，`xcode-select` 指向的那份应被保留并标注。
- 真实 `~/Library/Caches/JetBrains` 含 `LocalHistory` 时整行不列出，“未列出”提示写明原因。
- 清空废纸篓后打开早先的回执详情，应显示“已不在废纸篓 · 无法在此恢复”。

## 风险

- 本轮新增（复核修复）：永久删除改为基于文件描述符的自写删除代码（P2-3），比 `FileManager.removeItem` 多了身份与卷核对，但也是新代码，JEV 复核为 escalate；日志预选口径变化（第 10 项）会让刚写过的日志默认不勾选。

- 预选范围明显扩大（D22）：按行缓存、浏览器与应用缓存、日志在所属应用未运行时默认勾选。执行前仍有确认、移入废纸篓可恢复；所属应用在运行会被跳过。
- “清空废纸篓”是本应用第一次永久删除用户文件。防线：冻结身份逐项复核、只限 `~/.Trash` 第一层、外指链接不碰、不跟随链接、单独两项确认、执行前三次复查、相对扫描时的废纸篓文件夹逐层不跟随链接删除；`ScanStore` 层的独立确认参数已在 A2 加上。
- 回执格式新增 `.deleted` 结果与可选字段（`deletedItemCount`、`deletedCount`）；新增字段为可选，旧回执可读。

## 命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`；Debug scratch `~/Developer/.sc-build/r2-junk/debug`（依赖从 `~/Developer/.sc-verify/integration/scratch/debug` 只读复制并改写路径）；严格并发 scratch `~/Developer/.sc-build/r2-junk/strict`。所有命令带 `--jobs 4 --skip-update --disable-automatic-resolution`。日志均在 `~/Developer/.sc-build/r2-junk/`。

| 步骤 | 命令要点 | 结果 |
|---|---|---|
| 基线构建（`561e2df`） | `swift build --build-tests` | PASS，exit 0（180.8 s，`baseline-build.log`） |
| 基线相关测试 | `swift test --filter 'CleanupRuleScannerTests\|CleanupExecutionSafetyTests\|UIConsistencyRegressionTests\|…'`（14 个类） | PASS：192 项，跳过 2，失败 0（`baseline-tests.log`） |
| 反证 | 见上 | 按预期 FAIL |
| 完整 Debug 第 1 次（会话辅助函数加入前的工作区） | `swift test` | 3197 项，跳过 21，失败 1：`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits` 超过 15 s 上限；运行期间负载 337／116／50（其他会话），属看板 N10。单独重跑 PASS（12.59 s，负载约 60）。未改阈值（`full-debug-1.log`、`rerun-benchmark-quick.log`） |
| 完整 Debug 第 2 次（提交 `27b7745`） | `swift test` | PASS：3197 项，跳过 21，失败 0，exit 0（196 s，负载 17.6→10.0，`full-debug-2.log`） |
| 相关测试（提交 `4825c00`） | `--filter 'CleanupJunkActionableTests\|UIConsistencyRegressionTests\|CleanupRuleScannerTests\|CleanupExecutionSafetyTests'` | PASS：127 项，跳过 2，失败 0（`run9.log`）；此前同一组加 `SafeCleanupLayoutTests`、`DebugSmartScanSessionFixtureTests`、`SystemUtilitySafetyTests`、`CodexArtifactScannerTests` 共 379 项，跳过 3，失败 0（`run8.log`） |
| 严格并发构建（提交 `4825c00`） | `swift build -Xswiftc -strict-concurrency=complete`（strict scratch） | PASS，exit 0（125 s），除 `--skip-update` 弃用提示外无警告（`strict-concurrency.log`） |
| 完整 Debug 第 3 次（提交 `4825c00`，最终代码） | `swift test` | PASS：3198 项，跳过 21，失败 0，exit 0（215 s，负载 11.8→14.3，`full-debug-3.log`） |
| 私有接口检查 | `python3 script/check_private_api.py` | PASS（6 处白名单用法），exit 0 |
| 源码守卫 | `Views` 中无 `Process(`／`.terminate(`／`.forceTerminate(`；无冲突副本 | PASS |
| 空白检查 | `git diff --check 561e2df..HEAD` | PASS，exit 0 |

没有运行 Release 全量与小窗性能脚本（主会话门禁步骤）；没有安装、没有启动或退出任何已安装应用；没有 push。

## JEV

- `jev_decide`：按来源分行的用户日志、所属应用识别不出时是否预选。选项“保持不预选、交主会话定”被选中，置信度 0.95（概率 0.96）。代码按此保持不变，并在“需要实机核对”中留给主会话。
- `jev_review`（清空废纸篓的设计摘录与测试摘要）：正确性 1.9／2、需求符合 1.97／2、测试缺口 0.63（置信度 0.33）、影响面 1.79、safe_to_apply 0.48、综合 0.794，动作 **escalate**（需人工复核，不视为通过）。据此补了 `testEmptyTrashStopsWhenTheTrashIsReplacedAndRecordsFailedDeletions`。只提交了源码摘录，未包含个人路径或数据。

## 提交

| 提交 | 内容 |
|---|---|
| `ee67895` | feat(cleanup)：规则、扫描、选择、计划、执行、界面与测试（D19、D22–D25） |
| `27b7745` | docs：`docs/cleanup-rules.md`、`AGENTS.md`、`docs/PROJECT_STATE.md` |
| `4825c00` | test(cleanup)：废纸篓被替换与删除失败的测试；开发工具页不显示废纸篓权限指引 |
| `90eb4a6` | docs：A1 交接 |
| `24a4cb8` | 复核 P1-1、P2-8、P2-9：含排除路径的项目计入未列出；大小未知的行不受阈值影响；不变量测试第 5 种情况并实际执行 |
| `57bea99` | 复核 P2-7：本地历史与 WorkBuddy 审计记录不列出 |
| `d4cb4af` | 复核 P2-5：废纸篓云端占位跳过、不让计划失败 |
| `92a73a7` | 复核 P2-4：按错误域识别权限错误 |
| `e0325a7` | 复核 P2-11：回执日志测试夹具不再写真实 `~/Library/Caches` |
| `f47c6d2` | 复核 P2-3：相对扫描时的废纸篓文件夹逐层不跟随链接删除 |
| `9ae17f3` | 复核 P2-1：重复应用需标识、版本、构建号都相同；显示版本；保留顺序 |
| `722c6a0` | 第 10 项：日志 7 天规则 |
| `1f19d99` | 复核 P2-2、P2-6：旧缓存不写永久删除回执；清空后回执不再声称可恢复 |
| `19662c3` | 复核 P2-3 补测：删到一半记为“永久删除未完成” |
| `82b1a0d` | 交接更新、`docs/cleanup-rules.md`、`rulesVersion` 升为 `2026.10.05.1` |
| `0f79b05` | 合并 `integration/2.0.0-beta`（批次 4b） |
| `1791a2d` | A2：清理后刷新结果、清空废纸篓独立确认、运行状态刷新与“正常退出并清理”、预检全部失败时逐项原因（代码与测试） |
| `455596a` 及 `c3870c8` | 交接 A2 一节、`docs/cleanup-rules.md` |
| `0073e39` | 合并 `integration/2.0.0-beta`（`724b06c`） |
| `15134b0` | 第三轮 P1-1：确认面板在全部未通过时也出现，视图与 store 用同一判断 |
| `194ac3a` | 第三轮 P2-1、P2-2、P2-6：需手动退出的应用点名；列出每个实例；复用正常退出与等待 |
| `9d1bf98` | 第三轮 P2-3：等待退出后只对同一扫描与计划继续 |
| `f524517` | 第三轮 P2-7：运行中的副本与命令行工具当前使用的 Xcode 都保留 |
| `19b1d45` | 第三轮 P2-4：读不全的日志行不预选（补测试） |
| 本文件所在提交 | 第三轮交接、`docs/cleanup-rules.md` 更正 |
