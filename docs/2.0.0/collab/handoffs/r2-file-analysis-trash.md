# 批次 r2-file-analysis-trash：D46 文件分析审阅后移到废纸篓 + r2-files-fixes 复核尾巴（P2-2、P2-7、迟到工作线程测试）

- 分支 `task/r2-file-analysis-trash`，基于集成分支 `7401e72`（已含 r2-live-fixes-1/2 与 r2-files-fixes）；worktree `~/Developer/sc-worktrees/r2-file-analysis-trash`。
- scratch `~/Developer/.sc-build/r2-file-analysis-trash/`：`debug/`（Debug 与全量测试）、`strict/`、`strict2/`（严格并发；后者是最终一次的新 scratch）、`release-base/`、`release-new/`（N21 Release 对照）、`base-src/`、`base-debug/`（`7401e72` 导出源码，只加截图钩子，供“改前”截图与性能对照）、`bundle-after/`（截图用 Debug 包）、`capture/`（隔离身份的包副本）、`d45/`（截图）、`logs/`（全部日志）、脚本 `capture-d45.sh`（截图）、`compose-d45.py`（并排对照图）、`n21-ab.sh`（Release 对照）、`gates-final.sh`（最终门禁）。依赖从 `r2-files-fixes/debug` 只读复制（checkouts、repositories、artifacts，workspace-state.json 改写路径），`swift` 命令都带 `--skip-update --disable-automatic-resolution`。截图包的编译缓存按 `build_and_run.sh` 的要求放在本批专用的 `/tmp/storage-cleaner-r2fat-bundle`。
- 实现：Claude 子代理（Claude Opus 5.5）。来源：DECISIONS D46、D45；`handoffs/r2-files-fixes.md` 第 2、9 节；交接目录《同类产品对比与改进清单-20261007》（Space Lens 的 Review and Remove）。
- 提交（按顺序）：`0f8e313` 迟到工作线程测试、`d5bfbd4` P2-2 源码契约、`1059d25` P2-7、`a2dbf5b` 变化戳与索引增删、`facc3cd` 可选规则／审阅／移动服务、`f921324` 页面 store、`9703459` 界面与操作记录措辞、`cb4d709` 截图钩子、`aee4446` 界面打磨（D45）、`f987e44` 仅在云端、`d665f8c` 更快的变化戳、`9ad630f` 底栏里单独的说明可以关闭、`f161093` 操作记录标题的“等 N 项”改在显示时生成、`f37b9ef` 本交接。复核后第二轮（第 9 节）：`b666fe3` 合入集成分支（带来 D54）、`4ad242e` D54 受保护范围、`27d399a` 符号链接测试（P2-1）、`9df0f45` P2-2、P2-8～P2-12、`6c55d40` 长原因换行与回执警示、`003d09f` 截图钩子，以及本交接的更新提交。没有变基。
- `Stores/ScanStore.swift`：只加 2 行（一行注释、一行调用），在 `restoreRecordedOperations` 恢复结果处理完后调用 `largeFilesWorkspace.operationHistoryDidRestore(restoredReceipts)`（P2-7，见第 2 节）。
- 没有改并行批次 r2-u1-preselect 的文件（`CleanupScanModels.swift`、`CleanupCoverageCatalog.swift`、`ReadOnlyCleanupScanner.swift`、`CleanupScanViews.swift`、性能测试视图、`ControlPaletteViews.swift`、`FanControlInlineControls.swift`、`GeekNetworkView.swift`）。没有改 `DECISIONS.md`、`BOARD.md`。
- 没有安装、复制到 `/Applications`、启动或退出已安装的测试版／正式版；截图只启动 scratch 里自己构建的 Debug 包副本，用隔离身份 `com.local.StorageCleanerMac.integration`。没有在真实文件上删除、移动或恢复（截图只分析夹具、审阅后取消，什么都没移动）；没有 push；没有读凭证。新测试不写真实 `~/Library/Preferences`（第 6.3 节）。

## 结论

| 项 | 内容 | 结果 | 提交 |
|---|---|---|---|
| D46 | 文件分析的列表、分栏、矩形图都能勾选文件和文件夹；底栏“已选 N 项 · X”＋“审阅并移到废纸篓”；审阅框列名称、路径、大小（文件夹附项目数）和合计，确认后才执行；执行走统一回执（`RecordedTrashOperation`＋`CleanupReportJournal`，规则 `file-analysis.trash.v1`），可从“操作记录”恢复；写不进意图就不移动；移动前逐项核对 inode、大小、修改时间与分析时一致（文件夹逐项比对其下全部条目），不符就跳过并说明，回执记为“已跳过”；移动后索引去掉这些项、各级大小随之减少，不需要重新分析；从“操作记录”放回后自动重新计入；不可选的项目在行内（锁标记＋短原因）和悬停处说明原因 | PASS（夹具单测、红绿、反证）；实机 NOT RUN（第 7 节） | `a2dbf5b` `facc3cd` `f921324` `9703459` `aee4446` `f987e44` `d665f8c` `9ad630f` `f161093` |
| 外接卷 | 移到该卷的废纸篓，回执照常写，写不进意图就不移动；**“操作记录”不能从别的卷的废纸篓恢复**（现有恢复路径只读用户废纸篓、只放回个人目录），所以这类回执行内写“在该卷的废纸篓中 · 请在访达中放回”、不显示“恢复”，审阅框和结果也这样说明（第 8 节第 1 条） | PASS（以“移到另一个废纸篓”的夹具模拟）；真实外接卷 NOT RUN | `facc3cd` `9703459` |
| P2-2 | 源码契约：生产调用（`LargeFilesView` 搬家原件）不传 `journal`／`persist`／`trustedVolumes`／`trashOperation`，默认 `journal ?? .live`，`.live` 就是应用的 `CleanupReports` | PASS（绿、两组反证） | `d5bfbd4` |
| P2-7 | “操作记录”是盖在页面上的 sheet，页面不会重新出现；现在 ScanStore 恢复结束后直接通知文件页 store，搬家行立即变为“已恢复到原处”；文件分析里被放回的项目立即重新计入 | PASS（红、绿、反证） | `1059d25`（文件分析部分在 `f921324`） |
| 测试补强 | 复核方的实验测试改写后纳入 `StorageMapAnalysisEquivalenceTests`（夹具改到家目录下的隐藏文件夹）：取消返回后才启动的工作线程不再走目录；同时去掉 `enterWorker` 与 `take` 的 `closed` 检查时失败（迟到走了 3 个子文件夹），只去掉其中一处仍通过（两处互为保险） | PASS | `0f8e313` |
| D45 | 选择状态、底栏、确认框、不可选说明：深色、浅色各一套“改前（`7401e72`）｜改后”，1280×763.7 与 820×560 两档 | PASS（截图见第 5 节） | `cb4d709`（截图钩子） |
| 门禁（最终代码 `f161093`） | Debug 全量 3564 项、跳过 22、0 失败；严格并发（含测试目标，新 scratch 全量编译）0 错误、本批 0 警告；私有接口检查通过；`git diff --check 7401e72 HEAD` 通过 | PASS（第 6 节） | — |
| N21 走树开销 | Release 对照（负载 5–6.5）中位 +1.4%，逐轮 6 轮都略慢；摘要、内存相同 | 记录在案，不是门禁（6.2） | `d665f8c` |

JEV 两次 `jev_review` 都是 escalate（需人工复核），没有指出具体缺陷；一次 `jev_verify` 核对 Release 对照结论，6 条都 verified，其中 4 条置信度不够、需复核。都不视为批准（第 6.4 节）。

**复核（结论“修后可合并”）后的第二轮修复**，详见第 9 节：

| 项 | 内容 | 结果 | 提交 |
|---|---|---|---|
| P1-1（D54） | ① 整块保护（`~/Library` 下 20 个系统文件夹、`Containers`／`Group Containers`／`Application Support` 里的 `com.apple.*` 与 `AddressBook`、`CallHistoryDB`、`Knowledge`、本应用三个身份的数据目录、9 个凭据位置）；② `~/Library` 第一层每个文件夹、应用容器根目录与其 `Data` 不能整个勾选；③ 含正在运行的应用或挂载点的文件夹不能整个勾选（同时解决 P2-4、P2-5）；④ 有其他硬链接的文件在审阅框提示（同时解决 P2-3）；⑤ 上层目录规则延续；iPhone 备份仍可选。行内与悬停都写中文原因 | PASS（规则表测试、反证逐类失败）；实机 NOT RUN | `4ad242e` |
| P2-1 | 复核员 E1–E3 并入；两处符号链接检查各有一个测试单独兜住 | PASS（两处分别反证） | `27d399a` |
| P2-2 | 中途写回执失败：底栏写“回执未写完，请在“操作记录”中核对”，结果行用警示图标，未处理的项写明原因 | PASS | `9df0f45` `6c55d40` |
| P2-8／P2-9／P2-10／P2-11／P2-12 | 停止后未处理项保持勾选；移走的高亮项清掉高亮、路径栏和预览目标；错误提示中文、原始错误只在“详情”、取消审阅清掉旧提示；“随‘X’移走”不再截成“随…”、比对标题立即显示；iCloud 判定回来前显示“检查中”且不可勾选，规则变化后自动取消勾选并说明 | PASS | `9df0f45` `6c55d40` |
| P2-6、P2-7 与 4 处不实说法 | 只改文档（第 9.6 节；1.2、1.3、5、8 节已更正） | 已更正 | 本交接 |
| 截图 | 改前（`f37b9ef`＋截图钩子）／改后，深浅色各 9 张 | PASS | `003d09f`（钩子） |
| 门禁 | 定向测试、严格并发（含测试）、私有接口、空白检查（第 9.5 节） | 见 9.5 | — |

