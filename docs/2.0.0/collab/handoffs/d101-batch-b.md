# d101-batch-b：竞品逆向改进 B 批（删除语义）

批次：B / D101。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`。本批全部改动未提交，与 D98–D100 和 A 批返修的未提交改动在同一工作区。计划文件是 `~/Claude 好玩的/Mac清理与监控软件逆向-2026-10-15/2.0.1改进计划.md`（SHA-256 `169ed23e1070d1e6…`，与 A 批相同）。各项的产品决定见 DECISIONS D101，本文只记实现、测试、证据和未完成的部分。

本批没有做以下事情：提交、合并、安装、重启、启动 App、对真实数据执行清理（包括本机的 `simctl delete` 和清空废纸篓）、写风扇／电源模式／SMC。接触真实数据的只有两处只读核实：
- G2：在本机运行 `xcrun simctl list -j devices` 和 `xcrun simctl runtime list -j`，只读列表。
- G7：读取本机 iStat Menus（Setapp 版）安装包的 `Info.plist`、可执行文件里的字符串，用 `lsof`、`ps` 和一个只读的 `NSRunningApplication` 脚本查看进程。没有移动、修改或删除这些文件。

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-b/`，包括原始日志、批前批后的差异快照、反证脚本和门禁脚本。

## 完成项

| 项 | 改动 | 测试 |
|---|---|---|
| L5 | 菜单里的“清空废纸篓”改为：请求时冻结废纸篓和每个条目的身份，两次确认，只删除冻结的条目，复用 D23 的删除器；删除 `CleanupService.emptyUserTrash` | `FrozenTrashEmptyingTests` 14 项；`PermanentDeletionInvariantTests` 4 项；`CleanupTrashDeletionTests`、`CleanupSafetyTests` 已有测试同步更新 |
| G13 | 单次计划超过 10,000 项，或超过所在卷已用空间的一半时，确认页显示规模摘要并多一道勾选；按会执行的条目判断 | `CleanPlanScaleAlertTests` 5 项；`CleanupExecutionSafetyTests`、`CleanupStoreFollowUpTests` 各有对应测试；`UIConsistencyRegressionTests` 源码断言 |
| G4-2 | 第 1 层 `ProtectedLocations`（文件分析、卸载、扫描共用）；第 2 层规则校验拒绝起点在受保护位置内的规则，扫描时受保护位置只计数不列出；第 3 层 `FileProtectionFlags`（helper、卸载、文件分析共用同一组 BSD 标志） | `ProtectedLocationLayersTests` 6 项；`CleanupJunkActionableTests` 1 项 |
| G10 | Bun 安装缓存规则 `developer.bun-install-cache`；绿色项按 G1 保守预计释放过少时不预选（`freesLittle`） | `BunInstallCacheRuleTests` 3 项；`CleanupDefaultSelectionPolicyTests` 中的 G10 测试 |
| G2 | “开发工具与产物”页新增模拟器数据入口：只读列出不可用设备和没有设备使用的运行时，逐项按 UUID 删除，两次确认 | `SimulatorCleanupTests` 12 项 |
| G9 | 卸载页识别同一开发者（Team ID 相同）的官方卸载程序，用户点击才打开 | `VendorUninstallerTests` 9 项 |
| G7 | iStat Menus（Setapp 版）历史库规则 `user-data.istat-menus-setapp-history`，黄色、默认不勾选，写入进程都退出后才执行 | `IStatMenusHistoryRuleTests` 3 项 |

规则集：`rulesVersion` 2026.10.15.2，共 81 条（JSON 12 条），基线 81 条，新增两条都是修订 1；`docs/2.0.1/cleanup-rule-table.md` 已重新生成。L8 清单从 153 条、243 处变为 155 条、246 处：L5 删去 `CleanupService` 的 `removeItem` 一条（原 `emptyUserTrash`），G2 新增 `Shell.run`、`/usr/bin/xcrun` 各一条，G9 新增 `openApplication` 一条（2 处）。

## 编译和定向测试中发现并修正的问题

全部在测试代码或测试夹具里，没有为此改产品代码。没有放宽任何断言：要么改成用同一种路径写法比较同一个位置，要么让测试与它的名称和注释所说的一致。

