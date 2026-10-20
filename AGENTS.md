# StorageCleanerMac Agent Notes

- This is a SwiftPM macOS SwiftUI app. The only development copy is `~/Developer/StorageCleanerMac`; the old copy under `~/Documents` is a read-only backup. Never develop in a cloud-synced folder: placeholders hang `git describe`/SwiftPM and sync conflicts create duplicate `* 2.swift` sources.
- Use `./script/build_and_run.sh --beta` for the normal build loop. Add `--install` only when the user has approved replacing the single Beta at `/Applications/测试版.app`. The non-Beta modes use the release bundle identifier, share the installed app's data, and refuse to run while that app is running.
- Keep scanning read-only. Cleanup actions must be explicit UI actions and should prefer moving items to Trash.
- Junk-scan tiering follows DECISIONS D19 and D22–D25 (details in `docs/cleanup-rules.md`): every listed item can be selected and moved to Trash, except the separately confirmed "Empty Trash" item. Caches, logs and regenerable build artifacts are green; items that need judgment (Downloads, Mail Downloads, CloudKit, mid-age developer caches) are yellow; recently active developer files and duplicate app copies are red with two confirmations. Non-regenerable personal data, agent sessions and app bundles are not listed (File Analysis and Uninstall cover them).
- Private Apple API is allowed only where listed with a reason in `script/private-api-allowlist.txt`; `script/check_private_api.py` (run by `script/verify.sh`) enforces it.
- Verify with `script/verify.sh` (`DEVELOPER_DIR=/Applications/Xcode-27.0.0-Beta.app/Contents/Developer`, `STORAGE_CLEANER_VERIFY_BUNDLE=0`, `STORAGE_CLEANER_UI_SMOKE=0`, a private `STORAGE_CLEANER_VERIFY_ROOT`).
- 2.0.0 work is coordinated in `docs/2.0.0/collab/`: `RULES.md` (how sessions work), `BOARD.md` (batches and status), `DECISIONS.md` (product decisions that override older rules and tests).
- Do not initialize git in parent folders.

## Cursor Cloud specific instructions

Cloud Agent machines run Linux. This package targets macOS 14 and Xcode. `script/bootstrap.sh` exits unless the kernel is Darwin, and `script/build_and_run.sh`, `script/test.sh`, and `script/verify.sh` need the macOS SDK, `xcrun`, and `codesign`. Do not run those scripts here; they cannot compile or launch the app.

`./script/verify_cloud.sh` is the host-independent gate. It runs the private-API allowlist check, the menu-bar presentation assertions, the helper plist and upgrade-status unit tests, the SwiftUI process and purge source guards, the conflict-copy check, and `git diff --check`. Python 3 from the base image is enough; those scripts use only the standard library. Compiling, signing, and launching Storage Cleaner still happens on a Mac.
