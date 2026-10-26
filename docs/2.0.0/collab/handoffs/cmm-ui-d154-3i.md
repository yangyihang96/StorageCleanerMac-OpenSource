# 交接：D154 第三批 I（设置窗口改为 CleanMyMac 顶部页签）

日期：2026-10-21。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `0c4b4d7f`（= 第三批 H 结果树；v2.0.1 合并后的代码树 `8121c037` 只多 DECISIONS.md 的记录，本批不碰 DECISIONS）。未提交、未安装、未推送。

## 1. 用户要求

用户原话（2026-10-21）：“设置改成 CleanMyMac 那样的顶部页签，推翻 D3/D53 的侧栏决定，相关测试按新版式改。”

## 2. 改了什么

- **设置窗口**：左边的分类侧栏（D3/D53 那套）换成窗口顶部一排页签，照 CleanMyMac 的设置窗口：每个页签上面是该页的 3D 小图（28 pt），下面是名字（11 pt，窄窗英文可折两行）；当前页签垫一块柔和的底色（沿用原侧栏的选中色）。页签栏高 72 pt，下面一条细线，再下面是原来的设置页。
- **一层背景**：整窗只画一层光晕背景（从标题栏一直到页签和设置页），设置页自己的背景关掉（`SettingsLightfieldPane` 新增 `drawsBackdrop`，默认仍是 `true`，只有设置窗口传 `false`）。
- **键盘**：点过页签后，← → 在页签间移动（原侧栏是 ↑ ↓）；页签的辅助功能值和“已选择”特征照旧。
- **版本号**：原侧栏底部的版本号随侧栏去掉，版本仍在“关于”页；主窗口侧栏的版本号不变。
- **都没变**：七个分类、选中状态的保存（`settingsSelection`）、每页的内容和冻结几何（`SettingsLightfieldGeometry`）、主窗口侧栏（D3 的选中色、D53 的滑动选中块）都没动。窗口最小宽度仍是 560。

## 3. 建议的 DECISIONS 行

| # | 决定 | 影响 |
|---|---|---|
| D154⑪（编号由 2.0.1 会话定） | 设置窗口改为 CleanMyMac 式顶部页签（图在上、名在下，选中垫底色，← → 切换），推翻 D3/D53 中设置窗口侧栏的部分；设置页几何不变，整窗一层背景；版本号只在“关于”页。主窗口侧栏不变。 | 设置窗口 |

## 4. 测试

按新版式改的测试（断言内容随版式换，没有放宽）：

- `UIConsistencyRegressionTests`：原来查侧栏宽度（窄窗 180 / 宽窗 210）和 `HStack`，改为查 `settingsTabBar`、`SettingsTabBar(selected: selectedCategory)`、`VStack(spacing: 0)`，并断言源码里不再有 `settingsSidebar`；分类、选中绑定、方向键、焦点、行按钮样式、选中底色的断言照旧。D3/D53 的注释改成本批的说明（主窗口侧栏的 D53 断言照旧）。
- `SettingsSourceContractTests`、`D64DeclutterAContractTests`、`AppResponsivenessTests`：侧栏声明换成页签声明（图标尺寸 20 → 28），设置页调用改为 `drawsBackdrop: false`；“只挂当前页”的断言（`settingsPane(for: selectedCategory)` 等）照旧。
- `SettingsLightfieldContractTests`、`SettingsLightfieldGeometryTests`：设置页的尺寸由“窗宽减侧栏、窗高减标题栏”改为“整窗宽、窗高减标题栏减页签栏和细线”；背景测试加查整窗只有一层背景、设置页在 `drawsBackdrop` 为假时不画。
- 新增 `SettingsLightfieldGeometryTests.testSettingsTabsFitTheBarAtEveryWindowWidth`（窗口类）：中英文、窗宽 560/677/820/1180/1680，七个页签都在页签栏里、从左到右不重叠，栏高 72。
- `CareStudioWindowReviewTests` 截图加 `w17-settings-tabs`（1180 宽）和 `w17-settings-tabs-narrow`（560 宽），中英文、深浅色。

## 5. 验证

- debug 编译通过；release 编译（`swift build -c release`，约 8 分钟）通过，本批两个源文件无警告（8 条警告都是别处原有的 `init(cString:)` 弃用）。
- 非窗口全量（10-21 23:3x–23:38）：XCTest 5473 个，1 个失败——`AppResponsivenessTests.testSettingsAndBenchmarkMountExpensiveContentOnDemand` 还在查旧的侧栏声明；按新版式改成查页签声明后，重跑该类和 `UIConsistencyRegressionTests`、`SettingsSourceContractTests`（52 个）0 失败。swift-testing 135 个通过。
- 窗口类全量 625 个（含新增的页签测试；虚拟屏 2，23:39–23:51）失败集合与基线逐条相同（43 对 43，无新增）；`SettingsMiniWindowPreviewTests` 的 7 个是基线里原有的。
- 截图核对（测试窗口里真实绘制）：1180 宽中文深色/浅色、560 宽英文深色/中文浅色；页签不挤不叠，窄窗英文名折两行，整窗一层背景。
- 未核对：截图里的设置页是示例行（不读真实设置）；完整的设置窗口（七页真实内容、标题栏）要装测试版后实机看。← → 切换页签只做了代码审阅（和原侧栏的 ↑ ↓ 同一写法），没在窗口里按键实测。

## 6. 下一步

首次引导（要 F 类插画）；智能扫描模块卡、菜单栏（等用户定）；空间地图气泡里放图标。
