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
# Validate the standard-workload timing against the optimized shipping code.
# The unoptimized Debug kernel can exceed its wall-clock budget under local
# load. Keep the full workload and the stricter Release limit; run this exact
# test here instead of measuring it again in the Debug suite below.
BENCHMARK_TIMING_TEST="MacBenchmarkKernelTests.testStandardQuickKernelsCompleteWithinDeclaredLimits"
swift test -c release --scratch-path "$VERIFY_ROOT/release" --jobs "$JOBS" \
  --filter "$BENCHMARK_TIMING_TEST"
swift build \
  --scratch-path "$VERIFY_ROOT/concurrency" \
  --jobs "$JOBS" \
  -Xswiftc -strict-concurrency=complete
swift test --scratch-path "$VERIFY_ROOT/debug" --jobs "$JOBS" \
  --skip "$BENCHMARK_TIMING_TEST"

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
if grep -R -n -E '^[[:space:]]*import[[:space:]].*Private|dlopen\(.*PrivateFrameworks|-[[:space:]]*framework[[:space:]].*Private' \
    Sources Package.swift; then
  echo "Private framework usage is not allowed." >&2
  exit 12
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
