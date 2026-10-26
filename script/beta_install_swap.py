#!/usr/bin/env python3
"""Atomic moves for `build_and_run.sh --beta --install --no-launch` (D106).

The installed Beta's FanControl helper watches the app's path: when the app
disappears, or comes back with another signer, it treats the app as removed
and hands back the sleep policy it holds. The old install moved the Beta
aside and the new one in with two renames, so for a moment the path did not
exist. These commands never leave such a moment and never replace or delete
anything:

  swap A B          exchanges two directories with renamex_np(RENAME_SWAP):
                    each path names one of the two bundles at every moment
  place SRC DST     moves a directory to a path that must not exist
                    (renamex_np with RENAME_EXCL)
  signer BUNDLE     prints the bundle's code-signing Identifier and
                    TeamIdentifier (codesign -dv); fails for an ad-hoc
                    signature or one without a team
  same-signer A B   both bundles signed by one team with one Identifier
  backup-folder DIR prints the folder for previous Betas with `..` and
                    symbolic links resolved, or refuses one in Applications,
                    a synced folder or /tmp ($HOME's, checked by path and by
                    identity), so no alias reaches them (D106-R5)
  backup-place SRC DST
                    place into a backup folder that is still the checked
                    canonical folder: the move follows no link
  --self-test       fixture directories in a private temporary folder only

Both paths of swap and place must be real directories (not symbolic links)
on the same volume. Symbolic links in the parent folders are resolved first,
and the call itself refuses any link it meets (RENAME_NOFOLLOW_ANY). After a
move the inodes are compared, so a move that did not happen is reported.
Exit status: 0 done, 1 refused or failed, 2 usage.
"""
import contextlib
import ctypes
import os
import pathlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import unicodedata

RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
RENAME_NOFOLLOW_ANY = 0x00000010
CODESIGN = "/usr/bin/codesign"


class Refused(Exception):
    pass


def resolved(path):
    """The absolute path with symbolic links resolved in its parent folders
    only; the last component is checked, never followed."""
    path = os.path.abspath(path)
    return os.path.join(os.path.realpath(os.path.dirname(path)), os.path.basename(path))


def directory(path, role, lstat=os.lstat):
    try:
        info = lstat(path)
    except FileNotFoundError:
        raise Refused(f"{role} does not exist: {path}") from None
    if stat.S_ISLNK(info.st_mode):
        raise Refused(f"{role} is a symbolic link: {path}")
    if not stat.S_ISDIR(info.st_mode):
        raise Refused(f"{role} is not a directory: {path}")
    return info


def inside(path, folder):
    return os.path.commonpath([path, folder]) == folder


def check_swap(first, second, lstat=os.lstat):
    a, b = directory(first, "first path", lstat), directory(second, "second path", lstat)
    if (a.st_dev, a.st_ino) == (b.st_dev, b.st_ino) or first == second:
        raise Refused(f"both paths name the same directory: {first}")
    if inside(first, second) or inside(second, first):
        raise Refused(f"one path is inside the other: {first} {second}")
    if a.st_dev != b.st_dev:
        raise Refused(f"the paths are on different volumes ({a.st_dev} != {b.st_dev}): {first} {second}")
    return a, b


def check_place(source, destination, lstat=os.lstat):
    info = directory(source, "source", lstat)
    try:
        lstat(destination)
        raise Refused(f"destination exists and is never replaced: {destination}")
    except FileNotFoundError:
        pass
    parent = directory(os.path.dirname(destination), "destination folder", lstat)
    if inside(destination, source):
        raise Refused(f"destination is inside the source: {destination}")
    if parent.st_dev != info.st_dev:
        raise Refused(f"the paths are on different volumes ({info.st_dev} != {parent.st_dev}): "
                      f"{source} {destination}")
    return info


def renamex(source, destination, flags):
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renamex_np
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(os.fsencode(source), os.fsencode(destination), flags | RENAME_NOFOLLOW_ANY) != 0:
        error = ctypes.get_errno()
        raise OSError(error, f"renamex_np failed: {os.strerror(error)} (errno {error})", source, None, destination)


