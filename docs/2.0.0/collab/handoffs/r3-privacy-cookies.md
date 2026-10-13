# r3-privacy-cookies：修复轮 1（独立 Claude 复核反馈）

基线 `a010e5b3c24859e3c224b5dd606dbbb471102884`，分支 `task/r3-privacy-cookies`。worktree `/Users/developer/Developer/sc-worktrees/r3-privacy-cookies`；scratch `/Users/developer/Developer/.sc-build/r3-privacy-cookies`。本轮先检查 `git status`，保留前轮的全部修改与未跟踪文件。`.git` 只读，按 prepared 分组交付，未提交／合并／安装／启动应用。全程只连接临时假 profile；没有读取或修改真实浏览器数据。没有修改 ScanStore、AppUpdates、清理规则、卸载、照片、云文件、文件分析。

## 修复轮 1 改动与依据

- **P1-1**：下载关联表写死独立规则：`downloads_url_chains.id`、`downloads_slices.download_id`、`downloads_reroute_info.download_id`。切片复合主键 `(download_id, offset)`，同下载的多个切片都删除。未知 `downloads_` 关联表、已知表缺指定列，均拒绝并给中文原因；事务回滚保留原记录。只删表内记录，不读取文件路径，不删文件，历史 urls／visits 不写。
- **P1-2**：数据运行用恢复根内 `.data-run.lease` 排他锁串行预留额度。开始前按完整 profile×contract 批次数检查剩余的十二份数据额度，超过则整次零删除并提示减少选择／处理旧备份。保守把未恢复的未知／未完成数据备份也占额度。每批只更新摘要，不修剪、不释放 writingLease；运行结束携带全部本次 UUID 的 sparing，再统一修剪和释放。历史与数据按 dataContract 是否为空分池，各十二份，互不挤占。任何批次失败都会结束运行；之前成功批次仍有备份，错误报告包含此前已确认删除的总条数与后续停止原因，不把部分完成写成整次零写入。
- **P1-3**：较新备份警告比较 `dataContract.relativePath`，旧历史视同 `History`。历史删除与下载删除共享目标数据库，因此彼此都触发“之后还有备份”警告。
- **P1-4**：Firefox 表单选择只读，fieldname／计数仍可读；读取校验不执行写入级触发器／外键门槛。新版 `moz_history_to_sources` 外键不再让读取失败，删除拒绝。`webappsstore.sqlite` 仅遗留文件只读，界面明确不代表当前站点存储已经清理。Cookie（含 Firefox）和 Chromium autofill 均行级备份与 INSERT OR IGNORE 恢复；信用卡、地址资料、密码等其他表不进入行级备份或恢复。旧的整文件 Cookie／Web Data 备份不能再走覆盖恢复。
- **行级备份顺序**：安全私有目录先建立空备份库及固定类型元数据；以备份库为可写主库，ATTACH 只读 immutable 源库，在第一段 BEGIN IMMEDIATE 内复制所选行、核对复制条数、提交，然后封存 SHA-256 元数据。只有封存成功才进入第二段删除事务，再核对当前各键计数；保留源库原有 WAL／DELETE 日志模式，每段只写备份库或源库之一，不改源库日志配置；失败回滚第二段，第一段已封存备份保留。两段之间用 SQLite 内部双向 EXCEPT 的差异计数核对归档与待删行；即使条数相同但行已替换，也拒绝删除。应用仅接收差异 COUNT，不取回任何值。这使备份元数据故障发生在删除之前。整段复制只在 SQLite 引擎内进行，不经 sqlite3_column 返回 payload，不解密、不记录值。数据库 schema 仅用于复制该固定表及唯一索引；无唯一身份、不兼容／未知级联格式拒绝。移除了 Original.sqlite 及旁文件多余副本。下载继续使用现有规范化整库快照，未合并 WAL／SHM／journal 拒绝，完整可恢复快照由既有 SQLite 备份机制保证。
- **恢复**：检查应用退出、锁、路径、备份摘要，获取源备份租约和持久化 restorePending。行级恢复核对列／主键／唯一索引签名，只对固定表 INSERT OR IGNORE，不替换现有行。事务内核对总条数增加与旧组计数不减少；失败回滚不能确认时保留“可能已写入”标记，不声称零变化；新只读连接核对全部分组；成功才写 restoredAt。行级恢复是补回操作，没有整库撤销备份，不声称可撤销整次恢复。Cookie 登录能否恢复取决于服务器、过期和分区，无法保证。
- **P2**：保留站点用归一化后的等于或 `'.' + 域名` 后缀，避免 badexample.test 被 example.test 误保护；unkeep 同样归一化。Chromium profile／可信父目录的 SingletonLock 与 Firefox profile 的 .parentlock 用 lstat 检查（包括悬空链接），事务前再次拒绝。Firefox 数据写入 Team ID 固定 `43AQ936H96`，其他 Firefox 衍生应用即使可读也不继承 Mozilla 写权限；此值须主会话在授权测试应用上实机 codesign 核对，本轮 NOT RUN。删除、行复制和恢复事务内启用 secure_delete=ON。确认标题随选择类型变化；Cookie 醒目标明退出登录、同域所有分区一起处理、同步回填、过期限制；非 Cookie 使用所选类型标题。界面按浏览器×类型显示未开放原因。

SQLite 元数据读取仍是私有快照、分组键／字段类别／COUNT。补充了 `SQLiteSnapshotService.swift` 的显式 opt-in 只读分支：macOS SQLite 对关闭后无 WAL/SHM 的 WAL 模式库可能在只读打开后返回 CANTOPEN（临时原生 SQLite 探针复现）；新数据 source 可在该失败时复用既有 immutable 读协议。原有主文件前后 contentStamp、旁文件/热日志检查、NOFOLLOW、路径身份和超时均保留；参数默认 false，仅本批新数据读取显式开启。它不建立源旁文件、不改源日志模式。新增 WAL 模式全链路测试不更改成功断言，并把 BrowserPrivacyRecordScannerTests 加入定向以覆盖原有快照和 immutable 边界。SQL trace 仅用于显式注入的假连接测试，使用未展开参数的 sqlite3_sql，不记录参数或 payload。生产未注入 observer，不建立 SQL 日志。扫描不预选任何新类型，白名单复核在 UI 和删除边界各一次。LevelDB／IndexedDB／Service Worker／会话不写，Safari 不开放删除，绝不涉及钥匙串。

