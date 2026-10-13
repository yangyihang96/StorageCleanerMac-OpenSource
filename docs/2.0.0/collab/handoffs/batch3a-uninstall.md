# 批次 3a 交接：卸载

- 实现：Claude 子代理（Opus 5.5）　复核：全新上下文的 Claude 子代理（结论“修改后合并”，无 P0、无数据安全问题；意见与处理见下文“复核与处理”）
- 分支：`task/batch3a-uninstall`，基于集成分支 `f2d709c`（含批次 1、2a、2c）
- 第一轮提交：`7af9d29`（第 2、3 项）、`e7200af`（第 1 项，D1）、`304d7ef`（第 6 项）、`1fb39b1`（第 4 项）、`beb8cdb`（第 5 项）、`dbf90fc`（交接）
- 复核后提交：`f8793bb`（P1、P2-1、P2-2）、`c036f9e`（P2-4、P2-5）、`7777218`（P2-3、P2-7）、`8c9edc1`（P2-6），以及本交接与 `RULES.md`（P2-8）
- 每个提交都单独构建过，并跑过相关测试（见“命令与结果”）。

## 最终行为（按卡片各项）

| # | 问题 | 现在的做法 | 文件 |
|---|---|---|---|
| 1 | 卸载预览与残留模式默认全选“已核实归属”的关联文件 | 按 D1 默认只选应用本体：`requestUninstall`、`prepareResidualUninstall` 的初始选择为空。复用原有分组按钮，“全选”改名“全选已核实项”（再点为“取消全选”），逐项勾选不变。说明文字：普通卸载为“默认保留；勾选后才会随应用移入废纸篓”，残留模式（应用本体已在废纸篓）为“默认保留；勾选的项目会移入废纸篓”。残留模式未勾选时“清理所选文件”不可用 | `Stores/ScanStore.swift`、`Views/UninstallPreviewSheet.swift` |
| 2 | 一出现 Cocoa 513 就请求管理员授权，“应用管理”（TCC）拒绝时 root 辅助程序同样会被拒，用户白输一次密码 | 统一由 `UninstallAuthorizationDecision.evaluate` 决定。以下四条**同时成立**才请求授权：① 错误链里有 POSIX `EACCES`/`EPERM`，或者只有一个单独的 Cocoa 513；② 应用包本身或它所在目录 `access(W_OK)` 确实失败（跨目录移动目录要写父目录和包自身的“..”）；③ 辅助程序自己的 `FileOperationPathPolicy.permits` 接受这个请求；④ 应用包没有 `UF_IMMUTABLE`/`SF_IMMUTABLE`/`SF_RESTRICTED` 标志（与辅助程序一样用 `lstat` 检查）。其余情况都不请求密码，并分四种原因记录：系统拒绝（文案不断言是“应用管理”所致，只说明可去哪里允许，附“打开系统设置”“在访达中显示”）、位置不支持（附“在访达中显示”）、受保护的应用（Apple 自带、本应用自身、缺少标识或带系统保护标志，与“位置”分开说明）、已锁定（在访达“显示简介”中取消“已锁定”后重试，附“在访达中显示”）。原因作为诊断域（`UninstallAuthorization.not-offered.<原因>`）加在错误链最外层，拒绝码仍在链里，原地未动的应用照旧记为“未移动”（`trashMoveRejected`），不会变成“结果不明”。`isPermissionDenied` 语义不变；新增 `hasPOSIXPermissionDenial`、`isLoneWriteRefusal`。删除未被调用、仍按旧 513 规则写文案的 `uninstallFailureMessage` | `Services/UninstallExecution.swift`、`Services/RecordedTrashOperation.swift`（仅权限判断）、`Services/AuthorizedApplicationMover.swift`、`Views/UninstallPreviewSheet.swift` |
| 3 | 辅助程序只接受 `/Applications`、`~/Applications` 的直接子项，客户端却对任何路径（含嵌套）请求授权 | `AuthorizedApplicationMover.request(for:…)` 是唯一的请求构造，实际移动也用它，仍在授权之后构造，过期窗口不变。`helperVerdict(_:)` 直接调用辅助程序同一个纯函数（uid 与 home 取自账户记录），不在客户端重写规则；不通过时，用中性标识再判一次：通过则说明是应用标识的问题，否则是位置问题。嵌套路径不再请求授权。辅助程序未改（只读核对 `Sources/FileOperationHelper/main.swift`：prepare 与 commit 都先跑 `FileOperationPathPolicy.permits`，移动前检查不可变标志） | `Services/AuthorizedApplicationMover.swift`、`Services/UninstallExecution.swift` |
| 4 | 记录页状态直接拼枚举原名，而且所有移动前检查失败都显示成“系统拒绝移入废纸篓” | 跳过原因用已有的 `CleanSkipReasonPresentation`，失败用 `CleanFailurePresentation`（清理报告视图里私有的 `failureTitle` 原样移出共享）。新增只读分类 `UninstallFailureReason`，按回执里的诊断码区分：扫描后已变化或正在运行、未确认本体已移走、项目已不存在、任务被中断、授权未完成、授权辅助程序不可用、系统拒绝，以及四种“未请求密码”的原因；记录页与卸载结果页按原因分别措辞，未知码沿用通用标题。日志的记录方式不变 | `Services/UninstallExecution.swift`、`Support/UninstallPresentation.swift`、`Views/ReversibleOperationsView.swift`、`Views/UninstallPreviewSheet.swift`、`Views/CleanupExecutionViews.swift` |
| 5 | 卸载夹具测试走真实 `~/.Trash`，本机无权限时整条跳过 | 注入夹具目录内的隔离废纸篓（移动与恢复都用），并注入一旦请求授权就判失败的授权环境，去掉 `XCTSkip`；任何环境都实际运行。`RULES.md` 第 3 节删去这条测试“用 `--skip` 排除”的说明（只删这一处，保留其余环境限制） | `Tests/.../SystemUtilitySafetyTests.swift`、`docs/2.0.0/collab/RULES.md` |
| 6 | “重试未完成项”用只含重试项的新报告替换结果：第一次已移走的项被显示为“未勾选，已保留”，“恢复文件”也只恢复重试那一份 | 只在应用本体已移走（仍可恢复；残留模式下由更早的回执证明）、或本体原地被拒且重试有可能成功时提供重试；本体结果不明、未执行、已恢复、回执未保存，或剩下的未完成项都会以同样原因再次失败时，不提供重试（`confirmUninstall(retrying:)` 同样拒绝）。每次运行仍是日志里独立的一份回执。界面用 `UninstallReviewResult`：其中保存的回执用于恢复和残留检查；展示用的合并视图按路径合并，每个路径取最后一次结果，有自己的标识和规则标记，不会被当成某一份回执。重试进行中只更新进度、不发布结果；结束时在当时的回执列表上追加。“恢复文件”在一个恢复租约内依次恢复本次卸载的所有回执（`CleanupRecoveryService.restore(reports:)`，位于 `RecordedCleanupRecovery.swift`）；从操作记录恢复其中一份时，界面同步更新 | `Services/UninstallExecution.swift`、`Services/RecordedCleanupRecovery.swift`、`Stores/ScanStore.swift`、`Views/UninstallPreviewSheet.swift` |
| — | `ScanStore` 的卸载路径写真实日志，无法做不碰用户数据的集成测试 | 卸载的检查点与最终记录写入批次 2a 注入的 `operationJournal`（`CleanReportStore.record` 增加 journal 参数；旧的 defaults 缓存只镜像真实日志）。新增注入项 `operationTrashURL`（记录恢复读取的废纸篓）和 `UninstallMoveEnvironment`（系统回收与授权输入）。默认值与原生产行为相同 | `Stores/ScanStore.swift`、`Services/CleanupMigration.swift`、`Services/UninstallExecution.swift` |

