# disktree-p1：空间地图方块图第 1 期交接

PASS：4 个纯算法模块及 4 个内存测试文件已新增，最终构建与 52 项相关测试通过；界面、完整门禁、独立复核与合并交由 Claude 主会话。

工作目录：`/Users/developer/Developer/sc-worktrees/disktree-p1`。当前为独立 worktree 的 detached HEAD，基点 `6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b`。实际验证日期为 2026-10-22（Australia/Sydney），批次仍沿用 2026-10-21 的名称。

**新增文件（仅这 9 个）**

生产文件均在 `Sources/StorageCleanerMac/Features/SpaceMap/Treemap/`；测试均在 `Tests/StorageCleanerMacTests/`。

| 文件 | 实际改动 |
| --- | --- |
| `SpaceMapTreemapLayout.swift` | 稳定 squarify、1–6 层嵌套、名字带、间距、尾部合并、筛选缩放与逆序命中。 |
| `SpaceMapTreemapFilter.swift` | Unicode 名称筛选、整块/部分保留、匹配统计、索引快照遍历及取消。 |
| `SpaceMapPurposeClassifier.swift` | 9 种用途、10 种可回收原因、同级与目录表规则、保护边界及稀疏祖先继承查询。 |
| `SpaceMapInsights.swift` | 门槛剪枝、最外层可回收目录、工作树计数、确定排序及数量上限。 |
| `SpaceMapTreemapLayoutTests.swift` | 17 项覆盖面积/比例/退化值、层次/名字带/命中、终止块、合并、筛选和确定性。 |
| `SpaceMapTreemapFilterTests.swift` | 8 项覆盖中日文/重音、整块与祖先、范围边界、重复硬链接、被挡目录及取消，并提供本批共用的纯内存索引夹具。 |
| `SpaceMapPurposeClassifierTests.swift` | 19 项覆盖继承、主导子目录、裸库、同级规则、目录表、家目录层级、保护边界、稀疏计数、双语和取消。 |
| `SpaceMapInsightsTests.swift` | 8 项覆盖门槛、互不嵌套、工作树、排序/上限、重复硬链接、根目录、取消及 20 万项基准。 |
| `docs/2.0.0/collab/handoffs/disktree-p1.md` | 本交接与验证证据索引。 |

开始时这 9 个目标均不存在；原工作区已有大量修改及未知文件，已保留。基线状态见证据目录的 `initial-status.txt`。没有修改已有文件，没有 commit、push、安装或运行应用。

**对应关系与有意差异**

- 参考为只读的 disktree `6c8d4ce`，4 个 Swift 文件分别对应 `core/treemap.rs`、`filter.rs`、`classify.rs`、`insights.rs`。布局文件保留 © 2026 Tobi Lütke 与完整 MIT 许可，其余三个文件指向该许可。
- 布局复用 `StorageTreemapEntry`/role/category，根层接受调用方的 `StorageTreemapPresentation.mapLayoutEntries(...)` 结果；更深层仅调用传入的 children 闭包。包、云端占位、不可进入目录和余量均不展开。有效值先归一化，避免有限 Double 相加溢出；只有确实输出可见子块才保留名字带。
- 筛选和推荐各构造一次 `DiskScanner(excludedPaths: [])` 并复用 `storageMapSnapshot(at:using:)`；不重做子项大小、硬链接、排序、估算、内容分类或可进入性推导。快照接口本身没有取消参数，遍历阶段每 1,024 项检查取消，并在入口/出口检查。
- 筛选 API 为 `SpaceMapTreemapFilter.filter(index:basePath:keyword:isCancelled:)`；结果有 `keyword`、`basePath`、`keepByPath`、`topLevelMatchCount`、`matchedBytes`、`matchedItems`。首尾空白去除后保留原关键字，比较忽略大小写与变音符；搜索基点、整块匹配项内部及搜索范围外的查询均按约定处理。项数适配现有索引：整目录为 `1 + descendantItemCount`、文件为 1；重复硬链接仍计项但字节为 0，区别于原版的 files 指标。
- 分类只给目录建关系和状态，大小直接取快照同源的 `index.directories` 聚合；`childrenByDirectory` 仅探测 manifest/HEAD 等名称，不为文件构造路径、用途条目或小写字符串集合。目录遍历/最多三层主导推断为 O(目录数)，同级规则另需探测相应已有子项名称；索引未提供 manifest 名称的常数时间索引。裸库先确认 `objects`、`refs` 目录，再检查 `HEAD`，不运行 Git。
- 分类保留 macOS 适用名单，移除指定平台/个人名单；AI 根名从现有目录表补足，包含应用支持目录中的 AI 工具。目录表按注入家目录下完整相对路径匹配，日志与临时文件单独归类；同级 `Logs` 改为 `.logs`。`Xcode/Archives`、`MobileSync/Backup` 及其子树显式阻断可回收继承，普通同名归档目录仍遵循继承规则。公开 `explicitDirectoryCount` 可检查稀疏性。
- 推荐从分析根本身开始，根若可回收也可入选；相同字节以路径打破平局。仅实现原版前两种 finding；“30 天未写入的陈旧实验”、工作树最老时间均留给第 4 期的修改时间索引。

