# 交接：D204（报告第四节第 19 条）首页类别只写名字

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话合并树 `9ba4a562`（含 Codex D195）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求和依据

报告原文：“首页类别：CleanMyMac 每个类别只写名字（cmm/01–08）；我们每个类别下面多一行说明（ours/05）。保留还是去掉，待定。”

用户 10-24 在本会话决定，原话：“第 19 条去掉首页各类别下面的说明行，只写名字，照 CleanMyMac。”

CleanMyMac 实测（`1比1对照-20261023/cmm/01`、`05`，窗口 1200×720 点，按像素量）：

- 每行一个约 29 点的图标，旁边写名字，约 17 点半粗，名字和图标之间约 20 点；
- 每 52 点一行，名字下面没有说明。
- 云盘清理（`cmm/08`）是另一种版式（“Connect iCloud”等连接按钮），因为它要登录第三方云盘。我们不接第三方账户（D154），所以云盘页仍用列表，同样只写名字。

## 2. 改了什么

### 列表行（`Views/CareStudio/CareStudioHero.swift`、`CareStudioTheme.swift`）

- `CareStudioBullet`：
  - 新增 `hint`：这一行涵盖什么，只给读屏（`accessibilityHint`），不显示；
  - `detail` 仍在，只用于名字下面的读数：内存页的内存压力、已用内存、文件缓存、交换。模块首页不再传它。
- `CareStudioBulletRow`：
  - 图标和名字之间 14 → 20 点；
  - 图标里的符号 13 → 14 点。
- 尺寸（`CareStudioMetrics`）：
  - 名字 15 → 17 点（`bulletSize`）；
  - 图标 26 → 28 点（`bulletIconSide`）；
  - 新增 `bulletNameSpacing` = 24：只有名字时，每 52 点一行，和 CleanMyMac 一样；
  - 带读数的行仍用 `bulletSpacing` = 18。

### 各首页

| 首页 | 原来名字下面的说明 | 现在 |
|---|---|---|
| 智能扫描（`MainWorkspaceViews.swift`） | 每个模块查什么（`module.scope`） | 改为读屏提示 |
| 垃圾清理（`ContentView.swift`，4 个开关） | 每个开关涵盖什么（`FeatureLightfieldCleanupScopeRow.detail`） | 改为读屏提示；开关本身、勾选和存取不变 |
| 应用管理（`CareStudioApplications.swift`） | 卸载程序、应用更新、残留清理各一句 | 改为读屏提示 |
| 云盘清理（`CareStudioCloudCleanup.swift`） | iCloud 是否启用、本机副本怎么处理、其他云盘是否设置 | 改为读屏提示 |

- 云盘页：“这台 Mac 没有启用 iCloud 云盘”原来是 iCloud 那一行的第二行。没有它，扫描按钮变灰时就没有解释，所以挪到列表下面的状态行（`CloudCleanupPresentation.landingStatus`），只在 iCloud 没启用时出现。
- 开发者垃圾、登录项的首页原来就没有说明行，不变。
- 内存页（“我的工具 › 内存管理”）名字下面是实时读数，不是说明，也不是 CleanMyMac 的模块首页，保留。它的名字和图标跟着变大，行距仍是 18。

## 3. 测试

- `CloudDriveD185Tests`：两处断言原来查 `detail`（“已在这台 Mac 上设置”“没有发现其他云盘文件夹”），改为查 `hint`，并断言 `detail` 为空。测试里写了“D204＋旧断言＋原因”。
- 新增 `LandingNamesOnlyTests`（非窗口）：
  - 云盘首页在 iCloud 开或关、有没有其他云盘的四种情况下，都只有名字，每行都有读屏提示；
  - iCloud 没启用时出现状态行，启用时没有；
  - 名字 17 点，图标加行距等于 52 点。
- 窗口类不用改。会经过这些首页的窗口类交主会话的窗口全量：CareStudioWindowReviewTests 的首页截图、文字与按钮不重叠检查等。

## 4. 验证

Xcode 27.1。树是 `9ba4a562` 加本项，在 heavy 锁里增量编译，10-24 11:56–11:59。

- 非窗口定向 7 个类，132 个测试，0 失败：LandingNamesOnlyTests（新增）、CloudDriveD185Tests、CareStudioModuleShellRenderTests、CareStudioRenderReviewTests、UIConsistencyRegressionTests、SmartCareTests、PrivacyCleanupPresentationTests。
- 静态检查（在 D202 的最终树上跑）：窗口类登记（D106）、删除与进程清单、私有 API 都通过；改到的源码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项。
- 截图核对（`~/Developer/.sc-build/cmm-ui-items-evidence/d20x/`）：
  - `apps-landing-*`、`01-smartscan-landing-*`、`02-cleanup-landing-*`：类别只有名字，每 52 点一行；
  - 垃圾清理首页仍是 4 个开关，右边带勾。
- 没跑的：会经过这些首页的窗口类交给主会话的窗口全量（CareStudioWindowReviewTests 的首页检查与截图、DesignSystemV2ReviewTests、FeatureLightfieldContractTests）。
- 没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| D204 | 模块首页的类别只写名字，照 CleanMyMac（用户 10-24 定，原话“第 19 条去掉首页各类别下面的说明行，只写名字，照 CleanMyMac。”）：名字 17 点、图标 28 点、每 52 点一行；原来的说明改为读屏提示；云盘页“没有启用 iCloud 云盘”挪到列表下的状态行；内存页名字下的实时读数保留。 | 智能扫描、垃圾清理、应用管理、云盘清理首页；内存页字号 |
