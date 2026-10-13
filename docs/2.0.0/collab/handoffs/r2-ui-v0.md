# 批次 r2-ui-v0：UI 2.0 V0——设计基础 + 智能扫描与内存管理两页样板（D53、D56、D58）

- 分支 `task/r2-ui-v0`，起点 `6e2cb95`（已含 r2-u1-preselect）；按主会话要求四次并入集成分支（第四次是复核修复轮开始前的 `14c1127`，合并提交 `a092891`，见第 0 节；之后集成分支又前进到 `100062a`（r2-privacy-edges 与文档），试合并无冲突，未再并入）：`5200ae0`（合并提交 `ce24ff0`）；最终验证前 `4fea34d`（合并提交 `ca8be22`，含 r2-test-hygiene／D48、r2-u1-followups、D46；唯一冲突 `Debug/MainWindowSnapshotPipeline.swift`，两边都在文件末尾新增 Debug 类型，均保留）；交付前集成分支又前进到 `7d654d4`（r2-mini-sensors／D57 与 D59、D60 文档），再并入一次（合并提交 `62b60c2`，无冲突；JEV 选“再并入”p=0.97）。之后只有两处小修：Debug 截图修正 `9630ed8`，性能测试页页头插画映射 `aff331e`（最终代码 HEAD，其后只有文档提交）。守卫、定向、全量测试在 `aff331e` 上；改后截图中含 14 页的 3 组在 `aff331e` 上重拍，扫描中／结果页／可退出应用 9 组用 `9630ed8` 包（不含性能测试页，界面相同）；空闲 CPU 在 `9630ed8` 上（初始页不受后一处影响）；`verify_menu_bar_performance.sh` 在 `62b60c2` 上（之后的改动不涉及菜单栏代码）。worktree `~/Developer/sc-worktrees/r2-ui-v0`。
- scratch `~/Developer/.sc-build/r2-ui-v0/`：`debug/`（Debug 构建、定向与全量测试，保留给后续修改）、`logs/`、`shots/`（截图与录屏）、`before-overlay/`（改前包的截图管线叠加补丁）、`tools/`（本批脚本）。按 RULES 随时清缓存：改前包 `dist-before/`、录屏包、截图用的 `.app` 副本、Release 验证目录 `verify/`、打包编译缓存 `/tmp/storage-cleaner-r2v0-before`／`-after` 都在用完后删除，录屏的原始 `.mov` 转成 MP4 后删除。全部构建离线（`--skip-update --disable-automatic-resolution`）。
- 实现：Claude 子代理（Claude Opus 5.5）。依据：DECISIONS D53（`docs/2.0.0/UI-V2-SPEC.md`）、D56（夜间默认深空）、D58（生成插画，风格 A），以及主会话在批次中途的补充（集成并入与 `TestPreferenceDomain`、截图管线与行数统计、6 项视觉调整、D56、06b 修正、D58 接入、随时清缓存）。
- 没有修改 `Stores/ScanStore.swift`；没有修改 D46 批次的 `LargeFilesView.swift`、`StorageTreemapView.swift`、`CleanupExecutionViews.swift`；没有改任何清理、预选、确认、执行语义（D47、D49、D52、N19）；菜单栏小窗未改（D56）。没有修改 `DECISIONS.md`、`BOARD.md`。
- 没有安装、没有碰 `/Applications`、没有启动或退出已安装的测试版／正式版；截图与录屏只启动 scratch 里自建的 Debug 包副本，身份 `com.local.StorageCleanerMac.integration`，语言、外观、底色一律用启动参数（volatile argument domain），不写共用偏好域；演示数据只用夹具；没有真实扫描或清理，没有写硬件设置；没有 push；没有读凭证。新增和改动的测试不写真实 `~/Library/Preferences`（底色主题用 `AppCanvasTheme.withCurrent` 在内存里切换），不在真实 `~/Library/Caches` 建夹具。

## 结论

- **第三个小轮（10-08）**：sol 增量核对提出的 2 个新 P2 已修（第 0.3 节），各有改回即失败的行为测试并已反证；探针超时现在给出缺失 ID。最终代码 HEAD `65dbd69`：守卫 exit 0（8 项）；定向 39 类 exit 0（703 项，跳过 2，0 失败）；全量 exit 0（3850 项，跳过 25，0 失败）；严格并发全新构建 exit 0，诊断 0。
- **第二轮复核修复（10-08）**：gpt-6.1-sol 增量复核的 6 个 P2 全部处理（第 0.2 节），每项都有在改回时失败的测试或构建诊断，并逐项反证；P2-6 记录了平台本身已排除旧页鼠标命中的运行时证据。最终代码 HEAD `1abca72`：守卫 exit 0（8 项）；定向 39 类 exit 0（700 项，跳过 2，0 失败）；全量 exit 0（3847 项，跳过 25，0 失败）；严格并发全新构建 exit 0，隔离诊断 0。
- **复核修复轮（10-08）**：复核的 8 个 P2、契约 #11 验证、契约 #5 说法和 `git diff --check` 全部处理（第 0 节）；最终代码 HEAD `f6d1e40`：守卫 exit 0（8 项）；定向 39 类 exit 0（696 项，跳过 2，0 失败）；全量 exit 0（3843 项，跳过 25，0 失败）；12 组改后截图全部用 `f6d1e40` 重拍（255 条记录全部通过），102 张并排图重新生成；空闲 CPU 0.00%／1.50%／0.00%（与之前相同的一次性 AppKit 快照）。减弱动态效果下的关键帧 NOT RUN（本机未开启该设置，我不能改系统设置）。下面几条是第一轮交付时的状态。
- **完成**：V0 范围全部做完——令牌 v2（三套底色，D56 默认深空、已存纯黑保留）、`AppMotion`、`PageLayout` 与自适应容器、`Views/DesignSystem/` 组件、侧栏（< 960 pt 收成图标栏、选中块滑动）、`PageHero`、切页过渡、模块光晕；样板页智能扫描（初始页／扫描中／结果页）与内存管理在 5 种尺寸 × 3 种底色下完成；D58 生成插画已接入（全部 14 个模块页及相似照片模式的页头、智能扫描与 11 个初始页及其运行页的插画中心、样板页状态插画），应用包增加 818,948 字节（40 个 HEIC，磁盘占用 888 KiB）。
- **最终验证（代码 HEAD `aff331e`）**：定向 38 类 exit 0（683 项，跳过 2，0 失败）；守卫 exit 0（8 项）；全量 exit 0（3712 项，跳过 24，0 失败）；`verify_menu_bar_performance.sh` exit 0（p95 79.0 ms ≤ 100 ms）；主窗口初始页稳定空闲 0.00%（另有一次 0.15 s 的 AppKit 窗口快照写入，改前同样有，见 8.1）。
- **截图与录屏**：102 张改前／改后并排图（改后用最终代码的包重拍，255 条记录逐条核对尺寸和前台状态）；4 段只录本窗口的录屏（13.6–17.8 s）；减弱动态效果录屏 NOT RUN（需改系统设置）。
- **偏离与问题**：规范偏离 14 条（第 3 节）；契约测试改动 16 条（第 4 节）；已知问题 9 条（第 9 节）。
- **未改动**：`ScanStore.swift`、D46 的三个文件、清理／预选／确认／执行语义、菜单栏小窗；没有安装、没有碰 `/Applications`、没有 push、没有读凭证。

## 0. 复核修复轮（10-08，GPT-6 Astra 复核 `90407d8`：无 P0／P1，8 个 P2 及测试、文档问题）

复核全文：`~/Developer/.sc-build/r2-ui-v0/review/review-1.md`。先并入集成分支 `14c1127`（合并提交 `a092891`，无冲突），然后逐条修复：

| 复核项 | 修复 | 提交 | 测试（`DesignSystemV2ReviewTests`） |
|---|---|---|---|
| P2-1 内存页“全选”“选择建议退出项”在已有选择时消失（`5bd4464` 引入） | 恢复改前的可用条件：两项无论选了多少都在，只受 `canRequestMemoryQuitActions` 约束；有选择时再出现“清空选择”和退出。详情区宽 < 960 pt 时三个次要命令只显示图标（标题留在帮助和读屏），退出始终带标题 | `4988da7` | 零选、部分选、全选 × 宽（1084×712）窄（756×468）：探针确认在视口内，再用真实读屏树的命中测试确认是按钮、读出标题、可用 |
| P2-2 减弱动态效果仍有插画缩放和按钮→进度卡变形 | `AppMotion.entranceScale`（入场缩放在减弱动态效果下保持 1，只变透明度）用于轨道插画全部 5 处和状态插画；`SmartScanFlowMatchModifier` 在减弱动态效果下不匹配几何；另把布局变化（分组展开、尺寸档、页头形态、侧栏收起）改用 `AppMotion.layout`（减弱动态效果下直接到位，新出现的行仍淡入）；符号弹跳与替换在减弱动态效果下静止 | `7c9c8bc`、`6625a83` | 规则函数与全部调用处 |
| P2-3 200 行阈值按单个子分类算 | `BulkUpdateScope`：一次更新涉及的行数跨分组相加；风险组复选框与展开、报告级“选择”菜单的 4 个命令、分组复选框、内存页两张列表（最多 256 行）与选择命令都按总行数，超过 200 行不动画并设 `disablesAnimations` | `7c9c8bc`、`4988da7` | “单组 201 行”“多组合计超过 200 行”：真实托管视图里，行自己的隐式动画在批量更新时拿不到动画、小更新照常；调用处 |
| P2-4 插画首次读取和解码在 `body` 里 | `GeneratedArtLibrary`：视图只查缓存；后台任务读取并解码（同一张图的并发请求共用一次），完成后视图从代码绘制的退路淡入成图片；锁只保护缓存状态；主窗口出现时后台预载页头图 | `6625a83` | 视图先退路后图片；缺图保持退路且不重试；一张图读得很慢时缓存和其他图照常应答（带截止时间，锁被占用会失败而不是卡住） |
| P2-5 内存趋势图丢了悬停读数和两条序列的读屏摘要 | `TrendChart` 悬停显示指针下的采样（几秒前、两条序列的值或“无数据”）；读屏读两条序列的当前、平均、最低、最高，最新采样无数据时说“当前无数据”，完全没有数据时说“正在采样…” | `4988da7` | 摘要、无当前数据、无数据、最近采样定位与读数文字 |
| P2-6 SwiftPM 测试只验证缺图退路 | 视图通过环境注入的 `GeneratedArtLibrary`（解析器：应用包或目录）取图；测试注入仓库 `Resources/Art` 的真实文件并断言视图显示了图片；缺图退路另测 | `6625a83` | 见 P2-4 |
| P2-7 1280 宽结果页绿、黄卡副标题被截断 | 三张卡都放得下整行时“数量 · 已选分组”在数值旁边（保持完整宽度）；否则每张卡把它放到全宽第二行；窄窗两列。同一行的卡等高。没有缩小字号 | `76e699f` | 1000／1280／1680 宽 × 中文／英文：每张卡的这行文字要么达到它的完整宽度，要么占两行，并都在卡片内 |
| P2-8 小尺寸初始页插画底部节点和标签被裁 | `OrbitArtworkGeometry`：按节点、标签和星点的完整边界决定画面大小与中心，所有节点和标签都在正方形内；边长 < 320 pt 时不画装饰标签（选项卡上有同样的名字） | `6625a83` | 220–600 pt、3／4 个节点、中英文最长标签：外圈轨道和每个节点及标签都在正方形内 |
| 契约 #11 共享容器过渡期间的互斥 | 切页时离开的页面从第一帧起不响应点击、对读屏隐藏（`AppMotionOutgoingPageModifier`），并淡出 | `7c9c8bc` | 托管的 `PageTransitionContainer`：两页同时在视图树里时（平台标记确认）只有新页能被读屏找到；修饰器本身单独测 |
| 契约 #5 阈值说法 | 第 4 节更正：0.025 → 0.07 是放宽，依据象牙白 C2-4 | 本文件 | — |
| `git diff --check` 返回 2 | 去掉 `SurfaceComponents.swift` 文件尾空行 | `1e3ec15` | `git diff --check integration/2.0.0-beta...HEAD` 返回 0 |

