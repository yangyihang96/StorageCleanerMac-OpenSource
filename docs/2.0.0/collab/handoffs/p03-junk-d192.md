# p03-junk：D192①⑦ 与经典列表标题交接

状态：代码与文档已准备交接；最终 Debug 构建通过，92 项可在当前沙箱运行的核心／守卫测试全部通过。完整定向过滤受环境阻塞，见下文 BLOCKED。

## 范围与基线

只在 `/Users/developer/Developer/sc-worktrees/p03-junk` 修改。任务给定输入为集成树 `32495dd6` 的完整副本；本目录 git HEAD 实际为 `6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b`，存在大量已带入的集成差异，未重置、暂存或提交。
本次修改前副本保存在 `.build/p03-junk-d192-evidence/before/`，相对于副本的差异保存在同目录 `diffs/`；这些差异用于区分本次工作与原有集成修改。另附本次 27 文件的纯增量补丁 `.build/p03-junk-d192-evidence/p03-junk-d192.patch`，以及包含改前／改后 SHA-256 的 `change-manifest.json`。补丁检查命令为 `git apply --check --reverse .build/p03-junk-d192-evidence/p03-junk-d192.patch`，结果见 `artifact-validation.json`；该命令只检查当前文件与补丁一致，不改工作树。未读取真实废纸篓或 iCloud 内容，未联网、安装、清空真实项目、commit 或 push。

## 文件与作用

