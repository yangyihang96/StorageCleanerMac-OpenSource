# D207 按类别的忽略列表：P05 实现交接

状态：本批代码已落地；最终构建、新增 27 项、522 项定向回归和最后 85 项复测 PASS。完整回归验收 BLOCKED：77 个既有用例需主会话复测；设置窗口 NOT RUN。未安装、未提交。

源码：`/Users/developer/Developer/sc-worktrees/p05-ignore`。本副本开工时已有集成改动；未 commit、未 push、未安装。开工状态在 `.build/d207-evidence/initial-status.txt`，逐文件改前副本在 `.build/d207-evidence/before/`。只叠加本交接列出的差异，未修改 `Views/CareStudio/`、`DECISIONS.md` 或提醒忽略列表。HEAD 为 `6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b`，处于 detached HEAD；这是 Git 基底标识，不代表开工集成内容已提交。当前工具未发现 JEV，亦未获得额外来源/预算，未调用其他模型或委派。

## 数据格式与迁移

- 维护源：`AppDataDirectories.applicationSupportRoot/IgnoreList.json`，随 Beta/正式版的数据目录隔离。JSON 字段为 `version: 1`、`migratedLegacyPaths`、`importedAt`、`entries`；每条有 `id`、`category`、`target { path, bundleIdentifier?, latestVersion? }`、`displayName`、`addedAt`。日期按 Foundation Codable 的参考时间秒数编码。
- 文件以原子写入保存，目录/文件权限 0700/0600；递归锁串行保护首次加载、快照、写入、移除和撤销。扫描传递值类型 `IgnoreListSnapshot`，扫描中修改不改变本轮结果。
- 路径用 `PathSafety.normalizedPath` 展开、标准化并解析符号链接；匹配复用 `PathSafety.isContained` 的整组件前缀边界。`/a/bc` 不匹配 `/a/b`。对整目录的清理候选还检查是否包含被忽略的子路径，避免整目录操作触及保留项。
- 首次加载只读导入 `scan.excludedPaths.v1` 和旧 `cleanup.v2.excludedPaths.v1` 到 `other`，两份旧值均保留。迁移标记写进新文档，显式移除后不会从旧值反复导入。`ScanExclusionService` 和 `CleanupMigration.v2ExcludedURLs` 的正式运行入口改读同一个 `other` 清单；测试可注入 store/defaults，避免真实用户目录。
- `appUpdateIgnoredLatestVersions` 保持原存储和原版本语义。设置列表将它投影成带“只忽略 x.y.z”的虚拟条目，未建立第二份版本存储。旧数据没有原始加入时间，因此显示首次导入时间；显示名从应用路径推导。设置显式移除某个版本条目时才移除对应旧键。
- 新增应用忽略按 `AppUpdateIgnoreService.identifier(bundleIdentifier:path:)` 的同一规则匹配；`updates` 新条目没有版本字段，因此覆盖此应用以后所有更新。接口也接受卸载类别的残留路径；应用忽略本身不匹配残留。
- 损坏、未知版本或不合法文档按空列表处理，原文件先复制为 `IgnoreList.json.unreadable-<UUID>`；无法保留副本时拒绝覆盖。一次性提示经 `takeNotice()` 由设置模型展示。写入失败不把未保存变更留在内存列表。

## 扫描接线与数量

目录被跳过时记为一个遇到的忽略范围，不递归读取它的后代来凑数；重叠路径去重。

