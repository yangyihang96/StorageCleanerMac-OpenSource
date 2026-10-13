# r3-photos：系统照片图库来源

基线 `52f722aca8b735904c21c542b13bb501d4e5de99`，分支 `task/r3-photos`。遵守 D89；竞品报告只用于“发现→加入相册→用户手动删除”的产品思路，未复制 GPL 代码、素材或图库数据库读取方式。本批任何阶段都未访问真实照片图库，未运行应用、安装、删除照片或提交。

## 实现和边界

- `PhotoLibraryProviding` 是图库读写能力边界，仅暴露授权、分批元数据、小缩略图、结束扫描和加入固定待删除相册。没有删除操作。生产 provider 为惰性 PhotoKit actor，构造不调用图库。
- 相似照片页面在落地、扫描和结果态均有文件系统/系统照片图库来源选择，保持原文件数据流，不修改 `ScanStore.swift`。系统来源有独立 store 和取消状态，离开页面取消扫描。演示夹具的自动授权状态查询/缩略图任务被拦截。
- PhotoKit 仅取图片资源的标识、尺寸、拍摄/修改时间、收藏和调整资源类型（判断已编辑）。不取位置、原始文件名、原图数据、私有 KVC 大小、不上传；没有照片日志输出。通过 `PHImageManager.requestImage` 请求 96×96 `.aspectFit` 小缩略图，`isNetworkAccessAllowed = false`，当前版本；不请求 image data 或资源 bytes。本地缩略图不可用/请求超时显示缺失计数，不将缺失误报为零相似。缩略图请求共享一次完成门，支持取消和 10 秒超时。
- `.readWrite` 授权只由用户点击触发；首次授权说明仅读元数据/本地缩略图，读写能力用于相册创建及加入。已拒绝/受限/限制状态有明确说明和设置入口；不自动重弹。受限状态仅读系统允许访问的子集，文案声明结果不覆盖全图库。扫描前、每批和图库动作前重新核对授权；撤销后刷新清除结果与选择。
- 重复证据分三级，必须同尺寸、同非空拍摄时间，再按独立资源内容指纹/公开可得大小/仅元数据分桶。仅资源内容指纹级可称“完全重复”；大小一致和元数据一致均显示人工候选。**生产 PhotoKit 不提供独立原图指纹或公开可靠文件大小，故两字段保持 nil，实际完全重复确认不可用**。不能把缩略图哈希、标识、资源文件名当作内容指纹，也不能绕过限制读取原图补足证据。
- `ImageSimilarity` 从现有 `DuplicateFileScanner` 提取共同实现，原文件算法行为保持：dHash≤10、aHash≤10、相对宽高比差≤0.12、归一化 RGB 距离≤0.28、综合分≥0.84。相似分组与种子比较，不把传递相似性当作每一对都相似；11 个互不重叠 dHash 分段索引候选，对距离≤10不丢候选，种子按枚举顺序稳定处理。元数据重复分组成员不再跨组重复列出。
- 推荐保留顺序：像素总数更大→已收藏→已编辑→拍摄时间更早（未知排后）→标识字典序。每组恰好一张推荐，默认全部不选。用户可更换保留项；保留项不能勾选，也不能通过异常选择 ID 写入；加入前仅允许本次结果中的非保留成员。
- 分批 200，硬上限 50,000；PhotoKit fetchLimit 为 N+1，额外一项用于确认截断，不声称得到了完整图库总数。按拍摄时间升序，隐藏照片不纳入。后台 actor 扫描、逐照片/比较检查 Task 取消，结束释放 fetch 结果。相似比较硬预算 2,000,000 次；耗尽时保留已找到的组并明示结果不完整。
- 哈希缓存为 App 自己数据目录 `PhotoLibrary/thumbnail-hashes-v1.json`，包含 localIdentifier、modificationDate、算法版本键和必要图像特征，不缓存原图或预览。未知修改时间不缓存。持久化过滤本次有效键；读取限制 32 MiB，目录/文件权限 0700/0600。缓存读写故障仅降级，不隐藏有效扫描结果。测试缓存仅在 TestFileSystem 拥有的临时根内。
- 唯一写路径 `PHPhotoLibrary.performChanges` 创建/复用普通相册「存储清理助手-待删除」，`PHAssetCollectionChangeRequest.addAssets` 加入既有照片；没有 `PHAssetChangeRequest`、删除/移除 API。写前核对全部所选照片仍可访问，事务后回读相册成员；加入成功不等于删除或释放空间。失败/回读失败明确显示待检查，未宣称照片已删除。完整中英确认与完成文案，包含去照片 App 查看删除、最近删除 30 天恢复、打开照片 App。
- `script/build_and_run.sh` 的运行包主 Info.plist 和 Beta 重建的 InfoPlist.strings 加 `NSPhotoLibraryUsageDescription`；资源中英两份同样维护。仅作照片相关最小改动。当前脚本签名没有 App Sandbox entitlement，故本批不新增 entitlement。将来沙盒化必须加入 `com.apple.security.personal-information.photos-library` 并重新实机验证 TCC/签名。

