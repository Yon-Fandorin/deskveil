#!/usr/bin/env python3
"""Run the isolated preview's native layout scenarios with a bounded lifetime."""
import argparse
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from xml.parsers.expat import ExpatError

AUDIT_EXECUTABLE = "SoftLockAuditPreview"
ARTIFACT_SUFFIXES = ("", ".json", ".png", ".error.json", ".log", ".content.png", ".content.png.json", ".identify.png")
MACHO_HEADERS = (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe",
                 b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca")
# These literals belong to the render/audit entry point in Tools/DesignPreview,
# not the normal application's startup path. This prevents accidental app mixups;
# it is not an authenticity check against a deliberately modified executable.
AUDIT_BINARY_MARKERS = (b"SoftLockPopoverAuditPath", b"SoftLockDashboardRenderPath")

def preflight(preview, output):
    for suffix in ARTIFACT_SUFFIXES:
        artifact = Path(str(output) + suffix)
        if artifact.exists() or artifact.is_symlink():
            raise SystemExit(f"Choose an entirely unused output prefix; artifact already exists: {artifact}")
    try:
        info = plistlib.loads((preview / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        raise SystemExit(f"Cannot read preview Info.plist: {error}") from error
    if not isinstance(info, dict):
        raise SystemExit("Preview Info.plist must contain a dictionary")
    protocol = info.get("SoftLockNativeAuditProtocol")
    if type(protocol) is not int or protocol != 1:
        raise SystemExit("Use Tools/DesignPreview/build.sh output with SoftLockNativeAuditProtocol=1; normal app previews cannot run this audit")
    identifier = info.get("CFBundleIdentifier")
    if not isinstance(identifier, str) or not identifier.startswith("dev.local.softlock.") or identifier == "dev.local.softlock.power":
        raise SystemExit("Use a separately identified audit preview app")
    if info.get("CFBundleExecutable") != AUDIT_EXECUTABLE:
        raise SystemExit(f"Audit preview CFBundleExecutable must be {AUDIT_EXECUTABLE}")
    executable = preview / "Contents/MacOS" / AUDIT_EXECUTABLE
    if executable.is_symlink() or not executable.is_file() or not os.access(executable, os.R_OK | os.X_OK):
        raise SystemExit(f"Audit preview executable must be a readable, executable regular file: {executable}")
    try:
        binary = executable.read_bytes()
    except OSError as error:
        raise SystemExit(f"Cannot read audit preview executable: {error}") from error
    if binary[:4] not in MACHO_HEADERS or not all(marker in binary for marker in AUDIT_BINARY_MARKERS):
        raise SystemExit("Executable lacks the native DesignPreview audit entry point; rebuild with Tools/DesignPreview/build.sh")
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("preview", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--dark", action="store_true")
    parser.add_argument("--status-item", action="store_true")
    args = parser.parse_args()
    # Preserve a final dangling symlink so preflight can reject it explicitly.
    output = args.output.parent.resolve() / args.output.name
    info = preflight(args.preview, output)
    output.parent.mkdir(parents=True, exist_ok=True)

    # Reserve the prefix before signing or launching. A concurrent invocation
    # cannot overwrite the audit log or mistake this run's artifacts for its own.
    with Path(str(output) + ".log").open("x") as log, tempfile.TemporaryDirectory(prefix="softlock-native-audit-") as temporary:
        app = Path(temporary) / "SoftLockNativeAudit.app"
        shutil.copytree(args.preview, app)
        identity = "dev.local.softlock.native-audit." + uuid.uuid4().hex
        info.update(CFBundleIdentifier=identity, SoftLockPopoverAuditPath=str(output),
                    SoftLockDashboardRenderPath=str(output) + ".content.png",
                    SoftLockDashboardManyDisplays=False, SoftLockPreviewScenario="ready",
                    SoftLockPreviewNeedsPermission=False,
                    SoftLockDesignAppearance="dark" if args.dark else "light",
                    SoftLockPopoverAuditStatusItem=args.status_item)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", identity, str(app)], check=True)
        process = subprocess.Popen([str(app / "Contents/MacOS" / AUDIT_EXECUTABLE)], stdout=log, stderr=log)
        print(f"Native audit process: {process.pid}", flush=True)
        try:
            deadline = time.monotonic() + 55
            result = Path(str(output) + ".json")
            error = Path(str(output) + ".error.json")
            capture = Path(str(output) + ".png")

            def completed():
                # JSON is written before the native image. Do not terminate the
                # process while AppKit is still capturing/writing that image.
                return result.exists() and capture.exists() and capture.read_bytes().endswith(b"\x00\x00\x00\x00IEND\xaeB`\x82")

            while time.monotonic() < deadline and process.poll() is None and not completed() and not error.exists():
                time.sleep(0.1)
            if error.exists():
                raise SystemExit(error.read_text())
            if not completed():
                raise SystemExit(f"Native audit produced no result within 55 seconds; see {output}.log")
            subprocess.run([sys.executable, "-E", str(Path(__file__).with_name("check-popover-layout.py")), str(result)], check=True)
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
