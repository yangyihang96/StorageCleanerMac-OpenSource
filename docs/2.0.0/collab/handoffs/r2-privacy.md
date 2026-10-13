# 批次 r2-privacy：浏览器隐私可辨认（D20）

- 分支：`task/r2-privacy`，基于集成分支 `2ac7902`；worktree `~/Developer/sc-worktrees/r2-privacy`；scratch `~/Developer/.sc-build/r2-privacy/`（日志在 `logs/`）。
- 第一轮实现：Claude 子代理（Claude Fable 5.1），提交 `55a57cb`…`909fe77`。主会话复核：需小修后合并，无 P0；保留 `36dd431`、`7f73f4a`。第二轮修复：Claude 子代理（Claude Opus 5.5），提交 `7c51293`…`3b6d053`。主会话第二轮增量复核：数据安全核心路径正确，需小修后合并（1 个 P1）。第三轮修复：Claude 子代理（Claude Opus 5.5），提交 `f58bdea`…（见下一节）。
- 结论（第三轮后）：任务卡 1–10 项、第二轮的 P1-1、P1-2、P2-1…P2-11、第三轮的 P1-B1、P2-B1…P2-B6、P3 全部已修，每项都有先红后绿的测试或反向变异证据。所有改动只在临时目录的假数据库上验证，**没有在真实 Safari／Chrome 数据上做过删除或恢复**，实机核对清单见第 6 节（第二、三轮已补充）。
- 阅读顺序：先看"第三轮"一节（当前状态），再看"第二轮"；第 1–9 节是第一轮记录。被后一轮改变的说法已就地标注"第二轮更正"，或列在第三轮的"对第二轮记录的更正"里。

## 第三轮：增量复核意见修复（2026-10-05 凌晨）

规则不变：每项先写能复现的测试（红）再改（绿），对既有行为的保护测试用反向变异证明它能发现问题；没有删断言、没有放宽阈值、没有新增跳过；没有读取真实 Safari／Chrome 数据，没有启动应用、没有截图；没有改 `Stores/ScanStore.swift`、`DECISIONS.md`、`BOARD.md`；沿用原 scratch，没有新建构建目录。第三轮没有修改任何已有测试，只新增测试。

### 提交

| 提交 | 内容 | 对应项 |
|---|---|---|
| `f58bdea` | 应用运行期间按最早到期时间定时清理到期备份（到期后约 1 秒，最长每小时再查一次，连续时钟），时钟与等待可注入 | P1-B1 |
| `4eba22f` | 恢复时保存当前状态不再挤掉恢复源；恢复过的备份与结果未知的备份不计入 12 份（仍按 7 天到期）；结果未知的文案改为"请在到期前核对" | P2-B1、P2-B5 |
| `cd13982` | "最近的删除"删除备份失败时在该行提示；页面忙时删除按钮和弹层确认按钮禁用（与恢复同条件） | P2-B2 |
| `ee8aeaf` | 每次恢复之后的列表刷新也豁免恢复源（覆盖恢复失败、未标记"已恢复"的情况） | P2-B1 失败路径 |
| `34265fe` | 展开行的完整网址、手动处理页的页面行不再可选中；PRIVACY.md 与 Parity Matrix 对应 | P2-B3 |
| `15aa983` | 恢复根目录排除在时间机器之外，设置不上就不备份、不删除；PRIVACY.md 如实描述 | P2-B4 |
| `35b8b93` | 符号链接、非 UUID 命名项、UUID 命名的普通文件不会被到期清理或手动删除的测试；删除恒为真的父目录检查 | P2-B6 |
| `364b936` | 非网页地址的 `#片段` 同样折叠；保存的状态改称"恢复备份之前自动保存的状态" | P3 |
| （本提交） | 交接第三轮 | — |

`git diff --shortstat 3b6d053 364b936`：12 个文件，+748 / −75。整批 `2ac7902 364b936`：26 个文件，+7581 / −886（不含本交接提交）。

### 逐项

**P1-B1 到期清理不按时 —— 已修（`f58bdea`）**
- 二选一的选择：按最早到期时间安排下一次清理，并给单次等待加 1 小时上限。到期后约 1 秒删除（计时器容差 10 秒），与"最近的删除"每行"T 自动删除"一致；上限让之后新建的备份、被改动的系统时间、长时间睡眠都在 1 小时内被发现，不必在新建备份时另外通知计时器。
- 实现（`Features/BrowserPrivacy/Support/BrowserPrivacyRecoveryMaintenance.swift`）：`BrowserPrivacyRecoveryPurgeSchedule.wait(untilEarliestExpiry:now:)`——下一次 = 最早到期 + 1 s，最长 3600 s；没有备份，或已到期却删不掉的备份 → 3600 s，避免空转。`BrowserPrivacyRecoveryPurgeLoop`（`now`、`sleep` 注入）：清理 → 计算等待 → 睡眠，直到任务取消或 `sleep` 抛错。`enableAndPurge()`（应用启动时调用一次）以 utility 优先级启动循环，用 `ContinuousClock().sleep(for:tolerance:)`：连续时钟在 Mac 睡眠时继续计时，醒来后立即处理期间到期的备份。打开本页与打开"最近的删除"时的清理保留。服务新增 `earliestExpiry()`（包括正在写的备份）。
- 测试：`BrowserPrivacyRecoveryTests.testExpiredBackupsAreRemovedOnTimeWhileTheAppKeepsRunning`——两份备份相隔 3 天，假时钟从第一份到期前 90 秒起跑（为缩短测试把上限设为 2 天）；断言 4 次等待依次为 91 s、2 天、1 天、2 天，每次等待时磁盘上剩下的备份，以及第一份在到期后 1 秒被删。`testScheduledChecksWaitForTheNextExpiryButNeverMoreThanAnHour`——31 s、1 小时上限、无备份、删不掉的过期备份；源码契约：启动即启动循环、使用连续时钟。红：`logs/r4-red-phase.log`（旧行为只清理一次：0 次等待；期望 31 s 得到 3600 s；启动不安排）。

**P2-B1 满 12 份时恢复最旧的一份会裁掉恢复源 —— 已修（`4eba22f`、`ee8aeaf`）**
- 三层：① 处理器在恢复成功或"失败但可能已改动"时描述保存的状态，随之而来的裁剪豁免本次恢复源（`annotate(_:summary:sparing:)`）；② 恢复成功、已标记"已恢复"的备份此后不计入 12 份——浏览记录此刻与它一致，留到 7 天到期；③ 每次恢复（无论成败）之后的列表刷新也豁免恢复源（`BrowserPrivacyRecoveryStore.restore` → `refresh(sparing: [entry.id])`）。
- 测试：`testRestoringTheOldestBackupAtTheLimitKeepsThatBackup`——上限 2、两份删除备份，恢复最旧的一份：成功、该备份仍在并标记已恢复、保存的状态在、之后再按上限清理一次仍在。红：恢复源被裁掉。①②各自必要，反向变异证明：去掉 sparing → 失败（`logs/r4-sparing-mutation.log`）；恢复过的仍计数 → 失败（`logs/r4-restored-mutation.log`）。`testTheListRefreshAfterARestoreSparesItsSourceWhateverTheResult`（红：`logs/r4-refresh-sparing-red.log`）。

**P2-B2 删除备份失败无提示、忙时可点 —— 已修（`cd13982`）**
- `BrowserPrivacyRecoveryStore.failedRemovalID`：删除失败时记下该备份，该行下显示"没能删除这份备份，请稍后再试。"，下一次操作清除。删除图标按钮和弹层内的确认按钮都改为 `.disabled(isBusy || recoveryStore.isWorking)`，与恢复按钮相同（页面扫描或删除中、或正在恢复/删除备份时不可点）。
- 测试：`testRecentDeletionsSaysWhenABackupCouldNotBeDeleted`——用 UUID 命名的普通文件顶替备份目录，删除失败：`failedRemovalID` 被设上，`clearResult()` 后清除；源码契约：行下提示、不再有只看 `isWorking` 的禁用条件。红：`logs/r4-red-phase.log`。

**P2-B3 ⌘C 绕过隐藏标记 —— 已修（`34265fe`）**
- 去掉展开行"完整网址"和手动处理页页面行的 `.textSelection(.enabled)`；手动处理页的网站名称列表保留可选中（复核允许）；"复制网址"按钮不变。PRIVACY.md（中英）：页面标题和网址不能作为文字选中，只能用"复制网址""复制域名"复制；只有手动处理页的网站名称列表可以作为普通文字选中复制。Parity Matrix 第 51 行同步。
- 测试：`PrivacyCleanupPresentationTests.testCompleteAddressesAndPageListsCannotBeSelectedAsText`——结果视图只剩 1 处可选中且在网站名称列表上，其余浏览器隐私视图没有；PRIVACY.md 措辞。红：3 处可选中。

**P2-B4 时间机器 —— 已修（`15aa983`）**
- 写备份前给恢复根目录（`…/BrowserPrivacyRecovery/v1/`）设置 `isExcludedFromBackup`；设置失败按"备份失败"处理：不建备份、不删除任何记录。旧版本留下的、没有该标记的目录，在下一次到期清理（启动、定时、打开本页）时补上（只对真实目录，不跟随符号链接）。
- PRIVACY.md（中英）删除"Backups never leave this Mac／备份不会离开这台 Mac"，改为：备份不上传，所在文件夹排除在时间机器之外（其他备份软件不一定遵守）；时间机器里可能已有浏览器自己历史数据库的早期副本，本应用不改动它们。"最近的删除"顶部说明与 Parity Matrix 同步。
- 测试：`testRecoveryFolderIsExcludedFromTimeMachine`——删除后恢复根目录带标记；旧目录在一次到期清理后带标记；PRIVACY.md 措辞。红：标记为 false。"标记设不上即不备份"这条路径没有专门测试（临时目录里无法让 `setResourceValues` 失败）。

**P2-B5 结果未知的备份 —— 已修（`4eba22f`）**
- `BrowserPrivacyRecoveryOutcome.leavesTheResultUnknown`（restoreUnconfirmed、unexpectedError）：不计入 12 份，仍按 7 天到期。"最近的删除"文案："删除结果未能确认，请在这份备份到期前重新扫描核对，需要时用它恢复"、"处理时出现未预期的错误，不知道 N 次访问（M 个页面）是否已删除；请在这份备份到期前重新扫描核对"；报告里 restoreUnconfirmed、unexpectedError 两个原因也改为"在删除前的备份到期前（7 天内）重新扫描核对，需要时在'最近的删除'里恢复"。`unverified`（已提交、最后复核未通过）不在复核清单里，仍计入上限，文案本来没有"请保留"。
- 测试：`testBackupsWithAnUnknownResultAreNeverPrunedButStillExpire`——上限 1，两份结果未知 + 两份已删除：只裁掉较早的已删除；8 天后 3 份全部到期删除。`testBackupsWithAnUnknownResultAskForACheckBeforeTheyExpire`——中英文不含"保留／keep this backup"，含"到期前／before"。红：未知结果被裁到 1 份，文案含"请保留"。

