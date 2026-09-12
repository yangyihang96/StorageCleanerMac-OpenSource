#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${MEMORY_FIXTURE_BUILD_DIR:-/tmp/storage-cleaner-memory-fixture-build}"
OUTPUT_DIR="${MEMORY_FIXTURE_OUTPUT_DIR:-/tmp/storage-cleaner-memory-fixture}"
APP="$OUTPUT_DIR/MemoryFixtureApp.app"

cd "$ROOT_DIR"
/usr/bin/swift build --scratch-path "$BUILD_DIR" --product MemoryFixtureApp
BIN_DIR="$(/usr/bin/swift build --scratch-path "$BUILD_DIR" --show-bin-path)"

rm -rf -- "$APP"
mkdir -p "$APP/Contents/MacOS"
/usr/bin/ditto --norsrc "$BIN_DIR/MemoryFixtureApp" "$APP/Contents/MacOS/MemoryFixtureApp"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>MemoryFixtureApp</string>
  <key>CFBundleIdentifier</key><string>com.local.StorageCleanerMac.MemoryFixture</string>
  <key>CFBundleName</key><string>Memory Fixture App</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
chmod +x "$APP/Contents/MacOS/MemoryFixtureApp"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP"
