# P02 · D185 本机云盘文件夹

状态：实现与沙箱内可执行验证已交付；构建 PASS，新增 17 个测试 PASS，原有 21 个测试 PASS、5 个测试因夹具路径权限 BLOCKED（整体测试命令 exit 1，不能算整组通过）。工作目录 `/Users/developer/Developer/sc-worktrees/p02-cloud`；用户交接基线 `2585443c`，未提交、未安装、未部署。只使用当前 Codex；未调用 JEV 或其他外部模型（本批未授权其来源和预算）。

## 文件与作用

- `Sources/StorageCleanerMac/Features/CloudCleanup/CloudDriveScanner.swift`：提供商/账户结构、共同识别、可注入的元数据扫描、逐账户快照；同文件内的 `CloudCleanupModel` 仅在 start 后扫描，汇总进度并原子发布结果，取消保留旧结果，运行 ID 隔离过期回调。
- `Sources/StorageCleanerMac/Features/LargeFiles/Services/CloudLocalCopyService.swift`：在本机 home 的 CloudStorage 普通文件位置扩展 D90；不完整证据降级；第三方只调用一次同一释放 API，并回读一次。
- `Sources/StorageCleanerMac/Views/CareStudio/CareStudioCloudCleanup.swift`：首页账户列表、每账户结果卡片、审阅和访达入口；无 iCloud 但有第三方时也可扫描；共享展示数据供无窗口测试验证中英文。
- `Sources/StorageCleanerMac/Views/FilesLightfield/CloudLocalCopyView.swift`：第三方阻止原因附访达提示；审阅计数统一 `ByteFormat.count`。
- `Sources/StorageCleanerMac/Views/CareStudio/CareStudioJunkResults.swift`：**范围外必要改动**：给现有 `CareStudioTileModel` 增加可选 `appIcon`，并在现有卡片角落渲染。现有 `iconPaths` 通过缓存读应用包资源，不满足本批明确要求的系统图标来源；云盘卡片改传 `NSWorkspace.shared.icon(forFile:)` 返回值，其他调用保持默认 nil。没有新建视觉组件或商标资源。
- `Tests/StorageCleanerMacTests/CloudDriveD185Tests.swift`：新增 17 个无窗口测试，覆盖识别、扫描、取消、资格、回读、中英文与 D178。
- `Tests/StorageCleanerMacTests/CloudLocalCopyTests.swift`：保留 26 个原测试及原方法名，仅修改第三方元数据齐全仍一律拒绝的旧期望，旁注“D185＋旧值”；iCloud 原测试不改。
- 本交接文件。

## 识别与扫描

仅读取 `Library/CloudStorage` 的直接目录名；隐藏项、非目录和链接跳过，不进入账户目录。第一个 `-` 之前匹配 `GoogleDrive`、`OneDrive`、`Dropbox`、`Box`；未知归 other，显示该前缀；第一个 `-` 之后完整保留为账户（包括邮箱、Personal、中文公司名及后续连字符）。同提供商不同根路径单独显示。`externalProviderName` 复用同一解析规则，有一致性测试。

扫描复用 iCloud 同一组七个资源键，不读文件内容、不协调、不下载、不跟随链接。分配大小优先 totalFileAllocatedSize，其次 fileAllocatedSize；状态为 notDownloaded 的文件按逻辑大小计云端，其余有分配块的普通文件计本机。保留最大 200 个文件。每根目录（iCloud 及每个第三方账户）各自最多读取 400,000 项元数据；保留原 iCloud 计数习惯：遇到第 400,001 个停止标记时 inspectedCount 包含该标记，但不再调用注入读取器或对它分类统计（目录枚举器仍按原 iCloud 方式预取资源键）。读失败和目录遍历错误计入 unreadableCount。进度每 400 项及根结束时回调，页面累计各根的检查数；取消不发布本轮部分结果。

## D90 扩展

