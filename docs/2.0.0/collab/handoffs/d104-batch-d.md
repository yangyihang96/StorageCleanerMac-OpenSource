# d104-batch-d：竞品逆向改进 D 批（只评估），补做 A 批的 G1、G5

批次：D / D104。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`。本批全部改动未提交，与 D98–D103、D105 的未提交改动在同一工作区。计划文件是 `~/Claude 好玩的/Mac清理与监控软件逆向-2026-10-15/2.0.1改进计划.md`。各项的产品决定见 DECISIONS D104，本文只记实现、测试、证据和未完成的部分。C 批的复核返修（D105）在本批进行中完成，记在 `d105-review-c-fixes.md`；两者改的文件没有重叠。

D 批计划只有 G11、G12 两项评估。用户与 Codex 要求（CODEX_B_RECHECK_20261015_1345：“G1 文件分析/大文件预计释放和 G5 只补扫新授权位置，不能仅记为‘延后’就算全部完成”）把 A 批记为偏差的 G1、G5 在本批补做。

本批没有做以下事情：提交、合并、安装、重启、启动 App、对真实数据执行清理或移动、写风扇／电源模式／SMC。G1、G5 的测试只用夹具、临时目录和假读取器。接触本机真实路径的只有 G12 的只读元数据遍历（见 G12 一节；Codex 指出那部分不是夹具验证，按原样标注）。

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-d/`。

## 完成项

| 项 | 改动 | 测试 |
|---|---|---|
| G5 | 授权横幅的按钮改为“重新扫描这些位置”：只运行本次结果里读不到、现在可读的那几条规则，结果并入同一次扫描；规则有变化时按 A-R3 整体重扫原会话的范围 | 新增 `ScanSessionRescanMergeTests` 8 项；`ScanAccessReturnTests` 新增 4 项；`CleanupRuleScannerTests` 新增 2 项（其中 1 项用真实扫描器和拒绝读取的夹具文件系统，验证被拒绝的规则保留空分组，补扫后并入同一会话） |
| G1 项目产物 | 测量产物时逐个普通文件读共享属性，行内和移动确认注明清空废纸篓后预计释放；执行前复查不额外读取 | `ProjectArtifactTests` 新增 1 项；移动确认与扫描结果共用的那句话由 `ReclaimableOutsideCleanupScanTests` 1 项直接测试 |
| G1 大文件列表 | 列出后对每个文件读一次共享属性（文件夹不读），迁移页的行在大小下面写“可释放 X”，说明里写原因 | `ReclaimableOutsideCleanupScanTests` 1 项 |
| G1 重复文件 | 内容完全相同的组算出“一定能释放”的量，页面的“物理可释放”由此显示，不再一律“待确认” | `DuplicateFileScannerTests` 新增 3 项，2 项改期望值（见下文） |
| G1 文件分析移到废纸篓 | 复查时对就绪、没有其他硬链接的文件读共享属性；条目和确认页写出预计释放 | `ReclaimableOutsideCleanupScanTests` 4 项 |
| G12 | `getattrlistbulk` 与现有逐项读取的基准对比，只评估 | 证据 `batch-d/g12/` |
| G11 | 计划写“先问用户要不要做”，本批没有做 | — |

## G5：只扫描新可读的位置

- **入口**：`ScanStore.rescanAfterAccessReturn()`。只在横幅属于当前结果时生效。要扫的规则是这次结果里读取状态为“无权限”、路径在横幅列出的可读位置中的那些（`ScanSession.deniedRuleIDs(at:)`）。
- **改为整体重扫的情形**（沿用 A-R3：按已完成会话记录的范围，不读也不改扫描偏好）：没有符合的规则；现在的规则与会话扫描时的版本或指纹（D82）不同；会话中的某条规则已不在规则里；规则迁移没有完成。
- **扫描**：与普通扫描相同的重活租约（`.mainScan`）和进度页；请求只含这些规则，用会话自己的开发者不活跃天数和当前的排除项。扫描器新增 `CleanupScanRequest.sessionID`，扫描结果属于原会话（行的 ID 本来就不依赖会话）。
- **并入**（`ScanSession.mergingRescan(_:ofRules:)`，新文件 `ScanSessionRescanMerge.swift`）：
  - 只并入属于同一会话、未取消、规则版本和指纹相同、并且报告了其中至少一条规则的扫描；否则返回 nil，结果不变。
  - 补扫报告到的规则：该规则的行、读取报告和问题整体替换为新的；补扫没有报告到的规则保留原来的报告，仍算没读到。
  - 新行与已列出的行是同一文件（身份相同）、在其内部或包含它时不再列出，记一条去重问题（`hardLinkDeduplicated`），与一次扫描中两条规则碰到同一文件的处理相同。已列出行内部的文件与新行内部的文件之间的硬链接不重新读取，无法匹配；整体重扫可以。
  - 统计：遍历数、耗时等相加；行数、大小、测量完整度按并入后的行重算；结果是否完整与扫描器用同一判断（`ScanIssueKind.limitsScanCoverage`，从扫描器的判断中提出来共用），仍有读不到的位置时为“部分”。
