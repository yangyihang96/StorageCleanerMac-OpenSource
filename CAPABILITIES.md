# Capabilities and Limits

## Memory measurements

| Metric | Status | Source / limitation |
| --- | --- | --- |
| Physical memory | Direct | `ProcessInfo.physicalMemory` |
| VM free, inactive, wired, compressed, speculative, file-backed, purgeable | Direct counters | Public Mach `host_statistics64`; several counters overlap and must not be added blindly |
| Cached files | Inferred | Conservative maximum of overlapping file-backed and purgeable counters |
| Available memory | Inferred | Free/speculative plus conservative cache estimate, clamped to physical memory; not `os_proc_available_memory` |
| Memory Pressure | Measured + classified | `memory_pressure -Q` headroom plus available/compressed/swap signals; unavailable if evidence is insufficient |
| Swap used/total | Direct | `sysctlbyname("vm.swapusage")` |
| Swap in/out rate | Derived trend | Delta of kernel Swapins/Swapouts over `ContinuousClock`; first/invalid sample is unavailable |
| Application footprint | Direct per process, partial aggregate | `proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint`; aggregate covers readable bounded process samples and is not Activity Monitor’s private global “App Memory” formula |

Read failures, permissions, unsupported APIs, process exit, and invalid samples are separate states. They are not rendered as 0.

## Memory optimization

The feature can diagnose pressure, identify sustained high-footprint user applications, request a normal quit, and verify subsequent observations. It cannot guarantee faster performance, attribute all system-memory movement to one app, save another app’s documents, or guarantee a fixed number of bytes will become free.

“Estimated app reduction” is the pre-action physical footprint of selected targets. “Observed app delta” and “observed available-memory delta” are post-action measurements and can differ because macOS cache, compression, swap, and other processes change concurrently.

Normal quit does not require administrator permission. Force quit requires separate user confirmation and may lose unsaved data. System/background processes are read-only.

Cancellation stops actions that have not yet been sent. An application that has already quit cannot be safely “undone” by this feature; the user must reopen it, and document restoration remains the responsibility of that application.

## Platform and distribution

- Deployment target: macOS 14.
- Some sensors and fan controls depend on Mac model, OS support, and separate helper permissions.
- The current repository has no App Store target/profile. App Store sandbox capability differences are therefore `EVIDENCE-INCOMPLETE`.
- A Developer ID build can use capabilities allowed by its entitlements and separately installed helper. The currently available local identity is Apple Development, which is not public distribution proof.
