# D217 / D218 实现交接

2026-10-25，工作副本 `/Users/developer/Developer/sc-worktrees/p06-startup-apps`。输入 Git HEAD 为 detached `6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b`，已有大量集成差异；未切分支、提交、安装、联网或操作真实用户文件。JEV、LayerFS 工具未提供，未调用其他模型、未入库。本文件是主会话接手入口。

**状态：实现与构建通过，新增 19 项测试通过；完整相关回归 BLOCKED，不能声称整批验收通过。** 最终回归 266 项：263 通过、2 项原有条件跳过、1 个旧测试失败（4 条签名相关断言）。窗口类按 D106 未运行。

**口径与范围**

D217 复用 `LaunchdPlistScanner` 的顶层 `.plist` 证据，三处位置各文件各一行、各计一项，不按应用或开发者合并、不排除本 App，不计 `.plist.disabled`、子目录及 `/System/Library`。其他扫描证据单列“其他后台组件”，继续用已有组件能力管理。登录项读取、计数和管理保留。助手不可用时后台数及说明不再表示下限。

本机预期 **46 = 用户代理 27 + 共享代理 3 + 守护进程 16**，来自输入调查第 4 节，本沙箱未复读真实目录。实际安装验收应按当时文件重新核对。

D218 复用 Spotlight 会话，查询 `kMDItemContentTypeTree == "com.apple.application-bundle"`；位置、包内应用、虚拟机、备份、代理、网页应用、保护目录和符号链接均过滤。按 bundle id 合行，无 id 按路径；展开显示每份路径、大小和修改时间。初始不选，不进入标准库存、智能扫描或概览计数（包括概览的已忽略数）。路径忽略接 `.uninstaller`。移除只含明确勾选的包，隔离其他分类预选项，构造请求时强制清空关联资源，沿用可恢复废纸篓回执。新功能测试实际移动的仅为本工作副本内生成的临时应用。

调查的其他位置 **59 份**是本机输入证据，未在本轮重查；新类别数量以本次过滤后同标识合并的组数为准，不能用 `109 − 84` 推算，因为其他位置也可能有已安装应用的同标识副本。Spotlight 失败、超时或不可用显示空状态与原因。**新类别的右键“加入忽略列表”未做（任务允许延后）**，现有设置页按路径忽略有效。

**文件清单：22 个代码/测试文件，另有本交接**