- **选择**：已选和已取消的行保持不变，只有新加的行按 D47 默认勾选（`CleanupSelection.addingDefaults(forRowsAddedTo:in:)`）。已生成的清理计划和试运行在开始扫描时就清掉，与普通扫描相同。
- **不另记扫描历史**：补扫不写第二条扫描历史，结果仍是原来那一次扫描。
- **停止或失败**：扫描结果和选择不变（清理计划和试运行已在开始时清掉，需要重新生成），横幅重新出现，提示“已停止扫描新位置，结果保持不变，未改动任何文件”或“没能把新位置加入本次结果……可以再试一次”。
- **文字**：横幅改为“现在可以读取：……。本次结果没有包含这些位置；扫描这些位置后会加入本次结果，其他结果不重新扫描。”完成后提示“已扫描新可读的位置并加入本次结果”，仍有位置读不到时另加说明。

## G1：扫描结果以外的预计释放

口径与 A 批（含返修 A-R1、A-R2）相同：与 APFS 克隆共享或被本地快照占用的块一律不计入预计释放；只有“明显”时才写出（保留的部分 ≥1 MiB 且 ≥ 大小的十分之一，`CleanupReclaimableEstimate.isNoticeable`）；读的是公开的 `getattrlist` 属性（`FileStorageSharing`），只读元数据，不读文件内容。

- **项目产物**（`ProjectArtifactScanner`）：测量产物时，对其中每个普通文件（按身份去重之后）读一次共享属性，按卷和克隆 ID 汇总成行的估计。只显示、不可选的行不保留估计。执行前的复查（`assess`）不读共享属性。行内用扫描结果同一句提示；移动确认的“动作”一行在大小后面写“清空废纸篓后预计释放 X”（与扫描结果的选择汇总共用 `CleanupSelectionReclaimable.note(ofSelected:)`）；页面底部说明改为“与 APFS 克隆共享或被本地快照占用的部分，清空废纸篓后也不会释放，明显时在行内注明预计释放量”。
- **大文件列表**（`LargeFilesStore`）：列出后在后台对列出的每个文件读一次（文件夹不读），按行 ID 存放，不改 `StorageItem`；取消时不保存。大文件列表所在的迁移页（按文件列出时；按应用列出时不显示）只在明显时在大小下面加一行“可释放 X”，口径说明里写原因。每行只用自己的估计，不需要跨行匹配克隆，所以这里不需要卷信息。
- **重复文件**（`DuplicateFileScanner`）：内容完全相同的组，在列表确定之后，对列出的每一份读“删除它一定能释放的量”：没有其他硬链接时取私有块（`FileStorageSharing` 的私有字节，卷不报告共享时取 `st_blocks × 512`），有其他硬链接时为 0，读不到为未知；不跟随符号链接。组的量是“各份之和减去最大的一份”，即不论保留哪一份都能释放的量；任何一份未知，整组未知。互为克隆的组因此约为 0。页面的“物理可释放”（组内标签和顶部合计）原来一律“待确认”，现在由此显示；有组未知时合计仍为“待确认”。
- **文件分析移到废纸篓**（`FileAnalysisTrashService.review`）：复查时，对已就绪、不是文件夹、没有其他硬链接的文件读一次共享属性，估计里带文件所在卷的设备号，确认页跨文件匹配克隆组时不会把两个卷上相同的克隆 ID 当成一组。条目说明写“清空废纸篓后预计释放 X；其余与其他文件共享存储（克隆）”等；确认页的容量一行写“其中 X 移到废纸篓；清空废纸篓后预计释放 Y，所选完整克隆另可能释放 Z；与 APFS 克隆共享或被本地快照占用的部分不释放”，有文件夹时加“；文件夹按完整大小计”。所选项目里有其他硬链接时沿用原来的“最多释放”（D93 P1-2），不给出估计。不明显时文字与原来相同。
- **共用部分**：`CleanupReclaimableEstimate.file(_:allocatedBytes:deviceID:)`（单个文件的估计）、`CleanupSelectionReclaimable(items:)`（扫描结果以外的项目汇总）、`CleanupCandidateRowHint.reclaimable(_:ofSize:format:)`（行内提示，按页面自己的字节格式）。

**测试期望值的改动**（不是放宽断言，是本项要改变的行为）：
- `DuplicateFileScannerTests.testDifferentNamesWithSameContentShareVerifiedGroupAndSavingsRemainUnknown` 改名为 `...AndFreeOneCopysBlocks`：原来断言“物理可释放”为 nil（未知），现在断言等于一份的 `st_blocks × 512`。
- 同文件的克隆组用例：原来断言 nil，现在断言 0（克隆共享全部块，删除一份几乎不释放）。

## G12：元数据层基准测试（只评估）

详见证据 `batch-d/g12/README.md`。要点：
- 同一棵目录树，`getattrlistbulk`（bulk）与现在的读法（`contentsOfDirectory`＋逐项 `lstat`＋普通文件 `getattrlist`）读到的结果完全相同；中夹具（21,553 个条目）和 Xcode 包上，bulk 墙钟少 9%–34%，不做包含检查时约三分之一。
- 扫描器对每个条目做的两次路径包含检查是这一层最大的开销；根目录的两种形式每次遍历只算一次时，现有读法少 14%–31%。
- **范围**：运行矩阵除两个自建夹具外，还遍历了 `/Applications/Xcode-27.0.0-Beta.app`（01:12:50–01:16:05）和 `~/Library/Caches`（01:16:05–01:33:12），12 次全部 exit 0。Codex（CODEX_G12_SCOPE_20261015_1428）指出这两条不是隔离夹具验证。它们是只读元数据观察（列目录、读元数据，没有打开文件读写，没有清理、删除或移动），按原样保留范围、时间和退出码，单独列表；此后没有再安排真实路径的测试。`~/Library/Caches` 三次汇总都不相同，推断是目录在两次遍历之间有变化（没有另外验证）。
- 本批不改产品代码，也没有为此改测试阈值；是否在 2.0.2 采用由用户另行决定。

