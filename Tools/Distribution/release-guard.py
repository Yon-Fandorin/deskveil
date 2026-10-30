#!/usr/bin/env python3
"""Fail closed before replacing a production app or publishing its disk image.

The checked-in baseline contains public release metadata, never private keys.
Migration flags authorize one operation; they do not rewrite that baseline.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import stat
import subprocess
import sys
from xml.parsers.expat import ExpatError

BASELINE = Path(__file__).with_name("production-baseline.json")
HELPER = Path("Contents/Helpers/SoftLockPower.app")


class GuardError(Exception):
    pass


def baseline():
    return json.loads(BASELINE.read_text())


def allowed(name):
    return os.environ.get("SOFTLOCK_ALLOW_" + name) == "1"


def require(condition, message, override=None):
    if not condition and not (override and allowed(override)):
        suffix = f" Intentional changes require SOFTLOCK_ALLOW_{override}=1." if override else ""
        raise GuardError(message + suffix)


def run(*arguments):
    result = subprocess.run([str(value) for value in arguments], capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise GuardError(f"{arguments[0]} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout + result.stderr


def signature(path):
    details = run("/usr/bin/codesign", "-d", "--verbose=4", "-r-", path)
    fields = {}
    for field in ["Identifier", "CDHash"]:
        match = re.search(rf"^{field}=(.+)$", details, re.MULTILINE)
        require(match is not None, f"Missing {field} in signature: {path}")
        fields[field] = match[1]
    requirement = re.search(r"^(?:# )?designated => (.+)$", details, re.MULTILINE)
    require(requirement is not None, f"Missing designated requirement: {path}")
    fields["requirement"] = requirement[1]
    return fields


def bundle_digest(path):
    """Compare the entire copied payload, including symlink destinations."""
    digest = hashlib.sha256()
    for entry in sorted(path.rglob("*")):
        relative = entry.relative_to(path).as_posix().encode()
        if entry.is_symlink():
            kind, content = b"L", os.readlink(entry).encode()
        elif entry.is_dir():
            kind, content = b"D", b""
        elif entry.is_file():
            kind, content = b"F", hashlib.sha256(entry.read_bytes()).digest()
        else:
            raise GuardError(f"Unexpected bundle entry: {entry}")
        mode = stat.S_IMODE(entry.lstat().st_mode).to_bytes(4, "big")
        digest.update(kind + len(relative).to_bytes(8, "big") + relative + mode + content)
    return digest.hexdigest()


def inspect_bundle(path, include_plan=True):
    path = Path(path)
    with (path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    with (path / HELPER / "Contents/Info.plist").open("rb") as stream:
        helper_info = plistlib.load(stream)
    run("/usr/bin/codesign", "--verify", "--strict", "--deep", path)
    app = signature(path)
    helper = signature(path / HELPER)
    require(app["Identifier"] == info.get("CFBundleIdentifier"), "App signing and bundle identifiers differ.")
    require(helper["Identifier"] == helper_info.get("CFBundleIdentifier"), "Helper signing and bundle identifiers differ.")
    result = {
        "bundleIdentifier": app["Identifier"], "appCDHash": app["CDHash"],
        "appRequirement": app["requirement"], "helperBundleIdentifier": helper["Identifier"],
        "helperCDHash": helper["CDHash"], "helperRequirement": helper["requirement"],
        "version": str(info.get("CFBundleShortVersionString", "")),
        "build": str(info.get("CFBundleVersion", "")),
    }
    if include_plan:
        check_static_identity(result, baseline())
        if not allowed("IDENTITY_MIGRATION"):
            # Enforce the actual signer as well as its displayed designated
            # requirement before invoking even the read-only application CLI.
            run("/usr/bin/codesign", "--verify", "--strict", "--deep",
                "-R=" + result["appRequirement"], path)
            run("/usr/bin/codesign", "--verify", "--strict",
                "-R=" + result["helperRequirement"], path / HELPER)
        # This CLI exits before AppKit, input filtering, installation or power control.
        plan = json.loads(run(path.resolve() / "Contents/MacOS/SoftLock", "--lid-install-plan"))
        require(plan.get("clientHash") == result["appCDHash"], "Installation plan and app signature differ.")
        require(plan.get("helperHash") == result["helperCDHash"], "Installation plan and bundled helper differ.")
        result["clientRequirement"] = plan.get("clientRequirement")
        result["protocolVersion"] = plan.get("protocol")
        result["bundleSHA256"] = bundle_digest(path)
    return result


def release_numbers(value):
    version, build = value["version"], value["build"]
    require(re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", version) is not None,
            f"Unsupported release version: {version!r}")
    require(re.fullmatch(r"[0-9]+", build) is not None, f"Unsupported build number: {build!r}")
    parts = tuple(int(part) for part in version.split("."))
    return parts + (0,) * max(0, 3 - len(parts)), int(build)


def expected_requirement(identifier, certificate):
    return f'identifier "{identifier}" and certificate leaf = H"{certificate}"'


def check_static_identity(candidate, reference):
    app_requirement = expected_requirement(reference["bundleIdentifier"], reference["certificateSHA1"])
    helper_requirement = expected_requirement(reference["helperBundleIdentifier"], reference["certificateSHA1"])
    require(candidate["bundleIdentifier"] == reference["bundleIdentifier"] and
            candidate["helperBundleIdentifier"] == reference["helperBundleIdentifier"] and
            candidate["appRequirement"] == app_requirement and
            candidate["helperRequirement"] == helper_requirement,
            "Production app/helper signing identity differs from the public baseline.", "IDENTITY_MIGRATION")


def check_release(candidate, reference, previous=None):
    check_static_identity(candidate, reference)
    require(candidate["clientRequirement"] == expected_requirement(
                reference["bundleIdentifier"], reference["certificateSHA1"]),
            "Installation client requirement differs from the public baseline.", "IDENTITY_MIGRATION")
    require(candidate["helperCDHash"] == reference["helperCDHash"] and
            candidate["protocolVersion"] == reference["protocolVersion"],
            "Bundled helper or IPC protocol changed; existing helper approval cannot be preserved.", "HELPER_CHANGE")
    references = [reference] + ([previous] if previous else [])
    version, build = release_numbers(candidate)
    for other in references:
        old_version, old_build = release_numbers(other)
        require(version >= old_version and build >= old_build,
                f"Release {candidate['version']} ({candidate['build']}) would downgrade "
                f"{other['version']} ({other['build']}).", "DOWNGRADE")
        require(not (version == old_version or build == old_build) or
                candidate["appCDHash"] == other["appCDHash"],
                "Changed app reuses a release version or build number.", "RELEASE_REPLACEMENT")
    if previous:
        require(candidate["appRequirement"] == previous["appRequirement"] and
                candidate["helperRequirement"] == previous["helperRequirement"],
                "Replacing this destination changes its approved signing identity.", "IDENTITY_MIGRATION")
        require(candidate["helperCDHash"] == previous["helperCDHash"],
                "Replacing this destination changes its approved helper.", "HELPER_CHANGE")


def file_stamp(path):
    path = Path(path)
    if not path.exists() and not path.is_symlink():
        return None
    require(not path.is_symlink() and path.is_file(), f"Output is not a regular file: {path}")
    info = path.stat()
    return {"device": info.st_dev, "inode": info.st_ino, "size": info.st_size,
            "mtimeNS": info.st_mtime_ns, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def check_output(path):
    stamp = file_stamp(path)
    require(stamp is None, f"Release output already exists: {path}", "RELEASE_REPLACEMENT")
    return stamp


@contextmanager
def directory_lock(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        os.close(descriptor)


def run_locked(lock_path, command):
    """Carry the build lock through exec, including if the launcher is killed."""
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(descriptor).st_mode), "Build lock is not a regular file.")
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        os.set_inheritable(descriptor, True)
        os.execvp(command[0], command)
    finally:
        os.close(descriptor)


def validate_app_path(path):
    """Only missing .app paths or real application bundles may be replaced."""
    path = Path(path)
    require(path.suffix == ".app", f"App path must end in .app: {path}")
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    require(stat.S_ISDIR(info.st_mode), f"App destination is not a real directory: {path}")
    for directory in [path / "Contents", path / "Contents/MacOS"]:
        require(not directory.is_symlink() and directory.is_dir(), f"Invalid app bundle directory: {directory}")
    plist = path / "Contents/Info.plist"
    require(not plist.is_symlink() and plist.is_file(), f"Missing real app Info.plist: {plist}")
    try:
        metadata = plistlib.loads(plist.read_bytes())
    except (ValueError, ExpatError) as error:
        raise GuardError(f"Invalid app Info.plist: {plist}") from error
    require(isinstance(metadata, dict) and metadata.get("CFBundlePackageType") == "APPL" and
            isinstance(metadata.get("CFBundleIdentifier"), str) and bool(metadata["CFBundleIdentifier"]),
            f"Invalid app bundle metadata: {plist}")
    executable = metadata.get("CFBundleExecutable")
    require(isinstance(executable, str) and executable not in ("", ".", "..") and
            Path(executable).name == executable, f"Invalid app executable name: {plist}")
    binary = path / "Contents/MacOS" / executable
    require(binary.exists() and not binary.is_symlink() and binary.is_file() and
            bool(binary.stat().st_mode & 0o111), f"Missing real app executable: {binary}")
    return True


def app_stamp(path):
    """Identify the full destination, including replaced but identical bundles."""
    path = Path(path)
    if not validate_app_path(path):
        return None
    identity = hashlib.sha256()
    for entry in [path, *sorted(path.rglob("*"))]:
        entry_info = entry.lstat()
        record = [entry.relative_to(path).as_posix(), entry_info.st_dev, entry_info.st_ino,
                  entry_info.st_mode, entry_info.st_size, entry_info.st_mtime_ns, entry_info.st_ctime_ns]
        identity.update(json.dumps(record).encode())
    return {"identitySHA256": identity.hexdigest(), "bundleSHA256": bundle_digest(path)}


def snapshot_app(path):
    with directory_lock(Path(path).parent):
        return app_stamp(path)


def publish_app(source, destination, expected, backup):
    """Revalidate under the publisher lock and retain the original on failure.

    Locks serialize cooperating publishers. Other writers (including Finder,
    direct swift builds, or deletion of the build lock) must be kept away during
    a build: advisory locks cannot close their check/rename or process-start races.
    """
    source, destination, backup = Path(source), Path(destination), Path(backup)
    paths = [path.resolve() for path in (source, destination, backup)]
    for index, left in enumerate(paths):
        for right in paths[index + 1:]:
            require(left != right and left not in right.parents and right not in left.parents,
                    "App publication paths must be distinct and must not contain one another.")
    with directory_lock(destination.parent):
        require(app_stamp(source) is not None, "Staged app is missing.")
        require(not os.path.lexists(backup), f"App backup already exists: {backup}")
        # Delay ordinary termination until commit/rollback has completed. SIGKILL
        # can still interrupt; the shell cleanup always preserves an extant backup.
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
        try:
            require(app_stamp(destination) == expected,
                    "App destination changed during build; nothing was replaced.")
            moved_previous = False
            try:
                if expected is not None:
                    os.rename(destination, backup)
                    moved_previous = True
                os.rename(source, destination)
            except BaseException as error:
                if moved_previous:
                    if not os.path.lexists(destination):
                        try:
                            os.rename(backup, destination)
                        except OSError as rollback_error:
                            raise GuardError(f"App rollback failed; original preserved at {backup}: {rollback_error}") from error
                    else:
                        raise GuardError(f"App destination changed during commit; original preserved at {backup}") from error
                raise
            if moved_previous:
                shutil.rmtree(backup)
        finally:
            signal.pthread_sigmask(signal.SIG_SETMASK, mask)


def publish(source, destination, expected):
    """Serialize guard publishers and revalidate immediately before publication.

    Writers outside this guard can still race an explicitly allowed replacement
    between revalidation and os.replace. The no-clobber path is atomic even for
    writers that do not honor this directory lock.
    """
    directory = os.open(Path(destination).parent, os.O_RDONLY)
    try:
        fcntl.flock(directory, fcntl.LOCK_EX)
        require(file_stamp(destination) == expected, "Release output changed during packaging; nothing was replaced.")
        if expected is None:
            # Both paths share a filesystem. link fails if another publisher wins.
            os.link(source, destination)
            Path(source).unlink()
        else:
            require(allowed("RELEASE_REPLACEMENT"), "Replacing a published release requires explicit authorization.")
            os.replace(source, destination)
    finally:
        os.close(directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("signing-pin")
    check = subparsers.add_parser("check")
    check.add_argument("app", type=Path)
    check.add_argument("--previous", type=Path)
    check.add_argument("--expected-manifest", type=Path)
    output = subparsers.add_parser("check-output")
    output.add_argument("path", type=Path)
    publish_parser = subparsers.add_parser("publish")
    publish_parser.add_argument("source", type=Path)
    publish_parser.add_argument("destination", type=Path)
    publish_parser.add_argument("--expected-output", type=Path, required=True)
    lock_parser = subparsers.add_parser("run-locked")
    lock_parser.add_argument("lock", type=Path)
    lock_parser.add_argument("arguments", nargs=argparse.REMAINDER)
    snapshot_parser = subparsers.add_parser("snapshot-app")
    snapshot_parser.add_argument("path", type=Path)
    validate_parser = subparsers.add_parser("validate-app-path")
    validate_parser.add_argument("path", type=Path)
    app_parser = subparsers.add_parser("publish-app")
    app_parser.add_argument("source", type=Path)
    app_parser.add_argument("destination", type=Path)
    app_parser.add_argument("--expected-output", type=Path, required=True)
    app_parser.add_argument("--backup", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "signing-pin":
        print(baseline()["certificateSHA1"])
    elif args.command == "check":
        candidate = inspect_bundle(args.app)
        previous = inspect_bundle(args.previous, include_plan=False) if args.previous and args.previous.exists() else None
        check_release(candidate, baseline(), previous)
        if args.expected_manifest:
            require(candidate == json.loads(args.expected_manifest.read_text()),
                    "Copied bundle differs from the verified source release.")
        print(json.dumps(candidate, sort_keys=True))
    elif args.command == "check-output":
        print(json.dumps(check_output(args.path), sort_keys=True))
    elif args.command == "publish":
        publish(args.source, args.destination, json.loads(args.expected_output.read_text()))
    elif args.command == "run-locked":
        require(bool(args.arguments), "Missing locked build command.")
        run_locked(args.lock, args.arguments)
    elif args.command == "snapshot-app":
        print(json.dumps(snapshot_app(args.path), sort_keys=True))
    elif args.command == "validate-app-path":
        validate_app_path(args.path)
    elif args.command == "publish-app":
        publish_app(args.source, args.destination, json.loads(args.expected_output.read_text()), args.backup)


if __name__ == "__main__":
    try:
        main()
    except (GuardError, OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        print(f"Release guard: {error}", file=sys.stderr)
        sys.exit(1)