**P2-B6 符号链接与非 UUID 项 —— 已补测试（`35b8b93`）**
- `testOnlyRealBackupFoldersAreEverExpiredOrRemoved`：恢复根目录里放一个指向外部目录、以 UUID 命名的符号链接，一个非 UUID 名的目录，一个 UUID 名的普通文件（都标为 30 天前创建），和一个真实的、早已过期的备份目录。到期清理只删真实目录；按 ID 删除链接和文件都返回失败并原样保留；链接指向的外部文件不受影响。这是对既有行为的保护测试，修前修后都通过；去掉 `remove(backupID:)` 的目录检查（反向变异）后 4 处断言失败（`logs/r4-folder-safety-mutation.log`）。
- `remove(backupID:)` 删掉恒为真的"父目录等于恢复根目录"条件，注释写明真正起作用的保护：路径由根目录加 UUID 拼出，所以总在根目录下一级；`lstat` 不跟随链接，不是真实目录的一律不删。

**P3 —— 已修（`364b936`）**
- 非网页地址（chrome://、file://、about: 等）和无法解析的地址：`?` 或 `#` 之后的内容折叠为"?…"或"#…"（之前只折叠查询，`#access_token=…` 会出现在行内和悬停提示里）；网页地址不变（域名＋路径，查询折叠，片段不显示）；展开行仍显示完整网址。
- "恢复较早的备份之前自动保存的状态" → "恢复备份之前自动保存的状态，用它可以撤销那次恢复"（恢复最新一份时也会保存状态）。
- 测试：`testFragmentsOfOtherAddressesAreFoldedLikeQueries`、`testTheSavedStateIsDescribedTheSameWhicheverBackupWasRestored`。红：片段原样显示，文案含"较早"。

### 命令与结果（第三轮）

环境同前（`DEVELOPER_DIR=…/Xcode-27.0.0-Beta.app/…`，`swift test --scratch-path ~/Developer/.sc-build/r2-privacy/debug --jobs 4 --skip-update --disable-automatic-resolution`）。"定向"指 `--filter 'BrowserPrivacy|PrivacyCleanupPresentationTests'`。

| 步骤 | 范围 | 结果 | 日志 |
|---|---|---|---|
| **红阶段**（新测试对未修实现；P1-B1 用保持旧行为的桩以便编译） | 定向 | 200 执行 / 1 跳过 / **37 处断言失败，分布在 10 条新测试**；P2-B6 的保护测试按预期通过；exit 1 | `logs/r4-red-phase.log` |
| 各提交前一刻 | 定向 | 191（`f58bdea`）→ 194（`4eba22f`）→ 195（`cd13982`）→ 196（`ee8aeaf`）→ 197（`34265fe`）→ 198（`15aa983`）→ 199（`35b8b93`）→ 201（`364b936`）执行，均 1 跳过 / 0 失败，exit 0；尚未修的项的新测试暂不纳入，随修复一起提交 | `logs/r4-p1-b1.log`、`r4-p2-b1-b5.log`、`r4-p2-b2.log`、`r4-refresh-sparing.log`、`r4-p2-b3.log`、`r4-p2-b4.log`、`r4-p2-b6.log`、`r4-p3.log` |
| 红：刷新豁免（`ee8aeaf`） | 单测 | 2 处断言失败，exit 1 | `logs/r4-refresh-sparing-red.log` |
| 反向变异 | 单测 | 去掉 sparing：失败；恢复过的仍计数：失败；去掉目录检查：4 处断言失败；每次改动前先备份源文件，跑完从备份还原并 `cmp` 核对一致 | `logs/r4-sparing-mutation.log`、`r4-restored-mutation.log`、`r4-folder-safety-mutation.log` |
| 布局与 UI 守卫（`364b936`） | 同前 | 81 执行 / 0 失败，exit 0 | `logs/r4-final-ui.log` |
| **Debug 全量**（`364b936`，最终代码） | 全部 | **3269 执行 / 21 跳过 / 0 失败**，测试 178 s，总 180 s；负载（1 分钟）3.2→3.9；跳过名单与第一轮相同；上一轮超时的计时测试本次 10.1 s 通过；exit 0 | `logs/r4-full-debug.log` |
| 私有接口检查 | `python3 script/check_private_api.py` | passed（6 allowlisted uses），exit 0 | — |
| 空白检查 | `git diff --check 2ac7902..HEAD`、工作区 | exit 0 | — |
| 严格并发构建、Release 全量、门禁脚本 | — | NOT RUN（同第二轮说明） | — |

### 对第二轮记录的更正
- 第二轮 P1-1"删除范围限定"里"且父目录正是恢复根目录才删除"不是额外保护（恒为真，代码已删除）；真正的保护是路径由根目录加 UUID 拼出、`lstat` 不跟随链接、只删真实目录（第三轮已有测试）。
- 第二轮"已满 12 份时恢复最旧的一份，新增的'恢复前状态'会把刚恢复的那份挤掉"已修（P2-B1），不再成立；"保存的状态也计入 12 份"仍成立，但恢复过的、结果未知的备份不计入。
- 第二轮 P1-1"调用点：启动、打开本页、refresh"——现在启动后按到期时间定时清理（P1-B1）。
- 第二轮"恢复较早的备份之前自动保存的状态"已改（P3）；"请保留这份备份"类文案已改（P2-B5）。
- 第二轮"备份不会离开这台 Mac"的说法已改为如实描述（P2-B4）。
- 第二轮的决定草案编号 D29–D32 作废（D29–D33 已被批次 4b 占用，集成分支 `9d87578`），改用下方 D34–D37。

### 决定草案（由主会话写入 DECISIONS.md；编号按主会话指定）
- **D34**（`36dd431`）："Chromium 系直接删除接受数据库旁 0 字节的普通 `-journal` 文件；有内容的 journal、符号链接 journal 以及任何 `-wal`／`-shm` 仍视为未合并写入而拒绝；sidecar 只在写入前（浏览器退出后、打开写连接前）检查，不在扫描时决定可删性。"取代 1.9.10 的"sidecar 全部不存在"门槛。
- **D35**（`7f73f4a`）："已同步到账号的 Chromium 访问（`is_known_to_sync` 或任一 `originator_*`）在扫描时就标为浏览器内处理并写明原因，不拖累同一配置文件里其他记录的直接删除；处理器写入前再查一次。"
- **D36**（`69ad817`、`3c054c9`、`4eba22f`、`ee8aeaf`）："恢复前先把当前历史数据库另存为一份备份（保留规则同 D26），恢复可撤销；保存失败不开始恢复。恢复提示写明会丢弃之后新增的浏览记录和下载列表、之后删除的记录会重新出现；恢复的不是该配置文件最新的一份备份时再确认一次，并说明会一并撤销几份。恢复结果使用独立的原因与文案，不借用删除文案。恢复源不会因这次恢复被数量上限裁掉。"
- **D37**（`2824b37`、`d485f78`）："Chromium 整页删除在 History 数据库内按 Chromium 自身删除历史的流程处理依赖行与 URL 行；已同步的访问交由浏览器（D35）；悬空的 opener_visit／from_visit／segment_id 与 Chromium 一样不处理。与 Chromium 的三处差异如实写在文档：加书签（固定）网址的 urls 行本应用会删除；重定向上游访问不连带删除，作为独立页面由用户选择；Favicons 等其他存储不处理。"取代 1.9.9 验收记录第 12 节"最后一条 visit…fail closed"。
- **D26 补充**（备份生命周期；`7452b3c`、`5358d50`、`b17f4cc`、`f58bdea`、`4eba22f`、`ee8aeaf`、`15aa983`）："数据库未改动的失败立即删除刚建的备份；成功、结果未确认、未预期错误和恢复前保存的备份保留，元数据只记录浏览器名、配置文件名、条数与结果，不含网址与标题。到期清理在应用启动后按最早到期时间定时进行（到期后约 1 秒，最长每小时再查一次），打开本页时也清理。12 份上限只计算结果已知、未被恢复过的备份，在删除成功写完摘要后才裁剪，且不裁掉正在恢复的备份；结果未知（恢复未确认、未预期错误）和恢复过的备份不计入上限，仍按 7 天到期；进行中的备份不计数、2 分钟内不列出。恢复根目录排除在时间机器之外，设置不上就不备份、不删除。删除备份为直接删除、不进废纸篓。"
- 原第一轮 D25（处理原因枚举化、扫描记录不能直接删除的原因、同一配置文件可删与手动部分分别处理）属实现细节，如需登记请主会话另行编号。
- 过程说明（复核记录 b-notes）：第二轮按 P1-2 修改的两条旧测试依据的是本节 D36 草案，登记后即有据可查。

### 第三轮之后的未完成与风险
- 全部只在临时目录的假数据库上验证；新增的实机核对项见第 6 节第 13–18 条。
- 恢复失败（可能已部分改动）时，恢复源只在这次恢复与紧随的刷新里豁免，没有标记"已恢复"；之后定时按上限裁剪时，它按普通备份处理（恢复前保存的状态仍保留，可撤销）。
- 恢复过的、结果未知的备份不计入上限，所以磁盘上的备份可能多于 12 份，但每份都在 7 天后删除。
- 定时清理与一次恢复之间有毫秒级窗口：处理器写完保存状态的说明之后、Store 标记"已恢复"之前，若恰好赶上定时清理且已超上限，最旧的恢复源仍可能被裁。概率极低，未处理。
- "进行中的备份 2 分钟内不列出"按墙上时间判断，系统在删除途中睡眠可能让它提前出现在列表里（显示为"未记录删除了多少条"）；未改（复核 P3 备注，不在本轮清单）。
- 定时清理每次运行都会重新设置一次时间机器排除标记（幂等，开销可忽略）。
- 删除备份不进废纸篓，误删即失去那次删除的恢复能力（确认里写明）；`confirmationDialog` 文字较长的显示问题仍待实机核对。

## 第二轮：复核意见修复（2026-10-04 晚）

规则同任务卡：每项先写能复现的测试（红）再改（绿）；没有删断言、没有放宽阈值、没有新增跳过。没有读取真实 Safari／Chrome 数据，没有启动应用、没有截图（离屏渲染是测试进程内渲染，见证据一节）。没有改 `Stores/ScanStore.swift`、`DECISIONS.md`、`BOARD.md`，决定文字放在本节末尾。

### 提交

| 提交 | 内容 | 对应项 |
|---|---|---|
| `7c51293` | 报告行 id 含删除途径与原因；事务内超时／取消时 ROLLBACK 绕过已过期的执行控制；未预期错误保留带摘要的备份并如实说明；恢复目录写不进去报"备份失败"；"最近的删除"页面数与列表同口径。另加后续提交要用的接缝（仅测试用的事务内钩子、保留期常量、空的清理与文案桩），行为不变 | P2-1、P2-2、P2-7、P2-8 |
| `5358d50` | 备份保留 7 天、最多 12 份（D26）；启动时与每次打开浏览器隐私页时清理到期备份；数量裁剪改到删除成功并写完摘要之后；结果页与"最近的删除"都能删除备份（确认后直接删除，不进废纸篓）；确认框按"会删除／浏览器退出才删除／浏览器内处理"分组列出页面，并标明未读全的配置文件 | P1-1、P2-4、P2-5、P2-9 |
| `69ad817` | 恢复前先备份当前状态，恢复可撤销；恢复提示补"之后删除的记录也会重新出现"；恢复的不是最新一份备份时再确认一次；恢复结果改用独立的原因类型与文案 | P1-2、P2-11 |
| `d639df8` | 悬停提示只显示不含查询参数的网址；"复制网址"和"复制域名"标记为隐藏、临时内容 | P2-6、P2-10 |
| `d485f78` | Parity Matrix、PROJECT_STATE、1.9.9 更正块改掉"不持久化"并写明备份保留期；如实列出与 Chromium 的三处差异；`PRIVACY.md` 新增浏览器隐私一节（中英） | P1-1（文档）、P2-3 |
| `b17f4cc` | 复核清单之外，改保留期时发现：正在进行的删除刚建、还没有结果的备份不计入 12 份上限，2 分钟内不在列表出现 | P2-5 的另一条路径 |
| `3c054c9` | 复核清单之外：恢复前保存当前状态失败时按真实原因报告（无权限、数据库被替换），不再一律"未能保存当前状态" | P1-2 补充 |
| `f5749f1` | 给 `3c054c9` 的两条映射补上能反证的测试（`3c054c9` 自带的测试修前修后都通过） | 同上 |
| `df63148` | "删除这份备份"的英文在结果页是 Delete、在"最近的删除"是 Remove，统一为 Delete（中文本来一致） | P1-1 补充 |
| （本提交） | 本交接的第二轮部分 | — |

