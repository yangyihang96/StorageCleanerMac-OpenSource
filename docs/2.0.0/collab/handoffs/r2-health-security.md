# r2-health-security 交接

日期：2026-10-09。worktree：`/Users/developer/Developer/sc-worktrees/r2-health-security`；分支：`task/r2-health-security`；基线：`0bd131b2f6e4debb24e1ffeed9bb9aaba71dd6fc`；scratch：`/Users/developer/Developer/.sc-build/r2-health-security`。

> 注：以下至“未解决 / 待主会话验证”为 Codex 轮记录（当时未编译）；实际构建、测试、反证、Release/Beta 与截图结果见文末“主会话验证轮”。

本轮完成源码、测试源码和可复核补丁准备。**构建、Swift 严格并发、XCTest、反证、安装、提交均 NOT RUN**，原生测试执行 0 项。依据 `common.md` 和 D60③，不在 Codex 沙箱内尝试这些操作。主会话在沙箱外验证后提交、复核、合并；不将源码或静态核对称为已安装或实机验收。

## 依据与范围核对

已读 `common.md`、`RULES.md`，以及 DECISIONS D5、D48、D55、D60、D64、D69、D70①、D71②。当前分支/HEAD 与任务指定一致，初始工作区干净。基线 `BOARD.md` 没有 `r2-health-security` 对应条目（精确搜索无命中），D71 表内有本批名称；不代替主会话更新共享看板。

不修改 `ScanStore.swift`、评分实现/权重、私有 API 白名单或系统助手。不安装、启动应用，不执行安全命令，不改变系统设置。可选防火墙隐身模式未增加；本批覆盖要求的四个主要状态。

## 实际改动与理由

1. **复用 `SystemProtectionAudit`，补齐 FileVault。** 只接收检查枚举，生产 `runCommand(for:)` 内固定四组绝对路径/参数：`/usr/bin/csrutil status`、`/usr/bin/fdesetup status`、`/usr/sbin/spctl --status`、`/usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate`。经现有 `Shell.run` 执行，每次超时参数 3 秒、合计输出上限 8192 字节，沿用取消和安全子进程收尾。不经 shell、无管理员请求、无写命令。Shell 的进程退出验证/收尾时间独立于命令采样超时，不能把 3 秒称为整个健康扫描的实测耗时。
2. **收紧结果解析与证据。** 英文标准状态行、中文样例、空白/全角冒号/括号均有覆盖；匹配完整已知状态行，不按 `enabled` 子串或成功退出码推断正常。非零退出、缺命令、拒绝、超时或输出超限为“无法读取”；退出成功但陌生、矛盾或自定义 SIP 输出为“未知”。FileVault 加密/解密进度为“转换中”，不声称已完成加密；防火墙 State=2 的已知响应识别为已开启。原始 stdout/stderr 和任意错误诊断不进入事件摘要。既有 XProtect 组件读取保留在数据保护展开内容，四项新增安全行及日志不把它作为第五项。
3. **共享健康探针。** `DefaultComputerHealthProbe` 的任务组增加安全读取，完成后交给可注入的 `ComputerHealthEventPersisting`。`ComputerHealthStore.refresh` 与智能扫描默认闭包都走这个探针，`SmartScanScope.health` 原有范围语义不变；不勾健康不执行这条链。安全项不可读仍能完成健康快照；日志失败单独设置 `changeLogReadFailed`，不改健康/文件评分与 outcome。取消传播，不把未完成扫描写成结果。
4. **版本兼容的快照字段。** 增加可选 `security`、`recentChanges` 和 `changeLogReadFailed`，老快照缺字段时保持未检查/空日志/无日志错误，不凭空补“正常”。维持原有电池快照兼容编码和评分模型版本。
5. **事件日志。** 新增结构化检查项/状态/事件模型及 `ComputerHealthEventRepository` actor。默认文件是 `AppDataDirectories.applicationSupportRoot/computer-health-events.json`，沿用正式版/Beta 数据目录隔离，本机保存。单个版本 1 JSON 原子保存上次基线及事件；9 项检查覆盖磁盘 SMART、容量、稳定性、电池、时间机器和四项安全检查。首次读取只建立基线；只有状态变化才追加，不按证据值波动制造事件；同一天多次变化保留。新事件优先，上限 200 条，证据上限 256 字符，文档上限 512 KiB。缺失的检查不捏造变化；较旧或相同时间的完成结果不回滚基线；取消先于写入时不推进基线。损坏、未知版本或不可读日志不自动覆盖旧证据，界面提示日志失败。
6. **沿用 D70①结果布局。** 现有结果摘要、评分行、环境分区与证据展开保留。新增 `HealthSecurityChecksView`，四行直接复用 `FeatureLightfieldStatusDisclosure`，含状态符号/名称/证据/状态词/行尾展开。关闭或转换中为警告，未知/无法读取为未知符号，开启为正常。每项展开含一句建议、读取时间、“打开系统设置”按钮和打开失败提示。复用 `CleanupService` 的系统设置 opener，增加隐私与安全性/FileVault/防火墙目的地及旧链接回退；没有开启开关或写入操作。
7. **统一证据时间。** 原数据保护展开内的单独“检查系统防护”查询按钮及临时任务移除，改读本次健康快照，避免独立读取绕过日志、与结果行时间不一致；原数据保护展开结构和时间机器内容继续保留。磁盘证据中的卷元数据改名“卷加密”，与 `fdesetup` 的全局 FileVault 状态分清来源。
8. **最近变化。** 两处结果页复用 `HealthRecentChangesView`，无历史事件时没有“最近变化”标题；有历史变化时默认展示最近 5 条，按钮展开最多 200 条全部事件并可收起。即使本轮没有追加事件，已有的“最近变化”仍可查看。日志失败单独显示原因类别，不以空日志冒充从未变化。

