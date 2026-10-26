# disktree-p2：空间透镜方块视图交接

代码及本轮非窗口验证 PASS：最终构建 exit 0，锚定主测试包的 121 项测试全部通过，新增及本轮改动文件没有编译警告。窗口验证与截图 NOT RUN，由主会话在测试显示器运行；本交接不代表整项目验收完成。

工作目录：`/Users/developer/Developer/sc-worktrees/disktree-p2`，2026-10-22。这是带有大量既有差异的镜像；本轮仅改任务书列出的 15 个文件，没有 commit、push、安装、联网、发布或对外发送。第 1 期算法、CMM 的窗口审阅测试、DECISIONS、BOARD、第三方声明均未修改。

## 文件

新增源码均小于 600 行：

| 文件 | 作用 |
| --- | --- |
| `Features/SpaceMap/Treemap/SpaceMapTreemapViewState.swift` | Sendable 的视口、缩放目标/上限、设备方向、防误触、过渡、选中、方向键和顶层悬停映射，以及 `SpaceMapViewStyle`。 |
| `Features/SpaceMap/Treemap/SpaceMapTreemapSource.swift` | 根层余量、索引快照子项、布局键、后台计算、8 份 LRU 布局和当前分析的分类缓存。 |
| `Views/CareStudio/SpaceMapTreemapPainter.swift` | 颜色/深浅、斜线/警示、描边、标签、悬停卡和无障碍摘要的决定，以及可离屏渲染的 Canvas 层。 |
| `Views/CareStudio/SpaceMapTreemapView.swift` | 页面数据接入、静态 Canvas / 过渡 Timeline、待开始的导航过渡、悬停卡和既有动作闭包。 |
| `Views/CareStudio/SpaceMapTreemapInputBridge.swift` | AppKit 指针、滚轮、捏合、点击、侧键、键盘、上下文菜单和第一响应者。 |

以上路径相对 `Sources/StorageCleanerMac/`。视口/方向/过渡逻辑参考 disktree 的 MIT 实现，并在状态文件注明归属及第 1 期完整许可的位置；未复制界面、配色或个人目录名。

| 其余新增文件 | 作用 |
| --- | --- |
| `Tests/StorageCleanerMacTests/SpaceMapTreemapViewStateTests.swift` | 18 项纯状态测试。 |
| `Tests/StorageCleanerMacTests/SpaceMapTreemapSourceTests.swift` | 7 项内存数据源、缓存、取消、分类及独立偏好域测试。 |
| `Tests/StorageCleanerMacTests/SpaceMapTreemapPainterTests.swift` | 17 项绘制决定、双语摘要、源码契约与离屏性能测试。 |
| `Tests/StorageCleanerMacTests/SpaceMapTreemapWindowTests.swift` | 5 项 display-bound 测试，含小宿主、几何、输入、全宽及可选截图。 |
| `docs/2.0.0/collab/handoffs/disktree-p2.md` | 本交接。 |

