# 交接：第 20 次（D226 杂乱“下载”按类型分、D227 下线垃圾清理的下载规则、D225 补路径措辞全应用统一）

- 会话：cmm-ui（CleanMyMac 界面逆向，D154 车道）
- 基线：0efcd63e（r55/r56 最终门禁树）
- 补丁：`cmm-ui-第20次-D226D227D225补.patch`，一份（主会话 10-26 要求措辞统一和第 20 批合成同一个补丁）。sha256 和结果树随交付消息给出；本文件在补丁里，不含自己的哈希。
- 本交接在仓库里的位置：`docs/2.0.0/collab/handoffs/cmm-ui-build20.md`
- 未提交、未安装；没有用 LCU（重启前不用）。DECISIONS 没改，建议措辞在第六节。

## 一、D226 杂乱“下载”（用户 10-26 选方案 B：按类型分）

### 1. 一份安装包清单

- 新文件 `Models/InstallerFileTypes.swift`：dmg、pkg、mpkg、iso、sparseimage、xip。
- 三处都读它：
  - 应用管理 → 安装文件：`UnusedInstallerScanner.extensions` 改为这份清单，补上 xip。
  - 杂乱“下载”：不列清单里的类型。
  - 大型和旧文件：`LargeOldFilesPresenter.rows` 不再列安装包。
- 安装文件的 Spotlight 查询：原来只按两种类型树找（磁盘映像、安装包）。现在另加清单里每种扩展名的文件名条件。
  - 本机 UTType 实测：iso、sparseimage 本来就算磁盘映像；只有 xip 两种都不是，靠文件名才找得到。
- D209 预选规则没动：只有「下载」和桌面里、名字对上已装应用的才预选。新测试用 xip 核对了这一点。
- 没改的另外三份清单（用途不同，不在工单的三处里），列出供参考：
  - `LargeFileKind` 的安装包分类（dmg、pkg、mpkg、ipsw、appinstaller；iso 算压缩包），给“文件搬家”大文件清单分类用。
  - `ApplicationResourceFinder.installerExtensions`（dmg、pkg、mpkg），卸载时找某个应用自己的安装包。
  - `CodexArtifactScanner`（dmg、pkg、mpkg、xip、zip）。

### 2. 范围和层级

- 文件夹：`FileManager` 给的「下载」位置，不写死路径。
  - 测试里跟着测试用 store 自己的主目录走：`DownloadsStore.downloadsURL(homePath:)`。在应用里两个主目录相同，取到的就是系统位置。
  - 为此给 `LargeFilesStore` 加了只读的 `fileAnalysisEnvironment`。`ToolboxStores` 用它定位「下载」，也用它审阅和移动，和空间透镜同一个环境。
  - 原因：`CareStudioWindowReviewTests` 会在真窗口里打开杂乱结果页，没有这一步就会读到本机真实的「下载」。
- 读法：空间透镜同一个只读分析（`DiskScanner` 存储地图）。
  - 只读名称、大小、修改时间和文件自带的来源记录，不打开文件内容，不写任何东西。
  - 云端占位不往里走，不触发下载。
- 层级：每个顶层项目一行，文件夹按里面全部内容算大小和项目数，和空间透镜同一算法（硬链接只算一次）。
  - 依据：CleanMyMac 的“下载”读的是 Safari、Chrome、Slack 各自的下载历史（`CMSafariDownloadsHistoryDataController` 等）。
  - 我们不读浏览器历史（隐私，也要另外的权限）。所以列人在访达里看到的「下载」顶层。
- 不列：
  - 隐藏项目；
  - 清单里的安装包；
  - `.app`（归“其他位置的应用”）；
  - 链接、读不了的项目、云端占位；
  - `ProtectedLocations` 保护的位置；
  - 忽略列表里“杂乱 → 下载”和“其他”类的条目。

### 3. 来源分组

