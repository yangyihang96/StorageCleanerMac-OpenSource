#!/usr/bin/env bash
set -euo pipefail

DISPLAY_NAME="存储清理助手"
APP_NAME="StorageCleanerMac"
MODE="${1:-notarize}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release_version.env
source "$ROOT_DIR/script/release_version.env"
RELEASE_DIR="${RELEASE_DIR:-$ROOT_DIR/release}"
DIST_DIR="${DIST_DIR:-/tmp/storage-cleaner-release-dist}"
DIST_APP="$DIST_DIR/StorageCleanerMac.app"
EXPECTED_BUNDLE_ID="${EXPECTED_BUNDLE_ID:-com.local.StorageCleanerMac}"
FAN_HELPER_NAME="StorageCleanerFanControlHelper"
FAN_HELPER_LABEL="com.local.StorageCleanerMac.FanControlHelper"
EXPECTED_VERSION="${EXPECTED_VERSION:-${APP_VERSION:-$DEFAULT_APP_VERSION}}"
EXPECTED_BUILD="${EXPECTED_BUILD:-${APP_BUILD:-$DEFAULT_APP_BUILD}}"
EXPECTED_DISPLAY_NAME="${EXPECTED_DISPLAY_NAME:-$DISPLAY_NAME}"
EXPECTED_DEVELOPMENT_REGION="${EXPECTED_DEVELOPMENT_REGION:-zh-Hans}"
EXPECTED_MIN_SYSTEM_VERSION="${EXPECTED_MIN_SYSTEM_VERSION:-14.0}"
EXPECTED_FEED_URL="${EXPECTED_FEED_URL:-https://raw.githubusercontent.com/yangyihang96/StorageCleanerMacUpdates/main/appcast.xml}"
EXPECTED_SPARKLE_PUBLIC_KEY="${EXPECTED_SPARKLE_PUBLIC_KEY:-9zE8Bh4PM/yp47qqC5RmAVnvkrqlX7TtT7POVCz2wEo=}"
APP_VERSION="${APP_VERSION:-$EXPECTED_VERSION}"
if [ -z "$APP_VERSION" ] && [ -f "$DIST_APP/Contents/Info.plist" ]; then
  APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$DIST_APP/Contents/Info.plist")"
fi
APP_VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"
ASCII_DMG_ASSET_NAME="StorageCleanerMac-$APP_VERSION.dmg"
ASCII_ZIP_ASSET_NAME="StorageCleanerMac-$APP_VERSION.zip"
ZH_DMG_ASSET_NAME="StorageCleanerMac-zhHans-$APP_VERSION.dmg"
ZH_ZIP_ASSET_NAME="StorageCleanerMac-zhHans-$APP_VERSION.zip"
DMG_PATH="$RELEASE_DIR/$DISPLAY_NAME-$APP_VERSION.dmg"
ZIP_PATH="$RELEASE_DIR/$DISPLAY_NAME-$APP_VERSION.zip"
ASCII_DMG_PATH="$RELEASE_DIR/$ASCII_DMG_ASSET_NAME"
ASCII_ZIP_PATH="$RELEASE_DIR/$ASCII_ZIP_ASSET_NAME"
ZH_DMG_ASSET_PATH="$RELEASE_DIR/$ZH_DMG_ASSET_NAME"
ZH_ZIP_ASSET_PATH="$RELEASE_DIR/$ZH_ZIP_ASSET_NAME"
CHECKSUM_PATH="$RELEASE_DIR/CHECKSUMS-SHA256-$APP_VERSION.txt"
if [ "$MODE" = "--verify-only" ]; then
  REPORT_PATH="${VERIFY_REPORT_PATH:-$RELEASE_DIR/公开分发验证报告.txt}"
else
  REPORT_PATH="${NOTARY_REPORT_PATH:-$RELEASE_DIR/公证验证报告.txt}"
