# ADR 0001: Memory optimization is a verified application-quit workflow

- Status: accepted
- Date: 2026-07-29

## Context

High RAM occupancy is normal on macOS and does not itself prove pressure. Clearing cache with `purge` can reduce useful cache, distort “released” numbers, and does not establish a performance benefit. Ending a process by PID without a stable identity risks acting on a reused PID.

## Decision

Memory health is led by pressure, swap trend, compression, available-memory evidence, sustained process footprint, and measurement quality. StorageCleanerMac will not execute `purge` or manufacture memory pressure.

An optimization is an immutable, single-use plan over verified current-user GUI application identities. Execution performs a fresh preflight, normal quit, bounded wait, and fresh measurement. Force quit is a separate action with independent approval. Estimated and observed deltas are reported separately and system-wide changes are not fully attributed to the action.

## Consequences

- Some high-RAM states correctly produce “observe” rather than an action.
- Unavailable values can make the UI less numerically dense, but prevent false zeros.
- Applications with unsaved work may refuse normal quit.
- Tests can inject clocks, probes, and application controllers without touching real user applications.
- Public release still requires independent signing, notarization, and Sparkle evidence.
