# 存储清理助手 1.9.6 清理架构设计

日期：2026-07-24

状态：已批准，并已在 1.9.6 候选源码中实现

审计基线：`v1.9.5`（`e53c02a`）

目标版本：1.9.6

## 1. 范围

本设计只定义清理功能的模块边界、数据契约、状态机、迁移、feature flag、测试边界和回滚方法，不实现扫描或删除。

1.9.6 清理链路目标：

```text
UI
  → CleanupWorkflowStore
  → CleanupRuleSet
  → ReadOnlyCleanupScanner
  → ScanSession / ScanCandidate
  → CleanupSelection
  → CleanPlanBuilder
  → immutable CleanPlan
  → SafeCleanupExecutor
  → CleanReport
```

### 1.1 必须保持的 1.9.5 安全边界

- 扫描阶段只能读取元数据和目录内容，不能删除、移动、修改、下载或水合文件。
- 只有安全级别候选可以进入清理计划。
- 推荐只决定默认勾选，不代表用户已经同意。
- 执行前必须再次确认。
- 普通清理只能移入系统废纸篓，不能在失败后降级为永久删除。
- 黄色、红色、应用本体、云盘、用户文档和未知项目只能审查或在访达中显示。
- 清空废纸篓是独立的永久操作，不能成为一键清理计划的一部分。
- 不使用特权辅助程序执行普通清理。
- 真实硬件信息、文件信息或权限状态读取失败时必须显示不可用，不能伪造。

现有分级和目录边界继续以 [`docs/cleanup-rules.md`](../../cleanup-rules.md) 为最低安全要求。

### 1.2 非目标

- 不模仿或复制其他清理软件的源码、资源、图标或文案。
- 不增加远程规则下载或远程 feature flag 服务。
- 不增加自动后台清理。
- 不增加定时永久删除。
- 不扫描整个系统根目录。
- 不把浏览历史、隐私数据库或应用本体纳入普通文件清理执行器。
- 不在本阶段修改 Swift 源码、构建、安装或运行真实清理。

## 2. 威胁模型与强制不变量

### 2.1 需要防止的情况

- 扫描后文件被同路径新文件或目录替换。
- 符号链接或路径组件在确认后发生变化。
- 路径逃出规则允许根目录或用户 Home。
- 外部卷卸载后，同一个挂载点被其他卷复用。
- 云占位文件因扫描被自动下载。
- 硬链接被重复计数或重复加入计划。
- 权限拒绝、读取超时或文件消失被误报为“没有垃圾”。
- 用户确认后，UI 选择变化偷偷改变执行内容。
- 旧规则的默认选择在风险升级后继续生效。
- 取消、超时或部分失败后 UI 进入无法解释的组合状态。
- 测试误操作用户真实 Home、废纸篓、外接盘或云盘。

### 2.2 不变量

1. `ReadOnlyCleanupScanner` 的依赖类型不提供写入方法。
2. `CleanPlan` 只能由 `CleanPlanBuilder` 从当前 `ScanSession` 和叶子选择生成。
3. `SafeCleanupExecutor` 不接受任意路径、`StorageItem` 或 UI 行模型。
4. 执行器只能处理 `CleanPlan.items` 中的项目。
5. 每个计划项目必须保存扫描时文件身份和允许根目录。
6. 执行前必须重新读取身份、卷、类型、路径组件和云状态。
7. 任一复核失败只跳过对应项目，不能扩大路径、降低风险或改为永久删除。
8. 计划在执行开始后不可修改，并且最多执行一次。
9. 取消只在项目边界生效；当前正在执行的系统废纸篓移动必须完成或返回错误。
10. 执行报告分别表达已移入废纸篓、跳过、失败和未处理，不能统一显示为“已释放”。
11. V2 规则、会话或计划校验失败时必须 fail closed。
12. feature flag 必须同时在 UI 协调层和执行器边界检查。

## 3. 模块边界

| 模块 | 职责 | 明确不负责 |
|---|---|---|
| `CleanupRuleLoader` | 从签名 App 内资源读取规则并解析 | 不访问网络、不扫描文件 |
| `CleanupRuleValidator` | 校验 schema、根目录、风险和动作组合 | 不自动修正规则 |
| `ReadOnlyCleanupScanner` | 只读枚举、生成候选和扫描问题 | 不选择、不移动、不删除 |
| `CleanupSelection` | 保存叶子候选选择并派生三态 | 不保存路径、不执行 |
| `CleanPlanBuilder` | 从会话和选择生成不可变计划 | 不访问文件系统、不执行 |
| `SafeCleanupExecutor` | 复核计划并逐项移入废纸篓 | 不重新分类、不接受任意路径 |
| `CleanReportStore` | 保存结构化报告和恢复回执 | 不把估算大小称为实际释放 |
| `CleanupWorkflowStore` | 驱动 UI 状态机和任务生命周期 | 不包含规则判断或路径安全逻辑 |

模块之间使用值类型传递。只有扫描器、执行器和工作流协调器需要 actor 隔离。

