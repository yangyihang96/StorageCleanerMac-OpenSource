# r3-cloud-evict：云文件释放本地副本（D90）

基线 `3fb4f695120c83ffbfdf33cc0fe92003f3422e6c`，分支 `task/r3-cloud-evict`，基于 task/r3-files。实现位置为本 worktree；scratch 为 `~/Developer/.sc-build/r3-cloud-evict`。用户 2026-10-12 选择此功能，只借鉴竞品思路，没有复制竞品代码。

## 改动与依据

- `Features/LargeFiles/Services/CloudLocalCopyService.swift`：独立 Sendable 协议，只暴露元数据状态读取与 evict；没有删除、移动、内容读取或下载接口。iCloud 用 Foundation 官方释放 API；Native actor 把同步元数据查询、lstat 和释放移出主线程。逐级拒绝符号链接祖先，拒绝目录、链接、非普通文件和多硬链接文件；用设备/inode 与修改时间/逻辑大小复查，未知状态全部禁止。
- 可选性要求：current/downloaded、上传完成、无冲突、不上传/下载、未排除同步、没有上传/下载错误、确有分配块，所有可选 Bool 必须明确为安全值。灰显说明未上传/未同步修改、冲突、同步中或错误、占位、未知、安全路径限制、非云文件、提供商不支持。
- 状态第一次在用户进入独立页时读取，执行前再读取。Native evict 入口还会复查，拒绝身份/修改记录变化。不能把扫描时的事实视为执行时仍成立。
- 执行后新 URL 回读，仅同一文件身份、安全路径、同一提供商、已为占位且分配大小下降才记成功；统计 `max(0, before allocated - after allocated)`，before 是执行前最新测量，不是确认页估算。每文件分配大小用 lstat.st_blocks × 512，不用逻辑大小替代、不读取内容；是 D84 的逐文件本地占用差值，不能承诺磁盘卷可用空间同步增加同样数量（APFS 克隆/其他磁盘活动另算）。回读失败、回读未变化、执行失败、复查禁止、取消、批量越限、操作锁冲突分别报告。
- `LargeFilesStore.swift`：仅新增现有 coordinator 的只读访问出口。服务使用同一 HeavyWorkCoordinator 的独占 lease，避让清理/恢复等操作；退出时释放 lease。（修复轮 1 起改为独立种类 `.cloudLocalCopy`，见文末。）没有改 ScanStore、AppUpdates、清理规则、卸载、照片、容量算法或扫描算法。
- `Views/FilesLightfield/CloudLocalCopyView.swift` 与文件分析入口：检查当前目录索引里的普通文件，最多 200 项，独立选择默认全不选；每批最多 50，超过上限服务整批拒绝；确认页列对象、数量、预计本地占用、提供商、需网络重新打开恢复。只有合法所选项目才进入确认和执行。取消只停止后续项目，已受理的系统请求继续回读；不允许操作期间交互式关闭。关闭/离开会取消任务。执行结果显示实测量；原索引不自行伪改，明确提示重新分析。没有修改“优化 Mac 存储”设置。
- `CloudLocalCopyTests`：纯假提供商，不碰真实云文件；覆盖完整状态矩阵、未知证据、执行前同步变化与身份/版本变化、实测差值、必须同时占位与下降、不同失败类别、第三方降级、上限、路径去重、取消前/后、共享 lease、语言切换。协议本身没有删除/移动接口（修复轮 1 删除了假对象上协议外、永远调用不到的 delete()/move() 陷阱，它们不构成证据）；源码守卫锁定 Native 没有删除、移动、内容读取、下载调用，修复轮 1 起另有临时目录本地文件上的 Native 闸门行为测试。
- DECISIONS 最上方追加 D90。没有改写任何既有断言。

## 提供商能力表与接口证据

| 提供商 | 本应用可用能力 | 同步状态证据 | UI / 操作 |
|---|---|---|---|
| iCloud Drive（`~/Library/Mobile Documents/` 下，或桌面/文稿且与家目录同卷、isUbiquitousItem 为真；修复轮 1 起正向认定） | `FileManager.evictUbiquitousItem(at:)` | URLResourceValues 的 isUbiquitousItem、downloadingStatus、isUploaded、hasUnresolvedConflicts、isUploading、isDownloading、isExcludedFromSync 和错误属性；缺失即禁止 | 状态全安全才允许勾选和确认释放 |
| OneDrive 新 File Provider | 本应用不拥有该提供商扩展/域，无法得到合法 NSFileProviderManager | 独立应用无法取得本功能所需完整同步属性；不能从分配大小推断已同步 | 灰显“提供商不支持：请在访达中右键选『移除下载』”，无该项释放按钮 |
| Google Drive 新 File Provider | 同上 | 同上 | 同上 |
| Dropbox 新 File Provider | 同上 | 同上 | 同上 |
| 其他 `~/Library/CloudStorage` 提供商 | 同上；路径里的名称只作展示，不作支持证明 | 不猜测 | 同上 |
| iCloud 位置以外的 ubiquitous 项（修复轮 1） | 不能正向认定为 iCloud，当前一律降级 | 不猜测提供商 | 同上 |
| 旧版/普通本地同步目录 | 没有系统云属性就不能确认云文件 | 本地存在/文件大小不是上传证据 | 显示非云文件或未知，不能勾选 |

