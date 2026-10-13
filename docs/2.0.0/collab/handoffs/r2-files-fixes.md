# 批次 r2-files-fixes：文件功能缺陷 N17、N18、N23 与文件分析性能 N21

- 分支 `task/r2-files-fixes`，基于 `23bd624`；worktree `~/Developer/sc-worktrees/r2-files-fixes`；scratch `~/Developer/.sc-build/r2-files-fixes/`（`debug/`、`strict/`、`release-base/`、`release-new/`，日志在 `logs/`）。依赖复制进各 scratch（checkouts、repositories、artifacts，workspace-state.json 改写路径），`swift` 命令都带 `--skip-update --disable-automatic-resolution`。
- 实现：Claude 子代理（Claude Opus 5.5）。来源：BOARD N17、N18、N21，主会话追加 N23；《功能实测报告-20261007》。
- 提交：`88f1240`（N17）、`389d072`（N18）、`b0397fa`（N23）、`aae1173`（N21），交接 `782020a`。复核（“修后可合并”：1 个 P1、9 个 P2）后：`a319151`（P1-1、P2-3）、`bc82850`（P2-2、P2-7）、`2a97d32`（P2-5、P2-6）、`b275faa`（P2-1）、`778ee6d`（P2-8），之后是本交接的 docs 提交；没有变基。复核后的改动集中在第 9 节，前文受影响的说法已在原位改正。
- 没有修改 `Stores/ScanStore.swift`。没有安装、打包、启动应用，没有截屏实机；没有在真实文件上清理、移动、恢复；没有在真实 `~/Library/Preferences` 里删除文件（本批早期测试误建了 9 个空 plist，见 3.5）。

## 结论

| # | 项 | 结果 | 状态 |
|---|---|---|---|
| N17 | 重复文件／相似照片不能只扫所选位置 | 新范围“仅所选位置”（只扫添加的文件夹和外接卷，没有添加位置时不可选并说明原因）；“用户文件”“用户数据区”先扫添加的位置、单独配额，默认位置保留原配额；相似照片与重复文件是同一 store，同一设置路径；2c 的 `SF_DATALESS` 跳过规则保留 | PASS（夹具单测、红绿、两组反证）；实机 NOT RUN |
| N18 | 文件搬家：原件移到废纸篓不写回执 | 原件改走 `RecordedTrashOperation`，写入统一回执日志（规则 `migration.original.v1`），“操作记录”可恢复：放回原处、外接盘副本保留、原处被占用时按现有规则跳过不覆盖（两份都在）；没有持久意图就不移动；暂存回执改为“文件搬家 · 复制用的临时文件／已自动清理，无需处理”，不再给“恢复”和“已移走 0”；恢复横幅只显示本次打开页面后的结果；已搬走的行显示新位置，原件被放回或原处换了文件后改为提示重新扫描（P2-7）；回执默认写正式日志，夹具必须指定隔离日志（P2-2） | PASS（夹具单测、红绿、反证）；实机 NOT RUN |
| N23 | Sparkle 探测在 `~/Library/Preferences` 留空 plist | 根因：每次探测用新域名，清空域不会删文件。修复：设置域改为探测临时目录里的绝对路径，随目录删除；影子宿主关掉签名失败宽限期，Sparkle 不再往本应用偏好写 `SUInitialFailedFeedSigningValidationDate_<宿主ID>`（P2-3）；应用不删除偏好目录里的任何文件（复核 P1-1 删掉了原来的残留清理，并加源码契约），历史残留按 D48 由主会话移到废纸篓；测试不再碰真实偏好目录 | PASS（隔离目录单测、红绿、反证）；本机残留未动，按 D48 由主会话处理 |
| N21 | 文件分析性能 | 先测量：修前热点是每项都问 File Provider（Debug 走树 58%）、每项重算父路径（14.5%）；改到一半的 Release 采样又发现每项描述卷标识（1 线程约 10%）和新加的位置判断用字符搜索（约 21%）。行为不变的改法：只在可能是云端项的地方问、父路径直接复用、卷描述按相等复用、位置判断改字节搜索、子文件夹多线程走并按序合并（工作线程起不来时由调用线程自己走，P2-8）。Release 合成树 208,551 项 25.05 s → 2.51 s（10.0×），625,651 项 75.3 s → 8.0 s（9.4×）；分析后常驻每项 177 → 188～192 B（+6～8%）；修前与各模式索引摘要完全相同 | PASS（等价测试、跨版本摘要、两组反证）；真实 iCloud 树 NOT RUN（不碰真实数据），离开页面释放索引等改变行为的取舍只给数字（4.6） |

## 1. N17 重复文件、相似照片只扫所选位置（`88f1240`）

### 1.1 现象与根因

`DuplicateFileScanner.Configuration.userFiles` 把添加的位置接在 6 个默认目录之后（`mergedRoots(defaultUserRoots + customRoots + externalVolumeRoots)`），共用 8,000 文件／900 目录／10 秒的配额，广度优先发现时默认目录先把配额用完，添加的位置可能一项都没扫到；添加的文件夹如果在默认目录里面，还会被嵌套去重合并掉，没有单独计数。“用户数据区”（`wholeComputer`）同样是添加位置排在后面。相似照片页与重复文件页是同一个 `DuplicateFilesView`／`DuplicateFilesStore`（`resultFilter == .similarImage`），范围与添加位置共用一套设置，所以两页同一个问题。

### 1.2 改动

- 新范围 `DuplicateFileScanScope.selectedLocations`“仅所选位置／Selected Only”：只扫添加的文件夹和外接卷，深度与配额同“用户文件”（8,000／900／10 秒，深度 5）；说明文案写明默认位置不在范围、隐藏文件跳过。
- 没有添加位置时：范围按钮和菜单项不可选，按钮旁、悬停帮助和 VoiceOver 提示都给原因“‘仅所选位置’需要先添加文件夹或外接卷。”；已选中“仅所选位置”后删掉最后一个位置，范围保持不变但“扫描”不可用并显示同一原因（不会悄悄改扫默认目录）。
- “用户文件”“用户数据区”：添加的位置排在最前，作为第一轮单独发现，配额与该范围相同（用户文件 8,000／900／10 秒；用户数据区 250,000／30,000／30 秒）；默认位置第二轮，保留原配额。默认目录里面的添加位置只在第一轮扫一次，第二轮跳过它。每轮有自己的截止时间；第一轮没用完的时间留给确认重复。续扫记录每轮各自的位置（单轮的续扫索引格式不变）。
- 结果超过上限要截断时，添加位置下的重复组和候选优先保留（按规则逐轮稳定分区）。更正（复核 P2-4）：原写“排在前面”只对截断成立；结果页按“可审阅空间／单个大小／名称”重新排序，显示时不保证在前。界面不改。
- 覆盖说明里添加的位置标“你添加的位置 · 先扫描、单独计数”，只在扫描有先扫添加位置的那一轮时才标；“仅所选位置”只扫一轮，不标（复核 P2-5，`2a97d32`）。初始页范围按钮在窄宽度下由横排改竖排（`ViewThatFits`，不用 `.minimumScaleFactor`，遵守 `UIConsistencyRegressionTests` 的字体规则）。
- 发现阶段仍按 `SF_DATALESS` 跳过云端占位文件（2c 规则未动）。

