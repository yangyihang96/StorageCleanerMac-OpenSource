# r2-update-all 交接（2026-10-11）

本批初始基线为 `task/r2-update-all` 的 `1a3b6822`；修复轮 5 prepared 仅交付当前 HEAD `4fa11dbd` 之后的增量。已读 `_prompts/common.md`、`codex-build-common.md` 及协作决定；后者允许沙箱编译和定向测试，`.git` 只读，因此交付 `~/Developer/.sc-build/r2-update-all/prepared/`。

**当前状态：已执行修复轮 5，prepared 增量基线为 4fa11dbd；最终改动与验证见文末“修复轮 5”。** 下文保留前版记录供审计，其中 SecurityAgent 执行 mas、旧 group-write 全拒规则、fork 一律待核验及“脚本不能取得口令”的保证均已被后续实现或主会话决定取代。本批决定编号统一为 D78，D76／D77 留给并行批次。本批未安装、启动 App 或执行真实更新；源码编译与假实现测试不等于实机验收。

## 改动与数据流

1. `ApplicationUpdateProviderRegistry → ApplicationUpdatePlanBuilder → FrozenUpdatePlan → ApplicationUpdateCoordinator` 使用同一计划，automatic、requiresQuit、requiresAuthorization 都是自动批次成员；系统应用仍排除。主按钮“全部更新 · N 个”的 N 由同一计划计算，显示退出重开数和一次授权说明；一次点击直接冻结并确认原有 store 计划。分类展示仍保留处理方式，不再把授权项丢入 skipped。更新设置把原有 formula／自更新 cask 开关改为“始终包含／始终检查”说明；旧偏好字段继续解码保留，不再显示会产生误解的开关。
2. Homebrew 收集 plain 和 greedy outdated，默认包含 formula；包 token、安全执行器、pinned／disabled／deprecated、只读卷及未知 outdated 来源的保护保留。字体、CLI、无 .app cask、auto_updates／latest／元组版本不再因 .app 或旧签名准入门而转官网。Homebrew 所管理的包优先保留 Homebrew 来源，避免另装官网副本。
3. 新 `HomebrewBatchInstaller` 先读取冻结包的实际 `brew list --versions`，版本漂移拒绝执行；有应用的包读取所有声明的 .app 路径。formula、cask 分组，正常情况各一次 upgrade，cask 组含 greedy 项时加 `--greedy`。合并命令失败后逐项核验，只对仍未改变的项目单独重试，已改变身份／已安装但低于目标的项不重试。有 .app 的项更新后验证有效签名、Bundle ID、相同非空 Team ID和版本；选中路径与 cask 声明路径不同时，独立复读选中副本，不能用另一份应用或包版本冒充该行已更新。无 .app 核验包版本，记录失败证据。命令成功不等于完成。
4. `mas 7.0.0` 的 `upgrade` 是 `update` 别名，实际 help 明示需要 root；只读 help 已保存至 scratch `evidence/mas-upgrade-help.txt`，未执行 upgrade。本地 trusted mas、验证过的 receipt、签名身份、精确 Bundle ID、路径、当前版本、商品 ID以及 Apple 目录目标版本一致才纳入 automatic；执行前再次核对冻结目标。无 mas 走 App Store；实际升级返回账户未登录时记 skipped，保留“打开 App Store 更新”入口。商品 ID／路径／版本不一致的旧安全测试保持原断言。
5. 非 Homebrew Sparkle 读取 `SUFeedURL`／`SUPublicEDKey`，HTTPS appcast 只选择高于已安装且满足系统版本的完整附件；拒绝 DTD／外部实体／delta，不伪造没有 shortVersionString 的 marketing 版本。下载附件后 Ed25519 签名不通过即不解包、不替换。有新附件才复用 `OfficialApplicationUpdateInstaller`、`SecureZipArchiveExtractor`、`BundleIdentityVerifier` 与替换事务。无 ED key 的旧式应用要求可验证的已装代码身份及相同开发者候选签名；不具备安全条件或附件不支持时说明应用内更新原因。当前支持 zip／dmg。
6. 厂商来源优先保留已有 Homebrew 管理。否则识别固定官方路径和匹配开发者签名的 Microsoft `msupdate`／Google Keystone `ksadmin`，冻结命令路径和产品 ID，再执行精确官方参数。Microsoft 目前有明确 ID映射的 Word／Excel／PowerPoint／Outlook／OneNote／Defender；不凭空猜其他产品 ID。没有可靠 CLI 时保留应用内更新及原因。无公开目标版本的可信 CLI 可以检查并更新，最终以身份与磁盘严格更高的新版本核验；即使命令让版本改变，也不能把降级报成功。没有新版本记跳过。
7. 新批次 runtime 只调用 `NSRunningApplication.terminate`，最多等待 60 秒，不 forceTerminate；拒绝退出时写“应用未退出”并继续。成功后重新打开原来在运行的项目；重开错误单独保留，不把已核验的安装成功改成安装失败。生命周期、命令、下载与测试替换都有注入边界。
8. 批次授权复用现有 SecurityAgent＋签名 FileOperation helper：一次授权冻结 numeric App Store IDs及精确非 Apple `.app` 替换目标，不接收任意 root shell、命令或环境。不读／存密码。helper 对无签名 mas 的批准字节作 SHA-256 固定，并在 root 私有目录执行副本；应用替换再次核验旧版本及开发者身份，原子交换并在验证失败时交换回去。取消／结束释放批次；pause/resume 不重复请求同一批授权。真实系统框次数和 helper 部署均未验证。
9. 官网队列只接受无法自动处理的项目；旧 website-queue 中现已支持 automatic 的项目恢复为 deferred，提示使用全部更新。结果行加来源与降级原因，既有逐项状态、结果、失败重试继续复用。系统项单列“随 macOS 更新”，提供软件更新设置入口。

## 单列的跨边界补丁

- `01-privileged-helper`：`Sources/FileOperationShared/` 的四个受限 XPC 操作及数据合同、`Sources/FileOperationHelper/main.swift` 接入与新 session 实现。原因：mas 7明确要求 root，现有 helper 原来只有移动／恢复，直接在 App 内执行 mas 会失败；不能实现 sudo、读取密码或增加任意 root 执行器。必须由主会话单独做 helper 安全复核，并随对应 Beta 构建部署后核验协议兼容。用户明确要求复用授权机制，此处是必要的最小扩展，但超出常规 AppUpdates 文件拥有范围，故独立分组。
- `05-scanstore-result-count`：`ScanStore.swift` 仅在 executableApplicationIDs 集合增加 `snapshot.plan.requiresAuthorizationApplicationIDs` 一行。原因：否则已执行的 App Store 授权项会被旧结果统计当成系统手动项，完成页数量与实际批次不符。其余 store 代码保留。

## 改写的旧断言（依据 D78；安全断言不删除）

| 测试原名称／位置 | 原断言 → 新断言 | 依据 |
| --- | --- | --- |
| ModelsScanningProvider / CaskOutdatedProvenanceIgnoresInstalledInfoFlagAndFailsClosed | 只有 plain outdated 能自动 → plain、greedy 都能；unknown、失败／畸形 JSON仍拒绝 | greedy 用专用参数并后验结果 |
| ModelsScanningProvider / AutomaticLayersRequirePlainOutdatedProvenance | greedy 在 source、plan、recipe 被拒 → 全部允许 greedy，unknown仍拒 | D78取代人工确认门 |
| ModelsScanningProvider / CaskVersionProjectionKeepsAmbiguousCSVManual | CSV／latest／symbolic installed 全部 manual／unknown → 保留原始包版本并进入批次；已能严格投影的 digest 仍投影 | Homebrew outdated 是包更新依据，成功仍需后验 |
| ModelsScanningProvider / AutoUpdatesCaskRequiresStrictComparableTargetAndIdentity | equal／lower／latest 的 outdated、缺 Team、非精确 path 都拒准入 → 包可进入；冻结 target 必须等于实际检查结果 | 包版本和 Bundle 版本不必同格式，Team门移到更新后 |
| ModelsScanningProvider / AutomaticVersionGateRejectsSymbolicInstalledLatest | symbolic installed 不能自动、无目标 → 保留 Homebrew 目标、可执行 | 支持 latest cask；无法核验变化仍失败 |
| ModelsScanningProvider / ProviderOnlyMarksExactCaskMatchAutomatic | name fallback 必须手动 → 精确包 token 可自动 | 无 .app 字体／CLI也必须覆盖；路径身份在执行期核对 |
| ModelsScanningProvider / CaskRequiresActualArtifactPathAndSignedIdentity | 不是选中 path 就拒 source／plan → 包可入批次 | 不把应用路径当包更新准入条件；不把副本冒充目标成功 |
| ModelsScanningProvider / ArbitrationUsesVerifiedOfficialDMGForAutoUpdatesHomebrewCasks | greedy 倾向官网 DMG → 保留 Homebrew | 不重装第二份，brew 管理归属优先 |
| ModelsScanningProvider / ArbitrationUsesVerifiedOfficialDMGWhenOrdinaryHomebrewIsManual | 缺 exact path 倾向官网 → 保留 Homebrew | 同上；移除旧 exact-path门 |
| ModelsScanningProvider / AppStoreProviderAlwaysHandsOffToSystemAppStore | 永远不可自动、prepare被拒 → trusted mas＋精确证据可自动，加入授权组，注入的授权执行只收到指定 ID | mas 7root要求及统一批次 |
| PresentationModels / SummaryAndCatalogKeepAutomaticQuitAndAuthorizationDistinct | batch只含 direct／quit → 增加 authorization，分类数字仍各自独立 | N必须含需授权项 |
| PresentationModels / FrozenUpdatePlanPreservesEveryBucketAndSkipsUnsupportedExecution | authorization／AppStore 全放 skipped → authorization 执行，无mas AppStore保留 handoff | 不能在 frozen plan丢掉已支持来源 |
| PresentationModels / OneClickPlanStartsVerifiedRunningApplicationWaitingForQuit | running未知 Team／authorization 不入批次 → 加入；旧 Unsupported fake仍用 waitingQuit／waitingAuthorization | Team门移后验；生产 Batch executor自行限时退出 |
| Coordinator / PlanOnlyPlacesStrictHomebrewItemsInAutomaticGroup | pinned 放 manual → 放 skipped，普通 manual不变 | pinned排除，保留中文原因 |
| PresentationIntegration / HomebrewCommandIsAnAdvancedFallbackBehindOneClickUpdate | 主标题“查看并处理更新”、点击只 preview → 标题／启用读同一批计划，点击包含 confirm | 用户要求一个主按钮、一键执行 |
| PresentationIntegration / OneConfirmationExecutesEligibleItemOnceAndKeepsUnsupportedItemsVisible | authorization被skipped、只执行1项 → automatic与authorization共执行2项；AppStore无mas／只读Sparkle／manual仍skipped；使用明确的批次假执行器 | 统一批次必须执行授权组；本测试在沙箱创建家目录夹具时被阻挡，主会话复跑 |
| PresentationIntegration / SelectedRunningAutomaticSurvivesStoreGateWhileAuthorizationIsRejected | selected／单项授权被store拒 → selected／单项都保留授权项，FrozenPlan授权组不为空 | canJoinSelectedUpdateBatch沿用新batch成员；沙箱阻挡不能掩盖旧断言 |
| FreshActualTarget / NonInstallingProviders… | 未配置自动能力的 provider只会 providerUnsupported → 允许当前明确的 typed安全拒绝（configurationChanged／identityChanged／noLongerEligible等），仍不能成功 | 类别支持安装后，伪造空 prepared依旧必须失败 |

`SparkleReadOnlyProbeTests` 显式注入 `automaticAdapter: nil`，保留原只读 probe测试和原“不安装”断言；新增 automatic suite单独检验新边界。原默认 App Store 测试显式注入无 mas／空 outdated，以免 D48测试碰真实 mas。App Store 的商品 ID／路径／当前及目标版本错配测试未改断言；产品实现补回了这些阻断。

## 验证记录

- Debug：通过，最终源码构建 `debug-final.log`（24.78 sec）含全部测试目标；包括 Homebrew 选中副本独立复读、厂商未知目标拒绝降级和设置文案修正。
- Release：通过，最终 `release-final.log`：Build complete（428.87 sec），使用 `-c release --build-tests -Xswiftc -enable-testing` 和 SDK公开支持的 native构建引擎，包含最后厂商严格升版与设置修正。默认 `swiftbuild` 的 dSYM步骤被 `Operation not permitted` 拒绝；同一 dsymutil单独在 scratch执行成功，换 native重跑，未降低 Release优化。最终轮固定源码后完整构建。
- 定向 Release：新增25项＋UI一致性46项，`release-targeted-final.log` **71/71通过**，保持 Release优化／enable-testing；逐项记录在 `evidence/release-targeted-results.json`。
- 定向 Debug：`targeted-delivery-final.log` 共 **335** 个测试，**312 passed、19 failed methods、4 skipped**；XCTest计 **21个失败断言**。19个失败均来自沙箱写入限制，下节逐项列出。新增批次／Sparkle／厂商测试共 **25** 个全部通过；`WebsiteUpdateWorkflowTests` **22/22**、`UIConsistencyRegressionTests` **46/46**通过。
- 最后增加 `testUpdatedBrewArtifactCannotCompleteAnUnchangedSelectedCopy`，明确拒绝 cask 另一份应用更新但当前行未更新的假成功；最终 Debug 定向通过该测试；新增厂商未知目标版本测试覆盖不变／降级／升版，前两者不能报成功。此前管理员错误中文说明的针对回归见 `targeted-root-error-regression.log`，最终定向也覆盖单项失败后继续批次。
- 私有 API检查 `script/check_private_api.py`：通过（7项允许调用）。`git diff --check`：通过。最终文件和 prepared产物哈希、原 index可应用性通过只读交付脚本检查；40个文件、六组补丁，未写入 index或提交。
- 没有运行完整 verify.sh：该脚本跑全量测试／真实夹具；遵守 codex-build-common只跑定向。主会话需完成完整门禁，尤其沙箱外定向／全量测试、strict concurrency与 counterexamples。
- JEV：发现工具后尝试判断调用，被 `approval policy=never` 阻止（工具要求 approval）。未获得 JEV判断，未换模型或声称复核通过。

## 沙箱阻挡（保留夹具与阈值，主会话复跑）

