# disktree 第 3 期：空间透镜侧栏增强

## 主会话验收结论（2026-10-23，第 5 轮后）

本节取代后文各轮里已过时的描述（第 1 轮的 9 色用途配色、图例横向滚动、固定 14 pt 间距、“窗口 NOT RUN”等）；各轮原始记录保留在后文。

- **最终代码树**（不含本交接）：`1b630343`；基线 `0c4cbf26`，即测试版 #8 的树。共 17 个文件：新增源码 2 个、测试 3 个和本交接，修改 11 个。
- **实现**：Codex（gpt-6.1-sol）写了 4 轮。第 5 轮派发后，服务端返回 429 Too Many Requests，15 秒退出，未改文件；这一轮只补测试，由主会话完成：新增 4 项测试，并照 `computeFilter` 给“值得一看”的后台计算加了注入点 `computeWorth`，默认实现与原内联代码逐行相同。主会话没有改其他生产行为。
- **最终功能**：
  1. **值得一看**：左栏第 4 个分段，最多 6 项、64 MB 以上；行复用原有勾选、审阅和移到废纸篓（D46）；点行从分析根进入该目录，并切回“目录”。
  2. **按名称筛选**：宽窗口、“目录”分段、方块模式时，标题栏显示搜索框；“/”聚焦，Esc 清空；150 ms 防抖，可取消，最近 8 个结果缓存（键为数据版本、目录、关键词）。列表保留整块和部分匹配的原条目及大小，方块按匹配字节排布，显示“N 项匹配 · X”。
  3. **清空废纸篓后的估算**：量条上方固定一行；无勾选时显示提示，有勾选时显示“已选 X · 清空废纸篓后约释放 Y”。口径与 D104 G1 审阅相同：文件夹和有其他硬链接的文件按完整大小计，共享克隆块不计，完整克隆另提示“可能另外释放”。300 ms 防抖，可取消，按“勾选＋数据版本”缓存；只读元数据（`lstat`、共享属性），不读文件内容。
  4. **按用途着色**：“类型｜用途”切换，记在注入的偏好域（`storage-map.color-mode`）。用户定的 3 组加灰（暗色/亮色）：开发 `#3987E5`/`#2A78D6`，缓存 `#D95926`/`#EB6834`，个人内容 `#199E70`/`#1BAF7A`，其他 `#6E6B7B`/`#B6B3C2`。悬停卡写具体用途，用途模式下只对含多种用途的组加组名。两种图例叠放、保留较高的高度，切换不改布局。
  5. 方块里放不下的大小数字不画。
- **验收**（主会话，Xcode 27.1）：
  - 守卫、Debug 构建、严格并发构建通过，改动文件 0 新增警告。
  - 定向测试 309 项，0 失败（2 项为原有的按需跳过）。
  - 全量（树 `10081fe6`，与最终代码只差 `computeWorth` 注入点）：Debug 主测试包 5,698 项、跳过 29、0 失败；Release 5,443 项、跳过 28、0 失败；Swift Testing 135 项、CombinedStatusIcon 285 项全过；没有访问通讯录。
  - 窗口（借用“虚拟屏 1 · Codex”，2560×1440、1 倍，经 D106 门）：本期两类 20/20；全部 in-process 窗口类 647 项，0 失败（跳过的 5 项为截图导出用例），测试屏记录 4,353 次窗口放置。
  - 单点变异：单元 18/19，窗口 3/3。未抓到的 ST1（估算缓存只比勾选、不比数据版本）判为可观察行为等价：数据版本变化而勾选不变的唯一路径，是把其他项目从废纸篓放回，此时所选文件不变；重新扫描会清空勾选。版本留在缓存键里，作为保守失效。
  - JEV：escalate（safe 0.38，composite 0.70），不代表批准，按人工复核处理。
- **截图**：15 张（第 4 轮导出，界面代码与最终一致）已发给用户。用户 10-23 看过后原话：“截图看过了，同意。把第 3 期交给集成会话合并、跑门禁、装测试版，合入后通知 CMM 会话。”
- **已知限制**：用途分类沿用第 1 期规则，`~/Developer` 属结构目录，其下项目文件夹本身不会自动算“开发”；示例里 `.build` 在个人目录根下，显示“其他”。是否加“含 `.git` 的文件夹算开发”，由用户决定。气泡名字宽度由 CMM 会话在本期合入后修；工作树最老时间和陈旧依赖留第 4 期。

## 建议的 DECISIONS 条目（编号由集成会话分配）