编译错误 2 处（21:26、21:27）：
- `SimulatorCleanupTests` 调用了 `withLanguage`，但没有定义。每个测试类都有自己的私有版本，照 `FrozenTrashEmptyingTests` 的写法补上。
- `BunInstallCacheRuleTests` 第 91 行在 `XCTUnwrap` 的自动闭包里调用了 `try await`，拆成两句。
- 另外去掉了 `FrozenTrashEmptyingTests` 里两处多余的 `try`（编译警告）。其余 4 条编译警告所在文件与 HEAD 完全相同，不是本批引入的。

第一次定向测试（21:29–21:30）：708 个，跳过 4 个，**失败 10 个**，原因如下：

| 测试 | 原因 | 处理 |
|---|---|---|
| `VendorUninstallerTests` 2 个 | 本机的目录遍历（`contentsOfDirectory`、`enumerator`）返回 `/private/var/...`，而夹具根目录写成 `/var/...`；这两处直接比较了 `url.path` | 改用类里已有的 `paths(_:)`，先转成 lexical 写法再比较。setUp 里的注释写反了（`resolvingSymlinksInPath()` 得到的是 `/var/...`），已更正 |
| `IStatMenusHistoryRuleTests` 1 个（2 处断言） | 同一个写法问题：临时打印候选项后确认只列出了 `history` 一项，但路径是 `/private/var/...`，被 `/var/...` 前缀过滤掉了 | 按 lexical 写法过滤和比较 |
| `SimulatorCleanupTests.testARuntimeInUseIsNeverListed` | 测试收集了所有列出项的 `runtimeIdentifier`，而“不可用设备”项带着它所用运行时的标识，被误算成“运行时被列出”。产品逻辑正确：watchOS 11 运行时没有作为运行时项列出 | 只统计 `.unusedRuntime` 类型的项 |
| `SimulatorCleanupTests.testFailuresAndDeletionsStillListedAreReportedAsSuch` | 本机 ICU 的 `\p{Han}` 会匹配英文文案里的分隔符“·”（U+00B7） | 改用仓库其他测试的写法：检查 0x4E00–0x9FFF |
| `SimulatorCleanupTests.testTheConfirmationListsPermanentDeletionAndTheAppsToQuit`（2 处断言） | 只有这个测试传入了空的预览设备集合，visionOS 运行时因此合理地被列出（4 项）。期望值 3 项、8,548,580,096 字节是按其他测试共用的场景算的 | 传入与其他测试相同的 `[visionOS2]`，期望值不变 |
| `CleanupJunkActionableTests.testLocationsNoFlowMayTouchAreCountedNotListed` | 夹具规则复制自自动规则 `system.user-caches`，把根改到 Application Support；已有的校验正确地拒绝了这样的自动规则（`forbiddenRoot`） | 夹具改成复核规则（根在 Application Support 的规则只能是复核规则，与 iStat 规则相同），断言不变 |
| `CleanupRuleTableTests` | 新增 Bun、iStat 两条规则后没有重新生成规则表 | 用 `STORAGE_CLEANER_RECORD_RULE_TABLE=1` 重新生成 |

同样的路径写法问题也让 `BunInstallCacheRuleTests.testNothingElseUnderBunIsListed` 存在漏洞：它通过了，但“`~/.bun` 下不列别的”这一检查对遍历得到的子项（`/private/var/...`）不起作用。已按同样方式修正，反证 G10d 和 H2 显示了修正前后的差别。

第二次定向测试（21:37–21:38）：38 个套件，708 个，跳过 4 个，**0 失败**，exit 0。跳过的 4 个都是需要手动开启的已有测试（读取本机主目录或真实卸载清单）。两次运行中窗口监视器都没有看到任何窗口（0 个窗口，0 次越界）。

## 反证

反证脚本 `counterproof_batch_b.py` 在工作区的逐字节副本（`b-cp`）里运行，工作区本身不被改动。每一项先改动一处产品代码、规则或测试，运行守护它的测试或检查脚本，再按字节恢复，并核对哈希。“预期失败”的项必须是断言失败或检查脚本非零退出，编译错误不算；“预期通过”的项是等价改写，或用来说明旧测试漏掉了什么。

