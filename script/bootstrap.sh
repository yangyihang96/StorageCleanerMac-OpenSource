#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${STORAGE_CLEANER_BOOTSTRAP_DIR:-/tmp/storage-cleaner-bootstrap}"

[ "$(uname -s)" = "Darwin" ] || {
  echo "StorageCleanerMac requires macOS." >&2
  exit 2
}
for tool in git swift xcrun codesign grep; do
  command -v "$tool" >/dev/null || {
    echo "Missing required tool: $tool" >&2
    exit 3
  }
done
[ -f "$ROOT_DIR/Package.swift" ] || {
  echo "Package.swift is missing." >&2
  exit 4
}
[ -f "$ROOT_DIR/Package.resolved" ] || {
  echo "Package.resolved is missing; dependencies are not pinned." >&2
  exit 4
}

cd "$ROOT_DIR"
swift --version
echo "macOS SDK $(xcrun --sdk macosx --show-sdk-version)"
swift package --scratch-path "$BUILD_DIR" resolve
swift package --scratch-path "$BUILD_DIR" show-dependencies --format json >/dev/null
echo "Bootstrap verification passed."
