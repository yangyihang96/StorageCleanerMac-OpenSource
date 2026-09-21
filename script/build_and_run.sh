#!/usr/bin/env bash
set -euo pipefail

export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release_version.env
source "$ROOT_DIR/script/release_version.env"

BETA_MODE=0
BETA_INSTALL=0
BETA_VERIFY=0
BETA_SCREENSHOTS=0
BETA_LOGS=0
BETA_TELEMETRY=0
MODE="${1:-run}"

if [ "${1:-}" = "--beta" ]; then
  BETA_MODE=1
  MODE="beta"
  shift
  for option in "$@"; do
    case "$option" in
      --install) BETA_INSTALL=1 ;;
      --verify) BETA_VERIFY=1 ;;
      --screenshots) BETA_SCREENSHOTS=1 ;;
      --logs) BETA_LOGS=1 ;;
      --telemetry) BETA_TELEMETRY=1 ;;
      --help|-h) MODE="help" ;;
      *)
        echo "unknown beta option: $option" >&2
        exit 2
        ;;
    esac
  done
  if [ "$BETA_VERIFY" -eq 1 ] || [ "$BETA_SCREENSHOTS" -eq 1 ] ||
     [ "$BETA_LOGS" -eq 1 ] || [ "$BETA_TELEMETRY" -eq 1 ]; then
    BETA_INSTALL=1
  fi
fi

PRODUCT_NAME="StorageCleanerMac"
APP_NAME="$PRODUCT_NAME"
APP_DISPLAY_NAME="存储清理助手"
BUNDLE_ID="com.local.StorageCleanerMac"
FAN_HELPER_NAME="StorageCleanerFanControlHelper"
FAN_HELPER_LABEL="com.local.StorageCleanerMac.FanControlHelper"
FAN_HELPER_PLIST="$FAN_HELPER_LABEL.plist"
MIN_SYSTEM_VERSION="14.0"
REQUIRED_LINK_SDK_MAJOR="${REQUIRED_LINK_SDK_MAJOR:-26}"
REQUIRED_ARCHITECTURE="${REQUIRED_ARCHITECTURE:-arm64}"
APP_VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"
APP_BUILD="${APP_BUILD:-$DEFAULT_APP_BUILD}"
UPDATE_FEED_URL="https://raw.githubusercontent.com/yangyihang96/StorageCleanerMacUpdates/main/appcast.xml"
SPARKLE_PUBLIC_KEY="9zE8Bh4PM/yp47qqC5RmAVnvkrqlX7TtT7POVCz2wEo="
LEADERBOARD_API_URL="${LEADERBOARD_API_URL:-$DEFAULT_LEADERBOARD_API_URL}"

SWIFT_BUILD_JOBS="${SWIFT_BUILD_JOBS:-2}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
BUILD_CONFIGURATION="debug"
BUILD_CONFIGURATION_NAME="Debug"
if [ "$MODE" = "--bundle-only" ] || [ "$MODE" = "bundle" ]; then
  case "${BUNDLE_CONFIGURATION:-debug}" in
    debug) ;;
    release) BUILD_CONFIGURATION="release"; BUILD_CONFIGURATION_NAME="Release" ;;
    *) echo "bundle configuration must be debug or release" >&2; exit 2 ;;
  esac
fi
SWIFT_BUILD_DIR_OVERRIDE="${SWIFT_BUILD_DIR:-}"
DIST_DIR_OVERRIDE="${DIST_DIR:-}"
BETA_DIST_DIR_OVERRIDE="${BETA_DIST_DIR:-}"
SWIFT_BUILD_DIR="${SWIFT_BUILD_DIR_OVERRIDE:-/tmp/storage-cleaner-swiftpm-build-run}"
DIST_DIR="${DIST_DIR_OVERRIDE:-/tmp/storage-cleaner-run-dist}"
APP_BUNDLE="$DIST_DIR/$PRODUCT_NAME.app"

if [ "$BETA_MODE" -eq 1 ]; then
  APP_NAME="StorageCleanerMacBeta"
  APP_DISPLAY_NAME="测试版"
  BUNDLE_ID="com.local.StorageCleanerMac.beta"
  FAN_HELPER_LABEL="com.local.StorageCleanerMac.beta.FanControlHelper"
  FAN_HELPER_PLIST="$FAN_HELPER_LABEL.plist"
  BUILD_CONFIGURATION="release"
  BUILD_CONFIGURATION_NAME="Beta"
  SWIFT_BUILD_DIR="${SWIFT_BUILD_DIR_OVERRIDE:-/tmp/storage-cleaner-beta-build}"
  DIST_DIR="${DIST_DIR_OVERRIDE:-/tmp/storage-cleaner-beta-package}"
  APP_BUNDLE="$DIST_DIR/测试版.app"
  # Keep the published verification copy outside Documents/File Provider roots.
  # Those roots can immediately reattach com.apple.FinderInfo to the app and its
  # nested Sparkle bundles and invalidate an otherwise correct strict code
  # signature after copying (same policy as make_release_dmg.sh DIST_DIR).
  BETA_ARTIFACT_DIR="${BETA_DIST_DIR_OVERRIDE:-/tmp/storage-cleaner-beta-dist}"
  BETA_ARTIFACT_BUNDLE="$BETA_ARTIFACT_DIR/测试版.app"
  UPDATE_FEED_URL=""
fi

APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_LAUNCH_DAEMONS="$APP_CONTENTS/Library/LaunchDaemons"
APP_BINARY="$APP_MACOS/$APP_NAME"
APP_FAN_HELPER="$APP_RESOURCES/$FAN_HELPER_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="AppIcon.icns"
ARTWORK_FILE="AppIcon.png"
BUILD_INFO_PLIST="$APP_RESOURCES/BuildInfo.plist"
BETA_WINDOW_CAPTURE_TOOL="/tmp/storage-cleaner-beta-window-capture"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short=12 HEAD)"
BUILD_DATE="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
if [ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]; then
  GIT_DIRTY=true
else
  GIT_DIRTY=false
fi

