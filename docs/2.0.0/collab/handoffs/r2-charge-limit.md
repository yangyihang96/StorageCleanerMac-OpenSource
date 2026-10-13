# r2-charge-limit 交接（2026-10-07）

N25／D59 的代码、测试源码与分组补丁已准备。**构建、原生测试和实机验收均 NOT RUN，不能据此称为修复已验证。** 本轮遵守用户的沙箱边界：不编译、不测试、不提交、不运行探测程序、不写硬件、不安装或启动应用。

基线：`bded4d096576cf1c59f1a1795d2d4a492b2bb42d`；分支：`task/r2-charge-limit`；工作区：`~/Developer/sc-worktrees/r2-charge-limit`。未改 `ScanStore.swift`。改前的 8 个已有文件副本保存在 `~/Developer/.sc-build/r2-charge-limit/source-before/`；准备目录为同批次的 `prepared/`。

## 改动

- `Services/BatteryFullChargeService.swift`：增加实际上限、来源与临时停用标志，保留手动 `target` 与原有可选范围规则。来源优先级为手动启用 → 手动；手动关闭且智能充电值为 1 或最大上限限制为真 → 优化；实际 100% 或无上限读数但明确不受最大上限限制 → 不限；其余未知。缺少手动启用标志时仍返回 nil，绝不把未知手动状态当成 100%。
- 智能充电数值仅认主会话实测的 1（开启）与 3（临时停用）；0、2、其他值与读取失败一律保留未知。来源也可以由独立的实际上限／受限标志确定，未知智能状态不等于“智能充电已关闭”。
- 新读取：`currentChargeLimit:`、`isSmartChargingCurrentlyEnabled:`、`isOBCEngaged:isMaxChargeLimited:chargingOverrideAllowed:withError:`。前两者为 `UInt64` 返回值加错误指针；第三者为 `Bool` 返回值加三个布尔输出及错误指针。沿用 `class_getInstanceMethod` 与 `@convention(c)`；方法缺失、错误或无效上限不填假值。
- 满充按来源选择 `temporarilyDisableSmartCharging:`／`temporarilyDisableMCL:`；旧式优化充电挂起仅在确实挂起且允许覆盖时使用 `temporarilyEnableCharging:`。优化／手动路径不受旧式覆盖许可约束。没有可用路径、方法缺失或完全无验证读数时返回 `.unsupported`，不退到别的写入路径；界面按已知来源解释原因。
- 保留接电、未满、未在充电的既有前置检查。写入返回成功后立即回读，再以 100 ms 间隔最多等 30 次（约 3 秒），以上限 100% 或最大上限受限标志为 false 判定接受。覆盖许可变更、智能状态变成 3、充电电流均不单独作为接受依据；回读失败／超时／等待取消不报成功。
- 引入 `@MainActor BatterySmartChargeClient` 协议与纯值快照。生产入口保留；测试通过内部重载传入假客户端、电池快照、等待闭包及偏好域，不替换全局客户端，也不触发生产单例的懒初始化。
- `Support/BatteryChargeLimitPresentation.swift`：集中中英文实际摘要、手动选项、优化说明、临时状态与不支持原因；语言可显式传入，测试不用写全局语言偏好。
- `Views/MenuBarAdvanced/GeekSensorsPowerHoverDetails.swift`：手动选择器用系统菜单，完整显示“100%（不设手动上限）”；选择 100% 只解除手动限制，不再顺带请求临时满充。优化来源下显示实际值、系统优化说明、满充按钮及电池设置入口。成功或读到智能状态 3 时显示“本次将充到 100%（优化充电已临时暂停）”。电池三级的“目标电量”改为“实际充电上限”。
- `GeekPowerView.swift`：能源摘要改读实际值和来源；电池三级也传实际上限。`ControlPaletteViews.swift`：满充请求结束后只读刷新，立即同步摘要。`MenuBarAdvancedStatusView.swift`：演示夹具补实际值和来源。
- `script/private-api-allowlist.txt`：补四个新增选择子、原遗漏的手动启用相关选择子和 D59／D5 理由，保持四列格式。

## 测试源码与本轮检查

新增 **24 个**测试方法，实际执行 **0 个**：

- `BatteryChargeLimitServiceTests`：18 个方法，含只读矩阵、未知数值和无效读数、优化／手动／旧式挂起路径、实际 100% 或不再受限的回读、许可变化与单独状态 3 的反例、约 3 秒轮询边界、取消、拒绝、方法／读数缺失、前置条件、D5 采样与刷新不写设置，以及手动目标只在回读后保存。
- `BatteryChargeLimitPresentationTests`：6 个方法，含中英文摘要、100% 手动选项、优化说明、重新打开时的临时状态、未知／不支持解释与界面接线。手动选择器不会隐式调用满充的源码契约保留为单独断言。
- `BatteryPresentationTests`：保留既有断言，把唯一写偏好的测试改为临时目录里的绝对路径域。本分支没有 `TestPreferenceDomain`；新测试也用临时绝对路径域并注册清理。
- `GeekSensorsPowerHoverDetailTests`：根据 D59，将现有标签契约中的 `Target Charge` 更新为 `Effective Charge Limit`，保留逐项断言与所有其他断言。未放宽阈值，未跳过或删除测试。

| 检查 | 状态 | 命令／依据 |
|---|---|---|
| 差异空白检查 | PASS，exit 0 | `git diff --check`，只读检查 |
| 工作区范围与基线 | 人工复核 | `git status --short`、`git rev-parse HEAD`、`git diff`；初始工作区干净 |
| Swift 构建／严格并发 | NOT RUN，退出码无 | 用户要求本轮禁止编译 |
| XCTest | NOT RUN，执行 0，退出码无 | 用户要求本轮禁止测试；没有通过／失败／跳过数量 |
| 私有 API 守卫、完整门禁 | NOT RUN | 未执行检查脚本，留给主会话 |
| 实机写入、视觉／交互、性能 | NOT RUN | 不运行 probe，不写充电设置，不安装或启动 |
| Git 暂存／提交／推送 | NOT RUN | `.git` 只读；只生成补丁与提交说明 |
| JEV | BLOCKED | 工具需要审批，而本轮审批策略为 `never`；请求未执行，没有模型判断或模型身份验证 |

本轮仅参考 `probe2.swift`／`probe4.swift` 的源码与用户提供的实测记录；没有编译或运行任何 probe。原生测试结果不能用这份只读源码复核替代。

## 主会话验证

以下为**待执行命令**，本轮没有执行。必须在沙箱外、当前工作区、独立构建目录运行；不加任何绕过沙箱的参数。

```bash
cd /Users/developer/Developer/sc-worktrees/r2-charge-limit
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-debug --jobs 4
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-debug --jobs 4 --filter 'BatteryChargeLimitServiceTests|BatteryChargeLimitPresentationTests|BatteryPresentationTests|GeekSensorsPowerHoverDetailTests|GeekPowerViewTests|ControlPaletteTests'
python3 script/check_private_api.py
```

