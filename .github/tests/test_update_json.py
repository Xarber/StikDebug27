import json
from pathlib import Path
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
with patch.object(sys, "argv", ["update_json.py", "--repository", "Xarber/StikDebug27"]):
    updater = runpy.run_path(str(ROOT / ".github/update_json.py"))


class SourceHistoryTests(unittest.TestCase):
    def test_nightly_output_retains_stable_versions_and_omits_channels(self):
        base = json.loads((ROOT / ".github/apps.json").read_text())
        persistent = json.loads(json.dumps(base))
        persistent["apps"][0].pop("releaseChannels")
        persistent["apps"][0]["versions"] = [{"version": "3.1.10", "downloadURL": "https://example.test/stable.ipa"}, {"version": "3.1.9"}]
        function = updater["update_source"]
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "apps.json"
            with patch.dict(function.__globals__, {
                "JSON_FILE": str(output), "RELEASE_TAG": "nightly", "IS_NIGHTLY": True,
                "load_base_json": lambda: base, "load_persistent_json": lambda: persistent,
                "github_api_get": lambda _: {"tag_name": "nightly", "assets": [{"name": "StikDebug.ipa", "browser_download_url": "https://example.test/nightly.ipa", "size": 10}]},
                "app_versions": lambda: ("3.1.11", "2")
            }):
                function()
            result = json.loads(output.read_text())["apps"][0]
        self.assertEqual(result["versions"], persistent["apps"][0]["versions"])
        self.assertNotIn("releaseChannels", result)

    def test_published_source_without_channels_preserves_all_stable_versions(self):
        base = json.loads((ROOT / ".github/apps.json").read_text())
        persistent = json.loads(json.dumps(base))
        app = persistent["apps"][0]
        app.pop("releaseChannels")
        app["versions"] = [{"version": "3.1.10"}, {"version": "3.1.9"}]
        output = updater["clean_source_from_base"](base, persistent)
        self.assertEqual(output["apps"][0]["versions"], app["versions"])
        self.assertEqual(len(output["apps"][0]["releaseChannels"]), 2)

    def test_recovery_only_uses_actual_stable_ipa_assets(self):
        release = {"tag_name": "3.1.10", "published_at": "2026-08-25T00:00:00Z", "assets": [{"name": "StikDebug.ipa", "browser_download_url": "https://example.test/stable.ipa", "size": 123}]}
        function = updater["recover_stable_versions"]
        with patch.dict(function.__globals__, {"github_api_get": lambda _: [release, {**release, "prerelease": True}, {**release, "tag_name": "1.0"}]}):
            versions = function()
        self.assertEqual(len(versions), 1)
        self.assertEqual(versions[0]["version"], "3.1.10")
        self.assertNotIn("buildVersion", versions[0])


if __name__ == "__main__":
    unittest.main()
