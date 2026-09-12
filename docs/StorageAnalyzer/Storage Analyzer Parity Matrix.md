# Storage Analyzer Parity Matrix

> 2026-08-12 当前验收以本页“当前 Skill 报告复核”为准。后面的 2026-08-11 四轮记录保留为历史证据，不代表当前规则数量。

## 2026-08-12 当前 Skill 报告复核

当前官方 Skill 报告不是旧的 99 个叶子候选口径，而是 10 个用户决策项目：绿色 1、黄色 7、红色 2。旧测试版把同一主项目的子路径和通用扫描分组提升为 7/90/2，项目层级和当前报告不一致。

本轮继续复用现有 `ReadOnlyCleanupScanner`，将 bundled rules 收紧为当前 Skill 报告的 10 个决策项目，并保留 1 个蓝色已安装应用信息规则。修正版连续三轮真实只读扫描结果如下：

| 轮次 | 项目级结果 | 叶子明细 | 默认选择 | 路径/风险/动作差异 | 扫描耗时 |
|---:|---|---|---|---:|---:|
| 1 | 绿 1 / 黄 7 / 红 2 | 绿 2 / 黄 20 / 红 6 | 仅绿色 1 个主项目 | 0 | 76.4 秒 |
| 2 | 绿 1 / 黄 7 / 红 2 | 绿 2 / 黄 20 / 红 6 | 仅绿色 1 个主项目 | 0 | 70.8 秒 |
| 3 | 绿 1 / 黄 7 / 红 2 | 绿 2 / 黄 20 / 红 6 | 仅绿色 1 个主项目 | 0 | 71.4 秒 |

三轮决策路径和状态完全相同。Downloads、Codex 会话等活跃目录在三次扫描间有真实容量变化，因此 JSON 哈希不同；这不是分类漂移，也没有用旧容量冒充实时容量。

与当前 Skill 报告的项目映射：

| 风险 | Skill 主项目 | App 主项目 | 结果 |
|---|---|---|---|
| 绿 | npm 缓存 | `developer.npx-cache` + `developer.npm-content-cache` | 仅精确匹配两个可执行子目录；推荐与默认选择分别记录 |
| 黄 | Downloads、Pictures、微信、Chrome、Codex、ego lite、CrossOver | 7 条对应的版本化规则 | 项目、根路径和只读/手选边界一致 |
| 红 | Xcode 双版本、四个大型创作应用 | 重复 Bundle ID 规则 + 创作应用 Bundle ID 白名单 | 项目和应用路径一致 |

原始 Skill 的红色操作仍是打开审查；按用户明确要求，App 的红色应用默认不选但允许逐项手选，必须双重确认、执行前回读 Bundle ID/身份并只移入废纸篓。这是唯一有意的动作策略差异，不降低扫描与显示匹配结论。

## 对标证据

