# P02 · D182 系统缓存清除

工作目录：`/Users/developer/Developer/sc-worktrees/p02-syscache`。输入说明为 2.0.1 集成树完整副本；实际 Git HEAD 为 `6e660a59`，已有大量已跟踪及未知集成内容，未还原、提交或重排。入口状态和原差异保存在 `.build/d182-evidence/status-before.txt`、`existing.diff`；本次涉及的原文件保存在同目录 `before/`。

## 文件与作用

| 文件 | 本次改动 |
| --- | --- |
| `Sources/FileOperationShared/SystemCacheContract.swift` | 两项白名单、请求/回复、严格解码、每次管理员授权策略和一次性批准门 |
| `Sources/FileOperationShared/SystemCacheClearing.swift` | 逐级无链接打开、限时限量清单、目录身份回读、相对描述符永久删除；内部临时目录注入只供测试 |
| `Sources/FileOperationShared/FileOperationContract.swift` | 新授权权限名和三个 optional XPC 方法 |
| `Sources/FileOperationHelper/SystemCaches.swift` | 独立串行队列、只读清单、导入授权、prepare/commit；只把枚举映射的白名单交给删除器 |
| `Sources/FileOperationHelper/main.swift` | 每条已认证连接持有自己的系统缓存批准门 |
| `Sources/StorageCleanerMac/Services/SystemCacheService.swift` | 静默清单、同签名同 build 探测、管理员授权、身份复核、提交和不明结果隔离 |
| `Sources/StorageCleanerMac/Services/SystemCachePresentation.swift` | 中英文名称、说明、冻结确认计划、容量与结果文字 |
| `Sources/StorageCleanerMac/Services/AuthorizedApplicationMover.swift` | 仅把已有签名验证方法改为模块可见，系统缓存注册前复用；移动/恢复流程未改 |
| `Sources/StorageCleanerMac/Stores/ScanStore.swift` | 扫描完成后异步读清单、发布状态、确认前冻结计划、显式确认清除和完成后重读清单 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSystemCaches.swift` | 两项默认不勾选的列表、每项大小和重建/不可撤销说明、管理员密码与永久删除确认页 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkResults.swift` | 新卡片、查看入口、可用时计入垃圾总量；旧布局不重排 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkManager.swift` | 追加系统缓存查看入口 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSmartCare.swift` | 智能扫描摘要计入同一可用清单；默认运行不包含系统缓存 |
| `Tests/StorageCleanerMacTests/SystemCache{Contract,Clearing,Presentation}Tests.swift` | 请求/批准门、临时目录安全删除、假服务顺序和中英文展示测试 |
| `Tests/StorageCleanerMacTests/FileOperationPeerRequirementTests.swift` | D182＋旧值：客户端清单由 4/3 增为 5/4，保留原断言 |
| `Tests/StorageCleanerMacTests/TestScanStoreFactory.swift` | 可注入假服务，默认不可用，防止其他测试访问真实助手；回收清单任务 |
| `script/deletion-process-inventory.txt` | 登记共享删除器唯一 `unlinkat` 调用；没有新增生产进程启动 |

## 契约和授权

白名单只有共享 `SystemCacheID.directoryPath` 中的两个目录：`coreSymbolication`、`iconServices`。路径字面量不出现在客户端或助手实现。这里不重复绝对路径，避免维护多个来源。

清单为 `items` 数组；每项 `cache`、可选 `allocatedBytes`、`entryCount`、`device`、`inode`、`failure`。无法打开时大小/身份为 nil；超时、条目/深度上限或读取错误保留已测部分并附固定原因代码。两项清单合计 30 秒，每项最多 500,000 个条目，深度硬上限 64，不读文件内容。

清除请求：`requestID`、`caches` 编号数组、`directories`（每项 `cache/device/inode`）、`expiresAt`。4,096 字节上限；1…2 个唯一已知编号、身份与编号一一对应、inode 非零；根对象和身份对象严格字段集合，任何额外字段（包括路径）都拒绝。创建后 60 秒，到达时剩余有效期不得超过 65 秒。

回复：`requestID`、可选 `prepared`、`items`、可选 `failure`；每项为 `cache/deletedEntries/freedBytes/skippedEntries/failure`。错误只回代码，不回系统原文或路径。

