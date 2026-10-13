# 批次 r3-files：容量口径、大文件门槛、本地 AI 模型盘点（D84/D85/D86）

2026-10-12，Claude 子代理（Opus 5.5）实现。基线 `52f722ac`，分支 `task/r3-files`，worktree `~/Developer/sc-worktrees/r3-files`，scratch `~/Developer/.sc-build/r3-files/`。参考 `同类逆向-20261012/腾讯柠檬-5.3.4.md`（P1-3、P2-2）与 `CleanMyMac-5.7.1.md`（本地模型 P2），只借思路，未复制竞品代码（柠檬 GPL）。

## 1. 改动与理由

### D84 容量口径说明（只加说明，不改算法）
- 新增 `Models/StorageCapacityBasis.swift`：四种口径“本地占用（分配大小）”“逻辑大小”“本轮量到的下限”“云端占位（未下载，不占本地）”，以及硬链接、APFS 克隆、稀疏文件、废纸篓说明；`StorageCapacityPresentation` 给出行口径、摘要标签、面包屑说明、行悬停帮助、移到废纸篓完成摘要。
- `DiskScanner.storageMapSizeBasis(path:)`：把原 `storageMapPreferredSize` 里“/Applications 应用包内容取逻辑大小，其他取分配大小”的判断抽出，`storageMapPreferredSize` 改为调用它，返回值与改前逐分支相同（测试覆盖四种组合）。
- 未读入的文件夹（未下载的云端文件夹与被排除/读不出的文件夹在索引中无法区分，`StorageMapIndexedEntry.isCloudOnly` 注释已写明）一律说成“本轮量到的下限”，不猜测为云端；云端占位只用于有大小的未下载文件。
- 文件分析结果页：摘要标签“已分析 · 本地占用”／不完整时“本轮量到的下限”；面包屑说明“按本地占用（分配大小）”／“部分索引 · 本轮量到的下限”；每行大小列悬停显示口径；新增“容量口径”按钮与说明页（`StorageCapacityNotesSheet`）。
- 文件分析移到废纸篓后的状态由“已移走 N 项 · 已选…”改为“已移到废纸篓 N 项 · X（清空废纸篓后才释放） · 已选…”。搬家页原件移废纸篓的提示原本已写“清空废纸篓后才会释放空间”，未改。
- 大文件清单的树测量 `treeSizeMeasurement`：与原 `treeSizeBytes` 相同的走法和超时，另记录是否走完、是否有读不出的子项目；不完整时该行为下限（结果页说明并在大小列悬停标注）。

### D85 大文件门槛三档
- 新增 `Models/LargeFileListing.swift`：`LargeFileThreshold`（50 MiB / 200 MiB 默认 / 1 GiB，二进制字节）与 `LargeFileListingSummary`（门槛、80 条上限、找到数、显示数、时间上限、单文件夹测量上限、下限项目，以及结果页说明文字）。`ScanMode.largeFileMinimumBytes` 改为取默认档，值仍为 200 MiB。
- `DiskScanner`：新增 `largeFileThreshold` 初始化参数（默认 200 MiB）、`largeFileListing(deadline:)`（替代私有 `scanLargeFiles`），`scanChildren` 改为调用新的 `scanChildrenReport` 并只取 entries（读取、跳过、36 项测量上限、每位置 40 条均不变）；`scan()` 把清单摘要写进新的 `ScanResult.largeFileListing`（时间已到、大文件这一步没开始时记为“时间上限”）。
- 排序：改前只按大小降序（同大小顺序未定义），现在同大小按路径，以便测试与显示稳定；其余截断规则不变。
- `LargeFilesStore`：门槛偏好键 `large-files.threshold`（无法识别回到 200 MiB）；新增 `ListingScanOperation` 注入点与 `LargeFileScanOutcome`，旧的 `scanOperation:` 注入仍可用（包装成无摘要结果，现有测试不改）；`listingSummary` 只在成功扫描后替换，取消/失败保留上次。
- 文件搬家起始页（可搬移大文件时）新增“大文件门槛”一行三段选择，悬停写明单位；结果页在目标盘行下显示“门槛 ≥ X · 按本地占用（分配大小）”，截断时加“仅显示前 N 项（共找到 M 项）”“已到扫描时间上限”“部分文件夹只测了前一部分项目”“K 项测量超时，大小为本轮量到的下限”。
- 智能扫描（ScanStore，不属于本批）仍用默认 200 MiB。

