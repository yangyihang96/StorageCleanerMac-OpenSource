# 交接：CleanMyMac 卸载器、应用更新与两类提醒的 1:1 复刻（2.0.1）

日期：2026-10-19。会话：Claude「CleanMyMac 卸载升级功能逆向」。工作树：`~/Developer/sc-worktrees/app-lifecycle`（分支 `task/app-lifecycle`，基线树 `e1fd99b0` = v2.0.1 工作区 2026-10-19 16:15 快照，含当时全部未提交改动）。未提交、未安装、未推送。

逆向规格与证据：`/Users/developer/Claude 好玩的/CleanMyMac卸载更新逆向-2026-10-19/逆向规格与差距清单.md`。集成用补丁：同目录 `app-lifecycle-vs-e1fd99b0.patch`（相对基线树 `e1fd99b0` 的全部改动，43 个文件；2026-10-19 18:50 对当时的 v2.0.1 工作区 `git apply --check` 通过，未实际应用）。

## 1. 做了什么

### 1.1 两类提醒（新）
- **拖进废纸篓的应用 →“以正确的方式彻底卸载应用程序”**。检测按反编译的 `+[CMTrashedAppsService applicationsToUninstallFromTrashURL:]`：递归废纸篓；不进入 `vmwarevm`、`photolibrary`、`aplibrary`；扩展名含 `app` 且有 `Contents/MacOS` 与 `Contents/Info.plist` 即为应用，不进入其内部。过滤按 `appExistsOutsideTrashWithURL:`（LaunchServices 路径在废纸篓外且可写，或 `/Applications/同名` 存在且可写 → 不提醒）。另外跳过本应用自己移入废纸篓的项目（回执日志里有的）。
- **废纸篓超过上限 →“是时候清倒废纸篓了！”**。默认开、阈值 2 GB（CleanMyMac 本机偏好实测值），档位 0.5/1/2/3/5/10/20 GB（CleanMyMac 档位数值未拿到，见 §4）。只计 `~/.Trash`（偏差，见 §3）。
- **忽略**：主按钮“忽略”= 一周；箭头菜单：一天、3 天、一周、直到明天（到本地午夜）、永久。拖进废纸篓的应用按每个应用（文件 URL）分别记；废纸篓容量一条全局记录。存 `Application Support/<渠道>/AppLifecycle/IssueIgnoreList.json`。
- **何时等**：本应用主窗口正在用、小窗打开、前台应用全屏、摄像头在用时推迟，条件消失后（每 4 秒复查）再弹。专注模式与屏幕录制没有公开接口，未观察。
- **弹出与动画**：菜单栏图标下方的无激活面板，淡入并下滑 10 pt（0.34 s），淡出上移（0.2 s）；图标外圈声呐扩散三次；内容变化时面板高度动画；“减少动态效果”时全部瞬时。
- **清倒废纸篓**：卡片内保留 D23 两项确认（冻结清单，D101 L5），确认后走既有 `ScanHeavyWorkService.emptyTrash`（重任务租约、只删冻结条目），显示“正在释放…”，完成后对勾弹出、已释放数字滚动、播放访达清倒废纸篓音效，2.6 秒后淡出。
- **卸载…**：打开主窗口卸载页，进入“程序残留”分类，列出这些应用留下的文件（全部勾选），确认后移入废纸篓（带回执）；完成后把这些应用记为已处理，不再提醒。
- **设置**：设置 → 扫描与安全 →“应用与废纸篓提醒”：两个开关、阈值、当前废纸篓大小、重置忽略列表。

