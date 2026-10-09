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


def test_preflight_creates_missing_devices_on_the_newest_ios_runtime(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    log = tmp_path / "simctl.jsonl"
    fake = bin_dir / "xcrun"
    fake.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
with open(os.environ["SIMCTL_TEST_LOG"], "a") as out:
    out.write(json.dumps(args) + "\\n")
if args[:3] == ["simctl", "list", "devices"]:
    print(json.dumps({"devices": {}}))
elif args[:3] == ["simctl", "list", "devicetypes"]:
    print(json.dumps({"devicetypes": [
        {"name": n, "identifier": "type-" + str(i)}
        for i, n in enumerate(["iPhone 17 Pro Max", "iPhone Duo", "iPad Pro 13-inch (M5) (16GB)"])
    ]}))
elif args[:3] == ["simctl", "list", "runtimes"]:
    print(json.dumps({"runtimes": [
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-26-5", "version": "26.5", "isAvailable": True},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1", "version": "27.1", "isAvailable": True},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-2", "version": "27.2", "isAvailable": False},
        {"identifier": "com.apple.CoreSimulator.SimRuntime.watchOS-28-0", "version": "28.0", "isAvailable": True}
    ]}))
elif args[:2] == ["simctl", "create"]:
    print("TEST-UDID")
''')
    fake.chmod(0o755)
    for name in ("pgrep", "defaults", "launchctl", "killall"):
        command = bin_dir / name
        command.write_text("#!/bin/sh\nexit 0\n")
        command.chmod(0o755)
    env = {
        **os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "SIMCTL_TEST_LOG": str(log), "CI_PRODUCT_PLATFORM": "iOS",
        "CI_XCODEBUILD_ACTION": "test-without-building", "CI_PRIMARY_REPOSITORY_PATH": "",
    }
    result = subprocess.run(
        ["bash", str(ROOT / "ci_scripts/ci_pre_xcodebuild.sh")],
        env=env, capture_output=True, text=True, timeout=10,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    import json
    calls = [json.loads(line) for line in log.read_text().splitlines()]
    creates = [c for c in calls if c[:2] == ["simctl", "create"]]
    assert len(creates) == 3
    assert all(c[-1] == "com.apple.CoreSimulator.SimRuntime.iOS-27-1" for c in creates)
    assert sum(c[:2] == ["simctl", "status_bar"] for c in calls) == 3
