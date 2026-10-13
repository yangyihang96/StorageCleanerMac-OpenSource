# 批次 4a 交接：更新安全

- 实现：Claude（主会话；复核意见由 Claude 子代理处理）　复核：全新上下文的 Claude 子代理（只读）
- 分支：`task/batch4a-update-safety`，基于 `458cf66`
- 提交：原改动 `9da0122`、`de02c40`、`ce1ac37`、`498cd5e`；复核处理 `c722315`、`d50dd62`、`750734d`；本交接单独一个提交

## 改动

| # | 问题（原审阅编号） | 改动 | 文件 |
|---|---|---|---|
| 1 | P1-8 自身 Sparkle“安装并重启”不等清理、恢复，可能在移动中途退出 | 新增 Sparkle 代理，只实现 `shouldPostponeRelaunchForUpdate`：有租约或清理隔离时推迟重启，空闲后再安装；更新选择仍由 Sparkle 决定。锁定“代理必须为空”的策略测试改为：必须是只推迟重启的代理，仍禁止自定义选择 | `Services/AppUpdater.swift`、`App/StorageCleanerMacApp.swift`、`Tests/.../AppUpdaterPolicyTests.swift` |
| 2 | P1-9 第三方更新、卸载归属等比对 Team ID，但自签名证书可以在主题里写任意 Team ID | 签名校验结果只在签名链锚定到 Apple（`anchor apple generic`：Developer ID、App Store、Apple Development、Apple 自家）时才报告 Team ID，否则为空，所有 Team 比对因此失败关闭 | `Features/AppUpdates/Security/CodeSignatureVerifier.swift` |
| 3 | P1-10 官网更新队列点“稍后”后无法再次加入（文案却说“已保留供下次处理”） | 再次请求被“稍后”的应用时，作为新项重新校验并入队 | `Features/AppUpdates/WebsiteUpdates/WebsiteUpdateQueue.swift` |
| 4 | P1-11 下载字节上限无效 | 实测确认：原实现用异步 `download(for:)`，会话代理的 `didWriteData` 从不被调用，16 MiB 无长度分块响应和声明长度超限的响应都完整下完。改为由代理驱动的下载任务（逐块回报写入），写入量或声明长度超过上限立即取消并删除半成品 | `Features/AppUpdates/WebsiteUpdates/OfficialApplicationUpdateInstaller.swift`（新 `OfficialUpdateDownloader`） |

复核处理后追加的改动见下一节。本批没有改批次 3a 的文件（`ScanStore.swift`、`UninstallExecution.swift`、`AppUninstallService.swift`、`RecordedTrashOperation.swift`、`AuthorizedApplicationMover.swift`、`Sources/FileOperationHelper/**`、`UninstallPreviewSheet.swift`、`ReversibleOperationsView.swift`），也没有改 `DECISIONS.md`、`BOARD.md`。

## 复核意见与处理

复核结论“需修改后合并”。逐条：

