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
BETA_NO_LAUNCH=0
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
      --no-launch) BETA_NO_LAUNCH=1 ;;
      --help|-h) MODE="help" ;;
      *)
        echo "unknown beta option: $option" >&2
        exit 2
        ;;
    esac
  done
  if [ "$BETA_VERIFY" -eq 1 ] || [ "$BETA_SCREENSHOTS" -eq 1 ] ||
     [ "$BETA_LOGS" -eq 1 ] || [ "$BETA_TELEMETRY" -eq 1 ]; then
    if [ "$BETA_NO_LAUNCH" -eq 1 ] && [ "$MODE" != "help" ]; then
      echo "--no-launch never opens the app; it cannot be combined with --verify, --screenshots, --logs or --telemetry" >&2
      exit 2
    fi
    BETA_INSTALL=1
  fi
  if [ "$BETA_NO_LAUNCH" -eq 1 ] && [ "$BETA_INSTALL" -eq 0 ] && [ "$MODE" != "help" ]; then
    echo "--no-launch is an install mode: use --beta --install --no-launch" >&2
    exit 2
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
  APP_VERSION="${BETA_APP_VERSION:-$DEFAULT_BETA_APP_VERSION}"
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
  UPDATE_FEED_URL="https://raw.githubusercontent.com/yangyihang96/StorageCleanerMacUpdates/main/appcast-beta.xml"
fi

FILE_HELPER_NAME="StorageCleanerFileOperationHelper"
FILE_HELPER_LABEL="$BUNDLE_ID.FileOperationHelper"
FILE_HELPER_PLIST="$FILE_HELPER_LABEL.plist"
# D88: Finder right-click entry. A thin Finder Sync extension that only hands
# selected .app paths to this app's existing uninstall review, by opening them
# with its host app (open-documents; there is no URL scheme). Only the
# installed Beta (--beta --install) embeds it: run, --bundle-only and a Beta
# assembled without --install never carry an extension, so no copy with the
# release identity, and no uninstalled build, registers one. Inside the
# extension the menu appears only when its host is /Applications/测试版.app.
FINDER_EXTENSION_NAME="StorageCleanerFinderExtension"
FINDER_EXTENSION_ID="$BUNDLE_ID.FinderUninstall"
FINDER_EXTENSION_PRINCIPAL_CLASS="StorageCleanerFinderUninstallExtension"
EMBED_FINDER_EXTENSION=0
if [ "$BETA_MODE" -eq 1 ] && [ "$BETA_INSTALL" -eq 1 ]; then
  EMBED_FINDER_EXTENSION=1
fi

APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_LAUNCH_DAEMONS="$APP_CONTENTS/Library/LaunchDaemons"
APP_PLUGINS="$APP_CONTENTS/PlugIns"
FINDER_EXTENSION_BUNDLE="$APP_PLUGINS/$FINDER_EXTENSION_NAME.appex"
FINDER_EXTENSION_BINARY="$FINDER_EXTENSION_BUNDLE/Contents/MacOS/$FINDER_EXTENSION_NAME"
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
  echo "usage: $0 --beta [--install] [--verify] [--screenshots] [--logs|--telemetry]   (normal development loop)"
  echo "       $0 --beta --install --no-launch   (D106: install without quitting or opening anything;"
  echo "           refuses while the Beta or its helpers run; then script/launch_beta_acceptance.sh)"
  echo "       $0 [run|--debug|--logs|--telemetry|--verify|--bundle-only]   (release identity; shares the installed app's data)"
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

# The non-Beta modes launch a build with the release bundle identifier, which
# shares data and preferences with the installed app. Never kill a running
# copy: it may be in the middle of a cleanup, restore or fan-control session.
if [ "$BETA_MODE" -eq 0 ] && [ "$MODE" != "--bundle-only" ] && [ "$MODE" != "bundle" ] \
  && pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  if [ "${STORAGE_CLEANER_QUIT_RUNNING_APP:-0}" != "1" ]; then
    echo "$APP_NAME is running. Quit it first, or use --beta for the development loop." >&2
    echo "Set STORAGE_CLEANER_QUIT_RUNNING_APP=1 to ask it to quit normally." >&2
    exit 3
  fi
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in $(seq 1 40); do
    pgrep -x "$APP_NAME" >/dev/null 2>&1 || break
    sleep 0.5
  done
  if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "$APP_NAME did not quit; it may be finishing work. Not forcing it." >&2
    exit 3
  fi