### 1.3 行为变化（请主会话知悉）

- 有添加位置时，“用户文件”发现阶段最长 20 秒（两轮各 10 秒），“用户数据区”最长 60 秒；没有添加位置时与原来相同。
- 配置变了（根顺序与 `selectedRootsPass`），升级后带添加位置的旧扫描结果不会自动恢复，需要重新扫描；没有添加位置的配置不受影响。
- 改了 4 个锁定旧行为的测试（`DuplicateFileScannerTests`：根顺序、范围列表含 `selectedLocations`、用户数据区根顺序、`selectedRootsPass` 计数），依据是 N17 本身（BOARD 已批准的修法），DECISIONS 里没有锁定旧顺序的决定。

### 1.4 测试、红绿与反证

新测试 `DuplicateSelectedLocationsTests`（交接时 9 个，复核后 11 个），扫描根都是临时夹具。更正（复核 P2-6）：原写“全部只用临时夹具”不对，`DuplicateFilesStore` 每次开始扫描都读取真实续扫索引 `~/Library/Application Support/StorageCleanerMac/DuplicateFiles/resume-index.json`，保存、清除也指向它；`2a97d32` 起续扫索引像结果存储一样注入，测试用临时目录。`ScanRecorder(allowedRoot:)` 遇到夹具外的根直接拒绝，保证“仅所选位置”从不触碰默认目录；偏好用临时目录里的绝对路径域，不写真实偏好目录。

- 红（实现前桩）：8 个执行，33 处失败（预期），`logs/n17-red.log`。
- 绿：相关 76 个，0 失败（`n17-green.log`）；扩大到重复文件、相似照片、UI 规则相关 396 个，1 个原有跳过，0 失败（`n17-green-related.log`）。
- 反证 A（改回单轮、不按添加位置排序）：4 个测试 11 处失败，已还原（`n17-mutation-a.log`）。
- 反证 B（“仅所选位置”混入默认目录、去掉无位置拦截）：3 个测试 16 处失败，已还原（`n17-mutation-b.log`）。
- 离屏渲染（临时测试，已删）：中英文 × 深浅色 × 700×560／820×600／1080×720，无位置、仅所选位置、删光位置三种状态，范围按钮、原因提示、禁用的扫描按钮都正常，图在 scratch `n17-snapshots/`。另看到 820×600 时右上插画与容量环重叠，与本批无关，未改。

## 2. N18 文件搬家原件移到废纸篓写回执（`389d072`）

### 2.1 现象与根因

`ExternalDriveMigrationService.moveOriginalToTrash` 直接调用 `FileManager.trashItem`，不经回执日志，“操作记录”里没有这一步，无法恢复；记录里唯一一条是复制时 `.partial` 暂存目录的回执（规则 `migration.staging.v1`），标题“迁移临时资源”、数字“已移走 0 · 已保留 1”，容易误解。操作记录页的恢复横幅读的是 store 里上一次恢复结果，换页回来仍显示。搬家结果存在视图 `@State` 里，换页后行又显示原路径。

### 2.2 改动

- 原件移废纸篓改走 `RecordedTrashOperation.run`（与清理、卸载同一回执日志 `CleanupReportJournal`）：先持久写意图，再移动，移动后核对身份写回执；规则 `migration.original.v1`，`allowedRestoreRoot` 为原件所在目录。移动前再核对外接盘副本存在、原件身份与大小／修改时间未变，不符则拒绝（记录为拒绝，没有可恢复回执）。
- 意图写不进日志就不移动，抛出新错误“无法写入操作记录；为了能从‘操作记录’恢复，原件没有移动。”
- 恢复走现有 `CleanupRecoveryService.restore` 记录恢复路径：从废纸篓放回原处，外接盘副本不动；原处已有同名文件时跳过、不覆盖，两份都保留（现有规则）。
- 操作记录（`OperationRecordPresentation`，新文件）：搬家记录标题“文件搬家 · <文件名>”；暂存记录标题“文件搬家 · 复制用的临时文件”，状态“已自动清理，无需处理”（或“未能自动清理，需要核实”），不显示“恢复”和“原操作移走”；跑分测试资源同样按临时资源显示。横幅只显示打开页面之后产生的恢复结果。
- 文件分析／大文件页：搬家结果移到 `LargeFilesStore.migrationCompletions`，换页后保留，下一次扫描成功后清空；已搬走的行显示新位置（“已搬到 <卷名>”），“在访达中显示”打开副本。复核 P2-7（`bc82850`）：搬家结果带上原件身份，页面出现时再看原处——同一个文件被放回（从“操作记录”恢复）显示“已恢复到原处，请重新扫描”，原处换成别的文件显示“原处已有其他文件，请重新扫描”；这两种情况“在访达中显示”打开原处，标记改为“已复制”。
- 回执日志（复核 P2-2，`bc82850`）：`moveOriginalToTrash` 默认写正式回执日志；调用方可以指定日志（新参数 `journal:`）或持久化方式。注入 `trustedVolumes`（只有夹具会注入）时必须指定其一，否则不移动（`receiptUnavailable`）。原来注入卷会让默认持久化悄悄变成空操作，把生产默认改成空操作测试也照样通过。

### 2.3 测试、红绿与反证

新测试 `ExternalMigrationReceiptTests`（交接时 8 个，复核后 11 个，走默认回执路径、用隔离日志）：夹具在家目录下的临时文件夹 `~/.storage-cleaner-migration-receipt-test-<uuid>`（迁移服务要求源在家目录内；回执日志拒绝含符号链接成分的路径，所以不能放 `/var/folders`），独立回执日志、夹具废纸篓，结束删除。

- 红：8 个执行，33 处失败（2 处为未预期抛错，预期），`n18-red.log`。
- 绿：相关 338 个，1 个原有跳过，0 失败（`n18-green.log`）。
- 反证（不持久化、横幅不按本次、行显示原路径）：6 个测试 10 处失败，已还原（`n18-mutation.log`）。

## 3. N23 Sparkle 探测残留空 plist（`b0397fa`）

### 3.1 根因（两侧都有）

- 产品：只读探测每次用新域名 `com.storagecleanermac.sparkle-probe.<uuid>` 作 `SUDefaultsDomain`，Sparkle 用 `NSUserDefaults(suiteName:)` 写设置；结束时 `removePersistentDomain` 只清空域，cfprefsd 留下 42 字节的空 plist。
- 测试：`SparkleReadOnlyProbeTests` 在同样的真实域里写 `SULastCheckTime`，还写 `com.example.sparkle`。本机那个 73 字节、内容为 2027-01-15 检查时间的残留就是测试写的。

### 3.2 修复

`SUDefaultsDomain` 改为探测临时目录里的绝对路径（`<probe root>/SparkleDefaults`），设置文件落在临时目录里；结束时先 `CFPreferencesAppSynchronize` 再删除整个目录。Sparkle 若在删除后迟写，最多重建那个临时目录，不会在偏好目录生成文件。创建失败时不再调用 `removePersistentDomain`。

