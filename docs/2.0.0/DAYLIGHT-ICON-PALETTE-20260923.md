# 2.0.0 Beta 日间图标配色（2026-09-23）

D63 / D64 / V1 R10 更新：用户于 2026-10-08 上午选定①晨雾蓝，另外两套候选与 Debug 切换已删除；Debug 与 Release 统一。14 个功能起始／运行的内容与插画共用画布，无白色卡片背板。当前合同见 [日间验收](DAY_APPEARANCE_ACCEPTANCE.md)。图标只保留真实可选控件、应用／文件数据和信息性状态；标题、分区、状态行、主按钮的装饰及插画卫星删除。保留图标按正式晨雾蓝的画布、侧栏、内嵌表面校准，最小对比度仍为 4.6:1，类别色差仍为 ≥0.04；夜间原色、数据曲线、风险色及用户小窗图表色合同不变。R10 尚待外部构建、测试与实图验收。

下面保留 2026-09-23 的原色表与证据，作为历史记录；其中“象牙白”与暖色固定表不再是 D63 主窗口验收要求。小窗／设置不在本次结构迁移范围。

| 用途 | 日间图标色 | 对应区域 |
|---|---|---|
| 暖棕 | `#795B42` | 设置与中性工具 |
| 青绿 | `#2D7565` | 次级功能与文件分析细节 |
| 赭金 | `#95652D` | 智能扫描、清理和 CPU |
| 橄榄绿 | `#56754C` | 保护、内存和健康检查 |
| 暖梅紫 | `#79556F` | 性能、显示相关功能 |
| 陶土棕 | `#9C6756` | 应用与存储设备 |
| 松叶绿 | `#3D755C` | 文件与目录 |

历史合同中的颜色只占图标、轮廓和少量浅色底；D63 的当前大面积表面由统一日间主题令牌管理。菜单选择用既有青绿，操作和风险颜色保持原语义。此表是本软件自己的配色合同，不声称复制 iStat 或腾讯柠檬的精确色值。

## 验收边界

本地实图及完整测试记录保存在 `/Users/developer/Documents/好玩的/StorageCleanerMac-icon-colors-20260923/`。主窗口抽查、小窗独立检查、M4 Mac mini 及原 49 项严格视觉验收分别记录，不能用单元测试结果代替视觉完成。

| 项目 | 结果 |
|---|---|
| 定向图标测试 | PASS：`DaylightRefinementTests` 9 项，零失败；`icon-targeted-final.log`。检查象牙白卡片对比度、可辨色度与夜间原色回退。 |
| Release 全量 | PASS：2868 项，17 项按原条件跳过，零失败；`beta-install-final.log`。 |
| Debug 全量 | PASS：2923 项，18 项按原条件跳过，零失败；同一日志。 |
| 严格并发及小窗性能回归 | PASS：`script/verify.sh` 退出码 0，`MenuBarPerformanceRegressionTests` 10 项零失败。性能脚本测得准备数据 P95 为 54.47 ms、缓存交付 P95 为 0.003 ms；这些不是鼠标到像素的实测交互延迟。 |
| Beta 构建、签名、安装和运行 | PASS：`STORAGE_CLEANER_SKIP_TESTS=0 ./script/build_and_run.sh --beta --install` 退出码 0；`/Applications/测试版.app` 为 `com.local.StorageCleanerMac.beta`、`2.0.0 (20260923044839)`，运行路径及 `codesign --verify --deep --strict` 已核对。签名是 Apple Development，并非 Developer ID 或公证证据。 |
| 唯一测试版 | PASS：核对身份后移除上一个测试版和两份临时打包 App；`/Applications` 仅保留 `/Applications/测试版.app`。未生成 ZIP／DMG。 |
| 实际主窗口抽查 | PASS：`final-smart-scan.png`、`final-performance.png`、`final-file-analysis.png`、`final-dev-tools.png` 均采自上述最终安装版；图标与象牙白表面、文字及选中状态的关系已检查。 |
| 设置及小窗模拟预览 | PASS：`final-settings-mini-preview.png` 采自同一安装版；预览明示非实时数据，不能代替真实小窗验收。 |
| 普通 M4 Mac mini／竖屏／49 项严格视觉 | NOT RUN：本次开发机为 Apple M5 Pro；保留既有独立验收状态，未宣称全部完成。 |

安装版主可执行文件 SHA-256：`fb1b6922b4c0d5e86fdb53bbbde7247474d1e0c23ea3c3ce65b9357519d29a1c`。本轮源代码的改前快照、增量补丁和哈希清单也保存在上述证据目录；未推送、未发布正式版或修改正式更新源。
