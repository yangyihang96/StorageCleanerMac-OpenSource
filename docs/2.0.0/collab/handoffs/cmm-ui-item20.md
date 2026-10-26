# 交接：报告第四节第 20 条（我的工具）

日期：2026-10-24。工作树：`~/Developer/sc-worktrees/cmm-ui`。基线是第 18 条的结果树 `3269a7a3`。结果树和 sha256 见交付消息。工具链 Xcode 27.1。未提交、未安装、未推送。

## 1. 要求和依据

报告原文：“我的工具：CleanMyMac 3 列、有 New 角标、卡上不写所属模块（cmm/09）；我们 4 列、卡上写所属模块、有收藏星标（ours/09）。”

CleanMyMac 实测（`1比1对照-20261023/cmm/09`，窗口 1200×720 点，按像素量）：

- 3 列，每张约 272×240 点，卡与卡之间约 17 点。
- 卡内：
  - 内边距约 22；
  - 左上角图标约 35；
  - 名字约 17.5 点半粗；
  - 说明约 15 点、行高 20、最多 3 行；
  - 右下角是白色圆角矩形按钮，高约 31、圆角约 7，写 Scan / Open / Learn More。
- 卡上不写所属模块，静止时也没有收藏控件。
- “New”是洋红小胶囊，约 32×15 点，白色粗体约 11 点，压在卡片左上角、往外伸约 6 点；带 New 的四张排在最前。
- 侧栏“我的工具”图标左上角也有一个“New”。

CleanMyMac 5.7.2 安装包（`ToolboxModule.framework`，只读，没有运行它）：

- 文字表：
  - 有“收藏 / 已收藏”（`favorite_save` / `favorite_saved`）、“收藏夹 / 其他工具”、“找到 %@ 项”、“新”（`browser_care_card_badge_new`）；
  - 没有“全部工具”。
- 图片：空心和实心的星（`favorite`、`favorite_fill`，14 点）。
- 符号名（以下是推断，没有运行验证）：
  - 收藏控件 `ToolboxIntroFavoriteControl` 带 `isHovered`，卡片有 `HoverTrackingView`，所以推断收藏控件在悬停时出现；
  - `ToolboxBadgedFirstOrderProvider`：带角标的工具排在前面；
  - `hasUntriedNewTool`：还有没试过的新工具，推断用于侧栏的 New。

所以收藏不是我们独有的，CleanMyMac 也有，只是平时不显示。这次保留收藏（D154），改成它的样子。

## 2. 改了什么

### `Views/CareStudio/CareStudioMyTools.swift`

- 网格：
  - 固定 3 列等宽。原来是 `adaptive(minimum: 228, maximum: 360)`，宽窗口会排 4 列；
  - 改用 `Grid`，同一排卡片一样高，网格高度按内容（`fixedSize`），窗口再高卡片也不拉长；
  - 最后一排不满时用空格占位，列宽不变。
- 卡片 `CareStudioToolCard`：
  - 内边距 22（原 16）；插画仍是 46，可见部分约 37（CleanMyMac 的图标约 35）；
  - 名字 17 点半粗（原 15）；说明 14 点、行距 3、最多 4 行（原 12 点）；
  - 去掉所属模块那一行，搜索仍能按模块名找到；
  - “打开”改为右下角的白色圆角矩形 `CareStudioToolOpenButton`：高 30、圆角 7、14 点 medium，颜色和白色胶囊按钮相同；
  - 最小高度 232（原 196），同一排按最高的那张。
- 收藏：
  - 右上角“☆ 收藏 / ★ 已收藏”（星加文字），只在指针在卡片上时出现；
  - 实心星用 `CareStudioInk.badgeAttention` 的黄，原来是文件里自己写的颜色；
  - 右键菜单“收藏 / 取消收藏”；读屏时“打开”按钮上有“收藏 / 取消收藏”动作；
  - 没有收藏时卡片上方不写标题（原来写“全部工具”）；有收藏时仍是“收藏”在上、“其他工具”在下；全部收藏时不再出一个空的“其他工具”。
- “新”：
  - `Tool.isNew` 标出这一版新加的三项：维护任务（D161）、扩展（D160）、聊天文件（D162）；
  - 带“新”的排在最前（`MyToolsCatalog.ordered(tried:)`）；从“我的工具”打开一次后去掉“新”，回到原来的位置；
  - 打开过的记在 `myTools.tried.v1`，和收藏一样存成逗号分隔的 id；
  - 角标 `CareStudioNewTag`：洋红胶囊、白色 11 点粗体，写“新 / New”，压在卡片左上角、往外伸 7 点。
- `MyToolsCatalog` 新增 `triedDefaultsKey`、`columns`、`ordered(tried:)`、`showsNewTag`、`hasUntriedNewTool`、`sections`、`rows(of:)`；`favorites(from:)` 改名 `ids(from:)`，收藏和打开过的共用。

