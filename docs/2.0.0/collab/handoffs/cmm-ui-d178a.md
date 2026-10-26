# 交接：D178a（单位和千分位，第一批：三个入口、Care Studio 与工具面板）

日期：2026-10-23。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `f2c9fdae`：D176 的结果树，也就是 `0bd6589f` 加上 D176 补丁 `cmm-ui-D176-侧栏A.patch`（sha256 `ae22f44f…3053791`）。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求

2.0.1 会话转来报告第二节第 5 条，编号 D178。下面摘录的是两次消息里的原话：

- 规则（照 CleanMyMac 和访达）：
  - “容量一律用十进制单位，跟 storageString 一样用 ByteCountFormatStyle 的 .file 样式，跟随区域设置。”
  - “个数一律带千分位：加一个统一入口……把各处直接拼的 "\(n)" 都换成它。”
  - “门槛文案用整数十进制：现在的‘超过 95.4 MiB’应该写成‘超过 100 MB’。”
- 入口：“按含义分三个入口：fileSize 用十进制 .file 样式，memorySize 用 .memory 样式（1024 进位，单位写 GB，跟活动监视器一样），count 用 .formatted() 加千分位。273 处调用逐个按含义迁过去，最后删掉 string”。
- 范围选 (b)：“这次放开小窗和菜单栏相关文件……只改格式化调用和测试里写死的期望字符串（按‘D178＋旧值’注明），不动小窗的布局、采样和刷新逻辑。……交接里请单列你碰过的小窗和菜单栏文件”。
- 证据：
  - ours/01 智能扫描写“51,962”，ours/03 防护页写“51962”；
  - ours/08 云盘写“39997”和“95.4 MiB”；
  - ours/02、10 用 GiB/MiB，ours/06、07 用 MB/GB。

## 2. 分两批交

`ByteFormat.string` 原有 273 处调用，再加上各处直接拼进文字的个数。一次改完，补丁太大、不好审，所以拆开交。原计划三批，小窗和菜单栏那批后来并进了 D178b（原因见 D178b 交接 §2）：

| 批 | 范围 | 状态 |
|---|---|---|
| D178a（本批） | 三个入口；Care Studio 和工具面板自己的文字（`Views/CareStudio`、`Views/Toolbox`） | 本交接 |
| D178b | 其余全部：<br>经典页面（`Views` 下其余文件）、`Services`、`Models`、`Stores`、`Features`；<br>D85 的大文件门槛（“50 MiB/200 MiB/1 GiB”改成整数十进制）；<br>内存页（`LightfieldMemoryPage`、`SystemUtilitiesView`）走内存入口；<br>“不到 1 MiB”这类文案，以及 BenchmarkV7 的“不足 1 GiB”（内存）；<br>小窗和菜单栏（单列文件）；<br>最后删掉 `ByteFormat.string` | 紧接着交 |

空间地图冻结的文件（`CareStudioSpaceLens.swift`、`SpaceMap*.swift`）里没有 `ByteFormat.string`，删它不用等 Disktree 第 3 期。

## 3. 改了什么

### 3.1 三个入口（`Support/ByteFormat.swift`）

- 文件和磁盘（你说的 fileSize）：沿用现成的 `storageString`。它已经有 94 处调用，所以没另起名字。
  - 十进制，`ByteCountFormatStyle` 的 `.file` 样式。
  - 格式样式写的是 SI 的“kB”，这里改成访达和 CleanMyMac 写的“KB”。
- 内存（memorySize）：新增 `memoryString`，`.memory` 样式，1024 进位，单位写 KB/MB/GB。16 GiB 内存显示“16 GB”，跟活动监视器一样。
- 个数：新增 `count(_:)`（Int 和 Int64），`.number` 样式，带千分位（“51,962”）。
- 语言：三个入口都按 App 自己的语言（`ByteFormat.locale`：中文用 zh_Hans，英文用 en_US）。`storageString` 原来默认是系统区域（`.current`）。**这跟你说的“跟随区域设置”不一样**，原因有三条：
  1. 单位词跟着语言走。0 字节在中文界面写“0字节”，英文写“0 bytes”。如果按系统区域，中文界面在英文区域的机器上会出现“0 bytes”。
  2. 测试里设定语言（`CalibrationLanguageScope`）就能得到固定结果，不随跑测试那台机器的区域变。
  3. `L10n.locale` 的英文是 en_US_POSIX，不分千分位，所以没直接用它。
  - 中文和英文的千分位、小数点都是“,”和“.”，在这台机器上看不出差别。你如果还是要跟系统区域，只改 `ByteFormat.locale` 一处就行。
- `ByteFormat.string` 暂时留着，注释写明调用方迁完后删掉（D178b 删）。

### 3.2 迁移（21 个页面文件）

- 容量：58 处 `ByteFormat.string` 按含义换掉。
  - 46 处换成 `storageString`：文件、磁盘、清理量、云盘、聊天文件、扩展、我的活动等。
  - 12 处换成 `memoryString`，全在内存页 `CareStudioMemory.swift`：已用和总量、缓存估计、交换、可收回的预算、释放后的“+X”、前后对比。
- 个数：133 处改走 `ByteFormat.count`，有三类：
  - 文字里直接拼的个数，例如“已检查 \(n) 项”、“\(n) 个文件在这台 Mac 上”、“已处理 x / 共 y”；
  - 卡片的数值，例如 `value: "\(n)"`；
  - 智能扫描卡片里原来的 5 处 `.formatted()`。
