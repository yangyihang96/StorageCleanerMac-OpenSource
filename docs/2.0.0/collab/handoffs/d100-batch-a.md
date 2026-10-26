# d100-batch-a：竞品逆向改进 A 批（只读、展示、文档与守卫）

批次：A / D100。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`。本批全部改动未提交，与 D98、D99 的未提交改动在同一工作区。计划文件是 `~/Claude 好玩的/Mac清理与监控软件逆向-2026-10-15/2.0.1改进计划.md`（SHA-256 `169ed23e1070d1e6…`）。

本批没有做以下事情：提交、合并、安装、重启、启动 App、对真实数据执行清理、写风扇／电源模式／SMC。唯一接触真实数据的是 G1 的只读测量：在工作区的副本里用产品扫描器只读扫描本机主目录，没有移动或删除任何文件。

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-a/`，包括原始日志、批前批后的差异快照和反证脚本。

## 完成项

| 项 | 改动 | 测试与反证 |
|---|---|---|
| G6 | 删除没有调用的 `PathSafety.shellQuoted` | 编译通过。全仓只剩 `UpdateModels.shellQuotedForDisplay`，这是另一个只用于显示命令的函数 |
| L8 | 新增 `script/check_deletion_process_inventory.py`、清单 `script/deletion-process-inventory.txt`（153 条，243 处使用）、自测 `script/test_check_deletion_process_inventory.py`（8 项），接入 `verify.sh`（exit 16） | 16/16 反证 |
| G4-1 | `docs/2.0.1/cleanup-rule-table.md`（79 条规则）由 `CleanupRuleTableTests` 生成，并与加载结果逐字比对 | 2 项测试；反证 G4a、G4b |
| G1 | 预计释放扣除克隆共享和本地快照占用的部分（见下节） | `FileStorageSharingTests` 8 项；反证 G1a–G1k，另有无害改写 H1 |
| G8 | SSD 健康细节（见下节） | `DiskSMARTDetailsTests` 6 项；反证 G8a–G8e |
| G5 | 授权后回到 App，提示一次可以重新扫描（见下节） | `ScanAccessReturnTests` 6 项；反证 G5a–G5g |

## G1：预计释放（克隆与快照）

- **读取方式**：用公开的 `getattrlist` 读取一组属性：`ATTR_CMN_FLAGS`、`ATTR_FILE_DATAALLOCSIZE`，以及 `ATTR_CMNEXT_PRIVATESIZE`、`CLONEID`、`EXT_FLAGS`、`CLONE_REFCNT`（`Support/FileStorageSharing.swift`）。
  - 只在测量清理候选时读，对象是聚合遍历中的普通文件，包括规则候选、重复 App 副本和废纸篓总量。整盘扫描（`DiskScanner`）不读。
  - 本机实测确认了这些属性的含义：`cp -c` 的一对克隆私有字节为 0、克隆 ID 相同、引用数 2；改写一部分的克隆会换一个克隆 ID；硬链接各自报告完整的私有字节。
- **计算方法**（`Models/CleanupReclaimableEstimate.swift`）：
  - 同一卷、同一克隆 ID 的全部引用都在一个候选内时，删除该候选会释放其中一份，按一份计入可释放。**（已由返修 A-R1 更正：引用数不能证明别处没有部分克隆或快照仍在共享，这一份现在不计入预计释放，只单独显示为“可能释放”。见文末“返修”一节。）**
  - 跨候选的克隆组不合并，部分改写的克隆只算私有字节，这两种情况的估算都偏低。**（返修 A-R2：选择汇总已按卷和克隆 ID 跨候选合并完整克隆组。见“返修”一节。）**
  - 硬链接沿用原有的身份去重。
  - 共享但没有克隆标志的块记为本地快照占用。
- **不信任的读数**：
  - 压缩文件（`UF_COMPRESSED`）的私有字节为 0，但已分配大小不为 0，因此记为“读不到”：按全部释放计，明显时注明“可能高估”。
  - 按需下载的占位文件（`SF_DATALESS`）和不报告私有字节的卷记为“不适用”，不显示提示。
- **“明显少于”的门槛**：至少 1 MiB，并且至少是大小的十分之一。
- **显示位置与不变的部分**：
  - 列出门槛、排序、默认勾选、计划与回执仍用已分配大小。
  - 预计释放显示在：候选行提示、详情弹窗、lightfield 详情与帮助文字、选择汇总栏（明显时追加“清空废纸篓后预计释放 X”）。
  - 删除路径没有改动。