复核 P2-3（`a319151`）：签名校验失败时，Sparkle 的宽限期逻辑会把首次失败时间写进本应用的 standard defaults（`~/Library/Preferences` 里本应用的 plist），键名带每次新建的宿主 ID：`SUInitialFailedFeedSigningValidationDate_<宿主ID>`。每次探测本来就重新计数，宽限期从未生效；影子宿主现在固定 `SUSignedFeedFailureExpirationInterval = 0`（目标应用设了别的值也覆盖），Sparkle 不再写这个键。更正：`b0397fa` 的代码注释写“Probes no longer write there”，在 P2-3 之前不成立；该注释已随残留清理代码一起删除。

### 3.3 历史残留清理（已删除，复核 P1-1）

交接时的 `SparkleProbePreferenceLeftovers` 会在每次启动第一次真实更新检查时，自动永久删除偏好目录里的探测残留。这与 D48（由主会话移到废纸篓、不永久删除）和 AGENTS.md（清理是界面上的显式操作，优先移到废纸篓）冲突，列目录也占在 12 秒的探测超时里（3.5）。`a319151` 删除了这段代码、真实会话里的调用和只为它写的测试，保留根因修复（3.2），并加源码契约 `PreferencesFolderContractTests`：应用源码里凡提到偏好目录的文件，不得调用 `unlink`、`unlinkat`、`removefile`、`rmdir` 或 `removeItem`（忽略注释；移到废纸篓允许）。历史残留按 D48 由主会话处理。

### 3.4 测试隔离（N13 卫生）

- 测试只在临时目录或探测目录里读写：记录器只在设置域位于探测目录内时才写；原来写真实域的“目标偏好不变”哨兵改为断言设置域在探测目录内、探测后目录已删除、真实偏好目录没有对应文件（只读检查）。
- 新测试：设置不进真实偏好目录。交接时另有残留清理的测试（只删空的合规文件、上限与下次继续、只有真实会话清理），已随清理代码删除（3.3）；现在 `SparkleReadOnlyProbeTests` 15 个，另有 `PreferencesFolderContractTests` 2 个。
- 交接时的红绿与反证：红：清理相关 2 个测试 9 处失败（`n23-red.log`；红阶段没有运行旧的探测代码，避免它写真实偏好）。绿：17 个，0 失败（`n23-green.log`）。反证（设置域放回探测目录外、去掉空字典检查、去掉会话里的清理调用）：6 个测试 15 处失败，已还原；反证期间真实目录的探测文件数没有变化（`n23-mutation.log`）。

### 3.5 交给主会话决定（子代理不动）

- 本机 `~/Library/Preferences` 里的探测残留现在是 **6,189** 个（交接时 6,184；10-07 09:50:53 同一秒多了 5 个，时间上不是本批的测试——本批那次运行没有包含 Sparkle 测试，像是其他 worktree 用旧代码跑了全量测试，N23 合并后会停止）。其中 6,188 个是空字典，1 个 73 字节非空（测试写的）。应用不会删除它们（3.3），按 D48 由主会话移到废纸篓。复核后再数是 6,199 个（13:11）：新增的 10 个是 11:39:53、11:54:03 各 5 个，与旧代码的 Sparkle 测试每跑一次建 5 个相符；本批这两个时刻没有运行测试，本批代码也不再写这里，像是不含 N23 的分支跑了全量测试。
- 本批 N17 早期测试（08:49–08:57）在真实偏好目录误建了 9 个 `DuplicateSelectedLocationsTests-<UUID>.plist`（各 42 字节），测试随后改为临时目录里的绝对路径域。按规则子代理不删，请主会话处理。
- N13／N24 后续（未做，归 D48 的 `r2-test-hygiene` 批次）：偏好目录里约 22 万个文件是各测试类按 `<前缀><UUID>` 建的套件（最多的是 `MenuBarPanelSessionTests.`、`CleanupHistoryServiceTests-`、`FanControlPlannerTests.`）；测试代码里有 111 处 `UserDefaults(suiteName:`，分布在 44 个测试文件。
- 列目录耗时（更正）：原写“列出真实偏好目录要约 1.9 秒”，那是用 Python `os.listdir` 只取名字测的一次；原来的清理用 `FileManager.contentsOfDirectory`，复核实测 5.6–12.3 秒，而且算在 12 秒的探测超时里。清理已删除（3.3），应用不再列这个目录。

## 4. N21 文件分析性能（`aae1173`）

### 4.1 测量方法

- 合成树：`StorageMapAnalysisPerformanceTests`（默认跳过，`STORAGE_CLEANER_N21_PERF=1` 才运行）在 scratch 里建一次 50 个顶层文件夹 × 10 × 8 × 50 个文件的树，共 208,551 项：202,001 个文件（多数为空，每 10 个有 1 个 2–4 KB，名字长短与真实目录相近）、6,050 个文件夹（含 500 个应用包）、500 对硬链接、500 个符号链接。像个人目录但不碰真实数据；树在家目录下的 scratch 里，不在 iCloud、桌面、文稿位置。
- 每次 `xctest` 新进程：第 0 次分析前后取进程 `phys_footprint` 和峰值（`ledger_phys_footprint_peak`），得到常驻与峰值的每项字节；之后计时若干次。另按索引内容估算纯数据大小（每项字节）。每次分析后对索引算 SHA-256 摘要（目录、子项按原顺序、阻塞集、硬链接重复集、根大小），修前修后与各模式必须相同。
- 修前用 `23bd624` 源码导出到 scratch 编译（同一测试程序，只去掉选项参数），与新代码交替运行，记录当时 1 分钟负载。机器同时有其他会话在编译和测试，负载很高，数字只作同一时段的相对比较。

### 4.2 修前热点（Debug，`sample`，`logs/n21-baseline-sample.txt`）

走树线程共 2,538 个样本：

| 位置 | 样本 | 占比 | 说明 |
|---|---|---|---|
| 每项 `URL.resourceValues(forKeys:)` | 1,481 | 58% | 其中 `FPURLMightBeInFileProvider` 1,113（44%）：为了 `isUbiquitousItem`／下载状态，每一项都问 File Provider，本地文件也问 |
| `storageMapParentPath` | 368 | 14.5% | 每项从完整路径重新拆出父路径，而枚举时父路径已知 |
| 硬链接判断的 `lstat` | 117 | 4.6% | 每个普通文件一次 |
| 其余 | — | — | 枚举（`getattrlistbulk`）、建条目、字典 |

实机报告的 433 万项 2,202.5 秒、主要耗在 iCloud 云盘，原因同属第一行：iCloud 里每一项的 File Provider 查询要走进程间通信，比本地文件慢得多；整棵树只用一个线程。

### 4.3 改动（行为不变）

