# Changelog

## 1.9.13 — 2026-09-12 (Build 202609120014)

### 菜单栏与监控历史

- 新增“电量＋内存＋Wi-Fi”菜单栏模式：中心数字显示内存占用，上半环显示电量，下方三点显示 Wi-Fi 强度。充电绿色，未充电黄色，低于 50% 深橙色、低于 20% 红色；无内置电池的 Mac 自动改用内存环。保留其他显示模式和有效用户偏好。
- Wi-Fi 使用真实无线接口信号，区分关闭、断开与读取失败；不会把 RSSI 的错误返回值 0 当成满格。电量及无线状态单独变化也能刷新图标，小窗关闭后继续采样。
- 历史图按固定时间窗口平均，避免采样时刻的轻微偏差直接表现为离散空柱：1 小时按 6 秒、1 天按 144 秒；3/6/12 小时及 3/7/14/28 天按相同的约 600 点密度扩展，并增加 10 分钟选项。后者是本应用的计算规则，不声称是 iStat 未公开的内部算法。
- CPU、内存、网络、磁盘、传感器及电池共用时间投影，图形与悬停使用一致数值。真实零值保留，磁盘计数差按实际测量区间加权；短时估算柱沿用普通柱外观，来源仍可核对。睡眠、暂停、应用未运行和长期缺失不伪造补点。
- 网络与磁盘纵轴完整容纳当前图中平均柱的高峰，修复按第 90 百分位缩放时高峰被截断的问题。CPU 和内存百分比仍使用 0–100% 量程。
- 修复菜单栏外观通知导致重复重绘，以及图表渲染中反复扫描同一份历史数据的问题；图表的时间推进与真实采样分开处理，切换范围不改写历史。

### 主窗口、小窗与文件工作区

- 更新主要功能页的素材、页头、状态区、操作区与紧凑布局，保留现有扫描、真实结果与清理流程；改善登录项、性能、内存及能耗页面的信息层次。
- 小窗悬停可打开风扇控制的三级详情，调整能源模式、充电控制与级联菜单的边界和排布，并精简重复说明。未知硬件模式仍按真实状态处理，不会因为隐藏冗余文字而绕过控制安全检查。
- 文件分析增加按文件/文件夹过滤、搜索与排序，并提供按真实字节占比展开的目录图；列表筛选不会改变原始容量及图形统计。
- 改善浏览器隐私的日期范围批量选择、结果列表和空状态；所有删除继续使用原有确认、备份与操作后核对。
- 文件搬家只有在复制校验成功、原件成功移入废纸篓之后才完成；无法移除原件时保留原件及已验证副本并报告真实结果。
- 风扇、电池控制继续保留硬件能力判断、Helper 身份验证、租约、读回和失败恢复；测试展示数据与实际硬件写入路径分开。

### 本地验证与发布流程

- 修复正式安装包遗漏 13 张现有界面插图而退回旧视觉的问题。Release 打包与 Beta 使用相同素材，并在解出的 ZIP 和挂载的 DMG 中逐文件比对资源内容。
- 修复部分界面测试在 Release 配置中引用 Debug 专用截图与演示工具而无法编译的问题；演示数据仍只存在于调试/测试版，正式功能和安全逻辑继续执行 Release 回归。
- GitHub CI、CodeQL 与发布候选验证改为手动触发，并停用本次发布的远端验证流程；构建、测试、签名和安装包检查全部在本机完成。
- 本轮完整验证与运行观察的最终结果记录在 `docs/RELEASE_VALIDATION_1.9.13.md`。测试通过不等于不存在任何潜在缺陷，也不代替独立的黄金视觉验收。

### Responsiveness and background efficiency

- Serialize application inventory and deep signature scans through the existing
  heavy-work coordinator so they cannot compete with storage analysis,
  duplicate scanning, cleanup, network tests, or benchmarks.
- Run long file-analysis, duplicate-hashing, and AC energy-attribution work at
  utility QoS so visible interaction keeps scheduler priority without reducing
  scan safety checks or telemetry calculations.
- Resolve direct and parent application bundle paths before querying
  LaunchServices, avoiding repeated synchronous process metadata lookups during
  the 30-second background energy sample.

### Stable file-tool scan UI

- Keep File Analysis, File Mover, and Duplicate Files on one fixed landing-page
  geometry while their read-only scans run, so changing counters and paths no
  longer move the configuration card, action, status, or artwork.