| 入口 | 快照与过滤 | “已忽略 N 项”的出口 |
| --- | --- | --- |
| 垃圾规则 / `ReadOnlyCleanupScanner` | `ScanStore` 创建扫描请求时固定快照，live 操作不重新读取；D203 的系统、开发者、待确认组共用 `systemJunk`，AI 和邮件分别使用自己的类别，废纸篓使用 `other` | `ScanMetrics.ignoredItemCount/ignoredSummary`，清理扫描详情；`ignoredPathsByRule` 使局部补扫替换正确规则的计数 |
| `ProjectArtifactScanner` | 用户选定根内，使用 `systemJunk + other`；路径和包含忽略子路径的聚合产物不列出 | 返回 session 的同一 metrics；项目产物状态行 |
| `MalwareScanner` | 开始时只调用一次快照 provider；collector 在读取路径元数据、签名、Info/launch plist 或文件内容之前跳过 | `outcome.counts.ignored`，恶意软件覆盖详情 |
| 卸载管理模型 | 对完整安装清单取一次快照，过滤 `uninstaller + other` 后生成卸载及长期未用条目；完整清单继续作为残留所有权证据，即使所有应用被忽略也会查残留 | `ignoredApplicationCount`、`ignoredLeftoverCount`、`ignoredDownloadCount`、`ignoredPluginCount` 与 `ignoredSummary`，应用结果/管理器状态 |
| `LeftoverScanner` | 仅用路径条目过滤残留，应用 ID 条目不隐藏残留 | `scanReport().ignoredCount` |
| `UnusedInstallerScanner` / `AudioPluginScanner` | 安装文件用 `downloads + other`，插件路径用 `uninstaller + other`；默认链接保护不变，测试可注入读取策略 | 各自 `scanReport().ignoredCount`；管理模型合入对应计数 |
| 应用更新 | `ScanStore` 在只读检查开始时固定永久忽略及旧版本快照；增量结果与最终结果都标 `.ignored` | `AppScanSummary.ignoredCount/ignoredSummary`、`ScanStore.ignoredAppUpdateCount`、更新页状态；忽略行仍显示“已忽略”，计数/计划/批次共同排除 |
| 重复与相似文件 | 同一配置快照：`other` 在遍历时排除；重复类别在确认/元数据分组前排除，相似类别在图像分组前排除，互不串用 | coverage 的 `ignoredCount(for:)`、`ignoredSummary(for:)`（不把原有系统保护范围算成用户忽略），重复/相似扫描详情 |
| `DiskScanner` 大型和旧文件 / 下载 | 大文件过滤 `largeAndOld + other`，下载组过滤 `downloads + other`；旧扫描 live 操作也传固定快照 | `LargeFileListingSummary.ignoredItemCount/note`；`ScanResult.ignoredCounts` 供管理器使用 |
| 空间地图 | 浏览和分析显式使用空排除数组，不使用类别忽略过滤地图；文件操作的保护清单仍从原安全服务读取 | 空间地图保留全部可读节点，此处没有忽略计数 |

`CleanupRuleTable` 是规则清单文档测试，不是另一套扫描器；其规则不变、按同一 D203 分类在扫描时过滤。

## 给 CMM 的接口

```swift
let store = IgnoreListStore.shared
store.add(path, category: .systemJunk)
store.add(.application(bundleIdentifier: app.bundleIdentifier, path: app.path),
          category: .updates, displayName: app.name)
store.add(paths.map { IgnoreListTarget(path: $0) }, category: .uninstaller)
store.remove(entry)                 // 或 remove(ids: Set<String>)
store.undoLastAdd()                 // 多选的一次 add 整批撤销，不撤销早先保留项
let frozen = store.snapshot()
let applications = frozen.applying(to: rawUpdates)
```

`add` 单项返回 Bool，批量返回新增数；失败/重复不会污染上一次可撤销加入；CMM 仅在新增成功时提供撤销按钮。撤销历史只保留当前进程最后一次成功加入，重启不恢复撤销历史。`remove` 和 `undoLastAdd` 返回 Bool。所有接口可在主线程外调用。保存成功后在主队列发 `IgnoreListStore.didChange` 通知；旧版本忽略服务的变更也发同名通知（object 可为 nil），因此订阅通知名称即可，刷新时重取快照。设置模型示例在 `SettingsIgnoreListModel`。CMM 可在通知后刷新经理列表/计数，但不要替换正在扫描的配置；本实现不发起自动重扫、不执行清理。

设置窗口新增“忽略列表”第八页：11 类按模块分组，路径类走 `AppOpenPanelCoordinator`，应用类从 `ScanStore.installedApps` 选择；没有安装清单时只读刷新它。旧“扫描排除”只保留通往 `忽略列表 → 其他` 的入口。旧的排除方法仍是兼容调用口，不再呈现第二份可编辑清单。