**实际命令与结果**

全部命令均在本 worktree 执行，环境：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --filter 'SpaceMap'
```

| 运行 | exit code | 结果 |
| --- | --- | --- |
| `build-1.log` | 0 | PASS，57.10 秒；新增文件 0 警告/0 错误。 |
| `test-1.log` | 0 | PASS，51 通过 / 0 失败 / 0 跳过。 |
| `build-2.log` | 0 | PASS，23.55 秒；补 AI 根目录与绝对路径测试。 |
| `test-2.log` | 0 | PASS，52 通过 / 0 失败 / 0 跳过。 |
| `build-3.log` | 0 | PASS，21.68 秒；最终 Xcode 归档边界收紧，新增文件 0 警告/0 错误。 |
| `test-3.log` | 0 | PASS，最终 52 通过 / 0 失败 / 0 跳过，0.344 秒。 |

证据目录：`/private/tmp/disktree-p1-codex-iv_1287i/`。每份 build/test 日志另有同名 `.exit`；`source-checks.json` 记录新文件空白与生产代码禁用调用扫描，`final-review.json` 记录最终范围、空白及文件哈希。`git diff --no-index --check -- /dev/null <新增文件>` 无空白诊断（exit 1 表示新增文件差异）；另外对 9 个文件逐行检查空白。构建存在 SwiftPM 全局 manifest 缓存只读警告，首轮也有已有测试的编译警告，未阻碍构建或测试；没有绕过沙箱。

20 万项最终 Debug 样本：2,000 目录 + 198,000 文件，夹具构造不计时；分类 **10.63 ms**，布局（含按需快照）**5.01 ms**，推荐 **211.12 ms**。测试前一次系统 load averages 为 6.10 / 6.76 / 6.58，非空闲测量，未做计时断言。

**剩余工作**

- 本批没有构建或测试阻塞；完整测试、Release、变异检查、独立复核、安装与合并由主会话执行，本轮均 NOT RUN。
- 下一期接入 UI 时，children 闭包继续复用同一个 scanner 的索引快照；默认文件类型配色及气泡图默认入口按既定决定接入，本批未接 UI。
- 发布前建议主会话将 disktree/MIT 归属加入项目现有第三方声明；该已有文件超出本批修改范围，故仅保留源文件许可并交接。
- 沿用当前会话模型与推理设置，没有调用其他模型。JEV NOT RUN：本轮无已确认来源/预算及可调用工具；代码使用 `code-review-and-quality` 技能自查，不能代替主会话独立复核。

## 第 2 轮

PASS：完成本轮两项复核修正，仅修改指定的 2 个源码、2 个测试及本交接文件；以下行为说明覆盖上一轮对应描述。

- `SpaceMapTreemapLayout.layout(rootPath:rootEntries:in:options:children:filter:)` 必须传入当前目录；通过 `DiskScanner.storageMapLogicalPath` 规范化，根层 `.others.parentPath` 一律取该路径，移除条目父路径推断与 `/` 回退。17 处既有调用已更新；测试覆盖条目属于其他目录、仅有余量块时尾部合并及路径规范化，嵌套合并仍使用所在目录路径。
- `SpaceMapInsights.worthALook` 通过根的 `storageMapSnapshot(at:using:)` 获取可遍历且达标的子目录作为起点，分析根永不入选；保留门槛剪枝、终止边界、最外层匹配与可回收原因继承。原根目录测试改为 `~/.cache` 下达标子目录入选、根与更深层不入选；另补普通不可回收根仍发现嵌套缓存的测试。

实际命令（本 worktree；环境及参数与上一轮一致）：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --filter 'SpaceMap'
```