## 1. D46 改动

### 1.1 分析时记下每项的“变化戳”（`a2dbf5b`、`d665f8c`）

- 要在移动前核对“与分析时一致”，分析时就要记下 inode 和修改时间。原索引条目只有名称、类型、大小、三个布尔值。现在 `StorageMapIndexedEntry` 加 `changeStamp: UInt32`：设备、inode、类型、创建时间，文件再加大小和修改时间，做 SplitMix64 式混合后折成 32 位，0 表示“没记”（符号链接、排除项、读不出的项）。
- 文件夹的戳**不含自身修改时间**：访达保存 `.DS_Store`（例如点了“在访达中显示”）会改文件夹的修改时间，否则用户看一眼就会被判“已变化”。文件夹内部的变化改由移动前逐项比对发现（1.4）。
- 内存：新字段落在原来的对齐填充里，条目步长仍是 48 字节（有测试钉住）。文件复用走树本来就做的那次 `lstat`；文件夹每个多一次 `lstat`（不触发下载）。
- 性能：第一版用逐字节 FNV，Debug 合成树（104,276 项）中位 1.34 s → 约 1.7 s，慢了约 25%；改成按字混合后三轮交替各 3 次：修前 `7401e72` 中位 1.338 s，本批 1.374 s，在各次波动范围内；24 次分析的索引摘要（不含新字段）全部相同（`logs/n21-ab-debug.log`、`n21-ab-debug-2.log`）。Release（208,551 项）负载 5–6.5 时中位 1.260 s → 1.278 s（+1.4%），逐轮比较本批 6 轮都略慢；单独测量的成本是每个文件夹的 `lstat` 1.45 µs、每项算戳 3.3 ns，这棵树合计约 10 ms CPU。详见 6.2。
- 地图条目另带 `isCloudOnly`（`f987e44`）：走树时云端占位文件保留大小并标“估算”、云端文件夹不下钻，据此标出“仅在云端”。

### 1.2 索引就地去掉、放回（`a2dbf5b`）

- `StorageMapAnalysisIndex.removeItem(at:)`：去掉条目及其下全部目录、子项、阻塞集、硬链接重复集；从父目录起到根逐级减去该项的字节、项目数、内容分类。拒绝根、拒绝包内与其他不展开的文件夹里的项目（包按自身类别计入上层，它们本来也不显示）。硬链接在别处计数的路径减 0。
- `reinsert(_:)`：放回原位置（同级里原来的序号）和原数值。store 按“后出先回”放回，保证同级顺序和“先移文件后移其父文件夹”时的嵌套。
- 编辑方式（复核更正，P2-7）：store 先把分析结果从自身取出（`storageAnalysis = nil`）再改。**放回路径**确实在原处编辑；**移动路径不是**：移动任务在同一任务里仍持有 `index`，所以 `directories`、`childrenByDirectory` 两个字典会写时复制（复核 E10 看到指针变化）。复制的只是字典本身，条目数组共享，10 万个文件夹多约 4.7 ms（Debug，复核 E16），原先写的“433 万项时约几百 MB”不对。代码没改（按要求只改文档）；如要避免，可在 `withLease` 闭包用完 `index` 后不再持有它。
- 测试以“同一棵树真把该项删掉后重新分析”的结果作对照，去掉文件、去掉文件夹都与重新分析的索引相同（同级顺序归一后比较）；放回后与原索引完全相等。

### 1.3 哪些项目能勾选（`facc3cd`、`f987e44`）

`FileAnalysisTrashPolicy` 只做路径字符串判断，行在绘制时就能问；需要文件系统的检查放在审阅和移动前（1.4）。**复核更正**：首版这张表把“受保护路径”只落实为系统根、标准文件夹、本应用数据等，没有覆盖 `~/Library` 中的钥匙串、容器、偏好设置等（复核 P1-1），也没列入第 8 节风险；第二轮按 D54 补齐，见 9.1 的规则表。一次分析开始时先用不问文件系统的规则，后台再补两项：iCloud 是否保管“桌面／文稿”，外接卷是否只读。

**不可选规则表**（第一条命中的原因显示在行内，完整说明在悬停提示、审阅框和点锁后的提示里）：

| 顺序 | 情形 | 行内短语 | 说明要点 |
|---|---|---|---|
| 1 | 分析根本身 | 分析范围本身 | 不能整体移到废纸篓 |
| 2 | 启动盘：`/Users` 与任一用户的家目录 | 用户文件夹 | 个人目录不能整体移走 |
| 3 | 启动盘：`/Applications` 里的应用 | 应用 | 在“卸载”中处理 |
| 4 | 启动盘：`/Applications` 里其他项目 | 应用程序文件夹 | 在“卸载”中处理 |
| 5 | 启动盘：重复文件“整台电脑”的受保护根（`/System`、`/Library`、`/private`、`/usr`、`/bin`、`/sbin`、`/opt`、`/cores`、`/System/Volumes/...`）以及 `/Applications`、`/Volumes` 等个人目录以外的顶层位置 | 系统位置 | 不能在这里移走 |
| 6 | 启动盘：其他用户目录与 `/Users/Shared` 下的项目 | 个人目录以外 | 恢复只能放回个人目录，请在访达中处理 |
| 7 | 家目录下的标准文件夹：桌面、文稿、下载、图片、影片、音乐、`Library`、`Applications`、公共（另加了“公共”） | 系统标准文件夹 | 可以打开它处理里面的项目 |
| 8 | 本应用数据目录（含操作记录回执）及其每一级上层（如 `~/Library/Application Support`） | 本应用的数据 | 回执日志在里面，移走会连回执一起移走 |
| 9 | `~/.Trash` 及其中项目；外接卷的 `.Trashes` | 已在废纸篓 | — |
| 10 | `~/Library/Mobile Documents`、`~/Library/CloudStorage` 及其中任何项目；iCloud 保管时的桌面、文稿中的任何项目 | 云盘位置 | 移到废纸篓会从所有设备删除，**请在访达或云盘应用中处理** |
| 11 | 外接卷顶层的隐藏文件夹（`.Spotlight-V100`、`.fseventsd` 等）与 `Backups.backupdb` | 系统位置 | 卷的系统数据、时间机器备份 |
| 12 | 只读的外接卷上的项目 | 只读卷 | — |
| 13 | 应用包（任何位置的 `.app` 文件夹） | 应用 | 统一走“卸载”，那里会检查关联文件 |
| 14 | 符号链接 | 符号链接 | 只是链接本身，移走不释放空间 |
| 15 | 扫描排除清单中的项目，以及含有排除项的文件夹 | 已排除 | 复用 `ScanExclusionService` 的规则 |
| 16 | 读不出的项目 | 无法读取 | — |
| 17 | 仅在云端的项目 | 仅在云端 | 请在访达或云盘应用中处理 |
| 18 | 测量不完整、可能含未读部分的文件夹；大小读不出的文件 | 测量不完整 | — |
| 审阅／移动前 | 已锁定（`uchg`、`schg`、`SF_RESTRICTED` 等标志） | 已锁定或受保护 | 可在“显示简介”中解锁 |
| 审阅／移动前 | 分析后被修改或替换；不在原处；路径中出现符号链接；文件提供者报告为云端项；卷不可写 | 分析后已变化／已不存在／云盘位置／仅在云端／只读卷 | — |
| 状态 | 已勾选文件夹里面的项目 | 随“X”移走 | 勾选框显示为已勾、不可单独操作 |

- 启动盘上只有个人目录里的项目可选：“操作记录”的恢复只放回个人目录（现有恢复路径的限制），这样移走的都能恢复。
- 包含应用的普通文件夹（例如构建产物）可以勾选：规则只针对应用包本身，否则 DerivedData 一类都会被挡。
- 勾选一个文件夹会收起其中已勾的项目；已勾文件夹里的项目显示“随‘X’移走”。

