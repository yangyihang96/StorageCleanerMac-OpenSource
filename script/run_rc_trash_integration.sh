#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-/tmp/storage-cleaner-rc-trash-integration-build}"
LOG_DIR="${LOG_DIR:-/tmp/storage-cleaner-rc-trash-integration-logs}"

mkdir -p "$LOG_DIR"

run_once() (
  local run_number="$1"
  local run_root=""
  local rw_image=""
  local ro_image=""
  local detach_image=""
  local rw_mount=""
  local ro_mount=""
  local detach_mount=""
  local attached_mount=""
  local log_path="$LOG_DIR/run-$run_number.log"

  run_root="$(mktemp -d /private/tmp/storage-cleaner-rc-trash.XXXXXX)"
  case "$run_root" in
    /private/tmp/storage-cleaner-rc-trash.*) ;;
    *)
      echo "unsafe integration root: $run_root" >&2
      return 2
      ;;
  esac
  rw_image="$run_root/rw.sparsebundle"
  ro_image="$run_root/ro.sparsebundle"
  detach_image="$run_root/detach.sparsebundle"
  rw_mount="/Volumes/StorageCleanerRC-RW-$run_number-$$"
  ro_mount="/Volumes/StorageCleanerRC-RO-$run_number-$$"
  detach_mount="/Volumes/StorageCleanerRC-DETACH-$run_number-$$"

  cleanup() {
    local mount=""
    for mount in "$rw_mount" "$ro_mount" "$detach_mount"; do
      if /sbin/mount | grep -Fq " on $mount ("; then
        /usr/bin/hdiutil detach "$mount" >/dev/null
      fi
    done
    if /sbin/mount | grep -Fq "$run_root"; then
      echo "fixture volume remains mounted: $run_root" >&2
      return 1
    fi
    case "$run_root" in
      /private/tmp/storage-cleaner-rc-trash.*)
        /usr/bin/find "$run_root" -depth -delete
        ;;
    esac
  }
  trap cleanup EXIT

  /usr/bin/hdiutil create -quiet -size 192m -fs APFS \
    -volname "StorageCleanerRC-RW-$run_number-$$" -type SPARSEBUNDLE "$rw_image"
  /usr/bin/hdiutil create -quiet -size 96m -fs APFS \
    -volname "StorageCleanerRC-RO-$run_number-$$" -type SPARSEBUNDLE "$ro_image"
  /usr/bin/hdiutil create -quiet -size 96m -fs APFS \
    -volname "StorageCleanerRC-DETACH-$run_number-$$" -type SPARSEBUNDLE "$detach_image"

  attached_mount="$(
    /usr/bin/hdiutil attach -owners on "$rw_image" \
      | /usr/bin/awk '$3 ~ /^\/Volumes\/StorageCleanerRC-/ { print $3; exit }'
  )"
  [ "$attached_mount" = "$rw_mount" ]
  attached_mount="$(
    /usr/bin/hdiutil attach -owners on "$ro_image" \
      | /usr/bin/awk '$3 ~ /^\/Volumes\/StorageCleanerRC-/ { print $3; exit }'
  )"
  [ "$attached_mount" = "$ro_mount" ]
  attached_mount="$(
    /usr/bin/hdiutil attach -owners on "$detach_image" \
      | /usr/bin/awk '$3 ~ /^\/Volumes\/StorageCleanerRC-/ { print $3; exit }'
  )"
  [ "$attached_mount" = "$detach_mount" ]
  for mount in "$rw_mount" "$ro_mount" "$detach_mount"; do
    case "$mount" in
      /Volumes/StorageCleanerRC-*) ;;
      *)
        echo "unexpected integration mount: $mount" >&2
        return 2
        ;;
    esac
  done

  SC_RC_TRASH_RUN="$run_number" \
  SC_RC_TRASH_RW_ROOT="$rw_mount" \
  SC_RC_TRASH_RO_ROOT="$ro_mount" \
  SC_RC_TRASH_RO_IMAGE="$ro_image" \
  SC_RC_TRASH_DETACH_ROOT="$detach_mount" \
  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
    /usr/bin/swift test -c release \
      --scratch-path "$BUILD_DIR" \
      --jobs 2 \
      -Xswiftc -DSTORAGE_CLEANER_RC_TRASH_INTEGRATION \
      -Xswiftc -disable-batch-mode \
      --filter CleanupTrashItemIntegrationTests \
      >"$log_path" 2>&1

  grep -F "RC_TRASH_" "$log_path"
  cleanup
  trap - EXIT

  if [ -e "$run_root" ]; then
    echo "fixture root still exists after cleanup: $run_root" >&2
    return 3
  fi
  echo "RC_TRASH_SCENARIO|25|PASS|fixture-destroyed-run-$run_number"
)

run_once 1
run_once 2