- Coalesce UI-only progress snapshots to a bounded cadence while preserving
  every scanner callback, phase transition, pause/cancel action, safety check,
  and final result. Volatile paths no longer wrap the File Analysis landing
  page; Duplicate Files keeps a single-line middle-truncated path with full
  hover and accessibility text.

### Browser privacy bulk selection

- Add a visible bulk-selection popover that groups selectable history by local
  date ranges and exact website domains, with a searchable lazy website list
  instead of requiring row-by-row selection.
- Keep bulk selection additive and review-gated. It never deletes immediately;
  the existing browser-running preflight, immutable cleanup plan, recovery
  backup, exact Visit transaction, and post-delete read-back remain required.

### Fan-control hardware compatibility

- Give bounded Apple Silicon SMC takeover operations enough time for slower
  thermal-manager unlocks instead of treating the generic five-second XPC
  deadline as a failed fan write.
- Resolve each fan's `F?md`/`F?Md` mode key independently and retain the same
  helper watchdog, hardware-range clamp, write read-back, and automatic restore
  requirements.

### Explainable system health

- Rebuild the health score around four measured core factors: disk reliability,
  usable capacity, 30-day stability, and battery lifespan. A critically weak
  factor can no longer be hidden by a healthy average.
- Keep current battery charge, FileVault, Time Machine, network, and thermal
  readiness visible as supporting status without mixing them into the hardware
  health score. SMART Verified is reported as a current check, not invented as
  100% remaining SSD life when no media-life sensor exists.
- Treat macOS `shutdownStall` diagnostics as hangs rather than unexpected
  restarts, and keep per-app crash/spin reports out of the device-stability
  score, while preserving the diagnostic evidence and action guidance.
- Replace the full-page warning tint and nested score cards with a neutral,
  responsive evidence view that shows the measured value, score, availability,
  and observation time for every scored factor.

## 1.9.12 — 2026-08-28 (Build 202608282037)

### Adaptive main-window layout

- Keep native window resizing and the existing readable minimum size instead of
  locking the main window to one fixed frame.
- Replace the shared button's hand-built icon/text `HStack` with native SwiftUI
  `Label`, keeping system alignment, spacing, focus, tooltip, and accessibility
  behavior. Primary, secondary, destructive, and other meaning-bearing actions
  now keep their visible title under pressure; only toolbar, icon, and small
  utility actions may use `ViewThatFits` to fall back to an icon-only label.
- Stack shared page-header actions below the page identity at compact window
  density, while regular windows retain the original single-row arrangement.
  All 15 main routes were recaptured from the installed Beta at the supported
  `833 × 544` minimum size without icon/title overlap; the compact memory page
  keeps both the refresh glyph and its visible “刷新” title.

### Startup performance and Smart Scan

- Keep ordinary startup-item refreshes on the fast read-only path; the separate
  **Full Scan** button remains the only entry that runs the bounded macOS BTM
  diagnostic.
- Read referenced application signing identities with at most four concurrent
  checks and drain temporary bundle metadata per application to reduce first-scan
  latency and transient memory pressure.
- Pre-index normalized application paths, bundle identifiers, and attribution
  tokens once per startup scan. Embedded helpers no longer standardize every
  application URL again for every startup item, while deepest-parent matching
  and attribution confidence remain unchanged.
- Precompute startup-item merge fingerprints once per item so deduplication no
  longer normalizes plist and executable URLs again for every candidate pair;
  merge ordering and evidence rules remain unchanged.
- Avoid Foundation URL normalization for startup items whose paths cannot resolve
  into sealed `/System` locations, while retaining dot-segment safety checks.
- Defer self-signature capability inspection from MainActor store construction
  until the first background scan or confirmed startup-item operation.
- Move the app-and-Helper signature contract check off the main thread and reuse
  its single fail-closed result, keeping the mini-window responsive on first open.
- Fill the existing fixed Smart Scan accessory slot with the last verified green
  and review totals, reserving the center width for the primary action instead of
  adding another card system or allowing the summary to overlap it.
- Serialize application-inventory progress and incremental-result delivery with
  the main actor so late batches cannot overwrite final source/ignore policy, and
  propagate cancellation immediately from metadata reads instead of continuing
  Spotlight, Homebrew, and source classification work.
- Remove an always-empty localized metadata dictionary allocated for every app.
- Read application metadata with a four-task ceiling while preserving URL order
  and the existing 16-item UI batches, reducing full inventory latency without
  launching an unbounded task per installed application.

### Application updates

