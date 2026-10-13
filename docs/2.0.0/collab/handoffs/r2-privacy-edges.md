# r2-privacy-edges：N12 浏览器隐私备份边界

日期：2026-10-07。worktree：`~/Developer/sc-worktrees/r2-privacy-edges`；分支：`task/r2-privacy-edges`；基线：`9e53489e06f6a4e08540a9e0538bb9139cc338e7`；scratch：`~/Developer/.sc-build/r2-privacy-edges/`。

本批代码、测试源码和补丁已准备，构建／原生测试／红绿／反证均 **NOT RUN**。Codex 沙箱禁止编译、测试和写 `.git`；主会话须在沙箱外验证、复核、提交。本批没有安装、启动应用、操作真实浏览器数据库、读取凭据或改 Time Machine 系统配置。没有修改 `ScanStore.swift`、`DECISIONS.md`、`BOARD.md` 或既有测试。

已阅读 RULES 全文，DECISIONS D5、D20、D26、D34–D37、D48、D55、D60，看板 N12 和 r2-privacy 第三轮。JEV 的 `jev_decide` 请求被工具层拒绝：`MCP tool call requires approval, but approval policy is never`；请求未执行，模型标识／参数也未取得，不能声称获得 JEV 判断。当前会话没有暴露生成模型的可靠标识，补丁说明使用 `Generated-By: Codex (model-not-exposed)`，不把 D55 的默认派工型号当成实际模型证明。

## 1. 恢复源与定时清理

原因：旧处理器只在撤销备份摘要的裁剪中传 `sparing`；恢复源的 `restoredAt` 要到 `BrowserPrivacyRecoveryStore` 收到结果后才写。独立服务实例的定时清理既看不到一次性的 `sparing`，又可能在复制结束与标记之间选中恢复源。单纯提前写标记仍不足：清理可能已经拿到旧的待删除名单。

改动：

- 新 `BrowserPrivacyRecoveryLease` 复用 `SQLiteSnapshotService.leaseFileName`（`.lease`）、`flock(LOCK_EX | LOCK_NB)`、不跟随符号链接的文件打开方式。描述符由 `NSLock` 保护，只关闭一次；租约本身没有全局注册表。
- 处理器在保存当前状态之前取得恢复源租约，先原子写 `restorePending = true`，再保存撤销备份与执行复制。通过 `defer { withExtendedLifetime(...) {} }` 跨所有 `await` 保持租约。
- 复制与复核成功后，处理器在同一租约内通过 `finishRestoring` 写 `restoredAt` 并清除 `restorePending`，随后记录撤销备份摘要。界面层不再另写“已恢复”；移除不再被调用的旧 `markRestored` 入口。
- 到期删除、数量裁剪及显式删除均取得同一目录租约。数量裁剪在锁内重新读元数据与完整性，再决定是否删除。`beforeRemovalHook` 只为测试确定性交错，生产为 nil。
- 若最终标记写失败，处理器报告失败并保留可能已改动的当前状态备份；恢复源落盘的 `restorePending` 仍使它不计入数量上限。未触及数据库的失败也保守留下这个标记，避免失败后的独立清理抢走重试来源；它不表示“已恢复”。标记不会延长七天期限，显式删除仍可在租约释放后执行。

不会再有原窗口的理由：清理先胜出，则取得租约／读取元数据失败，恢复在保存撤销状态之前返回，目标库不写；恢复先胜出，则全部删除路径的非阻塞租约失败，不能删；恢复释放后，锁内复查会看到 `restoredAt` 或 `restorePending`，即使候选名单来自恢复之前也不能按数量裁剪。到期删除在活动租约释放后仍遵守 D26，而活动恢复期间不会删除源。

定向方法：

1. `testRestoreSourceIsProtectedDuringCopyAndBeforeTheRestoredMarker`：异步替身在复制前及复制后暂停；独立服务的定时循环按源的到期时间运行，源保留、显式删除拒绝；完成后标记已落盘，后续按数量清理仍保留。
2. `testFailedFinalMarkerKeepsTheSourceOutOfTheCountLimitButStillExpires`：注入最终标记失败，确认复制确已发生、未谎报成功、撤销状态仍在，释放租约后仍豁免数量、七天后仍过期。
3. `testPruningRechecksAVictimRestoredBetweenSelectionAndLeaseAcquisition`：清理先选中最旧的源，钩子内取得并释放恢复租约、写好标记；实际删除必须复查，旧候选不得删除。
4. `testCleanupWinningBeforeTheRestoreLeaseNeverWritesTheDestination`：临时源先被清理，恢复失败，目标逐表一致，不创建撤销备份。

**红（主会话执行）**：在独立反证副本保留新增接口，但把 `beginRestoring` 改为返回 nil、不写保护标记，把 `finishRestoring` 改为空操作，重现基线缺少整个恢复租约的行为；运行方法 1，应断言源被定时清理、恢复不能成功。暂停替身在处理器提前返回时也唤醒等待者，失败不应挂死。基线本身缺新接口，不能直接拿新测试编译失败充当红证据。

**绿**：最终源码运行上述四项，所有断言通过，且没有跳过。方法 4 是边界保护测试，修前可通过，不把它算作红证据。

**反证（逐个独立变异）**：①私有 `remove` 中把租约取得改为 `let lease: BrowserPrivacyRecoveryLease? = nil`，方法 1 应在活动恢复期间到期删除源；②去掉 `metadata.restorePending = true`，方法 2 应在后续数量裁剪失去源；③去掉私有 `remove` 的 `shouldRemove(...)` 守卫，方法 3 应因旧候选被删失败。各变异只改产品源码，不改测试。

## 2. 十二份上限与完整性

原因：旧 `countsTowardsLimit` 只看结果枚举和 `restoredAt`，`unverified` 被当作已确认；有完整摘要却丢失、被破坏或被替换成链接的数据库也可能挤掉正常备份。

改动：数量候选必须同时有匹配目录 UUID 的元数据、完整摘要、可解析的 SHA-256、普通数据库文件及实际内容摘要一致；没有结果、已恢复、恢复待确认或结果未知的备份不计数。只在数量判断及数量删除前做摘要校验；查最早到期、到期删除及显式删除只读元数据，不额外重复读取数据库内容。排序和 12 份常量不变。

**待主会话裁定的解释**：D26 定义七天／十二份，第三轮 P2-B5 已把 `restoreUnconfirmed`、`unexpectedError` 排除，却明确说 `unverified` 当时未在复核清单而继续计数；D 编号条目没有给后者明确结论。本批按用户授权二选一，选择 **不计入**：提交成功不能代替最后复核成功，结果仍未确认；使它与其余未确认结果一致，避免挤掉正常备份或失去可能唯一的回退来源。仍可手动删除，仍按原创建时间七天过期。未改 DECISIONS，也没有把这个选择写成已获产品裁定。

