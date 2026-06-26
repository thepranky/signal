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

    # --- source detection + transcript-derived project name ---------------

    def test_cursor_session_without_cwd_derives_project_and_source(self):
        transcript = os.path.expanduser(
            "~/.cursor/projects/Users-alice-signal/agent-transcripts/abc/abc.jsonl")
        self.run_hook("running", {
            "session_id": "cur1",
            "transcript_path": transcript,
        })
        data = self.state("cur1")
        self.assertEqual(data["source"], "cursor")
        # cwd was absent, so the project falls back to the transcript folder
        # rather than the literal "unknown".
        self.assertNotEqual(data["project"], "unknown")
        self.assertIn("signal", data["project"])

    def test_claude_cli_source_from_path_without_entrypoint(self):
        # A ~/.claude transcript path that doesn't exist on disk falls back to
        # the path heuristic, which is the plain Claude Code CLI.
        transcript = os.path.expanduser(
            "~/.claude/projects/-Users-bob-my-app/sess.jsonl")
        self.run_hook("running", {
            "session_id": "cc1",
            "cwd": "/Users/bob/my-app",
            "transcript_path": transcript,
        })
        data = self.state("cc1")
        self.assertEqual(data["source"], "cli")
        self.assertEqual(data["project"], "my-app")

    def test_unknown_source_when_transcript_unrecognized(self):
        self.run_hook("running", {
            "session_id": "x1",
            "cwd": "/p/app",
            "transcript_path": "/tmp/whatever.jsonl",
        })
        self.assertEqual(self.state("x1")["source"], "")

    # --- Cursor's native hook payload shape -------------------------------

    def test_cursor_conversation_id_used_when_no_session_id(self):
        # Cursor's per-tool events carry `conversation_id`, not `session_id`.
        # Falling back to it keeps every event for a turn in one state file.
        self.run_hook("running", {
            "conversation_id": "conv-123",
            "cursor_version": "1.7.2",
            "workspace_roots": ["/Users/alice/code/widget"],
        })
        self.assertEqual(self.files(), ["conv-123.json"])
        data = self.state("conv-123")
        self.assertEqual(data["session_id"], "conv-123")
        self.assertEqual(data["source"], "cursor")
        self.assertEqual(data["project"], "widget")

    def test_cursor_version_tags_source_without_transcript(self):
        # No transcript path at all, but the cursor_version field is enough.
        self.run_hook("running", {
            "conversation_id": "conv-9",
            "cursor_version": "1.7.2",
        })
        self.assertEqual(self.state("conv-9")["source"], "cursor")

    def test_cursor_session_end_removes_file_by_conversation_id(self):
        # sessionEnd provides session_id (== conversation_id); the running
        # events used conversation_id, so the filenames must line up.
        self.run_hook("running", {
            "conversation_id": "conv-7",
            "cursor_version": "1.7.2",
            "workspace_roots": ["/p/app"],
        })
        self.assertEqual(self.files(), ["conv-7.json"])
        self.run_hook("end", {"session_id": "conv-7"})
        self.assertEqual(self.files(), [])

    def test_session_id_preferred_over_conversation_id(self):
        # When both are present, the explicit session_id wins.
        self.run_hook("running", {
            "session_id": "real",
            "conversation_id": "other",
            "cwd": "/p/app",
        })
        self.assertEqual(self.files(), ["real.json"])

    # --- title + entrypoint extracted from the transcript -----------------

    def write_transcript(self, name, lines):
        path = os.path.join(self.state_dir, name)
        with open(path, "w", encoding="utf-8") as f:
            for obj in lines:
                f.write(json.dumps(obj) + "\n")
        return path

    def test_title_and_entrypoint_from_claude_transcript(self):
        transcript = self.write_transcript("claude.jsonl", [
            {"type": "queue-operation", "operation": "enqueue"},
            {"type": "user", "entrypoint": "vscode",
             "message": {"role": "user", "content": "Fix the failing test"}},
        ])
        self.run_hook("running", {
            "session_id": "t1",
            "cwd": "/Users/bob/app",
            "transcript_path": transcript,
        })
        data = self.state("t1")
        self.assertEqual(data["title"], "Fix the failing test")
        self.assertEqual(data["source"], "vscode")

    def test_title_unwraps_cursor_user_query(self):
        wrapped = ("<timestamp>Fri</timestamp>\n<user_query>\n"
                   "Make the button blue\n</user_query>")
        transcript = self.write_transcript("cursor.jsonl", [
            {"role": "user",
             "message": {"content": [{"type": "text", "text": wrapped}]}},
        ])
        self.run_hook("running", {
            "session_id": "t2",
            "transcript_path": transcript,
        })
        self.assertEqual(self.state("t2")["title"], "Make the button blue")

    def test_title_is_truncated(self):
        long_prompt = "word " * 40
        transcript = self.write_transcript("long.jsonl", [
            {"type": "user", "message": {"role": "user", "content": long_prompt}},
        ])
        self.run_hook("running", {
            "session_id": "t3",
            "cwd": "/p/app",
            "transcript_path": transcript,
        })
        title = self.state("t3")["title"]
        self.assertLessEqual(len(title), 60)
        self.assertTrue(title.endswith("\u2026"))

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