1. **只在可能是云端项的地方问 File Provider**（`StorageMapAnalysisOptions.UbiquityLookup.whereNeeded`）：文件夹一律问（云端文件夹不下钻的判断照旧）；符号链接不问（原来也不用）；文件只在以下情况问：所在文件夹被报告为云端项、`lstat` 显示 `SF_DATALESS`、路径在任意用户的 `Library/Mobile Documents/` 或 `Library/CloudStorage/` 下、或在当前用户的“桌面”“文稿”下（iCloud 桌面与文稿）。其余文件按 macOS 现有的 File Provider 位置不会是云端项，按“非云端”处理，与原来逐项询问的答案相同。更正：原写“不可能是云端项”说过头了，理论上的例外见 4.5“理论上的残余差别”。`lstat` 结果同时用于硬链接判断，不多调一次。
2. **父路径直接用枚举时拼出的那个**（`storageMapEnumeratedPathAndParent`），不再从完整路径拆；Debug 下留 `assert` 核对与 `storageMapParentPath` 一致。
3. **卷标识描述按相等复用、云位置用字节搜索**：同一卷的每一项都带一个新的、字节相同的卷标识对象，原来每项都 `String(describing:)` 一次再比较；现在与上一个相等就复用它的描述（相等的对象描述相同，比较结果不变）。云位置的“包含”判断改为在路径的 UTF-8 里按字节找（`memmem`），对 ASCII 片段，字符搜索能找到的它都找到，只会多问、不会少问；桌面、文稿前缀每次分析只拼一次。
4. **多线程走子文件夹，按顺序合并**：调用线程走根这一层，把每个顶层文件夹交给工作线程（默认 `min(4, 活跃核数/2)`，QoS utility，与调用方相同）；工作线程空闲时，正在走的子树再把自己的下一层交出去。每个子树有独立状态，调用线程按交出顺序合并（文件夹条目总在它的父子树之后合并，自底向上汇总的前提不变），硬链接按“单线程走树的先后位置”排序后再按原规则选规范路径。进度经一把锁汇总：回调不会同时被调用、数字只增不减，硬链接文件跨子树只计一次（与单线程一致）。取消：任一线程看到取消就全部停下，调用线程每 50 ms 查一次任务取消。复核 P2-8（`778ee6d`）：合并时调用线程等了 50 ms，它要合并的那个子文件夹仍没有工作线程领走（只会在没有工作线程在领任务时发生），就自己走；合并中看到任务取消立即结束；结束时只等已经启动的工作线程，之后才启动的直接返回。工作线程经 `StorageMapAnalysisOptions.startWorker` 启动（应用照旧交给全局队列）。
5. `StorageMapAnalysisOptions.reference`（单线程、逐项询问）保留原走法，供测试对照；应用只用 `.standard`。
6. 复核 P2-1（`b275faa`）：云端状态的来源可注入（`StorageMapAnalysisOptions.cloudState`）：应用用 File Provider（不变），测试用替身，替身在走树原本问 File Provider 的每一处被问（包括根），所以可以把任意文件夹当作云端文件夹来测父目录状态的传递。

### 4.4 修前修后数字

Release，`xctest` 每个配置一个新进程、交替轮换；第 0 次分析取内存，之后计时。“常驻”是第 0 次分析后、仍持有结果时的 `phys_footprint` 增量；峰值与常驻相同（最高点就在分析结束时）。

合成树 208,551 项（3 轮 × 每进程 2 次计时，共 6 次；1 分钟负载 8～11；`logs/n21-ab-release-2.log`）：

| 配置 | 中位用时 | 范围 | 相对修前 | 每秒项数 | 常驻／峰值（每项） | 索引摘要 |
|---|---|---|---|---|---|---|
| 修前 `23bd624` | 25.05 s | 23.5～34.6 s | 1× | 8,345 | 177 B／177 B | `53796262…` |
| 修后默认（4 线程、按需询问） | 2.51 s | 1.7～2.7 s | 10.0× | 83,174 | 192 B／192 B | 相同 |
| 修后 2 线程 | 3.52 s | 2.5～4.2 s | 7.1× | 59,256 | 188 B／188 B | 相同 |
| 修后 1 线程、按需询问 | 5.14 s | 4.6～6.4 s | 4.9× | 40,596 | 180 B／180 B | 相同 |
| 对照模式（1 线程、逐项询问，只给测试用） | 25.24 s | 22.0～31.9 s | 1.0× | 8,262 | 178 B／178 B | 相同 |

合成树 625,651 项（2 轮 × 每进程 1 次计时；负载 7～14；`logs/n21-ab-release-600k.log`）：

| 配置 | 中位用时 | 范围 | 相对修前 | 常驻增量（两轮） | 每项 | 索引摘要 |
|---|---|---|---|---|---|---|
| 修前 | 75.3 s | 60.1～90.4 s | 1× | 105.6／106.0 MB | 177 B | `bf159eff…` |
| 修后默认 | 8.0 s | 7.5～8.4 s | 9.4× | 112.1／113.3 MB | 188 B | 相同 |
| 修后 2 线程 | 11.7 s | 10.6～12.8 s | 6.4× | 110.5／110.7 MB | 185 B | 相同 |
| 修后 1 线程 | 24.5 s | 21.7～27.3 s | 3.1× | 105.9／106.2 MB | 177 B | 相同 |

- 多线程多占的内存大致是约 1 MB 固定量加每项约 10 字节（208,551 项多 2.9 MB，625,651 项多 6.5～7.3 MB），来自各线程各自的分配区；按 10-07 实测的 433 万项推算，默认设置多约 40 MB（实测常驻增量 1.26 GB 的约 3%）。不想要这部分可把 `StorageMapAnalysisOptions.standard` 改成 2 线程或 1 线程（一行），速度见上表。
- 中间版本（还没改卷描述和字符搜索，负载 12～23，`logs/n21-ab-release-1.log`）：默认 3.89 s、1 线程按需 11.09 s、修前 29.64 s；那次 Release 采样（`logs/n21-profile-onewhere.txt`）显示 1 线程时字符搜索占 21%、卷描述占 10%，于是有了 4.3 第 3 条。
- 修后剩余热点（1 线程，`logs/n21-profile-v2-onewhere.txt`，按每项处理时间）：判断硬链接与 `SF_DATALESS` 的 `lstat` 约 37%（修前也有，只是占比变大），取预读属性约 15%，文件夹的 File Provider 询问约 7%，扩展名、文件名、路径检查各约 4～6%。
- 合成树都是本地文件，没有 iCloud 项。真实个人目录里 iCloud 云盘、桌面与文稿下的文件仍逐个询问（行为不变的前提），那部分只能靠多线程加速，能快多少要实机测（第 6 节）。

### 4.5 行为不变的证据

