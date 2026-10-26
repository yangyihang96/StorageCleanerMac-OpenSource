# d102-batch-c：竞品逆向改进 C 批（信任边界与硬件生命周期）

批次：C / D102。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`。本批全部改动未提交，与 D98–D101、D103 的未提交改动在同一工作区。计划文件是 `~/Claude 好玩的/Mac清理与监控软件逆向-2026-10-15/2.0.1改进计划.md`（SHA-256 `169ed23e1070d1e6…`，与 A、B 批相同）。各项的产品决定见 DECISIONS D102，本文只记实现、测试、证据和未完成的部分。

本批没有做以下事情：提交、合并、安装、重启、启动 App、构建或签名 App 包、写风扇／电源模式／SMC、运行 helper 做功耗测量。接触本机的只有只读核实：
- 用 `codesign -d`、`codesign --verify` 读取已安装的测试版、正式版和 `/usr/bin/true` 的签名信息，用 `--extract-certificates` 把证书链导出到任务临时目录，再用 `openssl x509` 读出摘要。证据目录只放摘要 `logs/certs-summary.txt`（邮箱已替换），不放证书原件。
- 用 `plutil -p` 读取两个已安装 App 内的风扇 helper 启动配置。
- 用 `ps` 查看测试版风扇 helper 的运行时长和累计 CPU（G3 的观察，不是测量）。

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-c/`。

**2026-10-16 补记**：Codex 独立复核（CODEX_C_REVIEW_20261015_1445）没有验收本批，报告两项 P2：C-R1（回复只带触发原因就记为“已自动交回系统”）和 C-R2（L4 的补记没有做）。两项由 D105 修复，见 `d105-review-c-fixes.md`；Codex 返修复核又报 D105-R1（App 历史保存失败后同一次运行无法补记），也已修复，记在同一文件；2026-10-16 Codex 最终复核（CODEX_FINAL_RECHECK_20261015_1710）在源码与隔离测试层面关闭 C-R1、C-R2、D105-R1，不是实机验收。下文保留 C 批交付时的原始记录；其中与 D105 不一致的地方（自动恢复的记法、“L4 补记”的收窄）以 D105 为准。

## 完成项

| 项 | 改动 | 测试 |
|---|---|---|
| L7 | App 连接风扇 helper 前，按 App 自己的签名生成要求（helper 的 identifier、App 的叶证书指纹、Team ID），在第一次 `resume()` 之前设 `setCodeSigningRequirement`；生成不了就不连接、不自动重试。`FanControlPeerRequirement.currentSigner` 只为 helper 的 identifier 生成。签名不一致（4102）时提示开头改为“辅助程序的签名与本应用不一致，已拒绝连接。”，之后照常退避重连 | `FileOperationPeerRequirementTests`（风扇客户端不再例外）；`FanControlProtocolSafetyTests` 新增 1 项 |
| L1 | helper 原有的接入校验之后，再设系统逐条消息检查的要求：启动时按启动签名生成一次（App 的 identifier、helper 自己的叶证书、Team ID），生成不了就拒绝；普通接入的客户端代码检查加一次动态 `SecCodeCheckValidity` | `HelperUpgradeSafetyTests` 新增 1 项（源码顺序与写法） |
| L2 | 两个通道的要求都追加 `certificate leaf[subject.OU] = "<Team ID>"`，Team ID 从当前签名读取；没有 Team ID 时不加；identifier 与 Team ID 只允许字母、数字（identifier 另加 `.`、`-`），否则不生成要求 | 新增 `FanControlPeerRequirementTests`（6 项）；`FileOperationPeerRequirementTests` 仍为 5 项：2 项改名重写（`testRequirementShapeRefusesAnotherIdentifierOrLeafCertificate` → `testRequirementRefusesAnotherIdentifierLeafCertificateOrTeam`，`testProductionRequirementUsesTheCheckedShape` → `testCurrentSignerUsesTheCheckedBuilder`），另有 2 项按 Team ID 和风扇客户端的改动修改 |
| L3 | Beta 构建生成的风扇 helper 启动配置与正式版相同（`RunAtLoad`、`KeepAlive{SuccessfulExit:false}`），只有 label 不同；两种模式的打包检查都读回这两个键 | `MacMiniModePackagingTests` 新增 1 项 |
| L4 | 风扇（手动、预设和最大转速的写入，曲线开关与更新，交回系统控制）、电源模式、Mac mini 模式的写操作，以及 App 得知的自动恢复，记入本地硬件操作记录（最多 200 条、128 KiB），在“操作记录”页底部列出。请求已交给 helper 而没有可用回复记“未确认”；在 App 内发出前就停下的请求不记 | 新增 `HardwareOperationHistoryTests`（9 项） |
| G3 | 只写测量方案，没有测量（需要运行装有 helper 的版本，等用户批准） | — |
| L6 | 评估后不加，理由见 D102 | — |

