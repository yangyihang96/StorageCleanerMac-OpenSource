#!/usr/bin/env python3
"""Checks the display gate's JSON-lines log after a display-bound test run
(script/run_display_bound_tests.sh, DECISIONS D106). The log is the only
evidence that the test process confined its windows to the named display, so
it fails closed (D106-R4):

  display_gate_log.py --check LOG --display NAME [--not-before EPOCH]
      exit 0 only when the log is complete JSON lines, the first and only
      `installed` record confines to exactly NAME and was written by this
      run (not before EPOCH), every other record is a well-formed `placed`
      or `moved` with its entry, window and both frames, and nothing was
      refused, a violation or refused outside UI. Exit 1 otherwise, 2 usage.
  display_gate_log.py --self-test

A missing, empty or blank log, a cut-off last line, an unknown kind or a
gate in another mode or for another display is never read as a pass. A run
whose tests ordered no window passes with the evidence level "installed
only": the gate was confined and nothing was placed, so no placement is
claimed. Display names compare as the Swift side compares them: canonically
equivalent strings are equal.
"""
import collections
import contextlib
import datetime
import io
import json
import math
import os
import pathlib
import re
import sys
import tempfile
import unicodedata

KINDS = {"installed", "placed", "moved", "refused", "violation", "externalRefused"}
FAILING = {"refused", "violation", "externalRefused"}
# TestDisplayGateBootstrap: "\(gateMode) in \(process.processName) \(pid)".
INSTALLED = re.compile(r'confine\(displayName: "((?:[^"\\]|\\.)*)"\) in (\S+) ([1-9][0-9]*)')


class Invalid(Exception):
    pass


def same_name(first, second):
    return unicodedata.normalize("NFC", first) == unicodedata.normalize("NFC", second)


def unescaped(text):
    """The display name as Swift's description of the mode quotes it."""
    return re.sub(r"\\(.)", r"\1", text)


def timestamp(event, line):
    value = event.get("time")
    if not isinstance(value, str) or not value:
        raise Invalid(f"line {line}: no time")
    try:
        moment = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise Invalid(f"line {line}: unreadable time {value!r}") from None
    if moment.tzinfo is None:
        raise Invalid(f"line {line}: time without a zone {value!r}")
    return moment.timestamp()


def frame(event, key, line):
    value = event.get(key)
    if (not isinstance(value, list) or len(value) != 4
            or not all(isinstance(number, (int, float)) and not isinstance(number, bool) and math.isfinite(number)
                       for number in value)):
        raise Invalid(f"line {line}: {event['kind']} needs {key} as four numbers")


def check(text, display, not_before=None):
    """(counts, evidence) for a valid log, or Invalid with every problem."""
    if not text.strip():
        raise Invalid("the gate log is empty: the display gate recorded nothing, so placement is unproven")
    if not text.endswith("\n"):
        raise Invalid("the last line is cut off: the log is incomplete")
    problems, counts, installed = [], collections.Counter(), []
    for line, raw in enumerate(text[:-1].split("\n"), start=1):
        try:
            if not raw.strip():
                raise Invalid(f"line {line}: blank line")
            try:
                event = json.loads(raw)
            except ValueError:
                raise Invalid(f"line {line}: not JSON: {raw.strip()[:120]}") from None
            if not isinstance(event, dict):
                raise Invalid(f"line {line}: not a JSON object")
            kind = event.get("kind")
            if kind not in KINDS:
                raise Invalid(f"line {line}: not a gate event: kind {kind!r}")
            counts[kind] += 1
            if kind in FAILING:
                raise Invalid(f"line {line}: {kind}: {event.get('entry')} {event.get('window')} {event.get('detail', '')}")
            moment = timestamp(event, line)
            if kind == "installed":
                installed.append(line)
                match = INSTALLED.fullmatch(event.get("detail") or "")
                if line != 1:
                    raise Invalid(f"line {line}: installed is not the first record")
                if not match:
                    raise Invalid(f"line {line}: the gate did not confine to one display: {event.get('detail')!r}")
                if not same_name(unescaped(match.group(1)), display):
                    raise Invalid(f"line {line}: the gate confined to {unescaped(match.group(1))!r}, not {display!r}")
                if not_before is not None and moment < not_before:
                    raise Invalid(f"line {line}: installed before this run started: {event['time']}")
            else:
                for key in ("entry", "window"):
                    if not isinstance(event.get(key), str) or not event[key]:
                        raise Invalid(f"line {line}: {kind} has no {key}")
                frame(event, "before", line)
                frame(event, "after", line)
        except Invalid as problem:
            problems.append(str(problem))
    if not installed:
        problems.insert(0, "no installed record: the display gate's start in this run is unproven")
    elif len(installed) > 1:
        problems.append(f"{len(installed)} installed records (lines {installed}): more than one gate wrote this log")
    if problems:
        raise Invalid("\n".join(problems))
    placements = counts["placed"] + counts["moved"]
    if placements == 0:
        evidence = "installed only: the gate was confined to the display and no window was ordered, so no placement is recorded"
    else:
        evidence = f"{placements} placement(s) recorded ({counts['placed']} placed, {counts['moved']} moved)"
    return counts, evidence


