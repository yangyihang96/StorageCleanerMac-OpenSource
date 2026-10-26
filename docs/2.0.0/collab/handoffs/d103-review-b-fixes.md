# d103-review-b-fixes：B 批独立复核返修（CODEX_B_REVIEW_20261015_1249）

批次：B 批返修 / D103。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`，全部改动未提交。返修在 C 批进行中完成，与 C 批改动在同一工作区，但两者改的文件没有重叠（见“差异与哈希”）。产品决定见 DECISIONS D103，本文只记实现、测试、证据和仍未完成的部分。

复核来源：Codex 的 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/review-b-20261015/REVIEW.md`。行号按 Codex 冻结的 `b-tree`（B 批门禁副本，2026-10-15 22:28）。本次只读了 Codex 的目录，没有改动。

本次没有做以下事情：提交、合并、安装、重启、启动 App、对真实数据执行清理（包括本机的 `simctl` 和清空废纸篓）、写风扇／电源模式／SMC。修复和新测试只用夹具、临时目录和假执行器；会改权限的测试只改自己建的临时目录，结束时和 `tearDown` 中都恢复。

## 结论

**B-R1、B-R2、B-R3 在源码和定向测试层面关单。** 依据分两部分，下文分开记录：
- **Codex 独立复核**（CODEX_B_RECHECK_20261015_1345）：Codex 用原冻结的 `b-tree` 加本次交付的 8 个文件重建隔离副本，独立编译并运行 36 个测试，0 失败、0 跳过，exit 0；结论是 B-R1–B-R3 在源码与定向测试层面关单，D23 同类回读修复已核对。
- **自测**（本会话）：定向测试 1,169 个 0 失败（第一次有 1 个未改动的计时测试超时），反证 12/12。

不能据此把以下任何一项记为通过：B 批完整门禁（exit 1，菜单栏计时项）、57 个会开窗口的测试类、B 批界面目视与实机项、A 批遗留的 G1／G5、C 批和 D 批的验收。

## Codex 独立复核（CODEX_B_RECHECK_20261015_1345）

记录：`~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/followup-2.0.1/review-b-fix-20261016/RECHECK.md`，同目录有 `RESULT.json`、`SOURCE_MANIFEST.json`、`swift-recheck.log`、`JEV_RECHECK.json`。本会话只读取了这些文件，没有改动。以下按 Codex 的记录转述，日志哈希已在本机核对：`swift-recheck.log` 的 SHA-256 是 `e7f6f1915e2a82293438c1ae9ece55e7f0d319ea23ef1d686adaed1361c7055b`，与 Codex 给出的相同。
- 源码：原冻结 `b-tree` 1,724 个文件，只加本次 8 个文件得到 1,725 个，测试前后哈希全部符合，没有多余文件；`review-b-fixes` 证据包 37 个文件校验通过；8 个修复文件与当时的工作区相同（2026-10-16 00:43:51 AEDT）；`IndependentBatchBReviewTests.swift` 与 Codex 原文件逐字节相同。复核副本不含 C 批改动。
- 运行：Codex 自己的构建目录，完整重建后于 2026-10-16 00:42:40–00:42:41 AEDT 运行 36 个测试：`IndependentBatchBReviewTests` 3、`FrozenTrashEmptyingTests` 15、`SimulatorCleanupTests` 12、`CleanupTrashDeletionTests` 5、`CleanupJunkActionableTests.testEmptyTrashDeletesOnlyFrozenEntriesInsideTheTrash` 1；0 失败、0 跳过，exit 0。输出与自测相同：两个场景 `retainsTrash=true`，`unknown=true offeredRuntimes=0`，`deleted=0 failed=1 retained=true`；D23 的回读失败和正常删除两个用例都通过。
- 范围：没有真实清理、`simctl` 删除、已安装 App、窗口或硬件写入。Codex 另外核对了自测日志（全量 1 的计时失败 5.45 秒对 2.0 秒上限、全量 2 的 0 失败、反证 12 项），记录为“已检查，不替代独立运行”。JEV 只作辅助。
- Codex 明确不关单的：B 批 Release 性能门禁失败、57 个未运行的界面测试类、G1 大文件预计释放、G5 只扫新可读位置、C／D 验收，以及需要另行批准的运行时、安装和硬件验收。

`FrozenTrashEmptyingTests` 有 15 个测试（文件里的 `static func testFixture` 是辅助函数，不是测试），所以本次新增的测试是 5 个：Codex 的 3 个、`FrozenTrashEmptyingTests` 1 个、`CleanupTrashDeletionTests` 1 个。

## 修复

