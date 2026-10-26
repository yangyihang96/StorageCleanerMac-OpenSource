# 交接：第 18 次 A（D219 扫描到期提醒、D220 可用空间不足提醒、D222 首次引导两处文字）

- 会话：cmm-ui（CleanMyMac 界面逆向，D154 车道）
- 基线：c83c1f32（第 17 次门禁树）
- 补丁：`cmm-ui-第18次A-D219D220D222.patch`（sha256 和结果树随交付消息给出，本文件在补丁里，不含自己的哈希）
- 本交接在仓库里的位置：`docs/2.0.0/collab/handoffs/cmm-ui-build18-a.md`
- 未提交、未安装、未发布；没有真实清理，没有写真实忽略列表。

## 一、改了什么

### D219 扫描到期提醒（修好原来不起作用的“扫描提醒”）

- 原来只有设置页读“提醒频率”，没有任何地方据此提醒。现在由 `AppLifecycleReminderCenter` 判断，到期时在菜单栏图标下出卡片，沿用现有卡片、忽略菜单和“稍后再出现”规则（全屏、摄像头、小窗打开、正在用本应用时延后）。
- 频率改成和 CleanMyMac 一样：关闭、每 3 天、每周、每两周、每月（3/7/14/30 天）。默认仍是每周（CleanMyMac 的 `SmartCareReminderSelectedOption` 默认 1，按它的顺序也是每周）。
- 旧值迁移：存的“每日”（`daily`）读作每 3 天（`MaintenanceReminderService.cadence(from:)`），其余照旧；不改写用户存的值。
- 卡片什么时候出：
  - 有过扫描且距上次扫描已超过所选间隔；
  - 从没扫描过的不出（首次扫描交给首次引导）；
  - 正在扫描时不出；
  - 点“现在扫描”后休息 24 小时，免得扫描被停掉后卡片马上回来；
  - 忽略菜单照旧（忽略一周、一天、3 天、直到明天、永久）。
- 卡片文字（自拟）：标题按距上次扫描的时间取最大整单位，如“已经 3 天没有扫描了”“已经一周没有扫描了”“已经 2 周没有扫描了”“已经一个月没有扫描了”；说明“定期扫描能及早发现新的垃圾和问题。扫描只读取，不会删除任何文件。”；内容行“上次扫描”（按应用语言显示日期，如“2026年10月16日 21:19”）“提醒频率”。
- 按钮“现在扫描”：打开主窗口的“智能扫描”页（`.overview`），调用 `SmartCareCoordinator.start()` 开始只读扫描。只调扫描，从不调 `run(cleanup:)`；清理仍要用户在结果页自己点。主窗口出现时才把浏览器隐私 store 交给智能扫描，所以开始前最多等 3 秒（`hasAttachedPrivacy`）。
- 多张卡片同时满足时的先后：应用进废纸篓 > 可用空间不足 > 废纸篓过大 > 扫描到期；一次只出一张，前一张处理完下一张再出。
- 菜单栏检查节奏：每 5 分钟（计时器容差 60 秒）和 Mac 唤醒后各看一次；扫描完成时立即重新判断（订阅 `scanHistorySummary`）。
- 设置“扫描提醒”一节：选频率后马上通知提醒中心；加脚注“到期时，菜单栏图标下方会出现提醒；点“现在扫描”只做只读扫描，不会清理。”

### D220 可用空间不足提醒

- 启动盘可用空间低于阈值时出同一种卡片，按钮“打开垃圾清理”：只打开“垃圾清理”模块页（`.green`），不扫描、不清理。
- 可用空间口径：和其他页面同一个 `StorageCapacitySnapshot.userAvailableBytes`（含可清除空间的 important-usage 可用量）。为照顾 D173（读 important-usage 会让系统问一遍 CacheDelete），先读普通可用空间；只有普通可用空间已低于阈值时才读 important-usage（它只会更大）。
- 同一张卡片不反复出：低于阈值出一次；用户点了忽略或“打开垃圾清理”就记下“这次下跌已处理”（`appLifecycle.lowDiskSpaceAwaitingRecovery.v1`），回到阈值及以上才清掉，再跌下去才再出。卡片没被处理、空间先回升了，卡片自动收起，再跌下去会再出。忽略菜单另外叠加：忽略一周内即使再次下跌也不出。
- 默认阈值：逆向找到了 CleanMyMac 的默认值规则，照它做（见第三节依据），不是固定 10 GB：
  - 取启动盘总容量的十分之一，落到最近的档位（2、5、10、20、30、50、100 GB），一样近取较小一档；
  - 读不到容量时按 1 TB 算，即 100 GB；
  - 例：1 TB 盘 100 GB，512 GB 机型（约 494 GB）50 GB，256 GB 机型（约 245 GB）20 GB。
  - 用户选过的阈值照用户的。
