# 批次 r2-live-fixes-1：实机测试发现的缺陷（第一批）

- 分支 `task/r2-live-fixes-1`，基于集成分支 `c05b530`；worktree `~/Developer/sc-worktrees/r2-live-fixes-1`；scratch `~/Developer/.sc-build/r2-live-fixes-1/`（`debug/`、`strict/`，日志在 `logs/`）。依赖从 `integration/debug` 只读复制（checkouts、repositories、artifacts、workspace-state.json 改写路径）。
- 实现：Claude 子代理（Claude Opus 5.5）。来源：2026-10-06 实机测试（测试版构建 20261006111920）。
- 提交：`7773f56`（第 1 项）、`a3cf164`（第 2 项）、`6230c68`（第 3 项）、`639e77f`（交接）；复核后（第 7 节）：`d01de24`（P2-1、P2-2）、`77dea27`（P2-3 注释）、`b76a6d9`（P2-4）、本交接更新提交。
- 复核（主会话，2026-10-07）：可以合并，无 P0／P1；P2-1～P2-4 已按第 7 节处理，P2-5 留作后续（第 6 节）。
- 修改了 `Stores/ScanStore.swift`（第 1 项，`dismissV2CleanupReport` 附近约 40 行）：合并时注意 RULES“同一时间只允许一个批次修改 ScanStore.swift”。

## 结论

| # | 缺陷 | 结果 |
|---|---|---|
| 1 | 清理完成后点“完成”丢掉剩余结果 | 已修。还有可列出的行时“完成”回到同一次扫描的结果（已移走／删除的行不在，跳过／失败的行保留，选择清空，统计随之变化），没有剩余才回初始页；完成页另加“重新扫描”。核对中另发现：安全清理页、开发工具页点“完成”后列表虽回来，但“清理”按钮静默无效（扫描的展示令牌被清掉），同一处修复。 |
| 2 | 已安装应用签名身份被严格校验误判（Chrome） | 已修。根因只在 `codesign --verify --strict` 的 sideband 检查；身份读取器改为 codesign 默认校验＋`anchor apple generic` 要求。Security 框架的调用点不受 Finder 信息影响，全部保留。D42 已由用户确认（2026-10-07，集成分支 `d91cb2d`）；主会话已在真实 Chrome 上只读核对（2.2）。 |
| 3 | 内存说明文案与 D28 不一致 | 已改。等级＝系统给出（与活动监视器一致），百分比＝100% − 系统压力余量、仅作趋势；样本缺等级或余量时说明。中英同步，全仓同类句子已核对；复核后统一叫“系统压力余量”（P2-4）。 |

除上述三项外没有其他行为改动；没有安装、没有启动应用、没有截图、没有在真实应用或浏览器数据上操作。实机核对清单见第 5 节。

## 1. “完成”丢掉剩余结果

### 1.1 现象与根因

- 实机：智能扫描清理 4 项后，完成页“完成”回到“尚未扫描”，剩余 17 组需要重扫。
- 链路：完成页按钮 `(onDone ?? store.dismissV2CleanupReport)()`（`Views/CleanupExecutionViews.swift`）→ `ScanStore.dismissV2CleanupReport()` 清掉回执后调用 `resetSmartScanPresentation()` → `ScanPresentation.reset()`：状态 `.idle`、展示令牌 `sessionID = nil`。
  - 智能扫描页：`SmartScanFlowHost` 按状态切页，`.idle` 显示 `StartView`（落地页只看扫描历史），内存里已由 A2 刷新的 `cleanupScanSession`（`removingCleanedItems`）还在，但没有入口。
  - 安全清理页（`.green`）、开发工具页（`.devCaches`）：路由按页面而不是按状态，“完成”后 `cleanupWorkspace` 会再显示这次扫描的结果；但 `requestV2Cleanup` 需要 `scanPresentationSessionID`（`guard let presentationSessionID`），令牌已被清掉，点“清理”什么都不发生，也没有提示（`canRequestV2Cleanup` 不检查令牌，按钮是可点的）。这是同类问题里更隐蔽的一种。

### 1.2 修复（`7773f56`）

- `Models/ScanPresentationState.swift`：新增 `ScanPresentation.returnToResults(matching:)`，只有同一会话的终态（`.completed`、`.failed`、`.cancelled`）能回到 `.results`。没有把“终态 → results”加进 `canTransition` 转移表：否则其他调用 `transitionScanPresentation(to: .results)` 的地方（例如 `cancelV2CleanupConfirmation`）也能从终态离开结果页；专用方法只给“完成”用。
- `Stores/ScanStore.swift` `dismissV2CleanupReport()`：同时满足以下条件时回到结果，否则保持原行为（回初始页）。复核后条件收紧为“这次清理记下的回执与展示令牌”，见 7.1：
  - 被关闭的回执属于当前扫描（`report.sessionID == cleanupScanSession.id`）——卸载也会写 `lastCleanReport`，别的回执不能把扫描结果重新打开；
  - 当前扫描还有可列出的行（`isSelectable`，与结果页的列出口径一致）；
  - 展示令牌还在且处于终态（复核指出这里是拿当前令牌和自己比，已在 7.1 修正）。
  回到结果时：状态 `.results`（令牌不变）、`cleanupWorkflowState = .results(sessionID:)`、选择清空（清理完成时已清空，这里再保证一次）。