if [ "$BETA_MODE" -eq 1 ]; then
  APP_BUILD="$(date -u '+%Y%m%d%H%M%S')"
  for installed_beta in "/Applications/测试版.app" "$HOME/Applications/测试版.app"; do
    if [ -f "$installed_beta/Contents/Info.plist" ]; then
      previous_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$installed_beta/Contents/Info.plist" 2>/dev/null || true)"
      if [[ "$previous_build" =~ ^[0-9]{14}$ ]] && [[ "$APP_BUILD" < "$previous_build" || "$APP_BUILD" == "$previous_build" ]]; then
        APP_BUILD="$(printf '%014d' "$((10#$previous_build + 1))")"
      fi
    fi
  done
fi

cd "$ROOT_DIR"

configure_build_toolchain() {
  local stable_developer_dir="/Applications/Xcode.app/Contents/Developer"
  local candidate_sdk=""

  if [ -z "${DEVELOPER_DIR:-}" ] && [ -x "$stable_developer_dir/usr/bin/xcodebuild" ]; then
    candidate_sdk="$(DEVELOPER_DIR="$stable_developer_dir" xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
    if [[ "${candidate_sdk%%.*}" =~ ^[0-9]+$ ]] && [ "${candidate_sdk%%.*}" -ge "$REQUIRED_LINK_SDK_MAJOR" ]; then
      export DEVELOPER_DIR="$stable_developer_dir"
    fi
  fi

  BUILD_SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
  if ! [[ "${BUILD_SDK_VERSION%%.*}" =~ ^[0-9]+$ ]] || [ "${BUILD_SDK_VERSION%%.*}" -lt "$REQUIRED_LINK_SDK_MAJOR" ]; then
    echo "macOS SDK $REQUIRED_LINK_SDK_MAJOR or newer is required; found '${BUILD_SDK_VERSION:-none}'." >&2
    exit 5
  fi

  # The system tool dispatcher applies DEVELOPER_DIR consistently. Invoking
  # the toolchain's swift binary directly can lose the linked SDK version in
  # LC_BUILD_VERSION on some SwiftPM/Xcode combinations.
  SWIFT_TOOL="/usr/bin/swift"
  echo "build toolchain: $(xcodebuild -version | tr '\n' ' '), macOS SDK $BUILD_SDK_VERSION"
}

verify_executable_compatibility() {
  local binary="$1"
  local build_info=""
  local linked_minos=""
  local linked_sdk=""
  local architecture_info=""

  build_info="$(xcrun vtool -show-build "$binary")"
  linked_minos="$(awk '/^[[:space:]]*minos / { print $2; exit }' <<<"$build_info")"
  linked_sdk="$(awk '/^[[:space:]]*sdk / { print $2; exit }' <<<"$build_info")"
  architecture_info="$(/usr/bin/file "$binary")"

  if [ "$linked_minos" != "$MIN_SYSTEM_VERSION" ]; then
    echo "$binary: minimum macOS expected $MIN_SYSTEM_VERSION but found '${linked_minos:-none}'" >&2
    return 1
  fi
  if ! [[ "${linked_sdk%%.*}" =~ ^[0-9]+$ ]] || [ "${linked_sdk%%.*}" -lt "$REQUIRED_LINK_SDK_MAJOR" ]; then
    echo "$binary: linked macOS SDK must be $REQUIRED_LINK_SDK_MAJOR or newer; found '${linked_sdk:-none}'" >&2
    return 1
  fi
  if [[ "$architecture_info" != *"$REQUIRED_ARCHITECTURE"* ]]; then
    echo "$binary: required architecture $REQUIRED_ARCHITECTURE is missing ($architecture_info)" >&2
    return 1
  fi

  echo "verified: macOS $linked_minos+, linked SDK $linked_sdk, $REQUIRED_ARCHITECTURE"
}

configure_build_toolchain

if [ "$BETA_MODE" -eq 1 ] && [ "$MODE" != "help" ] && [ "$SIGN_IDENTITY" = "-" ]; then
  SIGN_IDENTITY="$(security find-identity -p codesigning -v 2>/dev/null \
    | awk -F'"' '/Apple Development:|Developer ID Application:/ { print $2; exit }')"
  if [ -z "$SIGN_IDENTITY" ]; then
    echo "Beta installation requires an Apple Development or Developer ID Application signing identity." >&2
    exit 7
  fi
fi

if ! [[ "$SWIFT_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "SWIFT_BUILD_JOBS must be a positive integer; found '$SWIFT_BUILD_JOBS'." >&2
  exit 2
fi

prepare_swift_build_dir() {
  local target="$1"
  local parent="${target%/*}"
  local name="${target##*/}"

  case "$target" in
    ""|/|/tmp|/private/tmp|*"/../"*|*/..)
      echo "refusing unsafe Swift build path: '$target'" >&2
      exit 6
      ;;
  esac

  if [[ "$parent" != "/tmp" && "$parent" != "/private/tmp" ]] ||
     [[ "$name" != storage-cleaner-* || "$name" == *"/"* ]]; then
    echo "Swift build path must be a direct storage-cleaner-* child of /tmp: '$target'" >&2
    exit 6
  fi

  if [ -L "$target" ]; then
    echo "refusing symlinked Swift build path: '$target'" >&2
    exit 6
  fi
  # SwiftPM invalidates changed sources and flags. Reuse this cache instead of
  # producing another complete dependency checkout for every review build.
  mkdir -p "$target"
}

clean_attrs() {
  local path="$1"
  xattr -cr "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.FinderInfo "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.ResourceFork "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.fileprovider.fpfs#P "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.macl "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.quarantine "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.provenance "$path" >/dev/null 2>&1 || true
  while IFS= read -r item; do
    xattr -c "$item" >/dev/null 2>&1 || true
    xattr -d com.apple.FinderInfo "$item" >/dev/null 2>&1 || true
    xattr -d com.apple.ResourceFork "$item" >/dev/null 2>&1 || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$item" >/dev/null 2>&1 || true
    xattr -d com.apple.macl "$item" >/dev/null 2>&1 || true
    xattr -d com.apple.provenance "$item" >/dev/null 2>&1 || true
    xattr -d com.apple.quarantine "$item" >/dev/null 2>&1 || true
  done < <(find "$path" -depth -print)
  xattr -c "$path" >/dev/null 2>&1 || true
  xattr -d com.apple.FinderInfo "$path" >/dev/null 2>&1 || true
  xattr -d com.apple.ResourceFork "$path" >/dev/null 2>&1 || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$path" >/dev/null 2>&1 || true
  xattr -d com.apple.macl "$path" >/dev/null 2>&1 || true
  xattr -d com.apple.provenance "$path" >/dev/null 2>&1 || true
  xattr -d com.apple.quarantine "$path" >/dev/null 2>&1 || true
}

sign_sparkle_framework() {
  local framework_path="$1"
  local version_path="$framework_path/Versions/B"
  local sign_args=(--force)

  if [ "$SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--options runtime)
  fi
  if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]]; then
    sign_args+=(--timestamp)
  fi

  clean_attrs "$framework_path"
  codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" \
    "$version_path/XPCServices/Installer.xpc" >/dev/null
  codesign "${sign_args[@]}" --preserve-metadata=entitlements \
    --sign "$SIGN_IDENTITY" \
    "$version_path/XPCServices/Downloader.xpc" >/dev/null
  codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" \
    "$version_path/Autoupdate" >/dev/null
  codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" \
    "$version_path/Updater.app" >/dev/null
  codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" \
    "$framework_path" >/dev/null
}

copy_resource_file() {
  local source="$1"
  local destination="$2"
  /bin/cp -f "$source" "$destination"
  xattr -c "$destination" >/dev/null 2>&1 || true
  xattr -d com.apple.FinderInfo "$destination" >/dev/null 2>&1 || true
  xattr -d com.apple.ResourceFork "$destination" >/dev/null 2>&1 || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$destination" >/dev/null 2>&1 || true
  xattr -d com.apple.macl "$destination" >/dev/null 2>&1 || true
  xattr -d com.apple.provenance "$destination" >/dev/null 2>&1 || true
  xattr -d com.apple.quarantine "$destination" >/dev/null 2>&1 || true
}

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--bundle-only]"
  echo "       $0 --beta [--install] [--verify] [--screenshots] [--logs|--telemetry]"
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--bundle-only|bundle|beta)
    ;;
  --help|help|-h)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

