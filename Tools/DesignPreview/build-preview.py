#!/usr/bin/env python3
"""Stage and publish an isolated native audit preview, preserving other apps."""
import ctypes
import importlib.util
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


PROJECT = Path(__file__).resolve().parents[2]


def load_module(name, path):
    specification = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


GUARD = load_module("softlock_preview_release_guard", PROJECT / "Tools/Distribution/release-guard.py")
AUDIT = load_module("softlock_native_audit_runner", Path(__file__).with_name("run-native-audit.py"))
SOURCES = ["Localization", "Brand", "ControlWindow", "SteppedSetting", "KeepAwake", "LidDuration", "DisclosureSection",
           "QuickMenu", "MenuDashboard", "StatusDashboard", "DisplayStatus", "DisplayBrightness", "DisplayIdentification",
           "IndividualDisplays", "Shortcut", "ShortcutRecorder", "DisplayTransition", "Brightness",
           "DDCBrightness", "BrightnessRecovery", "DisplayGamma", "OperationReplies", "Installation", "LidPower", "RelaunchHandoff"]


class PreviewBuildError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise PreviewBuildError(message)


def validate_identifier(identifier):
    require(isinstance(identifier, str) and
            re.fullmatch(r"dev\.local\.softlock\.[A-Za-z0-9][A-Za-z0-9.-]*", identifier) is not None and
            identifier != "dev.local.softlock.power", "Use a separate dev.local.softlock.* preview bundle identifier")


def preview_path(raw, project=PROJECT, home=None):
    raw = Path(raw).expanduser().absolute()
    require(not raw.is_symlink(), f"Preview destination cannot be a symlink: {raw}")
    path = raw.parent.resolve() / raw.name
    require(path.suffix == ".app", f"Preview destination must end in .app: {path}")
    production = [Path(project) / "dist/SoftLock.app", Path("/Applications/SoftLock.app"),
                  Path(home or Path.home()) / "Applications/SoftLock.app",
                  Path(project) / "dist/DeskVeil.app", Path("/Applications/DeskVeil.app"),
                  Path(home or Path.home()) / "Applications/DeskVeil.app"]
    for protected in production:
        protected = protected.resolve()
        require(path != protected and protected not in path.parents and path not in protected.parents,
                f"Preview destination is a production app path: {path}")
    require(not any(parent.suffix == ".app" for parent in path.parents),
            f"Preview destination cannot be inside another app: {path}")
    return path


def validate_existing_preview(path):
    require(not path.is_symlink(), f"Preview destination cannot be a symlink: {path}")
    if not path.exists():
        return
    GUARD.validate_app_path(path)
    require(not any(entry.is_symlink() for entry in path.rglob("*")),
            f"Existing preview bundle cannot contain symlinks: {path}")
    metadata = plistlib.loads((path / "Contents/Info.plist").read_bytes())
    validate_identifier(metadata.get("CFBundleIdentifier"))
    require(metadata.get("CFBundleExecutable") == AUDIT.AUDIT_EXECUTABLE,
            f"Existing destination is not a native audit preview: {path}")
    # Legacy builds have the audit entry point but no capability marker. Only
    # this updater accepts them; the runner always requires protocol version 1.
    if "SoftLockNativeAuditProtocol" in metadata:
        protocol = metadata["SoftLockNativeAuditProtocol"]
        require(type(protocol) is int and protocol == 1, f"Unsupported audit preview protocol: {path}")
    executable = path / "Contents/MacOS" / AUDIT.AUDIT_EXECUTABLE
    require(os.access(executable, os.R_OK | os.X_OK), f"Preview executable must be readable and executable: {executable}")
    binary = executable.read_bytes()
    require(binary[:4] in AUDIT.MACHO_HEADERS and all(marker in binary for marker in AUDIT.AUDIT_BINARY_MARKERS),
            f"Existing destination lacks the native audit entry point: {path}")


