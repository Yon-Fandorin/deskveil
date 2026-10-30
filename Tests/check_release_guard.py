#!/usr/bin/env python3
"""Pure release-policy and mocked inspection tests; never sign or use a keychain."""
import importlib.util
import fcntl
import json
import os
from pathlib import Path
import plistlib
import select
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("release_guard", ROOT / "Tools/Distribution/release-guard.py")
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


def release():
    reference = guard.baseline()
    return {
        "bundleIdentifier": reference["bundleIdentifier"], "appCDHash": reference["appCDHash"],
        "appRequirement": guard.expected_requirement(reference["bundleIdentifier"], reference["certificateSHA1"]),
        "helperBundleIdentifier": reference["helperBundleIdentifier"],
        "helperCDHash": reference["helperCDHash"],
        "helperRequirement": guard.expected_requirement(reference["helperBundleIdentifier"], reference["certificateSHA1"]),
        "clientRequirement": guard.expected_requirement(reference["bundleIdentifier"], reference["certificateSHA1"]),
        "protocolVersion": reference["protocolVersion"], "version": reference["version"], "build": reference["build"],
    }


class ReleasePolicyTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.reference = guard.baseline()

    def test_current_and_new_ui_release_preserve_baseline_identity(self):
        guard.check_release(release(), self.reference)
        candidate = release()
        candidate.update(version=self.reference["version"] + ".1",
                         build=str(int(self.reference["build"]) + 1), appCDHash="c" * 40)
        guard.check_release(candidate, self.reference, release())

    def test_same_name_rotated_certificate_and_adhoc_requirement_are_rejected(self):
        for requirement in [guard.expected_requirement("dev.local.softlock", "a" * 40),
                            'cdhash H"' + "a" * 40 + '"']:
            candidate = release()
            candidate["appRequirement"] = requirement
            with self.assertRaisesRegex(guard.GuardError, "IDENTITY_MIGRATION"):
                guard.check_release(candidate, self.reference)

    def test_preview_bundle_cannot_be_packaged_as_production(self):
        candidate = release()
        candidate["bundleIdentifier"] += ".preview"
        with self.assertRaisesRegex(guard.GuardError, "IDENTITY_MIGRATION"):
            guard.check_release(candidate, self.reference)

    def test_migration_helper_change_and_release_replacement_are_independent(self):
        candidate = release()
        candidate.update(appRequirement='cdhash H"' + "a" * 40 + '"',
                         clientRequirement='cdhash H"' + "a" * 40 + '"',
                         helperCDHash="a" * 40, appCDHash="b" * 40)
        with self.assertRaisesRegex(guard.GuardError, "IDENTITY_MIGRATION"):
            guard.check_release(candidate, self.reference)
        os.environ["SOFTLOCK_ALLOW_IDENTITY_MIGRATION"] = "1"
        with self.assertRaisesRegex(guard.GuardError, "HELPER_CHANGE"):
            guard.check_release(candidate, self.reference)
        os.environ["SOFTLOCK_ALLOW_HELPER_CHANGE"] = "1"
        with self.assertRaisesRegex(guard.GuardError, "RELEASE_REPLACEMENT"):
            guard.check_release(candidate, self.reference)
        os.environ["SOFTLOCK_ALLOW_RELEASE_REPLACEMENT"] = "1"
        guard.check_release(candidate, self.reference)

    def test_protocol_change_requires_helper_change(self):
        candidate = release()
        candidate["protocolVersion"] += 1
        with self.assertRaisesRegex(guard.GuardError, "HELPER_CHANGE"):
            guard.check_release(candidate, self.reference)

    def test_baseline_and_newer_destination_both_prevent_downgrade(self):
        # Keep version-order fixtures independent of the latest public release.
        reference = dict(self.reference, version="2.0.0", build="20")
        current = dict(release(), version="2.0.0", build="20")
        older_version = dict(current, version="1.9.9")
        older_build = dict(current, build="19")
        newer_version = dict(current, version="2.1.0")
        newer_build = dict(current, build="21")
        for candidate, previous in [(older_version, None), (older_build, None),
                                    (current, newer_version), (current, newer_build)]:
            with self.subTest(candidate=candidate, previous=previous):
                with self.assertRaisesRegex(guard.GuardError, "DOWNGRADE"):
                    guard.check_release(candidate, reference, previous)
        os.environ["SOFTLOCK_ALLOW_RELEASE_REPLACEMENT"] = "1"
        with self.assertRaisesRegex(guard.GuardError, "DOWNGRADE"):
            guard.check_release(older_version, reference)

    def test_same_version_in_new_destination_still_requires_replacement(self):
        with self.assertRaisesRegex(guard.GuardError, "RELEASE_REPLACEMENT"):
            guard.check_release(dict(release(), appCDHash="c" * 40), self.reference)

    def test_previous_helper_and_signer_also_require_explicit_changes(self):
        previous = dict(release(), appRequirement='cdhash H"' + "a" * 40 + '"')
        with self.assertRaisesRegex(guard.GuardError, "IDENTITY_MIGRATION"):
            guard.check_release(release(), self.reference, previous)
        previous = dict(release(), helperCDHash="a" * 40)
        with self.assertRaisesRegex(guard.GuardError, "HELPER_CHANGE"):
            guard.check_release(release(), self.reference, previous)


class InspectionAndPublishTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.temporary = tempfile.TemporaryDirectory(prefix="softlock-release-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)

    def bundle(self):
        app = self.directory / "SoftLock.app"
        for bundle, identifier in [(app, "dev.local.softlock"), (app / guard.HELPER, "dev.local.softlock.power")]:
            (bundle / "Contents/MacOS").mkdir(parents=True)
            (bundle / "Contents/MacOS/SoftLock").write_bytes(b"fixture")
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier,
                "CFBundleShortVersionString": guard.baseline()["version"],
                "CFBundleVersion": guard.baseline()["build"]}))
        return app

    def mocked_inspection(self, app, candidate=None):
        candidate = candidate or release()

        def run(*arguments):
            if arguments[0] == "/usr/bin/codesign":
                if "--verify" in arguments:
                    return ""
                helper = Path(arguments[-1]) == app / guard.HELPER
                identifier = candidate["helperBundleIdentifier" if helper else "bundleIdentifier"]
                code_hash = candidate["helperCDHash" if helper else "appCDHash"]
                requirement = candidate["helperRequirement" if helper else "appRequirement"]
                return f"Identifier={identifier}\nCDHash={code_hash}\ndesignated => {requirement}\n"
            self.assertEqual(Path(arguments[0]), app.resolve() / "Contents/MacOS/SoftLock")
            self.assertEqual(arguments[1], "--lid-install-plan")
            return json.dumps({"clientHash": candidate["appCDHash"], "helperHash": candidate["helperCDHash"],
                               "clientRequirement": candidate["clientRequirement"],
                               "protocol": candidate["protocolVersion"]})
        return run

    def test_inspects_native_metadata_and_compiled_plan_without_signing(self):
        app = self.bundle()
        with patch.object(guard, "run", side_effect=self.mocked_inspection(app)) as commands:
            result = guard.inspect_bundle(app)
        guard.check_release(result, guard.baseline())
        self.assertEqual(len(commands.call_args_list), 6)
        self.assertTrue(all("--sign" not in call.args for call in commands.call_args_list))

    def test_rotated_app_is_rejected_before_executing_its_cli(self):
        app = self.bundle()
        candidate = dict(release(), appRequirement=guard.expected_requirement("dev.local.softlock", "a" * 40))
        with patch.object(guard, "run", side_effect=self.mocked_inspection(app, candidate)) as commands:
            with self.assertRaisesRegex(guard.GuardError, "IDENTITY_MIGRATION"):
                guard.inspect_bundle(app)
        self.assertEqual(len(commands.call_args_list), 3)

    def test_signature_failure_stops_inspection(self):
        app = self.bundle()
        with patch.object(guard, "run", side_effect=guard.GuardError("invalid signature")) as commands:
            with self.assertRaisesRegex(guard.GuardError, "invalid signature"):
                guard.inspect_bundle(app)
        self.assertEqual(len(commands.call_args_list), 1)

    def test_displayed_requirement_cannot_replace_actual_signer_validation(self):
        app = self.bundle()
        inspect = self.mocked_inspection(app)

        def reject_actual_signer(*arguments):
            if any(str(argument).startswith("-R=") for argument in arguments):
                raise guard.GuardError("Actual signer does not satisfy the pin")
            return inspect(*arguments)

        with patch.object(guard, "run", side_effect=reject_actual_signer) as commands:
            with self.assertRaisesRegex(guard.GuardError, "Actual signer"):
                guard.inspect_bundle(app)
        self.assertTrue(all(call.args[0] == "/usr/bin/codesign" for call in commands.call_args_list))

    def test_bundle_digest_detects_helper_resources_and_links(self):
        app = self.bundle()
        before = guard.bundle_digest(app)
        (app / guard.HELPER / "Contents/MacOS/SoftLock").write_bytes(b"changed helper")
        self.assertNotEqual(before, guard.bundle_digest(app))
        before = guard.bundle_digest(app)
        (app / "Contents/Resources").mkdir()
        (app / "Contents/Resources/link").symlink_to("one")
        self.assertNotEqual(before, guard.bundle_digest(app))

    def test_bundle_digest_detects_removed_helper_execute_permission(self):
        app = self.bundle()
        helper = app / guard.HELPER / "Contents/MacOS/SoftLock"
        helper.chmod(0o755)
        before = guard.bundle_digest(app)
        helper.chmod(0o644)
        self.assertNotEqual(before, guard.bundle_digest(app))

    def test_publish_never_clobbers_unapproved_or_changed_output(self):
        source, destination = self.directory / "staged.dmg", self.directory / "release.dmg"
        source.write_bytes(b"new")
        self.assertIsNone(guard.check_output(destination))
        destination.write_bytes(b"existing")
        with self.assertRaises(guard.GuardError):
            guard.publish(source, destination, None)
        with self.assertRaisesRegex(guard.GuardError, "RELEASE_REPLACEMENT"):
            guard.check_output(destination)
        os.environ["SOFTLOCK_ALLOW_RELEASE_REPLACEMENT"] = "1"
        expected = guard.check_output(destination)
        destination.write_bytes(b"changed during packaging")
        with self.assertRaisesRegex(guard.GuardError, "changed during packaging"):
            guard.publish(source, destination, expected)
        self.assertEqual(destination.read_bytes(), b"changed during packaging")
        expected = guard.check_output(destination)
        guard.publish(source, destination, expected)
        self.assertEqual(destination.read_bytes(), b"new")

    def test_publish_first_release_and_reject_directory_or_symlink(self):
        source, destination = self.directory / "staged.dmg", self.directory / "release.dmg"
        source.write_bytes(b"new")
        guard.publish(source, destination, None)
        self.assertEqual(destination.read_bytes(), b"new")
        for target in [self.directory, self.directory / "link.dmg"]:
            if target.name == "link.dmg":
                target.symlink_to(destination)
            with self.assertRaisesRegex(guard.GuardError, "regular file"):
                guard.check_output(target)


class AppPublicationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="softlock-app-publish-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.destination = self.directory / "SoftLock.app"
        self.source = self.directory / "staged.app"
        self.backup = self.directory / "previous.app"
        for app, content in [(self.destination, b"original"), (self.source, b"candidate")]:
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/payload").write_bytes(content)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundlePackageType": "APPL", "CFBundleIdentifier": "test.softlock.preview",
                "CFBundleExecutable": "SoftLock"}))
            binary = app / "Contents/MacOS/SoftLock"
            binary.write_bytes(b"fixture executable")
            binary.chmod(0o755)

    def publish(self, expected):
        guard.publish_app(self.source, self.destination, expected, self.backup)

    def test_a_b_publish_interleaving_aborts_b_instead_of_replacing_a(self):
        expected_a = guard.snapshot_app(self.destination)
        expected_b = guard.snapshot_app(self.destination)
        self.publish(expected_a)
        self.assertEqual((self.destination / "Contents/payload").read_bytes(), b"candidate")
        self.assertFalse(self.backup.exists())
        shutil.copytree(self.destination, self.source)
        (self.source / "Contents/payload").write_bytes(b"stale B")
        with self.assertRaisesRegex(guard.GuardError, "changed during build"):
            self.publish(expected_b)
        self.assertEqual((self.destination / "Contents/payload").read_bytes(), b"candidate")
        self.assertEqual((self.source / "Contents/payload").read_bytes(), b"stale B")

    def test_snapshot_detects_nested_payload_metadata_and_identical_replacement(self):
        expected = guard.snapshot_app(self.destination)
        payload = self.destination / "Contents/payload"
        payload.write_bytes(b"modified")
        with self.assertRaisesRegex(guard.GuardError, "changed during build"):
            self.publish(expected)
        expected = guard.snapshot_app(self.destination)
        payload.chmod(0o700)
        with self.assertRaisesRegex(guard.GuardError, "changed during build"):
            self.publish(expected)
        expected = guard.snapshot_app(self.destination)
        moved = self.directory / "moved.app"
        self.destination.rename(moved)
        shutil.copytree(moved, self.destination)
        with self.assertRaisesRegex(guard.GuardError, "changed during build"):
            self.publish(expected)
        self.assertTrue(self.source.exists())

    def test_missing_new_and_symlink_destinations_fail_closed(self):
        expected = guard.snapshot_app(self.destination)
        shutil.rmtree(self.destination)
        with self.assertRaisesRegex(guard.GuardError, "changed during build"):
            self.publish(expected)
        self.destination.mkdir()
        with self.assertRaisesRegex(guard.GuardError, "Invalid app bundle"):
            self.publish(None)
        self.destination.rmdir()
        for target in [self.source, self.directory / "missing.app"]:
            self.destination.symlink_to(target)
            with self.assertRaisesRegex(guard.GuardError, "real directory"):
                guard.snapshot_app(self.destination)
            with self.assertRaises(guard.GuardError):
                self.publish(None)
            self.assertTrue(self.destination.is_symlink())
            self.destination.unlink()
        self.publish(None)
        self.assertEqual((self.destination / "Contents/payload").read_bytes(), b"candidate")

    def test_non_app_directories_and_invalid_app_layout_are_never_replaced(self):
        for name in ["ordinarydir", "misleading.app"]:
            destination = self.directory / name
            destination.mkdir()
            valuable = destination / "valuable.txt"
            valuable.write_text("keep this unrelated data")
            with self.assertRaises(guard.GuardError):
                guard.validate_app_path(destination)
            with patch.object(guard.os, "rename") as rename:
                with self.assertRaises(guard.GuardError):
                    guard.publish_app(self.source, destination, None, self.backup)
            rename.assert_not_called()
            self.assertEqual(valuable.read_text(), "keep this unrelated data")
            self.assertFalse(self.backup.exists())

        original_info = (self.destination / "Contents/Info.plist").read_bytes()
        invalid_metadata = [b"not a plist", plistlib.dumps([]), plistlib.dumps({}),
                            plistlib.dumps({"CFBundlePackageType": "APPL", "CFBundleIdentifier": "preview",
                                            "CFBundleExecutable": "../payload"})]
        for metadata in invalid_metadata:
            (self.destination / "Contents/Info.plist").write_bytes(metadata)
            with self.assertRaises(guard.GuardError):
                self.publish(None)
            self.assertEqual((self.destination / "Contents/payload").read_bytes(), b"original")
        (self.destination / "Contents/Info.plist").write_bytes(original_info)
        (self.destination / "Contents/MacOS/SoftLock").chmod(0o644)
        with self.assertRaisesRegex(guard.GuardError, "executable"):
            self.publish(None)
        self.assertFalse(self.backup.exists())

    def test_valid_preview_bundle_can_be_replaced(self):
        self.assertTrue(guard.validate_app_path(self.destination))
        self.publish(guard.snapshot_app(self.destination))
        self.assertEqual((self.destination / "Contents/payload").read_bytes(), b"candidate")
        self.assertEqual(plistlib.loads((self.destination / "Contents/Info.plist").read_bytes())[
            "CFBundleIdentifier"], "test.softlock.preview")

    def test_invalid_or_overlapping_publication_paths_do_not_rename_anything(self):
        expected = guard.snapshot_app(self.destination)
        invalid = [(self.source, self.destination, self.source),
                   (self.source, self.source, self.backup),
                   (self.source, self.source / "Nested.app", self.backup),
                   (self.source, self.destination, self.source / "previous.app"),
                   (self.source, self.destination, self.directory),
                   (self.source, self.directory / "missing-without-app-suffix", self.backup)]
        for source, destination, backup in invalid:
            with self.subTest(source=source, destination=destination, backup=backup), \
                    patch.object(guard.os, "rename") as rename:
                with self.assertRaises(guard.GuardError):
                    guard.publish_app(source, destination, expected, backup)
                rename.assert_not_called()
        self.assertEqual((self.destination / "Contents/payload").read_bytes(), b"original")
        self.assertEqual((self.source / "Contents/payload").read_bytes(), b"candidate")

    def test_commit_failure_restores_original_bundle_inode_and_contents(self):
        expected = guard.snapshot_app(self.destination)
        inode = self.destination.stat().st_ino
        rename = os.rename

        def fail_commit(source, destination):
            if source == self.source:
                raise OSError("injected commit failure")
            rename(source, destination)

        with patch.object(guard.os, "rename", side_effect=fail_commit):
            with self.assertRaisesRegex(OSError, "injected commit failure"):
                self.publish(expected)
        self.assertEqual(self.destination.stat().st_ino, inode)
        self.assertEqual((self.destination / "Contents/payload").read_bytes(), b"original")
        self.assertFalse(self.backup.exists())
        self.assertTrue(self.source.exists())

    def test_failed_rollback_or_intervening_destination_preserves_backup(self):
        expected = guard.snapshot_app(self.destination)
        rename = os.rename

        def fail_commit_and_rollback(source, destination):
            if source == self.source or source == self.backup:
                raise OSError("injected rename failure")
            rename(source, destination)

        with patch.object(guard.os, "rename", side_effect=fail_commit_and_rollback):
            with self.assertRaisesRegex(guard.GuardError, "original preserved at"):
                self.publish(expected)
        self.assertEqual((self.backup / "Contents/payload").read_bytes(), b"original")
        self.backup.rename(self.destination)
        expected = guard.snapshot_app(self.destination)

        def intervene_during_commit(source, destination):
            if source == self.source:
                self.destination.mkdir()
                (self.destination / "outside").write_text("outside writer")
                raise OSError("destination appeared")
            rename(source, destination)

        with patch.object(guard.os, "rename", side_effect=intervene_during_commit):
            with self.assertRaisesRegex(guard.GuardError, "original preserved at"):
                self.publish(expected)
        self.assertEqual((self.backup / "Contents/payload").read_bytes(), b"original")
        self.assertEqual((self.destination / "outside").read_text(), "outside writer")

    def test_revalidation_and_both_renames_hold_publisher_lock(self):
        expected = guard.snapshot_app(self.destination)
        stamp, rename = guard.app_stamp, os.rename

        def assert_locked():
            descriptor = os.open(self.directory, os.O_RDONLY)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(descriptor)

        def checked_stamp(path):
            assert_locked()
            return stamp(path)

        def checked_rename(source, destination):
            assert_locked()
            rename(source, destination)

        with patch.object(guard, "app_stamp", side_effect=checked_stamp), \
                patch.object(guard.os, "rename", side_effect=checked_rename):
            self.publish(expected)

    def test_build_lock_survives_exec_and_serializes_shared_outputs(self):
        lock = self.directory / "build.lock"
        command = [sys.executable, str(ROOT / "Tools/Distribution/release-guard.py"),
                   "run-locked", str(lock), "/bin/zsh", "-c",
                   'print entered; read response; print finished']
        first = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        second = None
        try:
            self.assertTrue(select.select([first.stdout], [], [], 5)[0], "first builder did not start")
            self.assertEqual(first.stdout.readline().strip(), "entered")
            descriptor = os.open(lock, os.O_RDONLY)
            try:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            finally:
                os.close(descriptor)
            second = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True)
            # A is paused before its shared-output copy; B must not enter.
            self.assertFalse(select.select([second.stdout], [], [], 0.2)[0])
            first_out, first_error = first.communicate("continue\n", timeout=5)
            self.assertEqual(first.returncode, 0, first_error)
            self.assertEqual(first_out.strip(), "finished")
            self.assertTrue(select.select([second.stdout], [], [], 5)[0], "second builder stayed locked")
            self.assertEqual(second.stdout.readline().strip(), "entered")
            second_out, second_error = second.communicate("continue\n", timeout=5)
            self.assertEqual(second.returncode, 0, second_error)
            self.assertEqual(second_out.strip(), "finished")
        finally:
            for process in [first, second]:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.communicate(timeout=5)

    def test_build_script_locks_before_swift_and_rejects_unsafe_destinations_early(self):
        workspace = self.directory / "workspace"
        tools = workspace / "Tools/Distribution"
        tools.mkdir(parents=True)
        shutil.copy2(ROOT / "build.sh", workspace / "build.sh")
        shutil.copy2(ROOT / "Tools/Distribution/release-guard.py", tools / "release-guard.py")
        commands = workspace / "fake-commands"
        commands.mkdir()
        swift = commands / "swift"
        swift.write_text(f'''#!{sys.executable}
import fcntl, os, sys
descriptor = os.open(".build/.softlock-build.lock", os.O_RDONLY)
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("locked before first compiler access")
    print(sys.argv[-1])
    sys.exit(92)
sys.exit(93)
''')
        swift.chmod(0o755)
        alias = self.directory / "alias"
        alias.symlink_to(self.directory, target_is_directory=True)
        final_link = self.directory / "Final.app"
        final_link.symlink_to(self.destination, target_is_directory=True)
        environment = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                           SOFTLOCK_APP_PATH=str(alias / self.destination.name))
        result = subprocess.run(["/bin/zsh", str(workspace / "build.sh")], env=environment,
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 92, result.stderr)
        self.assertEqual(result.stdout.splitlines(),
                         ["locked before first compiler access", str(self.destination.parent.resolve() / self.destination.name)])
        for path in [alias / "Final.app", workspace, self.directory / "misleading.app"]:
            if path.suffix == ".app" and not path.exists():
                path.mkdir()
            environment["SOFTLOCK_APP_PATH"] = str(path)
            result = subprocess.run(["/bin/zsh", str(workspace / "build.sh")], env=environment,
                                    capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(result.stdout, "", "invalid destination reached the mocked Swift command")
        self.assertTrue(final_link.is_symlink())


class PackagingShellPathTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="softlock-packaging-shell-test-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.workspace = self.directory / "workspace"
        distribution = self.workspace / "Tools/Distribution"
        distribution.mkdir(parents=True)
        shutil.copy2(ROOT / "Tools/package-dmg.sh", self.workspace / "Tools/package-dmg.sh")
        shutil.copy2(ROOT / "Tools/Distribution/release-guard.py", distribution / "release-guard.py")
        self.app = self.workspace / "fixture.app"
        resources = self.app / "Contents/Resources"
        resources.mkdir(parents=True)
        (resources / "SoftLock.icns").write_bytes(b"fixture icon")
        self.log = self.directory / "calls.txt"

    def run_packager(self, output, stop="ditto"):
        # Run the actual packaging shell. Mock source inspection and native tools;
        # check-output and run-locked still run the real guard. Every tool below
        # is mocked, including the cold venv/pip setup and artwork compiler.
        commands = self.workspace / "mock-commands"
        commands.mkdir(exist_ok=True)
        for name in ["python3", "lipo", "ditto", "swift", "hdiutil"]:
            command = commands / name
            command.write_text(f'''#!{sys.executable}
import fcntl, os, sys
from pathlib import Path
name = Path(sys.argv[0]).name
python = name in ("python3", "python")
if python and sys.argv[1:3] == ["Tools/Distribution/release-guard.py", "run-locked"]:
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
descriptor = os.open(".build/.softlock-build.lock", os.O_RDONLY)
try:
    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    pass
else:
    sys.exit("Packaging reached a tool without the shared build lock")
finally:
    os.close(descriptor)
if name == "lipo":
    print("arm64")
    sys.exit(0)
if python:
    if sys.argv[1:3] == ["Tools/Distribution/release-guard.py", "check"]:
        print("{{}}")
        sys.exit(0)
    if sys.argv[1:3] == ["-m", "venv"]:
        tools = Path(sys.argv[3]) / "bin"
        tools.mkdir(parents=True)
        (tools / "python").symlink_to(Path(__file__).resolve())
        event = "venv"
    elif sys.argv[1:3] == ["-m", "pip"]:
        executable = Path(".build/dmg-tools/bin/dmgbuild")
        executable.write_text("#!/bin/zsh\\nexit 93\\n")
        executable.chmod(0o755)
        event = "pip"
    else:
        event = "check-output:" + sys.argv[3]
else:
    event = name
with open(os.environ["SOFTLOCK_TEST_PACKAGE_LOG"], "a") as log:
    log.write(event + "\\n")
if python and event.startswith("check-output:"):
    os.execv(sys.executable, [sys.executable, *sys.argv[1:]])
if python or (name == "ditto" and os.environ["SOFTLOCK_TEST_PACKAGE_STOP"] == "swift"):
    sys.exit(0)
sys.exit(91 if name == "ditto" else 92 if name == "swift" else 93)
''')
            command.chmod(0o755)
        mock_shell = self.workspace / "mock-shell"
        mock_shell.mkdir(exist_ok=True)
        (mock_shell / ".zshenv").write_text('function /usr/libexec/PlistBuddy { print 0.7.11; }\n')
        environment = dict(os.environ, SOFTLOCK_APP_PATH=str(self.app), SOFTLOCK_DMG_PATH=str(output),
                           SOFTLOCK_ALLOW_RELEASE_REPLACEMENT="1", SOFTLOCK_TEST_PACKAGE_LOG=str(self.log),
                           SOFTLOCK_TEST_PACKAGE_STOP=stop,
                           ZDOTDIR=str(mock_shell), PATH=str(commands) + os.pathsep + os.environ["PATH"])
        return subprocess.run(["/bin/zsh", str(self.workspace / "Tools/package-dmg.sh")],
                              env=environment, capture_output=True, text=True, timeout=5)

    def test_existing_and_dangling_final_output_symlinks_are_rejected_before_copy(self):
        for name, existing in [("valuable.txt", True), ("missing.txt", False)]:
            with self.subTest(existing=existing):
                target = self.directory / name
                if existing:
                    target.write_bytes(b"unrelated data must survive")
                output = self.directory / "release.dmg"
                output.symlink_to(target)
                result = self.run_packager(output)
                self.assertEqual(result.returncode, 1, result.stderr)
                self.assertIn("not a regular file", result.stderr)
                self.assertEqual(self.log.read_text().splitlines(),
                                 ["check-output:" + str(output.parent.resolve() / output.name)])
                self.assertTrue(output.is_symlink())
                self.assertEqual(os.readlink(output), str(target))
                if existing:
                    self.assertEqual(target.read_bytes(), b"unrelated data must survive")
                else:
                    self.assertFalse(target.exists())
                self.assertEqual(list(self.directory.glob(".softlock-dmg.*")), [])
                output.unlink()
                self.log.unlink()

    def test_parent_directory_alias_is_canonicalized_and_accepted(self):
        parent = self.directory / "output"
        parent.mkdir()
        alias = self.directory / "alias"
        alias.symlink_to(parent, target_is_directory=True)
        result = self.run_packager(alias / "release.dmg")
        self.assertEqual(result.returncode, 91, result.stderr)
        self.assertEqual(self.log.read_text().splitlines(),
                         ["check-output:" + str(parent.resolve() / "release.dmg"), "ditto"])
        self.assertFalse((parent / "release.dmg").exists())
        self.assertTrue(alias.is_symlink())
        self.assertEqual(list(parent.iterdir()), [])

    def test_tool_install_and_artwork_share_the_persistent_build_lock(self):
        output = self.directory / "release.dmg"
        canonical_output = output.resolve()
        first = self.run_packager(output, stop="swift")
        self.assertEqual(first.returncode, 92, first.stderr)
        self.assertEqual(self.log.read_text().splitlines(),
                         ["check-output:" + str(canonical_output), "ditto", "venv", "pip", "swift"])
        lock = self.workspace / ".build/.softlock-build.lock"
        first_lock = lock.stat()
        self.log.unlink()
        second = self.run_packager(output, stop="swift")
        self.assertEqual(second.returncode, 92, second.stderr)
        self.assertEqual(self.log.read_text().splitlines(),
                         ["check-output:" + str(canonical_output), "ditto", "swift"])
        self.assertEqual((lock.stat().st_dev, lock.stat().st_ino), (first_lock.st_dev, first_lock.st_ino))
        self.assertFalse(output.exists())
        self.assertEqual(list(self.directory.glob(".softlock-dmg.*")), [])


class SigningSelectionTests(unittest.TestCase):
    def run_selector(self, identities, **extra_environment):
        with tempfile.TemporaryDirectory(prefix="softlock-selector-test-") as directory:
            directory = Path(directory)
            listing, log = directory / "identities.txt", directory / "calls.txt"
            listing.write_text(identities)
            environment = {"PATH": os.environ["PATH"], "SOFTLOCK_TEST_IDENTITIES": str(listing),
                           "SOFTLOCK_TEST_SECURITY_LOG": str(log), **extra_environment}
            # Source with $0 set to the real script; the function shadows every
            # security invocation without touching a keychain or executable mode.
            shell = '''security() {
                print -r -- "$*" >> "$SOFTLOCK_TEST_SECURITY_LOG"
                cat "$SOFTLOCK_TEST_IDENTITIES"
            }
            source "$0"
            '''
            result = subprocess.run(["/bin/zsh", "-c", shell, str(ROOT / "Tools/local-signing-identity.sh")],
                                    env=environment, capture_output=True, text=True)
            return result, log.read_text()

    def test_selects_pinned_fingerprint_regardless_of_display_name(self):
        pin = guard.baseline()["certificateSHA1"].upper()
        result, log = self.run_selector(f'  1) {"A" * 40} "SoftLock Local Development"\n'
                                        f'  2) {pin} "Renamed original certificate"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), pin)
        self.assertNotIn("import", log)

    def test_missing_pin_never_enrolls_even_with_clean_or_custom_destination(self):
        for environment in [{}, {"SOFTLOCK_APP_PATH": "/Applications/SoftLock.app"},
                            {"SOFTLOCK_ENROLL_SIGNING_IDENTITY": "1"},
                            {"SOFTLOCK_ALLOW_IDENTITY_MIGRATION": "1"}]:
            result, log = self.run_selector(f'  1) {"A" * 40} "SoftLock Local Development"\n', **environment)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("No identity was created", result.stderr)
            self.assertNotIn("import", log)


if __name__ == "__main__":
    unittest.main(verbosity=2)