if [ "$BETA_MODE" -eq 0 ] && [ "$MODE" != "--bundle-only" ] && [ "$MODE" != "bundle" ]; then
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
fi

if [ "$BETA_MODE" -eq 1 ] && [ "$BETA_INSTALL" -eq 1 ]; then
  STORAGE_CLEANER_VERIFY_BUNDLE=0 "$ROOT_DIR/script/verify.sh"
fi

"$ROOT_DIR/script/verify_menu_bar_performance.sh"

prepare_swift_build_dir "$SWIFT_BUILD_DIR"
swift_build_args=(
  -c "$BUILD_CONFIGURATION"
  --scratch-path "$SWIFT_BUILD_DIR"
  --jobs "$SWIFT_BUILD_JOBS"
  -Xswiftc -disable-batch-mode
  # Swift 6.4's driver can emit SDK=deployment-target despite compiling
  # against Xcode's selected SDK. Supply the actual SDK version at link time;
  # do not patch LC_BUILD_VERSION after linking or weaken the verification.
  -Xlinker -platform_version
  -Xlinker macos
  -Xlinker "$MIN_SYSTEM_VERSION"
  -Xlinker "$BUILD_SDK_VERSION"
)
if [ "$BETA_MODE" -eq 1 ]; then
  swift_build_args+=(
    -Xswiftc -D
    -Xswiftc STORAGE_CLEANER_BETA
    -Xswiftc -g
  )
fi
"$SWIFT_TOOL" build "${swift_build_args[@]}"
BUILD_BIN_DIR="$("$SWIFT_TOOL" build "${swift_build_args[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$PRODUCT_NAME"
FAN_HELPER_BINARY="$BUILD_BIN_DIR/$FAN_HELPER_NAME"
SPARKLE_FRAMEWORK="$BUILD_BIN_DIR/Sparkle.framework"
SPARKLE_LICENSE="$SWIFT_BUILD_DIR/artifacts/sparkle/Sparkle/LICENSE"

if [ ! -d "$SPARKLE_FRAMEWORK" ]; then
  echo "missing Sparkle.framework at $SPARKLE_FRAMEWORK" >&2
  exit 3
fi
if [ ! -f "$SPARKLE_LICENSE" ]; then
  echo "missing Sparkle license at $SPARKLE_LICENSE" >&2
  exit 3
fi
if [ ! -x "$FAN_HELPER_BINARY" ]; then
  echo "missing fan-control helper at $FAN_HELPER_BINARY" >&2
  exit 3
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_FRAMEWORKS" "$APP_LAUNCH_DAEMONS"
/usr/bin/ditto --norsrc "$BUILD_BINARY" "$APP_BINARY"
/usr/bin/ditto --norsrc "$FAN_HELPER_BINARY" "$APP_FAN_HELPER"
/usr/bin/ditto --norsrc "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
copy_resource_file "$SPARKLE_LICENSE" "$APP_RESOURCES/Sparkle-LICENSE.txt"
copy_resource_file "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
copy_resource_file "$ROOT_DIR/Resources/CleanupRules.v2.json" "$APP_RESOURCES/CleanupRules.v2.json"
if [ "$BETA_MODE" -eq 1 ]; then
  cat >"$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$FAN_HELPER_LABEL</string>
  <key>BundleProgram</key>
  <string>Contents/Resources/$FAN_HELPER_NAME</string>
  <key>MachServices</key>
  <dict>
    <key>$FAN_HELPER_LABEL</key>
    <true/>
  </dict>
</dict>
</plist>
PLIST
else
  copy_resource_file \
    "$ROOT_DIR/Resources/$FAN_HELPER_PLIST" \
    "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST"
fi
chmod +x "$APP_BINARY" "$APP_FAN_HELPER"

if [ -f "$ROOT_DIR/Resources/$ICON_FILE" ]; then
  copy_resource_file "$ROOT_DIR/Resources/$ICON_FILE" "$APP_RESOURCES/$ICON_FILE"
fi
copy_resource_file "$ROOT_DIR/Resources/LandingArtwork-SafeCleanup-v1.png" "$APP_RESOURCES/LandingArtwork-SafeCleanup-v1.png"
copy_resource_file "$ROOT_DIR/Resources/LandingArtwork-BrowserPrivacy-v1.png" "$APP_RESOURCES/LandingArtwork-BrowserPrivacy-v1.png"
for artwork in "$ROOT_DIR"/Resources/GoldenArtwork-*.png; do
  [ -f "$artwork" ] || continue
  copy_resource_file "$artwork" "$APP_RESOURCES/$(basename "$artwork")"
done
if [ -f "$ROOT_DIR/Resources/$ARTWORK_FILE" ]; then
  copy_resource_file "$ROOT_DIR/Resources/$ARTWORK_FILE" "$APP_RESOURCES/$ARTWORK_FILE"
fi
while IFS= read -r -d '' resource; do
  copy_resource_file "$resource" "$APP_RESOURCES/$(basename "$resource")"
done < <(find "$ROOT_DIR/Resources" -maxdepth 1 -type f -name 'AppIcon*.png' ! -name 'AppIconSource.png' ! -name 'AppIconGenerated*.png' -print0)
find "$ROOT_DIR/Resources" -maxdepth 1 -type d -name '*.lproj' -exec sh -c '/usr/bin/ditto --norsrc "$1" "$2/$(basename "$1")"' sh {} "$APP_RESOURCES" \;
if [ "$BETA_MODE" -eq 1 ]; then
  while IFS= read -r -d '' localized_info; do
    rm -f -- "$localized_info"
    plutil -create xml1 "$localized_info"
    plutil -insert CFBundleName -string "$APP_DISPLAY_NAME" "$localized_info"
    plutil -insert CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$localized_info"
  done < <(find "$APP_RESOURCES" -path '*.lproj/InfoPlist.strings' -print0)
fi

if [ "$GIT_DIRTY" = true ]; then
  BUILD_INFO_DIRTY_XML="<true/>"
else
  BUILD_INFO_DIRTY_XML="<false/>"
fi
cat >"$BUILD_INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>version</key>
  <string>$APP_VERSION</string>
  <key>build</key>
  <string>$APP_BUILD</string>
  <key>commit</key>
  <string>$GIT_COMMIT</string>
  <key>dirty</key>
  $BUILD_INFO_DIRTY_XML
  <key>buildDate</key>
  <string>$BUILD_DATE</string>
  <key>configuration</key>
  <string>$BUILD_CONFIGURATION_NAME</string>
</dict>
</plist>
PLIST

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>StorageCleanerBuildConfiguration</key>
  <string>$BUILD_CONFIGURATION_NAME</string>
  <key>LeaderboardAPIURL</key>
  <string>$LEADERBOARD_API_URL</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
PLIST

if [ "$BETA_MODE" -eq 1 ]; then
  cat >>"$INFO_PLIST" <<PLIST
  <key>StorageCleanerBetaBuild</key>
  <true/>
  <key>SUEnableAutomaticChecks</key>
  <false/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
PLIST
else
  cat >>"$INFO_PLIST" <<PLIST
  <key>SUFeedURL</key>
  <string>$UPDATE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>21600</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
PLIST
fi

cat >>"$INFO_PLIST" <<PLIST
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST" "$BUILD_INFO_PLIST" "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST" >/dev/null

clean_attrs "$APP_BUNDLE"
sign_args=(--force)
if [ "$SIGN_IDENTITY" != "-" ]; then
  sign_args+=(--options runtime)
fi
if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]]; then
  sign_args+=(--timestamp)