- Show the scanned `.app` artwork in every update catalog row and detail view.
  Homebrew formulae, command-line tools, and other items without an application
  bundle now receive a clear provider-specific icon instead of a weak generic
  file glyph.
- Add a visible **Open** action to every manual-update row and a matching detail
  action. Provider-verified Homebrew and confirmed official sources open only an
  HTTPS page whose identity and allowed host pass the existing source checks;
  items without a trusted page retain their existing app or command fallback.
- Keep manual hand-off truthful: opening a page, app, or copied command never
  marks the item updated; the installed version must change on a later scan.

### Application uninstaller

- Replace the automatic scan on page entry with an explicit **Scan Apps**
  action. The initial page now stays idle until the user starts the read-only
  scan, then returns to the existing searchable application list.
- Reuse the shared feature landing shell, status treatment, and design tokens so
  the uninstaller follows the same visual language as the other main modules.

### File analysis space map

- Change the default tile action from opening Finder to an in-app directory
  drill-down. A child list, proportional map, back control, and breadcrumb path
  now stay synchronized while the user explores successive folder levels.
- Replace the vertically stacked summary, type bars, map, and duplicate file
  list with a dedicated analysis workspace: one compact result toolbar, one
  segmented **Space Map / File List** switch, and an edge-to-edge split between
  the current directory list and its treemap. The map is no longer clipped by
  the outer page scroll view.
- Label every sufficiently large tile with both size and percentage, reduce the
  visual gutter to two points, and keep the parent folder's known size as the
  layout denominator. Items beyond the tile limit are grouped as **Other
  Measured Items**, while time-, access-, exclusion-, or cloud-limited space is
  retained as a non-interactive gray **Measurement Incomplete** tile. A partial
  child scan can no longer inflate 150 MB into 42% of a 3.8 GB parent folder.
- Keep **Show in Finder** as a separate explicit row/header action. Selecting a
  file only shows its local details and never opens Finder or performs cleanup.
- Reuse the existing `LargeFilesStore`, `DiskScanner`, heavy-work coordinator,
  scan exclusions, and safety rules. A bounded low-power scan divides its
  remaining time fairly among immediate child folders, preventing one large
  first folder from starving later map tiles. Results are cached for instant
  back navigation and marked as lower bounds when time, access, exclusions,
  symbolic links, or cloud placeholders prevent a complete result.

### Duplicate files

- Use the existing shared button content with explicit icon-to-title spacing for
  the add-folder and external-volume actions, including the coverage report.
  Compound SF Symbol badges no longer overlap Chinese text at Retina scaling.
- Give the scan-scope menu the same explicit spacing while preserving native
  menu, focus, keyboard, and accessibility behavior.

### Browser privacy

- Identify every history result with the installed browser's real app icon and
  name, then show a bounded local page-title summary, domain, profile, visit
  count, and latest visit time. Full URL paths, query parameters, parsed search
  keywords, passwords, cookies, bookmarks, autofill, and page contents remain
  outside the result UI.
- Include local page titles in the existing result search without adding a new
  scanner or persistence path. Remove the meaningless per-row size placeholder
  so the review, handling, and running-state badges remain readable at the
  supported compact window width.

### Performance benchmark

- Replace the default wall of raw benchmark units with an at-a-glance comparison
  of CPU, GPU, memory, and storage scores, including the relative strength,
  relative weakness, and an honest V7-reference explanation. Keep all original
  metrics available in one collapsed technical-details section.
- Show the real benchmark workload, repetition number, overall progress, and the
  seven-stage run path while testing. This reuses the existing V7 state and
  coordinator without adding another benchmark flow, timer, or persisted score.

### Energy impact

- Replace the automatic page-entry scan and six-second refresh loop with an
  explicit **Scan Energy** action built on the shared feature landing shell.
- Show the existing measurement pipeline as six real stages: running processes,
  app attribution, baseline counters, initial attribution, the 1.2-second live
  sample, and calibrated result aggregation.
- Keep menu-bar background prefetch separate from the main page's explicit scan.
  Rescans retain the previous complete result until the new measurement finishes,
  and the stage nodes and progress bar update together without visual lag.
- Give every six-stage pipeline node a fixed glyph column and the shared 8pt
  icon-to-title spacing. Apply the same spacing to rescan, sample-window, and
  sort controls so icons cannot crowd localized text at Retina scaling.
