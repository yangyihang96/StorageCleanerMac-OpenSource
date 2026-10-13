# r2-macmini-mode 第五轮交接（2026-10-08）

交付位于 `/Users/developer/Developer/.sc-build/r2-macmini-mode/prepared-r5/`，分支 `task/r2-macmini-mode`，补丁相对 `e9173f0724aebf5face8f86e423adb754bcbe821`。主会话已提交第四轮四组，开始时已读回确认 HEAD 与干净工作区。本轮交付11个最终源码、测试、文档文件，当前 worktree 已有最终源码，不要再叠加补丁；干净的同基线工作区才 apply。前四轮 prepared 目录的65个原文件保留并核对 SHA-256，review 和日志不改。

已读完整 `review/review-3.md`，其结论“修一处后可合并”是本轮修改前的独立复核。报告的 JEV 自相矛盾/低置信判断没有采纳为批准。第四轮 `logs/main-r4-151715/mutations/summary.json` 已只读核对64条全部PASS；报告提及的602项定向测试不作为第五轮测试结果。没有修改 ScanStore、Package、AGENTS、private-api allowlist、launchd plist、RULES、DECISIONS、BOARD、第三方致谢或任何硬件白名单。

## 实际验证状态

- PASS：仅 metadata 核对，包括改动范围、空白、pmset 白名单逐字不变、保护文件、launchd plist 解码、测试入口存在、变异before精确匹配、Python AST、`git diff --check`、总补丁和三组补丁的反向 `git apply --check`、最终文件/交付物/前四轮原件哈希。命令及exit code记录在 `static-checks.json`。
- NOT RUN：build、严格并发、XCTest、源码守卫、变异执行、安装、原生验收、硬件、提交。本轮运行测试0；common.md明确要求沙箱实现阶段只准备代码与交付物，不尝试编译、测试或写.git。
- 新增12个行为测试方法；纠正2个既有行为测试，扩展1个既有生产接线守卫。36类定向清单沿用，累计76项单点变异（原64项保留id与filter，新增12项）；本轮均NOT RUN，必须由主会话运行后填结果。
- JEV：实际尝试 `jev_decide` 对比“只读恢复保留存档”与“无锁恢复并写回存档”两种策略。可用工具schema没有模型选择参数；工具返回 `MCP tool call requires approval, but approval policy is never`，模型请求未执行，未获得本轮JEV判断。

## 三项修复

### N3-1：证据未知不能阻止自身睡眠恢复

`MacMiniModeLifecycle.reconcile` 的未知签名、硬件false/nil分支改走共享引擎的 `reconcileUnconfirmedEvidence`。该路径只在已有可信恢复责任时进入电源对账，永远给写1设置拒绝条件，关闭立即睡眠请求。电池或未知电源下恢复0并核对读回，保存mode=whenOnAC、owns=false；AC下不写1，保留原值和意图。没有责任时不清外部值。证据不足仍返回stateUnavailable；命令失败、读回失败、存档失败的具体原因不被覆盖，恢复责任留待重试。真实缺失/签名不符仍走已有applicationRemoved，未改其安全语义。

SIGTERM继续只恢复自身0并保留意图；显式关闭成功则保存用户选择的off。显式关闭不依赖签名/硬件证据，但证据未知时禁止sleepnow。如果关闭意图保存失败，也先尝试仅恢复自己的0，保留原意图/责任/失败状态，不把未持久保存的off报为成功。用户要求中的“保持开启意图”适用于后台对账与信号恢复；不覆盖用户成功保存的主动off选择。

### N3-2：旧格式对方记录不能无限占用

对方v1记录经原有目录0700、文件0600、属主、类型、链接数、大小和JSON校验后，因缺少可核实的安装路径/签名绑定，明确视为过期占用。检查继续检查另一个记录，所以v1 policy不能掩盖有效v2 recovery，反向亦然；不删除或改写对方任何字节。损坏或权限不安全的记录并不伪装成有效v1，仍拒绝开启。v2现有规则不变：确认应用缺失/签名不符后不持有，未知验证仍保留占用。

本方旧记录的恢复责任与“对方是否占用”不同：可信本方v1仍可恢复自身0；正常持锁加载继续按既有迁移规则关闭旧意图。对方有效v2仍须在对应版本关闭并确认恢复，或核实应用移除/签名不符；早期v1无需删记录来解除占用。运行中的旧开发助手不遵守新策略，不能承诺与它同时启用时无竞争，交接需先让它完成恢复并停用。

### N3-3：锁目录异常仍能撤销本方有证据的值

锁初始化失败时不再直接丢弃所有本方证据。Runtime调用 `MacMiniPolicyStore.readRecoveryWithoutLock`：只读打开本方root私有目录和严格校验的文件，不mkdir、不迁移、不隔离、不改存档。有效policy是权威记录；policy缺失/无效才读独立recovery。有效policy已解除责任而旧recovery尚未来得及删除时，以policy为准，不能用过期责任清别方后设的1。未可信验证到责任就不写0，不能从系统SleepDisabled=1猜归属。