## 4. 配置驱动规则

### 4.1 规则来源

1.9.6 只加载随签名 App 打包的 `Resources/CleanupRules.v1.json`。不读取远程规则，不接受用户编辑的 JSON，也不把 `UserDefaults` 内容解释成路径规则。

规则资源包含：

```json
{
  "schemaVersion": 1,
  "rulesVersion": "2026.07.24.1",
  "rules": [
    {
      "id": "system.user-caches",
      "selectionPolicyVersion": 1,
      "titleKey": "cleanup.rule.userCaches.title",
      "root": {
        "kind": "homeRelative",
        "path": "Library/Caches"
      },
      "maximumDepth": 4,
      "minimumAgeDays": 0,
      "include": {
        "entryKinds": ["regularFile", "directory"],
        "extensions": [],
        "namePrefixes": []
      },
      "exclude": {
        "relativePrefixes": [],
        "extensions": []
      },
      "cloudPolicy": "skipPlaceholder",
      "risk": "safe",
      "recommendation": "recommended",
      "allowsManualSelection": true,
      "action": "moveToTrash",
      "requiredClosedBundleIDs": [],
      "reasonKey": "cleanup.rule.userCaches.reason"
    }
  ]
}
```

示例只定义结构，不代表最终规则内容。阶段 3 必须从现有 1.9.5 规则逐项迁移并进行安全审查。

### 4.2 接口草案

```swift
struct CleanupRuleSet: Codable, Sendable {
    let schemaVersion: Int
    let rulesVersion: String
    let rules: [CleanupRule]
}

struct CleanupRule: Codable, Identifiable, Sendable {
    let id: String
    let selectionPolicyVersion: Int
    let titleKey: String
    let root: CleanupRuleRoot
    let maximumDepth: Int
    let minimumAgeDays: Int
    let include: CleanupRuleMatch
    let exclude: CleanupRuleExclusion
    let cloudPolicy: CleanupCloudPolicy
    let risk: CleanupRisk
    let recommendation: CleanupRecommendationLevel
    let allowsManualSelection: Bool
    let action: CleanupRuleAction
    let requiredClosedBundleIDs: [String]
    let reasonKey: String
}

enum CleanupRuleAction: String, Codable, Sendable {
    case moveToTrash
    case revealOnly
}

enum CleanupCloudPolicy: String, Codable, Sendable {
    case metadataOnly
    case skipPlaceholder
    case excludeCloudRoots
}

struct CleanupRuleRoot: Codable, Sendable {
    let kind: CleanupRuleRootKind
    let path: String
}

enum CleanupRuleRootKind: String, Codable, Sendable {
    case homeRelative
    case grantedFolderRelative
}

struct CleanupRuleMatch: Codable, Sendable {
    let entryKinds: Set<FileEntryKind>
    let extensions: Set<String>
    let namePrefixes: [String]
}

struct CleanupRuleExclusion: Codable, Sendable {
    let relativePrefixes: [String]
    let extensions: Set<String>
}
```

### 4.3 规则校验

`CleanupRuleValidator` 必须在扫描前一次性验证整个规则集：

- `schemaVersion` 必须是 App 支持的版本。
- `rulesVersion` 和所有规则 ID 必须非空且唯一。
- `selectionPolicyVersion` 必须大于 0。
- 相对路径不得为空，不得包含 `..`、空组件、NUL 或路径展开语法。
- 禁止把 `/`、用户 Home、`Library` 根目录、`Applications`、`Desktop`、`Documents`、`Downloads`、媒体资料库或云盘根目录标记为安全自动清理。
- `moveToTrash` 只能与 `.safe` 风险组合。
- `.reviewOnly`、`.protected` 或未知风险只能使用 `.revealOnly`。
- 非 `.safe` 规则的 `allowsManualSelection` 必须是 `false`。
- `maximumDepth` 和年龄阈值必须落在硬编码安全上限内。
- 不支持正则表达式、Shell 命令、通配路径展开或任意可执行参数。
- 规则集任一项无效时，整个 V2 扫描不可启动，不能忽略坏规则继续执行。

错误使用稳定机器码：

```swift
enum CleanupRuleValidationError: Error, Equatable {
    case unsupportedSchema(Int)
    case duplicateRuleID(String)
    case invalidRelativePath(ruleID: String)
    case forbiddenRoot(ruleID: String)
    case unsafeActionRiskCombination(ruleID: String)
    case invalidLimit(ruleID: String)
}
```

## 5. 只读扫描器

### 5.1 只读文件系统接口

扫描器使用只暴露读取能力的接口，避免误把 `FileManager` 写入 API 带入扫描层：

