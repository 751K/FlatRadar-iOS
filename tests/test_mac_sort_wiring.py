"""Mac 点列头：全量在手时本地重排，不再重拉全部分页（代码审查）。

本地顺序和服务端一致由 Core 的 `ServerListingOrderTests` 守（夹具来自后端原始代码）。
这里钉住的是 Mac 真的走了那条路——`BrowseModel.applySortOrder` 是 SwiftUI 列头点击的
落点，单测够不着它和 `ListingsStore` 之间那一行。
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_列头排序先试本地重排_没拉全才去服务端():
    src = (ROOT / "FlatRadarMac/BrowseModel.swift").read_text(encoding="utf-8")
    start = src.index("func applySortOrder() async {")
    body = src[start:src.index("\n    }\n", start)]
    assert "listings.reorderLocally(" in body, "点列头又直接去服务端重拉全部分页了"
    assert body.index("listings.reorderLocally(") < body.index("listings.setSort("), (
        "本地重排必须先试；setSort 是没拉全时的退路")


def test_夹具生成脚本钉着后端提交():
    src = (ROOT / "tools/server-sort/make_fixture.py").read_text(encoding="utf-8")
    assert 'BACKEND_SHA = "' in src, "夹具要钉在后端的某个提交上，否则无法复现"
