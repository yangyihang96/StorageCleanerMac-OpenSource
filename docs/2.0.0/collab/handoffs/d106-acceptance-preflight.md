# d106-acceptance-preflight：验收前置（显示前约束、只读验收启动、不启动的安装）

批次：D106，以及复核后的修复 D107（D106-R1，第十一节）和 D108（D106-R2，第十二节）。工作区 `/Users/developer/Developer/sc-worktrees/v2.0.1`，分支 `release/2.0.1`，HEAD `6e660a59`。本轮改动未提交，与 D98–D105 的未提交改动在同一工作区。决定见 DECISIONS D106。

起因：Codex `CODEX_ACCEPTANCE_PREFLIGHT_20261016_0930`（记录 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/acceptance-2.0.1-20261016/STATUS.md`，本轮只读）。用户 0949 的选择经 Codex 转达：“保持禁止硬件写入，先完成可做的准备和隔离测试，暂缓替换”。

本轮没有做：安装或替换 `/Applications/测试版.app`，启动 App 或任何窗口，退出、替换或重启已安装的测试版和它的 helper，注册或运行 helper，真实清理，写风扇、电源或 SMC，提交、合并或发布。正式版没有动。测试只用夹具、临时目录和假执行器。闸门测试把原调用换成记录器，没有窗口、应用、URL 或系统界面到达屏幕。57 个会开窗口的测试类仍未运行。

## 结论

1. **显示前约束与安装路径（第 1 项）**：已提供不启动的安装路径（`--install --no-launch`）和单独的验收启动脚本。测试版的每个新窗口在显示前移到指定的非主屏；放不下或目标屏不存在时不显示（fail closed），不会先在主屏出现再移走。测试包加载时就装上同一个闸门：没有指定显示器时拒绝所有窗口，拒绝即测试失败。57 个会开窗口的测试类由 `verify.sh` 跳过并写明未运行；运行器只在指定的非主屏上运行其中 56 个进程内的类，本轮没有运行。不改全局显示器设置。
2. **旧测试版退出（第 2 项）是阻断项**：helper 启用时，旧测试版正常退出一定写 SMC（`F{n}Tg=0`）。开着 Mac mini 模式时，helper 交接或新 helper 对账还可能写 `pmset disablesleep`。不杀进程、不取消恢复，就没有可证明不写硬件的退出路径。按用户决定暂缓替换。不安装就无法验收新构建的界面，这部分全部未测。
3. **启动维护与副作用（第 3 项）**：18 项都已逐项核对源码（见第六节）。验收会话不做任何自动删除，不连 helper，不检查更新，不建状态栏图标，不做首次或回到前台时的受保护文件夹探测。仍会做的事都写在表里，包括小窗网络区对 ipify 的只读请求。另有一个既有问题：测试版启动时的跑分残留清理指向正式版的文件夹。本轮先只报告；Codex 复核确认后（D106-R1）已经修复，测试版改用自己的文件夹，正式版路径不变（第十一节，D107）。
4. **复核后的两处修复与验证**：D106-R1（D107）见上一条。D106-R2（D108）修好了测试目标在 Release＋测试版下编译不过的既有问题（第十二节）。两者都在真实工作区里通过了定向测试，包括 Release＋测试版。完整门禁：门禁 1、2、3 都是退出码 1，原因见第八、十一节；门禁 4（最终源码）也是退出码 1：除了菜单栏计时项，其余步骤都通过；计时项两次都超过 100 ms（183.179、101.881 ms），阈值没有改，所以完整门禁仍未通过（第十二节）。这些都不是实机或界面验收。

## 一、显示前约束（`DisplayConfinementGate`，`Support/DisplayConfinement.swift`）

只有测试版的验收启动和测试包会安装它，正常启动从不安装。正式构建里 `AcceptanceLaunch.isActive` 恒为假，也没有 `configureOrExit`。

**拦截的入口（24 个，都是公开 API，用 `#selector` 加 `method_setImplementation` 替换，没有 `NSSelectorFromString` 或私有类名）**

| 类别 | 入口 | 闸门开启时 |
|---|---|---|
| 显示 | `orderFront:`、`makeKeyAndOrderFront:`、`orderBack:`、`orderFrontRegardless`、`orderWindow:relativeTo:`（`.out` 放行）、`setIsVisible:`（`false` 放行） | 显示前把窗口移到目标屏的可见区域；已在目标屏则不动 |
| 位置 | `setFrame:display:`、`setFrame:display:animate:`、`setFrameOrigin:`、`setFrameTopLeftPoint:` | 只处理已显示的窗口：新位置不在目标屏上时移回目标屏，不行则保持原位置。隐藏窗口在显示时再处理 |
| 表单 | `beginSheet:completionHandler:`、`beginCriticalSheet:completionHandler:` | 父窗口必须已显示在目标屏上，否则不显示，回调以 `.abort` 结束（异步，不会当作确认） |
| 模态 | `runModalForWindow:`（拒绝时返回 `.abort`）、`beginModalSessionForWindow:` | 同“显示” |
| 其他进程的界面 | `NSWorkspace` 的 `openURL:`、`openURL:configuration:completionHandler:`、`openURLs:withApplicationAtURL:…`、`openApplicationAtURL:…`、`activateFileViewerSelectingURLs:`、`selectFile:inFileViewerRootedAtPath:`；`SMAppService.openSystemSettingsLoginItems`；`UNUserNotificationCenter` 的授权请求与发送；`PHPhotoLibrary` 的首次授权（状态已确定时不弹窗，照常放行） | 一律拒绝，完成回调收到 `RefusalError`（文字含 D106）。这些窗口属于别的进程，本 App 无法定位 |

另有两处调用点直接问闸门（C 接口无法替换）：设置里的“登录时打开”（`SMAppService.mainApp` 的注册和注销，系统会在主屏发通知）、文件操作 helper 的注册与随后的密码框（`AuthorizedApplicationMover.prepareHelper`，应用更新的受保护替换也经过它）。拒绝时分别显示“验收模式不更改登录项”和抛出 `AuthorizedMoveError.unavailable`。

**窗口子类自带的实现**：安装时遍历当时已加载的全部类，NSWindow 子类自己实现了上述窗口入口的，同样包一层（调用 super 的子类会过两次闸门，无害）。遍历只用不给类发消息的运行时函数，类表按原始指针读取（按 `AnyClass` 读会让 Swift 做动态转换，给类发消息，某些根类会因此崩溃，开发中遇到过一次，见第八节）。测试包里实际包了 33 处，例如 `NSRemoteSavePanel.orderWindow:relativeTo:`、`NSLocalSavePanel.orderWindow:relativeTo:`、`_NSPopoverWindow.setFrame:display:`、`NSPopupMenuWindow.setFrame:display:animate:`、`QLPreviewPanel.makeKeyAndOrderFront:`。`uncoveredWindowOverrides()` 检查当时已加载的窗口类，测试断言它为空。

**放置规则**（`DisplayConfinementPolicy`，纯函数）：目标屏按名称完全匹配，必须恰好一块，且不能是主屏（带菜单栏、坐标原点所在的那块）；为空、找不到、重名或是主屏都拒绝。窗口已完全在目标屏上（容差 0.5 pt）则不动。一部分在目标屏上的，按最短距离移进可见区域；其余的放到可见区域正中。比可见区域大的缩到可见区域，最小尺寸也放不下时拒绝。坐标不是有限数时拒绝。

**事后检查**：通过 `NSWindow` 的显示状态、移动、缩放、换屏、成为主窗口等通知，再查一次已显示的窗口。不在目标屏上的立即隐藏，并记为违规（`violation`）。这只能发现，不能预防，从不算作通过。验收会话里出现违规会结束会话；测试里会让当前测试失败。

**不改全局显示器设置**：闸门只改本进程窗口的位置，不调用任何显示器配置接口，也不读写显示器偏好。

## 二、测试窗口

- **加载即安装**：新的 C 目标 `Tests/StorageCleanerTestDisplayBootstrap`，在测试包加载时用构造函数调用测试目标里的 `@_cdecl("storage_cleaner_install_test_display_gate")`（`TestDisplayGateBootstrap.swift`），比任何测试类的 setUp 都早。
- **默认拒绝**：没有 `STORAGE_CLEANER_TEST_DISPLAY` 时是 `denyAll`，任何窗口和外部界面都被拒绝。拒绝和违规通过 XCTest 观察者记到正在运行的测试上；发生在两个测试之间的记到下一个测试；最后一个测试之后的让整个运行以 1 退出。
- **日志只属于真正跑测试的进程**：`swift test --filter`／`--skip` 会先在 `swiftpm-xctest-helper` 里加载测试包，只为列出测试；这个进程继承同样的环境变量，也执行同一个构造函数。所以要求日志（`STORAGE_CLEANER_TEST_DISPLAY_LOG`）时，加载时先一律拒绝窗口，等本进程真正开始跑测试（XCTest 的 `testBundleWillStart`）才新建日志、切到指定模式。列测试的进程不跑测试，不会建日志。无法新建日志时拒绝一切，并让第一个测试失败，所以带显示器的运行不会没有记录。`installed` 一行写明进程名和 PID。（最初的写法在加载时建日志，日志会被列测试的进程抢先建好，真正跑测试的进程反而记不了、退回全部拒绝。反证 C13 证实了这一点，见第八节。）
- **57 个类**：清单在 `script/display-bound-tests.txt`（类名、进程内或进程外、理由）。`script/display_bound_tests.py --check` 用与私有接口检查相同的源码剥离方法重新扫描测试源码，清单与扫描结果有任何不一致都报错。`verify.sh` 跳过这些类，并打印未运行的数量。
- **运行器**：`script/run_display_bound_tests.sh` 先用 JXA 只读地确认恰好有一块同名的非主屏，否则以 78 退出、什么也不运行。之后带上上述两个环境变量，只运行 56 个进程内的类；进程外的 `RealMacUIAccessibilitySmokeTests`（真的启动 App）从不运行。本轮没有运行它。几何断言若因窗口在虚拟屏上而失败，应查原因，不能放宽断言。

## 三、验收启动（`Support/AcceptanceLaunch.swift`）

```
open -n -g -a /Applications/测试版.app --args \
  --acceptance-display "虚拟屏 1 · Codex" --acceptance-log <新文件的绝对路径> \
  -ApplePersistenceIgnoreState YES [--open-menu-bar-panel]
```

`script/launch_beta_acceptance.sh` 会先做检查，再执行上面这条命令。要经 LaunchServices 启动，这样权限仍算在 App 自己名下。脚本在 `open` 之前依次检查：

| 检查 | 不通过时 |
|---|---|
| 参数；日志须为不存在的新文件，所在目录已存在 | 64／73 |
| 测试版 App 本身（`Contents/MacOS/`）在运行。同一 bundle 里的其他进程（Finder 扩展、helper）只列出、不处理：验收会话不连 helper | 75 |
| 目标屏（JXA 只读读取 `NSScreen` 列表）：完全同名、恰好一块、不是主屏 | 78 |
| 已安装的是测试版 bundle ID，`codesign --verify --deep --strict` 通过，签名带团队 | 1 |
| **已安装的构建带验收模式**：可执行文件里同时有 `--acceptance-display` 和 `--acceptance-log` | 69 |

最后一项是必要的。现在装着的是 20261013152803 旧构建，可执行文件里这两个参数名都没有（检查结果 0 处）。旧构建会忽略这两个参数，按正常方式启动：窗口和状态栏图标出现在主屏，连 helper，跑启动维护。所以在装上 D106 构建之前，启动脚本一定拒绝。检查通过后用 `open -n -g` 在后台启动，最多等 20 秒，直到日志出现 `installed`；日志出现 `display-unavailable` 或 `permissions-unverified` 时，分别以 78、77 结束。

`App.init` 的第一句就是 `AcceptanceLaunch.configureOrExit()`，在任何窗口、状态栏图标、存储或 helper 连接之前执行：

| 检查 | 不通过时 |
|---|---|
| 任何以 `--acceptance` 开头的参数都按验收请求检查，所以拼错或只给日志时同样以 64 退出，不会按普通方式在主屏启动。参数只允许两个带值的开关、`--open-menu-bar-panel`、LaunchServices 的 `-psn_…` 和单横线的临时偏好（`-Key value`）；诊断、截屏等开关都不允许 | 退出码 64 |
| 同一 bundle ID 的另一个副本在运行（不激活它，也不交接） | 75 |
| 日志必须是新文件（`O_EXCL`、`O_NOFOLLOW`、权限 0600） | 73 |
| 目标屏：完全同名、恰好一块、不是主屏 | 78（日志记 `display-unavailable`） |
| 完全磁盘访问已确认（只列不会弹窗的 Safari、Mail、Messages 文件夹）；未确认时扫描会让 macOS 在主屏弹出权限窗口 | 77（日志记 `permissions-unverified`） |

通过后闸门进入 `confine` 模式，每个决定写一行 JSON（种类、入口、窗口、前后坐标、原因、时间）。拒绝的窗口保持隐藏并记录。出现违规，或目标屏在会话中消失，会结束会话：之后显示的内容不能再作为证据。结束会话走正常退出，验收协调器不会发出任何 helper 请求（见第五节、第八节测试）。

验收会话不做的事，和正常启动的对照见第六节。

## 四、不启动的安装（`build_and_run.sh --beta --install --no-launch`）

原来的 `install_beta`（约 930–1017 行）在安装和回滚时都会无条件执行 `open -n`，所以另加了一条路径 `install_beta_without_launch`。它不运行 `open`、`osascript`、`defaults write`、`lsregister` 或 `pluginkit`，也不退出、不发信号给任何进程。`--no-launch` 只能和 `--install` 一起用，不能和 `--verify`、`--screenshots`、`--logs`、`--telemetry` 同用（退出码 2）。

1. **组装**：同普通的 `--beta --install`。在 `/tmp/storage-cleaner-beta-package/测试版.app` 组装并签名，嵌入 Finder 扩展，构建号取当前 UTC 时间，且大于已装的构建号。签名用钥匙串里第一个 Apple Development 或 Developer ID Application 证书。如果私钥访问没设为“始终允许”，系统会弹授权框（SecurityAgent，属于其他进程，在主屏），本 App 无法定位。本轮没有组装，所以不知道会不会弹（第九节）。
2. **只要已装测试版还有进程在运行就拒绝，退出码 75，什么也不改**：
   - 阻断项：App 本身或更新用的 askpass（按命令行里的 bundle 路径匹配）；两个 helper 的 launchd 任务有 pid，或任务读不出来（helper 由 SMAppService 以相对路径启动，命令行里没有 bundle 路径，所以改问 launchd）；`/var/run/<风扇 helper 标签>.active` 存在。
   - Finder 扩展只列出、不阻断。Finder 在扩展启用期间会一直保留它的进程；它不连 helper，不写硬件，也不开自己的窗口。交换后它继续用备份里旧文件的映像运行，直到 Finder 重启它。原来的 `install_beta` 也只等 App 本身。
   - 拒绝时提示：旧测试版正常退出可能把风扇交回自动、交回它持有的 Mac mini 睡眠策略（都是硬件写入），只有获批后才能退出；helper 在最后一个客户端断开约 15 秒后会自行退出，除非 Mac mini 模式或风扇控制让它常驻。
3. 记录 helper 的只读快照（`launchctl print` 的 pid 和 runs，可执行文件的 inode 与时间）。
4. 上次中断留下的暂存包（`.测试版.staging.*.app`）先移到备份目录，从不删除。
5. 复制到目标所在卷的暂存路径 `.测试版.staging.<pid>.app`，按 `verify_beta_bundle_at` 校验：Info.plist 身份与构建号、跑分资源、照片权限说明与 entitlement、helper 配置的标签与 MachServices、helper 和整包的严格签名。校验不过就删除暂存包，目标不动。
6. 目标必须是测试版（bundle ID），且新旧两包的签名 Identifier 与 Team ID 相同（`beta_install_swap.py same-signer`）；第一次安装只要求有团队签名。
7. 交换前再查一次第 2 步。
8. 用 `renamex_np(RENAME_SWAP)` 一次原子交换，任何时刻 `/Applications/测试版.app` 都指向一个完整的、同团队签名的测试版，交换后比对 inode。若此时有 helper 在运行，它对 App 路径的监视看到的是改名而不是删除。2 秒后对账时路径存在；按源码，身份比较的是 Identifier 与团队（`MacMiniApplicationTrust.matches`），所以身份仍然有效，不会按“App 已移除”交还策略（未实测；第 2 步本来也要求 helper 不在运行）。
9. 校验装好的包。不过的话原子换回旧包，删除新包，什么也不打开。
10. 报告：安装期间从新包启动的进程（“started from the Beta during the installation”，不退出它）；Finder 扩展；helper 前后快照对比（pid 或 runs 变化即说明 launchd 在安装期间启动过 helper，见第九节 RunAtLoad）。
11. 旧包用 `RENAME_EXCL` 移到 `~/Developer/StorageCleanerMac-beta-backups.noindex/<UTC>-<pid>/测试版.app.previous`（同卷，不在 `/Applications`，改名后 LaunchServices 和 PlugInKit 不会把它当作第二个测试版），从不删除。可用环境变量 `STORAGE_CLEANER_BETA_BACKUP_DIR` 指定备份目录，但必须是绝对路径，不能在 `/Applications`、`~/Applications`、`~/Documents`、`~/Desktop`、iCloud、CloudStorage 或 `/tmp`。脚本会打印回滚命令。

`beta_install_swap.py` 的 `swap`／`place` 只接受同一卷上的真实目录（不是符号链接），先解析父目录里的链接，调用本身再用 `RENAME_NOFOLLOW_ANY` 拒绝路上遇到的任何链接；从不覆盖、从不删除。`signer` 读 `codesign -dv`，ad-hoc 或没有团队的签名一律拒绝；输出里的 Team ID 只显示前 3 位。

## 五、旧测试版退出会写硬件（阻断项，只读调查）

源码链（工作区当前源码）：

1. App 退出 → `FanControlCoordinator.prepareForTermination()`（`Services/FanControlCoordinator.swift:1793`）：只要 `helperStatus == .enabled`，就发送 `.restoreAutomatic`（1799 行）。数据模式（`isDataOnlyFixture`）才直接返回。
2. helper 收到后（`Sources/FanControlHelper/main.swift:563` 分派）调用 `restoreAllFans(using:)`（1619 行），没有“已经是自动就跳过”的判断。
3. `SMCFanController.setAutomatic(fanID:)`（1949 行）在 arm64 上：模式字节不是 0 时写 0；然后**无条件**读出 `F{n}Tg`、清零、写回（1962–1965 行）。所以即使风扇已经是自动模式，也会写一次 SMC。
4. Mac mini 模式（`Sources/FanControlHelper/MacMiniModeRuntime.swift`）：helper 用 `O_EVTONLY` 监视 App 包（151–166 行），收到删除、改名或撤销事件后作废安装状态，2 秒后对账。路径不在或签名身份不符时按“App 已移除”处理，恢复 `pmset disablesleep 0`；身份相符时按当前状态对账，已是期望值则不写。新 helper 启动对账时也可能写 1。

所以，在不杀进程、不停用 helper、不取消正常与异常恢复的前提下，没有能证明不写硬件的退出方式。两个 active 标记都不存在，也不能证明退出不写（第 3 步不看标记）。按用户 0949 的决定，本轮不退出、不替换，也不再次请求同一授权。

不依赖这一步、已完成的工作：新包可以构建和校验，但不安装；不启动的安装路径在旧测试版或它的任何进程还在运行时会拒绝执行，什么也不改；验收会话本身不连 helper，退出时不写任何硬件（测试证明请求函数一次都没被调用）。

## 六、启动维护与副作用审计

“验收”一栏是本轮之后 `--acceptance-display` 会话的行为。