def swap(first, second, rename=renamex):
    first, second = resolved(first), resolved(second)
    a, b = check_swap(first, second)
    rename(first, second, RENAME_SWAP)
    now_first, now_second = os.lstat(first), os.lstat(second)
    if (now_first.st_ino, now_second.st_ino) != (b.st_ino, a.st_ino):
        raise Refused(f"the swap could not be confirmed: {first} {second}")
    return first, second


def place(source, destination, rename=renamex, exact=False):
    source = resolved(source)
    if exact:
        destination = os.path.abspath(destination)
        if resolved(destination) != destination:
            raise Refused(f"the destination folder is reached through a symbolic link: {destination}")
    else:
        destination = resolved(destination)
    info = check_place(source, destination)
    rename(source, destination, RENAME_EXCL)
    if os.lstat(destination).st_ino != info.st_ino or os.path.lexists(source):
        raise Refused(f"the move could not be confirmed: {source} -> {destination}")
    return source, destination


# MARK: Backup folder (D106-R5)

def forbidden_folders(home):
    """Where a previous Beta is never kept: Applications, synced folders, /tmp."""
    return ["/Applications", f"{home}/Applications", f"{home}/Documents", f"{home}/Desktop",
            f"{home}/Library/Mobile Documents", f"{home}/Library/CloudStorage", "/tmp", "/private/tmp"]


def canonical(path):
    """The absolute path with `.`, `..` and symbolic links resolved in its
    existing part; the missing rest must be plain names that do not exist,
    not even as a link, so nothing is left to resolve later."""
    if not path.startswith("/"):
        raise Refused(f"not an absolute path: {path}")
    head, rest = path.rstrip("/") or "/", []
    while not os.path.exists(head):
        if os.path.lexists(head):
            raise Refused(f"a symbolic link in the path cannot be followed: {head}")
        name = os.path.basename(head)
        if name in (".", ".."):
            raise Refused(f"the missing part of the path uses {name}: {path}")
        rest.insert(0, name)
        head = os.path.dirname(head)
    real = os.path.realpath(head)
    if not os.path.isdir(real):
        raise Refused(f"not a folder: {head}")
    return os.path.join(real, *rest)


def comparable(path):
    return unicodedata.normalize("NFD", path).casefold()


def backup_folder(path, home):
    """The canonical backup folder, or Refused. Compared by components after
    resolving (case and normalization folded, as APFS compares names) and by
    the identity of every existing parent, which also catches firmlinks."""
    if not home or not home.startswith("/"):
        raise Refused("HOME must be an absolute path")
    folder = canonical(path)
    roots = set()
    for root in forbidden_folders(home):
        roots.add(os.path.normpath(root))
        with contextlib.suppress(Refused):
            roots.add(canonical(root))
    for root in sorted(roots):
        if comparable(folder) == comparable(root) or comparable(folder).startswith(comparable(root) + "/"):
            raise Refused(f"the backup folder {folder} is in {root}: Applications, a synced folder or /tmp")
    identities = {}
    for root in forbidden_folders(home):
        with contextlib.suppress(OSError):
            info = os.stat(root)
            identities[(info.st_dev, info.st_ino)] = root
    parent = folder
    while True:
        with contextlib.suppress(FileNotFoundError):
            info = os.stat(parent)
            if (info.st_dev, info.st_ino) in identities:
                raise Refused(f"the backup folder {folder} is in {identities[(info.st_dev, info.st_ino)]} "
                              "under another name: Applications, a synced folder or /tmp")
        if parent == "/":
            return folder
        parent = os.path.dirname(parent)


def backup_place(source, destination, home, rename=renamex):
    """place() into a backup folder checked again right before the move."""
    folder = os.path.dirname(os.path.abspath(destination))
    if backup_folder(folder, home) != folder:
        raise Refused(f"the backup folder is not the checked canonical folder: {folder}")
    return place(source, destination, rename=rename, exact=True)


