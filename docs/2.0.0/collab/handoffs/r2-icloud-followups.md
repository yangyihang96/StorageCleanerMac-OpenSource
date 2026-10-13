# r2-icloud-followups：搬家复制与读取 A–H 后续修复

## 状态和证据边界

- 基线 `41415ad90ba9fb7e40f485916c9cfbf32edae7db`，分支 `task/r2-icloud-followups`；开始时 worktree 干净。只写本 worktree 和 `~/Developer/.sc-build/r2-icloud-followups/`。
- 已读 `~/Developer/.sc-build/_prompts/common.md`、RULES、BOARD 的 R10、DECISIONS D5／D48／D49／D52／D54／D55／D60／D61，前批交接 fix3、fix4、主会话验证，以及 `r2-icloud-reads/review/review-2.md` 的 A–H、实验和反证。阅读了 review2 的压缩构造、两种大包性能和 invokedMove 窗口程序。旧实验是复核报告的证据，**不代表本轮改动已通过**。
- **NOT RUN**：Swift 编译、严格并发编译、XCTest、实际元数据／压缩／持久化实验、反证、不同模型复核、提交、合并、安装。本会话执行 Swift 测试数 **0**，没有构建产物；common.md 禁止在 Codex 沙箱构建、测试和提交。
- **PASS（静态）**：检查及 exit code 记录在 `prepared/static-checks.json`；文件和补丁 SHA-256 记录在 `prepared/manifest.json`。这些结果仅涉及字节、路径、补丁适用性和源码检查，不证明运行行为。
- **BLOCKED（JEV）**：工具 `jev_decide` 没有模型参数，调用后返回 `MCP tool call requires approval, but approval policy is never`。没有返回实际模型标识或判断；不声称获得 JEV 通过。原始状态写入 `prepared/jev-status.json`，主会话仍须不同模型复核。

## 实现与理由

| 项 | 根因修复与边界 | 对应源码 |
|---|---|---|
| A：0555 包根目录跨父目录发布 EACCES | 系统复制完成后，仅当新暂存根为目录且缺少 u+w 时，打开 no-follow 描述符并核对 inode／设备／属主，记录原模式，临时加 u+w。发布成功先恢复原权限，再恢复 immutable／append 标志。失败仍交原身份绑定的 staging owner 清理；原件不写。权限恢复失败返回已发布副本并警示。 | `GuardedFileCopy` 的 `deferredRootMode`、`restorePublishedPermissions`；`ExternalDriveMigrationService.migrate` |
| B：exFAT／FAT32 改名清掉 hidden | 延迟发布状态另记录目标已经能表达的 UF_HIDDEN，不在发布前清除该位；发布后以目标现有标志为基础补回 hidden／immutable／append，并读回确认。不强求 SF_*，不清除 UF_COMPRESSED。恢复失败写 `publicationWarning`，不把已提交 rename 谎报成迁移未发生。 | `publicationFlags`、`restorePublishedFlags` |
| C：跨卷 birth time 变成 mtime | Entry 同时采集 `st_birthtimespec`，两次目标时间恢复均调用公共 `setattrlist(ATTR_CMN_CRTIME, FSOPT_NOFOLLOW)`，包括目录与链接自身。若只读目标的元数据操作需要写权限，仅在当前属主、身份一致、无外部硬链接的目标 inode 上临时加 u+w，重试后恢复原模式。ENOTSUP／EINVAL／权限限制记录创建时间降级；成功后读回，若时间被目标精度舍入，明确记录精度降级。其他错误（如 EIO）仍拒绝。访问／修改时间原断言与恢复逻辑不删。 | `GuardedFileCopy.PreparedCopy.restoreTimes` |
| D：错误原因 | 原始 POSIX ENOENT 改用“文件或目标文件夹已不存在”中性短句，明确的产品 `.sourceMissing` 保持来源错误。EDEADLK 映射 `.cloudOnly`。看门狗按当前阶段区分纯读取、系统复制、明确的目标写入／持久化；15 s 默认时限不改。 | `FileContentReadGuard`、`GuardedFileCopy.Job`、`SafeCleanupExecutor` 的穷尽映射 |
| E：4 个反证及压缩夹具 | 生产卷 key 直接比较 devfs／home；预检后等长改写源并恢复 mtime，断言复制函数调用数 0；onFailure 必须见到工作线程 gate 已返回，并观察 300 ms 排除异步提前清理；在生产 moveOriginal 的最后一次回执元数据检查中取消任务，移动闭包仍应运行。透明压缩用已压缩的只读 `/usr/share/dict/web2`，保留有／无克隆两条路径的原压缩位、占用 `< payload.count / 2`、内容断言。 | 原 metadata／isolation 类；新增 `InvokedMigrationMoveTests` |
| F：发布重绑定忽略 ctime | 第二次目标时间恢复前抓完整 Snapshot（含纳秒 ctime），重绑定时与校验所用快照比较；同时比较恢复后与耗时持久化后的完整快照，防止 H 扩大忽略 ctime 的窗口。变化时用 guarded reader 重新哈希，内容不一致不提供证明；仅当完整前驱快照一致时允许本发布器的时间／权限／标志／rename 所造成的 ctime 变化。没有提供前驱快照的直接调用按完整当前快照判断，不能凭 size+mtime 重绑定。 | `MigrationContentVerification.afterPublication`、`migrate` |
| G：deny delete 阻止暂存删除 | 普通文件与目录均在 descriptor 相对、no-follow、身份／属主核对后读取 ACL，只删阻止 delete／delete_child 的 deny 条目，保留其他 ACL；多硬链接普通文件拒绝改 ACL，保留待清理回执。源 ACL、目标同级项目不改。 | `MigrationStagingDirectory.removeDeletionDenials` |
| H：副本持久化 | 复用 GuardedFileCopy 的线程策略／槽／Job abandon 协议。发布前：暂存树普通文件逐个 F_FULLFSYNC，目录后序 fsync，最后一道 F_FULLFSYNC 屏障；链接不跟随。发布后：恢复元数据后的根项与目标父目录逐层到所选卷 fsync，再对普通文件做屏障。发布前失败不发布；发布后失败返回警示且不提供处理原件证明。处理原件时再次对副本和父目录持久化，完整快照若在回执检查中变化，重新哈希并重新持久化；失败在 invokedMove 前拒绝。 | 新 `MigrationDurability`；`makeDurable`；`moveOriginalToTrash` |

`copyfile` 的 DATA 回调只说明复制有进展，无法判断某个卡住的内核调用到底在来源读还是目标写。因此文案有第三类“复制长时间无进展，请检查来源和目标磁盘”，不会把未知归因为目标写或来源读。纯 source 预检／willRead 阶段为读取超时；目标 utimensat／setattrlist／fsync／F_FULLFSYNC 为写入超时。这里没有新增分块内容复制器。