`git diff --shortstat 909fe77 df63148`（第二轮全部代码、测试与文档）：20 个文件，+1761 / −196。整批 `2ac7902 df63148`：26 个文件，+6764 / −886（不含本交接提交）。

### 逐项

**P1-1 备份没有期限、文案不实 —— 已修（`5358d50`、`d485f78`、`b17f4cc`）**
- 常量 `BrowserPrivacyBackupRetention`（`Features/BrowserPrivacy/Processing/BrowserPrivacyRecoveryBackupService.swift`）：`days = 7`、`maximumCount = 12`。到期时间、数量裁剪和所有界面文案都读这两个值。
- `purgeExpired(now:)`：按元数据的创建时间（没有元数据时按文件夹创建时间）删除超过 7 天的备份，再按上限裁剪；`entries(now:)` 不列出已到期的备份。调用点：`StorageCleanerMacApp.applicationDidFinishLaunching`（`BrowserPrivacyRecoveryMaintenance.enableAndPurge()`）、`BrowserPrivacyWorkspaceView.onAppear`（`purgeIfEnabled()`；只在应用代理启动后生效，因此测试里渲染视图不会碰 Application Support）、`BrowserPrivacyRecoveryStore.refresh()`。
- 数量裁剪（同 P2-5）：原来在建备份时就裁剪，之后被拒绝、数据库没改的删除也会挤掉最旧的一份；现在只在 `annotate()` 写完结果之后裁剪，且只计算已记录结果的备份（`b17f4cc`）。
- 删除备份："最近的删除"每行的废纸篓图标按钮（悬停与无障碍名"删除这份备份"／Delete This Backup），弹出确认，确认按钮"删除备份"／Delete Backup（`df63148` 统一英文用词，测试 `testDeletingABackupIsNamedTheSameInTheReportAndInRecentDeletions`，红：`logs/r3-wording-red.log`）；结果页每个配置文件"删除这份备份…"（行内确认，成功显示"备份已删除"，失败提示"没能删除备份，可在'最近的删除'里再试。"）。确认文字："删除这份备份后，那次删除将无法再撤销。备份是本应用保存的整个历史数据库副本，会直接删除，不会移到废纸篓（放进废纸篓等于继续保留被删除的页面）。"
- **取舍（直接删除，不进废纸篓）**：直接删除不可撤销，误删后那次删除就无法恢复；但移到废纸篓等于把整份历史副本（含被删页面）继续留在磁盘上，与 D26"可随时手动立即删除"的目的相反。因此选直接删除，并在确认里写明后果。删除范围限定：`remove(backupID:)` 只按备份 ID 拼出恢复根目录（`Application Support/…/BrowserPrivacyRecovery/v1/`）下一级的路径，`lstat` 确认是真实目录（不跟随符号链接）才删除。（第三轮更正：原文还写了"且父目录正是恢复根目录"，那条检查恒为真，不是额外保护，代码已删除；第三轮补了符号链接与非 UUID 项的测试。）
- 文案：两个删除确认框与结果页都写"被删除的页面仍保存在删除前的备份里，7 天后自动删除；确认无误后可在"最近的删除"里立即删除备份。"（天数来自常量）；"最近的删除"顶部写明保留 7 天、最多 12 份，每行显示"… 自动删除"的时间。
- 文档：Parity Matrix 第 51 行（序号 34）与第 57 行（序号 40）；`docs/PROJECT_STATE.md:63`；`docs/1.9.9-browser-privacy-validation.md` 顶部更正块；`PRIVACY.md` 新增 "Browser privacy／浏览器隐私"（本地只读扫描；网址和标题不写入设置、日志、诊断导出，不上传；复制带隐藏标记；删除前整库备份含被删页面，7 天、12 份，可提前删除；恢复前先保存当前状态）。原来"不持久化、不导出、不上传、不写日志"的说法已全部改为"本应用不把网址和标题写入设置、日志或诊断导出，也不上传"，并写明备份例外。
- 测试（红阶段全部失败）：`BrowserPrivacyRecoveryTests.testExpiredBackupsAreRemovedAfterTheRetentionPeriod`、`testExpiredBackupsArePurgedAtLaunchAndWhenThePageOpens`、`testBackupCountIsPrunedOnlyAfterADeletionSucceeds`、`testRecoveryStoreRemovesABackupByIdentifier`；`PrivacyCleanupPresentationTests.testReportOffersToRemoveTheBackupAndStatesItsRetention`、`testDeletionConfirmationStatesTheBackupAndIncompleteReads`、`testDocumentsDescribeTheBackupAndTheDifferencesFromChromium`。`b17f4cc`：`testBackupsStillBeingWrittenNeitherCountNorShow`（红：`logs/r3-inflight-red.log`，3 处断言）。

**P1-2 恢复的后果没说清、不能撤销 —— 已修（`69ad817`、`3c054c9`、`f5749f1`）**
- `BrowserPrivacyHistoryProcessor.restore`：写入前先用同一备份服务备份当前数据库（结果 `savedBeforeRestore`，同样 7 天保留、计入 12 份）；保存失败就不开始恢复。恢复写入前后比较 `SecureSourceFile.contentStamp`：失败且文件没变→丢弃这份保存；文件可能变了→保留并在结果里给出它（"浏览记录可能已部分改动；恢复前的状态已另存为备份，可在"最近的删除"里用它撤销。"）。
- 恢复提示："…会丢弃这次删除之后新增的浏览记录和下载列表，之后删除的记录也会重新出现。恢复前会先自动备份当前状态，可在"最近的删除"里撤销这次恢复。请先退出 X；书签、密码和 Cookie 不受影响。"
- 恢复的不是该配置文件最新的一份时，第二次确认："这不是这个配置文件最近的一份备份：在它之后还有 N 份（最近一份在 …）。恢复它会把之后的删除和恢复都一起撤销，之后删除的记录都会重新出现。"
- "最近的删除"里保存的状态写"恢复较早的备份之前自动保存的状态，用它可以撤销那次恢复"，按钮"撤销那次恢复"。
- 保存当前状态失败的原因（`3c054c9`）：未合并写入→pendingWrites，忙→databaseBusy，无权限→permissionDenied，数据库不可用或被替换→databaseChanged，超时、取消，其余→currentStateNotSaved（"没能先保存 X 当前的浏览记录。为了让恢复可以撤销，没有开始恢复。"）。
- 测试：`testRestoreFirstSavesTheCurrentStateSoTheRestoreCanBeUndone`（恢复后再用保存的状态撤销，每张表回到恢复前）、`testRestoreWarningsSayWhatComesBackAndFlagOlderBackups`（红阶段失败）；`testRestoreNamesWhyTheCurrentStateCouldNotBeSaved`（`f5749f1`，反向变异红：去掉两条映射后 permissionDenied、unavailable 都变成 currentStateNotSaved，`logs/r3-restore-mapping-red.log`）；保护性测试（修前修后都通过，不算红证据）：`testFailedRestoreThatTouchedNothingDropsItsSavedState`、`testRestoreThatCannotSaveTheCurrentStateFirstDoesNotStart`。

**P2-1 报告行 id 重复 —— 已修（`7c51293`）**：`BrowserPrivacyProcessingEntry` 新增 `deletionPath`（direct／inBrowser），`id` = 浏览器｜配置文件｜删除途径｜原因。同一配置文件的可删部分与手动部分都以手动结束（例如有未合并写入，旁边又有已同步的访问）时不再撞 id。测试 `testReportEntryIDsStayUniqueWhenBothPartsOfAProfileEndInTheBrowser`（红：两行都是 `chrome:chrome:Default:manualBrowserGuidance`）。

**P2-2 事务内超时后跳过回滚 —— 已修（`7c51293`）**：ROLLBACK 先关掉进度回调、直接 `sqlite3_exec`，不再经过已过期的执行控制，之后检查 autocommit；结果"操作超时，未完成的修改已全部撤销。"（原因 `timedOut`），不保留备份，也不再整库从备份写回。接缝：处理器构造参数 `inTransactionHook`（`BEGIN IMMEDIATE` 之后调用，生产传 nil）。测试 `testTimeoutInsideTheTransactionRollsBackWithoutRestoringTheBackup`（红：结果为 restoredFromBackup）。

**P2-3 与 Chromium 的差异 —— 已如实写明（`d485f78`，代码行为未改）**：Parity Matrix 第 56 行（序号 39）与 1.9.9 更正块列出三处：① 加了书签（Chromium 叫"固定"）的网址，Chromium 保留 `urls` 行只调整计数，本应用删除该行；② Chromium 删除一次访问时连带删除其重定向上游访问，本应用只删所选访问，上游访问作为独立页面列出由用户选择；③ Chromium 还清理单独的 Favicons 数据库及热门网站、地址栏快捷联想等存储，本应用只改 History 数据库，这些地方仍可能留有被删页面的网址。决定文字见下方 D32 草案。测试 `testDocumentsDescribeTheBackupAndTheDifferencesFromChromium`（红阶段失败）。

**P2-4 未读全的配置文件 —— 已修（`5358d50`）**：`BrowserPrivacyStore.selectionIncludesIncompletelyReadProfiles`（按扫描覆盖信息里读全的配置文件判断）；确认框加"部分配置文件这次没有读取全部记录（超过单个配置文件的读取上限）。只会删除已读取到的访问；同一页面更早的访问不会被删除。"测试 `BrowserPrivacyRecordScannerTests.testSelectionFromIncompletelyReadProfilesIsFlagged`、`testDeletionConfirmationStatesTheBackupAndIncompleteReads`（红阶段失败）。

**P2-5 先裁剪后失败 —— 已修**：见 P1-1。

**P2-6 悬停提示带查询参数 —— 已修（`d639df8`）**：无标题行的标题和网址行的悬停提示都改为 `presentation.address.collapsed`（不含查询参数、不截断）；完整网址只出现在展开行和"复制网址"。测试 `testHoverShowsTheAddressWithoutItsQuery`（红阶段失败）。

**P2-7 "最近的删除"页面数口径 —— 已修（`7c51293`）**：`recoverySummary` 用 `BrowserPrivacyDisplayItem.pageCount(of:)`，与结果列表分组一致（`#片段` 算同一页）。测试 `testRecoverySummaryCountsPagesTheWayTheListDoes`（红：2 个页面，列表是 1 个）。