## G11：没有做（先问用户）

计划原文：“柠檬、CleanMyMac 有这项功能，全仓没有 MobileSync 相关代码。需要完全磁盘访问。只显示每个备份的设备名、日期和大小，引导用户到访达里管理；App 里不提供删除，因为备份可能是唯一副本。先问用户要不要做。”本批没有实现，等用户决定。

## 自测：验证（原始日志）

以下全部是本会话的自测，在工作区运行，`--scratch-path` 为任务临时目录，`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`。每次测试都带只读窗口监视器，记录到的窗口数都是 0。

| 检查 | 时间（2026-10-16） | 实际结果 | 日志（`batch-d/logs/`） |
|---|---|---|---|
| 编译 | 01:50:40–01:53:12 | exit 0（G5、G1 的源码和测试的第一版） | `build-d1.*` |
| 编译 | 02:30:52–02:32:10 | exit 0（G1 新测试）；新测试里有 1 处多余的 `try` 警告，另一条 `ProjectArtifactTests.swift:163` 的警告在 A 批开始前就有 | `build-d4.*` |
| 编译 | 02:32:43–02:32:54 | exit 0（去掉那个多余的 `try`） | `build-d5.*` |
| G1 新测试 | 02:32:58–02:33:17 | **54 个，4 处断言失败，exit 1**，都在新测试 `ProjectArtifactTests.testListedRowsReadSharingAndTheMoveCheckDoesNot`：测试里的假读取器按 `/var/…` 存放假读数，扫描器读的是解析链接后的 `/private/var/…`，所以没有读到假读数。这是测试写法的问题：假读取器和期望值改为两边都按解析链接后的路径比较，断言本身没有改，产品代码没有改 | `d104-g1-new.*`（原样保留） |
| 编译 | 02:33:57–02:34:07 | exit 0 | `build-d6.*` |
| G1 新测试重跑 | 02:34:07–02:34:23 | 54 个，0 失败，exit 0 | `d104-g1-new2.*` |
| D104＋D105 定向测试 | 02:35:26–02:36:02 | 49 个套件 621 个，跳过 3，0 失败，exit 0 | `d104-d105-t1.*` |
| 反证第 1 轮 | 02:40:18–02:53:24 | 34 项中 33 项符合预期，G1e 不符合（见“反证”） | `counterproof-d104-run1.log` 等 |
| 编译 | 02:56:38–02:57:11 | exit 0；新加的直接测试调用了主线程隔离的方法，4 条警告 | `build-d7.*` |
| 编译 | 02:57:17–02:57:26 | exit 0，0 条警告（该测试标为 `@MainActor`） | `build-d8.*` |
| 定向测试 | 02:57:29–02:57:48 | 4 个套件 79 个，0 失败，exit 0（过滤串里的 `CleanupScanViewTests` 并不存在，没有匹配） | `d104-g1e-fix.*` |
| 反证第 2 轮 | 02:59:42–03:13:25 | 36 项全部符合预期，exit 0；副本前后清单相同 | `counterproof-d104.log`（三轮依次追加，第 2 轮从 “started 2026-10-16 02:59:42” 一行开始）、`d104-counterproof-run2.*` 等 |
| 编译 | 03:13:39–03:15:02 | exit 0，0 条警告（新增真实扫描器测试；同时编入 D105-R1 的修复） | `build-d9.*`（在 `review-c-fixes/logs/`） |
| 定向测试 | 03:15:10–03:15:17 | 7 个套件名中 6 个存在，122 个，跳过 2，0 失败，exit 0，其中新的真实扫描器测试通过 | `d105r1-t1.*`（在 `review-c-fixes/logs/`） |
| 反证第 3 轮 | 03:17:10–03:18:13 | 只跑新加的 G5o：符合预期（2 处断言失败），exit 0；副本前后清单相同 | `counterproof-d104.log`（“started 2026-10-16 03:17:10” 起）、`d104-counterproof-run3.*` |

## 自测：反证

在工作区的逐字节副本（`d-cp`，不含 `.build`）上运行，每轮建立副本时都与当时工作区的清单相同（第 1 轮 1,739 个文件，第 2、3 轮 1,740 个）。每轮先跑基线：第 1 轮 6 个套件 163 个测试、第 2 轮 164 个（多了下面说的直接测试）、第 3 轮只跑 `CleanupRuleScannerTests` 46 个，都是 0 失败、跳过 2（本机采集测试）；删除与进程清单检查通过（155 条、246 处）。之后每项改动一处源码，只跑守护它的测试，预期失败（`H1`–`H3` 是等价写法，预期通过）；每项结束后从备份逐字节恢复并核对哈希，全部为 OK，每轮结束时副本的完整清单与开始时相同。窗口监视器记录到的窗口数都是 0。所有“失败”都是断言失败，不是编译错误（日志里每项都有对应的 `error: -[...]` 行）。

