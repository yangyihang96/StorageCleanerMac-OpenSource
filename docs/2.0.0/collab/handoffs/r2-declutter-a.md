# r2-declutter-a：D64 的 D1＋D3 第三轮交接

日期：2026-10-08。worktree：`/Users/developer/Developer/sc-worktrees/r2-declutter-a`；分支：`task/r2-declutter-a`。本轮从干净 HEAD `78df5997e9db72ce9981ed68e4c8cc7aaf71c76e` 开始，该 HEAD 已包含主会话提交的第二轮四组。当前交付为 `/Users/developer/Developer/.sc-build/r2-declutter-a/prepared-r3/`，补丁只包含相对 **78df599** 的第三轮最终改动。`prepared/`、`prepared-r2/` 和既有日志原样保留；不再次应用相对 a6db3c5 的第二轮累计补丁。

**第二轮已在沙箱外构建、定向测试和反证通过。第三轮源码、测试、反证脚本和静态产物已准备；第三轮 Swift／XCTest／反证红绿／原生 UI 尚未执行。** 两轮结果分别记录，不把历史通过当作新源码通过。本轮未提交、安装、启动应用或写硬件设置。

## 第三轮实际修复

| 复核项 | 改动、理由与覆盖 |
|---|---|
| P1-1 胶囊信息性符号丢失 | `MetadataPillStatus` 显式区分 `.none/.locked/.warning/.failure/.readOnly/.systemSettingsOnly`。默认 `.none`，旧 `systemImage` 仍兼容且不渲染装饰；只有状态语义可开启符号。锁、警告、失败、只读、仅系统设置分别映射到不同符号，单一朗读标签保留，另加状态 accessibilityValue。枚举逐项断言映射与旧图标名无关。**C 批文件未改，登录项恢复可见限制仍需 C 接入下述 status。** |
| P1-2 cx1 重新添加分区图标 | 设置页检查涵盖全部 `Label(...)` 和 `Label { ... } icon: { ... }` 及 `Image(systemName:)`，保留分类导航 `AppSymbolIcon` 和移除排除项 `AppIconButton` 的正向覆盖。该类是视图接线检查，配合枚举模型断言；不将所有源码检查误称为运行时渲染测试。 |
| P1-2 cx2 设置卡片删除密码边界 | 设置、首启分别使用 `PermissionSafetyDisclosure.settingsHelper/onboardingHelper`。逐项检查两套模型的中英文功能范围、白名单和不保存管理员密码，并检查各卡绑定相应模型；首启另一处有密码文字不能掩盖设置模型的遗漏。 |
| P1-2 cx3 次级按钮重新显示图标 | 将策略抽为 `AppButtonIconPolicy.showsInlineIcon`，`AppButtonKind: CaseIterable`，按全部 13 个 case 的期望表实际调用策略。普通图标、nil、两种外链符号都覆盖；选择、展开、外链、窄布局仅图标回退与可访问性覆盖保留。策略 switch 无 default，添加类别必须明确策略。 |
| P1-2 cx4 登录失败符号改名导致隐藏 | `SettingsNoticeSeverity` 显式区分信息、成功、警告、失败、保护拒绝。所有构造点填写 severity，图标名／tint 不再决定显示。注册成功／待批准／注册失败及四类系统设置打开结果用纯模型工厂构造并测试所有分支；失败原因、按钮可达、注册／注销／读取及会话恢复行为仍覆盖。原 cx4 改名现在也不会让失败符号消失，另保留批准的默认三角符号断言，确保该原始写法仍被抓红；任意符号名下 `.failure` 必须显示的枚举测试验证真正安全含义。 |
| P2-1 结果符号精确白名单 | `AppStateIconRing` 用 `.result/.decorative` 的 role 决定静态状态，不猜名字。默认 `.result` 兼容现有进度／操作结果调用，`checkmark.circle/minus.circle/exclamationmark.circle/hourglass` 等可显示；显式 `.decorative` 无进度／活动时为 0 pt。空态仍只在 isLoading 时构造 ring，真实活动 32 pt、数值进度用 size。|
| P2-2 设置标题错位 | 标题和内容共同置于 `category.columnMaxWidth` 列中，取消独立标题列。非小窗 600 pt、小窗充满；标题 inset 匹配权限卡／小窗 24 pt，其他原生 grouped Form 内容起点 30 pt。逐项断言七分类列宽／inset 和共享列接线。30 pt 来自复核截图的原生 Form 内容起点；**尚未用第三轮截图验证像素对齐**。|
| P2-3 隐私边界误删 | “无需辅助功能、屏幕录制、相机、麦克风、定位或自动化权限。”及同步英文恢复到“联网与隐私”，并恢复 UIConsistency 的对应覆盖。全部六类逐项断言，原不请求 AX／屏幕录制、独立联网同意覆盖保留。|
| P2-4 管理员卡缺少功能范围 | 设置和首启均补回风扇、电源模式与系统级启动项；与白名单、不保存管理员密码合并为短句，首启保持只授权一次。权限要求、状态、系统路径和真实 action 未改。|
| P2-5 死属性 | 用户本轮明确授权移除 `AppCanvasTheme.detail` 及两套文案。`AppDesignTokens.swift` 只有这一块删除，其他字节与 HEAD 相同；默认主题、持久化 key、解析／缓存／标题未改，测试验证纯解析模型，不写偏好。|
| P2-6 排版 | 恢复 `fanControl.manualFraction = min(1, max(0, $0 / 100))` 的单行括号与缩进，量程不变。|
| P2-7 过时交接 | 用实际第二轮构建／514 项／反证 13 次和独立 174 项通过证据替换旧“第二轮 NOT RUN”；新源码未执行状态单独保留。|