第一轮（21:45–22:21）：38 项，**37 项符合预期，1 项不符合**。开跑前的基线是 12 个套件、149 个测试全部通过，L8 清单检查通过（155 条、246 处）。结束后副本与开跑前一致（清单比对），窗口监视器记录 0 个窗口、0 次越界。

不符合的一项是 **G13c**：把每个卷的判断从“该卷自己的计划字节数”改成“整次计划的字节数”，`CleanPlanScaleAlertTests` 仍然通过。原因在测试夹具：`testEachVolumeIsJudgedOnItsOwnUsedSpace` 里 volume-a 的已用空间是 1,000，整次计划 450 字节也不超过它的一半，所以两种算法结果相同，这个测试其实没有检查它名称所说的事情。处理：把 volume-a 的已用空间改为 800。这样 volume-a 自己的 300 不超过 400，但整次计划的 450 超过，两种算法结果不同。断言和期望值不变，只改夹具和说明文字。

第二轮（22:22–22:27，只跑 G13 的 5 项和 H1，副本里换成加强后的测试）：**6 项全部符合预期**，G13c 现在会让 `testEachVolumeIsJudgedOnItsOwnUsedSpace` 失败。基线是这 3 个套件、73 个测试在未改动的代码上全部通过，所以加强后的测试本身成立。副本结束后不变，窗口监视器 0 个窗口。两轮合计：38 项全部符合预期，其中 1 项是加强测试后才符合。

G13c 的夹具是在第二次定向测试之后改的，所以第二次定向测试的 708 个不包括加强后的 `CleanPlanScaleAlertTests`；它由第二轮反证的基线（未改动代码上通过）和下面的完整门禁覆盖。

各项的改动和结果见 `logs/counterproof-batch-b.log`、`logs/counterproof-g13-rerun.log`。脚本加了一个可选的环境变量 `COUNTERPROOF_ONLY`，用于只跑部分项；不设置时行为与第一轮相同，第一轮实际运行的脚本另存为 `scripts/counterproof_batch_b.as-run-2145.py`。

## 门禁（原始日志）

**结论：完整门禁没有通过（exit=1）。** 15 步中 14 步 exit 0；Release 全量测试有 1 项失败，是菜单栏长历史准备耗时的计时项，下面单列。没有改阈值或断言。

运行方式：22:28 把工作区冻结到 `b-tree`（1,724 个文件，与工作区逐个文件哈希一致），在冻结副本上按 `script/verify.sh` 的步骤逐步运行（`verify_no_window_all.sh`），每步都跑完并记录 exit code；两次全量 `swift test` 跳过会开窗口的测试类（见下节）。`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`，不构建 App 包，不启动 App。结束后冻结副本与开始时一致（`tree unchanged`）。开始负载 10.00 / 10.85 / 13.66，结束 9.57 / 10.04 / 13.07。

| 步骤 | exit | 时间 | 结果 |
|---|---|---|---|
| bootstrap | 0 | 22:28:14–22:28:17 | |
| debug-build | 0 | 22:28:17–22:33:20 | |
| release-test | **1** | 22:33:20–22:54:12 | 执行 4,886 个，跳过 23 个，**失败 1 个** |
| release-test-list | 0 | 22:54:12–22:54:13 | 测试清单 5,190 个 |
| concurrency-build | 0 | 22:54:13–23:00:18 | `-strict-concurrency=complete` |
| debug-test | 0 | 23:00:18–23:06:23 | 执行 4,996 个，跳过 24 个，0 失败 |
| guard-views-10 / guard-purge-11 / guard-shell-15 | 0 | 23:06:23–23:06:24 | |
| private-api-selftest / private-api | 0 | 23:06:24–23:06:26 | |
| inventory-selftest / inventory | 0 | 23:06:26–23:06:31 | L8 清单 155 条、246 处 |
| guard-conflicts-14 | 0 | 23:06:31 | |
| menu-bar-performance | 0 | 23:06:31–23:06:36 | 16 个，0 失败；准备阶段 p95 90.87 ms |

