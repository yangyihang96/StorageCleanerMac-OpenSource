#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---candidate}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=release_version.env
source "$ROOT_DIR/script/release_version.env"
BUILD_DIR="${STORAGE_CLEANER_RELEASE_CANDIDATE_DIR:-/tmp/storage-cleaner-release-candidate}"
JOBS="${SWIFT_BUILD_JOBS:-2}"
APP_VERSION="${APP_VERSION:-$DEFAULT_APP_VERSION}"

verify_release_source() {
  [ -z "$(git status --porcelain --untracked-files=all)" ] || {
    echo "Release packaging requires a clean worktree." >&2
    exit 20
  }
  local expected_tag="v$APP_VERSION"
  local head_commit
  local tag_commit
  head_commit="$(git rev-parse HEAD)"
  tag_commit="$(git rev-parse "$expected_tag^{commit}" 2>/dev/null || true)"
  [ -n "$tag_commit" ] && [ "$tag_commit" = "$head_commit" ] || {
    echo "HEAD must be the immutable $expected_tag commit before distribution." >&2
    exit 21
  }
}

cd "$ROOT_DIR"
case "$MODE" in
  --candidate|candidate)
    "$ROOT_DIR/script/bootstrap.sh"
    swift build -c release --scratch-path "$BUILD_DIR" --jobs "$JOBS"
    swift test -c release --scratch-path "$BUILD_DIR" --jobs "$JOBS"
    echo "Release candidate build and tests passed; no distribution artifact was published."
    ;;
  --verify-tag|verify-tag)
    verify_release_source
    echo "Release source is clean and matches v$APP_VERSION."
    ;;
  --package|package)
    verify_release_source
    "$ROOT_DIR/script/configure_distribution.sh"
    ;;
  *)
    echo "usage: $0 [--candidate|--verify-tag|--package]" >&2
    exit 2
    ;;
esac