公开 API 类型和语义静态核对了 Xcode-27.0.0-Beta SDK 的 `unistd.h`、`sys/attr.h`、`sys/acl.h`，以及 SDK `usr/share/man/man2/{setattrlist,fcntl}.2`、`man3/acl_get_entry.3`。64 位 `setattrlist` 最后参数为 unsigned int；Darwin `acl_get_entry` 成功返回 0、遍历完返回 -1。`F_FULLFSYNC` 先 fsync，再要求设备清空缓存，覆盖同设备此前已 fsync 的写入；设备若不遵守硬件刷新命令，软件无法证明断电安全。

## H 的耗时影响估计与主会话测量方法

**下面是估计，不是实测。** 本轮动态耗时 **NOT RUN**。review2 的基线：1.2 GB／3007 目录／3063 文件跨卷发布为 3.222／3.788／3.233 s；3 万小文件／1518 目录为 12.862／19.682 s。镜像结果有缓存和宿主 I/O 噪声，不可用于宣称真实外接盘性能。

本实现大包的主要额外成本是逐文件 F_FULLFSYNC（N 次），目录 fsync（D 次），发布父链同步以及两道终结硬件屏障。若单次 SSD 硬件刷新平均 0.5–2 ms，目录同步 0.05–0.3 ms，则：

| 夹具 | 仅按调用延迟估计的额外时间 | 必须另计 |
|---|---|---|
| 1.2 GB／3063 文件／3007 目录 | 约 1.7–7.1 s | 待写数据量／实际落盘速率、路径核对与 open/close、USB 桥接延迟 |
| 30,000 小文件／1518 目录 | 约 15–60.5 s | 目录／文件 metadata 开销及 OS 合并写入行为 |

这些刷新延迟只是用于敏感性估计的假设。若设备平均刷新延迟为 5–20 ms，3063 文件的调用成本可能约 15–61 s，3 万文件约 150–600 s。设备第一次刷新可能排空此前所有积压数据，不能机械地把数据大小／吞吐与每项耗时相加；按 `T≈Σ文件刷新耗时+Σ目录同步耗时+元数据恢复/发布成本` 分阶段计量才有意义。没有提高 15 s 无进度阈值；每个完成的同步更新进度，总耗时可超过 15 s，单个调用若长时间不返回仍有界放弃等待。

主会话测量（不改产品阈值或正式逻辑）：

1. 使用 review2 原规格，在 `~/.storage-cleaner-durability-perf-<UUID>` 创建两份独立的隔离 `.app` 夹具（可使用该目录内的签名测试包），目标使用专用 APFS／HFS+ SPARSE 镜像。分别记录源／目标文件系统、物理介质、挂载选项、字节／普通文件／目录／链接数；镜像与物理 USB SSD／机械盘分开报告。
2. 在主会话专属 archive 副本中跑旧基线 `41415ad` 和最终候选。同一夹具、不同目标文件名，交错 3 轮（大包）／至少 2 轮（小文件）；首轮单独列作冷缓存候选，不把 warm cache 的读数标成真正冷盘。
3. 对候选注入 `MigrationDurability.flushOperation` 包装器：用 uptime 在调用前后计时并委派给未改的 `MigrationDurability().flushOperation`。汇总 F_FULLFSYNC／目录 fsync 次数、总耗时、p50／p95／max；用 F_GETPATH 区分 `.partial` 阶段和发布目标／父目录阶段。同时计整次 `migrate`、校验和最终签名，原件必须仍在。可参照 `MigrationDurabilityTests.FlushTrace` 的线程安全收集方式，不记录或改真实个人文件。
4. 在有界测试里用 gate 卡住同步，确认取消／超时 <1 s 返回、工作线程未返回前暂存仍在、返回后仅清理一次；发布后的卡住应返回已生成副本＋警示，不删除副本。此项已有定向测试，勿改成全流程 1 s 预算。
5. 做真正跨卷元数据对照与安全卸载、重挂后副本内容哈希／应用签名检查。若做强制弹出，仅专用镜像夹具；没有物理断电实验就注明。真实慢盘／USB／网络卷没有实测时标 NOT RUN。测完卸载专用镜像并删除自有夹具、临时源码及编译缓存，只保留日志／汇总。

应用仍按既有规则只复制；没有让应用原件获得自动移到废纸篓能力。普通文件处理原件没有证明时仍各哈希一次，未变证明仍避免重复读取；新增 durability 只刷新目标，回执规则／恢复路径不改。

## 红／绿／反证（本轮全部待主会话执行）

红＝在隔离基线或指定的单点变异版本运行；绿＝最终候选；反证＝只改指定位置后，应有上述测试变红。每轮重新编译并记录实际失败方法，结束恢复源码并核对 SHA-256。不要在其他并行 worktree 做变异，不删断言、不改阈值。