### 卡片范围之外改动的文件（说明）

- `Views/CleanupExecutionViews.swift`：把清理报告视图里私有的 `failureTitle` 原样移成共享的 `CleanFailurePresentation`（复核确认逐字未改），供记录页复用，避免另写一套文案。
- `Support/UninstallPresentation.swift`：这个文件原本就是卸载界面的纯展示工具；新增的记录页短文案 `recordLabel` 放在这里，不读文件系统。
- `Services/RecordedCleanupRecovery.swift`：按复核意见，把通用的多回执恢复放到单回执恢复旁边。
- `Services/CleanupMigration.swift`：`CleanReportStore.record`／`recordDetached` 增加 journal 参数（默认仍为真实日志），供卸载路径使用注入的日志。
- `docs/2.0.0/collab/RULES.md`：只删除第 3 节关于此夹具测试“用 `--skip` 排除”的一句。

## 对卡片第 2 项的细化（主会话决定）

卡片原规则是“只有 POSIX `EACCES`/`EPERM` 且 `access(W_OK)` 失败才授权，单独的 513 只作诊断”。`docs/2.0.0/UNINSTALL-513-20260925.md` 第 5 行记录了一份现场回执：只有 `NSCocoaErrorDomain:513`，应用仍在原位，场景是安装器管理或其他账户持有的 `/Applications` 应用，正是辅助程序的用途。按原规则，这类应用将不再能授权移动，相对当前测试版是回退。因此按主会话决定，把条件 ① 扩为“POSIX `EACCES`/`EPERM` 或单独的 Cocoa 513”，并加上条件 ④（锁定标志）。单独的 513 且应用包与目录都可写时，仍只给指引、不请求密码。

