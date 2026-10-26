# P02 · D183 邮件库附件

状态：D183 实现已交付，构建通过、改动文件 0 新警告、新增 19 测试全通过；指定测试集 142 passed / 2 原有 skipped / 10 原夹具失败，整体 exit 1，需主会话完成下列 BLOCKED 复核。

工作目录 `/Users/developer/Developer/sc-worktrees/p02-mail`；输入为用户指定的 `f6a78f97` 集成副本（本副本实际 git HEAD 为 `6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b`，以进入本轮时的文件快照作本批比较基准），保留进入本轮时的所有已有差异和未知文件。未 commit、push、安装、发布，未修改 DECISIONS。只用当前 Codex；没有调用 JEV 或其他模型：当前工具未发现 JEV，且未授权本次来源和预算。

## 文件与作用

- `Sources/StorageCleanerMac/Models/CleanupScanModels.swift`：新增 `namedDescendantDirectories` 和可选 `maximumCandidates`，旧规则仍默认 40 行。
- `Sources/StorageCleanerMac/Models/CleanupNamedDescendantScope.swift`（新）：计划与执行共用的根、目录名和深度检查；仅 D183 的精确 Mail 规则能例外进入通用保护的邮件库。
- `Sources/StorageCleanerMac/Services/CleanupDirectoryEntries.swift`（新）：只发现目录与链接的 POSIX 目录列表，目录项类型已知时不读取邮件文件的完整属性；不跳过 `.mbox` 包。
- `Sources/StorageCleanerMac/Services/ReadOnlyCleanupScanner.swift`：新范围校验、受 deadline 约束的发现遍历、候选数覆盖，以及中英文标题和说明。`descendantAggregate` 的原拒绝保持。
- `Sources/StorageCleanerMac/Models/CleanupExecutionModels.swift`：新范围的计划路径检查与目录类型检查；旧范围原检查保持。
- `Sources/StorageCleanerMac/Services/SafeCleanupExecutor.swift`：预检与持久化意图后的复核，要求准确的 home-relative 根、匹配的名称/层数、扫描路径与当前路径一致；沿用已有身份、链接、权限和运行 App 复核。
- `Sources/StorageCleanerMac/Models/CleanupRuleProvenance.swift`：将候选上限写入规范化指纹；nil 不增加字段，原规则哈希不变。
- `Sources/StorageCleanerMac/Models/CleanupCoverageCatalog.swift`：增加 D183 规则并登记；D24 只更新注释。
- `Sources/StorageCleanerMac/Models/OperationConfirmationModels.swift`：增加 `CleanupImpactText.englishByChinese` 对应英文。
- `Sources/StorageCleanerMac/Views/CareStudio/CareJunkGrouping.swift`：两条 Mail 规则沿用同一邮件附件组，更新组说明；从 `.mbox` 名字提取并本地化邮箱名，无法推断时用路径末四级。
- `Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkManager.swift`：D183 行标题显示邮箱名。
- `Resources/CleanupRules.baseline.json`：新增 revision 1 的 D183 条目，保留 legacyRules 和其他条目。
- `Tests/StorageCleanerMacTests/MailLibraryAttachmentRuleTests.swift`（新）：10 个规则、扫描、上限和基线测试。
- `Tests/StorageCleanerMacTests/MailLibraryAttachmentExecutionTests.swift`（新）：7 个审阅后移动回执、执行拒绝和最终复核测试；只在夹具内模拟废纸篓及放回，不操作系统废纸篓。
- `Tests/StorageCleanerMacTests/MailLibraryAttachmentPresentationTests.swift`（新）：2 个中英文、分组和行标题测试。
- `Tests/StorageCleanerMacTests/CleanupRuleScannerTests.swift`：增加新规则的集合期望，小附件 D24 原夹具仍不命中 1 MB 门槛；旧规则不存在的断言保留。
- `Tests/StorageCleanerMacTests/CleanupRuleProvenanceTests.swift`：指纹变更字段覆盖新增上限。
- `Tests/StorageCleanerMacTests/CleanupJunkActionableTests.swift`：新范围夹具分支、D183 的预期附件行；保留其他个人数据不列出的断言，期望变动旁注明“D183＋旧值”。
- `docs/2.0.1/cleanup-rule-table.md`：范围外必要生成文件。现有 `CleanupRuleTableTests` 要求规则目录与表一致，通过其既有生成入口更新，不改校验。
- 本交接文件。

## 走查与安全边界

根的深度为 0，后代目录最多查到 16 层（包含第 16 层）。精确匹配 `include.nameMatcher` 的目录单独成为候选，发现阶段不再进入命中目录；后续沿用现有元数据聚合以计算整行大小，内部同名目录不会再生成行。普通文件在发现阶段通过 `readdir.d_type` 跳过；类型未知时才 `lstat`。每次目录读取、每个目录项和聚合均沿用 `checkDeadline`；超时进入 `.timedOut`，取消沿用原取消语义。