- 跨版本摘要：同一棵合成树，`23bd624` 与修后每种模式（默认、1／2 线程、对照）每次分析的 SHA-256 摘要都相同：208,551 项 45 次全是 `53796262…`，625,651 项 16 次全是 `bf159eff…`。摘要覆盖所有目录的大小、子项数、后代数、是否完整、内容分类，每个目录的子项按原顺序（名字、类型、大小、可否下钻、是否估算），阻塞集、硬链接重复集、根大小、检查数与略过数。
- `StorageMapAnalysisEquivalenceTests`（交接时 6 个，Debug 与 Release 都通过；复核后 9 个，见 9.1）：混合树逐项钉住索引（硬链接、应用包、符号链接、排除目录、无权限目录、隐藏与零字节文件；这个测试在 `23bd624` 上同样通过）；混合树与多层嵌套树（硬链接跨子文件夹）上各模式与对照模式的索引、根快照、检查数、略过数全等；取消后 2 秒内抛 `CancellationError`；云端询问判断与字节搜索的各类路径（含中文路径、组合字符）；走树先后顺序；进度只增不减、回调从不并发、硬链接文件只计一次。
- 反证 A（合并时不累加子树根的直接子项数）：2 个测试 17 处失败（`logs/n21-mutation-a.log`）。反证 B（去掉 `SF_DATALESS` 条件，进度回调放回锁外、硬链接按各子树计）：2 个测试 4 处失败——计数倒退、29 次并发回调、运行中字节 462,848 对 458,752（一个 4 KiB 硬链接文件被算两次）（`logs/n21-mutation-b.log`）。都已还原并逐字节核对。
- 理论上的残余差别：某个文件既不是 dataless、所在文件夹不是云端项、也不在上述四类位置，File Provider 却报告它是云端项且不是最新——原来会标“估算”，现在不会；只影响这个标记，不影响大小。macOS 上的 File Provider 位置都在 iCloud 云盘、`Library/CloudStorage`、桌面与文稿之内，所以只在将来出现新位置时才可能发生。
- 与原来不同但不改结果的地方：分析期间最多 5 个线程同时读目录（QoS 都是 utility）；进度里的“当前路径”来自正在汇报的那个线程。

### 4.6 改变行为的取舍（只给数字和建议，由用户决定）

| 方案 | 数字 | 代价 | 建议 |
|---|---|---|---|
| 离开文件分析页后释放索引（或离开若干分钟后、内存压力时释放） | 索引常驻每项约 177～192 B（合成树）；10-07 实测 433 万项常驻增量 1.26 GB（每项约 290 B） | 回到页面要重新分析：本地文件按上表每秒 4～8 万项，iCloud 多的树仍要几分钟以上 | 先做“离开 N 分钟后或系统内存压力时释放、回来时提示重新分析”，N 由用户定 |
| iCloud 等位置的文件改用 `lstat` 的 `SF_DATALESS` 判断，不再逐个问 File Provider | 合成树没有 iCloud 项，测不出；实机 433 万项的 2,202.5 s 主要耗在这里 | 已下载但不是最新版本的文件不再标“估算”（大小不变） | 先请主会话用新版实测个人目录，看剩余时间是否仍主要在 iCloud，再决定 |
| 走树线程关闭 dataless 物化（`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`） | 未测（需要真实云盘） | 没被标成云端但内容不在本机的文件夹，会显示为读不到，而不是被下载列出 | 建议做：保证分析从不触发下载；与上一条一起实测 |
| 压缩索引的存储（名字集中存放、条目定长） | 纯数据估算每项 123 B，实际常驻 177 B | 不改行为，但改动面大，要单独批次和测试 | 可排入后续批次 |
| 用一次批量属性调用取硬链接数、inode、标志，省掉每个文件一次 `lstat` | `lstat` 占修后 1 线程处理时间约 37% | 不改行为，但要替换 `FileManager` 枚举器，风险较高 | 暂不做 |
| 限制分析深度 | — | 会改变目录大小与完整性 | 不建议 |

## 5. 命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`、`LC_ALL=en_US.UTF-8`；`swift` 命令都带 `--scratch-path ~/Developer/.sc-build/r2-files-fixes/<debug|strict|release-base|release-new> --jobs 3～6 --skip-update --disable-automatic-resolution`；日志在 `~/Developer/.sc-build/r2-files-fixes/logs/`。

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| 基线构建（改动前，含测试） | `swift build --build-tests` | 0 | — | `baseline-build.log` |
| N17 红 | `swift test --filter DuplicateSelectedLocationsTests`（实现前桩） | 1 | 8 个执行，8 个失败、33 处（预期） | `n17-red.log` |
| N17 绿 | `--filter` DuplicateSelectedLocations、DuplicateFileScanner、ItemListAndDuplicatePresentation、CleanupExecutionSafety | 0 | 76 个，0 失败 | `n17-green.log` |
| N17 相关 | 再加 UIConsistencyRegression、ConceptLandingNativeLayoutRegression、SafeCleanupLayout、IndependentFeatureWorkspaceStore、HeavyWorkIntegration、SystemUtilitySafety | 0 | 396 个，1 个原有跳过，0 失败 | `n17-green-related.log` |
| N17 反证 A／B | 见 1.4 | 1／1 | 4 个测试 11 处／3 个测试 16 处失败，已还原 | `n17-mutation-a.log`、`n17-mutation-b.log` |
| N18 红 | `--filter ExternalMigrationReceiptTests` | 1 | 8 个执行，8 个失败、33 处（2 处未预期抛错） | `n18-red.log` |
| N18 绿 | ExternalMigrationReceipt、RecordedCleanupRecovery、RecordedTrashRecovery、CleanupReceiptHistory、CleanupJournalEvent、OperationRecordLabel、UninstallStoreWiring、SystemUtilitySafety、IndependentFeatureWorkspaceStore、StorageTreemapLayout、UIConsistencyRegression、ConceptLandingNativeLayoutRegression | 0 | 338 个，1 个原有跳过，0 失败 | `n18-green.log` |
| N18 反证 | 见 2.3 | 1 | 6 个测试 10 处失败（1 处未预期），已还原 | `n18-mutation.log` |
| N23 红 | 残留清理的 2 个新测试 | 1 | 2 个失败、9 处（预期） | `n23-red.log` |
| N23 绿 | `--filter SparkleReadOnlyProbeTests` | 0 | 17 个，0 失败，0.1 秒 | `n23-green.log` |
| N23 反证 | 见 3.4 | 1 | 6 个测试 15 处失败，已还原；真实目录探测文件数不变 | `n23-mutation.log` |
| N21 修前采样 | Debug 测试程序跑合成树时 `sample` | — | 见 4.2 | `n21-baseline-sample.txt` |
| N21 修前钉住 | 在 `23bd624` 源码上跑 `testMixedTreeIndexIsPinned` 与 `StorageTreemapLayoutTests` | 0 | 26 个，0 失败 | `n21-char-baseline.log` |
| N21 Release 构建 | `swift build -c release --build-tests -Xswiftc -enable-testing`（`23bd624` 导出源码与修后各一份） | 0／0 | 用于 A/B | `n21-release-base-build.log`、`n21-release-new2-build.log` |
| N21 A/B | 交替运行 `StorageMapAnalysisPerformanceTests`（`STORAGE_CLEANER_N21_PERF=1`） | 0 | 见 4.4；摘要全部相同 | `n21-ab-release-1.log`、`n21-ab-release-2.log`、`n21-ab-release-600k.log` |
| N21 Release 等价 | Release 测试包 `-XCTest StorageMapAnalysisEquivalenceTests`（中间版本；最终版本，测试包与 HEAD 一致已核对） | 0／0 | 6 个，0 失败／6 个，0 失败 | `n21-release-equivalence.log`、`n21-release-equivalence-final.log` |
| N21 采样（修后） | Release 1 线程 `sample` | — | 见 4.4 | `n21-profile-v2-onewhere.txt` |
| N21 反证 A／B | 见 4.5 | 1／1 | 2 个测试 17 处／2 个测试 4 处失败，已还原 | `n21-mutation-a.log`、`n21-mutation-b.log` |
| N21 相关 | `--filter` StorageMapAnalysisEquivalence、StorageMapAnalysisPerformance、StorageAnalysisScopeLayout、CodexArtifactScanner、IndependentFeatureWorkspaceStore、SystemUtilitySafety、CompetitiveParityContract、StorageTreemapLayout、ScanMode、ExternalMigrationReceipt | 0 | 292 个，2 个跳过（N21 测量程序默认跳过、原有 Setapp 实机项），0 失败 | `n21-related.log` |
| Debug 全量（`aae1173`） | `swift test` | 0 | 3,469 个执行，22 个跳过，0 失败；测试耗时 193.4 s，总 196 s；负载 6.7～8.8 | `debug-full.log` |
| 严格并发（`aae1173`，新 scratch 全量编译） | `swift build -Xswiftc -strict-concurrency=complete` | 0 | 0 错误、0 编译警告（唯一一条是 `--skip-update` 选项已弃用）；92 s；负载 8.8～11.9 | `strict-concurrency.log` |
| 私有 API | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `guards.log` |
| `verify.sh` 的源码检查 | Views 不启动进程、内存功能不调用 purge、没有冲突副本 | — | 都没有匹配，PASS | `guards.log` |
| 空白检查 | `git diff --check`；`git diff --check 23bd624 HEAD` | 0；0 | — | `guards.log` |