fi
sign_sparkle_framework "$APP_FRAMEWORKS/Sparkle.framework"
codesign "${sign_args[@]}" -i "$FAN_HELPER_LABEL" \
  --sign "$SIGN_IDENTITY" "$APP_FAN_HELPER" >/dev/null
codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null

verify_sparkle_bundle() {
  local framework="$APP_FRAMEWORKS/Sparkle.framework"

  [ -d "$framework" ]
  [ -f "$APP_RESOURCES/Sparkle-LICENSE.txt" ]
  [ -f "$APP_RESOURCES/THIRD_PARTY_NOTICES.md" ]
  [ -x "$APP_FAN_HELPER" ]
  [ -f "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST" ]
  [ ! -e "$APP_RESOURCES/$FAN_HELPER_LABEL.legacy.plist" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "$FAN_HELPER_LABEL" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "Contents/Resources/$FAN_HELPER_NAME" ]
  [ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$FAN_HELPER_LABEL" "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "true" ]
  codesign --verify --strict --verbose=4 "$APP_FAN_HELPER"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LeaderboardAPIURL' "$INFO_PLIST")" = "$LEADERBOARD_API_URL" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")" = "$BUNDLE_ID" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$INFO_PLIST")" = "$APP_DISPLAY_NAME" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$INFO_PLIST")" = "$APP_NAME" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")" = "$APP_VERSION" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")" = "$APP_BUILD" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :version' "$BUILD_INFO_PLIST")" = "$APP_VERSION" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :build' "$BUILD_INFO_PLIST")" = "$APP_BUILD" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :commit' "$BUILD_INFO_PLIST")" = "$GIT_COMMIT" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :configuration' "$BUILD_INFO_PLIST")" = "$BUILD_CONFIGURATION_NAME" ]
  if [ "$BETA_MODE" -eq 1 ]; then
    while IFS= read -r -d '' localized_info; do
      [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$localized_info")" = "$APP_DISPLAY_NAME" ]
      [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$localized_info")" = "$APP_DISPLAY_NAME" ]
    done < <(find "$APP_RESOURCES" -path '*.lproj/InfoPlist.strings' -print0)
    ! /usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST" >/dev/null 2>&1
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$INFO_PLIST")" = "false" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$INFO_PLIST")" = "false" ]
    strings "$APP_BINARY" | grep -F "$BUNDLE_ID" >/dev/null
    strings "$APP_FAN_HELPER" | grep -F "$FAN_HELPER_LABEL" >/dev/null
  else
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")" = "$UPDATE_FEED_URL" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")" = "$SPARKLE_PUBLIC_KEY" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$INFO_PLIST")" = "true" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUAutomaticallyUpdate' "$INFO_PLIST")" = "true" ]
  fi
  [ "$(/usr/libexec/PlistBuddy -c 'Print :SUVerifyUpdateBeforeExtraction' "$INFO_PLIST")" = "true" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO_PLIST")" = "$MIN_SYSTEM_VERSION" ]
  otool -L "$APP_BINARY" | grep -F '@rpath/Sparkle.framework/Versions/B/Sparkle' >/dev/null
  local fan_helper_signing_info
  fan_helper_signing_info="$(codesign -d --verbose=4 "$APP_FAN_HELPER" 2>&1)"
  [[ "$fan_helper_signing_info" == *"Identifier=$FAN_HELPER_LABEL"* ]]
  if [ "$BETA_MODE" -eq 1 ]; then
    local app_signing_info
    local app_team
    local helper_team
    app_signing_info="$(codesign -d --verbose=4 "$APP_BUNDLE" 2>&1)"
    [[ "$app_signing_info" != *"Signature=adhoc"* ]]
    [[ "$fan_helper_signing_info" != *"Signature=adhoc"* ]]
    [[ "$app_signing_info" == *"flags="*"runtime"* ]]
    [[ "$fan_helper_signing_info" == *"flags="*"runtime"* ]]
    app_team="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$app_signing_info")"
    helper_team="$(awk -F= '/^TeamIdentifier=/{print $2; exit}' <<<"$fan_helper_signing_info")"
    [ -n "$app_team" ]
    [ "$app_team" = "$helper_team" ]
  fi
  verify_executable_compatibility "$APP_BINARY"
  codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
  if [ "$BETA_MODE" -eq 1 ]; then
    echo "verified: signed Beta bundle, isolated identity, local-update policy and BuildInfo"
  else
    echo "verified: Sparkle framework, feed, signing key and automatic update policy"
  fi
}

