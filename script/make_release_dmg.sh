#!/usr/bin/env bash
set -euo pipefail

export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release_version.env
source "$ROOT_DIR/script/release_version.env"
APP_NAME="StorageCleanerMac"
DISPLAY_NAME="存储清理助手"
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

BUILD_ROOT="${BUILD_ROOT:-/tmp/storage-cleaner-release-build}"
SWIFT_BUILD_DIR="${SWIFT_BUILD_DIR:-/tmp/storage-cleaner-swiftpm-build-release}"
BENCHMARK_VALIDATION_BUILD_DIR="${BENCHMARK_VALIDATION_BUILD_DIR:-/tmp/storage-cleaner-benchmark-release-validation}"
SWIFT_BUILD_JOBS="${SWIFT_BUILD_JOBS:-2}"
BUILD_CONFIGURATION="${BUILD_CONFIGURATION:-release}"
APP_BUNDLE="$BUILD_ROOT/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_LAUNCH_DAEMONS="$APP_CONTENTS/Library/LaunchDaemons"
APP_FAN_HELPER="$APP_RESOURCES/$FAN_HELPER_NAME"
DMG_STAGING="$BUILD_ROOT/dmg-staging"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/release}"
# Keep the canonical verification copy outside Documents/File Provider roots.
# Those roots can immediately reattach FinderInfo to nested Sparkle bundles and
# invalidate an otherwise correct strict code signature after copying.
DIST_DIR="${DIST_DIR:-/tmp/storage-cleaner-release-dist}"
DIST_APP="$DIST_DIR/StorageCleanerMac.app"
ASCII_DMG_ASSET_NAME="StorageCleanerMac-$APP_VERSION.dmg"
ASCII_ZIP_ASSET_NAME="StorageCleanerMac-$APP_VERSION.zip"
ZH_DMG_ASSET_NAME="StorageCleanerMac-zhHans-$APP_VERSION.dmg"
ZH_ZIP_ASSET_NAME="StorageCleanerMac-zhHans-$APP_VERSION.zip"
DMG_PATH="$RELEASE_DIR/$DISPLAY_NAME-$APP_VERSION.dmg"
ZIP_PATH="$RELEASE_DIR/$DISPLAY_NAME-$APP_VERSION.zip"
ASCII_DMG_PATH="$RELEASE_DIR/$ASCII_DMG_ASSET_NAME"
ASCII_ZIP_PATH="$RELEASE_DIR/$ASCII_ZIP_ASSET_NAME"
REPORT_PATH="${REPORT_PATH:-$RELEASE_DIR/发布验证报告-$APP_VERSION.txt}"
CHECKSUM_PATH="$RELEASE_DIR/CHECKSUMS-SHA256-$APP_VERSION.txt"
CHECKSUM_STAGING="$BUILD_ROOT/checksum-staging"
ZH_DMG_ASSET_PATH="$RELEASE_DIR/$ZH_DMG_ASSET_NAME"
ZH_ZIP_ASSET_PATH="$RELEASE_DIR/$ZH_ZIP_ASSET_NAME"
NOTICE_NAME="THIRD_PARTY_NOTICES.md"
NOTICE_PATH="$ROOT_DIR/$NOTICE_NAME"
TEMP_DMG="$BUILD_ROOT/$DISPLAY_NAME-temp.dmg"
ASCII_TEMP_DMG="$BUILD_ROOT/StorageCleanerMac-temp.dmg"
ASCII_STAGING="$BUILD_ROOT/ascii-staging"
ZIP_STAGING="$BUILD_ROOT/zip-staging"
ASCII_ZIP_STAGING="$BUILD_ROOT/ascii-zip-staging"
VERIFY_ROOT="$BUILD_ROOT/archive-verify"

SIGN_IDENTITY="${SIGN_IDENTITY:-}"
REQUIRE_DEVELOPER_ID="${REQUIRE_DEVELOPER_ID:-0}"

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

