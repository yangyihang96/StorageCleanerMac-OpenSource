# Browser Privacy Parity Matrix

## 对标证据与边界

- 对标对象：本机安装的 storage-analyzer Skill（用户需求中的 Clean Analysiser）。
- 路径：/Users/developer/.codex/skills/storage-analyzer。
- SKILL.md SHA-256：4b41cc77494638ee0f010f5c50b8015e4dff82e522c9184d4bbeba14b776eae4。
- SKILL.md 修改时间：2026-06-02T20:22:25+1000。
- 已读取 SKILL.md、macOS/Windows references、三个 scripts 和 HTML report template；该 Skill 没有 fixtures/examples。
- 重要边界：Skill 是通用磁盘扫描器；当前 Browser Privacy 产品扫描器只读浏览器历史访问记录。浏览器缓存文件已经由安全清理模块的版本化规则处理，本页不复制第二套文件扫描器。
- Chromium 系 8 个注册 Provider（Chrome、Chromium、Edge、Brave、Arc、Opera、Opera GX、Vivaldi）提供直接删除：仅当数据库是精确的 Schema 版本 70／兼容版本 16、浏览器应用的安装位置与签名可确认、路径在注册根目录内、浏览器已退出且没有未合并的写入时才写入。Safari、Orion、Firefox 系和动态发现的衍生浏览器没有写入 Adapter，只生成浏览器内处理步骤。
- 测试夹具里的删除通过，不等于在真实浏览器数据库上做过实机删除验收；实机验收另行记录。

## 对标矩阵