## 复核与处理

复核结论：修改后合并。辅助程序未改、客户端路径策略与之一致；多回执的重试、合并、恢复没有移错文件、重复恢复或漏恢复的路径。

| 意见 | 处理 |
|---|---|
| P1：单独的 513 一律不授权，会让现场回执那类应用失去授权移动 | 已改（`f8793bb`），规则见上节；测试覆盖“单独 513 且包不可写 → 授权”“单独 513 且可写 → 只给指引”；反证见下 |
| P2-1：辅助程序因 `com.apple.`、空标识拒绝时，文案说成位置问题 | 已改（`f8793bb`）：`helperVerdict` 区分标识与位置，“受保护的应用”单独措辞 |
| P2-2：锁定的应用 `access` 也失败，客户端会请求授权，辅助程序却拒绝 | 已改（`f8793bb`）：客户端用 `lstat` 检查与辅助程序相同的三种标志，不授权，提示在“显示简介”中取消锁定后重试；测试用真实 `chflags` 锁定夹具（`access` 确实返回不可写） |
| P2-3：重试结束时用开始时捕获的旧回执列表覆盖结果，期间从操作记录做的恢复会被盖掉；`isUninstallingApp` 与结果可能不一致 | 已改（`7777218`）：结束时在当前回执上追加；只通过一个函数发布界面状态，运行中只更新进度、结果为空，运行结束的同一时刻发布结果 |
| P2-4：移动前检查失败一律显示“系统拒绝移入废纸篓”；“位置不支持”等必然再次失败的情况仍有重试按钮 | 已改（`c036f9e`）：按诊断码分原因措辞；无法靠重试解决时隐藏重试按钮；日志记录方式不变 |
| P2-5：残留模式说明“随应用移入废纸篓”不对 | 已改（`c036f9e`） |
| P2-6：`ScanStore` 接线无自动化测试 | 已改（`8c9edc1`）：卸载路径改用注入的日志、废纸篓与移动环境（改动小），新增 `UninstallStoreWiringTests` 覆盖 `canRetryUninstall`、`confirmUninstall(retrying:)`、`restoreUninstallResult`、从记录页恢复后的同步、清除 `completedUninstallApplication`、运行中不发布结果 |
| P2-6（可选）：用环境变量开启的真实 `NativeApplicationRecycler` 集成测试 | **未做**。现有做法（`script/run_rc_trash_integration.sh`）需要挂载可丢弃的 APFS 磁盘映像，默认使用 `/tmp` scratch 和 `/Applications/Xcode.app`，与本批规则（专属 scratch、不碰真实废纸篓）不符；即使写了测试，本批也无法实际运行，只能记为 NOT RUN。建议主会话把 `NSWorkspace.recycle` 场景加入该脚本，并在实机阶段运行 |
| P2-7：通用的 `restore(reports:)` 位置；合并结果沿用第一份回执的 id；范围外文件需说明 | 已改（`7777218`）：移到 `RecordedCleanupRecovery.swift`；合并结果改为 `UninstallReviewResult.display`，有自己的标识与规则标记 `uninstall.review.display.v1`，恢复和残留检查只用保存的回执；范围外文件见上节说明 |
| P2-8：删除 `RULES.md` 第 3 节关于夹具测试跳过的说明 | 已改（本交接所在提交），只删这一处 |