### 1.2 卸载器（重写结果页）
`AppUninstallerView` 结果区换成 `ApplicationsManagerView`（首次扫描仍是原来的落地页）。界面仍是 D67 结果页骨架：摘要（可审阅总量、应用数）→ 工具栏（搜索、分类菜单、排序、更多）→ 已批准表头（应用 / 版本、应用路径、可审阅大小）→ 共享结果视口里的懒加载行，金额沿用 D70 的十进制存储单位。CleanMyMac 的左侧分类栏在这里是工具栏的分类菜单（带各类数量）；行是“勾选框＋图标 / 名称与版本 / 路径 / 大小＋展开箭头”，展开后按资源组列出全部项目，组和项目各自可勾选、可在访达中显示；行右键菜单保留“复制路径”“在 Finder 中显示”。管理器按 ScanStore 各建一个（`ApplicationsManagerModel.of(store)`），演示/截图夹具（`featurePresentationIsFixture`）里不读包、不扫 Library、不查 Spotlight。
- **扫描结果概览（CleanMyMac 磁贴）**：每次应用清单扫描结束后先显示（移除完成后“管理更多项目”触发的重扫除外，回到列表），也可从“更多 → 扫描结果概览”打开：可用更新、未使用应用、应用残留、安装文件、32 位应用、macOS 更新、“建议卸载”，“管理我的应用程序”进入列表。磁贴主按钮只处理该磁贴的项目，同样经过退出应用步骤与回执。
- **分类**：所有应用程序、未使用（超过 6 个月未打开；无记录时用安装时间）、可疑项、勾选的；商店（App Store、Setapp、Steam、Battle.net、其他）；提供商（Apple、Google、Microsoft、Adobe、JetBrains、MacPaw、其他，按 Team ID 再按标识前缀）；插件（音频插件）；其他（32 位、程序残留、安装器）。排序：名称、大小、上次打开、上次更新。
- **资源组**（CleanMyMac 的 15 组）：二进制、偏好设置、支持文件、缓存、日志、系统崩溃、容器、插件、登录项、程序坞图标、帮助、安装器、用户数据、其他。查找器 `ApplicationResourceFinder` 对应 CleanMyMac 的约 20 个 Fetcher：标识/内嵌辅助程序标识/应用组/launchd 引用/程序坞/可执行文件名/按词匹配应用名。安全闸：路径任一段是符号链接即排除（不解析）；`ProtectedLocations` 一律排除；不进入其他已安装应用；更长的已安装标识（`com.x.App.Pro`）拥有的项不算；共用厂商应用组在同厂商还有其他应用时不算。
- **勾选规则（CleanMyMac）**：勾应用 = 勾上它找到的全部可移除项；只取消“二进制文件”= 重置；受保护的系统应用只能重置。**这取代 D1**（见 §3）。
- **正在运行的应用**：弹窗“一些应用程序应该退出。”，每行关闭/强制退出/忽略，底部全部退出、忽略并继续。被忽略的应用不移除（“跳过（应用正在运行）”，沿用 D93 用词）。
- **执行**：先停止该应用自己的用户 LaunchAgent（`launchctl print`/`bootout`，系统域只列不动）；应用本体走既有回收器，失败时走既有管理员授权路径；其余项目逐个移入废纸篓；每项移动前再核身份；每个应用一份回执，可从“操作记录”恢复。程序坞图标从 `persistent-apps` 移除并让程序坞重开。
- **卸载自己**：CleanMyMac 同款确认（“不卸载/卸载”），成功后退出。
- **完成页**：“完成！/清理完毕！/移除失败...”＋说明，按钮“应用程序日志”“管理更多项目”；完成音效。
- **Finder 右键“用存储清理助手卸载”**：直接请求改为在管理器里选中该应用（全部项），从“操作记录”续做残留仍用原审阅单。

### 1.3 应用更新（补差）
- “打开应用内更新”“在 App Store 中更新”先弹 CleanMyMac 的说明（`popover_update_app_manually_text`：“由于该应用程序的限制，无法通过存储清理助手进行此项更新。请通过该应用程序本身进行更新。”；`popover_update_mas_app_manually_text`），点“打开”才执行原来的动作。项目原有的安全设计不变：退出并更新只请求正常退出、不强制结束；App Store 只打开公开页面、不自动操作；官网/Homebrew 入口照旧。
- Sparkle 发布清单解析 `pubDate`、`description`（含 CDATA，转纯文本，不跟链接）→ 详情区“发布日期/发布说明”。
- “有 macOS 的可用更新”卡片：读 `/Library/Preferences/com.apple.SoftwareUpdate.plist` 的 `RecommendedUpdates`；“查看更新”弹层文案照 CleanMyMac，按钮打开系统设置的软件更新。
- 完成通知文案改为“更新任务已完成！…点击以查看您的应用程序更新结果。”（保留成功/失败/取消数）。

