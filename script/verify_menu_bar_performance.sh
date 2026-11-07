#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# Runs locally only. Budgets are fixed in MenuBarPerformancePolicy and must
# not be increased to accommodate a regression. UI visibility is audited separately.
python3 "$ROOT_DIR/script/check_menu_bar_presentation.py"
swift test -c release --scratch-path "${STORAGE_CLEANER_VERIFY_ROOT:-/tmp/storage-cleaner-verify}/release" \
  --jobs "${SWIFT_BUILD_JOBS:-2}" -Xswiftc -enable-testing --filter MenuBarPerformanceRegressionTests