| D180 | D170 第 3 期：空间透镜页侧栏增强。① 左栏第 4 个分段“值得一看”：后台分类后列出最多 6 项、64 MB 以上的可再生或可重装目录及 AI 工作区里的工作树，副标题写原因和位置（工作树写数量）；行复用原勾选、保护原因和 D46 审阅，点行从分析根进入并切回“目录”。② 按名称筛选：宽窗口、“目录”、方块模式时标题栏显示搜索框，“/”聚焦、Esc 清空；150 ms 防抖，可取消，最近 8 个结果缓存；列表保留匹配条目原大小，方块按匹配字节排布，显示匹配数和字节；进入、返回保留，离开方块、切分段、变窄清除。③ 量条上方固定一行估算“已选 X · 清空废纸篓后约释放 Y”，口径同 D104 G1（文件夹、其他硬链接按完整大小，共享克隆块不计，完整克隆另提示），只读元数据，300 ms 防抖，可取消，按勾选和数据版本缓存；无勾选时显示提示，行高不变。④ 方块图“类型｜用途”着色，偏好键 `storage-map.color-mode`；用途按用户定的 3 组加灰：开发（代码、工具链、版本库、AI 工作区）蓝、缓存橙、个人内容（媒体、文档、同步盘）青绿、其他灰，深浅两套色经色觉和对比校验；悬停卡写具体用途；两种图例叠放，切换不改布局。⑤ 方块里放不下的大小数字不画。勾选、审阅、移到废纸篓仍只走 D46，不加删除路径。 | — | 新文件 `Features/LargeFiles/Services/FileAnalysisSelectionReclaim.swift`、`Views/CareStudio/SpaceLensWorthALook.swift`；测试 `FileAnalysisSelectionReclaimTests`、`SpaceLensSidebarTests`、display-bound 的 `SpaceLensSidebarWindowTests`；改 `CareStudioSpaceLens.swift`、`SpaceMapTreemapPainter.swift`、`SpaceMapTreemapView.swift`、`SpaceMapTreemapInputBridge.swift`、`SpaceMapTreemapSource.swift`、`SpaceMapTreemapViewState.swift`、`LargeFilesStore.swift`、`FileAnalysisLightfieldView.swift`、`Debug/FeatureLightfieldFileResultFixture.swift`、`SpaceMapTreemapWindowTests.swift`（仅适配）、`script/display-bound-tests.txt`；BOARD F 行、`THIRD_PARTY_NOTICES.md` disktree 一节补一段；交接 `handoffs/disktree-p3.md` |

---

以下为各轮原始记录。

实现及沙箱内非窗口验证 **PASS**：最终构建 exit 0；指定过滤的 181 项测试通过，0 失败、0 跳过；本期新增及修改文件 0 编译警告。窗口、截图和整个项目的验收 **NOT RUN**，仍由主会话完成。

工作目录 `/Users/developer/Developer/sc-worktrees/disktree-p3`，基线来自任务书所述 `0c4cbf26` 镜像，未通过 Git 核对。开始时保存了白名单文件原文、存在状态及 SHA-256，未做任何 Git 检查。执行跨过午夜，最终验证日期为 2026-10-23（Australia/Sydney）。没有 commit、push、安装、启动应用、外发或委派其他 Worker。

## 文件清单

共新增 6 个、修改 11 个文件，全部在任务白名单内。路径均相对项目根目录。

| 文件 | 作用 |
| --- | --- |
| 新增 `Sources/StorageCleanerMac/Features/LargeFiles/Services/FileAnalysisSelectionReclaim.swift` | 注入元数据和共享属性读取；逐项估算、后台计算、缓存键和双语估算文字。 |
| 新增 `Sources/StorageCleanerMac/Views/CareStudio/SpaceLensWorthALook.swift` | 发现经父目录快照映射为普通行；相对位置、原因、工作树、空状态及匹配数文案。 |
| 新增 `Tests/StorageCleanerMacTests/FileAnalysisSelectionReclaimTests.swift` | 12 项纯测试：共享/克隆/硬链接/目录/未知/多卷、审阅等价、防抖和迟到结果。 |
| 新增 `Tests/StorageCleanerMacTests/SpaceLensSidebarTests.swift` | 20 项纯测试：推荐、筛选缓存与取消、用途色、图例、偏好、双语文案和只读契约。 |
| 新增 `Tests/StorageCleanerMacTests/SpaceLensSidebarWindowTests.swift` | 8 项 display-bound 测试：双语几何、筛选/Esc/斜杠焦点、目录保留/离开清除、用途、推荐、估算、条件截图。 |
| 新增 `docs/2.0.0/collab/handoffs/disktree-p3.md` | 本交接。 |
| 修改 `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSpaceLens.swift` | 第四分段、推荐行和气泡、搜索、用途切换及图例、估算文字、新回调与探针。 |
| 修改 `Sources/StorageCleanerMac/Views/CareStudio/SpaceMapTreemapView.swift` | 接筛选、用途色和搜索焦点回调；空匹配提示；保留旧布局直到新布局就绪。 |
| 修改 `Sources/StorageCleanerMac/Views/CareStudio/SpaceMapTreemapPainter.swift` | 用途填充、9 色映射、7/9 项图例模型；绘制等价判断包含颜色模式。 |
| 修改 `Sources/StorageCleanerMac/Views/CareStudio/SpaceMapTreemapInputBridge.swift` | `/` 映射为 `.focusFilter`。 |
| 修改 `Sources/StorageCleanerMac/Features/SpaceMap/Treemap/SpaceMapTreemapSource.swift` | 推荐、分类及筛选后台任务；筛选缓存键；布局输入和键携带筛选。 |
| 修改 `Sources/StorageCleanerMac/Features/SpaceMap/Treemap/SpaceMapTreemapViewState.swift` | `SpaceMapColorMode`：`type`、`purpose`。 |
| 修改 `Sources/StorageCleanerMac/Features/LargeFiles/Stores/LargeFilesStore.swift` | 注入元数据读取；300 ms 防抖估算、取消及版本缓存；注入 defaults 保存颜色模式。 |
| 修改 `Sources/StorageCleanerMac/Views/FilesLightfield/FileAnalysisLightfieldView.swift` | 传颜色绑定、估算状态；推荐进入使用 `openStorageMapDirectory(_:fromLevel: 0)`。 |
| 修改 `Sources/StorageCleanerMac/Debug/FeatureLightfieldFileResultFixture.swift` | 新增可选的颜色/估算初始化值并接入页面；推荐从夹具根补齐中间层。 |
| 修改 `Tests/StorageCleanerMacTests/SpaceMapTreemapWindowTests.swift` | 仅为新增绑定参数补 `.constant(.type)`，原断言和行为未删改。 |
| 修改 `script/display-bound-tests.txt` | 登记 `SpaceLensSidebarWindowTests` 为 in-process。 |