## 改动的旧测试（锁定旧行为的）

| 测试 | 原来锁定的 | 现在 | 依据 |
|---|---|---|---|
| `UninstallExecutionTests.testNestedPermissionErrorRetainsCodes` → 改名 `…AndOffersAuthorizationOnlyForUnwritableFolders` | `513 > POSIX 13` 属于权限拒绝，旧代码据此直接请求授权 | 仍断言属于“拒绝”（记为未移动）、诊断码不变；可写时只给指引、不可写时授权；单独 513 同样如此（第二轮按 P1 细化） | 卡片第 2 项及其细化 |
| `SystemUtilitySafetyTests.testUninstallPreviewUsesOneExplicitSelectionAndRetainsOwnershipBoundary` | 旧文案“包含设置和本地数据；取消勾选即可保留。” | 断言 D1 新文案、残留模式文案、“全选已核实项”、`ScanStore` 不再默认选中关联项 | DECISIONS D1；复核 P2-5 |
| `SystemUtilitySafetyTests.testUninstallTrashesOnlyAnIsolatedFixtureAndPersistsItsReceipt` | 无 `~/.Trash` 读权限时 `XCTSkip` | 注入隔离废纸篓；原断言全部保留，另加“回执指向隔离废纸篓”“恢复后隔离废纸篓为空” | 卡片第 5 项 |

没有删除断言、放宽阈值或新增跳过。

## 新增测试

- `UninstallAuthorizationTests`（15 项）：判定规则（单独 513、POSIX、其他 Cocoa 拒绝、辅助程序策略与锁定标志的先后）、诊断码与“未移动”分类、真实 `FileOperationPathPolicy` 下的位置与标识判定、真实 `chflags` 锁定夹具、夹具应用上的 `execute`（可写时不授权、现场情形授权一次、位置或锁定时不授权、本体被拒后重试只跑本体）。
- `UninstallRetryResultTests`（8 项）：提供重试的条件表、必然再次失败时隐藏重试、按路径合并且不把第一次已移走的项显示为“已保留”、展示视图不是回执、运行中的重试只显示不进入可恢复回执、夹具上原回执与重试回执都被恢复、按诊断码区分原因、移动前检查失败照旧记录但按原因说明。
- `OperationRecordLabelTests`（3 项）：失败码与跳过原因都有本地化标题且不含枚举原名；每个卸载原因有各自的记录页文案；两个视图不再拼接 `.rawValue`。
- `UninstallStoreWiringTests`（2 项）：见上表 P2-6。

反证（临时改回旧行为后跑测试，再从备份或提交还原；工作区已确认干净）：

| 改回的旧行为 | 结果（日志在 `~/Developer/.sc-build/batch3a/`） |
|---|---|
| 任何权限拒绝都授权（第一轮） | 28 处失败（`mutation-M1.log`） |
| 客户端忽略辅助程序路径策略（第一轮） | 7 处失败（`mutation-M2.log`） |
| 合并只取重试报告、只恢复最后一份、有未完成项就重试（第一轮） | 24 处失败（`mutation-M3M4.log`） |
| 只认 POSIX，不认单独 513（P1） | 11 处失败（`r2-mutation-M5-posix-only.log`） |
| 不查锁定标志（P2-2） | 6 处失败（`r2-mutation-M6-no-lock-check.log`） |
| 标识问题报成位置问题（P2-1） | 2 处失败（`r2-mutation-M7-bundle-as-location.log`） |
| 必然失败时仍提供重试（P2-4） | 4 处失败（`r2-mutation-M8.log`） |
| 运行中也发布结果（P2-3） | 2 项测试失败（`r2-mutation-M10.log`） |

第二轮做 M5 时，反证脚本用 `git checkout` 还原文件，误把当时尚未提交的 `UninstallExecution.swift` 改动一并还原。改动随即按本会话记录重新写入，并从头重跑了构建与相关测试；之后的反证都改为从备份还原。