- 规范来源：[`KKKKhazix/khazix-skills/storage-analyzer`](https://github.com/KKKKhazix/khazix-skills/tree/741eb55ba5acf2050b0e209723c2985e956e4f7c/storage-analyzer)
- 审计 Commit：`741eb55ba5acf2050b0e209723c2985e956e4f7c`（2026-08-11）
- 许可：MIT；本项目复用规则语义，不嵌入该仓库的 Python Server、HTML 或删除实现。
- 读取文件：`SKILL.md`、`references/macos.md`、`references/windows.md`、`scripts/scan.py`、`scripts/build_report.py`、`scripts/server.py`、`assets/report_template.html`
- Skill 目录 SHA-256：`20c449a9302d7aacfce396f642eb74969ed101b8b0abeb7d0f910e701373b129`
- `SKILL.md` SHA-256：`4b41cc77494638ee0f010f5c50b8015e4dff82e522c9184d4bbeba14b776eae4`
- 官方 Git 仓库可核对 Commit；本次以固定 Commit 审计，未来更新必须重新比较规则和安全边界，不能静默跟随远端变化。
- 本矩阵只对标 macOS 规则。Windows 实现明确标注为未经实机验证，不是本 macOS App 的事实来源。

## 解读边界

Skill 的可执行扫描器只输出路径、`du -sk` 容量、分组和权限错误；三级分类由 Agent 阅读当次 JSON 后判断。Skill 没有定义候选 ID、置信度枚举、原因代码枚举、UI 选择存储、默认勾选、重扫选择协调、Alias/APFS Clone 规则或 Golden Fixture。因此这些项不能伪造为“Skill 规定”；App 在未定义处采用 fail-closed 策略，并单独标记。

## 2026-08-11 四轮实机对照（历史口径）

四轮均在同一台开发机上依次运行固定 Commit 的官方 `scan.py` 和 App 的单一只读 Scanner；原始 JSON 保存在本地忽略目录 `artifacts/1.9.10-storage-analyzer-parity/round-{1...4}/`，没有执行删除。

| 轮次 | 本轮目标 | 官方与 App 对照 | 结果 |
|---:|---|---|---|
| 1 | 修复深层目录容量漏算 | Caches、Downloads、Application Support、Containers、Group Containers、Dev Caches 路径集合一致；容量最大偏差 0.89%。Applications 命中 39/40，识别出官方还包含非 `.app` 的 `Setapp` 目录 | 本轮深度目标通过；记录 1 个应用范围差异供第 4 轮处理 |
| 2 | 绿色缓存与性能 | Caches 5/5、Dev Caches 2/2；路径、风险、动作一致，容量偏差 0%；完整原生扫描约 114 秒 | 通过 |
| 3 | 黄色项目与动作边界 | Application Support 34/34、Containers 20/20、Group Containers 11/11、Downloads 14/14；路径一致，容量最大偏差 1.33% | 通过；通用应用数据只允许 Finder 审查，Downloads 仍可明确手选 |
| 4 | 应用信息与红色重复项 | 七个共同决策分组路径全部一致；Applications 40/40；容量最大偏差 0.33%；同 Bundle ID 的 `Xcode.app` 与 `Xcode-27.0.0-Beta.app` 均为 protected；2026-08-12 起按产品要求允许手选、双重确认后移入废纸篓 | 扫描结果对照通过；操作策略有意扩展 |

### 完整 Skill 报告交叉复核（历史叶子口径，已被当前复核取代）

在四轮原始扫描对照后，又按 Skill 的完整流程重新执行：官方 `scan.py` → 阅读 `references/macos.md` → 对重叠分组去重并只读深入个人目录 → 生成 `storage_analysis.json` → 官方 `build_report.py` 生成静态 HTML。随后从已安装 `/Applications/测试版.app` 完成同一磁盘状态的真实扫描，并用 App 的只读 Scanner 导出机器可比快照。

- Skill 分级：绿色 7 项 / 约 4.1 GB，黄色 90 项 / 约 202.5 GB，红色 2 项 / 约 7.0 GB。
- 已安装 App：绿色 7 项 / 4.1 GB，黄色 90 项 / 202.5 GB，红色 2 项 / 7.0 GB；另有 38 个正常应用作为 informational/蓝色容量信息，不进入 Skill 的三灯决策清单。
- 决策路径：Skill 99，App 99，精确交集 99；缺失 0、额外 0。
- 风险、动作、选择资格和默认选择：不一致 0。
- 机器可读证据：`artifacts/1.9.10-storage-analyzer-parity/full-skill/{official-scan.json,official-analysis.json,cross-comparison.json,official-storage-report.html}`（本地忽略目录，不提交包含用户路径的扫描快照）。
- 未启动 Skill 的删除服务，未执行报告中的命令，也未触发 App 清理按钮。

### 四次完整 Skill 独立实跑（历史叶子口径）

用户要求不能只复用 `scan.py` 的原始分组，因此又连续执行四次完整流程。每轮都重新运行官方 `scan.py`、依据 `SKILL.md` 与 `references/macos.md` 重新分级、运行官方 `build_report.py`，再独立运行 App 的只读 Scanner；未复用上一轮扫描 JSON。

| 轮次 | Skill 三灯结果 | App 扫描耗时 | 决策路径 | 风险/动作/选择差异 | 结果 |
|---:|---|---:|---:|---:|---|
| 1 | 绿 7 / 约 4.1 GB；黄 90 / 约 202.5 GB；红 2 / 约 7.0 GB | 105.0 秒 | 99/99 | 0 | 通过 |
| 2 | 绿 7 / 约 4.1 GB；黄 90 / 约 202.5 GB；红 2 / 约 7.0 GB | 109.3 秒 | 99/99 | 0 | 通过 |
| 3 | 绿 7 / 约 4.2 GB；黄 90 / 约 202.5 GB；红 2 / 约 7.0 GB | 104.3 秒 | 99/99 | 0 | 通过 |
| 4 | 绿 7 / 约 4.2 GB；黄 90 / 约 202.5 GB；红 2 / 约 7.0 GB | 105.2 秒 | 99/99 | 0 | 通过 |

每轮机器结果保存在本地忽略目录 `artifacts/1.9.10-storage-analyzer-parity/full-skill-runs/round-{1...4}/`。四轮的 `missing`、`extra` 与 `policyMismatches` 均为空。第 4 轮之后再次从已安装 App 发起扫描时，实时黄色估算变为 202.6 GB；这是后一个磁盘快照的内容变化与一位小数取整，不把旧数值硬编码进 UI。

### 显示逻辑实机复核（历史状态）

- 三灯只呈现存在清理决策的项目；38 个正常应用保留为 informational，并计入磁盘详情中的蓝色“其余已用空间”，不进入绿/黄/红数量。
- 历史测试版曾把绿色 7 个、黄色 90 个叶子候选当作顶层项目显示；当前已改为主项目 1/7/2，叶子只在展开后出现。
- 当前绿色有两个 npm 子项目：`_npx` 推荐且默认选择，`_cacache` 可选且默认不选；黄色和红色主项目默认收起且不选择。
- 当前红色应用可逐项手选，但必须经过增强确认；这取代了历史“红色不可选”状态。
- 磁盘总览、Top 5、扫描覆盖和长期建议继续放在默认折叠的次级详情中；这是本项目已确认的结果页信息层级，不复制 Skill 的 HTML 视觉资源，但风险、动作和处置资格与 Skill 一致。

## 规则矩阵

| # | Skill 规则 | Skill 来源 | 当前 App 行为 | 是否一致 | 目标实现 | 代码位置 | 测试 |
|---:|---|---|---|---|---|---|---|
| 1 | 扫描 home、Library、Caches、Containers、Group Containers、Application Support、Applications、Downloads 和开发缓存 | `SKILL.md` Step 1；`scan.py` `MAC_TARGETS` / `MAC_DEV_CACHE_PATHS` | V2 规则只正式授权 `.npm/_npx` 与 `.npm/_cacache` 两个精确目录；其他已列范围保持人工复核或只定位，Gradle/Maven/Cargo 尚未迁入 V2 | 部分：原生实现有意缩小可执行范围 | 逐条迁移并保持同一 V2 安全链，不把旧扫描分类当作授权 | `Resources/CleanupRules.v2.json` | `testBundledRulesEncodeStorageAnalyzerDecisionTiersWithNativeSafetyGuards` |
| 2 | 通过 `scan.py` 从本机扫描入口开始 | `SKILL.md` Step 1 | 用户从智能扫描 UI 发起，`ScanStore` 异步调用单一 Scanner actor | 语义一致，入口形式不同 | 保留原生 App 入口与只读扫描边界 | `ScanStore.startSmartScan`；`ReadOnlyCleanupScanner.scan` | `testReadOnlyFixtureProducesCategoriesRiskReasonsAndSeparateSpaceTotals` |
| 3 | 普通分组统计根的直接子项；`dev_caches_macos` 把每个预定义开发缓存根当作整体 | `scan.py:du_children/dev_caches_macos` | 规则显式选择 `immediateChildren` 或 `root`，两者共用同一只读汇总、去重、取消和超时链 | 一致，容量实现不同 | 根整体超过 50 MB 时不再因子项各自过小而漏报 | `CleanupRuleCandidateScope`；`ReadOnlyCleanupScanner.scan/aggregateSize` | `testRootCandidateScopeEmitsOneStableSelectableRootAndBuildsPlan` |
| 4 | `expanduser`；执行操作前 `realpath` 并限制在允许根 | `scan.py`；`server.py:expand/do_POST` | 词法标准化 + symlink-aware 边界复核；执行前再校验标准路径 | 一致，App 更严格 | 任何路径变化都 fail closed | `PathSafety`；`CleanPlanBuilder`；`CleanupPreflightService` | `testPathBoundaryUsesComponentsNotStringPrefixes` |
| 5 | 跳过符号链接 | `scan.py:du_children` | 根、子项和递归路径均检查 symlink，不跟随 | 一致 | 保留显式 issue，不默默计入 | `FoundationReadOnlyFileSystem.snapshot`；`aggregateSize` | `testSymbolicLinksAreSkippedWithoutFollowingTarget` |
| 6 | 未定义 Finder Alias | Skill 全部文件无规则 | App 不把 Alias 解析成另一路径，仅按普通文件元数据处理 | Skill 未定义 | 不自行跟随 Alias | `FoundationReadOnlyFileSystem.snapshot` | 矩阵记录；无可提取的 Skill fixture |
| 7 | Applications 的大体积直接子项用于容量决策；正常应用归蓝色，只有可验证的删除决策才归红色 | `macos.md` 关键目录；`SKILL.md` 红灯 | 所有大体积直接子目录作为不可选 informational 候选；相同 Bundle ID 的重复 `.app` 派生为 protected，默认不选，可在双重确认后移入废纸篓 | 产品按用户要求扩展红色操作；App 仍只使用 Bundle ID 证据，不按名称猜测 | 蓝色应用不能进入计划；红色只允许规则验证的重复应用手动进入 | `applications.installed-apps` / `applications.duplicate-installed-apps`；`duplicateApplicationGroups` | `testDuplicateApplicationBundlesBecomeProtectedDecisionItems` |
| 8 | Containers/Group Containers/Application Support 通常是用户数据，归黄灯；未证明安全的通用应用数据只应打开审查 | `macos.md`；`SKILL.md` 黄灯 | 三类根均是 `reviewOnly` + `advisoryOnly` + `forbidden` + `revealOnly` | 一致，App 不允许把整个登录状态/数据库根直接移到废纸篓 | 只能在 Finder 中审查，并使用原应用或卸载器管理 | `user-data.*` rules | bundled rule contract；deep candidate test |
| 9 | 根目录读不到时输出 `denied` | `SKILL.md` Step 1；`scan.py:du_children` | 输出明确 permission report/issue，并将结果标为 partial | 一致，App 信息更结构化 | 不把权限失败显示成空成功 | `permissionStatus`；`ScanIssue` | `testPermissionDenialIsExplicitAndNotReportedAsEmptySuccess` |
| 10 | 仅显式跳过 symlink 和 `.`/`..` | `scan.py:du_children` | 另外支持请求级 excluded roots、规则排除和云端 placeholder；Cargo 只建候选 `registry`/`git`，不把 `bin`/凭据并入可执行根 | App 更严格 | 不因扫描对标扩张删除权限 | `CleanupRule.exclude`；`isExcluded`；`shouldSkipCloudItem` | bundled root/validator assertions |
| 11 | 系统文件/APFS 快照不上灯；应用不建议手删 | `SKILL.md` 红灯；`macos.md` | 规则 allowlist 限制在用户可审查路径和 `/Applications`；系统根不进候选 | 系统边界一致；重复应用操作为产品扩展 | 系统路径始终不可选；仅 `/Applications` 一级重复 `.app` 可手选 | `CleanupRuleValidator.safeAutomaticRoots`；`CleanupSelectionPolicy` | 非安全根验证测试 |
| 12 | 超过阈值的直接子项成为扫描输出 | `scan.py:du_children` | 候选由规则根、类型/后缀、阈值与边界检查共同产生 | 一致，App 更明确 | 所有决策属性由 scanner/model 输出，UI 不重新分类 | `ReadOnlyCleanupScanner.candidate` | Golden snapshot test |
| 13 | 未定义稳定文件身份 | Skill JSON 只有 name/path/size | App ID 由 rule/version/canonical path/volume/device+inode+birthtime 的 SHA-256 派生 | Skill 未定义；App 补齐 UI/安全必需能力 | 排序/渲染不变 ID，身份变化则 ID 变 | `ScanCandidateID.init(stableKey:)` | `testStableCandidateIDChangesWhenFileIdentityChanges` |
| 14 | home/Library/专项分组可交叉输出，未定义去重 | `scan.py` groups | App 按 device+inode+kind 在整次 session 去重 | App 更严格，避免重复容量 | 同一身份只有一个可清理候选 | `seenIdentityKeys` | hard-link/global dedup tests |
| 15 | macOS 容量使用 `du -sk` | `scan.py:du_children/dev_caches_macos` | 优先使用 allocated bytes，不可用时回退 logical bytes，并显式记录 complete/lowerBound/failed | 语义对齐；不保证与 `du` 字节级完全一致 | UI 不能把下界显示成精确值；不完整容量不得执行 | `ScanCandidate.estimatedSizeBytes`；`MeasurementCompleteness` | lower-bound/failed measurement tests |
| 16 | `du -sk` 汇总目录全部内容 | `scan.py` | 规则深度上限提高到 32；候选根执行完整安全校验，后代容量使用只读 `lstat` 快速快照；标准扫描硬上限为 300 秒且可取消 | 对照范围内一致；仍保留有限深度与超时保护 | 容量口径保持“估算”，不冒充物理可释放量 | `aggregateSize`；`aggregateSnapshot`；`CleanupScanRequest.standardMaximumDuration` | deep candidate、symlink、hard-link、timeout tests |
| 17 | Skill 未定义硬链接口径 | 无规则 | App 通过 device+inode 只计一次 | Skill 未定义；App 更安全 | 不重复计入可清理/已选容量 | `FileIdentity.deduplicationKey` | `testHardLinksAreCountedOnceByDeviceAndInode` |
| 18 | APFS 快照归蓝色；未定义 Clone 计费 | `macos.md` | 不扫描快照；Clone 使用 filesystem allocated metadata，不声称物理可回收精确值 | 可执行规则一致；Clone 未定义 | 保留“估算”文案与执行后验证 | scanner system snapshot/report copy | 矩阵记录；无 Skill fixture |
| 19 | 绿=已证明可再生且不丢用户数据；黄=含用户数据或需判断；红=不建议手删 | `SKILL.md` Step 2；`macos.md` | `safe/reviewOnly/protected/informational` 只表达风险；推荐、默认选择和执行资格由独立字段输出 | 语义一致，原生实现更保守 | 颜色不再隐式决定是否默认勾选 | `CleanupRules.v2.json` | tier/rule assertions |
| 20 | 未定义置信度模型 | Agent 根据当次内容判断 | App 暂不伪造数值置信度；使用明确的规则来源和风险级 | Skill 未定义 | 如未来 Skill 增加结构化置信度再对齐 | `sourceRuleID`；`risk` | 矩阵记录 |
| 21 | 需提供原因/处置/风险说明，未定义原因代码 | `SKILL.md` Step 2 | App 以稳定 rule ID/reason key 作原因代码，同时显示中性本地化文案 | 语义一致 | 文案不代替结构化规则 ID | `CleanupRuleCopy`；`ScanCandidate.sourceRuleID` | Golden snapshot reason assertion |
| 22 | 绿灯有操作；黄灯默认只供打开审查，只有已核实安全子路径才可 Trash；红灯原始 Skill 只打开 | `SKILL.md` Step 2/3；`server.py:load` | 绿灯 `selectable`；Downloads/个人文件等黄色为 `selectableWithReview`；通用应用数据黄色为 `reviewRequired`；规则验证的重复应用红色为 `selectableWithProtectedReview`，其余红色仍为 `protected` | 产品按 2026-08-12 用户要求有意扩展红色操作，不再与 Skill 的只打开策略完全一致 | 红色默认不选，仅重复安装 `.app` 可在双重确认后移入废纸篓 | `CleanupSelectionPolicy.eligibility`; `CleanPlanBuilder` | bundled rule contract；protected plan test |
| 23 | 未定义默认勾选 | Skill 没有 selection state/schema | `CleanupDefaultSelection` 独立决定初始选择；optional 绿色可执行但默认不选 | Skill 未定义；App 明确定义 | 黄色和红色仍需记录显式选择，推荐按钮不清掉已主动选择的复核项 | `CleanupDefaultSelection`；`CleanupSelection.defaults/recommended` | default/optional/preserve-review tests |
| 24 | 只有明确可再生且不丢数据的项是绿灯 | `SKILL.md` 绿灯 | App 同时要求 risk、action、executionEligibility、measurementRequirement 和规则版本一致 | 一致，App 更严格 | “安全”“推荐”“默认选择”“允许执行”是四个独立状态 | `CleanupSelectionPolicy`；`CleanPlanBuilder` | eligibility/lower-bound plan tests |
| 25 | 黄灯用 Finder/应用内工具审查 | `SKILL.md` 黄灯 | 通用应用数据只能 Finder 审查；下载和个人文件保留显式手选；Finder 按钮始终是独立操作 | 一致 | 不因风险 Badge 点击而改变选择；可执行黄色项仍需单独确认 | rules + `CleanupCandidateRow`; `CleanupPlanConfirmationSheet` | UI source contract + reviewed-yellow plan test |
| 26 | 红灯不提供删除/卸载 API | `SKILL.md` 红灯；`server.py:load` | 产品有意扩展：只有同 Bundle ID 重复 `.app` 使用 `moveToTrashAfterProtectedReview`；其他红色仍拒绝 | 与 Skill 有意不一致 | 必须显式选择、具备重复 Bundle ID 证据、位于 `/Applications` 一级目录、通过双重确认和执行前复核；只移入废纸篓 | `CleanupSelection`；`CleanPlanBuilder`；`SafeCleanupExecutor` | protected selection/plan/preflight tests |
| 27 | 容量降序，每组最多 40 | `scan.py:du_children` | 使用 measured bytes 降序，路径作稳定 tie-break，每规则保留 40，并记录被截断数量 | 一致，App 增加覆盖率证据 | UI 排序不改变 ID/选择，不能把前 40 项声称为全部 | `candidateSort`；`ScanMetrics.truncatedCandidateCount` | candidate-cap metrics test |
| 28 | 过滤 50 MB 以下；home/Applications 使用 100 MB | `SKILL.md` Step 1；`scan.py:MAC_TARGETS` | `_npx` 为 50 MiB，`_cacache` 为 200 MiB，Applications 为 100 MiB，并保留类型/云端/安全排除 | App 对 npm 内容缓存更保守 | 阈值按 allocated-first 口径 | `CleanupRules.v2.json`；`matches` | bundled threshold assertions |
| 29 | 扫描 JSON 按 groups 分组；报告包含磁盘、Top5、建议和绿黄红决策清单 | `scan.py` schema；`SKILL.md` 报告顺序 | App 按 category/subcategory/tier 建 snapshot；首屏先显示三灯决策清单，磁盘、Top5、覆盖和建议完整保留在默认折叠的次级详情 | 数据与决策层级一致；视觉顺序按本项目结果页要求调整 | 不复制 HTML 布局，也不让技术明细挤占首屏清理决策 | `categories(from:)`；`CleanupScanResultsView` | `testSmartScanResultsPrioritizeDecisionListAndCollapseSecondaryDetails` |
| 30 | 未定义重扫后选择状态 | Skill 无 selection model | App 每个完成的新 session 重置到 Skill-未定义的 fail-closed 默认（空集） | Skill 未定义 | 不将旧 session 授权自动带到新 snapshot | `ScanStore` completion path | default-selection + stable-ID tests |
| 31 | Skill 脚本没有交互取消 | `scan.py` | App task 可取消，返回只包含已完成规则的 cancelled snapshot | App 扩展 | 不留悬挂任务，不发布伪完成 | `Task.isCancelled`；`ScanOutcome.cancelled` | `testCancellationStopsFixtureScanAndReturnsOnlyCompletedReadOnlyResults` |
| 32 | 根权限不足作为 denied 输出 | `SKILL.md` Step 1 | 权限、文件消失、元数据、卷、路径越界和超时产生 partial，仍保留可靠已完成结果 | 一致，App 更完整 | 部分结果必须带 warning | `ScanOutcome.partial`；`ScanIssue` | permission/missing/timeout tests |
| 33 | 读不到的目录需在报告列出 | `SKILL.md` Step 1 | 结构化 issue + permission coverage，不吞错 | 一致 | 错误不影响已验证候选的只读展示 | `CleanupPermissionReport`；`ScanIssueKind` | permission denial test |
| 34 | 扫描输出带 generated_at/system/groups 的 JSON 快照 | `scan.py` 输出 schema | App 使用不可变 `ScanSession`，包含 session ID/rules version/timestamps/categories/issues/metrics/system | 语义一致，类型更严格 | Selection 只引用快照候选 ID | `ScanSession` | Golden snapshot test |
| 35 | 删除必须先停下确认；请求做 realpath/白名单验证 | `SKILL.md` 铁律；`server.py` | 保留更严格链：Snapshot → Selection → Immutable Plan → Preflight → 明确确认 → 身份复核 → Trash/Quarantine → 验证/报告。根候选还在 Plan 构建时校验规则路径后缀和精确父目录 | App 更严格；故意不对齐 Skill 的 green 直接 `rm` | 绝不为达成扫描对标而降低删除安全 | `CleanPlanBuilder`；`CleanupPreflightService`；`CleanupExecutionCoordinator` | `CleanupExecutionSafetyTests`；root-candidate plan test；scan-only gate test |

## 结论

- 当前三轮复核已按 Skill 当前报告对齐 10 个主决策项目：绿色 1、黄色 7、红色 2；项目路径、风险和默认选择无漂移。
- Skill 没有默认选择规则；App 按已确认的产品策略默认选择经过规则验证的绿色候选，黄色和红色默认不选。
- 不声称文件系统字节级完全相等：Skill 使用 `du -sk`，App 使用 allocated bytes，且活跃目录在连续扫描间会变化。Skill 仍由 Agent 即席分类，App 的类型化规则是可测试、fail-closed 的产品化映射。
- 执行安全保持 App 更严格的 Trash/Quarantine 链；不实现 Skill 本地网页中的直接 `rm`。
