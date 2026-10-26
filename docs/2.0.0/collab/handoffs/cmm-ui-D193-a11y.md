# 交接：D193② 可清除空间一行的无障碍修正（第二版）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话的 `a8ccf403`（第一版已退回）依次打上 D204、D203、D202 之后的树（见交付消息）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 问题和第一版为什么退回

主会话在第 11 次测试版里用 LCU 实测（10-24）：

- 空间地图根层“目录”列表末尾的“可清除空间 126.68 GB”，在无障碍树里并进了上一行 /var 的文字元素；
- 读出来是“Value: 0字节 0.0% 可清除空间、由 macOS 管理…、126.68 GB, Help: /var”。

第一版把这一行改成单独的元素，并在 `SpaceMapTreemapWindowTests` 里加了进程内的无障碍检查。r40 窗口全量里这条检查没过：遍历下来，没有任何元素带“Purgeable Space”。

主会话按诊断测试（`D193A11Y`，不合入）在副屏跑了一次，原样输出在 `~/Developer/.sc-build/v2.0.1/d192-handson/diag-d193a11y/D193A11Y.txt`：

- 在测试进程里，ScrollView 里的 SwiftUI 内容根本不在无障碍树里：
  - 目录列表是 `HostingScrollView`（AXScrollArea），下面只有 `NSScroller`，一行文件夹也没有；
  - 在行中心做命中测试，落在滚动区本身。
- 对照窗口里的 7 种写法都一样：原写法、第一版、去掉 help、放到 LazyVStack 外、独立 id、放进 ForEach、加探针。
- 第 11 次测试版上，外部的 LCU 读得到列表行。

所以失败的是检查方法：进程内读不到 ScrollView 里的行，不能说明修正无效。

## 2. 这一版改了什么（`Views/CareStudio/CareStudioSpaceLens.swift`）

`purgeableRow`：

- 一个单独的元素（`.accessibilityElement(children: .ignore)`），不再把子文字拼起来（原来是 `.combine`）；
- 自己带四项：
  - label：标题“可清除空间 / Purgeable Space”；
  - value：大小，和行里显示的数字相同；
  - hint：说明“由 macOS 管理，需要时自动腾出，不用手动清理”；
  - 固定标识 `careStudio.spaceLens.purgeable`，LCU 可以按 id 找到它；
- `.help(说明)` 放在这几项之后，挂在这个元素自己身上（原来读成上一行的 /var）。

列表里：这一行加 `.id("spaceLens.purgeable")`，在 LazyVStack 里有自己的身份，不和最后一个文件夹行共用。

- 这是推断，没有验证：第 11 次并进 /var，可能和这一行没有自己的身份有关。
- 文件夹行的 id 是路径，不会重名。

版式、显示条件、探针都不变。

## 3. 测试

- `SpaceLensPurgeableTests.testThePurgeableRowIsOneAccessibilityElementOfItsOwn`（新增，非窗口）检查源码：
  - 这一行是 ignore 加 label、value、hint、identifier；
  - 没有 combine；
  - 列表里有 `.id("spaceLens.purgeable")`。
  - 它只挡住改回原写法，不证明读屏效果；进程内读不到 ScrollView 里的行，见第 1 节。
- `SpaceMapTreemapWindowTests`：不改，和 `a8ccf403` 相同，只有原来的布局检查。第一版加的进程内无障碍断言不再加。

## 4. 验证

Xcode 27.1。树是 `a8ccf403` 依次打上 D204、D203、D202 再加本修正，在 heavy 锁里增量编译（含测试目标，窗口测试也编进去了），10-24 12:09–12:13。

- 非窗口定向 6 个类，106 个测试，0 失败：SpaceLensPurgeableTests（含新增的源码检查）、SpaceLensSidebarTests、SpaceLensBubbleIconTests、UIConsistencyRegressionTests、SmartCareIndependenceD202Tests、SidebarBadgeTests。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。
- 没跑的：SpaceMapTreemapWindowTests（窗口类，只有原来的布局检查）交给主会话的窗口全量。
- 读屏效果没验证：要等装机后用 LCU 看下面三点。
- 没装、没提交。

装机后请主会话用 LCU 看三点：

1. 有一个 id 为 `careStudio.spaceLens.purgeable` 的元素，label 是“可清除空间 / Purgeable Space”，value 是大小（如 126.68 GB）；
2. /var 那一行的元素里不再含“可清除空间”；
3. 它的 help 是“由 macOS 管理…”，不是 /var。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| D193② 补二（重做） | 空间地图“可清除空间”一行在无障碍里是单独的元素：名字是“可清除空间”，数值是大小，提示是“由 macOS 管理…”，固定标识 `careStudio.spaceLens.purgeable`，在列表里有自己的身份。测试进程读不到 ScrollView 里的行（10-24 诊断），这一条以装机后 LCU 外部读到的为准；单元测试只检查源码，挡住改回原写法。 | 空间地图目录列表 |
