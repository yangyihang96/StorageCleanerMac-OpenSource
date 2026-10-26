# StorageCleanerMac Agent Notes

- This is a SwiftPM macOS SwiftUI app. The only development copy is `~/Developer/StorageCleanerMac`; the old copy under `~/Documents` is a read-only backup. Never develop in a cloud-synced folder: placeholders hang `git describe`/SwiftPM and sync conflicts create duplicate `* 2.swift` sources.
- Use `./script/build_and_run.sh --beta` for the normal build loop. Add `--install` only when the user has approved replacing the single Beta at `/Applications/测试版.app`. The non-Beta modes use the release bundle identifier, share the installed app's data, and refuse to run while that app is running.
- Keep scanning read-only. Cleanup actions must be explicit UI actions and should prefer moving items to Trash.
- Junk-scan tiering follows DECISIONS D19 and D22–D25 (details in `docs/cleanup-rules.md`): every listed item can be selected and moved to Trash, except the separately confirmed "Empty Trash" item. Caches, logs and regenerable build artifacts are green; items that need judgment (Downloads, Mail Downloads, CloudKit, mid-age developer caches) are yellow; recently active developer files and duplicate app copies are red with two confirmations. Non-regenerable personal data, agent sessions and app bundles are not listed (File Analysis and Uninstall cover them).
- Private Apple API is allowed only where listed with a reason in `script/private-api-allowlist.txt`; `script/check_private_api.py` (run by `script/verify.sh`) enforces it.
- Verify with `script/verify.sh` (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, `STORAGE_CLEANER_VERIFY_BUNDLE=0`, `STORAGE_CLEANER_UI_SMOKE=0`, a private `STORAGE_CLEANER_VERIFY_ROOT`).
- 2.0.0 work is coordinated in `docs/2.0.0/collab/`: `RULES.md` (how sessions work), `BOARD.md` (batches and status), `DECISIONS.md` (product decisions that override older rules and tests).
- Do not initialize git in parent folders.