**P2-8 未预期错误的说法与摘要 —— 已修（`7c51293`）**：备份建立之后的未预期错误写入 `unexpectedError` 摘要并保留备份，文案"处理时出现未预期的错误，无法确认这个配置文件的数据库是否有改动。删除前的备份已保留，可在"最近的删除"里恢复；请重新扫描核对。"；备份建立之前的未预期错误不留备份，文案"…发生在写入数据库之前，没有删除任何记录。"；恢复目录写不进去（只有文件夹与元数据步骤抛出 `BrowserPrivacyBackupStorageFailure`）报"删除前没能备份 X 的历史数据库，所以没有删除任何记录。"。测试 `testUnexpectedErrorKeepsTheBackupWithASummaryAndSaysTheResultIsUnknown`（红：transactionFailed、无摘要）；`testUnwritableRecoveryFolderSaysTheBackupFailed`（反向变异红：去掉专用 catch 后为 unexpectedErrorBeforeChanges，`logs/r3-backupfolder-red.log`；更早一次把断言临时加在 `testBackupFailurePreventsAnyHistoryMutation` 上对旧映射跑红，`logs/r3-backupfailed-red.log`，该旧测试最终未改）；保护性测试 `testUnexpectedErrorBeforeAnyWriteSaysNothingWasChanged`。

**P2-9 运行中浏览器的确认框 —— 已修（`5358d50`）**：`BrowserPrivacyConfirmationText.preflightMessage` 把页面分成"正在运行的 X 里的 N 次访问：选择'正常退出并继续'会删除，选择'跳过运行中的浏览器'则跳过、不处理""其他浏览器（…）里的 N 次访问，两种选择都会删除""另有 N 次访问只能在浏览器内处理，稍后会给出步骤"三段，各列页面；确认文字在弹出时生成一次并缓存。测试 `testRunningBrowserConfirmationListsSkippedPagesSeparately`（红阶段失败）。

**P2-10 剪贴板标记 —— 已修（`d639df8`）**：`BrowserPrivacyClipboard.write(_:to:)` 声明 `.string`、`org.nspasteboard.ConcealedType`、`org.nspasteboard.TransientType`，"复制网址"与"复制 N 个域名"都经它写入；源码契约要求结果视图里只有这一处 `setString`。测试 `testCopiedAddressesAreMarkedConcealedAndTransient`（用临时命名剪贴板，不碰系统剪贴板；红阶段失败）。

**P2-11 恢复失败沿用删除文案 —— 已修（`69ad817`）**：新增 `BrowserPrivacyRestoreReason`（restored、browserRunning、pendingWrites、databaseBusy、permissionDenied、backupUnavailable、backupTooLarge、profileUnavailable、databaseChanged、timedOut、cancelled、currentStateNotSaved、failed）与 `BrowserPrivacyRestoreResult`（附"浏览记录没有改动／可能已改动／可能已部分改动…"）；处理原因里去掉 restoredByRequest、backupUnavailable、profileUnavailable、transactionFailed。测试 `testRestoreFailureTextsTalkAboutRestoringNotDeleting`（红阶段失败）、契约 `testEveryRestoreReasonIsWrittenInBothLanguagesAboutRestoring`（中英、互不相同、不含"删除"类说法）。

### 改动的旧测试（第二轮）

| 原测试 | 处理 | 依据 |
|---|---|---|
| `BrowserPrivacyRecoveryTests.testRestoreBringsBackExactlyTheStateBeforeTheDeletion` | `.restoredByRequest`→`.restored`；"恢复后恰好 1 份备份"改为"原备份仍在，另有 1 份 savedBeforeRestore，且就是结果里的 undoBackupID" | P1-2（恢复前先保存当前状态）、P2-11（恢复独立原因） |
| `…testRecoveryStoreListsRestoresAndRemovesBackups` | 同上；最后逐份删除列表里的备份后列表为空 | 同上 |
| `PrivacyCleanupPresentationTests.testResultRowsPrintOnlySanitizedPresentationText` | 悬停提示由 `address.full ?? address.collapsed` 改为 `address.collapsed`；剪贴板写入点由 2 处 `NSPasteboard.general` 改为 2 处 `BrowserPrivacyClipboard.write(`，并新增"只有一处 setString" | P2-6、P2-10 |
| `…testBrowserPrivacyCleanAnalysiserParityMatrixDocumentsSafetyBoundary`、`…testBrowserPrivacyResultsUseCompactHeaderSingleSearchAndLazyRows` | 文档短语"不持久化、不导出、不上传、不写日志"改为"不把网址和标题写入设置、日志或诊断导出，也不上传" | P1-1／D26：备份会保存被删页面 7 天，原短语不实 |

`testEveryProcessingReasonIsWrittenInBothLanguagesWithoutJargon` 未改，红阶段因桩文案与已有文案重复而失败（28≠29），实现补上真实文案后通过。

### 命令与结果（第二轮）

环境同第一轮：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，`swift test --scratch-path ~/Developer/.sc-build/r2-privacy/debug --jobs 4 --skip-update --disable-automatic-resolution`；沿用原 scratch，没有新建构建目录。下表"定向"指 `--filter 'BrowserPrivacy|PrivacyCleanupPresentationTests'`。

| 步骤 | 范围 | 结果 | 日志 |
|---|---|---|---|
| 接缝（不改行为） | 定向 | 163 执行 / 1 跳过 / 2 失败（两条契约：桩文案与已有文案重复、剪贴板写入点计数；随实现改正，提交 `7c51293` 时已为绿），exit 1 | `logs/r3-seams.log` |
| **红阶段**（新测试对未修实现） | 定向 | 181 执行 / 1 跳过 / **77 处断言失败，分布在 20 条测试**（18 条新测试 + 上述 2 条契约），exit 1 | `logs/r3-red-phase.log` |
| 反证：备份目录失败的原因 | 单测 | 旧映射下 databaseUnavailable，exit 1 | `logs/r3-backupfailed-red.log` |
| 中间态（P2-1 已修） | 处理器测试 | 58 执行 / 10 处断言失败（剩 P2-2、P2-8 和契约），exit 1 | `logs/r3-p2-1.log` |
| 各提交前一刻 | 定向（`5358d50` 另跑 UI 守卫 81 / 0） | 169（`7c51293`）→ 177（`5358d50`）→ 182（`69ad817`）→ 184（`d639df8`）→ 185（`d485f78`）执行，均 1 跳过 / 0 失败，exit 0；尚未修的项的新测试在对应提交前暂不纳入，随修复一起提交 | `logs/r3-group-{a,b,c,d,e}.log`、`logs/r3-group-b-ui.log` |
| 反证：进行中的备份 | 单测 | 3 处断言失败，exit 1 | `logs/r3-inflight-red.log` |
| 修复后 | 定向 | 186（`b17f4cc`）、187（`3c054c9`）执行 / 1 跳过 / 0 失败，exit 0 | `logs/r3-inflight.log`、`logs/r3-restore-presave.log` |
| 反证：恢复前保存失败的映射（`f5749f1`） | 2 条单测 | 2 处断言失败（permissionDenied、unavailable），exit 1；源码已从备份还原并核对与 HEAD 一致 | `logs/r3-restore-mapping-red.log` |
| 反证：备份目录失败的专用 catch | 单测 | unexpectedErrorBeforeChanges≠backupFailed，exit 1；源码已还原 | `logs/r3-backupfolder-red.log` |
| 定向（`f5749f1`） | 定向 | 188 执行 / 1 跳过 / 0 失败，exit 0 | `logs/r3-final-privacy.log` |
| 反证：备份删除的英文用词（`df63148`） | 单测 | 4 处断言失败，exit 1 | `logs/r3-wording-red.log` |
| **最终定向**（`df63148`） | 定向 | **189 执行 / 1 跳过（opt-in 真实扫描）/ 0 失败**，exit 0 | `logs/r3-wording.log` |
| 布局与 UI 守卫（`3c054c9`、`df63148`） | `SafeCleanupLayoutTests\|UIConsistencyRegressionTests\|L10nTests\|SystemUtilitySafetyTests/testBrowserPrivacy\|AppResponsivenessTests` | 两次均 81 执行 / 0 失败，exit 0 | `logs/r3-final-ui.log`、`logs/r3-wording-ui.log` |
| Debug 全量（`3c054c9`） | 全部 | 3255 执行 / 21 跳过 / 0 失败，测试 218 s，总 251 s；负载（1 分钟）38.2→21.1（18 核，其他会话同时在编译），exit 0 | `logs/r3-full-debug.log` |
| Debug 全量（`f5749f1`） | 全部 | 3256 执行 / 21 跳过 / 0 失败，测试 201 s，总 206 s；负载 14.5→12.0，exit 0 | `logs/r3-full-debug-final.log` |
| **Debug 全量**（`df63148`，最终代码） | 全部 | **3257 执行 / 21 跳过 / 1 失败**，测试 208 s，总 212 s；负载 18.5→12.9，exit 1。唯一失败是计时测试 `MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`：CPU 快速内核超出 15 s 上限，抛 `BenchmarkKernelError.resourceLimit`（15.003 s）。见下方说明 | `logs/r3-full-debug-df63148.log` |
| 上述计时测试单独重跑（`df63148`） | 1 条 | passed（15.288 s），负载 13.4→13.7，exit 0；阈值未改 | `logs/r3-benchmark-rerun.log` |
| 私有接口检查 | `python3 script/check_private_api.py` | passed（6 allowlisted uses），exit 0 | — |
| 空白检查 | `git diff --check 2ac7902..HEAD`、工作区 `git diff --check` | exit 0 | — |
| 严格并发构建 | — | NOT RUN（第一轮在 `concurrency` scratch 上通过；本轮为腾磁盘已删除该目录，约 1.2 GB；Package 为 Swift 6 语言模式，Debug 构建本身就做完整并发检查） | — |
| Release 全量、小窗性能、门禁脚本 | — | NOT RUN（按规则由主会话在集成分支跑） | — |

21 条跳过均为既有 opt-in／真实环境测试（含 `testOptInProductionBrowserCoverage`、`MenuBarPerformanceRegressionTests.testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`），四次全量的跳过名单与第一轮完全相同；本批未设置 `STORAGE_CLEANER_RUN_LIVE_BROWSER_SCAN`。

**计时测试超时（BOARD N10 一类）**：`testStandardQuickKernelsCompleteWithinDeclaredLimits` 在四次全量里的用时为 10.0 s（第一轮）、15.6 s（`3c054c9`）、12.1 s（`f5749f1`）、超时失败 15.003 s（`df63148`），单独重跑 15.3 s 通过。该测试与基准内核源码本批没有改动（`git diff 2ac7902 HEAD` 对 `Services/Benchmark/` 和 `MacBenchmarkKernelTests.swift` 为空），`df63148` 只改了"最近的删除"里的 3 个英文字符串和一条源码测试；失败时同机有其他会话的 `swift` 编译进程（各约 70–95% CPU）和 `fileproviderd`（约 170%）在跑，18 核。判断为负载导致的计时超时，没有放宽阈值、没有重跑到通过为止再报。

### 离屏渲染（证据，非截图）

测试进程内 `NSHostingView.cacheDisplay` 渲染匿名夹具（不是应用截图、不是屏幕捕获）：`~/Developer/.sc-build/r2-privacy/snapshots/r3-recent-deletions.png`（顶部说明 7 天／12 份、每行"… 自动删除"、保存的状态一行、"已于 … 恢复过"、恢复成功提示）、`r3-report.png`（结果页保留期说明与"删除这份备份…"）、`r3-texts.txt`（确认框各段、恢复提示、较早备份提示）。生成它们的临时测试未提交，已移出 worktree（副本在本会话 scratchpad）。

