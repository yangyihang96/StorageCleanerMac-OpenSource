# 2.0.0 Beta 日间配色实测（2026-09-23）

本轮只修改当前 `codex/2.0.0-beta-r2` 工作区和本地测试版。参考[腾讯柠檬官网](https://lemon.qq.com/)的浅色界面中性底面、暖色焦点和绿色操作色的使用方式，颜色、图形和组件均由本项目自行实现；没有复制其素材或宣称取得其精确色值。夜间主题、用户紫色图表偏好、已有功能与数据口径保留。

## 实际修改

| 区域 | 此前 | 本轮 |
|---|---|---|
| 主页面 | 银灰表面整体提亮，局部白底和模块色叠加 | 暖纸色画布、暖白内容卡片、浅绿侧栏、深墨色文字；小面积琥珀色标识与青绿色主操作 |
| 智能扫描 | 浅色模式仍使用蓝紫光晕素材 | 浅色模式用原生矢量青绿轨道和暖色节点；深色仍使用原素材 |
| 安全清理 | 四块大面积高饱和色填充 | 浅色选择卡片与稳定边线，风险语义色及实际扫描行为不变 |
| 设置 | 系统亮蓝选中底与页面暖绿混用 | 整行按钮继续使用原选择绑定，选中底与主窗口统一；保留草稿的应用／取消保护，增加方向键切换 |
| 性能与文件分析 | 整块紫红主按钮、紫色大标题块和系统亮蓝选中行 | 青绿主按钮、中性大标题块与浅绿选中行；小图标及图表颜色继续表达类别和数据 |
| 小窗 | 已有浅色独立外壳及紫色图表设置 | 随本轮语义表面颜色同步，仍保留紫色图表偏好与零间隔三级菜单 |

## 构建与验证

- 源码分支：`codex/2.0.0-beta-r2`；基线 HEAD：`6ec0a148c559fd1daf3c5ddf0e43b520cc82c717`。已有未提交修改保留，本轮增量见 `StorageCleanerMac-daylight-lemon-pass-20260922/incremental-source.diff` 与 `incremental-manifest.json`。
- 命令：`STORAGE_CLEANER_SKIP_TESTS=0 SWIFT_BUILD_JOBS=4 SWIFT_BUILD_DIR=/tmp/storage-cleaner-2.0.0-r2 BETA_DIST_DIR=/tmp/storage-cleaner-2.0.0-r2-beta-artifacts ./script/build_and_run.sh --beta --install`，退出码 **0**。最终完整日志：`StorageCleanerMac-daylight-lemon-pass-20260922/lemon-final-install.log`。前一个候选及其日志保留以解释改进过程，不冒充最终包测试。
- Release 全量：2867 项，17 项按原测试条件跳过，0 失败。Debug 全量：2922 项，18 项按原测试条件跳过，0 失败。小窗性能定向：10 项通过，最终准备 P95 43.3 ms、缓存交付 P95 0.0022 ms；这不是实际鼠标到绘制延迟。
- 最终安装：`/Applications/测试版.app`，版本 **2.0.0**、构建 **20260923004123**、Bundle ID `com.local.StorageCleanerMac.beta`。`codesign --verify --deep --strict` 通过；实际签名为 **Apple Development**，不是 Developer ID 公证发行证据。运行 PID 30315 的路径是此安装包。
- 已安装 App 实际占用约 **83 MiB**；可执行文件 SHA-256：`a1a7d773742ec7e72df3fe4a69c1b1c7c4c74f505005b8f257af7d66d6eb1199`。本轮未生成供分发的 ZIP／DMG，不用此 App 体积冒充压缩包体积对照。
- 在 M5 Pro MacBook Pro 上实际打开主窗口、清理、性能、文件分析、设置与小窗。性能主操作已变为青绿，文件分析选中行已变为浅绿；设置左侧点击“通用”，方向键下移到“小窗”，再上移回“通用”，选择与右侧内容同步。最终安装版截图：`accepted-smart-scan.png`、`accepted-safe-cleanup.png`、`accepted-performance.png`、`accepted-file-analysis.png`、`accepted-settings.png`、`accepted-mini.png`，均在上述证据目录。
- 安装后删除已核对 Bundle ID 的上一测试版备份与两个临时 App 副本，`/Applications` 内仅见 `/Applications/测试版.app`。正式版和正式更新源未改；无远程操作。

## 边界

- 本轮截图是开发机实际 App 的局部视觉检查，不代表全部页面、全部运行状态或 49 项严格视觉验收完成；原记录仍为 **0/49**。
- 普通 M4 Mac mini、不同显示缩放／副屏及系统增强对比度的真实视觉验收尚未进行。签名、公证、Gatekeeper、Sparkle 正式升级各自仍需独立证据。
- 测试日志含系统 Contacts/CoreData 连接告警及原有按条件跳过项；总测试结果为通过，不将系统告警误记为本项目崩溃。