- 先看 `com.apple.quarantine` 里记的 App，再看 Spotlight `kMDItemWhereFroms` 的网址域名（去掉 www.），都没有就归“其他来源”。
- 文件夹：先看它自己的隔离记录。没有就看里面多数文件的来源，最多读 200 个文件，每个文件夹最多问 Spotlight 50 次；票数相同取先遇到的。
- 每次读取，Spotlight 一共最多问 500 次。用完后，没有隔离记录的项目归“其他来源”。读属性很快，Spotlight 慢，这样上千项也能很快列出。
- 组名是我们自己的话：“来自 Safari”“来自 github.com”“其他来源”。没有照搬 CleanMyMac 的 `downloads_*_group_title`。
- 几个内部名换成人认得的 App 名：sharingd → 隔空投送；com.apple.shortcuts → 快捷指令；Mail → 邮件；Preview → 预览；wpsoffice → WPS Office。其余照记录显示。
- 本机只读核实（10-26，只读属性，不读内容，只给统计）：
  - 「下载」不是链接。顶层可见 12 项（1 个文件、11 个文件夹），另 2 个隐藏项。12 项自身都没有隔离记录，也没有网址记录。
  - 往下查到第 4 层，共 479 个文件：
    - 254 个有隔离记录，其中 16 个没写 App 名；
    - 107 个有网址记录，共 19 个域名。
  - 记录里的 App 名：Chrome 130、wpsoffice 52、sharingd 26、Telegram 10、Mail 10、WeChat 6，Ulysses、Microsoft Excel、com.apple.shortcuts、Preview 各 1。
  - 结论：macOS 27 上，隔离记录对浏览器、隔空投送和聊天软件下载的文件是可靠的。本机顶层几乎都是文件夹、自身没有记录，所以要按里面文件的多数来源归组。

### 4. 位置、读取和移走

- 结果页卡片“下载”排在“大型和旧文件”之后、“聊天文件”之前。
  - 卡片上的数和大小与管理器这一类同口径。
  - 只给“查看”，不放一键执行。
  - 图标用现有的 `tile-othersources`（带下载箭头的地球），没有新画图。
- 管理器分类栏“下载”在“大型和旧文件”下面。
  - 打开方式照 D221 补：卡片留请求，管理器出现时取走。
  - 页面状态 `showsDownloads` 在 `DuplicateFilesView`，和 `showsLargeOld` 互斥。
- 什么时候读：
  - 杂乱结果页出现时读一次，以重复文件扫描的完成时间为准，已在那之后读过就不再读；
  - 从分类栏直接进、还没读过时读；
  - “更多 → 重新读取“下载”文件夹”；
  - 新读一次，什么都不勾。
- 租约：读取不占重活租约，只读一个文件夹的名称、大小和属性。
  - 这样不会挡住“重新开始”或别的扫描（D184 应用瘦身读取持 `.mainScan` 挡住过“重新开始”）。
  - 移动走 `.cleanup` 租约。
- 默认一个都不勾。组的勾选框全选或全不选，部分选中显示横杠。排序：按大小、按名称、按修改时间（最旧在前）。搜索名称、路径或来源。
- 移走走 D221 那套：
  - 勾选 → “移到废纸篓…” → 审阅 → 移到废纸篓 → 回执，可在操作记录恢复。
  - 审阅用 `FileAnalysisTrashService`，和空间透镜同一套：D46/D54 各项保护；文件夹与读取时逐层比对，有变化的跳过；每项移动前再核对一次。
  - 审阅弹窗抽成了共用的 `ClutterTrashReviewSheet`。“大型和旧文件”的 `LargeOldFilesReviewSheet` 现在是它的一层包装，界面和文字不变。
- 没有完全磁盘访问权限时，读「下载」macOS 可能弹一次文件夹权限框。
  - 读取发生在用户自己开始的杂乱扫描之后。“用户文件”范围的扫描本来就读「下载」。
  - 验收模式启动时要求已有完全磁盘访问权限，不会弹。

### 5. 页底

- 列表下面固定一行：“安装包（dmg、pkg、iso 等）统一在“应用管理 → 安装文件”里查看 ›”，可以点。
- 点了打开应用管理的安装文件类（`ApplicationsManagerModel.review(.installers)` 加 `showFilter(.uninstall)`）。应用还没读过时，先到应用管理首页。

### 6. 忽略

- 右键：在访达中显示、加入忽略列表、复制路径。
- 加入忽略列表按路径记在“杂乱 → 下载”（D207 已有这一类，安装包的条目也在这一类，照旧），列表里马上消失。
- “放回原处”照 D215/D225：回到列表，原来勾着的还勾着。

### 7. 两边都列