- 22 个跳过：21 个是其他测试类里原有的条件跳过（AppUpdateOfficialSecurity 4、BenchmarkV7RealHardwareCapture 3、CleanupRuleScanner 2，其余 12 类各 1），新增 1 个是 N21 测量程序（不设 `STORAGE_CLEANER_N21_PERF=1` 就跳过）。没有计时项失败，没有放宽阈值。日志里的 CoreData／contactsd 报错出现在原有的 `AppStoreCatalogResolverTests` 附近，不是失败，与本批无关。

NOT RUN（主会话门禁或实机）：Release 全量 `swift test -c release`、`script/verify_menu_bar_performance.sh`、打包、安装、启动应用、实机截图与实机核对（第 6 节）。

## 6. 需要实机核对（主会话，用夹具）

N17（重复文件、相似照片）：

1. 没有添加位置时，“仅所选位置”按钮与菜单项不可选，旁边和悬停帮助给出原因；VoiceOver 读出同一原因。中英文各看一次，窄窗口（约 700 宽）范围按钮改竖排、不截断。
2. 添加一个含重复文件的夹具文件夹，选“仅所选位置”扫描：结果与覆盖说明只涉及该文件夹，没有下载、桌面等默认目录。删掉这个位置：范围保持“仅所选位置”，“扫描”不可用并显示原因；重新添加后可扫描。
3. “用户文件”范围下添加同一夹具：覆盖说明里它标“你添加的位置 · 先扫描、单独计数”；结果超过上限时它的重复组优先保留（页面显示顺序跟随所选排序，不一定在前）。“仅所选位置”扫描后覆盖说明不带这个标记。把夹具移到“下载”里面再扫一次：只扫一次、只计一次。
4. 相似照片页看到同一组范围和添加位置；用夹具图片文件夹选“仅所选位置”扫描。

N18（文件搬家，夹具文件 → 外接盘）：

5. 复制校验后把原件移到废纸篓：“操作记录”出现“文件搬家 · <文件名>”，可以恢复；恢复后原件回到原处，外接盘副本还在。
6. 恢复前在原处放一个同名文件：恢复跳过、不覆盖，两份都在，提示与清理恢复一致。
7. 同一次搬家的暂存记录显示“文件搬家 · 复制用的临时文件”“已自动清理，无需处理”，没有“恢复”、没有“已移走 0”。
8. 恢复后离开操作记录页再回来，恢复横幅不再显示。
9. 大文件列表里已搬走的行显示“已搬到 <卷名>”和新路径，“在访达中显示”打开外接盘上的副本；换页回来仍是新位置；重新扫描后按新结果显示。再从“操作记录”恢复这个原件后回到大文件页：该行显示“已恢复到原处，请重新扫描”，标记“已复制”，“在访达中显示”打开原处。

N23（Sparkle 探测）：

10. 装上含 N23 的测试版后做一次真实更新检查：偏好目录里不再新增 `com.storagecleanermac.sparkle-probe.*.plist`，本应用的偏好里不新增 `SUInitialFailedFeedSigningValidationDate_*`；旧残留数量不变（应用不删，按 D48 由主会话移到废纸篓）。

N21（文件分析）：

11. 用新版分析个人目录，记录用时与分析后常驻内存，对照 10-07（433 万项 2,202.5 秒，常驻增量 1.26 GB）；看剩余时间是否主要在 iCloud 云盘（据此决定 4.6 前三条）。抽查几个文件夹大小、云端占位文件的“估算”标记与修前一致；分析中途取消能马上停；进度数字只增不减。

## 7. 未解决与风险

- N17：有添加位置时发现阶段最长时间翻倍（1.3）；带添加位置的旧结果升级后不恢复。“用户数据区”的添加位置第一轮配额与该范围相同（250,000／30,000／30 秒），如嫌太长可另定。
- N18：回执日志写不进时原件不再移动（新错误提示），这是有意的行为变化；断电、日志损坏等极端情况只在单测里覆盖；回执日志写入没有用 `F_FULLFSYNC`（既有限制，复核 P2-9，见 9.4）。
- N23：应用不清理旧残留（3.3）；本机的探测残留按 D48 由主会话处理，在那之前一直留着。
- N21：默认 4 线程使分析后常驻多约 6～8%（4.4）；只在可能是云端项的地方询问有一个理论上的残余差别，只影响“估算”标记（4.5）；真实 iCloud 树的加速未测；离开页面释放索引等改变行为的取舍未做，等用户决定（4.6）。
- 测试卫生（N13／N24，归 D48 的 `r2-test-hygiene` 批次）：约 22 万个测试建的偏好套件文件、111 处 `UserDefaults(suiteName:` 仍写真实偏好目录（3.5）。
- 改动了锁定旧行为的测试：`DuplicateFileScannerTests` 4 处（N17）；`SparkleReadOnlyProbeTests` 去掉写真实域的“目标偏好不变”哨兵，改为更严格的“设置只在探测目录、真实目录无文件”断言（N23，意图不变）。两处都没有 DECISIONS 条目锁定旧行为；没有删断言放宽阈值、没有新增跳过。复核后：残留清理的测试随代码删除（3.3）；`SystemUtilitySafetyTests` 的搬家夹具改为指定自己的回执日志（P2-2）。
- 离屏截图里看到的 820×600 插画与容量环重叠（1.4）未处理，留给 UI 批次。

## 8. JEV（判断与复核，不是批准）