- Prevent the shared landing action from covering header content when the main
  window is short. Energy results now switch to a stacked measurement bar and
  app row at compact widths, keeping app names, status badges, and all three
  energy values readable instead of compressing badges down to bare glyphs.

### Developer artifacts

- Add a persisted 30–364 day activity threshold to the existing developer-cache scan. The latest readable modification anywhere inside each candidate now classifies it as green (over one year, selected by default), yellow (older than the chosen threshold, manual confirmation), or red (within the threshold, off by default with two confirmations).
- Recheck nested modification activity during preflight and immediately before moving an item; any post-scan change fails closed and requires a new scan.
- Identify every supported AI developer artifact by owner and type in scan rows and evidence details: Codex, Claude Code, Cursor, GitHub Copilot, OpenCode, and OpenClaw. Regenerable caches and temporary files keep the time-based safety policy; logs remain review-only and can only be revealed in Finder.
- Keep sessions, chat history, project state, credentials, settings, extension state, and OpenCode storage outside the cleanup allowlist.

### Fan control stability

- Keep verified manual and maximum targets active while physical RPM catches
  up. Helper target-register readback, lease renewal, thermal protection, and
  the watchdog remain the control safety boundary.
- Refine the attached fan-control palette with the mini-window's active theme,
  clearer hover/selection borders, live progress feedback, a wider readable
  layout, and 25/50/75/100% synchronized fan presets.
- Keep every 1% slider movement local for immediate pointer response, publish a
  bounded 5% live hardware preview, and commit the exact target on release so
  UserDefaults and shared SwiftUI observers are not invalidated for every pixel.

### Mini-window power controls

- Keep the battery power-mode palette top-aligned beside the secondary power
  page. Expanding or collapsing battery information no longer moves the
  palette with its source row.

### Access setup

- Add **Settings → Access & Setup**, consolidating Full Disk Access, per-folder
  access, App Management, the restricted system-control helper, and optional
  notifications.
- Show current status, exact System Settings paths, direct jump buttons, and a
  three-step setup tutorial.
- Explicitly document that Accessibility, Screen Recording, Camera,
  Microphone, Location, and Automation permissions are not required.

### Duplicate files and file migration

- Give Duplicate Files and File Migration the same shared landing/data-page
  hierarchy as the rest of the file tools, with route-specific copy, semantic
  icons, shared empty states, and responsive controls.
- Keep the duplicate-results search, filter, rules, sort, and scope controls
  usable at compact widths; report only full SHA-256 matches as content-confirmed
  files and keep the coverage description tied to the completed scan's scope.
- Keep File Analysis and File Migration on the same scanner and Store while
  separating their presentation: migration no longer inherits hidden analysis
  filters, and external-drive/app discovery runs only on the migration route.
- Show only regular user files that satisfy the migration safety boundary,
  expose scan cancellation, and state that files are SHA-256 verified before
  the original is moved to Trash.
- Reject a file when its current size no longer matches the scanned candidate,
  and reject an application whose source signature is invalid before copying.

## 1.9.11 — 2026-08-14 (Build 202608142241)

### Interface

- Replaced the floating Beta-only title with the product name and a compact
  Beta capsule so every main-window page shares one chrome.
- Gave idle landing pages the same page-feature icon as data pages, and routed
  module headers through `AppSymbolIcon` so Smart Scan, health, utilities, and
  file tools use one glyph size and rendering mode.
- Kept immersive pages free of the settings-only header divider, and showed the
  version plus Beta mark in the sidebar footer.

### Menu-bar window and hardware control

- Kept fan monitoring and fan control on separate surfaces: the sensors card
  only reads speeds and helper status; mode switches, sliders, and the curve
  editor live in the attached palette.
- Replaced the blocking AppKit slider with a DragGesture control, widened the
  helper watchdog to 30 seconds, and stopped a second GUI instance from
  stealing the helper lease.
- Hovering from a control anchor to its palette no longer dismisses the
  tertiary column; the session hover envelope now includes the palette frame.
- Palette rows stay clickable after relaunch so a stale “connection
  interrupted” state can self-heal instead of dead-ending the controls.
- Shared one status capsule between the sensors card and the fan palette.

### Application updates

- Added a vendor-updater path for apps that ship Keystone or Squirrel, and
  surfaced Sparkle apps with a trusted in-app update path even when the
  remote version is still unknown. Automatic install gates are unchanged.

### Performance and maintenance

- Cached localization language lookup, merged CPU sampling into one mach call,
  replaced per-item `du`/`mdls` with native size reads, windowed mini-window
  telemetry history, and throttled duplicate-file progress publication.