- “重新扫描”另行提供：完成页在“完成”左边加次要按钮“重新扫描”（`rescanAfterV2Cleanup()`）。完成页在所有页面上都会显示（`presentsV2CleanupPage` 与当前页面无关），而扫描范围按当前页面决定（`startCleanupV2Scan` 读 `selectedFilter`），所以先按这次扫描的范围选回对应页面（`scanRoute(of:)`：有 `includedRuleIDs` 为安全清理，有 `includedCategoryIDs` 为开发工具，否则智能扫描）再扫描。结果页页头原有的“重新扫描”不变。

### 1.3 其他完成页核对

| 页面 | “完成／关闭”做什么 | 之后的数据 | 是否同类 |
|---|---|---|---|
| 智能扫描、安全清理、开发工具的清理结果页（`SmartScanCleanupCompletedPage`，以及 `.completed` 无回执时的 `SmartScanTerminalPage`） | `dismissV2CleanupReport` | 本批修复 | 是，同一处修复 |
| `CleanupV2OperationOverlay` | `dismissV2CleanupReport` | 同上 | 无调用方（`UIConsistencyRegressionTests` 断言不被使用），行为随函数一起变化 |
| 卸载（`UninstallPreviewSheet`，“关闭”→ `cancelUninstall`） | 关闭预览表 | 已安装应用列表保留，已卸载的应用移出 | 否 |
| 重复文件（`duplicateCleanupReportPanel`，“关闭”→ `dismissVerifiedDuplicateCleanupReport`） | 只关报告条 | 重复文件列表保留，已移走的行标记为已移动 | 否 |
| 旧版移入废纸篓浮层（`CleanupOperationOverlay`，“完成”→ `dismissCleanupOperationSummary`） | 只关浮层 | 下面的页面不变 | 否 |
| 应用更新（`onDone: store.showAppUpdateScanSummary`） | 回到扫描摘要 | 保留 | 否 |
| 浏览器隐私（`BrowserPrivacyStore.finishProcessing`） | 没有完成页 | 只移除已核实删除的记录，其余保留 | 否 |

### 1.4 测试、红绿与反证

新增（`CleanupStoreFollowUpTests`，驱动真实夹具清理：临时 home、夹具废纸篓、隔离回执日志、假的运行中应用）：

| 测试 | 修复前 | 修复后 |
|---|---|---|
| `testDoneAfterACleanupReturnsToTheRemainingResults`：清理 1 行（另 1 行因应用运行被跳过）→“完成”：状态 `.results`、令牌不变、同一扫描、跳过的行在、统计为 1、选择为空；应用退出后剩余行可直接清理 | FAIL（`.idle`、令牌 nil、再清理超时） | PASS |
| `testDoneAfterCleaningEverythingReturnsToTheStartPage`：全部清理 →“完成”回初始页（对照） | PASS | PASS |
| `testDoneOnTheSafeCleanupPageKeepsTheRemainingRowsCleanable`：安全清理页扫描，清 1 行 →“完成”→ 再清剩余行并确认 | FAIL（再清理静默无效，超时） | PASS |
| `testScanAgainFromTheCleanupResultScansTheSameScope`：安全清理后切到别的页面，点“重新扫描”：回到安全清理页、第二次扫描的规则范围与第一次相同、回执清掉 | 新接口 | PASS |
| `testTheCleanupResultPageOffersScanAgainBesideDone`：完成页接线与 `scanRoute(of:)` 三种范围 | 新接口 | PASS |
| `ScanPresentationStateTests.testOnlyATerminalStateOfTheSameSessionReturnsToResults`：非终态、别的会话都不能返回；转移表仍拒绝终态 → results | 新接口 | PASS |

夹具改动：`scannedStore(route:)` 可从安全清理页扫描（按默认范围的规则生成会话）；`ScanRequestLog` 记录 `ScanStore` 发给扫描操作的请求。原有测试不变。

反证：临时去掉 `rescanAfterV2Cleanup` 里按会话选页面的两行，`testScanAgain…` 失败 3 处（停在 `.privacy`、第二次扫描变成全量智能扫描、规则范围为 nil），已还原（`item1-mutation-rescan.log`）。

布局：完成页多一个按钮后，`SafeCleanupLayoutTests.testCleanupExecutionAndTerminalPagesKeepActionsInTheViewport`（含 473×360、深浅色）与 `UIConsistencyRegressionTests` 全部通过（`item1-layout.log`）。

### 1.5 限制

- 在完成页点“恢复”后再点“完成”：恢复的行不会重新出现在结果里，要“重新扫描”才列出（结果会少列，不会多列或误删）。原因：会话没有按恢复结果重建；`ScanStore` 的恢复走 `CleanupRecoveryService.restore(report:coordinator:lease:)` 的默认真实日志与真实废纸篓（N8），无法在隔离夹具里测试。后续建议：清理时保留被移走的候选，恢复成功后放回会话（执行前检查仍会按身份复核）。

## 2. 已安装应用签名身份被 `--strict` 误判

### 2.1 现象与根因

