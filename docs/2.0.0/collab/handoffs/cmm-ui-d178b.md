# 交接：D178b（单位和千分位，第二批：其余页面、服务、模型、小窗和菜单栏，删掉旧入口）

日期：2026-10-23。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `a6e86238`：D178a 的结果树。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求

同 D178a 交接 §1（2.0.1 会话转来的 D178 规则、三个入口、范围 (b)）。本批做完剩下的部分：
- 273 处 `ByteFormat.string` 按含义迁完，然后删掉它；
- 门槛文案写整数十进制；
- 小窗和菜单栏只改格式化调用和测试里的期望（“D178＋旧值”）。

## 2. 原计划的 c 并进本批

D178a 交接里说分 a/b/c 三批。动手后发现，小窗和菜单栏按 D128 用的是 iStat 的格式（`IStatNumberFormat`）：
- 内存和速率 1024 进位，磁盘 1000 进位；
- 单位本来就写 KB/MB/GB；
- 没有用 `ByteFormat.string`。

所以 c 只剩七处（§5），就并进本批，少跑一轮门禁。

## 3. 改了什么

### 3.1 容量（`ByteFormat.string` 迁完）

- 磁盘和文件大小改走 `storageString`，约 220 处。经典页面、服务、模型、`ScanStore`、各功能模块、导出的 Markdown 清单都算在内。
- 内存改走 `memoryString`，27 处：
  - 经典内存页 `LightfieldMemoryPage` 全部；
  - `SystemUtilitiesView` 里的内存面板（优化结果、释放建议、进程选择、只读进程行、可选应用行），以及“已用 / 总量”摘要。摘要原来手算 GiB，写“41.3 / 48.0 GiB”，现在写“41.3 GB / 48 GB”；
  - `ScanStore` 的“空闲内存增加”；
  - `SystemMonitorService` 的内存“已用 / 物理”。
- 三处把 `ByteFormat.string` 当函数传的地方，改成闭包。
- 删掉 `ByteFormat.string`。现在源码里一处都不剩，编译器保证不会再有人用到它。

### 3.2 门槛和手写的单位

| 位置 | 原来 | 现在 |
|---|---|---|
| 大文件清单门槛（`LargeFileThreshold`，D85） | 50 MiB / 200 MiB / 1 GiB，按二进制字节判断 | 50 MB / 200 MB / 1 GB，按十进制字节判断（50,000,000 等）。档位名 `mib50` 这些存在偏好里，所以不改名；说明文字改成“1 MB = 1,000,000 字节，1 GB = 1000 MB” |
| “预计释放明显少于大小”（`CleanupReclaimableEstimate.isNoticeable`）和两处“不到 1 MiB”文案 | 1 MiB（1,048,576） | 1 MB（1,000,000） |
| 兼容测速的流量说明 | “约 120 MiB，最大预算 128 MiB” | 用 `storageString` 写：“约 125.8 MB，最大预算 134.2 MB” |
| 跑分预检“可用内存不足” | “不足 1 GiB” | “不足 1 GB”（内存，阈值仍是 1 GiB） |

**请注意两处判断变了：**
- 大文件门槛：1 GB 那档比原来低 7.4%，200 MB 那档低 4.6%，所以清单里会多出刚过门槛的文件；
- “明显少于”的下限从 1,048,576 字节变成 1,000,000 字节。

不这样改的话，界面写“50 MB”，实际却按 52.4 MB 判断，文字和行为对不上。这两处推翻了 D85 写的“单位一律按二进制”。你 10-23 已经回复同意，同意的还有 §3.3 删掉 `OperationByteStyle`、§3.5 网络速率改用 `IStatNumberFormat.bandwidth`。

### 3.3 去掉“每页一种单位”的开关

- `OperationByteStyle`（P2-1：清理计划、卸载等页面用二进制，文件分析用十进制）删掉了。现在全 App 都是十进制，这个开关没有存在的必要。确认表、完成回执、清单行都直接用 `storageString`。
- `CleanupCandidateRowHint.reclaimable` 的 `format:` 参数也去掉了，原因相同。D178a 漏了一处：Care Studio 垃圾管理器的行注释（“清空废纸篓后预计释放 X”）调的是这个函数，默认走二进制，所以 D178a 之后它还写 MiB。这批一起改成了十进制。

### 3.4 个数（千分位）

- 文字里直接拼的个数，约 800 处改走 `ByteFormat.count`：
  - 变量名是 `xxxCount` 或 `.count` 的；
  - 紧跟量词的（“\(n) 个文件”“\(n) records”）。中文那半改了，同一句英文那半也一起改。
- 共用的文字函数改在源头：
  - `L10n.items`、`englishCount`、`itemBytes`、`greenCountDescription`、`bulkTrashMessage`；
  - 浏览记录的 `BrowserPrivacyCountText`（页面数、访问次数、列表表头）。