安全说明使用一个短句，不加 `lineLimit(1)`，英文和窄窗口允许自然换行，避免截断密码、权限或外发边界。本轮改动 6 个生产文件、4 个测试文件和本交接，共 11 个文件；`AppPageHeader` 及其后续源码、`SmartCareGauge` 逐字节未变。b／c／V1、ScanStore、BOARD／DECISIONS 均未修改。

## C 批必须接入：登录项限制状态

组件参数默认 `.none`，确保旧调用保持第三轮前的文字呈现。**新增参数本身不会自动修复未接入的登录项页面**，主会话需把下面映射转交 C 批，禁止用图标名或 tint 猜状态。目标为 `Features/StartupItems/Views/StartupItemsDashboardView.swift` 约 708–751 的 statusPill；保留现有 shortStatus、help、完整 `item.displayStatus` 朗读标签。映射顺序沿用当前 statusSymbol 的限制优先级：

```swift
private var statusSemantic: MetadataPillStatus {
    if item.requiresAdministrator { return .locked }
    if item.hasConfigurationIssue { return .warning }
    if item.isSystemSettingsOnly { return .systemSettingsOnly }
    if item.isReadOnly { return .readOnly }
    if item.state.process == .failed { return .failure }
    return .none
}

MetadataPill(
    text: shortStatus,
    systemImage: statusSymbol,
    tint: statusTint,
    status: statusSemantic
)
.help(statusHelp)
.accessibilityLabel(item.displayStatus)
```

C 批应加入各限制分支／优先级及 process.failed 的测试，再采集有受保护、需管理员、配置问题、仅系统设置、只读的登录项行，确认不只剩“正在运行”。运行／等待／停止等状态已有文字，普通模块／播放／暂停图标可继续不显示。

第三轮检索得到 **29 处生产 MetadataPill 调用、8 个文件**，并非复核估计的 30。逐处源码片段、行号、文件 SHA 和判定在 `prepared-r3/source-audit.json`：

| 调用文件（Sources/StorageCleanerMac 下） | 数量 | 判定 |
|---|---:|---|
| Views/ComputerHealth/MacAcceleratorBenchmarkSection.swift | 2 | 样本／协议口径有文字 |
| Views/ComputerHealthView.swift | 2 | 数据模型／置信口径有文字 |
| Views/ContentView.swift | 5 | 可读、受限、跳过、准备状态、当前／历史结果有文字 |
| Views/LargeFilesView.swift | 3 | 空间、文件系统、资格状态有文字 |
| Views/OverviewView.swift | 2 | 扫描时效、评分有文字 |
| Views/SmartScanProgressView.swift | 2 | 只读与调试状态有文字 |
| Views/SystemUtilitiesView.swift | 12 | 来源、计数、证据关系、内存状态／时长／差值／压力有文字 |
| Features/StartupItems/Views/StartupItemsDashboardView.swift | 1 | shortStatus 截断限制限定词，须显式状态 |

