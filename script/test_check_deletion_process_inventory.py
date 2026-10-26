#!/usr/bin/env python3
"""Pure text cases for the deletion and process inventory; reads no repository source."""
import unittest
from check_deletion_process_inventory import ROOT, compare, findings_for, parse_inventory

SAMPLE = ROOT / "Sources" / "Sample.swift"
FILE = "Sources/Sample.swift"


def found(text, types=None):
    return {(kind, target): count for (kind, _, target), count in findings_for(SAMPLE, text, types).items()}


class CallFindingTests(unittest.TestCase):
    def test_deletion_calls_are_found_in_any_spelling(self):
        self.assertEqual(found("try FileManager.default.removeItem(at: url)"), {("delete", "removeItem"): 1})
        self.assertEqual(found("try fm\n  .removeItem(\n    at: url)"), {("delete", "removeItem"): 1})
        self.assertEqual(found("try FileManager.default.`removeItem`(at: url)"), {("delete", "removeItem"): 1})
        self.assertEqual(found("_ = unlinkat(fd, name, 0); _ = unlinkat (fd, other, AT_REMOVEDIR)"),
                         {("delete", "unlinkat"): 2})
        self.assertEqual(found("_ = Darwin.unlink(path)"), {("delete", "unlink"): 1})
        self.assertEqual(found("_ = Darwin . `unlink` (path)"), {("delete", "unlink"): 1})
        self.assertEqual(found("_ = rmdir(path); _ = removefile(path, nil, 0)"),
                         {("delete", "rmdir"): 1, ("delete", "removefile"): 1})
        self.assertEqual(found("_ = remove(path)"), {("delete", "remove"): 1})
        self.assertEqual(found("_ = Foundation.remove(path)"), {("delete", "remove"): 1})

    def test_replacing_trashing_and_launching_calls_are_found(self):
        self.assertEqual(found("renameatx_np(a, b, c, d, UInt32(RENAME_EXCL))"), {("rename", "renameatx_np"): 1})
        self.assertEqual(found("_ = rename(a, b); _ = Darwin.renameat(x, a, y, b)"),
                         {("rename", "rename"): 1, ("rename", "renameat"): 1})
        self.assertEqual(found("_ = try fm.replaceItemAt(a, withItemAt: b)"), {("rename", "replaceItemAt"): 1})
        self.assertEqual(found("try fm.trashItem(at: url, resultingItemURL: &out)"), {("trash", "trashItem"): 1})
        self.assertEqual(found("NSWorkspace.shared.recycle([url]) { _, _ in }"), {("trash", "recycle"): 1})
        self.assertEqual(found("let p = Process(); try p.run()"), {("launch", "Process"): 1})
        self.assertEqual(found("try Process.run(url, arguments: [])"), {("launch", "Process.run"): 1})
        self.assertEqual(found("posix_spawn(&pid, path, nil, nil, argv, envp)"), {("launch", "posix_spawn"): 1})
        self.assertEqual(found("_ = system(command)"), {("launch", "system"): 1})
        self.assertEqual(found("try Shell.run(tool, [])\ntry Shell . capture(tool, [])"),
                         {("launch", "Shell.run"): 1, ("launch", "Shell.capture"): 1})
        self.assertEqual(found("try await runner.run(\n  executableURL: url, arguments: [])"),
                         {("launch", "run(executableURL:)"): 1})
        self.assertEqual(found("try await runner.run(executable: path, arguments: [])"),
                         {("launch", "run(executable:)"): 1})
        self.assertEqual(found("NSWorkspace.shared.openApplication(at: url, configuration: c)"),
                         {("launch", "openApplication"): 1})
        self.assertEqual(found("NSWorkspace.shared.open([doc], withApplicationAt: app, configuration: c)"),
                         {("launch", "open(withApplicationAt:)"): 1})
        self.assertEqual(found("let s = NSAppleScript(source: text)"), {("script", "NSAppleScript"): 1})

    def test_explicit_initializers_count_under_the_type(self):
        # Review A-R4: every spelling of the same initializer is one launch.
        for spelling in ("Process()", "Process.init()", "Foundation.Process.init()", "Process . init ()",
                         "`Process`.init()", "Process/* note */.init()", "Process\n    .init()",
                         "Process.self.init()", "Foundation . `Process` . `init` ()"):
            with self.subTest(spelling=spelling):
                self.assertEqual(found(f"let task = {spelling}; task.executableURL = url; try task.run()"),
                                 {("launch", "Process"): 1})
        self.assertEqual(found("let task: Process = .init()"), {("launch", "Process"): 1})
        self.assertEqual(found("var task: Foundation.Process? = .init()"), {("launch", "Process"): 1})
        # Any other "Process = .init(" counts as well; a guard errs towards a finding.
        self.assertEqual(found("worker.Process = .init()"), {("launch", "Process"): 1})
        self.assertEqual(found("let task = NSTask.init()"), {("launch", "NSTask"): 1})
        self.assertEqual(found("let s = NSAppleScript.init(source: text)"), {("script", "NSAppleScript"): 1})
        self.assertEqual(found("let s = OSAScript.init(source: text)"), {("script", "OSAScript"): 1})

    def test_other_initializers_and_names_are_not_launches(self):
        self.assertEqual(found("let info = ProcessInfo.init(); let r = Process.TerminationReason.init(rawValue: 1)"), {})
        self.assertEqual(found("let kind = ProcessKind.init(rawValue: x); let t = MyProcess.init()"), {})
        self.assertEqual(found("let id = AppUpdateTrackedProcess.init(pid: 1)"), {})
        self.assertEqual(found("x = .init(); let count: Int = .init()"), {})
        self.assertEqual(found("// Process.init()\nlet s = \"Process.init()\"; let t = \"Process = .init()\""), {})
        # Documented boundary: a function value is not a call.
        self.assertEqual(found("let make = Process.init"), {})

    def test_other_names_text_and_declarations_are_not_findings(self):
        self.assertEqual(found("paths.remove(at: 0); set.remove(x); self.unlink(x)"), {})
        self.assertEqual(found("remove(backupID: id); unlink(name, in: fd, flags: 0)"), {})
        self.assertEqual(found("try Self.remove(deletion)"), {})
        self.assertEqual(found("enum Failure { case system(Int32) }\nthrow Failure.system(errno)"), {})
        self.assertEqual(found("throw Failure.system(errno)", types={"Failure"}), {})
        self.assertEqual(found("func remove(_ name: String) {}\nstatic func unlink(_ x: Int) {}"), {})
        self.assertEqual(found("func run(executableURL: URL, arguments: [String]) {}"), {})
        self.assertEqual(found("Text(\"x\").font(.system(size: 13))"), {})
        self.assertEqual(found("NSWorkspace.shared.open(url)"), {})
        self.assertEqual(found("// try FileManager.default.removeItem(at: url)"), {})
        self.assertEqual(found("/* unlink(path) /* nested */ */ let t = 1"), {})
        self.assertEqual(found('let note = "call removeItem(at: url) and Process()"'), {})
        self.assertEqual(found('let help = """\n  rm: unlink(path)\n  """'), {})


