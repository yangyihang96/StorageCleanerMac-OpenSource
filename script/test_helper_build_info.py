#!/usr/bin/env python3
import plistlib
import errno
import tempfile
import unittest
from pathlib import Path
from helper_build_info import write_info


class HelperBuildInfoTests(unittest.TestCase):
    def test_existing_symlink_is_rejected_without_overwriting_its_target(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            victim = Path(directory) / "untouched"
            victim.write_bytes(b"original contents")
            path.symlink_to(victim)
            with self.assertRaises(OSError) as result:
                write_info(path, "21", "com.local.StorageCleanerMac.FanControlHelper", "StorageCleanerFanControlHelper")
            self.assertEqual(result.exception.errno, errno.ELOOP)
            self.assertEqual(victim.read_bytes(), b"original contents")
            self.assertTrue(path.is_symlink())

    def test_dangling_symlink_is_rejected_without_creating_its_target(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            missing = Path(directory) / "missing"
            path.symlink_to(missing)
            with self.assertRaises(OSError) as result:
                write_info(path, "21", "com.local.StorageCleanerMac.FanControlHelper", "StorageCleanerFanControlHelper")
            self.assertEqual(result.exception.errno, errno.ELOOP)
            self.assertFalse(missing.exists())
            self.assertTrue(path.is_symlink())

    def test_both_signed_identifiers_use_same_authoritative_build(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            for label in ["com.local.StorageCleanerMac.FanControlHelper", "com.local.StorageCleanerMac.beta.FanControlHelper"]:
                write_info(path, "20261010015824", label, "StorageCleanerFanControlHelper")
                self.assertEqual(plistlib.loads(path.read_bytes()), {"CFBundleIdentifier": label,
                    "CFBundleExecutable": "StorageCleanerFanControlHelper", "CFBundleVersion": "20261010015824"})

    def test_file_operation_helper_labels_are_accepted_with_their_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            for label in ["com.local.StorageCleanerMac.FileOperationHelper", "com.local.StorageCleanerMac.beta.FileOperationHelper"]:
                write_info(path, "20261013071824", label, "StorageCleanerFileOperationHelper")
                self.assertEqual(plistlib.loads(path.read_bytes()), {"CFBundleIdentifier": label,
                    "CFBundleExecutable": "StorageCleanerFileOperationHelper", "CFBundleVersion": "20261013071824"})

    def test_ambiguous_or_overflowing_version_is_never_written(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            for build in ["", "0", "01", "-2", "+2", "2.0", " 2", "2\n", "２", "18446744073709551616"]:
                with self.assertRaises(ValueError):
                    write_info(path, build, "com.local.StorageCleanerMac.FanControlHelper", "StorageCleanerFanControlHelper")
            self.assertFalse(path.exists())

    def test_unexpected_label_or_executable_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            for label, exe in [("com.attacker", "StorageCleanerFanControlHelper"),
                               ("com.local.StorageCleanerMac.FanControlHelper", "other"),
                               ("com.local.StorageCleanerMac.FanControlHelper", "StorageCleanerFileOperationHelper"),
                               ("com.local.StorageCleanerMac.beta.FileOperationHelper", "StorageCleanerFanControlHelper")]:
                with self.assertRaises(ValueError):
                    write_info(path, "21", label, exe)
            self.assertFalse(path.exists())


if __name__ == "__main__":
    unittest.main()