- **重复文件**：该功能原本就用 AppleArchive 的 CLC 识别 APFS 克隆，只改了文案：“已是克隆，删除几乎不释放空间”。
- **偏差**：文件分析／大文件页和 `ProjectArtifactScanner` 不显示预计释放。原因是计划第 2 步限定只在清理候选内读取，而且 `StorageItem` 被多处共享并持久化。这一项留作后续。**（2026-10-16：已由 D104 补做，见 `d104-batch-d.md`，未提交，待 Codex 复核。）**
- **本机只读测量**（2026-10-15，产品扫描器，在副本中运行，日志 `g1-measure-local.log`）：
  - uv 缓存列出 854.4 MB，预计释放 461.6 MB。
  - 计划写的“785 MB 与虚拟环境共享，删除只释放约 69 MB”只算了私有字节。逐组核对（`g1-uv-clone-groups.txt`）：
    - 9,616 组克隆每组 2 份，**两份都在 `~/.cache/uv` 内**：一份在 `archive-v0/<wheel>`，另一份在缓存自带的环境 `archive-v0/<id>/lib/python3.13/site-packages`；
    - 删除整个缓存会释放其中一份，即私有 69.1 MB 加 392.5 MB。
  - **返修后更正**：上面“删除整个缓存会释放其中一份”和“计划只算了私有字节”这两个判断不成立。按本节的分组数据推算，返修后的保守预计释放就是私有的 69.1 MB，计划写的“约 69 MB”正是这个保守值；392.5 MB 只在别处没有部分克隆或快照共享这些块时才会释放，现在单独显示为“可能释放”。下面整次扫描的 90.3 GB 是旧算法的数字。以上都是推算，返修后没有重新测量本机数据。
  - 整次扫描：53 个候选，列出 122.7 GB，预计释放 90.3 GB。
  - 耗时：
    - 最大的根（废纸篓，50.8 GB）不读共享时 29.6／29.3／30.4 s，读共享时 48.9（首次）／35.8／35.8 s，热缓存约多 6 s（约 21%）；
    - 整次扫描（900,886 项）读共享时 95.5／124.7 s，不读时 134.1／92.1 s，差异在两次运行的波动范围内。
  - 扫描上限是 300 s（`CleanupScanRequest.standardMaximumDuration`），超时后结果标为不完整；本机离上限还有余量，更慢的 Mac 或更大的主目录没有测过。
  - 测试进程没有完全磁盘访问，所以读共享和不读共享的两组运行，结果都是“部分”（`partial`）。

## G8：SSD 健康细节

- 数据来源是 `diskutil info -plist` 已经返回的 `SMARTDeviceSpecificKeysMayVaryNotGuaranteed` 字典，没有新增命令。
- 字段解析：
  - 128 位计数器由 `_0`（低 64 位）和 `_1`（高 64 位）组合；任何一半不是非负整数时，整个计数器记为未知；
  - 布尔值和小数不当作数字；
  - 1 个数据单位按 512,000 字节换算。
- 显示内容：温度、累计写入／读取、通电时间与次数、异常断电、可用备用块（附阈值）、介质错误、严重警告。每一行只在系统报告了对应键时显示。
- 健康结论只看两项：
  - 盘自报的 `CRITICAL_WARNING` 不为 0 时，结论为“需要处理”；
  - `PERCENTAGE_USED` 达到 100、剩余寿命为 0 时，结论为“注意”。
- 可用备用块只显示、不参与判断。本机报告的是 100 对阈值 99，如果拿它们比较会误报。
- 旧快照没有这些字段，照常解码。

## G5：授权后回到 App