- **第 1 轮**（02:40:18–02:53:24，34 项）：33 项符合预期。**G1e 不符合**：这一项本想证明“行内提示按页面的字节格式”，但锚点落在了 `CleanupSelectionReclaimable.note(ofSelected:format:)` 上。核对后发现这个 `format:` 参数是本批新加的，两处调用方（扫描结果的选择汇总、项目产物的移动确认）都用默认值，改掉它不改变任何行为，所以测试不失败是对的；同时也说明这句选择汇总的文字没有直接测试（A 批只有源码检查）。处理：删去这个没有用到的参数；新增直接测试 `ReclaimableOutsideCleanupScanTests.testTheSelectionNoteSaysWhatEmptyingTheTrashFreesWhenItIsNoticeablyLess`（含项目产物页的 `reclaimableNote`）；G1e 改为改动行内提示 `CleanupCandidateRowHint.reclaimable` 里的 `format(freed)`；新增 G1g、G1h 守护选择汇总。第 1 轮的日志原样保留（`counterproof-d104-run1.log`、`d104-counterproof-run1.*`、`counterproof_d104-run1.py`）。
- **第 2 轮**（02:59:42–03:13:25，36 项）：全部符合预期。
- **第 3 轮**（03:17:10–03:18:13）：本批新加了一项用真实扫描器的测试（`CleanupRuleScannerTests.testANewlyReadableRuleScannedAsPartOfTheSessionJoinsItsResults`），并入依赖“被拒绝的规则仍有一个空分组”这一点，此前只有模拟扫描器的夹具体现。G5o 把扫描器改成不列出空分组，测试 2 处断言失败，符合预期。只跑这一项。第 2、3 轮之间改动的文件是：`FanControlCoordinator.swift` 和 `HardwareAutomaticRestoreTests.swift`（D105-R1，见 `d105-review-c-fixes.md`）、`CleanupRuleScannerTests.swift`（只新增上面这项测试，G5m 守护的测试没有变）和 A 批交接文档；其他各项守护的源码和测试都没有改动。

下表为第 2 轮的 36 项加第 3 轮的 G5o：

| 项 | 改动 | 守护测试 | 预期 | 结果 |
|---|---|---|---|---|
| G5a | 补扫到的行与已列出的行相同、在其内部或包含它时仍再列出 | `ScanSessionRescanMergeTests` | 失败 | 失败 |
| G5b | 只去掉“在已列出行内部”的判断 | 同上 | 失败 | 失败 |
| G5c | 只去掉“包含已列出行”的判断 | 同上 | 失败 | 失败 |
| G5d | 补扫的规则保留原来的问题 | 同上 | 失败 | 失败 |
| G5e | 补扫没有报告到的规则也丢掉原报告 | 同上 | 失败 | 失败 |
| G5f | 其他会话的扫描也并入 | 同上 | 失败 | 失败 |
| G5g | 规则版本不同的扫描也并入 | 同上 | 失败 | 失败 |
| G5h | 仍有读不到的位置时结果仍算完整 | 同上 | 失败 | 失败 |
| G5i | 新加的行不按默认勾选 | 同上 | 失败 | 失败 |
| G5j | 默认勾选覆盖之前的选择 | 同上 | 失败 | 失败 |
| G5k | 按钮仍整体重扫原会话 | `ScanAccessReturnTests` 1 项 | 失败 | 失败 |
| G5l | 规则有变化时仍只扫新位置 | `ScanAccessReturnTests` 1 项 | 失败 | 失败 |
| G5m | 扫描器不用请求里的会话 | `CleanupRuleScannerTests` 1 项 | 失败 | 失败 |
| G5n | 停止扫描新位置后横幅不再出现 | `ScanAccessReturnTests` 1 项 | 失败 | 失败 |
| G5o | 扫描器不列出没有找到任何行的规则的分组（并入依赖被拒绝的规则仍有分组） | `CleanupRuleScannerTests` 1 项（真实扫描器） | 失败 | 失败 |
| G1a1 | 项目产物不读共享属性 | `ProjectArtifactTests` 1 项 | 失败 | 失败 |
| G1a2 | 移动前的复查也读共享属性 | 同上 | 失败 | 失败 |
| G1a3 | 文件夹也读共享属性 | 同上 | 失败 | 失败 |
| G1a4 | 只显示、不可选的行也保留估计 | 同上 | 失败 | 失败 |
| G1b1 | 大文件列表也读文件夹 | `ReclaimableOutsideCleanupScanTests` 1 项 | 失败 | 失败 |
| G1b2 | 大文件列表丢掉读到的估计 | 同上 | 失败 | 失败 |
| G1c1 | 重复文件组的可释放量把保留的一份也算进去 | `DuplicateFileScannerTests` 1 项 | 失败 | 失败 |
| G1c2 | 有其他硬链接的一份计入自己的块 | `DuplicateFileScannerTests` 1 项 | 失败 | 失败 |
| G1c3 | 读不到的一份按 0 计，不再整组待确认 | 同 G1c1 | 失败 | 失败 |
| G1c4 | 克隆的一份计入共享的块 | 同 G1c2 | 失败 | 失败 |
| G1d1 | 复查也读有其他硬链接的文件 | `ReclaimableOutsideCleanupScanTests` 1 项 | 失败 | 失败 |
| G1d2 | 复查不带文件所在卷 | 同上 | 失败 | 失败 |
| G1d3 | 有其他硬链接的选择也给出估计 | `ReclaimableOutsideCleanupScanTests` 1 项（确认页） | 失败 | 失败 |
| G1d4 | 接近完整大小时也写出估计 | 同上 | 失败 | 失败 |
| G1d5 | 有文件夹时不说明按完整大小计 | 同上 | 失败 | 失败 |
| G1e | 行内提示不用页面的字节格式 | `ReclaimableOutsideCleanupScanTests` 1 项 | 失败 | 失败 |
| G1f | 扫描以外列出的项目按完整大小计 | `ReclaimableOutsideCleanupScanTests` 全部 | 失败 | 失败 |
| G1g | 选择汇总在几乎全部能释放时也写出 | `ReclaimableOutsideCleanupScanTests` 1 项（选择汇总） | 失败 | 失败 |
| G1h | 选择汇总不写所选完整克隆可能另外释放的量 | 同上 | 失败 | 失败 |
| H1 | 最大的一份改用 `if` 求（等价） | 同 G1c1 | 通过 | 通过 |
| H2 | 跳过文件夹改用 `continue`（等价） | 同 G1b1 | 通过 | 通过 |
| H3 | 读不到的规则改用 `lazy` 过滤（等价） | `ScanSessionRescanMergeTests` | 通过 | 通过 |