- 实机：Google Chrome 的全部浏览记录只能“浏览器内处理”，原因“未能确认 Google Chrome 的安装位置和签名”（`.applicationNotVerified`）。主会话实测：`codesign -v --strict` 报 “resource fork, Finder information, or similar detritus not allowed”，非严格校验与 `spctl` 通过。
- 链路：`BrowserPrivacyRecordScanner`（扫描时）／`BrowserPrivacyHistoryProcessor`（写入前、恢复前）→ `BrowserPrivacyProviderDescriptor.productionWriteRoot` → `isValidInstalledBundle` 要求 Team ID、标识与 bundle ID 一致、DR → 身份来自 `StartupApplicationSigningIdentityReader`（`BrowserPrivacyApplicationLocator.discoverWithSigningIdentity`）→ 读取器先跑 `codesign --verify --strict --verbose=1`，失败即 nil。同一读取器还供登录项归属（`InstalledApplicationIndex.enrichingSigningIdentities`）和浏览器隐私的未知派生浏览器配置归属使用。
- `man codesign`：`--strict` = `symlinks`（包内符号链接必须指向包内已密封文件）＋`sideband`（不允许资源分叉、Finder 信息等附带数据），“这些检查并非在所有情况下都有意义，所以不是默认行为”。错误码 `errSecCSInvalidAssociatedFileData`（−66999）。
- 在 scratchpad 里用 Xcode 自带 FileMerge.app（Apple 签名、不在只读系统卷上；系统卷上的应用复制出来后因自定义省略规则本来就无法校验）的副本复现，记录在 `logs/item2-codesign-experiments.log`：

| 副本 | `--verify` | `--strict` | `--strict=symlinks` | `--strict=sideband` | `--no-strict` | `--verify -R '=anchor apple generic'` |
|---|---|---|---|---|---|---|
| 原样 | 0 | 0 | 0 | 0 | 0 | 0 |
| 包根与主可执行文件加 `com.apple.FinderInfo` | 0 | **1 detritus** | 0 | **1 detritus** | 0 | **0** |
| 已密封资源末尾加 1 字节 | 1 | 1 | 1 | 1 | 1 | 1 |
| 主可执行文件末尾加 1 字节 | 1（main executable failed strict validation） | 1 | 1 | 1 | **0** | 1 |
| 多一个未密封文件 | 1 | 1 | 1 | 1 | 1 | 1 |
| ad hoc 重签 | 0 | 0 | 0 | 0 | 0 | **3**（不满足要求） |
| Apple 自带 Instruments.app 的副本 | 0 | 1 | **1**（包内符号链接指向包外） | 1（No such file or directory，同一个悬空链接） | 未测 | 0 |

  另对 Xcode 里的 Instruments.app 原件做过一次只读 `codesign --verify --strict`，同样报包内符号链接指向包外（不是复制造成的）。除此之外没有在任何已安装应用上运行 codesign，没有碰 Chrome。

  结论：codesign 的默认校验已经包含严格结构校验（行为与错误码相当于 Security 框架的 `kSecCSStrictValidate`：`--no-strict` 才放过主可执行文件被追加数据），`--strict` 只多了 symlinks 与 sideband 两项，Chrome 栽在 sideband 上；symlinks 一项连 Apple 自己的 Instruments 也通不过。

- Security 框架（`SecStaticCodeCheckValidity`，每组标志用新的 `SecStaticCode`）：Finder 信息副本在默认、`kSecCSCheckAllArchitectures`、`kSecCSStrictValidate`、`kSecCSStrictValidate | kSecCSRestrictSymlinks` 下都是 0，只有加上 `kSecCSRestrictSidebandData` 才是 −66999；主可执行文件追加数据只有 `kSecCSStrictValidate` 能发现（默认标志为 0）；ad hoc 副本只有 `anchor apple generic` 要求能拒绝（−67050）。项目里没有任何调用点设置 `kSecCSRestrictSidebandData`。

### 2.2 修复（`a3cf164`）

`Features/StartupItems/Attribution/StartupApplicationSigningIdentityReader.swift`：校验参数由 `--verify --strict --verbose=1 <包>` 改为 `--verify --verbose=1 -R =anchor apple generic <包>`（`-R` 与 `=anchor apple generic` 为两个参数；`=` 前缀表示要求文本）。之后的 `--display --verbose=1 --requirements -` 与标识／Team ID／DR 解析、输出上限、超时、缓存都不变；退出码非 0（含要求不满足的 3）一律无身份。

- 仍校验：签名、全部密封文件、嵌套代码的封印、主可执行文件结构（codesign 默认的严格结构校验）。
- 新增要求：证书链由 Apple 签发（Developer ID、Mac App Store、Apple 自己）。旧读取器对 ad hoc 包（真实 codesign 实测，返回了标识）和自签名包（模拟）也给出身份，而自签证书可以在主体里写任意 Team ID（`CodeSignatureVerifier` 已有的前提，批次 4a）；现在这类包没有身份。
- 不再检查：sideband（Finder 信息、资源分叉）与 symlinks。
- 与以前相同的已知限制：不加 `--deep`，嵌套框架的可执行页不重新散列（用 Instruments 副本改嵌套框架二进制中间 1 字节，默认校验通过、`--deep` 才发现）；旧的 `--strict` 也不加 `--deep`。95 MB、含多个嵌套框架的 Instruments 副本校验 0.03 s（读取器每次调用超时 1 s）。
- 真实 Chrome 只读实测（主会话，2026-10-07，不是本子代理所测）：新参数校验 0.05 s、身份读取 0.01 s，都远低于 1 s 超时；`--strict` 只因 sideband 失败（symlinks 检查不影响 Chrome）；Finder 信息位于 `Contents/Frameworks/Google Chrome Framework.framework`。

### 2.3 逐个调用点结论

