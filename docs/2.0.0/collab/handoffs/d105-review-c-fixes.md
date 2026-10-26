# d105-review-c-fixes：C 批独立复核返修（CODEX_C_REVIEW_20261015_1445，及返修复核 D105-R1）

批次：C 批返修 / D105。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`，全部改动未提交。返修在 D 批（D104）进行中完成，与 D104 的改动在同一工作区，两者改的文件没有重叠（见“差异与哈希”）。产品决定见 DECISIONS D105，本文只记实现、测试、证据和仍未完成的部分。Codex 对本文 v1（9 个文件）做返修复核时又报 1 项 P2（D105-R1），修复见“Codex 返修复核”一节；v1 的差异与哈希保留在证据目录 `snapshots/v1/`。

复核来源：Codex 的 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/review-c-20261016/`（`REVIEW.md`、`CANDIDATES.md`、`RESULT.json`、`swift-targeted.log`）。行号按 Codex 冻结的 `c-gate-tree`（C 批门禁副本，1,733 个文件，清单 SHA-256 `6885b722…`，与 Codex `SOURCE_MANIFEST.json` 记录的相同；本次重新计算该副本的清单，与门禁时的清单逐字节相同）。本次只读了 Codex 的目录，没有改动。

本次没有做以下事情：提交、合并、安装、重启、启动 App、运行或安装真实 helper、写风扇／电源模式／SMC、对真实数据执行清理。测试只用注入的恢复结果、假 helper（测试注入的请求发送器，只应答 ping 和读取电源配置）和临时目录；helper 恢复记录文件的读写测试只在测试自己建的临时目录里进行，没有读写 `/var/run`。

## 结论

**C-R1、C-R2 已在源码和定向测试层面修复；Codex 返修复核报的 D105-R1 也已修复。2026-10-16 Codex 最终复核（CODEX_FINAL_RECHECK_20261015_1710）在源码与隔离测试层面关闭这三项，见“Codex 最终复核”一节；这不是实机或发布验收。** 依据：
- **Codex 的原失败**（保留，不改）：`swift-targeted.log`，SHA-256 `af41646e5887f9f1e9f8c32fe252cd25eabaf08116bdb5778acbb54e6b7ffac6`（本机核对与 Codex 记录相同），2026-10-16 01:41:17–01:41:26 AEDT，51 个方法，原有 50 个通过，新方法 `IndependentBatchCReviewTests.testARecoveryTriggerDoesNotProveSuccessfulAutomaticRestore` 2 处断言失败，exit 1。证据目录 `codex-review/` 存有该日志和 `REVIEW.md`、`CANDIDATES.md` 的副本。
- **D105-R1**：Codex 的探针（逐字复制的方法体＋假历史）原为 exit 1；修复后新增项目内集成测试（真实记录文件、真实读写失败），单独连续 20 次通过，反证 6/6 符合预期。
- **修复后自测**：用 Codex 的同一过滤串和同样排除的 2 个方法运行，51 个，0 失败，exit 0（D105-R1 修复后重跑，仍为 51 个 0 失败）。`IndependentBatchCReviewTests.swift` 与 Codex 的文件逐字节相同（SHA-256 `e312addf…`），断言没有改。新增 `HardwareAutomaticRestoreTests` 11 项（D105-R1 后为 12 项）；反证 18/18 符合预期，D105-R1 另 6/6。

修复后（含 D105-R1）的不开窗口完整门禁与 D104 一起运行，15 步全部 exit 0（2026-10-16 03:24:55–03:51:28；Release 4,946 个、Debug 5,056 个，0 失败；详见 `d104-batch-d.md`“门禁”一节）。不能据此记为通过的：57 个会开窗口的测试类、签名运行时、真实 helper 的安装与恢复、“操作记录”页的目视。

## Codex 复核记录（CODEX_C_REVIEW_20261015_1445）