- 页面上看得到的变化（举例）：
  - 防护页“已检查 51962 项”变成“已检查 51,962 项”；
  - 云盘“39997 个文件在这台 Mac 上”变成“39,997 个文件在这台 Mac 上”；
  - 云盘“超过 95.4 MiB”变成“超过 100 MB”。门槛 `CloudDriveScanner.largeFileBytes = 100_000_000` 本来就是十进制整数，只是写法变了，扫描行为不变；
  - 垃圾清理标题“2.0 GiB”变成“2.16 GB”，内存页的“GiB”变成“GB”（数值不变，仍是 1024 进位）。
- `CareStudioCountingText.swift` 只改了一处注释里的例子（“2.3 GiB”改成“2.16 GB”）。计数动画按文字里的数字逐位滚动，本来就认千分位和小数点，所以不用改。
- 没动：
  - 空间地图冻结的文件；
  - “30 天”这类天数门槛，它们不是个数；
  - 小窗和菜单栏：本批一个文件都没碰（单列见 §5）。
- **只合 D178a 时还剩两处二进制：** Care Studio 垃圾管理器每一行的大小，以及行下面那句“清空废纸篓后预计释放 X”。它们由经典页面和 Care Studio 共用的两个函数生成：
  - `CleanupMeasurementPresentation.value`，在 `CleanupScanViews.swift`；
  - `CleanupCandidateRowHint.reclaimable`，在 `CleanupScanModels.swift`，默认用二进制。
  - 这两个函数归 D178b 改，所以单独合入 D178a 时，垃圾管理器的行还会写 MiB/GiB，D178b 合入后就一致了。我在 Care Studio 和工具面板里查过对其他共用文字函数的调用，只有这两处。
- `CareStudioJunkResults.swift` 只换了格式化调用。我的基线里没有 D179，所以本批不碰 `coverageNotice` 那一段，合到你的树上不冲突（见 §6）。

## 4. 建议的 DECISIONS 行

| # | 决定 | 影响 |
|---|---|---|
| D178 | 数字照 CleanMyMac 和访达写：文件和磁盘用十进制（`storageString`，KB/MB/GB），内存用 1024 进位但单位写 GB（`memoryString`，同活动监视器），个数带千分位（`count`）；三个入口都按 App 的语言格式化；门槛写整数十进制（“超过 100 MB”）。`ByteFormat.string` 的二进制 KiB/MiB/GiB 按含义迁完后删掉。分 D178a/b/c 三批。 | 全 App 的容量和个数文字 |

## 5. 小窗和菜单栏文件

本批没有碰任何小窗或菜单栏文件（源码和测试都没有）。D178b 会单列。

## 6. 测试

- 改了 2 个测试里的期望。两处原来都用 `ByteFormat.string` 现算期望，现在改用 `storageString`，旁边注释写了“D178＋旧值”。断言没有放宽：
  - `CareStudioRenderReviewTests.testCleanupHeadlineCountsJunkAndNamesTheFilesToReviewApart`：标题里每个大小出现一次，现在按十进制找（这个夹具上是“2.16 GB”，原来是“2.0 GiB”）。“文件待复查不算垃圾”那条否定断言也一起换成十进制。不换的话，它找的是二进制写法，标题里永远没有，这条断言就成了空的。
  - `SmartCareTests.testTheCleanupCardCountsLikeTheJunkResults`：卡片数值“3.24 GB”（原来“3.0 GiB”）。
- 其他测试里还有 `ByteFormat.string` 的地方（约 50 处），对着的都是 D178b 的代码，这批不动，跟着 D178b 改。
- 窗口类测试（display-bound 的 63 个类）我用文本搜索查过：对着 Care Studio 或工具面板的，没有一个写死二进制单位或四位以上的个数。窗口类这次没有跑，见 §7。

## 7. 验证

全部在 Xcode 27.1、`f2c9fdae` 加本批改动上，按 D106 补充②的三段式跑，重活都先拿了 `heavy-build.lock`：

- 第一次 debug 非窗口三段（10-23 10:57–11:03）：主包 4 处失败，都在 §6 那两个测试里，原因是期望还在用二进制写法。改完后单独跑这两个测试类，22 个全过。
- debug 非窗口三段（11:12–11:18）：
  - 主包 XCTest 5658 个 0 失败（29 个跳过）；
  - CombinedStatusIconTests 285 个 0 失败；
  - Swift Testing 135 个通过；
  - 没有通讯录相关行。
- release（11:18–11:51）：
  - release 编译、release 测试目标（`--build-tests -Xswiftc -enable-testing`）编译都通过，本批文件没有新警告；
  - 主包 5403 个 0 失败（28 个跳过）；
  - CombinedStatusIconTests 285 个 0 失败；
  - Swift Testing 135 个通过；
  - 没有通讯录相关行。
- **未做：**
  - 窗口类：“虚拟屏 3 · Claude”还没回来，借不借“虚拟屏 1 · Codex”还在等用户。D176 的三项也还没补跑。
  - 没在真实 app 里亲手看：桌面在你手上做 1:1 对照；也没装测试版。

## 8. 下一步

- D178b，见 §2。
- D176 的窗口类补跑：“虚拟屏 3 · Claude”还没回来，借不借“虚拟屏 1 · Codex”在等用户回复。
