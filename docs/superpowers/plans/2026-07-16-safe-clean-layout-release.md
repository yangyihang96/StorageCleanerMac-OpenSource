# Safe Cleanup Layout, Regression, and Release Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stabilize the safe-clean workspace and scrolling, prove all v1.5.0 features on the installed app without hangs or idle regressions, and publish versioned source/update artifacts with a real 1.4.0-to-1.5.0 Sparkle upgrade.

**Architecture:** The safe-clean page uses a height-bounded top-aligned shell, a compact privacy summary plus separate details sheet, and stable list identity. Validation separates unit/integration proof from real AppKit/Space proof. Release scripts remain authoritative for signing, packaging and metadata; public update assets are verified by downloading and inspecting the exact remote archive before appcast publication.

**Tech Stack:** Swift 6, SwiftUI/AppKit-hosted tests, XCTest, shell release scripts, codesign, Sparkle, Git/GitHub CLI.

---

### Task 1: Reproduce and lock the safe-clean layout failure

**Files:**
- Create: `Sources/StorageCleanerMac/Support/LayoutProbe.swift`
- Create: `Tests/StorageCleanerMacTests/SafeCleanupLayoutTests.swift`
- Modify: `Tests/StorageCleanerMacTests/SystemUtilitySafetyTests.swift`

- [ ] **Step 1: Add a Debug-only frame probe**

```swift
#if DEBUG
struct LayoutFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func layoutProbe(_ id: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: LayoutFramePreferenceKey.self, value: [id: proxy.frame(in: .global)])
        })
    }
}
#endif
```

- [ ] **Step 2: Write AppKit-hosted SwiftUI tests**

Mount the real `ContentView` in an `NSHostingController` inside fixed 980×680, 1160×720 and 1440×900 windows. Inject deterministic empty/scanning/completed/large-privacy-result fixtures. Switch `.green` and `.devCaches` 100 times and assert the workspace top frame stays below the content layout guide/titlebar and within one point of its initial Y.

- [ ] **Step 3: Run and verify the current overflow fails**

Run: `./script/test.sh --filter SafeCleanupLayoutTests`

Expected: the large privacy result fixture pushes the green workspace probe into the titlebar or produces a changing top frame.

- [ ] **Step 4: Commit the regression harness**

```bash
git add Sources/StorageCleanerMac/Support/LayoutProbe.swift Tests/StorageCleanerMacTests/SafeCleanupLayoutTests.swift Tests/StorageCleanerMacTests/SystemUtilitySafetyTests.swift
git commit -m "test(cleanup): reproduce safe page vertical drift"
```

### Task 2: Move detailed privacy results into a sheet

**Files:**
- Modify: `Sources/StorageCleanerMac/Views/PrivacyCleanupView.swift`
- Create: `Sources/StorageCleanerMac/Views/PrivacyCleanupSummaryCard.swift`
- Modify: `Sources/StorageCleanerMac/Views/ContentView.swift:585-609`
- Modify: `Tests/StorageCleanerMacTests/PrivacyCleanupPresentationTests.swift`
- Modify: `Tests/StorageCleanerMacTests/SafeCleanupLayoutTests.swift`

- [ ] **Step 1: Add failing summary/detail behavior tests**

Test that the embedded safe-clean surface contains one compact summary card with safety mode, current state and primary action; grouped browser/profile/domain results render only inside an explicitly opened sheet; closing the sheet does not reset the read-only result or trigger a scan.

- [ ] **Step 2: Run tests and verify the current full inline view fails policy**

Run: `./script/test.sh --filter PrivacyCleanupPresentationTests`

Expected: current `PrivacyCleanupView` is embedded directly and has no summary/detail split.

- [ ] **Step 3: Implement summary-card API**

```swift
struct PrivacyCleanupSummaryCard: View {
    @ObservedObject var store: PrivacyHistoryStore
    @Binding var isShowingDetails: Bool
    let startScan: () -> Void
    let cancelScan: () -> Void
}
```

The card uses a fixed compact vertical structure and never grows with result count. It shows safe-guidance scope, scan state, aggregate count including truncation disclosure, scan/cancel, and “查看详情”. The existing `PrivacyCleanupView` becomes the sheet content and retains browser-native deletion guidance; it still performs no direct browser database deletion.

- [ ] **Step 4: Bound and top-align `ReviewWorkspaceShell`**

Use a top-aligned outer frame and let only the lower content consume remaining height:

```swift
VStack(alignment: .leading, spacing: 0) {
    segmentedPicker
    content
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .layoutPriority(1)
        .clipped()
}
.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
```

In `.green`, place the summary card above one lower `ItemListView`/`ToolPreparationView`; present details with `.sheet`. Do not stack multiple unconstrained `maxHeight: .infinity` children.

- [ ] **Step 5: Run privacy and layout tests**

Run: `./script/test.sh --filter 'PrivacyCleanupPresentationTests|SafeCleanupLayoutTests'`

Expected: compact summary behavior passes and all fixed window sizes keep the workspace below the titlebar.

- [ ] **Step 6: Commit structural fix**

```bash
git add Sources/StorageCleanerMac/Views/PrivacyCleanupView.swift Sources/StorageCleanerMac/Views/PrivacyCleanupSummaryCard.swift Sources/StorageCleanerMac/Views/ContentView.swift Tests/StorageCleanerMacTests/PrivacyCleanupPresentationTests.swift Tests/StorageCleanerMacTests/SafeCleanupLayoutTests.swift
git commit -m "fix(cleanup): keep safe workspace inside window bounds"
```

### Task 3: Preserve list identity and scroll position

**Files:**
- Modify: `Sources/StorageCleanerMac/Views/ItemListView.swift`
- Create: `Sources/StorageCleanerMac/Support/ItemListScrollStateResolver.swift`
- Modify: `Tests/StorageCleanerMacTests/SafeCleanupLayoutTests.swift`

- [ ] **Step 1: Write pure resolver and hosted refresh tests**

```swift
func testRefreshKeepsFirstVisibleExistingItem() {
    let resolved = ItemListScrollStateResolver.resolve(
        previousVisibleID: "b",
        previousIDs: ["a", "b", "c"],
        newIDs: ["a", "b", "c", "d"],
        userChangedFilter: false
    )
    XCTAssertEqual(resolved, "b")
}
```

In the hosted test, scroll the real list to a middle item, publish simulated size/status updates, and assert both the first visible ID and scroll-view identity remain unchanged.

- [ ] **Step 2: Run and verify current whole-list animation/identity fails**

Run: `./script/test.sh --filter SafeCleanupLayoutTests/testRefreshKeepsScrollIdentity`

Expected: current `rawItems.map(\.id)` animation invalidates the whole list.

- [ ] **Step 3: Implement stable selection/scroll rules**

Remove whole-array identity animation. Reuse the existing `ItemListSelectionResolver` for selection and add `ItemListScrollStateResolver` only for the first visible row. Give every row stable `.id(item.id)` and bind the native SwiftUI `scrollPosition`; keep row-local value animation only. Adjust selection/scroll only when the user changes filter/sort/search, the selected/visible item no longer exists, or the list becomes empty. Background size/status refresh cannot call `scrollTo`. The resolver selects the nearest surviving predecessor/successor only when the current item disappeared.

- [ ] **Step 4: Run layout and interaction stress tests**

Run: `./script/test.sh --filter SafeCleanupLayoutTests`

Expected: 100 tab switches, refresh at middle scroll, sidebar toggle, Chinese/English, Reduce Motion and all window sizes pass.

- [ ] **Step 5: Commit scroll stability**

```bash
git add Sources/StorageCleanerMac/Views/ItemListView.swift Sources/StorageCleanerMac/Support/ItemListScrollStateResolver.swift Tests/StorageCleanerMacTests/SafeCleanupLayoutTests.swift
git commit -m "fix(cleanup): preserve review scroll identity"
```

### Task 4: Complete code, concurrency and UI regression

**Files:**
- Modify: `release/发布说明.txt`
- Create: `release/validation/v1.5.0-regression.md`

- [ ] **Step 1: Run focused suites for each subsystem**

Run:

```bash
./script/test.sh --filter MenuBarPanel
./script/test.sh --filter NetworkSpeedTest
./script/test.sh --filter ComputerHealth
./script/test.sh --filter MacBenchmark
./script/test.sh --filter SafeCleanupLayout
./script/test.sh --filter HeavyWorkCoordinator
```

Expected: zero failures; any environment skip is named with reason.

- [ ] **Step 2: Run the complete suite twice**

Run: `./script/test.sh && ./script/test.sh`

Expected: both full runs pass, proving no ordering-dependent shared state.

- [ ] **Step 3: Perform hang and interaction stress**