class CloneFindingTests(unittest.TestCase):
    def test_clone_calls_are_inventory_items(self):
        for name in ("clonefile", "clonefileat", "fclonefileat"):
            self.assertEqual(found(f"Darwin.{name}(source, target, 0)"), {("clone", name): 1})
        self.assertEqual(found('// clonefile(a, b, 0)\nlet text = "clonefile(a, b, 0)"'), {})


class ExecutableFindingTests(unittest.TestCase):
    def test_program_paths_in_literals_are_found(self):
        self.assertEqual(found('try Shell.capture("/usr/bin/du", ["-sk", path])'),
                         {("launch", "Shell.capture"): 1, ("executable", "/usr/bin/du"): 1})
        self.assertEqual(found('static let tool = #"/usr/sbin/diskutil"#'), {("executable", "/usr/sbin/diskutil"): 1})
        self.assertEqual(found('let a = "/bin/ps"; let b = "/opt/homebrew/bin/brew"; let c = "/usr/libexec/x"'),
                         {("executable", "/bin/ps"): 1, ("executable", "/opt/homebrew/bin/brew"): 1,
                          ("executable", "/usr/libexec/x"): 1})
        self.assertEqual(found('let tool = "/usr/bin/\\(name)"'), {("executable", "/usr/bin/<interpolated>"): 1})
        self.assertEqual(found('let t = "/Library/Vendor/Tool.app/Contents/MacOS/tool"'),
                         {("executable", "/Library/Vendor/Tool.app/Contents/MacOS/tool"): 1})

    def test_other_paths_and_text_are_not_programs(self):
        self.assertEqual(found('let a = "/usr/share/x"; let b = "/usr/bin"; let c = "Contents/MacOS/"'), {})
        self.assertEqual(found('// run "/usr/bin/du" here'), {})
        self.assertEqual(found('let note = "use \\"/usr/bin/du\\" here"'), {})
        self.assertEqual(found('let help = """\n"/usr/bin/du"\n"""'), {})


