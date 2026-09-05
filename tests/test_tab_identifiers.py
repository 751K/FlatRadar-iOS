"""tab 的 accessibility identifier 和 SF Symbol：App 和截图测试必须说同一套。

为什么值得一条测试
------------------
`MainTabView` 声明 identifier，`ScreenshotTests` 按 identifier 找按钮。两边各写
一份字符串，中间没有编译器——Swift 不会因为 `"tab-dashbaord"` 拼错而报错，它只是
一个找不到匹配的查询。

失败的样子也不好看：截图套件跑在 Xcode Cloud 上，一轮几分钟起步，而报错是
「等不到元素」，指向的是测试的等待逻辑，不是那个拼错的字母。

2026-09-05 把 `MainTabView` 从 `.tabItem { Label(…).accessibilityIdentifier(…) }`
迁到 iOS 18 的 `Tab {}` builder 时，七个 identifier 的声明位置全部挪了一遍
（从 Label 上挪到 `TabContent` 上）。写那次改动的机器上没装 Xcode，编译器和模拟器
都不在，这条测试是当时唯一能在本地验证「七个都还在、且符号没串」的手段。

symbol 也一起查：iPad 那条查询路径拿 SF Symbol 当兜底 identifier
（`ScreenshotTests` 里叫 symbolQuery），所以 `Label(systemImage:)` 改了而测试没跟，
iPad 会退化成只剩一条路可走，而且是安静地退化。
"""
from __future__ import annotations

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN_TAB_VIEW = ROOT / "FlatRadar" / "Views" / "MainTabView.swift"
SCREENSHOT_TESTS = ROOT / "FlatRadarUITests" / "ScreenshotTests.swift"

# ScreenshotTests: static let dashboard = Tab(id: "tab-dashboard", symbol: "chart.bar.fill")
_TEST_TAB = re.compile(
    r'Tab\(id:\s*"([^"]+)",\s*symbol:\s*"([^"]+)"\)')
# MainTabView: Label("…", systemImage: "chart.bar.fill") … .accessibilityIdentifier("tab-dashboard")
_APP_SYMBOL = re.compile(r'systemImage:\s*"([^"]+)"')
_APP_IDENTIFIER = re.compile(r'\.accessibilityIdentifier\("(tab-[^"]+)"\)')


def _declared_in_tests() -> dict[str, str]:
    return dict(
        (tab_id, symbol)
        for tab_id, symbol in _TEST_TAB.findall(
            SCREENSHOT_TESTS.read_text(encoding="utf-8")))


def _declared_in_app() -> dict[str, str]:
    """把每个 identifier 配上它前面最近的那个 systemImage。

    `Tab {} label: { Label(…, systemImage:) } .accessibilityIdentifier(…)` 的顺序
    决定了「最近的前一个」就是同一个 tab 的符号。
    """
    src = MAIN_TAB_VIEW.read_text(encoding="utf-8")
    symbols = [(m.start(), m.group(1)) for m in _APP_SYMBOL.finditer(src)]
    out: dict[str, str] = {}
    for m in _APP_IDENTIFIER.finditer(src):
        before = [sym for pos, sym in symbols if pos < m.start()]
        assert before, f"{m.group(1)} 前面找不到任何 systemImage——结构变了？"
        out[m.group(1)] = before[-1]
    return out


def test_both_sides_declare_the_same_tabs():
    app, tests = _declared_in_app(), _declared_in_tests()
    assert set(app) == set(tests), (
        f"两边的 tab identifier 对不上。\n"
        f"  只在 MainTabView 里：{sorted(set(app) - set(tests))}\n"
        f"  只在 ScreenshotTests 里：{sorted(set(tests) - set(app))}\n"
        "少一个的表现是截图套件等不到元素然后超时，而报错指向等待逻辑，"
        "不是这里。")


def test_the_symbols_agree():
    app, tests = _declared_in_app(), _declared_in_tests()
    mismatched = {
        tab_id: (app[tab_id], tests[tab_id])
        for tab_id in set(app) & set(tests)
        if app[tab_id] != tests[tab_id]
    }
    assert not mismatched, (
        f"SF Symbol 对不上（App, 测试）：{mismatched}。"
        "iPad 那条查询路径拿 symbol 当兜底 identifier，不一致时它会安静地"
        "少一条路可走。")


def test_there_are_seven_tabs():
    """加减 tab 时强制回来看一眼这条测试，顺便确认两边都改了。"""
    app = _declared_in_app()
    assert len(app) == 7, (
        f"MainTabView 里有 {len(app)} 个 tab identifier，预期 7 个"
        "（dashboard / browse / listings / map / calendar / alerts / settings）。"
        "加减 tab 时请一并更新这条测试和 ScreenshotTests。")
