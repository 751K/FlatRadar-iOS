"""每个上架 target 的 scheme 都必须是**共享**的。

守的是什么
----------
Xcode Cloud 的 workflow 只能从**共享 scheme**（`xcshareddata/xcschemes/`）里选，
自动创建的 scheme 只存在于本机的 `xcuserdata/`，一次干净 clone 就没了。

`FlatRadarMac` 一直没被共享，于是「Mac Build」那条 workflow 在网页上根本选不到
它，被配成了 `scheme: FlatRadar` + `platform: MACOS`。而 `FlatRadar` 这个 iOS
target 在 Mac 上只有「Designed for iPad」那种形态，没有原生 macOS destination，
所以每一次推送都在 ValidationStep 上失败 36 秒：

    Unable to find a destination matching the provided destination specifier:
            { generic:1, platform:macOS }

build 329（2026-09-10）就是这么挂的。本地复现过：干净副本 + `-scheme FlatRadar
-destination 'generic/platform=macOS'` 同样报错，换成 `-scheme FlatRadarMac`
立刻 BUILD SUCCEEDED。

⚠️ 这条测试只管**仓库这一半**。ASC 上那条 workflow 指向哪个 scheme 是账号设置，
仓库里查不到，改完 scheme 还得去 App Store Connect 把它切成 FlatRadarMac。
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "FlatRadar.xcodeproj" / "project.pbxproj"
SHARED = ROOT / "FlatRadar.xcodeproj" / "xcshareddata" / "xcschemes"

#: 需要能在 CI 上单独构建 / 归档的 target。
#: 测试 target 不用列——它们由主 scheme 的 TestAction 带着走。
REQUIRED = ["FlatRadar", "FlatRadarMac"]


@pytest.mark.parametrize("name", REQUIRED)
def test_scheme_已共享(name):
    path = SHARED / f"{name}.xcscheme"
    assert path.is_file(), (
        f"{name} 的 scheme 没共享。Xcode 里 Product > Scheme > Manage Schemes 勾上 "
        f"Shared，或者直接把 {path.relative_to(ROOT)} 提交进来。"
        "不共享的话 Xcode Cloud 在干净 clone 上看不到它。"
    )


@pytest.mark.parametrize("name", REQUIRED)
def test_scheme_指向真实存在的_target(name):
    """scheme 里的 BlueprintIdentifier 必须能在 pbxproj 里找到。

    手写 / 手改 scheme 时最容易错的就是这个 24 位 id：写错了 Xcode 会静默把这个
    scheme 显示成空的，`xcodebuild -scheme` 报 "scheme not found"。
    """
    scheme = (SHARED / f"{name}.xcscheme").read_text(encoding="utf-8")
    project = PBXPROJ.read_text(encoding="utf-8")
    ids = set(re.findall(r'BlueprintIdentifier = "([0-9A-F]{24})"', scheme))
    assert ids, f"{name}.xcscheme 里没有 BlueprintIdentifier"
    for ident in ids:
        assert f"{ident} /*" in project, f"{name}.xcscheme 指向了不存在的 target {ident}"


def test_Mac_scheme_归档的是Mac那个target():
    """别指错：`FlatRadar` 是 iOS app，`FlatRadarMac` 才有原生 macOS 形态。

    指错的后果就是 build 329——`generic/platform=macOS` 解析不到 destination。
    """
    scheme = (SHARED / "FlatRadarMac.xcscheme").read_text(encoding="utf-8")
    assert 'BuildableName = "FlatRadarMac.app"' in scheme
    assert 'BuildableName = "FlatRadar.app"' not in scheme, \
        "FlatRadarMac 的 scheme 里混进了 iOS 那个 target"