verify_sparkle_bundle

publish_beta_artifact() {
  [ "$BETA_MODE" -eq 1 ] || return 0
  mkdir -p "$BETA_ARTIFACT_DIR"
  rm -rf -- "$BETA_ARTIFACT_BUNDLE"
  /usr/bin/ditto --norsrc "$APP_BUNDLE" "$BETA_ARTIFACT_BUNDLE"
  clean_attrs "$BETA_ARTIFACT_BUNDLE"
  codesign --verify --deep --strict --verbose=4 "$BETA_ARTIFACT_BUNDLE"
  echo "published Beta artifact: $BETA_ARTIFACT_BUNDLE"
}

publish_beta_artifact

RUNTIME_APP_BUNDLE="$APP_BUNDLE"
BETA_INSTALL_PATH=""

verify_beta_bundle_at() {
  local bundle="$1"
  local contents="$bundle/Contents"
  local plist="$contents/Info.plist"
  local helper="$contents/Resources/$FAN_HELPER_NAME"
  local daemon_plist="$contents/Library/LaunchDaemons/$FAN_HELPER_PLIST"

  [ -x "$contents/MacOS/$APP_NAME" ]
  [ -f "$contents/Resources/BuildInfo.plist" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "$BUNDLE_ID" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")" = "$APP_DISPLAY_NAME" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$APP_BUILD" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$daemon_plist")" = "$FAN_HELPER_LABEL" ]
  [ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$FAN_HELPER_LABEL" "$daemon_plist")" = "true" ]
  codesign --verify --strict --verbose=4 "$helper"
  codesign --verify --deep --strict --verbose=4 "$bundle"
}

beta_running_pids() {
  local executable="$1/Contents/MacOS/$APP_NAME"
  pgrep -f "$executable" 2>/dev/null || true
}

quit_existing_beta_safely() {
  local bundle="$1"
  local pids
  local marker="/var/run/$FAN_HELPER_LABEL.active"
  pids="$(beta_running_pids "$bundle")"
  if [ -z "$pids" ]; then
    [ ! -e "$marker" ] || {
      echo "refusing to replace Beta while its fan-control recovery marker exists" >&2
      return 1
    }
    return 0
  fi

  echo "requesting normal Beta termination for PID(s): $pids"
  osascript -e "tell application \"System Events\" to if exists process \"$APP_NAME\" then tell process \"$APP_NAME\" to key code 53" >/dev/null 2>&1 || true
  sleep 0.2
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if [ -z "$(beta_running_pids "$bundle")" ]; then
      break
    fi
    sleep 0.5
  done
  if [ -n "$(beta_running_pids "$bundle")" ]; then
    echo "Beta did not finish its normal termination handshake; no files were replaced." >&2
    return 1
  fi
  if [ -e "$marker" ]; then
    echo "Beta quit but automatic fan-control recovery was not verified; no files were replaced." >&2
    return 1
  fi
  echo "verified: previous Beta exited normally with no active fan-control marker"
}

resolve_beta_install_path() {
  if [ -w /Applications ]; then
    printf '%s\n' "/Applications/测试版.app"
    return
  fi
  mkdir -p "$HOME/Applications"
  printf '%s\n' "$HOME/Applications/测试版.app"
}

verify_beta_runtime_path() {
  local bundle="$1"
  local executable="$bundle/Contents/MacOS/$APP_NAME"
  local pids
  pids="$(beta_running_pids "$bundle")"
  [ -n "$pids" ] || {
    echo "installed Beta process is not running" >&2
    return 1
  }
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    local command
    command="$(ps -p "$pid" -o command=)"
    [[ "$command" == "$executable"* ]] || {
      echo "PID $pid is not running from the installed Beta path: $command" >&2
      return 1
    }
  done <<<"$pids"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle/Contents/Info.plist")" = "$BUNDLE_ID" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$bundle/Contents/Info.plist")" = "$APP_VERSION" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$bundle/Contents/Info.plist")" = "$APP_BUILD" ]
  echo "verified: installed Beta PID(s) $pids run from $executable"
}

install_beta() {
  local target
  local parent
  local staging
  local stale
  local backup
  local had_backup=0
  target="$(resolve_beta_install_path)"
  parent="$(dirname "$target")"
  staging="$parent/.测试版.staging.$$.app"
  backup="$parent/测试版.previous.app"

  case "$target" in
    "/Applications/测试版.app"|"$HOME/Applications/测试版.app") ;;
    *)
      echo "refusing unsafe Beta install target: $target" >&2
      return 1
      ;;
  esac

  quit_existing_beta_safely "$target"
  # Remove stale staging bundles left behind by earlier interrupted installs;
  # each run stages under its own PID, so orphans are never reused.
  for stale in "$parent"/.测试版.staging.*.app; do
    [ -e "$stale" ] || continue
    rm -rf -- "$stale"
    echo "removed stale Beta staging bundle: $stale"
  done
  rm -rf -- "$staging"
  /usr/bin/ditto --norsrc "$APP_BUNDLE" "$staging"
  verify_beta_bundle_at "$staging"

  if [ -e "$target" ]; then
    rm -rf -- "$backup"
    mv "$target" "$backup"
    had_backup=1
  fi
  if ! mv "$staging" "$target"; then
    if [ "$had_backup" -eq 1 ]; then
      mv "$backup" "$target"
    fi
    return 1
  fi

  RUNTIME_APP_BUNDLE="$target"
  BETA_INSTALL_PATH="$target"
  if ! defaults read "$BUNDLE_ID" menuBar.restorePanelOnLaunch >/dev/null 2>&1; then
    defaults write "$BUNDLE_ID" menuBar.restorePanelOnLaunch -bool true
  fi
  /usr/bin/open -n "$target"
  sleep 2
  if ! verify_beta_runtime_path "$target"; then
    if ! quit_existing_beta_safely "$target"; then
      echo "new Beta failed verification and could not be safely stopped; backup remains at $backup" >&2
      return 1
    fi
    rm -rf -- "$target"
    if [ "$had_backup" -eq 1 ]; then
      mv "$backup" "$target"
      /usr/bin/open -n "$target" || true
      echo "new Beta failed to launch; previous Beta was restored" >&2
    else
      echo "new Beta failed to launch; no previous Beta existed" >&2
    fi
    return 1
  fi
  verify_beta_bundle_at "$target"
  echo "installed: $target"
}

open_app() {
  /usr/bin/open -n "$RUNTIME_APP_BUNDLE"
}

reopen_app() {
  /usr/bin/open "$RUNTIME_APP_BUNDLE"
}