`FileAnalysisTrashService.swift`、审阅流程、CMM 的窗口测试、DECISIONS、BOARD、THIRD_PARTY_NOTICES 均未修改。第 2 期其他测试文件未修改。

## 四项功能

1. **值得一看**：`surface == 3`。页面自己的 source 在进入该分段时触发分类，无需先打开方块图；分类和推荐以数据版本复用。后台调用 `worthALook(limit: 6, minimumBytes: 64 * 1_024 * 1_024)`，再从各发现父目录的索引快照取得完整条目。副标题中父目录相对分析根显示，家目录为 `~`；工作树显示数量。复用 `row(_:)`、`onToggle` 和保护原因，点击进入走新 `onOpenFromRoot` 后切回目录。右栏使用原气泡路径，隐藏样式控件并保留 34 pt 高度；查找中只显示一行文字。
2. **按名称筛选**：仅宽窗口、目录、方块模式显示 200 pt 现成搜索框，紧邻“更多”左侧，路径优先截断。首尾去空白，150 ms 防抖；SwiftUI 任务键变化取消旧任务，取消继续传给 detached 任务。筛选键包含版本、当前路径、关键词，最近 8 个结果缓存；布局键也含已应用的关键词。防抖期间沿用同一目录上一份结果，新层不借用父层结果。列表保留整块和部分匹配的原条目及大小；布局使用算法的匹配字节；数量使用 `matchedItems`。斜杠请求搜索焦点，Esc 清空。进入、返回保留；离开方块、切分段、变窄清除。
3. **清空废纸篓后的释放估算**：store 发布 `selectionReclaim`、`isEstimatingSelectionReclaim`；每次选择或分析版本变化取消旧任务，300 ms 后读元数据，缓存最近一次完成的“选择数组＋数据版本”。目录不读子项；普通文件先 `lstat`，仅无其他硬链接时读共享属性。设备号采用扫描器同样的位模式转换。调用 `CleanupReclaimableEstimate.file` 后用 `CleanupSelectionReclaimable(items:)` 汇总。没有选择时为 nil；计算时显示省略号。文字单独占用量条上方一行，避免长英文挤压容量文字；条形图与白色已选段仍按原逻辑字节绘制。
4. **按用途着色**：偏好保存在注入 defaults 的 `storage-map.color-mode`，非法值回到 `type`。目录查自身用途，文件查父目录；分类未就绪回退类型色。切换只改变绘制决定，不改变布局键。原深浅、斜线、警示、徽标及描边均保留，中性块不受用途影响。图例使用原页面的 7 pt 点和 11 pt 文字，类型 7 项，用途取 `allCases` 的完整 9 项（旧算法的 `legend` 只有 8 项，未修改它）。

新增探针：`careStudio.spaceLens.filter`、`colorMode`、`legend`、`worth`、`reclaim`，均具有完整 `careStudio.spaceLens.` 前缀。原探针全部保留；`static func bubble(_:)` 与保存的原文逐字相同。

窄列表用 `ViewThatFits`：14 pt 间距仍放不下四个完整标题时，原分段控件分两行展示。右栏控件也允许两行。图例为 `LazyVGrid(.adaptive(minimum: 88))`，内容至少 472 pt，至多两行；较窄的右栏通过横向滚动浏览全部图例，1024 宽截图场景无需缩小文字。上述实际几何仍须窗口测试和截图复核。

## 用途配色

全部取对应 `CareStudioFamily.palette.actionGlow`；排除空间地图自身的 `.spaceMap`，9 色与两种中性填充均不同。

| 用途 | Family | RGB |
| --- | --- | --- |
| code | applications | `#74B4FF` |
| agentWorkspace | smartCare | `#E45BE0` |
| toolchain | performance | `#FFB45E` |
| synced | cloudCleanup | `#86C8FF` |
| git | cleanup | `#8CDB6A` |
| media | protection | `#F472C8` |
| documents | clutter | `#70E6D8` |
| cache | myTools | `#9E94F0` |
| other | myActivity | `#A08CFF` |

