"""桌面小组件那几处接线——**每一处坏掉都不报错**。

这是这条测试存在的全部理由。小组件和 app 是两个进程，它们之间只有
App Group 一条通道，而通道断掉的症状统一是"那一格永远空着"：

| 坏在哪儿 | 构建 | 运行 | 你看到的 |
|---|---|---|---|
| 两份 entitlements 的组名对不上 | 绿 | 不报错 | 空 |
| Swift 里的常量和 entitlements 对不上 | 绿 | 不报错 | 空 |
| macOS 上漏了 team 前缀 | 绿 | 不报错 | 空 |
| appex 没被嵌进 app | 绿 | 不报错 | 系统里根本没有这一格 |

没有一条会在日志里留下痕迹（`WidgetBridge` 自己那条 `log.error` 是写进
统一日志的，不在 Xcode 的构建输出里）。所以钉在测试里，而不是靠记性。

Swift 那一侧另有两个文件在守别的东西：`WidgetSnapshotTests` 管文案和"旧了
怎么办"，`FlatRadarMacTests/WidgetBridgeTests` 管"容器真的写得进去"（那条
必须跑在带 entitlement 的宿主 app 里）。这里管的是**配置文件之间对不对得上**。
"""
from __future__ import annotations

import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PBXPROJ = ROOT / "FlatRadar.xcodeproj" / "project.pbxproj"
APP_ENTITLEMENTS = ROOT / "FlatRadarMac" / "FlatRadarMac.entitlements"
WIDGET_ENTITLEMENTS = ROOT / "FlatRadarMacWidget" / "FlatRadarMacWidget.entitlements"
IOS_WIDGET_ENTITLEMENTS = ROOT / "FlatRadarWidget" / "FlatRadarWidget.entitlements"
IOS_APP_ENTITLEMENTS = ROOT / "FlatRadar" / "FlatRadar.entitlements"
BRIDGE = ROOT / "FlatRadarCore" / "Sources" / "FlatRadarCore" / "Status" / "WidgetBridge.swift"
WIDGET_INFO_PLIST = ROOT / "FlatRadarMacWidget-Info.plist"

GROUPS_KEY = "com.apple.security.application-groups"


def pbxproj() -> str:
    return PBXPROJ.read_text(encoding="utf-8")


def development_team() -> str:
    teams = set(re.findall(r"DEVELOPMENT_TEAM = (\w+);", pbxproj()))
    assert len(teams) == 1, f"预期只有一个 DEVELOPMENT_TEAM，实际 {sorted(teams)}"
    return teams.pop()


def app_groups(path: Path) -> list[str]:
    """entitlements 里声明的组，`$(TeamIdentifierPrefix)` 已展开。"""
    declared = plistlib.loads(path.read_bytes()).get(GROUPS_KEY, [])
    return [g.replace("$(TeamIdentifierPrefix)", development_team() + ".") for g in declared]


def swift_app_group() -> str:
    """`WidgetBridge.appGroup` 的 macOS 分支。"""
    source = BRIDGE.read_text(encoding="utf-8")
    macos_branch = source.split("#if os(macOS)", 1)[1].split("#else", 1)[0]
    found = re.findall(r'appGroup = "([^"]+)"', macos_branch)
    assert len(found) == 1, f"WidgetBridge 的 macOS 分支里解析出 {found}，正则该修了"
    return found[0]


# ---------------------------------------------------------------- App Group

def test_两个_target_声明的组名一模一样():
    """一边改了另一边没改 —— 通道就断了，而且两边都编得过。"""
    assert app_groups(APP_ENTITLEMENTS) == app_groups(WIDGET_ENTITLEMENTS) != [], (
        f"app 声明 {app_groups(APP_ENTITLEMENTS)}，"
        f"小组件声明 {app_groups(WIDGET_ENTITLEMENTS)}。"
        "两边必须字字相同，否则它们各自拿到一个空容器。")


def test_代码里的常量和_entitlements_对得上():
    """`containerURL(...)` 只认签名里那个串，多一个字符就是另一个（不存在的）容器。"""
    assert swift_app_group() in app_groups(APP_ENTITLEMENTS), (
        f"WidgetBridge.appGroup = {swift_app_group()}，"
        f"而 entitlements 里是 {app_groups(APP_ENTITLEMENTS)}。")


def test_macOS_上组名必须带_team_前缀():
    """iOS 写 `group.xxx` 就行，macOS 不行。

    漏了前缀时 `containerURL(...)` **照样返回一个路径**（实测过），
    只有写的那一步被沙盒拒掉——于是症状是"读回来是 nil"，离原因隔着两层。
    """
    prefix = development_team() + "."
    assert swift_app_group().startswith(prefix), (
        f"{swift_app_group()} 没有以 {prefix} 开头。")