verify_visible_window() {
  local attempts=12
  local output=""

  for _ in $(seq 1 "$attempts"); do
    if ! pgrep -x "$APP_NAME" >/dev/null; then
      sleep 0.5
      continue
    fi

    output="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  if exists process "$APP_NAME" then
    tell process "$APP_NAME"
      set frontmost to true
      set windowCount to count of windows
      if windowCount > 0 then
        repeat with w in windows
          try
            perform action "AXRaise" of w
          end try
        end repeat
      end if
      return (frontmost as text) & "," & (windowCount as text)
    end tell
  end if
end tell
APPLESCRIPT
)"

    if [[ "$output" == true,* ]]; then
      local count="${output#true,}"
      if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
        echo "verified: process running and $count window(s) visible"
        return 0
      fi
    fi

    sleep 0.5
  done

  echo "verification failed: $APP_NAME is not showing a visible window" >&2
  if [ -n "$output" ]; then
    echo "last window state: $output" >&2
  fi
  return 1
}

verify_reopen_restores_window() {
  local close_state=""

  close_state="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  if exists process "$APP_NAME" then
    tell process "$APP_NAME"
      set frontmost to true
      repeat 6 times
        set windowCount to count of windows
        repeat with windowIndex from 1 to windowCount
          try
            set i to contents of windowIndex
            set targetWindow to window i
            set shouldClose to false
            try
              set windowIdentifier to value of attribute "AXIdentifier" of targetWindow as text
              if windowIdentifier starts with "main-AppWindow-" then set shouldClose to true
            end try
            set windowSize to size of targetWindow
            if (item 1 of windowSize) is greater than or equal to 700 then set shouldClose to true
            if shouldClose then
              set closeButtons to (buttons of targetWindow whose subrole is "AXCloseButton")
              if (count of closeButtons) > 0 then
                click item 1 of closeButtons
              else
                perform action "AXClose" of targetWindow
              end if
              exit repeat
            end if
          end try
        end repeat
        delay 0.2
      end repeat
      delay 0.5
      return count of windows
    end tell
  end if
end tell
APPLESCRIPT
)"

  if ! pgrep -x "$APP_NAME" >/dev/null ||
     [[ "$close_state" != "0" && "$close_state" != "1" ]]; then
    echo "verification failed: close left multiple $APP_NAME windows active" >&2
    if [ -n "$close_state" ]; then
      echo "last close state: $close_state" >&2
    fi
    return 1
  fi

  reopen_app
  verify_visible_window
  echo "verified: close/reopen keeps Beta responsive and restores a visible window"
}

verify_localized_menu() {
  local language
  language="$(defaults read "$BUNDLE_ID" app.language 2>/dev/null || true)"
  if [ "$language" != "zhHans" ]; then
    echo "verified: menu localization skipped for app.language=${language:-system}"
    return 0
  fi

  local attempts=8
  local output=""
  for _ in $(seq 1 "$attempts"); do
    output="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  if exists process "$APP_NAME" then
    tell process "$APP_NAME"
      set menuTitles to {}
      repeat with menuItem in menu bar items of menu bar 1
        set end of menuTitles to title of menuItem
      end repeat
      return menuTitles as text
    end tell
  end if
end tell
APPLESCRIPT
)"

    if [[ "$output" == *"文件"* && "$output" == *"编辑"* && "$output" == *"窗口"* && "$output" == *"帮助"* ]]; then
      echo "verified: zh-Hans menu localized"
      return 0
    fi

    sleep 0.5
  done

  echo "verification failed: zh-Hans menu is not localized" >&2
  if [ -n "$output" ]; then
    echo "last menu titles: $output" >&2
  fi
  return 1
}

verify_settings_runtime_info() {
  local attempts=8
  local output=""
  local bundle_version=""
  local bundle_build=""
  local bundle_identifier=""

  osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  if exists process "$APP_NAME" then
    tell process "$APP_NAME"
      repeat with appMenuItem in menu bar items of menu bar 1
        try
          if exists menu item "设置…" of menu 1 of appMenuItem then
            click menu item "设置…" of menu 1 of appMenuItem
            exit repeat
          end if
          if exists menu item "Settings…" of menu 1 of appMenuItem then
            click menu item "Settings…" of menu 1 of appMenuItem
            exit repeat
          end if
        end try
      end repeat
    end tell
  end if
end tell
APPLESCRIPT

  for _ in $(seq 1 "$attempts"); do
    output="$(osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  if exists process "$APP_NAME" then
    tell process "$APP_NAME"
      set settingsWindowCount to 0
      repeat with w in windows
        set windowName to name of w
        if windowName contains "设置" or windowName contains "Settings" ¬
          or windowName is "通用" or windowName is "General" ¬
          or windowName is "扫描与安全" or windowName is "Scan & Safety" ¬
          or windowName is "权限" or windowName is "Access" ¬
          or windowName is "系统控制" or windowName is "System Control" ¬
          or windowName is "应用更新" or windowName is "App Updates" ¬
          or windowName is "关于" or windowName is "About" then
          set settingsWindowCount to settingsWindowCount + 1
        end if
      end repeat
      return settingsWindowCount as text
    end tell
  end if
end tell
APPLESCRIPT
)"

    if [ "${output:-0}" -gt 0 ] 2>/dev/null; then
      bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST")"
      bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"
      bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST")"
      if [ "$bundle_identifier" = "$BUNDLE_ID" ] && [ -n "$bundle_version" ] && [ -n "$bundle_build" ]; then
        echo "verified: settings window opens and runtime metadata is present"
        return 0
      fi
    fi

    sleep 0.5
  done

  echo "verification failed: settings window or runtime metadata is not available" >&2
  if [ -n "$output" ]; then
    echo "last settings window count: $output" >&2
  fi
  if [ -n "$bundle_identifier$bundle_version$bundle_build" ]; then
    echo "last runtime metadata: bundle_id=$bundle_identifier, version=$bundle_version, build=$bundle_build" >&2
  fi
  return 1
}

beta_overview_card_accessibility() {
  local card_index="$1"
  local operation="$2"
  osascript - "$APP_NAME" "$card_index" "$operation" <<'APPLESCRIPT' 2>/dev/null || true
on run arguments
  set processName to item 1 of arguments
  set cardIndex to item 2 of arguments as integer
  set operationName to item 3 of arguments
  tell application "System Events"
    if not (exists process processName) then return ""
    tell process processName
      repeat with targetWindow in windows
        try
          set areaCount to count of scroll areas of group 1 of targetWindow
          repeat with areaIndex from 1 to areaCount
            set i to contents of areaIndex
            set targetArea to scroll area i of group 1 of targetWindow
            if (count of buttons of targetArea) is greater than or equal to 6 then
              set targetButton to button cardIndex of targetArea
              if operationName is "press" then
                perform action "AXPress" of targetButton
                return "pressed"
              end if
              set elementPosition to position of targetButton
              set elementSize to size of targetButton
              return (item 1 of elementPosition as text) & "," & (item 2 of elementPosition as text) & "," & (item 1 of elementSize as text) & "," & (item 2 of elementSize as text)
            end if
          end repeat
        end try
      end repeat
    end tell
  end tell
  return ""
end run
APPLESCRIPT
}