以下按 Codex 的 `CANDIDATES.md` 转述，两项都是 P2。
- **C-R1**：`HardwareOperationHistory.swift:154` 把 `fanLeaseExpired`、`curveLeaseExpired`、`thermalProtectionActivated` 直接记为 `automaticRestore`，`HardwareOperationPresentation.swift:55` 据此显示风扇已交回系统。而 helper 的 `failCurveControl`（`main.swift:1481`）设置触发原因后调用 `restoreAllFans`，失败只写日志；`curveFailureReply`（1509）不论恢复成败都回同一个错误码。Codex 用两个协议合法的假回复（曲线租约到期、过热保护）证明两者都被记成已恢复。验收要求：区分确已恢复与失败、未确认；只凭触发原因不能证明成功；保留真实的成功和失败记录；用注入的恢复结果覆盖成功和失败；不用真实风扇复现。
- **C-R2**：已批准的计划 L4（计划第 302–310 行）包括“helper 自己做的租约／崩溃恢复由 App 下次连接时补记”。C 批交接（`d102-batch-c.md` 第 133 行）自行写明没有做。这是未完成的已批准项，不是待实机项；生产者自己的收窄说明不能把它记为完成。验收要求：注入 helper 的恢复结果，App 重连时记一次成功的恢复，区分失败／未确认，重复读取不重复记；root helper 不写用户文件夹；开机、崩溃、看门狗恢复不等待界面授权。

Codex 同时记录：C 批 15 步不开窗口门禁的原始结果已核实（Release 4,909 个、跳过 23，Debug 5,019 个、跳过 24，0 失败，计时 p95 98.83／94.74 ms，阈值 100 ms），但 57 个会开窗口的类没有运行，不能覆盖本次新增回归，也不能当作全界面或签名运行时验收。A-R1–A-R4、B-R1–B-R3 维持此前已验证版本的关单结论，本次没有重复修改。

## 修复

| 项 | 根因 | 改动 | 测试 |
|---|---|---|---|
| C-R1 | `HardwareOperationRecord.make` 只看错误码就记 `.automaticRestore`；helper 回同一个错误码时并不带恢复结果，App 分不出恢复成功还是失败 | helper 的自主恢复改为先恢复、再按实际结果记下（`FanControlAutomaticRestore.perform`），结果随回复报给 App。App 只在 helper 报来的结果里记“已交回”（`.automaticRestore`）或“未能交回”（新 `.automaticRestoreFailed`）；只有错误码、没有报告的回复（旧版 helper）记“是否已交回未确认”（新 `.automaticRestoreUnconfirmed`）。三种结果的界面文字分开 | Codex `IndependentBatchCReviewTests`（原样）；`HardwareAutomaticRestoreTests` 的 `testTheHelperKeepsTheResultItsReturnActuallyHad`（注入恢复结果 true／false）、`testAReasonAloneIsUnconfirmedAndAReportedReturnKeepsItsResult`、`testEachResultReadsAsWhatHappened`；`HardwareOperationHistoryTests` 1 处期望值从 `.automaticRestore` 改为 `.automaticRestoreUnconfirmed`，原期望正是 Codex 指出的错误语义，测试注释写明了改动原因 |
| C-R2 | helper 不保存、不回报自己做过的恢复；App 不在运行或没有再发请求时发生的恢复（租约到期、App 断开、helper 退出、开机恢复）都不会记下 | helper 把每次自主恢复的结果写入 root 自有的 `/var/run/<helper label>.restores`，在 ping 回复和每个失败回复里附上整份清单。App 下一次连接（ping）或收到失败回复时，按每条的 ID 各记一次；重复读取、重新连接、App 重新运行都不会重复 | `testTheAppRecordsTheHelpersOwnReturnsOnceWhenItConnects`（假 helper，见下文）、`testAStartupFailureTheHelperReportsIsRecordedOnce`、`testTheRecordKeepsAReportedReturnOnce`、`testTheListKeepsEachResultAndStaysBounded`、`testOnlyAListTheHelperCouldHaveWrittenIsRead`、`testTheHelpersCopySurvivesARestartAndRefusesAnythingElse`、`testAPowerSampleNeverCarriesTheReport`、`testTheHelperKeepsEveryReturnItMakesOnItsOwn`（源码检查） |