### 1.4 审阅与移动（`facc3cd`）

- 审阅（后台线程）：每项再次套用上表，并核对：索引里有这项、有变化戳；`lstat` 存在、不是符号链接、文件／文件夹类型不变、变化戳与分析时相同；没有锁定标志；`FileSnapshot` 不是云端项、卷可写、路径无符号链接成分；文件的大小（与分析同一口径）与分析时相同。通过的记下身份（设备、inode、创建时间），不通过的在审阅框里写出原因、不执行。
- 移动：`RecordedTrashOperation.runAsync`，先持久写意图，写不进就一项都不动；在重任务租约 `.cleanup` 下逐项进行。每项在 `validate` 里（移动前）再做一遍审阅时的核对，并要求身份与审阅时相同；文件夹再完整走一遍、逐目录比对全部条目（名称、类型、大小、变化戳；`.DS_Store` 不比），因此文件夹里任何文件被改、增、删、替换都能发现。任何不符抛 `RecordedTrashOperation.Skip`，回执记为“已跳过”（新跳过原因 `changedSinceAnalysis`：“分析后已修改或替换，请重新分析”），不是“移动被拒绝”。`RecordedTrashOperation` 只加了这一处：`validate` 在移动前抛 `Skip` 时记为跳过；其他调用方不抛它，行为不变。
- 回执：规则 `file-analysis.trash.v1`，`allowedRestoreRoot` 为原件所在目录，金额为页面上显示的大小。“操作记录”标题“文件分析 · 第一项名称 等 N 项”：回执索引缓存里只存第一项名称（与文件搬家相同），“等 N 项”在显示时按回执的项数和当前语言生成（`f161093`；原先整句存进缓存，切换语言后仍是旧语言）。
- 进度：审阅框里显示“正在核对并移动 N / M”，比对文件夹时显示“正在与分析结果比对‘X’（已读 N 项）”；“停止”在当前这一项结束后停下。
- 结果：底栏显示“已移到废纸篓 N 项 · X”和未移动的项目及原因（前 3 项，其余见“操作记录”）；回执写不进时显示“无法写入操作记录；为了能恢复，没有移动任何项目”。
- 移动后：索引去掉已移动的项（1.2），根快照和页面持有的每一层（包括前进历史）从新索引重建，所在层被移走时退到还在的上层。
- 从“操作记录”恢复后：ScanStore 通知 store（第 2 节），身份相同的项目放回索引、各级大小加回，底栏提示“已从‘操作记录’放回 N 项，已重新计入”；原处是另一个文件时不算。
- 一次新的分析清空勾选、审阅、结果和放回记录。审阅、移动期间“重新分析磁盘”不可用。

### 1.5 界面（`9703459`、`aee4446`）

- 列表行、分栏行：行首勾选框，样式同智能扫描结果的分组勾选（空心方框、模块色实心勾、不可选显示锁）；点锁或已含在所选文件夹里的项目，底栏给出说明而不是勾选。行内第二行在类型后加短原因（不可选）或“随‘X’移走”（青色）。
- 矩形图：已勾的块左上角显示勾选框并加一层淡青色；可勾的块悬停时显示勾选框；不可选的块在悬停提示里写原因。
- 底栏：勾选后在索引状态行的位置显示“已选 N 项 · X”“清除”“审阅并移到废纸篓”（红色主按钮，悬停说明“可在‘操作记录’中恢复；清空废纸篓后才释放空间”），点锁的说明在其下一行；移动后显示结果。什么都没勾时点锁，底栏只有这条说明，带“好”按钮可关掉（`9ad630f`）。底栏显示时浏览区的最小高度从 240 降到 160（列表、矩形图 180 → 110），820×560 窗口下导航条、列表和底栏都看得到（修前同尺寸导航条被上下裁切）。
- 审阅框：标题“审阅后移到废纸篓”、“N 项可以移到废纸篓 · 合计 X”、不处理的项数；每项图标、名称、大小、完整路径（中间省略、悬停全文）、类型或“文件夹 · 含 N 项”、状态（可以移到废纸篓／不会处理：原因＋完整说明）；“移动前会逐项再核对一次……”“可在‘操作记录’中恢复……”；外接卷说明；按钮“取消”“移到废纸篓（N 项）”。4 项以内不出滚动区。
- 操作记录（`ReversibleOperationsView`）：别的卷的废纸篓里的回执行显示“在该卷的废纸篓中 · 请在访达中放回”，没有可在此恢复的项时“恢复”不可用；保留了 P2-6 源码契约要求的原句。

## 2. P2-7（`1059d25`）

- 原因：搬家行的刷新只在页面 `.task`（出现时）里做；“操作记录”是 sheet，关掉后页面不会重新出现，行一直显示“已搬到”，直到切页回来。
- 修复：`LargeFilesStore.operationHistoryDidRestore(_ receipts:)`，ScanStore 在 `restoreRecordedOperations` 处理完恢复结果后调用（ScanStore 唯一改动，2 行）。它重新查看搬家行原件的位置（复用 `refreshMigrationCompletions()`），D46 起也负责把文件分析里放回的项目重新计入。页面出现时的刷新保留。
- 测试：行为测试走与“操作记录”相同的恢复服务（`CleanupRecoveryService.restore`，夹具日志与夹具废纸篓）后调用该入口，行立即变为“已恢复到原处”；接线用源码契约（ScanStore 的恢复函数里，恢复之后调用该入口）。没有直接跑 ScanStore 的恢复：它结束后会从**正式**回执日志重新加载“操作记录”列表（`CleanReportStore.summaryPage` 只读 `.live`，BOARD N8），测试会碰到真实数据。

## 3. P2-2（`d5bfbd4`）

`ExternalMigrationReceiptTests.testTheProductionMoveWritesTheLiveJournal`：Sources 里在服务之外调用 `ExternalDriveMigrationService.moveOriginalToTrash(` 的只有 `LargeFilesView.swift`，其参数不含 `journal:`、`persist:`、`trustedVolumes:`、`trashOperation:`；服务里默认参数是 `journal: CleanupReportJournal? = nil`、`let receiptJournal = journal ?? .live`，`persist` 缺省时写 `receiptJournal`；`CleanupReportJournal.live.directory` 就是 `AppDataDirectories.applicationSupportRoot/CleanupReports`。D46 也有同样的契约：ScanStore 创建 `LargeFilesStore` 不传 `trashEnvironment`，默认 `.live`（正式日志＋`FileManager.trashItem`）。

## 4. 迟到工作线程测试（`0f8e313`）

复核方的 `rv2-ReviewLateWorkerExperimentTests.swift` 改写进 `StorageMapAnalysisEquivalenceTests`（复用该类已有的 `HeldWorkers`、`Locked`，新增 `RootLevelGate`、`LateProgress`），夹具从 `/private/tmp` 改到家目录下的隐藏临时文件夹、用后删除。场景：4 个工作线程全被扣住，根层走到第 3 个顶层文件夹时取消；取消返回后清空各子文件夹，再放行扣住的工作线程；返回之后出现任何进度回报或云端查询，就说明有迟到的工作线程走了目录。

- 绿：10 个，0 失败（`logs/t3-green.log`）。
- 反证：同时去掉 `enterWorker` 与 `take` 的 `closed` 检查，迟到的工作线程走了“Top 2/3/4”三个子文件夹，测试失败（`t3-mutation-closed.log`）；只去掉其中一处时仍通过（`t3-mutation-only-enter.log`、`t3-mutation-only-take.log`）——两处互为保险，这个测试锁的是“两处都没了”。已还原。

## 5. D45 截图