## 2. 文件
新增：`Features/AppLifecycle/Trash/{TrashedApplicationsDetector,TrashSizeMeasurer,TrashFolderMonitor}.swift`、`Features/AppLifecycle/Reminders/{AppLifecycleIgnoreList,AppLifecycleReminderPreferences,AlertEnvironmentWatcher,AppLifecycleReminderCenter}.swift`、`Reminders/UI/{AppLifecycleAlertPanelController,AppLifecycleAlertCard,AppLifecycleReminderSettingsSection}.swift`（设置分区放在这里而不是 `Views/Settings/`，因为 `SettingsSourceContractTests` 固定了那个目录的文件清单）、`Features/AppLifecycle/Uninstaller/{ApplicationResourceModels,ApplicationProfileReader,ApplicationResourceFinder,ApplicationClassification,ApplicationTerminator,ApplicationRemovalService,LeftoverAndInstallerScanners,ApplicationsManagerModel}.swift`、`Views/ApplicationsManager/{ApplicationsManagerView,ApplicationsManagerSheets,ApplicationsOverviewView}.swift`、`Features/AppUpdates/Views/{SystemUpdateAvailableCard,ManualUpdateExplanation}.swift`。
改动：`App/StorageCleanerMacApp.swift`（启动提醒中心一行）、`Views/SettingsView.swift`（一行）、`Views/SystemUtilitiesView.swift`（只换 `AppUninstallerView`）、`Features/AppUpdates/Views/AppUpdatesView.swift`（系统更新卡片一行；详情区两个按钮先弹说明，加一个 `@State`）、`Providers/SparkleAutomaticUpdateAdapter.swift`、`Providers/SparkleProvider.swift`、`Coordination/ApplicationUpdateNotificationService.swift`、`script/deletion-process-inventory.txt`（4 条）。
测试：新增 `AppLifecycleReminderTests`、`ApplicationResourceFinderTests`、`ApplicationsManagerTests`；随新管理器更新的合约测试 `SystemUtilitySafetyTests`、`UIConsistencyRegressionTests`、`UtilityPresentationPerformanceTests`、`FeatureLightfieldApplicationPresentationTests`、`OwnedUIFlatteningContractTests`、`PermanentDeletionInvariantTests`（`.emptyTrash(frozen,lease:` 允许出现在提醒中心，并断言它前面有两项确认的守卫）；窗口类（D106）`FeatureLightfieldContractTests` 三处、`FeatureLightfieldApplicationP2Tests` 一处改了期望并注明 D151 与旧值：源码约束改指向 `ApplicationsManagerView.swift`；“行选择不打开预览”改为“按行勾选/取消、不打开预览、不开始移除，有勾选时主按钮才可用”（旧：单选，主按钮“卸载所选”打开预览）；两个直接托管卸载页的布局测试加 `featurePresentationIsFixture`，保持不读磁盘。

## 3. 与既有决定的关系（用户 2026-10-19 已确认 D151）
- **D1（卸载默认只选应用本体）→ 改为 CleanMyMac 规则**：用户本次要求“逻辑、步骤、功能全部 1:1 复刻”。仍全部移入废纸篓、每项有回执、可恢复。用户 2026-10-19 确认原话：「接受 D14x：卸载时按 CleanMyMac 规则默认勾上应用和找到的全部相关项目（都移入废纸篓、可恢复）。」（D14x 是草稿编号，主会话分配为 D151。）
- **残留只读线索（ResidualFileEvidenceView 的设计）→ 改为可选可删的“程序残留”**：只收 Library 里形似 Bundle ID、无已安装或已登记应用的项，排除 `com.apple.` 等；默认全选（CleanMyMac）。
- **D23 保留**：清倒废纸篓仍需两项确认。
- **偏差**：可疑项不按证书国家判定；废纸篓容量只计 `~/.Trash`；系统域项目（`/Library`）本版只列不动；“重要更新”（MacPaw 服务器）、快捷指令意图、小窗里的“废纸篓”卡片未做。