这些 8 个文件均只读审计、未修改。本轮共享按钮普通次级动作的纯文字策略也影响 b 小窗三处导航和 V1 工具栏，请主会话同步知会；选择图标、展开箭头和窄布局仅图标回退保留。

## 测试改写的依据及保留覆盖

第三轮没有删方法、改名、skip 或放宽阈值；原 D64 12 项保留，加 7 项，共 **19 项**。它们仅创建纯模型／轻量 View 值，读取源文件，不创建 ScanStore/FanControlCoordinator，不执行真实偏好、清理或硬件动作。

| 方法／类 | 原断言与第三轮调整 | 仍覆盖的行为 |
|---|---|---|
| D64 的按钮守卫 | 原匹配几个 switch 字符串改为全枚举实际策略表 | disabled/loading、文字／窄窗回退、选择 trait、展开状态、外链方向与朗读 |
| D64／ControlAccessibility 的胶囊守卫 | 原“一律没有 Image”按 D64 信息性符号例外改为默认无符号＋显式状态有符号 | 单一 label、隐藏符号本身、状态 value、数据／指标文字和 monospaced 数值；Toast／列表旧朗读覆盖未删 |
| D64／SystemUtility 的 ring 守卫 | 原三种精确图标名改为显式 role | 活动／数值进度／结果保留，静态空态无槽、动作可达、无假进度、布局与运动策略 |
| D64 的权限守卫 | 全文件出现密码文字改为两种卡片数据模型逐项双语断言＋视图接线 | 要求标签、路径、安装／设置／重查 action、白名单、密码、独立联网同意及媒体隐私 |
| D64 的反馈守卫 | 图标名判严重程度改为全部 severity × 多种符号 × 多种 tint 的实际行为 | 所有失败分支警告可见、成功移除纯文字、保护拒绝、错误原因、批准与失败 action 接线 |
| UIConsistency 的设置权限守卫 | 第二轮遗漏的“无需额外权限”声明恢复双语六项模型与网络隐私 Text 接线断言 | 原权限状态、系统跳转、独立同意、禁止 AX/屏幕录制请求仍保留 |
| D64 的登录项守卫 | 成败提示从 Task 内迁到 SettingsNotice 工厂，相应检查改为实际工厂结果及 Task 调用 | ServiceManagement register/unregister、批准设置入口、读写中 disabled、实际 `NSApp.disableRelaunchOnLogin()` |

第二轮原失败处理保留为下面历史记录，指第二轮相对 a6db3c5 的修复；其中 3786 的“精确符号分支”已在第三轮被显式 role 取代，后者覆盖更多结果符号。
### 第二轮：逐条处理第一轮 8 条失败

证据为 `r1-failures.txt` 与 `logs/main-r1-113454/test.log`；以下行号均指第一轮被验证的 `SystemUtilitySafetyTests.swift`，不是第二轮的新行号。8 条断言分属 4 个方法：

- U：`testSettingsUpdateSourceEmptyNoticeSeparatesDisabledSourcesFromPermissions`。
- S：`testInstalledAppUpdatesStayDistinctFromStorageCleanerSelfUpdates`。
- L：原 `testSettingsLaunchAtLoginUsesServiceManagementAndExplainsSessionRestore`，现改名 `testSettingsLaunchAtLoginUsesServiceManagementAndKeepsSessionRestoreDisabled`。
- P：`testSmartCareUsesSingleStartActionAndActionableResultTiles`。

