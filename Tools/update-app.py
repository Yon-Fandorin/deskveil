#!/usr/bin/env python3
"""Apply a verified local release after SoftLock itself confirms it is idle.

Never sends quit, termination signals, input events or brightness commands.
Use --background to leave a queued update running, or --cancel JOB to cancel it.
"""
import argparse
import ctypes
import datetime
import fcntl
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import select
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_guard", ROOT / "Tools/Distribution/release-guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class UpdateError(Exception):
    pass


def save(job, state, **fields):
    record = dict(state=state, pid=os.getpid(), at=datetime.datetime.now(datetime.timezone.utc).isoformat(), **fields)
    temporary = job / "status.next"
    temporary.write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(job / "status.json")


def validate_job(job):
    info = job.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise UpdateError("Update job must be an owned private directory")


def record_worker_failure(job, error):
    try:
        status = json.loads((job / "status.json").read_text())
    except (OSError, ValueError):
        status = {}
    if status.get("state") != "failed":
        save(job, "failed", reason=str(error))


def live_processes(targets):
    library = ctypes.CDLL("/usr/lib/libproc.dylib")
    library.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.proc_listallpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    count = library.proc_listallpids(None, 0)
    if count <= 0:
        raise UpdateError("Cannot enumerate running applications")
    pids = (ctypes.c_int * (count + 1024))()
    actual = library.proc_listallpids(pids, ctypes.sizeof(pids))
    if not 0 < actual < len(pids):
        raise UpdateError("Process inventory changed; retry the update")
    binaries = {str(path / "Contents/MacOS/SoftLock"): path for path in targets}
    found = {}
    for pid in pids[:actual]:
        if pid <= 0:
            continue
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) > 0:
            path = buffer.value.decode()
            if path in binaries:
                found[pid] = binaries[path]
            elif path.endswith("/Contents/MacOS/SoftLock"):
                app = Path(path).parents[2]
                try:
                    metadata = plistlib.loads((app / "Contents/Info.plist").read_bytes())
                except (OSError, ValueError):
                    continue
                if metadata.get("CFBundleIdentifier") == "dev.local.softlock":
                    raise UpdateError(f"Another SoftLock instance is running outside the destinations: {app}; it was left untouched")
    return found


def connect_gate(pid):
    path = Path(f"/private/tmp/softlock-update-{os.getuid()}/{pid}.sock")
    if not path.exists():
        return None  # Brightness/cover children share the executable, not the gate.
    connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        connection.settimeout(2)
        connection.connect(str(path))
        # LOCAL_PEERPID is kernel-supplied; a stale/replaced socket cannot claim
        # that an unrelated process is the running application we enumerated.
        library = ctypes.CDLL(None, use_errno=True)
        peer = ctypes.c_int()
        size = ctypes.c_uint(ctypes.sizeof(peer))
        if library.getsockopt(connection.fileno(), 0, 2, ctypes.byref(peer), ctypes.byref(size)) != 0 or peer.value != pid:
            raise UpdateError("Update socket belongs to another process")
        return connection
    except BaseException:
        connection.close()
        raise


def check_cancel(job):
    if (job / "cancel").exists():
        raise UpdateError("Update cancelled; no active session was terminated")


