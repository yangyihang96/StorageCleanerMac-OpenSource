# D187：我的活动——健康度、时间估算与建议

工作目录：`/Users/developer/Developer/sc-worktrees/p02-activity`。保留交接前全部差异；未提交、安装、启动应用或操作其他会话的界面。未调用其他模型或 JEV：本会话没有可调用的 JEV 工具和额外模型预算。

副本 Git 为 detached HEAD `6e660a59f7b6dc406201b156e6c8ab1d3a6a6f4b`，工作目录原本已有大量集成差异；本次补丁以 `before/` 中的交接文件为比较基准，不以该旧提交覆盖原有差异。

**PASS**：D187 实现已通过最终测试构建、51 项过滤测试、显示测试清单检查和本次差异空白检查。新增 44 个测试；新增／改动文件编译警告 0。产出待主会话复核集成。

## 文件清单

| 文件（相对项目根） | 作用 |
| --- | --- |
| `Sources/StorageCleanerMac/Features/Activity/MyActivityHealth.swift` | 快照分档纯函数、原因、最新快照选择 |
| `Sources/StorageCleanerMac/Features/Activity/MyActivityTimeSavings.swift` | 手动用时估计常量、成功记录适配、去重合计、中英文时长 |
| `Sources/StorageCleanerMac/Features/Activity/MyActivityRecommendations.swift` | 八类推荐的值输入、条件、优先级、数量上限 |
| `Sources/StorageCleanerMac/Features/Activity/MyActivityMacInfo.swift` | 复用现有 sysctl 字符串工具和启动卷容量读取；不启动进程 |
| `Sources/StorageCleanerMac/Features/Activity/MyActivitySummary.swift` | 保留四张统计卡的原始汇总，另收集计时依据和仍可核对的废纸篓项目 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioActivityCards.swift` | 健康、时间、建议卡片及完整建议列表 |
| `Sources/StorageCleanerMac/Views/CareStudio/CareStudioMyActivity.swift` | 观察应用已有状态、展示新卡片、保留原统计与最近操作、注入跳转 |
| `Sources/StorageCleanerMac/Views/ContentView.swift` | 仅活动页调用处一行：传入应用已有健康和隐私 store |
| `Tests/StorageCleanerMacTests/MyActivityD187Fixtures.swift` | 纯数据夹具及只读页面的标准 store 工厂适配 |
| `Tests/StorageCleanerMacTests/MyActivityHealthTests.swift` | 分档及快照边界 |
| `Tests/StorageCleanerMacTests/MyActivityTimeSavingsTests.swift` | 分类、成功证据、合计、去重、溢出和格式 |
| `Tests/StorageCleanerMacTests/MyActivityRecommendationsTests.swift` | 每类触发与不触发、排序、去重、上限 |
| `Tests/StorageCleanerMacTests/MyActivityPageTests.swift` | 双语标题数字、空状态、跳转注入、真实导航和已有状态接入 |
| `Tests/StorageCleanerMacTests/CareStudioRenderReviewTests.swift` | 新增离屏页面渲染；原断言全部保留 |

## 健康度规则

只比较 `ComputerHealthStore.snapshot` 与 `ScanStore.smartScanHealthSnapshot`，使用时间较新者；不调用 `refresh` 或健康探针。没有快照显示“还没检查过 / Not Checked Yet”，按钮只跳 `.healthHub`。

| 证据 | 分档／原因 |
| --- | --- |
| SMART failing，或可读磁盘状态 actionRequired | 有问题；磁盘故障／要求处理 |
| 可读磁盘状态 attention | 需要注意；磁盘检查提醒 |
| 容量中严格可用空间低于 5% | 有问题；容量不足，不采用含可清除空间的 important-usage 数值 |
| 可用空间 5% 至不足 10% | 需要注意；可用空间偏低 |
| 容量趋势状态 attention/actionRequired，但空间未越线 | 需要注意；容量趋势提醒，不谎称低于 10% |
| Time Machine 未配置、目标不可达或已有状态提示注意／处理 | 需要注意；备份提醒 |
| 检查窗口内崩溃＋卡住至少 5 次，或稳定性 attention | 需要注意；稳定性提醒 |
| 崩溃＋卡住至少 10 次、内核崩溃、意外重启，或稳定性 actionRequired | 有问题；严重稳定性证据 |
| 电池 serviceRecommended/actionRequired | 有问题；建议维修 |
| 电池 attention | 需要注意；电池提醒 |
| SIP 或 Gatekeeper 关闭 | 有问题；明确列出关闭的项目 |
| FileVault 或防火墙关闭 | 需要注意；明确列出关闭的项目 |
| 检查数据缺失、不可读或部分可读；防护项不完整／不能确认开启 | 需要注意；数据不足。台式机明确 notPresent 的电池不算缺失 |
| 快照超过 7 天、时间无效或位于未来 | 需要注意；重新检查时间 |
| 可用且完整的数据均未触发上述条件 | 良好；帮助文字说明来自最近一次检查 |

多条并存取最严重档，不通过累加凭空制造故障。ⓘ 打开全部原因；卡片注明检查时间。机型显示系统 `hw.model` 标识，启动磁盘名取卷元数据，已用／总量和进度条取 `StorageCapacityService` 的当前只读结果，关闭 important-usage 读取。

## 时间估算

以下均为我们自己的手动操作用时估计，不是实测耗时。计数和分钟数走 `ByteFormat.count`；容量走 `storageString`；时长如“16 分钟”“1 小时 5 分钟”／“16 minutes”“1 hour 5 minutes”。

| 分类 | 每单位分钟 | 已记录的计数依据 |
| --- | ---: | --- |
| 卸载应用及残留 | 10 | 回执完成或部分完成、无待核实问题，且应用包本身确实已验证移动；不计仅重置或残留，不按残留文件数放大 |
| 更新应用 | 6 | 当前保留的自动更新队列和官网更新队列中 completed 的任务；隔离／待核实安装不计 |
| 垃圾清理 | 5 | 完成或部分完成的清理回执至少移动／删除一项；排除临时资源、文件分析、迁移、重复文件及工具类操作 |
| 维护任务 | 3 | 维护 store 当前保留的 succeeded 结果，每项任务一单位 |
| 隐私清理 | 4 | 当前保留的隐私处理结果确有已核实删除的记录，整个批次一单位 |

按类别＋操作 ID 去重，负数不计，整数溢出饱和保护。无成功依据为 0。没有新增持久化计时系统；卡片明确说明更新、维护和隐私仅含当前保留的结果。回执最多读取既有上限 3,000 份，仍保留原截断提示及四张真实统计的 D93 语义。

## 推荐规则

| 条件 | 优先级（越小越先） | 现有目标 |
| --- | ---: | --- |
| 健康度有问题 | 0 | `.healthHub` |
| 已核对仍在废纸篓、身份匹配且未恢复的回执项目大小大于 0 | 10 | `.green`，由垃圾清理页继续原来的废纸篓审阅与确认 |
| 现有 `AppUpdateCatalogSnapshot` 中可更新条目大于 0 | 20 | `.updater` |
| 没有明确智能扫描历史，或超过 7 天／日期异常 | 30 | `.overview` |
| 现有登录项展示模型计数 ≥ 5 | 35 | `.startup`（性能优化，非跑分页 `.performance`） |
| `maintenance.summary.recommendedCount` > 0 | 40 | `.startup` |
| 健康度需要注意或无快照 | 45 | `.healthHub` |
| 无现存安全防护扫描结果 | 60 | `.privacy` |
| 第三方本机云盘文件夹存在，或 iCloud 本机文件 ≥ 十进制 1 GB；已有云盘文件夹但尚无统计时引导首次统计 | 70 | `.cloudCleanup` |

废纸篓身份读取每次最多 1,000 项，不递归扫描目录；大小明确写“至少”，仅为已核对项目的下限。读取失败／已消失／被替换／已恢复的项目不计入。每种规则最多一条，共最多 8 条；性能两个不同建议共享目标而不互相吞掉，多个云盘也只产生一条云盘建议。默认显示前三条普通建议及条件成立的两类引导卡，“查看全部”打开完整列表。任何按钮只调用注入回调或 `store.navigationState.select`。

## 页面、探针及测试调整

- 顺序：页头 → 健康度和时间 → 原四张统计 → 推荐／引导 → 原最近操作。无可读记录时提供说明；未读取／无快照不伪造良好结论。
- 调试探针：`careStudio.activity.health`、`.health.status`、`.health.capacity`、`.time`、`.time.value`、`.recommendations.header`、`.recommendation.<kind>`、`.recommendation.<kind>.open`；原 hub 的页面探针保留。
- 注入入口：页面的 `healthStore`、`privacy`、`cloud`、`summary`、`mac`、`now`、`onNavigate`；注入展示数据时不启动记录和硬件读取。
- D187＋旧值：原截断提示直接插入 `3000`，现在按 D178 输出 `3,000`。没有修改旧测试的期望、阈值或断言。
- D187＋旧测试夹具：离屏渲染旧 setup 默认在真实 home 下创建隔离操作目录；现在仍通过 `ScanStore.makeForTests`，传入登记所有权但不创建的唯一操作根。渲染不执行清理、恢复、更新或维护，工厂的路径校验和拒绝执行器均保留；实际数据和偏好仍用已有临时目录夹具。云盘渲染夹具沿用 D185 的工作树 scratch 目录方案，避免临时目录路径被既有祖先符号链接检查拒绝，不改扫描器。
- 新导航测试初版错误地期待 `.startup` / `.updater` 直接存入 `selectedFilter`；D187＋旧期望“selectedFilter 等于工具”：改为严格同时断言 `.utilityHub` 和对应的 `selectedUtilityFilter`，符合已有导航契约，产品导航未变。

| 测试类 | 数量 |
| --- | ---: |
| MyActivityHealthTests | 14 |
| MyActivityTimeSavingsTests | 12 |
| MyActivityRecommendationsTests | 11 |
| MyActivityPageTests | 6 |
| CareStudioRenderReviewTests | 8（原 7 ＋ D187 新增 1；中文暗色、中文日间、英文暗色，共 6 张活动页离屏图） |
| 合计 | 51；新增 44，旧测试全部保留 |

## 实际验证记录

证据目录为本工作目录 `.build/d187-evidence/`，修改前文件在 `before/`；`files.json` 记录本次 15 个交付文件的路径和散列；`d187-working.patch` 仅含相对交接时文件的 D187 差异，供集成复核，不包含原本已有改动。

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"

# A：用户指定的构建命令；B：离线缓存就绪后追加的参数。
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox
# B = --disable-automatic-resolution --cache-path .build/codex/cache
# 最终实际运行的 A＋B：
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-automatic-resolution --cache-path .build/codex/cache

export STORAGE_CLEANER_CARESTUDIO_EVIDENCE="$PWD/.build/d187-evidence/renders"
nice -n 15 swift test --scratch-path .build/codex --skip-build --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing --disable-automatic-resolution --cache-path .build/codex/cache \
  --filter '^StorageCleanerMacTests\.(MyActivityHealthTests|MyActivityTimeSavingsTests|MyActivityRecommendationsTests|MyActivityPageTests|CareStudioRenderReviewTests)'
python3 -B script/display_bound_tests.py --check
git diff --check -- <本次交付文件>
```

