#!/usr/bin/env python3
"""Check real assertion renewals, heartbeat expiry, and SIGKILL cleanup without a UI lock."""
import re
import subprocess
import time
from pathlib import Path

root = Path(__file__).resolve().parents[2]
probe = root / ".build" / "keep-awake-probe"


def assertions(pid):
    output = subprocess.check_output(["/usr/bin/pmset", "-g", "assertions"], text=True)
    return re.findall(rf"^\s*pid {pid}\([^\n]*SoftLock: active input session[^\n]*$", output, re.M)


def expect(pid, count):
    limit = time.monotonic() + 5
    while time.monotonic() < limit:
        lines = assertions(pid)
        if len(lines) == count:
            if count:
                for kind in ("PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep", "PreventSystemSleep"):
                    assert any(kind in line for line in lines), kind
            return
        time.sleep(0.1)
    raise AssertionError(f"Expected {count} assertions for probe PID {pid}, got {len(lines)}")


proc = subprocess.Popen([str(probe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
try:
    ready = proc.stdout.readline().strip()
    assert ready.startswith("READY "), ready
    lease = float(re.search(r"LEASE=([0-9.]+)", ready).group(1))
    actual_ac = ready.endswith("AC=true")
    expect(proc.pid, 0)

    def send(command, active):
        proc.stdin.write(command + "\n")
        proc.stdin.flush()
        reply = proc.stdout.readline().strip()
        assert reply == f"ACTIVE={str(active).lower()}", reply
        expect(proc.pid, 3 if active else 0)

    send("lock", actual_ac)
    send("battery", False)
    send("ac", True)
    send("unlock", False)
    send("lock", True)
    started = time.monotonic()
    while time.monotonic() - started < lease + 1:
        time.sleep(1)
        send("renew", True)
    # readLine blocks the probe's main thread, deliberately withholding renewal.
    time.sleep(lease + 1)
    send("status", False)
    send("renew", True)
    proc.kill()
    proc.wait(timeout=5)
    expect(proc.pid, 0)
    print(f"PASS native assertions: real AC={actual_ac}; power transitions, renewal, heartbeat expiry/re-arm, SIGKILL cleanup")
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait(timeout=5)
