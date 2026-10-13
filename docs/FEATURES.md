# 功能详情 / Feature Details

本文按主窗口侧栏介绍 2.0.0 测试版，依据截至 **2026-10-07** 的功能实测与源码核对。**已支持**只指实机通过的子流程；删除与恢复的通过结果只来自隔离测试文件或测试应用。**测试版**表示存在已知问题、未完成实测，或修复已合并但尚未安装复测。使用步骤和安全边界描述当前实现的约束，不代表这些操作都已通过实机验证。各项依据见文末注释。[^scope]

This document follows the main-window sidebar for the 2.0.0 beta, using live test results and source inspection available on **October 7, 2026**. **Supported** applies only to workflows that passed on the test Mac; successful removal and recovery used isolated test files or apps. **Beta** means a known issue, an incomplete live test, or a merged fix awaiting installation and retesting. Usage instructions and safety boundaries describe implementation constraints, rather than claiming every operation has passed a live test. Evidence notes appear at the end.[^scope]

## 智能扫描 / Smart Scan

- **做什么 · 已支持：**扫描清理项目，按绿色、黄色、红色分组供审阅。实测中的全部列出分组均可勾选；测试文件移入废纸篓后，可从“操作记录”恢复。[^cleanup]
- **怎么用：**从“智能扫描”开始扫描，查看分组及逐项说明，调整选择后审阅清单、确认清理。当前实现默认选择绿色项，所属应用正在运行的行除外；黄色、红色及“清空废纸篓”不预选。新的默认选择规则为**测试版 · 已合并，待实机复测**。[^cleanup]
- **安全边界：**扫描只读。普通清理移入废纸篓；红色项需要两次确认。执行前复查路径、项目变化和应用运行状态，跳过不能安全处理的项目。应用本体通过“卸载”处理，重复安装的应用副本另行审阅。上述执行约束经源码核对；测试中符号链接指向的文件未被移动。[^cleanup]
- **限制：**权限、用户排除项与安全规则会限制覆盖，不能把结果当作整台电脑的全部可释放空间。“完成”后保留剩余结果的修复已合并，尚待安装复测；该行为仍标为**测试版**。[^cleanup]

- **Purpose · Supported:** scans cleanup candidates and groups them into Green, Yellow, and Red for review. Every listed group in the live test was selectable. Test files moved to the Trash were restored through Operation History.[^cleanup]
- **Usage:** start from Smart Scan, read the groups and item details, adjust the selection, review the plan, and confirm cleanup. The current implementation preselects Green rows except those whose app is running; Yellow, Red, and Empty Trash remain unselected. This revised selection policy is **Beta · merged, awaiting live retest**.[^cleanup]
- **Safety boundary:** scanning is read-only. Ordinary cleanup moves items to the Trash; Red items require two confirmations. Paths, changes, and running apps are rechecked before execution, and unsafe items are skipped. App removal uses Uninstall, with duplicate installed copies reviewed separately. These constraints were checked in source; the live test left symbolic-link targets untouched.[^cleanup]
- **Limits:** permissions, exclusions, and safety rules limit coverage, so the result is not a complete estimate of reclaimable space across the Mac. Keeping remaining results after Done has a merged fix awaiting installation and retesting, and remains **Beta**.[^cleanup]

## 清理 / CLEANUP

### 安全清理 / Safe Cleanup

- **做什么 · 已支持：**审阅缓存、日志等清理结果，与智能扫描共用清理和回执流程。本轮测试文件的清理与“操作记录”恢复通过。[^cleanup]
- **怎么用：**选择扫描范围，扫描后逐项查看用途、风险和大小，再选择需要处理的项目并确认。绿色、黄色、红色表示审阅风险，不表示可以跳过确认。[^cleanup]
- **安全边界：**普通项目只移入废纸篓。**测试版 · 未实测**的“清空废纸篓”是单独的永久删除操作，默认不选，需再次确认；它不具备恢复保证，也不删除扫描后新放入废纸篓的项目。[^cleanup]
- **限制：**不是所有占用都属于垃圾；个人数据与受保护内容不会因占用大就进入清理列表。清空废纸篓未在本轮执行；新版默认选择与完成页行为仍待实机复测。[^cleanup]

- **Purpose · Supported:** reviews cleanup results such as caches and logs, using the same cleanup and receipt workflow as Smart Scan. Removal and recovery of test files passed this round.[^cleanup]
- **Usage:** choose a scope, scan, review each item's purpose, risk, and size, then select and confirm what to handle. Green, Yellow, and Red indicate review risk and do not bypass confirmation.[^cleanup]
- **Safety boundary:** ordinary items move to the Trash. Empty Trash is a separate permanent-deletion operation, **Beta · not live-tested**, unselected by default and requiring another confirmation. It has no recovery guarantee and leaves items added to the Trash after the scan untouched.[^cleanup]
- **Limits:** storage use alone does not make something junk; personal and protected data are excluded from cleanup. Empty Trash was not executed this round. Revised default selection and completion-page behavior still await live retesting.[^cleanup]

### 开发工具与产物 / Dev Tools & Artifacts