| 文件 | 本次作用 |
| --- | --- |
| `Resources/CleanupRules.baseline.json` | 新规则 revision 1 指纹，保留 legacyRules。 |
| `Sources/StorageCleanerMac/Models/CleanupCoverageCatalog.swift` | 新增独立 trash.icloud-drive 规则。 |
| `Sources/StorageCleanerMac/Models/CleanupExecutionModels.swift` | 只有精确 iCloud 规则允许冻结占位条目；计划仍按顶层冻结、身份约束。 |
| `Sources/StorageCleanerMac/Models/CleanupScanModels.swift` | 四项扫描范围、版本化持久化键、精确的 iCloud 废纸篓判定。 |
| `Sources/StorageCleanerMac/Models/OperationConfirmationModels.swift` | 所有设备永久删除影响说明的英文映射。 |
| `Sources/StorageCleanerMac/Services/ReadOnlyCleanupScanner.swift` | 新根校验；POSIX 元数据入口；云端逻辑与本机实占分算；占位条目入冻结计划；纯云端零实占也列行。 |
| `Sources/StorageCleanerMac/Services/SafeCleanupExecutor.swift` | iCloud 执行前身份复核、删除后核对均用元数据入口；复用原永久删除器。 |
| `Sources/StorageCleanerMac/Stores/ScanStore.swift` | 恢复与保存开关；垃圾清理结果页重扫沿用会话范围，保持 D68 专页摘要边界。 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareJunkGrouping.swift` | 扫描范围、进度与结果共用四组分类；系统垃圾包含非 AI 开发者与待确认规则。 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkManager.swift` | iCloud 云盘废纸篓独立行名。 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioTheme.swift` | 侧栏帮助更新为四项。 |
| `Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift` | 第二项确认明确所有设备永久删除，并用同一 AND 判断连接两个确认开关。 |
| `Sources/StorageCleanerMac/Views/CleanupScanViews.swift` | iCloud 行显示逻辑/实占两种大小；经典标题按 D179 覆盖限制判断。 |
| `Sources/StorageCleanerMac/Views/ContentView.swift` | 四项 SF Symbols；经典卡片复用同一标题与说明，不重排布局。 |
| `Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldCleanupScopeRow.swift` | 四项标题/说明；系统垃圾复用缓存 PNG，其他项使用 SF Symbols。 |
| `Tests/StorageCleanerMacTests/CareStudioRenderReviewTests.swift` | 回归测试：D192 新行为或同步旧期望，保留原断言目的并注明旧值。 |
| `Tests/StorageCleanerMacTests/CleanupRuleScannerTests.swift` | 回归测试：D192 新行为或同步旧期望，保留原断言目的并注明旧值。 |
| `Tests/StorageCleanerMacTests/FeatureLightfieldResultSpaceTests.swift` | 回归测试：D192 新行为或同步旧期望，保留原断言目的并注明旧值。 |
| `Tests/StorageCleanerMacTests/SafeCleanupScopeCardLayoutTests.swift` | 回归测试：D192 新行为或同步旧期望，保留原断言目的并注明旧值。 |
| `Tests/StorageCleanerMacTests/ScanCoverageLimitsTests.swift` | 回归测试：D192 新行为或同步旧期望，保留原断言目的并注明旧值。 |
| `Tests/StorageCleanerMacTests/SmartScanScopeTests.swift` | 回归测试：D192 新行为或同步旧期望，保留原断言目的并注明旧值。 |
| `script/deletion-process-inventory.txt` | 在现有 unlinkat 登记中明确新根及双确认/占位文件限制，调用数仍为 1。 |
| `Tests/StorageCleanerMacTests/CleanupScopeD192Tests.swift` | 新增 4 个测试：四组完整互斥、与智能呵护一致、规则映射、偏好往返和损坏回退。 |
| `Tests/StorageCleanerMacTests/ICloudDriveTrashTests.swift` | 新增 8 个隔离夹具测试：规则边界、尺寸、纯云端、双确认、冻结/替换/链接、根替换、下载状态变化。 |
| `Tests/StorageCleanerMacTests/ScanAccessReturnTests.swift` | A-R3 旧 caches 枚举引用同步为 systemJunk，保留会话范围与偏好不变断言，并注明 D192＋旧值。 |
| `docs/2.0.1/cleanup-rule-table.md` | 已由 CleanupRuleTableTests 记录模式生成；普通模式 2 个测试已通过，共 89 条规则。 |
| `docs/2.0.0/collab/handoffs/p03-junk-d192.md` | 本交接、逐规则映射及验证证据索引。 |

## 四项与存储

`cleanup.selected-scopes.v1` 存在注入的 `cleanupPreferences` 中，保存稳定顺序的字符串数组；未保存、类型错误或包含未知值均恢复全开，显式空数组保留全关。无需迁移原内存值。
系统垃圾包含开发工具产物和待确认文件；AI 识别沿用 `DeveloperTool.isAITool` 与 `ruleKeyword`，仅对 developer 类规则生效；mail/trash 优先。完整逐规则表在文末。

| 项目 | 范围 | 起始页符号 / 经典资源 |
| --- | --- | --- |
| 系统垃圾 / System Junk | 除后三组外全部规则，含系统/浏览器/应用缓存、日志、临时文件、损坏偏好、CloudKit、非 AI 开发者、下载/应用/用户数据待确认项 | `gearshape.2.fill` 表示系统与工具产物；经典列表复用 `scope-cleanup-cache-{192,512}.png` |
| AI 垃圾 / AI Clutter | developer 类 AI 工具规则 | `sparkles` 表示 AI 工具生成内容，无新增图片 |
| 邮件附件 / Mail Attachments | categoryID == mail | `envelope.fill` 表示邮件附件，无新增图片 |
| 废纸篓 / Trash | categoryID == trash，包括 iCloud 新规则 | `trash.fill` 表示待清空项目，无新增图片 |

## iCloud 规则字段

| 字段 | 值 |
| --- | --- |
| `id` | trash.icloud-drive |
| `selectionPolicyVersion` | 2 |
| `categoryID / categoryTitleKey` | trash / cleanup.category.trash |
| `titleKey` | cleanup.rule.iCloudDriveTrash.title → iCloud 云盘废纸篓 / iCloud Drive Trash |
| `root.kind / root.path` | homeRelative / Library/Mobile Documents/.Trash |
| `candidateScope / maximumCandidates` | root / nil（不改变默认行数限制） |
| `maximumDepth / minimumAgeDays / minimumBytes` | 32 / 0 / 1；仅云端有逻辑大小而本机为 0 时也显示 |
| `include` | entryKinds = [directory]；extensions = []；nameMatcher = any / [] |
| `exclude` | relativePrefixes = []；extensions = []；namePrefixes = nil |
| `cloudPolicy` | metadataOnly（包含占位文件）；复用现有选项，无新增枚举值 |
| `risk / recommendation` | protected（红色） / notRecommended |
| `defaultSelection` | unselected |
| `executionEligibility` | eligibleAfterProtectedReview |
| `measurementRequirement` | complete；保留既有 D19 对 lowerBound 的人工审阅规则 |
| `allowsManualSelection / action` | true / emptyTrash |
| `requiredClosedBundleIDs` | [] |
| `reasonKey` | cleanup.reason.iCloudDriveTrash |
| `ownerDisplayName / developerTool / developerArtifactKind` | nil / nil / nil |
| `includedBundleIdentifiers / requiresDuplicateBundleIdentifier` | nil / nil |
| `ownerInference / projectArtifact / contentRequirement` | nil / nil / nil |
| `maintenance` | source=coverage-catalog；revision=1；checkedAt=2026-10-23；impact=会从你所有设备上的 iCloud 云盘永久删除，不能撤销；applicability=[]；evidenceURLs=[] |

## 占位文件、删除边界与提示

扫描与执行复核仅在这条精确规则上使用 `metadataOnlySnapshot`：文件大小来自 lstat 的 st_size，本机实占来自 st_blocks×512，SF_DATALESS 标明占位状态；statfs 只读取卷只读标志，祖先链接检查也只用 lstat。目录列表不预取 URL 资源属性。遍历不会读取文件内容、查询 FileProvider 下载状态或调用下载 API，也不读取 APFS 共享空间属性。
夹具沿用现有 RuleTestReadOnlyFileSystem 的方式，仅忽略系统临时目录 `/var` 祖先别名；在自有夹具 home 内逐级 lstat 检查链接，产品检查未放宽。占位大小和状态注入 FileSnapshot，未给任何真实文件设置占位标志。

目录测量聚合逻辑/实占两种大小；深层占位文件也计入逻辑大小；废纸篓内 Documents 等名称只是统计元数据，不按普通垃圾规则忽略其容量。行内采用 `iCloud 中 … · 本机 …`；不完整测量加“至少”，预计本机释放和永久删除计划按实占求和。既有 D23 的释放提示规则继续适用。
仅在扫描时冻结顶层条目；之后新增的顶层条目不会进入计划。计划与执行前逐条复核身份、卷、路径与废纸篓根身份。普通废纸篓仍跳过占位条目；只有精确的 iCloud 规则允许占位条目及下载状态变化。链接沿用 D23：顶层指向外部的链接不冻结，允许的链接仅 unlink 本身，内部链接也不跟随。
永久删除复用 `FoundationCleanupPermanentDeleter`：仅以 O_DIRECTORY|O_NOFOLLOW 打开目录，用 fstat/fstatat(AT_SYMLINK_NOFOLLOW) 核对身份，用 fdopendir/readdir 列目录、unlinkat 删除；不会打开普通文件或读取数据。执行后的存在性核对也走 lstat 元数据入口。此依据支持“不主动物化文件”，真实 iCloud 同步效果仍须主会话在安装后观察，不能用夹具替代。
第一次确认保持“我了解这些项目会被永久删除，无法恢复”；第二次确认在包含 iCloud 计划时为：“我已确认没有需要保留的文件；会从你所有设备上的 iCloud 云盘永久删除，不能撤销”。两项均勾选才向 store 传递永久删除确认。
新根已登记于 `script/deletion-process-inventory.txt` 的 SafeCleanupExecutor / unlinkat 项；没有增加删除原语、调用点或第三条永久删除通路。

## 复核与模型

沿用当前 Worker 模型与推理设置，没有委派或切换供应商。使用 debugging-and-error-recovery 核对根因、code-review-and-quality 复核本次差异。当前工具未发现已授权来源和本次预算的 JEV 入口，未调用 JEV，也未声称得到其复核结论。

## 验证

**PASS** 最终构建 `build-final-2` exit 0；本次修改的 Swift 文件在全部构建日志中新增警告为 0（`modified-file-warnings.json`）。既有 linker 重复 rpath 警告和未修改文件的警告保留，未为本任务改动其他批次文件。
**PASS** `headless-final` exit 0：实际 `Executed 92 tests, with 0 failures`，0 跳过；包含四范围 4、iCloud 8、覆盖限制 6、规则表 2、永久删除守卫 4、UI 源码一致性 46、外接盘废纸篓 9、本机永久删除 5、CareStudio 渲染／任务分组 8。
**PASS** 规则表记录模式 `rule-table-record-2` 2/0；普通模式已在 core-3、完整过滤及 headless-final 中各运行 2/0，生成内容与 89 条规则一致。
**PASS** 显示测试清单 `display-final-2` exit 0（63 in-process、1 out-of-process、1 exempt）；删除／进程清单 `deletion-final` exit 0（181 项、273 处使用）；`diff-check` exit 0。没有从显示清单移走测试。
**PASS（反证）** 临时把双确认 AND 改为 OR 后，8 个 iCloud 用例中的双确认用例在两个单勾场景各失败一次，命令 exit 1 为预期结果。源码已按保存副本逐字节恢复（SHA-256 一致，见 `confirmation-mutation.json`），之后重新构建且 iCloud 8/0 通过；最终代码要求两个确认同时为真。

**BLOCKED** 完整过滤 `targeted-final-2` 实际执行 270 项：173 通过、95 项因环境失败、2 项既有 opt-in 真实家目录扫描未启用；XCTest 汇总为 139 个 failure 条目，其中 73 个 unexpected（一个用例可产生多个 failure 条目）。95 个失败用例均可归因于 73 个写入沙箱外操作夹具失败和 22 个 D106 显示门禁拒绝，未发现其余断言失败，目录见 `targeted-final-2-failures.json`。
操作夹具必须由 TestFileSystem 登记且操作根位于真实家目录的 `.storage-cleaner-<用途>-<UUID>`，当前 writable roots 仅本工作目录和临时目录；工厂在创建时返回 NSCocoaErrorDomain 513 / NSPOSIXErrorDomain 1。`TestFileSystem.swift` 的 requireOwned、isFixtureRoot 和 ownership.contains 守卫未放宽。新增的 Store 跨实例持久化、结果页重扫范围两个运行用例也在此处阻塞，需要主会话补跑；纯偏好往返、完整互斥规则集合、源码连接均已通过。
D106 需要明确的测试显示屏；当前门禁拒绝 orderFront，没有授权屏幕可供本 Worker 使用。经典列表图标／排版、Store D68／A-R3 运行验证须由主会话在自己的测试显示屏及允许的操作夹具环境补跑。2 个 opt-in 用例为 testOptInCapturesCurrentHomeDeveloperArtifactScan、testOptInCapturesCurrentHomeStorageAnalyzerParity；任务禁止真实家目录扫描，因此未设置对应输出变量，没有新增 skip。
构建、测试均使用要求的 `nice -n 15`，但内核沙箱拒绝 setpriority（日志首行 Operation not permitted），进程仍执行；构建 jobs 始终为 4。不能声称实际降低了优先级。Sparkle 2.10.0 从既有 `/Users/developer/Developer/.sc-build/v2.0.1/debug` 离线缓存复制，所有 Swift 构建／测试命令禁用自动依赖解析；后续设置工作区内的 SwiftPM cache/config/security/manifest cache，避开全局只读缓存。
NOT RUN：Release 全量／完整 verify.sh、安装、真实设备效果和真实清空；没有执行安装或清空。真实 iCloud 行的容量与同步行为按下文步骤只读实测，确认框取消，不执行清空。

| 测试类 | 通过 | 环境失败用例 | 既有 opt-in 跳过 |
| --- | ---: | ---: | ---: |
| CareStudioRenderReviewTests | 8 | 0 | 0 |
| CleanupRuleScannerTests | 41 | 3 | 2 |
| CleanupRuleTableTests | 2 | 0 | 0 |
| CleanupScopeD192Tests | 4 | 0 | 0 |
| CleanupStoreFollowUpTests | 7 | 27 | 0 |
| CleanupTrashDeletionTests | 5 | 0 | 0 |
| FeatureLightfieldResultSpaceTests | 3 | 10 | 0 |
| ICloudDriveTrashTests | 8 | 0 | 0 |
| PermanentDeletionInvariantTests | 4 | 0 | 0 |
| ProtectedLocationLayersTests | 4 | 2 | 0 |
| SafeCleanupLayoutTests | 0 | 21 | 0 |
| SafeCleanupScopeCardLayoutTests | 3 | 0 | 0 |
| ScanAccessReturnTests | 5 | 8 | 0 |
| ScanCoverageLimitsTests | 6 | 0 | 0 |
| SmartCareTests | 12 | 3 | 0 |
| SmartScanScopeTests | 6 | 21 | 0 |
| UIConsistencyRegressionTests | 46 | 0 | 0 |
| VolumeTrashTests | 9 | 0 | 0 |

所有日志和 JSON 证据位于 `.build/p03-junk-d192-evidence/`；精确命令与退出码的机器可读索引为 `commands.jsonl`。新增测试 15 个：CleanupScopeD192Tests 4、ICloudDriveTrashTests 8、ScanCoverageLimitsTests 1、SmartScanScopeTests 2；既有测试仅同步 D192 期望，已注明旧值。

实际验证命令如下（均从本工作目录运行；运行器设置 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`、`CLANG_MODULE_CACHE_PATH=$PWD/.build/codex/clang-module-cache`）。早期失败已分别修复旧枚举引用、受保护根例外、临时目录祖先链接夹具与旧分组期望，保留原始日志供复核；不把它们计为最终通过。

