# r3-rules-provenance：规则来源、有效指纹与 AI 工具缓存

批次：R3-4 / D82、R3-7 / D83。工作区 `/Users/developer/Developer/sc-worktrees/r3-rules-provenance`，分支 `task/r3-rules-provenance`，基线 `52f722aca8b735904c21c542b13bb501d4e5de99`。初始工作区干净。本轮 `.git` 只读，使用 scratch `prepared/` 交付；未提交、合并、安装、启动 App 或在真实文件上执行清理。

## 实现与边界

- `CleanupRuleProvenance.swift` 定义三个来源、修订、固定核对日期、可空的适用条件、中文处理影响与证据链接。适用条件只接受 `applicationBundleIdentifier`、依赖 Bundle ID 的 `minimumApplicationVersion`；当前为空，作为维护说明，不新增匹配过滤。加载时检查元数据和 JSON 来源；维护测试对照仓库快照检查重复 ID、缺少影响、无效条件（仅格式校验，不核对本机应用或版本）、日期与修订回退／未递增、基线快照格式。
- 指纹对合并后的全部规则做 SHA-256（修复轮 1 起顶层规则顺序参与哈希，见文末）：对象键、规则及集合数组顺序、Unicode NFC、已有可选字段的有效默认值规范化；包含所有规则和维护字段、规则 schema，排除描述性 `rulesVersion`。单条内容哈希只排除修订号，以便判断是否需要递增。核对日期表示本轮模型与路径边界核对，未冒称逐应用实机重建验证。JSON 版本标签仍为 `2026.10.07.1`，不再单独承担追溯责任。
- 合并后 **79 条规则**，仓库基线保存 **73 条集成基线规则的原始匹配／选择字段**与当前 79 条的修订／内容哈希。VS Code 日志证据从继承层修正到实际定义层时修订增加到 2，其余当前规则修订为 1。首轮有效指纹为 `8f7cc8dbddff32be5ccacb73145bbfee08b4799829c803ff69e91dc0ee96e02f`（指纹 schema 1，已被修复轮 1 的 schema 2 取代，见文末）；独立只读快照工具的输出见 scratch `current-provenance.json`，实际加载和基线检查由产品测试覆盖。
- `ScanSession`、候选行、`CleanPlan`、`CleanReport` 记录完整规则集指纹与规则引用，计划／回执行另存本项规则修订。相同版本标签下内容改变，构建计划与执行前检查会拒绝旧计划；错误回执也保留原指纹。事件追加／冷重放、未知移动状态修复保留这些字段，并拒绝同一回执链中变更指纹或修订。旧回执解码为未知（nil），不补猜旧指纹。
- 限定扫描保留完整已加载规则集的指纹。结果行提供 `applicationOwnershipText`、`cleanupImpactText`、`preselectionExplanationText`。未改任何视图；视图批次使用这些字段接入三段说明。
- 必要的跨文件数据透传涉及 `CleanupExecutionModels.swift`、`SafeCleanupExecutor.swift`、`CleanupReportJournal.swift`、`CleanupJournalEvents.swift`，以及 `SmartScanReadOperation.swift` 的一处参数透传：空候选的智能扫描包装也不能丢失扫描指纹。`ScanStore.swift`、`Views/**`、`Features/AppUpdates/**`、菜单栏源码均未改。仅健康扫描没有应用清理规则，因此保持未知追溯值。

原 73 条规则的匹配路径、风险字段、预选字段与执行资格未变（首轮的保护名单扩大曾让 npx/uv 等原规则整行被隐藏，与此句不符，已在修复轮 1 改正）；迁移测试在原尺寸门槛上生成隔离夹具，比较候选 ID、规则 ID、风险、选择资格与默认选择，均通过。D19/D23/D24/D47/D52 保留。D83 另外要求保护混合缓存内的个人状态：原 Playwright 等规则字段保留，但含持久状态标记的整个候选目录安全跳过，这属于明确的防误伤补强；该补强只作用于 D83 新规则与两条 Playwright 规则。

## 本机只读调查与再生性证据

2026-10-12 仅使用目录 `ls`、`stat`、`du -sh` 观察结构和大小；不读文件内容、不打开凭证／会话／对话，不进入个人状态或模型目录、不启动工具验证重建。`du` 只用于候选缓存／日志根；未知个人数据根不测量其内部内容。证据在 scratch `ai-directory-audit.json`、`ai-directory-audit-candidates.json`、`ai-directory-audit-additional.json`；个人状态条目名称已脱敏。大小是目录观察，不代表可清理字节或已完成扫描。

