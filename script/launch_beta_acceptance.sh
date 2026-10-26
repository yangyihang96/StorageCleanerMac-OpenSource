#!/usr/bin/env bash
# Starts the installed Beta for UI acceptance (DECISIONS D106) and nothing
# else: no install, no quit, no preference write. The app is opened through
# LaunchServices, so macOS attributes its permissions to the app itself, with
# --acceptance-display: before any window, status item, store or helper
# connection exists it confines every window to that display, or exits.
#
# Usage: script/launch_beta_acceptance.sh --log ABSOLUTE_NEW_FILE
#          [--display NAME] [--panel]
#   --log      new file for the app's JSON-lines gate events (must not exist)
#   --display  default "虚拟屏 1 · Codex"
#   --panel    also open the menu-bar panel on that display
#
# Refuses (75) while the installed Beta app runs, (78) unless exactly one
# non-main display has the exact name, (69) when the installed build has no
# acceptance mode, and when the bundle is not the signed Beta. Other processes
# from the bundle (the Finder extension, which Finder keeps while it is
# enabled, or a helper) are listed and left alone: the acceptance session
# never connects to a helper. The app's own refusals: 64 usage, 73 log not
# creatable, 75 another copy running, 77 Full Disk Access not verified,
# 78 display.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="/Applications/测试版.app"
DISPLAY_NAME="虚拟屏 1 · Codex"
LOG_PATH=""
PANEL=0
WAIT_SECONDS=20

usage() {
  echo "usage: $0 --log ABSOLUTE_NEW_FILE [--display NAME] [--panel]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --display|--log)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "$1 needs a value" >&2
        exit 64
      fi
      if [ "$1" = "--display" ]; then DISPLAY_NAME="$2"; else LOG_PATH="$2"; fi
      shift 2
      ;;
    --panel) PANEL=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

if [[ "$LOG_PATH" != /* ]]; then
  echo "--log must be an absolute path to a new file" >&2
  exit 64
fi
if [ -e "$LOG_PATH" ] || [ -L "$LOG_PATH" ]; then
  echo "the log already exists; give a new file: $LOG_PATH" >&2
  exit 73
fi
if [ ! -d "$(dirname "$LOG_PATH")" ]; then
  echo "the log's folder does not exist: $(dirname "$LOG_PATH")" >&2
  exit 73
fi

# The Beta identity as build_and_run.sh assembles it.
beta_setting() {
  local values
  values="$(sed -n "s/^  $1=\"\\(.*\\)\"\$/\\1/p" "$ROOT_DIR/script/build_and_run.sh")"
  if [ -z "$values" ] || [ "$(wc -l <<<"$values")" -ne 1 ]; then
    echo "cannot read the Beta $1 from script/build_and_run.sh" >&2
    exit 1
  fi
  printf '%s\n' "$values"
}
BETA_BUNDLE_ID="$(beta_setting BUNDLE_ID)"
BETA_EXECUTABLE="$(beta_setting APP_NAME)"
case "$BETA_BUNDLE_ID" in
  *.beta) ;;
  *) echo "unexpected Beta bundle identifier: $BETA_BUNDLE_ID" >&2; exit 1 ;;
esac

# A UTF-8 locale keeps "测试版" intact in the matched command lines.
running="$(LC_ALL=en_US.UTF-8 pgrep -lf "$TARGET/Contents/MacOS/" 2>/dev/null || true)"
if [ -n "$running" ]; then
  echo "refusing: the Beta app already runs from $TARGET (quitting it is not this script's job):" >&2
  printf '%s\n' "$running" >&2
  exit 75
fi
others="$(LC_ALL=en_US.UTF-8 pgrep -lf "$TARGET/Contents/" 2>/dev/null || true)"
if [ -n "$others" ]; then
  echo "note: other processes run from $TARGET and are left alone (no helper is contacted in acceptance):"
  sed 's/^/  /' <<<"$others"
fi

# Reads the display list only (NSScreen through JXA); opens no window.
python3 -B "$ROOT_DIR/script/display_target.py" "$DISPLAY_NAME" || exit 78

if [ ! -d "$TARGET" ] || [ -L "$TARGET" ]; then
  echo "no Beta is installed at $TARGET" >&2
  exit 1
fi
installed_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$TARGET/Contents/Info.plist" 2>/dev/null || true)"
if [ "$installed_id" != "$BETA_BUNDLE_ID" ]; then
  echo "refusing: $TARGET is '$installed_id', not $BETA_BUNDLE_ID" >&2
  exit 1
fi
codesign --verify --deep --strict "$TARGET"
python3 -B "$ROOT_DIR/script/beta_install_swap.py" signer "$TARGET"
installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$TARGET/Contents/Info.plist")"
# A Beta built before D106 ignores the acceptance arguments and starts as
# usual: windows and status item on the menu-bar display, helper connection,
# launch maintenance. Its executable then lacks the argument names.
for flag in --acceptance-display --acceptance-log; do
  if ! LC_ALL=C grep -q -a -F -e "$flag" "$TARGET/Contents/MacOS/$BETA_EXECUTABLE"; then
    echo "refusing (69): the installed Beta build $installed_build has no acceptance mode ($flag is" \
      "missing) and would open its windows on the menu-bar display; install a D106 build first" >&2
    exit 69
  fi
done
echo "verified: $TARGET is $BETA_BUNDLE_ID build $installed_build with the acceptance mode"

app_args=(--acceptance-display "$DISPLAY_NAME" --acceptance-log "$LOG_PATH" -ApplePersistenceIgnoreState YES)
[ "$PANEL" -eq 0 ] || app_args+=(--open-menu-bar-panel)
echo "opening $TARGET in the background with: ${app_args[*]}"
/usr/bin/open -n -g -a "$TARGET" --args "${app_args[@]}"

log_kinds() {
  [ -f "$LOG_PATH" ] || return 0
  python3 -B -c '
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    try:
        print(json.loads(line).get("kind", "?"))
    except ValueError:
        pass
' "$LOG_PATH"
}

app_pids() {
  LC_ALL=en_US.UTF-8 pgrep -f "$TARGET/Contents/MacOS/$BETA_EXECUTABLE" 2>/dev/null | tr '\n' ' ' || true
}

for attempt in $(seq 1 $((WAIT_SECONDS * 2))); do
  kinds="$(log_kinds)"
  if grep -qx 'installed' <<<"$kinds"; then
    echo "acceptance launch: the display gate is installed (PID $(app_pids)); log: $LOG_PATH"
    grep -m1 '"installed"' "$LOG_PATH" || true
    exit 0
  fi
  if grep -qx 'display-unavailable' <<<"$kinds"; then
    echo "the app refused (78): the display is missing, ambiguous or the menu-bar display; log: $LOG_PATH" >&2
    exit 78
  fi
  if grep -qx 'permissions-unverified' <<<"$kinds"; then
    echo "the app refused (77): Full Disk Access is not verified for this build, so a scan could prompt" \
      "on the menu-bar display; the user grants it in System Settings; log: $LOG_PATH" >&2
    exit 77
  fi
  # LaunchServices can take a few seconds to start the process.
  if [ ! -f "$LOG_PATH" ] && [ "$attempt" -ge 20 ] && [ -z "$(app_pids)" ]; then
    echo "the app exited before writing its log: usage (64), log not creatable (73) or another" \
      "copy running (75); its stderr goes to the unified log" >&2
    exit 1
  fi
  sleep 0.5
done
echo "no gate event within ${WAIT_SECONDS} s (PID $(app_pids)); do not interact with the app until" \
  "the log shows \"installed\": $LOG_PATH" >&2
exit 1
