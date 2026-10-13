# r3-uninstall 交接：卸载残留规则扩充（D87）与 Finder 右键卸载（D88）

- 分支：`task/r3-uninstall`，基线 `52f722ac`；worktree `~/Developer/sc-worktrees/r3-uninstall`；scratch `~/Developer/.sc-build/r3-uninstall/`。
- 实现者：Claude 子代理（Opus 5.5）。参考资料：`同类逆向-20261012/腾讯柠檬-5.3.4.md` P1-2、`CleanMyMac-5.7.1.md` P3 Finder 卸载入口、`第三轮计划.md`。只借鉴“专用规则 + 归属证明”“薄 Finder 入口”的思路，没有复制竞品代码或规则文本（柠檬为 GPL）。
- 本批没有运行 `script/build_and_run.sh`、没有安装、没有启动应用，也没有读取任何真实应用的数据目录内容。

## 1. D87 卸载专用规则扩充

### 改了什么

- `Services/UninstallVendorRules.swift` 改为表驱动：
  - `entries`：可签发 `vendorRule` 证明的条目。每条有 Bundle ID、Team ID、官方资料链接、修订号，以及按版本给出的精确相对路径。
  - `discoveryOnlyPaths`：只用于发现的路径。界面会显示这些路径，但它们永远不能勾选。
  - `discoveryCandidates(bundleID:version:)`：返回某个 Bundle ID 的全部文档路径，不管签名者是谁。只在签名者核实后，`rules(bundleID:version:teamID:)` 才会签发证明。
  - `isSafeRelativePath`：路径只能位于 `Library/{Application Support,Caches,Preferences,Containers,Group Containers}/…` 下，不能是根目录本身，也不能含空段、`.`、`..` 或 NUL。
  - VS Code、Teams 的旧修订号原样保留，已保存的回执仍然可用。
- `Services/UninstallOwnershipVerifier.swift`：只改了一处。发现阶段改用 `discoveryCandidates`。以前 Team ID 不对时，文档路径根本不出现；现在会显示出来，但处于“签名未核实，已保留”状态，不能勾选。签发证明仍然只走 `vendorRules`，它绑定 Team ID。其余归属链没有改：签名需有 Apple 锚定，codesign 标识必须等于 Bundle ID，Team ID 不能为空，清单必须完整，只能有一份安装，应用身份、版本和构建号也不能变。
- `Support/UninstallCandidatePathPolicy.swift` 未改。原有的“仅按 Bundle ID 生成候选，名称不作证明”规则保持不变。
- 关联项默认不勾选（D1）：`ScanStore.requestUninstall` 仍会清空 `uninstallSelectedPaths`，本批没有改动。

### 规则表与资料来源