beta_press_palette_action() {
  local identifier="$1"
  osascript - "$APP_NAME" "$identifier" <<'APPLESCRIPT' 2>/dev/null || true
on run arguments
  set processName to item 1 of arguments
  set targetIdentifier to item 2 of arguments
  tell application "System Events"
    if not (exists process processName) then return ""
    tell process processName
      repeat with targetWindow in windows
        try
          if (name of targetWindow) is "硬件控制浮层" or (name of targetWindow) is "Hardware Control Palette" then
            set paletteContent to group 1 of group 1 of targetWindow
            repeat with targetButton in buttons of paletteContent
              try
                if (value of attribute "AXIdentifier" of targetButton as text) is targetIdentifier then
                  perform action "AXPress" of targetButton
                  return "pressed"
                end if
              end try
            end repeat
          end if
        end try
      end repeat
    end tell
  end tell
  return ""
end run
APPLESCRIPT
}

beta_click_accessibility_label() {
  local label="$1"
  local result
  result="$(osascript - "$APP_NAME" "$label" <<'APPLESCRIPT' 2>/dev/null || true
on run arguments
  set processName to item 1 of arguments
  set targetLabel to item 2 of arguments
  tell application "System Events"
    if not (exists process processName) then return "missing-process"
    tell process processName
      repeat with elementItem in entire contents
        try
          set elementName to name of elementItem as text
        on error
          set elementName to ""
        end try
        try
          set elementDescription to description of elementItem as text
        on error
          set elementDescription to ""
        end try
        try
          set elementHelp to value of attribute "AXHelp" of elementItem as text
        on error
          set elementHelp to ""
        end try
        try
          set elementIdentifier to value of attribute "AXIdentifier" of elementItem as text
        on error
          set elementIdentifier to ""
        end try
        if elementName is targetLabel or elementDescription is targetLabel or elementHelp is targetLabel or elementIdentifier is targetLabel then
          try
            perform action "AXPress" of elementItem
            return "pressed"
          end try
        end if
      end repeat
    end tell
  end tell
  return "missing"
end run
APPLESCRIPT
)"
  if [ "$result" = "pressed" ]; then
    return 0
  fi
  case "$label" in
    "打开 CPU 温度详情"|"Open CPU Temperature Details"|"打开硬件监测详情"|"Open Hardware Monitoring Details")
      [ "$(beta_overview_card_accessibility 5 press)" = "pressed" ]
      ;;
    "打开电池监测详情"|"Open Battery Monitoring Details"|"打开电池与电源详情"|"Open Battery and Power Details")
      [ "$(beta_overview_card_accessibility 8 press)" = "pressed" ]
      ;;
    "打开风扇控制"|"Open Fan Controls")
      [ "$(beta_overview_card_accessibility 7 press)" = "pressed" ]
      ;;
    "打开电源模式控制"|"Open Power Mode Controls")
      [ "$(beta_overview_card_accessibility 9 press)" = "pressed" ]
      ;;
    "内存"|"Memory")
      [ "$(beta_overview_card_accessibility 2 press)" = "pressed" ]
      ;;
    "自定义风扇曲线"|"Custom Fan Curve")
      [ "$(beta_press_palette_action "$label")" = "pressed" ]
      ;;
    "编辑曲线"|"Edit Curve")
      [ "$(beta_press_palette_action "$label")" = "pressed" ]
      ;;
    *) return 1 ;;
  esac
}

beta_accessibility_frame() {
  local label="$1"
  local frame
  frame="$(osascript - "$APP_NAME" "$label" <<'APPLESCRIPT' 2>/dev/null || true
on run arguments
  set processName to item 1 of arguments
  set targetLabel to item 2 of arguments
  tell application "System Events"
    if not (exists process processName) then return ""
    tell process processName
      repeat with elementItem in entire contents
        try
          set elementName to name of elementItem as text
        on error
          set elementName to ""
        end try
        try
          set elementDescription to description of elementItem as text
        on error
          set elementDescription to ""
        end try
        if elementName is targetLabel or elementDescription is targetLabel then
          try
            set elementPosition to position of elementItem
            set elementSize to size of elementItem
            return (item 1 of elementPosition as text) & "," & (item 2 of elementPosition as text) & "," & (item 1 of elementSize as text) & "," & (item 2 of elementSize as text)
          end try
        end if
      end repeat
    end tell
  end tell
  return ""
end run
APPLESCRIPT
)"
  if [ -n "$frame" ]; then
    echo "$frame"
    return 0
  fi
  case "$label" in
    "内存历史三级详情"|"Memory History Deep Detail")
      beta_overview_card_accessibility 2 frame
      ;;
  esac
}

close_large_beta_windows() {
  osascript - "$APP_NAME" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run arguments
  set processName to item 1 of arguments
  tell application "System Events"
    if exists process processName then
      tell process processName
        set windowCount to count of windows
        repeat with windowIndex from windowCount to 1 by -1
          try
            set i to contents of windowIndex
            set targetWindow to window i
            set windowSize to size of targetWindow
            if (item 1 of windowSize) is greater than or equal to 700 then
              set closeButtons to (buttons of targetWindow whose subrole is "AXCloseButton")
              if (count of closeButtons) > 0 then
                click item 1 of closeButtons
              else
                perform action "AXClose" of targetWindow
              end if
            end if
          end try
        end repeat
      end tell
    end if
  end tell
end run
APPLESCRIPT
}

capture_beta_visible_windows() {
  local destination="$1"
  local pid
  verify_visible_window >/dev/null
  pid="$(beta_running_pids "$RUNTIME_APP_BUNDLE" | head -n 1)"
  [ -n "$pid" ] || {
    echo "no visible Beta window available for $destination" >&2
    return 1
  }
  "$BETA_WINDOW_CAPTURE_TOOL" "$pid" "$destination"
  [ -s "$destination" ]
}

park_pointer_for_beta_capture() {
  if command -v cliclick >/dev/null 2>&1; then
    cliclick "m:20,20"
  fi
}

