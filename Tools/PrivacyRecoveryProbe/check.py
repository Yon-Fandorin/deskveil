#!/usr/bin/env python3
"""Native signed recovery client/server; the fixture has no production backends."""
import json
import os
from pathlib import Path
import plistlib
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / '.build/PrivacyRecoveryProbe.app'
FOREIGN = ROOT / '.build/PrivacyRecoveryForeign.app'
for app, identifier in [(APP, 'dev.local.softlock.privacy-recovery-probe'),
                        (FOREIGN, 'dev.local.softlock.privacy-recovery-probe.foreign')]:
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert info['CFBundleIdentifier'] == identifier and info['CFBundleExecutable'] == 'PrivacyRecoveryProbe'
binary = APP / 'Contents/MacOS/PrivacyRecoveryProbe'
foreign = FOREIGN / 'Contents/MacOS/PrivacyRecoveryProbe'
with tempfile.TemporaryDirectory(prefix='softlock-privacy-recovery-probe-', dir='/private/tmp') as raw:
    output = Path(raw); os.chmod(output, 0o700)
    server = subprocess.Popen([str(binary), raw])
    bystander = subprocess.Popen([str(binary), raw, '--fixture-bystander'])
    updater = None
    def state(predicate, filename='state.json'):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                value = json.loads((output / filename).read_text())
                if predicate(value): return value
            except (OSError, ValueError): pass
            if server.poll() is not None: raise RuntimeError('Fixture server exited')
            time.sleep(.025)
        raise RuntimeError('Fixture state timed out')
    try:
        state(lambda x: x['available'])
        state(lambda x: x['finishedLaunching'] and not x['available'], 'bystander.json')
        updater = socket.socket(socket.AF_UNIX); updater.settimeout(3)
        updater.connect(f'/private/tmp/softlock-update-{os.getuid()}/{server.pid}.sock')
        updater.sendall(b'{"command":"defer","version":"0.7.99"}\n')
        state(lambda x: x['pendingUpdate'])
        rejected = subprocess.run([str(foreign), '--fixture-foreign-request', str(server.pid)],
                                  capture_output=True, text=True, timeout=5, check=True)
        assert rejected.stdout.strip() == 'rejected'
        assert state(lambda x: x['pendingUpdate'])['requests'] == 0
        revealed = subprocess.run([str(binary), '--reveal-screen'], capture_output=True, text=True, timeout=5, check=True)
        assert revealed.stdout.strip() == 'revealed', revealed
        current = state(lambda x: x['requests'] == 1 and not x['shield'])
        assert current['pendingUpdate']
        again = subprocess.run([str(binary), '--reveal-screen'], capture_output=True, text=True, timeout=5, check=True)
        assert again.stdout.strip() == 'not-active'
        assert state(lambda x: x['requests'] == 2)['pendingUpdate']
        updater.close(); updater = None
        state(lambda x: not x['pendingUpdate'])
        print('PASS native recovery: real signer/kernel PID/UID; foreign client rejected; same-bundle helper ignored; CLI acknowledged; updater independent')
    finally:
        if updater is not None: updater.close()
        (output / 'stop').touch()
        for process in [server, bystander]:
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: process.terminate(); process.wait(timeout=5)
