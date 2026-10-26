# 交接：报告第四节第 13 条（结果卡的两个按钮、性能页维护任务卡）

日期：2026-10-23。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树：第 12 条的结果树（最终树 `922203b6` 加第 12 条）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。编号请你定；维护任务卡这一半是 D188a，你说 DECISIONS 由你写。

## 1. 要求

- 报告原文（第四节第 13 条）：“CleanMyMac 每张可操作的卡有‘Review’加‘Clean／Remove／Run Tasks’两个按钮，智能呵护的结果卡还有勾选框（决定‘运行’时包不包括）；我们只有‘查看’。”
- 你 10-23 的补充：“请把性能页‘维护任务’卡一起做成 CleanMyMac 那样：标题写‘N 个维护任务推荐’（数量用现成的 ToolboxStores.of(store).maintenance.summary.recommendedCount，和智能扫描卡同一口径），按钮‘查看’＋‘运行任务’（运行只跑推荐且确认过的任务，沿用 D154⑮ 的确认流程）。对照：cmm/24 对 ours/04。”

## 2. CleanMyMac 什么时候给第二个按钮（实拍）

- 只在卡里有默认选中的项目时给：
  - 垃圾清理（cmm/20）：系统垃圾、邮件附件、废纸篓有“Clean”；AI 杂物、额外二进制只有“Review”。
  - 防护（cmm/22）：Chrome 临时文件、最近使用项目有“Remove”。
  - 性能（cmm/24）：维护任务卡有“Run Tasks”；登录项、后台项目只有“Review”。
  - 应用（cmm2/01）：更新有“Update”，残留有“Remove”；“建议卸载”和 404 MB 的安装文件只有“Review”。卸载器逆向时它的字符串表里安装文件卡也有“移除”，所以推测是有预选时才出现，这一点没有实拍证实。
- 智能呵护（cmm/14）：参与“运行”的三张卡（清理、防护、性能）左上有勾选框，卡上只有“Review”。

## 3. 逐页核对（第 12 条的结果树）

| 页面 | CleanMyMac | 我们现在 | 这一批 |
|---|---|---|---|
| 垃圾清理 | 有预选的卡“Review＋Clean” | 已有：有勾选项的卡“查看＋清理”，复核用的卡只有“查看”（第三批 C；D47 预选） | 不改。ours/02 只有“查看”，是测试版 #8 那次扫描的状态；窗口截图 `w06-cleanup-results` 里系统垃圾卡有“清理” |
| 智能扫描 | 三张卡有勾选框 | 已有：清理、性能两张卡有勾选框（第三批 K、L） | 不改。防护卡不参与“运行”（D186 每个结果都要用户自己选），所以没有勾选框 |
| 性能 | 维护卡“Review＋Run Tasks” | 只有“查看” | 做，见 §4.1 |
| 防护 | 隐私项“Review＋Remove” | 最近使用项目已有“移除”（D188）；浏览记录、Cookie 等数据、恶意软件默认都不选，只有“查看” | 不改 |
| 应用 | 更新、残留有第二个按钮；没预选的安装文件只有“Review” | 安装文件卡总有“移除”，没有预选时点了什么都不做 | 做，见 §4.2 |
| 云盘 | 没拍到 | 第二个按钮是“在访达中打开” | 不改 |

## 4. 改了什么

### 4.1 性能页的维护任务卡（D188a，`Views/SystemUtilitiesView.swift`）

- 卡片抽成 `CareStudioTileModel.maintenance(_:onReview:onRun:)`，页面里的 `maintenanceTile` 调它（`leadingTiles: [maintenanceTile]` 不变，接线测试照旧）。
- 标题：有推荐时“N 个维护任务推荐”，数量用 `summary.recommendedCount`，和智能扫描卡同一口径；英文单复数分开。没有推荐时仍是“维护任务”，只有“查看”。
- 按钮：
  - “查看”打开维护任务页，和原来一样；
  - “运行任务”只在有推荐时出现。点了先弹确认框，列出要跑的任务和每个任务会做什么，确认后才跑。
- 只跑推荐的：
  - 新加 `SystemMaintenanceStore.recommendedTasks`（只加）：推荐、而且现在能跑的任务（可在这里运行、没有阻碍），按列表顺序；
  - 点“运行任务”时取这一份，确认框列的就是它，确认后跑的也是它（D168：确认时列出的就是要跑的）；
  - 维护任务页上另外勾的任务不会加进来。
- 确认框沿用 D154⑮ 的 `maintenanceRunConfirmation`，加了一个可选参数 `tasks`：不传时和原来一样列勾选的任务；性能卡传推荐的任务，标题写“运行推荐的维护任务？”。维护任务页和智能扫描的调用都没改。
- 正在跑时按钮写“正在运行…”并变灰（不管是从这里、维护任务页还是智能扫描启动的）。跑完卡上一行小字说结果：“已运行 N 项，结果在‘查看’里”；有没完成的就写“N 项没有完成，原因在‘查看’里”。在维护任务页关掉结果，这行字也就没了。
- 跑任务拿的是清理租约，所以第 12 条性能页的“重新开始”在跑的时候是灰的（`startOverActivity`）。

### 4.2 应用页的安装文件卡（`Views/CareStudio/CareStudioApplications.swift`）