定向方法：`testUnverifiedBackupsDoNotDisplaceAnyOfTwelveConfirmedBackupsAndStillExpire` 使用真实常量 12，保留十二份确认备份与一份未确认备份；第十三份确认备份只挤掉最旧的确认备份，未确认备份仍按七天消失。`testIncompleteOrDigestMismatchedBackupsCannotDisplaceACompleteBackup` 的五种临时夹具：缺文件、改字节、符号链接、坏摘要、缺摘要字段。

**红**：保留接口，恢复旧 `leavesTheResultUnknown` 两个 case 分组（`.restoreUnconfirmed, .unexpectedError: true`，`.deleted, .unverified, .restoredAfterFailure, .savedBeforeRestore: false`），十二份边界测试应失败；从 `countsTowardsLimit` 的 guard 去掉 `isComplete`，完整性测试应因正常旧备份被裁失败。

**绿**：最终两项通过，原 `BrowserPrivacyRecoveryTests` 的未知结果、到期与数量测试也通过。

**反证**：两种红变异分别作为单故障反证执行；另把 `.unverified` 加入数量豁免但把过期循环也按 `leavesTheResultUnknown` 跳过，十二份测试的七天过期断言必须失败，防止把数量保护错误扩展成无限保留。

## 3. 进行中备份的显示与连续时钟

原因：旧列表用 `now.timeIntervalSince(createdAt) > 120` 推断操作已不在进行。墙上时间跳变影响判断，睡眠也可能使尚未结束的操作超出该门槛。

改动：元数据版本 3 保存 `mach_continuous_time` 经 timebase 换算的秒数及 `kern.bootsessionuuid`。通过 `continuousNow` 注入读数；两分钟只比较同一启动周期的连续读数。创建日期继续管排序与七天到期。读不到连续时钟的新备份不以墙上时间代替；有摘要后立即列出。旧版本无读数的遗留备份、不同启动周期的备份属于已中断操作，可作为结果未知列出；不会把重启后的较小读数误判成当前操作。

语义必须分清：`mach_continuous_time` **在睡眠期间继续计时**，与现有维护循环的 `ContinuousClock`、`EnergyModelCounterReader.continuousNow` 一致。两分钟指真实经过时间，不是仅醒着的两分钟。本批另让 `backup()` 返回的句柄持有写入租约，直到 `annotate` 写摘要或 `discard` 丢弃；列表对无摘要项再检查活动租约。这样尚在执行的操作睡眠一小时仍不列出，已经中断且没有结果的备份才使用两分钟门槛。句柄的 `Equatable` 只比较持久化的 id、路径、摘要与创建时间，租约对象不参与相等性。

定向方法（均注入时钟，不睡眠、不改系统时间）：

- `testUnfinishedVisibilityUsesContinuousElapsedTimeAndIgnoresWallJumps`：操作中断后释放租约，119.999 秒、120 秒隐藏；120.001 秒显示；墙上时间前跳一小时／后退一小时不影响，倒退的连续读数不推断已过去。
- `testAnActiveBackupStaysHiddenWhenSleepPassesTheTwoMinuteAllowance`：仍持有写入租约，连续时钟推进一小时，独立服务仍不列出；摘要写完立刻显示。
- `testFinishedBackupIsVisibleImmediatelyWithoutWaitingForTheClock`、`testOldBootAndLegacyUnfinishedBackupsAreNotMistakenForAnActiveOperation`、`testUnavailableContinuousClockNeverFallsBackToWallTime`：完成、重启、旧格式及不可用时钟的分支。
- `testProductionClockUsesTheContinuousCounterAndABootIdentity`：源码契约锁定平台时钟绑定与启动标识，避免仅假时钟测试通过、生产误用停止于睡眠的时钟。

**红**：在最终接口下恢复墙上时间门槛，并去掉租约显示检查，时间跳变及活动睡眠两项均应失败。

**绿**：最终六项及原 `testBackupsStillBeingWrittenNeitherCountNorShow` 通过。

**反证**：①只去掉 `!BrowserPrivacyRecoveryLease.isInUse(in: directory)`，活动睡眠项失败；②只把 `mach_continuous_time()` 换成 `mach_absolute_time()`，平台绑定项失败；③只在显示门槛加回墙上时间判断，时间跳变项失败；④把新格式缺时钟读数改成允许显示，不可用时钟项失败。不要改测试中的边界值或断言。

## 4. 时间机器排除失败

原因：旧实现调用 `setResourceValues`，临时目录里难以稳定制造失败，因此第三轮没有失败路径测试。

改动：注入 `excludeFromTimeMachine` 写入器；默认仍使用现有平台能力。调用顺序不变：根目录准备 → 排除标记 → 创建 UUID 备份目录 → 读取源库。标记失败转换为带明确原因的 `BrowserPrivacyBackupStorageFailure`，处理器返回新原因 `backupExclusionFailed`。中英文都解释无法排除在时间机器之外、没有备份也没有删除记录；普通目录写失败仍用旧 `.backupFailed`。启动／维护给旧根目录补标记也走同一注入器。

定向方法：`testExclusionFailureCreatesNoBackupAndDeletionExplainsWhyNothingChanged` 两次使用抛错替身：直接备份必须抛出明确类型，根目录无 UUID 子目录、快照临时根目录为空；处理器返回失败及用户可读原因，目标逐表一致，无恢复 ID。`testMaintenanceUsesTheInjectedExclusionWriterForALegacyRoot` 记录调用，证明维护没有绕过接缝去改真实资源标记。

**红**：把备份准备中的排除调用恢复为无法注入的旧 `Self.excludeFromTimeMachine(canonicalRoot)`，失败测试应因注入未被调用、继续备份／删除而失败。只在临时夹具副本运行；这会写临时目录的资源标记，不允许换成真实根目录。

**绿**：最终两项通过，原真实临时目录资源标记测试 `testRecoveryFolderIsExcludedFromTimeMachine` 与普通备份失败测试仍通过。

**反证**：只将排除调用的错误吞掉（`try? excludeFromTimeMachine(canonicalRoot)`，移除对应重新抛错的 do/catch），失败项必须检测到建了备份及删除发生；或只改映射为旧 `.backupFailed`，失败项必须检测到缺失具体用户原因。

## 5. 旧断言、分组及验证状态

旧断言改写清单：**空**。所有既有测试文件逐字节保留；新 `BrowserPrivacyRecoveryEdgesTests` 有 14 个方法，无 `XCTSkip`，不使用 `UserDefaults`。所有新测试复用临时目录的 `ChromiumV70HistoryFixture`；每个新服务都显式注入临时根目录、临时 SQLite 快照根目录、假时钟及不写资源标记的替身／失败替身。异步暂停用 actor 和 continuation；观察值用 `NSLock` 保护，未把数据库夹具声称为 Sendable。

补丁目录：`~/Developer/.sc-build/r2-privacy-edges/prepared/`，顺序：