| 调用点 | 用途 | 校验方式 | 受 Finder 信息影响？ | 结论与理由 |
|---|---|---|---|---|
| `StartupApplicationSigningIdentityReader.swift`（原第 76 行） | 已安装应用身份：登录项归属、浏览器隐私判定浏览器真身与直接删除资格、未知派生浏览器配置归属 | `codesign --verify --strict` | **是**（根因） | **改**为默认校验＋`anchor apple generic`（2.2） |
| `Features/AppUpdates/Security/CodeSignatureVerifier.swift:50` `verifyCode` | 共用：下载的更新包替换校验（`BundleIdentityVerifier`）、更新安装器（`OfficialApplicationUpdateInstaller.swift:1256`）、官方源 DR 匹配（`OfficialSourceRegistry.swift:231`）、更新后复查（`WebsiteUpdateWorkflow.swift:33`）、自身重启身份（`ScanStore.swift:142`）、登录项可执行文件签名（`StartupSecurityInspection.swift:98`）、卸载归属与执行（`UninstallOwnershipVerifier.swift:27`、`UninstallExecution.swift:81`）、外置盘迁移复制校验（`ExternalDriveMigrationService.swift:451/490`）、风扇辅助程序（`LegacyFanControlHelperInstaller.swift:176`） | `kSecCSCheckAllArchitectures \| kSecCSStrictValidate` | 否（真实副本测试：Finder 信息副本校验通过、Team ID 经 Apple 锚定后可信） | **保留**。去掉 `kSecCSStrictValidate` 会放过主可执行文件被追加的数据；下载的更新包按任务要求保留严格校验 |
| `CodeSignatureVerifier.swift:95` `isAppleAnchored` | Team ID 是否可信 | `kSecCSStrictValidate`＋`anchor apple generic` | 否 | **保留** |
| `Features/AppUpdates/Scanning/ApplicationMetadataReader.swift:22` | 已安装应用元数据（更新源匹配、自动安装、更新后复查的 Team ID） | `kSecCSCheckAllArchitectures \| kSecCSStrictValidate` | 否（真实副本测试通过） | **保留** |
| `Services/UninstallOwnershipVerifier.swift:112` `hasAppleAnchor`、`:152` 容器元数据对隐式 DR | 卸载关联文件归属 | `kSecCSStrictValidate`（＋要求） | 否 | **保留** |
| `Services/AuthorizedApplicationMover.swift:199` | 本应用与自带特权辅助程序互相核对证书 | `kSecCSStrictValidate` | 否；且是自己的构建 | **保留** |
| `script/make_release_dmg.sh`、`notarize_release.sh`、`build_memory_fixture.sh` | 自己的发布包 | `codesign --verify --deep --strict` | — | **保留**（自己的产物，严格合适） |

### 2.4 安全边界的变化

- 放宽：已安装应用身份不再因附带数据（Finder 信息、资源分叉）或包内符号链接规则失败。代码被改动（密封文件、主可执行文件）仍然拒绝。
- 收紧：身份必须来自 Apple 签发的证书链。ad hoc、自签名应用在登录项归属与浏览器隐私里不再有签名身份（登录项归属退回按路径识别；其可执行文件仍由 Security 框架单独检查，Team ID 本来就只在 Apple 锚定时采用）。
- 直接后果：Chrome 等会被自动更新器留下附带数据的浏览器重新可判定为真身，直接删除资格恢复，但仍受 D34（sidecar）、D35（已同步的访问只能浏览器内处理）与写前复核约束。

### 2.5 测试、红绿与反证

`StartupApplicationSigningIdentityTests`：

| 测试 | 修复前 | 修复后 |
|---|---|---|
| `testReaderRunsOnlyFixedCodesignAndParsesBoundedIdentity`（参数锁定，按 D42 修改期望，并断言不含 `--strict`／`--no-strict`） | FAIL | PASS |
| `testFinderInfoRejectedOnlyByTheStrictCheckStillYieldsAnIdentity`（模拟 codesign：只有 `--strict` 报 detritus） | FAIL（nil） | PASS |
| `testModifiedOrNonAppleSignedBundlesStayUnknown`（模拟：密封文件被改 → nil 且不读 display；非 Apple 证书链 → 要求不满足 3 → nil） | FAIL（自签被接受） | PASS |
| `testRealCodesignAcceptsFinderInfoButRejectsModifiedAndAdHocCopies`（真实 `/usr/bin/codesign`，临时目录里的 FileMerge 副本：旧参数在 Finder 信息副本上报 detritus；新读取器给出 Team ID 与含 `anchor apple` 的 DR；改过密封文件的副本、ad hoc 副本无身份；`CodeSignatureVerifier.verifyCode` 与元数据读取器接受 Finder 信息副本并给出 Apple 锚定的 Team ID、拒绝改过的副本）。找不到 Xcode 的 FileMerge 或复制后无法校验时跳过 | FAIL（Finder 信息副本 nil；ad hoc 副本被接受） | PASS（未跳过，0.56 s） |

反证：临时去掉 `-R =anchor apple generic`，3 个测试 4 处失败（含真实 ad hoc 副本被接受），已还原（`item2-mutation-no-anchor.log`）。相关测试类（浏览器隐私、登录项扫描与管理、代码签名、卸载归属）267 个通过，3 个原有的显式开启项跳过。

### 2.6 决定 D42（用户已确认，2026-10-07）

正式文字已由主会话写入集成分支 `d91cb2d` 的 `DECISIONS.md`（本批未改 `DECISIONS.md`）；源码与测试注释已从“D42 draft”改为已确认的 D42（`77dea27`）。下面是交接时提交确认的草案原文，内容与正式文字一致：