| 应用 | Bundle ID | Team ID | 类型 | 路径（相对家目录） | 官方资料 | 核验 |
|---|---|---|---|---|---|---|
| Google Chrome（稳定版） | com.google.Chrome | EQHXZ8M8AV | 可签发 | Library/Application Support/Google/Chrome | https://support.google.com/chrome/answer/95319 （Mac：删除个人资料信息） | 已 curl 页面，路径原文核对；Team ID 用本机 `codesign -dv` 核对 |
| Spotify | com.spotify.client | 2FNC3A47ZF | 可签发 | Library/Caches/com.spotify.client；Library/Caches/com.spotify.client.helper；Library/Application Support/Spotify | https://support.spotify.com/us/article/clean-reinstall/ | 页面原文核对；Team ID **本机未安装，未核验** |
| Docker Desktop | com.docker.docker | 9BNSXJN65R | 可签发 | Library/Containers/com.docker.docker | https://docs.docker.com/desktop/uninstall/ | 页面原文核对；Team ID 未核验 |
| Docker Desktop | 同上 | — | 仅发现 | Library/Group Containers/group.com.docker（共享 App Group） | 同上 | 页面原文 |
| Discord | com.hnc.Discord | 53Q6R32WPB | 可签发 | Library/Application Support/Discord | https://support.discord.com/hc/en-us/articles/360022082931 （macOS 重装步骤） | 经 Zendesk API 读取原文；Team ID 本机核对 |
| Figma | com.figma.Desktop | T8RA8NE3B7 | 可签发 | Library/Application Support/Figma | https://help.figma.com/hc/en-us/articles/22380853110551 （清除桌面应用缓存） | Zendesk API 原文；Team ID 未核验 |
| IntelliJ IDEA / PyCharm / WebStorm / GoLand / CLion / PhpStorm | com.jetbrains.intellij / .pycharm / .WebStorm / .goland / .CLion / .PhpStorm | 2ZEFAR8TH3 | 可签发（按已安装版本） | Library/Application Support/JetBrains/<产品><年.次版本>；Library/Caches/JetBrains/<产品><年.次版本> | https://www.jetbrains.com/help/{idea,pycharm,webstorm,go,clion,phpstorm}/uninstall.html | 6 个页面原文的产品目录名均已核对；Bundle ID 与 Team ID 未核验 |
| VS Code、Teams | 不变 | UBF8T346G9 | 可签发 | 不变 | 不变 | — |
| Microsoft Edge | com.microsoft.edgemac | — | 仅发现 | Library/Application Support/Microsoft Edge；Library/Caches/Microsoft Edge | **未取得**（support.microsoft.com 返回错误页） | 档案可被多渠道共用 |
| Firefox | org.mozilla.firefox | — | 仅发现 | Library/Application Support/Firefox；Library/Caches/Firefox | **未取得**（SUMO 有机器人验证页，没有绕过） | 各渠道共用 Profiles |
| Slack | com.tinyspeck.slackmacgap | — | 仅发现 | Library/Application Support/Slack | **未取得**（帮助中心正文由脚本渲染） | — |
| Zoom | us.zoom.xos | — | 仅发现 | Library/Application Support/zoom.us | **未取得** | Bundle ID 本机核对 |
| Notion | notion.id | — | 仅发现 | Library/Application Support/Notion | **未取得** | — |
| Telegram（App Store） | ru.keepcoder.Telegram | — | 仅发现 | Library/Group Containers/6N38VWS5BX.ru.keepcoder.Telegram（共享组） | **未取得** | 沙盒容器仍走原容器元数据证明 |
| Telegram Desktop | org.telegram.desktop | — | 仅发现 | Library/Application Support/Telegram Desktop | **未取得** | — |
| 微信 | com.tencent.xinWeChat | — | 仅发现 | Library/Group Containers/5A4RE8SF68.com.tencent.xinWeChat（共享组，含聊天记录） | **未取得** | Bundle ID 与 Team ID 本机核对；`Containers/com.tencent.xinWeChat` 仍走原容器元数据证明 |
| JetBrains Toolbox | com.jetbrains.toolbox | — | 仅发现 | Library/Application Support/JetBrains/Toolbox（内含 Toolbox 管理的 IDE） | **未取得**（help 页正文由脚本渲染） | — |
| Adobe Creative Cloud | com.adobe.acc.AdobeCreativeCloud | — | 明确不列 | 无。`Application Support/Adobe` 下是共享组件，不列入 | helpx.adobe.com 拒绝访问 | 有测试守卫 |
| Dropbox | com.getdropbox.dropbox | — | 明确不列 | 无。官方卸载页 https://help.dropbox.com/installs/uninstall-dropbox 只提到用户的 Dropbox 同步文件夹，那是用户文件，不是残留 | 页面原文核对 | 有测试守卫 |

取舍说明：

1. Team ID 写错只会让规则失效，不会扩大范围，因为签发证明要求签名中的 Team ID 完全相等。标“未核验”的条目，请主会话在本机安装对应应用后用 `codesign -dv` 核对。不一致时改表即可，不需要改测试。
2. `~/.docker`、`~/.vscode`、`~/Library/Logs/JetBrains/…`、`Saved Application State`、`HTTPStorages`、`LaunchAgents` 都在现有安全根（`AppUninstallService.isSafeRelatedPath`）之外，本批没有加入。扩展安全根需要另做决定。
3. 网络限制：本会话的 WebSearch/WebFetch 工具报错（模型不可用），所以改用 curl 直接读取。有机器人验证、返回 404 或只靠脚本渲染的页面，没有绕过，相关条目一律降为“仅发现”。

## 2. D88 Finder 右键卸载

> **已被“修复轮 1”取代的部分**：下文第 2、3 步的 `storagecleaner-uninstall://` URL scheme、`kAEGetURL` 处理、`CFBundleURLTypes`、所有构建模式都嵌入扩展、用 `store.errorMessage`（“操作失败”）汇总被拒项，均已改掉，现行做法见文末“修复轮 1”。本节保留首版原文，便于对照。

### 方案取舍

采用 Finder Sync 扩展（FinderSync 上下文菜单），没有退回 NSServices。理由：

