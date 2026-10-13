#!/usr/bin/env python3
"""Read-only install snapshots. Never signal, launch, register or authorize a daemon."""
import json
import os
import re
import stat
import subprocess
import sys


def parse_pid(output):
    match = re.search(r"^\s*pid = ([1-9][0-9]*)\s*$", output, re.MULTILINE)
    return int(match[1]) if match else None


def capture(label, executable):
    snapshot = {"pid": None, "runs": None, "stamp": None, "job_readable": False}
    try:
        job = subprocess.run(["/bin/launchctl", "print", "system/" + label],
                             capture_output=True, text=True, timeout=3, check=False)
        snapshot["job_readable"] = job.returncode == 0
        if job.returncode == 0:
            snapshot["pid"] = parse_pid(job.stdout)
            runs = re.search(r"^\s*runs = ([0-9]+)\s*$", job.stdout, re.MULTILINE)
            snapshot["runs"] = int(runs[1]) if runs else None
        info = os.lstat(executable)
        if stat.S_ISREG(info.st_mode) and os.path.realpath(executable) == executable:
            snapshot["stamp"] = [info.st_dev, info.st_ino, info.st_size,
                                 info.st_mtime_ns, info.st_ctime_ns]
    except (OSError, subprocess.SubprocessError):
        pass
    return snapshot


def classify(before, after):
    if not before.get("job_readable") or not after.get("job_readable"):
        return "unknown"
    if not after.get("pid"):
        return "on_demand"
    if not before.get("pid") or after["pid"] != before["pid"]:
        return "new_process_unverified"
    # Include launchd's run counter to avoid treating a reused PID as the
    # same process instance. Missing counters cannot prove a survivor.
    if before.get("runs") is None or after.get("runs") is None:
        return "unknown"
    if before["runs"] != after["runs"]:
        return "new_process_unverified"
    if before.get("stamp") is None or after.get("stamp") is None:
        return "unknown"
    if before["stamp"] != after["stamp"]:
        return "old_process_survived_replacement"
    return "unchanged"


def main(args):
    if len(args) == 3 and args[0] == "capture":
        print(json.dumps(capture(args[1], args[2])))
    elif len(args) == 3 and args[0] == "compare":
        state = classify(json.loads(args[1]), json.loads(args[2]))
        messages = {
            "unknown": "助手进程状态未能确认；请在 App 的系统控制页重新连接并核对。",
            "on_demand": "助手当前没有驻留进程；下次受信任连接按需启动，连接及硬件模式仍待验证。",
            "new_process_unverified": "助手进程已变化；新进程的签名连接及硬件模式仍需 App 验证。",
            "unchanged": "助手进程与磁盘元数据未变化；受信任连接及硬件模式仍需 App 验证。",
            "old_process_survived_replacement": (
                "检测到安装前的助手进程仍驻留，磁盘文件已替换。请在 App 点击“重新连接”；"
                "含自动更新逻辑的助手会在完整客户端校验后恢复系统控制并让位。"
                "仍失败时请在系统设置 → 通用 → 登录项与扩展重新批准。"
                "早于本修复的助手不能自动让位，需要由主会话按批准流程重新启用；"
                "需要管理员权限的处理仅提示，本脚本不会执行 sudo 或结束助手。")
        }
        print("helper upgrade check: " + state + " — " + messages[state])
    else:
        raise SystemExit("usage: helper_upgrade_status.py capture LABEL EXECUTABLE | compare BEFORE_JSON AFTER_JSON")


if __name__ == "__main__":
    main(sys.argv[1:])
