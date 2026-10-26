# D195 文件操作助手与显示修复交接

工作副本：`/Users/developer/Developer/sc-worktrees/p04-helper`。输入为主会话给定的 2.0.1 集成树 ae40ba0d 完整副本；该副本 Git HEAD 实际为 detached `6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b`，已有大量集成差异，本轮未提交或变更分支。改前快照、差异与日志均在 `.build/d195-evidence/`；`d195-code.patch` 仅含本轮代码和测试差异，适合独立审阅，不能以整个 `git diff` 代替本轮差异。

状态：实现和构建完成；新增测试与直接相关回归 47 项通过。完整相关回归仍待沙箱外验收（详见验证段）。未安装、未运行应用、未连接真实助手、未操作任何 launchd 任务、未安装更新。JEV/LayerFS 工具未发现，本轮没有额外模型调用或入库；成果保留在本副本。

## 文件清单与作用

以下均为相对项目根的路径；JSON 完整清单为 `.build/d195-evidence/changed-files.json`（31 个代码/测试文件，另有本交接）。

| 文件 | 作用 |
| --- | --- |
| `Sources/FileOperationShared/FileOperationHelperLifecycle.swift`（新） | 可测的空闲纯策略、连接接纳、请求/批准计数、签名缺失退出；注入签名、时钟、忙状态和退出钩子 |
| `Sources/FileOperationShared/FileOperationContract.swift`、`SystemCacheContract.swift` | 各增加只读 `approvalExpiration`；既有授权、消费、过期规则不变 |
| `Sources/FileOperationHelper/main.swift` | Listener 接入生命周期；移动 prepare/commit 跟踪；统一回复后释放请求 |
| `Sources/FileOperationHelper/SystemCaches.swift` | 系统缓存三个导出方法计数，prepare/commit 同步批准有效期 |
| `Sources/FileOperationHelper/PrivilegedApplicationUpdates.swift` | 能力探测及三个替换步骤计数，沿用全局更新忙状态 |
| `Sources/FileOperationHelper/BackgroundTaskInventory.swift` | 后台清单导出方法计数 |
| `Sources/StorageCleanerMac/Services/FileOperationReadRetry.swift`（新） | 未收到回复的只读交换等待约 1 秒后再试一次；取消/收到错误回复不重试 |
| 同目录 `SystemCacheService.swift` | 静默清单及清除前能力探测换新连接重试；写操作保持单次 |
| 同目录 `HelperBackgroundTaskInventory.swift` | 每次重试重新签名校验并新建连接，清单和构建探测均保持原超时 |
| 同目录 `AppUpdateProtectedApplicationAuthorization.swift` | 能力查询重建连接重试，准备/替换/收尾不重放 |
| `Sources/StorageCleanerMac/Features/StartupItems/Views/StartupReadPresentation.swift`（新） | 中英文未知状态、原因和用户级后台清单说明 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioStartup.swift`、`CareStudioSmartCare.swift` | 性能磁贴/智能扫描消费读取覆盖状态 |
| `Sources/StorageCleanerMac/Views/SystemUtilitiesView.swift` | 向性能页传入真实 `startupCoverage`，保留“查看”入口 |
| `Sources/StorageCleanerMac/Features/Activity/MyActivityRecommendations.swift`、`Views/CareStudio/CareStudioMyActivity.swift` | 推荐状态传入读取可用性，缺失覆盖时不根据登录项数字生成推荐 |
| `Sources/StorageCleanerMac/Features/Activity/MyActivityMacInfo.swift`、`Views/CareStudio/CareStudioActivityCards.swift` | 已用文字/容量条使用访达口径；打开页面时读取 important-usage 值 |
| `Sources/StorageCleanerMac/Features/AppUpdates/Scanning/HomebrewInventoryScanner.swift` | 在公式解析层把 stable 与 revision 合成 Homebrew 包版本；已装原始版本原样保留 |
| `script/build_and_run.sh` | Beta 正常安装在风扇助手等待旁增加文件助手只读等待 |
| `Tests/StorageCleanerMacTests/FileOperationLifecycleTests.swift`、`FileOperationReadRetryTests.swift`、`StartupReadD195Tests.swift`、`AppUpdateRevisionD195Tests.swift`、`StorageCapacityD195Tests.swift`、`BuildAndRunD195Tests.swift`（新） | 27 项新增测试：生命周期/拒绝接纳、重试与不重放、中英文文案、修订号、容量口径、脚本守卫 |
| 同测试目录 `FileOperationPeerRequirementTests.swift` | 既有服务端源码契约跟进锁内接纳的数据流，继续检查 UID、同签名 requirement、导出/启动顺序；客户端校验断言保留 |
| 同测试目录 `MyActivityD187Fixtures.swift`、`MyActivityRecommendationsTests.swift`、`MyActivityPageTests.swift` | 既有成功读取夹具显式标记覆盖可用，原有文字/顺序/数量断言保留；注明“D195＋旧值” |

按要求完整读过助手原有四个文件，以及 App 端 `SystemCacheService.swift`、`HelperBackgroundTaskInventory.swift`、`AppUpdateProtectedApplicationAuthorization.swift`、`AuthorizedApplicationMover.swift`。最后一份仅审计，未修改。

## 助手计数、批准与退出

连接在 `FileOperationHelperLifecycle.admit(uid:)` 的锁内先校验 uid ≥ 501，再调用原来的 `currentSigner` 提供者；成功后登记 UUID。连接失效只移除该 UUID，重复失效不会让计数为负。最终退出判断和 `exit(EXIT_SUCCESS)` 也在同一把锁内，退出前关闭接纳，不会在判断后漏进新连接。

所有 10 个导出方法进入时都调用 `trackedReply` 同步加请求数，然后才入工作队列；同步能力查询也计数。`ReplyCallback.call` 先调用 XPC reply，再减请求数；更新的错误回复也经过相同出口，队列等待时间同样受保护。

| 导出方法 | 执行与释放时机 |
| --- | --- |
| `prepare` | 移动串行队列；验证/授权结束后先记 commitGate 的批准有效期，再回复并减数 |
| `commit` | 同队列；消费或失效批准、移动结束后更新批准快照，回复后减数 |
| `applicationReplacementCapabilities` | 同步读取；回复后减数 |
| `prepareApplicationReplacements` | 更新串行队列；准备结果（含错误）回复后减数 |
| `replaceAuthenticatedApplication` | 更新队列；`FileOperationUpdateActivity.perform` 包住替换及回滚，结果回复后减数 |
| `finishApplicationReplacements` | 加数后发出取消，再排队等替换/回滚完成并清理；确认回复后减数 |
| `systemCacheInventory` | 系统缓存串行队列；清单回复后减数 |
| `prepareSystemCacheClear` | 同队列；先记缓存批准有效期，再回复并减数 |
| `commitSystemCacheClear` | 同队列；清除/失败结束、批准消费或失效后更新快照，回复后减数 |
| `backgroundTaskInventory` | 后台清单队列；固定只读命令的结果回复后减数 |

正常退出要求连接数=0、请求数=0、没有有效待提交批准、`FileOperationUpdateActivity.isBusy == false`，且连续保持 15 秒。纯函数为 `FileOperationHelperIdlePolicy.mayExit`。空闲计时用 uptime；批准截止时间沿用原有 Date。批准到期会唤醒检查，随后重新开始完整的 15 秒空闲窗口。

prepare 的批准在回复前记录，commit 消费后才移除；即使连接刚失效，有效批准也会保留到原截止时间。因此 prepare 与 commit 之间不会因为请求暂时归零而退出。替换批次保持原连接；活动替换及回滚另有全局 busy 和请求数双重保护。

签名提供者返回 nil：拒绝该连接、关闭后续接纳、写一条不含客户端/授权数据的 NSLog，在生命周期队列上安排约 0.5 秒后的成功退出。若还有执行中请求、有效批准或更新 busy，则延期检查，避免中途打断修改。测试用退出记录器，不退出测试进程。`FileOperationPeerRequirement` 和 XPC 协议的代码已与改前快照逐字比较，相同；未修改 identifier、叶证书指纹或 Team ID 校验。

## App 重试与安装

允许重试：`applicationReplacementCapabilities`（保护应用更新探测、系统缓存清单探测、缓存清除前探测、后台项探测）、`SystemCacheService.inventory()`、`HelperBackgroundTaskInventory.dump()`。第一次未收到回复（代理错误、连接中断/失效、原有超时）后，销毁旧连接，等待约 1 秒，新连接只重试一次。探测仍为 2 秒，缓存清单 35 秒，后台清单默认 20 秒。收到构建不匹配、解码失败、助手错误回复或取消时不重试。

不重试：文件移动 prepare/commit、缓存 prepare/commit、应用替换 prepare/replace/finish。缓存 prepare 后的身份复查绑定原批准连接，失败即终止，不通过新连接重放批准。D192 的 `@Sendable` XPC 错误/失效/回复闭包保留，`XPCCallbackIsolationTests` 通过。

`script/build_and_run.sh:976`：在退出旧 Beta 后、交换包前执行 `helper_upgrade_status.py wait-exit "$FILE_HELPER_LABEL" 30 || true`；与原风扇助手等待相邻。只有只读等待，不增加 sudo、kickstart、bootout 或信号。没有对应正式版安装分支；正式版 Sparkle 更新依靠新助手自身的空闲/签名缺失退出。`--no-launch` 安装保留既有“不退出正在使用的应用、忙时拒绝”的约束。

## 四部分行为对照与数据来源

| 部分 | 旧行为 | 本轮行为 |
| --- | --- | --- |
| 助手 | 旧可执行文件被替换后，驻留进程可能永久拒绝连接 | 正常空闲退出；读不到自己的签名则拒绝后尽快安全退出；App 只读请求有一次新连接重试 |
| 登录项 | 缺失系统覆盖时数字可能被呈现为 0/正常，原因仅在列表帮助里 | 性能页写“没读到登录项 / Login Items Not Read”，使用 diagnostic 原因或后备说明；后台写“至少 N 个”、只含用户级项目；智能扫描同样写未知；读到时保留全部旧文案 |
| Homebrew | stable 不含 revision，显示 `4.0.0 → 4.0.0` | 解析得到 `4.0.0_1`；已装版本的 `_1` 保留，支持 `4.0.0_1 → 4.0.0_2`；D192 更新确认规则未改 |
| 已用 | 我的活动文字和条形图用严格 free；空间地图用访达 free | 我的活动文字用 `userUsedBytes`、条用 `userUsedRatio`，与空间地图一致；健康评价仍用原严格 free |

本副本原有登录项推荐阈值是 ≥5，本轮增加覆盖可用条件，连旧扫描残留数字也不会在读取失败时生成推荐；没有把阈值改为 0。

Homebrew 数据流：`HomebrewInventoryParser.parse` → `HomebrewPackageMetadata.currentVersion` → `ApplicationInventoryScanner.syntheticApplication` / `HomebrewProvider` → `InstalledApplication.availableVersion` → 现有版本行。本轮不在视图拼 revision。夹具通过实际 ProviderRegistry 分类验证版本和 D192 的确认状态。

容量数据流：我的活动页面 `.task` → `MyActivityMacInfo.read()` → `StorageCapacityService.snapshot()`（页面打开时一次 important-usage 查询）→ `userUsedBytes`/`userUsedRatio`。空间地图为 `DiskScanner.swift:941` 附近的 `snapshot(path: rootPath)` → `capacity.userAvailableBytes` → `StorageMapAnalysisResult.volumeAvailableBytes`，页头的 `usedVolumeBytes = total - available`。给定 total 994.61、free 77.54、important 204.22 GB，两页显示已用 790.39 GB；严格已用仍是 917.07 GB。`MyActivityHealth.evaluate` 的 `capacity.availableBytes` 判断未动。未修改另一个会话负责的 Space Lens 两个文件。

## 验证与限制

所有日志均相对 `.build/d195-evidence/`。构建请求均使用 `nice -n 15` 和 `--jobs 4`；本沙箱返回 `nice: setpriority: Operation not permitted`，Swift 仍运行，不能声称实际优先级已降低。依赖仅从已有 `~/Developer/.sc-build/v2.0.1/bootstrap` 复制到本副本 `.build/codex`，未联网。

实际构建命令（每次均设 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`、`CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"`）：