SDK 来源：Xcode-27.0.0-Beta.app 中 MacOSX.sdk 的 `FileProvider.framework/Headers/NSFileProviderManager.h` 第 35–47 行限定调用进程为扩展/包含它的主应用/兄弟扩展/本应用包内关联可执行文件，第 131–138 行说明跨提供商 user-visible URL 不能取得 identifier。项目没有第三方扩展或域，所以不伪造 domain、不调用未授权 manager。未来若有本应用自有域，可通过协议增加 NSFileProviderManager adapter，仍须能完整读同步属性后才允许选择。

官方参考：[evictItem](https://developer.apple.com/documentation/fileprovider/nsfileprovidermanager/evictitem(identifier:completionhandler:))；该 API 可以把文件物化内容变成 dataless，未同步修改、不可释放、打开的文件等会失败。第三方降级是本应用的接口权限边界，不代表这些提供商自身不支持释放。

## 验证记录

- **PASS**：最终 `swift build`（上节列出的沙箱参数，`--jobs 3 --build-tests`）exit 0，332.64 秒，日志 `~/Developer/.sc-build/r3-cloud-evict/build-final.log`。
- 首次构建 **FAIL**：exit 1，`build.log`。编译期间补入操作锁接线，产生旧 `CloudLocalCopyService.init(provider:)` 对象与最终接口不一致的链接错误。停止源码修改后，最终稳定重建已通过；没有删日志或隐去失败。
- 定向测试整体 **FAIL**：exit 1，`test-targeted.log`；111 项执行，0 跳过，两个既有测试出现 3 处断言失败。分项：CloudLocalCopyTests 14/0 失败，StorageCapacityBasisTests 11/0，HeavyWorkCoordinatorTests 13/0，FeatureLightfieldFilesPresentationTests 6/0，UIConsistencyRegressionTests 46/0；TestPreferenceHygieneTests 21 项、3 处断言失败。
- **BLOCKED（沙箱外复跑）**：`TestPreferenceHygieneTests.testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory` 在第 308 行 synchronize 与第 309 行 plist 存在检查失败；`testTemporarySuiteCanBeReopenedOnAWorkerThread` 第 324 行 worker synchronize 失败。同段日志反复出现 `sandbox_extension_issue_file failed ... defaults.plist: 1 (Operation not permitted)`。失败涉及 CFPreferences 在隔离临时偏好域申请扩展权限/落盘，本批没有改偏好工具或旧测试；源码卫生检查 `testTestSourcesUseTemporaryDomainsAndDoNotPersistStandardDefaults` 通过。不要把整体定向结果写为全绿，也不要跳过这些用例或放宽断言。主会话在沙箱外用相同 filter 复跑。
- **PASS**：`python3 script/check_private_api.py` exit 0（7 处既有白名单使用）；`git diff --check`、all.patch 与三组补丁的 reverse apply check exit 0；20 条 mutation before 逐字唯一。
- **NOT RUN**：全量/Release/严格并发完整 verify、反证执行、安装/启动/UI 实机几何、真实云 evict/内容回读/恢复、提交/推送/发布。`.git` 只读，以 prepared 交付。
- 交付：scratch `prepared/01-code.patch`、`02-tests.patch`、`03-docs.patch`（各 message）、`all.patch`、`manifest.json`（基线/组顺序/7 文件 SHA-256）、`static-checks.json`、`commit-prepared.py --validated`、生成器和 README。scratch 根还含 `targeted-classes.txt`、`mutations.json`（20 条）、`validation.json` 与构建/测试日志。

## 主会话命令与红 / 绿 / 反证

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r3-cloud-evict/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter 'CloudLocalCopyTests|StorageCapacityBasisTests|HeavyWorkCoordinatorTests|FeatureLightfieldFilesPresentationTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests'
git diff --check
```

`targeted-classes.txt` 与 `mutations.json` 在 scratch 根。20 条 before 逐字唯一，expected_occurrences=1；覆盖未上传、冲突、上传/下载/未知/占位、执行前复查、身份/修改、回读实测差值与两个成功条件、绝不删除、提供商降级、上限、取消、去重、失败分类、Native 身份检查与确认。主会话逐条应用一条 mutation → 编译 → 对应 filter 应为 RED → 严格还原 → 编译与定向全 GREEN。**本会话没有执行反证**（按批次公共要求主会话负责）；尤其 never-delete mutation 只让源码守卫读取源文件，不能调用 Native 在真实文件上尝试删除。

完整门禁另由主会话按 `script/verify.sh`（私有 verify root、STORAGE_CLEANER_VERIFY_BUNDLE=0、STORAGE_CLEANER_UI_SMOKE=0）及批次公共规则运行。prepared 的 commit-prepared.py 要求 `--validated`，只在主会话完成验证复核后使用，不替代验证。

## 必须经用户授权的实机验收（本批 NOT RUN）

1. 主会话先在用户确认的 iCloud 测试文件夹创建一个独立测试文件，记录名称、逻辑大小和本地分配大小；不要用用户已有文件。等待提供商确认上传结束、无冲突/无修改，不关闭优化 Mac 存储。
2. 在文件分析里分析该目录，进入“云文件本地副本”；核对提供商、可选性、数量、预计本地占用、网络恢复说明。再请用户明确授权对这个文件释放。授权不能泛化到其他云文件。
3. 用户确认后执行；验证文件路径/云端文件仍存在、下载状态未下载/占位、分配大小下降，结果只计回读差值。回读尚未变化必须保留“未确认”，不能补填估算成功。原分析索引提示重新分析。
4. 用户在提供商/访达打开自建文件，等待重新下载，在获授权的实机环节核对内容一致与恢复；本批没有进行内容读回。断网时确认需网络恢复说明，不声称离线可恢复。
5. 用自建测试项验证未上传/同步中/冲突会灰显或被复查拦截；批量取消不执行后续项，已受理项回读仍报告；测试文件的后续删除另须明确授权。
6. OneDrive/Google Drive/Dropbox 新版只核对降级展示，不尝试 API evict、不读取内容。非支持的路径、硬链接、目录、符号链接、未知元数据必须不能选择。
7. 安装测试版、启动、截图、中英 UI 真实窗口几何验收、上传/下载/恢复和文件内容确认均由主会话另行执行。本批没有安装、提交、推送、发布。

## 已知边界

- 公共 Foundation evict API 不能携带文件描述符/期望版本进行原子 compare-and-evict；服务和 Native 双重复查缩短竞态，系统仍负责最终同步安全性。没有读取内容或通过协调器强制物化文件来消除竞态。
- （修复轮 1 已改）回读最多 3 次只读短轮询（间隔 0.5 秒），仍未确认如实显示“未确认”，不会把成功回调当已释放。执行后不自动重新扫描，避免意外读取更多目录。
- 符号链接祖先、多硬链接文件和目录一律保守禁用；本页只处理当前目录索引内已列文件，索引外项须进入对应目录/重新分析；检查 200 项上限会显式说明。
- JEV 实际可调用工具存在但请求被审批策略拒绝：`MCP tool call requires approval, but approval policy is never`。没有模型结果，不声称 JEV 审核通过。

## 修复轮 1（Claude 子代理，2026-10-13）

依据独立复核（无 P0；P1 一项、P2 八项）。全部改动未提交；没有启动 App，没有对任何真实云文件调用 evict，也没有读取真实云文件的元数据或内容。测试只用本地临时夹具 `~/.storage-cleaner-cloudcopy-<UUID>`，结束时严格删除，残留为 0。没有放宽断言。

### 改动

- **P1 Native 闸门行为测试**：`NativeCloudLocalCopyProvider` 新增可注入的 `home`、元数据读取闭包和 evictor 闭包，默认值仍为 `FileManager.default.evictUbiquitousItem(at:)` 和 `URL.resourceValues`。测试只注入计数闭包，所以测试里不会调用系统 evict。新增以下测试，均使用本地文件：
  - 普通文件得到 `.notCloud`，包括走默认系统元数据读取的一例；
  - 文件本身是符号链接、上层目录是符号链接、硬链接（nlink>1）、目录、路径含 `..`、相对路径，均得到 `.unsafe`，且不会读取元数据；
  - `<夹具>/home/Library/CloudStorage/OneDrive-X/f` 得到 `.unsupported`，元数据读取计数为 0；
  - Native evict 入口在身份或修订变化时抛出 `CloudCopyGateError`，evictor 计数为 0；状态一致时只调用计数 evictor。
  - 夹具不放在系统临时目录：Foundation 会把已存在的 `/private/var/...` 标准化成 `/var/...`，闸门会正确地判定为路径变化而拒绝。
- **P2-1 正向认定 iCloud**：只有满足下列条件之一，才判为 `.iCloud` 且可支持：
  - 路径在 `<home>/Library/Mobile Documents/` 下且 isUbiquitousItem 为真；
  - 路径在 `<home>/Desktop/` 或 `<home>/Documents/` 下，与家目录同卷（st_dev 相等），且 isUbiquitousItem 为真。

  其他位置的 ubiquitous 项判为 `.external("其他云提供商")`，结果是 `.unsupported`。isUbiquitousItem 为假时判为 `.notCloud`。没有该值时：位于 iCloud 位置内判为 `.unknown`，位于其外判为 `.notCloud`（实测 Foundation 对普通本地文件返回 nil）。几种结果都不可选。
  - `CloudLocalCopyState` 的默认值全部改为“未知”：provider `.unknown`、supported false、safe nil、download `.unknown`，各同步布尔值为 nil，syncError 改为 `Bool?`。新测试逐项留空任一字段，都必须被拦截。
- **P2-2 独立租约种类**：`HeavyWorkCoordinator.Owner` 新增 `.cloudLocalCopy`，与所有重活仍互斥。后台活动条显示“正在进行释放本地副本…”，导航到 `.review(.largeFiles)`（文件分析）。`conflictMessage` 和 `title(for:)` 改为 `nonisolated`，供服务层生成本地化详情。HeavyWorkActivityStoreTests 的 allCases 循环会自动覆盖新种类。
- **P2-3 回读轮询**：最多 3 次只读回读，间隔 0.5 秒（`readbackAttempts`、`readbackInterval` 可注入，测试用 0）。间隔用 detached sleep，所以取消后续项目不会缩短已受理请求的回读。全部未确认时：若最后一次读取出错，记为 `.readbackFailed`，否则记为 `.unchanged`，文案为“未确认：…请稍后重新分析”。
- **P2-4 文案**：结果标题改为“本地占用实测减少（逐文件分配大小）”，预计行改为“预计本地占用减少”。
- **P2-5 错误本地化**：新增 `CloudCopyErrorText.describe`，覆盖以下情况：闸门错误、busy（复用活动条冲突文案）、取消、文件不存在、无权限、iCloud 不可用，其余显示“系统未完成请求（错误代码 N）”。服务和界面源码都不再使用 `localizedDescription`，源码守卫锁定这一点。执行前读取失败改为 `.blocked(.unreadable)`（“未能读取状态”）。
- **P2-6 源码守卫**：
  - 服务文件的禁用词增加：`removeItem`、`trashItem`、`moveItem`、`replaceItem`、`unlink(`、`rename(`、`remove(`、`truncate`、`open(`（代码里没有合法使用 O_RDONLY，所以一并禁用）、`NSFileCoordinator`、`FileHandle`、`Data(contentsOf:`、`startDownloading`、`localizedDescription`。
  - 界面文件另有一组禁用词，不含 `remove(`，因为 `selection.remove` 属于合法用法。
  - 删除假对象上协议外的 `delete()`/`move()` 陷阱及其恒为 0 的计数断言（该方法不可能被调用，不构成证据），并改正前文的夸大表述。
- **P2-7 读取与列表**：
  - `reviewCandidates` 先剔除索引里的 `isCloudOnly`、目录和非 content 项，再取前 200；
  - `readStates`/`readState` 给单项读取设上限（默认 5 秒），超时的项记为 `.unreadable`（“未能读取状态”），迟到的结果被忽略；
  - 页面改用 `FeatureLightfieldPalette.resolve(scheme)`，fg/fg2、字号 24/15/13 和 hairline 行与 `LocalModelInventorySheet` 一致。
- **P2-8**：
  - D90 措辞同步：仅正向认定的 iCloud 可执行，其他提供商当前一律降级；新增独立租约、回读轮询、读取超时、先滤占位等内容；
  - 不支持提示改为“请在访达中右键选『移除下载』”；
  - 删除测试里未使用的 TestPreferenceDomain，只保留 TestVolatilePreferences。

### 改写的旧断言（同批次、尚未提交的新测试）

- `preFailure` 原来期望 `.blocked(.unknown)`，改为期望 `.blocked(.unreadable)`。依据是 P2-7 新增了“未能读取状态”这一类。
- `readFailure` 的假对象从“第 2 次读取失败”改为“第 2 次起每次读取都失败”。原因是回读改为轮询后，只有一次失败会在下一次读取时恢复。
- `testBothPlaceholderAndDecreaseRequired` 中“替换文件”和“不安全路径”两例拆成独立测试，断言不变，这样每条反证各有精确的 filter。
- 删除 `counts.2`/`counts.3`（死陷阱计数）。
- 源码守卫里 `fresh.identity/revision == expected` 两条字符串断言改为 Native 行为测试，对应反证的 filter 也改指新测试。

### 验证（本机，非 Codex 沙箱）

- **PASS** Debug 构建：`swift build … --jobs 3 --build-tests`，exit 0，日志 `fix1-final-build.log`。
- **PASS** 定向测试：`targeted-classes.txt` 共 8 类，新增 HeavyWorkActivityStoreTests 和 HeavyWorkIntegrationTests，结果 146 个测试、0 失败、0 跳过，exit 0，日志 `fix1-final-targeted.log`。分类如下：

  | 测试类 | 测试数 |
  |---|---|
  | CloudLocalCopyTests | 26 |
  | StorageCapacityBasisTests | 11 |
  | HeavyWorkCoordinatorTests | 13 |
  | HeavyWorkActivityStoreTests | 6 |
  | HeavyWorkIntegrationTests | 17 |
  | FeatureLightfieldFilesPresentationTests | 6 |
  | UIConsistencyRegressionTests | 46 |
  | TestPreferenceHygieneTests | 21 |

  TestPreferenceHygieneTests 在本机通过，上一轮的 BLOCKED 是 Codex 沙箱造成的。
- **PASS** `python3 script/check_private_api.py` exit 0；`git diff --check` exit 0；新文件没有行尾空白。
- **反证**：`mutations.json` 共 42 条（原 20 条，其中 10 条的 before 随修复同步更新，另新增 22 条）。生成器 `generate-mutations.py` 逐条断言 before 恰好出现 1 次。
  - 用 `run-mutations.py` 逐条执行“应用 → 构建 → 跑该条 filter → 严格还原”，覆盖新增 22 条和更新 10 条，共 32 条，结果 **32/32 RED**，全部编译通过，没有超时。
  - 结果在 `fix1-mutations/results.json`，各条日志在同目录。
  - 跑完后三份被改源文件的 SHA-256 与跑前一致（`pre.sha256`）。之后重建，定向测试复跑全绿（见上）。
  - before 未变的 10 条原始反证本轮没有重跑。
- **PASS** Release 测试编译：`swift build -c release --scratch-path ~/Developer/.sc-build/r3-cloud-evict/release … --jobs 3 --build-tests -Xswiftc -enable-testing`，exit 0，用时 704 秒，日志 `fix1-release.log`。
- **NOT RUN**：全量测试、严格并发 verify、安装/启动/截图、真实云文件验收、提交。

### 残余

- Foundation 的 evict 不能做原子比较后释放；双重复查只能缩短竞态窗口。
- 单项读取超时后，后台的同步元数据调用仍可能继续占着 actor；之后的项会排队，并依次超时，记为“未能读取状态”（保守），不会误放行。
- 桌面/文稿的“同卷”判断只用 st_dev，不能区分系统映射与用户手工同卷目录；还要求 isUbiquitousItem 为真，所以只会更保守。
- 跨卷的负例只用纯函数测试；临时夹具没法制造异卷。
- `.external("其他云提供商")` 的显示名在创建时取当前语言，运行中切换语言不会刷新已读取的行。

### 实机验收清单（须用户授权，主会话执行）

1. 只用自建的 iCloud 测试文件（`~/Library/Mobile Documents/com~apple~CloudDocs/` 下的新文件），确认它显示为 iCloud 且可选；放在桌面/文稿下的同名测试文件也应如此（如果开启了桌面与文稿同步）。
2. OneDrive / Google Drive / Dropbox 下的文件只核对灰显和“在访达中右键选『移除下载』”，不执行任何操作。
3. 执行释放时，后台活动条应显示“释放本地副本”，点击后回到文件分析，而不是安全清理页。
4. 结果页标题应为“本地占用实测减少（逐文件分配大小）”。状态传播慢时，等约 1 秒的轮询后仍可能显示“未确认”，属预期。
5. 错误详情应无英文系统原文（中文界面）。
6. 已是占位的文件不出现在列表里，“已跳过 N 个云端占位”的计数正确。
7. 中英两种语言的窗口几何和配色与“本地 AI 模型”页一致。
8. `prepared/` 已过期（README 顶部已注明），不得再用于提交。