定向集合通过后，按项目要求由主会话跑完整门禁，保留原有性能阈值：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 \
STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-charge-limit/main-verify \
./script/verify.sh
```

补记命令、退出码、实际测试数量和日志；若编译或测试要求改源码／文档，重新生成 prepared 中的补丁和哈希。已有工作区包含全部改动，不要在这里再次正向应用 `all.patch`。主会话复核、验证后按组提交；提交与安装验收分别记录。

## 主会话实机核对

所有硬件动作只由主会话在用户已授权范围内通过应用点击。先用只读状态记录当前手动开关／手动目标、实际上限、智能状态、最大上限标志、旧式挂起与许可、接电／充电／电量，以及系统设置中的优化充电配置；主会话此前已临时解除过限制，不能假定当前仍停在 80%。

1. **只读与展示**：在接电但暂停充电、低于 100% 的条件下，先只打开、刷新、关闭、重开小窗，确认没有充电设置变化。对照只读实际值：优化来源显示“上限 80%（macOS 优化充电）”，手动目标 100% 的选项仍明确“不设手动上限”，不能出现把实际 80% 说成目标 100% 的摘要。逐项检查中文与英文、窄宽度、日夜配色、菜单的完整选项、说明换行、设置入口和满充按钮均可见可点击；已有面板的自然高度测量承载新增说明，本轮未改其预算。
2. **优化来源满充一次**：MCL 关闭、来源为优化且符合前置条件时，点击“本次充到 100%”。确认走优化临时暂停；在约 3 秒内回读实际上限 100% 或最大上限受限标志 false，显示优化已临时暂停。电流即便十几秒后才上来，也不能误报验证失败。关闭后重开小窗，读到智能状态 3 时仍显示临时状态；确认没有长期关闭系统优化充电。
3. **手动来源满充一次**：明确记录原设置，选系统提供的手动值（例如 80% 或 90%），确认手动启用、摘要来源手动。待接电、未满、未在充电时点一次满充，确认走临时解除手动限制，接受依据同上；手动目标／偏好不应被临时请求改写为 100%。完成后恢复原手动开关和目标，再只读核对实际状态。
4. **旧式优化挂起满充一次**：仅在真机确实报告旧式优化充电挂起且允许覆盖、又不归属前两种上限来源并符合前置条件时点击一次，核对普通覆盖路径与回读。如本机没有这种状态，标 NOT RUN／本机无法复现，不用假实现测试冒充实机验收，也不为制造状态而运行写入 probe。
5. **手动上限切换与恢复**：在已记录原设置后，按系统提供的值切换，例如 100% → 80% → 90% → 100%，每次回读手动启用标志与目标。最后 100% 只关闭手动限制；如果系统优化仍限 80%，摘要和说明继续如实显示，不能把这一选择当成临时满充。结束后恢复最初手动开关／目标，并核对系统优化配置；若系统自己重新启用优化策略，照实记录，不靠后台写入强行恢复。
6. **前置条件与未知**：拔电、正在充电、已满的状态应按既有结果返回；缺少可识别的来源／方法／回读应不写入并说明不支持。系统不提供的路径标明条件不满足，不尝试其他写入选择子。

## 补丁分组与剩余限制

- `01-service.patch`：服务、白名单、18 个假客户端测试、既有偏好测试隔离。
- `02-ui.patch`：本地化出口、四个界面／接线文件、6 个文案／接线测试、既有电池三级标签契约。
- `03-docs.patch`：本交接。每组有对应 `*-message.txt`，含用户指定的两行作者尾注；`all.patch` 是三组的完整总补丁。
- `manifest.json` 记录基线、分支、最终文件 SHA-256 与组顺序；主会话用 `commit-prepared.py` 前仍须完成验证。本轮没有执行该脚本。

未解决的是**验证边界**：尚无 Swift 编译／严格并发结果；假实现不能验证私有接口在其他机型或系统上的 ABI 与行为；本机是否能复现旧式挂起未知；新增长说明的实际菜单／面板布局、性能与真实回读延迟尚未验收。长期关闭优化充电仍由用户在系统设置操作；未增加后台解除或自动恢复策略。暂无另一个已确认但未实现的 D59 代码需求，仍需主会话复核才能确认完整性。

## 主会话验证结果（2026-10-07 20:15）

上面“主会话验证”一节是 Codex 留下的待办；以下是主会话在沙箱外的实际结果。

- **提交**：Codex 三组按 `prepared/commit-prepared.py` 提交（`0c79eb4` 服务、`23c99d6` 界面、`f0fe47a` 交接），脚本的基线与文件哈希校验通过。随后合入集成分支 `73bed27`（`7fcd6eb`）：`BatteryPresentationTests` 冲突取集成分支的 `TestPreferenceDomain` 版本。
- **主会话小修**：
  - `bf3480a`：本批写于测试卫生合并之前，新测试自建的临时绝对路径域改用 `TestPreferenceDomain.make(for:)`；白名单理由改回英文，与其他行一致。
  - `669f636`：说明里引用按钮名的引号改为界面通用的“”，同步两条文案断言（文字内容不变）。
- **构建**：`swift build --build-tests`（scratch `main-debug`，离线参数）exit 0；改动文件无警告。
- **定向测试**（10 个类：`BatteryChargeLimitPresentationTests`、`BatteryChargeLimitServiceTests`、`BatteryPresentationTests`、`GeekSensorsPowerHoverDetailTests`、`GeekPowerViewTests`、`ControlPaletteTests`、`TestPreferenceHygieneTests`、`MiniWindowDemoDataTests`、`GeekHoverDetailTargetTests`、`MenuBarTertiaryDetailTests`）：
  - 合并后首轮 174 个，0 失败，exit 0；
  - 小修后复跑 174 个，0 失败，exit 0；
  - 新增 24 个全部执行：服务 18 个，文案与接线 6 个。
- **私有接口守卫**：`python3 script/check_private_api.py` → passed（6 allowlisted uses），exit 0。
- **反证**：用 `rp.py` 改回旧行为，每轮后 `git checkout -- Sources` 还原。只跑两个新测试类，共 24 个。
  - A：优化来源满充改回“须允许覆盖”，并让选择器选 100% 时顺带满充 → 6 个方法失败，含 `testOptimizedFullChargeIgnoresLegacyOverridePermissionAndWaitsForReadback`、`testUIUsesSharedSummaryAndPickerNeverRequestsTemporaryFullCharge`。
  - B：去掉优化来源判定 → 6 个方法失败，含 `testReadOnlyStateMatrixSeparatesEffectiveAndManualLimits`。
  - C：满充接受判定改为恒真 → 5 个方法失败，含 `testOverridePermissionChangeAloneDoesNotConfirmFullCharge`、`testTemporarySmartStateAloneDoesNotConfirmFullCharge`、`testMissingReadbackAfterWriteIsNotSuccess`。
  - 还原后工作区干净。
- **未运行**：
  - 完整门禁与严格并发：合并后在集成分支统一跑；
  - 实机验收：安装测试版前先问用户，硬件写入只按用户授权做；
  - 日志在 `~/Developer/.sc-build/r2-charge-limit/logs/`（`main-build-1`、`main-test-1/2`、`rp-A/B/C`）。

## 第 2 轮（复核修复，2026-10-07）

本节接续基线 `0852725`（分支 `task/r2-charge-limit`），以 D59 复核补充⑤–⑧及 `review-1.md` 为规格；前面第 1 轮的来源规则、回读成功规则和界面说明以本节为准。第 1 轮主会话的 174 个通过结果仅覆盖当时版本，**不证明本轮修改通过**。

本轮已写代码、测试源码、交接和补丁包。**Swift 构建、严格并发、XCTest、私有接口守卫、实机读写、视觉验收、安装、Git 提交均 NOT RUN；原生测试实际执行 0 个。** 未改 `ScanStore.swift`，未修改 `.git`，未启动应用或探针，未访问凭证。只读参考了复核证据的崩溃替身、假客户端探针及文字测宽源码／输出，没有编译或运行它们。11 个已有文件的改前副本在 `~/Developer/.sc-build/r2-charge-limit/source-before-r2/`。

### 各项修复与数据流

| 复核项 | 本轮实现 |
| --- | --- |
| P1-1 错误回写崩溃、D59⑤ | `BatteryFullChargeService.swift` 内抽出 `@MainActor BatteryChargeLimitObjCCalls`，用任意对象和选择子名查询 IMP。六种带错误参数的 C 类型（无符号值、单字节、对象列表、设置单字节、布尔操作、三个布尔输出）全部用 `AutoreleasingUnsafeMutablePointer<AnyObject?>`；包括旧 MCL 的 `getMCLLimitWithError:`、`availableChargeLimitsWithError:`、`setMCLLimit:error:`，没有遗漏。三个布尔输出仍是普通 `ObjCBool` 指针。生产客户端调用同一助手，方法缺失或回写错误失败关闭。替身覆盖 12 个实际错误选择子，每个在 50 个独立自动释放池中调用；不接触 PowerUI。 |
| P1-1 扩大读取范围、P2 主线程开销、D59⑤ | 服务在创建 PowerUI 客户端之前检查内置电池与演示／夹具状态；不支持手动上限时不调用 MCL 读取，仍可显示系统提供的实际优化上限，手动选择项为空。新增 `BatteryChargeLimitReadCache`，时钟默认系统单调时间，可注入假时钟；包括失败读数在内的可见采样每 30 秒最多读一次，隐藏面板只保留缓存。面板打开与用户操作后绕过节流。`recordBatterySample`、两处打开面板 task、设置手动上限和满充后的刷新全部核对并接入。 |
| P2 手动与优化并存、D59⑥ | 新增 `.manualAndOptimized`。手动开启且实际低于手动目标、智能值为 1 时判两者；实际等于目标或实际 100 且目标低于 100 时判手动。手动关闭且受限为真，或智能 1 且实际低于 100 时判优化。智能 1／100／未受限判不限。100／受限矛盾先判未知，满充写入前失败关闭。未定义数值不猜测。 |
| P1-2 回读不变也成功、D59⑦ | 新增 `.noActiveLimit`，已解除上限时不写。旧式挂起独立检查挂起／许可转变，不能以“maxLimited 本来为 false”报成功。上限路径要求写前有生效限制，写后实际 100 且受限不为真；两项都有时必须同时一致，只有一项时按该项判断。每次写入立即回读，再最多 30 次 100 ms 等待；不以电流或单独智能值 3 判成功。 |
| P2 两种限制的满充顺序、D59⑦ | 手动／两者先临时解除手动；第一步回读成功就停止。第一步最多约 3 秒后仍有限制且智能值为 1，才按需暂停优化充电；第二步也最多约 3 秒。优化来源只暂停优化；旧式挂起且允许覆盖、又不属上限来源才走旧式覆盖。任一步被拒绝立即返回 `.rejected`，不继续；取消、未知、矛盾、方法缺失均不退到其他写入路径。UI 在拒绝和验证失败后也立即只读刷新。 |
| P2 卡片截断及无值显示、D59⑧ | 能源卡片用 `cardSummary`：只显示“上限 80%”／“Limit 80%”或“无充电上限”／“No charge limit”，不拼接来源或模式名称；没有可展示的充电读数时只保留原能源模式项。来源留在调板，含手动＋优化的中英文。测宽测试沿用证据里的 11 pt semibold 字体和 264 pt 页宽，标题、内边距、间距照原计算（旧证据：中文可用 180 pt，英文 142 pt）。本轮文字宽度尚未实际测量，不能把测试源码称为测量通过。 |
| P2 临时满充显示、R7、D59⑧ | 只读状态导出智能值 3、或手动开启／目标低于 100／实际 100／未矛盾的临时解除。即使 `acceptedSource=nil`、关闭重开仍能显示“本次将充到 100%（优化充电已临时暂停）”或“本次将充到 100%（手动上限已临时解除）”；临时状态下隐藏满充按钮。抽出纯函数 `retainedAcceptedSource`，限制恢复、优化恢复、未知或读失败时清除记忆；请求进行中保持。测试也锁定视图 onChange 实际调用此函数。 |
| P2 说明和按钮不一致、D59⑧ | 说明按供电与按钮可用性分支：接电且可用时提示点按钮；使用电池时提示接上电源后再点；接电但按钮禁用或隐藏时不提示点击。智能 1／100／不限写“macOS 优化充电已开启，目前没有限制。”，不写“另设上限 100%”；英文补 `of`。按钮随供电状态禁用，不保留成功后的可点击满充入口。 |
| P2 改上限失败遮住摘要 | 失败提示与实际摘要使用两个独立 Text；失败提示保留，摘要仍同步。设置手动上限失败、拒绝也刷新，不再只在 `.applied` 时读。 |
| P2 测试缺口 R11 | 手动开关的 `decodeManualEnabled` 是纯函数，只认 0／1，nil、2、3、4、255、最大值都未知；生产 MCL 读取调用该函数，另有接线契约，不能只测一个生产不用的函数。 |
| 演示／夹具真实服务连接、D59⑧ | `BatteryChargeLimitAccess` 识别 `MiniWindowDemoData.isEnabled` 与菜单栏捕获参数（directory、scenario、power、power-mode）。调板还识别 `fanControl.isDataOnlyFixture`，在初始化时向采样状态登记，先于 task／异步采样。选择器与满充按钮禁用，事件处理与 task 也拦截；`MenuBarAdvancedStatusView` 的电源快照夹具明确禁用充电控件，回调为不支持。 |
| P2 高度 | `docs/mini-window-design.md` 只有风扇高度预算，没有电源调板预算，因此不凭空增加或放宽阈值。复核第 1 轮实测为中文 248→294 pt、英文 248→322 pt。本轮新增电源布局测试，覆盖中英文、深浅色、优化／手动／两者／电池供电／两种临时状态／无读数，量自然高度并检查窗口尺寸与屏幕容纳，不固定成旧 248 pt。修复后的实测高度 **NOT RUN**，须由主会话记录日志及截图。 |

私有选择子清单没有新增；助手仍留在已有白名单对应的服务文件，`script/private-api-allowlist.txt` 保持原样（四列与英文理由不变）。

### 改写的旧断言（不删除方法、不放宽阈值）

| 原测试／断言 | 本轮改写 | 依据 |
| --- | --- | --- |
| `BatteryChargeLimitServiceTests.testReadOnlyStateMatrixSeparatesEffectiveAndManualLimits`：手动 90、实际 85、智能 1 的来源为 `.manual` | 同一个矩阵行改为 `.manualAndOptimized`；目标、实际值、选项顺序、智能临时状态的断言不变，新增同值手动／不限／矛盾行 | D59⑥、用户确认 powerd 两策略并存 |
| `testLegacyPauseRequiresBothEngagementAndPermission`：固定回读不变、挂起和许可都为真却预期 `.accepted` | 此组合改预期 `.verificationFailed`；其余没有可覆盖挂起而 `maxLimited=false` 的组合改为 `.noActiveLimit`；操作选择与不写的原断言保留 | D59⑦，旧式路径必须挂起或覆盖许可由真变假；已经没有生效上限不能写 |
| `BatteryChargeLimitPresentationTests.testOptimizedExplanationDistinguishesTemporaryAndPermanentControls`：英文 `sets a separate limit 80%` | 精确断言补为 `sets a separate limit of 80%`；中文、未知值及其他来源的 nil 断言保留 | D59⑧及复核语法问题 |
| `testTemporaryStatusSurvivesReopeningFromReadOnlyState`：实际 80、仅视图记忆为优化即可显示将充到 100% | 同一成功断言的夹具改为已回读不限 100；新增实际 80＋旧记忆必须为 nil 的断言。原智能临时状态／无记忆成功断言仍保留 | D59⑦⑧，成功记忆不能盖过当前限制 |
| 同一测试：手动满充中文／英文只有“本次将充到 100%”／`Charging to 100% this time` | 两条精确断言改为包含“手动上限已临时解除”／`manual limit temporarily lifted`，夹具显式提供只读临时标志 | D59⑧，区分两种临时解除 |
| `testUIUsesSharedSummaryAndPickerNeverRequestsTemporaryFullCharge`：说明函数无供电／可用性参数 | 接线断言改为供电与按钮状态参数；保留选择器只调用 `setChargeTarget`、从不请求临时满充的断言 | D59⑧ |
| 同一测试：`if showsFullChargeAction` 与 `.disabled(isRequesting)` | 分别改为同时排除临时状态、使用 `canRequestFullCharge`；新契约覆盖演示、供电和事件入口的拦截 | D59⑧ |
| 同一测试：能源卡片调用完整 `summary` | 改为 `cardSummary`；三级实际值及“不显示 target.displayText”的断言保留 | D59⑧、264 pt 截断证据 |
| 同一测试：满充后无参数刷新 | 改为 `refreshBatteryChargeLimitState(reason: .userOperation)` 的精确接线 | D59⑤，操作后立即读 |

保留原 `testEffective100OrUnlimitedFlagIsEnoughWithoutChargingCurrent`：它的两个成功夹具分别只有实际值、只有受限标志，仍符合 D59⑦的单读数规则；没有把“双读数矛盾也成功”写进该断言。所有其他既有断言均保留。本轮源码新增 **24 个**测试方法：服务 10、文案／接线 5、错误调用 3、读取缓存 5、电源高度 1；执行 **0 个**。原服务 18、文案 6、ControlPalette 44 个方法全部保留。

### 主会话验证（以下命令本轮均未执行）

在沙箱外使用本 worktree 与独立 scratch，先构建测试目标以检查访问级别、`@MainActor` 与 Swift 6：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-charge-limit
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --build-tests --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-r2-debug --jobs 4
swift test --skip-build --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-r2-debug --filter 'BatteryChargeLimitObjCCallTests/testNSErrorWritebackSurvivesAutoreleasePoolsForEveryErrorABI'
swift test --skip-build --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-r2-debug --filter 'BatteryChargeLimitServiceTests|BatteryChargeLimitPresentationTests|BatteryChargeLimitObjCCallTests|BatteryChargeLimitReadCacheTests|BatteryPresentationTests|GeekSensorsPowerHoverDetailTests|GeekPowerViewTests|ControlPaletteTests|TestPreferenceHygieneTests|MiniWindowDemoDataTests|GeekHoverDetailTargetTests|MenuBarTertiaryDetailTests'
python3 script/check_private_api.py
```

