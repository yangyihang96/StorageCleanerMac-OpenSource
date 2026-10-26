# 交接：D207 管理器里的“加入忽略列表”和“放回原处”

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是主会话的 `ea932051`（D207 已合入）；补丁不碰 DECISIONS，也能直接打在 `d2e57b8e` 和主会话当前工作区上。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 做了什么

照 CleanMyMac 的行为（行的右键 “Add to Ignore List / Ignore N items”，之后一条提示带 “Put Back”），文字是我们自己的：

| 管理器 | 哪些行 | 菜单 | 类别 |
|---|---|---|---|
| 清理管理器（含智能扫描清理的下钻） | 右栏每一项；中栏每个小组 | 单项“加入忽略列表”；小组“忽略 N 项” | 按这一项的规则所属 D203 分组：系统、开发者、待确认归 systemJunk，AI 归 aiClutter，邮件归 mailAttachments，废纸篓归 other（`IgnoreCategory.cleanup(for:)`，与扫描同一归法） |
| 杂乱 | 重复文件每一行（右键和“操作”菜单）；相似照片每一张（右键和“查看”菜单） | 加入忽略列表 | 相似照片归 similar，其余归 duplicates |
| 应用更新 | 结果页和管理页的每一行 | 加入忽略列表（已忽略的行不出现） | updates，应用身份（bundle ID＋路径），以后的更新都忽略 |
| 应用管理 | 卸载候选、长期未用的每个应用；残留的每一组 | 应用“加入忽略列表”；残留组“忽略 N 项” | uninstaller；应用按应用身份，残留按路径（与残留扫描一致） |
| 恶意软件结果 | 每一行 | 加入忽略列表 | malware |

提示条：

- 加入后在底部出现，写“已把“X”加入忽略列表”（多项时“已把 N 项加入忽略列表”），带“放回原处”和关闭按钮，8 秒后消失。
- 主窗口里显示在底部，抬高 84 点，避开管理器底栏。
- 恶意软件结果是单独的表单，提示显示在表单里，不会在主窗口再出一条。
- 已经在列表里的项目写“已在忽略列表里”，不给“放回原处”。保存失败时显示忽略列表自己的提示，不隐藏任何行。

## 2. 加入之后当前结果怎么变（不重扫）

做法是：照扫描跳过被忽略项那样，把这几项从当前结果里拿出来，计数照扫描的口径加上。

- 清理：
  - 会话里去掉这些候选（`ScanSession.holdingBack`）；
  - 路径记进 `ignoredPathsByRule`，`ignoredItemCount` 按不重复路径数变；这样之后局部补扫合并时，口径和完整扫描一致；
  - 小组、合计、智能扫描卡片、清理计划都跟着变；
  - 从勾选里去掉，被忽略的项目不会被清理；
  - 某个整目录候选如果包含了刚忽略的路径，也一起拿出来，和扫描对整目录的处理相同；
  - 有清理计划或正在清理时，菜单不可用。
- 应用更新：照检查时的做法标成“已忽略”（`snapshot.applying(to:)`）。行还在，显示“已忽略”；不计入更新数，也不进计划和批次。
- 应用管理：
  - 应用从卸载候选和长期未用里去掉，`ignoredApplicationCount` 加一；
  - 这个应用的残留不受影响：只忽略应用不隐藏残留，和 D207 相同；
  - 残留去掉所选路径，组空了就整组去掉，`ignoredLeftoverCount` 按路径数加；
  - 同时更新内部的快照，下一次 `load` 不会因为“忽略列表变了”而重读、重扫残留。
- 杂乱：
  - 去掉这个文件，计入对应类别的忽略数；
  - 如果它所在的重复组只剩一份，这一份也一起收起：它已经不是重复了，扫描也不会列它，但它不算“已忽略”；
  - 已确认重复组（克隆合并用的 `exactGroups`）同步去掉这些文件，所以不会去合并被忽略的文件。
- 恶意软件：从结果里去掉，计入 `counts.ignored`，从勾选里去掉。

“放回原处”：

- 精确删除这一次加入的条目（`remove(ids:)`），不用 `undoLastAdd()`，以免撤销的是之后在设置里加的条目；
- 然后把仍未被列表覆盖的项目放回原来的位置，计数减回去，原来勾选的照样勾上；
- 结果已经换过（重新扫描、重新载入）时，只删条目、不往新结果里放：新结果按当时的列表生成，下次扫描就会出现。