- 回到 App（`didBecomeActive`）时，只对当前扫描标为“没有权限”（`permissionDenied`）的根目录重新做一次只读的可读性检查（`ScanReadinessService.readableDirectories`）。
- 变得可读的位置会在结果页显示一次横幅：“现在可以读取：…。本次结果没有包含这些位置，重新扫描后会包含。”同一次运行中，每个位置最多提示一次，关闭权限后再打开也不会重复提示。
- 用户点“重新扫描”之前不会开始扫描。检查只在结果已经显示、且没有扫描或清理在进行时运行。
- 先检查目录，再刷新权限就绪卡片（只在卡片原本有受阻项时刷新）。顺序反过来的话，刷新本身会被当作“正在准备扫描”，把检查挡掉。
- **偏差**：计划写的是“只重扫新位置”，实际横幅按钮会从结果所在的页面，按原扫描的范围重新扫描一次，与回执页的“重新扫描”一致。**（返修 A-R3 后，这个按钮按已完成会话自己记录的范围扫描，不再读当前的扫描偏好；回执页的“重新扫描”仍按该页面当前的偏好，两者在这一点上不再一致。见“返修”一节。）**原因是每次扫描的结果是一个会话（`cleanupScanSession`），新的扫描会整体替换它：只扫新位置会把结果换成其中一部分；合并会话又会改变计划依赖的候选身份。**（2026-10-16：D104 改为只扫新可读位置并并入同一次结果，规则有变化时仍按 A-R3 整体重扫；见 `d104-batch-d.md`，未提交，待 Codex 复核。）**
- 修复记录：最初的实现用 `scanPresentationState.isTerminal` 做守卫，但扫描结束后状态是 `.results`，不在 `isTerminal` 之列，所以检查从不运行。`rescanAfterV2Cleanup()` 也有同样的守卫，只适用于清理之后。现在两处都改用 `showsSettledScanResults`。在页面准备扫描时，按钮不可点。

## 反证

在副本中逐项改坏实现，运行守护该项的测试套件，确认测试在断言上失败（不是编译错误），然后逐字节恢复并核对哈希。脚本是 `counterproof_batch_a.py`，日志是 `counterproof-batch-a.log`；副本未修改时的基线日志是 `counterproof-baseline.log`。

结果：**26/26 符合预期**（2026-10-15 17:23–17:35）。25 个改坏用例都在断言上失败，无害改写 H1 通过。27 次恢复的哈希全部一致。副本在反证前后与工作区逐字节相同（1,710 个文件），唯一的差别是之后才写的本交接文档。

| 项 | 用例（全部按预期失败） |
|---|---|
| G4-1 | G4a：JSON 规则修订号改了但表没重新生成；G4b：表里删掉一行 |
| G8 | G8a：丢掉 128 位计数器的高半部分；G8b：拿可用备用块和阈值比较来下结论；G8c：数据单位按 512 KiB 换算；G8d：忽略盘自报的严重警告；G8e：把布尔值当数字读 |
| G1 | G1a：完整克隆组不按一份释放；G1b：信任压缩文件的读数；G1c：按需下载的占位文件记成“读不到”；G1d：克隆 ID 和标志位读反顺序；G1e：遍历时不记录普通文件；G1f：子文件夹的统计不向上合并；G1g：去掉 1 MiB 门槛；G1h：去掉十分之一门槛；G1i：可释放大小忽略估算；G1j：快照占用记成克隆；G1k：克隆组不分卷 |
| G5 | G5a：已提示的位置再次检查；G5b：同一位置再次提示；G5c：不存在或不可读的位置也去检查；G5d：回到 App 后自动开始扫描；G5e：lightfield 列表里缺少横幅；G5f：App 回到前台时不检查；G5g：新扫描开始后提示仍然留着 |

基线：副本未修改时，4 个套件共 22 个测试，0 失败，0 跳过。

## 门禁（原始日志）

| 检查 | 实际结果 | 日志（证据目录 `logs/`） |
|---|---|---|
| 完整 `script/verify.sh`（`DEVELOPER_DIR` 用 Xcode 27.0.0 Beta，`STORAGE_CLEANER_VERIFY_BUNDLE=0`，`STORAGE_CLEANER_UI_SMOKE=0`，私有 `STORAGE_CLEANER_VERIFY_ROOT`） | **exit 0**，2026-10-15 17:36–18:15 | `verify-full.log` |
| 其中 Release 全量 | 5,120 个，0 失败，跳过 24 | 同上 |
| 其中 Debug 全量 | 5,535 个，0 失败，跳过 25 | 同上 |
| 其中严格并发构建、源码守卫（exit 10/11/14/15）、私有 API（自测 3 项，9 处白名单）、删除原语与进程清单（自测 8 项，153 条、243 处）、`git diff --check` | 全部通过 | 同上 |
| 其中菜单栏性能（16 项） | 通过；准备阶段 p95 96.97 ms，阈值 100 ms，余量不大 | 同上 |
| 受影响套件定向测试（22 个套件） | 320 个，0 失败，跳过 2 | `targeted-suites.log` |
| Python 检查器单独运行 | 全部 exit 0 | `python-checkers.log` |
| 反证 | G4-1／G8／G1／G5 共 26/26；L8 16/16 | `counterproof-batch-a.log`、`counterproof-l8.log` |