新范围只允许 homeRelative、directory-only、exact 非空匹配、reviewOnly、默认 unselected、moveToTrashAfterReview、非空 requiredClosedBundleIDs；还要通过既有 reviewed-action 的完整计量、手动选择与执行资格校验。候选上限若非 nil 必须在 1…1000。

通用 `ProtectedLocations` 仍保护 `Library/Mail`：仅 ID、根、新范围、目录类型、精确 `Attachments`、黄色、不预选、审阅动作和 `com.apple.mail` 均吻合的 D183 规则可在规则引擎内部例外读取。文件分析、卸载及其他规则的保护不变。

计划生成检查根包含关系、末级精确目录名、1…maximumDepth、目录类型及快照链接标志。执行时再以当前用户 home 拼出准确规则根，检查原扫描路径；已有 metadataReader 重新确认整个路径不含链接、卷状态与扫描身份一致。上述检查在预检和真正移动前（持久化意图后）都会运行。没有新增删除、进程启动或移动实现。

## 新规则完整定义与文案

`id=mail.library-attachment-folders`；`selectionPolicyVersion=2`；`categoryID=mail`；`categoryTitleKey=cleanup.category.mail`；`titleKey=cleanup.rule.mailLibraryAttachments.title`；`root={kind:homeRelative,path:Library/Mail}`；`candidateScope=namedDescendantDirectories`；`maximumCandidates=400`；`maximumDepth=16`；`minimumAgeDays=0`；`minimumBytes=1000000`。

`include={entryKinds:[directory],extensions:[],nameMatcher:{mode:exact,values:[Attachments]}}`；`exclude={relativePrefixes:[],extensions:[]}`；`cloudPolicy=skipPlaceholder`；`risk=reviewOnly`；`recommendation=optional`；`defaultSelection=unselected`；`executionEligibility=eligibleAfterReview`；`measurementRequirement=complete`；`allowsManualSelection=true`；`action=moveToTrashAfterReview`；`requiredClosedBundleIDs=[com.apple.mail]`；`reasonKey=cleanup.reason.mailLibraryAttachments`；`ownerDisplayName=Apple Mail`。其他可选规则字段均 nil。

维护信息：`source=coverage-catalog`，`revision=1`，`checkedAt=2026-10-23`，`applicability=[]`，`evidenceURLs=[]`。

标题：`邮件附件` / `Mail Attachments`。通用标题格式仍带所有者前缀 `Apple Mail · …`。

说明（中文）：邮件 App 本地库中的附件文件夹，默认不选，请先逐项审阅并退出“邮件”。附件只移入废纸篓，可放回；IMAP 等仍在服务器上的邮件打开时会重新下载附件。只存在本机的邮件（如 POP 或“我的 Mac 上”邮箱）需要从废纸篓放回附件后才能再查看。

说明（英文）：Attachment folders in Mail’s local library. None is selected by default; review each one and quit Mail first. Attachments move to the Trash and can be put back. Mail downloads attachments again when you open messages still on a server, such as IMAP. For messages stored only on this Mac, including POP or On My Mac mailboxes, put the attachments back from the Trash to view them again.

影响（中文）：附件将移入废纸篓，可放回。IMAP 等服务器邮件打开时会重新下载附件；仅存本机的邮件（如 POP 或“我的 Mac 上”邮箱）需从废纸篓放回附件后才能再查看

影响（英文）：Attachments move to the Trash and can be put back. Mail downloads them again when you open messages on a server, such as IMAP. For messages stored only on this Mac, including POP or On My Mac mailboxes, put the attachments back from the Trash to view them again

## 规则基线与生成表

仓库 `script/` 中未找到规则基线生成脚本。先运行新增基线测试，由实际 `CleanupRuleFingerprint.contentHash(for:)` 在缺条目的 `XCTUnwrap` 信息中给出哈希，再只插入新条目：

`1ce6af59be43ca4e5eac714becf9290258458428f979c704b7bd9af2bd0b0c68`

新增条目 revision 1；程序比较确认所有旧 entries 和 legacyRules 与进入本轮时逐项一致。`mail.downloaded-attachments` 的原哈希保持 `987fa2d7d51604e5678a656532b9d2cf52a07e444e0065e286989f0bfeb03575`。随后新增基线测试和既有基线校验通过。规则表使用既有 `STORAGE_CLEANER_RECORD_RULE_TABLE=1` 测试入口生成，最终在不设置该变量的测试运行中比对通过；表为 88 条（33 developer、40 coverage、15 JSON）。