```sh
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox
```

`build.log`、`build-final.log`、`build-fixes.log`、`build-final-tests.log` 均 exit 0；首次完整构建 341.40 秒，最后为测试夹具增量构建。改动文件新增编译警告 0；其余既有/沙箱缓存警告留在 `all-warning-lines.txt`，未改其他模块消警告。基线参考用户指定 `baseline-warnings.txt`；当前集成副本还会报告未改动的 `UpdateAskpassInvocationRegistry`、`APFSCloneReplacement` 警告。

实际构建、测试和守卫命令另存 `commands.txt`；定向过滤器为 `focused-test-filter.txt`。实际相关回归命令：

```sh
read -r D195_TEST_FILTER < .build/d195-evidence/test-filter.txt
nice -n 15 swift test --scratch-path .build/codex --skip-build --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --filter "$D195_TEST_FILTER"
```

过滤器保存了 48 个实际类名，以 `/` 结尾，匹配确认后执行。显式关闭 live inventory 的既有 opt-in，并 unset `APP_UPDATE_AUDIT_INSTALLED/CANDIDATE/ROOT/IMAGE`，避免联网和真实更新。没有删除、跳过或放宽任何既有断言；display-bound 类仅按用户要求不运行。

- PASS：`tests-focused.log`，47 tests，0 failures，exit 0；含新增 27 项、我的活动既有夹具/推荐/页面、XPC 回调隔离、签名服务端与所有客户端顺序检查。
- BLOCKED：`tests-acceptance.log`，**Executed 718 tests, with 7 tests skipped and 28 failures (23 unexpected)**，exit 1；实际 25 个既有用例失败，28 条失败断言。新增六类 27 项在这次整组中也全部通过。失败索引为 `test-failures-final.txt`、`blocked-methods.json`，不把本次整组称为通过。初次 `tests.log` 为 718 项/42 条失败断言，中间 `tests-final.log` 为 718 项/31 条；本轮夹具/源码契约问题均已修正，保留这些中间日志。
- PASS：`python3 -B script/display_bound_tests.py --check`，exit 0，63 in-process、1 out-of-process、1 exempt（`display-bound-check-final.log`）。清单未修改。
- PASS：`python3 -B script/check_deletion_process_inventory.py`，exit 0，182 entries/274 uses（`deletion-inventory-final.log`）。
- PASS：`python3 -B script/check_private_api.py`，exit 0，10 allowlisted uses（`private-api.log`）。
- PASS：`bash -n script/build_and_run.sh`、`git diff --check`，exit 0。
- PASS：只在证据副本翻转空闲策略的批准条件，运行与新测试相同的 16 组合；原实现 exit 0，反转后 exit 1、2 failures（`mutation/*-test.log`）。独立 XCTest 链接尝试未能载入 XCTest Swift overlay，改用相同方法的独立断言记录器；未修改产品源文件做反证。

