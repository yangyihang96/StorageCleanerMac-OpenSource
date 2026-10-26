# D184 应用瘦身交接

2026-10-23；工作目录 `/Users/developer/Developer/sc-worktrees/p02-universal`。仅实现本子任务；未 commit、安装、启动或改动已安装的应用，未修改 DECISIONS、ScanStore、Package.swift。未联网或调用其他模型；未发现可调用的 JEV 工具，未声称做过 JEV 复核。

## 文件与集成边界

起始工作树已有大量集成差异，完整状态保存在 `.build/d184-evidence/status-before.txt`。不要把整个 `git diff` 当作本任务补丁。

| 文件 | 本次作用 |
| --- | --- |
| `Sources/StorageCleanerMac/Services/UniversalMachO.swift` | fat32/fat64 只读解析、本机 CPU 判断、克隆内部切片替换与元数据核对 |
| `Sources/StorageCleanerMac/Services/UniversalBinarySafety.swift` | dev/inode/birth 与包树快照、原包 fd 跟踪、APFS、内部相对链接边界、严格签名、Apple 锚、运行中检查、原生 Gatekeeper 评估 |
| `Sources/StorageCleanerMac/Services/UniversalBinaryService.swift` | 应用清单、可注入系统边界、逐应用克隆/校验/交换/回执/补偿与结果 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioAppThinning.swift` | 独立审阅和确认页；后台扫描/执行；共享 HeavyWorkCoordinator 的 mainScan/cleanup lease |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkResults.swift` | 只增加结果卡、sheet、扫描任务及可选黄色边框；没有重排网格 |
| `Sources/StorageCleanerMac/Services/RecordedTrashOperation.swift` | `runAsync` 增加默认 nil 的 prepare 钩子；D184 在准备交换前先持久化 in-flight；原调用不传参数，原验证次序保持不变 |
| `Sources/StorageCleanerMac/Models/CleanupExecutionModels.swift` | D184＋旧值：授权恢复以前仅支持 `/Applications`，现在仅 D184 回执额外支持 `/Applications/Utilities` 的第一层 app |
| `Tests/StorageCleanerMacTests/UniversalBinaryD184Tests.swift` | 三个测试类，共 41 个测试 |
| `script/check_deletion_process_inventory.py` | 增加 clone 类型，识别 clonefile/clonefileat/fclonefileat |
| `script/deletion-process-inventory.txt` | 登记新 clonefile、rename、renamex_np、removefile、trashItem；同时登记新检测器识别出的既有 APFSCloneReplacement.clonefile |
| `script/private-api-allowlist.txt` | 登记 SecAssessment 动态符号与原生执行评估理由 |
| `script/test_check_deletion_process_inventory.py` | 只增加 clone 检测测试，原断言不变 |
| 本文 | 验证证据与主会话验收步骤 |

精确的 13 文件清单见 `.build/d184-evidence/touched-files.txt`。既有文件的修改前快照在 `before/`；RecordedTrashOperation 的快照由刚应用的两处钩子差异精确反推，其余文件在修改前直接复制。最终限定补丁放在 `.build/d184-evidence/d184.patch`，供主会话逐项核对后集成。

## 判定与跳过

- 仅枚举 `/Applications`、`~/Applications`、`/Applications/Utilities` 的第一层 `.app`；可选目录不存在不报扫描失败。
- root/其他用户拥有、应用或父目录不可写、Apple `anchor apple`、MAS receipt、本产品三个渠道及自身路径、正在运行、原签名无效全部跳过。运行中检查复用 `FoundationCleanupRunningApplicationChecker`，还核对包内 helper 的 bundle ID、bundle/executable 路径。
- 严格验签使用 `kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode`，不设置启用网络访问的 flag。
- 检查整个包树，拒绝外部、断开和绝对符号链接、跨卷节点、特殊文件、dataless/锁定文件、硬链接、无法读取或不属于当前用户的实体。相对且留在包内的 framework 链接保留，实际文件只计一次。绝对链接即使指向原包内部也跳过，避免克隆后仍指回原包。
- 仅在指定的七个 Contents 子目录读取普通文件的有界文件头。支持大端 FAT_MAGIC/FAT_MAGIC_64，拒绝字节交换 fat、畸形表、越界、重叠、无效对齐、重复架构和非零保留字；最多 64 切片。单切片、缺本机、多本机子类型不处理，不猜 loader 的选择。预计节省量仅为非本机切片大小之和。
- Apple 芯片检测兼容 Rosetta；Intel 保留 x86_64。每行显示名称、版本、涉及文件数及 `ByteFormat.storageString`，所有计数用 `ByteFormat.count`。