## 评分影响（明确为零）

现有 `ComputerHealthAssessmentModels`/`ComputerHealthScoring` 的设备健康模型只计磁盘 35、容量 15、稳定性 20、电池 30；无内置电池沿用不适用分母处理；时间机器权重为 0。安全检查与备份一样作为独立保护提示，**不增加 HealthFactor、不重分配权重、不改变分数、coverage、confidence、总体 evaluation.status 或模型版本 `computer-health-v2`**。

| 安全读取结果 | 行状态 | 健康分变化 | 原评估/历史 |
|---|---|---|---|
| 明确开启 | 正常 | 0 | 不变 |
| 明确关闭 | 警告，显示已关闭 | 0 | 不变 |
| 加密/解密转换中 | 警告，显示转换中 | 0 | 不变 |
| 陌生或矛盾输出 | 未知 | 0 | 不变 |
| 非零退出、拒绝、缺命令、超时、超限 | 无法读取 | 0 | 不变 |

`ComputerHealthSecurityScoringTests` 将上述完整 evaluation 与 100 分、coverage=1 的相同设备基线比较，并锁定 SMART 故障仍 `actionRequired` 且不超过 20 分、事件历史不影响评分。安全项全部开启也不能弥补设备问题。未修改任何旧测试断言、阈值或跳过条件，未删除测试方法。

## 测试源码与隔离

新增 32 个测试方法（其中 3 项原生视图方法仅 Debug 编译），扩展原 `SystemProtectionAuditTests`，新增事件仓库、评分影响、快照/智能扫描/原生行、固定命令及视图源码守卫四个测试类。`ComputerHealthSecurityFixture` 是纯数据夹具。

JSON 根一律 `TestFileSystem.makeHome(for: self)`，由测试基础设施登记并清理。没有新增偏好写入/套件，没有调用真实默认健康探针，也不调用真实安全命令或系统设置按钮。UI 测试沿用现有 `CalibrationAppKitLayoutHost`，只按展开/收起按钮，覆盖 D69 七尺寸 × 两种外观的状态符号/状态词/行尾展开列对齐；不把行列几何测试等同于整页实机认可。定向清单含 `UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`。

源码守卫核对四组固定可执行文件/参数、Shell 超时和输出上限、无 shell/管理员调用/设置写入；系统健康与智能扫描共用默认探针；两处结果都挂接安全行/事件；视图不直接 `Process(`、`Shell` 或防护探针。此处是新增守卫源码，**没有宣称 XCTest 已通过**。

## 主会话验证命令

先按 RULES 复制既有离线依赖到本批 scratch；以下命令在沙箱外、此 worktree 执行。18 类准确清单见 scratch 的 `targeted-classes.txt`。日志不要写到共享默认构建目录。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
batch_scratch=/Users/developer/Developer/.sc-build/r2-health-security
swift build --scratch-path "$batch_scratch/debug" --jobs 4 > "$batch_scratch/build-debug.log" 2>&1
swift test --scratch-path "$batch_scratch/debug" --jobs 4 \
  --filter "$(paste -sd '|' "$batch_scratch/targeted-classes.txt")" \
  > "$batch_scratch/targeted.log" 2>&1
```

主会话记录 exit code、测试数、跳过数及日志。若有编译/严格并发错误，回交同一会话修复，重新生成 prepared 哈希后再继续。完成定向验证与独立复核后由主会话执行完整门禁（Release/Debug 全量、严格并发、源码守卫、小窗性能和 Beta 配置构建），按本批隔离要求运行项目 verify 时使用：

```bash
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 \
  STORAGE_CLEANER_VERIFY_ROOT="$batch_scratch/verify" bash script/verify.sh \
  > "$batch_scratch/verify.log" 2>&1