`AppUpdateCoordinatorTests` 的3项与 `AppUpdatePresentationIntegrationTests` 的10项在 `~/.storage-cleaner-scan-store-*/home` 创建夹具即报 NSCocoaErrorDomain 513／Operation not permitted。偏好6项（含重复断言计8次）有对应 `sandbox_extension_issue_file failed`，无法在绝对路径偏好域完成 synchronize；不是通过态。

- AppUpdateCoordinatorTests：ConfirmedQueueRequestsQuitOnceAndRejectedRequestKeepsWaiting；ExecutionTimeWaitingStateMakesLaterTerminationEventRecoverable；StoreRejectsBufferedTaskAndSnapshotEventsFromStaleSession。
- AppUpdatePresentationIntegrationTests：AllFailedBatchEntersFailedAndRetryKeepsSameSession；CancellationRequestIsVisibleBeforeQueueStops；DismissingConfirmedPreviewDoesNotCancelRunningBatch；FastAutoResumedQueueDrainIsBufferedBeforeRestoreMonitorStarts；OneConfirmationExecutesEligibleItemOnceAndKeepsUnsupportedItemsVisible；RestoredActiveQueueMapsToUpdatingPresentation；ScanLifecyclePublishesRealTotalsThenPreservesSummaryAcrossManagerNavigation；SelectedRunningAndAuthorizationSurviveStoreGate；TerminalRestoredQueueDoesNotDoubleFinalizeNextForegroundBatch；UserUpdateRequestsStayPendingUntilConfirmationAndSeparateManualActions。
- SparkleReadOnlyProbeTests：ShadowHostKeepsSparkleSettingsOutOfTheRealPreferencesFolder；ShadowHostLeavesTargetDefaultsUntouchedAfterCallerCancellation；…AfterTimeout；…ForUpdateAndNoUpdate（两条断言）。
- TestPreferenceHygieneTests：FactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory（两条断言）；TemporarySuiteCanBeReopenedOnAWorkerThread。

完整 method名、pass／fail／skip与日志尾部在 scratch `evidence/targeted-results.json`，不用删测试或放宽产品路径安全检查。

