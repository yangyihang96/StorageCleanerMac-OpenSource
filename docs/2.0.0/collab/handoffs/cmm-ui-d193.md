# 交接：D193②（空间地图的“可清除空间”一行）和 D193③（气泡名字门槛约 80 点）

日期：2026-10-23。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线树 `d3fce34f`：你合进第 12、13 条后的树。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。D193 的条目由你写，下面是建议的写法。

## 1. 要求（用户 10-23 选定，你转来的原话）

- ②“加一行 (Recommended)”：照 CleanMyMac 单独列出 macOS 需要时会自动腾出的空间（这台 Mac 约 29.6 GB），写明由 macOS 管理、不用手动清理；读数用现有 D173 的可清除空间读取，不新开读取频率。
- ③“降到约 80 点 (Recommended)”：直径不小于约 80 点的气泡显示名字和大小，放不下时末尾截断。

## 2. 改了什么

### 2.1 ② 可清除空间

- 读数：`StorageMapAnalysisResult` 加 `volumePurgeableBytes`（只加，构造参数在最后、默认 0，其他构造处不用改）。`DiskScanner` 在扫描结尾构造结果时多传一个参数，取那一次容量读数的 `reclaimableEstimateBytes`。这次读数本来就带重要用途可用容量，D173 的那种查询每次扫描一次，`volumeAvailableBytes` 也是它算出来的。所以不新开读取，也不加频率，和页头“可用”出自同一个快照。
- 显示（`Views/CareStudio/CareStudioSpaceLens.swift`）：“目录”列表的最后加一行。
  - 左边空出勾选框的位置，图标用 `clock.arrow.2.circlepath`，表示 macOS 会自己处理。没用回收符号，免得像是要人去清理。
  - 名字“可清除空间 / Purgeable Space”，说明“由 macOS 管理，需要时自动腾出，不用手动清理 / Managed by macOS and freed when needed; nothing to clean by hand”，右边是大小。
  - 不能勾选，没有箭头、点不进去，也不放进气泡和方块图。
- 出现的规则（`SpaceLensPurgeable.bytes`，放在 `SpaceLensWorthALook.swift` 末尾）：只在“目录”这一栏、位于磁盘最顶层、没有筛选、扫描的是整块磁盘（内置或外置，不是个人文件夹），而且读到的可清除空间大于 0 时显示。
- 和 CleanMyMac 的差别：它的“可清除空间”节点带一个“Clean Purgeable Space”按钮，跳到性能模块。用户选的是“不用手动清理”，所以这里不放按钮。

### 2.2 ③ 气泡名字

- `LightfieldBubbleLayout.labelThreshold` 从 100 改成 80（`FeatureLightfieldChartGeometry.swift`）。合同测试查的那句 `diameter >= LightfieldBubbleLayout.labelThreshold` 不变。名字仍按自己的字体排，放不下时末尾截断（3S 的做法）。
- 80 点的气泡留给文字的框只有 56 点高。用系统图标的气泡原来图标固定 24 点，加上名字和大小会超出约 10 点。现在显示名字时，系统图标也像应用图标一样按 `pictureSide` 缩小：80 点时 12 点；100 点以上不小于原来的 24 点，外观不变。
- 写法上，缩小放在 `iconSide` 的计算里，`LightfieldOptionIconView(icon: item.icon, pointSize: iconSide)` 这一行不变，两个源码合同测试照旧通过（评审 P2-7：图标按画出的尺寸请求）。

## 3. 测试

- 新增 `SpaceLensPurgeableTests`（非窗口）：
  - 整块磁盘的顶层“目录”列出 29.6 GB；外置磁盘也列出；
  - 子文件夹里、“文件类型”“最大的文件”两栏、有筛选时、个人文件夹的扫描、读数为 0 时，都不列；
  - 中英文案；
  - 读数等于“重要用途可用”减“可用”。
- 新增 `SpaceMapTreemapWindowTests.testTheTopOfADiskEndsWithItsPurgeableSpace`（窗口类）：三个文件夹的磁盘样例，可清除空间 29.6 GB。
  - 这一行在列表框内，排在三个文件夹之后；
  - 同样的数据换成个人文件夹的扫描，没有这一行。
- `testCaptureBlocksReviewEvidence` 加一组截图 `b-purgeable-1024-*`（中文深色、英文浅色），要设 `STORAGE_CLEANER_SPACEMAP_EVIDENCE`。
- 改了的预期（都写了“D193③＋旧值”）：
  - `FeatureLightfieldComponentGeometryTests`：门槛 100 改为 80；
  - `SpaceLensBubbleIconTests`：门槛处的图标 26 点改为 12 点，另加一行 100 点时仍是 26 点。

## 4. 验证

Xcode 27.1，树是 `d3fce34f` 加本批，换树后在 heavy 锁里重编译。

- 非窗口定向（22:24–22:31）：
  - `SpaceLensPurgeableTests`、`SpaceLensBubbleIconTests`、`FeatureLightfieldComponentGeometryTests`、`FeatureLightfieldComponentSourceTests`、`FeatureLightfieldB2ImportSourceTests`、`IndependentFeatureWorkspaceStoreTests`、`FileAnalysisSelectionReclaimTests`、`StorageTreemapLayoutTests`、`UIConsistencyRegressionTests`、`TestPreferenceHygieneTests`、`CareStudioRenderReviewTests`。
  - 第一轮 162 个里 2 个失败：两个源码合同测试按原文查 `pointSize: iconSide` 那一行，我起初把条件写在那一行里了。改成在 `iconSide` 里算（见 §2.2），这两个类连同图标、几何、样式规则的类重跑全过。
- 删除清单、私有 API、窗口类登记三项检查都通过。
- **没跑的**：
  - 完整的非窗口门禁：你说 30 分钟内交就并进你的集成门禁，所以没单独跑；
  - 窗口类：`FeatureLightfieldComponentTests`（气泡名字）、`CareStudioWindowReviewTests`（各页气泡名字不出圈）、`SpaceMapTreemapWindowTests`（新加的这一行）、`SpaceLensSidebarWindowTests`。这一批我没有用户的借屏同意，交给你的窗口全量。新加的那个窗口测试还没在窗口里跑过。
- 没在真实 App 里亲手看；没装测试版。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| D193② | 空间地图整块磁盘的顶层“目录”列表末尾单列“可清除空间”，大小取扫描那次容量读数里的重要用途余量，不新开读取；写明由 macOS 管理、不用手动清理，不能勾选、不进气泡和方块图，不放清理按钮。 | 空间透镜 |
| D193③ | 气泡直径不小于 80 点就显示名字和大小（原 100 点）；显示名字时系统图标随气泡缩小，100 点以上外观不变。 | 空间透镜、文件分析的气泡图 |