| 修改文件 | 实际改动 |
| --- | --- |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioSpaceLens.swift` | 绑定样式、右栏顶行、层数/全宽和方块承载，保留气泡函数及既有探针。 |
| `Sources/StorageCleanerMac/Views/FilesLightfield/FileAnalysisLightfieldView.swift` | 传入样式绑定、数据版本、浏览失败状态和前进闭包。 |
| `Sources/StorageCleanerMac/Features/LargeFiles/Stores/LargeFilesStore.swift` | 用注入的 defaults 保存 `storage-map.view-style`，并在分析替换时增加数据版本。 |
| `Sources/StorageCleanerMac/Debug/FeatureLightfieldFileResultFixture.swift` | 可选初始样式默认 `.bubbles`；用标准索引快照补齐深层路径。 |
| `script/display-bound-tests.txt` | 按字母顺序登记 `SpaceMapTreemapWindowTests`。 |

## 页面与绘制

- 默认气泡，目录栏记住“气泡｜方块”；文件类型和最大文件仍用气泡，保留 34 pt 空顶行。窄于 680 pt 不显示右栏。
- 方块层数 1–6、默认 3，只放页面状态；`[` / `]` 可调。全宽隐藏列表，离开方块、切换栏目或变窄都会取消。
- 新探针：`careStudio.spaceLens.mapStyle`、`careStudio.spaceLens.blocks`。原 `list`、`bubbles`、`path`、`more`、`status`、`row.*` 保留；`static func bubble(_:)` 与保存的基线逐字相同。
- 根层使用 `mapLayoutEntries(..., limit: .max)`，子项只来自 `DiskScanner(excludedPaths: []).storageMapSnapshot(at:using:)`。父目录保护、包和云端终止规则继续由第 1 期算法决定。
- 类型色与现有列表/气泡同源；按深度每档 7%、最多 3 档调整。边缘按 displayScale 取整，余量/合并块有不透明中性底，避免透出父色。目录可回收斜线在分类完成后出现，估算有警示点。
- 所有填充完成后再画描边，顺序为已勾选 → 悬停 → 选中；最多绘制面积最大的 150 个可见标签，分别裁剪。画布只暴露一个无障碍元素，块不单独暴露。
- 勾选一律走 `onToggle`，进入走 `onOpen`，返回/前进复用页面回调。包和不能进入的内容项沿用列表的勾选入口，由原选择策略决定是否允许；没有增加清理入口或 D46 以外的移动流程。

## 数据版本和后台计算

依据 `LargeFilesStore.swift`：`finishTrash`（1150 行）取得分析、从索引移出已移动项，再调用 `installEditedStorageAnalysis`；`putBackRestoredTrashItems`（1181 行）在回执/身份核对后恢复索引，也调用同一安装方法。`takeStorageAnalysisForEditing`（1206 行）先把 `storageAnalysis` 设为 nil；`installEditedStorageAnalysis`（1214 行）重建根快照、重新赋值分析，并重建 navigation、forward 和快照缓存。

因此在 `storageAnalysis` 的 didSet（107 行）递增 `storageMapDataVersion`，移出、恢复和新分析都会改变版本；一次编辑经过 nil 和重新安装会递增两次。版本不依赖可能保持不变的扫描时间、磁盘容量或大小总和。页面显式把版本传给布局及分类缓存。

布局键包含路径、取整到 1 pt 的宽高、层数和数据版本。布局由 `Task.detached(priority: .userInitiated)` 计算，输入为 Sendable 的快照/索引；最近 8 份结果保留在页面的 source 中。缩放/平移和悬停不进入键。分类在独立后台任务计算，按分析版本复用；家目录扫描用分析根作为分类 homePath，其余范围用当前 home。取消会传给后台任务及 classifier 的 `isCancelled`，返回结果后再次检查取消才入缓存/发布。

任务随 key 变化或视图消失取消。分类版本未匹配前不取旧分类绘制斜线。新布局未完成时保留上一幅，首幅未完成时仅显示面板底色，不出现转圈。

## 手势与过渡

设备方向先用 `isDirectionInvertedFromDevice` 换算；精确竖向增量除以 24，普通轮取 deltaY，限制 ±3，再用 `pow(1.15, lines)`。捏合使用 `1 + magnification`。指针下最深且可进入的有内容目录，名字带以下部分的 fitScale 决定上限，最多 5；无目标时为 1。指针点固定、平移限制在内容内。上限后的下一次放大进入，1 倍时缩小返回。

防误触是纯值状态：非惯性的 began 清除 consumed，一次手势最多消费一个导航；惯性事件只缩放；无 phase 的普通轮两次导航间至少 300 ms。该 gate 保留到异步导航之后，避免新一层继续接收同手势时再次进入。忙碌仅阻断导航与勾选，缩放、悬停和选中仍可用。

进入保存目标路径和旧画面中的目录 body 矩形；返回保存离开路径及画布矩形。等 navigation 更新且目标布局完成后，才建立从 source 到 destination 的矩形映射，按缓出三次方插值。时长为 `130 + 45 × clamp(log2(比例), 0, 4)` ms，范围 130–310 ms。返回目标块缺失则直接切换；返回选中刚离开的目录，进入清空选中。路径偏离目标或浏览失败会丢弃待开始记录。减少动态效果或 `featureDisablesLayoutAnimations` 时直接切换。只有 transition 存在时使用 `TimelineView(.animation)`，完成后回到静态 Canvas。

## 验证证据

证据目录：`/private/tmp/disktree-p2-evidence/`，保留 5 份原始文件、副本差异、构建/测试日志及 `.exit`，以及 `final-review.json`。最终新增源码和修改源码 0 警告，构建 0 错误。SwiftPM 无法写用户缓存/manifest 数据库的诊断属于沙箱限制，没有请求放宽权限。

实际命令（cwd 为本工作目录；所有构建同一命令，测试过滤均锚定主包）：

```bash
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  CLANG_MODULE_CACHE_PATH=/Users/developer/Developer/sc-worktrees/disktree-p2/.build/codex/clang-module-cache \
  swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox

env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  CLANG_MODULE_CACHE_PATH=/Users/developer/Developer/sc-worktrees/disktree-p2/.build/codex/clang-module-cache \
  swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing \
  --filter '^StorageCleanerMacTests\.(SpaceMapTreemap(ViewState|Source|Painter)Tests|SpaceLensBubbleIconTests|SpaceMap(TreemapLayout|TreemapFilter|PurposeClassifier|Insights)Tests)'

