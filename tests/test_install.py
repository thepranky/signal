"""Tests for Signal's Python hook installer.

These run the installer as a subprocess with a temporary HOME, matching the
real CLI contract without touching the user's actual Claude, Cursor, or Codex
settings.

Run with:  python3 -m unittest discover -s tests
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INSTALLER = os.path.join(REPO_ROOT, "install", "install.py")
MARKER = "SIGNAL_HOOK=1"


class InstallerTestCase(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="signal-install-test-")
        self.claude = os.path.join(self.home, ".claude", "settings.json")
        self.cursor = os.path.join(self.home, ".cursor", "hooks.json")
        self.codex = os.path.join(self.home, ".codex", "hooks.json")

    def tearDown(self):
        shutil.rmtree(self.home)

    def run_installer(self, *args):
        env = dict(os.environ, HOME=self.home)
        return subprocess.run(
            [sys.executable, INSTALLER, *args],
            capture_output=True,
            text=True,
            env=env,
        )

    def write_json(self, path, data):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            json.dump(data, f)

    def make_provider_dirs(self):
        os.makedirs(os.path.dirname(self.claude), exist_ok=True)
        os.makedirs(os.path.dirname(self.cursor), exist_ok=True)
        os.makedirs(os.path.dirname(self.codex), exist_ok=True)

    def read_json(self, path):
        with open(path, encoding="utf-8") as f:
            return json.load(f)

    def count_marker(self, obj):
        return str(obj).count(MARKER)

    def test_install_creates_full_claude_cursor_and_codex_hook_sets(self):
        self.make_provider_dirs()

        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)

        claude = self.read_json(self.claude)
        cursor = self.read_json(self.cursor)
        codex = self.read_json(self.codex)
        self.assertEqual(self.count_marker(claude), 9)
        self.assertEqual(self.count_marker(cursor), 6)
        self.assertEqual(self.count_marker(codex), 5)
        self.assertIn(" codex", str(codex))
        permission_groups = codex["hooks"]["PermissionRequest"]
        self.assertTrue(any("matcher" not in group for group in permission_groups))
        self.assertTrue(os.path.exists(os.path.join(self.home, ".signal", "signal_hook.py")))
        self.assertTrue(os.path.isdir(os.path.join(self.home, ".signal", "sessions")))

    def test_install_skips_missing_provider_directories(self):
        os.makedirs(os.path.dirname(self.codex), exist_ok=True)

        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)

        self.assertFalse(os.path.exists(self.claude))
        self.assertFalse(os.path.exists(self.cursor))
        codex = self.read_json(self.codex)
        self.assertEqual(self.count_marker(codex), 5)
        self.assertIn(" codex", str(codex))
        self.assertTrue(os.path.exists(os.path.join(self.home, ".signal", "signal_hook.py")))

    def test_install_fails_when_no_provider_directories_exist(self):
        proc = self.run_installer()
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no Claude, Cursor, or Codex config directories found", proc.stderr)
        self.assertFalse(os.path.exists(self.claude))
        self.assertFalse(os.path.exists(self.cursor))
        self.assertFalse(os.path.exists(self.codex))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".signal", "signal_hook.py")))

    def test_reinstall_repairs_partial_signal_hooks_without_duplicates(self):
        signal_command = (
            f'{MARKER} /usr/bin/env python3 '
            f'"{os.path.join(self.home, ".signal", "signal_hook.py")}" running'
        )
        self.write_json(self.claude, {
            "hooks": {
                "PreToolUse": [
                    {"matcher": "*", "hooks": [{"type": "command", "command": signal_command}]},
                    {"hooks": [{"type": "command", "command": "echo keep-claude"}]},
                ]
            }
        })
        self.write_json(self.cursor, {
            "version": 1,
            "hooks": {
                "preToolUse": [
                    {"command": signal_command},
                    {"command": "echo keep-cursor"},
                ]
            }
        })
        self.write_json(self.codex, {
            "hooks": {
                "PreToolUse": [
                    {"matcher": "*", "hooks": [
                        {"type": "command", "command": f"{signal_command} codex"}
                    ]},
                    {"hooks": [{"type": "command", "command": "echo keep-codex"}]},
                ]
            }
        })

        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)

        claude = self.read_json(self.claude)
        cursor = self.read_json(self.cursor)
        codex = self.read_json(self.codex)
        self.assertEqual(self.count_marker(claude), 9)
        self.assertEqual(self.count_marker(cursor), 6)
        self.assertEqual(self.count_marker(codex), 5)
        self.assertIn("echo keep-claude", str(claude))
        self.assertIn("echo keep-cursor", str(cursor))
        self.assertIn("echo keep-codex", str(codex))

    def test_uninstall_removes_only_signal_hooks_and_preserves_unrelated_hooks(self):
        self.make_provider_dirs()

        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)

        claude = self.read_json(self.claude)
        claude["hooks"].setdefault("PreToolUse", []).append({
            "hooks": [{"type": "command", "command": "echo keep-claude"}]
        })
        self.write_json(self.claude, claude)

        cursor = self.read_json(self.cursor)
        cursor["hooks"].setdefault("preToolUse", []).append({"command": "echo keep-cursor"})
        self.write_json(self.cursor, cursor)

        codex = self.read_json(self.codex)
        codex["hooks"].setdefault("PreToolUse", []).append({
            "hooks": [{"type": "command", "command": "echo keep-codex"}]
        })
        self.write_json(self.codex, codex)

        proc = self.run_installer("--uninstall")
        self.assertEqual(proc.returncode, 0, proc.stderr)

        claude = self.read_json(self.claude)
        cursor = self.read_json(self.cursor)
        codex = self.read_json(self.codex)
        self.assertEqual(self.count_marker(claude), 0)
        self.assertEqual(self.count_marker(cursor), 0)
        self.assertEqual(self.count_marker(codex), 0)
        self.assertIn("echo keep-claude", str(claude))
        self.assertIn("echo keep-cursor", str(cursor))
        self.assertIn("echo keep-codex", str(codex))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".signal", "signal_hook.py")))

    def test_uninstall_works_without_source_hook(self):
        self.make_provider_dirs()
        proc = self.run_installer()
        self.assertEqual(proc.returncode, 0, proc.stderr)

        source_hook = os.path.join(REPO_ROOT, "hooks", "signal_hook.py")
        backup = source_hook + ".testbak"
        os.rename(source_hook, backup)
        try:
            proc = self.run_installer("--uninstall")
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(self.count_marker(self.read_json(self.cursor)), 0)
        finally:
            os.rename(backup, source_hook)

    def test_invalid_json_refuses_to_overwrite_any_settings(self):
        os.makedirs(os.path.dirname(self.claude), exist_ok=True)
        os.makedirs(os.path.dirname(self.cursor), exist_ok=True)
        with open(self.claude, "w", encoding="utf-8") as f:
            f.write("{not json")
        self.write_json(self.cursor, {"version": 1, "hooks": {}})
        self.write_json(self.codex, {"hooks": {}})

        proc = self.run_installer()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to overwrite", proc.stderr)
        with open(self.claude, encoding="utf-8") as f:
            self.assertEqual(f.read(), "{not json")
        self.assertEqual(self.read_json(self.cursor), {"version": 1, "hooks": {}})
        self.assertEqual(self.read_json(self.codex), {"hooks": {}})

    def test_invalid_codex_json_refuses_to_overwrite_any_settings(self):
        self.write_json(self.claude, {"hooks": {}})
        self.write_json(self.cursor, {"version": 1, "hooks": {}})
        os.makedirs(os.path.dirname(self.codex), exist_ok=True)
        with open(self.codex, "w", encoding="utf-8") as f:
            f.write("{not json")

        proc = self.run_installer()
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("refusing to overwrite", proc.stderr)
        self.assertEqual(self.read_json(self.claude), {"hooks": {}})
        self.assertEqual(self.read_json(self.cursor), {"version": 1, "hooks": {}})
        with open(self.codex, encoding="utf-8") as f:
            self.assertEqual(f.read(), "{not json")

    def test_dry_run_does_not_write_files(self):
        proc = self.run_installer("--dry-run")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("No Claude, Cursor, or Codex config directories found.", proc.stdout)
        self.assertFalse(os.path.exists(self.claude))
        self.assertFalse(os.path.exists(self.cursor))
        self.assertFalse(os.path.exists(self.codex))
        self.assertFalse(os.path.exists(os.path.join(self.home, ".signal", "signal_hook.py")))


if __name__ == "__main__":
    unittest.main()
