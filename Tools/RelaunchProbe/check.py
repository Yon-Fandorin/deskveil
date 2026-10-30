#!/usr/bin/env python3
"""Exercise NSWorkspace new-instance launch and original singleton admission.

Only a separately signed fixture is launched; no production app is controlled.
"""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / '.build/RelaunchProbe.app'
metadata = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())
assert metadata['CFBundleIdentifier'] == 'dev.local.softlock.relaunch-probe'
assert metadata['CFBundleExecutable'] == 'RelaunchProbe'
with tempfile.TemporaryDirectory(prefix='softlock-relaunch-probe-', dir='/private/tmp') as raw:
    output = Path(raw)
    os.chmod(output, 0o700)
    process = subprocess.Popen([str(APP / 'Contents/MacOS/RelaunchProbe'), '--probe-parent', '--probe-output', raw])
    try:
        assert process.wait(timeout=20) == 0, 'Fixture predecessor failed'
        deadline = time.monotonic() + 10
        while not (output / 'child.json').exists() and time.monotonic() < deadline:
            if (output / 'error.json').exists(): raise RuntimeError((output / 'error.json').read_text())
            time.sleep(.05)
        parent = json.loads((output / 'parent.json').read_text())
        child = json.loads((output / 'child.json').read_text())
        assert parent['pid'] == process.pid
        assert parent['authenticatedReadyPID'] == child['pid'] != process.pid
        assert child['parentAliveAtAdmission'] is False
        assert child['otherInstancesAtAdmission'] == 0
        assert child['usedOriginalInstallationFlow'] is True
        print('PASS native NSWorkspace restart: signed readiness, predecessor exit, original singleton admission; no production hooks')
        print(json.dumps({'parent': parent, 'child': child}, sort_keys=True))
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=5)
