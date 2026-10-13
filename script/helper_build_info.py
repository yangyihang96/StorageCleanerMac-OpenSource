#!/usr/bin/env python3
"""Write the helper's linker input; never inspect or execute an installed helper."""
import argparse
import os
import plistlib
import re
from pathlib import Path


def write_info(destination: Path, build: str, identifier: str, executable: str) -> None:
    if not re.fullmatch(r"[1-9][0-9]{0,19}", build) or int(build) > (1 << 64) - 1:
        raise ValueError("helper CFBundleVersion must be a canonical positive UInt64 build")
    # Each signed helper label belongs to exactly one executable.
    allowed = {
        "com.local.StorageCleanerMac.FanControlHelper": "StorageCleanerFanControlHelper",
        "com.local.StorageCleanerMac.beta.FanControlHelper": "StorageCleanerFanControlHelper",
        "com.local.StorageCleanerMac.FileOperationHelper": "StorageCleanerFileOperationHelper",
        "com.local.StorageCleanerMac.beta.FileOperationHelper": "StorageCleanerFileOperationHelper",
    }
    if identifier not in allowed:
        raise ValueError("unexpected helper identifier")
    if executable != allowed[identifier]:
        raise ValueError("unexpected helper executable")
    data = plistlib.dumps({"CFBundleIdentifier": identifier,
        "CFBundleExecutable": executable, "CFBundleVersion": build}, sort_keys=True)
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
    with os.fdopen(fd, "wb") as output:
        output.write(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("build")
    parser.add_argument("identifier")
    parser.add_argument("executable")
    args = parser.parse_args()
    write_info(args.destination, args.build, args.identifier, args.executable)