## 3.1 主会话审阅后的三处修正（2026-10-19 晚，预合工作树 `integration`）
- **启动项**：`unload(label:plist:)` 先 `launchctl print gui/<uid>/<label>`，只有输出里的 `path =` 等于要移走的那个 plist 才 bootout；不一致（标签被别的 plist 的任务占用）或标签以 `com.apple.` 开头时保留，记“未能确认此启动项属于该应用，已保留”，plist 不移动。`launchctl` 注入点改为返回状态和标准输出。
- **程序坞**：`DockTileEditing.removeTiles` 返回实际移掉的图标（没有可移的返回空，写不进偏好返回 nil）；已不在程序坞中的图标只记一行“已不在程序坞中”，不计入移除数。
- **应用组**：除名字含本应用标识外，只有本厂商的组（以本应用 Team ID 开头，或名字含本厂商标识前缀）且没有同厂商的其他已安装应用时才算本应用的；别家厂商的共享组（如 `group.com.othervendor.shared`）只列出、不可勾选，注“可能与其他应用共用，已保留”。
- 测试：`ApplicationsManagerTests.testLaunchItemIsStoppedOnlyWhenLaunchdNamesThisPlistAndAbsentDockTilesDoNotCount`（新增），`ApplicationResourceFinderTests.testSharedVendorGroupIsSkippedWhileAnotherVendorAppIsInstalled` 加断言。

## 4. 未知与待办
- CleanMyMac 运行观察未做（LCU 控制 CleanMyMac 需用户在审批面板批准）：弹出位置与动画时长、阈值档位、各页面细节待截图核对。
- 待做：系统域项目（LaunchDaemons、PrivilegedHelperTools、`/Library/Application Support`、回执）经特权助手移除；小窗“废纸篓”卡片（与主会话的小窗改动协调）。
- 集成时决定：卸载页换成管理器后，以下生产代码已无生产调用，只剩测试或调试夹具在用——`AppUninstallListPresentation`（及 `AppUninstallListFilter`、`AppUninstallSortMode`）、`ResidualFileEvidenceView`、`FeatureLightfieldUninstallList`（`FeatureLightfieldResultFixture` 和两个组件测试在用）、`SystemUtilitiesView` 里早已不用的 `InstalledAppRow`。D151 获批后可一并删除并改相应测试；本会话没有动这些共用组件。

## 5. 验证（2026-10-19，工作树 `app-lifecycle`，均未安装、未提交）
- **严格并发**：`swift build -Xswiftc -strict-concurrency=complete` 通过，新增和改动的文件无警告。
- **verify.sh 里的守卫**：窗口类清单检查、Views 不启动进程、源码无删除/提权命令串、私有 API 清单、删除与进程清单（160 条）、无冲突副本、`git diff --check` 全部通过。
- **非窗口全量**（跳过 D106 窗口类，最终代码）：5313 项，跳过 24，失败 1：`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`（15 秒上限超时；负载约 14 时单独重跑仍超时，同一测试在基线构建上同样 15.02 s 超时，即 BOARD N10，与本改动无关，需空闲时重跑）。
- **窗口类（虚拟屏 1 · Codex，`script/run_display_bound_tests.sh`）**：受影响的 17 类，除下列与 v2.0.1 基线（改动前快照 `e1fd99b0`，同屏同时段对照）完全相同的 12 项外全部通过：`FeatureLightfieldApplicationP2Tests` 2 项、`FeatureLightfieldApplicationPageTests` 3 项、`FeatureLightfieldContractTests.testProductionPilotsKeepNativeSkeleton…`、`FeatureLightfieldResultSpaceTests` 3 项、`SettingsLightfieldGeometryTests` 1 项（都是 1680×1050、2400×1350 窗口在这块屏上放不下，“frames did not settle”）、`SafeCleanupLayoutTests` 2 项（小窗预览 301 vs 304 是 D118 改宽度后窗口类未同步）。因为骨架测试在大尺寸处中途抛错、从未走到卸载结果页，另用临时用例在 5 种放得下的尺寸、深浅两套配色下对卸载结果页跑了 `assertCompactResultSkeleton`，全部通过（临时用例已删除）。
- **离屏渲染自查**（临时用例，已删除）：新卸载页（列表、展开资源、窄窗口、概览磁贴，深浅色）、正在退出的应用、移除进度、提醒卡片 7 种状态、更新说明弹层；据此去掉了列表底部重复的选择汇总、卡片在非活跃面板里主按钮变灰、清倒步骤底部多余的分隔线，声呐波纹最大缩放 1.9 → 1.6。

