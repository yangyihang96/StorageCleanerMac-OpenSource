# 交接：D154 第三批 J（首次引导改为 CleanMyMac 式三屏；设置页签用自己的图）

日期：2026-10-22。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `3e80165f`（= 第三批 I 结果树 `a1fbc5d8` ＋ 2.0.1 会话的 D166② 图补丁 `D166b-art-blender.patch`，sha256 `2e90ec21…`；v2.0.1 的树另多 DECISIONS.md 的记录，本批不碰 DECISIONS）。未提交、未安装、未推送。

## 1. 用户要求

同前（全界面照 CleanMyMac；都有的功能 1:1；缺图就做、不要满屏文字）。首次引导在原清单 F 里；图由 2.0.1 会话按本会话的图位清单（`CleanMyMac全界面逆向-2026-10-20/图位清单-首次引导与设置页签.md`）做好，为 D166②。

## 2. 改了什么

- **首次引导**（`FirstLaunchOnboardingView`）：原来是一页三张权限卡（只有文字和按钮），改成 CleanMyMac 的引导流程，三屏，铺智能扫描颜色的渐变：
  1. 欢迎：大图 `onboard-welcome`，“欢迎使用存储清理助手”，一句安全说明（每一步由你确认，不保存管理员密码）。
  2. 扫描访问：大图 `onboard-diskaccess`（授权后换成 `state-success`），权限名和“必需”、状态、用途、系统设置路径、三个按钮（打开系统设置、只选择文件夹、重新检查）。
  3. 按需开启（我们有、CleanMyMac 没有）：系统控制组件、完成通知两张卡，卡上分别是风扇 `tile-systemcontrol` 和铃铛 `tile-notifications`。
  - 底部：圆按钮（开始 / 继续 / 完成，回车触发）；左边“暂不设置”（CleanMyMac 的 Skip for Now，第 3 屏没有）；右边步骤点（读屏读“第 N 步，共 3 步”）。
  - 都没变：三项权限的要求、状态、说明、路径、按钮和动作，助手的安全说明，弹出时机（`FirstLaunchOnboardingPolicy`）、完成后的处理（ContentView 不变）。按钮从系统样式换成渐变上的胶囊按钮（`CareStudioPillButton`）。
  - 按 D64：每屏只放一张主图（D64 保留主插画）；承诺行和标签前不放装饰小图标，不写没有依据的“好处”说明；不用 SF 符号，不用循环动画。
- **渐变背景**：`CareStudioBackdrop` 加 `fillsOwnFrame`。引导是弹出的面板，按面板自己的大小铺渐变，不上报主窗口尺寸，也不跟着主窗口漂移。
- **设置页签**：原来借模块图（`artworkModule`，雷达、芯片、扫帚盾、地球、心形、文件分析），改成每页自己的图（`SettingsCategory.tabArt`）：通用 `tile-general`、小窗 `tile-miniwindow`、扫描与安全 `tile-scansafety`、权限 `state-permission`、系统控制 `tile-systemcontrol`、应用更新仍用 `module-updater`、关于用本 app 的图标。页头的图也一样（关于页照旧没有页头图）。设置窗口不转色，新图按 D166② 的最终颜色显示。
- **第三批 I 的旧值注释**（2.0.1 会话要求，只改注释）：`D64DeclutterAContractTests`、`UIConsistencyRegressionTests`、`SettingsLightfieldContractTests`、`SettingsLightfieldGeometryTests`、`SettingsSourceContractTests`、`AppResponsivenessTests` 里第三批 I 改过的期望都补了 “was …”。

## 3. 建议的 DECISIONS 行

| # | 决定 | 影响 |
|---|---|---|
| D154⑫（编号由 2.0.1 会话定） | 首次引导改为 CleanMyMac 式三屏（欢迎与安全说明、扫描访问、按需开启），智能扫描颜色渐变、每屏一张主图（D166②）、底部圆按钮加“暂不设置”和步骤点；三项权限的要求、状态、路径、动作和安全说明不变。设置页签改用每页自己的图（D166②），关于用 app 图标。 | 首次引导、设置窗口 |

## 4. 测试