## 与审阅一致的证据

`FileAnalysisSelectionReclaimTests.testEachEstimateAndTotalMatchAnAllReadyD46Review` 构造 7 个全部 `.ready` 的审阅项：两份同卷完整克隆、其他硬链接、目录、未知共享、未报告共享、另一卷同 clone ID。预期项按未改的 `FileAnalysisTrashService.review` G1 公式构造，逐项比较新函数的 `reclaimableEstimate`，再逐项及合计比较 `FileAnalysisTrashReview.reclaimable`；合计断言 `freedBytes == 460`、`possibleCloneBytes == 80`。其余测试另覆盖普通文件、快照保留及读取次数。

这证明全部就绪输入的计算等价；纯测试没有调用实际 `review` 的文件就绪检查（该函数固定使用真实 `lstat`，本任务禁止真实文件夹具）。扫描身份、保护、就绪判断与移动仍由原 D46 执行，不由预览代替。

## 实际验证

环境与工作目录如上，命令均使用：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing --filter '^StorageCleanerMacTests\.(FileAnalysisSelectionReclaimTests|SpaceLensSidebarTests|SpaceMapTreemap(ViewState|Source|Painter|DataVersion)Tests|SpaceLensBubbleIconTests|SpaceMap(TreemapLayout|TreemapFilter|PurposeClassifier|Insights)Tests|FeatureLightfieldFilesPresentationTests)'
python3 -B script/display_bound_tests.py --check
```

| 记录 | exit | 结果 |
| --- | --- | --- |
| `build-1.log` | 1 | 新绑定参数的初始化错误，已改为正常绑定并适配调用方。 |
| `build-2.log` | 1 | 注入闭包参数顺序影响原 trailing closure，已恢复兼容顺序。 |
| `build-3.log` | 1 | 新测试误引用其他测试类的 private 文件系统夹具，已改成本文件无读取的 stand-in。 |
| `build-4.log` | 0 | 全部源码和测试编译通过，本批文件 0 警告。 |
| `build-5.log` | 0 | 元数据设备号、用途中继测试及导航窗口测试收尾后通过，本批文件 0 警告。 |
| `test-1.log` | 1 | 181 项；1 个用例的 2 条断言误把 `.js` 的类型色写成 other，改为快照已有的 developer，没有改生产回退逻辑。 |
| `build-6.log` | 0 | 最终构建通过，本批文件 0 警告、构建 0 错误。 |
| `test-2.log` | 0 | 最终 181 项，0 失败、0 跳过，主包约 1.8 秒。 |
| `display-check.log` | 0 | 62 个 in-process、1 个 out-of-process、1 个 exempt，登记通过。 |

最终测试数量：估算 12；侧栏纯测试 20；气泡图标 2；惰性夹具 6；Insights 9；PurposeClassifier 39；DataVersion 2；TreemapFilter 10；TreemapLayout 19；Painter 37；Source 7；ViewState 18，合计 181。新增窗口类另有 8 项，已编译、未运行。

完整证据目录：`/private/tmp/disktree-p3-evidence/`。每份 build/test/display 日志有同名 `.exit`；`baseline.json` 和 `baseline/` 保存原文；`implementation.diff` 为对原文的统一差异（未使用 Git）；`source-checks.json`、`final-review.json` 保存文件哈希与自查；`test-command.json` 保存实际 argv、环境和目录，`verification.json` 保存最终验证摘要。

SwiftPM 有用户缓存不可写和 manifest 只读数据库提示，链接器有既有 duplicate rpath 提示；较早的完整增量编译还打印基线中的既有测试警告。本批文件没有新增编译警告。测试日志包含 `sandbox_extension_issue_file failed … defaults.plist: 1 (Operation not permitted)`；最终所有断言通过，但同进程偏好读回不等同于沙箱外跨进程持久化验证。未申请扩大权限或绕过沙箱。

## 主会话后续与限制

- **窗口和截图 NOT RUN**：按任务书只能由主会话在“虚拟屏 3 · Claude”（2560×1440、1 倍）运行 `script/run_display_bound_tests.sh --display "虚拟屏 3 · Claude"`，本 Worker 未尝试操作桌面。重点复核标题完整、搜索焦点、路径/更多、图例滚动与圆按钮边界。
- 条件截图测试仅在设置 `STORAGE_CLEANER_SPACEMAP_EVIDENCE` 后写 PNG：`c-worth`、`c-filter`、`c-purpose`、`c-reclaim` 各中暗/英亮 2 张，`c-type-legend` 中暗 1 张，`c-tabs` 的 760/1280 × 中英共 4 张，总计 13 张。先给用户看，再由主会话按授权安排后续安装。
- 完整 `FileAnalysisTrash*`、`StorageMap*` 回归、既有窗口类、全量门禁、Release 和独立复核留给主会话；本轮只运行上面指定的过滤范围。没有未解决的构建或纯测试 BLOCKED。
- 工作树最老时间和陈旧实验依赖修改时间索引，留第 4 期；本期只显示工作树数量。
- 按 `code-review-and-quality` 技能做了正确性、可读性、架构、只读边界及性能自查，不能代替主会话独立验收。沿用当前模型与推理设置，没有调用其他模型；JEV 未调用，本轮没有明确的来源与预算授权。

## 第 2 轮

2026-10-23，处理主会话的 4 条复核意见。代码和沙箱内验证 **PASS**；窗口几何及截图 **NOT RUN**，仍由主会话在测试屏验收。本节更新第 1 轮中关于固定 14 pt 间距、条件估算行、图例横向滚动的描述。

本轮仅修改第 1 轮已有的 3 个文件：

| 文件 | 实际修改 |
| --- | --- |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSpaceLens.swift` | 左栏和右栏通过 `ViewThatFits` 按 26、20、14 pt 尝试单行，均放不下时采用原两行方案；两组右栏分段保持完整宽度。估算行始终占 14 pt，无选择时显示双语次要色提示，原有已选文字、help 及 reclaim 探针保留。图例改为 adaptive minimum 80 的自然换行网格，按内容定高；保留 11 pt 字号，单项单行尾部截断，help 为完整名称。单行匹配数位于颜色切换之后、层数之前，`layoutPriority(-1)` 并单行尾部截断；两行布局仍跟在首行分段后。 |
| `Tests/StorageCleanerMacTests/SpaceLensSidebarWindowTests.swift` | 原几何测试增加中文 1024/1280 宽下左右分段均为 26 pt 的断言；新增 3 项窗口测试，见下。截图场景、文件名、截图实现及索引夹具逐字保留。 |
| `docs/2.0.0/collab/handoffs/disktree-p3.md` | 仅追加本节。 |

