# r3-project-artifacts：限定文件夹的项目产物清理（D92）

基线 `bc5260c4d6df9f7d8ceb131e1a34aa475ba07717`，分支 `task/r3-project-artifacts`，worktree `/Users/developer/Developer/sc-worktrees/r3-project-artifacts`。起始工作区干净；沿用规则来源批次和最新集成。已先读批次 common/codex-build-common、RULES、规则来源交接、D5/D47/D48/D52/D55/D60/D82/D83/D84 与第三轮计划。BOARD 当前未找到本批独立条目。本轮 .git 只读，未暂存、提交或合并，交付 scratch `prepared/` 三组补丁。

## 变更与理由

- `ProjectArtifactModels.swift`：18 条清单→相对产物→重建说明的静态定义，含官方链接、revision/checkedAt。支持 npm、Cargo、Python（含三个清单变体）、SwiftPM、Gradle（含 Kotlin DSL）、Maven、Bundler、Composer、Dart/Flutter。Xcode/Go 不增加规则，保留已有系统缓存规则。npm dist/build 必须对应 build 脚本的输出名称或已知工具约定（Vite/tsup、react-scripts）；`.next` 要求 `next build`。不执行脚本，不把任意 build 脚本当作任意同名目录的再生证明。
- `ProjectArtifactScanner.swift`：只扫描显式传入的文件夹；生产保持原执行器的家目录范围，拒绝整个家目录和家目录之外。未选择任何位置不会扫描。后台可取消，发现遍历深度 12、100000 项、500 个项目、1500 个产物、60 秒上限；单个产物测量深度 32、100000 项、10 秒上限，Git 命令 2 秒上限。到上限/不可读时保守仅显示，不用于一键选择；不进入产物继续发现项目。Python 子目录里的缓存归到最近的清单项目。
- 清单读取只使用固定已知文件，且禁止链接/云占位，最大 1 MiB；Bundler 只读 `.bundle/config` 中 BUNDLE_PATH。`.env` 不读取。其余源码/配置仅读元数据计算项目最后修改时间，不读取内容，不列为产物。
- 虚拟环境必须包含普通非链接 `pyvenv.cfg`；Bundler 需要 BUNDLE_PATH 精确指向 `vendor/bundle`。产物自身或内部有链接、跨卷、云文件、`.git`、`.env*`、锁文件、凭据/用户数据库等保护标记时整行不可选。普通 dist/build/target 发现源码扩展名或 src/config 等目录也整行保护。依赖目录本身包含依赖的源码/配置，按清单再生模型识别；产物内自定义改动不能保证重建，确认页必须明确审阅。
- 使用只读 `git ls-files -z` 与 `git check-ignore -q`，由 Git 解析嵌套忽略、否定规则、全局忽略及 worktree；不自己实现简化 `.gitignore` 解析。先检查 tracked，再检查 ignored：tracked 禁选，未忽略/无法核验仅显示；非 Git 项目可手动选。关闭 fsmonitor 与可选锁，不执行 hooks 或构建工具。
- 大小复用现有文件系统 snapshot/aggregateSnapshot：安全检查使用完整元数据，测量使用逻辑字节/分配字节；按身份去重硬链接；同项目的多个生态指向同一产物目录时，由目录顺序中首条规则认领，避免重复行和重复计划。UI 区分本地占用、逻辑大小后备、已量到下限；不估算 APFS 克隆释放量。项目时间取源码/配置等非产物和已测量产物的最新元数据，近期重建的项目也不参加 N 天选择，未知时间不参加 N 天选择；N 默认 30，可调 1–3650。默认不预选，手动或 N 天选择都通过现有 CleanupSelection 记录显式选择。
- `ProjectArtifactView.swift`：通过开发工具页现有阈值控件增加独立面板入口（落地/结果页复用）；使用 AppOpenPanelCoordinator 与 FolderAccessGrantService，维持 scoped URL 到任务退出。扫描和清理共用 store 的 HeavyWorkCoordinator；CleanPlanBuilder、SafeCleanupExecutor、CleanupReportJournal.live 与操作记录沿用。确认列出对象/容量、逐项重建命令/来源、联网/本地改动影响、复查就绪/跳过、恢复方式。不能可靠核对所有 node/cargo/python/venv 进程，因此确认要求用户停止相关进程，不声称已检测其状态。关闭面板取消并等待任务释放授权，执行后旧结果不复用。
- `CleanupScanModels.swift` 只新增可选 `projectArtifact` 要求；D82 的通用规范化编码自动把清单、产物与重建条件纳入有效指纹。旧规则该字段 nil，原指纹不因添加可选属性改变。
- `SafeCleanupExecutor.swift` 17 行 D92 复查：preflight 和移动意图落盘后重新验证清单、Git tracked/ignore、venv、保护树以及最大修改时间/逻辑与分配字节；依据变化或有写入即跳过。项目产物使用此有界复查，不混用旧缓存时间读取的不同精度/遍历口径。计划和成功/错误回执沿用规则指纹与修订透传，恢复仍走统一操作记录。
- `Resources/ProjectArtifacts.baseline.json`：固定规范项目根的 18 条规则内容哈希，复用 D82 maintenance validator 检查改内容不增修订、修订回退与元数据。运行时每项目的完整动态规则另有指纹（不冒称存在一个恒定的全机项目规则指纹）。
- 新增 `ProjectArtifactTests` 24 项。共享夹具文件系统由 private 改 internal，复用已有沙箱祖先处理；夹具内链接检查保留，不改产品 PathSafety。没有删除断言或改写旧断言；UI 字号守卫发现问题后修产品代码为统一 TypeScale。

