# 批次 2a 交接：数据安全闭环

- 实现：Claude（主会话）　复核：全新上下文的 Claude 子代理（只读）
- 分支：`task/batch2a-data-safety`，基于 `b55cd70`（批次 1 末提交）

## 改动

| # | 问题 | 改动 | 文件 |
|---|---|---|---|
| 1 | 中断对账只在测试里运行：生产调用全部 `reconcile: false`，唯一的内联调用用 `try?` 吞掉错误，且废纸篓不可读时连恢复对账也一起跳过 | 启动时、打开“操作记录”、点“刷新”时都运行；废纸篓对账与恢复对账各自运行；单条坏回执不再拖住其他回执；租约被占、废纸篓不可读、部分失败分别给出提示（废纸篓不可读时附“打开设置”）；对账时保留用户“已取消”的结果 | `Services/CleanupReportJournal.swift`、`Services/RecordedCleanupRecovery.swift`、`Stores/ScanStore.swift`、`Views/ReversibleOperationsView.swift`、`App/StorageCleanerMacApp.swift`、`Models/CleanupExecutionModels.swift` |
| 2 | 恢复时 `invoked = true` 设在移动之前，原子重命名失败（同名冲突、无权限、跨卷）也记成“结果不明”并永久锁住重试 | 只有辅助程序提交后无回复、或移动后校验失败才记为结果不明；其余按错误归为冲突／身份变化／失败，保持可重试 | `Services/SafeCleanupExecutor.swift` |
| 3 | 旧“恢复最近清理”走 `CleanupService.restoreFromTrash`，不写回执日志；操作记录页恢复后旧入口仍提供同一文件 | 有日志回执的记录改走日志恢复；已恢复或待核实的不再移动；无日志回执的旧记录走原路径；操作记录页恢复后同步清掉旧历史中对应记录；0 字节的已移动项也记入旧历史 | `Services/LegacyCleanupRestore.swift`（新）、`Services/CleanupHistoryService.swift`、`Stores/ScanStore.swift` |
| 4 | 回执在主线程同步落盘：主线程只“试”一次锁，锁被占就误报保存失败；fsync 卡界面 | 新增 `CleanReportStore.recordDetached`，在后台线程等待锁；5 处调用改为 `await` | `Services/CleanupMigration.swift`、`Stores/ScanStore.swift` |
| 5 | 小窗历史日志尾部撕裂后每次启动都重新冻结，从此不再保存 | 先把原日志逐字节另存为 `*.events.damaged-<时间>-<id>`，再从有效前缀写检查点并开新日志；另存失败则保持冻结、不动原件 | `Support/MetricHistoryJournal.swift`、`Support/MenuBarPowerHistoryStore.swift` |

“卸载重试不覆盖原报告”按看板调整移到批次 3a，与其他卸载改动一起做。

## 测试

新增 `InterruptedOperationReconcileTests`（5 项）、`LegacyCleanupRestoreTests`（4 项）；`MetricHistoryJournalTests` 两项按新行为更新，另加 1 项另存失败时保持冻结。
关键回归测试做过反证：把 `invoked = true` 放回移动之前，`testRestoreThatMovedNothingStaysRetryable` 按预期失败（outcomeUnknown、回执被锁）。

## 复核（全新上下文的 Claude 子代理）与处理

结论“需修改后合并”。P0 一项，已修：

- **P0**：旧“恢复最近清理”只按“原路径 + 废纸篓名”绑定日志报告，再恢复整份报告。废纸篓清空后同名会被复用，旧记录可能绑到后来另一次清理（智能清理、卸载）的报告上，用户只确认一条却移回整批文件，恢复提示也只算一条。复核者在副本里复现了失败。
  处理：只匹配旧路径自己写的报告（`cleanup.legacy-paths.v1`）；必须是同一文件（设备号、inode、创建时间都相同），有多份时取移动时间相同的那份，否则取最新；`restore` 新增 `onlyOriginalPaths`，只恢复已确认的那几项；从操作记录恢复后清理旧历史时同样按身份匹配。复现场景改为 3 项回归测试（旧记录不绑新报告、报告顺序不影响绑定、只恢复确认项，同批其他项留在废纸篓）。

P2 已处理：小窗历史恢复成功后不再报“未保存”；同样的损坏字节只另存一次；“废纸篓不可读”只在列举废纸篓失败时判断；刷新进行中再次请求不再丢弃，结束后补跑一次；租约被占且没有待核实记录时不提示，其他租约错误显示“未能核对”；卸载、关联文件、旧单项清理都改为先保存回执再显示结果（避免先恢复、后被旧回执覆盖）；对账只读一遍日志；`ScanStore` 注入回执日志，原有集成测试改用隔离目录；chmod 类测试在 root 下跳过；文案统一为“待核实”“打开系统设置”；日志读取失败时显示本地化说明而不是内部类型名。

P2 未处理（记入后续）：对账占用恢复租约期间，用户发起其他任务会看到“正在进行废纸篓恢复”（对账通常为毫秒级）；`recordDetached` 等锁没有超时；界面触发对账（`.task`、刷新、启动）与“等锁不误报”没有自动化测试（后者会碰真实日志目录）；旧入口失败原因只显示计数、未逐项展示；“身份已变化”有多种说法，归批次 5 统一。

（门禁结果在合并前补全。）

## 需要的决定记录

小窗历史“尾部损坏后继续保存”改变了两条旧测试锁定的行为（原为“永久冻结以保护证据”）。证据仍以逐字节副本保留。此项属于已批准计划的批次 2a 内容，合并时在 DECISIONS 记为 D10。

## 遗留

- 对账只把“在废纸篓里找到同一身份”的项改为已移动；原位置仍在、废纸篓里没有的项继续标为待核实（这类移动确实没发生）。是否把它们改记为“未移动”需另定，暂不改语义。
- 对账只查 `~/.Trash` 顶层；外接卷 `.Trashes` 中的项不在范围内。