## 验证记录

最终构建 PASS，19 个新增测试全通过。指定过滤集共 154 个测试：142 passed、2 个原有 opt-in 测试 skipped、10 个原测试失败（9 个家目录写入权限问题、1 个日志夹具清理 ENOENT，详见 BLOCKED），整体命令 exit **1**，不能声称整组通过。没有放宽、删除或新跳过任何原测试。对进入本轮时的 3 个原测试类审计：18/12/46 个测试方法全部保留。

所有 Swift 命令使用：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing --filter '^StorageCleanerMacTests\.(MailLibraryAttachment[A-Za-z]*Tests|CleanupRule[A-Za-z]*Tests|CleanupExecution[A-Za-z]*Tests|CleanupJunkActionableTests|BrokenPreferencesRuleTests|CompetitorDerivedRuleTests|ScanCoverageLimitsTests|ScanSessionRescanMergeTests)'
python3 -B script/display_bound_tests.py --check
python3 -B script/check_deletion_process_inventory.py
python3 -B script/check_private_api.py
```

实际运行与 exit code（日志均在 `.build/d183-evidence/`）：

| 日志 | 命令/结果 | Exit |
| --- | --- | --- |
| `build.log` | 上述 build；初次 GitHub DNS 无法解析，依赖不能下载 | 1 |
| `build-offline.log` | 同一 build；使用本机锁定依赖后，发现新目录 API 指针解包编译错误，已修复 | 1 |
| `build-fixed.log` | 同一 build；测试误用 fileprivate CleanPlan 构造器，改为正式构造器与元数据注入，已修复 | 1 |
| `build-final.log` | 同一 build；应用与测试编译通过 | 0 |
| `build-fixtures.log` | 同一 build；修正 3 处测试夹具后增量编译通过（22.40 s） | 0 |
| `baseline-hash.log` | 上述 test 的 filter 换为 `^StorageCleanerMacTests\.MailLibraryAttachmentRuleTests/testRuleIsReviewedSelectableAndInTheBaseline$`；取得真实函数哈希，插入前新条目尚不存在 | 1 |
| `tests.log` | 上述全过滤集并设置 `STORAGE_CLEANER_RECORD_RULE_TABLE=1`；生成规则表，暴露夹具字节门槛及 `/var` 别名问题，随后修复 | 1 |
| `tests-final.log` | 上述全过滤集，不设置生成变量；142 passed / 2 skipped / 10 原夹具失败（30.305 s） | 1 |
| `display-bound-final.log` | display_bound_tests.py --check，63 in-process / 1 out-of-process / 1 exempt | 0 |
| `deletion-inventory-final.log` | check_deletion_process_inventory.py，174 entries / 266 uses，清单未改 | 0 |
| `private-api-final.log` | check_private_api.py，9 allowlisted uses，清单未改 | 0 |
| `diff-check.log` | 本批文件差异与新文件空白检查 | 0 |

初次编译没有复用编译对象。离线依赖只从本机既有 `/Users/developer/Developer/.sc-build/v2.0.1/bootstrap/{checkouts,repositories,artifacts,workspace-state.json}` 复制到本工作目录的 `.build/codex` 并重定向 artifact 路径。已核对 Package.resolved、checkout revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`、Sparkle 2.10.0 及二进制 checksum `17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959`；没有改依赖声明、版本或外部缓存。

本轮每次均调用要求的 nice 命令，但沙箱返回 `nice: setpriority: Operation not permitted`，不能声称成功调整进程优先级；构建始终限制 jobs 4。最终改动文件 0 新警告，见 `changed-warnings.log`。用户给定基线警告之外，首次全编译另见未修改的 `Sources/FileOperationShared/UpdateAskpassInvocationRegistry.swift:12/13`（withLock 未使用结果）和 `Sources/StorageCleanerMac/Features/DuplicateFiles/CloneMerge/APFSCloneReplacement.swift:109`（String(cString:) 弃用）；没有越界修复。SwiftPM 用户缓存不可写与已有重复 rpath 警告仍在。

新增测试清单（19 个，最终均 PASS）：

`MailLibraryAttachmentRuleTests`（10）：

- `testRuleIsReviewedSelectableAndInTheBaseline`
- `testNamedDescendantsRejectUnsafeCombinationsAndAggregateStaysRejected`
- `testOnlyD183CanEnterTheProtectedMailLibrary`
- `testScopeAndCandidateOverrideParticipateInFingerprint`
- `testDiscoversExactDirectoriesThroughPackagesAndMeasuresEachWholeFolder`
- `testMaximumDepthIncludesTheBoundaryButNeverDeeperCandidates`
- `testKeepsLargest400FoldersAndOtherRulesStillKeep40`
- `testWalkTimeoutIsReportedFromInsideTheDirectoryListing`
- `testDeniedBranchIsReportedWhileOtherMailboxesRemainReadable`
- `testDeniedLibraryRootUsesTheExistingPermissionReport`