- SwiftPM 可以产出扩展可执行文件：`main.swift` 通过 `@_silgen_name("NSExtensionMain")` 调用系统入口，不需要 `-e` 链接参数。已在本 scratch 的 Debug 产物上确认：未定义符号含 `_NSExtensionMain`、`_OBJC_CLASS_$_FIFinderSync`，并导出 `_OBJC_CLASS_$_StorageCleanerFinderUninstallExtension`。
- 打包时由脚本把可执行文件包成 `.appex`。在 scratch 里按脚本相同结构手工组装了一份原型：`Info.plist` 能通过 `plutil -lint`，ad-hoc 签名加沙盒 entitlement 后 `codesign --verify --strict` 通过，entitlement 能读回。原型用完已删除。**真实脚本没有运行。**

### 数据流

1. Finder 右键时，扩展的 `menu(for:)` 判断所选项里是否有规范化的 `.app` 路径。有才显示“用存储清理助手卸载”（英文为 “Uninstall with Storage Cleaner”）。扩展不访问文件系统，不扫描、不测量、不移动。
2. 点击菜单后，扩展用 `FinderUninstallHandoff.makeURL` 生成 `storagecleaner-uninstall://review?path=…`（按 RFC 3986 非保留字符做百分号编码），再用 `NSWorkspace.open([url], withApplicationAt: <宿主 .app>)` 发给扩展所在的宿主应用。这样测试版和正式版不会互相抢请求。
3. 主程序的 `AppDelegate` 在 will-/did-FinishLaunching 两处都注册 `kAEGetURL` 处理，然后交给 `ExternalUninstallRequestCenter.receive(url:)`。`FinderUninstallHandoff.parse` 只接受上述 scheme 和 host，并拒绝带路径、用户名、端口或片段的 URL。
4. 请求中心（`Services/ExternalUninstallRequests.swift`）的处理：
   - 显示主窗口并切到“卸载”；只在新请求到达时切一次。
   - 卸载流程空闲时（没在加载清单、准备、执行或恢复，也没有打开的审阅），先刷新一次应用清单，避免用到几小时前的旧清单。
   - 逐个解析路径：替身和符号链接各解析一次；目标不存在或替身失效记为“已不存在”；非 `.app` 记为“不是应用程序”；`/System/…` 记为“系统应用”；按真实路径（`PathSafety.normalizedPath`）在清单里匹配，匹配不到记为“不在清单”；匹配到但 `canRequestUninstall` 不成立的，记为“不能移到废纸篓”。
   - 匹配成功就调用现有的 `store.requestUninstall(app)`，即打开原有审阅表。多选时排队：等审阅表关闭（`pendingUninstallApp == nil`）后再开下一个。
   - 队列处理完，用 `store.errorMessage` 汇总被拒项（沿用“操作失败”提示框），最多列 8 项。
   - 正在运行、签名、多份安装、关联项归属，全部交给原审阅和执行链判断，请求中心不做特殊处理。请求中心不会勾选关联项，也不会调用 `confirmUninstall`。
5. `ExternalUninstallRequestBridge`（ViewModifier）挂在主窗口上。加载、准备、执行状态，审阅对象和错误提示变化时，都会重新推进队列。

### 改动文件

- `Package.swift`：新增库 `UninstallHandoffShared`、可执行目标/产品 `StorageCleanerFinderExtension`（路径 `Sources/FinderUninstallExtension`，链接 FinderSync 和 AppKit）；主程序和测试目标依赖 `UninstallHandoffShared`。
- `Sources/UninstallHandoffShared/FinderUninstallHandoff.swift`：编解码与路径规范化，纯函数。
- `Sources/FinderUninstallExtension/{main.swift,FinderUninstallExtension.swift}`：扩展本体。
- `Sources/StorageCleanerMac/Services/ExternalUninstallRequests.swift`：解析器、请求中心、ViewModifier，以及 `ScanStore: ExternalUninstallHost`（只用于协议一致性声明，没有改 `ScanStore.swift`）。
- `Sources/StorageCleanerMac/App/StorageCleanerMacApp.swift`：注册 GURL 处理、挂上 Bridge。
- `script/build_and_run.sh`（只改打包和签名部分）：
  - 定义扩展名、`$BUNDLE_ID.FinderUninstall`、主类名和 URL scheme；
  - 把扩展包成 `Contents/PlugIns/StorageCleanerFinderExtension.appex`，写入 `Info.plist`（`XPC!`、`com.apple.FinderSync`）和只含沙盒的 entitlements；
  - 在外层签名之前，用 `-i $FINDER_EXTENSION_ID --entitlements` 签扩展，并做 strict verify；
  - 主 `Info.plist` 增加 `CFBundleURLTypes`；
  - `verify_sparkle_bundle` 增加检查：scheme、扩展标识、扩展点、主类、沙盒 entitlement、strict 签名、最低系统版本与架构。

## 3. 测试

