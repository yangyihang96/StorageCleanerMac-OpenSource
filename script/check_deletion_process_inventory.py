#!/usr/bin/env python3
"""Fail when production sources delete, replace, move to the Trash or launch
something that script/deletion-process-inventory.txt does not list.

D98 guards the cleanup flows that move items to the Trash. This inventory
(BOARD L8, DECISIONS D100) lists every other place that deletes a file or
starts a process, with a reason and a review date, so a new one cannot slip
in unreviewed.

Each finding is (kind, file, target), counted per file:
  clone       clonefile and its descriptor-relative variants (D184)
  delete      removeItem; unlink, unlinkat, rmdir, removefile, remove
  rename      rename, renameat, renamex_np, renameatx_np and exchangedata,
              which can replace or swap an existing item; replaceItem and
              replaceItemAt
  trash       trashItem and recycle, the recoverable route
  launch      Process() and Process.run; posix_spawn, posix_spawnp, system,
              popen, fork, vfork and the exec family; openApplication,
              launchApplication and open(_:withApplicationAt:...); the app's
              own runners: Shell.run, Shell.capture, Shell.captureCancellable,
              and run or runSync whose first argument is executable: or
              executableURL:
  script      NSAppleScript, OSAScript, NSUserAppleScriptTask, NSUserUnixTask

A type that starts a process or runs a script counts however its initializer
is spelled: Process(), Process.init(), Foundation.Process.init(),
Process.self.init(), and a declaration that names the type for an implicit
one, such as let task: Process = .init(); these count under the type's name.
  executable  a single-line string literal that starts with a path in /bin,
              /sbin, /usr/bin, /usr/sbin, /usr/libexec, /usr/local/bin or
              /opt/homebrew/bin, or that names a file in a bundle's
              Contents/MacOS: the programs the app names, wherever the name
              is kept

Read from code only, as in check_private_api.py: comments and string
contents are blanked first, and backticks are ignored, so `unlink` reads as
unlink. Swift collections and the app's own types reuse the C library names,
so such a name counts only as C imports it: with no argument labels, called
bare or through a qualifier that is neither a value nor Self nor a type
declared in Sources. Darwin.unlink(path) counts; paths.remove(at:),
Self.remove(x) and SomeError.system(code) do not. Declarations (func, case)
never count. Text, not data flow: function values passed without a call,
aliases, other wrappers and executables assembled at run time are not
followed; the launch entries name the places that start a process, and the
executable entries the programs named in the source.

An entry whose count differs from the source, or that the source no longer
uses, fails too, so the list stays an accurate inventory.
"""
import collections
import pathlib
import re
import sys

from check_private_api import CONFLICT_COPY, ROOT, SOURCE_SUFFIXES, call_arguments, swift_code

INVENTORY = ROOT / "script" / "deletion-process-inventory.txt"
KINDS = ("delete", "rename", "trash", "launch", "script", "executable", "clone")
# Names a Swift collection or a value may also use: only bare or capitalized-qualified calls count.
C_NAMES = {
    "clone": ("clonefile", "clonefileat", "fclonefileat"),
    "delete": ("unlink", "unlinkat", "rmdir", "removefile", "remove"),
    "rename": ("rename", "renameat", "renamex_np", "renameatx_np", "exchangedata"),
    "launch": ("posix_spawn", "posix_spawnp", "system", "popen", "fork", "vfork",
               "execv", "execve", "execvp", "execvP", "execl", "execle", "execlp"),
}
# Names that mean the same thing whatever they are called on.
METHOD_NAMES = {
    "delete": ("removeItem",),
    "rename": ("replaceItem", "replaceItemAt"),
    "trash": ("trashItem", "recycle"),
    "launch": ("Process", "NSTask", "openApplication", "launchApplication"),
    "script": ("NSAppleScript", "OSAScript", "NSUserAppleScriptTask", "NSUserUnixTask"),
}
KIND_OF = {name: kind for table in (C_NAMES, METHOD_NAMES) for kind, names in table.items() for name in names}
C_NAME_SET = {name for names in C_NAMES.values() for name in names}
CALLED_NAME = re.compile(r"\b(" + "|".join(KIND_OF) + r")\s*\(")
QUALIFIER = re.compile(r"([A-Za-z_]\w*)?\s*\.\s*$")
DECLARATION = re.compile(r"\b(?:func|case)\s+$")
TYPE_DECLARATION = re.compile(r"\b(?:enum|struct|class|actor|protocol|typealias)\s+([A-Z]\w*)")
ARGUMENT_LABEL = re.compile(r"\s*[A-Za-z_]\w*\s*:")
PROCESS_RUN = re.compile(r"\bProcess\s*\.\s*(run|launchedProcess)\s*\(")
# Types whose initializer starts a process or runs a script.
INITIALIZED_TYPES = ("Process", "NSTask", "NSAppleScript", "OSAScript", "NSUserAppleScriptTask", "NSUserUnixTask")
# Explicit initializers (Process.init(), Process.self.init()) and an implicit
# one assigned right after the type (let task: Process = .init()). Anything
# else spelled "Process = .init(" counts too: a guard errs towards a finding.
EXPLICIT_INIT = re.compile(r"\b(" + "|".join(INITIALIZED_TYPES) + r")\s*(?:"
                           r"(?:\.\s*self\s*)?\.\s*init\s*\("
                           r"|[?!]?\s*=\s*\.\s*init\s*\()")
