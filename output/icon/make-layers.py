#!/usr/bin/env python3
"""把设计源 SVG 拆成 Icon Composer 用的分层素材。

和 make-icons.py 的区别
-----------------------
make-icons.py 出的是**合成好的** 1024 PNG，直接塞 Assets.xcassets 用。
这个脚本出的是**分层的透明 SVG**，给 Icon Composer 做 Liquid Glass 图标用。

Icon Composer 的要求（与合成图标正好相反）：
  - 前景图层必须**透明背景**，背景是工具里单独设的一层，不能烤进 SVG
  - 背景之上最多 4 层，工具按层加高光与折射
  - SVG 里不能留外框 rect 之类的多余元素，会影响解析
  - 画布 1024（iPhone / iPad / Mac）

所有图层共用同一个 viewBox，堆叠时自动对齐。

    python3 output/icon/make-layers.py
"""
from __future__ import annotations

import pathlib
import re

HERE = pathlib.Path(__file__).parent
OUT = HERE / "layers"
FILL = .911                          # 与 make-icons.py 保持一致
BBOX = (89.5, 93.5, 822.5, 786.5)    # 内容包围盒（含水线与倒影）

SOURCES = {"light": "flatradar-canal-icon-windows.svg",
           "dark": "flatradar-canal-icon-windows-dark.svg"}

# 拆层顺序 = 由后往前。水面单独一层，让 Icon Composer 能给它不同的景深。
LAYERS = [("1-houses", "houses"), ("2-windows", "windows"), ("3-water", None)]


def viewbox() -> tuple[float, float, float]:
    x0, y0, x1, y1 = BBOX
    side = (x1 - x0) / FILL
    return (x0 + x1) / 2 - side / 2, (y0 + y1) / 2 - side / 2, side


def slice_group(svg: str, gid: str) -> str:
    """按 <g>/</g> 配对计数取出整组。

    不能用非贪婪正则：windows 组里还嵌着 ochre/red/navy 三个子组，
    `<g id="windows".*?</g>` 会在第一个子组的收尾就断掉，只取到 6 个窗子
    （应该是 20 个）。
    """
    i = svg.index(f'<g id="{gid}"')
    depth, j = 0, i
    while True:
        nxt_open = svg.find("<g", j)
        nxt_close = svg.find("</g>", j)
        if nxt_close == -1:
            raise ValueError(f"{gid} 没有闭合")
        if nxt_open != -1 and nxt_open < nxt_close:
            depth += 1
            j = nxt_open + 2
        else:
            depth -= 1
            j = nxt_close + 4
            if depth == 0:
                return svg[i:j]


def extract(svg: str, group: str | None) -> str:
    """group=None 时取水线 + 倒影。"""
    if group:
        return slice_group(svg, group)
    canal = re.search(r'<rect id="canal-line"[^>]*/>', svg).group(0)
    return canal + slice_group(svg, "reflections")


def main() -> int:
    OUT.mkdir(exist_ok=True)
    x, y, side = viewbox()
    bg = {}
    for mode, fname in SOURCES.items():
        src = HERE / fname
        if not src.is_file():
            print(f"缺源文件：{src}")
            return 1
        s = src.read_text()
        bg[mode] = re.search(r'<rect id="background"[^>]*fill="(#[0-9A-Fa-f]{6})"', s).group(1)
        inner = s[s.index(">", s.index("<svg")) + 1: s.rindex("</svg>")]
        d = OUT / mode
        d.mkdir(exist_ok=True)
        for name, group in LAYERS:
            body = extract(inner, group)
            (d / f"{name}.svg").write_text(
                '<?xml version="1.0" encoding="UTF-8"?>\n'
                f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
                f'viewBox="{x:.1f} {y:.1f} {side:.1f} {side:.1f}">\n  {body}\n</svg>\n')
            n = body.count("<path") + body.count("<rect")
            print(f"  layers/{mode}/{name}.svg   {n} 个形状")
    print("\n背景色（在 Icon Composer 里设成背景层，不要放进 SVG）：")
    for mode, c in bg.items():
        print(f"  {mode:6} {c}")
    print(f"\n共用 viewBox: {x:.1f} {y:.1f} {side:.1f} {side:.1f}  （占宽 {FILL*100:.0f}%）")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
