#!/usr/bin/env python3
"""Read-only install snapshots. Never signal, launch, register or authorize a daemon."""
import json
import os
import re
import stat
import subprocess
import sys
import time


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


def wait_for_exit(label, timeout, run=subprocess.run, sleep=time.sleep, clock=time.monotonic):
    """Polls launchd until this daemon has no process or `timeout` seconds pass.

    The helper exits by itself 15 s after its last client leaves. Waiting for
    that after the old Beta quits lets the new Beta's first connection start
    the replaced executable instead of reattaching to the old process. Only
    reads `launchctl print`; never signals, kickstarts or boots out the job.
    """
    start = clock()
    while True:
        try:
            job = run(["/bin/launchctl", "print", "system/" + label],
                      capture_output=True, text=True, timeout=3, check=False)
        except (OSError, subprocess.SubprocessError):
            return "unknown", None, clock() - start
        elapsed = clock() - start
        if job.returncode != 0:
            return "unknown", None, elapsed
        pid = parse_pid(job.stdout)
        if pid is None:
            return "exited", None, elapsed
        if elapsed >= timeout:
            return "still_running", pid, elapsed
        sleep(0.5)


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
                "检测到安装前的助手进程仍驻留，磁盘文件已替换。2.0.1（D97）起的助手会在新版 App "
                "通过完整客户端校验后让位，可在 App 点击“重新连接”。更早的助手不能让位（让位记录从未写入）："
                "开着 Mac mini 模式或风扇控制时它需要常驻；请先关掉这些功能并退出测试版，约 15 秒后它会"
                "自行退出，再打开测试版；或重启一次。仍失败时请在系统设置 → 通用 → 登录项与扩展重新批准。"
                "需要管理员权限的处理仅提示，本脚本不会执行 sudo 或结束助手。")
        }
        print("helper upgrade check: " + state + " — " + messages[state])
    elif len(args) == 3 and args[0] == "wait-exit":
        state, pid, elapsed = wait_for_exit(args[1], float(args[2]))
        messages = {
            "exited": "旧助手进程已自行退出（约 %d 秒）；新 Beta 首次连接时由系统启动替换后的助手。" % round(elapsed),
            "still_running": "旧助手进程 %d 秒后仍在运行（pid %s），可能还有客户端，或开着 Mac mini 模式、风扇控制（需要助手常驻）；继续安装，按安装后的提示处理。" % (round(elapsed), pid),
            "unknown": "未能读取助手状态，跳过等待。",
        }
        print("helper upgrade wait: " + state + " — " + messages[state])
    else:
        raise SystemExit("usage: helper_upgrade_status.py capture LABEL EXECUTABLE | compare BEFORE_JSON AFTER_JSON"
                         " | wait-exit LABEL SECONDS")


if __name__ == "__main__":
    main(sys.argv[1:])