1. `01-recovery-code.patch`：六个产品源码文件，租约／完整性／连续时钟／失败原因及调用接线。
2. `02-regression-tests.patch`：新增定向测试类，14 方法。
3. `03-handoff.patch`：本交接。

`all.patch` 为三组原样拼接；`manifest.json` 包含完整基线、分支、组顺序、八个最终文件 SHA-256 及产物 SHA-256。`commit-prepared.py` 只供主会话完成验证后按组提交，不在本会话执行。补丁静态核对的实际命令、exit code 与未运行项见 `prepared/static-checks.json`；不能把补丁校验当作编译或测试通过。

| 项目 | 本会话状态 | 证据 |
|---|---|---|
| 基线／分支／初始工作区 | PASS | HEAD 完整值等于上述基线，分支正确，初始 `git status --short` 为空 |
| 改动范围／原测试／ScanStore | PASS（静态） | manifest 与 static-checks，八个交付文件；旧测试与 ScanStore 无改动 |
| 空白、补丁反向可应用、分组覆盖、最终文件哈希 | PASS（静态） | 生成器成功返回后以 `prepared/static-checks.json` 的具体命令为准 |
| Swift 6 编译／隔离／并发检查 | NOT RUN | 沙箱规则，不执行编译 |
| 定向／全量 XCTest、TestPreferenceHygieneTests | NOT RUN | 原生测试执行 0，跳过数未产生 |
| 红／绿／反证 | NOT RUN | 第 1–4 节为主会话执行方案，不是已发生结果 |
| 私有接口守卫、verify 门禁 | NOT RUN | 未运行项目测试／门禁脚本 |
| JEV | BLOCKED | 工具调用被 never 审批策略阻止，未获得判断 |
| 提交／复核／合并／安装／实机 | NOT RUN | 主会话负责 |

## 6. 主会话命令与定向测试类

以下命令仅给主会话在沙箱外执行。依赖如需离线准备，按 RULES 从保留的 `r2-u1-preselect/debug` 依赖拷贝，不共用其他批次的构建缓存。构建和反证临时产物用完按 RULES 清理，保留日志／证据。

```bash
cd ~/Developer/sc-worktrees/r2-privacy-edges
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path ~/Developer/.sc-build/r2-privacy-edges/debug --jobs 4 --skip-update --disable-automatic-resolution
swift test --scratch-path ~/Developer/.sc-build/r2-privacy-edges/debug --jobs 4 --skip-update --disable-automatic-resolution --filter 'BrowserPrivacyRecoveryEdgesTests|BrowserPrivacyRecoveryTests|BrowserPrivacyHistoryProcessorTests|PrivacyCleanupPresentationTests|TestPreferenceHygieneTests'
swift build --scratch-path ~/Developer/.sc-build/r2-privacy-edges/strict --jobs 4 --skip-update --disable-automatic-resolution -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors
export STORAGE_CLEANER_VERIFY_ROOT="$HOME/Developer/.sc-build/r2-privacy-edges/verify"
export STORAGE_CLEANER_VERIFY_BUNDLE=0
export STORAGE_CLEANER_UI_SMOKE=0
script/verify.sh
```

重点测试类：`BrowserPrivacyRecoveryEdgesTests`、`BrowserPrivacyRecoveryTests`、`BrowserPrivacyHistoryProcessorTests`、`PrivacyCleanupPresentationTests`、`TestPreferenceHygieneTests`。完整门禁仍按 RULES，由主会话在集成分支执行。

单方法反证命令模板（把 `<方法名>` 换成第 1–4 节给出的实际方法名；每种变异独立应用、执行、还原）：

```bash
swift test --scratch-path ~/Developer/.sc-build/r2-privacy-edges/debug --jobs 4 --skip-update --disable-automatic-resolution --filter 'BrowserPrivacyRecoveryEdgesTests.<方法名>'
```

对每次红／反证记录故障改动、命令、exit code、失败断言、日志路径。先备份被变异的最终文件进本批 scratch，执行后从备份恢复并用 SHA-256 与 manifest 核对；不要通过删断言、改阈值或跳过来取得绿色。避免在同一个副本叠加变异；无须创建另一个原生应用或使用真实浏览器数据。

验证和独立复核完成后再由主会话执行：

```bash
python3 ~/Developer/.sc-build/r2-privacy-edges/prepared/commit-prepared.py
```

## 7. 尚待确认与实际限制

- 未取得编译、原生测试和反证结果，特别需主会话核对 Darwin 的 `openat`／`flock` 调用、Swift 6 严格并发和 actor 暂停替身；如编译报错，交回同一 Codex 会话修改并重生成产物。
- `unverified` 不计数是本批按授权作出的保守解释，须主会话裁定；恢复失败留下 `restorePending` 的保守计数语义也请复核，不改变七天期限。
- 对尚在执行的恢复，七天到期可能因租约短暂延迟到下一次维护检查；这是保护活动恢复所必需，租约释放后仍可按原期限删除，没有新建全局状态或无限延长有效期。
- 新格式若连续时钟读取不可用且摘要一直写不成，条目不会用墙上时间猜测可显示；目录仍按原七天到期。旧格式／上次启动的未知结果备份继续可供核对。
- 完整性校验增加数量裁剪时读取备份文件的成本；仅对原本可能计数的候选计算，已恢复／未知结果／进行中不重复计算。主会话原有性能门禁不应放宽。
- 本批没有证明 Time Machine 服务实际采用该目录标记，也没有操作真实浏览器；测试证明失败接缝、操作顺序与数据未改，原资源标记测试证明的仍只是临时目录资源值。

## 主会话验证结果（2026-10-07 22:1x）

- **提交**：Codex 三组按 `prepared/commit-prepared.py` 提交，哈希校验通过：
  - `329e701` 产品源码；
  - `b89fa55` 回归测试；
  - `c442067` 交接。
  - 提交说明里的模型名按派工记录改为 `openai/gpt-6.1-sol`。
- **构建**：`swift build --build-tests`（scratch `~/Developer/.sc-build/r2-privacy-edges/debug`，离线参数）exit 0。本批文件无新警告；唯一的警告是既有的 `BrowserPrivacyRecoveryTests.swift:467`。
- **定向测试**：`BrowserPrivacyRecoveryEdgesTests|BrowserPrivacyRecoveryTests|BrowserPrivacyHistoryProcessorTests|PrivacyCleanupPresentationTests|TestPreferenceHygieneTests` 共 146 个，0 失败，exit 0。
- **反证**（`~/Developer/.sc-build/r2-privacy-edges/rp.py`，每轮后 `git checkout -- Sources` 还原，工作区干净）：
  1. 删除路径不取目录租约 → 12 处失败，含 `testRestoreSourceIsProtectedDuringCopyAndBeforeTheRestoredMarker`。
  2. `unverified` 重新计入 12 份 → `testUnverifiedBackupsDoNotDisplaceAnyOfTwelveConfirmedBackupsAndStillExpire` 失败。
  3. 有写入方持有租约时不再隐藏未完成备份 → `testAnActiveBackupStaysHiddenWhenSleepPassesTheTwoMinuteAllowance` 失败。
  4. 时间机器排除失败被忽略 → `testExclusionFailureCreatesNoBackupAndDeletionExplainsWhyNothingChanged` 失败。