每项图例新增探针 `careStudio.spaceLens.legend.<id>`；id 复用 Painter 的 `type.<category>` 或 `purpose.<purpose>`。另增 `careStudio.spaceLens.matches`、`careStudio.spaceLens.depth`，用于匹配数相对位置和控件边界断言。原探针全部保留，`static func bubble(_:)` 逐字未改；其余第 1 轮文件的 SHA-256 均与本轮开始时一致。

新增窗口测试（本类现有 11 项，均已编译）：

- `testEveryLegendItemFitsWithinThreeRowsAboveTheActionInBothLanguages`：760/1024/1280 宽 × 中英文 × 类型/用途模式，逐项探针必须存在且落在图例框内，至多 3 行，图例在方块图下、圆按钮上。
- `testSelectingAndClearingPreservesListBlocksAndBubblePositionsInBothLanguages`：双语下实际勾选首项、取消最后一项，列表与方块图/气泡的探针 minY 不变，估算行高度不变，并检查无选择提示。
- `testMatchCountFollowsColorInOneRowAndStyleInTwoRowsWithoutDisplacingControls`：双语 1280/760 宽，检查单行/两行匹配数位置，颜色和层数控件在控件行内。

实际执行的三条命令与第 1 轮“实际验证”代码块相同，环境保持 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`、`CLANG_MODULE_CACHE_PATH=$PWD/.build/codex/clang-module-cache`。测试过滤仍锚定 `^StorageCleanerMacTests\.`，覆盖本期全部纯测试；新增窗口方法保留在已登记的 display-bound 类内，未在沙箱执行。

| 命令 | exit | 结果及日志 |
| --- | --- | --- |
| `swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox` | 0 | 35.29 秒，0 错误；本轮修改的 Swift 文件 0 编译警告。`build-1.log`。 |
| 第 1 轮原定锚定过滤的 `swift test`（完整 argv 见 `test-command.json`） | 0 | 主测试包 181 项，0 失败、0 跳过。`test-1.log`。 |
| `python3 -B script/display_bound_tests.py --check` | 0 | 62 in-process、1 out-of-process、1 exempt。`display-check.log`。 |

证据目录：`/private/tmp/disktree-p3-round2-evidence/`。各日志有同名 `.exit`；`baseline.json` 与 `baseline/` 保留修改前文件和哈希；`implementation.diff` 为本轮相对第 1 轮的差异；`source-checks.json`、`verification.json` 记录范围、旧探针、气泡方法、截图实现与验证结果。SwiftPM 用户缓存/manifest 只读、既有 duplicate rpath 及偏好沙箱提示仍存在，不是本轮新增源码警告。

按 `code-review-and-quality` 做了本轮自查，没有调用其他 Worker 或更换模型。JEV 未调用：当前未发现可用工具，且无本轮来源与预算授权。开始时误执行了一次只读 `git status --short`，读到 brief 的禁止事项后停止所有后续 Git 检查；没有 Git 写操作、commit、push、安装、启动应用或操作桌面。

留给主会话：在测试屏运行 `SpaceLensSidebarWindowTests` 全部 11 项（含新增 3 项）及既有窗口回归，按原场景导出并复核 13 张截图；无选择场景现包含提示行。尚无窗口/截图通过证据，未宣称整个项目完成。第 4 期修改时间相关事项沿用上文。

## 第 3 轮

2026-10-23，按用户决定实现“3 组用途色＋其他灰”。本轮构建及指定纯测试 **PASS**；鼠标交互、窗口几何和新截图 **NOT RUN**，留给主会话在测试屏验收。已逐张查看主会话提供的 `/Users/developer/Developer/.sc-build/disktree-p1/evidence-p3/r2/` 下全部 13 张 `c-*.png`，确认旧用途色接近、控件组缺少分隔，以及估算演示值不合理。

本轮只修改前两轮已有的 7 个文件：

| 文件（相对项目根） | 实际修改 |
| --- | --- |
| `Sources/StorageCleanerMac/Views/CareStudio/SpaceMapTreemapPainter.swift` | 新增 `PurposeGroup`，9 种用途归为 4 组；用途填充按外观取固定色，图例按组提供名称和完整 help；悬停卡在类型后写具体用途，用途模式追加组名。目录取自身用途，文件取父目录用途，分类未就绪不加用途行。 |
| `Sources/StorageCleanerMac/Views/CareStudio/SpaceMapTreemapView.swift` | 将当前颜色模式传给悬停卡模型。 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSpaceLens.swift` | 用途图例使用实际外观颜色及组 help；颜色切换整体无障碍标签为“着色方式 / Color by”，保留子按钮；单行控件组间增加两条 1×16 pt hairline，左右各 10 pt，两行布局不加。行勾选框增加仅 DEBUG 的 `careStudio.spaceLens.check.<entry.id>` 探针。 |
| `Tests/StorageCleanerMacTests/SpaceLensSidebarTests.swift` | 侧栏纯测试由 20 项增至 25 项，覆盖逐项分组、固定深浅色、其他与中性灰区别、4 项图例的顺序/标识/双语名称与 help，以及两种模式下目录和文件的悬停用途行；类型 7 项、未就绪回退及装饰断言保留。 |
| `Tests/StorageCleanerMacTests/SpaceLensSidebarWindowTests.swift` | 两项失败测试改为由探针中心转换到窗口坐标，构造 `NSEvent.mouseEvent` 的按下/抬起并经 `window.sendEvent` 勾选，失败时才打印该行附近 AX 角色和标签。布局不跳动与进入后切回目录的原断言保留；扩展现有控件测试验证分隔与整体无障碍标签。修正 reclaim 演示并新增 purpose-hover 场景。 |
| `Tests/StorageCleanerMacTests/SpaceMapTreemapWindowTests.swift` | 仅适配新增用途行：悬停行数 4/6/5 改为 5/7/6，受保护/可回收原因的末行索引顺移；原自然高度、边界、文字可见及原因换行断言全部保留。 |
| `docs/2.0.0/collab/handoffs/disktree-p3.md` | 仅追加本节。 |

