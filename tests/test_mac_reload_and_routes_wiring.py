"""Mac 端刷新按钮和推送跳转的接线（代码审查 P2 两条）。

规则本身在 FlatRadarMacTests 里测（`SectionReloadTests`、`RouteInboxTests`）。
这里钉住的是**视图和命令真的走了那条规则**——两处都是"写对了规则、调用点却还在走
老路"就会原样复发的问题，而调用点在 SwiftUI 视图和菜单命令里，单测够不着。
"""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAC = ROOT / "FlatRadarMac"


def _src(name: str) -> str:
    return (MAC / name).read_text(encoding="utf-8")


def _body(src: str, start_marker: str) -> str:
    start = src.index(start_marker)
    return src[start:src.index("\n}\n", start)]


# MARK: - 刷新

def test_工具栏刷新按钮刷的是当前这一屏():
    src = _src("MainWindow.swift")
    toolbar = src[src.index("private var toolbar: some ToolbarContent"):]
    reload_item = toolbar[:toolbar.index('Label("Reload"')]
    assert "reloader.reload(" in reload_item, "工具栏刷新没有走 SectionReloader，又写死成刷房源了？"
    assert "model.reload()" not in reload_item
    assert ".disabled(model.listings.isLoading)" not in toolbar, (
        "刷新按钮又按房源列表的 isLoading 置灰了——在地图屏上它和眼前的东西无关。")


def test_Cmd_R_刷的是当前这一屏():
    body = _body(_src("FlatRadarMacApp.swift"), "private struct BrowseCommands: View")
    assert "@FocusedValue(\\.sectionReload)" in body
    assert "model?.reload()" not in body, "⌘R 又写死成 model.reload() 了"
    assert 'Button("Reload Listings")' not in body


def test_主窗口把当前屏的刷新交给菜单命令():
    assert ".focusedSceneValue(\\.sectionReload" in _src("MainWindow.swift")


def test_地图刷新绕开只在空时才取的_load():
    src = _src("MainWindow.swift")
    assert re.search(r"map:\s*\{[^}]*mapStore\.refresh\(\)", src), (
        "地图的刷新得直接 refresh()——MapPane.load() 只在还没数据时才取。")


# MARK: - 推送跳转

def test_点推送投进信箱_不再发完即忘地广播():
    src = _src("MacPushDelegate.swift")
    assert "RouteInbox.shared.post(.alerts)" in src
    assert "NotificationCenter.default.post" not in src, (
        "推送回调又改回广播了：没有窗口 / 窗口还没挂上时，这次点击没人接。")


def test_主窗口从信箱取件_出现时也取一次():
    src = _src("MainWindow.swift")
    assert "takeRoute(justAppeared: true)" in src, "窗口出现时不取件，冷启动那次点击就接不住"
    assert "takeRoute(justAppeared: false)" in src
    assert ".flatRadarOpenAlerts" not in src and ".flatRadarLocateOnMap" not in src


def test_浏览窗口向信箱报到并登记开窗动作():
    body = _body(_src("FlatRadarMacApp.swift"), "private struct RootView: View")
    assert "routes.browserWindowAppeared()" in body
    assert "routes.browserWindowDisappeared()" in body
    assert "routes.registerWindowOpener" in body


def test_地图深链也走信箱():
    body = _body(_src("FlatRadarMacApp.swift"), "private struct RootView: View")
    assert "routes.post(.locateOnMap(listingID: id))" in body
    assert "NotificationCenter.default.post(name: .flatRadarLocateOnMap" not in body


def test_信箱注入到窗口和菜单栏那一格():
    src = _src("FlatRadarMacApp.swift")
    assert src.count(".environment(RouteInbox.shared)") >= 2