## 验证记录

证据目录：`.build/d207-evidence/`。依赖仅复制本机 `~/Developer/.sc-build/v2.0.1/bootstrap/{checkouts,repositories,artifacts,workspace-state.json}` 的 Sparkle 2.10.0，修改工作区状态中的绝对缓存路径，无联网、安装或助手连接。

新增测试共 **27 项**，全部通过：

| 类 | 数量 | 覆盖 |
| --- | ---: | --- |
| `D207IgnoreListStoreTests` | 11 | JSON 版本/读写/元数据，坏文件保留/一次提示，未知版本，双旧路径迁移与不再导回，扫描排除桥接，旧版本忽略保留，永久应用身份，路径组件边界，符号链接，32 路并发及不可变快照，批量撤销/重复加入 |
| `D207IgnoreScannerTests` | 12 | D203 六组分类与过滤，局部补扫忽略计数，重复与相似隔离，旧路径计数与系统保护计数区分，相似图像过滤，大文件/聚合保护与空间地图保留，恶意软件未读取忽略文件，项目产物，应用忽略不隐藏残留，卸载候选，下载快照与撤销 |
| `SettingsIgnoreListD207Tests` | 3 | 添加/删除/撤销，后台写入的主队列通知刷新，11 类/应用选择模型 |
| `AppUpdateIgnoreD207Tests` | 1 | 更新三个展示计数一致，持久摘要一致，批次排除，更新页保留已忽略行 |

已有两处期望按“D207＋旧值”更新：设置源码清单新增第八页；项目产物由“排除但仍列不可选行”改为“不列出、计数 1”。未删除测试、未放宽阈值、未增加 skip。链接读取注入只用于临时夹具内的验证，产品默认 `PathSafety` 检查保持原样。

