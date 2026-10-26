# 交接：第 18 次 B（D221 杂乱管理器加“大型和旧文件”）

- 会话：cmm-ui（CleanMyMac 界面逆向，D154 车道）
- 基线：第 18 次 A 的结果树（A 打在 c83c1f32 上）。B 和 A 不改同一个文件，单独打在 c83c1f32 上也能打上。
- 补丁：`cmm-ui-第18次B-D221.patch`（sha256 和结果树随交付消息给出，本文件在补丁里，不含自己的哈希）
- 本交接在仓库里的位置：`docs/2.0.0/collab/handoffs/cmm-ui-build18-b.md`
- 未提交、未安装；没有移动、删除任何真实文件。

## 一、改了什么

- 杂乱文件管理器左栏最后加一类“大型和旧文件”（标题用 D207 的同名忽略类别文字），数字是这一类会列出的文件数；还没有大型文件清单时不显示数字。
- 列表来源：复用“文件搬家”的大文件清单（`LargeFilesStore.items`，门槛照它的 50 MB / 200 MB / 1 GB 设置）。只列文件，文件夹留在大文件清单里。还没有清单时，页面说明来源并给“扫描大型文件”按钮（只读扫描，用户点了才开始）；扫描中显示进度圈。
- 默认一个都不勾；三组筛选也默认一个都不勾（= 显示全部）。
- 筛选（同组多选相加，不同组相互收窄）：
  - 类型：文稿、图片、视频、压缩包、其他（安装包、音频、邮件附件、开发文件都算“其他”；分类沿用 `LargeFileKind.classify`）。
  - 大小：小（100 MB 以下）、中（100 MB–1 GB）、大（1 GB 及以上），十进制单位（D178）。界线依据 CleanMyMac 的说明文字：小文件“几 MB”、中等“数百 MB 到上 GB”、最大的“上 GB”。
  - 上次打开：一周内、一周前、一个月前、半年前、一年前（7/7/30/182/365 天）。和 CleanMyMac 一样，后几档包含更老的文件（两年前打开的文件同时属于一周前、一个月前、半年前、一年前）。
  - 菜单里每项后面有数量；“上次打开”菜单底部注明“没有打开记录的文件按修改时间算”，读日期时显示“正在读取上次打开时间…”。
- 上次打开时间：读 Spotlight 的 `kMDItemLastUsedDate`（`MDItemCreate`/`MDItemCopyAttribute`，公开 API，不启动进程）。缺失时用大文件清单记下的修改时间，行内标注“无打开记录 · 修改于 …”并用橙色字；有记录的写“上次打开 …”。日期按应用语言显示。每份新清单在后台读一次。
- 排序：按大小（默认）、按名称、按上次打开（最早的在前，没有日期的排最后）。搜索名称或路径。
- 移除：底部主按钮“移到废纸篓…”，先出审阅单，审阅单里再点“移到废纸篓”才移动（D90/D93：全程不叫“释放”）。
  - 审阅走 D46 的 `FileAnalysisTrashService.review`/`execute`，做法和恶意软件移除一样（`LargeOldFilesTrashService`）：打开审阅时逐个测量；已不存在的标“已不存在”，不再是普通文件的标“无法读取”，修改时间和扫描时记下的不同的标“分析后已变化”；D46/D54 的保护全部生效；每个文件移动前再核对一次，在 cleanup 租约里、写回执，可从“操作记录”恢复。
  - 审阅单：六项确认事实（`OperationConfirmationFactsView`）、逐项状态和不能移动的原因、硬链接提示、脚注“移到废纸篓后可在“操作记录”中恢复；清空废纸篓后才会释放空间。”（沿用 D93 现有文字）。回车不会移动任何文件。
  - 移动后：移走的文件同时从这一类和“文件搬家”的大文件清单里拿掉（新增 `LargeFilesStore.forgetMovedFiles`）；被跳过的保留勾选；页面顶部说明移了几个、几个没移。另一项任务占着清理租约时，审阅单不关，写明是哪项任务。
- 忽略列表（D207）：行右键“加入忽略列表”，按“大型和旧文件”类别加入并立即从列表里拿掉；窗口底部提示条上的“放回原处”会把它放回来，原来勾着的仍勾着。其他类别（如“重复文件”）的条目不影响这一类；“其他”类别照旧覆盖所有类别。
- 右键另有“在访达中显示”“拷贝路径”；行尾箭头也是“在访达中显示”。
- 更多菜单：选择显示的全部文件（用户主动点）、取消选择、清除筛选、重新扫描大型文件。
- 状态归属：`LargeOldFilesStore` 挂在 `ToolboxStores` 上，每个 ScanStore 一份。
- 没动：智能扫描（按工单，留作后续可选项）；杂乱结果页的卡片（见第三节）；CareStudioManagerChrome.swift（D213）；Codex 车道的文件。

## 二、测试

- 新增非窗口测试 `ClutterLargeOldFilesD221Tests`，9 条：
  - 只列文件不列文件夹，类型、大小档（含 100 MB、1 GB 两条界线）和显示哪个日期，行内写明是上次打开还是修改时间；
  - 忽略列表：“大型和旧文件”类别的条目才挡住这一类，其他类别（重复文件）不挡，“其他”类别照旧都挡；
  - 筛选同组相加、跨组收窄，后几档“上次打开”包含更老的文件，没有日期的文件不符合任何时间档，半年界线 182 天；
  - 排序（大小、名称、上次打开最早在前且无日期排最后）和搜索；
  - 默认一个都不勾，没勾时不出审阅；审阅不移动任何文件，审阅打开时不能改勾选；移动后移走的文件离开两份列表，被跳过的保留勾选；结果说明写“移到废纸篓”，不出现“释放”；
  - 清理租约被占时审阅单不关，写明是哪项任务，什么都没移；
  - 加入忽略列表后立即消失，放回原处后回来且仍勾着；
  - 新的大文件清单清空勾选，筛选保留；
  - 真文件的审阅：修改时间变了的标“分析后已变化”，已删的标“已不存在”，正常的可移动；审阅不写回执、不动文件。
