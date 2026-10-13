# r2-icloud-reads：N6 内容读取保护交接

## 状态与范围

- 实现工作区：`/Users/developer/Developer/sc-worktrees/r2-icloud-reads`；分支 `task/r2-icloud-reads`。
- 基线：`9e53489e06f6a4e08540a9e0538bb9139cc338e7`。开始时工作区干净。
- 首轮准备记录：代码、测试、静态审计、分组补丁 **已准备**。当时本会话的构建、严格并发编译、XCTest、反证、提交、合并、安装均 **NOT RUN**，实际运行测试数 **0**。主会话随后已提交 5 组，沙箱外编译反馈及本次修正见末尾“fix1”。
- `Sources/StorageCleanerMac/Stores/ScanStore.swift` **未修改**，无需主会话代改该文件。
- 已读 RULES、BOARD 的 N1/N6、2c 交接，以及 D5、D46、D48、D49、D51、D52、D54、D55、D60。本批不改变清理选择规则、保护目录或应用仅复制的语义。
- JEV **BLOCKED**：工具存在，`jev_decide` 没有可选模型参数；一次方案判断调用返回 `MCP tool call requires approval, but approval policy is never`。未获得模型判断，不将其记为复核通过。主会话仍需派不同模型复核。

## 改动与理由

1. **共享 2c 的保护实现**：把 `lstat/SF_DATALESS` 和同线程 `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = OFF` 原实现迁入 `FileContentReadGuard`；扫描器的旧静态函数仅转调它，2c 测试入口保留。N6 新读取器无法设置该策略时拒绝读取。查询下载状态沿用 `DiskScanner.storageMapNeedsCloudState` 的 D51④ 判定；普通本地文件不询问 File Provider。没有下载、驱逐、协调写入或修改源文件的接口。
2. **有界只读工作池**：`FileContentReadPool` 同时最多 4 个读取工作，取消约每 10 ms 检查一次，等待使用单调时钟。每次文件打开／数据块读取默认 15 s，预览解码 5 s；重复扫描还受其已有剩余时间预算约束。池满直接拒绝，不堆积无限线程。大文件的哈希按块限时，不给整份文件强加 15 s 完成上限。
3. **文件身份与打开方式**：`GuardedFileContentReader` 在实际工作线程禁止物化，再做云状态检查；逐级 `openat/O_NOFOLLOW`，校验普通文件及 `fstat` 的 dataless 标志。读取前后核对身份、大小、mtime、ctime，迟到结果不能被采用。只接受系统实际指向 `/private/var`、`/private/tmp` 的两个固定别名，其他父级符号链接仍拒绝。
4. **重复扫描**：快速指纹、SHA-256、相似图片签名接入有界读取。仍使用 `DuplicateFileScanControl`、原暂停逻辑和总时间预算；哈希按块更新原进度；超时／工作池满沿用扫描的时间限制结果。
5. **相似图片预览**：保留原 512 MiB 文件上限和 320 像素缩略图上限。`AppIconCache.LoadedImage` 增加失败原因；卡片展示中英文原因；全部订阅取消时把取消传给实际加载器，未完成的读取不会填入缓存。每个缓存使用自己的加载队列，避免其他应用图标的阻塞拖住相似图片预览。原图标加载器 API 仍可用，原成功／空图缓存行为保留；带失败原因的结果不长期缓存。
6. **清理前复核**：生产哈希读取器接入共享实现；重复文件复核的元数据读取也放入有界只读池。保留原三次身份／内容检查和持久化意图后的最终复查。云端、下载中、超时和取消不再经 `try?` 误报为“内容已变化”，新增可持久化的跳过原因。早期复核收到取消时仍返回原执行器的 cancelled 结果并释放租约，不调用 mover。
7. **搬家复制与复核**：来源预检、哈希和应用包签名读取接入保护；验签前先检查整个包的云状态，不进入占位目录。替换不可取消的整项 `copyItem`：读线程只接收源文件，调用者逐块写自己拥有的暂存目录。保留权限、日期、扩展属性、资源叉和 ACL；链接复制为链接，不读取其目标。每次写入前检查取消；任何失败先走现有暂存清理和统一回执。副本发布前重新核对来源，成功发布为完成点；完成之后的取消不能把已写成的副本报告为未完成。
8. **处理搬家原件**：继续要求用户另行确认、持久化回执成功、文件身份一致。`RecordedTrashOperation.validate` 在持久化意图前后都重新验证两份文件内容，防止回执写入期间副本变化。应用仍仅复制，绝不自动移原件。界面新增取消按钮，外层取消通过 `withTaskCancellationHandler` 传到 detached worker。
9. **删除旧入口**：全仓检索确认 `ScanHeavyWorkService.scanDuplicates` 无调用方，`Operations.duplicateScan` 只有它使用。删除属性、默认闭包、赋值和包装方法。`HeavyWorkIntegrationTests` 仅去掉未使用的 `duplicateScan:` 注入参数；它实际通过 `duplicateFilesScanOperation` 覆盖有效入口，所有断言及测试保留。没有仅为旧入口存在、需要整项删除的测试。

## 读取内容路径 × 保护状态（改前／改后）

下表覆盖运行时代码的直接文件内容 API，以及 Bundle／代码签名／Quick Look 等间接读取。`目录列举、stat、readlink` 是元数据，不计成内容；输入流内存数据、进程管道另列。全仓搜索包含 `Sources`、`Tests`、脚本；测试和脚本的夹具／源码／构建产物读取不作为产品扫描入口。行级清单见同目录 `r2-icloud-reads-content-audit.csv`。没有发现 `AVAsset`、`AVURLAsset`、`QLThumbnailGenerator` 的直接调用；SwiftUI Quick Look 的调用列在下表。

“无”指该具体内容读取点没有 dataless 检查，**不等于所在功能没有其他安全检查**。“循环取消”或“外层超时”不能中断一个已经卡住的同步系统调用。未改行是盘点结论，不是本批已修复的声明。

| 功能／读取位置 | 云盘／网络卷可达性 | 改前 dataless；取消／超时 | 改后 |
|---|---|---|---|
| `DuplicateFileScanner` 快速指纹、SHA-256、ImageIO 相似签名 | 所选位置、用户数据、可选卷，可达 | 2c 标志＋线程 OFF；文件／块间取消，总预算不能打断 syscall | 复用共享标志＋OFF＋下载状态；有界读池；扫描 control／总预算，单次最多 15 s |
| 同扫描器 AppleArchive 的 CLC/HLC/PAT/TYP 探测 | 同上 | 线程 OFF；只选元数据字段，`writeBlob` 空实现 | 不改；不请求 DATA 字段；元数据阻塞仍是另外的风险 |
| `SimilarImagePreviewCache` ImageIO 预览 | 结果项可达两者 | 无；只取消订阅；无解码超时，共用串行队列 | 每次打开／解码前保护，5 s，取消传递，原因可见，队列隔离 |
| `FoundationCleanupContentDigestReader`、`SafeCleanupExecutor` 选中项及保留副本哈希 | 用户目录和其挂载点可达 | 外层 snapshot 有云状态，但实际 open/read 无 2c 防线；哈希无取消／超时 | 每块保护、15 s；取消／超时拒绝移动；原写前复查保留 |
| `ExternalDriveMigrationService` 原件复制、两份哈希、复核后移原件 | 源可达；生产目标仅本地可写物理外接卷，网络目标已被 `availableVolumes` 排除 | 无；copyItem 后才查取消，哈希不查；无 syscall 超时 | 逐块有界读取，写方不被放弃；暂存清理；双文件保护；取消可从界面触达 |
| 搬家应用 Bundle／`CodeSignatureVerifier` | 源包可达两者 | 无；同步验签可能读包内文件，无超时 | 包树先查云状态，实际验签线程 OFF，15 s；仍仅复制 |
| `GuardedFileCopy` xattr／资源叉／ACL | 同搬家源 | 原先隐含于 copyItem | 元数据和资源叉读取均在有界 OFF 线程；资源叉按块读取，写方取消检查 |
| `AppIconCache` Bundle 图标、图像属性；`AppArtwork` ImageIO | 应用可在外接卷／用户位置；素材通常本地 | 无统一 dataless；图标订阅可取消，解码无时间界限 | 通用图标内容策略未改；加载队列与相似预览隔离 |
| `GoldenLandingArtwork` ImageIO | 随应用分发资源；调试源码资源可能在自选工作区 | 无；同步、无取消／超时 | 不改 |
| `SystemUtilitiesView` 两处、`StorageTreemapView` Quick Look | 用户选择的结果文件，可达两者 | 系统预览；用户明确点击，不是扫描；本应用无预览 syscall 超时 | 不改系统预览语义；相似缩略图拒绝原因可见 |
| `AppUninstallService` Info.plist、本地化 strings、Bundle；`AppUpdateService` Info.plist | 应用扫描根可达外接／用户位置 | 无统一 dataless；这些 Data/NSDictionary 读点无内部取消／超时 | 不改，列为后续风险 |
| `UninstallOwnershipVerifier` plist 归属数据 | 用户应用数据；迁移过的 home／卷可达 | 有大小／常规文件约束，非 dataless；测量有 3 s 预算，Data 读取无 syscall 超时 | 不改 |
| `AuthorizedApplicationMover`、`UninstallExecution` Info.plist 与签名身份 | 显式卸载的应用包／废纸篓 | 无统一 dataless；写操作另有身份、授权、回执保护，读点无超时 | 不改；不可把丢弃读结果用于放弃已开始的移动 |
| `CleanupApplicationRelease.read`（`ReadOnlyCleanupScanner`）Info.plist／Bundle | 开发工具／重复应用规则命中位置，可达外接路径 | 无 dataless；4 MiB 是读取后的限制，非取消／时间限制 | 不改，列为后续风险 |
| `AppInstallationConflictService`、`AppRuntimeLocationService` Info.plist | 本应用及候选副本；一般本地，候选可在外接卷 | 无 dataless；同步内容读无超时 | 不改 |
| 启动项 `LaunchdPlistScanner`、`EmbeddedServiceScanner`、`UserLaunchAgentManager` | 用户／系统 LaunchAgents 与应用包；前者受路径限制，包可能外置 | 路径、symlink、大小等防护，非 dataless；命令阶段超时不覆盖 Data 读取 | 不改 |
| `StartupUndoStore` 恢复记录 | 应用自己的本地数据；home 外置是间接风险 | 无 dataless／内容超时 | 不改 |
| 更新 `ApplicationMetadataReader` Info.plist、Mach-O 前缀 | 被扫描应用，可达外接／用户位置 | 无 dataless；Mach-O 最多 4096 B，但 syscall 无超时 | 不改，列为后续风险 |
| 更新 `VendorUpdaterProvider`、`MacAppStoreProvider` Info.plist、收据 | 被扫描应用，同上 | 无 dataless；Data 读点无超时 | 不改 |
| 更新 `BundleIdentityVerifier`、`UpdateSecurityMachOArchitectureReader`、`CodeSignatureVerifier` | 安装候选／被扫描包 | 有签名、范围等安全校验，非 dataless；直接读无独立超时 | 通用实现不改；仅搬家调用侧增加保护 |
| `OfficialApplicationUpdateInstaller` 包哈希、DMG 尾、XML/plist、copyItem；`SecureZipArchiveExtractor` ZIP 与哈希 | 本应用下载暂存、已解压候选、选中应用 | 包哈希／解压有循环取消，命令有 30/120 s，文件 syscall 未单独限时；无 dataless | 不改；下载器网络超时不等于磁盘读超时 |
| `ApplicationUpdateQueueRepository`、`WebsiteUpdateQueue` | 应用本地队列 | 无 dataless／内容超时 | 不改 |
| `OfficialSourceRegistry`、`RemoteOfficialSourceRegistry` | 分发规则、本地最后成功缓存；显式远程下载另属 URLSession | 无 dataless／本地 Data 读取超时 | 不改 |
| 浏览器 `BrowserPrivacyProviderRegistry` JSON/plist、SQLite 文件头 | 受允许根限制的浏览器资料；网络 home 间接可达 | NOFOLLOW／字节上限等，不是 dataless；同步读取无 syscall 超时 | 不改 |
| `SQLiteSnapshotService` fd 复制、sqlite3_open_v2／查询／备份 | 浏览器资料及受控快照 | 存在 deadline、取消／SQLite interrupt、路径身份校验；不是统一 dataless；底层阻塞 read 不保证中断 | 不改 |
| `BrowserPrivacyRecoveryBackupService` 备份元数据、`BrowserPrivacyHistoryProcessor` marker | 本应用本地恢复目录 | 有字节／路径／身份约束；没有统一 dataless 或该内容读的超时 | 不改 |
| `CleanupReportJournal`、`CleanupReportIndex`、`CleanupJournalEvents` JSON／事件哈希 | 本应用本地日志；网络 home 间接可达 | 有回执完整性／字节与帧校验；无统一 dataless／内容超时 | 不改，必须保持持久化和真实写入结果的顺序 |
| `DuplicateFileResumeIndexStore`、`DuplicateFileResultStore` | 应用本地续扫／结果缓存 | 有大小等校验；无 dataless／内容超时 | 不改 |
| `BoundedMonitoringFile`、`MetricHistoryJournal` 读／保留副本 | 应用本地监控历史 | NOFOLLOW、普通文件、字节／变化校验；无 dataless／时间限界；journal copyItem 无取消 | 不改 |
| `CapacityHistoryService`、`ComputerHealthHistoryRepository`、`NetworkSpeedTestResultRepository` | 应用本地历史 | 部分有字节／fd 防护，无统一 dataless／内容超时 | 不改 |
| `BenchmarkV7HistoryRepository`、`MacBenchmarkHistoryRepository`、`MacAcceleratorBenchmarkHistoryRepository` | 本地跑分历史 | 部分 NOFOLLOW／字节上限；无统一 dataless／内容超时 | 不改 |
| `DiskBenchmarkKernel`、`StorageRandomAccessBenchmarkV7`、`MSeriesStorageKernel` | 显式性能测试创建的自有临时数据，非扫描用户内容 | 自建文件不应为云占位；有循环取消／跑分预算，read/pread 本身不可中断 | 不改 |
| `StabilityReportService` 崩溃报告前缀 | 固定日志根，网络 home 间接可达 | 无 dataless；单份 64 KiB／总 8 MiB；外层 2 s 等待＋单个在途工作防堆积 | 不改，超时丢弃迟到结果已有 |
| `LegacyFanControlHelperInstaller` 安装 plist | 固定系统位置 | 无 dataless；同步内容读无超时 | 不改；本批不触发硬件写入 |
| `CleanupRuleSetLoader` JSON、规则／基线资源读取 | 应用资源、开发时源码回退 | 无 dataless／内容超时；生产分发资源通常本地 | 不改 |
| `Shell`、`EnergyImpactService` stdout/stderr 临时文件 | 自建本地临时输出 | 子进程有取消／超时；Data 读取输出无独立磁盘超时 | 不改 |
| `NetworkSpeedTestService`、FanControlHelper 进程管道；`FileOperationHelper` 请求 fd | 管道／IPC，不是云文件路径；helper 请求有字节上限 | 各自进程生命周期控制；不适用 dataless | 不改 |
| `NetworkCompatibilitySpeedTestService.InputStream(data:)`、内存 SHA-256 | 内存 | 不打开文件，不适用 | 不改 |
| Tests／Debug 夹具、script 构建／归档／检查工具 | 隔离夹具／源码／产物，非自动产品扫描 | 按各工具生命周期；不宣称有统一 dataless | 本批未运行；新测试不创建真实云盘／Provider 夹具 |