| # | 动作（源码核对） | 正常启动的测试版 | 验收会话 |
|---|---|---|---|
| 1 | Sparkle：`App.init` 时启动，测试版更新源；没有上次检查时间或已超过 6 小时立即检查，此后每 6 小时 | 运行 | 不启动（`startingUpdater: false`）；菜单和更新页的“检查更新”也直接返回 |
| 2 | 隐私快照孤儿清理：永久删除 `$TMPDIR/.StorageCleanerPrivacySnapshots` 下没有租约的目录 | 运行 | 不运行 |
| 3 | 浏览器隐私恢复备份清理（启动、每小时、打开隐私页）：删除超过 7 天或多于 12 份的备份 | 运行 | 不运行：启动时不启用，每小时和打开隐私页时的清理都以“已启用”为前提 |
| 4 | 状态栏图标与采样（`ps`、`nettop`、`pmset -g`、`diskutil`、SMC 读取），写 `MetricHistory-v1.json` | 运行 | 不建状态栏图标（系统会把它画在每块屏幕的菜单栏）；采样和历史写入照常（只读命令，App 自己的文件） |
| 5 | 启动时恢复小窗（`menuBar.restorePanelOnLaunch` 或 `--open-menu-bar-panel*`）；小窗网络区向 ipify 发 GET（默认同意） | 运行 | 不自动恢复；只在 `--open-menu-bar-panel` 或菜单命令时打开，放在目标屏右上角。**打开后网络区仍会请求 ipify**（只读的外网请求） |
| 6–7 | helper XPC：ping、读电源配置、功耗采样；ping 被拒时最多 3 次 `restoreAutomatic` | helper 启用时运行 | 不连接：数据模式协调器，状态固定为“不可用”，`send` 直接抛出 |
| 8 | 健康页的只读命令；App 自己的历史写入 | 运行 | 照常 |
| 9 | 第三方应用更新扫描（出现后 6–10 秒、每次回到前台；首页是更新页时立即）：运行 `brew`、`mas`、`msupdate`，联网，扫描结束时恢复保存的队列并自动续接（可能重启或安装应用） | 运行 | 不运行（`prepareApplicationUpdatesOnLaunch`、`refreshAppUpdates` 直接返回） |
| 10 | 别的应用退出时放行“等待退出”的更新任务 | 运行 | 不触发：队列只在第 9 项的扫描结束时恢复，验收会话没有队列 |
| 11 | 中断操作对账，只写证据 | 运行 | 照常 |
| 12 | 跑分：启动时清理超过 24 小时的残留 | 运行 | 不运行；历史照常读取 |
| 13 | 安装冲突检查（只读，App 内横幅） | 运行 | 照常 |
| 14 | 首次运行的受保护文件夹探测；回到前台时对读不到的位置复查 | 运行 | 都不运行；另要求完全磁盘访问已确认，否则退出码 77 |
| 15 | 引导页（首次运行） | 运行 | 照常；是表单，父窗口显示在目标屏上才会出现 |
| 16 | 重复文件结果库启动时检查最多 1 万个已保存路径是否存在 | 运行 | 照常（只读） |
| 17 | 首页：隐私页→第 3 项；更新页→第 9 项；性能页→`preflightV7` 在测试版自己的 `StorageCleanerMac-Beta/BenchmarkTemporary` 写入探测文件；性能页的全球排行榜区出现时向排行榜接口发 GET | 运行 | 隐私页和更新页同上；性能页的预检照常（App 自己的文件夹）。**排行榜 GET 照常**（只读的外网请求）；发布成绩和移除成绩都要再点确认，验收中不要点 |
| 18 | 退出 → `restoreAutomatic`（SMC 写入） | helper 启用时运行 | 不发送（见第五节） |

其他：语言偏好 `AppleLanguages` 的写入、窗口位置自动保存仍会写测试版自己的偏好；`verifyBatterySettingsAfterReturn` 启动时不做事。不要给验收会话加 `--diagnose-*` 或截屏类开关，参数检查会以 64 拒绝。

**另发现的既有问题（已在 D106-R1 修复，见第十一节）**：`DiskBenchmarkKernel.defaultRootDirectory`（`Services/Benchmark/DiskBenchmarkKernel.swift:92`）原来写死 `Application Support/StorageCleanerMac/BenchmarkTemporary`，那是正式版的文件夹。测试版启动时的残留清理（`SystemMacBenchmarkLifecycleCleaner` → `DiskBenchmarkKernel()`）因此会删除正式版文件夹里超过 24 小时的跑分残留；`startV7` 未传目录时也默认用它。性能页的预检传的是测试版自己的文件夹，不受影响。验收会话本来就跳过启动清理。本节最初只报告；Codex 复核后认定是已授权安全准备中的正确性缺陷，现在默认目录按渠道区分。

## 七、安全安装与界面验收步骤（Codex 独立复核、用户批准后执行）

本轮一步也没有执行。下面每一步都只在前提满足后由 Codex 执行；缺任何一项就停在那一步，不找替代办法。

**前提**

1. 用户另行批准替换 `/Applications/测试版.app`。
2. 旧测试版怎么退出，由用户决定。它正在运行：App PID 33383，Finder 扩展 33384，风扇 helper 33402，都是 2026-10-14 21:45 启动的。正常退出会写 SMC，开着 Mac mini 模式时还会写 pmset（第五节）。用户 0949 选择“保持禁止硬件写入、暂缓替换”，所以这一步现在不能做，本轮也不再请求同一授权。可选的做法：用户批准一次“正常退出时的安全恢复写入”，或者用户自己退出。不要 kill，不要 `launchctl bootout`／`kickstart`，不要删标记文件。
3. 完全磁盘访问由用户在系统设置里给新构建打开或确认。新构建签名团队与 Identifier 不变，TCC 授权一般会延续，但本轮未验证。没有确认时，验收启动以 77 退出。
4. “虚拟屏 1 · Codex”存在，且不是主屏。

**0. 只读预检**（不改任何东西）

```
cd /Users/developer/Developer/sc-worktrees/v2.0.1
python3 -B script/display_target.py "虚拟屏 1 · Codex"            # 期望 exit 0
LC_ALL=en_US.UTF-8 pgrep -lf "/Applications/测试版.app/Contents/"   # 期望只剩 Finder 扩展，或什么都没有
launchctl print system/com.local.StorageCleanerMac.beta.FanControlHelper | grep -E '^\s*(state|pid|runs) ='
ls -l /var/run/com.local.StorageCleanerMac.beta.FanControlHelper.active   # 期望不存在
```

**1. 旧测试版退出**（只按前提 2 的批准做）。等 helper 在最后一个客户端断开约 15 秒后自行退出；它因 Mac mini 模式或风扇控制常驻时，第 2 步会以 75 拒绝。拒绝时按原样报告，不要强行结束。

**2. 不启动的安装**

```
DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer \
  ./script/build_and_run.sh --beta --install --no-launch
```

要逐行看输出，并原样保存：

- `installed without opening: /Applications/测试版.app (build …)`，以及备份路径和回滚命令。
- helper 前后快照对比：pid 或 runs 有变化，说明安装期间 launchd 启动过 helper，按第九节第 3 条处理。
- 是否出现 `started from the Beta during the installation`。
- Finder 扩展的提示行。

组装时如果弹出钥匙串授权框，那是系统窗口，会出现在主屏，本 App 无法预先定位。是否继续由 Codex 判断。

**3. 验收启动**

```
script/launch_beta_acceptance.sh --log <新的绝对路径>.jsonl [--panel]
```

期望输出 `acceptance launch: the display gate is installed`。之后只在虚拟屏上操作：

- 每做一步就看一次日志。正常情况下只有 `installed`、`placed`、`moved`。
- `refused` 表示窗口被拒、一直隐藏，要记下来并查原因。
- `violation`（会话随即结束）和 `externalRefused` 都是发现，不能算通过。
- 不要用 Finder 右键的“用存储清理助手卸载”（第九节第 6 条）。
- 不要点“检查更新”、发布或移除排行榜成绩、清理、清空废纸篓，也不要碰风扇、电源和 Mac mini 控件。

**4. 结束会话**：用菜单“退出”或 ⌘Q。验收会话退出时不发任何 helper 请求（第八节有测试）。

**5. 会开窗口的测试类**（可选，由 Codex 判断是否运行）

```
script/run_display_bound_tests.sh --log <新的绝对路径>.jsonl [--classes REGEX] [--scratch-path DIR]
```

- 不需要安装测试版；
- 期望 exit 0，且日志里没有 `refused`／`violation`／`externalRefused`；
- 几何断言失败时要查原因，不能放宽断言；
- 进程外的 `RealMacUIAccessibilitySmokeTests` 不在其中。

**回滚**：用安装输出里给出的命令，同样要求测试版没有进程在运行。

```
python3 script/beta_install_swap.py swap "<备份目录>/测试版.app.previous" "/Applications/测试版.app"
```

## 八、测试与反证

所有测试都在私有构建目录里运行，只用夹具、临时目录和假执行器；没有安装，没有启动 App，也没有开窗口。

**新增测试（3 个类，22 个）**

| 类 | 个数 | 内容 |
|---|---|---|
| `DisplayConfinementPolicyTests` | 4 | 目标屏按名称恰好匹配一块且不是主屏；放置规则（不动、移进、缩小、拒绝）；任何放置结果都在目标屏上；包含判断用整块屏和 0.5 pt 容差 |
| `DisplayConfinementGateTests` | 12 | 闸门未开启时原实现照常调用；每个入口都在自己的类上替换；`denyAll` 拒绝所有显示入口，窗口保持隐藏；`confine` 在显示前把隐藏窗口移到目标屏；没有可用目标或放不下时拒绝；隐藏窗口可以自由移动，显示时才放置；表单要求父窗口显示在目标屏上；模态被拒时以 `.abort` 结束；外部界面被拒绝；非主线程的显示请求被拒绝；已加载的窗口类没有能绕过闸门的；测试包在第一个测试之前已经装好闸门 |
| `AcceptanceLaunchTests` | 6 | 普通启动不算验收请求；验收请求的参数规则（包括以 `--acceptance` 开头但拼错、只给日志、只写 `--acceptance` 等情况）；日志一定是新建的、仅属主可读的 JSON 行文件；验收会话跳过的启动副作用（按源码原文钉住每一处守卫）；验收协调器从不接触 helper（`isDataOnlyFixture` 为真，状态是“不可用”；依次调用刷新连接、退出准备和断开之后，请求函数一次也没有被调用）；没有指定显示器时测试包拒绝所有窗口 |

`DisplayConfinementGateTests` 在清单里是“豁免”：它的窗口无边框、延迟创建、从不显示，URL 和 App 都是夹具，原调用换成了记录器，所以留在 `verify.sh` 里运行。

**改动的既有测试（3 处，门禁 1 发现）**：D106 改了 3 处既有测试钉住的源码原文。改法是钉住新原文，并加上不变量断言，没有删除或放宽原来的检查：

1. `BetaDistributionTests.testUnifiedRunScriptOwnsStableSignedBetaInstallFlow`：原来钉 `startingUpdater: true`。现在钉 `startingUpdater: !AcceptanceLaunch.isActive,`，并加两条：测试进程里 `AcceptanceLaunch.isActive` 为假；`isActive` 的定义原文（只有测试版构建才看参数，其他构建恒为假）。正常启动仍然启动 Sparkle。
2. `HardwareControlPresentationTests.testAppYieldsToExistingInstanceBeforeTouchingTheHelper`：原来钉 `init()` 的第一句是 `terminateIfDuplicateInstance()`。现在钉整段：测试版先执行 `AcceptanceLaunch.configureOrExit()`，紧接着才是 `terminateIfDuplicateInstance()`。顺序是有意的：后者会激活已在运行的副本（`activate()`），而那个副本的窗口不受约束，所以验收检查要排在前面，自己按 bundle ID 查副本，查到就以 75 退出。另外断言 `configureOrExit` 的函数体里没有 Coordinator、Store、`NSXPCConnection`、`SMAppService`、`activate`，并且用 `runningApplications(withBundleIdentifier:)` 查副本。
3. `HardwareOperationHistoryTests.testOnlyTheSharedCoordinatorRecordsByDefault`：原来钉 `static let shared = FanControlCoordinator(operationHistory: .shared)`。现在钉 `AcceptanceLaunch.isActive ? makeAcceptanceInstance() : FanControlCoordinator(operationHistory: .shared)`，并断言验收工厂的函数体设置了 `isDataOnlyFixture = true`、没有传 `operationHistory`（验收会话不写硬件操作记录）。

**结果**

- **定向**：上面 6 个类，48 个测试，0 失败。
- **测试日志的创建时机**（只跑新增的类）：
  - E1：要求日志、不指定显示器。日志由真正跑测试的进程创建，`installed` 一行是 `denyAll … in xctest 122`，6 个测试通过。
  - E2：日志路径无法新建。第一个测试失败，原因是 `D106 display gate: STORAGE_CLEANER_TEST_DISPLAY_LOG could not be created as a new file …`。
  - E3：不要求日志。22 个测试通过。
- **脚本自测**（`verify.sh` 一开始就运行，夹具都在私有临时目录）：`display_bound_tests.py --self-test`、`display_target.py --self-test`、`beta_install_swap.py --self-test` 都通过。`display_bound_tests.py --check` 通过：56 个进程内、1 个进程外、1 个豁免，共跳过 57 个类。
- **脚本夹具**：用假 bundle、shell 脚本假进程和假 launchd 标签，没有读真实的测试版。
  - `build_and_run.sh` 的活动检查：什么都没运行时，没有阻断，也没有提示；只有 Finder 扩展时，只提示；App 和扩展都在时，App 算阻断，扩展另行提示。
  - 启动脚本的预检：复制到夹具，停在显示器检查之前。什么都没运行或只有扩展时通过，扩展会被列出；App 在运行时退出 75；日志用相对路径时退出 64；日志已存在时退出 73；未知参数退出 64。
  - 能力检查（与启动脚本是同一条 grep）：两个参数名都没有时退出 69；只有 `--acceptance-display` 时退出 69；两个都有时退出 0。
- **完整门禁**：`script/verify.sh`，不开窗口；环境为 `STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`，`STORAGE_CLEANER_VERIFY_ROOT` 用私有目录。57 个会开窗口的类按清单跳过，不计入下面的测试数。
  - 门禁 1：在参数前缀加固和改钉之前运行，退出码 1。Release 测试共 4,968 个，跳过 23 个，失败 3 个，就是上面 3 处钉住的测试。整个运行没有一次闸门拒绝或违规。因为 `set -e`，后面的并发检查构建、Debug 测试、源码守卫和 Python 检查都没有运行。源码守卫的 grep 另外手动跑过，没有命中。
  - 门禁 2：在 D106 的最终源码上运行（D106-R1 修复之前），11:48–12:19，退出码 1。
    - 结果：Release 4,968 个，跳过 23 个，0 失败；Debug 5,078 个，跳过 24 个，0 失败。并发检查构建、源码守卫、私有接口检查（9 处登记用法）、删除和进程清单检查（156 条、247 处）都通过。
    - 唯一的失败：最后一步菜单栏性能脚本里的 `MenuBarPerformanceRegressionTests.testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`，准备阶段 p95 为 101.248 ms，阈值 100 ms。同一门禁的 Release 全量里这一项测得 94.849 ms，但那是另一次测量，不能让这一步算作通过。这一项在 D101 和 r2-mini-sampling 也超过过阈值。门禁结束约 1 分钟后（12:20:02）测得负载 11.21／10.12／11.48（1／5／15 分钟平均）；这只是同一时段的观测，负载是不是失败原因没有验证。
    - 补跑：按先例，12:20:20 测得负载 9.22 后单独重跑这一步，16 个测试 0 失败，p95 为 84.96 ms，退出码 0。这次通过不改变门禁 2 的结果。脚本中断后没跑的 `git diff --check` 也补跑了，退出码 0。
    - 预算没有改，门禁 2 的退出码 1 和失败日志照实保留。
  - 门禁 3（D106-R1 之后）和门禁 4（D106-R2 之后的最终源码）：见第十一节、第十二节。门禁 3 在 Release 全量里同一个计时项超过阈值（110.391 ms），退出码 1。
    - D106 对 `MenuBarStatusController` 的改动只在验收模式下生效（不建状态栏图标、小窗放在目标屏），不涉及这个测试测量的历史数据准备。

**反证**：每一项先在源码里临时插入一处违规，构建后只跑对应的测试，确认测试变红；然后恢复原文件并核对哈希，最后重新构建恢复后的树。

| # | 临时改动 | 对应的测试 | 结果 |
|---|---|---|---|
| C1 | `denyAll` 改为放行 | `DisplayConfinementGateTests.testDenyAllRefusesEveryOrderingEntryAndKeepsTheWindowHidden` | 红 |
| C2 | 显示前不移动窗口（去掉 `setFrame`） | `DisplayConfinementGateTests.testConfineMovesAHiddenWindowOntoTheTargetBeforeItIsOrdered` | 红 |
| C3 | 不包装窗口子类自带的实现 | `DisplayConfinementGateTests.testNoLoadedWindowClassBypassesTheGate` | 红 |
| C4 | 外部界面放行 | `DisplayConfinementGateTests.testExternalUIIsRefusedWhileTheGateIsActive` | 红 |
| C5 | 不检查表单的父窗口 | `DisplayConfinementGateTests.testSheetsNeedAParentShownOnTheTarget` | 红 |
| C6 | 参数解析跳过未知参数 | `AcceptanceLaunchTests.testAnAcceptanceRequestNeedsADisplayAndANewAbsoluteLog` | 红 |
| C7 | 日志去掉 `O_EXCL`、`O_NOFOLLOW` | `AcceptanceLaunchTests.testTheLogIsAlwaysANewOwnerOnlyFileOfJSONLines` | 红 |
| C8 | 验收协调器去掉 `isDataOnlyFixture = true` | `AcceptanceLaunchTests.testAnAcceptanceCoordinatorNeverReachesTheHelper` | 第一轮**仍是绿的**：第二层（helper 状态固定为“不可用”、服务状态“未注册”）单独也能挡住请求，测试区分不出少了一层。于是给测试加上 `XCTAssertTrue(coordinator.isDataOnlyFixture)`，之后变红 |
| C8b | 只去掉第二层（helper 状态改成“已启用”） | 同上 | 红 |
| C8c | 两层都去掉 | 同上 | 红，而且是行为上的：发出了 `restoreAutomatic` 请求 |
| C9 | 测试包加载时不安装闸门 | `DisplayConfinementGateTests.testTheTestBundleInstalledTheGateBeforeAnyTest` | 红 |
| C10 | 要求日志但建不成时不拒绝窗口 | `AcceptanceLaunchTests.testTheTestBundleRefusesWindowsUnlessADisplayIsNamed` | 红 |
| C11 | 回到前台时的受保护文件夹复查不看验收模式 | `AcceptanceLaunchTests.testAnAcceptanceSessionLeavesOutLaunchSideEffects` | 红 |
| C12 | 不检查完全磁盘访问 | 同上 | 红 |
| C13 | 测试日志改回加载时创建 | 带 `STORAGE_CLEANER_TEST_DISPLAY_LOG` 跑 `AcceptanceLaunchTests` | 证实了竞争：日志里只有一行，是 `swiftpm-xctest-helper`（只列测试的进程）写的 `installed`；真正跑测试的进程一行也没写。现在的写法见上面的 E1 |
| C14 | 只有完全等于 `--acceptance-display` 的参数才算验收请求 | `AcceptanceLaunchTests.testAnAcceptanceRequestNeedsADisplayAndANewAbsoluteLog` | 红：拼错、只给日志等 4 种情况变成了普通启动 |
| C15 | 把 `terminateIfDuplicateInstance()` 放到验收检查之前 | `HardwareControlPresentationTests.testAppYieldsToExistingInstanceBeforeTouchingTheHelper` | 红 |
| C16 | `configureOrExit` 里访问 `FanControlCoordinator.shared` | 同上 | 红 |
| C17 | 验收协调器传入 `operationHistory: .shared` | `HardwareOperationHistoryTests.testOnlyTheSharedCoordinatorRecordsByDefault` | 红 |
| C18 | Sparkle 总是启动 | `BetaDistributionTests.testUnifiedRunScriptOwnsStableSignedBetaInstallFlow` | 红 |

C1–C12（C8 用加强后的三种）第一轮是在参数前缀加固之前跑的，之后又在最终源码上重跑了一遍：14 项全部变红，每一项都是对应的那个测试失败；恢复后的哈希与运行前一致，恢复后的树重新构建成功。C14–C18 本来就是在最终源码上跑的。C13 运行时，测试的启动文件已经是最终版本（哈希相同）。

**开发中的一次崩溃（已修复）**：测试包加载时出现 SIGTRAP，调用栈是 `loadedWindowSubclasses` → `swift_dynamicCastSlow` → `swift_getObjectType` → `___forwarding___`。原因是按 `AnyClass` 读取 `objc_copyClassList` 的结果时，Swift 会做动态转换，给某些根类发消息。改为按原始指针读、用 `unsafeBitCast` 转换后，没有再出现。崩溃报告含本机信息，没有放进证据目录。这份报告还说明 `swift test --filter`／`--skip` 会先在 `swiftpm-xctest-helper` 里加载测试包，这就是第二节改为开始跑测试时才建日志的原因。