- **`unverified` 是否计入**：D26 补充写明“进行中、已恢复过、结果未知的备份不计入（仍 7 天到期）”。`unverified`（已删除但提交后复核未通过）属于结果未知，所以不计入，与既有决定一致，不需另行裁定。
- **未运行**：完整门禁、严格并发、实机（真实浏览器删除与恢复按既有授权另行实测）。

## 第 2 轮（复核修复）

日期：2026-10-07。基线为本轮开始时的当前 HEAD：`a2bc13911757b87bfc2ddea76a796bbf90f80aec`；分支仍为 `task/r2-privacy-edges`。已阅读独立 Astra 复核 `review/review-1.md`、上述主会话验证记录，以及 D26 原文与补充、D48、D60。本轮初始工作区干净；只修改本 worktree 的两个产品文件、定向测试文件和本交接，产物写入 `~/Developer/.sc-build/r2-privacy-edges/prepared-r2/`。保留第一轮交接和验证原文；第一轮的构建、146 个测试和反证结果不作为本轮验证结果。

本轮完成代码与测试源码准备，**没有编译、运行测试、执行红／绿／反证或提交**，也没有安装、启动应用或操作真实浏览器、Time Machine 设置、偏好。改动与产物静态检查以 `prepared-r2/static-checks.json` 中的实际命令、exit code 为准。未修改 `ScanStore.swift`、`DECISIONS.md`、`BOARD.md` 或夹具根目录定义。

### 1. P1：先原子退休目录，再递归删除

- `BrowserPrivacyRecoveryLease` 保存取锁时的目录 device/inode。删除持有源租约，复查目录身份后，用 POSIX `rename` 将目录移到同一恢复根目录下的 `.deleting-<UUID>`，才调用递归删除。重命名失败时不递归删除原目录。手动删除、到期删除、数量裁剪、已取得写入租约的备份失败清理均使用这条路径。
- 在恢复根目录永久保留隐藏的 `.recovery-namespace.lease`，复用非阻塞 `flock` 和文件安全检查；它只保护子目录租约的打开／补建和原子重命名。旧格式或孤儿目录可能没有 `.lease`，仅在取锁后复查路径仍可能沿旧目录描述符在墓碑里新建锁；这个短时根租约把补建与重命名互斥。数据库复制、摘要校验和墓碑递归删除都不持有根租约，且不引入进程内锁注册表。
- 取源租约只接受 UUID 目录。恢复的开始、低层复制和最终标记均检查源是本服务恢复根下的原 UUID 目录；墓碑路径和已消失的原路径失败关闭。恢复名单及到期调度继续只枚举非隐藏 UUID 目录。
- `purgeExpired` 在到期／数量维护前清理中断的墓碑，接入既有启动、每小时和打开页面维护，不新增另一套调度。只接受私有恢复根目录中 `.deleting-<UUID>` 的同文件系统、当前用户拥有的真实目录，不跟随链接、不处理非 UUID 名称。递归删除失败时返回失败并留下不可恢复的墓碑，不声称其中的数据已被清除；后续维护重试。根命名空间锁文件不参与列表、计数或清理。
- 新增 `removeTombstone` 注入接缝，生产默认仍为 `FileManager.removeItem`。测试在 detached 删除工作线程移除 `.lease` 后暂停，保留数据库和元数据；主 actor 在此时完成恢复尝试，无 sleep 或真实数据。删除若未进入接缝，完成通知唤醒等待者并让断言失败，不会因等不到交错点挂死。

新增定向方法：

1. `testRestoreDuringDeletionAfterLeaseUnlinkNeverWritesTheDestination`：原路径已退休；数据仍在墓碑；持删除租约时 `.lease` 已移除；源恢复和直接指向墓碑的低层恢复均拒绝；目标逐表不变，不开始撤销备份，不在墓碑补建第二把锁，墓碑不列出。另一备份仍能取租约，证明递归删除没有占用根租约；放行后墓碑删净。
2. `testMaintenanceFinishesInterruptedTombstonesWithoutFollowingLinks`：递归删除接缝抛错，中断墓碑保留数据但不可列出、调度或恢复；新的服务实例维护立即清理，不等七天；同前缀链接、非 UUID 目录及夹具外侧哨兵保留。

**红（主会话执行）**：保留最终接缝和接口，在 `retireAndRemove` 中把取得墓碑的语句改为 `let tombstone = directory`，恢复第一轮原地递归删除；方法 1 应在固定交错点检测到原路径仍在、恢复重新建锁并写入目标，不能成功报告保护成立。方法 2 也应发现没有墓碑。基线缺少新接缝，直接编译基线时报缺接口不算红证据。

**绿**：最终源码运行两项新增方法，以及原 `testRestoreSourceIsProtectedDuringCopyAndBeforeTheRestoredMarker`、`testCleanupWinningBeforeTheRestoreLeaseNeverWritesTheDestination`、`testPruningRechecksAVictimRestoredBetweenSelectionAndLeaseAcquisition` 和原孤儿／链接删除测试；全部断言通过且无跳过。

**反证**：①独立重复上述原地删除变异，方法 1 必须失败；②只把 `purgeTombstones` 改为返回 0，方法 2 的立即清理断言必须失败；③只移除低层 `restore` 的 `liveDirectory` 守卫，方法 1 直接指定墓碑的恢复拒绝及目标不变断言必须失败。每个变异独立执行，测试保持不变。

### 2. P2：旧格式恢复后仍可见、可删除，原期限不变

`entries` 将 `restoredAt != nil` 与已有摘要同样视为完成，绕过未完成备份的连续时钟／活动写入门槛。`finishRestoring` 仍只写版本与恢复结果，不补写 `continuousCreatedAt` 或 `bootSessionIdentifier`，`createdAt` 保持不变。

新增 `testLegacyBackupsStayVisibleAfterRestoringAndKeepTheirOriginalExpiry`：两份临时旧格式备份无摘要、无时钟、无租约；恢复后刷新仍显示已恢复，无伪造时钟、创建日期与到期日逐项保持原值。一份刷新后手动删除，另一份在原到期日前 0.001 秒保留、原到期日删除；恢复成功不会重启七天期限。

**红**：仅删除 `entries` 中的 `metadata.restoredAt != nil` 分支；实际恢复成功后，刷新取不到旧备份，新增方法应失败。

**绿**：最终新增方法与原 `testOldBootAndLegacyUnfinishedBackupsAreNotMistakenForAnActiveOperation`、`testUnavailableContinuousClockNeverFallsBackToWallTime` 通过，原两分钟和睡眠断言保持。

