#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFT_TEST_DIR="${SWIFT_TEST_DIR:-$HOME/.storage-cleaner-swiftpm-test}"

cd "$ROOT_DIR"
mkdir -p "$SWIFT_TEST_DIR"
if [ -d "$SWIFT_TEST_DIR" ]; then
  xattr -cr "$SWIFT_TEST_DIR" >/dev/null 2>&1 || true
fi

COPYFILE_DISABLE=1 swift test --scratch-path "$SWIFT_TEST_DIR" -Xswiftc -disable-batch-mode "$@"