契约测试随之改的两条（依据同上）：`UIConsistencyRegressionTests` #14 改查新的离开页修饰器（淡出 0.15 s、不可点、读屏隐藏；减弱动态效果只淡入）；#12 改查 `BulkUpdateScope(...).perform(AppMotion.layout(...))` 与分组复选框的批量更新。没有删断言、没有放宽阈值、没有跳过测试。

反证（实现先提交，在工作区改坏、跑 `DesignSystemV2ReviewTests`、再 `git checkout -- Sources` 复原）：
- 第 1 轮同时改坏 8 处（内存命令只在零选时出现、一处入场缩放绕过规则与变形不看减弱动态效果、多组行数取最大值且不设 `disablesAnimations`、读取解码放进锁里且视图不加载、摘要把旧值当当前值、副标题回到单行截断、标签任何尺寸都画、离开页不再读屏隐藏）：13 项中 10 项失败（`logs/v0-review-reverse-proof.log`）。
- 第 2 轮（离开页改成半透明可读可点、风险组复选框不再是批量更新）：修饰器测试与调用处测试失败（`logs/v0-review-reverse-proof-2.log`）。容器测试在这两轮都仍通过：SwiftUI 在移除动画开始时就把离开的页面移出读屏树，所以容器层面本来就只有一个可读页面；修饰器把这一点和不可点击明确下来，由修饰器测试守护。
- 写测试时还发现一次自己造成的卡死：慢读测试若两次请求不共用加载会永远等待信号量；已改成带截止时间的检查。

### 0.2 第二轮复核修复（10-08，gpt-6.1-sol 增量复核 `a092891..3fe50e3`：“修后可合并”，6 个 P2，无 P0／P1）

复核全文：`~/Developer/.sc-build/r2-ui-v0/review/review-2.md`。只改这 6 项需要的地方；`OrbitLandingArtwork` 只加了两个 `nonisolated`（V1 会改它的运行态）。

| 复核项 | 修复 | 提交 | 行为测试（`DesignSystemV2ReviewTests`）与反证 |
|---|---|---|---|
| P2-1 超过 200 行时子分类入场动画仍会重新开启（`appStaggeredAppearance` 在 `onAppear` 里另开动画） | 批量护栏同时把范围写进环境（取外层最大的范围）；风险组把跨分组相加的范围包在全部分组外；入场修饰器在超过 200 行的范围里直接显示最终状态 | `6c01e71` | 真实结果页：用绿色风险卡的读屏动作打开 3×80 行的组，开始的入场动画为 0；再往已打开的组里加第 4 组（同样是“新出现的分组”路径），仍为 0 且新组在屏上；3×5 行时正好 3 个（对照）。反证：去掉风险组外的护栏，或让入场修饰器不看范围，都失败 |
| P2-2 后台预载在视图任务开始前完成时可能停在退路 | 视图任务总是 `await` 取图（缓存命中立即返回）并发布到 `loaded`，仍检查取消 | `56f77f9` | 可控时序：退路视图的 body 里放行被闸门挡住的预载并等它写入缓存（正好落在视图 body 之后、任务之前），之后不再有任何变化，图片仍出现。反证：恢复“缓存命中就返回”，失败 |
| P2-3 几何提取后新增 4 处主 actor 隔离诊断 | `nodeOrbitRadius`、`nodeSide(for:)` 是纯常量和纯函数，标 `nonisolated` | `6d82345` | 严格并发全新构建（`-strict-concurrency=complete`，全新 scratch，全部目标）：exit 0，编译器警告 0、隔离诊断 0（`logs/v0-review2-strict-concurrency.log`，唯一一行是 SwiftPM 的 `--skip-update` 弃用提示）。反证：去掉两个 `nonisolated` 重新编译，隔离警告回来（16 行，`logs/v0-review2-reverse-3-isolation.log`）。这一项不是运行时行为，守护手段是构建诊断 |
| P2-4 悬停保存数组下标，新样本到来后读到旧样本 | 保存指针在绘图区内的横向比例，每次渲染按当前样本重新求最近点（新样本、历史淘汰、尺寸变化都跟随）；Debug 可设“静止的指针”供测试 | `7319744` | 指针停在最右端，连续追加 3 个样本，读数每次都是最新样本。反证：改回保存下标，失败 |
| P2-5 英文浮层截断 “Pressure estimate No data” | 浮层按最长一行自适应宽度（每行 `fixedSize`），放在指示线空间较大的一侧 | `7319744` | 中、英文 × 正常值（56%）、100%、无数据：每一行的实际宽度都达到它的完整宽度。反证：恢复 150 pt 定宽单行，英文失败 |
| P2-6 切页测试没验证鼠标路径 | 测试补鼠标路径（代码无需改）：过渡期间对旧页按钮位置做 AppKit 实际路由鼠标事件用的 `hitTest`，确认落不到旧页、而新页按钮能接到；切换前旧页能接到（对照）；离开页修饰器也分别查读屏和鼠标两条路径 | `1abca72` | 运行时证据：**单独去掉 `.allowsHitTesting(!isLeaving)` 两项测试仍通过**——SwiftUI 在移除过渡期间已经不让旧页参与命中，透明度为 0 的视图本身也不接收命中（`logs/v0-review2-reverse-6-leaving-page-hit-testable.log`），所以这一行是冗余保险；同时去掉透明度和 `allowsHitTesting` 时，修饰器测试的鼠标断言失败（`-6b-…log`）。测试宿主里合成的鼠标事件（`sendEvent`、直接调用 `mouseDown`，窗口已显示并视为主窗口）都触发不了 SwiftUI 按钮，所以没有用点击计数，改用 `hitTest` |

验证（最终 HEAD 见文首结论）：反证逐项单独做（`tools/reverse_proof_r2.py`，日志 `logs/v0-review2-reverse-*.log`）。截图：只有深空底色下受影响的页重拍——智能扫描初始页与内存页的 1280×764、1680×1050，结果页 1280×764（`1abca72` 包，5 条记录全部通过尺寸／前台检查），对应 7 张并排图重新生成；悬停浮层是悬停状态，静态截图拍不到，由上面的托管测试量宽度。

### 0.3 第三个小轮（10-08，sol 增量核对 `3fe50e3..633ebdc`：第二轮第 2、3、4、6 项可关闭；第 1、5 项的修复各引入 1 个 P2）

报告：`~/Developer/.sc-build/r2-ui-v0/review/review-3.md`。只改这两处。

| 复核项 | 修复 | 提交 | 行为测试（`DesignSystemV2ReviewTests`）与反证 |
|---|---|---|---|
| P2-1 大范围缩到 200 行以内时，保留身份的分组变透明（首次无动画显示时没记下“已显示”） | 首次出现总是记为已显示：不播动画时也在首次 `onAppear` 里无动画地置 `isVisible = true`；之后范围或位置变化都不会再隐藏。没有用换 ID 重建（会丢展开状态） | `71b04d3` | 真实结果页：打开 3×80 行的组，再把同样三个分组（ID 不变）缩到每组 30 行（共 90 行，等同筛选保留同一批分组），渲染窗口取每个分组区域内最亮像素，缩小前后都要是可见文字的亮度（> 0.6），不是只看探针；另在修饰器层面用平台标记做 `hitTest`，缩小后仍能接到鼠标。反证：恢复旧的 `guard animates, !isVisible`，两项都失败（`logs/v0-review2-reverse-r3-1-entrance-not-remembered.log`） |
| P2-2 浮层按完整文字定宽后没有按实际宽度夹紧，窄图表越界（260 pt 图表里超出约 58 pt） | 新的小布局 `TrendReadoutPlacement`：量出浮层实际宽度，放得下就在指示线右侧，否则左侧，再不行就跨过指示线并夹在图表内；比整个图表还宽时按图表宽度给出，行内换行（不靠裁剪） | `134c204` | 220／260／300 pt 图表 × 指针在左（5%）／中（50%）／右（95%）× 中、英文 × 无数据、100%：浮层左右边界都在图表内，三行都在浮层内。反证：恢复按中线分左右、不夹紧，失败 11 处（`logs/v0-review2-reverse-r3-2-readout-unclamped.log`，例如 220 pt 中间位置右缘 275.5 > 240.5） |
| 可选：探针等待超时的错误归因 | `V0LayoutHost.frames(required:)` 超时时先给出带缺失 ID 的明确失败，再抛错 | `65dbd69` | 第二轮第 2、4 项重新反证，日志现在直接写 `Layout probes did not appear: ["generatedArt.image.module-memory-192"]`、`["trend.readout.820000002"]`（`logs/v0-review2-reverse-2-task-skips-cached.log`、`-4-stored-index.log`） |