设置页里的增删照 D207 的原则，下次扫描才生效；当前结果只响应管理器自己的“加入忽略列表”和“放回原处”。

## 3. 改到的文件

- 新增 `Views/CareStudio/CareStudioIgnoreList.swift`：
  - `IgnoreListFeedback`：一次加入可跨类别，记下这次新增的条目 ID，管“放回原处”；
  - `CareStudioIgnoreNote`：提示条；
  - `IgnoreListMenu`：菜单文字；
  - 环境值 `ignoreListFeedback`。
- `Stores/ScanStore.swift`：
  - `ignoreListStore` 可注入：App 里是 `IgnoreListStore.shared`，测试里为空，除非测试自己给一个；`currentIgnoreListSnapshot()` 读它，行为不变；
  - 新增 `ignoreFeedback`；
  - 清理：`ignoreCleanupCandidates`、`cleanupIgnoreCategories`、`canIgnoreCleanupCandidates`；
  - 应用更新：`ignoreAppUpdates`、`canAddAppUpdateToIgnoreList`；
  - 两边各有放回原处。
- `Models/CleanupScanModels.swift`：
  - `mappingCandidates` 改为调用共用的 `rebuilding`，行为不变，`ignoredPathsByRule` 不变时计数不变；
  - 新增 `holdingBack`、`puttingBack` 和 `HeldCleanupCandidate`。
- `Services/IgnoreListStore.swift`：新增 `IgnoreCategory.cleanup(for: CareJunkGroup)`，原来按规则的那个改为调用它，归法不变。
- `Features/MalwareScan/MalwareScanStore.swift`、`Features/DuplicateFiles/Stores/DuplicateFilesStore.swift`、`Features/AppLifecycle/Uninstaller/ApplicationsManagerModel.swift`：各自的 `ignore…` 和放回原处。
  - 应用管理加了列表版本号，放回只进同一份列表；
  - 加了 `replaceLeftovers` 测试接口，与已有的 `replaceEntries` 同类；
  - `DuplicateFilesStore.replaceItemsForTesting` 多一个可选的 `coverage` 参数。
- 视图：`CareStudioJunkManager`、`CareStudioClutter` 与 `DuplicateFilesLightfieldView`、`AppUpdatesView` 与 `AppUpdateLightfieldPresentation`、`ApplicationsManagerView`、`MalwareScanViews` 与 `CareStudioProtection`、`ContentView`（环境值和提示条）。
- 没有新增删除或移动文件的调用，删除与进程清单不用改。

## 4. 没接的地方，以及原因

- “大型和旧文件”“下载”：现在的杂乱管理器里没有这两类行。大文件列表在“文件搬家”里，下载类文件在应用管理的“安装器”里。主会话列的应用管理范围只有卸载候选、长期未用、残留，所以这次都没接。要接的话，搬家列表按 largeAndOld、安装器按 downloads，另排。
- 应用的展开项和残留组里的单个资源：只接了应用行和残留组行，单个资源行没有菜单。
- 空间地图：D207 定的是不按忽略列表过滤，所以没接。

## 5. 测试

都是非窗口测试；没有改动、删除任何旧断言。

- 新增 `D207IgnoreFromManagersTests`，6 条，所有列表都是测试目录里的文件，不碰真实的忽略列表：
  - 反馈：
    - 放回原处只删这一次加入的条目，之后另加的条目保留；
    - 已在列表里时提示“已在忽略列表里”；
    - 一次跨两个类别算一次加入；
    - 没有列表时什么都不做；
    - 菜单文字。
  - 清理：
    - 候选从会话里去掉，候选数、忽略数、`ignoredPathsByRule` 都变，也退出勾选；
    - 条目的类别和路径正确；
    - 放回原处后回到原位置，计数还原，仍是勾选状态。
  - 应用更新：
    - 标成已忽略，退出自动批次；
    - 条目是 updates、应用身份、不带版本；
    - 放回后状态逐项还原。
  - 恶意软件：去掉、计入 ignored、退出勾选，提示显示在表单；放回后还原。
  - 应用管理：
    - 应用去掉后放回原位，勾选还原；
    - 残留组按路径加入、空组去掉、计数变；放回后还原。
  - 杂乱：
    - 一对重复里忽略一份，另一份一起收起，只计 1 个忽略；放回两份都回来；
    - 三份里忽略一份，剩两份仍成组；
    - 相似照片和重复文件的类别分开。