python3 -B script/display_bound_tests.py --check
```

| 运行 | exit | 结果 |
| --- | --- | --- |
| `build-1.log` | 1 | Canvas 的 Text 修饰器返回类型不匹配；已改为单行绘制并裁剪。 |
| `build-2.log` | 1 | lazy 标签闭包需要 escaping 参数；已修正。 |
| `build-3.log` | 1 | 窗口测试递归闭包缺少显式 self；已修正。 |
| `build-4.log` | 1 | 截图准备闭包缺少 MainActor 隔离；已修正。 |
| `build-5.log` | 0 | 47.60 秒，生产及窗口测试均编译通过。 |
| `test-1.log` | 0 | 120 项，0 失败。 |
| `build-6.log` | 0 | 48.07 秒，补顶层余量方向键及平移悬停边界。 |
| `build-7.log` | 0 | 最终构建，37.15 秒；截图等待匹配尺寸的布局。 |
| `test-2.log` | 0 | 最终 121 项，0 失败、0 跳过，主包 0.459 秒。 |
| `display_bound_tests.py --check`（3 次） | 0 | 61 in-process、1 out-of-process、1 exempt。 |

最终测试数量：新增状态 18、数据源 7、Painter 17，共 **42**；既有气泡图标 2、布局 19、筛选 10、分类 39、insights 9，共 79；合计 **121**。新增窗口类另有 **5** 项，已编译，未运行。

性能实测：`ImageRenderer` 绘制不含输入桥接的 3,000 块、1200×800、10 次平均，首次 **5.326 ms**，最终 **5.171 ms**；100 ms 上限断言通过。新 5 源码的禁止文件修改/进程入口文本契约通过。偏好测试使用 `TestPreferenceDomain`：store 重建读回 blocks、无效值回落 bubbles 均通过；测试运行中系统打印了针对该临时偏好域的 `sandbox_extension_issue_file ... Operation not permitted`，没有造成断言失败，未绕过沙箱。

## 主会话待验收

- 按任务书仅主会话运行 `script/run_display_bound_tests.sh` 中的新窗口类及既有 `CareStudioWindowReviewTests`。本沙箱没有运行任何窗口测试，也没有生成 PNG。
- 设置 `STORAGE_CLEANER_SPACEMAP_EVIDENCE` 后，截图测试准备 **19 张**：3 宽度 × 双语 × 双外观 12 张、全宽 1、悬停 2、勾选与选中 1、默认气泡对照 1、富样例 2；未设置时该截图测试 XCTSkip。文件名为 `b-<场景>-<宽>-<zh|en>-<dark|light>.png`。
- 富样例是内存索引，含 node_modules/package.json、Library/Caches、.build/Package.swift、估算和保护目录、132 个小文件及未测余量，供复核斜线、警示点、尾部合并和余量。
- 全量、FileAnalysisTrash*/StorageMap* 扩展回归、Release、完整 verify、并发检查及变异抽查均 NOT RUN，按本轮分工由主会话执行；不能以本轮 121 项代替这些门禁。
- 新增视图的窗口几何、第一响应者和真实事件派发、完整双语外观仍待显示器验收。本轮无构建/纯测试 BLOCKED。
- 用途色条、按用途着色、筛选和时间模式未接入，也未留空实现，留第 3、4 期。第三方声明、DECISIONS、BOARD 由主会话补写。
- 仅沿用当前模型和推理设置；按 `code-review-and-quality` 做了本地自查，没有递归委派。JEV NOT RUN：交接未给出已确认的调用来源与本次预算，未调用其他模型或收费来源；仍需主会话独立复核。

## 第 2 轮（主会话复核修复，2026-10-22）

非窗口验证 PASS：最终构建 exit 0；137 项定向测试、0 失败、0 跳过；改动源码和测试文件 0 新增警告；显示测试登记检查 exit 0。本轮修改原授权 15 个文件中的 10 个（9 个源码/测试文件及本交接），保留其余第 1 轮实现和已有差异。窗口测试与截图 NOT RUN，仍由主会话在副屏验收。

### 修复与新增测试

新增 **16 项**：下列前五组为 `SpaceMapTreemapPainterTests` 的 14 项，第六组为新增类 `SpaceMapTreemapDataVersionTests` 的 2 项；类定义放在已授权的 `SpaceMapTreemapSourceTests.swift` 中。

1. **P1-1**：页面接收默认空的 `checkedPaths`；生产、演示及窗口宿主分别传路径集合。只有自身路径直接勾选的内容块描边；布局安装或路径集合变化时缓存勾选 id，Timeline 帧与指针移动复用它。选择策略只查询当前悬停内容项及菜单标题。新增 3 项：`testCheckedIDsOnlyIncludeTheItemsOwnCheckedPath`、`testDrawingDecisionsDoNotQuerySelectionForThreeThousandTiles`、`testHoverOnlyQueriesTheCurrentContentTileSelection`。
2. **P2-1**：绘制层实现 `Equatable` 并使用 `.equatable()`，比较布局键、分类版本、视口、过渡、时间、勾选/悬停/选中 id、外观与 displayScale；不比较 tile 数组。静态时间固定为 0，悬停卡继续随指针定位。新增 2 项：`testDrawingEqualityForIdenticalInputs`、`testDrawingEqualityChangesWithEveryPaintInput`。
3. **P2-2**：悬停展示统一从 `snapshot.measuredBytes` 计算百分比。新增 1 项：`testHoverShareUsesMeasuredBytesJustLikeTheList`，用 measured/reference 不同的快照验证与列表一致的 50.0%。
4. **P2-3**：移除估算高度及原因的两行限制；`onGeometryChange` 测量卡片，宽不超过 220、高不超过画布减 8，按实际尺寸保留 (14,14) 偏移并夹在画布内；靠边时尝试避开块的左上角。新增 2 项：`testHoverFrameUsesMeasuredHeightAndKeepsThePointerOffset`、`testClampedHoverCardAvoidsTheTileNameOrigin`。新增调试探针 `careStudio.spaceLens.hoverCard`、`careStudio.spaceLens.hoverCard.line.<序号>`，截图测试断言完整原因位于卡片内。
5. **P2-4**：名称由 `GraphicsContext.resolve(Text).measure(in:)` 量宽，按字符二分截断并追加省略号；不足以放下完整字符时留空。外层视图保留上限 2,000 条的缓存，键含文字、字号、字重、向下取整的 1 pt 宽度，满时清空；过渡只用已有缓存，未命中保持原裁剪，大小数字沿用原实现。新增 6 项：`testNameTruncationLeavesFittingTextIntact`、`testNameTruncationFindsTheLongestFittingPrefixAndEllipsis`、`testNameTruncationReturnsEmptyWhenNoWholeCharacterFits`、`testNameCacheReusesPointWidthAndIncludesFontAndWeight`、`testTransitionUsesCachedNamesOrClipsWithoutMeasuring`、`testNameCacheClearsWhenItsLimitIsReached`。
6. **P2-5**：新增 `testReplacingAnalysisIncrementsTheVersionEveryTime`、`testRecordedMoveAndIdentityMatchedRestoreChangeTheVersion`。两次替换均断言版本 +1；内存录制移动经过 store 的真实完成处理，随后身份匹配恢复经过 `operationHistoryDidRestore`，分别断言版本改变，索引和快照恢复原值。仅增加 DEBUG 的 `finishTrashForTesting` 薄入口，复用 `finishTrash`，未改版本递增逻辑。
7. **P2-6**：窗口 `press` 按仓库已验证方式遍历三种 AX 子节点及 NSView.subviews，visited 去重，只匹配读作目标文字的按钮，再调用真实 AX press；全宽操作没有绕过按钮。原窗口 5 项保留并编译通过，新增测试方法数 0。截图预期 **23 张**：原 19 张加 `rich-hover-reclaim` / `rich-hover-blocked` 各中文暗色、英文亮色，共 4 张；分别悬停 node_modules 与受保护目录，后者使用带锁的完整长原因。未在本沙箱生成 PNG，也未将两项原失败窗口测试标记为通过。

### D46 的验证边界

`FileAnalysisTrashStoreTests` 的 `TrashFixture` 会在家目录创建文件、移动文件及持久化回执（`FileAnalysisTrashTests.swift:607`、`:662`），不能用于本轮禁止真实文件系统读写的验收。完整 `requestTrashReview` / `confirmTrash` 路径还会直接调用 `lstat`、资源值读取（`FileAnalysisTrashService.swift:349`），执行服务固定写 journal（同文件 `:527`）；允许修改的文件不包含这些服务，不能在此注入内存替代。

因此复用该组测试的环境注入模式，使用 `SpaceMapMemoryIndex`、内存 metadata/移动/回执检查点，实际执行 `RecordedTrashOperation.run` 的身份校验及录制逻辑，再进入 `finishTrash` → `takeStorageAnalysisForEditing` → `installEditedStorageAnalysis`；恢复使用真实 `operationHistoryDidRestore` → `putBackRestoredTrashItems` 和身份核验。覆盖了本次版本失效的生产编辑路径，但未运行完整 D46 审阅、持久化或 `CleanupRecoveryService.restore`。所有模拟文件操作仅修改字典，真实文件未读写；偏好使用 `TestPreferenceDomain`。

### 实际命令、结果与证据

cwd：`/Users/developer/Developer/sc-worktrees/disktree-p2`。每次 build/test 均使用以下环境与命令；两次 test 的过滤相同，已包含新测试类，未运行全量或窗口测试：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing \
  --filter '^StorageCleanerMacTests\.(SpaceMapTreemap(ViewState|Source|Painter|DataVersion)Tests|SpaceLensBubbleIconTests|SpaceMap(TreemapLayout|TreemapFilter|PurposeClassifier|Insights)Tests)'
python3 -B script/display_bound_tests.py --check
```