- 「下载」里不是安装包的大文件，“下载”和“大型和旧文件”两边都列，不加两类合计的数字。
- 一边移走，另一边立即不再列出（在 `ToolboxStores` 里互相接上）：
  - “下载”移走的文件和文件夹：“大型和旧文件”和“文件搬家”大文件清单都去掉它们，以及文件夹里的文件（它们已在废纸篓）；那边勾着的也一并去掉。
  - “大型和旧文件”移走的、在「下载」顶层的文件：从“下载”去掉，不重新读。移走的文件在某个顶层文件夹里面时，重新读一次「下载」，让那个文件夹的大小对得上。

### 8. 首页说明和侧栏提示（主会话 10-26 加）

- 首页说明，按结果页顺序加上“下载”：
  - 中文：“整理重复文件、相似照片、大型和旧文件、“下载”文件夹以及聊天文件；重复文件每组至少留一份。”
  - 英文：“Sort out duplicates, similar photos, large and old files, the Downloads folder and chat files. At least one copy of each duplicate group stays.”
- 侧栏“杂乱文件”悬停提示（也是 VoiceOver 提示），原来是“重复文件和相似照片”：
  - 中文：“重复文件、相似照片、大型和旧文件、下载和聊天文件”
  - 英文：“Duplicates, similar photos, large and old files, Downloads and chat files”
- 首页扫描按钮“扫描重复文件”没改。
- 这行说明在 `FeatureLightfieldPage` 的杂乱首页上，现有离屏渲染集里没有这一页，我没另外渲染。长度比 D223 多 7 个字，请窗口类和装机后核对。

### 9. 改写的旧期望（D226＋旧值）

- `ClutterLargeOldFilesD221Tests.testListsFilesOnlyWithKindSizeAndWhichDateItShows`：清单不再有 Installer.dmg，注释里留了原来的清单。
- `CareStudioModuleShellRenderTests`：卡片顺序两处加 "downloads"。
- `CareStudioRenderReviewTests.testRendersD221LargeOldTile`：卡片顺序加 "downloads"。
- `WordingD223D224Tests`：首页说明全文；类别清单加一项；新增侧栏提示一条。

## 二、D227 下线垃圾清理的两条下载规则（用户选甲）

- 删除 `downloads.installers`、`downloads.large-items`：
  - `CleanupRules.v2.json` 删条目，rulesVersion 2026.10.20.1 → 2026.10.26.1，json 规则 15 → 13；
  - `CleanupRules.baseline.json` 删条目和 legacyRules，entries 89 → 87，legacyRules 73 → 71；
  - 加载后的规则集共 89 → 87 条。
- 校验没有放宽：`CleanupRuleMaintenanceValidator` 照常通过。
- 删了不再用到的文字：`ReadOnlyCleanupScanner` 里 `cleanup.category.downloads`、`cleanup.rule.downloadInstallers.title/.reason`、`cleanup.rule.downloadLargeItems.title/.reason` 的备用文字，以及 `OperationConfirmationModels` 里 downloads.large-items 的影响说明。
- 保留 `CareJunkGrouping` 里 "downloads" 类别 → 待确认文件的对应，旧报告里的项目还在原来的组。
- 忽略列表条目、回执、操作记录都没动。
  - 新测试 `CleanupDownloadsRetiredD227Tests` 用这两条规则 ID 写回执，确认操作记录照常列出、标题正常、能恢复。
- 数字：
  - 这两条原是待确认文件（reviewOnly）。垃圾清理结果页和智能扫描卡的垃圾数本来就不算待确认文件组（`CareStudioJunkResults.swift:171`、`CareStudioSmartCare.swift:85`），所以垃圾数不变，只有“另有 … 待确认文件”变小。
- 清理规则表 `docs/2.0.1/cleanup-rule-table.md` 按现有约定重新生成（`STORAGE_CLEANER_RECORD_RULE_TABLE=1`，D100 G4-1）：两行规则和计数。
- 改写的旧期望（D227＋旧值）：
  - `CleanupRuleProvenanceTests`（legacy 73 → 71）；
  - `CleanupRuleScannerTests`（决策清单、reviewOnly 集合；两处属性检查改为确认规则已不存在）；
  - `CleanupScopeD192Tests`；
  - `ProtectedLocationLayersTests`（基准规则换成仍在的一条）；
  - `CompetitorDerivedRuleTests`（rulesVersion）；
  - `ScanAccessReturnTests`：D104 G5 的夹具原来拿「下载」当第二个新位置。会话点名的规则不在打包规则里时，店里按设计改走 A-R3 整体重扫，第一轮有 3 条失败。现在第二个新位置换成仍随包的待确认规则 `user-data.istat-menus-setapp-history`，断言不变，仍然检查“只跑新位置的规则、并进同一个结果”。