- **做什么 · 已支持：**在清理结果中单独审阅开发工具缓存、日志与可再生成产物。本轮与智能扫描共同验证了列出分组可选，以及测试文件清理、恢复流程；并未逐个验证每种开发工具。[^cleanup]
- **怎么用：**进入此页扫描，查看项目对应的工具、活动时间和风险，再选择并确认。当前规则按活动时间区分开发缓存风险；近期使用的项目不默认勾选。[^cleanup]
- **安全边界：**配置、凭据、会话、工作区、技能、插件数据与用户成果不应作为可再生成缓存清理；执行前复查新写入和运行状态。普通操作移入废纸篓，保留回执。[^cleanup]
- **限制：**只覆盖规则能明确识别的内容，不是对所有开发目录的通用删除。新增工具规则与新的绿色预选策略属于**测试版 · 已合并，待实机复测**；不能从共同流程通过推断每个工具都已实测。[^cleanup]

- **Purpose · Supported:** reviews developer caches, logs, and regenerable artifacts separately. The shared Smart Scan test verified selectable groups and test-file cleanup and recovery; it did not test every developer tool individually.[^cleanup]
- **Usage:** scan this page, review the owning tool, activity age, and risk, then select and confirm. Current rules tier developer caches by activity age; recently used items are not preselected.[^cleanup]
- **Safety boundary:** configuration, credentials, sessions, workspaces, skills, plugin data, and user output are excluded from regenerable-cache cleanup. New writes and running tools are rechecked before execution. Ordinary cleanup uses the Trash and receipts.[^cleanup]
- **Limits:** coverage is confined to identifiable rules, rather than general deletion across developer folders. Added tool rules and revised Green preselection are **Beta · merged, awaiting live retest**. A passing shared workflow does not establish live coverage for every tool.[^cleanup]

## 保护 / PROTECTION

### 系统健康 / System Health

- **做什么 · 已支持：**手动检查系统健康，显示评分与各项依据；本轮实测四项指标均有证据来源。[^health]
- **怎么用：**点击“开始健康检查”，完成后查看各项结果和证据，按提示判断哪些信息仍需补充。[^health]
- **安全边界：**健康检查只读，评分不是修复动作，也不表示硬件故障已排除。网络测速是另行确认的联网操作，本轮未验证测速。[^health]
- **限制：**没有权限、缺少历史或硬件不提供的数据不能成为完整诊断；本轮通过的是本机健康检查及结果展示，不是所有机型的硬件诊断或联网测速。[^health]

- **Purpose · Supported:** checks system health on demand and shows a score with its evidence. All four indicators in this live test had identifiable evidence sources.[^health]
- **Usage:** choose Start Health Check, then read each result and its evidence, including any information still missing.[^health]
- **Safety boundary:** the check is read-only. A score does not repair anything or rule out hardware faults. Network speed testing is a separately confirmed network action and was not verified this round.[^health]
- **Limits:** missing access, history, or hardware readings prevents a complete diagnosis. The passing result covers this Mac's health check and presentation, rather than hardware diagnosis on every model or network speed testing.[^health]

### 浏览器隐私 / Browser Privacy

- **做什么 · 已支持：**扫描、显示本机 Safari 与 Chrome 的浏览历史。实测可辨认页面标题、网址和日期，可选择单行、复制网址；查询参数默认折叠。其他浏览器未在本轮逐个验证。[^privacy]
- **怎么用：**点击“扫描浏览器记录”，审阅页面和访问时间。按结果提供的处理方式操作；“在浏览器内处理”表示需要进入浏览器自身的历史管理界面。应用内直接删除为**测试版 · 未完成实测**。[^privacy]
- **安全边界：**扫描只读。直接删除实现要求核对浏览器身份、退出浏览器、备份历史库并在写入前后复查；同步记录转交浏览器处理。该流程不等同于把文件移入废纸篓。删除前备份仍包含原浏览内容，7 天后自动删除，正常删除备份设有 12 份上限；“最近的删除”用于恢复，手动删除备份或到期删除均不进废纸篓。[^privacy]
- **限制：**Chrome 身份核对修复已合并，尚未安装复测直接删除；Safari 删除、历史恢复和其他浏览器删除也未实测。直接删除的实现不处理网站图标库，不连带删除重定向上游访问；页面曾被书签引用也不阻止删除其历史。恢复旧备份会覆盖其后新增的历史和下载列表，并可能重新带回之后删掉的记录，必须先阅读确认说明。[^privacy]

- **Purpose · Supported:** scans and displays local Safari and Chrome history. The live test verified readable page titles, URLs, and dates, individual row selection, and Copy Address; query parameters are collapsed by default. Other browsers were not tested individually.[^privacy]
- **Usage:** choose Scan Browser Records and review pages and visit times. Follow the handling option shown for the result. Handle in Browser means using the browser's own history controls. Direct deletion in this app is **Beta · live testing incomplete**.[^privacy]
- **Safety boundary:** scanning is read-only. The direct-deletion implementation requires browser identity checks, browser exit, a history-database backup, and checks before and after writing; synced visits are handled in the browser. This is not a move-to-Trash operation. Backups still contain the original browsing history, expire after seven days, and have a twelve-backup limit for normal deletions. Recovery uses Recent Deletions; manual backup deletion and expiry do not use the Trash.[^privacy]
- **Limits:** the Chrome identity fix is merged but awaits installation and a direct-deletion retest. Safari deletion, history recovery, and deletion in other browsers were not live-tested. Direct deletion does not change the website-icon database or remove upstream redirect visits; a bookmark does not prevent deletion of that page's history. Restoring an older backup overwrites newer history and download-list entries and can bring back records deleted later, so read the confirmation first.[^privacy]

