#!/usr/bin/env python3
"""Cross-language real socket/peer-PID handshake; only starts the fixture probe."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import threading
import time

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('update_app',ROOT/'Tools/update-app.py')
update=importlib.util.module_from_spec(spec)
spec.loader.exec_module(update)
with tempfile.TemporaryDirectory(prefix='softlock-update-fixture-',dir='/private/tmp') as raw:
    directory=Path(raw)
    process=subprocess.Popen([str(ROOT/'.build/update-gate-probe'),raw],stdout=subprocess.PIPE,text=True)
    try:
        marker=process.stdout.readline().strip()
        if marker!=f'fixture-only {process.pid}': raise RuntimeError('Refusing a non-fixture process')
        errors=[]
        approved=[]
        def wait():
            try: update.wait_for_idle({process.pid:directory},'0.7.99',directory,on_ready=approved.append)
            except BaseException as error: errors.append(error)
        thread=threading.Thread(target=wait)
        thread.start()
        end=time.monotonic()+5
        while not (directory/'status.json').exists() and time.monotonic()<end: time.sleep(.02)
        status=json.loads((directory/'status.json').read_text())
        if status['state']!='waiting' or approved or process.poll() is not None:
            raise RuntimeError('Fixture did not retain its blocking session')
        (directory/'release').touch()
        thread.join(5)
        if thread.is_alive() or errors or approved!=[process.pid]: raise RuntimeError(str(errors))
        if process.wait(timeout=5)!=0: raise RuntimeError('Fixture did not finish cleanly')
        print('PASS native Swift gate + Python updater: authenticated peer PID, wait while blocked, ready only after release')
    finally:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=5)