第三方位置必须是注入/当前 home 的 `Library/CloudStorage/<非隐藏提供商>/...`，文件为无符号链接祖先的普通文件、nlink == 1，具有本机分配块。元数据必须正向报告 isUbiquitous == true、下载状态已知、已上传、无冲突、不在上传/下载、未排除同步、无同步错误；任何字段 nil/unknown 都不可选，显示原“提供商不支持：请在访达中右键选『移除下载』”。已知不安全/未同步状态仍按原 D90 门槛阻止，并在第三方审阅行附访达提示。

执行前沿用服务复查和 Native gate 的再次复查：路径、提供商、设备/inode 身份、mtime/逻辑大小 revision 都应一致。唯一请求是原 `FileManager.evictUbiquitousItem(at:)`。第三方只回读一次；必须同路径、同提供商、同身份、安全、现在是占位符，并且分配块实测下降，才计 releasedBytes。调用失败、回读失败或不满足条件显示：**“这个云盘没有让本应用释放本机副本，请在访达中右键选『移除下载』”**。不重试，不调用其他接口。iCloud 保留原 3 次有界回读和原状态文案。

没有新增删除、移动、内容读取、网络、登录、令牌/账号保存、File Provider 域管理或子进程路径。

## 页面与探针

每账户一张现有网格卡片：提供商与账户、本机分配大小/文件数、云端逻辑大小/文件数、“查看”最大本机文件及“在访达中打开”。首页显示“已在这台 Mac 上设置”。容量均用 storageString，个数均用 count，中文英文均用 L10n.text。iCloud 卡片保持原内容；有第三方时总标题与脚注包含所有云盘。

新增 DEBUG 探针 `careStudio.cloudCleanup.headline`；账户列表和卡片复用现有探针，稳定 ID 为 `careStudio.bullet.provider.<index>`、`careStudio.tile.provider.<index>`。可用注入的 `CloudCleanupModel(home:metadata:itemLimit:)` 和页面 `init(store:model:)` 准备隔离视觉夹具。本批无新增 NSWindow 测试，无 display-bound 清单改动。

## 测试与验证

新增：CloudDriveProviderTests 2、CloudDriveD185Tests 6、CloudLocalCopyD185Tests 7、CloudCleanupD185PresentationTests 2，共 17。原 CloudLocalCopyTests 26，目标共 43。新测试只用工作目录 `.build/d185-fixtures/StorageCleanerMac-Tests-d185-<UUID>` 临时夹具和注入读取器/计数 evictor；UUID 由现有 TestFileSystem 生成，严格 teardown。采用工作目录临时夹具，是因为原 Native gate 会正确拒绝系统 `/var` 符号链接祖先，同时本批沙箱不可写 home 外的操作夹具；未放宽产品路径门槛。

