import runpy
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE = runpy.run_path(str(Path(__file__).resolve().parents[1] / "scripts/release_notes.py"))

class ReleaseNotesTests(unittest.TestCase):
    def test_conventional_groups_include_real_commit_links_and_scope(self):
        function = MODULE["generate"]
        commits = "abcdef123456\0feat(discovery): Find nearby servers\n123456abcdef\0fix: Retain stable releases\n987654abcdef\0docs: Update guide\n"
        with patch.dict(function.__globals__, {"subprocess": type("Git", (), {"check_output": staticmethod(lambda args, **kwargs: commits)})}):
            result = function("Xarber/StikServer27", "v0.4.0")
        self.assertIn("## Features", result)
        self.assertIn("## Fixes & Improvements", result)
        self.assertIn("**discovery:** Find nearby servers", result)
        self.assertIn("/commit/abcdef123456", result)
        self.assertNotIn("feat(discovery):", result)

    def test_git_receives_revision_as_argument_and_empty_range_is_explicit(self):
        function = MODULE["generate"]
        with patch("subprocess.check_output", return_value="") as call:
            result = function("Xarber/StikServer27", "v0.4.0")
        self.assertEqual(call.call_args.args[0][-1], "v0.4.0..HEAD")
        self.assertIn("No new commits", result)

if __name__ == "__main__":
    unittest.main()