fi
NOTICE_PATH="$ROOT_DIR/THIRD_PARTY_NOTICES.md"
NOTICE_NAME="THIRD_PARTY_NOTICES.md"
WORK_DIR="${WORK_DIR:-/tmp/storage-cleaner-notarize}"
NOTARY_PROFILE="${NOTARY_PROFILE:-storage-cleaner}"
STAPLED_APP="$WORK_DIR/$DISPLAY_NAME.app"
APP_SUBMISSION="$WORK_DIR/StorageCleanerMac-app-submission.zip"
ZH_DMG_STAGING="$WORK_DIR/zh-dmg-staging"
ASCII_DMG_STAGING="$WORK_DIR/ascii-dmg-staging"
ZH_ZIP_STAGING="$WORK_DIR/zh-zip-staging"
ASCII_ZIP_STAGING="$WORK_DIR/ascii-zip-staging"
VERIFY_ROOT="$WORK_DIR/verify"
LAST_NOTARY_ID=""

log_report() {
  echo "$*" | tee -a "$REPORT_PATH"
}

fail() {
  echo "$*" >&2
  exit 1
}

find_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Developer ID Application/ { print $2; exit }'
}

clean_pre_notary_attrs() {
  local path="$1"
  xattr -cr "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.FinderInfo "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.ResourceFork "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.quarantine "$path" >/dev/null 2>&1 || true
  xattr -dr com.apple.provenance "$path" >/dev/null 2>&1 || true
}

signature_details() {
  codesign -dvvv "$1" 2>&1
}

verify_distribution_signature() {
  local app_path="$1"
  local details
  local entitlements_path="$WORK_DIR/entitlements.plist"

  codesign --verify --deep --strict --verbose=4 "$app_path"
  details="$(signature_details "$app_path")"

  if ! grep -Fq "Authority=Developer ID Application:" <<<"$details"; then
    fail "$app_path is not signed with Developer ID Application."
  fi
  if ! grep -Eq "flags=.*runtime" <<<"$details"; then
    fail "$app_path does not have the hardened runtime enabled."
  fi
  if ! grep -Fq "Timestamp=" <<<"$details"; then
    fail "$app_path does not include a secure signing timestamp."
  fi

  : > "$entitlements_path"
  codesign -d --entitlements - "$app_path" >"$entitlements_path" 2>/dev/null || true
  if [ -s "$entitlements_path" ] \
      && /usr/libexec/PlistBuddy -c "Print :com.apple.security.get-task-allow" "$entitlements_path" 2>/dev/null \
        | grep -Fxq "true"; then
    fail "$app_path contains com.apple.security.get-task-allow=true."
  fi
}

verify_fan_helper_distribution_contract() {
  local app_path="$1"
  local helper_path="$app_path/Contents/Resources/$FAN_HELPER_NAME"
  local app_details helper_details app_team helper_team app_chain helper_chain

  [ -x "$helper_path" ] || fail "$app_path is missing $FAN_HELPER_NAME."
  codesign --verify --strict --verbose=4 "$helper_path"
  app_details="$(signature_details "$app_path")"
  helper_details="$(signature_details "$helper_path")"
  grep -Fxq "Identifier=$EXPECTED_BUNDLE_ID" <<<"$app_details" \
    || fail "$app_path has the wrong code-signing identifier."
  grep -Fxq "Identifier=$FAN_HELPER_LABEL" <<<"$helper_details" \
    || fail "$helper_path has the wrong code-signing identifier."

  app_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$app_details" | head -1)"
  helper_team="$(sed -n 's/^TeamIdentifier=//p' <<<"$helper_details" | head -1)"
  [ -n "$app_team" ] && [ "$app_team" = "$helper_team" ] \
    || fail "$app_path and its helper do not share the same signing team."
  app_chain="$(grep '^Authority=' <<<"$app_details")"
  helper_chain="$(grep '^Authority=' <<<"$helper_details")"
  [ -n "$app_chain" ] && [ "$app_chain" = "$helper_chain" ] \
    || fail "$app_path and its helper do not share the same certificate chain."
  grep -Fq "Authority=Developer ID Application:" <<<"$helper_details" \
    || fail "$helper_path is not signed for production distribution."
  grep -Eq "flags=.*runtime" <<<"$helper_details" \
    || fail "$helper_path does not have hardened runtime enabled."
  grep -Fq "Timestamp=" <<<"$helper_details" \
    || fail "$helper_path does not include a secure signing timestamp."
}