- 窗口登记检查：PASS，exit 0，`.build/d185-evidence/display-bound.log`（63 in-process、1 out-of-process、1 exempt）。
- 删除/进程调用清单：PASS，exit 0，`.build/d185-evidence/deletion-inventory.log`（174 entries、266 uses）。
- 构建：最终 PASS，exit 0，改动文件 0 新增警告。相同构建命令共执行 3 次：首次完整编译 exit 1（`.build/d185-evidence/build.log`，编译期间补入 appIcon 导致部分对象仍引用旧构造签名；未清库/删对象）；固定源码增量重编 exit 0（`build-final.log`，408.38 秒）；发现并修正任务内外层强弱引用警告后小范围复编 exit 0（`build-warning-fix.log`，76.13 秒）。后两次无链接或编译错误。
- 警告：本批弱引用警告已消除，`changed-warnings.log` 记录最终改动文件 0 警告。SwiftPM 用户目录缓存不可写及基线重复 rpath 警告仍在；首次编译还报告未修改的 `Sources/FileOperationShared/UpdateAskpassInvocationRegistry.swift:12/13` 的 withLock 返回值未使用警告（不在给定 baseline-warnings 清单中），未越界修改。
- 过滤测试：实际执行 43 个，38 PASS、5 因沙箱创建夹具失败，整体 exit 1；日志 `.build/d185-evidence/tests.log`。新增四类 17 个均 PASS；原类 21 PASS、5 BLOCKED，无跳过。
- BLOCKED 的 5 个原测试：`testCloudStorageReturnsUnsupportedWithoutReadingSyncMetadata`、`testNativeEvictGateRequiresSameIdentityAndRevision`、`testNativeGateRejectsUnsafeLocalFixtures`、`testNativePlainLocalFileUsesSystemMetadataAndIsNotCloud`、`testOnlyPositivelyIdentifiedICloudLocationsAreSupported`。它们原有 `fixture()` 在 `/Users/developer/.storage-cleaner-cloudcopy-<UUID>` 建根时抛 `NSCocoaErrorDomain Code=513`，底层 `NSPOSIXErrorDomain Code=1 “Operation not permitted”`；尚未执行产品断言。未改旧夹具、未放宽/跳过测试。主会话需在允许该 home 夹具路径的环境重跑同一过滤命令。新增 Native 测试使用本树临时夹具验证了同一门槛，包括 iCloud 正向和缺项/冲突状态。
- `git diff --check -- <本批文件>`：PASS，exit 0，`diff-check.log`；额外检查 Git 初始未跟踪的本批源文件和测试：0 行尾空白，`scoped-whitespace.log`。原测试审计确认 26 个方法保留，只有上述第三方旧期望方法改变，iCloud 原测试未改；`existing-test-audit.log`。
- 新增测试的临时夹具 teardown 后剩余 0 个；未遗留本批用户文件。
- 可选构建进程诊断：BLOCKED，`ps` 被沙箱拒绝，`PermissionError: [Errno 1] Operation not permitted: 'ps'`；未提权或重试，不影响构建日志检查。

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export CLANG_MODULE_CACHE_PATH="$PWD/.build/codex/clang-module-cache"
nice -n 15 swift build --scratch-path .build/codex --build-tests --jobs 4 --disable-sandbox -Xswiftc -disable-sandbox
nice -n 15 swift test --scratch-path .build/codex --skip-build --disable-sandbox -Xswiftc -disable-sandbox \
  --disable-swift-testing --filter '^StorageCleanerMacTests\.(CloudDriveProviderTests|CloudDriveD185Tests|CloudLocalCopyD185Tests|CloudCleanupD185PresentationTests|CloudLocalCopy[A-Za-z]*Tests|CloudCleanup[A-Za-z]*Tests|CloudDrive[A-Za-z]*Tests)'
python3 -B script/display_bound_tests.py --check
python3 -B script/check_deletion_process_inventory.py
```

离线依赖从本机现有 `/Users/developer/Developer/.sc-build/v2.0.1/bootstrap/{checkouts,repositories,artifacts,workspace-state.json}` 复制并重定向到本树 `.build/codex`；没有复制编译对象，也没有联网取依赖。证据目录 `.build/d185-evidence`：修改前文件 `before/`、初始差异 `initial-status.txt`、本批补丁 `scoped.patch`、原测试审计 `existing-test-audit.log` 、`source-sha256.json` 和各验证日志/exit 文件（build.exit=1、build-final.exit=0、build-warning-fix.exit=0、tests.exit=1、display-bound.exit=0、deletion-inventory.exit=0、diff-check.exit=0）。

## 限制与下一步

真实提供商如果不报告任一 D90 同步字段，本应用不能释放该提供商任何本机副本，仍可扫描和在访达检查。最大文件审阅每账户只保留 200 个，扫描大目录可能截断。SDK API 能否被真实 Google Drive/OneDrive/Dropbox 接受未实机验证；本批禁止真实释放和用户文件操作，测试不调用真实 evictUbiquitousItem。窗口视觉验证未在沙箱运行（包括多个账户/窄窗口卡片布局），未新增或启动 NSWindow 测试。主 Agent 复核本批差异后，先重跑上述 5 个因 home 夹具权限被拦截的原测试，再按既有外部窗口流程检查新探针与多账户布局。未安装、未提交，也未在真实云盘上执行扫描或释放。