> D42：识别已安装应用的身份或归属（登录项归属、浏览器隐私判定浏览器真身与直接删除资格、卸载关联文件归属、应用更新读取已安装应用的元数据）只要求三件事：签名完整（codesign 默认校验，相当于 Security 框架 `kSecCSStrictValidate`：签名、全部密封文件、嵌套代码封印、主可执行文件结构）；证书链由 Apple 签发（`anchor apple generic`）；原有的标识、Team ID、DR 检查。不使用 codesign `--strict`：其 sideband 检查把自动更新器留在完好签名包上的 Finder 信息、资源分叉当作 detritus 拒绝（Google Chrome，2026-10-06 实机），symlinks 检查连 Apple 自带的 Instruments 也拒绝。下载的更新包、本应用自己的构建与辅助程序保留严格校验（Security 框架 `kSecCSStrictValidate` 与更新包自己的符号链接检查；发布脚本 `--deep --strict`）。取代：`StartupApplicationSigningIdentityReader` 的 `codesign --verify --strict`（`StartupApplicationSigningIdentityTests` 锁定的参数按本决定修改）。影响：Chrome 等浏览器可再判定为真身、恢复直接删除（仍受 D34、D35 约束）；未经 Apple 签发证书签名（ad hoc、自签）的应用不再得到签名身份。

### 2.7 JEV

`jev_review`（只提交了代码改动、实验结果与测试摘要，没有凭据、个人数据或本机路径）：correctness 1.94（置信 0.91）、spec_match 1.98（0.97）、test_gap 0.23（0.65）、blast_radius 1.51（**0.27**），composite 0.8545，safe_to_apply 0.62，**action = escalate**。按工具规则，最低的评分置信度（blast_radius 0.27）低于复核线 0.5，所以是 escalate；影响面正是本项的安全边界与两个下游功能。这不是批准：之后 D42 由用户确认，Chrome 由主会话只读核对（2.2）。

## 3. 内存说明文案与 D28 不一致

### 3.1 改动（`6230c68`）

- `Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift` `MemorySampleStatusPresentation.evidence`（小窗一级内存卡的读屏值 `MenuBarGeekPanel.swift:233`；二级内存页 `GeekMemoryView` 页头采样时间的帮助、读屏提示与读屏值 `GeekMemoryView.swift:94–100`）：
  - 中：“快照生成于 …。压力等级（正常／升高／高）取自 macOS 系统，与活动监视器一致；压力百分比为 100% 减去系统压力余量，是估算，仅用于趋势。”（复核前写作“系统内存余量”，P2-4 统一）
  - 英：“Snapshot generated at …. The pressure level (Normal / Elevated / High) comes from macOS, the same source as Activity Monitor; the pressure percentage is an estimate, 100% minus system pressure headroom, for trends only.”
  - 样本缺项时追加一句：没有系统等级（等级按百分比估算，85% 起升高、95% 起高）／没有余量（没有百分比）／两者都没有（等级不可用）。规则与 `MemoryPressureLevel.estimated` 一致。
- `Views/MenuBarAdvanced/MenuBarGeekPanel.swift` 二级内存页压力圆环帮助：原“压力估算：100% − 系统压力余量”→“百分比为估算：100% − 系统压力余量，仅用于趋势；圆环颜色表示压力等级，取自 macOS 系统，与活动监视器一致；系统未给出等级时按百分比估算（85% 起为升高、95% 起为高）”（最后一句为 P2-4 补充；英文同步）。
- `Views/SystemUtilitiesView.swift` 主窗口内存页“指标说明”：原“…不是占用率，也不等同于压力等级”→“压力等级取自 macOS 系统（与活动监视器一致），系统未给出等级时按百分比估算（85% 起为升高、95% 起为高）。压力趋势估算 = 100 − 系统压力余量，仅用于趋势，不是占用率。”（估算一句为 P2-4 补充；英文同步）。主窗口压力圆环帮助原本已写明等级来源，P2-4 在句末补同一估算说明。

### 3.2 全仓同类句子

在 `Sources/` 与 `docs/` 搜“活动监视器”“Activity Monitor”“余量”“headroom”“压力估算／评估／趋势”“仅用于趋势”：

- 已改：上面三处。旧句“不等同于活动监视器的压力等级”／“it is not Activity Monitor's pressure level”全仓已无（测试守卫）。
- 本来就一致（P2-4 只补估算说明）：主窗口内存压力圆环帮助（“环颜色表示 macOS 报告的内存压力等级（与活动监视器同源）…”）；`docs/mini-window-design.md` 第 49–50 行（D28 原文）；`Models/SystemModels.swift` `pressureEstimatePercent` 注释（说的是百分比）。
- 只是标签或数值、不作判断，未改：“压力评估”“压力趋势估算”标题，“系统压力余量 N%”，优化结果里的“压力余量 N%”。

### 3.3 测试

`PanelChartNormalizationTests.testMemoryExplanationsSayTheLevelIsTheSystemsAndOnlyThePercentIsEstimated`：四种组合（系统等级有／无 × 百分比有／无）的说明文字、两种语言的原文都在源码里、另两处说明写明等级来源、全部 Swift 源码不再含旧句。修复前 14 处失败，修复后通过。原有的 `testMemoryStatusLabelsUseIndependentLowFrequencyClockWithoutSampling` 在 P2-4 中按统一用词把期望由“系统内存余量”改为“系统压力余量”（同义，锁定测试的修改见第 7 节）。测试进程的界面语言是英文，中文分支由源码检查覆盖。