if ! [[ "$SWIFT_BUILD_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "SWIFT_BUILD_JOBS must be a positive integer; found '$SWIFT_BUILD_JOBS'." >&2
  exit 5
fi

safe_remove_generated_build_path() {
  local target="$1"
  local parent="${target%/*}"
  local name="${target##*/}"

  case "$target" in
    ""|/|/tmp|/private/tmp|*"/../"*|*/..)
      echo "refusing to remove unsafe generated build path: '$target'" >&2
      exit 6
      ;;
  esac

  if [[ "$parent" != "/tmp" && "$parent" != "/private/tmp" ]] ||
     [[ "$name" != storage-cleaner-* || "$name" == *"/"* ]]; then
    echo "generated build path must be a direct storage-cleaner-* child of /tmp: '$target'" >&2
    exit 6
  fi

  rm -rf -- "$target"
}

validate_production_benchmark_contracts() {
  local status=0
  safe_remove_generated_build_path "$BENCHMARK_VALIDATION_BUILD_DIR"
  MAC_BENCHMARK_CALIBRATION_ACTION=validate-production \
    "$SWIFT_TOOL" test -c release \
      --scratch-path "$BENCHMARK_VALIDATION_BUILD_DIR" \
      --jobs "$SWIFT_BUILD_JOBS" \
      -Xswiftc -disable-batch-mode \
      --filter 'MacBenchmarkCalibrationWorkflowTests/testExplicitCalibrationWorkflow|BenchmarkV7ReferenceCatalogTests|BenchmarkV7ScoringFoundationTests|OfficialBenchmarkPlanTests|BenchmarkV7LeaderboardTests' \
    || status=$?
  safe_remove_generated_build_path "$BENCHMARK_VALIDATION_BUILD_DIR"
  if [ "$status" -ne 0 ]; then
    echo "release blocked: production benchmark calibration or V7 contract is invalid" >&2
    return "$status"
  fi
}

validate_production_benchmark_contracts

if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')"
fi
if [ -z "$SIGN_IDENTITY" ]; then
  SIGN_IDENTITY="-"
fi
if [ "$REQUIRE_DEVELOPER_ID" = "1" ] && [[ "$SIGN_IDENTITY" != Developer\ ID\ Application* ]]; then
  echo "Developer ID Application certificate is required for public distribution." >&2
  echo "Install a Developer ID Application certificate, or run without REQUIRE_DEVELOPER_ID=1 for local testing only." >&2
  exit 4
fi

safe_remove_generated_build_path "$SWIFT_BUILD_DIR"
"$SWIFT_TOOL" build -c "$BUILD_CONFIGURATION" --scratch-path "$SWIFT_BUILD_DIR" --jobs "$SWIFT_BUILD_JOBS" -Xswiftc -disable-batch-mode
BUILD_BIN_DIR="$("$SWIFT_TOOL" build -c "$BUILD_CONFIGURATION" --scratch-path "$SWIFT_BUILD_DIR" --jobs "$SWIFT_BUILD_JOBS" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_DIR/$APP_NAME"
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

safe_remove_generated_build_path "$BUILD_ROOT"
mkdir -p \
  "$APP_MACOS" \
  "$APP_RESOURCES" \
  "$APP_FRAMEWORKS" \
  "$APP_LAUNCH_DAEMONS" \
  "$RELEASE_DIR"

clean_attrs() {
  local path="$1"
  local attrs=(
    com.apple.FinderInfo
    com.apple.ResourceFork
    com.apple.fileprovider.fpfs#P
    com.apple.macl
    com.apple.quarantine
    com.apple.provenance
  )

  xattr -cr "$path" >/dev/null 2>&1 || true
  for attr in "${attrs[@]}"; do
    xattr -d "$attr" "$path" >/dev/null 2>&1 || true
    xattr -dr "$attr" "$path" >/dev/null 2>&1 || true
  done
  xattr -d com.apple.diskimages.recentcksum "$path" >/dev/null 2>&1 || true
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

sign_app_bundle() {
  local app_path="$1"
  local sign_args=(--force)

  if [ "$SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--options runtime)
  fi

  if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]]; then
    sign_args+=(--timestamp)
  fi

  clean_attrs "$app_path"
  sign_sparkle_framework "$app_path/Contents/Frameworks/Sparkle.framework"
  sign_fan_helper "$app_path/Contents/Resources/$FAN_HELPER_NAME"
  codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" "$app_path" >/dev/null
  codesign --verify --deep --strict --verbose=4 "$app_path"
}

sign_fan_helper() {
  local helper_path="$1"
  local sign_args=(--force -i "$FAN_HELPER_LABEL")

  if [ "$SIGN_IDENTITY" != "-" ]; then
    sign_args+=(--options runtime)
  fi
  if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]]; then
    sign_args+=(--timestamp)
  fi

  clean_attrs "$helper_path"
  codesign "${sign_args[@]}" --sign "$SIGN_IDENTITY" "$helper_path" >/dev/null
  codesign --verify --strict --verbose=4 "$helper_path"
}

