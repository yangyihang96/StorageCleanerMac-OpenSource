# d116-batch-e：竞品逆向 E 批（把剩下的学习点写进程序）

批次：E / D116、D117。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`。本批改动未提交，与 D98–D115 的未提交改动在同一工作区。

**来由**：用户 2026-10-18 在本会话要求：“你先不提交，继续给我开发。把之前逆向工程得到的这些文件都学习写进我们的程序里。程序做好以后，把测试版给我安装好，让我自己亲自运行看一遍。我批准后，你就可以上传。”之后又追加：“你随时可以逆向工程找你需要的”“尤其是 istat 的小窗模式的设计与底层逻辑”，最后“你去修改吧”。产品决定见 DECISIONS D116（逆向学习点）和 D117（iStat 小窗），本文记实现、测试、证据、逆向学习点的覆盖情况和未完成的部分。

**逆向材料**：
- 《2.0.1 改进计划》`~/Claude 好玩的/Mac清理与监控软件逆向-2026-10-15/2.0.1改进计划.md`（SHA-256 `169ed23e…`）。
- 同目录的 `汇总.md`、`StorageCleanerMac差距清单.md`、`分报告/{cleanmymac,lemon,monitors,small-cleaners}.md`。
- 仓库内 `docs/COMPETITIVE_REVERSE_ENGINEERING_2026-10-14.md`（本批没有改它）。
- 证据目录 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15`。

**本批没有做的事**：提交、合并、推送、发布、重启；真实清理、清空废纸篓；写风扇、电源模式或 SMC。开发和测试期间没有启动 App；装好以后按用户要求打开过一次，见“安装”一节。新增测试只用测试自己建的临时目录（`TestFileSystem.uniqueRoot`）和仓库里的源码、脚本，不读真实的 `~/Library`。