```

该命令不构成安装授权，主会话按现有发布门禁核对覆盖范围。系统设置 deep link 是否落到正确面板，以及真实系统语言下的命令输出，需要主会话后续 UI/只读实机验收；本会话没有启动任何应用或进行这种验收。SIP 没有可在常规系统设置中开启的开关，按钮落到隐私与安全性，建议明确说明更改需要恢复环境；不能声称已打开 SIP 专属开关页。某些 macOS 版本可能接收 deep link 但只打开父面板，必须实测确认。

## 红 / 绿 / 反证

所有执行状态均 NOT RUN。`counterexamples.json` 在 scratch，含 16 个唯一命中的单点变异锚点、定向 filter 和应失败断言。**主会话复制最终源码到独立反证工作区，一次只应用一项，运行指定测试，确认红，再恢复绿色源码；不在真实数据上实验，不执行变异后的安全命令。** CE04/CE05 仅跑源码守卫。完整记录编译失败与断言失败的区别，不能把任意编译报错当作预期反证。

| 修复面 | 红色做法 | 绿色目标 | 反证 |
|---|---|---|---|
| 中英解析、未知不正常、读取失败分类 | CE01/02/03 | 解析器类全部断言成立 | 错误输出/非零退出/超时不成正常 |
| 四项固定只读命令 | CE04/05 | 源码白名单与禁写守卫通过 | 路径变化或 setter 参数必须被拒 |
| 安全评分零影响 | CE06 | 完整 evaluation 等于原设备基线 | 关闭扣 10 分必须变红 |
| 变化才记、滚动与过期保护 | CE07/08/09 | 仓库类通过且 200 条新到旧 | 重复记账、201 条、旧结果回滚变红 |
| 本地隔离、证据隐私、原子写入 | CE10/11/16 | 隔离 JSON 无原始私有摘要，原子接线成立 | 换数据根/存私有摘要/去原子写入变红 |
| 语义符号、共享探针、智能扫描显示 | CE12/13/14 | 两处使用同一检查结果，未知不成正常 | 错误符号/断开默认探针/漏智能扫描行变红 |
| 最近 5 条及查看全部 | CE15 | 原生 AX：无事件无标题，5 条默认，7 条展开 | 第 6 条默认可见必须变红 |

额外绿色用例覆盖：损坏日志不覆盖原文件；阻塞日志路径不覆盖阻塞文件；取消不写；重启不重复；缺失安全字段不制造变化；同日多次变化；FileVault 转换不冒充开启；未知→无法读取→恢复状态可区分。未放宽产品文件路径检查。

## prepared 分组与静态核对

`scratch/prepared/`：

1. `01-security-audit.patch`：既有防护审计扩展、状态 Codable、固定 Shell 查询与解析测试。
2. `02-events-pipeline.patch`：事件模型/仓库、快照兼容字段、默认健康探针接线、事件测试与纯数据夹具。
3. `03-results-contracts.patch`：系统设置复用、两处安全结果/事件视图、评分影响/集成/源码守卫测试。
4. `04-handoff.patch`：本交接。

另附各组 `-message.txt`、`all.patch`、`manifest.json`（完整基线、分支、16 个最终文件 SHA-256、组顺序和产物哈希）、`commit-prepared.py`、`generate-prepared.py`、`static-checks.json`。提交脚本仅供主会话验证后显式 `--validated` 执行，会核对基线、分支、暂存区、最终文件/产物哈希及改动集合，再分组暂存并提交；本会话不运行它。模型标识未在本会话工具中暴露，提交尾注如实写 `Codex (model identifier unavailable)`，没有凭旧示例自称某一模型或改模型。

静态核对限于 Git 只读差异、补丁反向适用性（`--check --reverse`）、修改边界和元数据/唯一变异锚点；实测 exit code 与条目见 `prepared/static-checks.json`。不把这些核对当作 Swift 编译或原生测试。

## 未解决 / 待主会话验证

- NOT RUN：编译、严格并发、18 类定向测试、16 项反证、完整门禁、真实命令输出、系统设置面板与整页实机显示；本轮无安装或提交。
- BLOCKED：`mcp__jev__jev_decide` 在安全评分取舍处调用被拒：`MCP tool call requires approval, but approval policy is never`。可调用 schema 没有模型覆盖参数，拒绝结果也未返回实际模型标识，**未获得 JEV 判断**。证据为 `scratch/jev-status.json`；没有绕过审批策略或把静态自审称为独立 JEV 复核。
- 输出协议发生变动时保持“未知”，日志损坏时保留原件并显示失败，不自动修复/覆盖；这些是保守边界。事件日志只比较已完成的健康快照，并非连续安全监控；两次检查之间的中间变化无法观察。

## 主会话验证轮（2026-10-09，Claude Opus 5.5）

沙箱外在本 worktree 实际执行；未安装、未碰 /Applications、未提交、未 push。日志在 scratch `logs/main/`。

### 改动（在 Codex 版本之上）

1. **FileVault 真实转换输出**（`SystemProtectionAudit.swift`）：`fdesetup status` 在加密/解密进行中实际输出两行（`FileVault is On.` + `Encryption in progress: Percent completed = …`），原解析器要求单行，会把真实转换状态判为“未知”。新增：仅当第一行是 On/Off 且第二行是进度行时判“转换中”；其余两行组合（延迟启用、顺序颠倒、三行矛盾）仍为“未知”。抽出 `isFileVaultProgressLine` 复用单行判断。
2. **真实输出夹具**（`SystemProtectionAuditTests`）：新增 `testRealCommandOutputsCapturedOnMacOS27`（本机只读运行四条命令的逐字节 stdout，含行尾换行；防火墙本机为 `Firewall is disabled. (State = 0)`）与 `testTwoLineFileVaultConversionOutputIsTransitioningButOtherSecondLinesAreUnknown`。实测：这四个命令在 `LANG/LC_ALL=zh_CN.UTF-8` 下输出与英文完全相同（不本地化），中文夹具仍保留作防御。
3. **原生布局测试修夹具**（`ComputerHealthSecurityIntegrationTests`）：`testSecurityRowsKeepExistingSymbolValueAndDisclosureColumnsAtSevenSizes`、`testRecentChangesHideEmptyShowFiveAndExpandAll` 首次运行失败——裸组件高度小于窗口，`fixture.viewport` 高度≠宿主尺寸，`frames(required:size:)` 永不稳定（报错 `frames did not settle`）。给根视图加 `.frame(width: size.width, height: size.height, alignment: .topLeading)`，与其他使用整页根视图的 Calibration 测试一致。**未改任何断言、阈值或跳过条件。**
4. **英文状态词**：`SystemProtectionState.unreadable` 与 `ComputerHealthCheckState.unreadable` 英文由 “Could Not Read” 改为项目已有的 “Unreadable”（离屏渲染发现值列截断成 “Could…t Read”）。中文不变。
5. **Debug 演示夹具**（`Debug/FeatureLightfieldResultFixture.swift`，仅 `#if DEBUG`）：健康结果夹具补四项安全结果（防火墙关闭）和两条“最近变化”，供截图核对；不影响 Release/Beta。
6. scratch：`counterexamples.json` CE01 锚点因新函数调整上下文（变异语义不变），新增 CE17；`prepared/generate-prepared.py` 改为 17 个文件、34 个新测试方法后重新生成 prepared（见下）。