## 浏览器 × 类型能力表（本轮最终口径）

Chromium 行逐项适用于 Chrome、Chromium、Edge、Brave、Arc、Opera、Opera GX、Vivaldi，沿用各自注册签名／根目录规则。Firefox 四种（Firefox、Zen、LibreWolf、Waterfox）可读元数据，只有 Mozilla Team ID 符合的已注册 Firefox 身份可条件写 Cookie；不因共用格式给衍生应用写权限。

| 浏览器 | 类型／文件 | 读取 | 删除 | 备份 | 回读与操作记录恢复 | 状态 |
|---|---|---|---|---|---|---|
| 8 种 Chromium | Cookie，Cookies／Network/Cookies | host_key + COUNT，按域名合并，不读值 | 固定 cookies 按原 host_key 事务删除；同域分区一起处理 | ATTACH 所选行，复制表 schema／唯一索引，不含其他表 | 删除组消失、未选组不变、提交后新连接核对；INSERT OR IGNORE 补回所删行 | 条件开放 |
| 8 种 Chromium | 表单，Web Data/autofill | name + COUNT，仅字段类别 | 仅固定 autofill 按 name 删除 | 同上，仅所删 autofill 行；不含信用卡／地址资料／密码表 | 同上，保留新记录与冲突行，不覆盖其他表 | 条件开放 |
| 8 种 Chromium | 下载，History/downloads | COUNT，不读 url／路径 | 已知三张关联表各自真实键，最后 downloads；未知表拒绝 | 既有整库恢复快照（含历史），不另留 Original 副本 | 下载计数回读＋历史和文件不变；恢复整库有覆盖提示，保存当前状态供撤销 | 条件开放 |
| 8 种 Chromium | Local Storage/LevelDB | 不读内容，只显示原因 | 无 | 无 | 无安全站点映射与恢复协议 | 不支持 |
| 8 种 Chromium | IndexedDB／Service Worker | 同上 | 无 | 无 | 无 | 不支持 |
| 8 种 Chromium | Sessions／最近关闭 | 不解析会话内容 | 无 | 无 | 不能区分当前与最近关闭 | 不支持 |
| Firefox（含上述衍生） | cookies.sqlite/moz_cookies | host + COUNT，按站点合并 | 固定 moz_cookies 按 host 事务删除；限注册 Mozilla 身份 | 所删行 ATTACH 备份 | 新连接核对；INSERT OR IGNORE 补回、不覆盖新行 | Mozilla 身份条件开放；其他只读 |
| Firefox（含上述衍生） | formhistory.sqlite | fieldname + COUNT；存在 moz_history_to_sources 仍可读 | 无，外键及行级恢复协议未开放 | 无写备份 | 无写恢复 | 只读 |
| Firefox（含上述衍生） | webappsstore.sqlite/webappsstore2 | originKey + COUNT，只读反向域名 | 无 | 无 | 不代表当前站点存储已经清理 | 仅遗留文件，只读（Firefox 92 起） |
| Firefox（含上述衍生） | storage/现代站点存储／IndexedDB／Service Worker | 不读内容 | 无 | 无 | 尚无 quota／跨目录一致性恢复协议 | 不支持 |
| Firefox（含上述衍生） | 下载记录 | 不读相关字段 | 无 | 无 | 未实现独立下载关联适配器 | 不支持 |
| Firefox（含上述衍生） | sessionstore／sessionstore-backups | 不读内容 | 无 | 无 | 未证明最近关闭范围 | 不支持 |
| Safari | 受保护 Cookies.binarycookies | 仅说明，没有能避开值的安全读取器 | 永不提供删除 | 无 | 无 | 只读说明；数据读取不支持 |
| Safari／Orion | 其他新增类型 | 只显示未开放原因 | 无 | 无 | 未实现 | 不支持 |
| 未注册衍生浏览器 | 匹配的 SQLite 元数据类型 | 只读快照 | 无 | 无 | 无 | 只读 |

## 真实下载 schema 来源