## 4. 命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`；`swift` 命令都带 `--scratch-path ~/Developer/.sc-build/r2-live-fixes-1/<debug|strict> --jobs 3 --skip-update --disable-automatic-resolution`；日志在 `~/Developer/.sc-build/r2-live-fixes-1/logs/`。

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| 基线构建（改动前，含测试） | `swift build --build-tests` | 0 | 168.5 s | `baseline-build.log` |
| 第 1 项红 | `swift test --filter 'CleanupStoreFollowUpTests/testDone'` | 1 | 3 个执行，2 个测试失败（7 处，其中 2 处为再清理等待超时抛出；预期），对照通过 | `item1-red.log` |
| 第 1 项绿 | `swift test --filter 'CleanupStoreFollowUpTests\|ScanPresentationStateTests'` | 0 | 25 个，0 失败 | `item1-green.log` |
| 第 1 项反证 | 去掉按会话选页面后 `--filter 'CleanupStoreFollowUpTests/testScanAgain'` | 1 | 3 处失败（预期），已还原 | `item1-mutation-rescan.log` |
| 第 1 项布局 | `--filter 'SafeCleanupLayoutTests/testCleanupExecutionAndTerminalPagesKeepActionsInTheViewport\|UIConsistencyRegressionTests'` | 0 | 47 个，0 失败 | `item1-layout.log` |
| 第 2 项实验 | scratchpad 副本上的 codesign 与 Security 框架探针 | — | 见 2.1 | `item2-codesign-experiments.log` |
| 第 2 项红 | `--filter 'StartupApplicationSigningIdentityTests'` | 1 | 9 个执行，4 个测试失败（12 处，预期） | `item2-red.log` |
| 第 2 项绿 | `--filter 'StartupApplicationSigningIdentityTests\|BrowserPrivacy\|StartupScanning\|StartupItemManagement\|CodeSignature\|ApplicationMetadata\|UninstallOwnership'` | 0 | 267 个，3 个原有显式开启项跳过，0 失败 | `item2-green.log` |
| 第 2 项反证 | 去掉 `-R` 要求后 `--filter 'StartupApplicationSigningIdentityTests'` | 1 | 3 个测试 4 处失败（预期），已还原 | `item2-mutation-no-anchor.log` |
| 第 3 项红 | `--filter 'PanelChartNormalizationTests/testMemory'` | 1 | 8 个执行，新测试 1 个失败（14 处，预期），其余通过 | `item3-red.log` |
| 第 3 项绿 | `--filter 'PanelChartNormalizationTests\|UIConsistencyRegressionTests\|GeekHoverDetail\|DetailedPanelViewProfileTests\|MemoryPressure\|SystemMemory'` | 0 | 189 个，0 失败 | `item3-green.log` |
| Debug 全量（`6230c68`） | `swift test` | 0 | 3434 个执行，21 个跳过，0 失败；测试耗时 179.8 s，总 3 分 03 秒；负载 3.2–3.9 | `debug-full.log` |
| 严格并发（`6230c68`，新 scratch 全量编译） | `swift build -Xswiftc -strict-concurrency=complete` | 0 | 0 错误、0 编译警告（唯一一条是 `--skip-update` 选项已弃用）；95.9 s；负载 2.8–6.0 | `strict-concurrency.log` |
| 私有 API | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `guards.log` |
| `verify.sh` 的源码检查 | Views 不启动进程、内存功能不调用 purge、没有冲突副本 | — | 都没有匹配，PASS | `guards.log` |
| 空白检查 | `git diff --check`；`git diff --check c05b530 HEAD` | 0；0 | — | `guards.log` |

- 21 个跳过都是其他测试类里原有的条件跳过（AppUpdateOfficialSecurity 4、BenchmarkV7RealHardwareCapture 3、CleanupRuleScanner 2，其余 12 类各 1），本批没有新增跳过；没有计时项失败，没有放宽阈值。

NOT RUN（主会话门禁或实机）：Release 全量、`script/verify_menu_bar_performance.sh`、打包、安装、启动应用、截图。除 2.1 记录的一次对 Xcode 自带 Instruments.app 原件的只读 `codesign --verify --strict` 外，没有在已安装应用上运行 codesign，没有碰 Chrome。

## 5. 需要实机核对（主会话）

1. Chrome 记录能否直接删除：浏览器隐私扫描后，Chrome 的未同步记录不再标“浏览器内处理／未能确认安装位置和签名”（已同步的按 D35 仍在浏览器内处理）；用测试浏览记录走一次直接删除与恢复。可先只读核对 `codesign --verify --verbose=1 -R "=anchor apple generic" "/Applications/Google Chrome.app"` 退出码为 0、耗时小于 1 s（读取器每次调用的超时）。
2. 卸载 Chrome 类应用时关联文件能否核实：卸载预览里关联文件的“已核实”状态（走 Security 框架，本批未改；Finder 信息不影响它，只需确认结果）。
3. 登录项里 Google 更新代理的归属：显示所属应用 Google Chrome、Team ID EQHXZ8M8AV、用途为 Google 更新。
4. 清理后“完成”：智能扫描清理部分项目 →“完成”回到结果列表（已移走的不在、跳过的在、未选中、数字已变）；全部清完 →“完成”回初始页；完成页“重新扫描”可用。安全清理页、开发工具页同样走一遍，并在“完成”后直接再清理一次剩余项（修复前这一步静默无效）。
5. 内存说明：小窗内存页页头时间的悬停帮助与读屏、二级压力圆环帮助、主窗口内存页“指标说明”与压力圆环帮助，中英文各看一次；用词都是“系统压力余量”。
6. 复核 P2-1：完成页上点“重新扫描”正常扫描时，旧结果不再出现；在文件页按 ⌘R 后回到完成页再点“完成”，回初始页而不是结果列表。规则加载失败不易在实机上制造，可只看测试。