**测试输出里的 contactsd 报错**：`CoreData: error: … com.apple.contactsd.persistence … Code=4097`（连接被拒）。D106 之前的门禁日志里就有，通过的运行里也有。本仓库不调用通讯录接口，具体是哪个系统框架发起的连接本轮没有查。

## 九、仍未测、无法由本 App 保证的部分

1. **其他进程的界面无法预先定位**：钥匙串和管理员密码框（SecurityAgent）、TCC 权限框、系统设置、Finder、通知横幅。闸门只拒绝本 App 主动请求的这类界面（记为 `externalRefused`）。系统因为访问受保护的数据而自己弹出的框拦不住，所以验收要求完全磁盘访问已确认，并跳过受保护文件夹的探测。照片和通知的授权请求被拒绝；App 不用定位、蓝牙、通讯录、日历、摄像头、屏幕录制或 Apple 事件（按源码检索）。“App 管理”的授权只在修改别的 App 时出现，验收中不做这类操作。
2. **违规检查是事后的**：通知回调发现窗口不在目标屏时，窗口已经显示过一次（通常不到一帧）。它用来发现漏网的入口，从不算作通过。
3. **安装会不会启动新 helper，没有验证**：测试版的 helper 配置现在是 `RunAtLoad`＋`KeepAlive{SuccessfulExit:false}`（D102 L3）。交换包之后，launchd 或后台任务管理会不会立即用新包重新加载并启动 helper，本轮无法验证；下次开机一定会启动。新 helper 启动时：只有 `/var/run/<标签>.active` 存在才写 SMC（安装在它存在时会拒绝）。Mac mini 对账在模式为“关”且本 helper 没有持有 `disablesleep` 时不写，在其他情况下只在观测值与目标不同时写 pmset；测试版有没有 Mac mini 记录（root 所有，`/private/var/db/StorageCleanerMac-Beta-MacMiniMode`），本轮没有读。安装输出里的 helper 前后对比就是这一条的证据。
4. **状态栏图标没有测**：验收会话不建状态栏图标（系统会把它画在每块屏幕的菜单栏，无法只放在虚拟屏），所以状态栏图标和从它打开小窗的路径都没有验收。小窗只能用 `--panel` 或菜单命令打开。
5. **57 个会开窗口的测试类没有运行**：56 个进程内的类要用第七节第 5 步的运行器，`RealMacUIAccessibilitySmokeTests` 会真的启动 App，不在运行器里。确认窗口显示前就在虚拟屏上的唯一依据是运行器的日志，不能拿“屏幕上没有窗口”的抽样代替。几何断言写的是主屏坐标的，在虚拟屏上可能失败；失败要查原因，不能放宽断言。
6. **Finder 右键入口会以普通方式启动测试版**：扩展的“用存储清理助手卸载”按 Finder 选中的 App 打开宿主，不带验收参数。宿主没在运行时，它会以普通方式启动：窗口出现在主屏，连 helper，跑启动维护。验收期间不要用它。宿主是正在运行的验收会话时，打开请求交给这个会话，卸载审阅表单照样受闸门约束。
7. **启动脚本按参数名识别验收能力**：它检查可执行文件里有没有两个参数名，这是证据，不是证明。如果编译器以后改了字符串的存放方式，检查会失败并拒绝启动（失败关闭），不会放行。
8. **组装签名可能弹框**：见第四节第 1 步。
9. **跑分目录按渠道区分后的未测部分**（D106-R1，第十一节）：只用夹具、假文件管理器和定向测试验证（正常构建，以及测试版定义下的 Debug 和 Release；Release 是 D106-R2 修复后在工作区里跑的），没有在真实文件夹里运行，也没有读取真实的跑分临时目录。修复后，测试版的 v7 磁盘子测试会在自己的文件夹里真正运行；按源码，修复前它会被根目录校验拒绝。这一点没有实测。修复前测试版可能留在正式版文件夹里的跑分临时文件，本轮没有迁移或清理；按源码，正式版启动时会按原规则清理其中超过 24 小时的 `benchmark-*.tmp`。
10. **Release＋测试版下只跑了定向测试**：D106-R2 之后，这个条件下跑的是第十一节的 5 个类和 `BrowserPrivacyRecordScannerTests`。全量测试没有在这个条件下跑；门禁只跑 Debug 和不带测试版定义的 Release。
11. **D106、D106-R1、D106-R2 都等 Codex 独立复核**：没有提交，没有安装，没有启动。菜单栏计时项在门禁 2、门禁 3 都超过阈值，门禁 4 的结果见第十二节；之前的失败不会因为之后的运行通过而取消。

## 十、证据

证据目录：`~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/d106-acceptance-preflight/`。目录说明见 `README.md`，校验和见 `SHA256SUMS.txt`。

| 路径 | 内容 |
|---|---|
| `d106-incremental.diff`、`d106-files.txt`、`d106-files.sha256` | 从 D106 开工前的树到现在的增量差异、改动文件清单、每个文件改前和改后的校验和 |
| `baseline/reconstruction.txt` | 开工前的树是怎么重建、怎么核对的 |
| `gate/` | 门禁 1–3 的完整日志；门禁 2 菜单栏性能的单独重跑、`git diff --check` 补跑、时间与负载记录 |
| `tests/` | 定向测试的日志；E1–E3 |
| `counterproofs/` | C1–C18 每一项的临时改动、构建与测试日志、结果、恢复前后的哈希；还有最终源码上的重跑；`counterproofs/r1/` 是 D106-R1 的反证 |
| `r1/` | D106-R1：只含本修复的差异 `d106-r1.diff`、改前改后的源码哈希、冻结摘要复算、正常构建与测试版构建条件（Debug、Release）的构建和定向测试日志 |
| `fixtures/` | 脚本夹具测试的过程和输出 |
| `observations.md` | 只读观察：已安装测试版的构建和进程、开发中的崩溃、contactsd 报错 |

外部记录（本轮只读）：`~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/acceptance-2.0.1-20261016/STATUS.md`。

## 十一、D106-R1：测试版的跑分临时目录与正式版分开（D107）

