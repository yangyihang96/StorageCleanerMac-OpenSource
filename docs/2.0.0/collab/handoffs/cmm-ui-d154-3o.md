# 交接：D154 第三批 O（智能扫描起始页第一次显示“欢迎使用…”）

日期：2026-10-22。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `d1caab95`（v2.0.1 合并第三批 N 后的树，D154⑯）。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 用户要求

用户原话（10-22）：“接下来做智能扫描起始页第一次显示“欢迎使用…”标题。”

## 2. 依据

- 逆向记录（`CMM模块规格.md` 智能扫描·起始页）：平时标题是模块名；另有一套“Welcome to CleanMyMac”和“Welcome back!”两个标题，配一句开始说明。【推断】第一次和回访时替换标题。
- 第三批 J 的图位清单最后一行：首次引导结束后进入智能扫描起始页，第一次显示“欢迎使用…”标题，图用现有的 `module-smartscan`。

## 3. 改了什么

- **第一次的起始页**：标题“欢迎使用存储清理助手”／“Welcome to Storage Cleaner”（产品名取 `L10n.productName`，与首次引导第 1 屏同一写法）；副标题换成我们自己写的一句“选好要检查的内容，点“扫描”，看看有哪些可以整理。”／“Choose what to check, then click Scan to see what can be tidied up.”，不是 CleanMyMac 的原句；中文在常规窗口里一行放得下。图、5 条模块、状态行、安全说明和圆按钮都不变。
- **“第一次”怎么算**：扫描历史里没有记录（老版本扫过的也算），并且从没开始过智能扫描。第一次真正开始智能扫描时（至少选了一项）记下来，此后起始页回到“智能扫描”和模块原来的副标题；开始过的用户以后清空扫描历史，也不会再看到欢迎。
  - `SmartCareCoordinator` 新增 `@Published hasStartedScan`，存在 `smart-care.has-started-scan`，和模块选择用同一个偏好域（`store.smartCarePreferences`）；`start()` 通过检查后，第一次时写入。
  - `SmartCareLandingView.welcome(latestStatus:hasStartedScan:)` 决定标题和副标题。只用在新版起始页，经典（D70）起始页不变。
- **没做**：CleanMyMac 回访时的“Welcome back!”（这次只要第一次）。首次引导第 1 屏的标题本来就是“欢迎使用…”，新用户会先后看到两次，保持现状。

## 4. 建议的 DECISIONS 行

| # | 决定 | 影响 |
|---|---|---|
| D154⑰（编号由 2.0.1 会话定） | 智能扫描起始页第一次（扫描历史为空，且从没开始过智能扫描）显示“欢迎使用存储清理助手”和一句开始说明；第一次开始智能扫描时记下（`smart-care.has-started-scan`），以后显示模块标题。回访的“欢迎回来”不做。 | 智能扫描 |

## 5. 测试

- `SmartCareTests` 新增 2 个（非窗口）：
  - `testTheFirstScanIsRemembered`：新偏好域里为假；什么都没选时 `start()` 不算；选一项开始后为真，新建的 coordinator 从同一偏好域读回来也为真。
  - `testTheLandingGreetsAFirstVisitOnly`：没有历史且没开始过 → 欢迎标题（带产品名）和一句不同于模块原副标题的说明；开始过 → 没有；历史里有一次扫描 → 没有。
- `CareStudioWindowReviewTests`：圆按钮那条测试多了“扫描过后的起始页”（`smartscan-landing-again`）。原来的 `smartscan-landing` 现在就是第一次的样子（测试的 store 用独立偏好域，历史为空）。两种起始页在四种窗口尺寸下，标题、状态行、图都不碰圆按钮、不出窗口。截图多一张 `w19-smartcare-landing-again`。
- 原有测试的期望没改。

## 6. 验证

全部在 Xcode 27.1、`d1caab95` 加本批改动上：

- debug 编译通过；release 编译、release 测试目标（`--build-tests -Xswiftc -enable-testing`）编译通过，本批文件无警告。
- 非窗口全量（10-22 11:17–11:25）：XCTest 5545 个（比第三批 N 多的是 `d1caab95` 新增的 SpaceMap 测试和本批 2 个），27 个跳过，1 个失败：`MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`（`BenchmarkKernelError.resourceLimit`，跑满 15 秒）。改副标题之前的那次全量（11:05–11:11）也只有 1 个失败，是另一个：`SystemEnergyACTelemetryTests.testTheLocalSystemLoadOnExternalPower`（当时整机负载 81.8 W，超过适配器输入 60.8 W 加电池 0.8 W 再加容差，交叉校验不给读数）。这两个都读本机硬件或计时，当时 release 编译和窗口测试同时在跑；13:17 机器空下来后单独重跑，两个都通过（整机负载 33.46 W）。swift-testing 135 个通过。
- release 下的非窗口测试（12:45–13:17）：XCTest 5292 个 0 失败（26 个跳过），swift-testing 135 个通过。
- 窗口全量 626 个（虚拟屏 2，11:17–11:38，先拿了 `virtual-display-2.lock`，跑完即释放；开了截图目录）：失败 40 个，全部在 27.1 基线的 43 个之内，没有新增失败。基线里另外 3 个这次通过了：`PhotoLibraryTests.testProductionSourceHasOnlyAlbumAdditionAndLocalSmallThumbnailRequests`、`ResidentStartupScheduleTests` 的两个（这两个测试文件在 `d1caab95` 里有改动，本批没碰）。两个出截图的测试这次运行并通过，所以没有跳过项（基线那次跳过 2 个）。
- 早先一次只跑起始页相关的 5 类窗口测试（11:05–11:15，改副标题之前）：81 个，只有基线里的 `SafeCleanupLayoutTests.testMiniSettingsPreviewStaysWithinNarrowViewportAndActionsRemainVisible` 失败。
- 截图核对（测试窗口里真实绘制）：中文深色、中文浅色、英文深色的第一次和扫描过后。中文标题和副标题各一行；英文标题折成两行（“Welcome to / Storage Cleaner”），副标题两行。圆按钮那条测试在 1500×960、1024×734、604×490、473×360 四种尺寸下，两种起始页都没碰圆按钮、没出窗口。
- 未核对：没装测试版，没在真实 app 里从首次引导一路走到起始页；记下“开始过”写进真实偏好域这一步，只在测试偏好域里由单元测试覆盖。

## 7. 下一步

- 回访的“欢迎回来”：用户 10-22 决定先不做（原话：“回访的“欢迎回来”先不做，起始页保持现在这样。”，据 CMM 会话转述）。
