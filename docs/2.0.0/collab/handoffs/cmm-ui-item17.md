# 交接：报告第四节第 17 条（换页时先模糊再清晰）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是第 14 条的结果树（见交付消息）。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求和证据

报告原文：“换页过渡：CleanMyMac 内容先模糊，再清晰淡入（cmm/02 拍到了中间那一帧）。”

**证据核对（要你知道）**：我按像素比了 `cmm/02` 和换页后稳定下来的 `cmm/15`（同一个 Cleanup 首页）。

- 标题“Junk Cleanup”、副标题、列表、插画这几块的边缘强度相同（标题 11.06 对 10.97，插画 2.33 对 2.37）；
- 文字最亮值也相同（都是 255 左右）。

所以 `cmm/02` 并不是过渡中间的一帧，现有截图量不出 CleanMyMac 模糊的程度和时长。下面的做法依据的是报告里实际看到的描述。要做到 1:1，得再录一段 CleanMyMac 换页的屏幕视频，那需要用 LCU 操作 CleanMyMac，还要和其他会话错开桌面。

## 2. 改了什么（`Support/AppMotion.swift`）

- 新页面（`AppMotionPageModifier`）淡入时，模糊半径跟着淡入的进度减小：`(1 - opacity) × 8` 点，完全进来后是 0。时长和曲线照旧，是原来的 0.5 秒 `pageChange`，新页面上升 8 点也不变。
- 旧页面（`AppMotionOutgoingPageModifier`）在 0.15 秒淡出的同时变成 8 点模糊。开了“减少动态效果”时不模糊，仍然只淡出。
- “减少动态效果”下，新页面本来就只做 `AnyTransition.opacity`，不经过 `AppMotionPageModifier`，所以没有模糊。
- 合同测试里的原文（`active: AppMotionPageModifier(opacity: 0, offset: 8)`、`.opacity(isLeaving ? 0 : 1)`、`.allowsHitTesting(!isLeaving)`、`.accessibilityHidden(isLeaving)`、`.offset(y: offset)`、没有 `scaleEffect`）都没动。模糊不改变布局和点击区域。

## 3. 测试

- `CareStudioMotionTests.testAPageComesInOutOfABlur`（离屏渲染）：
  - 方块淡入到一半时，它左边缘外 2 点处的亮度 < 0.97，说明模糊把灰色带了出去；
  - 完全进来后同一处 > 0.99，是清晰的。
- 换页的窗口行为（`DesignSystemV2ReviewTests` 里离开的页面不接收点击、读屏读不到）交给主会话的窗口全量。

## 4. 验证

Xcode 27.1，树是第 14 条结果树加本批，在 heavy 锁里增量编译，10-24 02:26–02:28。

- 非窗口定向 3 个类，58 个测试，0 失败：CareStudioMotionTests（含新加的模糊测试）、UIConsistencyRegressionTests（换页的合同原文）、CareStudioRenderReviewTests。
- 没跑的：
  - 换页在窗口里的样子，以及 DesignSystemV2ReviewTests 里离开的页面不接收点击、读屏读不到，交主会话的窗口全量；
  - 动画中间帧没有截图，离屏渲染只能测“淡入一半时模糊、进来后清晰”。
- 没在测试版里亲手看；没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| 第 17 条 | 换页时，新页面由 8 点模糊变清晰地淡入，旧页面模糊着淡出；减少动态效果时只淡入淡出。依据是报告的现场描述，cmm/02 不是过渡中间的一帧。 | 主窗口所有换页 |
