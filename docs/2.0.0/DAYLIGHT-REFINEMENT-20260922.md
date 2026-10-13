# 2.0.0 Beta 日间主题与小窗边框修整

> 后续用户已将近白／6 pt 要求改为银灰／0 pt 紧贴；最终续查见 [银灰日间与紧贴菜单](DAYLIGHT-FOLLOWUP-20260922.md)。本页保留首轮历史证据。

本轮基于 `codex/2.0.0-beta-r2` 的原工作区增量修改，未重置、提交、推送、发布或改动正式更新源。正式版安装保持原样。开发机为 Apple M5 Pro（18 逻辑核心、48 GiB、macOS 27.2），不是普通 M4 mini。

## 实际修改

- `AppAppearanceColors`、`AppDesignTokens`、`ModuleTheme`：雾白页面、白色卡片、墨灰文字、青绿主操作及浅青绿选择背景；日间不再铺设模块色光晕。夜间模块配色保留。
- `GlassStyle`、运行状态与设置：浅色卡片中性化，权限、警告、失败、暂停和部分结果的语义保留。窄窗口备用插画亦有日间表面。
- `GoldenLandingArtwork`：12 张单独日间派生素材，保留原文件；取消从亮度推断透明度的统一蒙版，按外观和目标像素大小限额解码缓存（32 MiB / 16 项）。
- `MiniWindowStyleTokens`、公共外壳：级间 6 pt、外壳圆角 12 pt、卡片圆角 10 pt、控件圆角 6 pt、外边距 8 pt、卡片间距 6 pt、普通行距 4 pt。外框和状态边框均为一个物理像素。
- `MenuBarTertiaryDetail`、历史内容、电池与网络详情：由父页面负责外边距，移除重复 padding；网络三级详情在内嵌时不再强制额外固定宽度。
- 电源二级高度改为由卡片、标题和间距计算，修复新增间距后少 3 pt 的底部空间。
- 实际小窗、独立控制浮层及设置预览复用背景/图表颜色解析。内置日间面板不染紫，紫色图表偏好和显式自定义颜色保留。预览仅读取配置和静态模拟数据。
- 测试夹具的快速切换循环统一使用模拟指针；原来部分读取真实桌面指针，用户移动鼠标会触发生产重排保护并干扰夹具。生产保护与所有断言均保留。
- 真实界面检查后，将主窗口、设置、小窗和控制浮层的主次文字层级接入语义颜色；健康结果页及中性玻璃卡片在日间使用白色表面，夜间原配色不变。
- 独立运行测试发现 `MenuBarPanelSession` 的性能记录无条件读取 `NSApp.currentEvent`，在应用对象尚未初始化时触发 SIGTRAP；改为可选读取，记录机制不再要求应用对象预先存在。两个曾崩溃的类及相关主题共 43 项定向回归通过，未将此次测试进程崩溃误记为已安装 Beta 崩溃。

## 颜色证据

| 前景 / 背景 | 对比度 | 判定 |
|---|---:|---|
| `#202629` / `#F4F5F6` | 14.04:1 | PASS |
| `#535D62` / `#FAFBFC` | 6.52:1 | PASS |
| `#647078` / 白色 | 5.08:1 | PASS |
| `#147D70` / 白色按钮文字 | 5.00:1 | PASS |
| 用户紫色图表 `#BF5AF2` / 白色 | 3.52:1 | PASS（图形） |

`#D6DBDE` 是非交互装饰边线，不能以它证明必要控件达到 3:1。增强对比度路径另用较深的边线。以上为颜色令牌计算，不代替逐个实机组件验收。

## 证据分类

证据目录：项目旁的 `StorageCleanerMac-daylight-evidence-20260922`。

- `daylight-concept.png`：GPT Image 概念参考，仅表达色彩、材质和层级，不是产品截图。
- `runtime-fixtures/`：真实 SwiftUI 组件使用受控数据渲染的截图，不是清理真实文件的执行结果。
- `main-before.jpg`：更新前安装版的真实窗口。原生界面工具返回 JPEG，按实际编码保存；未进行像素修饰。
- `baseline.json`、`source-before.zip`、`incremental.diff`：本轮输入和增量；保留原有未提交工作。
- `artwork-manifest.json`：12 张派生资源及其原素材的版本、尺寸、SHA-256。
- `run-local-validation.sh`、`run-debug-isolated.py` 与各阶段 `.log/.exit`：命令、失败、退出码和完整覆盖记录。

## 验证边界

- 常规 Debug 全量已执行；旧 CPU 快速内核有间歇 15 秒保护超时。原实现、任务量和保护限时未修改。独立用例通过不能抹掉全量中的失败；保留全部初次/重跑日志。
- 所有原有 Debug 用例再按类隔离顺序运行，核对用例清单，防止漏跑；不删除断言、不将失败改为跳过。
- 跳过项为原有明确 opt-in 的真实扫描、升级安装、性能捕获等；本轮未设置 `STORAGE_CLEANER_SKIP_TESTS=1`。
- 100 次几何布局与快速三级路由/控制浮层互斥循环属于模拟或程序驱动的原生窗口测试，不能称为 100 次真人鼠标跨间隙操作。
- 缓存/数据准备耗时不能代替输入到屏幕呈现延迟。实机 P95、连续主线程阻塞、1× 外接屏、旋转/热插拔与普通 M4 mini 没有取得的证据均不标 PASS。
- 原 49 项严格视觉记录保持独立，本轮不修改其通过数。
- Apple Development 签名与 Developer ID、公证、Gatekeeper、Sparkle 归档签名是不同证据。本轮仅本地 Beta，不进入正式发布。

