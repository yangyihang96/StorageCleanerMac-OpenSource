#!/usr/bin/env python3
"""List and check the XCTest classes that can put a window or system UI on
screen (DECISIONS D106).

script/verify.sh has no display to confine windows to, so it skips these
classes and prints them as NOT RUN. script/run_display_bound_tests.sh runs
the in-process ones with every test window placed on one named non-main
display before it is shown (the test bundle's display gate).

A test file is flagged when its code (comments and string contents blanked,
as in check_private_api.py) uses a window API itself, a shared window host,
or a product entry point that shows a window, a panel, Finder, a URL,
another app, a notification or an authorization prompt. Every XCTestCase
class declared in a flagged file, or extended there, is display-bound. Only
files directly in the test folder are read; a class declared under Fixtures
still counts as an XCTest class when a flagged file extends it.

script/display-bound-tests.txt lists each display-bound class once:
  in-process      skipped by verify.sh, run by run_display_bound_tests.sh
  out-of-process  skipped by verify.sh and never run by the display runner:
                  it launches another app, which the gate cannot place
  exempt          runs in verify.sh: it is detected, but shows nothing
                  (the reason must say why)
--check fails (exit 17, as verify.sh reports it) when a detected class is
not listed, or a listed class is no longer detected or no longer exists, so
the list cannot drift. The regex and count modes refuse a drifted list too.

verify.sh runs one `swift test` per test target (D106 supplement 2): given
several targets, swift test hands every test bundle one list naming the tests
of all of them, XCTest cannot find another target's classes by name and then
lists every class in the process (objc_copyClassList), and realizing
ContactsUICore's classes initializes CNContactStore, which tries to open the
user's address book. --test-targets names the targets Package.swift declares.

Usage:
  display_bound_tests.py [--check]      check the list against the tests
  display_bound_tests.py --test-targets the package's test targets, one a line
  display_bound_tests.py --skip-regex   regex for `swift test --skip`
  display_bound_tests.py --filter-regex [CLASSES]
                                        regex for `swift test --filter`: the
                                        in-process classes, or those whose
                                        names fully match the CLASSES regex
                                        (any other match is refused)
  display_bound_tests.py --count KIND   in-process, out-of-process, exempt
                                        or skipped (the first two together)
  display_bound_tests.py --self-test    checks this script on a fixture tree
"""
import pathlib
import re
import shutil
import sys
import tempfile

from check_private_api import ROOT, swift_code

TEST_TARGET = "StorageCleanerMacTests"
TEST_DIR = pathlib.Path("Tests") / TEST_TARGET
LIST = pathlib.Path("script") / "display-bound-tests.txt"
KINDS = ("in-process", "out-of-process", "exempt")
DRIFT = 17

DIRECT = re.compile(
    r"\bNSWindow\s*\(|\bNSPanel\s*\(|\borderFront\w*\s*\(|\bmakeKeyAndOrderFront\s*\(|\borderWindow\s*\(|"
    r"\bNSOpenPanel\s*\(|\bNSSavePanel\s*\(|\bNSAlert\s*\(|\brunModal\w*\s*\(|\bstatusItem\s*\(|\bNSPopover\s*\(|"
    r"\bbeginSheet\w*\s*\(|\bshowWindow\s*\(|\bNSWindowController\s*\(|\bsetIsVisible\s*\(|\.isVisible\s*=\s*true|"
    r"activateFileViewerSelecting|NSWorkspace\.shared\.(open|openApplication|launch\w*|selectFile|recycle)\b|"
    r"\bopenApplication\s*\(|"
    r"UNUserNotificationCenter|NSUserNotification|requestAuthorization|AXIsProcessTrustedWithOptions|"
    r"CGRequestScreenCaptureAccess|"
    r"\.register\s*\(\s*\)|NSApp\.activate|NSApplication\.shared\.activate|"
    r"NSRunningApplication\b[^\n]*\.activate\s*\(|NSSharingService")