起因：Codex `CODEX_D106_R1_20261016_1210`，详情见 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/acceptance-2.0.1-20261016/D106-R1.md`（P2）。第六节报告的既有问题经 Codex 独立复核确认，被认定为已授权安全准备中的正确性缺陷，不需要再问用户。门禁 2 结束、结果保存之后才改源码。

**修复前的数据流**：

1. 普通启动的测试版在 `App.init` 里建 `MacBenchmarkStore`，没有传 `lifecycleCleaner`，于是用默认的 `SystemMacBenchmarkLifecycleCleaner()`。
2. 它用 `DiskBenchmarkKernel()`，默认根是 `Application Support/StorageCleanerMac/BenchmarkTemporary`，也就是正式版的文件夹。
3. 启动后 `prepareLifecycleOnLaunch` 调 `cleanupOrphans(olderThan: 24 h)`：目录不存在就创建；把路径上的文件夹改成 0700；删除根里超过 24 小时的普通 `benchmark-*.tmp`。只有验收会话跳过这一步。

风险限于正式版的跑分临时文件。本轮没有执行真实清理，也不声称真的删过文件。

**修复**：`DiskBenchmarkKernel.defaultRootDirectory` 改为复用 `AppDataDirectories.applicationSupportRoot`，再加上 `BenchmarkTemporary`。它按构建身份 `StorageCleanerBuildIdentity.applicationSupportDirectoryName` 取 `StorageCleanerMac-Beta` 或 `StorageCleanerMac`，和性能页已经在用的 `MSeriesProtocol.temporaryRoot` 是同一个文件夹。另加 `defaultRootDirectory(fileManager:)`，让夹具可以指定 Application Support 的位置。下面这些默认调用者都经过它，现在都按渠道区分：

| 默认调用者 | 位置 |
|---|---|
| 启动清理 `SystemMacBenchmarkLifecycleCleaner()` | `Services/Benchmark/MacBenchmarkLifecycle.swift`；`diskKernel` 由 private 改为 internal，只是为了让测试读到它的根 |
| 旧版跑分 `SystemMacBenchmarkWorkloadRunner`：测量本身和它自己的残留清理 | `Services/Benchmark/MacBenchmarkService.swift:33`、`:48` |
| 旧版容量探测 `systemDiskCapacityBytes` | `Services/Benchmark/MacBenchmarkService.swift:126` |
| v7 预检和运行的默认目录（3 处） | `Services/Benchmark/BenchmarkV7Coordinator.swift:79`、`:91`、`:135` |
| 商店里 v7 的默认目录（2 处） | `Stores/MacBenchmarkStore.swift:363`、`:445` |
| `DiskBenchmarkKernel(rootDirectory:)` 的默认值 | `Services/Benchmark/DiskBenchmarkKernel.swift` |
| 系统文件管理器的根目录校验：只有默认根在 Application Support 下被信任 | `DiskBenchmarkKernel.swift:725`（`trustedBaseAndComponents`） |

**没有改的**：

- 正式版路径仍是 `StorageCleanerMac/BenchmarkTemporary`，测试按原来的公式核对过；
- 清理时的各项校验：年龄、名称（`benchmark-*.tmp`）、只限根目录的直接子项、只删普通文件、不跟随链接、所有者校验和 0700 权限；
- 测试注入的根；
- 验收会话仍不做启动清理、不连 helper（第六节、第八节的测试没有改）；
- 正常和异常时的安全恢复。

没有迁移或清理旧的共用文件夹，也没有读取任何真实文件夹的内容。

**行为变化**（按源码，都没有在真实文件夹里实测）：

1. 测试版的启动清理现在只准备和清理 `StorageCleanerMac-Beta/BenchmarkTemporary`：不存在时创建，并把它和 `StorageCleanerMac-Beta` 改成 0700（正式版一直这样对待自己的文件夹）。它不再创建或改动正式版的文件夹。
2. 测试版的 v7 磁盘子测试：性能页传入的根（`MSeriesProtocol.temporaryRoot`）现在就是默认根，会通过根目录校验，所以子测试会在测试版自己的文件夹里真正写临时文件。按源码，修复前这个根既不是默认根，也不在临时目录下，会以 `invalidConfiguration` 被拒绝。验收时如果跑分，以界面结果为准。
3. 集成 QA 包（bundle ID 为 `com.local.StorageCleanerMac.integration`，并设了 `STORAGE_CLEANER_INTEGRATION_ROOT`）：默认根随 `AppDataDirectories` 移进集成根，而根目录校验不信任那里，所以它的启动清理和磁盘测试会失败关闭，不再用正式版的文件夹。仓库里没有脚本构建这个包。

**冻结的 v6 指纹（请 Codex 复核）**：

- 为什么要改：`DiskBenchmarkKernel.swift` 在 `MacBenchmarkCalibrationWorkflowTests` 冻结的 v6 跑分协议源码清单里。这次只改了默认目录，工作负载、文件大小、计时和计分都没变。
- 依据：1.9.9 有先例，`docs/1.9.9-ui-and-function-validation.md` 写的是“只更新确认不改变 v6 工作负载/计分语义的冻结源码摘要”。
- 怎么改的：摘要从 `b6f20c14…` 换成 `8ba060cd…`，旁边加注释写明原因。
- 验证：用旧摘要时，这个测试确实变红，报告的实际值就是 `8ba060cd…`（见证据）；换成新摘要后通过。
- 辅助参考：JEV（jev-latest）比较了三个方案——改文件并换摘要、不碰冻结文件让测试版一律失败关闭、先问复核方——选了第一个，置信度 0.99。
- 如果 Codex 认为冻结摘要需要另行批准，替代方案是不碰冻结文件。这样测试版在自己文件夹里的跑分和清理都会被拒绝，旧版跑分的默认目录也要在组装处另外注入。

**测试**：新增 `BenchmarkChannelRootTests`，共 5 个。

1. **构建条件**：测试版构建里，身份是测试版，本渠道文件夹是 `StorageCleanerMac-Beta`，另一渠道是 `StorageCleanerMac`；正常构建正好相反。
2. **默认根**：
   - 用一个只回答 Application Support 位置的夹具 `FileManager`，默认根是“夹具／本渠道文件夹／BenchmarkTemporary”。
   - 真实的默认根只计算路径、不打开。它等于 `AppDataDirectories.applicationSupportRoot/BenchmarkTemporary`，也等于 `MSeriesProtocol.temporaryRoot`，上一级是本渠道文件夹。
   - `DiskBenchmarkKernel()` 和默认的启动清理用的都是它。
   - 正常构建里，再按原来的公式核对正式版路径没变。
3. **其他默认调用者**：这些不用真实文件夹就构造不出来，所以按源码核对。
   - 旧版跑分、容量探测、启动清理和商店的默认值都指向内核的默认值；
   - 5 处 `targetDirectory: URL =` 默认值全是 `DiskBenchmarkKernel.defaultRootDirectory`；
   - 只有两处定义写了 `"BenchmarkTemporary"`；
   - 没有任何源码手写 `appendingPathComponent("StorageCleanerMac"`。
4. **假文件管理器**：不管被问哪个目录，它都列出两个渠道文件夹里各一个旧残留。清理只问本渠道的文件夹，也只删本渠道里的那一个；另一渠道的路径一次都没有出现。
5. **真实文件夹夹具**：在私有临时目录里建好两个渠道的文件夹。
   - 只有本渠道里超过 24 小时的 `benchmark-old.tmp` 被删除；
   - 新文件、名字不符的文件和指向另一渠道的链接都留着；
   - 另一渠道文件夹里每一项的 inode、大小、修改时间，以及文件夹本身的修改时间，都没有变。

这 5 个测试分别在正常构建和测试版构建条件下各跑一遍。测试版构建条件指的是 `-Xswiftc -D -Xswiftc STORAGE_CLEANER_BETA`，与 `build_and_run.sh --beta` 的编译条件相同；用 Debug 配置和私有构建目录。在测试版构建里，“本渠道”就是测试版，“另一渠道”就是正式版。

定向运行包括上面的 5 个测试，以及 4 个既有类：`MacBenchmarkIOTests`（年龄、名称、链接、只限根目录的清理和根目录校验；所有者校验需要别的用户的文件，没有测试，代码没改）、`MacBenchmarkCalibrationWorkflowTests`（冻结指纹）、`TestDataIsolationTests`、`AcceptanceLaunchTests`（验收会话不清理、不连 helper）。

**结果**（日志在证据目录 `r1/`、`counterproofs/r1/`）：

| 运行 | 结果 |
|---|---|
| 正常构建，冻结摘要还是旧值 | 只有 `testFrozenV6ProtocolFingerprintMatchesCalibrationGate` 失败（同一个测试里两条失败记录：指纹不符，报告的实际值是 `8ba060cd…`；`inconsistentSourceBuild`）。这一次是为了留下证据 |
| 正常构建，换成新摘要 | 52 个，跳过 1 个，0 失败，退出码 0 |
| Debug 配置加 `-D STORAGE_CLEANER_BETA`，私有构建目录 | 构建退出码 0；52 个，跳过 1 个，0 失败，退出码 0 |
| Release 配置加 `-D STORAGE_CLEANER_BETA` 和 `-g`（与 `build_and_run.sh --beta` 的编译条件相同），另加测试必需的 `-enable-testing`，私有构建目录 | 在工作区直接构建：**测试目标编译失败**，构建退出码 1，测试退出码 1（外层脚本的 `run_exit=0` 只表示脚本跑完，不是通过）。原因是一个既有测试的编译条件，见下面的“附带发现”，Codex 定为 D106-R2，修复和工作区的结果见第十二节。私有副本里的那次通过只用于诊断，不算工作区的结果 |
| 门禁 3：在 D106-R1 之后、D106-R2 之前的源码上跑完整的 `script/verify.sh`，私有根目录 | 12:46–13:14，**退出码 1**。Release 4,973 个（比门禁 2 多出新增的 5 个），跳过 23 个，失败 1 个，又是菜单栏计时项 `testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`：p95 110.391 ms，阈值 100 ms 没有改。因为 `set -e`，后面的并发检查构建、Debug 全量、源码守卫、Python 检查、菜单栏性能脚本和 `git diff --check` 都没有运行。开始和结束时的负载是 13.28／35.57／25.68 和 10.00／13.13／17.47（1／5／15 分钟），负载是不是原因没有验证。最终源码上的门禁见第十二节 |

跳过的 1 个是 `MacBenchmarkIOTests.testSystemMetal3DStandardWorkloadWhenExplicitlyRequested`，它只在明确要求时运行。

**附带发现（既有问题，已作为 D106-R2 修复，第十二节）**：仓库的测试目标在“Release 配置＋测试版定义”下编译不过。`BrowserPrivacyRecordScannerTests` 在 `#if DEBUG || STORAGE_CLEANER_BETA` 里用了 `BrowserPrivacyPreviewFixture`，而它在 App 里只在 `#if DEBUG` 下定义（`Sources/StorageCleanerMac/Debug/BrowserPrivacyPreviewFixture.swift`）。两处条件都从 1.9.10（`81d9e298`，2026-08-13）起就是这样，与 D106、D106-R1 无关。门禁只编 Debug 和不带测试版定义的 Release，测试版打包只编 App、不编测试，所以一直没有暴露。我起初写成“改不改请 Codex 决定”，并在私有副本里绕过；Codex `CODEX_D106_R2_20261016_1300` 认定这是当前授权范围内的测试构建阻断，要求在工作区里修，副本的结果不能代替工作区的结果。

两次运行的记录都保留：

- 工作区里直接构建的失败（`r1/release-beta-worktree/`，原始文件的哈希与 Codex 记录的一致）。失败的编译命令里可以直接看到 `-O … -D STORAGE_CLEANER_RELEASE_BUILD -D Xcode -D STORAGE_CLEANER_BETA`，这也说明测试版定义确实传到了编译器。
- 私有副本（`r1/release-beta-copy-diagnostic/`，**仅作诊断**）：由工作区的全部受控和未忽略文件复制而成（1,757 个），与当时的工作区只差这一处条件（逐文件比对哈希）。构建退出码 0，定向 52 个、跳过 1 个、0 失败。

D106-R1 涉及的文件（内核、启动清理、`AppDataDirectories`、构建身份、`MSeriesProtocol`、旧版跑分服务、v7 协调器、商店）里都没有 `#if DEBUG` 分支，Debug 和 Release 编译的是同一段代码。

**冻结摘要复算**：用与测试相同的算法（`r1/frozen_digest.py`）重算 11 个文件。改前的源码得到 `b6f20c14…`，改后的源码得到 `8ba060cd…`，都与当时测试里写的期望值一致。清单里只有 `DiskBenchmarkKernel.swift` 变了。

**反证**：做法同第八节，测试只跑 `BenchmarkChannelRootTests`。4 项在测试版构建条件下运行，R1-C1 另在正常构建下运行一次。

| # | 临时改动 | 测试版构建 | 正常构建 |
|---|---|---|---|
| R1-C1 | 默认目录改回正式版文件夹（缺陷本身） | 红：4 个测试。默认根不是本渠道；源码检查发现手写的 `"StorageCleanerMac"`；假文件管理器记录到清理在正式版夹具路径上准备、列出、删除（删了 2 个，应为 1 个）；真实夹具里，正式版文件夹的 `benchmark-old.tmp` 被删掉了 | 红：只有源码检查。正常构建的本渠道就是正式版，行为测试本来就该通过 |
| R1-C2 | 只把启动清理的默认内核指向正式版文件夹 | 红：默认根测试（启动清理的根不对）和源码检查 | 没有跑 |
| R1-C3 | 清理不再限定根目录的直接子项 | 红：假文件管理器测试，删到了另一渠道的路径 | 没有跑 |
| R1-C4 | v7 预检的默认目录手写成正式版路径 | 红：源码检查 | 没有跑 |

R1-C1 在两种构建条件下结果不同，说明测试版构建条件下 `STORAGE_CLEANER_BETA` 确实进入了编译：它同时作用于 `FanControlShared`（构建身份在这里）和测试目标。如果没有进入，测试版构建的结果会和正常构建一样。另外，构建请求里 `OTHER_SWIFT_FLAGS` 是 `$(inherited) -D STORAGE_CLEANER_BETA`（`build-request.json`）。

每项之后都恢复原文件，核对哈希与改前一致；两种配置恢复后的树都重新构建成功（退出码 0）。反证跑完后，5 个相关文件的哈希与下表“改后”一致。

**源码哈希（SHA-256，改前 → 改后）**：

| 文件 | 改前 | 改后 |
|---|---|---|
| `Sources/StorageCleanerMac/Services/Benchmark/DiskBenchmarkKernel.swift` | `de88c73fccf30279d68b2a31e4db50518236328a94488bbc4dfaa8ecdb1539f0` | `b420f5dd9f7cc0389c4d62b1a2b579ceec1d1fe9334b5820591eea0387107dc6` |
| `Sources/StorageCleanerMac/Services/Benchmark/MacBenchmarkLifecycle.swift` | `a6f5024b12bfb4b1bf328a2c4ea89a90cfbd52216cb526912faf462f6bb336d2` | `07c7cdcc20ddd501499993f9cb6f2b62bb7d46985a702743ac23dc4180b1e2ff` |
| `Tests/StorageCleanerMacTests/MacBenchmarkCalibrationWorkflowTests.swift` | `e871856e2211fbae23d86ace0e591ac8fbd35068c0833ead1b486ce67e055e2d` | `442332e99b709261e1cf11805e2a3cafe9a79c436533893702a90789e6518acc` |
| `Tests/StorageCleanerMacTests/BenchmarkChannelRootTests.swift` | （新文件） | `97a9385f08b719ade4d9efeb053f5b5884ee477e45c01c912fe787f7b189aa6c` |

改前的值与 Codex D106-R1.md 记录的指纹一致（`DiskBenchmarkKernel.swift`、`MacBenchmarkLifecycle.swift`）。D106-R1 没有改 `MacBenchmarkStore.swift` 和 `StorageCleanerMacApp.swift`，它们的哈希仍与 Codex 记录的一致（`c7ed1831…`、`93ad22f8…`）；`BenchmarkV7Coordinator.swift` 与 HEAD 相同。只含 D106-R1 的差异见证据目录 `r1/d106-r1.diff`。

## 十二、D106-R2：测试目标在 Release＋测试版下编译不过（D108）

起因：Codex `CODEX_D106_R2_20261016_1300`，详情见 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/acceptance-2.0.1-20261016/D106-R2.md`（P2，验收和测试构建阻断，不是说 App 本身编译不过）。复现就是第十一节在工作区里那次失败的 Release＋测试版构建：`BrowserPrivacyRecordScannerTests.swift:10` 报 `cannot find 'BrowserPrivacyPreviewFixture' in scope`。门禁 3 和私有副本的运行都结束、结果保存之后才改源码。

**修复**：`Tests/StorageCleanerMacTests/BrowserPrivacyRecordScannerTests.swift` 里预览测试 `testBetaBrowserPrivacyPreviewUsesAnonymousInMemoryRecords` 的编译条件从 `#if DEBUG || STORAGE_CLEANER_BETA` 改为 `#if DEBUG`，与被测的 `BrowserPrivacyPreviewFixture` 一致。仓库里其他用到这个夹具的测试（`BrowserPrivacyLightfieldTests`、`BrowserPrivacyDisclosureTests`、`ConceptLandingNativeLayoutRegressionTests`）本来就整个文件放在 `#if DEBUG` 里。

**没有改的**：

- 这个测试的全部断言，以及同一个类里的其他测试；
- App 源码：调试预览夹具仍然只在 Debug 里，没有为了通过编译把它扩到 Release；
- 测试名不改，Codex 要求按原名单独运行。

覆盖不会减少：Debug（包括 Debug＋测试版）下 `DEBUG` 已定义，这个测试照样编译运行；不带测试版定义的 Release 下它本来就不编译；Release＋测试版下它以前根本编不过。

**结果**（都在真实工作区里运行，日志在证据目录 `r2/`）：

| 运行 | 结果 |
|---|---|
| Release 配置＋`-D STORAGE_CLEANER_BETA`＋`-g`，另加 `-enable-testing`；与第十一节失败的那次是同一条命令，私有构建目录 | 构建退出码 0（13:15–13:20）。定向（同第十一节的 5 个类）52 个，跳过 1 个，0 失败，退出码 0。整个 `BrowserPrivacyRecordScannerTests` 类 51 个，跳过 1 个，0 失败，退出码 0；预览测试在这个条件下不编译，所以不在其中 |
| Debug（工作区的 `.build`） | 构建退出码 0。单独运行 `testBetaBrowserPrivacyPreviewUsesAnonymousInMemoryRecords`：1 个，0 失败，退出码 0。整个类 52 个，跳过 1 个，0 失败，退出码 0 |
| 门禁 4：最终源码上的完整 `script/verify.sh`，新的私有根目录 | 13:21–13:49，**退出码 1**。Release 全量 4,973 个，跳过 23 个，失败 1 个，又是菜单栏计时项 `testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`（p95 183.179 ms，阈值 100 ms 没有改），因 `set -e` 停在这里 |
| 门禁 4 之后各步骤的补跑：同一私有根目录。脚本由 `verify.sh` 第 2–28 行和第 34–107 行生成，只把 `ROOT_DIR` 写成工作区路径（与原文的差异见 `gate/gate4-remaining-vs-verify.diff`） | 13:50–14:02，**退出码 1**。并发检查构建通过；Debug 全量 5,083 个，跳过 24 个，0 失败；源码守卫、私有接口检查（9 处登记用法）、删除和进程清单检查（156 条、247 处）、冲突副本检查都通过；最后的菜单栏性能脚本 16 个里 1 个失败，还是这个计时项（p95 101.881 ms）。中断后没跑的 `git diff --check` 单独补跑，退出码 0 |

两个 `BrowserPrivacyRecordScannerTests` 整类运行里跳过的是 `testOptInProductionBrowserCoverage`：它只在设了 `STORAGE_CLEANER_RUN_LIVE_BROWSER_SCAN=1` 时读本机浏览器，`r2/` 下的两个运行脚本都显式清掉了这个变量。定向里跳过的仍是 `MacBenchmarkIOTests.testSystemMetal3DStandardWorkloadWhenExplicitlyRequested`。

**门禁结论**：最终源码上，除了这个计时项，`verify.sh` 的其余步骤都通过了。计时项在门禁 4 的两次测量里都超过 100 ms，所以完整门禁没有通过；阈值没有改，门禁 2、门禁 3 的失败也照实保留。

这个测试只测纯数据计算（`MenuBarDerivedCache` 加 `GeekPreparedLineFrame`，4.4 万个点），不开窗口；被测的源码文件（`MenuBarDerivedCache.swift`、`MenuBarPerformancePolicy.swift`、`MenuBarPreparedChart.swift`）都不在 D106 的改动清单里。按源码，D106 在测试包里装的显示闸门走不到这段代码，但这只是推断。为此在同一时段（14:15–14:18）交替运行了 D106 之前的树和最终的树。D106 之前的树是重建的开工前树的副本，按门禁的 Release 步骤构建；最终的树直接用门禁 4 的 Release 构建目录（`verify-d106d/release`，加 `--skip-build`，不重新构建）；门禁 4 在 13:21:07 开始，之后没有源码、测试、脚本或资源文件被修改。共三串，每组各 15 次：只跑这一个测试 5 对（ABBA 顺序）；跑整个 `MenuBarPerformanceRegressionTests` 类 5 对（与性能脚本相同）；再按相反顺序跑整个类 5 对。

| | 次数 | 中位数 | 最小–最大 | 超过 100 ms |
|---|---|---|---|---|
| 最终的树 | 15 | 86.15 ms | 82.74–154.67 ms | 3 次 |
| D106 之前的树 | 15 | 85.96 ms | 83.45–135.24 ms | 1 次（135.24 ms） |

两边的中位数几乎一样，D106 之前的树在同样条件下也超过过阈值。超阈值次数 3 比 1，Fisher 精确检验双侧 p=0.598：样本这么少，区分不出差别，也不能排除小的差别。超阈值的 4 次出现时，记录的 1 分钟负载是 7.04–10.53；负载最高的是单个测试那一串（10.66–13.58），一次也没有超过。所以超阈值和记录的负载没有明显对应。

结论：没有证据表明 D106 让这段代码变慢，超阈值的原因没有查明。这个计时项在最终源码上仍未通过，阈值和测试都没有改。下一步请 Codex 和用户决定，例如在安静时段重跑整个门禁，或者把这个测试的波动单独立项调查。

**哈希（SHA-256）**：

| 文件 | 改前 | 改后 |
|---|---|---|
| `Tests/StorageCleanerMacTests/BrowserPrivacyRecordScannerTests.swift` | `d75855c0483cbe50cdc64604e0a5307aa54b0934aef8a30eb99437633fe96dd8`（与 Codex D106-R2.md 记录的一致） | `be98abd97da40d31f24ca8942c82a2d014ab76aafbc959569fcb94c3300c232c` |
| `Sources/StorageCleanerMac/Debug/BrowserPrivacyPreviewFixture.swift` | `e163401a52f84ccbe828c31eb3c2405c90dd12b0fc16d05b5a5d9bfae3fdba9b` | 没有改 |

Release＋测试版运行开始时，脚本打印了 D106-R1 的 4 个文件的哈希，与第十一节的“改后”一致。只含 D106-R2 的差异见 `r2/d106-r2.diff`。第十一节那次失败的原始日志没有覆盖，哈希与 Codex 记录的一致（`build.log` `88b6d87e…`、`run.out` `a7ad7f85…`）；私有副本的结果只作诊断。

## 十三、D106-R3／R4／R5 的修复（D109–D111）与计时项定位

起因：

- Codex `CODEX_D106_REVIEW_CONTINUE_20261016_1440`：对计时项做有边界的定位；
- `CODEX_D106_REVIEW_R3_R4_20261016_1450` 和 `CODEX_D106_REVIEW_R5_20261016_1500`：三项 P2，详情见 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/acceptance-2.0.1-20261016/D106-R3-R4.md` 与 `D106-R5.md`。

性能诊断全部跑完（最后一次 15:02）之后才改源码，修复和测试期间没有计时运行。第十至十二节的证据和失败结果照原样保留。本节的证据放在新目录 `~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/d106-r3-r5-perfdiag/`；原来 179 个文件的目录没有动，`SHA256SUMS.txt` 复核全部 OK。这三项修完不等于整批复核通过。

### 计时项定位（仍未关闭；证据 `perfdiag/`，结论见其中的 `DIAGNOSIS.md`）

方法：在私有诊断包里按原测试的输入、缓存、键、闭包和计时方式逐次重放，记录每次的进程计数器，不断言预算。原测试、阈值和仓库源码都没有改。

- **没有找到代码缺陷，也没有找到会造成超时的测试隔离缺陷**：
  - 每次的指令数基本恒定（除第一次迭代和下面 K 的 3 次以外，是 1,301–1,315 M）；
  - 完整顺序下，进程内其他线程的 CPU 每次 0.05–0.27 ms，处于运行状态的线程只有 1 个，前面的测试没有留下仍在运行的工作；
  - 只先跑 `MenuBarNetworkProcessCadenceTests`（K）时，3 次运行各有一次迭代多出 3.4–3.7 ms 的其他线程 CPU，来源没有查明，这 3 次是 81.3–90.1 ms，都没有超过；
  - actor 和任务跳转只有 0.03–0.22 ms。
- **能复现的是机器状态**：按门禁顺序先跑完前面 3,142 个测试（约 97–113 秒）再跑计时，开头一段 Super 核时钟被压低。FS-1 前 12 次是 2.88 GHz（每次 112.6–130.4 ms），到最后一次（第 20 次）才回到 4.2 GHz，p95 129.2 ms；FS-2 开头 3.6 GHz，p95 97.1 ms。单独运行 2 次、只先跑 `MenuBarNetworkProcessCadenceTests` 3 次，Super 核时钟的中位数是 4.25–4.26 GHz，p95 84.1–103.2 ms，唯一超过的一次是 IPC 低，不是时钟。
- **单次超过 100 ms 的三种机制**：
  1. 同频下 IPC 低；
  2. 被抢占并迁移到 Performance 核；
  3. 完整测试顺序之后时钟被压低。
- **限制**：
  - 计数器是进程级的，Super 核频率是推算值；没有用需要 root 的 `powermetrics`；
  - `pmset -g therm` 没有记录警告，但它只报离散等级；
  - 时钟被压低的原因（功耗或温控管理，或者其他进程占用 Super 簇）分不出来；
  - 门禁 4 的 183.179 ms 没有逐次数据，无法回溯。
- **未解释的观察**：部分测试运行里，进程连接 contactsd（`AddressBook-v22.abcddb`）被拒，CoreData 报 4097。已交付的日志里也有，出现的位置不固定，触发方没有查明。K 的 3 次运行里，它都在诊断测试执行期间再出现一次，与上面那次多出的 3.4–3.7 ms 每次运行正好各一次，但不能确认是同一件事；即使是，那 3 次也没有超过。单独运行的日志里没有它；R3 的相关类 Debug 运行没有运行计时项，也在 `HardwareOperationHistoryTests.testTheRecordIsBoundedByCountAndBytes` 执行期间出现一次。
- **下一步需要 Codex 和用户决定**，没有执行：
  - 如果预算只要求满频下成立，就需要在门禁里让这一项等机器恢复后单独测，这会改变测量条件，必须明确批准；
  - 如果负载之后也要成立，就需要把这段准备代码的周期至少减少约 20%，这是新的性能工作，不是缺陷修复。

### D106-R3：验收参数的严格边界（D109）

**问题**：`AcceptanceLaunch.request(in:)` 把单横线 defaults 选项后面的参数无条件当成它的值。所以合法请求后面加上 `-ApplePersistenceIgnoreState --diagnose-hardware-writes`（或 `-Fixture --diagnose-hardware-control`、`--diagnose-fan-max-hold`）会被接受，而 App 仍按原始参数里有没有这个开关来分派诊断。共享协调器在验收会话里本来就拦硬件写入，所以这不是已证实的 SMC 绕过，问题在于严格的参数边界失效。

**修复**（`Support/AcceptanceLaunch.swift`）：

- 先逐个检查原始参数：验收自身的三个开关以外，任何以 `--` 开头的参数，不论在什么位置都拒绝（`unsupportedArgument`），包括放在 defaults 值位置和 `--x=值` 的形式；
- defaults 的值不能以 `--` 开头，否则报 `missingValue`，所以验收自己的开关也不能藏进值位置；
- `--open-menu-bar-panel` 给两次报 `repeated`；
- `-ApplePersistenceIgnoreState YES` 和以单横线开头的值（如 `-1`）照旧接受。

`StorageCleanerMacApp.swift` 没有改：`configureOrExit` 是 `App.init` 的第一句，解析失败就以 64 退出，后面的诊断分派走不到。

**回归测试**（`AcceptanceLaunchTests`，纯解析，不启动任何东西）：

- `testNoLaunchSwitchRidesAlongInAnyArgumentPosition`：5 个诊断或截屏开关，各放在 6 个位置（直接、defaults 值、值后面再跟合法对、请求之前、两对之间、作为显示器的值），全部拒绝；另有自身开关作值、缺值、重复、合法覆盖；
- `testEverySwitchTheSourcesNameIsRefusedInAcceptance`：扫描 `Sources/StorageCleanerMac` 里全部 `--` 字面量（87 个），每个都直接加入请求、或放在 defaults 值位置，两种都拒绝。

**反证**：把同一组向量编译成私有探针（`r3/parser-probe/`，与 Codex 的方法相同，只编译 `AcceptanceLaunch.swift` 和 `DisplayConfinement.swift`，只调用纯解析）。

| 解析器 | 结果 |
|---|---|
| 改前（`32beb5a4…`） | 42 例中 31 例不符：25 例错误接受，其中包括 Codex 的 3 个例子；6 例拒绝的理由不同。87 个 `--` 开关放在 defaults 值位置，全部被接受 |
| 改后 | 42/42 符合，87 个全部拒绝 |

### D106-R4：显示闸门日志的检查不再只认文件存在（D110）

**问题**：`run_display_bound_tests.sh` 里内嵌的 Python 检查，对空文件、空白文件、`{"kind":"not-a-gate-event"}` 都退出 0，之后会打印“passed on display”。

**修复**：新增 `script/display_gate_log.py --check LOG --display NAME --not-before EPOCH`，runner 改为调用它。它在以下情况失败：

- 文件不存在、为空或全是空白；末行没有换行（不完整）；有空行；
- 有非 JSON 行或非对象行；`kind` 缺失或未知；缺少时间或时间无法读取；
- 第一条不是 `installed`；没有 `installed`，或有不止一条；
- `installed` 的模式不是 `confine`，或显示器名与要求的不一致（按 Unicode 规范等价比较）；
- `installed` 早于这次运行开始；
- `placed`／`moved` 缺 `entry`、`window`，或缺少由 4 个数字组成的 `before`／`after`；
- `refused`、`violation`、`externalRefused`，与原来一样失败。

通过时写明证据层级：

- “installed only”：闸门确实按这个显示器运行，但测试没有开窗口，所以没有放置记录，不制造 placement 事件；
- 或者“N 次放置”。

runner 最后那句 passed 带上这个层级。`verify.sh` 加了一行 `display_gate_log.py --self-test`。

**回归与反证**：

- 自测：26 个无效日志、4 个有效日志、5 个用法错误，另检查 runner 是否调用它并打印证据层级。Python 3.10 和系统的 3.9 都通过。
- runner 的假执行器（`r4/harness.py`）：把改前、改后的 runner 分别复制进没有 `Package.swift` 的夹具仓库；`swift`、`display_target.py`、`display_bound_tests.py` 都是假的，假的 `swift` 只写夹具日志。12 个日志里，改前 6 个结果错误：空、空白、无关 JSON、denyAll 模式、其他显示器、早于本次运行的 installed，都打印了 passed。改后 12/12 符合预期。

全程没有运行任何开窗口的测试。

### D106-R5：测试版备份目录按真实路径判断（D111）

**问题**：`build_and_run.sh` 对 `STORAGE_CLEANER_BETA_BACKUP_DIR` 只做字面 `case` 判断，`Developer/../Documents/backups` 和“父目录链接指向 Documents”都会被接受。下游的 `beta_install_swap.py` 会解析父链接，但不检查禁区，所以兜不住。

**修复**：

- 在任何复制或移动之前，由 `beta_install_swap.py backup-folder` 求规范路径：已存在的部分解析 `..` 和符号链接；缺失的部分只能是普通名字。悬空链接、链接环、`..` 出现在缺失部分、路径中间是文件，都拒绝。
- 禁区与原来相同：Applications 两处、Documents、Desktop、Mobile Documents、CloudStorage、`/tmp`、`/private/tmp`。判断分两层：
  - 按路径组件比较，大小写和 Unicode 规范化都折叠，与 APFS 的比较方式一致；
  - 逐级比较已存在父目录的 inode 身份，firmlink 别名（如 `/System/Volumes/Data/...`）也能拦住。
- 之后整个安装过程只用这个规范路径。
- 往备份目录搬包时改用 `backup-place`：先再查一次，确认目录仍是那个规范路径，然后放置时不解析父链接，由 `renamex_np` 的 `RENAME_NOFOLLOW_ANY` 拒绝路径中的任何链接。
- 默认路径、原子交换、签名、活动进程和恢复检查都没有改。

**回归与反证**：`beta_install_swap.py --self-test` 新增以下用例，Python 3.10 和 3.9 都通过。

- 26 个应拒绝的路径：直接写的、经 `..` 到达的、经父链接到达的 Documents、Applications、云盘和 tmp，以及禁区根本身、悬空链接和链接环；firmlink 路径存在时再加 1 个；
- 6 个应接受的路径：默认路径、`Documents-old`、`DocumentsBackups`、`/Applications-…`、指向安全目录的链接、经 `..` 到达的安全目录；
- `backup-place` 的 3 个用例；
- 假执行器：从 `build_and_run.sh` 取出 `install_beta_without_launch`，它会调用的命令全部换成假的，只放在假 HOME 里。

假执行器在未改的 `build_and_run.sh` 上是红的（`r5/r5-red-before-shell-fix.log`）。逐例的原始结果在 `r5/results.json`：

| 部分 | 结果 |
|---|---|
| `backup-folder` | 28/28 |
| `backup-place` | 3/3 |
| 安装路径，旧脚本 | 5 个别名一直走到下一步的活动检查（这里用假的活动检查以 75 停下），只有 `/tmp` 的字面写法被拦住 |
| 安装路径，新脚本 | 7/7 符合预期：6 个禁区在任何其他调用之前就以 1 拒绝，合法路径过了检查后停在活动检查；夹具目录树始终不变 |

没有运行安装函数本身，没有移动任何真实包。

### 运行结果

| 运行 | 结果 |
|---|---|
| Debug（工作区 `.build`）`AcceptanceLaunchTests` | 构建 exit 0；8 个，0 失败 |
| Debug：钉住 `AcceptanceLaunch` 相关源码的 3 个类（`BetaDistributionTests`、`HardwareControlPresentationTests`、`HardwareOperationHistoryTests`） | 26 个，0 失败 |
| Release＋测试版＋`-g`＋`-enable-testing`（与 R1、R2 同一条命令，私有构建目录）`AcceptanceLaunchTests` | 构建 exit 0（1,000.27 秒，15:21–15:38，结束时负载 20.91）；8 个，0 失败，exit 0 |
| 静态检查：私有接口、删除和进程清单、display-bound 清单、`git diff --check`；新文件没有行尾空白 | 都通过 |

完整门禁没有重跑：本轮改动不涉及计时代码，计时项的结论不变，仍未通过。没有安装、启动或退出任何 App 或 helper，没有真实清理，没有硬件写入，没有开窗口，没有提交。

### 哈希（SHA-256）

| 文件 | 改前（即已交付的版本） | 改后 |
|---|---|---|
| `Sources/StorageCleanerMac/Support/AcceptanceLaunch.swift` | `32beb5a4ad4737dc86c342bf317059dcec0d81c1d27205a844d60631d959995e` | `2587995006b083f1fff6f1aed5c197936dd2c905852974992807a8453b7a23e7` |
| `Tests/StorageCleanerMacTests/AcceptanceLaunchTests.swift` | `b033f6e480235ee8c933ae05c8c15fc0a9f7163c3f38610bb8b85dc21dedfc5b` | `84aca84e940ed7858d632ae1f62affc5f97319a479e09ac57d001ab99fcf5cb7` |
| `script/run_display_bound_tests.sh` | `00ec10ed351d934f9b354812ec2c6d6b3b477ad7aa944c39f7204f7132e89ba2` | `8c93e4cce93d90201de61b8d0a5a08c9d2e064bcc8510a0c33395dca68812a73` |
| `script/display_gate_log.py`（新增） | — | `428f78607d61b893654dbfe8c8e723afd55692a9e12c4ffc538236f1cf2e0fd1` |
| `script/verify.sh` | `14a9e9ab653ccd1e8b0a396be5e75c61aff0e217d18cf2616d980f8c7ebd211c` | `b23dc0216675b753f75b41595b0f9349b0cc5c87cf7d5dee0285fc4d9367a8cb` |
| `script/beta_install_swap.py` | `1e1e7321b8b4a0fa600e5a98509fbff22c2296dad6331448f749f97275c76f78` | `14fa81db1a16a18f1a0a3e5f397daf19e6d846650d325cb735391e3bd2d063d6` |
| `script/build_and_run.sh` | `d109a811f754da4dee1d7b1237221aa8b41fdcc8c1dadf94b03b34b022240ed4`（与 Codex D106-R5.md 记录的一致） | `57035265902b064d9d7a056ea38b4889edd3d1d995e12f4fe7b350cae3186d9a` |

文档（DECISIONS、BOARD、本交接）的改前和改后哈希，以及只含这一轮的差异，见证据目录里的 `increment/`。

## 十四、计时项：热点剖析与行为等价的局部优化（D112）

起因：Codex `CODEX_D106_PERF_CONTINUE_20261016_1600`。按 D27（不改变行为的性能修复直接做），对计时项 `MenuBarPerformanceRegressionTests.testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets` 的准备路径做有边界的剖析和局部优化。

测试本身没有改：44,000 个点、20 次迭代、p95、wall-clock 计时范围、门禁顺序和 100 ms 阈值都不变，也没有拆分、预热、加跳过或重跑挑结果。

本节的证据在新目录 `~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/d106-perf-optimize/`。之前两个证据目录没有动，交付前用各自的 `SHA256SUMS.txt` 复核过。

### 更正第十三节的结论

第十三节和 `perfdiag/DIAGNOSIS.md` 说“没有找到会造成超时的测试隔离缺陷”，这一条不成立。

- xctest 进程的偏好域（`com.apple.dt.xctest.tool`）里留着 433 条已知暂停：
  - 最早开始于 2026-09-14 13:48:18，最晚结束于 2026-10-07 16:17:15 UTC；
  - 是以前在 xctest 进程里运行的代码写进去的，具体是哪次运行、哪个测试没有查明；
  - 今天的门禁和诊断运行之后读到的仍是这 433 条，最晚一条结束于 10-07，说明今天的运行没有新增；
  - `MenuBarSamplingGaps` 只在写入时清理（`end()` 只保留结束时间在 28 天内的最后 512 条），读取时不过滤，所以它们会一直留到下一次写入。
- `MenuBarSamplingGaps.shared` 读到这些暂停。所以这个计时项的输入，除了测试自己造的 44,000 个点，还有这 433 条暂停。
- 改前的 `windows()` 对每个样本逐条检查暂停：
  - 每次准备约 1,304 M 条指令，其中 `windows()` 约 1,262 M（没有暂停时 `windows()` 只要 18 M）；
  - 第十三节逐次记录的 1,301–1,315 M 就是这个工作量；
  - 没有这些暂停时，同一份代码只要约 61 M。
- 第十三节记录的时钟压低、IPC 低和抢占仍然成立，它们决定的是这 1.3 G 条指令要跑多久。门禁 4 那次 183.179 ms 没有逐次数据，仍然不能确定是哪种机制。

已交付的第十至十三节和两个证据目录照原样保留，更正只写在本节和新的证据目录里。

### 剖析（改前，只读；`profile/PROFILE.md`）

**方法**：

- 用私有程序链接门禁 4 的 Release 目标文件，输入与测试相同。
- 先调用真实的 `GeekPreparedLineFrame.init`，再按初始化器的步骤逐个调用同一批产品函数（`displayBuckets`、`GeekCPUHistoryFrame.prepare` 等）。
- 每个阶段前后读三个计数：进程指令数（不受时钟和 IPC 影响）、线程 CPU、wall time。
- 暂停只通过易失参数域传入合成夹具（N 条 0.1 秒的暂停），没有写任何偏好设置。

| 暂停条数 | 每次初始化指令（M） | 线程 CPU（ms） | 其中 `windows()`（M） |
|---|---|---|---|
| 0 | 60.8–61.8 | 3.2–4.5 | 17.9–18.0 |
| 100 | 351.2 | 32.2 | 306.4 |
| 433 | 1,304.1–1,304.9 | 86.3–89.6 | 1,260.9–1,263.9 |
| 512 | 1,535.7 | 119.0 | 1,488.1 |

- **采样**（`/usr/bin/sample`，433 条）：主线程 1,970 个样本里有 1,886 个直接落在改前的 `GeekHistoryAveraging.swift:48`，也就是逐点执行的 `!gaps.contains(where: { date >= $0.start && date < $0.end })`。每次检查约 66 条指令，44,000 × 433 次合计约 1.26 G。
- **其他阶段**：没有暂停时每次合计约 61 M、3–5 ms，离 100 ms 很远，这次没有改。
  - `compressed` 扫描 22 M（初始化器和 `CPU.prepare` 各做一次）；
  - `displayBuckets` 19 M；
  - `CPU.prepare` 11 M；
  - `barRange` 10 M。
- **用户侧同样受影响**：App 自己最多保留 512 条暂停。暂停多的用户，28 天图表每次准备也要付同样的代价（512 条时约 1.5 G 条指令）。

### 改动（只有 `GeekHistoryAveraging.swift`）

- 新增私有的 `KnownPauses`：循环开始前，把暂停一次性整理成按开始时间排序、互不相交的半开区间。空区间和含 NaN 端点的区间丢掉，重叠或相接的合并。之后每个点用二分查找判断。
- `windows()` 主循环里的逐条检查换成 `!pauses.contains(date)`。
- **为什么等价**：
  - `Date` 的比较就是 `timeIntervalSinceReferenceDate`（Double）的 IEEE 比较；
  - 在原式里，空区间（start ≥ end）和含 NaN 端点的区间不包含任何时间，NaN 日期不在任何区间内；
  - 判断一个时间在不在若干半开区间里，用它们的并集判断和逐条判断结果相同；
  - ±∞ 端点照常比较。
- **没有改的**：
  - 代码：参考时间的那一次检查（`hasBoundarySample`）、速率分支里的 `MenuBarSamplingGaps.crosses`、分组、权重、排序、桶的切分、`displayBuckets` 和所有调用方；
  - 语义：统计、缺值、压缩、峰值、hover、估算标识、间隔语义；
  - 其他：更新节奏、缓存容量和生命周期、阈值、测试。

### 等价性（旧实现作隔离对照）

旧实现的做法：

- 改前的文件原样复制为 `OldGeekHistoryAveraging`，只改了类型名，并加了一行 `@testable import StorageCleanerMac`（差异见 `equiv/control-vs-before.diff`）；
- 它与改后的产品代码链接进同一个私有程序；
- 旧实现不进仓库。

| 检查 | 结果 |
|---|---|
| 函数级（`equiv/`）：两个种子各 20,640 例（边界 620、44k 大输入 20、随机 20,000）。逐个比较 `windows()` 每个窗口的起止、索引和权重（按位），`displayBuckets` 的每个桶，以及 `isMissing`／`intervalStart` 的调用顺序 | 0 不符，两个种子分别比较了 1.13 亿和 1.21 亿个窗口 |
| 覆盖 | 每个种子：约 1.6 万例带暂停，约 9.1 千例带非有限暂停；约 420 万个样本落在暂停里，约 18 万个正好在暂停起点，约 18 万个正好在终点。另有非有限日期、乱序、重复、速率起点、缺值、参考时间在窗口边界 |
| 灵敏度 | 把暂停终点上移一个 ulp，510 个边界例里 392 个结果变了，说明比较能分辨一个 ulp 的差别 |
| 改前就有的越界陷阱（见下） | 预测 54 例和 52 例，逐例单独起子进程运行，改前改后都以 133（SIGTRAP）退出，没有一例只在一边出现 |
| 整帧（`framedump/`）：改前、改后两份完整产品目标文件各自链接。帧和输入见表后 | 已知暂停为无、433 条、512 条、329 条边界暂停时，改前改后逐行相同（各 2,880 帧）；同一程序重复运行一次也相同。暂停集合确实影响输出：433 条与无暂停相比有 137 行不同，边界暂停有 2,020 行不同 |

整帧比较的帧和输入：

- `GeekPreparedLineFrame`：10 种原始和压缩输入 × 11 种通道配置（两个大输入只用其中 5 种）× 6 种时长 × 2 种绘图区 × 2 个参考时间，共 2,352 帧。完整帧的摘要包含 CPU 列、桶、值、hover 值和估算标识、线段、范围、压力等级、源点；
- `GeekCPUHistoryFrame.prepare`：120 帧；
- `GeekPreparedDiskFrame`：5 种磁盘输入，120 帧；
- 显式暂停集合（无、有限、非有限、开放）下的 `displayBuckets`，带和不带速率起点各一次：288 帧。

### 改前改后的工作量（`stages/`）

17:11:40–17:12:40 改前改后交替运行，1 分钟负载 9.4–10.8。下表是每次初始化的指令数（M），每种 3 轮：

| 暂停条数 | 改前 | 改后 |
|---|---|---|
| 0 | 61.1–62.4 | 61.2–62.0 |
| 433 | 1,304.1–1,308.7 | 66.5–67.9 |
| 512 | 1,527.6–1,529.4 | 67.2–68.6 |

- 433 条时，`windows()` 从 1,262–1,267 M 降到 23.8 M（没有暂停时是 18 M），线程 CPU 从 92.8–109.4 ms 降到 3.6–4.4 ms；
- 512 条时，线程 CPU 从 96.4–99.2 ms 降到 4.0–4.1 ms；
- 没有暂停时指令数相同，线程 CPU 的差别来自当时的时钟和负载。

### 计时与定向

**定向**（17:13–17:14，私有构建目录）：

- 范围：Release（`-enable-testing`）和 Debug 各一遍，共 16 个类，涉及图表、暂停、统计和测试隔离；跳过规则与门禁相同，这 16 个类都不是显示类。
- Release：310 个，0 失败，exit 0。计时项 `preparation_p95_ms=5.244`，`cached_delivery_p95_ms=0.0025`。
- Debug：317 个，跳过 1 个（计时项在 Debug 下按原设计跳过），0 失败，exit 0。
- 运行时仍是原来的 xctest 偏好域，那 433 条暂停没有删除或改写。

**完整门禁（门禁 5，17:14:46–17:53:39）**：改动后只跑了这一次，exit 0，最后一行是 `Repository verification passed.`。

- 条件：`STORAGE_CLEANER_VERIFY_BUNDLE=0`、`STORAGE_CLEANER_UI_SMOKE=0`，新的私有构建根目录。开始时记录的源码哈希与交付时一致，包括改后的 `GeekHistoryAveraging.swift`、计时项测试、`verify.sh` 和 `verify_menu_bar_performance.sh`。1 分钟负载开始时 8.23，结束时 14.98。
- Release：4,975 个，跳过 23 个，0 失败。计时项通过，`preparation_p95_ms=5.536`，`cached_delivery_p95_ms=0.0027`。
- 严格并发构建通过。
- Debug：5,085 个，跳过 24 个（计时项在 Debug 下按原设计跳过），0 失败。
- 检查：源码守卫通过；私有接口检查通过（9 处登记用法）；删除和进程清单检查通过（156 条、247 处）。
- `verify_menu_bar_performance.sh`：16 个，0 失败。计时项 `preparation_p95_ms=7.329`，`cached_delivery_p95_ms=0.012`。
- `git diff --check` 通过。
- 最后输出 `NOT RUN (D106): 57 display-bound test classes`，57 个会开窗口的测试类仍然没有运行。
- 测试数：与门禁 4 相比，Release 和 Debug 各多 2 个，是第十三节 R3 新增的 2 个测试；这一轮没有增删测试。
- 日志里的其他输出：
  - contactsd 的 CoreData 4097 照旧出现（第十三节已记）；
  - 现有的 `MiniSensorsLiveReadingTests` 照常只读读取本机传感器，以往门禁也有，没有写入。
- 这一项在门禁 2–4 里的 p95 是 101.2–183.2 ms，这次是 5.5 ms（Release 全套）和 7.3 ms（性能脚本）。这只说明这次运行没有超过阈值。wall-clock 计时仍受机器状态影响，不能保证任意负载下都在 100 ms 以内。

### 没有改、但写法相同的地方（只记录）

下面几处也是“逐点乘以逐条暂停”的写法：

- `windows()` 速率分支里的 `MenuBarSamplingGaps.crosses`：磁盘、网络速率图，每个带起点的样本检查一次；
- 不做平均的 `displayBuckets` 路径里的 `crosses`：每个空桶一次，量小；
- 摘要和压缩里每个点、每个通道的 `statistic`／`coverage`：`MenuBarTelemetryModels.swift` 的 `coverage(from:to:...)` 每次调用一次 `crosses`。

它们都不在计时项的路径上，这次没有测量，也没有改。暂停很多时它们也可能变慢；要处理的话需要另外剖析。

### 改前就有的越界陷阱（没有改）

`windows()` 在下面三个条件同时成立时，数组下标会越界，进程以 SIGTRAP 退出：

1. 参考时间按 1970 秒计正好落在窗口边界上；
2. 计入的样本里没有一个正好等于参考时间；
3. 有一个计入的样本在参考时间之前（按 2001 秒计不相等），但换算成 1970 秒后舍入成同一个边界值（相差在约 0.24 µs 以内）。

改前改后行为相同。实际运行中：

- 参考时间来自按当前时间开始的时间线和共享时钟，样本按秒级节奏采集；
- 这三条几乎不会同时出现，但没有证明不可能。

修它会改变行为（这种样本该算进哪个窗口），超出 D27 的范围，需要 Codex 和用户决定。一个可选做法是：这类样本按参考时间之前的那个窗口处理。

### 建议（没有执行）

xctest 偏好域里的旧暂停只影响测试进程，清不清由用户决定。

- 清除命令：`defaults delete com.apple.dt.xctest.tool menuBar.history.unrecordedIntervals.v1`。它会改真实的偏好设置，所以这次没有执行。
- 改动之后，不论有没有这 433 条，计时项每次的工作量都在约 61–69 M 条指令之间（0 到 512 条暂停实测 61.2–68.6 M）。

### 限制

- 指令数和线程 CPU 是进程级计数，wall time 受当时负载影响（剖析时 1 分钟负载 8.9–13.2）。
- 机器上同时有其他进程（浏览器、WindowServer、正式版 App、Codex 等），只观察，没有动。
- 合成暂停的位置与真实的 433 条不同。改前的代码对每条暂停做同样的比较，成本只取决于条数；指令数也与门禁诊断一致。
- 等价性是有限输入上的逐位比较加上推理，不是形式证明。
- 没有运行 57 个会开窗口的测试类，也没有做签名后的运行时验收和界面验收。

### 哈希（SHA-256）

| 文件 | 改前（即已交付的版本） | 改后 |
|---|---|---|
| `Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHistoryAveraging.swift` | `757f979f651e1157b80a7f30b7c6f0d368ace1e7a08f143abbf86949dc65696b` | `30b39aaebf46725cd01187c4c0691def6d4fb9e7d0937b648717e4d56cedd048` |

计时项测试、`MenuBarPreparedChart.swift`、`MenuBarSamplingGaps.swift`、`verify.sh` 都没有改，它们的哈希见证据目录里的 `increment/`。文档（DECISIONS、BOARD、本交接）的改前和改后哈希，以及只含这一轮的差异，也在 `increment/`。

## 十五、Codex 复核 D112 后的 R6、R7（D113）

起因：Codex `CODEX_D112_REVIEW_R6_R7_20261016_1815` 复核 D112。已知暂停优化和当前的 100 ms 计时项在源码和隔离层面通过；R1–R5 保持关闭。另有两个 P2，本节在同一会话里做小范围修复：

- R6：`GeekHistoryAveraging.windows()` 在参考时间正好落在窗口边界时，参考时间之前的有限有效样本仍会越界。
- R7：计时项经 `GeekPreparedLineFrame` → `displayBuckets`（默认 nil）→ `MenuBarSamplingGaps.shared(defaults: .standard)`，工作量仍取决于真实的 xctest 偏好。

本节的证据在新目录 `~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/d112-r6-r7/`。之前三个证据目录没有动，交付前用各自的 `SHA256SUMS.txt` 复核过。

这一轮只做了定向验证，没有跑完整门禁。第十四节的门禁 5 也不是全隔离的，见“披露”。

### R6：参考时间之前的样本归前一个窗口

**原因**：

- `Date` 按 2001 年起的秒数存储。在这个时间段，它比换算成 1970 年起的秒数更细：前者的 ulp 是 2⁻²³ s，后者是 2⁻²² s。
- 参考时间正好在窗口边界、而且没有样本正好等于参考时间时，`windows()` 不开新窗口。
- 这时参考时间之前 1 个 ulp 的样本，换算成 1970 秒后会舍入到边界。算出的窗口号等于还没开的新窗口，下标越界。

Codex 的复现：

- 参考时间 `Date(timeIntervalSince1970: 1_792_107_072)`；
- 样本是参考时间的 `nextDown`，早 1.19e-7 s；
- 间隔 4,032 s，起点为参考时间之前 8,064 s，没有暂停。

**改动**（`GeekHistoryAveraging.swift`，点样本路径加一行）：

```swift
if atBoundary, key == current, key > first, date < referenceDate { key -= 1 }
```

- 参考时间之前的可表示样本归前一个窗口；真正等于参考时间的观察仍开新窗口；窗口仍是半开区间。
- 不丢有效样本，也不对所有异常一概钳位。只有同时满足下面四条时才移一个窗口：
  - 参考时间在边界；
  - 样本舍入到新窗口号；
  - 样本早于参考时间；
  - 前一个窗口在范围内。
- 首窗口不动（`key > first`）。范围内没有前一个窗口时，唯一的窗口照旧同时包含这两个样本。
- 带测量区间的样本走原来的覆盖路径，不受影响。区间太短、碰不到任何窗口时，按一次观察处理，同样遵守这条规则。

**行为变化**：非崩溃输入里只有一类会变。

- 条件：参考时间在边界，有一个样本正好在参考时间（所以 D112 不崩），另外还有参考时间之前、舍入到边界的点样本。
- 变化：D112 把这个点样本算进新窗口，现在算进前一个窗口。权重仍是 1，窗口内仍按时间排序。

两个特殊情形：

- 参考时间是边界的 `nextUp`（换算成 1970 秒仍等于边界）：正好在边界上的样本早于参考时间，按规则归前一个窗口，比精确归属早一个窗口。两个种子里各有 6,018 个。
- 参考时间是边界的 `nextDown`：正好在参考时间的样本照旧开新窗口，这个窗口的起点晚于终点。这是改前就有的，没有改。

**没有改**：

- 内部边界、以及参考时间不在边界时的 1970 秒舍入：样本可能晚一个窗口，但不越界。
- 起点是边界的 `nextDown` 时首窗口的归属。
- 日期大到换算 `Int64` 时溢出的陷阱：属于无效输入，与本项无关。

**回归测试** `GeekHistoryAveragingTests.testSampleJustBeforeBoundaryReferenceStaysInPrecedingWindow`，九种平均间隔都测：

- 参考时间的 `nextDown`、正好、`nextUp` 三个时刻；
- 首窗口起点的 `nextDown`、正好、`nextUp`；
- 参考时间上的样本缺值或在暂停里，以及它之前的样本缺值或在暂停里；
- 范围内没有前一个窗口；
- 测量区间三种：覆盖到参考时间之前、太短只算一次观察、覆盖到参考时间。

**等价与归属**（`equiv/`）：用 D112 的 `GeekHistoryAveraging.swift` 原样复制一份作对照，另一份在越界处跳过并记录。

| 检查 | 结果 |
|---|---|
| 用例：两个种子各 226,389 例（边界 620、44k 大输入 20、R6 构造 205,749、随机 20,000）。R6 构造是：九种间隔 × 参考时间在边界及前后 1–2 个 ulp × 4 种起点 × 边界附近 7 个时刻的全部组合；每组再加缺值、暂停、测量区间和首窗口起点几种变体；另有 Codex 的复现 | — |
| 没有规则样本的用例（213,296／213,298 例） | 新实现与 D112 逐位相同：窗口、显示桶，以及 `isMissing`／`intervalStart` 的调用顺序 |
| 有规则样本、D112 不崩的用例（3,808／3,804 例） | 与 D112 相同，只是规则样本移到前一个窗口。D112 在这些用例里全部违反性质检查，新实现 0 例 |
| 有规则样本、D112 越界的用例（9,285／9,287 例） | 新实现正常返回，结果等于跳过版对照加上归到前一个窗口的规则样本。每个种子抽 100／102 例单独起子进程：抽样包括 Codex 的复现、全部非 R6 用例，以及 R6 用例里每 200 个取一个。D112 全部以 133 退出，新实现全部以 0 退出 |
| 性质：每个计入的样本恰好出现一次，点样本权重为 1，参考时间之前的样本不在新窗口，窗口数正确 | 新实现 0 违规 |
| 精确归属：按整数精确算出每个样本应属的窗口，再与实现的结果对比 | 新实现早一个窗口的只有规则造成的 6,018 个（即上面的 `nextUp` 情形）。参考时间之前却晚一个窗口的为 0 个；对照（D112，越界的用例用跳过版）是 2,575／2,579 个。差两个窗口以上的 0 个。其余晚一个窗口的类别新旧相同：首窗口 25,875，参考时间上的样本 4,672，内部 166,019／165,623 |
| 灵敏度 | 把同一程序链接到 D112 构建，“新实现”就是 D112（种子 20261016、随机 2,000 例，共 208,389 例，跳过 D112 会越界的用例）。D112 不崩、带规则样本的 3,762 例全部报出问题，性质违规 4,432 个，说明检查能分辨 D112 的行为（`out/sensitivity-d112build.log`） |

第一次运行两个种子都是 exit 1，分别有 11 个和 15 个问题，全部出在对照程序的预期上：

- 随机用例里有 plot 宽度为 0 或 NaN 的。这时 `displayBuckets` 在调用 `windows()` 之前就返回，所以跳过版在显示桶路径上本来就不会记录跳过，而对照程序要求它记录。
- 改正这一条预期后 exit 0。宽度无效的越界用例正好是 11 个和 15 个，与第一次的问题数一致。
- 第一次的日志、源码和程序保留在 `equiv/history/run1-exit1/`。
- 灵敏度运行做得更早，用的就是第一次运行的源码。改正的那条预期只在 D112 越界的分支里，而灵敏度运行在进入这个分支之前就跳过了这些用例，所以结果不受影响。

### R7：计时项和新测试自带已知暂停

**依赖注入**（生产默认不变）：

- 新增可选参数 `unrecordedIntervals: [DateInterval]? = nil`：
  - `GeekPreparedLineFrame.init`；
  - `GeekCPUHistoryFrame.prepare`；
  - `TimeBucketAggregator.observedSegments`。
- nil 时仍读 `MenuBarSamplingGaps.shared`。生产调用方都不传，行为不变（整帧检查 B 与 D112 逐字节相同）。
- 生产入口（图表视图里的 `GeekPreparedLineFrame(...)` 和 `pointSegments` 里的 `observedSegments(...)`）都不传；内部只把帧自己收到的参数往下传。
- 传入时，这一帧的每一步都只用传入的列表：
  - 折线帧的 `displayBuckets` 和压缩投影；
  - CPU 帧的两处 `displayBuckets`、压缩投影和短路径；
  - `observedSegments`。
- 下面几处仍读共享暂停。它们不在计时项的路径上，这次没有改，只记录：
  - 磁盘帧和磁盘摘要（`MenuBarPreparedChart.swift`）；
  - 网络帧（`MenuBarGeekCharts.swift`）；
  - 功耗准备；
  - 窗口摘要；
  - 构造存储历史时的压缩。

**计时项** `testOptimizedLongHistoryPreparationAndCachedDeliveryBudgets`：

- 传入 512 条合成暂停：互不相交，各 0.1 s，分布在第一个样本之前的保留期里，不遮任何样本。512 是共享存储最多保留的条数。
- 加一个断言，放在两个计时区之外：每次准备出的帧里，各桶样本数之和等于 44,000。这样工作量不再取决于机器上的偏好。
- 不变的部分：
  - 44,000 个点、20 次、p95；
  - `systemUptime` 计时范围；
  - 100 ms 和缓存预算；
  - 门禁顺序。
- 没有预热，也没有改成只测空暂停。

**新测试** `MenuBarPerformanceRegressionTests.testLongHistoryFrameUsesOnlyTheKnownPausesItIsGiven`：

- 同一 44k 负载下：
  - 0 条、433 条、512 条合成暂停准备出的帧逐桶相同；
  - 120 个桶，每个点恰好出现一次。
- 一条从第 40,000 个点到第 42,000 个点的半开暂停，只隐藏下标 40,000–41,999 这 2,000 个点。
- 在测试自己的私有偏好域（`TestPreferenceDomain.make(for:)`）里写一条覆盖全部样本的冲突暂停：
  - 把它显式传入时，全部样本被隐藏；
  - 之后再用注入的列表准备，结果与之前逐桶相同；
  - 私有存储的内容也没变。
- 不改进程级状态：私有偏好域由测试清理，不写参数域。
- 定向运行时参数域里放着夹具。`MenuBarSamplingGaps` 只在初始化时读一次偏好，而参数域盖过所有 suite（`argprobe/`），所以这个私有存储的初值就是参数域夹具：
  - A 运行（Codex 的 512 条 2020 年暂停）：`end` 按 28 天保留期截掉这些旧暂停，冲突列表只剩覆盖暂停；
  - B 运行（覆盖 2000–2100 年的一条）：冲突列表是这一条加上覆盖暂停。
  - 两种情况测试都通过。不带参数夹具运行时（例如门禁的 `swift test`），私有存储从空开始。这两种初值是按代码推出的，没有单独测量。

### 验证

这一轮没有跑完整门禁，也没有运行任何会开窗口的测试。

**构建**（私有目录，不安装）：

- Release（`-c release -enable-testing`）：exit 0。
- Debug：第一次 exit 1，原因是与 Release 并行时争用 SwiftPM 共享的 Sparkle 包缓存，报 “already exists in file system”，没有编译任何源码。Release 结束后单独重跑，exit 0。
- 两次构建前后的源码哈希相同（`builds/`）。

**定向 xctest**（`targeted/`）：

- 与 Codex 复核时一样，直接运行 `xctest`。
- 参数域里放合成的已知暂停。测试进程里的共享存储和每个私有偏好域读这个键时都得到这份夹具，读不到 xctest 偏好域里的值（`argprobe/`）。

| 运行 | 夹具 | 范围 | 结果 |
|---|---|---|---|
| Release A | Codex 的 512 条合成暂停（参数 SHA-256 `929390a9…`，逐字复现） | 15 个整类，加 5 个类的部分方法 | 290 个，0 失败，0 跳过；计时项 p95 5.17 ms |
| Release B | 一条覆盖 2000–2100 年的暂停。哪一步读了共享存储，样本就全被隐藏 | 计时项和新的 R7 测试 | 2 个，0 失败；计时项 p95 9.00 ms |
| Debug A | 同 A | 同 A | 297 个，跳过 1 个（计时项原有的 `#if DEBUG` 跳过），0 失败 |
| Debug B | 同 B | 同 B | 2 个，跳过 1 个（同上），0 失败 |

- 每次运行，显示闸门日志只有一条 `installed`（denyAll），没有窗口。
- 测试二进制在运行前后哈希不变。
- 运行时机器上有用户自己的进程，只记录，没有动：Google Drive 和 fileproviderd 各占约 0.9–1.3 个核，1 分钟负载 9.7–16.1（`targeted/logs/*.conditions`）。

**整帧**（`framedump/`）：同一程序链接到这一轮的 Release 构建。

| 比较 | 结果 |
|---|---|
| B：参数域放无、433 条、512 条、329 条边界暂停，不注入；对比第十四节 D112 构建的输出 A | 四组都逐字节相同（各 2,897 行，2,880 帧）。R6、R7 没有改变这些输入上的任何一帧 |
| D（对照）：参数域放覆盖暂停，不注入 | 与 B 的无暂停组相比，折线 1,764 行、CPU 95 行不同。说明不注入时，环境暂停确实会进入折线和 CPU 帧 |
| C：参数域放覆盖暂停，注入同一组暂停 | 非 stored 输入上的折线、CPU、显式暂停行全部相同。三个 stored 输入本身就不同：它们由历史存储压缩得到，压缩会读环境暂停 |
| C4：参数域放同一组暂停，另加一条只在最后一小时原始区的暂停 R1（参考时间之前 600 s 到 300 s），并注入这组暂停 | 先用 v2 只保存 stored 输入：四组都与不加 R1 时逐字节相同（压缩只处理一小时以前的点）。四组 C4 与 B 相比只有已知暂停行（1 行）和磁盘行（72 行）不同；折线、CPU、显式暂停和全部输入行（包括三个 stored 输入）逐行相同。磁盘帧仍读共享暂停，不在 R7 范围内 |
| D4（对照）：参数域放 R1，不注入 | 与 B 的无暂停组相比，折线 980 行、CPU 59 行、磁盘 72 行不同。说明 R1 落在样本上，不注入时会进入折线和 CPU 帧；C4 注入后这些行全部相同，说明注入时这些帧（包括压缩分支）都没有读共享暂停 |

C 之后试过把 B 的 stored 输入存成 JSON 再读回（dumper v2）。产品的历史解码会校验压缩统计（`MenuBarTelemetryModels.swift:1376–1408`），读回时抛 `MonitoringFileError.invalidStructure`，8 个运行都以 133 退出，没有输出。记录保留在 `framedump/out-v2/`，C4 改用上面不需要读回的办法。

### 定向范围：运行与 NOT RUN

测试目标里共有 485 个 XCTestCase 类。完整清单和每条理由在 `targeted/selection.txt`。

**运行**：

- 15 个整类：
  - `GeekHistoryAveragingTests`、`MenuBarPerformanceRegressionTests`、`TestPreferenceHygieneTests`；
  - `PanelChartNormalizationTests`、`MiniWindowCPUChart1011Tests`、`MenuBarHistoryGapTests`、`MenuBarBucketStatisticsTests`；
  - `BatteryPresentationTests`、`GeekSensorsPowerHoverDetailTests`、`GeekHoverDetailTargetTests`；
  - `MiniWindowFanHistoryCacheTests`、`MenuBarTertiaryDetailTests`、`MiniWindowD43LayoutTests`、`GeekPowerViewTests`、`MiniWindowRangeSwitchTests`。
- 5 个类的部分方法：
  - `ChartContinuityTests`：9 个里的 8 个；
  - `MiniWindowMemoryPressureLevelTests`：12 个里的 9 个；
  - `MiniWindowConsistencyRuleTests.testTertiaryHistoriesShowAxisFooterWithScaleAndUnrecordedLegend`；
  - `UIConsistencyRegressionTests.testCompactAndGeekPanelsAvoidCardWithinShapeDecoration`；
  - `MiniWindowPhase2ReviewTests.testOnlyTheChartOfTheCPUCardIsDimmed`：用 `ImageRenderer` 和固定输入渲染 CPU 卡片，不开窗口，不建 ScanStore。

**NOT RUN**：

- `MenuBarSamplingPlanTests`（整类）：
  - 它只有 `testHardwareHistoryKeepsSourceTimesAndRejectsExpiredSingleFlightCache` 用到改动的代码（第 512 行，默认共享暂停的 `GeekPreparedLineFrame`）。
  - 这个测试的 `SystemMonitorSampler` 用默认的 `cpuCounterReader`，会读实时 CPU 计数（`SystemMonitorService.swift:764–771`），同类的其他采样测试也一样。
  - 默认 nil 的折线帧由整帧检查 B 覆盖。
- `ChartContinuityTests.testPauseBoundariesPersistAndAnOpenPausePreventsBridging`：
  - 它先写私有偏好域再读回，参数域夹具会盖过所有 suite 的值，所以会因为夹具而失败。
  - 它不在改动路径上（`MenuBarSamplingGaps` 没有改）。
  - 不带夹具单独运行的话，那个进程的共享存储就失去保护。
- `MiniWindowMemoryPressureLevelTests` 的三个方法都做实时读取：
  - `testDefaultReaderIsTheKernelPressureLevel`：读 `kern.memorystatus_vm_pressure_level`，并取默认 `SystemMemoryProbe` 快照；
  - `testProbeReportsTheSystemLevelWhateverThePercentAndTheOldHeuristicSay`、`testAnUnreadableOrUnknownSystemLevelStaysUnavailable`：只注入压力等级代码，快照仍读 `host_statistics64`、`vm.swapusage` 和 `kern.memorystatus_level`。
- `MiniWindowPhase2ReviewTests` 的其余 5 个方法：
  - 它们读的是内存中监视器的历史切片和摘要，不经过改动的帧代码；
  - 它们经 `ScanStore.makeForTests` 构造 ScanStore，其中保留了实时默认依赖，例如会列出真实 home 下 Library 文件夹的 `ScanReadinessService.summary`。没有证明这些依赖不会被调用，所以按这一轮“不重复真实传感器或真实路径读取”的限制不运行。
- `MiniWindowConsistencyRuleTests`、`UIConsistencyRegressionTests` 的其余方法：不读改动的文件，也不调用改动的代码。
- 实时读取，且不在改动路径上：
  - `MiniSensorsLiveReadingTests`；
  - `SystemMonitorServiceTests`：其中对源码的断言只提到这次 diff 没碰的类型名，已静态核对（`targeted/static-source-assertions.txt`）。
- 不在改动路径上，上一轮的定向清单跑过、这一轮没跑：`TestDataIsolationTests`（私有偏好域持久化，会被参数域夹具盖过）、`SystemEnergyACTelemetryTests`、`SystemEnergyAccumulatorTests`。
- 57 个显示类：56 个进程内、1 个进程外，跳过方式与 `verify.sh` 相同。其中 `MiniWindowUpdatingStateTests` 有对 `MenuBarGeekCharts.swift` 和 `MenuBarPreparedChart.swift` 的源码断言，已静态核对，结果都通过。
- 其余 402 个类不在改动路径上：
  - 不调用改动的函数，也不调用调用它们的类型和视图；
  - 不离屏渲染带历史图的视图；
  - 不读改动的文件。

### 披露

**第十四节的定向运行和门禁 5 不是全隔离的**：

- 都用 `swift test` 运行，没有参数夹具，所以计时项读了 xctest 偏好域里的 433 条暂停。这正是 R7 的问题。
- 两者都包括 `MiniWindowMemoryPressureLevelTests` 里三个做实时读取的方法（sysctl、`host_statistics64`），也都包括 `MenuBarSamplingPlanTests`。后者默认的 `cpuCounterReader` 读实时 CPU 计数，这次核实。
- 门禁 5 还包括 `MiniSensorsLiveReadingTests`、`SystemMonitorServiceTests` 等所有非显示类。

**这一轮**：

- 定向运行里，产品代码照测试原样读 `.standard` 的其他键，例如界面语言，与 Codex 复核时相同。已知暂停这个键由参数夹具覆盖，测试代码拿不到真实值。
- xctest 偏好域里的旧暂停没有删除或修改；测试进程里这个键被参数夹具覆盖，代码读不到它的真实值。

### 限制

- 等价性是有限输入上的逐位比较加上推理，不是形式证明。
- 定向不是门禁：没有跑完整的 Release／Debug 门禁和性能脚本。57 个显示类、签名后的运行时和界面验收都没有做。
- 计时项 p95 只说明这几次运行没有超过阈值。wall-clock 计时仍受机器状态影响。
- 第十四节“没有改、但写法相同的地方”里其他没有测量的 O(n×g) 路径，这次没有扩大处理。

### 哈希（SHA-256）

| 文件 | 改前（D112 交付版本） | 改后 |
|---|---|---|
| `Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHistoryAveraging.swift` | `30b39aaebf46725cd01187c4c0691def6d4fb9e7d0937b648717e4d56cedd048` | `ad49ba5b7dc2b7744fb00b5eafd9a1d1e07b7c667b71d4a74f9c2e016d21aef3` |
| `Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarPreparedChart.swift` | `7403b98f300ad800a0d594f23267f37e94a726c2022b67d543ef43cc7e987547` | `e73213c6fb7cb62a923e4850204fe2cbe9b5c0ac58cb144b48e7a1ea45449a56` |
| `Sources/StorageCleanerMac/Views/MenuBarAdvanced/MenuBarGeekCharts.swift` | `9978e6959ceabe270476984b93289b9b82b56a05de6753d3ce48913c28a553bd` | `b36c2c67dc74af97d44642df37c36f192bdce3fd9b0525b8dbf8e100d9118411` |
| `Tests/StorageCleanerMacTests/GeekHistoryAveragingTests.swift` | `ffb36454043172b3d6d3be01579357872bc27b0d8648106f87c768c172d74561` | `9978dd20fce3f3321639e512b6d8a550cfc3ade1a1d007889679b45e22012504` |
| `Tests/StorageCleanerMacTests/MenuBarPerformanceRegressionTests.swift` | `9add97baa1cf6c98bf7994ab57b874b6025110abee7b00a84f18b2e6889ff279` | `01dcf5b80c64afdc548f31cda4806831396ca18efccbd96147af38c83bfab16d` |

`MenuBarSamplingGaps.swift`、`TestPreferenceDomain.swift`、`verify.sh` 都没有改，它们的哈希在证据目录的 `change/` 里。文档（DECISIONS、BOARD、本交接）改前和改后的哈希，以及只含这一轮的差异，也在 `change/` 里。

## 十六、Codex 复核 D113 后的 R6（D114）

起因：Codex `CODEX_D113_R6_RECHECK_20261016_2025` 独立复核 D113。R7 在源码和定向隔离层面关闭，R1–R5 保持原来的限定关闭。R6［P2］仍未通过，而且不是原问题重复出现：

- D113 新加的那一行引入了新的错分。Codex 的复现：
  - `b = Date(timeIntervalSince1970: 1_792_107_072)`，参考时间 `r` 是 `b` 的 `nextUp`；
  - 样本 `[b, r]`，间隔 4,032 s，起点 `b − 8,064 s`，没有暂停；
  - D113 得到 `[[],[0],[1]]`，预期和 D112 都是 `[[],[],[0,1]]`。`b` 是前一个半开窗口的排除端点，却被移进了这个窗口；
  - 九种间隔都能复现，D112 exit 0，D113 exit 1。
- 同一验收边界上的旧问题：参考时间是 `b` 的 `nextDown`、样本只有它本身时，仍得到起点 `b` 晚于终点 `r` 的反向窗口，九种间隔都失败。
- 第十五节对这两种情形的披露不能代替修复。

Codex 要求在同一会话里最小修复三件事的精度一致性：真实边界判定、窗口分配、样本归属。验收要求：

- 参考时间本身要移到 `nextDown`、正好、`nextUp`；
- 要测样本邻点、参考时间上没有／缺值／在暂停里的样本，以及测量区间；
- 样本不丢不重复，权重和半开归属正确，没有反向窗口；
- 不能拿“早于参考时间就归前一个窗口”作判据。

本节的证据在新目录 `~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/d113-r6-recheck/`。之前四个证据目录没有动，交付前用各自的 `SHA256SUMS.txt` 复核过。

这一轮只做了定向验证，没有跑完整门禁。

### 原因

窗口 k 是 `[k × 间隔, (k+1) × 间隔)`，以 1970 年起的秒数计。九种标准间隔是 3,600 s 到 28 天各除以 600，都是整秒，所以边界也都是整秒。

`Date` 和 1970 秒的精度不同：

- `Date` 按 2001 年起的秒数存储，2018–2035 年间 ulp 是 2⁻²³ s；
- 换算成 1970 年起的秒数要加 978,307,200，结果的 ulp 是 2⁻²² s；
- 所以边界前后各一个 `Date`（`nextDown`、`nextUp`）换算后正好落在两个可表示值的中点，按就近取偶舍入到边界本身。

D112 和 D113 用换算后的秒数决定窗口号、判断参考时间是否正好在边界，也用它算测量区间覆盖到哪些窗口。结果，边界旁边的 `Date` 都被当成了边界本身：

- 边界前一个 ulp 的点样本、起点或测量区间起点，被算进后一个窗口。
- 边界前一个 ulp 的参考时间被当成正好在边界上。有样本正好在参考时间时，就开出起点晚于终点的窗口（旧问题）。
- 边界后一个 ulp 的参考时间也被当成正好在边界上：
  - 没有样本正好在参考时间时，`[b, r]` 这个窗口不显示；
  - D113 那一行又把正好在 `b` 的样本移进前一个窗口（Codex 的新复现）。
- 测量区间的终点在边界后一个 ulp 时，最后这一小段被丢掉，或者整个区间退化成一次点观察。

D113 那一行只在点样本路径上补救，判据是“早于参考时间”，不是半开区间的真实边界，所以参考时间在 `nextUp` 时会错分。

### 改动（`GeekHistoryAveraging.swift`，只改 `windows()`）

```swift
func boundary(_ key: Int64) -> Date { Date(timeIntervalSince1970: Double(key) * interval) }
func window(containing date: Date) -> Int64 {
    var key = Int64(floor(date.timeIntervalSince1970 / interval))
    while date < boundary(key) { key -= 1 }
    while date >= boundary(key + 1) { key += 1 }
    return key
}
```

- 换算后的秒数只用来估计窗口号，再用 `Date` 本身和边界比较来纠正。整秒间隔的边界换回 `Date` 是精确的。
- 下面各处都改用它：
  - 首窗口（起点所在的窗口）；
  - 参考时间所在的窗口，以及参考时间是否正好在边界（`referenceDate == boundary(current)`）；
  - 点样本的窗口；
  - 测量区间覆盖的首尾窗口，以及每个窗口分到的重叠；
  - 窗口的起止。
- 删掉 D113 那一行。现在每个时刻都属于包含它的半开窗口。
- 新窗口是否显示仍按原规则：参考时间正好在边界时，只有那一刻有计入的观察才显示新窗口。这个判断改成了 `Date` 的精确比较。
- 测量区间：
  - 每个窗口计入 `[max(起点, 区间起点), 样本时刻)` 与它的精确重叠；
  - 区间在范围内没有长度时（样本正好在起点，区间整个在起点之前），按一次观察计入，权重 1；
  - 在这种情况下，D112 和 D113 只在起点正好在边界时按一次观察计入，否则丢掉这个样本。
- 窗口终点改为下一个边界 `boundary(k + 1)`。整秒间隔下，它与原来的 `lower + interval` 逐位相同；非整秒间隔下两者可能差一次舍入，改后窗口首尾相接。
- 以下都没有变：
  - 函数签名和 `displayBuckets()`；
  - 暂停判断（`KnownPauses`）、缺值、`hasBoundarySample` 的条件；
  - 排序和权重的含义。

### 行为变化

和 D113 相比，只有下面几类输入会变。九种标准间隔下，前五类只出现在边界前后一个 `Date` 的时刻上（2018–2035 年间是 1.19e-7 s）：

1. 点样本在边界前一个 ulp：从后一个窗口回到它所在的窗口。
2. 起点在边界前一个 ulp：
   - 现在首窗口从起点开始，多出一个只有一个 ulp 长的窗口；
   - 原来首窗口从边界开始，起点到边界之间没有窗口。
3. 参考时间在边界前一个 ulp：最后一个窗口就是包含参考时间的那个，终点是参考时间，不再有反向窗口。
4. 参考时间在边界后一个 ulp：
   - 现在 `[b, r]` 照常显示，`b` 和 `r` 上的样本都在里面；
   - D113 把 `b` 上的样本移进前一个窗口；
   - D112 在没有样本正好在 `r` 时不显示这个窗口。
5. 测量区间的起点在边界前一个 ulp，或终点在边界后一个 ulp：这一个 ulp 的重叠计入它所在的窗口。原来要么算进相邻窗口，要么整个区间退化成一次点观察。
6. 与精度无关（Z 类）：带测量区间的样本正好在起点、区间整个在起点之前时，现在总按一次观察计入。整帧检查里唯一的变化就是这一类（见下）。
7. 非整秒间隔（图表不用，只出现在随机用例里）：窗口终点是下一个边界，窗口首尾相接，少数样本因此换了窗口。

窗口数变化时，显示桶照原来的办法把窗口重新分到各个显示位置。

### 回归测试

`GeekHistoryAveragingTests.testDatesBesideABoundaryStayInTheirOwnHalfOpenWindows` 替换第十五节的 `testSampleJustBeforeBoundaryReferenceStaysInPrecedingWindow`，九种间隔都测。

**前提断言**：三个边界 `b0`、`b1`、`b` 前后各一个 `Date`，换算成 1970 秒后都等于边界。这说明测的正是会舍入的输入。

**结构检查**：每次调用都做，不依赖预期值：

- 首窗口从起点开始，末窗口在参考时间结束，没有反向窗口，窗口首尾相接；
- 计入的点样本只出现一次，权重 1，落在窗口的半开区间里（只有末窗口在参考时间处闭合）；
- 测量区间只出现在与它重叠的窗口里，权重为正，合计等于它在范围内的长度；
- 不计入的样本（范围外、缺值、在暂停里）不出现。

**预期值**：

- 九个时刻：三个边界、它们前后的 `Date`，再加一个在范围之前的。参考时间分别在 `b` 的 `nextDown`、正好、`nextUp`；
- 每种参考时间下，再测：参考时间上没有样本、样本缺值、样本在暂停里，以及前一个窗口整个在暂停里；
- Codex 的四种情形：原始、正好、`nextUp`、`nextDown`；
- 起点在边界的 `nextDown`、`nextUp`；
- 测量区间：
  - 跨边界；起点或终点在边界旁；终点正好在边界；
  - 终点在参考时间；跨过参考时间所在的边界；
  - 在起点处截断；整个在起点之前（按一次观察计入）。
- 权重的预期都是精确值，例如 `ulp`、`1 − ulp`、0.5、0.25。

### 等价与归属（`equiv/`）

同一个程序里同时跑三份实现：

- 新实现：这一轮 Release 构建里的 `GeekHistoryAveraging`；
- D113：D113 交付的文件，只改类型名；
- D112：第十五节的跳过版，越界处只记录、不追加，其余与 D112 交付文件相同。

检查有四项：

1. **独立的精确 oracle**：
   - 适用范围：输入在 2⁻²³ s 网格上（2018–2035 年的每个 `Date`，以及 1967–1984 年），间隔是整秒；
   - 用整数精确算出每个窗口的起止、样本和权重，不调用产品代码；
   - 新实现必须与它逐位相同。
2. **性质**（不用 oracle，所有用例、三份实现都查）：
   - 窗口从起点到参考时间首尾相接，没有反向；
   - 每个计入的样本恰好出现一次：点样本权重 1，在窗口的半开区间里；测量区间只在重叠的窗口里，权重合计等于覆盖长度；
   - 不计入的样本不出现；
   - 显示桶是窗口按显示位置重新分组的结果；
   - 新实现必须 0 违规。
3. **输入标记**（全部由输入算出）：
   - R、S、P、M：参考时间、起点、点样本、测量区间首尾，按 1970 秒判定的结果与精确判定不同；
   - Z：见上一小节；
   - E：非整秒间隔；
   - U：输入不在网格上。
   - 没有任何标记的用例，新实现必须与 D113、D112 逐位相同，包括 `isMissing`／`intervalStart` 的调用顺序。
4. **其余差异**按标记和类别计数。

**用例构成**：每个种子 392,529 例，其中 Codex 36、边界 165,888、生产形态 216、R6（第十五节）205,749、边缘 620、44k 大输入 20、随机 20,000。

- 边界用例是下面几项的全部组合，每组再加 2 种缺值、2 种暂停和 4 种测量区间的变体：
  - 九种间隔；
  - 两个年份：2026 年，以及 1970-01-11（这时换算不舍入）；
  - 参考时间：在边界前一个 ulp、正好、后一个 ulp、半个间隔后；
  - 起点：在 `b0`、它前后一个 ulp，或 600 个窗口之前；
  - 样本：`b0`、`b1` 两个边界和它们前后各一个 ulp，共 6 个时刻的全部子集；另外每例都有半个窗口处和 `b` 及其前后各一个 ulp 的 4 个样本。
- 生产形态：起点是参考时间之前 600 个间隔，最后一小时每秒一个样本，参考时间在边界上、旁边或两个边界之间。

两个种子的结果（20261016／3507360256）：

| 检查 | 结果 |
|---|---|
| oracle | 391,353／391,433 例适用（126,065,113／122,375,475 个窗口）。新实现 0 例不同。D113 有 173,731／173,753 例不同；D112（不越界时）有 163,610／163,627 例。其余 1,176／1,096 例是非整秒间隔，不适用 |
| 性质 | 新实现 0 违规。D113 有 174,892／174,827 例违规，D112 有 164,768／164,701 例 |
| D113 违规按类（种子 20261016，例数） | 首窗口不从起点开始 72,207；末窗口不在参考时间结束 16,361；反向窗口 44,793；不相接 25,380；丢样本 12,628；点样本不在自己的窗口 83,193；测量区间不在恰好重叠的窗口 41,988；权重不等于覆盖 50,926 |
| 无标记用例 | 170,415／170,460 例，新实现与 D113、D112 逐位相同 |
| Codex 四种模式 | 新实现 36/36。D113 18/36，`nextUp`、`nextDown` 都是 0/9。D112 9/36：原始复现 9 例越界，正好 0/9，`nextUp` 9/9，`nextDown` 0/9 |
| 灵敏度 | 同一程序链接 D113 构建，这时“新实现”就是 D113（种子 20261016）：174,892 例报出问题，Codex 模式 18/36，exit 1。与上面 D113 的计数一致（`out/sensitivity-d113build.log`） |

与 D113 的差异，按计入的样本分类：

| 类别 | 整秒间隔 | 非整秒间隔（只有随机用例） |
|---|---|---|
| 有差异的用例 | 187,217／187,239 | 1,161／1,074 |
| 窗口数变化（例） | 少 1：20,169；多 1：55,916；多 2：1,152（两个种子相同） | 少 1：4／3 |
| 点样本到更早的窗口 | 254,048／253,652 | 2,776／2,079 |
| 点样本到更晚的窗口 | 13,355／13,355，即撤回 D113 那一行的错误移动 | 32／44 |
| 同一窗口起点、终点不同 | 0 | 54,480／65,953 |
| 测量区间的权重变化 | 64,251／65,477 | 18,886／17,955 |
| 点观察变成测量区间 | 73,157／73,150 | 8／7 |
| 测量区间变成点观察 | 0 | 39／139 |
| 原来被丢、现在计入 | 12,626／12,630 | 3／1 |
| 现在被丢 | 0 | 0 |

- 与 D112 的差异（不越界时，整秒间隔）：
  - 177,105／177,122 例；
  - 点样本到更早的窗口 246,343／247,062 个，到更晚的窗口 0；
  - 测量区间权重变化 62,053／61,982 个，点观察变成测量区间 72,339／72,330 个；
  - 原来被丢、现在计入 12,626／12,630 个，现在被丢 0。
- 整秒间隔下，由代码可知 D112 和 D113 只在 Z 类上丢样本：别处换算出的覆盖窗口不为空时，都落在区间真正重叠的窗口里，重叠大于 0。所以整秒间隔的“原来被丢、现在计入”都是 Z 类。这是推理，harness 没有按 Z 单独计这一项；非整秒间隔的 3／1 个没有归类。
- 运行记录：
  - 第一次两个种子都 exit 0（`history/run1/`，程序哈希在 `history/run1/binaries.sha256`）。
  - 之后加了 `R6_ONLY` 诊断模式：只在设置这个环境变量时输出单个用例的输入和三份实现的窗口，然后退出，不影响正常运行。当时用一个临时程序看了两个非整秒间隔的随机用例，输出被截到前 30 行，没有保存，那个程序已删除。
  - 交付前用第二次运行的程序重跑这两个用例，完整输出在 `out/only-random-3083.log`、`out/only-random-3915.log`。可以看到 D113 的相邻窗口之间有约 1.2e-7 s 的重叠或空隙，有样本落在所在窗口的起点之前；新实现的窗口首尾相接。
  - `history/run1/main.swift` 是加了 `R6_ONLY` 之后才复制的，第一次运行的源码是它去掉 `R6_ONLY` 那一段。
  - 第二次运行只把差异计数按整秒／非整秒间隔分开（`history/run2-main.diff`），两次共有的结果行逐行相同。

### 验证

这一轮没有跑完整门禁，也没有运行任何会开窗口的测试。

**构建**（私有目录，不安装）：

- 先 Debug（exit 0，108 s），再 Release（`-c release -enable-testing`，exit 0，601 s），依次进行。
- 构建前后的源码哈希相同（`builds/`）。

**预跑**（`pre/`）：Debug 构建完成后、Release 构建进行时，单独跑了 `GeekHistoryAveragingTests`：14 个，0 失败，exit 0。这个类没有计时断言。

**Codex 探针**（`probe/`）：

- Codex 的 `Probe.swift` 不改，从复核目录读取（SHA-256 `35983f00…`）。
- 按它的 `run.mjs` 编译（`-D NEW_API`、`-swift-version 6`、`-O -wmo`），分别链接这一轮和 D113 的 Release 构建，跑四种边界模式。
- 矩阵模式会设置易失参数域，属于 R7，没有跑。

| 构建 | 原始 | 正好 | `nextUp` | `nextDown` |
|---|---|---|---|---|
| D114 | 9/9，exit 0 | 9/9，exit 0 | 9/9，exit 0 | 9/9，exit 0 |
| D113 | 9/9，exit 0 | 9/9，exit 0 | 0/9，exit 1 | 0/9，exit 1 |

D113 的四份日志与 Codex `run3/` 里的逐字节相同。

**整帧**（`framedump/`）：

- 做法：第十五节的整帧程序 v1（源码不改）链接这一轮的 Release 构建。参数域放四组环境暂停：无、433 条、512 条、329 条边界暂停，都不注入。输出逐字节对比第十五节 D113 构建的 B。
- 四组各 2,897 行，每组只有 2 行不同。这两行是磁盘帧 `counters-1d-nonfinite`，时长一天，参考时间 r30，两种 plot 各一行：
  - 桶数和非空桶数不变；
  - 计入的样本多 1 个：9,171 → 9,172，边界暂停组 7,873 → 7,874。
- 其余折线、CPU、磁盘、显式暂停和输入行全部相同。

**整帧差异的解释**（`framedump/explain/`）：

- 做法：同一程序加一段只在 harness 里的代码，用同样的输入分别调用这一轮的 `windows()` 和 D113 对照，输出归属不同的样本。只跑了无暂停组。
- 结论：这两行的差异是第 0 个样本：
  - 它正好在范围起点，测量区间从起点前 5 s 开始；
  - D113 丢掉它；
  - D114 在首窗口 `[+0, +114 s)` 按一次观察计入，权重 1。这就是 Z 类。
- 同样的样本还出现在 6 个 stored-28d 帧里，但这些行没有变：
  - 这 6 帧是一天、七天、28 天三种时长 × 两种 plot，参考时间 r30；
  - 压缩输入经 `GeekCompressedHistoryProjection.buckets` 按存储的覆盖记录重算每个桶的样本和权重，只保留窗口的几何。
- 解释程序输出的帧与上面新的无暂停组逐字节相同。

**定向 xctest**（`targeted/`）：

- 选择、夹具和命令都与第十五节相同；`targeted/selection.txt` 说明了为什么 D113 的选择仍然覆盖这一轮。
- 一次只跑一个，没有与构建或其他计时工作并行。

| 运行 | 夹具 | 范围 | 结果 |
|---|---|---|---|
| Release A | Codex 的 512 条合成暂停（参数 SHA-256 `929390a9…`） | 15 个整类，加 5 个类的部分方法 | 290 个，0 失败，0 跳过；计时项 p95 3.67 ms（阈值 100 ms，44k 点、20 次不变） |
| Release B | 一条覆盖 2000–2100 年的暂停 | 计时项和 R7 测试 | 2 个，0 失败；计时项 p95 3.74 ms |
| Debug A | 同 A | 同 A | 297 个，跳过 1 个（计时项原有的 `#if DEBUG` 跳过），0 失败 |
| Debug B | 同 B | 同 B | 2 个，跳过 1 个（同上），0 失败 |

- 每次运行，显示闸门日志只有一条 `installed`（denyAll），没有窗口。
- 测试二进制在运行前后哈希不变。
- 运行时机器上有用户自己的进程，只记录，没有动：Google Drive 约占 0.9–1.0 个核，1 分钟负载 5.5–7.9（`targeted/logs/*.conditions`）。

**反证**（`mutant/`）：

- 复制一份包，只把 `GeekHistoryAveraging.swift` 换回 D113 版本（`ad49ba5b…`），保留这一轮的测试。
- Debug 构建 exit 0。只跑新测试：exit 1，684 处失败，九种间隔都有。
- 日志里含 `: error: ` 的行有 686 行，多出的 2 行是“披露”里说的 CoreData 消息。

**exit 1 与失败的记录**（都保留在证据里）：

- 等价程序的灵敏度运行（链接 D113 构建）三次都 exit 1，这是预期结果：
  - 先用随机 200 例试跑：172,531 例报出问题（`out/pre-sensitivity-d113build-r200.log`）；
  - 第一次、第二次正式运行：各 174,892 例（`history/run1/`、`out/`）。
- Codex 探针链接 D113 构建时，`nextUp`、`nextDown` 两种模式 exit 1。
- 反证 exit 1。
- 新实现的运行没有失败。

**辅助参考**：JEV（jev-latest）评审这次改动，评分范围 0–2：correctness 1.94，spec_match 1.96，test_gap 0.09（越低越好），safe_to_apply 0.76。blast_radius 一项置信度为 0，所以给出 escalate（需要人工复核），这一轮交给 Codex 独立复核。

### 定向范围：运行与 NOT RUN

运行范围和 NOT RUN 清单都与第十五节相同：15 个整类、5 个类的部分方法，NOT RUN 的清单和理由不变。见第十五节和 `targeted/selection.txt`。

为什么不用重新选：

- 这一轮只改 `windows()` 一个函数。D113 改过这个文件，它的选择就是按这个函数的全部调用方和改动文件的读取方做的。
- 没有测试把 `GeekHistoryAveraging.swift` 当作文本读。
- D113 改过的另外三个文件与 D113 逐字节相同，D113 静态核对过的源码断言仍然成立。

**这一轮另外没有做的**：

- 完整的 Release／Debug 门禁和性能脚本；
- 57 个显示类、签名后的运行时、界面验收；
- Codex 探针的矩阵模式，以及整帧的 C、D、C4、D4（都属于已关闭的 R7）；
- D112 越界的子进程抽样：第十五节做过，这一轮 D112 只作对照，越界由跳过版记录；
- 实时传感器、真实路径和显示类的测试。

### 披露

**CoreData 消息**：

- 现象：xctest 日志里有 CoreData 消息。测试进程里有系统框架尝试经 XPC 连接 `com.apple.contactsd.persistence`，打开通讯录存储，连接失败（`NSCocoaErrorDomain` 4097）。
- 出现次数：
  - 这一轮的 CoreData 行：Release A 68 行，Debug A 138 行，预跑 17 行，反证 2 行；
  - D113 的定向日志里也有：Release A 102 行，Debug A 204 行；
  - Codex `run3/` 的 xctest 日志里没有。
- 产品和测试源码都不引用 Contacts，发起方没有查明。

**并行运行**（都不是计时工作）：

- 整帧的四组运行是并行的。
- 这三项是在这一轮 Release 构建进行时做的，都不依赖这个构建：
  - 预跑；
  - 把等价程序链接到 D113 构建；
  - 随机 200 例的灵敏度试跑。
- 计时项所在的定向运行开始前，确认过这一轮没有别的进程在运行。

**对第十五节的更正**：

- 第十五节“行为变化”里说的 `nextUp` 情形（D113 harness 里各 6,018 个），就是 D113 那一行造成的错分，这一轮撤回。
- `nextDown` 的反向窗口也修了。

### 限制

- oracle 是独立的整数实现，但只覆盖整秒间隔和网格上的输入。非整秒间隔和网格外的输入只有性质检查。
- 等价性是有限输入上的逐位比较加上推理，不是形式证明。
- 极端无效日期（换算 `Int64` 时溢出）的陷阱没有处理，Codex 不要求。
- 定向不是门禁。计时项 p95 只说明这几次运行没有超过阈值，wall-clock 计时仍受机器状态影响。
- 解释程序只在无暂停组跑。其他三组同样的两行，是按同样多计 1 个样本推断为同一原因。

### 哈希（SHA-256）

| 文件 | 改前（D113 交付版本） | 改后 |
|---|---|---|
| `Sources/StorageCleanerMac/Views/MenuBarAdvanced/GeekHistoryAveraging.swift` | `ad49ba5b7dc2b7744fb00b5eafd9a1d1e07b7c667b71d4a74f9c2e016d21aef3` | `df01205b5125e747d1845acb5a44e362e65a2a054e4e1a273bd5e7dfa31fc596` |
| `Tests/StorageCleanerMacTests/GeekHistoryAveragingTests.swift` | `9978dd20fce3f3321639e512b6d8a550cfc3ade1a1d007889679b45e22012504` | `61fb9f75867795183f070a6f503fdf77f4a0e901b2ed12f31760e4b643ecf3cf` |

D113 改过的另外三个文件这一轮没有改，与 D113 的改后哈希相同：`MenuBarPreparedChart.swift`、`MenuBarGeekCharts.swift`、`MenuBarPerformanceRegressionTests.swift`。

证据目录的 `change/` 里还有：

- `unchanged.sha256`：上面三个文件和其他依赖文件的哈希；
- 文档改前和改后的哈希；
- 只含这一轮的差异。

## 十七、Codex 复核 D114 后：E1 勘误与暂缓替换下的打包准备（D115）

起因：Codex `CODEX_D114_REVIEW_PREP_FINISH_20261016_2215`（复核记录 `~/Developer/reverse-engineering/cleaners-monitors-2026-10-15/acceptance-2.0.1-20261016/review-d114-20261016-2210/REVIEW.md`，本轮只读）。R6 在源码和定向隔离回归层面关闭，R1–R5、R7 保持限定关闭。Codex 要求不再改产品代码，也不重复已通过的大批回归，只做两件事：

1. E1［P2，证据与 runner，不是产品缺陷］：新增勘误，把以后的 none 调用改成显式的空夹具；已交付的证据目录和清单不改。
2. 暂缓替换下剩余可安全做的打包准备。

这一轮没有改产品代码、测试或仓库脚本，只改了三个文档。证据是新的增量目录 `~/Developer/StorageCleanerMac-evidence/2.0.1-reverse-engineering/d114-review-prep/`。

### E1：整帧的 none 组不是隔离的空夹具

Codex 指出：

- `d113-r6-recheck/framedump/run.zsh` 的 none 分支是 `none) reply=()`，调用整帧程序时不传暂停参数。文件里是第 17 行，Codex 记为第 18 行。
- 整帧程序 `main.swift` 第 141 行读 `MenuBarSamplingGaps.shared`。它的初始化读 `.standard.data(forKey:)`（`MenuBarSamplingGaps.swift` 第 7、16–18 行）。

所以 none 组是**未注入的默认状态观察**，不是已证明隔离的空输入。`d113-r6-recheck/README.md` 第 19–20 行（Codex 记为 20–21 行）的两句全称说法不成立：

- “已知暂停只通过易失参数域或显式参数传入合成夹具，代码读不到真实的已知暂停”；
- “没有读、写或删除任何真实偏好”。

**前两轮也有同样的写法。** 下面这些运行都没有给出已知暂停键 `menuBar.history.unrecordedIntervals.v1`，按同一标准都改为“未注入的默认状态观察”：

| 证据目录 | 运行 | 脚本与行 | 原来的说法 |
|---|---|---|---|
| `d113-r6-recheck/`（D114） | 整帧 B-none | `framedump/run.zsh:17` | README 第 19–20 行；`run.zsh` 第 8–9 行注释；第十六节“参数域放四组环境暂停：无、…”“无暂停组” |
| 同上 | 解释程序 B-none | `scripts/commands-this-round.txt` 第 263 行（标题写着 no ambient pauses） | 第十六节“只跑了无暂停组”“新的无暂停组” |
| `d112-r6-r7/`（D113） | 整帧 B-none；v2 的 save-none、L-none | `framedump/run.zsh:21`（`v1/run.zsh` 同一行）、`framedump/run-v2.zsh:22` | README 第 11 行；`run.zsh` 第 4–5 行注释 nothing reads or writes a real preference；第十五节“参数域放无、…”“B 的无暂停组” |
| `d106-perf-optimize/`（D112） | 整帧 none-old、none-new；分阶段计数的 0 条 | `scripts/run_framedump.zsh:15`、`scripts/run_stages.zsh:15` | README 第 9 行、第 22–23 行的“无暂停”；`run_stages.zsh` 第 4 行注释 |
| 同上 | 剖析 `profile/out/stages-1.tsv`（无暂停 3 轮） | 交付证据没有记录调用参数（`.meta` 只有时间和负载） | `profile/PROFILE.md` 第 12、18 行。不能确认带了参数，按同一标准不算隔离 |

这些运行的原始输出记着 `known-pauses 0`，分阶段计数和解释程序记着 `gaps 0`。这只说明各进程当时解码出 0 条已知暂停，不说明这个值从哪里来，也不能据此断言读到或没读到某个真实保存的值。Codex 没有为此读真实偏好；这一轮也没有读，也没有清除。

**对比结论不受影响。** 只在这些 none 运行之间做的对比（D112 的改前对改后、D113 的 B 对 D112 的 A、D114 的 B 对 D113 的 B），两边都打印了 `known-pauses 0`，而这一行就在逐字节比较的清单里，所以两边观察到的暂停状态相同。这是同一观察状态下的对比，不是隔离的证据。C、D、C4、D4 与 B-none 的对比，本来就是比较不同的暂停；B-none 那边观察到的是 0 条。R6、R7 的关闭不变（Codex）。

**收回的说法与今后的说法**

- 收回上表所列 README、注释，以及第十四至十六节里的全称说法：“代码读不到真实的已知暂停”“没有读、写或删除任何真实偏好”“不写任何偏好设置”，以及把 none 组叫作“无暂停组”或“参数域放无”。原文件不改，以本节为准。
- 不换成别的全称保证。所有进程（xctest、等价程序、整帧程序）都用 Foundation 或 AppKit，框架会读 `.standard` 的其他键。对其他键和框架行为不作任何保证。
- 按证据只能说下面几点：
  - 已知暂停键：D114 的定向 xctest、Debug 预跑、反证测试，以及整帧的 433 条、512 条、329 条组，都通过参数域给出合成夹具；等价程序和 Codex 探针运行过的四种模式不访问共享暂停；上表的运行没有给出这个键。
  - 五个证据目录里的脚本、Swift 源码和命令记录，逐个检索：没有执行 `defaults` 读、写或删，也没有直接打开 `Library/Preferences` 下的文件。放宽到任何 `defaults` 字样以及 `Preferences`、`plutil`、`PlistBuddy`，命中的只有注释、测试用例的标签，和 D113 参数域探针（`d112-r6-r7/argprobe/main.swift`）在临时目录的绝对路径套件里读写、再删除它自己的键。全文检索的其他命中都在文档正文、文档副本和差异里，例如第十四节“建议（没有执行）”里写的清除命令（`e1/defaults-grep.txt`）。整轮的逐条命令记录只有 D114 的 `scripts/commands-this-round.txt`；D113 只有探针的 4 行 `argprobe/commands.txt`，更早几轮没有。没有命令记录的部分只能按脚本说。
  - 整帧程序、解释程序和剖析程序的源码只调用共享暂停的 `intervals(at:)`，没有调用会写这个键的 `begin` 或 `end`，也没有 `set` 或 `setVolatileDomain`。产品里写这个键的只有 `MenuBarSamplingGaps.end(_:at:)`，调用方是 `ScanStore` 的暂停操作和 `SystemEnergyAccumulator` 的睡眠观察。

**修正：以后的 none 调用**（`e1/framedump/run.zsh`）

在 D114 的 runner 上改了这些：

- none 组在进程自己的易失参数域里放显式的空列表 `[]`（`e1/framedump/fixtures/empty.arg`，内容 `<5b5d>`），传法和其他三组相同；
- 任何一组找不到夹具，就在开始前拒绝运行（exit 2），不再退回到不传参数；
- 运行前清掉 `FRAMEDUMP_INJECT` 等变量，把每次运行的参数个数、键和值的 SHA-256 写进 `args.txt`；
- `FRAMEDUMP_BIN` 可以换成假执行器或探针，这时不做比较。默认用 D114 的整帧程序，先核对它的 SHA-256 与交付的 `framedump/SHA256SUMS` 一致；
- 不链接、不构建，只写指定的新输出目录。

与交付版的差异见 `e1/framedump/run.zsh.diff`。

**验证**（`e1/check/`，没有运行真实的整帧程序）

`check.zsh` 的 41 项全部通过，exit 0（2026-10-16T11:27:12Z–11:27:16Z）：

| 检查 | 结果 |
|---|---|
| 交付的 `run.zsh` 第 17 行就是它的 `ambient()`，单独执行这一行 | none 给出 0 个参数，其他三组各 2 个 |
| 把旧 none 的参数交给假执行器和探针 | 假执行器收到 0 个参数；探针在参数域里找不到这个键，不向 `.standard` 查这个键，以 3 退出 |
| 新 runner 加假执行器（只记参数，不用 Foundation） | 四组都是 2 个参数：第 1 个是暂停键，第 2 个的 SHA-256 等于夹具文件的值；none 的值是 `<5b5d>`；都没有注入 |
| 新 runner 加 Foundation 探针 | 四组都 exit 0。键在进程的参数域里，类型是 data；`.standard.data(forKey:)` 返回的就是这个值；按 `MenuBarSamplingGaps.init` 的方式解码出 0、433、512、329 条。none 的值是 2 个字节 `5b5d` |
| 负对照 | 探针不带参数时以 3 退出；新 runner 遇到没有夹具的组以 2 退出，不建输出目录 |

探针只链接 Foundation（`otool -L` 见 `e1/check/out/probe-linkage.txt`）。它在参数域里找到这个键以后，才向 `.standard` 查这个键；它说明的只是这一个键。

**NOT RUN**：用真实的整帧程序重跑四组（Codex：没有新理由，不要求重跑）。所以交付的 D114 B-none 仍是未注入的默认状态观察；不断言显式空夹具的输出会与它相同。

### 暂缓替换下的打包准备

结论：现有的测试版打包路径在签名时可能弹出钥匙串授权框，按要求没有执行。这一轮没有构建或组装任何 App 包，只做了只读核对。

**打包入口**（`script/` 下的现有脚本，只读，没有运行）

| 入口 | 做什么 | 启动、退出或替换 | 签名 | 本轮 |
|---|---|---|---|---|
| `build_and_run.sh --beta`（不带 `--install`） | 构建测试版配置，在 `/tmp/storage-cleaner-beta-package` 组装，再复制到 `/tmp/storage-cleaner-beta-dist` | 不启动，不退出，不安装 | 第 216–223 行把临时签名换成钥匙串里第一个 Apple Development 或 Developer ID Application 证书；第 797–809 行要求非临时签名、hardened runtime 和团队。codesign 使用私钥时可能弹出钥匙串授权或解锁框（第四节第 1 步已记） | NOT RUN：签名可能弹出未受控的系统授权窗。另外它默认会跑 `verify_menu_bar_performance.sh`（`swift test`，不带暂停夹具）；产物是磁盘上第二个测试版身份的包，LaunchServices 是否会登记它，无法证明 |
| `--beta --install`（含 `--no-launch`）、`beta_install_swap.py` 的 `swap` 和 `place`、`launch_beta_acceptance.sh` | 安装、替换、启动 | 是 | 同上 | NOT RUN：用户暂缓替换 |
| `build_and_run.sh --bundle-only` | 组装正式身份的包，不启动 | 否 | 默认临时签名，不用钥匙串 | NOT RUN：不是要替换的测试版产物。包用正式版的 bundle ID（启动后与已装正式版共用数据和偏好），磁盘上会多一份正式身份的包；默认也会跑性能测试 |
| `build-release.sh --package`、`make_release_dmg.sh`、`notarize_release.sh` | 发布打包、Developer ID 签名、公证 | — | Developer ID；公证要提交给 Apple | NOT RUN：`--package` 要求干净且正好在 `v2.0.1` 标签上的 HEAD，不提交就不满足；发布和公证不在授权内；不绕过门禁 |
| `build-release.sh --candidate`、`verify.sh`（`STORAGE_CLEANER_VERIFY_BUNDLE=1`） | 全量构建和测试，然后组装 | — | — | NOT RUN：全量测试超出本轮范围 |

**现有产物与指纹**（`pkg/`，只读）

- 已装的两个 App：按 Codex 的基线（`install-baseline.json`，每个 340 项）逐项比对类型、大小、权限，以及 SHA-256 或链接目标。两个都是 0 处变化、0 个新增项（2026-10-16T11:31:50Z）。
  - 测试版：`com.local.StorageCleanerMac.beta` 2.0.1，build 20261013152803，BuildInfo commit `6e660a59f7b6`、dirty=false，主程序 `79cf0bb4…`；
  - 正式版：2.0.0，build 20261012230050，commit `545049117b24`，主程序 `95a9d7b8…`；
  - 签名用 `codesign -dv` 读取，只显示，不校验，不联网。两个 App 都是证书签名；App、两个 helper、更新口令程序（测试版还有 Finder 扩展）属于同一团队；测试版与正式版也是同一团队。证据里不记团队 ID 和证书名。
- 当前源码的私有构建只有第十六节的 `r6fix/rel` 和 `r6fix/dbg`。它们是 SwiftPM 产物（`-enable-testing`），链接器临时签名，不是 App 包，不能安装；哈希与第十六节交付的 `builds/products.sha256` 一致。任务临时目录里另有一份 15:21–15:38 的 SwiftPM 构建（`beta-release/`），早于 D112–D114，不代表当前源码。`/tmp/storage-cleaner-*` 都不存在，所以当前源码没有组装好的 App 包。任务临时目录里唯一的 `.app` 是 D106 检查脚本函数用的夹具（`actfx/`，可执行文件是一行 `sleep` 的 shell 脚本，没有 Info.plist），不是构建产物。
- 当前源码清单（HEAD 加 1,430 个文件）与 D114 构建时的清单逐字节相同（`pkg/source-now.sha256`）。工作区有未提交的改动，现在组装的测试版 BuildInfo 会是 commit `6e660a59f7b6`、dirty=true，看不出具体是哪份源码。

**以后执行时的准备说明**（用户另行批准替换后，由 Codex 执行）

- 仍按第七节的前提和步骤；本轮没有改第七节。前提 2 写的进程状态已经变了，见下面“环境变化”。
- 第 2 步之前先记源码清单（`d113-r6-recheck/builds/build.zsh` 里的 `manifest` 函数），应与 `pkg/source-now.sha256` 相同，不同就停。
- 第 2 步默认会先跑 `verify.sh` 和 `verify_menu_bar_performance.sh`（Codex 的 STATUS 已记）。设 `STORAGE_CLEANER_SKIP_TESTS=1` 会跳过这些测试并打印 NOT RUN，签名、架构和更新配置检查仍保留。用哪种由 Codex 在执行时决定；跳过的测试仍算未测。
- 组装签名时如果弹出钥匙串框，按第七节由 Codex 判断是否继续。
- 安装后用 `pkg/fingerprints.py` 的同样做法读新包的身份和签名（基线比对那部分换掉），不记团队 ID 和证书名。

### 环境变化：本轮开始前系统重启过

打包时只读核对进程（`pkg/processes.txt`）才发现：

- 系统启动时间是 2026-10-16 22:01:08（11:01:08Z），早于本轮开始的 11:16:12Z。D114 交付前（10:47:55Z）核对时，正式版 PID 1174 和旧测试版 PID 33383、33384、33402 都在运行；D114 交付后，本会话从 10:48:57Z 到 11:16:12Z 没有运行任何命令。`last` 有这次 reboot 的记录，没有对应的 shutdown 记录。重启的原因、这些进程是随重启结束还是在重启前退出，本轮没有查。
- 现在：正式版是 PID 1519（22:03:04 启动）；测试版只有 Finder 扩展 PID 1370（22:02:58 启动），测试版主程序和风扇 helper 都没有在运行。本轮没有动它们。
- 影响：第七节前提 2 写的旧测试版进程已经不在；它们结束时有没有写 SMC 或 pmset，没有观察，仍算未测。以后执行替换前，按当时的进程重新核对第七节的前提 2 和回滚条件（现在测试版的 Finder 扩展在运行）。本轮不改第七节。

### 未测清单（按层）

| 层 | 已有的证据 | 未测 |
|---|---|---|
| 源码 | R1–R7 在源码和定向隔离层面关闭（Codex）；E1 只涉及证据 | 当前源码没有跑完整的 Release／Debug 门禁。最后一次是第十四节 D112 的门禁 5，之后 D113、D114 只做了定向 |
| 构建 | 私有 Debug、Release（`-enable-testing`）构建都 exit 0（第十六节） | 测试版配置（`STORAGE_CLEANER_BETA`、`-g`）的构建和 App 包组装 |
| 签名 | 已装两个 App 的签名只读显示 | 新包签名（可能弹钥匙串框，NOT RUN）；Developer ID、公证、Sparkle 更新源 |
| 安装 | 已装两个 App 与基线逐项相同 | 替换 `/Applications/测试版.app`（用户暂缓） |
| 界面 | 闸门和测试窗口的隔离测试（第八节） | 验收启动、57 个显示类、截图 |
| 实机 | 无 | helper 生命周期；风扇、电源、SMC；Mac mini 模式；旧测试版退出时的硬件写入（旧测试版进程已不在，结束时有没有写硬件没有观察）；真实清理；实时传感器；真实路径；完全磁盘访问。G11 等用户决定，G12 不扩大 |

### 验证

- E1：`check.zsh` 41/41 通过，exit 0。
- 指纹：`fingerprints.py` exit 0；源码清单相同。
- 之前五个证据目录（178／139／113／595／129 个文件）用各自的 `SHA256SUMS.txt` 复核，全部 OK。
- JEV 的结果见证据目录 `jev/`。

### 披露

- Codex 引用的行号（`run.zsh:18`、README 第 20–21 行）比文件里的实际行号（第 17 行、第 19–20 行）大 1，内容相同。
- 这一轮在任务临时目录编译了一个只用 Foundation 的探针，运行了假执行器、探针和只读的指纹脚本。没有构建产品，没有运行真实的整帧程序或 xctest。
- 指纹脚本读取了已装两个 App 的文件，并对 App 和嵌套代码运行了 `codesign -dv`。没有启动、校验或注册，也没有调用 LaunchServices。
- 更正：这一节原先写“正式版（PID 1174）和旧测试版（PID 33383、33384、33402）一直在运行，没有动”，是本轮没有核对就写的，不对：本轮开始前系统重启过，这些进程都已不在（见“环境变化”）。这一轮没有启动、退出、替换任何 App 或 helper，没有给它们发信号，也没有重启。

### 哈希（SHA-256）

这一轮没有改代码。三个文档改前、改后的哈希在证据目录的 `change/`。当前源码清单 `pkg/source-now.sha256` 的 SHA-256 是 `766399dadabeab500caa5eb2d5222fe1da331e9bb0cfa08885087544147c0571`。