## 6. 未解决与风险

- D42 已由用户确认（2026-10-07）；JEV 当时为 escalate（2.7）。
- Chrome 的 codesign 结果与耗时由主会话只读实测（2.2）；本子代理没有在真实应用上运行。直接删除与恢复仍待实机核对（第 5 节）。
- 后续 P2-5（未做）：浏览器隐私判定浏览器真身时，再按各浏览器固定的 Team ID 核对（例如 Google Chrome 为 EQHXZ8M8AV），而不只要求“有 Apple 签发证书链和任意 Team ID”。需要逐个浏览器维护对照表，留作单独批次。
- 复核后发现的残留（未改）：在文件页按 ⌘R 启动的旧版全盘扫描不清除智能扫描的清理回执，所以该扫描失败或取消后旧回执页会再出现一次；“完成”已不会因此回到结果（P2-1），页面本身是否该出现可另行决定。
- 第 1 项的恢复后重新列出（1.5）未做。
- 新测试沿用现有夹具：临时目录、`/Users/Shared` 下的隔离回执日志（结束时删除）；真实 codesign 的测试只操作临时目录里的副本（含一次 ad hoc 重签，不用证书或钥匙串），结束时删除。它依赖已安装 Xcode 的 FileMerge.app，找不到或复制后无法校验时跳过（本次未跳过）。

## 7. 复核后修改（2026-10-07）

主会话独立复核：可以合并，无 P0／P1。用户已确认 D42（集成分支 `d91cb2d`）。同一 worktree 按复核意见补下列各项（先红后绿、`--jobs 3`）。

### 7.1 P2-1：“完成”只认这次清理自己的回执（`d01de24`）

- 问题：`dismissV2CleanupReport` 里的 `returnToResults(matching: scanPresentationSessionID)` 是拿当前令牌和自己比。两种触发：
  1. 完成页“重新扫描”时规则加载失败：新扫描换了令牌后在规则加载处失败（`ScanStore` 的 `startCleanupV2Scan`），旧回执没被清掉，`.failed` 加上旧回执让完成页再次出现（`ContentView.presentsV2CleanupPage`）；点“完成”就用失败扫描的令牌回到结果，而规则集已被清空，“清理”静默无效。
  2. 完成页显示时在文件页按 ⌘R：走旧版全盘扫描（`startScan` 的文件页分支）换了令牌，不清清理回执；该扫描失败或取消后旧回执页再出现，“完成”用别的扫描的令牌回到结果。
- 修复：
  - 清理发布结果时记下 `cleanupResultReturn`（回执 ID 与当时的展示令牌）。“完成”只在显示的就是这张回执、`cleanupWorkflowState` 仍是 `.completed(reportID:)` 且令牌一致（`returnToResults(matching:)` 用记下的令牌）时回到结果；无论结果如何都清掉记录。
  - `rescanAfterV2Cleanup` 开始前清掉回执（`lastCleanReport`、`cleanupRecoveryReport`、记录），另一个扫描在跑时不做（完成页“重新扫描”此时也不可点，与 ⌘R 一致）。
  - `canRequestV2Cleanup` 另要求处于 `.results`、有展示令牌、有规则集；残留状态下按钮不可点，不再静默无效。
- 测试（`CleanupStoreFollowUpTests`）：

| 测试 | 修复前 | 修复后 |
|---|---|---|
| `testScanAgainThatCannotLoadTheRulesDoesNotBringTheOldResultBack`（规则加载失败：旧回执已清、按钮不可点、“完成”回初始页） | FAIL（4 处） | PASS |
| `testDoneAfterAnotherScanStartedDoesNotReturnToTheResults`（文件页启动旧版全盘扫描（假的，失败）后“完成”回初始页） | FAIL（2 处：回到 results、按钮可点） | PASS |
| `testAnUninstallReceiptDoesNotReopenTheResults`（见 7.2；修复前“完成”已回初始页，但按钮仍可点） | FAIL（1 处） | PASS |

- 反证：把判断恢复成“当前令牌和自己比”，⌘R 测试 2 处失败，已还原（`review-p2-1-mutation-token.log`）。

### 7.2 P2-2：补的行为测试（同在 `d01de24`）

| 测试 | 说明 | 修复前 |
|---|---|---|
| `testAnUninstallReceiptDoesNotReopenTheResults` | 卸载会写 `lastCleanReport`；在产品模式下真实跑一次卸载（夹具应用，见下），之后“完成”回初始页、不重开结果 | 见 7.1 |
| `testTheOldMoveToTrashCannotRunBesideTheSmartScanCleanup` | 旧版“移入废纸篓”（单项与批量）也写 `lastCleanReport`，但只在旧版清理模式提供；产品模式下 `canRequestTrash`、`canRequestGreenTrash` 为假，`requestTrashAllGreen` 不生成待办，回执不变，文件不动 | PASS（行为本就如此，作守卫） |
| `testDoneAfterAStoppedCleanupReturnsToTheUnprocessedRows` | 第一次移动卡在闸门时“安全取消”，结果“已取消”：“完成”回到结果，未处理的行在、已移走的行不在、未选中、按钮可用 | PASS |
| `testDoneAfterAFailedCleanupReturnsToTheFailedRows` | 每次移动都失败，结果“失败”：“完成”回到同样两行，可再试 | PASS |
| `testDoneOnTheDeveloperFilesPageKeepsTheRemainingRowsCleanable` | 开发工具页（Homebrew、uv 两条开发缓存规则）清 1 行 →“完成”→ 直接清剩下的 1 行；全程只扫描一次 | PASS；反证：恢复成最初的“完成”实现后失败 2 处（回初始页、再清理超时），已还原（`review-p2-2-mutation-dev.log`） |

