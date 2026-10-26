#!/usr/bin/env python3
"""Pure snapshots; does not invoke launchctl or inspect a real daemon."""
import ast
import pathlib
import subprocess
import unittest
from helper_upgrade_status import classify, parse_pid, wait_for_exit


class FakeLaunchd:
    """Answers `launchctl print` from a script of (returncode, pid) replies."""
    def __init__(self, replies):
        self.replies = list(replies)
        self.calls = []
        self.now = 0.0

    def run(self, argv, **kwargs):
        self.calls.append(argv)
        code, pid = self.replies.pop(0) if len(self.replies) > 1 else self.replies[0]
        text = "state = running\n\tpid = %d\n\truns = 3\n" % pid if pid else "state = not running\n\truns = 3\n"
        return subprocess.CompletedProcess(argv, code, stdout=text, stderr="")

    def sleep(self, seconds):
        self.now += seconds

    def clock(self):
        return self.now


class HelperUpgradeStatusTests(unittest.TestCase):
    def snap(self, pid=42, stamp=(1, 2, 3), readable=True, runs=444):
        return dict(pid=pid, runs=runs, stamp=stamp, job_readable=readable)

    def test_same_pid_with_replaced_disk_warns_old_process(self):
        self.assertEqual(classify(self.snap(), self.snap(stamp=(4, 5, 6))), "old_process_survived_replacement")

    def test_same_pid_same_disk_is_unchanged(self):
        self.assertEqual(classify(self.snap(), self.snap()), "unchanged")

    def test_new_pid_is_not_claimed_as_verified_connection(self):
        self.assertEqual(classify(self.snap(), self.snap(pid=43)), "new_process_unverified")

    def test_reused_pid_with_new_run_counter_is_not_old_process(self):
        self.assertEqual(classify(self.snap(), self.snap(runs=445)), "new_process_unverified")
        self.assertEqual(classify(self.snap(), self.snap(runs=None)), "unknown")

    def test_no_process_is_on_demand(self):
        self.assertEqual(classify(self.snap(), self.snap(pid=None)), "on_demand")

    def test_unreadable_or_unknown_disk_is_unknown(self):
        self.assertEqual(classify(self.snap(readable=False), self.snap()), "unknown")
        self.assertEqual(classify(self.snap(), self.snap(stamp=None)), "unknown")

    def test_pid_parser_does_not_confuse_runs_or_other_numbers(self):
        self.assertEqual(parse_pid("state = running\n\tpid = 2424\n\truns = 444\n"), 2424)
        self.assertIsNone(parse_pid("runs = 444\nlast exit code = 0\n"))


class HelperIdleExitWaitTests(unittest.TestCase):
    def wait(self, launchd, timeout=30):
        return wait_for_exit("com.example.helper", timeout, run=launchd.run, sleep=launchd.sleep, clock=launchd.clock)

    def test_waits_until_the_old_process_leaves_by_itself(self):
        launchd = FakeLaunchd([(0, 4242)] * 31 + [(0, None)])
        state, pid, elapsed = self.wait(launchd)
        self.assertEqual(state, "exited")
        self.assertIsNone(pid)
        self.assertAlmostEqual(elapsed, 15.5)

    def test_gives_up_after_the_timeout_and_names_the_process(self):
        launchd = FakeLaunchd([(0, 4242)])
        state, pid, elapsed = self.wait(launchd, timeout=30)
        self.assertEqual((state, pid), ("still_running", 4242))
        self.assertGreaterEqual(elapsed, 30)
        self.assertLess(elapsed, 31)

    def test_no_process_or_unreadable_job_does_not_wait(self):
        self.assertEqual(self.wait(FakeLaunchd([(0, None)]))[0], "exited")
        launchd = FakeLaunchd([(113, None)])
        self.assertEqual(self.wait(launchd), ("unknown", None, 0.0))
        self.assertEqual(len(launchd.calls), 1)

    def test_only_reads_launchd(self):
        launchd = FakeLaunchd([(0, 4242)] * 3 + [(0, None)])
        self.wait(launchd)
        self.assertEqual({tuple(call) for call in launchd.calls},
                         {("/bin/launchctl", "print", "system/com.example.helper")})
        # The code (not its messages) only ever runs `launchctl print` and
        # never imports signal handling or kills a process.
        tree = ast.parse((pathlib.Path(__file__).parent / "helper_upgrade_status.py").read_text())
        imported = {alias.name for node in ast.walk(tree) if isinstance(node, (ast.Import, ast.ImportFrom))
                    for alias in node.names} | {node.module for node in ast.walk(tree) if isinstance(node, ast.ImportFrom)}
        self.assertNotIn("signal", imported)
        self.assertFalse([node for node in ast.walk(tree) if isinstance(node, ast.Attribute) and node.attr in ("kill", "killpg")])
        commands = [node for node in ast.walk(tree) if isinstance(node, ast.List) and node.elts
                    and isinstance(node.elts[0], ast.Constant) and node.elts[0].value == "/bin/launchctl"]
        self.assertEqual(len(commands), 2)
        self.assertTrue(all(isinstance(node.elts[1], ast.Constant) and node.elts[1].value == "print" for node in commands))


if __name__ == "__main__":
    unittest.main()
