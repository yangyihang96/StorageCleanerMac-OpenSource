# p03-speed · D192④⑤⑥

状态：实现完成；构建和两项静态门禁 PASS，完整选择测试因沙箱权限／显示门禁 BLOCKED。仅修改 `/Users/developer/Developer/sc-worktrees/p03-speed`；无 commit、安装、联网、清理真实资料或修改 DECISIONS。沿用当前模型；无 JEV 调用，未发现相应工具且本轮无来源／预算授权。

## 改动清单

- `Features/CloudCleanup/CloudDriveScanner.swift`：保留 MetadataReader；元数据以 `isDataless` 替代 downloadingStatus。一次 lstat 读取 SF_DATALESS；枚举器预取本地大小属性，缺失时以 st_size / st_blocks×512 回退；保留完整的目录文件清单。
- `Views/CareStudio/CareStudioTheme.swift`：扫描标题改为“正在读取云盘…”／“Reading cloud storage…”。共享主题没有当前服务字段；进度路径仍能指示所读服务。
- `Services/DiskScanner.swift`：whereNeeded 用本地 stat 标志分类，不调用 FileProvider 或 custom 云端源；注入 fileStatus 供夹具模拟标志。目录戳和硬链接身份复用该 stat。占位文件的计数为 0，占位目录／选中的占位根不枚举。
- `Stores/ApplicationsScanCoordinator.swift`（新）、`Stores/ScanStore.swift`（仅增加一个 coordinator 属性）、`Stores/SmartCareLiveScanner.swift`（仅共享现有网络路径检测）：应用首页的本机扫描与只读更新检查按顺序执行。
- `Views/CareStudio/CareStudioApplications.swift`：仅首页扫描入口、结果磁贴及所需观察属性；进行中先显示“正在检查更新…”；未改概览页页头和原来第 179 行附近的操作。
- `Features/AppUpdates/Coordination/ApplicationUpdatePlanBuilder.swift`：统一直接计划和批次的系统管理门槛，批次入口先将重复副本转回原有手动处理，授权分支不再绕过它。
- `Features/AppUpdates/Models/AppUpdatePresentationModels.swift`：isUpdateAvailable 使用确认谓词；Homebrew 复用 D190 的方向判断，保留仅修订号变化的更新；低目标公式进入手动目录但不计新版本。
- `Features/AppUpdates/Views/AppUpdateLightfieldPresentation.swift`、`AppUpdatesView.swift`：标题读取 confirmedUpdateCount；管理行显示现有 D190 原因说明。
- 测试：改 `CloudDriveD185Tests.swift`、`StorageMapAnalysisEquivalenceTests.swift`；新增 `StorageMapD192Tests.swift`、`AppUpdateD192Tests.swift`、`ApplicationsScanD192Tests.swift`。

以上源码路径均相对 `Sources/StorageCleanerMac/`；测试相对 `Tests/StorageCleanerMacTests/`。初始文件副本在 `.build/d192-evidence/before/`，本轮专属差异在 `.build/d192-evidence/changes.diff`（与原来已经存在的集成差异分开）。

## 云盘和空间地图判断

| 情况 | 旧云盘清理 | 新云盘清理 | 旧地图／everyItem | 新地图 whereNeeded |
|---|---|---|---|---|
| 普通本地文件 | 查询 downloadingStatus 后计分配大小 | 本地标志非 dataless，计分配大小 | 云端源判为本地则计大小 | 不查云端源，计原有大小口径 |
| SF_DATALESS 文件 | 状态为 notDownloaded 时计云端数量／逻辑量 | 标志直接计云端数量／逻辑量 | ubiquitous 且非 current 标为占位 | 无论位置，标志直接标为占位、本机计 0 |
| SF_DATALESS 文件夹 | 枚举目录，逐项查状态 | 保留完整枚举，只换文件状态判断 | 非 current 的云端目录不进入 | 标志决定不进入，包括直接选中的根 |
| 已下载但非最新 | 当作已下载文件 | 同左 | 仍标占位、受不可选／估算限制 | 按本机实占计，允许原有本地操作资格检查继续工作 |

空间地图的 isUbiquitous 仅用于本次遍历内部：目录继承、并行 job 传递，以及和 isCurrent 合成 cloudPlaceholder；它没有进入不可变索引、透镜或方块图的独立字段。新实现按 Mobile Documents／CloudStorage／当前用户 Desktop、Documents 位置作提示，dataless 标志也视为云端；Desktop/Documents 提示可以包括本地目录，但不影响占位判断和计数。isCurrent 在 whereNeeded 表示“有本地数据”，不再承诺服务器版本最新。