生命周期所有事务仍先有界拿锁。恢复事务拿锁失败时，`recoverWithoutPersistence`只能写固定0并核对读回，不写1、不sleepnow、不变更内存的已接受意图/责任或磁盘记录；正常对账只有off或非AC才进入该降级恢复，主动关闭/移除/终止可在AC恢复。新的开启仍返回persistenceFailed，无peer读取、无未持锁unlock、无意图保存。重复看到已为0不反复写；正常持锁后才完成责任的持久收尾。已加载策略临时竞争时可在后续拿锁后收尾；锁目录异常启动时仅加载off/恢复责任，原开启意图字节仍保留，修复后重新加载助手才能恢复正常策略。

存档可写性或互斥故障仍以persistenceFailed返回；0命令失败与读回失败分别返回原有具体错误。应急0成功不意味着记录收尾、持久off或注销成功，应用现有注销门禁继续要求成功、mode=off、owns=false，因此锁未修复前不会假报移除完成。风扇/曲线故障白名单与既有纯恢复通道不改。

中英文提示说明“恢复记录或互斥锁不可用”，要求查看助手日志、修复记录目录或锁目录权限后重新加载。日志明确 `/private/var/db/StorageCleanerMac-MacMiniMode-Lock` 要求root/0700、`owner.lock`要求root/普通单链接0600。本轮不自动修权限、不删未知记录。主会话实际修复须先确认目录/文件属主、类型和原记录，不能仅用chmod将未知内容变成可信。

## 分组与旧断言变更

| 顺序 | 补丁 | 文件数 | 内容 |
|---|---|---:|---|
| 1 | 01-recovery-policy.patch | 3 | 引擎、生命周期及行为测试：未知证据恢复、无锁仅0、关闭保存失败恢复 |
| 2 | 02-archive-recovery.patch | 6 | 旧peer过期、独立恢复读取、Runtime接线、日志/中英诊断、存档与呈现测试及接线守卫 |
| 3 | 03-docs.patch | 2 | 本交接与中英功能说明 |

纠正两条把错误行为固定为预期的测试，依据用户第五轮N3-1及review-3；无需改产品决定文档。方法名和历史mutation filter保留，未删测试、跳过测试或放宽阈值：

1. `MacMiniModeLifecycleTests.testUnknownHardwareTelemetryDoesNotEraseExistingIntentOrSleep`：原unknown能力+unknown电源断言commands/saved为空、owns=true，改为精确 `[disableSleep(false)]`、保存开启意图但解除责任、读回false；增加AC证据未知时仍不写的对照。名称中的“不sleep”继续指不调用sleepnow。
2. `testFalseOrMissingCapabilityPreservesIntentAndSettingsUntilRetry`：改为每个能力/责任/电源组合独立夹具。原一律保留owns和值，改为仅“有责任且非AC”恢复0；其他组合保留值。逐项检查意图、责任、命令、保存、幂等重试，以及证据恢复并接电后重新按意图写1。名称保留供通用runner使用，系统设置保持的范围按本轮授权修正。

`LifecycleSystem` 的“任何硬件写都必须持锁”夹具断言改成精确例外：未持锁时命令必须等于disableSleep(false)，且engine必须仍有恢复责任；所有存档写、peer检查仍强制持锁。新增命令失败/不反映写入的注入，不接真实硬件。其他旧断言保留。`MacMiniModePackagingTests`只增加Runtime调用共享只读恢复与诊断路径的接线断言，不能代替行为测试。

所有存档、锁目录、链接和旧版JSON夹具都在TestFileSystem登记的临时数据根，注入当前uid，不读写真实/var/db。权限异常夹具仍可按既有严格teardown删除。生命周期只有假pmset、假读数/签名/硬件/存储/锁；不启动风扇/应用。语言测试使用既有TestVolatilePreferences并恢复。没有新增真实默认依赖。

## 主会话验证命令与反证

以下命令在沙箱外由主会话执行，本批未运行：

```bash
export DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-macmini-mode/debug --jobs 4
swift build --scratch-path /Users/developer/Developer/.sc-build/r2-macmini-mode/strict --jobs 4 -Xswiftc -strict-concurrency=complete
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-macmini-mode/debug --jobs 4 --filter 'MacMiniModeEngineTests|MacMiniModeLifecycleTests|MacMiniPolicyStoreTests|MacMiniModePresentationTests|MacMiniModePackagingTests|FanControlStartupSafetyTests|FanControlStartupCoordinatorTests'
FILTER=$(paste -sd '|' /Users/developer/Developer/.sc-build/r2-macmini-mode/prepared-r5/targeted-classes.txt)
swift test --scratch-path /Users/developer/Developer/.sc-build/r2-macmini-mode/debug --jobs 4 --filter "$FILTER"
python3 script/check_private_api.py
git diff --check
```