| 编号 | 意见 | 处理 | 提交 |
|---|---|---|---|
| P1-a | `ApplicationMetadataReader` 直接读原始 `kSecCodeInfoTeamIdentifier`，签名无效也返回；它产出的 `signingTeamIdentifier` 用于来源匹配、自动安装资格、Homebrew/App Store/Sparkle 更新后回读和替换前复核 | **已修**。读取器复用 `CodeSignatureVerifier.trustedTeamIdentifier(reported:isAppleAnchored:)` 与 `isAppleAnchored(_:)`，且只在签名有效时才给 Team ID。测试用真实夹具：复制 `/usr/bin/true` 组成最小 `.app`，`codesign --sign - --team-identifier ABCDE12345` 签名（有效、ad-hoc、声明了 Team、不锚定 Apple）；先断言夹具确实声明了该 Team，再断言读取器、`inspectSignature` 和 `read()` 都拿不到 Team ID、`signed-bundle-identity` 证据不出现 | `c722315` |
| P1-b | 改了源码契约测试，RULES §4 要求 DECISIONS 有对应条目 | **已备文字**，见下文“拟议 D11”，由主会话合并时写入（本批不改 `DECISIONS.md`） | — |
| P2-1 | 下载器续体丢失唤醒：完成回调先于续体保存到达时永不恢复，下载期间持有 `.appUpdates` 租约 | **已修**。完成时若续体还没登记，结果暂存在代理里；`run` 在同一把锁内先查暂存结果，有就直接返回，没有才登记续体；调用方已取消时只取消任务、不启动传输。新增测试用测试钩子在“登记续体前”停 200 ms，让已取消任务的完成先到；旧实现下该测试 10 秒超时失败（见反证 M5） | `d50dd62` |
| P2-2 | 拒绝重定向后任务以 3xx 正常完成，报成 `.invalidResponse`，`invalidRedirect` 映射是死代码 | **已修**。拒绝分支里取消任务；成功路径再查一次“拒绝过重定向/超过上限”，命中就按失败处理并删除暂存文件。新增 URLProtocol 测试：302 指向允许列表外的主机 → 报 `invalidRedirect`、暂存文件不存在、外部主机从未被请求 | `d50dd62` |
| P2-3 等待测试 | `finishedEarly` 读的是协调器状态，等待函数立即返回也能通过；没覆盖清理隔离 | **已修**。测试改为观察等待方自身：持有清理租约时 150 ms 内不得完成、提示恰好一次，释放后取到自己的 `.appUpdates` 租约；只剩清理隔离时同样等待，清除后才继续；取消后不取租约；空闲时立即取到且不提示，之后清理开不了。反证：实现改成“取不到就立即返回”，两条等待测试失败（M8） | `750734d` |
| P2-3 下载测试 | 没断言停在哪里、没断言暂存文件已删除；只按写入量判断的实现也能通过 | **已修**。新增 `didWrite` 测试钩子记录每次写入的累计量。声明长度超限：上限 1 MiB、声明 4 MiB，断言最大写入量小于上限（第一次写入即停）；无长度分块：断言上限 < 最大写入量 ≤ 上限 + 一个分块；两者都断言暂存文件不存在。反证：只按写入量判断时声明长度测试失败，实测写到 1114112 字节（M7） | `d50dd62` |
| P2-3 签名测试 | 只测辅助函数，`verifyCode` 去掉锚定判断测试发现不了 | **已修**。用上面的夹具经 `verifyCode` 断言：签名有效、标识符正确、Team ID 为空。反证：`verifyCode` 不看锚定时失败（M1）。说明：SwiftPM 构建的测试包是 ad-hoc 签名但**不带** Team ID，用它做样本无法区分，所以改用 `--team-identifier` 夹具 | `c722315` |
| P2-3 策略测试 | 只禁止 `bestValidUpdate` | **已修**。改为经 Objective-C 运行时枚举 Sparkle 2.9.4 `SPUUpdaterDelegate` 的全部可选方法，断言 `AppUpdater` 恰好只实现 `updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:` 和 `updater:didFinishUpdateCycleForUpdateCheck:error:`；并断言选择类方法（`bestValidUpdateInAppcast:forUpdater:`、`allowedChannelsForUpdater:`、`feedURLStringForUpdater:`、`feedParametersForUpdater:sendingSystemProfile:`、`updater:shouldProceedWithUpdate:updateCheck:error:`、`versionComparatorForUpdater:`、`updater:mayPerformUpdateCheck:error:`、`updaterMayCheckForUpdates:`、`updaterShouldRelaunchApplication:`、`updater:willInstallUpdateOnQuit:immediateInstallationBlock:`）确实存在于协议中，检查才有意义。名称按 checkout 中 2.9.4 头文件核对。反证：加上 `allowedChannels(for:)` 后失败（M9） | `750734d` |
| P2-4 | 推迟期间 Sparkle 窗口停在“Ready to Install”，没有说明 | **已修（实现方式有一处偏离，见说明）**。有重任务时弹出非模态说明窗口（SwiftUI 内容放在 `NSPanel` 里，浮动、不抢模态、不申请任何权限）：标题“更新将在当前任务完成后安装”，正文“当前有任务正在进行，完成后将自动安装并重启。如需立即更新，可先取消该任务。”（英文同义，均走 `L10n.text`）；安装继续时自动关闭，用户也可点“好”关闭。没有重任务时不提示、立即安装。**偏离**：没有重任务时代理仍返回 `true` 而不是 `false`，因为协调器是 actor，取租约需要 `await`；若返回 `false`，Sparkle 会在没有租约的情况下继续，P2-5 要关的窗口又打开了。实际效果与“照常安装”相同，只多一次 actor 调用 | `750734d` |
| P2-5 | 判定空闲到真正退出之间（stage 2、退出事件、3 秒握手）新开始的清理会被截断 | **已修**。复用已有 owner `.appUpdates`：调用安装回调前先在 `HeavyWorkCoordinator` 取得租约并持有到退出，其间新开始的重任务会得到现有冲突提示“正在进行应用更新，请等待完成或取消后再试。”。等待任务调用安装回调前有 `guard !Task.isCancelled`，取消时归还租约。若安装没有导致退出：Sparkle 报告更新周期结束（`didFinishUpdateCycleFor`，安装失败或中止时都会调用，见 2.9.4 `SPUUpdater.m` 的完成回调）时立即释放；另有 120 秒安全网，避免安装进程卡住时重任务一直被挡 | `750734d` |
| P2-6 协调器赋值 | 只在主窗口 `.onAppear` 赋值 | **已修**。改在 `StorageCleanerMacApp.init()` 创建协调器后立即交给 `AppUpdater.shared`（Sparkle 文档推荐在 App 初始化中创建控制器；原先 `@StateObject` 也会在启动时创建，时机只提前一点） | `750734d` |
| P2-6 复用 | `isAppleAnchored` 与 `hasAppleAnchor` 重复；`HeavyWorkRelaunchGate` 与 `waitUntilOwnerInactive` 重复 | **已修**。`UninstallOwnershipVerifier.hasAppleAnchor` 改为调用 `CodeSignatureVerifier.isAppleAnchored`。`waitUntilOwnerInactive` 从 `MacBenchmarkLifecycle.swift` 移到 `HeavyWorkCoordinator.swift`，与新的 `acquireWhenIdle(owner:pollInterval:)` 共用一个轮询循环；旧的 `HeavyWorkRelaunchGate.waitUntilIdle` 删除 | `c722315`、`750734d` |
| P2-6 并发简化 | `SPUUpdaterDelegate` 已是 `NS_SWIFT_UI_ACTOR` | **已修**。去掉 `nonisolated`、`MainActor.assumeIsolated` 和 `RelaunchHandler`，代理方法直接主线程隔离；Debug（Swift 6 模式）与 `-strict-concurrency=complete` 构建均无错误、无警告 | `750734d` |
| P2-6 两边为空 | `OfficialApplicationUpdateInstaller.swift:1257`、`WebsiteUpdateWorkflow.swift:189` 两边都没有 Team 也算通过 | **已修**。两处都显式要求期望的 Team ID 非空（替换前复核返回不通过；官网复查报“应用身份已变化”并转为等待用户）。自动安装资格 `supportsAutomaticInstallation` 原本就经 `isCompleteForAutomaticUpdates` 要求 Team 非空，未改；`ExternalUpdateVersionVerifier` 原本就要求，未改。反证 M3、M4 | `c722315` |
| P2-6 行为变化 | 写明非 Apple 证书签名应用的行为变化 | **已写**，见下文 | — |