- 设置：“扫描与安全”页的提醒一节加一行“可用空间低于此值时发出提醒：”（开关加 7 档菜单，档位和 CleanMyMac 一样），开着时下面显示“启动磁盘当前可用”。这一节标题由“应用与废纸篓提醒”改为“应用、废纸篓与磁盘提醒”。
- “重置已忽略的提醒”：确认文字改为“之前选择忽略的卸载、废纸篓、磁盘空间和扫描提醒会重新出现；忽略列表里的项目不受影响。”；重置时也清掉“这次下跌已处理”和“现在扫描后的 24 小时休息”（`releaseHandledReminders()`），D211 的“只动提醒、不动忽略列表”不变（仍调用 `center.ignoreList.reset()`）。

### D222 首次引导两处文字

- 完全磁盘访问授权后，页面卡片标题改为“已授予完全磁盘访问权限”，主按钮由“继续”改为“开始”（仍进入下一步“按需开启”）。
- 底部“暂不设置”改为“暂时跳过”（英文 Skip for Now）。

### 其他

- 提醒忽略记录新增两类：扫描到期 100、空间不足 101（CleanMyMac 的数据库里没见过这两类，从 100 编号，避免和它的编号撞上）。读忽略记录改为逐条宽松解码：遇到本版本不认识的类别只跳过那一条，不再整份丢弃。
- `AppLifecycleReminderCenter` 可注入偏好域、时钟、上次扫描时间、读盘函数，并有不出面板的测试模式（`presentsPanel: false`）；正式运行不变。

## 二、测试

- 新增非窗口测试 `AppLifecycleReminderD219D220Tests`，13 条：
  - 五档频率与间隔、默认每周、“每日”读作每 3 天（字符串和偏好域两种读法）；
  - 卡片标题的时间单位（3 天、6.9 天、一周、2 周、4 周、一个月、2 个月）；
  - 扫描卡只在间隔已过时出，关闭时不出，从没扫描过不出；
  - “现在扫描”只去智能扫描（`Destination.smartScan`），别的卡的按钮对它无效，之后 24 小时内不再出，一天后仍未扫描会再出；
  - 扫描卡的忽略菜单（一天内不出，过期后再出）；
  - 默认阈值规则（读不到、1 TB、2 TB、约 494 GB、约 245 GB、256 GB、250 GB 一样近、0），以及用户选过的阈值不随盘大小变；
  - 空间卡每次下跌只出一次：点“打开垃圾清理”只去该页（`Destination.junkCleanup`），同一次下跌不再出，回到阈值后再跌才再出；
  - 没处理的空间卡在空间回升时收起，再跌再出；
  - 空间卡的忽略菜单叠加在下跌规则上；
  - 空间卡排在扫描卡前面，关掉空间提醒后不保留读数、不出卡；
  - 重置已忽略的提醒（`ignoreList.reset()` 加 `releaseHandledReminders()`）后，已处理的卡片能再出；
  - 读启动盘用的是和其他页面相同的可用空间口径；
  - 忽略记录文件里有不认识的类别时，其余记录照样读到。
- 新增离屏渲染测试 `CareStudioRenderReviewTests.testRendersD219D220ReminderCards`（非窗口，设 `STORAGE_CLEANER_CARESTUDIO_EVIDENCE` 时出图）。
- 没有删除或改动任何已有断言。
- 跑过的定向非窗口测试（Debug，`--disable-swift-testing`）：
  - 第一轮 14 类 174 条，0 失败：AppLifecycleReminderD219D220Tests、ClutterLargeOldFilesD221Tests、AppLifecycleReminderTests、MaintenanceReminderServiceTests、SettingsIgnoreListPageTests、PermanentDeletionInvariantTests、CareStudioModuleShellRenderTests、D207IgnoreFromManagersTests、D64DeclutterAContractTests、UIConsistencyRegressionTests、ExternalMigrationReceiptTests、FileAnalysisTrashStoreTests、CareStudioRenderReviewTests、D186MalwareTrashAdapterTests。
  - 改日期格式后，新类和渲染测试复跑，0 失败。
  - 第四轮，两份补丁一起：读到本批改动文件的 28 个源码契约类（AppIconCacheTests、AppUpdatePresentationIntegrationTests、CareStudioToolboxWiringTests、CompetitiveParityContractTests、DuplicateSelectedLocationsTests、EnergyImpactServiceTests、FeatureLightfieldApplicationPresentationTests、FeatureLightfieldPerformanceSourceTests、HelperPowerMetricsMonitorTests、ItemListAndDuplicatePresentationTests、MemoryPressureLevelAppWideTests、MemoryQuitConfirmationTests、MemorySelectionSummaryTests、MyActivityPageTests、OperationConfirmationContractTests、OwnedUIFlatteningContractTests、PanelChartNormalizationTests、PhotoLibraryRepairTests、SettingsSourceContractTests、SmartCareTests、StartupCoverageHelpD206Tests、StartupReadD195Tests、SystemEnergyACTelemetryTests、SystemUtilitySafetyTests、UtilityPresentationPerformanceTests、CareStudioRenderReviewTests、AppLifecycleReminderTests、D207IgnoreFromManagersTests）555 条：2 条跳过（只在打开真机开关时跑），1 条失败。
  - 那 1 条是 `SystemEnergyACTelemetryTests.testTheLocalSystemLoadOnExternalPower`：读本机电池控制器的实时“系统负载”，当时没给出读数（XCTUnwrap 失败）。同一构建单独重跑 3 次都通过（35.04 W，插电、电量 100% 已充满）。本批没碰电池和能耗代码，判断为一时读不到；没改这条测试。