用途色和图例顺序如下，原样使用用户提供的数值：

| 组名 | 具体用途 | 暗色 | 亮色 |
| --- | --- | --- | --- |
| 开发 / Development | code、toolchain、git、agentWorkspace | `#3987E5` | `#2A78D6` |
| 缓存 / Caches | cache | `#D95926` | `#EB6834` |
| 个人内容 / Personal | media、documents、synced | `#199E70` | `#1BAF7A` |
| 其他 / Other | other | `#6E6B7B` | `#B6B3C2` |

校验来源是本轮任务中主会话提供的数据可视化脚本结果，本 Worker 没有重新运行该脚本，也未调整颜色：旧 9 色正常视力最差一对色差为 **3.3**，下限 **15**；新方案在暗色面板 `#30278A`、浅色面板 `#E4E2F4` 上，三个彩色两两比较，两种外观均通过。浅色橙色和青绿对面板的对比低于 **3:1**，按要求保留方块图的可见名字标签。这些依据已写进 Painter 注释。“其他”分别与合并块/余量块中性灰 `#3A3A42`、`#E8E8EE` 区分，纯测试核对实际 `Fill.color(dark:)`。深浅、斜线、警示点、勾选徽标、描边及类型着色的绘制规则未改。

图例 help 示例：`开发：代码、工具链、版本库、AI 工作区` / `Development: Code, Toolchains, Git, AI Workspaces`。悬停示例：类型模式为 `用途：AI 工作区` / `Purpose: AI Workspaces`；用途模式为 `用途：AI 工作区（开发）` / `Purpose: AI Workspaces (Development)`。双语测试同时检查用途行紧随类型行。

`c-reclaim` 使用实际勾选的前两项合计 **111 GB**，共享克隆块 **7 GB**，故 `freedBytes` 为 **104 GB**；`wholeCloneGroupBytes` 和汇总后的 `possibleCloneBytes` 为 **3 GB**，help 会追加“所选的完整克隆可能另外释放 3 GB”。只改测试注入值，没有修改生产估算口径。

