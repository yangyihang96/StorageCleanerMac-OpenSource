# 2.0.0 Beta 日间配色与 iStat 对照（2026-09-23）

基于现有 `codex/2.0.0-beta-r2` 工作区增量修改，没有重置或覆盖已有未提交内容。只读查看了本机已运行的 iStat Menus 设置页及 [Bjango 官方 iStat Menus 页面](https://bjango.com/mac/istatmenus/)：其中菜单示例采用中性外壳、灰色空环、蓝色与玫红等分色数据系列。没有更改 iStat 设置，也没有复制其素材或声称使用其精确色值。2.0.0 Beta 日间仍是浅色，不把 iStat 的深色 Graphite 主题直接套用。

## 落地的颜色关系

| 角色 | 上一版 | 本轮 | 目的 |
|---|---|---|---|
| 主页面渐变 | `#F0F1EE` → `#E9EBE8` | `#E8EBEA` → `#DEE3E1` | 加深低彩度灰，避免近白大底 |
| 侧栏渐变 | `#F6F6F3` → `#EEF0EC` | `#F2F4F2` → `#E7EBE9` | 与页面和数据卡片分层 |
| 数据卡片 | `#FAFAF8` | `#FAFBF9` | 保持可读的明亮表面 |
| 次级表面 | `#F1F2EF` | `#EEF1EF` | 小窗外壳及次级内容跟随灰阶 |
| 普通边线 | `#D8DDD9` | `#C9D1CD` | 在浅色卡片上更易辨认 |

浅色主操作仍为 `#0A8466`，小面积选中为 `#DDF3E8`，智能扫描矢量插画仍用暖金。CPU 蓝／玫红、内存和其他数据系列沿用已有语义颜色及灰色空轨道，用户的小窗紫罗兰图表偏好保持有效。夜间颜色分支未改动。此次改动限定在 `AppAppearanceColors.swift` 与 `ModuleTheme.swift` 的浅色表面及边线，没有更改采样、扫描、清理、权限或硬件控制调用链。

## 本机真实界面

证据目录：`/Users/developer/Documents/好玩的/StorageCleanerMac-istat-palette-20260923/`。

- 只读参考：`istat-official-menus.png`、`istat-local-themes.png`。
- 更新前运行中的测试版：`before-installed.png`。
- 更新后 `/Applications/测试版.app`：`after-smart-scan.png`、`after-safe-cleanup.png`、`after-settings.png`、`after-mini.png`。
- 同尺寸截图中，主页面空白区域的取样从约 RGB `(240,240,238)` / `(238,238,236)` 变为 `(233,235,234)` / `(230,232,231)`。这证明灰阶已进入实际运行界面，不代表主观视觉验收完成。

## 执行与边界

| 检查 | 本轮结果 |
|---|---|
| 定向回归 | PASS：`./script/test.sh --filter DaylightRefinementTests` 8 项、`--filter DayAppearanceTests` 6 项，均零失败 |
| Release 全量 | PASS：2867 项、17 项按既有条件跳过、零失败 |
| Debug 全量 | PASS：2922 项、18 项按既有条件跳过、零失败 |
| 严格并发构建 | PASS：`script/verify.sh` 使用 `-strict-concurrency=complete`，整体验证退出码 0 |
| 小窗性能回归 | PASS：10 项；准备数据 P95 约 42.63 ms。该指标不是鼠标到实际像素的端到端延迟 |
| Beta 构建与安装 | PASS：`STORAGE_CLEANER_SKIP_TESTS=0 ./script/build_and_run.sh --beta --install` 退出码 0；安装版本 `2.0.0 (20260923030046)`，Bundle ID 为 `com.local.StorageCleanerMac.beta` |
| 安装签名 | PASS：`codesign --verify --deep --strict`；Apple Development 签名，非 Developer ID／公证证据 |
| 开发机视觉抽查 | PASS：智能扫描、安全清理、设置和小窗真实截图已人工查看 |
| 普通 M4 Mac mini 与竖屏 | NOT RUN：当前可访问的运行机器不是用户的普通 M4 mini |
| 全部页面及原 49 项严格视觉验收 | NOT RUN：保留独立记录 `0/49`；上述截图不能替代逐项验收 |
| 正式发行 | NOT RUN：未推送、未发布 Release、未修改正式 appcast、未覆盖正式 App |

首次直接运行 `swift test` 时，仓库内 `.build` 生成测试包被 File Provider 添加扩展属性，导致代码签名拒绝，未进入测试断言；改用项目的 `script/test.sh` 在隔离构建路径重跑通过。完整构建输出保存在证据目录 `beta-install.log`。安装后仅保留 `/Applications/测试版.app`；主可执行文件 SHA-256 为 `02373fd4f7534b74d6091c0c2191fd05dd9a55c2ab9eb268b15dc0fbca0909dd`，应用约 83 MiB。