verify_fan_helper_signing_contract() {
  local app_path="$1"
  local helper_path="$app_path/Contents/Resources/$FAN_HELPER_NAME"
  local app_details helper_details app_team helper_team app_chain helper_chain

  codesign --verify --deep --strict --verbose=4 "$app_path"
  codesign --verify --strict --verbose=4 "$helper_path"
  app_details="$(codesign -dvvv "$app_path" 2>&1)"
  helper_details="$(codesign -dvvv "$helper_path" 2>&1)"
  grep -Fxq "Identifier=$BUNDLE_ID" <<<"$app_details" \
    || { echo "$app_path: wrong code-signing identifier" >&2; return 1; }
  grep -Fxq "Identifier=$FAN_HELPER_LABEL" <<<"$helper_details" \
    || { echo "$helper_path: wrong code-signing identifier" >&2; return 1; }

  app_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$app_details" | head -1)"
  helper_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_details" | head -1)"
  app_chain="$(grep '^Authority=' <<<"$app_details" || true)"
  helper_chain="$(grep '^Authority=' <<<"$helper_details" || true)"
  if [ "$app_team" != "$helper_team" ] || [ "$app_chain" != "$helper_chain" ]; then
    echo "$app_path: app/helper signing team or certificate chain differs" >&2
    return 1
  fi
  if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
    [ -n "$app_team" ] \
      && grep -Fq "Authority=Developer ID Application:" <<<"$app_details" \
      && grep -Fq "Authority=Developer ID Application:" <<<"$helper_details" \
      || { echo "$app_path: production helper requires Developer ID Application" >&2; return 1; }
  fi
}

copy_resource_file() {
  local source="$1"
  local destination="$2"
  /bin/cp -f "$source" "$destination"
  clean_attrs "$destination"
}

hdiutil_clean() {
  local status=0
  hdiutil "$@" 2> >(grep -v "deprecated" >&2) || status=$?
  return "$status"
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist"
}

assert_plist_value() {
  local plist="$1"
  local key="$2"
  local expected="$3"
  local actual
  actual="$(plist_value "$plist" "$key")"
  if [ "$actual" != "$expected" ]; then
    echo "$plist: $key expected '$expected' but found '$actual'" >&2
    return 1
  fi
}

assert_plist_array_contains() {
  local plist="$1"
  local key="$2"
  local expected="$3"

  if ! /usr/libexec/PlistBuddy -c "Print :$key" "$plist" | grep -Fxq "    $expected"; then
    echo "$plist: $key does not include '$expected'" >&2
    return 1
  fi
}