```sh
# deletion-inventory: exit 0; log .build/p03-junk-d192-evidence/deletion-inventory.log
python3 -B script/check_deletion_process_inventory.py

# display-inventory: exit 0; log .build/p03-junk-d192-evidence/display-inventory.log
python3 -B script/display_bound_tests.py --check

# build-1: exit 1; log .build/p03-junk-d192-evidence/build-1.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution

# build-2: exit 0; log .build/p03-junk-d192-evidence/build-2.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# rule-table-record: exit 1; log .build/p03-junk-d192-evidence/rule-table-record.log
env STORAGE_CLEANER_RECORD_RULE_TABLE=1 nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.CleanupRuleTableTests/'

# build-3: exit 0; log .build/p03-junk-d192-evidence/build-3.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# rule-table-record-2: exit 0; log .build/p03-junk-d192-evidence/rule-table-record-2.log
env STORAGE_CLEANER_RECORD_RULE_TABLE=1 nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.CleanupRuleTableTests/'

# core-1: exit 1; log .build/p03-junk-d192-evidence/core-1.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.(CleanupScopeD192Tests|ICloudDriveTrashTests|ScanCoverageLimitsTests|CleanupRuleTableTests)/'

# build-4: exit 0; log .build/p03-junk-d192-evidence/build-4.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# icloud-diagnostic: exit 1; log .build/p03-junk-d192-evidence/icloud-diagnostic.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.ICloudDriveTrashTests/testCloudOnlyAndLocalSizesAreMeasuredSeparatelyWithoutResourceQueries'

# build-5: exit 0; log .build/p03-junk-d192-evidence/build-5.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# core-2: exit 1; log .build/p03-junk-d192-evidence/core-2.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.(CleanupScopeD192Tests|ICloudDriveTrashTests|ScanCoverageLimitsTests|CleanupRuleTableTests)/'

# build-6: exit 0; log .build/p03-junk-d192-evidence/build-6.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# core-3: exit 0; log .build/p03-junk-d192-evidence/core-3.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.(CleanupScopeD192Tests|ICloudDriveTrashTests|ScanCoverageLimitsTests|CleanupRuleTableTests)/'

# build-mutation: exit 0; log .build/p03-junk-d192-evidence/build-mutation.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# confirmation-mutation-test: exit 1; log .build/p03-junk-d192-evidence/confirmation-mutation-test.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.ICloudDriveTrashTests/'

# build-final: exit 0; log .build/p03-junk-d192-evidence/build-final.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# deletion-final: exit 0; log .build/p03-junk-d192-evidence/deletion-final.log
python3 -B script/check_deletion_process_inventory.py

# display-final: exit 0; log .build/p03-junk-d192-evidence/display-final.log
python3 -B script/display_bound_tests.py --check

# targeted-final: exit 1; log .build/p03-junk-d192-evidence/targeted-final.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.(CleanupScopeD192Tests|ICloudDriveTrashTests|CleanupRuleScannerTests|FeatureLightfieldResultSpaceTests|SafeCleanupScopeCardLayoutTests|ScanCoverageLimitsTests|ScanAccessReturnTests|CleanupRuleTableTests|UIConsistencyRegressionTests|PermanentDeletionInvariantTests|SmartScanScopeTests|SafeCleanupLayoutTests|CleanupStoreFollowUpTests|VolumeTrashTests|CleanupTrashDeletionTests|CareStudioRenderReviewTests|SmartCareTests|ProtectedLocationLayersTests)/'

# build-final-2: exit 0; log .build/p03-junk-d192-evidence/build-final-2.log
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local

# targeted-final-2: exit 1; log .build/p03-junk-d192-evidence/targeted-final-2.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.(CleanupScopeD192Tests|ICloudDriveTrashTests|CleanupRuleScannerTests|FeatureLightfieldResultSpaceTests|SafeCleanupScopeCardLayoutTests|ScanCoverageLimitsTests|ScanAccessReturnTests|CleanupRuleTableTests|UIConsistencyRegressionTests|PermanentDeletionInvariantTests|SmartScanScopeTests|SafeCleanupLayoutTests|CleanupStoreFollowUpTests|VolumeTrashTests|CleanupTrashDeletionTests|CareStudioRenderReviewTests|SmartCareTests|ProtectedLocationLayersTests)/'

# display-final-2: exit 0; log .build/p03-junk-d192-evidence/display-final-2.log
python3 -B script/display_bound_tests.py --check

# headless-final: exit 0; log .build/p03-junk-d192-evidence/headless-final.log
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/shared-cache --config-path .build/codex/shared-config --security-path .build/codex/shared-security --manifest-cache local --filter '^StorageCleanerMacTests\.(CleanupScopeD192Tests|ICloudDriveTrashTests|ScanCoverageLimitsTests|CleanupRuleTableTests|PermanentDeletionInvariantTests|UIConsistencyRegressionTests|VolumeTrashTests|CleanupTrashDeletionTests|CareStudioRenderReviewTests)/'

# diff-check: exit 0; log .build/p03-junk-d192-evidence/diff-check.log
git diff --check -- Resources/CleanupRules.baseline.json Sources/StorageCleanerMac/Models/CleanupCoverageCatalog.swift Sources/StorageCleanerMac/Models/CleanupExecutionModels.swift Sources/StorageCleanerMac/Models/CleanupScanModels.swift Sources/StorageCleanerMac/Models/OperationConfirmationModels.swift Sources/StorageCleanerMac/Services/ReadOnlyCleanupScanner.swift Sources/StorageCleanerMac/Services/SafeCleanupExecutor.swift Sources/StorageCleanerMac/Stores/ScanStore.swift Sources/StorageCleanerMac/Views/CareStudio/CareJunkGrouping.swift Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkManager.swift Sources/StorageCleanerMac/Views/CareStudio/CareStudioTheme.swift Sources/StorageCleanerMac/Views/CleanupExecutionViews.swift Sources/StorageCleanerMac/Views/CleanupScanViews.swift Sources/StorageCleanerMac/Views/ContentView.swift Sources/StorageCleanerMac/Views/DesignSystem/FeatureLightfieldCleanupScopeRow.swift Tests/StorageCleanerMacTests/CareStudioRenderReviewTests.swift Tests/StorageCleanerMacTests/CleanupRuleScannerTests.swift Tests/StorageCleanerMacTests/FeatureLightfieldResultSpaceTests.swift Tests/StorageCleanerMacTests/SafeCleanupScopeCardLayoutTests.swift Tests/StorageCleanerMacTests/ScanAccessReturnTests.swift Tests/StorageCleanerMacTests/ScanCoverageLimitsTests.swift Tests/StorageCleanerMacTests/SmartScanScopeTests.swift docs/2.0.1/cleanup-rule-table.md script/deletion-process-inventory.txt Tests/StorageCleanerMacTests/CleanupScopeD192Tests.swift Tests/StorageCleanerMacTests/ICloudDriveTrashTests.swift docs/2.0.0/collab/handoffs/p03-junk-d192.md

```