# Types and methods of the app that show UI when a test drives them.
ENTRY_TYPES = (
    "CalibrationAppKitLayoutHost", "V0LayoutHost", "ControlPaletteCoordinator", "MenuBarPanelSession",
    "AppOpenPanelCoordinator", "MainWindowSnapshotPipeline", "WindowMotionDemo", "AppUpdatePasswordPrompt",
    "AppUpdateBatchAuthorization", "RelaunchPostponedNotice", "AppInstallationConflictController",
    "PrivacySystemSettingsOpener", "ComputerHealthSystemActions", "WorkspaceBatterySettingsOpener",
    "NSWorkspaceBrowserLauncher", "NSWorkspaceVPNControlApplicationOpener", "ApplicationUpdateNotificationService",
    "PhotoKitLibraryProvider", "ProjectArtifactController", "ExternalUninstallRequestCenter", "MainWindowReopenBridge",
    "AppDelegate")
ENTRY_METHODS = (
    "requestRequiredFolderAccess", "openLatestV2CleanupLocation", "revealStartupCandidate",
    "openParentApplication", "revealDeniedUninstallAppInFinder", "searchCandidateOfficialWebsite", "exportReport",
    "exportMaintenanceChecklist", "openTrashFolder", "openStorageSettings", "openLoginItemsSettings",
    "openFullDiskAccessSettings", "openFilesAndFoldersSettings", "openAppManagementSettings", "openSecuritySettings",
    "openUpdateEntry", "relaunch", "requestNotificationAccess", "openNotificationSettings",
    "setLaunchAtLogin", "addExclusion", "prepareHelper")
# Generic names count only together with the type that shows UI.
PAIRED = (
    (re.compile(r"\.install\s*\(\s*store\s*:"), None),
    (re.compile(r"\.show\s*\(\s*anchor\s*:"), None),
    (re.compile(r"\bCleanupService\.reveal\s*\("), None),
    (re.compile(r"\.reveal\s*\("), "ExternalDriveMigrationService"),
    (re.compile(r"\.authorize\s*\("), "PhotoLibraryStore"),
    (re.compile(r"\bAuthorizedApplicationMover\s*\("), None))
TYPE_USE = re.compile(r"\b(" + "|".join(ENTRY_TYPES) + r")\b")
METHOD_CALL = re.compile(r"\.(" + "|".join(ENTRY_METHODS) + r")\s*\(")
XCTEST_CLASS = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:final|public|internal|private|fileprivate|open|nonisolated)\s+)*"
    r"class\s+(\w+)\s*:\s*[^{]*\bXCTestCase\b", re.M)
EXTENSION = re.compile(
    r"^\s*(?:@\w+\s+)*(?:(?:private|fileprivate|public|internal)\s+)*extension\s+(\w+)\b[^{]*\{", re.M)


def read(path):
    return path.read_text(encoding="utf-8", errors="replace")


def xctest_classes(root):
    """Every XCTestCase subclass declared anywhere under the test folder."""
    classes = set()
    for path in sorted((root / TEST_DIR).rglob("*.swift")):
        classes.update(XCTEST_CLASS.findall(swift_code(read(path))))
    return classes


def scan(root):
    """(flagged files: name -> (reasons, classes), all XCTest classes)."""
    known = xctest_classes(root)
    flagged = {}
    for path in sorted((root / TEST_DIR).glob("*.swift")):
        code = swift_code(read(path))
        reasons = {match.group(0).strip() for match in DIRECT.finditer(code)}
        reasons |= set(TYPE_USE.findall(code))
        reasons |= {"." + name for name in METHOD_CALL.findall(code)}
        for pattern, needs in PAIRED:
            if pattern.search(code) and (needs is None or needs in code):
                reasons.add(pattern.pattern if needs is None else f"{needs} + {pattern.pattern}")
        if not reasons:
            continue
        classes = set(XCTEST_CLASS.findall(code)) | {name for name in EXTENSION.findall(code) if name in known}
        flagged[path.name] = (sorted(reasons), sorted(classes))
    return flagged, known


def detected_classes(flagged):
    return {name for _, classes in flagged.values() for name in classes}


def parse_list(text):
    """({class: kind}, problems)."""
    entries, problems = {}, []
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split("|")]
        if len(parts) != 3 or not all(parts):
            problems.append(f"{LIST.name}:{number}: expected Class | kind | reason")
            continue
        name, kind, _ = parts
        if not re.fullmatch(r"\w+", name):
            problems.append(f"{LIST.name}:{number}: not a class name: {name}")
        elif kind not in KINDS:
            problems.append(f"{LIST.name}:{number}: unknown kind '{kind}' (use {', '.join(KINDS)})")
        elif name in entries:
            problems.append(f"{LIST.name}:{number}: {name} is listed twice")
        else:
            entries[name] = kind
    return entries, problems


