# agent-interface-batch-1 交接：AI 助手接口第 1 批（D260–D269）

- 分支：`release/2.0.2`，基线 `066ef037`（树 `930ef8e6`）；工作树 `~/Developer/sc-worktrees/v2.0.2`；构建目录 `~/Developer/.sc-build/v2.0.2/`。
- 实现者：Claude（Opus 5.5）侧会话 `local_c6ef5aab`。
- 状态：接口本身已本地提交 `2f00dfcb`；“AI 助手”设置页（§6）已本地提交 `cf254250`；真实窗口复看后的 D274 紧随其后也已本地提交。没有 push、tag，没有装测试版。
- 过程记录：交接目录 `20261028-2.0.2-AI助手接口/02-工作记录/第1批-暂存实现-20261029.md` §8。字段映射：同目录 `01-计划与分工/第1批-R0字段映射-20261031.md`。

## 1. 改了什么

新增 4 个目标和 App 端目录：

| 位置 | 内容 |
|---|---|
| `Sources/AgentShared` | 套接字位置、数据目录规则、对端策略、偏好键 |
| `Sources/AgentBridgeCore`、`Sources/AgentBridge` | 包内桥接程序 `storage-cleaner-agent`：两代 MCP stdio 服务器和 JSON 命令行 |
| `Sources/AgentGatewayCore` | 网关：套接字服务、路由、限流、结果防线、令牌、客户端记录、访问记录、请求队列 |
| `Sources/StorageCleanerMac/Features/Agent` | 逐字段白名单、分页和令牌、从 Store 拷值、`AgentInterface`（设置页要用的全部接口） |

改动的现有文件：

- `Package.swift`：加产品、目标和测试目标。
- `App/StorageCleanerMacApp.swift`：3 行，`AppLaunchWork.run` 启动，`applicationWillTerminate` 关闭。
- `script/build_and_run.sh`、`script/make_release_dmg.sh`：放入桥接程序，用 `$BUNDLE_ID.agent-bridge` 签名，校验标识和链接版本，测试版再校验 Team 相同。
- `script/verify.sh`：加端到端一步。`script/deletion-process-inventory.txt`：加 3 行。
- `Tests/StorageCleanerMacTests/TestPreferenceHygieneTests.swift`：`fixtureDataPathAllowlist` 加 2 条，旧条目没动。
- `Tests/StorageCleanerMacTests/ReleasePackagingParityTests.swift`：加 1 个打包测试。
- `docs/2.0.0/collab/DECISIONS.md`、`BOARD.md`。

接口这一批共 62 个路径（门禁时），没有碰视图。设置页的改动见 §6。

## 2. 开放了什么

第 1 批只开放 R0（12 个）：`get_overview`、`get_live_status`、`get_health`、`list_results`（junk、startup_items、installed_apps、app_updates）、`list_operation_records`、`get_operation_record`、`list_hardware_operations`、`get_history`、`describe_capabilities`、`list_requests`、`get_request`、`cancel_request`。其余 12 个工具已声明，调用返回 `not_yet_available`。

总开关默认关（D265），在“设置 › AI 助手”里打开（D273，见 §6）。

## 3. 验证

工具链：Xcode 27.2（27B52）、SDK 27.2、Swift 6.4.2、macOS 27.2（26B123）。

脚本 `~/Developer/.sc-build/v2.0.2/gate/verify_v202.sh`（由 `verify_d166.sh` 改，步骤同 `script/verify.sh`），每步单独记日志。

### 接口这一批（g1、g2）