本批改动 14 个文件：源码 7 个（新增 `FanControlShared/FanControlPeerRequirement.swift`、`Models/HardwareOperationPresentation.swift`、`Services/HardwareOperationHistory.swift`；修改 `FanControlHelper/main.swift`、`FileOperationShared/FileOperationContract.swift`、`Services/FanControlCoordinator.swift`、`Views/ReversibleOperationsView.swift`），测试 6 个，构建脚本 1 个（`script/build_and_run.sh`）。测试数比 B 批门禁副本多 18 个：`FanControlPeerRequirementTests` 6、`HardwareOperationHistoryTests` 9、`FanControlProtocolSafetyTests`、`HelperUpgradeSafetyTests`、`MacMiniModePackagingTests` 各 1。

## 自检中发现并修正的问题

第一轮反证跑到第 5 项时，自检发现 3 处语义问题，停下反证（23:46，见“反证”）先修：

1. **L4 把没发出的请求记成“未确认”**：helper 签名不受信任、请求编码失败、建立连接失败时，请求根本没有离开 App，原来也记一条“未确认”。改为 `send` 记录请求是否已交给 helper（`sent`），只有已交出、没有可用回复的才记“未确认”。新增源码测试 `testOnlyARequestThatLeftTheAppCanBeUnconfirmed`，反证 L4n–L4p。
2. **`currentSigner` 与注释不符**：注释说只为 helper 生成，代码也接受 App 的 identifier。改为只认 helper；`testOnlyTheHelperGetsARequirement` 检查 App 的 identifier 也返回 nil，反证 L2h。
3. **记录标题**：手动、预设和“最大”都走同一个写入请求，原来的标题“手动设置风扇转速”不准确，改为“设置风扇转速”；“未确认”的说明改为“已发出，但没有收到可用的回复”。

另外说明一个特性（不是缺陷）：目标转速不变时 App 只续租，续租不记；转速按每秒最多 500 RPM、至少间隔 2 秒逐步接近目标，每一步都是一次写入，各记一条。

## 编译和定向测试

全部在工作区运行，`--scratch-path` 为任务临时目录，`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`。每次测试都带只读窗口监视器，记录到的窗口数都是 0。

