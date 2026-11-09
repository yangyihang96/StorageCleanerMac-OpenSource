# Security

## Memory-operation boundary

- The feature never runs `purge`, allocates throwaway memory to manufacture a result, or executes a string-built `kill` command.
- Only regular GUI applications owned by the current UID are eligible by default.
- The app itself, system processes, accessory/background-only processes, and unverifiable identities are read-only.
- Normal quit uses `NSRunningApplication.terminate()` only after identity preflight.
- Timeout never escalates to force quit.
- Force quit uses a separately generated action and separate confirmation.
- Cancellation stops remaining targets and skips result verification.
- Immutable plans are consumed once and retained in a bounded replay-prevention set.

The process identity includes PID, bundle identifier, launch date, executable path, bundle path, and UID. Every field available at planning is checked again before mutation, limiting PID-reuse attacks.

## Privileges

Memory diagnosis and normal application quit do not request root, install a privileged helper, or change System Settings. The existing fan-control helper is a separate capability and is not used by memory optimization.

## AI assistant interface

The interface is off until the user turns it on in Settings › AI Assistant. Its only transport is a private Unix socket in the app's data folder: the app refuses to start it if the folder is not owned by this user, has other permissions, or is a link.

- **Levels.** R0 reads existing state, R1 starts read-only scans, R2 only proposes an operation for the user to confirm in the app, and R3 is not offered (any setting including this interface, enabling background helpers, system permissions, the app's own updates, uninstalling the app, password entry). Only R0 is open now. R1 and R2 tools are declared and answer `not_yet_available`.
- **No grant skips confirmation.** A client is read only or denied. Settings offers nothing else.
- **Both ends check each other.** The app accepts a bridge only with the same UID, a valid code signature, the identifier `<bundle id>.agent-bridge`, the app's Team ID (for ad-hoc signing, the bundled copy's cdhash), and the executable inside this bundle. The bridge checks the app the same way. The checks use the kernel's audit token and reuse the update askpass peer code.
- **The app names the client.** It walks up from the bridge, skips shells, launchers and language runtimes, and takes the first other program. Nothing a bridge or client says about itself counts. Approval binds to identifier and Team ID, to the cdhash for ad-hoc code, or to the path for unsigned code, and Settings marks anything without a developer signature.
- **Every call is checked in order:** switch, tool, arguments, rate limit (20 per second, 600 per minute per client), approval, permission, availability, then the result's per-field allowlist and output schema, and the access log.
- **Turning it off** refuses calls in progress, voids waiting requests and closes the socket.

**Residual risk.** The switch and the approvals are kept in the app's preferences, so malicious code running as the same user can change them. It could then read what an approved client can read; this version offers no proposals. It still could not carry out an operation without the user confirming it in the app.

## Logs and diagnostics

The memory feature does not log full process paths, usernames, command lines, or process arguments. User-visible process paths remain local to the UI. Diagnostic exports must redact home-directory prefixes and must never include signing keys, notarization credentials, Sparkle private keys, or update credentials.

## Dependencies and automation

- Sparkle is pinned by exact version and lockfile.
- GitHub Actions use minimal permissions and commit-pinned actions.
- Dependabot covers Swift packages and workflow actions.
- CodeQL analyzes Swift on a trusted macOS runner.
- Pull requests do not receive distribution credentials.

## Reporting vulnerabilities

Do not attach private files, process lists, credentials, or full home-directory paths to a public issue. Provide the app version/build, macOS version, reproduction steps, and a redacted diagnostic excerpt.