| 运行 | exit code | 结果 |
| --- | --- | --- |
| `build.log` | 0 | PASS，SwiftPM 报告 23.68 秒；本批 8 个源码/测试文件 0 警告、0 错误。 |
| `test.log` | 0 | PASS，54 通过 / 0 失败 / 0 跳过；布局 18、推荐 9、分类 19、筛选 8，共 0.386 秒。 |

证据目录：`/private/tmp/disktree-p1-round2-cfwfc7o0/`。`commands.json` 保存实际参数与环境，`build.exit`、`test.exit` 保存退出码，`verification.json` 保存测试与警告摘要，`round2-code.diff` 保存 4 个代码文件相对本轮基线的差异；`final-review.json` 记录最终范围、文件哈希和交接仅追加检查。构建仍有 SwiftPM 用户缓存不可写及 manifest 只读数据库提示，均未指向本批文件，无构建/测试阻塞。

随原有基准测试实测的 20 万项 Debug 样本：分类 14.08 ms、布局（含快照）5.18 ms、推荐 234.12 ms；未添加计时断言。原工作区状态与本批其余 4 个文件保留；本轮无未解决修正项。完整门禁、独立复核及集成仍由主会话处理。JEV 未调用：本轮无已确认来源/预算及可调用工具，沿用当前模型并使用 `code-review-and-quality` 自查。

## 第 3 轮

目标测试卫生修正已完成；构建 PASS，过滤测试 FAIL（当前 Worker 沙箱限制），验收第 2 项仍待主会话复跑。

- 仅修改 `SpaceMapPurposeClassifierTests.swift` 并追加本节。双语标题测试改用与 `FileStorageSharingTests.withLanguage` 完全相同的私有辅助方法：`TestPreferenceDomain.make(for: self)` 创建并登记清理临时偏好域，写入语言后经 `TestVolatilePreferences` 覆盖，在 `defer` 中恢复，并断言 `L10n.usesChinese`。中英用途标题的顺序、内容及可回收原因标题非空断言保留，仍为 19 项分类测试。
- 该测试文件已无 `setVolatileDomain`、`argumentDomain` 或 `UserDefaults.standard` 引用；偏好卫生守卫及共用辅助类均未修改。