未改 `ScanStore.swift`、`Features/AppUpdates/**`、卸载、照片、云文件功能、浏览器隐私、菜单栏、更新源、原清理规则 JSON 或原 D82 基线。D92 加在 DECISIONS 最上方；仅项目产物采用不预选，不改变 D47/D52 已有缓存/日志策略。

## 实际验证

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，`LC_ALL=en_US.UTF-8`。日志均在 `/Users/developer/Developer/.sc-build/r3-project-artifacts/logs/`。

| 检查 | 结果与证据 |
|---|---|
| Debug 带测试构建 | PASS，exit 0；最终 `build-final.log`，50.49 秒 |
| 最终 ProjectArtifactTests + UIConsistencyRegressionTests | PASS，exit 0；70 项，0 失败、0 跳过；`project-ui-final.log`（24 + 46） |
| 其余五类定向（见下） | 命令 exit 1；83 项中 70 PASS、12 未通过、1 原有 opt-in 跳过。主会话须在沙箱外复跑，不是完整门禁通过 |
| CleanupWriteRecheckTests | 8 项，7 PASS、1 原有 opt-in 跳过；`regression-tests.log` |
| CleanupExecutionSafetyTests | 37 项，32 PASS、5 未通过（家目录回执/恢复夹具；其中一项还报告 ENOENT 收尾异常） |
| CleanupJournalEventTests | 5 项，1 PASS、4 BLOCKED：家目录夹具创建 EPERM |
| CleanupRuleProvenanceTests | 12 项，11 PASS、1 BLOCKED：家目录夹具创建 EPERM；原规则迁移与指纹检查通过 |
| TestPreferenceHygieneTests | 21 项，19 PASS、2 BLOCKED：临时偏好域 sandbox extension EPERM；源码偏好卫生守卫通过 |
| git diff --check | PASS，exit 0 |
| private API 守卫 | PASS，exit 0，7 allowlisted uses；未增加私有 API |
| 分组补丁、哈希、mutation before 唯一性 | PASS，见 prepared/static-checks.json；24 条 mutations，只准备，未执行反证 |
| Release/完整 verify/变异反证/签名安装/实机验收/提交/合并 | NOT RUN；由主会话负责 |
| JEV | BLOCKED：调用 jev_decide 被工具“requires approval, approval policy is never”拒绝，未取得判断；没有宣称调用成功 |

首轮新测试出现沙箱祖先链接判定失败，复用既有夹具注入后解决。复跑发现 `/var`/`/private/var` 相对路径与旧缓存精度混用问题，在根因处修复，未放宽路径边界。原 `regression-tests.log` 的 129 项包含 UI 字号失败，已修复并用最终 46 项 UI 复跑证明；其余受限用例未重跑或删除，最终仍列为未通过。