capture_beta_screenshots() {
  local output_dir="$ROOT_DIR/artifacts/beta-preview/$APP_BUILD"
  local prior_appearance=""
  local had_appearance=0
  local prior_language=""
  local had_language=0
  local prior_section=""
  local had_section=0

  mkdir -p "$output_dir"
  rm -f -- "$BETA_WINDOW_CAPTURE_TOOL"
  xcrun swiftc -parse-as-library \
    -framework AppKit \
    -framework ScreenCaptureKit \
    "$ROOT_DIR/script/capture_app_windows.swift" \
    -o "$BETA_WINDOW_CAPTURE_TOOL"
  if defaults read "$BUNDLE_ID" app.appearance >/dev/null 2>&1; then
    prior_appearance="$(defaults read "$BUNDLE_ID" app.appearance)"
    had_appearance=1
  fi
  if defaults read "$BUNDLE_ID" app.language >/dev/null 2>&1; then
    prior_language="$(defaults read "$BUNDLE_ID" app.language)"
    had_language=1
  fi
  if defaults read "$BUNDLE_ID" menuBar.panelSection >/dev/null 2>&1; then
    prior_section="$(defaults read "$BUNDLE_ID" menuBar.panelSection)"
    had_section=1
  fi
  defaults write "$BUNDLE_ID" app.language zhHans
  defaults write "$BUNDLE_ID" menuBar.panelSection overview

  # Re-launch so restorePanelOnLaunch presents the small panel after the
  # settings/reopen checks have intentionally closed every app window.
  quit_existing_beta_safely "$RUNTIME_APP_BUNDLE"
  park_pointer_for_beta_capture
  /usr/bin/open -n "$RUNTIME_APP_BUNDLE"
  sleep 3
  park_pointer_for_beta_capture
  close_large_beta_windows
  sleep 1
  capture_beta_visible_windows "$output_dir/01-main-small-window.png"

  if beta_click_accessibility_label "打开 CPU 温度详情"; then
    sleep 2
    capture_beta_visible_windows "$output_dir/02-hardware-detail.png"
    if beta_click_accessibility_label "打开风扇控制"; then
      sleep 1
      capture_beta_visible_windows "$output_dir/03-fan-control-current-state.png"
      if beta_click_accessibility_label "自定义风扇曲线"; then
        sleep 1
        capture_beta_visible_windows "$output_dir/04-fan-curve-editor.png"
      fi
    fi
  fi

  if beta_click_accessibility_label "打开电源模式控制"; then
    sleep 1
    capture_beta_visible_windows "$output_dir/05-power-control-overview.png"
  fi

  if beta_click_accessibility_label "打开电池监测详情"; then
    sleep 1
    capture_beta_visible_windows "$output_dir/06-battery-detail.png"
    if beta_click_accessibility_label "打开电源模式控制"; then
      sleep 1
      capture_beta_visible_windows "$output_dir/07-power-control-detail.png"
    fi
  fi

  quit_existing_beta_safely "$RUNTIME_APP_BUNDLE"
  defaults write "$BUNDLE_ID" app.appearance light
  defaults write "$BUNDLE_ID" menuBar.panelSection overview
  park_pointer_for_beta_capture
  /usr/bin/open -n "$RUNTIME_APP_BUNDLE"
  sleep 3
  park_pointer_for_beta_capture
  close_large_beta_windows
  sleep 1
  capture_beta_visible_windows "$output_dir/08-light-mode.png"

  quit_existing_beta_safely "$RUNTIME_APP_BUNDLE"
  defaults write "$BUNDLE_ID" app.appearance dark
  defaults write "$BUNDLE_ID" menuBar.panelSection overview
  park_pointer_for_beta_capture
  /usr/bin/open -n "$RUNTIME_APP_BUNDLE"
  sleep 3
  park_pointer_for_beta_capture
  close_large_beta_windows
  sleep 1
  capture_beta_visible_windows "$output_dir/09-dark-mode.png"

  quit_existing_beta_safely "$RUNTIME_APP_BUNDLE"
  if [ "$had_appearance" -eq 1 ]; then
    defaults write "$BUNDLE_ID" app.appearance "$prior_appearance"
  else
    defaults delete "$BUNDLE_ID" app.appearance >/dev/null 2>&1 || true
  fi
  if [ "$had_language" -eq 1 ]; then
    defaults write "$BUNDLE_ID" app.language "$prior_language"
  else
    defaults delete "$BUNDLE_ID" app.language >/dev/null 2>&1 || true
  fi
  if [ "$had_section" -eq 1 ]; then
    defaults write "$BUNDLE_ID" menuBar.panelSection "$prior_section"
  else
    defaults delete "$BUNDLE_ID" menuBar.panelSection >/dev/null 2>&1 || true
  fi
  /usr/bin/open -n "$RUNTIME_APP_BUNDLE"
  sleep 3
  close_large_beta_windows
  verify_beta_runtime_path "$RUNTIME_APP_BUNDLE"
  rm -f -- "$BETA_WINDOW_CAPTURE_TOOL"

  cat >"$output_dir/README.md" <<README
# Beta $APP_BUILD real-window captures

- Every PNG was captured from the installed $RUNTIME_APP_BUNDLE process.
- No cleanup, power-mode write, Helper registration, manual fan target, maximum fan mode, or fan curve was applied.
- 03-fan-control-current-state.png records the real authorization and fan-control state; it does not claim that manual mode was activated.
- 04-fan-curve-editor.png is the real editor UI only; opening it does not apply a curve or write fan targets.
- 05 and 07 record the same reusable power palette from its two supported entry points.
README
  echo "screenshots: $output_dir"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_visible_window
    verify_localized_menu
    verify_settings_runtime_info
    verify_reopen_restores_window
    ;;
  --bundle-only|bundle)
    echo "verified: app bundle assembled without launching"
    ;;
  beta)
    if [ "$BETA_INSTALL" -eq 1 ]; then
      install_beta
      if [ "$BETA_VERIFY" -eq 1 ] || [ "$BETA_SCREENSHOTS" -eq 1 ]; then
        verify_visible_window
        verify_localized_menu
        verify_settings_runtime_info
        verify_reopen_restores_window
        verify_beta_runtime_path "$RUNTIME_APP_BUNDLE"
      fi
      if [ "$BETA_SCREENSHOTS" -eq 1 ]; then
        capture_beta_screenshots
      fi
      if [ "$BETA_LOGS" -eq 1 ]; then
        /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
      elif [ "$BETA_TELEMETRY" -eq 1 ]; then
        /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
      fi
    else
      echo "verified: Beta bundle assembled at $BETA_ARTIFACT_BUNDLE"
    fi
    ;;
esac
