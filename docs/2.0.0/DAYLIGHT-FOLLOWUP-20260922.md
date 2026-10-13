# 银灰日间与紧贴菜单续查 — 2026-09-22

基于现有 `codex/2.0.0-beta-r2` 的 dirty 工作区，HEAD 保持 `6ec0a148c559fd1daf3c5ddf0e43b520cc82c717`。保留历史修改。本轮用户后续明确要求“参考 iStat 配色”和“三级菜单之间不要空隙”，替代上一轮的近白背景／6 pt 间隔。

证据目录：项目旁 `StorageCleanerMac-daylight-followup-20260922`。`source-before.zip` 保留本轮涉及文件修改前内容；`incremental-source.diff` 与 `modified-files.json` 仅记录本轮增量及哈希。

## 实际修改

- 参考 [iStat Menus 产品](https://bjango.com/mac/istatmenus/)及[独立主题设置](https://bjango.com/help/istatmenus7/global/)，并只读查看本机 iStat。采用本应用自己的银灰分层：页面 `#DADDE3`、内容 `#ECEEF1`、次级表面 `#DDE0E5`、侧栏 `#D2D5DC`、边线 `#B9BFC9`、主文字 `#202629`。这些不是宣称取自 Bjango 内部的色值。保留紫色图表偏好、青绿操作色和全部夜间色值。
- `AppAppearanceColors`、`AppDesignTokens`、`ModuleTheme` 与窄窗口备用插画共用上述表面；降低透明度时也不回退成纯白卡片。
- `MiniWindowStyleTokens.cascadeGap` 为 **0 pt**。独立风扇／电源浮层原来还有 4 pt 常量，已改为使用同一个配置。布局和鼠标通道同步使用它。
- `GeekAttachedPanelChromeGeometry` 让接触处合并圆角、共享边只绘制一次；外侧仍为 12 pt 圆角。支持左右、上下、部分高度重叠和阶梯外缘，避免接缝双线、圆角空洞或漏边。内部卡片 10 pt、页面留白 8 pt、卡片间距 6 pt 未改。
- 独立控制浮层英文实际／目标 RPM 不再强制一行省略，宽度不足时标题和值上下排列。辅助文字直接使用语义文字色。
- 风扇原生布局回归必须等待展开后的新自然高度；修复原测试可能以旧紧凑高度过早判定通过的问题。

JEV 已用于范围和配色判断，结果见 `jev-decision.json`、`istat-palette-jev.json`。没有把模型判断当作实测证据。

## 回归与失败记录

- 间隔根因复现：独立浮层原 4 pt 与当时的 6 pt 规范不一致，1 项失败；修复后定向通过。后续用户要求 0 pt，生产与预期共同更新为 0。
- 紧贴布局定向：150 项、0 失败，含 100 组三级几何布局、反向／上下布局、部分接边和鼠标接缝状态；这是逻辑／原生组件测试，不能等同于真实鼠标悬停 100 次。
- 银灰最终外观定向：13 项、0 失败；所有文本对比度仍至少 4.5:1，图表必要表达至少 3:1。旧测试规定画布亮度 >0.8，因用户拒绝近白背景而改为银灰亮度区间 0.6–0.8；文字对比度、安全和性能断言未放宽。语义色与图表标签现在对实际灰色卡片检查，而不是假设白底。
- `silver-acceptance-debug`：2,921 项／18 原有跳过／14 失败，均为上述旧白底亮度断言；保留原日志。
- `joined-final-debug`：2,921 项／18 原有跳过／1 失败，为网络取消后 URLProtocol 停止计数偶发为 0。未修改生产网络链路或该断言；单独重跑整个网络服务组 45 项通过。下一轮完整 Debug 中该项通过；偶发失败仍保留，不宣称已定位修复。
- `joined-confirmed-debug`：2,921 项／18 原有跳过／1 失败，网络取消通过，但旧 `testStandardQuickKernelsCompleteWithinDeclaredLimits` 在 15.005 秒触及 CPU 内核超时。即时只读检查显示其他应用同时占用 CPU，未记录系统热警告；并发负载可能有影响，但未证明因果。没有关闭工作应用、放宽期限或改成跳过。最终 Debug 整体为 **FAIL**，不是全绿。
- `joined-confirmed-release`：**PASS**，2,866 项／17 原有跳过／0 失败，退出 0。跳过理由逐项保留在 `joined-release-skip-reasons.txt`，包含显式硬件／手动优化验证门槛，没有新增跳过。
- `joined-confirmed-concurrency`：**PASS**，`-strict-concurrency=complete` 构建退出 0。
- 打包前优化性能组：**PASS**，10 项／0 失败；这是计算及缓存回归，不代替真实输入到绘制延迟测量。
- 本轮之前的近白／6 pt 全量通过和构建保留为历史，不代表最终银灰／0 pt 源码。

## 界面证据边界

- 原安装版主窗口宽度 1280 → 981 → 850 → 1280 的真实拖动已记录，高度都是 713。竖向、角落及设置窗口尝试未取得可核验尺寸变化，标记未通过验收，不能宣称连续宽高全部完成。
- `silver-joined-fan-fixtures` 为 64 张中英文 × 日夜 × 八种只读硬件状态 × 展开／收起原生组件截图；全部禁用硬件写入。布局、读数换行及末行经过检查，但不等于真实风扇调速或 M4 mini 实测。
- `silver-runtime-fixtures` 为实际 SwiftUI 运行状态的隔离数据截图；紧凑尺寸使用滚动视口，不能将局部截图当作整个内容一次可见。没有扫描／清理私人文件。
- **安装后实机证据：** `installed-before-silver.jpg` 与 `installed-silver-cleanup.jpg` 对比相同安全清理页，页底从近白改为银灰，卡片保持较亮灰，素材及原生文字控件未重绘。`installed-silver-start.jpg` 是新版智能扫描页。`installed-silver-mini-open.jpg`、`installed-silver-cpu-three-levels.jpg`、`installed-silver-disk-three-levels.jpg` 和第 100 次的 `installed-silver-final-cycle-100.jpg` 是实际已安装小窗；三级页面零间距相接且高度不同时外侧边缘完整，最后一行可见。实际点击／辅助功能导航 **100 次全通过**，覆盖 CPU、内存、磁盘、网络和电源页面，原始逐次记录在 `installed-joined-navigation-100.json`。这验证了路由能打开，未测量鼠标悬停延迟。
- 同尺寸安全清理页在空白背景的同一点 `(750, 400)`，安装前截图 RGB 为 `244,245,247`，新版为 `220,221,226`；这是实际截图像素，不是仅由源码色值推断。
- **唯一测试版：** `/Applications/测试版.app` 已由 2.0.0 Beta build `20260922092617` 升为 `20260922113332`，运行文件 SHA-256 `35e838a578401554fab865e6c573de02ee0cf4e449ef8f68ac7d9e1ffe8940fd`。运行进程路径、Bundle ID、Beta 更新源、公钥和签名已核对。安装版 `codesign --verify --deep --strict` 退出 0；Apple Development + hardened runtime，不是 Developer ID 或公证发行证据。
- 安全替换在旧应用正常退出后执行，签名与可执行哈希匹配后才把旧版移至临时回退名。新版成功启动后移除一份经哈希验证的旧版回退副本和两份相同的新包临时 App，剩余 `/Applications` 只有一份 `com.local.StorageCleanerMac.beta`。正式版可执行文件哈希与安装前一致。
- 生成包检查：`joined-confirmed-package` **PASS**，退出 0；优化性能组 10 项通过、Beta 产物签名通过。没有制作本轮 ZIP/DMG，也没有在线发布。

## 尚未完成及发布边界

开发机为 M5 Pro，不是用户的普通 M4 mini。M4 mini、1× 屏幕、旋转、负坐标副屏和真实热插拔未验证；完整连续宽高调整、所有真实运行状态逐页视觉、真实输入至呈现 P95、主线程最长阻塞仍未完成。独立风扇浮层的真实焦点截图仍受窗口选择限制。

原 49 项严格视觉记录独立，不用本轮测试数覆盖。没有 push、tag、Release、上传、正式 appcast 修改或真实硬件策略写入。正式版不变，本次不具备正式发布结论。
