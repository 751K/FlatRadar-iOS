"""项目版本号：**两个平台各一套**，每套内部要自洽。

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

2026-09-16：版本号拆成两套
--------------------------
在这之前 `MARKETING_VERSION` 是两个平台共用一个数，这条文件里原来那条测试断言的
就是"所有 target 都一致"。那是错的——iOS 从 1.4.5 一路发到 2.2.0，Mac 版一次都
还没上架，ASC 上这两个平台的版本记录本来就是分开的（当天查到的）：

    MAC_OS   1.0     PREPARE_FOR_SUBMISSION   （2026-09-10 建的）
    IOS      2.2.0   PREPARE_FOR_SUBMISSION
    IOS      2.1.1 / 2.1.0 / 2.0.0 / 1.8.0 / 1.7.1 / 1.6.0 / 1.5.0  READY_FOR_SALE

共用一个数的后果很具体：已经传上去的三个 macOS 构建（334 / 336 / 338）全都带着
版本串 2.2.0，而 ASC 只允许把**版本串和该版本记录相同**的构建挂上去——于是
macOS 那条 1.0 记录一个可选构建都没有，卡在那里。

最后定的是 `1.0.0`（三段式，和 iOS 的写法一致）：工程里改成 1.0.0，ASC 上那条
记录也 PATCH 成了 1.0.0（`PREPARE_FOR_SUBMISSION` 状态下 versionString 可改）。
**两边必须逐字相同**——`1.0` 和 `1.0.0` 在 ASC 眼里是两个不同的串，差一个字符
就挂不上构建。改工程里的 Mac 版本号时记得 ASC 上那条也要跟着改。

这几条测试挡不住「版本号该不该升」（那要问 ASC，需要网络和凭据，不适合放进单元
测试），但挡得住它的近亲：**改了一半**，以及**两个平台又被并回一套**。

构建号为什么还是共用
--------------------
上传到 ASC 的 `CFBundleVersion` 是 **Xcode Cloud 自己塞的**（就是它的构建编号，
334/336/338 这些），`ci_scripts/` 里没有任何一行碰版本号。工程里那个
`CURRENT_PROJECT_VERSION` 只影响本地构建，两端共用不会造成任何冲突——
所以别"顺手"把它也拆开。
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest

PBXPROJ = Path(__file__).resolve().parent.parent / "FlatRadar.xcodeproj" / "project.pbxproj"

_BLOCK = re.compile(
    r"\t\t[0-9A-F]{24} /\* (Debug|Release) \*/ = \{\n"
    r"\t\t\tisa = XCBuildConfiguration;(.*?)\n\t\t\};",
    re.S,
)

#: 每个平台已经上架、投递通道已关闭的版本号。
#: 取自 App Store Connect 的 appStoreVersions（state = READY_FOR_SALE）。
#: 这不是自动校验——真正的判据在 ASC 上，取它需要网络和凭据。但把「已经出去的
#: 是哪个号」放在版本号旁边，比让人凭记忆强。
ALREADY_RELEASED = {
    "ios": {"1.5.0", "1.6.0", "1.7.1", "1.8.0", "2.0.0", "2.1.0", "2.1.1"},
    # Mac 版一次都还没上架。空集合是**事实**，不是待填的坑。
    "macos": set(),
}


def _setting(body: str, key: str) -> str | None:
    m = re.search(rf"\n\t+{key} = ([^;]+);", body)
    return m.group(1).strip().strip('"') if m else None


def configs() -> list[dict]:
    """每个 XCBuildConfiguration 块摊平成一条记录。

    按**块内容**认目标（`SDKROOT`、`PRODUCT_BUNDLE_IDENTIFIER`），不按块在文件里
    出现的顺序——Xcode 开着的时候会重排 pbxproj，认顺序的锚点隔天就失效。
    """
    src = PBXPROJ.read_text(encoding="utf-8")
    out = []
    for cfg, body in _BLOCK.findall(src):
        version = _setting(body, "MARKETING_VERSION")
        if version is None:
            continue
        out.append({
            "config": cfg,
            "bundle_id": _setting(body, "PRODUCT_BUNDLE_IDENTIFIER") or "?",
            # macOS 的 target 显式写了 SDKROOT = macosx；iOS 的继承 project 级设置。
            "platform": "macos" if _setting(body, "SDKROOT") == "macosx" else "ios",
            "version": version,
            "build": _setting(body, "CURRENT_PROJECT_VERSION"),
        })
    return out


def versions_of(platform: str) -> set[str]:
    return {c["version"] for c in configs() if c["platform"] == platform}


@pytest.mark.parametrize("platform", ["ios", "macos"])
def test_每个平台都自己定义版本号(platform):
    """两个平台各有自己的 `MARKETING_VERSION`。

    这条守的是"别把设置提到 project 级"：一旦提上去，两个平台又会共用一个数，
    而且是**静默**共用——本地构建照样过，要到 ASC 上挂不上构建才发现，
    就是 2026-09-16 之前那个状态。
    """
    assert versions_of(platform), f"{platform} 没有任何 target 定义 MARKETING_VERSION"


@pytest.mark.parametrize("platform", ["ios", "macos"])
def test_同一个平台内部版本号一致(platform):
    """一个平台里的 app target 和它的测试 target 用同一个号。

    手改时漏几处，得到的是各 target 版本不一致的构建——App 显示一个号、
    TestFlight 记另一个，而编译一切正常。
    """
    got = versions_of(platform)
    assert len(got) == 1, f"{platform} 内部有多个 MARKETING_VERSION：{sorted(got)}"


def test_同一个target的Debug和Release一致():
    """只改了一个 configuration 是最容易犯的错，而且没有任何报错。"""
    seen: dict[tuple[str, str], dict[str, str]] = {}
    for c in configs():
        seen.setdefault((c["bundle_id"], c["platform"]), {})[c["config"]] = \
            f"{c['version']} ({c['build']})"
    for (bundle_id, platform), by_cfg in seen.items():
        assert len(set(by_cfg.values())) == 1, (
            f"{bundle_id} / {platform} 的 Debug 和 Release 对不上：{by_cfg}")


def test_构建号仍然是两端共用一个():
    """`CURRENT_PROJECT_VERSION` **不**跟着版本号拆开，理由见文件头。"""
    builds = {c["build"] for c in configs()}
    assert len(builds) == 1, f"pbxproj 里有多个 CURRENT_PROJECT_VERSION：{sorted(builds)}"


@pytest.mark.parametrize("platform", ["ios", "macos"])
def test_版本号形状对(platform):
    v = next(iter(versions_of(platform)))
    assert re.fullmatch(r"\d+\.\d+(\.\d+)?", v), f"{platform} 版本号形状不对：{v!r}"


@pytest.mark.parametrize("platform", ["ios", "macos"])
def test_不能用已经上架的版本号(platform):
    """用一个已上架的号，构建会成功、投递必被拒，而日志指向别处。"""
    v = next(iter(versions_of(platform)))
    assert v not in ALREADY_RELEASED[platform], (
        f"{platform} 的 MARKETING_VERSION {v} 已经上架了。App Store Connect 会关闭"
        "这个版本的投递通道，构建能成功但投递必被拒（ITMS-90186 / ITMS-90062），"
        "而构建日志里的报错会指向别处。")