夹具改动：
- 卸载夹具应用放在家目录顶层的隐藏文件夹 `~/.StorageCleanerMacTests-LiveFix-<UUID>/`（卸载只接受家目录或 /Applications 里的应用；该位置不在任何清理规则根下，正在运行的测试版扫描不会列出它），移动注入到同一文件夹里的夹具废纸篓，不碰特权辅助程序；测试结束删除，运行后核对家目录里没有残留。
- 旧版全盘扫描一律注入为会失败的假实现（不读磁盘）；`cleanReportLoader: { [] }`，本测试类启动时不再读真实回执日志。
- 规则加载器可让下一次加载失败；移动器可换成“闸门”或“总是失败”的假实现；`scannedStore(route: .devCaches)` 按开发工具页的请求生成会话。

### 7.3 P2-3：D42 已确认（`77dea27` 与本交接更新）

- 读取器与测试注释中的“D42 draft”改为已确认的 D42。
- 交接 2.2 补主会话的 Chrome 只读实测；2.6、第 6 节改为“用户已确认（2026-10-07）”。

### 7.4 P2-4：用词统一与估算说明（`b76a6d9`）

- 小窗内存卡说明文字里的“系统内存余量”／“system memory headroom”改为与其他标签一致的“系统压力余量”／“system pressure headroom”。
- 二级压力圆环帮助、主窗口“指标说明”、主窗口压力圆环帮助补“系统未给出等级时按百分比估算（85% 起为升高、95% 起为高）”（英文同步），与说明文字里的规则一致（D28）。
- 修改的锁定测试：`PanelChartNormalizationTests.testMemoryStatusLabelsUseIndependentLowFrequencyClockWithoutSampling` 的期望由“系统内存余量”改为“系统压力余量”（同义，统一用词；依据 D28 与本复核意见）。`MemoryPressureLevelAppWideTests` 锁定的“环颜色表示 macOS 报告的内存压力等级”保留未变。
- 新断言：两处帮助与“指标说明”含估算说明（中英）；全部 Swift 源码不再出现“内存余量”／“memory headroom”。修改前 10 处失败（`review-p2-4-red.log`），修改后通过。

### 7.5 本轮命令与结果

| 步骤 | 命令 | exit | 结果 | 日志（`logs/`） |
|---|---|---|---|---|
| P2-1／P2-2 红 | `--filter 'CleanupStoreFollowUpTests'` | 1 | 25 个执行，3 个测试失败（7 处，预期） | `review-red.log` |
| P2-1／P2-2 绿 | `--filter 'CleanupStoreFollowUpTests\|ScanPresentationStateTests\|DebugSmartScanSessionFixtureTests\|UninstallStoreWiringTests'` | 0 | 37 个，0 失败 | `review-p2-1-green.log` |
| P2-1 反证 | 判断恢复成令牌自比 | 1 | 2 处失败（预期），已还原 | `review-p2-1-mutation-token.log` |
| P2-2 反证 | “完成”恢复成最初实现，只跑开发工具页测试 | 1 | 2 处失败（预期），已还原 | `review-p2-2-mutation-dev.log` |
| P2-4 红 | `--filter 'PanelChartNormalizationTests/testMemory'` | 1 | 8 个执行，10 处失败（预期） | `review-p2-4-red.log` |
| P2-3／P2-4 绿 | `--filter 'PanelChartNormalizationTests\|UIConsistencyRegressionTests\|MemoryPressureLevelAppWideTests\|StartupApplicationSigningIdentityTests\|GeekHoverDetail\|DetailedPanelViewProfileTests'` | 0 | 179 个，0 失败 | `review-p2-3-4-green.log` |
| Debug 全量（`b76a6d9`） | `swift test` | 0 | 3441 个执行，21 个跳过（与上一轮相同的原有条件跳过），0 失败；测试耗时 189.9 s，总 3 分 13 秒；负载 4.7–7.1 | `review-debug-full.log` |
| 严格并发（`b76a6d9`，在上一轮 strict scratch 上增量编译） | `swift build -Xswiftc -strict-concurrency=complete` | 0 | 0 错误、0 编译警告（只有 `--skip-update` 选项已弃用的提示）；34.9 s | `review-strict-concurrency.log` |
| 私有 API | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `review-guards.log` |
| `verify.sh` 的源码检查 | Views 不启动进程、内存功能不调用 purge、没有冲突副本 | — | PASS | `review-guards.log` |
| 空白检查 | `git diff --check`；`git diff --check c05b530 HEAD` | 0；0 | — | `review-guards.log` |

测试结束后核对：家目录里没有残留的 `.StorageCleanerMacTests-LiveFix-*` 文件夹，`/Users/Shared` 下没有残留的隔离回执日志。NOT RUN：Release 全量、小窗性能、打包、安装、实机。