清单先检查当前捆绑路径的助手进程确实在运行，再设置同签名者 requirement，并通过 `applicationReplacementCapabilities` 比对 build。未运行、签名/版本不符或通信失败安静返回 nil，不安装、注册或请求授权，不显示卡片。

只有确认页的“永久清除”会调用清除服务。服务先获取 `.cleanup` 独占租约（复用现有所有权及隔离机制），检查捆绑助手签名，再 `prepareHelper()`；这时可能出现系统后台项目批准界面。后台线程创建新 AuthorizationRef：基于 `kAuthorizationRuleAuthenticateAsAdmin` 的实际规则建立专用 right，禁用 shared 并把 timeout 设为 0；已有规则若不满足该条件则拒绝。权限名为 `FileOperationIdentity.helper + ".clear-system-cache"`，说明“清除所选系统缓存”及英文。外部授权只在内存传递，defer 中 destroyRights。

助手导入外部授权并复查规则，通过与原文件移动相同的 flags 检查权限；SecurityAgent 可以在发起用户会话中再次要求管理员认证。请求 ID 在认证前保留，同连接最多 128 个且不可重放。认证完成后只批准原请求 15 秒。客户端随后在同连接再次查询：批准期间仅逐级打开回读两项目录的 dev/ino，不重新统计大目录，从而避免消耗提交窗口。与冻结清单不同就放弃；然后发原请求 commit。助手一次性消费批准，文件夹最终身份仍由删除器重查。失败/不匹配的 commit 同样销毁批准。

一旦 commit 发出，不以界面任务取消提前释放租约。若回复丢失、格式不符或超时，保留现有 cleanup quarantine，提示结果待核实、重开应用后再扫描，阻止其他清理与可能未完成的 root 工作重叠。

## 删除检查

1. 从 `/` 起，对每个路径分量使用 `O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`；拒绝相对、空、点/上级、NUL 等路径。任一级失败则整项不删。
2. 保持路径链上目录描述符，`fstat` 目标并严格匹配期望 dev/ino；文件夹自身没有 unlink 调用。
3. 遍历前以及每次删除前复查目录链仍指向原目录，防止目录被换成链接或搬离原父目录后继续使用旧描述符。
4. 子项用原始名字字节和 `fstatat(AT_SYMLINK_NOFOLLOW)`；任何类型 dev 不同都跳过，包括挂载点。
5. 子目录使用 `openat(O_NOFOLLOW | O_DIRECTORY)`，核对打开前后 dev/ino/类型和名字绑定；递归深度硬上限 64。
6. 删除前再次复查目录链及当前项身份，目录用 `unlinkat(AT_REMOVEDIR)`，其他类型（包括链接）只用 `unlinkat(..., 0)`。不跟随链接、不读文件内容、不调用 Foundation 删除、不执行进程或 shell。
7. 每个成功删除项按删除前 `st_blocks * 512` 饱和累加 freedBytes；单项失败记 skippedEntries 后继续独立兄弟项。删除另有限制：每项最长 120 秒、最多 1,000,000 个条目。
8. 这是删除时量到的分配大小之和，不能证明 APFS 已释放相同空间；快照/硬链接、缓存重建或守护进程仍打开已删文件都可能使可用空间变化滞后。

## 页面与探针

垃圾结果卡片只在清单可用时显示，开发者垃圾页面不重复列出；智能摘要同口径。部分计量会在卡片和列表说明；有此卡片时，页脚明确普通垃圾进入废纸篓、系统缓存单独确认永久删除。清单与普通垃圾选择分离，打开时两项都不勾选，查看/勾选/请求确认/取消都不清除。确认页复用 `OperationConfirmationFactsView`，逐项列出大小，明确永久删除、不可撤销和管理员密码。图标缓存提示可能需重启或重新登录。容量走 `ByteFormat.storageString`，计数走 `ByteFormat.count`，新增文案均走项目中英文入口。

调试探针：`careStudio.systemCaches`、`careStudio.systemCaches.confirmation`。辅助功能标识：`systemCache.select.coreSymbolication`、`systemCache.select.iconServices`、`systemCache.reviewClear`、`systemCache.confirmClear`、`systemCache.result`。

## 验证记录