- 新增窗口测试方法 `CareStudioWindowReviewTests.testClutterLargeOldFilesKeepsTheListInsideThePanelAtEverySize`（已编译，未跑，没有借到屏）：四种窗口大小下面板、筛选、列表、底栏主按钮、左栏都在面板内，筛选在列表上方、列表在底栏上方、筛选不压左栏、标题不压搜索框；列出 12 个夹具文件，一个都不选。为此给测试里的 `clutterManager(store:filter:)` 加了默认为 false 的 `showsLargeOld` 参数，原有调用不变。
- 没有删除或改动任何已有断言。
- 跑过的定向非窗口测试（Debug，`--disable-swift-testing`），两份补丁一起：
  - 第一轮 14 类 174 条，0 失败（类名见 A 交接）；
  - 改窄窗口筛选排布和日期格式后，新类、CareStudioModuleShellRenderTests、SettingsIgnoreListPageTests 复跑，0 失败；
  - 第四轮，两份补丁一起：读到本批改动文件的 28 个源码契约类（AppIconCacheTests、AppUpdatePresentationIntegrationTests、CareStudioToolboxWiringTests、CompetitiveParityContractTests、DuplicateSelectedLocationsTests、EnergyImpactServiceTests、FeatureLightfieldApplicationPresentationTests、FeatureLightfieldPerformanceSourceTests、HelperPowerMetricsMonitorTests、ItemListAndDuplicatePresentationTests、MemoryPressureLevelAppWideTests、MemoryQuitConfirmationTests、MemorySelectionSummaryTests、MyActivityPageTests、OperationConfirmationContractTests、OwnedUIFlatteningContractTests、PanelChartNormalizationTests、PhotoLibraryRepairTests、SettingsSourceContractTests、SmartCareTests、StartupCoverageHelpD206Tests、StartupReadD195Tests、SystemEnergyACTelemetryTests、SystemUtilitySafetyTests、UtilityPresentationPerformanceTests、CareStudioRenderReviewTests、AppLifecycleReminderTests、D207IgnoreFromManagersTests）555 条：2 条跳过（只在打开真机开关时跑），1 条失败。
  - 那 1 条是 `SystemEnergyACTelemetryTests.testTheLocalSystemLoadOnExternalPower`：读本机电池控制器的实时“系统负载”，当时没给出读数（XCTUnwrap 失败）。同一构建单独重跑 3 次都通过（35.04 W，插电、电量 100% 已充满）。本批没碰电池和能耗代码，判断为一时读不到；没改这条测试。
- 静态检查：`display_bound_tests.py --check`、`check_deletion_process_inventory.py`、`check_private_api.py` 均通过（没有新增删除、移动或启动进程的调用点；移到废纸篓仍只经 `FileAnalysisTrashService` 里已登记的那一处）。

### 请主会话跑的窗口类

- `CareStudioWindowReviewTests`：新方法 `testClutterLargeOldFilesKeepsTheListInsideThePanelAtEverySize`；现有的杂乱管理器测试不受影响（不传 `onLargeOld` 时不出这一类）。
- 窄窗口下三个筛选菜单一行放不下时改为上下排（`ViewThatFits`），新窗口测试的 473×360 一档就是看这个。
- 读到本批改动文件（多是 `SystemUtilitiesView.swift`、`ToolboxStores`）的其他窗口类：`CareStudioNavigationTests`、`DesignSystemV2ReviewTests`、`FeatureLightfieldContractTests`、`RuntimeUIRound201Tests`、`StartupItemsDashboardContractTests`。

## 三、没做的和后续可选

- 杂乱结果页没加“大型和旧文件”卡片：工单只要求管理器加这一类，而现有 `CareStudioModuleShellRenderTests.testClutterAndProtectionTilesFollowWhatTheScanFound` 断言了卡片顺序。要加卡片需改那条断言，等主会话定。
- 智能扫描的杂乱卡没有加“大文件”（工单写明这次不动）。
- 杂乱模块自己的扫描不会顺带刷新大文件清单；这一类读“文件搬家”最近一次清单，可在页面或“更多”里重扫。
- “下载”类（按下载来源分组）没做，等定了和“应用管理 → 安装文件”怎么分工。
- 没新画这一类的图标，左栏和空页用现有的“文件搬家”图（`.migration`）。
- 从“操作记录”放回的文件，下次扫描大型文件后才回到列表。

## 四、建议写进 DECISIONS 的条目（由主会话定稿）

- D221：杂乱文件管理器加“大型和旧文件”，列“文件搬家”大文件清单里的文件（不含文件夹），默认一个都不选。筛选按类型（文稿、图片、视频、压缩包、其他）、大小（小 <100 MB、中 100 MB–1 GB、大 ≥1 GB）、上次打开（一周内、一周前、一个月前、半年前、一年前；后几档含更老的），同组相加、跨组收窄。上次打开读 `kMDItemLastUsedDate`，缺失用修改时间并标注。移除只经 D46 审阅后移到废纸篓（不叫“释放”），变化或不存在的文件不移；移走的同时离开大文件清单。右键可加入忽略列表的“大型和旧文件”类别，放回原处恢复。智能扫描不变。
