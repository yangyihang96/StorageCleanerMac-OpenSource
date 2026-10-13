#!/usr/bin/env python3
"""Pure snapshots; does not invoke launchctl or inspect a real daemon."""
import unittest
from helper_upgrade_status import classify, parse_pid


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


if __name__ == "__main__":
    unittest.main()