实现要点：
- **共享类型**（`Sources/FanControlShared/FanControlAutomaticRestore.swift`，新文件）：每条记录只有 ID、时间、原因、是否完成，不含任何标识这台电脑的信息。原因 8 种：风扇租约到期、曲线租约到期、过热保护、曲线停止、风扇状态无法核对、App 断开、helper 退出、开机恢复；新版 helper 的未知原因解码为“其他”。
- **先恢复，后记录**：`perform(_:hadControl:restore:keep:)` 先执行恢复，再用恢复的实际返回值记录；记录不会推迟或替代恢复，也不等待 App 或界面。只有确实有控制可交还时才记（手动风扇集合非空，或崩溃恢复标记存在），所以空闲 helper 的例行恢复不会产生记录。
- **记录点**：看门狗租约到期、曲线失败（按错误分为曲线租约到期、过热保护、曲线停止）、续租时 AppleSMC 不可用、续租核对风扇状态不一致（记 `restoreCompleted` 的实际值）、连接失效（App 断开）、helper 退出、开机时上一个进程留下了崩溃恢复标记（记开机恢复是否成功，即 `startupState == .ready`，等同于恢复调用的返回值）。
- **不单独记的**：App 发起的请求里的回滚（应用转速失败、开曲线失败）、App 请求的“交回系统控制”、关闭曲线。这些属于 App 自己的写操作，C 批已按回复的成功或失败记录。
- **存放**：`/var/run/<helper label>.restores`，与崩溃恢复标记同在 root 的 `/var/run`，不写任何用户文件夹。最多 16 条、8 KiB；同一原因的失败连续重试只占一条，直到有一次成功。读取用 `lstat`，只接受大小在上限内的普通文件，链接、超大文件、解码失败或条数超限都当作没有；写入为原子写，写不进去只记日志，清单仍在内存里照常回报。
- **回报**：只附在 ping 回复和失败回复上（`reply.operation == .ping || !reply.success`），从不附在功耗采样回复上；App 校验功耗采样回复时，带这个字段即视为无效回复。回复字段是可选的，没有提高协议版本：旧版 helper 不带这个字段，App 按“未确认”记。
- **App 记录一次**：协调器在本次运行中记住已保存成功的 ID（v1 是交给记录即记住，Codex 返修复核 D105-R1 指出保存失败后无法补记，已改，见下文），硬件操作记录本身按 ID 去重（跨运行有效）；每次最多取清单最后 16 条。记录的时间是 helper 报告的发生时间，不是 App 收到的时间。
- **开机恢复失败**：C 批的 App 端故障锁存在收到“开机恢复失败”回复时会自己记一条；回复带有 helper 的清单时不再自己记，避免同一事件记两次。
- **界面文字**：英文标题由“Fans returned to system control”改为“Return fans to system control”，因为这一类记录现在也可能是失败；三种结果分别显示“……，已自动交回系统”“……，但未能交回系统控制”“……，是否已交回系统未确认”。

假 helper 端到端测试（`testTheAppRecordsTheHelpersOwnReturnsOnceWhenItConnects`）：假 helper 在 ping 时报两条（租约到期、成功；过热保护、失败）。第一次连接后记录为 2 条，结果分别是 `.automaticRestore` 和 `.automaticRestoreFailed`，时间是 helper 报告的时间；同一协调器再连一次、换一个新协调器（相当于 App 重新运行）再连一次，ping 共 3 次，记录仍是 2 条；helper 追加一条（App 断开、成功）后再连，记录变为 3 条。

## 自测：验证（原始日志）

以下全部是本会话的自测，都在工作区运行，`--scratch-path` 为任务临时目录，`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`。每次测试都带只读窗口监视器，记录到的窗口数都是 0。D105 v1 的源码最后修改于 02:11:36，此后只改过测试文件（02:19:17 新增 1 项），所以下表的测试都运行在 v1 的最终源码上。D105-R1 于 03:12:23 改了协调器、03:13:24 改了测试，之后的测试见“Codex 返修复核”一节。