- 新增窗口测试 `CareStudioWindowReviewTests.testFirstLaunchGuideKeepsEveryPageAboveItsButtons`：中英文三屏，内容和圆按钮都在面板里，内容在圆按钮上方，“暂不设置”和步骤点不压住圆按钮。截图测试加 `w18-onboarding-<屏>`（中文深色、中文浅色、英文深色）。
- `D64DeclutterAContractTests.testPermissionsKeepRequirementsPathsActionsAndSafetyWithoutArtwork` 只加了注释（每屏一张主图是 D64 保留的；下面列的装饰仍不许出现），断言没改，照旧通过。读屏文字起初写成 `.accessibilityLabel(L10n.text(…))`，碰上该测试对 `Label(L10n.text` 的字面检查，改成先算好字符串再传，测试本身没动。
- `keepsOwnColour` 没有加新图：新图只出现在设置页签、页头和引导卡片里，这几处都不转色；`CareStudioModuleShellRenderTests.testOnlyTheStatePicturesKeepTheirOwnColours`（D166：只有 4 张状态图保持原色）照旧。

## 5. 验证

工具链：本批先在 Xcode 27.0.0 测试版上验证。10-22 01:08 测试版被移进废纸篓，用户定改用 Xcode 27.1（D169），于是又在 27.1 上做了 release 编译和窗口全量。

- Xcode 27.0.0 测试版：
  - debug 编译通过。
  - 非窗口全量（10-22 00:4x–00:54）：XCTest 5473 个 0 失败（27 个按设计跳过），swift-testing 135 个通过。
  - 窗口全量 626 个（含新增的首次引导测试；虚拟屏 2，00:57–01:11）：失败集合与基线逐条相同（43 对 43）。这一轮在测试版被移走前已编好，测试进程跑完了全部用例。
  - release 编译在 01:08 链接时因工具链被移走而中断（unable to spawn swiftc），不是代码问题。
- Xcode 27.1（27A9275，Swift 6.4）：
  - release 编译通过（01:11–01:37）。本批文件无警告；共 8 条警告，都在别的文件：原有 2 条 `init(cString:)` 弃用，`FileOperationShared/UpdateAskpassInvocationRegistry.swift` 第 12、13 行新报 2 条“`withLock` 的返回值没用到”（新编译器才报）。
  - 窗口基线：基线树 `3e80165f` 625 个，失败集合 43 个，与测试版下的旧基线逐条相同（`~/Developer/.sc-build/base27-window.failures.txt`）。
  - 本批窗口全量 626 个（虚拟屏 2，01:56–02:16）：失败集合比基线多 1 个，`MenuBarPublishLoopTests.testReplayedOlderConsumerDoesNotStealLatestPagePriority`。它不是断言失败，是收尾时删不掉自己的临时夹具（`TestFileSystem.swift:113`，NSCocoaErrorDomain 513 / POSIX EPERM，目录里只有 `Monitoring/MenuBarPowerHistory.json`，无不可改标志）。在 27.1 上单独重跑这个类三次，这个测试每次都通过，类的失败集合与基线相同（只有基线里的 `testChangedResidentSectionWithSamePendingStateDoesNotPublish`）；它在测试版的本批全量和 27.1 基线里也都通过。判断为偶发的环境问题，与本批改动无关；断言没动。
  - 非窗口全量：未在 27.1 上重跑（测试版上已全量通过；2.0.1 会话合并后会在 27.1 上跑完整一轮）。
- 截图核对（测试窗口里真实绘制）：首次引导三屏（中文深色、中文浅色、英文深色），设置页签（1180 宽、560 宽，中英文，深浅色）。截图方式不画色相旋转，所以大图在截图里是渲染原色（欢迎图和硬盘图本来就按色相约 293 渲染，差别很小）。
- 未核对：首次引导在真实 app 里的弹出和“完成”后的流转（ContentView 没改，靠代码审阅）；← → 和回车只做了代码审阅；“关于”页签的 app 图标在测试进程里显示成通用图标，装进测试版后才是本 app 图标。

## 6. 下一步

- 第三批 K：智能扫描改为 CleanMyMac 式 5 张模块卡（用户 10-22 已定，2.0.1 会话记为 D168），方案和“运行”范围另问用户。
- 推迟：智能扫描起始页第一次显示“欢迎使用…”（CleanMyMac 的 Welcome 标题）。很多窗口布局测试用的是没有扫描记录的起始页，换长标题会牵动这些测试；等第三批 K 改智能扫描页时一起做。
