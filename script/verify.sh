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

# D106: test classes that can put a window or system UI on screen run only
# with every window confined to a named non-main display
# (script/run_display_bound_tests.sh); here they are skipped and reported as
# NOT RUN. The list must match the tests (exit 17) before anything is skipped.
# Without STORAGE_CLEANER_TEST_DISPLAY the test bundle's gate refuses every
# window and outside UI, so a window this list misses fails instead of showing.
unset STORAGE_CLEANER_TEST_DISPLAY STORAGE_CLEANER_TEST_DISPLAY_LOG
python3 -B "$ROOT_DIR/script/display_bound_tests.py" --self-test
python3 -B "$ROOT_DIR/script/display_target.py" --self-test
python3 -B "$ROOT_DIR/script/display_gate_log.py" --self-test
python3 -B "$ROOT_DIR/script/beta_install_swap.py" --self-test
python3 -B "$ROOT_DIR/script/display_bound_tests.py" --check
DISPLAY_BOUND_SKIP="$(python3 -B "$ROOT_DIR/script/display_bound_tests.py" --skip-regex)"
DISPLAY_BOUND_COUNT="$(python3 -B "$ROOT_DIR/script/display_bound_tests.py" --count skipped)"

# D106 supplement 2: swift test runs every test bundle with one list naming
# the selected tests of all test targets. XCTest cannot find another target's
# classes by name, so it lists every class in the process (objc_copyClassList),
# and in the StorageCleanerMacTests bundle, which loads SwiftUI and with it
# ContactsUICore, realizing those classes initializes CNContactStore, which
# tries to open the user's address book. So swift test only selects that
# bundle's own XCTest tests; every other test bundle runs alone under xctest,
# and Swift Testing, which finds its tests without listing classes, runs once
# for all targets. A run whose output names the address book database fails
# (exit 18).
MAIN_TEST_TARGET="StorageCleanerMacTests"
OTHER_TEST_TARGETS=()
MAIN_TEST_TARGET_FOUND=0
while IFS= read -r target; do
  if [ "$target" = "$MAIN_TEST_TARGET" ]; then MAIN_TEST_TARGET_FOUND=1; else OTHER_TEST_TARGETS+=("$target"); fi
done < <(python3 -B "$ROOT_DIR/script/display_bound_tests.py" --test-targets)
if [ "$MAIN_TEST_TARGET_FOUND" -ne 1 ]; then
  echo "Package.swift declares no $MAIN_TEST_TARGET test target." >&2
  exit 18
fi
check_address_book() {
  if grep -q "AddressBook/AddressBook-v" "$1"; then
    echo "A test process tried to open the address book ($1, DECISIONS D106 supplement 2)." >&2
    exit 18
  fi
}
run_tests() {
  local configuration="$1" bin target log
  shift
  log="$VERIFY_ROOT/test-$configuration-xctest-$MAIN_TEST_TARGET.log"
  swift test "$@" --disable-swift-testing --filter "^${MAIN_TEST_TARGET}\\." --skip "$DISPLAY_BOUND_SKIP" 2>&1 | tee "$log"
  check_address_book "$log"
  bin="$(swift build "$@" --show-bin-path)"
  for target in ${OTHER_TEST_TARGETS[@]+"${OTHER_TEST_TARGETS[@]}"}; do
    log="$VERIFY_ROOT/test-$configuration-xctest-$target.log"
    xcrun xctest "$bin/$target.xctest" 2>&1 | tee "$log"
    check_address_book "$log"
  done
  log="$VERIFY_ROOT/test-$configuration-swift-testing.log"
  swift test "$@" --disable-xctest --skip "$DISPLAY_BOUND_SKIP" 2>&1 | tee "$log"
  check_address_book "$log"
}

swift build --scratch-path "$VERIFY_ROOT/debug" --jobs "$JOBS"
# Both configurations run the complete suite except the display-bound
# classes; timing budgets remain unchanged.
run_tests release -c release --scratch-path "$VERIFY_ROOT/release" --jobs "$JOBS" -Xswiftc -enable-testing
swift build \
  --scratch-path "$VERIFY_ROOT/concurrency" \
  --jobs "$JOBS" \
  -Xswiftc -strict-concurrency=complete
run_tests debug --scratch-path "$VERIFY_ROOT/debug" --jobs "$JOBS"

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
# Nothing is deleted or elevated through a command string
# (DECISIONS D98 ④).
# Forbidden on any line, comments included: a static path in any directory
# whose last component is one of COMMANDS, a bare COMMANDS name given as the
# executable (fileURLWithPath:, Shell.run/capture) or as the first argv
# element, "rm -r/-f" text, AppleScript, legacy elevation and popen.
# Executables chosen at run time and argv arrays split across lines are not
# matched here; the inventory below lists every launch site and every program
# the sources name (BOARD L8). /usr/bin/sudo -A for verified App Store updates
# is not a command string and is allowed.
COMMANDS='rm|unlink|rmdir|srm|shred|sh|bash|zsh|dash|csh|ksh|tcsh|osascript|env|xargs|find|perl|python[0-9.]*|ruby'
if grep -R -n -E \
    -e "/($COMMANDS)([[:space:]\"'),;]|\$)" \
    -e "(fileURLWithPath:|Shell\.(run|capture)\()[[:space:]]*\"($COMMANDS)\"" \
    -e "arguments[[:space:]]*[:=][[:space:]]*\[[[:space:]]*\"($COMMANDS)\"" \
    -e '(^|[^[:alnum:]_-])rm[[:space:]]+-[[:alpha:]]*[rRf]' \
    -e 'do shell script|with administrator privileges|NSAppleScript|OSAScript|AuthorizationExecuteWithPrivileges' \
    -e '(^|[^[:alnum:]_])popen[[:space:]]*\(' \
    Sources; then
  echo "Sources must not delete or elevate through a shell, AppleScript or command string." >&2
  exit 15
fi
# Private API is allowed only where listed with a reason; formatting cannot hide a call.
python3 -B "$ROOT_DIR/script/test_check_private_api.py"
python3 -B "$ROOT_DIR/script/check_private_api.py"
# Every deletion, replacement, Trash move and process launch is listed with a
# reason and a count per file (BOARD L8, DECISIONS D100).
python3 -B "$ROOT_DIR/script/test_check_deletion_process_inventory.py"
python3 -B "$ROOT_DIR/script/check_deletion_process_inventory.py"
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

echo "NOT RUN (D106): $DISPLAY_BOUND_COUNT display-bound test classes — run script/run_display_bound_tests.sh on a named non-main display"
echo "Repository verification passed."