**反证**：①独立重复可见性红变异；②只在 `finishRestoring` 中给旧备份写入当前连续时钟及启动标识，新增方法的两项字段缺失断言必须失败，不能靠补假创建时钟取绿；③若把恢复日期用作新到期起点，创建日期／到期日和原期限删除断言必须失败。

### 3. P2 裁定：更早 2.0 测试版的降级保护不在支持范围

按主会话裁定，不实现旧读取器兼容、状态降级编码或隔离新目录。浏览器隐私备份是 2.0 新功能，正式版没有这一功能，同一时间只安装一个测试版。

**已知限制：降级到更早的 2.0 测试版后，`restorePending` 等新保护不被识别。** 旧版能解码元数据不等于识别保护语义；不能承诺降级后的数量豁免或新墓碑维护。此项按明确裁定记录限制，不补旧读取器测试。

### 4. P2：先筛数量候选，再按需验证内容

- 将数量资格拆成只读元数据／文件类型的 `mayCountTowardsLimit` 与已验证 SHA-256 的 `isComplete`。只有 UUID 与元数据一致、摘要完整、摘要值可解析、普通数据库文件且结果已确认、未恢复、未待确认的备份可能计数；先排除 `sparing`。
- 候选总数不超过实际配置上限（生产为 12）立即返回，数量裁剪不读取数据库内容。创建备份和真实恢复本身的摘要验证保持原实现；读取计数替身只记录数量裁剪的额外验证，不能声称备份创建也不读内容。
- 只有可能超限时，对这些候选计算 SHA-256，完整候选按既有日期排序裁剪；真正删除前在源租约内重新读取元数据与 SHA-256。未确认、已恢复、待确认、未完成／缺摘要和被 `sparing` 保护的项不参与这一轮内容验证；七天过期和显式删除仍不因数量条件增加内容读取。
- 复用现有 `CleanupContentDigestReading`，注入仅用于数量校验的 `countDigestReader`，生产为 `FoundationCleanupContentDigestReader`。测试记录读取 URL，不改分块算法，不缓存摘要，不放宽 12 份阈值。

新增定向方法：

1. `testCountPruningDoesNotReadContentAtOrBelowTwelveCandidates`：从 1 到实际 12 份逐次摘要写入和维护，每步裁剪内容读取均为 0；再加入未知、未完成和已恢复目录，仍只有 12 个候选，读取继续为 0。
2. `testOverLimitPruningHashesOnlyEligibleCandidatesAndRechecksTheVictim`：13 个确认候选和六类非参与项；仅 13 个候选各读一次，最旧的实际删除项在锁内再读一次，共 14 次；六类非参与项为 0 次，只删除最旧确认项。裁到 12 后再次维护不增加读取。
3. `testCountPruningRejectsContentChangedBetweenSelectionAndTheLockedRecheck`：选中待删项后、取锁前改写其夹具文件；锁内第二次摘要发现不一致，拒绝按旧名单删除，两份目录都保留。

**红**：仅移除 `candidates.count > maximumBackups` 的早返回守卫，让不超限的候选也计算摘要；方法 1 必须在零读取断言失败。只恢复旧全量校验行为即可，不把接口缺失当红。

**绿**：最终三项新增方法、原 `testIncompleteOrDigestMismatchedBackupsCannotDisplaceACompleteBackup`、未知结果数量／七天测试、旧候选恢复复查测试通过；方法 2 断言的实际读取分布为 13+1，下一次为 0。

**反证**：①独立重复无早返回红变异；②只从候选过滤中移除 `sparing`，方法 2 必须检测到读取了受保护项并裁多一份；③只移除私有 `remove` 中的 `shouldRemove(ownedDirectory(...))` 守卫，方法 3 及旧候选复查测试必须因缺少锁内复查而失败；不删断言或缩小生产上限。

### 5. 改写断言、分组与主会话验证

**改写的已有断言清单：空；删除的已有断言：空；放宽的阈值：空。** 本轮保留原 14 个边界方法全文，只扩展 `makeService` 注入参数并新增两个线程安全替身／删除暂停器及六个测试方法，定向类共 20 方法。其他既有测试文件、`ChromiumV70HistoryFixture` 和 `TestPreferenceDomain` 逐字节保持基线；没有改变任何临时根目录的位置，没有 `XCTSkip`，没有新增偏好或 Time Machine 资源值写入。

`prepared-r2/` 格式同 `prepared/`，基线为本轮完整 HEAD：

1. `01-recovery-code.patch`：`BrowserPrivacyRecoveryLease.swift`、`BrowserPrivacyRecoveryBackupService.swift`，覆盖三项必须修复的产品行为。
2. `02-regression-tests.patch`：`BrowserPrivacyRecoveryEdgesTests.swift`，六个新增方法及注入／暂停替身。
3. `03-handoff.patch`：仅追加本节，保留第一轮和主会话验证记录。

`all.patch` 按组三份原样拼接；manifest 记录四个最终文件 SHA-256、组顺序及产物 SHA-256，提交说明末尾固定为本次要求的 `Generated-By: Codex (openai/gpt-6.1-sol)` 与 Claude Opus 5.5 co-author。生成与静态检查脚本不写 `.git`；`commit-prepared.py` 只供主会话完成验证后执行，本轮未执行。

JEV：核对当前可调用的 `jev_decide` 参数，没有 `model`／推理配置字段，判断模型由服务选择，具体模型标识未暴露。本轮请求被工具层拒绝：`MCP tool call requires approval, but approval policy is never`；没有实际模型调用或 JEV 判断。未换模型、未委派新子代理；本轮自检不算新的独立复核。

