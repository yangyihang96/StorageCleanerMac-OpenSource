# 交接：第 21 次（D228 发布前文字修整）

- 会话：cmm-ui（CleanMyMac 界面逆向，D154 车道）
- 基线：64a64a57（第 20 次最终门禁树）
- 补丁：`cmm-ui-第21次-D228.patch`，一份。sha256 和结果树随交付消息给出；本文件在补丁里，不含自己的哈希。
- 本交接在仓库里的位置：`docs/2.0.0/collab/handoffs/cmm-ui-build21.md`
- 只修工单里的三处，没加别的改动。
  - 没碰 CHANGELOG.md、RELEASE.md、docs/RELEASE_VALIDATION_2.0.1.md、script/release_version.env，也没碰 DECISIONS。
  - 未提交、未安装，没有用 LCU。

## a. 杂乱首页说明折行不拆词

- 原因：
  - 首页文字栏最宽 460 点，用 16 号字（窄窗口 14 号），一行约 28 个汉字。
  - 中文允许在任意两个字之间换行，所以 1280 宽的窗口在“聊”后断开。
  - 改短或在“；”处分句都不可靠：前半句 32 个字，在 460 点下仍要折行，窄窗口照样会拆词。
- 做法：新加 `CareStudioLineBreaks.betweenPhrases`（`CareStudioTheme.swift`），只用在杂乱首页这一句。
  - 每个短语里的字之间加词连接符（U+2060，不显示、不占宽，文字排版不会在它两侧断行）。
  - 一行只能在顿号、逗号、分号、句号等停顿号之后，或“以及”之前断开。
  - 文字本身没变。英文只在空格处换行，原样不动。
- 1280 宽窗口（460 点）现在折成：“整理重复文件、相似照片、大型和旧文件、“下载”文件夹”｜“以及聊天文件；重复文件每组至少留一份。”
- 几何检查：新测试 `PreReleaseWordingD228Tests.testTheClutterSentenceBreaksOnlyBetweenPhrasesAtEveryWidth`。
  - 用 TextKit 按首页同一系统字体排版，中英文各算一遍，14 号和 16 号字都算。
  - 宽度从 240 点到 460 点，每 2 点一档。
  - 中文：每行只在停顿号后或“以及”前断开；“聊天文件”“重复文件”“相似照片”等词都完整落在一行里。
  - 英文：每行都在空格处断开。
  - 窗口测试的 1024、1280、1500 三种宽度，文字栏按布局算约 451、460、460 点；最小窗口也在 420 点以上，都在检查范围里。
  - 先用不加连接符的原句验证过：同样的排版在 460 点会拆开“聊天文件”，在 330 点会拆开“文件夹”。
- `WordingD223D224Tests` 的全文期望改为去掉连接符后比较，写“D228＋旧值”，文字不变。

## b. 来源组名的空格

- `DownloadSource.title`：中文、日文、韩文或全角字符开头的名字前不加空格（来自隔空投送、来自邮件、来自微信 WeChat）。拉丁字母或数字开头的名字前照旧留空格（来自 Chrome、来自 WPS Office、来自 github.com、来自 163.com）。
- 数字开头也留空格：中文排版里汉字和数字之间同样留空，工单只点名了拉丁字母，这一点请主会话确认。
- 英文界面照旧“From …”。
- 新测试覆盖中文、英文和混合名字。`ClutterDownloadsD226Tests` 一处旧期望（“来自 隔空投送”）照改，写“D228＋旧值”。

## c. 零字节的写法

- 源头 `ByteFormat`：系统的格式样式中文写“0字节”“512字节”，数字和单位之间没空格，其他单位都有空格（“17.8 MB”）。
  - 改法照 ByteFormat 现有约定：在它已有的单位整理步骤里（原来只把“kB”改成“KB”），再给“字节”前补一个空格。现在写成“0 字节”“512 字节”“1,000 字节”。
  - 这个步骤改名为 `unitsAsFinderWritesThem`。
  - `storageString`、`memoryString` 都走它。英文“0 bytes”本来就有空格，不变。
  - 底栏现在是“已选 0 项 · 0 字节”，“大型和旧文件”和“下载”共用这一句。
