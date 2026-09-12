# Release Runbook

## 1. Candidate validation

```sh
./script/build-release.sh --candidate
```

This performs a Release build and Release test run. It does not sign, notarize, install, publish, or mutate the appcast.

## 2. Source gate

Set `DEFAULT_APP_VERSION` and `DEFAULT_APP_BUILD` in `script/release_version.env`, commit all intended changes, and create the matching immutable tag. Then run:

```sh
./script/build-release.sh --verify-tag
```

The command requires a clean worktree and requires `HEAD` to match `v<version>`.

## 3. Developer ID package and notarization

Install a valid `Developer ID Application` identity and a `notarytool` keychain profile. Then run:

```sh
./script/build-release.sh --package
```

The existing distribution scripts perform the production benchmark gate, Release build, hardened-runtime signing, strict `codesign`, ZIP/DMG creation, SHA-256 generation, notarization, stapling, `spctl`, and artifact verification. They must fail if only Apple Development signing is available.

### Owner-authorized public-test exceptions

The owner explicitly authorized publishing versions `1.9.9 (202608052103)`,
`1.9.10 (202608131925)`, `1.9.11 (202608142241)`, and
`1.9.12 (202608282037)` as Apple Development-signed public test builds without
notarization. These narrow exceptions do not turn any artifact into a
Developer ID, notarized, or Gatekeeper-approved build and do not relax the
default gate for later versions. Each GitHub Release, packaged README, appcast
item, and handoff must state that first launch may require Control-click → Open.
Assets must still pass strict signatures, checksums, Sparkle EdDSA verification,
anonymous download verification, and a real public update test where the
environment permits it.

### 1.9.13 authorization (2026-09-12)

The owner explicitly confirmed publishing `1.9.13 (202609120014)` with the
locally built installers after being told that they use Apple Development
signing without notarization. The owner also accepted disclosure that the
600-second sustained benchmark was blocked by the thermal preflight, rather
than completed. This applies only to this public test release and does not
change hardware safety checks or future distribution defaults.

Local Debug and Release regression, the production calibration gate, strict
archive signatures and artwork matching, checksums, and independent Sparkle
signature verification passed. Full previous-version Sparkle replacement and
failure recovery remain separately unverified. See
[the validation record](docs/RELEASE_VALIDATION_1.9.13.md).

## 4. Sparkle and publication

After notarized artifacts exist:

1. Generate and independently verify the Sparkle EdDSA signature.
2. Add a new appcast item without editing historical items.
3. Validate the public URL anonymously and compare SHA-256 byte for byte.
4. Install the current stable build in a disposable GUI account or VM.
5. Perform a real Sparkle update, confirm replacement, relaunch, persisted data, and cancellation.
6. Exercise at least one failed download/signature/replacement recovery path.
7. Publish the source release and update release only after every gate is recorded.

## Evidence status in this workspace

- Published public-test baseline: `1.9.12 (202608282037)`, tag `v1.9.12`, commit `ba479345c26edcba63284c103b35350423a2badc`.
- Apple Development signing: available and used for the owner-authorized 1.9.12 public test release; it is not a Developer ID or notarized distribution identity.
- Developer ID Application certificate: unavailable for the owner-authorized 1.9.12 public test release.
- Apple notarization and stapling: not performed for the owner-authorized 1.9.12 public test release.
- 1.9.11 to 1.9.12 Sparkle replacement: `EVIDENCE-INCOMPLETE` until a real public update is exercised.
- Failed-update recovery in an isolated GUI account/VM: `EVIDENCE-INCOMPLETE`.
- Public release/appcast publication: completed for 1.9.12; the five public assets were anonymously verified against their recorded byte lengths and SHA-256 values, and the appcast first item was read back as 1.9.12 / Build `202608282037` / arm64 / macOS 14.
- Next release: use 1.9.13+ with a new commit, tag, build, assets, and appcast item; do not edit or replace any 1.9.12-or-earlier release state.