## 主会话命令与红／绿／反证

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
SC_UPDATE_SCRATCH=/Users/developer/Developer/.sc-build/r2-update-all
SC_UPDATE_FLAGS=(--disable-sandbox -Xswiftc -disable-sandbox --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
SC_UPDATE_FILTER=$(paste -sd '|' "$SC_UPDATE_SCRATCH/targeted-classes.txt")
swift build "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/debug" --build-tests
swift test "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/debug" --skip-build --filter "$SC_UPDATE_FILTER"
swift build -c release --build-tests -Xswiftc -enable-testing "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/release"
swift test -c release -Xswiftc -enable-testing "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/release" --skip-build --filter "$SC_UPDATE_FILTER"
# 沙箱默认引擎的 dSYM限制仍出现时，Release build/test 同时增加 --build-system native。
```

- 红：基线会把 greedy／字体／formula、授权项、Sparkle的签名安装移出计划；新增25项中的对应测试在基线不能满足新接口／行为。首轮旧回归的实际红见 `targeted-red.log`；这包含旧断言及权限失败，不能全部解释为产品缺陷。
- 绿：按上面16个类运行；实测335项结果和25项新增通过如上。身份变化、假成功、版本未到目标、拒绝退出、单项命令失败及无mas均用假实现，没有触发真实网络／更新。
- 反证：scratch `counterexamples.json` 有 **18** 项，精确 id/path/before/after/expected_occurrences/filter，多处替换用 replacements；每项限定一个有意义的安全／行为门，包括 greedy、pinned、版本漂移、Team、EdDSA、不更新版本、退出拒绝、重开、授权去重、按钮N、账户fallback、厂商命令冻结、官网排除及选中 cask 副本的独立复读和厂商未知目标版本拒绝降级。替换表达式保持 Swift类型和调用形状；本批按提示**未执行反证，也未证明突变编译成功**。主会话须逐项恢复原文→应用替换→Debug/Release编译→指定 filter必须失败→恢复原文，并记录 killed／survived；编译失败不能算 killed。
- 集成后完整门禁：用项目规定 `DEVELOPER_DIR`、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`、独立 `STORAGE_CLEANER_VERIFY_ROOT` 执行 `script/verify.sh`。所有真实更新与安装仍需另有明确授权，本批命令不包含它们。

## 未解决与实际边界

1. **管理员 Homebrew pkg：功能缺口。** 本机 Homebrew的 `Cask::Artifact::Pkg` 直接调用 `/usr/bin/sudo`，`HOMEBREW_NO_SUDO` 下 `check_requirements` 会拒绝；brew也不允许整进程 root运行。当前强制 `HOMEBREW_NO_SUDO=1`，避免越过“一批最多一次系统授权／不自行实现sudo”的约束，所以该类会进入同一批次但失败，给中文原因并继续其他包；其他依赖 Homebrew 自有 sudo 的 artifact 同样未被这条授权链覆盖。不能称所有 cask已经自动执行成功。需要真正受限的 Homebrew官方安装接口／授权桥接；不能通过改sudoers、伪造timestamp、保存密码或 root运行用户Ruby脚本补过此边界。
2. **Homebrew不会自动回滚 Team变化。** 这按用户要求标失败并保留路径与前后 Team证据；已装包可能已变化，不声称旧应用自动恢复。无 .app 且 symbolic latest前后版本不变无法证明升级，按失败报告，不能仅凭退出码完成。
3. **原生链路未验收。** 新 helper协议、签名／部署、SMAppService状态、系统授权对话次数、mas账户、厂商PPPC提示、正常退出／未保存文稿／重开都没有在实机运行。helper须已启用且版本匹配；仅 mock授权去重不证明真实系统交互只有一次。
4. **厂商覆盖有界。** 只对已验证官方CLI和已知产品ID执行；未将非 Homebrew安装的应用自动认领为新 cask，也未实现任意未知厂商命令。Keystone能力与MAU实际plist格式需要本机只读及mock回灌验证。
5. **Sparkle格式有界。** 当前支持zip/dmg完整包；pkg、delta与未通过签名／身份检查的来源降级应用内并说明原因。HTTPS下载沿用既有allowed-host策略，跨域CDN重定向可能需来源专门适配；未把任何官网地址放宽成自动下载许可。保护目录由helper原子交换保留旧app直到后验成功，真实崩溃与恢复场景需要主会话复核。
6. 无提交／安装／push／发布／真实更新；准备脚本只有主会话完成必要验证后使用 `--validated` 才提交。

## 一手依据

- mas本机7帮助及[官方README](https://github.com/mas-cli/mas/blob/main/README.md)：升级需要root，账户检查能力不能照旧版 account子命令猜测。
- [Sparkle官方安全说明](https://sparkle-project.org/documentation/security-and-reliability/)与[更新包文档](https://sparkle-project.org/documentation/)：附件认证、开发者身份与版本检查必须共同成立。
- [Microsoft msupdate官方文档](https://learn.microsoft.com/en-us/microsoft-365-apps/mac/update-office-for-mac-using-msupdate)：`--list --format plist`、`--install --apps`、`--wait`；MAU隐私授权与真实结果需要独立验收。
- 本机 Homebrew `system_command.rb`、`cask/artifact/pkg.rb`、`cask/installer.rb`、`brew.sh` 只读核对；没有改Homebrew本身。


## 修复轮 1（2026-10-12；主会话复核 P1–1…P1–7、P2–1…P2–6）

本节取代首轮涉及管理员授权、归档路径消费、替换方式、重试会话、未解决项与补丁分组的旧说明。D78 是本批决定；本批原编号已迁移，D76 属小窗批次、D77 属结果空间批次。首轮 prepared 原样备份为 scratch `prepared-before-repair1/`，主会话日志均未改写。

### 已读的失败证据

完整阅读 `logs/main-final-2210/` 的 build、targeted、full、mut/summary.json、rebuild、release-build，以及 `logs/codex-review.log` 末尾全部复核。首轮主会话 targeted 为 335 项、4 skipped、0 failures；full 的 8 个 XCTest failure（其中 1 unexpected） 分布在下面 5 个方法，并非 8 个独立方法。首轮 18 个反证为 17 killed、1 survived，存活项是 `non-newer-release`。主会话原始证据和摘要 `evidence/repair1-main-baseline.json` 保留；其通过结果不能作为本轮新源码的完整门禁结果。

### 修复与注入验证

| 复核项 | 本轮改动与理由 | 核心测试／证据 |
| --- | --- | --- |
| P1–1 | 删除 helper 的 mas／brew root 执行入口和旧批次合同。App 原生安全输入展示命令与项目；sudo -A 验证后立即 sudo -k，错误最多三次。签名 askpass 通过私有 socket 与本进程树取回内存密码，结束／取消／退出清零。MAS 用绝对路径、数值 ID；保持用户终端执行相同的信任模型。 | AuthorizationRepair：一次密码覆盖 MAS/Brew，参数／环境不含密码，错误三次全清零，取消不执行 sudo，结果脱敏；没有真实 sudo／askpass 调用。 |
| P1–2 | 归档通过 O_NOFOLLOW 文件描述符形成不映射的拥有字节快照；EdDSA、ZIP manifest、解包均消费同一对象。私有候选摘要经存活批次授权门透传，旧无摘要调用拒绝，随 helper 请求传递，root 0700 staging 复制后复核相同摘要与代码签名再交换。 | ArchiveRepair：有效签名后替换原路径内容，生产 manifest／inflate／安装仍只使用已签字节；改变候选字节使共享 root staging 摘要守卫拒绝。 |
| P1–3 | 新 RPC 前验证 bundled helper 签名，再通过受限 XPC 握手核对实际 build／capability／busy。build 来自驻留 executable 自身签名 __TEXT,__info_plist，绝不读 enclosing App／sidecar。旧或缺失 capability 只刷新一次，复用 AuthorizedApplicationMover 生命周期，握手 2 s、刷新 10 s、prepare 10 s、replace 120 s、finish 5 s；无 31 分钟兜底；刷新超时取消待办生命周期任务。更新与卸载／恢复共享重工作 lease，busy 时不刷新。旧 prepare／commit 合同保留；受信任 build 握手成功后同步既有生命周期缓存，避免卸载／恢复无谓重启 worker。 | AuthorizationRepair：旧 build、缺失 selector、busy、签名变化与基线旧客户端合同；真实 SMAppService／部署未执行。 |
| P1–4 | DMG 用已认证的匿名 seekable fd 挂载；挂载期间复制到 0700 私有 staging，复核链接 containment、代码身份、版本与摘要后才交 helper，最后 detach。helper 不接受 /Volumes。扫描／计划只允许 /Applications 顶层受保护替换，不支持的项单独降级；helper 不可用不拖垮已获批 MAS／Brew。 | ArchiveRepair：假的 mount→private copy→digest-bound helper→detach 顺序；AuthorizationRepair：受保护批次准备失败仍可执行假 MAS。 |
| P1–5 | 按本机 Homebrew pkg、installer sudo 声明、目标父目录／既有目标不可写识别 administratorReasons，计入授权提示。移除 HOMEBREW_NO_SUDO，管理员／普通包分组，只向管理员组注入 SUDO_ASKPASS。拒绝授权仅跳过管理员组，继续普通包。 | ArtifactPrivilegeDetection、授权参数检查与分组回归；本机 Ruby 源码只读依据保留。 |
| P1–6 | 按 kind＋token 去重，合并所有 app artifact 及选中副本路径，逐份正常退出；任一拒绝跳过整个包并重开此前已退出的副本。brew 前再次查精确路径是否运行，成功后逐份记重开成功／失败。 | AllBatch：同包多行只升级一次、第二 artifact 拒绝整包跳过且后续 formula 继续、执行前重启不运行 brew。 |
| P1–7 | 更新执行器仅使用生产端限量内存 pipe（64 KiB），不再无限输出到临时文件。只停止自己创建的命令组，TERM／KILL 都有界；helper finish 优先发出取消并明确等待 serial replacement／回滚回执，再在独立未取消任务中 sudo -k 撤销 timestamp。无法证明系统安装停止，包含已交给系统服务的 sudo／厂商安装，保持 needsReconciliation，核验并不自动重试；错误先清除密码／账户等，再截断，避免边界泄露密码片段。 | OutputBudget／StopReceipt、finished cancellation acknowledgement、假不确定安装只调用 list readback 不重试、密码／账户／URL 参数脱敏。 |
| P2–1 | App 与 helper 共用 ApplicationUpdateVersionOrder 严格比较 marketing，再比较 build；Sparkle、Bundle installer、后验与恢复沿用该顺序。 | ArchiveRepair：同 marketing 的 build 100→101 真 ZIP 解包后替换；同版本与 build 降级都拒绝且旧应用保留。 |
| P2–2 | 可写目录同卷 renamex_np RENAME_SWAP，旧包保留到后验完成。新增 bundlesExchanged journal 阶段，兼容旧 journal；失败反交换，清理后中断保留 journal 供核验。 | ArchiveRepair：afterSwap／beforeCleanup 注入故障无目的路径缺口且旧包恢复；afterCleanup 中断可恢复／核验新包。 |
| P2–3 | 无 .app 的 symbolic latest 不能只凭 list 字符串或退出码报成功；缺少关联本次调用的 receipt/artifact 证据即待核验，不执行单项自动重试。普通无 .app 包的恢复读 brew list，不用 GUI metadata reader。 | LatestWithoutApp、UnconfirmedSystemInstallation、NoAppPackageReadOnlyReconciliation。 |
| P2–4 | 已结束批次重试创建新 UUID、重新请求密码；多个勾选失败项一次建立一个新批次。先订阅事件，再将 ScanStore 监视器和页面 token 绑定到新 ID，快速结束事件也不会丢失；待核验项禁止再次启动安装。界面明确提示再次授权。 | CoordinatorRetryStartsNewBatchAndRequestsPasswordAgain；Coordinator failed retry；Store new-session integration 等待沙箱外复跑。 |
| P2–5 | MAS 账户未登录为 skipped，汇总分别列成功／失败／取消／跳过和原因；所有账户项跳过时 App Store／automatic 状态为 skipped。 | AppStoreAccountFailure；新增 Store 报告集成（沙箱家目录夹具受阻，原断言保留）。 |
| P2–6 | non-newer-release 夹具补有效 sparkleConfiguration，突变不能再被空配置掩盖。新增生产 ZIP 字节安装链、DMG staging、旧 helper、取消和输出上限测试。token 限定包名／明确三段 tap 名，拒绝 ./x.rb、x.rb 和路径形状；FreshActualTarget 恢复按 provider 精确枚举错误。 | 37 条精确反证配方及 anchor/filter 检查；本轮未执行反证，编译失败不可记 killed。 |

### 本轮改写的旧断言

| 方法 | 原断言 → 本轮断言 | 依据 |
| --- | --- | --- |
| FeatureLightfieldApplicationPage / UpdateRowAndPrimaryAXPressOnlyOpenReviewAndExposeHandling | 主按钮 AX 只打开审核且名字为 Review and Handle → 行仍审核，主按钮 AX 调用冻结自动批次、名字含 Update All 与 N | 用户一个主按钮直接更新；本轮 AX 方法实测通过。 |
| FeatureLightfieldApplicationPresentation / ResultSourceKeepsChecksAndReviewAwayFromInstallation | 主按钮源代码只调用 onPreviewOneClick → 保留预览后调用 confirmOneClickAppUpdates | 首轮 full 失败；审核入口仍独立，不能锁住旧行为。 |
| HeavyWorkIntegration / StaleAutomaticAppStoreFlagsStillRequireSystemConfirmation | 已验证 automatic App Store 仍只能 appStoreManaged、计划不自动 → trusted automatic 与授权项进入统一批次 | 新 MAS 路径及主会话决定；本轮定向通过。 |
| SystemUtilitySafety / AppUpdaterBatchButtonsCreateVerifiedAutomaticRequests | 同旧 preview-only callback → 冻结并确认批次 | 首轮 full 失败；本轮定向通过。 |
| SystemUtilitySafety / AppUpdatesDashboardShowsVerifiedUpdatesAndKeepsAutomaticBatchSeparate | 旧“查看并处理更新”标题 → 同一计划计算“全部更新 · N 个” | 首轮 full 失败；本轮定向通过。 |
| Coordinator / FailedTaskRetryKeepsSessionAndIncrementsAttemptCount | 重试保持 UUID → 新 UUID、attemptCount 仍递增 | 密码在批次结束清除，新批次须重新授权。 |
| PresentationIntegration / AllFailedBatchEntersFailedAndRetryKeepsSameSession | 完成报告同 sessionID → 新 sessionID，执行次数和 attemptCount 断言仍保留 | 同上；同时修复新批次监视器，沙箱外须跑集成。 |
| FreshActualTarget / NonInstallingProviders… | 放宽为若干通用安全错误 → 按 App Store／Sparkle／厂商／manual／system provider 枚举唯一预期错误 | 按主会话要求恢复精确安全断言，空 prepared 不能成功。 |
| SparkleAutomatic / FrozenReleaseMustBeNewerBeforeDownload | 空配置会先拒绝且掩盖升版守卫 → 有效 ED key 配置，仍断言同版本／降级不能下载 | 修复首轮唯一 surviving 反证的夹具原因，不删除断言。 |

### 独立补丁组与边界

本轮 prepared 为七组：01 helper＋AuthorizedApplicationMover 生命周期；02 统一引擎／内存 sudo 授权；03 UI；04 测试；05 ScanStore 最小例外；06 D78／交接；07 Package.swift／签名 askpass／打包脚本。ScanStore 例外仅三处：授权成员计数、skipped 汇总、新批次重试监视绑定。新增 AppUpdateReport.skippedCount 位于拥有的模型文件。包管理和 root 替换不混在同一个 helper 入口。

纯文件安装测试仅操作 TestFileSystem 隔离临时 fixture；DMG、sudo、askpass、MAS／Brew、厂商命令、下载、原生替换与退出／重开均注入。没有运行真实 brew upgrade、mas upgrade、sudo、installer、hdiutil，没有启动 App，没有读取钥匙串，没有安装／push／提交。

### 本轮验证与剩余核验

| 检查 | 本轮实际结果 | 日志／证据 |
| --- | --- | --- |
| 最终 Debug 构建（含测试目标） | PASS，13.15 s | `logs/repair1-debug-build.log` |
| 最终 Debug 定向 | 381 项：355 passed、22 failed methods、4 skipped；24 失败断言，其中 16 unexpected。22 方法均有沙箱拒绝写入证据；定向进程退出 1，不能写全绿。 | `logs/repair1-targeted-debug-final.log`；`evidence/repair1-targeted-results.json` |
| 新增批次／Sparkle／厂商与修复套件 | 55/55 passed：AllBatch 22、ArchiveRepair 9、AuthorizationRepair 12、SparkleAutomatic 8、VendorAutomatic 4 | 同上 |
| UIConsistencyRegressionTests | 46/46 passed | 同上 |
| 首轮 full 中 5 个失败方法对应的本轮回归 | 5/5 passed；AX、主按钮与 MAS 断言按上表改写，未放宽身份／路径安全断言 | 同上 |
| 最终 Release 构建（native；`-c release --build-tests -Xswiftc -enable-testing`） | PASS，498.45 s；保留 Release 优化与 enable-testing，包含全部测试目标 | `logs/repair1-release-build.log` |
| 最终 Release 定向（上述 55 项＋UI 46 项） | PASS，101/101，0 failed／0 skipped，4.045 s；逐方法结果 `evidence/repair1-release-targeted-results.json` | `logs/repair1-targeted-release-final.log` |
| 私有 API／打包脚本语法／diff | 私有 API PASS，7 项 allowlisted；脚本 `bash -n` PASS；`git diff --check` PASS | `logs/repair1-private-api.log`；`logs/repair1-packaging-syntax.log`；`logs/repair1-diff-check.log` |
| 源码冻结 | 58 个非文档最终文件 SHA-256 冻结，构建期间未改变 | `evidence/repair1-final-source-freeze.json` |
| 反证配方 | 37 条锚点、次数、唯一 ID、精确 filter 均通过检查；36 个基线 filter passed，账户 Store 集成 filter 被沙箱阻挡。本轮反证编译／执行均 NOT_RUN。 | `counterexamples.json`；`evidence/repair1-counterexample-anchor-check.json` |
| prepared 只读检查 | PASS；60 个最终文件／7 组，基线、分支、范围、最终文件与产物 SHA-256、对原 index 可应用性均通过；未提交 | `logs/repair1-prepared-check.log` |

下面 22 个方法需要沙箱外复跑，保留现有 TestPreferenceDomain 与真实路径限制，未为沙箱失败改断言、跳过测试或放宽路径检查。完整逐方法错误在 JSON；可直接使用 `evidence/repair1-sandbox-blocked-filters.txt` 组成 filter。

| 类 | 受阻方法 | 直接原因 |
| --- | --- | --- |
| AppUpdateCoordinatorTests | `testConfirmedQueueRequestsQuitOnceAndRejectedRequestKeepsWaiting`；`testExecutionTimeWaitingStateMakesLaterTerminationEventRecoverable`；`testStoreRejectsBufferedTaskAndSnapshotEventsFromStaleSession` | NSCocoaErrorDomain 513／EPERM：ScanStore 隔离家目录 fixture 创建受阻 |
| AppUpdatePresentationIntegrationTests | `testAccountUnavailableIsSkippedInStoreReportAndNeverCountedAsFailure`；`testAllFailedBatchEntersFailedAndRetryUsesNewSession`；`testCancellationRequestIsVisibleBeforeQueueStops`；`testDismissingConfirmedPreviewDoesNotCancelRunningBatch`；`testFastAutoResumedQueueDrainIsBufferedBeforeRestoreMonitorStarts`；`testOneConfirmationExecutesEligibleItemOnceAndKeepsUnsupportedItemsVisible`；`testRestoredActiveQueueMapsToUpdatingPresentation`；`testScanLifecyclePublishesRealTotalsThenPreservesSummaryAcrossManagerNavigation`；`testSelectedRunningAndAuthorizationSurviveStoreGate`；`testTerminalRestoredQueueDoesNotDoubleFinalizeNextForegroundBatch`；`testUserUpdateRequestsStayPendingUntilConfirmationAndSeparateManualActions` | NSCocoaErrorDomain 513／EPERM：ScanStore 隔离家目录 fixture 创建受阻 |
| FeatureLightfieldApplicationPageTests | `testApplicationPagesKeepProductionSkeletonAcrossThreeStatesSevenSizesAndTwoSchemes`；`testLandingOptionIconsAre28PointsAndOnlyPrimaryStartsTheCheck` | NSCocoaErrorDomain 513／EPERM：ScanStore 隔离家目录 fixture 创建受阻 |
| SparkleReadOnlyProbeTests | `testShadowHostKeepsSparkleSettingsOutOfTheRealPreferencesFolder`；`testShadowHostLeavesTargetDefaultsUntouchedAfterCallerCancellation`；`testShadowHostLeavesTargetDefaultsUntouchedAfterTimeout`；`testShadowHostLeavesTargetDefaultsUntouchedForUpdateAndNoUpdate` | sandbox_extension_issue_file／CFPreferences 同步被 Operation not permitted 拒绝 |
| TestPreferenceHygieneTests | `testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`；`testTemporarySuiteCanBeReopenedOnAWorkerThread` | sandbox_extension_issue_file／CFPreferences 同步被 Operation not permitted 拒绝 |

主会话复跑本轮最终源码时使用 scratch 正本 23 个 filters（20 个完整类＋3 个指定方法，其中两个指定方法同属 SystemUtilitySafetyTests）；不要沿用首轮测试清单或成功计数。

```zsh
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export LC_ALL=en_US.UTF-8
SC_UPDATE_SCRATCH=/Users/developer/Developer/.sc-build/r2-update-all
SC_UPDATE_FLAGS=(--disable-sandbox -Xswiftc -disable-sandbox --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
SC_UPDATE_FILTER=$(paste -sd '|' "$SC_UPDATE_SCRATCH/targeted-classes.txt")
swift build "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/debug" --build-tests
swift test "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/debug" --skip-build --filter "$SC_UPDATE_FILTER"
swift build --build-system native -c release --build-tests -Xswiftc -enable-testing "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/release"
swift test --build-system native -c release -Xswiftc -enable-testing "${SC_UPDATE_FLAGS[@]}" --scratch-path "$SC_UPDATE_SCRATCH/release" --skip-build --filter "$SC_UPDATE_FILTER"
python3 "$SC_UPDATE_SCRATCH/prepared/commit-prepared.py" --check
```

本轮红／绿／反证证据分别为：首轮 full 的 5 个方法实际失败＋`non-newer-release` surviving；本轮其对应定向方法通过，所有 55 项新套件和 46 项 UI 守卫通过；37 项突变配方等待主会话执行。每项突变必须先编译成功，再运行其 filter 失败，恢复原文；仅编译错误不能算 killed。全量门禁与反证在本轮按 `codex-build-common.md` 未运行；应在沙箱外以注入实现完成，首轮全量／反证结果不能计入本轮通过。


真实签名打包／SMAppService 生命周期、密码框次数、sudo／MAS 账户／Homebrew installer、厂商服务和未保存文稿／重开链路均未执行；主会话须用假实现先完成全量与 37 项反证复跑，再另行决定真实验收。无 .app latest 缺少安装关联证据时仍显示待核验；Homebrew Team ID 变化只失败并保存证据，不能声称自动回滚了 brew 管理的包。

JEV 判断工具被 approval policy=never 阻止，未获得判断；本轮未把旧外部复核当成新源码已获复核。

## 修复轮 2（2026-10-12）

### 已读证据与两个存活反证

已读主会话 `logs/main-final-0056/` 的完整构建、定向、全量、Release 和 `mut/summary.json`，以及 `logs/codex-review2.log` 末尾 P1–R2–1…5、P2–R2–1…5。主会话上版定向 381 项／0 failures（4 skipped）、全量 5016／0、Release 带测试构建通过；37 条反证为 35 killed、2 survived。这些是修复轮 1 源码的外部证据，不能记为本轮源码已通过。原始日志不改写，摘要和完整复核快照分别保留在 `evidence/repair2-main-baseline.json`、`evidence/repair2-review-snapshot.md`；上版 prepared 原样保存在 `prepared-before-repair2/`。

两个存活项的根因与修正：

| id／原 filter | 原测试漏检原因 | 本轮对准边界的断言 |
| --- | --- | --- |
| `dmg-private-staging`／`AppUpdateArchiveRepairTests/testDMGCandidateCopiesWhileMountedAndDigestReachesProtectedHelper` | 归档 helper 假实现只检验复制顺序与摘要，没有直接拒绝返回挂载源路径。 | 比较实际 `path`（避开 URL 目录尾斜杠导致的不等假象）；候选必须与 mount source 不同、位于 `Candidate-` 私有 staging、不在 mount 树中；helper 在 detach 前实际收到私有候选及其冻结摘要，且该路径与挂载源分离；检查 mount→replace→detach 顺序。还原 `destination → source` 必须触发这些断言。 |
| `all-cask-artifact-quit`／`AppUpdateAllBatchTests/testRefusalInAnotherCaskArtifactSkipsWholePackageAndContinues` | 夹具把同包两个 app 都选中，清空 metadata 路径仍会从所选行补出两个路径。 | 只选择 A，B 仅出现在同一 cask metadata；B 拒绝正常退出。断言精确退出请求为 A、B，整包不执行 brew，后续 formula 继续且 B 不凭空成为结果行。清空全 artifact 集合时必须失败。 |

这两个加强后的基线方法在最终 Debug 定向均通过。依照 `codex-build-common.md` 的“**不跑全量和反证（主会话跑）**”，本轮未执行突变，不提前记为 killed；配方和判定条件已交付。

### 全部复核项的修复

| 复核项 | 最终实现与安全边界 | 对准边界的测试／反证 |
| --- | --- | --- |
| P1–R2–1 askpass | 服务端由 getpeereid、LOCAL_PEERPID、LOCAL_PEERTOKEN 取得内核 UID／PID／audit token，以活动 SecCode＋严格 SecStaticCode 核验精确 bundle 内 askpass 路径、标识、Team／冻结 cdhash；父进程必须为 /usr/bin/sudo。重复核验 PID＋启动时间。askpass 自身要求 sudo 父进程和 FIFO stdout，才连接。每个请求有随机一次性挑战，实际存活获批命令中的每个 sudo PID＋启动时间只可取一次，结束移除 allowance；不再有 512 全局额度。 | `Repair2` 的真实 socket peer／错误挑战／一次性挑战，注入签名与父进程；纯策略覆盖路径、Team、hash、父进程、PID 重用；registry 覆盖无关 sudo、Ruby、二次取用及根命令结束。真实 socket 的三个方法在沙箱 bind 被拒，保留原断言待外部复跑。 |
| P1–R2–2 摘要绑定 | ZIP 候选摘要在解码认证 manifest 字节时建立，包含条目类型、mode、链接目标、文件长度与字节 SHA-256，不以可变解包树重新选择预期值。DMG 在挂载内立即冻结候选摘要。复制与 staging 后续仅比较该值；可写与 root 事务在 swap 前后、删除旧包前复核，journal 保存 frozen SHA-256。旧无摘要 journal 不能据路径后验后删除旧包。helper capability 升 v2，阻止相同 build 的旧摘要能力驻留程序。 | `ArchiveRepair`：解包后／取路径摘要前替换树、检查后／swap 前替换 staging、swap 后与删旧前替换、legacy 无绑定 journal；真实 ZIP 解包字节绑定与 root 事务摘要守卫。 |
| P1–R2–3 回滚失败 | root 与可写目录均将清理交给事务状态；rollbackFailed 保留 staging、唯一旧 bundle 与 journal，记录旧包实际保留位置，结果带恢复路径且进入待核验。root helper 的生产清理复用共享事务清理；不再 defer 无条件删除旧包。 | `ArchiveRepair`：前向故障＋回滚 swap 本身失败、旧包搬移失败、完整可写 installer defer、共享 root 清理。断言真实旧内容仍在报告路径，journal 存在、状态 rollbackFailed。helper 回执恢复路径透传测试。 |
| P1–R2–4 命令树／缓存 | 进程表按 PID＋启动时间收集所有可见后代，不要求同组，已见后代重挂到 PID 1 后仍跟踪，PID 重用不杀。子进程 suspended 启动后先挂观察器，再继续；取消／超时／生产输出超限依次 TERM／KILL 每个仍属本次的身份并有界等待。覆盖不完整或 root／系统服务停不下来返回 needsReconciliation。按本机 sudo 手册每个需授权 brew 调用后及批次结束使用无密码 sudo -K，撤销全部用户 timestamp；验证后 sudo -k、mas sudo -A -k 保留。 | `Repair2` 注入跨组、重挂、PID 重用、读表失败；实际自建 printf／sleep 短命子进程覆盖生产输出超限、超时、取消。`AuthorizationRepair`／`AllBatch` 覆盖 brew 父进程缓存撤销、失败调用仍撤销；反证含跨组过滤、PID 身份及 -K→-k。 |
| P1–R2–5 待核验／重试 | reconcile 抛错、failed、仍旧版、未达目标、不带停止回执的 cancelled 一律保持 needsReconciliation。新增明确 confirmedStopped 回执，只有可信停止或已核验完成才解除。待核验拒绝 late failed progress 以及 queued／installing 转移；通用 Task CancellationError 不证明命令树停止。取消快照保存失败时不得 clear 尚含未知安装的持久化意图，避免重启后错误放开重试。 | `Repair2` 完整 coordinator 链：五种读回结果→保持待核验→retry 被拒、执行器仍只执行一次；可信完成／停止可终结；迟到失败事件不开放重试。原 coordinator 取消持久化方法改为断言旧安装意图仍保留。 |
| P2–R2–1 密码内存／XPC | 脱敏直接按字节匹配完整密码，临时输入／输出数组擦除，输出 String 在隐去后才建立；不为匹配重新构造完整密码 String。仅保证自有密码缓冲与主动管理的临时缓冲清零；Cocoa／Swift 输入副本不在保证范围。 | `Repair2` 重复密码、跨截断边界匹配；旧参数／环境／日志不含密码与取消／失败清零测试保留。系统授权服务与 App helper 的 XPC 边界详见下节。 |
| P2–R2–2 来源冻结 | 准备批次前冻结 brew／mas requested＋resolved 绝对路径、inode／device／owner／mode／SHA-256，检查两条父目录链并拒 group／world writable。授权框展示冻结绝对路径；list、upgrade、mas 执行前重新比对，漂移拒绝该组且不单项重试，不拖垮其他来源。PATH 顺序固定系统目录＋冻结 prefix/bin，无任意继承 PATH。 | `Repair2` 同 inode 内容变化、group-writable 文件／父目录、PATH；`AuthorizationRepair` prompt 之前已冻结 MAS，之后改变拒绝；`AllBatch` installing 前替换 Brew 来源，断言零 upgrade。假命令同时注入假执行身份，避免检测真实机器包。 |
| P2–R2–3 cask 有效目录 | 根据本机 cask/config.rb 的 default→saved env（缺失才 current HOMEBREW_CASK_OPTS）→saved explicit 优先级读取配置；支持全部 moved artifact、suite／appimage、prefix binary/man/completions，包含 keyboard_layout／mdimporter。精确 app 路径使用有效 appdir，suite 遍历其中实际 app。未知／无法解析配置或类型保守计需授权。 | `Repair2` saved／env／quoted custom appdir 优先级、所有 artifact 目录、受保护 keyboard_layout／mdimporter、未知配置授权、suite 嵌套 A／B app 收集。 |
| P2–R2–4 symbolic latest | HomebrewSymbolicVersion 统一空白／冒号／大小写判断，verify、reconcile、合并失败后的单项重试门使用同一实现；无 app 且无本次安装证据的变体全部待核验。 | `AllBatch` 对 latest、:latest、LATEST、:LATEST、:LaTeSt 逐项走执行／核验，断言不自动再次 upgrade、不开放 retry。 |
| P2–R2–5 反证质量 | 原 37 项保留，另增真实两次 move 的缺口注入；新增 41 项，总 78；指向真实 socket、解码字节、root／可写真实交换、回滚失败、注入进程表／实际短命子进程、完整 coordinator。各配方唯一锚点／次数／精确方法和 Swift parser 均检查，编译错误不能算 killed。 | `counterexamples.json`、`evidence/repair2-counterexample-check.json`；78 项 parser PASS，突变 typecheck／执行由主会话完成，状态明确 MAIN_SESSION_PENDING。 |

### 明确收窄的保证与运行限制

askpass 的 Team 签名必须与 App 一致；ad-hoc 情况，App 主可执行文件与 askpass 本来有不同 cdhash，因此以有效 App nested／resource seal 认证本批 bundled askpass 的冻结 cdhash，活动 peer 必须是该确切 cdhash，不能仅凭双方 ad-hoc 放行。恶意 brew／厂商后代直接运行正版 askpass 时，其父不是 sudo，被拒；其自行再运行 `sudo -A` 时，正版 sudo 可以取得批准的权限，只有 sudo 读到密码，脚本本身不取得明文。这与本批明确采用的终端 sudo 信任模型一致，不宣称禁止同用户脚本在已批准命令内调用 sudo。

动态响应 allowance 按实际内核观测到的 sudo 请求逐个创建，每个请求只响应一次，且根命令必须仍在该通道的批准集合；结束后移除。Homebrew Ruby 在运行时才决定要调用多少次 sudo，所以没有伪造固定的“每包一次”计数，也没有批次 512 次预分配额度。

NSSecureTextField 的 `stringValue`、Cocoa／Swift 临时副本不能主动保证擦除，异常终止与系统内存转储也不在清零保证内。代码清零的是自有 UpdatePasswordBuffer、主动管理的字节临时缓冲；不保存、不写日志／参数／环境／偏好／文件／钥匙串。`AuthorizationCopyRights` 接收包含密码的 AuthorizationEnvironment；按系统 Security 公开实现，该 environment 会经 XPC 送往系统授权服务，不能表述为“密码完全不进 XPC”。项目自己的特权 helper 只收到 AuthorizationExternalForm，不收到明文密码。

本机 SDK／内核头明确 NOTE_TRACK／NOTE_CHILD 从 macOS 10.5 起不支持，NOTE_FORK 不提供可枚举子 PID，且事件可合并。实现结合 kqueue 与进程表持续观察可见后代；一旦观察到 fork 且无法证明没有瞬间重挂／不可见后代，就将覆盖标为不完整，不把“原进程组空了”当作停止。安装命令此时保守待核验，可信只读读回的新目标版本可以完成；未知取消不能重试。无需特权的 read-only list/info/outdated/prefix／sudo 缓存操作只按可见树与 root 结束返回，不把它们当安装停止证据。该保守策略可能使真实 fork 型更新多进入待核验，这是无特权进程观察的明确限制。

`sudo -K` 为本机 sudo 手册规定的撤销全部用户 timestamp 操作，覆盖无终端时以 brew 父 PID 关联的缓存；代价是同时撤销其他终端的 sudo 缓存，原生授权说明已写出。需授权 brew 调用运行期间仍可能有缓存权限窗口，直到该调用后的 -K；批次结束再撤销。撤销缓存不终止已经运行的 root 命令或系统安装服务；停止／撤销失败仍不构成可信停止，保持待核验。未实际执行 sudo 来证明本机缓存结果。

只读 stat 发现本机 `/opt/homebrew/bin` mode 为 0775、owner 501，brew 文件为 0755；新来源规则会拒绝该 group-writable 父目录。本批没有 chmod 或修改真实 Homebrew 安装，也未把此来源的实际可用性记为已验收。必须在独立实机验收中明确处理这项来源条件。

### 本轮改写的旧断言与夹具

| 测试 | 原断言／夹具 → 本轮断言／夹具 | 依据 |
| --- | --- | --- |
| Coordinator／testStateMachineRejectsTerminalAndOutOfOrderTransitions | needsReconciliation→installing 可转移 → installing／queued 都禁止，只允许 verifying 与可信终态 | P1–R2–5：未知安装不得重新执行。 |
| Coordinator／testQueueCancellationStopsActiveExecutorAndMarksRemainingItemsCancelled | 阻塞假执行器抛 CancellationError 后 active 项 cancelled → active 项 needsReconciliation；尚未执行项仍 cancelled | Task 取消不等于命令树停止回执。 |
| Coordinator／testExplicitCancellationKeepsOldIntentWhenPendingCancellationCannotBeSaved（原 testExplicitCancellationClearsOldSnapshotWhenSavingCancelledStateFails） | 保存取消状态失败就 clear 旧 snapshot → 抛 cancellationPersistenceFailed，保留旧 installing intent，当前待核验 | 防止持久化失败／重启后再启动未确认停止的安装。 |
| Coordinator／testExplicitCancellationThrowsWhenSavingAndClearingSnapshotBothFail | 当前 active cancelled → needsReconciliation，仍抛持久化错误 | 未知停止时不进入 clear 分支；不删除断言。 |
| OfficialSecurity／Coordinator recovery fixtures | 有候选路径和版本的 journal 足够 → 写入候选最初认证 SHA-256，随后才能故障修改 | 新摘要合同；旧未绑定 journal 另加保留旧包测试。 |
| ModelsScanningProvider／testHomebrewInventoryScannerDefaultsToNonGreedyOutdatedQuery、testHomebrewInventoryScannerKeepsPlainAndGreedyQueriesSeparate | 依赖本机 brew 可执行来源、找不到则 skip → 通过已有 fileManagerFactory 注入受信任 0755 fake 来源，命令仍全部假实现 | 新 group-write 门不能令命令形状测试失去覆盖；未新增 skip，原命令断言保留。 |
| DMG／多 artifact 两项 | 弱顺序断言／两个 artifact 都选中 → 精确私有 path、只选择 A 而拒绝 metadata-only B | 杀死已知存活反证，详见本节开头。 |

两个 recovery fixture 的预期摘要都在任何 fixture 破坏前计算；不能在注入替换之后重新选择预期值。新增 Suite 测试对双方路径同时做系统符号链接规范化，仅处理 `/var` 与 `/private/var` 别名，未放宽产品 containment 检查。所有密码／签名／文件身份／过程表假实现都显式注入，不读取钥匙串或执行真实升级。

### 本轮最终验证与交付

| 检查 | 本轮实际结果 | 日志／证据 |
| --- | --- | --- |
| 最终 Debug 构建，含测试 | PASS，28.14 s | `logs/repair2-debug-final-build.log` |
| 最终 Debug 定向 | 417 项：388 passed、25 failed methods、4 skipped；27 失败断言（19 unexpected），均为下述沙箱限制，退出 1 | `logs/repair2-targeted-debug-final3.log`；`evidence/repair2-targeted-results.json` |
| 新批次／归档／授权／Repair2／Sparkle／厂商核心类 | 91 项：88 passed、3 socket methods blocked；AllBatch 25／ArchiveRepair 18／AuthorizationRepair 15／Repair2 21／Sparkle 8／Vendor 4 | 同上 |
| UI 一致性 | 46／46 passed，0 skipped | 同上 |
| 最终 Release 带测试构建，native | PASS，565.78 s；`-c release --build-tests -Xswiftc -enable-testing`，未降低优化 | `logs/repair2-release-final-build.log` |
| 最终 Release 核心＋UI 定向 | 137 项：134 passed、3 socket methods blocked、0 skipped；退出 1 | `logs/repair2-targeted-release-final.log`；`evidence/repair2-release-targeted-results.json` |
| 私有 API／打包脚本／diff | PASS：7 allowlisted uses、bash -n、git diff --check | `logs/repair2-private-api.log`、`repair2-packaging-syntax.log`、`repair2-diff-check.log` |
| 源码冻结 | 68 个非文档文件 SHA-256，最终 Debug／Release／定向后仍匹配 | `evidence/repair2-final-source-freeze.json` |
| 反证 | 78 配方锚点／次数／精确方法／Swift parser PASS；62 个唯一基线 filter 中 59 passed、3 blocked（72／6 配方；5 条 askpass socket 配方＋1 条账户报告配方）。突变 typecheck／执行 NOT_RUN，不能记 killed | `counterexamples.json`；`evidence/repair2-counterexample-check.json` |
| prepared | 70 个最终文件／7 组；只读基线／分支／范围／SHA-256／原 index 可应用性核验，结果见 manifest | `prepared/manifest.json`；`logs/repair2-prepared-check.log` |

Debug 定向的 25 个失败方法中，22 个为前轮已记录的家目录／CFPreferences 沙箱阻挡，逐方法完整清单见 `evidence/repair2-sandbox-blocked-filters.txt`，未为了沙箱改为 skip 或放宽路径。新增的三个方法均在生产 UpdateAskpassChannel 的 bind 处被 POSIX EACCES 拒绝：

- `AppUpdateRepair2Tests/testRealSocketPeerRejectsWrongExecutableSignerAndNonSudoParent`
- `AppUpdateRepair2Tests/testRealSocketChallengeIsOneUseAndFinishErasesCredential`
- `AppUpdateRepair2Tests/testWrongOneUseChallengeNeverReleasesPassword`

这三个方法保留真实 socket／内核 peer 读回，签名、父进程及权限策略通过注入实现测试；不能把纯策略通过当成真实 socket 已验证。需主会话在沙箱外用同一源码、同一方法复跑，不执行真实 sudo。现有四个 skip 未增删，debug 定向进程退出 1，不能称为全绿。

prepared 仍按七组：01 helper／共享合同与事务／AuthorizedApplicationMover 生命周期；02 更新引擎／密码通道和来源冻结；03 界面；04 测试；05 ScanStore 最小例外；06 D78／交接；07 签名 askpass 打包。ScanStore 本轮无新增改动，继续将前轮三处必要例外单列：授权成员计数、账户 skipped 汇总、重试新批次监视绑定。补丁范围包括 helper／Shared／打包脚本是完成指定安全边界所必需，未混入其他批次文件。D78 替代本批所有旧 D77 代码、测试与决定引用；文档中 D76／D77 仅作并行编号归属说明，历史日志／备份不改写。

主会话复跑使用 scratch 最新 `targeted-classes.txt`（24 filters，新增 Repair2 类）；上节已给构建命令。除 Debug／Release 带测试构建和本轮定向外，还需完成最终全量、78 项突变逐项编译＋精确 filter 测试与只读安全复核。每项突变必须编译成功、指定方法实际失败，才算 killed；编译错误和沙箱拒绝不能替代边界断言失败。`commit-prepared.py --check` 仅只读校验，未提交或修改 index。

没有运行真实 brew upgrade／mas upgrade／sudo／installer／hdiutil，未启动 App、未下载网络内容、未读钥匙串、未安装／push／提交。只使用隔离 fixture 与本进程创建的 printf／sleep 短命子进程做生产命令边界测试。签名打包后的活动 SecCode、sudo 父进程、真实密码框次数、SMAppService 旧 helper 更新、MAS 登录账户、Homebrew installer、文稿拒绝退出／重开和真实软件更新均未验收。构建与 mock 测试不能提升为“一键更新全部”实机已达标。

JEV 判断工具本轮调用被自动审批拒绝（工具要求 approval，当前 approval policy=never），未返回判断；没有更换模型或宣称获得其复核结论。

## 修复轮 3（2026-10-12；增量基线 96c167bd）

本节覆盖前版关于 fork 完成、未决队列裁剪、group-write 全拒，以及“脚本本身拿不到明文”的表述。先完整读取 `logs/main-final-0310/` 的 build／targeted／full／mut／release 日志与反证 summary，以及 `logs/codex-review3.log` 末尾完整复核。该主会话定向与全量是在 96c167bd 之前因 SIGPIPE 中断，不能写成通过；79 条反证中的五条 askpass 崩溃结果、一个编译错误、一个 0 锚点和一个 survived 均按无有效保护结果处理。只读复核对象为 3c86c360，当前修复基线为其后的 96c167bd。

完整保留此前九个提交：5e97d1bc、bd93abe8、ee7c2b27、15ada265、dce0c1e7、5df16da0、134ec78e，以及主会话 3c86c360、96c167bd。没有 reset、改写提交或暂存区。admin 组来源规则、服务端 accepted socket 清除 O_NONBLOCK、测试客户端 SO_NOSIGPIPE 都保留；本轮没有改 Shared／helper／askpass 打包或 ScanStore。旧 prepared 在 `prepared-before-repair3/`，新 prepared 只含 96c167bd 之后的 15 文件／四组增量。

### 复核项与数据流修复

| 项目 | 本轮结果与依据 | 对准边界的测试／反证 |
| --- | --- | --- |
| P1–R3–3 正常 fork 完成 | `CLD_EXITED` 与取消／超时／超限分流。正常退出不向树发停止信号，已观察到仍存活的后代最多等待 stopTimeout（默认 3 秒）；随后立即做可信核验。全部达到目标则 completed、按原运行状态重开；已确认旧版／身份变化／未达目标为普通失败，无法读回结论才 pending。若等待结束后仍确认有存活安装后代，旧版／未达目标只是当前快照，不能给出最终失败结论，仍 pending；达到目标仍完成，不受仅观察到 fork 的影响。fork 覆盖不完整只限制停止回执，不能把正常成功一律 pending。 | Repair3／testNativeForkNormalExitCompletesAndReopensEveryOriginallyRunningArtifact 用自己的短命 sh／sleep；testNativeForkCancellationRemainsPendingEvenWhenReadbackAlreadyReachedTarget；testNormalParentExitWaitsForLiveOwnedDescendantWithoutSendingTermination 用实际 printf 加注入进程观察器记录每个信号和等待；testKnownLiveDescendantAndOldReadbackCannotAuthorizeConcurrentRetry、testMasKnownLiveDescendantOldVersionKeepsRecoveryPending；`live-descendant-old-readback-remains-pending`、`mas-live-descendant-old-readback-remains-pending`、`normal-fork-not-pending`、`normal-parent-must-not-signal-live-child`、`normal-parent-waits-live-descendant`、`fork-cancellation-is-not-normal-success`。 |
| P1–R3–2 跨批次隔离 | 重试 B 的新 session 保留 pending A；A 放进非执行 plan bucket，仍保留其 pending 状态和 originalSessionID。新批次带上未决任务；全新 coordinator 的 start 先读持久化意图，将旧 installing／verifying 转 pending，防止未 restore 就覆盖。按原 ID、冻结包 kind＋token、精确原路径隔离新扫描行。取消新批次不修改旧 pending 的恢复原因。 | Repair3／testMixedPendingAndFailedRetryPreservesQuarantineAcrossRestartRescanAndFreshBatch 覆盖 A pending＋B failed → 重试 B → 从同一 JSON 文件重启 → 同包新 ID／新路径被拒 → 新 C 批次仍保留 A；testFreshCoordinatorWithoutRestoreCannotOverwritePersistedPendingIntent；`retry-preserves-pending-other-item`、`fresh-start-loads-unresolved-intent`、`fresh-batch-carries-unresolved-intent`、`pending-package-token-isolation`。 |
| P1–R3–1 终端信任残余风险 | 按主会话决定不追加认证角色实现。保留真实 peer／精确 bundled path／活动签名／冻结 cdhash／sudo 父进程／stdout 管道／一次性挑战／动态请求 allowance。明确接受：**批准的 Homebrew 命令及其脚本与在终端输入密码运行 brew 同等信任；其后代可借用 askpass 取得口令。** 原生授权框同步“这些命令及其安装脚本将获得管理员权限，等同于在终端输入密码”。不再保证明文只抵达 sudo 的专用认证管道。 | D78、AppUpdateBatchAuthorization 原生提示及本节；不以纯策略测试或签名检查宣称解决被主会话接受的认证角色风险。 |
| P2–R3–1 整包恢复核验 | 增加可 Codable 的 recoveryEvidence，安装前持久化全部受影响 artifact 的原始身份、版本、运行状态与包元数据。Homebrew 正常安装／恢复共用同一个 verify 实现；不能拿新的 scan 版本／更短 artifact 列表代替原始证据。恢复也逐路径检查有效签名、Bundle ID、同 Team ID、严格升版和选中目标版本。无完整证据的旧 GUI cask 意图保持隔离；无 app 的旧 formula／cask 仍可用注入的可信 package readback。 | Repair3／testReconciliationRejectsUnselectedArtifactOldVersionAndChangedIdentityDespiteShorterRescan 覆盖 A 已升、未选中 B 旧版／Team／Bundle ID 改变；testFrozenArtifactBaselineCannotBeReplacedByPreExecutionRescan；testRecoveryEvidenceIsPersistedBeforeMergedInstallationBegins；`reconciliation-whole-package-artifacts`、`reconciliation-original-artifact-version`、`reconciliation-artifact-bundle-identity`、`frozen-baseline-pre-execution-drift`、`freeze-artifact-evidence-before-effects`。 |
| 重开持久化与 mas | pending 项保留原运行应用清单；从保存的证据进行完成核验后再重开，逐份保留成功／已在运行／失败原因。保存的 reopenOutcomes 避免下一次恢复重复发起已记录的重开。mas 的正常退出收据同样读回版本／身份并重开，未知取消保持 pending；不调用真实 mas／sudo。 | Repair3／testPersistedPendingArtifactReopenListSurvivesRestartAndReconciliationReopensEachCopyOnce 用实际隔离队列 JSON、无 scan row 恢复和第二次读回；testMasNormalExitReceiptVerifiesVersionAndReopensButCancelledForkRemainsPending，取消后通过 JSON roundtrip、nil row 恢复重开；`pending-reopen-list-is-persisted`、`reconciliation-reopens-all-original-copies`、`reopen-outcome-survives-second-readback`、`mas-normal-exit-readback`。 |
| P2–R3–2 admin 来源例外 | 保留 `AppUpdateSourcePermissions.isTrusted`：root／当前用户 owner，禁止 world-write、非 admin 组写；gid 80 的 admin 组写适用于来源文件及检查的祖先。默认 capture 仍读取真实 stat／目录属性；仅通过注入 stat reader 测试两条祖先链，无真实 chmod／chown。D78、代码注释、错误说明和授权框都明确这是信任本机 admin 可修改来源的取舍，不能据此推导口令保密或冻结全部脚本依赖。 | 主会话 testStandardHomebrewAdminGroupBinIsTrustedButOtherGroupWriteIsNot 保留；Repair3／testCaptureTrustsAdminWritableAncestorsInBothBinAndResolvedCellarButRejectsOtherWrites 同时走 bin 链及 symlink 解析后的 Cellar 链，admin 正向、其他组写／world-write 负向；`group-writable-source` 突变 isTrusted 的核心规则，`homebrew-admin-group-rejected` 保留主会话第 79 项，`capture-follows-admin-cellar-ancestor`。 |

新私有 ExecutorArtifactRechecker 使用执行器同一个可注入 metadata／签名 reader，生产默认仍由 Security 严格核验；避免测试意外落入真实签名检查或真实命令。Homebrew execute／reconcile 的命令始终由注入 HomebrewCommandRunning 负责；正常失败退出后仍先核验新版本，已确认完成的包不能因退出码或 fork 误入重试。所有真实短命子进程都是本测试创建的 sh／sleep／printf；跨进程组与 PID＋启动时间原守卫保留。

### 失效反证配方的修订

`counterexamples.json` 现为 **101 项**。本地旧副本是 78 项，另恢复主会话的 `homebrew-admin-group-rejected` 第 79 项，并新增 22 项；不是删除原记录来降低数量。

- `askpass-exact-peer-path`、`askpass-live-peer-signer`、`askpass-live-peer-cdhash`、`askpass-sudo-parent`、`askpass-one-use-challenge` 保留真实 socket／内核 peer filter 和现有 SO_NOSIGPIPE，锚点及基线方法已重新审计。沙箱在生产 bind 处 EACCES，仍须主会话外部跑，不能把上次 SIGPIPE 或本次 EACCES 记 killed。
- `askpass-live-command-binding` 改为突变实际批准祖先查找分支，错误允许从批准集合任取根；不再在同一作用域重新声明 bound。独立编译实际突变 registry＋UpdateProcessIdentity.swift 的 typecheck PASS，日志 `logs/repair3-askpass-binding-static-typecheck.log`；基线精确方法 PASS。
- `group-writable-source` 不再依赖已经删除的 0o022 锚点，直接突变 `AppUpdateSourcePermissions.isTrusted`，纯策略方法同时抓到非 admin 组写与 world-write 的放行；admin 例外另有正向反证。
- `pending-requires-stop-receipt` 改到 Repair3／testLateCancellationReplyWithoutStopReceiptCannotClearCoordinatorPendingIntent：先进入 installing，coordinator.cancel 把它改 pending，再收执行器无回执的 late cancelled result，必须仍 pending、retry 被拒。它直接到达 applyExecutionResult 的守卫。另有可信停止回执可解除的正向测试，不依赖 reconcile 的前置过滤挡住坏结果。
- `no-reopen` 迁到统一 recoveryEvidence.reopening 的实际 reopen 调用；`late-cancel-readback` 对齐新取消条件。整包、版本、路径、摘要、回滚及两条前轮 DMG／artifact 反证都继续保留。

101 配方均核对精确次数、替换后完整 Swift parser 和 filter 方法存在；77 个基线 filter 中 74 passed、3 blocked：两个真实 socket filter 对应 5 条 askpass 配方，另一个账户报告 filter 对应 1 条注入 executor 配方；合计 95／6 配方。这里只做静态配方准备，没有运行产品突变；独立类型检查不替代主会话每条完整突变构建及测试。编译错误、anchor 0、崩溃和沙箱拒绝都不算 killed。证据为 `evidence/repair3-counterexample-check.json`、`repair3-counterexample-baseline-results.json`。

### 旧断言／夹具逐条变化

| 方法或共用夹具 | 原 → 本轮 | 原因 |
| --- | --- | --- |
| FreshActualTarget／testEveryExecutableProviderExecutorRechecksActualTargetBeforeAndAfter | Homebrew 两次读 → 三次（安装前冻结整包证据＋原 preflight＋原 postflight）；官网仍两次 | 新持久恢复基线必须在 effect 前获得；没有减弱原两次实际目标核验。 |
| FreshActualTarget／testEveryExecutableProviderRejectsSameVersionChangeBeforeAndAfter | Homebrew 前／后篡改读取 1／2 次 → 2／3 次；官网仍 1／2 | 同上；原 identityChanged 和命令调用次数断言全部保留。 |
| FreshActualTarget／testHomebrewReconciliationDoesNotAcceptNewerDifferentArtifactAsActualTarget | 旧 GUI intent 无原 artifact 清单，读取单个 app 后 versionDidNotChange → 在任何读回命令前 applicationNoLongerEligible、无签名读回 | 缺失原全包基线不得从新扫描补齐；新的 Repair3 三种未选中 B 反例覆盖有完整证据的恢复链。 |
| Coordinator／testReconcileUsesPersistedOriginalVersionInsteadOfFreshScanVersion | task 只保存单项身份／版本 → 添加原 artifact 证据并注入 installer 读回 | 仍断言 fresh scan 的 2.0 不能改写原 1.0 基线，目标 2.0/200 完成。 |
| Coordinator／testReconcileRejectsChangedOnDiskSigningIdentity | 单 app executor identityChanged → 同一整包 installer 的 Homebrew.UpdateIdentity，且错误必须含 TEAM123 → OTHERTEAM | 持久 artifact 身份不随新 scan 更新；错误保留逐路径证据。 |
| Coordinator／testFormulaReconciliationQueriesOnlyThePlannedHomebrewToken | fake info JSON／info --json=v2 → 注入 list --versions --formula example／标准行输出，formula packageKind 设为 commandLineTool | 普通执行与恢复共用整包 list 规则，仍严格只查询原 token，仍断言最终 2.0。 |
| Coordinator／testReconcileRejectsChangedVersionBelowFrozenTarget | 同上 info JSON → 注入 list 行 1.5 | 原 targetVersionNotReached 的 expected 2.0／observed 1.5 断言保留。 |
| AllBatch／BatchTestState 共用失败夹具 | 任意 NSError 模拟已退出 brew → 生产 AppUpdateCommandError.failed(1, …) 收据 | 明确区分普通命令失败与无法给出停止／读回结论；bad 仍 failed，其他 token 继续成功，原调用次数断言保留。 |

没有删除断言、新增 skip、调整阈值或放宽产品路径检查。无证据默认 fake executor 不新增空 evidence 的持久化写入，原“保存在安装之后失败仍通过恢复、不能重新执行”的故障计数测试维持原断言。

### 最终验证、交付与剩余验收

| 检查 | 修复轮 3 实际结果 | 证据 |
| --- | --- | --- |
| Debug 带测试构建 | PASS，26.26 秒 | `logs/repair3-debug-final-build.log` |
| Debug 完整定向清单 | 435 项：406 passed、25 failed methods、4 既有 skipped；27 失败断言（19 unexpected），退出 1；失败方法集合与修复轮 2 完全相同，新增产品失败 0 | `logs/repair3-targeted-debug-final.log`、`evidence/repair3-targeted-results.json` |
| 本轮新增 Repair3 | 17／17 passed | 同上，包括正常 fork、取消 fork、混合重试／重启、持久整包／重开、mas 与来源权限 |
| UIConsistencyRegressionTests | 46／46 passed | 同上 |
| Release 带测试构建（native） | PASS，364.10 秒；优化级别未降低 | `logs/repair3-release-final-build.log`；`-c release --build-tests -Xswiftc -enable-testing` |
| Release 核心＋UI 定向 | 155 项：152 passed、3 socket methods blocked、0 skipped；3 失败断言，退出 1；Repair3 17／17、UI 46／46 passed，未出现 SIGPIPE 崩溃 | `logs/repair3-targeted-release-final.log`、`evidence/repair3-release-targeted-results.json` |
| 静态反证 | 101 项锚点／次数／方法／Swift parser PASS；askpass command binding 独立 typecheck PASS；突变执行 NOT_RUN | `evidence/repair3-counterexample-check.json` |
| 私有 API／diff／源码冻结 | 7 allowlisted uses PASS；diff PASS；13 个非文档最终文件 SHA-256 冻结，构建后复核 | `evidence/repair3-final-source-freeze.json`、prepared static-checks |
| prepared | 15 文件／四组，当前 HEAD 96c167bd 增量；只读原 index 可应用性和最终 hash 检查 | `prepared/manifest.json`、`logs/repair3-prepared-check.log` |

25 个失败方法完整列在 `evidence/repair3-sandbox-blocked-filters.txt`：22 项是家目录／CFPreferences 的既有沙箱拒绝，另外三个真实 socket 方法在 UpdateAskpassChannel.bind 处 EACCES，未出现 SIGPIPE 崩溃。不能把纯策略通过称为真实 socket 已验证。四个既有 skip 未改。

本机 admin 来源例外是**信任本机管理员可修改来源的明确取舍**，并非“admin 已获 root”或“整个 Homebrew 脚本／依赖树冻结”。终端信任 residual 也不能被 peer 检查掩盖：批准的后代可以借用 askpass 取得口令。清零只覆盖自有 UpdatePasswordBuffer／主动字节缓冲；NSSecureTextField 内部 String／Cocoa 副本无法主动保证擦除。AuthorizationCopyRights 的 environment 会经 XPC 送往系统授权服务，自己的 helper 只接收 external form。sudo 缓存撤销不终止已开始的 root／系统安装，运行期缓存与已批准管理员脚本窗口依旧按前节说明存在。

新 prepared 分四组：01 recoveryEvidence／coordinator／统一 installer／executor；02 正常退出、可注入树观察、来源 capture／原生授权说明；03 新测试和既有夹具接口调整；04 D78／交接。`commit-prepared.py --check` 只读，不暂存、不提交。主会话使用最新 `targeted-classes.txt`（25 filters）按 `_prompts/codex-build-common.md` 的命令外部复跑定向、全量及 101 条逐项完整构建＋精确反证，尤其 5 条真实 askpass socket 配方，以及 1 条账户报告配方（分别按 recipe／filter 记录，账户报告没有 socket）；随后只读安全复核并 `--validated` 按 manifest 顺序提交。该提示明确“**不跑全量和反证（主会话跑）**”，本轮没有越过此执行边界。

没有运行真实 brew／mas／sudo／installer／hdiutil，不启动 App，不读钥匙串，不下载网络内容，不改真实 Homebrew 或 /Applications，不安装、不 push、不提交。编译与注入测试不能代表实机全部更新达标；签名 bundle 内的活动 SecCode／真实 sudo、密码框次数、旧 helper 部署、App Store 账户、真实更新、文稿拒绝退出与重开均仍需实机验收。

JEV 判断调用被自动审批拒绝，原因是工具要求批准、当前会话 approval policy 为 never；本轮未取得 JEV 判断，不声称获得其复核结论。

## 修复轮 4（2026-10-12；增量基线 25c701b2）

本节覆盖上一节正常退出、完成、恢复解除、旧记录范围和损坏队列的边界。先完整读取主会话 logs/main-final-0509/ 的 build／targeted／full／mut/summary.json／rebuild／release-build，以及 codex-review4.log 末尾三个 P1 和两个 P2。修复轮 3 的外部结果为定向 435／0、全量 5070／0（25 skipped）、101 条反证全 killed、Release 带测试构建通过；这些只证明上版源码。原始日志不改写，摘要和完整复核保存在 evidence/repair4-main-baseline.json、repair4-review-snapshot.md。

当前 HEAD 为 25c701b27f67ee5d9f16a16639c67f04dba1e098，前十三个提交完整保留：5e97d1bc、bd93abe8、ee7c2b27、15ada265、dce0c1e7、5df16da0、134ec78e、3c86c360、96c167bd、ba8c15bd、2e0e18a3、74659dd1、25c701b2。没有修改 index、reset、提交或 push。admin gid 80 例外、accepted socket 清除 O_NONBLOCK、测试 SO_NOSIGPIPE 未变。旧 prepared 备份为 prepared-before-repair4/；本版只交付 HEAD 之后的 19 文件／五组。

### 全部复核项与最终边界

| 复核项 | 修复与理由 | 测试／反证 |
|---|---|---|
| P1-R4-1 跟踪不完整 | Native tree 冻结 trackingComplete、knownProcessesAlive、PID＋启动时间；normalExit 收据包含这些字段，正常退出不发送停止信号。空的已观察存活集合不代表覆盖完整。负向读回且覆盖不完整／仍有已知后代时保持 pending，合并 brew 不立即单包重跑。 | Repair4 的实际自建短命 fork 收据＋注入漏记观察器；两 token 合并、旧版读回只执行一次；normal-receipt-keeps-fork-tracking-integrity、normal-runner-keeps-completion-receipt、incomplete-tracking-cannot-authorize-token-retry、merged-brew-fallback-requires-complete-stop。 |
| P1-R4-1 达标但未结束 | 首次读回达标后，仍存活的已知后代再等待默认 60 秒、可注入／最大 120 秒；不发信号。退出后再次核验整包或 MAS 原目标；回退不能完成。超时记 completed＋installationIsolated，保留原运行状态和进程身份、不重开，显示“安装程序仍在收尾，稍后再打开”，恢复监视／新批次／重试／clear 均保留隔离。无存活后代的可信达标仍正常完成，未退回任何 fork 都 pending。 | Brew／MAS 后代仍存活、后代退出、退出后回滚三条链；completed-but-finishing 持久化、重启／同包别名／重试另一项；二次读回、重开、持久隔离、裁剪和清除反证。 |
| P1-R4-2 旧包范围 | 旧 Homebrew 未决记录缺 homebrewMetadata 时隔离整个 Homebrew provider：不同 Bundle ID 的同 cask、不同 formula 都不能进入新批次，MAS 可用。原证据缺失不会以新扫描补齐。 | testLegacyHomebrewIntentQuarantinesDifferentBundleAndFormulaButNotMas；legacy-homebrew-intent-isolates-entire-provider。 |
| P1-R4-3 安全解除 | 页面恢复入口现按修复轮 5 统一名为“核验并恢复 / Verify and Recover”，会处理恢复事务，需明确确认；本表保留轮 4 的安全解除策略。检查冻结身份不存活和系统无 brew／mas／installer／softwareupdate 相关进程，再读冻结原版／目标；读回后再检查一次进程。达标完成＋按原运行状态重开；停止但未升版／目标未达／旧 GUI 缺原证据则 failed＋confirmedStopped，解除隔离，可建立新授权批次。仍有安装进程／表不可读／取消核验则保持 pending，回滚事务恢复失败仍保留。 | 停止但旧版→自动恢复仍 pending→显式解除→新批次重试；旧 GUI 无证据可解除；全局四类安装进程、已知身份、PID 重用、zombie、读回时出现 installer。 |
| P1-R4-3 旧 formula | 以 task.originalVersion／冻结 packageVersionsBefore 作安装前基线；新扫描 installedVersions=2.0 不能把原版 1.0 改成 2.0。实际 2.0 达冻结目标即完成。 | testLegacyFormulaUsesFrozenOriginalVersionDespiteFreshScan；legacy-formula-readback-uses-frozen-original。 |
| P1-R4-3 解释器 | proc_pidpath 可能只返回 bash／Ruby。只读 KERN_PROCARGS2 前八个 argv 识别 brew 脚本和 Homebrew/brew.rb，不解析环境、不执行、不输出命令行；内核读取缓冲擦除，重新核对 PID＋启动时间。解释器 argv 无法读取则保守继续隔离。 | 注入 shell／Ruby argv、未知 argv 的边界；release-must-detect-interpreted-brew、release-cannot-trust-unreadable-interpreter；测试不调用真实 brew／sysctl 进程读回。 |
| P2-R4-1 队列损坏 | JSON 解码／不支持 schema 时先保存私有确认标记，再同目录原样改名到带毫秒时间戳＋UUID 的归档，不删除／重编码原字节。重启继续隔离 Homebrew；页面展示原因、保留路径和“我已确认没有正在进行的更新 / I confirm no update is in progress”，有确认对话框；队列时间、扫描告警或页面阶段改变即刷新恢复提示，不必重新进入页面。确认只归档标记，原数据和可读取的有效未决项保留，之后允许空队列／MAS 队列继续。 | 损坏二进制 JSON 原字节与同目录归档、重启前后阻挡、确认后执行；schema 999、MAS 可用、有效 MAS 队列不被确认裁剪；原样 rename、字节绑定、marker 持久、准入守卫和确认不删原归档反证。 |
| P2-R4-2 证据类别 | 修正上一节及旧聚合描述，逐 recipe／filter 写 category、test_boundary、基线失败原因、静态准备与突变结果。未把注入账户报告算 socket。 | 5 条真实 askpass socket 配方＋1 条账户报告配方；详情见下节与 evidence/repair4-counterexample-baseline-results.json。 |

恢复时的全局进程检查是瞬时只读证据，并非系统范围的安装锁；新安装可能在检查后由其他程序发起。已经记录的每个身份按 PID＋启动时间检查，读取失败不当作不存在，zombie／PID 重用不阻止解除。内核进程表和解释器 argv 无法完整读取时保守保持隔离，页面保留可重试核验入口。正常安装完成的目标读回不因无关更新器而阻断；只有恢复解除使用全局检查。

### 必要的 ScanStore 最小例外

原任务允许确需修改时把最小改动单列补丁。04-scan-store-minimal-recovery-bridge.patch 仅新增三个桥接方法（读取恢复状态、核验并发布现有队列、确认损坏记录），并把恢复监视、新批次前 clear、旧 relaunch 路径三处守卫纳入 completed-but-isolated。理由是现有 coordinator 为 ScanStore 私有成员；页面不能另建 coordinator，且旧 relaunch 和清除路径不能绕过新隔离标记。其余扫描逻辑、卸载／清理、真实路径准入不改。增量为 25 插入／2 删除；所有新增界面文字有中文＋英文 L10n，沿用 AppButton.secondary／theme／tokens。

### 改写的旧断言与夹具

| 方法／范围 | 具体变化 | 依据 |
|---|---|---|
| Repair3／testNormalExitWithLiveDescendantReceiptStillUsesImmediateReadbackAndNeverRetries | 原先读回达标就保存 2 个 reopenOutcomes，改为 0，并新增 installationIsolated=true 与全部原 running 状态仍保留的断言。 | D78／P1-R4-1：存活后代超时可 completed，但不能重开或解除隔离。没有删除版本／身份核验断言。 |
| Repair3／MAS normal-exit 成功夹具 | 旧 normalExitAwaitingVerification 无身份收据改为携带实际冻结假 PID＋启动时间的 normalExit 收据；假进程表显示该身份已退出，二次读回成立，原 completed／reopen 断言保留。 | 旧无身份 live 收据不能证明退出；可证明退出的新收据才能重开。 |
| Coordinator 11 个构造点／FreshActualTarget helper／Repair3 MAS／Vendor UnknownTarget | 注入空的假进程表，或明确存活／退出的假表；断言不变。 | D48：恢复解除不能读宿主真实安装进程，测试结果不能依赖主机进程状态。FreshActualTarget 按 provider 枚举预期错误仍保留。 |
| 其他旧测试 | 未删除安全断言、未放宽阈值、未新增 skip。 | 旧 4 skipped 和沙箱拒绝保留，由主会话外部跑。 |

修复中的 Debug 构建失败／夹具失败日志保留：build2 是测试访问／可选问题，build4 是 @Sendable 闭包中的 throwing 推断；修正后重新编译。focused3 曾在 build4 未成功后误用旧 --skip-build 产物，明确为失效的迭代记录，不能作为完成证据。完整定向发现的 Vendor UnknownTarget 失败源自缺假进程表；加入注入后不改原断言并用 final2 全集重跑。恢复后 retry 仍暂停的产品问题由新测试暴露，修复为建立新批次时清除旧 paused 标记，保留未决任务、重新要求授权。

### 最终冻结源码的验证

| 检查 | 本轮结果 | 证据 |
|---|---|---|
| Debug 带测试构建 | PASS，16.95 s，swiftbuild，最终 17 个源码／测试文件 SHA-256 冻结 | logs/repair4-debug-build-final3.log；evidence/repair4-final-source-freeze.json |
| Debug 定向 26 filters | 455 项：426 passed、4 skipped、25 个方法被沙箱阻挡，27 失败断言（19 unexpected）；退出 1，产品失败 0；失败方法与修复轮 3 完全相同 | logs/repair4-targeted-debug-final3.log；evidence/repair4-targeted-results.json |
| 新 Repair4／Repair3／UI | 20／20、17／17、46／46 passed | 同上 |
| Release 带测试构建 | PASS，338.16 s，native，-c release --build-tests -Xswiftc -enable-testing | logs/repair4-release-build-final3.log |
| Release 核心＋UI | 175 项：172 passed、3 个真实 socket 方法 bind EACCES、0 skipped、3 unexpected；退出 1，产品失败 0；新 Repair4 20／20、Repair3 17／17、UI 46／46 passed | logs/repair4-targeted-release-final3.log；evidence/repair4-release-targeted-results.json |
| 私有 API 检查 | PASS，7 个既有 allowlisted 使用；本轮未新增 allowlist | logs/repair4-private-api-check.log |
| 静态配方 | 128 条、92 个唯一 filter；锚点次数、完整替换后 Swift parser、方法存在检查 PASS；产品突变 typecheck／执行 NOT_RUN | counterexamples.json；evidence/repair4-counterexample-check.json |
| 配方基线 | 122 条配方的 filter passed；6 条配方 blocked，对应两个 socket filter＋一个账户报告 filter | evidence/repair4-counterexample-baseline-results.json |
| prepared 只读检查 | PASS（交付前以只读 --check 后验确认）；19 个最终文件、5 组、原 index 可应用、各文件与产物 hash、基线和分支核对 | prepared/manifest.json；logs/repair4-prepared-check.log |

Debug 的 25 个失败方法完整列在 evidence/repair4-sandbox-blocked-filters.txt：22 项既有家目录／CFPreferences 沙箱拒绝，3 个 Unix socket bind EACCES；不改夹具目录要求，不放宽生产路径。Release 核心只包含不依赖家目录的类和 UI 守卫；三个 socket 方法仍真实 bind 被拒，不能称全绿。未出现 SIGPIPE 崩溃。

具体 6 条 blocked 配方如下；5 个真实 socket 配方的内核 peer 来自真实 AF_UNIX socket，签名和父进程仍注入，不能称为本轮真实签名／sudo 认证已验证。

| Recipe | Filter | 类别／失败原因 |
|---|---|---|
| askpass-exact-peer-path | AppUpdateRepair2Tests/testRealSocketPeerRejectsWrongExecutableSignerAndNonSudoParent | socket peer；bind EACCES |
| askpass-live-peer-signer | 同上 | socket peer＋注入 signer；bind EACCES |
| askpass-live-peer-cdhash | 同上 | socket peer＋冻结 cdhash 策略；bind EACCES |
| askpass-sudo-parent | 同上 | socket peer＋注入父进程；bind EACCES |
| askpass-one-use-challenge | AppUpdateRepair2Tests/testWrongOneUseChallengeNeverReleasesPassword | socket peer／一次性挑战；bind EACCES |
| skip-not-failure-summary | AppUpdatePresentationIntegrationTests/testAccountUnavailableIsSkippedInStoreReportAndNeverCountedAsFailure | 账户报告／注入 executor，无 socket；家目录夹具 EPERM |

askpass-live-command-binding 属于注入 registry／进程表测试，基线通过，沿用上一轮可编译配方；不是上表的真实 socket 配方。askpass-one-use-challenge 的精确 filter 是 testWrongOneUseChallengeNeverReleasesPassword，错误挑战回显是该配方的直接边界；正向 testRealSocketChallengeIsOneUseAndFinishErasesCredential 在完整定向里也因 bind 被拒，但不属于这 128 条配方的精确 filter。上述映射按修复轮 5 已更正，与 counterexamples.json 和 repair4-counterexample-baseline-results.json 一致。

### prepared 顺序、主会话复跑与残余

01-command-lifecycle-evidence：命令正常退出／停止收据与只读进程检查；
02-recovery-release-and-quarantine：模型／队列／installer／executor／页面入口；
03-repair4-tests：20 个新增边界方法及旧夹具注入／必要旧断言；
04-scan-store-minimal-recovery-bridge：单列上述最小例外；
05-d78-and-repair4-handoff：收紧 D78 与本节、修正类别说明。

使用 prepared/commit-prepared.py --check 仅核验，本轮没有 --validated，没有提交。主会话在相同冻结源码上用 targeted-classes.txt 的 26 filters 外部复跑定向、全量和 128 条反证，逐条恢复原文→应用配方→完整构建成功→精确 filter 必须失败→恢复原文；替换导致编译失败不能算 killed。原 101 配方的外部全 killed 属上版事实，新版 128 只能记静态准备与基线，不能预报 killed。27 个新增配方对准上述三个 P1／P2-R4-1；7 个原配方只迁移已变化的锚点，ID 与意义保留。按 codex-build-common.md “不跑全量和反证（主会话跑）”，本轮未执行全量／产品突变；主会话还需外部只读安全复核。

D78 继续如实保留终端信任边界：批准的 Homebrew 命令及其脚本与在终端输入密码运行 brew 同等信任；其后代可借用 askpass 取得口令。精确 peer／签名／父进程／stdout／挑战检查未删；gid 80 来源例外保留，world-write／非 admin 组写仍拒绝。自有缓冲可清零，NSSecureTextField 的 Cocoa 内部副本无法保证主动擦除；AuthorizationCopyRights 的 environment 会经 XPC 发往系统授权服务，helper 仅接收 external form。真实 App／brew／mas／sudo／installer／hdiutil／账户／网络下载、签名打包、helper 部署、未保存文稿与重开都未执行；没有更改真实 Homebrew 或 /Applications。

本轮 JEV review 调用被自动审批拒绝（工具要求批准、approval policy=never），未取得 JEV 判断；evidence/repair4-jev-result.json 保留原结果。实现与证据仍由上述只读源码、注入测试及构建支持。

## 修复轮 5（2026-10-12；增量基线 4fa11dbd）

### 阅读、基线与范围

已读取 logs/codex-review5.log 末尾完整 P1-R5-1、P1-R5-2、P2-R5-1、P2-R5-2，以及主会话 main-final-0711 的构建与测试汇总和完整 mut/summary.json。上一版外部定向 455／0、全量 5090／0（25 skipped）、128／128 反证被杀、Release 带测试构建通过，均仅属于修复轮 4；完整全量日志虽有 CoreData 等诊断输出，实际失败测试为 0，未发现需额外处理的测试失败。证据及各日志 hash 在 evidence/repair5-prior-main-validation.json；完整复核四项摘录在 evidence/repair5-review5-findings.txt。

当前 HEAD 为 4fa11dbd316b419dbbe91bcbda19364f5e22bfe3，原十八个提交均保留（见 evidence/repair5-preservation-check.json）。3c86c360 的 admin gid 80 例外、96c167bd 的 accepted socket 清除 O_NONBLOCK 和 SO_NOSIGPIPE 保留；helper、Shared、askpass、AppUpdateExecutableIdentity 与 ScanStore 的增量均为空。原 index SHA-256 未变，没有提交、reset 或 push。上一版 prepared 原样保存在 prepared-before-repair5/，128 条配方保存在 counterexamples-before-repair5.json。

本轮只改上述四项：10 个应用更新源码、3 个测试文件、D78 与交接，共 15 文件／四组。没有新增 ScanStore 例外补丁；现有恢复桥接方法名保留，页面确认后才调用它。

### 四项修复及安全边界

| 意见 | 最终行为 | 保护测试 |
|---|---|---|
| P1-R5-2 等待集合扩展 | 复用 AppUpdateCommandProcessTree 的后代闭包。每次表读取都依据当前父进程的 PID＋启动时间身份扩展集合；子进程换组／重挂后仍保留，PID 重用不会接纳无关子进程。父进程仍有同一 zombie 身份时仍收集可见活子进程，zombie 自身不算存活。等待不发信号，默认 60 秒、最大 120 秒可注入；新身份经 inout 在超时／取消后保留，Brew／mas 结果及恢复证据均保存它，coordinator 对 pending 结果也持久化。旧记录没有 recoveryEvidence 时只建立进程证据，原路径／包范围仍未知，不补造 artifact；其 Homebrew 全来源隔离仍保留，没有路径的非 Homebrew 记录继续按原身份隔离别名。 | Repair5 的 WaitingExpands、ReusedParentPID、VisibleZombieParent；HomebrewWaitsForNewQ、两条 HomebrewTargetRollback、TimeoutPersists；AutomaticRecoveryPersists；MasWaitsForNewQ、MasTimeout、MasRollback。 |
| P1-R5-1 完整识别 | KERN_PROCARGS2 严格解析全部 argc 字符串，遇缺失／截断／不完整终止返回 unavailable，临时原始字节清零，不读入环境字符串作 argv、不日志化命令。ruby／bash／sh／zsh 任一参数含 brew.rb、brew.sh、前缀路径（包括 -c 文本）即相关；所有默认前缀及实际冻结 brew --prefix 下任意可执行文件均相关。客户端 brew／mas／installer／softwareupdate 及其可见后代都检查，恢复期间读回也扩大并保存身份。旧库存 optional prefixPath 缺失仍能解码。 | CompleteKernelArgv、TruncatedArgv、LongRubyArgv、ShellCommandText、ArbitraryExecutable、CustomBrewPrefix、GlobalInstallerDescendants。 |
| P2-R5-2 恢复写操作确认 | 页面按钮、隔离／取消提示统一“核验并恢复 / Verify and Recover”。按钮旁及确认框说明“会检查是否还有安装在进行，并根据结果完成、恢复先前更新留下的备份或解除锁定”，另说明可能清理已核验暂存／备份，均有英文 L10n。`.task` 只刷新恢复状态，不能恢复应用；自动 executor.reconcile 遇官网／Sparkle 替换事务只返回 pending，保留原 bundle／备份／staging／journal 字节。只有确认框按钮到显式 verifyAndRelease 路径才允许事务恢复写入。 | Coordinator 的 AutomaticWebsiteAndSparkleRecovery 检查备份／staging 摘要及 journal 原字节完全不变；ConfirmedWebsiteAndSparkleRecovery 验证确认后恢复原版并安全解除；已有成功恢复及身份不匹配测试仍保护材料。 |
| P2-R5-1 配方 filter | 第 420、423 行附近的历史说明已更正：askpass-one-use-challenge 的 filter 是 AppUpdateRepair2Tests/testWrongOneUseChallengeNeverReleasesPassword；正向 testRealSocketChallengeIsOneUseAndFinishErasesCredential 同样被 sandbox bind 拒绝，但不对应此配方。 | counterexamples.json 与两个 baseline-results JSON 一致；五条 socket 配方／一条账户报告类别保留。 |

常驻 installd、system_installd、softwareupdated、appinstalld 不因存在而阻塞，避免永久锁定；ResidentSystemInstallServices 测试锁定这一主会话取舍。本轮未引入新的常驻服务事务查询。“由 installer 客户端交给系统服务、客户端已退出后仍在进行的安装，无法从进程表可靠区分，核验会在读回层面兜底”，已同步 D78；完整 argv 与可见后代扩展不宣称穷举不可见安装事务。短命父进程完全落在两次快照之间的覆盖限制仍依 D78 处理：负向／不完整证据保持隔离，不开放重试；可信达标且已知后代均退出则正常完成、重开，不退回“任何 fork 都待核验”。

[ P ] → [ P, Q ] → [ Q ] → [ ] 已分别走等待器、Brew、mas。Q 活着时不能 stopped；Q 退出后再次读全包目标才完成／重开；Q 退出前或后版本回退都不得完成。等待超时仍为 completed＋持久隔离且不重开，新 Q 经队列 JSON／重启／恢复继续隔离，直到进程检查及目标读回通过。

损坏队列入口仍是轮 4 的显式用户声明“我已确认没有正在进行的更新”，保留原归档和有效未决意图；这一声明不等于技术停止回执，本轮没有扩大此确认机制。

### 旧断言与夹具调整依据

- testOfficialReconcileRecoversNilApplicationAfterReplacementCrash 改名 testConfirmedOfficialRecoveryRecoversNilApplicationAfterReplacementCrash，调用显式确认路径；仍要求目标版本、backup／journal 删除及 completed。依据 P2-R5-2：自动 reconcile 不能执行事务恢复写操作。
- testOfficialReconcileRejectsTransactionIdentityOrTargetMismatchBeforeCleanup 改为显式确认接口的结果合同：仍验证身份错误，结果 needsReconciliation、confirmedStopped=false，backup／journal 必须保留。显式恢复接口捕获 replacementRecoveryFailed 并保持隔离，所以原“抛出该错误”断言变为相同错误内容与隔离状态；没有减弱材料保留或身份检查。
- Repair4 的“Verify and Release is read-only”断言消息改为“Verify and Recover must not run an upgrade command”；callsBeforeRetry.isEmpty 断言原样保留。进程／版本检查不执行 upgrade，但官网／Sparkle 事务恢复可写回备份，因此旧说明不准确。
- 两条新增队列夹具显式调用 reconcilePendingTasks，区别仅加载 autoResume=false 队列与实际核验阶段；没有改旧断言、阈值或 skip。新 custom-prefix 夹具使用实际 HomebrewInventoryParser，未调用真实 brew。首轮测试类型错误已修正；并行 Release 输入变动的一轮结果作废，以以下冻结源码复跑结果为准。

### 最终验证（当前修复轮 5，不能外推上一版结果）

| 检查 | 结果 | 日志／证据 |
|---|---|---|
| Debug 带测试构建 | PASS，18.37 sec；13 源码／测试文件冻结 | logs/repair5-debug-build-final7.log；evidence/repair5-final-source-freeze.json |
| Debug 27 filters | 477 项：448 passed、4 skipped、25 个既有沙箱失败方法，27 个失败断言（19 unexpected）；退出 1，产品失败 0 | logs/repair5-targeted-debug-final4.log；evidence/repair5-targeted-results.json |
| 新 Repair5／恢复事务／UI | 20／20、4／4、46／46 passed；Repair4 20／20、Repair3 17／17 passed | 同上 |
| Release 带测试构建 | PASS，510.91s；native，-c release --build-tests -Xswiftc -enable-testing，同一冻结源码 | logs/repair5-release-build-final4.log |
| Release 核心＋4 恢复方法＋UI | 199 项：196 passed、3 个 socket bind EACCES、0 skipped，产品失败 0 | logs/repair5-targeted-release-final2.log；evidence/repair5-release-targeted-results.json |
| 静态检查 | git diff --check、私有 API（7 个既有 allowlisted）、十八祖先提交／index／admin／askpass／ScanStore 保留 PASS | logs/repair5-private-api-check.log；evidence/repair5-preservation-check.json |
| 配方准备 | 156 条、114 个 filter，完整替换锚点次数／方法／Swift parser PASS；产品突变 typecheck／执行 NOT_RUN | counterexamples.json；evidence/repair5-counterexample-check.json |
| 配方基线 | 150 passed／6 blocked：五条真实 socket 配方（两个 filter）＋一条账户报告（一个 filter） | evidence/repair5-counterexample-baseline-results.json |
| prepared | 15 文件／四组，基线 4fa11dbd；交付前执行 --check 验证 hash、原 index 可应用及范围，未提交 | prepared/manifest.json；logs/repair5-prepared-check.log |


Debug 25 个失败方法与修复轮 4 完全相同，22 个家目录／CFPreferences 沙箱拒绝、3 个真实 AF_UNIX bind EACCES；完整清单 evidence/repair5-sandbox-blocked-filters.txt，错误记录在 targeted-results JSON。Release 三个 socket 方法同样 bind 被拒；未出现 SIGPIPE，不把上述结果称全绿，不改夹具位置或放宽安全路径。新增模拟边界全部通过。

### 本轮反证 recipe／filter（28 条；主会话逐条完整编译及执行）

原 128 个 ID 全保留；仅六条既有锚点迁移：mas-live-child-must-finish-before-reopen, release-requires-known-process-identities-stopped, release-requires-global-installers-stopped, release-unreadable-process-table-is-not-stop-proof, release-must-detect-interpreted-brew, release-rechecks-processes-after-readback。它们保持原 filter／边界；新配方如下。静态 parser 不是产品 typecheck，主会话应恢复原文→应用配方→完整构建必须成功→精确 filter 必须失败→恢复原文。替换后编译失败不得算 killed；本轮未跑产品突变或全量。

| Recipe | 精确 filter | 意见 |
|---|---|---|
| complete-argv-no-eight-argument-cutoff | AppUpdateRepair5Tests/testCompleteKernelArgvPreservesArgumentsAfterEightAndStopsBeforeEnvironment | P1-R5-1 |
| truncated-argv-cannot-be-partial-stop-proof | AppUpdateRepair5Tests/testTruncatedArgvIsUnavailableAndCannotReleaseQuarantine | P1-R5-1 |
| interpreter-checks-full-long-argv | AppUpdateRepair5Tests/testLongRubyArgvFindsBrewAfterNinthArgument | P1-R5-1 |
| shell-command-text-detects-homebrew-prefix | AppUpdateRepair5Tests/testShellCommandTextAndBrewScriptsInAnyArgumentRemainInstalling | P1-R5-1 |
| interpreter-detects-brew-rb-and-sh-scripts | AppUpdateRepair5Tests/testShellCommandTextAndBrewScriptsInAnyArgumentRemainInstalling | P1-R5-1 |
| arbitrary-homebrew-prefix-process-blocks-release | AppUpdateRepair5Tests/testArbitraryExecutableUnderEveryHomebrewPrefixBlocksRelease | P1-R5-1 |
| brew-prefix-is-frozen-in-package-metadata | AppUpdateRepair5Tests/testCustomBrewPrefixIsFrozenWithFormulaAndCaskAndUsedDuringRecovery | P1-R5-1 |
| frozen-custom-prefix-reaches-recovery-process-gate | AppUpdateRepair5Tests/testCustomBrewPrefixIsFrozenWithFormulaAndCaskAndUsedDuringRecovery | P1-R5-1 |
| frozen-custom-prefix-reaches-interpreter-check | AppUpdateRepair5Tests/testCustomBrewPrefixIsFrozenWithFormulaAndCaskAndUsedDuringRecovery | P1-R5-1 |
| global-installer-descendants-outlive-client | AppUpdateRepair5Tests/testGlobalInstallerDescendantsStayTrackedAfterClientExitAcrossGroups | P1-R5-1 |
| resident-install-services-do-not-permanently-lock | AppUpdateRepair5Tests/testResidentSystemInstallServicesDoNotPermanentlyBlockRelease | P1-R5-1 |
| wait-expands-p-q-after-parent-exits | AppUpdateRepair5Tests/testWaitingExpandsPThenQAndCannotStopUntilQExits | P1-R5-2 |
| wait-parent-start-time-prevents-pid-reuse | AppUpdateRepair5Tests/testReusedParentPIDCannotAdoptUnrelatedNewChild | P1-R5-2 |
| zombie-parent-identity-still-owns-visible-child | AppUpdateRepair5Tests/testVisibleZombieParentStillOwnsItsChildUntilPIDIdentityDisappears | P1-R5-2 |
| wait-retains-expanded-identities-between-reads | AppUpdateRepair5Tests/testWaitingExpandsPThenQAndCannotStopUntilQExits | P1-R5-2 |
| brew-new-descendant-must-exit-before-reopen | AppUpdateRepair5Tests/testHomebrewWaitsForNewQThenRereadsAllArtifactsBeforeReopening | P1-R5-2 |
| brew-new-descendant-pre-exit-rollback | AppUpdateRepair5Tests/testHomebrewTargetRollbackWhileQIsStillAliveDoesNotCompleteOrReopen | P1-R5-2 |
| brew-new-descendant-post-exit-rollback | AppUpdateRepair5Tests/testHomebrewTargetRollbackAfterQExitsDoesNotCompleteOrReopen | P1-R5-2 |
| brew-timeout-persists-grown-descendants | AppUpdateRepair5Tests/testTimeoutPersistsNewDescendantAcrossCoordinatorRestartAndRecovery | P1-R5-2 |
| pending-recovery-persists-expanded-evidence | AppUpdateRepair5Tests/testAutomaticRecoveryPersistsNewGlobalDescendantsEvenWhileStillPending | P1-R5-2 |
| legacy-pending-intent-retains-new-process-evidence | AppUpdateRepair5Tests/testLegacyIntentWithoutEvidencePersistsGlobalChildAcrossRestart | P1-R5-2 |
| process-only-evidence-keeps-legacy-identity-quarantine | AppUpdateRepair5Tests/testLegacyIntentWithoutEvidencePersistsGlobalChildAcrossRestart | P1-R5-2 |
| mas-new-descendant-must-exit-before-reopen | AppUpdateRepair5Tests/testMasWaitsForNewQThenCompletesAndReopens | P1-R5-2 |
| mas-timeout-persists-grown-descendants | AppUpdateRepair5Tests/testMasTimeoutPersistsNewQWithoutReopening | P1-R5-2 |
| mas-new-descendant-pre-and-post-exit-rollback | AppUpdateRepair5Tests/testMasRollbackBeforeOrAfterNewQExitNeverCompletes | P1-R5-2 |
| automatic-recovery-requires-user-confirmation | AppUpdateCoordinatorTests/testAutomaticWebsiteAndSparkleRecoveryLeavesTransactionBytesAndBundlesUnchanged | P2-R5-2 |
| automatic-reconcile-cannot-confirm-itself | AppUpdateCoordinatorTests/testAutomaticWebsiteAndSparkleRecoveryLeavesTransactionBytesAndBundlesUnchanged | P2-R5-2 |
| confirmed-recovery-can-restore-earlier-backup | AppUpdateCoordinatorTests/testConfirmedWebsiteAndSparkleRecoveryCanRestoreBackupThenReleaseUnchangedUpdate | P2-R5-2 |


五条真实 socket 配方仅 askpass-exact-peer-path、askpass-live-peer-signer、askpass-live-peer-cdhash、askpass-sudo-parent、askpass-one-use-challenge：前四共享 testRealSocketPeerRejectsWrongExecutableSignerAndNonSudoParent，最后一条是 testWrongOneUseChallengeNeverReleasesPassword；真实 AF_UNIX／kernel peer，signer／父进程仍注入。skip-not-failure-summary 是 testAccountUnavailableIsSkippedInStoreReportAndNeverCountedAsFailure，注入账户报告、家目录夹具，无 socket。askpass-live-command-binding 是注入 registry，不算真实 socket。

### prepared 顺序、主会话命令与未执行范围

01-descendant-and-process-safety：可扩展 PID／启动时间集合、完整 argv／前缀识别、CLI 状态中文／英文；
02-confirmed-recovery-and-frozen-prefix：冻结 prefix、Brew／mas 扩展收据、pending 持久化、官网／Sparkle 恢复确认、页面文案；
03-repair5-tests：20 个新边界方法＋两个新恢复事务方法、已有两个恢复方法改用确认合同、Repair4 断言消息；
04-d78-and-repair5-handoff：D78、四项修复、真实 recipe／filter 与本节证据。

主会话：python3 prepared/commit-prepared.py --check 为只读后验；先外部复跑 targeted-classes.txt 的 27 filters、全量、156 条完整突变编译／测试、Release 带测试构建和只读复核，再按 manifest 四组处理。沿用 codex-build-common.md 的 SwiftPM flags，Debug scratch 为 debug、Release scratch 为 release；完整命令记录 prepared/static-checks.json。工作区已经是最终内容，不能将 all.patch 再应用到本 worktree；补丁是供主会话处理原 index／干净基线的增量。没有使用 --validated。

D78 保留已接受的终端信任：批准的 Homebrew 命令及其脚本与在终端输入密码运行 brew 同等信任；其后代可借用 askpass 取得口令。peer／签名／sudo 父进程／stdout／挑战检查未删；允许本机 gid80 admin 维护来源及祖先，world-write／非 admin 组写仍拒绝。自有字节缓冲清零范围不包括 NSSecureTextField 的 Cocoa 内部副本；AuthorizationCopyRights environment 经 XPC 送往系统授权服务。没有新增权限来源或保存密码方式。

JEV review 可调用元数据存在，但实际调用被自动审批拒绝（MCP tool call requires approval, but approval policy is never）；未取得 JEV 判断，原结果在 evidence/repair5-jev-result.json。没有执行真实 brew／mas／sudo／installer／hdiutil、下载、钥匙串、App 启动、真实 Homebrew 或 /Applications 修改、签名部署、提交或 push。模拟执行器、私有测试文件和构建不代表真实账户、授权框、未保存文稿提示、安装及重开实机验收。

## 修复轮 6（主会话，2026-10-12）

第 6 轮只读复核（Claude 子代理）：修复轮 5 的四项均已修复；新发现 P1-R6-1、P2-R6-1、P2-R6-2。

- **P1-R6-1**：前缀下任意可执行文件都算安装进程，`brew services` 的数据库、Cellar 里的 node／MCP 服务等常驻程序会让“核验并恢复”永远无法解除。改为只认 Homebrew 自身路径（`<前缀>/bin/brew`、`<前缀>/Library/Homebrew/`（含 portable-ruby）、`<前缀>/Caskroom/`、`/usr/local/Homebrew/`；默认前缀 `/opt/homebrew`、`/usr/local`，加任务冻结的自定义前缀）与安装客户端名；Cellar／opt 程序只有作为安装客户端后代时才计入。解释器参数（含 `-c` 文本）按词拆分后判断，不再用子串匹配；参数里的单词 `ruby` 不再触发“无路径 ruby”的保守规则（该规则仅用于拿不到可执行路径的 BSD 名称回退）。
- **P2-R6-1**：旧记录的“仅进程证据”（`applicationPath` 为空）不再参与路径身份比较和磁盘回读，已真实升级的旧 MAS／官网任务可正常完成。
- **P2-R6-2**：`homebrew.sh`、`mybrew.rb` 等不再误中（按文件名等于 `brew.rb`／`brew.sh` 判断）。

测试：`testArbitraryExecutableUnderEveryHomebrewPrefixBlocksRelease` 改为 `testHomebrewOwnExecutablesBlockReleaseButFormulaKegsDoNot`（依据：P1-R6-1）；`testShellCommandText…` 的 Cellar postinstall 样例改为 `/opt/homebrew/bin/brew postinstall`（postinstall 作为 brew 后代仍由进程树覆盖）；自定义前缀样例改为 `<前缀>/Library/Homebrew/vendor/bin/worker`。新增 `testResidentHomebrewInstalledProgramsDoNotBlockRelease`（node 及其子进程、postgres、`bash -c npx`、Cellar ruby 跑 rails、`homebrew.sh` 均不阻塞；同一 node 作为 brew 后代仍阻塞）与 `testLegacyMasIntentWithProcessOnlyEvidenceCompletesAfterVerifiedUpgrade`。反证 156→160 条（新增 4 条，更新 6 条锚点；修复轮 5 唯一存活的 `frozen-custom-prefix-reaches-interpreter-check` 已改为对准新的前缀合并处）。定向 137 项 0 失败。

## 修复轮 7（主会话，2026-10-12）

修复轮 6 只读复核（Claude 子代理）：P1-R7-1——`<前缀>/Caskroom/` 整棵被算作 Homebrew 自身，而 claude-code、codex、ngrok、chromedriver 等二进制 cask 与 miniforge/miniconda 的 python 都直接从 Caskroom 运行，常驻时仍会永久阻塞解除。已移除 Caskroom 目录（cask 的 uninstall/postflight 脚本是 brew 后代，由进程树覆盖）；测试改为断言 Caskroom 常驻程序 `.stopped`，并补 Intel 布局 `/usr/local/Homebrew/Library/Homebrew/vendor/portable-ruby/…/ruby` 为 `.running`。D78 中“前缀下任意可执行文件”的旧句改写，与新规则一致。
已记录残余：brew 被强杀（或 App 崩溃）后挂到 launchd 的孤儿后代，只能靠完成等待期间已持久化的身份覆盖；按词匹配可能把参数里单独出现 brew／mas／installer 的普通 shell 视为安装进程（只造成一次多余隔离）。反证 160→162 条。
