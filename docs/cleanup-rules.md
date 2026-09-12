# 1.9.12 清理规则

智能扫描以官方 [`storage-analyzer`](https://github.com/KKKKhazix/khazix-skills/tree/741eb55ba5acf2050b0e209723c2985e956e4f7c/storage-analyzer) 的 macOS 只读扫描和风险语义为规格。App 复用现有 `ReadOnlyCleanupScanner`，将 Skill 当次报告中的项目收敛为版本化原生规则，不嵌入其网页、服务器或删除命令。

## 当前项目级结果

- 开发工具候选：统一目录表明确标注 `npm`、Codex、Claude Code、Cursor、GitHub Copilot、OpenCode 与 OpenClaw 的所属工具和残留类型；缓存、插件缓存与临时文件进入现有时间分级，日志只允许审查和 Finder 定位。
- `.npm/_npx` 与 `.npm/_cacache` 均使用大小写敏感、Unicode 规范等价的精确名称匹配，不会命中 `_npx-backup` 或 `_cacache-old`。AI 工具规则同样只接受目录表中列出的精确子目录，不扫描会话、聊天、项目状态、账号或配置正文。
- 黄色应用/个人数据项目：Downloads、Pictures、微信沙盒、Chrome 用户数据、Codex 会话、ego lite 数据、CrossOver 数据；默认不选。开发工具日志也保持人工审查，但不能进入清理计划。
- 红色应用项目：重复 Xcode 版本、大型视频与创作应用；默认不选。30 天阈值内仍活跃的开发缓存也显示为红色并要求逐项双重确认。
- 蓝色/其他：其余大型已安装应用只参与容量信息，不进入绿黄红清理决策。

## 竞品范围精确覆盖（2026-08-25）

- `ReadOnlyCleanupScanner` 继续作为唯一智能扫描器；新增目录表只提供严格路径、所属软件和动作资格，没有创建第二套 Scanner、Store、Timer 或后台磁盘任务。
- 浏览器缓存精确识别 Chrome、Safari、Edge、Brave、Firefox 与 Arc；应用缓存精确识别 WhatsApp、Codex、ego lite、Typeless 与 Zoom。规则只接受目录表中的精确父路径和精确子目录名，不按名称模糊猜测。
- 开发缓存补充 Playwright MCP、pip、SwiftPM、Clang 与 Bun，并继续套用现有 30 天活动阈值：近期活动显示红色，超过阈值显示黄色，超过一年才显示绿色；不会因位于缓存目录就绕过时间证据。
- 同机复测将原先的通用缓存进一步归属为：Chrome 约 2.76 GB、WhatsApp 约 1.87 GB、Codex 约 773 MB、ego lite 约 520 MB、Typeless 约 330 MB；这些项目默认均不勾选，应用运行或测量不完整时不可执行。
- 界面推荐标签同时受执行资格约束：即使规则原本属于可选缓存，只要测量不完整、应用仍在运行或其他前置条件不满足，就显示“仅供查看”，不会显示成可执行的“可选”。
- Apple Mail 深层 `Attachments` 目录使用同一只读扫描器做后代匹配和聚合，本机约 318 MB。结果只统计并定位 `~/Library/Mail`，不修改 Mail 数据库、不逐目录制造大量结果，也不能进入清理计划；遍历遇到权限失败、符号链接或占位内容时容量自动降级为“至少占用”。
- CloudKit 缓存、macOS 诊断日志和 Codex 日志会被精确标明归属但保持只读；个人废纸篓只显示占用，清空仍必须走专门的不可恢复操作确认流程。
- 应用内部语言资源和 Universal Binary 架构切片仍不作为可清理候选。修改已签名 App 会破坏签名或更新完整性；在没有独立只读分析与签名恢复方案前，不用竞品容量口径伪造安全清理能力。

页面按“风险层 → 主项目 → 子项目”显示，三种风险层默认收起。风险摘要和选择摘要统计主项目数；展开后再显示实际路径明细，避免把一个主项目的多个子路径误报为多个清理项目。

## 选择与执行

- 风险颜色只表达安全风险，不再决定推荐等级或默认选择。`recommended`、`optional`、`notRecommended`、`advisoryOnly` 与 `selected`、`unselected`、`forbidden` 分别记录。
- 绿色：只有规则明确写为 `defaultSelection=selected` 的项目才会初始勾选；可选绿色项目仍可执行，但默认不选。
- 黄色：Downloads 明细可由用户逐项手选并额外确认；Pictures、聊天/浏览器/Profile/应用数据只允许定位或使用所属应用管理，不能整根移入废纸篓。
- 红色：允许逐项手选，但必须是规则明确授权的应用，或最近仍有活动的开发工具候选。两类项目都经过两次明确确认且只能移入废纸篓；应用仍需 Bundle ID/重复副本证据，开发候选仍需冻结的时间证据。红色永不默认选择，也不参与顶层“选择绿色项目”。
- 蓝色/其他：只读，不进入任何清理计划。

红色可选择是本产品相对原始 Skill “仅打开审查”的有意安全扩展，不伪装为 Skill 自带行为。扫描结果的项目、路径和风险语义保持一致，处置仍使用 App 更严格的安全链。

## 安全边界

- 扫描使用 Foundation/Darwin 文件元信息和只读目录枚举，不调用删除命令。
- 开发工具活动阈值默认 30 天，可在 30–364 天内设置：目录内最近一次可读修改超过 365 天为绿色并默认选择；超过所设阈值但不超过 365 天为黄色；阈值以内为红色且默认不选。边界采用“超过”，因此正好 365 天仍为黄色、正好达到所设阈值仍为红色。
- 活动判断会取候选目录及其可读后代中的最新修改时间。macOS 文件系统修改时间不是完整的版本控制历史，因此界面只陈述“最近可读修改”；预检和移动前会重新遍历，发现扫描后的变化即拒绝执行并要求重扫。
- iCloud、OneDrive、网络盘等同步或远端根不能当作普通本地垃圾删除。
- 微信、Chrome、Pictures、Codex 会话、ego lite Profile 和 CrossOver Bottle 不按缓存处理。
- npm 的 0%/100% 等概念不适用；仅规则精确列出的 `_npx`、`_cacache` 和 AI 工具明确缓存/临时目录可进入时间分级，其他源码、会话、聊天历史、项目索引、插件状态、凭据或设置不会因此自动获得删除资格。
- 容量测量分为 `complete`、`lowerBound`、`failed`。只有完整测量可进入计划；部分值显示“至少占用”，失败显示“无法计算”。
- 应用规则只接受 `/Applications` 一级 `.app`，并使用真实 Bundle ID 白名单或重复 Bundle ID 分组；不按显示名称猜测。
- 选择和容量来自同一 `ScanSession`；筛选、排序和折叠不改变稳定 `ScanCandidateID`。
- 执行链保持为：`ScanSession → CleanupSelection → CleanPlan → Preflight → Confirmation → Identity Recheck → Trash/Quarantine → Verification → Report`。
- 本轮所有 Skill/App 对照均为只读；没有触发 Skill 删除服务，也没有按下 App 清理确认。

## 容量口径

Skill 使用 `du -sk`，App 使用文件系统 allocated bytes 优先、logical bytes 回退。两者在同一路径上表达同一对象，但活跃目录会随扫描时刻变化，且不承诺逐字节相等。遇到权限失败、符号链接、用户排除子树或深度边界时，App 只保留已知下界并禁止执行，不能把部分值冒充精确容量。验收以项目、真实绝对路径、风险、动作资格和默认选择一致为硬条件；容量必须来自各自当次真实扫描，禁止硬编码旧报告数值。