沙箱外须复跑的具体用例：

- CleanupExecutionSafetyTests：testJournalReloadRetainsIdentityAndRejectsChangedIntent（日志为家目录夹具及 ENOENT 收尾，原因须由主会话确认）、testNewStoreReconnectsOnlyLatestRestorableVerifiedDuplicateReport、testPersistedDuplicateCleanupRecoveryFailsClosedForCorruptOrConsumedReports、testProductionQuarantineMoveAndIdentityCheckedRestoreUseOnlyTemporaryFixture、testRecoveryRejectsReplacementAtQuarantineReceiptPath。
- CleanupJournalEventTests：testAppendDoesNotRewriteBaseAndConfirmedResultsCannotBeErased、testApplicationRestoreRequiresOriginalScopeAndIdentityNotVersionString、testSummaryPaginationRetainsEveryReportAndBoundsEachPage、testTornTailRetainsSuccessfulReceiptsAndRefusesFurtherWrites。
- CleanupRuleProvenanceTests.testJournalEventsPreserveAndRefuseChangesToProvenance。
- TestPreferenceHygieneTests：testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory、testTemporarySuiteCanBeReopenedOnAWorkerThread。

本批测试只扫隔离临时目录。执行相关的新测试使用拒绝移动的注入 mover、内存回执（或在夹具内写保护标记模拟意图），从不移动真实文件，也不落盘真实回执；既有真实回执/恢复测试保持家目录操作夹具，不迁移到 temp、不放宽路径安全。失败夹具的所有权与清理问题由主会话根据日志处理，不自动删除未知家目录对象。

