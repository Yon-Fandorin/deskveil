#!/usr/bin/env python3
"""Pure/mocked preview publication and checker regressions; no native tooling."""
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
specification = importlib.util.spec_from_file_location("softlock_preview_builder_tests", HERE / "build-preview.py")
BUILDER = importlib.util.module_from_spec(specification)
specification.loader.exec_module(BUILDER)
PREVIEW_ID = "dev.local.softlock.audit-preview"
MOCK_BINARY = BUILDER.AUDIT.MACHO_HEADERS[0] + b"\0".join(BUILDER.AUDIT.AUDIT_BINARY_MARKERS)


def payload(path):
    if path.is_symlink():
        return {"link": os.readlink(path)}
    if not path.exists():
        return None
    return {str(entry.relative_to(path)): (os.readlink(entry) if entry.is_symlink() else entry.read_bytes())
            for entry in path.rglob("*") if entry.is_symlink() or entry.is_file()}


class PreviewBuildSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="softlock-preview-build-test-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name) / "project"
        self.project.mkdir()
        for language in ("en", "ko"):
            resources = self.project / "Sources/Resources" / (language + ".lproj")
            resources.mkdir(parents=True)
            (resources / "Localizable.strings").write_text("/* fixture */")
        (self.project / "Info.plist").write_bytes(plistlib.dumps({"CFBundlePackageType": "APPL"}))
        self.destination = self.project / "previews/Audit.app"
        run_patch = mock.patch.object(BUILDER.subprocess, "run")
        self.run = run_patch.start()
        self.addCleanup(run_patch.stop)
        stopped_patch = mock.patch.object(BUILDER, "ensure_preview_stopped")
        self.stopped = stopped_patch.start()
        self.addCleanup(stopped_patch.stop)

    def make_app(self, path=None, identifier=PREVIEW_ID, protocol=1, binary=MOCK_BINARY):
        path = path or self.destination
        executable = path / "Contents/MacOS/SoftLockAuditPreview"
        executable.parent.mkdir(parents=True)
        executable.write_bytes(binary)
        executable.chmod(0o755)
        metadata = {"CFBundlePackageType": "APPL", "CFBundleIdentifier": identifier,
                    "CFBundleExecutable": "SoftLockAuditPreview"}
        if protocol is not None:
            metadata["SoftLockNativeAuditProtocol"] = protocol
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps(metadata))
        return path

    def reject_untouched(self, path=None, identifier=PREVIEW_ID):
        path = path or self.destination
        original = payload(path)
        with self.assertRaises((BUILDER.PreviewBuildError, BUILDER.GUARD.GuardError)):
            BUILDER.build_preview(path, identifier, self.project)
        self.assertEqual(payload(path), original)
        self.run.assert_not_called()
        self.stopped.assert_not_called()
        self.assertFalse(list(self.project.rglob(".softlock-audit-build.*")))

    def fake_native_tools(self):
        original = payload(self.destination)

        def run(command, **kwargs):
            self.assertEqual(payload(self.destination), original, "Build wrote into destination before publication")
            if command[0] == "swiftc":
                executable = Path(command[command.index("-o") + 1])
                self.assertNotEqual(executable.parent.parent.parent, self.destination)
                executable.write_bytes(MOCK_BINARY + b"new preview")
                executable.chmod(0o755)
            elif command[0] == "zsh":
                Path(command[-1]).write_bytes(b"mock icon")
            elif command[0] == "codesign":
                self.assertNotEqual(Path(command[-1]), self.destination)
            else:
                self.fail(f"Unexpected external tool: {command}")
            return subprocess.CompletedProcess(command, 0)

        self.run.side_effect = run

    def test_canonical_production_app_and_alias_are_rejected_without_writes(self):
        production = self.make_app(self.project / "dist/SoftLock.app", identifier="dev.local.softlock")
        original = payload(production)
        self.reject_untouched(production)
        alias = self.project.parent / "alias"
        alias.symlink_to(self.project, target_is_directory=True)
        self.reject_untouched(alias / "dist/SoftLock.app")
        self.assertEqual(payload(production), original)

    def test_reserved_installed_paths_are_rejected_before_external_tools(self):
        for path in (Path("/Applications/SoftLock.app"), Path.home() / "Applications/SoftLock.app",
                     Path("/Applications/DeskVeil.app"), Path.home() / "Applications/DeskVeil.app"):
            with self.subTest(path=path), self.assertRaises(BUILDER.PreviewBuildError):
                BUILDER.preview_path(path, self.project)
        self.run.assert_not_called()

    def test_production_metadata_at_another_path_is_rejected(self):
        for identifier in ("dev.local.softlock", "dev.local.softlock.power"):
            with self.subTest(identifier=identifier):
                path = self.project / f"other-{identifier}.app"
                self.make_app(path, identifier=identifier)
                self.reject_untouched(path)

    def test_production_bundle_ids_cannot_be_selected_for_new_preview(self):
        for identifier in ("dev.local.softlock", "dev.local.softlock.power", "", "other.preview"):
            with self.subTest(identifier=identifier):
                self.reject_untouched(identifier=identifier)

    def test_symlink_destination_and_symlink_bundle_members_are_rejected(self):
        production = self.make_app(self.project / "Production.app", identifier="dev.local.softlock")
        self.destination.parent.mkdir()
        self.destination.symlink_to(production, target_is_directory=True)
        original = payload(production)
        self.reject_untouched()
        self.assertEqual(payload(production), original)
        self.destination.unlink()
        self.make_app()
        (self.destination / "Contents/linked-resource").symlink_to(production)
        self.reject_untouched()

    def test_ordinary_directories_and_nonpreview_binaries_are_rejected(self):
        ordinary = self.project / "ordinary.app"
        ordinary.mkdir()
        (ordinary / "do-not-delete.txt").write_bytes(b"ordinary directory")
        self.reject_untouched(ordinary)
        nonpreview = self.make_app(binary=BUILDER.AUDIT.MACHO_HEADERS[0] + b"production entry point")
        self.reject_untouched(nonpreview)

    def test_preview_cannot_be_nested_in_another_app(self):
        path = self.project / "Unknown.app/Contents/Nested.app"
        self.reject_untouched(path)

    def test_valid_and_legacy_preview_updates_publish_only_staged_output(self):
        for protocol in (None, 1):
            with self.subTest(protocol=protocol):
                self.destination = self.project / f"preview-{protocol}.app"
                self.make_app(protocol=protocol)
                self.fake_native_tools()
                BUILDER.build_preview(self.destination, PREVIEW_ID, self.project)
                info = plistlib.loads((self.destination / "Contents/Info.plist").read_bytes())
                self.assertEqual(info["SoftLockNativeAuditProtocol"], 1)
                self.assertEqual(info["CFBundleIdentifier"], PREVIEW_ID)
                self.assertIn(b"new preview", (self.destination / "Contents/MacOS/SoftLockAuditPreview").read_bytes())
                self.assertFalse(list(self.project.rglob(".softlock-audit-build.*")))
        self.assertEqual(self.stopped.call_count, 4)

    def test_running_preview_is_rejected_before_compiler(self):
        self.make_app()
        original = payload(self.destination)
        self.stopped.side_effect = BUILDER.PreviewBuildError("Audit preview is running")
        with self.assertRaisesRegex(BUILDER.PreviewBuildError, "running"):
            BUILDER.build_preview(self.destination, PREVIEW_ID, self.project)
        self.run.assert_not_called()
        self.assertEqual(payload(self.destination), original)

    def test_compile_failure_preserves_existing_preview(self):
        self.make_app()
        original = payload(self.destination)
        self.run.side_effect = subprocess.CalledProcessError(1, ["mock swiftc"])
        with self.assertRaises(subprocess.CalledProcessError):
            BUILDER.build_preview(self.destination, PREVIEW_ID, self.project)
        self.assertEqual(payload(self.destination), original)
        self.assertFalse(list(self.project.rglob(".softlock-audit-build.*")))

    def test_publish_rename_failure_rolls_original_preview_back(self):
        self.make_app()
        original = payload(self.destination)
        self.fake_native_tools()
        rename = os.rename

        def fail_publication(source, destination):
            if Path(source).name == "staged.app":
                raise OSError("mock publication failure")
            return rename(source, destination)

        with mock.patch.object(BUILDER.GUARD.os, "rename", side_effect=fail_publication):
            with self.assertRaisesRegex(OSError, "mock publication failure"):
                BUILDER.build_preview(self.destination, PREVIEW_ID, self.project)
        self.assertEqual(payload(self.destination), original)
        self.assertFalse(list(self.project.rglob(".softlock-audit-build.*")))

    def test_rollback_failure_keeps_original_preview_backup(self):
        self.make_app()
        original = payload(self.destination)
        self.fake_native_tools()
        rename = os.rename

        def fail_publication_and_rollback(source, destination):
            if Path(source).name in ("staged.app", "previous.app"):
                raise OSError("mock rename failure")
            return rename(source, destination)

        with mock.patch.object(BUILDER.GUARD.os, "rename", side_effect=fail_publication_and_rollback):
            with self.assertRaisesRegex(BUILDER.GUARD.GuardError, "rollback failed; original preserved"):
                BUILDER.build_preview(self.destination, PREVIEW_ID, self.project)
        backups = list(self.project.rglob(".softlock-audit-build.*/previous.app"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(payload(backups[0]), original)


class CheckerOptimizationTests(unittest.TestCase):
    def test_negative_json_never_prints_pass_with_any_optimization_mode(self):
        with tempfile.TemporaryDirectory(prefix="softlock-checker-test-") as temporary:
            capture = Path(temporary) / "negative.json"
            for value in ([], [{"phase": "refresh"}], {"invalid": True}):
                capture.write_text(json.dumps(value))
                for flags, optimization in (([], None), (["-O"], None), ([], "1"), ([], "2")):
                    with self.subTest(value=value, flags=flags, optimization=optimization):
                        environment = os.environ.copy()
                        environment.pop("PYTHONOPTIMIZE", None)
                        if optimization is not None:
                            environment["PYTHONOPTIMIZE"] = optimization
                        result = subprocess.run([sys.executable, *flags, str(HERE / "check-popover-layout.py"), str(capture)],
                                                capture_output=True, text=True, env=environment, timeout=10)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertNotIn("PASS", result.stdout)
                        if flags or optimization:
                            self.assertIn("requires assertions", result.stderr)


if __name__ == "__main__":
    unittest.main()