夹具 CREATE TABLE 来自 Chromium 固定源码提交 [c0c15e325e381f86795e51f236354b6727fef532/download_database.cc](https://chromium.googlesource.com/chromium/src.git/+/c0c15e325e381f86795e51f236354b6727fef532/components/history/core/browser/download_database.cc)，覆盖完整 downloads 列（含 by_web_app_id）、downloads_url_chains、downloads_slices，使用真实 NOT NULL 和主键。历史 reroute 采用 [85a072b23bde4aebb0d4e65074a6398f092e0854 迁移夹具](https://chromium.googlesource.com/chromium/src/+/85a072b23bde4aebb0d4e65074a6398f092e0854%5E%21/) 的 download_id 主键及 reroute_info_serialized VARCHAR；测试数据都是人为假数据。以上是源码提交来源，不声称是本机 Chrome 版本／实机兼容性证据。当前 [Chromium main](https://chromium.googlesource.com/chromium/src/+/refs/heads/main/components/history/core/browser/download_database.cc) 表明 reroute 自 schema v46 引入、FileSystem Connector 移除后删表；本批为仍存在该表的旧格式保留规则，不把它误称为所有新版必有的表。

## 测试、断言与反证

BrowserPrivacyDataTests 全部使用 TestFileSystem.uniqueRoot 临时 SQLite profile；偏好仅 TestPreferenceDomain，不触碰真实 home。新增假连接 FakeConnection 通过 sqlite3_trace_v2 记录实际传给 SQLite 的未展开 SQL；断言所有顶层用户表 SELECT 仅分组键和 COUNT，schema SELECT／PRAGMA 仅元信息。INSERT SELECT 的 payload 复制在引擎内部，测试断言不会 SELECT 返回值列。新增行为故障注入：错误 changes() 要求回滚且三行仍在；提交后错误 fresh-read 要求 unverified、备份可恢复；成功恢复必须落盘 restoredAt；未知关联表／触发器／外键拒绝写并保留记录；默认扫描结果清空已有选择；保留源库 WAL 模式的删除与行恢复；白名单子域与归一移除；真实下载切片／reroute 删除；新行／冲突行与信用卡表保留；13 批执行前拒绝；12 批运行及并发维护保留全部备份，额度满拒绝下一次；历史十二份不被数据挤占；History 与下载的跨类型较新备份警告。

**断言未放宽**：既有历史、恢复、UI、偏好卫生断言不删、不跳过、不降低阈值。前批新增的数据测试按本轮明确决定改写：原 Original.sqlite／Original.sqlite-wal 存在断言改为不存在，新增只含所删行和无其他表的验证；行级恢复原 undoBackupID 存在改为不存在，并要求 restoredAt 和新数据／冲突行完整保留；七适配器写循环改为只遍历明确允许删除的五种，其余两种另有只读行为测试；源码字符串安全守卫替换为真实执行 SQL 与错误条数／回读行为断言；触发器原扫描拒绝改为扫描可读而写拒绝，密码／卡表条数保留。唯一既有追踪测试修改仍是 D91 白名单偏好例外：只有固定 DataStore、固定 key、恰好两处 defaults.set 允许；其他历史和 payload 持久化守卫保持。

scratch targeted-classes.txt 覆盖 BrowserPrivacyDataTests、BrowserPrivacyRecoveryTests、BrowserPrivacyRecoveryEdgesTests、BrowserPrivacyHistoryProcessorTests、PrivacyCleanupPresentationTests、TestPreferenceHygieneTests、UIConsistencyRegressionTests、BrowserPrivacyRecordScannerTests。mutations.json ≥15 条，每个 before 逐字唯一；增加 P1-1/P1-2/P1-3/P1-4/白名单子域的独立变异，filter 指向行为测试。主会话逐一在隔离副本反证，编译失败不算击中，测试不得修改。

红／绿／反证：原假 slices.id 替换为真实 download_id 后可重现 P1-1；移除总额度预检可重现第十三批部分执行；比较 dataContract 可重现跨类型警告漏失；取消 readonly gate 可重现 Firefox 外键删除风险；把行恢复改为 REPLACE 可重现新冲突行被覆盖；取消 suffix 可重现子域被删除。正常源码必须满足对应行为断言。本轮不运行反证／全量门禁。

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r3-privacy-cookies/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter 'BrowserPrivacyDataTests|BrowserPrivacyRecoveryTests|BrowserPrivacyRecoveryEdgesTests|BrowserPrivacyHistoryProcessorTests|PrivacyCleanupPresentationTests|TestPreferenceHygieneTests|UIConsistencyRegressionTests|BrowserPrivacyRecordScannerTests'
STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=~/Developer/.sc-build/r3-privacy-cookies/full-verify script/verify.sh
```

## 实机验收（NOT RUN，仅主会话在用户授权下执行）

1. 用户在独立测试 profile、自建可丢弃站点准备 Cookie、普通 autofill 与下载记录；核对测试浏览器版本、bundle／codesign，Firefox Team ID 必须为 `43AQ936H96`。不得连其他真实 profile。
2. 读取只显示域名、计数、字段类别；默认空选择。保留根域后其子域也不可选，归一化移除恢复可选。浏览器运行或 profile lock 存在时删除／恢复拒绝，不强退。
3. 正常退出后选测试站点，确认登录／分区／同步影响；Cookie／autofill／下载条数回读，下载文件和历史未被删除。现代站点存储、Firefox 表单和会话应显示未开放原因。
4. 删除后先在测试 profile 加新记录和与备份唯一键冲突的记录；退出后恢复，旧缺失行补回，新数据／冲突行／卡和地址资料不覆盖，restoredAt 可见。下载整库恢复单独确认覆盖历史影响与撤销备份。Cookie 字节恢复不等于登录令牌有效。
5. 验证同步可能回填、过期／分区可能不恢复登录；门槛未通过必须显示原因，不能为验收放宽签名、锁、外键或值读取限制。

## 修复轮 1 验证与剩余边界

最终完整定向日志 [`fix1-delivery-gates.log`](/Users/developer/Developer/.sc-build/r3-privacy-cookies/fix1-delivery-gates.log)：构建 **PASS / exit 0**（38.80 s）；定向 **FAIL / exit 1**，311 项、1 项原有 opt-in 跳过、10 处既有断言失败、0 unexpected。

| 定向类 | 项数 | 结果 |
|---|---:|---|
| BrowserPrivacyDataTests | 33 | 全通过 |
| BrowserPrivacyHistoryProcessorTests | 58 | 全通过 |
| BrowserPrivacyRecoveryEdgesTests | 33 | 全通过 |
| BrowserPrivacyRecordScannerTests | 52 | 0 失败；1 个原有实机覆盖测试 opt-in 跳过 |
| UIConsistencyRegressionTests | 46 | 全通过 |
| BrowserPrivacyRecoveryTests | 31 | 2 处既有资源标记断言失败 |
| PrivacyCleanupPresentationTests | 37 | 5 处既有系统剪贴板断言失败 |
| TestPreferenceHygieneTests | 21 | 3 处既有偏好落盘断言失败 |

`testOptInProductionBrowserCoverage` 的原有跳过要求显式 STORAGE_CLEANER_RUN_LIVE_BROWSER_SCAN=1；本批禁止真实浏览器读取，因此没有设置。没有新增跳过或放宽断言。最终下载夹具进一步将真实 schema 的 target_path/current_path 绑定到所构造的 download.pdf，删除后核对文件字节原样，避免路径无关的假绿；仅修改假数据。该最终测试源码再编译 **PASS（6.99 s）**，数据 33 项再跑 **PASS**，日志 [`fix1-final-data.log`](/Users/developer/Developer/.sc-build/r3-privacy-cookies/fix1-final-data.log)。其余源码与完整定向一致，未重复扩大测试。

十处失败涉及前轮同样的四个原有方法：

- BrowserPrivacyRecoveryTests.testRecoveryFolderIsExcludedFromTimeMachine（2 处）；系统资源标记在沙箱中未如预期回读。
- PrivacyCleanupPresentationTests.testCopiedAddressesAreMarkedConcealedAndTransient（5 处）；系统剪贴板标记在沙箱中未如预期回读。
- TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory（2 处）及 testTemporarySuiteCanBeReopenedOnAWorkerThread（1 处）；日志明确有 sandbox_extension_issue_file / Operation not permitted。

环境归因须主会话沙箱外按原测试核对，不能把完整定向集合记为通过；没有删断言、放宽阈值或新增跳过。未确认的操作记录条数显示“条数未确认”，不再显示为零。

`git diff --check`、`script/check_private_api.py` **PASS**。mutations 共 **33 条**，Python 校验每个 before 恰好一次、expected_occurrences=1、ID 唯一、filter 的方法存在、P1-1 至 P1-4、suffix 与新 WAL 边界分别覆盖；见 scratch `fix1-mutation-validation.json`。反证未运行，不声称全部击中。prepared 重生成 01-code／02-tests／03-docs 与 all.patch，**15 个最终文件**（代码 11／测试 2／文档 2），SHA-256 与组顺序写入 manifest；所有补丁反向检查与文件／产物哈希校验通过。主会话运行 commit-prepared.py --validated 前须完成未过门禁和独立复核。

额外共享文件仅 `Services/SQLiteSnapshotService.swift`（20 行增量）：新增默认关闭的显式新数据读取参数、URI 参数，以及保留 canonical URI 路径；已扩展 RecordScanner 定向验证原有快照／旁文件边界。ScanStore 与其他禁改模块保持不变。无真实浏览器版本兼容性／原生 UI／安装验收证据。完整 verify、Release、反证、实机 codesign／自建站点验收均 NOT RUN。JEV 前轮工具层拒绝：`MCP tool call requires approval, but approval policy is never`；未获 JEV 判断，本轮不绕过权限。prepared 不等于提交或获批。

## 前轮执行记录（历史证据，不代表本轮源码）

## 本轮执行证据

初始工作区干净；基线与用户指定一致。首轮构建在 Swift switch 的返回上下文报错后修复，`build-2.log` 构建 PASS（331.45 s）。定向首轮 `targeted.log` 执行 241 项，26 个失败；第二轮 `targeted-2.log` 构建 PASS（60.33 s），241 项、23 个失败。

本批修正：NOFOLLOW 必须使用现有 `SecureSourceFile.canonicalizedURL` 的 realpath 边界；Foundation 路径解析仍会重新引入 `/var` 别名（单独临时空 SQLite 探针证明 `/var` 打开 NOFOLLOW 返回 14、`/private/var` 返回 0；没有读取真实数据）。保留 NOFOLLOW、身份链和最终链接拒绝，不放宽路径检查。另修正统一字体、D91 白名单偏好守卫；恢复 Store 将路由移到辅助方法，保留原“无论恢复成败都豁免源刷新”断言原文。

环境失败（须主会话原样复跑，不删断言）：`BrowserPrivacyRecoveryTests.testRecoveryFolderIsExcludedFromTimeMachine` 两处资源标记断言；`PrivacyCleanupPresentationTests.testCopiedAddressesAreMarkedConcealedAndTransient` 五处系统剪贴板断言（未修改该既有实现，暂按沙箱系统服务限制待外部核验）；`TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory` 两处、`testTemporarySuiteCanBeReopenedOnAWorkerThread` 一处落盘断言，日志有 `sandbox_extension_issue_file ... Operation not permitted`。新偏好白名单测试在进程内通过，但跨进程持久化仍需外部验证。其他失败在修正后以最终日志为准。

任何没有运行的项目均 NOT RUN。JEV `jev_decide` 被工具层拒绝：`MCP tool call requires approval, but approval policy is never`。接口不提供模型参数，本轮实际模型标识未取得，没有获得 JEV 判断或复核结论。prepared 交付不等于提交／合并／部署。


### 最终修正与交付

- 新夹具补齐快照根目录，并用 `isDirectory: true` 构造恢复目录（与生产默认根一致）；没有为夹具修改产品权限或放宽路径检查。
- 最终新增 15 项在 `targeted-3.log` **PASS**，含七个适配器循环的删除／恢复、事务故障、备份故障、旁文件与运行门槛。历史处理器 58、恢复边界 33、UI 一致性 46 全通过。
- `targeted-3.log` 总计 241 项、0 跳过、10 处断言失败（四个既有方法）；不可把整个定向集合记为通过。31 项恢复测试的资源标记 2 处，37 项展示测试的系统剪贴板 5 处，21 项偏好卫生的沙箱落盘 3 处；待主会话外部原样核验。
- 最终中英文恢复失败文案保留具体原因与是否可能写入说明，并把历史措辞替换为实际数据类型；完整数据库备份说明扩展至其他浏览器数据。该最终源码以 `final-targeted.log` 为准。
- `git diff --check`、`script/check_private_api.py` **PASS**。未运行完整 `script/verify.sh`、Release、专门严格并发构建、红／反证、原生应用与真实数据验收，均 **NOT RUN**；完整脚本命令已列在上文，由主会话执行。
- `.git` 按只读交付：scratch `prepared/01-code.patch`、`02-tests.patch`、`03-docs.patch`、`all.patch`、提交说明、`manifest.json`、`static-checks.json` 与 `commit-prepared.py --validated`；未进行 git 提交。`mutations.json` 20 项及定向类清单位于 scratch 根。


最终验证证据：`logs/final-targeted.log`，构建 **PASS / exit 0**（41.44 s）；定向 **FAIL / exit 1**，241 项、0 跳过、10 处既有断言失败（0 unexpected）。新增数据 15／历史处理 58／恢复边界 33／UI 一致性 46 均 0 失败；最终源码的失败名单与上文环境受限名单完全相同，没有新增代码失败。该名单归因仍待沙箱外核验，不能把未改实现视为环境正确性的证明。未运行变异，不声称红绿／反证已完成。

## 修复轮 2（2026-10-13；独立复核 2 的 P1×2、P2×7）

本轮从 `git status` 开始，HEAD 仍为 `a010e5b3c24859e3c224b5dd606dbbb471102884`；保留修复轮 1 全部修改与未跟踪文件。任务卡、修复轮 1 要求、本交接和 `review-claude-2.md` 均已读取。以下取代前轮“Firefox 锁存在即运行中”、原 id 行恢复、父域白名单与整库恢复失败修剪的口径。未提交／push／安装／运行应用，未读取真实 profile、Cookie／表单值或钥匙串。只用本测试拥有的临时 SQLite profile。

| 复核项 | 本轮处理与行为证据 |
|---|---|
| P1-A：Firefox ID 复用假恢复 | 恢复明确以 `name,host,path,originAttributes` 自然键判冲突；INSERT 排除 id，让 SQLite 自动分配。Chromium 使用非 partial 的独立唯一索引列（未知多重唯一键保守拒绝）。SQLite 内部 COUNT 计算备份行数减去自然键已存在行数，实际 added 必须相等，事务内及新只读连接检查缺失自然键数为零，并核对分组计数；任何不符不写 restoredAt、不报已恢复。真实 Firefox schema 夹具先保留 id 1，删最新 id 2/3，新 Cookie 自动复用 2/3，恢复后旧自然键获得新 id，两条新记录仍保留。另注入错误 added=0 与错误分组回读，证明期望大于零不能假成功。 |
| P1-B：残留 .parentlock | NSWorkspace 的 NSRunningApplication bundle id 检查涵盖 Firefox、Developer Edition、Nightly、Zen、LibreWolf、Waterfox。`.parentlock` 普通残留文件不等于运行；O_NOFOLLOW 打开、fstat/lstat 核对 inode，F_GETLK 探测、非阻塞 flock 与 F_SETLK 试锁（两种试锁依次释放，避免 macOS 锁机制互相干扰），持有时报运行中，不可判断时报“无法核实配置锁”。不创建／删除／修改锁文件内容。扫描可选与执行共用 requireQuit，组携带实际拒绝原因。普通无锁残留允许扫描、删除；Python 子进程只在临时锁文件上持 fcntl 锁，扫描只读、删除拒绝且备份为空；已注册变体各有 bundle id 行为测试。 |
| P2-1：真实 Chrome schema／独立索引 | 夹具改为真实 Chrome 20 列 cookies、meta 表和独立 cookies_unique_index（包括 top_frame_site_key、has_cross_site_ancestor、path、source_scheme、source_port）。行为测试确认备份复制独立唯一索引、meta 不进入行备份，真实数据表顶层 SELECT 只返回 host_key／COUNT，payload 从未返回 Swift。 |
| P2-2：多语句 DDL | sqlite_master 的 CREATE TABLE／CREATE UNIQUE INDEX 仅用 sqlite3_prepare_v2 执行；在 statement step 前验证 tail 只含空白，拒绝其他语句和多语句。注入 `CREATE TABLE ...; DELETE ...` 证明第一条也没有执行、原 Cookie 计数不变；合法单条末尾分号／空白允许。 |
| P2-3：只读 ATTACH | 归档阶段只有新备份主库可写，源库 URI 为 mode=ro&immutable=1。删除／恢复／新连接恢复回读的封存备份均 mode=ro，只有目标主库可写。注入的 SQLite db_readonly 回调逐次核对 source/saved 的实际状态；三次 saved 附加均只读，未展开 SQL trace 不输出参数或值。 |
| P2-4：父域 Cookie 白名单 | 复用 group.isProtected：保留 mail.google.com 时，除精确和子域外，带前导点并 domain-match 的 .google.com 也保护。不把不相干 badgoogle.com 当父域。UI 可选判断、keep 后移除选择、执行边界复核使用同一方法；界面明确解释。合并显示的父域组含 host-only 同域成员时保守保护整个组。 |
| P2-5：确认文案 | 共享纯函数按实际类型生成首句与风险文本，最多列八项，更多显示“等 M 项（仅列前 8 项）”；不描述未开放的站点存储。Firefox Cookie 专门提示会话恢复文件可能在启动时补回。下载说明只删记录、整库恢复会覆盖同库历史；表单只说明已开放普通 autofill。中英文行为测试覆盖一百项列表及下载独立文案。 |
| P2-6：并发原因 | 根级数据租约非阻塞 flock 忙返回 concurrentOperation，显示“已有删除或恢复在进行”；非法租约文件／权限错误仍归备份存储失败。持有一个真实临时租约后再次删除，证明不是 capacity。 |
| P2-7：下载恢复失败备份 | 数据恢复也持有根级数据运行租约；整库恢复先预留一份撤销备份额度，满额拒绝且不创建备份。成功／失败均 annotateDataRun，不调用会修剪他人备份的 annotate；defer 显式释放撤销 writingLease 与运行租约。测试先已有 11 份，生成撤销备份到 12 份后注入“写入后回读失败”，原 11 UUID 全保留、结果失败且显示可能写入；随后能取得撤销备份租约与运行租约，再次满额恢复失败且 UUID 集合不变。 |

### schema 与锁依据

- Chromium [131.0.6761.0 的 SQLitePersistentCookieStore CreateV23Schema／CreateV24Schema](https://chromium.googlesource.com/chromium/src/+/refs/tags/131.0.6761.0/net/extras/sqlite/sqlite_persistent_cookie_store.cc)：真实 20 列和独立唯一索引。本轮夹具所有内容均人为假数据；不代表本机 Chrome 版本验收。
- Mozilla [CookiePersistentStorage.cpp 的 CreateTableWorker（schema 16）](https://raw.githubusercontent.com/mozilla/gecko-dev/master/netwerk/cookie/CookiePersistentStorage.cpp)：2026-10-13 查询 gecko-dev master，真实 id INTEGER PRIMARY KEY 与 moz_uniqueid UNIQUE(name,host,path,originAttributes)。该来源是浮动 master，未声称锁定本机 Firefox 版本。
- Mozilla [nsProfileLock.cpp](https://raw.githubusercontent.com/mozilla/gecko-dev/master/toolkit/profile/nsProfileLock.cpp)：Unix 路径使用 fcntl，Unlock 关闭描述符且保留锁文件。本轮已通过临时子进程锁夹具验证，真实 Firefox 正常退出／codesign 仍 NOT RUN。Mozilla Team ID 43AQ936H96 沿用，测试固定团队身份允许、其他／缺失拒绝；不能把这个纯策略测试当作实机签名核对。

### 改写前轮断言的具体依据

- `testProfileLocksRefuseBeforeBackup` 的 Firefox 悬空符号链接从 browserRunning 改为 lockUnverifiable：链接存在不足以证明进程运行，仍严格拒绝写。Chromium 原 browserRunning 断言保留；两者新增扫描不可选断言。
- SQL trace 的 autofill 恢复从 `SELECT *` 改为显式列列表；断言仍验证实际 INSERT 发生。自然键 COUNT 的嵌套查询在 SQLite 内部包含 autofill value 作为唯一键，只返回 COUNT，因此顶层“不返回 payload”断言允许此 COUNT 语句，其他 SELECT 的值列／星号守卫保留。新增真实 Chrome 顶层 SELECT 白名单断言与 readonly 附加行为断言。没有降低测试阈值或删除安全断言。
- 共享辅助与策略方法均无 `#if DEBUG`。ScanStore.swift 和其他禁改模块未动；前轮 SQLiteSnapshotService 的读取回退保留，本轮恢复新连接先走已有元数据验证再附加备份，保证已关闭 WAL 格式可触发原有受保护 immutable 回退。

### 运行命令与交付边界

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8 swift build --disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r3-privacy-cookies/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3 --build-tests
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8 swift test --disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r3-privacy-cookies/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3 --skip-build --filter 'BrowserPrivacyDataTests|BrowserPrivacyRecoveryTests|BrowserPrivacyRecoveryEdgesTests|BrowserPrivacyHistoryProcessorTests|PrivacyCleanupPresentationTests|TestPreferenceHygieneTests|UIConsistencyRegressionTests|BrowserPrivacyRecordScannerTests'
```

`run-fix2.py` 原样执行上述参数并保留最终 `fix2-build.log`、`fix2-targeted.log`、`fix2-results.json`。mutations 从 33 扩到 50，新增 secure_delete、源库只读挂载、封存备份只读挂载、Firefox Team ID、恢复事务／提交后回读、恢复结构比对、UI 白名单及 P1-A/P1-B、DDL tail、并发和恢复额度。`fix2-mutation-validation.json` 校验全部 before 逐字唯一、ID 唯一、expected_occurrences=1、filter 方法存在 **PASS**。变异执行 **NOT RUN**，由主会话按 mutations.json 逐项执行，不能据唯一匹配声称反证击中。P1-A/P1-B 红／反证做法是分别恢复原 id 插入、把残留锁存在当运行中；对应真实 schema 与无锁／持锁行为测试必须失败。

prepared 重生成仍按 01-code、02-tests、03-docs，包含前轮累计改动，基于 a010e5b3；manifest 核对最终文件／补丁 SHA-256，补丁反向检查通过后交付。主会话须完成沙箱外四个原测试复跑、变异反证、独立复核及集成门禁，再用 `commit-prepared.py --validated`；本会话不执行提交。

JEV **UNAVAILABLE**：已检查实际工具 schema，jev_review 没有模型参数；调用返回 `MCP tool call requires approval, but approval policy is never`。未获得实际模型标识或判断、不绕过权限，证据 `jev-fix2.json`。完整 verify.sh、Release、安装、运行应用、真实 profile／自建站点验收和实机 codesign 均 **NOT RUN**。复核九项代码与隔离回归已处理；真实 Firefox 退出残留锁、重启会话 Cookie、Chromium 分区及服务端登录是否仍有效需主会话获用户授权后实测。

### 修复轮 2 最终验证结果

- **构建 PASS / exit 0**：`fix2-build.log`，37.76 s，用户指定 Xcode／locale／沙箱参数／jobs 3，包含 build-tests。
- **定向集合 FAIL / exit 1（仅已知沙箱受限方法）**：`fix2-targeted.log`，323 项，1 项原有 opt-in 跳过，10 处断言失败，0 unexpected。BrowserPrivacyDataTests **45 项全通过**（前轮 33＋本轮 12）；历史处理器 58、恢复边界 33、扫描器 52（1 跳过）、UI 一致性 46 均 0 失败。
- 已知失败原样保留：BrowserPrivacyRecoveryTests.testRecoveryFolderIsExcludedFromTimeMachine 两处；PrivacyCleanupPresentationTests.testCopiedAddressesAreMarkedConcealedAndTransient 五处；TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory 两处、testTemporarySuiteCanBeReopenedOnAWorkerThread 一处。前轮 review-claude-2.md 已记录沙箱外通过，本轮仍需主会话对最终源码复跑；本会话不把整个集合记为 PASS。
- **静态检查 PASS**：git diff --check；script/check_private_api.py（7 个已允许调用）；50 条 mutation 的唯一匹配／filter 校验；prepared all.patch 反向检查及最终文件／补丁哈希一致。
- 本轮早期非环境失败已修正：macOS flock 与 fcntl 必须分开试锁；恢复只读连接先校验主库，使关闭 WAL 的 immutable 回退可触发；测试短作用域释放临时运行租约后再测额度。最终日志无这些失败。

## 修复轮 3（2026-10-13；复核轮 3 唯一 P2-R3-1）

基线 `a618c2ba`，开始时工作区干净。本轮只修改 Firefox 锁探测、相关隔离测试及本交接，scratch `mutations.json` 由 50 增至 51 条。未提交、未运行／安装应用；未读取真实 profile、Cookie／表单值、钥匙串。所有锁与 SQLite 操作仅使用测试拥有的临时夹具。

### 两级探测与调用点分类

- **只读级** `requireFirefoxUnlocked`：`lstat` → `open(O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)`，不带 O_CREAT → `fstat` 核对 dev/ino → `fcntl(F_GETLK)` → 再次 lstat 核对身份 → close。不调用 flock/F_SETLK，不创建或删除锁文件；不存在仍允许，非普通文件／无法核实仍保守拒绝。
- **写入级** `requireFirefoxUnlockedForWrite`：先经过同一只读查询与身份检查，再做一次 `flock(LOCK_EX | LOCK_NB)`，成功立即 `LOCK_UN`；保留 flock 持有者检测，删除整个 F_SETLK 试锁步骤。不是持锁覆盖事务；写入级仍有最短试锁窗口，扫描已完全移除该窗口。
- `requireQuit`、`requireProfileUnlocked` 默认只读，写边界显式传 `forWrite: true`。观察钩子 `observeFirefoxWriteProbe` 仅记录真实试锁入口，不代替系统调用或修改其结果。

逐个生产调用点（下列为本轮源码行号）：

| 调用点 | 级别 | 实际语义 |
|---|---|---|
| scan:58 requireQuit(profile) | 只读 | 分组扫描／可选性／拒绝原因计算 |
| deleteBatch:107 requireQuit(first.profile) | 只读 | 首次选择与运行状态检查 |
| deleteBatch:116 requireQuit(first.profile) | 只读 | 过滤保留站点之后、备份之前的前置检查 |
| deleteBatch:128 requireQuit(first.profile) | 只读 | 归档前的进程、源身份和元数据检查 |
| deleteBatch:139 requireProfileUnlocked(first.profile, forWrite:true) | 写入 | 即将写行备份库事务；源只读附加 |
| deleteBatch:166 requireQuit(first.profile) | 只读 | 删除事务前的前置运行／身份检查 |
| deleteBatch:173 requireProfileUnlocked(first.profile, forWrite:true) | 写入 | 目标库删除事务边界 |
| restore:241 requireQuit(profile) | 只读 | 恢复前置检查 |
| restore:248 requireQuit(profile) | 只读 | 行恢复的进程前置检查 |
| restore:249 requireProfileUnlocked(profile, forWrite:true) | 写入 | 行恢复写连接准备边界（保留原双重检查） |
| restore:255 requireProfileUnlocked(profile, forWrite:true) | 写入 | 行恢复写连接／事务边界 |
| restore:300 requireQuit(profile, forWrite:true) | 写入 | 整库恢复前的最终检查，之后 recovery.restore 写回目标库 |
| requireQuit:384 → requireProfileUnlocked | 透传 | 默认只读，仅上述整库恢复显式写入 |
| requireProfileUnlocked:395/397 | 分派 | 显式写入级／默认只读级；Chromium 既有 lstat 逻辑保留 |

列出、选择与保护判断使用扫描结果，没有其他 Firefox 锁探测入口；恢复提交后的回读没有试锁。

### 隔离测试与变异

- 扩充既有 `testFirefoxHeldFcntlLockIsReadOnlyAndRefusesWrites`：Python 子进程持有临时文件的真实 fcntl 锁，只读级直接抛 browserRunning；扫描不可选且原因 browserRunning，删除拒绝、行计数和备份状态不变。
- 新增 `testFirefoxReadOnlyScanNeverProbesWriteLocksOrChangesLockFile`：直接只读查询与扫描后，用第二个 fd 的 F_GETLK 验证 F_UNLCK，文件 dev/ino 与纳秒 mtime 不变；试锁观察器调用次数为零。随后真实删除必须进入观察器，证明钩子没有断线。F_GETLK 的事后无锁断言不能独自证明没有瞬时试锁，因此同时用入口观察器确定扫描未进入写入级。
- 新增 `testFirefoxWriteProbeRefusesHeldFlockAndReleasesIdleLock`：另一独立 fd 持 flock 时写入级拒绝；解锁后写入级通过，原 fd 可以立即重新加锁，证明探测已释放。既有残留锁、删除、恢复与进程门槛测试保持原断言。
- 新 mutation `P2-R3-scan-must-not-probe-write-locks`：唯一 before 为 `do { try await requireQuit(profile) }`，after 改成 `do { try await requireQuit(profile, forWrite: true) }`；filter 指向新增只读扫描测试。51 条 before 逐字唯一、ID 唯一、expected_occurrences=1、filter 存在均 PASS。只执行本轮新增变异，其他 50 条本轮 NOT RUN。

### 命令与证据

沿用上一轮命令：Xcode-27.0.0-Beta、LC_ALL=en_US.UTF-8、`--disable-sandbox -Xswiftc -disable-sandbox --scratch-path /Users/developer/Developer/.sc-build/r3-privacy-cookies/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3`；build 加 `--build-tests`，test 使用 `--skip-build` 与同前八个测试类 filter。实际执行脚本 `run-fix3.py` 在 finally 中逐字恢复变异源码，再重建并跑 Firefox 测试；最终结果见 `fix3-results.json`。

- **构建 PASS / exit 0**：`fix3-build.log`，13.37 s。初次测试新增代码尝试修改 Fixture 的 let service，编译失败；改为复制 service 后注入观察器，未修改夹具不可变约定，最终构建通过。
- **定向集合 FAIL / exit 1**：`fix3-targeted.log`，325 项，1 项原有 opt-in 跳过，10 处断言失败，0 unexpected。BrowserPrivacyDataTests **47 项 PASS**；历史处理器 58、恢复边界 33、扫描器 52（1 跳过）、UI 一致性 46 均零失败。
- 四个既有受限方法原样保留：Time Machine 两处、私有命名剪贴板五处、偏好落盘三个断言。失败名称与修复轮 2 相同；复核轮 3 的沙箱外通过记录是前轮源码证据，本轮仍需调度方对最终源码沙箱外原样复跑，不能声称整个集合 PASS。
- **静态 PASS**：`git diff --check`、`script/check_private_api.py`（7 个已允许调用）；`fix3-mutation-validation.json` 记录 51 条唯一匹配检查。

JEV **UNAVAILABLE**：核对实际 jev_review schema，没有模型参数；本轮调用再次返回 `MCP tool call requires approval, but approval policy is never`。未取得实际模型标识和判断；未绕过权限。完整 verify.sh、Release、安装、应用运行、真实 profile 与实机验收均 NOT RUN。上一轮 prepared 包未重生成，本轮交付以当前 worktree diff 与上述日志为准；不提交。

### 修复轮 3 最终反证与恢复结果

- **新增 mutation KILLED**：`fix3-mutation-build.log` exit 0；`fix3-mutation-test.log` exit 1，恰好 1 项测试、1 处预期断言失败：`Read-only scan must never enter the write lock probe`（BrowserPrivacyDataTests.swift:622）。不是编译失败或其他环境失败。
- **逐字恢复后构建 PASS / exit 0**：`fix3-restored-build.log`，13.97 s；**Firefox 7 项 PASS / exit 0**：`fix3-restored-firefox.log`，0 失败、0 跳过。最终 scan:58 保持默认只读调用。
- 最终 `git diff --check` PASS；HEAD 仍 a618c2ba，worktree 仅上述源码、测试、交接三文件修改，scratch mutations 为 51 条。没有提交。其他 50 条 mutation 本轮未执行。

## 修复轮 4（2026-10-13；主会话完整验证 main-final-0510 三项问题）

开始时 HEAD `d6b5ba4e`、工作区干净；先 `git merge integration/2.0.0-beta`，DECISIONS.md 冲突用 `resolve-decisions.py ours-first` 解决（合并提交 `0d49347a`，无冲突标记残留）。未运行／安装应用；未读取真实 profile、Cookie／表单值、钥匙串。

### 1. 隐私页骨架下移（BrowserPrivacyLightfieldNativeTests 74 处断言）

- **根因**：本批在 `BrowserPrivacyWorkspaceView.body` 外层加了 `VStack { HStack { 浏览记录 / Cookie 与其他数据 按钮 } ; 页面 }`，按钮行位于整个 D67 骨架之上，使 title／content／primary／status 在落地页与结果页整体下移（24 pt 或 12 pt，取决于尺寸），结果页顶部超出 72 pt 限制。
- **修复**：删除外层按钮行，入口放进锁定骨架内既有槽位：落地页与结果页都用 `FeatureLightfieldPage` 的状态栏动作（`statusActionTitle/statusAction`，与 SystemUtilities／文件页同一做法），结果页经 `BrowserPrivacyRecordResultsView(onShowDataTypes:)` 传入（默认 nil，测试构造不变）；扫描中、处理中禁用。数据页标题行右侧新增“返回浏览记录”，数据操作进行中禁用。期望数值与容差未改。

### 2. “最近的删除”备份说明（DeclutterD4D5ContractTests 254–255）

- **判断**：行为是 D91 有意改变，不是误改。`pruneToLimit` 按 `isData` 分两池，各自最多 `maximumCount` 份；`beginDataRun` 对数据运行单独预留额度；Cookie 与 Chromium 表单（`usesRowBackup`）只备份所删行，其余类型（下载、存储等）备份所在数据库。旧文案“删除前整库备份……最多 12 份”与上一轮改出的“整库备份（含其他浏览器数据）”在行备份和两池额度下都不真实。
- **修复**：中英文改为“删除前备份：浏览记录为整库备份（含已删页面），Cookie 与 Chromium 表单自动填充只备份所删行，其他数据类型备份所在数据库；……浏览记录与其他数据各自最多 N 份（已恢复和待核实的不计）；可提前删除”。合同测试 254–255 两条 `contains` 同步锁定新的完整句子，其余断言（天数、份数常量、“已恢复和待核实的不计”）不变。这是更新过期合同，不是放宽；已写入 DECISIONS D91。

### 3. 变异

- `P1-2-separate-quota` 原存活原因：测试只做一次数据运行，本次备份被 `sparing` 排除，候选只剩 12 份历史，单池与两池结果相同。加强 `testThirteenBatchesRefuseEntireRunAndHistoryHasSeparateQuota`：12 份历史后做两次独立数据运行（先删一个站点组，重新扫描后删剩余组），第二次修剪时单池会有 13 个候选而删掉一份历史；断言历史 12、数据 2。
- `P1-A-firefox-auto-id` after 改为 `$0 == $0`（恒真，即复制 Firefox id 列），`P2-parent-domain-protection` after 改为 `$0 != $0`（恒假，即父域不受保护）；原 `true`／`false` 使闭包不再引用 `$0` 而编译失败。ID 不变，before 均唯一出现 1 次。scratch `mutations.json` 已同步更新。

### 命令与证据（`~/Developer/.sc-build/r3-privacy-cookies/logs/fix4/`）

- 构建 PASS：`build.log` exit 0（Xcode-27.0.0-Beta、LC_ALL=en_US.UTF-8、`--jobs 3 --build-tests`，同 scratch）。
- 定向测试 PASS：`targeted.log`，filter `BrowserPrivacy|Declutter|UIConsistencyRegressionTests|PrivacyCleanup`，397 项、1 项原有跳过、0 失败、exit 0。
- 变异 3/3 PASS（killed）：`mut/summary.json`；三条均由断言失败杀死（BrowserPrivacyDataTests.swift:534、583–585、760–762），不是编译失败。之后 `git status` 只有本轮 6 个源码／测试文件修改，无残留；`restored-build.log` 原样源码重建 exit 0。
- 完整 verify、Release、实机均 NOT RUN（由主会话复跑）。