| 检查 | 时间（2026-10-16） | 实际结果 | 日志（`review-c-fixes/logs/`） |
|---|---|---|---|
| 编译 | 02:14:25–02:17:11 | exit 0 | `build-d2.*` |
| 定向测试 1 | 02:17:18–02:17:30 | 127 个，0 失败，0 跳过，exit 0。过滤串 12 项中 `HelperIntervalSecurityTests` 并不存在，没有匹配任何测试；当时 `HardwareAutomaticRestoreTests` 为 10 项 | `d105-t1.*` |
| Codex 过滤串 | 02:17:58–02:18:07 | 51 个，0 失败，exit 0；排除的 2 个方法与 Codex 相同（读取 `/usr/bin/true` 签名的两项） | `d105-codexfilter.*` |
| 编译 | 02:19:19–02:19:30 | exit 0（新增 `testAPowerSampleNeverCarriesTheReport`） | `build-d3.*` |
| 定向测试 2 | 02:19:30–02:19:36 | 30 个，0 失败，exit 0；`HardwareAutomaticRestoreTests` 11 项全部通过（过滤串同样含不存在的 `HelperIntervalSecurityTests`，未匹配） | `d105-t2.*` |
| 反证 | 02:21:08–02:30:33 | 18 项全部符合预期，exit 0；副本前后清单相同 | `counterproof-d105.log`、`d105-counterproof.meta`、`d105-counterproof.stdout` |
| D104＋D105 定向测试 | 02:35:26–02:36:02 | 49 个套件 621 个，跳过 3，0 失败，exit 0（编译 `build-d6` 之后；含本表全部 D105 套件） | `d104-d105-t1.*` |

Codex 回归测试修复前后的输出：修复前两个假回复（曲线租约到期、过热保护）都得到 `automaticRestore`，2 处断言失败；修复后两者都是 `automaticRestoreUnconfirmed`，测试通过。

**跳过的 3 个**（D104＋D105 定向测试）都需要显式设置环境变量才运行，会读本机真实目录：`CleanupRuleScannerTests` 的两个本机采集测试、`FileAnalysisTrashCostTests.testTheLinkResolverOnThisMachinesHomeWhenAskedTo`。

**编译警告**：编译中出现的警告都不在 D105 的文件里。`ProjectArtifactTests.swift:163`、`OperationConfirmationContractTests.swift:123`、`HeavyWorkActivityStoreTests.swift:103` 在 A 批开始前的基线日志（`batch-a/logs/verify-previous-d99.log`）里已有；`MSeriesV11PagePresentationTests.swift:317` 从 A 批门禁日志起出现，该文件本身未改。

## 自测：反证

在工作区的逐字节副本（`d-cp`，建立时 1,738 个文件，与当时工作区的清单相同）上运行；D105 的 9 个文件与工作区逐字节相同。先跑基线：2 个套件 12 个测试 0 失败，删除与进程清单检查通过（155 条、246 处）。之后每项把一处修复改回原写法或改坏，只跑守护它的测试，预期失败；`H1`、`H2` 是等价的另一种写法，预期通过。每项结束后从备份逐字节恢复并核对哈希，全部为 OK；最后副本的完整清单与开始时相同。窗口监视器记录到的窗口数为 0。