## 三、D225 补：路径的两个右键动作全应用统一

- 中文统一为“复制路径”“在访达中显示”，英文（Copy Path、Show in Finder、Reveal in Finder）不动。
- grep 依据（按字符串字面量计）：改前“复制路径”12 处、“拷贝路径”3 处；“在访达中显示”31 处、“在 Finder 中显示”10 处。
- 改的地方：
  - 单份路径行：`OtherApplicationGroupRows`、`ApplicationsManagerView`；
  - “拷贝路径” → “复制路径”：`CareStudioJunkManager`、`ToolboxManagerPanel`、`CareStudioClutterLargeOld`；
  - “在 Finder 中显示” → “在访达中显示”：
    - 启动项：`StartupItemInspectorView`、`StartupItemsDashboardView`，以及 `ScanStore` 里一句提示“已在访达中显示，未修改启动项”；
    - 清理列表：`CleanupScanViews` 4 处，含按钮的无障碍名字和两句按键说明；
    - `FeatureLightfieldUninstallList`。
- `UIConsistencyRegressionTests` 一处断言照改，写“D225补＋旧值”。
- 新加源码合同测试 `PathActionWordingD225Tests`：跳过注释，检查 Sources 里的字符串不再有“拷贝路径”和“在 Finder 中显示”。
- 没改：“在 Finder 中打开“…””（菜单栏的磁盘卷详情，`GeekHoverDetailTarget.swift:1305`）是另一个动作，不在这两个词里。

## 四、验证（都在重锁下，定向编译）

- 第一轮（48 个非窗口类）有 4 个类失败，处理如下：
  - `ScanAccessReturnTests` 3 条：见第二节。
  - `CleanupRuleTableTests`：规则表未重新生成。
  - `CareStudioRenderReviewTests.testRendersD221LargeOldTile`：卡片顺序。
  - 我的新测试一条：应用管理在导航里是工具页（utilityHub 加 Uninstall），期望写错了，已按实际导航改成两部分都断言。
- 第三轮：同 48 个类，729 条，0 失败，4 跳过（原有）。规则表重新生成后测试通过。
- 第四轮（措辞统一、「下载」改跟 store 主目录、新合同测试之后）：64 个非窗口类，881 条，0 失败，4 跳过。
- 第五轮（首页说明、侧栏提示之后）：6 个相关类，94 条，0 失败。`testRendersStudioPagesForReview` 通过。
- 静态检查三项通过：`display_bound_tests.py --check`、`check_deletion_process_inventory.py`、`check_private_api.py`。代码规则 grep（字体、具名颜色、`.buttonStyle(.plain)`、工具栏）也是干净的。
- 离屏渲染（`~/Developer/.sc-build/cmm-ui-items-evidence/d226-downloads/`）：结果页深浅两色。
  - “下载”卡片在“大型和旧文件”之后，9 个夹具文件合计 9.45 GB，“9 个项目，按下载来源分组”，只有“查看”。
  - 管理器列表含 ScrollView，离屏画不出来，靠下面的窗口类核对。
- 没做：
  - 窗口类（交主会话）；
  - 实机 LCU 核对（重启前不用）；
  - 完整门禁。

### 请主会话跑的窗口类

- `CareStudioWindowReviewTests`：新方法 `testClutterDownloadsKeepsTheListInsideThePanelAtEverySize`，“下载”列表、页底一行、底栏在四种尺寸下都在面板里，上下不叠。另外结果卡片页现在有 6 张卡。
- `CareStudioNavigationTests`：杂乱结果页、侧栏提示。
- `SmartScanScopeTests`：打包规则少了两条。
- `SafeCleanupLayoutTests`、`MiniWindowCleanupPresentationTests`：清理列表措辞。
- `FeatureLightfieldApplicationPageTests`、`FeatureLightfieldApplicationP2Tests`：应用管理措辞、`FeatureLightfieldUninstallList`。
- `StartupItemsDashboardContractTests`：启动项措辞。
- `FeatureLightfieldContractTests`、`FeatureLightfieldResultSpaceTests`、`DesignSystemV2ReviewTests`、`LightfieldMergeContractTests`：会读到改过措辞的视图源文件。