def main(arguments, out=None, err=None):
    out, err = out or sys.stdout, err or sys.stderr
    if arguments == ["--self-test"]:
        return self_test()
    options, index = {}, 0
    while index < len(arguments):
        key = arguments[index]
        if key not in ("--check", "--display", "--not-before") or index + 1 >= len(arguments) or key in options:
            options = None
            break
        options[key] = arguments[index + 1]
        index += 2
    if not options or "--check" not in options or "--display" not in options or not options["--display"]:
        print("usage: display_gate_log.py --check LOG --display NAME [--not-before EPOCH] | --self-test", file=err)
        return 2
    try:
        not_before = float(options["--not-before"]) if "--not-before" in options else None
    except ValueError:
        print("--not-before needs seconds since 1970", file=err)
        return 2
    path = options["--check"]
    try:
        with open(path, encoding="utf-8", errors="strict") as handle:
            text = handle.read()
        counts, evidence = check(text, options["--display"], not_before)
    except FileNotFoundError:
        print(f"no gate log at {path}: the display gate recorded nothing, so placement is unproven", file=err)
        return 1
    except (OSError, UnicodeDecodeError) as error:
        print(f"the gate log cannot be read: {error}", file=err)
        return 1
    except Invalid as problems:
        print(str(problems), file=err)
        return 1
    print("gate events: " + ", ".join(f"{kind} {count}" for kind, count in sorted(counts.items())), file=out)
    print(f"evidence: {evidence}", file=out)
    return 0


# MARK: Self-test (fixture logs in a private temporary folder only)

