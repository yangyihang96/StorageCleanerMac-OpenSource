# r2-fa-followups：文件分析移到废纸篓 P2 后续

- 日期：2026-10-07（悉尼）。worktree：`~/Developer/sc-worktrees/r2-fa-followups`；分支：`task/r2-fa-followups`；基线：`e427787d442c0e129352a8bb5330eb01863880bf`。
- 依据：本 worktree 的 `RULES.md`、DECISIONS D46／D54（含补充）／D48、`handoffs/r2-file-analysis-trash.md`、`~/Developer/.sc-build/r2-file-analysis-trash-review/review.md` 开头第二轮“问题”的 P2-1～P2-8（第一轮）；本批复核的结论与问题清单（第二轮）。
- 经过：第一轮由 Codex 写成（`f54669b`～`1105c74`），主会话构建、跑定向测试并补修一处（`2cdafd4`）；复核结论“修后可合并”，列出 P1-1、P2-1～P2-4 和交接里的不符说法；第二轮由 Claude（Opus 5.5）修复（`eb807e6`～`3fe7e74`，见 §2），其间按主会话要求合并集成分支 `4fea34d`（测试卫生批 D48，`4927ff0`）；第三轮按主会话对第二轮未决项的裁定再改两处（`8ed1739`、`3a089ea`，见 §2.1）。
- 现状：三轮改动都已提交，最终验证见 §5。没有安装，没有碰 `/Applications`，没有启动已安装的应用，没有在真实文件上执行，没有 push，没有读取凭据；`Stores/ScanStore.swift` 未改。
- 复核材料：复核目录 `~/Developer/.sc-build/r2-fa-followups-review/` 只有日志、实验测试（`evidence/ReviewR2FAFExperimentTests.swift`）、反证脚本（`mutate.py`），没有书面清单（第三轮再次核对，仍没有）。§4 的“交接更正”**由实现者根据摘要整理**：依据主会话转来的复核摘要，并逐条对照源码和日志。

## 1. 第一轮改动（已按复核更正）

本节表格记录前三轮状态；`.app` 的最终规则和本轮尚未运行的验证见末尾 §8。第三次复核发现 FNDR／AAPL／BNDL 和缺可执行文件名的真应用仍可能被误判，前三轮没有达到“真应用不会变成可勾选文件夹”的完整保证。

| 项 | 现在的实现（含第二轮修正） | 测试 |
|---|---|---|
| P2-1 余项 | `~/Library/Reminders`、`~/Library/Shortcuts` 整块保护；凭据加 `.password-store`、`.terraform.d/credentials.tfrc.json`；`.terraform.d` 上层不能整个勾选 | `FileAnalysisTrashProtectedScopeTests.testSystemDataAndCredentialsAreKeptWholeWithEverythingInside` |
| P2-2 iCloud／卷判定 | 桌面、文稿分别询问，审阅只过滤依赖未完成判定的勾选；十秒超时只锁仍未回答的位置，迟到回答不接受，新分析不收旧结果。第二轮起：外接卷写“卷”，不再写 iCloud（§2 P2-3） | `FileAnalysisTrashRefinementTests` 6 项、`FileAnalysisTrashStoreTests.testItemsWaitWhileICloudIsBeingCheckedAndFollowTheAnswer` |
| P2-3 转移运行的应用 | 只读还原转移运行应用的原路径，运行路径和原路径都参与匹配。第二轮起：只有确在应用转移挂载下且还原不出原路径的应用才算“未知”，提示写出应用名（§2 P2-2） | `FileAnalysisTrashRunningApplicationTests` 8 项 |
| P2-4 名称与链接 | D54 名称按固定 locale 折叠大小写并做 NFC，比较保持路径分量边界；经由符号链接到达的 D54 位置加入规则。第二轮起：名单预先折叠（§2 P2-4），链接在主线程以外线性查找（§2 P1-1） | `FileAnalysisTrashFollowupPolicyTests` 的名称、链接两组 |
| P2-5 `.app` | 第二轮起：以 `.app` 结尾的包，只有 `Contents/Info.plist` 的 `CFBundlePackageType` 为 `APPL` 才算应用（§2 P2-1）；第三轮起缺这个键但可执行文件在的也算应用，行内分类跟着判定（§2.1） | `FileAnalysisTrashFollowupPolicyTests`、`FileAnalysisTrashStoreTests` 的 `.app` 各项 |
| P2-6 行内原因 | 七种短语，保护原因一行；“随所选文件夹移走”可两行；全文在悬停和审阅框。第二轮起：本批新增的原因也改成短语（§2 P2-3） | `FileAnalysisTrashProtectedScopeTests.testTheReasonsReadAsShortChinesePhrases` 等 |
| P2-7 详情 | 不再 `String(describing:)`；第二轮起所有错误（含协调器）只留错误域和错误码；第三轮起本应用和 Swift 运行时的类型写“应用内部错误（代码 N）”（§2.1） | `FileAnalysisTrashFollowupPresentationTests` 两项、`FileAnalysisTrashStoreTests.testAMoveThatCannotStartSaysWhyAndCancellingClearsIt` |
| P2-8 挂载点回执 | 持久化跳过原因 `CleanSkipReason.containsMountPoint`，“操作记录”显示“含挂载点” | `FileAnalysisTrashFollowupPresentationTests.testAMountPointAppearingAfterReviewIsRecordedSpecificallyAndOtherItemsMove`、`OperationRecordLabelTests.testMountPointSkipHasAChineseRecordLabelAndRoundTrips` |

## 2. 第二轮修复

每项先写测试，在修复前的代码上跑红，修复后跑绿，再逐一撤回关键实现（反证，跑完即还原）。反证工具和定义：`~/Developer/.sc-build/r2-fa-followups/round2/mutate.py`、`mutations.json`；每次的构建／测试日志在 `round2/logs/`（`b*`／`t*` 文件，名称带变异名）。