**测试版安装**：本批结束时按用户要求用 `./script/build_and_run.sh --beta --install --no-launch` 安装测试版，不启动。结果见“安装”一节。

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/batch-e/`。

## 完成项

| 项 | 改动 | 测试 |
|---|---|---|
| G11 iOS 设备备份只读盘点 | 文件分析页新增“设备备份”按钮。弹出的页面列出 `~/Library/Application Support/MobileSync/Backup` 下每个备份的设备名、系统版本、备份时间、是否加密、上次备份是否完成和本地占用；只提供“在访达中显示”，不提供删除 | 新增 `MobileDeviceBackupInventoryTests` 6 项 |
| G10 修订 | “释放过少不预选”改为按“可能释放”判断：成员全部在本行内的完整克隆组也算会释放。Bun 缓存内部互为克隆的副本现在默认勾选，克隆进项目的仍不勾选 | `CleanupDefaultSelectionPolicyTests` 改 1 项（新增 6 个行用例）；`BunInstallCacheRuleTests` 新增 1 项（真实 APFS 克隆夹具） |
| Little Snitch 网络用途说明 | 新增 `Resources/InternetAccessPolicy.plist`，以及英文、简体中文 `InternetAccessPolicy.strings`；两套打包脚本复制并逐字节核对 | 新增 `InternetAccessPolicyTests` 5 项 |
| G12 后续：包含检查缓存 | 扫描器每次遍历只算一次根目录的两种形式（`PathSafety.ContainmentRoot`），每个条目的字面形式也只算一次 | 新增 `PathSafetyContainmentRootTests` 3 项；扫描器安全相关的 9 个套件 117 项回归 |
| Stats 历史库（原 E2） | 不加规则（理由见下文） | — |
| G3 | 仍待实测（需要用户运行装有 helper 的测试版） | — |
| D117 镜像吞吐图（iStat） | 网络上传/下载、磁盘读写合并图的两半各自定量程（下限 1 KiB/s），柱高按 0.75 次幂压缩，两个方向各自衰减；三级历史底部写“上下各自缩放” | 新增 `MirroredThroughputScaleTests` 6 项；改 `PanelChartNormalizationTests`、`GeekHistoryAveragingTests`、`GeekHoverDetailTargetTests`；`MiniWindowConsistencyRuleTests` 新增 1 项 |
| D117 悬停斜移保护（iStat） | 320 ms 宽限后仍朝已开子面板前进就继续等，最长 1 s；回头立即切换；每一级都保护 | `HoverIntentControllerTests` 新增 5 项（含按 JEV 提示补的“等待中离开卡片不切换”）；`GeekHoverDetailTargetTests` 补两个参数 |
| D117 iStat 历史库规则理由 | 补“7.30 不会清理其中交换空间的历史” | `IStatMenusHistoryRuleTests` 补 1 处断言 |

## G11：iOS 设备备份只读盘点

**扫描器**：`Sources/StorageCleanerMac/Services/MobileDeviceBackupInventory.swift`（新文件）。
- **根目录状态**：沿用本地 AI 模型盘点的检查，把 `LocalModelInventoryScanner.rootState` 从 private 改为模块内可见，只改可见性。
  - 备份文件夹不存在：显示“这台 Mac 的默认位置没有 iPhone 或 iPad 备份”。
  - 备份文件夹本身是符号链接（例如指向外置盘）：不跟随，显示目的地。
  - 家目录以下某一层上级是符号链接：不跟随，显示是哪一层。
  - 读不了：提示授予完全磁盘访问，并给出打开设置的按钮。
- **列出备份**：每个备份文件夹按名称排序处理，跳过隐藏项和根目录里的普通文件。备份文件夹本身是链接时跳过并计数。
- **元数据**：
  - 先读 `Status.plist`：备份时间；`SnapshotState` 不是 `finished` 表示上次备份没有完成。
  - 再读 `Manifest.plist`：`IsEncrypted`；时间的后备；`Lockdown` 里的 `DeviceName`、`ProductVersion`。
  - 前两个缺信息时才读 `Info.plist`：`Device Name`、`Display Name`、`Product Version`、`Last Backup Date`。
  - 读取方式：用 `LocalModelInventoryScanner.readRegularFile` 读（`O_NOFOLLOW|O_NONBLOCK`，只读普通文件，有大小上限：前两个 8 MiB，`Info.plist` 可能带应用图标，放宽到 32 MiB）。链接、超限文件不解析。
  - 只保留界面显示的几项。序列号、电话号码、IMEI、设备标识等读到也不保留，测试断言盘点结果的文字里没有这些值。
  - 设备名去掉控制字符和首尾空白，最多 80 个字符。系统版本只接受 1–4 段 ASCII 数字、最多 16 字节。
- **大小**：
  - 按已分配块计（`st_blocks × 512`，与空间分析口径一致），只统计普通文件，不跟随符号链接（计数）。
  - 层级超过 16 层的只跳过那一棵子树，并标为大小不完整。
  - 硬链接文件在一个备份内只算一次；跨备份共用的部分写在行内（“其中 X 与其他备份共用（硬链接），合计只算一次”），合计里只算一次。
  - 条目上限 200 万，可以取消；中途停止时注明结果不完整。
- **排序**：先按大小，一样大时较新的在前，再按文件夹名。

**界面**：`Sources/StorageCleanerMac/Views/FilesLightfield/MobileDeviceBackupInventoryView.swift`（新文件）。
- 入口在文件分析页的“本地 AI 模型”旁边，悬停说明“只读查看 iPhone、iPad 备份的占用（需要完全磁盘访问权限）”。
- 页面打开时在后台读一次，关闭时取消。
- 页首说明：“只读盘点：备份可能是设备数据唯一的副本，本页不提供删除。要删除旧备份，请把 iPhone 或 iPad 连接到这台 Mac，在访达里选中设备，点‘管理备份…’。”
- 每行显示设备名（读不到时写“没有读到设备名的备份”）、详情和大小。详情包括备份时间、系统版本、已加密/未加密、上次备份没有完成、大小不完整。
- 行的右键菜单只有“在访达中显示”。界面不显示文件夹名（设备标识），所以行上没有带路径的悬停说明。
- 底部按钮：“返回”；可读时“在访达中显示备份文件夹”；读不了时“打开完全磁盘访问权限设置”。

**与原有决定的关系**：文件分析的“移到废纸篓”流程里，iPhone 备份仍可以勾选（`FileAnalysisTrashProtectedScopeTests` 的原有决定不变）。新页面本身不提供删除。

**测试**（`MobileDeviceBackupInventoryTests`，全部用假家目录）：
- 两个备份的设备名、版本、时间优先级、加密、未完成、大小、文件数与排序；
- 不保留其他字段；
- 不存在、备份文件夹是链接、上级是链接、`chmod 000` 读不了；
- 跨备份和备份内的硬链接、备份内链接、链接的备份文件夹、链接的 `Status.plist`、超限的 `Info.plist`、过深的文件夹；
- 条目上限与取消；
- 名称与版本的清洗；
- 源码里没有删除、移动、写入、启动进程的调用，入口在文件分析页。

## G10 修订：完整的内部克隆组也算会释放

D101 的 G10 规定：绿色行若 G1 在行内提示共享，且保守预计释放不到 1 MiB 或不到列出大小的十分之一，就不默认勾选。保守预计数把所有克隆共享都当作不释放，所以 Bun 缓存这种内部互为克隆的目录也被挡下，而清理整行会删掉组里的每个成员，那部分其实会释放。

- **新判断**（`ScanCandidate.freesTooLittleToPreselect`）：
  - 可能释放 = 保守预计数 + 成员全部在本行内的完整克隆组字节数（`wholeCloneGroupBytes`，每组一份）。后者以克隆共享量为上限，所以本地快照占用不会算成释放。
  - 起初还以“大小 − 保守数”为上限。反证 G10b 去掉它后测试仍全部通过：这个上限起作用时，可能释放等于整行大小，而保守部分明显时整行大小一定也明显，结果总是勾选；不加上限只会更大，结果相同。它不改变任何判断，所以删掉了，`inside-capped-at-size` 用例仍断言这种行会勾选。
  - 保守部分明显（≥1 MiB 且 ≥ 大小的十分之一），而且可能释放不明显时，才不勾选。
  - 有成员在本行以外的克隆组（例如 uv、pnpm、Bun 缓存克隆进项目的部分）和本地快照占用仍算保留；跨行、要看最终选择才能算的条件数不计入。
- **行内文字不变**：被留下的行，保守数和这个合计都在门槛以下。
- **JEV**：`jev_decide` 选 `plus_whole_internal_groups`，0.92，只作辅助。
- **测试**：
  - 选择策略：新增行内整组、整组不到十分之一、快照与整组并存、整组数被快照夸大、整组超过行大小等用例；`bunWhole` 从“不预选”改为“预选”。这是本项要改变的行为，不是放宽断言。
  - `BunInstallCacheRuleTests` 新增真实克隆在缓存内部的用例。原有的克隆在项目里的用例仍断言不预选。
- **文档**：`docs/cleanup-rules.md` 的“释放过少”一条已改。

## Little Snitch 网络用途说明（Internet Access Policy）

按 Little Snitch 开发者文档（help.obdev.at/littlesnitch5/ra-developers）的格式：
- 文件：`Contents/Resources/InternetAccessPolicy.plist`；各语言的 `<lang>.lproj/InternetAccessPolicy.strings` 以 plist 里的文字为键。
- 字段：`ApplicationDescription` 必填；每条连接必填 `Host`、`Purpose`；`Port`、`DenyConsequences` 可选；`Host` 用逗号分隔，`*.domain` 表示整个域，`*` 是兜底。
- 签名：Little Snitch 只在签名有效时读取，并校验这些文件。

**plist 的值写英文原文**：翻译表找不到时显示英文。英文表与原文相同，是为了让英文读者不会落到开发区域 `zh-Hans`。

**8 条连接**，端口都是 443：

| Host | 用途 |
|---|---|
| `github.com, *.githubusercontent.com` | 本应用自身的更新源与更新包、带签名的官方下载来源列表、在 GitHub 发布的应用更新包 |
| `api.github.com` | 查询在 GitHub 发布更新的应用的最新版本 |
| `itunes.apple.com` | 查询 App Store 应用的当前版本 |
| `speed.cloudflare.com` | 网络测速（每次开始前要用户确认） |
| `api.ipify.org, api6.ipify.org` | 小窗网络页面的公网 IP（按 D76 默认开启，可在“设置 › 权限”关闭） |
| `api.country.is` | IP 所属国家或地区（另行同意） |
| `storage-cleaner-benchmark-leaderboard.yangyihang96.workers.dev` | 跑分排行榜；发布或撤下结果需要用户确认 |
| `*` | 其他应用开发者自己的更新源和官方下载站；地址来自各应用或带签名的来源列表 |

`networkQuality`、Homebrew 和 `mas` 等外部进程的连接属于各自的进程，不在本应用的说明里。

**打包**：
- `build_and_run.sh` 和 `make_release_dmg.sh` 都在复制规则文件之后复制这个 plist；两个 `.lproj` 原本就整目录复制。
- Beta 构建只重写 `InfoPlist.strings`，不碰这两个文件。
- 打包后的检查（Beta 的 `verify_sparkle_bundle`、正式版的 `verify_app_metadata`，后者也检查解压的 ZIP 和挂载的 DMG）用 `cmp` 逐字节比对三份文件。

**守卫测试**（`InternetAccessPolicyTests`）：
1. 结构符合文档：只用文档列出的键；端口都是 443；没有监听；每个主机或域只出现一次；只有一条兜底；两个打包脚本都没有 App Transport Security 例外。
2. 每段文字在英文、中文两张表里都有，且两张表没有多余的键；英文等于原文，中文含中文字符。
3. 用去掉注释和字符串内容的源码，找出所有使用 `URLSession`、`URLRequest(`、`BoundedHTTPSReader.data(`、Sparkle 更新器等的文件。这个集合必须等于测试里的 12 个文件清单，每个文件依赖的条目必须在说明里。这些文件里写死的 `https://` 地址必须被具名条目覆盖，只靠兜底不算。
4. 代码里的端点常量、两个脚本里的更新源（正式版和 Beta）、`release_version.env` 里的排行榜地址，都被具名条目覆盖。
5. 两个脚本都复制并核对这三份文件。

**格式对照**（只读本机已装应用自带的同名文件）：Keka 和 iStat Menus 的每条连接写了 `Host`、`Port`、`NetworkProtocol`、`IsIncoming`、`Purpose`、`DenyConsequences`；Ulysses 只写 `Host`、`Purpose`、`DenyConsequences`、`Relevance`。本应用写 `Host`、`Port`、`Purpose`、`DenyConsequences`，是文档允许的子集。不写 `NetworkProtocol`：`URLSession` 可能走 HTTP/3（UDP 443），写死 TCP 反而不准；不写 `IsIncoming`：默认即外连，本应用没有监听。

**未实测**：本机没有装 Little Snitch，没有看到实际显示。说明文字只在签名有效的构建里生效。

## G12 后续：包含检查缓存

D104 的 G12 基准测试发现，扫描器对每个条目做的两次路径包含检查（按字面、解析链接后）每次都重新计算根目录，是元数据层最大的开销。

**实现**：
- 新增 `PathSafety.ContainmentRoot`，在 `Support/PathSafety.swift`：构造时算一次根目录的字面形式和解析形式。
  - `contains(_:resolvingSymlinks:)` 与 `isContained` 的判断式相同。
  - `containsAsWrittenAndResolved(_:)` 只算一次条目的字面形式，再从它求解析形式（与 `normalizedPath` 的算法相同）；字面检查不通过时不解析。
- `ReadOnlyCleanupScanner` 的 4 处遍历改用它：
  - 普通规则：根目录检查、第一层条目的两次检查、递归统计；
  - 重复应用：第一层与统计，复用同一个根；
  - 废纸篓：自己建一个；
  - `aggregateSize`：参数改为 `allowedRoot`。
- 其余单次调用的 `isContained` 不变。排除项检查没有改：它的成本随排除项数增长，默认没有排除项。

**语义**：根目录不变时，判定与原来逐项相同。根目录在遍历中被换成链接时，保留开始时的边界：经新链接到达的条目仍在外面，原来的写法会跟着新链接放行。这个方向更严，见测试 `testARootRelinkedDuringTheWalkKeepsItsBoundary`。

**测试**（`PathSafetyContainmentRootTests`）：
- 在含 `..`、`.`、双斜杠、末尾斜杠、指向外部和自身的链接、名称前缀相同的兄弟目录、`/var` 与 `/private/var` 两种写法的夹具上，9 类根、20 类候选，三种判断与 `isContained` 逐项比较，超过 300 组；
- 根目录换成链接后的边界；
- 源码守卫：扫描器里不再有 `allowedRootPath`；只有两处建 `ContainmentRoot`；`aggregateSize` 用合并检查，不再调 `isContained`。
- 回归：扫描器安全相关的 9 个套件 117 项 0 失败（原有 2 项手动开启的跳过）。

**计时**（证据 `batch-e/e5/`）：
- 程序与用法：`e5_bench.swift` 与 App 的 `PathSafety.swift` 一起编译；夹具用 D104 的 `make_fixture.py`，固定随机种子，21,553 个条目，在任务临时目录里。遍历方式与 `aggregateSize` 相同，对每个非链接条目做改前（两次 `isContained`）或改后（`containsAsWrittenAndResolved`）的检查，7 轮取中位数。
- 运行时间：2026-10-18 12:28:17–12:28:29 AEDT，1 分钟负载约 5.9。

| 检查 | 中位墙钟 | 中位 CPU |
|---|---|---|
| 不检查 | 210.7 ms | 210.2 ms |
| 改前 | 714.0 ms | 712.0 ms |
| 改后 | 396.2 ms | 395.1 ms |

整次遍历少 44%，包含检查本身约 503→185 ms；`--verify` 逐条比较两种写法的判定相同，3 个外部探针两种写法都拒绝。负载下的数字只用于两种写法之间的比较。

**`getattrlistbulk` 不采用**：计划要求合计一致并且快 25% 才替换。D104 的测量带真实包含检查时只快 17.7%（中夹具）和 9%（Xcode 包），而且要改写读取层，所以不采用。

## Stats 历史库：不加规则

开源 Stats 的 `Kit/plugins/DB.swift` 把历史存在 `~/Library/Application Support/Stats/lldb`，`ttl = 60*60`，`clean()` 删除一小时以前的记录。逆向时看到约 3.5 MB，它自己会清理，不值得加规则（iStat 的历史库约 184 MB，已由 D101 G7 处理）。

## G3：仍待实测

计划要求先测量：不可见状态下 30 分钟内 helper 的 CPU 时间、唤醒次数和能耗，以及同时段 IOReport 与 `powermetrics` 的读数差，再决定不可见时是否改用 IOReport。测量要运行装有 helper 的版本（计划 §9 第 5 项）。用户本人运行测试版后，可以由用户决定是否让我只读观察 helper 的运行时长和累计 CPU（`ps`）。这只是观察，不是计划里的受控测量。本批不改 helper 的采样。

## D117：iStat 小窗的设计与底层逻辑

**逆向**：对象是 iStat Menus 7.30（Setapp 版，build 2283）的 Menubar.app 与 history.xpc，只做静态分析：ObjC 元数据、otool 反汇编、Ghidra（REA）反编译，可疑常量回到汇编核对。没有启动、附加、发信号或注入 iStat 的进程，没有改它的文件和设置，没有读它的偏好，没有导出它的图像素材，也没有照抄它的代码。两份报告（界面与交互、采样与历史）存在证据目录 `batch-e/istat-re/`。

**与我们相关的发现**（[观察] 为直接读到的）：
- 面板是自绘窗口，宽 301，卡片缩进 8、圆角 8、间距 8；三级历史 120 根柱、每根 3 pt。[观察]
- 悬停立即打开下一级；鼠标朝已开子菜单那一侧移动（ΔX ≥ 1）时，最长 1.0 s 内忽略悬停目标的变化，方向反过来就解除。点击不打开子菜单。[观察] 这与 10-07 黑盒记录的“点击才开”相反；那次指针由用户手动移动，很可能悬停时已经打开。实机只悬停、不点击的确认仍待做。
- 网络图上下两个方向各自取可见窗口的最大值，最小量程 1024 B/s，柱高 = max(1, 半高 × min(1, (值/最大)^0.75))；磁盘活动历史同样两向各算、0.75 次幂，但没有下限和上限（最大为 0 时可能 NaN）。每次重画重算，没有衰减。[观察]
- 三级图每次请求带递增序号，过期回复丢掉；切换区间时先清空再取数，会闪一下空白。[观察]
- 历史库：每 360 s 经 XPC 批量写入、聚合和清理；清理名单漏了 swap，没有 VACUUM，也没有大小上限。[观察]
- 进程列表只在面板打开时采：立即一次、0.5 s 后一次、之后每 2 s；关闭就停。powermetrics 是常驻的 `-i 2000` 流，iStat 没有解决 G3 的问题。[观察]

**落地 1：镜像吞吐图两半各自定量程**（`MenuBarGeekCharts.swift`、`MenuBarPreparedChart.swift`）：
- `GeekBarChartScale.throughputUpperBound` 只看一个方向的桶值，取整后不低于 `throughputFloor`（1 KiB/s）。下限放在取整之后：直接把 1024 交给取整会得到 1250。
- `GeekPreparedNetworkFrame` 的 `maximum` 换成 `uploadMaximum`、`downloadMaximum`；`GeekPreparedDiskFrame` 换成 `readMaximum`、`writeMaximum`；删掉 `GeekDiskIOChartMode.maximum(for:)`。
- 网络图和磁盘图各有两套 `PanelChartAxisScale`，每个方向各自上升即跟、下降按原来的 10 s 衰减。
- `GeekMirroredBarSeries` 用 `GeekBarChartScale.barFraction`：合并图的两半按 0.75 次幂压缩；单方向磁盘图保持线性（只有一个方向，没有需要“看得见”的另一半）。
- 一、二、三级用的是同一个图表视图，所以都按新规则画。悬停提示和读屏摘要仍是实测值。
- 网络和合并磁盘的三级历史底部，“纵轴自动”改为“上下各自缩放”（英文 “Each half auto-scaled”），悬停说明和读屏都写明两半柱高不能直接比较。单方向磁盘图仍写“纵轴自动”。380 pt 宽下中英文都放得下一行（测试量过）。

**落地 2：悬停斜移保护**（`SmallWindowInteraction.swift`）：
- `openChildHeading()` 取代 `isMovingTowardOpenChild()`：以指针所在的那一列为起点，检查轨迹会不会从近边进入排在它后面的已开子列。原来只认总览这一列，现在模块列朝已开的历史列也保护（`attachedCascadeLayout.visibleFrames` 按“父在前、子在后”排列）。
- 原有 320 ms 宽限不变。新增 `holdWhileHeading`：每 50 ms 检查一次；宽限内朝反方向移动 2 pt 就立即切换；宽限过后，只要上一段仍朝子列前进至少 1 pt 就继续等，总计最长 `corridorMaximumHold`（1 s）；停下或回头就在下一次检查时切换。
- 只在调用方没有指定延时时生效；控制面板（检查器）传了固定延时，不受影响。离开当前卡片或悬停到别的卡片仍会立即作废这次切换，保持条件也照旧在最后复核。

**落地 3：iStat 历史库规则理由**（`ReadOnlyCleanupScanner.swift` 的 `CleanupRuleCopy`）：补“iStat Menus 7.30 不会清理其中交换空间的历史，这个文件夹会一直变大”。规则本身（路径、分级、要求 iStat 的三个进程都退出）不变。

**不采纳**（理由也写在 D117）：
- 1 小时以下的柱子改为桶内平均：现在是桶内最后一个有效样本，由 `testNetworkHeadlineAndMirroredBarsUseTheirLatestHistorySample` 等测试锁定；改动面大，收益小。
- 柱子边界对齐整点：1 小时及以上已按 epoch 对齐的 600 个窗口再分柱，1 小时以下改了会牵动实时显示。
- 只画已结束的桶：与实时显示冲突。
- 切换区间时先清空：我们保留旧图并显示“更新中…”，比 iStat 好。
- 进程区只在面板打开时采：与 D74“关闭时也低频预存、打开即显示”冲突；首个差值同样隔 0.5 s（`MenuBarPerformancePolicy.firstProcessSampleInterval`）。
- G3 的 powermetrics 租约：iStat 也常驻采样，没有可学的做法；仍等实测和用户决定。
- 电池历史回填、14 套主题、强调色派生、“⋮”小菜单：权限未知或没有需求。

**测试**：见“测试与门禁”。

## 逆向学习点覆盖表

“已做”指源码与隔离测试层面，不等于实机验收。

### 《2.0.1 改进计划》§2 的 21 项

| 项 | 状态 | 记录 |
|---|---|---|
| G6 删除死代码 `shellQuoted` | 已做 | D100 |
| L8 删除原语与外部进程清单 | 已做 | D100（返修 A-R4） |
| G4-1 生成完整规则表 | 已做 | D100 |
| G1 预计释放扣除克隆与快照 | 已做（扫描结果、项目产物、大文件、重复文件、文件分析） | D100、D104 |
| G8 SSD 健康细节 | 已做 | D100 |
| G5 授权后只重扫新位置 | 已做；实机切换权限待用户 | D100、D104 |
| L5 旧“清空废纸篓”走冻结快照 | 已做 | D101 |
| G13 计划规模异常时多确认一次 | 已做 | D101 |
| G4-2 受保护名单按语义合并 | 已做 | D101 |
| G10 Bun 缓存规则 | 已做；预选判断本批修订 | D101、D116 |
| G2 iOS 模拟器清理 | 已做（逐项按 UUID） | D101 |
| G9 识别厂商卸载程序 | 已做 | D101 |
| G7 监控软件历史库（iStat） | 已做 | D101 |
| L7＋L1 FanControl 双向签名要求 | 已做；签名构建实测待做 | D102、D105 |
| L2 签名要求加 Team ID | 已做；签名构建实测待做 | D102 |
| L4 硬件写操作进操作记录 | 已做 | D102、D105 |
| L3 Beta 与正式版 helper 启动配置一致 | 已做；开机恢复实测需重启 | D102 |
| G3 不可见时停跑 powermetrics | 待实测后再定 | 本文 G3 一节 |
| L6 手动写风扇前的会话授权 | 评估后不加（理由见 D102） | D102 |
| G11 iOS 设备备份只读展示 | 本批做 | D116 |
| G12 `getattrlistbulk` | 不替换（未达 25%）；包含检查缓存本批做 | D104、D116 |

### 《汇总》§5 的 12 条建议

| 建议 | 状态 |
|---|---|
| 1 统一路径安全闸 | 已有（冻结快照、按身份复核、`O_NOFOLLOW`＋`unlinkat`、受保护位置共享模块 G4-2） |
| 2 删除策略写进规则、默认移入废纸篓、报告幸存项、外部命令用参数数组 | 已有（D19/D22–D25 分级、幸存项报告、L8 守卫） |
| 3 项目产物要证据 | 已有（三重证据） |
| 4 按已分配空间、硬链接去重、云占位、克隆与 purgeable 单列 | 已有；克隆部分由 G1 补齐 |
| 5 完全磁盘访问引导 x/y、授权后重扫 | 已有；G5 补齐只重扫新位置 |
| 6 规则数据化、明文、签名、带版本号 | 已有（规则随 App 签名分发、来源记录与指纹）；在线更新不采纳 |
| 7 补齐增长中的类别（AI、包管理、模拟器、监控历史库） | 已有 AI、包管理；G2 模拟器、G7 iStat 历史库已做；Stats 历史库不加（本文） |
| 8 监控只用不需 root 的数据源 | 已有（IOReport、HID）；`powermetrics` 的去留看 G3 |
| 9 控制能耗（降频、按需、降采样与上限） | 已有 |
| 10 用 launchd WatchPaths 事件触发 | 不采纳（计划 §7：新增后台常驻与推送） |
| 11 特权组件用 SMAppService、类型化请求、audit token 校验、协议版本 | 已有；L1/L2/L7 加固 |
| 12 零遥测、只走 HTTPS、规则明文 | 已有；本批加 Little Snitch 说明，把每个连接写明 |

### 分报告里的其他功能

| 功能 | 出处 | 状态与理由 |
|---|---|---|
| iOS 备份 | 汇总 §3.1（CleanMyMac、MacOptimizer） | 本批只读盘点（G11），不删除 |
| 邮件附件 | 汇总 §3.1 | 已有（Mail Downloads，黄色） |
| 相似照片 | 汇总 §3.1 | 已有（r3-photos：只读元数据和小缩略图，加入待删除相册） |
| 微信、QQ、企业微信媒体 | 汇总 §3.1、`分报告/lemon.md` | 不采纳：不可再生的个人数据（D19、D22–D25），由文件分析覆盖 |
| 外置盘、Mail、文稿版本库的废纸篓 | `分报告/cleanmymac.md`、`small-cleaners.md` | 不采纳：永久删除或由系统管理，超出“优先移入废纸篓”的边界 |
| 刷新 DNS、建议结束进程 | `分报告/cleanmymac.md`、`small-cleaners.md` | 不采纳：效果短暂，需要提权或会中断用户工作 |
| `tccutil reset` 重新请求权限 | 汇总 §3.3（PureMac） | 不采纳：会清掉用户已作的授权；现有引导是打开系统设置并在返回时重新检查 |
| 安装包回执（pkg receipts）清理 | `分报告/lemon.md` | 不采纳：在系统目录、需要 root，删除后影响系统更新判断 |
| 小组件、摄像头/麦克风占用、蓝牙设备电量 | `分报告/monitors.md` | 不采纳：属于监控功能扩展，超出本批范围 |
| Stats 历史库 | 汇总 §5 第 7 条、`分报告/monitors.md` | 不加规则：自带 1 小时清理，约 3.5 MB |
| Little Snitch 网络用途说明 | `分报告/monitors.md` | 本批做 |

### 计划 §7 的 11 项（不采纳，理由沿用计划）

通用二进制瘦身与删语言包、安全覆写删除、精简或删除 Time Machine 本地快照、主动推送告警与 WatchPaths、“释放内存”（purge）、用 Spotlight 找大文件、FoundationModels 解释缓存与 CLI/Shortcuts/远程控制、私有 CGS 与 responsibility API、SMC 充电控制、在线规则更新、把重复文件合并为 APFS 克隆。

## 测试与门禁

**定向测试**（2026-10-18 12:4x，`swift build --build-tests` 后 `swift test --skip-build`，私有构建目录）：13 个套件 148 项，0 失败，2 项是原有的手动开启跳过；exit 0。套件：`PathSafetyContainmentRootTests`、`InternetAccessPolicyTests`、`MobileDeviceBackupInventoryTests`、`CleanupDefaultSelectionPolicyTests`、`BunInstallCacheRuleTests`、`LocalModelInventoryTests`、`CleanupRuleScannerTests`、`CleanupSafetyTests`、`AICleanupRuleSafetyTests`、`CleanupJunkActionableTests`、`ScanSessionRescanMergeTests`、`CleanupTrashDeletionTests`、`CleanupDuplicateApplicationTests`。删掉 G10 的冗余上限后重编，E 批 5 个套件 25 项 0 失败。

**反证**（脚本 `batch-e/e7/counterproofs.py`：每次只改一处，跑对应测试，还原后核对 SHA-256；全部跑完再重编并回归，最后比较 `git status`）：

| 编号 | 临时改动 | 结果 |
|---|---|---|
| IAPa | `build_and_run.sh` 删掉复制 plist 的一行 | 变红：`testBothPackagingScriptsShipThePolicyAndItsTranslations` |
| IAPb | 新增一个用 `URLSession` 的源文件 | 变红：`testEveryNetworkingFileIsListedAndItsAddressesAreNamed` |
| IAPc | 在 `AppStoreCatalogResolver.swift` 写死一个未列出的 `https://` 地址 | 变红：同上 |
| IAPd | 中文表删掉一条 | 变红：`testEveryTextHasAnEnglishAndAChineseEntry` |
| IAPe | 一条连接的端口改成 80 | 变红：`testThePolicyHasTheDocumentedShape` |
| G12a | `aggregateSize` 改回两次 `isContained` | 变红：`testTheScannerChecksEachWalkAgainstOneCachedRoot` |
| G12b | `ContainmentRoot` 的判断改成只比前缀 | 变红：`testTheCachedRootAnswersLikeTheCheckItReplaces` |
| G11a | 盘点文件里加一句 `write(to:)` | 变红：`testInventoryOffersNoDeletionAndIsReachableFromFileAnalysis` |
| G11b | 备份内硬链接每次都计入 | 变红：`testHardLinksLinksDeepFoldersAndUnreadableMetadataAreSafe` |
| G11c | 链接的备份文件夹不跳过、不计数 | 变红：同上 |
| G10a | 可能释放不加内部整组（回到 D101） | 变红：`testAGreenRowThatFreesTooLittleIsNotPreselected`、`testACacheWhoseClonesAllLieInsideItIsPreselected` |
| G10b | 去掉“大小 − 保守数”上限 | 没变红：等价变异，见 G10 一节；该上限已删除 |
| G10c | 去掉克隆共享量上限 | 变红：`testAGreenRowThatFreesTooLittleIsNotPreselected`（`inside-overstated` 用例） |

每项都已还原，文件指纹与 `git status` 和运行前相同；第一次运行时脚本里一个路径写错，在 IAPc 处中断，那次没有改动任何文件，改正后从 IAPc 起重跑。JEV `jev_verify`（只作辅助）：“去掉该上限不改变判断”verified 0.92；“克隆共享量上限挡住快照占用”verified 0.74（需人工复核，由 G10c 支撑）。

**D117 定向测试**（2026-10-18 13:50，同样的私有构建目录和命令；会开窗口的测试类按 D106 跳过，记为 NOT RUN，与 `verify.sh` 的做法相同）：
- 12 个套件 243 项，0 失败，exit 0。1 项跳过是原有的 `testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`（计时只在打包门禁里对优化构建检查）。
- 套件：`MirroredThroughputScaleTests`、`PanelChartNormalizationTests`、`GeekHistoryAveragingTests`、`GeekHoverDetailTargetTests`、`HoverIntentControllerTests`、`MiniWindowConsistencyRuleTests`、`IStatMenusHistoryRuleTests`、`MenuBarHistoryGapTests`、`MenuBarPanelInteractionTests`、`MenuBarPerformanceRegressionTests`、`MiniWindowRangeSwitchTests`、`HardwareControlPresentationTests`。日志 `batch-e/logs/test-d117b.log`。
- 第一次运行（`test-d117.log`）有两类失败：
  - 下限放在取整之前，1024 被取整成 1250，已改为先取整再取下限；
  - 没有跳过会开窗口的类，被 D106 显示门禁拒绝，属于预期。
  改正后重跑，得到上面的结果。

**D117 反证**（脚本 `batch-e/e7d117/counterproofs.py`，做法同上。改动模型代码的项先重编；只靠源码检查的项不重编）：

| 编号 | 临时改动 | 结果 |
|---|---|---|
| S1 | 网络两半共用一个量程 | 变红：`testNetworkHalvesFitTheirOwnPeaks`、`testIdleOrMissingDirectionKeepsTheFloor` |
| S2 | 磁盘两半共用一个量程 | 变红：`testDiskHalvesFitTheirOwnPeaks`、`testDiskWriteChartUsesItsOwnScaleInsteadOfReadPeak` |
| S3 | 去掉 1 KiB/s 下限 | 变红：`testIdleOrMissingDirectionKeepsTheFloor`、`testGeekThroughputScaleContainsEveryDisplayedPeak`、`testPreparedNetworkFrameReusesBucketsAndAveragesObservedChannelValues` |
| S4 | 合并图也画成线性 | 变红：`testMirroredSeriesCompressesOnlyMirroredHalves` |
| S5 | 磁盘图写入一半借用读取的量程 | 变红：`testEachDirectionDrawsWithItsOwnDecayingScale`、`testDiskWriteChartUsesItsOwnScaleInsteadOfReadPeak` |
| S6 | 网络图上传一半借用下载的量程 | 变红：`testEachDirectionDrawsWithItsOwnDecayingScale` |
| F1 | 网络历史不传“上下各自缩放” | 变红：`testMirroredThroughputHistoriesSayTheirHalvesScaleSeparately` |
| F2 | 底部改回“纵轴自动” | 变红：同上 |
| H1 | 宽限一到就切换（不再继续等） | 变红：`testSwitchKeepsWaitingWhileThePointerAdvancesTowardTheOpenChild` |
| H2 | 去掉 1 s 上限 | 变红：`testSwitchStopsWaitingAtTheMaximumHoldEvenWhileAdvancing` |
| H3 | 回头也等满宽限 | 变红：`testTurningBackFromTheOpenChildSwitchesWithoutWaitingOutTheGrace` |
| H4 | 只认总览这一列 | 变红：`testModuleColumnTowardTheOpenHistoryColumnKeepsProtection` |
| R1 | 规则理由删掉 7.30 那句 | 变红：`testTheBundledRuleIsAReviewedItemForTheCheckedPathOnly` |

- 13 项都已还原。最后重编（exit 0），D117 相关 6 个套件 160 项 0 失败；文件指纹和 `git status` 与运行前相同。
- 第一轮里 S4、S5、S6、F1 只跑测试、不重编，用的是 S3 留下的无下限构建。所以 S4–S6 多出一项 `testIdleOrMissingDirectionKeepsTheFloor` 失败；F1 的过滤范围不含这项，没有受影响。
- 在干净构建上单独重跑这 4 项后，只有表中列出的测试变红（`RESULTS-F1-…S6….md`）。

JEV `jev_review`（只作辅助，只发了悬停改动的 diff、图表改动摘要和测试摘要）：
- composite 0.80，safe_to_apply 0.61，action 为 escalate（需人工复核）。
- 分项满分为 2：正确性 1.92、符合要求 1.95；最弱的是测试缺口 0.84（置信度 0.52）。
- 按这个提示，补了 `testLeavingTheCardDuringTheHoldNeverSwitches`：宽限过后、仍在前进时离开卡片（视图在悬停结束时调用 `invalidateHoverIntent`，即 `cancel`），之后既不切换，状态也回到原来打开的那一项。
  - 连跑 3 次都通过（0.265–0.272 s），日志 `batch-e/logs/test-h5-hover-{1,2,3}.log`；`HoverIntentControllerTests` 共 29 项，0 失败。
  - 取消由两层保证：任务取消让等待的 `Task.sleep` 抛错；打开前还会复核 `isCurrent(request)`。所以只改一层不会让测试变红，反证按两种改法做（脚本 `batch-e/e7d117/counterproofs-h5.py`，结果 `RESULTS-H5.md`）：

| 编号 | 临时改动 | 结果 |
|---|---|---|
| H5a | `cancel(_:)` 什么也不做 | 变红：新测试，以及另外 4 项依赖取消的原有测试 |
| H5b | 等待吞掉取消（`try?`），且打开前不再复核 `isCurrent` | 变红：新测试，以及 `testDiagonalTransitTowardOpenChildDoesNotSwitchOverviewModule`、`testImmediateOpenRemainsCancellableBeforeTheNextMainActorTurn` |

  两项都已还原。最后重编（exit 0），D117 相关 6 个套件 161 项 0 失败；文件指纹和 `git status` 与运行前相同。

**完整门禁**：`script/verify.sh`，2026-10-18 13:59:38–14:35:17，参数照 AGENTS.md（Xcode 27 Beta、`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`、私有 `STORAGE_CLEANER_VERIFY_ROOT`）。结果 **FAIL，exit 1**，日志 `batch-e/gate/verify.log`、`gate.meta`。
- 通过的步骤：debug 构建；release 全量（5003 项，23 跳过，0 失败）；strict-concurrency 构建。
- debug 全量：5113 项，24 跳过，1 失败。
  - 失败项是 `MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits`：CPU 快速内核在 debug 下超出 15 s 上限，抛 `BenchmarkKernelError.resourceLimit`（15.002 s）。
  - 这是 BOARD N10 的计时项，以前几批也出现过（如 `r2-u1-preselect`、`r2-junk-actionable`、`r2-privacy`）。同一项在这次 release 全量里 0.907 s 通过；本批没有改跑分代码。
  - 当时负载约 10–12，主要来自别的程序：一个已运行 3 小时以上的 `ditto`、Google Drive、Codex。没有改阈值、工作量，也没有改成跳过。
- 因为 `set -e`，debug 全量之后的步骤这一轮没有执行。
- 单独重跑：用同一 debug 构建，负载约 6.8，通过（10.819 s），日志 `batch-e/gate/n10-rerun-1.log`。
- 门禁之后加了 H5 测试，只改了测试文件。之后在最终状态上按原命令补跑 `verify.sh` 第 41–108 行：
  - 脚本 `batch-e/gate/verify-tail.sh` 是逐字摘出的，已用 `diff` 核对；运行 14:43–14:54，exit 0，日志 `verify-tail.log`。
  - 源码守卫（exit 10、11、15 三项）没有命中。
  - 私有 API 自测与检查通过（9 处已登记）；删除与进程清单自测与检查通过（156 条、247 处）；冲突副本检查通过。
  - `verify_menu_bar_performance.sh` 通过：release 重编后，`MenuBarPerformanceRegressionTests` 17 项 0 失败，准备耗时 p95 8.19 ms。
  - `git diff --check` 通过；57 个会开窗口的测试类按 D106 NOT RUN。
- 用同一 release 构建跑 `HoverIntentControllerTests|MirroredThroughputScaleTests`：35 项（含 H5）0 失败，日志 `batch-e/gate/release-h5.log`。
- 结论：这**不是**一次完整的 `verify.sh` 通过。分段看，除 N10 计时项（单独重跑通过）以外，每一步都通过了；运行时用的要么是最终状态，要么是只差 H5 这一个测试文件的状态。门禁开始以后，产品源码（`Sources`、`Resources`、`script`、`Package.swift`）没有改动，指纹清单在 `batch-e/manifest/`。

## 安装

2026-10-18 14:55:40–15:03:57，exit 0，日志 `batch-e/install/install.log`、`install.meta`。

**命令**：`DEVELOPER_DIR=… STORAGE_CLEANER_SKIP_TESTS=1 ./script/build_and_run.sh --beta --install --no-launch`
- `SKIP_TESTS=1` 让脚本跳过它自带的 `verify.sh` 和性能测试，日志第 2 行打印了 NOT RUN。这些已在上一节单独跑过：完整门禁、N10 单独重跑、尾段补跑（含 `verify_menu_bar_performance.sh`）。
- 签名、架构和更新配置检查照常执行。

**安装前只读预检**：
- 已装测试版只有 Finder 扩展在运行（PID 1370），按设计只列出、不阻断；
- 两个 helper 都是 not running、runs 0，没有 `/var/run/…active`；
- 产品源码与门禁时相同（指纹清单），只多了 H5 这一个测试文件。

**组装、签名与交换**：
- 在 `/tmp/storage-cleaner-beta-package` 组装（项目脚本要求构建目录在 `/tmp`），用钥匙串里的证书签名。没有弹出钥匙串授权框。
- 校验通过：`verified: signed Beta bundle, isolated identity, dedicated signed update feed and BuildInfo`。
- 同签名者检查通过后，用 `renamex_np(RENAME_SWAP)` 原子交换，交换后再校验一次，也通过了。

**结果**：
- `installed without opening: /Applications/测试版.app (build 20261018035540)`。没有启动 App，日志里没有 “started from the Beta during the installation”。
- helper：安装后的检查结果是 `on_demand`，即没有驻留进程，下次受信任连接时按需启动。安装前后两个 helper 都是 not running、runs 0。
- 旧包在 `~/Developer/StorageCleanerMac-beta-backups.noindex/20261018T040356Z-97904/测试版.app.previous`，构建 20261013152803，就是 D114 记录的那一版。
- 回滚（要求测试版没有进程在运行）：`python3 script/beta_install_swap.py swap "<上面的路径>" "/Applications/测试版.app"`。

**Finder 扩展：与 D106 第四节的预期不同**
- D106 预计交换后，旧扩展继续用旧映像运行，直到 Finder 重启它。
- 实际上，交换后列出的扩展已经不是旧进程 1370，而是从新包启动的 12042；15:04 再看时，运行的是 12065（15:03:58 启动）。
- 脚本没有退出它，也没有给它发信号；是系统（Finder、PlugInKit）按需重新拉起的。
- 正式版（PID 1519，10-16 22:03 启动）照常运行。

**指纹**：脚本 `batch-e/install/fingerprints-e8.py`，只读；输出 `fingerprints-e8.json`、`.out`，不含证书名和 Team ID。
- 新测试版：`com.local.StorageCleanerMac.beta` 2.0.1，构建 20261018035540，配置 Beta。
  - BuildInfo 记的 commit 是 `6e660a59f7b6`，`dirty` 为 true，因为 D98–D117 都没提交。
  - 可执行文件 SHA-256 `7b602ee82b29db77…`。
  - App、两个 helper、更新口令程序、Finder 扩展都是证书签名，属于同一团队。
- 已装包与组装包逐项相同（343 项）。比旧包多 3 项，正是 D116 加的 `InternetAccessPolicy.plist` 和两份 `.strings`。
- 新旧两个测试版是同一团队签名；测试版与正式版也是同一团队。
- 正式版（2.0.0，构建 20261012230050）的可执行文件与 D114 记录的相同，安装没有动它。

**打开**：用户随后说“新的测试版安装并打开”。
- 先确认已装的就是最新构建：安装后产品源码没有变化，构建号仍是 20261018035540。
- 15:21:20 用 `open "/Applications/测试版.app"` 打开。用完整路径，是因为 `/tmp` 里还有两份身份相同的组装副本。
- 8 秒后：App 在运行（PID 19712）；风扇 helper 被按需拉起（launchd runs 1）；文件操作 helper 没有运行；Finder 扩展也随之重新拉起。
- 按设计，退出测试版时 App 会请 helper 把风扇交回自动控制，这是一次 SMC 写入（见 D106 第五节）。本机不是 Mac mini（门禁日志里的传感器有电池和掌托温度），所以不涉及 Mac mini 模式的 pmset 写入。

## 用户亲测清单

由用户本人打开 `/Applications/测试版.app`。不用退出正式版：测试版用自己的 bundle ID 和数据。凡是会真实删除的（清理、清空废纸篓、删除模拟器、运行卸载程序）或会写硬件的（风扇、电源模式、Mac mini 模式），只看确认页然后取消；要不要真做，由用户决定。

**A. D117 iStat 小窗（本批重点）**
1. 打开菜单栏小窗，悬停“网络”。上传、下载两半各自缩放：下载很大时，上传那一半不再只是一条细线；没有流量时两半都很低，不会被放大成满格。
2. 进入网络的三级历史：
   - 底部写“上下各自缩放”（英文为 “Each half auto-scaled”）；
   - 悬停这几个字有说明；
   - 悬停柱子显示实测值。
3. 磁盘的读写合并图同样两半各自缩放，悬停它进入的三级历史底部写“上下各自缩放”；悬停“读取”或“写入”数值进入的单方向三级详情仍写“纵轴自动”。
4. 悬停保护（只悬停，不点击）：
   - 从总览悬停一行，打开模块列。然后斜着穿过别的行，朝模块列移动：模块列不应换成路过的行。
   - 停下或往回移：立即切到指针所在的行。
   - 从模块列斜着移向已开的历史列，同样受保护。
   - 一直朝子列移动时，最多保持 1 秒。
   - 如果觉得 1 秒太长、切换发钝或没有效果，请告诉我。

**B. D116 本批其他项**
5. 文件分析页的“设备备份”：
   - 列出 iPhone、iPad 备份的设备名、系统版本、备份时间、是否加密、上次备份是否完成和占用；
   - 只有“在访达中显示”，没有删除；
   - 读不了时提示授予完全磁盘访问，并给出打开设置的按钮。
6. 智能扫描里的 Bun 缓存行（如果有）：克隆进项目的部分不预选，并在行内说明原因。只看，不清理。
7. Little Snitch 的网络用途说明：本机没有安装 Little Snitch，跳过。

**C. 前几批留下的实机项**
8. G5：在“系统设置 › 隐私与安全性 › 完全磁盘访问”里给测试版打开或关闭权限，回到 App 后检查：
   - 横幅只出现一次；
   - “重新扫描这些位置”只扫描新可读的位置，结果并入同一次扫描；
   - 已取消的勾选保持不变，扫描历史不多一条。
9. G1：扫描结果、项目产物、大文件、重复文件、文件分析“移到废纸篓”处的预计释放文字（扣除克隆与快照）。只看文字。
10. G8：健康页的 SSD 健康细节。
11. L5：菜单“清空废纸篓”。
    - 第一次确认显示数量和大小，第二次写明永久删除、无法恢复。
    - 看完取消。真清空是永久删除，由用户决定。
12. G13：只有计划超过 1 万项，或超过所在卷已用空间的一半，才会多一道勾选确认；正常规模不多步骤。一般不会遇到，可以跳过。
13. G2：“开发工具与产物”页的 iOS 模拟器入口。本机 10-15 只读核对时，按规则不会列出任何项。
14. G9：卸载页里如果有带官方卸载程序的 App，“应用本体”下方有提示和按钮。点了会运行第三方卸载程序，看到即可。
15. G7：扫描结果里的 iStat Menus 历史库：
    - 黄色、默认不勾选；
    - 理由里有“iStat Menus 7.30 不会清理其中交换空间的历史”；
    - iStat 在运行时，这一项要求先退出它。

**D. 可选（会写硬件，由用户决定，不做也可以）**
16. 风扇、电源模式、Mac mini 模式的控制，以及“操作记录”页的“硬件操作”区。
17. G3：用户运行测试版一段时间后，如果同意，我只读看一次 helper 的运行时长和累计 CPU（`ps`）。不改任何东西；这不是计划里的受控测量。

**看完以后**：告诉我“批准”或要改的地方。批准后我会先问清“上传”指推送分支、开 PR，还是发布正式版，再执行。

## 限制与待办

- Little Snitch 的实际显示没有实测（本机未安装）。
- G11 只读默认位置；备份在其他位置（经链接）时只说明、不跟随。
- G3 待实测；G1 本地快照情形、G5 完全磁盘访问切换、签名后的 XPC 与 helper、57 个会开窗口的测试类，仍按此前各批的待实机清单。
- D117 悬停：
  - 只在 `HoverIntentController` 模型层测过。真实窗口里的手感，包括 1 s 上限会不会太长、50 ms 检查够不够顺，要用户亲测。
  - “iStat 悬停即开、点击不开”来自静态分析，与 10-07 的黑盒记录相反。按逆向边界不运行 iStat，所以没有实机确认。
- D117 镜像图：0.75 次幂压缩和两半各自量程的观感没有截图验收（本批不启动 App）。两个方向各自衰减只有源码检查；会开窗口的视图测试按 D106 不运行。
- 新测试版装好后没有启动。新构建的签名团队和 Identifier 都没变，完全磁盘访问一般会延续，但没有验证；用户首次打开时如果系统再次询问，按需授权即可。
- 完整的 `verify.sh` 这一轮是 FAIL（N10 计时项），没有再整轮重跑。各步骤分别通过的记录见“测试与门禁”。
- D117 每一级都受保护，前提是窗口组的 frame 按“父在前、子在后”排列。
  - 级联布局（`MenuBarCascadeLayout.visibleFrames`）是这个顺序；没有级联布局时的备用列表是“模块列、总览、历史列”。
  - 在备用路径上，“总览→模块列”的保护原来就没有生效，本批没有改变这一点。
  - 没有测试锁定这个顺序。
- 测试日志里出现过系统通讯录框架的报错（`CoreData … AddressBook-v22.abcddb … contactsd.persistence`，连接失败）。它在测试进程里异步出现，单跑原有的 `BetaDistributionTests` 时也出现过；仓库代码没有使用通讯录接口。来源没有查明，本批没有处理。