构建实际命令（各轮同一命令）：

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox
```

最终 **`build-10.log` exit 0**。中间构建日志及 exit：`build-1` 为 1（Swift 6 捕获可变配置），`build-5` 为 1（计数辅助函数使用了错误的规则变量名），`build-7` 为 1（新增配置参数漏接结果恢复入口）；均已修复。`build-2/3/4/6/8/9` 和中间命名的 `build-final` 均为 0。`*.exit` 保留准确返回值。

测试实际使用的共同命令前缀：

```bash
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox --disable-swift-testing --filter "$test_filter"
```

所有类过滤表达式均以 `/` 结尾，无 `$`。各轮完整过滤器、日志和结果：

| 日志 | 过滤器 / 清单 | 结果 | exit |
| --- | --- | --- | ---: |
| `tests-1.log` | `test_filter=$(<.build/d207-evidence/test-filter.txt)`；50 个非窗口类，完整类名在 `test-classes.txt`；D106 的 3 个窗口类单独列在 `test-excluded-display.txt` | Executed **801 tests**, 8 既有 skip，85 次失败断言，涉及 82 个用例 | 1 |
| `tests-2.log` | `^StorageCleanerMacTests\.(D207Ignore[A-Za-z]*Tests\|AppUpdateIgnoreD207Tests\|SettingsIgnoreListD207Tests\|SettingsSourceContractTests\|ProjectArtifactTests)/` | 77 项，3 次夹具路径安全断言失败；随后注入夹具内部链接检查策略修复，未放宽产品检查 | 1 |
| `tests-3.log` | 上一行再加入 `ScanSessionRescanMergeTests` | **86 项，0 失败** | 0 |
| `tests-final.log` | `test_filter=$(<.build/d207-evidence/final-test-filter.txt)`；40 类见 `final-test-classes.txt` | Executed **522 tests**, 6 既有 skip，**0 失败**；含全部 27 个新增测试 | 0 |
| `tests-settings-final.log` | `^StorageCleanerMacTests\.(D207Ignore[A-Za-z]*Tests\|AppUpdateIgnoreD207Tests\|SettingsIgnoreListD207Tests\|SettingsAccessTests\|SettingsLightfieldContractTests\|SettingsSourceContractTests\|UIConsistencyRegressionTests)/` | 最后一处设置页切类清空选择后重建，**85 项，0 失败**；含全部新增测试与 46 项 UI 一致性回归 | 0 |

522 项回归是在完整定向首轮之后排除已确认无法在本沙箱复测的 12 类进行；**不代表完整首轮已通过**。首轮中的 D207 及两处旧期望失败已修复。仍有 **77 个既有用例** 需要主会话复测：75 个涉及家目录操作/回执夹具被沙箱拒绝，另有 Apple 实际签名和 APFS 克隆证据各 1 项。后两项需在主环境确认，不能仅凭本次失败认定产品无缺陷。准确清单在 `blocked-environment-tests.txt`，首轮全部失败列表在 `initial-failed-tests.txt`。这些原测试未改成 skip，也未移出窗口清单。

复核采用本模型和 `code-review-and-quality` 技能；按技能执行反证：临时将组件匹配改成普通字符串前缀，运行 `swift test`（同参数，去掉 `--skip-build` 并加 `--jobs 4`，过滤 `^StorageCleanerMacTests\.D207IgnoreListStoreTests/`）。`mutation.log` 显示 11 项中 `testComponentPrefixAndCategoryIsolation` 按预期失败，exit 1；随后 finally 恢复源码，哈希与执行结果见 `mutation-result.json`，恢复后的构建和上述测试均通过。

其余实际命令：

```bash
python3 -B script/display_bound_tests.py --check
python3 -B script/check_deletion_process_inventory.py
git diff --check
```

三者 exit 均为 **0**。D207 专用补丁在 `d207.patch`，校验值在 `d207.patch.sha256`；`git apply --check --reverse --whitespace=error .build/d207-evidence/d207.patch` 只读检查 exit 0，确认补丁与当前文件一致。显示清单为 63 in-process / 1 out-of-process / 1 exempt；删除流程清单为 182 entries / 274 uses。日志分别为 `display-check-final.log`、`deletion-check-final.log`、`git-diff-check.log`。窗口类未运行、未移出清单。

与 `~/Developer/.sc-build/v2.0.1/lanes/baseline-warnings.txt` 按文件与警告内容比较，改动文件 **0 新增警告**，见 `warnings-report.json`；保留了 `ProjectArtifactTests.swift` 的既有 actor 警告。SwiftPM 用户缓存不可写及既有链接警告另记在构建日志，未改用户配置。

## 主会话验证与装机后步骤

1. 集成前核对 `.build/d207-evidence/d207.patch` 与开工副本，只取 D207 差异；完整非窗口定向和真实签名/APFS/家目录操作夹具在主会话补跑。
2. D106 清单保持原样。相关窗口类至少补跑 `SettingsLightfieldGeometryTests`、`SettingsMiniWindowPreviewTests`；涉及主窗口入口的 `CareStudioWindowReviewTests`、`MenuBarPanelInteractionTests`、`SystemMonitorServiceTests`、`SafeCleanupLayoutTests` 也由主会话在指定非主显示器验证。
3. 用户已授权装机时，由主会话使用 Beta 正常流程。检查设置第八页在亮/暗主题、窄窗口下的分类滚动、文件路径截断、日期时间、加减按钮、应用多选、OpenPanel 取消和重新打开。
4. 用可恢复的专用测试文件夹加路径，下一次扫描应过滤并显示计数；扫描中改忽略项，本轮保持原快照，下轮生效。移除/撤销后再扫描恢复；退出再开仍保存。
5. 以旧扫描排除及旧“只忽略某版本”的已有测试账户确认迁移与一致性，不清空用户旧值。新增永久更新忽略后，对照应用磁贴、更新标题、智能呵护卡片同数且批次为其子集；更新页仍显示“已忽略”。
6. 忽略卸载应用后检查长期未用和卸载候选消失，独立残留仍可见；再对残留路径加入忽略才消失。大文件、重复、相似及下载分别验证类别隔离、`other` 共用及数量。空间地图仍能看到这些文件。
7. 在隔离数据目录制造坏 JSON/未知版本，确认原件保留、空列表及一次提示；勿破坏真实用户列表。CMM 最后接右键加入与“放回原处”的反馈及通知刷新。

本轮明确不做“按下载来源应用忽略”；空间地图不排除。窗口/真实环境验收、CMM 右键和反馈由主会话及 CMM 接续，不属于本沙箱已验收项。LayerFS 工具不可用，未入库；本地文件和上述开工/补丁证据是交接入口。

## 文件清单

共 41 个文件（含本交接）。

- `Sources/StorageCleanerMac/Features/AppLifecycle/Uninstaller/ApplicationsManagerModel.swift`
- `Sources/StorageCleanerMac/Features/AppLifecycle/Uninstaller/LeftoverAndInstallerScanners.swift`
- `Sources/StorageCleanerMac/Features/AppUpdates/Coordination/ApplicationUpdatePlanBuilder.swift`
- `Sources/StorageCleanerMac/Features/AppUpdates/Models/AppUpdatePresentationModels.swift`
- `Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdateLightfieldPresentation.swift`
- `Sources/StorageCleanerMac/Features/AppUpdates/Views/AppUpdatesView.swift`
- `Sources/StorageCleanerMac/Features/DuplicateFiles/Models/DuplicateFileModels.swift`
- `Sources/StorageCleanerMac/Features/DuplicateFiles/Stores/DuplicateFilesStore.swift`
- `Sources/StorageCleanerMac/Features/LargeFiles/Stores/LargeFilesStore.swift`
- `Sources/StorageCleanerMac/Features/MalwareScan/MalwareScanModels.swift`
- `Sources/StorageCleanerMac/Features/MalwareScan/MalwareScanStore.swift`
- `Sources/StorageCleanerMac/Features/MalwareScan/MalwareScanViews.swift`
- `Sources/StorageCleanerMac/Features/MalwareScan/MalwareScanner.swift`
- `Sources/StorageCleanerMac/Features/MalwareScan/MalwareTargetCollector.swift`
- `Sources/StorageCleanerMac/Models/CleanupScanModels.swift`
- `Sources/StorageCleanerMac/Models/LargeFileListing.swift`
- `Sources/StorageCleanerMac/Models/ScanSessionRescanMerge.swift`
- `Sources/StorageCleanerMac/Models/StorageModels.swift`
- `Sources/StorageCleanerMac/Services/AppUpdateIgnoreService.swift`
- `Sources/StorageCleanerMac/Services/CleanupMigration.swift`
- `Sources/StorageCleanerMac/Services/DiskScanner.swift`
- `Sources/StorageCleanerMac/Services/DuplicateFileScanner.swift`
- `Sources/StorageCleanerMac/Services/IgnoreListStore.swift`
- `Sources/StorageCleanerMac/Services/ProjectArtifactScanner.swift`
- `Sources/StorageCleanerMac/Services/ReadOnlyCleanupScanner.swift`
- `Sources/StorageCleanerMac/Services/ScanExclusionService.swift`
- `Sources/StorageCleanerMac/Services/ScanHeavyWorkService.swift`
- `Sources/StorageCleanerMac/Stores/ScanStore.swift`
- `Sources/StorageCleanerMac/Views/ApplicationsManager/ApplicationsManagerView.swift`
- `Sources/StorageCleanerMac/Views/ApplicationsManager/ApplicationsOverviewView.swift`
- `Sources/StorageCleanerMac/Views/CleanupScanViews.swift`
- `Sources/StorageCleanerMac/Views/FilesLightfield/DuplicateFilesLightfieldView.swift`
- `Sources/StorageCleanerMac/Views/ProjectArtifactView.swift`
- `Sources/StorageCleanerMac/Views/Settings/SettingsIgnoreList.swift`
- `Sources/StorageCleanerMac/Views/Settings/SettingsLightfield.swift`
- `Sources/StorageCleanerMac/Views/Settings/SettingsScan.swift`
- `Sources/StorageCleanerMac/Views/SettingsView.swift`
- `Tests/StorageCleanerMacTests/D207IgnoreListTests.swift`
- `Tests/StorageCleanerMacTests/ProjectArtifactTests.swift`
- `Tests/StorageCleanerMacTests/SettingsSourceContractTests.swift`
- `docs/2.0.0/collab/handoffs/p05-ignore-d207.md`
