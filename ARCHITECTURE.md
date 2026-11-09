# StorageCleanerMac Architecture

StorageCleanerMac is a Swift 6 Swift Package targeting macOS 14 and later. The package builds the main app, the fan-control helper, the AI assistant bridge, a dedicated memory fixture app, and the XCTest targets. Sparkle 2.9.4 is pinned in `Package.resolved`.

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

## AI assistant interface

`client → storage-cleaner-agent → private Unix socket → AgentGateway → AgentReadProvider → stores`

- `AgentShared`: the socket's location, the data folder rules, the peer policies, the preference keys and the tool catalog. The bridge and the app agree through this target rather than through each other's code.
- `AgentBridgeCore`, `AgentBridge`: the bridge inside the bundle (`Contents/Helpers/storage-cleaner-agent`, signed as `<bundle id>.agent-bridge`). `mcp` is a stdio server for both MCP protocol generations, and the other subcommands are a JSON command line.
- `AgentGatewayCore`: the socket server, the router, rate limits, the result guard, item tokens, the client registry, the access log and the request queue. It imports nothing from the app.
- `Features/Agent`: the app's end. `AgentStoreReadSource` copies values from the stores, `AgentReadModels` holds each tool's per-field allowlist, `AgentAppReadProvider` answers reads, and `AgentInterface` starts with the launch work, ends with the process and is all that Settings talks to.
- `Views/Settings/SettingsAIAssistant.swift`: the settings page. It reads and drives only the `AgentInterface` it is given, so a render or a test never reaches a real gateway or real preferences.

The gateway does not depend on a window, so it keeps answering with only the menu bar panel running. The router checks each call in the order listed in `SECURITY.md`. Listening uses no timer and wakes only for a connection.

## Build and distribution

- `script/bootstrap.sh`: verifies tools and resolves pinned dependencies.
- `script/verify.sh`: Debug/Release builds, strict concurrency build, tests, static boundaries, and optional bundle/UI smoke checks.
- `script/build-release.sh`: release-candidate validation and clean-tag distribution gate.
- Existing `make_release_dmg.sh` and `notarize_release.sh`: Developer ID packaging and notarization when credentials exist.

Distribution, installation, signing, notarization, appcast publication, and Sparkle replacement are separate evidence gates.
