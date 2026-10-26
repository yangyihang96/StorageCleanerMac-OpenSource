# 交接：D154 第三批 Q（扩展、维护任务工具面板左栏的彩色小图标）

日期：2026-10-22。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `98cc7fb7`（v2.0.1 整树，含 D154⑱ 和 D166③ 的六张新图）。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 用户要求

用户原话（10-22）：“下一批做扩展和维护任务工具面板左栏的彩色小图标，照 CleanMyMac 管理器左栏。”

依据：`图位与动效清单.md` C 节，扩展、维护任务、聊天文件这三个工具面板的左栏原来是符号；聊天文件已经用应用自己的图标，剩下扩展和维护任务。逆向记录里，CleanMyMac 维护任务管理器的每项任务都有自己的图（`maintenance-tasks_free-up-ram`、`…_flush-DNS-cache`、`…_speed-up-mail` 等）。做图清单：`图位清单-工具面板左栏.md`。

## 2. 改了什么

- 左栏每行一个 D166 小物件：`ExtensionKind.art`、`SystemMaintenanceTaskID.art`，分别写在两个页面文件里，传给左栏行 `ToolboxCategoryRow` 的 `art`（第三批 F 加的参数）。行组件会把物件转成面板所在模块的颜色：扩展转成应用的蓝，维护任务转成登录项的橙。这和登录项、杂乱文件等管理器的左栏是同一种做法。
- 用图，两个面板各 9 行，同一面板里互不重复：

| 维护任务 | 物件 | 扩展 | 物件 |
|---|---|---|---|
| 释放内存 | `tile-freeable` | 偏好设置面板 | `tile-general` |
| 可清除空间 | `tile-purgeable`（新） | 互联网插件 | `tile-othersources` |
| 刷新 DNS | `tile-othersources` | 快速查看插件 | `tile-quicklook`（新） |
| 加速邮件 | `tile-mail` | Spotlight 导入器 | `tile-review` |
| 重建 Spotlight 索引 | `tile-review` | 屏幕保护程序 | `tile-screensaver`（新） |
| 修复磁盘权限 | `tile-permissions`（新） | 音频插件 | `tile-audio`（新） |
| 运行维护脚本 | `tile-maintenance` | 内核扩展 | `tile-processes` |
| Time Machine 本地快照 | `tile-history` | Safari 扩展 | `tile-browsers` |
| 刷新“打开方式”数据库 | `tile-sync` | 应用扩展 | `tile-appextension`（新） |

- 6 张新图由 2.0.1 会话做（D166③）。图的文件、case、`dominantHue` 和图片测试都在它的补丁里，本批只接线。
- 右边不变：扩展列表的每一项仍用所属应用的图标，维护任务的详情区本来就没有图。
- `ToolboxWindowReviewTests` 的三个面板改用 app 里实际的模块：扩展 `.applications`、维护 `.startup`、聊天文件 `.clutter`（原来三个都是 `.startup`），截图颜色与 app 一致。检查项不变。

## 3. 建议的 DECISIONS 行

| # | 决定 | 影响 |
|---|---|---|
| D154⑲（编号由 2.0.1 会话定） | 扩展和维护任务工具面板的左栏每行一个 D166 小物件，转成面板所在模块的颜色，同一面板 9 行互不重复：12 行用现有物件，6 行用 D166③ 的新图。 | 扩展、维护任务 |

## 4. 测试

- 新增 `ToolboxCategoryArtTests`（非窗口，3 个）：
  - 两个面板每行都有小物件（`tile-`，只导 192），会转色（不是 `keepsOwnColour`），同一面板里不重复；
  - 评审渲染（设了 `STORAGE_CLEANER_TOOLBOX_EVIDENCE` 才运行）：用 ImageRenderer 画两个左栏，因为窗口截图画不出 `hueRotation`，转色后的样子要靠它看。
- `ToolboxWindowReviewTests`：模块与 app 一致，检查项不变。
- 原有测试的期望都没改。

## 5. 验证

全部在 Xcode 27.1、`98cc7fb7` 加本批改动上，按 D106 补充②的三段式跑：

- debug 编译通过；release 编译、release 测试目标（`--build-tests -Xswiftc -enable-testing`）编译通过，本批文件无警告。release app 编译在 17:36 机器重启前已完成；release 测试目标被重启打断，17:52 拿到 `heavy-build.lock` 后续编完成。
- 窗口全量 627 个（虚拟屏 2，10-22 16:51–17:12，先拿了 `virtual-display-2.lock`，跑完即释放；开了截图目录）：0 失败，与基线一致。`ToolboxWindowReviewTests` 在三种窗口尺寸下检查行和主按钮都在窗口内，通过，并出了 18 张截图。
- debug 非窗口三段（17:13–17:21）：主包 XCTest 5585 个 0 失败（28 个跳过；比上一批多本批 3 个，多跳过的 1 个是不设截图目录时跳过的评审渲染）；CombinedStatusIconTests 285 个 0 失败；Swift Testing 135 个通过；没有通讯录相关行。
- release 非窗口三段（18:05–18:36，持 `heavy-build.lock`）：主包 5332 个，1 个失败：`GPUTensorBenchmarkKernelTests.testSystemDriverCompletesTestingWorkloadsWhenMetalIsAvailable`（`BenchmarkKernelError.resourceLimit`，GPU 跑分超出时间上限）。本批没碰 GPU 和跑分代码，17:13 的 debug 门禁里这条是通过的；18:36 在 release 下单独重跑这一类，9 个全部通过（这条 0.5 秒）。27 个跳过。CombinedStatusIconTests 285 个 0 失败；Swift Testing 135 个通过；没有通讯录相关行。
- 核对图：评审渲染画出两个左栏 18 行，扩展一栏转成蓝色、维护一栏转成橙色，6 张新图在 28 pt 下都认得出（`工具面板左栏图标-第三批Q.png`）。窗口截图里物件是原色，因为截图画不出 `hueRotation`，这是已知限制，不是没转色；780 宽的窗口里左栏标题和说明完整，物件不挤。
- 未核对：没装测试版，没在真实 app 里看这两个面板。

## 6. 下一步

- 空间地图页的数字计数：等 Disktree 第 2 期合入后，看要不要接。
- `图位与动效清单` A 节剩下两项可选：安全防护主图改成盾形、空间地图主图改成气泡。