| 记录 | exit | 实际结果 |
| --- | --- | --- |
| `build-1` | 1 | Swift 6 相等运算隔离及 CGFloat.infinity 类型歧义；已修正。 |
| `display-check` | 0 | 61 in-process、1 out-of-process、1 exempt。 |
| `build-2` | 0 | 构建通过，110.87 秒。 |
| `build-3` | 0 | 外层保留名称缓存后的构建通过，197.15 秒。 |
| `test-1` | 1 | 137 项；恢复测试的两条断言暴露内存夹具缺少类型统计、根标题不一致。补齐为真实分析的数据形态，保留原断言。 |
| `build-4` | 0 | 最终构建通过，11.18 秒，改动文件 0 新增警告。 |
| `test-2` | 0 | 最终 137 项，0 失败、0 跳过；主包 0.457 秒。 |

最终数量：ViewState 18、Source 7、Painter 31、DataVersion 2、既有算法和气泡 79，共 **137**。3,000 块、1200×800、10 次离屏绘制平均 **5.066 ms**，100 ms 预算通过。通过的构建只有既有警告及 SwiftPM 用户缓存/只读 manifest 数据库诊断，没有绕过沙箱。

证据目录：`/private/tmp/disktree-p2-round2.vYsAgP/`。每次运行保留 `.command`、`.log`、`.exit`；另有 `before/`、`round2.diff`、`new-tests.json` 和最终范围/警告核对 `review.json`。本轮按 `debugging-and-error-recovery` 定位修复，未递归委派；JEV NOT RUN，未提供已确认来源及本次预算，未发起外部模型调用。剩余验收为主会话的副屏窗口测试与 23 张截图，完整 D46 文件操作回归仍由主会话按其授权执行。