实际命令（本 worktree；构建参数与前两轮一致）：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --filter 'SpaceMap|TestPreferenceHygieneTests'
```

| 运行 | exit code | 结果 |
| --- | --- | --- |
| `build.log` | 0 | PASS，SwiftPM 报告 8.30 秒；本批 8 个源码/测试文件 0 警告、0 错误。仍有 SwiftPM 用户缓存不可写及 manifest 只读数据库提示。 |
| `test.log` | 1 | FAIL，75 项中 73 通过 / 2 用例失败 / 0 跳过，共 3 条失败断言；SpaceMap 54 项全部通过，卫生测试 19 通过 / 2 失败。原先失败的 `testTestSourcesUseTemporaryDomainsAndDoNotPersistStandardDefaults` 已通过。 |

失败发生在既有卫生用例 `testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`（守卫文件第 308、309 行）和 `testTemporarySuiteCanBeReopenedOnAWorkerThread`（第 324 行）：临时偏好域 `synchronize()` 返回失败，首个用例未生成 plist；日志记录 `sandbox_extension_issue_file failed … defaults.plist: 1 (Operation not permitted)`。当前为 `workspace-write` 沙箱、审批策略 `never`，无法申请扩大权限；未改变测试或绕过沙箱。主会话需在允许偏好持久化的环境执行上面的同一过滤测试，确认 exit 0 后完成验收。

证据目录：`/private/tmp/disktree-p1-round3-d47xy9kv/`。`commands.json` 保存实际参数与环境，`build.exit`、`test.exit` 保存退出码，`verification.json` 保存数量、警告和失败摘要，`round3-code.diff` 保存相对本轮基线的测试差异；`source-checks.json` 记录禁用调用、辅助方法一致性和断言数量检查，`final-review.json` 记录最终哈希、守卫未修改及交接仅追加检查。未调用 JEV 或其他模型，未提交、安装或集成。

## 主会话验收与合入（Claude，2026-10-22）

结论：PASS。三轮 Codex（gpt-6.1-sol，经 `~/.local/bin/magpie-worker` 的 mp-implementer 角色，workspace-write 沙箱）实现，主会话逐行复核、在独立 scratch 构建并跑完整门禁；合入 v2.0.1 时只复制本批新增与修改的文件。未提交、未安装、未运行应用。

**复核意见与处理**

- 第 1 轮后：①“值得一看”会把分析根本身列为发现（分析根按 D46 不能移走，disktree 也只看根的子项）→ 第 2 轮改为从根的子目录开始；②布局用第一项推断当前目录，根层只有余量块时会错 → 第 2 轮改为必传 `rootPath`。
- 第 2 轮后：完整 Debug 测试发现 `SpaceMapPurposeClassifierTests` 直接写 `UserDefaults.argumentDomain`，违反 D48 测试偏好卫生守卫（`TestPreferenceHygieneTests` 失败 1 项）→ 第 3 轮改用仓库已有的 `TestPreferenceDomain`＋`TestVolatilePreferences` 语言切换；第 3 轮在 Codex 沙箱里有 2 个卫生用例因不能写临时 plist 失败，主会话环境下 Debug 与 Release 均通过。

**环境变化（须知）**：门禁进行中 `/Applications/Xcode-27.0.0-Beta.app` 被删除（不是本会话所为），Release 编译因 SDK 头文件消失失败。此后全部门禁改用 `/Applications/Xcode.app`（Xcode 27.1，27A9275，Swift 6.4 swiftlang-6.4.0.34.1）从空 scratch 重跑。`AGENTS.md`、`RULES.md` 和各会话脚本里写死的测试版路径需要另行更新。测试版工具链上的早先记录保存在 `~/Developer/.sc-build/disktree-p1/logs/beta-toolchain/`（Debug 全量 5,527／跳过 27／0 失败）。

**门禁（Xcode 27.1，`~/Developer/.sc-build/disktree-p1/tools/verify-p1.sh`，日志在同目录 `logs/`）**

| 步骤 | exit | 结果 |
| --- | --- | --- |
| 显示受限测试清单 `--check`、私有接口检查、删除与进程清单、视图启动进程与冲突副本守卫 | 0 | PASS（清单 60 进程内／1 进程外／1 豁免；私有接口 9 处登记；删除与进程清单 172 条／264 处） |
| Debug 构建（含测试） | 0 | 新文件 0 警告；全仓 9 处既有警告与基线相同 |
| 定向测试 `SpaceMap|StorageTreemapLayoutTests|StorageMap|FileAnalysisTrash` | 0 | PASS |
| Debug 全量（跳过 61 个显示受限类，D106） | 0 | 5,527 个，跳过 27，0 失败；另 CombinedStatusIcon 285 个与 swift-testing 135 个通过 |
| Release 全量（`-enable-testing`，同样跳过显示受限类） | 0 | 5,275 个，跳过 26，0 失败；CombinedStatusIcon 285 个通过 |
| 严格并发构建（`-strict-concurrency=complete`） | 0 | PASS，新文件 0 警告 |

**反证**：19 处单点变异（`tools/mutate.py`，清单 `mutations-p1.json`，结果 `logs/mutations-p1.txt`），抓到 18 处。唯一存活的 L6（整块匹配项之内继续套用筛选）是等价变异：`keep(forPath:)` 对整块匹配项之下的任何路径本来就返回 `.whole`，那一行只是省掉一次祖先查找。每处变异前后都核对了文件哈希；结束后源码与变异前导出的差异逐字节相同，scratch 已按复原后的源码重建。

**JEV**（`jev_review`，只提交了非敏感的改动摘要和测试摘要）：action `escalate`，safe_to_apply 0.56，composite 0.8395；correctness 1.82／0.74，spec_match 1.93／0.91，test_gap 0.54／0.18，blast_radius 0.98／0.40。低置信度主要在测试缺口和影响范围两项，由上面的变异与完整门禁补证；这不代表批准。

**合入**：第一次合入时 v2.0.1 已经变化：另一个会话合入了 CMM 第三批 J，把 D168、D169 记为别的决定，并正在跑它的门禁和安装。于是 `tools/merge-into-v201.sh` 按设计拒绝执行，本批决定改记为 **D170**。等那边的门禁和安装都结束后，`tools/sync-lane.py` 以 v2.0.1 当时的工作树（内容摘要 `0cf319a4cccc881d`）新建 `~/Developer/sc-worktrees/disktree-p1b`，复制本批 9 个新文件，并把 3 处文档改动重新加到那时的版本上；整体重跑门禁（结果见下节）。之后由 `tools/merge-b.py` 先核对 v2.0.1 仍是这个摘要，再复制改动并备份被覆盖的 3 个文档。

**留给后续各期**

- 第 2 期：方块图视图。在空间地图结果页加“气泡｜方块”切换（默认气泡），用 `SpaceMapTreemapLayout`（`children` 闭包复用同一个 `DiskScanner` 的 `storageMapSnapshot`）、SwiftUI `Canvas` 绘制，加滚轮或捏合放大即进入、成长式过渡和悬停卡片；勾选走现有 `toggleTrashSelection`。会改 `CareStudioSpaceLens.swift`，须与 CMM 会话排期。
- 分类与推荐要在后台任务里算，并支持取消。合成样本（2,000 个目录、20 万项）上分类约 14 ms、推荐约 234 ms；真实家目录的目录比例高得多，第 2 期要用真实规模再测。
- “陈旧实验”与工作树的最老时间需要目录级的最新修改时间，留给第 4 期（批量读目录时顺便记下）。

**合并树门禁（disktree-p1b = v2.0.1 `0cf319a4cccc881d` ＋ 本批，Xcode 27.1，日志 `~/Developer/.sc-build/disktree-p1/logs/p1b-*.log`）**：守卫全部通过；Debug 构建新文件 0 警告；定向测试通过；Debug 全量 5,527 个，跳过 27，0 失败；Release 全量 5,275 个，跳过 26，0 失败；严格并发构建通过，新文件 0 警告。本批源码和测试与 disktree-p1 逐字节相同，未重跑变异。

**交付补丁**：`~/Developer/.sc-build/disktree-p1/delivery/disktree-p1-D170.patch`，基线树和结果树见同目录 `trees.txt`，全部 12 个文件只增不删。对当时最新的 v2.0.1（临时索引，未写工作树）做三方合并检查：只有 `DECISIONS.md` 顶部冲突，原因是两边都在表头下新加了一节；保留两节即可，本节放在最上面。

## 第 4 轮（合入后复核修正）

结论：PASS（本轮定向验收）。在 `/Users/developer/Developer/sc-worktrees/disktree-p1c` 完成五项修正，仅编辑指定的三个源码文件、三个测试文件并追加本节。保留 lane 的原有差异与未知文件；未提交、安装或集成。工具链为 `/Applications/Xcode.app`，Xcode 27.1（27A9275）。

1. **主导用途**（`SpaceMapPurposeClassifier.swift`）：顶层结构目录按不区分大小写的名单停止主导推断，继续继承父用途；其子目录仍按自身规则分类。未知顶层仅沿每层最大的子目录向下查三层，同值按路径升序；候选须有已知名字或裸仓库形状，且达到原顶层字节数的 50%。用带溢出检测的整数乘法判断 `2 * 候选字节 >= 顶层字节`。更新两项既有测试，新增家目录 Library、全部结构名、较小已识别分支、50%／49% 及奇数字节边界、路径同值排序、超大裸仓库等六项测试。
2. **包与 blocked 子树**（同一分类器）：记忆祖先是否属于 blocked 子树，在创建 facts／children 前排除后代，包本身继续应用和继承规则；不再由包内目录推断包用途或产生可回收规则。新增两项测试，覆盖带真实 `package` kind 的 Tool.app、照片图库、普通 blocked 目录及 blocked 分析根；包内有无内容时显式条目数量一致，后代用途／原因等同包本身。共用内存夹具在 `SpaceMapTreemapFilterTests.swift` 增加包路径参数。
3. **饱和累加**（`SpaceMapTreemapFilter.swift`、`SpaceMapTreemapLayout.swift` 及共用夹具）：字节、匹配项数、目录自身加后代项数、部分分支汇总和布局尾部字节使用文件内私有饱和加法，溢出停在 `.max`。新增筛选两项、布局一项测试，覆盖直接匹配与部分祖先中两个 `Int64.max / 2 + 1` 字节项，以及 `Int.max` 后代计数；`maximumChildren: 1` 的 `.others.bytes` 为 `Int64.max`。
4. **外置盘废纸篓**（分类器）：`.trashes` 与 `.trash` 同为缓存用途／废纸篓原因。新增一项测试，验证外置卷 `.Trashes/501` 及其文件继承 `trash`。
5. **同步盘保护**（分类器）：上下文记录名字命中的同步盘边界，并从分析根的路径祖先初始化标记。同步盘内忽略名字和目录表的普通可回收原因，并清除外层继承来的普通原因；`.stversions` 保持同步历史及其向下继承，用途分类继续生效。新增四项测试，覆盖 iCloud 项目依赖、Dropbox 缓存及全部既有同步盘名称、同步历史、外层缓存继承、同步盘内部选为分析根、目录表规则与 `src` 用途。仅由主导推断得到的同步用途不会误抑制其他分支的正常缓存规则。

| 测试类 | 轮前 | 轮后 | 新增 |
| --- | ---: | ---: | ---: |
| `SpaceMapPurposeClassifierTests` | 19 | 32 | 13 |
| `SpaceMapTreemapFilterTests` | 8 | 10 | 2 |
| `SpaceMapTreemapLayoutTests` | 18 | 19 | 1 |
| `SpaceMapInsightsTests`（未修改） | 9 | 9 | 0 |
| 合计 | 54 | 70 | 16 |

实际命令（本 lane）：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --filter 'SpaceMap'
```