- 排除了不是给人看的地方：
  - 浏览器历史 SQL 里拼的列表达式；
  - 清理证据代码 `frozen-trash-entry-count:`；
  - 应用包指纹的哈希输入；
  - `.task(id:)` 的标识；
  - 跑分校准的参考描述；
  - 日志。

### 3.5 速率

`SystemMonitorService` 的网络速率会直接显示在菜单栏状态项里。它原来用 `ByteFormat.string` 拼“1.6 MiB/s”，现在改用 `IStatNumberFormat.bandwidth`，跟菜单栏其他速率一样（D128，“1.6 MB/s”，1024 进位）。

### 3.6 没动

- `IStatNumberFormat`（D128，小窗和菜单栏照 iStat 写）。你说过做菜单栏对照时再确认 CleanMyMac 的内存是不是 1024 进位，到时候按对照结果改。
- 本来就是十进制、但没走 `ByteFormat` 的几处 `ByteCountFormatter`（应用更新、跑分页）。它们和 `storageString` 的区别只在 0 的写法（“Zero KB”对“0 bytes”）。
- 已经用 `.formatted()` 加了千分位的个数（例如清理计划规模提醒）。它们跟系统区域，`ByteFormat.count` 跟 App 语言，在中文和英文下写法相同。
- MSeries 的合约字符串和测试文件名（“LZFSE1MiB”“fixed-64MiB.bin”）。它们是协议标识，不是界面文字。

## 4. 建议的 DECISIONS 行

D178a 交接 §4 那一行不变。另外补两句：
- “D85 的大文件门槛改为 50 MB / 200 MB / 1 GB（十进制字节）；`OperationByteStyle`（P2-1）取消，全 App 写十进制。”
- “菜单栏的网络速率与其他速率一样用 `IStatNumberFormat`（D128）。”

## 5. 小窗和菜单栏文件（单列）

只改了格式化调用，没动布局、采样和刷新：

| 文件 | 改了什么 |
|---|---|
| `Support/MiniWindowCleanupPresentation.swift` | “默认可清理 \(n) 项”中英两半的个数加千分位 |
| `Support/MiniWindowDemoData.swift` | 演示数据里风扇个数加千分位 |
| `Views/MenuBarAdvanced/GeekMemoryView.swift` | 已选应用数、退出结果三项（正常退出、跳过、失败）的个数；“进程组 · 前 x/y 项”保持原样（见 §6） |
| `Views/MenuBarAdvanced/GeekSensorsView.swift` | 风扇数、核心数、传感器数 |
| `Views/MenuBarAdvanced/MenuBarAdvancedComponents.swift` | 清理记录“\(n) 项” |
| `Views/MiniWindowConfigurationSettingsView.swift` | 设置里网络预览的示例文字：“410 KiB/s”“3.6 MiB/s”改成面板实际的写法“410 KB/s”“3.6 MB/s” |
| `Services/SystemMonitorService.swift`（不是小窗文件，但输出显示在菜单栏状态项） | 网络速率改用 `IStatNumberFormat.bandwidth`；内存“已用 / 物理”改走 `memoryString` |
| `Tests/…/MiniWindowCleanupPresentationTests.swift` | 测量下限“至少 X”的期望改走 `storageString`，注明 D178＋旧值 |

另外，`L10n.items` 等共用函数小窗也在用，所以小窗里的“N 项”同样有千分位。三位以内的数写法不变。

## 6. 测试

改了 21 个测试文件里的期望，每处都注明了“D178＋旧值”，没有放宽（其中两个窗口类合同测试见 §7）：
- 原来用 `ByteFormat.string` 现算期望的，改用被测代码现在的入口（`storageString` 或 `memoryString`）。涉及 FileStorageSharing、SimulatorCleanup、SystemMaintenance、SystemUtilitySafety、CleanPlanScaleAlert、OperationConfirmationModel、ReclaimableOutsideCleanupScan、MiniWindowCleanupPresentation、MemoryReclaimer、DesignSystemV2；
- 检查源码文字的，改查新入口：OperationConfirmationContract、UIConsistencyRegression、MemorySelectionSummary；
- 被删掉的 API：
  - `facts.byteStyle == .storage` 改成“容量文字里没有 iB”；
  - `OperationByteStyle` 两条映射断言删掉，上面几行已经用 `storageString` 检查了同一组数字；
  - `testARowNoteUsesThePagesByteFormat` 改名为 `testARowNoteWritesDecimalSizes`，检查注释里是十进制、没有 MiB；