### D86 本地 AI 模型只读盘点
- 新增 `Services/LocalModelInventory.swift`：`LocalModelInventoryScanner` 读取 `~/.ollama/models`（manifests 解析模型名、config 读 `model_format`/`file_type`；blobs 只取 lstat 元数据，按本地占用计）与 `~/.lmstudio/models`、`~/.cache/lm-studio/models`（发布者/模型文件夹，按扩展名识别 GGUF、Safetensors、MLX 等；硬链接按 inode 只计一次）。合计按文件身份（设备+inode）去重，共享 blob 只计一次，每个模型分列独占与共享部分及共用模型名。
- 安全处理：任何层级的符号链接都不跟随、不计入，列在“跳过”里；模型根本身是符号链接时报告目标、不读取；两处 LM Studio 根是同一文件夹时不重复计算；清单 JSON 读取上限 1 MiB；digest 必须是 `sha256:` 加 64 位小写十六进制，否则整份清单按“无法识别”保留不计（防止路径拼接越界）；未被引用的 blob、缺失文件分别说明；条目上限 20,000 与取消，结果标为不完整。
- 新增 `Views/FilesLightfield/LocalModelInventoryView.swift`：文件分析结果页“本地 AI 模型”按钮打开的只读页，后台读取一次；显示模型名、来源·格式·文件数、本地占用、共享说明、读取位置状态与“只读盘点：本页不提供删除。删除模型后需要重新下载，且不保证仍能下载到同一版本”。只有右键“在访达中显示”（显式操作）。**不提供删除**。
- 只读确认：本机 `~/.ollama/models`、`~/.lmstudio/models`、`~/.cache/lm-studio/models` 均不存在（仅检查存在与否，未读内容）；测试只用临时目录假家目录。

## 2. 改写的旧断言
无。未修改任何既有测试文件。

## 3. 构建与定向测试（实际运行）
- `swift build --scratch-path ~/Developer/.sc-build/r3-files/debug … --jobs 3 --build-tests`：exit 0（日志 `build-3.log`）。
- 新增类：`StorageCapacityBasisTests` 9、`LargeFileThresholdTests` 8、`LocalModelInventoryTests` 5，连同 `ScanModeTests` 4：26 项全部通过（`test-new.log`）。
- 定向清单 `targeted-classes.txt`（28 类）：530 项，1 跳过（`SystemUtilitySafetyTests.testLiveSetappUninstallInventoryWhenExplicitlyEnabled`，需显式开关，既有），1 失败（`test-targeted-1.log`）：`ConceptLandingNativeLayoutRegressionTests.testEveryLandingPageFitsInTheRealPageContainerAcrossTheSizeSweep` 只报 `devCaches english 655x560…760: final option is unreachable`。开发缓存起始页（`DeveloperCleanupThresholdControl`/`HeroScanPage`）不在本批改动范围；本批改动的 `largeFiles`、`migration` 起始页在同一扫描中均通过。该用例本次耗时 207 s（机器上同时有其他构建）。反证结束、恢复源码重新编译后单独重跑该用例：通过（174.7 s，`test-rerun.log`，同次新增三类 22 项也全部通过），判断为高负载下的不稳定，不是本批引入。
- 本批未跑全量测试和 Release 测试编译（主会话负责）。

## 4. 红 / 绿 / 反证
- 反证清单 `~/Developer/.sc-build/r3-files/counterexamples.json`（17 条，覆盖三项决定的核心行为），运行脚本 `run_cx.py`：逐条替换 → `--build-tests` 编译 → 跑对应 filter → 还原；日志 `counterexamples-run.log`，汇总 `counterexamples-summary.txt`。
- 结果：17/17 RED（替换后都能编译，对应测试失败），每条结束后已还原；脚本结束时 `git status` 只有本交接与 DECISIONS 两份未提交文档，源码与测试无改动。还原后重新编译（`build-4.log`，exit 0）并重跑新增测试全部通过。
  - D85：二进制单位、默认 200 MiB、扫描器使用所选门槛、80 条截断标记、单文件夹测量上限标记、偏好写入、Store 传入所选门槛（7 条）。
  - D84：读不出子项目为下限、应用包逻辑口径、未读入文件夹为下限、云端占位、废纸篓完成摘要（5 条）。
  - D86：共享 blob 只计一次、共享识别、未知/越界清单、模型根符号链接不跟随、条目上限（5 条）。