| 项 | 改动 | 守护测试 | 预期 | 结果 |
|---|---|---|---|---|
| R1a | 只有原因也记为已交回（回到修复前） | Codex `IndependentBatchCReviewTests` | 失败 | 失败（2 处断言） |
| R1b | helper 报告失败的恢复也记为已交回 | `HardwareAutomaticRestoreTests` | 失败 | 失败 |
| R1c | 在恢复之前就记下“成功”，不用实际结果 | 同上 | 失败 | 失败 |
| R1d | 失败的恢复显示“已自动交回系统” | 同上 | 失败 | 失败 |
| R1e | 同一原因的失败重试每次都新增一条 | 同上 | 失败 | 失败 |
| R2a | App 忽略 helper 报来的恢复 | 同上 | 失败 | 失败 |
| R2b | 记录不按 ID 去重 | 同上 | 失败 | 失败 |
| R2c | helper 已报告开机恢复失败，App 的故障锁存仍再记一条 | 同上 | 失败 | 失败 |
| R2d | 改写回复文字时丢掉报告 | 同上 | 失败 | 失败 |
| R2e | ping 回复不带报告 | 同上（源码检查） | 失败 | 失败 |
| R2f | 记录文件放到用户主目录 | 同上（源码检查） | 失败 | 失败 |
| R2g | 看门狗的恢复不记 | 同上（源码检查） | 失败 | 失败 |
| R2h | 开机恢复的结果不记 | 同上（源码检查） | 失败 | 失败 |
| R2i | 功耗采样回复可以带报告 | 同上 | 失败 | 失败 |
| R2j | 读取记录文件时跟随链接 | 同上 | 失败 | 失败 |
| R2k | 读取超过 16 条的清单 | 同上 | 失败 | 失败 |
| H1 | 记录写成 `guard` 形式（等价） | 同上 | 通过 | 通过 |
| H2 | ID 去重改用 `first(where:)`（等价） | 同上 | 通过 | 通过 |

所有“失败”都是断言失败，不是编译错误（日志里每项都有对应的 `error: -[...]` 行）。C 批反证中的 L4d 锚点（`if let errorCode, errorCode.isAutomaticRestore {`）在 D105 之后已不存在，由本表的 R1a 取代；C 批反证的原始记录不改。

## Codex 返修复核（CODEX_D105_REVIEW_20261015_1608）：D105-R1