## 门禁（原始日志）

**结论：不开窗口的完整门禁通过（exit=0）。** 15 步全部 exit 0。这次门禁覆盖 D104 的 24 个文件和 D105（含 D105-R1）的 9 个文件。它只说明这一份代码在本机、不开窗口的条件下通过了 `script/verify.sh` 的各步；57 个会开窗口的测试类没有运行，界面、签名后的运行时和实机都没有验收（见“仍未通过、未做或待实机”）。

运行方式：03:24:55 把工作区冻结到 `d-gate-tree`（1,740 个文件，冻结时工作区的逐个文件哈希与副本一致，清单 SHA-256 `f2a9e921…`），在冻结副本上按 `script/verify.sh` 的步骤逐步运行（`verify_no_window_all.sh`），每步都跑完并记录 exit code。两次全量 `swift test` 跳过会开窗口的 57 个测试类，名单按冻结副本重新生成，与 C 批门禁相同（没有增减）。不构建 App 包，不启动 App（相当于 `STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`）。结束后冻结副本与开始时一致（`tree unchanged`）。开始负载 6.62 / 7.11 / 7.38，结束 6.41 / 7.63 / 8.58。门禁期间没有并行运行反证或基准测试；工作区只改了文档（BOARD、DECISIONS、C 批与 D105 的交接、本文），源码和测试与冻结副本相同。

| 步骤 | exit | 时间 | 结果 |
|---|---|---|---|
| bootstrap | 0 | 03:24:55–03:24:58 | |
| debug-build | 0 | 03:24:58–03:29:02 | |
| release-test | 0 | 03:29:02–03:41:56 | 执行 4,946 个，跳过 23 个，0 失败 |
| release-test-list | 0 | 03:41:56–03:41:57 | 测试清单 5,250 个 |
| concurrency-build | 0 | 03:41:57–03:45:54 | `-strict-concurrency=complete` |
| debug-test | 0 | 03:45:54–03:51:17 | 执行 5,056 个，跳过 24 个，0 失败 |
| guard-views-10 / guard-purge-11 / guard-shell-15 | 0 | 03:51:17–03:51:18 | |
| private-api-selftest / private-api | 0 | 03:51:18–03:51:20 | |
| inventory-selftest / inventory | 0 | 03:51:20–03:51:24 | L8 清单 155 条、246 处（与 C 批相同） |
| guard-conflicts-14 | 0 | 03:51:24 | |
| menu-bar-performance | 0 | 03:51:24–03:51:28 | 16 个，0 失败；准备阶段 p95 85.59 ms |