| 检查 | 时间（2026-10-15／16） | 实际结果 | 日志（`batch-c/logs/`） |
|---|---|---|---|
| 编译 | 23:27:57–23:31:43 | exit 0 | `build-c1.*` |
| 编译 | 23:33:47–23:33:58 | exit 0 | `build-c2.*` |
| 定向测试 1 | 23:35:01–23:35:51 | 802 个，跳过 1，失败 1，exit 1：未改动的计时测试 `OperationReportTaskLifecycleTests.testStuckPhysicalReadTimesOutAndReportsItsWorkerWithoutHanging` 耗时 3.75 秒，超过上限 | `targeted-c1.*` |
| 计时测试单独运行 | 23:36:18–23:36:22 | 该套件 4 个，0 失败 | `targeted-c-oprt.*` |
| 定向测试 2 | 23:36:33–23:37:28 | 同一组 802 个，跳过 1，0 失败，exit 0 | `targeted-c2.*` |
| 编译（自检修正后） | 23:51:50–23:53:23 | exit 0 | `build-c3.*` |
| 编译（加入 D103 返修后） | 23:59:32–00:04:47 | 第一次 exit 1（D103 的 `Darwin.stat` 写法错误），之后两次 exit 0 | `build-c4.*`–`build-c6.*` |
| 定向测试全量 1 | 00:04:50–00:06:06 | 76 个套件 1,169 个（含 C 批和 D103 相关套件），跳过 4，失败 1，exit 1：同一个计时测试，5.48 秒 | `targeted-final1.*` |
| 定向测试全量 2 | 00:06:47–00:07:57 | 同一组 1,169 个，跳过 4，0 失败，exit 0 | `targeted-final2.*` |

这个计时测试和它测的报告任务代码，C 批和 D103 都没有改；断言没有改。跳过的都是需要显式设置环境变量才运行的测试（读本机真实目录或计时）。

## 只读核实已安装的签名

| 项 | 结果 |
|---|---|
| 签名证书 | 测试版和正式版的 App、两个 helper 都用同一张 Apple Development 叶证书（SHA-1 `bf6c52220a38977e73fa59d83cb7e9ba3709a55f`），Team ID `T9GZL52H8R`，证书链到 Apple Root CA。签名时间：测试版 2026-10-14 02:28，正式版 2026-10-13 11:20 |
| 要求写法 | 用 `codesign --verify -R` 对 6 个已安装的二进制（两个 App 各自的 App、风扇 helper、文件操作 helper）检查 D102 的要求写法，每个 5 种：正确的要求通过；Team ID、identifier、叶证书指纹任一处错误都被拒绝（exit 3）；去掉 Team ID 子句的旧写法仍通过。30 项全部符合预期，检查后两个 App 的签名仍有效 |
| 启动配置 | 已安装的测试版 helper 配置没有 `RunAtLoad` 和 `KeepAlive`（L3 之前的 Beta 构建）；正式版有 `RunAtLoad=true` 和 `KeepAlive{SuccessfulExit:false}`。与 L3 的前提一致 |

这只证明要求的写法能被系统解析，并且与当前签名匹配；**不等于实际 XPC 连接验收**。签名构建上的接入与拒绝要等用户批准安装后实测。

**操作失误与核实**：23:31 读取已安装 App 里的启动配置时，脚本把两个 plist 文件名放在同一个变量里传给 `PlistBuddy`，路径实际上变成了“两个文件名用换行连起来”的一个不存在的文件。`PlistBuddy` 对这个路径输出了“File Doesn't Exist, Will Create”。命令里只有 `Print`，没有 `Save`，所以不会写文件。核实：
- 当时：两个 `LaunchDaemons` 目录的列表不变，`find -newer` 为空，`codesign --verify --strict` 两个 App 都通过。之后改用 `plutil -p` 重读（`logs/installed-fan-plists.log`）。
- 2026-10-16 00:19 复查：两个目录都只有原来的两个 plist，目录修改时间仍是安装时（测试版 2026-10-14 02:28，正式版 2026-10-13 11:19），没有名字带换行的文件，两个 App 的签名都有效（`logs/near-miss-recheck.log`）。

以后读取已安装 App 只用 `plutil -p`、`codesign -d`／`--verify`，不给 `PlistBuddy` 传多个路径。

## 反证

在工作区的逐字节副本（`c-cp`）上运行。每项把一处实现改回旧写法或改坏，只跑守护它的测试，预期因断言失败（不是编译错误）；`H1`–`H6` 是等价的另一种写法，预期通过。每项结束后从备份逐字节恢复并核对哈希，最后副本的完整清单与开始时相同。窗口监视器记录到的窗口数为 0。