cloudPlaceholder 控制目录是否继续走、是否探测应用包内容、目录完整性／blocked 路径、文件 estimated 标记；后者经 StorageMapIndexedEntry.isCloudOnly 进入空间透镜／Treemap 和文件操作的云端占位防护。D189 的镜像排除逻辑保持原样。everyItem 保留逐项云端查询和 current 分类，继续作为 N21 对照；两模式共同明确占位文件大小为 0，避免占位元数据块或逻辑长度被算成本机内容。等价夹具给旧源和新 stat 注入相同占位事实，保留索引、并发和取消断言；取消 gate 从旧的云端查询点移动至本地 stat 点。

旧 storageMapNeedsCloudState 另供 FileContentReadGuard 使用，因此保留原 API 与路径匹配，内容读取前的安全检查不变；新的空间地图不调用它。文件分析的其他专用扫描不在本轮更改范围内。

不会触发下载的依据：改动扫描只枚举目录和读取 URL 预取的本地属性／lstat；不打开文件、不读取数据、不协调下载、不调用 startDownloading 或物化 API；空间地图的 SF_DATALESS 目录在进入前截断；云盘清理保留完整文件枚举，仅枚举元数据。应用包探测的原实现也继续被占位判断挡住。没有使用真实 iCloud、CloudStorage、Volumes 作测试。

## 应用首页扫描顺序

首页按钮先同步置应用读取状态，继续现有 refreshInstalledApps；协调任务等待 isLoadingInstalledApps 结束，再用现有 NWPathMonitor 检测网络（只读网络路径，不发请求），刷新 HeavyWorkActivityStore 快照，最后调用 checkAppUpdatesForSmartCare。该入口自己取得唯一 .appUpdates 租约，不恢复保存队列／官网向导，不执行自动安装策略；忙碌时按原入口跳过。没有额外套一层租约，避免自我冲突。

扫描任务由 ScanStore 持有的 coordinator 管理，首页切到结果后继续；有更新检查时先显示占位磁贴，完成后只在确认数大于 0 时显示原磁贴。离线时不发起更新检查，抑制本次扫描以前的更新磁贴；之后手动查更新得到新的结果日期时可重新显示。更新磁贴与本机应用枚举没有各自并行启动重活。

## 59／63 的依据与修复

- `hasPresentableUpdate` 只反映宽泛状态，其中 failed、queued 等并不能证明远端更高。旧目录允许有更新器但版本未知的应用进入管理目录，Lightfield 再按这个宽状态计行，于是失败的应用内更新项被算成“有更新”。现在行、标题和共享计数都用 hasConfirmedPresentableUpdate。
- `canJoinAutomaticUpdatePlan` 原来直接调用 isEligibleForAutomaticUpdate：会排除重复副本和当前需要退出／授权的项目，但没有完整的系统管理门槛。`canJoinAutomaticUpdateBatch` 通过 destination，包含退出／授权分支；Homebrew 和官网的授权分支原来在检查重复副本前直接返回 requiresAuthorization。而 confirmed 谓词显式排除重复副本，因此会出现批次大于确认数。现在两条计划路径共用系统门槛，destination 在确认有更新后即把重复副本保留为手动处理，禁止它进入退出／授权／直接更新批次。
- 本轮用四个重复且需授权的 Homebrew 夹具重现“旧批次 4、确认数 0”，新实现三项均为 0；还覆盖系统、App Store、Sparkle、Homebrew 修订号、低目标公式、Epic／Claude／OrbStack／Surfshark 自更新 cask 和失败的应用内更新器，验证批次 ID 是确认集合的子集。
- **实际四项的类别和证据边界**：对当前代码的同一快照，旧 Lightfield 的差集只能来自 `hasActionableInApplicationPath && hasPresentableUpdate && !hasConfirmedPresentableUpdate`，即有应用内更新路径、但没有确认更高版本的行（常见为 failed 的 Sparkle／厂商更新器）；较低版本公式旧代码根本未入目录，不是标题多四项的来源。批次差集来自被授权分支放行的重复 Homebrew／官网项目；批次还可能少了已确认但须手动处理的 App Store 等，因此“批次 − 确认数 = 4”不能证明批次恰好多了同四项。没有当次 646 项扫描目录／JSON，不能指认实际应用名称，也不能声称标题与批次的差集相同。主会话须保存同一次扫描的三个 ID 集合核对；本轮四个重复授权夹具证明的是确定的越界路径。
- openssl@3 这类较低目标公式保留 D190 原说明，在“管理更新 → 手动处理”显示；不计入确认数，不进入计划或批次。不重新解释 Homebrew 的版本方向，直接复用既有安全函数。