测试（`65dbd69`）：守卫 exit 0，8 项（`v0-hygiene-guard-review3.log`）；定向 39 类 exit 0，703 项，跳过 2，0 失败（`v0-targeted-review3.log`）；全量 exit 0，3850 项，跳过 25，0 失败（`v0-full-review3.log`）。严格并发全新构建（`-strict-concurrency=complete`，全新 scratch，用完删除）：exit 0，编译器警告 0、隔离诊断 0（`logs/v0-review3-strict-concurrency.log`）。本轮改动只影响悬停浮层（静态截图拍不到）和“范围缩小后”的分组可见性（夹具截图里分组本来就可见），没有重拍截图。

## 1. 提交

| 提交 | 内容 |
|---|---|
| `e44e16a` | 令牌 v2：三套底色（纯黑、深空、日间象牙白）、模块颜料与渐变、字号、栅格、圆角、三层表面、减弱动态效果／降低透明度／增强对比度；`AppMotion` 令牌与修饰器；D56 默认深空、已存纯黑保留 |
| `a22793f` | `Views/DesignSystem/` 组件：`PageLayout` 等自适应容器、`PageHero`、`IconTile`、`SurfaceCard`、`GradientButtonStyle`、`MetricRing`、`TrendChart`、`CapsuleSegmentedControl`、`AnimatedCheckbox`、`StatusFooter`、`SkeletonBlock`、`OrbitLandingArtwork` |
| `92a4ea8` | 页面外壳：尺寸分档与滞后、侧栏图标栏与选中块滑动、固定标题区、切页过渡、模块光晕、设置里的底色主题 |
| `4f10ea1` | 11 个初始页共用的落地页外壳（页头、配置卡、插画、状态条） |
| `7178a08` | 智能扫描结果页：一句话结论、风险卡、分类便当卡、行内建议词、按行计数 |
| `8ed14e5` | 截图管线：每次会话只激活一次、不跨屏移动窗口；窗口动效演示参数 |
| `0ef7d74` | `DesignSystemV2Tests` 第一批（13 项） |
| `c626470` | 结果页列表在固定页头下渐隐；评审截图从顶部开始 |
| `61d6898` | 扫描中页：进度圆环卡、插画节点按完成点亮、开始按钮变形为进度卡 |
| `5bd4464` | 内存管理页：概览一行、趋势图、列表填满、贴底退出条 |
| `ab09d7d` | Debug：内存夹具参数；截图与演示时窗口不响应指针 |
| `da336b6` | 契约测试发现的问题：矮窗、大窗、动画收尾（详见第 3 节） |
| `dabc980` | D58 生成插画接入（页头、初始页中心、状态插画）＋ `GeneratedArtTests` |
| `f51c89a` | Debug：智能扫描流程演示、录屏用窗口矩形 |
| `617cc54` | 契约测试按 D53／D56 同步（逐条见第 4 节） |
| `bb990bb`、`a159dd9` | 新测试：内存页各尺寸、大尺寸组合门槛、主题覆盖作用域、禁用按钮失色；页头表补 1084×600 |
| `834c59b` | 扫描中扫光改成 Core Animation 图层动画（扫描页 CPU 16–31% → 0.1%）＋测试 |
| `11160fc` | Debug：录屏等待主窗口出现、录制时窗口置顶 |
| `ca8be22` | 并入集成分支 `4fea34d`（见上） |
| `d8d64c8` | D56 偏好测试改用 `TestPreferenceDomain`（D48 守卫） |
| `044269d` | Debug：录屏的窗口矩形文件写出窗口编号（给只录本窗口的 ScreenCaptureKit 录制） |
| `9f98032` | 内存压力环：矮窗 66 pt 圆环放不下“内存压力”时显示“压力”；读屏标签恢复原有的 “Memory Pressure”（`5bd4464` 把它改成了小写，定向集之外的 `PanelChartNormalizationTests` 发现） |
| `62b60c2` | 并入集成分支 `7d654d4`（见上） |
| `9630ed8` | Debug：比屏幕高的截图尺寸在页面稳定时被 AppKit 重新排版成窗口实际大小，拍前检查并重新放置（第 7 节） |
| `aff331e` | 性能测试页页头显示 benchmark 插画：该页页头传的是仪表盘的 `speedometer` 符号，原来对不上侧栏符号而退回图块（最终截图发现）；`GeneratedArtTests` 加映射与页面符号的检查 |
| `53357b2`、`90407d8` | 交接（本文件，第一轮） |
| `a092891` | 复核修复轮前并入集成分支 `14c1127`（无冲突） |
| `7c9c8bc` | 复核 P2-2／P2-3／契约 #11：减弱动态效果下布局直接到位、不变形；批量更新跨分组计行；切页时离开页不可点、读屏隐藏 |
| `4988da7` | 复核 P2-1／P2-5：内存页选择命令任何选择下都在；趋势图悬停读数与两条序列的读屏摘要；两张列表的批量护栏 |
| `76e699f` | 复核 P2-7：结果页风险卡副标题完整显示 |
| `6625a83` | 复核 P2-4／P2-6／P2-8：插画后台读取解码、可注入解析器；轨道插画的节点和标签留在正方形内 |
| `1e3ec15` | `git diff --check`：去掉文件尾空行 |
| `f6d1e40` | `DesignSystemV2ReviewTests`（13 项） |
| `3fe50e3` | 交接（本文件，复核修复轮） |
| `6c01e71` | 第二轮 P2-1：大风险组的分组不再错峰入场；Debug 分组探针、入场计数、批量会话夹具 |
| `56f77f9` | 第二轮 P2-2：插画视图总是发布库返回的图片 |
| `6d82345` | 第二轮 P2-3：轨道几何的两个纯成员 `nonisolated` |
| `7319744` | 第二轮 P2-4／P2-5：悬停读数跟随指针位置；浮层按内容自适应宽度 |
| `1abca72` | 第二轮测试（`DesignSystemV2ReviewTests` 增至 17 项） |
| `633ebdc` | 交接（本文件，第二轮） |
| `71b04d3` | 第三小轮 P2-1：无动画显示的入场也记为已显示 |
| `134c204` | 第三小轮 P2-2：悬停浮层按实际宽度放在图表内 |
| `65dbd69` | 第三小轮测试（`DesignSystemV2ReviewTests` 增至 20 项）；探针超时给出缺失 ID |
| 其后的文档提交 | 交接（本文件，第三小轮） |

## 2. 改了什么、为什么

### 2.1 设计基础（规范 §1）

- **令牌 v2**（`Support/AppDesignTokens.swift`、`ModuleTheme.swift`）：三套表面 `SurfaceSpec`（纯黑：画布 #000000、卡 #16171A；深空：画布 #10162E→#0A0E20、卡 #161D3B@0.88、不透明 #151B37；日间象牙白：画布 #F0ECE2→#ECE7DC、侧栏 #F7F0E6、卡 #FBF7EF）；描边上亮下暗、增强对比度时加粗、降低透明度时卡片不透明；`TypeScale`（页标题 30/28/24/20、指标 38/22/17 等）、`Grid`（4 的倍数）、`Corner`；模块颜料 `ModulePigment`（亮色＋渐变两端，白字对比度 ≥ 4.5:1，危险色见第 3 节）。视图通过 `@AppSurfaces` 读取表面；旧的 `AppAppearanceColors` 只有画布与侧栏四个色随底色主题变化，其余共享令牌保持原值（小窗不受影响，D56）。
- **底色主题**（D56）：`AppCanvasTheme` 纯黑／深空，默认深空；未存过选择的用户得到深空，存过纯黑的保持纯黑；“设置 › 界面 › 底色主题”可选。日间不受影响。
- **动效**（`Support/AppMotion.swift`）：hover、press、standard、emphasized、data、减弱动态效果时的 0.2 s 淡入；`pageChange`（切页与智能扫描变形，0.5 s 缓出，见第 3 节）；依次出现只排前 12 项；超过 200 行的批量更新不加动画；修饰器 `appStaggeredAppearance`、`appHoverLift`、`appDataTransition`、`appBulkAnimationGuard`；`AppMotionTokens` 旧名字映射到新令牌。
- **自适应**（`Views/DesignSystem/PageLayout.swift`）：详情区宽 compact／regular／wide／extraWide（720／1040／1500）、高 short／regular／tall（560／900），≥ 680 才可用完整页头；档位向下 16 pt 滞后；`AdaptivePageViewport` 只在详情区量一次并写入环境；页面可声明 `pageOwnsScrolling()` 自管滚动（拿到恰好可见高度），否则最小页高 468 pt（520−52，删掉了旧的 520 pt 页高）；`AdaptivePane`、`AdaptiveCardGrid`（不出现 2+1、3+1）、列表列优先级 `ListColumnPriority`、`PinnedActionBar`（macOS 26 Liquid Glass，更早系统与降低透明度时用不透明的抬升表面；矮窗 44 pt）。
- **组件**：见第 10 节。

### 2.2 共用骨架（审计 §1.3、§2.1、§2.16、§3）

