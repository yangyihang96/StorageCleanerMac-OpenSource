# 交接：第 19 次 A（D223 杂乱首页说明、D224 提醒文案改成自己的话、D225 其他位置的应用加入忽略列表）

- 会话：cmm-ui（CleanMyMac 界面逆向，D154 车道）
- 基线：9fb77d01（第 18 次最终门禁树）
- 补丁：`cmm-ui-第19次A-D223D224D225.patch`（sha256 和结果树随交付消息给出，本文件在补丁里，不含自己的哈希）
- 本交接在仓库里的位置：`docs/2.0.0/collab/handoffs/cmm-ui-build19-a.md`
- 未提交、未安装；没有用 LCU（按通知，重启前不用）。

## 一、D223 杂乱首页说明

- 位置：`CareStudioTheme.swift` 的 `CareStudioModule.clutter.subtitle`（杂乱首页标题下面那一行）。
- 原文：“找出内容完全相同的文件和相似的照片，每组至少留一份。”
- 现文：“整理重复文件、相似照片、大型和旧文件以及聊天文件；重复文件每组至少留一份。”
  - 英文：“Sort out duplicates, similar photos, large and old files, and chat files. At least one copy of each duplicate group stays.”
- 依据：
  - CleanMyMac 杂乱首页在说明下面列出类别名（`intro_category_*`：重复文件、相似图片、大型文件、下载项）。
  - 我们照这个做法，用自己的话把杂乱现有的四类列全：重复文件、相似照片、大型和旧文件、聊天文件。没有照抄它的句子。
- “每组至少留一份”改为明确只说重复文件。
- 留意：从“我的工具”进“相似照片”时，首页用的也是这一行（第 19 次之前就是这样）。现在列出四类，对相似照片页也说得通，所以没有另写。

## 二、D224 提醒文案对照与改写

### 怎么核对的

- 读本机 CleanMyMac 全部 44 个 zh-Hans 和 en 字符串表（`plutil` 转 JSON）。
- 把三个文件里每一处 `L10n.text` 的中英文都拿去比对，先找完全相同的，再找相似度 0.72 以上的：
  - 提醒卡片 `AppLifecycleAlertCard.swift`；
  - 卡片上的忽略菜单 `AppLifecycleIgnoreList.swift`；
  - 提醒设置一节 `AppLifecycleReminderSettingsSection.swift`。
- 结论：工单点到的那两句确是照抄，同一节和卡片上还有同类问题，一起改了。

### 逐条对照