## 性能 / PERFORMANCE

### 性能测试 / Performance Test

- **做什么 · 已支持：**启动性能测量并显示实时负载和温度，可取消。本轮完成了核心阶段，扩展阶段取消后正常停止；未完成整次测试。[^benchmark]
- **怎么用：**点击“开始性能测试”，先阅读环境提示，在运行中查看进度；需要时使用取消操作。已有完整结果在本轮取消后仍保留。[^benchmark]
- **安全边界：**测试由用户启动，会产生计算负载和临时测试数据；取消需要等待收尾，不能把部分结果当成完整成绩。本轮没有发布成绩或验证排行榜。[^benchmark]
- **限制：**扩展阶段取消记录与后台负载提示的修复已合并，待安装复测，属于**测试版**。完整测量、评分、参考数据与跨设备可比性未获本轮验证；部分界面文案和小窗口布局仍有已知问题。[^benchmark]

- **Purpose · Supported:** starts performance measurements, displays live load and temperature, and accepts cancellation. The core stage completed and cancellation during extensions stopped normally; the full run was not completed.[^benchmark]
- **Usage:** choose Start performance test, read the environment notices, and follow progress. Cancel when needed. The earlier complete result remained available after this round's cancellation.[^benchmark]
- **Safety boundary:** the user starts the test, which creates compute load and temporary test data. Cancellation requires cleanup time; partial results are not complete scores. No result was published and the leaderboard was not verified this round.[^benchmark]
- **Limits:** fixes for extension-stage cancellation history and background-load notices are merged but awaiting installation and retesting, and remain **Beta**. Full measurement, scoring, reference data, and comparisons across devices were not validated this round. Some wording and small-window layouts still have known issues.[^benchmark]

### 登录项与后台任务 / Login Items & Background Tasks

- **做什么 · 已支持：**读取登录项和后台任务，按分组展示；本轮验证了读取与列表浏览。[^startup]
- **怎么用：**打开此页读取列表，分别查看注册、授权、启用、载入与运行状态，不把“没有进程”直接等同于“已停用”。停用、启用与撤销为**测试版 · 未实测**。[^startup]
- **安全边界：**当前实现只直接管理归属可核实的当前用户后台代理；系统、Apple、受管理或归属不明的项目保持只读，或交给系统设置处理。不以改写第三方配置文件代替管理。[^startup]
- **限制：**本轮停用／启用夹具步骤受自动操作权限限制而未执行。列表中可管理标记不证明停用、启用或撤销已经成功；也不表示所有后台组件均可直接管理。[^startup]

- **Purpose · Supported:** reads and groups login items and background tasks. Reading and browsing the list passed this round.[^startup]
- **Usage:** open the page and inspect registration, authorization, enablement, load, and running state separately. No process does not necessarily mean disabled. Disable, enable, and undo are **Beta · not live-tested**.[^startup]
- **Safety boundary:** the current implementation directly manages only attributable current-user background agents. System, Apple, managed, and unattributed items remain read-only or use System Settings. Management does not rewrite third-party configuration files.[^startup]
- **Limits:** the fixture disable/enable step was blocked by automated-operation permissions this round. A manageable label is not proof of successful disable, enable, or undo, and does not imply direct control over every background component.[^startup]

### 内存管理 / Memory Management

- **做什么 · 已支持：**显示内存压力、占用、趋势和进程快照；可选择建议应用并取消选择。本轮没有执行退出应用。[^memory]
- **怎么用：**先查看压力和应用占用，再手动选择要退出的应用；小窗对应按钮为“退出所选应用”。退出流程为**测试版 · 确认修复已合并，待实机复测**。[^memory]
- **安全边界：**当前实现要求主窗口和小窗的退出操作先列出应用名并确认，再请求正常退出；未保存内容由各应用处理，不承诺自动保存。不把普通文件缓存当作必须清除的内存。[^memory]
- **限制：**实测版本曾有连续点击按钮直接退出、没有确认的问题；修复和建议排除前台应用已合并，但没有安装后的实机证据。显示和选择通过不等于安全退出流程已通过，也不保证释放特定大小的内存。[^memory]

- **Purpose · Supported:** displays pressure, usage, trends, and a process snapshot; suggested apps can be selected and deselected. No apps were quit in this live test.[^memory]
- **Usage:** review pressure and app usage, then select apps manually. The corresponding mini-window button is Quit Selected Apps. Quitting is **Beta · confirmation fix merged, awaiting live retest**.[^memory]
- **Safety boundary:** the current implementation names the apps and asks for confirmation in both windows before requesting a normal quit. Each app handles its unsaved work; automatic saving is not promised. Normal file cache is not treated as memory that must be cleared.[^memory]
- **Limits:** the tested build could quit apps on repeated clicks without confirmation. That fix and foreground-app exclusion are merged but lack an installed-build live retest. Passing display and selection tests does not establish safe quitting or a particular amount of freed memory.[^memory]

### 能耗 / Energy

- **做什么 · 已支持：**按六步流程测量并展示应用和进程的能耗信息。本轮测量能运行并产生结果，但汇总存在缺陷。[^energy]
- **怎么用：**点击“开始测量”，等待各阶段完成，查看应用结果及覆盖说明；只在数据来源和测量时段明确时解读数字。[^energy]
- **安全边界：**测量只读，不改变电源模式，不结束应用。功率、累计电量、覆盖率不是同一个指标，部分来源不足不能代表零耗电。[^energy]
- **限制：**实测中的整机汇总为零、覆盖不足，与应用级结果不一致。接电时汇总及进程名称修复已合并，待安装复测，属于**测试版**；目前不能把汇总作为准确的耗电统计或续航保证。[^energy]