## 5. 未解决 / 交给其他批次
- `ConceptLandingNativeLayoutRegressionTests` 的 devCaches 英文窄窗：首次定向运行失败、单独重跑通过（见第 3 节），建议主会话全量门禁时留意是否在高负载下复现。
- 其他页面“移入废纸篓”与“已释放”的口径（安全清理、卸载、重复文件完成摘要、概览/菜单栏的清理统计等）不在本批文件内，交 r3-confirm（R3-5）统一；本批粗查源码未发现“已释放”字样，但未逐页审查完成页数字是否把移入废纸篓的容量算成释放。
- 重复文件页“物理可释放”是执行前估算（清空废纸篓后的物理节省），本批未改名；如要统一为“清空后可释放（估）”，需同时更新相关界面断言。
- 大文件清单的文件夹大小逐项测量，同一硬链接数据在两行都会计入（说明里已写明）；APFS 克隆在空间分析与大文件清单中都按各自完整分配计（已写明，测试锁定现状）。如要改算法需另立决定。
- 文件搬家的文件扫描仍走完整 `DiskScanner.scan()`（所有组共用 28 秒），低门槛下更容易碰到时间上限；本批只如实显示，不改扫描范围。
- 本地模型：不读取 `OLLAMA_MODELS` 环境变量或 LM Studio 设置里的自定义下载目录；模型删除计划留给后续批次（需保证仍被其他模型引用的 blob 不删、未知清单与外部路径保留）。
- 新界面元素（门槛行、截断说明行、两个按钮与两张说明页）尚未做实机截图与小窗几何验收。

## 修复轮 1（独立复核意见，2026-10-12）

### 改动
- **P1-1 混合口径**：`StorageCapacityBasis` 新增 `mixedWithAppBundles`“本地占用（应用包按逻辑大小）”。`basis(forMeasuredPath:isDirectory:)` 把 `/`、`/Applications` 及 `/Applications` 下非应用包的文件夹标为混合，`/Applications/X.app` 及其内容仍标为逻辑大小。`summaryBasis/summaryLabel/snapshotNote` 改为带 `path:` 参数，按当前范围/层级取口径：`/` 与 `/Applications` 显示“已分析 · 本地占用（应用包按逻辑大小）”“按本地占用（应用包按逻辑大小）”。行悬停也随之变化。容量口径说明页从 8 段增至 9 段。演示夹具 `FeatureLightfieldFileResultFixture` 的旧标签“已分析总量”改为同一函数。测量算法不变。
- **P2-1**：`Context.isIncomplete` 拆成 `isStopped`（只有条目上限或取消才设置）、`skippedDeepFolders`、`unreadableFolders`。层级过深时只跳过那棵子树，并给出单独提示“N 个文件夹层级过深……其余照常盘点”。`LocalModelInventory.isIncomplete` 改为由这三项合成。
- **P2-2**：`rootState` 从家目录往下逐级 lstat（`~/.ollama`、`~/.lmstudio`、`~/.cache`、`lm-studio`、`models`）。上级是链接时返回新状态 `.linkedAncestor(path:destination:)`，界面显示“上级 X 是符号链接，未跟随”。全部是真实文件夹时，再比对 realpath 前缀作兜底。家目录本身及更上层不检查（例如临时目录 `/var` → `/private/var`）。
- **P2-3**：新增 `readRegularFile(at:byteLimit:)`：`open(O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)` 后用 `fstat` 确认是普通文件且不超过上限，再循环读取。读的过程中文件变长、超过上限就放弃。上限仍是 1 MiB。
- **P2-4**：digest 只接受 ASCII `0-9a-f`（按 UTF-8 字节判断），不再用 `Character.isHexDigit`。
- **P2-5**：每个 LM Studio 发布者文件夹也计一项 `consume()`。停止后 `Context.list` 不再列目录，LM Studio 第二个根和 manifests 遍历也不再开始。列不出的文件夹（含 manifests 子文件夹、读不了的 blobs/manifests 根）记进 `unreadableFolders`，结果标为不完整。
- **P2-6（可选，已做）**：未到结果上限、但碰到时间或文件夹上限时，原措辞“仅显示前 N 项”改为“已显示找到的 N 项，可能还有未测到的”。到结果上限时的措辞不变。
- **P2-7**：`hardLinkNote/cloneNote/sparseNote/trashNote`、`LargeFileThreshold.unitHelp`、`LocalModelInventoryPresentation.readOnlyNote` 由 `static let` 改为计算属性，切换语言后立即跟着变。
- **P2-8**：删除无引用的 `ScanMode.largeFileMinimumBytes`。新增 `L10n.englishCount` 处理英文单复数，本地模型页与大文件说明里的英文计数改用它或 `L10n.items`（不再出现 "1 files"）。