| 运行 | exit code | 结果 |
| --- | --- | --- |
| `build.log` | 0 | PASS，构建完成，本轮修改源码／测试 0 警告、0 错误。日志另有 SwiftPM 用户缓存不可写、manifest 只读缓存及 Package.swift 链接重复 rpath 提示，均未指向本轮文件。 |
| `test.log` | 0 | PASS，70 通过／0 失败／0 跳过；CombinedStatusIcon 独立测试包在该过滤条件下执行 0 项。 |

既有 20 万项 Debug 基准随测试执行：分类 12.85 ms、布局（含快照）5.28 ms、推荐 235.08 ms；未新增计时断言，也未更改基准测试或 `.Trash` 推荐行为。

证据目录：`/private/tmp/disktree-p1c-round4-spiv478i/`。`before/` 保存七个文件的轮前副本；`commands.json` 保存命令和环境；`build.exit`、`test.exit` 保存退出码；`verification.json` 保存测试及诊断摘要；`round4-code.diff` 保存六个代码文件相对轮前的差异；`final-review.json` 记录最终哈希、范围和交接仅追加检查。已按 `debugging-and-error-recovery` 与 `code-review-and-quality` 自查；本轮未获 JEV 来源／预算授权，也未发现可调用的 JEV 工具，未调用 JEV 或其他模型。无未解决修正项；完整门禁及集成仍由主会话验收。