verify_stapled_app() {
  local app_path="$1"
  local plist_path="$app_path/Contents/Info.plist"
  local actual_bundle_id
  local actual_version
  local actual_build
  local actual_display_name
  local actual_bundle_name
  local actual_development_region
  local actual_min_system_version
  local actual_feed_url
  local actual_sparkle_public_key
  local actual_automatic_checks
  local actual_automatic_updates
  local actual_update_verification

  verify_distribution_signature "$app_path"
  verify_fan_helper_distribution_contract "$app_path"
  [ -f "$plist_path" ] || fail "$app_path is missing Contents/Info.plist."
  actual_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist_path")"
  actual_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$plist_path")"
  actual_build="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$plist_path")"
  actual_display_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleDisplayName" "$plist_path")"
  actual_bundle_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$plist_path")"
  actual_development_region="$(/usr/libexec/PlistBuddy -c "Print :CFBundleDevelopmentRegion" "$plist_path")"
  actual_min_system_version="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$plist_path")"
  actual_feed_url="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$plist_path")"
  actual_sparkle_public_key="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$plist_path")"
  actual_automatic_checks="$(/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$plist_path")"
  actual_automatic_updates="$(/usr/libexec/PlistBuddy -c "Print :SUAutomaticallyUpdate" "$plist_path")"
  actual_update_verification="$(/usr/libexec/PlistBuddy -c "Print :SUVerifyUpdateBeforeExtraction" "$plist_path")"
  [ "$actual_bundle_id" = "$EXPECTED_BUNDLE_ID" ] \
    || fail "$app_path has unexpected bundle ID $actual_bundle_id."
  if [ -n "$EXPECTED_VERSION" ] && [ "$actual_version" != "$EXPECTED_VERSION" ]; then
    fail "$app_path has version $actual_version; expected $EXPECTED_VERSION."
  fi
  [ "$actual_build" = "$EXPECTED_BUILD" ] \
    || fail "$app_path has build $actual_build; expected $EXPECTED_BUILD."
  [ "$actual_display_name" = "$EXPECTED_DISPLAY_NAME" ] \
    || fail "$app_path has display name $actual_display_name; expected $EXPECTED_DISPLAY_NAME."
  [ "$actual_bundle_name" = "$EXPECTED_DISPLAY_NAME" ] \
    || fail "$app_path has bundle name $actual_bundle_name; expected $EXPECTED_DISPLAY_NAME."
  [ "$actual_development_region" = "$EXPECTED_DEVELOPMENT_REGION" ] \
    || fail "$app_path has development region $actual_development_region; expected $EXPECTED_DEVELOPMENT_REGION."
  /usr/libexec/PlistBuddy -c "Print :CFBundleLocalizations" "$plist_path" \
    | grep -Fq "zh-Hans" \
    || fail "$app_path is missing the zh-Hans localization declaration."
  [ "$actual_min_system_version" = "$EXPECTED_MIN_SYSTEM_VERSION" ] \
    || fail "$app_path requires macOS $actual_min_system_version; expected $EXPECTED_MIN_SYSTEM_VERSION."
  [ "$actual_feed_url" = "$EXPECTED_FEED_URL" ] \
    || fail "$app_path has unexpected Sparkle feed URL $actual_feed_url."
  [ "$actual_sparkle_public_key" = "$EXPECTED_SPARKLE_PUBLIC_KEY" ] \
    || fail "$app_path has an unexpected Sparkle public key."
  [ "$actual_automatic_checks" = "true" ] \
    || fail "$app_path does not enable automatic update checks."
  [ "$actual_automatic_updates" = "true" ] \
    || fail "$app_path does not enable automatic updates."
  [ "$actual_update_verification" = "true" ] \
    || fail "$app_path does not require update verification before extraction."
  xcrun stapler validate "$app_path"
  if command -v syspolicy_check >/dev/null 2>&1; then
    syspolicy_check distribution "$app_path"
  fi
  spctl --assess --type execute --verbose=4 "$app_path"
}