- **第 1 轮（停止）**：23:38:14 开始，L7a–L7d 符合预期。23:46:41 在 L7e 运行中用 TaskStop 停止，先修自检发现的问题。进程被杀时 `finally` 没有执行，L7e 的改动留在副本里（`FanControlCoordinator.swift` 的哈希变为 `1063088b…`，原为 `60c5fd71…`）。下一轮开始前已用 `rsync --delete` 从工作区重新同步副本，并用 `diff -rq` 核对与工作区相同。记录在 `logs/round1-stopped/`。
- **第 2 轮**：00:17:56–00:35:30，45 项全部符合预期，exit 0，副本前后清单相同。在第 1 轮 41 项的基础上，加了针对自检修正的 4 项：L2h（为 App 也生成要求）、L4n（App 内停下的请求记为未确认）、L4o（helper 请求在建立连接前就算已发出）、L4p（假 helper 的请求不算已发出）。

| 组 | 项数 | 守护测试 | 结果 |
|---|---|---|---|
| L7 | 6 项改坏 + H1 | `FileOperationPeerRequirementTests`（客户端）、`FanControlProtocolSafetyTests` | 全部符合预期 |
| L1 | 5 项改坏 + H2 | `HelperUpgradeSafetyTests` | 全部符合预期 |
| L2 | 8 项改坏（含 L2h）+ H3 | `FanControlPeerRequirementTests`、`FileOperationPeerRequirementTests` | 全部符合预期 |
| L3 | 4 项改坏 + H4 | `MacMiniModePackagingTests` | 全部符合预期 |
| L4 | 16 项改坏（含 L4n–L4p）+ H5、H6 | `HardwareOperationHistoryTests` | 全部符合预期 |

开始前的基线：6 个相关套件 52 个测试 0 失败，删除与进程清单检查通过（155 条、246 处）。39 项预期失败的都有断言输出，没有一项是编译错误。逐项名称、预期和每项的断言输出见 `logs/counterproof-batch-c.log`。

## 门禁（原始日志）

**结论：不开窗口的完整门禁通过（exit=0）。** 15 步全部 exit 0。这次门禁覆盖 C 批的 14 个文件，也覆盖 B 批复核返修 D103 的 8 个文件（B 批门禁没有包括它们）。它只说明这一份代码在本机、不开窗口的条件下通过了 `script/verify.sh` 的各步；57 个会开窗口的测试类没有运行，界面、签名后的运行时和实机都没有验收（见“待实机验收”）。

运行方式：00:35:56 把工作区冻结到 `c-gate-tree`（1,733 个文件，冻结时工作区的逐个文件哈希与副本一致），在冻结副本上按 `script/verify.sh` 的步骤逐步运行（`verify_no_window_all.sh`），每步都跑完并记录 exit code。两次全量 `swift test` 跳过会开窗口的 57 个测试类，名单与 B 批相同（没有增减）。`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`，不构建 App 包，不启动 App。结束后冻结副本与开始时一致（`tree unchanged`）。开始负载 10.67 / 11.86 / 10.99，结束 8.39 / 9.17 / 10.62；期间 Google Drive、WindowServer、Kang Charge 的调试版和 Codex 也在占用 CPU，不受本会话控制。

| 步骤 | exit | 时间 | 结果 |
|---|---|---|---|
| bootstrap | 0 | 00:35:56–00:35:59 | |
| debug-build | 0 | 00:35:59–00:42:16 | |
| release-test | 0 | 00:42:16–00:57:35 | 执行 4,909 个，跳过 23 个，0 失败 |
| release-test-list | 0 | 00:57:35–00:57:36 | 测试清单 5,213 个 |
| concurrency-build | 0 | 00:57:36–01:02:13 | `-strict-concurrency=complete` |
| debug-test | 0 | 01:02:13–01:08:19 | 执行 5,019 个，跳过 24 个，0 失败 |
| guard-views-10 / guard-purge-11 / guard-shell-15 | 0 | 01:08:19–01:08:20 | |
| private-api-selftest / private-api | 0 | 01:08:20–01:08:21 | |
| inventory-selftest / inventory | 0 | 01:08:21–01:08:26 | L8 清单 155 条、246 处（与 B 批相同） |
| guard-conflicts-14 | 0 | 01:08:26 | |
| menu-bar-performance | 0 | 01:08:26–01:08:31 | 16 个，0 失败；准备阶段 p95 94.74 ms |

