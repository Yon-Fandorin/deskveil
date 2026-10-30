"""Check the isolated in-memory guardian; never use the production display backend."""
import base64
import json
import os
from pathlib import Path
import subprocess
import select
import time
import sys

binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "dist/DeskVeil.app/Contents/MacOS/SoftLock"
if b"--brightness-guardian-fixture" not in binary.read_bytes():
    raise SystemExit("Rebuild SoftLock first: this binary does not provide the isolated guardian fixture.")

for command, expected in (
    ("restore-now@41", "restore-failed@41"),
    ("dim:0@1", "dimmed:0@1"),
    ("individual:" + base64.b64encode(json.dumps(dict(displayID=1, identity="fixture", off=True)).encode()).decode() + "@9", "individual-recovery-needed@9"),
):
    environment = dict(os.environ, SOFTLOCK_FIXTURE_RECOVERY_READ_FAILURE="1")
    child = subprocess.Popen(
        [str(binary), "--brightness-guardian-fixture"], env=environment,
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        child.stdin.write((command + "\n").encode()); child.stdin.flush()
        assert select.select([child.stdout], [], [], 3)[0], "no unreadable-recovery acknowledgement"
        assert child.stdout.readline().decode().strip() == expected
        child.stdin.write(b"restore-now@42\n"); child.stdin.flush()
        assert select.select([child.stdout], [], [], 3)[0], "no failed restore acknowledgement"
        assert child.stdout.readline().decode().strip() == "restore-failed@42"
        child.stdin.write(b"fixture-recovery-readable\nrestore-now@43\nquit\n"); child.stdin.flush()
        assert child.wait(timeout=8) == 0
        output = child.stdout.read().decode().strip()
        assert output == "restored@43", output
        writes = [json.loads(line) for line in child.stderr.read().decode().splitlines()]
        assert writes == [{"fixtureDisplay": 1, "value": 0.75}], writes
        print(f"PASS guardian unreadable-recovery {command.split(':', 1)[0]}")
    finally:
        if child.poll() is None:
            child.kill(); child.wait()
        child.stdin.close(); child.stdout.close(); child.stderr.close()

for case in ("closed-reply-pipe-and-heartbeat-timeout", "tagged-restore-and-quit", "query-after-completed-restore", "eof-after-dim", "individual-off-eof"):
    child = subprocess.Popen(
        [str(binary), "--brightness-guardian-fixture"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    started = time.monotonic()
    try:
        if case == "individual-off-eof":
            command = base64.b64encode(json.dumps(dict(displayID=1,identity="fixture",off=True)).encode()).decode()
            child.stdin.write(("individual:"+command+"@9\n").encode()); child.stdin.flush()
            assert select.select([child.stdout],[],[],3)[0], "no individual Off acknowledgement"
            assert child.stdout.readline().decode().strip() == "individual-off@9"
        else:
            child.stdin.write(b"dim:0@1\n"); child.stdin.flush()
            assert select.select([child.stdout],[],[],3)[0], "no dim acknowledgement"
            assert child.stdout.readline().decode().strip() == "dimmed:1@1"
        if case in ("eof-after-dim", "individual-off-eof"):
            child.stdin.close()
        elif case == "query-after-completed-restore":
            target = {"displayID": 1, "identity": "fixture"}
            payload = base64.b64encode(json.dumps(target).encode()).decode()
            child.stdin.write(("restore-now@42\nbrightness-status:" + payload + "@43\nquit\n").encode())
            child.stdin.flush()
        elif case == "tagged-restore-and-quit":
            child.stdin.write(b"restore-now@42\nquit\n")
            child.stdin.flush()
        else:
            child.stdout.close()
            child.stdin.write(b"ping\n")
            child.stdin.flush()
        assert child.wait(timeout=8) == 0, case
        output = child.stdout.read().decode().strip() if not child.stdout.closed else ""
        elapsed = time.monotonic() - started
        if case == "tagged-restore-and-quit":
            assert output == "restored@42", output
        if case == "query-after-completed-restore":
            restored, response = output.splitlines()
            assert restored == "restored@42", output
            message, identifier = response.rsplit("@", 1)
            assert identifier == "43" and message.startswith("brightness-status:"), output
            sample = json.loads(base64.b64decode(message.split(":", 1)[1]))
            assert sample["target"] == target and sample["value"] == 0.75, sample
        if case == "closed-reply-pipe-and-heartbeat-timeout":
            assert 3.5 <= elapsed < 7, elapsed
        writes = [json.loads(line) for line in child.stderr.read().decode().splitlines()]
        assert writes and writes[0] == {"fixtureDisplay":1,"value":0}, writes
        assert writes[-1] == {"fixtureDisplay":1,"value":0.75}, writes
        assert all(row["fixtureDisplay"] == 1 for row in writes), writes
        print(f"PASS guardian {case} ({elapsed:.2f}s)")
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        if not child.stdin.closed:
            child.stdin.close()
        child.stdout.close()
        child.stderr.close()