来源：Codex 的 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/review-c-fix-20261016/`（`FINDINGS.md`、`RECHECK.md`、`history_retry_probe.swift`、`history_retry_probe.log`）。Codex 在 2026-10-16 03:08（AEDT）核对这 9 个文件与本文 v1 的哈希一致，随后报告 1 项 P2，C-R2 因此仍未关闭。本次只读了该目录，没有改动；证据目录 `codex-review-r1/` 存有其中文本文件的副本（不含编译出的可执行文件）。

- **问题**（转述 Codex）：`FanControlCoordinator.recordHardwareOperation` 在后台保存成功之前就把这条恢复的 ID 记为“已记录”；保存抛错时只写日志，ID 仍留在集合里。历史文件的读取、建目录或原子写入失败后，即使之后存储恢复，同一次运行里 helper 再报告这一条也会被跳过，要等 App 重新运行才可能补记。Codex 把这两个方法体逐字复制到可执行探针里，配一个先拒绝写入、再接受写入的假历史，结果 exit 1：`replayedOriginalSaved=false writeAttempts=2`。
- **修复**：只有保存成功后才把 ID 记为已记录。保存进行中的 ID 另放在 `savingAutomaticRestoreIDs` 里，同一条在保存途中再被报告时不重复保存；保存失败后把它移出，helper 下次报告这一条时（下一次连接或失败回复）重新保存。`saveHardwareRecord` 把保存是否成功交回调用方；没有注入历史时不进入这段。请求不等待保存，helper 的恢复也与 App 的记录无关；记录文件本身仍按 ID 去重，即使两次保存同时进行也只留一条。
- **测试**：新增 `HardwareAutomaticRestoreTests.testAReturnWhoseSaveFailedIsRecordedWhenTheHelperReportsItAgain`，项目内的集成测试，用假 helper 和真实的 `HardwareOperationHistory`。在测试自己的临时文件夹里用一个普通文件占住记录文件夹的位置，读取和保存都会真实地失败。步骤：连接两次（保存失败，连接照常完成）；删掉这个文件；同一个协调器再连接一次，记录里有这一条且只有一条，结果和时间都是 helper 报告的；helper 再报告一条新的恢复，连接一次后两条都在；再连接两次，仍是两条。Codex 的 `IndependentBatchCReviewTests`（C-R1 回归）和原有的重连、跨运行去重测试都没有改。
- **等待方式**：删掉那个文件之前，测试先让记录读取三次，三次都失败。记录（actor）按顺序处理调用，所以这时先前发出的保存都已失败，协调器也已收到失败；之后的连接才会重试。这依赖运行时按顺序处理同优先级的调用。为确认稳定，这个测试单独连续运行了 20 次，全部通过。

| 检查 | 时间（2026-10-16） | 实际结果 | 日志（`review-c-fixes/logs/`） |
|---|---|---|---|
| 编译 | 03:13:39–03:15:02 | exit 0，0 条警告（同时编入 D104 新增的 1 项测试） | `build-d9.*` |
| 定向测试 | 03:15:10–03:15:17 | 122 个，跳过 2（`CleanupRuleScannerTests` 的本机采集测试，需要显式设置环境变量），0 失败，exit 0；过滤串里的 `FanControlStartupRecoveryTests` 并不存在，没有匹配 | `d105r1-t1.*` |
| Codex 过滤串 | 03:15:22–03:15:28 | 51 个，0 失败，exit 0；排除的 2 个方法与 Codex 相同 | `d105r1-codexfilter.*` |
| 新测试连续 20 次 | 03:15:40–03:16:09 | 20 次全部 exit 0，每次 1 个测试 0 失败 | `d105r1-repeat.*` |
| 反证 | 03:18:14–03:22:45 | 6/6 符合预期：F1–F5 都在断言上失败（不是编译错误），H1 通过；每项之后被改的文件按字节还原并核对哈希，结束时副本清单与开始时相同；窗口监视 0 个窗口、0 违规 | `counterproof-d105r1.log`、`d105r1-counterproof.meta`、`d105r1-counterproof.stdout` |

反证在工作区的逐字节副本上运行（建立时 1,740 个文件，与当时工作区的清单相同），基线是 `HardwareAutomaticRestoreTests` 12 个测试全部通过、删除与进程清单检查通过（155 条、246 处）。

| 项 | 改动 | 守护测试 | 预期 | 结果 |
|---|---|---|---|---|
| F1 | 保存之前就记为已记录（即 Codex 复核的写法） | 新测试 | 失败 | 失败 |
| F2 | 保存失败后不移出“保存中” | 新测试 | 失败 | 失败 |
| F3 | 不论保存成败都记为已记录 | 新测试 | 失败 | 失败 |
| F4 | 保存失败也报告为成功 | 新测试 | 失败 | 失败 |
| F5 | App 忽略 helper 报来的恢复（原 R2a，锚点随本次改动更新） | `HardwareAutomaticRestoreTests` | 失败 | 失败 |
| H1 | 去掉“保存中”集合（记录文件按 ID 去重，结果相同，只多一次读取） | `HardwareAutomaticRestoreTests` | 通过 | 通过 |

H1 说明“保存中”集合只省掉重复的读取，不重复记录靠的是记录文件按 ID 去重（D105 反证 R2b 守护）。

**JEV 复核**（辅助，不当作通过；2026-10-16 03:57 前后）：只传了 D105-R1 的差异、新测试的步骤和自测摘要，没有传凭据或个人数据。结果：正确性 1.81/2（置信度 0.71）、规格符合度 1.96/2、测试缺口 0.25、影响面 1.15（置信度 0.33），`safe_to_apply` 0.69，综合 0.851，判定 escalate（影响面一项置信度低于 0.5，需要人工复核），没有指出具体缺陷。结论交给 Codex 独立复核。

**本次仍未做到的**：App 自己发起的写操作（D102 L4 的记录）保存失败时只写日志，没有来源可以重报，沿用 D102 的设计，不在这次范围内。

## 差异与哈希

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/review-c-fixes/`。`README.md` 说明各文件，`SHA256SUMS.txt` 覆盖目录内全部其他文件。

- `snapshots/review-c-fixes.diff`：以 Codex 复核用的 `c-gate-tree` 为基准，本次 9 个文件现在的差异（新文件以 `/dev/null` 为基准）；`snapshots/v1/` 是交给 Codex 复核的 v1；`snapshots/d105r1.diff` 是 v1 到现在的差异（2 个文件）。
- `snapshots/review-c-fixes-files.sha256`：每行是“修复前 修复后 路径”，修复前取自 `c-gate-tree`，新文件写 `absent`。
- `snapshots/c-gate-tree-vs-worktree.txt`：`c-gate-tree` 与整理时工作区全部不同的文件。除本次 9 个外，其余是 D104 的源码和测试，以及门禁之后改过的文档；D104 与 D105 没有共同文件，所以这 9 个文件的差异只有本次返修。