## 拟议 D11（请主会话写入 `DECISIONS.md`）

建议放在新的日期小节（例如“2026-10-04 下午”）最上面：

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D11 | 自身更新的 Sparkle 代理只推迟安装重启，不参与更新选择：`AppUpdater` 只实现“推迟安装重启”（`updater(_:shouldPostponeRelaunchForUpdate:untilInvokingBlock:)`）与“更新周期结束”（`updater(_:didFinishUpdateCycleFor:error:)`，仅用于结束推迟、释放租约）。安装前取得 `.appUpdates` 重任务租约并持有到退出；有重任务时显示说明并等待。不实现任何选择、频道、更新源、版本比较、检查放行、重启放行或退出时安装的代理方法。依据：已批准计划批次 4a“自身更新重启前等待重任务” | 旧规则：不设 Sparkle 代理（`updaterDelegate: nil`，`AppUpdaterPolicyTests` 锁定），全部交给 Sparkle | 批次 4a；`AppUpdaterPolicyTests` 改为经运行时核对代理恰好只实现上述两个方法 |

## 行为变化

**非 Apple 证书签名但声明了 Team ID 的应用**（自签名证书在主题里写 Team ID，或 ad-hoc 签名加 `--team-identifier`）：签名校验与应用元数据现在都不报告它的 Team ID。Developer ID、App Store、Apple Development 签名的应用不受影响（本软件测试版用 Apple Development 签名，锚定 Apple）。

