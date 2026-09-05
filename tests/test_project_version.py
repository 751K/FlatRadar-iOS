"""项目版本号的一致性。

为什么值得一条测试
------------------
2026-09-05：2.0.0 过审上架后，项目里仍写着 MARKETING_VERSION = 2.0.0。此后每一次
推送触发的 Xcode Cloud Default 构建都会编译成功、然后在投递给 App Store Connect
时被拒：

    ITMS-90186  The train version '2.0.0' is closed for new build submissions
    ITMS-90062  CFBundleShortVersionString [2.0.0] 必须高于已批准的版本 [2.0.0]

而构建日志里显示的是 "Unable to authenticate with App Store Connect"——一条完全
指向别处的错误。真正的原因只出现在 Apple 发来的邮件里。四次构建、两个仓库都试过
之后才定位到，因为我一直在读日志。

这条测试挡不住「版本号该不该升」（那要问 ASC，需要网络和凭据，不适合放进单元
测试），但挡得住它的近亲：**改了一半**。

pbxproj 里 MARKETING_VERSION 出现 6 次（3 个 target × Debug/Release）。手改时
漏掉几处，得到的是各 target 版本不一致的构建——App 显示一个号、TestFlight 记另
一个，而编译一切正常。
"""
from __future__ import annotations

import re
from pathlib import Path

PBXPROJ = Path(__file__).resolve().parent.parent / "FlatRadar.xcodeproj" / "project.pbxproj"

_MARKETING = re.compile(r"MARKETING_VERSION = ([^;]+);")
_BUILD = re.compile(r"CURRENT_PROJECT_VERSION = ([^;]+);")


def test_all_targets_agree_on_the_marketing_version():
    versions = set(_MARKETING.findall(PBXPROJ.read_text(encoding="utf-8")))
    assert len(versions) == 1, (
        f"pbxproj 里有多个 MARKETING_VERSION：{sorted(versions)}。"
        "多半是手改时漏了几处——3 个 target × Debug/Release 共 6 处。"
        "各 target 版本不一致时编译不会报错，App 显示一个号、TestFlight 记另一个。")


def test_all_targets_agree_on_the_build_number():
    versions = set(_BUILD.findall(PBXPROJ.read_text(encoding="utf-8")))
    assert len(versions) == 1, f"pbxproj 里有多个 CURRENT_PROJECT_VERSION：{sorted(versions)}"


def test_marketing_version_looks_like_a_version():
    v = _MARKETING.findall(PBXPROJ.read_text(encoding="utf-8"))[0].strip()
    assert re.fullmatch(r"\d+\.\d+(\.\d+)?", v), f"版本号形状不对：{v!r}"


def test_the_shipped_version_is_recorded_so_the_next_bump_is_obvious():
    """已上架的版本写在这里，改版本号时顺手对一眼。

    这不是自动校验——真正的判据在 App Store Connect 上，取它需要网络和凭据。
    但把「已经出去的是哪个号」放在版本号旁边，比让人凭记忆强。
    """
    v = _MARKETING.findall(PBXPROJ.read_text(encoding="utf-8"))[0].strip()
    already_released = {"1.6.0", "1.7.1", "1.8.0", "2.0.0"}
    assert v not in already_released, (
        f"MARKETING_VERSION {v} 已经上架了。App Store Connect 会关闭这个版本的"
        "投递通道，构建能成功但投递必被拒（ITMS-90186 / ITMS-90062），"
        "而构建日志里的报错会指向别处。")