def ensure_preview_stopped(path):
    """Read process paths without compiling Swift or opening the application."""
    library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    library.proc_listallpids.argtypes = [ctypes.c_void_p, ctypes.c_int]
    library.proc_listallpids.restype = ctypes.c_int
    library.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]
    library.proc_pidpath.restype = ctypes.c_int
    required = library.proc_listallpids(None, 0)
    require(required > 0, "Cannot check running preview processes; nothing was built or replaced")
    pids = (ctypes.c_int * (required + 1024))()
    count = library.proc_listallpids(pids, ctypes.sizeof(pids))
    require(0 < count < len(pids), "Cannot check running preview processes; nothing was built or replaced")
    target = (path / "Contents/MacOS" / AUDIT.AUDIT_EXECUTABLE).resolve()
    for pid in pids[:count]:
        if pid <= 0:
            continue
        buffer = ctypes.create_string_buffer(4096)
        if library.proc_pidpath(pid, buffer, len(buffer)) <= 0:
            continue
        if Path(os.fsdecode(buffer.value)).resolve() == target:
            raise PreviewBuildError(f"Audit preview is running (PID {pid}); quit it or choose another preview path")


def build_preview(raw_path, identifier, project=PROJECT):
    project = Path(project)
    validate_identifier(identifier)
    destination = preview_path(raw_path, project)
    validate_existing_preview(destination)
    ensure_preview_stopped(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    expected = GUARD.snapshot_app(destination)
    # Do not accept a destination changed to a different kind of app while the
    # initial snapshot was being taken.
    validate_existing_preview(destination)
    require(GUARD.snapshot_app(destination) == expected, "Preview destination changed before build")
    staging = Path(tempfile.mkdtemp(prefix=".softlock-audit-build.", dir=destination.parent))
    staged_app, backup = staging / "staged.app", staging / "previous.app"
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(project / ".build/clang-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(project / ".build/swift-cache")
    try:
        executable = staged_app / "Contents/MacOS" / AUDIT.AUDIT_EXECUTABLE
        resources = staged_app / "Contents/Resources"
        executable.parent.mkdir(parents=True)
        resources.mkdir()
        for language in ("en", "ko"):
            shutil.copytree(project / "Sources/Resources" / (language + ".lproj"), resources / (language + ".lproj"))
        subprocess.run(["swiftc", "-O", "-module-name", AUDIT.AUDIT_EXECUTABLE,
                        *[f"Sources/{name}.swift" for name in SOURCES], "Tools/DesignPreview/main.swift",
                        "-o", str(executable)], cwd=project, env=environment, check=True, close_fds=False)
        metadata = plistlib.loads((project / "Info.plist").read_bytes())
        metadata.update(CFBundleIdentifier=identifier, CFBundleExecutable=AUDIT.AUDIT_EXECUTABLE,
                        CFBundleName=AUDIT.AUDIT_EXECUTABLE, CFBundleDisplayName="DeskVeil 미리보기",
                        SoftLockNativeAuditProtocol=1, LSUIElement=False)
        (staged_app / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
        subprocess.run(["zsh", "Tools/Distribution/make-icon.sh", str(staging / "SoftLock.iconset"),
                        str(resources / "SoftLock.icns")], cwd=project, env=environment, check=True, close_fds=False)
        # Preserve the inherited build-lock descriptor in child tools, including
        # if the Python launcher is terminated while a compiler is still running.
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", identifier, str(staged_app)],
                       check=True, close_fds=False)
        subprocess.run(["codesign", "--verify", "--strict", str(staged_app)], check=True, close_fds=False)
        validate_existing_preview(staged_app)
        validate_existing_preview(destination)
        ensure_preview_stopped(destination)
        GUARD.publish_app(staged_app, destination, expected, backup)
    finally:
        if os.path.lexists(backup):
            print(f"Original preview preserved at {backup}; staging directory retained", file=sys.stderr)
        else:
            shutil.rmtree(staging)
    print(f"Built {destination}")


def main():
    build_preview(os.environ.get("SOFTLOCK_PREVIEW_PATH", PROJECT / "dist-tests/DeskVeilAuditPreview.app"),
                  os.environ.get("SOFTLOCK_PREVIEW_BUNDLE_ID", "dev.local.softlock.audit-preview"))


if __name__ == "__main__":
    try:
        main()
    except (PreviewBuildError, GUARD.GuardError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"Preview build: {error}", file=sys.stderr)
        sys.exit(1)