- **Purpose · Supported:** measures and presents app and process energy information through six stages. The workflow produced results, but its summary had defects.[^energy]
- **Usage:** choose Start Measurement, wait for the stages, and read app results with their coverage notes. Interpret numbers only with an identifiable source and measurement period.[^energy]
- **Safety boundary:** measurement is read-only and does not change power modes or quit apps. Power, cumulative energy, and coverage are different measures; incomplete sources do not establish zero consumption.[^energy]
- **Limits:** the live whole-system summary showed zero and insufficient coverage despite app-level results. Fixes for plugged-in summaries and process names are merged but await installation and retesting, and remain **Beta**. The summary is not yet verified as accurate energy accounting or a battery-life guarantee.[^energy]

## 应用 / APPLICATIONS

### 卸载 / Uninstall

- **做什么 · 已支持：**预览应用与关联文件，确认后将测试应用本体移入废纸篓，再从“操作记录”恢复。本轮未核实归属的关联文件被保留。[^uninstall]
- **怎么用：**选择应用并打开预览，默认只选应用本体；审阅关联文件的归属和原因，确认后执行，再查看逐项结果与回执。[^uninstall]
- **安全边界：**未核实的关联文件不自动删除。移入废纸篓的通过结果只覆盖测试应用；权限不足、锁定或系统保护会阻止操作，应按界面指引处理。[^uninstall]
- **限制：**真实应用卸载、管理员授权、重试与后续残留清理未在本轮实测，属于**测试版 · 未实测**。不能保证完整移除共享数据或所有残留，也不能保证废纸篓被清空后仍可恢复。[^uninstall]

- **Purpose · Supported:** previews an app and related files, moves a test app to the Trash after confirmation, and restores it through Operation History. Related files with unverified ownership were retained.[^uninstall]
- **Usage:** select an app and open its preview. Only the app itself is selected by default. Review ownership and reasons for related files, confirm, then inspect item results and receipts.[^uninstall]
- **Safety boundary:** unverified related files are not deleted automatically. The passing removal result covers a test app only. Missing permissions, locks, or system protection can block an operation; follow the guidance shown.[^uninstall]
- **Limits:** real-app removal, administrator authorization, retry, and subsequent leftover cleanup were not live-tested this round and remain **Beta · not live-tested**. Complete removal of shared data or every leftover is not guaranteed, nor is recovery after emptying the Trash.[^uninstall]

### 应用更新 / App Updates

- **做什么 · 已支持：**检查应用更新，列出来源、当前版本与可用版本。本轮验证了检查及结果展示，没有安装更新。[^updates]
- **怎么用：**在此页开始检查，核对来源和版本；需要安装时再按对应来源的操作说明执行。检查结果不代表更新已安装。[^updates]
- **安全边界：**当前实现要求安装来源和签名可核实；不能安全自动处理的项目转交应用商店、官网或应用内流程。自身更新安装会等待占用中的重任务完成；这些安装约束只有源码与维护记录依据。[^updates]
- **限制：**单项安装、批量安装和自身更新均为**测试版 · 本轮未实测安装**。检查通过不证明下载、签名验证、替换或重启通过；网络不可达或来源信息不足也会影响检查。[^updates]

- **Purpose · Supported:** checks updates and presents sources, current versions, and available versions. Checking and result presentation passed; no updates were installed.[^updates]
- **Usage:** start a check, review sources and versions, then follow the source-specific instructions if you choose to install. A check result does not mean the update is installed.[^updates]
- **Safety boundary:** the current implementation requires verifiable sources and signatures for installation. Items unsuitable for safe automation use the App Store, official website, or in-app flow. Self-update installation waits for an active heavy task to finish. These installation constraints have source and maintenance evidence only.[^updates]
- **Limits:** individual, batch, and self-update installation are **Beta · installation not live-tested this round**. A passing check does not validate download, signature verification, replacement, or relaunch. Network access and incomplete source information also limit checking.[^updates]

## 文件 / FILES

### 文件分析 / File Analysis

- **做什么 · 已支持：**分析空间占用，用矩形图、列表和分栏浏览。实测通过了下钻、搜索当前层、返回和切换分栏。[^analysis]
- **怎么用：**选择范围后点击“分析磁盘空间”，按层级浏览和搜索。新版提供勾选及“审阅并移到废纸篓”，此操作为**测试版 · 已合并，待实机验证**。[^analysis]
- **安全边界：**分析本身只读。新版移动流程要求审阅、确认、记录回执和写入前复查；系统数据、凭据、云盘及其他受保护位置不可选。当前界面对外接卷说明：项目移入该卷废纸篓，需在访达中放回，不能承诺都能由应用内恢复。[^analysis]
- **限制：**本轮实测是只读浏览，没有验证新版移动与恢复。大型目录及云盘枚举耗时、分析后内存占用已有问题；性能优化已合并但未在同一实机范围复测，不给出加速承诺。权限或覆盖不足的大小不能当作完整容量。[^analysis]

