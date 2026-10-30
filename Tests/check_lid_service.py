#!/usr/bin/env python3
"""Real native IPC/watchdog processes; file-backed power, never native pmset."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
BINARY = Path(os.environ.get("SOFTLOCK_LID_TEST_BINARY", str(ROOT / ".build/release/SoftLockPower"))).resolve()


class LidServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="softlock-lid-service-", dir="/private/tmp")
        self.directory = Path(self.temporary.name)
        self.save("power.json", {"disabled": False})
        self.save("source.json", {"acPower": True, "batteryPercent": 80})
        self.save("faults.json", {})
        self.process = None
        self.client = None
        self.stream = None

    def save(self, name, value):
        target = self.directory / name
        temporary = target.with_suffix(".new")
        temporary.write_text(json.dumps(value))
        temporary.replace(target)

    def read(self, name):
        return json.loads((self.directory / name).read_text())

    def records(self):
        path = self.directory / "session.jsonl"
        result = []
        for line in path.read_text().splitlines() if path.exists() else []:
            try:
                result.append(json.loads(line))
            except ValueError:
                pass
        return result

    def wait_for(self, predicate, seconds=4):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                if predicate():
                    return
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.01)
        self.fail("Condition not met; events=" + json.dumps(self.records()))

    def start(self, limit=30):
        self.limit = limit
        self.process = subprocess.Popen([str(BINARY), "--lid-service-simulate", str(self.directory),
                                         "--lease", "0.6"],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True)
        self.wait_for(lambda: (self.directory / "control.sock").exists())
        self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.client.settimeout(4)
        self.client.connect(str(self.directory / "control.sock"))
        self.stream = self.client.makefile("rwb", buffering=0)

    def request(self, active=True, **changes):
        message = dict(protocol=4, allowBattery=False, batteryReservePercent=10, durationSeconds=self.limit, requested=active, session="test-session", ready=True,
                       locked=True, awake=True, preparing=False, sessionReady=True, ac=True,
                       displayCount=1, displayQuery=0)
        message.update(changes)
        self.stream.write(json.dumps(message).encode() + b"\n")
        return json.loads(self.stream.readline())

    def activate(self, **changes):
        self.wait_for(lambda: self.request(**changes)["phase"] == "active")
        self.assertTrue(self.read("power.json")["disabled"])

    def restored(self):
        self.wait_for(lambda: not self.read("power.json")["disabled"] and
                      not (self.directory / "recovery.json").exists())

    def watchdog(self):
        return next(x["watchdogPID"] for x in self.records() if x["event"] == "ready")

    @contextmanager
    def locked_journal(self):
        # A diagnostic reader can take an advisory shared lock on the 0644 log.
        # Keep it held until both the supervisor and watchdog have recovered.
        path = self.directory / "session.jsonl"
        path.touch(exist_ok=True)
        with path.open("rb") as reader:
            fcntl.flock(reader, fcntl.LOCK_SH | fcntl.LOCK_NB)
            try:
                yield
            finally:
                fcntl.flock(reader, fcntl.LOCK_UN)

    def tearDown(self):
        if self.stream:
            self.stream.close()
        if self.client:
            self.client.close()
        if self.process and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=4)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait(timeout=4)
        # The independent child must release the inherited lease before cleanup.
        if self.process and any(x["event"] == "ready" for x in self.records()):
            deadline = time.monotonic() + 3
            while (self.directory / "recovery.json").exists() and time.monotonic() < deadline:
                time.sleep(0.02)
        self.temporary.cleanup()

    def test_repeated_lock_unlock_preserves_service_without_reauthorization(self):
        self.start()
        for session in ["first", "second"]:
            self.activate(session=session)
            self.request(False, session=session)
            self.restored()
            self.request(False, session=session)
        self.assertIsNone(self.process.poll())

    def test_existing_policy_is_preserved_even_on_service_stop(self):
        self.save("power.json", {"disabled": True})
        self.start()
        self.assertEqual(self.request()["reason"], "existing-power-policy")
        self.process.terminate()
        self.process.wait(timeout=4)
        self.assertTrue(self.read("power.json")["disabled"])
        self.assertFalse((self.directory / "recovery.json").exists())

    def test_invalid_recovery_receipt_cannot_change_an_existing_policy(self):
        self.save("power.json", {"disabled": True})
        self.save("recovery.json", {"baselineDisabled": True})
        self.process = subprocess.Popen([str(BINARY), "--lid-service-simulate", str(self.directory)],
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
        self.assertNotEqual(self.process.wait(timeout=3), 0)
        self.assertTrue(self.read("power.json")["disabled"])

    def test_app_stall_and_scope_losses_restore_without_reactivating(self):
        self.start()
        for changes in [dict(ac=False), dict(sessionReady=False), dict(ready=False)]:
            self.save("source.json", {"acPower": True, "batteryPercent": 80})
            self.activate()
            if changes.get("ac") is False:
                self.save("source.json", {"acPower": False, "batteryPercent": 80})
            self.request(**changes)
            self.restored()
            self.request(False)
        self.activate()
        self.restored()  # No heartbeat: the app remains alive with its socket open.
        time.sleep(0.3)
        self.assertFalse(self.read("power.json")["disabled"])

    def test_supervisor_sigkill_restores_with_independent_watchdog(self):
        self.start()
        self.activate()
        self.process.kill()
        self.process.wait(timeout=3)
        self.restored()

    def test_supervisor_stall_is_killed_before_restoring(self):
        self.start()
        self.activate()
        os.kill(self.process.pid, signal.SIGSTOP)
        self.restored()
        self.process.wait(timeout=3)
        self.assertEqual(self.process.returncode, -signal.SIGKILL)

    def test_watchdog_death_is_recovered_by_supervisor(self):
        self.start()
        self.activate()
        os.kill(self.watchdog(), signal.SIGKILL)
        self.restored()
        self.process.wait(timeout=3)

    def test_held_log_lock_does_not_block_startup_or_release(self):
        with self.locked_journal():
            self.start()
            self.activate()
            self.request(False)
            self.restored()
            self.assertIsNone(self.process.poll())

    def test_held_log_lock_does_not_block_independent_watchdog_recovery(self):
        self.start()
        self.activate()
        with self.locked_journal():
            self.process.kill()
            self.process.wait(timeout=3)
            self.restored()

    def test_held_log_lock_does_not_block_supervisor_recovery(self):
        self.start()
        self.activate()
        watchdog = self.watchdog()
        with self.locked_journal():
            os.kill(watchdog, signal.SIGKILL)
            self.restored()
            self.process.wait(timeout=3)

    def test_held_log_lock_does_not_block_previous_session_recovery(self):
        self.save("power.json", {"disabled": True})
        self.save("recovery.json", {"baselineDisabled": False})
        with self.locked_journal():
            self.start()
            self.restored()

    def test_partial_activation_failure_does_not_leave_power_disabled(self):
        self.save("faults.json", {"failAfterEnable": True})
        self.start()
        self.assertEqual(self.request()["phase"], "recovering")
        self.restored()
        self.assertTrue(any(x["event"] == "error" for x in self.records()))

    def test_orphaned_enable_cannot_run_after_recovery(self):
        self.save("faults.json", {"delayedEnable": True})
        self.start()
        self.client.sendall(json.dumps(dict(protocol=4, allowBattery=False, batteryReservePercent=10, durationSeconds=self.limit, requested=True, session="orphan", ready=True,
                                            locked=True, awake=True, sessionReady=True)).encode() + b"\n")
        self.wait_for(lambda: (self.directory / "inflight.json").exists())
        self.process.kill()
        self.process.wait(timeout=3)
        self.restored()
        time.sleep(1.4)
        self.assertFalse(self.read("power.json")["disabled"])

    def test_restart_receipt_and_session_deadline(self):
        self.save("power.json", {"disabled": True})
        self.save("recovery.json", {"baselineDisabled": False})
        self.start(limit=0.5)
        self.restored()
        self.activate()
        deadline = time.monotonic() + 2
        while self.read("power.json")["disabled"] and time.monotonic() < deadline:
            self.request(durationSeconds=0)  # Heartbeats cannot extend the chosen deadline.
            time.sleep(0.03)
        self.restored()
        self.assertTrue(any(x.get("reason") == "session-limit" for x in self.records()))

    def test_unlimited_keeps_running_but_still_recovers_on_scope_loss(self):
        self.start(limit=0)
        self.activate()
        until = time.monotonic() + 1.2
        while time.monotonic() < until:
            # A later heartbeat must not add a deadline to this session either.
            state = self.request(durationSeconds=0.3)
            self.assertEqual(state["phase"], "active")
            self.assertEqual(state["remainingSeconds"], -1)
            time.sleep(0.1)
        self.save("source.json", {"acPower": False, "batteryPercent": 80})
        self.request(ac=False)
        self.restored()
        self.assertTrue(any(x.get("reason") == "power-disconnected" for x in self.records()))

    def test_battery_opt_in_survives_power_transitions_and_restores_at_reserve(self):
        self.save("source.json", {"acPower": False, "batteryPercent": 80})
        self.start(limit=0)
        self.activate(allowBattery=True, batteryReservePercent=35)
        started = self.request(allowBattery=True, batteryReservePercent=35)["startedAt"]
        for source in [{"acPower": True}, {"acPower": False, "batteryPercent": 36}]:
            self.save("source.json", source)
            # A later heartbeat cannot change the active session's battery policy.
            state = self.request(allowBattery=False, batteryReservePercent=10)
            self.assertEqual(state["phase"], "active")
            self.assertTrue(state["allowBattery"])
            self.assertEqual(state["batteryReservePercent"], 35)
            self.assertEqual(state["startedAt"], started)
        self.save("source.json", {"acPower": False, "batteryPercent": 35})
        self.request(allowBattery=True, batteryReservePercent=10, ac=True)  # Client-reported power cannot override the backend.
        self.restored()
        self.assertTrue(any(x.get("reason") == "battery-low" for x in self.records()))
        self.assertEqual(sum(x["event"] == "active" for x in self.records()), 1)

    def test_battery_start_requires_opt_in_and_known_capacity_above_reserve(self):
        self.start()
        for option, percent, reason in [(False, 80, "power-required"), (True, 10, "battery-low"),
                                        (True, None, "battery-unavailable"), (True, 101, "battery-unavailable")]:
            self.save("source.json", {"acPower": False, "batteryPercent": percent})
            state = self.request(allowBattery=option)
            self.assertEqual(state["phase"], "failed")
            self.assertEqual(state["reason"], reason)
            self.assertFalse(self.read("power.json")["disabled"])
            self.request(False)
        self.assertFalse(any(x["event"] == "active" for x in self.records()))

    def test_missing_or_invalid_power_policy_never_enables_power(self):
        self.start()
        invalid = [("durationSeconds", value) for value in [None, True, -1, "0", 40000000]]
        invalid += [("allowBattery", value) for value in [None, 0, 1, "true"]]
        invalid += [("batteryReservePercent", value) for value in [None, True, 0, 5, 11, 81, 25.5, "20"]]
        for index, (field, value) in enumerate(invalid):
            # Reconnect because invalid IPC closes its connection.
            if index > 0:
                self.stream.close()
                self.client.close()
                self.client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.client.settimeout(4)
                self.client.connect(str(self.directory / "control.sock"))
                self.stream = self.client.makefile("rwb", buffering=0)
            message = dict(protocol=4, allowBattery=False, batteryReservePercent=10, requested=True, session="invalid", ready=True,
                           locked=True, awake=True, sessionReady=True, ac=True, durationSeconds=0)
            if value is None: message.pop(field)
            else: message[field] = value
            self.stream.write(json.dumps(message).encode() + b"\n")
            self.assertEqual(self.stream.readline(), b"")
            self.assertFalse(self.read("power.json")["disabled"])
        self.assertFalse(any(x["event"] == "active" for x in self.records()))


if __name__ == "__main__":
    if os.geteuid() == 0:
        raise SystemExit("Refusing simulation tests as root")
    unittest.main(verbosity=2)
