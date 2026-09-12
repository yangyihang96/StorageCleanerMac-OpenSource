# Support

## Requirements

- macOS 14 or later
- Apple silicon for the production baseline currently used by the project
- No administrator permission is required for memory diagnosis or normal app quit

## Memory data is unavailable

Refresh once and wait for a second sample; swap rates require two monotonic samples. If only one metric is unavailable, the UI shows an unavailable reason instead of 0. Restarting the app resets the rate baseline but does not change system memory.

## An app did not quit

Save work in the target application first. A normal quit can be refused by an app with unsaved documents, can time out, or can become invalid if the process restarts. StorageCleanerMac reports that result and does not silently force quit. Re-open the selection and explicitly choose force quit only if data loss is acceptable.

## Build verification

Run:

```sh
./script/bootstrap.sh
STORAGE_CLEANER_VERIFY_BUNDLE=0 ./script/verify.sh
```

For an interactive GUI session with Accessibility permission available:

```sh
STORAGE_CLEANER_UI_SMOKE=1 ./script/verify.sh
```

The second command opens and closes test windows. It does not install or publish the app.