## 安装后的主会话实测（不执行清空）

1. 打开“垃圾清理”起始页，核对系统垃圾、AI 垃圾、邮件附件、废纸篓四项默认全开；切换后退出再打开应用，核对状态保留。全关时扫描不可开始。
2. 全开执行只读扫描，核对系统垃圾含非 AI 开发者与待确认文件，AI、邮件、废纸篓分别成组；iCloud 行保持未选，菜单栏/小窗全局摘要不被专页结果更新（D68）。
3. 返回起始页关掉废纸篓，再开始新扫描，核对没有三类废纸篓行；在结果页改开关后重扫，核对仍沿用该次会话范围（A-R3）。
4. 再开废纸篓开始新扫描，核对 iCloud 云盘废纸篓独立行名和 `iCloud 中 … · 本机 …`。可与 Finder/只读统计对照逻辑和实占，观察没有文件下载；数值随同步变化，不把任务给定的 19.12/18.24 GB 当固定断言。
5. 手动勾选 iCloud 行进入确认，仅观察两个确认开关、所有设备永久删除警告、预计本机释放；分别只勾一项核对执行按钮不可用，然后取消。不要执行清空。
6. 对含符号链接或可选目录缺失的扫描查看经典列表标题；真正权限拒绝、超时或测量失败仍应提示部分结果。