新增六条规则采用精确的直接子目录，不扫描应用数据根：

| 规则 / 工具 | 家目录下路径及本机大小 | 证据与策略 |
|---|---|---|
| `developer.claude-desktop-web-cache` / Claude 桌面 | `Library/Application Support/Claude/{Cache,Code Cache,GPUCache}`：198M / 141M / 1.6M | [Electron 应用数据路径](https://www.electronjs.org/docs/latest/api/app#appgetpathname)、[生成代码缓存与清缓存 API](https://www.electronjs.org/docs/latest/api/session#sesclearcache)与本机生成目录一致；检查已有 Claude Bundle ID；按 D52 活动分档 |
| `developer.codex-desktop-web-cache` / Codex 桌面 | `Library/Application Support/Codex/{Cache,Code Cache,GPUCache}`：25M / 16K / 548K | 同一 Electron 运行时证据；检查 `com.openai.codex`；按 D52 活动分档 |
| `developer.vscode-web-cache` / VS Code（含 Copilot） | `Library/Application Support/Code/{Cache,Code Cache,GPUCache}`：64K / 16K / 548K | 同一运行时证据；检查 `com.microsoft.VSCode`；共享宿主缓存不冒称 Copilot 独占；按 D52 活动分档 |
| `developer.vscode-logs` / VS Code（含 Copilot） | `Library/Application Support/Code/logs`：52K | [VS Code 官方环境服务](https://github.com/microsoft/vscode/blob/main/src/vs/platform/environment/common/environmentService.ts)将日志与 `User/History`、`workspaceStorage` 分开；沿用 D47 日志策略，应用运行不预选 |
| `developer.lmstudio-web-cache` / LM Studio | `Library/Application Support/LM Studio/{Cache,Code Cache,GPUCache}`：0B / 16K / 548K | 仅运行时生成界面缓存，平台文档与目录布局一致；Bundle ID 本轮没有核实，按已有命令行缓存的活动及执行前写入检查；不纳入模型目录 |
| `developer.rod-browser-downloads` / Rod 浏览器工具 | `.cache/rod/browser`：287M | [Rod 官方下载器实现](https://github.com/go-rod/rod/blob/main/lib/launcher/browser.go)定义浏览器下载目录，缺失二进制时下载；只涵盖下载根，不涵盖自定义用户 profile；按 D52 活动分档 |

上述 Electron 判断是官方运行时行为与本机目录结构的推断，未取得逐应用删除后重建的实机证据。缓存维持既有开发工具活动策略：近期为红、超过阈值至一年为黄、超过一年为绿，只有绿预选。日志维持 D47，近期时间本身不降级。六条规则的门槛均为 64 KiB；目录小于门槛不会因本轮规则出现候选。

其他工具与候选路径逐项处理如下，不按猜测扩展规则：

| 工具 / 候选 | 观察与处理 |
|---|---|
| Claude Code | `.claude/cache` 1.1M，`Library/Caches/claude-cli-nodejs` 20M；`.claude/logs` 未观察到。现有精确规则保留，未找到足以新增其他路径的厂商缓存再生说明；`.claude` 的会话、项目、历史、配置不进入缓存规则。`Library/Logs/Claude` 4.2M 保留原规则归属，本轮不凭目录名重新认定桌面／CLI 日志归属。 |
| Codex CLI 与既有桌面规则 | `.codex/cache` 45M、`Library/Caches/com.openai.codex` 160K、`Library/Logs/com.openai.codex` 153M；`.codex/log` 未观察到。原规则和归属保留；会话、归档、配置、认证、shell 快照与状态数据库受保护。 |
| Cursor | `Library/Application Support/Cursor` 存在，`Code Cache` 16K；已有 Cache/CachedData/Code Cache/GPUCache 与日志精确规则，避免重复新增。User、Backups、工作区与持久浏览器存储不纳入。 |
| Windsurf | `Library/Application Support/Windsurf`、`.codeium/windsurf` 未观察到；保留旧日志规则，不新增未经证明的缓存根。未取得可靠的厂商再生路径说明。 |
| VS Code Copilot | 单独的 `.cache/github-copilot`、`Library/Caches/GitHub Copilot`、`Library/Logs/GitHub Copilot` 未观察到；已有规则保留，新规则使用 VS Code 宿主归组，不扫描 `User/globalStorage` 或 `workspaceStorage`。 |
| ChatGPT | `Library/Application Support/com.openai.chat` 与 `Library/Group Containers/group.com.openai.chat` 存在，并有明显的对话／任务／项目／草稿状态目录；只列根目录，不进入。常见 Cache／Logs 猜测路径未观察到，未找到原生应用缓存再生证据，故无新规则。 |
| OpenCode | `.cache/opencode` 5M、`.local/share/opencode/log` 4K；现有规则保留，未扩展到项目状态或对话数据。 |
| Ollama | `.ollama`、`.ollama/logs`、常见 Library Caches／Logs 路径未观察到。官方 [macOS 说明](https://github.com/ollama/ollama/blob/main/docs/macos.mdx)区分日志与模型／配置，不能据此把模型或配置纳入；无新规则。 |
| LM Studio 模型与其他缓存 | `.lmstudio`、`.cache/lm-studio`、常见 Library Caches 根未观察到；[官方模型下载说明](https://lmstudio.ai/docs/app/basics/download-model)及[本地模型列表](https://lmstudio.ai/docs/cli/local-models/ls)用于确认模型属于保留数据，不作为清理目标。 |
| Playwright / Chromium 下载 | `Library/Caches/ms-playwright` 557M、`ms-playwright-go` 0B，已有规则保留；[官方浏览器文档](https://playwright.dev/docs/browsers)证明下载二进制可重新安装。 |
| Playwright MCP 持久浏览器配置 | `Library/Caches/ms-playwright-mcp` 41M，直接子目录包含 MCP profile。官方 [user-profile 说明](https://github.com/microsoft/playwright-mcp#user-profile)明确持久配置保留登录状态，且可位于 `ms-playwright/mcp-*`；含此状态时整个候选安全跳过。本轮不向 profile 内提取缓存，不声称该 41M 全部可清理。 |
| 其他 MCP 服务 | 没有通用 MCP 状态根规则。只有已知 Playwright 浏览器下载根和 Rod 下载根具备可再下载证据；自定义路径、服务配置、鉴权、工具会话和状态不纳入。 |

保护通过元数据名称识别，覆盖 sessions／archived_sessions、检查点／历史／项目、配置／凭证、Local Storage／IndexedDB／Cookies、`mcp-*`、模型目录与模型文件扩展名；不读取这些文件内容。混合目录安全跳过、符号链接不跟随、文件身份去重沿用原实现。修复轮 1 起，这组名称只对 6 条 D83 规则与 2 条 Playwright 规则生效，执行前由单独的名称复查拒绝扫描后新出现的标记（含日志规则）；其他开发缓存的活动遍历恢复基线行为。本轮没有读取或复制腾讯柠檬的代码／规则文本；静态报告只用于确认功能思路。

## 测试与实际验证

新增 `CleanupRuleProvenanceTests` 10 项、`AICleanupRuleSafetyTests` 7 项。公共夹具 `CleanupRuleTestFixtures.swift` 位于 Debug／Release 共用范围，无 `#if DEBUG`。纯扫描用项目所有权登记的临时目录；落盘与执行相关夹具用 `makeOperationHome`，未把家目录操作夹具迁到 temp、未放宽产品路径安全检查。扫描夹具复用既有注入方式，只排除不可读系统祖先的干扰，夹具内真实符号链接仍检查；规范化 `/var` 与 `/private/var` 别名后计算相对路径。

唯一改写的旧断言：`CleanupRuleScannerTests.testBundledRulesEncodeStorageAnalyzerDecisionTiersWithNativeSafetyGuards` 的工具集合追加 `.claudeDesktop`、`.visualStudioCode`、`.lmStudio`、`.rodBrowser`，依据 D83。没有删断言、改风险／选择期望、降低尺寸／时间门槛或新增跳过。

| 检查 | 实际结果 |
|---|---|
| Debug `--build-tests` | PASS，exit 0；最终日志 `logs/debug-build-final.log` |
| Release 默认调试符号命令 | BLOCKED／命令 exit 1；`MemoryFixtureApp.dSYM` 的 `GenerateDSYMFile` 返回 `Operation not permitted`，见 `logs/release-build.log` |
| Release 加 `-debug-info-format none`，保留 `-c release --build-tests -Xswiftc -enable-testing` | PASS，exit 0（最终编译 3107.15 秒）；日志 `logs/release-build-no-dsym-final.log`。这是 SwiftPM 官方选项，省略调试符号生成，不改变 Release 优化或 enable-testing；不将 dSYM 步骤算作通过 |
| Debug 新增两类最终定向 | 17 项，15 PASS、2 BLOCKED，exit 1；`logs/new-rule-tests-final.log` |
| Release 新增两类定向 | 17 项，15 PASS、2 BLOCKED，exit 1；日志 `logs/new-rule-tests-release.log` |
| `targeted-classes.txt` 的 22 个筛选项（21 个 XCTest 类实际执行） | 348 项，266 PASS、79 个用例失败、3 个原有可选用例跳过；共 80 条失败断言，exit 1；`logs/targeted-debug-tests.log`，逐项归类 `targeted-debug-results.json` |
| 其中 UI 一致性 | 46 项 PASS |
| 其中 TestPreferenceHygiene | 21 项：19 用例 PASS，2 用例在临时 plist 的 sandbox extension 被 EPERM 拒绝（3 条断言失败）；源码偏好守卫通过 |
| JSON／基线、`git diff --check`、private API 守卫 | PASS；private API 守卫仍为 7 项 allowlisted uses；最终文件／补丁哈希及静态记录在 `prepared/static-checks.json` |
| 全量、反证、严格并发单独门禁、App/UI smoke、安装、提交、合并 | NOT RUN，按共同要求留主会话；未执行真实清理 |
| JEV | BLOCKED：`jev_decide` 请求被 MCP 审批策略拒绝，提示 requires approval 而 policy 为 never；未取得模型执行或判断结果，不声称 JEV 复核通过 |

348 项中 77 个失败用例包含明确 `Operation not permitted`：家目录夹具创建／删除或 CFPreferences 临时 plist 的 sandbox extension 被拒。涉及 `AICleanupRuleSafetyTests`、`CleanupRuleProvenanceTests`、`CleanupExecutionSafetyTests`、`CleanupJournalEventTests`、`CleanupRuleScannerTests`、`CleanupSafetyTests`、`CleanupStoreFollowUpTests`、`RecordedCleanupRecoveryTests`、`SmartScanHistoryTests`、`SmartScanScopeTests`、`TestPreferenceHygieneTests`。另两项保留 FAIL，不能仅凭环境推断为通过：

- `CleanupExecutionSafetyTests.testJournalReloadRetainsIdentityAndRejectsChangedIntent`：家目录操作夹具初始化／移除报 Cocoa 4 / ENOENT，非明确 EPERM。
- `CleanupSafetyTests.testCleanupRejectsCandidateReplacedBySymbolicLinkAfterScan`：家目录操作夹具初始化／移除报 Cocoa 4 / ENOENT，非明确 EPERM。

本轮新增的两项 BLOCKED 为 `AICleanupRuleSafetyTests.testWritesAfterScanAreRejectedForNewAICaches`、`CleanupRuleProvenanceTests.testJournalEventsPreserveAndRefuseChangesToProvenance`；后一项包含实际冷重放及规则修订／指纹不可变检查，须沙箱外验证。

`CleanupTrashItemIntegrationTests` 位于 `#if STORAGE_CLEANER_RC_TRASH_INTEGRATION`，需要专门的可丢弃 APFS 卷夹具与构建标志，本轮未启用，状态 NOT RUN；不能把筛选名单中包含它等同于执行。三个跳过来自原有 opt-in 条件：两项真实 home 扫描和二万文件计时。未设置其环境变量，未跑真实 home 扫描，未调整性能阈值。

## 主会话复跑与提交

先在权限允许的环境复跑以下命令；通过后才能使用准备脚本。离线依赖已从指定 r2 scratch 复制到本批独立 debug／release scratch。不要修改 HOME 或去掉产品路径检查来处理夹具失败。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
S=/Users/developer/Developer/.sc-build/r3-rules-provenance
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$S/debug" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter "$(paste -sd '|' "$S/targeted-classes.txt")"
swift build --disable-sandbox -Xswiftc -disable-sandbox --scratch-path "$S/release" --skip-update --disable-automatic-resolution --manifest-cache local --jobs 4 -c release --build-tests -Xswiftc -enable-testing
```

独立完整门禁仍由主会话按项目规则执行：`script/verify.sh`，设 `STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0` 与本批私有 `STORAGE_CLEANER_VERIFY_ROOT`。本轮没有把定向结果替代全量或实机验收。

反证规格在 scratch `counterexamples.json`，**15 个案例，NOT RUN**。主会话先确认绿，再在隔离副本一次只做一个退化：版本标签替代有效内容、取消规范排序、移除修订／影响／适用字段守卫、丢失计划／回执／智能扫描字段、允许回执修改追溯、取消持久数据保护／符号链接／去重／写入复查；对应类应红。运行与结果记录后恢复原文件并验证哈希，临时反证构建用完删除。

`prepared/` 分三组：规则模型与 AI 安全；计划／回执／空智能扫描透传；测试与文档。包含 `all.patch`、逐组提交说明、基线／分支／最终文件与产物 SHA-256 的 `manifest.json`、`static-checks.json`、`commit-prepared.py`。脚本 `--check` 仅做读取与补丁 dry-run；`--validated` 由主会话完成复跑、反证和复核后明确使用，按序创建提交，不运行 App、不安装、不 push。脚本发现基线、分支、工作区文件、补丁、暂存区或额外改动不匹配即停止。本轮未执行提交。

后续规则维护先对照已接受快照递增修订；禁止直接覆盖旧内容哈希来掩盖漏增修订。更新快照须和实际内容变更／修订共同复核。新增适用字段先定义并验证其 schema；其成为匹配条件需要新的产品决定。LM Studio Bundle ID、逐应用实际重建以及原生 ChatGPT 缓存证据仍未验证，当前不补猜。

## 修复轮 1（Claude 子代理，2026-10-12）

Codex 不可用，本轮由 Claude 子代理在同一工作区直接修改，未提交、未 `git add`，未启动 App，未扫描或删除真实文件。编译与测试只用 scratch `codex-debug`；反证在源码隔离副本 `claude-mutation-src` 中逐条进行，避免主会话全量测试读到临时退化的源码。**`prepared/` 下的 Codex 补丁、manifest 与 `commit-prepared.py` 已过期，不能再用**；主会话直接从工作区提交。

| 复核项 | 修改 |
|---|---|
| P1-1 保护名单扩大误隐藏原规则 | `isProtectedDataFolder` 恢复为基线 `52f722ac` 原样。AI 状态名称标记改为规则级开关 `CleanupProtectedContentPolicy.persistentAgentStateRuleIDs`（6 条 D83 规则＋`developer.playwright-browsers`、`developer.playwright-mcp-cache`），只在这些规则的测量递归与整行判定中生效。开关属代码策略（与名称表相同），不改变规则内容哈希与基线快照。npx、uv、pip、Yarn、pnpm、用户缓存等原规则恢复基线语义。 |
| P2-1 执行前复查 | 删除首轮加在通用活动遍历里的名称判断（它也会误伤 npx 等原规则的执行）。新增 `persistentAgentStateSkipReason`：只对上述 8 条规则、包括无活动复查的日志规则（如 `developer.vscode-logs`），按扫描相同深度、不跟随链接、跳过排除项，只看名称与类型，扫描后出现保护标记即 `candidateBecameActive` 跳过。说明：这里的“浅层”指只读名称、不读内容，深度与扫描一致。 |
| P2-2 指纹与规则顺序 | 规则内部集合仍排序，顶层 `rules` 保留原顺序参与哈希，指纹 schema 升为 2。全部 79 条规则的当前有效指纹为 `bcecb76512bb90d20592b81fb3a0c52a592d3f0526a8f39cf74bf8c8c6e03666`（来自测试输出；`current-provenance.json` 仍是首轮 schema 1 的结果，已过期）。 |
| P2-3 失效条件 | 采用“如实改为格式校验”：适用条件只校验字段名、Bundle ID 与版本号格式，不核对本机应用或版本；DECISIONS D82、`docs/cleanup-rules.md` 与本文同步措辞。补 `revisionRegressed`、`invalidBaseline`（schema、重复条目、修订 0、哈希长度）测试。 |
| P2-4 计划指纹放行 | 规则带维护元数据时，候选必须带本项修订且指纹等于当前有效指纹；会话缺指纹只在无候选（仅健康扫描、空智能扫描）或活动规则全无维护元数据（合成夹具）时放行。旧 `CleanupWriteRecheckTests` 夹具用产品规则手工构造候选，按扫描器实际行为补上修订与指纹（夹具真实性修正，未改断言）。 |

新增测试（均在已有类内，`targeted-classes.txt` 无需追加）：`AICleanupRuleSafetyTests` 的 `testAgentStateMarkersApplyOnlyToD83AIAndPlaywrightRules`、`testPackageCachesWithConfigModelAndMCPNamedFoldersStayListedWithBaselineSelection`（npx 夹具含 `node_modules/x/config`、`.../integrations/mcp-server` 等，uv 夹具含 `site-packages/pkg/models`、`*.pt`、`*.onnx` 等；两行仍列出、选择与无标记对照一致、npx 仍预选；同类名称在 Claude 缓存深处仍隐藏）、`testAgentStateAppearingAfterScanBlocksAILogRowBeforeExecution`；`CleanupRuleProvenanceTests` 的 `testRevisionRegressionAndInvalidBaselineAreRejected`、`testPlanRequiresFingerprintOnRuleScanRowsAndAllowsOnlyEmptySessionsWithout`。`testFingerprintIsIndependentOfOrderingAndDescriptiveVersion` 按 P2-2 改名为 `testFingerprintKeepsRuleOrderButNormalizesCollectionsAndIgnoresDescriptiveVersion`，断言改为“顶层顺序改变指纹、内部集合顺序与版本标签不改变”；这是本批新测试，未动集成基线的旧断言。

| 检查（scratch `codex-debug`，`--disable-sandbox`） | 结果 |
|---|---|
| Debug `--build-tests` | PASS，日志 `logs/claude-fix1-build-final.log` |
| `targeted-classes.txt` 定向 | PASS：353 项，0 失败，3 项原有 opt-in 跳过；`logs/claude-fix1-targeted-final.log` |
| 额外受 P2-4 影响面：FeatureLightfieldContract、ItemListAndDuplicatePresentation、MemoryCoordinator、MiniWindowCleanupPresentation、SystemUtilitySafety | PASS：297 项，0 失败，1 跳过；`logs/claude-fix1-extra.log` |
| 主会话全量中的非本批失败单独重跑 | `FileAnalysisTrashCostTests.testARowsRuleCheckFoldsOnlyItsOwnPath` 单跑 PASS（主会话已在不含本批的 r2-update-all 复现，判为基线问题）；`NetworkPathPreflightTests` 两项单跑 PASS；`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits` 单跑仍 FAIL（`BenchmarkKernelError` 2，约 15 秒，当时 load average 约 19–47），与规则代码无关，疑为高负载计时问题，需低负载复跑 |
| `git diff --check` | PASS |
| 全量、Release、严格并发门禁 | NOT RUN（留主会话） |

反证：`mutations.json` 更新为 28 条（首轮 20 条，原文件备份 `mutations.pre-claude-fix1.json`），全部 `before` 出现次数经 python 校验与 `expected_occurrences` 一致。修改了 2 条首轮配方的 `before`（`D82-json-label-only`、`D82-plan-fingerprint-check`），两条的过滤器随测试改名更新。新增 8 条 `R1-*`：P1-1 三条（标记作用于所有规则；并回 `isProtectedDataFolder`；作用范围清空）、P2-1 一条、P2-2 一条、P2-3 一条、P2-4 两条（候选级、会话级）。在隔离副本中逐条应用→构建→跑过滤器→恢复：8 条新配方及 4 条相关旧配方（`D82-json-label-only`、`D82-plan-fingerprint-check`、`D82-no-array-normalization`、`D83-persistent-agent-markers`）**12/12 均构建成功且测试失败**；结果 `logs/claude-fix1-mutations/results.json`。恢复后副本与工作区 `Sources`/`Tests` 逐文件一致，再从工作区重建并复跑定向，全部通过。其余 16 条首轮配方的 `before` 仍有效，但本轮未执行。

残余：AI 规则执行前多一次仅元数据的目录遍历（Playwright 浏览器下载等目录较大时多一次遍历）；规则 ID 开关不进入指纹，以后改变该集合需同时复核 D83 与反证；LM Studio Bundle ID、逐应用实机重建仍未验证。