def parse_signer(text):
    """(identifier, team) from `codesign -dv` output, or Refused."""
    fields = {}
    adhoc = False
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key in ("Identifier", "TeamIdentifier") and key not in fields:
            fields[key] = value.strip()
        flags = re.search(r"\bflags=0x[0-9a-fA-F]+\(([^)]*)\)", line) if line.startswith("CodeDirectory ") else None
        if line == "Signature=adhoc" or (flags and "adhoc" in flags.group(1).split(",")):
            adhoc = True
    if adhoc:
        raise Refused("the bundle has an ad-hoc signature")
    identifier, team = fields.get("Identifier", ""), fields.get("TeamIdentifier", "")
    if not identifier:
        raise Refused("the bundle has no signing Identifier")
    if not team or team == "not set":
        raise Refused("the bundle's signature names no team")
    return identifier, team


def masked(team):
    """Enough of a Team ID to tell two apart in a log."""
    return team[:3] + "…" if len(team) > 3 else team


def signer(bundle, run=subprocess.run):
    result = run([CODESIGN, "-dv", "--verbose=2", bundle], capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise Refused(f"codesign could not read the signature of {bundle}: {result.stderr.strip()}")
    try:
        return parse_signer(result.stderr + result.stdout)
    except Refused as refused:
        raise Refused(f"{bundle}: {refused}") from None


def same_signer(first, second, run=subprocess.run):
    a, b = signer(first, run), signer(second, run)
    if a != b:
        raise Refused(f"different signers: {first} is {a[0]} (team {masked(a[1])}), "
                      f"{second} is {b[0]} (team {masked(b[1])})")
    return a


def main(arguments):
    try:
        if len(arguments) == 3 and arguments[0] == "swap":
            first, second = swap(arguments[1], arguments[2])
            print(f"swapped atomically: {first} <-> {second}")
        elif len(arguments) == 3 and arguments[0] == "place":
            source, destination = place(arguments[1], arguments[2])
            print(f"moved: {source} -> {destination}")
        elif len(arguments) == 2 and arguments[0] == "signer":
            identifier, team = signer(arguments[1])
            print(f"signer: {identifier} team {masked(team)}")
        elif len(arguments) == 3 and arguments[0] == "same-signer":
            identifier, team = same_signer(arguments[1], arguments[2])
            print(f"same signer: {identifier} team {masked(team)}")
        elif len(arguments) == 2 and arguments[0] == "backup-folder":
            print(backup_folder(arguments[1], os.environ.get("HOME", "")))
        elif len(arguments) == 3 and arguments[0] == "backup-place":
            source, destination = backup_place(arguments[1], arguments[2], os.environ.get("HOME", ""))
            print(f"moved: {source} -> {destination}")
        elif arguments == ["--self-test"]:
            return self_test()
        else:
            print("usage: beta_install_swap.py swap A B | place SRC DST | signer BUNDLE"
                  " | same-signer A B | backup-folder DIR | backup-place SRC DST | --self-test", file=sys.stderr)
            return 2
    except (Refused, OSError) as error:
        print(f"refused: {error}", file=sys.stderr)
        return 1
    return 0


# MARK: Self-test (a private temporary folder only; no real bundle is read)

SIGNED = """Executable=/x/测试版.app/Contents/MacOS/StorageCleanerMacBeta
Identifier=com.local.StorageCleanerMac.beta
Format=app bundle with Mach-O thin (arm64)
CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+1 location=embedded
Signature size=4797
Authority=Example Authority
TeamIdentifier=ABCDE12345
"""
ADHOC = """Identifier=com.local.StorageCleanerMac.beta
CodeDirectory v=20400 size=1 flags=0x2(adhoc) hashes=1+1 location=embedded
Signature=adhoc
TeamIdentifier=not set
"""


def self_test():
    failures = []

    def expect(condition, message):
        if not condition:
            failures.append(message)

    def refused(action):
        try:
            action()
        except Refused as error:
            return str(error)
        return None

    folder = pathlib.Path(tempfile.mkdtemp(prefix="beta-install-swap-self-test-"))
    try:
        first, second = folder / "first.app", folder / "second.app"
        for path in (first, second):
            (path / "Contents").mkdir(parents=True)
            (path / "Contents" / "marker").write_text(path.name)
        inode_first, inode_second = first.stat().st_ino, second.stat().st_ino

        swap(str(first), str(second))
        expect((first / "Contents" / "marker").read_text() == "second.app"
               and (second / "Contents" / "marker").read_text() == "first.app", "swap exchanges the contents")
        expect((first.stat().st_ino, second.stat().st_ino) == (inode_second, inode_first), "swap exchanges inodes")

        # Non-ASCII names, as in 测试版.app.
        named = folder / "测试版.app"
        named.mkdir()
        swap(str(named), str(first))
        expect((named / "Contents" / "marker").read_text() == "second.app", "swap handles non-ASCII paths")

        link = folder / "link.app"
        link.symlink_to(second)
        plain_file = folder / "file.app"
        plain_file.write_text("x")
        nested = second / "Contents" / "nested.app"
        nested.mkdir()
        cases = {
            "missing": (lambda: swap(str(first), str(folder / "missing.app")), "does not exist"),
            "link": (lambda: swap(str(first), str(link)), "symbolic link"),
            "file": (lambda: swap(str(first), str(plain_file)), "not a directory"),
            "same": (lambda: swap(str(first), str(first)), "same directory"),
            "nested": (lambda: swap(str(second), str(nested)), "inside the other"),
        }
        for label, (action, message) in cases.items():
            error = refused(action)
            expect(error is not None and message in error, f"swap {label}: {error}")

        # Different volumes are refused before any rename is attempted.
        real = os.lstat

        def other_volume(path):
            info = real(path)
            if path.endswith("second.app"):
                fields = list(info)
                fields[stat.ST_DEV] = info.st_dev + 1
                return os.stat_result(fields)
            return info

        error = refused(lambda: check_swap(resolved(str(first)), resolved(str(second)), lstat=other_volume))
        expect(error is not None and "different volumes" in error, f"swap volumes: {error}")

        calls = []
        swap_without_rename = (lambda: swap(str(first), str(second), rename=lambda *call: calls.append(call)))
        error = refused(swap_without_rename)
        expect(error is not None and "could not be confirmed" in error and len(calls) == 1,
               f"an unconfirmed swap is reported: {error}")

        moved = folder / "backup" / "测试版.app.previous"
        moved.parent.mkdir()
        inode = first.stat().st_ino
        place(str(first), str(moved))
        expect(not first.exists() and moved.stat().st_ino == inode, "place moves the directory")
        error = refused(lambda: place(str(second), str(moved)))
        expect(error is not None and "never replaced" in error, f"place onto an existing path: {error}")
        error = refused(lambda: place(str(first), str(folder / "elsewhere.app")))
        expect(error is not None and "does not exist" in error, f"place a missing source: {error}")
        error = refused(lambda: place(str(second), str(folder / "no-folder" / "x.app")))
        expect(error is not None and "destination folder does not exist" in error, f"place without folder: {error}")

        expect(parse_signer(SIGNED) == ("com.local.StorageCleanerMac.beta", "ABCDE12345"), "parse a team signature")
        error = refused(lambda: parse_signer(ADHOC))
        expect(error is not None and "ad-hoc" in error, f"ad-hoc: {error}")
        runtime_adhoc = SIGNED.replace("flags=0x10000(runtime)", "flags=0x10002(runtime,adhoc)")
        error = refused(lambda: parse_signer(runtime_adhoc))
        expect(error is not None and "ad-hoc" in error, f"ad-hoc among other flags: {error}")
        error = refused(lambda: parse_signer(SIGNED.replace("TeamIdentifier=ABCDE12345", "TeamIdentifier=not set")))
        expect(error is not None and "no team" in error, f"team not set: {error}")

        def fake_codesign(outputs):
            def run(command, **_):
                return subprocess.CompletedProcess(command, 0, "", outputs[command[-1]])
            return run

        same = fake_codesign({"old": SIGNED, "new": SIGNED})
        expect(same_signer("old", "new", run=same) == ("com.local.StorageCleanerMac.beta", "ABCDE12345"),
               "same signer")
        other_team = fake_codesign({"old": SIGNED, "new": SIGNED.replace("ABCDE12345", "ZZZZZ99999")})
        error = refused(lambda: same_signer("old", "new", run=other_team))
        expect(error is not None and "different signers" in error, f"team mismatch: {error}")
        other_id = fake_codesign({"old": SIGNED, "new": SIGNED.replace(".beta\n", ".other\n", 1)})
        error = refused(lambda: same_signer("old", "new", run=other_id))
        expect(error is not None and "different signers" in error, f"identifier mismatch: {error}")
        unsigned = lambda command, **_: subprocess.CompletedProcess(command, 1, "", "code object is not signed at all")
        error = refused(lambda: signer("old", run=unsigned))
        expect(error is not None and "could not read" in error, f"unsigned: {error}")

        backup_self_test(folder, expect, refused)
    finally:
        shutil.rmtree(folder)

    for failure in failures:
        print(f"self-test failed: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("beta install swap self-test passed")
    return 0


def backup_self_test(folder, expect, refused):
    """D106-R5 on a fake HOME: forbidden folders reached directly, through
    `..` or through a parent link are refused, safe look-alikes are not, and
    the install path refuses before it copies or moves anything."""
    home = folder / "home"
    for name in ("Developer", "Documents", "Desktop", "Applications", "Library/Mobile Documents",
                 "Documents-old", "Developer/real-backups"):
        (home / name).mkdir(parents=True)
    (home / "Developer" / "file.txt").write_text("x")
    links = {"backup-link": home / "Documents", "apps-link": home / "Applications", "tmp-link": pathlib.Path("/tmp"),
             "cloud-link": home / "Library" / "Mobile Documents", "safe-link": home / "Developer" / "real-backups",
             "dangling": home / "nowhere"}
    for name, target in links.items():
        (home / "Developer" / name).symlink_to(target)
    (home / "Developer" / "loop").symlink_to(home / "Developer" / "loop")
    home = str(home)
    real_home = os.path.realpath(home)
    forbidden = {
        "documents": f"{home}/Documents/backups",
        "documents exact": f"{home}/Documents",
        "documents trailing slash": f"{home}/Documents/",
        "documents case": f"{home}/documents/backups",
        "documents dotdot": f"{home}/Developer/../Documents/backups",
        "documents parent link": f"{home}/Developer/backup-link/backups",
        "documents link exact": f"{home}/Developer/backup-link",
        "desktop": f"{home}/Desktop/b",
        "home applications": f"{home}/Applications/b",
        "home applications link": f"{home}/Developer/apps-link/b",
        "applications": "/Applications/StorageCleanerMac-backups",
        "applications exact": "/Applications",
        "applications dotdot": f"{home}/Developer/../../../../../../../../../../../../Applications/b",
        "icloud": f"{home}/Library/Mobile Documents/b",
        "icloud link": f"{home}/Developer/cloud-link/b",
        "cloud storage missing": f"{home}/Library/CloudStorage/GoogleDrive/b",
        "tmp": "/tmp/StorageCleanerMac-backups",
        "tmp exact": "/tmp",
        "private tmp": "/private/tmp/b",
        "tmp dotdot": "/Applications/../tmp/b",
        "tmp link": f"{home}/Developer/tmp-link/b",
        "dotdot in the missing part": f"{home}/Developer/new/../../Documents/b",
        "dangling link": f"{home}/Developer/dangling/b",
        "link loop": f"{home}/Developer/loop/b",
        "file": f"{home}/Developer/file.txt/b",
        "relative": "Developer/backups",
    }
    firmlinked = "/System/Volumes/Data" + real_home + "/Documents"
    if os.path.isdir(firmlinked) and os.stat(firmlinked).st_ino == os.stat(f"{home}/Documents").st_ino:
        forbidden["documents firmlink"] = firmlinked + "/b"
    for label, path in forbidden.items():
        error = refused(lambda: backup_folder(path, home))
        expect(error is not None, f"backup folder {label} must be refused: {path}")
    allowed = {
        "default": (f"{home}/Developer/StorageCleanerMac-beta-backups.noindex",
                    f"{real_home}/Developer/StorageCleanerMac-beta-backups.noindex"),
        "look-alike": (f"{home}/Documents-old/backups", f"{real_home}/Documents-old/backups"),
        "prefix": (f"{home}/DocumentsBackups/b", f"{real_home}/DocumentsBackups/b"),
        "applications look-alike": ("/Applications-StorageCleanerMac-fixture/b", "/Applications-StorageCleanerMac-fixture/b"),
        "safe link": (f"{home}/Developer/safe-link/b", f"{real_home}/Developer/real-backups/b"),
        "dotdot to a safe folder": (f"{home}/Documents/../Developer/b", f"{real_home}/Developer/b"),
    }
    for label, (path, expected) in allowed.items():
        try:
            result = backup_folder(path, home)
        except Refused as error:
            result = f"refused: {error}"
        expect(result == expected, f"backup folder {label}: {result}")

    # backup-place checks the folder again and follows no link.
    source = pathlib.Path(home) / "Applications" / ".测试版.staging.1.app"
    (source / "Contents").mkdir(parents=True)
    stamp = pathlib.Path(real_home) / "Developer" / "real-backups" / "stamp"
    stamp.mkdir()
    for label, destination in {"through a link": f"{home}/Developer/safe-link/stamp/测试版.app.previous",
                               "forbidden": f"{home}/Documents/测试版.app.previous"}.items():
        error = refused(lambda: backup_place(str(source), destination, home))
        expect(error is not None and source.is_dir(), f"backup place {label}: {error}")
    backup_place(str(source), str(stamp / "测试版.app.previous"), home)
    expect(not source.exists() and (stamp / "测试版.app.previous" / "Contents").is_dir(), "backup place moves")

    # The install path checks the folder before anything else: a fake run of
    # build_and_run.sh's function, with every command it would reach faked.
    script = (pathlib.Path(__file__).resolve().parent / "build_and_run.sh").read_text(encoding="utf-8")
    start = script.index("\ninstall_beta_without_launch() {")
    function = script[start:script.index("\n}\n", start) + 3]
    calls = folder / "calls.txt"
    harness = "\n".join([
        "set -euo pipefail",
        f"ROOT_DIR={shlex.quote(str(pathlib.Path(__file__).resolve().parent.parent))}",
        f"APP_BUNDLE={shlex.quote(str(folder / 'missing-new.app'))} BUNDLE_ID=fixture APP_BUILD=0",
        "FAN_HELPER_LABEL=fixture FAN_HELPER_NAME=fixture",
        f"call() {{ printf '%s\\n' \"$*\" >> {shlex.quote(str(calls))}; }}",
        'resolve_beta_install_path() { printf \'%s\\n\' "$HOME/Applications/测试版.app"; }',
        "beta_bundle_activity() { call activity; printf 'fixture activity\\n'; }",
        "refuse_beta_activity() { call refuse; exit 75; }",
        "note_beta_extension() { call note; }",
        f'python3() {{ call "python3 ${{2:-}}"; if [ "${{2:-}}" = backup-folder ]; then {shlex.quote(sys.executable)} -B "$@"; '
        "else return 1; fi; }",
        function,
        'BETA_BACKUP_ROOT="$1"',
        "install_beta_without_launch",
    ])
    tree = lambda: sorted(str(path) for path in pathlib.Path(home).rglob("*"))
    before = tree()
    for label, path, status, expected in [
        ("forbidden dotdot", f"{home}/Developer/../Documents/backups", 1, ["python3 backup-folder"]),
        ("forbidden parent link", f"{home}/Developer/backup-link/backups", 1, ["python3 backup-folder"]),
        ("forbidden tmp", "/tmp/StorageCleanerMac-backups", 1, ["python3 backup-folder"]),
        ("allowed", f"{home}/Developer/backups.noindex", 75, ["python3 backup-folder", "activity", "refuse"]),
    ]:
        with contextlib.suppress(FileNotFoundError):
            calls.unlink()
        run = subprocess.run(["/bin/bash", "-c", harness, "harness", path], capture_output=True, text=True,
                             env={**os.environ, "HOME": home}, check=False)
        seen = calls.read_text().splitlines() if calls.exists() else []
        expect((run.returncode, seen) == (status, expected) and tree() == before,
               f"install path {label}: exit {run.returncode}, calls {seen}, stderr {run.stderr.strip()[-300:]}")


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