36类包含TestPreferenceHygieneTests、UIConsistencyRegressionTests、现有风扇/曲线/电源/缓存/锁/小窗相关类，不排除ControlPaletteTests。实际执行数量、skip、失败与日志由主会话记录。

`counterexamples.json`格式不变，mutations每项包含id/path/before/after/expected_occurrences/filter。先跑最终绿，再串行逐项变异，运行指定filter并确认具体XCTest断言变红；编译失败、超时、0项、环境权限错误都不算反证。每次恢复完整原字节并核对manifest，不与其他构建并发修改源码。manifest的counterexample_source_sha256覆盖全部目标，包括本轮未改的既有反证目标。

| 问题 | 行为证据与新增单点变异 |
|---|---|
| 未知签名/能力仍恢复 | battery/unknown恢复自身0、AC拒写1、未知无归属不清外部1、意图保留、恢复具体错误不被覆盖；`unknown-signing-must-restore-own-zero`、`unknown-capability-must-restore-own-zero`分别改回未知直接返回，必须失败 |
| 未知证据不请求立即睡眠 | 闭盖battery只出现0；`unknown-evidence-recovery-never-sleeps`改回允许sleepnow，必须失败 |
| 主动关闭保存失败仍恢复 | 只发0、责任与失败保留；`failed-off-save-must-recover`删掉恢复必须失败 |
| 旧peer过期 | v1 policy/recovery不占用、原字节保留、另一个v2仍占用、unsafe仍拒绝；`legacy-peer-claim-expires`取消过期必须失败 |
| 锁异常恢复 | 各操作/电源/意图/责任组合仅许可本方恢复0，其他拒绝；`unavailable-lock-must-recover`改回拿不到锁即返回必须失败 |
| 无锁恢复安全边界 | `unlocked-recovery-requires-proof`去掉责任判断、`unlocked-recovery-only-zero`把0改1、`unlocked-recovery-verifies-zero`跳过读回、`unlocked-recovery-keeps-archive-debt`提前清责任，均必须使行为断言失败 |
| 独立可信存档 | 真实权限错误锁目录不挡可信恢复、存档字节不变；`lockless-reader-retains-proven-debt`丢弃可信责任必须失败；无效目录/链接/文件/JSON/未来版本/无binding不能认领 |
| 旧journal不能复活责任 | 已提交clear policy优先；`lockless-policy-clear-beats-stale-journal`改成先读旧recovery，必须失败 |

原64项id/filter不变，只适配3项before/after定位：`lifecycle-acquires-before-check-and-write`的新恢复回调guard、`false-capability-preserves-intent`的新共享恢复调用、`unknown-signing-preserves-intent`的新恢复调用。`unknown-capability-does-not-clear-intent`仍用原单点条件变异，由加强后的AC对照检出。新增12项加原64项共76项，全部NOT RUN；历史64 PASS不能替代这一轮执行。

## 尚待原生验证与限制

本轮没有安装、SMAppService注册、launchctl、pmset或IOKit写入，没有启动应用/助手。主会话先完成构建、行为/变异和独立复核，再在已有用户授权范围内做隔离实机验收：

1. 未知签名窗口、开机能力false/空期间拔电：实际恢复0、没有sleepnow、意图保留；证据恢复后接电再按意图生效。未知电源也只恢复0，不能猜AC写1。SIGTERM/关机与主动off分别核对意图语义。
2. 仅用隔离目录/注入方式模拟锁权限错误，不故意损坏真实/var/db：独立证明本方责任，0读回、无写1/睡眠、诊断准确、旧存档不变；恢复正常持锁后收尾。确认正常启动仍服务风扇/其他电源功能、无launchd失败循环。
3. 临时锁竞争已加载责任时可降级恢复；冷启动尚未取得锁时保持5秒延后加载、不从未知状态认领；有限6次/1.55秒退避保留。真正永久争用、强杀、无收尾时间的关机仍不能保证即时恢复。
4. 旧v1对方记录过期但原件不删；本方v1责任照常恢复。正确v2peer仍阻止开启、未知v2不被误判为释放。旧开发助手和外部pmset工具不参加互斥，不能从单个系统布尔值辨认最后写入者。
5. 第四轮的真实XPC故障关闭/注销、更新时签名缓存失效、签名校验时间、2秒包替换窗口、连接15秒稳定、桌面隐藏和中英文界面仍按既有交接验证。无锁应急0不会越过应用注销门禁；应先修复记录/锁并正常收尾。

可信本方目录或两份记录都不可读时，无证据就不改外部值；这不是恢复成功。锁异常下存档收尾刻意留待修复，不能声称已安全注销。上述原生验收全部NOT RUN，本轮交付是可验证源码和补丁，尚不声称可合并或已安装可用。
