# D188 下半：安全防护的最近使用项目

工作目录：`/Users/developer/Developer/sc-worktrees/p02-recent`。只处理最近使用项目；维护推荐由另一会话负责。保留进场时已有差异及未知文件；未改 DECISIONS，未 commit、安装、启动测试版或操作真实最近使用列表。

状态：本子任务实现和指定沙箱验证通过。最终构建 exit 0；新增 30 项测试全部通过、0 跳过；本任务改动文件 0 编译警告。实机系统列表和 UI 验收待主会话执行。

## 文件及作用

生产模块位于 `Sources/StorageCleanerMac/`：

| 文件 | 作用 |
| --- | --- |
| `Features/RecentItems/RecentItemsScanner.swift` | 白名单、无链接读取、归档类元数据计数、明确的缺失证据 |
| `Features/RecentItems/RecentItemsProcessController.swift` | 当前 UID 的 KERN_PROC 查询、逐 PID 复核、只发 SIGTERM |
| `Features/RecentItems/RecentItemsCleanupService.swift` | 确认门、冻结清单、既有回执路径、服务重启、两秒后核实 |
| `Features/RecentItems/RecentItemsStore.swift` | 默认空选择、冻结确认、应用名称/图标、运行状态、执行状态 |
| `Features/RecentItems/RecentItemsPresentation.swift` | 中英文摘要、分组、确认提示、逐项核实结果 |
| `Views/CareStudio/CareStudioRecentItems.swift` | 查看、确认和完成三阶段 sheet；复用确认事实及完成统计组件 |
| `Views/CareStudio/CareStudioProtection.swift` | 追加最近使用卡片及 sheet，不重排既有布局；页脚区分浏览备份与废纸篓恢复 |
| `Views/BrowserPrivacyWorkspaceView.swift` | 持有本次扫描状态；防护结果出现时只读扫描；预览/夹具不扫描真实目录 |
| `Views/ContentView.swift` | 传入现有 HeavyWorkCoordinator，完成后刷新操作记录 |
| `Models/OperationRecordPresentation.swift` | 新规则 ID 的操作记录标题；旧规则分支保持原行为 |

其他文件：`script/deletion-process-inventory.txt` 增加信号调用说明；新增 `Tests/StorageCleanerMacTests/RecentItems{Scanner,Cleanup,Presentation,SourceGuard}Tests.swift` 及 `RecentItemsTestFixture.swift`。原有测试未删未改，未修改旧期望，因此无“D188＋旧值”替换项。

## 白名单与读取

仅扫描当前用户 `Library/Application Support/com.apple.sharedfilelist` 的直接文件：

- `com.apple.LSSharedFileList.RecentDocuments.{sfl2,sfl3,sfl4}`
- `com.apple.LSSharedFileList.RecentApplications.{sfl2,sfl3,sfl4}`
- `com.apple.LSSharedFileList.RecentServers.{sfl2,sfl3,sfl4}`
- `com.apple.LSSharedFileList.RecentHosts.{sfl2,sfl3,sfl4}`
- `com.apple.LSSharedFileList.ApplicationRecentDocuments/` 的直接 `包标识.{sfl2,sfl3,sfl4}` 文件。包标识只允许非空的点分段、ASCII 字母/数字/连字符，且排除 `com.apple.LSSharedFileList.*` 系统列表名。

`FavoriteItems`、`FavoriteVolumes`、`TopSidebarSection`、`ProjectsItems`、`iCloudItems`、其他根目录文件名及扩展名均不入清单。目录、符号链接、链接祖先及嵌套目录不认可。移动前再次核对白名单、普通文件、无链接、设备/inode/创建时间身份、大小和修改时间。

读取用 `PropertyListSerialization`，验证 NSKeyedArchiver/version/objects/top 引用；遍历 `$objects` 中实例的 `$class`，只数 `$classname` / `$classes` 含 `SFLListItem` 的实例，不把类描述本身算条目。二进制 UID 仅经公开 plist 序列化转换成引用专属 XML，取其 CF$UID 整数；不使用私有 UID accessor、NSKeyedUnarchiver 或私有类实例化。不查看书签、URL、标题等载荷内容。

格式不支持、引用损坏、读取失败或超过 32 MiB 的文件显示“条目数未知”。有未知列表时合计明确标注只读到了多少及有多少未知，不宣称完整总数。文件夹读取受限另标“结果不完整”。扫描只读，不触发服务重启。

## 清理、失败和恢复