- **Purpose · Supported:** analyzes storage use with a proportional map, list, and column view. Drill-down, current-level search, navigation back, and switching to columns passed the live test.[^analysis]
- **Usage:** choose a scope and select Analyze Disk Space, then browse and search by level. The new selection and Review and Move to Trash workflow is **Beta · merged, awaiting live validation**.[^analysis]
- **Safety boundary:** analysis itself is read-only. The new move workflow requires review, confirmation, receipts, and checks before writing; system data, credentials, cloud locations, and other protected paths cannot be selected. The current external-volume notice directs users to put items back from that volume's Trash in Finder; recovery inside the app is not promised for every volume.[^analysis]
- **Limits:** this round verified read-only browsing, rather than the new move and recovery workflow. Large directories and cloud enumeration have known time and memory costs. Performance changes are merged but have not been retested over the same live scope, so no speedup is promised. Incomplete access or coverage cannot establish a complete size.[^analysis]

### 文件搬家 / File Migration

- **做什么 · 已支持：**把测试文件复制到外接盘，用 SHA-256 校验副本，再单独确认将原件移入废纸篓；本轮副本与原件的哈希一致。[^migration]
- **怎么用：**选择来源与目标盘，扫描并选择项目，执行“复制并验证”；确认副本可用后，再决定是否使用“移到废纸篓”处理原件。[^migration]
- **安全边界：**先复制和验证，原件处理另行确认；同名目标不覆盖。应用搬家当前只保留副本，不自动移走原件。新版原件回执写入失败时不移动，回执与恢复流程为**测试版 · 已合并，待实机复测**。[^migration]
- **限制：**实测版本无法从“操作记录”恢复原件，修复已合并但尚无实机复测。目标只接受可写的物理外接盘，网络卷、只读卷与虚拟磁盘不在此流程范围；应用副本可运行性及应用搬家未获本轮验证。[^migration]

- **Purpose · Supported:** copies test files to an external drive, checks the copy with SHA-256, and separately confirms moving the originals to the Trash. Copy and original hashes matched in the live test.[^migration]
- **Usage:** select a source and destination, scan and select items, then choose Copy and Verify. After checking the copy is usable, decide separately whether to use Move to Trash for the originals.[^migration]
- **Safety boundary:** copying and verification precede a separate confirmation for originals. Existing destination items are not overwritten. App migration is currently copy-only and keeps the original. The new receipt workflow refuses to move originals when receipt writing fails; receipts and recovery are **Beta · merged, awaiting live retest**.[^migration]
- **Limits:** the tested build could not restore originals through Operation History. The fix is merged but lacks a live retest. Destinations must be writable physical external drives; network, read-only, and virtual volumes are excluded. App migration and the usability of copied apps were not verified this round.[^migration]

### 重复文件 / Duplicates

- **做什么 · 测试版：**当前实现按大小筛选，再用内容哈希确认完全相同的文件。本轮因不能仅扫描指定测试位置而受阻，未完成扫描、选择、删除与恢复实测。[^duplicates]
- **怎么用：**添加要扫描的位置，再选择“仅所选位置”；没有添加位置时不能选择该范围。此范围修复已合并，尚待安装后使用测试文件复测。[^duplicates]
- **安全边界：**扫描只读，重复组需要人工审阅，处理时至少保留一份；删除副本需确认并移入废纸篓。仅云端文件跳过内容比对，不应为比较而自动下载。以上为实现约束，不能当作本轮实测通过。[^duplicates]
- **限制：**范围、时间及项目数量上限会限制覆盖，未比较项不等于没有重复。所选位置优先扫描的修复已合并，但完整流程仍为**测试版 · 待实机验证**。[^duplicates]

- **Purpose · Beta:** the implementation filters by size and confirms identical content with hashes. This round was blocked because scans could not be confined to a test location; scanning, selection, deletion, and recovery were not completed.[^duplicates]
- **Usage:** add locations, then choose Selected Only. That scope is unavailable until a location is added. The scope fix is merged and awaits installation and a test-file retest.[^duplicates]
- **Safety boundary:** scanning is read-only, groups require human review, and at least one copy must be retained. Removing copies requires confirmation and uses the Trash. Cloud-only files skip content comparison rather than downloading for it. These are implementation constraints, rather than passing live results this round.[^duplicates]
- **Limits:** scope, time, and item budgets limit coverage; unexamined items do not establish absence of duplicates. Selected-location prioritization is merged, but the complete workflow remains **Beta · awaiting live validation**.[^duplicates]

### 相似照片 / Similar Photos

- **做什么 · 测试版：**当前实现使用本机图片指纹寻找视觉相似照片，供逐张对照；相似不表示文件内容完全相同。本轮与重复文件扫描一起受阻。[^duplicates]
- **怎么用：**从侧栏进入“相似照片”，添加位置并选择扫描范围，再人工查看候选。与重复文件共用位置和范围设置；“仅所选位置”的修复已合并，待实机验证。[^duplicates]
- **安全边界：**本页提供只读对照，不在此页删除照片。需要删除时，用户在访达或照片管理工具里自行确认；不能套用本应用清理回执的恢复承诺。[^duplicates]
- **限制：**本轮未完成发现与对照流程，也未验证识别质量；不承诺覆盖所有图像格式、照片图库或云端照片。界面存在不等于该流程已实测通过。[^duplicates]