verify_app_metadata() {
  local app_path="$1"
  local expected_display_name="$2"
  local plist="$app_path/Contents/Info.plist"

  if [ ! -f "$plist" ]; then
    echo "$app_path: missing Contents/Info.plist" >&2
    return 1
  fi

  assert_plist_value "$plist" CFBundleIdentifier "$BUNDLE_ID"
  assert_plist_value "$plist" CFBundleDisplayName "$expected_display_name"
  assert_plist_value "$plist" CFBundleShortVersionString "$APP_VERSION"
  assert_plist_value "$plist" CFBundleVersion "$APP_BUILD"
  assert_plist_value "$plist" CFBundleDevelopmentRegion "zh-Hans"
  assert_plist_value "$plist" LSMinimumSystemVersion "$MIN_SYSTEM_VERSION"
  assert_plist_value "$plist" SUFeedURL "$UPDATE_FEED_URL"
  assert_plist_value "$plist" SUPublicEDKey "$SPARKLE_PUBLIC_KEY"
  assert_plist_value "$plist" LeaderboardAPIURL "$LEADERBOARD_API_URL"
  assert_plist_value "$plist" SUEnableAutomaticChecks "true"
  assert_plist_value "$plist" SUAutomaticallyUpdate "true"
  assert_plist_value "$plist" SUScheduledCheckInterval "21600"
  assert_plist_value "$plist" SUVerifyUpdateBeforeExtraction "true"
  assert_plist_array_contains "$plist" CFBundleLocalizations "zh-Hans"
  assert_plist_array_contains "$plist" CFBundleLocalizations "en"
  if [ ! -d "$app_path/Contents/Frameworks/Sparkle.framework" ]; then
    echo "$app_path: missing Sparkle.framework" >&2
    return 1
  fi
  if [ ! -f "$app_path/Contents/Resources/Sparkle-LICENSE.txt" ]; then
    echo "$app_path: missing Sparkle license" >&2
    return 1
  fi
  if ! otool -L "$app_path/Contents/MacOS/$APP_NAME" | grep -Fq '@rpath/Sparkle.framework/Versions/B/Sparkle'; then
    echo "$app_path: executable is not linked to embedded Sparkle.framework" >&2
    return 1
  fi
  # Verify every shipped illustration in extracted ZIPs and mounted DMGs too.
  local artwork
  for artwork in "$ROOT_DIR"/Resources/GoldenArtwork-*.png "$ROOT_DIR"/Resources/LandingArtwork-*.png; do
    if [ ! -f "$artwork" ] || ! cmp -s "$artwork" "$app_path/Contents/Resources/$(basename "$artwork")"; then
      echo "$app_path: missing or changed artwork $(basename "$artwork")" >&2
      return 1
    fi
  done
  local helper_path="$app_path/Contents/Resources/$FAN_HELPER_NAME"
  local helper_plist="$app_path/Contents/Library/LaunchDaemons/$FAN_HELPER_PLIST"
  if [ ! -x "$helper_path" ] \
    || [ ! -f "$helper_plist" ]; then
    echo "$app_path: missing system-control helper or launch daemon plist" >&2
    return 1
  fi
  verify_fan_helper_signing_contract "$app_path"
  assert_plist_value "$helper_plist" Label "$FAN_HELPER_LABEL"
  assert_plist_value \
    "$helper_plist" \
    BundleProgram \
    "Contents/Resources/$FAN_HELPER_NAME"
  if [ -e "$app_path/Contents/Resources/$FAN_HELPER_LABEL.legacy.plist" ]; then
    echo "$app_path: legacy launch daemon plist must not be bundled" >&2
    return 1
  fi
  verify_executable_compatibility "$app_path/Contents/MacOS/$APP_NAME"
  echo "$app_path: metadata OK ($BUNDLE_ID, $APP_VERSION, $APP_BUILD)"
}

verify_zip_archive() {
  local zip_path="$1"
  local expected_app_name="$2"
  local label="$3"
  local expected_readme_name="$4"
  local verify_dir="$VERIFY_ROOT/$label"

  rm -rf "$verify_dir"
  mkdir -p "$verify_dir"
  /usr/bin/ditto -x -k "$zip_path" "$verify_dir"

  local app_path="$verify_dir/$expected_app_name.app"
  if [ ! -d "$app_path" ]; then
    echo "$zip_path: archive does not contain $expected_app_name.app" >&2
    return 1
  fi
  if [ ! -f "$verify_dir/$expected_readme_name" ]; then
    echo "$zip_path: archive does not contain $expected_readme_name" >&2
    return 1
  fi
  if [ ! -f "$verify_dir/$NOTICE_NAME" ]; then
    echo "$zip_path: archive does not contain $NOTICE_NAME" >&2
    return 1
  fi
  if ! grep -Fq "Stats SMC helper" "$verify_dir/$NOTICE_NAME"; then
    echo "$zip_path: $NOTICE_NAME does not mention the SMC notice" >&2
    return 1
  fi
  verify_first_open_readme "$verify_dir/$expected_readme_name" "$zip_path" "$expected_readme_name"
  echo "$zip_path: includes $NOTICE_NAME"

  codesign --verify --deep --strict --verbose=4 "$app_path"
  verify_app_metadata "$app_path" "$DISPLAY_NAME"
}