| 失败原行／方法 | 旧断言 | 判定与依据 | 最终修复与保留覆盖 |
|---|---|---|---|
| 2099／U | 必须含“关闭更新来源只停止对应远程检查” | **真实提示回归**。D64 允许压缩说明，第二轮要求仍表达更新来源与权限的区别；不能把这种边界当作废话删除 | Settings 恢复一句双语边界；断言“关闭来源仅停止该来源的远程检查”，并补充“不改变权限”；来源计数、切换 binding 和恢复动作均覆盖 |
| 2100／U | 必须含“不影响存储清理助手自身的 Sparkle 更新” | **同一提示回归**。来源开关不能被理解为停用本应用自身更新 | 改为检查完整“不改变权限，也不影响存储清理助手自身的 Sparkle 更新”，保持两类更新入口区分 |
| 2101／U | 必须含英文 `Disabling an update source only stops its remote checks` | **同一提示回归**。中英安全意义须同步保留 | 显示并断言压缩后 `Disabling a source only stops its remote checks`；不是删除英文断言 |
| 2102／U | 必须含英文 `it does not affect Storage Cleaner's own Sparkle updates` | **同一提示回归**。不因压缩英文而丢失自身更新及权限边界 | 改为 `permissions and Storage Cleaner's own Sparkle updates are unchanged`，与中文同义 |
| 3221／S | 必须含中文“不影响存储清理助手自身的 Sparkle 更新” | **同一提示回归**，与 U 重复守卫同一用户可见边界 | 检查包含“不改变权限”的完整中文边界；保留模型名称、已安装应用更新页、本应用专属更新菜单及禁止混用菜单标题的原断言 |
| 3222／S | 必须含英文 `does not affect Storage Cleaner's own Sparkle updates` | **同一提示回归**；不将该安全断言改成“不存在” | 检查新英文边界；上述原有两个更新流程的独立入口断言保持 |
| 2116／L | 必须常显“应用不会加入 macOS 的登录会话恢复列表” | **D64 预期删除导致旧文案断言失效**。原 footer 只是启动行为重复说明；真实退出会话恢复行为不能随文案删除 | 断言中英旧说明都不存在，并直接检查 App delegate 的 `NSApp.disableRelaunchOnLogin()`；保留 register/unregister 与开关标题，新增批准设置入口、双语待批准提示和读取／变更期间禁用控件的守卫。没有修改 App 文件或启动行为 |
| 3786／P | 必须有 `width: progress == nil ? 32 : size` | **D64 预期删除静态装饰槽导致旧布局断言失效**。普通无进度模块图标应为零尺寸，实际活动和结果符号仍需尺寸 | 替换为 `.frame(width: renderedSize, height: renderedSize)`，锁定实际 progress 用 size、活动／结果用 32、普通静态装饰用 0，及 checkmark/xmark/exclamationmark 结果分支；保留单一扫描动作、结果动作可达、真实 ProgressView、运动策略与无假进度的所有原断言 |

因此是 **6 条断言暴露同一个更新来源提示回归，2 条旧断言按 D64 改写**。第一轮新增的 10 项 D64 守卫全部通过，没有“自己的新守卫失败”；其缺口是未覆盖该更新来源边界，第二轮新增对应守卫及遗漏反证。没有把失败测试 skip、删除方法或放宽阈值。

第二轮新增 `testUpdateSourceNoticeKeepsRemotePermissionAndSelfUpdateBoundaries` 与 `testLaunchAtLoginKeepsApprovalAndSessionRestoreBehaviorWithoutGuidance`，共 **12 个 D64 方法**。新增覆盖包括提示在来源区可见且可自然换行、双语三项边界、来源持久化／恢复不请求权限、签名与安装确认、待批准登录项可打开设置、注册／注销状态和错误反馈、App delegate 实际禁用会话恢复。

浏览器隐私与管理员登录项安全测试没有改写或删断言，第二轮加入定向类：

- `PrivacyCleanupPresentationTests.testBrowserPrivacyCopyMatchesManualOnlyProductionBoundary`、`testBrowserPrivacyManualModeNeverClaimsOrStartsDatabaseDeletion`：保留浏览器内手动处理、显式复制与不启动直接删除的边界。
- 同类 `testResultRowsPrintOnlySanitizedPresentationText`：保留原始历史字段不得直接到 Text／help／无障碍标签、经 presentation 处理才显示、显式剪贴板动作及写入位置数量覆盖。
- `StartupItemsDashboardContractTests.testInspectorMakesSingleVerifiedAdministratorRequestReachable`、`testAdministratorRequestFailsClosedWithoutCapabilityOrSingleTarget`、`testAdministratorFailureKeepsPostMutationRescanEnabled`：管理员请求可达，同时保持缺少能力／目标不唯一时拒绝及失败后的重新扫描。

这些测试及其 b／c／V1 生产文件均未修改。其他原有安全、证据、警告与可操作性断言照旧。

## 主会话第二轮验证：已通过

