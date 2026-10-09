"""Run the Cloud preparation script when simulators have not been created yet."""
import os
from pathlib import Path
import subprocess

import pytest


ROOT = Path(__file__).resolve().parents[1]


@pytest.mark.parametrize("locale", ["C", "en_US.UTF-8"])
def test_missing_simulators_do_not_abort_preflight(tmp_path, locale):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    commands = {
        "xcrun": '#!/bin/sh\nprintf \'{"devices":{}}\\n\'\n',
        "pgrep": "#!/bin/sh\nexit 1\n",
        "defaults": "#!/bin/sh\nexit 0\n",
        "launchctl": "#!/bin/sh\nexit 0\n",
        "killall": "#!/bin/sh\nexit 0\n",
    }
    for name, content in commands.items():
        command = bin_dir / name
        command.write_text(content)
        command.chmod(0o755)
    env = {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "LC_ALL": locale,
        "CI_PRODUCT_PLATFORM": "iOS",
        "CI_XCODEBUILD_ACTION": "test-without-building",
        "CI_PRIMARY_REPOSITORY_PATH": "",
    }
    result = subprocess.run(
        ["bash", str(ROOT / "ci_scripts/ci_pre_xcodebuild.sh")],
        env=env, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    for name in ("iPhone 17 Pro Max", "iPhone Duo", "iPad Pro 13-inch (M5) (16GB)"):
        assert f"找不到「{name}」，跳过" in result.stdout
    assert "unbound variable" not in result.stderr
