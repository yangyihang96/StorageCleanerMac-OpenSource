# Mac mini 模式功能说明草稿（第五轮）

当前源码基线为 e9173f0，主会话已提交第四轮修复。已读 review-3 全文，本轮处理未知证据下的恢复、旧格式对方占用和锁目录异常恢复；第四轮64项变异汇总只读核对为PASS。第五轮最终源码尚待主会话构建、测试和实机验收，当前说明不代表已安装版本支持此功能。

入口位于小窗“电源”的电源管理浮层与普通电源页。只在确认有内置电池、并能读取合盖能力的 Mac 上显示；台式 Mac、没有合盖能力或能力未确认的设备不显示。只有“关闭 / 插电时开启”两档，没有“始终开启”。

开关文案为“Mac mini 模式：插电时不睡眠（合盖也继续运行）”，开启提示为“拔电后自动恢复睡眠”。`disablesleep 1` 禁止插电时的全部系统睡眠，包括自动睡眠及合盖睡眠，不只是改变合盖行为。系统助手保存模式；退出应用后继续对账，重启后恢复意图。未授权时面板不常驻警告，用户尝试开启才提示现有系统助手的授权流程。v2 助手仍须先更新并重新授权。

拔电后，助手恢复允许睡眠。只在已核对实际发生 1→0、最新电源来源可确认、最新合盖与合盖会导致睡眠均为真时，才请求 `sleepnow`。外接显示器使系统回报合盖不会睡眠时，不请求立即睡眠。电源、合盖或旧禁止睡眠值未知时，不猜测这些条件。用户在已合盖的机器上显式关闭模式也可能触发这条规则，远程连接可能因此中断。

SIGTERM/SIGINT、应用移除或签名身份变化、损坏记录的安全恢复均不请求 `sleepnow`；仅撤销本助手有可信恢复责任的 `disablesleep 1`。收到信号时保留仍有效的开启意图供启动后对账。应用被移走或签名不符则先清除意图再恢复。外部已设 1 且本助手未写入时，关闭或终止不改该值。开启期间按电源策略纠偏；恢复责任不等于能识别最后写入这个布尔值的外部工具。

记录绑定安装路径与助手的签名身份（Team ID；没有 Team ID 时使用从助手指定要求导出的应用要求），不绑定设备号或 inode。同路径、同签名身份的包替换更新保留意图。路径来自正在运行的助手的 `Bundle.main.executableURL`，不使用 `argv[0]`；固定旧式 helper 路径不能开启本模式。监视器遇到包替换事件后重新检查路径与签名，并重建监视。第一轮 v1 记录没有可证明的路径/签名绑定，首次迁移到 v2 时关闭旧意图，只保留可信恢复责任；以后的同身份更新不会关闭模式。v1迁移遇到助手签名未知时，保留可信原记录和恢复责任，待确认后迁移；不构造空身份，仍按v1规则禁止旧开启意图生效。已经关闭的策略可继续重试恢复自身0。

root 记录目录为 `/private/var/db/StorageCleanerMac-MacMiniMode`，Beta 使用 `StorageCleanerMac-Beta-MacMiniMode`。目录 0700、普通单链接文件 0600，拒绝符号链接、错误属主/权限和损坏 JSON。写 1 前分别持久保存 `recovery.json` 与 `policy.json`；恢复责任有独立证据，意图文件损坏仍可安全恢复。无法验证的记录按关闭处理、记录具体原因，不能从系统当前 1 猜归属。有可信恢复记录才尝试 0。损坏意图在可信私有目录中改名保留；不自行修正未知目录权限。记录不可用时拒绝新的开启，但助手的风扇与其他电源模式功能继续可用，启动不因本模式存档错误而失败或被 launchd 循环拉起。修复记录后需重新加载助手以重新验证存档。

正式版与 Beta 共用一把 root 文件锁，在同一锁内检查另一版本的开启意图或恢复责任、保存本版本意图、执行命令并核对。另一身份仍持有时拒绝开启并提示先在那里关闭或移除助手。对方记录中的应用路径实际已不存在或签名明确不符时，核实后不再视为持有；读取或签名未知仍保守保留占用，不删除对方记录。对方记录不可读时也拒绝抢占。先在持有版本关闭并确认责任解除，再在另一版本开启。外部工具及尚未升级到本轮的助手不遵守这把锁；自身有可信恢复责任的0不会被peer占用阻挡；正常路径持锁，锁不可用时允许仅恢复0的降级路径；没有责任时不清对方的1。若旧版已留下双方持有的冲突记录，先在对应版本关闭并确认责任解除；后台项停用时先允许它完成恢复。已通过目录和文件安全校验的v1对方记录缺少安装签名绑定，按过期占用处理，原文件不删除；对应助手仍可用它恢复本方值并迁移。v2未知校验或损坏记录继续阻止抢占，需有证据地修复，不能删除未知记录绕过。