- 应用更新扫描：不再匹配要求 Team 的官方来源（内置注册表、记录了 Team 的用户确认来源）；不进入任何自动更新（`isCompleteForAutomaticUpdates` 为假：Homebrew、App Store、官网自动安装）；Sparkle 只读探测报“应用签名身份不完整，未连接 Sparkle appcast”；官网复查报“应用身份已变化”（两边为空不再算通过）；外部更新核对报无法核实身份（原本就要求 Team）。
- 旧数据里保存了原始 Team ID 的身份（扫描结果、官网队列、用户确认记录）与新读数对不上，表现为失败关闭：用户确认过的来源不再生效、需要重新确认；以旧身份为期望的复查或更新后回读报身份变化。
- 以下两条来自复核者分析，本轮未单独复测：更新后不自动重启该应用（重启前核对身份）；带 Team 的登录项无法管理（启动项管理比对 Team）。
- 唯一变宽松处：`UserLaunchAgentManager.swift:612-617` 父应用没有可信 Team 时，跳过“可执行文件与父应用 Team 一致”检查，但仍核对指定要求和标识符。
- 卸载归属：原本就要求 Apple 锚定，行为不变（只是改为复用同一个判断）。

**两边都没有 Team ID 不再算同一开发者**：官网更新替换前复核不通过；官网复查报“应用身份已变化”并转为等待用户。

**自身更新（Sparkle）**：点“安装并重启”后先取 `.appUpdates` 租约。没有重任务：立即安装，无提示。有重任务（租约或清理隔离）：弹出上述说明窗口，每秒重试，取到后关闭说明并安装。取到租约到退出之间，其他重任务开始时提示“正在进行应用更新，请等待完成或取消后再试。”。安装失败或中止：立即释放；最长 120 秒后也会释放。

**官网下载**：调用方在传输开始前取消时立即返回取消，不再可能永久挂起并占住 `.appUpdates` 租约；拒绝的重定向报“官方下载发生了未授权的重定向”（以前报“官方下载服务器返回了无效响应”）。

**测试钩子**：`OfficialUpdateDownloader.TestHooks`（`beforeStart`、`didWrite`）只供测试注入，生产默认为空。

## 验证

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，Debug scratch `~/Developer/.sc-build/batch4a/debug`，日志在 `~/Developer/.sc-build/batch4a/logs/`、反证在 `~/Developer/.sc-build/batch4a/counterproof/`。全程加 `--disable-automatic-resolution`，日志中无 Fetching／Downloading；未联网、未启动应用、未截图、未安装。

| 项 | 命令（摘要） | 结果 |
|---|---|---|
| 构建 | `swift build --scratch-path …/debug --jobs 4` | PASS，exit 0，无警告（最终一次 167 s，见 `final-build.log`） |
| 相关测试（第一组改动后） | `swift test … --filter 'CodeSignatureVerifierTests\|WebsiteUpdateWorkflowTests'` | PASS，exit 0，28 项，0 失败 |
| 更新／卸载／签名相关（第一组改动后） | `--filter 'AppUpdate\|Sparkle\|Uninstall\|StartupApplicationSigning\|OfficialSource\|ApplicationMetadata\|HeavyWorkCoordinator'` | PASS，exit 0，318 项，跳过 9（需显式开启的实机、联网、签名夹具用例，以及无废纸篓权限用例），0 失败 |
| 本批相关（全部改动后） | `--filter 'AppUpdaterPolicyTests\|OfficialUpdateDownloaderTests\|HeavyWorkCoordinatorTests\|CodeSignatureVerifierTests\|WebsiteUpdateWorkflowTests\|AppUpdateOfficialSecurityTests'` | PASS，exit 0，91 项，跳过 4（显式实机用例），0 失败 |
| 新测试重复 | `swift test --skip-build --filter 'OfficialUpdateDownloaderTests\|AppUpdaterPolicyTests'` 连跑 15 次 | PASS，15/15 |
| Debug 全量 | `swift test --scratch-path …/debug --jobs 4`（反证回滚后的干净树） | PASS，exit 0，3139 项，跳过 22，0 失败（`debug-full.log`）。已知偶发的 `NetworkCompatibilitySpeedTestServiceTests` 取消测试、`SystemUtilitySafetyTests` Homebrew 文案测试本次均通过 |
| 严格并发 | `swift build --scratch-path ~/Developer/.sc-build/batch4a/concurrency --jobs 4 -Xswiftc -strict-concurrency=complete`（依赖状态从 Debug scratch 复制，避免联网） | PASS，exit 0，128 s，0 警告，日志无 Fetching／Downloading（`strict-concurrency.log`） |
| 私有接口 | `python3 script/check_private_api.py` | PASS，exit 0（6 处白名单） |
| 空白 | `git diff --check`、`git diff --check 458cf66 HEAD` | PASS，exit 0 |
| 源码守卫 | `Views` 中无 `Process(`／`.terminate(`；无冲突副本 | PASS |
| 未运行 | Release 全量、小窗性能、打包、UI 冒烟；真实 Sparkle 安装；说明窗口实机显示 | NOT RUN（规则不允许启动应用、截图、真实更新；Release 等由主会话在集成分支跑） |