### 测试数字（最终源码）

- Debug 构建（含测试）：exit 0，无 error/warning 行。
- 定向（`targeted-classes.txt` 18 类 + `TestPreferenceHygieneTests` + `UIConsistencyRegressionTests`）：**241 项，0 失败**。
- 全量 Debug：**4344 项，25 跳过（全部为既有类，非本批），0 失败**。第一次全量（改动 4/5 之前）有 1 项 `DuplicateContentReadTests.testImageSignatureTimeoutIsPartialAndCancellationUsesScanControl` 1 秒等待超时；该类单跑 3 次全过，之后两次全量均 0 失败，判为并发负载下的既有计时抖动，与本批无关。
- 隔离：测试前后 `~/Library/Application Support/StorageCleanerMac{,-Beta}/computer-health-events.json` 均不存在；`script/check_private_api.py` 通过（7 处白名单）。

### 反证

`counterexamples.json` 17 项逐项单独应用→跑指定 filter→恢复（SHA-256 校验）：**17/17 变红，全部为断言失败，非编译错误**。CE04/CE05 只跑源码守卫，未执行变异命令；CE13 未运行默认探针。反证后重新构建 exit 0，并在其后完成上面的最终全量。

### Release / Beta

独立 scratch（`release/`、`beta/`，从 debug 复制 checkouts/repositories/artifacts 并改写 workspace-state.json 路径）：`swift build -c release` 与 `-c release -Xswiftc -D -Xswiftc STORAGE_CLEANER_BETA` 均 exit 0（最终源码增量重建同样通过）。

### 截图（D70①核对）

Debug 包用 `SWIFT_BUILD_DIR=/tmp/storage-cleaner-hsec-build`、`DIST_DIR=/tmp/storage-cleaner-hsec-dist`（直接用覆盖变量避免与其他批次共用 run-dist，产物随即改名 `/tmp/storage-cleaner-hsec-app`）打包，`capture-main.sh` 以隔离 QA 身份拍 `healthHub:result`，日间 deepSpace／夜间 pureBlack × 1280×763、820×560、2400×1350、677×390；结果在 scratch `shots/hsec-day|hsec-night/`。另有离屏渲染 `shots/rows-light.png`、`rows-dark.png`（四种状态 + 7 条变化，临时测试文件用后已删除，未进入改动集）。