- **Purpose · Beta:** uses local image fingerprints to find visually similar photos for individual comparison. Similar appearance does not mean identical file content. This round was blocked alongside duplicate scanning.[^duplicates]
- **Usage:** open Similar Photos from the sidebar, add locations, choose a scope, and review candidates manually. Locations and scopes are shared with Duplicates. The Selected Only fix is merged and awaits live validation.[^duplicates]
- **Safety boundary:** this page is read-only comparison and does not delete photos. Users handle deletion in Finder or their photo-management tool; the app's cleanup-receipt recovery promise does not apply to those actions.[^duplicates]
- **Limits:** discovery, comparison, and matching quality were not verified this round. Coverage of every image format, photo library, or cloud photo is not promised. An available page is not evidence of a passing live workflow.[^duplicates]

## 菜单栏小窗 / Menu-Bar Panel

- **做什么 · 已支持：**提供 CPU 与 GPU、内存、磁盘、网络、传感器、电源与能耗六个模块的概览与详情；本轮操作了六个模块的二级、三级及时间档切换。[^mini]
- **怎么用：**打开菜单栏小窗，悬停进入模块详情，再查看历史与时间档；模块和顺序在“设置 → 小窗”中调整，配色在“设置 → 通用 → 菜单栏小窗”中调整。目前只有一种可用的小窗布局。[^mini]
- **安全边界：**查看读数与历史本身只读。退出应用仍须确认；风扇、充电和电源模式是另行触发的写入操作，不能从监控流程通过推断硬件控制通过。后台采样不得自动解除 macOS 优化电池充电暂停。[^mini]
- **限制：**GPU 频率、进程区初始空白、网速短暂缺值和电源空行等修复已合并，新增功耗与区域温度读数也已合并，但尚待安装实机核对，均为**测试版**。充电上限及临时充满存在已知问题，修复尚未完成实机验证；风扇与电源模式写入未在本轮验证。硬件或系统不提供的读数不能保证显示，历史切档也不承诺固定响应时间。[^mini]

- **Purpose · Supported:** provides overview and details for six modules: CPU & GPU, Memory, Disk, Network, Sensors, and Power & Energy. This round exercised second- and third-level views and history-range switching across the six modules.[^mini]
- **Usage:** open the Menu-Bar Panel, hover into module details, then inspect history and ranges. Adjust modules and their order in Settings → Mini Window, and colors in Settings → General → Menu-Bar Panel. Only one mini-window layout is currently available.[^mini]
- **Safety boundary:** viewing readings and history is read-only. App quitting requires confirmation. Fan, charging, and power-mode controls are separately triggered writes; a passing monitoring workflow does not verify hardware control. Background sampling must not automatically override macOS Optimized Battery Charging pauses.[^mini]
- **Limits:** fixes for GPU frequency, initially empty process lists, brief missing network readings, and empty power rows are merged. Added power and regional temperature readings are also merged, but all await installed-build live checks and remain **Beta**. Charge limits and temporary full charging have known issues, and the fix has not yet been verified on a real Mac; fan and power-mode writes were not verified this round. Unavailable hardware readings and fixed history-switch response times are not promised.[^mini]

## 设置 / Settings

- **做什么 · 已支持：**七个分区可打开：通用、小窗、扫描与安全、权限、系统控制、应用更新、关于。本轮验证了小窗设置修改草稿后“取消”恢复原值。[^settings]
- **怎么用：**从侧栏“设置”进入对应分区。“小窗”先编辑并预览，使用“应用”保存，或用“取消”放弃；“应用”保存未在本轮实测。通用分区有语言与外观选项，选项存在经源码核对，不表示逐个切换已通过。[^settings]
- **安全边界：**预览使用模拟数据，不证明本机支持对应硬件读数。权限页的系统设置跳转不等于已获授权；系统控制选项不等于硬件写入已成功。[^settings]
- **限制：**扫描提醒在实测版一直等待首次扫描；修复已合并但未安装复测，仍为**测试版**。完整磁盘访问、文件夹授权恢复、各类设置保存与硬件控制均未在本轮逐项验证；部分小窗摘要与小窗口布局仍待修整。[^settings]

- **Purpose · Supported:** all seven sections opened: General, Mini Window, Scan & Safety, Access, System Control, App Updates, and About. Cancelling a mini-window draft restored its prior value in the live test.[^settings]
- **Usage:** choose Settings in the sidebar and open a section. Edit and preview Mini Window settings, then use Apply to save or Cancel to discard. Apply was not live-tested this round. Language and appearance options exist in General, as checked in source; individual switching was not verified.[^settings]
- **Safety boundary:** preview data is simulated and does not prove hardware support on this Mac. Opening System Settings from Access does not grant permission, and a System Control option does not establish a successful hardware write.[^settings]
- **Limits:** scan reminders stayed at the first-scan waiting state in the tested build. The fix is merged but awaits installation and retesting, and remains **Beta**. Full Disk Access, restored folder grants, every settings save, and hardware controls were not individually verified this round. Some summaries and small-window layouts still need work.[^settings]

## 安全边界 / Safety Boundaries

- **扫描与写入：**扫描和分析读取数据，不能作为删除授权；清理、卸载、处理原件与硬件控制都有各自的操作入口和确认边界。新版确认及复查约束仍须按上面的测试版状态判断。[^safety]
- **恢复：**本轮已支持的“操作记录”恢复只覆盖清理测试文件和测试应用卸载。搬家原件、文件分析及重复文件恢复尚未实机通过；外接卷可能需要访达放回。浏览器使用独立历史备份。“清空废纸篓”、删除浏览器备份及备份到期均不能套用废纸篓恢复保证。[^safety]
- **结果核对：**扫描列表、用户选择、确认计划、完成结果与回执不是同一个状态。项目变化、权限不足或回执写入问题可能使操作跳过或结果待核实；应查看逐项结果，不把点击按钮当作完成。移入废纸篓也不等于已经释放对应空间。[^safety]