## 第 4 轮主会话验收（Claude，2026-10-22）

起因：D170 合入 v2.0.1 后，集成会话请 Grok 做了只读复核，并转来 3 条已核实的 P1 和几条 P2。主会话对照代码复核，三条 P1 都成立：
- `dominantPurpose` 在一层里只要有认得出的子目录就采用；
- 包被走进去量大小，但只记为 blocked、不跳过子项，所以包内目录也在 `index.directories` 里；
- `+=` 溢出会崩溃。

另外采纳两条与安全相关的 P2：外置盘 `.Trashes`；同步盘里不标可回收。“`.Trash` 进值得一看”留到第 3 期再定；基准测试仍不加计时断言。

修正 lane `~/Developer/sc-worktrees/disktree-p1c` 由 v2.0.1 当时的工作树复制而来（内容摘要 `8593ba455f45822f`，树 `5f701312`，已含 D170）。Codex（gpt-6.1-sol）第 4 轮只改了交接里列出的 7 个文件。主会话复核后，用 Xcode 27.1 跑完整门禁（`tools/verify-p1.sh`，日志 `logs/p1c-*.log`）：

| 步骤 | exit | 结果 |
| --- | --- | --- |
| 守卫（显示受限清单、私有接口、删除与进程清单等） | 0 | PASS |
| Debug 构建（含测试） | 0 | 新文件 0 警告 |
| SpaceMap 定向测试 | 0 | 70 个全过（布局 19、筛选 10、分类 32、推荐 9） |
| Debug 全量（跳过 61 个显示受限类） | 0 | 5,557 个，跳过 27，0 失败 |
| Release 全量（`-enable-testing`） | 0 | 5,304 个，跳过 26，0 失败 |
| 严格并发构建 | 0 | PASS，新文件 0 警告 |

