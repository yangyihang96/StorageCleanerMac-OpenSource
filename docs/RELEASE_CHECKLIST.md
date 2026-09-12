# Release Checklist

Use this checklist with the authoritative commands in [`../RELEASE.md`](../RELEASE.md). A build, install, signature, notarization, upload, appcast edit, and observed update are separate proof states.

## Source

- [ ] `script/release_version.env` contains the final version and 12-digit build.
- [ ] All intended changes are committed; generated artifacts are outside the release checkout.
- [ ] `origin/main` is fully integrated and no remote-only commit remains.
- [ ] The annotated `v<version>` tag points at the exact clean release commit.
- [ ] `./script/build-release.sh --verify-tag` passes from a clean checkout.

## Tests and runtime

- [ ] Full Debug tests pass with the exact release commit.
- [ ] Full Release tests and the production benchmark gate pass with the exact release commit.
- [ ] Benchmark leaderboard server tests and type checking pass against the matching contract.
- [ ] One Release official product flow completes CPU, GPU, memory, storage, display, and 600-second sustained work.
- [ ] The official result records the exact app version/build, 28 metrics, 84 completed executions, and no runtime failure.
- [ ] Real installed-app windows cover application updates, browser privacy, benchmark history, leaderboard, light mode, and dark mode.

## Signing and packaging

- [ ] A valid `Developer ID Application` identity is installed.
- [ ] The configured `notarytool` keychain profile authenticates successfully.
- [ ] App and helper use hardened runtime, secure timestamps, and strict nested signatures.
- [ ] App and both DMGs are notarized; the app and DMGs have stapled tickets.
- [ ] `spctl`, quarantined-copy launch, archive extraction, version/build, architecture, minimum macOS, and checksums pass.
- [ ] Sparkle EdDSA signing uses the existing application account and verifies independently.

## Publication

- [ ] Source and public-update tags are new and immutable; historical tags and assets are unchanged.
- [ ] Public update assets are uploaded before the appcast is changed.
- [ ] Anonymous downloads match the local byte length and SHA-256 exactly.
- [ ] The new appcast item has the exact version, build, URL, length, minimum macOS, architecture, and EdDSA signature.
- [ ] The source Release and public update Release are visible at the expected tags.

## Update acceptance

- [ ] A real install of the immediately previous public version discovers the exact new version/build being released (for the next release, start from public 1.9.12 and target 1.9.13+).
- [ ] Sparkle downloads, verifies, replaces the whole app, exits the old process, relaunches the new build, and preserves user data.
- [ ] Cancellation leaves the old app usable.
- [ ] At least one bad download, bad signature, or replacement failure is rejected without losing the old app or user data.
- [ ] Final reporting keeps local build, installed build, signed package, notarized package, public assets, appcast, and observed update distinct.