| 项 | 红／触发方式 | 候选绿灯要求 | 单点反证与目标测试 |
|---|---|---|---|
| A | 签名夹具 `.app` 根 chmod 0555，跨父目录 rename；基线迁移 EACCES。 | `testReadOnlyApplicationRootPublishesWithOriginalModeAndValidSignature`：发布、0555、birth time、签名；拒绝发布时 owned staging 清理、原件／同级目标保留。 | 删 `copyOnWorker` 临时 u+w 块，应发布失败；或让 `restorePublishedPermissions` 不执行，最终 0555 断言红。 |
| B | `PublicationFileManager` 模拟系统改名后清除 UF_HIDDEN；实际 exFAT/FAT32 同样做一遍。 | `testLostHiddenFlagIsRestoredAfterProductionPublication`：两端隐藏位／内容；`testFlagRestorationRefusalReturnsPublishedCopyWithWarningAndKeepsOriginal`：ACL 拒绝 writeattr 时已发布＋warning、无证明、源保留。 | 把 `publicationFlags` 改回只有 renameBlockingFlags；丢失隐藏位测试必须红。恢复失败不能变为 migration 抛未发布错误。 |
| C | copyfile 替身先实际复制，再将目标 birth time 写成 mtime，模拟实测跨卷结果。 | `testBirthTimeIsRestoredEvenWhenSystemCopyReplacesItWithMtime`：纳秒创建／修改时间、内容；目录／链接 birth time 与 referent 未改。真实 HFS+/exFAT/FAT32 按各自精度记录 warning，不能断言这些目标支持纳秒。 | 删除 `restoreTimes` 的 ATTR_CMN_CRTIME 写回，强制 mtime 的目标创建时间断言必须红；在隔离版本让该调用返回 ENOTSUP，应保留副本并记录创建时间降级。 |
| D | 缺失目标父目录、POSIX EDEADLK、source willRead gate、COPYFILE_PROGRESS gate、full sync gate。 | `testSystemMissingPathIsNeutralAndDatalessErrnoHasBothLanguages` 中英文；原纯读取 gate 仍 timedOut，DATA gate 为 copyTimedOut，sync gate 为 writingTimedOut；源始终保留。 | 恢复 ENOENT→sourceMissing、删 EDEADLK 映射、把 Job watchdog 固定为 timedOut，分别应使文案／copy gate／sync gate 测试红。 |
| E/M4b | 生产 mountedVolumeKey 返回常量 "/"。 | `testProductionMountedVolumeKeysSeparateDevfsFromHome` 不注入 key，home 与不存在的 home 子项同 key，devfs 与 home 不同。 | 直接替换生产 `mountedVolumeKey` 函数体为 `return "/"`，测试必须红。 |
| E/M5b | reader.willRead 在 collect 后用 FileHandle 等长改写源，再 utimensat 恢复 mtime。 | `testSourceRewriteAfterPreflightWithRestoredSizeAndMtimeNeverReachesCopyfile`：实际 ctime 变化、系统复制尝试 0、changed 原因和清理。 | 从 checkSource 比较中删 ctime 条件（同时移除前一行的逗号），尝试数 0 断言必须红，不能仅依赖最终哈希拒绝。 |
| E/M6 | abandon 不等 finished 就提前调 cleanup，含异步调度。 | 原 progress gate 测试在 onFailure 断言 didReturn；额外 300 ms 仍 0 次 cleanup、暂存存在；释放后正好一次。同步 gate 同要求。原 <1 s 返回阈值不变。 | `Job.abandon` 中把 `guard finished, !cleanupClaimed` 改成 `guard !cleanupClaimed`，两个 gate 测试必须红。 |
| E/M7 | 在 production move 闭包的 `let target: URL?` 前恢复 `try Task.checkCancellation()`。 | `InvokedMigrationMoveTests.testCancellationInFinalMetadataCheckStillInvokesProductionMoveAndRecordsIt`：第 5 次 source snapshot 取消，在实际移动闭包中确认 Task.isCancelled，仍移动并有可恢复回执，unknown=0。 | 恢复入口检查，测试必须红；此处 metadata 注入是既有只读接口的测试接缝，不使用复核程序的另一个 move 实现。 |
| E/压缩 | 同卷 ditto 克隆构造本来永远 skip；改用系统已压缩文件。 | 两种 clone 开关均执行并保留原压缩位／块数 `< payload.count / 2`／内容断言；源只读。 | 在隔离版本用数据展开复制替换 copyfile，压缩位或占用断言红。源不存在或确实未压缩才可 XCTSkip 并记录原因；本机 APFS 前提由主会话读回确认。 |
| F | 校验后目标等长改写，再第二次 restoreTimes 恢复 mtime；另一个例子只 chmod，不改内容。 | `testChangedCtimeBeforeMetadataRestorationRehashesAndRejectsChangedCopy`：读取探针 >0、proof nil、源完整；`testMetadataOnlyCtimeChangeRehashesAndRenewsMatchingProof`：读取 >0、digest 一致、绑定新完整快照。 | 忽略 beforeMetadataRestoration 的 ctime、只比较 device/inode/size/mtime；两个新增 F 测试的读取／证明断言应红。原 receipt checkpoint ctime 反证继续跑。 |
| G | 对源夹具设 `everyone deny delete` 后跑真实 migrate，发布失败；另在暂存放源硬链接。 | `testDeniedDeletePublicationCleansOnlyOwnedStagingAndPreservesOriginalACL`：暂存无残留、源 ACL／内容／同级目标不变；多硬链接拒绝 ACL 改写。 | 删除普通文件的 removeDeletionDenials 调用（保留目录处理），deny-delete 暂存清理测试必须红；放开硬链接 guard，外部 ACL 保留测试必须红。 |
| H | 注入 F_FULLFSYNC EIO／ENOTSUP，分别在发布前和发布后；sync gate 模拟不返回；晚取消落在发布后。 | `MigrationDurabilityTests` 全部方法：每个普通目标文件／目录／父项同步顺序，无源刷新或链接跟随；发布前不发布；发布后返回副本＋warning；处理原件时失败在回执/移动前；gate 遵守原取消和迟到清理；已发布晚取消返回实际副本。 | `makeDurable` 中跳过 durability.synchronize，实际轨迹／错误／原件移动前检查应红；把 committed 参数的忽略晚取消去掉，晚取消测试应出现警示或失败并红。真实掉盘／断电安全与耗时仍需另做实验。 |

## 旧断言与范围

- 只改写 **一条旧原因断言**：`FileContentReadIsolationTests.testProgressCallbackStopsCancelledOrTimedOutSystemCopyAndCleansOnlyAfterReturn` 的 DATA 回调停顿由 `.timedOut` 改为 `.copyTimedOut`，依据本批 D 的准确原因要求。取消类型、<1 s 返回、线程返回前存在暂存、返回后清理、原件保留断言全部保留，新增清理时点和次数断言。
- 透明压缩测试仅替换构造源与真实前提；两种 clone 开关和原三个产品断言逐字保留。源缺失或不压缩的 skip 必须独立列 NOT RUN，不能当成产品 PASS。没有提高半数占用阈值。
- 新增 **23 个方法**（新增三类共 21 个；原 isolation 新增 1、原 metadata 新增 1），原测试方法名不删。定向清单为原 19 类再加三个新类，共 **22 类**，含 `UIConsistencyRegressionTests` 和 `TestPreferenceHygieneTests`。实际发现／执行／跳过数量以主会话日志为准。
- `GuardedMigrationReadTests` 的 fixture helper 增加默认 durability 参数，仍是原 `~/.storage-cleaner-content-tests-<UUID>` 家目录隔离夹具。所有会走回执／移动／恢复的测试仍在那里；语言测试只使用 `TestVolatilePreferences` 的内存覆盖。不放宽 PathSafety，不写真实偏好／缓存／应用数据。
- `SafeCleanupExecutor` 只为新增两类错误补穷尽枚举映射；内容读取入口仍只会生成纯读取超时，没有新增清理行为。`ScanStore.swift`、Views、DECISIONS、RULES、BOARD、旧交接和其他 worktree 均未改。
- 同步 API 的开放路径、元数据、结果、观察器都是 Sendable 或线程本地对象；新增 FlushTrace／metadata 测试替身的可变字段有 NSLock。产品没有新增 `@unchecked Sendable` 容器、`@preconcurrency` 或 `nonisolated(unsafe)` 豁免。Job 仍采用原锁保护。

## 主会话命令和交付

