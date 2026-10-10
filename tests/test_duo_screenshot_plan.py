"""The Duo pose option and screenshot credentials must reach every language."""
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def test_credentials_injection_preserves_the_inner_display_option(tmp_path):
    shutil.copytree(ROOT / "TestPlans", tmp_path / "TestPlans")
    result = subprocess.run(
        ["sh", str(ROOT / "ci_scripts/ci_post_clone.sh")],
        env={**os.environ, "CI_PRIMARY_REPOSITORY_PATH": str(tmp_path),
             "UI_TEST_USERNAME": "fixture-user", "UI_TEST_PASSWORD": "fixture-pass"},
        capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stderr
    plan = json.loads((tmp_path / "TestPlans/ScreenshotsDuoInner.xctestplan").read_text())
    defaults = {e["key"]: e["value"] for e in plan["defaultOptions"]["environmentVariableEntries"]}
    for config in plan["configurations"]:
        effective = {**defaults, **{e["key"]: e["value"]
                     for e in config["options"].get("environmentVariableEntries", [])}}
        assert effective["UI_TEST_DUO_INNER_LANDSCAPE"] == "1"
        assert effective["UI_TEST_USERNAME"] == "fixture-user"
        assert effective["UI_TEST_PASSWORD"] == "fixture-pass"
    assert "fixture-user" not in result.stdout and "fixture-pass" not in result.stdout