新增 5 个测试类，共 24 个测试（首版写成 25 个，修复轮 1 更正；修复轮 1 后为 37 个，见文末）：

- `UninstallVendorRuleCatalogTests`（7 个）检查：
  - 每条可签发规则都有官方 https 链接，且主机与厂商相符；Team ID 格式正确；修订号唯一；同一路径不会被两个厂商认领；共享组从不签发证明；
  - 本批要求的应用全部覆盖；
  - Team ID 错误、为空，或 Bundle ID 相近（加 `.helper`、大小写变化、`.beta`）时一律不签发；
  - JetBrains 的版本目录解析；
  - 仅发现路径与可签发路径不重叠；Adobe、Dropbox、CloudStorage 不会被列入；
  - 仅发现路径在签名未核实时也会出现；
  - 安全根边界。
- `UninstallVendorOwnershipTests`（3 个，操作家目录夹具）检查：
  - 未签名夹具能发现 Chrome 档案和 Docker 共享组，但一律没有证明、不可勾选；
  - 存在多份安装（`otherInstallations`）或清单不完整（`inventoryIncomplete`）时保持阻止；
  - `vendorRule` 证明只在 Team ID、路径、修订号和版本都精确匹配时成立；IDE 升级后，旧版本目录不再成立；Toolbox 目录永远不成立；
  - 不读取真实应用数据。
- `FinderUninstallHandoffTests`（5 个）检查：
  - 特殊字符、中文和 `%` 的往返编码；去重、去掉末尾 `/`、保持顺序；
  - 选中项里没有应用时不出菜单；
  - 外部 URL 和格式不对的 URL 被拒；
  - 相对路径、`.`、`..`、`//`、非应用路径被拒；
  - 32 个上限和路径过长被拒。
- `ExternalUninstallRequestTests`（5 个）检查：
  - 符号链接和 Finder 替身能解析到清单中的同一应用；
  - 目标已删除、链接失效、链接指向非应用、相对路径、系统应用都被拒；
  - 先刷新一次清单，然后一次只开一个审阅，关闭后再开下一个；运行中应用照常进入审阅；队列处理完后汇总被拒项，且从不勾选关联项；
  - 不可管理的项和非应用路径只汇总提示，不进入审阅；非本 scheme 的 URL 返回 false；
  - 卸载正在执行时不刷新清单。
- `FinderUninstallPackagingTests`（4 个）守卫：
  - 脚本里的 appex 结构、扩展点、`XPC!`、沙盒 entitlement、URL scheme 与共享常量一致；扩展先于外层签名；verify 段包含新增检查；
  - 主类名和扩展源码的 `@objc` 名一致；
  - 扩展源码里不出现移动、删除、枚举或执行类调用；
  - 主程序把请求交给现有 `requestUninstall`，且请求中心不调用 `confirmUninstall`、`uninstallSelectedPaths`、`AppUninstallService.execute`。

没有改写任何旧断言。原有 `UninstallExperienceTests` 中 Teams/VS Code 的断言保持不变，并且通过。

### 实际运行（Xcode 27 beta，`--jobs 3`，机器负载约 80–100）

| 命令 | 结果 |
|---|---|
| `swift build "${F[@]}"` | exit 0 |
| `swift build "${F[@]}" --build-tests` | exit 0 |
| `swift test … --filter '新 5 类 + UninstallExperienceTests + UninstallOwnershipTests'` | exit 0；共 36 个测试，跳过 2 个（原有的签名夹具测试，需要 `SCM_SIGNED_UNINSTALL_FIXTURE`），失败 0 |
| `swift test … --filter '相关旧类 14 个'`（见 targeted-classes.txt） | 共 375 个测试，跳过 1 个，失败 1 个：`SystemUtilitySafetyTests/testShellTimeoutTerminatesDescendantProcesses`，耗时 52.8 s，系统负载约 100；单独重跑通过（0.38 s）。判断与本批无关 |
| `swift build -c release … --build-tests -Xswiftc -enable-testing`（release scratch） | 在提交 97837b70 的源码上 exit 0（日志 `release-build-final.log`，677 s 增量构建） |

### 红/绿/反证

`counterexamples.json` 共 11 条，每条把一项核心行为改坏，对应的 filter 应该失败。验证方法与结果写在文末“反证结果”一节。

## 4. 未解决问题和需要主会话验证的事项