- **Scanning and writes:** reading or analysis does not authorize deletion. Cleanup, uninstall, handling originals, and hardware controls have separate entry points and confirmation boundaries. Revised confirmation and recheck rules retain their Beta status above.[^safety]
- **Recovery:** passing Operation History recovery covers cleanup test files and a test-app uninstall only. Migration-original, File Analysis, and duplicate recovery have not passed a live test; external volumes may require Finder recovery. Browsers use separate history backups. Empty Trash, manual browser-backup deletion, and backup expiry have no Trash-recovery guarantee.[^safety]
- **Checking outcomes:** a scan list, selection, confirmed plan, completion result, and receipt are separate states. Changes, missing access, or receipt-writing problems can cause skips or uncertain outcomes. Inspect item results rather than treating a button click as completion. Moving to the Trash does not establish that the corresponding space has been freed.[^safety]

## 系统要求与限制 / Requirements and Limits

- **系统要求：**项目最低部署目标为 macOS 14；构建脚本默认要求 Apple 芯片架构。最低目标不等于各旧系统或全部硬件已实测通过；本机环境为 macOS 27.2。[^requirements]
- **权限和数据：**可见范围取决于 macOS 权限、所选范围、排除规则、卷状态及硬件接口。云端占位、不可读目录、没有样本和不支持的读数不应解释为零；逐项限制见对应功能。[^requirements]
- **验证范围：**本文不是发布、签名、公证、安装或跨设备兼容证明。未完成的完整性能测试、更新安装、浏览器删除、登录项管理、照片识别及硬件写入仍保留各自验证边界。[^requirements]

- **System requirements:** the minimum deployment target is macOS 14; build scripts require Apple silicon architecture by default. This does not establish live validation on every older system or all hardware. The local environment is macOS 27.2.[^requirements]
- **Access and data:** coverage depends on macOS permissions, scope, exclusions, volume state, and hardware interfaces. Cloud placeholders, unreadable directories, missing samples, and unsupported readings do not establish zero. See each feature's limits.[^requirements]
- **Validation scope:** this document is not proof of release, signing, notarization, installation, or compatibility across devices. Full performance runs, update installation, browser deletion, login-item management, photo matching, and hardware writes retain their individual verification boundaries.[^requirements]

## 依据说明 / Evidence Notes

注释区分实机结果与源码约束。后者用于说明界面和安全规则，不将合并、单元测试或界面存在写成实机通过。实测报告记录的是测试时的版本，修复状态取 2026-10-07 的维护记录；更晚的安装或复测需要重新核对。

These notes distinguish live results from implementation constraints. Source checks explain the interface and safety rules, rather than treating a merge, unit test, or available interface as a passing live test. Reports describe the build tested at the time; fix status uses maintenance records available on October 7, 2026. Later installation or retesting needs a fresh check.