submit_notary() {
  local artifact_path="$1"
  local label="$2"
  local result_path="$WORK_DIR/$label-result.json"
  local log_path="$WORK_DIR/$label-log.json"
  local status

  xcrun notarytool submit "$artifact_path" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait \
    --output-format json > "$result_path"

  status="$(plutil -extract status raw -o - "$result_path")"
  LAST_NOTARY_ID="$(plutil -extract id raw -o - "$result_path")"
  xcrun notarytool log "$LAST_NOTARY_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    "$log_path" >/dev/null

  log_report "$label submission: $LAST_NOTARY_ID ($status)"
  if [ "$status" != "Accepted" ]; then
    echo "Apple notarization rejected $artifact_path. Log: $log_path" >&2
    cat "$log_path" >&2
    exit 5
  fi

  if grep -Eq '"severity"[[:space:]]*:[[:space:]]*"warning"' "$log_path"; then
    log_report "$label log: accepted with warnings; review $log_path"
  else
    log_report "$label log: accepted with no reported warnings"
  fi
}

write_chinese_readme() {
  local destination="$1"
  cat > "$destination" <<'TXT'
存储清理助手 - 首次打开说明

Apple 验证状态：
- 此发行包使用 Developer ID Application 证书签名。
- App 与 DMG 已通过 Apple notarization，公证票据已附加。
- 正常安装无需 Control-点击，也无需执行 xattr 命令。

安装：
1. 打开 DMG。
2. 把“存储清理助手.app”拖到 Applications。
3. 从 /Applications/存储清理助手.app 双击打开。

首次打开：
- macOS 仍可能显示标准的“从互联网下载”确认，这是正常的首次运行提示，不是“无法验证开发者”。
- 完整磁盘访问、文件与文件夹等授权是清理功能需要的系统权限，与开发者身份验证是两件事。
- 后续继续使用同一个 /Applications 副本，可减少重复文件访问授权。
TXT
}

write_english_readme() {
  local destination="$1"
  cat > "$destination" <<'TXT'
Storage Cleaner Mac - First Launch

Apple verification:
- This release is signed with a Developer ID Application certificate.
- The app and DMG are notarized by Apple and have their tickets stapled.
- Normal installation does not require Control-click or an xattr command.

Install:
1. Open the DMG.
2. Drag 存储清理助手.app to Applications.
3. Open /Applications/存储清理助手.app.

First launch:
- macOS may still show its standard downloaded-from-the-Internet confirmation. This is not an unidentified-developer warning.
- Full Disk Access and Files & Folders prompts are functional permissions and are separate from developer verification.
- Keep using the same Applications copy to reduce repeated file-access prompts.
TXT
}

prepare_staging_directories() {
  rm -rf "$ZH_DMG_STAGING" "$ASCII_DMG_STAGING" "$ZH_ZIP_STAGING" "$ASCII_ZIP_STAGING"
  mkdir -p "$ZH_DMG_STAGING" "$ASCII_DMG_STAGING" "$ZH_ZIP_STAGING" "$ASCII_ZIP_STAGING"

  /usr/bin/ditto "$STAPLED_APP" "$ZH_DMG_STAGING/$DISPLAY_NAME.app"
  /usr/bin/ditto "$STAPLED_APP" "$ZH_ZIP_STAGING/$DISPLAY_NAME.app"
  /usr/bin/ditto "$STAPLED_APP" "$ASCII_DMG_STAGING/$DISPLAY_NAME.app"
  /usr/bin/ditto "$STAPLED_APP" "$ASCII_ZIP_STAGING/$DISPLAY_NAME.app"

  ln -s /Applications "$ZH_DMG_STAGING/Applications"
  ln -s /Applications "$ASCII_DMG_STAGING/Applications"

  write_chinese_readme "$ZH_DMG_STAGING/首次打开说明.txt"
  /usr/bin/ditto "$ZH_DMG_STAGING/首次打开说明.txt" "$ZH_ZIP_STAGING/首次打开说明.txt"
  write_english_readme "$ASCII_DMG_STAGING/README-FIRST.txt"
  /usr/bin/ditto "$ASCII_DMG_STAGING/README-FIRST.txt" "$ASCII_ZIP_STAGING/README-FIRST.txt"

  /usr/bin/ditto "$NOTICE_PATH" "$ZH_DMG_STAGING/$NOTICE_NAME"
  /usr/bin/ditto "$NOTICE_PATH" "$ZH_ZIP_STAGING/$NOTICE_NAME"
  /usr/bin/ditto "$NOTICE_PATH" "$ASCII_DMG_STAGING/$NOTICE_NAME"
  /usr/bin/ditto "$NOTICE_PATH" "$ASCII_ZIP_STAGING/$NOTICE_NAME"
}