主会话必须在沙箱外执行（依赖与离线参数沿用第一轮环境；不要更换夹具根目录）：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --build-tests --scratch-path ~/Developer/.sc-build/r2-privacy-edges/debug --jobs 4
swift test --scratch-path ~/Developer/.sc-build/r2-privacy-edges/debug --jobs 4 --filter 'BrowserPrivacyRecoveryEdgesTests|BrowserPrivacyRecoveryTests|BrowserPrivacyHistoryProcessorTests|PrivacyCleanupPresentationTests|TestPreferenceHygieneTests'
```

先跑新增六项及相关旧方法取得最终绿色，再在隔离反证副本或完整源码备份上逐个执行上述红／反证。各变异仅改产品实现，测试文件和阈值不变；每轮记录 exit code、失败断言与日志。还原用最终源码备份，**不要用基线 `git checkout -- Sources` 覆盖本轮修复**；还原后核对 manifest 四份文件哈希。反证／临时构建用完按 RULES 清理，只留日志与证据。主会话再做独立复核、完整门禁和严格并发，确认无问题后使用 `prepared-r2/commit-prepared.py` 提交。

剩余验证限制：本轮原生测试执行 0，构建、严格并发、红／绿／反证、完整门禁、独立复核及实机均 **NOT RUN**；特别需核对新根租约的 Darwin 接口、Swift 并发捕获和 detached 删除暂停器。没有把静态推理或第一轮绿色当成本轮问题已经通过验证。降级不支持的限制见第 3 项；删除中断后的隐私数据由下一次既有维护重试清除，不能承诺递归删除失败时已经清除。

### 第 2 轮补修（r2b）：恢复错误按发生位置归因

基线 `434b548bd66d73a445dc5e4cf04c5cb4f08309cb`，初始工作区干净。主会话反馈该基线编译通过、定向 152 项中 1 项失败：`BrowserPrivacyRecoveryTests.testRestoreThatCannotSaveTheCurrentStateFirstDoesNotStart` 实际返回 `databaseChanged`，应为 `currentStateNotSaved`。这是主会话提供的结果；本补修没有重跑，也不沿用为本轮通过证据。

- **产品修正**：`beginRestoring` 先复用 `backup` 的恢复根准备逻辑，根被普通文件占住时先报存储失败；根命名空间租约失败、源仍在时墓碑重命名失败，以及恢复前保护标记写失败，使用 `BrowserPrivacyBackupStorageFailure`。处理器的恢复准备阶段将其映射为 `currentStateNotSaved`，在浏览器数据库写入前返回。源租约仍先于撤销备份，并覆盖最终标记；不回退原子墓碑保护。
- **同类错位**：源租约忙改为 `backupInUse`，源目录／元数据／内容缺失、不可读或损坏改为 `backupUnavailable`；`SQLitePersistentBackupFailure` 区分写备份文件与读源备份，撤销文件位置失败不冒充浏览器权限或身份问题，真正的目标数据库 busy／permission／unavailable 保留原映射，取消／超时保留。最终标记失败单独为 `restoreResultNotSaved`，不再说浏览器无写权限或恢复未开始，并保留有写入时的撤销备份。新增两项原因的中英文文案由既有全枚举文案测试覆盖。
- **范围**：修改 `BrowserPrivacyHistoryProcessor.swift`、`BrowserPrivacyProcessingReason.swift`、`BrowserPrivacyRecoveryBackupService.swift`、`BrowserPrivacyRecoveryLease.swift`、`SQLiteSnapshotService.swift`，以及边界测试、本交接。共享 SQLite 文件只改两个持久备份接口及其错误类型／私有包装器，当前产品调用方仅浏览器隐私备份服务；普通快照扫描实现不变。没有改 `ScanStore.swift`、决策、看板、夹具根目录、真实浏览器、偏好或 Time Machine 设置。
- **断言清单**：用户指出的 `BrowserPrivacyRecoveryTests.swift` 全文件逐字节保持基线。唯一改写在 `BrowserPrivacyRecoveryEdgesTests.testRestoreDuringDeletionAfterLeaseUnlinkNeverWritesTheDestination`：低层错误从 `SQLiteSnapshotFailure.unavailable` 改为 `SQLitePersistentBackupFailure.sourceRead(.unavailable)`，保留原错误含义并验证来源；该方法其余断言及另外 19 个原方法全文保持。没有删除断言、放宽阈值或新增跳过。
- **新增六项源码**：`testRestoreRootNamespaceFailuresDoNotBlameTheBrowserOrSource`、`testMissingReplacedAndBusySourcesKeepTheirOwnRestoreReasons`、`testTombstoneWriteFailureIsStorageFailureAndKeepsTheSource`、`testPersistentBackupIOFailuresDistinguishRecoveryStorageSourceAndLiveDatabase`、`testRestoreFailureMappingUsesTheFailingStage`、`testFinalMarkerFailureReportsAnUnrecordedResultAndKeepsUndo`。只用原临时夹具，覆盖真实根锁忙／锁路径非法、源缺失／替换／忙、墓碑 rename 写失败、备份输出路径被普通文件占住、源与目标错误分离、16 个阶段映射分支及最终标记失败。根目录权限故障只施加于夹具，`defer` 恢复原 0700。
- **红／绿／反证（主会话执行）**：先原样重跑上述既有失败测试及 `testRestoreNamesWhyTheCurrentStateCouldNotBeSaved`，再跑边界类全部 26 项、双语文案和原五类定向集合。独立变异：去掉 `beginRestoring` 根准备应让根被普通文件占住的既有测试失败；把根锁错误恢复为 SQLite busy 应让根锁测试失败；去掉源错误包装应让源／目标映射测试失败；把最终标记重新交给通用映射应让最终标记测试失败。变异仅改产品，测试不变；还原用本轮最终源码备份并核对 manifest，不用基线覆盖未提交修复。
- **产物与实际验证**：`~/Developer/.sc-build/r2-privacy-edges/prepared-r2b/` 的三组分别为产品、测试、交接；完整基线、哈希、五项只读 diff／反向补丁检查及 exit code 见 `manifest.json`、`static-checks.json`。提交说明末尾按本次要求保留 `Generated-By: Codex (openai/gpt-6.1-sol)` 和 Claude Opus 5.5 co-author；提交脚本仅供主会话验证后执行。**本轮构建、原生测试、严格并发、红／绿／反证、完整门禁、独立复核、安装和提交均 NOT RUN，原生测试执行 0。**
- **JEV**：本次工具实际可用，返回模型为 `jev-latest`（provider `typesafe`，接口无模型／推理参数）；方案判断选择保留源租约并按阶段归因。补丁复核返回 `escalate`，`safe_to_apply=0.14`，正确性置信度 `0.19`，范围评分 `1.93/2`，未给具体代码问题；不记为通过。原始复核结果保存在 `prepared-r2b/jev-review.json`，主会话须复核这五个产品文件并完成上述原生验证。

## 主会话验证结果（第 2 轮与 r2b，2026-10-08 00:3x）

- **提交**：
  - 第 2 轮 `905e4d1`、`b4d6fd3`、`434b548`；
  - r2b `2b857ef`、`1e71baf`、`6bd2024`；
  - 模型名按派工记录改为 `openai/gpt-6.1-sol`。
- **第 2 轮首跑**：152 个测试中 1 个既有测试失败。`testRestoreThatCannotSaveTheCurrentStateFirstDoesNotStart` 期望 `currentStateNotSaved`，实际为 `databaseChanged`。r2b 按出错位置归因后通过，未改该测试。
- **r2b 后**：定向过滤 `BrowserPrivacy|PrivacyCleanup|SQLiteSnapshot|TestPreferenceHygieneTests` 共 236 个，跳过 1 个，0 失败。
- **反证**（`rp2.py`，每轮后还原）：
  1. 删除不先移入墓碑 → 14 处失败，含 `testRestoreDuringDeletionAfterLeaseUnlinkNeverWritesTheDestination`。
  2. 恢复过的旧格式备份不豁免显示门槛 → `testLegacyBackupsStayVisibleAfterRestoringAndKeepTheirOriginalExpiry` 失败。
  3. 未超上限也读内容 → 26 处失败，含 `testCountPruningDoesNotReadContentAtOrBelowTwelveCandidates`。

## 第 3 轮（增量复核修复）

基线 `dad96efa0b3fac44f3c000c28933038e9559600a`，分支 `task/r2-privacy-edges`，初始工作区干净。已读 `review/review-2.md`、上述主会话验证与 D26／D48／D60。复核认定原 P1 已关闭，本轮保留源租约、根命名空间锁、原子退休、旧格式显示、数量早返回和 r2b 错误归因。上述 236 项、1 项跳过、0 失败及三组反证是主会话对旧基线的证据，不作为本轮验证结果。

### 改法与范围

- **P2-1**：新墓碑名为 `.deleting-<原备份 UUID>-<删除 UUID>`，关联不依赖可能先被移除的元数据或锁文件。按原 ID 删除会继续寻找并清理关联墓碑；`isRemoved` 同时检查原路径和待清理目录，根不可读／身份变化属于未知，不能报告成功。递归删除回调无论返回或抛错，都用 `lstat` 确认墓碑路径确已消失。旧的随机 UUID 墓碑继续维护；尚有元数据时读取原 ID，来源已丢失时保守保留待清理状态，不能让某个原 ID 的重试误报成功。
- **独立反馈**：Store 新增从磁盘刷新出的 `pendingRemovalIDs`，重建 Store 后仍可找回；清除恢复结果不清除待清理警告。删除操作在维护刷新后核对最终磁盘状态再返回布尔结果，现有结果页据此显示成功或失败。“最近的删除”在可恢复列表之外显示“部分备份尚未清除”及“重试删除”，空列表时也可见；墓碑仍不提供恢复操作。中文新增文案没有英文术语、内部类型名或 UUID；沿用统一按钮、字体和颜色。
- **P2-2**：新增 `BrowserPrivacyRecoveryRoot`，先 `lstat` 拒绝配置根末级链接，再以 `O_NOFOLLOW` 打开目录，核对所有者和设备号／inode，并保留目录描述符以固定身份。该服务各入口统一使用规范路径，复查配置路径与规范路径仍指向同一目录；原路径被链接或新目录替换时失败关闭。根权限用已打开描述符设置；创建子目录、打开子租约和原子退休分别使用 `mkdirat`、`openat`、`renameat`。根准备回调后和关键读写前后再次复查，拒绝链接发生在源数据库读取／备份创建之前；删除处理显示“备份位置是一个链接，无法安全保存浏览记录备份”。父级别名（如系统临时路径的别名）仍允许，末级目录必须真实且身份一致。
- **文件**：七个产品文件：恢复处理器、原因文案、备份服务、Store、租约、新根目录支持类、`Views/BrowserPrivacyRecentDeletionsView.swift`；另修改边界测试和本交接，共九文件。`ScanStore.swift`、共享 SQLite 服务、结果页、决策、看板、偏好夹具与临时根目录定义不变。没有触碰真实浏览器、真实偏好、Time Machine 设置或已安装应用。

### 断言与测试源码

唯一既有断言改写：`testMaintenanceUsesTheInjectedExclusionWriterForALegacyRoot` 的排除回调 URL 期望从 `fixture.recoveryRoot` 改为其 `resolvingSymlinksInPath().standardizedFileURL`，对应本轮统一规范路径，仍要求恰好一次、同一个根。另 25 个旧方法全文保持；该方法其余断言保持。没有删除断言、放宽阈值或新增跳过；`BrowserPrivacyRecoveryTests.swift` 全文件保持基线。

新增七方法，边界类现在 33 方法（均仅准备源码）：

1. `testPersistentRemovalFailureStaysVisibleAndRetriesByOriginalIDAfterRestart`：持续故障先移除元数据／锁而保留数据库；首次及再次删除均失败、待清理状态独立于空恢复列表，清除结果不隐藏，重建 Store 仍可重试；解除故障后按原 ID 成功并清除新旧 Store 失败状态。也检查独立界面分支与重试绑定。
2. `testLegacyTombstoneWithoutMetadataCannotMakeAnIDRetryClaimSuccess`：旧随机墓碑丢失元数据仍不能误报按原 ID 删除成功，故障解除后可清除。
3. `testRemovalReadbackRejectsACallbackThatLeavesTheDataInPlace`：回调不抛错但保留数据时，两次删除仍失败。
4. `testLinkedRecoveryRootFailsBeforeReadingSourceOrCreatingBackup`：链接目标仅放临时哨兵，先用不可读的源检验根拒绝优先，再用真实夹具删除流程检验用户原因；无备份、无目标历史变化、无排除回调或新增快照。
5. `testReplacingTheVerifiedRootFailsClosedAcrossEveryEntryPoint`：根换成新目录或链接后，创建、枚举、恢复、删除、维护都拒绝接纳替换身份，原备份保留。
6. `testRootReplacementDuringPreparationCannotCreateABackup`：排除回调后把根换为链接，复查阻止创建备份与读取源。
7. `testAParentAliasUsesOneCanonicalRootForTheWholeBackupLifecycle`：只在父级有链接时，创建、列表、恢复、手动删除和原期限维护均走同一规范根。

### 主会话验证与反证

先运行七个新增方法、原删除交错／恢复源保护／r2b 根失败测试，再运行完整定向集合。因为修改了 Views，**必须含 `UIConsistencyRegressionTests`**；沿用主会话依赖／离线参数与既有夹具根目录：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --build-tests --scratch-path ~/Developer/.sc-build/r2-privacy-edges/debug --jobs 4
swift test --scratch-path ~/Developer/.sc-build/r2-privacy-edges/debug --jobs 4 --filter 'BrowserPrivacy|PrivacyCleanup|SQLiteSnapshot|TestPreferenceHygieneTests|UIConsistencyRegressionTests'
```