跳过的测试：Release 23 个都是需要手动开启的已有测试（读取本机真实数据、真实安装流程、真实硬件采集等，例如 `AppUpdateLiveScanTests.testLiveReadOnlyInventoryAudit`、`StartupScanningTests.testLiveReadOnlyCoverageWhenExplicitlyEnabled`）；Debug 多出的 1 个是这个计时项本身，它在 Debug 下按设计跳过，只在 Release 下计时。

**失败项**：`MenuBarPerformanceRegressionTests.testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`，准备阶段 p95 112.91 ms，阈值 100 ms（`MenuBarPerformanceRegressionTests.swift:398`）。同一测试在门禁最后的专门步骤（负载较低时）是 90.87 ms，通过。本批没有改动这个测试和它覆盖的代码：`MenuBarPreparedChart.swift`、`MenuBarDerivedCache.swift`、`MenuBarPerformancePolicy.swift` 和测试文件在工作区里都与 HEAD 相同。A 批门禁时同一项在 96.97–1,055 ms 之间变化，当时没有做 HEAD 对照。本批的 HEAD 对照见下。

**HEAD 对照（23:07–23:21，`run_menu_control.sh`）**：把 HEAD `6e660a59` 逐字节导出到 `head-tree`（1,694 个已跟踪文件，与 HEAD 逐个比对无缺失、无差异），用与门禁相同的参数构建 Release 测试（`--jobs 2`，exit 0，835 秒）。然后在同一时段交替运行这一个测试：HEAD 与 B 批冻结副本各 5 次，`--skip-build`，每次记录开始前的负载。两份副本运行前后都没有变化；窗口监视器结束汇总为 0 个窗口、0 次越界、0 个外来测试窗口。

| 轮次 | HEAD p95（ms） | HEAD exit | B 批 p95（ms） | B 批 exit | 1 分钟负载 |
|---|---|---|---|---|---|
| 1 | 92.08 | 0 | 96.27 | 0 | 13.65–14.15 |
| 2 | 169.92 | 1 | 127.39 | 1 | 12.88–13.04 |
| 3 | 100.20 | 1 | 98.83 | 0 | 13.32–13.61 |
| 4 | 104.62 | 1 | 102.22 | 1 | 12.65–13.32 |
| 5 | 125.87 | 1 | 147.49 | 1 | 11.96–12.65 |

同样负载下，未改动的 HEAD 5 次中失败 4 次（中位数 104.62 ms），B 批失败 3 次（中位数 102.22 ms）；每次失败都只有第 398 行这一条断言。这说明本次门禁的这项失败跟随机器负载，不是 B 批改动引起的。但它仍是门禁失败：Release 全量测试这一步没有通过，不能记为通过；阈值和断言都没有改。原始日志在 `logs/menu-control/`（`runs.tsv`、每次运行的日志、`head-build.log`、`control.meta`、`watch.jsonl`、两份副本前后的清单）。

测试数量：A 批返修门禁（`verify-afix`）的 Release 测试清单是 5,144 个，本批 5,190 个，多 46 个：`SimulatorCleanupTests` 12、`VendorUninstallerTests` 9、`ProtectedLocationLayersTests` 6、`CleanPlanScaleAlertTests` 5、`BunInstallCacheRuleTests` 3、`IStatMenusHistoryRuleTests` 3、`CleanupDefaultSelectionPolicyTests` 3、`CleanupStoreFollowUpTests` 2、`CleanupExecutionSafetyTests` 1、`CleanupJunkActionableTests` 1、`PermanentDeletionInvariantTests` 1，没有减少。`FrozenTrashEmptyingTests`（14 个）在 A 批返修冻结时已经在工作区里，所以不在这 46 个中。

`git diff --check` 在工作区上 exit 0（`logs/git-diff-check.log`）。它不检查未跟踪文件；单独检查后，未跟踪文件中只有 `docs/COMPETITIVE_REVERSE_ENGINEERING_2026-10-14.md` 结尾多一个空行，这个文件不是本批写的，没有改（`logs/untracked-whitespace-check.log`）。

## 其他复核

