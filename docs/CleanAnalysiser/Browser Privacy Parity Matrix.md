# Browser Privacy Parity Matrix

## 对标证据与边界

- 对标对象：本机安装的 storage-analyzer Skill（用户需求中的 Clean Analysiser）。
- 路径：/Users/developer/.codex/skills/storage-analyzer。
- SKILL.md SHA-256：4b41cc77494638ee0f010f5c50b8015e4dff82e522c9184d4bbeba14b776eae4。
- SKILL.md 修改时间：2026-06-02T20:22:25+1000。
- 已读取 SKILL.md、macOS/Windows references、三个 scripts 和 HTML report template；该 Skill 没有 fixtures/examples。
- 重要边界：Skill 是通用磁盘扫描器；当前 Browser Privacy 产品扫描器只读浏览器历史访问记录。浏览器缓存文件已经由安全清理模块的版本化规则处理，本页不复制第二套文件扫描器。
- 生产 Provider 不授予历史数据库写入 Adapter。当前页只生成浏览器内处理步骤；测试 Fixture 的事务删除能力不等于真实浏览器数据库已获准修改。

## 对标矩阵

| # | 规则 | Skill / 产品安全基线 | 当前 1.9.10 行为 | 代码与验证 |
|---:|---|---|---|---|
| 1 | 浏览器发现 | 只扫描明确目标，不猜测未知位置 | Provider Registry 覆盖 Safari、Chromium/Firefox 家族及已验证衍生浏览器 | BrowserPrivacyProviderRegistry；discovery tests |
| 2 | Profile 发现 | 路径必须在注册根目录内 | 每个 Provider 使用固定 Profile layout 和受信父目录 | provider/scanner path tests |
| 3 | 扫描范围 | 扫描前明确告知范围 | 只读历史 URL、标题、时间、次数；不读网页内容 | Workspace trust copy；scanner tests |
| 4 | Cache | Skill 绿色仅限可再生缓存 | 本页不重复扫描；浏览器缓存走安全清理规则和 Trash 链 | CleanupRules.v2.json；cleanup parity matrix |
| 5 | History | 用户数据，需人工判断 | risk=review，生产 eligibility=browserActionOnly | model + selection tests |
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
| 20 | 搜索 | 本地处理、避免泄露 | 单一输入框；200 ms debounce；本地匹配浏览器、Profile、域名元数据和类别 | UI/source + store tests |
| 21 | 排序 | 报告应稳定且可读 | Store 预计算容量/最近访问/浏览器排序；未知容量不伪造 | Store implementation |
| 22 | 容量 | 只报告真实值 | SQLite 不提供逐历史行字节；选中未知行显示“大小不可用”，不均摊数据库大小 | selection-summary test |
| 23 | 去重 | 同一扫描不重复处理同一身份 | Processor 按 UUID 去重；复核使用稳定 fingerprint multiset | processor/reverification tests |
| 24 | 权限 | denied 必须显式报告 | 紧凑 Banner；用户主动打开 Full Disk Access；权限结果不伪装为空成功 | permission coverage tests |
| 25 | 浏览器运行 | 运行状态不等于风险 | Store 复用现有运行进程 Checker，UI 使用独立 Badge | running-state test |
| 26 | 强制退出 | 不静默终止应用 | Browser Privacy View 不调用 terminate/forceTerminate | verify script + source audit |
| 27 | 写入资格 | 生产写入必须有已验证 Adapter | 注册 Provider 始终返回 nil；生产记录进入浏览器内处理 | registered-provider tests |
| 28 | 处理前确认 | 黄色需明确用户动作 | 记录默认不选；用户选择后再打开确认和四步流程 | presentation tests |
| 29 | 文件身份 | 写前必须重新验证 | Fixture 写路径绑定 provider/profile/path/inode/schema/row identity | processor safety tests |
| 30 | 数据库锁 | 活跃数据库不直接修改 | 运行中、sidecar、busy、schema 变化均 fail closed | processor tests |
| 31 | 事务与回读 | 函数返回成功不等于已删除 | Fixture 事务后重新只读打开；仅回读不存在的 ID 从 Store 移除 | processor/store tests |
| 32 | 处理报告 | 区分成功、跳过、失败、不确定 | Report 保留 deleted/failed/indeterminate/manual/unsupported | processing report tests |
| 33 | 复核 | 未看到不等于已删除 | 仅完整覆盖原 Profile 才可显示 no-longer-found | reverification tests |
| 34 | 敏感显示 | 默认最小披露 | 标题、完整 URL、查询和真实域名隐藏；复制域名必须单独点击 | presentation leakage tests |
| 35 | 性能 | 大结果使用稳定、懒加载 UI | Store 预计算筛选/排序，列表用单一 ScrollView + LazyVStack | source contract |
| 36 | 状态稳定 | 扫描不应替换整个已完成页面 | 刷新保留上次结果和选择，失败/取消恢复终态 | refresh tests |
| 37 | 空状态 | 权限/部分扫描不能显示空成功 | 权限、partial、filtered、completed 分开解析 | empty-state tests |
| 38 | Finder | 只显示真实文件位置 | 只有存在可信数据库 locator 时显示 Finder；逻辑历史行不伪造文件路径 | row implementation |

## 未纳入本页的能力

缓存、下载文件、Cookie、Session、Local Storage、IndexedDB、密码、书签、扩展和完整 Profile 不会因为参考界面出现就被伪造成 Browser Privacy 扫描结果。若未来要把安全缓存候选合并到本页，应复用 ReadOnlyCleanupScanner、CleanPlanBuilder、Preflight、Trash 和执行后验证，不得复制目录扫描或建立第二条删除链。