在沙箱外、本 worktree 执行；不要执行正常 build_and_run／安装循环：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-build.log 2>&1
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 --filter 'GuardedFileCopyMetadataTests|FileContentReadIsolationTests|GuardedMigrationReadTests|MigrationVerificationReuseTests|MigrationPublicationFollowupTests|MigrationDurabilityTests|InvokedMigrationMoveTests' > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-followups.log 2>&1
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 --filter 'AppIconCacheTests|Audit20260919RegressionTests|BrowserPrivacyRecoveryTests|CleanupExecutionSafetyTests|DuplicateContentReadTests|DuplicateFileScannerTests|DuplicateSelectedLocationsTests|ExternalMigrationReceiptTests|FileContentReadGuardTests|FileContentReadIsolationTests|GuardedFileCopyMetadataTests|GuardedMigrationReadTests|HeavyWorkIntegrationTests|MigrationVerificationReuseTests|RecordedTrashRecoveryTests|SimilarImagePreviewCacheTests|SystemUtilitySafetyTests|TestPreferenceHygieneTests|UIConsistencyRegressionTests|InvokedMigrationMoveTests|MigrationDurabilityTests|MigrationPublicationFollowupTests' > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-targeted.log 2>&1
git diff --check
```

`logs/` 已由交付生成器创建。离线依赖只按 RULES 复制 `r2-u1-preselect/debug/{checkouts,repositories,artifacts,workspace-state.json}` 到本批 debug，不复用其他并行批次的可写构建目录。执行主会话定向与反证后，再在集成分支按 RULES 跑完整 Release／Debug／严格并发／源码守卫／性能门禁：`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`、私有 `STORAGE_CLEANER_VERIFY_ROOT`，不能把本轮静态结果当这些门禁通过。

`~/Developer/.sc-build/r2-icloud-followups/prepared/` 分三组：

1. `01-publication-and-durability`：七个产品文件，包含元数据／发布、错误原因、ACL 清理和持久化；同组保持枚举调用点一致。
2. `02-followup-regressions`：六个测试文件，四个反证缺口、压缩源、A–H 测试与原 fixture 默认参数。
3. `03-handoff`：本交接。

每组 patch／message、`all.patch`、`manifest.json`、`static-checks.json`、`generate-prepared.py`、`commit-prepared.py`、`filter-followups.txt`、`jev-status.json`、README 已准备。提交脚本仅供主会话在编译、定向、反证、不同模型复核通过后执行；核对基线／分支／索引／文件／产物哈希并分组提交，不构建、不安装、不推送。尾行严格为：

```text
Generated-By: Codex (gpt-6.1-sol)
Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
```

剩余限制：实际 Swift 6 编译及本轮 22 类测试、四种文件系统能力／元数据对照、动态反证、真实外接介质持久化耗时、设备对缓存刷新命令的遵守、真实慢盘签名和界面显示均 **NOT RUN**；真实 iCloud／File Provider 操作仍按规则禁止，只用替身。公开 F_FULLFSYNC 失败时不回落成“fsync 就算完成”，原件保留。单个内核调用永不返回时仍无法承诺立刻物理清理，但已作废结果永不发布，待清理回执仍保留。

## 主会话第一轮结果与修复

### 第一轮结果与本轮基线

主会话已在沙箱外提交 `82ff4d3`、`d9472e4`、`e6a0108`，随后修正三处编译错误并提交 `047422d`：`acl_get_entry` 的游标参数为 `Int32`，`ACL_FIRST_ENTRY`／`ACL_NEXT_ENTRY` 在 Swift 中是 `acl_entry_id_t`，因此三处取 `.rawValue`。本轮基线为 `047422d7c838c29c140feabf7686c5b07fcb4c47`，开始时工作区干净；`MigrationStagingDirectory.swift` 与该提交完全一致，保留这三处修正。

主会话日志 `~/Developer/.sc-build/r2-icloud-followups/logs/main-test-3.log:9728–9736,10320–10323` 的实际结果为 **515 项、跳过 1 项（Setapp 实机开关）、2 个失败方法／3 处断言失败**；完整错误摘录在 `failures-r1.txt`。此结果属于旧候选加编译修正，不是本轮修复的绿灯。日志没有单独记录命令 exit code，本轮不补造该数字。主会话的构建已能进入这次测试，但严格并发、四种文件系统实测、原有反证和 H 耗时验证的完成状态仍以各自证据为准。

### 判定及可复查依据

| 失败 | 判定 | 依据与修复 |
|---|---|---|
| G：旧第 217 行 `before.contains("deny delete")` | **测试前提检查写错**，不是暂存清理失败 | `chmod` 的输入是空格语法，`acl_to_text` 输出是扩展 ACL 文本语法。review2 的 `logs/evidence/harness/main.swift:50–55` 已按冒号拆成 principal／tag／permissions，`dump-src.txt` 中也是 `group:staff:allow:read,...`，不能把空格输入子串当作读回语义。此次日志只有这条断言失败；后面的真实发布失败、无暂存／目标残留、源 ACL 精确相等、源内容及 sibling 保留断言没有失败。现改成 ACL API 的同一 ACE 检查：qualifier 是 everyone 的 UUID、tag 是 `ACL_EXTENDED_DENY`、权限含 `ACL_DELETE`。源 ACL 前后完整文本精确比较仍保留。 |
| B：旧第 84／85 行 warning 非空、proof 为空 | **测试构造没有触发声称的恢复失败**，结果断言的含义正确并全部保留 | `chmod +a everyone deny writeattr` 成功只证明 ACL 已设置，不证明 `lchflags(UF_HIDDEN)` 被拒。主会话日志没有 chmod 设置失败，实际返回 warning nil 与内容证明；同类真实标志丢失后恢复测试也通过。本地 SDK `chflags(2)` 明确把 `UF_HIDDEN` 列为文件属主可设置／清除的标志，因此不能把这个 ACL 当成属主 chflags 必败的保证。现保留真实 copyfile、校验、改名发布及生产错误处理，仅在最终 `lchflags` 叶子调用分别返回 `-1`／`errno=EACCES` 与 `ENOTSUP`，确定构造拒绝／不支持两种失败。 |

本轮仅给 `ExternalDriveMigrationService.migrate` 的发布标志调用加 `@Sendable publicationFlagOperation` 参数，并传给 `PreparedCopy.restorePublishedFlags(setFlags:)`；两处默认都仍直接委派公共 `Darwin.lchflags`，指针只在同步 `withCString` 期间有效。没有把整段恢复／发布处理替换为测试闭包。实际 `lstat`、flags 合并、错误抛出、恢复成功后的读回、catch 文案、同步、warning 禁止提供处理原件证明的分支均保留；取消、时限、回执与 D61 不变。ACL 清理产品代码没有修改。

G 的测试 helper 用 `acl_from_text("!#acl 1\\ngroup::everyone::deny:delete\\n")` 在内存中解析 everyone 的 qualifier；实际文件则用 `acl_get_link_np`／`acl_get_entry`／`acl_get_tag_type`／`acl_get_permset`／`acl_get_perm_np`／`acl_get_qualifier` 读回，不写文件 ACL。资格标识按 UUID 全部字节比较，不能由“其他身份 deny delete”或“一个 deny writeattr 加另一个 allow delete”误通过。所有游标都取 `.rawValue`，所有 ACL／qualifier 分配均 `acl_free`。本地 SDK `sys/acl.h`、`acl_get_qualifier(3)` 与 `acl_from_text(3)` 已核对类型、内存所有权和扩展 ACL 格式边界；没有执行解析或文件系统实验。

外部 Apple OSS 页面未能形成可交付源码快照：沙箱内读取 `raw.githubusercontent.com` 返回 DNS `URLError [Errno 8]`。因此本轮交付的可复查证据以主会话日志、本地 SDK、已存在的 review2 程序／结果和基线代码为准，不把未保存的外部源码或 JEV 判断列为已验证证据。

### 逐条旧断言变更与保留

1. G 仅把旧 `XCTAssertTrue(before.contains("deny delete"))` 改成 `XCTAssertTrue(try hasEveryoneDeleteDenial(source), before)`。含义仍是源确实具有 everyone 的删除拒绝条目，新增身份与同一条目约束，依据就是本批 G 与本轮用户“测试错就修测试，不放宽断言含义”的要求。原 chmod 成功、真实迁移抛错、1 s 清理等待预算、`assertNoPartialOrPublishedCopy`、源 ACL／内容／sibling 精确比较全部保留。
2. B 删除无效的 `deny writeattr` 构造及它的 chmod 成功前提断言，替换为底层失败调用的路径、恢复位、发布后调用和恰好一次调用断言。发布后模拟丢标志的成功断言保留，并由清零所有标志改成只清 `UF_HIDDEN`，不改其他目标标志。此处替换的是失败构造，未放宽任何产品结果要求。
3. B 的 warning 非空、proof 为空、`didMoveSourceToTrash == false`、已发布副本内容正确、原件仍带隐藏位断言全部保留。另检查 warning 包含**标志恢复失败**的原中英文短句，避免其他警告冒充本项失败；增加 trashURL nil、返回正确目标路径、目标隐藏位仍丢失、源设备／inode／完整 flags／内容不变、目标父目录只剩已发布副本且无暂存等断言。一个方法分别覆盖 `EACCES` 与 `ENOTSUP`，没有新增／删去测试方法，没有增加 skip 或调整阈值。
4. `testLostHiddenFlagIsRestoredAfterProductionPublication` 仍使用真实默认 `Darwin.lchflags`，`testCleanupRefusesToChangeDeletionACLOnAnExternalHardLink`、其他 A–H 测试与原压缩阈值断言均未改。`ScanStore.swift`、Views、偏好 helper、ACL 清理、取消／超时、持久化产品代码不改。

### 本轮红／绿／反证（均由主会话执行）

| 项 | 红／触发 | 候选绿灯要求 | 单点反证 |
|---|---|---|---|
| G 前提 | 本轮基线 `047422d` 的第一轮主会话日志已记录旧格式断言为红。 | 同一实际源 ACE 的 everyone／deny／delete 检查通过，生产发布仍抛错，清理和原件保护全部通过。 | 在隔离源码副本只把该夹具改成 `everyone allow delete` 或 `staff deny delete`，同一 ACE 前提断言必须红；不能拆成无关联的字符串 token 检查。 |
| G 清理／所有权 | 不改真实 `everyone deny delete` 夹具，目标为原 APFS 隔离目录。 | 暂存清空，原件 ACL 全文本精确相等，源内容和同级目标不变；原硬链接拒绝测试也通过。 | 在隔离候选删除普通文件的 `removeDeletionDenials` 调用、保留目录处理，清理断言必须红；放开 `st_nlink == 1` 保护，原硬链接 ACL 保留断言必须红。所有等待预算原样保留。 |
| B 拒绝／不支持 | 发布后只清目标 hidden 位，最终标志设置分别返回 `-1/EACCES`、`-1/ENOTSUP`。 | 确认调用发生在真实已发布目标上、请求恢复 hidden、恰好一次；返回已发布副本和明确的标志恢复 warning、proof nil、原件不变。 | ①仅把生产调用改回不传 `publicationFlagOperation`，恢复实际成功，调用次数／warning／proof／目标位断言必须红；②保留注入失败但删除 catch 中追加标志警告，warning 与 proof 断言必须红；③保留 warning 但移除结果中 `publicationWarning == nil` 的 proof 门禁，proof nil 必须红；④改为 catch 抛出，方法意外抛错必须红。 |
| B 默认成功 | 原 `testLostHiddenFlagIsRestoredAfterProductionPublication` 走真实默认 setter。 | warning nil、proof 非空、源／目标 hidden 及内容通过。 | 仅让 `restorePublishedFlags` 直接返回或从 `publicationFlags` 删除 hidden，目标 hidden 断言必须红。仍需按原交接在 exFAT／FAT32 真正跨卷验证。 |

每次反证在主会话自有的隔离源码副本中单点修改、重新编译，记录实际红色方法／断言，随后恢复并核对交付 SHA；不要修改并行 worktree 或放宽测试。上节原 B 绿灯栏的“ACL 拒绝 writeattr”构造由本节**明确更正**为系统调用失败注入，原 B／G 设计要求保持有效。

### 主会话第二轮命令与交付

本轮定向类仍为原 19 类加三个已存在的新增类，共 **22 类**，含 `UIConsistencyRegressionTests` 和 `TestPreferenceHygieneTests`；清单逐字复制到 `prepared-r2/filter-followups.txt`，未删类。没有新增测试方法，预期发现数量仍为前轮 515，实际执行数／skip 和失败数须重新读回，不能预报 PASS。

以下命令仅供主会话在沙箱外执行，本会话未执行：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-build-r2.log 2>&1
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 --filter 'MigrationPublicationFollowupTests' > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-publication-r2.log 2>&1
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 --filter 'AppIconCacheTests|Audit20260919RegressionTests|BrowserPrivacyRecoveryTests|CleanupExecutionSafetyTests|DuplicateContentReadTests|DuplicateFileScannerTests|DuplicateSelectedLocationsTests|ExternalMigrationReceiptTests|FileContentReadGuardTests|FileContentReadIsolationTests|GuardedFileCopyMetadataTests|GuardedMigrationReadTests|HeavyWorkIntegrationTests|MigrationVerificationReuseTests|RecordedTrashRecoveryTests|SimilarImagePreviewCacheTests|SystemUtilitySafetyTests|TestPreferenceHygieneTests|UIConsistencyRegressionTests|InvokedMigrationMoveTests|MigrationDurabilityTests|MigrationPublicationFollowupTests' > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-targeted-r2.log 2>&1
git diff --check
```