- **侧栏**（`SidebarView.swift`）：渐变图块 22 pt、模块渐变选中块在行间滑动（`matchedGeometryEffect`）、悬停底色、分组箭头旋转与行依次出现；顶部标题区固定、列表在其下与页脚上渐隐（去掉了多余的 44 pt 留白，修首项被压，审计 2.16）；窗口宽 < 960 自动收成 64 pt 图标栏（悬停显示名称、分组标题换成分隔线），用户手动切换后以用户为准，直到再次跨过阈值；宽度变化有动画，启动时第一次量到的宽度直接到位不加动画。
- **页头**（`PageHero`）：按档位 prominent 72／full 64／regular 52／compact 32，紧凑形态不显示副标题，操作放不下时只留图标（标题做提示）；实时数据页（内存、能耗、性能）只用 regular／compact。D58 后，regular 以上用模块插画，compact 仍用图块。
- **切页**：新页淡入并上移 8 pt，旧页 0.15 s 淡出，模块光晕颜色随之渐变；减弱动态效果时只淡入淡出。
- **初始页外壳**（`FileToolLandingPage.swift`，11 个初始页共用）：页头 → 配置卡与插画（卡在左、插画在右，紧贴页头 8／24／32 pt）→ 状态条；页面自管滚动，只有选项列表在卡内滚动，主按钮在任何高度都可见（最矮 338 pt 平铺窗口）；大窗口（宽或高且 ≥ 680）卡宽 560–600、按钮 56 pt、插画 480–560；常规 380–420；矮窗插画 ≤ 220 并排不占高度；正文最大宽 1440 居中；修了审计 L1–L6（中间尺寸空洞、按钮被挤、插画贴顶等）。

### 2.3 样板页：智能扫描

- **初始页**：三行扫描内容（图块与插画节点同色同名）、“开始扫描”大按钮（左侧图标盘、标题居中）、同心轨道插画（入场动画只播一次，空闲无循环）。
- **扫描中**：进度圆环卡（`MetricRing`）、渐变进度条（data 动画）、阶段标题交叉淡入、已发现大小与计数数字过渡、类别完成时对勾弹跳一次、插画节点按完成三分之一逐个点亮、扫描进行中轨道扫光转动；开始按钮与进度卡用 `matchedGeometryEffect` 变形。
- **结果页**：一句话结论（绿色已勾选、其余几类需人工判断）、三张风险卡（建议清理／需人工判断／谨慎）、宽且高的窗口加分类便当卡、行内一句话原因与建议词、勾选框动画、底部贴底操作条按行计数（“已选择 N 项（M 组）”）；列表在固定页头下渐隐，滚动后出现发丝线；一次都没发现时显示“没有发现可清理的项目”（D58 状态插画）。
- **终止页**：扫描未完成显示出错插画，完成但没有报告时显示完成插画；取消扫描仍用智能扫描插画（没有改动文件）。

### 2.4 样板页：内存管理

- 概览一行：系统压力圆环（颜色即 macOS 压力等级，D28）在前、占用圆环在后、处理建议与已用／缓存／交换、两分钟趋势图（占用面积＋压力估算虚线，新样本从右推入）；指标说明改成信息按钮弹层。矮窗去掉趋势、操作移到右侧；矮且窄时只留压力圆环。
- 进程列表填满剩余高度，只有列表滚动；“可退出应用”列表的选择汇总与操作贴底（`PinnedActionBar`），退出始终是危险样式并先确认（N19、D49，未改确认流程）；列表行有悬停与选中底色，勾选框动画；进程列表首屏的范围切换用胶囊分段控件（读屏仍是原生分段）。
- 空态、没有可退出应用、上次内存操作结果用 D58 状态插画。
- 复核修复（`4988da7`）：“选择建议退出项”“全选”在任何选择下都可用（恢复改前条件）；趋势图悬停显示指针下的采样，读屏读两条序列的当前／平均／最低／最高并区分“当前无数据”。
- 禁用条件、文案、快照行、采样范围说明与原来一致（契约测试原样通过）；默认仍显示“已采样进程”（这是 `ScanStore` 的默认值，本批不改）。

### 2.5 D58 生成插画

- `Resources/Art/`：40 个 HEIC（20 张 × 192／512 px，带透明通道，818,948 字节）与 README；母版不入库。两个打包脚本把它们复制到应用包 `Contents/Resources/Art`，Release 校验逐个比对。
- `GeneratedArt`（`Support/GeneratedArt.swift`）：模块与状态到图片的对应；`GeneratedArtLibrary` 用 ImageIO 按导出尺寸（即显示尺寸）解码一次并缓存，之后刷新不再解码；缺图返回 nil。复核修复（`6625a83`）后：视图在 `body` 里只查缓存，读取和解码在后台任务里做（同一张图共用一次加载），锁只保护缓存；视图通过环境 `generatedArtLibrary` 取库（解析器：应用包或目录），主窗口出现时后台预载页头图。
- `GeneratedArtView`：装饰图（`Image(decorative:)`，对读屏隐藏），图片加载完成前和缺图时画代码绘制的后备（`IconTile`／`GlossyOrb`），加载完成后淡入成图片。日间略提对比，图片自带外光晕在象牙白上不显脏（已在日间截图核对）。
- 接入范围：所有模块页的页头（regular 以上；性能测试页页头用仪表盘符号 `speedometer`，`aff331e` 起同样映射到 benchmark 插画；应用更新“安装中／完成”等状态页头保留状态符号图块，不换插画）；智能扫描与 11 个初始页的插画中心（及它们的运行页），轨道、节点、星点、光晕仍由代码绘制，入场动画保留，空闲不循环；样板页的状态（见 2.3、2.4）。侧栏不改。

### 2.6 Debug 工具（只在 Debug 构建）

- 截图管线：每次会话只激活一次窗口、不跨屏移动、超出屏幕的尺寸按内容视图排版后离屏截取、截图期间窗口不响应指针（避免悬停高亮）。
- `--debug-window-content-size=WxH`、`--debug-window-resize-demo`（1680→820×560 再回到起点，`setFrame(_:display:animate:)`）、`--debug-sidebar-tour=a,b,c`、`--debug-window-frame-file=`（写出窗口矩形给 `screencapture -R`）。
- 内存夹具：`--debug-memory-quittable`、`--debug-memory-select-suggested`、`--debug-memory-demo`，只在 `--debug-mini-window-demo-data` 下生效；夹具模式下退出请求本来就被拒绝。
- `--debug-smartscan-flow-demo`：真实初始页 → 夹具进度的扫描中页 → 惰性结果夹具 → 几次草稿勾选；不启动扫描、不生成清理计划。

## 3. 规范偏离

| # | 规范 | 实际 | 原因 |
|---|---|---|---|
| 1 | §3.2.1 切页“缩放 0.995 → 1，emphasized 弹簧” | 淡入＋上移 8 pt，0.5 s 缓出（`AppMotion.pageChange`），不缩放；智能扫描的按钮变形同用此曲线 | 缩放会让测量到的布局随之缩小（列表栏 360 pt 量成 358.2 pt），项目早先也因此去掉过 0.988 缩放；弹簧的尾巴让变形中的卡片在看似停稳后仍以千分之一点移动一秒多，布局测试等不到稳定 |
| 2 | §2.1／§2.4 矮窗“主操作进贴底操作条” | 初始页的主按钮留在配置卡内，只有选项列表在卡内滚动；结果页和内存页用 `PinnedActionBar` | 初始页的按钮在任何高度都可见（338 pt 有测试），并保留“卡片＋按钮”的整体；JEV 选“卡内”p=0.58 |
| 3 | §2.3 插画高 ≤ 280／≤ 200 | 常规 380–420、大窗 480–560、矮窗 ≤ 220 | 主会话第 1 轮评审要求放大（对齐效果图） |
| 4 | §2.3 完整页头 26 pt | 28 pt（full）、30 pt（prominent） | 主会话第 3 轮评审 |
| 5 | §2.4 正文最大宽 1400 | 初始页 1440、其余 1400 | 初始页卡片＋插画并排，1400 时插画被压（评审 3） |
| 6 | §1.5 禁用按钮 40% 透明 | 填充改成中性底色＋描边、整体 55% | 只降透明度时禁用的危险按钮仍像“淡红的可用按钮”（评审 6）；55% 保证文字可读 |
| 7 | §1.2 危险色 #FF5A5F | 渐变 #DE2F38 → #B71C28 | #FF5A5F 上白字 3.0:1，不到 4.5:1 |
| 8 | §2.3 内容向下滚动时页头收成紧凑页头 | 未做；结果页改为固定页头＋滚动后发丝线＋列表在页头下渐隐 | V0 样板页只有结果页长列表滚动；收起页头会让操作区跳动，留给 V1 再评估 |
| 9 | §2.2 侧栏折叠按钮 | 侧栏标题行内放切换按钮（图标栏／完整），系统工具栏的侧栏按钮仍移除 | 窄窗时图标栏需要就近的展开入口 |
| 10 | D3 补充“设置窗口与主侧栏同一行样式” | 主侧栏改为渐变选中块，设置窗口仍用原行样式 | 设置窗口属 V4（规范 §5） |
| 11 | D58 “用 Bundle.module 加载” | 放在顶层 `Resources/Art`，由打包脚本复制，`Bundle.main` 读取 | 项目没有 SwiftPM 资源包，现有插画都走这条路；`Bundle.module` 找不到资源包时会直接终止应用，违背“缺图不崩溃”；JEV 选此方案 p=1.0（仅参考） |
| 12 | §2.2 录屏“窗口 1680→820” | 起点按窗口所在屏幕的可见区域收小（本机内建屏 1352×878 点，可见区域约 1352×754；录屏窗口 1336×738，见 `motion/02-…frame.json`） | 1680×1050 放不进当前屏幕；按规则不把窗口移到另一块屏 |
| 13 | §2.5 减弱动态效果录屏 | 未录 | 需要打开系统设置里的“减弱动态效果”，属于系统设置，我不能代改；令牌映射有单元测试与反证 |
| 14 | §2.5 外接 1× 显示器 | 未测 | 没有 1× 显示器可用（本机屏幕为 2×） |

## 4. 契约测试改动（逐条，均有 D53／D56／D58 依据）

没有删断言、没有跳过测试；每条都保留原测试守护的不变量，只把实现细节换成 v2 的写法。**唯一的数值阈值变化是 #5**：日间暖色上限 0.025 → 0.07（放宽），依据是规范 1.2 的象牙白底色（C2-4：#F0ECE2／#F7F0E6 的暖色本身约 0.06），原阈值是给中性灰日间定的；之前写的“没有放宽数值阈值”不准确，复核指出后在此更正。提交 `617cc54`（另有 `bb990bb` 只加新测试）；复核修复轮又改了 #12、#14 两条（见第 0 节）。