```swift
protocol ReadOnlyFileSystem: Sendable {
    func metadata(at url: URL) async throws -> FileSnapshot
    func children(
        of directory: URL,
        keys: Set<FileMetadataKey>
    ) async throws -> [URL]
}

actor ReadOnlyCleanupScanner {
    init(
        fileSystem: any ReadOnlyFileSystem,
        ruleSet: CleanupRuleSet
    )

    func scan(
        request: ScanRequest,
        progress: @Sendable (ScanProgressEvent) async -> Void
    ) async throws -> ScanSession
}

enum FileMetadataKey: Hashable, Sendable {
    case identity
    case entryKind
    case sizes
    case dates
    case volume
    case cloudState
    case symbolicLinkState
}

enum CleanupScanMode: String, Codable, Sendable {
    case quick
    case standard
    case deep
}

struct ScanRequest: Sendable {
    let mode: CleanupScanMode
    let userHomeURL: URL
    let grantedScopeURLs: [URL]
    let excludedURLs: [URL]
}
```

生产实现只包装 `FileManager`、`URLResourceValues`、`lstat/stat` 和必要的只读系统查询。接口中不得出现：

- `removeItem`
- `moveItem`
- `trashItem`
- 文件写入句柄
- 权限提升
- 云文件下载
- 任意 Shell 命令

如果保留 `/usr/bin/du`，必须使用固定绝对路径、固定参数白名单、超时、取消和输出上限；不能把规则内容直接拼接为命令参数。优先使用文件元数据，只有明确需要时才调用 `du`。

### 5.2 扫描行为

- 使用结构化并发，不创建超时后继续失控运行的孤立 worker。
- 每进入目录和每处理固定数量条目检查一次取消。
- 默认不跟随符号链接。
- 记录硬链接身份并按设备号和 inode 去重。
- 外部卷记录卷身份；卷不可用时生成问题，不重试到其他挂载点。
- 云占位项目只读元数据并跳过内容；无法确认状态时按规则跳过。
- 文件在扫描中消失是正常变化，记录为 `vanished`，不视为致命错误。
- 权限拒绝和超时不得返回普通空分类。
- 扫描结果可以是 `complete`、`partial` 或 `cancelled`。
- 扫描取消后可以保留已经完成的只读摘要，但不能从取消会话生成清理计划。

### 5.3 进度语义

扫描前无法知道真实总文件数，因此不得显示伪精确百分比。

```swift
struct ScanProgressEvent: Sendable {
    let phase: ScanPhase
    let currentRuleID: String?
    let completedRuleCount: Int
    let totalRuleCount: Int
    let discoveredItemCount: Int
    let estimatedBytes: Int64
}

enum ScanPhase: Sendable {
    case preparing
    case enumerating
    case classifying
    case finalizing
}
```

UI 主进度保持不确定状态；`completedRuleCount / totalRuleCount` 只显示为“已完成分类数”，不能作为总体线性进度条。

## 6. 扫描会话与候选

### 6.1 身份类型

```swift
struct ScanSessionID: Hashable, Codable, Sendable {
    let rawValue: UUID
}

struct ScanCandidateID: Hashable, Codable, Sendable {
    let rawValue: UUID
}

struct CleanPlanID: Hashable, Codable, Sendable {
    let rawValue: UUID
}

struct FileIdentity: Hashable, Codable, Sendable {
    let deviceID: UInt64
    let inode: UInt64
    let entryKind: FileEntryKind
    let creationTimeNanoseconds: Int64?
}

enum FileEntryKind: String, Codable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}
```

`deviceID + inode + entryKind` 是主要身份；创建时间用于增加替换检测证据，不能单独作为身份。

### 6.2 文件快照

```swift
struct FileSnapshot: Hashable, Codable, Sendable {
    let identity: FileIdentity
    let standardizedPath: String
    let volumeIdentifier: String
    let logicalSizeBytes: Int64
    let allocatedSizeBytes: Int64?
    let modificationTimeNanoseconds: Int64?
    let isWritableVolume: Bool
    let isCloudItem: Bool
    let isCloudPlaceholder: Bool
    let hasSymbolicLinkComponent: Bool
}
```

### 6.3 扫描候选

```swift
struct ScanCandidate: Identifiable, Sendable {
    let id: ScanCandidateID
    let sessionID: ScanSessionID
    let ruleID: String
    let ruleSelectionPolicyVersion: Int
    let sourceURL: URL
    let allowedRootURL: URL
    let snapshot: FileSnapshot
    let risk: CleanupRisk
    let recommendation: CleanupRecommendation
    let isManuallySelectable: Bool
    let action: CleanupRuleAction
    let requiredClosedBundleIDs: [String]
    let reasonCode: String
}
```

候选必须是值类型。候选生成后不允许 UI 修改风险、动作、路径或身份。

### 6.4 扫描会话