下表“修复后”为现在的版本（v2，含 D105-R1）；与 v1 不同的两个文件另列 v1 的哈希。

| 文件 | 修复前 | 修复后 |
|---|---|---|
| `Sources/FanControlShared/FanControlAutomaticRestore.swift` | 新文件 | `31788e21039e12e676b80ecf524fbda9b9fe3b50f2493e41e2d433fb5a0cae88` |
| `Sources/FanControlHelper/main.swift` | `034a181a…` | `91a95c78fbd6282793885e4eaee8b29137621e3ce66a06c50eb378b1d097191d` |
| `Sources/StorageCleanerMac/Models/FanControlModels.swift` | `3e3cc616…` | `364d32de0a63dfc198be1fd359ec34dd61172322022111cd64ccb559bc7ff30a` |
| `Sources/StorageCleanerMac/Models/HardwareOperationPresentation.swift` | `5ee9527a…` | `374ee695e58d1d3f5e10ce555ef54fef82d7a0ca0580aea051143ac12a78ac9b` |
| `Sources/StorageCleanerMac/Services/FanControlCoordinator.swift` | `c09ad5d6…` | `8d01cadcf8b343c6840e8a1cb644592074e826fa2bed5d65a678f2df4c83735e`（v1 为 `8eb279019fb892821d9420f627ea4eb6ed988d94891fe0c8c88e33fdbd380302`） |
| `Sources/StorageCleanerMac/Services/HardwareOperationHistory.swift` | `3bba74c3…` | `6368cd38cb86b707960d90e57d24bf5b43539218353fc70d6af3802936d93c2a` |
| `Tests/StorageCleanerMacTests/HardwareOperationHistoryTests.swift` | `10579dcb…` | `02362c4657242c05503101bc1e977f2426043f4a1f858ec638d6a6b00ee93302` |
| `Tests/StorageCleanerMacTests/HardwareAutomaticRestoreTests.swift` | 新文件 | `c84f527b0919dc08c777c22031a7142faa8ab88cf64c696487bdca9d3515c4c7`（v1 为 `7e713ceab7b98ffeed3b868ddd609188a3c7983346472e0cb4b098bc895930a4`） |
| `Tests/StorageCleanerMacTests/IndependentBatchCReviewTests.swift` | 新文件（Codex） | `e312addfa583fa1c89d743eaf95b251045113473b3eeb5dc4697a835484e3c04`（与 Codex 复核目录中的文件相同） |

## Codex 最终复核（CODEX_FINAL_RECHECK_20261015_1710）

来源：Codex 的 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/review-c-fix-r1-20261016/`（`RECHECK.md`、`RESULT.json`、`RUN.json`、`PACKAGE_AUDIT.json`、`JEV_RESULT_RECHECK.json`、`swift-targeted.log`）和 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/final-gate-20261016/AUDIT.json`。本次只读了这些文件，没有改动。以下转述 Codex 的结论，不是本会话的结果。