布局与卡片测宽建议单独留日志，可用 `STORAGE_CLEANER_LAYOUT_EVIDENCE` 收集布局 PNG：

```bash
STORAGE_CLEANER_LAYOUT_EVIDENCE=/Users/developer/Developer/.sc-build/r2-charge-limit/main-r2-layout \
swift test --skip-build --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-r2-debug \
  --filter 'ControlPaletteTests/testPowerPaletteFitsMeasuredNaturalHeightInBothLanguages|BatteryChargeLimitPresentationTests/testShortCardSummaryHidesMissingStateAndFits264PointPageInBothLanguages'
```

测试仅调用假客户端／Swift 替身，布局只构造内容和不写入的闭包，不启动应用、不走真实 PowerUI。上面的测试命令不会替代实机验收。

**红／绿与反证**：主会话另建隔离副本和独立 scratch，一次只改一个反证；不要在共享集成工作区做全目录 checkout 或覆盖其他改动。建议记录命令、退出码、失败方法和还原后的绿色结果：

- **红（P1-1）**：在本轮助手的六个 C 类型里把错误参数临时改回普通 `UnsafeMutablePointer<AnyObject?>`，只跑自动释放池测试。预期是测试进程崩溃／非零退出，而不是普通断言失败。保留僵尸诊断和 Debug、Release 两种构建结果；不运行复核目录的探针。恢复后同一测试应正常结束、50 次循环全部通过。
- **P1-2 反证**：把一致成功条件改回 `effectiveLimit == 100 || maxLimited == false`，或取消写前／旧式转变检查。矛盾回读、旧式挂起不变、智能 1／100 挂起不变、已不限不写的测试应失败。
- **并存顺序反证**：去掉第二步、颠倒写入顺序、第一步已成功仍写第二步、被拒绝后继续，都应由操作序列、读次数及结果断言抓住。两步都回读不变应在两个窗口后验证失败。
- **读取反证**：把 30 秒改短、移除隐藏／无电池／只读模式守卫、操作后不刷新，假时钟和源码接线应失败。
- **R7**：让 `retainedAcceptedSource` 永远保留记忆，或让 `onChange(chargeLimitState)` 不调用它；清除矩阵和接线契约应失败。
- **R11**：让解码函数认“非零即开”，或让生产读取绕过该函数；解码矩阵和生产调用契约应失败。
- **UI 反证**：卡片改回完整来源／追加能源模式名称、nil 显示未知、临时状态重新显示满充按钮、失败 Text 取代摘要、演示控件或事件入口解除拦截，短文案／测宽／接线应失败。自然高度测试不取代逐张截图核对。