只提交了非敏感的方案、代码摘录与测试数字。三次复核都是 escalate（需要人工复核），没有一次达到自动通过：

| 调用 | 对象 | 结果 |
|---|---|---|
| `jev_decide` | N21 默认线程数（4／2／1） | 选 4 线程，概率 0.75（2 线程 0.23、1 线程 0.02），置信度 0.69，低于 0.8，只作参考；三项要求（常驻增幅 ≤10%、对 File Provider 延迟最有效、可一行改回）4 线程与 2 线程都满足 |
| `jev_review` | N21 并行合并与按需询问（代码摘录＋测试） | escalate；safe_to_apply 0.41；正确性 1.52／2（置信度 0.28）、需求符合 1.80（0.70）、测试缺口 0.36（0.45）、影响面 1.89（0.83）；综合 0.705 |
| `jev_review` | N23 设置域与残留清理 | escalate；safe_to_apply 0.68；正确性 1.83（0.74）、需求符合 1.97（0.95）、测试缺口 0.36（0.47）、影响面 1.50（0.25）；综合 0.822 |
| `jev_review` | N18 原件移废纸篓写回执 | escalate；safe_to_apply 0.12；正确性 1.06（0.23）、需求符合 1.86（0.78）、测试缺口 1.20（0）、影响面 1.78（0.67）；综合 0.568 |

JEV 只给分数，没有指出具体缺陷。请复核者重点看：N21 的任务队列与按序合并（并发、影响面大）；N18 在注入 `trustedVolumes`（只有夹具测试会注入，与原有暂存回执相同）时持久化为空操作、`moveOutcomeUnknown` 且原件已不在原处时按“已移走、待核实”返回、意图写不进就拒绝移动这三处；N23 直接删除偏好目录里的文件（cfprefsd 不再访问这些随机域名）。N17 本批没有调用 JEV。复核后：N18 注入卷时的空操作持久化已改（P2-2），N23 的删除已去掉（P1-1）。

## 9. 复核后修改（2026-10-07）

复核结论“修后可合并”：没有 P0，1 个 P1、9 个 P2，另有 6 处交接说法与代码不符。集成分支此时已到 `7e4e481`（合入 r2-live-fixes-2、D48–D50），复核用 `git merge-tree` 试合并本分支，没有冲突。本分支没有变基，在原 worktree 上小步提交；每项按 红 → 修 → 绿 → 反证，日志在 `logs/rv-*.log`，反证后都已还原并逐字节核对。

### 9.1 逐项

| 项 | 提交 | 改动 | 红 | 绿 | 反证 |
|---|---|---|---|---|---|
| P1-1（N23）应用内永久删除偏好目录里的探测残留，与 D48、AGENTS.md 冲突 | `a319151` | 删掉 `runSession` 里的 `cleanUpLiveOncePerLaunch()` 调用、`SparkleProbePreferenceLeftovers` 和只为它写的测试；保留根因修复；新源码契约 `PreferencesFolderContractTests`（3.3） | 契约在旧代码上指出 `SparkleProvider.swift` | 与 P2-3 合跑：Sparkle 探测、偏好目录契约与 AppUpdate 相关 243 个，5 个原有跳过（需显式开启的实机项），0 失败（`rv-n23-green.log`） | 在 `UninstallCandidatePathPolicy.swift` 插一行删除偏好目录里的文件：契约指出该文件 |
| P2-3（N23）签名失败宽限期往本应用偏好写随机键 | `a319151` | 影子 Info.plist 固定 `SUSignedFeedFailureExpirationInterval = 0`，目标应用设了别的值也覆盖（3.2） | 目标未设、设为 86,400 时都不是 0（2 处；与 P1-1 合计 17 个执行、2 个测试 3 处失败，`rv-n23-red.log`） | 同上 | 去掉这一键：2 处失败（与上一格合计 2 个测试 3 处，`rv-n23-mutation.log`） |
| P2-2（N18）注入 `trustedVolumes` 而不传 `persist` 时回执持久化是空操作 | `bc82850` | 默认写正式回执日志；可传 `journal:` 或 `persist`；注入卷必须指定其一，否则不移动（2.2） | 与 P2-7 合计 11 个执行、6 个测试 11 处失败（`rv-n18-red.log`） | 搬家、恢复、回执、操作记录、大文件页与 UI 规则相关 336 个，1 个原有跳过，0 失败（`rv-n18-green.log`） | 默认持久化改回空操作（同时让行不刷新）：5 个测试 6 处失败；去掉“注入卷必须指定日志”：1 个测试 3 处失败（`rv-n18-mutation-1.log`、`-2.log`） |
| P2-7（N18）从“操作记录”放回原件后，行仍显示“已搬到”、访达仍指向副本 | `bc82850` | 页面出现时再看原处，放回或换了文件就改为提示重新扫描、访达打开原处、标记“已复制”（2.2） | 同上 | 同上 | 只让行不刷新：1 个测试 4 处失败（`rv-n18-mutation-3.log`） |
| P2-5（N17）“仅所选位置”的覆盖说明标“先扫描、单独计数” | `2a97d32` | `lastScanSelectedRootPaths` 只在有先扫添加位置那一轮（`selectedRootsPass`）时非空（1.2） | 10 个执行，1 个失败（`rv-n17-red.log`） | 重复文件相关 133 个，0 失败（`rv-n17-green.log`） | 与 P2-6 一起改回：3 个测试 5 处失败（`rv-n17-mutation.log`） |
| P2-6（N17）新测试读真实续扫索引 | `2a97d32` | 续扫索引像结果存储一样注入：应用用真实的，带自有 defaults 的 store（测试）不给，除非传入；新测试检查扫描从给定索引续扫、存回给定索引（1.4） | 没有单独的红：新测试要用注入接口才能编译，先加接口再写测试 | 同上 | 去掉注入：新测试 3 处失败（同上日志） |
| P2-1（N21）把 `parentIsUbiquitous` 换成 `false`，全部测试仍通过 | `b275faa` | 云端状态来源可注入（4.3 第 6 条）；新测试用替身把 `/private/tmp` 下的两个文件夹当作云端文件夹：一个在顶层（多线程时交给工作线程），一个嵌在另一个顶层文件夹里；1 线程与 4 线程下其中文件都标“估算”、本地文件不标，且与逐项询问的参照索引全等 | 这是测试缺口，代码本身没错；红由反证给出（复核的变异现在会失败） | 存储图相关 35 个，1 个跳过（N21 测量程序），0 失败（`rv-p21-final.log`） | 走树丢掉父目录状态（复核的变异）：1、4 线程各 5 个文件失败，且索引与参照不等；工作线程丢掉 `job.isUbiquitous`：4 线程 5 个文件失败，且与参照不等（`rv-p21-mut-parentdrop.log`、`rv-p21-mut-workerdrop.log`） |
| P2-8（N21）合并时调用线程只等不领任务，工作线程起不来就一直等，取消也退不出 | `778ee6d` | 见 4.3 第 4 条；新测试注入永不启动的工作线程：分析仍能完成且与参照全等，之后再启动的工作线程什么都不走；调用线程自己走子文件夹时取消，2 秒内抛 `CancellationError` | 修前：10 秒仍未结束；调用线程没有自己走子文件夹；取消后 2 秒内没有结束、没有抛错（2 个测试 7 处，`rv-p28-red.log`） | 存储图相关 37 个，1 个跳过，0 失败；两个新测试 0.74 s、0.155 s（`rv-p28-green.log`） | 去掉“调用线程接手”：两个测试都失败（取消测试只在“自己走子文件夹”这一条失败，合并循环仍会因取消结束）；改回“等所有已派发的工作线程”：第一个测试 10 秒未结束（`rv-p28-mut-no-takeover.log`、`rv-p28-mut-wait-launched.log`） |
| P2-4（N17）交接说“添加位置的结果排在前面” | 本 docs 提交 | 只改交接（1.2、第 6 节第 3 条），界面不改 | — | — | — |