- **跳过的测试**：Release 23 个、Debug 24 个，与 C 批门禁逐个相同（`skipped-release-d.txt`、`skipped-debug-d.txt`）。
- **菜单栏计时项**：Release 全量测试中 p95 87.22 ms，最后的专门步骤 85.59 ms，阈值 100 ms。B 批门禁曾在这一项失败（112.91 ms），C 批时 98.83 ms；这次通过不能说明它不再受负载影响。阈值和断言都没有改。
- **测试数量**：C 批门禁的 Release 测试清单是 5,213 个，这次 5,250 个，净增 37 个（`test-list-c-vs-d.diff`：新增 38 个、去掉 1 个）。D104 新增 25 个：`ScanSessionRescanMergeTests` 8、`ReclaimableOutsideCleanupScanTests` 6、`ScanAccessReturnTests` 4、`DuplicateFileScannerTests` 4（新增 3、改名 1）、`CleanupRuleScannerTests` 2、`ProjectArtifactTests` 1；去掉的 1 个是 `DuplicateFileScannerTests` 改名前的那项。D105 新增 13 个：`HardwareAutomaticRestoreTests` 12（含 D105-R1 的 1 项）、Codex 的 `IndependentBatchCReviewTests` 1。执行数两边都多 37 个（Release 4,909→4,946，Debug 5,019→5,056）。
- **编译警告**：与 C 批门禁的警告逐条相同（`warnings-c.txt`、`warnings-d.txt`），没有新增，都不在 D104、D105 的文件里。
- **窗口**：只读窗口监视器在整个门禁期间开着，命令行包含验证目录的进程共 210 个，结束汇总是 0 个上屏窗口、0 次越界、0 个外来测试窗口（`gate-watch.jsonl`）。它看到测试进程 `xctest` 建立的 9 个窗口（14 条记录），都始终是 `onscreen=false`：Release 段 03:40:35 两个、Debug 段 03:49:32 两个，尺寸为 0，与 `MenuBarStatusPanelTests`／`MenuBarTertiaryDetailTests` 同时；Debug 段 03:50:41–03:50:42 五个，出现在 `SafeCleanupScopeCardLayoutTests` 运行期间，其中 4 个坐标在内建显示器范围内（x 0、y 158、宽 180–560、高 720），1 个尺寸为 0，都没有上屏。这与 A、B、C 批门禁的情况相同（C 批交接原先写成“都是 0×0、不落在任何显示器上”，与其监视记录不符，已在 `d102-batch-c.md` 更正）。监视器每 0.5 秒刷新一次进程、每 50 毫秒查看一次窗口，不能证明窗口没有在两次查看之间短暂显示；这也不是把窗口路由到“虚拟屏 1 · Codex”的证明。
- **空白检查**：门禁结束后 `git diff --check` exit 0；46 个未跟踪文件逐个检查没有问题，另有 `docs/COMPETITIVE_REVERSE_ENGINEERING_2026-10-14.md` 末尾多一个空行，开工前就有，按要求不改（`diff-check-post.log`）。

## JEV（辅助）

**JEV 复核**（辅助，不当作通过）：只传了 G5 的并入函数、商店里新流程的摘要和重复文件组的计算，以及自测摘要；没有传凭据或个人数据。结果：正确性 1.6/2（置信度 0.41）、规格符合度 1.84/2、测试缺口 0.89、影响面 1.78，`safe_to_apply` 0.39，判定 escalate（需要人工复核），没有指出具体缺陷。据此核对了并入所依赖的前提（扫描器为被拒绝的规则保留空分组），补了真实扫描器的测试和反证 G5o。结论交给 Codex 独立复核。