## 定向测试、红／绿／反证

**全部 NOT RUN**。下列“绿”均为主会话待执行的验收动作，不是本会话结果；不放宽 1 s 等返回预算，繁忙机器请空闲时重跑。

| 定向类／项目 | 红：应抓住的旧行为 | 绿：本次新增／保留断言 | 反证（在主会话隔离副本上改一处后跑对应测试） |
|---|---|---|---|
| `FileContentReadGuardTests` 云端／下载中 | 2c 以外无 guard，底层内容探针会被调用 | 预览和生产清理哈希读取次数 0，错误及可见文案准确；普通本地 digest 相同且 Provider 调用 0 | 把 `check` 的 placeholder／downloading 分支分别移除，应失败；把 needsCloudState 恒 true，本地 Provider 计数失败 |
| 同类线程策略 | 默认 ON 线程会物化占位 | 实际读线程为 OFF；抛错后恢复调用线程原 ON | 把 OFF 设置去掉，应失败；不要改真实文件标志 |
| 同类 timeout／cancel／池容量 | 卡住的 read 导致调用方一直等待、无法恢复 | 替身 semaphore 尚未返回时，哈希取消／超时已返回；上限 1 的池拒绝第二个读 | 去掉等待循环的取消或 deadline 分支；主会话用外层进程超时控制反证，不允许无限挂起 |
| 同类预览队列 | 取消只解除订阅，串行 decoder 仍阻塞下一张 | 第一张读替身尚未返回，第二个缓存请求已完成；超时有原因 | 不把订阅取消传给 loader，应卡到 gate 3 s 并违反 1 s 断言 |
| `GuardedMigrationReadTests` | copyItem／哈希先读云文件；整项复制不可中断 | 云端／下载中 migrate 与 hash 不读内容；保留副本云端时不读两边、不移原件 | 绕过 `checkAvailability` 与 reader guard 后，读取计数或期望错误失败 |
| 同类暂存生命周期 | 后台 copyItem 超时后仍可写、可发布 | 取消／超时在 read 仍阻塞时返回；无 `.partial` 和最终副本；放行迟到 read 后仍无输出；源字节不变 | 在写方忽略读取错误或取消并发布暂存，应失败；禁止用真实外接盘做反证 |
| 同类应用包、元数据与大文件 | 内部占位被递归读；改写复制器容易损坏辅助数据 | 云端子项不读；验签预检拒绝它；2.1 MB 文件、权限、符号链接、xattr 和跨块资源叉逐字节相同 | 去掉包树 guard、metadata 拷贝或资源叉第二块，应分别失败 |
| 同类写前复查 | 回执持久化期间副本被同大小内容替换，原件仍可能移动 | persist 替身改副本后拒绝移动，原件保持 | 删除 `RecordedTrashOperation.validate` 中的最终内容比较，应失败 |
| `CleanupExecutionSafetyTests` 两个 `testN6…` 方法 | 哈希错误被吞成 contentChanged，最终复查可能未保留原因 | source／retained × cloud／downloading／timeout／busy × 预检／第三次最终复查；mover 调用 0，原因准确；另断言阻塞哈希取消后原件不移动、租约释放、outcome 为 cancelled | 恢复 `try? digest` 或跳过第三次内容复查，应失败 |
| `DuplicateContentReadTests`、`DuplicateFileScannerTests`、`DuplicateSelectedLocationsTests` | 2c dataless、续扫覆盖与暂停／取消回归；网络读取卡住 | 新替身分别卡在快速指纹、SHA-256、相似图片签名前，断言超时为部分完成、control 取消及时返回；保留旧 2c 所有断言 | 将扫描器 reader 还原为直接无界 FileHandle 或删掉相似签名的超时标志，应违反 1 s 或 partial 断言；测试只卡 semaphore，不用真实网络卷 |
| `SimilarImagePreviewCacheTests`、`AppIconCacheTests` | 解码、no-follow、共享请求与缓存语义回归 | 原测试不改；新失败结果不永久缓存、取消传播由新类覆盖 | 移除逐级 no-follow，原父级 symlink 断言应失败 |
| `ExternalMigrationReceiptTests`、`SystemUtilitySafetyTests` | 迁移回执、原件恢复、同大小内容差异或保护范围回归 | 原断言全留；唯一 production move 调用不注入测试 journal | 停用持久化意图／内容比较，已有相关断言应失败 |
| `HeavyWorkIntegrationTests`、`TestPreferenceHygieneTests` | 删除旧入口误删活入口测试；写真实偏好域 | 仍覆盖独立 duplicate owner；新测试不直接创建 UserDefaults 或写 standard 持久域 | 重复扫描活入口的租约去掉，原 owner 断言失败；将新测试改成普通 suiteName，卫生守卫失败 |

新增测试不设置真实 SF_DATALESS、不调用 iCloud 下载，也不在真实 `Library/Mobile Documents`、`Library/CloudStorage` 或 File Provider 根中建夹具。通用夹具在系统临时目录；完整搬家测试因生产来源策略必须位于 home，沿用现有迁移测试的 `~/.storage-cleaner-content-tests-<UUID>` 独立目录，测试结束删自己创建的目录，不使用 Library/Caches／Preferences／Application Support。语言测试仅用既有 `TestVolatilePreferences` 内存作用域。

### 主会话命令

