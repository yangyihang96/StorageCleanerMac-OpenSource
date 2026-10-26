#!/usr/bin/env bash
# Runs the in-process display-bound test classes (script/display-bound-tests.txt,
# DECISIONS D106) that script/verify.sh skips. The test bundle's display gate
# places every test window on one named non-main display before it is shown,
# and fails a test whose window cannot be placed there or that asks for UI of
# another process. Nothing runs unless exactly one non-main display has the
# exact name. The out-of-process class is never run here.
#
# Usage: script/run_display_bound_tests.sh --log ABSOLUTE_NEW_FILE
#          [--display NAME] [--classes REGEX] [--scratch-path DIR]
#   --log      new file that receives the gate's JSON-lines events; it must
#              not exist (the gate never appends to an old log)
#   --display  default "虚拟屏 1 · Codex"
#   --classes  run only the in-process classes whose names fully match REGEX
#
# A failing geometry assertion here is a finding: investigate it; never
# loosen the assertion or move the class out of the list to make it pass.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPLAY_NAME="虚拟屏 1 · Codex"
LOG_PATH=""
CLASSES=""
SCRATCH_PATH=""

usage() {
  echo "usage: $0 --log ABSOLUTE_NEW_FILE [--display NAME] [--classes REGEX] [--scratch-path DIR]"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --display|--log|--classes|--scratch-path)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "$1 needs a value" >&2
        exit 64
      fi
      case "$1" in
        --display) DISPLAY_NAME="$2" ;;
        --log) LOG_PATH="$2" ;;
        --classes) CLASSES="$2" ;;
        --scratch-path) SCRATCH_PATH="$2" ;;
      esac
      shift 2
      ;;
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

cd "$ROOT_DIR"
# The list must match the tests, or a window class could run unlisted.
python3 -B script/display_bound_tests.py --check
filter_args=(--filter-regex)
[ -z "$CLASSES" ] || filter_args+=("$CLASSES")
FILTER="$(python3 -B script/display_bound_tests.py "${filter_args[@]}")"
if [[ "$FILTER" != "^StorageCleanerMacTests\\.(?:"* ]]; then
  echo "no in-process class filter was produced" >&2
  exit 1
fi

# Reads the display list only (NSScreen through JXA); opens no window.
python3 -B script/display_target.py "$DISPLAY_NAME" || exit 78

swift_args=(test --filter "$FILTER")
[ -z "$SCRATCH_PATH" ] || swift_args+=(--scratch-path "$SCRATCH_PATH")
echo "display-bound tests: $(python3 -B script/display_bound_tests.py --count in-process) in-process classes listed; filter $FILTER"
echo "gate log: $LOG_PATH"

started_at="$(date +%s)"
set +e
env -u STORAGE_CLEANER_RUN_UI_TESTS \
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  STORAGE_CLEANER_TEST_DISPLAY="$DISPLAY_NAME" \
  STORAGE_CLEANER_TEST_DISPLAY_LOG="$LOG_PATH" \
  swift "${swift_args[@]}"
test_status=$?
set -e

# The log is the evidence that windows were placed before they were shown.
# It fails closed (D106-R4): a missing, empty, cut-off or foreign log, no
# installed record of this run confining to this display, or any refusal or
# violation proves nothing. A run that ordered no window is "installed only".
log_status=0
gate_report="$(python3 -B script/display_gate_log.py --check "$LOG_PATH" --display "$DISPLAY_NAME" \
  --not-before "$started_at")" || log_status=$?
[ -z "$gate_report" ] || echo "$gate_report"

if [ "$test_status" -ne 0 ]; then
  echo "display-bound tests failed (swift test exit $test_status). Investigate each failure; do not loosen assertions." >&2
  exit "$test_status"
fi
if [ "$log_status" -ne 0 ]; then
  echo "the gate log does not prove this run's gate on \"$DISPLAY_NAME\", or shows a window that was refused or left it." >&2
  exit 1
fi
echo "display-bound tests passed on \"$DISPLAY_NAME\" ($(sed -n 's/^evidence: //p' <<<"$gate_report")); gate log: $LOG_PATH"