## 完整逐规则对应表

共 89 条；AI 垃圾 / aiClutter 30 条，系统垃圾 / systemJunk 54 条，邮件附件 / mailAttachments 2 条，废纸篓 / trashBins 3 条。四项全开与 SmartCareModule.cleanupScopes 覆盖的规则 ID 集合完全相同，每条仅属一项（CleanupScopeD192Tests）。

| # | 规则 ID | 范围 |
| --- | --- | --- |
| 1 | `developer.codex-cache` | AI 垃圾 / aiClutter |
| 2 | `developer.codex-plugin-cache` | AI 垃圾 / aiClutter |
| 3 | `developer.codex-temporary-files` | AI 垃圾 / aiClutter |
| 4 | `developer.codex-logs` | AI 垃圾 / aiClutter |
| 5 | `developer.claude-code-cache` | AI 垃圾 / aiClutter |
| 6 | `developer.claude-code-plugin-cache` | AI 垃圾 / aiClutter |
| 7 | `developer.claude-code-temporary-files` | AI 垃圾 / aiClutter |
| 8 | `developer.claude-code-app-cache` | AI 垃圾 / aiClutter |
| 9 | `developer.claude-code-cli-cache` | AI 垃圾 / aiClutter |
| 10 | `developer.claude-code-logs` | AI 垃圾 / aiClutter |
| 11 | `developer.claude-code-telemetry` | AI 垃圾 / aiClutter |
| 12 | `developer.cursor-cache` | AI 垃圾 / aiClutter |
| 13 | `developer.cursor-app-cache` | AI 垃圾 / aiClutter |
| 14 | `developer.cursor-logs` | AI 垃圾 / aiClutter |
| 15 | `developer.github-copilot-cache` | AI 垃圾 / aiClutter |
| 16 | `developer.github-copilot-app-cache` | AI 垃圾 / aiClutter |
| 17 | `developer.github-copilot-logs` | AI 垃圾 / aiClutter |
| 18 | `developer.opencode-cache` | AI 垃圾 / aiClutter |
| 19 | `developer.opencode-logs` | AI 垃圾 / aiClutter |
| 20 | `developer.openclaw-cache` | AI 垃圾 / aiClutter |
| 21 | `developer.openclaw-temporary-files` | AI 垃圾 / aiClutter |
| 22 | `developer.openclaw-app-cache` | AI 垃圾 / aiClutter |
| 23 | `developer.openclaw-logs` | AI 垃圾 / aiClutter |
| 24 | `developer.openclaw-app-logs` | AI 垃圾 / aiClutter |
| 25 | `developer.workbuddy-logs` | AI 垃圾 / aiClutter |
| 26 | `developer.windsurf-logs` | AI 垃圾 / aiClutter |
| 27 | `developer.continue-index` | AI 垃圾 / aiClutter |
| 28 | `developer.claude-desktop-web-cache` | AI 垃圾 / aiClutter |
| 29 | `developer.codex-desktop-web-cache` | AI 垃圾 / aiClutter |
| 30 | `developer.vscode-web-cache` | 系统垃圾 / systemJunk |
| 31 | `developer.vscode-logs` | 系统垃圾 / systemJunk |
| 32 | `developer.lmstudio-web-cache` | AI 垃圾 / aiClutter |
| 33 | `developer.rod-browser-downloads` | 系统垃圾 / systemJunk |
| 34 | `browser-cache.google-chrome` | 系统垃圾 / systemJunk |
| 35 | `browser-cache.safari` | 系统垃圾 / systemJunk |
| 36 | `browser-cache.microsoft-edge` | 系统垃圾 / systemJunk |
| 37 | `browser-cache.brave` | 系统垃圾 / systemJunk |
| 38 | `browser-cache.firefox` | 系统垃圾 / systemJunk |
| 39 | `browser-cache.arc` | 系统垃圾 / systemJunk |
| 40 | `application-cache.whatsapp` | 系统垃圾 / systemJunk |
| 41 | `application-cache.codex` | 系统垃圾 / systemJunk |
| 42 | `application-cache.ego-lite` | 系统垃圾 / systemJunk |
| 43 | `application-cache.typeless-updater` | 系统垃圾 / systemJunk |
| 44 | `application-cache.zoom` | 系统垃圾 / systemJunk |
| 45 | `developer.playwright-mcp-cache` | 系统垃圾 / systemJunk |
| 46 | `developer.pip-cache` | 系统垃圾 / systemJunk |
| 47 | `developer.swiftpm-cache` | 系统垃圾 / systemJunk |
| 48 | `developer.clang-cache` | 系统垃圾 / systemJunk |
| 49 | `developer.bun-cache` | 系统垃圾 / systemJunk |
| 50 | `developer.go-build-cache` | 系统垃圾 / systemJunk |
| 51 | `developer.gopls-cache` | 系统垃圾 / systemJunk |
| 52 | `developer.golangci-lint-cache` | 系统垃圾 / systemJunk |
| 53 | `developer.playwright-browsers` | 系统垃圾 / systemJunk |
| 54 | `developer.pnpm-cache` | 系统垃圾 / systemJunk |
| 55 | `developer.yarn-cache` | 系统垃圾 / systemJunk |
| 56 | `developer.node-gyp-cache` | 系统垃圾 / systemJunk |
| 57 | `developer.typescript-cache` | 系统垃圾 / systemJunk |
| 58 | `developer.deno-cache` | 系统垃圾 / systemJunk |
| 59 | `developer.electron-cache` | 系统垃圾 / systemJunk |
| 60 | `developer.cypress-cache` | 系统垃圾 / systemJunk |
| 61 | `developer.poetry-cache` | 系统垃圾 / systemJunk |
| 62 | `developer.cocoapods-cache` | 系统垃圾 / systemJunk |
| 63 | `developer.carthage-cache` | 系统垃圾 / systemJunk |
| 64 | `developer.sccache-cache` | 系统垃圾 / systemJunk |
| 65 | `developer.flutter-cache` | 系统垃圾 / systemJunk |
| 66 | `system-log.diagnostics` | 系统垃圾 / systemJunk |
| 67 | `application-log.codex` | 系统垃圾 / systemJunk |
| 68 | `system-cache.cloudkit` | 系统垃圾 / systemJunk |
| 69 | `mail.downloaded-attachments` | 邮件附件 / mailAttachments |
| 70 | `mail.library-attachment-folders` | 邮件附件 / mailAttachments |
| 71 | `system.broken-preferences` | 系统垃圾 / systemJunk |
| 72 | `trash.user-trash` | 废纸篓 / trashBins |
| 73 | `trash.volume-trashes` | 废纸篓 / trashBins |
| 74 | `trash.icloud-drive` | 废纸篓 / trashBins |
| 75 | `developer.npx-cache` | 系统垃圾 / systemJunk |
| 76 | `developer.npm-content-cache` | 系统垃圾 / systemJunk |
| 77 | `developer.homebrew-cache` | 系统垃圾 / systemJunk |
| 78 | `developer.uv-cache` | 系统垃圾 / systemJunk |
| 79 | `developer.bun-install-cache` | 系统垃圾 / systemJunk |
| 80 | `developer.xcode-derived-data` | 系统垃圾 / systemJunk |
| 81 | `developer.xcode-ios-device-support` | 系统垃圾 / systemJunk |
| 82 | `developer.gradle-cache` | 系统垃圾 / systemJunk |
| 83 | `developer.cargo-registry-cache` | 系统垃圾 / systemJunk |
| 84 | `system.user-caches` | 系统垃圾 / systemJunk |
| 85 | `system.user-logs` | 系统垃圾 / systemJunk |
| 86 | `downloads.installers` | 系统垃圾 / systemJunk |
| 87 | `downloads.large-items` | 系统垃圾 / systemJunk |
| 88 | `user-data.istat-menus-setapp-history` | 系统垃圾 / systemJunk |
| 89 | `applications.duplicate-installed-apps` | 系统垃圾 / systemJunk |