class InventoryTests(unittest.TestCase):
    def test_entries_are_parsed_and_checked(self):
        entries, errors = parse_inventory(
            "# comment\n\n"
            f"delete | {FILE} | removeItem | 2 | 2026-10-15 | why | with a pipe\n"
            f"launch | {FILE} | Process | 1 | 2026-10-15 | why\n")
        self.assertEqual(errors, [])
        self.assertEqual(entries, {("delete", FILE, "removeItem"): 2, ("launch", FILE, "Process"): 1})

    def test_malformed_entries_are_errors(self):
        _, errors = parse_inventory(
            f"delete | {FILE} | removeItem | 2 | 2026-10-15\n"
            f"erase | {FILE} | removeItem | 2 | 2026-10-15 | why\n"
            f"delete | {FILE} | unlink | 0 | 2026-10-15 | why\n"
            f"delete | {FILE} | rmdir | 1 | today | why\n"
            f"delete | {FILE} | remove | 1 | 2026-10-15 | why\n"
            f"delete | {FILE} | remove | 1 | 2026-10-15 | again\n"
            f"delete | {FILE} | rename |  | 2026-10-15 | why\n")
        self.assertEqual([error.split(":")[0] for error in errors], ["1", "2", "3", "4", "6", "7"])

    def test_new_removed_and_recounted_uses_fail(self):
        entries = {("delete", FILE, "removeItem"): 2, ("delete", FILE, "unlink"): 1, ("launch", FILE, "Process"): 1}
        self.assertEqual(compare({("delete", FILE, "removeItem"): 2, ("delete", FILE, "unlink"): 1,
                                  ("launch", FILE, "Process"): 1}, entries), [])
        messages = compare({("delete", FILE, "removeItem"): 3, ("launch", FILE, "Process"): 1,
                            ("trash", FILE, "trashItem"): 1}, entries)
        self.assertEqual(messages, [
            f"not in inventory: trash {FILE} trashItem (1 uses)",
            f"stale inventory entry (no longer used): delete {FILE} unlink",
            f"new use not in inventory: delete {FILE} removeItem (listed 2, found 3)",
        ])
        self.assertEqual(compare({("delete", FILE, "removeItem"): 1, ("delete", FILE, "unlink"): 1,
                                  ("launch", FILE, "Process"): 1}, entries),
                         [f"stale inventory count: delete {FILE} removeItem (listed 2, found 1)"])


if __name__ == "__main__":
    unittest.main()