新增截图 `c-purpose-hover-1024-zh-dark.png`、`c-purpose-hover-1024-en-light.png`：富样例、用途模式，指针落在 `.codex/worktrees/experiment-*` 目录块，卡片显示具体用途和开发组；导出前检查用途行和卡片均在画布内。原 13 张 `c-*` 场景名保留，本类现在条件导出 **15 张**；截图仍只在设置 `STORAGE_CLEANER_SPACEMAP_EVIDENCE` 时生成。新增 DEBUG 分隔探针为 `careStudio.spaceLens.controlSeparator.style`、`.depth`，测量框包括左右留白，因此为 21×16 pt。

实际执行的三条命令与本交接前文“实际验证”代码块完全相同，环境仍为 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`、`CLANG_MODULE_CACHE_PATH=$PWD/.build/codex/clang-module-cache`；完整命令见下述证据目录的 JSON。

| 命令 | exit | 结果 |
| --- | --- | --- |
| `swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox` | 0 | 源码和窗口测试均编译通过；0 错误，6 个修改的 Swift 文件 0 编译警告。日志 `build-1.log`。 |
| 原定锚定过滤的 `swift test --skip-build --disable-swift-testing …` | 0 | 主测试包 **186 项，0 失败、0 跳过**，含侧栏 25 项；过滤保持 `^StorageCleanerMacTests\.`，覆盖全部新增纯测试。日志 `test-1.log`。 |
| `python3 -B script/display_bound_tests.py --check` | 0 | 62 in-process、1 out-of-process、1 exempt。日志 `display-check.log`。 |

证据目录：`/private/tmp/disktree-p3-r3.b9fdvi/`。日志附 `.exit`；`baseline.json` 和 `baseline/` 保存 17 个前轮文件原文及哈希；`implementation.diff`、`source-checks.json`、`verification.json` 记录本轮差异、范围和检查结果；`build-command.json`、`test-command.json` 保存完整 argv/环境。SwiftPM 只读缓存、既有 duplicate rpath 和偏好 sandbox extension 提示仍存在，未扩大权限；纯测试通过不代表跨进程偏好持久化已验证。

沿用当前模型，按 `code-review-and-quality` 局部自查，未委派或调用其他模型。JEV 未调用：未发现可用工具，且没有本轮来源与预算授权。读取 brief 禁止事项前误执行了一次只读 `git status --short`，之后未再进行 Git 检查；无 Git 写操作、安装、启动应用、外发或桌面操作。

主会话下一步：在“虚拟屏 3 · Claude”运行 `SpaceLensSidebarWindowTests` 11 项及 `SpaceMapTreemapWindowTests` 8 项，重点复核两项真实鼠标勾选、单/双行分隔和新增用途行的卡片高度；导出本轮 15 张 `c-*` 截图给用户复核。这里没有窗口通过或新 PNG 已生成的声明；第 4 期修改时间相关事项继续保留。

## 第 4 轮

2026-10-23，完成主会话第 3 轮测试及截图反馈的五项修复。构建、指定锚定纯测试和显示测试登记守卫 **PASS**；本轮窗口交互、几何及新截图 **NOT RUN**，由主会话在测试屏验收。已查看 `evidence-p3/r3/` 中指定的 `c-tabs-760-zh-dark.png`、`c-purpose-hover-1024-zh-dark.png`、`c-worth-1024-en-light.png`。

本轮最终仅修改前三轮已有的 6 个文件，以下路径相对项目根：

| 文件 | 实际修改 |
| --- | --- |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSpaceLens.swift` | 两套图例在同一个顶端对齐的 ZStack 中使用相同列定义，共同保留较高的高度；非当前图例透明、不命中、不参与无障碍、不带 help 或单项探针；外框探针保留。行打开按钮新增仅 DEBUG 的 `careStudio.spaceLens.open.<entry.id>` 探针。 |
| `Sources/StorageCleanerMac/Views/CareStudio/SpaceMapTreemapPainter.swift` | 用实际绘制的 10 pt 等宽数字 Text 测宽，经纯函数 `sizeFits(measuredWidth:availableWidth:)` 判断完整放下才绘制，左右对齐共用此判断。大小缓存键含文字、字号和准确可用宽度，与名字共享 2,000 项上限；动画期间复用缓存、不重新测宽，未缓存的大小等动画结束再显示。悬停用途仅在组含多种用途时追加组名。 |
| `Sources/StorageCleanerMac/Views/CareStudio/SpaceLensWorthALook.swift` | 工作树副标题复用 `SpaceMapPurpose.agentWorkspace.title`，英文正确区分 `1 worktree` / `3 worktrees`；中文保持原写法。 |
| `Tests/StorageCleanerMacTests/SpaceLensSidebarTests.swift` | 新增 6 项纯测试，侧栏合计 31 项：大小刚好放下、少 1 pt、零宽；缓存命中/拒绝及文字、字号、宽度键；动画不测量；共用容量上限；四种双语悬停用途；工作树数量 1/3 的双语文案。原英文副标题断言同步更新。 |
| `Tests/StorageCleanerMacTests/SpaceLensSidebarWindowTests.swift` | 提取通用 `click(probe:…)`，勾选和打开都通过探针中心发送真实鼠标事件，保留失败时的附近 AX 诊断、回调路径及返回目录断言。新增 `testColorModeRoundTripsPreserveEveryTileAndLegendFrameAtAllWideSizesInBothLanguages`：760/1024/1280 宽 × 中英文，各两次类型→用途→类型往返，逐次断言全部 tiles、画布外框及图例外框不变，当前图例探针齐全且在图例内、圆按钮上方。 |
| `docs/2.0.0/collab/handoffs/disktree-p3.md` | 仅追加本节。 |