## 主会话命令、红/绿与反证

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r3-project-artifacts/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3)
swift build "${F[@]}" --build-tests
FILTER=$(paste -sd '|' ~/Developer/.sc-build/r3-project-artifacts/targeted-classes.txt)
swift test "${F[@]}" --skip-build --filter "$FILTER"
# 完整门禁只由主会话在集成分支运行：
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=~/Developer/.sc-build/r3-project-artifacts/verify-root script/verify.sh
```

`mutations.json` schema 严格为 mutations 数组，每项 id/path/before/after/expected_occurrences/filter；24 项 before 均逐字唯一。覆盖清单/build 脚本、venv、Bundler、ignore/tracked、锁/源码、链接/跨卷/云路径、默认不选、N 天、指纹/修订/日期、项目/测量上限、取消转发、执行前与最终移动前复查。

- 红：主会话在独立反证 worktree，逐条替换指定 before→after（每次检查恰好一次），编译后运行该 filter，目标行为断言应失败；编译失败、超时或环境 EPERM不能算“已杀死”变异。
- 绿：撤销每条变异后重新跑同一 filter；最终新类 24 项及 UI 46 项已在本轮 PASS。不要混入真实项目作为扫描夹具。
- 反证：每个变异单独恢复基线，保存 diff、命令、exit code 和失败断言；汇总 killed/survived/blocked。当前没有运行变异，不能据 mutations 文件声称安全边界反证通过。
- 源码与锁文件：夹具根中的真实源码/配置/锁文件不会成为产物行；在产物中加保护标记后整行禁选；preflight 后/移动意图期间添加 `.git` 的测试证明不能沿用旧批准。
- 源码复核：确认 ScanStore 与禁止目录 diff 为空，旧规则 D82 指纹迁移测试通过；最终补丁 reverse apply --check 与每个文件哈希一致。

## 实机验收（用户自建测试项目）

由主会话安装经完整门禁批准的 Beta 后执行；本批未安装或启动 App。用户自建一个专用于验收的家目录内文件夹，所有项目/源码/锁文件均为可丢弃测试样本，不用真实工作项目：

1. 开发工具与产物 → 项目产物 → 选择该验收文件夹。核对选定范围、未自动扫描家目录、未选择任何产物；项目最后修改/容量与 Finder 及已知样本对照。
2. 建 npm/package.json + node_modules + dist/build/.next；逐次移除/补齐对应 build 脚本，核对输出识别。建 Python 清单 + .venv，缺 pyvenv.cfg 时应仅显示；补齐后再扫。补 Cargo、SwiftPM、Gradle、Maven、Bundler、Composer、Dart 的小型产物样本；Go/Xcode 不产生本批新规则。
3. 在测试 Git 仓库里先不忽略 target → 仅显示；加入 .gitignore → 可手动选但不预选；git add -f 跟踪一个产物文件 → 禁选。测试忽略否定规则和嵌套仓库。锁文件、源码、.env 和 .git 本身不得成为候选。
4. 只在测试样本中建立链接、嵌套 .git/用户数据保护标记。跨卷、CloudStorage/iCloud 使用一个单独无业务数据的位置检查只显示/不遍历，不触发占位下载或同步删除；无法安全提供此样本则记录 NOT RUN，不搬入真实云项目补测。
5. 调整 N=30/60 并使用已知修改时间的样本，核对只选择符合条件的完整项目；新写源码后重扫应从一键选择中移除。扩大测试树后取消，界面应响应并禁止旧结果继续执行。
6. 手动选择普通可重建样本，进入确认页，核对逐项命令、动作=移到废纸篓、数量/容量、就绪/跳过、进程停止提醒与恢复路径。确认前修改清单、取消忽略或添加 .git，核对重新扫描/跳过；通过测试注入验证“意图后”场景，不在真实目录制造竞态。
7. 用户明确点击确认，仅移动自建样本产物；源码/配置/锁文件应原样保留。操作记录中核对规则 ID/修订与指纹、移入废纸篓字节和实际释放量的区分；从统一操作记录恢复，再由用户执行原项目重建命令，独立记录重建结果。

限制：目录名称/清单/忽略状态是再生性证据，不能证明产物里的所有自定义改动都可自动重建；面板明确要求审阅。进程检测尚不能可靠覆盖 CLI 工作目录/venv，所以不声称无相关进程。任何单次阻塞文件系统调用只能在返回后响应取消/时间上限；所有此类 I/O 在后台，不能据单元测试宣称离线卷/极端负载下实机性能已验收。

## 修复轮 1（2026-10-13）

本节取代上文首轮交付中有关“所有内部链接禁选”“全局扫描 limited 连坐所有行”“build token 可作输出证据”及旧测试/变异数量的描述；首轮原始记录保留供追溯。开始先核对 git status：继承 5 个已修改文件和 6 个未跟踪文件，未丢弃上一会话实现。读取任务卡、完整独立复核、四个复现探针及协同规则后修改。本轮仍不暂存、不提交、不 push、不安装或运行应用，只扫描隔离测试夹具。

### 逐项处理

| 复核项 | 修复与正式测试 |
|---|---|
| P1-1 build 子命令误作目录证据 | 移除任意目录 token 判定。明确输出参数必须包含目录值；已知工具配置只接受保守的静态字面量输出属性，不执行 JS 或构建脚本。无配置时 Vite/Next/react-scripts 还须匹配 index.html＋assets、BUILD_ID＋server、index.html＋static 等实际产物结构。存在不明确/覆盖默认值的配置时不猜默认目录。手工 icns/plist、build 根脚本及 src/config/源码区仍保护。`testBuildSubcommandsDoNotConfirmHandMaintainedResources` 将原 electron 探针改为禁止成行，覆盖 vite/ng/electron-vite/gulp/nx；`testNodeOutputRequiresConfigOrDefaultProductSignature` 区分默认形态、显式配置和注释假证据。原 `.next` 测试补 BUILD_ID/server 真实形态后保留三行断言。 |
| P1-2 安装载荷被当项目 | 扫描根和 requirements 均核对祖先组件与自定义 venv 的 pyvenv.cfg。排除 node_modules、site/dist-packages、编辑器 extensions、.cargo/registry、.npm 及产物容器内部；扫描范围警告说明未遍历。`testInstalledPayloadRootsAndAncestorsAreNeverProjects` 把原包载荷探针改为零行断言，覆盖选 node_modules 根、依赖包、大小写变体、扩展、custom-env 及嵌套依赖不独立成项。 |
| P1-3 真实产物不可用 | 内部链接仅看保存的目标词法路径，不跟随；在产物内允许，venv bin/python* 到已知系统/Homebrew/Python.framework 解释器位置是有限例外。产物根链接和其他外部链接仍仅显示。内部链接使用 aggregateSnapshot 的 lstat 元数据，不查询目标元数据。已确认的依赖目录内证书、数据库、依赖锁文件与源码不套用项目源码保护；.git/.env/凭据风险标记连链接形态也继续阻止整行。target 生成源码、dist .d.ts 允许，src/config 标记保留。`testRealisticDependencyAndGeneratedArtifactShapesAreSelectable` 将 venv 探针改写并扩为五类真实形态：node_modules/.bin、venv 的 bin/python＋cacert.pem、.build 的 manifest.db＋debug 链接、target 生成 .rs、dist .d.ts；每类同时验证可选、preflight 就绪与追加外部链接后禁选。`testInternalProtectedLinksStayReadOnly` 锁定 .git/.env 内部链接仍保护。`testArtifactLimitDoesNotBlockOtherRows` 和 `testDiscoveryLimitOnlyRemovesAffectedProjectActivityEvidence` 证明局部上限不连坐其他行；发现不完整只使相关项目活动时间未知。所有原上限数值保持不变。 |
| P2-1 monorepo 活动 | 嵌套子项目最新时间向包含它的每个项目回传；不依赖 workspaces 字段。`testMonorepoActivityPreventsRootInactiveSelection` 将原探针改为当天修改子包后，根 node_modules 不进入 N 天选择。 |
| P2-2 Git HOME/无 CLT | Git 使用实际用户 HOME，保留 GIT_CONFIG_NOSYSTEM、禁止 fsmonitor/可选锁。先检查 CLT 或有界 xcode-select -p，再调用 git；无工具链返回 unknown、不调用 git shim。测试可注入仅该调用的配置 home，不改进程 HOME。`testGitGlobalExcludesAndUnavailableToolchain` 验证 ~/.global-ignore 生效以及明确无工具链时 unknown。 |
| P2-3 锁文件重建条件 | 各生态检查适用锁文件存在性；每行及确认页展示锁证据，无锁仍可审阅选择，但提示“重建可能取不同版本；清单外本地安装不能保证恢复”。lockEvidence 参与动态规则有效指纹，preflight/最终复查重读并比对。`testLockEvidenceIsVisibleAndChangesFingerprint` 与 `testPreflightRejectsChangedLockEvidence` 覆盖提示、可选、指纹变化与 rulesChanged。不读取锁内容、不声称版本或本地修改可完全恢复。静态目录 catalog 的可选字段为 nil，18 条 D82 基线保持有效。 |
| P2-4 Python 最近仓库 | Git -C 改用产物父目录，Git 自己解析最近仓库，保留清单归属外层 Python 项目。`testInheritedPythonCacheUsesNearestRepository` 验证外层 ignored、内层 tracked 时仍不可选且原因为 tracked。 |
| P2-5 旧云路径 | 补 Dropbox、Google Drive、OneDrive（名称比较不区分大小写），保持 CloudStorage/Mobile Documents/iCloud 和文件系统云标记保护。现有云路径识别帮助函数只覆盖存储图 Desktop/Documents，与本模型用途不同，因此本模型补名称、不更改云文件模块。`testLegacyCloudRootsAndCaseInsensitiveDiscovery` 与 `testCloudMetadataAndGitUnknownAreReadOnly` 验证旧路径无遍历以及云元数据仅显示。 |
| P2-6 发现名称大小写 | 发现阶段统一 lowercased 处理 .git/.env 和产物容器。大小写变体夹具验证零行，且不因进入安装容器而产生范围警告；无需依赖宿主卷是否区分大小写。 |
| P2-7 测试/变异区分度 | 原 cross-volume 断言强化为精确“跨卷目录，仅显示”，区别根与内部守卫；新增 maximumProjects=1、两个项目时只能有一行/一个项目的边界断言。preflight 五种变更明确断言跳过原因：manifest/tracked/保护标记/venv → rulesChanged，产物写入 → candidateBecameActive，同时 failure 必须 nil。新增遍历中途及 Git 进程等待期间取消；发现元数据错误吞掉取消的问题，在返回前补取消检查。去重、Git unknown、云元数据、执行前 mtime/逻辑/分配大小等关键守卫补入 mutations。共享夹具及新增测试辅助均位于 Debug/Release 共用范围。 |

### 实际验证与反证

使用用户指定 Xcode/LC_ALL、jobs=3、专属 scratch 和全部 SwiftPM 参数。最终基线构建与测试是在撤销两条变异后重新运行；最终源文件 SHA-256 与反证记录中的 baseline_sha256 一致。新类共 41 项（首轮 24＋本轮新增 17）；四个复核探针已改写进正式测试，不把复核中“确认错误行为存在”的断言原样复制。

| 检查 | 结果与日志（scratch/logs/） |
|---|---|
| 最终 Debug --build-tests | PASS，exit 0，`fix1-build-final.log` |
| 最终 ProjectArtifactTests＋UIConsistencyRegressionTests | PASS，exit 0；41＋46＝87 项，0 失败、0 跳过；`fix1-project-ui-final.log`。五类真实产物也通过 preflight 就绪断言。 |
| targeted-classes.txt 全部七类 | 命令 exit 1；170 项，157 PASS、12 个用例未通过、1 原有 opt-in 跳过。XCTest 总计报告 13 条失败（Preference 第一个用例有两条断言）；`fix1-targeted-final.log`、逐用例 `fix1-targeted-results.json`。未通过的仍是上文列出的家目录/偏好夹具沙箱限制，未放宽阈值、迁移操作夹具、删除断言或新增跳过。 |
| cross-volume 反证 | KILLED：单独替换原条目，编译 exit 0、定向测试 exit 1；根守卫失效后实际原因变成“产物包含跨卷目录，仅显示”，精确原因断言失败。`fix1-mutation-cross-volume-{build,test}.log`。 |
| project-limit 反证 | KILLED：单独把 `<` 改为 `<=`，编译 exit 0、测试 exit 1；产生两个项目/两行，数量断言失败。`fix1-mutation-project-limit-{build,test}.log`。 |
| 变异汇总 | `fix1-mutation-results.json` 记录两个单独变异的命令/退出码/源哈希与恢复状态；不以编译失败、超时或 EPERM 算 killed。其余 40 条 NOT RUN。 |
| 私有 API、diff、补丁和哈希 | PASS：`fix1-private-api.log`（7 allowlisted uses）；git diff --check、三组/all.patch reverse apply --check、42 条 before 在各目标文件恰好一次，及完整 manifest 哈希见 prepared/static-checks.json。 |
| JEV | BLOCKED：工具 schema 未提供模型参数，调用被“requires approval, approval policy is never”拒绝，未取得模型/判断结果；不声称 JEV 复核通过。 |
| 全量 verify、Release、安装、App/实机验收、提交/合并 | NOT RUN；遵守本轮授权范围。 |

`mutations.json` 保留全部原 24 条（没有删除曾存活项），现为 42 条。新增覆盖 P1 的输出证据/安装载荷/内部链接许可与外部链接保护/真实依赖内容、局部 limited、子项目活动、最近仓库、HOME/工具链、unknown fail-closed、云元数据、去重、写入快照、锁证据、.git 发现跳过及遍历中途取消。每个 before 在指定文件逐字唯一，filter 指向正式测试；cross-volume 保留原变异，project-limit 保留原 `<`→`<=` 并改用明确边界测试。剩余 40 条仍须由主会话独立反证，不据静态检查声称全部 killed。

首轮本轮内的临时失败记录保留：`fix1-project-first.log` 的 venv URL 尾斜杠比较失败已改为规范化路径；`fix1-project-second.log` 的中途取消被吞已补返回前检查。最终 41 项均通过，未删相关断言。原有测试改动仅强化 cross-volume、preflight 的区分度，以及为 `.next` 补正式产物形态，依据本轮用户要求与 D92 修订。

### 交付与残余

已更新 D92 的“修复轮 1”细化说明，重新生成 prepared 的 01-code、02-tests、03-docs、all.patch、manifest/static-checks 和提交辅助脚本；现有 11 个交付文件全部纳入哈希。提交脚本仅交付，未执行；补丁已在本工作区实现，不要再次正向 apply。保持基线 bc5260c4d6df9f7d8ceb131e1a34aa475ba07717 与 task/r3-project-artifacts，不改 ScanStore 或禁止模块。

残余：静态输出配置解析刻意保守，只支持小型可确认字面量；含注释、导入、条件或动态值等配置不会被执行或猜测，可能不列出输出目录。自定义/未知 venv 外部解释器位置仍仅显示。达到产物测量上限的该行仍不可选，不以未查完的保护树允许移动；其他已确认行不受影响。目录形态、忽略状态和锁文件存在性不能证明所有本地改动可重建，确认页保持审阅与停止进程提醒。家目录/偏好沙箱失败仍需主会话在沙箱外复跑；剩余变异、完整门禁及实机验收沿用上文步骤，均未完成。本轮未触及真实用户项目或数据。

## 修复轮 2（2026-10-13）

本轮基线 HEAD `90753952`（修复轮 1 已提交并合入后再合并集成），开始 `git status --short` 为空；已按要求读 `review-claude.md` 的“复核轮 2”与 `logs/review2-probe-ReviewRound2Tests.swift`。仅修改扫描器、项目产物测试、D92 与本交接；不修改 ScanStore。未提交、暂存、push、安装、运行应用或扫描真实用户项目。本轮 prepared 以该 HEAD 为基线，只交付本轮增量；不能混用首轮 bc5260c4 补丁或提交脚本。

### 三项 P2 处理

| 问题 | 实现与正式回归 |
|---|---|
| P2-A 祖先目录名误排除 | 不再把所有 artifactContainerNames 作为已安装证据。node_modules/site-packages/dist-packages、npm/Cargo 安装缓存、编辑器扩展继续排除；venv 根要有普通 pyvenv.cfg；vendor 要有 Composer 安装记录，vendor/bundle 要有 Bundler 标记。普通 build/target/dist/vendor/bundle/.build/venv 祖先不影响发现；确认的产物内部仍跳过。探针 D 改写为 `testProjectUnderGenericArtifactAncestorIsScanned`，同时验证直接选择项目、父目录、上层范围；`testInstalledVendorRequiresInstallationEvidence` 验证加标记前可发现、加标记后排除，单有 .bundle/config 不算安装。去掉名称跳过后发现既有 /var 与 /private/var 路径别名会绕过 artifactPaths 比较，复用 lexicalPath 在记录与比较两端修复，原嵌套缓存不发现内部项目测试通过。 |
| P2-B venv 解释器白名单 | pyvenv.cfg 解析唯一绝对、非根目录的 home；配置缺失/不可读/链接/无法解析仍仅显示。仅 bin/python* 外部链接是解释器例外；目标原名与解析后的名称需匹配 Python 解释器，解析路径需在 home 的规范路径内。不运行解释器，不扫描外部工具链内容。探针 C 改写为 `testVenvInterpreterUsesConfiguredHomeAcrossToolchains`：Xcode、Homebrew opt、pyenv、uv 全部在本测试临时根伪造，覆盖 home 别名规范化、缺键/相对路径/根路径/重复键、错误 home 与 sh 目标。原真实形态 venv 夹具也改成临时工具链和有效 home，无真实 /usr/bin 依赖。 |
| P2-C 非 Git 证据不足 | assess 在原 Git 与路径守卫后增加工具生成标记检查；无标记给出“非 Git 项目缺少工具生成标记，无法确认可再生产物，仅显示”。探针 A 改写为 `testNonGitHandwrittenArtifactsRequireGeneratedMarkers`：node_modules 手写笔记/数据库/依赖锁、target 手写 rs、.build 手写 Swift 无标记均禁选；补对应工具标记后可选；Git 未忽略仍禁选，Git 已忽略无标记沿用原规则。`testAlternativeGeneratedMarkersAndBytecodeOnlyCache` 验证 Yarn/pnpm/SwiftPM/Composer/Dart 标记、链接标记禁选与 __pycache__ 仅普通 .pyc；`testNonGitMarkerRemovalIsRejectedAtPreflight` 断言扫描后删除标记明确跳过 rulesChanged。 |

生成标记的完整适用表见 D92“修复轮 2”。普通 build/dist、Maven target、.gradle 没有可靠通用生成标记时，非 Git 项目仍成行但不可选；Git 项目继续按原规则。标记只证明工具生成形态，不保证恢复用户放进依赖目录的本地自定义内容。原 .git/.env、凭据、源码/配置、跨卷、云文件、外部链接、上限与取消保护均保留。Bundler 标记目录先核对本地非链接目录再枚举。执行器复用现有 assess 复查，无需改 ScanStore 或 SafeCleanupExecutor。

### 夹具与验证

项目产物测试从 41 增到 **47 项（新增 6 项）**，包含上述三条复核探针改写。既有可选夹具补真实工具生成标记；需要可选的通用输出夹具明确使用隔离 Git 仓库和忽略规则。源码保护测试加具体保护原因断言，测量上限测试加具体上限原因断言，防止新标记门槛遮蔽这些原有守卫。mtime 夹具也包含新标记，未放宽天数或上限。所有新扫描/链接/工具链对象只在 TestFileSystem.makeHome 所有权临时根内生成，旧家目录回执夹具保持原样，不改进程 HOME。

命令环境仍为 `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8`；共同参数为 `--scratch-path /Users/developer/Developer/.sc-build/r3-project-artifacts/debug --disable-sandbox -Xswiftc -disable-sandbox --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3`。

| 检查 | 状态与证据（日志根 /Users/developer/Developer/.sc-build/r3-project-artifacts/logs） |
|---|---|
| `swift build <共同参数> --build-tests` | PASS，exit 0；`fix2-build-final.log`。 |
| `swift test <共同参数> --skip-build --filter 'ProjectArtifactTests\|UIConsistencyRegressionTests'` | PASS，exit 0；最终 **93 项（47 + 46），0 失败，0 跳过**，`fix2-project-ui-final.log`。 |
| 七类定向（targeted-classes.txt，filter 用竖线连接） | 命令 exit 1，PARTIAL_SANDBOX；176 项：163 PASS、12 个受限用例未通过、1 既有 opt-in 跳过；XCTest 为 13 条失败报告。项目产物 47 项和 UI 46 项通过；12 个受限用例与修复轮 1 清单一致（5 执行安全、4 JournalEvent、1 provenance、2 preference）。家目录夹具创建 EPERM 和偏好域访问限制见 `fix2-targeted-final.log`，机器清单见 `fix2-targeted-results.json`。七类检查后补强了两项项目测试断言，并将 Bundler 安装证据收紧为实际 specifications/*.gemspec（单有配置不算安装）；已用最终 93 项重新验证受影响路径，未重复受限用例。 |
| 私有 API 守卫 | PASS，exit 0；`fix2-private-api.log`，7 allowlisted uses。 |
| `git diff --check`、禁止路径 diff、prepared 分组/all.patch reverse apply check 与哈希 | PASS；见重新生成的 `prepared/static-checks.json` 与 `manifest.json`。 |
| mutation 静态检查 | PASS；`mutations.json` 从 42 增至 **47 条**，每条 before 在目标文件逐字恰好一次。更新了三个因源码形态变化而失配的旧 before；每个 P2 至少一条新增，B/C 各两条。 |
| mutation 实际反证 | 本轮 NOT RUN；新增 5 条与其余当前基线反证由主会话队列执行。修复轮 1 两条 killed 仅为历史证据，不冒称当前基线再次反证通过。 |
| 完整 verify、Release、严格并发、签名/安装、实机、提交、push | NOT RUN；本轮只做上述构建/定向检查与交付准备。 |
| JEV | BLOCKED；实际尝试 jev_review，工具返回 `MCP tool call requires approval, but approval policy is never`。已核对工具 schema，无可指定模型标识或模型参数；未取得 JEV 结果，人工 diff 与正式测试不冒称 JEV 判断。 |

最终交付 `prepared/01-code.patch`、`02-tests.patch`、`03-docs.patch`、`all.patch` 和新 manifest/static-checks；旧 prepared 已保留到 `logs/fix1-prepared-snapshot/`。三组仅含当前 HEAD 之后的四个修改文件，提交辅助脚本只准备未执行。当前唯一未通过验证仍是上述沙箱用例；完整门禁、mutation 与实机状态保持分开。