| 复核项 | 修复 | 测试 | 红 → 绿 → 反证 |
|---|---|---|---|
| P1-1 链接解析卡主线程、平方增长 | ①算法（`b564e2c`）：每个目录只列一次，建“折叠名 → 实际名”字典；容器的 `Data` 直接 lstat；不是链接的项目沿用上层已解析路径。②移出主线程（`cbaed20`）：分析结束时 `resetTrash` 只装“起始规则”（不读文件系统，排除项和挂载表除外），链接在分离任务里查找，按分析 generation 回到主线程套用；完成前其他规则不挡的项目都是“检查中”（`.checking(.protectedLocations)`），底栏“正在核对受保护的位置…”，点击提示稍候，审阅只取不等待的勾选；与 iCloud 共用十秒预算，超时则全部项目“保护范围未知”（`protectedLocationsUnknown`），迟到结果不接受（服务和 store 两道守卫）。`isRefined` 现在表示所有需要文件系统的判断都已完成。③解析器作为 `FileAnalysisTrashEnvironment.protectedLinkTargets` 注入；`TrashFixture` 默认以夹具自己的目录为家目录，并对解析器加 precondition，夹具外的家目录直接失败 | `FileAnalysisTrashCostTests.testTheLinkResolverReadsAThousandContainersWithinBudget`（夹具家目录里 1,000 个容器＋250＋250，单次 ≤ 200 ms）；`FileAnalysisTrashStoreTests.testProtectedLinksAreFoundOffTheMainThreadWhileItemsWait`、`testTrashFixturesUseTheirOwnHomeFolder`；`FileAnalysisTrashRefinementTests.testFindingTheLinksOutOfTimeBlocksEveryItemAndALateResultIsIgnored` | 红：旧解析器单次 1.82／2.27／1.71 s。绿：24–27 ms。反证：恢复逐容器重列重折叠 → 1.1–1.2 s，失败；子项按未解析的上层拼路径 → 链接容器的 Data、链接资源库里的系统数据漏掉，2 个测试失败；在 `resetTrash` 里同步解析（旧行为）→ 替换分析等 10 s、项目立即可选，6 处失败；夹具改回真实家目录且去掉守卫 → 4 处失败（读到真实资源库的链接目标）；超时不处理链接 → 超时测试等不到；原迟到结果反证结论撤回：原测试只等 gate 返回和 20 次 yield；第三次复核按同一变异重跑 3 次都通过，未等解析和主线程处理完成，不能证明它抓得住迟到结果。第 4 轮改用完成信号＋实际保护任务完成句柄，主会话须重新反证（§8） |
| P2-1 `.app` 普通文件夹 | `FileAnalysisApplicationBundleProbe` 只读 `Contents/Info.plist`、只看 `CFBundlePackageType`：`APPL` 才是应用。lstat＋`O_NOFOLLOW` 不跟链接，不下载；链接、无权限、仅云端、过大按应用处理（仍挡住），没有 Contents／Info.plist、不是属性表或其他包类型不算应用（第三轮补“缺类型但可执行文件在”也算应用，见 §2.1）。只探测行里看得到、规则本来会判成应用的包（不在别的包里，不是云端占位），与链接一起在主线程以外完成（`nonApplicationBundlePaths`）；结果出来前和不读文件系统的规则仍按应用处理。`TrashFixture` 的 `Tool.app` 改为真实 APPL 属性表（`90b5fad`） | `FileAnalysisTrashFollowupPolicyTests.testAFolderNamedLikeAnAppIsSelectableUnlessItsInfoPlistSaysAPPL`（扫描器真实给出的 `package`，替换原 `kind: "folder"` 的测试）、`testTheAppProbeReadsOnlyThePackageTypeAndStaysBlockedWhenItCannotRead`；`FileAnalysisTrashStoreTests.testAFolderNamedLikeAnAppBecomesCheckableOnceItsInfoPlistIsRead` | 红：四个非应用的 `.app` 文件夹全被挡，5 处失败。绿。反证：忽略探测结果 → 7 处失败；任何 Info.plist 都算应用 → 3；跟随链接的 Info.plist（撤 lstat 判断和 `O_NOFOLLOW`）→ 1；读不了算“不是应用” → 1 |
| P2-2 “无法确认运行中的应用”太宽 | `originalURL(for:)` 先问 Security；Security 答不出时（包已不存在、符号缺失），只有路径在 `…/AppTranslocation/<id>/d/<App>.app` 下才按转移处理。其他应用（包括包已删除或移走、仍在运行的）用自己的路径匹配。`runningApplicationState()` 对注入的查询同样处理，并按名字记下未知的应用（`unknownApplicationNames`）；规则带上名字，行状态 `.blocked(block, applications:)`、点击提示、审阅框、移动结果都写出“无法确认“Demo”的原始位置（由系统转移运行），暂不能整个勾选文件夹；请退出“Demo”后重试。”（`e32e1f4`）。私有接口白名单的理由同步更新（`4c54f5c`） | `FileAnalysisTrashRunningApplicationTests.testARunningAppWhoseBundleIsGoneIsMatchedByItsOwnPath`（真实 Security 查询，路径不存在，只读）、`testTheRealLookupLeavesOnlyAnUnrestorableTranslocatedAppUnknown`、`testTheReasonNamesTheAppWhoseOriginalLocationIsUnknown`，原失败关闭测试补应用名 | 红：包已不存在的运行应用让状态未知，3 处失败。绿。反证：任何查询失败都算未知 → 1；Security 答不出就当转移 → 1；提示不写名字 → 5；行状态不带名字 → 3 |
| P2-3 文案 | 外接卷检查“卷是否只读”：检查中写“正在确认卷状态…”，点击“正在确认“X”所在的卷是否只读，请稍候再勾选。”，悬停“检查中：正在确认这个卷是否只读，确认后才能勾选。”；超时用新原因 `volumeStateUnknown`：行内“卷状态未知”，悬停与审阅“无法确认卷状态，暂不可选：确认这个卷是否只读已超时，请重新分析后再试。”。iCloud 保留“正在确认 iCloud 状态…”“无法确认云端状态，暂不可选”，点击和悬停不再提卷。本批新增原因改成一行短语：云端状态未知、卷状态未知、运行应用位置未知、保护范围未知（≤ 8 字、无逗号、行数 1），整句在悬停。协调器出错时“详情”只留错误域与错误码（`cd96a9a`；当时显示 `StorageCleanerMac.HeavyWorkCoordinator.Error:1`，第三轮改为“应用内部错误（代码 1）”，见 §2.1） | `FileAnalysisTrashFollowupPresentationTests.testMoveFailureDetailsForCoordinatorErrorsKeepOnlyTheDomainAndCode`（替换原中文说明测试）、`testTheVolumeIsNotCalledICloudAndTheNewReasonsAreShortPhrases`；`FileAnalysisTrashRefinementTests.testAnExternalVolumeSaysItIsCheckingTheVolumeNotICloud`；两个超时测试改为期望短语和 `volumeStateUnknown` | 红：15 处失败。绿。反证：卷的底栏写回 iCloud → 2；卷超时按云端 → 2；行内恢复长句 → 4；详情重复提示 → 4 |
| P2-4 每行重新折叠名单 | 名单预先折叠为静态常量，家目录、数据目录在建规则时折叠，链接目标在发现时折叠；`block()` 只折叠一次当前路径，折叠用的 Locale 也只建一次（`eb807e6`） | `FileAnalysisTrashCostTests.testARowsRuleCheckFoldsOnlyItsOwnPath`（每次 ≤ 30 µs，Debug） | 红：45／95／148／150 µs（首稿 60 µs 时文件样本 45 µs 能过，提交前收紧到 30 µs）。绿：5–10 µs。反证：每次重新折叠资源库名单 → 两个资源库样本 38–39 µs，失败 |
| D48 合并后 | 本批新增的两个测试辅助改用 `TestPreferenceDomain.make(for: self)`；`TrashLanguageScope` 仍是 `FileAnalysisTrashTests.swift` 里白名单登记的 2 处内存覆盖（`3b6b607`） | `TestPreferenceHygieneTests` 6 项 | 合并后先跑守卫，再跑定向测试 |

提交（第二轮，按时间）：`eb807e6` P2-4；`b564e2c` P1-1 算法；`cbaed20` P1-1 移出主线程与夹具家目录；`90b5fad` P2-1；`e32e1f4` P2-2；`4927ff0` 合并集成分支 `4fea34d`；`3b6b607` D48 测试偏好；`cd96a9a` P2-3；`4c54f5c` 私有接口理由；`90e952f` Debug 截图模式；`4142cb5` 本机只读测量（显式开关、默认跳过）；`3fe7e74` 第二轮交接。第三轮：`8ed1739` 详情不出现内部类型名；`3a089ea` 老应用判定与行内分类；最后一次提交为本交接更新。

## 2.1 第三轮（主会话裁定第二轮未决项）