| # | 位置 | 原文（中 / 英） | CleanMyMac 字符串（键） | 判断 | 现文（中 / 英） |
|---|---|---|---|---|---|
| 1 | 设置：开关 | 提示以正确的方式彻底卸载应用程序 / Offer to uninstall applications correctly | 中文是它的标题“以正确的方式彻底卸载应用程序”前面加“提示”；英文与 `Settings_Notifications_CorrectlyUninstallApplications_Title` 完全相同 | 照抄 | 应用放进废纸篓时，提醒清理它的残留 / Remind me to remove an app's leftovers when it goes to the Trash |
| 2 | 设置：开关说明 | 如果您将某款应用程序放入废纸篓中，会提示您将其正确卸载。 / If you put an application into Trash, you will be offered to uninstall it correctly. | `Settings_Notifications_CorrectlyUninstallApplications_Description`：中文只比它少“那么”二字，英文完全相同 | 照抄 | 把应用拖进废纸篓后，菜单栏会提醒你找出它留下的设置和缓存等文件，一起移除。 / After you drag an app to the Trash, a reminder in the menu bar helps you find the settings, caches and other files it left and remove them too. |
| 3 | 设置：废纸篓阈值 | 废纸篓大小超过此值时发出通知： / Notify if Trash size exceeds | `Settings_Notifications_TrashSizeExceeds_Title`，中英完全相同 | 照抄 | 废纸篓超过这个大小时提醒： / Remind when the Trash grows past |
| 4 | 设置：空间阈值（第 18 次 D220 写的） | 可用空间低于此值时发出提醒： / Remind when free space falls below | `Settings_Notifications_FreeSpaceLow_Title`：可用空间小于此值时发出警告：（相似 0.79，句式相同） | 不是照抄，但跟着第 3 条的句式；一起改成同一种说法 | 可用空间不足这个值时提醒： / Remind when free space drops below |
| 5 | 卡片：应用进废纸篓·标题 | 以正确的方式彻底卸载应用程序 / Uninstall applications correctly | `TrashedApps_Issue_Title`，中英完全相同 | 照抄 | 卸载还差一步 / Finish the Uninstall |
| 6 | 卡片：应用进废纸篓·说明 | 移除废纸篓中的应用程序以及所有相关残留项。 / Remove trashed applications along with all related leftovers. | `TrashedApps_Issue_Description`，中英完全相同 | 照抄 | 放进废纸篓的应用还留着设置、缓存等文件，可以一并找出来移除。 / Apps in the Trash still leave settings, caches and other files behind; find and remove them too. |
| 7 | 卡片：应用进废纸篓·按钮 | 卸载... / Uninstall... | `TrashedApps_Issue_Uninstall_ButtonTitle`，中英完全相同 | 照抄 | 查看残留… / Review Leftovers…（按钮只打开卸载页去审阅残留，这个说法也更准） |
| 8 | 卡片：废纸篓·标题 | 是时候清倒废纸篓了！ / It’s time to empty your Trash! | `TrashSize_Issue_Title`，中英完全相同 | 照抄 | 废纸篓占了不少空间 / The Trash Is Taking Up Space |
| 9 | 卡片：废纸篓·说明 | 废纸篓中文件的大小已超过您设置的上限 %@。 / The size of files in your Trash has exceeded the %@ limit you have set. | `TrashSize_Issue_Description`，中英完全相同 | 照抄 | 废纸篓里的文件已超过你设的 %@；清倒后才会真正腾出这些空间。 / Files in the Trash are over the %@ you set; the space comes back once the Trash is emptied. |
| 10 | 卡片：清倒进行中 | 正在释放… / Freeing Up… | `Monitor_Detailed_Storage_TrashBin_Action_FreeingUp`：正在释放… / Freeing Up... | 照抄 | 正在清倒… / Emptying… |
| 11 | 卡片：忽略菜单 | 一天 / For a day | `Issue_Alert_Ignore_Option_1Day`，中英完全相同 | 照抄（选项名） | 一天内不再提醒 / Not for a Day |
| 12 | 同上 | 3 天 / For 3 days | `Issue_Alert_Ignore_Option_3Days`，英文完全相同 | 照抄（选项名） | 3 天内不再提醒 / Not for 3 Days |
| 13 | 同上 | 一周 / For a week | `Issue_Alert_Ignore_Option_1Week`，中英完全相同 | 照抄（选项名） | 一周内不再提醒 / Not for a Week |
| 14 | 同上 | 直到明天 / Until tomorrow | `Issue_Alert_Ignore_Option_UntilTomorrow`，中英完全相同 | 照抄（选项名） | 今天不再提醒 / Not Again Today |
| 15 | 同上 | 永久 / Forever | `Issue_Alert_Ignore_Option_Forever`，中英完全相同 | 照抄（选项名） | 以后都不再提醒 / Never Remind Me |

### 对上了但保留的（系统或通用词，不是 CleanMyMac 自己的句子）

- “清倒废纸篓 / Empty Trash”：和它的 `TrashSize_Issue_EmptyTrash_ButtonTitle` 相同，但这是访达自己的菜单命令名。
- “忽略 / Ignore”：和 `Issue_Alert_Ignore_Option_Ignore` 相同，但这是单个通用动词，本应用的忽略列表、“已忽略的提醒”都用它。
- “废纸篓 / Trash”“好 / OK”“取消 / Cancel”：系统通用词。

### 没对上的（本来就是我们写的）

- 卡片：“另有 N 个应用”“N 项 · 大小”“在访达中打开废纸篓”、D23 清倒确认里的各句、“已释放 X”，以及 D219/D220 两张卡的全部文字。
  - “已释放 X”和它最像的是“内存已释放”，是另一句话。
- 设置：“废纸篓当前大小”“需要“完全磁盘访问权限”才能读取”“启动磁盘当前可用”“已忽略的提醒：N 项”“重置已忽略的提醒”、节标题、脚注、重置确认的两句。

### 范围外顺带说一下

- “扫描提醒”的频率选项“每 3 天”等，与 CleanMyMac 的 `Settings_Notifications_SmartCareReminder_Option_*` 相同。这是 D219 按工单“选项改成和 CleanMyMac 一样”做的，都是短选项名，没动。要改请告诉我。
- 代码注释里仍写着 CleanMyMac 对应的键名和英文名，用来说明出处，不是界面文字。

## 三、D225 其他位置的应用：右键加入忽略列表

