# 清理规则（2.0.0 第二轮，DECISIONS D19、D22–D25、D47）

智能扫描、安全清理、开发工具与产物三个结果页共用唯一的只读扫描器 `ReadOnlyCleanupScanner`。规则来自三处：`Resources/CleanupRules.v2.json`、`Models/CleanupCoverageCatalog.swift`（精确路径的浏览器、应用缓存与日志，CloudKit、邮件附件副本、废纸篓）、`Models/CleanupScanModels.swift` 中的 `DeveloperToolArtifactCatalog`（开发工具缓存与日志）。规则以官方 [`storage-analyzer`](https://github.com/KKKKhazix/khazix-skills/tree/741eb55ba5acf2050b0e209723c2985e956e4f7c/storage-analyzer) 的只读扫描为起点，处置使用本应用更严格的安全链。

## 验收口径（D19）

- 结果页列出的每一项都能勾选、能处理：除“清空废纸篓”外都只移入废纸篓，可恢复。
- 不能满足的项目不进入结果列表，只在“部分范围已因安全边界跳过（N 项无法安全处理，未列出；其中……）”的说明和“安全跳过”卡的“未列出”里计数（`ScanMetrics.notActionableCandidateCount`）。目前有四种情况，各有原因记录：
  - 项目根目录本身无法列出（容量“无法计算”，`candidateNotActionable`）。大小未知，所以不受单列阈值影响，低于阈值也同样计数；
  - 开发缓存的最近修改时间完全不可用（`candidateNotActionable`）；
  - 项目内含用户排除的路径（`candidateContainsExcludedPath`，计入 `excludedPathCandidateCount`）：执行时一定会因“用户排除”跳过，因此扫描就不列出、不测量；废纸篓里含排除路径的项目不冻结；
  - 项目内含 IDE 本地历史等个人数据（`candidateContainsProtectedData`，计入 `protectedDataCandidateCount`），见下方“本地历史”。
- 重复应用副本组内不能处理的副本也按第一种计数。
- 风险卡的数值与项目数、扫描进度页的“候选大小”只统计可清理的项目；“清空废纸篓”单独显示和计数，不进入三张风险卡。
- 不可再生的个人数据和应用本体不列入垃圾结果，只在“文件分析”里作为空间占用出现；删除应用走“卸载”页。

## 规则表

| 类别 | 规则 | 风险 | 可选 | 默认预选（D47） | 说明 |
|---|---|---|---|---|---|
| `~/Library/Caches` 下各应用缓存 | `system.user-caches`（按应用分行） | 绿 | 是 | 是，所属应用正在运行的行除外；识别不出所属应用的行也预选，行内注明 | 已被更具体规则列出的路径不重复列出，见下方排除清单 |
| 浏览器缓存（Chrome、Safari、Edge、Brave、Firefox、Arc） | `browser-cache.*` | 绿 | 是 | 是，所属浏览器正在运行时除外 | 执行前浏览器仍在运行则跳过 |
| 应用缓存（WhatsApp、Codex、ego lite、Typeless、Zoom） | `application-cache.*` | 绿 | 是 | 是，所属应用正在运行时除外 | 同上 |
| 用户日志 | `system.user-logs`（按来源分行） | 绿 | 是 | 是，所属应用（能识别时）正在运行的行除外；7 天内仍有写入的也预选，行内注明 | `DiagnosticReports` 视为无所属应用 |
| 诊断日志 | `system-log.diagnostics` | 绿 | 是 | 是（无所属应用）；7 天内仍有写入的行内注明 | |
| Codex 应用日志 | `application-log.codex` | 绿 | 是 | 是，Codex 正在运行时除外 | |
| 开发工具日志（9 类） | `developer.*-logs` | 绿 | 是 | 是，所属应用正在运行时除外 | 不按活动时间分级；WorkBuddy 只列 `logs`、`traces`，`audit-log` 是审计记录，不列 |
| 开发缓存与临时文件 | `developer.*`（npm、Homebrew、uv、Xcode DerivedData、pip、SwiftPM、Clang、Bun、Playwright MCP 与各 AI 工具缓存；D47 补充起还有 `~/Library/Caches` 下的 Go 构建缓存 go-build、gopls、golangci-lint、Playwright 浏览器 ms-playwright／ms-playwright-go、pnpm、Yarn、node-gyp、TypeScript、Deno、Electron／electron-builder、Cypress、Poetry、CocoaPods、Carthage、sccache、Flutter 引擎、Claude Code 命令行缓存 claude-cli-nodejs；D101 G10 起还有 Bun 安装缓存 `~/.bun/install/cache`，`~/.bun` 下其他内容不列出） | 按活动时间：超过一年绿、超过阈值黄、阈值内红 | 是 | 绿色档（超过一年）预选，所属应用正在运行时除外；D101 G10 起，G1 行内提示共享且保守预计释放不到 1 MiB 或不到列出大小十分之一的也不预选；黄、红不预选 | 部分内容无法读取时为红色、可选、不预选 |
| CloudKit 缓存 | `system-cache.cloudkit` | 黄 | 是 | 否（需判断） | |
| 邮件附件副本（Mail Downloads） | `mail.downloaded-attachments` | 黄 | 是 | 否（需判断） | 打开附件时系统另存的副本；需先退出“邮件” |
| 下载目录安装包、大项目 | `downloads.installers`、`downloads.large-items` | 黄 | 是 | 否（需判断） | |
| iStat Menus 历史记录（Setapp 版） | `user-data.istat-menus-setapp-history` | 黄 | 是 | 否（需判断） | D101 G7：只列本机核实过的 `~/Library/Application Support/iStat Menus 7 (Setapp)/history` 整个文件夹，移入废纸篓后历史图表清空；主程序、辅助程序、history 服务、菜单栏程序任一在运行则跳过 |
| 重复安装的应用副本 | `applications.duplicate-installed-apps` | 红 | 是 | 否 | 应用标识、版本、构建号都相同才算；整组勾选时自动保留一份，见下文 |
| 清空废纸篓 | `trash.user-trash` | 红（单独一节） | 是 | 否 | 不可恢复，执行前单独二次确认，见下文 |
| 照片图库、微信、Chrome 用户数据、Codex 等会话与检查点（含 `~/.codex/.tmp`）、ego lite、CrossOver、邮件库内附件 | — | — | — | — | 已移出垃圾结果（D19、D24） |
| 大型创作应用、已安装应用 | — | — | — | — | 已移出垃圾结果，删应用走“卸载”页（D25） |

规则校验器同时保证：内置规则没有只读（`revealOnly`）规则，任何列出项都可执行；按行列出的容器规则必须排除所有更具体规则占用的子目录；“清空废纸篓”只能作用于用户自己的 `~/.Trash`；`/Applications` 规则只能列出重复副本。

## 按应用分行的排除清单

`system.user-caches`（`~/Library/Caches`）不单列下列子目录：

- 已被更具体规则列出（或其父目录）：`Homebrew`、`Claude`、`claude-code`、`com.todesktop.230313mzl4w4u92`（Cursor）、`GitHub Copilot`、`OpenClaw`、`Google`（含 Chrome 缓存）、`Microsoft Edge`、`BraveSoftware`、`Firefox`、`company.thebrowser.Browser`、`net.whatsapp.WhatsApp`、`Codex`、`com.openai.codex`、`Citro Labs`（含 ego lite 缓存）、`typeless-updater`、`us.zoom.xos`、`ms-playwright-mcp`、`pip`、`org.swift.swiftpm`、`clang`、`bun`、`CloudKit`；D47 补充新增的开发工具缓存 `go-build`、`gopls`、`golangci-lint`、`ms-playwright`、`ms-playwright-go`、`pnpm`、`Yarn`、`node-gyp`、`typescript`、`deno`、`electron`、`electron-builder`、`Cypress`、`pypoetry`、`CocoaPods`、`org.carthage.CarthageKit`、`Mozilla.sccache`、`flutter_engine`、`claude-cli-nodejs`（规则版本 `2026.10.07.1`）。
- 系统关键状态：`com.apple.accountsd`、`com.apple.akd`、`com.apple.amsaccountsd`、`com.apple.appleaccountd`（账户与认证）、`com.apple.bird`（iCloud 云盘）、`com.apple.cache_delete`（系统可清除空间记账）、`com.apple.containermanagerd`（应用容器元数据）、`com.apple.nsurlsessiond`（进行中的后台下载），以及名称以 `com.apple.FileProvider`、`com.apple.XProtect` 开头的目录（文件提供程序、安全防护）。
- 本应用自己的缓存：`com.local.StorageCleanerMac`、`com.local.StorageCleanerMac.beta`。

`system.user-logs`（`~/Library/Logs`）不单列：`com.apple.diagnosticextensionsd`（诊断日志规则）、`com.openai.codex`（Codex 应用日志规则）、`GitHub Copilot`、`OpenClaw`（开发工具日志规则）。

单列阈值：应用缓存每行至少 50 MiB，日志每行至少 1 MiB；每条规则最多列出 40 个最大的项目，其余计入“候选截断”。大小未知的行（无法列出、含排除路径、含本地历史）不受阈值影响，一律计入“未列出”。

## 本地历史（P2-7）

IDE 的本地编辑历史是用户自己的数据，有的应用把它放在缓存里（JetBrains：`~/Library/Caches/JetBrains/<产品>/LocalHistory`）。扫描遇到名为 `LocalHistory`、`local-history`、`local_history`、`Local History`（不区分大小写）的文件夹时不再往里读，所在的整行不列出，计入“未列出”（含本地历史记录等个人数据）。因为清理只能整行移入废纸篓，这意味着含本地历史的 JetBrains 缓存整行都不清理；如需只清 JetBrains 的索引与缓存，后续要为它加按产品子目录分行的规则。

## 默认预选与所属应用（D47，取代 D22 的“识别不出所属应用不预选”和 D40 的 7 天规则）

- **默认勾选全部绿色项，例外是所属应用正在运行的行**（执行时也会跳过，勾上只会误导），以及 D101 G10 起释放过少的行（见下）。黄色、红色项目和“清空废纸篓”（D23）永不预选。判断在 `ScanCandidate.isPreselectedByDefault`：可直接移入废纸篓的绿色行（`selectionEligibility == .selectable`）且所属应用不在运行；规则里的 `defaultSelection` 对绿色行只剩 `forbidden` 一种取值起作用（内置规则里没有绿色的 `forbidden`；开发缓存规则里的“可选、不选”是占位，由活动分档取代，绿色档为选中）。
- 扫描完成时读取一次正在运行和已安装的应用（`NSWorkspace`），之后不随时间变化。
- 所属应用的来源：规则写明的 `requiredClosedBundleIDs`；按行列出的缓存与日志用目录名推断——名称或其反向域名前缀（至少三段，如 `com.vendor.app.Helper` → `com.vendor.app`）是已安装应用的标识才算识别成功；`DiagnosticReports` 视为无所属应用；重复副本以应用包本身为准。
- 识别不出所属应用的缓存行也预选，徽标与其他绿色行一样显示“推荐”，行内注明“未识别所属应用，清理前无法确认它是否在运行”（警示色）。日志行不依赖所属应用是否识别（D40 原样保留）。
- D47 补充（复核 P1-1，主会话已定）：①`~/Library/Caches` 下能明确识别的开发工具缓存（见规则表“开发缓存与临时文件”）有自己的开发者规则，按活动时间分级，最近用过的为红或黄、不预选，不再作为“未识别所属应用”的绿色用户缓存；②识别不出所属应用的行（缓存与日志）执行前没有应用可查，改为复查写入：按扫描时同样的方式重读可读部分的最近修改时间，扫描之后有任何新写入或变化就跳过，确认面板与完成页写明“扫描后仍有新写入或变化，可能正在使用；已跳过，如需清理请重新扫描”（与开发缓存共用同一检查和原因）。
- 日志（第 10 项）：用户日志、诊断日志、开发工具日志仍记录该行最近一次写入（取可读部分的最新修改时间，只跳过符号链接时仍算可确认），但不再决定预选：7 天内仍有写入的行预选并在行内显示“最近 7 天内仍有写入”；部分内容无法读取、不能确认的行预选并显示“无法确认最近 7 天内是否有写入”。
- 大体积缓存（D47）：单行估算占用不少于 5 GiB 的缓存行（浏览器、应用、系统与开发缓存，不论风险等级；日志、下载、邮件附件副本、重复应用副本、废纸篓除外）在行内提示“体积较大：重建需要重新下载或生成，可能较慢”（`CleanupRebuildCostPolicy`）。
- 所属应用正在运行的行不预选，行内显示“正在运行，清理前需退出”。执行前会再查一次运行状态，规则写明的和从目录名识别出的应用仍在运行则跳过该项。
- 释放过少（D101 G10，D116 修订）：G1 在行内提示共享（克隆或本地快照占了明显一部分）、且可能释放的量不到 1 MiB 或不到列出大小十分之一的绿色行不预选，行内写明“清空废纸篓后预计释放不到 1 MiB 或不到列出大小的十分之一，本次不预选”（`ScanCandidate.freesTooLittleToPreselect`，原因 `freesLittle`）。可能释放的量 = 保守预计数 + 成员全部在本行内的完整克隆组（每组一份；清理本行会删掉组里每个成员）；有成员在本行以外的克隆组（例如 uv、pnpm、Bun 缓存克隆进项目的部分）和本地快照占用的部分仍算保留，跨行、要看最终选择才能算的条件数也不计入。被留下的行保守数和这个合计都在门槛以下，所以行内文字不变。没读到共享信息或共享很少的行照常预选。仍可手动勾选。所属应用正在运行时先显示运行原因。
- “选择推荐项目”取规则推荐（`recommended`）且所属应用不在运行的项；内置规则的绿色行都是推荐，因此与默认预选一致。“恢复默认选择”回到上述 D47 预选。“全选绿色”仍可手动选中运行中的项，执行时按上一条跳过。
- 结果页出现时、以及有应用启动或退出时，重新读取运行状态并更新各行的“正在运行”，不改动已勾选的内容（A2）。
- 已勾选且所属应用在运行、并且可以请求退出的行提供“正常退出并清理”；确认面板中因“相关应用仍在运行”跳过的项目也提供同一操作。先列出将退出的每个实例（同一应用开了多个时写明个数）请用户确认，只发送正常退出请求，不强制结束；退出与等待复用浏览器隐私的 `requestNormalTermination`（每个实例 `terminate()`，按时钟截止时间每 100 ms 检查一次，最长 5 秒）。之后重新检查：从行进入则对当前页的选择发起清理，从确认面板进入则对同一冻结计划重新预检；若等待期间扫描结果或计划已变，只刷新行状态、不自动发起。没有退出的应用逐个点名，相关项目照常跳过。菜单栏或后台应用、Finder、本应用不能请求退出，行与确认面板改写“需手动退出：…”，不会再说“已经退出”；重复应用副本不提供（A2，第三轮 P2-1、P2-2、P2-3、P2-6）。

## 容量不完整（D19）

- 容量分为完整、至少（`lowerBound`）、无法计算（`failed`）。“至少”可勾选、可加入计划，大小显示“至少 X”；清理只移动项目根目录本身，不跟随其中的符号链接。项目根目录本身是符号链接或超出允许范围时仍跳过。
- “无法计算”（根目录不能列出）不列出，计入安全跳过。
- 开发缓存：只因跳过符号链接而不完整时照常按活动时间分级；有无法读取或达到深度上限的部分时为红色（`activityUnverified`），可选、不预选、执行前双重确认。含用户排除路径的开发缓存不列出（见“验收口径”）。执行前复查按扫描时同样的方式重读可读部分的最近修改时间，任何变化都会让该项跳过（“扫描后仍有新写入或变化，可能正在使用；已跳过，如需清理请重新扫描”）。

## 重复应用副本（D25）

- 只在 `/Applications` 第一层的 `.app` 中分组：应用标识（`CFBundleIdentifier`）、版本（`CFBundleShortVersionString`）、构建号（`CFBundleVersion`）都相同才算同一组（P2-1；两份都没有版本键时按相同处理）。每次扫描直接读 `Contents/Info.plist`，不用系统的应用包缓存。例如 `Xcode.app` 与 `Xcode-27.0.0-Beta.app` 标识相同但版本不同，不算重复。至少两份才列出；只测量重复组内的副本，不构成重复组的大应用不遍历。每组至少一份副本达到 100 MiB 才列出；列出时整组一起，不会只列一份。每行显示“版本 X（构建 Y）”。
- 正在运行的副本和 `/var/db/xcode_select_link` 指向的副本（界面称“命令行工具当前使用的 Xcode”，只读链接、不起子进程）总会保留、不能勾选，两者不同时两份都保留；一组副本全部如此时没有可移除项，整组不列出、计入未列出（第三轮 P2-7）。其余副本整组勾选时自动保留一份：直接位于 `/Applications` 根目录的副本 → 应用包修改时间最新的副本 → 路径较短的副本 → 路径排序在前的副本。单独勾选最后一个未选副本时不会选中它，行内显示“将保留此副本”。计划中若仍出现整组全选（例如旧的选择），生成计划时按同一规则去掉保留的那一份，不再整份失败。
- 保留的副本作为保留证据，执行前逐项核对它仍在原位、身份未变。

## 清空废纸篓（D23）

- 单独一项、默认不选，在结果页的单独一节显示；确认面板中单独一节，两项确认后才可执行；与移入废纸篓的项目分开显示和计数（风险卡不含它）。
- 扫描时冻结 `~/.Trash` 第一层的每个项目（路径与文件身份）以及废纸篓文件夹本身的身份。只删除这些项目，不删除废纸篓文件夹本身；扫描后放入废纸篓的项目（包括本次清理移入的）不会被删除。未下载的云端占位文件跳过并计入“云文件”，不冻结，也不会让整份计划失败（P2-5）；含用户排除路径的项目不冻结。
- 每项执行前重新核对三次：仍直接位于 `~/.Trash` 内、废纸篓文件夹与扫描时是同一个、文件身份未变、卷可写、不是新变成的云端占位。指向废纸篓之外的符号链接在扫描时就不列入，执行时若链接已指向外部也会跳过。
- 删除本身（P2-3）：以 `O_NOFOLLOW|O_DIRECTORY` 打开 `~/.Trash`，核对设备号、inode、类型与创建时间和扫描时一致；再用 `fstatat(AT_SYMLINK_NOFOLLOW)` 核对条目身份，条目在其他卷上则拒绝；然后相对这个已打开的目录用 `unlinkat` 删除，文件夹逐层以不跟随链接的方式打开、清空，遇到挂载点（其他卷）即停止。删除前就被拒绝时记为跳过并写明原因；删到一半出错记为“永久删除未完成”。
- 结果回执记为“已永久删除”，不可恢复，计入“永久释放”；未完成的删除记为“永久删除未完成”，不会被当作移入废纸篓的项目自动核对或恢复。
- 没有读取 `~/.Trash` 的权限时不报“空”，而是提示在“系统设置 › 隐私与安全性 › 完全磁盘访问权限”中允许本应用后重新扫描。权限错误按各自的错误域识别：Cocoa 257/513、POSIX `EPERM`/`EACCES`（含嵌套的底层错误）都算权限问题（P2-4）。
- 清空后，“操作记录”中此前“已移走 · 可恢复”的回执：打开回执详情时逐项核对移入位置是否还有同一身份的项目，没有了就显示“已不在废纸篓 · 无法在此恢复”，全部如此时“恢复”按钮不可用；确认面板也提醒早先清理移入的文件清空后无法再恢复（P2-6）。
- 含“已永久删除”或“永久删除未完成”的回执只写入回执日志，不写入旧版的 UserDefaults 回执缓存，以免旧版本整份解码失败后覆盖丢失旧回执（P2-2）。
- 测试只在临时目录夹具的 `.Trash` 上运行，不触碰真实废纸篓。

## 执行链与安全边界（不变）

- 扫描只读，使用 Foundation/Darwin 文件元信息和只读目录枚举。
- 执行链：`ScanSession → CleanupSelection → CleanPlan → Preflight → Confirmation → Identity Recheck → Trash/Quarantine（或冻结的废纸篓项目删除）→ Verification → Report`。确认后每项在移动前仍复查身份、路径、卷与运行状态。
- 预检没有一项通过时，确认面板照样打开，逐项列出原因且不能确认，关闭后回到可编辑的结果页；预检本身无法进行时回到结果页提示（A2；第三轮 P1-1 起界面实际使用 `ScanStore.isV2CleanupConfirmationPresented` 这一个判断，此前真实界面因另有“可确认”条件而不弹面板、结果页被锁）。清空废纸篓在确认面板单独两项确认，`ScanStore` 也单独校验（`permanentDeletionAcknowledged`），与红色项目的两项确认互不替代。
- 清理完成后，结果页去掉已移入废纸篓和已永久删除的行，跳过与失败的行保留（A2）。
- iCloud、OneDrive、网络盘等同步或远端根不当作本地垃圾。
- 选择和容量来自同一 `ScanSession`；筛选、排序和折叠不改变稳定的 `ScanCandidateID`。
- 开发工具活动阈值默认 30 天，可在 30–364 天内设置：最近一次可读修改超过 365 天为绿色，超过阈值但不超过 365 天为黄色，阈值以内为红色；边界采用“超过”。

### 执行前写入复查的限制

识别不出所属应用的行与开发缓存共用修改时间复查（D52、D22）。预检查遍历一遍；执行时的身份、路径、卷及应用状态核对照常保留，目录写入只在保存移动意图之后、紧挨移动的最后复查遍历一遍。取消时每 512 个条目及目录枚举前后检查任务状态，未读完的结果不批准执行；执行中的该项及后续项目按已取消、未处理保留，不移动；意图保存后取消会立即写检查点，再做容量读取与最终回执保存。只有任务确实被取消才走取消分支；读取器在任务未取消时抛出 `CancellationError`，沿用读取失败一类的 `.permissionChanged` 保守跳过。

- 复查只能发现会改变修改时间、且改变可读部分最大修改时间的写入。它不是内容哈希或文件监视：修改时间被还原的改写、读不了的子目录、深度超过规则上限（通常为 32 层）的变化都看不到；即使某个文件的修改时间改变，没有改变整行最大值时也看不到。符号链接与用户排除部分仍不跟随、不纳入比较。根目录不可读则保守跳过，与子目录不可读的既有下界语义不同。
- 剩余 TOCTOU（检查与使用之间）窗口约等于最后一遍遍历的时长，加移动前的几毫秒：先读过的条目可能在遍历余下条目时再次被改写。移动操作不会冻结文件或让写入程序退出；程序如果还开着文件，移到废纸篓后它仍可能继续往里写。这项复查不能保证目录完全静止。
- 仍保留意图保存后的唯一执行写入遍历，才能发现保存意图期间的写入。若此时判定新写入、但后续跳过检查点和最终回执都保存失败，持久记录仍可能停在“移动结果待核实”；并不证明调用了移动。把遍历提前到意图前会扩大这段盲区，本轮未这样调整。

完成页把新写入或相关应用仍在运行的行单列为“仍在使用，已跳过”（英文“Skipped: still in use”），使用中性图标并保留跳过原因。预检阶段已跳过的行由同一执行器按冻结计划 ID 保留原因，在执行上下文和回执中沿用；它们不会因不在批准集合而丢失为泛化的“未通过本次执行前检查”。没有对应预检原因的未批准行仍使用原通用原因，批准集合与执行授权不变。操作记录沿用同一分组用词，并把新写入原因组合为“仍在使用，已跳过 · 扫描后有新写入或变化”，不重复“已跳过”。这些行仍是跳过／保留，不计为失败，真实失败与取消后未处理的行保留原分组。清理浮层的视图实现复用了列表，但尚未接入产品流程，不能当作已上线界面。

## 容量口径

Skill 使用 `du -sk`，App 使用文件系统 allocated bytes 优先、logical bytes 回退。两者表达同一对象，但活跃目录会随扫描时刻变化，不承诺逐字节相等。遇到权限失败、符号链接或深度边界时只保留已知下界并显示“至少”；含用户排除路径的项目不列出（废纸篓中这类条目不冻结，废纸篓一行的大小只计将删除的条目）。容量必须来自当次真实扫描，禁止硬编码旧报告数值。

## 历史

1.9.12 版本的“黄色只读、测量不完整即不可选（fail-closed）、应用本体列为红色可选”等边界，已由 D19、D22–D25（2026-10-04 用户确认）取代。


## R3-4：来源、维护修订与有效指纹（D82，2026-10-12）

每条产品规则的 `maintenance` 保存 `source`（`json`／`developer-catalog`／`coverage-catalog`）、正整数 `revision`、ISO 核对日期 `checkedAt`、可空的 `applicability`、中文短句 `impact` 和可空的 `evidenceURLs`。适用条件仅接受 `applicationBundleIdentifier` 与 `minimumApplicationVersion`；最低版本必须同时标注 Bundle ID。维护测试只做**格式校验**（字段名、Bundle ID 与版本号格式），不核对本机是否装有该应用或其版本。它们是维护注释，本轮不作为新的匹配门槛，原匹配、风险、默认选择、执行资格与 D19/D23/D24/D47/D52 保持原策略。

`rulesVersion` 继续保存原 JSON 标签，追溯使用 `CleanupRuleSet.effectiveProvenance`：对合并后的规则全部字段（含来源／影响／修订等元数据）统一编码、排序规则内部的集合、规范化 Unicode 和隐式默认值，再取 SHA-256（指纹 schema 2）。顶层规则保留原顺序参与哈希：扫描按文件身份去重时由先到的规则认领，规则顺序改变会改变实际行为，因此也改变指纹（修复轮 1）。单独改变版本标签、对象键顺序或规则内部集合顺序不改变指纹。任一实质字段改变会改变指纹。按类别／规则筛选的扫描继承完整规则集的指纹；继承前逐项核对内容哈希，过期的筛选注释不能掩盖内容变化。扫描器每次构造只计算一次追溯数据。

`ScanSession`／`ScanCandidate`、`CleanPlan`／`CleanPlanItem`、`CleanReport`／`CleanReportItem` 顺次保留指纹、规则 ID 与修订。生成计划、预检和执行再次核对有效指纹，JSON 标签相同也能拒绝过期计划。带维护元数据的规则所产生的候选必须带指纹与本项修订，缺失即拒绝生成计划；只有没有候选的会话（仅健康扫描、空智能扫描）可以没有指纹。回执事件追加与冷回放保留且锁定追溯字段，未知移动的核对更新也保留它们。旧回执缺少字段时为 nil，不推测修订；无维护元数据的合成测试／重复文件哨兵规则继续兼容。

`Resources/CleanupRules.baseline.json` 同时保存已审阅规则的修订／规范化内容哈希（初始 79 条；D101 G10 新增 `developer.bun-install-cache`、G7 新增 `user-data.istat-menus-setapp-history`，均为修订 1，共 81 条），以及集成 `52f722ac` 修改前的 73 条原规则。维护测试要求变更内容时修订递增，禁止以自动重写基线替代修订；基线更新须随规则变更一起审阅。迁移测试逐字段锁定原规则，并在隔离目录中比较原候选 ID、风险、执行选择资格与默认选择集合。

结果行预留 `applicationOwnershipText`（属于什么应用）、`cleanupImpactText`（处理后影响）、`preselectionExplanationText`（为什么预选或未预选）；这些字段反映已有策略，不改变选择。视图尚未接入。

## R3-7：AI 工具与持久状态保护（D83，2026-10-12）

新增 6 条规则，全部复用现有开发者目录与安全执行链：

| 工具 | 精确候选目录（家目录下） | 策略与证据 |
|---|---|---|
| Claude 桌面 | `Library/Application Support/Claude/{Cache,Code Cache,GPUCache}` | [Electron userData 路径](https://www.electronjs.org/docs/latest/api/app#appgetpathname)与[可重建代码／HTTP 缓存](https://www.electronjs.org/docs/latest/api/session#sesclearcache)；按开发缓存活动分档，检查 Claude 运行状态 |
| Codex 桌面 | `Library/Application Support/Codex/{Cache,Code Cache,GPUCache}` | 同上；检查 Codex 运行状态；已有 CLI 缓存与日志规则保留 |
| VS Code（含 Copilot） | `Library/Application Support/Code/{Cache,Code Cache,GPUCache}` 与 `logs` | 缓存按活动分档；[VS Code 自建日志目录](https://github.com/microsoft/vscode/blob/main/src/vs/platform/environment/common/environmentService.ts)按现有日志策略，应用关闭时绿色预选；共享宿主缓存不冒称 Copilot 独占 |
| LM Studio | `Library/Application Support/LM Studio/{Cache,Code Cache,GPUCache}` | 只处理已观察到的 Electron 界面缓存；不包含任何模型下载目录；Bundle ID 本轮未核实，保留命令行工具同类活动与执行前写入检查 |
| Rod 浏览器工具 | `.cache/rod/browser` | [官方下载器](https://github.com/go-rod/rod/blob/main/lib/launcher/browser.go)会在二进制缺失时重新下载；按现有开发缓存活动分档；不扫描自定义 profile 根 |

缓存近 30 天（可设置阈值）有写入为红色、阈值之外至一年为黄色、超过一年无写入为绿色；只有绿色预选。日志沿用 D47：近期写入不额外降低等级，应用运行则不预选。清理仍需显式 UI 操作和既有确认；无已证实可再生性的目录不新增规则。

[Playwright 官方浏览器下载文档](https://playwright.dev/docs/browsers)证明二进制可重下载；[Playwright MCP 官方说明](https://github.com/microsoft/playwright-mcp#user-profile)同时明确其持久配置保存登录状态。现有规则字段保留，但混合目录含 `mcp-*`、会话／配置／浏览器持久存储／凭证／模型标记时整行安全跳过，避免把持久配置整体移走。本轮不提取其内部缓存，避免新增凭证目录遍历。**这组名称标记只作用于上表 6 条 D83 规则与 `developer.playwright-browsers`、`developer.playwright-mcp-cache`**（`CleanupProtectedContentPolicy.persistentAgentStateRuleIDs`）；npx、uv、pip、Yarn、pnpm、用户缓存等原有规则内常见的 `config`、`models`、`mcp-server`、`*.pt` 等包内容不受影响，原 `isProtectedDataFolder` 保持集成基线语义（修复轮 1）。新保护在只读元数据遍历中识别名称，不读文件内容；这 8 条规则（含无活动复查的 VS Code 日志）在执行前另做一次只看名称与类型的复查，扫描后新出现的保护标记使整行跳过。符号链接不跟随，原文件身份去重继续保证同一位置只计一次。

本机目录观察、各工具暂不纳入的路径与证据限制，见 `docs/2.0.0/collab/handoffs/r3-rules-provenance.md`。本轮没有启动 App、验证实际重建行为或清理任何真实文件；平台生成目录的可再生性判断来自官方文档与本机结构的一致性。