- `logs/main-prepared-r2-121948/build.log`：build PASS，`Build complete! (54.15 sec)`。
- 同目录 `test.log`：**514 项、1 项既有 skip、0 失败**，D64 12 项与修复的 U/S/L/P 四项均通过。
- `counterexample-logs/a1766124-d322-409b-b4cc-5bb656e4b535/report.json`：**PASS，13 次全部 accepted=true**。SHA-256：`d18679e343fbb420c3b8b32c6788438605e0a95aee8064ff8f75a2dfabdcf539`。
- 独立复核 `review/cx/00-baseline.log`：额外 8 个类加旧 D64 共 **174 项、0 失败**；复核的 HEAD／a6db3c5 Debug 包都构建成功，HEAD 0 warning。
- `review/review-1.md` 全文及 `shots/compare/` 全部 11 张对照图已读。复核的 cx1–cx4 在旧 D64/UIC/CA 中均存活；每次 SystemUtility 出现同一 23 条缺夹具失败，与突变无关，**不能作红证据**。第三轮副本包括 Resources、script、docs 等项目夹具，并由 D64 对应方法明确抓红。

所有日志、复核、旧 manifest、四组漏抓结果和 11 张图的 SHA-256 汇总于 `prepared-r3/previous-validation.json`。这是 **78df599 的历史证据**，不是当前未提交源码的通过证明。第一轮记录保留在 `prepared-r2/r1-evidence.json`，原日志不覆盖。

## 第三轮静态结果与反证计划

第三轮静态检查：`git diff --check`、4 组及 all.patch 共 5 份补丁反向适用、11 文件范围及 SHA、禁止区域字节比较、Python AST、19 个守卫方法保留／新增清单、28 个定向类文件存在性、13 组突变目标唯一性和突变后的 Swift 词法括号。执行明细在 `prepared-r3/static-checks.json`、`counterexample-preflight.json`。词法检查不是类型检查／编译，突变静态检查不是 XCTest 红。

以下十三组仅在带 UUID 所有权标记的独立副本中执行。前十组由 `run-counterexamples.py` 要求 **19 项完整执行且 failed 方法集合准确等于指定方法集合**；最后三组保留第二轮的安全反证，分别增加原 U/S、L、P 方法，执行数为 21、20、20。非零退出本身、编译失败、工具错误、零匹配、执行数错误或无关方法失败，一律不能算通过反证。

| 突变 | 必须抓红的 D64 方法（缩写仅用于表格） |
|---|---|
| cx1 把扫描提醒分区 Text 改回 `Label { } icon: { Image(...) }` | `testSettingsKeepSevenNavigationCategoriesWithoutDecoratedHeadingsOrTutorial` |
| cx2 删除设置 helper 数据模型的中英密码边界 | `testPermissionDisclosuresKeepPasswordAndControlScopeInBothLanguages` |
| cx3 `.secondary/.destructive` 重新返回显示内嵌图标 | `testTextActionsHideInlineIconsButKeepSelectionAndCompactFallback` |
| cx4 登录项失败默认符号替换为 `xmark.octagon.fill` | `testLoginFailureUsesExplicitSeverityAndDefaultSymbol` |
| cx5 `.failure` 严重程度不显示符号 | 反馈枚举表、登录失败模型、系统设置打开失败模型三个方法 |
| cx6 MetadataPill 默认状态改为 locked | 默认纯文字／指标守卫 |
| cx7 locked 的状态符号改为 nil | 状态枚举表守卫 |
| cx8 result 重新添加三图标名白名单 | 空态／活动／多种结果符号守卫 |
| cx9 删除联网与隐私里的无需额外权限 Text | `testNetworkPrivacyRetainsUnneededAccessBoundary` |
| cx10 取消共享列 600 pt 上限 | `testSettingsColumnsAlignHeaderWithFormContent` |
| cx11 删除双语更新来源与权限／自身更新边界 | 新更新来源守卫＋原 U/S 方法 |
| cx12 删除登录项批准设置 action，保留按钮文字 | 新登录项守卫＋原 L 方法 |
| cx13 活动指示不再有占位 | 空态／活动守卫＋原 P 方法 |

cx1–cx4 保持复核的原始写法／语义；cx2 的文案已抽到首启文件内的 `settingsHelper` 模型，因此突变位置随数据维护源迁移，不再靠另一张卡片的密码句过关。cx4 除抓默认符号变更，还证明即使采用其他符号，显式 failure 仍显示；cx5 专门反证失败语义被关闭。