### 决定草案（不写入 DECISIONS.md，供主会话登记）

**第三轮更正：本节编号作废**（D29–D33 已被批次 4b 占用），以第三轮一节的 D34–D37 与"D26 补充"为准。以下保留第二轮原文。

编号按主会话指定从 D29 起；保留期引用 D26（用户 2026-10-04 决定，主会话已登记）。第一轮交接里的 D22–D25 草案编号与 DECISIONS.md 现有 D22–D25（第二轮修复 A）冲突，作废：原 D23 即 D29，原 D22 并入 D32，原 D24 改为下面的"D26 补充"，原 D25 如需登记建议用 D33。

- **D29**（`36dd431`）："Chromium 系直接删除接受数据库旁 0 字节的普通 `-journal` 文件；有内容的 journal、符号链接 journal 以及任何 `-wal`／`-shm` 仍视为未合并写入而拒绝；sidecar 只在写入前（浏览器退出后、打开写连接前）检查，不在扫描时决定可删性。"取代 1.9.10 的"sidecar 全部不存在"门槛。
- **D30**（`7f73f4a`）："已同步到账号的 Chromium 访问（`is_known_to_sync` 或任一 `originator_*`）在扫描时就标为浏览器内处理并写明原因，不拖累同一配置文件里其他记录的直接删除；处理器写入前再查一次。"
- **D31**（`69ad817`、`3c054c9`）："恢复前先把当前历史数据库另存为一份备份（保留规则同 D26），恢复可撤销；保存失败不开始恢复。恢复提示写明会丢弃之后新增的浏览记录和下载列表、之后删除的记录会重新出现；恢复的不是该配置文件最新的一份备份时再确认一次，并说明会一并撤销几份。恢复结果使用独立的原因与文案，不借用删除文案。"
- **D32**（`2824b37`、`d485f78`）："Chromium 整页删除在 History 数据库内按 Chromium 自身删除历史的流程处理依赖行与 URL 行；已同步的访问交由浏览器（D30）；悬空的 opener_visit／from_visit／segment_id 与 Chromium 一样不处理。与 Chromium 的差异如实写在文档：加书签（固定）网址的 urls 行本应用会删除；重定向上游访问不连带删除，作为独立页面由用户选择；Favicons 等其他存储不处理。"取代 1.9.9 验收记录第 12 节"最后一条 visit…fail closed"。
- **D26 补充**（`7452b3c`、`5358d50`、`b17f4cc`）："数据库未改动的失败立即删除刚建的备份；成功、结果未确认、未预期错误和恢复前保存的备份保留，元数据记录浏览器名、配置文件名、条数与结果，不含网址与标题；12 份上限只计算已记录结果的备份，并在删除成功写完摘要后才裁剪；没有结果的备份 2 分钟内不列出，7 天后照常到期；删除备份为直接删除、不进废纸篓。"

### 第二轮之后的未完成与风险

- 全部只在临时目录的假数据库上验证；真实 Chrome 上的删除、恢复、撤销恢复、到期清理都需要实机核对（第 6 节第 7–12 条）。
- 删除备份不进废纸篓，误删即失去那次删除的恢复能力（已在确认中写明）。
- 到期按备份元数据里的创建时间计算；系统时间被往回或往前大幅调整时，备份可能早删或晚删。
- 保存的状态也计入 12 份；连续多次恢复会挤掉较早的删除备份（与 D26 一致，未另设名额）。已满 12 份时恢复最旧的一份，新增的"恢复前状态"会把刚恢复的那份挤掉（仍可用保存的状态撤销恢复）。（第三轮已修：恢复源不会被这次恢复裁掉，恢复过的备份不再计入上限。）
- Debug 全量在最终代码上有 1 条与本批无关的计时测试超时（见上），单独重跑通过；主会话在集成分支跑门禁时请在空闲时复核。
- `confirmationDialog` 的文字比第一轮更长（分组 + 保留期说明），macOS 对长消息的换行／截断本会话无法确认。
- 严格并发构建本轮未重跑（见上表）。

## 1. 提交列表（按时间，第一轮）

| 提交 | 内容 | 对应项 |
|---|---|---|
| `55a57cb` | Safari 标题改读 `history_visits.title`，列不存在时退回 `history_items.title` | 5 |
| `2824b37` | Chromium 整页删除：按 Chromium 自身删除流程处理依赖行与 URL 行 | 6 |
| `91b3645` | 处理结果原因改为枚举 + `L10n.text` 中英文；扫描记录"为何不能直接删除"；同一配置文件可删与手动部分分别处理 | 7、6（原因准确） |
| `d442f06` | 行显示标题＋网址、可展开看完整网址和逐次访问、逐次勾选、复制网址；搜索匹配网址/标题/浏览器/配置文件名/中英类别；排序生效；计数口径；手动处理页不打码；确认框列出页面；演示数据 | 1、2、3、4、9 |
| `7452b3c` | "最近的删除"：列出删除前备份（时间、浏览器、配置文件、条数），可恢复、可删除备份；数据库未改动的失败不留备份 | 8 |
| `f32e7c4` | 侧栏说明、Parity Matrix、PROJECT_STATE、1.9.9 验收记录更正；相关测试 | 10 |
| `36dd431` | **任务卡之外**：Chromium 正常退出留下的 0 字节 `History-journal` 不再阻止删除；扫描器不再按 sidecar 决定可删性 | 见第 8 节 A |
| `7f73f4a` | **任务卡之外**：已同步到账号的访问在扫描时就标为"浏览器内处理"，不拖累同配置文件的其他记录 | 见第 8 节 B |

`git diff --stat 2ac7902 HEAD`：21 个文件，+4933 / −807。

## 2. 逐项改动与状态

### 1. 行内容可辨认 —— 已修（`d442f06`）
- `Views/BrowserPrivacyRecordPresentation.swift` 重写：`BrowserPrivacyAddressPresentation`（折叠网址：域名＋端口＋解码后的路径，查询参数折叠为 `?…`；完整网址另存；非 http(s) 地址原样显示、只折叠查询）、`BrowserPrivacyRecordPresentation`（标题缺失时用折叠网址作标题；类别／访问次数／最近时间摘要；无障碍标签）。所有进入视图的文本先去控制字符、合并空白并限长（标题 160、网址 2048）。
- 行（`BrowserPrivacyRecordResultsView.swift` 的 `BrowserPrivacyDisplayItemRow`）：浏览器＋配置文件显示名 → 标题（两行，尾部截断；无标题时中间截断）→ 网址（单行中间截断，悬停提示完整网址）→ 摘要。右侧徽标下方有"复制网址"和展开按钮；"浏览器内处理"徽标的悬停提示给出具体原因。
- 不再出现"未记录页面标题""未知网站"。
- 测试：`PrivacyCleanupPresentationTests.testRowShowsTitleSiteAndPathAndFoldsTheQuery`、`testRowWithoutATitleUsesTheAddressInsteadOfAPlaceholder`、`testAddressesOtherThanWebPagesAreShownAsRecorded`、`testAddressPresentationHandlesHostPortEncodingAndMissingValues`（大小写、端口、百分号解码、凭据不显示、方向控制字符、2048 上限、只有域名、什么都没有）、`testListedPageCarriesNewestRecordedTitleAndAddress`、`testResultRowsPrintOnlySanitizedPresentationText`（源码契约）。
- 反证：红阶段 `testRedPhaseRowIdentifiesThePageWithoutATitle`（旧接口写法）在旧实现上失败，见 `logs/red-phase-test.log`。

### 2. 行可展开看每次访问 —— 已修，含逐次勾选（`d442f06`）
- 展开状态放在 `BrowserPrivacyStore.expandedItemIDs`（会话内存，`clearSession` 清空；展开不会选中）。展开区显示完整网址（可选中复制）和每次访问的时间，访问带 `#片段` 或与行不同的标题时一并显示；最多逐条列出 50 次，其余以"另有 N 次更早的访问…勾选整行会一并包含"说明。
- 每次访问有自己的复选框（`store.toggleSelection(record)`）；行级复选框仍是"该页面全部访问"，部分勾选显示为混合态。
- 测试：`BrowserPrivacyRecordScannerTests.testExpandingAPageNeverSelectsAndVisitsCanBeSelectedOneByOne`、`PrivacyCleanupPresentationTests.testExpandedRowListsEveryVisitWithWhatDistinguishesIt`。

### 3. 搜索、排序、计数、配置文件名 —— 已修（`d442f06`）
- `BrowserPrivacyRecord.searchableFields`：网址（原文与百分号解码后）、标题、浏览器名、配置文件显示名、域名、搜索词、类别中英文名、来源中英文名；Store 对每条记录缓存一次折叠后的搜索文本（字段间用 U+001F 分隔，匹配不跨字段），只在内存中。
- 因折叠内容命中时行上显示原因：`BrowserPrivacyRecordPresentation.searchHint`（命中搜索词→"命中搜索词：…"；只在网址参数里命中→"网址的参数里包含搜索内容，展开可查看完整网址"；只在未显示的类别"其他/未知"上命中→"类别：…"）。
- 排序：`BrowserPrivacyResultSort` 改为 最近访问／访问次数最多／按浏览器（去掉恒为未知的"容量优先"），排序作用于页面（`BrowserPrivacyDisplayItem.aggregate(_:sort:)`），分组模式下在各组内生效。
- 计数：列表头"N 个页面 · M 次访问 · 已选 K 次访问"；网站分组头"N 个页面 · M 次访问"；底栏"已选择 K 次访问"；批量选择弹层"N 次访问"（`BrowserPrivacyCountText`）。
- 高级筛选的配置文件改为"浏览器 · 配置文件显示名"（`BrowserPrivacyRecordResultsView.profileOptions(from:browserID:)`）。
- 测试：`testSearchMatchesAddressTitleBrowserProfileNameAndCategoryNamesInBothLanguages`、`testResultSortReordersTheDisplayedPages`、`testSearchHintExplainsMatchesTheRowDoesNotPrint`、`testCountsAlwaysNamePagesAndVisits`、`testProfileFilterListsProfilesByBrowserAndDisplayName`。
- 反证：搜索与排序两条测试在旧实现上失败（红阶段日志）。

### 4. 手动处理页与确认框 —— 已修（`d442f06`）
- 手动处理页按浏览器列出真实网站（前 8 个 + "等 N 个网站"）和页面（"标题 — 域名/路径"，前 6 个 + "等 N 个页面"），`maskedDomain` 删除；域名仍只在点击"复制 N 个域名"后进入剪贴板（原说明句保留）。
- 两个确认框（直接清理、浏览器运行中预检）都列出要处理的页面（`BrowserPrivacyPageListText.lines`，在点击时生成一次），文案改为白话："删除前会先备份浏览器的历史数据库，删除后重新读取确认；数据库结构不受支持的配置文件不会被修改。书签、密码、Cookie、自动填充和未选的访问记录不受影响。"
- 测试：`testManualGuidanceShowsRealSitesAndPagesGroupedByBrowser`、`testConfirmationNamesTheFirstPagesAndCountsTheRest`。