| 项 | 根因 | 改动 | 测试 |
|---|---|---|---|
| B-R1（G2） | `FoundationSimulatorDeviceSetReader.runtimeIdentifiers` 用 `fileExists` 判断设备集是否存在。上级文件夹不可搜索时它也返回假，读取结果成了空集合，仍被引用的运行时被当作“没有设备使用” | 先 `stat`：只有 ENOENT、ENOTDIR 返回空集合；其他错误、路径不是文件夹、读不出内容或某台设备的 `device.plist`，返回 nil（未知）。调用方已有的处理是：任何一个设备集未知，这一轮不列运行时，只列不可用设备 | Codex 的 `testUnreadableDeviceSetIsUnknownRatherThanAbsent`；`SimulatorCleanupTests.testOtherDeviceSetsAreReadFromTheirDeviceFiles` 加一处 ENOTDIR 断言（文件下面的路径算不存在） |
| B-R2（L5） | `CleanupService.emptyFrozenTrash` 删除后用 `try? identity(at:)` 回读。回读出错（EACCES、EIO）被压成 nil，与“已不存在”无法区分，计入已删除和字节 | 回读改为 `do/catch`：与冻结身份相同计失败；不存在（ENOENT、ENOTDIR 返回 nil）或身份不同计删除；回读出错计失败，不加已删除数和字节 | Codex 的 `testUnreadableTrashReadbackDoesNotReportDeletion`（预期 deleted 0、bytes 0、failed 1）；`FrozenTrashEmptyingTests` 原有用例同步检查删除名单 |
| B-R3（L5） | `ScanStore.confirmEmptyTrash` 对任何结果都调用 `removeTrashItemsFromCurrentResult()`，清掉全部 `trash_bins` 行 | `FrozenTrashEmptyResult` 新增 `deletedNames`（按冻结顺序，只含确认删除的条目）。扫描结果只去掉这些条目本身及其内部的行（按词法路径比较，同名前缀的兄弟条目不受影响）；跳过、失败、回读出错的条目和冻结之后才出现的条目保留；其他来源的行不动。“废纸篓已经是空的”路径仍用原来的无参数版本清空 | Codex 的 `testKeptTrashItemsRemainInTheScanResult`（全部跳过、全部失败两个场景）；新增 `FrozenTrashEmptyingTests.testOnlyDeletedEntriesLeaveTheScanResult`（删 2 失败 1，含子路径行、同名前缀行、未冻结行和其他来源的行） |

## 同类修复（不在 Codex 列出的 3 项内）

D23 智能扫描“清空废纸篓”项的执行器 `SafeCleanupExecutor.deleteFrozenTrashEntry` 删除后也用 `try? metadataReader.snapshot(at:)` 回读，回读出错同样会被当作已删除。它与 B-R2 是同一条不变量（“只有看见条目已不存在或已被替换才算删除”），所以一并修改：
- 与冻结身份相同：仍为 `deletionOutcomeUnknown` / `item-still-present`；
- `CleanupFileSystemError.vanished`：已删除；
- 其他回读错误：新的 `deletionOutcomeUnknown` / `deletion-readback-failed`，需核实，不计入已删除。

测试：新增 `CleanupTrashDeletionTests.testAFailedReadbackAfterDeletionIsNotCountedAsDeleted`，用一个删除后把夹具废纸篓权限改成 000 的假删除器，预期失败、已删除数 0、需核实、文件仍在；权限在执行后立即恢复，`tearDown` 中再恢复一次。原有的 `CleanupJunkActionableTests.testEmptyTrashDeletesOnlyFrozenEntriesInsideTheTrash` 继续确认真正删掉的条目仍算删除。

## 自测：验证（原始日志）

以下全部是本会话的自测，全部在工作区运行，`--scratch-path` 为任务临时目录；`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`。每次测试都带只读窗口监视器，记录到的窗口数都是 0。

| 检查 | 时间（2026-10-15／16） | 实际结果 | 日志（`review-b-fixes/logs/`） |
|---|---|---|---|
| 编译 | 23:59:32–23:59:49 | exit 1：`Darwin.stat(...)` 指的是结构体类型，调用写法错误 | `build-c4.*` |
| 编译 | 23:59:55–00:01:35 | exit 0 | `build-c5.*` |
| 定向测试 BR | 00:02:06–00:02:47 | 28 个套件 592 个，跳过 4，0 失败，exit 0。这次运行早于 00:03:28 加入的 ENOTDIR 断言 | `targeted-br1.*` |
| 编译 | 00:04:36–00:04:47 | exit 0（之后源码和测试没有再改，最后一次改动是 00:03:28） | `build-c6.*` |
| 定向测试全量 1 | 00:04:50–00:06:06 | 76 个套件 1,169 个，跳过 4，失败 1，exit 1。失败的是未改动的计时测试，见下文 | `targeted-final1.*` |
| 定向测试全量 2 | 00:06:47–00:07:57 | 同一组 1,169 个，跳过 4，0 失败，exit 0 | `targeted-final2.*` |
| 反证 | 00:08:13–00:17:27 | 12 项全部符合预期，exit 0；副本前后清单相同 | `counterproof-review-b.log`、`counterproof.meta`、`counterproof.stdout` |

