#!/usr/bin/env python3
"""Checks that one named non-main display exists before anything is shown on
it (DECISIONS D106). Used by script/run_display_bound_tests.sh and
script/launch_beta_acceptance.sh; the app and the test bundle check again
for themselves.

  display_target.py NAME       prints the display and exits 0, or exits 78
                               when no display, or more than one, has exactly
                               this name, or it is the menu-bar display
  display_target.py --self-test

The display list comes from AppKit through JavaScript for Automation: it
reads NSScreen.screens (name and display number) and CGMainDisplayID, and
opens no window and talks to no app. Names compare as the Swift side
compares them: canonically equivalent strings are equal.
"""
import contextlib
import io
import json
import subprocess
import sys
import unicodedata

DISPLAY_UNAVAILABLE = 78
LIST_SCREENS = r"""
ObjC.import('AppKit');
ObjC.import('CoreGraphics');
(() => {
  const screens = $.NSScreen.screens;
  const main = $.CGMainDisplayID();
  const found = [];
  for (let index = 0; index < screens.count; index++) {
    const screen = screens.objectAtIndex(index);
    const number = screen.deviceDescription.objectForKey('NSScreenNumber');
    const id = number.unsignedIntValue;
    found.push({name: ObjC.unwrap(screen.localizedName), id: id, main: id === main || index === 0});
  }
  return JSON.stringify(found);
})();
"""


class Unavailable(Exception):
    pass


def list_screens(run=subprocess.run):
    try:
        result = run(["/usr/bin/osascript", "-l", "JavaScript"], input=LIST_SCREENS,
                     capture_output=True, text=True, timeout=15, check=False)
    except (OSError, subprocess.SubprocessError) as error:
        raise Unavailable(f"the displays could not be read: {error}") from None
    if result.returncode != 0:
        raise Unavailable(f"the displays could not be read: {result.stderr.strip()}")
    try:
        screens = json.loads(result.stdout)
        return [(str(item["name"]), int(item["id"]), bool(item["main"])) for item in screens]
    except (ValueError, KeyError, TypeError) as error:
        raise Unavailable(f"the display list could not be parsed: {error}") from None


def resolve(name, screens):
    """The (name, id) of the target, or Unavailable."""
    if not name:
        raise Unavailable("no display name was given")
    wanted = unicodedata.normalize("NFC", name)
    matches = [screen for screen in screens if unicodedata.normalize("NFC", screen[0]) == wanted]
    if not matches:
        known = ", ".join(f'"{screen[0]}"' for screen in screens) or "none"
        raise Unavailable(f'no display is named "{name}" (displays: {known})')
    if len(matches) > 1:
        raise Unavailable(f'{len(matches)} displays are named "{name}"')
    if matches[0][2]:
        raise Unavailable(f'"{name}" is the menu-bar display')
    return matches[0][0], matches[0][1]


def main(arguments, run=subprocess.run):
    if arguments == ["--self-test"]:
        return self_test()
    if len(arguments) != 1:
        print("usage: display_target.py NAME | --self-test", file=sys.stderr)
        return 2
    try:
        name, number = resolve(arguments[0], list_screens(run))
    except Unavailable as error:
        print(f"display unavailable (exit {DISPLAY_UNAVAILABLE}): {error}", file=sys.stderr)
        return DISPLAY_UNAVAILABLE
    print(f'display {number} "{name}"')
    return 0


def self_test():
    failures = []
    screens = [("Built-in Retina Display", 1, True), ("虚拟屏 1 · Codex", 7, False), ("Studio", 9, False)]

    def unavailable(name, listed):
        try:
            resolve(name, listed)
        except Unavailable as error:
            return str(error)
        return None

    if resolve("虚拟屏 1 · Codex", screens) != ("虚拟屏 1 · Codex", 7):
        failures.append("an exact name resolves")
    decomposed = unicodedata.normalize("NFD", "Café")
    if resolve("Café", [("Built-in", 1, True), (decomposed, 4, False)]) != (decomposed, 4):
        failures.append("canonically equivalent names match")
    cases = {
        "missing": ("虚拟屏 2 · Codex", screens, "no display is named"),
        "partial": ("Codex", screens, "no display is named"),
        "case": ("studio", screens, "no display is named"),
        "main": ("Built-in Retina Display", screens, "menu-bar display"),
        "ambiguous": ("Studio", screens + [("Studio", 11, False)], "2 displays are named"),
        "empty": ("", screens, "no display name"),
        "no displays": ("Studio", [], "displays: none"),
    }
    for label, (name, listed, message) in cases.items():
        error = unavailable(name, listed)
        if error is None or message not in error:
            failures.append(f"{label}: {error}")

    def fake(code, stdout, stderr=""):
        return lambda command, **_: subprocess.CompletedProcess(command, code, stdout, stderr)

    listed = json.dumps([{"name": "Built-in", "id": 1, "main": True}, {"name": "虚拟屏 1 · Codex", "id": 7, "main": False}])
    if list_screens(fake(0, listed)) != [("Built-in", 1, True), ("虚拟屏 1 · Codex", 7, False)]:
        failures.append("the JXA output parses")
    for label, run in {"script error": fake(1, "", "execution error"), "garbage": fake(0, "not json"),
                       "fields": fake(0, '[{"name": "x"}]')}.items():
        try:
            list_screens(run)
            failures.append(f"{label}: accepted")
        except Unavailable:
            pass
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        statuses = (main(["虚拟屏 1 · Codex"], run=fake(0, listed)), main(["Built-in"], run=fake(0, listed)),
                    main(["Built-in"], run=fake(1, "", "error")))
    if statuses != (0, DISPLAY_UNAVAILABLE, DISPLAY_UNAVAILABLE):
        failures.append(f"exit status {statuses}; an unreadable display list must fail closed")

    for failure in failures:
        print(f"self-test failed: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("display target self-test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