1. **实机验证（未做）**，需要主会话在测试版上确认：
   - 扩展需在“系统设置 › 通用 › 登录项与扩展 › 访达”中启用；首次使用可能需要先运行 `pluginkit -e use -i com.local.StorageCleanerMac.beta.FinderUninstall`，或由用户手动打开；
   - 右键菜单项的出现条件；
   - `NSWorkspace.open(_:withApplicationAt:)` 在沙盒扩展里是否成功；
   - SwiftUI 是否覆盖了我们注册的 GURL 处理。did-finish 时已经再注册一次；如果仍被覆盖，可改用 `.onOpenURL` 加 `handlesExternalEvents`；
   - 冷启动时请求是否会丢；
   - 多选排队时，执行完成后的结果页何时关闭，以及何时推进下一项。
2. ad-hoc 签名（非测试版的 `--bundle-only`）的沙盒扩展，pluginkit 是否接受还不确定。测试版用开发证书签名，应该没有问题。
3. `script/make_release_dmg.sh`（正式发布打包）**没有接入**扩展和 URL scheme（不在本批授权范围）。正式版要提供这个入口，需要另开批次，按同样结构改。
4. URL scheme 是公开注册的。网页也能发起 `storagecleaner-uninstall://review?path=…`（浏览器会先询问用户）。最坏结果是打开某个应用的卸载审阅表，执行仍需用户在审阅表里确认，所以没有加签名校验。如需更严，可以去掉 `CFBundleURLTypes`，只依赖“指定宿主应用打开”。这一点需要实机确认，未注册 scheme 时投递能否成功。
5. 被拒项提示沿用“操作失败”标题，文案没有单独设计。
6. 规则表中标“未核验”的 Team ID 和 JetBrains Bundle ID，需要在本机安装对应应用后核对。

## 反证结果（实际执行）

做法：用 `~/Developer/.sc-build/r3-uninstall/ce.py apply <ids>` 按 `counterexamples.json` 做精确替换（先断言出现次数），然后 `swift build --build-tests`，再逐个运行对应 filter，最后 `git checkout -- Sources script` 还原，并确认 `git status` 干净。为减少负载，11 条分两组构建：A 组 5 条、B 组 6 条。各条改动位置、影响的测试方法互不重叠，组内一起编译通过，也就说明逐条替换都能编译。

| id | filter | 结果 |
|---|---|---|
| ce1-vendor-team-binding | UninstallVendorRuleCatalogTests/testWrongTeamSimilarBundleIDAndEmptyTeamGrantNothing | 构建 exit 0；测试 exit 1，15 条 error |
| ce4-vendor-revision-current | UninstallVendorOwnershipTests/testVendorProofIsCurrentOnlyForExactTeamPathRevisionAndVersion | exit 1，2 条 error |
| ce5-handoff-traversal | FinderUninstallHandoffTests/testParseRejectsRelativeTraversalAndNonApplicationPaths | exit 1，2 条 error |
| ce7-one-review-at-a-time | ExternalUninstallRequestTests/testQueueRefreshesOnceThenFeedsOneReviewAtATime | exit 1，2 条 error |
| ce9-alias-resolution | ExternalUninstallRequestTests/testResolverFollowsSymlinkAndAliasIntoTheSameInventoryIdentity | exit 1，1 条 error |
| ce2-jetbrains-major-minor | UninstallVendorRuleCatalogTests/testJetBrainsRulesAreBoundToTheInstalledMajorMinorVersion | 构建 exit 0；测试 exit 1，2 条 error |
| ce3-discovery-only-visible | UninstallVendorRuleCatalogTests/testDiscoveryCandidatesIgnoreTheSignerButRulesDoNot | exit 1，1 条 error |
| ce6-handoff-host | FinderUninstallHandoffTests/testParseRejectsForeignAndMalformedURLs | exit 1，1 条 error |
| ce8-refresh-before-match | ExternalUninstallRequestTests/testQueueWaitsForBusyUninstallFlowBeforeRefreshing | exit 1，1 条 error |
| ce10-system-application | ExternalUninstallRequestTests/testResolverRejectsMissingBrokenNonApplicationAndSystemPaths | exit 1，1 条 error |
| ce11-appex-signed-sandboxed | FinderUninstallPackagingTests/testBuildScriptPackagesAndSignsSandboxedFinderSyncExtension | exit 1，1 条 error |

绿灯：反证之前，在最终源码上构建（`--build-tests` exit 0），新增的 5 类加上 `UninstallExperienceTests`、`UninstallOwnershipTests` 共 36 个测试：跳过 2 个，失败 0 个。日志在 scratch 的 `ce-*.log`、`test-green.log`。注意：反证结束后，debug scratch 里的产物是 B 组反证版本，主会话请先重新构建再测试。

## 修复轮 1（独立复核意见：D87 可合入，D88 需先修）