def check(root):
    """(entries, problems) for the list against the test sources."""
    flagged, known = scan(root)
    entries, problems = parse_list(read(root / LIST))
    detected = detected_classes(flagged)
    for name in sorted(detected - entries.keys()):
        files = sorted(file for file, (_, classes) in flagged.items() if name in classes)
        problems.append(f"display-bound class not listed: {name} ({', '.join(files)})")
    for name in sorted(entries.keys() - detected):
        if name in known:
            problems.append(f"listed class is no longer display-bound: {name} ({entries[name]})")
        else:
            problems.append(f"listed class does not exist in {TEST_DIR}: {name} ({entries[name]})")
    return entries, problems


def classes_of(entries, *kinds):
    return sorted(name for name, kind in entries.items() if kind in kinds)


def class_regex(names):
    """Matches every test of these classes and nothing else; SwiftPM names an
    XCTest test StorageCleanerMacTests.Class/testMethod."""
    if not names:
        raise ValueError("no classes")
    return rf"^{TEST_TARGET}\.(?:" + "|".join(names) + ")/"


def test_targets(root):
    """The test targets Package.swift declares, in its order."""
    text = (root / "Package.swift").read_text(encoding="utf-8")
    return re.findall(r'\.testTarget\(\s*name:\s*"([^"]+)"', text)


def run(arguments, root, out=sys.stdout, err=sys.stderr):
    mode = arguments[0] if arguments else "--check"
    if mode == "--test-targets" and len(arguments) == 1:
        names = test_targets(root)
        if not names:
            print("Package.swift declares no test target", file=err)
            return 1
        print("\n".join(names), file=out)
        return 0
    entries, problems = check(root)
    if mode == "--check" and len(arguments) <= 1:
        for problem in problems:
            print(problem, file=err)
        if problems:
            print("Every display-bound test class must be listed with a kind and a reason in "
                  f"{LIST} (DECISIONS D106).", file=err)
            return DRIFT
        print(f"display-bound test check passed ({len(classes_of(entries, 'in-process'))} in-process, "
              f"{len(classes_of(entries, 'out-of-process'))} out-of-process, "
              f"{len(classes_of(entries, 'exempt'))} exempt)", file=out)
        return 0
    if mode in ("--skip-regex", "--filter-regex", "--count") and problems:
        # A regex from a drifted list could let a window test run unconfined.
        for problem in problems:
            print(problem, file=err)
        print(f"{LIST} does not match the tests; run --check.", file=err)
        return DRIFT
    if mode == "--skip-regex" and len(arguments) == 1:
        names = classes_of(entries, "in-process", "out-of-process")
        if not names:
            print("no class is listed as in-process or out-of-process", file=err)
            return 1
        print(class_regex(names), file=out)
        return 0
    if mode == "--filter-regex" and len(arguments) in (1, 2):
        names = classes_of(entries, "in-process")
        if len(arguments) == 2:
            try:
                pattern = re.compile(arguments[1])
            except re.error as error:
                print(f"--filter-regex: not a regex: {error}", file=err)
                return 2
            chosen = sorted(name for name in entries if pattern.fullmatch(name))
            others = [name for name in chosen if entries[name] != "in-process"]
            if others:
                print(f"--filter-regex selects classes that are not in-process: {', '.join(others)}", file=err)
                return 1
            if not chosen:
                print(f"--filter-regex: no in-process class matches {arguments[1]}", file=err)
                return 1
            names = chosen
        if not names:
            print("no class is listed as in-process", file=err)
            return 1
        print(class_regex(names), file=out)
        return 0
    if mode == "--count" and len(arguments) == 2:
        kinds = {"skipped": ("in-process", "out-of-process")}.get(arguments[1], (arguments[1],))
        if not set(kinds) <= set(KINDS):
            print(f"--count takes {', '.join(KINDS)} or skipped", file=err)
            return 2
        print(len(classes_of(entries, *kinds)), file=out)
        return 0
    print(__doc__.split("Usage:")[1].rstrip(), file=err)
    return 2