- **JEV**（`jev_review`，21:55，只给了 L5 冻结与清空、确认流程和 G9 服务的代码摘录，见 `logs/jev-payload.txt`）：建议 escalate，safe_to_apply 0.28，综合 0.757，没有指出具体缺陷。这只是概率判断，不算通过，也没有据此改代码。
- 工作区里 A 批运行检查脚本时留下的 `script/__pycache__/`（2 个 `.pyc`）已删除；门禁和快照本来就排除 `__pycache__`。批前快照的未跟踪文件包里仍有这两个文件。

## 会开窗口的测试与界面

按 Codex 0855/0901 的要求：会把窗口或系统界面放到屏幕上的测试类不在主屏运行，列为待验证，不算通过；窗口监视器只是证据，不是保证；不改主显示器或排列，不先在主屏显示再移走。

- **跳过名单**：`build_skip_list.py` 在冻结副本上找出 54 个文件、474 个测试类中的 57 个（直接创建窗口、面板或系统界面，或经过会这样做的类型），与第二次定向测试时的名单完全相同（新增 0、移除 0）。这些类在本批的门禁里没有运行，结果是“待验证”，不是“通过”。名单在 `logs/skip-list-b-tree.json`，原因逐类列在 `logs/gate.stdout`。
- **监视器**：整个门禁期间开着只读监视器，命令行包含验证目录的进程共 210 个（编译和测试进程），结束汇总是 0 个上屏窗口、0 次越界、0 个外来测试窗口（`logs/gate-watch.jsonl`）。它看到 9 个由测试进程创建的窗口，都始终是 `onscreen=false`：Release 段 22:52:43 两个、Debug 段 23:04:32 两个，尺寸为 0，出现在 `MenuBarStatusPanelTests`／`MenuBarTertiaryDetailTests` 运行期间；Debug 段 23:05:45–23:05:46 五个，出现在 `SafeCleanupScopeCardLayoutTests` 运行期间，坐标在内建显示器范围内（x 0、y 158、宽 180–560、高 720），但没有上屏。这与 A 批记录的情况相同。监视器每 0.5 秒刷新一次进程、每 50 毫秒查看一次窗口，不能证明窗口没有在两次查看之间短暂显示。

本批新增或改动的界面都没有在运行中的 App 上目视检查过：
- L5 清空废纸篓的两步确认页（`EmptyTrashConfirmationSheet`）。
- G13 确认页里的规模摘要和勾选。
- G2 模拟器数据页、列表和两次确认。
- G9 卸载页“应用本体”下方的提示和“打开卸载程序”按钮。
- G10 行内的 `freesLittle` 说明；G7 在扫描结果里的那一行。

## 待实机验收（需要用户批准，或由用户本人操作）

1. **界面**：上面列出的界面需要构建并启动 Beta 目视检查；安装 `/Applications/测试版.app` 要另行批准。
2. **L5**：没有在本机真实清空废纸篓（属于真实清理，未获批准），只用夹具和假删除器测试过。
3. **G2**：2026-10-15 21:50 本机只读列表结果是 11 台设备、0 台不可用、1 个运行时（iOS 27.0，24A434，8,067,000,161 字节）被默认设备集使用，按规则不会列出任何项。真实的 `simctl delete` 没有执行，执行需要批准。运行时删除是异步的，“已提交”状态只在假执行器上验证过。
4. **G9**：没有用真实的、带同一 Team ID 签名的卸载程序测试过，签名读取用的是假的检查器；真实打开第三方卸载程序属于对外操作，需要批准。
5. **G7**：没有在 iStat Menus 运行时检查真实扫描和执行是否跳过这一项。`NSRunningApplication` 看不到 history XPC 服务，依靠菜单栏程序退出来覆盖它；这一点只在本机读进程列表时核实过。
6. **G10**：本机的 Bun 缓存大部分已克隆到 `node_modules`，按规则不会预选，但没有在真实扫描中确认。

## 未做、收窄或待用户确认