def acquire_build_lock(job, timeout=20):
    descriptor = os.open(ROOT / ".build/.softlock-build.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    stream = os.fdopen(descriptor, "a+b")
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise UpdateError("Build lock is not a regular file")
        deadline = time.monotonic() + timeout
        while True:
            check_cancel(job)
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
                check_cancel(job)
                return stream
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise UpdateError("Build is still running; existing app will resume without update")
                time.sleep(.1)
    except BaseException:
        stream.close()
        raise


def wait_for_idle(processes, version, job, connector=connect_gate, on_ready=lambda pid: None,
                  before_commit=lambda: None, renewal_interval=5):
    connections = {}
    buffers = {}
    ready = set()
    try:
        for pid in processes:
            connection = connector(pid)
            if connection is not None:
                connections[connection] = pid
                buffers[connection] = b""
                connection.sendall(json.dumps(dict(command="defer", version=version)).encode() + b"\n")
        if processes and not connections:
            raise UpdateError("Running version has no deferred-update support. It was left untouched; first installation requires closing it while unlocked.")
        last_reason = None
        next_renewal = time.monotonic() + renewal_interval
        while len(ready) != len(connections):
            check_cancel(job)
            if time.monotonic() >= next_renewal:
                for connection in ready:
                    connection.sendall(b'{"command":"renew"}\n')
                next_renewal = time.monotonic() + renewal_interval
            readable, _, _ = select.select(list(connections), [], [], min(0.2, renewal_interval))
            for connection in readable:
                data = connection.recv(4096)
                if not data:
                    raise UpdateError("Application exited without update readiness; no application was replaced")
                buffer = buffers[connection] + data
                if len(buffer) > 8192:
                    raise UpdateError("Invalid update response")
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    message = json.loads(line)
                    if message.get("pid") != connections[connection]:
                        raise UpdateError("Update response PID differs from its authenticated peer")
                    if message.get("state") == "ready":
                        ready.add(connection)
                    elif message.get("state") == "waiting":
                        reason = message.get("reason", "")
                        if reason != last_reason:
                            save(job, "waiting", reason=reason)
                            print("Update waiting:", reason, flush=True)
                            last_reason = reason
                    else:
                        raise UpdateError("Invalid update response state")
                buffers[connection] = buffer
        # Preparation never permits the owner to exit. Keep the channels alive
        # while acquiring the build lock, and record relaunch authority BEFORE
        # sending commit. Cancellation/disconnect before commit resumes the app.
        # Signature/digest verification can outlast the owner's readiness lease.
        # Keep prepared owners fenced until verification completes or fails.
        stop_renewing = threading.Event()
        renewal_errors = []
        def renew_prepared():
            try:
                while not stop_renewing.is_set():
                    for connection in ready:
                        connection.sendall(b'{"command":"renew"}\n')
                    if stop_renewing.wait(renewal_interval):
                        return
            except BaseException as error:
                renewal_errors.append(error)
        renewer = threading.Thread(target=renew_prepared, name="softlock-update-lease")
        renewer.start()
        try:
            before_commit()
        finally:
            stop_renewing.set()
            renewer.join()
        if renewal_errors:
            raise UpdateError("Application readiness connection was lost before commit") from renewal_errors[0]
        check_cancel(job)
        for connection, pid in connections.items():
            check_cancel(job)
            on_ready(pid)
            connection.sendall(b'{"command":"commit"}\n')
    finally:
        for connection in connections:
            connection.close()


def inspect_release(source, targets, expected=None):
    candidate = guard.inspect_bundle(source)
    if expected is not None and candidate != expected:
        raise UpdateError("Queued candidate changed; no application was replaced")
    previous = {}
    for target in targets:
        guard.validate_app_path(target)
        before = guard.inspect_bundle(target) if target.exists() else None
        guard.check_release(candidate, guard.baseline(), before)
        previous[str(target)] = before
    return candidate, previous


def rollback(targets, committed, previous, candidate, job):
    errors = []
    for target in reversed(committed):
        try:
            stamp = guard.snapshot_app(target)
            actual = guard.inspect_bundle(target) if target.exists() else None
            if live_processes(targets) or (actual is not None and actual != candidate):
                raise UpdateError("destination restarted or changed; preserved backups instead of overwriting it")
            if actual is None and previous[str(target)] is None:
                continue
            stage = Path(tempfile.mkdtemp(prefix=".softlock-rollback.", dir=target.parent))
            try:
                if previous[str(target)] is None:
                    # Preserve the new bundle rather than deleting it. There was
                    # no application at this path before the attempted update.
                    with guard.directory_lock(target.parent):
                        if live_processes(targets) or guard.app_stamp(target) != stamp or guard.inspect_bundle(target) != candidate:
                            raise UpdateError("new destination changed before rollback")
                        os.rename(target, stage / "retained.app")
                else:
                    archive = job / f"backup-{targets.index(target)}.app"
                    if guard.inspect_bundle(archive) != previous[str(target)]:
                        raise UpdateError("backup changed")
                    shutil.copytree(archive, stage / "restore.app", symlinks=True)
                    if guard.inspect_bundle(stage / "restore.app") != previous[str(target)]:
                        raise UpdateError("restoration copy differs from backup")
                    if live_processes(targets):
                        raise UpdateError("application restarted during rollback")
                    guard.publish_app(stage / "restore.app", target, stamp, stage / "previous.app")
            finally:
                if not (stage / "previous.app").exists() and not (stage / "retained.app").exists():
                    shutil.rmtree(stage)
        except BaseException as error:
            errors.append(f"{target}: {error}")
    return errors


def default_targets(candidate):
    """Include installed legacy copies so their running owners must approve too."""
    if candidate.name != "DeskVeil.app":
        return [ROOT / "dist/SoftLock.app", Path("/Applications/SoftLock.app")]
    current = [ROOT / "dist/DeskVeil.app", Path("/Applications/DeskVeil.app")]
    legacy = [ROOT / "dist/SoftLock.app", Path("/Applications/SoftLock.app")]
    return current + [path for path in legacy if path.exists()]


def relaunch_target(targets, reopened, applied):
    previous = next((target for target in targets if target in reopened), None)
    if applied and previous is not None and previous.name == "SoftLock.app":
        renamed = previous.with_name("DeskVeil.app")
        if renamed in targets:
            return renamed
    return previous


def apply(job):
    validate_job(job)
    plan = json.loads((job / "plan.json").read_text())
    targets = [Path(path) for path in plan["targets"]]
    source = job / "candidate.app"
    candidate, previous = inspect_release(source, targets, plan["candidate"])
    original = live_processes(targets)
    reopened = set()
    committed = []
    build_locks = []
    applied = False
    def prepare_commit():
        build_locks.append(acquire_build_lock(job))
        _, current = inspect_release(source, targets, candidate)
        if current != previous:
            raise UpdateError("Installed application changed while waiting; update stopped")
    try:
        wait_for_idle(original, candidate["version"], job, on_ready=lambda pid: reopened.add(original[pid]),
                      before_commit=prepare_commit)
        deadline = time.monotonic() + 15
        while live_processes(targets):
            if time.monotonic() >= deadline:
                raise UpdateError("App/helper exit not confirmed; no replacement or forced termination")
            time.sleep(0.1)
        check_cancel(job)
        if not build_locks:
            raise UpdateError("Missing update publication lock")
        candidate, current = inspect_release(source, targets, candidate)
        if current != previous or live_processes(targets):
            raise UpdateError("Installed app changed or restarted; update was not applied")
        stages = []
        try:
            for index, target in enumerate(targets):
                check_cancel(job)
                target.parent.mkdir(parents=True, exist_ok=True)
                stage = Path(tempfile.mkdtemp(prefix=".softlock-update.", dir=target.parent))
                stages.append((target, stage, guard.snapshot_app(target)))
                shutil.copytree(source, stage / "next.app", symlinks=True)
                if guard.inspect_bundle(stage / "next.app") != candidate:
                    raise UpdateError("Staged copy differs from verified candidate")
                if target.exists():
                    shutil.copytree(target, job / f"backup-{index}.app", symlinks=True)
                    if guard.inspect_bundle(job / f"backup-{index}.app") != previous[str(target)]:
                        raise UpdateError("Backup validation failed")
            for target, stage, stamp in stages:
                check_cancel(job)
                if live_processes(targets):
                    raise UpdateError("App restarted before publication; update stopped")
                try:
                    guard.publish_app(stage / "next.app", target, stamp, stage / "previous.app")
                except BaseException:
                    # Publication can commit both renames then fail during old
                    # backup cleanup. Reconcile that commit before rollback.
                    if not (stage / "next.app").exists() or ((stage / "previous.app").exists() and not target.exists()):
                        committed.append(target)
                    raise
                committed.append(target)
                if guard.inspect_bundle(target) != candidate:
                    raise UpdateError("Published app differs from candidate")
        finally:
            for _, stage, _ in stages:
                if not (stage / "previous.app").exists():
                    shutil.rmtree(stage)
        save(job, "applied", version=candidate["version"], targets=plan["targets"])
        applied = True
        print("Applied", candidate["version"], flush=True)
    except BaseException as error:
        errors = rollback(targets, committed, previous, candidate, job)
        save(job, "failed", reason=str(error), rollbackErrors=errors)
        if errors:
            raise UpdateError(str(error) + "; rollback incomplete; verified backups at " + str(job)) from error
        raise
    finally:
        for stream in build_locks:
            stream.close()
        # A cancelled/failed attempt after an idle shutdown restores availability,
        # but never interrupts or duplicates a still-running application.
        running = live_processes(targets) if reopened else {}
        if reopened and running:
            # A later peer's commit can fail after an earlier owner has accepted
            # commit but before that owner exits. Settle those exits before
            # deciding recovery; never terminate a surviving/uncommitted owner.
            deadline = time.monotonic() + 15
            while running and time.monotonic() < deadline:
                time.sleep(.1)
                running = live_processes(targets)
        if reopened and not running:
            target = relaunch_target(targets, reopened, applied)
            if target is not None:
                actual = guard.inspect_bundle(target)
                if actual not in (candidate, previous[str(target)]):
                    raise UpdateError("Cannot relaunch an unverified installed app")
                subprocess.run(["/usr/bin/open", "-g", "-n", str(target)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("candidate", type=Path, nargs="?")
    parser.add_argument("--destination", action="append", type=Path)
    parser.add_argument("--background", action="store_true")
    parser.add_argument("--worker", type=Path, help=argparse.SUPPRESS)
    parser.add_argument("--lock-fd", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--cancel", type=Path, metavar="JOB")
    args = parser.parse_args()
    if args.cancel:
        validate_job(args.cancel)
        (args.cancel / "cancel").touch(exist_ok=True)
        print("Cancellation requested")
        return
    (ROOT / ".build").mkdir(exist_ok=True)
    lock_path = ROOT / ".build/.softlock-update.lock"
    lock = args.lock_fd if args.worker and args.lock_fd is not None else os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(lock, "a+b") as stream:
        info = os.fstat(stream.fileno())
        named = lock_path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or (info.st_dev, info.st_ino) != (named.st_dev, named.st_ino):
            raise UpdateError("Invalid update lock")
        try:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise UpdateError("Another update is already queued") from error
        if args.worker:
            validate_job(args.worker)
            try:
                apply(args.worker)
            except BaseException as error:
                record_worker_failure(args.worker, error)
                raise
            return
        if not args.candidate:
            parser.error("candidate is required")
        source = args.candidate.absolute().parent.resolve() / args.candidate.name
        guard.validate_app_path(source)
        targets = [path.parent.resolve() / path.name for path in (args.destination or default_targets(source))]
        paths = [source, *targets]
        if any(left == right or left in right.parents or right in left.parents for i, left in enumerate(paths) for right in paths[i+1:]):
            raise UpdateError("Candidate and destination paths must be distinct and nonoverlapping")
        candidate, previous = inspect_release(source, targets)
        if all(value == candidate for value in previous.values()):
            print("Already installed; no update or restart needed")
            return
        job = Path(tempfile.mkdtemp(prefix="softlock-update-", dir=ROOT / ".build"))
        shutil.copytree(source, job / "candidate.app", symlinks=True)
        inspect_release(job / "candidate.app", targets, candidate)
        (job / "plan.json").write_text(json.dumps(dict(candidate=candidate, targets=[str(t) for t in targets]), indent=2))
        save(job, "prepared", version=candidate["version"])
        print("Update job:", job, flush=True)
        if args.background:
            with (job / "worker.log").open("x") as log:
                worker = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), "--worker", str(job),
                    "--lock-fd", str(stream.fileno())], stdin=subprocess.DEVNULL, stdout=log,
                    stderr=subprocess.STDOUT, start_new_session=True, pass_fds=(stream.fileno(),))
            print("Update worker:", worker.pid)
        else:
            apply(job)


if __name__ == "__main__":
    try:
        main()
    except (UpdateError, guard.GuardError, OSError, ValueError) as error:
        print("Update stopped:", error, file=sys.stderr)
        sys.exit(1)
