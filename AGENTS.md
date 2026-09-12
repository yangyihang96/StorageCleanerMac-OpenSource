# StorageCleanerMac Agent Notes

- This is a SwiftPM macOS SwiftUI app. Use `./script/build_and_run.sh` for the normal build and launch loop.
- Keep scanning read-only. Cleanup actions must be explicit UI actions and should prefer moving items to Trash.
- Preserve the original `storage-analyzer` tiering boundary: caches and regenerable build artifacts are green, app/user data is yellow, apps and sensitive data are red or open-only.
- Do not initialize git outside this app directory; `/Users/developer/Documents/好玩的` is a mixed workspace.