在沙箱外、当前工作区运行，保持本批 scratch；依赖按 RULES 使用已保留的离线源，不要创建新的共享构建目录。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'DuplicateContentReadTests|FileContentReadGuardTests|GuardedMigrationReadTests|CleanupExecutionSafetyTests|SimilarImagePreviewCacheTests|AppIconCacheTests|DuplicateFileScannerTests|DuplicateSelectedLocationsTests|ExternalMigrationReceiptTests|SystemUtilitySafetyTests|HeavyWorkIntegrationTests|TestPreferenceHygieneTests'
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/strict --jobs 4 -Xswiftc -strict-concurrency=complete
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-icloud-reads/verify script/verify.sh
git diff --check
```

完整 Debug／Release 和源码守卫由主会话按 RULES 门禁执行。反证用独立临时副本，每项只撤掉对应防线，保存红灯输出，再用最终版跑绿；不得把反证改动写回 prepared 文件。用完清理临时构建产物，保留日志。

## 用户可见文案（中英文）

| 中文 | English | 位置 |
|---|---|---|
| 仅在云端，未读取内容；请先在访达中下载，或跳过此项。 | Only in the cloud; content was not read. Download it in Finder first, or skip this item. | 共享云端拒绝；预览、清理、搬家 |
| 正在下载，未读取内容；请等待下载完成后重试，或跳过此项。 | Downloading; content was not read. Wait for the download to finish and retry, or skip this item. | 同上 |
| 读取文件超时，已停止等待；请检查磁盘或网络连接后重试。 | Reading the file timed out and waiting stopped. Check the disk or network connection and retry. | 超时 |
| 仍有文件读取未响应，已跳过；请检查磁盘或网络连接后重试。 | Some file reads are still unresponsive; this item was skipped. Check the disk or network connection and retry. | 工作池满 |
| 无法确认读取不会触发云端下载，已跳过此项。 | A read without triggering a cloud download could not be assured; this item was skipped. | 线程策略设置失败 |
| 文件在读取期间已变化，请重新扫描。 | The file changed while being read. Scan again. | 读取身份／大小变化 |
| 无法读取预览，请在访达中检查文件。 | The preview could not be read. Check the file in Finder. | 其他预览读取错误 |
| 无法安全读取文件，已跳过；请稍后重试。 | The file could not be read safely and was skipped. Try again later. | 清理的不可读取原因 |
| 已取消读取，未处理原件。 | Reading was cancelled; the original was not handled. | 清理跳过原因 |
| 取消 | Cancel | 搬家进行中按钮，复用现有用词 |
| 已取消，原件保留；未完成的副本已停止复制。 | Cancelled. The original was kept and the unfinished copy stopped. | 搬家取消反馈 |

重复扫描的“仅在云端，未下载、未比对”和时间限制文案继续复用 2c 现有内容。未增加“已结束内核读取”之类无法证明的文案。

## 旧断言、兼容性与未解决边界

- **没有删除、放宽或改写旧断言**；仅移除上述无效依赖注入参数。新增 `CleanSkipReason` 原始值用于本批新日志，新版本仍能读旧日志；旧版本遇到新原因可能不能解码，和 2c 的新增原因一样，不宣称向旧版本兼容。
- 系统若永久卡住一个同步 `read/open/metadata/ImageIO`，Swift 不能安全强杀该线程。本实现保证等待方取消／超时返回、最多四个滞留读取、迟到结果不用、读取者无写权限；不声称内核线程已结束。四个槽都卡住后新读取明确拒绝，需卷恢复或重启应用。
- 目标写入、rename、Trash、持久化回执均是显式操作，**没有**通过“超时放弃后台写入”处理。生产迁移目标已有本地物理卷限制。目标被拔掉或系统拒绝清理时，现有 `TemporaryResourceReceipt` 仍记录暂存清理待核实；不能保证不可用卷上的物理目录当场消失。可用隔离卷上的取消无半成品由新增测试验证，真实卷失联需主会话确认回执展示。
- 元数据读取全应用并未统一有界化；重复扫描发现／AppleArchive 元数据、其他功能的路径解析仍可能受异常文件系统影响。表中应用扫描、更新、启动项等读取器也未全部迁入本服务，不能据本批宣布“全应用所有读取都有下载／网络超时保护”。这些是明确后续范围。
- 自定义复制器的普通扩展属性总量上限 64 MiB、属性名列表上限 1 MiB、递归深度 128；资源叉另行分块，不占该 64 MiB；其 `getxattr/setxattr` 位置参数为 UInt32，超出可表示范围拒绝复制，保留原件。所有辅助数据写入失败都拒绝发布，不能静默漏掉资源叉／ACL。需要主会话重点跑 APFS 夹具，并评估非 APFS 外接卷的扩展属性行为是否与现有产品预期一致。
- `AppIconCache` 的通用应用图标仍可能阻塞其自己的队列；本批只隔离它对相似预览的影响。Quick Look 为用户明确动作，不代表后台扫描获准下载。
- 资源叉的定位读写按 Apple 的 `getxattr(2)`／`fsetxattr(2)` 接口说明实现；官方说明将 position 定义用于资源叉。参考：[getxattr](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getxattr.2.html)、[fsetxattr](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsetxattr.2.html)。此为接口依据，**不是实机通过证据**。

## 分组补丁与实际静态检查

`/Users/developer/Developer/.sc-build/r2-icloud-reads/prepared/`：

1. `01-read-guard`：共享 guard、有界池、内容读取器和流式复制器。
2. `02-reader-integration`：重复扫描、清理复核、缩略图缓存与原因展示。
3. `03-migration`：搬家复制／哈希／写前复查、取消按钮与任务取消链。
4. `04-tests-and-legacy`：新测试、旧入口移除和原集成测试的无效参数删除。
5. `05-handoff`：本交接与逐读取点审计 CSV。

另含 `all.patch`、`manifest.json`、`commit-prepared.py`、`static-checks.json`、生成脚本和 README。manifest 记录完整基线、分支、组顺序、每个最终文件 SHA-256 和补丁产物 SHA-256；提交脚本在基线、分支、暂存区、文件或产物校验不符时拒绝执行。**脚本尚未运行，不等于已提交。**

实际只执行了只读 git 状态／diff、rg／源码读取、补丁生成及静态完整性检查；各命令和退出状态见 `prepared/static-checks.json`。主会话编译或复核发现问题请回交同一会话修正，并重新生成全部 prepared 哈希。

## fix1：Swift 6 的 FileManager 捕获修正

### 编译反馈与改动

- 修正基线：`c729a184950b7477d2d618f484d3614df1f6627d`，分支仍为 `task/r2-icloud-reads`；开始时工作区干净。前述 5 组已由主会话提交，本轮不提交。
- **FAIL（主会话反馈）**：沙箱外 Swift 6 编译唯一错误为 `ExternalDriveMigrationService.swift:628:19` 的 `capture of 'fileManager' with non-Sendable type 'FileManager' in a '@Sendable' closure`。本会话没有重跑该编译，也没有原始编译日志。
- **已修正**：`inspectSource` 在读取池的 `@Sendable` 闭包内取得 `FileManager.default`；移除该私有方法的 `fileManager` 参数，同步更新复制和原件处理两处调用。跨线程仍只捕获 `ExternalMigrationItem`、`GuardedFileContentReader` 等 `Sendable` 值，返回已声明 `Sendable` 的身份和来源快照。
- 公开的迁移 API 仍保留调用方 `fileManager` 参数，用于调用线程上的目标检查、暂存及实际文件操作；只读预检不再传递这个非 `Sendable` 实例。云状态检查、超时、取消、回执及写前复查顺序保持原样。
- 没有新增 `nonisolated(unsafe)`、`@unchecked Sendable`、`@preconcurrency` 或关闭严格并发的选项；没有修改测试、旧断言、用户文案、`ScanStore.swift`。本轮实际改动为一个源码文件和本交接。

### 本批全部文件的并发复查

按首轮 manifest 的 20 个文件逐项重新检查改动和相关调用链；检查 `@Sendable`／GCD／Task 捕获、跨隔离返回值、`@MainActor` 调用，以及现有同步封装的所有权。下表为人工源码复查结论，**不能代替 Swift 6 编译和测试通过证据**。

| 文件（相对源码或测试根） | 复查结果 |
|---|---|
| `Services/FileContentReadGuard.swift` | guard 保存的闭包为 `@Sendable`；读取池工作闭包捕获控制器、完成盒、信号量及操作闭包；可变取消／结果状态已有锁保护。策略设置和恢复在同一同步线程。 |
| `Services/GuardedFileContentReader.swift` | reader 为 `Sendable` 值；取消查询留在调用方；`FileHandle` 由 `OpenFile` 持有并按现有调用链串行读取，超时后迟到工作保留所有权，调用方不从另一线程关闭。 |
| `Services/GuardedFileCopy.swift` | 读取闭包只捕获 reader、来源 URL 和不可变偏移／块大小；`FileManager.default` 在使用处取得；目标写入和输出句柄留在调用线程。 |
| `Services/DuplicateFileScanner.swift` | 指纹／签名结果及 candidate 均为 `Sendable`；可变时间预算和进度留在扫描线程，没有被内容读取闭包捕获；读句柄仅作为工作闭包参数使用。 |
| `Services/SafeCleanupExecutor.swift` | actor 先把遵守 `ReadOnlyFileSystem: Sendable` 的依赖赋给局部常量，再传入读取闭包；没有捕获 actor 的隔离可变状态。 |
| `Models/CleanupExecutionModels.swift` | 新增项仅为已有 `Sendable` 枚举的无关联值 case，无新隔离边界。 |
| `Support/AppIconCache.swift` | 缓存／请求表继续受内部 actor 隔离；加载器声明 `@Sendable`，取消控制器有锁；原有 `LoadedImage` 按不可变显示值传递，没有为本次 FileManager 修正扩张其豁免。 |
| `Support/SimilarImagePreviewCache.swift` | ImageIO／NSImage 在实际解码闭包内创建，通过既有 `LoadedImage` 返回；没有从界面捕获图像对象到读线程。 |
| `Views/CleanupExecutionViews.swift` | 新增原因展示为同步纯映射；没有新增主 actor 调用或跨隔离对象。 |
| `Views/SystemUtilitiesView.swift` | 预览结果 await 后在 View 的任务中写入 `@State`；读线程不访问 store／View 状态。 |
| `Services/ExternalDriveMigrationService.swift` | 修复本次报错；同时检查其余三处读取池闭包：元数据依赖、签名输入、来源身份／日期均可发送；Bundle 和资源值在工作闭包内创建。回执 validate／move／persist 为同一调用线程的同步闭包，不跨入读取池。 |
| `Views/LargeFilesView.swift` | 两个 detached 任务只捕获 `Sendable` 的 item、volume 或 pending 值；取消闭包只捕获 Task 句柄；store／workspace／`@State` 更新留在外层继承主 actor 的任务。 |
| `Services/ScanHeavyWorkService.swift` | 删除旧路径未新增异步边界；存续 Operations 闭包及一次更新入口的 `@MainActor @Sendable` 约束保留。 |
| `HeavyWorkIntegrationTests.swift` | 本批只移除无调用方的注入参数；actor 替身和已有主 actor 测试隔离不变。 |
| `CleanupExecutionSafetyTests.swift` | 新任务捕获执行器 actor 和可发送的计划／上下文；拒绝计数替身有锁，阻塞替身使用同一有锁 gate；未捕获 XCTestCase 到读闭包。 |
| `FileContentReadGuardTests.swift` | 读取替身捕获 Sendable reader／夹具和同步 probe／gate；本地 FileManager 在创建夹具的方法内使用，不被后台任务捕获。 |
| `GuardedMigrationReadTests.swift` | 后台任务捕获 Sendable 夹具／reader；元数据数组和文件句柄不跨隔离；同步回执替身没有被标成后台闭包。 |
| `DuplicateContentReadTests.swift` | 捕获 Sendable 配置、reader、夹具、循环常量及有锁扫描控制器；进度闭包不捕获 XCTestCase 或可变局部值。 |
| `handoffs/r2-icloud-reads.md` | 补充本次编译反馈、复查及验证边界；首轮未运行状态与本轮状态区分记录。 |
| `handoffs/r2-icloud-reads-content-audit.csv` | 258 条记录继续作为首轮读取盘点快照，未重写；fix1 未增删任何内容读取入口，行号仍指首轮版本。 |

除已修复的捕获之外，暂未发现本批另有同类并发问题。现有有锁控制器、完成盒和句柄／显示值封装保持原有实现；没有用新增豁免压过本次编译错误。

### 验证与交付

- **PASS（静态）**：工作区差异、各组和合并补丁的反向 `git apply --check`、最终文件与补丁 SHA-256、`ScanStore.swift` 与基线字节一致。具体命令、exit code 和核对项写入 `prepared-fix1/static-checks.json`。
- **NOT RUN（本会话）**：构建、严格并发编译、XCTest、运行时反证、提交、合并、安装；执行测试数 0。没有新增或改写测试断言，原定向测试列表继续适用。
- JEV 本轮可调用，`jev_review` 返回模型 `jev-latest`，`action=escalate`、`safe_to_apply=0.24`，未达到自动接受门槛；返回评分但没有文字原因。原始结果保存在 `prepared-fix1/jev-review.json`。不将此记为复核通过，不重复请求以改变评分，主会话仍需编译及独立复核。
- **红**：保留主会话提供的 `c729a18` 编译诊断。**绿（待跑）**：按上文命令重新 `swift build`，再跑 `GuardedMigrationReadTests|ExternalMigrationReceiptTests|SystemUtilitySafetyTests`；`swift test` 也会编译测试目标，可检查新增测试中的严格并发问题。随后完成上文原定向列表与门禁。Swift 6 已默认严格并发，无需改包配置。
- **反证（待跑）**：仅在主会话隔离副本恢复 fix1 源码补丁中的私有 FileManager 参数、两处传参并删除闭包内局部声明，再以同一 Swift 6 配置编译，应重新出现 `SendableClosureCaptures`；恢复补丁后重编译。不得关闭并发检查来取得绿灯。
- 新产物目录 `/Users/developer/Developer/.sc-build/r2-icloud-reads/prepared-fix1/`：`01-migration-sendable.patch`、`02-fix1-handoff.patch` 及各自提交说明，另有 `all.patch`、`manifest.json`、`commit-prepared.py`、`static-checks.json` 和 JEV 结果。基线为 `c729a18`，manifest 记录组顺序、最终文件及产物 SHA-256。提交说明使用用户要求的 `Codex (gpt-6-astra)` 与 Claude Opus 5.5 尾行。
- 原 `prepared/` 保留为前 5 个提交的历史产物，不对已提交的旧补丁重算。本轮提交脚本仅供主会话完成验证后按两组提交，尚未执行；当前源码修正仍留在工作区。

剩余待验收事项仍为首轮所列边界，以及主会话确认本次 Swift 6 重编译／测试结果；本轮没有新的产品行为取舍或 `ScanStore.swift` 协调请求。

## fix2：系统临时目录别名导致普通文件打不开

### 证据与原因

- 基线 `33bf7b0d1bd7f1a825f79f11a2f4f0b20cf23c04`，分支 `task/r2-icloud-reads`；开始时工作区干净。主会话已提交 fix1，并反馈 **Swift 6 编译 PASS**。
- **FAIL（主会话日志）**：已读取 `~/Developer/.sc-build/r2-icloud-reads/logs/failures-1.txt` 和 `logs/main-test-2.log`。后者记录 `AppIconCacheTests` 17/0、`CleanupExecutionSafetyTests` 31/0；`DuplicateContentReadTests` 两个方法有 7 处失败。随后旧扫描器测试出现重复组为空、哈希字节为 0，续扫测试访问空数组后以 signal 5 终止。未跑到的后续类不能算通过。
- **已确认的源码缺陷**：`GuardedFileContentReader.systemAliasPath` 只把链接目标字符串等于 `/private/var` 或 `/private/tmp` 的系统别名转成物理路径；本机只读 `os.readlink` 实际返回 `/var → private/var`、`/tmp → private/tmp`，都是相对于根目录的写法。比较失败后路径仍含 `/var` 或 `/tmp`，逐级 `openat(O_NOFOLLOW | O_DIRECTORY)` 在该符号链接处拒绝打开，发生在云状态预检之后、`willRead` 和内容读取之前。
- 使用 `resolvingSymlinksInPath()` 也不能保证保留物理前缀：Apple 明确说明，当去掉 `/private` 后仍指向现存文件时，该 API 会去掉它；`AppIconCache` 使用的 `standardizingPath` 也有类似行为。因此新夹具与 `PathSafety.normalizedPath` 都可能重新得到 `/var/...`，不能通过改夹具位置规避产品问题。依据：[NSURL.resolvingSymlinksInPath](https://developer.apple.com/documentation/foundation/nsurl/resolvingsymlinksinpath)、[NSString.standardizingPath](https://developer.apple.com/documentation/foundation/nsstring/standardizingpath)。
- 这解释了三个连带现象：打开失败被扫描器的既有逐文件错误处理跳过，重复组为空；哈希进度从未增加，依赖哈希进度的取消回调不会触发；新替身从未到达 `read started`，测试稍后发出的取消已经晚于扫描完成。现有证据不支持“普通文件被 SF_DATALESS／下载状态误判为云端”的推测。
- 续扫日志未在“从第 16 个目录恢复、最终 19 个目录／18 个文件”的旧断言处报错，失败发生在内容确认得到 0 组之后。源码对照也确认检查点编码、校验、发现阶段及完成／取消时发布检查点的边界未被本批改动；不能用重置续扫计数或提前清除检查点解决此次问题。

### 修正与调用点逐项核对

产品修正仅在共享读取器：对根目录下的 `/var`、`/tmp` 两个固定别名，认可其**精确的绝对目标或相对于根目录的目标**，返回 `/private/...` 的字符串用于原逐级 no-follow 打开。不对结果再调用 Foundation 的路径标准化，也不解析用户任意符号链接。其他目标、查询失败和不匹配的路径保持原拒绝行为。`linkDestination` 是同步、非逃逸的元数据查询注入点，用于在不改系统链接的情况下覆盖两种写法。

`FileContentReadGuard`（包括 SF_DATALESS、下载状态、线程 OFF）、`Snapshot` 的 fstat 复查、取消与超时、身份校验均未改。没有新增并发豁免、放宽文件权限／云状态保护、改旧断言或预算。相同根因影响的预览、清理及搬家读取由这处共享修正覆盖。

| 调用点／边界 | 与批次前 `9e53489` 的对照，以及 fix2 核对结论 |
|---|---|
| `scanReport` 两个入口 → `confirmedGroups`／`manualCandidates` | 普通入口仍转调完整入口；完整入口的注入 reader 原样传到两条内容分支，续扫也走同一分支，没有在中间重新构造默认 reader。fix2 不改扫描器。 |
| `quickFingerprint` → `withValidatedFile` → `reader.withFile` | 原先直接打开后读首尾；N6 改为同一注入池打开、校验、读首尾。仍使用原 candidate 快照；`control.isCancelled` 明确传给等待方，工作控制器在两次读取间检查取消。系统别名修正后可到达原读取及替身。 |
| `sha256` → `reader.open`／`reader.readChunk` | 原先整次哈希在打开闭包内；N6 改为按块有界读取，但 reader、pool、guard、willRead 始终来自同一注入值，只把 timeout 取与剩余扫描预算的较小值。每块前仍查暂停／取消，进度仍在调用线程累计。 |
| `imageSimilaritySignature` → `withValidatedFile` | 继续传同一 reader、扫描 control 和时间预算；ImageIO 在受保护工作线程中使用描述符。读取取消映射为 cancelled；超时映射为部分完成。原有新测试继续覆盖，不改其 1 s 断言。 |
| `FileContentReadPool.read` | 回调 `isCancelled` 在扫描／调用线程轮询，不能改成只在 GCD 线程问 `Task.isCancelled`。扫描 control 取消后抛 `CancellationError`；`withValidatedFile`／哈希包装映射为 `FileReadError.cancelled`，最终 report 再合并 control 状态。池容量、超时、迟到结果及句柄所有权保持原实现。 |
| 断点续扫 | 与 `9e53489` 逐段比较：`encodedResumeIndex`、`validatedResumeIndex`、完整入口的发现／16 目录检查点区段、结尾的检查点重发／清除区段均字节一致。取消和超时重发最后已持久化边界，成功确认后才清除；新测试另外覆盖内容阶段取消后从持久化数据恢复。 |
| `SimilarImagePreviewCache.load` → `reader.withFile` | AppIconCache 传递订阅取消控制器；load 传入同一 reader，默认 5 s。缓存标准化路径可能省去 `/private`，故也需要共享别名修正；不改缓存键或取消语义。 |
| `FoundationCleanupContentDigestReader` → `reader.sha256` | N6 替换原直接 FileHandle 哈希，reader 未被覆盖。SafeCleanupExecutor 对 source／retained 的三次复查、错误原因映射、取消后不调用 mover 并释放租约都保留；本轮两个直接哈希入口使用别名的正常文件由新测试覆盖。 |
| `SafeCleanupExecutor.boundedDuplicateSnapshot` | 元数据依赖为 Sendable，工作闭包不捕获 actor 状态。这里使用共享池而非注入 digest 的池，是独立元数据读取；不触发内容探针，不是本次 `read started` 丢失的原因。 |
| `migrate`／`moveOriginalToTrash` 的来源与保留副本预检 | 同一 contentReader 传到 availability、inspectSource、身份快照、verifyCopy、sourceIsUnchanged 和回执最终 validate；fix1 的 FileManager 工作线程内获取保持。没有向读池提交目标写操作。 |
| `GuardedFileCopy.copy`／`copyResourceFork` | 元数据、普通文件 open／readChunk、资源叉均使用传入 reader 的池与保护；默认取消查询在迁移任务调用线程执行。只把源读取放进池，目标写入、暂存清理及发布仍由调用者负责。别名修正不会放行中间或末级用户链接。 |
| `filesHaveSameSHA256`／`applicationSignatureIfNeeded` | 两份文件先检查 availability，再用同一 reader 分别哈希；包树检查与验签使用同一池。元数据、fstat、云状态与内容比对仍在写入前复查。 |
| `LargeFilesView` 两条迁移任务 | 外层取消继续调用 detached worker.cancel；UI／store 回写仍在继承主 actor 的外层 Task。本轮不改变已发布副本与取消的完成点。 |
| 间接使用者 `BrowserPrivacyRecoveryBackupService.backup`／`restore` | 全仓调用点复查发现它们也使用 `FoundationCleanupContentDigestReader`（生成备份摘要及恢复前核验），会受同一临时目录别名问题影响。其调用点和备份／恢复规则不改；补列 `BrowserPrivacyRecoveryTests` 为共享读取器回归测试。 |
| 其余批次文件 | `CleanupExecutionModels`、两处原因展示 View、旧重任务入口删除、全部 5 个测试文件及两份交接／审计文档重新核对；没有另一套内容打开实现需要单独补别名。原 CSV 保留为首轮盘点快照，本节补充间接摘要调用的影响。 |

以上为源码审计，不能充当取消时延或运行时成功的证明；本轮未执行产品代码。

### 新增测试、红／绿／反证

新增 4 个方法，仅在原测试类中追加；所有既有方法、断言、夹具实现和阈值保持字节不变。新文件夹只由主会话运行测试时创建在 `/private/tmp`、`/private/var/tmp` 的 UUID 子目录或已有隔离临时夹具下，结束时移除自己创建的目录。没有真实云盘夹具、真实偏好域或应用数据目录写入。

| 方法 | 红与绿（绿均待主会话执行） | 反证 |
|---|---|---|
| `FileContentReadGuardTests.testSystemAliasTranslationAcceptsOnlyItsExactRootRelativeOrAbsoluteTarget` | 旧代码漏掉 root-relative 写法；新代码支持两种精确目标，拒绝错目标、嵌套目标、查询失败及近似前缀。通过查询替身完成，不改 `/var`／`/tmp` 链接。 | 在隔离副本只恢复绝对目标比较，root-relative 断言应失败。 |
| `FileContentReadGuardTests.testLocalFilesUnderBothSystemTemporaryAliasesReachTheContentReader` | `/var/tmp` 和 `/tmp` 真实隔离普通文件经 reader 与清理摘要入口按块哈希，摘要与内存 SHA-256 一致、读取计数大于 0、Provider 查询为 0。 | 撤掉相对目标支持，应在正常文件打开时失败，而非取得摘要。 |
| `FileContentReadGuardTests.testSystemAliasDoesNotPermitUserSymlinksOrReadTheirContents` | 系统别名后的用户父级链接、末级链接仍打不开，内容读取次数 0。 | 仅去掉父级目录 openat 的 O_NOFOLLOW，父级链接读取与计数断言应失败；末级另有 lstat 快照防线，不能用仅删末级 O_NOFOLLOW 的仍绿结果宣称防线无效。 |
| `DuplicateContentReadTests.testScanControlCancelsBlockedFingerprintAndHashThenResumesFromCheckpoint` | 分别在指纹及哈希内阻塞，**只取消扫描 control**，替身未返回时扫描在 1 s 内报告 cancelled；取消不误报 timeout。隔离 `DuplicateFileResumeIndexStore` 保留检查点，另一次注入 reader 的续扫得到 1 个两文件重复组，扫描计数不重复、hashedFiles=2，完成后清除检查点。 | 将 scanner 的 `isCancelled` 改为仅问 Task 或丢弃传入 reader，应违反取消／read started 断言；取消时清除 checkpoint 或续扫丢候选应违反持久化／分组断言。 |

主会话原 5 个失败方法全部保留，包括旧测试的数组访问；没有用删除／绕过该断言阻止崩溃。根因修正后应由非空分组让该访问成立；为避免某个类再崩溃遮住其他类，下面把测试拆成三条独立命令。

### 主会话重跑命令与交付状态

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'FileContentReadGuardTests|DuplicateContentReadTests'
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'DuplicateFileScannerTests|DuplicateSelectedLocationsTests'
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'GuardedMigrationReadTests|CleanupExecutionSafetyTests|SimilarImagePreviewCacheTests|AppIconCacheTests|ExternalMigrationReceiptTests|SystemUtilitySafetyTests|HeavyWorkIntegrationTests|TestPreferenceHygieneTests|BrowserPrivacyRecoveryTests'
git diff --check
```