- 静态检查：`display_bound_tests.py --check`、`check_deletion_process_inventory.py`、`check_private_api.py` 均通过。

### 请主会话跑的窗口类

- `CareStudioWindowReviewTests`：首次引导三页（文字变了，探针不变）。
- `SettingsLightfieldGeometryTests`：“扫描与安全”页多了一行开关加菜单、一行当前可用和一段脚注。
- `SmartScanScopeTests`：读扫描提醒的到期判断（频率枚举改了，判断函数没改）。
- 提醒卡片本身没有窗口测试（以前也没有）；离屏渲染自查图见第四节。

## 三、CleanMyMac 默认阈值的依据（只读反汇编，不抄代码）

- 文件：`/Applications/Setapp/CleanMyMac.app/Contents/Frameworks/SharedPreferences.framework`，x86_64 切片，`otool -tV`。
- `0x5500` 起的函数登记 `DiskSpaceThreshold`（字符串长 18）：
  - 先 `callq 0x19b0`：用 `URL(fileURLWithPath: "/")` 读 `NSURLVolumeTotalCapacityKey`，读不到时用常量 `0xE8D4A51000`（1,000,000,000,000，即 1 TB）；
  - 再 `callq 0x1c00`：容量乘 `0xCCCCCCCCCCCCCCCD` 再右移，即除以 10；然后在 `0x151d0` 的静态数组里找差值最小的一项（严格更近才替换，所以一样近取前一项）；
  - `0x151d0` 数组 7 项：2、5、10、20、30、50、100 GB（十进制）。
- 对照：`TrashSizeThreshold` 的默认是另一数组（`0x15270`：0.5、1、2、3、5、10、15、20、30、50、100 GB）的第 3 项 2 GB，和我们现有默认一致；`SmartCareReminderSelectedOption` 默认 1。
- 本机 CleanMyMac 偏好里存的 `DiskSpaceThreshold` 是 100 GB，和这台 1 TB 级别的盘按规则算出的值一致。

## 四、离屏渲染自查

`第18次-离屏渲染自查/` 里四张图：扫描到期、空间不足各深浅两色。核对结果：

- 标题、说明、内容行、按钮文字都对；空间卡写明“可用 12.4 GB / 共 494.38 GB”和用户设的 20 GB；日期按应用语言显示。
- 图里左下角和空间卡的进度条处是黄色禁止图标：离屏渲染画不出 AppKit 控件（“忽略”下拉按钮、线性进度条）时的占位，真窗口里正常。

## 五、建议写进 DECISIONS 的条目（由主会话定稿）

- D219：扫描提醒由提醒中心按设置的频率出卡片（关闭、每 3 天、每周、每两周、每月；旧“每日”读作每 3 天）。从未扫描、正在扫描、点“现在扫描”后 24 小时内不出；按钮只打开智能扫描并开始只读扫描，不执行清理。
- D220：启动盘可用空间（`userAvailableBytes`，含可清除空间）低于阈值时出卡片，按钮只打开“垃圾清理”。每次下跌只出一次（忽略或点按钮记为已处理，回到阈值以上清除），忽略菜单另外叠加。默认阈值照 CleanMyMac：启动盘总容量十分之一就近取 2/5/10/20/30/50/100 GB 中的一档，读不到容量按 1 TB。important-usage 只在普通可用空间低于阈值时读（D173）。
- D222：首次引导在完全磁盘访问已授予时标题为“已授予完全磁盘访问权限”、主按钮为“开始”；“暂不设置”改为“暂时跳过”。

## 六、限制与没做的

- 没有在真机上等到卡片实际出现（需要真实满足到期或空间不足条件；按约定也不在会改真实忽略列表的情况下点）。卡片的出现、延后、忽略和按钮去向由非窗口测试覆盖，外观见离屏图。
- 卡片文字是自拟的，没有照搬 CleanMyMac 的句子。
- 没有新画图标：两张卡用系统符号（`clock.arrow.circlepath`、`internaldrive.fill`）。