| 步骤 | 命令要点 | g2 结果 |
|---|---|---|
| Debug 构建 | `swift build --build-tests` | exit 0 |
| Debug 主测试包 | `swift test --disable-swift-testing --filter '^StorageCleanerMacTests\.' --skip <D106 窗口类>` | exit 0；6357 个，跳过 29，0 失败 |
| Release 构建 | `swift build -c release -Xswiftc -enable-testing --build-tests` | exit 0 |
| Release 主测试包 | 同上加 `-c release` | exit 0；6064 个，跳过 28，0 失败 |
| 其他测试包 | `xcrun xctest`；Swift Testing 单独一遍（Debug、Release 各一次） | 桥接 92/0、组合图标 285/0、Swift Testing 135/0 |
| 严格并发 | `swift build -Xswiftc -strict-concurrency=complete` | exit 0 |
| 守卫 | D98④ 正则、私有接口、删除与进程清单、`check_cjk_literals`、冲突副本、`git diff --check` | exit 0 |
| 端到端 | `Tests/agent-e2e/run_e2e.py --sdk … --schemas …` | exit 0；71/0，含官方 MCP SDK 和官方 JSON Schema |
| 打包 | `script/build_and_run.sh --bundle-only`，再查包内桥接 | exit 0 |
| 测试版装配 | `script/build_and_run.sh --beta`（不安装、不启动） | exit 0；Team `T9GZL52H8R` |
| 小窗性能 | `script/verify_menu_bar_performance.sh` | g1 exit 0（1407 s）；g2 没重跑，之后 `Sources` 只改了一行注释 |

跳过项和 r72 完全相同（选择性开启的实机测试）。四个测试日志里 `AddressBook/AddressBook-v` 都是 0 处。变异 11 个全部被抓到（`v2.0.2/mutants/mutate.out`）。

门禁通过时的子树：`Sources` `00efe1d1eaea`、`Tests` `12dc6a05a933`、`script` `4ad3d5e57517`、`Package.swift` `9b102a17c3bd`。提交前用临时索引重算比对。

g1 的 3 个失败（都不是产品问题）：测试卫生守卫抓到新测试（Debug、Release 各 1 个），门禁脚本的 SIGPIPE。修法见过程记录 §8.3 第 6、7 条。

### 设置页（g4–g7，2026-11-02）

同一个脚本，工具链不变。最后一轮是 g7，它开始和结束时树都是 `ceabde78`（`HEAD 5e9b3d7b` 加 19 个未提交路径）。脚本 `gate/g7.sh`，日志 `gate/verify-g4-logs/` 到 `verify-g7-logs/`。

| 步骤 | g4 | g7 |
|---|---|---|
| Debug 主测试包 | **1 失败**；6378 个，跳过 29 | exit 0；6383 个，跳过 29，0 失败 |
| Release 主测试包 | **1 失败**；6085 个，跳过 28 | exit 0；6090 个，跳过 28，0 失败 |
| 其他测试包（Debug、Release 各一次） | 桥接 92/0、组合图标 285/0、Swift Testing 135/0 | 相同 |
| 严格并发 | exit 0，**这一页 2 条新警告** | exit 0，全量编译，这一页没有警告 |
| Debug 和 Release 构建、自测、守卫 | exit 0 | exit 0 |
| 端到端 | exit 0；71/0 | exit 0；71/0 |
| 小窗性能 | exit 0；17 个 | exit 0；17 个 |
| 打包、测试版装配，含包内桥接 | exit 0 | exit 0 |

前几轮查出 4 处，都是这一页带来的，都修了：

1. g4：`SettingsSourceContractTests` 的封闭文件清单没有新文件 `SettingsAIAssistant.swift`。补进清单，注明“D273＋旧值”。
2. g4：`SettingsLightfield.swift` 的 `minimumTabWidth` 不在主线程隔离上，却读 `SettingsTabBar.titleSize`、`tabPadding`，到 Swift 6 语言模式下是错误。两个常量改成 `nonisolated static let`，数值没变。
3. g5 全部通过后看图：离屏渲染里中文页面的日期是英文（“上次使用 Nov 2, 2026 at 10:23 AM”）。改成跟随 App 语言（`L10n.locale`）。这种英文日期只出现在测试、渲染和运行中切换语言（没重启）时，真实 App 的情况见 §5。
4. 同时读代码：英文只有 1 条记录时写成 “1 entries”。改用 `L10n.englishCount`。