- **待用户确认（G10）**：目前只用 G1 的保守预计释放决定是否预选。如果要把“整组克隆都在所选范围内时可能释放”的条件数加进来（两者之和），属于默认勾选策略的变化，需要用户确认；Codex 0901 也要求单列，不能只靠改决定记录视为批准。
- **比计划原文收窄**：G2 逐项按 UUID 删除，不用 `delete unavailable`；G9 在共用文件夹里要求卸载程序名称包含 App 名称；G10 没读到共享信息或共享很少的行仍按 D47 预选；G7 只收录本机核实过的 Setapp 版路径。
- **A 批遗留，仍未实现，不算完成**：G1 文件分析／大文件列表的预计释放；G5 授权后只扫新增位置。

## 差异与证据

**结论：B 批七项在源码、定向测试和反证层面完成。完整门禁没有通过：Release 全量中菜单栏计时项超阈值（同时段 HEAD 对照同样失败，随负载变化），57 个会开窗口的测试类没有跑。不能据此把完整门禁、B 批界面或任何实机验收记为通过。**

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-b/`。`README.md` 说明各文件和复核步骤，`SHA256SUMS.txt` 覆盖目录内全部文件。

- **批前与批后**：
  - `snapshots/pre-batch-B.diff`、`pre-batch-B-untracked.tar` 是 18:17 开工时的状态，即 HEAD 加 D98–D100 的未提交改动。
  - `post-batch-B.*` 是收尾时的同类快照。
  - `batch-B-delta.diff` 是开工时的树与收尾时的工作区逐文件比较的结果。文件列表在 `batch-B-files.txt`（59 个文件），收尾时的哈希在 `batch-B-files.sha256`。快照脚本自检：开工时的树加上这份差异，得到的文件与工作区一致。
  - **这份差异含 A 批返修**：返修（A-R1–A-R4）在 B 批开工后才做，它改的 11 个文件也在其中。返修本身见 A 批证据目录的 `afix-delta.diff`。
- **Codex 还没看过的部分**：`snapshots/afix-to-final.diff` 是 A 批返修冻结副本（`afix-tree`，Codex 0901 已逐字节核对）到收尾时工作区的差异，文件列表在 `afix-to-final-files.txt`（43 个文件）。内容如下：
  - G13、G4-2、G10、G2、G9、G7 的全部改动；
  - L5 只有一处：`FrozenTrashEmptyingTests` 去掉两处多余的 `try`；
  - 文档：DECISIONS、BOARD、规则表、`cleanup-rules.md`、本交接，以及 A 批交接中 21:20 填写的返修证据一节（属于 A 批）。
- **门禁副本与工作区**：门禁在 22:28 冻结的 `b-tree` 上运行。收尾时它与工作区只差 DECISIONS、BOARD 两份文档和本交接（`snapshots/b-tree-vs-final.txt`），代码与测试相同。

| 检查 | 时间（2026-10-15） | 实际结果 | 日志 |
|---|---|---|---|
| 编译 | 21:20–21:37 | 前两次因测试代码编译失败（见上文），之后通过 | `logs/build*.log`、`.meta` |
| 定向测试第 1 次 | 21:29–21:30 | 708 个，跳过 4，失败 10（测试代码与夹具问题，见上文） | `logs/targeted-b.*` |
| 定向测试第 2 次 | 21:37–21:38 | 38 个套件 708 个，跳过 4，0 失败，exit 0 | `logs/targeted-b2.*` |
| Python 检查与自测 | 21:39 | 私有 API 检查、删除与进程清单检查及两者的自测都通过 | `logs/python-checkers.log` |
| 反证第 1 轮 | 21:45–22:21 | 38 项中 37 项符合预期，G13c 不符合 | `logs/counterproof-batch-b.log` |
| 反证第 2 轮 | 22:22–22:27 | 加强夹具后 6 项全部符合预期 | `logs/counterproof-g13-rerun.log` |
| 不开窗口的完整门禁 | 22:28–23:06 | exit 1：15 步中 14 步 exit 0；Release 4,886 个，跳过 23，失败 1（菜单栏计时项）；Debug 4,996 个，跳过 24，0 失败 | `logs/verify-nowindow-b.log`、`gate-steps.txt`、`gate.meta`、`gate.stdout` |
| HEAD 计时对照 | 23:07–23:21 | HEAD 5 次失败 4 次，B 批 5 次失败 3 次 | `logs/menu-control/` |
| `git diff --check` | 22:28 | exit 0 | `logs/git-diff-check.log` |