关闭且无恢复责任时撤下本模式的计时器和监听。助手只有在最后一个 XPC 连接断开、无待办、无风扇工作、也无模式常驻需求时才允许 15 秒空闲退出；已连接应用不会因这个计时器收到连接中断。开启意图或待恢复责任继续保持助手对账。正常注销仍先确认睡眠恢复、再恢复风扇、最后移除服务。读回不一致、命令失败和恢复未完成会显示真实原因，不把开关状态当作系统实际设置。

如果助手启动时不能恢复上次崩溃遗留的风扇控制，会先执行 Mac mini 模式的安全收尾，只撤销自身有证据的禁止睡眠值，不请求立即睡眠。之后明确提示“启动时未能恢复风扇自动控制，已禁用风扇写入和曲线控制。请检查风扇状态；如需重新启用，请移除并重新授权系统助手。”故障状态仍允许读取睡眠状态、关闭模式和恢复自身睡眠责任；不需要先取得风扇ready，且不能sleepnow。确认mode=off及责任解除后可移除助手，不追加风扇写入，明确风扇自动状态仍未确认。睡眠恢复失败则保留责任并提示，不能冒充移除成功。故障重连动作隐藏，自动恢复/连接重试停止；修复后移除、重新授权，让新进程核对风扇恢复成功才允许正常控制。原故障进程不启动正常计时器，最后断连且待办清空后成功空闲退出，保留风扇恢复标记，不被launchd无限重启。Mac mini存档坏但风扇恢复正常时，其他风扇/电源功能仍可用。

已开启模式对账时，硬件能力暂时为否或未知（含开机电池列表尚为空）、签名读取暂时失败，只阻止写入1，保留开启意图。电池供电或电源来源未知时，只要本助手有可信恢复责任，仍恢复0并核对读回，且不请求sleepnow；没有责任则保留外部值。插电时不写1，显示未确认并稍后重试。SIGTERM同样恢复自身0并保留意图；显式关闭成功会按用户选择保存off，证据未知不妨碍恢复。关闭意图保存失败也先恢复自身0，保留记录与失败状态，不谎报关闭成功。只有明确应用移除或身份不符才自动清除旧意图。签名验证按路径与修改信息缓存，包替换/watch事件或修改信息变化才完整重查，未知结果不缓存。

共享锁有6次有限尝试和合计1.55秒退避，恢复也使用同一策略。开机锁暂忙则保留待加载任务，5秒再试，加载后回到60秒兜底；不持久改为关闭。已加载可信责任时，有限拿锁失败后可恢复自身0，不写1、不sleepnow、不改存档；责任保留至正常持锁收尾。开机锁仍忙且责任尚未加载时，继续延后加载，不猜测所有权。强制终止不能承诺即时完成。

锁目录本身权限或类型异常时，助手独立只读校验本方存档目录0700、属主root、文件0600/普通单链接且非符号链接，从可信policy读取恢复责任；policy缺失或无效时才尝试独立recovery。已提交责任解除的policy优先于尚未删除的旧recovery，避免误清后来由别方设的1。不会迁移、隔离或改写存档，也不会自动修权限；本方v1可信责任仍可恢复。仅允许撤销自身值并核对0，存档中的原开启意图保持不变，新的开启仍失败。界面提示检查日志并修复记录或锁目录权限；日志明确 `/private/var/db/StorageCleanerMac-MacMiniMode-Lock` 需root/0700、`owner.lock` 需root/普通单链接0600。修复并重新加载助手、正常持锁完成记录收尾后才能确认责任解除。应急0成功不等于持久关闭或注销已成功。

## English draft

Mac mini mode is offered in the mini window's Power management palette and
compact Power page only on Macs with an internal battery and confirmed clamshell
capability. Desktop Macs and unsupported or unconfirmed devices do not show it.
The two choices are Off and On AC.

The label is “Mac mini mode: no sleep on AC (runs with lid closed)”. Its enabled
notice is “Unplugging automatically restores sleep”. On AC, the helper disables
all system sleep, including idle and lid sleep. It retains the selected policy
after the app quits and reconciles it after a restart. An unapproved helper does
not produce a persistent warning; authorization guidance appears when the user
tries to enable the mode.

Unplugging restores sleep. Immediate sleep is requested only after a verified
1-to-0 transition, a known fresh power source, and fresh readings confirming a
closed lid that should cause sleep. External-display operation and unknown
readings do not meet these conditions. Explicit Off on a closed laptop may also
request sleep and interrupt a remote connection.

SIGTERM/SIGINT, application removal or signing changes, and damaged-record
recovery never request immediate sleep. They restore only this helper's proven
setting. Termination preserves valid intent; removal or signing mismatch clears
it. External values without this helper's recovery proof remain untouched.