- **跳过的测试**：Release 23 个、Debug 24 个，与 B 批门禁逐个相同（共 24 个不同的测试，`skipped-release-c.txt`、`skipped-debug-c.txt`）。都是需要手动开启的已有测试（读取本机真实数据、真实安装流程、真实硬件采集等）；Debug 多出的 1 个是菜单栏长历史计时项，它在 Debug 下按设计跳过。
- **菜单栏计时项**：B 批门禁在 Release 全量测试里这一项失败（p95 112.91 ms，阈值 100 ms），HEAD 对照显示它随负载变化。这次 Release 全量测试中它是 98.83 ms，通过，但离阈值只差 1.17 ms；最后的专门步骤是 94.74 ms。通过一次不能说明它不再受负载影响。阈值和断言都没有改。
- **测试数量**：B 批门禁的 Release 测试清单是 5,190 个，这次 5,213 个，净增 23 个（`test-list-b-vs-c.diff`：新增 25 个、去掉 2 个）。新增的是 `HardwareOperationHistoryTests` 9、`FanControlPeerRequirementTests` 6、`IndependentBatchBReviewTests` 3、`FileOperationPeerRequirementTests` 2（改名后的两项）、`FanControlProtocolSafetyTests` 1、`HelperUpgradeSafetyTests` 1、`MacMiniModePackagingTests` 1、`FrozenTrashEmptyingTests` 1、`CleanupTrashDeletionTests` 1；去掉的 2 个是 `FileOperationPeerRequirementTests` 改名前的两项（见“完成项”L2 一行）。执行数也是两边各多 23 个（Release 4,886→4,909，Debug 4,996→5,019）。
- **窗口**：只读窗口监视器记录到测试进程 `xctest` 建立的 10 个窗口（20 条记录），都始终是 `onscreen=false`，没有上屏：4 个尺寸为 0（00:56:14、01:06:27 各两个）；6 个出现在 `SafeCleanupScopeCardLayoutTests` 运行期间（01:07:42–01:07:43），坐标在内建显示器范围内（x 0、y 158、宽 180–560、高 720）。（2026-10-16 更正：原文写“都是 0×0、不在屏幕上、不落在任何显示器上”，后两点与 `gate-watch.jsonl` 不符，D 批门禁核对监视记录时发现；A、B 批交接对同类窗口的记录是对的。）屏幕上的窗口 0 个，越界 0 次，不属于测试的外来窗口 0 个（`gate-watch.jsonl`）。这只是只读观察，不是把窗口路由到“虚拟屏 1 · Codex”的证明；会开窗口的 57 个测试类仍未运行。
- 原始日志：证据目录 `logs/gate/`（`verify-nowindow-c.log`、`gate.meta`、`gate-steps.txt`、`gate.stdout`、`gate-watch.jsonl`、冻结前后清单、跳过名单 `skip-list-c-gate-tree.json`、测试清单 `test-list-release-c.txt`）。

## G3：测量方案（没有测量）

计划要求先测量再决定。测量必须运行装有 helper 的版本，按计划要先问用户，所以本批只写方案。

只读观察（不是测量）：2026-10-15 22:39 用 `ps` 看到本机测试版的风扇 helper 已连续运行 1 天 0 小时 53 分，累计 CPU 19.78 秒。这与计划所说“菜单不可见时 App 仍每 60 秒请求一次功耗，helper 难以闲时退出”一致，但没有控制条件，不能用来下结论。

