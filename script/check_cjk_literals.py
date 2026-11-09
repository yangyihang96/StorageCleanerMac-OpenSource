#!/usr/bin/env python3
"""Fail when app UI code shows a Chinese string literal that bypasses L10n.

D234 (2.0.1 review P2-9): the 2026-10-27 review found Chinese literals given
straight to SwiftUI constructors (`Text("项目产物")`, `Button("选择文件夹")`),
which the English interface showed in Chinese. Every user-visible string goes
through `L10n.text(zh, en)`.

A finding is a string literal containing CJK ideographs that is the first
argument of a SwiftUI text-bearing constructor (Text, Button, Label, Toggle,
Stepper, Link, Menu, Section, Picker, TextField, SecureField, DisclosureGroup,
GroupBox), of a text modifier (.help, .accessibilityLabel, .accessibilityHint,
.accessibilityValue, .navigationTitle, .confirmationDialog, .alert), or the
value assigned to an AppKit text property (prompt, message, messageText,
informativeText, title, placeholderString). `L10n.text("…", "…")` is never a
finding: its first argument is a call, not a literal.

Comments are blanked first. `Sources/StorageCleanerMac/Debug/` (the DEBUG
component gallery and fixtures) is exempt, and a line may opt out with
`// cjk-literal-ok: <reason>`.
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCOPE = ROOT / "Sources" / "StorageCleanerMac"
EXEMPT_DIRECTORIES = ("Sources/StorageCleanerMac/Debug/",)
OPT_OUT = "cjk-literal-ok:"

# Ideographs only: full-width punctuation between interpolations
# ("\\(a)：\\(b)") is a separate wording question, not a missing translation.
CJK = re.compile("[\u3400-\u4dbf\u4e00-\u9fff]")
LITERAL = r'"(?:[^"\\\n]|\\.)*"'
CONSTRUCTORS = ("Text|Button|Label|Toggle|Stepper|Link|Menu|Section|Picker|TextField|SecureField"
                "|DisclosureGroup|GroupBox")
MODIFIERS = "help|accessibilityLabel|accessibilityHint|accessibilityValue|navigationTitle|confirmationDialog|alert"
PROPERTIES = "prompt|message|messageText|informativeText|title|placeholderString"
PATTERNS = (
    re.compile(r"(?<![\w.])(?:" + CONSTRUCTORS + r")\s*\(\s*(" + LITERAL + ")"),
    re.compile(r"\.(?:" + MODIFIERS + r")\s*\(\s*(" + LITERAL + ")"),
    re.compile(r"\.(?:" + PROPERTIES + r")\s*=\s*(" + LITERAL + ")"),
)


def blank_comments(text):
    """Comments become spaces (newlines kept); string literals stay as they are."""
    out = []
    i, n = 0, len(text)
    in_string = False
    while i < n:
        c = text[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"' or c == "\n":
                in_string = False
            i += 1
            continue
        if text.startswith("//", i):
            end = text.find("\n", i)
            end = n if end == -1 else end
            out.append(" " * (end - i))
            i = end
            continue
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = n if end == -1 else end + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:end]))
            i = end
            continue
        if text.startswith('"""', i):
            # Multi-line literals hold long copy, never a constructor's
            # one-line title here; keep them out of the line patterns.
            end = text.find('"""', i + 3)
            end = n if end == -1 else end + 3
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:end]))
            i = end
            continue
        if c == '"':
            in_string = True
        out.append(c)
        i += 1
    return "".join(out)


def findings_for(text):
    """(line number, literal) for each finding in one file's text."""
    raw_lines = text.split("\n")
    result = []
    for number, line in enumerate(blank_comments(text).split("\n"), start=1):
        if OPT_OUT in raw_lines[number - 1]:
            continue
        for pattern in PATTERNS:
            for match in pattern.finditer(line):
                literal = match.group(1)
                if CJK.search(literal):
                    result.append((number, literal))
    return result


def main():
    problems = []
    for path in sorted(SCOPE.rglob("*.swift")):
        relative = path.relative_to(ROOT).as_posix()
        if relative.startswith(EXEMPT_DIRECTORIES):
            continue
        for number, literal in findings_for(path.read_text(encoding="utf-8")):
            problems.append(f"{relative}:{number}: {literal}")
    if problems:
        print("Chinese UI literals must go through L10n.text(zh, en) (D234):", file=sys.stderr)
        for problem in problems:
            print("  " + problem, file=sys.stderr)
        return 1
    print("check_cjk_literals: no Chinese UI literal outside L10n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