## 本轮交付记录

当前应运行 `/Applications/测试版.app`，版本 **2.0.0 Beta / 20260922092617**。工作分支与原 HEAD 不变，BuildInfo 明确记录 dirty 输入；没有提交工作区改动。

| 检查 | 结果与证据 |
|---|---|
| 定向回归 | PASS：43 项，0 失败；`final-targeted.log/.exit`，退出 0 |
| Debug 全用例按类隔离 | PASS：191 类 / 2,919 项，2,901 通过、18 原有跳过，无遗漏；`debug-isolated-summary.json`，退出 0 |
| Debug 单进程全量 | FAIL（保留）：旧 `testStandardQuickKernelsCompleteWithinDeclaredLimits` 有间歇 15 秒保护超时；未延长保护、减少任务或改为跳过。不能把隔离通过改写成这一轮通过 |
| Release 全量 | PASS：2,864 项，17 原有跳过，0 失败；`final-release.log/.exit`，退出 0 |
| 严格并发 | PASS：`-strict-concurrency=complete`，退出 0，无警告；`final-concurrency.log` |
| 打包前本地性能检查 | PASS：10 项；准备 P95 31.29 ms、缓存派发 P95 0.005 ms。仅为数据准备/派发，不是输入至屏幕延迟 |
| 实际三级导航 | PASS（100 次累计成功）：已安装 Beta 的 CUA 点击与辅助功能动作，5 类详情各 20 次；`actual-mini-navigation-100.json`。第 65 次尝试前有外部窗口点击，正常关闭小窗；保存生命周期日志，正常重启后完成其余 36 次。不是一次无中断的 100 次悬停测试 |
| 真实日间窗口 | 主页面逐页检查；最终包复核智能扫描、健康结果及 CPU、内存、磁盘、网络、传感器、电池三级详情。反向展开保留间隔，电池最后一行可见 |
| 设置与预览 | 首个日间候选实测浅色/深色切换、英文、内存模拟预览和历史；恢复中文、浅色与原紫罗兰偏好。模拟预览截图不是实时采样证据 |
| 独立风扇浮层 | BLOCKED：检查工具仍选择后面的小窗，未取得浮层焦点与画面；两次尝试已保存。没有应用真实转速 |
| 连续手动 resize / 完整悬停路径 | NOT RUN：拖拽调用未得到可核验的尺寸变化；不能据此标通过。1×/2×、断点及 100 次几何布局测试属于模拟证据 |
| 输入/呈现 P95、50 ms 主线程门槛 | NOT RUN：未取得真实端到端测量 |
| M4 mini、旋转、负坐标副屏、热插拔、辅助功能系统开关 | NOT RUN（实机）；既有模拟/逻辑测试另列，不冒充硬件实测 |

Release 日志包含测试宿主的 CoreData/XPC 连接诊断、未安装到视图时访问 Environment 的测试警告和重复 rpath 链接警告；严格并发构建无警告。日志原样保留。初次隔离测试从错误工作目录启动导致三个资源查找失败，修正启动目录后重跑全部用例，未改相关断言；失败日志保存在 `debug-isolated.wrong-cwd/`。

### 构建、安装和清理

- 本地 Release/Beta 构建和 `codesign --verify --deep --strict` 通过；Apple Development 签名，hardened runtime 已启用。没有 Developer ID、公证或正式发布验收。
- 安装前比较 Bundle ID、升级构建号、独立 feed 和公钥，安装后核对 12 张资源、可执行文件和运行路径；更新源与公钥未变。
- 可执行文件 SHA-256：`8f09a13bdedfdd69bf9f73d0c18889338c20400948d6a56fdafee8c75b0531cd`。
- 相同计数口径（文件逻辑大小，不重复计算符号链接）：原包 77,376,493 bytes，新包 86,179,783 bytes；增加 8,803,290 bytes，主要是保留原素材并新增 12 张日间素材。没有将源码体积当作 App 体积。
- 删除本轮 4 个临时/回退 Beta App，仅保留 `/Applications/测试版.app`。本轮未创建 ZIP/DMG 安装包。源码备份 `source-before.zip` 和验收证据保留。
- 正式 `/Applications/存储清理助手.app` 仍为 1.10.1；没有 push、tag、Release、远程安装或正式 appcast 修改。

### 画面与增量

- 前后主窗口：`main-before.jpg` / `final-main-window.jpg`；最终健康页：`final-health.jpg`。
- 实际小窗：`final-mini-overview.jpg`、`final-mini-cpu-tertiary.jpg`、`final-mini-memory-tertiary.jpg`、`final-mini-disk-tertiary.jpg`、`final-mini-sensors-tertiary.jpg`、`final-mini-battery-tertiary.jpg`。
- 网络截图含本机地址，仅保留本地 `final-mini-network-tertiary-local-only.jpg`，不得直接作为脱敏对外素材；文件分析页也含本地路径。所有实际截图保留原始画面，未修饰像素。
- `incremental.diff` 相对本轮源码备份生成，不将全部历史 dirty 改动冒充本轮修改；`modified-files.json`、`artwork-manifest.json` 和源码输入清单提供哈希。

**未达到完整计划验收或正式发布门槛。** 风扇独立浮层、完整连续缩放/悬停、真实性能和 M4 mini 等剩余检查仍需完成；原 49 项严格视觉记录没有改动。