1. 默认全部不选。卡片“查看”打开分组清单；“移除”打开冻结确认页，零选择时只能先选择列表，执行按钮禁用。未确认、无选择或完全不在白名单时，不申请执行租约、不建回执、不移动、不查进程、不等待。
2. 显式确认后取得既有 `.cleanup` 独占租约，交给 `RecordedTrashOperation.run`。生产使用它已有的原生废纸篓实现，不增加删除或移到废纸篓入口。逐项身份复核及持久 intent/回执沿用 D46；文件变动、权限和回执失败沿用共同统计及原因显示。
3. 所有移动尝试结束后，只有确实移走过列表才处理服务。sysctl 使用 KERN_PROC_UID/getuid，逐 PID 以 KERN_PROC_PID 再查；只允许 `pid > 1`、名称精确为 `sharedfilelistd`、UID 为当前用户，且两次记录一致的进程收到 SIGTERM。没有可用进程就跳过；查询/信号失败明确提示；不启动进程，不重试。
4. 生产等待两秒后只进行一次白名单扫描，同一快照用于选中列表核实及页面刷新。空列表或有无链接的明确缺失证据显示“已确认列表为空或不存在”；非空显示“系统已写回，可能要注销后才清空”；新链接、权限问题或格式未知显示“无法确认列表是否已清空”。未移动项单列“未移走，请查看操作回执”。不自动再次移走系统重建的文件。
5. 应用运行状态用 NSWorkspace 只读解析，在确认的“需退出的应用”列出对应运行应用，并说明建议先退出。选择提示、不强制退出：不接管其他应用的退出/未保存文稿，由用户决定；清理后按实际写回结果报告。
6. 操作记录标题为“最近使用项目 · 移到废纸篓”。放回沿用现有恢复服务；系统已重建同名列表时报告冲突、保留新列表，不覆盖。确认页也说明此限制。没有永久删除或空间已释放的承诺。

应用名和图标通过 NSWorkspace 从包标识解析，无法找到时显示包标识。系统列表按最近的文稿、应用、服务器及各应用的最近文稿分组；主列表与每个应用列表可能有同一文稿，数量按列表项相加，不解书签去重。

## 页面与探针

卡片摘要使用 `ByteFormat.count`。所有新增文案通过 `L10n.text` 提供中英文；不包含书签内的条目名称。确认明确废纸篓与操作记录恢复、系统服务短暂重启、两秒后检查、访达边栏/收藏不受影响。

DEBUG 探针：`careStudio.protection.recentItems.review`、`.confirmation`、`.result`。复选框可通过 `recentItems.list.<列表文件名>` 的 accessibility identifier 定位。既有防护页探针 `careStudio.results.protection` 保留。独立预览没有执行 coordinator 时不能执行清理，也不读取真实列表。

## 清单登记

现有清单检查器的 KINDS 只有 delete/rename/trash/launch/script/executable，不统计 kill/信号函数引用。因此没有伪造一个会让检查器报未知种类的可执行条目；在 inventory 中以注释按原六列格式登记 `signal | ...RecentItemsProcessController.swift | Darwin.kill (function reference) | 1 | 2026-10-23 | 理由`。

`RecentItemsSourceGuardTests` 锁定 getuid、精确进程名、正 PID、UID、重新查询及 SIGTERM，且特性目录不含新删除/原生 Trash/启动入口。运行时测试注入假枚举、假逐 PID 查询及假信号函数，覆盖其他 UID、其他名称、相似名称、无效 PID、PID 改变、无进程、信号失败和执行顺序。

## 测试与实际命令

新增 30 项：Scanner 8、Cleanup 13、Presentation 6、SourceGuard 3。覆盖三种扩展名、完整正/反白名单、链接与目录、正常/空/损坏归档及未知格式；确认门、去重/仅勾选、身份变化、持久回执、历史恢复与冲突、写回/空/未知结果、回执失败、并发租约、信号顺序；中英文卡片/确认文案、应用名回退、默认不选及重扫清空选择。

所有文件为自产夹具，不读真实 sharedfilelist。移动注入为夹具内改名，信号与等待全为假函数。默认使用 TestFileSystem 的隐藏家目录操作夹具；本沙箱将 TMPDIR 指向工作区内，因此通过同一工厂生成并登记工作区中的临时夹具，不修改 HOME、不放宽产品路径检查。每项测试结束严格回收自己的根。

离线依赖从 `/Users/developer/Developer/.sc-build/v2.0.1/bootstrap/{checkouts,repositories,artifacts,workspace-state.json}` 复制到 `.build/codex` 并重写 workspace-state 中的缓存路径；未复制编译对象，首次从头编译，未联网。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox

# 当前沙箱只允许工作区和系统临时目录写入；同时避开 /var 祖先链接。
mkdir -p .build/p02-recent-evidence/tmp
export TMPDIR="$PWD/.build/p02-recent-evidence/tmp"
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --filter '^StorageCleanerMacTests\.(RecentItemsScannerTests|RecentItemsCleanupTests|RecentItemsPresentationTests|RecentItemsSourceGuardTests)'
python3 -B script/display_bound_tests.py --check
python3 -B script/check_deletion_process_inventory.py
python3 -B script/check_private_api.py
git diff --check
```

证据目录 `.build/p02-recent-evidence/`。每次构建/测试及门禁有同名 `.log` 与 `.exit`。`p02-d188-files.txt` 列出全部 17 个交付文件；`status-before.txt` / `status-after.txt` 保留进出场状态；已有状态项无消失。

| 最终命令/证据 | exit code | 结果 |
| --- | --- | --- |
| 构建，`build-06.log` | 0 | 最终代码与全部测试目标构建通过（414.99 秒） |
| 上述四类锚定过滤测试，`tests-04-final.log` | 0 | 30 tests、0 failures、0 skipped；主测试包约 9 秒 |
| display-bound，`display-bound-final.log` | 0 | 63 in-process / 1 out-of-process / 1 exempt，无清单漂移 |
| deletion inventory，`deletion-inventory-final.log` | 0 | 175 entries / 267 uses |
| private API，`private-api-final.log` | 0 | 原有 9 allowlisted uses，没有新增私有 API |
| `git diff --check`，`diff-check-final.log` | 0 | 无空白错误；新增文件另按任务清单检查也是 0 行尾空白 |

`changed-file-warnings.txt` 汇总所有构建记录：这 17 个任务文件 0 warning。`changed-file-whitespace.txt` 记录新增/修改文件行尾空白检查结果。XCTest 的其他测试包因锚定过滤运行 0 项，不计入本次 30 项通过。

前序失败保留证据：`build-01` exit 1（编译期间元数据类型改名导致旧主模块与新测试符号不一致）；`build-02` exit 0；`tests-01` exit 1（临时路径 /var 链接和 UID XML 再解码问题）；`build-03` exit 0；`tests-02` exit 1（28 项已过、回执夹具目录标记缺失）；`build-04` exit 0；`tests-03-diagnostic` exit 1（两个针对性用例将原因定位到 readWithEvents 的目录 URL 校验）；`build-05` exit 0（夹具修正）；`build-06` / `tests-04-final` 均 exit 0（加入单次回读守卫后的最终验证）。修复仅涉及自己的代码和夹具，未放宽断言。进程清单首轮 exit 16 是自定义元数据类型名 Process 的误报，改名 ProcessIdentity 后通过。

所有构建/测试命令按要求带 nice -n 15；沙箱输出 `nice: setpriority: Operation not permitted`，因此不能声称优先级已成功降低。构建仍固定 jobs 4。SwiftPM 用户级缓存写入在沙箱被拒绝；只使用本工作区 scratch。首轮完整构建还输出未改文件 UpdateAskpassInvocationRegistry、APFSCloneReplacement 等警告，部分不在提供的 baseline-warnings.txt 中，详见构建日志；未为本任务修改这些文件。

## 未做的实机验收及主会话下一步

没有安装、制作/替换 Beta、运行 UI 截图/显示测试或操作真实列表/进程；没有跑整个 verify.sh / Release / 全量测试。JEV 未调用：本轮没有其已授权来源及预算，工具中亦未发现 JEV；未换模型/供应商、未发起额外模型调用。

安装测试版由主会话执行并实测：

1. 先记录苹果菜单“最近使用的项目”、访达侧栏和收藏；打开文件、应用及服务器产生可辨认记录，扫描防护，核对 N、分组、图标、未知数量及默认全不选。
2. “查看”只读；“移除”在未勾选时禁用执行。勾选一个列表，核对冻结确认清单、恢复/服务重启/不影响收藏提示及建议先退出的应用。取消后确认没有修改文件或服务。
3. 退出对应应用后确认清理，核对废纸篓有原列表、操作记录有可放回回执；两秒后检查苹果菜单“最近使用的项目”，确认选中类别已空。未选类别、访达侧栏和收藏须保持正常。
4. 保持应用运行做一组单独验证，观察写回时显示指定提示；不自动重试。对已重建的同名列表尝试放回，必须提示冲突且保留新列表；不存在同名文件时从操作记录放回，再打开系统/应用确认可用。
5. 中英文分别检查卡片、查看/确认/完成页；在 1280×763 与 980×520 下核对滚动和按钮可达性。实际系统的 sfl4 类结构若未识别应显示未知，禁止把未知误报成零。