方案（等用户批准后执行，全程不写风扇、电源模式或 SMC）：
1. 前提：用户批准安装新的测试版并启用高级控制；记录测试版与 helper 的版本、签名和启动时间。
2. 菜单与主窗口都不可见，连接电源，静置 30 分钟。每分钟记录 helper 进程的累计 CPU 时间、唤醒次数（`top -l` 的 `IDLEW` 或 `powermetrics --samplers tasks`，后者需要授权，单独确认）、`powermetrics` 子进程的启动次数。
3. 同一时段，App 自己用 IOReport 读 CPU、GPU、ANE 功耗，与 helper 的 `powermetrics` 读数逐分钟对比，记录差值的中位数与最大值。
4. 判断（阈值在测量前写入 DECISIONS）：如果 30 分钟内 helper 的 CPU 时间与唤醒次数明显高于闲时退出的基线，且 IOReport 与 `powermetrics` 的差在可接受范围内，不可见时的功耗历史改用 IOReport 并标明来源，`powermetrics` 只在面板可见时运行；否则保持现状，把数据写进 DECISIONS。
5. 验收：不可见 10 分钟内没有 `powermetrics` 子进程；功耗历史图连续；可见时读数不变；风扇曲线和开机、异常恢复不受影响。

## L6：评估结论（不加）

不加手动写风扇前的会话授权，理由写在 D102：手动写入本来就是显式的界面操作，有 3–30 秒租约看门狗和按 `F{n}Mn/Mx` 的硬件钳制；L1、L7 之后两端都固定了签名。会话授权要防的是“已通过签名校验的本 App 被劫持后写风扇”，到那一步攻击者同样能弹出授权框，只会增加正常使用的摩擦。如果将来要加，也只能加在手动写入之前，开机和异常后的恢复路径不能经过它。

## 比计划收窄或改变的地方

- **L4 存储**：计划写“复用现有有上限的历史存储”。现有的同类存储（电脑体检事件记录）存的是另一种数据，所以新建一个同样有上限的文件（200 条、128 KiB），没有新建无上限的存储。
- **L4 补记**：计划写“helper 自己做的自动恢复由 App 下次连接时读取 helper 状态补记”。helper 目前不保存、也不回报过去的自动恢复，补记需要扩展 helper 协议，本批没有做。只记 App 从回复中得知的情况；App 没在运行、或之后没有再发请求时发生的自动恢复不会记下。helper 启动时的崩溃恢复成功也不会记。（2026-10-16 补：Codex 复核 C-R2 指出这是已批准而未完成的计划项，不能由本批自行收窄；已由 D105 补做。本条保留为 C 批交付时的原始记录。）
- **G3**：只写方案，没有测量。
- **L6**：评估后不加。

## 待实机验收（需要用户批准，或由用户本人操作）

- 签名构建上的 XPC：测试版 App 能连上自己的两个 helper；签名不同的客户端被系统拒绝（4102），界面提示正确；未签名构建不连接、不自动重试。
- L3：批准安装新的测试版并重启后，测试版风扇 helper 开机自启并先把风扇交回系统；正式版与测试版同时安装时互不覆盖。
- L4：真实写风扇、切换电源模式、Mac mini 模式后，“操作记录”页的“硬件操作”区按时间倒序列出，目标值和结果正确；租约到期、过热保护的自动恢复能记下。
- “硬件操作”区和签名不一致提示的界面目视。
- 会开窗口的测试类（门禁跳过名单）。
- G3 测量。