| # | 测试 | 改动 | 依据 |
|---|---|---|---|
| 1 | `SafeCleanupLayoutTests.testLandingCardUsesItsOptionsHeightWhenTheWindowGetsTaller` | “同一内容高度不随窗口变化”改为在同一组合档内比较（大组合从 900 pt 起按钮 56 pt、卡内边距加大） | §2.3–2.4 大窗口放大按钮与边距；仍断言选项列表不随窗口拉伸 |
| 2 | `…testResizingDetailColumnKeepsScopeReadableAndShortPageScrollable` | 矮于 520 pt 时：页面比视口高才滚动，然后状态条必须在视口内（原来无条件要求能滚） | §2.2 删掉 520 pt 页高，页面自管滚动 |
| 3 | `…testCancelledUpdateScanKeepsRuntimeLayoutAndActionsReachable` | 同上 | 同上 |
| 4 | `…testRuntimeStatesKeepPanelsAndLongPathsStableAcrossWindowSizes` | 页头高度下限从“旧大图标边长＋24”改为“PageHero 工具页档位的图块＋16” | §2.3 实时页用常规／紧凑页头 |
| 5 | `DaylightRefinementTests.testDaylightUsesSubtleWarmNeutralsWithRaisedCardsAndQuieterSidebar` | 暖色上限 0.025 → 0.07（象牙白 #F0ECE2／#F7F0E6）；“侧栏比画布暗”改为“侧栏在画布与卡片之间” | 规范 1.2 日间象牙白（C2-4） |
| 6 | `DaylightRefinementTests.testNightUsesNeutralNearBlackSurfacesWithStableDataColors` | 原有中性近黑断言在纯黑主题下运行（`AppCanvasTheme.withCurrent`），另加深空断言与小窗外壳仍为中性 | D56：默认深空，纯黑保留 |
| 7 | `OwnedUIFlatteningContractTests.testSystemUtilitiesUseNativeLinearProgressAndFlatRows` | `progress: usedRatio`／`progress: nil` → `MetricRing` 的 `fraction: usedRatio`／`fraction: snapshot.reportablePressureLevel == nil ? nil : 1` | 规范 1.5 `MetricRing`；压力环仍只表示等级 |
| 8 | `SystemMonitorServiceTests.testMacOS26UsesFixedScrollSidebarAndCompactPanelControls` | 侧栏底色 `AppAppearanceColors.sidebarTop` → `surfaces.sidebar`；选中色 `actionFill` → 模块颜料渐变块 | 规范 1.2；D3＋§3.2.2 |
| 9 | `SystemUtilitySafetyTests.testSidebarMergesRelatedFunctionsAndKeepsToolboxExpanded` | `SidebarFooter(isRail:)`；`sidebarTopInset` 代替 `sidebarTrafficLightClearance`；`title ?? filter.sidebarTitle`；`IconTile`／`pigment`／`isOnSelection` 代替 `AppSymbolIcon`／`role: .sidebar`／`tint: iconColor`／`sidebarIconColor`；hover 令牌；`ideal: sidebarMode.idealWidth` | §2.2 图标栏与固定标题区、审计 2.16、规范 1.4 |
| 10 | `UIConsistencyRegressionTests.testMainWindowSettingsAndItemBrowserUseNativeMacOSStructure` | 主侧栏改查渐变选中块与 `matchedGeometryEffect`；设置窗口仍查 `SidebarRowBackground` | §3.2.2；设置窗口 V4 |
| 11 | `…testSmartScanFlowUsesOneMutuallyExclusivePageInsteadOfLayeredTransitions` | 只新增断言：流程页用共享 `PageTransitionContainer(key: flowStage)`；原有“无 ZStack、无 .pageTransition(、无叠加层”全部保留 | §3.2.3 |
| 12 | `…testSmartScanResultHierarchyUsesCompactNestedDisclosure` | `ForEach(tierSubcategories)` → 带序号的 `ForEach`（依次出现）；`.glassPanel(` → `SurfaceBackground(level: .card`；`.easeInOut(duration: 0.16)` → `AppMotion.allowsAnimation(rowCount:)`＋standard 令牌 | §3.2.4、规范 1.3、§3.3 |
| 13 | `…testCleanupCandidateUsesNativeCheckboxAndSeparateRowAndFinderActions` | `.toggleStyle(.checkbox)` → `AnimatedCheckboxToggleStyle(`，并查它对读屏暴露原生复选框 | 规范 1.5 |
| 14 | `…testSharedMotionUsesVisiblePageTransitionAndHonorsReduceMotion` | 断言移到 `AppMotion.swift`：淡入＋上移 8、旧页 0.15 s 淡出、减弱动态效果只淡入；仍禁止 0.988 缩放与 `.snappy(`，另禁止切页缩放 | §3.1–3.2.1（偏离见第 3 节 #1） |
| 15 | `…testSharedPageHeaderSymbolsSelectionAndChartsUseOneSemanticSystem` | `: AppTypography.pageTitle)` → `PageHero(`＋`AppTypography.pageTitle`；侧栏 `role: .sidebar`／`sidebarIconColor` → `IconTile(`／`filter.moduleTheme.pigment` | §2.3、规范 1.4 |
| 16 | `…testGeneratedArtworkIsAllowListedForBrandSurfacesOnly` | 侧栏 `sidebarIconColor` → `filter.moduleTheme.pigment`；`AppArtworkAsset` 白名单（6 项）不变 | 规范 1.4；D58 插画走 `GeneratedArt`，见第 5 节 |

另有两条原样通过、但意图被 D53／D58 改变的断言，在此说明：
- `UIConsistencyRegressionTests.testMainModulesUseGoldenSurfaceWithoutChangingNativeSettingsOrRouteTransitions` 断言 `ModulePresentation.swift` 里没有 `RadialGradient(`（“夜间画布不带类别色光晕”）。D53 §1.3／§3.2.1 明确要求模块光晕，光晕在 `SurfaceComponents.swift` 的 `ModuleGlowCanvas` 里，所以字面仍通过；意图已被 D53 推翻，主会话如要保留旧意图请改断言。
- 上表 #16 的“生成插画只给品牌表面”：D58 起模块页头、初始页中心、状态插画也用生成图；范围由新测试 `GeneratedArtTests.testPicturesAreDecorativeAndOnlyOnTheAgreedSurfaces` 锁定（侧栏不用）。

## 5. 新增测试与反证

新增 `DesignSystemV2Tests`（17 项）与 `GeneratedArtTests`（5 项），共 22 项；复核修复轮又加 `DesignSystemV2ReviewTests`（13 项，见第 0 节），`GeneratedArtTests` 改为异步加载接口（仍 5 项），合计 35 项：

- 宽高分档与校准断点；验收窗口的页头形态（含 1084×600 宽而不够高时用常规页头）；16 pt 滞后；无效尺寸；侧栏 960 图标栏、滞后与手动选择；列表列优先级；卡片网格不留孤行；减弱动态效果的令牌映射；D56 默认深空且已存纯黑保留（临时绝对路径偏好域，不写真实偏好）；三套表面的文字对比度与降低透明度时卡片不透明；所有按钮与图块渐变上白字可读；初始页在 6 种详情尺寸（338 pt 平铺到 2204×1298）主按钮、状态条、页头都在视口内；内存页 4 种尺寸页头、概览、贴底退出条都在视口内且中间留出列表；大尺寸组合需要完整页头高度；主题覆盖只在作用域内；禁用的主按钮与危险按钮完全失色（像素检查）；扫描中的扫光图层只在窗口里、未减弱动态效果时转动，离开窗口即停（`834c59b`）。
- 插画：40 个文件按导出尺寸解码且有透明通道、总量 < 1 MB、无 PNG、有 README；每个模块与状态都有图（含相似照片模式与性能测试页的页头符号）；解码一次并复用、缺图返回空；装饰图对读屏隐藏、紧凑页头不用、侧栏不用、轨道循环只在进行中、两个打包脚本都复制；测试宿主里没有图（视图走后备）。

反证（实现先全部提交，在工作区改坏实现、跑新测试、再 `git checkout -- Sources` 复原并移回 1 个 HEIC）：

| 轮次 | 改坏的地方 | 结果 | 日志 |
|---|---|---|---|
| 1 | 滞后 16→0、宽度阈值 720→760、大组合不看页头高度、standard 在减弱动态效果下改为立即、默认主题改纯黑、主题覆盖失效、禁用按钮保留颜色、初始页不自管滚动、内存页矮窗列表最小 220、文件分析无插画、解码不缓存、插画不对读屏隐藏、图标栏阈值 960→1000、P2 列从 wide 起、去掉整行规则、深空三级文字降到 #3A4058、智能扫描渐变变浅、移走 1 个 HEIC | 21 项中 17 项失败（38 处） | `logs/v0-reverse-proof.log` |
| 2 | 无效尺寸不归零、`Image(decorative:)` 改成带标签图片、共享图库改读源码目录 | 3 项失败（另 1 项未失败，见下） | `logs/v0-reverse-proof-2.log` |
| 3 | 页头表原来没有“宽但不到 680 pt”的例子，补 1084×600 后：去掉完整页头的高度条件 | 失败（`full` ≠ `regular`）；复原后通过 | `logs/v0-reverse-proof-3.log`、`logs/v0-header-forms-green.log` |
| 4 | 第 17 项（扫光图层，`834c59b`）：改坏 `OrbitSweepView` 加动画的条件 | 3 处断言失败（无窗口、减弱动态效果、离开窗口时仍有动画）；复原后通过 | `logs/v0-reverse-proof-4.log` |
| 5 | `aff331e` 新断言：去掉 `speedometer` → benchmark 的映射 | `testEveryModuleAndStateHasAPicture` 失败（nil ≠ benchmark）；复原后通过 | `logs/v0-reverse-proof-5.log`、`logs/v0-art-performance.log` |

全部 22 项都有对应的反证失败。

## 6. 命令与结果

环境：`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`，`LC_ALL=en_US.UTF-8`，本机 macOS 27.2；日志都在 `~/Developer/.sc-build/r2-ui-v0/logs/`。

| 命令 | 结果 | 日志 |
|---|---|---|
| **第二轮（`1abca72`）** | 守卫 exit 0（8 项，`v0-hygiene-guard-review2.log`）；定向 39 类 exit 0，700 项，跳过 2，0 失败（`v0-targeted-review2.log`）；全量 exit 0，3847 项，跳过 25，0 失败（`v0-full-review2.log`）；严格并发全新构建 `swift build -Xswiftc -strict-concurrency=complete`（全新 scratch，用完删除）exit 0，编译器警告 0（`v0-review2-strict-concurrency.log`）；截图包构建日志隔离警告 0（`bundle-after-review2.log`） | 见左 |
| **复核修复轮（`f6d1e40`）** | 守卫 exit 0（8 项，`v0-hygiene-guard-review.log`）；定向 39 类（加 `DesignSystemV2ReviewTests`）exit 0，696 项，跳过 2，0 失败（`v0-targeted-review.log`）；全量 exit 0，3843 项，跳过 25（新增的 1 项是并入的 r2-fa-followups 需显式开启的实机测试），0 失败（`v0-full-review.log`）；影响面 12 类 222 项（`v0-review-affected.log`）；`git diff --check integration/2.0.0-beta...HEAD` 返回 0；`verify_menu_bar_performance.sh` 本轮未重跑（本轮没有改菜单栏代码） | 见左 |
| `swift build --scratch-path ~/Developer/.sc-build/r2-ui-v0/debug --jobs 8 --skip-update --disable-automatic-resolution` | exit 0（每次提交前都跑；复核修复轮每个提交前用 `git stash --keep-index` 单独编译过暂存内容） | `v0-art-performance.log`、`v0-build-capture-guard.log`、`v0-build-merge2.log` |
| 定向测试（`tools/run-targeted.sh`）：`swift test --scratch-path … --skip-update --disable-automatic-resolution --filter '^StorageCleanerMacTests\.(<下列 38 类>)/'` | **最终 `aff331e`：exit 0，683 项，跳过 2，0 失败**（`9630ed8`、第三次合并后的 `62b60c2` 同样 683／2／0：`v0-targeted-final2.log`、`v0-targeted-merge2.log`）。跳过的是 `SystemUtilitySafetyTests.testLiveSetappUninstallInventoryWhenExplicitlyEnabled`（需显式开启的实机测试）和随 r2-mini-sensors 并入的 `SystemMonitorServiceTests.testAppleSiliconTemperatureServiceCanProbeLocalChipTemperatureWhenAvailable`（本机不提供可读的 HID 芯片温度传感器） | `v0-targeted-final3.log` |
| 同上，第二次合并后（`d8d64c8`） | exit 0，683 项，跳过 1，0 失败 | `v0-targeted-merged.log` |
| 同上，合并前（`11160fc`） | exit 0，675 项，跳过 1，0 失败 | `v0-targeted-final.log` |
| 同上，起点基线（`ce24ff0`，34 类） | exit 0，653 项，跳过 1，0 失败 | `base-targeted.log` |
| 过程记录 | 改动后第一次 100 处失败（`v0-targeted-1.log`），逐条处理：实现修正见 `da336b6`，契约更新见第 4 节；中间轮 109／4／3 处（`-2`～`-4`），`-5` 起 0 失败 | — |
| 守卫：`--filter '^StorageCleanerMacTests\.(TestPreferenceHygieneTests\|PreferencesFolderContractTests)/'` | 最终 `aff331e`：exit 0，8 项，0 失败；`9630ed8`、`62b60c2` 与第二次合并后同样通过（每次都另在定向集里再跑一次） | `v0-hygiene-guard-final3.log`、`v0-hygiene-guard-final.log`、`v0-hygiene-guard-merge2.log`、`v0-hygiene-guard.log` |
| **全量**：`swift test --scratch-path ~/Developer/.sc-build/r2-ui-v0/debug --jobs 8 --skip-update --disable-automatic-resolution` | **最终 `aff331e`：exit 0，3712 项，跳过 24，0 失败（430.3 s）**；`9630ed8`、`62b60c2`：同样 3712／24／0；第二次合并＋`9f98032` 的工作区：exit 0，3647／23／0。跳过的 24 项都是需要显式开启的实机扫描、在线更新、硬件基准、计时或一次性签名夹具测试（例如 `STORAGE_CLEANER_RUN_LIVE_*`、`MAC_BENCHMARK_V7_*`），以及本机没有可读 HID 芯片温度传感器的 1 项；没有一项来自本批的测试类 | `v0-full-final3.log`、`v0-full-final2.log`、`v0-full-merge2.log`、`v0-full.log` |
| 定向集之外的发现：`--filter` 内存相关 6 类（含 `PanelChartNormalizationTests`） | 第一次 176 项 1 失败：`PanelChartNormalizationTests.testVisibleMemoryPressureKeepsStateAndHeadroomWithoutRedundantExplanation` 要求压力环读屏标签为 “Memory Pressure”，`5bd4464` 改成了小写；`9f98032` 恢复原文后该类 83 项全部通过 | `v0-memory-caption.log`、`v0-panelchart.log` |
| `script/verify_menu_bar_performance.sh`（`STORAGE_CLEANER_VERIFY_ROOT=~/Developer/.sc-build/r2-ui-v0/verify`） | `62b60c2`：exit 0，16 项，见 8.2 | `verify-menu-bar-performance-merge2.log` |
| 反证（第 5 节） | 每轮按预期失败后复原 | `v0-reverse-proof*.log` |
| 截图包：`STORAGE_CLEANER_SKIP_TESTS=1 SWIFT_BUILD_DIR=/tmp/storage-cleaner-r2v0-after DIST_DIR=~/Developer/.sc-build/r2-ui-v0/dist-after ./script/build_and_run.sh --bundle-only` | 最终：exit 0；包内 commit `aff331e`、dirty=false；签名、架构、Sparkle 配置检查通过；`Contents/Resources/Art` 40 个 HEIC；截图拍完后删除 | `bundle-after-perfart.log`（`9630ed8` 见 `bundle-after-guard.log`，打包时把当时未提交的本文件暂时移出工作区以得到 dirty=false；`62b60c2` 见 `bundle-after-merge2.log`；`d8d64c8` 见 `bundle-after-final.log`） |
| 改前包：`6e2cb95`＋截图管线叠加补丁（`before-overlay/6e2cb95-debug-capture-overlay.patch`，只加 Debug 截图入口与真实扫描中页） | exit 0；commit `6e2cb95`、dirty=true（即该补丁） | `bundle-before-2.log` |

定向 38 类：AppResponsiveness、AppSymbolGeometry、Audit20260919Regression、BenchmarkMonitorLayout、CompetitiveParityContract、ComputerHealthDashboard、ConceptLandingNativeLayoutRegression、ControlAccessibilityContract、DayAppearance、DaylightRefinement、DebugScanPresentation、DebugSmartScanSessionFixture、HealthCapabilityLayout、ItemListAndDuplicatePresentation、L10n、MacMiniPortraitRegression、MemoryQuitConfirmation、MemorySelectionSummary、ModuleTheme、OfficialBenchmarkPlan、OverviewPerformanceRegression、OwnedUIFlatteningContract、PrivacyCleanupPresentation、RuntimeWorkflowPresentation、SafeCleanupLayout、SafeCleanupScopeCardLayout、ScanPresentationState、StartupItemsDashboardContract、StorageAnalysisScopeLayout、SystemMonitorService、SystemUtilitySafety、UIConsistencyRegression、UtilityPresentationPerformance、WindowGlassConfiguration（以上 34 类即起点基线所跑），加 DesignSystemV2、GeneratedArt、TestPreferenceHygiene、PreferencesFolderContract（类名均省略 `Tests` 后缀）；复核修复轮再加 DesignSystemV2Review，共 39 类。

任务卡要求的是定向测试类；交付前另外跑了两次全量（见上表），都没有失败。

## 7. 截图与录屏

都在 `~/Developer/.sc-build/r2-ui-v0/shots/`（不入库）。改前 = `6e2cb95`＋截图管线叠加补丁；改后 = 复核修复轮的最终代码 `f6d1e40` 的 Debug 包：12 组改后截图全部用它重拍（修复影响初始页插画、扫描中插画、结果页风险卡、内存页命令条，各组都有涉及）；每张并排图的标签写明所用的包。原版只有一种夜间底色（纯黑），所以“深空”“纯黑”两列都和原版夜间比；日间与原版日间比。截图由应用自己离屏渲染（`cacheDisplay`），只含本应用窗口，截图期间窗口不响应指针。

核对：改后 255 条截图记录（`capture-sizes.json`）逐条检查请求尺寸＝实际内容尺寸、应用在前台、窗口为主窗口，全部通过。过程：第一次重拍（`62b60c2` 包）有 33 张尺寸不对（比屏幕高的尺寸在页面稳定过程中被 AppKit 按窗口实际大小重新排版，拍成 1304×713、1304×710 或 1280×713），已在截图管线里修正（`9630ed8`：拍前检查内容视图，不对就重新放置并再等稳定）并全部重拍；之后发现性能测试页页头没有插画（`aff331e` 修正），含 14 页的 3 组再用 `aff331e` 包重拍。拍摄期间用户切到其他应用时，有几张尺寸正确但应用不在前台（两轮共 17 张），都在应用处于前台时单独补拍替换。复核修复轮用 `f6d1e40` 包把 12 组全部重拍，255 条记录一次全部通过（`logs/capture-final-after-review.log`）。

### 7.1 并排图（`pairs/`，共 102 张，`pairs/index.json` 列出全部）

- 样板页 5 档 × 3 底色：`sample-<页>-<尺寸>-<底色>.png`，页为 `smartscan-initial`（初始页）、`smartscan-scanning`（扫描中，夹具进度 60%）、`smartscan-results`（结果页，含 D47 示例行、绿色层展开）、`memory`（内存管理）；尺寸 `820x560`、`1000x700`、`1280x763`（即 1280×764）、`1680x1050`、`2400x1350`；底色 `deep`（深空，默认）、`black`（纯黑）、`day`（日间象牙白）。60 张。
- 全部 14 页 1280×764 × 3 底色：`all14-<页>-1280x764-<底色>.png`。42 张。
- 原始截图：`final-before-{night,day}-{pages,scanning,results}/`、`final-after-{deep,black,day}-{pages,scanning,results,memquit}/`。
- 只有改后的补充：`final-after-*-memquit/`（内存“可退出应用”列表，夹具已勾选建议项，5 档尺寸；原版没有对应的夹具参数）。
- 820×560 的内存页改前图里侧栏“浏览器隐私”有一处悬停高亮（截图时用户的指针停在那里，页面出现在指针下面时 SwiftUI 按指针位置给了悬停样式，窗口不响应指针挡不住这一种）；是悬停，不是选中。复核修复轮重拍的改后图里没有。
- 按钮状态证据：`evidence/button-states-{night,day}.png`。

### 7.2 录屏（`motion/`，MP4，各 ≤ 20 s，深空）

| 文件 | 内容 | 时长 |
|---|---|---|
| `01-sidebar-page-switch.mp4` | 侧栏依次切换 9 页：选中块滑动、切页淡入上移、模块光晕变色、各页插画入场 | 17.8 s |
| `02-window-resize-1680-to-820.mp4` | 窗口从最大逐级缩到 820×560 再放回：侧栏 960 以下收成图标栏、页头档位、卡片与插画重排 | 14.3 s |
| `03-smartscan-start-results-select.mp4` | 初始页 → 扫描中（进度、节点点亮、数字过渡）→ 结果页 → 几次勾选（勾选框动画、贴底条计数） | 17.8 s |
| `04-memory-refresh-select.mp4` | 内存页入场（圆环从 0 画起）→ 刷新 → 切到可退出应用 → 勾选建议项（危险色勾选框与行底色、贴底操作条计数；夹具模式下退出按钮是禁用外观，见第 9 节 #3）→ 清空 → 切回 | 13.6 s |

- 每段都有 `*-keyframes.png`（8 帧）、`*.app.log`、`*.frame.json`。
- 方法：用 ScreenCaptureKit 只录本应用这一个窗口（`tools/sckrec`，desktop-independent window），其他窗口、桌面、调度中心与其他空间都不会进画面；录完立即退出 Debug 包。窗口缩小时画面外圈为黑边（窗口本身变小）。
- 第一次尝试用 `screencapture -R` 录屏幕区域，激活窗口时触发了空间切换，画面里出现了调度中心和其他应用的窗口；这 4 段已立即删除，没有留存或外传，改用上面的窗口录制重录。
- 录屏包是 `044269d`，最终代码是 `aff331e`。录屏涉及的界面差别：`9f98032`（矮窗内存压力环的文字；录屏 04 的窗口是 1280×738，圆环是常规尺寸，不受影响）和 `aff331e`（性能测试页页头插画；录屏 01 切到性能测试页时页头仍是图块）；其余是并入的集成提交（菜单栏小窗与传感器，录屏不涉及）和 Debug 截图管线。录屏里的内存夹具数字与最终截图一致。
- 02 的起点：1680×1050 放不进本机内建屏（1352×878 点，可见区域约 1352×754），按规则不跨屏移动，起点收成该屏可见区域内的窗口（1336×738，含标题栏），见第 3 节 #12。
- 减弱动态效果切页：未录，见第 11 节。

## 8. 性能

### 8.1 主窗口空闲 CPU（规范 §3.3：初始页入场动画结束后采样 10 秒，目标 ≤ 1%）

方法（`tools/measure-idle-cpu.sh`）：启动 scratch Debug 包副本（隔离身份、演示数据、深空、1280×764，窗口由 Debug 参数放置并激活，截图期间不响应指针），等 12 秒让入场动画与启动工作结束，然后连续取 3 个 10 秒窗口，用 `ps -o time` 的 CPU 时间差除以墙钟时间；另用 `top` 采样核对。Debug 构建（未优化），数值偏保守。

| 构建 | 页面 | 第 1 个 10 s | 第 2 个 | 第 3 个 | 日志 |
|---|---|---|---|---|---|
| **复核修复轮 `f6d1e40`** | 智能扫描初始页 | **0.00%** | 1.50%（同一次性 AppKit 快照） | **0.00%** | `logs/idle-cpu-review-landing.log`；插画改为后台加载、启动时预载页头图后不变 |
| **`9630ed8`** | 智能扫描初始页 | **0.00%** | 1.50%（一次性 0.15 s，见下） | **0.00%** | `logs/idle-cpu-final2-landing.log`、剖析 `logs/sample-launch-after-final2.txt` |
| `62b60c2`（界面代码与最终相同） | 智能扫描初始页 | 8.78% | 1.40% | 0.00% | `logs/idle-cpu-merge2-landing.log`；测量时本批的并排图脚本正在运行（1 分钟负载约 9），推测启动工作被拉长；没有单独剖析，所以在最终包上重测并剖析 |
| 改后 `11160fc` | 智能扫描初始页 | 2.09%／1.70%（两次） | 0.00% | 0.00% | `logs/idle-cpu-final-landing.log`、`-final-landing-2.log` |
| 改后 `11160fc` | 内存管理（可退出应用列表） | 0.00% | 0.00% | 0.00% | `logs/idle-cpu-final-memory.log` |
| 改后 `11160fc` | 扫描中（扫光在转） | 1.40% | 0.00% | 0.10% | `logs/idle-cpu-final-scanning.log` |
| 改前 `6e2cb95` | 智能扫描初始页 | 0.00% | 2.39% | 0.00% | `logs/idle-cpu-final-before-landing.log` |
| 改前 `6e2cb95` | 扫描中（夹具 60%，旧页无循环动画） | 1.99% | 1.20% | 0.00% | `logs/idle-cpu-before-scanning.log` |

- 稳定空闲 0.00%，达标。启动后十几到三十秒内有一次约 0.15–0.2 s 的 CPU：`sample`（`11160fc`：`logs/sample-launch-after.txt`；最终 `9630ed8`：`logs/sample-launch-after-final2.txt`，启动后 11–37 s 每毫秒采样）都显示是 AppKit 状态恢复写窗口快照（`NSPersistentUIFileManager writeWindowSnapshot` → zlib `deflate`，约 103 个样本），由窗口改变尺寸触发，改前的包同样出现（2.39%），不是界面动画，也不循环；并入的小窗传感器代码在这段时间没有出现在调用栈里。严格按“任意 10 s 窗口 ≤ 1%”算，这一次性开销所在的那个窗口超标（1.4–2.4%），改前改后相同。
- **扫描中的动画开销**（规范要求单独记录）：第一版用 SwiftUI `repeatForever` 转扫光，扫描页 Debug 构建 16–31% CPU（`logs/idle-cpu-after-scanning.log`、`-wip-scanning.log`），改成 Core Animation 图层动画后 0.1%（提交 `834c59b`，见上表）。
- 空闲不跑循环：初始页插画只播一次入场；骨架屏只在可见时扫光；扫光只在扫描或测量进行中存在；窗口不可见时图层动画由系统停止合成。

### 8.2 `script/verify_menu_bar_performance.sh`

命令：`STORAGE_CLEANER_VERIFY_ROOT=~/Developer/.sc-build/r2-ui-v0/verify SWIFT_BUILD_JOBS=8 ./script/verify_menu_bar_performance.sh`（Release 构建，离线依赖从 `r2-u1-preselect/debug` 复制；用完删除 `verify/`）。预算写在 `MenuBarPerformancePolicy`，没有改。

| 构建 | 结果 | 长历史准备 p95 | 缓存投递 p95 | 日志 |
|---|---|---|---|---|
| **`62b60c2`（之后的 `9630ed8`、`aff331e` 不涉及菜单栏代码）** | **exit 0，16 项，0 失败** | 79.0 ms（预算 100 ms） | 0.0017 ms | `verify-menu-bar-performance-merge2.log` |
| `044269d` 时的工作区（21:09） | exit 0，16 项，0 失败 | 89.3 ms | 0.0019 ms | `verify-menu-bar-performance-2.log` |
| 更早的工作区（19:07，`834c59b` 之前） | exit 1：`testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 105.2 ms > 100 ms；之后两次都通过（上两行），推测是当时同时运行的其他构建造成的负载（本批的提交没有改菜单栏代码，预算没有改） | 105.2 ms | — | `verify-menu-bar-performance.log` |


## 9. 已知问题

1. **旧颜色的主题切换有延迟**：v2 表面（`@AppSurfaces`）随“底色主题”立即切换；未迁移页面里仍用 `AppAppearanceColors` 的部分读的是缓存的全局主题，切换后要等下一次重绘。V1–V5 迁移后消失。
2. **未迁移页面在深空底上新旧混排**：例如系统健康配置卡里的旧图标、各列表行、设置窗口。V0 只承诺共用骨架与两页样板；其余页面由 V1–V5 逐页完成。
3. **夹具下的内存页**：演示数据模式里所有退出请求本来就被拒绝，所以截图与录屏里的勾选框、“退出 N 个应用”是禁用外观；真实数据下为红色可用（按钮状态另有像素测试）。
4. **与集成分支的合并**：已四次并入（见文首），最后一次是 `14c1127`，无冲突；集成分支现在的 `100062a` 试合并也无冲突。以后再合并时，`Debug/MainWindowSnapshotPipeline.swift` 最容易冲突（D46 等批次也在文件末尾加截图入口），两边都保留即可。
5. **共用截图身份**：其他批次也用 `com.local.StorageCleanerMac.integration` 截图，同一时间只能有一个实例；本批截图脚本改为等 10 秒无实例再启动，失败自动重试（最多 3 次）。
6. **布局测试与动画**：切页与变形改成有限时长后，定向测试稳定通过；仍有 standard 弹簧用于档位切换和展开，以后的布局测试如在动画中途取样，需要等待稳定（现有测试的等待足够）。
7. **应用启动会把 `AppleLanguages` 写进自身偏好域**：这是已有行为（不是本批引入），隔离身份的偏好域会因此留下语言项。
8. **缩窗时的滞后带**：窗口缩小时，详情区在阈值下 16 pt 以内仍保持原档位（例如大组合），跨过滞后带才切换，录屏 02 开头可见；这是为避免在阈值附近来回跳动的设计，不是卡住。
9. **截图里的悬停高亮**：截图期间窗口不响应指针，但页面出现在用户静止的指针下面时，SwiftUI 仍会按指针位置给悬停样式（目前只在 820×560 内存页的改前图里有一处，见第 7 节）。要完全去掉，需要让悬停修饰器在截图会话里关闭，留给后续截图工具改进。

## 10. 组件用法（给 V1–V5）

所有组件都在 `Sources/StorageCleanerMac/Views/DesignSystem/` 与 `Support/AppMotion.swift`、`Support/GeneratedArt.swift`。原则：页面不再自写 `GeometryReader` 断点，读 `@Environment(\.pageLayout)`；颜色读 `@AppSurfaces`；动画只用 `AppMotion` 令牌并绑定 value。

| 组件 | 用法 | 注意 |
|---|---|---|
| `PageLayout`（环境 `\.pageLayout`） | `layout.width`（compact…extraWide）、`layout.height`、`allowsFullHeaderHeight`、`usesLargeComposition`、`pagePadding`、`cardPadding`、`cardSpacing`、`heroForm(for: .landing／.tool)` | 由 `AdaptivePageViewport` 写入；单独托管（测试、预览）时用 `PageLayout.resolve(size:)` 或 `.approximated(from:)` |
| `AdaptivePageViewport` ＋ `.pageOwnsScrolling()` | 页面要自己管滚动（列表填满、贴底操作条）就在根视图加 `.pageOwnsScrolling()`，会拿到恰好可见的高度；否则最小页高 468 pt 并整页滚动 | 自管滚动的页面必须让主操作在 338 pt 高时仍可见 |
| `AppPageHeader(…, role:)` → `PageHero` | 初始页 `role: .landing`，实时数据页 `.tool`；操作放在尾随闭包；没有操作就传 `{ EmptyView() }`（不要传 `if let` 包装，否则会留空行） | 页头图标自动按 `systemImage` 找 D58 插画，缺图退回 `IconTile` |
| `AdaptivePane` | 两栏 58／42，compact 上下排 | |
| `AdaptiveCardGrid(minimumColumnWidth:maximumColumns:spacing:)` | 卡片网格，自动 1–4 列，不出现 2+1、3+1 | |
| `.listColumn(.p2／.p3)` | 列表次要列：P2 从 regular、P3 从 wide 显示 | 路径用中间省略加悬停 |
| `PinnedActionBar { summary } actions: { … }` | 贴底操作条；放在页面最后一行或 `safeAreaInset` | 矮窗自动 44 pt；compact 时按钮可用 `.labelStyle(.iconOnly)` |
| `IconTile(systemImage:side:pigment:shape:glows:)` | 模块图块（渐变、高光、描边），侧栏和小图标用 | 选中块上用 `isOnSelection:` |
| `SurfaceCard`／`.surfaceBackground(level:)`／`SurfaceBackground` | 卡片表面（card／elevated／inset），日间带阴影、增强对比度加描边 | 不要再用 `.glassPanel` 做新卡片 |
| `GradientButtonStyle(kind:size:pigment:fillsWidth:)` | primary（模块渐变）、destructive（危险红，退出／移到废纸篓／清理必须用它）、secondary、ghost；尺寸 32／40／52／56 | 禁用的 primary／destructive 自动失色；`PrimaryActionLabel` 用于初始页大按钮 |
| `MetricRing(fraction:colors:lineWidth:) { center }` | 圆环；`nil` 表示未知（只画轨道，不当 0） | 首次出现从 0 画起，之后从旧值过渡 |
| `TrendChart(samples:secondarySamples:range:duration:color:…)` | 平滑曲线＋面积，可加虚线第二序列；新样本从右推入 | 没有计时器，样本变化才动 |
| `CapsuleSegmentedControl(selection:options:title:label:)` | 胶囊分段控件，选中块滑动；读屏是原生分段 | |
| `AnimatedCheckboxToggleStyle(tint:)`／`AnimatedCheckmarkBox` | 勾选框动画；读屏是原生复选框 | 三态用 `AnimatedCheckmarkBox(mark:)` |
| `StatusFooter(status:trustText:isCompact:)` | 页面底部状态条（状态＋只读说明） | |
| `SkeletonBlock` | 加载占位，1.2 s 微光，只在可见且未减弱动态效果时动 | |
| `OrbitLandingArtwork.smartScan(…)`／`.module(systemImage:nodes:isActive:)` | 初始页／运行页插画：D58 中心图＋代码轨道、节点、星点；`isActive` 时才转扫光 | 节点最多 4 个 |
| `GeneratedArtView(art:variant:) { fallback }`、`StateArtPanel(art:fallbackSystemImage:title:detail:arrangement:)`、`StateLandingArtwork` | D58 图片与状态插画；`.banner` 用在有其他内容的页面，`.stacked` 用在空页面；初始页式页面可用环境 `\.landingStateArt` 换成状态图 | 装饰图，对读屏隐藏；必须给后备 |
| 动效修饰器 | `.appStaggeredAppearance(index:)`（只排前 12）、`.appHoverLift`（可点卡片上浮 2 pt）、`.listRowHover(isSelected:tint:)`（列表行只变底色）、`.appDataTransition(value:)`（数字过渡）、`.appBulkAnimationGuard(rowCount:)`（> 200 行不动画）、`AppMotion.rowTransition`、`AppMotion.pageTransition` | 不要用 `.spring(`／`.snappy(` 字面值、材质、`.buttonStyle(.plain)`（有契约测试） |
| 滚动辅助 | `.scrollTopFade(height:)`、`.reportsScrollOffset($isScrolled)`＋`FixedHeaderDivider(isVisible:)` | 固定页头下的列表 |
| `PageTransitionContainer(key:) { … }` | 互斥的几页之间切换（切页过渡、减弱动态效果时淡入） | key 可以是任意 Hashable |
| `ModuleGlowCanvas`、`AppCanvasTheme`、`@AppSurfaces` | 模块光晕背景；底色主题；表面颜色 | 测试与预览用 `AppCanvasTheme.withCurrent(_:_:)`，不要写偏好 |

## 11. 未做与受阻

- **减弱动态效果下的关键帧（复核修复轮要求“如果系统允许”）：NOT RUN**。本机未开启“减弱动态效果”（只读查询 `defaults read com.apple.universalaccess reduceMotion` 没有这个键，即默认关闭），开启要改系统设置，我不能代改。复核指出的两处（插画缩放、按钮变形）和布局变化的规则与全部调用处由 `DesignSystemV2ReviewTests.testReduceMotionKeepsGeometryAtRest` 覆盖并反证。
- **减弱动态效果录屏：NOT RUN**，也没有关键帧条可替代。需要在“系统设置 › 辅助功能 › 显示”打开“减弱动态效果”；这是系统设置，我不能代改。应用内也无法模拟：SwiftUI 的 `accessibilityReduceMotion` 环境值是只读的（SDK 27 的 SwiftUICore 接口只有 `get`），要模拟就得把所有读取处改成自定义环境键，超出本批。代码路径由 `DesignSystemV2Tests.testReduceMotionMapsMovementToFadesAndDataToImmediateUpdates` 与反证覆盖；用户打开该设置后可用 `tools/record-motion.sh` 同样的参数录一段侧栏切页。
- **外接 1× 显示器：NOT RUN**（没有 1× 显示器可用，本机屏幕为 2×）。
- **页头随滚动收起**（规范 §2.3 最后一行）：未做，见第 3 节 #8。
- **真实数据下的内存退出流程**：没有在真实应用上点退出（规则不允许）；确认流程未改，契约测试原样通过。

## 12. JEV

只提交非敏感的方案与证据摘要；结论只作参考，不代替测试或批准。

| 决策 | 选择 | 概率／置信 |
|---|---|---|
| 批次策略（主会话）：先基础与样板 | foundation_pilot | 0.99 |
| 初始页矮窗的主按钮放卡内还是贴底条 | in_card（卡内，选项列表滚动） | p=0.58，置信 0.5（低，按评审结果采用并在第 3 节列为偏离） |
| D58 资源加载：Bundle.module 还是沿用 Resources/＋打包脚本＋Bundle.main | bundle_main_script_copy | p=1.0；三项要求逐项 supported（不崩溃、兼容现有打包、与现有插画一致） |
| 交付前集成分支已前进到 `7d654d4`：再并入一次，还是沿用 `4fea34d` 的合并 | merge_again | p=0.97，置信 0.96；“最终验证在最新集成上”只有再并入满足 |

## 主会话合并记录（2026-10-08 凌晨）

- 复核链：GPT-6 Astra review-1（`90407d8`，8 项 P2）→ 修复轮 → gpt-6.1-sol review-2（`a092891..3fe50e3`，6 项 P2，修后可合并）→ 第二轮修复 → sol review-3（`3fe50e3..633ebdc`，修复引入 2 项 P2）→ 第三小轮 → sol review-4（`633ebdc..d7d0c7b`，**可合并**，无新增 P0／P1／P2）。报告在 `~/Developer/.sc-build/r2-ui-v0/review/`。
- 实现方最终数字（`65dbd69`）：守卫 8 项、定向 39 类 703 项（跳过 2）、全量 3850 项（跳过 25）均 0 失败；全新 scratch 严格并发构建 0 警告 0 隔离诊断；各项修复逐项反证。
- 非阻断覆盖边界（review-4）：浮层“文字比整个图表还宽”的换行分支未被现有 36 种组合实际触发；当前内存页趋势栏最窄 220 pt，不触发该分支。以后若复用到更窄图表，补约 120 pt 的用例。
- V1（D62）由 gpt-6.1-sol 在 `task/r2-ui-v1`（自 `3fe50e3`）并行实现，合并 V0 后由主会话把本分支并入 V1 再验证。