- **结论**：C-R1、C-R2、D105-R1 在源码与隔离测试层面关闭。这不是实机或发布验收。
- **独立运行**：Codex 用前一次 C 批快照加本文 v2 的 2 个改动重建 C 批冻结副本（1,736 个文件，前后哈希不变），运行原 7 个类加 `HardwareAutomaticRestoreTests`：63 个方法 0 失败、0 运行时跳过，exit 0；2026-10-16 03:52:32–03:57:50（AEDT；UTC 16:52:32–16:57:50）；日志 SHA-256 `be3edd32c9b94e94d9d5334e28c986cd10cb69ac1c0a7446e50ee87d6ff99855`。排除的 2 个系统签名方法（`testSecurityHonoursEachClause`、`testRequirementRefusesAnotherIdentifierLeafCertificateOrTeam`）没有运行，不算通过，也不算运行时跳过。Codex 的原 C-R1 回归测试仍与原文件逐字节相同；新的集成测试（真实记录保存失败、同一协调器重连补记）通过。03:59:54 时 9 个修复文件仍与工作区一致。
- **Codex 核对的其他记录**：本会话的自测结果（122 个、51 个、20 次连续运行、反证 6/6）是生产方结果，不是 Codex 独立执行；新测试按调用顺序等待的前提已在本文写明，连续通过只是佐证，不是对执行顺序的一般保证。证据包 `review-c-fixes/` 的 78 条校验和全部匹配（清单 SHA-256 `47085923…`）。最新整合门禁的原始结果经 Codex 核实（见 `d104-batch-d.md`）。Codex 的第一次探针失败结果保留在其 `review-c-fix-20261016/` 目录，没有改写。
- **JEV（Codex 调用）**：源码复核判定 escalate（`safe_to_apply` 0.14），没有指出具体缺陷；新执行结果的 3 条证据都核实。Codex 不把模型分数当作批准，关闭依据是直接源码复核和独立测试。

## 仍未通过、未做或待实机

- 修复后的完整门禁已与 D104 一起跑过（不开窗口，03:24:55–03:51:28，15 步全部 exit 0，冻结副本含 D105 v2 的 9 个文件，哈希与上表相同），结果和原始日志见 `d104-batch-d.md` 与证据 `batch-d/logs/gate/`。C 批门禁的原始结果（2026-10-16 00:35–01:08，exit 0）对应的是修复前的代码，不覆盖本次改动。
- 57 个会开窗口的测试类没有跑，也没有窗口在显示前定位到 Codex 虚拟屏的证明（窗口监视器只是定期观察）；“操作记录”页三种结果的显示没有目视。
- Codex 独立运行时排除的 2 个系统签名方法没有运行，不算通过。
- **待实机**（需要用户另行批准安装 Beta、启用 helper）：安装后的 helper 能写入 `/var/run/<label>.restores`；真实的租约到期、过热保护、App 断开、helper 退出后，App 重连时的“操作记录”能列出对应结果；helper 崩溃后由 launchd 重新拉起时的开机恢复记录。`/var/run` 在 macOS 重启后是否保留没有核实：若重启时被清空，重启前发生、App 还没读到的恢复记录会和崩溃恢复标记一起消失，重启后也就没有开机恢复可记；重启是否让风扇回到系统控制同样没有在本机核实。
- 恢复只在 App 之后再次连接 helper（ping）或收到失败回复时补记；App 一直不再连接，记录就留在 helper 的清单里（最多 16 条，旧的被挤掉）。
- 签名运行时（L1、L2、L7 的真实签名校验）仍待实机，本次没有改动这部分。

## 复核方法

```bash
cd /Users/developer/Developer/sc-worktrees/v2.0.1
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --build-tests --scratch-path <私有临时目录>
swift test --skip-build --scratch-path <同一目录> \
  --filter 'StorageCleanerMacTests\.(IndependentBatchCReviewTests|HardwareOperationHistoryTests|FanControlPeerRequirementTests|FileOperationPeerRequirementTests|FanControlProtocolSafetyTests|HelperUpgradeSafetyTests|MacMiniModePackagingTests)/' \
  --skip 'testSecurityHonoursEachClause|testRequirementRefusesAnotherIdentifierLeafCertificateOrTeam'
swift test --skip-build --scratch-path <同一目录> --filter 'StorageCleanerMacTests\.HardwareAutomaticRestoreTests/'
swift test --skip-build --scratch-path <同一目录> \
  --filter 'StorageCleanerMacTests\.HardwareAutomaticRestoreTests/testAReturnWhoseSaveFailedIsRecordedWhenTheHelperReportsItAgain'
```
第一条与 Codex 的命令相同；D104＋D105 定向测试的完整过滤串在 `logs/d104-d105-filter.txt`（49 个套件）。