三次定向测试中 Codex 回归测试的输出相同：
```
REVIEW_B_TRASH_RESULT skipped=1 failed=0 retainsTrash=true
REVIEW_B_TRASH_RESULT skipped=0 failed=1 retainsTrash=true
REVIEW_B_UNREADABLE_SET unknown=true offeredRuntimes=0
REVIEW_B_TRASH_READBACK deleted=0 failed=1 retained=true
```
修复前 Codex 记录的是 `retainsTrash=false`（两个场景）、`unknown=false offeredRuntimes=1`、`deleted=1 failed=0 retained=true`。

**跳过的 4 个**都需要显式设置环境变量才运行（读本机真实目录或计时）：`CleanupRuleScannerTests` 的两个本机采集测试、`CleanupWriteRecheckTests.testTwentyThousandFileWriteRecheckTimings`、`SystemUtilitySafetyTests.testLiveSetappUninstallInventoryWhenExplicitlyEnabled`。

**没有跑的套件**：B 批相关套件中 `MiniWindowCleanupPresentationTests` 会开窗口，按跳过名单（57 个类）没有跑。

**计时失败**：`OperationReportTaskLifecycleTests.testStuckPhysicalReadTimesOutAndReportsItsWorkerWithoutHanging` 在全量 1 中耗时 5.48 秒，超过断言上限；C 批第一次定向测试也出现过一次（3.72 秒）。单独运行和重跑都通过（约 0.33 秒）。这个测试和它测的报告任务代码本次和 C 批都没有改；`ScanStore` 本次只改了 `confirmEmptyTrash` 和新增的辅助函数。断言没有改。

## 自测：反证

在工作区的逐字节副本（`c-cp`，运行前用 `diff -rq` 核对与工作区相同）上运行。先跑基线：5 个相关套件 53 个测试 0 失败，删除与进程清单检查通过（155 条、246 处，与 B 批相同）。之后每项把一处修复改回原写法或改坏，只跑守护它的测试，预期失败；`HB1` 是等价的另一种写法，预期通过。每项结束后从备份逐字节恢复并核对哈希，全部为 OK；最后副本的完整清单与开始时相同。窗口监视器记录到的窗口数为 0。

| 项 | 改动 | 守护测试 | 预期 | 结果 |
|---|---|---|---|---|
| BR1a | 设备集 `stat` 失败一律返回空集合（回到“读不到就当不存在”） | Codex `IndependentBatchBReviewTests` | 失败 | 失败（2 处断言） |
| BR1b | 不存在的设备集返回“未知” | `SimulatorCleanupTests.testOtherDeviceSetsAreReadFromTheirDeviceFiles` | 失败 | 失败 |
| BR1c | 文件下面的路径（ENOTDIR）返回“未知” | 同上 | 失败 | 失败 |
| BR2a | 菜单清空废纸篓回读出错仍计为已删除 | Codex `IndependentBatchBReviewTests` | 失败 | 失败 |
| BR2b | 已删除条目不记名称 | `FrozenTrashEmptyingTests` | 失败 | 失败 |
| BR3a | 清空后仍删掉全部废纸篓行 | Codex `IndependentBatchBReviewTests` | 失败 | 失败 |
| BR3b | 只按名称前缀匹配，同名前缀的兄弟条目也被去掉 | `FrozenTrashEmptyingTests` | 失败 | 失败 |
| BR3c | 只去掉条目本身，不去掉其内部的行 | 同上 | 失败 | 失败 |
| BR3d | 其他来源的行也被并入废纸篓来源 | 同上 | 失败 | 失败 |
| HB1 | 行匹配改用集合写法（等价） | 同上 | 通过 | 通过 |
| BR4a | D23 执行器回读出错仍计为已删除 | `CleanupTrashDeletionTests.testAFailedReadbackAfterDeletionIsNotCountedAsDeleted` | 失败 | 失败 |
| BR4b | D23 执行器把已不存在的条目也算作结果未知 | `CleanupJunkActionableTests.testEmptyTrashDeletesOnlyFrozenEntriesInsideTheTrash` | 失败 | 失败 |

