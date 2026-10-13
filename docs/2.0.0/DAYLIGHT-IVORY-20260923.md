# 2.0.0 Beta 象牙白日间配色（2026-09-23）

基于 `codex/2.0.0-beta-r2` 的现有未提交工作增量修改。用户选择偏暖象牙白，并要求图标不泛灰、底色不要冷灰。修改限定为日间语义配色、侧栏与设置图标；不重置既有工作，不改夜间主题或扫描、清理、采样和硬件控制路径。

| 日间角色 | 改前 | 最终 |
|---|---|---|
| 主背景（上／下） | `#E8EBEA`／`#DEE3E1` | `#F0ECE2`／`#E9E4D9` |
| 侧栏（上／下） | `#F2F4F2`／`#E7EBE9` | `#F7F0E6`／`#EEE6D9` |
| 卡片／次级表面 | `#FAFBF9`／`#EEF1EF` | `#FBF7EF`／`#F3EEE5` |
| 普通边线／侧栏图标 | `#C9D1CD`／`#626C69` | `#D2C7B7`／`#895A32` |

文字层级改为暖墨灰，提示表面改为 `#F9F4EA`。图标保留青绿选中与有含义的数据颜色；暖棕只用于原来发灰的中性图标。小窗已保存的图表颜色偏好继续决定图表颜色。日间层次独立定义，没有把夜间页面反色。

## 安装与实图

证据目录：`/Users/developer/Documents/好玩的/StorageCleanerMac-ivory-palette-20260923/`。

- `before-smart-scan.png`：修改前已安装的石墨灰日间版。
- `final-complete-smart-scan.png`：最终 `2.0.0 (20260923035311)` 的真实主窗口。
- `final-complete-settings-mini.png`：同一最终安装版的真实设置窗口；右侧明确是模拟预览，不冒充真实小窗采样。
- `final-dev-tools.png`：前一轮暖白构建的开发工具页面，用于检查图标；最终轮只补了设置标题图标与侧栏次级文字、边线，未重新采集该页面。

开发机截图人工检查了上述两张最终实图，确认主背景、卡片、侧栏及设置标题齿轮呈暖色，字仍可读。此项是有限页面抽查，不是 49 项严格视觉验收；真实小窗悬浮窗口的最终截图未取得。普通 M4 Mac mini 和竖屏也未在本机实测。

## 本地验证

| 项目 | 结果 |
|---|---|
| 日间定向测试 | PASS：`./script/test.sh --filter 'DaylightRefinementTests|DayAppearanceTests'`，14 项零失败；日志 `appearance-targeted-complete.log` |
| Release 全量 | PASS：2867 项，17 项按既有条件跳过，零失败 |
| Debug 全量 | PASS：2922 项，18 项按既有条件跳过，零失败 |
| 严格并发构建 | PASS：`script/verify.sh` 使用 `-strict-concurrency=complete`，整体验证退出码 0 |
| 小窗性能回归 | PASS：10 项；准备数据 P95 为 48.96 ms，缓存数据交付 P95 为 0.003 ms；不是鼠标到像素的实际交互延迟 |
| Beta 构建及安装 | PASS：`STORAGE_CLEANER_SKIP_TESTS=0 ./script/build_and_run.sh --beta --install`，退出码 0；完整日志 `beta-install-complete.log` |
| 安装身份与签名 | PASS：`com.local.StorageCleanerMac.beta`、`2.0.0 (20260923035311)`；`codesign --verify --deep --strict` 退出码 0。签名为 Apple Development，并非 Developer ID／公证证据 |
| 唯一测试版 | PASS：安装后 `/Applications` 仅 `/Applications/测试版.app`；删除了经 Bundle ID 核对的旧 `.previous.app` 和两份临时打包 App |
| 真正小窗／M4 mini／49 项视觉 | NOT RUN：模拟预览和主窗口抽查不替代这些验收，原严格视觉记录仍为 `0/49` |
| 正式发布 | NOT RUN：未推送、未发布 Release、未更改正式 appcast、未覆盖正式 App |

安装版主可执行文件 SHA-256：`4b9b47617e2c48c038d6d442db53dc7e0c8264748dfba630012a8378dfef7a21`。App 约 83 MiB。截图与日志保留在证据目录；其中 `source-before/` 保存改前源码，便于审核本轮增量。