反证：针对本轮修正的 9 处单点变异（`mutations-p1c.json`，结果 `logs/mutations-p1c.txt`）全部被测试抓到：去掉过半判断、去掉结构文件夹排除、关闭 blocked 剪枝、同步盘照常给原因、同步标记不下传、忽略分析根本身在同步盘内、去掉 `.Trashes`、筛选和布局改成溢出回绕。每处结束后文件均已复原，并核对过哈希。

JEV（`jev_review`，只提交改动和测试摘要）：action `review`，safe_to_apply 0.74，composite 0.84；correctness 1.95／0.91，spec_match 1.95／0.93，test_gap 0.18／0.71，blast_radius 1.72／0.59。这不代表批准。

交付：基于修正 lane 的基线树出三方补丁，发给集成会话合并，主会话不写 v2.0.1。

## 第 5 轮（同步根、结构目录及零字节推断修正）

结论：A/B/C 修正及定向测试通过。指定原命令均 exit 0；本轮源码与测试 0 编译警告，但原命令有 SwiftPM 沙箱缓存及既有链接警告，不能宣称原命令已达到严格的 0 警告。显式使用本地 SwiftPM 目录后的补充增量构建与测试均 exit 0、0 警告，详见下表。

工作目录仍为 `/Users/developer/Developer/sc-worktrees/disktree-p1c`，工具链为 `/Applications/Xcode.app`，Xcode 27.1（27A9275）。仅修改指定的 `SpaceMapPurposeClassifier.swift`、`SpaceMapPurposeClassifierTests.swift`，并在本交接末尾追加本节；保留原有差异和未知文件，未提交、安装或集成。

1. **A：同步根**：遍历目录与初始化分析根共用同一边界判断：家目录直接子目录且名字用途为 `synced`，或任意位置的 `Mobile Documents`／`CloudStorage`。只有这些边界及其子树抑制普通可回收原因。其他位置的同步名字继续保留用途颜色，并照常计算／继承原因；`.stversions` 仍标同步历史版本，即使外层已有缓存原因。
2. **B：结构目录位置**：家目录直接子目录仅 `library`、`applications`、`developer` 停止主导推断；分析根为 `/` 或 `/Volumes/<名称>` 时，其直接子目录使用指定的 13 个结构名（含 `developer`）。其他位置照常进行原有顶层主导推断。目录自身的名字／裸仓库形状分类继续生效。
3. **C：零字节**：`dominantPurpose` 要求原顶层目录字节数大于 0，避免空目录因 `2 * 候选 >= 0` 得到用途。

分类测试新增 7 项，调整 4 项既有测试，没有删除断言。新增覆盖同步同名项目依赖、`Library/Caches/Dropbox/blobs` 的缓存继承、Library 下两种同步根、分析根位于真实／同名同步目录内、家目录 Developer 过半依赖、家目录与 `/` 下 bin 的裸仓库、完整卷根结构名与其他位置同名目录、零字节目录。同步根和同步历史既有测试继续覆盖全部原有同步名字，并增加根下 `node_modules` 及真正同步根清除外层缓存原因的断言。

与新规则冲突的旧期望调整如下：

- 原结构名单测试把家目录下全部名单都期望为 `other`；现仅 Library、Applications、Developer 为 `other`，其余 System、Users、Private、Volumes、opt、usr、bin、sbin、cores、Network 在 80% Caches 夹具中期望为 `cache`。新增卷根测试保留完整名单的 `other` 断言。
- 原 `/analysis/.cache/Dropbox` 及其 `Cache/data` 期望无原因；它们不是真实同步根，现期望继承 `regenerableCache`。同树 `.stversions/Cache/old` 仍期望 `syncHistory`，新增 `.cache/CloudStorage`、`.cache/Mobile Documents` 仍期望清除继承原因。
- 原目录表抑制测试把注入家目录及分析根都设为 `/analysis/Dropbox/unrecognized`；按新定义，其 Dropbox 祖先不属于这个注入家目录的直接子目录。夹具改为 `/analysis/CloudStorage/Dropbox/unrecognized`，以明确的 CloudStorage 祖先保留所有原抑制断言；另用真实家目录边界单独验证 `/analysis/Dropbox/Work` 与 `/analysis/Projects/Sync` 的相反结果。