提交 `14bb01fb`（代码与测试），文档另一提交。仍未运行 `script/build_and_run.sh`、未安装、未启动应用、未启用扩展、未卸载任何真实应用，`ScanStore.swift` 未改，没有放宽旧断言。

### P1-1 扩展副本与正式版 ID

- `script/build_and_run.sh`：新增 `EMBED_FINDER_EXTENSION`，只在 `--beta --install` 时为 1。组装 appex、签扩展两段都包在这个条件里；`run`、`--bundle-only`（正式版 ID `com.local.StorageCleanerMac`）与不带 `--install` 的测试版都不带 PlugIns。`verify_sparkle_bundle` 在不嵌入时若发现 `Contents/PlugIns` 直接报错。
- 安装流程里同一个包仍会出现在 `/tmp` 的 dist、artifact、staging、`.previous` 副本中（脚本先签名再复制，无法只给最终位置嵌入）。这些副本靠下一条变成惰性：
- 扩展：`FinderUninstallHandoff.hostApplication(forExtensionAt: Bundle.main.bundleURL)` 只在扩展位于 `/Applications/测试版.app/Contents/PlugIns/*.appex` 时返回宿主，否则 `menu(for:)` 返回 nil、点击处理直接返回。删掉了宿主不是 `.app` 时 `NSWorkspace.shared.open(url)` 的退回。装到 `~/Applications/测试版.app`（`/Applications` 不可写时脚本的备选位置）也不会出菜单，这是有意的。

### P1-2 去掉公开 URL scheme

- 主 `Info.plist` 不再有 `CFBundleURLTypes`；校验段反向检查它不存在。共享库删掉 `scheme/host/makeURL/parse` 与百分号编码，只保留 `request(for:)`、`applicationURLs(for:)`、`hostApplication(forExtensionAt:)` 与路径规范化。
- 扩展：`NSWorkspace.shared.open(所选 .app 目录 URL, withApplicationAt: 宿主, configuration:)`，宿主收到的是 open documents（`application(_:open:)`），网页无法发起。
- 宿主（`ExternalUninstallRequests.swift`）：
  - `receive(openedURLs:)` 忽略非文件 URL（全是非文件 URL 时什么都不显示）；`.app` 之外的文件进被拒汇总；解析时要求目标是目录，文件名叫 `X.app` 的普通文件被拒。
  - 队列上限 32（超出记“一次最多处理 32 个应用”），被拒记录上限 64（超出只计数，汇总里并入“另有 N 项”）。
  - 批次合并：一批处理完之前到达的请求并入同一批，只刷新一次清单、只切一次页面、只显示一次窗口；批次结束（队列空、无审阅、无后台解析）后再来的请求算新批次。
  - 先在主线程按字面规范化路径比对清单（不碰文件系统）；比不上的才用 `Task.detached` 在后台解析替身/符号链接/真实路径，结果回主线程再开审阅。
  - 被拒汇总改用独立提示框，标题“部分项目未进入卸载审阅”（英文 “Some Items Were Not Opened for Review”），不再写 `store.errorMessage`/“操作失败”；有其他错误提示时等它关闭再出。文件名去掉控制与格式字符（含换行、RLO），超过 60 字符截断加“…”；分隔符按语言用“：”或“: ”。
- 普通用户把 `.app` 拖到 Dock 图标、或在访达“打开方式”选测试版，也会走这条路径：只会打开该应用的卸载审阅表，执行仍需在审阅表里确认。可接受，已写入 D88。（当前主 `Info.plist` 没有声明文档类型，Dock 是否接受拖放需实机看。）

### P1-3 冷启动与 SwiftUI

- `AppDelegate` 删掉 `kAEGetURL` 处理与 `applicationWillFinishLaunching`，改为 `application(_:open:)` → `ExternalUninstallRequestCenter.shared.receive(openedURLs:)`。
- 请求中心在主窗口 attach（Bridge `onAppear`）前只入队、记下“待显示窗口”；attach 时显示一次窗口再推进队列。
- 主窗口内容加 `.handlesExternalEvents(preferring: ["*"], allowing: ["*"])`，外部事件由现有窗口处理；原有 `WindowGroup(for: String.self)` + `openWindow(value: "primary")` 继续保证单窗口。

### P2