## 第 3 轮（截图复核修复，2026-10-22）

非窗口验证 **PASS**：构建 exit 0，143 项定向测试、0 失败、0 跳过，改动文件 0 新增警告，显示测试登记检查 exit 0。本轮只改原授权 15 个文件中的 5 个：`SpaceMapTreemapPainter.swift`、`SpaceMapTreemapView.swift`、`SpaceMapTreemapPainterTests.swift`、`SpaceMapTreemapWindowTests.swift` 及本交接；路径同上文清单。已核对第 2 轮引用的 6 张截图，保留主会话加在 `Host` 上的 `.environment(\.accessibilityEnabled, true)`、既有测试断言和其他实现。

### 逐项改动与新测试

共新增 **9 项测试**：Painter 6 项已通过，窗口 3 项仅编译通过。

1. **P1 高度**：`fixedSize` 后立即用 `onGeometryChange` 测自然尺寸，再使用固定高度（自然高度与画布高度减 8 的较小值），保留裁剪和定位规则。新增 detail、title 两个行探针，与既有 `hoverCard.line.*` 一起覆盖全部内容行。新增窗口测试 `testHoverCardsFitTheirNaturalContentInBothAppearances`：文件、可回收目录、受保护目录 × 中文暗色/英文亮色，逐一断言高度等于各行高度、行间距及 24 pt 上下内边距之和（容差 2 pt），且小于画布高度的 75%，完整行及卡片都位于边界内。
2. **P1 背景**：移除 `colorInvert`；按外观以纯黑/纯白作不透明底，再叠 `CareStudioInk.pillFill`。新增窗口测试 `testDarkHoverCacheDisplayHasADarkBackgroundAndVisibleText`、`testLightHoverCacheDisplayHasALightBackgroundAndVisibleText`：实际调用 `cacheDisplay`，在卡片中心附近的行间空隙采 3 点，分别断言亮度 < 0.35 / > 0.8；扫描标题区域，要求文字与背景亮度差 > 0.4，避免把描边误当文字。这两项不依赖设置截图目录。
3. **P1 单复数**：英文数量 1 显示 `1 item`，0 和其他数量显示 `N items`，中文仍为 `N 项`。新增纯测试 `testDirectoryHoverCountUsesEnglishSingularAndPluralAndKeepsChinese`，覆盖中英各 0、1、2；同步修正原悬停内容测试的英文期望。
4. **P2-1 勾选徽标**：仅自身 id 已勾选的内容块画直径 14 pt 的模块强调色圆形、白色粗体 SF Symbol `checkmark`，右下内缩 4 pt，宽或高不足 22 pt 不画；描边为暗色黑/亮色白的 35% 不透明度、1 pt，位于圆内。收集后在最终一遍绘制，保留原三种描边规则和顺序。新增纯测试 `testCheckedBadgeOnlyMarksTheContentItemsOwnCheckedPath`、`testCheckedBadgeRequiresTwentyTwoPointsOnBothSidesAndStaysInset`、`testCheckedBadgeIsPaintedAboveDescendants`；最后一项实际离屏渲染，核对父块徽标未被后画的子块遮住。
5. **P2-2 中性块**：合并尾项与未测余量统一使用不透明 sRGB 灰色：暗色 (58,58,66)、亮色 (232,232,238)，不再叠白色 tile token。新增纯测试 `testNeutralTilesRenderAsOpaqueSoftGrayInBothAppearances`，在类型色父块上覆盖两种中性块，逐点检查精确 RGB（容差 0.01）及 alpha 1；原标签深浅色保持清晰。
6. **P2-3 警示点**：右上角改为 7 pt，复用对应外观的 `FeatureLightfieldPalette.warningColor`，描边同勾选徽标；装不下完整圆点的块不画。新增纯测试 `testWarningDotRendersSevenPointsWithTheAppearanceWarningColor`，核对位置、直径、暗亮两种实际渲染颜色及描边颜色规则。