g6 通过后，用户决定先拿掉“允许提出操作”，并且没有开发者签名的客户端只有签名那行用警告色（D273），所以有 g7。第 3、4 条和这两条都先写测试，红了再改。

按测试名比较：Debug 比 g3 多 22 个（`AgentSettingsPageTests`）；Release 比 g2 多 26 个（这 22 个，加 D272 的 `SettingsInventoryTests` 4 个）；没有测试消失，跳过项相同。所有测试日志里 `AddressBook/AddressBook-v` 都是 0 处，D106 门禁没有拒绝记录。

g7 的严格并发从空目录全量编译（121 s）。只有 4 条警告，所在文件 2.0.2 都没动过：`init(cString:)`（`AuthenticatedUpdateArchive.swift:39`、`APFSCloneReplacement.swift:109`），未用的 `withLock` 结果（`UpdateAskpassInvocationRegistry.swift:12`、`:13`）。Release 构建另有 `Tests/` 里 5 条，g2 就有。这些都没改。

页面图：`gate/ai-page-renders-g7/`，96 张，g7 同一棵树上离屏渲染；g6 的在 `gate/ai-page-renders/`。这一页 6 种状态，每种有中文浅色、中文深色、英文、中英 560 pt、中文加高。别的页面 60 张和 g6 逐字节相同，所以 `SettingsRow` 的改动没有影响它们。图里 `helper` 那行的“可提出操作”是夹具放的旧记录，用来看页面如实显示。离屏时页签图片是空的，已打开的开关是灰的，别的页也一样。

门禁通过时的子树：`Sources` `93b3f6cd070b`、`Tests` `e8d66bed1ea6`、`script` `81fd16049666`、`Package.swift` `9b102a17c3bd`（`gate/g7-tree.txt`）。提交前用临时索引重算比对。

## 4. 没验证的

1. **窗口全量**：2026-11-02 在这一页的快照上跑过（Xcode 27.2，虚拟屏 1 · Codex 2560×1440，`gate/window-g7/`）：执行 669，665 通过，3 跳过（只有设了渲染目录才跑），1 失败。失败的是 `RuntimeUIRound201Tests.testPalettePickerNamesTheSelectionByItsTitleAndMarksCustom`：它还在 `SettingsGeneral.swift` 里找 D272 挪走的选择器。只改查找位置，断言不变，副屏重跑这一类 13 个全过。`testSettingsTabsFitTheBarAtEveryWindowWidth` 在九个页签上通过。D274 之后的代码只跑了 5 个设置相关的窗口类，见 `BOARD.md`；窗口全量等日期统一后的门禁。
2. **Team 签名下真进程的双向校验**：要第一次装机。端到端只用临时签名；Team 分支只有合成身份的单元测试。
3. **设置页的真实操作**：开关、批准和撤销按钮、复制接入配置都没有在运行中的 App 里点过；“已打开”状态是用 DEBUG 钩子渲染的。要装机。
4. Claude Desktop、Codex 的真实调用链；App Nap 下的延迟；`get_live_status` 的 `data_time` 实际节奏。
5. `make_release_dmg.sh` 只做了 `bash -n` 和断言。

## 5. 未解决的问题