### 改写的旧断言（均为本分支前三个提交里新增的断言，基线断言未动）
- `StorageCapacityBasisTests.testBasisTitlesNameTheFourMeasures`：说明段数 8 → 9，并断言其中包含混合口径。依据：P1-1 新增了一种口径。
- `StorageCapacityBasisTests` 中 `summaryLabel/summaryBasis/snapshotNote` 的调用补上 `path:`（取 fixture 根路径），期望值不变。
- `LargeFileThresholdTests.testThreeBinaryThresholdsWithTheDefaultUnchanged`：`ScanMode.standard.largeFileMinimumBytes == 200 MiB` 改为 `LargeFileThreshold.standard.bytes == 200 MiB`。依据：该属性已删，默认档字节数仍被锁定。

### 新增测试
- `StorageCapacityBasisTests`：`testScopesContainingAppBundlesAreLabelledAsMixed`、`testNotesFollowTheCurrentLanguageAndEnglishCountsArePluralised`（在临时偏好域里先英文后中文切换）。
- `LocalModelInventoryTests`：`testDeepFolderSkipsOnlyThatSubtree`、`testUnreadableManifestFolderAndCancellationStopEarly`、`testIntermediateSymbolicLinkLayersAreNotFollowed`（临时假家目录里 `.ollama/.lmstudio/.cache` 均为链接）、`testRegularFileReadRejectsLinksFifosFoldersAndOversizedFiles`（含 mkfifo），以及 `testNamesDigestsAndReadOnlyPresentation` 里新增的全角 digest 断言。
- 所有夹具都在 `TestFileSystem.uniqueRoot` 临时目录中；没有读真实模型目录。

### 构建与测试（实际运行）
- `swift build … --jobs 3 --build-tests`：exit 0（`build-fix1.log`；反证还原后重建 `build-fix1-restore.log`）。
- 三个直接相关的类：28 项全部通过（`test-fix1-new.log`）。
- 定向清单（28 类，未新增类名）：536 项，1 项跳过，0 失败，跑了两次（`test-fix1-targeted.log`、反证后的 `test-fix1-targeted-2.log`）。跳过的是 `SystemUtilitySafetyTests.testLiveSetappUninstallInventoryWhenExplicitlyEnabled`，需显式开关才运行，跳过属既有情况。本轮没有出现布局类偶发失败。
- 未跑全量测试和 Release 测试编译（主会话负责）。

### 反证
- `counterexamples.json` 由 17 条增至 27 条，修改前的版本备份为 `counterexamples.before-fix1.json`。所有 before 都用 python 校验过出现次数与 `expected_occurrences` 一致。
- 失效条目同步：`d86-root-symlink-not-followed` 原来替换的是 `directoryState` 的链接分支，修复后模型根是否为链接改由逐级检查决定，已把它改指 `rootState` 中最后一层的分支。
- 新增 10 条：P1-1 两条（混合判断、界面传入范围路径），P2-1 一条，P2-2 两条（整个逐级检查、只查最后一层），P2-3 两条（去掉 `O_NOFOLLOW`、去掉 `fstat` 普通文件判断），P2-4 一条，P2-5 两条（停止后仍检查发布者、列目录失败不记录）。
- 本轮亲自跑了以上 10 条加同步的 1 条（`run_cx_subset.py`，日志 `counterexamples-run-fix1.log`）：11/11 RED，每条跑完后还原；重建后定向测试全绿。其余 16 条既有反证的 before 文本仍然存在、出现次数正确，本轮没有重跑。

### 残余
- 混合口径按路径字符串判断（`/`、`/Applications…`）。如果分析范围以 `/System/Volumes/Data` 一类路径表示，其中的应用包本来就按本地占用测量，标签也写本地占用，两者一致。
- `/Applications` 下不含应用包的普通文件夹也会保守地标成混合口径。
- `rootState` 的逐级检查与随后的列目录之间仍有极短的竞态窗口；子文件夹遍历时每一项都会 lstat，文件读取用 `O_NOFOLLOW`，不会跟随链接读取内容。
- P2-7 语言切换没有反证条目（改动跨多行，单处替换不能干净地还原成 `static let`），由新增测试覆盖。