## 五、和 CleanMyMac 的差别

- 它的“下载”里也会出现 DMG；我们的安装包只在“应用管理 → 安装文件”（用户的选择）。
- 它读各浏览器的下载历史；我们读文件自带的隔离记录和网址记录。
- 组名、说明、页底文字都是我们自己的话，没有照搬它的代码、图片和整句。

## 六、建议 DECISIONS 措辞

- D226：杂乱“下载”按类型分。
  - 安装包（dmg、pkg、mpkg、iso、sparseimage、xip，一份共用清单）不管放在哪，只在“应用管理 → 安装文件”出现，D209 预选规则不变，“大型和旧文件”不再列安装包。
  - 杂乱新增第五类“下载”：系统给的「下载」文件夹顶层项目（文件夹按总大小），不含安装包、.app、链接、云端占位、受保护位置和忽略列表里的项目。
  - 按来源分组：隔离记录的 App → Spotlight 网址域名 → 其他来源；文件夹按里面多数文件。
  - 默认不勾，审阅后移到废纸篓、有回执、可在操作记录恢复；右键加入忽略列表（杂乱 → 下载，按路径），可放回原处；页底一行指向“应用管理 → 安装文件”。
  - 结果页卡片排在“大型和旧文件”之后、“聊天文件”之前，只给“查看”。
  - 两边都列的大文件，一边移走另一边立即不再列出，不给两类合计数。
  - 读取只读、不占重活租约，测试里读测试 store 自己的主目录。
  - 首页说明和侧栏提示列上“下载”。
- D227：垃圾清理下线 `downloads.installers`、`downloads.large-items`。
  - v2 规则和基线同步删除，rulesVersion 2026.10.26.1，规则 89 → 87 条；清理规则表重新生成。
  - 垃圾数不变，只有“另有 … 待确认文件”变小；旧回执照常显示和恢复。
- D225 补：全应用中文统一为“复制路径”“在访达中显示”（英文不变），源码合同测试 `PathActionWordingD225Tests` 防回退。

## 七、改动文件（42 个，含本交接共 43 个）

- 新增：
  - `Models/InstallerFileTypes.swift`
  - `Features/Downloads/DownloadsModels.swift`、`DownloadsStore.swift`
  - `Views/CareStudio/CareStudioClutterDownloads.swift`
  - 测试：`ClutterDownloadsD226Tests`、`CleanupDownloadsRetiredD227Tests`、`PathActionWordingD225Tests`
- 修改，D226：
  - `LeftoverAndInstallerScanners`、`LargeOldFilesModels`、`LargeOldFilesStore`、`LargeFilesStore`（只读访问器）、`ToolboxStores`
  - `CareStudioClutter`、`CareStudioClutterLargeOld`（共用审阅弹窗，加上“复制路径”）、`CareStudioTheme`、`SystemUtilitiesView`（`DuplicateFilesView` 的 `showsDownloads`）
  - 测试：`CareStudioModuleShellRenderTests`、`CareStudioRenderReviewTests`、`CareStudioWindowReviewTests`、`ClutterLargeOldFilesD221Tests`、`WordingD223D224Tests`
- 修改，D227：
  - `CleanupRules.v2.json`、`CleanupRules.baseline.json`、`ReadOnlyCleanupScanner`、`OperationConfirmationModels`、`docs/2.0.1/cleanup-rule-table.md`
  - 测试：`CleanupRuleProvenanceTests`、`CleanupRuleScannerTests`、`CleanupScopeD192Tests`、`ProtectedLocationLayersTests`、`CompetitorDerivedRuleTests`、`ScanAccessReturnTests`
- 修改，D225 补：
  - `OtherApplicationGroupRows`、`ApplicationsManagerView`、`CareStudioJunkManager`、`ToolboxManagerPanel`、`StartupItemInspectorView`、`StartupItemsDashboardView`、`ScanStore`（一句提示）、`CleanupScanViews`、`FeatureLightfieldUninstallList`
  - 测试：`UIConsistencyRegressionTests`
- 碰到的较热文件：`ScanStore.swift`（一行文字）、`SystemUtilitiesView.swift`（`DuplicateFilesView` 里 13 行）、`LargeFilesStore.swift`（加 3 行访问器）。