SHELL_CALL = re.compile(r"\bShell\s*\.\s*(run|capture|captureCancellable)\s*\(")
RUNNER_CALL = re.compile(r"\b(run|runSync)\s*\(\s*(executable|executableURL)\s*:")
OPEN_CALL = re.compile(r"\bopen\s*\(")
WITH_APPLICATION = re.compile(r"\s*withApplicationAt\s*:")
EXECUTABLE = re.compile(r'"(/(?:usr/(?:s?bin|libexec|local/bin)|s?bin|opt/homebrew/bin)/[^"\\\n]*'
                        r'|[^"\\\n]*\bContents/MacOS/[^"\\\n/]+)(\\?)')
ENTRY_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")


def lexed(text: str) -> str:
    return swift_code(text).replace("`", " ")  # one character for one, so offsets still match `text`


def findings_for(path: pathlib.Path, text: str, types=None) -> collections.Counter:
    """(kind, file, target) -> number of uses in `text`. `types` are the type
    names declared in Sources; by default those declared in `text`."""
    rel = path.relative_to(ROOT).as_posix()
    code = lexed(text)
    if types is None:
        types = set(TYPE_DECLARATION.findall(code))
    found = collections.Counter()

    def prefix(position):
        return code[max(0, position - 80):position]

    for match in CALLED_NAME.finditer(code):
        name, before = match.group(1), prefix(match.start())
        if DECLARATION.search(before):
            continue
        if name in C_NAME_SET:
            qualifier = QUALIFIER.search(before)
            owner = qualifier and qualifier.group(1)
            if qualifier and (not owner or not owner[0].isupper() or owner == "Self" or owner in types):
                continue  # a member of a value or of the app's own type, such as paths.remove(at:)
            if any(ARGUMENT_LABEL.match(code, start, end) for start, end in call_arguments(code, match.end()) or []):
                continue  # C functions take no argument labels: remove(backupID:) is the app's own
        found[(KIND_OF[name], rel, name)] += 1
    for match in PROCESS_RUN.finditer(code):
        found[("launch", rel, "Process." + match.group(1))] += 1
    for match in EXPLICIT_INIT.finditer(code):
        found[(KIND_OF[match.group(1)], rel, match.group(1))] += 1
    for match in SHELL_CALL.finditer(code):
        found[("launch", rel, "Shell." + match.group(1))] += 1
    for match in RUNNER_CALL.finditer(code):
        if not DECLARATION.search(prefix(match.start())):
            found[("launch", rel, f"{match.group(1)}({match.group(2)}:)")] += 1
    for match in OPEN_CALL.finditer(code):
        spans = call_arguments(code, match.end()) or []
        if any(WITH_APPLICATION.match(code, start, end) for start, end in spans):
            found[("launch", rel, "open(withApplicationAt:)")] += 1
    for match in EXECUTABLE.finditer(text):
        if code[match.start()] != '"' or code[match.start() + 1:match.end(1)].strip():
            continue  # not the start of a literal's contents: in a comment, another literal or code
        target = match.group(1) + ("<interpolated>" if match.group(2) else "")
        found[("executable", rel, target)] += 1
    return found


def source_findings() -> collections.Counter:
    texts = {}
    for path in sorted((ROOT / "Sources").rglob("*")):
        if path.suffix not in SOURCE_SUFFIXES or not path.is_file():
            continue
        if CONFLICT_COPY.search(path.name):
            continue  # verify.sh rejects conflict copies separately
        texts[path] = path.read_text(encoding="utf-8", errors="replace")
    types = set()
    for text in texts.values():
        types.update(TYPE_DECLARATION.findall(lexed(text)))
    found = collections.Counter()
    for path, text in texts.items():
        found.update(findings_for(path, text, types))
    return found


def parse_inventory(text: str):
    """(entries, errors): entries map (kind, file, target) to the listed count."""
    entries, errors = {}, []
    for number, line in enumerate(text.splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split("|", 5)]
        if len(parts) != 6 or not all(parts):
            errors.append(f"{number}: expected kind|file|target|count|reviewed|reason")
            continue
        kind, rel, target, count, reviewed, _ = parts
        key = (kind, rel, target)
        if kind not in KINDS:
            errors.append(f"{number}: unknown kind {kind!r}")
        elif not count.isdigit() or int(count) < 1:
            errors.append(f"{number}: count must be a positive number")
        elif not ENTRY_DATE.fullmatch(reviewed):
            errors.append(f"{number}: reviewed must be a date (YYYY-MM-DD)")
        elif key in entries:
            errors.append(f"{number}: duplicate entry {kind} {rel} {target}")
        else:
            entries[key] = int(count)
    return entries, errors


def compare(found, entries):
    """Messages for uses the inventory misses, entries it no longer needs and counts that changed."""
    messages = []
    for key in sorted(found.keys() - entries.keys()):
        messages.append("not in inventory: {} {} {}".format(*key) + f" ({found[key]} uses)")
    for key in sorted(entries.keys() - found.keys()):
        messages.append("stale inventory entry (no longer used): {} {} {}".format(*key))
    for key in sorted(found.keys() & entries.keys()):
        if found[key] > entries[key]:
            messages.append("new use not in inventory: {} {} {}".format(*key)
                            + f" (listed {entries[key]}, found {found[key]})")
        elif found[key] < entries[key]:
            messages.append("stale inventory count: {} {} {}".format(*key)
                            + f" (listed {entries[key]}, found {found[key]})")
    return messages


def main() -> int:
    entries, errors = parse_inventory(INVENTORY.read_text(encoding="utf-8"))
    for error in errors:
        print(f"{INVENTORY.name}:{error}", file=sys.stderr)
    if errors:
        return 16
    found = source_findings()
    messages = compare(found, entries)
    for message in messages:
        print(message, file=sys.stderr)
    if messages:
        print("Deleting, replacing, trashing and launching must be listed with a reason in "
              "script/deletion-process-inventory.txt.", file=sys.stderr)
        return 16
    print(f"deletion and process inventory check passed ({len(found)} entries, {sum(found.values())} uses)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