- 与 `r2-ui-v1-shots/r2/shots/lf-r6-light/1280x763-healthHub-result.png`（现行生产结果页）对比：标题、评分区、行样式、列对齐、重新检查按钮与底栏完全一致，只在电池行后多出安全行，符合 D70①。
- 结果列表是既有的有界滚动区（`FeatureLightfieldResults` + `snapsResultRows`），1280×763 只露出到“系统完整性保护”，2400×1350 露出到“磁盘加密”；Gatekeeper、防火墙、环境分区和“最近变化”需要在列表内滚动才能看到。这是现有布局的行为，未为此改布局；是否接受“安全行需滚动”请用户在实机确认。
- 离屏渲染：状态符号语义（开启=对勾，关闭/转换中=警告，无法读取=问号）、值列、行尾展开对齐正常；“最近变化”默认 5 条 + “查看全部（7 条）”。

### 未解决 / 待确认

- 系统设置 deep link（FileVault、防火墙、隐私与安全性）实际落到哪个面板：未实测（未点按钮）。
- 真实安全命令的中文输出：本机 macOS 27.2 不本地化，中文解析分支只有构造夹具。
- 安全行在结果列表中需滚动可见（上节）；“最近变化”位于环境分区之后、评分依据之前，用纯文本样式（字号/字重沿用默认），如需与光场行风格统一可另开小批次。
- JEV：本轮未调用（`jev-status.json` 仍为 Codex 轮的 BLOCKED 记录）。
- 未提交；`prepared/` 已按最终文件重新生成，主会话复核后可执行 `commit-prepared.py --validated`（会核对 17 个文件哈希）。

## 复核修复轮（2026-10-09，Claude Opus 5.5 子代理）

基线 a08cede4（prepared 四个提交之后）。独立复核结论：无 P0，1 个 P1 和 8 个 P2，本轮全部处理。

### P1 Gatekeeper 关闭时的退出码

- `SystemProtectionAudit.finding(from:for:)`：新增 `isDocumentedDisabledExit`。只有同时满足“Gatekeeper、退出码 1、stdout 去首尾空白后恰为 `assessments disabled`”才判已关闭（警告）。依据是 Apple 开源 spctl，`--status` 在 Gatekeeper 关闭时输出这一行并以 1 退出。其他非 0 退出仍判无法读取，证据为“读取失败（退出码 N）”。
- 其余三项的核对：
  - `socketfilterfw --getglobalstate`：本机防火墙关闭时实测输出 `Firewall is disabled. (State = 0)`，退出码 0。二进制字符串表只有 `Firewall is disabled. (State = %d)` 和 `Firewall is enabled. (State = %d) `。
  - `fdesetup status`：字符串表含 `FileVault is Off.`、`…, but will be enabled after the next restart.`、`FileVault is On, but needs to be restarted to finish.`、`Encryption/Decryption in progress: Pending|Percent completed = %s`。本机 FileVault 开启，无法实测关闭时的退出码。
  - `csrutil status`：字符串表只有 `System Integrity Protection status: `。本机 SIP 开启，无法实测关闭时的退出码。
  - 结论：fdesetup 与 csrutil 关闭时若退出码非 0，仍判“无法读取”（保守，不会把关闭误显示为开启），需在关闭 FileVault/SIP 的机器上补测。“需要重启才能完成”的两种 FileVault 输出仍判“未知”。
- 测试：`testGatekeeperOffWithDocumentedExitOneIsDisabledWarning` 是正例（含行尾换行和空白）。`testOnlyThatExactGatekeeperShapeEscapesTheNonzeroExitRule` 是反例，覆盖：退出码 2/69、enabled+1、两行、`error:` 前缀、空输出、另三项的关闭文本+1、另两项输出 `assessments disabled`+1。原 `testNonzeroExitAndStderr…` 只断言 `assessments enabled`+非 0 为无法读取，与新规则一致，未改。

### P2

1. **SMART 故障用语**：`ComputerHealthCheckState.title(for:)` 中，磁盘的 warning 显示“故障警告”/“Failure”，与结果行相同。级别仍是 warning，与结果行的警告符号同级，日志存储值不变。
2. **无法读取/未知不记事件**：`isIndeterminate` 的状态既不记事件，也不替换上次确定的基线。开启→(超时)→开启不记事件；开启→(超时)→关闭只记一条“开启→关闭”；首次确定读数只建立基线。
   - 改写旧断言（依据复核 P2-2）：`testUnknownUnreadableAndRecoveryAreDistinctStateChanges` 改为 `testUnknownAndUnreadableNeverLogAndDoNotReplaceTheDeterminateBaseline`；`testEvidenceIsBoundedAndAllExistingChecksCanEmitChanges` 的期望集合去掉 battery（不适用→无法读取属于不确定读数）。