P2-8 里有一项没有直接的测试：分析已经抛错返回后才启动的工作线程，因为队列已关闭会直接返回，不再打开目录。成功路径上“之后启动的工作线程什么都不走”有测试；取消路径上，没有这道关闭，迟到的工作线程只会打开一个子文件夹、读到第一项就因取消而停，注入的钩子观察不到这一步，所以只靠代码审阅。

### 9.2 对复核 6 处说法的更正（已在原位改正）

| 原说法 | 位置 | 更正 |
|---|---|---|
| 列偏好目录约 1.9 秒（“首次检查多花约 2 秒列目录”） | 3.5、第 7 节 | 1.9 秒是 Python `os.listdir` 只取名字测的一次；原清理用 `contentsOfDirectory`，复核实测 5.6–12.3 秒，算在 12 秒的探测超时里；清理已删除 |
| 添加位置的结果“排在前面” | 1.2、第 6 节第 3 条 | 只对结果上限截断成立；结果页会按空间、大小或名称重新排序（P2-4） |
| 新测试“全部只用临时夹具” | 1.4 | 当时会读真实续扫索引，保存、清除也指向它（P2-6，已改） |
| “Probes no longer write there” | `b0397fa` 的代码注释（已随清理代码删除）；3.2 补说明 | P2-3 之前，签名失败时 Sparkle 仍往本应用偏好写 `SUInitialFailedFeedSigningValidationDate_<宿主ID>` |
| “首次真实更新检查自动删” | 结论表、3.3、3.5、第 6 节第 10 条、第 7 节 | 应用内清理已删除；历史残留按 D48 由主会话处理 |
| “其余文件不可能是云端项” | 4.3 第 1 条 | 按 macOS 现有 File Provider 位置不会是；理论上的例外见 4.5 |

### 9.3 P2-4 说明

“用户文件”“用户数据区”有添加位置时，添加位置下的重复组和候选在结果超过上限要截断时优先保留（逐轮稳定分区）。结果页按“可审阅空间／单个大小／名称”排序显示，所以添加位置的结果不一定显示在前面。按复核意见只改交接，界面不改。

### 9.4 后续（本批不做）

- P2-9：回执日志写入没有用 `F_FULLFSYNC`。这是清理、卸载、搬家共用的 `CleanupReportJournal` 的既有限制，不是本批引入，留给单独批次。

### 9.5 本轮测试与门禁

环境与第 5 节相同；日志在 `~/Developer/.sc-build/r2-files-fixes/logs/`。

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| Debug 全量（`778ee6d`） | `swift build --build-tests`，再 `swift test --skip-build` | 0；0 | 3,477 个执行，22 个跳过，0 失败；测试 189.8 s，总 191 s；负载 4.9～5.6。比交接时（3,469）多 8 个，正好是本轮测试的增减：重复文件 +2、搬家回执 +3、Sparkle 探测 −2（随清理代码删除）、偏好目录契约 +2、存储图等价 +3。跳过与交接时相同：21 个原有的条件跳过（AppUpdateOfficialSecurity 4、BenchmarkV7RealHardwareCapture 3、CleanupRuleScanner 2，其余 12 类各 1）加 N21 测量程序；没有计时项失败，没有放宽阈值 | `rv-debug-full.log`、`.meta`、`rv-debug-full-build.log` |
| 严格并发（`778ee6d`，主目标＋测试目标；先清空 `strict/out` 再全量编译） | `swift build --build-tests -Xswiftc -strict-concurrency=complete` | 0 | 0 错误；1 条编译警告在 `Tests/.../BrowserPrivacyRecoveryTests.swift:474`（`try` 里没有会抛错的调用），本批没改这个文件，`23bd624` 上同一行就有；另一条是 `--skip-update` 已弃用；82 s，负载 5.7～8.3 | `rv-strict-concurrency.log`、`.meta` |
| 私有 API | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `rv-guards.log` |
| `verify.sh` 的源码检查 | Views 不启动进程或终止应用、内存功能不调用 purge、没有冲突副本（与 `verify.sh` 同一模式） | — | 都没有匹配 | `rv-guards.log` |
| 空白检查 | `git diff --check`；`git diff --check 23bd624 HEAD` | 0；0 | — | `rv-guards.log` |

### 9.6 测试卫生

- 本轮新测试不写真实 `~/Library/Preferences`：本批新增的 4 处 `UserDefaults(suiteName:)` 调用都用临时目录里的绝对路径（Sparkle 那处还先核对设置域在探测目录内）；存储图夹具在 `/private/tmp`，不用 UserDefaults；搬家夹具在家目录下的临时文件夹、用隔离回执日志；续扫索引用临时目录；Sparkle 设置域在探测临时目录。
- 全量前后只读对照（13:11:45 → 13:15:52，`logs/rv-prefs-before.txt`、`rv-prefs-after.txt`）：探测残留 6,199 → 6,199，`com.example.sparkle` 1 → 1，本批测试类前缀（`PreferencesFolderContractTests`、`StorageMapAnalysisEquivalenceTests`、`ExternalMigrationReceiptTests`、`SparkleReadOnlyProbeTests`）都是 0，`DuplicateSelectedLocationsTests` 仍是交接时说的 9 个旧文件（3.5）；xctest 的偏好里没有 `SUInitialFailedFeedSigningValidationDate_*`。偏好目录总数多了 178 个，按前缀都来自既有测试（`MenuBarPanelSessionTests.` 37、`FanControlPlannerTests.` 22、`CleanupHistoryServiceTests-` 17 等，本批 diff 没有新增这些前缀），属于 N24／D48。家目录下的搬家夹具、`/private/tmp` 下的存储图夹具都已删除（各 0 个）。

### 9.7 JEV（判断，不是批准）

只提交了 P2-8 的要求、源码 diff 与测试数字（非敏感）。`jev_review`：escalate（需人工复核）；safe_to_apply 0.70；正确性 1.97／2（置信度 0.96）、需求符合 1.99（0.99）、测试缺口 0.15（0.77）、影响面 1.58（0.37）；综合 0.863。升级的原因是影响面一项的置信度低于 0.5，没有指出具体缺陷。请复核者重点看 `StorageMapJobQueue` 的 `close()`、`result(for:waitingUpTo:)` 接手条件和合并循环的三处退出。其余各项本轮没有调用 JEV。