定向绿色后由主会话在集成分支跑完整门禁，保持已有性能阈值：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 \
STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-charge-limit/main-r2-verify \
./script/verify.sh
```

### 主会话实机核对与授权边界

先只读记录当前系统与手动配置，不假定前次临时暂停还在生效。**每次写入前都须获得用户针对该次动作的同意**，包括设置手动值、点击满充、第二个优化暂停动作及恢复配置；在用户同意一次“手动＋优化的按需两步满充”时，须预先说明可能执行两个临时动作及不满足条件时停止。不得把本轮代码任务或过去探测授权当成新的硬件写入授权。没有满足条件的真实状态，记 NOT RUN，不用探针制造。

1. **纯只读、节流、界面**：只打开／刷新／关闭／重开面板；记录打开读、操作后读、可见 30 秒边界与隐藏不读。没有电池的设备不创建客户端；演示参数、捕获参数和只读夹具控件禁用，事件入口也不能连 PowerUI。264 pt 电源详情页与 280 pt 调板分别核对中英文、深浅色、无值隐藏、完整来源、实际摘要、按钮／说明一致、两行失败提示；保存电源自然高度日志和截图。只读动作不能改变任何充电设置。
2. **优化来源满充一次**：手动关闭、实际低于 100 且智能 1／受限为真，接电、未满、未充电；取得本次同意后点满充。只写暂停优化充电；约 3 秒内回读上限为 100 且受限不为真，出现优化临时暂停文字并隐藏按钮。电流晚十几秒开始不作为失败依据，重开仍能从读数恢复提示。
3. **手动来源满充一次**：记录与设置手动目标各自征得同意，实际等于目标、来源手动；取得本次满充同意后点一次。先解除手动，已回读到 100 就不再写优化暂停；手动目标不改成 100。重开后从只读状态显示手动临时解除。恢复原设置前另取同意。
4. **手动＋优化满充一次**：来源应由“实际低于手动目标且智能 1”确认（本机手动 80 与优化 80 虽可两策略并存，但按 D59⑥同值仍标手动；要区分两者需实际低于目标的真实状态）。取得涵盖两步的同意后点一次；核对先解除手动，若仍受优化限制且智能为 1，才暂停优化，约每步 3 秒；第一步已到 100 时第二步必须不执行。任一步拒绝停止，界面即刻只读更新，不假报接受。恢复设置前另取同意。
5. **旧式／无生效限制**：确有旧式挂起且允许覆盖才在同意后核对该路径；须记录挂起或覆盖许可真→假。智能 1／100／未受限且没有挂起时不要写，返回“当前没有生效的充电上限，无需解除。”。矛盾或未知读数失败关闭，不试写别的接口。

### 补丁、静态检查与未解决问题

`~/Developer/.sc-build/r2-charge-limit/prepared-r2/`：

- `01-service.patch`：服务、错误调用替身测试、来源／转变／并存序列测试。
- `02-read-policy.patch`：可注入时钟缓存、采样接线与读取策略测试。
- `03-ui.patch`：中英文文案、两处面板打开／操作接线、临时状态和演示夹具拦截、卡片与自然高度测试。
- `04-docs.patch`：本交接追加。每组配 `*-message.txt`，末尾使用用户指定的 `Generated-By` 与 `Co-Authored-By` 两行。
- `all.patch`、`manifest.json`、`commit-prepared.py`、`README.md`、`static-checks.json`：manifest 的基线写 `0852725`，记录所有最终文件及准备产物的 SHA-256。提交脚本兼容短基线，在真实 HEAD 上展开比对，只在主会话完成验证后运行；本轮未执行。

已有 worktree 包含全部修改，不要再次正向应用 `all.patch`。主会话修改任何源码或文档后须重生补丁与哈希。脚本只按组暂存／提交，不安装、不推送、不替代验证；组间提交不是独立构建验收节点，四组最终状态一起验证。

本轮只做只读差异／范围核对和准备产物一致性核对，详情及退出码在 `prepared-r2/static-checks.json`；不把这些核对称为 XCTest 或编译通过。

未解决／未验证：Swift 6 编译与严格并发、NSError 替身的真实红／绿结果、所有定向与完整门禁、其他机型 SPI 行为、修复后文字宽度和电源高度、真实 XPC 延迟／拒绝处理与实机视觉交互，均留待主会话执行。可见读取仍在主线程同步调用，调用频率已限制，但单次 XPC 阻塞耗时尚未实测；本轮没有宣称消除该延迟。没有另一个已确认而主动留着的复核代码项。

JEV：调用前查到可用 `jev_decide` 参数没有模型选择字段，因此没有擅自设置或更换模型。请求实际被审批策略 `never` 拦截（`MCP tool call requires approval, but approval policy is never`），**BLOCKED**；没有执行模型请求，没有 JEV 判断，也没有实际模型身份回执。按用户约束未绕过沙箱或审批。

## 主会话验证结果（第 2 轮，2026-10-07 21:2x）

- **提交**：Codex 四组按 `prepared-r2/commit-prepared.py` 提交，哈希校验通过：
  - `0f9dfd9` 服务；
  - `cb8cc6e` 读取节流；
  - `85bae21` 界面；
  - `8ab880a` 交接。
- **构建**：`swift build --build-tests`（scratch `main-debug`）一次通过，exit 0。
- **首轮定向测试**：198 个，2 处失败，都在新加的 `ControlPaletteTests.testPowerPaletteFitsMeasuredNaturalHeightInBothLanguages`。另有 3 个“mutated after capture by sendable closure”警告。
- **主会话修正**（`0e56f5c`，只改测试）：
  - 测试里手搭的调板内容没有观察 `ControlPalettePresentationState`，切到电源页后不会重新测量，高度一直为空。改为像 `ControlPaletteRootView` 一样观察。
  - 时钟改放主线程隔离的引用盒，消除警告。
  - 修正后电源调板实测自然高度：中文 240–294 pt，英文 248–336 pt（“手动＋优化”英文最高）。
- **复跑**：12 个类共 198 个，0 失败，exit 0。`check_private_api.py` passed（6 allowlisted uses）；`git diff --check` exit 0。
- **反证**（`rp2.py`，每轮后 `git checkout -- Sources` 还原，工作区干净）：
  - E：错误参数改回 `UnsafeMutablePointer<AnyObject?>` → `BatteryChargeLimitObjCCallTests` 在 `testNSErrorWritebackSurvivesAutoreleasePoolsForEveryErrorABI` 测试进程崩溃，exit 1。这就是 P1-1 的崩溃。
  - F：接受判定不比较写前状态 → 3 个方法失败（`testContradictoryLimitFailsClosedBeforeAndAfterWriting`、`testLegacyPauseRequiresBothEngagementAndPermission`、`testReviewUnchangedSmartOneAt100DoesNotUseSmartOverride`）。
  - G：可见时取消 30 秒节流 → 2 个方法失败。
  - H：手动开关“非零即开” → `testManualEnabledDecoderRecognizesOnlyZeroAndOne` 失败。
- **未运行**：完整门禁、严格并发、实机。实机按来源各点一次满充，每次写入前问用户。


## 第 3 轮（增量复核修复）

本节以 `eead0da58478532e8bf3e8fb94e0492fc6155280`（短基线 `eead0da`）为基线，分支仍为 `task/r2-charge-limit`，根据 `review-2.md` 的 N1–N7 和主会话本次裁定修复。D59⑧ 的卡片规则按本轮裁定解释为“模式 · 短上限”；前两轮把模式去掉的实现、对应旧断言与反证建议由本节取代。前轮 198 个通过结果不代表本轮已验证。

**本轮仅完成源码、测试源码、交接和补丁准备。Swift 构建、严格并发、XCTest、私有接口守卫、完整门禁、红／绿、反证、测宽程序、原生布局、硬件、安装、启动、Git 暂存／提交均 NOT RUN；原生测试实际执行 0 个。** 没有运行复核探针，没有调用真实 PowerUI，没有改 `ScanStore.swift`、私有 API 白名单、偏好配置或 `.git`。12 个目标文件的改前副本保存在 `~/Developer/.sc-build/r2-charge-limit/source-before-r3/`，准备产物在 `prepared-r3/`。

阅读了 D59（含⑤–⑧）、D5、D57 电池与无值规则、D48、交接前两轮及主会话结果。当前基线的 `docs/2.0.0/collab/DECISIONS.md` **未找到 D60**（检索 `D60` 无命中），未推测其内容；本轮按用户明确给出的七项裁定实现。若主会话另有 D60 正文，应在接续时核对是否影响本轮结果。

### 七项修复与涉及文件

| 项 | 实现与数据流 |
| --- | --- |
| N1 模式与短上限 | `BatteryChargeLimitPresentation.energyModeCardTitle` 统一输出当前模式与短上限；英文自动模式用 `Auto`，不限短摘要用 `No limit`，中文用“无上限”。`GeekPowerView.geekPowerModeTitle` 接当前电源对应的模式与实际上限，悬停继续复用同一标题。上限未知时保留已知模式，不编造未知模式。扩展原测宽测试，按复核 `measure2.swift` 的 11 pt semibold、向上取整及原 264 pt 扣除边距／标题／间隔的方法，测所有三种模式、70/80/85/90/95、不限、两种临时状态的完整组合。仍保留短摘要无来源与无值隐藏断言。 |
| N2 没有手动选项 | `GeekChargeTargetSetting` 仅在 `availableTargets` 非空时创建 Picker，其余情况显示“本机不支持手动上限”／`Manual limit not supported on this Mac`，不生成回退选择项。实际摘要、优化说明、临时状态、满充按钮与设置入口均在该分支之外。高度测试新增系统优化 80、手动选项为空的夹具；原有有值／nil 夹具保留。 |
| N3 显示需求 | `MenuBarAuxiliaryMonitorDemand.needsChargeLimit` 默认 false，合并消费者时取任一为真。显式刷新与电池采样中的可见判断都改为 `!isPaused && combinedDemand.needsChargeLimit`。只有显示上限的电源页置位；电源调板独立用 UUID 在其 task 中通过现有 `updateConsumer` 登记、消失时移除，避免父页切换导致调板丢失需求，也不改全局暂停状态。简单面板、性能基准页沿用默认 false。30 秒节流、打开／操作后的立即只读回读、无电池／只读夹具守卫保持。 |
| N4 并存首步不等待 | `BatteryFullChargeService.requestToFull` 仅在写前来源为 `.manualAndOptimized` 时，在解除手动请求后立即读一次，再按该读数决定是否暂停优化；已满足转变则直接成功，未知／矛盾／智能非 1 不继续。`.manual` 仍保留原有首步 30 次等待。第二步仍调用原 `verifyTransition`，比较第二步写前与写后状态，最多等待 30 个 100 ms 间隔；成功／矛盾标准未放宽。 |
| N5 临时摘要 | 读到优化临时停用或手动临时解除标志时，短卡片为“本次充满”／`Full this time`，模式组合例如“自动 · 本次充满”。调板摘要为“本次充到 100%”／`Charging to 100% this time`，详细临时说明仍保留。所选手动目标保持原值，不把临时状态说成长期无上限或新设手动 100%。 |
| N6 部分完成后拒绝 | 新增 `.optimizedChargingRejectedAfterManualLift(effectiveLimit:)`。首步接口返回 true、第二步被拒时，仅补一次只读回读，将当时实际上限带入结果；第一步被拒仍为普通 `.rejected`。提示说明已临时解除手动，但 macOS 拒绝暂停优化；限制为 80/85 等时使用新回读值，100 时只说明当前回读，读失败时说明未能确认，绝不代用请求前的 80%。仍非 `.accepted`，提示保留打开电池设置入口，`ControlPaletteViews` 原有任意结果后的 `.userOperation` 只读刷新继续执行。首步返回 true 是已完成接口调用的证据，不能据此称整次满充已通过最终验证。 |
| N7 代表性与请求高度 | 主会话自然高度测试的选项改为 `[80, 90, 100]`，手动＋优化夹具仍为目标 90、实际 80，并新增有选项时目标必须包含在选项里的断言。优化说明依据不含 `isRequesting` 的 `isFullChargeActionAvailable`，请求期间保留原“请点…”句子；按钮另以 `canRequestFullCharge = isFullChargeActionAvailable && !isRequesting` 禁用。移除请求时额外插入的进度行，不增加高度。 |

### 依裁定改写的旧断言（逐条）

没有删除测试方法、跳过测试或放宽阈值。以下仅替换被本轮裁定取代的期望，其余既有断言保留；新增断言另外加强模式、需求合并、动作顺序、回读次数和目标有效性。

1. `BatteryChargeLimitPresentationTests.testUIUsesSharedSummaryAndPickerNeverRequestsTemporaryFullCharge`：说明接线字符串 `canRequestFullCharge: canRequestFullCharge` → `canRequestFullCharge: isFullChargeActionAvailable`（N7）；满充按钮仍断言 `.disabled(!canRequestFullCharge)`。
2. 同一方法：卡片接线 `BatteryChargeLimitPresentation.cardSummary(batteryChargeLimitState)` → `BatteryChargeLimitPresentation.energyModeCardTitle(`（N1）；短摘要出口保留、由新组合出口调用。
3. 同一方法：`title.contains("return summary")` → 必须传入 `mode: geekCurrentPowerMode, state: hasInternalBattery ? batteryChargeLimitState : nil`（N1），不再把“无模式”当卡片契约；`joined`、`values.append`、实际值而非手动目标等旧断言保留。
4. `testShortCardSummaryHidesMissingStateAndFits264PointPageInBothLanguages`：不限期望“无充电上限”／`No charge limit` → “无上限”／`No limit`（N1）。原有 `width(text) <= room` 不变，另加完整模式组合的同阈值断言；没有扩大可用宽度或缩小测试字体。
5. `testDemoFixturesDisableControlsAndFailureKeepsSeparateSummaryLine`：旧单条 `.disabled(!controlsEnabled || isRequesting || chargeLimitState?.availableTargets.isEmpty != false)` → `.disabled(!controlsEnabled || isRequesting)`，并新增 `if chargeLimitState?.availableTargets.isEmpty == false` 断言（N2）；空选项现在不创建控件，演示和请求禁用仍受断言约束。
6. `BatteryChargeLimitReadCacheTests.testProductionEntryChecksBatteryBeforeCreatingClientAndSamplingUsesCache`：`isPanelVisible: !isPaused && !consumers.isEmpty` → `isPanelVisible: !isPaused && combinedDemand.needsChargeLimit`（N3），新增两处接线计数必须为 2。
7. `BatteryChargeLimitServiceTests.testManualAndOptimizedWritesManualThenSmartOnlyWhenStillLimited`：`waits == 30` → `waits == 0`（N4），夹具从首步 31 个不变读数改为首步一个；仍断言成功、手动→优化顺序、目标不变。
8. 同一方法：`readCount == 33` → `readCount == 3`（N4），并加请求时读次数 `[1, 2]`，确保第二步紧随首次回读。
9. `testManualAndOptimizedUnchangedReadbackFailsAfterBothWindows`：`waits == 60` → `waits == 30`（N4）。保留方法名以便接续原定向命令；本轮语义为“首步一次回读＋第二步验证窗口后仍失败”。成功断言仍必须是 `.verificationFailed`。
10. 同一方法：`readCount == 63` → `readCount == 33`（N4），并加请求时读次数 `[1, 2]`；不是放宽性能预算，而是删除明确无信息的首步等待。
11. `testRejectedStepStopsSequenceAndNeverReportsSuccess`：统一 `.rejected` → 首步拒绝为 `.rejected`，第二步拒绝为 `.optimizedChargingRejectedAfterManualLift(effectiveLimit: 80)`（N6），仍保留拒绝即停的操作序列断言。
12. 同一方法：`readCount == (首步拒绝 ? 1 : 32)` → `(首步拒绝 ? 1 : 3)`（N4／N6），第二步路径包括初始读、首步后读、第二步拒绝后读。

`ControlPaletteTests.testPowerPaletteFitsMeasuredNaturalHeightInBothLanguages` 原有自然高度正值、面板与测量高度差 ≤0.5、宽度 ≤原宽+0.5、可见屏幕范围等断言均未改写。这里只修夹具选项、增加系统优化单独机型与目标选项有效性断言。

### 新测试源码与主会话定向集合

本轮新增 **12 个测试方法**：服务 4 个（第二步才等待、手动首步仍等、并存回读失败关闭、第二步拒绝后新回读），需求／缓存 3 个（需求矩阵、消费者生命周期与读计数、真实页面接线），文案／界面 5 个（模式组合、临时摘要、无选择项替代、部分拒绝文案、请求期间说明和高度契约）。测试都用显式假客户端／注入读取／纯值；偏好相关原方法继续用 D48 的 `TestPreferenceDomain`，高度测试继续用现有 `TestVolatilePreferences`。

下面全部是**待主会话执行**命令，本轮未执行，也没有通过／失败／跳过数量。在沙箱外独立 scratch 构建包含测试的二进制，再运行定向集合：

```bash
cd /Users/developer/Developer/sc-worktrees/r2-charge-limit
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --build-tests --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-r3-debug --jobs 4
swift test --skip-build --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-r3-debug --filter 'BatteryChargeLimitServiceTests|BatteryChargeLimitPresentationTests|BatteryChargeLimitReadCacheTests|BatteryChargeLimitObjCCallTests|BatteryPresentationTests|GeekSensorsPowerHoverDetailTests|GeekPowerViewTests|ControlPaletteTests|UnifiedMenuBarPanelTests|TestPreferenceHygieneTests|MiniWindowDemoDataTests|GeekHoverDetailTargetTests|MenuBarTertiaryDetailTests'
python3 script/check_private_api.py
```

`UnifiedMenuBarPanelTests` 是本轮应增补的定向类，覆盖既有消费者、暂停与资源清理。前轮其他 12 个定向类继续保留。独立留测宽与自然高度日志及 PNG（复用已有环境变量，不启动实际应用）：

```bash
STORAGE_CLEANER_LAYOUT_EVIDENCE=/Users/developer/Developer/.sc-build/r2-charge-limit/main-r3-layout \
swift test --skip-build --scratch-path /Users/developer/Developer/.sc-build/r2-charge-limit/main-r3-debug \
  --filter 'BatteryChargeLimitPresentationTests/testShortCardSummaryHidesMissingStateAndFits264PointPageInBothLanguages|ControlPaletteTests/testPowerPaletteFitsMeasuredNaturalHeightInBothLanguages'
```

输出应包含**完整模式组合**的宽度，而不只是短上限。逐张核对中英文、深浅色的 `combined80`、`system-only-optimized80`、`manual-lifted100` 与 `smart-paused100` 截图，确认选中手动 90、无空 Picker、临时摘要和说明相符。现有截图文件名前缀 `power-r2-` 为测试既有命名，本轮不改；输出到 `main-r3-layout` 避免覆盖前轮证据。

### 红／绿与反证（均 NOT RUN）

在独立隔离副本应用本轮总补丁，保留本轮测试与接口，先构建绿色候选；一次只回退一个生产行为，保持测试源码不变以获得红色结果，恢复后重新构建并跑同一集合取得绿色。不要通过删除新增接口制造编译错误充当行为反证，也不要在共享集成工作区做全目录还原。

| 项 | 红／反证变体 | 应抓住的测试或证据 |
| --- | --- | --- |
| N1 | 让新卡片组合出口直接返回短摘要；或不限改回长英文 `No charge limit`。另让视图绕过组合出口。 | `testEnergyModeCardKeepsCurrentModeWithShortLimitAndUnknownState`、完整组合后缀、原宽度预算与卡片／悬停接线。长英文高功率组合应超原预算，不调整阈值。 |
| N2 | 去掉非空分支、恢复无选项 Picker，仍保留提示函数以避免编译错误。 | `testUnsupportedManualLimitReplacesOnlyPickerAndKeepsOtherControls`；系统优化单独夹具截图应再次出现空白选择器。自然高度测试并不替代视觉检查。 |
| N3 | 两处可见判断改回 `!consumers.isEmpty`；或电源页不置位、调板不登记／不移除。 | `testVisibleReadsFollowChargeLimitConsumersAndStopWhenLastOneLeaves`、`testOnlyPowerPageDeclaresChargeLimitDemand`、调板与简单／基准页接线；新加 `UnifiedMenuBarPanelTests` 回归现有消费者。 |
| N4 | 并存来源也跑完整首步等待；反过来让所有手动来源都立即进第二步；第二步直接返回成功。 | 两步操作时读数 `[1,2]`、总等待 0／2／30、单手动 `[1,32]`；不变读数和矛盾读数仍验证失败。分别恢复后用同一测试取得绿。 |
| N5 | 移除两个临时摘要分支、恢复无上限／手动 100 文案。 | `testTemporarySummariesDescribeThisChargeWithoutChangingManualTarget`、临时状态完整模式测宽；所选手动目标仍为 80。 |
| N6 | 第二步拒绝返回普通 `.rejected`，或 payload 用首步前／后旧值，不补拒绝后读。 | `testSecondRejectionRecordsManualStepAndUsesFreshReadbackEvenWhenUnknown`（新读85、nil、100；单手动／并存各覆盖）、部分完成文案、请求次数／读次数。第一步拒绝仍不得有后续读写。 |
| N7 | 优化说明重新传 `canRequestFullCharge`、恢复请求进度行，或从测试选项中去掉 90。 | `testPendingRequestKeepsExplanationAndOnlyDisablesActionWithoutAddingHeight`、既有说明接线、目标必须在选项中的新断言；原生高度及实际请求时稳定性由主会话另外记录。 |

成功反证继续保留前轮矩阵：将一致成功判定改回 OR、让智能 3 单独当成功、忽略写前状态、第一步已满仍写第二步、解除手动后任意智能状态都尝试优化，必须被既有与本轮测试抓住。针对 N4 的回读失败、矛盾或智能 3 反例只能有首步动作，不得进入第二步。针对 N6 读到 100 仍保留拒绝结果，不以新读数抹掉接口拒绝的事实。

主会话记录每次命令、退出码、失败方法、恢复后的结果与日志。定向集合绿色后，在集成分支按原门禁运行（不放宽原性能阈值）：

```bash
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
STORAGE_CLEANER_VERIFY_BUNDLE=0 \
STORAGE_CLEANER_UI_SMOKE=0 \
STORAGE_CLEANER_VERIFY_ROOT=/Users/developer/Developer/.sc-build/r2-charge-limit/main-r3-verify \
./script/verify.sh
```

主会话实机验收沿用原授权边界。只读验收补：仅简单面板／性能基准页可见时无周期充电上限读取；电源页与调板任一仍在时按30秒读取；关闭最后一个显示需求后停止。经用户针对该次动作授权的并存满充验收补：首步只回读一次，第二步单独等待并验证；第二步拒绝后提示已完成首步与当前限制，随后只读刷新；请求期间原说明和按钮位置稳定。没有满足条件的实际系统拒绝时记 NOT RUN，不用写入探针制造。

### 补丁分组、只读准备检查与限制

`~/Developer/.sc-build/r2-charge-limit/prepared-r3/` 沿用四组格式：

- `01-service.patch`：服务、并存首步回读与部分拒绝结果、服务测试（N4／N6）。
- `02-read-policy.patch`：需求字段与合并、主电源页与独立调板登记、缓存／接线测试（N3）。
- `03-ui.patch`：模式与临时摘要、无选项说明、部分拒绝提示、请求期间稳定说明、测宽与自然高度夹具（N1／N2／N5／N6／N7）。
- `04-docs.patch`：本节交接追加；全部 `*-message.txt` 末尾均为本次指定的两行作者尾注。
- `all.patch`、`manifest.json`、`generate-prepared.py`、`commit-prepared.py`、`README.md`、`static-checks.json`：基线 `eead0da`，分组、12 个最终文件 SHA-256、产物 SHA-256、新增／未删除方法清单与未执行边界。主会话如改任何文件，先复核再重新生成。

本轮允许的准备检查仅为 `git diff --check`、总补丁及四组 `git apply --check --reverse`、基线与范围／哈希核对；**没有执行测试或守卫脚本**。命令与退出码写在 `static-checks.json`。已有工作区含全部修改，不要再次正向应用 `all.patch`。`commit-prepared.py` 只在主会话完成复核与验证后运行，检查展开基线、分支、空暂存区与所有哈希，按组提交；它不检查测试结果，不替代验收。本轮未执行。四组最终状态一起构建／验证，组间不作为独立构建验收节点。

JEV：调用前检查了实际 `jev_decide` 工具声明，没有模型选择字段；没有自行设置 Astra 或更换模型。对 N6 结果携带已完成事实／实际上限与界面推断两个方案的判断请求被审批策略 `never` 拦截，返回 `MCP tool call requires approval, but approval policy is never`。状态 **BLOCKED**，模型请求未执行，没有 JEV 判断或实际模型身份回执；本轮未绕过审批或沙箱。

未解决／未验证：D60 正文未在本基线找到；Swift 6 编译、严格并发、所有定向与完整门禁、完整模式组合在当前系统字体下的真实测宽、修正夹具后的自然高度、请求期间实际界面稳定性、其他机型 SPI、XPC 单次延迟与真实拒绝回读，均待主会话。可见上限读取仍为已节流的主线程同步调用，未声称消除单次阻塞。除该文档缺口和验证边界外，没有另一个已确认而主动留着的 N1–N7 代码项。

## 主会话验证结果（第 3 轮，2026-10-07 22:2x）

- **提交**：Codex 四组按 `prepared-r3/commit-prepared.py` 提交，哈希校验通过：
  - `89811c5` 服务：两步首读、第二步被拒的结果；
  - `884bab2` 读取：专门的“需要充电上限”需求；
  - `3c313d8` 界面：卡片恢复能源模式、临时摘要、无手动上限说明、调板稳定；
  - `0786937` 交接。
  - 提交说明里的模型名按派工记录改为 `openai/gpt-6.1-sol`。
- **构建与定向测试**：构建 exit 0。定向测试过滤为 `BatteryChargeLimit|BatteryPresentationTests|GeekSensorsPowerHoverDetailTests|GeekPowerViewTests|ControlPaletteTests|TestPreferenceHygieneTests|MiniWindowDemoDataTests|GeekHoverDetailTargetTests|MenuBarTertiaryDetailTests|MenuBarAuxiliary|UnifiedMenuBarPanelTests|MenuBarPanelInteractionTests|PerformanceBenchmark`，共 248 个，0 失败，exit 0。
- **反证**（`rp3.py`，每轮后还原，工作区干净）：
  1. 有上限摘要时卡片去掉能源模式 → 3 个方法失败（`testEnergyModeCardKeepsCurrentModeWithShortLimitAndUnknownState` 等）。
  2. 任何需求方都算“可见” → `testVisibleReadsFollowChargeLimitConsumersAndStopWhenLastOneLeaves` 等 2 个失败。
  3. “手动＋优化”第一步后仍等满 3 秒 → 5 个方法失败。
  4. 第二步被拒说成普通拒绝 → 2 个方法失败。
- **结论**：增量复核在第 2 轮已判定可以合并，本轮修的是那次提出的 7 个 P2。主会话验证通过后合并。实机验收在安装测试版后进行，每次写入前先问用户。