verify_first_open_readme() {
  local readme_path="$1"
  local archive_path="$2"
  local expected_readme_name="$3"

  if [ ! -f "$readme_path" ]; then
    echo "$archive_path: archive does not contain $expected_readme_name" >&2
    return 1
  fi
  if ! grep -Fq "减少重复授权提示" "$readme_path"; then
    echo "$archive_path: $expected_readme_name does not explain repeated access prompts" >&2
    return 1
  fi
  if ! grep -Fq "/Applications/存储清理助手.app" "$readme_path"; then
    echo "$archive_path: $expected_readme_name does not name the stable install path" >&2
    return 1
  fi
  if ! grep -Fq "关闭窗口不会撤销 macOS 文件访问授权" "$readme_path"; then
    echo "$archive_path: $expected_readme_name does not explain that closing windows keeps access grants" >&2
    return 1
  fi

  echo "$archive_path: includes $expected_readme_name"
}

verify_dmg_archive() {
  local dmg_path="$1"
  local expected_app_name="$2"
  local label="$3"
  local expected_readme_name="$4"
  local mount_point="$VERIFY_ROOT/$label-mount"

  rm -rf "$mount_point"
  mkdir -p "$mount_point"

  hdiutil_clean attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_point" >/dev/null

  local app_path="$mount_point/$expected_app_name.app"
  if [ ! -d "$app_path" ]; then
    echo "$dmg_path: mounted image does not contain $expected_app_name.app" >&2
    hdiutil_clean detach "$mount_point" >/dev/null
    return 1
  fi

  local status=0
  codesign --verify --deep --strict --verbose=4 "$app_path" || status=$?
  if [ "$status" -eq 0 ]; then
    verify_app_metadata "$app_path" "$DISPLAY_NAME" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    verify_first_open_readme "$mount_point/$expected_readme_name" "$dmg_path" "$expected_readme_name" || status=$?
  fi
  if [ "$status" -eq 0 ]; then
    if [ ! -f "$mount_point/$NOTICE_NAME" ]; then
      echo "$dmg_path: mounted image does not contain $NOTICE_NAME" >&2
      status=1
    elif ! grep -Fq "Stats SMC helper" "$mount_point/$NOTICE_NAME"; then
      echo "$dmg_path: $NOTICE_NAME does not mention the SMC notice" >&2
      status=1
    else
      echo "$dmg_path: includes $NOTICE_NAME"
    fi
  fi
  hdiutil_clean detach "$mount_point" >/dev/null
  return "$status"
}

write_and_verify_checksums() {
  mkdir -p "$CHECKSUM_STAGING"
  ln -s "$ASCII_DMG_PATH" "$CHECKSUM_STAGING/$ASCII_DMG_ASSET_NAME"
  ln -s "$ASCII_ZIP_PATH" "$CHECKSUM_STAGING/$ASCII_ZIP_ASSET_NAME"
  ln -s "$ZH_DMG_ASSET_PATH" "$CHECKSUM_STAGING/$ZH_DMG_ASSET_NAME"
  ln -s "$ZH_ZIP_ASSET_PATH" "$CHECKSUM_STAGING/$ZH_ZIP_ASSET_NAME"

  (
    cd "$CHECKSUM_STAGING"
    shasum -a 256 \
      "$ASCII_DMG_ASSET_NAME" \
      "$ASCII_ZIP_ASSET_NAME" \
      "$ZH_DMG_ASSET_NAME" \
      "$ZH_ZIP_ASSET_NAME" > "$CHECKSUM_PATH"
    shasum -a 256 -c "$CHECKSUM_PATH"
  )
  clean_attrs "$CHECKSUM_PATH"
}