取色诊断发现 `NSBitmapImageRep.colorAt` 会把原始通道标为 calibrated RGB，即使位图本身是 sRGB；直接 `usingColorSpace(.sRGB)` 会使 (58,58,66) 偏成约 (75,75,84)。纯测试和窗口测试取样都先恢复位图原有 ICC 配置，再转换到 sRGB，保留全部阈值。独立离屏探针及原始读数见 `color-probe.swift`、`color-probe.log`。

### 命令、exit code 与证据

cwd 仍为本工作目录。实际执行前三条验证命令，过滤锚定主测试包，并包含第 2 轮的 DataVersion 类及本轮全部新增非窗口测试：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
swift build --scratch-path .build/codex --build-tests --jobs 8 --disable-sandbox -Xswiftc -disable-sandbox
swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing \
  --filter '^StorageCleanerMacTests\.(SpaceMapTreemap(ViewState|Source|Painter|DataVersion)Tests|SpaceLensBubbleIconTests|SpaceMap(TreemapLayout|TreemapFilter|PurposeClassifier|Insights)Tests)'
python3 -B script/display_bound_tests.py --check
```

| 记录 | exit | 结果 |
| --- | --- | --- |
| `build-1` | 0 | 生产代码、全部纯测试及窗口测试编译通过，34.84 秒。 |
| `display-check` | 0 | 61 in-process、1 out-of-process、1 exempt，窗口类仍在登记中。 |
| `test-1` | 1 | 143 项，3 个新增取色测试产生 18 条失败断言；定位为上述颜色空间误标，未改产品颜色或放宽阈值。 |
| `build-2` | 0 | 修正取色辅助函数后通过，9.85 秒；改动文件 0 新增警告。 |
| `test-2` | 0 | 最终 143 项、0 失败、0 跳过，主包 0.550 秒；新增 6 项纯测试全部实际执行。 |

最终数量：ViewState 18、Source 7、Painter 37、DataVersion 2、既有算法和气泡 79，共 **143**。3,000 块、1200×800、10 次离屏绘制平均 **5.035 ms**，100 ms 预算通过。构建仅有既存 SwiftPM 用户缓存只读诊断及链接器 duplicate rpath 警告，改动源码和测试均无新增编译警告。

证据目录：`/private/tmp/disktree-p2-round3.b7p3b8vt/`。验证运行保留 `.command`、`.log`、`.exit`，另有 15 个文件的 `before/`、`before.json`、`new-tests.json`、本轮差异 `round3.diff`、最终范围及警告核对 `review.json`。

**NOT RUN，交主会话**：窗口类现有 **8 项**（原 5 + 新 3）及原 23 张截图，均待在副屏运行；本沙箱未创建窗口、未生成 PNG。第 2 轮主会话的 250 项和 5 项窗口测试通过记录属于本轮前的基线，不作为本轮通过证据。全量、Release、严格并发及完整 D46 文件操作回归继续由主会话按原分工处理。本轮沿用当前模型与推理设置，按 `debugging-and-error-recovery` 自查；JEV **NOT RUN**：无可核实调用来源及本次预算，未递归委派或调用其他模型。未安装、提交、推送或发布。

## 主会话补丁（第 3 轮后，2026-10-22）

主会话在验收中直接改了两处，都只是恢复或补齐，不改功能逻辑：

1. `Tests/StorageCleanerMacTests/SpaceMapTreemapWindowTests.swift`：测试宿主 `Host` 加 `.environment(\.accessibilityEnabled, true)`。没有辅助功能客户端时 SwiftUI 不建无障碍树，`press` 找不到“全宽显示”按钮，第 1、2 轮的两项窗口测试因此失败。`V0LayoutHost` 用的是同样的打开方式。
2. `Sources/StorageCleanerMac/Debug/FeatureLightfieldFileResultFixture.swift`：`childSnapshot(path:)` 恢复为原来那版只读内存索引的实现。第 1 轮改成构造 `DiskScanner`，违反了 `FeatureLightfieldFilesPresentationTests.testProductionRoutingRetainsExistingSafetyCallbacksAndInertFixturesHaveNoProviders` 的惰性夹具契约（夹具里不得出现 `DiskScanner(` 等入口），全量测试的第一段因此有 1 项失败。深层进入补齐中间层的 `openDirectory` 保留，它只用静态的 `DiskScanner.storageMapParentPath`。影响：演示模式里点进子目录后，子层的颜色和能否放大进入退回原演示数据的样子；正式页面、窗口测试和截图都走生产快照，不受影响。

### 主会话验收结果（最终树）

- 守卫（display-bound 清单、私有 API、删除与进程清单）PASS；Debug、严格并发、Release 构建都没有新增警告，改动文件 0 警告。
- 三段式全量（D106 补充 2）：Debug 主测试包 5,641 项 0 失败（27 项按环境变量跳过）、CombinedStatusIconTests 285 项 0 失败、Swift Testing 135 项通过；Release 主测试包 5,386 项 0 失败。所有日志都没有访问通讯录。
- 副屏窗口测试（`script/run_display_bound_tests.sh`，“虚拟屏 2 · Claude”）：`SpaceMapTreemapWindowTests` 8/8 通过，23 张截图逐张核对；默认气泡页相关的 7 个类 43 项 0 失败。
- 单点变异：29 处抓到 28 处（报告 `~/Developer/.sc-build/disktree-p1/logs/p2-mutations.txt`）。存活的 V12（去掉 `highlightedID(for:roots:)` 里的 `entry.role == .content`）是等价变异：后面查找时只认内容条目，余量块路径为空，结果不变，不是测试缺口。

### 全部窗口类回归（10-22 重启后，Mi Monitor）

- 环境：17:45 重启后“虚拟屏 2 · Claude”（10-20 用 `~/Developer/.sc-build/virtual-display/vd` 开的 2560×1600、1 倍）没了，非主屏只剩实体的 Mi Monitor（1920×1080 点、2 倍）。窗口内容区被系统压在 1920×1018 点以内。
- D174 开发线：全部 in-process 类 634 项，44 项失败（42 项 unexpected），失败用例 43 个（清单 `~/Developer/.sc-build/disktree-p1/logs/p2-all-display-failures.txt`）。
- 基线对照：不带 D174 的 2.0.1 树 `6b6f65d4`（含 CMM 3Q），在同一显示器上跑这 14 个类，211 项 44 失败，失败用例同样是这 43 个（`base-mi-display-failures.txt`），两份清单逐项一致。
- 原因（集成会话只读分析日志后确认）：42 项是测试请求的窗口超过 1920 宽或 1018 高，被系统压小，布局因此不稳定；1 项是 `MenuBarPanelSessionTests` 用了用户真实的鼠标位置。都是环境问题，与 D174 无关。
- 结论：按用户决定，窗口验收回到恢复后的“虚拟屏 2 · Claude”，Mi Monitor 上的结果不算数。集成会话合并后会在虚拟屏上跑窗口全量（预计 635 项，含 `SpaceMapTreemapWindowTests` 8 项）。

## 交给集成会话：DECISIONS D174（合并时请写进 `DECISIONS.md` 最上面）

按集成会话 10-22 的安排，DECISIONS 不放进补丁，由集成会话合并时写入。本期没有改动任何已有测试的期望值，所以没有“D174 + 旧值”这一项。窗口基线多 8 项（新增 `SpaceMapTreemapWindowTests`）。

节标题：

```
## 2026-10-22 晚（2.0.1：空间地图方块图第 2 期 D174；用户 10-22 原话：“开始第 2 期：先和 CleanMyMac 改版会话排好改空间透镜页的时间，以 2.0.1 最新树为基线建开发线，照以往做法派 Codex 写、你验收；截图先给我看，我同意后再安装。”看过截图后：“截图看过了，同意。等全部窗口测试回归通过后，把第 2 期交给集成会话合并、跑门禁、装测试版，合入后通知 CMM 会话。”）
```

正文一段：

```
排期：CMM 会话 10-22 承诺第 2 期合入前不改 `CareStudioSpaceLens.swift`、`FeatureLightfieldCharts.swift`、`FeatureLightfieldChartGeometry.swift`，合入后通知它。实现：Codex（gpt-6.1-sol）三轮，主会话复核，并直接补了 2 处（窗口测试宿主打开 SwiftUI 无障碍树；演示夹具 `childSnapshot` 恢复为只读内存索引，满足惰性夹具契约）。验收（合入前，开发线）：Debug 三段式全量 5,641 个／跳过 27／0 失败，Release 5,386 个／跳过 26／0 失败，严格并发、守卫通过，改动文件 0 警告，没有访问通讯录；副屏窗口 `SpaceMapTreemapWindowTests` 8/8，默认气泡页相关 7 类 43/0，全部 in-process 窗口类在 10-22 重启后的 Mi Monitor 上 634 项 44 失败，与不带 D174 的基线逐项一致（43 个用例，环境原因：窗口被压在 1920×1018 点内 42 项、真实鼠标位置 1 项），按用户决定窗口验收回到恢复后的“虚拟屏 2 · Claude”，由集成会话合并后一并跑窗口全量；单点变异 28/29（1 处等价）；JEV 两次 escalate（safe 0.26、0.22），按人工复核处理；用户看过 23 张截图后同意。
```

表格一行：

```
| D174 | D170 第 2 期：空间透镜页右栏加“气泡｜方块”切换（只在“目录”栏出现；“文件类型”“最大的文件”两栏仍是气泡），默认气泡，选择存在 `LargeFilesStore` 注入的偏好域（键 `storage-map.view-style`，不用 `.standard`）。方块图用第 1 期的 squarified 嵌套布局，从当前层画 1–6 层（默认 3，`[` `]` 或加减钮），可一键全宽暂时收起列表；颜色沿用文件类型，层越深越亮（暗色）或越暗（亮色）；可回收目录叠斜线（只表示可再生、可重装或可重建，能否移动仍按 D46、D54）；估算项右上角橙色警示点；已勾选块右下角勾选徽标；“+N 项”和未测余量用中性灰；最多 150 个标签，放不下以“…”结尾。交互：悬停卡（大小、与列表一致的占比、项目数、类型、可回收原因、保护原因带锁），同时联动左栏高亮；单击选中，双击或回车进入目录（文件则勾选），空格勾选，Esc／Delete 先复位缩放再返回，⌘[ ⌘] 与鼠标侧键后退前进，方向键在同级间移动；滚轮或捏合放大，上限是指针下最深目录正好填满画布（最多 5 倍），再放大即进入，1 倍时缩小即返回；一次手势最多进入或返回一次，惯性不进入，无 phase 的滚轮两次至少隔 300 ms；Shift 滚动平移；进入和返回有 130–310 ms 缓出过渡，“减少动态效果”时直接切换；右键菜单：快速查看、在访达中显示、复制路径、勾选。旁白只读一句摘要，逐项浏览用左栏列表。布局与分类在后台计算并缓存，数据版本随分析替换（含 D46 移出与恢复）变化。勾选、审阅、移到废纸篓仍只走 D46，不加删除路径。 | — | 新文件 `Features/SpaceMap/Treemap/SpaceMapTreemapViewState.swift`、`SpaceMapTreemapSource.swift`，`Views/CareStudio/SpaceMapTreemapPainter.swift`、`SpaceMapTreemapView.swift`、`SpaceMapTreemapInputBridge.swift`；测试 `SpaceMapTreemapViewStateTests`、`SpaceMapTreemapSourceTests`（含 `SpaceMapTreemapDataVersionTests`）、`SpaceMapTreemapPainterTests`、display-bound 的 `SpaceMapTreemapWindowTests`；改 `CareStudioSpaceLens.swift`、`FileAnalysisLightfieldView.swift`、`LargeFilesStore.swift`、`Debug/FeatureLightfieldFileResultFixture.swift`、`script/display-bound-tests.txt`；BOARD F 行、`THIRD_PARTY_NOTICES.md` disktree 一节补一段；交接 `handoffs/disktree-p2.md` |
```