- 方法：`cb4d709` 给开发版截图管线加了 `--capture-file-analysis-trash=<夹具文件夹>`（只接受家目录下 `.storage-cleaner-` 开头的隐藏文件夹）：分析夹具 → 截图；勾选三项并点一次应用包（留下说明）→ 截图；切到分栏 → 截图；进入已勾选的文件夹 → 截图；审阅前改动一个已勾选的夹具文件，使审阅框里出现“不会处理”的一项 → 打开审阅 → 截审阅框与主窗口 → **取消**（不移动任何东西）；窗口改 820×560 → 截图。显示方式偏好用后恢复。
- “改前”：`7401e72` 导出源码，只加同一个钩子里与本批无关的部分（不含勾选、审阅），Debug 编译，可执行文件放进同一个包副本。“改后”：本批代码（`f161093`）的 Debug 包（`build_and_run.sh --bundle-only`）。两者链接信息相同（`minos 14.0`、`sdk 27.0`；改前的可执行文件按 `build_and_run.sh` 的做法加了 `-Xlinker -platform_version`，否则按 SDK 14 链接会用旧外观，两边不可比）。两者都复制到 `capture/`，改 Bundle ID 为 `com.local.StorageCleanerMac.integration`、临时签名，用 `STORAGE_CLEANER_INTEGRATION_ROOT` 指向 `~/Library/Caches/StorageCleanerIntegration-claude-r2fat-*`（每次运行后删除）。同一身份一次只运行一个实例，启动前等待其他实例退出，结束时只终止自己启动的进程。夹具是家目录下的隐藏临时文件夹（约 160 MB），结束后删除（脚本核对已删除）。
- 语言、外观用启动参数传入（`-app.language zhHans -app.appearance light|dark -AppleLanguages ("zh-Hans")`，只在该进程的参数域），不写偏好。原因：第 5 次截图的深色“改后”一组是英文，运行后该域的 `AppleLanguages` 也没了（应用读不到 `app.language` 时按“跟随系统”删掉 `AppleLanguages`），说明运行中语言键不在了。隔离身份的偏好域是各会话共用的，推测是别的进程同时改了它（未核实是谁）。改成启动参数后不受这类改动影响，重拍了全部四组（第 6 次），逐张看过都是中文。结束后该域与本批开始前一致：`AppleLanguages = ("zh-Hans")`，没有 `app.language`、`app.appearance`、`storage-analysis.display-mode`（后者是早先一次被提前终止的截图留下的，脚本已删除；截图钩子本身用后会恢复它）。
- 脚本 `~/Developer/.sc-build/r2-file-analysis-trash/capture-d45.sh`（上一版留作 `capture-d45.v1.sh`）；最后一次运行日志 `logs/capture-d45-6.log`，各次运行的应用输出在 `d45/*.log`。并排对照图由 `compose-d45.py` 生成。
- 图在 `~/Developer/.sc-build/r2-file-analysis-trash/d45/`（不进仓库）；并排对照（左改前、右改后）在 `d45/side-by-side/{light,dark}-fa-{1,3,4,6}-*.png`：

| 状态 | 改前（`before-light`／`before-dark`） | 改后（`after-light`／`after-dark`） |
|---|---|---|
| 勾选框与不可选说明（锁＋“应用”；复核更正：`link` 与 `Locked Folder` 两行在可见区下方，“符号链接”“测量不完整”两条原因没有截图证据，只有代码与测试） | `fa-1-checkboxes.png`（无勾选框） | `fa-1-checkboxes.png` |
| 已勾选＋底栏＋点锁后的说明；矩形图上的勾选 | —（新增状态） | `fa-2-selected-bar.png` |
| 分栏里的勾选 | `fa-3-columns.png` | `fa-3-columns.png` |
| 已勾文件夹里的项目（“随‘Old Projects’移走”） | `fa-4-inside-checked-folder.png` | `fa-4-inside-checked-folder.png` |
| 审阅框（2 项可以移、1 项“分析后已变化”） | —（新增状态） | `fa-5-review-sheet.png`、`fa-5-review-main.png` |
| 820×560 窄窗口 | `fa-6-narrow-selected.png`（导航条被裁切） | `fa-6-narrow-selected.png`（导航条、列表、底栏都在） |

- 截图里看到并已改的问题（`aee4446`）：系统原生勾选框在深浅色下都把未勾选画成实心灰块，改为与智能扫描分组勾选相同的画法；短窗口里底栏被裁掉；行内加注后占比文字被挤；审阅框少量项目时下方留白。
- 截图不能反映的：真实指针悬停（矩形图悬停才出现的勾选框、悬停提示）、真正的移动与“操作记录”恢复、外接卷。放到实机清单（第 7 节）。
- 深色组里红色主按钮（底栏“审阅并移到废纸篓”、审阅框“移到废纸篓（N 项）”）显示为灰色，浅色组是红色。两个按钮用的都是应用统一的 `appButtonChrome(.primary)`（`.borderedProminent`）加红色 tint；并行批次 r2-u1-preselect 的深色截图里，智能扫描已选 3 项时的“安全清理”主按钮同样是暗的。复核更正：原先写“深色的系统外观”不准确，应是**深色那几轮窗口不是活动窗口**（分段控件选中段也是灰的；浅色那轮是活动窗口），截图也区分不了“禁用”与“非活动”。第二轮截图里深色“改后”有一轮窗口是活动的，“审阅并移到废纸篓”显示为红色（`review-fixes-shots/after-dark/fb-5-inside-checked-folder.png`）。仍放在实机清单第 1 条。
- 深色组的 `Archive 2023.zip` 显示 28.3 MB、浅色组 27.3 MB：同一个夹具先被浅色“改后”那次运行追加了 1 字节（为了让审阅框出现“已变化”），APFS 预分配使占用多出约 1 MiB；每组改前改后用的是同一状态的夹具，可比。