| 裁定 | 实现 | 测试 | 红 → 绿 → 反证 |
|---|---|---|---|
| 第 1 项：“详情”不出现内部类型名（RULES §5） | 只改界面：错误链上每一层，错误域是本应用 Swift 类型（前缀 `StorageCleanerMac.`、`FanControlShared.`、`FileOperationShared.`、`MSeriesKernels.`、两个助手）或 Swift 运行时类型（`Swift.`，如 `Swift.CancellationError`）时写“应用内部错误（代码 N）”／“Internal error (code N)”；系统错误域保持“域:代码”，如 `NSCocoaErrorDomain:513`、`NSPOSIXErrorDomain:1`，包着内部错误时为 `NSCocoaErrorDomain:513 > 应用内部错误（代码 1）`。协调器出错时为“错误域与错误码：应用内部错误（代码 1）”。回执里的 `UninstallErrorEvidence.codes` 不变（`8ed1739`） | `FileAnalysisTrashFollowupPresentationTests.testMoveFailureDetailsNameSystemDomainsButNotThisAppsOwnTypes`（替换第二轮的“域与码”测试，保留不重复提示、不含枚举名与“(”“重试”的检查，加英文与 `CancellationError`） | 红（`3fe7e74`）：9 处失败。绿；本提交单独构建，相关 11 个测试通过。反证：本应用模块不算内部 → 6；所有域都算内部 → 4；Swift 运行时不算内部 → 3 |
| 第 3 项：当时只补缺 `CFBundlePackageType` 且明确写可执行文件名的老应用；覆盖不完整（第 4 轮更正见 §8） | 探测器：`APPL` 是应用；没有这个键时，`CFBundleExecutable` 是不含路径分隔的名字、且 `Contents/MacOS/<该名字>` 是普通文件，也是应用；其他（没有 Info.plist、类型是别的值、没写或没有可执行文件、名字带路径）按普通文件夹。`MacOS` 或可执行文件是链接时不跟随，按应用处理（仍挡住）。行内分类跟着判定走：文件分析的索引遍历对以 `.app` 结尾的包调用同一探测器（云端占位不读），不是应用的按内容分类，例如 `~/Library/HTTPStorages/com.example.app` 行内为“数据 · 1 项”，色块与上层分类统计同步；它仍是包，地图里不能点开。勾选它时 store 标 `presentsAsFolder`，审阅框显示“文件夹 · 含 N 项”和文件夹图标（`3a089ea`） | `FileAnalysisTrashFollowupPolicyTests.testAnOlderAppWithoutAPackageTypeIsStillAnAppWhenItsExecutableIsThere`（三种裁定情形＋路径名、可执行处是文件夹、两种链接）；`testAFolderNamedLikeAnAppIsSelectableUnlessItsInfoPlistSaysAPPL` 加 `Legacy.app` 与各行分类；`FileAnalysisTrashStoreTests.testAFolderNamedLikeAnAppBecomesCheckableOnceItsInfoPlistIsRead` 加行内分类、审阅文字与图标 | 红（`3fe7e74`）：11 处失败（第二轮的规则让 `Legacy.app` 可勾选、各 `.app` 行都写“应用与安装包”）。绿。反证：去掉可执行文件规则 → 5；不检查可执行文件是否存在 → 2；名字带路径也接受 → 1；跟随链接（`stat` 代替 `lstat`）→ 2；扫描器分类不跟判定 → 5；审阅不跟判定 → 2 |
| 第 2 项 | 不在本批，主会话记入 N26 | — | — |
| 第 4 项 | 接受现状，写入 §7 | — | — |

反证均为单项撤回、确认构建成功后再测，跑完还原；第三轮日志在 `~/Developer/.sc-build/r2-fa-followups/round3/logs/`（`b*`／`t*` 带变异名，`R3-*`），定义在 `round2/mutations.json`。其中“跟随链接”首次写成 `Darwin.stat(...)` 编译失败（那次的测试结果作废），改用 `stat(...)` 后重跑，见 `b11-mut-R3-links-followed.log`。

## 3. 性能（改前 → 改后）

| 项 | 改前 | 改后 | 说明 |
|---|---|---|---|
| 链接解析，合成家目录（1,000 容器＋250 群组容器＋250 应用支持，Debug，单次） | 复核 2.8 s；本轮红 1.82／2.27／1.71 s | 24–27 ms | `FileAnalysisTrashCostTests`；预算 200 ms |
| 链接解析，本机家目录（只读、显式开关） | 复核 1,102 容器：Debug 4.6–4.9 s，`-O` 1.5–2.6 s | 1,102 容器、229 群组容器、228 应用支持、1 个链接目标：109 ms（冷）、26 ms、26 ms | `testTheLinkResolverOnThisMachinesHomeWhenAskedTo`，默认跳过 |
| 主线程 | 分析结束同步解析，界面卡住 | 不在主线程：解析器被闸门扣住时替换分析立即返回，解析器 0 次在主线程调用 | `testProtectedLinksAreFoundOffTheMainThreadWhileItemsWait` |
| 26 个读真实 `~/Library` 的夹具测试 | 每个 2.6–5.2 s（复核 `t-final.log`） | 每个 0.011–0.093 s（`cbaed20`，`round2/logs/t09-p11b.log`）；最终运行 0.013–0.088 s（`final-targeted.log`） | 按测试名逐个对照 |
| 行规则 `block()`（Debug，单次） | 复核 83–291 µs；本轮红 45–150 µs | 5–10 µs | `FileAnalysisTrashCostTests` |
| 定向测试整组 | 复核 111 个 78.8 s；主会话 103 个 159 s | 110 个（2 个按开关跳过）6.6 s | 范围不完全相同（见 §5） |

## 4. 交接更正（复核所列 1–5，逐条）

复核员目录（`~/Developer/.sc-build/r2-fa-followups-review/`）没有书面清单，以下五条**由实现者根据摘要整理**，每条都对照了源码或日志。

1. **原说法**：“`.app` 扩展名必须同时是索引的 `kind == "package"` 才作为应用；普通 folder 或 file 不误挡。复用扫描器已有的包类型”。**事实**：扫描器对所有以 `.app` 结尾的目录都给 `isPackage == true`（`DiskScanner.swift` 1310、1981 行），普通文件夹照样被判成应用；原测试传入的 `kind: "folder"` 扫描器永远不会给出。复核实验 X1：`Library/HTTPStorages/com.example.app` 被扫描成 `package`、挡为“应用”。**现在**：按 `Contents/Info.plist` 判断：`CFBundlePackageType` 为 `APPL`，或缺这个键但可执行文件在（§2 P2-1、§2.1）。
2. **原说法**：“分析建立 policy 时只读 D54 位置及父级链接元数据”；剩余限制“链接解析只读目录名和元数据；未做性能测量”。**事实**：解析器列出 `~/Library`、`Containers`、`Group Containers`、`Application Support` 的全部项目，并对每个容器重新列目录、重新折叠同一目录的全部名字，耗时随容器数平方增长；调用在 `resetTrash`（`@MainActor`）里同步执行，每次分析结束都卡住界面（本机 1,102 个容器：Debug 4.6–4.9 s，`-O` 1.5–2.6 s）。**现在**：线性算法、主线程以外、完成前“检查中”（§2 P1-1）。
3. **原说法**：“数据、链接、回执与模拟废纸篓都在已有 `TrashFixture` 隔离目录”。**事实**：没有写真实目录，但 `TrashFixture.environment()` 默认家目录是真实家目录，26 个测试经解析器读取真实 `~/Library`，每个 2.6–3.1 s（分析两次的一个 5.2 s）。**现在**：夹具默认以自己的目录为家目录，解析器拿到夹具外的家目录直接失败（§2 P1-1）。
4. **原说法**：“无法还原时记录未知……所有整块文件夹选择暂时阻止”，并暗示只在“被转移的应用”还原失败时发生。**事实**：`SecTranslocateIsTranslocatedURL` 对不存在的路径直接失败，解析器随即返回 nil，所以包已被删除或移走、仍在运行的普通应用也让所有文件夹不能整块勾选（复核实验 X6：缺失包 → 未知）；提示固定写“请退出被转移的应用”，不说是哪个。**现在**：只在确属转移挂载且还原失败时未知，提示写出应用名（§2 P2-2）。
5. **原说法**：“底栏有检查中项目时显示‘正在确认 iCloud 状态…’”“超时只把仍待判定的位置标成 `cloudStateUnknown`”，并把外接卷超时也归在这套文案下（`testAnExternalVolumeTimeoutStaysUnavailable`）。**事实**：外接卷检查的是“卷是否只读”，界面却写 iCloud 状态，超时原因也写“无法确认云端状态”。**现在**：外接卷与 iCloud 分开（§2 P2-3）。

其他过期或不准确之处，本次一并删改：

- 原“状态：……构建、测试、反证、私有 API 检查、安装、运行应用、提交均 NOT RUN”、§2“文件与分组”（prepared 补丁与 `git apply --cached` 说明）、§3“主会话补跑：绿、红、反证”的待执行方案、§4 第 1、6 条（“当前没有实际 PASS 证据”“commit 都没有发生”）均已过期，删除；实际验证见 §5，提交见 §2。
- 原“主会话验证”表把 `CleanupReportSkipPresentationTests` 列进第一次定向测试，但当时本分支没有这个类（它随 r2-u1-followups 进入集成分支，本批 `4927ff0` 合并后才有），那次的 103 个测试不含它（日志 `~/Developer/.sc-build/r2-fa-followups/logs/main-targeted-2.log`）。
- 原 P2-7 写“协调器错误用中文说明”：那段中文与上方提示重复，复核要求“详情”只留错误域和错误码，已改（§2 P2-3）。
- 原 JEV 一段记录的是第一轮 Codex 会话的工具情况，与本轮无关，删除；本轮情况见 §7 第 10 条。

## 5. 验证（实际运行）

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`、`LC_ALL=en_US.UTF-8`；Debug scratch `~/Developer/.sc-build/r2-fa-followups/main-debug`，严格并发 scratch `~/Developer/.sc-build/r2-fa-followups/strict`；构建都带 `--skip-update --disable-automatic-resolution`；脚本 `round2/build.sh`、`round2/test.sh`（test.sh 记录运行前后 `~/Library/Preferences`、`~/Library/Caches` 第一层里比标记新的非 `com.apple.*` 项和 `~/.storage-cleaner-*` 夹具数）。

| 步骤 | 命令 | exit | 结果 | 日志（`~/Developer/.sc-build/r2-fa-followups/round2/logs/`） |
|---|---|---|---|---|
| Debug 构建（含测试） | `swift build --package-path <worktree> --scratch-path …/main-debug --jobs 4 --build-tests --skip-update --disable-automatic-resolution` | 0 | HEAD `4142cb5` | `final-debug-build.log` |
| 守卫 | `swift test … --skip-build --skip-update --disable-automatic-resolution --filter TestPreferenceHygieneTests` | 0 | 6 个，0 失败 | `final-guard.log` |
| 定向测试 | 同上，`--filter 'FileAnalysisTrash\|OperationRecordLabelTests\|StorageMap\|RecordedTrashRecoveryTests\|RecordedCleanupRecoveryTests\|OperationResultPresentationTests'` | 0 | 110 个，2 个按开关跳过（`FileAnalysisTrashCostTests.testTheLinkResolverOnThisMachinesHomeWhenAskedTo`、`StorageMapAnalysisPerformanceTests.testSyntheticTreeThroughputAndMemory`），0 失败，6.6 s。按类：Cost 3、FollowupPolicy 5、FollowupPresentation 4、ProtectedScope 7、Refinement 6、RunningApplication 8、Store 15、FileAnalysisTrashTests 17、OperationRecordLabel 4、OperationResultPresentation 4、RecordedCleanupRecovery 6、RecordedTrashRecovery 4、StorageMapAnalysisEquivalence 10、StorageMapAnalysisPerformance 1、StorageMapIndexEditing 9，另有方法名含 StorageMap 的 StorageTreemapLayout 6、CompetitiveParityContract 1。运行前后 `~/Library/Preferences`、`~/Library/Caches` 第一层没有新的非 Apple 项，`~/.storage-cleaner-*` 夹具 0 | `final-targeted.log` |
| 本机只读测量 | `STORAGE_CLEANER_R2FAF_REAL_HOME=1 swift test … --filter FileAnalysisTrashCostTests/testTheLinkResolverOnThisMachinesHomeWhenAskedTo` | 0 | 1 个，0 失败（数字见 §3） | `t28-optin-real-home.log` |
| 严格并发 | `swift build … --scratch-path …/strict --build-tests -Xswiftc -strict-concurrency=complete` | 0／0 | `cd96a9a` 全量 234 s，只有一条与本批无关的测试警告（`BrowserPrivacyRecoveryTests.swift:467`）；`4142cb5` 增量 27 s，无警告 | `strict-build.log`、`final-strict-build.log` |
| 私有接口 | `python3 script/check_private_api.py` | 0 | 7 处白名单用法 | `final-private-api.log` |
| 空白 | `git diff --check`；`git diff --check 4fea34d HEAD`；`git diff --check 2cdafd4 e32e1f4` | 0／0／0 | — | — |
| 截图用包 | 改后：`script/build_and_run.sh --bundle-only`（Debug，`STORAGE_CLEANER_SKIP_TESTS=1`，`SWIFT_BUILD_DIR=/tmp/storage-cleaner-r2faf-round2-after`，`DIST_DIR=round2/bundle-after`）；改前：`round2/before-src`（`git archive 2cdafd4` 导出，加同一截图模式、去掉改后才有的一步）`swift build --product StorageCleanerMac`，换入改后包的副本。两包都改为 `com.local.StorageCleanerMac.integration` 并临时签名 | 0／0 | 150 s／99 s | `bundle-after.log`、`before-build.log` |
| 截图 | `round2/capture-followups.sh` | 0 | 浅、深色各一次：改前 10 张、改后 11 张；四次运行的夹具“废纸篓”都为空（没有移动任何东西），夹具与集成数据根运行后删除 | `capture-followups.log` |

每项的红、反证运行日志：`b01`～`b27`／`t01`～`t28`（构建／测试，文件名带项目或变异名），`mutations.json` 记录每个变异的原文与替换。

第三轮（HEAD `3a089ea`；日志在 `~/Developer/.sc-build/r2-fa-followups/round3/logs/`）：

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| Debug 构建（含测试） | 同上（`main-debug`） | 0 | — | `final-debug-build.log` |
| 守卫 | `--filter TestPreferenceHygieneTests` | 0 | 6 个，0 失败 | `final-guard.log` |
| 定向测试 | 同上的定向过滤 | 0 | 111 个，2 个按开关跳过（同上两项），0 失败，5.7 s；运行前后偏好、缓存第一层没有新的非 Apple 项，夹具 0 | `final-targeted.log` |
| 只含第 1 项的中间提交 | 暂存第 1 项、其余改动临时收起后构建，跑守卫＋详情测试＋store 的 move-did-not-start 测试 | 0／0 | 11 个，0 失败 | `b20-item1-only.log`、`t20-item1-only.log` |
| 严格并发 | `swift build … --build-tests -Xswiftc -strict-concurrency=complete`（`3a089ea`） | 0 | 43 s，无警告 | `strict-build.log` |
| 私有接口 | `python3 script/check_private_api.py` | 0 | 7 处白名单用法 | `private-api.log` |
| 空白 | `git diff --check 3fe7e74 HEAD` | 0 | — | — |
| 截图用包 | `script/build_and_run.sh --bundle-only`（Debug，`STORAGE_CLEANER_SKIP_TESTS=1`），改前用第二轮的截图包 | 0 | 42 s | `bundle-after.log` |
| 截图 | `round3/capture-followups.sh` | 0 | 见 §6 | `capture-followups.log`、`capture-followups-after-dark.log` |

## 6. 截图（改前／改后）

并排图（左改前 `2cdafd4`，右改后）：`~/Developer/.sc-build/r2-fa-followups/round2/shots/side-by-side/{light,dark}-<名称>.png`；单张：`shots/{before,after}-{light,dark}/`。主窗口 1280 × 763，带 `n` 的为 820 × 560 窄窗；语言、外观、显示方式只用启动参数。

| 名称 | 内容 |
|---|---|
| `fc-0-links-checking`（只有改后） | P1-1：链接查找期间，其他规则不挡的行显示“检查中”，底栏“正在核对受保护的位置…”，点击“正在核对受保护的位置，请稍候再勾选“Old Projects”。”。改前没有这个状态：解析在主线程同步完成，期间界面卡住 |
| `fc-1-library-httpstorages` | P2-1：`Library/HTTPStorages/com.example.app`（普通文件夹）改前锁定“应用”，改后可勾选 |
| `fc-2-downloads-bundles` | P2-1：`Plugin.app`（BNDL）、`Untyped.app`（无类型）改后可勾选，`Real.app`（APPL）仍是“应用” |
| `fc-3-icloud-timeout`、`fc-3n-…-narrow` | P2-3：iCloud 十秒未答，桌面项目改前“无法确认云端状态，暂不可选”，改后“云端状态未知” |
| `fc-4-running-app-unknown`、`fc-4n-…-narrow` | P2-2／P2-3：转移运行且还原失败（注入），文件夹改前“无法确认运行中的应用”＋“请退出被转移的应用后重试”，改后“运行应用位置未知”＋“请退出“Demo”后重试” |
| `fc-5-gone-bundle` | P2-2：包已删除、仍在运行的应用（真实 Security 查询）：改前所有文件夹“无法确认运行中的应用”，改后只有 `Build`“含正在运行的应用”，其他文件夹可勾选 |
| `fc-6-volume-checking` | P2-3：外接卷检查中，底栏改前“正在确认 iCloud 状态…”，改后“正在确认卷状态…”；点击提示改前提 iCloud，改后“正在确认“Movies”所在的卷是否只读，请稍候再勾选。” |
| `fc-7-volume-timeout`、`fc-7n-…-narrow` | P2-3：外接卷十秒未答，改前“无法确认云端状态，暂不可选”，改后“卷状态未知” |

截图限制：悬停提示无法离屏截取，“详情”默认折叠、未截展开态（两者由单元测试覆盖）；改前包是 `2cdafd4`，改后包含集成分支合并，按钮外观等差异来自合并而非本批。

第三轮只补行内分类有变化的两张（左第二轮 `3fe7e74`，右第三轮 `3a089ea`）：`~/Developer/.sc-build/r2-fa-followups/round3/shots/side-by-side/{light,dark}-fc-1-library-httpstorages.png`、`…-fc-2-downloads-bundles.png`。改前 `com.example.app` 行为“应用与安装包 · 1 项”，改后“数据 · 1 项”（数据图标）；改前 `Plugin.app`（BNDL）、`Untyped.app`（无类型、无可执行文件）为“应用与安装包”，改后“其他 · 1 项”；改前 `Legacy.app`（无类型、有可执行文件）可以勾选，改后锁定为“应用”。“详情”的新写法仍只由单元测试覆盖（折叠态截不到）。

第三轮截图过程：四次运行中只有浅色改后跑完全部 11 步；其余在本轮不需要的后面几步停住（深色改后第一次在启动后 2.5 分钟才出第一张，加启动参数 `-NSAppSleepDisabled YES` 重跑后得到前 8 张；改前包与第二轮完全相同、当时全部跑完，这次两次都在 `fc-6` 后停住），同期另一会话也在运行同一隔离身份。所需的 `fc-1`、`fc-2` 四种组合都已拍到；没有深究原因。四次运行的夹具“废纸篓”都为空，夹具和集成数据根运行后删除。

## 7. 剩余限制

1. 早两轮的 §4 更正依据转述摘要；第 3 次复核已有书面清单 `~/Developer/.sc-build/r2-fa-followups/round4/review-r3.md`，第 4 轮逐条按它接手。
2. 还有测试会读真实资源库：`IndependentFeatureWorkspaceStoreTests`（2 处）和 `StorageTreemapLayoutTests`（1 处）用默认 `.live` 环境建 `LargeFilesStore` 并装入分析，后台会用真实家目录跑解析器（只读，现已不在主线程）。不在本批，主会话已记入 N26。
3. 主会话已接受现状：链接查找与 iCloud／卷共用十秒预算，超时后所有项目“保护范围未知”，迟到结果不收，需重新分析；卡住的系统调用（如网络卷上的 lstat）不会被中止，只是不再等。超时类“未知”（保护范围、云端、卷）排在项目自身规则前，与原 iCloud 超时一致，所以超时后应用行显示“保护范围未知”而不是“应用”。
4. 以下为第三轮的历史限制，第 4 轮已改可执行文件规则并跳过已判应用的外层包内的探测，见 §8。第三轮 `.app` 判定：没有 `CFBundlePackageType`、可执行文件也不在的 `.app` 按普通文件夹处理、可以勾选，这是裁定的规则；在别的包里或云端占位里的 `.app` 不探测，仍算应用（行里也看不到）。行内分类与移到废纸篓的规则各自调用探测器（分析遍历时和分析结束后），两次之间文件被改动时可能不一致；可否移走以规则那次为准，移动前还会再核对整个文件夹。
5. 第三轮改了 `DiskScanner` 的索引遍历：每次文件分析遍历到以 `.app` 结尾的包（包括别的包里的）都会读一次它的 Info.plist（最大 1 MiB，云端占位、仅云端的文件不读），非应用的 `.app` 的内容分类改为按内容统计，影响行、色块、图例和上层的分类统计。只跑了定向测试（其中 `StorageMapAnalysisEquivalenceTests` 各遍历模式结果仍一致），没有跑全量；测试源码里没有其他断言依赖“无效 Info.plist 的 `.app` 被分类为应用”（只查到 `StorageMapContentCategory.classify` 的分类表测试，该函数未改）。第三次复核已实测：5,000 个 `.app` 夹具整次分析 CPU 约增加 3–4%，探测器热态 28–31 µs／个、冷态约 113 µs／个，未达 P1 阈值；证据为 `~/Developer/.sc-build/r2-fa-followups-review/logs/r3-*.log`、`evidence/ReviewR3PerfTests.swift`。这是第 3 轮测量，第 4 轮未重新测量。
6. 转移判断用路径分量 `AppTranslocation` 识别挂载；真实的 App Translocation 没有端到端验证（没有启动任何应用）。Security 的只读查询只在不存在的路径和 `/System/Applications/Calculator.app` 上实测。
7. “详情”的内部错误判定按错误域前缀：本应用各模块和 `Swift.`。把 Swift 运行时类型（如 `Swift.CancellationError`）也写成“应用内部错误”是我对裁定“界面不出现内部类型名”的延伸理解，请主会话确认。其他第三方错误域（如 Sparkle 的）仍显示“域:代码”。
8. 截图运行时，应用自身会写隔离身份的偏好域（窗口位置、Sparkle 记录等；同时段另一会话也在运行该身份）；语言、外观、显示方式只经启动参数，域中没有这三项。集成数据根按应用要求放在 `~/Library/Caches/StorageCleanerIntegration-claude-r2faf*`，每次运行后删除。
9. 按 RULES 第 3 条（用完即删）已删除本批的临时构建与截图用 `.app` 副本：`/tmp/storage-cleaner-r2faf-round2-after`、`round2/before-debug`、`round2/before-src`、`round2/bundle-after`、`round2/capture`、`round3/bundle-after`、`round3/capture`、严格并发 scratch `strict`，约 4.6 GB；保留日志、截图、脚本、`capture-hook.patch`、`mutations.json` 和正在用的 `main-debug`。第一轮 Codex 留下的 `prepared`、`stages` 等不是本会话所建，未动。
10. 没有运行：全量 Debug／Release、小窗性能、整套源码守卫（只跑了 `TestPreferenceHygieneTests`）、安装、实机；按要求只跑定向测试。
11. JEV（provider typesafe，model jev-latest，`jev_review`）：第二轮只看了改动摘要（完整 diff 超过 50 KB 上限），**escalate**，safe_to_apply 0.39，composite 0.777（correctness 1.81／置信 0.71，spec match 1.95／0.93，test gap 0.40／0.40，blast radius 1.97／0.95）。第三轮看了完整源码 diff：**escalate**，safe_to_apply 0.53，composite 0.790（correctness 1.75／0.62，spec match 1.91／0.88，test gap 0.47／0.28，blast radius 1.49／0.27）。两次都是需人工复核的信号，不是批准，不替代主会话复核。


## 8. 第 4 轮：增量复核修复（待主会话验证）

- 日期：2026-10-07（悉尼）；基线 `80f37e34d1bfc1ed5f3be6f873161e6fe7343d93`；分支 `task/r2-fa-followups`。开始时工作区和暂存区均干净。
- 先读第 3 次复核报告 `~/Developer/.sc-build/r2-fa-followups/round4/review-r3.md`，以及本 worktree 的 RULES、BOARD 的 R7、DECISIONS D5／D46／D48／D54（含补充）／D55。此 worktree 的 DECISIONS 尚无 D60，另只读核对维护源 `~/Developer/StorageCleanerMac/docs/2.0.0/collab/DECISIONS.md` 的 D60：Codex 沙箱只写代码、测试和 prepared，主会话编译、测试、反证、提交；未同步或改动该决定文件。
- 本节全部红／绿／反证均为**待执行方案**。构建、严格并发、XCTest、私有 API 守卫、截图、安装、启动、移动、提交均 **NOT RUN**；执行测试数 0。此前 §5 的 PASS 不适用于本轮。
- 产物：`~/Developer/.sc-build/r2-fa-followups/round4/prepared/`，含四组补丁、提交说明、all.patch、manifest.json、commit-prepared.py、static-checks.json；附主会话用的红基线准备脚本、反证脚本与 mutations.json。所有提交说明按要求以两行署名结尾。

### 8.1 修复、文件和分组

| 组 | 文件 | 修改与理由 |
|---|---|---|
| `01-app-safety` | `Features/LargeFiles/Models/FileAnalysisTrashModels.swift`；`Services/FileAnalysisApplicationBundleProbe.swift`；`Services/FileAnalysisTrashService.swift`（均在 `Sources/StorageCleanerMac/` 下的相应目录）；`FileAnalysisTrashFollowupPolicyTests.swift`、`FileAnalysisTrashRunningApplicationTests.swift`、`FileAnalysisTrashTests.swift` | P1-1：运行路径自身在 `nonApplicationBundlePaths` 中也返回 `.applicationBundle`；上层仍为 `.containsRunningApplication`。P2-1：不看包类型，按 CFBundle 名字规则核对普通可执行文件；未写／空名字、缺 plist、可读但解析失败时用去掉 `.app` 的包名。支持包内子路径，先做词法边界核对，再从已打开的包根通过 `fstatat(AT_SYMLINK_NOFOLLOW)`／`openat(O_NOFOLLOW)` 逐级走；不访问包外路径。无可执行文件仍为普通文件夹，行按内容分类。初始 FIFO 不打开；检查后被换成 FIFO 用 `O_NONBLOCK` 和打开后的 `fstat` 类型、文件身份、占位与大小核对保守挡住。测试夹具根改临时目录并解析系统路径别名；Tool 的普通文件放到 `Contents/MacOS/Tool`。实际 Security 查询只用临时 Tool 和临时目录内不存在的转移路径，替换系统 Calculator 读取 |
| `02-refinement-and-phrases` | `Features/LargeFiles/Stores/LargeFilesStore.swift`；`FileAnalysisTrashRefinementTests.swift`；`FileAnalysisTrashFollowupPresentationTests.swift` | P2-2：store 暴露只读的实际保护任务句柄，沿用现有 ForTesting 入口方式；测试先等注入解析闭包调用真实解析器完成后发出的信号，再 `await protectionTask.value`，因此确认主 actor 已处理或拒收。生产两道守卫均保留。其他：`volumeStateUnknown` 加入同一个短语循环，检查 ≤8 字、无逗号、一行、悬停全文，另加“卷状态未知”的精确断言 |
| `03-traversal` | `Services/DiskScanner.swift`；新增 `FileAnalysisApplicationBundleTraversalTests.swift` | P2-3：外层应用整体汇总后，子目录继承“在应用包内”；状态通过 StorageMapJob 传给并行 walker，嵌套 `.app` 不再调用 plist 探测器。继续统计整个外层包的字节、项目与分类。普通 `.app` 数据目录没有该状态，内部的应用仍探测。options 注入共用探测器，测试记录实际调用路径，比较 1／4／8 线程模式的索引、根快照和计数 |
| `04-docs` | 本交接 | 修正三处复核指出的不符说法，追加本轮实现、旧断言改写、截图口径和待主会话执行的验证 |

`ScanStore.swift`、私有 API 白名单、阈值及其他 worktree 均未修改。没有安装、启动应用、清理真实文件或读取凭据。链接仍不跟随并保守挡为应用；可执行处是目录仍为文件夹；plist 无权限、仅云端或超过 1 MiB 的保守分支保留。仅云端边界未制造真实 File Provider 占位或操作系统文件：主会话可根据现有复核证据和静态分支检查复核；本轮没有添加必须读系统目录的测试。

### 8.2 逐条列出改写的旧断言与夹具

依据为本轮主会话对 P2-1 的明确裁定（安全优先，按包内可执行文件，不看 CFBundlePackageType）：

1. 扫描／policy 测试的 `Downloads/Plugin.app`：旧夹具只有 BNDL plist，无可执行文件，断言可选；改为 BNDL＋普通 `MacOS/Plugin`，断言 `.applicationBundle`。无可执行文件的 BNDL 夹具仍在探测边界测试中断言 false，未移除该边界。
2. 同一 Plugin 的行分类：从 `XCTAssertNotEqual(..., .application)` 所在循环移到 `XCTAssertEqual(..., .application)` 所在循环。Untyped／Empty 仍断言不是 application。审阅新增 Plugin blocked 和 ready 仅包含数据目录的断言。
3. 名字规则测试的 `Unnamed.app`：有 `MacOS/Unnamed` 而 plist 无可执行文件名，false → true（按包名后备）。
4. 名字规则测试的 `Plugin.app`：BNDL＋普通可执行文件，false → true（包类型不决定）。
5. 名字规则测试的 `Escape.app`：名字 `../MacOS/Escape` 实际仍在包内，false → true（不再拒绝所有路径分隔符）。另新增 `bin/Tool` 为 true、`../../../outside`／绝对路径／NUL 名字为 false，包外的目标文件确实存在于临时夹具中，不能靠“文件不存在”通过边界断言。
6. `Real.app`、边界测试的 `App.app` 和共享 `Tool.app`：原断言 `.applicationBundle`／true **保持**；夹具补普通可执行文件（Tool 的原文件从 Contents 下调整到 MacOS 下）。新增“只有 APPL、没有可执行文件”明确断言 false，防止以包类型代替文件。
7. `testTheRealLookupLeavesOnlyAnUnrestorableTranslocatedAppUnknown`：原“系统 Calculator 的原路径等于自身”改为“临时 Tool 的原路径等于自身”，期望语义不变；不存在的转移 Ghost 仍须返回 nil，形状相似的非转移路径仍须 false。更换输入是本轮临时目录约束所需，不削弱原位置保护。

三个测试方法仅更名、保留并扩展原断言：

- `testAFolderNamedLikeAnAppIsSelectableUnlessItsInfoPlistSaysAPPL` → `testAFolderNamedLikeAnAppIsSelectableUnlessItHasAnExecutable`。
- `testAnOlderAppWithoutAPackageTypeIsStillAnAppWhenItsExecutableIsThere` → `testTheAppProbeUsesCFBundleExecutableNamesWithoutRequiringAPPL`。
- `testTheAppProbeReadsOnlyThePackageTypeAndStaysBlockedWhenItCannotRead` → `testTheAppProbeStaysBlockedWhenItCannotRead`。

新方法有三项：运行中四种包写法、stat/open 间换 FIFO、单／并行遍历跳过嵌套包。新增断言还覆盖解析失败／缺 plist／空名字的包名后备、目录可执行处、各级链接、过大 plist；没有降低性能预算或跳过既有测试。

### 8.3 主会话构建和定向绿测试

下面命令仅供沙箱外主会话执行；本轮没有执行。不要打开 `STORAGE_CLEANER_R2FAF_REAL_HOME`；既有的真实家目录测量测试继续按原显式开关默认跳过，不属于本轮临时夹具验证。构建写独立 scratch；D48 所有新增 store 偏好均由 `TestPreferenceDomain.make(for: self)` 创建。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
unset STORAGE_CLEANER_R2FAF_REAL_HOME
worktree=/Users/developer/Developer/sc-worktrees/r2-fa-followups
round=/Users/developer/Developer/.sc-build/r2-fa-followups/round4
swift build --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --build-tests --skip-update --disable-automatic-resolution
swift test --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter TestPreferenceHygieneTests
swift test --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter 'FileAnalysisTrash|FileAnalysisApplicationBundleTraversalTests|StorageMapAnalysisEquivalenceTests|StorageMapIndexEditingTests|OperationRecordLabelTests'
swift build --package-path "$worktree" --scratch-path "$round/strict" --jobs 4 --build-tests --skip-update --disable-automatic-resolution -Xswiftc -strict-concurrency=complete
python3 script/check_private_api.py
git diff --check
```

定向类：`FileAnalysisTrashRunningApplicationTests`、`FileAnalysisTrashFollowupPolicyTests`、`FileAnalysisTrashRefinementTests`、`FileAnalysisTrashFollowupPresentationTests`、`FileAnalysisTrashTests`、`FileAnalysisTrashStoreTests`、`FileAnalysisTrashProtectedScopeTests`、`FileAnalysisTrashCostTests`、新增 `FileAnalysisApplicationBundleTraversalTests`；回归含 `StorageMapAnalysisEquivalenceTests`、`StorageMapIndexEditingTests`、`OperationRecordLabelTests`；卫生守卫 `TestPreferenceHygieneTests` 单独先跑。新增的两处等待使用 @MainActor／实际 Task 的 Sendable 句柄；等待解析完成的锁封装只暴露 Bool，解析路径数组的记录也用锁，没有把 UserDefaults 传到后台线程。

### 8.4 红与反证：须记录编译成功后测试失败的日志

红基线准备：`python3 "$round/prepared/prepare-red-baseline.py"`，导出 80f37e3 到专属 `red-baseline-src`，只覆盖本轮测试和临时 Tool 夹具，给旧 probe 加 stat/open 之间的测试钩子，给旧 scanner 加探测器注入，给旧 store 加同样的只读任务句柄。三个接线适配保留基线语义，不加入修复。脚本不构建、不运行测试、不提交；目录已存在则拒绝覆盖。

```bash
swift build --package-path "$round/red-baseline-src" --scratch-path "$round/red-debug" --jobs 4 --build-tests --skip-update --disable-automatic-resolution
swift test --package-path "$round/red-baseline-src" --scratch-path "$round/red-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter 'FileAnalysisTrashFollowupPolicyTests|FileAnalysisTrashRunningApplicationTests/testRunningBundlesStayBlockedRegardlessOfPackageTypeOrProbeResult|FileAnalysisApplicationBundleTraversalTests'
```

预期红：运行中的四种包仍漏挡；后备名、BNDL、子路径断言失败；nested 调用记录出现多余包；FIFO 换入后旧 open 等约 2 秒才解阻，超过新测试的 1 秒预算。基线的生产迟到守卫本来正确，新的等待测试在基线上应为绿；它的红必须通过下列 `late-protection-accepted` 变异产生，不能声称在正确基线上会失败。

反证脚本只改本轮绿文件的精确片段，哈希不匹配或有其他变异在场则停止；备份存 round4/mutation-backup。每项 `python3 "$round/prepared/mutate-prepared.py" apply <name>` → 构建成功 → 跑表中定向过滤，记录非零 exit 和失败断言 → `python3 "$round/prepared/mutate-prepared.py" restore` → 重建 → 重跑同一项为绿。不要以编译失败代替红测试。各变异一次只运行一项。

| 变异名 | 撤掉／改坏什么 | 定向过滤及预期失败 |
|---|---|---|
| `running-self-unblocked` | 仅删除运行路径自身挡板，保留新探测器 | `FileAnalysisTrashRunningApplicationTests/testRunningBundlesStayBlockedRegardlessOfPackageTypeOrProbeResult`：测试强制旧 nonApplication 结果，四个包自身 block 和直接 review 断言失败，证明 P1 独立于 P2 |
| `package-type-required` | 恢复包类型 gate | `FileAnalysisTrashFollowupPolicyTests`：BNDL／APPL 无文件等断言失败 |
| `no-bundle-name-fallback` | 必须明确写非空可执行文件名 | `FileAnalysisTrashFollowupPolicyTests/testTheAppProbeUsesCFBundleExecutableNamesWithoutRequiringAPPL`：Unnamed／Malformed／MissingPlist／EmptyName 失败 |
| `plain-name-only` | 再次拒绝所有子路径 | 同上：Subpath 和包内 Escape 失败 |
| `executable-not-required` | 忽略可执行文件存在与类型 | 同上及 `testAFolderNamedLikeAnAppIsSelectableUnlessItHasAnExecutable`：NoExecutable／APPLWithoutExecutable／FolderExecutable／数据目录失败 |
| `links-followed` | `fstatat` 跟链接并撤 `O_NOFOLLOW` | `FileAnalysisTrashFollowupPolicyTests`：LinkedContents／LinkedPlist／LinkedMacOS／LinkedExecutable／LinkedSubpath 的保守断言失败（包根的 lstat 保留，LinkedBundle 仍挡住） |
| `unreadable-is-folder` | plist 的 open 失败返回 false | `FileAnalysisTrashFollowupPolicyTests/testTheAppProbeStaysBlockedWhenItCannotRead`：Locked 失败 |
| `fifo-open-blocks` | 仅 plist open 去掉 `O_NONBLOCK` | `FileAnalysisTrashFollowupPolicyTests/testAnInfoPlistReplacedWithAFIFOBetweenStatAndOpenDoesNotBlock`：2 秒解阻后耗时断言失败，测试不会永久挂住 |
| `nested-apps-probed` | 去掉外层应用范围的短路 | `FileAnalysisApplicationBundleTraversalTests`：记录到嵌套包调用，1／4／8 模式失败 |
| `worker-loses-app-scope` | 并行任务不带入外层应用状态 | 同上：4／8 模式调用集合失败；1 线程仍应正常 |
| `late-protection-accepted` | 撤 `LargeFilesStore` 的 `current.awaitsProtectedLinkTargets` 条件、撤 service 的 awaits 守卫，并清 `protectedLinkTargetsUnknown`（与复核同定义） | `FileAnalysisTrashRefinementTests/testFindingTheLinksOutOfTimeBlocksEveryItemAndALateResultIsIgnored`：解析完成且主 actor 处理后 zip 变 available，`Not taken late` 断言必须失败。单独连续跑 3 次，均须失败；还原后均须绿 |
| `volume-phrase-too-long` | 卷未知行内文案写成长句 | `FileAnalysisTrashFollowupPresentationTests/testTheVolumeIsNotCalledICloudAndTheNewReasonsAreShortPhrases`：精确短语及新纳入的循环 ≤8 字／无逗号断言失败 |

迟到反证的精确定义在 mutations.json：**不是**只清 unknown 或只撤一道守卫；同时撤两道守卫并清未知，才会把原 ZIP 恢复成 available。新测试的 `resolved.finish()` 在 `resolve(home, appData)` 返回之后，`await protectionTask.value` 在主 actor 保护任务整段结束之后。`resolver.waitFinished` 表示的仅是 gate 放行，本轮不再把它当作解析结束。其他两个旧 iCloud 测试的 yield 等待不在本轮指定问题中，保留；不得把本项修复推广为所有异步测试均已具备相同强度。

### 8.5 截图说明、性能与已知限制

1. §6 的 fc-2 仍是第二／三轮历史截图，不能作为第四轮完成证据。第四轮预期：`Plugin.app` 若为 BNDL＋普通 MacOS/Plugin，锁定“应用”，分类“应用与安装包”；`Legacy.app`／Real.app 有普通可执行文件时同样锁定；Untyped.app 没有文件仍可选、按内容分类。fc-1 的 com.example.app 数据目录仍可选，行内“数据 · 1 项”、审阅为“文件夹”。如主会话另行获准补截图，应把夹具全放临时目录、真实应用查询替换为临时 Tool，确保 Real／Plugin／Legacy 的普通文件确实存在；保存日／夜两种底色的截图和夹具清单。本轮只更新说明，未启动应用或生成截图。
2. 前三轮“真应用不会变成可勾选文件夹”的概括不成立：复核提供 FNDR、AAPL、BNDL、缺可执行文件名的反例。本轮改的是明确范围：运行路径自身无条件挡；CFBundle 命名规则能找到包内普通文件的 `.app` 挡；不能读／不能安全读保守挡。没有承诺识别所有其他历史包布局。
3. 第三轮遍历成本已由复核测量约 +3–4% CPU（5,000 个 .app）。本轮多了可执行文件元数据核对，也减少了外层应用内的重复探测；净成本 **未测量**，不能把第三轮测量当成本轮结果，不修改既有 30 µs／200 ms 预算。
4. 转移路径形状的观察只记录：若 Security 明确认定已转移却还原不出原路径，而系统未来挂载布局不符合 `AppTranslocation/<id>/d/`，当前 resolver 的“未知”判定可能遗漏原位置保护。本轮未改该行为，也没有做真实 App Translocation 的端到端验收。
5. 行内分类与清理规则在遍历和分析结束时各探测一次，夹具或真实包在两次间变化仍可能暂时显示不一致；可否移走按规则判定，执行前原有核对保留。网络文件系统上阻塞的 lstat 不能中断，原十秒超时保护保留。
6. JEV：已核对本会话的 `mcp__jev__jev_review` 可调用定义，参数无 model 字段；尝试传源码完整 diff 和明确 NOT RUN 状态，权限层返回 `MCP tool call requires approval, but approval policy is never`。状态 **BLOCKED**，模型请求未执行，未收到实际模型标识或评判，不能声称得到 JEV 批准。该权限限制不阻止已授权的静态准备，主会话仍须构建、反证和独立复核。

## 主会话验证结果（第 4 轮，2026-10-07 22:4x）

- **提交**：Codex 四组按 `round4/prepared/commit-prepared.py` 提交，哈希校验通过：
  - `b06c748` 运行中包自身阻挡、按可执行文件判定应用；
  - `56e13ab` 迟到结果测试；
  - `7d164c5` 嵌套包跳过探测；
  - `f243eaa` 交接。
  - 模型名按派工记录改为 `openai/gpt-6.1-sol`。
- **首轮定向测试**：143 个，68 处失败，其中 19 处是意外错误 `unsafePath`。原因是本轮把 `TrashFixture` 的根目录从家目录改到了系统临时目录，而移到废纸篓只接受家目录内的项目。
- **主会话修正**（`def2321`）：夹具根目录恢复为 `~/.storage-cleaner-file-analysis-trash-test-*`（D48 认可的隔离位置，夹具自己清理），保留新应用规则需要的 `Contents/MacOS` 可执行文件。
- **复跑**：过滤 `FileAnalysisTrash|FileAnalysis|OperationRecordLabelTests|StorageMap|RecordedTrashRecoveryTests|RecordedCleanupRecoveryTests|OperationResultPresentationTests|ExternalMigrationReceipt|CleanupReportSkipPresentation|TestPreferenceHygieneTests|LargeFilesStore|DiskScanner`，共 143 个，跳过 2 个（需显式开关的测量），0 失败。`~/.storage-cleaner-*` 残留 0 个。
- **反证**：按 `round4/prepared/mutations.json` 的定义，由主会话执行器逐项应用，每轮后 `git checkout` 还原。
  - `running-self-unblocked` → 失败，含 `testRunningBundlesStayBlockedRegardlessOfPackageTypeOrProbeResult`。
  - `package-type-required` → 失败。
  - `executable-not-required` → 失败。
  - `late-protection-accepted` → `testFindingTheLinksOutOfTimeBlocksEveryItemAndALateResultIsIgnored` 失败。上一轮复核指出的测试缺口已补上。
  - `nested-apps-probed` → `testNestedAppsAreNotProbedInsideAnApplicationInAnyWalkMode` 失败。
  - `volume-phrase-too-long` → 2 个方法失败。
  - 未执行 `fifo-open-blocks`：去掉 `O_NONBLOCK` 会让测试进程卡死在 FIFO 上，不适合放进定向集。

## 9. 第 5 轮：可执行候选位置与非普通 plist（待主会话验证）

本轮基线为 `741fc695032f957ee7ca44c1fcfbccb6c0c59d52`，分支 `task/r2-fa-followups`，开始时工作区和暂存区干净。依据独立复核 `~/Developer/.sc-build/r2-fa-followups/round4/review/review-final.md` 的两项 P2 和主会话本轮裁定修改；第 4 轮运行中包自身挡板保留。D60 继续从主开发副本的 DECISIONS 维护源只读核对，本 worktree 未同步该条。

**夹具位置不改。**主会话 `def2321` 已恢复 `TrashFixture` 到家目录中的 `~/.storage-cleaner-file-analysis-trash-test-*`；本轮没有修改 `FileAnalysisTrashTests.swift` 或夹具构造函数。新增夹具都建在该 UUID 隔离根目录内，由 `defer` 清理；偏好仍使用 `TestPreferenceDomain.make(for:)`。本轮未在本会话创建或运行 Swift 夹具。

### 9.1 改动与理由

1. **P2-1：遍历所有适用的包内候选位置。**`FileAnalysisApplicationBundleProbe.swift` 以不跟链接的元数据检查识别 `.app` 布局，优先级为 Contents → Resources → Support Files → 平面布局。按该布局读取对应目录的 Info.plist，取现有 `CFBundleExecutable`／包名后备规则，再依次检查候选。某候选确定缺失、是目录或其他非普通文件时继续下一候选；任一候选为普通文件即按应用处理，链接、无权限、占位或其他不确定情况保守阻挡。只有所有适用候选都确定无普通文件才放行为文件夹。

   | 布局 | plist 所在目录 | 可执行文件的候选目录（按序） |
   |---|---|---|
   | Contents | `Contents` | `Contents/MacOS`、`Contents/Mac OS X`、`Contents/MacOSClassic`、`Contents/Mac OS 8`、`Contents`、包根 |
   | Resources | `Resources` | 包根 |
   | Support Files | `Support Files` | `Support Files/Executables` 下四个平台目录、`Support Files/Executables`、包根 |
   | 平面布局 | 包根 | 包根下四个平台目录、包根 |

   每一候选从已打开的包根描述符逐级 `fstatat`／`openat`，保留 `AT_SYMLINK_NOFOLLOW`／`O_NOFOLLOW`／`O_NONBLOCK`；子路径分别以候选为起点做词法归一，禁止越过包根。没有改用 Bundle／CFBundle 的文件系统查询，没有读取可执行文件内容。布局目录打开后另核对占位标记。

   目录表依据 Apple 公开 CF 的固定版本 `dc54c6bb1c1e5e0b9486c1d26dd5bef110b20bf3`：[可执行文件查找](https://github.com/apple-oss-distributions/CF/blob/dc54c6bb1c1e5e0b9486c1d26dd5bef110b20bf3/CFBundle.c#L1680)、[布局优先级与平台目录名](https://github.com/apple-oss-distributions/CF/blob/dc54c6bb1c1e5e0b9486c1d26dd5bef110b20bf3/CFBundle_Resources.c#L221)、[布局路径常量](https://github.com/apple-oss-distributions/CF/blob/dc54c6bb1c1e5e0b9486c1d26dd5bef110b20bf3/CFBundle_Internal.h#L279)。原始源码及哈希保存在 `round5/reference/`，prepared/source-references.json 固定来源。此处复用目录规则，仍采用本批“普通文件即保护”的裁定；没有仿造二进制装载器、DYLD 环境变量或所有平台专用 plist 变体。

2. **P2-2：非普通 Info.plist 走后备名。**把初始目录、FIFO 等类型的提前 `false` 改为不打开且继续包名查找；plist 链接／占位／无法获取元数据仍保守阻挡。普通 plist 的 1 MiB 上限、非阻塞打开以及打开后类型、设备／inode 和大小核对保留。找不到包名可执行文件的目录／FIFO plist 包仍可判为普通文件夹，不能一律误挡。

3. **新增测试，不改旧断言。**新增 `FileAnalysisApplicationBundleCandidateTests.swift`（6 个方法）和 `FileAnalysisApplicationBundleSpecialInfoTests.swift`（2 个方法）。前者包含复核指定的 `Example.app/Contents/Info.plist`＋包根 `Tool`，直接断言探测、分类、共用勾选规则、store 实际不可勾选、服务审阅阻挡及用户审阅仅保留 big.zip；其余覆盖各布局候选、候选全部缺失、先遇目录／FIFO 仍继续、适用布局范围和子路径／链接边界。后者覆盖 plist 为目录／FIFO 时先无可执行文件再创建 `Contents/MacOS/<包名>`，均用打开前钩子确认未进入 open 分支、用 1 秒预算确认不等待 FIFO；候选 MacOS 为链接时保守阻挡。

本轮旧断言改写清单：**无**。原有 FIFO＋没有可执行文件的 `XCTAssertFalse` 保留且仍应通过；原有可执行文件为目录、链接不跟随、无权限、过大、解析失败、子路径、运行中、嵌套包和迟到结果断言均未改动。没有删除测试、放宽阈值或新增跳过条件，也未修改 `ScanStore.swift`。

### 9.2 补丁、静态核对与主会话绿验证

产物在 `~/Developer/.sc-build/r2-fa-followups/round5/prepared/`，两组顺序：`01-bundle-probe`（共用探测器＋两个新增测试文件）→ `02-handoff`（本节）。附提交说明、all.patch、manifest.json、commit-prepared.py、static-checks.json、红基线和变异辅助脚本；提交说明末尾使用本轮指定的两行署名。

本会话仅静态准备：`git diff --check`、all.patch 及两组 patch 的 `git apply --check --reverse`、Python AST、最终文件与产物 SHA-256、变异片段数量核对记录在 static-checks.json。**Swift 构建、严格并发、XCTest、反证、提交、安装和应用启动均 NOT RUN，测试执行 0**；静态核对不是原生验证。脚本生成不会运行红基线、变异或提交脚本。

主会话在本 worktree 执行，保存日志到 round5/logs；不复用上一轮的 --skip-build 产物：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
unset STORAGE_CLEANER_R2FAF_REAL_HOME
worktree=/Users/developer/Developer/sc-worktrees/r2-fa-followups
round=/Users/developer/Developer/.sc-build/r2-fa-followups/round5
swift build --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --build-tests --skip-update --disable-automatic-resolution
swift test --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter TestPreferenceHygieneTests
swift test --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter 'FileAnalysisApplicationBundle|FileAnalysisTrash|StorageMapAnalysisEquivalenceTests|StorageMapIndexEditingTests'
swift build --package-path "$worktree" --scratch-path "$round/strict" --jobs 4 --build-tests --skip-update --disable-automatic-resolution -Xswiftc -strict-concurrency=complete
python3 script/check_private_api.py
git diff --check
```

重点定向：`FileAnalysisApplicationBundleCandidateTests`、`FileAnalysisApplicationBundleSpecialInfoTests`，回归 `FileAnalysisTrashFollowupPolicyTests`、`FileAnalysisTrashRunningApplicationTests`、`FileAnalysisApplicationBundleTraversalTests`、`FileAnalysisTrashRefinementTests`、`FileAnalysisTrashCostTests`，再含上述过滤中的其余 FileAnalysisTrash 类和两个 StorageMap 类。卫生守卫先单独跑。新增 store 测试方法为 `@MainActor`，异步流程沿用已编译验证过的 store 接线与 15 秒等待预算；探测器新逻辑没有异步捕获或共享可变状态。

### 9.3 红基线与反证

红基线：`prepare-red-baseline.py` 通过 `git archive` 导出 `741fc695` 到专属 `round5/red-baseline-src`，只叠加两个新增测试文件，不加入生产修复，也不做接线适配；保留主会话修正过的家目录夹具。目录已存在或绿文件哈希不符则拒绝覆盖。仅主会话执行：

```bash
python3 "$round/prepared/prepare-red-baseline.py"
swift build --package-path "$round/red-baseline-src" --scratch-path "$round/red-debug" --jobs 4 --build-tests --skip-update --disable-automatic-resolution
swift test --package-path "$round/red-baseline-src" --scratch-path "$round/red-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter 'FileAnalysisApplicationBundleCandidateTests|FileAnalysisApplicationBundleSpecialInfoTests'
```

红基线必须先编译成功，再出现测试断言失败：包根 Tool 的探测返回 false、被纳入非应用例外并允许勾选／审阅；其他未覆盖的候选位置失败；目录／FIFO plist 有包名可执行文件时仍被漏放。旧式和后备位置的新增测试也应失败。无可执行文件、Contents/MacOS 正常位置等对照断言应保持通过，不能把编译错误计为红证据。

反证以最终绿源码为起点，定义见 `round5/prepared/mutations.json`，格式延续 round4 的 `file`／`before`／`after`／`matches`。每次只应用一项，先构建成功，再跑对应测试，保存失败断言和非零退出码，最后还原并重新构建／复跑绿；不要直接套用 round4 中已失效的行文本。脚本保留本轮原始文件字节于 round5/mutation-backup，只还原自身已知变异，拒绝覆盖未知修改。

| 变异名 | 改动 | 应失败的定向方法／类 |
|---|---|---|
| `omit-wrapper-fallback` | 去掉最后的包根后备 | Candidate 的 `testRootExecutableIsBlockedByProbeSelectionAndReview`，覆盖三个入口；现代及旧式包根条目也失败 |
| `macos-only` | 四个平台目录缩为 MacOS | Candidate 的 `testEveryModernExecutableLocationIsAnApplication`、`testLegacyAndFlatExecutableLocationsAreApplications` 的三个其他平台目录条目 |
| `omit-executable-base` | 不查平台目录的上层可执行目录本身 | 同上两方法的 Contents、Support Files/Executables、平面包根条目 |
| `ignore-legacy-layouts` | 布局探测只认 Contents，否则平面 | Candidate 的 `testLegacyAndFlatExecutableLocationsAreApplications` 中 Resources／Support Files 条目；适用布局对照也会失败 |
| `fallback-follows-links` | fstatat 和 open 去掉 NOFOLLOW | Candidate 的 `testFallbackCandidatesKeepSubpathsInsideTheBundleAndDoNotFollowLinks` 和 SpecialInfo 的不确定候选测试；只访问夹具内链接目标 |
| `nonregular-plist-is-folder` | 非普通 plist 再次提前 false | SpecialInfo 两个方法中的有包名可执行文件／不确定候选断言 |
| `nonregular-plist-always-app` | 非普通 plist 一律 true | SpecialInfo 的 `testNonRegularInfoPlistsUseBundleNameWithoutOpeningOrBlocking` 中尚无可执行文件的两个 false 对照 |
| `open-nonregular-plist` | 让目录／FIFO 进入普通 plist 的 open 分支 | 同一方法中的 `attemptedOpen == false` 断言，和无可执行文件的 false 对照；O_NONBLOCK 保留，因此这项不会刻意阻塞 FIFO |

```bash
python3 "$round/prepared/mutate-prepared.py" apply omit-wrapper-fallback
swift build --package-path "$worktree" --scratch-path "$round/mutation-debug" --jobs 4 --build-tests --skip-update --disable-automatic-resolution
swift test --package-path "$worktree" --scratch-path "$round/mutation-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter FileAnalysisApplicationBundleCandidateTests
python3 "$round/prepared/mutate-prepared.py" restore
swift build --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --build-tests --skip-update --disable-automatic-resolution
swift test --package-path "$worktree" --scratch-path "$round/main-debug" --jobs 4 --skip-build --skip-update --disable-automatic-resolution --filter 'FileAnalysisApplicationBundleCandidateTests|FileAnalysisApplicationBundleSpecialInfoTests'
```

其余变异同法逐项执行；涉及非普通 plist 时过滤 SpecialInfo，涉及候选目录时过滤 Candidate，`fallback-follows-links` 跑这两个类。shell 若启用遇错即退出，应记录预期失败并确保 restore 执行，不能把变异源码留给后续验证或提交。本轮未定义去掉 O_NONBLOCK 的阻塞变异；第四轮对该反证的主会话记录保留，不改写成已验证通过。

### 9.4 复核状态与剩余边界

- JEV 本轮实际调用了 `mcp__jev__jev_review`，工具定义没有 model 参数；返回 `model=jev-latest`、`provider=typesafe`，`truncated=false`，`action=escalate`、`safe_to_apply=0.18`、`composite=0.65925`。返回只含评分，没有具体缺陷诊断；这是**待进一步复核**，不是自动认可，也不是工具权限阻断。原始返回保存为 prepared/jev-review.json。提交前仍由主会话完成构建、红绿、反证和独立复核。
- 候选目录增加后的 CPU 净成本本轮未测；第 3 轮约 +3–4% CPU 是历史测量，不能当成本轮结果。原有 30 µs／200 ms 等预算和计时断言均未放宽。
- 无新增的已确认未修复功能缺陷；真实 File Provider 占位、全部历史平台变体和真实 App Translocation 端到端未验证。没有系统位置测量或真实应用查询。
- 第四轮记录的转移路径形状限制、扫描与规则两次探测间包内容变化、不可中断的网络 lstat 仍存在；本轮不改变这些范围，也不声称解决它们。

## 主会话验证结果（第 5 轮，2026-10-07 23:4x）

- **提交**：Codex 两组按 `round5/prepared/commit-prepared.py` 提交（`1cfdd33` 探测器与测试、`6293a56` 交接），模型名按派工记录改为 `openai/gpt-6.1-sol`。
- **构建与测试**：构建 exit 0。定向测试与第 4 轮同一过滤，共 151 个，跳过 2 个，0 失败。`~/.storage-cleaner-*` 残留 0 个。
- **反证**：按 `round5/prepared/mutations.json`，逐项应用并还原。
  - `omit-wrapper-fallback`：18 处失败；
  - `macos-only`：12 处失败；
  - `nonregular-plist-is-folder`：4 处失败；
  - `nonregular-plist-always-app`：3 处失败；
  - `fallback-follows-links`：13 处失败。
  - 未执行 `open-nonregular-plist`：会打开 FIFO，测试进程可能卡死。
- **结论**：最终复核（GPT-6 Astra）无 P0／P1，要求修复的两处 P2 已修并验证，合并。