| # | 规则 | Skill / 产品安全基线 | 当前行为（2.0.0 第二轮，2026-10-04） | 代码与验证 |
|---:|---|---|---|---|
| 1 | 浏览器发现 | 只扫描明确目标，不猜测未知位置 | Provider Registry 覆盖 Safari、Chromium/Firefox 家族及已验证衍生浏览器 | BrowserPrivacyProviderRegistry；discovery tests |
| 2 | Profile 发现 | 路径必须在注册根目录内 | 每个 Provider 使用固定 Profile layout 和受信父目录 | provider/scanner path tests |
| 3 | 扫描范围 | 扫描前明确告知范围 | 只读历史 URL、标题、时间、次数；不读网页内容 | Workspace trust copy；scanner tests |
| 4 | Cache | Skill 绿色仅限可再生缓存 | 本页不重复扫描；浏览器缓存走安全清理规则和 Trash 链 | CleanupRules.v2.json；cleanup parity matrix |
| 5 | History | 用户数据，需人工判断 | risk=review；可直接删除的记录为 selectableWithConfirmation，其余为 browserActionOnly，并记录不能直接删除的具体原因 | model + selection tests；scanner blocker test |
| 6 | Downloads | 记录与真实下载文件不同 | 本页尚不扫描；Router 仅能打开浏览器下载管理页 | BrowserPrivacyCleanupRouterTests |
| 7 | Cookies | 会改变登录态 | 不扫描、不自动删除；仅 Router 可提供独立确认的浏览器设置入口 | router safety tests |
| 8 | Session | 会改变登录态和恢复状态 | 不扫描、不加入选择 | source/model audit |
| 9 | Local Storage | 可能含登录态和站点数据 | 不扫描、不加入选择 | source/model audit |
| 10 | IndexedDB | 可能含应用数据 | 不扫描、不加入选择 | source/model audit |
| 11 | Autofill | 个人身份数据 | 不读取、不展示、不处理 | Workspace trust copy tests |
| 12 | Password / Keychain | 受保护，禁止手删 | 不读取；没有进入 Scanner/Router 的删除接口 | safety tests |
| 13 | Bookmark | 用户内容，受保护 | 不读取、不处理 | Workspace trust copy tests |
| 14 | Extension / Profile | 应用结构，受保护 | 不读取、不移动、不破坏 Profile | provider path tests |
| 15 | 风险等级 | 绿/黄/红表达后果 | 独立 BrowserPrivacyRisk；History 为 review | model tests |
| 16 | 选择资格 | 颜色不能代替权限 | 独立 BrowserPrivacySelectionEligibility | model/store tests |
| 17 | 默认选择 | 黄色不得静默自动处理 | 所有历史记录默认不选；高置信分类也不例外 | explicit-selection tests |
| 18 | 选择封装 | View 不直接改内部 Set | Store 私有写入；单项和分组三态均验证 eligibility | selection-state tests |
| 19 | 父级三态 | 不可选项不进入分母 | checked/mixed/unchecked 仅基于可选择的可见记录 | filteredSelectionState tests |
| 20 | 搜索 | 本地处理、避免泄露 | 单一输入框；200 ms debounce；本地匹配网址（域名、路径、查询参数）、标题、浏览器、配置文件显示名和中英文类别名；只因折叠的参数或搜索词命中的行会说明原因 | UI/source + store tests |
| 21 | 排序 | 报告应稳定且可读 | 页面按最近访问、访问次数或浏览器排序；历史行没有独立容量，不提供容量排序 | sort test |
| 22 | 容量 | 只报告真实值 | SQLite 不提供逐历史行字节；选中未知行显示“大小不可用”，不均摊数据库大小 | selection-summary test |
| 23 | 去重 | 同一扫描不重复处理同一身份 | Processor 按 UUID 去重；复核使用稳定 fingerprint multiset | processor/reverification tests |
| 24 | 权限 | denied 必须显式报告 | 紧凑 Banner；用户主动打开 Full Disk Access；权限结果不伪装为空成功 | permission coverage tests |
| 25 | 浏览器运行 | 运行状态不等于风险 | Store 复用现有运行进程 Checker，UI 使用独立 Badge | running-state test |
| 26 | 强制退出 | 不静默终止应用 | Browser Privacy View 不调用 terminate/forceTerminate | verify script + source audit |
| 27 | 写入资格 | 生产写入必须有已验证 Adapter | Chromium 系注册 Provider 返回 chromiumProduction Adapter，其余返回 nil；扫描与写入共用同一个精确 Schema 门槛 | registered-provider tests |
| 28 | 处理前确认 | 黄色需明确用户动作 | 记录默认不选；确认框列出要处理的页面（过多时列出前几个并注明其余数量）；浏览器内处理给出四步流程 | presentation tests |
| 29 | 文件身份 | 写前必须重新验证 | 写路径绑定 provider/profile/path/inode/schema/row identity；生产与夹具走同一条路径 | processor safety tests |
| 30 | 数据库锁 | 活跃数据库不直接修改 | 运行中、sidecar、busy、schema 变化均 fail closed | processor tests |
| 31 | 事务与回读 | 函数返回成功不等于已删除 | 提交前在事务内核对预期终态，提交后重新只读打开再核对一次；仅回读确认不存在的记录从 Store 移除 | processor/store tests |
| 32 | 处理报告 | 区分成功、跳过、失败、不确定 | Report 保留 deleted/failed/indeterminate/manual/unsupported | processing report tests |
| 33 | 复核 | 未看到不等于已删除 | 仅完整覆盖原 Profile 才可显示 no-longer-found | reverification tests |
| 34 | 敏感显示 | 每条记录都能看出是哪个网站的哪个页面（D20） | 行内显示标题与网址（域名＋路径）；查询参数默认折叠，只在展开行或点击“复制网址”时出现，悬停提示也不含查询参数；非网页地址（chrome://、file:// 等）的 #片段同样折叠；手动处理页显示真实网站与页面；本应用不把网址和标题写入设置、日志或诊断导出，也不上传；复制到剪贴板时标记为隐藏、临时内容；标题和网址不能作为文字选中复制（手动处理页的网站名称列表除外）。直接删除前对整个历史数据库所做的备份仍含被删页面，存放的文件夹排除在时间机器之外，7 天后自动删除、最多 12 份（D26），可在结果页或“最近的删除”里提前删除；时间机器里可能仍有浏览器原库的早期副本，本应用不处理 | presentation tests；in-memory source guard；recovery tests |
| 35 | 性能 | 大结果使用稳定、懒加载 UI | Store 预计算筛选/排序，列表用单一 ScrollView + LazyVStack | source contract |
| 36 | 状态稳定 | 扫描不应替换整个已完成页面 | 刷新保留上次结果和选择，失败/取消恢复终态 | refresh tests |
| 37 | 空状态 | 权限/部分扫描不能显示空成功 | 权限、partial、filtered、completed 分开解析 | empty-state tests |
| 38 | Finder | 只显示真实文件位置 | 历史行不对应独立文件，本页不提供 Finder 定位，也不伪造文件路径 | row implementation |
| 39 | 整页删除 | 尽量与浏览器自身删除一致，差异如实列出 | 一行是一个页面的全部访问；访问、来源、标注、聚类、访问过的链接、URL 行、搜索词和分段按 Chromium 自身删除历史的做法处理，有剩余访问时只调整计数与最近访问时间。与 Chromium 的差异：① 加了书签（Chromium 称为固定）的网址，Chromium 保留 urls 行、只调整计数，本应用删除该行；② Chromium 删除一次访问时会连带删除它的重定向上游访问，本应用只删除所选访问，上游访问作为独立页面列出、由用户选择；③ Chromium 还会清理单独的 Favicons 数据库以及热门网站、地址栏快捷联想等其他存储，本应用只修改 History 数据库，这些地方仍可能留有被删页面的网址 | processor tests |
| 40 | 恢复 | 删除前备份可用、到期删除 | “最近的删除”列出删除前的备份（时间、浏览器、配置文件、条数、到期时间），可恢复或删除备份；备份 7 天后自动删除、最多 12 份（D26；恢复过的和结果未知的备份不计入份数，仍按 7 天到期）：应用启动后按最早到期时间安排下一次清理（到期后几秒内删除，最长每小时再查一次），打开本页时也清理；恢复前先备份当前状态，可撤销恢复；恢复较早的备份时再提醒一次；数据库未改动的失败不留备份 | recovery tests |

## 未纳入本页的能力

缓存、下载文件、Cookie、Session、Local Storage、IndexedDB、密码、书签、扩展和完整 Profile 不会因为参考界面出现就被伪造成 Browser Privacy 扫描结果。若未来要把安全缓存候选合并到本页，应复用 ReadOnlyCleanupScanner、CleanPlanBuilder、Preflight、Trash 和执行后验证，不得复制目录扫描或建立第二条删除链。
