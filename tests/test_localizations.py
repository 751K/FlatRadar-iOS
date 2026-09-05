"""字符串目录：每条用户可见的文案都要有全部语言的译文。

为什么需要这个测试
------------------
2026-09-06，zh-Hans 的地图截图底部图例长这样::

    Direct book 0 · 抽签 3 · Reserved 9

三个状态里只有 Lottery 有中文。查下来是 ``Localizable.xcstrings`` 里
``Direct book`` / ``Reserved`` / ``Occupied`` 三个 key **一个译文都没有**——而
同一个 switch 里的 ``Lottery`` 有。

这类缺失**没有任何信号**：Xcode 不报错，App 照跑（回退到 key 本身，也就是英文），
UI 测试照过，截图照拍。等发现的时候，五种语言的商店截图里已经混着英文了。

顺着查下去发现不是三条，是 **37 条**：地图筛选栏（Filter map / All / City /
Platform / Shown / Hidden）、登录页的免责声明整段、地图上那几句解释性提示……
换句话说，非英文用户看到的界面一直是中英/西英混排的。

所以这条规则要自动化：**新加一句 `String(localized:)` 而忘了配译文，就该红。**
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "FlatRadar" / "Localizable.xcstrings"

#: 这些 key 故意不翻译，不是漏了。
#:
#: 全是符号、占位符或标记，翻译它们没有意义，甚至会出错（比如把 "· %@" 里的
#: 间隔点改掉）。列成白名单而不是"跳过短字符串"之类的启发式——启发式会把
#: "All"、"more" 这种真正需要翻译的短词一起放过，而那正是这次漏掉的一批。
NOT_TRANSLATABLE = {
    "",              # 空字符串占位
    " ",             # 撑高度用的空格（已标记 stale）
    "· %@",          # 间隔点 + 占位符
    "/ %lld",        # 分数形式的分隔
    "+%lld",         # 增量数字
    "⋯⋯⋯⋯",          # 加载占位的省略号
    "TEST",          # 测试推送的角标，各语言都保持 TEST
}


def _catalog() -> dict:
    return json.loads(CATALOG.read_text())


def _target_languages(cat: dict) -> set[str]:
    """目录里出现过的所有语言，减去源语言。

    不写死语言列表：加一种语言时这个测试要自动跟上，写死的话新语言会被
    静默放过——而那恰好是最需要检查的时候。
    """
    langs: set[str] = set()
    for entry in cat["strings"].values():
        langs.update(entry.get("localizations", {}))
    return langs - {cat.get("sourceLanguage", "en")}


def test_catalog_is_valid_json():
    cat = _catalog()
    assert cat["strings"], "字符串目录是空的"
    assert cat.get("sourceLanguage") == "en"


def test_every_user_facing_string_is_translated():
    cat = _catalog()
    languages = _target_languages(cat)
    assert len(languages) >= 4, f"目标语言只有 {languages}，看着不对"

    missing: dict[str, list[str]] = {}
    for key, entry in cat["strings"].items():
        if key in NOT_TRANSLATABLE or entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        have = {
            lang
            for lang, loc in localizations.items()
            if (loc.get("stringUnit", {}).get("value") or "").strip()
        }
        gap = sorted(languages - have)
        if gap:
            missing[key] = gap

    assert not missing, "以下文案缺译文（补进 Localizable.xcstrings，或加入 " \
        "NOT_TRANSLATABLE 白名单）：\n" + "\n".join(
            f"  {k!r} 缺 {v}" for k, v in sorted(missing.items())[:40])


def test_allowlist_has_no_stale_entries():
    """白名单里的 key 必须真的还在目录里。

    不然它会悄悄失效：某个 key 改了文案之后，白名单还挡着一个已经不存在的
    旧 key，而新 key 缺译文却没人管。
    """
    cat = _catalog()
    stale = sorted(k for k in NOT_TRANSLATABLE if k not in cat["strings"])
    assert not stale, f"白名单里这些 key 已经不在目录里了，删掉：{stale}"


@pytest.mark.parametrize(
    "key, lang, wrong",
    [
        # Sort 是列表页的排序按钮（ListingsView 的 Picker + Label）。
        # 曾经 es 译成 "Suerte"（运气）、nl 译成 "Lot"（命运）——把 sort 当成了
        # 「抽签/命运」那个义项。钉住，别再回去。
        ("Sort", "es", "Suerte"),
        ("Sort", "nl", "Lot"),
    ],
)
def test_known_mistranslations_do_not_come_back(key, lang, wrong):
    cat = _catalog()
    value = cat["strings"][key]["localizations"][lang]["stringUnit"]["value"]
    assert value != wrong, f"{key!r} 的 {lang} 又变回错误译法 {wrong!r} 了"