所有“失败”都是断言失败，不是编译错误（日志里每项都有对应的 `error: -[...]` 行）。

## 差异与哈希

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/review-b-fixes/`。`README.md` 说明各文件，`SHA256SUMS.txt` 覆盖目录内全部文件。

- `snapshots/review-b-fixes.diff`：以 Codex 复核用的 `b-tree` 为基准，本次 8 个文件的差异（含新文件）。
- `snapshots/review-b-fixes-files.sha256`：每个文件修复前（`b-tree`）和修复后（工作区）的完整 SHA-256。
- `snapshots/b-tree-vs-worktree.txt`：`b-tree` 与当前工作区全部不同的文件，共 25 个：本次 8 个、C 批 14 个、文档 3 个（DECISIONS、BOARD、B 批交接）。两批没有共同文件，所以这 8 个文件的差异只有返修。

| 文件 | 修复前 | 修复后 |
|---|---|---|
| `Sources/StorageCleanerMac/Services/SimulatorCleanupService.swift` | `d83ad9f4…` | `f45a7043450c1c3f108be67450b40264628015af36cd14368abfd6a814cc59a5` |
| `Sources/StorageCleanerMac/Services/CleanupService.swift` | `0d6c1492…` | `49d83c2ff7f0bd4a582b1c6ae47d4fb61cac5e8b94f81ccb09cee13b43a30472` |
| `Sources/StorageCleanerMac/Stores/ScanStore.swift` | `52a8c038…` | `050b11284894f2a81a5fa29b0f0ebf5500384deacd164adad2e425f5d017da5f` |
| `Sources/StorageCleanerMac/Services/SafeCleanupExecutor.swift` | `55d7af58…` | `c3990d2678cb0b0bea54e7cbbd417480e313db25bcac5908ef55d65b1c5772a3` |
| `Tests/StorageCleanerMacTests/FrozenTrashEmptyingTests.swift` | `124a567a…` | `d00fac204147952e585a2dd74e0403a6bd839bdf78ed0edd2eb180101471aecf` |
| `Tests/StorageCleanerMacTests/CleanupTrashDeletionTests.swift` | `702e6b7b…` | `8f8ebb4d06fd8f546eaba4498ff6dbacae4bb3c8ee627ef6fbf57b0eab71fd67` |
| `Tests/StorageCleanerMacTests/SimulatorCleanupTests.swift` | `11e4c4ec…` | `90ebb8287ab55d0378bdeb77ec2ab0c6d06b51e476bbb12dcb9304c53857bc4a` |
| `Tests/StorageCleanerMacTests/IndependentBatchBReviewTests.swift` | 新文件 | `53a46e2566f0eb54b1196a080aab38f2f5a8ac805b6f7239042ca7b81bfa47ee`（与 Codex `HASHES.json` 相同） |

## 仍未通过、未做或待实机

- B 批自己的完整门禁仍是 exit 1（Release 全量中菜单栏计时项，HEAD 对照同样失败），这个记录不改。修复后的代码随 C 批跑了一次不开窗口的完整门禁（2026-10-16 00:35–01:08，冻结副本包含本次的 8 个文件）：15 步全部 exit 0，Release 4,909 个、Debug 5,019 个，0 失败，计时项这次 98.83 ms（阈值 100 ms，未改）。详见 `d102-batch-c.md` 的“门禁”。这是自测，不是 Codex 复核。
- 57 个会开窗口的测试类没有跑；界面目视没有做。
- 实机：真实废纸篓中回读失败的情形、真实模拟器设备集无权限的情形都只用夹具测过；清空真实废纸篓和本机 `simctl delete` 都需要用户批准。
- A 批遗留：G1 文件分析／大文件列表的预计释放、G5 授权后只扫新增位置，本批没有实现；按用户与 Codex 的要求在 D104 补做，结果记在 D104 的交接。
- C 批的完整门禁已通过（自测），C 批与 D 批都还没有经过 Codex 复核或实机验收。

## 复核方法

```bash
cd /Users/developer/Developer/sc-worktrees/v2.0.1
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --build-tests --scratch-path <私有临时目录>
swift test --skip-build --scratch-path <同一目录> \
  --filter 'StorageCleanerMacTests\.(IndependentBatchBReviewTests|FrozenTrashEmptyingTests|CleanupTrashDeletionTests|SimulatorCleanupTests|CleanupJunkActionableTests)'
```
完整的定向测试过滤串在 `logs/final-filter.txt`（76 个套件）和 `logs/br-filter.txt`（28 个套件）。