- 全应用查了一遍零字节：
  - 走 ByteFormat 的地方都跟着改好了。
  - 另有 4 处没走 ByteFormat，直接用系统格式化。零时写“Zero KB”“Zero kB”，而且跟系统语言而不是应用语言（D178 要求都走 ByteFormat），改成走 `ByteFormat.storageString`：
    - 应用更新：单个下载大小、合计下载大小（`AppUpdatesView`）；
    - 应用更新：磁盘空间不足的提示（`ProviderBackedApplicationUpdateExecutor`）；
    - 健康页：SMART 读写量（`ComputerHealthView`）。
  - 还有 4 处直接用系统格式化，但值不会是零，没动：提醒阈值、跑分里的内存、磁盘容量（含 `MacBenchmarkPresentation`、`BenchmarkV7DashboardView`）。
  - 菜单栏和状态栏不用 `storageString`，不受影响。
- `SystemMonitorServiceTests` 一处旧期望（“0字节”）照改，写“D228＋旧值”。
- 新测试：中英文零、单字节、千字节以下和 MB；底栏那句；上面 4 处的源文件不再用系统格式化。

## 验证（重锁下，定向编译）

- 引用到改动文件的非窗口测试类共 61 个（ByteFormat 用得广），1058 条，0 失败，3 跳过（原有）。新测试类 5 条都在里面通过。
- 静态检查三项通过：`display_bound_tests.py --check`、`check_deletion_process_inventory.py`、`check_private_api.py`。代码规则 grep 也是干净的。
- 没做：窗口类、实机 LCU、完整门禁。

### 请主会话跑的窗口类

- `CareStudioNavigationTests`：1024、1280、1500 三种宽度下的页面，含杂乱首页。
- `CareStudioWindowReviewTests`、`SmartScanScopeTests`、`SpaceLensSidebarWindowTests`、`RuntimeUIRound201Tests`。
- `MiniWindowCleanupPresentationTests`、`MiniWindowRowLayoutTests`：用到 ByteFormat，千字节以下的中文大小多了一个空格。
- `FeatureLightfieldContractTests`、`FeatureLightfieldFilesContractTests`、`LightfieldMergeContractTests`、`DesignSystemV2Tests`、`StartupItemsDashboardContractTests`、`HelperPowerMetricsMergeTests`：会读到改过的源文件或用到 ByteFormat。
- 装机后请顺带看一眼：杂乱首页在 1280 宽窗口折成两行，第二行以“以及聊天文件”开头；“下载”管理器的组名“来自隔空投送”；底栏“0 字节”。

## 建议 DECISIONS 措辞

- D228：发布前文字修整三处。
  - ①杂乱首页说明只在短语之间换行：短语里的字用词连接符（U+2060）连起来，只在停顿号后或“以及”前断开，文字不变；TextKit 几何检查覆盖 240–460 点、14/16 号字和中英文。
  - ②“下载”来源组名：中文等宽字符开头的名字前不加空格（来自隔空投送），拉丁字母或数字开头的留空格（来自 Chrome）。
  - ③零字节和千字节以下的中文写法和其他单位一样带空格（“0 字节”），在 ByteFormat 的单位整理步骤里改；另 4 处能显示零的系统格式化（应用更新的下载大小、合计和磁盘空间提示，健康页 SMART 读写量）改走 ByteFormat，不再显示“Zero KB”，也跟应用语言走。

## 改动文件（10 个，含本交接共 11 个）

- 源码：
  - `CareStudioTheme.swift`（a）
  - `DownloadsModels.swift`（b）
  - `ByteFormat.swift`、`AppUpdatesView.swift`、`ProviderBackedApplicationUpdateExecutor.swift`、`ComputerHealthView.swift`（c）
- 测试：
  - 新增 `PreReleaseWordingD228Tests`
  - 改旧期望：`WordingD223D224Tests`、`ClutterDownloadsD226Tests`、`SystemMonitorServiceTests`，各一处，都写了“D228＋旧值”