fi

case "${STORAGE_CLEANER_SKIP_TESTS:-0}" in
  0)
    if [ "$BETA_MODE" -eq 1 ] && [ "$BETA_INSTALL" -eq 1 ]; then
      STORAGE_CLEANER_VERIFY_BUNDLE=0 "$ROOT_DIR/script/verify.sh"
    fi
    "$ROOT_DIR/script/verify_menu_bar_performance.sh"
    ;;
  1)
    echo "NOT RUN: test suites and performance tests explicitly skipped by request (STORAGE_CLEANER_SKIP_TESTS=1)."
    echo "Bundle, signing, architecture and update configuration checks remain enabled."
    ;;
  *) echo "STORAGE_CLEANER_SKIP_TESTS must be 0 or 1" >&2; exit 2 ;;
esac

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
# Relink only this product with a signed, embedded helper-specific Info.plist.
# The surrounding App/BuildInfo plist is never the helper's version authority.
HELPER_SIGNED_INFO="$SWIFT_BUILD_DIR/helper-signed-info-$APP_BUILD.plist"
python3 "$ROOT_DIR/script/helper_build_info.py" "$HELPER_SIGNED_INFO" "$APP_BUILD" "$FAN_HELPER_LABEL" "$FAN_HELPER_NAME"
"$SWIFT_TOOL" build "${swift_build_args[@]}" --product "$FAN_HELPER_NAME" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$HELPER_SIGNED_INFO"
FILE_HELPER_SIGNED_INFO="$SWIFT_BUILD_DIR/file-helper-signed-info-$APP_BUILD.plist"
python3 "$ROOT_DIR/script/helper_build_info.py" "$FILE_HELPER_SIGNED_INFO" "$APP_BUILD" "$FILE_HELPER_LABEL" "$FILE_HELPER_NAME"
"$SWIFT_TOOL" build "${swift_build_args[@]}" --product "$FILE_HELPER_NAME" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$FILE_HELPER_SIGNED_INFO"
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
[ -x "$BUILD_BIN_DIR/StorageCleanerUpdateAskpass" ]
/usr/bin/ditto --norsrc "$BUILD_BIN_DIR/StorageCleanerUpdateAskpass" "$APP_RESOURCES/StorageCleanerUpdateAskpass"
[ -x "$BUILD_BIN_DIR/$FILE_HELPER_NAME" ]
/usr/bin/ditto --norsrc "$BUILD_BIN_DIR/$FILE_HELPER_NAME" "$APP_RESOURCES/$FILE_HELPER_NAME"
cat >"$APP_LAUNCH_DAEMONS/$FILE_HELPER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$FILE_HELPER_LABEL</string>
<key>BundleProgram</key><string>Contents/Resources/$FILE_HELPER_NAME</string>
<key>MachServices</key><dict><key>$FILE_HELPER_LABEL</key><true/></dict>
</dict></plist>
PLIST
chmod +x "$APP_RESOURCES/$FILE_HELPER_NAME"
plutil -lint "$APP_LAUNCH_DAEMONS/$FILE_HELPER_PLIST" >/dev/null
if [ "$EMBED_FINDER_EXTENSION" -eq 1 ]; then
[ -x "$BUILD_BIN_DIR/$FINDER_EXTENSION_NAME" ]
mkdir -p "$FINDER_EXTENSION_BUNDLE/Contents/MacOS"
/usr/bin/ditto --norsrc "$BUILD_BIN_DIR/$FINDER_EXTENSION_NAME" "$FINDER_EXTENSION_BINARY"
chmod +x "$FINDER_EXTENSION_BINARY"
cat >"$FINDER_EXTENSION_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$FINDER_EXTENSION_NAME</string>
<key>CFBundleIdentifier</key><string>$FINDER_EXTENSION_ID</string>
<key>CFBundleName</key><string>$APP_DISPLAY_NAME</string>
<key>CFBundleDisplayName</key><string>$APP_DISPLAY_NAME</string>
<key>CFBundlePackageType</key><string>XPC!</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$APP_BUILD</string>
<key>LSMinimumSystemVersion</key><string>$MIN_SYSTEM_VERSION</string>
<key>NSExtension</key><dict>
<key>NSExtensionAttributes</key><dict/>
<key>NSExtensionPointIdentifier</key><string>com.apple.FinderSync</string>
<key>NSExtensionPrincipalClass</key><string>$FINDER_EXTENSION_PRINCIPAL_CLASS</string>
</dict>
</dict></plist>
PLIST
FINDER_EXTENSION_ENTITLEMENTS="$SWIFT_BUILD_DIR/finder-extension.entitlements"
cat >"$FINDER_EXTENSION_ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
</dict></plist>
PLIST
plutil -lint "$FINDER_EXTENSION_BUNDLE/Contents/Info.plist" "$FINDER_EXTENSION_ENTITLEMENTS" >/dev/null
fi
/usr/bin/ditto --norsrc "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
copy_resource_file "$SPARKLE_LICENSE" "$APP_RESOURCES/Sparkle-LICENSE.txt"
copy_resource_file "$ROOT_DIR/THIRD_PARTY_NOTICES.md" "$APP_RESOURCES/THIRD_PARTY_NOTICES.md"
copy_resource_file "$ROOT_DIR/Resources/CleanupRules.v2.json" "$APP_RESOURCES/CleanupRules.v2.json"
# D116: Little Snitch reads this policy (and the .lproj translations copied
# below) to explain each connection; it is covered by the bundle signature.
copy_resource_file "$ROOT_DIR/Resources/InternetAccessPolicy.plist" "$APP_RESOURCES/InternetAccessPolicy.plist"
source "$ROOT_DIR/script/benchmark_resources.sh"
copy_benchmark_resources
if [ "$BETA_MODE" -eq 1 ]; then
  # D102 L3: the same launch keys as Resources/$FAN_HELPER_PLIST, so the Beta
  # helper also starts at boot to return the fans to system control.
  cat >"$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$FAN_HELPER_LABEL</string>
  <key>BundleProgram</key>
  <string>Contents/Resources/$FAN_HELPER_NAME</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
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
copy_resource_file "$ROOT_DIR/Resources/LandingArtwork-SafeCleanup-v1-Day.png" "$APP_RESOURCES/LandingArtwork-SafeCleanup-v1-Day.png"
copy_resource_file "$ROOT_DIR/Resources/LandingArtwork-BrowserPrivacy-v1.png" "$APP_RESOURCES/LandingArtwork-BrowserPrivacy-v1.png"
for artwork in "$ROOT_DIR"/Resources/GoldenArtwork-*.png; do
  [ -f "$artwork" ] || continue
  copy_resource_file "$artwork" "$APP_RESOURCES/$(basename "$artwork")"