```swift
struct ScanSession: Identifiable, Sendable {
    let id: ScanSessionID
    let rulesVersion: String
    let startedAt: Date
    let completedAt: Date
    let outcome: ScanOutcome
    let candidates: [ScanCandidate]
    let issues: [ScanIssue]
    let metrics: ScanMetrics
}

enum ScanOutcome: Sendable {
    case complete
    case partial
    case cancelled
}

struct ScanIssue: Identifiable, Sendable {
    let id: UUID
    let ruleID: String?
    let path: String?
    let kind: ScanIssueKind
}

enum ScanIssueKind: String, Codable, Sendable {
    case permissionDenied
    case timedOut
    case vanished
    case unreadable
    case metadataUnavailable
    case symbolicLinkSkipped
    case cloudPlaceholderSkipped
    case volumeUnavailable
}

struct ScanMetrics: Sendable {
    let visitedEntryCount: Int
    let candidateCount: Int
    let deduplicatedIdentityCount: Int
    let estimatedCandidateBytes: Int64
    let duration: TimeInterval
}
```

会话只存在于当前 App 运行期。1.9.6 不把完整候选路径集合持久化到 `UserDefaults`，避免重启后执行陈旧计划。

## 7. 风险与推荐模型

风险决定允许的动作，推荐只决定默认勾选，两者不能合并为一个分数。

```swift
enum CleanupRisk: String, Codable, Sendable {
    case safe
    case reviewOnly
    case protected
    case informational
}

enum CleanupRecommendationLevel: String, Codable, Sendable {
    case recommended
    case optional
    case notRecommended
    case blocked
}

struct CleanupRecommendation: Codable, Sendable {
    let level: CleanupRecommendationLevel
    let reasonCode: String
    let evidenceCodes: [String]
}
```

约束：

- `.safe + .recommended`：默认勾选，可以进入计划。
- `.safe + .optional`：默认不勾选，用户可勾选。
- `.safe + .notRecommended`：默认不勾选，仍需显示原因；只有 `allowsManualSelection` 为真时用户才能选择。
- `.blocked`：不能选择。
- `.reviewOnly`、`.protected`、`.informational`：不能进入 Clean Plan。
- 推荐不得自动触发清理。
- 不显示无法解释的“AI 置信度”或伪精确评分。
- 文案通过稳定 `reasonCode/evidenceCodes` 本地化，执行器不依赖显示文案。

## 8. 三态选择

### 8.1 数据模型

只保存可执行叶子候选 ID；分类和子分类的状态由子项实时派生。

```swift
enum TriStateSelection: Sendable {
    case unchecked
    case checked
    case mixed
}

struct CleanupSelection: Sendable {
    private(set) var selectedCandidateIDs: Set<ScanCandidateID>

    mutating func setCandidate(
        _ candidateID: ScanCandidateID,
        selected: Bool,
        in session: ScanSession
    )

    mutating func setRuleGroup(
        ruleID: String,
        selected: Bool,
        in session: ScanSession
    )

    func state(
        for candidateIDs: [ScanCandidateID],
        in session: ScanSession
    ) -> TriStateSelection
}
```

### 8.2 选择规则

- 只有当前会话内、风险允许且动作是 `moveToTrash` 的候选可以进入集合。
- 父级 `checked` 表示所有可选择子项已选，不包含不可选择子项。
- 没有可选择子项的分组显示禁用，不显示误导性的半选。
- 扫描会话变化后创建新的 `CleanupSelection`，不复用候选 ID。
- UI 同时显示“发现大小”和“已选大小”。
- 默认选择根据推荐和用户规则偏好计算一次，之后由用户选择控制。

### 8.3 规则偏好

偏好只保存规则级默认选择，不保存文件路径或候选 ID：

```swift
struct RuleSelectionPreference: Codable, Sendable {
    let ruleID: String
    let selectionPolicyVersion: Int
    let isSelectedByDefault: Bool
    let changedAt: Date
}
```

当规则的 `selectionPolicyVersion` 变化、风险升级、动作变化或规则消失时，旧偏好失效并使用新的安全默认值。

## 9. 不可变 Clean Plan

### 9.1 计划模型

```swift
struct CleanPlan: Identifiable, Sendable {
    let id: CleanPlanID
    let sessionID: ScanSessionID
    let rulesVersion: String
    let createdAt: Date
    let scanWasPartial: Bool
    let items: [CleanPlanItem]
    let estimatedMovableBytes: Int64
}

struct CleanPlanItem: Identifiable, Sendable {
    let id: UUID
    let candidateID: ScanCandidateID
    let ruleID: String
    let ruleSelectionPolicyVersion: Int
    let sourceURL: URL
    let allowedRootURL: URL
    let expectedSnapshot: FileSnapshot
    let action: CleanupRuleAction
    let requiredClosedBundleIDs: [String]
    let reasonCode: String
}
```

所有属性使用 `let`。`CleanPlan` 不公开可从任意 URL 构造的初始化器。

### 9.2 生成接口

```swift
struct CleanPlanBuilder {
    func makePlan(
        session: ScanSession,
        selection: CleanupSelection,
        activeRules: CleanupRuleSet,
        now: Date
    ) throws -> CleanPlan
}
```

生成时验证：

- 会话不是 `.cancelled`。
- 会话是当前活动会话。
- 会话规则版本等于活动规则版本。
- 每个选择 ID 存在且属于当前会话。
- 每个候选仍为 `.safe`、允许选择且动作为 `.moveToTrash`。
- 规则 ID 和 `selectionPolicyVersion` 一致。
- 没有重复路径或重复文件身份。
- 计划非空。