/usr/bin/ditto --norsrc "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"
/usr/bin/ditto --norsrc "$FAN_HELPER_BINARY" "$APP_FAN_HELPER"
/usr/bin/ditto --norsrc "$SPARKLE_FRAMEWORK" "$APP_FRAMEWORKS/Sparkle.framework"
copy_resource_file "$SPARKLE_LICENSE" "$APP_RESOURCES/Sparkle-LICENSE.txt"
copy_resource_file "$NOTICE_PATH" "$APP_RESOURCES/$NOTICE_NAME"
copy_resource_file "$ROOT_DIR/Resources/CleanupRules.v2.json" "$APP_RESOURCES/CleanupRules.v2.json"
copy_resource_file \
  "$ROOT_DIR/Resources/$FAN_HELPER_PLIST" \
  "$APP_LAUNCH_DAEMONS/$FAN_HELPER_PLIST"
chmod +x "$APP_MACOS/$APP_NAME" "$APP_FAN_HELPER"

if [ -f "$ROOT_DIR/Resources/AppIcon.icns" ]; then
  copy_resource_file "$ROOT_DIR/Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

# Keep production illustrations identical to the tested Beta resources.
for artwork in "$ROOT_DIR"/Resources/GoldenArtwork-*.png "$ROOT_DIR"/Resources/LandingArtwork-*.png; do
  [ -f "$artwork" ] || { echo "missing artwork: $artwork" >&2; exit 1; }
  copy_resource_file "$artwork" "$APP_RESOURCES/$(basename "$artwork")"
done

while IFS= read -r -d '' resource; do
  copy_resource_file "$resource" "$APP_RESOURCES/$(basename "$resource")"
done < <(find "$ROOT_DIR/Resources" -maxdepth 1 -type f -name 'AppIcon*.png' ! -name 'AppIconSource.png' ! -name 'AppIconGenerated*.png' -print0)
find "$ROOT_DIR/Resources" -maxdepth 1 -type d -name '*.lproj' -exec sh -c '/usr/bin/ditto --norsrc "$1" "$2/$(basename "$1")"' sh {} "$APP_RESOURCES" \;

cat >"$APP_CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
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
  <key>SUFeedURL</key>
  <string>$UPDATE_FEED_URL</string>
  <key>SUPublicEDKey</key>
  <string>$SPARKLE_PUBLIC_KEY</string>
  <key>LeaderboardAPIURL</key>
  <string>$LEADERBOARD_API_URL</string>
  <key>SUEnableAutomaticChecks</key>
  <true/>
  <key>SUAutomaticallyUpdate</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>21600</integer>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

sign_fan_helper "$APP_FAN_HELPER"
sign_app_bundle "$APP_BUNDLE"

mkdir -p "$DIST_DIR"
rm -rf "$DIST_APP"
/usr/bin/ditto --norsrc "$APP_BUNDLE" "$DIST_APP"
clean_attrs "$DIST_APP"
if codesign --verify --deep --strict --verbose=4 "$DIST_APP" >/dev/null 2>&1; then
  codesign --verify --deep --strict --verbose=4 "$DIST_APP"
else
  echo "$DIST_APP: copied for local development; strict validation failed after metadata cleanup" >&2
  exit 1
fi
clean_attrs "$DIST_APP"

mkdir -p "$DMG_STAGING"
/usr/bin/ditto --norsrc "$APP_BUNDLE" "$DMG_STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
copy_resource_file "$NOTICE_PATH" "$DMG_STAGING/$NOTICE_NAME"

cat >"$DMG_STAGING/首次打开说明.txt" <<'TXT'
存储清理助手 - 首次打开说明

状态说明：
- 这个包已通过打包脚本的签名结构校验，适合本机或受控测试。
- 当前不是 Apple 公证的公开分发版，也不是 App Store 版本。
- 如果朋友电脑提示“文件已损坏”，通常是 Gatekeeper 拦截未公证 App，不代表 DMG 或 ZIP 真坏。

建议打开方式：
1. 把“存储清理助手.app”拖到 Applications。
2. 在 Applications 里按住 Control 点击“存储清理助手.app”。
3. 选择“打开”，再点“打开”确认。

减少重复授权提示：
- 后续尽量继续从 /Applications/存储清理助手.app 打开，不要反复从 DMG、下载目录或不同副本启动。
- 保持同一个 Bundle ID 和签名身份时，macOS 通常会复用已授予的文件访问权限；更换开发包、路径或签名后，系统可能会再次要求确认。
- 关闭窗口不会撤销 macOS 文件访问授权；重新打开同一个 /Applications 副本时，不需要每次重新授权。