最终状态：实现已落盘；PASS 最终构建、47 项相关测试（含全部 26 项新增测试）和两项静态门禁。BLOCKED 完整限定门禁：较大范围的 89 项测试仍记录 7 次失败，不能视为全部验收通过。没有安装、运行真实清除或提交。

证据统一位于本工作树 `.build/d182-evidence/`；供集成核对的仅本次增量为 `d182.patch`，文件摘要为 `d182-manifest.json`，不包含初始集成树的其他修改。

| 测试类 | 数量 | 最新结果 |
| --- | ---: | --- |
| `SystemCacheClearingTests` | 10 | PASS：子项删除而根保留、分配块计数、文件/目录/断链不跟随、路径祖先链接拒绝、dev/ino 不符、stat 后换链接、深度上限、部分失败继续、分批目录枚举不漏项 |
| `SystemCacheContractTests` | 8 | PASS：严格解码、未知/重复/空编号、路径及未知字段、超大/过期/未来请求、单次批准/不同/超时提交、时钟倒退、零超时独立管理员规则、源码边界 |
| `SystemCachePresentationTests` | 8 | PASS：不可用静默、默认不选择、查看/取消/错误确认不清除、确认后只调用一次、清除后刷新、失败文字、确认事实/总量、中英文与页面源码守卫 |
| `FileOperationBoundaryTests` | 17 | PASS |
| `PermanentDeletionInvariantTests` | 4 | PASS；D23 等原删除链未改 |
| `FileOperationPeerRequirementTests` | 5 | 新客户端绑定守卫等 4 项通过；旧系统二进制证书测试未取得 SecCertificate，1 次失败，根因未在本沙箱确认 |
| `BackgroundTaskInventoryTests` | 9 | 旧页面计数测试创建隐藏操作 home 被拒绝，1 次失败 |
| `CareStudioRenderReviewTests` | 7 | 旧标题与渲染测试创建隐藏操作 home 被拒绝，2 次失败 |
| `TestPreferenceHygieneTests` | 21 | 源码偏好隔离守卫通过；系统拒绝临时偏好 plist 的 sandbox extension，两项持久化测试记录 3 次断言失败 |

新增假服务测试使用 `uniqueOperationRoot` 登记一个唯一但不落盘的操作 home，并在收尾断言目录仍不存在；其他数据根仍为临时目录，真实写操作继续由 `TestOperationFactory` 拒绝。未改 TestFileSystem 的安全断言，未覆盖 HOME。删除夹具使用 libc `realpath`：本机 Foundation `resolvingSymlinksInPath()` 保留 `/var` 别名，首次删除测试因此全部被安全拒绝；修正夹具后全部通过，未允许删除器跟随链接。对应诊断为 `temp-path-probe.log`。

最终构建命令（exit 0，`build-complete.log`/`.exit`）：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache" \
nice -n 15 swift build --scratch-path .build/codex \
  --cache-path .build/codex/cache --config-path .build/codex/config \
  --security-path .build/codex/security --disable-automatic-resolution \
  --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox
```

最终通过的测试命令（exit 0，`tests-complete.log`/`.exit`，47 项、0 失败）：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache" \
nice -n 15 swift test --scratch-path .build/codex \
  --cache-path .build/codex/cache --config-path .build/codex/config \
  --security-path .build/codex/security --disable-automatic-resolution \
  --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing \
  --filter '^StorageCleanerMacTests\.(SystemCacheClearingTests|SystemCacheContractTests|SystemCachePresentationTests|FileOperationBoundaryTests|PermanentDeletionInvariantTests)'
```

完整限定范围使用同样 test 参数，加 `STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`、`STORAGE_CLEANER_VERIFY_ROOT="$PWD/.build/d182-evidence/verify"`，filter 为：

```text
^StorageCleanerMacTests\.(SystemCacheClearingTests|SystemCacheContractTests|SystemCachePresentationTests|FileOperationBoundaryTests|FileOperationPeerRequirementTests|BackgroundTaskInventoryTests|CareStudioRenderReviewTests|TestPreferenceHygieneTests|PermanentDeletionInvariantTests)
```

该命令 exit 1，89 项、7 次失败（3 unexpected）；证据 `tests-final.log`/`.exit`。其中新增 26 项全部通过，新增客户端的 requirement 源码守卫也通过。没有跳过或删去原测试；只在已知环境阻塞后，用小范围补跑验证修改后的代码。