Intent is bound to the installation path and the helper's signing identity
(Team ID, or a derived designated requirement). Replacing a bundle at the same
signed path preserves it; device and inode numbers are not used. The path comes
from the running executable's Bundle URL, never argv. The first migration from
the earlier v1 archive clears unprovable old intent while preserving trusted
recovery debt. Subsequent updates retain intent. If helper signing is unknown during v1 migration,
trusted recovery evidence stays in place until verification and restoration;
no empty signing identity is invented, and unprovable v1 intent remains Off.
An already Off policy can continue retrying its own restoration.

Invalid archive permissions or damaged JSON degrade to Off with a recorded
reason. A separately protected recovery journal may prove ownership; the system
sleep boolean cannot. Invalid Mac mini records do not prevent the helper from
serving fan control or other power modes. New enable requests remain blocked
until persistence is repaired and the helper is reloaded. Damaged intent evidence
is retained by renaming it within a validated private directory.

Release and Beta helpers use the same root lock. They check the other identity's
intent and recovery debt before saving or writing. A held or unreadable peer
policy blocks enabling. A verified absent or signing-mismatched peer app no longer
holds the setting; unknown validation still reserves it without erasing evidence.
Turn the mode off or remove the helper in its current owner before switching.
Our proven sleep-restoration obligation can write 0 even while the peer holds
intent; unowned policy cannot clear the peer's value. A validated v1 peer record
has no verifiable installation binding and is treated as expired occupancy. Its
bytes remain for its own helper to restore and migrate. Unknown v2 validation
and unreadable data still block enabling.
External tools and older helpers do not participate in this lock.

Clean Off permits idle exit only after the last XPC client disconnects and all
pending requests and fan work have finished. Enabled intent or recovery debt
keeps reconciliation resident. These behaviors still need signed SMAppService,
XPC, reboot, update and hardware acceptance. Forced killing, abrupt power loss
and forced removal without shutdown time cannot be certified by injected tests.

If startup recovery of fan control fails, the helper first prepares Mac mini
mode for termination, restoring only its proven setting and never requesting
immediate sleep. Fan writes and curves remain blocked, but sleep-state reads,
Off and restoration of its sleep obligation remain available. Once Off and the
absence of recovery debt are confirmed, the app can remove the helper without
issuing another fan write. It reports that automatic fan control remains
unconfirmed. Incomplete sleep recovery is reported and retains its evidence.
The ineffective reconnect action is hidden. Resolve the fault, remove and
authorize the helper again; normal control requires a new launch with verified
fan recovery. A failed process starts no normal timers and exits successfully
after the last client disconnects and pending replies finish. Recovery markers
remain, without a launchd restart loop.

False or unknown hardware capability during reconciliation, an empty early
boot battery list, or transient signing reads preserve enabled intent and block
writing 1. On battery or unknown power, the helper still restores its own proven
setting to 0 and verifies it, without requesting immediate sleep. Unowned values
remain untouched. Termination restores its value and retains intent; successful
explicit Off saves Off. Even a failed Off save attempts its proven recovery,
keeps the archive evidence and reports failure. Only confirmed removal or a
signing mismatch automatically clears intent.
Signature validation is cached by identity, path and modification metadata;
updates and watcher events invalidate it, and uncertain results are not cached.

The shared lock uses six bounded attempts and 1.55 seconds of backoff, including
restoration. Busy boot loading remains pending and retries every five seconds,
then returns to the normal sixty-second schedule once loaded. It does not
persistently switch enabled intent to Off. If trusted debt is already loaded,
a failed lock acquisition can restore only that debt to 0, without writing 1,
requesting sleep or mutating the archive. If boot loading is still pending, it
does not invent ownership. Forced termination cannot guarantee completion.

An unsafe lock directory does not hide independently protected recovery proof.
The fallback only reads this identity's validated private directory and regular,
single-link records. A valid committed policy takes precedence over an old
recovery journal; only a missing or invalid policy falls back to the journal.
Trusted own v1 debt is usable without migration. It verifies recovery to 0 while
leaving intent and debt records unchanged. The UI reports unavailable records
or lock permissions and directs the user to helper logs. Logs identify
/private/var/db/StorageCleanerMac-MacMiniMode-Lock as root/0700 and owner.lock as
root/0600, regular and single-link. Repair and reload the helper for normal locked
cleanup; an emergency 0 alone is not a successful durable Off or unregister.

参考项目：[MacMiniMode](https://github.com/Pama-Lee/MacMiniMode)，MIT，参考提交
`f21aad039bc517f396e31f3612059bafec4d1008`。独立实现，未复制上游源码；许可致谢见 `THIRD_PARTY_NOTICES.md`。