新增类实际通过数：`FileOperationLifecycleTests` 9、`FileOperationReadRetryTests` 7、`StartupReadD195Tests` 5、`AppUpdateRevisionD195Tests` 2、`StorageCapacityD195Tests` 3、`BuildAndRunD195Tests` 1。

剩余失败分布（断言数）：`AppUpdateCoordinatorTests` 3、`AppUpdatePresentationIntegrationTests` 11、`AppUpdateRepair2Tests` 3、`BackgroundTaskInventoryTests` 1、`FileOperationPeerRequirementTests` 1、`SmartCareTests` 4、`StartupScanningTests` 5（其中一个方法有 4 条签名/能力断言）。20 个方法因 home 夹具创建受限、3 个因 socket bind 受限，另外 2 个方法因系统签名证书/验证能力失败。7 项跳过沿用既有 live/真实安装审计或签名夹具不可用保护，未新增跳过。

沙箱限制需主会话重跑：既有测试工厂在真实 home 下创建唯一的操作夹具被拒、Unix socket bind 被拒，以及 `/usr/bin/true` 签名证书不可用（只读 `codesign -dv` 的证据为 `platform-true-signature.log`，显示 `Authority=(unavailable)`）。未修改对应保护策略或将夹具挪到会被产品拒绝的位置；签名/启动项断言失败仍需主会话确认。

