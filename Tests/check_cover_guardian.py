"""Exercises the real IPC/watchdog process in headless mode: no windows, brightness, input, or OS lock."""
import json, subprocess, sys, time, select
from pathlib import Path

binary = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "dist/DeskVeil.app/Contents/MacOS/SoftLock"
def child():
    return subprocess.Popen([str(binary), "--transition-cover-guardian", "--headless"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
def send(p, action, id):
    p.stdin.write((json.dumps({"action": action, "id": id, "duration": 0, "reason": "", "retry": "", "emergency": ""})+"\n").encode())
def reply(p):
    assert select.select([p.stdout], [], [], 3)[0], "no reply"
    return json.loads(p.stdout.readline())
def close(p):
    if p.poll() is None: p.kill(); p.wait()
    if not p.stdin.closed: p.stdin.close()
    p.stdout.close(); p.stderr.close()

for case in ["watchdog-visible", "retry-and-stale-command"]:
    p=child(); started=time.monotonic()
    try:
        send(p,"show",1); assert reply(p)=={"id":1,"state":"covered"}
        if case=="watchdog-visible":
            assert p.wait(timeout=7)==0
            assert 3.5 <= time.monotonic()-started < 7
        else:
            send(p,"failure",2); assert reply(p)=={"id":2,"state":"failure"}
            send(p,"show",3); assert reply(p)=={"id":3,"state":"covered"}
            send(p,"hide",2); send(p,"invalid",999)
            send(p,"hide",4); assert reply(p)=={"id":4,"state":"released"}
            p.stdin.close(); assert p.wait(timeout=3)==0
        print(f"PASS cover guardian {case} ({time.monotonic()-started:.2f}s)",flush=True)
    finally: close(p)