3. **日志损坏或版本不识别**：DecodingError、invalidJournal（含未知 version）、journalTooLarge 时，原文件 `moveItem` 为同目录 `<名>.corrupt-<UTC 时间>`，重名时加随机后缀，不覆盖；然后从本次检查重建基线。读写 I/O 或权限错误仍按“日志失败”处理，不写入。
   - 页面：`ComputerHealthSnapshot.changeLogWasReset` 只在为 true 时编码。“最近变化”区显示一句说明：“原变化日志无法识别，已在同一目录备份原文件，并从本次检查重新开始记录。”
   - 改写旧断言（依据复核 P2-3）：`testCorruptJournalFailsWithoutOverwritingExistingEvidence` 改为 `testCorruptOrUnknownVersionJournalIsKeptAsideAndBaselineRestarts`，锁定备份字节与原件完全相同、只有一个备份、新日志可用、下一次正常记事件。
   - 接口：协议方法改为 `recordChanges(_:) -> ComputerHealthEventRecording`，actor 仍保留 `record(_:)` 返回事件数组。
4. **结构化证据**：`SystemProtectionEvidence` 取值为 systemQuery、outputUnrecognized、readFailed(exitCode)、readTimedOut、outputTooLarge、readCancelled、commandUnavailable、legacy。`ComputerHealthEventEvidence` 取值为 status、availableBytes、batteryMaximumCapacity、security、legacy。文件里只存代码和数字，显示时按当前语言本地化。
   - 旧格式中只有 `evidenceSummary` 文本的记录解码为 `.legacy`，按原文显示；legacy 文本仍有 256 字符上限。
   - 测试锁定：JSON 中不含“系统查询”或 “Confirmed”；中英文切换后显示对应语言；旧版发现与旧版日志都能解码。
5. **设置跳转**：Gatekeeper 新增目的地，`PrivacySecurity.extension?Security`，回退到 `preference.security?General`。FileVault 的旧版回退链接锚点改为 `?FDE`。是否真的落到对应面板仍未实测。
6. **四条命令耗时**：本机只读串行跑 5 次，总耗时 p50 43 ms、p95 51 ms（fdesetup 约 32 ms，其余 3–4 ms），远低于 1 s，保持串行，各自 3 秒超时不变。
7. **样式**：“最近变化”改用光场状态展开行（`FeatureLightfieldStatusDisclosure`）：状态符号、检查项、“旧→新 · 时间”作三级说明、新状态放值列、证据和完整时间在行尾展开内。标题与提示用 13 pt fg2，行间细线与检查行对齐，“查看全部/收起”用 `FeatureLightfieldRowButtonStyle`。
   - 智能扫描健康部分原先混用 `FeatureFormRow`，现统一为 `FeatureLightfieldStatusRow`：磁盘 SMART、可用容量、电池（容量·循环）在前，安全行在后，`Text(status?.title ?? unavailable)` 保留。可用容量优先取磁盘读数，缺失时取容量快照。
   - 安全行说明列显示证据句“系统查询确认（csrutil status）”等，不再重复状态词；演示数据同样改为结构化证据。
   - 改写旧断言（依据复核 P2-7）：`testRecentChangesHideEmptyShowFiveAndExpandAll` 中 AX 标签由证据文本改为“检查项 · 新状态”（证据移入展开内容），并新增日志重建提示的 AX 断言。
8. **截图**：Debug 包重拍，日间 deepSpace、夜间 pureBlack，各 820×560、1280×763、2400×1350、677×390，结果在 scratch `shots/hsec-day|hsec-night/`。离屏渲染 `shots/rows-light.png`、`rows-dark.png` 已覆盖旧图，另有 `smartscan-health-light|dark.png`。临时渲染测试用后删除，未进入改动。
   - 布局仍与 D70① 现行页一致，说明列显示证据句。安全行和“最近变化”仍需在既有的有界列表里滚动查看，这一点未改。
   - 智能扫描“可用容量”的回退是在拍摄之后改的，截图未覆盖，只经构建与测试验证。

### 测试与反证

- `counterexamples.json` 共 27 项（原 17 项，CE02/CE03/CE11 只调整锚点，语义不变；新增 CE18–CE27）。逐项单独应用、恢复后校验 SHA-256。
- 27/27 变红。CE19（豁免扩到其他检查）首跑没有变红，因为原测试只用各自命令的关闭文本；补两个反例后变红，见 `note`。
- 反证后重新构建通过。最终数字见下一小节。

