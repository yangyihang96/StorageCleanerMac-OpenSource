# 交接：报告第四节第 18 条（清理管理器中栏）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是第 15 条的结果树（见交付消息）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求和现状

报告原文：“管理器中栏（cmm/16 对 ours/11）：CleanMyMac 每个子类都有图标，选中的大小用粉色小标显示，按类型分组（系统缓存、用户缓存、日志、语言文件……），左栏没有勾选框；我们中栏没有图标、名字被截断，按应用分组，左栏有勾选框。”

对照现状（主会话 r37 的 `w08-cleanup-manager-en-dark`，树 55581c6f）：

- D192 已经按类型分组（浏览器缓存、构建产物……），名字也不再截断，这两点已一致。
- 子类图标都有。截图里“浏览器缓存”那一行空着，是因为测试宿主没设 `generatedArtWindowVisible`，`LightfieldOptionIconView` 只在它为真时才加载图片；正式 App 里 ContentView 会设这个值。这不是产品问题，这次没改。
- 还差两处：
  - 左栏每个大类都有三态勾选框，CleanMyMac 左栏只有名字；
  - 中栏每个子类右边是勾选框，CleanMyMac 在这个位置用粉色小标写已选的大小（“42 GB”；部分选中时写已选的那部分，如 21.1 GB 里选了 11.7 GB），没选的不显示。

## 2. 改了什么（`Views/CareStudio/CareStudioJunkManager.swift`）

- 左栏（`groupColumn`）去掉勾选框，只剩名字；行的 accessibilityValue 读出“已选择 / 部分选择 / 未选择”。
- 中栏（`subgroupColumn`）的勾选框换成 `CareStudioSelectedSizeTag`：
  - 写这个子类已选的大小，白字粉底（`CareStudioManagerInk.accent`），圆角 6，没选的不显示；
  - 小标只是显示，不能点，点整行仍是打开这个子类；
  - 行的 accessibilityValue 同样读出选择状态。
- 选择的入口照旧，都没改：
  - 右栏顶上“选择：全部 / 部分 / 不选”菜单（推荐 / 全部 / 不选）；
  - 每一项的勾选框；
  - 底部“选择”菜单（选推荐 / 恢复默认 / 全部不选）。
  - 没加全选，因为 D47 规定黄、红两级要一项项勾。原来左栏、中栏勾选框用的 `toggle(ids:recommended:)` 只服务这两处，已删掉。
- 已选大小抽成纯函数 `CareStudioJunkManager.selectedBytes(in:selected:)`，便于测试。

## 3. 测试

新增 `CareStudioJunkManagerTagTests`（非窗口，用调试夹具的扫描会话）：

- 没选时为 0（不显示小标）；
- 选一项时只算这一项；
- 选两项时是两项之和；
- 别的子类的项不算；
- 三种选择状态的读屏文字互不相同。

## 4. 验证

Xcode 27.1，树是第 15 条结果树加本批，在 heavy 锁里增量编译，10-24 02:54–02:56。

- 非窗口定向 5 个类，76 个测试，0 失败：CareStudioJunkManagerTagTests（新增）、UIConsistencyRegressionTests、CareStudioRenderReviewTests（会渲染管理器）、SystemCachePresentationTests、CareStudioModuleShellRenderTests。
- 静态检查：窗口类登记（D106）通过；Sources 没有新增删除调用。
- 没跑的：管理器在窗口里的样子（离屏渲染画不出滚动列表），即 CareStudioWindowReviewTests 的 w08-cleanup-manager 截图和管理器检查，交给主会话的窗口全量，这一条用户没同意我借屏。
- 没在测试版里亲手看；没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| 第 18 条 | 清理管理器照 CleanMyMac：左栏大类只有名字，不带勾选框；中栏子类右边用粉色小标写已选的大小，没选不显示。选择改在右栏的“选择”菜单、每一项的勾选框和底部的“选择”菜单里做，不加全选（D47）。 | 清理管理器 |