### 5. Safari 标题 —— 已修（`55a57cb`）
- `BrowserPrivacyRecordScanner.historyQuery(.safari)`：两列都有时 `COALESCE(NULLIF(history_visits.title,''), history_items.title)`，只有一列时用那一列，都没有为空。
- 测试用真实 Safari 表结构建库（`history_items(id,url,domain_expansion,visit_count,daily_visit_counts,…)`、`history_visits(id,history_item,visit_time,title,load_successful,…,redirect_source,redirect_destination,…)`，含索引）：`testSafariRealSchemaReadsEachVisitTitleFromHistoryVisits`（同一网址两次访问各自的标题、无标题访问保持为空、库未被修改）、`testSafariTitleFallsBackToHistoryItemsOnlyWhenVisitsHaveNoTitleColumn`。
- 反证：前者在旧实现上失败（红阶段日志）。

### 6. Chromium 整页删除 —— 已修（`2824b37`；配套 `36dd431`、`7f73f4a`）
- `BrowserPrivacyHistoryProcessor.mutateChromiumV70` 按 Chromium 自身删除历史的做法（`ExpireHistoryBackend::DeleteURLs/ExpireURLsForVisits/DeleteVisitRelatedInfo/DeleteOneURL`、`VisitDatabase::DeleteVisit`、`VisitAnnotationsDatabase::DeleteAnnotationsForVisit/DeleteClusters`、`URLDatabase::DeleteURLRow`、`VisitSegmentDatabase::DeleteSegmentForURL`，经 WebFetch 读取 chromium/main 源码核对）：
  - 被删访问的下游 `from_visit` 改指向它的来源（经过多个被删访问时沿链上溯，循环即拒绝）；
  - 删除 `visit_source`、`context_annotations`、`content_annotations`、`clusters_and_visits`、`cluster_visit_duplicates`（两侧）；所有成员都被删的聚类连同 `clusters`、`cluster_keywords` 行一起删除（这两张表作为可选表加入适配器，存在时必须是含 `cluster_id` 的普通表、无触发器无外键，否则扫描不发放定位、写入拒绝）；
  - `visited_links` 每被删一次访问减一，减到 0 删行；链接行不属于被删 URL 时拒绝（`inconsistentData`）；没有对应行时与 Chromium 一样忽略；
  - URL 仍有访问：`visit_count` 按非 reload（核心 transition ≠ 8）数递减、`typed_count` 按 `incremented_omnibox_typed_score` 递减、两者下限 0，`last_visit_time` 取剩余访问中最新者；URL 已无访问：删除 `segment_usage`、`segments`、`keyword_search_terms`、`urls` 行。
  - 预期终态先于第一次写入算好，提交前在事务内复核，提交后用新的只读连接再复核一次（新增对已删 URL 行、其依赖、visited_links 计数、被清空聚类的检查）。ID 列表按 400 个一段拼接，避免超过 SQLite 语句长度。
  - 仍拒绝且不写入：已同步到账号的访问（`is_known_to_sync` 或任一 `originator_*`，报告为浏览器内处理并说明原因）、`from_visit` 循环、属于其他 URL 的 visited link、聚类表形态未知、任何被写表上有触发器或外键、非版本 70／兼容 16 的 Schema。悬空的 `opener_visit`、`from_visit`、`segment_id` 不再阻止删除（Chromium 也不处理它们）。
  - 写入授权器放行的表与列相应扩大（见 `BrowserPrivacySQLiteWriteAuthorizer`），INSERT、DDL、ATTACH 等一律拒绝。
- 测试（`BrowserPrivacyHistoryProcessorTests`）：整页删除（只有一次访问的页、多次访问的页）、部分删除的计数与最近时间（含 reload 不递减、计数低于访问数时钳到 0）、聚类与关键词、无可选聚类表、聚类表形态未知（扫描无定位；扫描后才改变则写入拒绝）、visited links（减一、删行、悬空 id 忽略、归属不符拒绝）、opener 不动、referrer 链修补与悬空 referrer／segment、referrer 循环拒绝、提交后 URL 行被重建→结果未确认、晚一步的 URL 更新失败时整体回滚（含已删 URL 的恢复）、1300 次访问／800 个页面的大批量（0.31 s）、5 种同步标记、授权器写集。
- 反证：红阶段 9 条新测试在旧实现上失败；变异测试 M1（不删 `urls` 行→事务内复核拒绝提交、5 条测试失败、库不变，`logs/mutation-m1-keep-url-row.log`）、M2（漏算剩余访问→复核拒绝、9 条失败，`logs/mutation-m2-overlook-remaining-visits.log`）。
- 未镜像：Chromium 在 chrome://history 删除一条记录时会连带删除它的重定向上游访问（`GetVisitsAndRedirectParents`），本应用把上游访问作为独立页面列出，由用户自行选择；Favicons 数据库中的图标映射不在本应用范围（见第 8 节）。**第二轮补充**：还有一处差异——加了书签（Chromium 叫"固定"）的网址，Chromium 保留 `urls` 行只调整计数，本应用删除该行。三处差异已写入 Parity Matrix 与 1.9.9 更正块（第二轮 P2-3，D32 草案）。

### 7. 失败原因 —— 已修（`91b3645`）
- 新文件 `Processing/BrowserPrivacyProcessingReason.swift`：`BrowserPrivacyProcessingReason`（27 个原因，每个有中英文），`BrowserPrivacyDirectDeletionBlocker`（扫描时记录为何不能直接删除：浏览器家族无写入计划、数据库不可写、应用未验证、路径不可信、Schema 不受支持、已同步到账号、记录信息不完整）。`BrowserPrivacyProcessingEntry` 新增 `reason`、`profileDisplayName`；报告行显示配置文件显示名。
- Safari／Firefox 的手动说明改为白话（不再有 "parent counters""derived indexes""frecency""sidecar" 等英文术语）。
- 同一配置文件里能直接删的与只能手动的分成两组分别处理（原来一条无定位记录会让整批变手动）。
- 测试：`testFailureDetailFollowsTheAppLanguageAndNamesTheRealCause`（强制中/英语言各跑一次）、`testEveryProcessingReasonIsWrittenInBothLanguagesWithoutJargon`（每个原因中文含汉字且不含术语表、英文不含汉字、文案互不相同、处理器源码无写死的 `detail: "` 字面量）、`testRecordsWithoutLocatorDoNotHoldBackTheRestOfTheProfile`、`testScanRecordsWhyAProfileCannotBeDeletedDirectly`。
- 反证：语言测试在旧实现上失败（中文断言）。

### 8. 恢复入口 —— 已修，两步都做了（`7452b3c`）
- `BrowserPrivacyRecoveryBackupService`：备份元数据增加浏览器显示名、配置文件显示名、访问数、页面数、结果（deleted／unverified／restoredAfterFailure／restoreUnconfirmed）、恢复时间；提供 `entries()`、`remove(backupID:)`、`markRestored`。元数据不含网址与标题（有测试）。**第二轮更正**：结果另有 unexpectedError、savedBeforeRestore，访问数与页面数可为空（未知不显示为 0）；备份保留 7 天、最多 12 份（D26），见第二轮 P1-1、P1-2。
- 处理器：删除成功后标注备份；提交后复核失败标注为 unverified；事务回滚或根本没开始的失败**删除**刚建的备份（旧版本会把失败尝试的备份留下，占用 12 份名额并多留一份完整历史副本）。
- 恢复 `BrowserPrivacyHistoryProcessor.restore(_:installedApplications:)`：不信任元数据里的路径，而是用注册表重新发现配置文件并按指纹匹配；同样要求应用签名/位置可验证、浏览器已退出、没有未合并写入；核对备份摘要后经 SQLite 备份 API 写回；结果用同一套原因文案。**第二轮更正**：恢复前先备份当前状态、可撤销；恢复结果改用独立的 `BrowserPrivacyRestoreReason`（P1-2、P2-11）。
- 界面：结果工具栏新增"最近的删除"按钮（弹层 `BrowserPrivacyRecentDeletionsView`）：每行时间、浏览器 · 配置文件、"删除了 N 次访问（M 个页面）"或"由旧版本创建，未记录删除了多少条"，恢复与删除备份都在弹层内二次确认；恢复提示明确写"会丢弃这次删除之后新增的浏览记录和下载列表，恢复前请先退出 X"。删除成功的报告里提示可在"最近的删除"恢复。**第二轮更正**：恢复提示补"之后删除的记录也会重新出现"与"恢复前会先自动备份当前状态"，恢复较早的备份时再确认一次；每行显示自动删除时间；结果页也能删除备份（P1-1、P1-2）。
- 测试：新文件 `BrowserPrivacyRecoveryTests.swift`（8 条）：成功删除留一份带摘要且不含网址的备份；拒绝／回滚／浏览器运行中都不留备份；提交后复核失败的备份标 unverified；恢复后每张表回到删除前且删除后新增的行消失；浏览器运行中、有 `-wal` 时拒绝恢复；备份被篡改、配置文件找不到、应用未验证时拒绝；Store 列表／恢复／删除；文案。
- 未接入 `ScanStore` 的操作记录（按任务卡要求）。

### 9. 演示数据 —— 已修（`d442f06`）
- `Debug/BrowserPrivacyPreviewFixture.swift`：12 次访问 9 个页面：同一站点 3 个页面、一个页面 3 次访问含两个 `#片段`、带查询参数（含 token）的页面、搜索页（搜索词在折叠参数里）、无标题长网址、`chrome://settings/privacy`、两条 Safari（只能浏览器内处理）。测试 `testBetaBrowserPrivacyPreviewUsesAnonymousInMemoryRecords` 改为检查这些特征（红阶段在旧夹具上失败）。

### 10. 文案与文档 —— 已修（`f32e7c4`）
- `SidebarView.swift`："只扫描可能敏感的网站记录并在浏览器中确认删除" → "读取本机全部浏览记录，逐页列出网站和页面；删除前确认"。
- `docs/CleanAnalysiser/Browser Privacy Parity Matrix.md`：边界说明改为 Chromium 系 8 个 Provider 在精确 Schema／签名／路径／sidecar 检查通过时直接删除；第 5、20、21、27、28、29、31、34、38 行按代码改写；新增 39（整页删除）、40（恢复）。
- `docs/PROJECT_STATE.md:63`：补"2.0.0 第二轮按 D20 改为显示标题与网址…"。
- `docs/1.9.9-browser-privacy-validation.md`：保留各节原文，顶部状态行改为"1.9.9 当时状态"，并加"2026-10-04 更正"列出已被取代的事实（Provider 数 14、Chromium 写入 Adapter、无默认选中、显示边界 D20、Safari 标题、整页删除与恢复）。
- 测试：`testBrowserPrivacyCleanAnalysiserParityMatrixDocumentsSafetyBoundary`（把文档里的 Provider 数与注册表实际数对照）、`testSidebarAndDocumentsDescribeTheCurrentBrowserPrivacyBehaviour`。
- **第二轮更正**：下面"不持久化"的说法不准确——它只对本应用的设置、日志、导出成立；直接删除前的备份是整个历史数据库副本，仍含被删页面，保留 7 天（D26）。文档已改（第二轮 P1-1），源码守卫本身不变。
- "不持久化、不导出、不写日志"约束：新增 `testBrowserPrivacySourcesKeepHistoryInMemoryOnly`（BrowserPrivacy 全部源码与 `Views/BrowserPrivacy*.swift` 不出现 UserDefaults／AppStorage／Logger／os_log／NSLog／print／URLSession／分享／保存面板／回执日志；文件写入仅限备份服务文件；剪贴板仅限结果视图，且恰好两处）；`testBrowserPrivacySourcesStayLocalAndNeverOpenHistoryURLs` 未改动。