create_zip() {
  local staging_path="$1"
  local zip_path="$2"

  rm -f "$zip_path"
  (
    cd "$staging_path"
    /usr/bin/ditto -c -k --sequesterRsrc . "$zip_path"
  )
}

create_dmg() {
  local staging_path="$1"
  local volume_name="$2"
  local dmg_path="$3"
  local temp_dmg="$WORK_DIR/$volume_name-temp.dmg"

  rm -f "$temp_dmg" "$dmg_path"
  hdiutil create -volname "$volume_name" -srcfolder "$staging_path" \
    -ov -format UDRW "$temp_dmg" >/dev/null
  hdiutil convert "$temp_dmg" -format UDZO -imagekey zlib-level=9 \
    -o "$dmg_path" >/dev/null
  hdiutil verify "$dmg_path" >/dev/null
  xattr -c "$dmg_path" >/dev/null 2>&1 || true
  codesign --force --timestamp --sign "$DEVELOPER_ID" "$dmg_path" >/dev/null
  codesign --verify --verbose=4 "$dmg_path"
}

refresh_localized_release_assets() {
  rm -f "$ZH_DMG_ASSET_PATH" "$ZH_ZIP_ASSET_PATH"
  /usr/bin/ditto "$DMG_PATH" "$ZH_DMG_ASSET_PATH"
  /usr/bin/ditto "$ZIP_PATH" "$ZH_ZIP_ASSET_PATH"
  xattr -c "$ZH_DMG_ASSET_PATH" >/dev/null 2>&1 || true
  xattr -c "$ZH_ZIP_ASSET_PATH" >/dev/null 2>&1 || true
}

write_and_verify_checksums() {
  (
    cd "$RELEASE_DIR"
    shasum -a 256 \
      "$ASCII_DMG_ASSET_NAME" \
      "$ASCII_ZIP_ASSET_NAME" \
      "$ZH_DMG_ASSET_NAME" \
      "$ZH_ZIP_ASSET_NAME" > "$CHECKSUM_PATH"
    shasum -a 256 -c "$CHECKSUM_PATH"
  )
  xattr -c "$CHECKSUM_PATH" >/dev/null 2>&1 || true
}

notarize_and_staple_dmg() {
  local dmg_path="$1"
  local label="$2"

  submit_notary "$dmg_path" "$label"
  xcrun stapler staple "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"
}

verify_readme_and_notice() {
  local root_path="$1"
  local readme_name="$2"
  local language="$3"

  [ -f "$root_path/$readme_name" ] || fail "$root_path is missing $readme_name."
  [ -f "$root_path/$NOTICE_NAME" ] || fail "$root_path is missing $NOTICE_NAME."
  grep -Fq "Stats SMC helper" "$root_path/$NOTICE_NAME" \
    || fail "$root_path/$NOTICE_NAME is missing the SMC attribution."

  if [ "$language" = "zh" ]; then
    grep -Fq "已通过 Apple notarization" "$root_path/$readme_name" \
      || fail "$readme_name does not state the notarized status."
    grep -Fq "无需 Control-点击" "$root_path/$readme_name" \
      || fail "$readme_name still requires the unidentified-developer workaround."
  else
    grep -Fq "notarized by Apple" "$root_path/$readme_name" \
      || fail "$readme_name does not state the notarized status."
    grep -Fq "does not require Control-click" "$root_path/$readme_name" \
      || fail "$readme_name still requires the unidentified-developer workaround."
  fi
}