- **测试数量变化**：D98/D99 最后一次完整 verify 是 Release 5,098、Debug 5,513。本批两边都多 22 个，正好等于新增的 Swift 测试：G1 8 个、G5 6 个、G8 6 个、G4-1 2 个。
- **跳过的测试**：数量不变，都是原有的、需要手动开启的测试（真实硬件、真实主目录、真实安装包、计时测量等）。本批新增的测试一个都没有跳过，包括 G1 中依赖 APFS 的那几项。
- **JEV 复核**：只传了 G1、G5 的关键代码和测试摘要。结果是正确性 1.84/2、规格符合度 1.95/2、`safe_to_apply` 0.49，判定为 escalate（需要人工复核），没有指出具体缺陷；影响面得分 1.71，置信度 0.56。这个结果不当作通过，交给独立复核。

## 待实机验收（需要用户批准，或由用户本人操作）

1. **G5**：需要先另行批准安装测试版。之后由用户本人在“系统设置 › 隐私与安全性 › 完全磁盘访问”中打开测试版的权限，回到 App 后检查三点：
   - 横幅只出现一次；
   - 点“重新扫描”后，结果包含新位置；
   - 关闭权限再打开，不会重复提示。
2. **G1 本地快照占用**：本机没有本地快照，创建快照需要 `tmutil localsnapshot`，未获批准，所以只用合成读数测试过。
3. **G1、G5、G8 的界面**：文字与布局没有在运行中的 App 上目视检查过，需要构建并启动 Beta；安装要另行批准。
4. **G8 其他硬盘**：夹具只用了本机 `diskutil info -plist /` 的字段，外置 NVMe 和非 Apple SSD 的字段差异没有验证。

## 未做或延后

- G1：文件分析／大文件页和 `ProjectArtifactScanner` 的预计释放（见上文）。**（2026-10-16：已由 D104 补做，见 `d104-batch-d.md`，未提交，待 Codex 复核。）**
- G1 性能：最大的根多约 21%。如果需要，可以在遍历时改用 `getattrlistbulk`，按目录批量读取，改动面更大，本批没有做。

## 返修：Codex 复核 CODEX_A_REVIEW_20261015_0739

- 复核报告：`~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/review-a-20261015/REVIEW.md`，共 4 项 P2，A 批因此暂不验收。复核目录只读，本次没有修改。
- 返修在同一工作区进行。B 批第一项 L5（D101）此前已在工作区完成，未提交。返修开始前的状态另存了一份（`pre-afix`），返修差异单独存档，见本节末尾“差异与证据”。
- 本次没有提交、安装或发布，没有执行真实清理或硬件写入，也没有打开新窗口。

| 项 | 复核指出的问题 | 返修 | 回归测试 |
|---|---|---|---|
| A-R1 | 完整克隆组的引用数等于组内文件数时，被当作“别处没有共享”，按一份计入可释放。候选外还有部分改写的克隆共享这些块时，会高估 | 克隆共享的字节一律不计入预计释放。候选内整组都在的完整克隆，其中一份记入 `wholeCloneGroupBytes`，只作为“可能释放”显示，并写明条件 | Codex 的 `testIndependentReviewPartialCloneOutsideCandidateKeepsSharedBlocks` 原样加入并通过（产品报 0，上限 1 MiB）；新增 `testAFullPairReadsTheSameWithOrWithoutAPartialCloneOutside` |
| A-R2 | 跨候选的完整克隆组信息在汇总选择之前就丢了，两项都选中时仍是 0 | 候选保留“有成员在本项之外”的完整克隆组。选择汇总栏改用 `CleanupSelectionReclaimable`，按卷和克隆 ID 合并，成员全部选中才计一份，计入“可能释放” | Codex 的 `testIndependentReviewSelectionOfTwoCloneCandidatesFreesOneCopy`（调用目标改为选择级函数，断言值不变，见下）；新增 `testASelectionCountsOneCopyOfAGroupOnlyWhenEveryMemberIsSelected`、`testAnItemKeepsTheLargestGroupsReachingOutsideUpToTheLimit`、`testTheSelectionHeaderMatchesClonesAcrossTheSelectedRows` |
| A-R3 | 授权横幅的“重新扫描”读取当前的扫描偏好；偏好改过时，新授权的位置可能漏扫 | 重扫直接使用已完成会话记录的范围（智能扫描范围、类别、规则），既不读也不改用户的扫描偏好。排除项和开发者闲置阈值仍取当前设置 | Codex 的 `testIndependentReviewRescanKeepsTheCompletedSessionsScope` 原样加入并通过；新增“智能扫描范围收窄”“安全清理范围变化”两项 |
| A-R4 | 清单检查器只数 `Process()`，`Process.init()`、`Foundation.Process.init()` 都是 0 | 显式的 `.init(`、`.self.init(`、带模块限定名、反引号、点号和括号两侧有空格／注释／换行，以及 `Process = .init(`，都计为一次启动。`NSTask`、`NSAppleScript`、`OSAScript`、`NSUserAppleScriptTask`、`NSUserUnixTask` 同样处理 | 自测新增 2 项（含子测试），共 10 项；Codex 的 `inventory-repro.py` 3/3 通过 |

