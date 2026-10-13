#!/usr/bin/env python3
"""Fail when production sources reach private Apple API outside the allowlist.

The old verify.sh guard used a single-line grep, so a dlopen() whose path sat
on the next line passed unnoticed. This check reads each file with whitespace
collapsed, so formatting cannot hide a call, and compares every finding with
script/private-api-allowlist.txt. A stale allowlist entry also fails, keeping
the list an accurate inventory.

Findings:
  dlopen   a dlopen() whose target is not a public framework, or is not a
           string literal (the target cannot be checked)
  dlsym    any dlsym() use (how private symbols are reached, even from a
           public framework)
  objc     NSClassFromString() naming a class (dynamic private class use)
  selector any NSSelectorFromString() or Selector("...") use in a file (how
           private methods are reached; helpers often take the name as a
           parameter, so the file is gated and the reason names the methods)
  import   an import of a module whose name ends in "Private"
  link     a linker flag that references PrivateFrameworks
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ALLOWLIST = ROOT / "script" / "private-api-allowlist.txt"
SOURCE_SUFFIXES = {".swift", ".c", ".h", ".m", ".mm"}
CONFLICT_COPY = re.compile(r" \d+\.[A-Za-z]+$")
PUBLIC_FRAMEWORK = re.compile(r"^/System/Library/Frameworks/[^/]+\.framework/")


def findings_for(path: pathlib.Path, text: str):
    flat = re.sub(r"\s+", " ", text)
    rel = path.relative_to(ROOT).as_posix()
    for match in re.finditer(r"\bdlopen\( ?(\"([^\"]*)\"|[^,)]+)", flat):
        literal = match.group(2)
        if literal is None:
            yield ("dlopen", rel, "<non-literal>")
        elif not PUBLIC_FRAMEWORK.match(literal):
            yield ("dlopen", rel, literal)
    if re.search(r"\bdlsym\(", flat):
        yield ("dlsym", rel, "*")
    for match in re.finditer(r"\bNSClassFromString\( ?\"([^\"]+)\"", flat):
        yield ("objc", rel, match.group(1))
    if re.search(r"\bNSSelectorFromString\(|\bSelector\( ?\"", flat):
        yield ("selector", rel, "*")
    for match in re.finditer(r"(?m)^\s*import\s+(?:\w+\s+)?([\w.]*Private\w*)", text):
        yield ("import", rel, match.group(1))


def main() -> int:
    found = set()
    for path in sorted((ROOT / "Sources").rglob("*")):
        if path.suffix not in SOURCE_SUFFIXES or not path.is_file():
            continue
        if CONFLICT_COPY.search(path.name):
            continue  # verify.sh rejects conflict copies separately
        found.update(findings_for(path, path.read_text(encoding="utf-8", errors="replace")))
    package = (ROOT / "Package.swift").read_text(encoding="utf-8")
    if "PrivateFrameworks" in package or re.search(r"-framework\s*\"?,?\s*\"?\w*Private", package):
        found.add(("link", "Package.swift", "PrivateFrameworks"))

    allowed = {}
    for number, line in enumerate(ALLOWLIST.read_text(encoding="utf-8").splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = [part.strip() for part in line.split("|")]
        if len(parts) != 4 or not parts[3]:
            print(f"{ALLOWLIST.name}:{number}: expected kind|file|target|reason", file=sys.stderr)
            return 12
        allowed[tuple(parts[:3])] = parts[3]

    unexpected = sorted(found - allowed.keys())
    stale = sorted(allowed.keys() - found)
    for kind, rel, target in unexpected:
        print(f"private API not in allowlist: {kind} {rel} {target}", file=sys.stderr)
    for kind, rel, target in stale:
        print(f"stale allowlist entry (no longer used): {kind} {rel} {target}", file=sys.stderr)
    if unexpected or stale:
        print("Private API use must be listed with a reason in script/private-api-allowlist.txt.",
              file=sys.stderr)
        return 12
    print(f"private API check passed ({len(found)} allowlisted uses)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
