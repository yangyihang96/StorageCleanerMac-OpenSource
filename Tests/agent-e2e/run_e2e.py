#!/usr/bin/env python3
"""End-to-end check of the AI assistant interface with real signatures (D263).

Builds a throwaway ad-hoc signed bundle holding the real bridge and a test
double of the App (AgentFixtureHost: the real gateway with fixture answers),
then drives real processes over the real socket: the unit tests inject code
identities, this one lets the kernel and the Security framework supply them.

Touches only its own directory under /private/tmp and an isolated QA data root
under ~/Library/Caches/StorageCleanerIntegration-*, both removed at the end.
It reads one key of the QA preferences domain through the bridge and writes no
preference. Team signing cannot be tried here (it would need the keychain), so
the Team branch of the policies stays covered by AgentLocationAndPeerTests.

Usage: run_e2e.py --bin-dir <swift build --show-bin-path> --evidence <dir>
                  [--sdk <dir of @modelcontextprotocol/sdk>] [--schemas <dir with <version>/schema.json>]
Exit status: 0 when every check passed. Evidence goes to <dir>/e2e-<time>/.
"""
import json
import os
import plistlib
import select
import shutil
import signal
import socket
import stat
import subprocess
import sys
import threading
import time
import uuid
from pathlib import Path

QA_ID = "com.local.StorageCleanerMac.integration"
BRIDGE_ID = QA_ID + ".agent-bridge"
MODERN_META = {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {},
               "io.modelcontextprotocol/clientInfo": {"name": "e2e-modern", "version": "1"}}

results = []


def check(name, passed, detail=""):
    results.append({"name": name, "passed": bool(passed), "detail": str(detail)[:400]})
    print(("PASS " if passed else "FAIL ") + name + (f"  [{str(detail)[:200]}]" if detail != "" and not passed else ""), flush=True)


class Lines:
    """One line at a time from a pipe, with a timeout."""

    def __init__(self, fd):
        self.fd, self.buffer = fd, b""

    def read(self, timeout=10):
        end = time.time() + timeout
        while b"\n" not in self.buffer:
            left = end - time.time()
            if left <= 0 or not select.select([self.fd], [], [], left)[0]:
                raise TimeoutError
            chunk = os.read(self.fd, 1 << 20)
            if not chunk:
                raise EOFError
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line


class Host:
    """The App double, driven by its stdin."""

    def __init__(self, program, data, evidence, *flags):
        self.errors = open(evidence / "host-stderr.log", "ab")
        self.process = subprocess.Popen([str(program), "--data", str(data), *flags], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=self.errors)
        self.lines = Lines(self.process.stdout.fileno())

    def command(self, text):
        self.process.stdin.write((text + "\n").encode())
        self.process.stdin.flush()
        return json.loads(self.lines.read(15))

    def quit(self):
        if self.process.poll() is None:
            self.command("quit")
            self.process.wait(10)
        self.errors.close()

    def kill(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGKILL)
            self.process.wait(10)
        self.errors.close()