计划只保存在内存中：

- 切换会话、重新扫描、退出 App 或规则版本变化立即失效。
- 计划确认后，修改结果页选择不会改变已确认计划。
- 同一计划最多执行一次。
- 计划摘要必须在用户确认界面显示条目数、估算大小、部分扫描警告和“移入废纸篓”动作。

## 10. 安全执行器

本节只定义阶段 7 的接口和边界。阶段 2 不实现执行器。

### 10.1 写入边界

扫描层不依赖写入接口。只有执行器可以持有最小写入能力：

```swift
protocol TrashMoving: Sendable {
    func moveToTrash(_ url: URL) async throws -> URL
}

struct CleanupExecutionContext: Sendable {
    let featureConfiguration: CleanupFeatureConfiguration
    let activeSessionID: ScanSessionID
    let activeRulesVersion: String
    let userHomeURL: URL
    let excludedURLs: [URL]
}

struct CleanupExecutionProgress: Sendable {
    let planID: CleanPlanID
    let processedItemCount: Int
    let totalItemCount: Int
    let movedItemCount: Int
    let skippedItemCount: Int
    let failedItemCount: Int
    let currentRuleID: String?
}

actor SafeCleanupExecutor {
    init(
        metadataReader: any ReadOnlyFileSystem,
        trashMover: any TrashMoving,
        heavyWorkCoordinator: HeavyWorkCoordinator
    )

    func execute(
        plan: CleanPlan,
        context: CleanupExecutionContext,
        progress: @Sendable (CleanupExecutionProgress) async -> Void
    ) async -> CleanReport
}
```

`TrashMoving` 有两个实现：

- 生产环境：基于 `FileManager.trashItem`。
- 测试环境：只记录请求的 fake；真实文件系统集成测试仅操作临时夹具。

执行器不得提供永久删除、递归删除或任意路径入口。清空废纸篓保留为独立服务和独立确认流程。

### 10.2 执行前复核顺序

每个计划项目按以下顺序检查：

1. feature mode 必须为 `.v2Full`。
2. 计划 ID 尚未执行或消费。
3. 计划会话仍是活动会话。
4. 活动规则版本、规则 ID、风险、动作和选择策略版本一致。
5. `sourceURL` 和 `allowedRootURL` 都是绝对文件 URL。
6. 标准化路径仍位于允许根目录和用户允许范围。
7. 所有路径组件使用 `lstat` 检查，不允许符号链接替换。
8. 重新读取设备号、inode、类型和创建时间，与扫描快照一致。
9. 卷身份相同、仍挂载且允许写入。
10. 当前排除路径没有覆盖该项目。
11. 云项目状态仍允许处理；占位或不确定状态跳过。
12. 要求关闭相关 App 的规则必须满足前置条件。
13. 在调用系统废纸篓 API 前立即进行第二次轻量身份检查。

任一检查失败返回结构化 `skipped`，不得尝试“修复路径”或扩大搜索。

### 10.3 执行语义

- 项目串行移动，降低竞态和磁盘压力。
- 每个项目完成后检查取消。
- 取消不会中断正在进行的系统移动；当前项目完成后停止后续项目。
- 单项失败不阻止其他独立项目，除非发生计划来源、规则版本或执行器完整性错误。
- 系统废纸篓移动失败时直接报告失败，不回退为 `removeItem`。
- 保存系统返回的废纸篓 URL和移动后身份，供恢复使用。
- 执行前后都不修改规则、计划或原扫描会话。
- `HeavyWorkCoordinator` 继续确保一个清理重任务租约。

公共 Trash API 以路径为输入，身份复核和移动之间仍存在极短的同用户竞态窗口。1.9.6 使用双重 `lstat`、串行执行、规则根边界和移动后身份记录降低风险；不能在文档中宣称完全原子。

## 11. 清理报告

### 11.1 报告接口