红／反证分别在最终源码备份上独立做，测试保持不变：①令 `isRemoved` 仅按原路径 `ENOENT` 判断，忽略墓碑，持续故障测试必须检测到 Store 假成功；②墓碑名去掉原 ID，持续故障测试在元数据移除后必须检测到原 ID 关联丢失；③移除独立待清理界面分支，持续故障测试的界面结构断言必须失败；④在 `verified` 中先解析根链接再传给 `Directory`（复现旧根策略），链接根测试必须失败；⑤只移除 `validatePath` 的设备号／inode 比较，新目录替换测试必须失败。还原使用最终源码备份并核对 manifest，不能用基线覆盖本轮未提交修改。主会话再完成严格并发、完整门禁及独立复核；UI 测试／结构断言不等于实机视觉验收。

产物为 `~/Developer/.sc-build/r2-privacy-edges/prepared-r3/`，产品、测试、交接三组；manifest 包含新增根目录文件在内的九份最终文件与产物哈希，提交说明尾部使用用户指定两行。五项只读 diff／反向补丁核验及 exit code 见 `static-checks.json`。**本轮没有编译、Swift 解析／类型检查、原生测试、红绿反证、安装或提交，原生测试执行 0；这些项目均 NOT RUN。**

JEV 实际返回模型为 `jev-latest`／`typesafe`，接口没有模型或推理参数；方案判断选择名称关联。补丁评分为 `escalate`（`safe_to_apply=0.11`，正确性置信度 `0.31`），没有具体代码问题，不能记为通过；原始判断和评分分别保存在 `jev-decision.json`、`jev-review.json`。当前准备不能替代主会话编译、定向测试和新的独立复核。旧格式完全丢失来源的墓碑只能保守关联待清理状态；更早测试版降级不识别保护的限制仍按原裁定保留。