verify_zip() {
  local zip_path="$1"
  local expected_app_name="$2"
  local readme_name="$3"
  local language="$4"
  local label="$5"
  local verify_path="$VERIFY_ROOT/$label"

  rm -rf "$verify_path"
  mkdir -p "$verify_path"
  /usr/bin/ditto -x -k "$zip_path" "$verify_path"
  verify_stapled_app "$verify_path/$expected_app_name.app"
  verify_readme_and_notice "$verify_path" "$readme_name" "$language"
  log_report "$label: ZIP contains a Developer ID-signed, notarized, stapled app"
}

verify_dmg() {
  local dmg_path="$1"
  local expected_app_name="$2"
  local readme_name="$3"
  local language="$4"
  local label="$5"
  local mount_path="$VERIFY_ROOT/$label-mount"

  hdiutil verify "$dmg_path" >/dev/null
  codesign --verify --verbose=4 "$dmg_path"
  xcrun stapler validate "$dmg_path"
  spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path"

  rm -rf "$mount_path"
  mkdir -p "$mount_path"
  hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_path" >/dev/null
  (
    cleanup_mounted_dmg() {
      hdiutil detach "$mount_path" >/dev/null 2>&1 || true
    }

    trap cleanup_mounted_dmg EXIT
    verify_stapled_app "$mount_path/$expected_app_name.app"
    verify_readme_and_notice "$mount_path" "$readme_name" "$language"
    cleanup_mounted_dmg
    trap - EXIT
  )
  log_report "$label: DMG and contained app pass stapler and Gatekeeper assessment"
}

verify_quarantined_copy() {
  local source_app="$1"
  local quarantine_root="$VERIFY_ROOT/quarantine"
  local quarantine_app="$quarantine_root/$DISPLAY_NAME.app"
  local quarantine_stamp

  rm -rf "$quarantine_root"
  mkdir -p "$quarantine_root"
  /usr/bin/ditto "$source_app" "$quarantine_app"
  quarantine_stamp="$(printf '%x' "$(date +%s)")"
  xattr -w com.apple.quarantine "0081;$quarantine_stamp;StorageCleanerMac;" "$quarantine_app"
  verify_stapled_app "$quarantine_app"
  log_report "Quarantine simulation: Gatekeeper accepts the downloaded-app copy"
}

verify_final_release() {
  [ -f "$CHECKSUM_PATH" ] || fail "Missing $CHECKSUM_PATH."
  for archive in \
    "$DMG_PATH" \
    "$ASCII_DMG_PATH" \
    "$ZIP_PATH" \
    "$ASCII_ZIP_PATH" \
    "$ZH_DMG_ASSET_PATH" \
    "$ZH_ZIP_ASSET_PATH"; do
    [ -f "$archive" ] || fail "Missing $archive."
  done

  verify_zip "$ZIP_PATH" "$DISPLAY_NAME" "首次打开说明.txt" "zh" "zh-zip"
  verify_zip "$ASCII_ZIP_PATH" "$DISPLAY_NAME" "README-FIRST.txt" "en" "ascii-zip"
  verify_dmg "$DMG_PATH" "$DISPLAY_NAME" "首次打开说明.txt" "zh" "zh-dmg"
  verify_dmg "$ASCII_DMG_PATH" "$DISPLAY_NAME" "README-FIRST.txt" "en" "ascii-dmg"
  verify_quarantined_copy "$VERIFY_ROOT/ascii-zip/$DISPLAY_NAME.app"
  (cd "$RELEASE_DIR" && shasum -a 256 -c "$CHECKSUM_PATH")
}

if [ "$MODE" = "--verify-only" ]; then
  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR" "$RELEASE_DIR" "$VERIFY_ROOT"
  [ -f "$ASCII_ZIP_PATH" ] || fail "Missing $ASCII_ZIP_PATH."
  if [ -z "$EXPECTED_VERSION" ]; then
    version_probe="$WORK_DIR/version-probe"
    mkdir -p "$version_probe"
    /usr/bin/ditto -x -k "$ASCII_ZIP_PATH" "$version_probe"
    EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
      "$version_probe/$DISPLAY_NAME.app/Contents/Info.plist")"
  fi
  {
    echo "存储清理助手 公开分发验证报告"
    echo
    echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
    echo "预期版本: $EXPECTED_VERSION"
    echo "预期 Build: $EXPECTED_BUILD"
    echo "预期 Bundle ID: $EXPECTED_BUNDLE_ID"
    echo "预期显示名称: $EXPECTED_DISPLAY_NAME"
    echo "预期语言: $EXPECTED_DEVELOPMENT_REGION"
    echo "预期更新源: $EXPECTED_FEED_URL"
    echo
  } > "$REPORT_PATH"
  verify_final_release
  log_report "结论: 当前发行包通过 Developer ID、公证票据、Gatekeeper、隔离副本和校验和验收。"
  echo "$REPORT_PATH"
  exit 0