## 命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，scratch `~/Developer/.sc-build/batch3a/debug`，日志在 `~/Developer/.sc-build/batch3a/`。

| 命令 | 结果 |
|---|---|
| 第一轮：改动前基线 `swift build` | PASS，exit 0（`build-baseline.log`） |
| 第一轮：各提交状态的相关测试 | PASS，均 exit 0（`test-S1.log` … `test-S5.log`） |
| 第一轮：完整 Debug `swift test`（HEAD `beb8cdb`） | PASS，exit 0，3137 项／跳过 21／0 失败（`test-full-debug.log`） |
| 第二轮：`f8793bb` 状态，卸载相关 7 个测试类 | PASS，exit 0，54 项／0 失败（`r2-test-A.log`）；规则改动重新写入后复验 28 项／0 失败（`r2-test-A2.log`） |
| 第二轮：`c036f9e` 状态，卸载、记录、契约等 7 个测试类 | PASS，exit 0，94 项／0 失败（`r2-test-B.log`） |
| 第二轮：`7777218` 状态，卸载与恢复相关 8 个测试类 | PASS，exit 0，69 项／0 失败（`r2-test-C.log`） |
| 第二轮：`8c9edc1` 状态，含 `UninstallStoreWiringTests` 的 6 个测试类 | PASS，exit 0，76 项／0 失败（`r2-test-D.log`） |
| 第二轮：完整 Debug `swift test`（同一 scratch，HEAD `8c9edc1`） | **FAIL（计时，机器高负载）**：两次全量都是 3148 项／跳过 21／1 失败（15:50–15:54，负载约 17；15:55–15:58，负载约 15），唯一失败是 `MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`（跑满 15 s 上限，`BenchmarkKernelError` 2）。该类单独重跑 PASS：19 项／跳过 1／0 失败（负载约 13）；第一轮全量（负载较低）中同一测试 10.1 s 通过。本批未改动跑分代码。按 `RULES.md` 第 3 节须在空闲时重跑，未放宽阈值（`r2-test-full-debug.log`、`r2-test-full-debug-rerun.log`、`r2-rerun-MacBenchmarkKernelTests.log`）。新增的 11 项（3137 → 3148）全部通过 |
| `python3 script/check_private_api.py` | PASS，exit 0（6 处白名单） |
| `git diff --check f2d709c..HEAD` | PASS，exit 0 |
| JEV `jev_review`（第一轮，只提交非敏感的源码摘录与测试摘要） | `action=review`，`safe_to_apply=0.52`，composite 0.785；不是批准。第二轮未再调用 |

未运行（按要求）：完整门禁（Release 全量、严格并发、源码守卫、小窗性能，由主会话合并后跑）；应用启动、截图、实机操作；挂载磁盘映像的真实回收集成测试。

## 未完成与风险

1. **NOT RUN，需实机确认**：现场情形（安装器所有的应用、单独 513）在新规则下会请求授权，但真实的 `NSWorkspace.recycle` 错误链和辅助程序完成移动只能在实机阶段，用用户选定的应用验收；夹具与注入测试不能代替。
2. `access(W_OK)` 只看 Unix 权限，ACL 的“删除”拒绝不在判断内，这种情况会显示“系统拒绝”的指引，不请求密码。
3. 应用从废纸篓恢复到 `/Applications` 的路径（`Services/SafeCleanupExecutor.swift` 约 1313 行）仍按 `isPermissionDenied` 直接请求授权，没有套用同样的四项判断。不在本卡范围，建议后续统一。
4. P2-3 的竞态窗口（重试回执保存期间从操作记录恢复）无法用测试确定性复现：恢复要拿到恢复租约，而卸载持有清理租约，只有在保存回执那一小段才可能交叠。已测的是“运行中不发布结果”和“恢复后同步”，追加本身由代码保证。
5. 新文案与按钮未截图、未实机查看，需主会话复查视觉。
6. `ContentView` 里 `uninstallPermissionDenied` 的“在访达中定位／打开 App 管理设置”弹窗分支从未被置为 true（死路径），属批次 3b 区域，未改。