def swift_app_group_ios() -> str:
    """`WidgetBridge.appGroup` 的 iOS 分支（`#else` 那一半）。"""
    source = BRIDGE.read_text(encoding="utf-8")
    ios_branch = source.split("#else", 1)[1].split("#endif", 1)[0]
    found = re.findall(r'appGroup = "([^"]+)"', ios_branch)
    assert len(found) == 1, f"WidgetBridge 的 iOS 分支里解析出 {found}，正则该修了"
    return found[0]


def test_iOS_两端声明的组名一模一样():
    """iOS 的 app 和它的小组件必须声明同一个组，而且**不带** team 前缀。

    macOS 那边必须带（`$(TeamIdentifierPrefix)`），iOS 这边不能带——同一个
    App Group 在两端两种写法，这是 Apple 的规矩，不是笔误。写混了不会报错，
    只会让容器 URL 指向一个不存在的地方。
    """
    app = plistlib.loads(IOS_APP_ENTITLEMENTS.read_bytes()).get(GROUPS_KEY, [])
    widget = plistlib.loads(IOS_WIDGET_ENTITLEMENTS.read_bytes()).get(GROUPS_KEY, [])
    assert app == widget != [], f"app 声明 {app}，小组件声明 {widget}"
    assert swift_app_group_ios() in app, (
        f"WidgetBridge 的 iOS 分支是 {swift_app_group_ios()}，"
        f"而 entitlements 里是 {app}。")
    assert not any(g.startswith(development_team()) for g in app), (
        f"iOS 的组名带上了 team 前缀：{app}。那是 macOS 的写法。")


# ---------------------------------------------------- appex 得真的进到 app 里

def test_小组件被嵌进了_Mac_app():
    """`dstSubfolderSpec = 13` 就是 `Contents/PlugIns`。

    没有这条 Copy Files 阶段时 appex 照样会被构建出来（它是个独立 target），
    只是不进 .app——系统因此根本不知道有这个小组件，而构建是绿的。
    """
    source = pbxproj()
    assert "FlatRadarMacWidget.appex in Embed Foundation Extensions" in source, \
        "appex 没出现在任何 Copy Files 阶段里"
    assert "FlatRadarWidget.appex in Embed Foundation Extensions" in source, \
        "iOS 那个 appex 没出现在任何 Copy Files 阶段里"
    specs = re.findall(
        r"isa = PBXCopyFilesBuildPhase;[^}]*?dstSubfolderSpec = (\d+);", source)
    assert len(specs) == 2, f"预期两条 Embed 阶段（两端各一），实际 {len(specs)}"
    assert set(specs) == {"13"}, \
        f"dstSubfolderSpec = {specs}，预期都是 13（PlugIns）"


def test_小组件的_bundle_id_挂在_app_底下():
    """系统硬性要求：扩展的 bundle id 必须是宿主的**前缀 + 一段**。

    不满足时本地跑得起来，装包和提审会被拒。
    """
    ids = set(re.findall(r"PRODUCT_BUNDLE_IDENTIFIER = ([\w.]+);", pbxproj()))
    host = "com.j.kong.FlatRadar"
    widget = sorted(i for i in ids if i.startswith(host + ".") and "Widget" in i)
    assert widget == [f"{host}.MacWidget", f"{host}.Widget"], \
        f"小组件的 bundle id 是 {widget}，预期两端各一个"


# ------------------------------------------------- 不给的那几条权限也要守住

def test_小组件不许联网也不许碰钥匙串():
    """这一格的整个设计前提就是它**不取数**。

    加上 network.client 之后它就能自己发请求了，而那条路要的另外两样东西
    （bearer token、用户那台服务器的地址）都在 app 进程里——于是要么接着把
    钥匙串组也共享出去，要么给一个错的默认地址。两条都是悄悄发生的：
    自建实例的用户会看到别人家的数字，而没有任何一处会喊。

    真要改成联网取数，那是个需要重新论证的决定，不该是顺手加一行 entitlement。
    """
    for path in [WIDGET_ENTITLEMENTS, IOS_WIDGET_ENTITLEMENTS]:
        _assert_no_extra_capabilities(path)


def _assert_no_extra_capabilities(path: Path) -> None:
    declared = plistlib.loads(path.read_bytes())
    for key in ["com.apple.security.network.client",
                "com.apple.security.network.server",
                "keychain-access-groups",
                "com.apple.security.files.user-selected.read-write"]:
        assert key not in declared, (
            f"{path.name} 里出现了 {key}。见 WidgetSnapshot 顶部："
            "这一格不联网是有意的，不是还没做。")
    # macOS 的 extension 要**显式**声明沙盒；iOS 的 app extension 天然在沙盒里，
    # 那个键在 iOS 上不存在，所以只对 Mac 那份断言。
    if "Mac" in path.name:
        assert declared.get("com.apple.security.app-sandbox") is True, \
            f"{path.name}：macOS 的小组件必须显式声明沙盒"


# ------------------------------------------- Info.plist 不能待在同步目录里