## 中断续接与最终修复交付（2026-10-09，Codex）

本节为本轮实际证据。上文“复核修复轮”的反证、全量、Release/Beta、截图和耗时属于接手前记录；本轮没有执行这些验收，不能把它们当作当前最终文件的通过结果。

### 接手审计与保留

- 先读两份公共提示与 RULES、D5/D48/D55/D60/D64/D69/D70/D71；核对 `git status`、完整 `git diff` 与 HEAD，分支 `task/r2-health-security`，基线 `a08cede4446f09da61567760d29fec2ee7538cc6`。工作区 15 个已修改文件全部保留。
- 接手源码、完整 diff、SHA-256、原 prepared 与反证记录保存在 scratch `resume-20261009-input/`，没有重置、丢弃或清理工作区。
- `.git` 元数据只读，本轮按公共规则提供 `prepared/` 供主会话验证后提交；未执行暂存、提交、安装、启动应用、发布或硬件设置写入。`ScanStore.swift`、评分实现/模型和私有 API 白名单与基线保持相同。

### 最终修复与断言依据

1. **P1 精确豁免**：保留 `isDocumentedDisabledExit` 的三个必要条件：Gatekeeper、退出码 1、stdout trim 后恰为 `assessments disabled`。其它非 0 退出仍无法读取。原非 0 测试现在明确断言 disabled+1 为关闭、disabled+2/69 无法读取；额外反例锁定大小写变化、双空格、尾句号、中文输出和 SIP 复用相同字节均不能进入豁免。正例仍覆盖首尾空白/换行及警告级别。该规则以本轮任务给定的 Apple spctl 契约为依据；外网获取 Apple 原源码在本环境未成功，没有声称重新取得源码或在本机关闭 Gatekeeper。
2. **其它关闭退出码**：五次真实只读防火墙查询均为 `Firewall is disabled. (State = 0)`、退出码 0，已独立确认。`csrutil status` 只读到开启、退出码 0，未确认关闭时退出码。`fdesetup status` 五次均退出 15、stdout 空、stderr 为 `Error: Unknown volume or device specifier: '/'.`；不能据此判断 FileVault 开关。本机 Apple `/usr/share/man/man8/fdesetup.8` 的通用退出表 547–565 行列出 1=FileVault Off，且 `isactive` 节显式定义关闭返回 1，但 `status` 节没有单独承诺关闭退出码；不足以扩大本批 `status` 豁免，仍保守保持无法读取，交主会话在有明确关闭状态的机器核对。没有运行 `isactive` 或设置命令替代既定四条查询。
3. **P2 日志等级与噪声**：磁盘 SMART failing 存 warning，显示“故障警告”/“Failure warning”，和结果页警告符号及英文一致。未知/无法读取既不记变化，也不替换确定基线；初次确定读数只建基线。沿用上文已列出的两项旧断言改写，依据为本轮明确 P2②。
4. **P2 原件保护与兼容**：损坏/未知版本日志先 `moveItem` 到 `.corrupt-<时间>`，再原子写入新基线；备份冲突加随机后缀，I/O 失败保持失败提示。新增连续两次损坏测试，锁定两份备份字节均保留，先前备份路径及内容不变。新证据只存结构化代码/数值；旧 `evidenceSummary` 解码为 legacy 文本保留原文。语言测试现在实际从磁盘重读事件，然后逐一切换中英文核对显示，不只检查 JSON 中没有翻译文字。旧快照缺 `changeLogWasReset` 时明确为 false。
5. **P2 链接和视觉**：保留 Gatekeeper `?Security` 与旧 FileVault `?FDE` 链接；最近变化用光场展开行，智能扫描健康读数全部用光场状态行，安全行说明列与演示数据提供结构化证据句。日志失败及重建提示由原 13 pt 文本改为 `FeatureLightfieldStatusRow`，继承符号、列对齐、字体/颜色/细线令牌；同时保留完整说明的 AX 标签。相应原生 AX 断言改为完整行“变化日志 · 说明 · 状态”，新增失败行断言及源码守卫。依据为本轮明确 P2⑦，不放宽几何阈值或移除断言。

### 本轮编译与测试

固定环境 `DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`、`LC_ALL=en_US.UTF-8`。实际命令：

```bash
batch_scratch=/Users/developer/Developer/.sc-build/r2-health-security
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$batch_scratch/debug" \
   --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$batch_scratch/targeted-classes.txt")"
swift test "${F[@]}" --skip-build --filter ComputerHealthSecuritySourceGuardTests
python3 script/check_private_api.py
git diff --check
```