## 6. 测试与门禁

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`、`LC_ALL=en_US.UTF-8`、`--jobs 4`、`--skip-update --disable-automatic-resolution`；日志在 `~/Developer/.sc-build/r2-file-analysis-trash/logs/`。

### 6.1 每项红绿与反证

| 项 | 红 | 绿 | 反证（各自单独改动后跑相关测试，均已还原并逐字节核对） |
|---|---|---|---|
| 迟到工作线程 | 实验测试来自复核方，代码已修；红由反证给出 | 10 个，0 失败（`t3-green.log`） | 两处 `closed` 检查都去掉：1 处失败（`t3-mutation-closed.log`） |
| P2-2 | 契约锁定既有正确行为；红由反证给出 | `ExternalMigrationReceiptTests` 12 个，0 失败（`p22-green.log`） | 生产调用加 `journal:`：失败；默认改为非 `.live`：失败（`p22-mutation-call.log`、`p22-mutation-default.log`） |
| P2-7 | 入口为空桩：2 个测试 3 处失败（`p27-red.log`） | 搬家、恢复相关 26 个，0 失败（`p27-green.log`） | 去掉 ScanStore 的调用：契约失败（`p27-mutation-wiring.log`） |
| 变化戳、索引增删 | 实现先于测试写成，红由反证给出（如实说明） | 存储图相关 43 个，0 失败（`d46-index-green.log`） | 走树不记戳；文件夹戳含修改时间；不更新上层；硬链接重复也减字节；放回时追加到末尾：分别 1–3 个测试失败（`d46-index-mut-*.log`） |
| 可选规则、审阅、移动服务 | 同上 | `FileAnalysisTrashTests`＋操作记录标签 12 个，0 失败（`d46-service-green1.log`） | 去掉标准文件夹规则；去掉云盘位置规则；不比变化戳（替换仍被身份检查拦下，编辑被审阅拦下）；关掉文件夹比对；`.DS_Store` 也比；`Skip` 记成失败；回执不落盘：均有测试失败（`d46-service-mut-*.log`） |
| 页面 store | 接口为空桩：6 个中 5 个失败、19 处（`d46-store-red.log`） | 6 个，0 失败（`d46-store-green2.log`） | 勾文件夹不收起其中已勾项；移动后不改索引；放回不核对身份；不重建各层；新分析不复位：均有测试失败（`d46-store-mut-*.log`） |
| 操作记录措辞、页面契约 | — | 11 个，0 失败（`d46-presentation.log`） | 任何回执都当作在用户废纸篓；去掉行的勾选框：失败（`d46-ui-mut-*.log`） |
| 仅在云端 | — | 含新测试共 61 个，0 失败 | `isCloudOnly` 恒为假：2 处失败（终端输出，未单独存日志） |
| 操作记录标题（`f161093`） | 改测试与改代码同一提交，红由反证给出 | 相关 23 个，0 失败（`f161093-green.log`） | 回执索引缓存里再存整句“big.zip 等 3 项”：2 处失败（缓存不应含措辞；标题变成“等 3 项 等 3 项”）（`f161093-mutation-cachedtitle.log`）；已还原，逐字节核对 |
| 底栏说明的“好”（`9ad630f`） | — | 没有测试（纯界面），截图也没覆盖该状态 | NOT RUN；列入实机清单第 1 条 |

### 6.2 门禁

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| Debug 全量（最终代码 `f161093`） | `swift build --build-tests`，再 `swift test --skip-build` | 0；0 | 3564 个执行，22 个跳过，0 失败；测试 197.5 s；负载 3.8 → 4.3。跳过与上一次逐类相同：AppUpdateOfficialSecurity 4、BenchmarkV7RealHardwareCapture 3、CleanupRuleScanner 2、其余 13 类各 1（含 N21 测量程序）；没有计时项失败。（`d665f8c` 时也跑过一次：同样 3564／22／0，208.5 s，`gate-debug-full.log`） | `gate-debug-build-2.log`、`gate-debug-full-2.log`、`.meta` |
| 严格并发（`f161093`，主目标＋测试目标，新 scratch `strict2` 全量编译） | `swift build --build-tests -Xswiftc -strict-concurrency=complete` | 0 | 0 错误；唯一编译警告在 `Tests/.../BrowserPrivacyRecoveryTests.swift:474`（既有，本批未改该文件），另一条是 `--skip-update` 已弃用；本批文件 0 警告；99.4 s | `gate-strict-2.log`、`.meta` |
| 私有 API（`f161093`） | `python3 script/check_private_api.py` | 0 | private API check passed (6 allowlisted uses) | `gate-guards-2.log` |
| `verify.sh` 的源码检查 | Views 不启动进程或终止应用、内存功能不调用 purge、没有冲突副本（与 `verify.sh` 同一模式） | — | 都没有匹配 | `gate-guards-2.log` |
| 空白检查 | `git diff --check`；`git diff --check 7401e72 HEAD`（本交接文件在提交前另用 `git diff --cached --check` 检查） | 0；0 | — | `gate-guards-2.log` |
| N21 Debug 对照 | 交替运行 `StorageMapAnalysisPerformanceTests`（`STORAGE_CLEANER_N21_PERF=1`，104,276 项） | 0 | 见 1.1 | `n21-ab-debug.log`、`n21-ab-debug-2.log` |
| N21 Release 对照 | `swift build -c release --build-tests -Xswiftc -enable-testing`（改前源码、本批各一份），再用 `xcrun xctest` 交替运行同一个测量程序 | 0 | 负载 5–6.5：中位 1.260 s → 1.278 s（+1.4%），见下 | `release-*-build.log`、`n21-ab-release.log`、`n21-ab-release-2.log`、`stampbench.*`；脚本 `n21-ab.sh` |

N21 Release 对照（合成树 208,551 项、6,050 个文件夹，在 scratch 里；4 个工作线程；每个进程先热身 1 次再计时）：

| 轮次 | 负载（1 分钟） | 改前 `7401e72` | 本批 | 说明 |
|---|---|---|---|---|
| 第 1 次（15:19，3 轮×2 次） | 12–15 | 中位 2.053 s（1.766–2.135） | 中位 2.283 s（2.081–2.418） | +11%；负载太高、各次波动大，按 N10 在负载降下来后重跑 |
| 第 2 次（15:24，6 轮×3 次，每轮交换先后） | 5.2–6.5 | 中位 1.260 s（1.047–1.499），平均 1.247 s | 中位 1.278 s（1.048–1.447），平均 1.277 s | +1.4%（平均 +2.4%）；逐轮中位数之比 1.007–1.081，6 轮都是本批略慢；热身那次平均反而本批快（1.149 s 对 1.172 s） |

- 两次共 66 次分析的索引摘要全部是 `311e0d92…`（新字段不计入摘要）；常驻内存每项 194–211 字节，两边相同。
- 单独测量的成本（`stampbench.*`，Release，单线程，热缓存）：每个文件夹多一次 `lstat` 1.45 µs，算一次戳 3.3 ns；这棵树合计约 8.8 ms＋0.7 ms CPU，4 个线程分摊。文件的戳复用走树本来就做的 `lstat`，没有新增系统调用。
- 结论：开销在 1%–3% 之间，小于单次波动；但第 2 次逐轮比较 6 轮都是本批略慢，不能排除约 1%–2% 的固定开销（比单独测量的预期大，可能是并行时 `lstat` 更慢）。没有放宽任何阈值；全量测试里的计时项都通过。若要再省，可以把文件夹的 inode、创建时间放进枚举器本来就批量读取的资源键（`fileIdentifierKey`、`creationDateKey`），省掉这次 `lstat`；需要另测资源键的开销，本批没做。

NOT RUN（主会话门禁或实机）：Release 全量 `swift test -c release`、`script/verify_menu_bar_performance.sh`、打包安装、实机核对（第 7 节）。

### 6.3 测试卫生

- 新测试的夹具都在家目录下的隐藏临时文件夹（`.storage-cleaner-*-test-<UUID>`），用后删除；回执写独立日志，“废纸篓”是夹具文件夹；`LargeFilesStore` 的偏好用夹具里的绝对路径域；语言切换只改测试进程的 volatile argument domain。没有新测试读写正式回执日志或真实废纸篓。
- 全量前后只读对照（最终一次：`logs/prefs-before-2.txt`、`prefs-after-2.txt`；`d665f8c` 那次：`prefs-before.txt`、`prefs-after.txt`）：本批测试类前缀在 `~/Library/Preferences` 里都是 0 → 0；隔离身份的偏好文件 1 → 1；家目录下 `.storage-cleaner-` 夹具 0 → 0。偏好目录总数 228,462 → 228,680（+218；上一次 228,259 → 228,461，+202）。这段时间新建或改动的 234 个文件按前缀全部来自既有测试：`ScanHistoryTestDefaults` 40、`MenuBarPanelSessionTests` 37、`FanControlPlannerTests` 22、`CleanupHistoryServiceTests` 17、`MiniWindowAnchorGeometryTests` 8 等，另有 4 个纯 UUID 名的来自 `ItemListAndDuplicatePresentationTests`、`SystemMonitorServiceTests`（`UserDefaults(suiteName: UUID().uuidString)`），`large-files-store-test-*` 来自 `IndependentFeatureWorkspaceStoreTests`；同时段可能有其他会话在跑测试。属于 N24／D48，本批没有新增。本批新测试的偏好域都是夹具里的绝对路径。

### 6.4 JEV（判断，不是批准）

只提交了非敏感的需求、设计说明、代码摘录与测试数字。

| 调用 | 对象 | 结果 |
|---|---|---|
| `jev_review` | 第一次误把代码写成文件引用，实际只提交了需求与设计说明 | escalate；safe_to_apply 0.19；综合 0.644 |
| `jev_review` | D46 服务、规则、索引增删、store 收尾与放回、ScanStore 接线（摘录约 15 KB）＋测试与反证清单 | escalate；safe_to_apply 0.27；正确性 1.50／2（置信度 0.25）、需求符合 1.65（0.48）、测试缺口 0.52（0.22）、影响面 1.95（0.92）；综合 0.662 |
| `jev_verify` | 6.2 的 Release 对照结论（只交了计时数字与单独测量结果） | 6 条都是 verified、0 条 contradicted；auto 2 条（中位差小于各自波动范围 0.93、摘要全部相同 1.00），review 4 条（+1.4% 0.70、6 轮都慢 0.78、约 10 ms CPU 0.51、第 1 次 +11% 不可靠 0.48） |
| `jev_review`（第二轮） | 复核修复的需求、改动摘要（规则、读取时机、各 P2 的做法、截图钩子）与测试、反证、门禁数字 | escalate；safe_to_apply 0.33；正确性 1.81／2（置信度 0.72）、需求符合 1.90（0.85）、测试缺口 0.47（0.30）、影响面 1.95（0.92）；综合 0.766 |

JEV 没有指出具体缺陷；置信度低，按规则不视为批准。请复核者重点看：`FileAnalysisTrashService.check` 与 `verifyFolder` 的比对口径（文件夹戳不含修改时间、`.DS_Store` 不比）；`RecordedTrashOperation` 新增的 `Skip` 分支只在未调用移动时生效；`LargeFilesStore.takeStorageAnalysisForEditing` 先置空再原处编辑；放回的“后出先回”顺序；外接卷回执不提供“恢复”的处理。

## 7. 需要实机核对（主会话，只用夹具）

在家目录下建一个夹具文件夹（例如 `~/D46-夹具/`）：几个大文件（`dd`）、一个含子文件夹和文件的文件夹、一个 `X.app` 文件夹、一个符号链接、一个上锁文件（`chflags uchg`）、一个 `chmod 000` 的文件夹。文件分析选“个人目录”分析（只读），进入夹具文件夹；**只勾夹具里的项目**。

1. 行首勾选框、锁和行内原因：`X.app`“应用”、链接“符号链接”、`chmod 000` 文件夹“测量不完整”；回到个人目录根：桌面、文稿、下载等“系统标准文件夹”，`Library` 同；`~/Library/Mobile Documents`、`~/Library/CloudStorage`“云盘位置”；如开了 iCloud 桌面与文稿，其中任何项目“云盘位置”。悬停看完整原因；点锁看底栏说明（什么都没勾时有“好”可关）。中英文各看一次，深浅色各看一次；深色下窗口在前台时，“审阅并移到废纸篓”和审阅框的“移到废纸篓”应是红色主按钮（离屏截图里是灰的，见第 5 节）。
2. 勾选夹具里的文件夹和两个文件：底栏“已选 3 项 · X”；进入已勾的文件夹，其中项目显示“随‘…’移走”且勾选框为灰色已勾；矩形图上已勾的块有勾选框，可勾的块悬停出现勾选框，不可选的块悬停提示写原因（离屏截图看不到真实悬停）。
3. 点“审阅并移到废纸篓”：审阅框列出名称、路径、大小、文件夹项目数、合计；上锁文件显示“不会处理：已锁定或受保护”。审阅框开着时，在终端里改动一个已勾选的文件（`echo x >> 文件`）再点“移到废纸篓”：该文件跳过并写“分析后已变化”，其余移到废纸篓；页面上它们消失，各级大小减少，没有重新分析。
4. “操作记录”：出现“文件分析 · … 等 3 项”，被跳过的那项显示“已跳过：分析后已修改或替换，请重新分析”。在文件分析页上打开“操作记录”并恢复：关闭 sheet 后（不切页）项目立即回到地图，底栏“已从‘操作记录’放回 N 项，已重新计入”。
5. 把一个夹具文件夹放在外接卷上，分析该卷并移走它：进入该卷的废纸篓；审阅框与结果说明“在访达中从该卷的废纸篓放回”；“操作记录”该项显示“在该卷的废纸篓中 · 请在访达中放回”，没有“恢复”。在访达中放回后删除夹具。
6. 一个约 10 万项的夹具文件夹：移动前比对时显示“正在与分析结果比对‘X’（已读 N 项）”，记录用时；比对中点“停止”，当前这一项结束后停下，未处理的项目显示“已停止，未处理”。
7. 窗口缩到约 820×560：导航条、列表和底栏都在。
8. P2-7：文件搬家页移走一个夹具原件后，在该页打开“操作记录”恢复它；关掉 sheet 后（不切页）那一行立即显示“已恢复到原处，请重新扫描”。
9. 用新版分析个人目录一次，对照 r2-files-fixes 的用时与常驻内存（变化戳不增加条目大小；文件夹多一次 `lstat`）。
10. 第二轮（D54，只看、不勾真实目录）：分析个人目录，打开 `Library`：每个文件夹都有锁和“资源库文件夹，不能整个移走”，`Keychains`、`Mail`、`Messages`、`Preferences` 等写“系统数据，不能移到废纸篓”；打开 `Containers`：`com.apple.*` 是“系统数据”，第三方应用是“应用容器，不能整个移走”；个人目录根下 `.ssh` 写“密钥与凭据…”、`.config` 写“含受保护的位置”。`Application Support/MobileSync/Backup` 里的各份备份可勾（只看，不移动）。
11. 在夹具文件夹里放一个可运行的构建产物（例如夹具里的 `Demo.app`）并运行它：夹具文件夹显示“含正在运行的应用”，退出后再点一下勾选框即恢复可勾；把一个磁盘映像挂载到夹具文件夹里的空目录（`hdiutil attach -mountpoint`）：上层显示“含其他磁盘的挂载点”，推出后恢复。
12. 开着 iCloud“桌面与文稿”时刚分析完的一两秒内，桌面里的项目显示“检查中”、点了不勾；之后显示“云盘位置”。
13. 审阅框里有其他硬链接的夹具文件显示“另有硬链接，移走后空间不一定释放”；比对中点“停止”后未处理的项仍是勾选状态；勾选一个文件并高亮它，移走后路径栏回到当前文件夹。

## 8. 未解决问题与风险

1. **外接卷不能从“操作记录”恢复**：现有恢复（`CleanupRecoveryService.restoreOne`）只从用户废纸篓取、只放回个人目录（或授权的 `/Applications`）。本批按任务要求照常写回执，但界面明确写“请在访达中放回”、不提供“恢复”。另外中断后的对账（`reconcileInterruptedTrashMoves`）只列用户废纸篓，外接卷上“结果待核实”的移动不会被自动核实。若要支持，需要扩展恢复路径（按回执里的卷、`allowedRestoreRoot` 与身份放回同一卷），建议单独批次并实机测外接盘；请主会话决定。
2. **硬链接**：分析把多路径共享的字节记在一个规范路径上；移走规范路径时地图减去这部分字节，但其他链接还在，空间并不会释放。第二轮起审阅框对有其他硬链接的**文件**提示“另有硬链接，移走后空间不一定释放”（D54 ④）；含此类文件的**文件夹**不提示，地图仍按分析时的数字减。
3. **文件夹比对的耗时**：每个勾选的文件夹移动前都会完整再走一遍（与分析同一走法，合成树约 6–8 万项／秒，Debug），大文件夹要等一会儿，界面有进度和“停止”。
4. **变化戳是 32 位**：被改的文件恰好得到同一个戳的概率约 1/2^32；身份、大小与文件夹的逐项比对另行核对。
5. **索引是分析时的快照**：移走、放回只按分析时的数字增减；上层的“测量不完整”标记不重新计算（能移走的都是完整的项目，所以不会因此变化）。
6. **短窗口**：勾选后浏览区最小高度由 240 降到 160、列表与矩形图由 180 降到 110；底栏取代索引状态行（勾选清空或结果关闭后恢复）。
7. **隔离身份**：`com.local.StorageCleanerMac.integration` 的数据目录在 `~/Library/Caches/StorageCleanerIntegration-*`，因此在那个身份下 `~/Library/Caches` 作为“本应用数据的上层”不可选；正式版、测试版的数据目录在 `~/Library/Application Support`，不受影响。
8. 回执日志写入没有用 `F_FULLFSYNC`（r2-files-fixes P2-9 的既有限制，本批沿用）。
9. 新增跳过原因 `changedSinceAnalysis` 是可编码枚举的新值：更旧版本的应用读到含它的回执会解码失败（与以往新增原因相同）。
10. JEV 两次 escalate（6.4）。
11. **走树的开销**：Release 对照约 +1.4%（中位）、逐轮 6 轮都略慢（6.2），来自每个文件夹多一次 `lstat`；6.2 末尾有可再省的做法。
12. `9ad630f`（底栏里单独的说明加“好”）没有测试，截图也没有拍到“什么都没勾时点锁”的状态；放在实机清单第 1 条。
13. 第二轮新增的风险与限制见 9.7。

## 9. 复核后的修复（第二轮，2026-10-07）

来源：复核报告 `~/Developer/.sc-build/r2-file-analysis-trash-review/review.md`（结论“修后可合并”）与实验测试 `evidence/ReviewR2FATExperimentTests.swift`；集成分支 D54（`3d435b6`，由 `b666fe3` 合入，只有文档）。新测试仍只用夹具（家目录下的隐藏临时文件夹、夹具回执日志、夹具“废纸篓”），不写真实 `~/Library/Preferences` 或 `~/Library/Caches`（9.5 有计数）。

### 9.1 P1-1：D54 受保护范围（`4ad242e`）

在 1.3 的规则表之上增加（行内原因在锁之后显示，空间不够时换到第二行，最多两行；悬停、审阅框和点锁后的底栏说明给完整句子）：

| D54 | 情形 | 行内原因 | 补充 |
|---|---|---|---|
| ① | `~/Library` 下 `Keychains`、`Mail`、`Messages`、`Safari`、`Accounts`、`Calendars`、`Cookies`、`HomeKit`、`Passes`、`Autosave Information`、`LaunchAgents`、`Preferences`、`Biome`、`IdentityServices`、`Sharing`、`Suggestions`、`Metadata`、`Daemon Containers`，连同其中任何项目 | 系统数据，不能移到废纸篓 | 说明：系统和应用离不开它们，移走后会被重建，“操作记录”也放不回 |
| ① | `Mobile Documents`、`CloudStorage` 及其中项目 | 云盘位置 | 沿用 D46 原规则和“请在访达或云盘应用中处理” |
| ① | `Containers`、`Group Containers`、`Application Support` 里名称以 `com.apple.` 开头或含 `.com.apple.` 的项目（如 `group.com.apple.notes`、`243LU875E5.groups.com.apple.podcasts`），以及 `AddressBook`、`CallHistoryDB`、`Knowledge`，连同其中内容 | 系统数据，不能移到废纸篓 | D54 写的是 `com.apple.*`；苹果的群组容器名带前缀，按 D54 的意图一并识别 |
| ① | 本应用三个身份的数据目录：`Application Support/StorageCleanerMac`、`Application Support/StorageCleanerMac-Beta`、`Caches/StorageCleanerIntegration-*`，以及当前身份的数据目录和它的每一级上层 | 本应用的数据 | 名称取自 `AppDataDirectories` |
| ① | `~/.ssh`、`~/.gnupg`、`~/.aws`、`~/.azure`、`~/.kube`、`~/.docker`、`~/.config/gh`、`~/.config/gcloud`、`~/.netrc`，连同其中内容 | 密钥与凭据，不能移到废纸篓 | — |
| ② | `~/Library` 第一层的每个文件夹（`Library` 本身仍是“系统标准文件夹”） | 资源库文件夹，不能整个移走 | 里面的项目按规则可选；第一层的**文件**不在 D54 ② 之内，按其他规则 |
| ② | `Containers/<应用>`、`Group Containers/<应用>` 及其 `Data` 文件夹 | 应用容器，不能整个移走 | 里面的项目按规则可选 |
| ③ | 含正在运行的应用包的文件夹（任何位置，含外接卷） | 含正在运行的应用 | 应用包本身仍是“应用”；回执跳过原因 `relatedAppStillRunning` |
| ③ | 含挂载点（其他磁盘或磁盘映像）的文件夹 | 含其他磁盘的挂载点 | 挂载点本身不在索引里（走树不跨卷） |
| ⑤ | 含上述受保护位置的文件夹（目前只有 `~/.config` 会落到这一条） | 含受保护的位置 | ①的其他位置的上层本来就是“资源库文件夹”“系统标准文件夹”或个人目录 |
| ④ | 有其他硬链接的文件 | 审阅框：另有硬链接，移走后空间不一定释放 | 只提示，不阻止；文件夹不提示 |
| — | `Application Support/MobileSync/Backup/<各份备份>`（以及 `MobileSync`、`Backup`） | 可勾选 | D54 明确保留 |

③ 的读取时机：运行中的应用（`NSWorkspace.runningApplications` 的 `bundleURL`，在主线程读）和挂载点（`getmntinfo_r_np`）在分析结束时读一次，之后**每次点勾选框、每次请求审阅**再读；审阅时每个文件夹再读挂载点，移动前每个文件夹再读运行中的应用。已勾选的项目因此变得不可选时自动取消勾选，底栏写“已取消勾选“Build”：含正在运行的应用。”。

### 9.2 P2 修复

- **P2-1（`27d399a`，只加测试）**：复核员 E1–E3 改写后并入 `FileAnalysisTrashTests`（条目、父目录、所选文件夹在审阅后被换成链接或改名：什么都不移、什么都不跟随）。两处路径检查各有一个单独兜住的测试：审阅前父目录换成链接，只有服务的检查（`FileAnalysisTrashService.check` 的 `hasSymbolicLinkComponent`）能发现；服务最后一次检查之后、移动之前换成链接，只有回执层（`RecordedTrashOperation` 的 `validate`）能拒绝（用一个在指定一次快照之后再换的夹具元数据实现）。
- **P2-2**：回执中途写不进时，结果对象记 `receiptIncomplete`，底栏写“回执未写完，请在“操作记录”中核对：……”，结果行用警示图标，没处理到的项写“操作记录写入失败，已停下，未处理”，不再写“可在操作记录中恢复”。
- **P2-8**：停止后，回执里“未处理”的项保持勾选，可以直接再审阅。
- **P2-9**：移动结束后，若高亮、路径栏、快速预览或悬停指向已移走的项（或已移走文件夹里的项），一律清掉。
- **P2-10**：开始移动失败时写“没能开始移到废纸篓：后台任务的状态有变化，没有移动任何项目，请再试一次。”，原始错误只放在审阅框的“详情”里（可选中复制）；忙碌冲突仍用原有的中文说明；取消审阅清掉底栏的旧提示。
- **P2-11**：行内说明放不下时换到下一行（最多两行，再长才在中间省略，悬停看全文），“随‘Old Projects’移走”在 1280 宽度下完整显示；进度里“正在与分析结果比对‘X’”在标题变化时立即送出（原来同一进度 0.1 s 内会被丢掉）。
- **P2-12**：分析刚结束、iCloud“桌面与文稿”（外接卷则是只读状态）还没判定时，桌面、文稿里（外接卷上全部）的项目显示时钟和“检查中”，点了不勾并说明原因，“审阅并移到废纸篓”也要等判定回来；判定回来后按规则显示，已勾选而变得不可选的项自动取消并说明。

### 9.3 测试：红、绿、反证

实现仍先于测试写成，红由反证给出：用 `~/Developer/.sc-build/r2-file-analysis-trash/fix-mut/mutate.py` 每次只撤回一项修复（测试保留），即等于修复前的行为；跑完逐字节还原（还原前后 `git diff` 的 sha256 相同）。

| 撤回的修复 | 失败的测试（行） | 日志 |
|---|---|---|
| ① `~/Library` 系统文件夹 | `testSystemDataAndCredentialsAreKeptWholeWithEverythingInside`（34、35、40，E15 名单 9 项） | `logs/fixmut-X.log` |
| ① 共享文件夹里的苹果条目 | 同上（44、45 各 12 处，49，E15 名单） | `logs/fixmut-Y.log` |
| ① 凭据 | 同上（54、55，E15 名单 `.ssh`） | `fixmut-Y.log` |
| ① 各身份数据目录 | 同上（62、63，E15 名单） | `fixmut-Y.log` |
| ② 资源库第一层 | `testLibraryFoldersAndAppContainersAreNotMovedWhole`（79） | `fixmut-X.log` |
| ② 应用容器 | 同上（85、86、89） | `fixmut-Y.log` |
| ⑤ 含受保护位置 | 同上（92） | `fixmut-Y.log` |
| ③ 运行中的应用（规则） | `testAFolderHoldingARunningAppOrAMountPointIsNotMovedWhole`、`testAnAppThatStartsInsideAFolderAfterTheReviewKeepsTheFolder`、`testACheckedFolderWhereAnAppStartsIsUncheckedWithTheReason` | `fixmut-X.log` |
| ③ 挂载点（规则） | `testAFolderHolding…`（114、125）、`testTheReviewReadsMountPointsAgain` | `fixmut-Y.log` |
| ③ 审阅时重读挂载点 | `testTheReviewReadsMountPointsAgain` | `fixmut-X.log` |
| ③ 移动前重读运行中的应用 | `testAnAppThatStartsInsideAFolderAfterTheReviewKeepsTheFolder` | `fixmut-Y.log` |
| ③ 规则变化后取消勾选 | `testACheckedFolderWhereAnAppStartsIsUncheckedWithTheReason` | `fixmut-Y.log` |
| ④ 硬链接提示 | `testTheReviewSaysWhenAFileHasOtherHardLinks` | `fixmut-X.log` |
| P2-1 服务的路径检查 | 只有 `testAParentReplacedByALinkBeforeTheReviewIsCaughtByTheReview` 失败 | `logs/fixmut-service-link-check.log` |
| P2-1 回执层的路径检查 | `testAParentReplacedByALinkAfterTheLastCheckIsRefusedByTheReceiptLayer`（真实文件经链接被移进夹具“废纸篓”），另有既有的 `RecordedTrashRecoveryTests` 1 处（它的夹具在 `/var` 下，碰巧带链接成分） | `logs/fixmut-rto-link-check-2.log` |
| P2-2 | `testAReceiptThatCannotBeWrittenMidwayStopsTheMoveAndThePageSaysSo` | `fixmut-Y.log` |
| P2-8 | `testStopKeepsWhatWasNotReachedChecked` | `fixmut-X.log` |
| P2-9 | `testAMovedHighlightIsDropped` | `fixmut-X.log` |
| P2-10 取消清提示 | `testAMoveThatCannotStartSaysWhyAndCancellingClearsIt` | `fixmut-Y.log` |
| P2-11 进度标题 | `testTheRowNoteWrapsAndANewFolderShowsAtOnce`（中继断言）；`testStopKeeps…` 的等待在负载下不稳定，不作为证据 | `fixmut-Y.log` |
| P2-11 行高 | 同上（源码契约） | `fixmut-Y.log` |
| P2-12 检查中 | `testItemsWaitWhileICloudIsBeingCheckedAndFollowTheAnswer` | `fixmut-X.log` |

分步提交各自编译并通过：只有 D54 的一步（`4ad242e`）本批 6 类 40 个，0 失败（`logs/stage1-tests.log`）；加上 P2 的一步 8 类 61 个，0 失败（`logs/stage2-tests.log`）。

### 9.4 截图（改前／改后，深浅色）

- 方法：`003d09f` 给截图管线加了 `--capture-file-analysis-protected=<夹具>`（只接受家目录下 `.storage-cleaner-` 开头的隐藏文件夹）。夹具的 `Home` 当作个人目录（自带 `Library`、`.ssh`、`.config`、`Build/…/Demo.app`、`Mounts/Disk`、桌面、文稿等），`Receipts`、`Trash` 是夹具回执日志和夹具“废纸篓”；运行中的应用和挂载点由夹具环境给出；iCloud 判定由夹具环境扣住，以拍到“检查中”。唯一的移动是把夹具里的 `photo.jpg` 移进夹具“废纸篓”（为了拍“回执未写完”），`clip.mov` 因回执失败未处理；脚本核对后删除夹具。
- 改前：`f37b9ef` 导出源码，只加同一个截图钩子（不含本轮修复；`showTrashMoveFailureForCapture` 按 `f37b9ef` 当时的写法显示 `error.localizedDescription`），可执行文件放进同一个包副本；改后：`003d09f` 的 Debug 包（`BuildInfo` commit `003d09fad60f`、dirty false）。两者 `minos 14.0`、`sdk 27.0`，隔离身份 `com.local.StorageCleanerMac.integration`。
- 语言、外观、显示方式都用启动参数传入（`-app.language zhHans -app.appearance light|dark -AppleLanguages ("zh-Hans") -storage-analysis.display-mode visualMap`），脚本和钩子都不写偏好；结束时核对该域：`AppleLanguages = ("zh-Hans")`，没有 `app.language`、`app.appearance`、`storage-analysis.display-mode`（`logs/capture-review-fixes.log`）。
- 脚本 `~/Developer/.sc-build/r2-file-analysis-trash/capture-review-fixes.sh`，并排图由 `compose-review-fixes.py` 生成。图在 `~/Developer/.sc-build/r2-file-analysis-trash/review-fixes-shots/`：`{before,after}-{light,dark}/fb-*.png`，并排对照 `side-by-side/{light,dark}-fb-*.png`。

| 图 | 内容 | 改前 | 改后 |
|---|---|---|---|
| `fb-1-home-reasons` | 个人目录根 | `Build`、`Mounts`、`.config`、`.ssh` 都能勾 | 锁＋“含正在运行的应用”“含其他磁盘的挂载点”“含受保护的位置”“密钥与凭据，不能移到废纸篓” |
| `fb-2-desktop-checking` | iCloud 判定回来前的桌面 | 能勾 | 时钟＋“检查中” |
| `fb-3-library-reasons` | `Library` | 全部能勾 | “资源库文件夹，不能整个移走”“系统数据，不能移到废纸篓”（两行） |
| `fb-4-containers-reasons` | `Library/Containers` | 能勾 | `com.apple.mail`“系统数据…”、`com.example.tool`“应用容器，不能整个移走” |
| `fb-5-inside-checked-folder` | 已勾文件夹里面 | “随“Old Proj…”“随…” | “随“Old Projects”移走”完整显示 |
| `fb-6-review-hard-link` | 审阅框 | 无提示 | “另有硬链接，移走后空间不一定释放” |
| `fb-7-move-did-not-start` | 开始移动失败 | “未能完成操作。（StorageCleanerMac.HeavyWorkCoordinator.Error 错误 1。）” | 中文说明＋“详情” |
| `fb-8-after-cancel` | 取消审阅后 | 底栏仍留着上面那句英文内部错误 | 没有旧提示 |
| `fb-9-receipt-incomplete` | 回执中途写不进 | 绿色“已移到废纸篓 1 项…”＋“可在操作记录中恢复”＋“未处理” | 警示图标＋“回执未写完，请在“操作记录”中核对…”＋“操作记录写入失败，已停下，未处理” |

截图看不到的：真实悬停、实机的 TCC 行为、真实运行的应用和真实挂载、真实 iCloud。另外深浅色各有几轮窗口不是活动窗口（按钮、分段控件变灰），与本轮无关。

### 9.5 门禁（`003d09f`，代码最终状态）

环境同第 6 节；日志在 `~/Developer/.sc-build/r2-file-analysis-trash/logs/`，脚本 `gates-review-fixes.sh`，汇总 `rf-gates.log`（负载 4.9 → 7.5）。

| 步骤 | 命令 | exit | 结果 | 日志 |
|---|---|---|---|---|
| Debug 编译（主目标＋测试） | `swift build --build-tests` | 0 | 唯一警告为既有 `BrowserPrivacyRecoveryTests.swift:474` | `rf-gate-debug-build.log` |
| 本批 3 类（单独跑，计偏好与缓存） | `swift test --skip-build --filter 'StorageCleanerMacTests\.(FileAnalysisTrashTests\|FileAnalysisTrashStoreTests\|FileAnalysisTrashProtectedScopeTests)'` | 0 | 36 个，0 失败；`~/Library/Preferences` 229,143 → 229,143，期间非 Apple 前缀的偏好文件新建或改动 0 个；`~/Library/Caches` 顶层 104 → 104；家目录夹具 0 | `rf-gate-d46.log` |
| 定向测试（本批相关 19 类：上面 3 类、存储图、迟到工作线程、搬家回执、操作记录、回执与恢复、文件页 store、矩形图布局、界面一致性等） | `swift test --skip-build --filter '<19 类>'` | 0 | 435 个，跳过 1（`SystemUtilitySafetyTests` 的 Setapp 实机清点，需显式开关），0 失败 | `rf-gate-targeted.log` |
| 严格并发（主目标＋测试目标） | `swift build --build-tests -Xswiftc -strict-concurrency=complete`（在 `f161093` 时全新编译过的 `strict2` 上增量编译） | 0 | 0 错误；唯一警告为既有 `BrowserPrivacyRecoveryTests.swift:474`；本批文件 0 警告；49.6 s | `rf-gate-strict.log` |
| 私有 API | `python3 script/check_private_api.py` | 0 | passed (6 allowlisted uses)；新用到的 `getmntinfo_r_np` 是公开的 libc 接口 | `rf-gates.log` |
| `verify.sh` 的源码检查 | 同第 6.2 节 | — | 都没有匹配 | `rf-gates.log` |
| 空白检查 | `git diff --check`；`git diff --check b666fe3 HEAD`（本轮）；`git diff --check 7401e72 HEAD` | 0；0；**2** | 最后一项唯一的命中是 `docs/2.0.0/UI-V2-SPEC.md:61` 行尾空格，来自集成分支自己的 `2017cfb`（`git diff --check 7401e72 integration/2.0.0-beta` 同样 exit 2），由 `b666fe3` 合入；排除该文件后 exit 0。本批没有改这个文件，请主会话决定是否在集成分支修 | `rf-gates.log` |

NOT RUN：Debug 全量（按本轮“只跑定向测试和必要门禁”）、Release、`script/verify_menu_bar_performance.sh`、打包安装、实机。

### 9.6 只改文档的两项与更正

- **P2-6 固有竞态**：文件夹的整树比对只在移动前的第一次核对时做，第二次（紧挨着移动）跳过；比对结束到真正移动之间新增到该文件夹里的内容会随文件夹一起进废纸篓（复核 E14 证实）。窗口只有一次回执落盘加几次 actor 切换，量级是毫秒；移走的仍在用户勾选的文件夹里，可以从“操作记录”放回。接受这个竞态；如要再收紧，可在第二次核对时只比对顶层目录项。
- **P2-7**：见 1.2 的更正（移动路径会写时复制两个字典，代价是毫秒级，不是“几百 MB”）。
- 其余 3 处不实说法已在原处更正：5 节截图表 `fa-1` 的“符号链接”“测量不完整”无截图证据；5 节“深色的系统外观”应为“窗口不是活动窗口”；1.3 与 8 节漏了 `~/Library` 中的受保护位置（现由 9.1 补齐）。

### 9.7 仍未解决与风险

1. 外接卷仍不能从“操作记录”恢复（第 8 节第 1 条，未变）。
2. 运行中的应用和挂载点只在上述时机读取，没有订阅系统通知：两次点击之间启动的应用，页面上要到下一次点击或审阅时才显示；审阅与移动前的核对总会发现。
3. 硬链接只对文件提示；含硬链接文件的文件夹不提示，地图仍按分析时的字节减（第 8 节第 2 条）。
4. P2-6、P2-7 按要求只改文档，代码未改。
5. 规则挡住了 `~/Library` 中的这些位置，所以真实 `trashItem` 对 TCC 保护目录的行为没有、也不需要实测；规则以外的 `~/Library` 子项（如 `Caches/<应用>`）可以移动，是否会被 TCC 拒绝仍待实机。
6. 截图钩子的两个 store 方法（换环境、显示开始失败）与截图管线一样在 `DEBUG || STORAGE_CLEANER_BETA` 下编译，只有带截图启动参数且夹具在 `~/.storage-cleaner-*` 时才会走到。
7. 本轮按要求只跑定向测试和必要门禁，**Debug 全量 NOT RUN**；实机 NOT RUN（第 7 节第 10–13 条为本轮新增）。
8. JEV 第二轮 `jev_review` 仍是 escalate（6.4），没有指出具体缺陷，测试缺口一项置信度只有 0.30；不视为批准。
