#!/usr/bin/env python3
"""Exercise the commit-msg hook through real commits in temporary repositories."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CommitHookTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="deskveil-commit-hook-", dir="/private/tmp")
        self.repository = Path(self.temporary.name)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        self.environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_EDITOR=":")
        self.git("init", "--quiet", "--initial-branch=main")
        for key, value in [("user.name", "Commit Hook Fixture"), ("user.email", "fixture@example.invalid"),
                           ("commit.gpgSign", "false"), ("core.hooksPath", str(ROOT / ".githooks"))]:
            self.git("config", "--local", key, value)
        self.git("commit", "--quiet", "--allow-empty", "-m", "chore: initialize fixture")

    def tearDown(self):
        self.temporary.cleanup()

    def git(self, *arguments, check=True):
        return subprocess.run(["git", "-C", str(self.repository), *arguments], env=self.environment,
                              text=True, capture_output=True, check=check)

    def test_conventional_headers_and_breaking_change_forms_are_accepted(self):
        for message in ["fix(power): preserve the active session", "docs: update setup instructions",
                        "feat!: require a fresh heartbeat", "refactor(api)!: remove the old endpoint",
                        "custom-type: retain supported extension types", "FIX: accept case-insensitive types",
                        "fix: preserve diagnostics\n\nKeep the original operating system error."]:
            with self.subTest(message=message):
                self.git("commit", "--quiet", "--allow-empty", "-m", message)
                self.assertEqual(self.git("log", "-1", "--format=%s").stdout.strip(), message.splitlines()[0])

    def test_invalid_messages_cannot_create_a_commit(self):
        before = self.git("rev-parse", "HEAD").stdout
        for message in ["Initial DeskVeil source", "fix:missing space", "fix(): empty scope",
                        "fix( ): blank scope", "fix( power): padded scope", "fix: ",
                        "fix(power)!!: extra breaking marker", "fix: valid subject\nMissing separator",
                        "\ufefffix: hide an invalid subject prefix"]:
            with self.subTest(message=message):
                result = self.git("commit", "--allow-empty", "-m", message, check=False)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Use Conventional Commits", result.stderr)
                self.assertEqual(self.git("rev-parse", "HEAD").stdout, before)

    def test_git_generated_autosquash_messages_are_accepted(self):
        target = self.git("rev-parse", "HEAD").stdout.strip()
        for option in [f"--fixup={target}", f"--squash={target}", f"--fixup=amend:{target}"]:
            with self.subTest(option=option):
                self.git("commit", "--quiet", "--allow-empty", "--no-edit", option)

    def test_git_generated_merge_and_revert_messages_are_accepted(self):
        self.git("switch", "--quiet", "-c", "topic")
        self.git("commit", "--quiet", "--allow-empty", "-m", "feat: add a topic commit")
        self.git("switch", "--quiet", "main")
        self.git("merge", "--quiet", "--no-ff", "--no-edit", "topic")
        self.assertTrue(self.git("log", "-1", "--format=%s").stdout.startswith("Merge "))
        (self.repository / "fixture.txt").write_text("fixture\n")
        self.git("add", "fixture.txt")
        self.git("commit", "--quiet", "-m", "feat: add a fixture file")
        self.git("revert", "--no-edit", "HEAD")
        self.assertTrue(self.git("log", "-1", "--format=%s").stdout.startswith('Revert "'))

    def test_message_cleanup_uses_the_repository_comment_character(self):
        self.git("config", "core.commentChar", ";")
        message = self.repository / "message.txt"
        message.write_text("; Template hint\n\nfix: keep the subject\n\nKeep the body.\n; Editor hint\n")
        self.git("commit", "--quiet", "--allow-empty", "--cleanup=strip", "-F", str(message))
        self.assertEqual(self.git("log", "-1", "--format=%B").stdout.strip(),
                         "fix: keep the subject\n\nKeep the body.")

    def test_missing_or_empty_message_is_rejected(self):
        hook = ROOT / ".githooks/commit-msg"
        missing = subprocess.run([str(hook)], cwd=self.repository, env=self.environment,
                                 text=True, capture_output=True)
        self.assertEqual(missing.returncode, 2)
        message = self.repository / "empty.txt"
        message.write_text("")
        empty = subprocess.run([str(hook), str(message)], cwd=self.repository, env=self.environment,
                               text=True, capture_output=True)
        self.assertEqual(empty.returncode, 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