```bash
python3 -B script/display_bound_tests.py --check
# exit 0；63 in-process、1 out-of-process、1 exempt；display-bound-final.log
python3 -B script/check_deletion_process_inventory.py
# exit 0；175 entries、267 uses；deletion-inventory-final.log
```

其他实际验证：三个新增测试文件 `swiftc -frontend -parse` exit 0；只读 `security authorizationdb read authenticate-admin` exit 255，未拿到策略内容，未写入策略；真实授权规则行为仍待主会话验证。所有本次修改的 Swift 文件在最终编译及本轮构建日志中均无新增警告；未触及文件的警告保留在日志，包括既有测试警告以及 `UpdateAskpassInvocationRegistry`/`APFSCloneReplacement` 的警告，未为清零而改其他代码。

中间构建记录（同样的私有离线参数，除最初两次依赖准备尚未就绪）：`build.log` 1（DNS）；`build-offline.log` 1（依赖 workspace-state 未准备完）；`build-offline-prepared.log` 1（Substring 转 C 字符串编译错误）；`build-compile.log` 1（默认参数函数不能直接传给 Optional.map）；`build-tests.log` 1（ScanSessionID 类型）；`build-validation.log` 1（构建中修改可见性导致旧目标文件链接符号不匹配，后续稳定重编解决）；`build-final.log` 0；`build-reviewed.log` 0；`build-fixture-fix.log` 0；`build-inert-fixture.log` 0；`build-complete.log` 0。最初 `tests.log` 1（88 项、40 次失败，含已修正夹具问题）；修正物理路径后 `tests-focused.log` 0（39 项）；最终 `tests-final.log` 1（89 项、上述 7 次环境/系统证书失败）；`tests-complete.log` 0（47 项）。

初次指定构建命令 exit 1：GitHub DNS 在沙箱不可用；没有更换依赖版本。经本机只读检查，`~/Developer/.sc-build/v2.0.1/debug/checkouts/Sparkle` 的 HEAD 与 `Package.resolved` 一致（Sparkle 2.10.0），将依赖源码与现有二进制 artifact 复制到当前私有 scratch，调整仅 scratch 的 workspace-state 路径，并使用 `--disable-automatic-resolution` 和私有 cache/config/security 路径离线构建；未复制本项目编译产物。

所有构建仍带指定 `nice -n 15`、`--jobs 4`；沙箱报告 `nice: setpriority: Operation not permitted`，无法证明进程实际获得低优先级。没有提升权限。

## 主会话测试版实测（本 Worker 不安装、不操作真实缓存）

1. 安装同 build、同签名的 Beta 和助手后，助手未运行时扫描：无卡片、无系统授权界面。运行但旧 build 的助手也应静默不可用。
2. 助手已运行且同 build 时垃圾/智能扫描：核对两项名称、可读大小、默认未勾选、垃圾总量与智能摘要一致；普通扫描/查看/勾选/取消确认不得触发注册或密码界面。
3. 仅勾选系统符号缓存，核对确认页永久删除/不可恢复、每项容量和管理员密码。取消系统认证不得删除；成功后核对根文件夹 dev/ino 保持不变、内容减少，并重新读取清单。
4. 再次清除必须再次认证；图标缓存独立测试重建及重新登录提示。检查 App 仍响应，其他清理拿不到 `.cleanup` 租约。
5. 认证后变更目标身份、重复/超时/不同 commit、连接中断均应拒绝或保持隔离；不得扩展到第三条路径。
6. 清除前后记录同一数据卷可用空间和两项目录的分配大小。先用小项验证，再由用户明确确认大项；核实此前约 41.5 GB 符号缓存的内容确实删除。若守护进程仍持有已删文件，目录统计会下降但可用空间未立即增加：由主会话只读检查相应进程的已删除打开文件，等待系统关闭/按获准流程重启服务或 Mac 后复测空间；不得由本功能杀进程。

真实 root 访问、SIP/系统卷实际删除许可、SecurityAgent 对话、后台项目批准、重建/图标恢复、实际磁盘释放量均未在沙箱实测。JEV 没有可调用且来源已确认的工具，未调用；按 code-review-and-quality 进行本地代码与验证复核。