### 5.1 测试版安装（用户 2026-10-19 要求“把这版装到 /Applications/测试版.app，我亲自试一遍”）
- 19:21 安装 2.0.1 build `20261019080930`（Beta 配置，BuildInfo commit `6e660a59f7b6`、dirty），源为本工作树（= 16:15 的 v2.0.1 快照 + 本线改动，不含主会话 16:15 之后的改动）。命令：`STORAGE_CLEANER_SKIP_TESTS=1 SWIFT_BUILD_DIR=/tmp/storage-cleaner-beta-build-applifecycle DIST_DIR=/tmp/storage-cleaner-beta-package-applifecycle BETA_DIST_DIR=/tmp/storage-cleaner-beta-dist-applifecycle script/build_and_run.sh --beta --install`。跳过的是脚本自带的完整门禁（Release 配置全量测试、菜单栏性能测试）：Debug 全量与窗口类刚跑过，而 Release 全量在当时负载下必然卡在 N10；签名、架构、更新源和 BuildInfo 检查照常执行，`codesign --verify --deep --strict` 通过，访达扩展已注册。
- 风扇辅助进程在测试版本体未运行时仍常驻（10-18 15:48 起，pid 545），`--no-launch` 会拒绝，所以用默认安装路径（不发信号、不 bootout）。安装后旧进程自行退出（launchd 记 last exit code 1），新进程 pid 25634 运行的是新二进制（inode 一致）；测试版近 15 分钟日志无错误。Mac mini 模式或手动风扇控制若原本开着，需在测试版里确认仍生效。
- 被换下的 10-18 版（build `20261018035540`）安装前已完整备份到 `~/Developer/StorageCleanerMac-beta-backups.noindex/20261019T080917Z-applifecycle/测试版.app.previous`（签名校验通过）；脚本默认路径会删除它在 /Applications 的临时备份，所以先另存了这一份。

## 6. 建议写入 DECISIONS 的条目（用户 2026-10-19 已确认；编号由集成方按 D141 之后的空号分配）

| # | 决定 | 取代 | 影响 |
|---|---|---|---|
| D151 | 2.0.1：卸载器、应用更新补差与两类提醒照 CleanMyMac 5.7.2（静态逆向＋其偏好与 `IssueIgnoreList.db` 的只读副本，未控制其界面）1:1 复刻逻辑和步骤，界面用本应用的光场样式。**卸载勾选**：勾应用＝勾上它找到的全部可移除项，只取消“二进制文件”＝重置，受保护系统应用只能重置；一律移入废纸篓，每个应用一份回执，可从“操作记录”恢复，被忽略的运行中应用不移除（D93 用词）。**程序残留**改为可选可删分类：只收 Library 中形似 Bundle ID、没有已安装或已登记应用的项，排除 `com.apple.` 与 `ProtectedLocations`，默认全选。**提醒**：拖进废纸篓的应用、废纸篓超过上限（默认开，2 GB，只计 `~/.Trash`）；本应用主窗口或小窗在用、前台全屏、摄像头在用时推迟；忽略一周（菜单：一天、3 天、一周、直到明天、永久），记录存本地 JSON。**清倒废纸篓**仍是 D23 两项确认＋D101 L5 冻结清单，提醒中心是扫描页之外第二个调用 `emptyTrash(frozen,lease:)` 的地方。**系统域**（`/Library` 下）项目本版只列不动。**主会话审阅后加的三条**：用户启动项只在 `launchctl print` 回读的 path 等于要移走的 plist 时 bootout，`com.apple.` 标签一律不动，否则保留并注明；程序坞里已不存在的图标不计入移除数；应用组须名字含本应用标识，或属本厂商（以本应用 Team ID 开头或含本厂商前缀）且同厂商没有其他已安装应用，别家厂商的共享组只列不勾。 | D1（卸载预览默认只选应用本体）；残留只读线索（`ResidualFileEvidenceView` 不再用于残留分类，从“操作记录”续做残留仍用原审阅单） | 交接 `handoffs/app-lifecycle-cmm.md`；规格与证据 `/Users/developer/Claude 好玩的/CleanMyMac卸载更新逆向-2026-10-19/逆向规格与差距清单.md` |