## 验证与剩余事项

最终构建 exit 0，改动文件 **0 个编译警告**（逐一匹配所有构建日志；继承警告另列 `warnings-review.txt`）。指定选择范围实际执行 **794 个测试**，670 通过、115 失败用例、9 跳过；XCTest 报 142 条失败事件（97 unexpected），exit 1。115 个失败用例逐项分类：**94 个夹具写家目录被拒、3 个本地套接字被拒、18 个窗口被 D106 门禁拒绝**；无未分类失败。不能把完整测试写成 PASS。

新增 11 个测试中 **8 个通过、3 个 BLOCKED**：两个 CloudDrive 测试、三个 StorageMap 测试、三个 AppUpdate 测试通过；ApplicationsScanD192Tests 三个测试都在既有 TestScanStoreFactory 创建家目录夹具时失败，尚未进入扫描顺序／离线／租约断言。没有改工厂、扩沙箱、跳过已有测试或放宽阈值。

| 测试类 | 通过 | BLOCKED 失败 | 原有 opt-in 跳过 |
|---|---:|---:|---:|
| CloudDriveD185Tests | 8 | 0 | 0 |
| CloudDriveProviderTests | 2 | 0 | 0 |
| StorageMapD192Tests | 3 | 0 | 0 |
| StorageMapAnalysisEquivalenceTests | 9 | 1 | 0 |
| StorageMapIndexEditingTests | 1 | 8 | 0 |
| StorageTreemapLayoutTests | 25 | 1 | 0 |
| AppUpdateD192Tests | 3 | 0 | 0 |
| AppUpdateNoDowngradeD190Tests | 6 | 0 | 0 |
| ApplicationsScanD192Tests | 0 | 3 | 0 |
| ApplicationsManagerTests | 8 | 5 | 0 |
| SmartCareTests | 12 | 3 | 0 |
| UIConsistencyRegressionTests | 46 | 0 | 0 |
| CareStudioRenderReviewTests | 8 | 0 | 0 |
| SpaceLensBubbleIconTests | 2 | 0 | 0 |
| SpaceLensSidebarTests | 35 | 0 | 0 |
| SpaceMapTreemapLayoutTests | 19 | 0 | 0 |
| SpaceMapTreemapPainterTests | 37 | 0 | 0 |
| SpaceMapTreemapWindowTests | 0 | 7 | 1 |
| SpaceLensSidebarWindowTests | 0 | 11 | 1 |

完整逐类／逐用例清单：`.build/d192-evidence/test-summary.json`；失败原文：`test-errors.txt`；分类：`failure-categories.json`。D189 的镜像排除断言在 StorageTreemapLayoutTests 中已通过。N21 等价性 9 个通过，只有创建家目录的晚到 worker 夹具被拒；原来的 2 秒取消阈值和索引等价断言保持不变。StorageMapAnalysisPerformanceTests 是既有 opt-in 测量器，本次按给定命令未启用；未测真实云盘吞吐，未改时间阈值。其余跳过是原有真实下载／挂载／主机扫描／截图的 opt-in 用例。

实际验证命令（cwd 均为本 worktree）：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox

