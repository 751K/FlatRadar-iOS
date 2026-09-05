"""最低支持的 iOS 版本：工程里六处得一致，而且 README 说的必须是同一个数。

为什么值得一条测试
------------------
2026-09-05 发现的状态是这样的：

    根 README（徽章 + Requirements）   iOS 18.0+
    pbxproj（project 级，app target    17.0        ← app target 自己没写，继承它
      不写自己的值，直接继承）
    App Store 商店页                    iOS 17      ← 跟着 pbxproj 走

三个数，两个不一样。真正生效的是 pbxproj 那个，README 上那句是**没有任何东西
在维护的一句话**——它和工程之间不存在任何连接，所以它飘了多久没人知道。

这类漂移不会以失败的形式出现。改 IPHONEOS_DEPLOYMENT_TARGET 编译照过、测试照
绿、包照样上架，唯一的后果是商店页上的最低版本变了，以及一批老系统用户悄悄地
收不到更新（或者反过来，悄悄地被放进来一批从没测过的系统）。README 不会喊，
CI 不会喊，只有用户会。

顺带挡另外两件事
----------------
1. **改了一半。** pbxproj 里这个设置出现 6 次（project 级 Debug/Release +
   两个测试 target 各 Debug/Release）。改之前它们是 17.0 / 18.0 / 26.5 三个
   不同的值——UITests 那个 26.5 是 Xcode 建 target 时随手填的，跟 UI 测试真正
   需要什么无关（那些用例只用了 XCTest 的基本 API）。值不一致时编译不会报错。

2. **app target 偷偷长出自己的值。** 现在 app target 不写 IPHONEOS_DEPLOYMENT_
   TARGET，继承 project 级的那个——只有一个来源。Xcode 的 "Update to recommended
   settings" 会往 target 里塞显式值；一旦塞了，project 级就成了摆设，而两处从此
   可以各走各的。
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "FlatRadar.xcodeproj" / "project.pbxproj"
README = ROOT / "README.md"

_DEPLOYMENT = re.compile(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);")

# project 级 Debug/Release + FlatRadarTests × 2 + FlatRadarUITests × 2。
# app target 刻意不在其中——它继承 project 级的值。
EXPECTED_CONFIG_COUNT = 6

# 徽章：https://img.shields.io/badge/iOS-18.0%2B-000000?...
_README_BADGE = re.compile(r"img\.shields\.io/badge/iOS-(\d+\.\d+)%2B")
# Requirements 那一行：- iOS 18.0+
_README_REQUIREMENT = re.compile(r"^- iOS (\d+\.\d+)\+", re.M)


def _targets() -> list[str]:
    return [v.strip() for v in _DEPLOYMENT.findall(PBXPROJ.read_text(encoding="utf-8"))]


def test_every_configuration_agrees_on_the_deployment_target():
    values = set(_targets())
    assert len(values) == 1, (
        f"pbxproj 里有多个 IPHONEOS_DEPLOYMENT_TARGET：{sorted(values)}。"
        "值不一致时编译不会报错，但 app 能装到哪些系统上由其中一个说了算，"
        "另外几个只是让人误以为自己读懂了。")


def test_all_six_configurations_are_covered():
    """挡「改了一半」：漏掉的那几处会安静地留在旧值上。"""
    found = _targets()
    assert len(found) == EXPECTED_CONFIG_COUNT, (
        f"IPHONEOS_DEPLOYMENT_TARGET 出现 {len(found)} 次，预期 "
        f"{EXPECTED_CONFIG_COUNT} 次（project 级 + 两个测试 target，各 "
        "Debug/Release）。如果是 app target 新长出了自己的值，请把它删掉——"
        "它继承 project 级就够了，多一处就多一个能跑偏的地方。加减 target 时"
        "请一并更新这条测试。")


def test_the_readme_states_the_same_minimum_as_the_project():
    """README 上那句话没有任何东西在维护它，除了这条测试。"""
    project = _targets()[0]
    text = README.read_text(encoding="utf-8")

    badge = _README_BADGE.search(text)
    assert badge, "README 里找不到 iOS 版本徽章——徽章 URL 的格式变了？"

    requirement = _README_REQUIREMENT.search(text)
    assert requirement, "README 的 Requirements 里找不到 `- iOS <x.y>+` 这一行"

    stale = {
        name: value
        for name, value in (("徽章", badge.group(1)),
                            ("Requirements", requirement.group(1)))
        if value != project
    }
    assert not stale, (
        f"README 说最低支持 {stale}，而工程实际是 {project}。"
        "真正生效的是工程里那个，商店页也跟着它走；README 上那句只是文字。"
        "改工程时请一并改 README——反过来改 README 不会影响任何人能不能装上。")