- 有预选的安装文件（名字对得上已装应用）时才显示“移除”，没有就只留“查看”，和 cmm2/01 一致。
- 原来没预选时也有“移除”，但 `runTile(.installers)` 只选预选项，点了什么都不发生。

### 4.3 性能页另外三张卡的英文单复数（`Views/CareStudio/CareStudioStartup.swift`）

- 本条的离屏截图里登录项卡写成“You Have 1 Login Items”。登录项、后台项目、更新与同步三张卡的英文标题在数量为 1 时改用单数（“You Have 1 Login Item”“1 Background Item Found”“1 Update & Sync Item”）。
- 这三个数顺带改走 `ByteFormat.count`（D178 的口径），三位数以内写法不变。中文不变。

## 5. 测试

- 新增 `SystemMaintenanceTests.testPerformanceTileRunsOnlyTheRecommendedTasks`：用假探测和假执行器。
  - 推荐 1 个（重建邮件索引），用户在维护任务页另勾 1 个不推荐的（刷新“打开方式”）；
  - 卡片标题“1 个维护任务推荐”，按钮“查看”“运行任务”；点“运行任务”交出去的只有推荐的那 1 个；
  - 跑的时候按钮变成“正在运行…”并变灰，再点也不会交出任务；
  - 跑完只跑了推荐的那个，卡上出现“已运行 1 项……”。
- 新增 `SystemMaintenanceTests.testPerformanceTileWithoutRecommendationsOnlyReviews`：没有推荐时标题“维护任务”，没有“运行任务”。
- `CareStudioRenderReviewTests` 的离屏截图加一张 `14-performance-results-*`（性能结果页，维护卡领头，2 个推荐）：中文深色、中文浅色、英文深色三张，不用窗口。
- `CareStudioWindowReviewTests` 的窗口截图 `w11-startup-results-*` 也带上维护卡（1 个推荐）。维护卡用单独的预览实例，同一轮里其他截图读的维护任务数据不受影响。
- 安装文件卡的条件只是一行判断，没有加专门的测试。
- 改了的测试：`CareStudioToolboxWiringTests.testEachToolPageOpensFromItsModule` 原来按原文查一行 `onReview: { store.showFilter(.maintenance) }, art: .tileMaintenance)`。卡片抽成构造函数后，“查看”的接线留在页面里、配图在构造函数里，这一行就拆成两处了。现在查 `.maintenance(maintenance, onReview: { store.showFilter(.maintenance) })` 和 `art: .tileMaintenance)` 两段；配图另由新测试从卡片模型直接读（`tile.art == .tileMaintenance`）。原来那行写在注释里。

## 6. 验证

Xcode 27.1。

- 第 12、13 条合起来的完整非窗口门禁（门禁树 `b2cf54c0`，即本条结果树去掉两份交接文档，21:30–22:17，持 heavy 锁）：
  - debug：主测试包 5967 个，29 个跳过，1 个失败，是 `MacBenchmarkKernelTests` 在高负载下的资源上限超时（见第 12 条交接 §4），和本条无关；CombinedStatusIconTests 285 个 0 失败；Swift Testing 135 个通过。
  - release：主测试包 5710 个，28 个跳过，0 失败；285 个 0 失败；135 个通过。
- 定向跑（增量编译）：`SystemMaintenanceTests`、`CareStudioRenderReviewTests`、`CareStudioToolboxWiringTests`、`UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`、`ApplicationsManagerTests`、`StartOverTests`、`SmartCareTests`、`CareStudioModuleShellRenderTests`。
  - 第一轮 135 个里 1 个失败：`CareStudioToolboxWiringTests` 按原文查维护卡的那一行，改法见 §5；
  - 改后重跑两个类全过；单复数修正后再跑 4 个类，96 个全过。
- 离屏截图：`~/Developer/.sc-build/cmm-ui-evidence-i13/14-performance-results-*`，三张，对照 cmm/24。维护卡标题“2 个维护任务推荐 / 2 Maintenance Tasks Recommended”，英文和 CleanMyMac 一样折成两行，按钮“查看 / Review”加“运行任务 / Run Tasks”；登录项、后台项目两张卡只有“查看”；英文“You Have 1 Login Item”。
- 窗口：20:19–20:33 那一轮 5 个窗口类里，`CareStudioWindowReviewTests` 全过（借“虚拟屏 1 · Codex”，用户 10-23 同意）。截图 `~/Developer/.sc-build/cmm-ui-evidence-i12i13/w11-startup-results-*`：性能结果页领头是“1 个维护任务推荐”，带“查看”“运行任务”。
- 没有在真实 App 里点过“运行任务”，会真的跑维护任务，测试里也只用假的执行器；没装测试版。

## 7. 顺带看到的两点（在你那边，我没改）

1. 应用页“长期未用”卡的“卸载”（`runTile(.unused)`）会把这类应用全部选上，直接进入卸载，中间没有确认框（有应用在运行时只会先问要不要退出它）。CleanMyMac 的字符串表里这张卡确实有“卸载”，要不要加一步确认，你看着定。
2. 最近使用项目卡的“移除”，扫描后默认什么都没勾，点开是空的确认页（`RecentItemsPresentationTests` 也是这样断言的）。如果这是 D188 有意的设计，就不用管。