unset STORAGE_CLEANER_TEST_DISPLAY STORAGE_CLEANER_TEST_DISPLAY_LOG STORAGE_CLEANER_RUN_LIVE_APP_SCAN STORAGE_CLEANER_N21_PERF
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing --filter '^StorageCleanerMacTests\.(ApplicationsScanD192Tests|CloudDriveD185Tests|StorageMapD192Tests|CloudDrive[A-Za-z]*Tests|StorageMap[A-Za-z]*Tests|StorageTreemap[A-Za-z]*Tests|SpaceMap[A-Za-z]*Tests|SpaceLens[A-Za-z]*Tests|FileAnalysis[A-Za-z]*Tests|StorageCapacityBasisTests|AppUpdate[A-Za-z0-9]*Tests|ApplicationsManagerTests|SmartCareTests|CareStudioRenderReviewTests|UIConsistencyRegressionTests)/'
python3 -B script/display_bound_tests.py --check
python3 -B script/check_deletion_process_inventory.py
```

| 命令／轮次 | exit code | 证据 |
|---|---:|---|
| build 1 | 1 | `build-1.log`：删除旧 helper 后发现 FileContentReadGuard 调用；已恢复该 helper 原语义 |
| build 2 | 1 | `build-2.log`：共享谓词后私有 enum 的属性访问级别不符；已保持该属性 fileprivate |
| build 3 | 0 | `build-3.log`：全量 1,248.40 秒 |
| build 4 | 0 | `build-4.log`：最后云盘清单修改后增量 62.12 秒 |
| test 1 | 1 | `tests-1.log`：794 个；另暴露重复副本应保留手动语义、以及夹具 /var 与 /private/var 别名未命中，均已修复 |
| 最终 build | 0 | `build.log`、`build.exit`：64.13 秒 |
| 最终 test | 1 | `tests.log`、`tests.exit`：794 个；仅上述沙箱／显示失败 |
| display_bound_tests.py --check | 0 | `display-bound.log`：63 in-process、1 out-of-process、1 exempt |
| check_deletion_process_inventory.py | 0 | `deletion-inventory.log`：181 entries、273 uses |
| scoped git diff --check／新增行空白检查 | 0 | `diff-check.log`、`scope-review.txt` |
| 本地 Foundation 路径探针 | 0 | `path-probe.swift`／`path-probe.log`，仅自建并回收临时目录，证明枚举 URL 与解析 URL 的别名不同 |

以上日志均在 `.build/d192-evidence/`。依赖从本机现成 v2.0.1/debug 的 Sparkle **2.10.0** checkout、repository 和 artifact 复制进本轮 scratch，没有请求外网或改依赖版本。

**沙箱限制**：虽然所有构建／测试命令都按要求包含 `nice -n 15`，内核拒绝 `setpriority`（日志首行 `Operation not permitted`，探针读回继承 nice 为 0），因此没有成功降低 nice；`--jobs 4` 已按要求传入。不能宣称以实际 nice 15 完成。SwiftPM 用户缓存不可写也已如实保留。家目录夹具、本地 socket 和窗口测试需主会话在其已授权环境补跑；没有申请或尝试提权，也没有把类移出显示清单。

关键来源位置：CloudDriveScanner.swift:83（本地元数据）、:100（预取键）、:180（分类）；DiskScanner.swift:1369（whereNeeded）、:1405（占位）、:1540（本机 0 字节）；AppUpdatePresentationModels.swift:145／:592／:627（统一谓词和手动公式）；ApplicationUpdatePlanBuilder.swift:109（批次门槛）；ApplicationsScanCoordinator.swift:17（顺序）；StorageMapModels.swift:423（isCloudOnly 下游含义）。源码路径前缀同前表。


## 主会话装 Beta 后实测

1. 同一批 iCloud／Google Drive／OneDrive 数据各扫一次，记录总时长、inspectedCount、云端项与本机项数量／大小；比较原 35 分钟，并观察 bird/fileproviderd 是否仍持续高 CPU。扫描前后不要主动下载，核对云端占位保持未下载。
2. 空间地图分别从 iCloud 云盘、OneDrive 与卷根扫描，记录时长、项目数、measuredBytes；验证占位目录不进入、已下载但非最新文件计本机占用；检查 /.nofollow、/.resolve、/.vol 不重复计数，透镜和方块图的下钻与总量一致。
3. 在线从应用首页按“扫描”，确认只读检查自动开始、结果先出现占位磁贴，再替换为更新数；无安装或恢复旧队列。断网重新扫描应没有更新磁贴；之后手动查更新的新结果应可显示。
4. 同一次检查对照应用页磁贴、更新页标题、Smart Care 卡片、经典应用页，均为确认数；全部更新批次不大于该数，逐个批次 ID 均在确认集合。查看手动处理中的 openssl@3 原因和终端说明；自更新 cask 不显示重装／降级为新版本。
5. 保存此次全部应用与 confirmed/batch/Lightfield 三个 ID 集合的夹具，核对先前四项的实际名称和差集；在获准环境补跑 ApplicationsScanD192Tests、家目录／套接字受限测试，并在专用副屏补跑 18 个窗口测试。