| 检查 | 本轮结果 | 证据（scratch 相对路径） |
|---|---|---|
| Debug + 测试目标编译 | PASS，exit 0；首次 16.64 s，最终增量 6.04 s | `resume-build-debug.log`、`resume-build-final.log` |
| 18 类完整定向集合 | BLOCKED，实际进程 exit 1；246 项测试，32 个失败（29 unexpected），0 跳过 | `resume-targeted.log`、`resume-validation.json` |
| 五类安全相关测试 | PASS，共 40 项、0 失败；来自上述完整集合 | 同上；仓库 13、解析 12、集成 8、评分 3、源码 4 |
| 最终新增守卫后的源码类复跑 | PASS，exit 0；4 项、0 失败 | `resume-source-guard-final.log` |
| UIConsistencyRegressionTests | PASS，46 项、0 失败 | `resume-targeted.log` |
| 私有 API 守卫 | PASS，exit 0；7 个许可调用 | `python3 script/check_private_api.py` |
| 全量、Release/Beta、严格并发专项、最终截图及链接真实落点 | NOT RUN（本轮普通 Swift 6 Debug 编译通过，不等同专项门禁） | 主会话执行 |

构建只有 SwiftPM `--skip-update` 弃用及用户缓存/配置目录不可写警告，没有 Swift 源码编译错误。定向失败完整方法名与错误保存在 `resume-validation.json`：

- `FeatureLightfieldContractTests`：6 个家目录操作夹具创建失败；`SmartScanHistoryTests`：4 个；`SmartScanScopeTests`：19 个。均由 `TestFileSystem.swift:60` 创建 `~/.storage-cleaner-*` 时 NSCocoaError 513 / POSIX 1（Operation not permitted）阻塞。
- `TestPreferenceHygieneTests`：`testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory` 的两条断言及 `testTemporarySuiteCanBeReopenedOnAWorkerThread` 的一条断言失败，同段日志有 `sandbox_extension_issue_file ... defaults.plist: Operation not permitted`，`synchronize()` 无法完成临时偏好落盘。未改域、测试或阈值。
- 主会话在沙箱外用上面的 **完整 18 类 filter** 复跑，不用跳过这些测试掩盖失败。当前 15 个工作区文件和完整补丁仍需要该复跑通过后才可提交/合并。

### 五次只读串行计时

本轮由 Python `subprocess.run` 逐条执行固定四个绝对路径/参数，每条 timeout=3 s；墙钟包含创建子进程及输出收集，未包含项目 Shell 的额外收尾等待，也不代表整个健康扫描。每轮总耗时依次为 **30.545、18.357、17.540、16.490、16.716 ms**；p50 **17.540 ms**，nearest-rank p95（五次中的最大值）**30.545 ms**。每条的输出、退出码、耗时及本机 macOS 27.2 信息保存在 `readonly-command-timing-20261009.json`。

**限制**：五次 `fdesetup` 均退出 15；这组数字包含失败查询，不能作为四条命令全部成功读取的性能验收。接手前交接记录的沙箱外 p50 43 / p95 51 ms 也低于 1 s，但本轮没有重新验证该完整成功数据。当前保持串行及各自 3 s 超时不变；提供 scratch `measure-readonly-commands.py`，由主会话沙箱外同样只读跑五次并取得成功数据，如 p50 或 p95 >1000 ms，再改为并发且各自超时保持不变。

### 反证、补丁与待主会话事项

- `counterexamples.json` 基线更新为 a08cede4，共 **28 项**，全部最终锚点恰好命中一次。更新 SMART 英文锚点；新增 CE28 锁定失败提示光场行。红/绿做法：绿色源码跑各 filter；在隔离复制工作区每次仅应用单项变异，指定断言必须失败，恢复后再跑绿。本轮按公共规则 **NOT RUN 反证**；原 27/27 的接手前结果完整归档，当前状态没有沿用旧 PASS。
- `prepared/` 4 组：`01-security-audit`（退出码与解析）、`02-events-pipeline`（结构化证据、恢复、模型/探针）、`03-results-contracts`（光场行、设置链接、演示与守卫/AX）、`04-handoff`（交接）。均相对 **a08cede4**，包含全部接手改动及本轮追加；有 `all.patch`、提交说明、最终文件/产物哈希、静态检查和 `commit-prepared.py --validated`。原 prepared 归档，未混用原 0bd131b2 基线。
- JEV：本轮核对实际 callable `mcp__jev__jev_review`，schema 没有模型覆盖参数。调用被审批层拒绝：`MCP tool call requires approval, but approval policy is never`。模型请求未执行、实际模型标识未返回，没有 JEV 结论；见 `jev-status.json`。
- 尚待主会话：沙箱外完整定向集合、最终反证、全量/Release/严格并发门禁；四条成功查询的五次计时；FileVault/SIP 关闭退出码依据；最终行布局截图及设置链接真实落点。只有完成验证后执行 prepared 提交。本轮没有安装或系统修改授权，也没有执行这些操作。