- Removed unused privacy adapters, old menu-bar charts, and other dead views.
- Moved Beta verification copies out of Documents so File Provider cannot
  reattach `FinderInfo` and break strict codesign.

By owner decision, version 1.9.11 is published as an explicitly unnotarized
public test release using the locally validated Apple Development-signed build.
It is not Developer ID signed or Apple notarized and must not be described as
Gatekeeper approved. First launch may require Control-click → Open.

## 1.9.10 — 2026-08-13 (Build 202608131925)

### Smart Scan and cleanup safety

- Aligned the read-only scanner and three-tier presentation with the installed
  `storage-analyzer` policy while preserving stable item identities and the
  existing plan, preflight, confirmation, identity recheck, Trash/Quarantine,
  verification, and report chain.
- Kept regenerable cache items selected by default, review items opt-in with an
  extra warning, and protected or incomplete-evidence items out of executable
  cleanup plans.
- Rebuilt the result hierarchy around compact risk summaries and collapsed
  parent groups, with disk capacity, Top 5, coverage, and technical evidence
  retained as secondary detail instead of crowding the first screen.
- Stabilized the idle, scanning, and completed page geometry and throttled
  progress publication so file discovery no longer shifts the page or rebuilds
  the whole result view for every candidate.

### Menu-bar monitoring and hardware control

- Tightened the existing three-level menu-bar window attachment, hover intent,
  screen-edge flipping, panel mutual exclusion, equal outer insets, and compact
  card geometry without creating another panel architecture.
- Improved cached CPU, GPU, fan, memory, disk, network, battery, external disk,
  and network-volume telemetry while moving heavy disk work away from the main
  interaction path.
- Added structured helper, fan telemetry, capability, control-mode, and power
  state instead of ambiguous optimistic labels; all successful control states
  still require helper readback.
- Added temperature-curve fan control to the existing privileged helper, with
  typed validation, per-fan RPM mapping, filtering, hysteresis, rate limits,
  lease/watchdog protection, write verification, and automatic restoration.
- Unified automatic, manual, and curve control with one helper authorization;
  removed the legacy privileged installation path and arbitrary command/key
  surfaces.

### Browser privacy, applications, and files

- Expanded installed-browser discovery and profile scanning while keeping URL,
  title, visit time, and visit count processing local and read-only.
- Added recovery-aware browser history processing and clearer per-browser
  coverage without reading passwords, cookies, bookmarks, or page content.
- Improved application update discovery, official-source verification, queue
  progress, failure recovery, and the usable result surface without treating a
  failed package identity check as success.
- Restored file moving as a first-class sidebar workflow, kept copy/verify before
  Trash semantics, and hardened duplicate-file resume data and application data
  locations.

### Interface, accessibility, and performance

- Unified the main feature pages with the existing application shell, spacing,
  material, typography, button hierarchy, and compact explanatory copy.
- Improved application icons, process selection, keyboard/accessibility labels,
  reduced-motion behavior, and fixed-width numeric presentation.
- Reduced redundant timers, monitor work, state publication, formatter creation,
  and repeated panel connections to make the mini window respond faster.

By owner decision, version 1.9.10 is published as an explicitly unnotarized
public test release using the locally validated Apple Development-signed build.
It is not Developer ID signed or Apple notarized and must not be described as
Gatekeeper approved. First launch may require Control-click → Open.

## 1.9.9 — 2026-08-05 (Build 202608052103)

### Application updates

- Unified scanning, review, confirmation, execution, post-update inventory, and completion reporting into one recoverable queue.
- Kept ordinary App Store items in the system-managed flow while allowing only receipt-, signature-, identity-, and product-ID-verified MAS items into the automatic queue.
- Preserved frozen click-time identity and target versions, execution-time running-app checks, graceful quit, cancellation, reconciliation, relaunch, and one final inventory refresh.
- Separated preview dismissal from active-batch cancellation so confirming an update can no longer cancel the queue as the sheet closes.
- Corrected the completion summary so verified App Store work reports its real succeeded, failed, cancelled, or skipped result instead of always appearing skipped.

### Browser privacy

