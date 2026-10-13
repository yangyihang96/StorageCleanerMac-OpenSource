# Privacy

Memory diagnosis is performed locally. The app reads system VM counters and a bounded list of running-process identities and physical footprints so it can show high-usage applications and safely verify a requested quit.

The memory feature does not:

- upload a process list;
- collect process command-line arguments;
- read document contents;
- retain raw memory contents;
- use private frameworks;
- request administrator privileges;
- run a background memory-clearing service.

Process name, bundle identifier, executable/bundle path, PID, UID, launch date, and footprint are held in memory for the current snapshot and pending single-use plan. They are not added to routine logs. UI paths are shown only on the local Mac.

The optional residual-file check in the uninstaller reads only direct entry
names and modification dates in the current user's Library caches, logs,
saved application state, and HTTP storage directories. It does not read file
contents, contact a server, or add findings to an uninstall or cleanup plan.
No match in the current app inventory is only a review lead, not proof that
another app no longer uses the file.

macOS may require App Management permission to inspect or move another app's
bundle. The Beta requests it only through the system permission mechanism;
uninstall still requires an explicit in-app confirmation. If macOS denies the
move, the original app remains in place and the app records the denial rather
than bypassing it or deleting associated files.

Other app features may access the network for Sparkle update checks, explicitly requested speed tests, app-update catalog lookups, or benchmark leaderboard operations. Those are separate from memory diagnosis and should be reviewed under their own consent and trust boundaries.

## Browser privacy

The browser privacy page reads the local history databases of installed browsers (Safari, Chromium-family and Firefox-family browsers) through a temporary read-only copy that is deleted after the scan. Addresses, page titles and visit times are shown only on this Mac. The app does not write them to settings, logs or diagnostic exports and does not upload them. Copy Address and Copy Domains put text on the clipboard only when clicked, marked as concealed and transient so clipboard managers that honour these markers do not record it. Page titles and addresses cannot be selected as text, so these buttons are the only way to copy them; only the list of site names on the manual-handling page can be selected and copied as ordinary text.

Before the app deletes history directly (Chromium-family browsers only), it backs up that browser's whole history database to the app's Application Support folder. The backup still contains the deleted pages. It is deleted automatically after 7 days, also while the app keeps running. At most 12 backups are kept; a backup that has been restored, or whose result could not be confirmed, does not count towards the 12 but still expires. Any backup can be deleted earlier from the deletion report or from Recent Deletions; it is deleted directly, not moved to the Trash. Restoring a backup first saves the current history as another backup, so the restore can be undone. Backups are never uploaded, and the folder that holds them is excluded from Time Machine (other backup software may not honour this setting). Time Machine may still hold earlier copies of the browser's own history database; this app does not change those. A backup's description names only the browser, the profile and counts.

浏览器隐私页通过扫描后即删除的临时只读副本，读取已安装浏览器（Safari、Chromium 系和 Firefox 系）的本机历史数据库。网址、页面标题和访问时间只在这台 Mac 上显示；本应用不把它们写入设置、日志或诊断导出，也不上传。“复制网址”和“复制域名”只在点击时写入剪贴板，并标记为隐藏、临时内容，遵守这些标记的剪贴板管理工具不会记录。页面标题和网址不能作为文字选中，只能用这两个按钮复制；只有手动处理页上的网站名称列表可以作为普通文字选中复制。

本应用直接删除浏览记录（仅 Chromium 系浏览器）之前，会把该浏览器的整个历史数据库备份到应用的 Application Support 文件夹。备份里仍有被删除的页面，7 天后自动删除（应用一直开着也按时删除）。最多保留 12 份；恢复过的备份和结果未能确认的备份不计入份数，但同样到期删除。任何一份都可以在删除结果或“最近的删除”里提前删除，删除时直接删除、不移到废纸篓。用备份恢复之前，会先把当前的浏览记录另存为一份备份，因此恢复也可以撤销。备份不会上传，存放备份的文件夹已排除在时间机器备份之外（其他备份软件不一定遵守这一设置）。时间机器里可能仍有浏览器自己的历史数据库的早期副本，本应用不会改动它们。备份说明只记录浏览器、配置文件和条数。

## Public network address and country lookup

Public IP and country lookup have independent opt-in switches in Settings → Access.
Both default to off. Disabling public IP also stops country lookup; withdrawal
cancels active panel lookups and clears displayed external results.

After public-IP consent, the network panel can request the public IPv4/IPv6 address using HTTPS requests
to `api.ipify.org` and `api6.ipify.org`. Only with separate country-lookup consent does it send the resolved address as a
URL path component to `api.country.is` to look up a country code. These are
third-party network requests, not purely local device measurements. Each provider
can observe the connecting IP address and ordinary request metadata. Country
lookup additionally receives the queried IPv4/IPv6 address. This service uses an
ephemeral URLSession with cookies and URL caching disabled; that does not prevent
the providers from processing requests or keeping their own service logs.

These lookups do not establish the user's precise physical location and do not
prove VPN or firewall effectiveness. A VPN, proxy, or different IPv4/IPv6 routes
can change the addresses returned. This repository does not establish the
providers' retention periods; no promise of zero server logging is made.

## Benchmark leaderboard

Viewing the global benchmark leaderboard performs a read-only network request. Benchmark results remain local unless the user explicitly confirms publication.

After confirmation, the app sends only the fields needed to validate and rank the current official benchmark: a random installation identifier, an anonymous public label, Mac model, processor model, rounded memory capacity, benchmark date, app version/build, fixed protocol versions, safety conditions, required metric medians, and the proposed score. The service recomputes the score from the frozen reference contract and keeps at most the best result for that installation and workload.

The leaderboard payload does not include the computer name, account name, serial number, hardware UUID, MAC address, browser data, process list, document contents, or local paths. The installation identifier is generated by the app and is not derived from hardware. The service stores only an HMAC of it so the same installation can update or remove its public entry. Cloudflare necessarily processes the connection IP for delivery and abuse-rate limiting, but the IP is not included in the public entry or benchmark submission body.

Public results are community submissions and are not hardware-attested. A user can remove the public entry without deleting local benchmark history. A public result remains until it is replaced by a better eligible result or explicitly removed, subject to operational backup and security-log retention.


## 本地卸载授权 / Local uninstall authorization

卸载预览、扫描和启动不会注册文件操作辅助程序。仅当用户确认的应用移动被系统拒绝、且原应用身份仍可核实时，应用才准备独立的 FileOperationHelper 并请求系统授权。系统的登录项/扩展批准和管理员授权是分别检查的状态；App 管理、系统保护和只读卷限制不会被关闭。

辅助程序仅接受应用目录与当前用户同卷私有废纸篓之间的精确应用目标，不执行通用命令、不永久删除、不覆盖新同名文件。风扇 Helper 与文件操作 Helper 的身份、进程和授权分离。回执仍存于现有本地可恢复操作历史中，包含恢复所需的路径和身份；不会上传。生产扫描中未取得专属归属证明的关联数据只显示，不执行删除。

Scanning, previews and startup do not register the file-operation helper. After an explicitly confirmed app move is denied and the unchanged app is verified, a separate FileOperationHelper may require system approval and administrator authorization. It only performs exclusive, same-volume moves between permitted application directories and the current user's private Trash. It does not run shell commands, permanently delete files, overwrite existing destinations, disable App Management or change hardware controls. Recovery receipts remain in the existing local history and are not uploaded. Unverified related-data ownership remains display-only.
