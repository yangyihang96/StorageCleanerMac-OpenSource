#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFY_ROOT="${STORAGE_CLEANER_VERIFY_ROOT:-/tmp/storage-cleaner-verify}"
BUNDLE_BUILD_ROOT="${VERIFY_ROOT}-bundle-build"
BUNDLE_DIST_ROOT="${VERIFY_ROOT}-bundle-dist"
JOBS="${SWIFT_BUILD_JOBS:-2}"
VERIFY_BUNDLE="${STORAGE_CLEANER_VERIFY_BUNDLE:-1}"
UI_SMOKE="${STORAGE_CLEANER_UI_SMOKE:-0}"

cd "$ROOT_DIR"
"$ROOT_DIR/script/bootstrap.sh"

swift build --scratch-path "$VERIFY_ROOT/debug" --jobs "$JOBS"
# Both configurations run the complete suite; timing budgets remain unchanged.
swift test -c release --scratch-path "$VERIFY_ROOT/release" --jobs "$JOBS" -Xswiftc -enable-testing
swift build \
  --scratch-path "$VERIFY_ROOT/concurrency" \
  --jobs "$JOBS" \
  -Xswiftc -strict-concurrency=complete
swift test --scratch-path "$VERIFY_ROOT/debug" --jobs "$JOBS"

if grep -R -n -E '(^|[^[:alnum:]_])Process[[:space:]]*\(|\.terminate\(|\.forceTerminate\(' Sources/StorageCleanerMac/Views; then
  echo "SwiftUI Views must not launch processes or terminate applications." >&2
  exit 10
fi
if grep -R -n -E '/usr/(sbin|bin)/purge|Shell\.(run|capture)\(.*purge' \
    Sources/StorageCleanerMac/Features/Memory \
    Sources/StorageCleanerMac/Services/MemoryOptimizerService.swift; then
  echo "The memory feature must not execute purge." >&2
  exit 11
fi
# Private API is allowed only where listed with a reason; formatting cannot hide a call.
python3 "$ROOT_DIR/script/check_private_api.py"
# Cloud-sync conflict copies ("Name 2.swift") must never sit next to sources.
if find Sources Tests -type f -name '* [0-9]*' | grep -E ' [0-9]+\.[^/]+$'; then
  echo "Conflict copies found in Sources/Tests; move them out of the source tree." >&2
  exit 14
fi

"$ROOT_DIR/script/verify_menu_bar_performance.sh"

git diff --check

if [ "$VERIFY_BUNDLE" = "1" ]; then
  BUNDLE_MODE="--bundle-only"
  [ "$UI_SMOKE" != "1" ] || BUNDLE_MODE="--verify"
  SWIFT_BUILD_DIR="$BUNDLE_BUILD_ROOT" \
    DIST_DIR="$BUNDLE_DIST_ROOT" \
    "$ROOT_DIR/script/build_and_run.sh" "$BUNDLE_MODE"
  if otool -L "$BUNDLE_DIST_ROOT/StorageCleanerMac.app/Contents/MacOS/StorageCleanerMac" \
      | grep -q '/System/Library/PrivateFrameworks'; then
    echo "Built app links a private framework." >&2
    exit 13
  fi
fi

if [ "$UI_SMOKE" = "1" ]; then
  "$ROOT_DIR/script/test_memory_fixture.sh"
fi

echo "Repository verification passed."
