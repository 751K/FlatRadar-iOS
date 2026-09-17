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
import plistlib
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


def test_ci_strips_exactly_the_profile_bound_entitlements():
    """新加了「需要描述文件」的 entitlement，得同时加进 CI 的剥离清单。

    Xcode Cloud 的 TEST action 一律 ad-hoc 签名（`codesign --sign -`，
    `TeamIdentifier=not set`）。这类 entitlement 只能由描述文件授权，带着它们
    又没有描述文件，macOS 会拒绝 spawn：

        Could not launch "FlatRadarMac". Runningboard has returned error 5.
        Domain: RBSRequestErrorDomain Code: 5 / Launchd job spawn failed

    错误信息里一个字都没提签名或 entitlement——build 350 六条用例全挂在这上面，
    查到根因花的时间远超写这条测试。所以把它钉住：漏一项，下一轮云端就整轮红，
    而且报的还是那句看不出原因的 RunningBoard。

    判据用前缀而不是硬清单：`com.apple.developer.*` 全都要描述文件，
    `keychain-access-groups` 是靠它换 `application-identifier` 的那一个。
    `com.apple.security.*`（沙盒那一族）ad-hoc 签名自己就能授，不在此列。
    """
    ent_path = ROOT / "FlatRadarMac" / "FlatRadarMac.entitlements"
    assert ent_path.is_file(), f"{ent_path} 不存在"
    with ent_path.open("rb") as f:
        ent = plistlib.load(f)

    needs_profile = {
        k for k in ent
        if k.startswith("com.apple.developer.") or k == "keychain-access-groups"
    }

    script = (ROOT / "ci_scripts" / "ci_pre_xcodebuild.sh").read_text(encoding="utf-8")
    block = re.search(r"RESTRICTED = \[(.*?)\]", script, flags=re.S)
    assert block, "ci_pre_xcodebuild.sh 里找不到 RESTRICTED 清单——脚本结构变了"
    stripped = set(re.findall(r'"([^"]+)"', block.group(1)))

    assert needs_profile == stripped, (
        f"entitlements 里需要描述文件的是 {sorted(needs_profile)}，"
        f"而 CI 剥离的是 {sorted(stripped)}。"
        f"少剥的（{sorted(needs_profile - stripped)}）会让 Mac 截图整轮挂在"
        f" app.launch()；多剥的（{sorted(stripped - needs_profile)}）是清单没跟着删。")


def test_pre_xcodebuild_guards_every_ci_variable():
    """`ci_pre_xcodebuild.sh` 里每个 `CI_*` 都必须带 `:-` 默认值。

    这个脚本**每个 xcodebuild action 跑一遍**，而一次 TEST action 是两趟：
    build-for-testing，然后 test-without-building。Xcode Cloud 在这两趟里定义的
    `CI_*` 变量**不是同一组**——`CI_PRIMARY_REPOSITORY_PATH` 只有第一趟有。

    脚本开头是 `set -u`，所以第二趟引用它就是立即 exit 1。build 353 正是这样：
    第一趟已经把 entitlements 剥干净了，第二趟一句

        ci_pre_xcodebuild.sh: line 141: CI_PRIMARY_REPOSITORY_PATH: unbound variable

    把整轮判成 FAILED。日志里那行在 ci_pre_xcodebuild.log 的最后一行，而 ASC 的
    issues 接口只报「Running ci_pre_xcodebuild.sh script failed (exited with
    code 1)」——不下日志根本看不出是哪个变量。

    `ci_post_clone.sh` 不在此列：它整个构建只跑一次，且跑在
    `CI_PRIMARY_REPOSITORY_PATH` 确定存在的那个点上。
    """
    script = (ROOT / "ci_scripts" / "ci_pre_xcodebuild.sh").read_text(encoding="utf-8")
    assert re.search(r"^set -[a-z]*u", script, flags=re.M), (
        "脚本不再是 set -u 了——这条测试的前提没了，确认是有意的再删掉它")

    # 注释里的 CI_xxx 是说明文字，不是引用，跳过。
    code = "\n".join(l for l in script.splitlines() if not l.lstrip().startswith("#"))
    bare = set(re.findall(r"\$(CI_[A-Z_]+)\b", code))          # $CI_FOO
    bare |= set(re.findall(r"\$\{(CI_[A-Z_]+)\}", code))       # ${CI_FOO} 无默认值
    assert not bare, (
        f"这些 CI_ 变量没带 `:-` 默认值：{sorted(bare)}。"
        "脚本每个 xcodebuild action 都会跑一遍，而各阶段定义的变量不是同一组——"
        "set -u 下引用到没定义的那个会让整轮构建红，报错只说 'exited with code 1'。")


