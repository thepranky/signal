"""Tests for the Signal hook handler.

Runs the hook exactly as Claude Code would: as a subprocess, with the event
JSON piped to stdin and the target status passed as an argument. This verifies
the real CLI contract, not just internal functions.

Run with:  python3 -m unittest discover -s tests
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HOOK = os.path.join(REPO_ROOT, "hooks", "signal_hook.py")


class HookTestCase(unittest.TestCase):
    def setUp(self):
        self.state_dir = tempfile.mkdtemp(prefix="signal-test-")

    def tearDown(self):
        for name in os.listdir(self.state_dir):
            os.unlink(os.path.join(self.state_dir, name))
        os.rmdir(self.state_dir)

    def run_hook(self, status, event):
        """Invoke the hook; return its exit code."""
        env = dict(os.environ, SIGNAL_STATE_DIR=self.state_dir)
        stdin = "" if event is None else json.dumps(event)
        proc = subprocess.run(
            [sys.executable, HOOK, status],
            input=stdin,
            capture_output=True,
            text=True,
            env=env,
        )
        return proc.returncode

    def state(self, session_id):
        path = os.path.join(self.state_dir, f"{session_id}.json")
        with open(path) as f:
            return json.load(f)

    def files(self):
        return sorted(os.listdir(self.state_dir))

    # --- happy path -------------------------------------------------------

    def test_running_writes_state_file(self):
        code = self.run_hook("running", {
            "session_id": "sessA",
            "cwd": "/Users/bob/projects/my-app",
            "transcript_path": "/x/a.jsonl",
        })
        self.assertEqual(code, 0)
        data = self.state("sessA")
        self.assertEqual(data["status"], "running")
        self.assertEqual(data["project"], "my-app")
        self.assertEqual(data["cwd"], "/Users/bob/projects/my-app")
        self.assertEqual(data["session_id"], "sessA")
        self.assertIn("updated_at", data)

    def test_status_transition_overwrites(self):
        self.run_hook("running", {"session_id": "sessA", "cwd": "/p/app"})
        self.run_hook("waiting", {"session_id": "sessA", "cwd": "/p/app"})
        self.assertEqual(self.state("sessA")["status"], "waiting")
        self.run_hook("done", {"session_id": "sessA", "cwd": "/p/app"})
        self.assertEqual(self.state("sessA")["status"], "done")

    def test_separate_sessions_separate_files(self):
        self.run_hook("running", {"session_id": "sessA", "cwd": "/p/a"})
        self.run_hook("waiting", {"session_id": "sessB", "cwd": "/p/b"})
        self.assertEqual(self.files(), ["sessA.json", "sessB.json"])

    def test_end_removes_state_file(self):
        self.run_hook("running", {"session_id": "sessA", "cwd": "/p/app"})
        self.assertEqual(self.files(), ["sessA.json"])
        code = self.run_hook("end", {"session_id": "sessA"})
        self.assertEqual(code, 0)
        self.assertEqual(self.files(), [])

    def test_end_on_missing_file_is_safe(self):
        code = self.run_hook("end", {"session_id": "ghost"})
        self.assertEqual(code, 0)
        self.assertEqual(self.files(), [])

    # --- robustness: a hook must never fail the Claude session ------------

    def test_garbage_stdin_exits_zero_and_writes_nothing(self):
        env = dict(os.environ, SIGNAL_STATE_DIR=self.state_dir)
        proc = subprocess.run(
            [sys.executable, HOOK, "running"],
            input="this is not json",
            capture_output=True, text=True, env=env,
        )
        self.assertEqual(proc.returncode, 0)
        # No session_id available -> falls back to the 'unknown' session.
        self.assertEqual(self.files(), ["unknown.json"])

    def test_missing_session_id_uses_unknown(self):
        code = self.run_hook("running", {"cwd": "/p/app"})
        self.assertEqual(code, 0)
        self.assertEqual(self.files(), ["unknown.json"])
        self.assertEqual(self.state("unknown")["project"], "app")

    def test_invalid_status_is_noop(self):
        code = self.run_hook("bogus", {"session_id": "sessA", "cwd": "/p/app"})
        self.assertEqual(code, 0)
        self.assertEqual(self.files(), [])

    def test_no_args_is_noop(self):
        env = dict(os.environ, SIGNAL_STATE_DIR=self.state_dir)
        proc = subprocess.run(
            [sys.executable, HOOK],
            input="{}", capture_output=True, text=True, env=env,
        )
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(self.files(), [])

    def test_session_id_is_sanitized_into_filename(self):
        self.run_hook("running", {"session_id": "../../etc/passwd", "cwd": "/p/app"})
        # Path separators and dots are stripped, so nothing escapes the dir.
        for name in self.files():
            self.assertNotIn("/", name)
            self.assertTrue(name.endswith(".json"))


if __name__ == "__main__":
    unittest.main()