| 文件（相对项目根） | 做法 |
| --- | --- |
| `Sources/StorageCleanerMac/Features/AppLifecycle/Uninstaller/ApplicationClassification.swift` | D218 类别、说明、空状态；不加入其他应用分类。 |
| `Sources/StorageCleanerMac/Features/AppLifecycle/Uninstaller/ApplicationRemovalService.swift` | 新增 bundleOnly 请求，构造时强制清空关联资源；沿用废纸篓、回执和恢复链路。 |
| `Sources/StorageCleanerMac/Features/AppLifecycle/Uninstaller/ApplicationsManagerModel.swift` | 独立查询、合并、展开、勾选和忽略快照；其他位置操作隔离其他分类已有勾选；成功后按路径移除行。 |
| `Sources/StorageCleanerMac/Features/AppLifecycle/Uninstaller/OtherApplicationsScanner.swift` | 可注入 Spotlight、元数据和符号链接检查；先排除位置，再读应用包；同标识合并、无标识按路径；失败返回空状态原因。 |
| `Sources/StorageCleanerMac/Features/AppUpdates/Scanning/SpotlightApplicationScanner.swift` | 复用查询会话，允许注入类型属性；D218 用 ContentTypeTree，更新扫描保留 ContentType。 |
| `Sources/StorageCleanerMac/Features/StartupItems/Scanning/LaunchdPlistScanner.swift` | 只取目录顶层 plist 文件，忽略目录与 disabled 后缀；隐藏 plist 仍计数，保留原符号链接安全证据。 |
| `Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsDashboardView.swift` | 经典列表加入其他后台组件入口。 |
| `Sources/StorageCleanerMac/Features/StartupItems/Views/StartupItemsPresentation.swift` | 后台按三处扫描结果逐文件投影；其他来源独立分类，原归属合并和登录项逻辑保留。 |
| `Sources/StorageCleanerMac/Features/StartupItems/Views/StartupReadPresentation.swift` | 后台数不随助手覆盖变化；删除至少、只含用户级的旧说明。 |
| `Sources/StorageCleanerMac/Services/AppUninstallService.swift` | 仅在 bundleOnly 路径允许无 bundle id；仍核对目录身份、版本和当前 Info.plist。 |
| `Sources/StorageCleanerMac/Views/ApplicationsManager/ApplicationsManagerView.swift` | 其他组显示带数量的新类别、空状态、路径行与勾选；不改变所有应用与概览忽略数。 |
| `Sources/StorageCleanerMac/Views/ApplicationsManager/OtherApplicationGroupRows.swift` | 一行合并同标识副本；展开显示每份路径、大小、修改时间及独立勾选。 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioApplications.swift` | 新分类复用已有图标和插画。 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSmartCare.swift` | 智能扫描性能卡消费同一逐文件数，保留登录项未读提示。 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioStartup.swift` | 后台列表按文件显示路径；其他后台组件分类与管理能力保留。 |
| `Tests/StorageCleanerMacTests/ApplicationsManagerD218Tests.swift` | 12 项新增：所有排除规则、合并、默认勾选、计数隔离、忽略、失败、仅移包与可读恢复回执。 |
| `Tests/StorageCleanerMacTests/ApplicationsManagerTests.swift` | 旧回执夹具 URL 明确标记目录；全部移动与回执断言保留（D218＋旧值说明）。 |
| `Tests/StorageCleanerMacTests/StartupBackgroundD217Tests.swift` | 7 项新增：临时三目录、逐文件/同开发者、其他组件、助手独立、后缀、隐藏与 Apple 归属。 |
| `Tests/StorageCleanerMacTests/StartupItemsDashboardContractTests.swift` | 更新分类枚举契约，注明 D217＋旧值；D106 窗口类未运行。 |
| `Tests/StorageCleanerMacTests/StartupItemsPresentationTests.swift` | 更新逐文件数量、标识和位置优先的期望；保留精确断言并注明 D217＋旧值。 |
| `Tests/StorageCleanerMacTests/StartupReadD195Tests.swift` | 更新后台文案期望并注明 D217＋旧值；登录项断言保留。 |
| `Tests/StorageCleanerMacTests/TestFileSystem.swift` | 显式 STORAGE_CLEANER_TEST_OPERATION_ROOT 注入，仅接受本工作副本 .build 内已存在且无符号链接的目录；UUID 所有权、收尾和产品校验保留。 |

**验证与证据**

日志、改前快照、独立补丁、哈希和准确命令在 `.build/p06-evidence/`。只审本轮请使用 `p06-code.patch`、`changed-files.json`、`source-hashes.json`，不要把整个 Git diff 当成本轮改动。完整命令见 `.build/p06-evidence/验证命令.md`；所有过滤器均以 `/` 结尾。

- `build-final.log`：exit 0。改动文件相对指定 warning 基线 **0 新增警告**，见 `warnings.json`。沙箱拒绝 nice 调优先级、SwiftPM 用户缓存写入；构建本身完成。依赖来自已有本地 `v2.0.1/debug` 的 checkouts/repositories/artifacts/workspace-state.json 副本。
- `new-tests-final.log`：**Executed 19 tests, 0 failures**；D217 7、D218 12（含仅移包、共享文件未变、回执可读）。
- `tests-final.log`：**Executed 266 tests, 2 skipped, 4 failures**，共 17 类；D195、D206、应用管理、D207、SmartCare、UIConsistency、SettingsSourceContract 相关已执行。未删测试、放宽断言或增加跳过。
- 唯一失败：`StartupScanningTests.testCoordinatorDoesNotTreatAValidPlistAsANonExecutableTarget` 第 877–880 行。它用固定扫描器验证真实 `/usr/bin/true` 的签名。该测试、Coordinator 和签名实现均未修改；独立只读 `codesign` 同样 exit 1，报 `CSSMERR_TP_NOT_TRUSTED`（`system-signature-probe.log`）。**请主会话在沙箱外重跑，不能把这 4 条失败抹掉。**
- 原有条件跳过：`StartupApplicationSigningIdentityTests.testRealCodesignAcceptsFinderInfoButRejectsModifiedAndAdHocCopies`（同一签名信任限制），`StartupScanningTests.testLiveReadOnlyCoverageWhenExplicitlyEnabled`（未开启真实主机扫描）。未开启实机启动项扫描或新扫描器的真实 Spotlight 查询，未连接真实助手；已有应用扫描回归只传临时目录。
- 反证 `mutation-test.log`：当时 11 项 D218 测试仅资源边界断言按预期失败，exit 1；已还原，`mutation-restored.txt` 与最终源码哈希一致。
- `display-bound-check-final.log`、`deletion-process-check-final.log`、`diff-check.log`：均 exit 0，包含新增文件的尾随空白检查为 0。

早期失败已保留：首次编译的测试 actor 隔离、夹具目录未预建/所有权未接入、`/var` 符号链接、同开发者夹具缺签名身份、旧 Apple 筛选期望及回执 URL 目录标记均已修复。`journal-url-probe.log` 证实未标记目录的 URL 与其文件的父 URL 不相等（路径相同），所以仅修正旧夹具，未改回执安全校验。

| 实际日志（相同命令各轮保存） | exit code |
| --- | --- |
| `build.log` | 1 |
| `build-r2.log` | 0 |
| `build-r3.log` | 0 |
| `build-r4.log` | 0 |
| `build-r5.log` | 0 |
| `build-final.log` | 0 |
| `tests-r1.log` | 1 |
| `tests-r2.log` | 1 |
| `tests-r3.log` | 1 |
| `tests-r4.log` | 1 |
| `tests-final.log` | 1 |
| `new-tests-final.log` | 0 |
| `mutation-test.log` | 1 |
| `system-signature-probe.log` | 1 |
| `journal-url-probe.log` | 0 |
| `display-bound-check-final.log` | 0 |
| `deletion-process-check-final.log` | 0 |
| `diff-check.log` | False |

**主会话必须补跑**

D106 清单保持原样。窗口类：`StartupItemsDashboardContractTests`、`StartupApplicationUpdateSchedulerTests`、`CareStudioWindowReviewTests`、`CareStudioNavigationTests`、`FeatureLightfieldApplicationP2Tests`、`FeatureLightfieldApplicationPageTests`、`SmartScanScopeTests`（清单依据见 `.build/p06-evidence/main-session-window-classes.txt`）。另须在正常系统信任环境重跑上述签名失败与条件跳过类，并完成主会话常规集成门禁。

**装机后只读实测（本轮未执行安装）**

1. 打开性能页，执行只读扫描，核对三目录当前 `.plist` 数、性能磁贴、智能扫描性能卡和后台列表同数；助手不可用也不出现“至少”。不要停用、移除或申请安装助手。
2. 进启动项管理：后台每个 plist 单行并显示路径；同开发者多份保留；“其他后台组件”有数据库/内嵌/残留等额外来源，查看详情和现有能力提示；登录项数与原口径一致。只展开、搜索，不触发操作。
3. 打开应用管理“其他 → 其他位置的应用”，等待查询结束，核对数量、路径、修改时间和大小；同标识展开有多份，无标识分行，所有复选框默认未选。比对“所有应用”、概览与智能扫描计数未增加。
4. 检查标准位置、系统目录、保护目录、虚拟机/备份包、代理和网页应用未混入；已有 `.uninstaller` 路径忽略不显示。只查看现有忽略条目，不修改忽略列表，不点移除、卸载、恢复或任何会动文件的按钮。
5. Spotlight 禁用/失败的 UI 通过注入测试已覆盖；装机验收不要为了制造失败修改系统索引配置。移除/恢复链路已用夹具验证，真实数据的写操作不在本只读实测范围。

下一步：主会话先核对本轮补丁与来源，再在沙箱外完成签名及窗口验收；本副本和证据保持保留，未提交、未合入、未安装或发布。