先 19 项绿，逐个十三组红并立即恢复，最后 19 项绿，再第二轮 U/S/L/P 四项绿，总共 **16 次运行**。第三轮新增了模型类型，直接整文件还原 a6db3c5 会使新测试缺少类型，不能用这种编译失败证明第三轮红；原七组删除守卫仍在 19 个方法中，新突变隔离真实行为，第二轮的三条安全遗漏继续在原 U/S/L/P 方法上反证。所有报告与日志保留在 `counterexample-logs/r3-<UUID>/`；结束仅删除 runner 创建且标记未变的源码／缓存。**本会话没有执行这些 Swift 命令，尚无第三轮真实变红结果。** 这是共同要求 common.md 禁止沙箱构建／测试的明确限制，不用静态模拟代替。

## 主会话执行命令

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
python3 /Users/developer/Developer/.sc-build/r2-declutter-a/prepared-r3/run-targeted.py
python3 /Users/developer/Developer/.sc-build/r2-declutter-a/prepared-r3/run-counterexamples.py
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-declutter-a/verify-r3 script/verify.sh
```

`targeted-classes.txt` 保留第二轮 20 类，并纳入独立复核额外的 CleanupReceiptHistoryTests、ExternalMigrationReceiptTests、FileAnalysisTrashTests、MenuBarPanelInteractionTests、MiniWindowD43LayoutTests、PanelChartNormalizationTests、TestFanControlIsolationTests、UnifiedMenuBarPanelTests，共 **28 类**，含 TestPreferenceHygieneTests／UIConsistencyRegressionTests。runner 校验最终源码哈希、精确类名前缀过滤、全部类 suite passed 及非零测试数，日志使用 `verification-logs/r3-<UUID>/`。按 RULES 使用本批独立 debug scratch，离线依赖由主会话准备；反证默认 seed 是 `r2-u1-preselect/debug`。

构建、定向、反证、verify、C 接入及原生验收通过后再按组提交，`commit-prepared.py` 不自动验证或推送。本会话不执行提交。

## 分组与剩余交接

1. `01-shared-components.patch`：AppControls、MetadataPill、SmartCareComponents、仅死 detail 删除的 AppDesignTokens。
2. `02-settings-onboarding.patch`：SettingsView、FirstLaunchOnboardingView。
3. `03-contract-tests.patch`：D64 类及三份既有测试更新。
4. `04-handoff.patch`：本交接。

另外交付 all.patch、四份提交说明、manifest、static-checks、source-audit、previous-validation、counterexample-preflight、三个生成／验证／提交 runner、反证 runner、28 类清单与 README。manifest 记录基线、分支、组顺序、最终文件和所有产物 SHA。

- **C 批**：按上面映射接入登录项 status；组件能力已交付，登录项可见限制恢复需主会话转交，不能声称本批已独立恢复该页面。
- **D6 原有交接**：ContentView 的 AccessRepairStepRow 仍画 ArtworkIconTile 并构造空 detail Text；本批 service 数据的三步标题／媒体短句已精简，D6 删除空布局及图标后再收口 systemImage 字段。未改 ContentView。无引用的 SmartScanReadyStage 仍有无条件 ring；如果复用它须指定 `.decorative` 或移除图标，不能把装饰当结果；本轮检索未发现 `SmartScanReadyStage(` 生产调用。未挂载的 CleanupV2OperationOverlay 的结果符号已因 ring 语义修正不再被精确白名单隐藏，删除死覆盖层仍由 D6 处理。
- **本轮未变文件**：ReversibleOperationsView、RedactedSupportExportView、MiniWindowConfigurationSettingsView、AccessRepairGuideService 第三轮均与 78df599 相同，旧恢复安全、脱敏支持包、拖动／上下移／Apply、媒体隐私覆盖保留。浏览器“仅手动处理”、结果行只输出脱敏文本、登录项管理员请求可达／拒绝边界的既有测试和生产文件均未修改，仍在定向清单。
- **原生验收**：重新检查七类设置的 900×532pt 与最窄窗口、中英、较大字体、VoiceOver；验证标题与内容左缘、隐私与 helper 说明不截断、所有失败／保护拒绝可见、C 状态接入结果。复核未测的浅色 warning 胶囊对比度仍需验收，本轮不声称已测。
- **JEV**：本轮 `jev_review` 请求再次被工具审批策略拒绝：`MCP tool call requires approval, but approval policy is never`；工具无模型参数可选，模型请求未执行，未获得本轮判断。独立复核报告里的 JEV merge_after_fixes 0.99 是复核会话结果，不是本轮调用结果。