Run 120 main-window page switches, 100 safe-clean tab switches, 80 compact/advanced panel switches, repeated start/cancel for network and benchmark, and every pairwise heavy-work conflict. A failure is any sustained 100% CPU loop, approximately 20-second unresponsive UI, orphan process/file, leaked lease, or late result replacing a newer generation.

- [ ] **Step 4: Inspect concurrency and hot paths**

Use Time Profiler/signposts to confirm MainActor only publishes UI state, progress is at most 5 Hz, no synchronous external command/file kernel waits on MainActor, and Store roots are not recreated on navigation. Record before/after call stacks for any fixed hang.

- [ ] **Step 5: Write factual release notes and regression evidence**

Release notes must separate fixes, new functions, privacy/traffic warnings, macOS compatibility, signing/notarization status, known limitations, and exact test results. Do not claim Developer ID notarization if the final bundle remains Apple Development signed.

- [ ] **Step 6: Commit regression record**

```bash
git add release/发布说明.txt release/validation/v1.5.0-regression.md
git commit -m "docs: record v1.5.0 regression results"
```

### Task 5: Verify installed UI and idle performance on macOS 26

**Files:**
- Create: `release/validation/v1.5.0-installed-ui.md`
- Create: `release/validation/v1.5.0-performance.md`

- [ ] **Step 1: Build and install a versioned verification bundle**

Run: `APP_VERSION=1.5.0 APP_BUILD=$(date +%Y%m%d%H%M) ./script/build_and_run.sh --verify`

Expected: the built bundle reports `CFBundleShortVersionString=1.5.0`, timestamp build, `com.local.StorageCleanerMac`, `zhHans`, and launches visibly.

- [ ] **Step 2: Verify every visible feature in the installed app**

Open `/Applications/存储清理助手.app`; distinguish its status strip/footer from LemonMonitor and iStat Menus. Verify current-Space panel, compact/advanced selector, all main routes and buttons, network states, health dashboard, benchmark quick/full/cancel, safe-clean sheet/layout, fan RPM, and available CPU frequency/voltage fields. Record disabled controls with their exact precondition rather than treating disabled as broken.

- [ ] **Step 3: Capture final evidence only**

Capture one final screenshot per changed surface plus current-Space proof. Store temporarily under `/tmp/storage-cleaner-v1.5.0-validation`, copy only final selected evidence into `release/validation/final/`, and ensure no Tencent Lemon/iStat window is misidentified.

- [ ] **Step 4: Measure idle and recovery**

With the main window hidden, sample at least 60 seconds and compare to v1.4.0's approximately 1–2% CPU, 85 MB memory and 6 threads. After network/benchmark/health work, verify CPU drops within two seconds and memory/threads plateau without continued growth.

- [ ] **Step 5: Commit installed/performance evidence**

```bash
git add release/validation/v1.5.0-installed-ui.md release/validation/v1.5.0-performance.md release/validation/final
git commit -m "test: validate installed v1.5.0 on macOS 26"
```

### Task 6: Build and inspect versioned release artifacts

**Files:**
- Modify: `script/release_version.env`
- Modify: `release/发布验证报告.txt`
- Create: `release/CHECKSUMS-SHA256-1.5.0.txt`

- [ ] **Step 1: Set exact version/build metadata**

Set `APP_VERSION=1.5.0` and one final timestamp `APP_BUILD`; use the same values for build, DMG, ZIP, release notes and appcast. Do not rebuild after publishing checksums.

- [ ] **Step 2: Run packaging**

Run: `./script/make_release_dmg.sh`

Expected artifacts include `StorageCleanerMac-1.5.0.dmg`, `StorageCleanerMac-1.5.0.zip`, and `CHECKSUMS-SHA256-1.5.0.txt`; no unversioned new installer is published.

- [ ] **Step 3: Inspect the archive contents, not just filenames**

Extract ZIP and mount DMG into temporary directories. Run `plutil`, `codesign --verify --deep --strict --verbose=2`, `spctl` where applicable, Sparkle framework/rpath checks, language/resource checks, and bundle-ID/version/build checks against both copies. Verify the archive app hash matches the staged app.

- [ ] **Step 4: Install the exact staged app and reopen**

Quit every running copy, replace `/Applications/存储清理助手.app` with the staged release app, launch by bundle path, and verify the process executable path plus version/build. Search for duplicate mounted/download/worktree app copies and record them separately; do not delete user copies without scope.

- [ ] **Step 5: Record signing boundary**