`MailLibraryAttachmentExecutionTests`（7）：

- `testReviewedFolderUsesTheExistingMoveReceiptAndCanBePutBack`
- `testMailMustBeClosedAndSelectionMustBeExplicit`
- `testPlanAndExecutorRejectRenamedOutsideAndTooDeepPaths`
- `testPreflightRejectsReplacementBySymlinkOrAnotherDirectory`
- `testPreflightRejectsASymlinkInAnAncestor`
- `testRenamingOrMovingAScannedFolderMakesTheOriginalPlanMissing`
- `testFinalIdentityCheckAfterDurableIntentStopsASymlinkSwap`

`MailLibraryAttachmentPresentationTests`（2）：

- `testGroupsBothMailRulesTogetherAndNamesMailboxesInBothLanguages`
- `testTitleReasonAndImpactExplainTrashServerDownloadAndLocalRestoration`

## BLOCKED 与主会话下一步

下列 9 个原测试的家目录夹具写入被沙箱拒绝（`NSCocoaErrorDomain Code=513`，底层 `NSPOSIXErrorDomain Code=1 "Operation not permitted"`）：

- `BrokenPreferencesRuleTests.testOnlyUnreadablePreferenceFilesAreListed`
- `CleanupExecutionSafetyTests.testNewStoreReconnectsOnlyLatestRestorableVerifiedDuplicateReport`
- `CleanupExecutionSafetyTests.testPersistedDuplicateCleanupRecoveryFailsClosedForCorruptOrConsumedReports`
- `CleanupExecutionSafetyTests.testProductionQuarantineMoveAndIdentityCheckedRestoreUseOnlyTemporaryFixture`
- `CleanupExecutionSafetyTests.testRecoveryRejectsReplacementAtQuarantineReceiptPath`
- `CleanupRuleProvenanceTests.testJournalEventsPreserveAndRefuseChangesToProvenance`
- `CleanupRuleScannerTests.testDeveloperThresholdPersistsInExistingScanStore`
- `CleanupRuleScannerTests.testScanOnlyFeatureFlagDisablesAllLegacyTrashEntryPoints`
- `CleanupRuleScannerTests.testTopLevelSelectAllSelectsOnlyGreenCandidates`

准确示例：`/Users/developer/.storage-cleaner-broken-preferences-…/home`，或 `.storage-cleaner-cleanupquarantine-…/home/Library/Caches`，错误为 `You don’t have permission to save the file …`，完整 UUID 路径和错误见 `tests-final.log` 与 `blocked-errors.log`。

另有 `CleanupExecutionSafetyTests.testJournalReloadRetainsIdentityAndRejectsChangedIntent` 在清理家目录夹具时报 `NSCocoaErrorDomain Code=4`、底层 `NSPOSIXErrorDomain Code=2 "No such file or directory"`，位置为 `TestFileSystem.swift:72`，路径 `/Users/developer/.storage-cleaner-journalfixture-…`。它也在沙箱可写根外，但尚未独立证实其根因一定是权限；不能把它算通过。主会话应在允许家目录夹具的环境重跑这 10 项，若日志夹具仍失败再调查原有测试/日志路径，不放宽断言。

两个原有 opt-in 跳过项为 `CleanupRuleScannerTests.testOptInCapturesCurrentHomeDeveloperArtifactScan` 与 `testOptInCapturesCurrentHomeStorageAnalyzerParity`。未启用真实家目录扫描，未改跳过条件。

建议主 Agent 先复核 `.build/d183-evidence/scoped.patch`、源文件 SHA-256 与上述日志，再集成；本批未执行真实邮件库扫描、系统废纸篓移动或窗口测试。


## 限制

未读取真实 `~/Library/Mail`，未打开或解析邮件/附件内容。没有完全磁盘访问权限时沿用现有 permissionDenied、受限扫描提示和权限引导；单个不可读分支记 issue，其他可读邮箱仍可产生结果。无账户元数据读取，因此只有路径能推出的邮箱名，不能为 UUID 账户猜邮箱地址；无 `.mbox` 的布局显示路径末四级。上限之外的较小行计入 truncatedCandidateCount。系统实际移动仍由现有基于路径的 API 执行，检查与系统调用间的极短竞态窗口沿用既有机制。未在真实邮件库比对 480 MB；结果还受 1 MB 单行门槛、16 层深度、400 行上限、时间限制和系统权限影响。