只读 lstat 统计（不是签名/可瘦身容量实测）：`/Applications` 68 个 app 条目中 28 个 root 拥有、1 个是链接；`~/Applications` 7 个、root 0；Utilities 1 个链接。共 76 条目、28 个 root 拥有、2 个链接条目。28 个 root 应用本批不处理。证据：`application-ownership-counts.json`。

## 执行、回退和恢复

1. 每个应用独立重新扫描，核对身份、完整树快照与切片计划，复核关闭、签名、所有跳过条件、源与父目录的 APFS 格式。持有原包目录 fd，先验证 fstat 身份与 F_GETPATH 路径能力；不满足时在改动前跳过。
2. 原生 `SecAssessmentCreate` 执行评估原包，取 `SecAssessmentCopyResult` 的明确 verdict。原包获准的，克隆也必须获准；评估不可用或结果不完整则拒绝操作。当前 SDK 无公开声明，因此从 Security.framework 动态获取函数和实际常量，已登记；本机五个符号均存在（`gatekeeper-symbols.json`），没有调用外部程序。
3. 在同父目录生成带 UUID 的 `.storagecleaner-thin-<UUID>.app`，只用 clonefile，不提供生产复制回退；克隆身份立即记录。测试夹具所在卷已核实为 APFS，因此本轮使用真实 clonefile（`filesystem.json`）。
4. 仅在克隆内逐文件读取本机切片，写入同目录 O_EXCL 临时文件；复制并核对权限、owner/group、ACL、全部 xattrs；fsync 后 rename。然后严格验签克隆，按原包 verdict 评估克隆。
5. RecordedTrashOperation 先写 intent，再写 in-flight；prepare 才复核树、签名、运行状态并 `RENAME_SWAP`。随后通过既有回执路径移走原包。被移走的原包使用可见的“瘦身前”副本名；从操作记录放回时回到同文件夹的该副本名，保留当前瘦身应用，不覆盖它。
6. 交换前失败：只删除名称模式和 dev/inode/birth 均吻合的本次克隆。交换后移动拒绝、回执失败：有可核对的原包时先从注入/真实 Trash 移回临时位置，再交换回原位，最后删除拒绝的克隆。即使 Trash 已移动却抛错、未给出目的 URL，或给出错误对象，也优先从原包 fd 的 F_GETPATH 找到实际位置，核对身份后取回；返回 URL 只作为身份吻合时的后备。测试确认原身份恢复、原位为旧内容、无克隆残留、无关对象不动。原包从不永久删除。
7. 边界：若回滚时原位置出现其他对象，或原包 fd/路径/身份已不可验证，不能安全替换它；此时保留原包与瘦身副本，保留 unknown 回执并显示需查看操作记录/文件夹。身份冲突保留分支有测试。断电/进程被杀也不等于自动回滚；in-flight 先落盘，原包仍在同目录或 Trash。不要把这种冲突说成“原位置已恢复”。若 clonefile 抛错并留下无法确认身份的项目，也只报告保留路径，不删除未知对象。
8. 成功只计“清空废纸篓后预计释放”；即时永久释放量为 0。

## 页面

选择垃圾结果里的独立“应用瘦身”组：黄色边框、需审阅、默认不选，不纳入普通清理/智能扫描的批量选择或普通删除计划；开发者垃圾和仅健康扫描不显示。独立分组的理由是这里会修改签名应用，确认和失败回退与普通垃圾不同。确认列出勾选应用，并明确改动应用、原包进 Trash 可放回、增量更新可能失败且需重装、清空 Trash 后才释放空间。中英文沿用项目的双语函数 `L10n.text`，数字遵循 D178。未更改 ScanStore，也没有重排既有布局。

## 测试与实际命令

所有日志及 exit 文件均在 `.build/d184-evidence/`。

先只复制现有本地 `~/Developer/.sc-build/v2.0.1/bootstrap/{checkouts,repositories,artifacts,workspace-state.json}` 的 Sparkle 2.10.0 依赖并重定位 artifact 路径，没有复制编译输出，没有联网。首次 build 从头编译。