def test_mac_launch_arguments_are_dash_prefixed():
    """Mac 的启动参数必须是 `-KEY value`，**不能**用 iOS 那种裸 token。

    AppKit 把不带 `-` 的裸参数当成「要打开的文档」。它不是路径，打开失败，于是
    app 走「为打开文档而启动」那条路——`WindowGroup` 的默认窗口根本不创建。

    build 358 就是这么挂的：六条用例全卡在 `waitForWindow`，60 秒 `windows=0`，
    而进程活着、菜单栏齐全、辅助功能正常响应。屏幕录像里是一张空桌面配一条
    FlatRadarMac 的菜单栏。错误信息里没有任何一处指向启动参数。

    本地对照（`open -n -a FlatRadarMac.app --args …`）：

        HELLO                        → 无窗口     ← 和截图逻辑完全无关
        UI_TEST_SCREENSHOT_MODE      → 无窗口
        -UITestFoo 1                 → 有窗口
        （不传 --args）               → 有窗口

    iOS 不受影响，UIKit 没有这套开文档的语义——所以这条只查 Mac 那份。
    """
    src = TESTS.read_text(encoding="utf-8")
    m = re.search(r"app\.launchArguments\s*=\s*(\w+)", src)
    assert m, "没找到 app.launchArguments 的赋值——测试结构变了"

    # 收集所有拼进 args 的字符串字面量
    pushed = re.findall(r'args\s*(?:=|\+=)\s*\[([^\]]*)\]', src)
    literals = []
    for chunk in pushed:
        literals += re.findall(r'"([^"]*)"', chunk)
    assert literals, "没解析出任何启动参数字面量"

    bare = [t for t in literals
            if not t.startswith("-") and not t.startswith("\\(") and t != "1"]
    assert not bare, (
        f"这些启动参数没带 `-` 前缀：{bare}。AppKit 会把它们当成要打开的文档，"
        "结果是 app 起来了却一个窗口都没有，而且六条用例的失败信息都只说"
        "「主窗口未在 60s 内出现」。")


def test_screenshot_flag_name_matches_core():
    """UI 测试里硬写的开关名，要和 Core 里那个常量一致。

    UI 测试 target 不链 FlatRadarCore（为一个常量加依赖不值得），所以名字是抄的。
    抄错的后果是静默的：App 那边 `isOn` 永远为假，于是不进截图模式——窗口尺寸
    不钉、身份不设、推送权限框照弹，而测试照跑，拍出来的图全是错的。
    """
    core = (ROOT / "FlatRadarCore" / "Sources" / "FlatRadarCore" / "Platform"
            / "UITestFlags.swift").read_text(encoding="utf-8")
    m = re.search(r'screenshotMode\s*=\s*"([^"]+)"', core)
    assert m, "UITestFlags 里没找到 screenshotMode 常量"
    assert f'"-{m.group(1)}"' in TESTS.read_text(encoding="utf-8"), (
        f"MacScreenshotTests 里没有 \"-{m.group(1)}\"——和 Core 的常量对不上了")


def test_pane_identifier_prefix_matches_between_app_and_tests():
    """内容区 identifier 的前缀，App 和测试两边必须一致。

    App 那边是 `"pane-\\(model.section.rawValue)"`，测试那边是
    `"pane-\\(section)"`，两个字符串各写一份。改了一边忘了另一边的后果是静默的：
    `assertShowing` 永远找不到元素，六条用例全红在「内容区不是 X」上，而真正的
    原因是前缀对不上，不是界面错了——这两种失败的改法完全不同。

    section 名本身由 test_sections_match_the_enum 管，这里只管前缀。
    """
    app_src = (ROOT / "FlatRadarMac" / "MainWindow.swift").read_text(encoding="utf-8")
    m = re.search(r'\.accessibilityIdentifier\("([a-z-]+)\\\(model\.section\.rawValue\)"\)', app_src)
    assert m, "MainWindow 里没找到内容区的 accessibilityIdentifier——结构变了"
    prefix = m.group(1)

    test_src = TESTS.read_text(encoding="utf-8")
    assert f'"{prefix}\\(section)"' in test_src, (
        f"App 用的前缀是 {prefix!r}，但 MacScreenshotTests 里没有对应的 "
        f'"{prefix}\\(section)"——两边对不上，assertShowing 会永远找不到元素。')
