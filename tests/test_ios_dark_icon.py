"""iOS 深色 App 图标的守卫。

从 751K/holland2stay-monitor 的 tests/test_dark_icon.py 拆出来。那个文件同时守
网页资源（static/logo*.png）和这个 iOS 图标；iOS 客户端迁出后，网页那半留在
后端仓库，这两条跟着 Assets.xcassets 过来。

守的是什么
----------
旧的 AppIcon-Dark.png 是一张去饱和的灰白图——在深色模式下**比浅色版还刺眼**。
它当时通过了所有人工检查，因为「有一张深色图标」这件事看起来是成立的。所以
这里不看「有没有」，只看实际内容：够不够暗、四角会不会在系统切圆角后露出亮边。

2.2 起图标换成 Icon Composer 的 `FlatRadar/AppIcon.icon`，旧的
`Assets.xcassets/AppIcon.appiconset` 已删除。删之前实测过：把整个 appiconset
移走再构建，`BUILD SUCCEEDED`，产物 `AppIcon60x60@2x.png` 与移走前**逐像素
完全一致**（平均差 0.000）——那三张 PNG 对构建的贡献是零。

所以这些断言跟着搬到 `.icon` 上。风险没有消失，只是换了载体：
  - 深色分支要真的存在，否则深色模式是系统硬压浅色版压出来的
  - 深色底色要够暗
  - 图层 SVG 必须透明（背景由 icon.json 的 fill 提供）。带背景 rect 的图层会
    在系统切圆角后露出方角——和当年那张灰白图同一类问题，只是形状不同。

不引入 Pillow / lxml：`.icon` 是 JSON + SVG，标准库就够。这一点和原文件的
取舍一致——用 importorskip 挡掉等于这些断言在 CI 上根本不跑。
"""
from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
ICON = ROOT / "FlatRadar" / "AppIcon.icon"
LAYERS = ("1-houses", "2-windows", "3-water")


def _document() -> dict:
    p = ICON / "icon.json"
    assert p.is_file(), f"{p} 不存在"
    return json.loads(p.read_text())


def _specializations(entries: list[dict]) -> dict[str | None, object]:
    """→ {None: 默认值, "dark": 深色值}

    Icon Composer 的写法：数组第一项**不带** `appearance`，那才是默认值；
    带 `appearance` 的才是分支。只写分支不写默认项的话整段会被静默忽略。
    """
    return {e.get("appearance"): e.get("value") for e in entries}


def _parse_color(spec: str) -> tuple[float, float, float]:
    """`display-p3:0.06667,0.10980,0.16078,1.00000` → (r, g, b)，0–1。"""
    body = spec.split(":", 1)[1]
    r, g, b, *_ = (float(v) for v in body.split(","))
    return r, g, b


def _luma(rgb: tuple[float, float, float]) -> float:
    """WCAG 相对亮度。分量已经是 0–1。"""
    def lin(c: float) -> float:
        return c / 12.92 if c <= 0.03928 else ((c + 0.055) / 1.055) ** 2.4
    return 0.2126 * lin(rgb[0]) + 0.7152 * lin(rgb[1]) + 0.0722 * lin(rgb[2])


@pytest.fixture(scope="module")
def doc() -> dict:
    return _document()


def test_dark_appearance_is_declared(doc):
    """深色必须是**显式分支**，不能靠系统自动压暗浅色版。"""
    fills = doc.get("fill-specializations")
    assert fills, "icon.json 缺 fill-specializations（深色背景没有单独定义）"
    by_appearance = _specializations(fills)
    assert None in by_appearance, "第一项必须不带 appearance，那是默认值"
    assert "dark" in by_appearance, "缺 appearance=dark 的背景分支"


def test_dark_background_is_actually_dark(doc):
    """旧那张灰白 AppIcon-Dark.png 在这里挂。"""
    dark = _specializations(doc["fill-specializations"])["dark"]
    rgb = _parse_color(dark["solid"])
    mean = _luma(rgb)
    assert mean < 0.25, f"深色底 {rgb} 相对亮度 {mean:.3f}，不算深色图标"


def test_every_layer_has_a_dark_variant(doc):
    layers = doc["groups"][0]["layers"]
    assert len(layers) == len(LAYERS), f"应有 {len(LAYERS)} 个图层，实际 {len(layers)}"
    for layer in layers:
        spec = layer.get("image-name-specializations")
        assert spec, f"图层 {layer.get('name')} 没有 image-name-specializations"
        by_appearance = _specializations(spec)
        assert None in by_appearance, f"图层 {layer.get('name')} 缺不带 appearance 的默认项"
        assert "dark" in by_appearance, f"图层 {layer.get('name')} 缺 dark 分支"
        for value in by_appearance.values():
            assert (ICON / "Assets" / value).is_file(), f"素材 {value} 不存在"


@pytest.mark.parametrize("stem", LAYERS)
@pytest.mark.parametrize("suffix", ("", "-dark"))
def test_layer_svg_has_no_baked_background(stem, suffix):
    """图层必须透明。

    背景由 icon.json 的 fill 提供；图层里再画一个铺满的 rect，系统切圆角后会
    露出方角。这和当年那张灰白图是同一类问题——看起来「有一张图」，但内容错了。
    """
    p = ICON / "Assets" / f"{stem}{suffix}.svg"
    assert p.is_file(), f"{p} 不存在"
    svg = p.read_text()
    assert 'id="background"' not in svg, f"{p.name} 里还留着背景 rect"
    # viewBox 必须是正方形：非方 viewBox 会被渲染器补白边，四角变纯白
    m = re.search(r'viewBox="([\d.\-]+) ([\d.\-]+) ([\d.\-]+) ([\d.\-]+)"', svg)
    assert m, f"{p.name} 没有 viewBox"
    w, h = float(m.group(3)), float(m.group(4))
    assert abs(w - h) < 0.5, f"{p.name} 的 viewBox 不是正方形（{w}×{h}）"


def test_all_layers_share_one_viewbox():
    """六个图层的 viewBox 必须一致，否则堆叠时会错位。"""
    boxes = set()
    for stem in LAYERS:
        for suffix in ("", "-dark"):
            svg = (ICON / "Assets" / f"{stem}{suffix}.svg").read_text()
            boxes.add(re.search(r'viewBox="([^"]+)"', svg).group(1))
    assert len(boxes) == 1, f"图层 viewBox 不一致：{sorted(boxes)}"


def test_legacy_appiconset_is_gone():
    """appiconset 已被 .icon 取代；留着同名的死资源只会骗人。"""
    legacy = ROOT / "FlatRadar" / "Assets.xcassets" / "AppIcon.appiconset"
    assert not legacy.exists(), (
        f"{legacy} 还在。实测它对构建贡献为零（移走后产物逐像素一致），"
        "留着会让人以为改它有用。")