## 3. 实际命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，全部加 `--skip-update --disable-automatic-resolution`，依赖缓存只读复制自 `~/Developer/.sc-verify/integration/scratch/debug`（改写 `workspace-state.json` 路径）。未联网构建；为核对 Chromium 删除语义，用 WebFetch 读取了 chromium/main 的公开源码（`expire_history_backend.cc`、`visit_database.cc`、`visit_annotations_database.cc`、`url_database.cc`、`visitsegment_database.cc`、`visited_link_database.cc`、`sql/database.cc`），未发送任何本机数据。

| 步骤 | 命令 | 结果 | 日志 |
|---|---|---|---|
| 基线构建 | `swift build --build-tests --scratch-path ~/Developer/.sc-build/r2-privacy/debug --jobs 4` | exit 0，156 s | `logs/baseline-build.log` |
| 基线定向测试 | `swift test … --filter 'BrowserPrivacy\|PrivacyCleanupPresentationTests'` | 121 执行 / 1 跳过 / 0 失败，exit 0 | `logs/baseline-test.log` |
| 红阶段（新测试对旧实现） | 同上 | 134 执行 / 1 跳过 / **78 处断言失败，分布在 16 条新测试**（名单见文末），其余全部通过，exit 1 | `logs/red-phase-test.log` |
| 各步定向测试 | 同上 | 均 0 失败 | `logs/step*.log` |
| 变异反证 M1、M2 | 同上（临时改源码后还原） | 分别 5 条、9 条测试失败，库不变 | `logs/mutation-m1-keep-url-row.log`、`logs/mutation-m2-overlook-remaining-visits.log` |
| 最终定向测试 | `--filter 'BrowserPrivacy\|PrivacyCleanupPresentationTests'` | 163 执行 / 1 跳过（opt-in 真实扫描）/ 0 失败 | `logs/step8-sync.log` |
| 布局与 UI 守卫 | `--filter 'SafeCleanupLayoutTests\|UIConsistencyRegressionTests\|L10nTests\|SystemUtilitySafetyTests/testBrowserPrivacy\|AppResponsivenessTests'` | 81 执行 / 0 失败 | `logs/step4-ui.log` |
| **Debug 全量** | `swift test --scratch-path ~/Developer/.sc-build/r2-privacy/debug --jobs 4` | **3231 执行 / 21 跳过 / 0 失败**，183 s，负载 4.5→9.8，exit 0 | `logs/full-debug-1.log` |
| 私有接口检查 | `python3 script/check_private_api.py` | passed（6 allowlisted uses），exit 0 | — |
| 空白检查 | `git diff --check 2ac7902 HEAD` | exit 0 | — |
| 源码守卫（verify.sh 同款） | Views 不含 `Process(`／`.terminate(`／`.forceTerminate(`；无冲突副本 | 通过 | — |
| 严格并发构建 | `swift build --scratch-path ~/Developer/.sc-build/r2-privacy/concurrency --jobs 4 -Xswiftc -strict-concurrency=complete` | 见文末"严格并发构建结果"（第二轮为腾磁盘已删除该 scratch，未重跑） | `logs/strict-concurrency-build.log` |
| Release 全量、小窗性能、门禁脚本 | — | NOT RUN（按规则由主会话在集成分支跑） | — |

跳过的 21 条均为既有 opt-in／真实环境测试（含 `testOptInProductionBrowserCoverage`），本批未设置 `STORAGE_CLEANER_RUN_LIVE_BROWSER_SCAN`。

## 4. 改动的旧测试及依据

| 原测试 | 处理 | 依据 |
|---|---|---|
| `testChromeV70ProductionRejectsLastURLVisitWithoutWriting` | 改为 `testChromeV70ProductionDeletesTheOnlyVisitOfAPageAndItsURLRow` | 任务卡第 6 项（明确要求） |
| `testChromiumV70FixtureRejectsLastVisitWithoutChangingAnyTable` | 改为 `testChromiumV70FixtureDeletesLastVisitTogetherWithItsURLRow` | 第 6 项；夹具计划与生产计划共用同一变更逻辑 |
| `testChromeV70ProductionRejectsSelectedClusterReferencesWithoutWriting` | 改为 `…RemovesClusterReferencesAndEmptiedClusters`、`…CleansClustersWithoutOptionalClusterTables`、`…UnknownClusterTableShapeMintsNoLocatorAndIsNeverWritten` | 第 6 项"聚类相关表…按已识别的表逐一处理" |
| `testChromeV70ProductionRejectsSelectedVisitedLinkWithoutWriting` | 改为 `…AdjustsVisitedLinkCountsLikeChromium`、`…RejectsVisitedLinkOwnedByAnotherURLWithoutWriting` | 第 6 项（visited_links 是适配器已识别的表） |
| `testChromeV70ProductionRejectsOtherRowOpenerReferenceWithoutWriting` | 改为 `…KeepsOpenerColumnOfOtherVisitsUntouched` | 第 6 项；Chromium `DeleteVisit` 不修补 `opener_visit`，拒绝只会让常见的"新标签页打开"记录无法删除 |
| `testChromeV70ProductionRejectsSelectedSyncMetadataWithoutWriting` | 改为 `…LeavesSyncedVisitsToTheBrowserWithoutWriting`：结果由 unsupported 改为 manual，原因 `syncedRecords`；仍不写入 | 第 6 项"拒绝原因要准确"、第 7 项 |
| `testChromeV70ProductionAuthorizerKeepsTheSameFiniteWriteSet` | 改为 `…AllowsOnlyThePageDeletionWriteSet`（新放行集合 + 更多拒绝断言） | 第 6 项 |
| 处理器测试中按英文片段断言 `detail`（rolled back／reused／still running／identity／schema／committed／manually／busy） | 改为断言 `reason` 枚举 | 第 7 项（文案已中英文化） |
| `testRegisteredProvidersExposeOnlyAuditedChromiumProductionAdapter` 中对 `manualGuidanceReason` 含 parent／derived／frecency／sidecar 的断言 | 改为断言 `BrowserPrivacyDirectDeletionBlocker.browserNotSupported` 中英文都点名浏览器并说明"不直接修改" | 第 7 项；RULES §5 中文界面不出现英文术语 |
| `testBetaBrowserPrivacyPreviewUsesAnonymousInMemoryRecords` | 期望从 4 条/3 组改为新夹具特征 | 第 9 项 |
| `PrivacyCleanupPresentationTests.testActiveRecordPresentationShowsTitleAndDomainWithoutURLDetails`（锁定不显示路径） | 改为 D20 系列测试（折叠网址含路径、默认不出现 token、完整网址可得） | D20 |
| `…testManualGuidanceGroupsDomainsByBrowserAndOnlyClipboardPayloadIsUnmasked`（锁定遮罩） | 改为 `testManualGuidanceShowsRealSitesAndPagesGroupedByBrowser` | D20"手动处理页不再给域名打码" |
| `…testActiveResultSourceUsesSafeTitleAndDomainPresentation` | 改为 `testResultRowsPrintOnlySanitizedPresentationText`（保留"原始字段不得直接进视图"的禁令，更新必需字符串，断言遮罩与占位文案已删除） | D20 |
| `…testBrowserPrivacyManualModeNeverClaimsOrStartsDatabaseDeletion` 的"不支持的 Schema 不会写入"/"unsupported schemas are not written" | 改为"数据库结构不受支持的配置文件不会被修改"/"profiles with an unsupported database schema are not modified" | 第 4 项确认框改写；RULES §5 |
| `…testBrowserPrivacyCleanAnalysiserParityMatrixDocumentsSafetyBoundary` 的"生产 Provider 不授予历史数据库写入 Adapter" | 改为对照注册表实际写入 Provider 数与 D20 措辞 | 第 10 项 |
| `testScanRecordsWhyAProfileCannotBeDeletedDirectly` 的 `-wal` 存在→扫描标记 pendingWrites 一段（本批新增后又改） | 移到 `testJournalFilesAtScanTimeDoNotDecideWhetherAPageCanBeDeleted` | 提交 `36dd431`（见第 8 节 A） |

没有删除断言、没有放宽阈值、没有跳过测试。

## 5. JEV 记录（非授权，只作判断参考）

- `jev_review`（提交 `2824b37` 的变更摘要 + 代码节选 + 测试结果）：action **escalate**，safe_to_apply 0.22，composite 0.77；分项 correctness 1.77（置信 0.65）、spec_match 1.94（0.91）、test_gap 0.44（0.34）、blast_radius 1.89（0.83）。解读：规格匹配高、改动面大（直接写用户浏览器数据库），需人工与实机复核，不是批准。
- `jev_decide`（sidecar 策略，4 个候选）：前两次调用因候选 id 格式不符被服务端拒绝（未产生判断），第三次成功：选 `accept_empty_journal`（即 `36dd431` 的做法），置信 1.0；逐项要求检查：它满足"不在有未完成事务时打开写连接""真实退出后留 0 字节 journal 时仍可删""扫描瞬时状态不误标"三条；维持基线被判为与后两条矛盾；接受所有 non-hot journal 被判为与第一条矛盾。JEV 的判断不代替用户授权与实机验证。
- **第二轮** `jev_review`（复核项摘要 + `Features/` 下第二轮全部逻辑改动的精简 diff，未截断；视图文案与文档未包含 + 测试结果摘要；不含任何浏览记录或个人数据）：action **escalate**，safe_to_apply 0.49，composite 0.68；分项 correctness 1.71（置信 0.56）、spec_match 1.59（0.38）、test_gap 0.74（0.49）、blast_radius 1.91（0.86）。解读：低置信度、改动面大（删除用户数据的备份、恢复写回浏览器数据库），需主会话人工复核与实机核对；不是批准。spec_match 置信度低与 diff 未含视图和文档部分有关。JEV 没有给出具体问题。
- **第三轮** `jev_review`（第三轮复核项 + `Sources/` 改动的精简摘要式 diff（含视图文案，未截断）+ 测试结果摘要；不含浏览记录或个人数据）：action **escalate**，safe_to_apply 0.49，composite 0.74；分项 correctness 1.82（置信 0.74）、spec_match 1.90（0.85）、test_gap 0.98（0.81）、blast_radius 1.87（0.81）。解读：规格匹配与正确性评分较高，但 safe_to_apply 低于 0.5、改动面大（自动删除用户数据的备份），仍需主会话复核与实机核对；不是批准。JEV 没有给出具体问题。

## 6. 需要实机核对（主会话）