```swift
struct CleanReport: Identifiable, Codable, Sendable {
    let id: UUID
    let planID: CleanPlanID
    let sessionID: ScanSessionID
    let rulesVersion: String
    let startedAt: Date
    let completedAt: Date
    let outcome: CleanReportOutcome
    let items: [CleanReportItem]
    let summary: CleanReportSummary
}

enum CleanReportOutcome: String, Codable, Sendable {
    case completed
    case partiallyCompleted
    case cancelled
    case failed
}

struct CleanReportItem: Identifiable, Codable, Sendable {
    let id: UUID
    let planItemID: UUID
    let ruleID: String
    let sourcePath: String
    let estimatedBytes: Int64
    let outcome: CleanItemOutcome
}

enum CleanItemOutcome: Codable, Sendable {
    case movedToTrash(TrashMoveReceipt)
    case skipped(CleanSkipReason)
    case failed(CleanFailure)
    case notProcessed
}

struct TrashMoveReceipt: Codable, Sendable {
    let trashURL: URL
    let movedIdentity: FileIdentity
}

enum CleanSkipReason: String, Codable, Sendable {
    case itemMissing
    case identityChanged
    case entryKindChanged
    case pathOutsideAllowedRoot
    case symbolicLinkDetected
    case volumeChanged
    case volumeUnavailable
    case volumeReadOnly
    case excludedByUser
    case cloudStateChanged
    case relatedAppStillRunning
    case rulesChanged
}

struct CleanFailure: Codable, Sendable {
    let code: CleanFailureCode
    let detailCode: String?
}

enum CleanFailureCode: String, Codable, Sendable {
    case trashMoveRejected
    case trashMoveFailed
    case metadataReadFailed
    case planIntegrityFailed
    case featureDisabled
    case coordinatorBusy
    case unexpected
}

struct CleanReportSummary: Codable, Sendable {
    let requestedItemCount: Int
    let movedItemCount: Int
    let skippedItemCount: Int
    let failedItemCount: Int
    let notProcessedItemCount: Int
    let plannedBytes: Int64
    let movedToTrashBytes: Int64
    let reclaimableAfterEmptyingTrashBytes: Int64
}
```

### 11.2 结果语义

报告必须分别显示：

- 已移入废纸篓的项目数和估算大小。
- 跳过项目及稳定原因码。
- 失败项目及可操作建议。
- 取消后未处理项目。
- 可恢复项目和恢复目标。
- 扫描是否部分完成。

移动到同一卷废纸篓通常不会立即增加可用空间，因此 UI 不得把 `movedBytes` 显示为“已释放空间”。使用以下术语：

- `movedToTrashBytes`：已移入废纸篓的估算大小。
- `reclaimableAfterEmptyingTrashBytes`：清空废纸篓后可能回收的估算大小。
- `permanentlyFreedBytes`：仅在独立清空废纸篓操作后，通过同一卷前后可用空间差值保守计算；无法可靠测量时显示不可用。

路径只保存在本机清理历史和用户主动导出的报告中，不写入遥测或普通统一日志。

## 12. UI 状态机

### 12.1 单一工作流状态

`CleanupWorkflowStore` 使用一个判别枚举表达工作流，不再让多个布尔值独立组合：

```swift
enum CleanupWorkflowState: Sendable {
    case idle(lastSessionID: ScanSessionID?)
    case preparingScan
    case scanning(sessionID: ScanSessionID, progress: ScanProgressEvent)
    case cancellingScan(sessionID: ScanSessionID)
    case results(sessionID: ScanSessionID, selection: CleanupSelection)
    case buildingPlan(sessionID: ScanSessionID)
    case awaitingConfirmation(planID: CleanPlanID)
    case executing(planID: CleanPlanID, progress: CleanupExecutionProgress)
    case cancellingExecution(planID: CleanPlanID)
    case completed(reportID: UUID)
    case failed(CleanupWorkflowFailure)
}

struct CleanupWorkflowFailure: Sendable {
    let code: CleanupWorkflowFailureCode
    let isRecoverable: Bool
}

enum CleanupWorkflowFailureCode: String, Codable, Sendable {
    case invalidRuleSet
    case permissionPreparationFailed
    case scanFailed
    case planInvalidated
    case executionUnavailable
    case executionFailed
}
```

会话、计划和报告由 Store 内部仓库按 ID 保存，枚举不复制大型数组。

### 12.2 合法转换

| 当前状态 | 事件 | 下一状态 |
|---|---|---|
| `idle/results/completed/failed` | 开始扫描 | `preparingScan` |
| `preparingScan` | 规则和权限检查通过 | `scanning` |
| `preparingScan` | 配置无效 | `failed`，执行功能关闭 |
| `scanning` | 用户取消 | `cancellingScan` |
| `scanning` | 完成或部分完成 | `results` |
| `cancellingScan` | worker 退出 | `idle` 或只读取消摘要 |
| `results` | 修改选择 | `results` |
| `results` | 请求清理 | `buildingPlan` |
| `buildingPlan` | 计划有效 | `awaitingConfirmation` |
| `buildingPlan` | 计划失效 | `results` 加提示 |
| `awaitingConfirmation` | 取消 | `results` |
| `awaitingConfirmation` | 确认且 feature mode 为 full | `executing` |
| `executing` | 用户取消 | `cancellingExecution` |
| `executing/cancellingExecution` | worker 完成 | `completed` |
| 任意运行状态 | 不可恢复完整性错误 | `failed` |

不允许：

- 扫描时生成计划。
- 执行时重新扫描。
- 使用取消会话生成计划。
- V2 会话交给 1.9.5 执行器。
- `.v2ScanOnly` 状态下显示可确认的执行按钮。
- 计划确认后返回结果页修改同一计划。

### 12.3 UI 表达

