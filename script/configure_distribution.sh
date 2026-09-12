#!/usr/bin/env bash
set -euo pipefail

PROFILE_NAME="${NOTARY_PROFILE:-storage-cleaner}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release_version.env
source "$ROOT_DIR/script/release_version.env"
DIST_DIR="${DIST_DIR:-/tmp/storage-cleaner-release-dist}"
ENROLLMENT_URL="https://developer.apple.com/programs/enroll/"
EXPECTED_RELEASE_VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"
EXPECTED_RELEASE_BUILD="${APP_BUILD:-$DEFAULT_APP_BUILD}"

find_developer_id() {
  security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }'
}

echo "Storage Cleaner distribution setup"
echo

DEVELOPER_ID="$(find_developer_id)"
if [ -z "$DEVELOPER_ID" ]; then
  echo "Missing: Developer ID Application certificate."
  echo
  if defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
      | grep -q "isFreeProvisioningTeam = 1"; then
    echo "The Xcode account is currently using a free Personal Team."
    echo "Apple does not issue Developer ID certificates to free Personal Teams."
    echo
    echo "Enroll the Account Holder in the Apple Developer Program first:"
    echo "  $ENROLLMENT_URL"
  else
    echo "Open Xcode, then use:"
    echo "  Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application"
    echo
    echo "The Account Holder or an authorized Admin must create the certificate."
  fi
  echo "After the certificate is installed, run this script again:"
  echo "  $0"
  exit 3
fi

echo "Developer ID certificate:"
echo "  $DEVELOPER_ID"
echo

if xcrun notarytool history --keychain-profile "$PROFILE_NAME" >/tmp/storage-cleaner-notary-history.log 2>&1; then
  echo "Notary profile found:"
  echo "  $PROFILE_NAME"
else
  if [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
    xcrun notarytool store-credentials "$PROFILE_NAME" \
      --key "$NOTARY_KEY" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER"
  elif [ -n "${APPLE_ID:-}" ] && [ -n "${TEAM_ID:-}" ] && [ -n "${APP_SPECIFIC_PASSWORD:-}" ]; then
    xcrun notarytool store-credentials "$PROFILE_NAME" \
      --apple-id "$APPLE_ID" \
      --team-id "$TEAM_ID" \
      --password "$APP_SPECIFIC_PASSWORD"
  else
    echo "Missing: notarytool profile '$PROFILE_NAME'."
    echo
    echo "Create an app-specific password at:"
    echo "  https://appleid.apple.com/account/manage"
    echo
    echo "Then run:"
    echo "  xcrun notarytool store-credentials $PROFILE_NAME --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>"
    echo
    echo "App Store Connect API keys are also supported:"
    echo "  NOTARY_KEY=<AuthKey.p8> NOTARY_KEY_ID=<key-id> NOTARY_ISSUER=<issuer-id> $0"
    echo
    echo "Or run this script with environment variables:"
    echo "  APPLE_ID=<apple-id> TEAM_ID=<team-id> APP_SPECIFIC_PASSWORD=<app-specific-password> $0"
    exit 4
  fi
fi

echo
echo "Building, signing, notarizing, and stapling release DMGs..."
APP_VERSION="$EXPECTED_RELEASE_VERSION" APP_BUILD="$EXPECTED_RELEASE_BUILD" \
  DIST_DIR="$DIST_DIR" SIGN_IDENTITY="$DEVELOPER_ID" REQUIRE_DEVELOPER_ID=1 \
  "$ROOT_DIR/script/make_release_dmg.sh"
RELEASE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
  "$DIST_DIR/StorageCleanerMac.app/Contents/Info.plist")"
RELEASE_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" \
  "$DIST_DIR/StorageCleanerMac.app/Contents/Info.plist")"
[ "$RELEASE_VERSION" = "$EXPECTED_RELEASE_VERSION" ] || {
  echo "Release version mismatch: got $RELEASE_VERSION, expected $EXPECTED_RELEASE_VERSION" >&2
  exit 5
}
[ "$RELEASE_BUILD" = "$EXPECTED_RELEASE_BUILD" ] || {
  echo "Release build mismatch: got $RELEASE_BUILD, expected $EXPECTED_RELEASE_BUILD" >&2
  exit 5
}
APP_VERSION="$RELEASE_VERSION" EXPECTED_VERSION="$RELEASE_VERSION" \
  EXPECTED_BUILD="$EXPECTED_RELEASE_BUILD" \
  DIST_DIR="$DIST_DIR" NOTARY_PROFILE="$PROFILE_NAME" "$ROOT_DIR/script/notarize_release.sh"

echo
echo "Final Gatekeeper verification:"
spctl --assess --type execute --verbose=4 "$DIST_DIR/StorageCleanerMac.app"
(cd "$ROOT_DIR/release" && \
  shasum -a 256 -c "$ROOT_DIR/release/CHECKSUMS-SHA256-$RELEASE_VERSION.txt")

echo
echo "Distribution setup complete."