共同环境和命令：

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox
nice -n 15 swift test --scratch-path .build/codex --skip-build --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --filter '^StorageCleanerMacTests\.(UniversalMachOTests|UniversalBinaryWorkflowTests|UniversalBinaryInventoryTests)'
```

| 记录 | exit | 结果 |
| --- | --- | --- |
| build-1.log | 1 | 首次全编译；新增测试遗漏一处 try，已修正 |
| build-2.log | 0 | 构建通过 |
| tests-1.log | 1 | 30 测试、23 失败；夹具登记父目录及 journal URL 目录标记问题，已修正；未改公共守卫或断言 |
| build-3.log / tests-2.log | 0 / 0 | 30 测试，0 失败 |
| build-4.log / tests-3.log | 0 / 0 | 回执 prepare 补强后；39 测试，0 失败，0 跳过 |
| build-5.log / build-6.log | 0 / 0 | 原包 fd 跟踪与回执异常补强；此两次仅构建，随后继续复核 |
| build-7.log / tests-4.log | 0 / 0 | 最终版本；41 测试，0 失败，0 跳过；已将外部链接拒绝前移到原生验签之前 |
| `python3 -B script/display_bound_tests.py --check` | 0 | 63 in-process、1 out-of-process、1 exempt；未更改 display-bound 清单 |
| `python3 -B script/check_deletion_process_inventory.py` | 0 | 181 条登记、273 次使用 |
| `python3 -B script/check_private_api.py` | 0 | 10 条登记 |
| `python3 -B -m unittest discover -s script -p test_check_deletion_process_inventory.py` | 0 | 11 测试通过 |
| 对既有改动文件的 `git diff --check -- <文件>` | 0 | 无空白错误 |
| `git apply --reverse --check .build/d184-evidence/d184.patch` | 0 | 限定补丁与当前 13 文件一致；另逐行检查新增行无尾随空白 |

Swift 测试类：UniversalMachOTests 12、UniversalBinaryWorkflowTests 20、UniversalBinaryInventoryTests 9。覆盖大小端魔数、fat32/64、Intel/Apple、多个外来切片求和、截断/计数/offset/size/overflow/重叠/对齐/保留字段/重复架构、单切片/无本机/多本机、切片字节/权限/xattrs、原包保护、包范围与链接（在验签读取资源前拒绝）、运行/身份/原内容变化、非 APFS、clone/签名/Gatekeeper/回执/Trash 失败、回滚、无目的 URL/错误目的 URL 的 fd 找回、回滚身份冲突保留两份、in-flight 写入次序、放回原包、默认 prepare=nil 和 Utilities 受限授权。

原有测试没有删除、放宽、跳过或移动类别。本轮改动文件 0 编译警告（`warnings-audit.json`）；日志保留原有文件的基线警告、未改动 APFSCloneReplacement 的 String(cString:) 弃用警告、SwiftPM 全局缓存只读警告和既有链接 rpath 警告。

## NOT RUN 与主会话实测

沙箱内只操作 `.build/d184-fixtures` 的 UUID 假应用、假 Trash、独立 journal，结束后严格清理；签名和 Gatekeeper 注入，不把假包声称成真实签名验证。未运行完整 verify、安装/窗口显示、真实应用变更、真实 Trash 放回、真实增量更新或 Intel 实机验收。root 属主拒绝通过真实只读所有权统计及源码核对；没有越权 chown 来造 root 夹具。

主会话在获准安装测试版后：

1. 选择当前用户拥有、可写、非 Apple/Store/本产品、已关闭的第三方 Universal 应用；先用同一原生严格验签/执行评估入口记录结果、版本、包身份和可节省量。
2. 打开垃圾结果→应用瘦身，确认默认未选、黄色和两种语言文案；勾选一项并审阅，确认后记录逐项结果，确认回执存在及即时永久释放量为 0。
3. 对原路径的新包再次原生验签/评估，检查只留下本机切片，手动从访达启动并验证常用功能。若签名或系统评估拒绝，预期原应用保留且克隆被清理，记录原因。
4. 在操作记录把原包放回，确认它以“瘦身前”副本名出现在同文件夹、内容仍为 Universal、当前瘦身包没有被覆盖；关闭应用后再决定后续处理，不自动清空真实 Trash。
5. 打开应用再尝试该项，确认运行中跳过；改变包身份后确认陈旧清单跳过；仅在适当隔离对象上测试更新及失败回退。个别应用增量更新是否兼容仍须真实样本验证。