### A-R1：克隆共享的字节一律按“保留”计

- **证据**：同一卷上，候选内一对完整克隆的读数，无论候选外有没有部分改写的克隆，都完全相同：私有 0、共享 4 MiB、引用数 2、可能共享块的标志为 1。见证据目录的 `apfs-probe.log`；探测程序 `apfs-probe.c` 只调用 `getattrlist` 读取属性。没有公开的只读接口能说明别处是否还有部分克隆或快照引用这些块，所以“真的只在本项内”和“被外部部分共享”无法区分。
- **预计释放**：已分配大小 − 全部克隆共享字节 − 快照占用字节。读不到的字节仍按释放计，明显时注明“可能高估”（与原来相同）。
- **可能释放**：候选内整组都在的完整克隆，其中一份记为 `wholeCloneGroupBytes`。只有别处没有部分克隆或快照共享这些块时才会释放，最多一份。
- **行提示**（明显时显示）：“清空废纸篓后预计释放 X；其余与其他文件共享存储（克隆），其中 Y 的克隆都在本项内，别处没有共享时也会释放”。

### A-R2：选择汇总按卷和克隆 ID 合并

- **保留哪些组**：每个候选保留引用数大于本项成员数的完整克隆组，记录卷、克隆 ID、本项成员数、引用数和一份的大小。每个候选最多保留 1,024 组，按一份的大小从大到小。超出的组不参与跨项合并，只会让“可能释放”偏少，不影响预计释放。
- **成员数可以直接相加**：整次扫描共用一个身份集合，同一个文件（包括硬链接）只在一个候选里计一次。
- **`CleanupSelectionReclaimable(candidates:)`**：
  - 预计释放是各项预计释放之和，与各行显示的一致。
  - 可能释放 = 各项内整组的一份之和 + 跨项合并后成员全部被选中的组各一份；不超过所选大小减去预计释放。
- **选择汇总栏**：预计释放明显少于所选大小时，显示“已选择 N 项 · S · 清空废纸篓后预计释放 X”；可能释放 Y 也明显时，追加“，所选完整克隆另可能释放 Y”。
- **Codex 测试改了调用目标，断言没有放宽**：
  - 原测试照视图当时的写法，把各行的 `reclaimableSizeBytes` 相加。
  - A-R1 之后，逐行的值必须保守：只选 Left 时，Right 仍保留同一份数据，释放为 0。所以逐行相加在任何正确实现下都只能得到 0，不可能是 4 MiB。
  - 返修把视图的汇总改成了选择级函数，测试相应改为调用同一个函数；视图确实这样汇总，由 `testTheSelectionHeaderMatchesClonesAcrossTheSelectedRows` 锁定。
  - 断言值 4 MiB 和断言消息都没改，`total` 现在是确定释放加可能释放。
  - 另加三条断言：确定释放为 0（与 A-R1 一致）；可能释放为 4 MiB；只选一项时，可能释放为 0。
- **不变的部分**：删除路径、计划、回执、列出门槛、排序和默认勾选，仍用已分配大小。

### A-R3：重扫使用已完成会话的范围