- 关联文件清理进行中（`pendingRelatedCleanupApp != nil` 或 `isCleaningRelatedAppFiles`）时队列等待；Bridge 观察这两个值和 `isRestoringRecordedOperation` 的变化再推进，不再误报“不能移到废纸篓”。
- 高价值数据：`UninstallVendorRules.highValueDataPaths` 标注 Chrome/Edge/Firefox 档案为“含个人资料”、`Library/Containers/com.docker.docker` 为“含镜像与数据卷”（按 `Library/...` 尾部匹配，误判只会更严）。审阅表在该行显示标签；`UninstallPresentation.bulkSelectablePaths` 把它们排除在“全选已核实项”外，只能逐项勾选；全部已核实项都是高价值时不显示该按钮。
- 仅发现的共享组容器：`unmeasuredDiscoveryPaths`（`discoveryOnly` 中 `Library/Group Containers/` 下的，即微信、Telegram、Docker group、Teams group）在 `discover` 里只做 lstat，大小记为未知，不遍历。注意 Teams 的 group 容器是基线已有的仅发现项，现在也不再测量。
- `sharedVendorFolders`（Google、Microsoft、JetBrains、Adobe、Mozilla、Docker 的 Application Support/Caches 厂商目录）被 `isSafeRelativePath` 拒绝；测试同时检查任何一个应用的路径都不覆盖另一个应用的路径。

### 测试变化与改写的断言

本批自己的首版测试中，与已删除 URL scheme 相关的断言随功能删除并替换（不是放宽，被测接口已不存在）：
- `FinderUninstallHandoffTests`：`testRoundTrip…`/`testParseRejectsForeign…`/`testParseRejectsRelativeTraversal…` 换成 `testRequestKeepsOrder…`、`testOnlyTheInstalledBetaHostsTheMenu`、`testRequestRejectsRelativeTraversal…`，顺序、去重、`.`/`..`、非应用、32 上限、超长路径的期望不变。
- `FinderUninstallPackagingTests`：原先断言脚本含 URL scheme、扩展含 `makeURL`、App 含 `kAEGetURL`，改为断言它们**不存在**，并新增“只在安装测试版嵌入”“无公开 scheme”。
- `ExternalUninstallRequestTests`：`errorMessage` 断言改为 `rejectionSummary`；`center.resolve` 注入改为 `resolveOnFileSystem`（异步）。
- 旧类（`UninstallExperienceTests`、`UninstallOwnershipTests` 等）断言未动。

测试数：5 个新类首版 24 个（交接首版误写 25），修复轮 1 后 37 个：`UninstallVendorRuleCatalogTests` 9、`UninstallVendorOwnershipTests` 5、`FinderUninstallHandoffTests` 5、`ExternalUninstallRequestTests` 12、`FinderUninstallPackagingTests` 6。`targeted-classes.txt` 无新增类（新测试都在原 5 类内）。

### 实际运行（Xcode 27 beta，`--jobs 3`）

| 命令 | 结果 |
|---|---|
| 先重建（反证版产物作废）`swift build "${F[@]}" --build-tests` | exit 0 |
| 修复后 `swift build "${F[@]}" --build-tests` | exit 0 |
| `swift test … --filter` 新 5 类 | exit 0；37 个，失败 0 |
| `swift test … --filter` `targeted-classes.txt` 全部 21 类（反证全部还原后、最终重建） | exit 0；424 个，跳过 3，失败 0（日志 `r1-final-targeted.log`） |
| `swift build -c release --scratch-path …/release … --build-tests -Xswiftc -enable-testing` | exit 0（源码 `14bb01fb`，日志 `r1-release-build.log`） |

### 反证（`counterexamples.json` 27 条，逐条红）

做法同首版：`ce.py apply` 按出现次数精确替换 → `swift build --build-tests` → 逐条跑对应 filter → `git checkout -- Sources script` → `git status` 干净。首版 11 条中 `ce5`、`ce7`、`ce8` 的 before/filter 已同步新源码，`ce6`（URL host 解析）随 scheme 删除改为“只认已安装测试版宿主”。分 A/B/C 三组构建（JSON 的 `group` 字段），同组内各条改动的目标测试互不影响；`ce24` 在 B 组里因 `ce3`（去掉仅发现路径）同时生效而“假红”，已单独在 C 组重跑确认是它自己导致的失败。