- 所有主要页面标题和描述使用固定顶部布局，状态变化不引起垂直跳动。
- 扫描未知总量时使用不确定进度。
- 分类数、已发现项目数和估算大小使用独立文字，不拼成伪百分比。
- 权限拒绝、超时、跳过和空结果使用不同状态。
- 结果页清楚区分发现大小、默认推荐大小和当前选择大小。
- 半选必须同时有图形和无障碍值，不能只靠颜色。
- 确认页展示计划快照，不直接绑定可变选择。
- 执行页展示当前分类、已处理数、成功、跳过和失败；路径默认折叠。
- 完成页使用“已移入废纸篓”，不使用“已永久释放”。

## 13. Feature flag

两个独立布尔值容易形成“执行开启但扫描关闭”的无效组合，因此使用单一模式枚举：

```swift
enum CleanupArchitectureMode: String, Codable, Sendable {
    case legacy
    case v2ScanOnly
    case v2Full
}

struct CleanupFeatureConfiguration: Sendable {
    let mode: CleanupArchitectureMode
}
```

### 13.1 模式含义

| 模式 | 扫描 | 计划和执行 |
|---|---|---|
| `.legacy` | 1.9.5 链路 | 1.9.5 链路 |
| `.v2ScanOnly` | V2 只读扫描和结果 UI | 禁止生成可执行计划，不回退到旧执行器 |
| `.v2Full` | V2 扫描 | V2 Plan 和 V2 Executor |

约束：

- 执行器必须自行检查 `.v2Full`，不能只依赖按钮隐藏。
- 同一会话不能混用 V1 扫描和 V2 执行器。
- V2 配置加载失败时 fail closed，不静默回退到旧清理。
- 正式构建只接受随 App 签名打包的默认模式。
- `UserDefaults`、启动参数或环境变量覆盖只在 `DEBUG` 和测试构建开放。
- 阶段 3—6 的开发候选使用 `.v2ScanOnly`。
- 阶段 7 内部候选在测试通过后才允许 `.v2Full`。
- 1.9.6 正式发布是否默认 `.v2Full` 由阶段 9 安全门禁决定。

1.9.6 不增加远程配置服务。已经安装的正式版本不能被远程瞬间切换；如需生产回滚，发布更高版本并把签名默认模式改为 `.legacy`。

## 14. 1.9.5 到 1.9.6 迁移

迁移由一个幂等迁移器在首次进入清理功能时运行：

```swift
struct CleanupMigration {
    func migrateIfNeeded(
        defaults: UserDefaults,
        activeRules: CleanupRuleSet
    ) -> CleanupMigrationResult
}

struct CleanupMigrationResult: Sendable {
    let fromVersion: Int
    let toVersion: Int
    let migratedExclusionCount: Int
    let rejectedExclusionCount: Int
    let didComplete: Bool
}
```

### 14.1 数据处理

| 1.9.5 数据 | 1.9.6 处理 |
|---|---|
| `scan.excludedPaths.v1` | 读取、标准化并重新验证；合法路径复制到 V2 键，旧键保留 |
| `scan.history` | 保持只读兼容，显示为“旧版扫描记录”；不原地重写 |
| `cleanup.history` | 保持只读兼容，显示为“旧版清理记录”；不伪装成 `CleanReport` |
| 文件夹授权 bookmarks | 沿用现有服务；V2 操作按范围 start/stop access |
| 当前 `ScanResult` | 不迁移；升级后必须重新扫描 |
| 待确认候选 | 不迁移 |
| 清理选择 | 1.9.5 没有稳定规则偏好；使用 V2 安全默认 |
| 恢复记录 | 保留旧服务和恢复能力，不因启用 V2 删除 |

### 14.2 新键

建议键名：

```text
cleanup.migration.version
cleanup.v2.excludedPaths.v1
cleanup.v2.ruleSelectionPreferences.v1
cleanup.v2.reports.v1
```

正式 feature mode 不从可写 `UserDefaults` 读取。测试覆盖使用注入的 `CleanupFeatureConfiguration`。

### 14.3 迁移失败

- 不删除或覆盖任何 1.9.5 键。
- 不生成 Clean Plan。
- V2 清理保持关闭。
- UI 显示可恢复错误并允许用户继续查看旧历史。
- 再次进入时可以安全重试。
- 不把部分迁移结果标记为完成。

## 15. 测试边界

### 15.1 自动化测试允许范围

- 纯模型：规则解析、校验、风险、推荐、三态选择、状态机、计划生成、报告汇总。
- 文件系统集成：只能使用每个测试独占的系统临时目录。
- 执行器单元测试：使用 fake `TrashMoving`，只记录传入 URL。
- 默认自动化测试不调用真实 `FileManager.trashItem`。该 API 只在明确 opt-in 的隔离测试账户或一次性 APFS 磁盘映像中验证，并单独报告。
- 性能测试：在临时夹具生成 10 万文件和受控目录变化。
- 权限测试：通过读取适配器注入拒绝、超时、消失和卷变化结果。
- UI 测试：使用测试规则集和 fake 执行器，不能触碰真实 Home。

### 15.2 自动化测试禁止范围

