#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${MEMORY_FIXTURE_APP:-/tmp/storage-cleaner-memory-fixture/MemoryFixtureApp.app}"
STATUS_FILE=""
FIXTURE_PID=""

cleanup() {
  if [[ "$FIXTURE_PID" =~ ^[0-9]+$ ]] \
      && ps -p "$FIXTURE_PID" -o command= 2>/dev/null \
        | grep -Fq "$APP/Contents/MacOS/MemoryFixtureApp"; then
    kill -KILL "$FIXTURE_PID" 2>/dev/null || true
  fi
  [ -z "$STATUS_FILE" ] || rm -f -- "$STATUS_FILE"
}
trap cleanup EXIT

wait_for_event() {
  local expected="$1"
  for _ in {1..50}; do
    if [ -s "$STATUS_FILE" ] && grep -Fq "\"$expected\"" "$STATUS_FILE"; then
      return 0
    fi
    sleep 0.1
  done
  echo "Memory fixture did not report '$expected'." >&2
  [ ! -s "$STATUS_FILE" ] || sed -n '1p' "$STATUS_FILE" >&2
  return 1
}

start_fixture() {
  local mode="$1"
  shift
  STATUS_FILE="$(mktemp /tmp/storage-cleaner-memory-fixture-status.XXXXXX)"
  open -n -a "$APP" --args \
    --allocate-mib 16 \
    --termination "$mode" \
    --status-file "$STATUS_FILE" \
    "$@"
  wait_for_event ready
  FIXTURE_PID="$(plutil -extract pid raw -o - "$STATUS_FILE")"
}

stop_fixture_for_next_case() {
  cleanup
  STATUS_FILE=""
  FIXTURE_PID=""
}

"$ROOT_DIR/script/build_memory_fixture.sh" >/dev/null

start_fixture allow
/usr/bin/osascript -e 'tell application id "com.local.StorageCleanerMac.MemoryFixture" to quit'
wait_for_event terminated
stop_fixture_for_next_case

start_fixture delay --delay-seconds 0.2
/usr/bin/osascript -e 'tell application id "com.local.StorageCleanerMac.MemoryFixture" to quit'
wait_for_event terminationDelayed
wait_for_event terminated
stop_fixture_for_next_case

start_fixture refuse
/usr/bin/osascript -e 'tell application id "com.local.StorageCleanerMac.MemoryFixture" to quit' >/dev/null 2>&1 || true
wait_for_event terminationRefused
kill -0 "$FIXTURE_PID"
stop_fixture_for_next_case

start_fixture unsaved
/usr/bin/osascript -e 'tell application id "com.local.StorageCleanerMac.MemoryFixture" to quit' >/dev/null 2>&1 || true
wait_for_event unsavedDocument
kill -0 "$FIXTURE_PID"
stop_fixture_for_next_case

start_fixture allow --exit-after-seconds 0.2
wait_for_event suddenExit
stop_fixture_for_next_case

start_fixture allow --exit-after-seconds 0.2 --relaunch-after-exit
FIRST_PID="$FIXTURE_PID"
for _ in {1..50}; do
  if [ -s "$STATUS_FILE" ]; then
    NEXT_PID="$(plutil -extract pid raw -o - "$STATUS_FILE" 2>/dev/null || true)"
    NEXT_EVENT="$(plutil -extract event raw -o - "$STATUS_FILE" 2>/dev/null || true)"
    if [[ "$NEXT_PID" =~ ^[0-9]+$ ]] && [ "$NEXT_PID" != "$FIRST_PID" ] && [ "$NEXT_EVENT" = "ready" ]; then
      FIXTURE_PID="$NEXT_PID"
      break
    fi
  fi
  sleep 0.1
done
[ "$FIXTURE_PID" != "$FIRST_PID" ] || {
  echo "Memory fixture did not relaunch with a new process identity." >&2
  exit 1
}

echo "Memory fixture behavior smoke test passed."