如果 macOS 提示“无法验证开发者”：
请按上面的 Control-点击方式打开。

如果仍提示“文件已损坏”：
可以在终端运行以下命令移除下载隔离标记：

xattr -dr com.apple.quarantine /Applications/存储清理助手.app

然后再打开 App。

公开分发下一步：
要做到所有朋友双击即可打开，需要使用 Apple Developer ID 证书签名，并提交 Apple notarization 公证。
TXT

clean_attrs "$DMG_STAGING"
sign_app_bundle "$DMG_STAGING/$DISPLAY_NAME.app"

rm -f "$DMG_PATH" "$ZIP_PATH" "$ASCII_DMG_PATH" "$ASCII_ZIP_PATH" "$TEMP_DMG" "$ASCII_TEMP_DMG"
hdiutil_clean create -volname "$DISPLAY_NAME" -srcfolder "$DMG_STAGING" -ov -format UDRW "$TEMP_DMG" >/tmp/storage-cleaner-dmg.log
hdiutil_clean convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >>/tmp/storage-cleaner-dmg.log
hdiutil_clean verify "$DMG_PATH" >>/tmp/storage-cleaner-dmg.log
clean_attrs "$DMG_PATH"

mkdir -p "$ZIP_STAGING"
/usr/bin/ditto --norsrc "$DMG_STAGING/$DISPLAY_NAME.app" "$ZIP_STAGING/$DISPLAY_NAME.app"
/usr/bin/ditto --norsrc "$DMG_STAGING/首次打开说明.txt" "$ZIP_STAGING/首次打开说明.txt"
/usr/bin/ditto --norsrc "$DMG_STAGING/$NOTICE_NAME" "$ZIP_STAGING/$NOTICE_NAME"
clean_attrs "$ZIP_STAGING"
(
  cd "$ZIP_STAGING"
  /usr/bin/ditto -c -k --norsrc . "$ZIP_PATH"
)
clean_attrs "$ZIP_PATH"

mkdir -p "$ASCII_STAGING"
/usr/bin/ditto --norsrc "$DMG_STAGING/$DISPLAY_NAME.app" "$ASCII_STAGING/$DISPLAY_NAME.app"
ln -s /Applications "$ASCII_STAGING/Applications"
/usr/bin/ditto --norsrc "$DMG_STAGING/首次打开说明.txt" "$ASCII_STAGING/README-FIRST.txt"
/usr/bin/ditto --norsrc "$DMG_STAGING/$NOTICE_NAME" "$ASCII_STAGING/$NOTICE_NAME"
clean_attrs "$ASCII_STAGING"
sign_app_bundle "$ASCII_STAGING/$DISPLAY_NAME.app"

mkdir -p "$ASCII_ZIP_STAGING"
/usr/bin/ditto --norsrc "$ASCII_STAGING/$DISPLAY_NAME.app" "$ASCII_ZIP_STAGING/$DISPLAY_NAME.app"
/usr/bin/ditto --norsrc "$ASCII_STAGING/README-FIRST.txt" "$ASCII_ZIP_STAGING/README-FIRST.txt"
/usr/bin/ditto --norsrc "$ASCII_STAGING/$NOTICE_NAME" "$ASCII_ZIP_STAGING/$NOTICE_NAME"
clean_attrs "$ASCII_ZIP_STAGING"
(
  cd "$ASCII_ZIP_STAGING"
  /usr/bin/ditto -c -k --norsrc . "$ASCII_ZIP_PATH"
)
clean_attrs "$ASCII_ZIP_PATH"

hdiutil_clean create -volname "StorageCleanerMac" -srcfolder "$ASCII_STAGING" -ov -format UDRW "$ASCII_TEMP_DMG" >>/tmp/storage-cleaner-dmg.log
hdiutil_clean convert "$ASCII_TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$ASCII_DMG_PATH" >>/tmp/storage-cleaner-dmg.log
hdiutil_clean verify "$ASCII_DMG_PATH" >>/tmp/storage-cleaner-dmg.log
clean_attrs "$ASCII_DMG_PATH"