- `RuntimeUIRound201Tests`：内存摘要按共同单位拆分，单位从“GiB”变成“GB”；
- 新增 `SystemMonitorServiceTests.testByteFormatWritesSizesAndCountsAsFinderAndActivityMonitorDo`，把三个入口的写法钉住：
  - “2 KB”（访达的 KB，不是 SI 的 kB）、“100 MB”、“0 bytes”/“0字节”；
  - 内存“16 GB”“1.5 GB”；
  - 个数“51,962”“1,234,567”“7”。
  - 原来那条 `ByteFormat.string(…) == "1.0 GiB"` 随函数一起删掉，旁边注明了。
- 第一轮 debug 门禁又查出 13 个测试共 21 处失败，逐个处理如下：
  - `LargeFileThresholdTests`（D85 的门槛测试）：字节数、档位名、说明文字、两处“含 50 MB / 1 GB”的期望都改成十进制。测试名改为 `testThreeDecimalThresholdsWithTheDefaultInTheMiddle`，原来是 `testThreeBinaryThresholdsWithTheDefaultUnchanged`。
    - 边界测试：50,000,000 不是 4 KiB 的整数倍，所以“刚到门槛”的文件取门槛以上第一个整块（50,003,968 字节），“少 4 KiB”的那个照旧不计入。原来门槛 50 MiB 本身就是整块，可以直接用它。这样仍然是“刚好够计入、少一块不计入”。
  - `CleanupHistoryServiceTests`：清理记录 Markdown 里的“4 KiB”改成“4 KB”。
  - `CleanupDefaultSelectionPolicyTests`：“不到 1 MiB”改成“不到 1 MB”。
  - `MSeriesV11PersistenceTests`：跑分历史上限的期望从 1000 改成 1,000（用 `ByteFormat.count` 算）。
  - `SystemUtilitySafetyTests.testActionMessagesSeparateTrashMoveFromFreedSpace`：检查源码文字，期望改成带 `ByteFormat.count(movedCount)`。
  - 其余三处退回了源码，没有改测试：更新来源个数“x/y”（设置）、浏览记录备份保留份数、小窗内存“进程组 · 前 x/y 项”。这三个数都不会超过三位，加不加千分位写法一样；合同测试钉的是源码原文，退回比改合同干净。其中小窗那一处退回后，GeekMemoryView 只剩已选应用数和退出结果三项。

## 7. 验证

全部在 Xcode 27.1、`a6e86238` 加本批改动上，按 D106 补充②的三段式跑，重活都先拿了 `heavy-build.lock`：

- 增量编译：两处把字符串当个数的地方编译报错，退回原写法后通过，见下：
  - 电池循环次数，改成在源头用 `ByteFormat.count`；
  - 浏览记录“已选择 \(visits)”，`visits` 本身是一句文字。
- 第一轮 debug 非窗口三段（10-23 11:57–12:04）：主包 21 处失败，处理见 §6。改完后单独跑这 10 个测试类，357 个全过。
- debug 非窗口三段（12:06–12:13）：
  - 主包 XCTest 5659 个 0 失败（29 个跳过，比 D178a 多出的 1 个是新加的格式测试）；
  - CombinedStatusIconTests 285 个 0 失败；
  - Swift Testing 135 个通过；
  - 没有通讯录相关行。
- release（12:13–12:59）：
  - release 编译、release 测试目标（`--build-tests -Xswiftc -enable-testing`）编译都通过，本批文件没有新警告；
  - 主包 5404 个 0 失败（28 个跳过）；
  - CombinedStatusIconTests 285 个 0 失败；
  - Swift Testing 135 个通过；
  - 没有通讯录相关行。
- 窗口类：借“虚拟屏 1 · Codex”跑（2560×1440 点，用户 10-23 同意借用；本批和 3S 的窗口类跑完后一起归还）。跑在 D176＋D178a＋本批的树上：
  - 窗口全量（12:59–13:29，设了截图目录）：632 个通过、1 个跳过、4 个失败。
    - 其中 2 个是本批的：`FeatureLightfieldContractTests.testRoundSixPresentationContracts` 和 `StartupItemsDashboardContractTests.testManagementListKeepsAllResultsInNativeScrollWithFixedHeadersAndStatus`。它们核对源码原文，原文里的个数现在走 `ByteFormat.count`。期望已按“D178＋旧值”改，文件也算进本批（所以本批共 21 个测试文件）。重跑通过（13:32–13:36）。
    - 另外 2 个是 D176 的测试，修正另外交，见 3S 交接。
  - 窗口全量的截图里单位都对，例如清理管理“1.84 GB”“322 MB”、已选合计“2.16 GB”，内存结果页“+3 GB”“1.25 GB → 4.25 GB”。
- 未做：没在真实 app 里亲手看（桌面在你手上做 1:1 对照）；没装测试版。

## 8. 下一步

- 报告第四节第 12、13、16、14、17、15、18、20 条。
- D176、D178 的窗口类补跑：等“虚拟屏 3 · Claude”回来，或用户同意借屏。