**反证**（临时改动由环境变量 `B4A_MUT` 逐项开启，构建一次、逐项运行，结束后 `git apply -R` 撤回，工作区与 `HEAD` 一致；补丁见 `counterproof/mutations.patch`）。M9 是编译期改动，所以每一轮里策略测试都失败；不开任何开关时只有它失败，其余新测试全部通过：

| 开关 | 临时改动 | 失败的测试 |
|---|---|---|
| M1 | `verifyCode` 不看锚定 | `testVerifierDropsTheTeamIDThatAValidAdHocSignatureDeclares`（拿到 `ABCDE12345`）、`testReplacementIdentityCheckNeedsAnExpectedTeam` |
| M2 | 读取器返回原始 Team ID | `testMetadataInspectorDrops…`、`testMetadataReaderGivesANonAppleSignedAppNoTeamIdentity` |
| M3 | 替换前复核恢复“两边为空算通过” | `testReplacementIdentityCheckNeedsAnExpectedTeam` |
| M4 | 官网复查恢复“期望为空算通过” | `testWorkflowRejectsVersionIncreaseWhenNoTeamIdentifierIsExpected` |
| M5 | 下载器恢复旧的“先登记后启动、早到的完成丢弃” | `testCancelledCallerReturnsWhenTheCompletionArrivesFirst`（10 秒超时） |
| M6 | 拒绝重定向不取消、成功路径不查 | `testRefusedRedirectFailsAsAnInvalidRedirect`（下载“成功”，3xx 正文留在暂存文件） |
| M7 | 只按写入量判断上限 | `testDeclaredLengthOverTheLimitStopsAtTheFirstWrite`（写到 1114112 ≥ 1048576） |
| M8 | 取不到租约就立即返回 | `testInstallWaitsWhileHeavyWorkHoldsALease`、`testInstallWaitsWhileACleanupQuarantineRemains` |
| M9 | 代理加 `allowedChannels(for:)` | `testSparkleDelegateImplementsOnlyTheRelaunchHooks` |

## 未完成项与风险

- 说明窗口没有实机看过（不允许启动应用和截图）：布局、深浅色、与 Sparkle 窗口的叠放只经代码审阅。建议主会话安装前实机看一次：制造一个清理或恢复任务，再点“安装并重启”。
- 推迟与释放依赖 Sparkle 2.9.4 的行为（从 checkout 源码确认）：每个安装驱动只问一次推迟（`_postponedOnce`）；安装失败或中止时调用 `didFinishUpdateCycleFor`；“安装并重启”成功时应用先被安装器退出，不会先走到周期结束。没有用真实更新验证。
- 120 秒安全网：若安装器卡住超过 120 秒后又继续退出应用，这之后开始的重任务仍可能被截断（极端情况）。
- 自身更新期间的租约复用 `.appUpdates`，冲突提示显示为“应用更新”，与第三方应用更新同名。
- `waitUntilOwnerInactive` 从 `MacBenchmarkLifecycle.swift` 移到 `HeavyWorkCoordinator.swift`，其他批次若改这两个文件可能有小冲突。
- 原“未做”两项不变：测试版与正式版共用 EdDSA 签名密钥（需另行决定）；普通退出（⌘Q）时如果正在清理或恢复，仍在 3 秒超时后退出（需改 `ScanStore`，批次 3a 正在改）。
- 构建工具：一次 `swift build --build-tests` 在 SwiftBuild 进程内命令等待信号量处卡住约 14 分钟、CPU 为 0（与代码无关），手动结束（exit 143）后不带 `--build-tests` 重跑正常。

## 主会话复核修复轮（`498cd5e..9488614`）

主会话逐个读了修复差异：自身更新租约、通知窗、协调器轮询、元数据读取器、Team 非空要求、下载器竞态与重定向、`hasAppleAnchor` 复用（同样 `kSecCSStrictValidate`，等价）。确认退出流程只取消并等待第三方更新任务，不等待自身更新持有的 `.appUpdates` 租约，所以不会卡住重启。

补了一行防御：新的推迟请求到来时先释放旧的安装租约。被取消的旧等待在 120 秒兜底期间直接返回、不释放租约，按 Sparkle 的设计不应出现连续两次推迟，这里只是防止租约悬空。验证：`AppUpdaterPolicyTests` 6 项 0 失败。