def test_每一份_INFOPLIST_FILE_都在同步目录之外():
    """同步目录里的 Info.plist 会被当资源再拷一份进 bundle。

    这不是推测，Xcode 自己会警告：

        warning: The Copy Bundle Resources build phase contains this target's
        Info.plist file '.../FlatRadarMacWidget/Info.plist'.

    和 `test_testplan_location.py` 守的是同一类事（`PBXFileSystemSynchronizedRootGroup`
    里的文件自动成为 target 资源），只是那边的代价大得多——plan 里有明文凭据。
    这里的代价小，但成因一模一样，所以一起钉住。
    """
    source = pbxproj()
    synchronized = set(re.findall(
        r"isa = PBXFileSystemSynchronizedRootGroup;\s*\n\s*path = (\w+);", source))
    assert synchronized, "一个同步目录都没解析出来——正则或工程结构变了"

    plists = re.findall(r'INFOPLIST_FILE = "?([^";]+)"?;', source)
    assert plists, "一处 INFOPLIST_FILE 都没有"
    for plist in plists:
        top = Path(plist).parts[0]
        assert top not in synchronized, (
            f"{plist} 在同步目录 {top}/ 里，会被当资源多拷一份进 bundle。"
            f"挪到工程根，再把 INFOPLIST_FILE 改掉。（同步目录：{sorted(synchronized)}）")


def test_小组件声明了自己是哪种扩展():
    """`NSExtensionPointIdentifier` 只能写在 Info.plist 里——它是字典套字典，
    `INFOPLIST_KEY_*` 表达不了。漏了的话构建照样过，系统不认这个 appex。
    """
    info = plistlib.loads(WIDGET_INFO_PLIST.read_bytes())
    assert info["NSExtension"]["NSExtensionPointIdentifier"] == "com.apple.widgetkit-extension"


# --------------------------------------------------- kind 是桌面上那一格的身份

# 界面是两端共用的一份；两个 extension target 各自只有入口和 entitlements。
SHARED_UI_DIR = ROOT / "FlatRadarWidgets"
WIDGET_DIR = ROOT / "FlatRadarMacWidget"
IOS_WIDGET_DIR = ROOT / "FlatRadarWidget"
KINDS = ROOT / "FlatRadarCore" / "Sources" / "FlatRadarCore" / "Status" / "WidgetBridge.swift"


def test_widget_kind_改了等于把用户摆好的那一格弄没():
    """这两个串是桌面上那一格的**身份**。

    改掉之后，用户已经摆好的那一格会变成空白，得手动删了重摆——而构建是绿的，
    测试（除了这条）也是绿的。所以把值本身钉死在这里：要改它必须先改这条测试，
    那一刻就会读到这段话。
    """
    source = KINDS.read_text(encoding="utf-8")
    found = dict(re.findall(r'static let (\w+) = "(FlatRadar\w+)"', source))
    assert found == {"status": "FlatRadarStatus",
                     "unread": "FlatRadarUnread",
                     "calendar": "FlatRadarCalendar"}, found


def test_两格都注册在_bundle_里():
    """`WidgetBundle` 里漏掉一格的症状是"图库里没有它"——不报错。"""
    mac = (WIDGET_DIR / "FlatRadarMacWidgetBundle.swift").read_text(encoding="utf-8")
    for widget in ["StatusWidget()", "UnreadWidget()", "CalendarWidget()"]:
        assert widget in mac, f"{widget} 没出现在 Mac 的 WidgetBundle 里"
    # iOS 那边**没有**日历那一格：设计稿的 iOS 部分只有两格。
    ios = (IOS_WIDGET_DIR / "FlatRadarWidgetBundle.swift").read_text(encoding="utf-8")
    for widget in ["StatusWidget()", "UnreadWidget()"]:
        assert widget in ios, f"{widget} 没出现在 iOS 的 WidgetBundle 里"


def test_小组件里不许再出现裸的文案字面量():
    """两格显示的每一句话都必须走 `StatusWording`。

    docs/MACOS.md 只要求一件事：「文案和口径要一致」。收拢的时候当场抓到两处
    漂移（`StatsStrip` 说 `Showing`、菜单栏说 `Listings`，而注释写的又是第三种
    说法），所以这里不靠自觉——凡是要显示给人看的英文短语，一律从包里取。

    只扫 `Text("…")`：`configurationDisplayName` / `description` 那两句是
    小组件图库里的介绍语，只出现在那一个地方，没有第二处会漂。
    """
    # 品牌名不是文案，没有第二种写法可漂。设计稿大号那一格的页眉就是它。
    ALLOWED = {"FlatRadar"}
    offenders = []
    for path in sorted(SHARED_UI_DIR.glob("*.swift")):
        for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            for literal in re.findall(r'Text\("([^"\\]+)"\)', line):
                # 纯插值和标点不算文案。
                if literal not in ALLOWED and re.search(r"[A-Za-z]{3}", literal):
                    offenders.append(f"{path.name}:{lineno} Text(\"{literal}\")")
    assert not offenders, (
        "这些地方直接写了要显示的文字，绕开了 StatusWording：\n  "
        + "\n  ".join(offenders))