- 真实 `~/Library`、`~/Downloads`、`~/.Trash`。
- `/Library`、`/Applications`、系统目录。
- 用户真实外接硬盘。
- iCloud Drive、OneDrive、Dropbox 或其他 File Provider 根目录。
- 浏览器 Profile、Photos Library、Mail 或聊天数据库。
- 真实永久删除。
- 特权辅助程序。
- 网络下载规则或远程 feature flag。

### 15.3 必测契约

#### 规则

- schema 和版本校验。
- 重复 ID。
- `..` 和禁止根路径。
- 安全风险与动作组合。
- 风险升级导致旧选择偏好失效。

#### 扫描

- 扫描期间没有写入调用。
- 权限拒绝、超时、消失、符号链接和云占位分别报告。
- 取消后 worker 全部退出，没有迟到结果覆盖。
- 硬链接按身份去重。
- 10 万文件内存和响应时间基线。

#### 选择和计划

- 三级全选、半选和未选。
- 不可选项目不影响父级全选判断。
- 会话变化清空选择。
- 非当前会话、非安全项目和非选择项目不能进入计划。
- 计划生成后修改选择不改变计划。
- 同一计划不能执行两次。

#### 执行器

- 非计划路径永远不传给 `TrashMoving`。
- 同路径身份替换、符号链接替换、卷替换和规则版本变化均跳过。
- 一个项目失败不改变其他项目边界。
- 取消后当前项目完成、其余项目标记未处理。
- Trash 失败不调用永久删除。
- 报告逐项计数与计划一致。

#### 迁移和 feature flag

- 迁移幂等。
- 旧键保留。
- 非法排除路径不迁移。
- `.v2ScanOnly` 无法调用执行器。
- 正式构建忽略 `UserDefaults` override。
- 配置损坏时 fail closed。

## 16. 分阶段验证与回滚

| 阶段 | 实施内容 | 最小测试门禁 | 回滚 |
|---|---|---|---|
| 2 | 本设计文档和接口草案 | 文档完整性、状态和数据流审查 | 删除或回退文档，不影响运行代码 |
| 3 | 规则加载、校验、只读扫描 | 规则测试、无写入测试、权限/取消/云占位测试 | 回退阶段 3 提交；默认 mode 保持 `.legacy` |
| 4 | 扫描和结果 UI | 状态转换、取消、无障碍、固定布局和真实界面验收 | 回退 UI 提交；阶段 3 保持不可达或 scan-only |
| 5 | 风险、推荐和三态选择 | 组合选择、偏好版本和风险升级测试 | 回退选择提交；删除 V2 偏好键不影响旧数据 |
| 6 | Clean Plan | 不可变性、会话绑定和非计划路径拒绝测试 | 回退计划提交；执行器仍未启用 |
| 7 | 执行器和报告 | 临时夹具安全测试、故障注入、取消、恢复和报告测试 | mode 改回 `.v2ScanOnly` 或回退阶段 7；不发布 |
| 8 | 性能、权限和文件系统专项 | 10 万文件、持续变化、竞态、外部卷和长期运行 | 单独回退引发回归的修复提交 |
| 9 | 最终审计和发布检查 | 全量测试、Release 构建、签名、Sparkle、安装和真实 UI 分开验收 | 发布前停止；发布后只用 1.9.7+ 修复，不覆盖资产 |

## 17. 发布与生产回滚

### 17.1 发布前

- 1.9.5 的标签、Release、appcast 条目和资产保持不变。
- V2 执行门禁未通过时，正式默认模式不能设为 `.v2Full`。
- 任何 P1 数据安全问题都阻断发布。
- feature mode、规则版本和迁移版本写入发布验证报告。

### 17.2 发布后

如果 1.9.6 已经正式发布：

- 不覆盖 `v1.9.6` 标签、Release、资产或 appcast 条目。
- 一般故障发布 1.9.7，并把签名默认 mode 切换为 `.legacy` 或修复后的 `.v2Full`。
- 若 V2 规则无法加载，当前安装应 fail closed，只允许重新扫描或查看历史，不自动使用旧执行器。
- 旧恢复记录继续可用。
- 不自动永久删除已经移入废纸篓的内容。

## 18. 阶段 2 完成条件

- [x] 配置规则来源、schema、校验和禁止组合已定义。
- [x] 扫描器接口没有写入能力。
- [x] 扫描会话、候选和文件身份已定义。
- [x] 风险和推荐相互独立。
- [x] 三态选择只保存叶子候选 ID。
- [x] Clean Plan 不可变、会话绑定且不持久化。
- [x] 执行器只接受计划，并在 UI 与边界双重检查 feature mode。
- [x] 清理报告不把移入废纸篓冒充实际释放。
- [x] UI 使用单一判别状态机。
- [x] 1.9.5 数据采用保留式、幂等迁移。
- [x] 自动化测试不触碰用户真实文件。
- [x] 每个实施阶段都有独立测试门禁和回滚路径。

阶段 2 设计已批准；实现与验证结果以 `release/1.9.6-rc-validation.md` 为准。