原失败测试 `testPurposeChangesColorWithoutChangingLayoutAndSurvivesSurfaceChanges` 逐字未改；原 worth 回调、路径和返回分段断言保留。`SpaceMapPurposeClassifier.swift`、`FeatureLightfieldCharts.swift`、`FeatureLightfieldChartGeometry.swift`、`static func bubble(_:)` 与本轮备份一致；配色、分隔线、估算、筛选和原 15 张截图场景保留。`SpaceMapTreemapPainterTests.swift` 最终与原文完全一致，新增大小测试集中在前三轮已新增的侧栏测试文件内。

执行的三条命令和环境与任务书第 5 节及本文“实际验证”代码块一致，测试过滤仍锚定 `^StorageCleanerMacTests\.`，包含全部新增纯测试。窗口类仍登记为 in-process，新方法已编译但未在沙箱运行。

| 命令 | exit | 结果及证据 |
| --- | --- | --- |
| 原定 `swift build … --build-tests --jobs 8 …` | 0 | `build-1.log`、最终 `build-2.log`；构建 0 错误，修改的 5 个 Swift 文件 0 编译警告。第二次构建确认新增测试归入允许的侧栏测试文件后通过。 |
| 原定锚定过滤的 `swift test … --skip-build --disable-swift-testing …` | 0 | `test-1.log`：主测试包 **192 项，0 失败、0 跳过**，包含新增 6 项纯测试。 |
| `python3 -B script/display_bound_tests.py --check` | 0 | `display-check.log`：62 in-process、1 out-of-process、1 exempt。 |

本轮证据目录：`/private/tmp/disktree-p3-r4.96kkoywu/`。`baseline.json`、`baseline/` 保存相关文件原文及哈希；`implementation.diff`、`source-checks.json`、`verification.json` 记录最终差异、原测试/截图/气泡保持情况及验证；命令 JSON 保留完整 argv 和必要环境，各日志附 `.exit`。SwiftPM 缓存只读、既有 duplicate rpath 和偏好 sandbox extension 提示仍存在。开始读取 brief 前误执行了一次只读 Git 状态/日志查询，随后停止 Git 检查；未执行 Git 写操作、安装、应用启动或桌面操作。沿用当前模型及设置，未调用其他 Worker；当前无 JEV 调用入口，未调用或声称其复核。

主会话下一步：在测试屏跑侧栏 **12 项**及原方块图 **8 项**窗口测试，重点检查原两项失败及新增六组几何往返；按原场景导出 15 张截图，复核 760 宽中文暗色大小不再裁字、用途切换地图不动及英文工作树文案。窗口、截图和整个项目尚未验收，第 4 期修改时间相关事项继续保留。

## 第 5 轮（主会话补测试）

2026-10-23 02:34，第 5 轮派给 Codex 后 15 秒退出：服务端返回 429 Too Many Requests（限流），未改动任何文件。按用户规则，不改用其他来源，也不反复重试；本轮只补测试，由主会话直接完成。

主会话在第 4 轮代码上做了 19 条单点变异（只跑 `FileAnalysisSelectionReclaimTests`、`SpaceLensSidebarTests`），14 条被抓到。针对没被抓到的 5 条：

| 变异 | 处理 |
| --- | --- |
| R5：有估算、无完整克隆时仍追加“可能另外释放” | 新增 `testCloneSentenceNeedsPossibleCloneBytesInBothLanguages` |
| F1：子目录借用父目录的筛选结果 | 新增 `testActiveFilterKeepsOnlyTheSameVersionAndDirectory` |
| F3：被取代且未取消的筛选发布结果 | 新增 `testOverlappingFilterRequestsPublishOnlyTheNewest` |
| W1：被取代且未取消的“值得一看”发布结果 | 新增 `testOverlappingWorthRequestsPublishOnlyTheNewestVersion`；为控制两次计算的先后，`SpaceMapTreemapSource` 照 `computeFilter` 增加注入点 `computeWorth`，默认 `SpaceMapTreemapSource.computeWorth` 与原内联代码相同，调用方未改 |
| ST1：估算缓存只比较勾选、不比较数据版本 | 判为可观察行为等价，不另加测试（理由见文首“主会话验收结论”） |

验证：守卫通过；Debug 构建 0 错误、改动文件 0 新增警告；定向 309 项（307 通过、2 项按需跳过），0 失败；重跑变异 R5、F1、F3、W1、W2 均 CAUGHT，ST1 SURVIVED（等价）。窗口变异 3/3 CAUGHT：图例只给当前模式留高度（往返和用途切换两项失败）、“/”不再聚焦筛选（斜杠测试失败）、估算行只在勾选后出现（勾选前后位置测试失败）。随后在测试屏跑全部 in-process 窗口类：647 项，0 失败。
