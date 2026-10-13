# 2.0.0 Beta 浅色配色续调与实机复核

本轮在 `codex/2.0.0-beta-r2`、HEAD `6ec0a148c559fd1daf3c5ddf0e43b520cc82c717` 的已有未提交工作上实施，仅更新本地测试版。参考 iStat 的表面分层思路，色值由本应用独立确定；不复制其内部调色板。夜间配色、紫色图表偏好、图表数据口径、菜单贴合布局和清理安全链路未改。

## 实际改动

| 部位 | 前 | 后 |
|---|---|---|
| 主画布上／下 | `#DADDE3`／`#DADDE3` | `#E4E5E3`／`#DEE0DE` |
| 数据卡片 | `#ECEEF1` | `#F0F1EF` |
| 次级表面 | `#DDE0E5` | `#E5E8E5` |
| 主侧栏上／下 | `#D2D5DC`／`#D2D5DC` | `#DFE1DF`／`#D5D9D6` |
| 普通边线 | `#B9BFC9` | `#C1C8C3` |
| 设置侧栏 | 固定近白 `#F4F5F6` | 与主侧栏一致的浅色灰渐变；夜间仍用原有底色 |

悬停、选中和提示表面也改成同一低彩度灰绿体系。操作青绿 `#147D70`、深色文字、图表个人偏好保持原值。计算对比度：主文字／卡片约 13.52:1，次级文字／卡片约 7.40:1，白字／青绿按钮约 5.00:1。实机同一安全清理页 `(750,400)` 背景像素从 RGB `(220,221,226)` 变为 `(225,225,223)`；设置侧栏 `(80,300)` 从 `(244,245,247)` 变为 `(220,222,219)`。原始图和取样在本轮证据目录。

设置侧栏此前点击“小窗”或“关于”后仍停在“通用”；整行 `onTapGesture` 方案也未在实机生效。最终使用项目已有的 `ResponsivePlainButtonStyle` 承载原选择绑定，实机连续进入“小窗”、返回“通用”并进入“关于”；小窗预览明确标为模拟数据，未执行扫描或硬件控制。相关源文件为 `AppAppearanceColors.swift`、`ModuleTheme.swift`、`SettingsView.swift`，回归文件为 `DaylightRefinementTests.swift`、`MenuBarPanelSessionTests.swift`。

## 验证结果

| 项目 | 结果 | 证据 |
|---|---|---|
| 旧银灰色阶的新增设计断言 | 预期失败，3 条 | `before-color-test.log` |
| 调色后定向外观测试 | PASS，14 项 | `after-color-targeted.log` |
| 设置导航旧点击／最终点击 | 旧版仍选“通用”；最终选“小窗”且可切至“关于” | `settings-navigation-before.ax.txt`、`installed-shared-settings.ax.txt` 与对应截图 |
| 最终 Debug 全量 | PASS，2922 项、18 项按原条件跳过、0 失败 | `shared-debug.log`、`.exit` |
| 最终 Release 全量 | PASS，2867 项、17 项按原条件跳过、0 失败 | `shared-release.log`、`.exit` |
| 严格并发构建 | PASS | `shared-concurrency.log`、`.exit` |
| 性能定向及 Beta 打包 | PASS，性能定向 10 项；包签名验证通过 | `shared-package.log`、`.exit` |
| 安装版签名、身份、运行路径 | PASS，`com.local.StorageCleanerMac.beta`，从 `/Applications/测试版.app` 运行 | `installed-verification-final.json`、`installed-codesign-final.log` |
| 浅色主窗、设置、小窗三级 | 已在 Apple M5 Pro MacBook Pro 实机查看；三级相接、边界完整 | `installed-shared-cleanup.png`、`installed-shared-settings.png`、`installed-shared-cpu-three-levels.png` |

最终安装为 **2.0.0 Beta，构建 `20260922231545`**，主可执行文件 SHA-256 `14f27fe88692fec01c6b767cb6dbd0439767ef4249e28411c28ac7eafa2f0c3a`。使用 Apple Development 签名并通过本地 `codesign --verify --deep --strict`；这不等于 Developer ID、公证或正式发行。正式安装、正式更新源及远端仓库未修改。本轮产生的五份旧测试版回退副本已核对 Beta 身份并记录哈希，两份临时 App 包另与最终安装版比对哈希，随后删除；源码和验收证据保留。

证据目录：`/Users/developer/Documents/好玩的/StorageCleanerMac-daylight-color-pass-20260922`，内含本轮增量补丁、取样 JSON、安装／清理回执、完整日志和真实截图。原 49 项严格视觉验收仍独立为 **0/49**；本轮的局部视觉复核不替代整套验收。普通 M4 Mac mini、竖屏及其他显示配置未在这台 M5 Pro 笔记本上实测，不标记通过；正式版发布门槛未达到。