## 差异与哈希

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-d/`。`README.md` 说明各文件，`SHA256SUMS.txt` 覆盖目录内全部其他文件（含 `g12/`）。

- **起点**：`pre-d-tree` = HEAD `6e660a59` + C 批结束快照（`batch-c/snapshots/post-batch-C.diff` 与未跟踪文件包）。
- **D 批期间改动的全部文件**由批末快照列出（`snapshots/batch-D-files.txt`、`batch-D-delta.diff`、`batch-D-files.sha256`）：D104 的源码和测试 24 个、D105 的 9 个（见 `d105-review-c-fixes.md`）和文档。两组源码、测试没有共同文件。
- **只含 D104 的 24 个文件**：差异 `snapshots/d104.diff`（新文件以空文件为基准）；`snapshots/d104-files.sha256` 每行是“开工前 现在 路径”，开工前取自 `pre-d-tree`，新文件写 `absent`。源码 18 个（新增 `Models/ScanSessionRescanMerge.swift`），测试 6 个（新增 `ReclaimableOutsideCleanupScanTests.swift`、`ScanSessionRescanMergeTests.swift`）。源码最后修改于 02:56:15（去掉没有用到的 `format:` 参数），测试最后修改于 03:05:46（新增真实扫描器测试）；门禁冻结（03:24:55）之后没有再改源码和测试。

| 文件 | 开工前 | 现在 |
|---|---|---|
| `Sources/StorageCleanerMac/Features/DuplicateFiles/Models/DuplicateFileModels.swift` | `7a025936…` | `799419df3bb03cb0fef68e001a3b18ded944c63000fa2ec34575c67ea8e4fc5e` |
| `Sources/StorageCleanerMac/Features/LargeFiles/Models/FileAnalysisTrashModels.swift` | `47e3b25f…` | `19afaa69e85ce33843c681a2c21970e571aa239303e6ba51f30d4d979a391a97` |
| `Sources/StorageCleanerMac/Features/LargeFiles/Services/FileAnalysisTrashService.swift` | `f5f347c4…` | `79c73e676eba6ba0d1716a2d14805d5f5048e4d12c09946bb401cd84f717e35d` |
| `Sources/StorageCleanerMac/Features/LargeFiles/Stores/LargeFilesStore.swift` | `5c72622d…` | `fe60f52f7378b60649cba12943130d74ce82592966c3e352a629847632aab4a8` |
| `Sources/StorageCleanerMac/Models/CleanupReclaimableEstimate.swift` | `5282e302…` | `fd3035a5e3c2c3865e8011c7e88ff17966524eaec893a933281845ceadda797b` |
| `Sources/StorageCleanerMac/Models/CleanupScanModels.swift` | `e577c44e…` | `c742eeba2ba8fcd228d169510e2f41e39e520cc5622d8ce2e70ac32c399e099d` |
| `Sources/StorageCleanerMac/Models/OperationConfirmationModels.swift` | `642ed16b…` | `b21125efc25c949e2dd5d8b2aa3d76cfb4564055b0c608af420b5fe7a4a0c1ac` |
| `Sources/StorageCleanerMac/Models/ScanAccessReturn.swift` | `c7447b53…` | `a9951cf7db9567f9fe54f7091764fa0d4adb8e8cef2d586dbd6441b831c0848b` |
| `Sources/StorageCleanerMac/Models/ScanSessionRescanMerge.swift` | 新文件 | `f683e9f55263692800bb3c12cfb270aa9cf42855869e972e0b0b92ecdf688e8b` |
| `Sources/StorageCleanerMac/Services/DuplicateFileScanner.swift` | `348b4160…` | `f577675947d77187fcb18705874d6831f62525ffc9dd65d02d79c456729844c5` |
| `Sources/StorageCleanerMac/Services/ProjectArtifactScanner.swift` | `b10c07ec…` | `4170dd44f95cdf596c02dfc657500477d6f282db565a8bd58c2f906043a43188` |
| `Sources/StorageCleanerMac/Services/ReadOnlyCleanupScanner.swift` | `2e44e0de…` | `3893a72ccbe4bed6870452d136b28121c351077206f05e540186a10f74d9d027` |
| `Sources/StorageCleanerMac/Stores/ScanStore.swift` | `050b1128…` | `9418f151e0b31ed483b72c4fcc2ae07e277f726343d640af7c14c2f92875c5cc` |
| `Sources/StorageCleanerMac/Views/CleanupScanViews.swift` | `b64b4a8c…` | `88be35a7669065770bb4d92d1bf838719d346a66b9fedb0997b9a34df7293fcd` |
| `Sources/StorageCleanerMac/Views/FileAnalysisTrashViews.swift` | `da83e397…` | `af03fa454f544867d1fece4c15b5da9c3ec799e1023f6eea3e867c5f89da4581` |
| `Sources/StorageCleanerMac/Views/FilesLightfield/FileMigrationLightfieldView.swift` | `1f96c1d3…` | `6f667ff90d0886ae0add338d33d6e9b82d070c5621e496c75c5be6d9a2b913a3` |
| `Sources/StorageCleanerMac/Views/LargeFilesView.swift` | `56c1486d…` | `4901706420ce0229ea8168ba17fd23975907dea670ef5dfa392db15a779cb757` |
| `Sources/StorageCleanerMac/Views/ProjectArtifactView.swift` | `bd8a5878…` | `4ad3264b210f2170aec35000c05487db8a683ad01a642aff329177ff9d7c9fc9` |
| `Tests/StorageCleanerMacTests/CleanupRuleScannerTests.swift` | `d63de978…` | `0a98e7f02581966857738b5838c77eb63993c48369883390898cafd4e2199295` |
| `Tests/StorageCleanerMacTests/DuplicateFileScannerTests.swift` | `2a82b852…` | `a62cde39767d3fa7e568b3dfa5f2de252eda54174b52d4bbd5f8dd5f6c93d6c9` |
| `Tests/StorageCleanerMacTests/ProjectArtifactTests.swift` | `49ba1782…` | `da33a17e309b9402e08defdc223d1a3236c447179b784991953ceccd559b3160` |
| `Tests/StorageCleanerMacTests/ReclaimableOutsideCleanupScanTests.swift` | 新文件 | `a82714b1f67bd3582aefebf04be0593031ac676e182342bb571444885ed9914f` |
| `Tests/StorageCleanerMacTests/ScanAccessReturnTests.swift` | `68188b8e…` | `3a2558a81f5e5a91a9397cd82718ec36bd18dc06e2b7bff846092476845bc09b` |
| `Tests/StorageCleanerMacTests/ScanSessionRescanMergeTests.swift` | 新文件 | `fb72d0ef97282eb8336f73dcd7737a71568ec6ef9f4fa10baa14841174e83909` |

## Codex 独立复核（CODEX_FINAL_RECHECK_20261015_1710）

来源：Codex 的 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/review-d-20261016/`（`REVIEW.md`、`RESULT.json`、`RUN.json`、`LIVE_RECHECK.json`、`PACKAGE_AUDIT.json`、`G12_AUDIT.json`、`JEV_FINAL.json`、`swift-targeted.log`）和 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/final-gate-20261016/AUDIT.json`。本次只读了这些文件，没有改动。以下转述 Codex 的结论，不是本会话的结果。

- **结论**：在复核的 D104 改动中没有发现新的可复现、可操作的代码问题；在源码与隔离测试层面通过。这不是界面、已安装运行时、硬件或发布验收。
- **独立运行**：在门禁冻结副本 `d-gate-tree` 的拷贝上（1,740 个文件，前后哈希不变，清单 SHA-256 `f2a9e921…`）运行本文“复核方法”中的 8 个类：194 个方法 0 失败、0 运行时跳过，exit 0；2026-10-16 04:01:39–04:07:03（AEDT；UTC 17:01:39–17:07:03）；日志 SHA-256 `b0a515e3bd1634b9dc04eff6f5719afb46a7da51886b866ad75a791b9c2ed054`。排除的 2 个读本机真实目录的方法（`testOptInCapturesCurrentHomeStorageAnalyzerParity`、`testOptInCapturesCurrentHomeDeveloperArtifactScan`）不算通过，也不算运行时跳过。编译保留原有警告，不是无警告的说法。04:03:08 时 24 个 D104 文件与工作区一致。
- **直接源码复核**：G5（横幅与会话身份、被拒绝的根目录、规则版本与指纹、退回整体重扫、重活租约、进度与代次保护、停止与失败时结果不变、旧计划与试运行作废、旧选择保留、只有新行默认勾选）、并入（只替换补扫到的规则、拒绝其他会话与来源、保留未扫描的报告与问题、按身份和路径去重、共用的完整度判断）、G1（只读元数据、不改删除执行、按卷区分克隆、读不到时的处理、重复组“各份之和减去最大的一份”、其他硬链接、复查只读就绪文件、产物执行前不额外读取、大文件读取可取消）以及共用模型的默认值（旧的候选项初始化方法等价、行内格式默认不变、确认字段默认为空、`request.sessionID` 默认为空）。
- **Codex 核对的其他记录**：最新整合门禁的原始结果（15 步 exit 0；Release 4,946／跳过 23／0 失败，Debug 5,056／跳过 24／0 失败；p95 87.22129 与 85.59012 ms，阈值 100 ms 未改；1,740 个文件不变）；证据包 `batch-d/` 的 116 条校验和全部匹配（清单 SHA-256 `8a5cd31b…`）。反证是本会话的结果，Codex 没有独立重复：第 1 轮 33 项符合、1 项（G1e）不符合，虽然包装脚本 exit 0，仍按覆盖缺口保留；第 2 轮 36/36；第 3 轮 G5o 符合。窗口监视记录 9 个窗口、14 条记录，0 个上屏，8 条记录尺寸不为 0、落在主显示器范围内；定期观察不能证明两次观察之间没有显示，也不能证明显示前已定位。
- **G12**（`G12_AUDIT.json`）：12 条记录都是 exit 0；自建夹具 6 条和 Xcode 包 3 条的结果一致性核对相符；`~/Library/Caches` 3 条都不一致，仍不算一致性通过，“目录在变化”只是推断；亚毫秒级的中位数四舍五入后不能完全复现所有百分比，没有计时结论依赖这些小样本；这是元数据层的基准，不是整体性能。真实路径的遍历没有重做。
- **JEV（Codex 调用）**：判定 escalate（`safe_to_apply` 0.27，影响面 1.97 偏高，测试缺口置信度 0.28 偏低），3 条有限的证据结论都核实；Codex 没有为更好的分数重试，也不把分数当作批准。

## 仍未通过、未做或待实机

- **Codex 独立复核**：2026-10-16 已完成，在源码与隔离测试层面通过（见上一节）；C 批返修（D105，含 D105-R1）也已在同一层面关闭。这不是界面、运行时或发布验收；反证没有经 Codex 独立重复。
- **57 个会开窗口的测试类**没有跑（窗口必须先定位到“虚拟屏 1 · Codex”才能运行，当前门禁按名单排除），也没有窗口在显示前定位到 Codex 虚拟屏的证明；G1、G5 的新文字和布局没有在运行中的 App 上目视检查。
- **G5 待实机**（需要用户另行批准安装测试版）：由用户本人在“系统设置 › 隐私与安全性 › 完全磁盘访问”中打开测试版的权限，回到 App 后点“重新扫描这些位置”，确认只扫描新可读的位置、结果并入同一次扫描、已取消的勾选保持不变、扫描历史没有多一条。
- **G5 已知限制**：并入时，新行内部的文件与已列出行内部的文件之间的硬链接无法匹配（要重新读已列出的行），整体重扫可以匹配；并入后的结果完成时间取补扫的完成时间。
- **G1 待实机**：项目产物、大文件列表、重复文件、文件分析移到废纸篓四处的预计释放文字只在测试里核对过；在真实的克隆、本地快照和外置卷上的读数没有验证。项目产物测量时每个普通文件多一次 `getattrlist`，在大型产物目录上的耗时没有测量（之后不再安排真实路径的测试）。
- **G1 仍有的低估**：两份文件部分共享（改写过的克隆）时各自按保留计，与 A 批相同。重复文件组的量是“不论保留哪一份都一定能释放”的下限；混合组里保留一份克隆可能释放更多。
- **G11**：没有做，等用户决定。
- **G12**：只评估，不启用也不扩大实现；是否在 2.0.2 采用 `getattrlistbulk` 和包含检查的缓存，需要另行决定并配套测试。
- 提交、合并、安装、重启、发布、真实清理、风扇／电源／SMC 写入都没有做，仍逐次等用户批准。

## 复核方法

```bash
cd /Users/developer/Developer/sc-worktrees/v2.0.1
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --build-tests --scratch-path <私有临时目录>
swift test --skip-build --scratch-path <同一目录> \
  --filter 'StorageCleanerMacTests\.(ScanSessionRescanMergeTests|ScanAccessReturnTests|CleanupRuleScannerTests|ProjectArtifactTests|ReclaimableOutsideCleanupScanTests|DuplicateFileScannerTests|FileStorageSharingTests|FileAnalysisTrashTests)/'
```
`CleanupRuleScannerTests` 里有两项本机采集测试，只在显式设置环境变量时运行，默认跳过。反证脚本 `scripts/counterproof_d104.py` 需要一份工作区的副本（不含 `.build`），用法见脚本开头；每项都会把副本恢复原样并核对哈希。