| 测试类 | 轮前 | 轮后 | 新增 |
| --- | ---: | ---: | ---: |
| `SpaceMapPurposeClassifierTests` | 32 | 39 | 7 |
| `SpaceMapTreemapFilterTests`（未修改） | 10 | 10 | 0 |
| `SpaceMapTreemapLayoutTests`（未修改） | 19 | 19 | 0 |
| `SpaceMapInsightsTests`（未修改） | 9 | 9 | 0 |
| 合计 | 70 | 77 | 7 |

实际验收命令：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --filter 'SpaceMap'
```

为解决沙箱内 SwiftPM 全局缓存不可写，随后分别在以上两条命令后追加以下参数再运行（同一环境、同一 scratch，增量构建；完整参数记录在 `commands.json`）：

```bash
--cache-path "$PWD/.build/codex/round5-swiftpm/cache" \
--config-path "$PWD/.build/codex/round5-swiftpm/configuration" \
--security-path "$PWD/.build/codex/round5-swiftpm/security"
```

| 日志／运行 | exit code | 结果 |
| --- | --- | --- |
| `build.log`／指定原构建命令 | 0 | 构建成功；本轮源码及测试 0 编译警告。共 6 条环境／链接警告：3 条用户级目录不可写、2 条 manifest 只读缓存、1 条测试包重复 rpath。 |
| `test.log`／指定原测试命令 | 0 | 77 通过／0 失败／0 跳过；5 条 SwiftPM 目录／缓存警告。 |
| `build-local.log`／显式本地 SwiftPM 目录 | 0 | 增量构建成功，0 警告、0 错误（0.53 秒）；此次未重新链接测试包。 |
| `test-local.log`／显式本地 SwiftPM 目录 | 0 | 77 通过／0 失败／0 跳过，0 警告、0 错误。CombinedStatusIcon 独立测试包在本过滤条件下执行 0 项。 |

**验收限制**：原命令严格 0 警告仍受环境与既有链接设置影响。重复 rpath 来自 `Package.swift` 的测试包链接设置（112–116 行），不在本轮允许修改范围；本地增量构建的 0 警告不代表重新链接已消除该提示。建议主会话在集成环境复验原命令，并另行处理该链接设置。

**已知限制**：分析根本身是一个包且未进入 blocked 集合的情况，本轮未处理；实际能否移动仍由 D46 的保护规则决定。

证据目录：`/private/tmp/disktree-p1c-round5-mb2fwizk/`。`before/` 保存三个文件的轮前副本，`round5-code.diff` 为两份代码文件相对轮前差异，`commands.json` 记录全部命令及构建环境，四组 `.log`／`.exit` 保留实际输出和退出码；`verification.json`、`final-review.json` 保存测试、诊断与最终范围核对。按 `debugging-and-error-recovery` 定位并自查；本轮未发现可调用 JEV 工具，也未获 JEV 来源／预算授权，未调用 JEV 或其他模型。

## 第 5 轮主会话验收（Claude，2026-10-22）

起因：集成会话转来 Grok 4.7 对第 4 轮的只读复核。原有的 3 条 P1 和 2 条 P2 均已修好，没有新的 P0、P1；新提两条 P2：①泛名 `sync`、`mega` 在任何位置都会清掉子树的可回收原因，`~/Library/Caches/Dropbox` 也会丢掉继承来的可再生缓存；②结构名单缺 `developer`，而 `bin`、`opt` 等在家目录下又排除得太宽。主会话核实后，第 5 轮只改分类器、它的测试和本交接：
- 同步根只认家目录直接子目录里的同步名字，以及任意位置的 `Mobile Documents`、`CloudStorage`；分析根是否在同步盘内按同一定义判断；
- 结构文件夹分两套：家目录下为 library、applications、developer，卷根下为完整名单；
- 0 字节顶层目录不推断。

验证（Xcode 27.1，lane `disktree-p1c`，日志 `logs/p1c-r5-*.log`）：守卫 PASS；Debug 构建通过，新文件 0 警告；SpaceMap 77 个测试（分类 39）与 `TestPreferenceHygieneTests` 21 个全部通过；严格并发构建通过。变异 5/5 被抓到：同步根按名字在任何位置成立、家目录下不排除 developer、卷根名单用于任意分析根、0 字节照样推断、分析根按任意同步名字判断（`logs/mutations-p1c-r5.txt`）。Debug 和 Release 全量由集成会话在合并后的门禁里一起跑。