- 应用行（同一标识合成的一行）右键：“加入忽略列表”，有几份副本时显示“忽略 N 项”，把这个应用所有副本的路径都加入。
- 展开后的单份路径行右键：在原有“复制路径”“在 Finder 中显示”之外，加“加入忽略列表”，只加这一份。
- 按路径加入，类别“卸载”（`IgnoreListTarget(path:)`，不带应用标识）。
  - 和 D207、D215 一样：立即从列表里拿掉，计入这一类的“已忽略”；
  - 提示条上的“放回原处”把它们放回来，原来勾着的仍勾着；
  - 以后重新扫描，照忽略列表继续不列。
- 做法：模型新增 `ignoreOtherApplications(_:feedback:)`。
  - 加入后用新的忽略列表把完整扫描结果重新分组（分组本来就按忽略列表过滤）；
  - 放回原处同理；顺序由分组规则决定，所以放回后会回到原位置。
- 只改列表：D212 的合并、D218 的 `bundleOnly`（不带相关文件）都没动，测试里也核对了删除请求仍只有应用本身。
- `ApplicationsManagerView.swift` 没改：提示条对象由 ContentView 放在环境里，行视图直接读。
- 留意：单份路径行原有的“复制路径”“在 Finder 中显示”是 D218 的写法，和别处的“拷贝路径”“在访达中显示”不一致。这次没改，要统一请告诉我。

## 四、测试

- 新增 `ApplicationsManagerD225Tests`，3 条：
  - 应用行加全部副本：只按路径、类别“卸载”，提示“已把 2 项加入忽略列表”，已安装的应用不受影响；放回原处后全部回来，原来勾着的仍勾着，列表清空。
  - 副本行只加那一份：另一份留在行里；删除请求仍只有应用本身（`bundleOnly`，无相关文件）；重新扫描后仍不列。
  - 列表里没有的路径什么也不加，重复的路径只加一次。
- 新增 `WordingD223D224Tests`，3 条：
  - 杂乱首页说明的中文全文、列出四类、“每组至少留一份”只说重复文件；
  - 三个文件的代码里（跳过注释）不再出现第二节表里那些照抄的句子和选项名；
  - 忽略菜单五项和按钮的中文。
- 没有删除或改动任何已有断言（旧文字没有测试断言过）。
- 跑过的定向非窗口测试（Debug，`--disable-swift-testing`）：
  - 19 类 433 条，0 失败，1 条跳过（只在打开真机开关时跑）：AppLifecycleReminderD219D220Tests、AppLifecycleReminderTests、ApplicationsManagerD209D212Tests、ApplicationsManagerD218Tests、ApplicationsManagerD225Tests、ApplicationsManagerTests、CareStudioModuleShellRenderTests、CareStudioRenderReviewTests、ClutterLargeOldFilesD221Tests、CompetitiveParityContractTests、D207IgnoreFromManagersTests、D64DeclutterAContractTests、PrivacyCleanupPresentationTests、SettingsIgnoreListPageTests、SettingsSourceContractTests、StartOverTests、SystemUtilitySafetyTests、UIConsistencyRegressionTests、WordingD223D224Tests；
  - 另补 D207 忽略列表的 4 类 27 条，0 失败：D207IgnoreListStoreTests、SettingsIgnoreListD207Tests、AppUpdateIgnoreD207Tests、D207IgnoreScannerTests。
- 静态检查：`display_bound_tests.py --check`、`check_deletion_process_inventory.py`、`check_private_api.py` 均通过。

### 请主会话跑的窗口类

- `CareStudioWindowReviewTests`、`ConceptLandingNativeLayoutRegressionTests`、`ToolboxWindowReviewTests`：杂乱首页（和相似照片首页）的说明变长了。
- `SettingsLightfieldGeometryTests`：提醒一节的开关文字和说明换了，英文变长。
- `FeatureLightfieldApplicationPageTests`、`FeatureLightfieldApplicationP2Tests`：应用管理页，D225 只加了右键菜单，不改版面。
- 右键菜单本身没有窗口测试，由非窗口测试覆盖模型。

## 五、建议写进 DECISIONS 的条目（由主会话定稿）

- D223：杂乱首页说明照 CleanMyMac 列类别的做法，用我们的话列全四类（重复文件、相似照片、大型和旧文件、聊天文件）；“每组至少留一份”只说重复文件。
- D224：提醒卡片、卡片上的忽略菜单和提醒设置里原样照抄 CleanMyMac 字符串表的句子和选项名（逐条见 cmm-ui-build19-a.md），改成我们自己的话，意思不变；访达命令名和通用词（清倒废纸篓、废纸篓、忽略、取消、好）保留；加源码合同测试防止回退。
- D225：“其他位置的应用”右键“加入忽略列表”。应用行加入全部副本，副本行只加那一份；按路径、类别“卸载”，有“放回原处”，重新扫描照列表不列。不影响 D212 合并和 D218 只删应用本身。