rm -f "$ZH_DMG_ASSET_PATH" "$ZH_ZIP_ASSET_PATH"
/usr/bin/ditto --norsrc "$DMG_PATH" "$ZH_DMG_ASSET_PATH"
/usr/bin/ditto --norsrc "$ZIP_PATH" "$ZH_ZIP_ASSET_PATH"
clean_attrs "$ZH_DMG_ASSET_PATH"
clean_attrs "$ZH_ZIP_ASSET_PATH"

write_and_verify_checksums

rm -rf "$VERIFY_ROOT"
mkdir -p "$VERIFY_ROOT"

{
  echo "存储清理助手 发布验证报告"
  echo
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "签名身份: $SIGN_IDENTITY"
  if [ "$REQUIRE_DEVELOPER_ID" = "1" ]; then
    echo "发布要求: 已要求 Developer ID 签名"
  else
    echo "发布要求: 未强制 Developer ID；非 Developer ID 产物仅适合本机或受控测试"
  fi
  echo "版本: $APP_VERSION ($APP_BUILD)"
  echo "构建工具链: $(xcodebuild -version | tr '\n' ' '), macOS SDK $BUILD_SDK_VERSION"
  echo "构建配置: $BUILD_CONFIGURATION"
  echo "DMG: $DMG_PATH"
  echo "ZIP: $ZIP_PATH"
  echo "ASCII 文件名 DMG（内含存储清理助手.app）: $ASCII_DMG_PATH"
  echo "ASCII 文件名 ZIP（内含存储清理助手.app）: $ASCII_ZIP_PATH"
  echo "本地验证 App: $DIST_APP"
  echo
  echo "codesign:"
  codesign --verify --deep --strict --verbose=4 "$DMG_STAGING/$DISPLAY_NAME.app" 2>&1
  verify_app_metadata "$DMG_STAGING/$DISPLAY_NAME.app" "$DISPLAY_NAME" 2>&1
  echo
  echo "dmg contents:"
  verify_dmg_archive "$DMG_PATH" "$DISPLAY_NAME" "zh-dmg" "首次打开说明.txt" 2>&1
  verify_dmg_archive "$ASCII_DMG_PATH" "$DISPLAY_NAME" "ascii-dmg" "README-FIRST.txt" 2>&1
  echo
  echo "zip contents:"
  verify_zip_archive "$ZIP_PATH" "$DISPLAY_NAME" "zh-zip" "首次打开说明.txt" 2>&1
  verify_zip_archive "$ASCII_ZIP_PATH" "$DISPLAY_NAME" "ascii-zip" "README-FIRST.txt" 2>&1
  echo
  echo "checksums:"
  (cd "$CHECKSUM_STAGING" && shasum -a 256 -c "$CHECKSUM_PATH") 2>&1
  echo
  echo "spctl:"
  spctl --assess --type execute --verbose=4 "$DMG_STAGING/$DISPLAY_NAME.app" 2>&1 || true
  echo
  echo "可用证书:"
  security find-identity -v -p codesigning 2>&1 || true
  echo
  if [[ "$SIGN_IDENTITY" == Developer\ ID\ Application* ]]; then
    echo "结论: 已用 Developer ID Application 证书签名；如需双击无拦截，还需要提交 Apple notarization 并 staple。"
    echo "下一步: NOTARY_PROFILE=storage-cleaner script/notarize_release.sh"
  elif [[ "$SIGN_IDENTITY" == Apple\ Development* ]]; then
    echo "结论: 已用 Apple Development 证书签名，签名结构有效；但这不是公开分发用 Developer ID，也不是 Apple 公证版本。"
  elif [ "$SIGN_IDENTITY" = "-" ]; then
    echo "结论: 当前机器没有可用发布证书，本包已修复签名结构，但不是 Apple 公证版本。"
  else
    echo "结论: 已用 $SIGN_IDENTITY 签名；如需双击无拦截，还需要 Developer ID 签名并提交 Apple notarization。"
  fi
} > "$REPORT_PATH"
clean_attrs "$REPORT_PATH"

echo "$DMG_PATH"
echo "$ZIP_PATH"
echo "$ASCII_DMG_PATH"
echo "$ASCII_ZIP_PATH"
echo "$REPORT_PATH"
echo "$CHECKSUM_PATH"