本次选中但按 D106 不运行的窗口类：`AppUpdateAuthorizationRepairTests`、`StartupApplicationUpdateSchedulerTests`、`StartupItemsDashboardContractTests`（`window-tests-not-run.txt`）。主会话窗口全量还应观察 `CareStudioWindowReviewTests` 的登录项磁贴/智能扫描/我的活动布局；真实运行时的未知原因长文案和英文换行也需观察。Release、完整窗口门禁和已安装 Beta 实机行为均 NOT RUN。

## 主会话安装后实测

1. **第一次装新助手后，用户必须先重启，或由主会话按用户明确授权手动换掉从 10-23 起驻留的老进程。** 老进程没有 D195 退出代码，安装等待最多 30 秒后会继续，不能靠本次补丁让它自动升级。本 Worker 未停止该进程。
2. 第一次恢复后运行垃圾扫描和性能扫描：系统缓存卡出现，登录项与系统设置对应；不触发管理员安装/注册对话框。模拟助手读不到时，磁贴和智能扫描如实写未知，并展示诊断原因，查看按钮仍进入列表。
3. 退出所有客户端，确认新文件助手约 15 秒后自行退出；再安装一次 Beta，观察安装只读等待和后续 pid/签名构建换新。另检查失效签名拒绝后约 0.5 秒安全退出、下一次只读连接可恢复。
4. prepare 后等待确认、活动应用替换/回滚期间观察助手不退出；取消/断线后核对没有自动重放文件移动或清除。
5. 同一时间对比“我的活动”和空间地图的已用文字与容量条；健康风险评价仍保留原严格口径。
6. 应用更新列表检查 ada-url、cffi 等仅 revision 更新显示 `_N`，已有 `_N` 的当前版本也保留；不实际安装更新即可验收显示。

下一入口：本交接、`d195-code.patch`、`tests-focused.log` 和最终相关回归日志。主会话自行复核差异后集成，并在已授权环境完成剩余门禁与实机验收；本副本与证据未入 LayerFS、未 commit/push。