### 第 3 轮补修（r3b）：统一墓碑清理的路径判定

基线 `8fb3cd522842b3dc55ca330d1b74b2dd2809586d`，初始工作区干净。已读 `logs/failures-r3.txt` 和 `logs/main-test-r3.log`：上一轮定向 289 项、跳过 1 项，四个方法共 14 处断言失败；编译通过由主会话反馈。本轮没有重跑，不能把这些证据记为修后通过。

- **原因**：`removeRetiredDirectory` 直接将 `directory.deletingLastPathComponent()` 与规范根 `root.url` 作 `URL` 对象相等比较。首次退休的 URL 由根直接拼接，重试／维护的 URL 来自目录枚举；同一文件系统父路径的 URL 表示可以不同，因而在递归删除回调之前被错误拒绝。[Swift Foundation 的 URL 相等实现](https://github.com/swiftlang/swift-foundation/blob/main/Sources/FoundationEssentials/URL/URL.swift) 比较 `relativeString` 和 `baseURL`，不是目录身份。失败日志中，原 ID 关联、持续失败提示均已通过，四个方法只在重新枚举后的清理／清除状态阶段失败，与这一守卫的影响一致；本轮未用原生探针重现具体 URL 表示。
- **产品修正**：只改 `BrowserPrivacyRecoveryBackupService.swift` 的上述函数。核对规范化父路径后，从已验证根与墓碑末级名称构造唯一的删除／读回 URL；不解析墓碑自身的链接。递归删除前再次 `lstat` 核对真实目录、当前用户与设备号，复查固定根身份；回调之后仍要求同一路径确为 `ENOENT` 且根身份有效才返回成功。根 `O_NOFOLLOW`、源租约、原子退休、墓碑命名和解析规则保持不变。
- **全链一致性复核**：创建及失败清理经 `moveToTombstone → removeRetiredDirectory`；枚举同时识别带原 ID 的新名称和旧随机名称；维护、按原 ID 重试共用同一清理函数；`isRemoved` 同时检查原路径和关联墓碑；Store 刷新磁盘待清理集合并在最终读回后清除失败，独立界面提示继续使用该集合；可恢复列表、到期名单和恢复入口仍排除墓碑。未发现需要修改命名、关联、Store 或 Views 的另一处本次故障。
- **断言清单**：改写 0、删除 0、放宽阈值 0；没有新增或修改测试。`BrowserPrivacyRecoveryEdgesTests.swift`（全部 33 方法）、`BrowserPrivacyRecoveryTests.swift`、临时根目录夹具与其余测试全文件保持基线，第二轮既有方法不变。没有改 `ScanStore.swift`、真实浏览器、真实偏好或时间机器设置。
- **主会话红／绿／反证**：红证据为上述基线日志。修后先原样重跑 `testMaintenanceFinishesInterruptedTombstonesWithoutFollowingLinks`、`testPersistentRemovalFailureStaysVisibleAndRetriesByOriginalIDAfterRestart`、`testLegacyTombstoneWithoutMetadataCannotMakeAnIDRetryClaimSuccess`、`testRemovalReadbackRejectsACallbackThatLeavesTheDataInPlace`，应分别确认立即清理计数 1、重启后按原 ID 清除数据及状态、旧无来源墓碑可清理、无实际删除的回调仍失败而正常重试成功。再跑 `BrowserPrivacyRecoveryEdgesTests`、`BrowserPrivacyRecoveryTests`、`BrowserPrivacyHistoryProcessorTests`、`PrivacyCleanupPresentationTests`、`TestPreferenceHygieneTests`、`UIConsistencyRegressionTests`，并沿用上一节完整定向过滤与既有 scratch／离线参数。根链接、根替换、父级别名、删除交错及零内容读取断言仍须通过。独立反证：①只恢复旧父 URL 直接比较守卫，四个清理方法应再次失败；②只让 `isRemoved` 忽略墓碑而看原路径，持续故障／无实际删除的回调方法应检测到假成功。测试不变；每次从最终源码备份还原并核对 manifest。
- **交付与验证边界**：`prepared-r3b/` 两组为 `01-recovery-code.patch`、`02-handoff.patch`，没有空测试补丁；格式、完整基线、文件／产物哈希和提交说明尾部沿用此前要求。`git diff --check`、整体及分组反向 `git apply --check` 的命令和 exit code 见 `static-checks.json`。本轮构建、Swift 解析／类型检查、原生测试、红绿反证、严格并发、完整门禁、独立复核、安装、提交均 **NOT RUN**，测试执行 0。JEV 实际模型 `jev-latest`／`typesafe`（无模型／推理参数）返回 `escalate`、`safe_to_apply=0.10`，没有给出具体代码诊断，不能记为通过；原始结果在 `prepared-r3b/jev-review.json`。修后绿色结果仍待主会话验证。

## 主会话验证结果（第 3 轮与 r3b，2026-10-08 02:2x）

- **提交**：
  - 第 3 轮 `f2456ec`、`1eba018`、`8fb3cd5`；
  - r3b `6d37184`、`83d6726`；
  - 模型名按派工记录改为 `openai/gpt-6.1-sol`。
- **第 3 轮首跑**：289 个测试中 4 个方法失败，其中含第 2 轮既有的 `testMaintenanceFinishesInterruptedTombstonesWithoutFollowingLinks`。原因是墓碑清理入口直接比较 `URL` 对象，同一路径的不同表示被拒绝。r3b 改为核对规范化父路径后全部通过，测试未改。
- **r3b 后**：定向测试（`BrowserPrivacy|PrivacyCleanup|SQLiteSnapshot|TestPreferenceHygieneTests|UIConsistencyRegressionTests`）共 289 个，跳过 1 个，0 失败。
- **反证**（`rp3.py`）：
  1. `isRemoved` 不核对关联墓碑 → 10 处失败，涉及 3 个方法；
  2. 接受符号链接作为恢复根目录 → `testLinkedRecoveryRootFailsBeforeReadingSourceOrCreatingBackup` 失败。
  - 还原后工作区干净。
- **结论**：GPT-6 Astra 第二次复核的两项 P2 已按要求修复并由临时夹具测试锁定，合并。