- **新路径**：`rescanAfterAccessReturn()` 先把页面切到该会话所属的页面（与原来相同），再调用 `beginScan(rescanning: session)`。
  - 请求里的智能扫描范围、类别和规则直接取自会话，不读当前的扫描偏好，也不改写偏好。
  - 排除项和开发者闲置阈值仍取当前设置，与普通扫描一致；新加的排除项会被遵守。
- **与原路径的差别**：原来经过的 `startScanRespectingAccessGuide()`，在产品默认的 `.v2Full` 模式下只做几项守卫，然后调用 `startScan()`。
  - 返修路径保留了“正在准备扫描”“正在清理”这两项守卫（由 `showsSettledScanResults` 检查）。
  - 跳过了按偏好判断“至少选一项”的守卫，以及文件工作区的刷新；会话所属的页面不会是文件工作区。
  - 旧的 `.legacy` 模式下，原路径还会先弹出权限修复引导，返修路径不弹。该模式不是产品默认。
- **没有改的**：回执页的“重新扫描”（`rescanAfterV2Cleanup`）仍按页面当前的偏好扫描。复核没有涉及它，这次没有改。

### A-R4：显式初始化写法

- **计入**：`EXPLICIT_INIT` 覆盖 `Process.init(`、`Foundation.Process.init(`、`Process.self.init(`、反引号、点号和括号两侧的空格／注释／换行，以及 `Process = .init(`。最后一种通常出现在类型标注之后；在其他位置出现同样的写法也计入，守卫宁可多报。
- **不计入**：`ProcessInfo.init`、`Process.TerminationReason.init`、`ProcessKind`、`MyProcess`、单独的 `.init()`，以及注释和字符串里的文字。
- **边界不变（已记录）**：把初始化器当作函数值传递（`let make = Process.init`），以及经过别名或包装函数的数据流，不追踪。
- **仓库清单数不变**：152 条、242 处。A 批交付时是 153／243，少的那一条是 L5 删除的 `CleanupService removeItem`。

### 返修后仍未实现的计划内容（不算完成）

- G1：文件分析／大文件页和 `ProjectArtifactScanner` 不显示预计释放（A 批已记录的偏差）。**（2026-10-16：已由 D104 补做，见 `d104-batch-d.md`，未提交，待 Codex 复核。）**
- G1：候选内两份互相共享的部分改写克隆，仍各自按保留计，估算偏低；只有完整克隆组才有“可能释放”。
- G5：仍按原扫描范围整体重扫，不是计划写的“只扫新位置”（A 批已记录的偏差）。**（2026-10-16：已由 D104 补做，见 `d104-batch-d.md`，未提交，待 Codex 复核。）**
- G1 本地快照：仍只用合成读数测试过。
- 界面：新的行提示和汇总栏文字没有在运行中的 App 上目视检查过。

### 对 B 批的影响

- D101 的 G10 规定：预计释放不到 1 MiB、或不到大小十分之一的绿色项，不再默认勾选。
- 返修后预计释放是保守值。按 A 批的分组数据推算，uv 缓存的预计释放是 69.1 MB／854.4 MB（约 8%）：
  - 如果按保守值判断，它会不再默认勾选；
  - 如果按“预计释放加本项内的可能释放”（461.6 MB）判断，它仍默认勾选。
- G10 实现时，在 D101 写明采用哪一种，并说明理由。

### 差异与证据（返修）