- Reworked the page into a usable read-only scan, masked review, per-browser manual action, and confirmation-scan flow.
- Kept raw URLs, titles, search terms, and domains in the in-memory session; real domains reach the clipboard only after an explicit copy action.
- Added fail-closed per-profile coverage proof and multiset visit matching so a different profile, partial scan, permission failure, or duplicate record cannot be reported as cleared.
- Moved the privacy session to the main-window lifetime so navigating to another page no longer discards scan results or verification state.
- Deduplicated browser filter options by browser ID so ordinary multi-record scan results no longer trigger a duplicate-key crash while rendering the filter menu.

### Performance benchmark and leaderboard

- Kept one official V9 product flow covering CPU, GPU, memory, storage, display, and a 600-second sustained run, with an expected total duration of 14–16 minutes.
- Preserved the exact power, thermal, or Low Power Mode reason and sustained telemetry when a safety stop ends the official run early.
- Added compatible latest, best, history, and public leaderboard presentation without automatic score submission.
- Froze the client/server V9 contract and added it to the Release packaging gate alongside scoring, leaderboard, official-plan, and legacy calibration checks.

### Compatibility and release safety

- Integrated the current `main` Swift 6, Xcode 16.2, runner portability, icon-loading, update-event buffering, and benchmark compatibility fixes.
- Corrected the compact panel's memory-pressure semantics: the primary value and ring now report the three-level pressure state, system headroom remains explicit, and `100−headroom` is identified only as a history-trend estimate rather than an iStat or Activity Monitor percentage.
- Added explicit release-state separation for local builds, installed apps, Developer ID signing, notarization, public assets, appcast publication, and real Sparkle replacement.

By owner decision, version 1.9.9 is designated for an explicitly unnotarized public test release using the validated Apple Development-signed build. It must not be described as Developer ID signed or notarized, and macOS may require Control-click → Open before first launch. Anonymous artifact verification and a real 1.9.8-to-1.9.9 Sparkle replacement remain mandatory publication checks.

## 1.9.8 — 2026-07-30 (Build 202607301737)

### Interface and settings

- Refined the main window, cleanup selection, settings, and compact menu-bar panels with shared spacing, typography, borders, and semantic colors.
- Focused the Smart Scan preparation screen on one primary action and strengthened the existing module tint without introducing saturated full-window backgrounds.
- Added light and dark application artwork plus compact menu-bar artwork that follows the active appearance.
- Improved compact-panel sizing, edge attachment, routing, and multi-display placement so empty content no longer leaves fixed gaps.

### Performance benchmark

- Restored an explicit score for every benchmark run while keeping the highest verified score as the leaderboard entry.
- Added automatic best-score refresh and clearer per-test and Apple Silicon baseline presentation.

### Startup items and app updates

- Expanded startup discovery and now exposes only operations that the current system can actually perform, with explicit administrator or System Settings guidance where required.
- Improved App Store and website-update discovery, capability reporting, queued actions, and post-update version verification.

### Memory diagnosis and optimization

- Replaced `ps` RSS sampling with native physical-footprint and identity probes.
- Added explicit complete/partial/unavailable measurement quality and reasons.
- Switched paging trend input from generic Pageins/Pageouts to kernel Swapins/Swapouts.
- Stopped summing VM counters that may overlap; cached memory uses a conservative estimate.
- Removed cache purge actions, purge result language, and mixed disk/RAM “opportunity bytes.”
- Added immutable, single-use optimization plans and an application-scoped state machine.
- Added PID-reuse protection, graceful/force separation, cancellation, timeout, partial-result, and verification reporting.
- Separated estimated app reduction from observed app and available-memory deltas.

### Menu-bar charts

- Added one shared panel timeline derived from `ContinuousClock`.
- Added visibility, display sleep, Low Power Mode, thermal, and Reduce Motion cadence policy.
- Added continuous horizontal bar motion, clock-skew tolerance, future-sample rejection, and out-of-order sorting.
- Added persistent real battery history and unified CPU, memory, network, disk, sensor, fan, and battery chart geometry, hover targeting, and localized presentation.

### System monitoring and control

- Added richer memory, battery, power, sensor, disk, and network detail while preserving unavailable-data states instead of displaying false zeroes.
- Tightened fan-control capability checks and helper packaging without silently escalating privileges.

### Engineering

- Added a dedicated controllable memory fixture app and GUI behavior smoke test.
- Added reproducible bootstrap, verification, and release-candidate scripts.
- Added macOS 14/macOS 26 CI, CodeQL, and Dependabot configuration.

Version 1.9.8 has been published to the private source repository, the public updates repository, and the public Sparkle appcast. Build 202607301737 has not been installed, Developer ID signed, notarized, or exercised through a real Sparkle replacement.
