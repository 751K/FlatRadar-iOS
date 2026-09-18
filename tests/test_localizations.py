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

#: 所有字符串目录，不只 Localizable。
#:
#: `InfoPlist.xcstrings` 是 2026-09-06 补的：两条权限说明
#: （NSFaceIDUsageDescription / NSLocationWhenInUseUsageDescription）此前只在
#: project.pbxproj 的 INFOPLIST_KEY_* 里写着英文，**系统权限弹窗对所有语言都是
#: 英文**。那个位置不经过任何目录，所以之前的扫描一次也没看见它。
#:
#: 用 glob 而不是写死两个文件名：以后再加目录（比如 widget 的）会自动纳入。
#:
#: 2026-09-09 起包含 ``FlatRadarCore/``：Core 迁成本地 SwiftPM 包后自带一本
#: 目录（通过 ``Bundle.module`` 读），只扫 ``FlatRadar/`` 的话包里的文案
#: 缺译文不会被任何检查看见——正好是这个测试当初要堵的那种无声失败。
CATALOGS = sorted(
    q for root in ("FlatRadar", "FlatRadarCore")
    for q in (ROOT / root).rglob("*.xcstrings")
)

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
    # App 名字本身。Xcode 会把它抽进 InfoPlist.xcstrings，但 FlatRadar 是品牌名，
    # 各语言都保持原样——翻译它意味着桌面图标下的名字会变，不是我们要的。
    "CFBundleName",
}


def _catalog(path: Path) -> dict:
    return json.loads(path.read_text())


def _target_languages(cat: dict) -> set[str]:
    """目录里出现过的所有语言，减去源语言。

    不写死语言列表：加一种语言时这个测试要自动跟上，写死的话新语言会被
    静默放过——而那恰好是最需要检查的时候。
    """
    langs: set[str] = set()
    for entry in cat["strings"].values():
        langs.update(entry.get("localizations", {}))
    return langs - {cat.get("sourceLanguage", "en")}


def test_catalogs_exist():
    names = {p.name for p in CATALOGS}
    assert "Localizable.xcstrings" in names
    assert "InfoPlist.xcstrings" in names, \
        "InfoPlist.xcstrings 不见了——权限弹窗会退回英文"


@pytest.mark.parametrize("path", CATALOGS, ids=lambda p: p.name)
def test_catalog_is_valid_json(path):
    cat = _catalog(path)
    assert cat["strings"], f"{path.name} 是空的"
    assert cat.get("sourceLanguage") == "en"


@pytest.mark.parametrize("path", CATALOGS, ids=lambda p: p.name)
def test_every_user_facing_string_is_translated(path):
    cat = _catalog(path)
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

    assert not missing, f"{path.name} 里以下文案缺译文（补上，或加入 " \
        "NOT_TRANSLATABLE 白名单）：\n" + "\n".join(
            f"  {k!r} 缺 {v}" for k, v in sorted(missing.items())[:40])


@pytest.mark.parametrize("path", CATALOGS, ids=lambda p: p.name)
def test_catalog_has_no_duplicate_keys(path):
    """同一个 key 在目录里只能出现一次。

    JSON 允许重复 key，读的一方各有各的取法——Python 的 ``json`` 留最后一个，
    别的解析器可能留第一个。16b76c5 手工合并进来的 ``First seen`` /
    ``Last seen`` 就各有两份：一份 stale、一份在用，**译文还不一样**
    （es「Visto por primera vez」对「Visto primero」）。哪份生效取决于谁来读，
    而本文件其它测试用 ``json.loads`` 只看得见后一份，前一份完全隐身。
    """
    dups: list[str] = []

    def hook(pairs):
        seen: set[str] = set()
        for k, _ in pairs:
            if k in seen:
                dups.append(k)
            seen.add(k)
        return dict(pairs)

    json.loads(path.read_text(), object_pairs_hook=hook)
    assert not dups, f"{path.name} 里这些 key 出现了不止一次：{sorted(set(dups))}"


#: iPad 宽布局下顶部 tab 栏的六个标签（MainTabView）。Browse 只在窄布局出现。
IPAD_TABS = ["Dashboard", "Listings", "Map", "Calendar", "Alerts", "Settings"]

#: 六个标签加起来最多多少个字符还放得下。
#:
#: 来自 build 386 的 13 英寸 iPad 横屏实测：nl 合计 55 个字符，一行放下；es 是
#: 58 个（`Panel de control` + `Configuración`），tab 栏被分成两页，Alerts 和
#: Settings 落到第二页——截图测试找不到这两个 tab，真实的西语用户也得先点
#: 「Página siguiente」才看得见它们。按字符数估是粗的，但方向对：只会在
#: 「可能放不下」时红。
IPAD_TAB_BUDGET = 55


def test_ipad_tab_labels_fit_on_one_page():
    cat = _catalog(ROOT / "FlatRadar" / "Localizable.xcstrings")
    over = {}
    for lang in _target_languages(cat) | {"en"}:
        labels = []
        for key in IPAD_TABS:
            loc = cat["strings"][key].get("localizations", {}).get(lang, {})
            labels.append(loc.get("stringUnit", {}).get("value") or key)
        if sum(len(x) for x in labels) > IPAD_TAB_BUDGET:
            over[lang] = labels
    assert not over, (
        f"这些语言的 iPad tab 标签合计超过 {IPAD_TAB_BUDGET} 个字符，tab 栏会分页："
        f"{over}")


def test_allowlist_has_no_stale_entries():
    """白名单里的 key 必须真的还在目录里。

    不然它会悄悄失效：某个 key 改了文案之后，白名单还挡着一个已经不存在的
    旧 key，而新 key 缺译文却没人管。
    """
    keys: set[str] = set()
    for path in CATALOGS:
        keys |= set(_catalog(path)["strings"])
    stale = sorted(k for k in NOT_TRANSLATABLE if k not in keys)
    assert not stale, f"白名单里这些 key 已经不在目录里了，删掉：{stale}"


@pytest.mark.parametrize(
    "key, lang, wrong",
    [
        # Sort 是列表页的排序按钮（ListingsView 的 Picker + Label）。
        # 曾经 es 译成 "Suerte"（运气）、nl 译成 "Lot"（命运）——把 sort 当成了
        # 「抽签/命运」那个义项。钉住，别再回去。
        ("Sort", "es", "Suerte"),
        ("Sort", "nl", "Lot"),
        # Unpin 的西语位置上填的是中文（16b76c5 合进来的），Mac 列表右键菜单和
        # 侧栏 Pinned 里都看得见。
        ("Unpin", "es", "取消固定"),
        # "book" 是房源状态「可订」（iOS Dashboard 那格数字下面的小字），
        # 被当成名词「书」译了。
        ("book", "nl", "boek"),
        ("book", "es", "libro"),
    ],
)
def test_known_mistranslations_do_not_come_back(key, lang, wrong):
    cat = _catalog(ROOT / "FlatRadar" / "Localizable.xcstrings")
    value = cat["strings"][key]["localizations"][lang]["stringUnit"]["value"]
    assert value != wrong, f"{key!r} 的 {lang} 又变回错误译法 {wrong!r} 了"