done
# D58 module/state HEIC art and approved B2 benchmark option PNGs.
# Masters stay outside the repository.
mkdir -p "$APP_RESOURCES/Art"
for artwork in "$ROOT_DIR"/Resources/Art/*.heic "$ROOT_DIR"/Resources/Art/opt-benchmark-*.png "$ROOT_DIR"/Resources/Art/scope-cleanup-*.png; do
  [ -f "$artwork" ] || continue
  copy_resource_file "$artwork" "$APP_RESOURCES/Art/$(basename "$artwork")"
done
# D70 option thumbnails: approved RGBA PNG fallback, 28 pt at 2x / 3x.
# The option inventory JSON is source/test only; the app never reads it.
for artwork in "$ROOT_DIR"/Resources/Art/opt-*.png; do
  [ -f "$artwork" ] || continue
  copy_resource_file "$artwork" "$APP_RESOURCES/Art/$(basename "$artwork")"
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
    if [[ "$localized_info" == */zh-Hans.lproj/* ]]; then
      plutil -insert NSPhotoLibraryUsageDescription -string '仅读取照片元数据和本地小缩略图以查找重复或相似照片。读写权限仅用于创建待删除相册和加入您选中的照片；不删除、不上传、不下载云端原图。' "$localized_info"
      plutil -insert NSAppBundlesUsageDescription -string '仅在您确认卸载时，请求管理所选应用的安装包，以安全移入废纸篓。' "$localized_info"
    else
      plutil -insert NSPhotoLibraryUsageDescription -string 'Read photo metadata and small local thumbnails to find duplicate or similar photos. Read/write access creates a review album and adds selected photos; no deletion, uploads, or cloud original downloads.' "$localized_info"
      plutil -insert NSAppBundlesUsageDescription -string 'Manage only the app you choose to uninstall so it can be moved safely to Trash.' "$localized_info"
    fi
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
  <key>NSAppBundlesUsageDescription</key>
  <string>Manage only the app you choose to uninstall so it can be moved safely to Trash.</string>
PLIST

if [ "$BETA_MODE" -eq 1 ]; then
  cat >>"$INFO_PLIST" <<PLIST
  <key>StorageCleanerBetaBuild</key>
  <true/>
  <key>SUFeedURL</key>
  <string>$UPDATE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <false/>
  <key>SUScheduledCheckInterval</key>
  <integer>21600</integer>
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

# The plist is assembled in pieces above; edit it only once it is complete.
if [ "$BETA_MODE" -eq 1 ]; then
  plutil -insert NSPhotoLibraryUsageDescription -string 'Read photo metadata and small local thumbnails to find duplicate or similar photos. Read/write access creates a review album and adds selected photos; no deletion, uploads, or cloud original downloads.' "$INFO_PLIST"
fi

# D88: the sandboxed Finder extension hands .app bundles over as documents;
# Launch Services refuses that (kLSAppDoesNotClaimTypeErr) unless the host
# claims the type. Alternate rank: listed under Open With, never the default.
if [ "$EMBED_FINDER_EXTENSION" -eq 1 ]; then
  plutil -insert CFBundleDocumentTypes -json '[{"CFBundleTypeName":"Application","CFBundleTypeRole":"Viewer","LSHandlerRank":"Alternate","LSItemContentTypes":["com.apple.application-bundle"]}]' "$INFO_PLIST"
fi

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
codesign "${sign_args[@]}" -i "$FILE_HELPER_LABEL" --sign "$SIGN_IDENTITY" "$APP_RESOURCES/$FILE_HELPER_NAME" >/dev/null
codesign --verify --strict "$APP_RESOURCES/$FILE_HELPER_NAME"
codesign "${sign_args[@]}" -i "$BUNDLE_ID.update-askpass" --sign "$SIGN_IDENTITY" "$APP_RESOURCES/StorageCleanerUpdateAskpass" >/dev/null
codesign --verify --strict "$APP_RESOURCES/StorageCleanerUpdateAskpass"
# Nested code is signed before the outer bundle; the extension is sandboxed.
if [ "$EMBED_FINDER_EXTENSION" -eq 1 ]; then
  codesign "${sign_args[@]}" -i "$FINDER_EXTENSION_ID" --entitlements "$FINDER_EXTENSION_ENTITLEMENTS" \
    --sign "$SIGN_IDENTITY" "$FINDER_EXTENSION_BUNDLE" >/dev/null
  codesign --verify --strict "$FINDER_EXTENSION_BUNDLE"
fi
# Photo library entitlement only for the beta (D89): run/bundle-only builds use the
# release bundle ID and must not gain the photo source or a TCC record.
main_entitlement_args=()
if [ "$BETA_MODE" -eq 1 ]; then
  main_entitlement_args=(--entitlements "$ROOT_DIR/Resources/Signing/StorageCleanerMac.entitlements")
fi
codesign "${sign_args[@]}" ${main_entitlement_args[@]+"${main_entitlement_args[@]}"} --sign "$SIGN_IDENTITY" "$APP_BUNDLE" >/dev/null

verify_photo_library_entitlement() {
  # plistlib.load() seeks and fails on a pipe; read the bytes first.
  codesign -d --entitlements - --xml "$1" 2>/dev/null \
    | python3 -c 'import plistlib, sys; sys.exit(0 if plistlib.loads(sys.stdin.buffer.read()).get("com.apple.security.personal-information.photos-library") is True else 1)'
}
if [ "$BETA_MODE" -eq 1 ]; then
  verify_photo_library_entitlement "$APP_BUNDLE"
fi

verify_sparkle_bundle() {
  local framework="$APP_FRAMEWORKS/Sparkle.framework"

  [ -d "$framework" ]
  [ -f "$APP_RESOURCES/Sparkle-LICENSE.txt" ]
  [ -f "$APP_RESOURCES/THIRD_PARTY_NOTICES.md" ]
  cmp -s "$ROOT_DIR/Resources/InternetAccessPolicy.plist" "$APP_RESOURCES/InternetAccessPolicy.plist"
  cmp -s "$ROOT_DIR/Resources/en.lproj/InternetAccessPolicy.strings" "$APP_RESOURCES/en.lproj/InternetAccessPolicy.strings"
  cmp -s "$ROOT_DIR/Resources/zh-Hans.lproj/InternetAccessPolicy.strings" "$APP_RESOURCES/zh-Hans.lproj/InternetAccessPolicy.strings"
  [ -x "$APP_FAN_HELPER" ]
  [ -f "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST" ]
  [ ! -e "$APP_RESOURCES/$FAN_HELPER_LABEL.legacy.plist" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "$FAN_HELPER_LABEL" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "Contents/Resources/$FAN_HELPER_NAME" ]
  [ "$(/usr/libexec/PlistBuddy -c "Print :MachServices:$FAN_HELPER_LABEL" "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "true" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :RunAtLoad' "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "true" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :KeepAlive:SuccessfulExit' "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST")" = "false" ]
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
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO_PLIST")" = "$UPDATE_FEED_URL" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO_PLIST")" = "$SPARKLE_PUBLIC_KEY" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :SUEnableAutomaticChecks' "$INFO_PLIST")" = "true" ]
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
  # D88: no public URL scheme in any build.
  if /usr/libexec/PlistBuddy -c 'Print :CFBundleURLTypes' "$INFO_PLIST" >/dev/null 2>&1; then
    echo "unexpected CFBundleURLTypes in $INFO_PLIST" >&2
    return 1
  fi
  if [ "$EMBED_FINDER_EXTENSION" -eq 1 ]; then
    [ -x "$FINDER_EXTENSION_BINARY" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$FINDER_EXTENSION_BUNDLE/Contents/Info.plist")" = "$FINDER_EXTENSION_ID" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$FINDER_EXTENSION_BUNDLE/Contents/Info.plist")" = "com.apple.FinderSync" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPrincipalClass' "$FINDER_EXTENSION_BUNDLE/Contents/Info.plist")" = "$FINDER_EXTENSION_PRINCIPAL_CLASS" ]
    codesign -d --entitlements - "$FINDER_EXTENSION_BUNDLE" 2>/dev/null | grep -F 'com.apple.security.app-sandbox' >/dev/null
    codesign --verify --strict --verbose=4 "$FINDER_EXTENSION_BUNDLE"
    verify_executable_compatibility "$FINDER_EXTENSION_BINARY"
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSItemContentTypes:0' "$INFO_PLIST")" = "com.apple.application-bundle" ]
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes:0:LSHandlerRank' "$INFO_PLIST")" = "Alternate" ]
  elif /usr/libexec/PlistBuddy -c 'Print :CFBundleDocumentTypes' "$INFO_PLIST" >/dev/null 2>&1; then
    echo "unexpected CFBundleDocumentTypes in a bundle without the Finder extension: $INFO_PLIST" >&2
    return 1
  elif [ -e "$APP_PLUGINS" ]; then
    echo "unexpected PlugIns in a bundle that is not the installed Beta: $APP_PLUGINS" >&2
    return 1
  fi
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
    echo "verified: signed Beta bundle, isolated identity, dedicated signed update feed and BuildInfo"
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
  verify_benchmark_resources "$contents/Resources"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")" = "$BUNDLE_ID" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$plist")" = "$APP_DISPLAY_NAME" ]
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$APP_BUILD" ]
  [ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSAppBundlesUsageDescription' "$plist")" ]
  [ -n "$(/usr/libexec/PlistBuddy -c 'Print :NSPhotoLibraryUsageDescription' "$plist")" ]
  verify_photo_library_entitlement "$bundle"
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

# Outside a UTF-8 locale ps escapes non-ASCII bytes, so "测试版.app" comes
# back as "M-fM-5M^K….app" and never matches the installed path. A shell
# without LANG (an agent or CI shell) then failed the check below and rolled
# back a Beta that had installed and launched correctly. Pin the locale here.
process_command() {
  LC_ALL=en_US.UTF-8 ps -p "$1" -o command=
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
    command="$(process_command "$pid")"
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
  local helper_before
  local helper_after
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

  # Snapshot only this daemon before replacing its executable. No sudo,
  # kickstart, bootout, signals or launch of the helper itself is performed.
  helper_before="$(python3 "$ROOT_DIR/script/helper_upgrade_status.py" capture "$FAN_HELPER_LABEL" "$target/Contents/Resources/$FAN_HELPER_NAME")"
  quit_existing_beta_safely "$target"
  # The old helper exits by itself 15 s after its last client leaves. Wait for
  # that (read-only, at most 30 s) so the new Beta's first connection starts the
  # replaced executable instead of reattaching to the old process (D97).
  python3 "$ROOT_DIR/script/helper_upgrade_status.py" wait-exit "$FAN_HELPER_LABEL" 30 || true
  # D195: the file-operation helper follows the same idle-exit lifecycle.
  python3 "$ROOT_DIR/script/helper_upgrade_status.py" wait-exit "$FILE_HELPER_LABEL" 30 || true
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
    [ -f "$target/Contents/Info.plist" ] \
      && [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist")" = "$BUNDLE_ID" ] || {
      echo "refusing to replace a non-Beta app at $target" >&2
      return 1
    }
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
  if [ "$had_backup" -eq 1 ]; then
    rm -rf -- "$backup"
  fi
  helper_after="$(python3 "$ROOT_DIR/script/helper_upgrade_status.py" capture "$FAN_HELPER_LABEL" "$target/Contents/Resources/$FAN_HELPER_NAME")"
  python3 "$ROOT_DIR/script/helper_upgrade_status.py" compare "$helper_before" "$helper_after"
  echo "installed: $target"
}

# D106: what still runs from the installed Beta and blocks the exchange. The
# app and the update askpass run with absolute paths inside the bundle;
# launchd starts the two helpers through SMAppService with the relative path
# Contents/Resources/<name>, so their command lines never name the bundle and
# launchd is asked for their jobs instead. A job that cannot be read counts
# as running. The Finder extension is listed by beta_extension_activity
# instead: Finder keeps it while it is enabled, it holds no helper connection
# and writes nothing, and the exchange leaves its files intact under the
# backup name (install_beta likewise waits only for the app).
beta_bundle_activity() {
  local bundle="$1"
  local label
  local job
  local status
  # A UTF-8 locale keeps "测试版" intact in the matched command lines.
  { LC_ALL=en_US.UTF-8 pgrep -lf "$bundle/Contents/" 2>/dev/null || true; } \
    | { grep -vF "$bundle/Contents/PlugIns/" || true; }
  for label in "$FAN_HELPER_LABEL" "$FILE_HELPER_LABEL"; do
    status=0
    job="$(/bin/launchctl print "system/$label" 2>&1)" || status=$?
    if [ "$status" -eq 0 ]; then
      if grep -Eq '^[[:space:]]*pid = [1-9][0-9]*[[:space:]]*$' <<<"$job"; then
        echo "launchd job system/$label is running ($(grep -Em1 '^[[:space:]]*pid = ' <<<"$job" | tr -d '[:space:]'))"
      fi
    elif ! grep -q 'Could not find service' <<<"$job"; then
      echo "launchd job system/$label could not be read (launchctl status $status)"
    fi
  done
  if [ -e "/var/run/$FAN_HELPER_LABEL.active" ]; then
    echo "a fan-control recovery is pending (/var/run/$FAN_HELPER_LABEL.active)"
  fi
}

beta_extension_activity() {
  { LC_ALL=en_US.UTF-8 pgrep -lf "$1/Contents/PlugIns/" 2>/dev/null || true; }
}

note_beta_extension() {
  local extension
  extension="$(beta_extension_activity "$1")"
  [ -n "$extension" ] || return 0
  echo "note: $2 (not quit; Finder keeps it while it is enabled):"
  sed 's/^/  /' <<<"$extension"
}

refuse_beta_activity() {
  echo "refusing to install: something still runs from the installed Beta, and --no-launch never quits it:" >&2
  sed 's/^/  /' <<<"$1" >&2
  echo "$2 was not changed. The Beta's normal quit may return the fans to automatic control and" >&2
  echo "hand back its Mac mini sleep policy (hardware writes): quit it only when that is approved. A helper" >&2
  echo "exits by itself about 15 s after its last client, unless Mac mini mode or fan control keeps it." >&2
  exit 75
}

# D106: installs the Beta for acceptance without quitting, opening or
# relaunching anything and without writing preferences. It refuses while
# anything runs from the installed Beta, and exchanges the bundles in one
# atomic rename (script/beta_install_swap.py), so the path never stops naming a
# complete Beta signed by the same team: the helper's watch on it sees no
# removal. The previous bundle is kept outside /Applications on the same
# volume, renamed to *.app.previous so LaunchServices and PlugInKit do not
# take it for a second Beta and Finder extension; backups are never deleted.
# The backup folder is checked after resolving `..` and symbolic links, before
# anything is copied or moved, and only the checked path is used (D106-R5).
BETA_BACKUP_ROOT="${STORAGE_CLEANER_BETA_BACKUP_DIR:-$HOME/Developer/StorageCleanerMac-beta-backups.noindex}"

install_beta_without_launch() {
  local target
  local parent
  local staging
  local backup_root
  local backup_dir
  local stale
  local activity
  local had_previous=0
  local status
  local helper_before
  local helper_after
  target="$(resolve_beta_install_path)"
  parent="$(dirname "$target")"
  staging="$parent/.测试版.staging.$$.app"

  case "$target" in
    "/Applications/测试版.app"|"$HOME/Applications/测试版.app") ;;
    *)
      echo "refusing unsafe Beta install target: $target" >&2
      return 1
      ;;
  esac
  case "$BETA_BACKUP_ROOT/" in
    /*) ;;
    *)
      echo "STORAGE_CLEANER_BETA_BACKUP_DIR must be an absolute path: $BETA_BACKUP_ROOT" >&2
      return 1
      ;;
  esac
  if ! backup_root="$(python3 "$ROOT_DIR/script/beta_install_swap.py" backup-folder "$BETA_BACKUP_ROOT")"; then
    echo "refusing Beta backup folder in Applications, a synced folder or /tmp: $BETA_BACKUP_ROOT" >&2
    return 1
  fi

  activity="$(beta_bundle_activity "$target")"
  [ -z "$activity" ] || refuse_beta_activity "$activity" "$target"
  note_beta_extension "$target" "the Beta's Finder extension runs and keeps the previous build's files until Finder restarts it"
  helper_before="$(python3 "$ROOT_DIR/script/helper_upgrade_status.py" capture "$FAN_HELPER_LABEL" "$target/Contents/Resources/$FAN_HELPER_NAME")"
  backup_dir="$backup_root/$(date -u '+%Y%m%dT%H%M%SZ')-$$"

  # An interrupted earlier install may have left a staging bundle, possibly
  # holding a previous Beta: keep it with the backups, never delete it.
  for stale in "$parent"/.测试版.staging.*.app; do
    [ -e "$stale" ] || continue
    mkdir -p "$backup_dir"
    python3 "$ROOT_DIR/script/beta_install_swap.py" backup-place "$stale" "$backup_dir/stale-staging-${stale##*.staging.}.previous"
  done
  if [ -e "$staging" ] || [ -L "$staging" ]; then
    echo "refusing: staging path already exists: $staging" >&2
    return 1
  fi
  /usr/bin/ditto --norsrc "$APP_BUNDLE" "$staging"
  set +e
  ( set -e; verify_beta_bundle_at "$staging" )
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    rm -rf -- "$staging"
    echo "the new Beta failed verification; $target was not changed" >&2
    return 1
  fi

  if [ -e "$target" ] || [ -L "$target" ]; then
    if [ -L "$target" ] || [ ! -f "$target/Contents/Info.plist" ] ||
       [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$target/Contents/Info.plist" 2>/dev/null)" != "$BUNDLE_ID" ]; then
      rm -rf -- "$staging"
      echo "refusing to replace a non-Beta app at $target; nothing was changed" >&2
      return 1
    fi
    # The helper accepts the app by its signing team and identifier.
    if ! python3 "$ROOT_DIR/script/beta_install_swap.py" same-signer "$target" "$staging"; then
      rm -rf -- "$staging"
      echo "refusing: the new Beta is not signed by the installed Beta's team with the same identifier; nothing was changed" >&2
      return 1
    fi
    had_previous=1
  elif ! python3 "$ROOT_DIR/script/beta_install_swap.py" signer "$staging"; then
    rm -rf -- "$staging"
    echo "refusing: the new Beta has no team signature; nothing was changed" >&2
    return 1
  fi

  # Checked again right before the exchange.
  activity="$(beta_bundle_activity "$target")"
  if [ -n "$activity" ]; then
    rm -rf -- "$staging"
    refuse_beta_activity "$activity" "$target"
  fi
  if [ "$had_previous" -eq 1 ]; then
    if ! python3 "$ROOT_DIR/script/beta_install_swap.py" swap "$staging" "$target"; then
      echo "the exchange was not confirmed; nothing was deleted or opened. Inspect $target and $staging." >&2
      return 1
    fi
  elif ! python3 "$ROOT_DIR/script/beta_install_swap.py" place "$staging" "$target"; then
    echo "the move was not confirmed; nothing was deleted or opened. Inspect $target and $staging." >&2
    return 1
  fi

  set +e
  ( set -e; verify_beta_bundle_at "$target" )
  status=$?
  set -e
  if [ "$status" -ne 0 ]; then
    if [ "$had_previous" -eq 1 ] && python3 "$ROOT_DIR/script/beta_install_swap.py" swap "$staging" "$target"; then
      rm -rf -- "$staging"
      echo "the installed Beta failed verification; the previous Beta was swapped back atomically and nothing was opened" >&2
    elif [ "$had_previous" -eq 0 ] && python3 "$ROOT_DIR/script/beta_install_swap.py" place "$target" "$staging"; then
      rm -rf -- "$staging"
      echo "the installed Beta failed verification and was removed again; nothing was opened" >&2
    else
      echo "the installed Beta failed verification and could not be moved back; nothing was opened or deleted." >&2
      echo "Inspect $target and $staging." >&2
    fi
    return 1
  fi

  RUNTIME_APP_BUNDLE="$target"
  BETA_INSTALL_PATH="$target"
  activity="$(beta_bundle_activity "$target")"
  if [ -n "$activity" ]; then
    echo "note: started from the Beta during the installation (nothing was quit):"
    sed 's/^/  /' <<<"$activity"
  fi
  note_beta_extension "$target" "Finder extension processes after the exchange"
  helper_after="$(python3 "$ROOT_DIR/script/helper_upgrade_status.py" capture "$FAN_HELPER_LABEL" "$target/Contents/Resources/$FAN_HELPER_NAME")"
  python3 "$ROOT_DIR/script/helper_upgrade_status.py" compare "$helper_before" "$helper_after"
  echo "installed without opening: $target (build $APP_BUILD)"
  if [ "$had_previous" -eq 1 ]; then
    mkdir -p "$backup_dir"
    if ! python3 "$ROOT_DIR/script/beta_install_swap.py" backup-place "$staging" "$backup_dir/测试版.app.previous"; then
      echo "the previous Beta could not be moved to $backup_dir and is still at $staging" >&2
      return 1
    fi
    echo "previous Beta kept at: $backup_dir/测试版.app.previous"
    echo "  to go back (with nothing running from the Beta):"
    echo "  python3 script/beta_install_swap.py swap \"$backup_dir/测试版.app.previous\" \"$target\""
  fi
  echo "next (approved acceptance only): script/launch_beta_acceptance.sh --log <new absolute file> [--display NAME] [--panel]"
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
          or windowName is "小窗" or windowName is "Mini Window" ¬
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
    if [ "$BETA_INSTALL" -eq 1 ] && [ "$BETA_NO_LAUNCH" -eq 1 ]; then
      install_beta_without_launch
    elif [ "$BETA_INSTALL" -eq 1 ]; then
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