# MARK: Self-test (a fixture tree in a private temporary folder only)

FIXTURE_FILES = {
    "WindowTests.swift": """
import AppKit
import XCTest
@MainActor
final class WindowTests: XCTestCase {
    func testWindow() { _ = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true) }
}
final class SecondWindowTests: XCTestCase {}
""",
    "QuietTests.swift": """
import XCTest
// NSWindow( in a comment, /* NSAlert( */ in a block comment
final class QuietTests: XCTestCase {
    func testText() { XCTAssertEqual("NSWindow(", "NSWindow(") }
    func testRaw() { _ = #"orderFront( "NSPanel(" "#; _ = \"\"\"
    makeKeyAndOrderFront(
    \"\"\" }
}
""",
    "QuietExtensionTests.swift": """
import AppKit
extension QuietTests {
    func helper() { _ = NSAlert() }
}
extension String {}
""",
    "HostTests.swift": """
import XCTest
final class HostTests: XCTestCase {
    func testHost() { _ = CalibrationAppKitLayoutHost.self }
}
""",
    "PairedTests.swift": """
import XCTest
final class PairedOnlyNameTests: XCTestCase {
    func testReveal() { model.reveal(item) }
}
""",
    "PairedTypeTests.swift": """
import XCTest
final class PairedTypeTests: XCTestCase {
    func testReveal() { ExternalDriveMigrationService().reveal(item) }
}
""",
    "LauncherTests.swift": """
import AppKit
import XCTest
final class LauncherTests: XCTestCase {
    func testLaunch() { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
}
""",
    "GateOwnTests.swift": """
import XCTest
final class GateOwnTests: XCTestCase {
    func testHidden() { let window = NSPanel(); window.orderFront(nil) }
}
""",
}
FIXTURE_NESTED = {
    "Fixtures/FixtureHostTests.swift": """
import AppKit
final class FixtureOnlyTests: XCTestCase { func testA() { _ = NSWindow() } }
""",
}
FIXTURE_LIST = """# fixture
WindowTests | in-process | NSWindow
SecondWindowTests | in-process | same file as WindowTests
QuietTests | in-process | NSAlert through an extension in another file
HostTests | in-process | CalibrationAppKitLayoutHost
PairedTypeTests | in-process | ExternalDriveMigrationService.reveal
LauncherTests | out-of-process | opens another app
GateOwnTests | exempt | hidden windows only
"""