[^scope]: 2026-10-07《功能实测报告》“方法”“逐项结果”“未测与受阻”，以及同日维护记录。已支持范围只采用该报告明确通过的子流程。/ The October 7, 2026 live functional report's methods, item results, and untested/blocked workflows, plus maintenance records from that date. Supported scope uses only explicitly passing workflows.
[^cleanup]: 实测报告“智能扫描／安全清理／开发工具与产物”及垃圾扫描验收结论：分组可选、测试文件移入废纸篓并恢复、符号链接目标未动；清理崩溃修复已安装复测通过。当前清理界面、规则与执行约束经源码核对；完成页、新预选规则和新增工具规则依据已合并维护记录，仍待实机复测；清空废纸篓未运行。/ Live report: shared cleanup row and acceptance results; selectable groups, test-file Trash/recovery, untouched link targets, and a passing installed crash fix. Source checks cover current rules and constraints. Completion, preselection, and added-tool changes remain awaiting live retest; Empty Trash was not run.
[^health]: 实测报告“系统健康”：只读检查、四项证据与评分通过。按钮及另行确认的测速约束经当前界面核对；该报告没有测速通过证据。/ Live report: System Health's read-only check, four evidence-backed indicators, and score passed. Source checks cover the button and separately confirmed speed test; no passing speed-test result is supplied.
[^privacy]: 实测报告“浏览器隐私”“未测与受阻”：Safari 与 Chrome 扫描、显示、单行选择、复制网址；删除待复测。浏览器身份修复的合并状态取维护记录；备份期限、同步处理、恢复警告及直接删除差异经当前处理逻辑和界面核对。/ Live report: Safari/Chrome scanning and presentation, row selection, and Copy Address; deletion awaits retest. Maintenance records establish the merged identity fix. Source checks cover backup retention, synced visits, recovery warnings, and deletion differences.
[^benchmark]: 实测报告“性能测试”：核心阶段完成、扩展阶段取消、正常停止、保留上次完整结果；本次取消未入历史。取消历史与负载提示的合并状态取维护记录，按钮和环境提示经源码核对。/ Live report: completed core stage, cancellation during extensions, normal stop, and preserved prior complete result; the cancelled run was absent from history. Maintenance records cover cancellation-history and load-notice fixes; source checks cover actions and environment notices.
[^startup]: 实测报告“登录项与后台任务”“未测与受阻”：读取与分组通过，停用／启用未运行；状态区分和可管理范围经当前界面及管理逻辑核对。/ Live report: reading and grouped display passed; disable/enable was not run. State distinctions and management limits were checked in the current interface and logic.
[^memory]: 实测报告“内存管理”：显示、选择和取消选择；没有执行退出。报告中的重复点击缺陷及维护记录中的确认修复、前台排除状态共同决定测试版标记；按钮与确认文字经源码核对。/ Live report: display, selection, and deselection, with no quit performed. Its repeated-click defect and the merged confirmation/foreground-exclusion fixes determine Beta status; button and confirmation wording were checked in source.
[^energy]: 实测报告“能耗”：六阶段测量与应用结果可用，整机汇总和覆盖有错。接电汇总、命名修复的状态取维护记录；按钮和只读约束经当前界面核对。/ Live report: six-stage measurement and app results worked, with incorrect whole-system summary and coverage. Maintenance records cover plugged-in summary and naming fixes; source checks cover the action and read-only boundary.
[^uninstall]: 实测报告“卸载”：默认应用本体、测试应用移入废纸篓及恢复通过，未核实关联文件保留；“未测与受阻”明确真实应用卸载未做。预览与权限边界经当前实现核对，其他操作没有本轮实机通过依据。/ Live report: app-only default selection, test-app Trash/recovery, and retention of unverified related files. Real-app removal was not run. Preview and access boundaries were checked in source; other actions lack passing live evidence this round.
[^updates]: 实测报告“应用更新”：来源与版本展示、检查通过，安装未运行。安装约束、重任务等待与更新来源处理经当前实现及维护交接核对；没有本轮端到端安装证据。/ Live report: source/version presentation and checking passed, with no installation. Source and maintenance checks cover installation constraints, heavy-task waiting, and source handling; no end-to-end live installation evidence is supplied.
[^analysis]: 实测报告“文件分析”：分析、下钻、当前层搜索、返回、分栏通过，并记录耗时与内存问题。维护记录中的性能优化与审阅移动已合并，仍待实机验证；当前审阅及外接卷提示经源码核对。/ Live report: analysis, drill-down, current-level search, back navigation, and columns passed, with time/memory issues recorded. Performance and reviewed moves are merged but await live validation; source checks cover review and external-volume notices.
[^migration]: 实测报告“文件搬家”：测试文件外接盘复制、SHA-256 一致、原件移入废纸篓通过，操作记录恢复失败。维护记录中的回执修复已合并，待实机复测；目标限制、同名拒绝与应用只复制规则经当前实现核对。/ Live report: external-drive test-file copy, matching SHA-256, and moving originals to the Trash passed; Operation History recovery failed. The receipt fix is merged and awaits live retest; source checks cover destination limits, collision refusal, and app copy-only handling.
[^duplicates]: 实测报告“重复文件”“相似照片”：指定位置范围问题导致受阻，没有完整扫描或删除结果。范围修复已合并的状态取维护记录；当前范围、哈希、保留副本、云端跳过及相似照片只读对照约束经源码核对。/ Live report: scope restrictions blocked both pages, with no complete scanning or deletion result. Maintenance records cover the merged scope fix; source checks cover scopes, hashes, retained copies, cloud skips, and read-only photo comparison.
[^mini]: 实测报告“菜单栏小窗”及 2026-10-07《小窗与 iStat 对照》：六模块详情、历史与切档的实机观察，并记录缺值和延迟。单一布局、悬停与设置入口经当前源码核对；维护记录中的读数修复与新增传感器仍待安装核对，充电修复尚未完成实机验证。/ Live report and October 7 mini-window comparison: six-module details, history, and range switching, with missing-value and latency issues. Source checks establish one layout, hover behavior, and settings. Merged reading/sensor changes await installed checks; charging repairs await live verification.
[^settings]: 实测报告“设置（7 个分区）”：打开全部分区、修改小窗草稿后取消恢复原值；扫描提醒异常。当前分类、应用／取消、模拟预览、语言外观及权限入口经源码核对；提醒修复状态取维护记录，保存与授权恢复未逐项实测。/ Live report: all seven sections opened and Cancel restored a changed mini-window draft; reminders were incorrect. Source checks cover sections, Apply/Cancel, simulated previews, language/appearance, and access entry points. The reminder fix is merged; saves and grant restoration were not individually live-tested.
[^safety]: 上述实测中的清理与卸载恢复、搬家恢复失败、文件分析只读、重复／相似照片受阻，以及未运行清单；当前各页确认、回执、外接卷恢复和浏览器备份约束。/ The live cleanup/uninstall recovery results, failed migration recovery, read-only File Analysis, blocked duplicates/photos, and untested list above, together with current confirmation, receipt, external-volume, and browser-backup constraints.
[^requirements]: 项目的最低系统声明、构建脚本架构要求、本机 macOS 27.2 环境说明，以及上述实测覆盖与当前范围、权限、卷和硬件约束。最低部署目标与实测覆盖分开记录；未据此推断发行或公证状态。/ Project deployment declaration, build-script architecture requirement, supplied macOS 27.2 environment, and the live coverage plus source constraints above. Deployment target is separate from tested coverage; no release or notarization state is inferred.