第二轮仅四个文件，`prepared-r2/` 相对 `047422d` 分三组：`01-publication-flag-syscall`（两个产品文件的叶子注入接口）、`02-publication-test-premises`（一个测试文件）、`03-handoff-r2`（本交接追加）。manifest 记录基线／组序／最终文件及产物 SHA-256；提交说明尾行仍为 `Generated-By: Codex (gpt-6.1-sol)`、`Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。`commit-prepared.py` 仅供主会话在编译、定向、反证和不同模型复核通过后按组提交；本会话不执行。原 `prepared/`、主会话的失败日志和编译缓存不改。

**本轮状态**：静态检查的实际命令／exit code 在 `prepared-r2/static-checks.json`；编译、Swift 6 严格并发、XCTest、反证、外部文件系统能力验证、H 耗时、不同模型复核、提交／安装／合并均 **NOT RUN**，本会话执行 Swift 测试 **0**。JEV `jev_decide` 仍返回 `MCP tool call requires approval, but approval policy is never`，为 **BLOCKED**，未返回实际模型标识或判断；原始结果在 `prepared-r2/jev-status.json`。下一步先验证本轮接口／ACL helper 的实际编译和两项故障路径，再跑完整 22 类及上表反证。第一轮失败测试的前提问题已修正；产品行为的第二轮绿灯仍待主会话，不以静态 PASS 替代。


## 第三轮：创建时间精度与持久化后续

### 基线、独立复核与中断续接

本轮基线为 `c3eb0d4759d58daf6d58b85d6d6a7bad685c5b04`，分支仍为 `task/r2-icloud-followups`。主会话第二轮实际通过 **22 类／515 项／0 失败**，压缩测试实际执行；Claude 独立复核也记录 515 项、1 项 Setapp 实机开关跳过、0 失败。独立复核全文为 `~/Developer/.sc-build/r2-icloud-followups/review/review-1.md`；证据为 `~/Developer/.sc-build/r2-icloud-followups-review/logs/`。上述结果属于 `c3eb0d4`，不是第三轮候选的绿灯。报告中的 21 组反证均已变红，但它们没有覆盖本轮 P1 的跨卷精度回退。

按用户续接要求，先读 `git status` 与 scratch 中 `r3-message.txt`、`r3-continue.txt`。中断时已保存六个跟踪文件的核心修改和新增 `MigrationCreationTime.swift`，尚无 `prepared-r3/`；续接保留这些修改，补齐测试、脚本和交付。本轮没有重建 worktree、没有移动基线，也未改旧 `prepared/`、`prepared-r2/`、主会话日志、复核证据或构建缓存。只修改本 worktree 的九个文件。

### 产品判定与最终实现

P1 是**产品回退**：纳秒精确比较产生的精度说明直接进入 `publicationWarning`，阻断内容证明和 UI 后续确认。P2-1～P2-4 同属产品路径开销、阶段时限、能力处理和行动文案问题。本轮不把它们改成测试容忍。

| 项 | 改动与理由 |
|---|---|
| P1 | `MigrationCreationTime` 默认写入仍调用公共 `setattrlist(ATTR_CMN_CRTIME, FSOPT_NOFOLLOW)`，独立注入的只有叶子写入与精度查询。根据目标实际挂载类型（`getfsstat(MNT_NOWAIT)`、最长挂载点边界匹配），已实测 HFS、exFAT、msdos 驱动按秒比较，APFS／未知驱动按纳秒比较；截到支持粒度后相等视为成功。未知驱动若仍不等，只记“未能完整保留创建时间”的说明。不能用“只比较秒”忽略真正偏移的秒数。写不进去的 ENOTSUP／EINVAL／权限限制也只作说明；EIO 等真实 I/O 错误仍失败。写入只在副本上发生。 |
| P1 的数据流 | `ExternalMigrationResult.information` 和 `ExternalMigrationCompletion.information` 存储能力／创建时间说明，`noticeMessage` 以原成功文案加说明显示。`publicationWarning` 仅保留权限／标志恢复／持久化实错，原 proof 门禁不放开。创建时间说明不能令错误样式、普通文件的处理原件确认或摘要复用消失。应用包仍只复制，不自动处理应用原件。 |
| P2-1 | `MigrationDurability` 只核对一次根的绝对父路径，打开并绑定根 fd，随后 `fdopendir/readdir/fstatat/openat` 相对遍历；每项都校验设备／inode，不跟随符号链接，拒绝插入的挂载点。子项先 fsync，目录随后 fsync；父目录项相对 fsync 到所选卷根。保留一个文件 fd（无文件则根目录 fd），完成所有 fsync 后做**一次** F_FULLFSYNC。发布前和发布后分别有一个屏障；额外的复制前能力探测也有一次，不是整次搬家总共一个。没有逐项 F_GETPATH 或 PathSafety 全路径检查。 |
| P2-2 | 只有 durability／能力探测使用独立无进度预算：`max(reader.timeout, min(3600, 60 + bytes / 1048576))` 秒，即至少 60 s、每 MiB 再加 1 s、通常最多 1 h；512 MiB 为 572 s，1.2 GB 约 20 min。字节求和饱和到 Int64.max，处理原件时使用 item.sizeBytes。原复制／哈希／元数据看门狗和错误分类不变；没有伪造屏障中的字节进度。调用前后仍更新进度，取消仍迅速返回；工作线程返回前不能清暂存。发布已提交阶段继续忽略迟到取消，超时／I/O 错误返回已发布副本状态。测试专用显式 phase timeout 不改变旧断言预算。 |
| P2-3 | 在私有暂存树内创建 0600 探测文件，fsync 后试 F_FULLFSYNC，删除并同步暂存目录，**之后才开始复制源内容**。仅 POSIX ENOTSUP／ENOSYS／EINVAL 表示设备屏障不支持，后续仍逐项 fsync，并在结果和完成记录中明确记“该磁盘仅支持系统同步，无法确认设备缓存已刷新。”；不是静默成功，也不承诺这种卷能抵抗断电。能力绑定 st_dev，两次迁移同步复用。EIO、权限／断连、普通 fsync 失败仍失败；处理原件也在移动／回执之前重新同步，降级说明出现在该结果中。 |
| P2-4 | 发布后同步失败明确说副本已生成、原件保留、持久化未确认；要求检查外接盘、从列表处理原件、不要向同一位置再复制。中英文均覆盖。仍不给处理原件证明，不回滚已经发布的副本；发布前同步失败仍拒绝发布。 |

**本轮用户指令明确更新旧交接 H 中“不支持 F_FULLFSYNC 不回落”的表述**：仅设备级屏障明确不支持时可降级为 fsync，必须可见记录；真实 I/O 错误或 fsync 失败不可降级。支持的卷在提供处理原件入口之前已经完成目标文件、目录及设备屏障。D61 的系统 copyfile／禁止物化线程策略／只读云端预检／有界线程与迟到清理保持有效。`ScanStore.swift` 和 `MigrationStagingDirectory.swift` 完全不改，三处 ACL 游标 `.rawValue`、G 的所有权和硬链接保护全部保留。**P2-5 不做**：带 deny-delete ACL 在支持 ACL 的卷上发布仍可失败，只清自有暂存，不临时去掉发布目标的 ACL。

公共 API 语义依据为本机 SDK 的 `usr/share/man/man2/{fcntl,fsync}.2`（Xcode-27.0.0-Beta 的 MacOSX.sdk），尤其 `fcntl.2` 的 F_FULLFSYNC 段：设备级屏障在文件系统同步后请求排空设备缓存，可覆盖同一设备此前的 fsync；fsync 单独不提供该硬件缓存保证。硬件是否真的遵守命令、断电结果仍须真实设备验证。本轮未做新的平台实验。

### 新测试与旧断言逐条说明

新增 **11 个方法**，仅加入既有两个类。所有搬家／回执夹具沿用 `MigrationContentFixture` 的家目录隔离根及自有树清理；双语文案使用 `TestPreferenceDomain.swift` 中现成 `TestVolatilePreferences`，只覆盖内存 argumentDomain 并 defer restore，不写真实偏好。未新增 skip、未删测试方法、未降低压缩门槛。

- `MigrationPublicationFollowupTests` 新增 4 项：秒级舍入写回（两次生产元数据 pass）、warning nil／proof 非空／零重哈希处理原件；创建时间不支持或权限限制仅说明；错误秒数不能被精度比较掩盖；出生时间写回 EIO 仍拒绝发布和保留原件。
- `MigrationDurabilityTests` 新增 7 项：32 文件／2 目录所有 fsync 在唯一屏障之前且只检查根一次；目录被换成链接后拒绝且不跟随；300 ms 刷盘超过 100 ms copy watchdog 仍完成且 copy timeout 未改；三种明确不支持 errno 的复制前探测与可见降级；探测 EIO 在源读取／复制之前失败；已发布同步失败双语行动文案；取消能力探测后 300 ms 内不清理、工作线程返回后恰好清理一次。

既有测试改写只为观察新阶段与叶子 API，依据是本轮用户 P2 要求，结果保护含义不放宽：

1. 三个 trace 用例分别记录真实 `fsync` 和 `F_FULLFSYNC`，两种闭包均仍调用默认系统操作；原所有目标、父目录、源／链接不刷新、回执先后断言保留。
2. `testMigrationFlushesTargetFilesAndPublicationParentsBeforeReturningProof` 将原“暂存下任一普通文件”断言加强为实际 `/source.bin`，避免新增探测文件冒充副本。包用例再加屏障恰好一次断言。
3. `testFailedPrepublicationFullSyncNeverPublishesOrMovesOriginal` 的故障移到真正的 `fullSyncOperation`：能力探测成功，实际副本屏障返回 EIO。保留原 EIO、清理 1 s、原件保留断言；否则旧注入会只测试探测失败，错过原方法声称的发布前屏障。
4. `testCancellationOrTimeoutDuringSyncWaitsForWorkerBeforeCleanup` 显式设置测试用 durability timeout（取消分支 10 s／超时分支 0.1 s）。原 reader.timeout、<1 s 返回、300 ms 无清理、恰好一次清理和源保留断言全部不动。产品阶段预算按 P2-2 独立；不能再由缩短 copy timeout 隐含缩短刷盘预算。
5. `testMutationDuringDurabilityWaitCannotRebindAnOldDigest` 的闸门加 `/source.bin` 限定，确保改写在副本持久化阶段，不能在新增探测文件上误触发。原 proof nil、copyVerificationFailed、源保留和被改写副本内容断言不变。
6. 既有 B／G 所有方法正文、压缩类、ctime/线程清理/移动闭包取消反证测试原样保留。创建时间说明不会放开 B 的真正标志恢复失败或同步实错的 proof 门禁。

定向清单保持原 19 类加 `InvokedMigrationMoveTests`、`MigrationDurabilityTests`、`MigrationPublicationFollowupTests` 共 **22 类**，逐字沿用原清单；含 UIConsistencyRegressionTests／TestPreferenceHygieneTests。若发现集合不变，第三轮应为 **526 项**（515 + 11）；发现数、实际执行数、skip、失败数都以主会话日志为准，本轮不能预报 PASS。

### 每项红／绿／反证

红是同样夹具下的故障触发或独立单点变异；绿是最终候选满足完整结果断言；每项变异必须先编译成功再确认指定方法的断言／行为失败，编译失败不算红。`prepared-r3/mutations.json` 精确记录替换前后和目标方法；`run-mutations.py` 会先在隔离候选跑两个相关类的绿灯，再逐项变异并还原哈希，保存单次构建／测试日志。脚本不会动真实 worktree 或其 .git。

| 项 | 红／具体触发 | 候选绿灯要求 | 脚本反证 ID（指定测试） |
|---|---|---|---|
| P1 秒级精度 | 写入替身真实 setattrlist，但将纳秒截为 0；基线精确比较会把创建时间说明变成 publicationWarning。 | 两次 write 到副本；信息为空、warning nil、proof 非空；处理原件 reads=0、可恢复回执、两端内容正确。 | `P1-exact-nanoseconds`：忽略精度、强制 unit=1；`P1-skip-birth-write`：不调用写回。目标秒级方法／旧跨卷时间方法必须红。 |
| P1 说明与实错 | ENOTSUP／EINVAL／EACCES 写不进去；另写入正确粒度但 seconds+5，再单独注入 EIO。 | 前三者有准确说明且 proof 非空；错误秒数有说明，不能假称保真；EIO 拒绝发布，原件不动。 | `P1-promote-information`：说明并回发布警告；`P1-ignore-seconds`：精度比较忽略秒数；`P1-birth-EIO-as-capability`：把 EIO 当成可降级。 |
| P2-1 相对遍历与 fsync | 32 小文件两目录；逐项路径检查旧实现路径检查次数>1；刷盘空操作旧剖析仍接近真实耗时。 | 根绝对路径检查恰好一次，每文件 fsync、目录随后 fsync，唯一设备屏障在全部 inode 之后，不触源或链接。 | `P2-repeat-path-inspection`、`P2-skip-inode-fsync`、`P2-per-file-barrier`、`P2-skip-device-barrier`：数量／先后或源保护断言必须红。 |
| P2-1 竞态安全 | 首个文件 fsync 闸门把父目录挪出，再在原位置创建指向 fixture 根的链接。 | 返回 changed，源不被刷新／修改，不沿新链接遍历。 | `P2-skip-child-revalidation`：删除父名称对 pinned fd 的后验校验，目录替换方法必须红。 |
| P2-2 阶段预算 | reader.timeout=0.1 s，真实 fsync 前阻塞 300 ms；原 copy watchdog 会超时。 | 正常返回，reader.timeout 仍 0.1；512 MiB 预算572、极大字节预算3600。旧取消／超时测试保持 <1 s、300 ms 未清理、返回后一次清理。 | `P2-use-copy-timeout`：刷盘忽略独立 phase timeout，慢刷盘方法必须红；`P2-clean-active-worker`：取消未等工作线程就清理，新探测及旧持久化闸门方法必须红。 |
| P2-3 不支持 | 探测叶子返回 ENOTSUP／ENOSYS／EINVAL，现场确认暂存中只有探测文件、尚未复制。 | 仅探测调用一次；之后 fsync 完成，warning nil／proof 非空，结果与后续同步包含准确降级说明；原件保留。 | `P2-skip-precopy-probe`：直接伪造支持能力而不探测；`P2-silent-fallback`：同步返回空说明。指定能力测试必须红。 |
| P2-3 真实 I/O 故障 | 探测 F_FULLFSYNC 返回 EIO。 | 源读取次数0，抛 EIO、无副本／暂存，源内容不变。 | `P2-probe-EIO-as-capability`：把 EIO 纳入不支持集合，探测 I/O 方法必须红。 |
| P2-4 已发布失败 | 发布目标 fsync EIO，中英文各一次。 | copy exists＋original kept＋未确认持久化＋检查磁盘／从列表处理原件＋勿复制同位置，proof nil、副本及原件都保留。 | `P2-retry-existing-target`：恢复旧“请重试／Retry”文案，双语行动测试必须红。 |

变异脚本 16 组；除新增路径外，本轮后仍须保持原 A–H 的 21 组反证红灯（可复用独立复核 `evidence/harness/mutate.py` 的逻辑，按新接口调整相关 durability seam，不能只引用旧轮运行结果）。P2-5 没有新变异／功能扩展。

### 耗时证据与主会话测量方法

以下是**独立复核旧候选的实测**，本輪优化没有实测，不能把它们写成新版本性能结果。内置 SSD 上的 3 GB APFS sparse image：1.2 GB／3063 文件／3007 目录旧合并版 2.94／3.12／3.19 s、`c3eb0d4` 完整持久化 5.96／6.43／6.14 s；3 万小文件／1518 目录旧合并版 9.51／9.11 s、完整持久化24.70／25.99 s；512 MiB 单文件只多约30 ms。来源是复核报告第四节以及 `evidence/perf-{bigapp,many-small,single-file}.txt`。

剖析 `perf-durability-profile.txt`：3 万文件真实 synchronize 19.925／20.047 s、空操作19.118／21.221 s；应用包真实3.823／3.787 s、空操作3.453／3.705 s。独立直调策略 `perf-sync-strategies.txt` 的 fsync-each+barrier 为小文件0.640／0.686 s、应用包0.125／0.169 s。因工具和入口不同，后两数只能说明路径处理是热点，**不能推导第三轮总耗时会降到某数值**。预期是减少每项绝对路径查询和硬件屏障数，真实收益和残留开销由下述方法确认。

主会话使用已有 `evidence/harness/Experiments.swift` 的同规格构造，在隔离源码副本、同一 freshly copied tree 上交错测 `c3eb0d4` 和最终候选，每场景至少3轮。分别记录总 migrate／copyfile／发布前同步／发布后同步／原件处理同步；正常 fsync+barrier 与只将两种 flush 叶子替成空操作的 profile 各测，记录根路径检查次数、fsync 文件／目录次数、设备屏障次数。树遍历和安全检查不能在 profile 中消失。候选应当每同步阶段根检查1、逐项fsync、设备屏障1（另有能力探测）。每轮重建目标副本，禁止反复同步已落盘副本冒充首次持久化；读回内容、完整元数据及 `codesign --verify --deep --strict`，记录CPU负载与缓存状态，不靠放宽阈值过关。

四种映像矩阵重跑 P1：普通、只读、隐藏、锁定、ACL、压缩、应用包及目录／链接，对照各卷读回 precision；普通文件有 proof，支持粒度的创建时间舍入无 warning，只有可表达能力限制可见说明。支持系统同步却不支持设备屏障的第三方卷、真实 USB SSD／机械盘长刷盘、拔盘／断电与硬件是否服从 flush 均仍 **NOT RUN**。不得为了实验使用真实 iCloud／File Provider 或真实文件清理。

### 主会话命令、交付与状态

以下只供沙箱外主会话执行；本会话未执行任何 Swift 命令或测试：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-build-r3.log 2>&1
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 --filter 'MigrationPublicationFollowupTests|MigrationDurabilityTests' > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-focused-r3.log 2>&1
FILTER_R3=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-icloud-followups/prepared-r3/filter-followups.txt)
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-followups/debug --jobs 4 --filter "$FILTER_R3" > /Users/developer/Developer/.sc-build/r2-icloud-followups/logs/main-targeted-r3.log 2>&1
python3 /Users/developer/Developer/.sc-build/r2-icloud-followups/prepared-r3/run-mutations.py
git diff --check
```