Swift 6 默认严格并发；继续按首轮命令完成严格并发、完整门禁和独立复核，日志另存 `logs/fix2-*.log`，保留修前日志。反证在主会话隔离副本执行，单次只移除表中指定防线，完成后恢复最终版重跑；不得改本批 prepared 或在真实文件上做删除／搬家。

- 本会话 **PASS（静态）**：只读系统别名目标核对、补丁完整性、差异空白检查、SHA-256 回读、旧测试无删除改写、上述续扫区段与原基线一致、`ScanStore.swift` 未改。命令与退出状态见 `prepared-fix2/static-checks.json`；证据摘要及日志 SHA-256 见 `diagnostic-evidence.json`。
- 本会话构建、XCTest、运行时反证、提交、合并、安装均 **NOT RUN**；运行测试数 0。主会话的修前红灯不等于本轮已执行测试，也不能在重跑前声明绿灯。
- JEV `jev_review` 返回 `model=jev-latest`、`action=escalate`、`safe_to_apply=0.23`；没有文字原因，未取得自动接受。原始返回保存在 `prepared-fix2/jev-review.json`，仍由主会话结合编译与测试独立复核。
- 交付目录 `~/Developer/.sc-build/r2-icloud-reads/prepared-fix2/`：`01-system-alias`（共享读取器）、`02-alias-regressions`（4 个新增方法）、`03-fix2-handoff`（本节）；另含各组提交说明、all.patch、manifest、提交脚本及静态证据。基线为 `33bf7b0`，提交尾行按 `Codex (gpt-6-astra)` 与 Claude Opus 5.5 要求设置。本轮不提交，原 prepared／prepared-fix1 保留。