### `Views/SidebarView.swift`

- 三项里还有没打开过的，侧栏“我的工具”图标左上角带同样的“新”，中心在图标的左上角；全宽侧栏和图标栏都有。
- 读屏读出“有新工具”。
- 第 16 条的进度饼在右上角，两者不冲突。

### `Views/CareStudio/CareStudioTheme.swift`

- 新增 `CareStudioInk.newTag`：夜间 #B44AAE、日间 #A23C9C。
- 比 CleanMyMac 的 #D06ACB 深一些，让白字对比度到 4.6:1（夜间）和 5.7:1（日间）。

### 没改

- 标题、副标题、搜索框：用的是共用的 `CareStudioHubHeader`，“我的活动”也在用。CleanMyMac 的标题更大，但不在这一条里。
- 按钮文字仍是“打开”：我们点了是进页面，不直接开始扫描。
- 只有从“我的工具”打开才算“打开过”；从应用管理等模块页进入扩展这些页面，不去掉“新”。

## 3. 测试

- 新增 `MyToolsCatalogTests`（非窗口）：
  - 新的三项排最前，其余照原来的顺序；
  - 打开一项后它不再带“新”，回到原位；旧工具从不带“新”；
  - 侧栏的“新”：三项都打开过才消失；
  - 3 张一排，最后一排放剩下的；
  - 没有收藏时没有标题；有收藏时是“收藏”“其他工具”；全部收藏时没有空的“其他工具”；
  - id 的存取。
- `CareStudioModuleShellRenderTests`：
  - 新增 `testRendersMyToolsLikeCleanMyMacForReview`：
    - 用临时偏好域，渲染两种页面：“都没打开、没收藏”和“都打开过、收藏两项”，中英文、深浅色，另加一张图标栏；
    - 单张卡片的像素检查：新工具卡的左上角是洋红，旧工具卡没有。
  - 原 `shell-mytools-tall` 截图的高度从 1320 改为 1600：卡片变高后 1320 放不下，会画成空白的滚动区。这只是截图尺寸，没有断言。

## 4. 验证

Xcode 27.1，树是第 18 条结果树加本批，在 heavy 锁里增量编译，10-24 03:13–03:15。

- 非窗口定向 6 个类，114 个测试，0 失败：MyToolsCatalogTests（新增）、CareStudioModuleShellRenderTests、SidebarBadgeTests、UIConsistencyRegressionTests、CareStudioToolboxWiringTests、PrivacyCleanupPresentationTests。
- 之后只改了测试里的截图尺寸和语言范围：“已收藏”那组 1600 点放不下，退成了画不出来的滚动区；图标栏那张原来没放进中文范围。改完重跑 MyToolsCatalogTests 和 CareStudioModuleShellRenderTests，19 个测试 0 失败（03:17）。
- 静态检查：窗口类登记（D106）、删除与进程清单、私有 API 都通过；没有新增删除调用；新代码里没有 `.font(.caption…)`、`.buttonStyle(.plain)`、工具栏项。
- 截图核对（`~/Developer/.sc-build/cmm-ui-items-evidence/item20/`）：
  - `mytools-new-*`：3 列；维护任务、扩展、聊天文件排在最前，左上角带“新”；卡上没有所属模块；静止时没有收藏控件；“打开”是右下角的圆角矩形（夜间白底黑字，日间深底白字）；卡片上方没有标题；侧栏“我的工具”图标左上角带“新”；英文写“New”。
  - `mytools-saved-*`：“收藏”（性能测试、内存管理，第三列空着、列宽不变）在上，“其他工具”在下；三项新工具回到原来的位置，不带“新”；侧栏也没有“新”。
  - `mytools-new-rail-zh-dark`：图标栏里“我的工具”带“新”。
  - `mytools-card-new-dark` / `mytools-card-dark`：单张卡片有角标和没角标的对照。
- 没验证的：
  - 悬停时出现“收藏 / 已收藏”、右键菜单、读屏动作：离屏渲染没有指针，也不能点。
  - 窗口类：会经过我的工具页和侧栏的窗口类交给主会话的窗口全量，这一条用户没同意我借屏。
  - 没在测试版里亲手看；没装、没提交。

## 5. 建议的 DECISIONS 写法

| # | 决定 | 影响 |
|---|---|---|
| 第 20 条 | 我的工具照 CleanMyMac：固定 3 列，卡上不写所属模块，“打开”是白色圆角矩形。收藏保留：“收藏 / 已收藏”只在悬停时出现，右键菜单和读屏也能收藏；没有收藏时卡片上方不写标题。这一版新加的扩展、维护任务、聊天文件带“新”并排在最前，从我的工具打开一次后去掉；还有没打开过的时，侧栏“我的工具”也带“新”。 | 我的工具页、侧栏 |