**结论：四项返修在源码和定向测试层面通过，Codex 已独立复核（CODEX_A_RECHECK_20261015_0901，31 项、0 失败、0 跳过）。完整门禁没有通过：同一项负载敏感的菜单栏计时测试超阈值，会开窗口的 57 个测试类没有跑。不能据此把完整门禁、B/C/D 或整版运行时验收记为通过。**

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-a/review-fix-CODEX_A_REVIEW_20261015_0739/`（`SHA256SUMS.txt` 覆盖目录内全部文件）。

- **冻结副本**：返修结束时把工作区复制为 `afix-tree`（1,713 个文件），之后所有门禁都在这份副本上跑，工作区继续做 B 批。每次门禁前后的清单都与冻结时一致（`snapshots/afix-tree-manifest-checks.txt`）。Codex 复核时也逐字节核对了这份副本。
- **返修差异**：`snapshots/afix-delta.diff` 是返修前的树（`pre-afix.diff` 加 `pre-afix-untracked.tar`）与冻结副本逐文件比较的结果，共 11 个文件；应用后与 `afix-files.sha256` 一致（脚本自检 OK）。冻结副本相对 HEAD 共 47 个文件不同，包括 A 批、L5 和返修（`afix-tree-vs-HEAD-files.txt`）。

| 检查 | 时间（2026-10-15） | 实际结果 | 日志 |
|---|---|---|---|
| 返修定向测试（30 个套件） | 19:05–19:07 | 646 个，0 失败，跳过 3 | `logs/targeted-afix.log` |
| 反证 | 19:11–19:34 | Swift 25/25、Python 7/7 都按预期变红；源码已复原并核对哈希 | `logs/counterproof-afix*.log` |
| 完整 `verify.sh` | 19:34–19:56 | 收到窗口约束（CODEX_DISPLAY_CHECK_20261015_0855）后在 Release 测试构建中停止，没有任何测试开始，**不算通过** | `logs/verify-full-stopped-1956.*` |
| 不开窗口的门禁，第 1 次（Release 全量，跳过 57 个会开窗口的类） | 20:13–20:43，负载很高 | exit 1：4,840 个，跳过 23，失败 5（`MenuBarPerformanceRegressionTests` 1 项，p95 1,055 ms；`MenuBarSamplingPlanTests` 2 项） | `logs/verify-nowindow.*` |
| 菜单栏两套单独重跑 | 20:45 | 44 个，失败 1：同一计时项，p95 100.3 ms（阈值 100 ms）；`MenuBarSamplingPlanTests` 28 个全部通过 | `logs/menubar-rerun/` |
| 第 2 次（Release 全量） | 20:45–20:50 | exit 1：4,840 个，跳过 23，失败 1（同一计时项，p95 128 ms） | `logs/verify-nowindow-run2.*` |
| 其余阶段（`swift test list`、严格并发构建、Debug 全量、源码守卫、Python 检查、冲突副本、菜单栏性能脚本） | 20:51–21:15 | exit 1：Debug 4,950 个，跳过 24，**0 失败**；守卫和 Python 检查通过（清单 152 条、242 处）；菜单栏性能脚本失败（同一计时项，p95 115 ms），脚本在此停止，`git diff --check` 没有跑 | `logs/verify-nowindow-rest.*` |
| 补做的空白检查 | 21:20 | 对 HEAD 导出逐个 `git diff --no-index --check` 冻结副本的 47 个改动文件和 4 份文档：无问题 | `logs/diff-check-afix.log` |

- **跳过了什么**：57 个测试类（Release 共 304 个测试）会创建并显示窗口或系统界面，没有在主屏以外的可靠路由，所以没有跑，列为待验证，不算通过。名单见 `logs/pending-ui-classes.txt`，生成脚本见 `scripts/build_skip_list.py`。“跳过 23／24”是测试自身按条件跳过的原有项目，与这 57 类无关。
- **菜单栏计时项为什么判断与返修无关**：冻结副本相对 HEAD 改动的 47 个文件里没有菜单栏代码；这个测试测的是长历史准备耗时，p95 随负载在 100.3–1,055 ms 之间变化，阈值 100 ms。A 批完整门禁（17:36–18:15）时同一项是 96.97 ms，已经贴近阈值。没有改阈值和断言。**没有在同一负载下用 HEAD 做对照**，所以“与改动无关”是推断，不是对照结论；需要在低负载时重跑。
- **窗口**：
  - 不开窗口的几次门禁都开着只读监视器（`scripts/window_watch.swift`），记录到 0 个上屏窗口、0 次违规。其余阶段里有 4 个没被跳过的类（`MenuBarStatusPanelTests`、`MenuBarTertiaryDetailTests`、`SafeCleanupScopeCardLayoutTests`、`ScanAccessReturnTests`）创建了 8 个不上屏的窗口（`onscreen=false`），从未显示。监视器只是证据，不能保证窗口不会先在主屏出现。
  - 窗口约束之前跑过的测试很可能在主屏上显示过窗口：15:34–15:56 的完整 verify、17:36–18:15 的 A 批完整 verify、17:22 的 `SettingsLightfieldGeometryTests`、19:05–19:07 定向测试里的 `SafeCleanupLayoutTests` 和 `SmartScanScopeTests`。
- **其他**：`logs/trash-item-integration.log` 是一次没有匹配到测试的过滤（“No matching test cases were run”），不作为证据。JEV 结果见 `logs/jev-review.json`，不当作通过。
