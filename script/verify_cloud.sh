#!/usr/bin/env bash
# Host-independent gate for Linux Cloud Agents.
# SwiftPM, codesign, and the app bundle stay in script/verify.sh (macOS + Xcode).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export PYTHONDONTWRITEBYTECODE=1

python3 "$ROOT_DIR/script/check_private_api.py"
python3 "$ROOT_DIR/script/check_menu_bar_presentation.py"
python3 "$ROOT_DIR/script/test_helper_build_info.py"
python3 "$ROOT_DIR/script/test_helper_upgrade_status.py"

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
if find Sources Tests -type f -name '* [0-9]*' | grep -E ' [0-9]+\.[^/]+$'; then
  echo "Conflict copies found in Sources/Tests; move them out of the source tree." >&2
  exit 14
fi

git diff --check
echo "Host-independent verification passed."