| 执行／日志 | exit code | 结果 |
| --- | ---: | --- |
| A → `build-1.log` | 1 | FAIL（已解决）：首次复制的旧缓存是 Sparkle 2.9.4，而锁文件要求 2.10.0；SwiftPM 更新被网络限制阻断 |
| A＋B＋`--skip-update` → `build-2.log` | 1 | FAIL（已解决）：旧 artifact 触发下载，网络不可用。随后核对并完整复制本机 `.sc-build/v2.0.1/debug` 的 2.10.0 依赖；只在本任务副本修正 SwiftPM 的只读复制文件权限，未复制构建产物、未改依赖版本 |
| A＋B → `build-3.log` | 1 | FAIL（已修复）：活动页误用更新模型私有属性；已改用公开 `AppUpdateCatalogSnapshot` |
| A＋B → `build-4.log` 至 `build-9.log` | 均 0 | PASS：完整测试构建及后续有改动时的增量构建通过 |
| A＋B → `build-10.log` | 0 | PASS：最终源码及测试构建通过 |
| 过滤测试 → `test-1.log` | 1 | FAIL（已修复）：51 个测试；新增导航测试两处期望不符合既有 utilityHub 契约，已修正并同时核对子页面 |
| 同命令 → `test-2.log`、`test-3.log` | 均 1 | FAIL（已修复）：各 51 个测试；仅新增云盘渲染夹具的一处 provider 计数失败。规范化 temp URL 仍被祖先检查拒绝，改用 D185 既有工作树 scratch 夹具方式；保留原断言和安全检查 |
| 同命令 → `test-4.log` | 0 | PASS：51 项全部通过，0 failures / 0 unexpected，14.717 秒；主包匹配准确。另一测试包只报告 0 项，并未误跑 |
| `display-bound-final.log` | 0 | PASS：63 in-process、1 out-of-process、1 exempt；本次新增测试均不显示窗口，清单未修改 |
| `git-diff-check.log`、`whitespace-check.txt` | 0 | PASS：本次文件无空白错误 |

