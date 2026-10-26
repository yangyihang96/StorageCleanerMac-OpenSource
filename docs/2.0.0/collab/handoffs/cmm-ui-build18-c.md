# 交接：第 18 次 C（D221 补：杂乱结果页加“大型和旧文件”卡片）

- 会话：cmm-ui（CleanMyMac 界面逆向，D154 车道）
- 基线：1efd21fa（第 18 次 A、B 合入后的树）
- 补丁：`cmm-ui-第18次C-D221补.patch`（sha256 和结果树随交付消息给出，本文件在补丁里，不含自己的哈希）
- 本交接在仓库里的位置：`docs/2.0.0/collab/handoffs/cmm-ui-build18-c.md`
- 未提交、未安装；没有移动、删除任何真实文件。

## 一、改了什么

- 杂乱结果页加一张“大型和旧文件”卡片，放在“相似照片”之后、“聊天文件”之前（CleanMyMac 的杂乱卡片顺序是重复、相似图片、大型和旧文件、下载；聊天文件是我们自己的，排最后）。有没有重复文件都显示。
- 卡片上的数和大小与管理器这一类同口径，都取 `LargeOldFilesStore.rows`：只算文件不算文件夹，去掉忽略列表里“大型和旧文件”和“其他”类别挡住的。
  - 有清单、有文件：大字是总大小，下面写“N 个大型文件，可按打开时间筛选”（小卡片里一行放得下）；大卡片时另有一行“默认一个都不选，移走前逐个审阅。”
  - 有清单、没文件：写“大型文件清单里没有要整理的文件”。
  - 还没有清单：不写大小，写“体积较大、很久没打开的文件”和“点“查看”后可以扫描大型文件，扫描只读取。”
- 卡片只有“查看”，没有勾选框，也没有一键执行的按钮。
- 点“查看”直接进杂乱管理器的“大型和旧文件”一类。
  - 管理器开哪一类，记在 `SystemUtilitiesView.swift` 的 `DuplicateFilesView` 里。按主会话要求这次没动那个文件，所以由卡片在 `LargeOldFilesStore` 上留一个请求（`requestManager()`），再走原有的 `onReview(.all)` 打开管理器。
  - `CareStudioClutterManager` 在 `showsLargeOld` 为真，或有这个请求时，显示这一类（`showsLargeOldCategory`）。出现时取走请求（`takeManagerRequest()`），再调页面给的 `onLargeOld`，页面的状态随之对上，所以不会先闪一下“全部”。
  - 结果页其他卡片和“查看所有文件”会先撤掉残留的请求（`withdrawManagerRequest()`），不会误开这一类。
  - 页面没给 `onLargeOld` 时（经典列表和它的测试）照旧不提供这一类。
- 没动：`SystemUtilitiesView.swift`、智能扫描、`CareStudioManagerChrome.swift`、Codex 车道的文件。

## 二、测试

- 改了一条已有测试的两处期望：`CareStudioModuleShellRenderTests.testClutterAndProtectionTilesFollowWhatTheScanFound`，每处都写了“D221＋旧值”：
  - 有重复文件时，卡片顺序由 `["duplicates", "candidates", "similarPhotos", "chatFiles"]` 改为 `["duplicates", "candidates", "similarPhotos", "largeOld", "chatFiles"]`；
  - 没有重复文件时，由 `["similarPhotos", "chatFiles"]` 改为 `["similarPhotos", "largeOld", "chatFiles"]`。
  - 理由：D221 补按主会话决定加了这张卡片。同一条测试里“没有一张卡片能直接移除东西”的断言不变，新卡片也满足。
- 新增 `ClutterLargeOldFilesD221Tests.testResultsTileCountsWhatTheCategoryListsAndOnlyOpensIt`：
  - 还没有清单时不写大小；
  - 有清单时，数和大小与管理器同口径，文件夹不算；
  - 没有一键按钮和勾选框，只有“查看”；
  - 点“查看”后管理器显示这一类，请求只取一次，取走后照常；
  - 没有 `onLargeOld` 的管理器不提供这一类；
  - 其他卡片会撤掉残留的请求；
  - 一个都不选。
- 新增离屏渲染 `CareStudioRenderReviewTests.testRendersD221LargeOldTile`：五张卡片的结果页，深浅两色。
- 跑过的定向非窗口测试（Debug，`--disable-swift-testing`）：10 类 147 条，0 失败。类：ClutterLargeOldFilesD221Tests、CareStudioModuleShellRenderTests、CareStudioRenderReviewTests、AppLifecycleReminderD219D220Tests、D207IgnoreFromManagersTests、UIConsistencyRegressionTests、CareStudioToolboxWiringTests、SmartCareTests、D64DeclutterAContractTests、OwnedUIFlatteningContractTests。
- 静态检查：`display_bound_tests.py --check`、`check_deletion_process_inventory.py`、`check_private_api.py` 均通过。
- 离屏图：`第18次-离屏渲染自查/杂乱结果页-大型和旧文件卡片-深色.png`、`…-浅色.png`（14 个夹具文件，卡片写 47.25 GB、“14 个大型文件，可按打开时间筛选”，只有“查看”）。

### 请主会话跑的窗口类

- `CareStudioWindowReviewTests`：杂乱结果页由 4 张、2 张卡片变成 5 张、3 张。`testResultTilePagesStayInsideEverySupportedWindowSize`、`testMotionComesToRestOnTheStillLayout` 和模板截图都会走到。卡片网格放不下时本来就会在自己的区域里滚动。
- “点卡片进管理器这一类”这一步没有窗口测试：它要连着 `DuplicateFilesView`，而这次不动那个文件。逻辑由上面的非窗口测试覆盖。

## 三、建议写进 DECISIONS 的条目（由主会话定稿）

- D221 补：杂乱结果页加“大型和旧文件”卡片，排在“相似照片”之后。数和大小与管理器这一类同口径（只算文件，去掉忽略列表挡住的），只给“查看”，点开进管理器的这一类；没有清单时提示可在里面扫描大型文件（只读）。智能扫描不变。

## 四、限制

- 卡片的图沿用“文件搬家”的图（`.migration`），和管理器左栏一致，没有新画。
- 以后如果允许改 `SystemUtilitiesView.swift`，可以把“请求”换成结果页直接给的回调（`onLargeOld`）。现在的做法不需要那边配合。
