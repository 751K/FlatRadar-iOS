"""Mac 端 App Store 截图管线的守卫。

守的是四类「构建全绿、图却是错的」——每一类在 iOS 那条管线上都真的发生过，
所以这里不等它们在 Mac 上再发生一次。

1. **拍了但没进 plan。** 加了一条 `testCaptureNN_`，忘了写进
   `MacScreenshots.xctestplan` 的 `selectedTests`。云端照跑照绿，只是少一张图，
   而「少一张」没有任何一处会喊。反过来（plan 里写了、代码里删了）同样要挡。

2. **section 名对不上。** iOS 那边测试端发 `list`、App 认 `listings`，对不上
   就落进 default、界面原地不动，然后截图照拍——拍出一张名字对、尺寸对、内容
   是另一屏的图。这里把测试里用到的每个 `UI_TEST_SECTION=` 值和
   `SidebarSection` 的枚举 case 对一遍。

3. **test plan 被打进 app 里跟着上架。** `FlatRadarMac/` 是
   `PBXFileSystemSynchronizedRootGroup`——扔进去的文件会自动成为 app target 的
   资源。而 `ci_scripts/ci_post_clone.sh` 会往截图 plan 里写**明文凭据**。两件事
   撞在一起就是凭据随 .app 上架。
   这不是假想：iOS 那两份现在正是这个状态，Release 产物里实测有
   `FlatRadar.app/Screenshots.xctestplan`。所以 Mac 这份放在仓库根的
   `TestPlans/`，这条测试把它钉在那儿。

4. **plan 没挂进 scheme。** 挂不上的话 Xcode Cloud 的 TEST action 按名字找不到它，
   而报错发生在云端、要等一整轮才看得到。

不引入任何第三方依赖：plan 是 JSON、scheme 是 XML、Swift 那边只用得上正则，
标准库就够。和 `test_ios_dark_icon.py` 的取舍一致。
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PLAN = ROOT / "TestPlans" / "MacScreenshots.xctestplan"
DEFAULT_PLAN = ROOT / "TestPlans" / "Mac.xctestplan"
TESTS = ROOT / "FlatRadarMacUITests" / "MacScreenshotTests.swift"
SECTIONS = ROOT / "FlatRadarMac" / "SidebarSection.swift"
SCHEME = (ROOT / "FlatRadar.xcodeproj" / "xcshareddata" / "xcschemes"
          / "FlatRadarMac.xcscheme")
PBXPROJ = ROOT / "FlatRadar.xcodeproj" / "project.pbxproj"

UI_TEST_TARGET = "FlatRadarMacUITests"


@pytest.fixture(scope="module")
def plan() -> dict:
    assert PLAN.is_file(), f"{PLAN} 不存在"
    return json.loads(PLAN.read_text(encoding="utf-8"))


@pytest.fixture(scope="module")
def source() -> str:
    assert TESTS.is_file(), f"{TESTS} 不存在"
    return TESTS.read_text(encoding="utf-8")


def _capture_funcs(src: str) -> set[str]:
    return set(re.findall(r"func (testCapture\w+)\(\)", src))


def _selected(plan: dict) -> set[str]:
    names = set()
    for target in plan["testTargets"]:
        for t in target.get("selectedTests", []):
            # "MacScreenshotTests/testCapture01_Listings()" → testCapture01_Listings
            names.add(t.split("/")[-1].rstrip("()"))
    return names


def test_every_capture_is_in_the_plan(plan, source):
    """代码里有、plan 里没有 → 云端少拍一张，没有任何一处会喊。"""
    missing = _capture_funcs(source) - _selected(plan)
    assert not missing, (
        f"这些 testCapture 没写进 {PLAN.name} 的 selectedTests：{sorted(missing)}。"
        "云端会照跑照绿，只是少了这几张图。")


def test_plan_has_no_dangling_tests(plan, source):
    """plan 里有、代码里没有 → 云端直接报 test not found，整轮挂掉。"""
    dangling = _selected(plan) - _capture_funcs(source)
    assert not dangling, (
        f"{PLAN.name} 里这几条在 {TESTS.name} 里找不到：{sorted(dangling)}")


def test_sections_match_the_enum(source):
    """`UI_TEST_SECTION=` 的值必须是真的 `SidebarSection` case。

    对不上的后果不是报错，是截图照拍——名字对、尺寸对、内容是另一屏。
    """
    assert SECTIONS.is_file(), f"{SECTIONS} 不存在"
    cases = set(re.findall(r"^\s*case (\w+)$", SECTIONS.read_text(encoding="utf-8"),
                           flags=re.M))
    assert cases, "SidebarSection 里一个 case 都没解析出来——文件结构变了"
    # 测试里 section 是以字面量传给 capture(_:_:) 的
    used = set(re.findall(r'capture\("(\w+)"', source))
    assert used, "MacScreenshotTests 里没解析出任何 capture(...) 调用"
    unknown = used - cases
    assert not unknown, (
        f"这些 section 名不在 SidebarSection 里：{sorted(unknown)}，"
        f"可选的是 {sorted(cases)}。App 那边会落进 assertionFailure，"
        "而 Release 构建里 assertionFailure 不生效，于是静默拍错屏。")


def test_plan_is_not_inside_a_synchronized_app_folder():
    """截图 plan 里会被注入明文凭据，**不能**待在会被打进 app 的目录里。

    `FlatRadarMac/` 和 `FlatRadar/` 都是 PBXFileSystemSynchronizedRootGroup，
    扔进去的文件自动成为 app target 的资源。
    """
    synchronized = set(re.findall(r"isa = PBXFileSystemSynchronizedRootGroup;\s*\n\s*path = (\w+);",
                                  PBXPROJ.read_text(encoding="utf-8")))
    assert synchronized, "pbxproj 里没解析出同步目录——结构变了"
    top = PLAN.relative_to(ROOT).parts[0]
    assert top not in synchronized, (
        f"{PLAN.relative_to(ROOT)} 在同步目录 {top}/ 里，会被当资源拷进 .app。"
        "而 ci_post_clone.sh 会往这个文件写明文凭据——两件事撞在一起就是"
        "凭据随 App Store 包一起发出去。")


def test_scheme_references_both_plans():
    """挂不进 scheme，Xcode Cloud 的 TEST action 按名字就找不到它。"""
    xml = SCHEME.read_text(encoding="utf-8")
    for p in (DEFAULT_PLAN, PLAN):
        ref = f'container:{p.relative_to(ROOT).as_posix()}'
        assert ref in xml, f"{SCHEME.name} 里没有 {ref}"


def test_plan_targets_the_ui_test_target(plan):
    """plan 里的 target id 必须在 pbxproj 里真的存在。

    id 写错时 Xcode 会静默忽略那个 testTarget，plan 变成空的——跑完 0 条测试、
    退出码 0。
    """
    pbx = PBXPROJ.read_text(encoding="utf-8")
    ids = [t["target"]["identifier"] for t in plan["testTargets"]]
    assert ids, "plan 里没有 testTargets"
    for i in ids:
        assert f"{i} /* {UI_TEST_TARGET} */" in pbx, (
            f"plan 引用的 target id {i} 在 pbxproj 里不是 {UI_TEST_TARGET}")


def test_single_configuration_until_mac_is_localized(plan):
    """Mac 端现在只跑一种语言，这是**有据的**，不是偷懒。

    FlatRadarMac 这个 target 没有字符串目录，构建产物
    `FlatRadarMac.app/Contents/Resources/` 下**一个 .lproj 都没有**（只有
    FlatRadarCore 那个 bundle 里有五个）。侧栏、工具栏、表头这些 Mac 专有文案
    是硬写的英文，`Text(_ content: String)` 那个重载也不做本地化。

    所以多配几个语言 configuration，只会跑出几套一模一样的英文截图——而张数和
    尺寸全合格。iOS 那边正是这么浪费过一轮（见 ScreenshotTests 里 `launch` 的
    注释：「五种语言跑出五套一模一样的英文截图」）。

    哪天 Mac 端做了本地化，把语言加进 plan，同时把这条测试改掉。
    """
    names = [c["name"] for c in plan["configurations"]]
    assert names == ["en-US"], (
        f"Mac 截图 plan 现在有 {names}。多语言要等 FlatRadarMac 真的有字符串目录"
        "之后再加，否则跑出来是几套一样的英文图。")