| id | 覆盖 | 结果（测试 exit / 失败断言数） |
|---|---|---|
| ce1-vendor-team-binding | D87 | 1 / 15 |
| ce2-jetbrains-major-minor | D87 | 1 / 2 |
| ce3-discovery-only-visible | D87 | 1 / 1 |
| ce4-vendor-revision-current | D87 | 1 / 2 |
| ce5-handoff-traversal | D88 | 1 / 2 |
| ce6-host-only-installed-beta | P1-1 | 1 / 8 |
| ce7-one-review-at-a-time | D88 | 1 / 1 |
| ce8-refresh-before-match | D88 | 1 / 1 |
| ce9-alias-resolution | D88 | 1 / 1 |
| ce10-system-application | D88 | 1 / 1 |
| ce11-appex-signed-sandboxed | D88 | 1 / 1 |
| ce12-embed-only-installed-beta | P1-1 | 1 / 1 |
| ce13-menu-requires-host | P1-1 | 1 / 1 |
| ce14-no-url-scheme | P1-2 | 1 / 1 |
| ce15-queue-bound | P1-2 | 1 / 2 |
| ce16-rejection-bound | P1-2 | 1 / 2 |
| ce17-coalesce-refresh | P1-2 | 1 / 4 |
| ce18-sanitize-name | P1-2 | 1 / 4 |
| ce19-fs-resolution-off-main | P1-2 | 1 / 2 |
| ce20-cold-launch-queues | P1-3 | 1 / 1 |
| ce21-attach-presents | P1-3 | 1 / 2 |
| ce22-related-cleanup-wait | P2 | 1 / 2 |
| ce23-high-value-bulk | 高价值数据 | 1 / 2 |
| ce24-unmeasured-group | P2 共享组 | 1 / 2（C 组单独） |
| ce25-shared-vendor-folder | P2 厂商目录 | 1 / 11 |
| ce26-app-must-be-directory | P1-2 | 1 / 1 |
| ce27-open-documents-entry | P1-3 | 1 / 1 |

全部构建 exit 0。还原后最终重建并复跑定向 21 类全绿（见上表）。日志：scratch 下 `r1-ce-*.log`、`r1-ce-group{A,B,C}-build.log`。

### 实机验收清单（留给主会话，本批未做）

1. `script/build_and_run.sh --beta --install` 后：`/Applications/测试版.app/Contents/PlugIns/StorageCleanerFinderExtension.appex` 存在；`plutil -p /Applications/测试版.app/Contents/Info.plist | grep -c CFBundleURLTypes` 为 0；`/tmp/storage-cleaner-beta-dist` 等副本里虽有扩展，但不应出现第二个可用菜单。
2. `script/build_and_run.sh --bundle-only`（正式版 ID）产物没有 `Contents/PlugIns`。
3. 在“系统设置 › 通用 › 登录项与扩展 › 访达”启用扩展（或 `pluginkit -e use -i com.local.StorageCleanerMac.beta.FinderUninstall`）；`pluginkit -mAvvv -p com.apple.FinderSync` 确认只登记 `/Applications/测试版.app` 下那份（若登记了 `/tmp` 副本，菜单也不应出现）。
4. 在访达选中一个可卸载的第三方应用（不执行卸载，只看审阅表后点“关闭”）：测试版**已运行**时，右键出现“用存储清理助手卸载”，点击后主窗口来到前台、切到“卸载”页、打开该应用的审阅表，关联项全部未勾选。
5. **冷启动**：退出测试版后重复第 4 步，确认应用启动后只有一个主窗口，且审阅表能打开（验证 `application(_:open:)` 在 SwiftUI 下收得到、请求没有丢；若没打开窗口或丢请求，记录现象）。
6. 已打开主窗口时再次右键：不新开第二个主窗口。
7. 多选 3 个应用（含一个系统应用如“计算器”、一个文本文件）：只有可卸载的依次进入审阅（关闭一个才开下一个），最后出现标题“部分项目未进入卸载审阅”的提示框，列出被拒项。
8. 选中非应用（只有文件夹/文档）时没有菜单项。
9. 把一个 `.app` 拖到测试版 Dock 图标、或“打开方式 › 测试版”：只打开审阅表（Dock 可能因未声明文档类型而不接受拖放，记录即可）。
10. 有 Chrome 或 Docker 时（不执行卸载）：审阅表中档案/容器行显示“含个人资料”/“含镜像与数据卷”，“全选已核实项”不勾它们；微信/Telegram 的共享组容器行显示“大小未知”，且没有出现“访问其他 App 的数据”系统弹窗。

### 残余

- SwiftUI 对 `application(_:open:)` 与 `handlesExternalEvents` 的实际行为、沙盒扩展里 `NSWorkspace.open(_:withApplicationAt:)` 能否交付文件 URL，只能实机确认（清单第 4–6 项）。
- 安装到 `~/Applications/测试版.app` 时不出菜单（有意）。
- `make_release_dmg.sh` 仍未接入扩展；正式版要提供入口需另开批次，并按“只认安装位置宿主”同样处理。
- 规则表中标“未核验”的 Team ID 与 JetBrains Bundle ID 仍待本机核对（首版第 4 节第 6 项）。