1. **Chrome 配置文件旁的 `History-journal`**：正常退出 Chrome 后应为 0 字节（Chromium `journal_mode=TRUNCATE`）。若不是 0 字节或存在 `-wal`/`-shm`，直接删除会被拒绝并提示"数据库有未合并的写入"。本会话没有读取真实目录。
2. **Schema 版本**：已安装 Chrome 的 `meta.version`/`last_compatible_version` 是否仍为 70/16；不是的话所有 Chrome 行会显示"此版本的数据库结构不受支持"（扫描时就标出）。
3. **真实扫描**：Safari 行现在应有标题；Chrome 行应为"确认后处理"（除非已开 Chrome 同步——那时每行是"浏览器内处理"，悬停提示写明已同步）。
4. **删除测试记录**（只删本批造的测试页面）：在 Chrome 里访问几个测试页面（建议用 `.example` 或本地页面），退出 Chrome，扫描，整页删除一个页面、对另一个多次访问的页面只删部分访问；重开 Chrome 核对 chrome://history 与其他记录；再退出 Chrome，用"最近的删除"恢复，重开核对；最后删除备份。
5. **界面**：最小窗口 833×544 下行布局（徽标与右侧两个图标按钮）、展开区、复制网址、悬停提示、搜索提示行、排序菜单、配置文件筛选名称、确认框多行页面列表的显示（macOS `confirmationDialog` 对长消息的换行/截断表现本会话无法确认，若截断可把 `BrowserPrivacyPageListText.lines(limit:)` 调小）、"最近的删除"弹层。本会话只做了离屏渲染（见第 9 节）。
6. **性能**：真实 5000+ 条记录时搜索响应与大批量删除耗时（处理器单次操作上限 15 s，超时会回滚；第二轮 P2-2 后直接 ROLLBACK，不再整库从备份写回）。

第二轮新增（同样只用本批造的测试页面）：

7. **删除备份**：删除测试页面后，在结果页点"删除这份备份…"确认，再打开"最近的删除"核对那一行已消失；另做一次删除，在"最近的删除"用废纸篓图标删除。只看列表与恢复目录里的文件夹名（测试版为 `~/Library/Application Support/StorageCleanerMac-Beta/BrowserPrivacyRecovery/v1/`，正式版目录名为 `StorageCleanerMac`；看 UUID 文件夹是否消失），**不要打开备份数据库**——里面是完整浏览记录。确认废纸篓里没有出现这份备份。
8. **到期清理**：真实等 7 天不现实；可核对"最近的删除"每行显示的自动删除时间 = 删除时间 + 7 天，并确认启动应用、打开浏览器隐私页时没有报错、没有删掉未到期的备份。
9. **恢复与撤销恢复**：退出 Chrome 后用"最近的删除"恢复，确认提示里有"之后删除的记录也会重新出现""恢复前会先自动备份当前状态"；恢复后列表多出"恢复较早的备份之前自动保存的状态"一行，用"撤销那次恢复"回到恢复前；重开 Chrome 核对 chrome://history。连做两次删除后恢复较早的那份，核对第二次确认的文字与"之后还有 N 份"。
10. **浏览器运行中**：Chrome 运行时选中记录，确认框应把 Chrome 的页面单列为"选择'跳过运行中的浏览器'则跳过"，其他浏览器的页面单列为"两种选择都会删除"；Chrome 运行时点恢复，应提示先退出（恢复专用文案，不出现"没有删除任何记录"之类删除措辞）。
11. **悬停与剪贴板**：带查询参数的无标题页面，悬停标题和网址行都不应出现 `?` 之后的内容；展开后可见完整网址。若装有遵守 nspasteboard.org 标记的剪贴板管理器（如 Maccy、Paste），"复制网址"后它不应记录这一条；`pbpaste` 仍能取到内容。
12. **确认框长度**：第二轮确认文字更长（分组列出页面 + 保留期说明），在最小窗口下核对 macOS 确认框是否截断；若截断，可调小 `BrowserPrivacyPageListText.lines(limit:)`。

第三轮新增（同样只用测试页面）：

13. **时间机器排除**：做一次测试删除后，在终端运行只读命令 `tmutil isexcluded ~/Library/Application\ Support/StorageCleanerMac-Beta/BrowserPrivacyRecovery/v1`，应显示 `[Excluded]`。不要打开备份数据库。
14. **定时清理**：应用常驻时，"最近的删除"每行的"T 自动删除"即实际删除时间（到期后约 1 秒，计时器容差 10 秒）。真实等 7 天不现实；可确认应用空闲时 CPU 不因清理循环上升（它最多每小时醒一次），且合上盖子睡眠再唤醒后没有报错。
15. **满上限恢复**：已有多份备份时恢复最旧的一份，恢复后它仍在列表里并显示"已于 … 恢复过"，另有一行"恢复备份之前自动保存的状态"。
16. **不可选中**：展开行的完整网址、手动处理页的页面行不能拖选、⌘C 不复制；手动处理页的网站名称列表可以选中。
17. **非网页地址**：带 `#片段` 的 chrome:// 或 file:// 记录，行内和悬停提示显示为 `…#…`，展开后可见完整地址。
18. **删除失败提示**：真实环境下不易制造，本会话未核对；如需核对，主会话自行决定方法（不要改动用户真实备份的权限）。

## 7. 未完成与风险

- 本应用只修改 History 数据库。Chrome 自己的删除还会处理单独的 Favicons 数据库（含 page_url 的图标映射）、Top Sites、地址栏快捷联想（Shortcuts）、Visited Links 文件、会话文件等；这些仍可能保留被删页面的网址。建议在 FEATURES／PRIVACY 文档和界面说明中写明"只删除历史记录数据库中的访问记录"。`PRIVACY.md` 目前也未提及删除前的完整历史备份（最多 12 份，保存在 Application Support），建议补充。**第二轮**：`PRIVACY.md` 已补浏览器隐私一节（含备份、7 天、12 份），Parity Matrix 已写明只改 History 数据库及与 Chromium 的差异；`docs/FEATURES.md` 与界面说明仍未提"只删除 History 数据库中的访问记录"，未做。
- 重定向上游访问需用户自行勾选（Chromium 会自动连带删除）。
- 恢复会同时回退 History 数据库里的下载列表（已在提示里写明）。
- 同步开启的账号：所有 Chrome 访问只能在浏览器内删除；这是刻意的边界。
- 变更前后对真实 Chrome 的多表删除没有实机验收；JEV 评审结论为 escalate。
- 大批量删除的 15 s 上限只在 1300 条夹具数据上测过（0.31 s）。
- 测试进程内离屏渲染用了 NSWorkspace 运行中应用列表（预览夹具的 Chrome Bundle ID 命中本机正在运行的 Chrome，因此渲染里出现"运行中"徽标）；没有读取浏览器数据。

## 8. 任务卡之外的两项改动（请主会话决定保留或回退）

**第二轮更正**：复核已决定保留 A、B 两项。本节的 D22–D25 草案编号与 DECISIONS.md 已有编号冲突，作废，以"第二轮 · 决定草案"为准（D23→D29，B→D30，D22→并入 D32，D24→D26 补充，D25→D33 可选）。

A. `36dd431`（可 `git revert 36dd431` 单独回退，相关测试随提交一起消失）
- 事实：Chromium 以 `journal_mode=TRUNCATE` 打开数据库，正常退出后留下 0 字节 `History-journal`；基线代码只要任一 sidecar 存在就不发放写定位、写入也拒绝，因此在真实配置文件上直接删除从未可达，第 6 项的改动也无法生效。
- 改动：处理器只接受"普通文件且 0 字节的 `-journal`"这一种 sidecar（SQLite 视其为不存在，不含事务），有内容的 journal、符号链接 journal、任何 `-wal`/`-shm`（含 0 字节）仍拒绝；扫描器不再按 sidecar 决定可删性（扫描通常在浏览器运行时进行，瞬时状态会把整个配置文件误标为"浏览器内处理"），由处理器在浏览器退出后、打开写连接前检查。恢复走同一检查。
- 测试：空 journal 旁删除成功且 `quick_check` 为 ok；5 种其他 sidecar 与符号链接 journal 均拒绝且表内容不变；扫描时存在 journal 不影响可选性。
- 建议决定文字（D23 草案）："Chromium 系直接删除接受数据库旁 0 字节的普通 `-journal` 文件；其他 sidecar 仍视为未合并写入而拒绝；sidecar 只在写入前检查，不在扫描时决定可删性。"取代 1.9.10 的"sidecar 全部不存在"门槛。

B. `7f73f4a`
- 已同步到账号的访问在扫描时就不发放定位并记录原因，行显示"浏览器内处理"并说明；同一配置文件里未同步的记录照常直接删除。处理器保留自己的检查以防扫描后才被同步。

建议一并写入 DECISIONS.md 的其他决定文字：
- D22 草案："Chromium 整页删除按 Chromium 自身删除历史的流程处理依赖行与 URL 行；已同步到账号的访问交由浏览器处理；悬空的 opener_visit/from_visit/segment_id 与 Chromium 一样不处理。"取代 1.9.9 验收记录第 12 节"最后一条 visit…fail closed"。
- D24 草案："删除前备份在数据库未改动时立即删除；成功与结果未确认的备份保留并记录浏览器名、配置文件名、条数与结果，可在"最近的删除"恢复或删除；备份元数据不含网址与标题。"
- D25 草案："处理结果原因为枚举并经 L10n 中英文呈现；扫描记录不能直接删除的具体原因；同一配置文件的可删与手动部分分别处理。"

## 9. 证据路径

- 日志：`~/Developer/.sc-build/r2-privacy/logs/`（见第 3 节表）。
- 离屏渲染（测试进程内 `NSHostingView.cacheDisplay`，不是应用截图，不是屏幕捕获；用的是匿名预览夹具）：`~/Developer/.sc-build/r2-privacy/snapshots/`（zh/en × 窄 640/宽 980 × 浅/深色、展开态、"最近的删除"弹层）。生成它们的临时测试未提交，副本在本会话 scratchpad。
- 红阶段失败的 16 条测试：`BrowserPrivacyHistoryProcessorTests.{testChromeV70ProductionAdjustsVisitedLinkCountsLikeChromium, testChromeV70ProductionAuthorizerAllowsOnlyThePageDeletionWriteSet, testChromeV70ProductionCleansClustersWithoutOptionalClusterTables, testChromeV70ProductionDeletesEveryVisitOfAMultiVisitPage, testChromeV70ProductionDeletesTheOnlyVisitOfAPageAndItsURLRow, testChromeV70ProductionKeepsOpenerColumnOfOtherVisitsUntouched, testChromeV70ProductionPartialDeleteKeepsURLRowWithChromiumCounters, testChromeV70ProductionRemovesClusterReferencesAndEmptiedClusters, testChromiumV70FixtureDeletesLastVisitTogetherWithItsURLRow, testFailureDetailFollowsTheAppLanguageAndNamesTheRealCause}`、`BrowserPrivacyRecordScannerTests.{testBetaBrowserPrivacyPreviewUsesAnonymousInMemoryRecords, testResultSortReordersTheDisplayedPages, testSafariRealSchemaReadsEachVisitTitleFromHistoryVisits, testSearchMatchesAddressTitleBrowserProfileNameAndCategoryNamesInBothLanguages}`、`PrivacyCleanupPresentationTests.{testRedPhaseRowIdentifiesThePageWithoutATitle（旧接口版，已被 D20 测试取代）, testSidebarAndDocumentsDescribeTheCurrentBrowserPrivacyBehaviour}`。

### 严格并发构建结果

`swift build --scratch-path ~/Developer/.sc-build/r2-privacy/concurrency --jobs 4 --skip-update --disable-automatic-resolution -Xswiftc -strict-concurrency=complete`：Build complete，109 s，exit 0；日志中唯一的 warning 是 SwiftPM 对 `--skip-update` 选项的弃用提示，没有并发诊断（Package 为 Swift 6 语言模式，完整并发检查本就生效）。
