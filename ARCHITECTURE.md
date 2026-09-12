# StorageCleanerMac Architecture

StorageCleanerMac is a Swift 6 Swift Package targeting macOS 14 and later. The package builds the main app, the fan-control helper, a dedicated memory fixture app, and the XCTest target. Sparkle 2.9.4 is pinned in `Package.resolved`.

## Memory feature

The memory feature is split by responsibility:

- `Features/Memory/Domain`: measurement availability, process identity, immutable optimization plans, execution outcomes, pressure policy, and overflow-safe arithmetic.
- `Features/Memory/Infrastructure`: native VM/process probes, monotonic swap-rate history, and identity-checked `NSRunningApplication` control.
- `Features/Memory/Application`: the application-scoped coordinator and its single execution state machine.
- `ScanStore`: the MainActor presentation store observed by the main window and menu-bar panel. It owns one coordinator and exposes user intents to SwiftUI.
- SwiftUI views: render state and send intents only. They do not read kernel memory, create `Process`, or terminate applications.

The safe path is:

`observe → plan → preflight → explicit confirmation → graceful quit → verify → report`

Force quit is a different action and requires a second explicit approval. A plan ID is single-use. PID, bundle identifier, executable path, bundle path, launch date, and UID are checked again immediately before every request.

## Memory measurements

`SystemMemoryProbe` uses public macOS interfaces:

- `host_statistics64` and `host_page_size` for VM counters;
- `sysctlbyname("vm.swapusage")` for current swap use;
- `memory_pressure -Q` for pressure headroom, with a deadline;
- `proc_listpids`, `proc_pid_rusage(RUSAGE_INFO_V4)`, `proc_bsdinfo`, and `proc_pidpath` for process footprint and identity;
- `ContinuousClock` deltas over kernel `swapins`/`swapouts` counters for rates.

Unavailable readings remain unavailable. Compatibility fields in `MemorySnapshot` exist for older callers, but new presentation uses the canonical optional measurements.

## Menu-bar charts

`MenuBarAdvancedStatusView` owns one `PanelChartTimeline`. It supplies one monotonic-derived wall-clock reference to every visible chart. `ChartActivityPolicy` pauses or reduces the cadence for hidden panels, sleeping displays, Low Power Mode, serious/critical thermal states, and Reduce Motion.

Chart samples are ordered before mapping. Future timestamps beyond tolerance are discarded; tolerated skew is clamped to the shared reference. Bar geometry remains 2 pt wide with a 1 pt gap, and continuous motion changes horizontal phase without interpolating measured values.

## Build and distribution

- `script/bootstrap.sh`: verifies tools and resolves pinned dependencies.
- `script/verify.sh`: Debug/Release builds, strict concurrency build, tests, static boundaries, and optional bundle/UI smoke checks.
- `script/build-release.sh`: release-candidate validation and clean-tag distribution gate.
- Existing `make_release_dmg.sh` and `notarize_release.sh`: Developer ID packaging and notarization when credentials exist.

Distribution, installation, signing, notarization, appcast publication, and Sparkle replacement are separate evidence gates.