暂未发现另一个需修改的同类路径转换或取消注入缺陷；产品修正仍需上述主会话重跑证实。首轮记录的不可中断内核调用、异常目标卷清理及其他未统一保护的读取入口等边界继续有效。

## 主会话验证结果（fix2 后，2026-10-08 00:1x）

- **编译反馈循环**：
  - `c729a18` 首次编译失败（`ExternalDriveMigrationService.swift:628` 捕获非 Sendable 的 `FileManager`），fix1（`adf1c69`、`33bf7b0`）修正。
  - 随后定向测试大量失败并崩溃：重复文件扫描回退 3 项、新测试的读取钩子从未触发。根因是读取器不认 `/var`、`/tmp` 系统别名，fix2（`e9da64c`、`f94c63d`、`2022475`）修正。
- **主会话修正**（测试，见上一提交）：`testBundleCopySkipsCloudDescendantWithoutReadingIt` 注入的占位判定改为比较展开后的路径。
- **定向测试**：用本交接“定向测试”命令里的过滤，共 376 个，跳过 1 个，0 失败，exit 0。
- **复核**：派一位全新的 Claude 复核员（可编译、可做实验），重点核对文件搬家改为分块复制后，扩展属性、ACL、资源叉、Finder 标签、时间戳、文件标志是否保留。

## fix3：按 D61 恢复系统复制保真，处理独立复核意见

### 基线与证据边界

- 基线 `2d2a6477fc9c144c3a3b46aeeccaf28126fba4ce`，分支 `task/r2-icloud-reads`；开始时工作区干净。上节的 376 个定向测试、0 失败、1 跳过是**主会话对 fix2 的结果**，不代表 fix3 通过。
- 已读 `~/Developer/.sc-build/r2-icloud-reads/review/review-1.md` 全文：3 个 P1 有真实元数据对照证据，9 个 P2 包括实测、源码问题和明确标注的慢盘推断。此前的分块复制器由本批引入，问题在产品代码，不能改只读文件或 ACL 断言来掩盖。
- 按集成工作区 `~/Developer/StorageCleanerMac/docs/2.0.0/collab/DECISIONS.md` 的 D61 实现；同时遵守该工作区 RULES 第 3 节末的夹具位置规则。两份集成文档只读，没有复制覆盖本工作区的决定或规则。
- 本会话只改源码、测试、交接与 prepared 产物；**构建、Swift 6 编译、XCTest、元数据实验、反证、提交均 NOT RUN，执行测试数 0**。下述“覆盖”指已写测试，绿灯须主会话执行确认。

### 复核项对应改法

| 复核项 | fix3 产品变化 | 定向证据／待跑测试 |
|---|---|---|
| P1-1 只读文件／目录带 xattr 失败 | `GuardedFileCopy` 改用系统 `copyfile`，不再自行按错误顺序回写权限和 xattr。私有暂存清理按描述符逐级处理，只在自己拥有的树里解除阻塞删除的标志／目录权限／ACL。 | `GuardedFileCopyMetadataTests`：0444+xattr、0555+xattr、只读 `.app` 资源；完整 migrate 的只读文件；暂存只读目录与锁定子项清理。 |
| P1-2 标志和透明压缩丢失 | `COPYFILE_ALL | COPYFILE_CLONE`，不可克隆由系统回落；不再跳过 decmpfs、不再自行展开内容／资源叉。根项目的 immutable／append 标志如已复制，先从私有目标移除，发布改名后恢复；不改源标志。 | 隐藏+uchg 文件的 migrate 端到端断言；有／无克隆两条压缩路径检查标志、占用块数和内容。 |
| P1-3 不支持 ACL 的目标整份失败 | 目标卷能力判断可以注入；不支持扩展安全属性时从系统复制选项去掉 ACL，其余属性按系统行为处理。保留系统对 exFAT／FAT32 不支持属性的处理方式。 | ACL 文本往返、能力替身 `false` 后内容仍完整且不复制源 ACL；真实 exFAT／FAT32 镜像对照仍须主会话执行。 |
| P2-1 时间戳 | 记录源 atime／mtime 的秒与纳秒，使用 `utimensat(..., AT_SYMLINK_NOFOLLOW)` 恢复私有目标及链接自身时间；哈希／验签后再恢复一次。创建时间、权限等仍由系统复制。两次恢复都在可取消、有界工作线程执行。 | 分别断言 atime、mtime 的秒和纳秒、目录时间、符号链接自身时间；完整 migrate 后断言时间而非只测底层 copier。 |
| P2-2 全局读槽耗尽 | `FileContentReadPool` 按卷分配最多 4 个槽；以 `getfsstat(MNT_NOWAIT)` 的缓存挂载点与 fsid 区分，不对无响应卷 `stat`。复制另用源／目标卷组合的有界槽，不能占用本地内容读槽。超时工作线程真正返回后才归还槽。 | `FileContentReadIsolationTests.testFourStalledReadsOnOneVolumeLeaveOtherVolumeHashAndCopyAvailable`：4 个 gate 未释放时同卷 busy，另一卷哈希与复制仍成功。 |
| P2-3 固定 15 s 验签 | Security.framework 无进度回调，改按包大小预算：`max(60 s, 30 s + size / 2 MiB/s, reader.timeout)`，上限 30 分钟；等待仍每 10 ms 检查取消。 | 大包预算随大小增加、有有限上限的测试；慢盘大应用实测仍待执行，此数值是保守预算，不声称已测性能。 |
| P2-4 每个目录问 Provider | 复用 `DiskScanner.storageMapNeedsCloudState` 的路径规则，内容读取不再走其目录无条件查询分支；Desktop／Documents 根加路径分隔符以保留匹配。 | 普通 30 层级分支目录树 Provider 探针为 0；只用纯路径判断检查 CloudStorage／Mobile Documents／Desktop／Documents，不访问这些真实目录。 |
| P2-5 文案不准／系统英文 | 搬家错误统一经 `FileContentReadError.userMessage`；新增特殊文件、深度、路径、目标大小限制的准确原因。删除自写资源叉的 4 GiB 上限，由系统 `EFBIG` 映射准确大小原因；元数据读取失败保留系统错误类别，不一律假称变化。重复扫描另记可兼容旧 Codable 的 `contentReadUnresponsive`。 | 中英文错误映射、FIFO 不读内容、129 层目录拒绝；`DuplicateContentReadTests` 增加读取超时／池满原因断言；Views 定向集合含 `UIConsistencyRegressionTests`。 |
| P2-6 invokedMove 后抛取消 | 删除原件移动闭包开头的 `Task.checkCancellation()`；回执前后 validate 的取消检查保留，一旦开始移动仍完成记录。 | `MigrationVerificationReuseTests.testCancellationAfterMoveStartsStillRecordsTheCompletedMove`；准确的 invokedMove→闭包入口微小窗口另见反证说明。 |
| P2-7 主动操作 QoS | 搬家、系统复制、复制后元数据恢复、清理复核默认 `.userInitiated`；扫描和预览默认 `.utility`。所有 reader 派发都传入 priority。 | 检查主动读取线程 QoS（允许 OS 提升）、线程禁止物化策略，以及清理默认 reader 的 priority。 |
| P2-8 反复整份哈希 | 新增仅驻内存的 `MigrationContentVerification`，绑定两端路径、SHA-256、device/inode、size、纳秒 mtime/ctime。复制校验的结果经发布后身份确认传给 UI/store；处理原件在回执前后都检查完整快照，未变复用，变动才重哈希。 | 传入复制证明后读内容 0 次；无证明各文件哈希一次共 2 次；回执写入时改目标等长内容并精确恢复 mtime 仍由 ctime 使缓存失效并拒绝移动。 |
| P2-9 测试缺口 | 新增 3 个类、19 个方法；原有资源叉／下载状态／系统别名／扫描取消／续扫断言继续使用。 | 本节主会话命令与逐项反证。 |