- **残余风险**：总开关和批准记录在 App 偏好里，同一用户下的恶意程序能改。它因此能读，第 2 批开放后还能提出，执行仍要用户在 App 里确认。要更严要用钥匙串 ACL，第 2 批开始前请用户定。
- 版本号还是 2.0.1（`script/release_version.env`）。
- QA 副本要测接口的话，桥接程序要按 `.integration.agent-bridge` 重新签名。
- D275 已统一全部日期（交接 `dates-follow-app-language.md`，已本地提交）：这一页的 `settingsText(time:)` 删掉，改用入口；中文一律 24 小时制，下面说的两种样式并存不再出现。以下是 D275 之前的记录。这一页的时间跟随 App 语言。`Sources/StorageCleanerMac` 里还有 74 处日期跟进程的 `Locale.current`（69 次 `formatted(date:time:)`，5 处别的写法；如 `SettingsScan.swift:52`），这次没动。它们在测试、渲染和运行中切换语言（没重启）时中英混排。真实 App 启动时 `L10n.applyAppKitLanguagePreference()` 把 `AppleLanguages` 写进自己的偏好域，重启后 `Locale.current` 是 `zh-Hans_US`，普通写法是“2026年11月2日 下午3:23”，这一页是“2026年11月2日 15:23”，日期统一做完之前两种时间样式并存。这是临时 bundle 探针的结果，11-02 在真实窗口里看过，和探针一致：扫描页是“2026年11月1日 下午3:51”，这一页是“2026年11月2日 11:54”（证据：交接目录 `20261031-设置菜单整理/03-验证证据/日期语言探针-20261102/输出.txt`；`gate/qa-settings-real/`）。

## 6. 设置页（D273）

`Views/Settings/SettingsAIAssistant.swift` 的 `AgentSettingsPage`，只读写传给它的 `AgentInterface`。`SettingsView.init` 的 `agentInterface:` 默认 `AgentInterface.shared`，渲染和测试传自己的，碰不到真网关和真偏好。

改动的现有文件：

- `Views/SettingsView.swift`：第九个页签 `aiAssistant`，放在“权限与隐私”后面；注入 `agentInterface:`。
- `Views/Settings/SettingsLightfield.swift`：页签图；`minimumTabWidth` 按标题两行放下算最小宽度（见 D273）；`SettingsRow` 加可选的 `detail`，让“上次使用”那行不跟签名那行用警告色，别的页面不传。
- `Views/Settings/SettingsActivationRefresh.swift`：回到应用时刷新这一页。
- `Features/Agent/AgentInterface.swift`：`statusCaption`、`recentAccess`、`accessEntryCount`、`refreshForSettings()`。失败文案去掉“桥接”。
- 测试：新增 `AgentSettingsPageTests`（22 个）。`SettingsInventoryTests`、`D64DeclutterAContractTests`（D265＋旧值）、`SettingsSourceContractTests`（D273＋旧值）各补一处清单；`SettingsPagesRenderReviewTests` 加这一页的渲染；`AgentInterfaceLifecycleTests` 的 `EmptySource` 去掉 `private`。
- 文档：`CHANGELOG.md`、`PRIVACY.md`、`SECURITY.md`、`CAPABILITIES.md`、`ARCHITECTURE.md`。

| 页面上的 | 接口 |
|---|---|
| 总开关 | `isEnabled`、`setEnabled(_:)` |
| 状态和失败原因 | `statusCaption`、`status.isFailure` |
| 等待批准 | `pendingClients`、`decide(_:_:)`；选项是 `AgentSettingsPage.grants`（只读）和拒绝 |
| 客户端和撤销 | `clients`、`revoke(bindingKey:)` |
| 访问记录 | `recentAccess`、`accessEntryCount`；进页面和回到应用时由 `refreshForSettings()` 读 |
| 复制接入配置 | `configSnippets()` |

首次打开的说明靠偏好 `agentInterface.settingsIntroSeen.v1`。D265 里的“确认时要求 Touch ID 或登录密码”“允许打开本应用”“待确认请求”等第 2 批，页面上现在没有。

“允许提出操作”用户决定先拿掉（D273）。第 2 批开放提出工具时：

- 把 `.propose` 放回 `AgentSettingsPage.grants`，补回 `settingsGrantTitle` 的文案。
- 已批准只读的客户端要用户再批准一次，已有记录不自动升级。
- 改掉等待批准页脚的“这一版客户端只能读取信息”、连接一组和说明页里“这一版只能读”的句子，改 `CAPABILITIES.md`、`SECURITY.md`、`PRIVACY.md`。