`changed-file-warnings.json`：本次新增／改动文件编译警告 0。构建仍有其他未改动文件的既有警告；测试日志有 CFPreferences 的沙箱 extension 诊断，按实际断言结果报告。`Package.resolved` 保持 clean，Sparkle checkout revision 和 artifact 均核对为锁定的 2.10.0。

离屏图共 6 张：中文暗色／中文日间／英文暗色各有无快照与已有问题快照两种。已检查新卡片、容量进度条、双语数字和两张条件引导卡，未见截断或重叠。进度条复用 `LightfieldDataBar`，避免原生 `ProgressView` 在 `ImageRenderer` 中产生不支持的占位图。

**BLOCKED（环境）**：所有构建／测试命令均按要求带 `nice -n 15` 和 `--jobs 4`；沙箱对 `setpriority` 返回 `Operation not permitted`，无法确认 nice 15 生效，未提权。没有绕过显示门禁或启动真实窗口。

**NOT RUN**：安装、已安装应用运行、实机窗口点击、真实清理维护，以及主集成树的完整 `verify.sh`；本轮运行的是任务指定的构建、过滤测试和显示清单检查。活动页中英离屏图位于 `renders/d187-activity-*.png`。

## 已知限制

- 现有健康历史只保存评分和部分指标，无法重建完整 `ComputerHealthSnapshot`；重启后未重新取得快照时按无快照展示。没有新增探针或持久化协议。
- 更新、维护和隐私没有统一的完整终身成功日志，因此只计当前保留的成功结果，未杜撰累计值；安全防护首次引导依据当前隐私模块持有的扫描结果。后续 D186 合入后的新防护 store 接入应由集成方协调。
- 云盘建议使用本机文件夹及现有扫描结果；不连接账户，不新增联网，不触发云盘扫描。
- 不运行安装、已安装应用、真实清理／维护或桌面手工检查；发布、安装和主树完整门禁由集成方另行执行。