class MCP:
    """The real bridge in `mcp` mode, as an MCP client starts it."""

    def __init__(self, bridge, transcript):
        self.process = subprocess.Popen([str(bridge), "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.lines = Lines(self.process.stdout.fileno())
        self.transcript = open(transcript, "w", encoding="utf-8")
        self.next_id = 0

    def send(self, message):
        self.process.stdin.write((json.dumps(message) + "\n").encode())
        self.process.stdin.flush()

    def call(self, method, params=None, raw_id=None):
        self.next_id += 1
        identifier = raw_id if raw_id is not None else self.next_id
        request = {"jsonrpc": "2.0", "id": identifier, "method": method}
        if params is not None:
            request["params"] = params
        self.send(request)
        response = json.loads(self.lines.read(15))
        self.transcript.write(json.dumps({"request": request, "response": response}, ensure_ascii=False) + "\n")
        return response

    def raw(self, text):
        """A line that is not a valid request, recorded with what came back."""
        self.process.stdin.write((text + "\n").encode())
        self.process.stdin.flush()
        response = json.loads(self.lines.read(15))
        self.transcript.write(json.dumps({"request": {"raw": text[:80]}, "response": response}, ensure_ascii=False) + "\n")
        return response

    def close(self):
        self.process.stdin.close()
        start = time.time()
        status = self.process.wait(10)
        self.transcript.close()
        self.process.stdout.close()
        self.process.stderr.close()
        return status, time.time() - start


def run(*command, timeout=60):
    done = subprocess.run([str(part) for part in command], capture_output=True, text=True, timeout=timeout)
    return done.returncode, done.stdout, done.stderr


def sign(path, *flags):
    code, _, error = run("codesign", "-s", "-", "-f", "--timestamp=none", *flags, path)
    if code != 0:
        raise RuntimeError(f"codesign {path}: {error}")


def replace_file(source, target):
    # A new inode each time: the kernel caches signature state per vnode.
    temporary = target.with_name(target.name + ".new")
    shutil.copy2(source, temporary)
    os.replace(temporary, target)


def probe_program(program, path):
    code, out, _ = run(program, path, timeout=15)
    return code, out.strip()


def main():
    arguments = sys.argv[1:]
    sdk = Path(arguments[arguments.index("--sdk") + 1]) if "--sdk" in arguments else None
    schemas = Path(arguments[arguments.index("--schemas") + 1]) if "--schemas" in arguments else None
    binaries = Path(arguments[arguments.index("--bin-dir") + 1])
    stamp = time.strftime("%Y%m%d-%H%M%S")
    evidence = Path(arguments[arguments.index("--evidence") + 1]) / f"e2e-{stamp}"
    evidence.mkdir(parents=True)
    tag = uuid.uuid4().hex[:8]
    work = Path("/private/tmp") / f"sc-agt-e2e-{tag}"
    root = Path.home() / "Library/Caches" / f"StorageCleanerIntegration-agent-e2e-{tag}"
    socket_path = root / "Agent/s"
    hosts = []
    try:
        work.mkdir(mode=0o700)
        root.mkdir(mode=0o700)

        # A Chinese bundle name on purpose: the installed Beta is 测试版.app, and
        # peer checks compare paths with what proc_pidpath reports.
        bundle = work / "测试版QA.app"
        contents = bundle / "Contents"
        (contents / "MacOS").mkdir(parents=True)
        (contents / "Helpers").mkdir()
        info = {"CFBundleIdentifier": QA_ID, "CFBundleExecutable": "AgentFixtureHost", "CFBundleDisplayName": "测试版QA",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "2.0.2", "CFBundleVersion": "1",
                "LSEnvironment": {"STORAGE_CLEANER_INTEGRATION_ROOT": str(root)}}
        with open(contents / "Info.plist", "wb") as handle:
            plistlib.dump(info, handle)
        host_program = contents / "MacOS/AgentFixtureHost"
        bridge = contents / "Helpers/storage-cleaner-agent"
        shutil.copy2(binaries / "AgentFixtureHost", host_program)
        shutil.copy2(binaries / "StorageCleanerAgentBridge", bridge)
        sign(bridge, "-i", BRIDGE_ID)
        sign(bundle)
        code, _, error = run("codesign", "--verify", "--deep", "--strict", bundle)
        check("the fixture bundle passes a deep strict signature check", code == 0, error)
        signed_bridge = work / "signed-bridge"
        shutil.copy2(bridge, signed_bridge)

        def cli(*words):
            code, out, error = run(bridge, *words, timeout=30)
            try:
                return code, json.loads(out) if out.strip() else {}, error
            except json.JSONDecodeError:
                return code, {"unparsed": out}, error

        # --- Nothing running.
        code, out, _ = cli("status")
        check("App not running and switch absent: interface off, exit 4", code == 4 and out.get("reason") == "interface_off", out)

        # --- The App double, switched on.
        host = Host(host_program, root, evidence)
        hosts.append(host)
        check("off by default: nothing listens", host.command("status")["status"] == "off" and not socket_path.exists())
        code, out, _ = cli("status")
        check("App running but switch off: exit 4", code == 4, out)
        check("switching on listens", host.command("on")["status"] == "listening", "")
        mode = os.lstat(socket_path).st_mode
        check("socket is 0600 and its directory 0700",
              stat.S_IMODE(mode) == 0o600 and stat.S_IMODE(os.lstat(root / "Agent").st_mode) == 0o700, oct(mode))

        # --- D267: a listening gateway must not wake up on a timer.
        time.sleep(1)
        code, out, _ = run("top", "-l", "2", "-s", "3", "-pid", host.process.pid, "-stats", "pid,idlew", timeout=30)
        rows = [line.split() for line in out.splitlines() if line.strip().startswith(str(host.process.pid))]
        wakeups = rows[-1][1] if rows else "?"
        (evidence / "idle-wakeups.txt").write_text(out, encoding="utf-8")
        check("idle: under one wake-up a second while listening (100 ms polling would be 30 in 3 s)",
              wakeups.rstrip("+-").isdigit() and int(wakeups.rstrip("+-")) < 3, wakeups)
        print("     idle wake-ups over 3 s:", wakeups, flush=True)

        # --- The real bridge, verified by real signatures in both directions.
        code, out, _ = cli("status")
        check("the bundled bridge is accepted and an unknown client must be approved: exit 3",
              code == 3 and out.get("reason") == "approval_required", out)
        pending = host.command("pending")["pending"]
        (evidence / "identified-client.json").write_text(json.dumps(pending, ensure_ascii=False, indent=2), encoding="utf-8")
        check("the App names the real client from the process chain", len(pending) == 1 and pending[0]["key"], pending)
        print("     identified client:", json.dumps(pending[0] if pending else None, ensure_ascii=False), flush=True)

        host.command("approve read_only")
        code, out, _ = cli("status")
        check("approved read-only: reads work", code == 0 and out["result"]["app"]["name"] == "QA", out)
        check("D266: the raw home path was rewritten to ~", out.get("result", {}).get("app", {}).get("support") == "~/fixture", out)
        code, out, _ = cli("capabilities")
        check("capabilities report the read-only grant", code == 0 and out["result"]["permission"] == "read_only", out)
        code, out, _ = cli("scan", "junk")
        check("read-only client cannot start a scan: exit 6", code == 6 and out.get("reason") == "insufficient_permission", out)
        code, out, _ = cli("results", "junk", "--limit", "2")
        check("results come in pages with IDs and ~ paths",
              code == 0 and len(out["result"]["items"]) == 2 and out["result"]["items"][0]["path"].startswith("~/")
              and out["result"]["next_cursor"], out)
        cursor = out["result"]["next_cursor"] if code == 0 else ""
        code, out, _ = cli("results", "junk", "--cursor", cursor)
        check("the cursor continues where the page ended", code == 0 and out["result"]["items"][0]["id"] == "item-3", out)
        code, out, _ = cli("results", "junk", "--cursor", "other:1")
        check("a stale cursor is refused", code == 6 and out.get("reason") == "invalid_arguments", out)
        code, out, _ = cli("results", "large_files")
        check("a module not opened yet answers not_yet_available", code == 6 and out.get("reason") == "not_yet_available", out)
        code, out, _ = cli("requests")
        check("no requests yet", code == 0 and out["result"]["items"] == [], out)

        request_id = host.command("propose")["request"]
        code, out, _ = cli("request", request_id)
        check("the client reads its own request", code == 0 and out["result"]["request"]["state"] == "waiting_for_user", out)
        code, out, _ = cli("cancel-request", request_id)
        check("the client withdraws its own request", code == 0 and out["result"]["request"]["state"] == "cancelled", out)

        # --- MCP, both generations, through a real process.
        mcp = MCP(bridge, evidence / "mcp-legacy.jsonl")
        response = mcp.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "e2e-legacy", "version": "1"}})
        check("legacy handshake negotiates 2025-06-18", response["result"]["protocolVersion"] == "2025-06-18", response)
        mcp.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        response = mcp.call("tools/list")
        check("legacy tools/list shows 24 tools", len(response["result"]["tools"]) == 24, response)
        response = mcp.call("ping")
        check("legacy ping answers", response["result"] == {}, response)
        response = mcp.call("tools/call", {"name": "get_overview", "arguments": {}})
        result = response["result"]
        check("legacy tools/call returns structured content and the same JSON as text",
              result["structuredContent"]["app"]["name"] == "QA" and json.loads(result["content"][0]["text"]) == result["structuredContent"], result)
        response = mcp.call("tools/call", {"name": "start_scan", "arguments": {"module": "junk"}})
        check("a refusal is a tool result with isError", response["result"].get("isError") is True
              and "insufficient_permission" in response["result"]["content"][0]["text"], response)
        response = mcp.call("tools/call", {"name": "no_such_tool", "arguments": {}})
        check("an unknown tool is -32602", response["error"]["code"] == -32602, response)
        status, seconds = mcp.close()
        check("closing stdin ends the bridge at once", status == 0 and seconds < 2, f"{status} after {seconds:.2f}s")

        mcp = MCP(bridge, evidence / "mcp-modern.jsonl")
        response = mcp.call("server/discover", {"_meta": MODERN_META})
        result = response["result"]
        check("modern server/discover has every required field",
              result["resultType"] == "complete" and "2026-07-28" in result["supportedVersions"] and result["ttlMs"] > 0
              and result["cacheScope"] == "private" and result["_meta"]["io.modelcontextprotocol/serverInfo"]["name"] == "storage-cleaner-qa", result)
        response = mcp.call("tools/list", {"_meta": MODERN_META})
        check("modern tools/list has ttlMs and cacheScope", response["result"]["ttlMs"] > 0 and response["result"]["cacheScope"] == "private", "")
        response = mcp.call("tools/call", {"name": "get_health", "arguments": {}, "_meta": MODERN_META})
        check("modern tools/call is complete and structured",
              response["result"]["resultType"] == "complete" and response["result"]["structuredContent"]["score"] == 90, response)
        response = mcp.call("tools/call", {"name": "get_health", "arguments": {}, "_meta": {**MODERN_META, "io.modelcontextprotocol/protocolVersion": "1900-01-01"}})
        check("an unknown version is -32022 with the supported list", response["error"]["code"] == -32022 and response["error"]["data"]["requested"] == "1900-01-01", response)
        mcp.close()

        mcp = MCP(bridge, evidence / "mcp-errors.jsonl")
        response = mcp.raw("{not json")
        check("bad JSON is -32700 with no id", response["error"]["code"] == -32700 and "id" not in response, response)
        response = mcp.raw(json.dumps([{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}]))
        check("a batch is -32600", response["error"]["code"] == -32600 and "id" not in response, response)
        response = mcp.raw("x" * (300 * 1024))
        check("an overlong line is -32600", response["error"]["code"] == -32600, response)
        response = mcp.call("resources/list", {"_meta": MODERN_META})
        check("an unknown method is -32601", response["error"]["code"] == -32601, response)
        response = mcp.call("tools/list")
        check("no handshake and no _meta is -32600", response["error"]["code"] == -32600, response)
        response = mcp.call("tools/call", {"name": "get_health", "arguments": {"extra": 1}, "_meta": MODERN_META})
        check("an extra argument is -32602", response["error"]["code"] == -32602, response)
        mcp.close()

        # --- Who else may connect. The probe has no checks of its own, so what
        # it sees is the App's decision alone.
        other = work / "Other.app/Contents/Helpers"
        other.mkdir(parents=True)
        probe = other / "storage-cleaner-agent"
        shutil.copy2(binaries / "AgentFixtureProbe", probe)
        sign(probe, "-i", BRIDGE_ID)
        code, out = probe_program(probe, socket_path)
        check("right identifier, wrong place: the App hangs up without a word", out == "HUNGUP", out)

        raw = socket.socket(socket.AF_UNIX)
        raw.settimeout(5)
        raw.connect(str(socket_path))
        check("any other program (this script) gets no byte", raw.recv(100) == b"")
        raw.close()

        replace_file(binaries / "AgentFixtureProbe", bridge)
        sign(bridge, "-i", BRIDGE_ID)
        code, out = probe_program(bridge, socket_path)
        check("right path and identifier, other bytes: refused by cdhash", out == "HUNGUP", out)
        sign(bridge, "-i", "com.example.not-the-bridge")
        code, out = probe_program(bridge, socket_path)
        check("right path, wrong identifier: refused", out == "HUNGUP", out)
        replace_file(signed_bridge, bridge)
        code, out = probe_program(binaries / "AgentFixtureProbe", socket_path)
        check("an unsigned-path copy from the build folder: refused", out == "HUNGUP", out)
        code, out, _ = cli("status")
        check("positive control: the real bridge back in place works again", code == 0, out)

        # --- A false App. The real bridge must not talk to it.
        host.quit()
        hosts.remove(host)
        check("quitting removes the socket", not socket_path.exists())

        fake_directory = work / "Fake.app/Contents/MacOS"
        fake_directory.mkdir(parents=True)
        fake_program = fake_directory / "AgentFixtureHost"
        shutil.copy2(binaries / "AgentFixtureHost", fake_program)
        sign(fake_program, "-i", QA_ID)
        fake = Host(fake_program, root, evidence, "--accept-any-peer")
        hosts.append(fake)
        fake.command("on")
        code, out, _ = cli("status")
        check("the App's identifier at another path: the bridge refuses it", code == 1 and out.get("reason") == "app_unverified", out)
        fake.quit()
        hosts.remove(fake)

        received = []
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(socket_path))
        os.chmod(socket_path, 0o600)
        listener.listen(4)
        listener.settimeout(10)

        def serve():
            try:
                connection, _ = listener.accept()
                connection.settimeout(5)
                received.append(connection.recv(4096))
                connection.close()
            except OSError as error:
                received.append(error)

        thread = threading.Thread(target=serve)
        thread.start()
        code, out, _ = cli("status")
        thread.join(15)
        listener.close()
        check("a planted socket: refused", code == 1 and out.get("reason") == "app_unverified", out)
        check("nothing is sent to it, not even the request", received == [b""], received)
        os.unlink(socket_path)

        socket_path.write_text("not a socket")
        code, out, _ = cli("status")
        check("a plain file in its place: refused", code == 1 and out.get("reason") == "app_unverified", out)
        socket_path.unlink()
        os.symlink("/private/tmp/nothing-here", socket_path)
        code, out, _ = cli("status")
        check("a link in its place: refused", code == 1 and out.get("reason") == "app_unverified", out)
        socket_path.unlink()

        # --- The switch while a client stays connected.
        host = Host(host_program, root, evidence)
        hosts.append(host)
        host.command("on")
        mcp = MCP(bridge, evidence / "mcp-switch.jsonl")
        mcp.call("initialize", {"protocolVersion": "2025-11-25", "capabilities": {}})
        mcp.call("tools/call", {"name": "get_health", "arguments": {}})
        host.command("approve read_only")
        response = mcp.call("tools/call", {"name": "get_health", "arguments": {}})
        check("approval takes effect on the open connection", "structuredContent" in response["result"], response)
        host.command("off")
        response = mcp.call("tools/call", {"name": "get_health", "arguments": {}})
        check("switch off: a connected client reads interface_off", "interface_off" in response["result"]["content"][0]["text"], response)
        response = mcp.call("tools/list")
        check("the catalog still answers while off", len(response["result"]["tools"]) == 24, "")
        host.command("on")
        response = mcp.call("tools/call", {"name": "get_health", "arguments": {}})
        check("switch on again: the same bridge reconnects", "structuredContent" in response["result"], response)

        # --- The limit, on one connection.
        for index in range(40):
            mcp.send({"jsonrpc": "2.0", "id": f"burst-{index}", "method": "tools/call", "params": {"name": "get_health", "arguments": {}}})
        burst = [json.loads(mcp.lines.read(15)) for _ in range(40)]
        limited = [line for line in burst if line["result"].get("isError") and "rate_limited" in line["result"]["content"][0]["text"]]
        answered = [line for line in burst if "structuredContent" in line["result"]]
        check("a burst hits the limit with a clear refusal", limited and len(answered) <= 20, f"{len(answered)} answered, {len(limited)} limited")
        time.sleep(1.2)
        response = mcp.call("tools/call", {"name": "get_health", "arguments": {}})
        check("after a pause the same connection works again", "structuredContent" in response["result"], response)
        mcp.close()

        # --- A crash leaves a socket file behind.
        host.kill()
        hosts.remove(host)
        check("a killed App leaves its socket file", socket_path.exists())
        code, out, _ = cli("status")
        check("the leftover socket reads as off or not running, exit 4", code == 4, out)
        host = Host(host_program, root, evidence)
        hosts.append(host)
        check("the next start replaces the leftover socket", host.command("on")["status"] == "listening")

        # --- The official TypeScript SDK as an independent client.
        if sdk and sdk.exists():
            code, out, error = run("node", Path(__file__).with_name("sdk_client.mjs"), sdk, bridge, timeout=60)
            (evidence / "sdk-client.json").write_text(out + error, encoding="utf-8")
            try:
                report = json.loads(out)
            except json.JSONDecodeError:
                report = {}
            check("official SDK: connects (it negotiates its own version)", code == 0 and report.get("serverVersion"), out + error)
            check("official SDK: lists 24 tools", report.get("tools") == 24, report)
            # After the restart above this client is undecided again.
            check("official SDK: a refusal arrives as isError", report.get("beforeApproval") is True, report)
            host.command("approve read_only")
            code, out, error = run("node", Path(__file__).with_name("sdk_client.mjs"), sdk, bridge, timeout=60)
            (evidence / "sdk-client-approved.json").write_text(out + error, encoding="utf-8")
            try:
                report = json.loads(out)
            except json.JSONDecodeError:
                report = {}
            check("official SDK: structured results pass its own output-schema check", report.get("overview") == "QA" and report.get("results") == 5, out + error)
            check("official SDK: an unknown tool is a protocol error", report.get("unknownTool") == -32602, report)
        else:
            print("NOT_RUN official SDK client: no --sdk directory", flush=True)

        # --- Every recorded conversation against the official JSON Schema.
        if schemas and schemas.exists() and sdk:
            modules = sdk.parent.parent
            for version, names in (("2025-06-18", ["mcp-legacy.jsonl"]), ("2025-11-25", ["mcp-switch.jsonl"]),
                                   ("2026-07-28", ["mcp-modern.jsonl", "mcp-errors.jsonl"])):
                code, out, error = run("node", Path(__file__).with_name("validate_transcript.mjs"), modules, schemas, version,
                                       *[evidence / name for name in names], timeout=60)
                (evidence / f"schema-{version}.json").write_text(out + error, encoding="utf-8")
                check(f"official {version} JSON Schema accepts every response", code == 0, out + error)
        else:
            print("NOT_RUN official JSON Schema check: no --schemas directory", flush=True)

        # --- What the records hold.
        entries = [json.loads(line) for line in (root / "Agent/access.jsonl").read_text(encoding="utf-8").splitlines()]
        keys = set().union(*(entry.keys() for entry in entries))
        check("the access log holds who, tool and outcome, never arguments or results",
              keys <= {"time", "client", "clientKey", "tool", "level", "outcome", "reason", "requestID"}, keys)
        check("the access log is private", stat.S_IMODE(os.lstat(root / "Agent/access.jsonl").st_mode) == 0o600)
        (evidence / "access-log-sample.jsonl").write_text("\n".join(json.dumps(entry, ensure_ascii=False) for entry in entries[-5:]) + "\n", encoding="utf-8")
        for name in ("mcp-legacy.jsonl", "mcp-modern.jsonl", "mcp-switch.jsonl"):
            check(f"{name} was written", (evidence / name).stat().st_size > 0)
        host.quit()
        hosts.remove(host)
    finally:
        for host in hosts:
            host.kill()
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(root, ignore_errors=True)

    failed = [result for result in results if not result["passed"]]
    (evidence / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed. Evidence: {evidence}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