If no valid Developer ID/notarization credential is available, record `Apple Development signed; not Developer ID notarized`. Packaging success, local installation, Gatekeeper/public safety and notarization are separate proof states.

- [ ] **Step 6: Commit version metadata and verification report**

```bash
git add script/release_version.env release/发布验证报告.txt release/CHECKSUMS-SHA256-1.5.0.txt
git commit -m "release: prepare storage cleaner v1.5.0"
```

### Task 7: Publish source and public update releases

**Files:**
- Modify in update repository: `appcast.xml`
- Create in update repository: `release-notes-1.5.0.html`

- [ ] **Step 1: Confirm source repository and update repository visibility**

Verify source repo access and keep its existing visibility. Verify `StorageCleanerMacUpdates` is publicly readable because Sparkle uses its raw GitHub appcast URL. Do not point appcast at a private source-repository asset.

- [ ] **Step 2: Push source branch/tag and create source Release**

Push `codex/health-benchmark-v1.5.0`, merge or fast-forward the intended release branch according to existing repository practice, create signed/annotated tag `v1.5.0`, and publish the source GitHub Release with Chinese changelog and the versioned DMG/ZIP/checksum assets.

- [ ] **Step 3: Download source Release assets into a clean temp directory**

Use GitHub's asset URL, compute SHA-256, extract/mount and inspect bundle version/build/signature. This remote download proof must match local checksums before updating Sparkle.

- [ ] **Step 4: Publish update-repository Release and appcast**

Upload `StorageCleanerMac-1.5.0.zip` and release notes to the public update repository. Generate the Sparkle enclosure with exact version/build, length, download URL and EdDSA signature, update `appcast.xml`, commit/push, and verify raw appcast plus enclosure are reachable without login from a clean request.

- [ ] **Step 5: Verify update source is not reported private/unavailable**

From a separate browser/request without GitHub credentials, fetch raw appcast, release notes and ZIP. Confirm HTTP success, correct MIME/length, versioned filename and checksum. The app's diagnostics must report public Sparkle feed availability rather than source-repository privacy.

### Task 8: Perform a real 1.4.0-to-1.5.0 Sparkle update

**Files:**
- Modify: `release/发布验证报告.txt`

- [ ] **Step 1: Prepare a genuine 1.4.0 installed copy**

Use the previously released 1.4.0 archive, verify its internal version/build/signature first, install it in a controlled test path and launch that exact executable. Do not relabel a 1.5.0 build as 1.4.0.

- [ ] **Step 2: Check, download and install through Sparkle**

Trigger “检查更新”, confirm it displays 1.5.0 and the new changelog, download, validate EdDSA/signature, install, replace and relaunch. Record each state separately: feed reachable, update found, downloaded, validated, installed, replaced, relaunched.

- [ ] **Step 3: Verify the relaunched process and bundle**

Confirm process path, `1.5.0`, final build, bundle ID, feed URL and strict codesign. Verify the installed app hash corresponds to the published ZIP payload and no older duplicate copy was opened.

- [ ] **Step 4: Commit final update proof**

```bash
git add release/发布验证报告.txt
git commit -m "docs: verify real update to v1.5.0"
```

### Task 9: Clean development artifacts without touching user files

**Files:**
- Do not modify: `README 2.md`
- Do not modify: `release/发布说明 2.txt`
- Do not modify: `release/发布说明 3.txt`

- [ ] **Step 1: Inventory generated material**

List untracked files, `/tmp/storage-cleaner-*`, benchmark private temporary files, temporary mounted/extracted apps, debug screenshots, `.superpowers` previews, SwiftPM scratch paths created for this release, and current final release artifacts.

- [ ] **Step 2: Delete only verified development artifacts**

Remove temporary screenshots, raw network outputs, benchmark temporary files, extracted/mounted temporary apps, scratch builds and obsolete previews. Keep final versioned DMG/ZIP/checksum/appcast, selected final evidence, validation reports and all protected user files.

- [ ] **Step 3: Verify repository and installed state**

Run `git status --short --branch`, `git ls-files --error-unmatch` for every intended release record, final checksum verification, installed version/build/signature check, and raw appcast fetch. The only untracked files in the main user workspace may be the protected user-owned files already present.

- [ ] **Step 4: Produce the final proof-state handoff**

Report source commit/tag/release, tests, local package, installed app, signing/notarization, public update release, appcast reachability, real old-version update and cleanup as separate states with links and exact versions.
