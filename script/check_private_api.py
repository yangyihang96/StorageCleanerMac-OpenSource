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
  kvc      a key-value-coding call (value, setValue or mutable*Value with a
           forKey:/forKeyPath: argument) and its key: how a property the SDK
           does not declare is read, such as NSXPCConnection.auditToken. Read
           from code only: comments and string contents are blanked first, as
           in Tests/StorageCleanerMacTests/SwiftSourceScanning.swift. A key
           that is not one plain or raw string literal without escapes or
           interpolation is <non-literal>; a call whose arguments never close
           is <unparsed>
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
KVC_CALL = re.compile(r"\b(?:value|setValue|mutableArrayValue|mutableOrderedSetValue|mutableSetValue)\s*\(")
KVC_KEY_LABEL = re.compile(r"\s*forKey(?:Path)?\s*:")
# In lexed code a literal's contents are blank, so any other text is code.
LEXED_LITERAL = re.compile(r'\s*(#*)"( *)"\1\s*')


def swift_code(text: str) -> str:
    """Comments and the contents of string literals replaced by spaces, line
    breaks, delimiters and interpolated code kept, so every index still
    points at the same place in `text`. Mirrors SwiftSourceScanning.code."""
    out, stack, index, length = list(text), [("code", 0)], 0, len(text)

    def blank(start, end):
        for position in range(max(start, 0), min(end, length)):
            if text[position] != "\n":
                out[position] = " "

    while index < length:
        char, mode = text[index], stack[-1]
        if mode[0] != "string":
            if text.startswith("//", index):
                end = text.find("\n", index)
                end = length if end < 0 else end
                blank(index, end)
                index = end
            elif text.startswith("/*", index):
                depth, end = 0, index
                while True:
                    if text.startswith("/*", end):
                        depth, end = depth + 1, end + 2
                    elif text.startswith("*/", end):
                        depth, end = depth - 1, end + 2
                    else:
                        end += 1
                    if depth <= 0 or end >= length:
                        break
                blank(index, end)
                index = end
            elif char in '#"':
                quote = index
                while quote < length and text[quote] == "#":
                    quote += 1
                if quote >= length or text[quote] != '"':
                    index = max(quote, index + 1)
                    continue
                multiline = text.startswith('"""', quote)
                stack.append(("string", quote - index, multiline))
                index = quote + (3 if multiline else 1)
            else:
                if mode[0] == "interpolation":
                    if char == "(":
                        stack[-1] = ("interpolation", mode[1] + 1)
                    elif char == ")":
                        if mode[1] == 0:
                            stack.pop()
                        else:
                            stack[-1] = ("interpolation", mode[1] - 1)
                index += 1
        else:
            _, hashes, multiline = mode
            closing = ('"""' if multiline else '"') + "#" * hashes
            if text.startswith(closing, index):
                stack.pop()
                index += len(closing)
            elif char == "\\" and text.startswith("#" * hashes, index + 1):
                escaped = index + 1 + hashes
                if escaped < length and text[escaped] == "(":
                    stack.append(("interpolation", 0))
                else:
                    blank(index, escaped + 1)
                index = escaped + 1
            elif not multiline and char == "\n":
                stack.pop()  # An unterminated literal never swallows the rest of the file.
            else:
                blank(index, index + 1)
                index += 1
    return "".join(out)


def call_arguments(code: str, start: int):
    """(start, end) of each top-level argument of the call whose "(" ends just
    before `start`, or None when the call never closes. `code` is lexed, so
    every bracket and comma left in it is code."""
    spans, depth, current = [], 0, start
    for index in range(start, len(code)):
        char = code[index]
        if char in "([{":
            depth += 1
        elif char in ")]}":
            if depth == 0:
                spans.append((current, index))
                return spans
            depth -= 1
        elif char == "," and depth == 0:
            spans.append((current, index))
            current = index + 1
    return None


def kvc_keys(text: str):
    if "forKey" not in text:  # every key argument is labelled; skip lexing other files
        return
    code = swift_code(text)
    for call in KVC_CALL.finditer(code):
        spans = call_arguments(code, call.end())
        if spans is None:
            yield "<unparsed>"
            continue
        for start, end in spans:
            label = KVC_KEY_LABEL.match(code, start, end)
            if not label:
                continue
            literal = LEXED_LITERAL.fullmatch(code, label.end(), end)
            key = text[literal.start(2):literal.end(2)] if literal else None
            yield key if key is not None and "\\" not in key else "<non-literal>"


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
    for key in kvc_keys(text):
        yield ("kvc", rel, key)


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