## 差异与证据

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-c/`（`README.md` 说明各文件，`SHA256SUMS` 校验全部文件）。

- **起点**：`pre-c-tree` = HEAD `6e660a59` + B 批结束快照（`batch-b/snapshots/post-batch-B.diff` 与未跟踪文件包）。与 B 批门禁冻结的 `b-tree` 相比只差 B 批写门禁结果时改的 3 个文档。
- **快照**（`snapshots/`）：`post-batch-C.diff`（工作区相对 HEAD 的全部改动）、`post-batch-C.status`、`post-batch-C.untracked`、`post-batch-C-untracked.tar`；`pre-batch-C.diff` 与 `pre-batch-C-untracked.tar`（即 B 批结束快照）；`batch-C-files.txt`、`batch-C-delta.diff`、`batch-C-files.sha256`。脚本自检：起点加上 `batch-C-delta.diff` 能逐字节得到当前文件。
- **本批差异共 26 个文件**：C 批 14 个、D103 返修 8 个、文档 4 个（`BOARD.md`、`DECISIONS.md`、本文件、`d103-review-b-fixes.md`）。没有删除文件。代码、测试和脚本的 SHA-256：

| 文件 | SHA-256 |
|---|---|
| `Sources/FanControlHelper/main.swift` | `034a181abbf2110ea3b5c8f8c49ffd2c6d7453d1f410c2fb9415f4e18bfe1971` |
| `Sources/FanControlShared/FanControlPeerRequirement.swift`（新增） | `b4d5d87d3a468442ab78b309234ab1920fed6456c3e96d2fed1a7e6f29846155` |
| `Sources/FileOperationShared/FileOperationContract.swift` | `5d329f7656324ddeee5e3fa2290db0bd01a6a2044cf855a722959b0d0012afca` |
| `Sources/StorageCleanerMac/Models/HardwareOperationPresentation.swift`（新增） | `5ee9527a5043b80901052052cf7e24b1d94b8a0acb2b89f9be84c5d22ac4c94b` |
| `Sources/StorageCleanerMac/Services/FanControlCoordinator.swift` | `c09ad5d686a5ee3da3c28a83e25c20a5ea81897abd3fd259c1acc5a1a0b5d314` |
| `Sources/StorageCleanerMac/Services/HardwareOperationHistory.swift`（新增） | `3bba74c32accbde634ab050df13c13609075781fb86925969ff28e05ab5ca00b` |
| `Sources/StorageCleanerMac/Views/ReversibleOperationsView.swift` | `c3673120f54aaa6cf1c82960ad232468f72ba56f9ca91534f4963187180ae3a8` |
| `Tests/StorageCleanerMacTests/FanControlPeerRequirementTests.swift`（新增） | `4bb8d638bdb18305ebdf9077746e4c4c2c54b1b8dbce853dd27b70e0bf9eeacf` |
| `Tests/StorageCleanerMacTests/FanControlProtocolSafetyTests.swift` | `fe45ddab3765f342023e1228345501fbf726b9d3382cef4efd12cb2f9ee8554a` |
| `Tests/StorageCleanerMacTests/FileOperationPeerRequirementTests.swift` | `dd12034a679b9c72c1874265a679dea15ad0b184a8b66e3fd282b6436ff44e6d` |
| `Tests/StorageCleanerMacTests/HardwareOperationHistoryTests.swift`（新增） | `10579dcba4033422dbfa7ba6f4f9223171e842e4f5ed316fe7e7d21eb9340fef` |
| `Tests/StorageCleanerMacTests/HelperUpgradeSafetyTests.swift` | `9b34a547af204c510b9a88a1015e305c5ad75f6ac3a58b857575aed3f1063b82` |
| `Tests/StorageCleanerMacTests/MacMiniModePackagingTests.swift` | `2239844a3e9c33bffb9743ef82345346ace37b9546ce7d3f9223287bc82ec2ea` |
| `script/build_and_run.sh` | `d7297418b1220f03d6ee9926aa07ef09260541a4b1d29875dafeaa3bb1c62052` |

D103 的 8 个文件的哈希见 `d103-review-b-fixes.md` 的“差异与哈希”，与这次快照中的值相同。

- **日志**：`logs/`（编译、定向测试、反证、已安装签名的只读核实），门禁在 `logs/gate/`。
- **脚本**：`scripts/`（编译、定向测试、反证、门禁、跳过名单、窗口监视器、快照）。
- 未提交，未安装 `/Applications/测试版.app`，没有启动 App，没有写风扇、电源模式或 SMC。