- `CareStudioRenderReviewTests` 新增 `testRendersD207IgnoreNote`：离屏渲染提示条，证据在 `~/Developer/.sc-build/cmm-ui-items-evidence/d207/d207-ignore-note.png`。

## 6. 验证

Xcode 27.1。树是 `ea932051` 加本项，在 heavy 锁里增量编译（含测试目标，窗口测试也编进去了），10-24 22:58–23:06。

- 第一次编译就通过；D207 自己的 3 个测试类照样全过。
- 定向 24 个非窗口类，493 个测试：1 个跳过（原来就跳过的 Setapp 只读审计），1 个失败，不是本补丁引起的：
  - `FeatureLightfieldApplicationPresentationTests.testEmptyUnknownScanDoesNotClaimEverythingIsCurrent`：期望 `All Apps Are Up to Date`，实际是 `Ignored 0 items · All Apps Are Up to Date`。
  - 这句来自 D207 在 `AppUpdateLightfieldPresentation.swift:25`（`emptyMessage`）加的 `summary.ignoredSummary + " · "`。
  - 本补丁在这个文件里只给行加了右键菜单（7 行），没碰这一句，所以基线 `ea932051` 上同样会失败。
  - 是保留“已忽略 0 项”、改测试，还是 0 项时不显示，请主会话（D207 负责方）定，我没动。
- 新加的 7 条（6 条加渲染 1 条）全过。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过。改到的源码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项、具名颜色。
- 截图核对：提示条是深色胶囊，蓝色“眼睛划线”图标，写“已把“com.example.editor”加入忽略列表”，蓝色“放回原处”，右侧关闭按钮。
- 没跑：窗口类（没借屏）。请主会话跑：
  - `CareStudioWindowReviewTests`：清理、杂乱管理器的版式和截图；
  - `FeatureLightfieldApplicationPageTests`：应用管理的行；
  - `FeatureLightfieldFilesContractTests`、`FeatureLightfieldFileMetadataTests`、`FeatureLightfieldFilesPerformanceTests`：重复文件、相似照片的行；
  - `MiniWindowCleanupPresentationTests`；
  - `CareStudioNavigationTests`、`SafeCleanupLayoutTests`：主窗口多了一层提示条的叠加；
  - `SmartScanScopeTests`。
- 没装、没提交。

## 7. 装机后请用 LCU 看

注意：这会写进用户真实的忽略列表（`IgnoreList.json`）。每次看完点“放回原处”撤掉，或在设置“忽略列表”里移除。不删除、不移动任何文件。

1. 清理管理器：
   - 右键右栏一项，点“加入忽略列表”：这一项消失，小组大小和底部合计变小，底部出现提示条；
   - 点“放回原处”：这一项回到原位置，原来勾着的仍勾着；
   - 右键中栏一个小组：菜单写“忽略 N 项”。
2. 杂乱：在重复文件里对一对中的一份点“加入忽略列表”：这一组两份都消失；放回后都回来。
3. 应用更新：右键一行，点“加入忽略列表”：行显示“已忽略”，更新数少一；放回后还原。
4. 应用管理：右键一个应用，点“加入忽略列表”：它从列表消失，摘要里“已忽略 N 项”加一；放回后还原。残留组右键是“忽略 N 项”。
5. 恶意软件（有结果时）：右键一行，点“加入忽略列表”：提示条出现在表单里。
6. 设置“忽略列表”页能看到加入的条目，类别对；点放回原处后条目消失。

## 8. 建议的 DECISIONS 写法（编号由主会话定）

| # | 决定 | 影响 |
|---|---|---|
| D207 补（CMM 接入） | 管理器的行可以右键“加入忽略列表”（多项“忽略 N 项”），之后底部提示带“放回原处”，照 CleanMyMac 的行为，文字是我们自己的。<br>接入范围：清理管理器中栏、右栏；杂乱的重复、相似；应用更新两页；应用管理的应用和残留组；恶意软件结果。类别与扫描同一归法。<br>加入后不重扫：当前结果照扫描跳过的方式拿出这几项，计入“已忽略”，退出勾选，因此不会被清理、合并或更新。<br>“放回原处”精确删除这一次新增的条目，再把项目放回原位、恢复勾选。<br>设置页的增删照 D207，下次扫描生效。大型和旧文件、下载这次没有管理器行，未接。 | `CareStudioIgnoreList`（新）、`ScanStore`、`CleanupScanModels`、三个模型、相关视图；`D207IgnoreFromManagersTests`（新，6 条） |
