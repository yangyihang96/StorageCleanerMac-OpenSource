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
