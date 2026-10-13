# 2.0.0 Beta 日间中性配色实测（2026-09-23）

本轮基于 `codex/2.0.0-beta-r2` 的现有工作区修改，只更新本机测试版。参考腾讯柠檬官网展示的浅色界面中性底面、暖色视觉焦点与绿色主操作的**用色关系**；下列数值是 StorageCleanerMac 自行设计的色值，未复制对方素材或宣称为其官方色值。

## 实际改动

| 用途 | 本轮日间色 | 处理 |
|---|---|---|
| 页面渐变 | `#F0F1EE` → `#E9EBE8` | 从此前偏绿的整页底色改为低彩度中性灰 |
| 侧栏渐变 | `#F6F6F3` → `#EEF0EC` | 减少侧栏大面积绿雾 |
| 内容卡片 | `#FAFAF8` | 接近暖白，与页面区分 |
| 普通边线 | `#D8DDD9` | 保持浅色卡片边界 |
| 主操作 | `#0A8466` | 限于按钮和必要强调；白色按钮文字对比度约 4.66:1 |
| 选中 / 悬停 | `#DDF3E8` / `#EAF8F0` | 小面积浅薄荷色，不铺满页面 |
| 智能扫描插画 | 暖金 `#9F6510` | 日间轨道与焦点图形；夜间画法不变 |

日间色由 `AppAppearanceColors` 集中解析到主窗口、设置和小窗，`ModuleTheme` 只在浅色分支统一操作与外框色。夜间分支及用户紫色图表偏好未改动。设置中的系统蓝色键盘焦点环保留以维持焦点可见性。紫色、蓝色等数据图表颜色仍表达原有类别和用户偏好。

## 真实 App 画面

证据目录：`/Users/developer/Documents/好玩的/StorageCleanerMac-lemon-palette-20260923/`。

- 官网只读参考：`tencent-lemon-reference.png`；来源 `https://lemon.qq.com/`，只用于内部颜色关系对照。
- 改动前：`before-smart-scan.png`、`before-settings.png`。
- 安装后真实界面：`after-smart-scan.png`、`after-safe-cleanup.png`、`after-settings.png`、`after-mini.png`、`after-performance.png`、`after-file-analysis.png`。
- 截图为本机运行的 `/Applications/测试版.app`。智能扫描已明显减少大面积绿色；文件分析的类别图标、性能页图表、小窗图表仍保留各自的数据语义色。设置页的蓝线是实际键盘焦点，不是本轮主题强调色。

## 验证边界

| 检查 | 结果 |
|---|---|
| 日间定向测试 | PASS：`DaylightRefinementTests` 8 项、`DayAppearanceTests` 6 项 |
| Release 全量 | PASS：2867 项，17 项按现有条件跳过，0 失败 |
| Debug 全量 | PASS：2922 项，18 项按现有条件跳过，0 失败 |
| 小窗性能回归 | PASS：10 项；准备数据 P95 约 44.45 ms。这是测试测量，不等于鼠标到像素的真实端到端耗时 |
| Beta 构建、安装、签名 | PASS：`./script/build_and_run.sh --beta --install` 退出码 0；安装版为 `2.0.0 (20260923015841)`、`com.local.StorageCleanerMac.beta`；`codesign --verify --deep --strict` 通过 |
| 开发机真实截图 | PASS：主窗口智能扫描、安全清理、性能、文件分析、设置和小窗已采集并人工查看 |
| 普通 M4 Mac mini 与竖屏实机 | NOT RUN：当前可访问机器不是用户的普通 M4 mini |
| 原 49 项严格视觉验收 | NOT RUN：继续独立保留 `0/49`，上述截图与测试不代表逐项通过 |
| Developer ID、公证与正式版发布 | NOT RUN：本轮仅本地 Beta 调色，不进入正式发行 |

完整构建输出在同目录 `beta-install.log`，命令退出码在 `beta-install.exit`。安装后应用大小约 83 MiB，主可执行文件 SHA-256 为 `0befd1c80ef3d34c0dc175d1eb60b15d962e8c8f7d7b5c1a2927810ec11bc3d8`，签名身份为 Apple Development（不是 Developer ID）。只保留 `/Applications/测试版.app`，安装遗留的旧测试版与临时 App 副本已按 Bundle ID 核对后删除。本轮没有推送、发布 GitHub Release、修改正式 appcast 或覆盖正式版。