fi

if [ "$MODE" != "notarize" ]; then
  fail "Usage: $0 [--verify-only]"
fi

[ -d "$DIST_APP" ] || fail "Missing $DIST_APP. Run script/make_release_dmg.sh first."
[ -f "$NOTICE_PATH" ] || fail "Missing $NOTICE_PATH."

if [ -z "$EXPECTED_VERSION" ]; then
  EXPECTED_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$DIST_APP/Contents/Info.plist")"
fi

DEVELOPER_ID="$(find_developer_id)"
[ -n "$DEVELOPER_ID" ] || fail "No Developer ID Application certificate found."

if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  fail "Notary profile '$NOTARY_PROFILE' is missing or invalid."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$RELEASE_DIR" "$VERIFY_ROOT"

{
  echo "存储清理助手 公证验证报告"
  echo
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "签名身份: $DEVELOPER_ID"
  echo "Notary profile: $NOTARY_PROFILE"
  echo
} > "$REPORT_PATH"

/usr/bin/ditto "$DIST_APP" "$STAPLED_APP"
clean_pre_notary_attrs "$STAPLED_APP"
verify_distribution_signature "$STAPLED_APP"

rm -f "$APP_SUBMISSION"
/usr/bin/ditto -c -k --keepParent "$STAPLED_APP" "$APP_SUBMISSION"
submit_notary "$APP_SUBMISSION" "app"
xcrun stapler staple "$STAPLED_APP"
verify_stapled_app "$STAPLED_APP"
log_report "App: Developer ID signature, hardened runtime, secure timestamp, notarization, and staple verified"

rm -rf "$DIST_APP"
/usr/bin/ditto "$STAPLED_APP" "$DIST_APP"
verify_stapled_app "$DIST_APP"

prepare_staging_directories
create_zip "$ZH_ZIP_STAGING" "$ZIP_PATH"
create_zip "$ASCII_ZIP_STAGING" "$ASCII_ZIP_PATH"
create_dmg "$ZH_DMG_STAGING" "$DISPLAY_NAME" "$DMG_PATH"
create_dmg "$ASCII_DMG_STAGING" "$APP_NAME" "$ASCII_DMG_PATH"

notarize_and_staple_dmg "$DMG_PATH" "zh-dmg"
notarize_and_staple_dmg "$ASCII_DMG_PATH" "ascii-dmg"

verify_zip "$ZIP_PATH" "$DISPLAY_NAME" "首次打开说明.txt" "zh" "zh-zip"
verify_zip "$ASCII_ZIP_PATH" "$DISPLAY_NAME" "README-FIRST.txt" "en" "ascii-zip"
verify_dmg "$DMG_PATH" "$DISPLAY_NAME" "首次打开说明.txt" "zh" "zh-dmg"
verify_dmg "$ASCII_DMG_PATH" "$DISPLAY_NAME" "README-FIRST.txt" "en" "ascii-dmg"
verify_quarantined_copy "$DIST_APP"

refresh_localized_release_assets
write_and_verify_checksums

log_report "Checksums: regenerated after all staple and archive rebuild operations"
log_report "结论: App 与 DMG 已通过 Apple 公证并附加票据；DMG/ZIP 内 App 均通过 Gatekeeper 验收。"

echo "$DMG_PATH"
echo "$ZIP_PATH"
echo "$ASCII_DMG_PATH"
echo "$ASCII_ZIP_PATH"
echo "$CHECKSUM_PATH"
echo "$REPORT_PATH"