没有改写旧测试断言；没有改清理规则、卸载逻辑、AppUpdates 或 ScanStore。

## 测试和证据

单元测试只使用 FakePhotoLibrary（绝不实例化生产 PhotoKit provider）。覆盖重复分级、未知时间、相似阈值和非传递分组、比较预算、推荐保留排序、五类授权、权限撤销、分批/截断、取消释放、哈希缓存持久化/标识隔离/日期失效、保留项保护、唯一相册加入和零删除。生产源码守卫另断言没有删除/原图读取/私有大小/位置 API，有固定 96×96 和禁止网络请求。假对象的加入记录与删除计数配合源码守卫，避免把无删除方法的协议计数当成独立生产证据。

本轮命令和结果会在下面最终记录；构建/定向测试与真正打包、TCC、相册创建、用户删除恢复分别报告。

## 主会话验证与反证

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer LC_ALL=en_US.UTF-8
F=(--disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r3-photos/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3)
swift build "${F[@]}" --build-tests
swift test "${F[@]}" --skip-build --filter 'PhotoLibraryTests|DuplicateFileScannerTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests'
python3 script/check_private_api.py
bash -n script/build_and_run.sh
git diff --check
```

定向类清单位于 `~/Developer/.sc-build/r3-photos/targeted-classes.txt`。不跑全量和变异；由主会话后续执行完整门禁：`DEVELOPER_DIR=... STORAGE_CLEANER_VERIFY_BUNDLE=0 STORAGE_CLEANER_UI_SMOKE=0 STORAGE_CLEANER_VERIFY_ROOT=<本批私有验证根> script/verify.sh`，验证根不得与其他批次共用。

红/绿/反证：沙箱 scratch 的 `mutations.json` 含逐字唯一的 before、after 和方法 filter。主会话在隔离副本逐条只替换一次→重编译→运行指定测试，预期红→恢复 before→重编译→定向绿。首条删除反证仅在生产注释注入禁止 API 标记，验证源码边界守卫，不实际调用删除；不以真实图库执行任何反证。其余覆盖固定相册/加入 API、网络/尺寸、四种阈值、保留排序、拒绝授权、上限、取消、缓存键和选择过滤。测试/反证始终用假图库。

## 主会话实机验收（需用户明确授权，使用用户同意的可恢复测试照片）

1. 主会话完成合并门禁与独立复核后，在获得安装授权时构建 `./script/build_and_run.sh --beta --install`；核对 Beta 身份、最终主 plist 与 en/zh-Hans InfoPlist.strings 隐私文案。打包/安装不替代真实 TCC 验收。
2. 用户同意访问测试图库后进入“相似照片→系统照片图库”。初次进入只显示状态，点击授权才显示 macOS 照片读写权限弹窗；核对中英说明用途。先拒绝，刷新、离开再进入、点授权都不反复弹窗；去设置开启后刷新可扫描。受限制/受限授权的实际可用性按当前 macOS 验证，不支持状态不得伪造。
3. 同意只读扫描后，用已知相似/尺寸时间相同的测试照片核对分组、证据标签、推荐保留（分辨率/收藏/编辑/较早优先）、默认不选和更改保留项。云端未落地缩略图显示不可用，不开启网络下载。扫描中点取消、切换来源、离开页面，确认取消且无结果被迟到任务覆盖。大库上限和比较预算优先用假库，不为验收扫描用户完整大库。
4. 用户授权加入所选测试照片后，逐张勾选非保留项，确认框核对对象数量、固定相册及读写原因。执行后在照片 App 检查相册首次创建与下次复用、选中成员、原图库照片仍存在；重复加入不会新建同名相册。若回读失败，记录未核实，不宣称完成。相册移除成员操作不属于本 App 功能。
5. **删除须另获用户对具体测试照片的明确授权，由用户或主会话在照片 App 操作。** 在待删除相册中选择对应测试照片，使用“从图库删除照片”（仅从相册移除不会进入最近删除），确认后检查“最近删除”；在其保留期限内选择恢复，核对回到图库。不得清空最近删除、不得删除用户未授权照片、不得用本 App 调用删除 API。记录 Photos 展示的真实剩余天数；本 App 文案为标准 30 天说明，不把倒计时当固定 30 天。
6. 验证中英文页面/确认/完成/授权提示和 1280×763、较小窗口下的来源切换、滚动、可取消与底部动作；确认选中数量无释放空间承诺。最后按用户授权整理测试相册，不能默认为可删除相册或照片。

## 交付

`.git` 在本会话只读，使用 `~/Developer/.sc-build/r3-photos/prepared/` 三组：代码/测试/文档。包含分组补丁、提交说明、all.patch、manifest.json（基线、分支、最终文件 SHA-256 与产物哈希）、static-checks.json、`commit-prepared.py --validated`。该脚本只供主会话验证后提交，不替代验证、不安装、不 push。`targeted-classes.txt`、`mutations.json` 位于 scratch 根。

JEV：工具接口已核对，未暴露模型标识/模型参数。一次边界判断调用被系统自动审批拒绝（`MCP tool call requires approval, but approval policy is never`），未实际取得判断；没有声称 JEV 已复核，也没有改用别的第三方模型。

## 本轮实际结果（2026-10-12～13）

- **PASS** 最终 SwiftPM Debug 带测试构建：上列 `swift build ... --jobs 3 --build-tests`，exit **0**，66.58 秒；日志 `~/Developer/.sc-build/r3-photos/logs/build-final.log`。Swift 6 编译完成，最终本批源码没有新编译告警；只有 SwiftPM 沙箱缓存不可写/skip-update 弃用告警。首轮 exit **1**：编译中补充测试导致测试使用新 comparisonLimit 参数、先前已编译模块仍是旧签名；固定源码重建通过，中间构建也曾通过（97.12 秒）。最终增量构建对应最终源码。
- **FAIL / 部分 PASS** 四类定向 `swift test ... --skip-build --filter 'PhotoLibraryTests|DuplicateFileScannerTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests'`，exit **1**：执行 **125 项，4 个失败断言，0 跳过**。日志 `~/Developer/.sc-build/r3-photos/logs/targeted.log`。
  - PhotoLibraryTests：**18 项，0 失败**（0.064 秒），仅假图库。
  - UIConsistencyRegressionTests：**46 项，0 失败**。
  - DuplicateFileScannerTests：40 项，1 失败；三个现有相似图像算法回归均通过。失败方法 `testAPFSCloneIsLogicalDuplicateWithoutClaimingPhysicalSavings`：期望 `.apfsClone`，得到 `.independent`。单方法再跑 exit **1**，日志 `logs/apfs-rerun.log`。相关 `storageRelationship` 函数与基线逐字相同，SHA-256 `8e2854306bb1b70f9b39fe198f5b68749fe6b43bee0392c1e8f83fac375c7e99`；本批没有修改克隆证据读取或该测试。**根因未确定，不能把它断言为已证实的沙箱失败或基线已知失败**；主会话须复跑调查。
  - TestPreferenceHygieneTests：21 项，3 失败断言、涉及 2 方法：`testFactoryKeepsThePlistInItsOwnDirectoryAndRemovesTheWholeDirectory`（308/309：synchronize 和 plist 存在）、`testTemporarySuiteCanBeReopenedOnAWorkerThread`（324：synchronize）。对应日志明确 `sandbox_extension_issue_file ... defaults.plist ... Operation not permitted`，测试卫生源码守卫通过。没有改测试偏好工厂、放宽断言、跳过方法或写真实偏好目录；这两方法交主会话沙箱外复跑。
- **PASS** `bash -n script/build_and_run.sh`、`python3 script/check_private_api.py`（7 个现有 allowlisted uses）、两份 `plutil -lint Resources/{en,zh-Hans}.lproj/InfoPlist.strings`、`git diff --check`，全部 exit **0**。
- **PASS** prepared 分组补丁完整性：all.patch 反向 `git apply --check --reverse` exit **0**，14 个最终文件哈希、3 组顺序；21 个 mutation.before 各逐字唯一且 expected_occurrences=1。生成器、提交脚本 Python 语法通过。未执行变异，未声称独立复核或完整门禁通过。
- **NOT RUN** 全量门禁、Release、真实 TCC/图库/相册事务、Photos 删除恢复、安装、git 提交/合并、发布。**BLOCKED** JEV（前述自动审批原因）。

主会话在合并前必须解决/复跑上列 APFS 方法与两项偏好同步方法；本批只达到“源码、假图库功能测试与 prepared 交付完成”，没有达到完整验收或可发布状态。

## 修复轮 1（独立 Claude 复核后，2026-10-13）

本节覆盖上文首轮实现描述中冲突的内容；上文测试结果保留为历史记录。已先检查 git status，保留全部已知本批修改与新文件；只在本 worktree 和本批 scratch 工作，未访问真实图库。修复前 prepared 保存在 scratch `prepared-before-repair1/`，最终提交使用更新后的 `prepared/`。

### 修改与依据

- **P0-1**：纠正首轮“仅沙盒需要”的错误判断。Hardened Runtime 访问照片同样需要 `com.apple.security.personal-information.photos-library`。新增仓库文件 `Resources/Signing/StorageCleanerMac.entitlements`，仅此键为 true；主 App 的单条 codesign 命令加 `--entitlements`，不修改风扇/文件 helper 或 Finder 扩展签名。紧邻主 App 签名增加实际签名 entitlement 回读校验，Beta bundle 验证再次核对 entitlement 和用途说明。使用 `codesign -d --entitlements :-` 的 plist 输出与 Python plistlib 精确取完整键（避免 plutil 点号路径歧义），配合脚本既有 `set -euo pipefail`，缺失/false/异常输出即失败。**本轮未真实签名/打包，不声称已验证已安装 Beta 的权限**。
- **P0-2**：不修改 `script/make_release_dmg.sh`。`PhotoLibraryAvailability` 在主 Bundle 缺少/空白用途说明时返回 false，并通过公开 `SecTaskCreateFromSelf`/`SecTaskCopyValueForEntitlement` 读取本进程真实照片 entitlement；必须为 true 才显示系统来源。结果为进程内静态惰性值，不对每张照片重复验证不可变签名。picker 和 provider 双门禁，不调用 PhotoKit 就可拒绝缺配置包；纯函数测试注入用途说明和 entitlement，不读取真实图库。**正式版启用必须另开获授权批次，补发布包主 Info.plist、照片 entitlement、签名回读及 TCC 实机验证；本次正式版来源保持隐藏**。
- **P1-1**：PhotoKit fetch 与纯分组统一新→旧。替换原 11 段哈希索引及每照片 Set 构造，改用最多前 **64 张**的活跃种子数组，同时限制已知拍摄时间差 **≤24 小时**；未知时间仅邻近张数比较，排在已知时间之后。分组成员始终直接和种子图像比对，不形成传递相似链。最近匹配位置维持窗口，但种子拍摄时间的 24 小时限制不会随成员推移。元数据阶段与相似回退阶段各受相同窗口，总比较硬预算仍为 2,000,000，不放宽旧阈值。元数据阶段最多使用一半预算（1,000,000）；即使旧元数据桶耗尽该阶段预算，也继续将剩余照片按新→旧进入相似回退，保证新照片的相似比对有预算。新增低预算假数据反例锁定这一保留策略。
  - 比较范围是**有意的产品限制**：跨 24 小时/远隔 64 张的相似照片不比较；新照片在硬预算耗尽前优先被处理。50,000 张上限也是最新 N 张，隐藏照片仍不包含。
  - 新性能测试使用 20,000 张固定随机假签名、每分钟一张、不同时间元数据桶。断言无预算截断、比较次数 ≤20,000×64（1,280,000）、纯分组耗时 <10 秒。双阶段病理同秒桶的理论上界为 2×N×64，且仍受 2,000,000 硬预算；不承诺任意输入全部比较或无截断。
- **P1-2**：同尺寸/同拍摄时间/同可得证据桶不再直接成组。每个成员必须有缩略图，并和种子通过共享 ImageSimilarity 阈值，才列作重复候选；不匹配/缩略图缺失的照片不被消费，进入附近相似流程（缺图仍不比较）。生产仍没有可靠原图大小/指纹，元数据候选不宣称原图完全相同。新增同秒同尺寸但颜色完全不同、缩略图缺失、匹配成组、失败后与邻近不同时间照片相似的测试。
- **P1-3**：新增 Foundation-only `PhotoAlbumAccessing` 和 `PhotoReviewAlbumCoordinator`，将可访问资源校验、按 ID/标题查找、performAddition（封装 performChanges）、新建及成员回读拆成可替换接口；所有 PhotoKit 代码仍在原 provider 文件。假 backend 实际记录事务及查找/回读参数，验证已存 ID 复用、新建、回读缺成员失败、部分资源可访问时写前拒绝四路径。
  - 整个 `Sources` 的 Swift/C/ObjC 文件禁止 `removeAssets`、`deleteAssetCollections`、`requestContentEditingInput`、`requestAVAsset`、`.highQualityFormat`、`PHAssetChangeRequest`、`deleteAssets`、原图请求；导入 Photos 的路径必须精确等于 `PhotoKitLibraryProvider.swift`。原恒真 deletionCalls 与全部对应断言已删除，替代为可观察事务路径测试和全 Sources 边界守卫，未弱化安全边界。includeHiddenAssets=false、新→旧、扫描不编码预览和 fetch 复用也有源码守卫。
- **P1-4**：`canRead` 对 limited 保留 true，新增 `canAddToAlbum` 仅 authorized 为 true。UI、store、协调器及生产 backend 都禁止 limited 加入相册；中英文明确需要完整访问。加入既有照片不是 `.addOnly` 能力，不用 add-only 权限绕过。
- **P2 相册身份**：保存创建事务 placeholder 的 localIdentifier 到 App 自己目录 `PhotoLibrary/review-album-id.json`（仅相册 ID，权限 0600）。先按保存 ID 查找并核对固定标题；失效/已改名时才按标题查找，唯一匹配可复用，多匹配则拒绝，避免选中任意首个相册。创建 ID 在成员回读前保存，因此回读失败仍保留本次创建身份，避免下次重复创建。假测试包含磁盘恢复与失效 ID 回退。
  - **同名风险**：没有保存 ID 时，PhotoKit 不提供本 App 创建者证明，唯一同名相册可能是用户建立的；加入确认的中英文文案明确可能复用您的相册。保存 ID 以后优先精确定位，不因新增同名相册改用别的相册。仍仅添加成员，不改标题或移除原有成员。不能宣称绝不复用用户同名相册。多同名时须用户在照片 App 中自行处理歧义，本 App 不自动删除/重命名相册。
- **P2 性能/隐私/UI**：扫描 request 的 includePreview=false，仅计算哈希，不编码 JPEG；UI 的单独预览请求才编码小 JPEG。扫描复用 PHFetchResult 与 ID→索引，避免逐张重 fetch；调整资源类型只在最终需要审阅的候选中读取，避免遍读所有资源列表。扫描结束释放 fetch 和索引。权限撤销在刷新/下一次进入、应用重新激活、预览或扫描发现时取消扫描，删除哈希内存与磁盘缓存；删除失败有明确错误，不宣称清除成功。没有后台观察完整图库变更。推荐保留改为**收藏→分辨率→已编辑→更早拍摄→稳定标识**。DuplicateFilesView 持有 StateObject，图库子页用 ObservedObject，切换来源保留完整结果/选择；进行中的扫描仍会取消，不保留未完成结果。

### 旧断言改写

1. `testDuplicateEvidenceLevelsDoNotConfuseMetadataWithContent` 现在为照片显式提供同一可匹配缩略图，原三类证据和组数断言不变；依据 P1-2，不再把无缩略图的元数据桶直接确认成组。
2. 保留排序测试改名为 `testKeeperOrdersFavoriteResolutionEditedEarlierAndStableIdentity`，收藏低分辨率 vs 非收藏高分辨率的期望从 b 改为 a；依据本轮用户明确要求收藏优先。分辨率、编辑、时间及稳定标识的其余断言保留。
3. 删除假对象的恒真删除计数与对应断言；替代依据 P1-3，真实可观察的相册接口四路径与全 Sources 禁用名单。保留初始不选、保留项保护、选择过滤、授权各状态、取消、上限、缓存失效等断言，且新增撤销后磁盘缓存确实消失断言。

### 主会话补充验收

- 先核对新主 App 签名命令仅有这一个 entitlement 文件；与 r3-uninstall 合并时保留其 Finder 扩展的独立签名，不把此 entitlement 加到 helper/扩展。
- 主会话在授权打包后回读主 App `codesign -d --entitlements :- <bundle>`，必须包含照片键 true。最终主 Bundle 用途说明、SecTask 运行时来源可见、真实 TCC 弹窗均须单独验证；不以静态 plist 或本批编译代替。
- 缺用途说明或缺签名 entitlement 的隔离假 Bundle 用纯门禁测试验证；正式版未改发布脚本，本轮不会访问照片，因此不要在正式包强行调用 PhotoKit。正式版启用另开批次。
- 受限授权下只读扫描，加入按钮禁用；去设置改为完整访问后返回 App，授权状态刷新。撤销后返回 App/刷新清除结果与哈希缓存，确认清除失败文案；实机仅在用户明确授权下执行。
- 待删除相册初建后退出再进，应按已保存 ID 复用；出现用户同名相册时，先保存的 ID 仍精确定位，多标题歧义拒绝。单个未知同名相册的复用风险必须在确认文案中可见。实机授权范围只包含用户同意的测试照片，相册成员添加/用户删除/最近删除恢复分别取得授权并按上文步骤执行。

### 修复轮 1 反证准备

`mutations.json` 已同步原 21 条失效 before/过滤方法，新增 14 条，共 **35 条**，Python 确认每条 before 在最终文件逐字只出现一次。新增覆盖 P0-2 用途键和签名门禁、P1-1 张数/时间窗/新→旧、P1-2 缩略图门槛、P1-3 回读/相册标题与 ID 定位/ID 持久化/部分访问/includeHiddenAssets、P1-4 limited 写入；不执行变异，不使用真实图库。

### 修复轮 1 最终验证与剩余限制

- **PASS** 最终 `swift build --disable-sandbox -Xswiftc -disable-sandbox --scratch-path ~/Developer/.sc-build/r3-photos/debug --skip-update --disable-automatic-resolution --manifest-cache local --jobs 3 --build-tests`（相同 DEVELOPER_DIR/LC_ALL），exit **0**，81.56 秒；`logs/repair1-build-latest.log`。SecTask 公共 API 和 PhotoKit placeholder ID 接口均已编译通过。首个修复构建因 placeholder 在当前 SDK 为非可选而多写一个可选链失败（`repair1-build.log`，exit 1），已修正；固定源码后构建 120.55 秒通过，再补激活刷新/预算保留并最终重建通过。没有新生产代码告警，保留 SwiftPM 沙箱缓存与既有测试告警。
- **FAIL / 部分 PASS** 最终五类定向（根据 `targeted-classes.txt`）：`swift test ... --skip-build --filter 'PhotoLibraryTests|PhotoLibraryRepairTests|DuplicateFileScannerTests|UIConsistencyRegressionTests|TestPreferenceHygieneTests'`，exit **1**，**141 项、4 个失败断言、0 跳过**；`logs/repair1-targeted-final.log`。`PhotoLibraryTests` **19/19**、`PhotoLibraryRepairTests` **15/15**、界面一致性 **46/46** 全部通过。20,000 张假数据 **1,277,920 次比较、0.966513041 秒**（测试整体 0.97 秒左右），未截断；比较次数 ≤1,280,000、耗时 <10 秒断言通过。最终源码新增的旧元数据桶不能挤掉最新相似比对预算反例也通过。
- 剩余失败与首轮相同，无新增失败：DuplicateFileScannerTests 40 项/1 失败（APFS 关系期望 apfsClone、得到 independent；相关逻辑未改，根因仍未确定）；TestPreferenceHygieneTests 21 项/3 失败断言、2 方法（308/309/324，同步及 plist 存在；日志仍明确沙箱 Operation not permitted）。本轮未修改这三方法、偏好工厂或 APFS 逻辑，没有放宽、删断言或跳过测试，交主会话按首轮列出的具体方法沙箱外复跑/调查。
- **PASS** `bash -n script/build_and_run.sh`、entitlements 和 en/zh-Hans 两份 `plutil -lint`、`python3 script/check_private_api.py`（7 个原有 allowlisted uses）、`git diff --check`，exit **0**。`mutations.json` 35 条全部 expected_occurrences=1，Python 逐条核对 before 次数及 filter 方法确实存在；变异**未运行**。
- **PASS** 最终 prepared 代码/测试/文档三组；共 **18 个最终文件**，all.patch 反向只读应用检查 exit **0**，源码、产物和辅助清单 SHA-256 已回读核对。生成器/提交脚本 Python 语法检查通过。没有暂存、git 提交、合并或发布。
- **NOT RUN** 真正的主 App 签名回读/TCC、Beta 运行包/安装、真实 PhotoKit 资源/相册、用户照片删除恢复、正式版发布流程、全量/Release 门禁和反证。门禁仍有上述旧失败，不能将准备产物称为已获完整验收。
- **BLOCKED** JEV：本轮核对工具接口后，对 ID/标题复用策略作一次有限判断调用；仍被自动审批以 `MCP tool call requires approval, but approval policy is never` 拒绝，未取得 JEV 判断，没有改用其他第三方模型。实际纠正 entitlement 的依据是 Apple 官方 Hardened Runtime/Photos Library Entitlement 文档及当前 SDK 公共 SecTask 声明，技能只用于签名/权限核对，不授权安装或真实图库访问。

## 修复轮 2（主会话，2026-10-13）

修复轮 1 复核（Claude 子代理）：N-P0-1 `verify_photo_library_entitlement` 用 `plistlib.load(sys.stdin.buffer)` 读管道必然抛 `UnsupportedOperation`，在 `set -euo pipefail` 下所有打包模式都会中止。已改为 `codesign -d --entitlements - --xml` + `plistlib.loads(sys.stdin.buffer.read())`（本机用 Safari.app 实测可解析）。N-P2-2 照片 entitlement 与主 Info.plist 的 `NSPhotoLibraryUsageDescription` 改为仅测试版（`BETA_MODE=1`）加入，run/bundle-only 使用正式 Bundle ID，不再出现照片来源或产生 TCC 记录；空数组在 bash 3.2 `set -u` 下用 `${a[@]+"${a[@]}"}` 展开。N-P2-1 比较预算 2,000,000→3,200,000（≥ 5 万张上限 × 64 张窗口），测试改为断言预算不低于上限×窗口。脚本测试补“helper 签名行不带 entitlements”“回读不用 seek”。反证 35→38 条。定向 PhotoLibraryTests + PhotoLibraryRepairTests 34/0。真实打包回读仍待安装测试版时执行。
未处理（记录）：N-P2-3 扫描中撤销授权显示“已取消”；N-P2-4 `scenePhase` 在 macOS WindowGroup 下的激活刷新需实机确认；跨 64 张/24 小时窗口的相似照片不比较（产品限制）。

## 修复轮 3（Claude 子代理，2026-10-13）

主会话全量验证 `logs/main-final-0138/full.log`：5036 项、6 个失败断言，全部来自 `FeatureLightfieldFilesContractTests.testFourFilePagesKeepSkeletonAcrossThreeStatesSevenWindowsAndTwoSchemes`（215/216 行，title/content 下移 20pt、content 高度少 20pt），无其他失败。

- **根因**：本批在 `DuplicateFilesView.body` 外层改成 `VStack`，相似照片路由在整页上方插入“照片来源”分段 Picker（含 8pt 上下内边距）。即使 `PhotoLibraryAvailability` 为 false（测试 Bundle），Picker 仍以单段渲染，挤占 `FeatureLightfieldPage` 高度，D 锁定骨架整体下移。
- **修复**：去掉页面上方的 Picker，恢复 `Group`；来源切换放入骨架已有槽位，与其他文件页一致——落地页用状态栏 `statusAction`“改用系统照片图库”（FileAnalysis/FileMigration 同模式），结果页放在内容区工具栏“系统照片图库”按钮（与“详情”同排，忙碌时禁用）；两者都经 `systemPhotoLibraryAction` 门控（仅相似照片路由且 `isEnabledInMainBundle`，否则为 nil 不显示）。系统图库页加“改用文件系统图片”返回按钮（尾随闭包，`PhotoLibraryStore` 仍由 `@StateObject` 持有，切换保留结果）。扫描进行中的运行页不提供切换。测试期望值与精度未改。
  - `PhotoLibraryRepairTests.testMissingUsageDescriptionHidesSourceBeforePhotosCalls` 原源码守卫匹配已删除的 Picker 内 `if PhotoLibraryAvailability.isEnabledInMainBundle {`，改为同时守卫新门控 `guard isSimilarPhotosRoute, PhotoLibraryAvailability.isEnabledInMainBundle else { return nil }` 与页面分支条件（断言数 +1，未放宽）。
- **反证 keeper-resolution**：原测试没有“仅分辨率不同”的用例（收藏用例在收藏层已决出），`>`→`<` 存活。新增三条：同条件下 a/b 两种输入顺序均选高分辨率 b（排除稳定标识兜底），以及“已编辑且更早”的低分辨率 a 对未编辑高分辨率 b 仍选 b（分辨率优先于编辑/时间）。
- **反证 cache-date**：`"constant-date"` 让闭包不再引用 `$0` 而编译失败。`mutations.json` 同 id 的 `after` 改为 `String($0.timeIntervalSinceReferenceDate.magnitude * 0)`（恒为 "0.0"，类型匹配，日期失效被禁用）；`before` 不变，38 条均核对 expected_occurrences=1。原文件备份 `mutations.json.bak-repair3`。

### 验证（`~/Developer/.sc-build/r3-photos/logs/repair3/`）

- **PASS** `swift build --build-tests`（规定 DEVELOPER_DIR/LC_ALL 与 scratch/flags）exit 0；`build2.log`、`rebuild.log`。
- **PASS** 定向 `--filter 'PhotoLibraryTests|PhotoLibraryRepairTests|FeatureLightfield|UIConsistencyRegressionTests'`：**216 项 0 失败**（FeatureLightfieldFilesContractTests 7/7 含骨架测试、PhotoLibraryTests 19/19、PhotoLibraryRepairTests 15/15、UIConsistencyRegressionTests 46/46）；`targeted.log`。
- **KILLED** keeper-resolution：构建 0，目标测试 exit 1（102/103/104 行失败）；`mut-keeper-resolution.log`。
- **KILLED** cache-date：构建 0（不再编译失败），目标测试 exit 1（149 行 XCTAssertNil 失败）；`mut-cache-date.log`。
- **PASS** 两次变异后源文件 SHA-256 与变异前一致，`git diff --stat`/`git status` 与变异前一致；重建 exit 0，PhotoLibraryTests 19/19；`git diff --check` exit 0。
- **NOT RUN** 全量测试（交主会话）、App 运行与界面实际视觉核对、真实照片图库。未提交。