def self_test():
    failures = []
    display = "虚拟屏 1 · Codex"
    start = datetime.datetime(2026, 10, 16, 3, 30, tzinfo=datetime.timezone.utc).timestamp()
    time = "2026-10-16T04:00:00.000Z"
    early = "2026-10-16T03:00:00.000Z"

    def record(**fields):
        return json.dumps(fields, ensure_ascii=False, sort_keys=True) + "\n"

    installed = record(kind="installed", detail=f'confine(displayName: "{display}") in xctest 4242', time=time)
    placed = record(kind="placed", entry="orderFront:", window="NSWindow#1", before=[0, 0, 10, 10],
                    after=[0, 0, 10, 10], time=time)
    moved = record(kind="moved", entry="setFrame:display:", window="NSPanel#2", before=[-50, 0, 10, 10],
                   after=[1.5, 2, 10, 10], time=time)
    invalid = {
        "missing": None,
        "empty": "",
        "whitespace": " \n",
        "unrelated JSON": '{"kind":"not-a-gate-event"}\n',
        "refusal only": '{"kind":"refused","entry":"fixture"}\n',
        "malformed": "{broken\n",
        "array": installed + "[1]\n",
        "no kind": installed + record(entry="x", time=time),
        "unknown kind": installed + record(kind="shown", entry="x", window="w", time=time),
        "cut off": installed + placed.rstrip("\n"),
        "blank line": installed + "\n" + placed,
        "deny all": record(kind="installed", detail='denyAll(reason: "fixture") in xctest 4242', time=time),
        "other display": record(kind="installed", detail='confine(displayName: "Studio") in xctest 4242', time=time),
        "no process": record(kind="installed", detail=f'confine(displayName: "{display}")', time=time),
        "installed without time": record(kind="installed", detail=f'confine(displayName: "{display}") in xctest 4242'),
        "bad time": installed.replace(time, "yesterday"),
        "stale": installed.replace(time, early),
        "not first": placed + installed,
        "twice": installed + installed,
        "placed without before": installed + record(kind="placed", entry="e", window="w", after=[0, 0, 1, 1], time=time),
        "three numbers": installed + record(kind="moved", entry="e", window="w", before=[0, 0, 1], after=[0, 0, 1, 1],
                                            time=time),
        "text frame": installed + record(kind="placed", entry="e", window="w", before=["0", 0, 1, 1],
                                         after=[0, 0, 1, 1], time=time),
        "empty window": installed + record(kind="placed", entry="e", window="", before=[0, 0, 1, 1],
                                           after=[0, 0, 1, 1], time=time),
        "refused after install": installed + record(kind="refused", entry="orderFront:", window="NSWindow#3",
                                                    before=[0, 0, 1, 1], detail="off the display", time=time),
        "violation": installed + placed + record(kind="violation", entry="didMove", window="NSWindow#1",
                                                 before=[0, 0, 1, 1], detail="hidden", time=time),
        "external": installed + record(kind="externalRefused", entry="NSWorkspace.open", window="-",
                                       detail="URL", time=time),
    }
    valid = {
        "installed only": (installed, "installed only"),
        "placements": (installed + placed + moved, "2 placement(s) recorded (1 placed, 1 moved)"),
        "decomposed name": (installed.replace(display, unicodedata.normalize("NFD", display)), "installed only"),
        "quoted name": (record(kind="installed", detail='confine(displayName: "A \\"B\\"") in xctest 7', time=time),
                        "installed only"),
    }
    folder = tempfile.mkdtemp(prefix="display-gate-log-self-test-")
    try:
        def run(label, text, name=display):
            path = os.path.join(folder, re.sub(r"\W+", "-", label) + ".jsonl")
            if text is not None:
                with open(path, "x", encoding="utf-8") as handle:
                    handle.write(text)
            out, err = io.StringIO(), io.StringIO()
            status = main(["--check", path, "--display", name, "--not-before", str(start)], out=out, err=err)
            return status, out.getvalue(), err.getvalue()

        for label, text in invalid.items():
            status, out, err = run(label, text)
            if status != 1 or not err or "evidence:" in out:
                failures.append(f"{label}: exit {status}, out {out!r}, err {err!r}")
        for label, (text, expected) in valid.items():
            name = 'A "B"' if label == "quoted name" else display
            status, out, err = run(label, text, name)
            if status != 0 or expected not in out or err:
                failures.append(f"{label}: exit {status}, out {out!r}, err {err!r}")
        with contextlib.redirect_stderr(io.StringIO()):
            usage = (main([]), main(["--check", "x"]), main(["--check", "x", "--display", ""]),
                     main(["--check", "x", "--display", display, "--not-before", "soon"]),
                     main(["--check", "x", "--check", "y", "--display", display]))
        if usage != (2, 2, 2, 2, 2):
            failures.append(f"usage errors exit {usage}")
    finally:
        for name in os.listdir(folder):
            os.remove(os.path.join(folder, name))
        os.rmdir(folder)

    # The runner reads its log with this check and reports its evidence level.
    runner = (pathlib.Path(__file__).resolve().parent / "run_display_bound_tests.sh").read_text(encoding="utf-8")
    if ('script/display_gate_log.py --check "$LOG_PATH" --display "$DISPLAY_NAME"' not in runner
            or "<<'PY'" in runner or "s/^evidence: //p" not in runner):
        failures.append("run_display_bound_tests.sh must check its log with this script and print the evidence level")

    for failure in failures:
        print(f"self-test failed: {failure}", file=sys.stderr)
    if failures:
        return 1
    print("display gate log self-test passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
