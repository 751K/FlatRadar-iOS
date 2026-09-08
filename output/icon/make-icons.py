#!/usr/bin/env python3
"""从设计源 SVG 生成 1024 合成 PNG（**不再是提交素材**）。

定位（2.2 起变了，别搞错）
--------------------------
App 图标现在走 `FlatRadar/AppIcon.icon`（Icon Composer 文档），由 actool 直接
编译。旧的 `Assets.xcassets/AppIcon.appiconset` 已删除——删之前实测：把它整个
移走再构建，`BUILD SUCCEEDED`，产物 `AppIcon60x60@2x.png` 与移走前**逐像素
完全一致**（平均差 0.000）。那三张 PNG 对构建的贡献是零。

所以这个脚本的产物现在只有两个用途：
  1. 海报管线的 logo 来源（`make-logo.py`）
  2. 人眼审阅：一次看全 light / dark / tinted 在各尺寸下的样子

**改这里的 PNG 不会改变 App 图标。** 要改图标就去改设计源 SVG，然后跑
`make-layers.py` 重出分层素材，`.icon` 会跟着更新。

设计源
------
    flatradar-canal-icon-windows.svg        浅色（日间）
    flatradar-canal-icon-windows-dark.svg   深色（夜间）

深色版是**独立设计**，不是浅色版换色：源文件里背景和窗户是同一个色值，机械
替换会把窗子一起压暗，读成「夜里灯全关着」——对一个卖「房源亮起来」的 App
语义正好拧了。手工的夜间版把窗子做成暖琥珀 #F5D99B，是亮着的。

两个踩过的坑
------------
1. **方形 viewBox 是硬要求。** 源文件是 910×844 的非方画布；非方 viewBox 交给
   渲染器会被补白边，四角变纯白。iOS 的图标遮罩切不掉白角——这正是旧
   AppIcon.png 的 bug（自己烤了 25.4% 圆角、外面填白，系统遮罩 22.4% 切不到，
   主屏四角挂 15–22px 白楔）。这里按内容包围盒算出正方形 viewBox。
2. **FILL 由遮罩反推，不是拍脑袋。** 见下方注释。

每次生成后自动核对四角一致性与灰度跨度，不用手工复查。

    python3 output/icon/make-icons.py
"""
from __future__ import annotations

import pathlib
import re
import subprocess
import tempfile

import numpy as np
from PIL import Image, ImageDraw, ImageOps

HERE = pathlib.Path(__file__).parent
SRC_LIGHT = HERE / "flatradar-canal-icon-windows.svg"
SRC_DARK = HERE / "flatradar-canal-icon-windows-dark.svg"

# 内容占画布宽度的比例。
#
# 不是「留 10% 安全边距」——那是第三方博客把两件事混了。Apple 的硬性要求只有
# 1024×1024 / 不透明无 alpha / 不能自己烤圆角；**底色必须满幅**。所谓边距说的
# 是图形别伸进圆角被切掉，而不是留一圈空背景。
#
# 上限由遮罩本身算出来：叠上 iOS 主屏遮罩（圆角 22.37%）二分，内容放到占宽
# 97.8% 才开始有像素被切。但那是物理极限不是好看的落点——满到边会显得挤，
# 所以退到 .911（= .959 × .95），占宽 91%、四边留白 4.4–6.9%、被切 0 像素。
FILL = .911

MASK_RADIUS = .2237                  # iOS 主屏图标遮罩圆角占边长的比例
BBOX = (89.5, 93.5, 822.5, 786.5)    # 内容包围盒（含水线与倒影），取自源文件坐标


def body_of(path: pathlib.Path) -> tuple[str, str]:
    """返回 (图形, 背景色)。剥掉外壳、标题与背景 rect。"""
    s = path.read_text()
    bg = re.search(r'<rect id="background"[^>]*fill="(#[0-9A-Fa-f]{6})"', s).group(1)
    inner = s[s.index(">", s.index("<svg")) + 1: s.rindex("</svg>")]
    inner = re.sub(r'<title.*?</title>|<desc.*?</desc>|<rect id="background"[^>]*/>',
                   "", inner, flags=re.S)
    return inner.strip(), bg


def emit(body: str, bg: str) -> str:
    x0, y0, x1, y1 = BBOX
    side = (x1 - x0) / FILL
    x, y = (x0 + x1) / 2 - side / 2, (y0 + y1) / 2 - side / 2
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            f'<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
            f'viewBox="{x:.1f} {y:.1f} {side:.1f} {side:.1f}">'
            f'<rect x="{x-2:.1f}" y="{y-2:.1f}" width="{side+4:.1f}" '
            f'height="{side+4:.1f}" fill="{bg}"/>{body}</svg>')


def render(svg: str, out: pathlib.Path) -> Image.Image:
    with tempfile.TemporaryDirectory() as d:
        p = pathlib.Path(d) / "x.svg"
        p.write_text(svg)
        subprocess.run(["qlmanage", "-t", "-s", "1024", "-o", d, str(p)],
                       capture_output=True, check=False)
        png = pathlib.Path(d) / "x.svg.png"
        if not png.is_file():
            raise SystemExit(f"qlmanage 没能渲染 {out.name} 的 SVG")
        image = Image.open(png).convert("RGB").resize((1024, 1024), Image.LANCZOS)
    image.save(out)
    return image


def mask(n: int) -> np.ndarray:
    m = Image.new("L", (n * 4, n * 4), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        (0, 0, n * 4 - 1, n * 4 - 1), radius=round(n * MASK_RADIUS) * 4, fill=255)
    return np.asarray(m.resize((n, n), Image.LANCZOS)) > 200


def check(path: pathlib.Path) -> None:
    a = np.asarray(Image.open(path).convert("RGB")).astype(int)
    corners = {tuple(a[0, 0]), tuple(a[0, -1]), tuple(a[-1, 0]), tuple(a[-1, -1])}
    ink = np.abs(a - a[4, 4]).sum(2) > 26
    ys, xs = np.where(ink)
    clipped = int((ink & ~mask(1024)).sum())
    v = np.asarray(Image.open(path).convert("L")
                   .resize((40, 40), Image.LANCZOS)).astype(int)[9:-9, 9:-9]
    flags = []
    if len(corners) != 1:
        flags.append("✗ 四角不一致")
    if clipped:
        flags.append(f"✗ 被遮罩切掉 {clipped}px")
    print(f"  {path.name:24} 四角 {tuple(a[0,0])}  占宽 {(xs.max()-xs.min())/10.24:.0f}%"
          f"  灰度跨度 {v.max()-v.min():3}  {' '.join(flags) or '✓'}")


def main() -> int:
    for src, out, svg_out in ((SRC_LIGHT, "AppIcon.png", "appicon-light.svg"),
                              (SRC_DARK, "AppIcon-Dark.png", "appicon-dark.svg")):
        if not src.is_file():
            print(f"缺源文件：{src}")
            return 1
        body, bg = body_of(src)
        svg = emit(body, bg)
        (HERE / svg_out).write_text(svg)
        image = render(svg, HERE / out)
        if out == "AppIcon.png":
            ImageOps.grayscale(image).convert("RGB").save(HERE / "AppIcon-Tinted.png")
    for name in ("AppIcon.png", "AppIcon-Dark.png", "AppIcon-Tinted.png"):
        check(HERE / name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