def self_test():
    failures = []

    def expect(condition, message):
        if not condition:
            failures.append(message)

    fixture = pathlib.Path(tempfile.mkdtemp(prefix="display-bound-self-test-"))
    try:
        tests = fixture / TEST_DIR
        (tests / "Fixtures").mkdir(parents=True)
        (fixture / "script").mkdir()
        for name, text in {**FIXTURE_FILES, **FIXTURE_NESTED}.items():
            (tests / name).write_text(text, encoding="utf-8")
        list_path = fixture / LIST
        list_path.write_text(FIXTURE_LIST, encoding="utf-8")

        flagged, known = scan(fixture)
        expect(detected_classes(flagged) == {"WindowTests", "SecondWindowTests", "QuietTests", "HostTests",
                                             "PairedTypeTests", "LauncherTests", "GateOwnTests"},
               f"detected {sorted(detected_classes(flagged))}")
        expect("QuietTests.swift" not in flagged, "comments and strings must not flag a file")
        expect("PairedTests.swift" not in flagged, ".reveal( counts only with its type")
        expect("FixtureOnlyTests" in known and "FixtureHostTests.swift" not in flagged
               and "FixtureOnlyTests" not in detected_classes(flagged),
               "Fixtures declare classes but are not scanned for UI")

        def outcome(*arguments):
            out, err = _Capture(), _Capture()
            return run(list(arguments), fixture, out, err), out.text, err.text

        code, out, err = outcome("--check")
        expect(code == 0 and "5 in-process, 1 out-of-process, 1 exempt" in out, f"clean check: {code} {out} {err}")
        code, out, _ = outcome("--skip-regex")
        skip = out.strip()
        expect(code == 0 and skip == r"^StorageCleanerMacTests\.(?:HostTests|LauncherTests|PairedTypeTests|"
               r"QuietTests|SecondWindowTests|WindowTests)/", f"skip regex: {skip}")
        code, out, _ = outcome("--filter-regex")
        only = out.strip()
        expect(code == 0 and "LauncherTests" not in only and "GateOwnTests" not in only, f"filter regex: {only}")
        expect(re.search(skip, "StorageCleanerMacTests.WindowTests/testWindow") is not None, "skip matches a test")
        expect(re.search(skip, "StorageCleanerMacTests.WindowTestsExtra/testWindow") is None, "no prefix match")
        expect(re.search(skip, "StorageCleanerMacTests.GateOwnTests/testHidden") is None, "exempt runs")
        expect(re.search(skip, "OtherTarget.WindowTests/testWindow") is None, "other targets are not matched")
        code, out, _ = outcome("--filter-regex", "Window.*|Host.*")
        expect(code == 0 and out.strip() == r"^StorageCleanerMacTests\.(?:HostTests|WindowTests)/", f"subset: {out}")
        expect(outcome("--filter-regex", "Launcher.*|Window.*")[0] == 1, "a subset never selects out-of-process")
        expect(outcome("--filter-regex", "GateOwnTests")[0] == 1, "a subset never selects exempt classes")
        expect(outcome("--filter-regex", "Nothing.*")[0] == 1, "an empty subset is refused")
        expect(outcome("--filter-regex", "(")[0] == 2, "an invalid subset regex is refused")
        (fixture / "Package.swift").write_text(
            'targets: [\n    .target(name: "App"),\n    .testTarget(\n        name: "OtherTargetTests",\n'
            '        dependencies: ["App"]),\n    .testTarget(name: "StorageCleanerMacTests", dependencies: ["App"]),\n]\n',
            encoding="utf-8")
        code, out, _ = outcome("--test-targets")
        expect(code == 0 and out.split() == ["OtherTargetTests", "StorageCleanerMacTests"], f"test targets: {out}")
        (fixture / "Package.swift").write_text('targets: [.target(name: "App")]\n', encoding="utf-8")
        expect(outcome("--test-targets")[0] == 1, "a package without test targets is refused")
        expect(outcome("--count", "skipped")[1].strip() == "6", "count skipped")
        expect(outcome("--count", "exempt")[1].strip() == "1", "count exempt")
        expect(outcome("--count", "bogus")[0] == 2, "count rejects an unknown kind")

        drifted = {
            "unlisted": (FIXTURE_LIST.replace("HostTests | in-process | CalibrationAppKitLayoutHost\n", ""),
                         "display-bound class not listed: HostTests"),
            "stale": (FIXTURE_LIST + "QuietExtensionlessTests | in-process | gone\n",
                      "does not exist in Tests/StorageCleanerMacTests: QuietExtensionlessTests"),
            "duplicate": (FIXTURE_LIST + "WindowTests | exempt | again\n", "WindowTests is listed twice"),
            "kind": (FIXTURE_LIST.replace("GateOwnTests | exempt", "GateOwnTests | skipped"), "unknown kind"),
            "reason": (FIXTURE_LIST.replace("| hidden windows only", "|"), "expected Class | kind | reason"),
        }
        for label, (text, message) in drifted.items():
            list_path.write_text(text, encoding="utf-8")
            code, _, err = outcome("--check")
            expect(code == DRIFT and message in err, f"{label}: {code} {err}")
            code, out, _ = outcome("--skip-regex")
            expect(code == DRIFT and not out, f"{label}: a drifted list must not yield a skip regex")

        # A class that stops being display-bound is stale too.
        list_path.write_text(FIXTURE_LIST + "PairedOnlyNameTests | in-process | no longer flagged\n", encoding="utf-8")
        code, _, err = outcome("--check")
        expect(code == DRIFT and "no longer display-bound: PairedOnlyNameTests" in err, f"no longer flagged: {err}")
    finally:
        shutil.rmtree(fixture)

    for failure in failures:
        print(f"self-test failed: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("display-bound self-test passed")
    return 0


class _Capture:
    def __init__(self):
        self.text = ""

    def write(self, text):
        self.text += text

    def flush(self):
        pass


if __name__ == "__main__":
    if sys.argv[1:] == ["--self-test"]:
        sys.exit(self_test())
    sys.exit(run(sys.argv[1:], ROOT))
