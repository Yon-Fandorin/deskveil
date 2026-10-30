#!/usr/bin/env python3
"""Pure/temp regression coverage: never builds, signs, or launches a native app."""
from pathlib import Path
import os
import plistlib
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


RUNNER = Path(__file__).with_name("run-native-audit.py").resolve()
AUDIT = runpy.run_path(str(RUNNER))
# Run the actual CLI entry point in fresh interpreters, including optimized
# Python. Intercept both possible external-process paths before executing it.
CLI_PROBE = """
from pathlib import Path
import runpy
import subprocess
import sys
sentinel = Path(sys.argv[1])
runner = sys.argv[2]
def forbidden(*args, **kwargs):
    sentinel.write_text(repr(args))
    raise RuntimeError("Preflight attempted an external process")
subprocess.run = forbidden
subprocess.Popen = forbidden
sys.argv = [runner, *sys.argv[3:]]
runpy.run_path(runner, run_name="__main__")
"""


class NativeAuditPreflightTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="softlock-preflight-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.preview = self.root / "SoftLockAuditPreview.app"
        self.info_path = self.preview / "Contents/Info.plist"
        self.executable = self.preview / "Contents/MacOS/SoftLockAuditPreview"
        self.executable.parent.mkdir(parents=True)
        self.info = {"CFBundleIdentifier": "dev.local.softlock.audit-preview",
                     "CFBundleExecutable": "SoftLockAuditPreview", "SoftLockNativeAuditProtocol": 1}
        self.write_info()
        self.executable.write_bytes(AUDIT["MACHO_HEADERS"][0] + b"\0".join(AUDIT["AUDIT_BINARY_MARKERS"]))
        self.executable.chmod(0o755)
        self.output = self.root / "fresh-capture"

    def write_info(self):
        self.info_path.write_bytes(plistlib.dumps(self.info))

    def reject_cli(self, message):
        original_log_exists = Path(str(self.output) + ".log").exists()
        for optimized in (False, True):
            with self.subTest(optimized=optimized):
                sentinel = self.root / "external-process-attempted"
                command = [sys.executable, *(["-O"] if optimized else []), "-c", CLI_PROBE,
                           str(sentinel), str(RUNNER), str(self.preview), str(self.output)]
                result = subprocess.run(command, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertFalse(sentinel.exists(), result.stderr)
                self.assertEqual(Path(str(self.output) + ".log").exists(), original_log_exists,
                                 "Rejected candidate created an audit log before preflight finished")

    def test_valid_fixture_passes_pure_preflight_without_creating_artifacts(self):
        self.assertEqual(AUDIT["preflight"](self.preview, self.output), self.info)
        for suffix in AUDIT["ARTIFACT_SUFFIXES"]:
            self.assertFalse(Path(str(self.output) + suffix).exists())

    def test_normal_production_preview_is_rejected(self):
        self.info = {"CFBundleIdentifier": "dev.local.softlock.preview", "CFBundleExecutable": "SoftLock"}
        self.write_info()
        self.reject_cli("SoftLockNativeAuditProtocol=1")

    def test_missing_or_wrong_protocol_is_rejected_even_with_audit_binary(self):
        for protocol in (None, 0, 2, True, "1"):
            with self.subTest(protocol=protocol):
                if protocol is None:
                    self.info.pop("SoftLockNativeAuditProtocol", None)
                else:
                    self.info["SoftLockNativeAuditProtocol"] = protocol
                self.write_info()
                self.reject_cli("SoftLockNativeAuditProtocol=1")

    def test_nonseparate_or_malformed_bundle_identity_is_rejected(self):
        for identifier in ("dev.local.softlock", "dev.local.softlock.power", "com.example.preview", 1):
            with self.subTest(identifier=identifier):
                self.info["CFBundleIdentifier"] = identifier
                self.write_info()
                self.reject_cli("separately identified audit preview")

    def test_production_or_escaping_executable_name_is_rejected(self):
        for executable in ("SoftLock", "../SoftLockAuditPreview", "/tmp/SoftLockAuditPreview", 1):
            with self.subTest(executable=executable):
                self.info["CFBundleExecutable"] = executable
                self.write_info()
                self.reject_cli("CFBundleExecutable must be SoftLockAuditPreview")

    def test_missing_or_nonexecutable_binary_is_rejected(self):
        self.executable.chmod(0o644)
        self.reject_cli("readable, executable regular file")
        self.executable.unlink()
        self.reject_cli("readable, executable regular file")

    def test_symlink_binary_is_rejected(self):
        target = self.root / "other-binary"
        self.executable.rename(target)
        self.executable.symlink_to(target)
        self.reject_cli("readable, executable regular file")

    def test_wrong_binary_header_or_missing_audit_branch_is_rejected(self):
        payloads = (b"#!/bin/sh\n" + b"\0".join(AUDIT["AUDIT_BINARY_MARKERS"]),
                    AUDIT["MACHO_HEADERS"][0] + b"production startup",
                    AUDIT["MACHO_HEADERS"][0] + AUDIT["AUDIT_BINARY_MARKERS"][0])
        for payload in payloads:
            with self.subTest(payload=payload):
                self.executable.write_bytes(payload)
                self.reject_cli("lacks the native DesignPreview audit entry point")

    def test_unreadable_or_malformed_info_is_rejected(self):
        for payload in (b"not a plist", b"<?xml version='1.0'?><plist><dict>", plistlib.dumps(["wrong root"])):
            with self.subTest(payload=payload):
                self.info_path.write_bytes(payload)
                self.reject_cli("Info.plist")
        self.info_path.unlink()
        self.reject_cli("Cannot read preview Info.plist")

    def test_every_stale_artifact_rejects_before_any_external_process(self):
        for suffix in AUDIT["ARTIFACT_SUFFIXES"]:
            with self.subTest(suffix=suffix):
                artifact = Path(str(self.output) + suffix)
                artifact.write_text("previous capture")
                self.reject_cli("entirely unused output prefix")
                self.assertEqual(artifact.read_text(), "previous capture")
                artifact.unlink()

    def test_dangling_output_artifact_is_rejected(self):
        for suffix in ("", ".json", ".png", ".error.json", ".log"):
            with self.subTest(suffix=suffix):
                artifact = Path(str(self.output) + suffix)
                artifact.symlink_to(self.root / "does-not-exist")
                self.reject_cli("entirely unused output prefix")
                self.assertTrue(artifact.is_symlink())
                artifact.unlink()

    def test_runner_checker_ignores_inherited_python_optimization(self):
        original_run, original_popen = subprocess.run, subprocess.Popen
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        captured = []

        def fake_popen(*arguments, **kwargs):
            Path(str(self.output) + ".json").write_text("[]")
            Path(str(self.output) + ".png").write_bytes(b"\x00\x00\x00\x00IEND\xaeB`\x82")
            return process

        def fake_run(command, **kwargs):
            if command[0] == "codesign":
                return subprocess.CompletedProcess(command, 0)
            # Only the checker interpreter runs for real. No native binary or
            # codesign process is created, and its invalid JSON must still fail.
            with mock.patch.object(subprocess, "Popen", original_popen):
                try:
                    return original_run(command, capture_output=True, text=True, **kwargs)
                except subprocess.CalledProcessError as error:
                    captured.append(error)
                    raise

        with mock.patch.dict(os.environ, {"PYTHONOPTIMIZE": "2"}), \
                mock.patch.object(sys, "argv", [str(RUNNER), str(self.preview), str(self.output)]), \
                mock.patch.object(subprocess, "run", side_effect=fake_run), \
                mock.patch.object(subprocess, "Popen", side_effect=fake_popen):
            with self.assertRaises(subprocess.CalledProcessError):
                AUDIT["main"]()
        self.assertEqual(len(captured), 1)
        self.assertIn("Incomplete native audit scenarios", captured[0].stderr)
        self.assertNotIn("requires assertions", captured[0].stderr)
        self.assertNotIn("PASS", captured[0].stdout)
        process.terminate.assert_called_once()

    def test_runner_confines_inherited_render_configuration_to_reserved_prefix(self):
        previous = self.root / "previous-capture.png"
        previous_json = Path(str(previous) + ".json")
        previous.write_bytes(b"existing capture")
        previous_json.write_text("existing metadata")
        self.info.update(SoftLockDashboardRenderPath=str(previous),
                         SoftLockPopoverAuditPath=str(self.root / "old-audit"),
                         SoftLockDashboardManyDisplays=True, SoftLockPreviewScenario="permission-needed",
                         SoftLockPreviewNeedsPermission=True)
        self.write_info()
        process = mock.Mock(pid=12345)
        process.poll.return_value = None
        seen = []

        def fake_run(command, **kwargs):
            if command[0] == "codesign":
                seen.append(plistlib.loads((Path(command[-1]) / "Contents/Info.plist").read_bytes()))
            return subprocess.CompletedProcess(command, 0)

        def fake_popen(command, **kwargs):
            metadata = plistlib.loads((Path(command[0]).parents[1] / "Info.plist").read_bytes())
            render = Path(metadata["SoftLockDashboardRenderPath"])
            # Follow the native preview's actual metadata precedence: a leaked
            # source path would overwrite our previous capture and sidecar.
            render.write_bytes(b"new render")
            Path(str(render) + ".json").write_text("new render metadata")
            Path(str(self.output) + ".json").write_text("[]")
            Path(str(self.output) + ".png").write_bytes(b"\x00\x00\x00\x00IEND\xaeB`\x82")
            return process

        with mock.patch.object(sys, "argv", [str(RUNNER), str(self.preview), str(self.output)]), \
                mock.patch.object(subprocess, "run", side_effect=fake_run), \
                mock.patch.object(subprocess, "Popen", side_effect=fake_popen):
            AUDIT["main"]()
        self.assertEqual(seen[0]["SoftLockDashboardRenderPath"], str(self.output.resolve()) + ".content.png")
        self.assertEqual(seen[0]["SoftLockPopoverAuditPath"], str(self.output.resolve()))
        self.assertFalse(seen[0]["SoftLockDashboardManyDisplays"])
        self.assertFalse(seen[0]["SoftLockPreviewNeedsPermission"])
        self.assertEqual(seen[0]["SoftLockPreviewScenario"], "ready")
        self.assertEqual(previous.read_bytes(), b"existing capture")
        self.assertEqual(previous_json.read_text(), "existing metadata")
        self.assertEqual(plistlib.loads(self.info_path.read_bytes()), self.info, "Source preview remains unchanged")


if __name__ == "__main__":
    unittest.main()