定向脚本 stdout／stderr 保存到上述日志并另记 exit code。反证脚本在本批 `mutation-r3-<UUID>` 构造 `git archive c3eb0d4 + all.patch` 的隔离候选；依赖只从 RULES 指定 r2-u1-preselect/debug 复制四项。单点变异分别重新执行 `swift test`，只有指定 XCTest 方法实际运行且失败才判红，编译失败／没有发现测试为 BLOCKED；finally 恢复文件 SHA 并清自有候选与带 CACHEDIR.TAG 的构建缓存，仅保留 `logs/mutations-r3/<UUID>/`。脚本不更改 worktree、索引或基线，不提交，不运行已安装应用。

`prepared-r3/` 相对 `c3eb0d4` 分四组：

1. `01-metadata-and-durability`：MigrationCreationTime／MigrationDurability／GuardedFileCopy／ExternalDriveMigrationService，统一 API 与数据流。
2. `02-migration-information`：LargeFilesStore／LargeFilesView，说明可见而不阻断证明／确认。
3. `03-round3-regressions`：两个测试类，新增11方法与上述阶段观察调整。
4. `04-handoff-r3`：本节追加，不重写前轮证据。

每组 patch／message、all.patch、manifest（基线／分支／组序／最终文件及产物 SHA-256）、commit-prepared.py、generate-prepared.py、filter-followups.txt、mutations.json／run-mutations.py、静态检查、输入／前轮产物哈希和 JEV 状态均交付。主会话在编译、定向、反证、实测和独立复核通过后才运行 commit-prepared.py；脚本只按组提交，不测试、不安装、不推送。trailer 严格保留用户指定两行。

本轮实际静态命令和 exit code 见 `prepared-r3/static-checks.json`：补丁正／反向可应用、diff check、公共／私有 API 源码守卫、Python AST、16组变异替换锚点唯一且复原哈希、九文件范围／未删方法／旧阈值／B与G／ACL游标保留检查。静态 PASS 不等于 Swift 编译、Swift6并发、526项测试或动态反证 PASS。第三轮编译、XCTest（执行0）、严格并发、动态反证、优化耗时、四种目标矩阵复跑、独立复核、提交／安装／合并均 **NOT RUN**。

本轮沿用 `build-macos-apps:test-triage` 的故障分类和缩小入口方法，用户“不要构建、测试、提交”优先，不执行技能里的动态步骤。JEV 就独立有界预算与只响应取消的取舍发起请求，但 `mcp__jev__jev_decide` 返回 `MCP tool call requires approval, but approval policy is never`；未返回模型标识或判断，状态 **BLOCKED**，原始状态见 `prepared-r3/jev-status.json`。本轮方案由实现方依据用户 P2、D61 和可复查平台语义选择，不冒称获得 JEV 认可。原复核中另一会话的 JEV 结果不是本轮决策工具运行结果。