系统复制选项、回调传参以及克隆行为核对了当前 SDK 公共头文件和 Apple 原始实现：[copyfile 手册](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.3)、[copyfile 源码](https://github.com/apple-oss-distributions/copyfile/blob/main/copyfile.c)。`COPYFILE_STATE_STATUS_CB` 接收函数指针本身；状态、回调上下文只在一个工作线程使用。成功克隆可能没有数据进度回调，因此仍保留复制前全树预检、复制后源身份／大小／mtime／ctime／云状态复查与调用方时限，不依赖回调作为唯一保护。

### 取消、暂存、发布和回执边界

1. 源预检只做元数据操作；SF_DATALESS／下载中拒绝，复用 2c 的判定与同线程 `setiopolicy_np(...OFF)`。`copyfile` 全程在此策略下运行，回调开始时还检查源云状态，取消时返回 `COPYFILE_QUIT`。普通文件、系统 `/var`／`/tmp` 别名支持没有放宽或移除。
2. 超时采用无进度看门狗，预检节点、复制回调和目标时间恢复更新进度；调用方 10 ms 轮询取消。取消／超时后完成盒标为作废，调用方退出；尚未返回的线程继续独占私有暂存，只能清理，不能发布。清理成功前保留原暂存待清理回执。
3. 仅发布成功的调用方返回副本；发布后若恢复锁定标志失败，返回带警示的已生成副本，保留原件，不把成功改名谎报为“未完成复制”。不会自动弹出处理原件确认；后续用户再次主动处理仍须完整复核。
4. 暂存清理用捕获的目录身份、no-follow／fd 相对遍历，逐级复查身份再移除；拒绝经指向其他位置的链接改写。阻塞标志位于多硬链接普通文件时保守拒绝修改并保留待清理记录。底层 copier 默认不擅自删除目标，生产调用显式提供身份绑定的暂存清理，已有目标被 EXCL 拒绝后原样保留。
5. 哈希证明不写磁盘、不跨启动信任。发布后的自有改名／时间恢复会改变目标 ctime；只在源完整快照不变、目标身份／大小／纳秒 mtime 仍匹配时绑定发布后的快照，失败则丢弃优化。随后回执前后均比较完整快照（含 ctime），必要时重哈希。原件应用包仍按既有决定保持只复制，未改批准的清理／恢复语义。
6. 并发复查：跨 GCD 闭包传 Sendable URL、reader、快照、回执与只读配置，不捕获 FileManager；需要时在线程内取得 `.default`。C 回调的 `Job` 是新同步容器，其全部可变字段私有并受同一 NSLock 保护，原始 context 的存活由工作闭包持有；不是用 `@unchecked Sendable` 掩盖未同步状态。无 `nonisolated(unsafe)`／`@preconcurrency` 新豁免，UI/store 回写仍在原 MainActor 任务内。

### 旧测试调整、夹具位置与读取盘点补充

- 按 D61③ 逐项改写两个旧断言时点：`testBlockedCopyTimesOutCleansStagingAndNeverPublishesLate` 在 gate 未返回时改查“无已发布副本”，释放 gate 后原“无暂存／副本”断言保留；`testCancelledCopyCleansStagingBeforeBlockedReadReturns` 改名为 `testCancelledCopyDefersStagingCleanupUntilWorkerReturns`，同样先查无发布、线程返回后查清理。原件内容、取消类型、1 s 上限断言保留，没有放宽阈值或跳过测试。
- `GuardedMigrationReadTests` 的复制／哈希夹具统一复用 `MigrationContentFixture`：`~/.storage-cleaner-content-tests-<UUID>`；新增 3 类也用它。`Audit20260919RegressionTests` 暂存用 `~/.storage-cleaner-staging-tests-<UUID>`；`RecordedTrashRecoveryTests` 改为 `~/.storage-cleaner-recorded-recovery-<UUID>`／`~/.storage-cleaner-uninstall-denial-<UUID>`。这些位置调整不改断言、不放宽产品路径检查。若 hygiene 批也修改后两个文件，由主会话按同一夹具规则合并；本轮未改它拥有的 `ScanStore.swift` 或 `HeavyWorkIntegrationTests`。
- 语言测试用 `TestPreferenceDomain.swift` 中的 `TestVolatilePreferences`，只设置并恢复内存 volatile domain。无真实偏好、缓存、应用数据或 File Provider 夹具。压缩夹具由测试在隔离目录调用 `ditto --hfsCompression` 生成；已知复核机可构造，测试将构造失败明确断言失败，不伪装为通过。此会话没有运行构造命令。

| 内容路径 | fix2 状态 | fix3 状态 |
|---|---|---|
| 搬家数据／资源叉／压缩属性 | 共享 guard + 自写逐块复制，手工元数据存在复核缺陷 | 同一 guard／线程 OFF + 系统 copyfile；取消回调、无进度时限、私有目标迟到清理、系统元数据保真 |
| 搬家哈希、清理复核哈希 | 全局读池、utility；处理原件重复全哈希 | 按卷读池、userInitiated；完整快照约束下复用已验证摘要 |
| 应用包验签 | 全树 guard、固定 15 s | 路径限定 Provider 查询、按包大小给有界预算；同一线程 OFF／取消／按卷槽 |
| 相似预览、重复指纹／哈希／图片签名 | 已有 guard／可取消／有界，四槽跨卷共用 | 同一注入 reader 和取消传播不变；按卷槽；重复扫描将 I/O 无响应与通用预算上限分别展示 |
| 缩略图缓存、浏览器恢复备份摘要等间接调用 | 见 fix2 表与首轮 CSV | 经共享 reader 获得按卷隔离；没有新增无保护的平行内容读取器 |

首轮 258 行 CSV 保留为当时快照；本节补充替换的系统复制入口。重复发现、每 16 目录检查点、最终重发／清除边界继续与 `9e53489` 逐段字节核对，不改持久化语义。Scanner 只增加读异常原因传播。

### 用户可见文案（新增／改动，原云端与下载中词句不变）

| 条件 | 中文 | English |
|---|---|---|
| 特殊文件 | 包含管道、设备或其他不支持复制的特殊文件，已停止。 | A pipe, device, or other unsupported special file was found. Copying stopped. |
| 深度超限 | 文件夹嵌套层级过深，无法安全处理。 | The folder nesting is too deep to process safely. |
| 路径／链接不支持 | 路径无效或包含不受支持的链接，未读取内容。 | The path is invalid or contains an unsupported link; content was not read. |
| EFBIG | 文件或附带资源超过目标磁盘支持的大小。 | The file or its attached resources exceed the size supported by the destination disk. |
| 权限／锁定 | 没有足够权限处理此项目，请在访达中检查权限或锁定状态。 | This item cannot be processed with the current permissions. Check its permissions or locked state in Finder. |
| 磁盘／网络系统错误 | 磁盘或网络无响应、已断开或只读，请检查连接后重试。 | The disk or network is unresponsive, disconnected, or read-only. Check the connection and retry. |
| 不支持的系统操作 | 目标磁盘不支持此文件操作，请选择其他磁盘。 | The destination disk does not support this file operation. Choose another disk. |
| 其他系统错误 | 无法完成文件操作，请检查访问权限和磁盘连接后重试。 | The file operation could not be completed. Check access permissions and the disk connection, then retry. |
| 复制等待取消 | 已取消等待，原件保留；未完成的副本不会发布，临时文件将在复制返回后清理。 | Waiting was cancelled. The original was kept. The unfinished copy will not be published; temporary files will be cleaned up when copying returns. |
| 处理原件取消 | 已取消处理原件，原件和已验证的副本均保留。 | Handling the original was cancelled. Both the original and the verified copy were kept. |
| 发布后标志恢复失败 | 副本已生成，但未能恢复锁定等文件标志；原件保留，请在访达中检查副本。 | The copy was created, but its locked state or other file flags could not be restored. The original was kept. Check the copy in Finder. |
| 重复扫描 I/O 无响应 | 磁盘或网络无响应，已停止等待部分文件；结果为部分覆盖，请检查连接后重试。 | The disk or network is unresponsive. Waiting for some files stopped; coverage is partial. Check the connection and retry. |

空间不足、源消失、同名目标继续复用 `ExternalDriveMigrationError` 的既有中英文，不显示底层错误原文。

### 主会话定向类与红／绿／反证

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'GuardedFileCopyMetadataTests|FileContentReadIsolationTests|MigrationVerificationReuseTests|GuardedMigrationReadTests'
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'FileContentReadGuardTests|DuplicateContentReadTests|DuplicateFileScannerTests|DuplicateSelectedLocationsTests'
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'ExternalMigrationReceiptTests|RecordedTrashRecoveryTests|Audit20260919RegressionTests|CleanupExecutionSafetyTests|SimilarImagePreviewCacheTests|AppIconCacheTests'
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'SystemUtilitySafetyTests|UIConsistencyRegressionTests|HeavyWorkIntegrationTests|TestPreferenceHygieneTests|BrowserPrivacyRecoveryTests'
git diff --check
```

日志请另存 `logs/fix3-*.log`；Swift 6 默认严格并发，不改变语言设置。上述通过后按 RULES 执行完整门禁（独立 verify root，`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`），再派独立复核。需要视觉确认两条取消提示与重复扫描无响应提示，但不得在本实现会话启动应用。

| 对象 | 红灯与绿灯做法 | 反证（仅主会话隔离副本／隔离夹具） |
|---|---|---|
| 元数据与权限 | 保留复核实验的基线／失败版本数据；新 metadata 类完整执行，包含源码 copy 与 migrate。 | 切回旧手工元数据写入应再现 readonly+xattr 失败、flags／压缩／时间失败；单独取消目标 ACL 能力分支，用注入 false 的断言或真实 exFAT 对照识别。 |
| 标志发布 | 隐藏+uchg migrate 应成功、源目标标志均保持、无暂存。 | 删发布前清阻塞标志应 EPERM；只删发布后恢复应被目标标志断言捕获。 |
| 取消与暂存 | `testProgressCallbackStopsCancelledOrTimedOutSystemCopyAndCleansOnlyAfterReturn` 在实际数据回调里阻塞（关闭克隆），取消／超时均 <1 s，工作线程返回前暂存尚在、返回后清理。 | 删调用方取消轮询应无法及时返回；删 abandoned／回调退出应继续复制；删失败清理应留下暂存。不要使用真实 NAS 拔盘代替可控 gate。 |
| 云端保护 | 继续跑原 cloudOnly／downloading／bundle-descendant 的读取探针为 0 断言；复制回调内还检查线程策略。 | 删 preflight cloud 检查应触发内容探针；删线程 OFF 应使线程策略断言失败。仅用替身，不在真云盘造占位。 |
| 槽位隔离 | 四个阻塞读持有槽时，健康卷哈希和复制必须成功。 | 将 `volumeIdentity` 固定成单个 key，应回到 healthy hash 的 busy 失败。 |
| 验签与 Provider／QoS | 大小预算测试、普通目录 Provider 0、主动 QoS 与 OFF 断言。 | 改回固定 15 s／无条件目录查询／utility，分别使对应断言失败。慢盘上真实大包验签另由主会话做只读验证。 |
| 文案与 I/O 原因 | 双语言错误映射；扫描报告无响应 flag；UIConsistencyRegressionTests 与界面状态确认。 | 将 special/depth/EFBIG 映射回 changed、丢弃 unresponsive flag，应触发原因断言；把 View 分支改回保护上限，需界面读回发现（报告测试不替代显示验证）。 |
| 摘要复用安全 | reuse 类：0 次／2 次内容读取，回执变动拒绝移动；原有无回执不移动、目标变动不移动、恢复测试继续执行。 | 无条件重哈希违反计数；无条件复用违反回执内改内容测试；删 ctime 比较且保留 size/mtime，精确恢复 mtime 的篡改应被该测试抓住。 |
| invokedMove | 取消发生在 move 已开始后仍有完整可恢复回执、unknown=0；源码确认闭包入口无取消检查。 | 该动态方法覆盖已进 move 的取消，不能单独覆盖旧入口前几条指令；主会话如复现旧窗口，需在隔离 RecordedTrashOperation 的 invokedMove=true 后、调用 move 前注入取消，恢复旧 Task.checkCancellation 后应得到错误 unknown，再删掉该行应完成回执。不要把普通晚取消测试误称覆盖了窄窗口。 |

### 静态交付与剩余验证

- `prepared-fix3/` 分 5 组：`01-content-read-isolation`、`02-system-migration-copy`、`03-copy-regressions`、`04-fixture-locations`、`05-fix3-handoff`。含各组 patch／message、`all.patch`、manifest、主会话提交脚本、静态检查与诊断证据。21 个最终文件逐一记录 SHA-256；commit-prepared.py 只供验证后执行，本会话不执行。
- 静态检查包括差异空白、补丁反向适用、最终文件／产物哈希回读、索引为空、HEAD／分支匹配、ScanStore 未改、首轮审计 CSV 未改、4 段续扫边界与原基线一致。新 C API 用法、捕获和 actor 边界是人工源码检查，不是 Swift 编译证明。
- JEV 两次返回都未自动接受：首次 54695 字符超过工具上限且 `truncated=true`（safe_to_apply=0.08）；第二次完整核心候选输入未截断（safe_to_apply=0.04、action=escalate、model=jev-latest），均无文字原因。原始返回保留在 `jev-review-truncated.json`／`jev-review.json`。其后最后源码复查补了时间恢复的有界执行、无效路径错误和相应测试，不声称 JEV 评过最终字节或已复核通过。
- 待主会话验证：Swift 6 编译、以上全部定向类、压缩构造／系统元数据在 APFS 和 HFS+ 的实际结果、真实 exFAT／FAT32 对照、慢盘大包验签、界面文案与独立复核。ACL 能力替身不等于真实跨文件系统实验；目标不支持的属性与时间精度遵循系统能力，不承诺无法表达的纳秒／ACL。
- 内核调用无法强制安全终止；取消／超时后不会发布，但暂存实际清理仍需等待该线程的系统调用返回。线程永不返回或目标卷失联时，保留待清理回执，不能承诺立即物理删除。源数据不写回；发布、回执与清理语义仍遵守 D49／D52。没有 ScanStore 协调修改请求。

## fix4：复制错误必须退出，修正只读目录次序与宿主夹具前提

### 基线、规则与主会话证据

- 基线 `4ba44c64df183922ad9238ad417418b6de4c9eff`，分支 `task/r2-icloud-reads`；开始时工作区干净。包含 fix3 五组提交和主会话的 `Array(repeating: statfs(), count:)` 编译修正，后者不改。
- 已读本批 common.md、RULES、BOARD 的 N6、整个交接、review-1.md，及 D5／D48／D55／D60／D61。当前 worktree 的 DECISIONS 尚无 D61、D60 尚未更新，按主会话集成工作区的两项决定和本轮用户指令执行；不覆盖决定文档。D61 的系统复制、只读云端预检、禁止物化、后台工作所有权与受保护哈希方向不变；本轮不调用 Astra。
- **PASS（主会话的基线编译）**：用户反馈 HEAD `4ba44c6` 沙箱外编译通过，3 条与本批无关的警告；不充当 fix4 编译证据。
- **FAIL（主会话的基线定向测试）**：已读 `fix4/failures.txt` 和 `logs/main-test-6.log` 的错误与汇总。19 类、481 项、跳过 1；4 个失败方法、8 处断言失败，均在 `GuardedFileCopyMetadataTests`。原跳过是 `SystemUtilitySafetyTests.testLiveSetappUninstallInventoryWhenExplicitlyEnabled`。已有目标的内容未改，但错误被吞；只读目录后续时间恢复撞 ENOENT；无 ACL 被辅助函数当作 EIO；透明压缩夹具没有压缩标志。
- **NOT RUN（本实现会话）**：构建、Swift 6 编译、XCTest、实际元数据／压缩实验、反证、提交、合并、安装，执行测试数 **0**。common.md 明确禁止在 Codex 沙箱编译、测试和提交；本轮只改源码、测试、追加交接、生成补丁及做静态检查。没有修改 `ScanStore.swift`、其他 worktree 或已安装应用。
- **BLOCKED（JEV）**：核对工具说明后调用 `jev_decide`，用于比较逐项系统复制与整棵目录禁用克隆。工具没有模型选择参数；返回 `MCP tool call requires approval, but approval policy is never`，没有返回实际模型标识或任何判断。本轮无 JEV 通过结论，不请求额外审批、不重复该判断调用，主会话仍须不同模型独立复核。原始返回记录在 `prepared-fix4/jev-status.json`。

### 根因与实际修复

1. **错误阶段失效**：旧回调在 `COPYFILE_ERR` 也返回 `COPYFILE_CONTINUE`。现进入回调即保存 errno，先记录首个 `POSIXError`，返回 `COPYFILE_QUIT`；错误分支不做 observer／云状态／进度操作。系统返回后优先抛该回调错误，避免后续 ECANCELED 或锁操作掩盖原始 ENOSPC／EACCES。非回调失败仍检查系统返回值并抛真实 errno。默认底层 copier 没有删除目标的权限；生产迁移原有身份绑定清理闭包仍由工作线程在调用返回后执行。
2. **只读目录还有独立的真实错误**：Apple `copytree` 对目录前序先去掉 STAT，但克隆回退又添加 `COPYFILE_STAT | COPYFILE_EXCL | COPYFILE_XATTR | COPYFILE_DATA`，使 0555 提前恢复；链接则在目录清理后的第二遍才复制，嵌套链接也会遇只读父目录。仅把 ERR 改成 QUIT 不能解决此复制次序。
3. **保持系统复制的逐项执行**：复用原只读预检所得 `Entry` 树，目录排他 `mkdir(0700)`，非目录逐项 `copyfile(COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW)`，允许克隆时继续请求 `COPYFILE_CLONE`。文件和链接全部完成后，目录按后序调用系统 copyfile 恢复 ALL 元数据，去掉仅不适用此阶段的 CLONE／EXCL。ACL 不支持时仍只去掉 ACL 选项；没有手写内容、资源叉、xattr、ACL 或压缩复制。每次调用都新分配并释放 copyfile state，避免前一项的描述符／路径留在状态里。
4. **读保护与已有目标**：每项实际复制前、目录元数据恢复前及最终验收都检查原身份、类型、大小、纳秒 mtime／ctime 与云状态；克隆路径也不能绕过该检查。所有阶段在同一个禁止物化工作线程里，等待方／回调／节点仍可取消、更新无进度时限。已有根目标在进入系统复制前通过 lstat 直接抛 EEXIST，避免 copyfile 的权限回退碰到它；EXCL／排他 mkdir 继续保护后续创建。暂存所有权、作废、清理、发布点及回执代码不变。
5. **文件标志的边界**：延迟发布与时间恢复只临时清除 `UF_IMMUTABLE | UF_APPEND`。压缩位不在清除集合中，发布恢复以目标已有标志为基础，只补 owner-settable 阻塞位；不要求重新写入源的 SF_*。系统 copyfile 继续决定系统标志能否在目标表达。新增纯位运算及实际普通夹具测试，不能用手工设置无压缩数据的 UF_COMPRESSED 伪造压缩实验。
6. **测试辅助与夹具**：`aclText` 遇 `acl_get_link_np == NULL && errno == ENOENT` 返回空字符串，其他 errno 抛出，原 ACL／内容断言不改。透明压缩测试仅在 ditto 命令成功、目标元数据读回成功但 `UF_COMPRESSED == 0` 时 `XCTSkip("宿主无法构造透明压缩夹具（ditto --hfsCompression 未压缩）")`；命令失败或元数据读取失败仍失败。构造成功时两条克隆路径的目标压缩位、占用块数 `< payload.count / 2` 和完整内容断言原样保留。

源码依据保留在 `~/Developer/.sc-build/r2-icloud-reads/references-fix3/`：`copyfile.c` 的 copytree 两遍遍历／前序目录、克隆回退、目标权限回退，以及 `copyfile.3` 的 ERR／QUIT／errno 契约；本轮同时查阅 Apple 官方源码。`prepared-fix4/diagnostic-evidence.json` 记录这些文件、SDK 公共头、基线日志、决定和通用要求的 SHA-256。它们是源码与既有主会话证据，**不是本轮运行结果**。

### 测试调整、红／绿／反证

`GuardedFileCopyMetadataTests` 新增 **5 个方法**，原 **9 个方法全部保留**，类总数仍是 19。只读目录旧断言全部保留并在开／关克隆两条路径执行，新增 0555 目录内链接的内容和纳秒时间断言；每次复制前重新建立、捕获源目录时间，避免上一轮只读枚举更新 atime 后夹具失真。已有目标测试仍断言其内容，增加 EEXIST、inode、权限、标志、xattr 在开／关克隆后均原样。ACL 产品断言不改。唯一删除的旧断言是**夹具本身**是否压缩的失败断言，按本轮明确授权替换为上述严格前提 XCTSkip；所有产品断言和数值阈值不放宽。

下面绿灯和反证均 **NOT RUN**，由主会话在隔离副本执行。基线的四项失败是已有红灯证据；新方法的红灯通过对应最小反证构造，不能把未执行的反证记成已红。

| 测试／边界 | 绿灯要求 | 具体反证及预期失败 |
|---|---|---|
| `testNestedCallbackErrorsRetainErrnoStopPublicationAndCleanOwnedStaging`（新） | 嵌套应用资源实际先由 Darwin copyfile 复制，随后从当前 state 取出真实 C 回调／context，注入 DATA 的 ENOSPC 与 XATTR 的 EACCES；回调必须 QUIT，模拟系统把 errno 改成 ECANCELED 后仍抛原错误。不产生可发布 PreparedCopy，原件完整，等清理 expectation 后无暂存和发布项。 | 只把 ERR 的 QUIT 改回 CONTINUE，**回调返回值断言立即失败**，即使仍存 callbackError；再恢复整段旧 ERR 忽略逻辑，copy 会成功／发布，抛错、无发布、清理 expectation／无暂存断言失败。只删 callbackError 优先传播则 errno 断言看到 ECANCELED 而失败。 |
| `testUnreadableNestedChildThrowsAccessErrorAndCleansOwnedStaging`（新） | 非 root 测试进程下，嵌套源子项 chmod 000、关闭克隆，系统实际打开失败；抛 EACCES，不发布，工作返回后清理私有暂存；恢复权限后原件内容仍完整。 | 只删 `guard result == 0`，后续 ENOENT 或无错误会违反 EACCES 断言；删失败清理则 expectation／无暂存断言失败。此非回调失败测试**不声称**单改 ERR→CONTINUE 就一定红。 |
| `testExistingDestinationIsNeverOverwrittenOrRemovedOnFailure`（增强） | 已有目标带 xattr、0444、隐藏和 uchg；两种克隆模式都抛 EEXIST，身份、内容、权限和标志不变。 | 恢复 `4ba44c6` 整个旧递归复制入口／回调，原“不抛错”红灯应重现；删除根存在检查并去掉 EXCL 将违反 EEXIST／元数据保留断言。fix4 已有独立存在检查，**仅**把 ERR 改为 CONTINUE 不必使此测试红，不能错误宣称它单独证明错误回调契约。 |
| `testExistingDirectoryIsRejectedBeforeChangingAnyDescendant`（新） | 已有目录抛 EEXIST，inode 和唯一 sentinel 保留，源中的新子项没有写入。 | 删根存在检查，并将排他 mkdir 改为“已存在也继续”，目录子项／EEXIST 断言失败。 |
| `testReadOnlyApplicationDirectoriesAndResourcesRetainMetadataAndLinkTimes`（增强） | 开／关克隆都保留 0444 文件和 0555+xattr 目录、两处链接及秒／纳秒时间、内容。请求克隆的选项只出现在非目录阶段，目录元数据阶段不带 CLONE／EXCL。 | 恢复递归 ALL+CLONE，会在允许克隆路径提前设 0555；将目录元数据移到子项前会在两条路径造成写入或链接失败；关闭所有克隆则文件选项断言失败。保留原所有元数据断言。 |
| `testPublicationFlagHandlingKeepsCompressionAndDoesNotRequireSystemFlags`（新） | 合成压缩位在发布前／后均保留，延迟集合仅 UF_IMMUTABLE／UF_APPEND；把 SF_* 单独传给真实恢复入口时普通夹具不调用特权写入、标志／内容不变。 | 向清除集合加入 UF_COMPRESSED，使压缩位断言失败；恢复 SF_IMMUTABLE／SF_APPEND 到延迟集合，使集合和实际恢复断言失败；发布 helper 无筛选 OR 全部 deferred 会使纯值断言失败。无需宿主能生成压缩文件。 |
| `testACLIsPreservedAndUnsupportedACLDestinationStillCopies` | 源 ACL 文本往返；不支持 ACL 时无 allow、内容完整。 | 恢复 helper 的 NULL→EIO，无 ACL 分支恢复基线红灯；删产品 ACL 能力分支，能力 false 时文本断言失败。不能用 helper 去忽略其他 errno。 |
| `testTransparentCompressionIsRetainedWithAndWithoutCloning` | **夹具无法构造时 NOT RUN**（XCTest 记 Skip，并带明确原因）；能构造时全部原目标压缩／占用／内容断言必须过。 | 能构造的宿主上回退旧手写数据复制，应丢压缩／扩容并红；把产品压缩标志清除也应红。无法构造的宿主不做该反证，不把 Skip 当产品 PASS。 |
| `testChildBecomingCloudOnlyOrDownloadingAfterPreflightIsNotPassedToCopyfile`（新） | 仅替身在全树预检之后改变子项状态；实际调用 Darwin copyfile 前的子项内容探针为 0，原因准确，暂存清理，原件保留。 | 去掉逐项 `checkSource`，即使最终云状态复查会拒绝结果，子项已传给 copyfile，探针 0 的断言失败。没有真云占位、下载或驱逐操作。 |
| 取消／超时、锁定发布与暂存 | 继续跑原 gate 取消／超时测试及锁定完整 migrate 测试，1 s 阈值不变；线程未返回前保留暂存，返回后清理，迟到结果不发布。 | 沿用 fix3 的逐项取消／清理／标志恢复反证；删 failCallback 的退出或 failed 清理会让新增嵌套失败测试红。 |

### fix3 表格逐项重新核对

“基线”均指主会话 `main-test-6.log`，并非 fix4 结果；本轮最终字节的动态验证全部 **NOT RUN**。

| fix3 项 | 本轮核对与状态 |
|---|---|
| P1-1 只读+xattr | 基线普通文件／完整文件 migrate 测试 PASS，但只读应用目录 FAIL，故 fix3 的“已修好”不能成立。fix4 改后序目录元数据，增强原测试；最终验收待主会话。 |
| P1-2 标志／透明压缩 | 基线隐藏+uchg 的完整 migrate PASS；本轮限制恢复为 UF 阻塞位，保留发布前清除／发布后恢复与原件不写边界，原测试继续跑。压缩因为宿主前提失败独立记 **NOT RUN**，必须在可构造宿主实验；新增标志测试不替代该实验。 |
| P1-3 ACL | 基线 FAIL 在无 ACL 的测试 helper，产品能力分支未改；helper 修正后待验收。真实 exFAT／FAT32 仍 **NOT RUN**，不能以能力替身代替跨文件系统实验。 |
| P2-1 时间 | 基线单文件／完整 migrate 时间 PASS，应用目录时间未完整验收；原纳秒／链接时间断言保留并扩展，最终待验收。 |
| P2-2 槽隔离 | 基线 `FileContentReadIsolationTests` PASS。按源／目标卷组合槽、归还时机和其他卷读槽实现未改；复制逐项执行仍只占原一次作业槽。 |
| P2-3 验签预算 | 基线预算测试 PASS，验签与预算代码未改；慢盘真实大包验签仍 **NOT RUN**。 |
| P2-4 Provider 查询 | 基线普通目录探针测试 PASS，路径限定 guard 未改；逐项额外预检仍受同一 needsCloudState 条件控制，新状态变化测试待跑。 |
| P2-5 文案／原因 | 基线原因与无响应测试 PASS，相关 UI／模型代码未改；UIConsistencyRegressionTests 继续包含，真实界面显示验收仍 **NOT RUN**。 |
| P2-6 invokedMove | 基线晚取消回执测试 PASS，move 入口／回执最终 validate 未改；fix3 已写明的窄窗口反证仍待主会话，不扩大通过声明。 |
| P2-7 QoS | 基线主动 QoS 与线程 OFF 测试 PASS，GCD 队列与读取优先级未改；系统复制及目录后序恢复全在原 userInitiated＋OFF 作业线程。 |
| P2-8 摘要复用 | 基线复用／篡改／回执测试 PASS，证明绑定、ctime、发布后的快照重绑定和原件处理实现均未改；继续原定向类。 |
| P2-9 测试缺口 | 修正 4 项失败的具体原因，新增 5 个方法，保留所有既有方法和产品阈值；19 类最终运行数预计 486，以主会话实际发现／日志为准，当前运行数 0。 |
| 取消与暂存（fix3 边界表） | 基线实际 DATA 回调 gate、等待时限与暂存测试 PASS。`perform`／`Job.finish`／`abandon`、生产 cleanup 所有权、暂存身份清理、发布和回执代码均未改；只新增首错误保留。单个系统调用永不返回时仍不能承诺立即物理清理。 |

### 主会话定向验证与提交交付

定向类清单与 `logs/filter-fix3.txt` **完全相同**，全部新增方法位于已包含的 metadata 类；仍包含 UIConsistencyRegressionTests 和 TestPreferenceHygieneTests。`prepared-fix4/filter-fix4.txt` 复制并静态核对这 19 类。沙箱外在本 worktree 执行：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 > /Users/developer/Developer/.sc-build/r2-icloud-reads/logs/fix4-build.log 2>&1
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'GuardedFileCopyMetadataTests|FileContentReadIsolationTests|GuardedMigrationReadTests' > /Users/developer/Developer/.sc-build/r2-icloud-reads/logs/fix4-copy.log 2>&1
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-icloud-reads/debug --jobs 4 --filter 'AppIconCacheTests|Audit20260919RegressionTests|BrowserPrivacyRecoveryTests|CleanupExecutionSafetyTests|DuplicateContentReadTests|DuplicateFileScannerTests|DuplicateSelectedLocationsTests|ExternalMigrationReceiptTests|FileContentReadGuardTests|FileContentReadIsolationTests|GuardedFileCopyMetadataTests|GuardedMigrationReadTests|HeavyWorkIntegrationTests|MigrationVerificationReuseTests|RecordedTrashRecoveryTests|SimilarImagePreviewCacheTests|SystemUtilitySafetyTests|TestPreferenceHygieneTests|UIConsistencyRegressionTests' > /Users/developer/Developer/.sc-build/r2-icloud-reads/logs/fix4-targeted.log 2>&1
git diff --check
```

记录各命令 exit code、实际方法数／跳过／失败、宿主压缩前提及日志；门禁仍由主会话按 RULES 用私有 verify root、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0` 执行。修复结果经编译、定向、反证和不同模型复核之后，主会话才运行提交脚本；本轮没有构建产物需要清理。

- `~/Developer/.sc-build/r2-icloud-reads/prepared-fix4/` 分 **3 组**：`01-copy-error-and-directory-order`（产品）、`02-copy-regressions`（测试）、`03-fix4-handoff`（本节）。包括各组 patch／message、all.patch、manifest.json、commit-prepared.py、static-checks.json、生成脚本、19 类清单、诊断及 JEV 状态。提交尾行严格为 `Generated-By: Codex (gpt-6.1-sol)` 与 `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`。
- **PASS（静态）**：差异空白、全补丁及各组反向适用、对未变索引的正向适用检查、HEAD／分支／索引为空、3 个最终文件及产物 SHA-256 回读、交接仅追加、ScanStore／其他本批文件／首轮 CSV 未改、19 类清单与原清单字节一致、原测试名／压缩产品断言与阈值保留、唯一授权 Skip 原因。具体命令与退出状态在 static-checks.json；这些检查不执行 Swift 产品或测试。
- **剩余 NOT RUN**：最终 Swift 6 编译／19 类测试／反证／独立复核；能构造时的透明压缩实验、APFS／HFS+ 元数据对照、真实 exFAT／FAT32 ACL 能力和慢盘验签／界面验收。若严格错误传播显露其他真实失败，回交本会话修产品，不吞错、不改阈值；若修正最终文件，须重新生成补丁与全部哈希。

## 主会话验证（fix3＋fix4，HEAD `00d95c1`，2026-10-08 凌晨）

- fix3（GPT-6 Astra，5 组）提交为 `fe920d8` `3d86836` `5225472` `ac62389` `1bc0e64`；主会话编译修正 `4ba44c6`（`[statfs](...)` 在表达式里被解析成同名 C 函数的数组，改为 `Array(repeating: statfs(), count:)`）。
- fix3 定向 19 类 481 项：4 个测试 8 处断言失败，全在 `GuardedFileCopyMetadataTests`。根因：copyfile 回调在 `COPYFILE_ERR` 阶段返回 `COPYFILE_CONTINUE`，错误被吞，复制不完整也报成功；`aclText` 把“没有 ACL”（ENOENT）当成 EIO；压缩夹具用同卷 `ditto --hfsCompression` 构造，同卷只克隆不压缩。
- fix4（gpt-6.1-sol，3 组）提交为 `f003219` `ac718e9` `00d95c1`：错误阶段保存真实 errno 并 QUIT，根目标已存在提前 EEXIST，按预检树逐项系统复制、目录元数据在子项完成后恢复；压缩测试在宿主造不出夹具时 `XCTSkip` 并写明原因。
- 主会话：编译一次通过；19 类 486 项，跳过 2（压缩前提、Setapp 实机开关），0 失败，无残留夹具（`logs/main-test-7.log`）。
- 独立复核第二轮（Claude，`review/review-2.md`）：**可合并**，无 P0／P1；review-1 的 3 个 P1 已修好，9 个 P2 修好 8 个。证据包括四种文件系统（APFS、HFS+、exFAT、FAT32）元数据对照、生产 `migrate()` 端到端、1.2 GB／3007 目录及 3 万小文件包的耗时对比（与旧递归版同量级）、取消 9 ms 返回、超时 0.502 s、按卷槽位隔离实测，以及 13 组反证（9 组变红，4 组无测试捕获，列为后续）。压缩：跨卷 `ditto --hfsCompression` 可造夹具，新复制器在 APFS／HFS+ 上保留压缩（56 块）。
- 留作后续批（不阻塞合并）：A 只读（0555）应用包根目录发布改名 EACCES（既有）；B exFAT／FAT32 改名丢隐藏标志（系统行为）；C 跨卷创建时间变成修改时间；D 几处错误原因不准（目标侧 ENOENT、EDEADLK、写入停顿说成读取超时）；E 测试缺口（4 组未捕获的反证；压缩测试改用跨卷或 `/usr/share/dict/web2` 作源）；F 发布后重绑定摘要不看 ctime 的毫秒窗口；G 带 “everyone deny delete” ACL 的文件发布失败且暂存删不掉。批外：迁移完成前没有 `F_FULLFSYNC`。
- NOT RUN：真实 iCloud 占位（规则禁止，只用替身反证）、慢盘大包验签、界面实机显示。
